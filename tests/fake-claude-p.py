#!/usr/bin/env python3
"""A fake `claude -p` for tests/parkedq.sh: it behaves as Claude Code 2.1.307 does in the one corner the parked-question flow uses
(verified against the real CLI, Thu Oct 22nd 2026). No network, no model.

  claude -p [--resume SID] --output-format json --mcp-config J --permission-prompt-tool T --settings J [--model M] [--permission-mode M]
  the prompt on stdin (empty for a resume)

A new run "calls" the tool named by FAKE_TOOL (default AskUserQuestion) with the input FAKE_INPUT (JSON; default one question). The
tool is offered only when --permission-prompt-tool is given (a -p run without a permission host is not offered AskUserQuestion: the
result is a plain sentence). The PreToolUse hooks of --settings run for the call, with the payload Claude Code sends them, in this
process's environment: a "defer" ends the turn with terminal_reason tool_deferred and deferred_tool_use (FAKE_SHAPE=legacy: stop_reason
tool_deferred instead, the shape this fake first guessed; see result()); an "allow" runs the call (the
result says ALLOWED and the answers the hook put in updatedInput); a "deny" ends with DENIED and the reason; no output at all is the
normal permission flow, which a host with nobody behind it denies (HOST-DENIED). A resume replays the stored call: the same
tool_use_id fires the hooks again. FAKE_SECOND=1 makes a resume that was allowed go on to a second AskUserQuestion. Every call is
appended to FAKE_LOG (argv, SALA_DEFER_QUESTIONS, cwd, PATH); sessions live under FAKE_DIR.
Noise and failure for the tests: FAKE_STDERR=text prints that line on stderr before the result (a hook or node warning); FAKE_STDOUT_PRE=text prints
it on stdout before the result JSON; FAKE_FAIL=text prints it on stderr and exits 1 with nothing on stdout (a run that really failed)."""
import json, os, re, subprocess, sys, uuid

a = sys.argv[1:]


def opt(name, default=None):
    return a[a.index(name) + 1] if name in a and a.index(name) + 1 < len(a) else default


log, base = os.environ["FAKE_LOG"], os.environ["FAKE_DIR"]
os.makedirs(os.path.join(base, "sessions"), exist_ok=True)
prompt = sys.stdin.read()
with open(log, "a") as f:
    f.write(json.dumps({"argv": a, "defer_env": os.environ.get("SALA_DEFER_QUESTIONS"), "label": os.environ.get("SALA_QUESTION_LABEL"), "cwd": os.getcwd(), "prompt": prompt, "path": os.environ.get("PATH")}) + "\n")
if os.environ.get("FAKE_FAIL"):
    print(os.environ["FAKE_FAIL"], file=sys.stderr); sys.exit(1)
if "-p" not in a:
    print("fake claude: only -p is faked", file=sys.stderr); sys.exit(2)

DEFAULT = {"questions": [{"question": "Pick a colour?", "header": "Colour", "options": [{"label": "Red", "description": "r"}, {"label": "Blue", "description": "b"}], "multiSelect": False}]}
resume = opt("--resume")
host = opt("--permission-prompt-tool")
pmode = opt("--permission-mode", "default")
sf = lambda sid: os.path.join(base, "sessions", sid + ".json")


def result(sid, text="", stop="end_turn", deferred=None, err=False):
    # FAKE_SHAPE=real (the default): the shape the real CLI printed for a deferral on the first real run (Claude Code 2.1.307, haiku,
    # Thu Oct 22nd 2026): terminal_reason "tool_deferred" and deferred_tool_use, and NO stop_reason key.
    # FAKE_SHAPE=legacy: the shape this fake first emitted, stop_reason "tool_deferred" (no terminal_reason), kept so both stay covered.
    legacy = os.environ.get("FAKE_SHAPE") == "legacy"
    o = {"type": "result", "subtype": "success", "is_error": err, "num_turns": 1, "result": text, "session_id": sid, "permission_denials": [], "uuid": str(uuid.uuid4())}
    if legacy: o["stop_reason"] = stop
    elif deferred: o["terminal_reason"] = "tool_deferred"
    else: o["stop_reason"] = stop; o["terminal_reason"] = "completed"
    if deferred: o["deferred_tool_use"] = deferred
    if os.environ.get("FAKE_STDERR"): print(os.environ["FAKE_STDERR"], file=sys.stderr)
    if os.environ.get("FAKE_STDOUT_PRE"): print(os.environ["FAKE_STDOUT_PRE"])
    print(json.dumps(o)); sys.exit(0)


def run_hooks(tool, tuid, tin):
    s = json.loads(opt("--settings") or "{}")
    decision = None
    for ent in s.get("hooks", {}).get("PreToolUse", []):
        if not re.fullmatch(ent.get("matcher", ".*"), tool): continue
        for h in ent.get("hooks", []):
            payload = {"session_id": cur["sid"], "cwd": os.getcwd(), "permission_mode": pmode, "hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": tin, "tool_use_id": tuid}
            p = subprocess.run(["sh", "-c", h["command"]], input=json.dumps(payload), capture_output=True, text=True)
            try: decision = json.loads(p.stdout)["hookSpecificOutput"]
            except Exception: pass
    return decision


cur = {}
if resume:
    if not os.path.exists(sf(resume)):
        result(resume, "No conversation found with session ID: " + resume, err=True)
    cur = json.load(open(sf(resume))); cur["sid"] = resume
else:
    cur = {"sid": os.environ.get("FAKE_SID") or str(uuid.uuid4()), "tool": os.environ.get("FAKE_TOOL", "AskUserQuestion"),
           "tuid": "toolu_" + uuid.uuid4().hex[:20], "input": json.loads(os.environ.get("FAKE_INPUT") or json.dumps(DEFAULT))}
    json.dump(cur, open(sf(cur["sid"]), "w"))
sid, tool, tuid, tin = cur["sid"], cur["tool"], cur["tuid"], cur["input"]
if tool == "AskUserQuestion" and not host:
    result(sid, "I could not call AskUserQuestion: it is not among the tools available in this session.")
d = run_hooks(tool, tuid, tin)
dec = (d or {}).get("permissionDecision")
if dec == "defer":
    result(sid, "", stop="tool_deferred", deferred={"id": tuid, "name": tool, "input": tin})
if dec == "allow":
    upd = d.get("updatedInput")
    if os.environ.get("FAKE_SECOND") == "1" and resume:
        cur["tuid"] = "toolu_" + uuid.uuid4().hex[:20]; cur["input"] = {"questions": [{"question": "Which size?", "header": "Size", "options": [{"label": "S", "description": "s"}, {"label": "L", "description": "l"}], "multiSelect": False}]}
        json.dump(cur, open(sf(sid), "w"))
        d2 = run_hooks(tool, cur["tuid"], cur["input"])
        if (d2 or {}).get("permissionDecision") == "defer":
            result(sid, "", stop="tool_deferred", deferred={"id": cur["tuid"], "name": tool, "input": cur["input"]})
    result(sid, "ALLOWED " + (json.dumps(upd.get("answers"), sort_keys=True) if isinstance(upd, dict) and "answers" in upd else "as asked"))
if dec == "deny":
    result(sid, "DENIED " + (d.get("permissionDecisionReason") or ""))
result(sid, "HOST-DENIED the host denied the call: nobody answers a background run")
