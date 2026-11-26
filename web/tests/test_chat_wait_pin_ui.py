"""The chat session's "Your move" line is pinned under the header, in a headless Chromium (the text of the page is test_chat_session_view.py; the rest of the
strip is test_chat_session_view_ui.py and test_chat_kept_ui.py).

The rule: what waits on the owner never scrolls away with the thread. #chat-strip-wait is the first child of #chat-pane and sticks to the top of the pane, right under
sala's header. Closed it is one line, a real button with the count ("Your move · 3", aria-expanded false); one click, tap or Enter opens the list under it, and
the whole pinned box stays within 40vh, the list scrolling up and down inside it. With nothing waiting no line is drawn. The motion lines and the kept-back switch
still scroll with the thread. Held here at 1280 x 800 and 390 x 844 (the width rule also at 360 and 320), with api/chat replaced in the page and a real transcript:
  - closed by default: one line with the count, the list hidden, a button the keyboard can use; a click and Enter open and close it, and a read of the strip does not
    close it; with nothing waiting no line is drawn;
  - on a long thread, scrolled to the bottom and to the top, the pinned box's top is the header's bottom, closed and open; open it is never taller than 40vh, the
    list scrolls inside it, and every Answer link stays a link at the address it was given and is not covered;
  - the header and the composer are where they were with the line there or not, and a session that is not the chat session has no line and a thread that starts
    at the top of the pane;
  - NO SIDEWAYS SCROLL, at 1280, 390, 360 and 320 px, closed and open, with long item text (a 300-character word, a long address): the page, the pane, the pinned box and
    its list are never wider than the window.

What a wrong answer costs: a line a long thread carries thousands of pixels away, a list that covers the thread on a phone, a button the keyboard cannot reach, a page that
scrolls sideways. Runs in a headless Chromium when one is installed (conftest.py: `served`, `browser`), else is skipped; GitHub CI runs it. All names are invented."""

from __future__ import annotations

import json
import time

import pytest

from conftest import CHAT_READY, NAME, transcript_file, transcript_line
from test_board_items_ui import wait_for
from test_chat_session_view_ui import DESKTOP, MEASURE, SIZES, URL, WORD, api_chat, check, drawer_open, open_page

LINE = "Your move · 3"
PIN = "document.querySelector('#chat-strip-wait')"
BTN = "document.querySelector('#chat-strip-wait .wait-toggle')"
WIDTHS = [1280, 390, 360, 320]


def moves(n: int = 3, long: bool = False) -> list[dict]:
    """n owner's moves; `long` gives each a subject with a 300-character word and a long address."""
    out = []
    for i in range(n):
        subject = f"Move {i + 1} " + (("an item subject that keeps going and going " * 6) + WORD + " " + URL if long else "to answer")
        out.append({"id": f"item#{i + 1}", "subject": subject, "url": f"https://example.com/moves/{i + 1}"})
    return out


def long_thread(served, pairs: int = 40) -> None:
    text = ""
    for i in range(pairs):
        text += transcript_line("user", [{"type": "text", "text": f"question {i}"}], f"q-{i}", human=True)
        text += transcript_line("assistant", [{"type": "text", "text": ("An answer that goes on and on. " * 30) + str(i)}], f"a-{i}", model="claude-opus-5-5")
    transcript_file(served).write_text(text, encoding="utf-8")


def open_pin(browser, served, monkeypatch, size, waiting=None, thread=True) -> None:
    if thread:
        long_thread(served)
    open_page(browser, served, monkeypatch, size, api_chat(waiting=moves() if waiting is None else waiting))
    assert wait_for(browser, "!document.querySelector('#chat-strip').hidden", 15.0)
    if moves() if waiting is None else waiting:
        assert wait_for(browser, f"!{PIN}.hidden", 15.0)


def click(browser) -> None:
    browser.evaluate(BTN + ".click(); ''")


def state(browser) -> dict:
    return browser.evaluate("""(() => { const p = document.querySelector('#chat-strip-wait'), b = p.querySelector('.wait-toggle'), w = p.querySelector('.wait'),
      top = document.querySelector('#top').getBoundingClientRect(), pane = document.querySelector('#chat-pane').getBoundingClientRect(), r = p.getBoundingClientRect(),
      shown = (n) => n.getClientRects().length > 0;
      return { hidden: p.hidden, pinShown: shown(p), listShown: shown(w), expanded: b.getAttribute('aria-expanded'), tag: b.tagName, type: b.type, text: b.textContent.trim(),
               title: b.title, pinTop: r.top, pinH: r.height, pinW: r.width, headBottom: top.bottom, paneTop: pane.top, vh: window.innerHeight,
               listScroll: [w.scrollHeight, w.clientHeight], listOverflow: [getComputedStyle(w).overflowY, getComputedStyle(w).overflowX],
               pos: getComputedStyle(p).position, rows: p.querySelectorAll('.wait-row').length }; })()""")


def scroll_pane(browser, to_bottom: bool) -> int:
    top = browser.evaluate("(() => { const p = document.querySelector('#chat-pane'); p.scrollTop = " + ("p.scrollHeight" if to_bottom else "0") + "; return Math.round(p.scrollTop); })()")
    time.sleep(0.3)
    return top


# ── the line ─────────────────────────────────────────────────────────────────
@pytest.mark.parametrize("size", SIZES)
def test_closed_by_default_one_line_with_the_count_and_a_real_button(served, browser, monkeypatch, size):
    open_pin(browser, served, monkeypatch, size)
    s = state(browser)
    assert s["pinShown"] and not s["hidden"] and s["pos"] == "sticky", s
    assert s["tag"] == "BUTTON" and s["type"] == "button" and s["text"] == LINE and s["expanded"] == "false", s
    assert not s["listShown"] and s["pinH"] <= 48, s                    # one line: the list is not drawn, the box is as high as its button
    assert s["title"] == "Show your move list", s
    assert browser.evaluate(BTN + ".getAttribute('aria-controls') === document.querySelector('#chat-strip-wait .wait').id")


@pytest.mark.parametrize("size", SIZES)
def test_a_click_opens_the_list_and_a_second_closes_it_and_a_read_of_the_strip_leaves_it(served, browser, monkeypatch, size):
    open_pin(browser, served, monkeypatch, size)
    click(browser)
    s = state(browser)
    assert s["expanded"] == "true" and s["listShown"] and s["rows"] == 3 and s["title"] == "Hide the list", s
    browser.evaluate("window.__chat = Object.assign({}, window.__chat, { waiting: window.__chat.waiting.concat([{ id: 'item#9', subject: 'A late move', url: '' }]) }); loadChatMarks(); ''")
    assert wait_for(browser, f"{PIN}.querySelectorAll('.wait-row').length === 4", 10.0)
    s = state(browser)
    assert s["expanded"] == "true" and s["listShown"] and s["text"] == "Your move · 4", s     # a read changes the count and keeps the list open
    click(browser)
    s = state(browser)
    assert s["expanded"] == "false" and not s["listShown"] and s["pinShown"], s


def test_the_keyboard_reaches_the_button_and_enter_opens_and_closes_it(served, browser, monkeypatch):
    open_pin(browser, served, monkeypatch, DESKTOP)
    assert browser.evaluate(BTN + ".tabIndex") >= 0 and browser.evaluate(BTN + ".disabled") is False
    browser.evaluate(BTN + ".focus(); ''")
    assert browser.evaluate("document.activeElement === " + BTN)
    for want in ("true", "false"):
        browser.send("Input.dispatchKeyEvent", {"type": "keyDown", "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13, "text": "\r"})
        browser.send("Input.dispatchKeyEvent", {"type": "keyUp", "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13})
        assert wait_for(browser, f"{BTN}.getAttribute('aria-expanded') === '{want}'", 5.0), want
    assert browser.evaluate("document.activeElement === " + BTN), "the focus stays on the button"


@pytest.mark.parametrize("size", SIZES)
def test_with_nothing_waiting_no_line_is_drawn_and_it_comes_back_with_a_move(served, browser, monkeypatch, size):
    open_pin(browser, served, monkeypatch, size, waiting=[])
    s = state(browser)
    assert s["hidden"] and not s["pinShown"] and s["pinH"] == 0, s
    browser.evaluate("window.__chat = Object.assign({}, window.__chat, { waiting: [{ id: 'item#1', subject: 'One move', url: '' }] }); loadChatMarks(); ''")
    assert wait_for(browser, f"!{PIN}.hidden", 10.0)
    assert state(browser)["text"] == "Your move · 1"


# ── pinned ───────────────────────────────────────────────────────────────────
@pytest.mark.parametrize("opened", [False, True], ids=["closed", "open"])
@pytest.mark.parametrize("size", SIZES)
def test_on_a_long_thread_the_line_stays_at_the_header_whether_the_thread_is_at_the_top_or_the_bottom(served, browser, monkeypatch, size, opened):
    open_pin(browser, served, monkeypatch, size, waiting=moves(12, long=True))
    if opened:
        click(browser)
    before = state(browser)
    assert before["pinShown"] and abs(before["pinTop"] - before["headBottom"]) < 1, before
    far = scroll_pane(browser, True)
    assert far > 2000, f"the thread is long enough to prove it: scrolled {far}px"
    bottom = state(browser)
    assert abs(bottom["pinTop"] - bottom["headBottom"]) < 1 and bottom["pinShown"], bottom
    assert scroll_pane(browser, False) == 0
    top = state(browser)
    assert abs(top["pinTop"] - top["headBottom"]) < 1 and top["pinH"] == bottom["pinH"] == before["pinH"], (before, bottom, top)
    # in the middle of the thread too
    browser.evaluate("(() => { const p = document.querySelector('#chat-pane'); p.scrollTop = Math.round(p.scrollHeight / 2); return ''; })()")
    time.sleep(0.3)
    assert abs(state(browser)["pinTop"] - top["headBottom"]) < 1


@pytest.mark.parametrize("size", SIZES)
def test_open_it_is_never_taller_than_40vh_the_list_scrolls_inside_and_the_answers_are_links(served, browser, monkeypatch, size):
    open_pin(browser, served, monkeypatch, size, waiting=moves(30, long=True))
    click(browser)
    s = state(browser)
    assert s["pinH"] <= 0.4 * s["vh"] + 0.5, s
    assert s["listScroll"][0] > s["listScroll"][1], f"thirty long moves do not fit: the list scrolls inside the box: {s}"
    assert s["listOverflow"] == ["auto", "hidden"], s                   # up and down only
    got = browser.evaluate("""(() => { const a = document.querySelector('#chat-strip-wait .wait-row .answer'), r = a.getBoundingClientRect(), w = document.querySelector('#chat-strip-wait').getBoundingClientRect();
      const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
      return { href: a.getAttribute('href'), target: a.target, text: a.textContent, inside: r.top >= w.top && r.bottom <= w.bottom, covered: hit !== a && !a.contains(hit) }; })()""")
    assert got == {"href": "https://example.com/moves/1", "target": "_blank", "text": "Answer", "inside": True, "covered": False}, got
    # the list scrolls: the last move is reachable, the box does not grow and the thread's own scroll does not move
    before = browser.evaluate("document.querySelector('#chat-pane').scrollTop")
    # the list reaches its end and the box does not grow. A row of a long word and a long address may be taller than the box on a phone, and its Answer link sits on the row's
    # first line (baseline alignment), so the link is brought into view the way a person would: scrolled to inside the list, then measured.
    END = """(() => { const w = document.querySelector('#chat-strip-wait .wait'); w.style.scrollBehavior = 'auto'; w.scrollTop = w.scrollHeight;
      return { top: Math.round(w.scrollTop), max: Math.round(w.scrollHeight - w.clientHeight), h: document.querySelector('#chat-strip-wait').getBoundingClientRect().height }; })()"""
    end = browser.evaluate(END)
    assert end["top"] == end["max"] > 0 and end["h"] <= 0.4 * s["vh"] + 0.5, end
    REACH = """(() => { const rows = document.querySelectorAll('#chat-strip-wait .wait-row'), a = rows[rows.length - 1].querySelector('.answer'), w = document.querySelector('#chat-strip-wait .wait');
      w.style.scrollBehavior = 'auto'; a.scrollIntoView({ block: 'nearest' });
      const r = a.getBoundingClientRect(), b = document.querySelector('#chat-strip-wait').getBoundingClientRect();
      return { inside: r.top >= b.top && r.bottom <= b.bottom + 1, answer: [Math.round(r.top), Math.round(r.bottom)], box: [Math.round(b.top), Math.round(b.bottom)], h: b.height }; })()"""
    assert wait_for(browser, "(" + REACH + ").inside", 3.0), browser.evaluate(REACH)       # polled: the scroll may take a frame or two to land
    last = browser.evaluate(REACH)
    assert last["inside"] and last["h"] <= 0.4 * s["vh"] + 0.5, last
    assert browser.evaluate("document.querySelector('#chat-pane').scrollTop") == before


@pytest.mark.parametrize("size", SIZES)
def test_the_header_and_the_composer_do_not_move_with_the_line_there_open_or_not(served, browser, monkeypatch, size):
    rects = """(() => { const q = (s) => { const r = document.querySelector(s).getBoundingClientRect(); return [r.left, r.top, r.width, r.height].map((x) => Math.round(x * 10) / 10); };
      return { top: q('#top'), composer: q('#composer'), input: q('#composer-editor'), count: document.querySelectorAll('#composer').length }; })()"""
    open_pin(browser, served, monkeypatch, size, waiting=[])
    none = browser.evaluate(rects)
    browser.evaluate("window.__chat = Object.assign({}, window.__chat, { waiting: " + json.dumps(moves(12, long=True)) + " }); loadChatMarks(); ''")
    assert wait_for(browser, f"!{PIN}.hidden", 10.0)
    closed = browser.evaluate(rects)
    click(browser)
    opened = browser.evaluate(rects)
    assert none == closed == opened and none["count"] == 1, (none, closed, opened)


@pytest.mark.parametrize("size", SIZES)
def test_another_session_has_no_line_and_its_thread_starts_at_the_top_of_the_pane(served, browser, monkeypatch, size):
    long_thread(served, pairs=3)
    open_page(browser, served, monkeypatch, size, api_chat(session="demo-someone-else", waiting=moves()), chat="demo-someone-else")
    assert wait_for(browser, "!document.querySelector('#side-chat').hidden", 8.0)
    browser.evaluate("document.querySelector('#chat-pane').scrollTop = 0; ''")       # the page opens at the newest message: measure from the top of the pane
    time.sleep(0.3)
    s = browser.evaluate("""(() => { const p = document.querySelector('#chat-strip-wait'), pane = document.querySelector('#chat-pane').getBoundingClientRect(),
      chat = document.querySelector('#chat').getBoundingClientRect(), strip = document.querySelector('#chat-strip');
      return { pinHidden: p.hidden, pinRects: p.getClientRects().length, pinH: p.getBoundingClientRect().height, stripHidden: strip.hidden, cls: document.body.classList.contains('chat-session'),
               gap: Math.round(chat.top - pane.top + document.querySelector('#chat-pane').scrollTop), buttons: document.querySelectorAll('#chat-strip-wait .wait-toggle').length }; })()""")
    assert s == {"pinHidden": True, "pinRects": 0, "pinH": 0, "stripHidden": True, "cls": False, "gap": 0, "buttons": 0}, s


# ── no sideways scroll ───────────────────────────────────────────────────────
PIN_WIDTHS = """(() => { const root = document.scrollingElement, p = document.querySelector('#chat-strip-wait'), w = p.querySelector('.wait'), b = p.querySelector('.wait-toggle'),
  pane = document.querySelector('#chat-pane'), over = [];
  for (const n of p.querySelectorAll('*')) { if (!n.getClientRects().length) continue; const r = n.getBoundingClientRect(); if (r.right > document.documentElement.clientWidth + 0.5 || r.left < -0.5) over.push(n.className + ' ' + Math.round(r.left) + '-' + Math.round(r.right)); }
  return { doc: [root.scrollWidth, root.clientWidth], body: [document.body.scrollWidth, document.body.clientWidth], pane: [pane.scrollWidth, pane.clientWidth],
           pin: [p.scrollWidth, p.clientWidth], list: [w.scrollWidth, w.clientWidth], btn: [b.scrollWidth, b.clientWidth], listShown: w.getClientRects().length > 0, over, vw: document.documentElement.clientWidth }; })()"""


@pytest.mark.parametrize("opened", [False, True], ids=["closed", "open"])
@pytest.mark.parametrize("drawer", [False, True], ids=["drawer-shut", "drawer-open"])
@pytest.mark.parametrize("width", WIDTHS)
def test_no_sideways_scroll_with_the_line_closed_and_open_and_long_item_text(served, browser, monkeypatch, width, drawer, opened):
    open_pin(browser, served, monkeypatch, (width, 800 if width > 700 else 844), waiting=moves(5, long=True))
    assert wait_for(browser, f"{PIN}.querySelectorAll('.wait-row').length === 5", 10.0)
    if width < 700:
        browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 844, "deviceScaleFactor": 1, "mobile": True})
        assert wait_for(browser, f"document.documentElement.clientWidth === {width}", 10.0)
        if drawer:
            drawer_open(browser)
    if opened:
        click(browser)
    browser.settle(PIN)
    where = f"{width} px, drawer {'open' if drawer else 'shut'}, line {'open' if opened else 'closed'}"
    p = browser.evaluate(PIN_WIDTHS)
    assert p["vw"] == width and p["listShown"] is opened, (where, p)
    assert p["doc"][0] <= p["doc"][1] and p["body"][0] <= p["body"][1] and p["pane"][0] <= p["pane"][1], f"{where}: the page or the pane scrolls sideways: {p}"
    assert p["pin"][0] <= p["pin"][1] and p["list"][0] <= p["list"][1] and p["btn"][0] <= p["btn"][1], f"{where}: the line or its list scrolls sideways: {p}"
    assert p["over"] == [], f"{where}: something of the line ends outside the window: {p}"
    check(browser.evaluate(MEASURE), where)


@pytest.mark.parametrize("width", WIDTHS)
def test_the_open_list_does_not_cover_the_thread_on_a_phone(served, browser, monkeypatch, width):
    open_pin(browser, served, monkeypatch, (width, 800 if width > 700 else 844), waiting=moves(30, long=True))
    if width < 700:
        browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 844, "deviceScaleFactor": 1, "mobile": True})
        assert wait_for(browser, f"document.documentElement.clientWidth === {width}", 10.0)
    click(browser)
    browser.settle(PIN)
    s = state(browser)
    assert s["pinH"] <= 0.4 * s["vh"] + 0.5, s
    # what is left of the pane under the open line is the thread's: a quarter of the window at least
    assert browser.evaluate("document.querySelector('#chat-pane').getBoundingClientRect().height - document.querySelector('#chat-strip-wait').getBoundingClientRect().height") > 0.25 * s["vh"], s
