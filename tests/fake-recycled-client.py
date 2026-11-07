#!/usr/bin/env python3
"""A strict fake of stackshot's `client.py recycled` for tests/flags.sh, tests/sets.sh and tests/autorecycle.sh: the post-recycle hook
as sala fires it (docs/stackshot-contracts.md, interface 4). Like the real client it reads its input from the environment
(SALA_RECYCLE_ prefix) and exits 0 always, so a recycle never fails on it, but it REFUSES a call the real side would mis-read and says
so in $FAKE_RECYCLED_LOG as a BAD line, which the suites fail on:

  SALA_RECYCLE_KIND      recycle | reboot
  SALA_RECYCLE_STARTED   the flag's time, epoch seconds (digits only)
  SALA_RECYCLE_FLAG_AT   the same epoch, the name stackshot reads it by (digits only; must equal STARTED)
  SALA_RECYCLE_RESULT    ok when SKIPPED is empty, partial when it is not
  SALA_RECYCLE_SKIPPED   tmux session names, space-separated, no repeats (letters, digits, . _ -)

Each good call is one JSON line {"kind", "started", "flag_at", "result", "skipped": [...]}: the body the real client posts to
/client/recycled (plus flag_at). Prints stackshot's one answer line. $FAKE_RECYCLED_LOG is required."""
import json, os, re, sys

log = os.environ["FAKE_RECYCLED_LOG"]
e = os.environ.get
bad = []
kind, started, flag_at, result, skipped = (e("SALA_RECYCLE_" + k, "") for k in ("KIND", "STARTED", "FLAG_AT", "RESULT", "SKIPPED"))
names = skipped.split()
if kind not in ("recycle", "reboot"): bad.append("kind %r" % kind)
if not re.fullmatch(r"[0-9]+", started): bad.append("started %r" % started)
if not re.fullmatch(r"[0-9]+", flag_at): bad.append("flag_at %r" % flag_at)
elif started != flag_at: bad.append("flag_at %s is not started %s" % (flag_at, started))
if result not in ("ok", "partial"): bad.append("result %r" % result)
if (result == "ok") != (not names): bad.append("result %s with skipped %r" % (result, skipped))
if len(set(names)) != len(names) or any(not re.fullmatch(r"[A-Za-z0-9_.-]+", n) for n in names): bad.append("skipped %r" % skipped)
with open(log, "a") as f:
    if bad: f.write("BAD " + "; ".join(bad) + "\n")
    else: f.write(json.dumps({"kind": kind, "started": int(started), "flag_at": int(flag_at), "result": result, "skipped": names}) + "\n")
print("stackshot: 0 item(s) no longer wait for a recycle (none)" if not bad else "stackshot: recycle not reported [400] " + "; ".join(bad))
sys.exit(0)
