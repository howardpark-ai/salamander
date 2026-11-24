#!/usr/bin/env python3
"""lib/pauseinfo.py — what a session was doing when a relaunch paused its turn (the words of its resume note).

  pauseinfo.py <transcript.jsonl>
  pauseinfo.py inbox <inbox dir> <session> <conversation id>

The second form lists the lines waiting in stackshot's inbox for that session (`inbox<TAB>sender<TAB>first line`, sender and first line only,
at most 6, oldest first); the first form is described next.

Reads the END of one session transcript (the last 4 MB) and prints, one per line, tab separated:

  trigger<TAB><the last line a person or a notice typed into the session>     (cut to 160, scrubbed; absent when none is found)
  pending<TAB><Tool>: <description>        a tool call of the running turn that has no result yet (a foreground subagent, a shell, a monitor)
  started<TAB><Tool>: <description>        a call of the running turn that went to the background (run_in_background, or a Monitor)

Descriptions only. A tool call's `description` field is the session's own one-line label for it ("Build page-creation PR for copy
switch"); the call's command, prompt and every tool RESULT stay unread and unprinted. A call with no description is named by its tool
alone. The turn is everything after the last human line, so a call an earlier turn left unanswered is not listed. Read-only; any
failure prints nothing and exits 0 (a note without detail is still a note). SALA_SCRUB_PY (lib/common.sh) masks anything that looks
like a secret in the printed text, the way lib/holders.py does.
"""
import json
import os
import sys

TAIL = 4 * 1024 * 1024
MAX_LINES = 12


def env_scrub():
    src = os.environ.get("SALA_SCRUB_PY")
    if src:
        ns = {}
        try:
            exec(src, ns)
            return ns["scrub"]
        except Exception:
            pass
    return lambda t: t


SCRUB = env_scrub()


def clean(s, n):
    s = " ".join(str(s).split())
    s = SCRUB(s)
    return s if len(s) <= n else s[: n - 1] + "…"


def human_text(msg):
    """The text of a user record a person or a notice typed, else ''. A tool result and an injected reminder are not it."""
    c = msg.get("content")
    if isinstance(c, str):
        t = c
    elif isinstance(c, list):
        if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in c):
            return ""
        t = " ".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text")
    else:
        return ""
    t = t.strip()
    if not t or t.startswith(("<system-reminder", "<command-", "<local-command", "<task-notification", "Caveat:")):
        return ""
    return t


def main(path):
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            if size > TAIL:
                f.seek(size - TAIL)
                f.readline()   # a line cut by the seek
            raw = f.read().decode("utf-8", "replace").splitlines()
    except Exception:
        return
    trigger = ""
    calls = {}      # tool_use id -> [name, description, background, answered]
    order = []
    for line in raw:
        try:
            o = json.loads(line)
        except Exception:
            continue
        if not isinstance(o, dict) or o.get("isSidechain"):
            continue
        msg = o.get("message")
        if not isinstance(msg, dict):
            continue
        if o.get("type") == "user":
            t = human_text(msg)
            if t:
                trigger = t
                calls, order = {}, []   # a new turn: what an older one left unanswered is not in flight
                continue
            c = msg.get("content")
            if isinstance(c, list):
                for b in c:
                    if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("tool_use_id") in calls:
                        calls[b["tool_use_id"]][3] = True
        elif o.get("type") == "assistant":
            c = msg.get("content")
            if not isinstance(c, list):
                continue
            for b in c:
                if not (isinstance(b, dict) and b.get("type") == "tool_use" and b.get("id")):
                    continue
                inp = b.get("input") if isinstance(b.get("input"), dict) else {}
                d = inp.get("description")
                name = str(b.get("name") or "tool")
                bg = bool(inp.get("run_in_background")) or name == "Monitor"
                calls[b["id"]] = [name, d if isinstance(d, str) else "", bg, False]
                order.append(b["id"])
    out = []
    if trigger:
        out.append("trigger\t" + clean(trigger, 160))
    pend = [calls[i] for i in order if not calls[i][3]]
    back = [calls[i] for i in order if calls[i][3] and calls[i][2]]
    for kind, rows in (("pending", pend), ("started", back)):
        for name, d, _, _ in rows[-MAX_LINES:]:
            out.append("%s\t%s" % (kind, clean(name + (": " + d if d else ""), 110)))
    sys.stdout.write("\n".join(out) + ("\n" if out else ""))


def inbox(root, sess, uuid):
    """The lines waiting in stackshot's inbox for this session (hub/ and msg/ under root; one JSON file each, routed by to, uuid or name
    EQUAL to the session or its conversation): sender and first line only, oldest first, at most MAX_MSGS."""
    import glob
    want = {w for w in (sess, uuid) if w}
    rows = []
    for kind in ("hub", "msg"):
        for f in glob.glob(os.path.join(root, kind, "*.json")):
            try:
                with open(f, encoding="utf-8") as fh:
                    d = json.load(fh)
            except Exception:
                continue
            if not isinstance(d, dict) or not any(isinstance(d.get(k), str) and d[k] in want for k in ("to", "uuid", "name")):
                continue
            text = d.get("text")
            first = ""
            if isinstance(text, str):
                for ln in text.splitlines():
                    if ln.strip():
                        first = ln.strip()
                        break
            sender = d.get("from") if isinstance(d.get("from"), str) and d.get("from") else (d.get("src") if isinstance(d.get("src"), str) else "")
            ts = d.get("ts") if isinstance(d.get("ts"), (int, float)) else 0
            rows.append((ts, clean(sender, 40), clean(first, 120)))
    rows.sort()
    for _, sender, first in rows[:MAX_MSGS]:
        sys.stdout.write("inbox\t%s\t%s\n" % (sender, first))
    if len(rows) > MAX_MSGS:
        sys.stdout.write("inbox\t(and %d more)\t\n" % (len(rows) - MAX_MSGS))


MAX_MSGS = 6


if __name__ == "__main__":
    try:
        if len(sys.argv) == 2:
            main(sys.argv[1])
        elif len(sys.argv) == 5 and sys.argv[1] == "inbox":
            inbox(sys.argv[2], sys.argv[3], sys.argv[4])
    except Exception:
        pass
    sys.exit(0)
