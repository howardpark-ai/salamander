#!/usr/bin/env python3
"""stackshot_key.py: sala's own key for stackshot, and the short-lived pass the key trades for (docs/stackshot-contracts.md, "A caller's own key").

stackshot can trust a caller by a key the caller makes and keeps instead of by the name of the machine it runs on. sala makes an Ed25519 key
pair, keeps the private half and asks the server to trust the public half (`enroll`, once; the owner approves it on a board item). From then on
a signed claim is traded for a pass that lasts ten minutes, and the pass goes on the New session form's calls (`post project-agent`,
`post project-agent-rename`, `post project-agent-retire`, the For you list's two writes and the color combos writes) where the machine token went.

    python3 stackshot_key.py init        make the key if there is none (idempotent); prints the short fingerprint
    python3 stackshot_key.py enroll      init, then POST /keys/enroll; prints the state, the short fingerprint, the board item and what happens next
    python3 stackshot_key.py status      is there a key, its short fingerprint, and the server's state for it (approved | pending | unknown)
    python3 stackshot_key.py form-pass   a pass on stdout (never on a terminal), or nothing and exit 1: the web app's way to ask (lib/stackshot_form.py is the shell side)
    python3 stackshot_key.py forget-pass drop the cached pass (the web app does when the server refused one)

`sala stackshot-key <init|enroll|status>` is the same (lib/stackshot-key.sh).

Where things are:
  the private key   ${XDG_STATE_HOME:-~/.local/state}/salamander/stackshot-key/key  (directory 0700, file 0600): 32 raw bytes, base64url without padding. Made once, with
                    O_CREAT|O_EXCL (a link of a private temporary file), never overwritten, and never printed, logged, put in an argv, an environment variable or an error text.
  the pass cache    ${XDG_RUNTIME_DIR}/salamander/stackshot-pass (directory 0700, file 0600, written atomically); without XDG_RUNTIME_DIR a per-user folder in /tmp.
                    A pass is reused until 60 s before it expires, so a command that makes several form calls trades once. The pass is a secret too: never printed (but by
                    `form-pass`, to a pipe), never in an argv, never logged.
  the log           $SALA_LOG_DIR/salamander-stackshot-key.log (default ~/.claude): ONE line per five minutes at most, saying why no pass was used.

Settings (all optional): SALA_STACKSHOT_PASS=off (use no pass at all: the machine token, as before), SALA_STACKSHOT_KEY_DIR and SALA_STACKSHOT_PASS_DIR (the two folders above),
SALA_STACKSHOT_PASS_BACKOFF (seconds a failed trade is not tried again, default 30). The server address is the one stackshot's own client uses (STACKSHOT_URL, else
<secrets>/client.url, else [client] url of stackshot.toml) and is also the claim's audience, without a trailing slash.

Standard library plus `cryptography` (the package the signature needs). Without it, or without a key, or with a server that says no, `get_pass()` answers None and the caller
goes on with the machine token: a pass is never required for a call that worked before. The module prints no secret on any path."""
from __future__ import annotations

import base64
import fcntl
import hashlib
import json
import os
import secrets
import stat
import sys
import time
import urllib.error
import urllib.request

LABEL = "sala"            # what the key is for, as the server shows it on the board item
SENDER = "sala"           # the label the key's calls carry; the server accepts `sala` and every `sala-...` (sala-spawn, sala-rename, sala-retire, sala-web)
CLAIM_LIFE = 55           # seconds a claim lives (the server refuses more than 60)
CLAIM_MAX = 2048          # the server's limit on a claim's length
REUSE_MARGIN = 60         # a cached pass is reused until this many seconds before it expires
PASS_PREFIX = "ssp_"
TIMEOUT = 8.0             # one request to the server
LOG_GAP = 300             # at most one log line per this many seconds
BACKOFF = 30              # seconds a failed trade is not tried again
OFF_WORDS = ("off", "0", "no", "false")


class KeyProblem(Exception):
    """No usable key: the text says why and never holds a secret."""


# ---- small helpers --------------------------------------------------------------------------------------------------------------
def b64u(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode("ascii")


def unb64u(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def _home() -> str:
    return os.path.expanduser("~")


def state_home() -> str:
    v = os.environ.get("XDG_STATE_HOME")
    return v if v and os.path.isabs(v) else os.path.join(_home(), ".local", "state")


def key_dir() -> str:
    return os.environ.get("SALA_STACKSHOT_KEY_DIR") or os.path.join(state_home(), "salamander", "stackshot-key")


def key_file() -> str:
    return os.path.join(key_dir(), "key")


def pass_dir() -> str:
    v = os.environ.get("SALA_STACKSHOT_PASS_DIR")
    if v:
        return v
    xr = os.environ.get("XDG_RUNTIME_DIR")
    if xr and os.path.isabs(xr):
        return os.path.join(xr, "salamander")
    return "/tmp/salamander-%d" % os.getuid()


def pass_off() -> bool:
    return os.environ.get("SALA_STACKSHOT_PASS", "").strip().lower() in OFF_WORDS


def _num_env(name: str, default: float) -> float:
    try:
        return max(0.0, float(os.environ.get(name, "")))
    except ValueError:
        return float(default)


def _private_dir(path: str) -> bool:
    """Make the directory (mode 0700) if it is not there; True when it is ours, a real directory (no link) and closed to others after this."""
    try:
        parent = os.path.dirname(path.rstrip("/"))
        if parent:
            os.makedirs(parent, mode=0o755, exist_ok=True)
        try:
            os.mkdir(path, 0o700)
        except FileExistsError:
            pass
        st = os.lstat(path)
        if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid():
            return False
        if st.st_mode & 0o077:
            os.chmod(path, 0o700)
        return True
    except OSError:
        return False


# ---- the key --------------------------------------------------------------------------------------------------------------------
def _crypto():
    try:
        from cryptography.exceptions import InvalidSignature  # noqa: F401
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    except Exception:   # not installed, or broken: the same answer
        raise KeyProblem("the Python package cryptography is missing, so sala cannot sign a claim") from None
    return serialization, Ed25519PrivateKey


def make_key() -> bool:
    """Make the key pair when there is none: True when made, False when a key is already there (never overwritten)."""
    serialization, Ed25519PrivateKey = _crypto()
    kd, kf = key_dir(), key_file()
    if not _private_dir(kd):
        raise KeyProblem("the key folder cannot be made private (%s)" % kd)
    if os.path.lexists(kf):
        return False
    raw = Ed25519PrivateKey.generate().private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())
    tmp = os.path.join(kd, ".key.%d.%s" % (os.getpid(), secrets.token_hex(4)))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write((b64u(raw) + "\n").encode("ascii"))
            f.flush()
            os.fsync(f.fileno())
        try:
            os.link(tmp, kf)      # exclusive and atomic: the final name appears complete, or not at all, and never replaces a key
        except FileExistsError:
            return False
        except OSError:
            raise KeyProblem("the key file cannot be created in %s" % kd) from None
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass
    return True


def load_private():
    """The Ed25519 private key object; KeyProblem (no secret in its text) when there is none or it cannot be used."""
    serialization, Ed25519PrivateKey = _crypto()
    kf = key_file()
    try:
        fd = os.open(kf, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except FileNotFoundError:
        raise KeyProblem("no key yet (run: sala stackshot-key enroll)") from None
    except OSError:
        raise KeyProblem("the key file cannot be opened") from None
    with os.fdopen(fd, "rb") as f:
        st = os.fstat(f.fileno())
        if st.st_uid != os.getuid() or st.st_mode & 0o077:
            raise KeyProblem("the key file is readable by others or not ours: run chmod 600 on it (the key is not used until then)")
        data = f.read(512).strip()
    try:
        raw = unb64u(data.decode("ascii"))
        if len(raw) != 32:
            raise ValueError
        return Ed25519PrivateKey.from_private_bytes(raw)
    except Exception:
        raise KeyProblem("the key file is not a key sala made") from None


def public_raw(priv) -> bytes:
    serialization, _ = _crypto()
    return priv.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)


def fingerprint(priv) -> str:
    """SHA-256 of the 32 public bytes, in hex (64 characters)."""
    return hashlib.sha256(public_raw(priv)).hexdigest()


def short(fp: str) -> str:
    return fp[:16]


# ---- the server -----------------------------------------------------------------------------------------------------------------
def _toml() -> dict:
    try:
        import tomllib
        p = os.environ.get("STACKSHOT_CONFIG") or os.environ.get("BOARD_MCP_CONFIG") or os.path.join(_home(), ".config", "stackshot", "stackshot.toml")
        with open(os.path.expanduser(p), "rb") as f:
            return tomllib.load(f)
    except Exception:
        return {}


def server_url() -> str:
    """The board's address as stackshot's client reads it (client.py server_url): STACKSHOT_URL, else <secrets>/client.url, else [client] url; no trailing slash; "" when none."""
    u = os.environ.get("STACKSHOT_URL", "").strip()
    cfg = _toml()
    if not u:
        sec = (cfg.get("paths") or {}).get("secrets") if isinstance(cfg.get("paths"), dict) else None
        sec = os.path.expanduser(str(sec)) if sec else os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(_home(), ".config"), "stackshot")
        try:
            with open(os.path.join(sec, "client.url"), encoding="utf-8") as f:
                u = f.read().strip()
        except OSError:
            u = ""
    if not u and isinstance(cfg.get("client"), dict):
        u = str(cfg["client"].get("url") or "").strip()
    return u.rstrip("/") if u.startswith(("http://", "https://")) else ""


def post_json(base: str, path: str, obj: dict, timeout: float = TIMEOUT) -> tuple[int, dict | None, str]:
    """One POST without a token -> (HTTP status, JSON object or None, "" or why it failed). Status 0: the server was not reached. Neither the address nor the body is in the why."""
    req = urllib.request.Request(base + path, data=json.dumps(obj).encode("utf-8"), method="POST",
                                 headers={"Content-Type": "application/json", "User-Agent": "sala-stackshot-key"})

    def dec(raw: bytes):
        try:
            d = json.loads(raw.decode("utf-8", "replace"))
            return d if isinstance(d, dict) else None
        except ValueError:
            return None
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, dec(r.read(65536)), ""
    except urllib.error.HTTPError as e:
        try:
            body = dec(e.read(65536))
        except Exception:
            body = None
        return e.code, body, ""
    except Exception as e:
        return 0, None, type(getattr(e, "reason", e)).__name__


def _words(d: dict | None, key: str = "error", n: int = 120) -> str:
    v = d.get(key) if isinstance(d, dict) else ""
    return " ".join(str(v or "").split())[:n].replace("ssp_", "ssp-")


def enroll_key(priv, base: str) -> tuple[int, dict | None, str]:
    return post_json(base, "/keys/enroll", {"public_key": b64u(public_raw(priv)), "label": LABEL, "sender": SENDER})


def make_claim(priv, aud: str, now: float | None = None) -> str:
    """The compact JWS the server trades for a pass: header {"alg":"EdDSA"}, payload iss (the fingerprint), aud, iat, exp = iat + 55, jti (random, 32 characters)."""
    now = int(time.time() if now is None else now)
    head = b64u(json.dumps({"alg": "EdDSA"}, separators=(",", ":")).encode("ascii"))
    body = b64u(json.dumps({"iss": fingerprint(priv), "aud": aud, "iat": now, "exp": now + CLAIM_LIFE, "jti": secrets.token_urlsafe(24)},
                           separators=(",", ":")).encode("ascii"))
    claim = "%s.%s.%s" % (head, body, b64u(priv.sign(("%s.%s" % (head, body)).encode("ascii"))))
    if len(claim) > CLAIM_MAX:
        raise KeyProblem("the claim is longer than the server takes")
    return claim


def trade(priv, base: str) -> tuple[str, str, float, str]:
    """Trade a fresh claim for a pass -> (kind, pass, expires epoch, detail). kind: pass | pending | unknown | refused | unreachable | error. Only kind `pass` has a pass."""
    t0 = time.time()
    try:
        claim = make_claim(priv, base, t0)
    except KeyProblem as e:
        return "error", "", 0.0, str(e)
    st, d, why = post_json(base, "/keys/pass", {"claim": claim})
    if st == 0:
        return "unreachable", "", 0.0, "the server was not reached (%s)" % (why or "no answer")
    if st == 200 and isinstance(d, dict) and isinstance(d.get("pass"), str) and d["pass"].startswith(PASS_PREFIX):
        try:
            life = float(d.get("expires_in") or 600)
        except (TypeError, ValueError):
            life = 600.0
        return "pass", d["pass"], t0 + max(1.0, min(life, 3600.0)), ""
    state = _words(d, "state", 20)
    if st == 403 and state == "pending":
        return "pending", "", 0.0, "the key is still waiting for the owner's approval"
    if st == 403:
        return "unknown", "", 0.0, "the server does not trust this key (not enrolled, revoked, or not approved yet)"
    return "refused", "", 0.0, "the server answered HTTP %d%s" % (st, (": " + _words(d)) if _words(d) else "")


# ---- the log, at most one line per five minutes -----------------------------------------------------------------------------------
def _state_dir() -> str:
    return os.environ.get("SALA_STATE_DIR") or os.path.join(state_home(), "salamander")


def _log_dir() -> str:
    v = os.environ.get("SALA_LOG_DIR") or os.path.join(_home(), ".claude")
    return v if os.path.isabs(v) else os.path.join(_home(), v)


def note(why: str, now: float | None = None) -> None:
    """One line in salamander-stackshot-key.log saying why no pass was used; at most one per LOG_GAP seconds. Never raises, never holds a secret."""
    try:
        now = time.time() if now is None else now
        mark = os.path.join(_state_dir(), "stackshot-key-logged")
        try:
            if 0 <= now - os.stat(mark).st_mtime < LOG_GAP:
                return
        except OSError:
            pass
        os.makedirs(os.path.dirname(mark), exist_ok=True)
        with open(mark, "w", encoding="utf-8"):
            pass
        os.utime(mark, (now, now))
        os.makedirs(_log_dir(), exist_ok=True)
        stamp = time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now))
        with open(os.path.join(_log_dir(), "salamander-stackshot-key.log"), "a", encoding="utf-8") as f:
            f.write("[%s] no pass used (the machine token goes instead): %s\n" % (stamp, " ".join(why.split())[:300]))
    except OSError:
        pass


# ---- the pass cache -------------------------------------------------------------------------------------------------------------
def _cache_paths() -> tuple[str, str, str, str] | None:
    d = pass_dir()
    if not _private_dir(d):
        return None
    return d, os.path.join(d, "stackshot-pass"), os.path.join(d, "stackshot-pass.lock"), os.path.join(d, "stackshot-pass.failed")


def _read_cache(path: str, fp: str, aud: str, now: float) -> str:
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        with os.fdopen(fd, "rb") as f:
            st = os.fstat(f.fileno())
            if st.st_uid != os.getuid() or st.st_mode & 0o077:
                return ""
            d = json.loads(f.read(4096).decode("utf-8"))
        if d.get("fp") == fp and d.get("aud") == aud and isinstance(d.get("pass"), str) and d["pass"].startswith(PASS_PREFIX) and float(d["exp"]) - now > REUSE_MARGIN:
            return d["pass"]
    except Exception:
        pass
    return ""


def _write_cache(path: str, fp: str, aud: str, pw: str, exp: float) -> None:
    tmp = "%s.%d.%s" % (path, os.getpid(), secrets.token_hex(4))
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(json.dumps({"fp": fp, "aud": aud, "pass": pw, "exp": exp}).encode("utf-8"))
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def forget_pass() -> None:
    paths = _cache_paths()
    if paths:
        for p in (paths[1], paths[3]):
            try:
                os.unlink(p)
            except OSError:
                pass


def get_pass() -> str | None:
    """A pass for the form's calls (from the cache, else traded), or None: then the caller uses the machine token as it always did. Never raises; one log line per five
    minutes at most says why there was none. SALA_STACKSHOT_PASS=off is a silent None."""
    if pass_off():
        return None
    try:
        return _get_pass()
    except Exception as e:     # a pass is a convenience: nothing here may stop a call that worked before
        note("the pass step failed (%s)" % type(e).__name__)
        return None


def _get_pass() -> str | None:
    try:
        priv = load_private()
        fp = fingerprint(priv)
    except KeyProblem as e:
        note(str(e))
        return None
    base = server_url()
    if not base:
        note("no stackshot server address on this machine")
        return None
    paths = _cache_paths()
    lock = None
    try:
        if paths:
            lock = os.open(paths[2], os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
            end = time.time() + 12
            while True:      # one trader at a time: the others find its pass in the cache
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except OSError:
                    if time.time() > end:
                        break
                    time.sleep(0.05)
            hit = _read_cache(paths[1], fp, base, time.time())
            if hit:
                return hit
            try:
                gap = _num_env("SALA_STACKSHOT_PASS_BACKOFF", BACKOFF)
                if time.time() - os.stat(paths[3]).st_mtime < gap:
                    return None      # a trade failed a moment ago and said why: not asked again yet
            except OSError:
                pass
        kind, pw, exp, detail = trade(priv, base)
        if kind == "pass":
            if paths:
                _write_cache(paths[1], fp, base, pw, exp)
                try:
                    os.unlink(paths[3])
                except OSError:
                    pass
            return pw
        note(detail)
        if paths:
            try:
                with open(paths[3], "w", encoding="utf-8"):
                    pass
                os.utime(paths[3], None)
            except OSError:
                pass
        return None
    finally:
        if lock is not None:
            os.close(lock)      # closing releases the flock


# ---- the verbs ------------------------------------------------------------------------------------------------------------------
def _fail(msg: str, rc: int = 1) -> int:
    print("stackshot-key: " + msg, file=sys.stderr)
    return rc


def cmd_init() -> int:
    try:
        made = make_key()
        priv = load_private()
    except KeyProblem as e:
        return _fail(str(e))
    print("key: %s (%s)" % ("made" if made else "already there", short(fingerprint(priv))))
    return 0


def cmd_enroll() -> int:
    try:
        made = make_key()
        priv = load_private()
    except KeyProblem as e:
        return _fail(str(e))
    base = server_url()
    if not base:
        return _fail("no stackshot server address on this machine (STACKSHOT_URL, or client.url beside stackshot's token)")
    st, d, why = enroll_key(priv, base)
    fp = short(fingerprint(priv))
    if st == 0:
        return _fail("the server was not reached (%s); the key is %s and the same command can be run again" % (why or "no answer", "made" if made else "kept"))
    if st != 200 or not isinstance(d, dict) or d.get("state") not in ("pending", "approved"):
        return _fail("the server refused the enroll (HTTP %d%s)" % (st, (": " + _words(d)) if _words(d) else ""))
    forget_pass()
    item = str(d.get("item") or "")
    print("state: %s" % d["state"])
    print("key: %s" % fp)
    if d["state"] == "pending":
        print("item: %s" % (item if item else "none raised (the server names no project for it)"))
        print("next: the owner approves it on that item" if item else "next: the owner approves it on the server's command line")
    else:
        print("item: none (already approved)")
        print("next: nothing; the New session form's calls use a pass now")
    return 0


def cmd_status() -> int:
    try:
        priv = load_private()
    except KeyProblem as e:
        print("key: none")
        print("detail: %s" % e)
        return 0
    print("key: present")
    print("fingerprint: %s" % short(fingerprint(priv)))
    base = server_url()
    if not base:
        print("server: unknown (no stackshot server address on this machine)")
        return 0
    kind, pw, exp, detail = trade(priv, base)
    if kind == "pass":
        paths = _cache_paths()
        if paths:
            _write_cache(paths[1], fingerprint(priv), base, pw, exp)
        print("server: approved")
    elif kind == "pending":
        print("server: pending")
    else:
        print("server: unknown%s" % ((" (" + detail + ")") if detail else ""))
    return 0


def cmd_form_pass() -> int:
    if sys.stdout.isatty():
        return _fail("a pass is not printed to a terminal", 2)
    pw = get_pass()
    if not pw:
        return 1
    sys.stdout.write(pw + "\n")
    return 0


def main(argv: list[str]) -> int:
    verbs = {"init": cmd_init, "enroll": cmd_enroll, "status": cmd_status, "form-pass": cmd_form_pass, "forget-pass": lambda: (forget_pass(), 0)[1]}
    if len(argv) != 2 or argv[1] not in verbs:
        print("usage: stackshot_key.py init | enroll | status | form-pass | forget-pass", file=sys.stderr)
        return 2
    return verbs[argv[1]]()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
