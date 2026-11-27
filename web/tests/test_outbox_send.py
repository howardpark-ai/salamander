"""The outbox's routes and its sender (api/outbox/<name>), against a pane that is a made-up screen: no tmux, no browser.

The pane is a small state machine (idle with an empty box, a box with a draft, a permission dialog, no box at all); what is typed
and pressed is recorded, never made. The app runs with its sender (the lifespan), the tick shortened, as the service does.

What a wrong answer costs: a message typed over a dialog or a draft the owner left (the Enter then answers or submits the wrong
thing), a message dropped when the pane could not take it, sent out of order, sent twice (a restart, a "lost" verdict without
evidence, a retry), or a Cancel that the page reports as done while the text goes in anyway. Held here:

- a message to a pane that can take it is typed once, at once, mid-turn too, and is `queued` until a transcript line shows it;
- with a dialog open, no box, a sleeping session or no such session listed it is HELD, nothing typed, and goes in when the pane can take
  it, in the order it was sent; the page is told why and which ones wait behind;
- text in the terminal's input line is not the owner's: it is cleared (Ctrl+U, as the page's Replace does), its text kept in the cleared-text
  log with the session and the time, and the message goes in; the dim suggestion Claude Code draws in an empty line is not text; a line the
  keys cannot clear holds the message and nothing is typed into it;
- a lone option number or esc passes at once while a dialog has it, whatever is held; a `!` command is never held;
- cancel and edit take a held message back (an edit rejoins at the end), and answer "too late", changing nothing, once it is typed;
- the list survives a restart; a message half typed at the restart is failed, never typed again;
- a message the session's process ended without reading, with the CLI's enqueue line as evidence, is sent again; one the transcript
  shows delivered is not; one with no evidence stays queued;
- the folder is mode 700 and the files 600.
"""

from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import time
from pathlib import Path
from types import SimpleNamespace

import pytest
from starlette.testclient import TestClient

import sala_web.app as AP
from sala_web import outbox as OB
from sala_web import sessions as S
from sala_web import tmuxio as T
from sala_web import transcript as TR
from sala_web.app import create_app
from sala_web.config import Settings

FIX = Path(__file__).parent / "fixtures"
PANE = "%7"
SID = "aaaaaaaa-0000-0000-0000-000000000000"
NAME = "me"
RULE = "─" * 40
PROMPT = "❯"
NBSP = " "


class Pane:
    """What the session's pane shows, and what was done to it."""

    def __init__(self):
        self.mode = "idle"          # idle | dialog | blank | suggest (the box shows Claude Code's dim suggestion)
        self.draft = ""
        self.stuck = False          # Ctrl+U changes nothing
        self.submitted: list[str] = []
        self.keys: list[str] = []
        self.edits: list[str] = []

    def screen(self) -> str:
        if self.mode == "dialog":
            return (FIX / "capture-dialog.txt").read_text()
        if self.mode == "suggest":
            return (FIX / "capture-empty.txt").read_text()
        if self.mode == "blank":
            return "Loading the conversation\n" * 3
        return f"old output\n{RULE}\n{PROMPT}{NBSP}{self.draft}\n{RULE}\n"


def until(fn, secs=10.0):
    end = time.time() + secs
    while time.time() < end:
        got = fn()
        if got:
            return got
        time.sleep(0.05)
    return fn()


@pytest.fixture
def env(tmp_path, monkeypatch):
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    (claude / "projects").mkdir()
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                        tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"], sala_models=tmp_path / "none.tsv")
    pid = os.getpid()
    pane = Pane()
    row = claude / "sessions" / f"{pid}.json"

    def register(status="idle", name=NAME):
        row.write_text(json.dumps({"pid": pid, "sessionId": SID, "cwd": "/tmp", "name": name, "status": status,
                                   "tmux": f"me:@0.{PANE}", "procStart": S.proc_start(pid)}))

    async def pane_pid(_s, pane_id):
        assert pane_id == PANE
        return pid

    async def capture(_s, pane_id):
        return pane.screen()

    async def paste(_s, pane_id, text):
        pane.draft += text

    async def send_enter(_s, pane_id):
        if pane.draft:
            pane.submitted.append(pane.draft)
            pane.draft = ""

    async def send_key(_s, pane_id, key):
        pane.keys.append(key)

    async def send_edit_key(_s, pane_id, key):
        pane.edits.append(key)
        if key == "C-u" and not pane.stuck:
            pane.draft = ""

    async def no_shell(_settings):
        return None

    monkeypatch.setattr(T, "pane_pid", pane_pid)
    monkeypatch.setattr(T, "capture", capture)
    monkeypatch.setattr(T, "paste", paste)
    monkeypatch.setattr(T, "send_enter", send_enter)
    monkeypatch.setattr(T, "send_key", send_key)
    monkeypatch.setattr(T, "send_edit_key", send_edit_key)
    monkeypatch.setattr(T, "CLEAR_SETTLE", 0)
    monkeypatch.setattr(T, "CLEAR_STALL_SETTLE", 0)
    monkeypatch.setattr(S, "live_tmux_names", lambda: {})
    monkeypatch.setattr(AP, "bring_up_shell", no_shell)
    monkeypatch.setattr(AP, "OUTBOX_TICK", 0.1)
    monkeypatch.setattr(AP, "OUTBOX_GAP", 0)
    register()
    app = create_app(settings)
    with TestClient(app) as client:
        e = SimpleNamespace(client=client, pane=pane, settings=settings, register=register, row=row, pid=pid, app=app, claude=claude,
                            monkeypatch=monkeypatch)
        e.post = lambda text, **kw: client.post(f"/api/outbox/{NAME}", json={"text": text, **kw})
        e.msgs = lambda: client.get(f"/api/outbox/{NAME}").json()["messages"]
        e.states = lambda: [(m["text"], m["state"], m["reason"]) for m in e.msgs()]
        yield e


def test_a_message_to_a_pane_that_can_take_it_is_typed_once_at_once_and_is_queued(env):
    r = env.post("hello there")
    assert r.status_code == 200, r.text
    m = r.json()["message"]
    assert m["state"] == "queued" and m["text"] == "hello there" and m["sentAt"] and m["attempts"] == 1
    assert env.pane.submitted == ["hello there"]
    time.sleep(0.5)
    assert env.pane.submitted == ["hello there"]                  # once, however many ticks went by
    assert [x["state"] for x in env.msgs()] == ["queued"]


def test_it_is_typed_while_a_turn_runs(env):
    env.register(status="busy")
    r = env.post("while you work")
    assert r.json()["message"]["state"] == "queued" and env.pane.submitted == ["while you work"]   # the CLI queues it: sending while busy stays allowed


def test_the_folder_is_private_and_the_file_whole(env):
    env.post("kept")
    d = env.settings.outbox_dir
    assert stat.S_IMODE(d.stat().st_mode) == 0o700
    (f,) = [p for p in d.iterdir()]
    assert f.name == f"{NAME}.json" and stat.S_IMODE(f.stat().st_mode) == 0o600
    assert json.loads(f.read_text())["messages"][0]["text"] == "kept"


def test_a_dialog_holds_the_message_and_it_goes_in_when_the_dialog_is_gone_in_order(env):
    env.pane.mode = "dialog"
    a = env.post("first thing").json()["message"]
    b = env.post("second thing").json()["message"]
    assert (a["state"], a["reason"]) == ("held", "dialog") and (b["state"], b["reason"]) == ("held", "ahead")
    time.sleep(0.6)
    assert env.pane.submitted == [] and env.pane.keys == []                          # nothing typed, nothing pressed
    env.pane.mode = "idle"
    assert until(lambda: len(env.pane.submitted) == 2)
    assert env.pane.submitted == ["first thing", "second thing"]
    assert until(lambda: [m["state"] for m in env.msgs()] == ["queued", "queued"])


def cleared(env) -> list[dict]:
    return OB.ClearedLog(env.settings.state_dir / OB.CLEARED_FILE).read()


def test_text_in_the_terminal_line_is_cleared_and_kept_in_the_log_and_the_message_goes_in(env):
    env.pane.draft = "half a thought"                                                   # never the owner's: he does not write in the terminal
    m = env.post("my message").json()["message"]
    assert m["state"] == "queued" and m["reason"] is None
    assert env.pane.submitted == ["my message"]                                          # not "half a thoughtmy message"
    assert env.pane.edits == ["C-u"] and env.pane.draft == ""
    (rec,) = cleared(env)
    assert rec["text"] == "half a thought" and rec["session"] == NAME and isinstance(rec["t"], int)
    f = env.settings.state_dir / OB.CLEARED_FILE
    assert stat.S_IMODE(f.stat().st_mode) == 0o600


def test_a_line_that_cannot_be_cleared_holds_the_message_and_types_nothing_into_it(env):
    env.pane.draft = "stuck text"
    env.pane.stuck = True
    m = env.post("after it").json()["message"]
    assert (m["state"], m["reason"], m["detail"]) == ("held", "draft", "stuck text")
    assert env.pane.submitted == [] and env.pane.draft == "stuck text"                   # nothing was typed into the line
    env.pane.stuck = False
    assert until(lambda: env.pane.submitted == ["after it"])


def test_the_dim_suggestion_in_the_empty_line_is_not_text_and_nothing_is_cleared(env):
    env.pane.mode = "suggest"                                                            # Claude Code's grey placeholder after the prompt
    m = env.post("plain send").json()["message"]
    assert m["state"] == "queued" and env.pane.edits == [] and cleared(env) == []
    assert env.pane.submitted == ["plain send"]


def test_two_messages_over_a_draft_clear_it_once_and_go_in_in_order(env):
    env.pane.draft = "leftover"
    env.post("one")
    env.post("two")
    assert env.pane.submitted == ["one", "two"] and [r["text"] for r in cleared(env)] == ["leftover"]


def pasted_entry(env, text):
    """A message whose paste landed in the pane and whose Enter did not (the state the sender leaves after a half-done send)."""
    env.pane.mode = "dialog"                       # nothing is sent while the entry is made
    e, _ = env.app.state.outbox.add(NAME, text, [])
    env.app.state.outbox.update(NAME, e["id"], pasted=True)
    return e


def test_a_pasted_message_the_enter_did_not_take_is_submitted_as_it_stands_and_never_pasted_again(env):
    pasted_entry(env, "pasted one")
    env.pane.draft = "pasted one"
    env.pane.mode = "idle"
    assert until(lambda: env.pane.submitted == ["pasted one"])       # not "pasted onepasted one"
    assert env.pane.edits == [] and cleared(env) == []                 # the box held exactly it: nothing was cleared
    assert until(lambda: env.states() == [("pasted one", "queued", None)])


@pytest.mark.parametrize("box", ["", "somebody else's text"], ids=["box-empty", "other-text"])
def test_a_pasted_message_whose_box_no_longer_holds_it_is_failed_not_sent_again(env, box):
    pasted_entry(env, "pasted one")
    env.pane.draft = box
    env.pane.mode = "idle"
    assert until(lambda: env.states() == [("pasted one", "failed", None)])
    assert env.pane.submitted == [] and env.pane.edits == [] and env.pane.draft == box


def test_no_input_box_holds_it(env):
    env.pane.mode = "blank"
    m = env.post("are you there").json()["message"]
    assert (m["state"], m["reason"]) == ("held", "noInput")
    env.pane.mode = "idle"
    assert until(lambda: env.pane.submitted == ["are you there"])


def test_an_option_number_or_esc_passes_at_once_while_a_message_is_held_and_is_not_kept(env):
    env.pane.mode = "dialog"
    env.post("a message that waits")
    r = env.post("2")
    assert r.status_code == 200 and r.json()["dialogAnswer"] == "2" and env.pane.keys == ["2"]
    r = env.post("esc")
    assert r.json()["dialogAnswer"] == "Escape" and env.pane.keys == ["2", "Escape"]
    assert [m["text"] for m in env.msgs()] == ["a message that waits"]                   # the answers are not in the list
    assert env.pane.submitted == []
    r = env.post("7")                                                                    # not an option of this dialog: held like any text
    assert r.json()["message"]["state"] == "held" and env.pane.keys == ["2", "Escape"]


def test_a_number_with_no_dialog_open_is_a_message(env):
    r = env.post("1")
    assert r.json()["message"]["state"] == "queued" and env.pane.submitted == ["1"] and env.pane.keys == []


def test_a_bang_command_is_never_held(env):
    env.pane.mode = "dialog"
    r = env.post("! rm -rf scratch")
    assert r.status_code == 400 and r.json()["bang"] is True and env.msgs() == []


def test_cancel_takes_a_held_message_back_and_it_is_not_sent_later(env):
    env.pane.mode = "dialog"
    a = env.post("not this one").json()["message"]
    b = env.post("this one").json()["message"]
    r = env.client.post(f"/api/outbox/{NAME}/{a['id']}/cancel")
    assert r.status_code == 200 and r.json()["message"]["state"] == "withdrawn" and r.json()["message"]["text"] == "not this one"
    env.pane.mode = "idle"
    assert until(lambda: env.pane.submitted == ["this one"])
    time.sleep(0.4)
    assert env.pane.submitted == ["this one"]
    assert env.states() == [("not this one", "withdrawn", None), ("this one", "queued", None)]
    assert b["id"] in [m["id"] for m in env.msgs()]


def test_cancel_after_it_is_typed_says_too_late_and_changes_nothing(env):
    m = env.post("already in").json()["message"]
    r = env.client.post(f"/api/outbox/{NAME}/{m['id']}/cancel")
    assert r.status_code == 409 and r.json()["tooLate"] is True and "too late" in r.json()["error"] and r.json()["state"] == "queued"
    assert env.states() == [("already in", "queued", None)] and env.pane.submitted == ["already in"]
    assert env.client.post(f"/api/outbox/{NAME}/nope/cancel").status_code == 404


def test_edit_withdraws_the_old_message_and_the_new_one_joins_at_the_end(env):
    env.pane.mode = "dialog"
    a = env.post("A original").json()["message"]
    env.post("B")
    r = env.client.post(f"/api/outbox/{NAME}/{a['id']}/edit", json={"text": "A edited"})
    assert r.status_code == 200 and r.json()["withdrawn"] == a["id"] and r.json()["message"]["text"] == "A edited"
    assert env.states() == [("A original", "withdrawn", None), ("B", "held", "dialog"), ("A edited", "held", "ahead")]
    env.pane.mode = "idle"
    assert until(lambda: len(env.pane.submitted) == 2)
    assert env.pane.submitted == ["B", "A edited"]                                       # the edited one went to the end
    typed = env.client.post(f"/api/outbox/{NAME}/{r.json()['message']['id']}/edit", json={"text": "too late now"})
    assert typed.status_code == 409 and typed.json()["tooLate"] is True
    assert env.pane.submitted == ["B", "A edited"] and "too late now" not in [m["text"] for m in env.msgs()]


def test_the_page_asking_twice_with_one_cid_sends_one_message(env):
    env.pane.mode = "dialog"
    a = env.post("same", cid="c-1").json()["message"]
    b = env.post("same", cid="c-1").json()["message"]
    assert a["id"] == b["id"] and len(env.msgs()) == 1
    env.pane.mode = "idle"
    assert until(lambda: env.pane.submitted == ["same"])
    time.sleep(0.3)
    assert env.pane.submitted == ["same"]


def test_two_identical_messages_with_different_cids_are_two_messages(env):
    env.post("ok", cid="c-1")
    env.post("ok", cid="c-2")
    assert env.pane.submitted == ["ok", "ok"]                                            # the 20 s duplicate guard is for double clicks, which a cid already covers


def test_a_sleeping_session_holds_it_and_it_goes_in_once_the_session_is_live(env):
    env.row.unlink()
    sleeper = S.Session(pid=0, session_id=SID, name=NAME, cwd="/tmp", status="sleeping", tmux=f"me:@0.{PANE}", sleeping="2026-11-26T01:00:00Z")
    env.monkeypatch.setattr(S, "read_sleeping_sessions", lambda settings, live: [] if live else [sleeper])
    m = env.post("wake and read this").json()["message"]
    assert (m["state"], m["reason"]) == ("held", "asleep") and env.pane.submitted == []
    time.sleep(0.5)
    assert env.pane.submitted == []
    env.register()                                                                       # it woke
    assert until(lambda: env.pane.submitted == ["wake and read this"])
    assert until(lambda: env.states() == [("wake and read this", "queued", None)])


def test_a_session_that_is_not_listed_holds_it_and_after_a_long_while_fails_it_with_its_text(env):
    env.monkeypatch.setattr(AP, "OUTBOX_GIVE_UP", 0.3)
    env.pane.mode = "dialog"
    held = env.post("kept for it").json()["message"]
    assert held["state"] == "held"
    env.row.unlink()                                                                     # relaunching: the name is not listed now
    assert env.client.post(f"/api/outbox/{NAME}", json={"text": "to nobody"}).status_code == 404   # a name nothing lists is not a session to send to
    assert until(lambda: [x["state"] for x in env.msgs() if x["id"] == held["id"]] == ["failed"])
    failed = next(x for x in env.msgs() if x["id"] == held["id"])
    assert failed["text"] == "kept for it" and "did not come back" in failed["error"] and env.pane.submitted == []
    r = env.client.post(f"/api/outbox/{NAME}/{held['id']}/cancel")                       # Edit still takes it back
    assert r.status_code == 200 and r.json()["message"]["text"] == "kept for it"


def test_a_session_that_comes_back_in_time_gets_the_message(env):
    env.pane.mode = "dialog"
    env.post("wait for me")
    env.row.unlink()
    assert until(lambda: env.states() == [("wait for me", "held", "gone")])
    env.register()
    env.pane.mode = "idle"
    assert until(lambda: env.pane.submitted == ["wait for me"])


def test_a_held_message_is_there_after_a_restart_and_goes_in(env, tmp_path):
    env.pane.mode = "dialog"
    env.post("survive the restart")
    again = OB.Outbox(env.settings.outbox_dir)
    assert [e["text"] for e in again.entries(NAME)] == ["survive the restart"]
    env.pane.mode = "idle"
    assert until(lambda: env.pane.submitted == ["survive the restart"])


def test_a_message_half_typed_at_a_restart_is_failed_and_never_typed_again(env):
    e, _ = env.app.state.outbox.add(NAME, "was being typed", [])
    env.app.state.outbox.update(NAME, e["id"], state=OB.TYPING)
    fresh = create_app(env.settings)
    (got,) = fresh.state.outbox.entries(NAME)
    assert got["state"] == "failed" and got["text"] == "was being typed"
    time.sleep(0.4)
    assert env.pane.submitted == []


def test_an_upload_that_is_gone_fails_the_message_without_typing_a_path(env):
    up = env.client.post("/api/upload", content=b"\x89PNG fake", headers={"Content-Type": "image/png"}).json()["name"]
    env.pane.mode = "dialog"
    m = env.post("see this", uploads=[up]).json()["message"]
    assert m["state"] == "held" and m["uploads"] == [up]
    (env.settings.uploads_dir / up).unlink()
    env.pane.mode = "idle"
    assert until(lambda: [x["state"] for x in env.msgs()] == ["failed"])
    assert env.msgs()[0]["error"] == "an uploaded file is missing" and env.pane.submitted == []


def test_bad_requests_are_refused_before_anything_is_kept(env):
    c = env.client
    assert c.post(f"/api/outbox/{NAME}", json={"text": "  "}).status_code == 400
    assert c.post(f"/api/outbox/{NAME}", json={"text": "x", "uploads": "no"}).status_code == 400
    assert c.post(f"/api/outbox/{NAME}", json={"text": "x", "uploads": ["../../etc/passwd"]}).status_code == 400
    assert c.post(f"/api/outbox/{NAME}", content=b"x", headers={"Content-Type": "text/plain"}).status_code == 415
    assert c.post(f"/api/outbox/{NAME}", json={"text": "x"}, headers={"Origin": "https://evil.example"}).status_code == 403
    assert c.post("/api/outbox/no-such-session", json={"text": "x"}).status_code == 404
    assert c.get("/api/outbox/no-such-session").json()["messages"] == []
    assert env.msgs() == [] and env.pane.submitted == []


# ── what the transcript says ──────────────────────────────────────────────────────────────────────────────────
def transcript(env) -> Path:
    d = env.claude / "projects" / TR.project_slug("/tmp")
    d.mkdir(parents=True, exist_ok=True)
    return d / f"{SID}.jsonl"


def iso(ms: int) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(ms / 1000)) + f".{ms % 1000:03d}Z"


def user_line(text: str, ms: int, uuid: str) -> dict:
    return {"type": "user", "uuid": uuid, "timestamp": iso(ms), "sessionId": SID, "message": {"role": "user", "content": text}}


def append(path: Path, lines: list[dict]) -> None:
    with path.open("a", encoding="utf-8") as f:
        for d in lines:
            f.write(json.dumps(d) + "\n")


def dead_pid() -> int:
    p = subprocess.Popen([sys.executable, "-c", "pass"])
    p.wait()
    return p.pid


def queued_before(env, text: str, pid: int, proc_start: str | None) -> dict:
    """An entry the outbox typed earlier, by a process that is gone (or is this one)."""
    box = env.app.state.outbox
    e, _ = box.add(NAME, text, [])
    return box.update(NAME, e["id"], state=OB.QUEUED, sentAt=int(time.time() * 1000), pid=pid, procStart=proc_start, sessionId=SID)


def test_a_transcript_line_that_has_the_message_makes_it_delivered(env):
    m = env.post("did you get this").json()["message"]
    assert m["state"] == "queued"
    append(transcript(env), [user_line("did you get this", m["sentAt"] + 400, "00000000-0000-4000-8000-000000000001")])
    assert until(lambda: env.states() == [("did you get this", "delivered", None)])
    assert env.pane.submitted == ["did you get this"]


def test_a_message_the_process_ended_without_reading_is_sent_again_once(env):
    e = queued_before(env, "Z1", dead_pid(), "1")
    append(transcript(env), [{"type": "queue-operation", "operation": "enqueue", "timestamp": iso(e["sentAt"] + 100), "sessionId": SID, "content": "Z1"}])
    assert until(lambda: env.pane.submitted == ["Z1"])
    time.sleep(0.5)
    assert env.pane.submitted == ["Z1"]                                                  # sent again once, not on every tick
    (m,) = env.msgs()
    assert m["state"] == "queued" and m["resent"] is True and m["id"] == e["id"]


def test_a_message_the_transcript_shows_is_not_sent_again_even_if_its_process_ended(env):
    e = queued_before(env, "Z2", dead_pid(), "1")
    append(transcript(env), [{"type": "queue-operation", "operation": "enqueue", "timestamp": iso(e["sentAt"] + 100), "sessionId": SID, "content": "Z2"},
                             {"type": "queue-operation", "operation": "dequeue", "timestamp": iso(e["sentAt"] + 900), "sessionId": SID},
                             user_line("Z2", e["sentAt"] + 950, "00000000-0000-4000-8000-000000000002")])
    assert until(lambda: env.states() == [("Z2", "delivered", None)])
    time.sleep(0.4)
    assert env.pane.submitted == []


def test_a_message_with_no_evidence_stays_queued_and_is_not_sent_again(env):
    queued_before(env, "Z3", dead_pid(), "1")
    append(transcript(env), [user_line("something else", int(time.time() * 1000), "00000000-0000-4000-8000-000000000003")])
    time.sleep(0.8)
    assert env.states() == [("Z3", "queued", None)] and env.pane.submitted == []


def test_a_message_whose_process_is_alive_is_never_read_as_lost(env):
    queued_before(env, "Z4", env.pid, S.proc_start(env.pid))
    append(transcript(env), [{"type": "queue-operation", "operation": "enqueue", "timestamp": iso(int(time.time() * 1000)), "sessionId": SID, "content": "Z4"}])
    time.sleep(0.8)
    assert env.states() == [("Z4", "queued", None)] and env.pane.submitted == []
