"""The question a session waits on, read from the pane as a card with buttons: api/s/<pid>/dialog says what the screen shows (a question with one
answer, a question with several, a permission dialog, or nothing) and POST api/s/<pid>/dialog answers it.

The rules held here:
  - a multi-select question (rows "1. [ ] Alpha", a free-text row, a Submit row) and a numbered dialog both read as a card with their words, options and
    descriptions; the free-text row has no button; an ordinary screen, a prompt box and a numbered line of the conversation are no card;
  - a choice is one keypress; a choice whose options carry previews takes its number as a focus move and Enter only once the screen shows the focus
    there; an answer carries the words of the question it was made for, and one made for a question the pane no longer shows is refused and sends
    nothing;
  - a multi-select question that is not the last one has its row under the options labelled Next, and the picks go on through that row;
  - a multi-select answer sets only the marks that differ, reads the screen to see the marks are exactly the picks, moves to Submit by reading the screen
    after each Down, and presses Enter; whenever the screen does not read as asked it stops before Enter and says so.

No tmux here: the pane is a small simulation of the screen (tests/fixtures hold the real captures it is made after) and the tmux writes are recorded.
"""

import json
import os
import re
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


def multi_screen(checked: set, focus, button: str = "Submit") -> str:
    """The multi-select question as Claude Code draws it: `checked` option numbers, `focus` a row number (1-4: the last is the free-text row), "submit"
    or "other" (the row below Submit). `button` is "Next" on a question that is not the last one (Claude Code 2.1.332)."""
    def mark(n):
        return "❯ " if focus == n else "  "
    rows = []
    for i, (label, desc) in enumerate(LABELS, 1):
        rows += [f"{mark(i)}{i}. [{'✔' if i in checked else ' '}] {label}", f"         {desc}"]
    rows.append(f"{mark(4)}4. [ ] Type something")
    return "\n".join(["● Asking which letters.", "", RULE, "← ☐ Pick ✔ Submit →", "", "Which letters?", "", *rows,
                      ("❯    " if focus == "submit" else "     ") + button, RULE,
                      ("❯ " if focus == "other" else "  ") + "5. Chat about this", "", "Enter to select · Esc to cancel"])


PREVIEW = (FIX / "synthetic-ask-preview.txt").read_text()
OPTION_LINE_RE = re.compile(r"^(?:❯ | {2})(\d)\. ")


def preview_screen(focus: int) -> str:
    """The single-select question with previews, its focus on option `focus` (the focus mark moves; the preview text is the option's own)."""
    def mark(m):
        return ("❯ " if int(m.group(1)) == focus else "  ") + m.group(1) + ". "
    return "\n".join(OPTION_LINE_RE.sub(mark, ln) for ln in PREVIEW.split("\n"))


def _preview_key(p, key, moves):
    """A digit moves the focus to that option (`moves`), Enter chooses the focused one and clears the question."""
    if key.isdigit() and moves:
        p["screen"] = preview_screen(int(key))
    elif key == "Enter":
        focus = next(int(ln.split(".", 1)[0].strip(" ❯")) for ln in p["screen"].split("\n") if ln.startswith("❯"))
        p["screen"] = (FIX / "capture-empty.txt").read_text()
        p["chosen"] = focus


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
    p = {"screen": (FIX / "capture-dialog.txt").read_text(), "sent": [], "multi": None, "ignore": set(), "on_key": None}
    monkeypatch.setattr(T, "SETTLE_S", 0)

    async def pane_pid(_settings, pane_id):
        return pid

    async def capture(_settings, pane_id):
        m = p["multi"]
        return multi_screen(m["checked"], m["focus"], m.get("button", "Submit")) if m else p["screen"]

    async def send_key(_settings, pane_id, key):
        assert key in T.DIALOG_KEYS or key in T.MULTI_KEYS
        p["sent"].append(key)
        if p["on_key"]:
            p["on_key"](key)
        m = p["multi"]
        if not m or key in p["ignore"]:
            return
        order = [1, 2, 3, 4, "submit", "other"]
        if key.isdigit() and int(key) in (1, 2, 3):
            m["checked"] ^= {int(key)}
        elif key == "Down":
            m["focus"] = order[min(order.index(m["focus"]) + 1, len(order) - 1)]
        elif key == "Enter" and m["focus"] == "submit":
            p["multi"], p["screen"] = None, (REVIEW if m.get("button", "Submit") == "Submit" else (FIX / "capture-empty.txt").read_text())

    monkeypatch.setattr(T, "pane_pid", pane_pid)
    monkeypatch.setattr(T, "capture", capture)
    monkeypatch.setattr(T, "send_key", send_key)
    client = TestClient(create_app(settings))
    p["card"] = lambda: client.get(f"/api/s/{pid}/dialog").json()["card"]
    p["answer"] = lambda body: client.post(f"/api/s/{pid}/dialog", json=body)
    p["open_multi"] = lambda checked=(), focus=1, button="Submit": p.update(multi={"checked": set(checked), "focus": focus, "button": button})
    p["open_preview"] = lambda focus=1, moves=True: p.update(screen=preview_screen(focus), on_key=lambda k: _preview_key(p, k, moves))
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


# ---------- a question with previews (one answer; the number moves the focus, Enter chooses)

def test_the_preview_question_reads_its_options_without_the_preview_text():
    got = T.card(PREVIEW)
    assert got["kind"] == "choice" and got["preview"] is True and got["focus"] == 1
    assert [o["label"] for o in got["options"]] == ["Red", "Blue", "Green"]
    assert got["options"][0]["description"] == "The first colour option"
    assert not any("swatch" in o["label"] or "#" in o["label"] for o in got["options"])


def test_a_dialog_without_previews_is_not_marked_as_having_one():
    assert T.card((FIX / "capture-dialog.txt").read_text())["preview"] is False


def test_a_preview_answer_sends_the_number_then_enter_once_the_focus_moved(pane):
    pane["open_preview"]()
    r = pane["answer"]({"expect": pane["card"]()["text"], "key": "2"})
    assert r.status_code == 200 and r.json()["sent"] == ["2", "Enter"], r.text
    assert pane["sent"] == ["2", "Enter"] and pane["chosen"] == 2


def test_a_preview_answer_to_the_focused_option_still_presses_enter(pane):
    pane["open_preview"](focus=3)
    r = pane["answer"]({"expect": pane["card"]()["text"], "key": "3"})
    assert r.status_code == 200 and pane["sent"] == ["3", "Enter"] and pane["chosen"] == 3


def test_a_preview_answer_whose_focus_does_not_move_presses_no_enter(pane):
    pane["open_preview"](moves=False)
    r = pane["answer"]({"expect": pane["card"]()["text"], "key": "2"})
    assert r.status_code == 409 and "Enter not pressed" in r.json()["error"]
    assert pane["sent"] == ["2"] and pane.get("chosen") is None


# ---------- several answers on a question that is not the last (the row reads Next)

def test_the_next_question_is_a_card_whose_send_button_reads_next():
    got = T.card((FIX / "synthetic-ask-multi-next.txt").read_text())
    assert got["kind"] == "multi" and got["button"] == "Next" and got["focus"] == 1
    assert [(o["n"], o["label"]) for o in got["options"]] == [(1, "Alpha"), (2, "Beta"), (3, "Gamma")]
    assert T.card((FIX / "capture-ask-multi.txt").read_text())["button"] == "Submit"


def test_picks_on_a_next_question_walk_to_the_next_row_and_press_enter(pane):
    pane["open_multi"](button="Next")
    r = pane["answer"]({"expect": pane["card"]()["text"], "picks": [1, 3]})
    assert r.status_code == 200, r.text
    assert pane["sent"] == ["1", "3", "Down", "Down", "Down", "Down", "Enter"]
    assert pane["multi"] is None      # Enter on Next moved on: the pane no longer draws this question


def test_a_next_row_that_cannot_be_reached_says_next_and_presses_no_enter(pane):
    pane["open_multi"](button="Next")
    pane["ignore"].add("Down")
    r = pane["answer"]({"expect": pane["card"]()["text"], "picks": [1]})
    assert r.status_code == 409 and "Next was not pressed" in r.json()["error"] and "Enter" not in pane["sent"]
