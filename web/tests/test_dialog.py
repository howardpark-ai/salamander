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
        if "after_paste" in p:  # what the pane draws once the text is in it
            p["screen"] = p.pop("after_paste")

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


# --- a long message: the pane's box scrolls, its "❯" line leaves the view and its top rule says "↑ N more" ------------

RULE = "─" * 60
LONG = "\n".join(["first line of the long message", "second line", "third line", "fourth line", "fifth line", "sixth line"])


def _rule(label=None):
    return RULE if label is None else "─" * 24 + f" {label} " + "─" * 24


def _pane_with(box_lines, top=None, bottom=None):
    """A pane screen: old output, the top rule, the box's lines, the bottom rule (each rule with an optional label)
    and a footer."""
    return "\n".join(["old output", _rule(top), *box_lines, _rule(bottom), "  ? for shortcuts", ""])


EMPTY = _pane_with(['❯ \x1b[2mTry "something"\x1b[0m'])
SCROLLED = _pane_with(["  third line", "  fourth line", "  fifth line", "  sixth line"], top="↑ 2 more")


def test_a_long_message_whose_box_scrolls_is_submitted(pane):
    # after the paste the box shows only its tail: before, the send answered "the input box disappeared while pasting"
    pane["screen"] = EMPTY
    pane["after_paste"] = SCROLLED
    r = pane["send"](LONG)
    assert r.status_code == 200, r.text
    assert pane["sent"] == [("paste", LONG), ("key", "Enter")]


def test_retry_submits_the_message_already_in_a_scrolled_box(pane):
    pane["screen"] = SCROLLED
    r = pane["send"](LONG, retry=True)
    assert r.status_code == 200, r.text
    assert r.json()["ok"] and r.json()["imagesPasted"] == 0
    assert pane["sent"] == [("key", "Enter")]  # nothing pasted a second time


@pytest.mark.parametrize("screen", [
    _pane_with(["❯ " + LONG.replace("\n", "\n  ")]),  # whole in its box
    _pane_with(["❯ first line of the long message", "  second line", "  third line"], bottom="↓ 3 more"),  # cut off below
], ids=["whole", "cut-off-below"])
def test_retry_submits_a_message_whole_in_its_box_and_one_cut_off_below(pane, screen):
    pane["screen"] = screen
    assert pane["send"](LONG, retry=True).status_code == 200
    assert pane["sent"] == [("key", "Enter")]


REFUSED = "pane input box is not empty; nothing sent"
LINES = LONG.split("\n")


def _refused(pane, screen, message=LONG):
    pane["screen"] = screen
    r = pane["send"](message, retry=True)
    assert r.status_code == 409 and r.json()["error"] == REFUSED, r.text
    assert pane["sent"] == []  # nothing pasted, no Enter


def test_retry_never_submits_the_owners_own_shorter_text_when_the_whole_box_is_visible(pane):
    # the box holds the owner's "deploy to production", the Retry is for "deploy to production after approval":
    # the box hides nothing, so its text is not the retried message and Enter would send something else
    _refused(pane, _pane_with(["❯ deploy to production"]), "deploy to production after approval")
    _refused(pane, _pane_with(["❯ production after approval"]), "deploy to production after approval")
    # a whole box that holds the head or the tail of the long message is refused the same way
    _refused(pane, _pane_with(["❯ " + "\n  ".join(LINES[:3])]))
    _refused(pane, _pane_with(["❯ " + "\n  ".join(LINES[2:])]))


def test_retry_submits_a_box_whose_top_rule_says_more_above_and_that_holds_the_tail(pane):
    pane["screen"] = _pane_with(["  " + "\n  ".join(LINES[2:])], top="↑ 2 more")
    assert pane["send"](LONG, retry=True).status_code == 200
    assert pane["sent"] == [("key", "Enter")]


def test_retry_refuses_a_box_with_more_above_that_holds_a_head_of_the_message(pane):
    _refused(pane, _pane_with(["  " + "\n  ".join(LINES[:3])], top="↑ 2 more"))


def test_retry_submits_a_glyph_box_whose_bottom_rule_says_more_below_and_that_holds_the_head(pane):
    pane["screen"] = _pane_with(["❯ " + "\n  ".join(LINES[:3])], bottom="↓ 3 more")
    assert pane["send"](LONG, retry=True).status_code == 200
    assert pane["sent"] == [("key", "Enter")]


def test_retry_refuses_a_box_with_more_below_that_holds_a_tail_of_the_message(pane):
    _refused(pane, _pane_with(["❯ " + "\n  ".join(LINES[3:])], bottom="↓ 3 more"))


def test_retry_submits_a_middle_slice_when_both_rules_say_more(pane):
    pane["screen"] = _pane_with(["  " + "\n  ".join(LINES[2:4])], top="↑ 2 more", bottom="↓ 2 more")
    assert pane["send"](LONG, retry=True).status_code == 200
    assert pane["sent"] == [("key", "Enter")]


def test_retry_submits_a_box_equal_to_the_message_with_no_label(pane):
    pane["screen"] = _pane_with(["❯ " + "\n  ".join(LINES)])
    assert pane["send"](LONG, retry=True).status_code == 200
    assert pane["sent"] == [("key", "Enter")]


def test_retry_takes_the_labels_from_the_box_it_reads_not_from_another_rule(pane):
    # an earlier rule in the pane says "↑ 2 more"; the live box is whole, so a tail in it is refused
    old = "\n".join([_rule("↑ 2 more"), "  old tail", RULE, "answer"])
    _refused(pane, old + "\n" + _pane_with(["❯ " + "\n  ".join(LINES[2:])]))


def test_retry_with_other_text_in_the_box_is_refused_and_sends_nothing(pane):
    for screen in (_pane_with(["  something the owner was typing", "  on two lines"], top="↑ 1 more"),
                   _pane_with(["❯ something else entirely"])):
        pane["screen"] = screen
        r = pane["send"](LONG, retry=True)
        assert r.status_code == 409 and r.json()["error"] == "pane input box is not empty; nothing sent"
    assert pane["sent"] == []


def test_a_send_that_is_not_a_retry_into_a_box_with_text_is_refused_even_when_it_matches(pane):
    pane["screen"] = SCROLLED
    r = pane["send"](LONG)
    assert r.status_code == 409 and r.json()["error"] == "pane input box is not empty; nothing sent"
    r = pane["send"](LONG, retry=False)
    assert r.status_code == 409 and "not empty" in r.json()["error"]
    assert pane["sent"] == []


def test_retry_into_an_empty_box_pastes_as_a_send_does(pane):
    pane["screen"] = EMPTY
    assert pane["send"](LONG, retry=True).status_code == 200
    assert pane["sent"] == [("paste", LONG), ("key", "Enter")]


def test_a_retry_right_after_a_refused_send_is_not_taken_for_a_double_submit(pane):
    # the first send was refused (nothing on a 409 is recorded as sent), so a Retry inside DUP_WINDOW is no copy
    pane["screen"] = EMPTY
    pane["after_paste"] = "old output\nno box here\n"
    r = pane["send"](LONG)
    assert r.status_code == 409 and "disappeared while pasting" in r.json()["error"]
    pane["screen"] = SCROLLED
    r = pane["send"](LONG, retry=True)
    assert r.status_code == 200 and not r.json().get("duplicate"), r.text
    assert pane["sent"] == [("paste", LONG), ("key", "Enter")]
    # a second Retry straight after the success is the double submit the window exists for
    pane["screen"] = SCROLLED
    r = pane["send"](LONG, retry=True)
    assert r.status_code == 409 and r.json()["duplicate"]
    assert pane["sent"] == [("paste", LONG), ("key", "Enter")]
