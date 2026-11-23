#!/usr/bin/env python3
"""lib/inboxhold.py — sala's holds on a session's stackshot inbox, and its "does a line wait for it" check, asked of the stackshot SERVER (docs/subcommands.md, "Inbox holds across machines"; docs/stackshot-contracts.md interface 3).

Standard library only, no model call; run as `python3 -I -S inboxhold.py <verb> …` by lib/common.sh and lib/wrapup.sh. On the box that runs stackshot's server these are
files (lib/common.sh `_hold_edit`, lib/wrapup.sh `inbox_line_waiting`) and this file is not used. On another box the same four things are client API calls:

  mode                         files | server. $SALA_INBOX_MODE=files|server decides outright; anything else (the default `auto`) is what the stackshot client's own settings say: $ANCHOR_PUSH_MODE,
                               else `[client] push_mode` of its config (local = files, server = server, auto = server when the client's URL ($STACKSHOT_URL, else <secrets>/client.url, else [client] url)
                               names another machine, files when its host is this box or loopback). So a box whose lines go to the server through push.py holds there too, with one setting.
                               When the client's settings cannot be read (no stackshot checkout here, no config) the URL rule alone decides, and no URL at all is files.
  hold MINUTES KEY…            `client.py post inbox-hold KEY… --minutes N` (both sources; holding again refreshes the time). N is never 0 (the server refuses it: a hold always ends):
                               a zero asks for the longest hold (1440), a negative or a non-number for 10, and more than 1440 is 1440.
  release KEY…                 `client.py post inbox-release KEY…` (both sources); a key still held in another tool's file (a reboot's resume, a tool on the server's box) is not lifted by it
                               and is printed on stdout as `elsewhere<TAB>KEY` (the answer's `held_elsewhere`): the tool that wrote it lifts it, so it is no failure of the release
  holds                        `client.py get inbox-holds`: prints `kind TAB key TAB origin TAB expires` for each hold that is not a reboot's resume (origin api | file; expires an
                               epoch, or `-` for a hold with no time). Only an `api` row can be lifted with `release`
  waiting NAME UUID            `client.py get inbox-waiting NAME,UUID`: prints `hub` or `msg` for a line that waits (held or not)

Exit codes (the ones a caller must tell apart; on 2, 3 and 4 stdout is one line saying why, on 0 and 1 it is the data above):
  0  the server answered and the answer is the good one (held / released / listed / a line waits)
  1  `waiting` only: the server answered and nothing waits
  2  NO ANSWER: the client is missing, the server was not reached within SALA_INBOX_TIMEOUT (5) seconds, it refused (400, 401, 403, 5xx: a refusal is a refusal, not a missing call) or
     its answer is not the shape the contract names. NEVER read as "nothing waits" and never as "held": the caller decides what that means for its own step
     (lib/common.sh `inbox_hold`, lib/wrapup.sh)
  3  UNKNOWN VERB: an older stackshot (the client or the server) that does not have the call (the client prints its usage, or the server answers 404, 405 or 501)
  4  RETRY: the client ended with its code 4, a delivery error that a later try can get past (stackshot's push.py uses it for "the server could not be reached or its delivery
     failed"; the inbox calls of the client end 0 or 1, so this is the same answer asked for again): the call is made once more at once, and a second 4 is this. Nothing was held or
     released, nothing is known; a caller treats it as no answer that does not trip the shell's breaker and asks again at its next turn
The stackshot client's verbs are named once, in CLIENT_VERBS: if stackshot renames them, change that line.

Environment: SALA_INBOX_CLIENT (the client.py to run: lib/common.sh `stackshot_client`; empty = none on this box), SALA_INBOX_MODE, SALA_INBOX_TIMEOUT, STACKSHOT_URL, ANCHOR_PUSH_MODE, STACKSHOT_CONFIG.
"""
import ipaddress, json, os, re, socket, subprocess, sys

# the stackshot client's calls: the argv words after client.py for each one. The one place to change when stackshot names them otherwise.
CLIENT_VERBS = {"hold": ("post", "inbox-hold"), "release": ("post", "inbox-release"), "holds": ("get", "inbox-holds"), "waiting": ("get", "inbox-waiting")}
SOURCES = ("msg", "hub")
UNKNOWN_STATUS = {404, 405, 501}   # what an older server answers for a name it does not have (a 400 is the final server's refusal of a bad key, kind or time, or its 500-key cap)
MAX_KEYS = 20                      # keys in one call (the contract: 1 to 20)
MAX_KEY_LEN = 200
MAX_MINUTES = 1440                 # the longest hold the server takes; 0 is refused
DEFAULT_MINUTES = 10
RETRY_EXIT = 4
STATUS_RE = re.compile(r"\[(\d{3}|0)\]")
OK, UNKNOWN, NOANSWER, RETRY = "ok", "unknown", "noanswer", "retry"
EXIT = {OK: 0, UNKNOWN: 3, NOANSWER: 2, RETRY: 4}

# run in a child so the stackshot client's imports never touch this process: what the client resolves for its server URL and its push mode
CHILD = r'''
import json, sys
sys.path.insert(0, sys.argv[1])
out = {}
try:
    from stackshot.fleet import client
    out["url"] = str(client.server_url() or "")
except Exception:
    pass
try:
    from stackshot.core import config
    out["push_mode"] = str(config.get("client", "push_mode", default="local") or "local")
except Exception:
    pass
print(json.dumps(out))
'''


def log(msg):
    print("inboxhold: " + msg, file=sys.stderr)


def timeout():
    try:
        return max(0.5, float(os.environ.get("SALA_INBOX_TIMEOUT") or 5))
    except ValueError:
        return 5.0


# ---- the mode ---------------------------------------------------------------------------------------------------------------------------

def client_settings(client):
    """(URL, push mode) the stackshot client works with: $STACKSHOT_URL and $ANCHOR_PUSH_MODE first (as the client's own programs read them), then what the client itself resolves (its
    server_url() and its config's [client] push_mode, in a child), then the config file's own lines. '' for what nothing names."""
    url = os.environ.get("STACKSHOT_URL", "").strip()
    pm = os.environ.get("ANCHOR_PUSH_MODE", "").strip().lower()
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(client)))) if client else ""
    if (not url or not pm) and client and os.path.basename(client) == "client.py" and os.path.isfile(os.path.join(root, "stackshot", "core", "config.py")):
        try:
            p = subprocess.run([sys.executable, "-I", "-S", "-c", CHILD, root], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10)
            got = json.loads(p.stdout.strip().splitlines()[-1]) if p.returncode == 0 and p.stdout.strip() else {}
            if isinstance(got, dict):
                url = url or str(got.get("url") or "").strip()
                pm = pm or str(got.get("push_mode") or "").strip().lower()
        except (OSError, subprocess.TimeoutExpired, ValueError, IndexError):
            pass
    if not url or not pm:   # no client to ask (or it could not say): the config file's own lines
        try:
            import tomllib
            cfg = os.environ.get("STACKSHOT_CONFIG") or os.path.expanduser("~/.config/stackshot/stackshot.toml")
            with open(cfg, "rb") as f:
                c = tomllib.load(f).get("client") or {}
            url = url or str(c.get("url") or "").strip()
            pm = pm or str(c.get("push_mode") or "").strip().lower()
        except Exception:
            pass
    return url, pm


def is_this_box(host):
    """stackshot's own test (push.py `_is_this_box`): a loopback or unspecified address, localhost, this box's host name or fully qualified name (any case), or the bare first label of
    either (a dotted name must be the whole host or fully qualified name: another domain's `<label>.example.org` is not this box because its first label is)."""
    h = host.strip().strip("[]").split("%")[0].rstrip(".").lower()
    if not h:
        return False
    try:
        ip = ipaddress.ip_address(h)
        return ip.is_loopback or ip.is_unspecified
    except ValueError:
        pass
    if h == "localhost" or h.endswith(".localhost"):
        return True
    names = {n.strip().rstrip(".").lower() for n in (socket.gethostname(), socket.getfqdn()) if n}
    return h in names or ("." not in h and h in {n.split(".")[0] for n in names})


def names_another_box(url):
    """True when the URL names a host that is not this box (stackshot's push_mode = "auto" rule); False for no host at all."""
    from urllib.parse import urlparse
    try:
        host = (urlparse(url if "://" in url else "//" + url).hostname or "").lower()
    except ValueError:
        return False
    return bool(host) and not is_this_box(host)


def mode(client):
    m = (os.environ.get("SALA_INBOX_MODE") or "auto").strip().lower()
    if m in ("files", "server"):
        return m
    if m != "auto":
        log("SALA_INBOX_MODE=%r is none of files, server, auto: taken as auto" % m)
    url, pm = client_settings(client)
    if pm == "server":
        return "server"
    if pm in ("local", "files"):
        return "files"
    if pm and pm != "auto":
        log("[client] push_mode %r is none of local, server, auto: taken as auto" % pm[:40])
    return "server" if names_another_box(url) else "files"


# ---- the calls --------------------------------------------------------------------------------------------------------------------------

def ask(client, verb, args):
    """One client call → (OK, parsed JSON dict, '') | (UNKNOWN, None, why) | (NOANSWER, None, why) | (RETRY, None, why). Never raises."""
    if not client or not os.path.isfile(client):
        return NOANSWER, None, "no stackshot client.py on this box (SALA_STACKSHOT_CLIENT, SALA_STACKSHOT_DIR)"
    argv = ([client] if os.access(client, os.X_OK) else [sys.executable, client]) + list(CLIENT_VERBS[verb]) + list(args)
    t = timeout()
    for attempt in (1, 2):
        try:
            p = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=t)
        except subprocess.TimeoutExpired:
            return NOANSWER, None, "the stackshot server did not answer within %gs" % t
        except OSError as e:
            return NOANSWER, None, "the stackshot client could not be run (%s)" % (e.strerror or type(e).__name__)
        if p.returncode != RETRY_EXIT:
            break
    out, err = p.stdout.strip(), p.stderr.strip()
    if p.returncode == 0:
        try:
            d = json.loads(out)
        except ValueError:
            d = None
        return (OK, d, "") if isinstance(d, dict) else (NOANSWER, None, "the stackshot server's answer is not a JSON object: %s" % (out or "empty")[:120])
    said = " ".join((err or out).split())[:160]
    if p.returncode == RETRY_EXIT:
        return RETRY, None, "the stackshot client could not deliver the call just now, twice (a later try can: %s)" % (said or "no reason given")
    m = STATUS_RE.search(err) or STATUS_RE.search(out)   # `stackshot: <what> [404] …` on stderr (post), `[404] …` on stdout (get)
    if m:
        st = int(m.group(1))
        return (UNKNOWN if st in UNKNOWN_STATUS else NOANSWER), None, ("the stackshot server answered %d: %s" % (st, said) if st else "the stackshot server could not be reached: %s" % said)
    if "usage" in (out + err).lower():   # a client from before the calls prints its usage for a word it does not know
        return UNKNOWN, None, "this stackshot client does not have the call: %s" % said
    return NOANSWER, None, "the stackshot client failed (exit %d): %s" % (p.returncode, said)


def keys_of(args):
    return [k for k in dict.fromkeys(a.strip() for a in args) if k]


def bad_key(k, listed=False):
    """Why the calls would refuse this key (the client takes none that starts with `--`, the server none over 200 characters or with a control character; the waiting call's key list is split
    at commas, so a key there has none)."""
    if k.startswith("--") or len(k) > MAX_KEY_LEN or (listed and "," in k) or any(not c.isprintable() for c in k):
        return "a key the stackshot calls cannot carry: %r" % k[:40]
    return ""


def chunks(keys):
    return [keys[i:i + MAX_KEYS] for i in range(0, len(keys), MAX_KEYS)]


def minutes_of(raw):
    """The time of a hold, never 0: the server refuses it. 0 asks for the longest, a negative or a non-number for the default, more than the longest is the longest."""
    try:
        v = float(raw)
    except (TypeError, ValueError):
        return str(DEFAULT_MINUTES)
    if v != v or v < 0:
        return str(DEFAULT_MINUTES)
    v = MAX_MINUTES if v == 0 else min(max(v, 0.01), MAX_MINUTES)
    return str(int(v)) if v == int(v) else "%g" % v


def cmd_hold(client, args):
    if len(args) < 2:
        print("usage: hold MINUTES KEY…")
        return 2
    keys = keys_of(args[1:])
    if not keys:
        return 0   # nothing to hold
    for k in keys:
        if bad_key(k):
            print(bad_key(k))
            return 2
    mins = minutes_of(args[0])
    for group in chunks(keys):
        kind, d, why = ask(client, "hold", group + ["--minutes", mins])
        if kind == OK:
            held = d.get("held")
            # every key must be held in both sources: a partial answer is no hold (fail safe)
            if isinstance(held, dict) and all(isinstance(held.get(s), list) and all(k in held[s] for k in group) for s in SOURCES):
                continue
            kind, why = NOANSWER, "the stackshot server's answer does not list the keys as held: %s" % json.dumps(held)[:120]
        print(why)
        return EXIT[kind]
    return 0


def cmd_release(client, args):
    keys = keys_of(args)
    if not keys:
        return 0
    for k in keys:
        if bad_key(k):
            print(bad_key(k))
            return 2
    elsewhere = []
    for group in chunks(keys):
        kind, d, why = ask(client, "release", group)
        if kind == OK and not isinstance(d.get("released"), dict):
            kind, why = NOANSWER, "the stackshot server's answer has no `released`"
        if kind == OK and d.get("held_elsewhere") is not None and not isinstance(d.get("held_elsewhere"), list):
            kind, why = NOANSWER, "the stackshot server's `held_elsewhere` is not a list"
        if kind != OK:
            print(why)
            return EXIT[kind]
        elsewhere += [k for k in (d.get("held_elsewhere") or []) if isinstance(k, str) and k]
    for k in dict.fromkeys(elsewhere):   # the answer's held_elsewhere: held by another tool's file, left there for it to lift
        print("elsewhere\t%s" % k.replace("\t", " ").replace("\n", " "))
    return 0


def cmd_holds(client, args):
    kind, d, why = ask(client, "holds", [])
    if kind == OK and not isinstance(d.get("holds"), list):
        kind, why = NOANSWER, "the stackshot server's answer has no `holds` list"
    if kind != OK:
        print(why)
        return EXIT[kind]
    for r in d["holds"]:
        if not isinstance(r, dict) or r.get("kind") not in SOURCES or not isinstance(r.get("key"), str) or not r["key"] or r.get("origin") not in ("api", "file", "resume"):
            continue   # a row of a shape not named in the contract is not one sala may free
        if r["origin"] == "resume":
            continue   # a reboot's resume: never freed from here
        exp = r.get("expires")
        print("%s\t%s\t%s\t%s" % (r["kind"], r["key"].replace("\t", " ").replace("\n", " "), r["origin"], int(exp) if isinstance(exp, (int, float)) and not isinstance(exp, bool) else "-"))
    return 0


def cmd_waiting(client, args):
    keys = keys_of(args[:2])
    if not keys:
        return 1
    for k in keys:
        if bad_key(k, listed=True):
            print(bad_key(k, listed=True))
            return 2
    kind, d, why = ask(client, "waiting", [",".join(keys)])
    if kind == OK and not (isinstance(d.get("waiting"), bool) and all(isinstance(d.get(s), int) and not isinstance(d.get(s), bool) for s in SOURCES)):
        kind, why = NOANSWER, "the stackshot server's answer is not the waiting shape: %s" % json.dumps(d)[:120]
    if kind != OK:
        print(why)
        return EXIT[kind]
    if not d["waiting"] and not (d["hub"] or d["msg"]):
        return 1
    print("hub" if d["hub"] else "msg")
    return 0


VERBS = {"hold": cmd_hold, "release": cmd_release, "holds": cmd_holds, "waiting": cmd_waiting}


def main(argv):
    client = os.environ.get("SALA_INBOX_CLIENT", "")
    if argv and argv[0] == "mode":
        print(mode(client))
        return 0
    if not argv or argv[0] not in VERBS:
        print("usage: inboxhold.py mode | hold MINUTES KEY… | release KEY… | holds | waiting NAME UUID   (lib/inboxhold.py's header)", file=sys.stderr)
        return 2
    try:
        return VERBS[argv[0]](client, argv[1:])
    except Exception as e:   # whatever went wrong is no answer, never a good one
        print("%s: %s: %s" % (argv[0], type(e).__name__, e))
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
