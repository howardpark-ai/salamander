"""The chat session's "Your move" line is pinned under the header, in a headless Chromium (the text of the page is test_chat_session_view.py; the rest of the
strip is test_chat_session_view_ui.py and test_chat_kept_ui.py).

The rule: what waits on the owner never scrolls away with the thread. #chat-strip-wait is the first child of #chat-pane and sticks to the top of the pane, right under
sala's header. Closed it is one line, a real button with the count ("Your move · 3", aria-expanded false); one click, tap or Enter opens the list under it, and
the whole pinned box stays within 40vh, the list scrolling up and down inside it. With nothing waiting no line is drawn. The motion lines and the kept-back switch
still scroll with the thread. Held here at 1280 x 800 and 390 x 844 (the width rule also at 360 and 320), with api/chat replaced in the page and a real transcript:
  - closed by default: one line with the count, the list hidden, a button the keyboard can use; a click and Enter open and close it, and a read of the strip does not
    close it; with nothing waiting no line is drawn;
  - on a long thread, scrolled to the bottom and to the top, the pinned box's top is the header's bottom, closed and open; open it is never taller than 40vh, the
    list scrolls inside it, and every row shows its id and its title as the one link to the item (the address it was given, a new tab, no "Answer" link), not covered;
  - the open list has no heading row of its own (the pinned line is the one heading; the panel's aria-label is the line's text), and each row hangs from its dot: the dot
    is on the title's first line (never alone on a line, also for a 300-character word and a long Korean title with a long address at 1280, 390, 360 and 320), and a
    wrapped line starts at the content's left edge, under the id, never under the dot;
  - the box covers the thread cleanly: opaque panel colour, a 1 px bottom border and a soft shadow, and the list's own scroll ends with 12 px under the last row;
  - each row shows the board id as a plain, selectable label before the title (the id as written; a row with no id shows the title alone, a row with no address shows the
    title as plain text, a row with no subject shows the id once as its title); the title is a keyboard-focusable link with a 44 px touch target on a touch screen;
  - the header and the composer are where they were with the line there or not, and a session that is not the chat session has no line and a thread that starts
    at the top of the pane;
  - the open list shows that it scrolls: at 390 px with eight long moves a soft band of the text colour sits on the list's last 24 px at first open (read as a pixel of a
    screenshot, in the gutter beside the rows where no text or line is, against a pixel of the same gutter near the top), and it is gone once the list is scrolled to its end,
    where the last row's title link is not covered; no sideways scroll with it showing;
  - a "new" tag that wraps onto a line of its own starts at the left edge of the id (the content's left edge), and one that follows the title on the same line keeps its 8 px gap;
  - NO SIDEWAYS SCROLL, at 1280, 390, 360 and 320 px, closed and open, with long item text (an 80-character id, a 300-character word, a long address): the page, the
    pane, the pinned box, its list and every id and title inside its row are never wider than the window.

What a wrong answer costs: a line a long thread carries thousands of pixels away, a list that covers the thread on a phone, a button the keyboard cannot reach, a page that
scrolls sideways. Runs in a headless Chromium when one is installed (conftest.py: `served`, `browser`), else is skipped; GitHub CI runs it. All names are invented."""

from __future__ import annotations

import base64
import json
import time
import zlib

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
        out.append({"id": f"demo#{i + 1}", "subject": subject, "url": f"https://example.com/moves/{i + 1}"})
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


# The index-th row's id label and title link, after the link is scrolled to the way a person would (the list's own scroll, `nearest`; a row may be taller than the box on a
# phone, so what is measured is the slice of the link that shows inside the box). `seen`: some of the link is inside the box and the point in the middle of that slice
# lands on the link (nothing covers it) and the id label is real text of the same row, before the link. Pure reads apart from the scroll: poll it, never sleep.
LINK_AT = """(() => { const rows = document.querySelectorAll('#chat-strip-wait .wait-row'), row = rows[__INDEX__], a = row.querySelector('a'), id = row.querySelector('.wait-id'),
  w = document.querySelector('#chat-strip-wait .wait'); w.style.scrollBehavior = 'auto'; a.scrollIntoView({ block: 'nearest' });
  const r = a.getBoundingClientRect(), b = document.querySelector('#chat-strip-wait').getBoundingClientRect(), wr = w.getBoundingClientRect();
  const top = Math.max(r.top, wr.top), bottom = Math.min(r.bottom, wr.bottom), ok = bottom - top >= Math.min(r.height, 16) && top >= b.top - 0.5 && bottom <= b.bottom + 0.5;
  const hit = ok ? document.elementFromPoint(r.left + Math.min(r.width, 40) / 2, (top + bottom) / 2) : null;
  return { seen: ok && !!hit && (hit === a || a.contains(hit)), covered: ok ? !(hit === a || a.contains(hit)) : null, h: b.height, rows: rows.length,
           id: id ? id.textContent : null, idIsText: !!id && id.firstChild.nodeType === 3 && getComputedStyle(id).userSelect !== 'none', idBefore: !!id && !!(id.compareDocumentPosition(a) & Node.DOCUMENT_POSITION_FOLLOWING),
           text: a.textContent, href: a.getAttribute('href'), target: a.target, rel: a.rel, tab: a.tabIndex, box: [Math.round(b.top), Math.round(b.bottom)], link: [Math.round(r.top), Math.round(r.bottom)] }; })()"""


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
    assert s["title"] == "Show the list: Your move", s
    assert browser.evaluate(BTN + ".getAttribute('aria-controls') === document.querySelector('#chat-strip-wait .wait').id")


@pytest.mark.parametrize("size", SIZES)
def test_a_click_opens_the_list_and_a_second_closes_it_and_a_read_of_the_strip_leaves_it(served, browser, monkeypatch, size):
    open_pin(browser, served, monkeypatch, size)
    click(browser)
    s = state(browser)
    assert s["expanded"] == "true" and s["listShown"] and s["rows"] == 3 and s["title"] == "Hide the list: Your move", s
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
def test_open_it_is_never_taller_than_40vh_the_list_scrolls_inside_and_the_titles_are_links(served, browser, monkeypatch, size):
    open_pin(browser, served, monkeypatch, size, waiting=moves(30, long=True))
    click(browser)
    s = state(browser)
    assert s["pinH"] <= 0.4 * s["vh"] + 0.5, s
    assert s["listScroll"][0] > s["listScroll"][1], f"thirty long moves do not fit: the list scrolls inside the box: {s}"
    assert s["listOverflow"] == ["auto", "hidden"], s                   # up and down only
    assert browser.evaluate("document.querySelectorAll('#chat-strip-wait .answer').length") == 0
    assert wait_for(browser, "(" + LINK_AT.replace("__INDEX__", "0") + ").seen", 3.0), browser.evaluate(LINK_AT.replace("__INDEX__", "0"))
    got = browser.evaluate(LINK_AT.replace("__INDEX__", "0"))
    assert got["id"] == "demo#1" and got["text"].startswith("Move 1 an item subject") and got["href"] == "https://example.com/moves/1", got
    assert got["target"] == "_blank" and got["rel"] == "noopener noreferrer", got
    assert got["seen"] and not got["covered"], got
    # the list scrolls: the last move is reachable, the box does not grow and the thread's own scroll does not move
    before = browser.evaluate("document.querySelector('#chat-pane').scrollTop")
    # the list reaches its end and the box does not grow. A row of a long word and a long address may be taller than the box on a phone (its title is the whole link), so the
    # link is brought into view the way a person would (scrollIntoView, nearest), polled, and then measured: what shows of it is inside the box and nothing covers it.
    END = """(() => { const w = document.querySelector('#chat-strip-wait .wait'); w.style.scrollBehavior = 'auto'; w.scrollTop = w.scrollHeight;
      return { top: Math.round(w.scrollTop), max: Math.round(w.scrollHeight - w.clientHeight), h: document.querySelector('#chat-strip-wait').getBoundingClientRect().height }; })()"""
    end = browser.evaluate(END)
    assert end["top"] == end["max"] > 0 and end["h"] <= 0.4 * s["vh"] + 0.5, end
    reach = LINK_AT.replace("__INDEX__", "29")
    assert wait_for(browser, "(" + reach + ").seen", 3.0), browser.evaluate(reach)       # polled: the scroll may take a frame or two to land
    last = browser.evaluate(reach)
    assert last["id"] == "demo#30" and last["href"] == "https://example.com/moves/30", last
    assert last["seen"] and not last["covered"] and last["h"] <= 0.4 * s["vh"] + 0.5, last
    assert browser.evaluate("document.querySelector('#chat-pane').scrollTop") == before


ROWS = """(() => [...document.querySelectorAll('#chat-strip-wait .wait-row')].map((row) => { const id = row.querySelector('.wait-id'), a = row.querySelector('a'), t = row.querySelector('.wait-title');
  return { id: id ? id.textContent : null, idText: id ? id.firstChild.nodeType === 3 : null, link: a ? a.textContent : null, href: a ? a.getAttribute('href') : null,
           plain: t ? t.textContent : null, anchors: row.querySelectorAll('a').length, answers: row.querySelectorAll('.answer').length, text: row.querySelector('.wait-subj').textContent }; }))()"""


@pytest.mark.parametrize("size", SIZES)
def test_each_row_shows_its_id_and_the_title_is_the_link_and_a_row_missing_a_part_shows_the_rest(served, browser, monkeypatch, size):
    waiting = [{"id": "demo#1", "subject": "With an address", "url": "https://example.com/moves/1"},
               {"id": "demo#2", "subject": "No address", "url": ""},
               {"id": "", "subject": "No id", "url": "https://example.com/moves/3"},
               {"id": "demo#4", "subject": "", "url": "https://example.com/moves/4"}]
    open_pin(browser, served, monkeypatch, size, waiting=waiting)
    click(browser)
    rows = browser.evaluate(ROWS)
    assert rows == [
        {"id": "demo#1", "idText": True, "link": "With an address", "href": "https://example.com/moves/1", "plain": None, "anchors": 1, "answers": 0, "text": "demo#1With an address"},
        {"id": "demo#2", "idText": True, "link": None, "href": None, "plain": "No address", "anchors": 0, "answers": 0, "text": "demo#2No address"},
        {"id": None, "idText": None, "link": "No id", "href": "https://example.com/moves/3", "plain": None, "anchors": 1, "answers": 0, "text": "No id"},
        {"id": None, "idText": None, "link": "demo#4", "href": "https://example.com/moves/4", "plain": None, "anchors": 1, "answers": 0, "text": "demo#4"},
    ], rows
    # a new row carries the "new" tag after its link; the link and the id are still there
    browser.evaluate("window.__chat = Object.assign({}, window.__chat, { waiting: window.__chat.waiting.concat([{ id: 'demo#9', subject: 'A late move', url: 'https://example.com/moves/5' }]) }); loadChatMarks(); ''")
    assert wait_for(browser, f"{PIN}.querySelectorAll('.wait-row').length === 5", 10.0)
    last = browser.evaluate("(() => { const r = [...document.querySelectorAll('#chat-strip-wait .wait-row')].pop(); return [...r.querySelector('.wait-subj').children].map((n) => n.className + ':' + n.textContent); })()")
    assert last == ["wait-id:demo#9", "wait-link:A late move", "new:new"], last


@pytest.mark.parametrize("size", SIZES)
def test_the_title_link_is_in_the_tab_order_the_id_is_selectable_text_and_the_ring_rule_is_there(served, browser, monkeypatch, size):
    open_pin(browser, served, monkeypatch, size)
    click(browser)
    s = browser.evaluate("""(() => { const a = document.querySelector('#chat-strip-wait .wait-link'), id = document.querySelector('#chat-strip-wait .wait-id'); a.focus();
      const sel = window.getSelection(); sel.removeAllRanges(); const range = document.createRange(); range.selectNodeContents(id); sel.addRange(range);
      return { tab: a.tabIndex, focused: document.activeElement === a, display: getComputedStyle(a).display, pe: getComputedStyle(a).pointerEvents, idUserSelect: getComputedStyle(id).userSelect,
               selected: sel.toString(), idInLink: a.contains(id), links: document.querySelectorAll('#chat-strip-wait a').length }; })()""")
    assert s["tab"] >= 0 and s["focused"] and s["pe"] != "none" and s["idUserSelect"] != "none", s
    assert s["selected"] == "demo#1" and not s["idInLink"] and s["links"] == 3, s       # the id can be selected and copied; one link per row


@pytest.mark.parametrize("width", [390, 360, 320])
def test_on_a_touch_screen_every_row_and_its_title_link_give_a_44px_target(served, browser, monkeypatch, width):
    open_pin(browser, served, monkeypatch, (width, 844), waiting=moves(3))
    browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 844, "deviceScaleFactor": 1, "mobile": True})
    assert wait_for(browser, f"document.documentElement.clientWidth === {width}", 10.0)
    browser.touch()
    assert wait_for(browser, "matchMedia('(pointer: coarse)').matches", 10.0)
    click(browser)
    browser.settle(PIN)
    # the title is inline text (it wraps), so the row has its own 44 px and the link's padding gives the link's box as much (what a finger hits: test_chat_onit_ui.py)
    got = browser.evaluate("""(() => [...document.querySelectorAll('#chat-strip-wait .wait-row')].map((row) => { const a = row.querySelector('a'), r = row.getBoundingClientRect(), q = a.getBoundingClientRect();
      return { row: Math.round(r.height * 10) / 10, link: Math.round(q.height * 10) / 10 }; }))()""")
    assert len(got) == 3 and all(g["row"] >= 44 and g["link"] >= 44 for g in got), got


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
  const outRow = [];
  for (const row of p.querySelectorAll('.wait-row')) { const rr = row.getBoundingClientRect(); for (const n of row.querySelectorAll('.wait-id, .wait-link, .wait-title, .new')) { const r = n.getBoundingClientRect(); if (r.right > rr.right + 0.5 || r.left < rr.left - 0.5) outRow.push(n.className + ' ' + Math.round(r.left) + '-' + Math.round(r.right) + ' in ' + Math.round(rr.left) + '-' + Math.round(rr.right)); } }
  for (const n of p.querySelectorAll('*')) { if (!n.getClientRects().length) continue; const r = n.getBoundingClientRect(); if (r.right > document.documentElement.clientWidth + 0.5 || r.left < -0.5) over.push(n.className + ' ' + Math.round(r.left) + '-' + Math.round(r.right)); }
  return { doc: [root.scrollWidth, root.clientWidth], body: [document.body.scrollWidth, document.body.clientWidth], pane: [pane.scrollWidth, pane.clientWidth],
           pin: [p.scrollWidth, p.clientWidth], list: [w.scrollWidth, w.clientWidth], btn: [b.scrollWidth, b.clientWidth], listShown: w.getClientRects().length > 0, over, outRow, ids: p.querySelectorAll('.wait-id').length, vw: document.documentElement.clientWidth }; })()"""


@pytest.mark.parametrize("opened", [False, True], ids=["closed", "open"])
@pytest.mark.parametrize("drawer", [False, True], ids=["drawer-shut", "drawer-open"])
@pytest.mark.parametrize("width", WIDTHS)
def test_no_sideways_scroll_with_the_line_closed_and_open_and_long_item_text(served, browser, monkeypatch, width, drawer, opened):
    waiting = moves(5, long=True)
    waiting[0]["id"] = "item#" + "1" * 75            # stackshot's longest shown id (80 characters) in front of a 300-character word
    open_pin(browser, served, monkeypatch, (width, 800 if width > 700 else 844), waiting=waiting)
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
    assert p["vw"] == width and p["listShown"] is opened and p["ids"] == 5, (where, p)
    assert p["doc"][0] <= p["doc"][1] and p["body"][0] <= p["body"][1] and p["pane"][0] <= p["pane"][1], f"{where}: the page or the pane scrolls sideways: {p}"
    assert p["pin"][0] <= p["pin"][1] and p["list"][0] <= p["list"][1] and p["btn"][0] <= p["btn"][1], f"{where}: the line or its list scrolls sideways: {p}"
    assert p["over"] == [] and p["outRow"] == [], f"{where}: something of the line ends outside the window or its row: {p}"
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


# ── the open list: one heading (the line), rows that hang from their dot, a clean cover ──────────────────────────────────────────────────────────────────────────────────────────
# A long real-looking Korean title (escapes only: no Hangul in this file) and a long address, a 300-character word, a short title: the dot sits on the first line of the title,
# never alone, and a wrapped line starts at the content's left edge (under the id, past the dot), never under the dot.
KO_TITLE = ("[hp] \ud50c\ub8e8\ub9ac\uc6c0 \ub0c9\uc7a5\uace0 LG \ucee8\ubc84\ud130\ube14 1\ub3c4\uc5b4 3\ub300 \uc8fc\ubb38\ud558\uace0 \uc785\uc8fc \uc804\uc5d0 \uc124\uce58\ud558\uae30 "
            "\ud50c\ub8e8\ub9ac\uc6c0 \ub0c9\uc7a5\uace0 LG \ucee8\ubc84\ud130\ube14 1\ub3c4\uc5b4 3\ub300 \uc8fc\ubb38\ud558\uace0 \uc785\uc8fc \uc804\uc5d0 \uc124\uce58\ud558\uae30 ") + URL

HANG = """(() => [...document.querySelectorAll('#chat-strip-wait .wait-row')].map((row) => {
  const cs = getComputedStyle(row), before = getComputedStyle(row, '::before'), r = row.getBoundingClientRect(), subj = row.querySelector('.wait-subj'), sr = subj.getBoundingClientRect(),
    link = row.querySelector('.wait-link') || row.querySelector('.wait-title'), text = [row.querySelector('.wait-id'), link].filter(Boolean),
    first = text[0].getClientRects()[0], dotTop = r.top + parseFloat(cs.paddingTop) + parseFloat(cs.borderTopWidth), dotH = parseFloat(before.height), rects = [...link.getClientRects()];
  return { dotW: before.width, dotH, dotMid: Math.round((dotTop + dotH / 2) * 10) / 10, firstTop: Math.round(first.top * 10) / 10, firstBottom: Math.round(first.bottom * 10) / 10,
           contentLeft: Math.round(sr.left * 10) / 10, rowLeft: r.left, lines: rects.length, lefts: rects.map((q) => Math.round(q.left * 10) / 10), subjH: sr.height, over: sr.right > r.right + 0.5 }; }))()"""


def hang_rows() -> list[dict]:
    return [{"id": "demo#1", "subject": WORD, "url": "https://example.com/moves/1"},
            {"id": "demo#2", "subject": KO_TITLE, "url": "https://example.com/moves/2"},
            {"id": "demo#3", "subject": "A short move", "url": "https://example.com/moves/3"},
            {"id": "", "subject": KO_TITLE, "url": ""}]


@pytest.mark.parametrize("width", WIDTHS)
def test_the_dot_sits_on_the_first_line_of_the_title_and_wrapped_lines_start_under_the_id_not_the_dot(served, browser, monkeypatch, width):
    open_pin(browser, served, monkeypatch, (width, 800 if width > 700 else 844), waiting=hang_rows())
    if width < 700:
        browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 844, "deviceScaleFactor": 1, "mobile": True})
        assert wait_for(browser, f"document.documentElement.clientWidth === {width}", 10.0)
    click(browser)
    browser.settle(PIN)
    rows = browser.evaluate(HANG)
    assert len(rows) == 4
    for i, g in enumerate(rows):
        where = f"{width} px, row {i}: {g}"
        assert g["dotW"] == "8px" and g["dotH"] == 20, where
        # the dot's middle is inside the first line of the row's text (the id, else the title): never a dot on a line of its own
        assert g["firstTop"] - 2 <= g["dotMid"] <= g["firstBottom"] + 2, where
        # the content starts to the right of the dot (an 8 px dot and an 8 px gap), and nothing of it leaves the row
        assert g["contentLeft"] >= g["rowLeft"] + 16 - 0.5 and not g["over"], where
        # every wrapped line of the title starts at the content's left edge (under the id), the first one at or after it (it follows the id)
        assert g["lefts"][0] >= g["contentLeft"] - 0.5 and all(abs(x - g["contentLeft"]) <= 1 for x in g["lefts"][1:]), where
    assert rows[0]["lines"] > 1 and rows[1]["lines"] > 1 and rows[3]["lines"] > 1, ("the long titles wrap, so the check above has lines to compare", rows)
    assert rows[2]["lines"] == 1 and rows[2]["subjH"] <= 20.5, rows[2]


@pytest.mark.parametrize("size", SIZES)
def test_the_open_list_has_no_heading_row_and_is_named_by_the_line(served, browser, monkeypatch, size):
    open_pin(browser, served, monkeypatch, size)
    click(browser)
    got = browser.evaluate("""(() => { const w = document.querySelector('#chat-strip-wait .wait'), kids = [...w.children].map((n) => n.tagName + '.' + n.className);
      return { kids, headings: w.querySelectorAll('h1, h2, h3, h4, h5, h6, .sec-head').length, text: w.textContent, label: w.getAttribute('aria-label'),
               line: document.querySelector('#chat-strip-wait .wait-line').textContent, note: !!w.querySelector('.wait-cap') }; })()""")
    assert got["kids"][0] == "UL.wait-list" and got["headings"] == 0 and "straight from the board" not in got["text"], got
    assert got["label"] == got["line"] == LINE and got["note"], got           # one heading only: the pinned line; the footnote stays


@pytest.mark.parametrize("width", WIDTHS)
def test_the_open_box_covers_the_thread_cleanly_and_the_last_row_has_room_under_it(served, browser, monkeypatch, width):
    open_pin(browser, served, monkeypatch, (width, 800 if width > 700 else 844), waiting=moves(30, long=True))
    if width < 700:
        browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 844, "deviceScaleFactor": 1, "mobile": True})
        assert wait_for(browser, f"document.documentElement.clientWidth === {width}", 10.0)
    click(browser)
    browser.settle(PIN)
    box = browser.evaluate("""(() => { const p = document.querySelector('#chat-strip-wait'), cs = getComputedStyle(p), w = p.querySelector('.wait'), ws = getComputedStyle(w);
      const alpha = (c) => { const a = c.slice(c.indexOf('(') + 1, c.lastIndexOf(')')).split(',').map((x) => parseFloat(x)); return a.length > 3 ? a[3] : 1; };
      return { alpha: alpha(cs.backgroundColor), border: cs.borderBottomWidth + ' ' + cs.borderBottomStyle, shadow: cs.boxShadow, pos: cs.position, padBottom: ws.paddingBottom }; })()""")
    assert box["alpha"] == 1 and box["border"] == "1px solid" and box["shadow"] != "none" and box["pos"] == "sticky" and box["padBottom"] == "12px", box
    # at the end of the list the last row is not clipped by the box's edge: 12 px of padding follow it (polled: the scroll lands a frame later)
    END = """(() => { const w = document.querySelector('#chat-strip-wait .wait'); w.style.scrollBehavior = 'auto'; w.scrollTop = w.scrollHeight; const rows = w.querySelectorAll('.wait-row');
      return Math.round(w.getBoundingClientRect().bottom - rows[rows.length - 1].getBoundingClientRect().bottom); })()"""
    assert wait_for(browser, f"{END} >= 12", 3.0), browser.evaluate(END)


# ── the list scrolls and more is below: a cue at its bottom edge; a wrapped "new" tag starts at the content's left edge ──────────────────────────────────────────────────────────
# The cue is background layers on the list (style.css), so it is read as what it paints: a pixel of a screenshot in the list's left gutter (inside the padding, where no row text,
# hairline or dot is) 4 px above its bottom edge, against a pixel of the same gutter 4 px under its top edge (the band is the last 24 px only). A screenshot of the page, 4 x 4 px at
# scale 1, is a PNG of eight-bit RGB or RGBA: its first pixel is the first three bytes after the filter byte of row 0, whatever the filter is (nothing is to its left or above it).
BAND = """(() => { const w = document.querySelector('#chat-strip-wait .wait'), r = w.getBoundingClientRect();
  return { x: Math.round(r.left) + 2, bottom: Math.floor(r.bottom) - 4, top: Math.ceil(r.top) + 4, sx: window.scrollX, sy: window.scrollY,
           rest: Math.round(w.scrollHeight - w.clientHeight - w.scrollTop), room: w.scrollHeight - w.clientHeight, shown: w.getClientRects().length > 0 }; })()"""
TO_END = "(() => { const w = document.querySelector('#chat-strip-wait .wait'); w.style.scrollBehavior = 'auto'; w.scrollTop = w.scrollHeight; return Math.round(w.scrollTop); })()"
TO_TOP = "(() => { const w = document.querySelector('#chat-strip-wait .wait'); w.style.scrollBehavior = 'auto'; w.scrollTop = 0; return Math.round(w.scrollTop); })()"


def pixel(browser, x: int, y: int, sx: float = 0, sy: float = 0) -> tuple[int, int, int]:
    got = browser.send("Page.captureScreenshot", {"format": "png", "clip": {"x": x + sx, "y": y + sy, "width": 4, "height": 4, "scale": 1}})
    png, pos, idat, kind, depth = base64.b64decode(got["data"]), 8, b"", None, None
    while pos < len(png):
        n, name = int.from_bytes(png[pos:pos + 4], "big"), png[pos + 4:pos + 8]
        if name == b"IHDR":
            depth, kind = png[pos + 16], png[pos + 17]
        elif name == b"IDAT":
            idat += png[pos + 8:pos + 8 + n]
        pos += 12 + n
    assert depth == 8 and kind in (2, 6), (depth, kind)
    raw = zlib.decompress(idat)
    return raw[1], raw[2], raw[3]


def band(browser) -> int:
    """How far the pixel 4 px above the list's bottom edge is from the pixel 4 px under its top edge (the sum of the channels' differences): 0 with no band."""
    b = browser.evaluate(BAND)
    low, high = pixel(browser, b["x"], b["bottom"], b["sx"], b["sy"]), pixel(browser, b["x"], b["top"], b["sx"], b["sy"])
    return sum(abs(p - q) for p, q in zip(low, high))


def poll(read, ok, timeout: float = 5.0):
    """The value `read()` gives once `ok(value)` holds, else the last one (the caller asserts): a wait on what the page does, never a fixed sleep."""
    end, v = time.time() + timeout, read()
    while not ok(v) and time.time() < end:
        time.sleep(0.1)
        v = read()
    return v


def phone(browser, width: int) -> None:
    browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 844, "deviceScaleFactor": 1, "mobile": True})
    assert wait_for(browser, f"document.documentElement.clientWidth === {width}", 10.0)


@pytest.mark.parametrize("width", [390, 360])
def test_a_list_that_scrolls_shows_a_band_at_its_bottom_edge_until_its_end_is_in_view(served, browser, monkeypatch, width):
    open_pin(browser, served, monkeypatch, (width, 844), waiting=moves(8, long=True))
    phone(browser, width)
    click(browser)
    browser.settle(PIN)
    assert wait_for(browser, f"{PIN}.querySelectorAll('.wait-row').length === 8", 10.0)
    first = poll(lambda: browser.evaluate(BAND), lambda b: b["shown"] and b["room"] > 48)
    assert first["shown"] and first["room"] > 48, ("the eight long moves overflow the 40vh box, so there is more below", first)
    # first open: more is below, and the band says so (the scroll position is read, not assumed: what counts is what is left below)
    at_first = poll(lambda: band(browser), lambda v: v >= 24)
    assert browser.evaluate(BAND)["rest"] > 29 and at_first >= 24, ("a list with more below shows the band", at_first, browser.evaluate(BAND))
    # scrolled to its end: nothing is below and nothing of the band is left
    browser.evaluate(TO_END)
    end = poll(lambda: browser.evaluate(BAND), lambda b: b["rest"] <= 1)
    assert end["rest"] <= 1, end
    gone = poll(lambda: band(browser), lambda v: v <= 6)
    assert gone <= 6, ("at the end of the list the band is gone", gone, browser.evaluate(BAND))
    # the footnote stays, and at the end nothing covers the last row's title link (the band is a background, painted under the rows)
    assert browser.evaluate(PIN + ".querySelectorAll('#chat-strip-wait-panel .wait-cap').length") == 1
    last = poll(lambda: browser.evaluate(LINK_AT.replace("__INDEX__", "7")), lambda g: g["seen"])
    assert last["seen"] and last["covered"] is False and last["id"] == "demo#8", last
    assert browser.evaluate("getComputedStyle(document.querySelector('#chat-strip-wait .wait'), '::after').content") in ("none", "normal")
    # and back up: the band returns with more below
    browser.evaluate(TO_TOP)
    back = poll(lambda: band(browser), lambda v: v >= 24)
    assert back >= 24, back
    # no sideways scroll with the band showing
    p = browser.evaluate(PIN_WIDTHS)
    assert p["vw"] == width and p["listShown"] is True, p
    assert p["doc"][0] <= p["doc"][1] and p["body"][0] <= p["body"][1] and p["pane"][0] <= p["pane"][1], p
    assert p["pin"][0] <= p["pin"][1] and p["list"][0] <= p["list"][1] and p["btn"][0] <= p["btn"][1], p
    assert p["over"] == [] and p["outRow"] == [], p
    check(browser.evaluate(MEASURE), f"{width} px, the band showing")


# A row that is "new" (a move that came after the page's first answer) gets the tag. The title's text is swapped for a run of one letter, longer by one letter each time, until the
# tag no longer fits after it and wraps onto a line of its own (a tag is as wide as 'new' plus 16 px of padding, much more than one letter, so some length leaves it alone on a
# line); then the tag's left edge is read against the id's (the first thing of the row's content) and the content's.
WRAP = """(() => { const tag = document.querySelector('#chat-strip-wait .wait-row .new'), row = tag.closest('.wait-row'), link = row.querySelector('.wait-link'),
  id = row.querySelector('.wait-id'), subj = row.querySelector('.wait-subj'), left = (n) => n.getBoundingClientRect().left, out = { same: null, wrapped: null, rows: 0 };
  const last = () => { const l = [...link.getClientRects()]; return l[l.length - 1]; };
  link.textContent = 'm';
  { const t = tag.getBoundingClientRect(), l = last(); out.same = { gap: t.left - l.right, onLine: !(t.top > l.bottom - 1) }; }
  for (let n = 1; n <= 90; n++) { link.textContent = 'm'.repeat(n); const t = tag.getBoundingClientRect(), l = last();
    if (t.top > l.bottom - 1) { out.wrapped = { n, tagLeft: t.left, idLeft: left(id), contentLeft: left(subj), lines: link.getClientRects().length }; break; } }
  out.rows = document.querySelectorAll('#chat-strip-wait .wait-row').length; return out; })()"""


@pytest.mark.parametrize("width", [390, 360, 320])
def test_a_new_tag_that_wraps_starts_where_the_id_starts_and_one_after_the_title_keeps_its_gap(served, browser, monkeypatch, width):
    open_pin(browser, served, monkeypatch, (width, 844))
    phone(browser, width)
    click(browser)
    browser.settle(PIN)
    browser.evaluate("window.__chat = Object.assign({}, window.__chat, { waiting: window.__chat.waiting.concat([{ id: 'demo#9', subject: 'Late', url: 'https://example.com/moves/9' }]) }); loadChatMarks(); ''")
    assert wait_for(browser, f"{PIN}.querySelectorAll('.wait-row .new').length === 1", 10.0)
    got = browser.evaluate(WRAP)
    where = f"{width} px: {got}"
    assert got["rows"] == 4, where
    # on the same line the tag keeps the 8 px of the text before it
    assert got["same"]["onLine"] and 7 <= got["same"]["gap"] <= 9, where
    # wrapped, it starts at the content's left edge: the id's left, which is where every wrapped title line starts
    w = got["wrapped"]
    assert w is not None, ("some length of the title leaves the tag alone on a line", where)
    assert abs(w["tagLeft"] - w["idLeft"]) <= 0.5 and abs(w["idLeft"] - w["contentLeft"]) <= 0.5, where
    p = browser.evaluate(PIN_WIDTHS)
    assert p["vw"] == width and p["doc"][0] <= p["doc"][1] and p["pane"][0] <= p["pane"][1] and p["list"][0] <= p["list"][1] and p["over"] == [] and p["outRow"] == [], where
    check(browser.evaluate(MEASURE), where)


# ── the group's name is the one stackshot serves ──────────────────────────────
# api/chat carries `group: {en, ko}` (stackshot's own name for the group). The pinned line, its titles, the panel's label and the drawer chip use it in place of sala's own
# words; a Korean page uses the served ko, or sala's own Korean when that equals the served en (no Korean catalog); a bad group is no group. All polled, no fixed sleeps.
RENAMED = "Decide demo"
KO_LABEL = "".join(chr(c) for c in (0xACB0, 0xC815, 0x20, 0xB370, 0xBAA8))
OWN_KO = "".join(chr(c) for c in (0xB0B4, 0x20, 0xCC28, 0xB840))
CHIP = "document.querySelector('#side-chat .wchip')"
TIP = "document.querySelector('#side-chat').title"
TIP_EN = "Open the chat session, with the list: "


def line_is(text: str) -> str:
    return f"{BTN}.textContent.trim() === {json.dumps(text)}"


def set_group(browser, group) -> None:
    browser.evaluate("window.__chat = Object.assign({}, window.__chat, { group: " + json.dumps(group) + " }); loadChatMarks(); ''")


def open_group(browser, served, monkeypatch, size, group) -> None:
    open_page(browser, served, monkeypatch, size, api_chat(waiting=moves(), group=group))
    assert wait_for(browser, f"!{PIN}.hidden", 15.0)


@pytest.mark.parametrize("size", SIZES)
def test_a_renamed_group_is_the_name_of_the_closed_bar_the_titles_the_label_and_the_chip(served, browser, monkeypatch, size):
    open_group(browser, served, monkeypatch, size, {"en": RENAMED, "ko": KO_LABEL})
    assert wait_for(browser, line_is(RENAMED + " · 3"), 10.0), state(browser)
    s = state(browser)
    assert s["title"] == "Show the list: " + RENAMED and s["expanded"] == "false", s
    assert wait_for(browser, f"{CHIP}.title === {json.dumps('3 items in ' + RENAMED)}", 10.0), browser.evaluate(CHIP + ".title")
    assert browser.evaluate(TIP) == TIP_EN + RENAMED
    click(browser)
    assert wait_for(browser, f"{BTN}.title === {json.dumps('Hide the list: ' + RENAMED)}", 5.0), state(browser)
    assert browser.evaluate("document.querySelector('#chat-strip-wait .wait').getAttribute('aria-label')") == RENAMED + " · 3"
    click(browser)
    assert wait_for(browser, f"{BTN}.getAttribute('aria-expanded') === 'false'", 5.0)
    assert "Your move" not in browser.evaluate("document.querySelector('#chat-strip-wait').textContent + ' ' + " + BTN + ".title + ' ' + " + CHIP + ".title + ' ' + " + TIP)
    m = browser.evaluate(MEASURE)
    assert m["waiting"] == 3, m
    check(m, f"a renamed group at {size[0]} px")


def test_a_korean_page_shows_the_served_korean_label_or_sala_s_own_when_it_equals_the_english(served, browser, monkeypatch):
    open_group(browser, served, monkeypatch, DESKTOP, {"en": RENAMED, "ko": KO_LABEL})
    assert wait_for(browser, line_is(RENAMED + " · 3"), 10.0)
    browser.evaluate("SalaI18n.setLang('ko'); ''")
    assert wait_for(browser, line_is(KO_LABEL + " · 3"), 10.0), state(browser)          # repainted from what the strip holds, no new read
    assert wait_for(browser, f"{BTN}.title.startsWith({json.dumps(KO_LABEL)}) && {CHIP}.title.startsWith({json.dumps(KO_LABEL)})", 5.0)
    assert wait_for(browser, f"{TIP}.includes({json.dumps(KO_LABEL)}) && !{TIP}.includes('{{group}}')", 5.0), browser.evaluate(TIP)
    set_group(browser, {"en": RENAMED, "ko": RENAMED})                                      # stackshot has no Korean catalog: ko equals en
    assert wait_for(browser, line_is(OWN_KO + " · 3"), 10.0), state(browser)
    assert wait_for(browser, f"{TIP}.includes({json.dumps(OWN_KO)})", 5.0), browser.evaluate(TIP)
    browser.evaluate("SalaI18n.setLang('en'); ''")
    assert wait_for(browser, line_is(RENAMED + " · 3"), 10.0), state(browser)
    assert wait_for(browser, f"{TIP} === {json.dumps(TIP_EN + RENAMED)}", 5.0), browser.evaluate(TIP)


def test_a_group_that_changes_on_a_later_read_repaints_and_a_bad_one_is_no_group(served, browser, monkeypatch):
    open_group(browser, served, monkeypatch, DESKTOP, None)
    assert wait_for(browser, line_is(LINE), 10.0), state(browser)                           # no group: sala's own words
    assert wait_for(browser, f"{TIP} === {json.dumps(TIP_EN + 'Your move')}", 5.0), browser.evaluate(TIP)
    set_group(browser, {"en": RENAMED, "ko": KO_LABEL})
    assert wait_for(browser, line_is(RENAMED + " · 3"), 10.0), state(browser)
    set_group(browser, {"en": "Decide again", "ko": KO_LABEL})
    assert wait_for(browser, line_is("Decide again · 3"), 10.0), state(browser)
    for bad in ({"en": "<b>x</b>", "ko": KO_LABEL}, {"en": "x" * 41, "ko": KO_LABEL}, {"en": RENAMED}, "text", None):
        set_group(browser, bad)
        assert wait_for(browser, line_is(LINE), 10.0), (bad, state(browser))
        assert browser.evaluate("document.querySelectorAll('#chat-strip-wait b').length") == 0
