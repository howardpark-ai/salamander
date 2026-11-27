"""The wheel means a turn in progress (turnstate.py): a registry row that says "busy" for background work alone reads "idle" on every page.

The CLI writes "busy" while a turn runs and also while only background work runs after the turn ended; the transcript says which. Held
here: the shapes that end a turn and the ones that do not, every unsure case staying "busy" as the registry says, the short belief in a row
that has only just turned busy, the cached read that follows a growing file, a parked pane's job, and that the session list, the Overview,
the chat session's entry and its thread all give the same answer. Made-up lines and rows only; no tmux, no browser.
"""

from __future__ import annotations

import json
import os
import time
from datetime import datetime, timezone

import pytest
from starlette.testclient import TestClient

from sala_web import sessions as S
from sala_web import transcript as TR
from sala_web import turnstate as TS
from sala_web.app import create_app
from sala_web.config import Settings

SID = "bbbbbbbb-0000-4000-8000-000000000001"
JOB_SID = "bbbbbbbb-0000-4000-8000-000000000002"
NAME = "demo-turn"
CWD = "/work/example-repo"
NOW = time.time()


def stamp(ago: float) -> str:
    return datetime.fromtimestamp(NOW - ago, timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def at(ago: float) -> int:
    """A registry stamp on the transcript lines' clock."""
    return int((NOW - ago) * 1000)


def just(ago: float) -> int:
    """A registry stamp that many seconds before this moment, for the grace a fresh one gets."""
    return int((time.time() - ago) * 1000)


# every builder takes `ago`, how many seconds before the run the line was written
def human(ago, text="go", **extra):
    return {"type": "user", "uuid": f"u{ago}", "timestamp": stamp(ago), "origin": {"kind": "human"}, "message": {"role": "user", "content": text}, **extra}


def plain(ago, text, **extra):
    """A user line with no origin: a slash command, its output, an interrupt."""
    return {"type": "user", "uuid": f"p{ago}", "timestamp": stamp(ago), "message": {"role": "user", "content": text}, **extra}


def peer(ago):
    return human(ago, "Another Claude session sent a message:\nfrom: demo\n\nhello", isMeta=True) | {"origin": {"kind": "peer"}}


def task(ago):
    return human(ago, "<task-notification>\n<summary>demo done</summary>\n</task-notification>") | {"origin": {"kind": "task-notification"}}


def say(ago, text="Done.", stop="end_turn", **extra):
    return {"type": "assistant", "uuid": f"a{ago}", "timestamp": stamp(ago),
            "message": {"role": "assistant", "model": "claude-demo", "stop_reason": stop, "content": [{"type": "text", "text": text}]}, **extra}


def call(ago):
    return {"type": "assistant", "uuid": f"c{ago}", "timestamp": stamp(ago), "message": {
        "role": "assistant", "model": "claude-demo", "stop_reason": "tool_use", "content": [{"type": "tool_use", "id": "t1", "name": "Bash", "input": {}}]}}


def result(ago):
    return {"type": "user", "uuid": f"r{ago}", "timestamp": stamp(ago), "toolUseResult": {},
            "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": "ok"}]}}


def ended(ago, **extra):
    return {"type": "system", "subtype": "turn_duration", "uuid": f"e{ago}", "timestamp": stamp(ago), "durationMs": 4000, **extra}


def interrupt(ago, tool=False):
    words = "[Request interrupted by user for tool use]" if tool else "[Request interrupted by user]"
    return plain(ago, [{"type": "text", "text": words}])


def api_error(ago):
    return say(ago, "API Error: demo", stop="stop_sequence", isApiErrorMessage=True) | {
        "message": {"role": "assistant", "model": "<synthetic>", "stop_reason": "stop_sequence", "content": [{"type": "text", "text": "API Error: demo"}]}}


def command(ago, name="/model"):
    return plain(ago, f"<command-name>{name}</command-name>\n<command-args></command-args>")


def output(ago):
    return plain(ago, "<local-command-stdout>set</local-command-stdout>")


# lines that say nothing of the turn
def quiet(ago):
    return [
        {"type": "data-flow-records", "records": [{"type": "x", "text": "y" * 2000}]},
        {"type": "attachment", "timestamp": stamp(ago), "attachment": {"type": "hook_success"}},
        {"type": "queue-operation", "operation": "enqueue", "timestamp": stamp(ago)},
        {"type": "queue-operation", "operation": "remove", "timestamp": stamp(ago)},
        {"type": "system", "subtype": "stop_hook_summary", "timestamp": stamp(ago)},
        say(ago, "a subagent's line", isSidechain=True),
        human(ago, "a subagent's task", isSidechain=True),
        {"type": "last-prompt", "lastPrompt": "go"},
    ]


def compaction(ago):
    return [{"type": "system", "subtype": "compact_boundary", "timestamp": stamp(ago)},
            human(ago, "This session is being continued from a previous conversation.", isCompactSummary=True)]


DONE = [human(900), say(890), ended(889, pendingBackgroundAgentCount=1)]

OVER = {
    "turn ended, background work still out": DONE,
    "lines that say nothing after the end": DONE + quiet(600),
    "interrupted": [human(300), say(290, stop=None), interrupt(200)],
    "interrupted at a tool": [human(300), call(290), result(200), interrupt(200, tool=True)],
    "ended in an API error": [human(300), api_error(290)],
    "an API error, then its end line": [human(300), api_error(290), ended(289)],
    "a slash command after the end": DONE + [plain(500, "<local-command-caveat>x</local-command-caveat>", isMeta=True), command(500), output(500)],
    "a command written as system lines": DONE + [command(500), {"type": "system", "subtype": "local_command", "timestamp": stamp(500),
                                                               "content": "<local-command-stdout>set</local-command-stdout>"},
                                                 plain(500, "<system-reminder>mode changed</system-reminder>", isMeta=True)],
    "compacted after the end": DONE + compaction(500),
    "the CLI's own empty reply after the end": DONE + [say(500, "No response requested.") | {"message": {"role": "assistant", "model": "<synthetic>", "content": []}}],
}

RUNNING = {
    "a message just taken": DONE + [human(5)],
    "a message with nothing before it": [human(5)],
    "another session's message": DONE + [peer(300)],
    "a background task's notice": DONE + [task(300), *quiet(299)],
    "a long silent tool call": DONE + [human(7200), call(7190)],
    "a tool's result in": DONE + [human(700), call(690), result(600)],
    "a reply whose end is not written": [human(300), say(290)],
    "a stop hook sends it back": [human(300), say(290), plain(289, "Stop hook feedback:\nmore", isMeta=True)],
    "compacted in the middle": [human(700), call(690), result(600), *compaction(500)],
    "a slash command that prompts": DONE + [command(300, "/demo"), plain(300, "the skill's text", isMeta=True)],
    "a slash command not answered yet": DONE + [command(5, "/demo")],
    "a command run during the turn": [human(700), call(690), command(500), output(500)],
    "a message after an interrupt": [human(300), interrupt(200), human(100)],
    "a message that went in with the interrupt": [human(700), call(690), human(200.5), result(200.2), interrupt(200, tool=True)],
}


def transcript(tmp_path, lines, sid=SID):
    p = tmp_path / "claude" / "projects" / TR.project_slug(CWD) / f"{sid}.jsonl"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text("".join(json.dumps(d) + "\n" for d in lines), encoding="utf-8")
    return p


def append(path, *lines):
    with path.open("a", encoding="utf-8") as f:
        f.writelines(json.dumps(d) + "\n" for d in lines)


def row(tmp_path, pid=None, **extra):
    pid = pid or os.getpid()
    d = {"pid": pid, "sessionId": SID, "name": NAME, "cwd": CWD, "tmux": NAME + ":@1.%1", "status": "busy", "statusUpdatedAt": at(3600), **extra}
    d_dir = tmp_path / "claude" / "sessions"
    d_dir.mkdir(parents=True, exist_ok=True)
    (d_dir / f"{pid}.json").write_text(json.dumps(d))


@pytest.fixture
def settings(tmp_path, monkeypatch):
    monkeypatch.setattr(S, "proc_lane", lambda p: "subscription-1")
    monkeypatch.setattr(S, "live_tmux_names", lambda: {})   # never the default tmux server's names
    TS._cache.clear()
    yield Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=tmp_path / "claude", tmux_socket_name="salaweb-pytest-none",
                   roles_cmd=["false"], sala_models=tmp_path / "none.tsv", admin_key=tmp_path / "none-key", brain_dir=tmp_path / "no-brain")
    TS._cache.clear()


def status(settings) -> str:
    [s] = S.read_live_sessions(settings)
    return s.status


@pytest.mark.parametrize("lines", OVER.values(), ids=OVER.keys())
def test_a_busy_row_whose_turn_is_over_reads_idle(tmp_path, settings, lines):
    row(tmp_path)
    transcript(tmp_path, lines)
    assert status(settings) == "idle"


@pytest.mark.parametrize("lines", RUNNING.values(), ids=RUNNING.keys())
def test_a_running_turn_reads_busy(tmp_path, settings, lines):
    row(tmp_path)
    transcript(tmp_path, lines)
    assert status(settings) == "busy"


@pytest.mark.parametrize("said", ["waiting", "shell", "idle", "unknown"])
def test_every_other_status_stays_as_the_registry_says(tmp_path, settings, said):
    row(tmp_path, status=said)
    for lines in (DONE, RUNNING["a message just taken"]):
        transcript(tmp_path, lines)
        assert status(settings) == said


def test_unsure_stays_busy(tmp_path, settings, monkeypatch):
    row(tmp_path)
    assert status(settings) == "busy"                       # no transcript
    path = transcript(tmp_path, [])
    assert status(settings) == "busy"                       # an empty one
    path = transcript(tmp_path, quiet(100))
    assert status(settings) == "busy"                       # nothing in it says either way
    path.write_text(json.dumps(ended(100)))                 # a line still being written
    assert status(settings) == "busy"
    transcript(tmp_path, DONE + quiet(500) * 20)
    TS._cache.clear()
    monkeypatch.setattr(TS, "SCAN_MAX", 4096)               # the end is further back than a look goes
    assert status(settings) == "busy"


def test_a_row_that_has_only_just_turned_busy_is_believed(tmp_path, settings):
    transcript(tmp_path, DONE)
    row(tmp_path, statusUpdatedAt=just(2))                  # busy since after the end: a new turn whose first line is not written
    assert status(settings) == "busy"
    row(tmp_path, statusUpdatedAt=just(TS.GRACE_MS / 1000 + 60))    # the same, longer ago: background work
    assert status(settings) == "idle"
    transcript(tmp_path, [human(20), say(11), ended(10)])
    row(tmp_path, statusUpdatedAt=at(20))                   # busy since before the end: that turn is over
    assert status(settings) == "idle"
    d = json.loads((tmp_path / "claude" / "sessions" / f"{os.getpid()}.json").read_text())
    del d["statusUpdatedAt"]
    (tmp_path / "claude" / "sessions" / f"{os.getpid()}.json").write_text(json.dumps(d))
    assert status(settings) == "idle"


def test_a_growing_transcript_is_followed_and_a_quiet_one_not_reread(tmp_path, settings, monkeypatch):
    row(tmp_path)
    path = transcript(tmp_path, DONE)
    looks: list[int] = []
    real = TS._look

    def look(m, end, floor):
        looks.append(floor)
        return real(m, end, floor)

    monkeypatch.setattr(TS, "_look", look)
    assert status(settings) == "idle" and status(settings) == "idle" and looks == [0]
    seen = path.stat().st_size
    append(path, *quiet(400))
    assert status(settings) == "idle" and looks == [0, seen]           # only what was added is read; it says nothing: as before
    append(path, task(300))
    assert status(settings) == "busy"
    append(path, *quiet(299))
    assert status(settings) == "busy"
    with path.open("a") as f:
        f.write(json.dumps(ended(200))[:30])
    assert status(settings) == "busy"
    with path.open("a") as f:
        f.write(json.dumps(ended(200))[30:] + "\n")
    assert status(settings) == "idle"
    append(path, command(100))
    assert status(settings) == "busy"                       # its output not written yet
    append(path, output(100))
    assert status(settings) == "idle"                       # the two lines came apart: still one command, and the turn is over
    append(path, human(50), call(49))
    assert status(settings) == "busy"
    append(path, interrupt(10, tool=True))
    assert status(settings) == "idle"
    other = path.with_suffix(".new")                        # another file in its place is read whole
    other.write_text(json.dumps(human(5)) + "\n" + "".join(json.dumps(d) + "\n" for d in quiet(4) * 40))
    os.replace(other, path)
    assert status(settings) == "busy" and looks[-1] == 0


def test_a_parked_panes_job_is_judged_by_the_jobs_own_transcript(tmp_path, settings):
    row(tmp_path, os.getpid(), status="shell", parkedJobId=JOB_SID[:8])
    row(tmp_path, os.getppid(), sessionId=JOB_SID, jobId=JOB_SID[:8], kind="bg", tmux="")
    transcript(tmp_path, [human(5)])                        # the pane's old conversation says nothing of the job
    path = transcript(tmp_path, DONE, sid=JOB_SID)
    assert status(settings) == "idle"
    append(path, human(3))
    assert status(settings) == "busy"


@pytest.mark.parametrize("lines,busy", [(DONE + quiet(500), False), (DONE + [human(5)], True)], ids=["background work alone", "a turn"])
def test_every_page_gives_the_same_answer(tmp_path, settings, monkeypatch, lines, busy):
    monkeypatch.setenv("SALA_CHAT_SESSION", NAME)
    row(tmp_path)
    transcript(tmp_path, lines)
    word = "busy" if busy else "idle"
    client = TestClient(create_app(settings))
    listed = [s for scope in client.get("/api/sessions").json()["scopes"] for g in scope["groups"] for s in g["sessions"]]
    assert [(s["name"], s["status"]) for s in listed] == [(NAME, word)]                       # the sidebar, the header, the spinner
    assert [r["status"] for r in S.overview_rows(S.read_live_sessions(settings), {})] == ["working" if busy else "idle"]   # the Overview
    assert S.find_session(settings, os.getpid()).status == word                              # the open stream's status events
    assert client.get("/api/chat").json()["busy"] is busy                                    # the chat session's entry
    assert client.get("/api/chat/thread").json()["busy"] is busy                             # its thread's working mark
