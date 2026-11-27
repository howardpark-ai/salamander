"""Send now (POST /api/s/<pid>/send-now, sendnow.py) against made-up screens and transcripts: no tmux, no browser.

The screens are the layout Claude Code 2.1.332 draws while a message waits behind a running step (invented paths and words); the
transcript lines are the parts of its records the check reads. The one key the route may press is recorded, never made.

What a wrong answer costs: a command or a call cancelled (a hook still before it, a later call of a reply, background tasks off, a `!`
command), a draft submitted, a subagent's command lost. Held here: the chord is pressed once, and only, when the screen shows a waiting
message under the running step's background hint with an empty input line and no dialog, and the transcript's latest reply is complete
with exactly one call unfinished; every other screen and transcript answers 409 with its reason and presses nothing.
"""

from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
from types import SimpleNamespace

import pytest
from starlette.testclient import TestClient

import sala_web.app as AP
from sala_web import sendnow as SN
from sala_web import sessions as S
from sala_web import tmuxio as T
from sala_web import transcript as TR
from sala_web.app import create_app
from sala_web.config import Settings

FIX = Path(__file__).parent / "fixtures"
PANE = "%7"
SID = "aaaaaaaa-0000-0000-0000-000000000000"
NAME = "me"
RULE = "─" * 60
PROMPT = "❯"
CORNER = "⎿"
NBSP = "\xa0"
DOT = "●"

RUNNING = [f"{DOT} Waiting · 4s",
           f"  {CORNER}  $ python3 /srv/project/wait.py",
           "     (ctrl+b to run in background)"]
WAITING = [f"{PROMPT} one more thing", f"  {CORNER}  Queued · ctrl+x ctrl+s to send now"]
SPINNER = ["✻ Working… (5s · ↓ 5 tokens)", " " * 40 + "◐ medium · /effort"]
FOOT = ["  ⏸ manual mode on · esc to interrupt · ← for agents"]
PLACEHOLDER = f"{PROMPT}{NBSP}\x1b[2mPress up to edit queued messages\x1b[0m"


def screen(step=RUNNING, waiting=WAITING, under=SPINNER, box=PLACEHOLDER, foot=FOOT) -> str:
    return "\n".join([f"{PROMPT} run it", *step, *waiting, *under, RULE, box, RULE, *foot]) + "\n"


def hint(words: str) -> list[str]:
    return [*RUNNING[:2], f"     ({words} to run in background)"]


SAFE = {
    "a running command": screen(),
    "no placeholder in the empty line": screen(box=f"{PROMPT}{NBSP}"),
    "several messages, one of two lines": screen(waiting=[f"{PROMPT} first", f"{PROMPT} second", "  and its other line",
                                                          f"{PROMPT} /effort", WAITING[1]]),
    "a blank line above the messages": screen(waiting=["", *WAITING]),
    "inside a tmux with the Ctrl+B prefix": screen(step=hint("ctrl+b ctrl+b (twice)")),
    "a subagent in the foreground": screen(step=[f"{DOT} Agent(look)", f"  {CORNER}  Bash(python3 wait.py)", "     Running…",
                                                 RUNNING[2]],
                                           foot=[*FOOT, f"  {DOT} main", "  ◯ general-purpose  look   8s"]),
    "vim insert mode": screen(foot=["  -- INSERT -- ⏸ manual mode on · ← for agents"]),
    "the running step's dot between blinks": screen(step=["  Waiting · 3s", *RUNNING[1:]]),
    "an earlier ! command that has ended": screen(step=["! ls", f"  {CORNER}  notes.txt", *RUNNING]),
}

REFUSED = {
    "text in the input line": (screen(box=f"{PROMPT}{NBSP}half a thought"), SN.NOT_READY["draft"]),
    "no input line": ("Loading the conversation\n" * 3, SN.NOT_READY["noInput"]),
    "a permission dialog": ((FIX / "capture-dialog.txt").read_text(), SN.NOT_READY["dialog"]),
    "the model picker": ((FIX / "capture-overlay-model-picker.txt").read_text(), SN.NOT_READY["dialog"]),
    "the transcript view": ((FIX / "capture-overlay-transcript.txt").read_text(), SN.NOT_READY["dialog"]),
    "the empty ! mode": (screen(box=f"!{NBSP}"), "! mode"),
    "a subagent's own screen": (screen(box=f"{PROMPT}{NBSP}\x1b[2mMessage @general-purpose…\x1b[0m"), "subagent's own screen"),
    "a user's ! command running": (screen(step=["! sleep 60", f"  {CORNER}  Running… (4s)", RUNNING[2]]), SN.BANG),
    "a ! command waiting before the message": (screen(waiting=["! echo B > mark", *WAITING]), SN.BANG),
    "a ! command waiting after the message": (screen(waiting=[*WAITING, "! echo B > mark"]), SN.BANG),
    "nothing waiting": (screen(waiting=[]), SN.NO_QUEUED),
    "the action bound to another key": (screen(waiting=[WAITING[0], f"  {CORNER}  Queued · ctrl+enter to send now"]),
                                        SN.NO_QUEUED),
    "two Queued lines": (screen(waiting=[*WAITING, *WAITING]), SN.NO_QUEUED),
    "a hook before the call, or background tasks off": (screen(step=RUNNING[:2]), SN.NO_STEP),
    "an MCP tool running, which draws no hint": (screen(step=[f"{DOT} Calling slow " + chr(0xb7) + " 4s" + chr(0x2026)]), SN.NO_STEP),
    "the hint only further up, with a reply under it": (screen(step=[*RUNNING, f"{DOT} Now the next one."]), SN.NO_STEP),
    "the hint quoted inside a waiting message": (screen(step=RUNNING[:2],
                                                        waiting=[f"{PROMPT} it said", RUNNING[2], WAITING[1]]), SN.NO_STEP),
    "the hint with another key": (screen(step=hint("ctrl+y")), SN.NO_STEP),
    "a call line between the hint and the message": (screen(step=[*RUNNING, f"{DOT} Write(w.1)"]), SN.NO_STEP),
}


@pytest.mark.parametrize("captured", SAFE.values(), ids=SAFE.keys())
def test_the_safe_screen_is_allowed(captured):
    assert SN.screen_refusal(captured) is None


@pytest.mark.parametrize("captured, why", REFUSED.values(), ids=REFUSED.keys())
def test_every_other_screen_is_refused_with_its_reason(captured, why):
    got = SN.screen_refusal(captured)
    assert got and why in got and got.endswith(SN.NOTHING), got


# --- the transcript ---------------------------------------------------------------------------------------------------------

def said(text: str) -> dict:
    return {"type": "user", "message": {"role": "user", "content": text}}


def call(cid: str, mid: str = "m1", stop: str | None = "tool_use", **more) -> dict:
    return {"type": "assistant", "message": {"id": mid, "stop_reason": stop, "content": [
        {"type": "tool_use", "id": cid, "name": "Bash", "input": {}}]}, **more}


def words(mid: str = "m1", stop: str = "end_turn") -> dict:
    return {"type": "assistant", "message": {"id": mid, "stop_reason": stop, "content": [{"type": "text", "text": "Done."}]}}


def result(cid: str) -> dict:
    return {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": cid, "content": "ok"}]}}


QUEUE = {"type": "queue-operation", "operation": "enqueue", "content": "one more thing"}
ONE_STEP = [said("run it"), call("a"), QUEUE]

ALLOWED_LINES = {
    "one call running": ONE_STEP,
    "an earlier step finished": [said("go"), call("a", "m1"), result("a"), call("b", "m2"), QUEUE],
    "the second of two calls running, the first finished between them": [said("go"), call("a"), result("a"), call("b"), QUEUE],
    "a subagent's own lines do not count": [*ONE_STEP, call("s", "sub", isSidechain=True)],
    "lines Claude Code adds for itself do not end the turn": [*ONE_STEP, {**said("<reminder>"), "isMeta": True},
                                                              {"type": "attachment", "attachment": {}}],
}

REFUSED_LINES = {
    "nothing yet": [said("go")],
    "a reply being written, the step before it finished": [said("go"), call("a"), result("a"), QUEUE],
    "a reply being written, nothing before it": [said("go"), words(), said("more"), QUEUE],
    "two calls unfinished": [said("go"), call("a"), call("b")],
    "every call finished": [said("go"), call("a"), result("a")],
    "a reply with no stop reason yet": [said("go"), call("a", stop=None)],
    "an interrupt after the call": [*ONE_STEP, said("[Request interrupted by user for tool use]")],
    "a text reply after the call": [*ONE_STEP, words("m2")],
}


def write(path: Path, lines: list[dict], tail: str = "") -> Path:
    path.write_text("".join(json.dumps(d) + "\n" for d in lines) + tail)
    return path


@pytest.mark.parametrize("lines", ALLOWED_LINES.values(), ids=ALLOWED_LINES.keys())
def test_one_unfinished_call_of_a_complete_reply_is_allowed(tmp_path, lines):
    assert SN.transcript_refusal(write(tmp_path / "t.jsonl", lines)) is None


@pytest.mark.parametrize("lines", REFUSED_LINES.values(), ids=REFUSED_LINES.keys())
def test_every_other_transcript_is_refused(tmp_path, lines):
    assert SN.transcript_refusal(write(tmp_path / "t.jsonl", lines)) == SN.NOT_ONE_STEP


def test_a_line_half_written_or_no_file_is_refused(tmp_path):
    half = write(tmp_path / "t.jsonl", ONE_STEP, tail='{"type": "assistant", "mess')
    assert "being written" in SN.transcript_refusal(half)
    assert SN.transcript_refusal(tmp_path / "none.jsonl") == SN.NO_TRANSCRIPT
    assert SN.transcript_refusal(None) == SN.NO_TRANSCRIPT


def test_only_the_end_of_a_long_transcript_is_read(tmp_path, monkeypatch):
    path = write(tmp_path / "t.jsonl", [said("x" * 4000), *ONE_STEP])
    monkeypatch.setattr(SN, "TAIL_BYTES", 1000)
    assert SN.transcript_refusal(path) is None
    monkeypatch.setattr(SN, "TAIL_BYTES", 20)       # the call itself is out of reach: refused, never guessed
    assert SN.transcript_refusal(path) == SN.NOT_ONE_STEP


# --- the route --------------------------------------------------------------------------------------------------------------

def test_the_chord_is_ctrl_x_ctrl_s_and_nothing_else(monkeypatch):
    ran = []

    async def run_tmux(_s, *args, **kw):
        ran.append(args)
        return ""

    monkeypatch.setattr(T, "run_tmux", run_tmux)
    asyncio.run(T.send_now_chord(None, PANE))
    assert ran == [("send-keys", "-t", PANE, "C-x", "C-s")]
    with pytest.raises(T.TmuxError):
        asyncio.run(T.send_now_chord(None, "me:0.0"))
    assert len(ran) == 1


@pytest.fixture
def env(tmp_path, monkeypatch):
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    project = claude / "projects" / TR.project_slug("/tmp")
    project.mkdir(parents=True)
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                        tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"], sala_models=tmp_path / "none.tsv")
    pid = os.getpid()
    (claude / "sessions" / f"{pid}.json").write_text(json.dumps(
        {"pid": pid, "sessionId": SID, "cwd": "/tmp", "name": NAME, "status": "busy", "tmux": f"me:@0.{PANE}",
         "procStart": S.proc_start(pid)}))
    e = SimpleNamespace(screen=screen(), chords=[], owner=pid, broken=False, pid=pid, transcript=project / f"{SID}.jsonl")
    write(e.transcript, ONE_STEP)

    async def pane_pid(_s, pane_id):
        assert pane_id == PANE
        return e.owner

    async def capture(_s, pane_id):
        return e.screen

    async def send_now_chord(_s, pane_id):
        if e.broken:
            raise T.TmuxError("tmux send-keys: gone")
        e.chords.append(pane_id)

    async def never(*_a, **_kw):
        raise AssertionError("send-now types nothing")

    async def no_shell(_settings):
        return None

    monkeypatch.setattr(T, "pane_pid", pane_pid)
    monkeypatch.setattr(T, "capture", capture)
    monkeypatch.setattr(T, "send_now_chord", send_now_chord)
    for name in ("paste", "send_enter", "send_key", "send_edit_key"):
        monkeypatch.setattr(T, name, never)
    monkeypatch.setattr(S, "live_tmux_names", lambda: {})
    monkeypatch.setattr(AP, "bring_up_shell", no_shell)
    with TestClient(create_app(settings)) as client:
        e.post = lambda **kw: client.post(f"/api/s/{kw.pop('pid', pid)}/send-now", **({"json": {}} | kw))
        yield e


def refused(env, why: str, status: int = 409, **kw) -> None:
    r = env.post(**kw)
    assert r.status_code == status and why in r.json()["error"], (r.status_code, r.text)
    assert env.chords == []


def test_the_safe_case_presses_the_chord_once_in_the_sessions_pane(env):
    r = env.post()
    assert r.status_code == 200 and r.json() == {"ok": True}, r.text
    assert env.chords == [PANE]


@pytest.mark.parametrize("case", ["text in the input line", "a permission dialog", "no input line", "the empty ! mode",
                                  "nothing waiting", "a hook before the call, or background tasks off",
                                  "a subagent's own screen", "a ! command waiting before the message"])
def test_a_screen_that_is_not_the_safe_case_presses_nothing(env, case):
    env.screen, why = REFUSED[case]
    refused(env, why)


def test_a_safe_screen_over_a_reply_still_being_written_presses_nothing(env):
    write(env.transcript, [said("go"), call("a"), result("a"), QUEUE])
    refused(env, SN.NOT_ONE_STEP)


def test_no_transcript_presses_nothing(env):
    env.transcript.unlink()
    refused(env, SN.NO_TRANSCRIPT)


def test_a_pane_that_is_not_the_sessions_presses_nothing(env):
    env.owner = 1
    refused(env, SN.UNREADABLE)


def test_a_tmux_failure_is_a_502(env):
    env.broken = True
    refused(env, "tmux failed", status=502)


def test_only_this_pages_json_posts_are_taken(env):
    refused(env, "cross-origin", status=403, headers={"origin": "https://elsewhere.example"})
    refused(env, "application/json", status=415, json=None, content="{}", headers={"content-type": "text/plain"})
    refused(env, "no live session", status=404, pid=999999999)
