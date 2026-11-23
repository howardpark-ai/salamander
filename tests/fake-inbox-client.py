#!/usr/bin/env python3
"""A fake stackshot client.py for the inbox-hold calls (tests/inboxserver.sh, tests/sleeping.sh, tests/sleepverbs.sh): the four calls of docs/stackshot-contracts.md
interface 3 as stackshot's server answers them (its docs/inbox-holds.md), kept in files of $FAKE_INBOX_DIR; no network, no stackshot.

  post inbox-hold KEY… [--kind msg|hub] [--minutes N]   {"held": {"msg": [keys], "hub": [keys]}, "expires": epoch|null}; the hold is kept with origin api and its time. Refused (400, exit 1)
                                                        as the server refuses: no key or more than 20, a bad key, a kind that is not msg or hub, minutes that is not above 0 and at most 1440
                                                        (0 included), and a source whose api holds would pass FAKE_INBOX_CAP (500) keys. Holding a held key is a refresh
  post inbox-release KEY… [--kind K]                    {"released": {"msg": [the keys that were held], "hub": […]}, "held_elsewhere": [keys]}; only the origin api rows go, a key that
                                                        another tool's file (origin file) or a reboot's resume (origin resume) still holds is named in held_elsewhere (left out when there is none)
  get inbox-holds [KEY]                                 {"holds": [{"kind", "key", "origin": api|file|resume, "since", "expires"}], "now": epoch}; a key held in two files has two rows
  get inbox-waiting NAME[,UUID]                         {"keys", "hub": n, "msg": n, "waiting": bool, "held": {"hub": bool, "msg": bool}} over $FAKE_INBOX_DIR/inbox/<hub|msg>/*.json
                                                        (a line whose to, uuid, name or pid equals a key counts, held or not; held = a key is held in that source, whatever the origin)
State: $FAKE_INBOX_DIR/holds.json ({"msg": [{"key", "origin", "since", "expires"}], "hub": […]}; a test seeds `file` and `resume` rows into it). Every call is appended to
$FAKE_INBOX_DIR/calls.log as one line, its argv joined by single spaces.
Failures, to play a server that does not answer: FAKE_INBOX_FAIL = a comma list of verbs (hold, release, holds, waiting) or `all`; FAKE_INBOX_HOW says how:
  down (default)  the way client.py fails to reach the server: post → `stackshot: <what> [0] URLError…` on stderr, get → `[0] URLError…` on stdout, exit 1
  e500, e401      the same with that status;  e404 the server (or the proxy before it) does not know the call;  e400 the server refuses the call (a bad key, kind or time)
  usage           a client from before the calls: its usage text on stdout, exit 1
  hang            sleeps 30 s (the caller's own timeout ends it)
  garbage         exit 0 and a line that is not JSON
  partial         (hold only) 200 with no key listed as held
  retry           exit 4, the retriable delivery error: the first FAKE_INBOX_RETRY_TIMES (default 1) times a call is made (counted in $FAKE_INBOX_DIR/retry.count), then it answers as usual
"""
import json, os, sys, time

D = os.environ["FAKE_INBOX_DIR"]
a = sys.argv[1:]
os.makedirs(D, exist_ok=True)
with open(os.path.join(D, "calls.log"), "a") as f:
    f.write(" ".join(a) + "\n")
SOURCES = ("msg", "hub")
VERB = {("post", "inbox-hold"): "hold", ("post", "inbox-release"): "release", ("get", "inbox-holds"): "holds", ("get", "inbox-waiting"): "waiting"}
verb = VERB.get(tuple(a[:2]))
STATE = os.path.join(D, "holds.json")
CAP = int(os.environ.get("FAKE_INBOX_CAP") or 500)


def load():
    try:
        d = json.load(open(STATE))
        return {s: list(d.get(s) or []) for s in SOURCES}
    except Exception:
        return {s: [] for s in SOURCES}


def save(st):
    json.dump(st, open(STATE, "w"))


def refuse(why, what):   # the server's 400, as the client prints it
    print("stackshot: %s [400] %s" % (what, why), file=sys.stderr)
    sys.exit(1)


fail = {x for x in os.environ.get("FAKE_INBOX_FAIL", "").split(",") if x}
if verb and ("all" in fail or verb in fail):
    how = os.environ.get("FAKE_INBOX_HOW", "down")
    what = {"hold": "hold not made", "release": "hold not lifted"}.get(verb, "")
    st = {"down": 0, "e500": 500, "e401": 401, "e404": 404, "e400": 400}.get(how)
    if how == "hang":
        time.sleep(30); sys.exit(1)
    if how == "garbage":
        print("ok"); sys.exit(0)
    if how == "usage":
        print("usage: client.py <verb> …  (the verbs of a client from before the inbox calls)"); sys.exit(1)
    if how == "retry":
        cf = os.path.join(D, "retry.count")
        n = int(open(cf).read()) if os.path.exists(cf) else 0
        if n < int(os.environ.get("FAKE_INBOX_RETRY_TIMES") or 1):
            open(cf, "w").write(str(n + 1))
            print("fake: delivery failed, try again", file=sys.stderr); sys.exit(4)
    elif how == "partial" and verb == "hold":
        print(json.dumps({"held": {"msg": [], "hub": []}, "expires": None})); sys.exit(0)
    elif st is not None:
        body = "URLError: <urlopen error [Errno 111] Connection refused>" if st == 0 else "refused (FAKE_INBOX_HOW=%s)" % how
        if a[0] == "post":
            print("stackshot: %s [%d] %s" % (what, st, body), file=sys.stderr)
        else:
            print("[%d] %s" % (st, body))
        sys.exit(1)

if verb is None:   # a word the fake does not know: what the real client does with one
    print("usage: client.py …"); sys.exit(1)

rest = a[2:]
opt = {}
for k in ("kind", "minutes"):
    if "--" + k in rest:
        i = rest.index("--" + k)
        if i + 1 >= len(rest):
            print("--%s needs a value" % k, file=sys.stderr); sys.exit(1)
        opt[k] = rest[i + 1]; del rest[i:i + 2]
now = time.time()
st = load()
what = {"hold": "hold not made", "release": "hold not lifted"}.get(verb, "")
if verb in ("hold", "release"):
    if not rest or any(not x.strip() or x.startswith("--") for x in rest):
        print("usage: client.py post inbox-%s <key> [<key> ...]" % verb, file=sys.stderr); sys.exit(1)
    if len(rest) > 20:
        refuse("keys is 1 to 20 keys", what)
    if any(len(x) > 200 or not x.isprintable() for x in rest):
        refuse("a key is one line of at most 200 printable characters", what)
    if opt.get("kind") and opt["kind"] not in SOURCES:
        refuse("kinds are hub and msg", what)
if verb == "hold":
    kinds = [opt["kind"]] if opt.get("kind") else list(SOURCES)
    if opt.get("minutes") not in (None, ""):
        try:
            mins = float(opt["minutes"])
        except ValueError:
            mins = -1.0
        if not 0 < mins <= 1440:
            refuse("minutes is more than 0 and at most 1440", what)
    else:
        mins = 10.0
    exp = now + mins * 60
    for s in kinds:
        have = {r["key"] for r in st[s] if r["origin"] == "api"}
        if len(have | set(rest)) > CAP:
            refuse("a source's api file holds at most %d keys" % CAP, what)
    for s in kinds:
        for k in rest:
            st[s] = [r for r in st[s] if not (r["key"] == k and r["origin"] == "api")] + [{"key": k, "origin": "api", "since": now, "expires": exp}]
    save(st)
    print(json.dumps({"held": {s: rest for s in kinds}, "expires": exp}))
elif verb == "release":
    kinds = [opt["kind"]] if opt.get("kind") else list(SOURCES)
    out, elsewhere = {}, []
    for s in kinds:
        out[s] = [k for k in rest if any(r["key"] == k and r["origin"] == "api" for r in st[s])]
        st[s] = [r for r in st[s] if not (r["key"] in rest and r["origin"] == "api")]
        elsewhere += [r["key"] for r in st[s] if r["key"] in rest and r["origin"] in ("file", "resume") and r["key"] not in elsewhere]
    save(st)
    ans = {"released": out}
    if elsewhere:
        ans["held_elsewhere"] = elsewhere
    print(json.dumps(ans))
elif verb == "holds":
    rows = [{"kind": s, "key": r["key"], "origin": r["origin"], "since": r.get("since"), "expires": r.get("expires")} for s in SOURCES for r in st[s]]
    if rest:
        rows = [r for r in rows if r["key"] == rest[0]]
    print(json.dumps({"holds": rows, "now": now}))
else:
    keys = [k for k in (rest[0].split(",") if rest else []) if k]
    if not keys or len(keys) > 20:
        print("[400] key = the session's name, or its name and transcript id separated by a comma"); sys.exit(1)
    n = {s: 0 for s in SOURCES}
    for s in SOURCES:
        d = os.path.join(D, "inbox", s)
        for fn in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            try:
                it = json.load(open(os.path.join(d, fn)))
            except Exception:
                continue
            if isinstance(it, dict) and any(str(it.get(f) or "") in keys for f in ("to", "uuid", "name", "pid")):
                n[s] += 1
    held = {s: any(r["key"] in keys for r in st[s]) for s in SOURCES}
    print(json.dumps({"keys": keys, "hub": n["hub"], "msg": n["msg"], "waiting": any(n.values()), "held": held}))
