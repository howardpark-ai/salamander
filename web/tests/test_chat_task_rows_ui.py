"""A background task's notice is not a row of the chat session's view, and still is of every other session's, in a headless Chromium (conftest.py: `served`, `browser`).

The rule and the reads are test_chat_task_rows.py; this holds the page, against the real server and a real transcript. A transcript with a task notification in
the middle of a turn the owner started, one that starts a turn of its own and a message from another session (the one hidden turn that is counted):
  - the chat session's view (SALA_CHAT_SESSION names the session) draws no notice: no fold of a notice, no "finished" text, no empty bubble where it was, and
    the owner's message and the replies are all there, at 390 and 1280 px, the kept-back switch off and on;
  - the kept-back count is the number of kept lines (the other session's message, one), and there is no kept line for the task's turn;
  - the same transcript in a session that is not the chat session shows the notice, folded, with its summary as before.
Polling, no fixed sleeps. All names are invented."""

from __future__ import annotations

import pytest

from conftest import CHAT_READY
from test_board_items_ui import wait_for
from test_chat_kept_ui import LINES, click_switch, open_real, stamp, write
from test_chat_session_view_ui import SIZES, open_page
from test_chat_task_rows import scenario


def prepare(served) -> None:
    write(served, stamp(scenario()))


NOTICES = "document.querySelectorAll('#chat details.fold.notice').length"
EMPTY = """[...document.querySelectorAll('#chat > .msg:not(.kept)')].filter((m) => !m.textContent.trim() && !m.querySelector('img, svg, details, pre')).length"""


@pytest.mark.parametrize("size", SIZES)
def test_the_chat_session_view_draws_no_task_row_and_keeps_everything_else(served, browser, monkeypatch, size):
    prepare(served)
    open_real(browser, served, monkeypatch, size)
    assert wait_for(browser, "document.body.innerText.includes('A drawing task.')", 15.0)
    for _ in range(2):    # the switch off, then on: the kept lines show, the task's notice is in neither
        s = browser.evaluate(LINES)
        assert browser.evaluate(NOTICES) == 0, s["page"]
        assert "finished" not in s["dom"] and "task-notification" not in s["dom"] and "completed" not in s["dom"], s["page"]
        for gone in ("Check demo#1", "Review demo#2", "Draw demo#3", "build"):
            assert gone not in s["page"], (gone, s["page"])
        for shown in ("Check demo-one", "Checked.", "The review of demo#2 is done.", "what is that?", "A drawing task."):
            assert shown in s["page"], (shown, s["page"])
        assert browser.evaluate(EMPTY) == 0, "no empty bubble or gap where the row was"
        assert s["kept"] == 1 and s["count"].startswith("1 "), s       # the other session's message, counted once; none for a task's turn
        assert "Slides drawn." in " ".join(s["text"]), "the other session's message is still a kept line"
        click_switch(browser)
        assert wait_for(browser, "document.querySelectorAll('#chat > .msg.kept').length === 1", 5.0)


@pytest.mark.parametrize("size", SIZES)
def test_the_same_transcript_in_another_session_still_shows_the_notice(served, browser, monkeypatch, size):
    prepare(served)
    open_page(browser, served, monkeypatch, size, None, chat=None)
    assert wait_for(browser, f"{CHAT_READY} && document.body.innerText.includes('A drawing task.')", 15.0)
    text = browser.evaluate("[...document.querySelectorAll('#chat details.fold.notice summary')].map((s) => s.textContent)")
    tasks = [t for t in text if "finished" in t or "completed" in t]
    assert len(tasks) == 4, ("all four task notices, as the ordinary view has always drawn them", text)
    assert any('Agent "Check demo#1" finished' in t for t in tasks), tasks
    assert browser.evaluate("document.querySelectorAll('#chat details.fold.notice[open]').length") == 0, "folded, as before"
