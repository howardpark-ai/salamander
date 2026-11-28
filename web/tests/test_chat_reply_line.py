"""A reply to a done "On it" line (POST /api/outbox/<name> with `reply`), against the made-up pane of test_outbox_send: no tmux, no browser.

The owner answers a done line with its row's Reply button. What a wrong answer costs: a done line that leaves the list with nobody having
answered it (a message that only quotes it, a send that was refused or failed), the wrong line removed, or a session that gets an answer
without knowing which line it is for. Held here:

- a reply is typed with its line quoted in front, and once the server takes it (typed, or held for later) that done line, and no other, leaves;
- no other message removes a line, whatever it quotes or says;
- a refused or failed reply removes nothing; a command cannot be a reply; a reply is never pressed into a dialog as a key;
- an edited reply stays a reply to its line;
- the page words the message as the server does (static/waiting.js replyText, under node when it is there).

All names are invented.
"""

from __future__ import annotations

import json
import subprocess

import pytest

from sala_web import app as AP
from sala_web import motion as MO
from sala_web import outbox as OB
from test_addresses import NODE, needs_node
from test_chat_motion_done import write_motion
from test_outbox_send import NAME, append, env, transcript, until, user_line  # noqa: F401  (env: a fixture)

HEAD = '> In reply to the done "On it" line: '
TOPIC = "research on the cache"
# two done lines of one text, a done line of the same time, an open line of the same text
ROWS = [{"text": TOPIC, "at": 100, "done": 200}, {"text": TOPIC, "at": 101, "done": 201},
        {"text": "another topic", "at": 101, "done": 202}, {"text": TOPIC, "at": 102}]
ANSWERED = {"text": TOPIC, "at": 101}


@pytest.fixture(autouse=True)
def lines(tmp_path, monkeypatch):
    """The chat session is the fake pane's, its motion file is ROWS under a state folder of the test's own; returns a reader of the file."""
    monkeypatch.setenv("SALA_WEB_SALA_STATE", str(tmp_path / "sala"))
    monkeypatch.setenv("SALA_CHAT_SESSION", NAME)
    folder = tmp_path / "sala" / "motion"
    write_motion(folder, NAME, ROWS)
    return lambda: json.loads((folder / f"{NAME}.json").read_text())["lines"]


def without(answered: dict) -> list[dict]:
    return [r for r in ROWS if not ("done" in r and r["text"] == answered["text"] and r["at"] == answered["at"])]


def test_a_reply_removes_its_line_and_no_other_and_the_session_is_told_which(env, lines):
    r = env.post("looks right, go on", reply=ANSWERED, cid="c1")
    assert r.status_code == 200, r.text
    typed = HEAD + TOPIC + "\nlooks right, go on"
    m = r.json()["message"]
    assert (m["state"], m["text"], m["own"], m["reply"]) == ("queued", typed, "looks right, go on", ANSWERED)
    assert env.pane.submitted == [typed]
    assert lines() == without(ANSWERED) and len(lines()) == 3
    again = env.post("looks right, go on", reply=ANSWERED, cid="c1")         # the page asked twice: one message, nothing more removed
    assert again.json()["message"]["id"] == m["id"] and env.pane.submitted == [typed] and lines() == without(ANSWERED)
    append(transcript(env), [user_line(typed, m["sentAt"] + 400, "00000000-0000-4000-8000-000000000001")])
    assert until(lambda: env.states() == [(typed, "delivered", None)]), env.states()   # the transcript's copy is matched by what was typed


def test_a_held_reply_removes_its_line_at_once_and_a_digit_is_not_pressed_into_the_dialog(env, lines):
    env.pane.mode = "dialog"
    m = env.post("2", reply=ANSWERED).json()["message"]
    assert (m["state"], m["reason"]) == ("held", "dialog")
    assert env.pane.keys == [] and env.pane.submitted == []                    # an answer to the line, not to the dialog
    assert lines() == without(ANSWERED)
    env.pane.mode = "idle"
    assert until(lambda: env.pane.submitted == [HEAD + TOPIC + "\n2"]), env.pane.submitted


def test_only_a_reply_removes_a_line_whatever_another_message_quotes(env, lines):
    for text in ("done, thanks", f"> {TOPIC}\nlooks right", HEAD + TOPIC + "\nlooks right", TOPIC):
        r = env.post(text)
        assert r.status_code == 200 and r.json()["message"]["text"] == text, r.text
        assert "reply" not in r.json()["message"] and "own" not in r.json()["message"]
    kept = env.post("plain first", cid="c2").json()["message"]
    again = env.post("plain first", reply=ANSWERED, cid="c2").json()["message"]   # the kept message names no line: nothing to remove
    assert again["id"] == kept["id"] and lines() == ROWS
    assert env.post("now it is a reply", reply=ANSWERED).status_code == 200 and lines() == without(ANSWERED)


BAD_SHAPES = [TOPIC, {}, {"text": TOPIC}, {"at": 101}, {"text": TOPIC, "at": "101"}, {"text": TOPIC, "at": True}, {"text": "", "at": 101},
              {"text": "x" * (MO.MAX_CHARS + 1), "at": 101}, {"text": "two  spaces", "at": 101}, {"text": "two\nlines", "at": 101},
              {"text": "bell\x07", "at": 101}]


@pytest.mark.parametrize("text, reply, chat", [("yes", bad, NAME) for bad in BAD_SHAPES]
                         + [("/status", ANSWERED, NAME), ("  /status", ANSWERED, NAME), ("!ls", ANSWERED, NAME),
                            ("yes", ANSWERED, "another-chat"), ("yes", ANSWERED, "")])
def test_a_refused_reply_removes_nothing_and_keeps_nothing(env, lines, monkeypatch, text, reply, chat):
    monkeypatch.setenv("SALA_CHAT_SESSION", chat)
    r = env.post(text, reply=reply)
    assert r.status_code == 400 and r.json()["ok"] is False, r.text
    assert lines() == ROWS and env.msgs() == [] and env.pane.submitted == [] and env.pane.keys == []


def test_a_reply_that_fails_removes_nothing(env, lines):
    async def box_goes_away(_s, _pane, key):
        env.pane.mode = "blank"

    real = AP.T.send_edit_key
    env.monkeypatch.setattr(AP.T, "send_edit_key", box_goes_away)
    env.pane.draft = "half a thought"                     # cleared before typing, and the box is gone after it: the send fails
    r = env.post("yes", reply=ANSWERED)
    assert r.status_code == 200 and r.json()["message"]["state"] == "failed", r.text
    assert lines() == ROWS and env.pane.submitted == []
    env.monkeypatch.setattr(AP.T, "send_edit_key", real)
    env.pane.mode, env.pane.draft = "idle", ""
    assert env.post("yes again", reply=ANSWERED).json()["message"]["state"] == "queued" and lines() == without(ANSWERED)


def test_a_line_that_cannot_be_written_stays_and_the_reply_is_still_taken(env, lines, monkeypatch):
    def full(*_a):
        raise OSError("no space")

    monkeypatch.setattr(MO, "confirm", full)
    r = env.post("yes", reply=ANSWERED)
    assert r.status_code == 200 and r.json()["message"]["state"] == "queued", r.text
    assert env.pane.submitted == [HEAD + TOPIC + "\nyes"] and lines() == ROWS


def test_an_edited_reply_still_answers_its_line_and_cannot_become_a_command(env, lines):
    env.pane.mode = "dialog"
    old = env.post("first words", reply=ANSWERED).json()["message"]
    refused = env.client.post(f"/api/outbox/{NAME}/{old['id']}/edit", json={"text": "/status"})
    assert refused.status_code == 400 and env.states() == [(HEAD + TOPIC + "\nfirst words", "held", "dialog")], refused.text
    r = env.client.post(f"/api/outbox/{NAME}/{old['id']}/edit", json={"text": "> a quote\nsecond words"})
    assert r.status_code == 200, r.text
    m = r.json()["message"]
    assert (m["own"], m["reply"]) == ("> a quote\nsecond words", ANSWERED)
    assert m["text"] == HEAD + TOPIC + "\n\n> a quote\nsecond words"      # a quote of the owner's stays a block of its own
    env.pane.mode = "idle"
    assert until(lambda: env.pane.submitted == [m["text"]]), env.pane.submitted


@needs_node
def test_the_page_words_a_reply_as_the_server_does():
    cases = [(TOPIC, ""), (TOPIC, "  \n"), (TOPIC, "yes"), (TOPIC, "> quoted\nyes"), (TOPIC, "   > quoted"), (TOPIC, "    > code"),
             ('say "x" & <y>', "two\nlines")]
    script = f"""global.window = {{}}; global.document = {{ addEventListener() {{}} }};
      require({json.dumps(str(AP.STATIC / "waiting.js"))});
      console.log(JSON.stringify({json.dumps(cases)}.map(([line, own]) => window.SalaWaiting.replyText(line, own))));"""
    r = subprocess.run([NODE, "-e", script], capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stderr
    assert json.loads(r.stdout) == [OB.reply_text(line, own) for line, own in cases]
