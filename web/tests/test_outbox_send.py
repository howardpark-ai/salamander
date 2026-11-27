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
- a message still in the CLI's queue (typed mid-turn, not read yet) is taken back with one Up that pulls the whole queue into the box; the
  others go back to held and are typed again in order; text already in the input line is cleared (and kept) first; refused (busy, nothing
  pressed) with a dialog, a line that cannot be cleared, a queue that does not read back as sala's, an upload in the queue; one the session
  took first is `tooLate` while the others are still typed again; what the Up cannot be confirmed to have pulled is failed with its text
  kept and never typed again; a message pulled into the box by an Up that was not sala-web's is failed too, so it is not shown as waiting;
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
        self.busy = False           # a turn runs: a message typed now waits in the CLI's queue (an enqueue line), it does not run
        self.queue: list[str] = []  # the CLI's queue, oldest first; an Up pulls all of it into the box (a popAll line per message)
        self.up_mute = False        # Up does nothing
        self.up_silent = False      # Up fills the box and no popAll line is written (nothing confirms what came back)
        self.takes = 0              # how many queued messages the session takes just as the Up is pressed (a turn ending mid take-back)
        self.late: list[str] = []   # texts that reach the queue between sala-web's look and its Up (typed in the terminal)
        self.recall = ""            # what an Up recalls into the box when nothing is queued (the last prompt, from history)
        self.ups = 0
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
        first, *more = self.draft.split("\n")
        body = [f"{PROMPT}{NBSP}{first}"] + [f"  {x}" for x in more]
        return "\n".join(["old output", RULE, *body, RULE]) + "\n"


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

    def tr_file() -> Path:
        d = claude / "projects" / TR.project_slug("/tmp")
        d.mkdir(parents=True, exist_ok=True)
        return d / f"{SID}.jsonl"

    def tr_line(d: dict) -> None:
        with tr_file().open("a", encoding="utf-8") as f:
            f.write(json.dumps(d) + "\n")

    def queue_op(op: str, content: str | None = None) -> dict:
        d = {"type": "queue-operation", "operation": op, "timestamp": iso(int(time.time() * 1000)), "sessionId": SID}
        if content is not None:
            d["content"] = content
        return d

    async def send_enter(_s, pane_id):
        if pane.draft:
            text = pane.draft
            pane.submitted.append(text)
            pane.draft = ""
            if pane.busy:
                pane.queue.append(text)
                tr_line(queue_op("enqueue", text))

    async def send_key(_s, pane_id, key):
        pane.keys.append(key)

    async def send_edit_key(_s, pane_id, key):
        pane.edits.append(key)
        if key == "C-u" and not pane.stuck:
            pane.draft = ""

    async def send_take_back_key(_s, pane_id, key):
        assert key == "Up", key
        pane.ups += 1
        if pane.up_mute:
            return
        for text in pane.late:
            pane.queue.append(text)
            tr_line(queue_op("enqueue", text))
        pane.late = []
        for _ in range(min(pane.takes, len(pane.queue))):
            tr_line(queue_op("remove", pane.queue.pop(0)))
        pane.takes = 0
        pulled = [t for t in pane.queue if not t.startswith("<task-notification")]
        if not pulled:
            pane.draft = pane.recall
            return
        if not pane.up_silent:
            for text in pulled:
                tr_line(queue_op("popAll", text))
        pane.draft = "\n".join(pulled)
        pane.queue = [t for t in pane.queue if t.startswith("<task-notification")]

    async def no_shell(_settings):
        return None

    monkeypatch.setattr(T, "pane_pid", pane_pid)
    monkeypatch.setattr(T, "capture", capture)
    monkeypatch.setattr(T, "paste", paste)
    monkeypatch.setattr(T, "send_enter", send_enter)
    monkeypatch.setattr(T, "send_key", send_key)
    monkeypatch.setattr(T, "send_edit_key", send_edit_key)
    monkeypatch.setattr(T, "send_take_back_key", send_take_back_key)
    monkeypatch.setattr(AP, "TAKE_BACK_WAIT", 0.4)
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


def test_cancel_of_a_message_typed_at_an_idle_pane_with_no_transcript_line_is_busy_and_changes_nothing(env):
    m = env.post("already in").json()["message"]
    r = env.client.post(f"/api/outbox/{NAME}/{m['id']}/cancel")
    assert r.status_code == 409 and r.json()["busy"] is True and "transcript" in r.json()["error"] and r.json()["state"] == "queued"
    assert env.states() == [("already in", "queued", None)] and env.pane.submitted == ["already in"] and env.pane.ups == 0
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
    assert typed.status_code == 409 and typed.json()["busy"] is True and typed.json()["state"] == "queued"
    assert env.pane.submitted == ["B", "A edited"] and env.pane.ups == 0 and "too late now" not in [m["text"] for m in env.msgs()]


# ── a queued message (the CLI's queue, not yet read): take back, cancel, edit ─────────────────────────────────
def busy_queue(env, *texts: str) -> list[str]:
    """The session is mid-turn: each text is typed into the CLI's queue and stays queued there (an enqueue line each)."""
    env.pane.busy = True
    return [env.post(t).json()["message"]["id"] for t in texts]


def test_cancel_of_a_queued_message_pulls_the_queue_back_and_the_others_go_in_again_in_order(env):
    ids = busy_queue(env, "A", "B", "C")
    assert [x[1] for x in env.states()] == ["queued", "queued", "queued"] and env.pane.queue == ["A", "B", "C"]
    r = env.client.post(f"/api/outbox/{NAME}/{ids[1]}/cancel")
    assert r.status_code == 200 and r.json()["message"]["state"] == "withdrawn" and r.json()["message"]["text"] == "B", r.text
    assert env.pane.ups == 1 and env.pane.draft == ""                          # one Up, the box emptied again
    assert until(lambda: env.pane.queue == ["A", "C"])                          # A and C re-typed in order, not B
    assert until(lambda: env.states() == [("A", "queued", None), ("B", "withdrawn", None), ("C", "queued", None)])
    time.sleep(0.3)
    assert env.pane.submitted == ["A", "B", "C", "A", "C"] and env.pane.ups == 1


def test_edit_of_a_queued_message_puts_the_new_text_at_the_end_behind_the_others(env):
    ids = busy_queue(env, "A", "B")
    r = env.client.post(f"/api/outbox/{NAME}/{ids[0]}/edit", json={"text": "A2"})
    assert r.status_code == 200 and r.json()["withdrawn"] == ids[0] and r.json()["message"]["text"] == "A2", r.text
    assert until(lambda: env.pane.queue == ["B", "A2"])
    assert env.pane.submitted == ["A", "B", "B", "A2"] and env.pane.ups == 1


def cancel(env, mid):
    return env.client.post(f"/api/outbox/{NAME}/{mid}/cancel")


def other_line(env, op: str, content: str | None = None) -> None:
    """A queue-operation line the pane's session wrote on its own."""
    d = {"type": "queue-operation", "operation": op, "timestamp": iso(int(time.time() * 1000)), "sessionId": SID}
    append(transcript(env), [d if content is None else {**d, "content": content}])


def test_a_dialog_refuses_the_take_back_and_nothing_is_changed(env):
    (m,) = busy_queue(env, "A")
    env.pane.mode = "dialog"
    r = cancel(env, m)
    assert r.status_code == 409 and r.json()["busy"] is True and "dialog" in r.json()["error"] and "nothing was changed" in r.json()["error"]
    assert env.pane.ups == 0 and env.pane.keys == [] and env.pane.edits == [] and env.pane.queue == ["A"]
    assert env.states() == [("A", "queued", None)]
    r = env.client.post(f"/api/outbox/{NAME}/{m}/edit", json={"text": "A2"})
    assert r.status_code == 409 and env.pane.ups == 0 and env.states() == [("A", "queued", None)]


def test_text_in_the_input_line_is_cleared_and_kept_before_the_take_back(env):
    ids = busy_queue(env, "A", "B")
    env.pane.draft = "leftover text"
    r = cancel(env, ids[0])
    assert r.status_code == 200, r.text
    assert [x["text"] for x in cleared(env)] == ["leftover text"]              # not owner's text, but never lost
    assert env.pane.ups == 1 and env.pane.queue == ["B"] and env.pane.draft == ""
    assert env.pane.submitted == ["A", "B", "B"]


def test_a_line_that_cannot_be_cleared_refuses_the_take_back_and_presses_no_up(env):
    (m,) = busy_queue(env, "A")
    env.pane.draft = "stuck text"
    env.pane.stuck = True
    r = cancel(env, m)
    assert r.status_code == 409 and r.json()["busy"] is True and "input line" in r.json()["error"]
    assert env.pane.ups == 0 and env.pane.draft == "stuck text" and env.pane.queue == ["A"]
    assert env.states() == [("A", "queued", None)]


def test_a_queue_that_does_not_read_back_as_salas_is_refused_and_nothing_is_pressed(env):
    (m,) = busy_queue(env, "A")
    other_line(env, "enqueue", "typed by someone else")
    r = cancel(env, m)
    assert r.status_code == 409 and r.json()["busy"] is True and "can not take back" in r.json()["error"]
    assert env.pane.ups == 0 and env.pane.queue == ["A"] and env.states() == [("A", "queued", None)]


def test_the_clis_own_notice_in_the_queue_does_not_stand_in_the_way_and_is_not_typed(env):
    (m,) = busy_queue(env, "A")
    note = "<task-notification><task-id>x1</task-id></task-notification>"
    env.pane.queue.insert(0, note)
    other_line(env, "enqueue", note)
    r = cancel(env, m)
    assert r.status_code == 200, r.text
    assert env.pane.queue == [note] and env.pane.submitted == ["A"]


def test_a_queue_the_session_already_took_is_too_late_and_nothing_is_pressed(env):
    (m,) = busy_queue(env, "A")
    env.pane.queue = []                                                        # the CLI took it: a dequeue line, no Up needed
    other_line(env, "dequeue")
    r = cancel(env, m)
    assert r.status_code == 409 and r.json()["tooLate"] is True and "taken" in r.json()["error"] and r.json()["state"] == "queued"
    assert env.pane.ups == 0 and env.states() == [("A", "queued", None)] and env.pane.submitted == ["A"]


@pytest.mark.parametrize("which", [0, 1], ids=["cancel-the-taken-one", "cancel-a-pulled-one"])
def test_a_turn_that_ends_mid_take_back_loses_nothing_and_types_nothing_twice(env, which):
    ids = busy_queue(env, "A", "B", "C")
    env.pane.takes = 1                                                         # the session takes A as the Up is pressed
    r = cancel(env, ids[which])
    if which == 0:
        assert r.status_code == 409 and r.json()["tooLate"] is True, r.text
        assert env.pane.queue == ["B", "C"] and env.pane.submitted == ["A", "B", "C", "B", "C"]
        assert [x[1] for x in env.states()] == ["queued", "queued", "queued"]
    else:
        assert r.status_code == 200, r.text
        assert env.pane.queue == ["C"] and env.pane.submitted == ["A", "B", "C", "C"]
        assert [x[1] for x in env.states()] == ["queued", "withdrawn", "queued"]
    time.sleep(0.4)
    assert env.pane.submitted.count("A") == 1 and env.pane.draft == "" and env.pane.ups == 1


def test_a_queue_taken_whole_before_the_up_is_too_late_and_the_recalled_prompt_is_cleared(env):
    ids = busy_queue(env, "A", "B")
    env.pane.takes = 2
    env.pane.recall = "B"                                                      # the Up brings the last prompt back from history
    r = cancel(env, ids[1])
    assert r.status_code == 409 and r.json()["tooLate"] is True, r.text
    assert env.pane.draft == "" and cleared(env) == []                          # it is the session's already: not "lost text"
    time.sleep(0.4)
    assert env.pane.submitted == ["A", "B"] and [x[1] for x in env.states()] == ["queued", "queued"]


def test_a_text_that_reached_the_queue_just_before_the_up_is_typed_again_after_the_others(env):
    ids = busy_queue(env, "A", "B")
    env.pane.late = ["typed in the terminal"]
    r = cancel(env, ids[0])
    assert r.status_code == 200, r.text
    assert until(lambda: env.pane.queue == ["B", "typed in the terminal"])
    assert env.pane.submitted == ["A", "B", "B", "typed in the terminal"]


def test_an_up_that_takes_nothing_back_changes_nothing(env):
    ids = busy_queue(env, "A", "B")
    env.pane.up_mute = True
    r = cancel(env, ids[1])
    assert r.status_code == 409 and r.json()["busy"] is True and "nothing back" in r.json()["error"], r.text
    assert env.pane.ups == 1 and env.pane.queue == ["A", "B"] and env.pane.edits == []
    assert [x[1] for x in env.states()] == ["queued", "queued"]
    time.sleep(0.4)
    assert env.pane.submitted == ["A", "B"]
    env.pane.up_mute = False                                                    # asked again, it works
    assert cancel(env, ids[1]).status_code == 200 and env.pane.queue == ["A"]


def test_an_up_that_cannot_be_confirmed_fails_the_queued_messages_with_their_text_kept_and_types_nothing(env):
    ids = busy_queue(env, "A", "B")
    env.pane.up_silent = True
    r = cancel(env, ids[1])
    assert r.status_code == 409 and r.json()["busy"] is True and "could not be confirmed" in r.json()["error"], r.text
    assert env.pane.ups == 1 and env.pane.draft == "" and [x["text"] for x in cleared(env)] == ["A\nB"]
    assert env.states() == [("A", "failed", None), ("B", "failed", None)]
    assert [m["text"] for m in env.msgs()] == ["A", "B"] and all(m["error"] for m in env.msgs())
    time.sleep(0.4)
    assert env.pane.submitted == ["A", "B"]                                  # nothing typed again by the pump


def test_a_multi_line_queued_message_is_typed_again_as_it_was(env):
    two = "line one\n\n  line two, indented"
    korean = "\ud55c\uae00 \uba54\uc2dc\uc9c0"
    ids = busy_queue(env, two, "B", korean, "x" * 9000)
    r = cancel(env, ids[1])
    assert r.status_code == 200, r.text
    assert env.pane.queue == [two, korean, "x" * 9000]
    assert [x[1] for x in env.states()] == ["queued", "withdrawn", "queued", "queued"]


def test_a_queued_message_with_an_upload_is_not_taken_back_and_nothing_is_pressed(env):
    up = env.client.post("/api/upload", content=b"\x89PNG fake", headers={"Content-Type": "image/png"}).json()["name"]
    env.pane.busy = True
    m = env.post("see this", uploads=[up]).json()["message"]
    assert m["state"] == "queued" and m["uploads"] == [up]
    r = cancel(env, m["id"])
    assert r.status_code == 409 and r.json()["busy"] is True and "upload" in r.json()["error"]
    assert env.pane.ups == 0 and env.states()[0][1] == "queued"
    other = env.post("plain one").json()["message"]                              # another one behind it: refused for the same reason
    r = cancel(env, other["id"])
    assert r.status_code == 409 and "upload" in r.json()["error"] and env.pane.ups == 0


def test_an_up_that_was_not_sala_webs_fails_the_pulled_message_with_its_text(env):
    busy_queue(env, "A")
    other_line(env, "popAll", "A")                                             # someone pressed Up in the terminal
    env.pane.queue = []
    assert until(lambda: env.states() == [("A", "failed", None)])
    assert "pulled back" in env.msgs()[0]["error"]
    time.sleep(0.4)
    assert env.pane.submitted == ["A"]


def test_a_message_older_than_the_give_up_is_not_failed_the_moment_its_session_is_not_listed(env):
    env.pane.mode = "dialog"
    m = env.post("slept long").json()["message"]
    box = env.app.state.outbox
    box.update(NAME, m["id"], created=int((time.time() - 2 * AP.OUTBOX_GIVE_UP) * 1000))
    env.row.unlink()
    assert until(lambda: env.states() == [("slept long", "held", "gone")])
    time.sleep(0.4)
    assert env.states() == [("slept long", "held", "gone")]                      # the long while counts from when it went missing
    env.register()
    env.pane.mode = "idle"
    assert until(lambda: env.pane.submitted == ["slept long"])


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


def test_a_message_of_an_earlier_conversation_does_not_stand_in_the_way_of_a_later_one(env):
    old = queued_before(env, "before the clear", env.pid, S.proc_start(env.pid))
    env.app.state.outbox.update(NAME, old["id"], sessionId="bbbbbbbb-0000-0000-0000-000000000000")
    m = env.post("after the clear").json()["message"]
    append(transcript(env), [user_line("after the clear", m["sentAt"] + 400, "00000000-0000-4000-8000-000000000009")])
    assert until(lambda: env.states()[1] == ("after the clear", "delivered", None))
    assert env.states()[0] == ("before the clear", "queued", None) and env.pane.submitted == ["after the clear"]


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
