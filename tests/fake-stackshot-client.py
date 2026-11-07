#!/usr/bin/env python3
"""A fake stackshot client.py for tests/boardseam.sh and tests/op.sh: the verbs sala calls (`post question`, `get answer`, `event`), with the
limits the real ones enforce (stackshot's own: client.py and server.py _question / _gate_options / render.parse_ask), so a script
that would be refused by the board is refused here. No network, no board.

  post question --project P --subject S --request-id T --ask A [--option L=LINE …] [--recommended L] [--sender X]   (text on stdin)
      refuses (exit 1, reason on stderr): more than 5 non-blank lines or 8000 characters; an ask that is not one line of at most 240
      characters in the form "Decide: … · Recommend: … · Stakes: … · By: …" with " · " or ";" inside the Decide part; a subject over 80
      characters or without a "[scope] " bracket; options not 2 to 6, a label over 40 characters or with "=", a line over 160, two
      labels alike, not exactly one recommended; an empty text. Otherwise prints board#N; the same (sender, request id) prints the
      same N and files nothing; N counts from 9001 (an invented range). FAKE_CLIENT_FAIL=1 refuses everything (exit 1, "refused").
  get answer board#N    prints $FAKE_CLIENT_DIR/answers/<N> as it is (one line, kind TAB label TAB text TAB when), nothing when the file
      is absent; FAKE_CLIENT_FAIL=1 exits 1.
  event --kind recycle|fleet_op|job_run [--machine M] [--verb V] [--name N] [--sessions N] [--result R] [--text T]
      as event_waits.event_from_report takes it: refuses (exit 1) an unknown kind, a fleet_op with no verb of lower-case letters, digits, _ and -,
      a job_run with no name, a machine that is not a name, sessions that are not a whole number; result over 80 or text over 240 characters.
      Otherwise prints "stackshot: <kind> reported; no item was waiting on it". FAKE_CLIENT_FAIL=1 refuses it (exit 1); FAKE_CLIENT_HANG=<secs>
      sleeps that long first, whatever the verb (a client that does not answer).
Every call is appended to $FAKE_CLIENT_DIR/calls.jsonl (argv and stdin); filed items to $FAKE_CLIENT_DIR/items.json."""
import json, os, re, sys, time

D = os.environ["FAKE_CLIENT_DIR"]
a = sys.argv[1:]
os.makedirs(os.path.join(D, "answers"), exist_ok=True)
text = sys.stdin.read() if a[:2] == ["post", "question"] else ""
with open(os.path.join(D, "calls.jsonl"), "a") as f:
    f.write(json.dumps({"argv": a, "stdin": text}) + "\n")


def refuse(why):
    print("stackshot: question not filed [400] " + why, file=sys.stderr); sys.exit(1)


if os.environ.get("FAKE_CLIENT_HANG"):
    time.sleep(float(os.environ["FAKE_CLIENT_HANG"]))
if os.environ.get("FAKE_CLIENT_FAIL") == "1":
    print("stackshot: refused (FAKE_CLIENT_FAIL)", file=sys.stderr); sys.exit(1)
if a[:1] == ["event"]:
    ev, rest = {}, a[1:]
    while rest:
        k = rest.pop(0)
        if not k.startswith("--") or not rest or k[2:] not in ("kind", "machine", "verb", "name", "sessions", "result", "text"):
            print("usage: client.py event --kind recycle|fleet_op|job_run [--machine M] [--verb V] [--name N] [--sessions N] [--result R] [--text T]", file=sys.stderr); sys.exit(1)
        ev[k[2:]] = rest.pop(0)
    bad = None
    if ev.get("kind") not in ("recycle", "fleet_op", "job_run"): bad = "kind is one of recycle | fleet_op | job_run"
    elif ev["kind"] == "fleet_op" and not re.fullmatch(r"[a-z][a-z0-9_-]{0,39}", ev.get("verb", "")): bad = "a fleet_op report names the op: verb"
    elif ev["kind"] == "job_run" and not re.fullmatch(r"[A-Za-z0-9][\w.@:-]{0,79}", ev.get("name", "")): bad = "a job_run report names the job: name"
    elif ev.get("machine") and not re.fullmatch(r"[A-Za-z0-9][\w.@:-]{0,79}", ev["machine"]): bad = "machine is not a machine name"
    elif ev.get("sessions", "0") != "" and not re.fullmatch(r"[0-9]+", ev.get("sessions", "0")): bad = "sessions is a whole number"
    elif len(ev.get("result", "")) > 80 or len(ev.get("text", "")) > 240: bad = "result or text too long"
    if bad:
        print("stackshot: event not reported [400] " + bad); sys.exit(1)
    print("stackshot: %s reported; no item was waiting on it" % ev["kind"]); sys.exit(0)
if a[:2] == ["get", "answer"]:
    p = os.path.join(D, "answers", re.sub(r"\D", "", a[2] if len(a) > 2 else ""))
    if os.path.isfile(p): sys.stdout.write(open(p).read())
    sys.exit(0)
if a[:2] != ["post", "question"]:
    print("fake client: unknown verb", file=sys.stderr); sys.exit(2)
opt, options, rest = {}, [], a[2:]
while rest:
    k = rest.pop(0)
    if not k.startswith("--") or not rest: refuse("misused: " + k)
    v = rest.pop(0)
    if k == "--option": options.append(v)
    else: opt[k[2:]] = v
for k in ("project", "subject", "request-id", "ask"):
    if not opt.get(k, "").strip(): refuse("--%s is required" % k)
lines = [l for l in text.splitlines() if l.strip()]
if not lines: refuse("the question's text is empty")
if len(lines) > 5: refuse("the question's text has %d lines and an item's description takes at most 5" % len(lines))
if len(text.strip()) > 8000: refuse("the question's text has %d characters and at most 8000 are taken" % len(text.strip()))
if not re.match(r"\[[a-z0-9._-]+\] ", opt["subject"]) or len(opt["subject"]) > 80: refuse("the subject needs a prefix and at most 80 characters")
ask = opt["ask"]
m = re.fullmatch(r"Decide: (?P<d>\S.*?) · Recommend: (?P<r>\S.*?) · Stakes: (?P<s>\S.*?) · By: (?P<b>\S.*)", ask.strip())
if len(ask.strip()) > 240 or "\n" in ask or not m: refuse("ask must read Decide: … · Recommend: … · Stakes: … · By: … in one line of at most 240 characters")
if " · " in m["d"] or ";" in m["d"] or len(re.findall(r"\b(Decide|Recommend):", ask)) != 2: refuse("the ask has several decisions")
opts = []
for o in options:
    label, eq, line = o.partition("=")
    if not eq or not label.strip() or not line.strip(): refuse("--option is not <label>=<line>")
    opts.append({"label": label.strip(), "line": line.strip(), "recommended": False})
if opts:
    if not 2 <= len(opts) <= 6: refuse("options takes 2 to 6 entries")
    if len({o["label"].lower() for o in opts}) != len(opts): refuse("two options are labelled alike")
    for o in opts:
        if len(o["label"]) > 40 or len(o["line"]) > 160: refuse("option %s is too long" % o["label"])
    rec = opt.get("recommended", "").strip().lower()
    hit = [o for o in opts if o["label"].lower() == rec]
    if len(hit) != 1: refuse("exactly one option is recommended")
    hit[0]["recommended"] = True
elif opt.get("recommended"): refuse("--recommended without options")
ip = os.path.join(D, "items.json")
items = json.load(open(ip)) if os.path.exists(ip) else {"map": {}, "n": 0}
key = "%s\x1f%s" % (opt.get("sender", "client.py"), opt["request-id"])
if key not in items["map"]:
    items["n"] += 1; items["map"][key] = items["n"]
json.dump(items, open(ip, "w"))
print("board#%d" % (9000 + items["map"][key]))   # ids start at 9001 (an invented range)
