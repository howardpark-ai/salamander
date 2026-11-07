"""Answering a dialog from Chat: with no input box but a numbered dialog in the pane, an option number goes in as one
keypress and "esc" as Escape; anything else is refused with the options listed.

No tmux here: the pane is a captured screen (tests/fixtures) and the tmux writes are recorded, not made.
"""

import json
import os
from pathlib import Path

import pytest
from starlette.testclient import TestClient

from sala_web import sessions as S
from sala_web import tmuxio as T
from sala_web.app import create_app
from sala_web.config import Settings

FIX = Path(__file__).parent / "fixtures"
PANE = "%7"


@pytest.fixture
def pane(tmp_path, monkeypatch):
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    (claude / "projects").mkdir()
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                        tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"])
    # this test process stands in for the session, its pane is PANE
    pid = os.getpid()
    rec = {"pid": pid, "sessionId": "aaaaaaaa-0000-0000-0000-000000000000", "cwd": "/tmp", "name": "me",
           "status": "idle", "tmux": f"me:@0.{PANE}", "procStart": S.proc_start(pid)}
    (claude / "sessions" / f"{pid}.json").write_text(json.dumps(rec))
    p = {"screen": (FIX / "capture-dialog.txt").read_text(), "sent": []}

    async def pane_pid(_settings, pane_id):
        assert pane_id == PANE
        return pid

    async def capture(_settings, pane_id):
        return p["screen"]

    async def send_key(_settings, pane_id, key):
        assert key in T.DIALOG_KEYS
        p["sent"].append(("key", key))

    async def paste(_settings, pane_id, text):
        p["sent"].append(("paste", text))

    async def send_enter(_settings, pane_id):
        p["sent"].append(("key", "Enter"))

    monkeypatch.setattr(T, "pane_pid", pane_pid)
    monkeypatch.setattr(T, "capture", capture)
    monkeypatch.setattr(T, "send_key", send_key)
    monkeypatch.setattr(T, "paste", paste)
    monkeypatch.setattr(T, "send_enter", send_enter)
    client = TestClient(create_app(settings))
    p["send"] = lambda text, **kw: client.post(f"/api/s/{pid}/send", json={"text": text, **kw})
    return p


def test_option_number_answers_the_dialog_with_one_keypress(pane):
    r = pane["send"](" 4\n")
    assert r.status_code == 200, r.text
    assert r.json()["dialogAnswer"] == "4"
    assert pane["sent"] == [("key", "4")]  # the digit alone: no paste, no Enter


def test_esc_cancels_the_dialog(pane):
    r = pane["send"]("Esc")
    assert r.status_code == 200, r.text
    assert pane["sent"] == [("key", "Escape")]


def test_number_not_offered_is_refused(pane):
    for text in ("5", "0", "12"):
        r = pane["send"](text)
        assert r.status_code == 409
        assert r.json()["error"] == (f"a dialog is open in the pane and {text} is not one of its options: "
                                     "answer with one of 1, 2, 3, 4, or esc; nothing sent")
    assert pane["sent"] == []


def test_free_text_is_refused_with_the_options_listed(pane):
    r = pane["send"]("yes please")
    assert r.status_code == 409
    assert r.json()["error"] == "a dialog is open in the pane: answer with one of 1, 2, 3, 4, or esc; nothing sent"
    assert pane["sent"] == []


def test_no_box_and_no_dialog_keeps_the_old_refusal(pane):
    pane["screen"] = "some output\nno box here\n"
    r = pane["send"]("1")
    assert r.status_code == 409 and r.json()["error"].startswith("no input box in the pane")
    assert pane["sent"] == []


def test_same_answer_to_the_next_dialog_is_not_a_double_submit(pane):
    assert pane["send"]("1").status_code == 200
    # the same dialog still showing: the copy is refused
    r = pane["send"]("1")
    assert r.status_code == 409 and r.json()["duplicate"]
    # the box is back: a copy now would be typed as a prompt, so it is refused too
    pane["screen"] = (FIX / "capture-empty.txt").read_text()
    assert pane["send"]("1").json().get("duplicate")
    # another dialog: "1" again is its answer
    pane["screen"] = (FIX / "capture-dialog.txt").read_text().replace("/etc/hostname", "/etc/hosts")
    assert pane["send"]("1").status_code == 200
    assert pane["sent"] == [("key", "1"), ("key", "1")]


def test_input_box_path_unchanged(pane):
    # with the input box showing, a digit is a prompt like any other: pasted, then Enter
    pane["screen"] = (FIX / "capture-empty.txt").read_text()
    r = pane["send"]("4")
    assert r.status_code == 200, r.text
    assert "dialogAnswer" not in r.json()
    assert pane["sent"] == [("paste", "4"), ("key", "Enter")]
    pane["screen"] = (FIX / "capture-content.txt").read_text()
    r = pane["send"]("other text")
    assert r.status_code == 409 and "not empty" in r.json()["error"]
