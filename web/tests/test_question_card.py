"""The question a session waits on, read from the pane as a card with buttons: api/s/<pid>/dialog says what the screen shows (a question with one
answer, a question with several, a permission dialog, or nothing) and POST api/s/<pid>/dialog answers it.

The rules held here:
  - a multi-select question (rows "1. [ ] Alpha", a free-text row, a Submit row) and a numbered dialog both read as a card with their words, options and
    descriptions; the free-text row has no button; an ordinary screen, a prompt box and a numbered line of the conversation are no card;
  - a choice is one keypress; an answer carries the words of the question it was made for, and one made for a question the pane no longer shows is
    refused and sends nothing;
  - a multi-select answer sets only the marks that differ, reads the screen to see the marks are exactly the picks, moves to Submit by reading the screen
    after each Down, and presses Enter; whenever the screen does not read as asked it stops before Enter and says so.

No tmux here: the pane is a small simulation of the screen (tests/fixtures hold the real captures it is made after) and the tmux writes are recorded.
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
RULE = "─" * 60
LABELS = [("Alpha", "The first letter option"), ("Beta", "The second letter option"), ("Gamma", "The third letter option")]


def multi_screen(checked: set, focus) -> str:
    """The multi-select question as Claude Code draws it: `checked` option numbers, `focus` a row number (1-4: the last is the free-text row), "submit"
    or "other" (the row below Submit)."""
    def mark(n):
        return "❯ " if focus == n else "  "
    rows = []
    for i, (label, desc) in enumerate(LABELS, 1):
        rows += [f"{mark(i)}{i}. [{'✔' if i in checked else ' '}] {label}", f"         {desc}"]
    rows.append(f"{mark(4)}4. [ ] Type something")
    return "\n".join(["● Asking which letters.", "", RULE, "← ☐ Pick ✔ Submit →", "", "Which letters?", "", *rows,
                      ("❯    " if focus == "submit" else "     ") + "Submit", RULE,
                      ("❯ " if focus == "other" else "  ") + "5. Chat about this", "", "Enter to select · Esc to cancel"])


REVIEW = "\n".join(["● Asking which letters.", "", RULE, "Review your answers", "", "Ready to submit your answers?", "",
                    "❯ 1. Submit answers", "  2. Cancel", "", "Enter to select · Esc to cancel"])


@pytest.fixture
def pane(tmp_path, monkeypatch):
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    (claude / "projects").mkdir()
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                        tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"])
    pid = os.getpid()
    rec = {"pid": pid, "sessionId": "aaaaaaaa-0000-0000-0000-000000000000", "cwd": "/tmp", "name": "me",
           "status": "waiting", "tmux": f"me:@0.{PANE}", "procStart": S.proc_start(pid)}
    (claude / "sessions" / f"{pid}.json").write_text(json.dumps(rec))
    p = {"screen": (FIX / "capture-dialog.txt").read_text(), "sent": [], "multi": None, "ignore": set()}
    monkeypatch.setattr(T, "SETTLE_S", 0)

    async def pane_pid(_settings, pane_id):
        return pid

    async def capture(_settings, pane_id):
        m = p["multi"]
        return multi_screen(m["checked"], m["focus"]) if m else p["screen"]

    async def send_key(_settings, pane_id, key):
        assert key in T.DIALOG_KEYS or key in T.MULTI_KEYS
        p["sent"].append(key)
        m = p["multi"]
        if not m or key in p["ignore"]:
            return
        order = [1, 2, 3, 4, "submit", "other"]
        if key.isdigit() and int(key) in (1, 2, 3):
            m["checked"] ^= {int(key)}
        elif key == "Down":
            m["focus"] = order[min(order.index(m["focus"]) + 1, len(order) - 1)]
        elif key == "Enter" and m["focus"] == "submit":
            p["multi"], p["screen"] = None, REVIEW

    monkeypatch.setattr(T, "pane_pid", pane_pid)
    monkeypatch.setattr(T, "capture", capture)
    monkeypatch.setattr(T, "send_key", send_key)
    client = TestClient(create_app(settings))
    p["card"] = lambda: client.get(f"/api/s/{pid}/dialog").json()["card"]
    p["answer"] = lambda body: client.post(f"/api/s/{pid}/dialog", json=body)
    p["open_multi"] = lambda checked=(), focus=1: p.update(multi={"checked": set(checked), "focus": focus})
    return p


# ---------- reading the screen

def test_the_captured_multi_select_question_is_a_card_with_its_options_and_no_free_text_row():
    got = T.card((FIX / "capture-ask-multi.txt").read_text())
    assert got["kind"] == "multi"
    assert [(o["n"], o["label"], o["checked"]) for o in got["options"]] == [(1, "Alpha", False), (2, "Beta", False), (3, "Gamma", False)]
    assert got["options"][0]["description"] == "The first letter option"
    assert got["title"] == "Which letters?" and got["focus"] == 1


def test_the_captured_question_with_marks_and_the_focus_on_submit():
    got = T.card((FIX / "capture-ask-multi-submit.txt").read_text())
    assert [o["checked"] for o in got["options"]] == [True, False, True]
    assert got["focus"] == "submit"


def test_a_permission_dialog_is_a_choice_card_with_its_lines():
    got = T.card((FIX / "capture-dialog.txt").read_text())
    assert got["kind"] == "choice"
    assert [o["n"] for o in got["options"]] == [1, 2, 3, 4]
    assert got["options"][2]["label"] == "No, and ask again next time"
    assert "Allow this read outside the working directories?" in got["title"]


@pytest.mark.parametrize("name", ["capture-empty.txt", "capture-content.txt", "pane-assistant-turn.txt", "capture-shell-mode.txt"])
def test_an_ordinary_screen_is_no_card(name):
    assert T.card((FIX / name).read_text()) is None


def test_one_screen_one_text_whatever_the_focus_and_the_marks_do_to_the_other_rows():
    a, b = T.card(multi_screen({1}, 1)), T.card(multi_screen({1}, 3))
    assert a["text"] == b["text"] and a["text"] != T.card(multi_screen({1, 2}, 1))["text"]


def test_the_page_reads_the_card_from_the_screen(pane):
    assert pane["card"]()["kind"] == "choice"
    pane["open_multi"]()
    assert pane["card"]()["kind"] == "multi"
    pane["multi"] = None
    pane["screen"] = (FIX / "capture-empty.txt").read_text()
    assert pane["card"]() is None
    assert pane["sent"] == []


# ---------- one answer

def test_a_choice_is_one_keypress(pane):
    card = pane["card"]()
    r = pane["answer"]({"expect": card["text"], "key": "3"})
    assert r.status_code == 200 and r.json()["sent"] == ["3"]
    assert pane["sent"] == ["3"]


def test_esc_cancels(pane):
    r = pane["answer"]({"expect": pane["card"]()["text"], "key": "esc"})
    assert r.status_code == 200 and pane["sent"] == ["Escape"]


def test_an_answer_made_for_another_question_sends_nothing(pane):
    stale = pane["card"]()["text"]
    pane["screen"] = (FIX / "capture-menu.txt").read_text()
    r = pane["answer"]({"expect": stale, "key": "1"})
    assert r.status_code == 409 and r.json()["changed"] is True and pane["sent"] == []


def test_a_number_not_offered_and_a_bad_body_send_nothing(pane):
    text = pane["card"]()["text"]
    assert pane["answer"]({"expect": text, "key": "7"}).status_code == 409
    assert pane["answer"]({"expect": text, "picks": [1]}).status_code == 409   # a question of one answer takes no picks
    assert pane["answer"]({"expect": text}).status_code == 400
    assert pane["answer"]({"key": "1"}).status_code == 400
    assert pane["answer"]({"expect": text, "key": "1", "picks": [1]}).status_code == 400
    assert pane["answer"]({"expect": text, "picks": ["1"]}).status_code == 400
    assert pane["sent"] == []


def test_no_question_open_sends_nothing(pane):
    pane["screen"] = (FIX / "capture-empty.txt").read_text()
    assert pane["answer"]({"expect": "x", "key": "1"}).status_code == 409 and pane["sent"] == []


# ---------- several answers

def test_picks_set_the_marks_walk_to_submit_and_press_enter(pane):
    pane["open_multi"]()
    r = pane["answer"]({"expect": pane["card"]()["text"], "picks": [1, 3]})
    assert r.status_code == 200, r.text
    assert pane["sent"] == ["1", "3", "Down", "Down", "Down", "Down", "Enter"]
    assert pane["card"]()["options"][0]["label"] == "Submit answers"      # the review is the next card


def test_a_mark_already_set_is_not_toggled_again(pane):
    pane["open_multi"](checked={2}, focus=2)
    r = pane["answer"]({"expect": pane["card"]()["text"], "picks": [2]})
    assert r.status_code == 200 and pane["sent"] == ["Down", "Down", "Down", "Enter"]


def test_picks_in_any_order_and_none_at_all(pane):
    pane["open_multi"](checked={1, 2}, focus="submit")
    r = pane["answer"]({"expect": pane["card"]()["text"], "picks": []})
    assert r.status_code == 200 and pane["sent"] == ["1", "2", "Enter"]


def test_a_key_that_the_pane_ignores_stops_before_enter(pane):
    pane["open_multi"]()
    text = pane["card"]()["text"]
    pane["ignore"].add("3")
    r = pane["answer"]({"expect": text, "picks": [1, 3]})
    assert r.status_code == 409 and "Submit was not pressed" in r.json()["error"]
    assert "Enter" not in pane["sent"]


def test_a_submit_row_that_cannot_be_reached_stops_before_enter(pane):
    pane["open_multi"]()
    text = pane["card"]()["text"]
    pane["ignore"].add("Down")
    r = pane["answer"]({"expect": text, "picks": [1]})
    assert r.status_code == 409 and "Enter" not in pane["sent"]


def test_the_free_text_row_and_an_unknown_row_cannot_be_picked(pane):
    pane["open_multi"]()
    text = pane["card"]()["text"]
    assert pane["answer"]({"expect": text, "picks": [4]}).status_code == 409
    assert pane["answer"]({"expect": text, "picks": [1, 1]}).status_code == 409
    assert pane["answer"]({"expect": text, "key": "1"}).status_code == 409    # one key is no answer to a question of several
    assert pane["sent"] == []
    assert pane["answer"]({"expect": text, "key": "esc"}).status_code == 200 and pane["sent"] == ["Escape"]


def test_a_changed_mark_between_the_read_and_the_answer_sends_nothing(pane):
    pane["open_multi"]()
    stale = pane["card"]()["text"]
    pane["multi"]["checked"].add(2)
    r = pane["answer"]({"expect": stale, "picks": [1]})
    assert r.status_code == 409 and r.json()["changed"] is True and pane["sent"] == []
