"""The chat strip's second tab, "On it", in a headless Chromium (the lines as the app answers them and the row helpers are test_chat_onit.py; the first list's rows
and the bar's keyboard on their own are also in test_chat_wait_pin_ui.py).

The rule: the pinned part of the strip is a bar of two tabs, the owner's group and "On it", with a chevron, and one list is open at a time, inside one 40vh box. The
second list is what the chat session has promised to report back and has not yet: its own `sala motion` lines (`motion` of api/chat). Held here at 1280 x 800 and
390 x 844 (the width rule also at 360 and 320), with api/chat replaced in the page (but for one case the app answers itself from the session's own file):
  - closed: both counts in a bar one line high, no list, an amber dot while a line is late, said in the tab's name too;
  - a tab opens its list and closes it again, the other tab switches, the chevron closes the open list and opens the one last open, a read keeps it open;
  - a tab list for the keyboard and a screen reader: role tablist, tab and tabpanel, aria-selected on the open one, one tab in the Tab order, the arrows, Home and
    End move between the tabs and Enter or Space open the one reached;
  - a row: the topic as plain text (no id, no link, no name) and under it since when, with the days of a late one (amber past two days, red past five), no "new"
    tag; the late count over the list; with nothing in progress the tab is a quiet 0 and the list says so; with both lists empty nothing is drawn;
  - a line the session takes off leaves the list, and the count and the dot follow; nothing of the lines is drawn anywhere else in the strip;
  - the list's help line is behind a (?) in the bar, there only while that list is open: a button with an accessible name and aria-expanded, a press shows the line in a
    small box under the bar and a second press, a press anywhere else, Escape, and the list closing or the other tab opening shut it; a read leaves it as it is; it is
    never drawn on its own, and the box stays inside the window, wraps and adds no sideways scroll (at 1280, 390, 360 and 320 px, in English and in Korean);
  - a Korean page names the tab and words the rows, the empty line, the (?) and its help line in Korean;
  - a session that is not the chat session has no tabs, looks the same whether there are lines or not, and the same again with every style rule of the strip's
    pinned box taken out of the page, with a mouse and on a touch screen;
  - markup in a line is text;
  - NO SIDEWAYS SCROLL, at 1280, 390, 360 and 320 px, closed and on each tab, with long unbroken text in the lines, long ids, subjects and group names; open, the
    box stays within 40vh and the list scrolls inside it; on a touch screen the tabs, the chevron and every row give 44 px;
  - on a touch screen, 390 x 844 and 1280 x 800, a finger anywhere along a title link of the first list has 44 px of that link (read with elementFromPoint), no two
    links' areas overlap, the rest of the row is no link and a one-line row is no taller; with a mouse the link has no padding of its own;
  - under the bar a list scrolled to its end is cut 4 px below the selected tab's underline, never on it.

What a wrong answer costs: a promise nobody sees, a bar that pushes the thread off a phone, a list the keyboard cannot reach, a page that scrolls sideways, a chat
change that leaks into every session's view. Runs in a headless Chromium when one is installed (conftest.py: `served`, `browser`), else is skipped; GitHub CI runs
it. All names are invented; Korean is built from code points."""

from __future__ import annotations

import json
import re
import time

import pytest

from conftest import NAME, transcript_file
from test_board_items_ui import wait_for
from test_chat_session_view_ui import DESKTOP, MEASURE, MEASURE_PARITY, SIZES, URL, WORD, api_chat, check, code_transcript, drawer_open, open_page

DAY = 86400
WIDTHS = [1280, 390, 360, 320]
PIN = "document.querySelector('#chat-strip-wait')"
MOVE_TAB = "document.querySelector('#chat-strip-tab-move')"
ONIT_TAB = "document.querySelector('#chat-strip-tab-onit')"
CHEVRON = "document.querySelector('#chat-strip-wait .wait-chev')"
HELP_BTN = "document.querySelector('#chat-strip-wait .wait-help')"
MOVE_PANEL, ONIT_PANEL = "chat-strip-wait-panel", "chat-strip-onit-panel"
NOTHING = "Nothing in progress right now"
NOTE = "This is what the assistant has said it will report back on in this chat. Once it has, it leaves the list."
HELP_LABEL = "About this list"


def cp(*codes) -> str:
    return "".join(chr(c) for c in codes)


NOTE_KO = cp(0xC774, 0x20, 0xCC44, 0xD305, 0xC5D0, 0xC11C, 0x20, 0xACB0, 0xACFC, 0xB97C, 0x20, 0xC54C, 0xB824, 0x20, 0xB4DC, 0xB9AC, 0xAE30, 0xB85C, 0x20, 0xD55C, 0x20,
             0xC77C, 0xC785, 0xB2C8, 0xB2E4, 0x2E, 0x20, 0xC54C, 0xB824, 0x20, 0xB4DC, 0xB9AC, 0xACE0, 0x20, 0xB098, 0xBA74, 0x20, 0xBAA9, 0xB85D, 0xC5D0, 0xC11C, 0x20,
             0xBE60, 0xC9D1, 0xB2C8, 0xB2E4, 0x2E)


def line(text: str, ago: float = 60) -> dict:
    """One line of `motion`: what was promised, first set `ago` seconds ago."""
    return {"text": text, "at": int(time.time() - ago)}


def promises() -> list[dict]:
    """One late (3 days), one red (a week), one set an hour ago and one just now."""
    return [line("Promise 11", 3 * DAY + 3600), line("Promise 12", 7 * DAY + 3600), line("Promise 13", 3600), line("Promise 14")]


def hostile(n: int = 3) -> list[dict]:
    """Lines no width can hold unwrapped: one very long word, an address, Korean with and without spaces (longer than the server sends, which is stricter)."""
    long_text = "a promise that keeps going and going " * 6 + WORD + " " + URL
    first = [line(long_text, 8 * DAY), line("w" * 400, 3 * DAY + 3600), line(cp(0xD50C, 0xB8E8, 0xB9AC, 0xC6C0) * 60), line(URL.replace(" ", "") * 3), line(WORD)]
    return (first + [line(long_text, 8 * DAY) for _ in range(len(first), n)])[:n]


def waiting(n: int = 2, long: bool = False) -> list[dict]:
    subject = ("an item subject that keeps going " * 6 + WORD + " " + URL) if long else "to answer"
    return [{"id": f"demo#{i}", "subject": f"Move {i} {subject}", "url": f"https://example.com/moves/{i}"} for i in range(1, n + 1)]


def open_strip(browser, served, monkeypatch, size, **over) -> None:
    over.setdefault("waiting", waiting())
    over.setdefault("motion", promises())
    open_page(browser, served, monkeypatch, size, api_chat(**over))
    assert wait_for(browser, "!document.querySelector('#chat-strip').hidden", 15.0)
    if over["waiting"] or over["motion"]:
        assert wait_for(browser, f"!{PIN}.hidden", 15.0)


def change(browser, **over) -> None:
    """api/chat answers differently from now on (a key set to None is left out of it), and the page reads it."""
    browser.evaluate("(() => { const d = Object.assign({}, window.__chat, " + json.dumps(over) + "); for (const k of Object.keys(d)) if (d[k] === null) delete d[k]; "
                     "window.__chat = d; loadChatMarks(); return ''; })()")


def click(browser, node: str) -> None:
    browser.evaluate(node + ".click(); ''")


def phone(browser, width: int) -> None:
    browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 844, "deviceScaleFactor": 1, "mobile": True})
    assert wait_for(browser, f"document.documentElement.clientWidth === {width}", 10.0)


STATE = """(() => { const p = document.querySelector('#chat-strip-wait'), shown = (n) => !!n && n.getClientRects().length > 0, q = (s) => p.querySelector(s);
  const chev = q('.wait-chev'), list = q('[role=tablist]');
  return { pin: shown(p), h: p.getBoundingClientRect().height, bar: shown(q('.wait-bar')), text: p.innerText.trim(),
    tablist: list ? list.getAttribute('aria-label') : null,
    tabs: [...p.querySelectorAll('[role=tab]')].map((t) => ({ id: t.id, text: t.textContent.trim(), selected: t.getAttribute('aria-selected'), index: t.getAttribute('tabindex'),
      controls: t.getAttribute('aria-controls'), label: t.getAttribute('aria-label'), zero: t.classList.contains('zero'), tag: t.tagName, type: t.type })),
    dot: shown(q('.wait-latedot')), chev: chev ? [chev.getAttribute('aria-expanded'), chev.title, chev.getAttribute('aria-controls'), chev.getAttribute('aria-label')] : null,
    panels: [...p.querySelectorAll('.wait')].map((w) => ({ id: w.id, shown: shown(w), role: w.getAttribute('role'), by: w.getAttribute('aria-labelledby'), rows: w.querySelectorAll('.wait-row').length })),
    open: [...p.querySelectorAll('.wait')].filter(shown).map((w) => w.id), focus: document.activeElement ? document.activeElement.id : null }; })()"""


def state(browser) -> dict:
    return browser.evaluate(STATE)


def selected(s: dict) -> list[str]:
    return [t["selected"] for t in s["tabs"]]


# ── the bar ──────────────────────────────────────────────────────────────────
@pytest.mark.parametrize("size", SIZES)
def test_closed_the_bar_shows_both_counts_and_the_late_dot_one_line_high(served, browser, monkeypatch, size):
    open_strip(browser, served, monkeypatch, size)
    s = state(browser)
    assert s["pin"] and s["bar"] and s["open"] == [] and 35.5 <= s["h"] <= 48, s
    assert [t["text"] for t in s["tabs"]] == ["Your move · 2", "On it · 4"] and s["tablist"] == "Chat lists", s
    assert [(t["id"], t["controls"], t["tag"], t["type"]) for t in s["tabs"]] == [("chat-strip-tab-move", MOVE_PANEL, "BUTTON", "button"),
                                                                                ("chat-strip-tab-onit", ONIT_PANEL, "BUTTON", "button")], s
    assert selected(s) == ["false", "false"] and [t["index"] for t in s["tabs"]] == ["0", "-1"] and not [t for t in s["tabs"] if t["zero"]], s
    # two lines are late (3 days and a week)
    assert s["dot"] and [t["label"] for t in s["tabs"]] == [None, "On it · 4, 2 older than 2 days"], s
    assert s["chev"] == ["false", "Show the list: Your move", MOVE_PANEL, "Show the list: Your move"], s
    # nothing late: no dot, and the tab's name is its words alone
    change(browser, motion=[line("one"), line("two", 2 * DAY - 60)])
    assert wait_for(browser, f"{ONIT_TAB}.textContent.trim() === 'On it · 2'", 10.0)
    s = state(browser)
    assert not s["dot"] and s["tabs"][1]["label"] == "On it · 2", s


@pytest.mark.parametrize("size", SIZES)
def test_a_tab_opens_its_list_one_at_a_time_and_the_chevron_closes_it_and_opens_the_last_one(served, browser, monkeypatch, size):
    open_strip(browser, served, monkeypatch, size)
    click(browser, ONIT_TAB)
    s = state(browser)
    assert s["open"] == [ONIT_PANEL] and selected(s) == ["false", "true"] and [t["index"] for t in s["tabs"]] == ["-1", "0"], s
    assert s["chev"][:3] == ["true", "Hide the list: On it", ONIT_PANEL], s
    assert [(w["id"], w["role"], w["by"], w["rows"]) for w in s["panels"]] == [(MOVE_PANEL, "tabpanel", "chat-strip-tab-move", 2),
                                                                             (ONIT_PANEL, "tabpanel", "chat-strip-tab-onit", 4)], s
    click(browser, MOVE_TAB)
    s = state(browser)
    assert s["open"] == [MOVE_PANEL] and selected(s) == ["true", "false"] and s["chev"][:3] == ["true", "Hide the list: Your move", MOVE_PANEL], s
    click(browser, MOVE_TAB)                       # a press on the open one's tab closes it
    s = state(browser)
    assert s["open"] == [] and selected(s) == ["false", "false"] and s["chev"][0] == "false", s
    click(browser, ONIT_TAB)
    click(browser, CHEVRON)
    s = state(browser)
    assert s["open"] == [] and s["chev"][:3] == ["false", "Show the list: On it", ONIT_PANEL] and s["bar"], s
    click(browser, CHEVRON)
    assert state(browser)["open"] == [ONIT_PANEL]
    # a read changes the counts and keeps the open list
    change(browser, motion=promises() + [line("one more")])
    assert wait_for(browser, f"{ONIT_TAB}.textContent.trim() === 'On it · 5'", 10.0)
    s = state(browser)
    assert s["open"] == [ONIT_PANEL] and selected(s) == ["false", "true"] and s["panels"][1]["rows"] == 5, s


def key(browser, name: str, code: str, vk: int, text: str | None = None) -> None:
    down = {"type": "keyDown", "key": name, "code": code, "windowsVirtualKeyCode": vk}
    if text is not None:
        down["text"] = text
    browser.send("Input.dispatchKeyEvent", down)
    browser.send("Input.dispatchKeyEvent", {"type": "keyUp", "key": name, "code": code, "windowsVirtualKeyCode": vk})


def test_the_keyboard_moves_between_the_tabs_and_opens_the_one_reached(served, browser, monkeypatch):
    open_strip(browser, served, monkeypatch, DESKTOP)
    browser.evaluate(MOVE_TAB + ".focus(); ''")
    for name, code, vk, want in (("ArrowRight", "ArrowRight", 39, "onit"), ("ArrowRight", "ArrowRight", 39, "move"), ("ArrowLeft", "ArrowLeft", 37, "onit"),
                                 ("Home", "Home", 36, "move"), ("End", "End", 35, "onit")):
        key(browser, name, code, vk)
        assert wait_for(browser, f"document.activeElement.id === 'chat-strip-tab-{want}'", 5.0), (name, state(browser))
        s = state(browser)
        assert [t["index"] for t in s["tabs"]] == (["0", "-1"] if want == "move" else ["-1", "0"]) and s["open"] == [], (name, s)      # moving opens nothing
    key(browser, "Enter", "Enter", 13, "\r")
    assert wait_for(browser, f"{ONIT_TAB}.getAttribute('aria-selected') === 'true'", 5.0), state(browser)
    assert state(browser)["open"] == [ONIT_PANEL] and state(browser)["focus"] == "chat-strip-tab-onit"
    key(browser, "ArrowLeft", "ArrowLeft", 37)
    assert state(browser)["open"] == [ONIT_PANEL]
    key(browser, " ", "Space", 32, " ")
    assert wait_for(browser, f"{MOVE_TAB}.getAttribute('aria-selected') === 'true'", 5.0), state(browser)
    assert state(browser)["open"] == [MOVE_PANEL]
    # a read leaves the focus and the Tab order where they were
    change(browser, motion=promises()[:2])
    assert wait_for(browser, f"{ONIT_TAB}.textContent.trim() === 'On it · 2'", 10.0)
    s = state(browser)
    assert s["focus"] == "chat-strip-tab-move" and [t["index"] for t in s["tabs"]] == ["0", "-1"], s


# ── the rows ─────────────────────────────────────────────────────────────────
ROWS = """(() => { const probe = (v) => { const i = document.createElement('i'); i.style.color = 'var(' + v + ')'; document.body.append(i); const c = getComputedStyle(i).color; i.remove(); return c; };
  const warn = probe('--warn'), red = probe('--waiting'), tone = (n) => { const c = getComputedStyle(n).color; return c === warn ? 'amber' : c === red ? 'red' : ''; };
  const p = document.querySelector('#chat-strip-onit-panel'), shown = (n) => !!n && n.getClientRects().length > 0, sum = p.querySelector('.wait-sum');
  return { sum: shown(sum) ? sum.textContent : null, empty: shown(p.querySelector('.wait-empty')) ? p.querySelector('.wait-empty').textContent : null,
    list: shown(p.querySelector('.wait-list')), caps: p.querySelectorAll('.wait-cap').length,
    rows: [...p.querySelectorAll('.wait-row')].map((r) => { const a = r.querySelector('a'), id = r.querySelector('.wait-id'), t = r.querySelector('.wait-link, .wait-title');
      return { cls: r.className, id: id ? id.textContent : null, title: t.textContent, href: a ? a.getAttribute('href') : null, target: a ? a.target : null, tags: r.querySelectorAll('.new').length,
        under: r.querySelector('.wait-meta').getBoundingClientRect().top >= r.querySelector('.wait-subj').getBoundingClientRect().bottom - 0.5,
        meta: [...r.querySelectorAll('.wait-meta > span')].map((s) => ({ cls: s.className.trim(), text: s.textContent, tip: s.title, tone: tone(s) })) }; }) }; })()"""


@pytest.mark.parametrize("size", SIZES)
def test_a_row_shows_the_topic_since_when_and_how_late(served, browser, monkeypatch, size):
    open_strip(browser, served, monkeypatch, size)
    click(browser, ONIT_TAB)
    got = browser.evaluate(ROWS)
    assert got["sum"] == "2 older than 2 days" and got["empty"] is None and got["list"] and got["caps"] == 0, got
    rows = got["rows"]
    assert [r["cls"] for r in rows] == ["wait-row back-row late", "wait-row back-row red", "wait-row back-row", "wait-row back-row"], rows
    assert [(r["id"], r["title"], r["href"]) for r in rows] == [(None, f"Promise {n}", None) for n in (11, 12, 13, 14)], rows      # plain text: no id, no link
    assert all(r["under"] and r["tags"] == 0 for r in rows), rows
    late, red, hour, fresh = (r["meta"] for r in rows)
    assert [(m["cls"], m["tone"]) for m in late] == [("late", "amber"), ("late age", "amber")] and late[1]["text"] == "3 days", late
    assert re.fullmatch(r"since [A-Z][a-z]{2} \d\d:\d\d", late[0]["text"]), late
    assert [(m["cls"], m["tone"]) for m in red] == [("red", "red"), ("red age", "red")] and red[1]["text"] == "7 days", red
    assert re.fullmatch(r"since [A-Z][a-z]{2} [A-Z][a-z]{2} \d{1,2}(st|nd|rd|th)", red[0]["text"]), red
    for meta in (hour, fresh):
        assert [(m["cls"], m["tone"]) for m in meta] == [("", "")] and re.fullmatch(r"since ([A-Z][a-z]{2} )?\d\d:\d\d", meta[0]["text"]), meta
    # an item new to the first list since the page's first answer is tagged "new" there; a row of the second list never carries the tag
    change(browser, motion=promises() + [line("one more")], waiting=waiting(3))
    assert wait_for(browser, f"{PIN}.querySelectorAll('#{ONIT_PANEL} .wait-row').length === 5", 10.0)
    assert browser.evaluate(f"[document.querySelectorAll('#{ONIT_PANEL} .new').length, document.querySelectorAll('#{MOVE_PANEL} .new').length]") == [0, 1]
    # the lines are in that one list and nowhere else in the strip
    assert browser.evaluate(f"[document.querySelectorAll('#chat-pane .motion, #chat-pane .mo').length, document.querySelector('#chat-strip').textContent.includes('Promise')]") == [0, False]


@pytest.mark.parametrize("size", SIZES)
def test_a_line_taken_off_leaves_the_list_and_the_count_and_the_dot_follow(served, browser, monkeypatch, size):
    open_strip(browser, served, monkeypatch, size)
    click(browser, ONIT_TAB)
    change(browser, motion=promises()[2:])
    assert wait_for(browser, f"{ONIT_TAB}.textContent.trim() === 'On it · 2'", 10.0)
    s = state(browser)
    assert not s["dot"] and s["tabs"][1]["label"] == "On it · 2" and s["open"] == [ONIT_PANEL], s
    got = browser.evaluate(ROWS)
    assert [r["title"] for r in got["rows"]] == ["Promise 13", "Promise 14"] and got["sum"] is None, got


@pytest.mark.parametrize("size", SIZES)
def test_with_nothing_in_progress_the_tab_is_a_quiet_zero_and_with_both_lists_empty_nothing_is_drawn(served, browser, monkeypatch, size):
    open_strip(browser, served, monkeypatch, size, motion=[])
    s = state(browser)
    assert s["bar"] and [t["text"] for t in s["tabs"]] == ["Your move · 2", "On it · 0"] and [t["zero"] for t in s["tabs"]] == [False, True] and not s["dot"], s
    click(browser, ONIT_TAB)
    got = browser.evaluate(ROWS)
    assert state(browser)["open"] == [ONIT_PANEL] and got["empty"] == NOTHING and got["caps"] == 0 and not got["list"] and got["sum"] is None and got["rows"] == [], got
    # only the second list has rows: the bar stands, the owner's tab is the quiet one
    change(browser, waiting=[], motion=[line("one")])
    assert wait_for(browser, f"{MOVE_TAB}.textContent.trim() === 'Your move · 0' && {ONIT_TAB}.textContent.trim() === 'On it · 1'", 10.0)
    s = state(browser)
    assert s["pin"] and [t["zero"] for t in s["tabs"]] == [True, False] and s["open"] == [ONIT_PANEL] and browser.evaluate(ROWS)["empty"] is None, s
    change(browser, motion=[])
    assert wait_for(browser, f"{PIN}.hidden", 10.0)
    s = state(browser)
    assert not s["pin"] and s["h"] == 0, s


@pytest.mark.parametrize("size", SIZES)
def test_a_korean_page_names_the_tab_and_words_the_rows_the_empty_line_and_the_help_line(served, browser, monkeypatch, size):
    open_strip(browser, served, monkeypatch, size)
    click(browser, ONIT_TAB)
    browser.evaluate("SalaI18n.setLang('ko'); ''")
    tab = cp(0xC9C4, 0xD589, 0x20, 0xC911)
    assert wait_for(browser, f"{ONIT_TAB}.textContent.trim() === {json.dumps(tab + ' · 4')}", 10.0), state(browser)
    s = state(browser)
    assert s["tabs"][0]["text"] == cp(0xB0B4, 0x20, 0xCC28, 0xB840) + " · 2" and s["tablist"] == cp(0xCC44, 0xD305, 0x20, 0xBAA9, 0xB85D) and s["open"] == [ONIT_PANEL], s
    got = browser.evaluate(ROWS)
    assert got["rows"][0]["title"] == "Promise 11" and got["rows"][0]["meta"][0]["text"].endswith(cp(0xBD80, 0xD130)), got
    assert got["caps"] == 0, got
    click(browser, HELP_BTN)
    h = browser.evaluate(HELP)
    assert h["label"] == cp(0xC774, 0x20, 0xBAA9, 0xB85D, 0x20, 0xC124, 0xBA85) and h["text"] == NOTE_KO and h["expanded"] == "true" and h["pop"], h
    change(browser, motion=[])
    nothing = cp(0xC9C0, 0xAE08, 0x20, 0xC9C4, 0xD589, 0x20, 0xC911, 0xC778, 0x20, 0xC77C, 0xC774, 0x20, 0xC5C6, 0xC2B5, 0xB2C8, 0xB2E4)
    assert wait_for(browser, f"document.querySelector('#{ONIT_PANEL} .wait-empty').textContent === {json.dumps(nothing)}", 10.0), browser.evaluate(ROWS)


# ── the (?) and its help line ────────────────────────────────────────────────
HELP = """(() => { const p = document.querySelector('#chat-strip-wait'), b = p.querySelector('.wait-help'), pop = p.querySelector('.wait-pop'), vw = document.documentElement.clientWidth;
  const shown = (n) => !!n && n.getClientRects().length > 0, r = pop.getBoundingClientRect(), bar = p.querySelector('.wait-bar').getBoundingClientRect();
  return { btn: shown(b), expanded: b.getAttribute('aria-expanded'), label: b.getAttribute('aria-label'), controls: b.getAttribute('aria-controls'), type: b.type, tag: b.tagName,
    inTabs: !!b.closest('[role=tablist]'), inBar: !!b.closest('.wait-bar'), pop: shown(pop), popId: pop.id, text: pop.textContent, role: pop.getAttribute('role'),
    box: shown(pop) ? { left: r.left, right: r.right, bottom: r.bottom, w: r.width, vw, vh: innerHeight, below: r.top >= bar.bottom - 0.5, scrollW: pop.scrollWidth, clientW: pop.clientWidth } : null,
    elsewhere: document.body.innerText.includes(__NOTE__), caps: [...p.querySelectorAll('.wait-cap')].map((c) => c.closest('.wait').id) }; })()""".replace("__NOTE__", json.dumps(NOTE))


def helped(browser) -> dict:
    return browser.evaluate(HELP)


def on_second_list(browser) -> None:
    """The second list is the open one (a press on its tab opens it; a press on it while open would close it)."""
    if state(browser)["open"] != [ONIT_PANEL]:
        click(browser, ONIT_TAB)


@pytest.mark.parametrize("size", SIZES)
def test_the_help_line_is_behind_a_question_mark_that_shows_it_on_a_press_and_not_on_its_own(served, browser, monkeypatch, size):
    open_strip(browser, served, monkeypatch, size)
    # closed, or on the first list: no (?), no line, and the line is nowhere on the page
    h = helped(browser)
    assert not h["btn"] and not h["pop"] and not h["elsewhere"] and h["expanded"] == "false", h
    click(browser, MOVE_TAB)
    h = helped(browser)
    assert not h["btn"] and not h["pop"] and not h["elsewhere"] and h["caps"] == [MOVE_PANEL], h              # the first list's own footnote is another line
    # the second list: the (?) is in the bar (not among the tabs), named by its words, shut, and the line is not drawn
    click(browser, ONIT_TAB)
    browser.settle(PIN)
    h = helped(browser)
    assert h["btn"] and (h["tag"], h["type"]) == ("BUTTON", "button") and h["inBar"] and not h["inTabs"], h
    assert h["label"] == HELP_LABEL and h["controls"] == h["popId"] == "chat-strip-onit-help" and h["role"] == "note", h
    assert h["expanded"] == "false" and not h["pop"] and not h["elsewhere"] and h["caps"] == [MOVE_PANEL], h
    # a press shows exactly the line, under the bar; a second press shuts it
    click(browser, HELP_BTN)
    h = helped(browser)
    assert h["expanded"] == "true" and h["pop"] and h["text"] == NOTE and h["box"]["below"], h
    click(browser, HELP_BTN)
    h = helped(browser)
    assert h["expanded"] == "false" and not h["pop"] and not h["elsewhere"], h


@pytest.mark.parametrize("size", SIZES)
def test_the_help_line_shuts_on_a_press_elsewhere_on_escape_and_with_its_list(served, browser, monkeypatch, size):
    open_strip(browser, served, monkeypatch, size)
    click(browser, ONIT_TAB)
    # a press anywhere else, the line itself included
    for away in ("document.querySelector('#chat-strip-onit-panel .wait-row')", "document.querySelector('#chat')", "document.body", "document.querySelector('#chat-pane')",
                 "document.querySelector('#chat-strip-wait .wait-pop')"):
        click(browser, HELP_BTN)
        assert helped(browser)["pop"], away
        click(browser, away)
        h = helped(browser)
        assert not h["pop"] and h["expanded"] == "false", (away, h)
    # Escape shuts it, with the focus on the (?) and Enter to open it; with nothing shown Escape changes nothing
    browser.evaluate(HELP_BTN + ".focus(); ''")
    key(browser, "Enter", "Enter", 13, "\r")
    assert wait_for(browser, "!document.querySelector('#chat-strip-wait .wait-pop').hidden", 5.0), helped(browser)
    key(browser, "Escape", "Escape", 27)
    assert wait_for(browser, "document.querySelector('#chat-strip-wait .wait-pop').hidden", 5.0), helped(browser)
    h = helped(browser)
    assert h["expanded"] == "false" and browser.evaluate("document.activeElement.className") == "wait-help", h
    key(browser, "Escape", "Escape", 27)
    assert state(browser)["open"] == [ONIT_PANEL]
    # a read leaves it shown; it goes with its list (the other tab, the chevron, a press on the open tab) and the (?) goes too
    for leave in (MOVE_TAB, CHEVRON, ONIT_TAB):
        on_second_list(browser)
        click(browser, HELP_BTN)
        change(browser, motion=promises()[:3])
        assert wait_for(browser, f"{ONIT_TAB}.textContent.trim() === 'On it · 3'", 10.0)
        assert helped(browser)["pop"], "a read leaves it shown"
        change(browser, motion=promises())
        assert wait_for(browser, f"{ONIT_TAB}.textContent.trim() === 'On it · 4'", 10.0)
        click(browser, leave)
        h = helped(browser)
        assert not h["pop"] and h["expanded"] == "false" and not h["btn"] and not h["elsewhere"], (leave, h)
    # and it does not come back by itself when the list is opened again
    on_second_list(browser)
    h = helped(browser)
    assert h["btn"] and not h["pop"] and h["expanded"] == "false", h


@pytest.mark.parametrize("width", WIDTHS)
@pytest.mark.parametrize("lang", ["en", "ko"])
def test_the_help_line_stays_inside_the_window_wraps_and_adds_no_sideways_scroll(served, browser, monkeypatch, width, lang):
    group = {"en": "G" * 40, "ko": cp(0xACB0) * 40}
    open_strip(browser, served, monkeypatch, (width, 800 if width > 700 else 844), waiting=waiting(12, long=True), motion=hostile(12), group=group)
    if width < 700:
        phone(browser, width)
    if lang == "ko":
        browser.evaluate("SalaI18n.setLang('ko'); ''")
    click(browser, ONIT_TAB)
    click(browser, HELP_BTN)
    browser.settle(PIN)
    h = helped(browser)
    where = f"{width} px, {lang}: {h}"
    assert h["pop"] and h["text"] == (NOTE if lang == "en" else NOTE_KO), where
    box = h["box"]
    assert box["left"] >= 0 and box["right"] <= box["vw"] + 0.5 and box["bottom"] <= box["vh"] and box["w"] <= 320.5 and box["below"], where
    assert box["scrollW"] <= box["clientW"] + 1, f"the line scrolls sideways: {where}"
    assert box["w"] <= width - 24 + 0.5, where                                                              # never wider than the bar less 12 px each side
    got = browser.evaluate(WIDE)
    assert got["doc"][0] <= got["doc"][1] and got["body"][0] <= got["body"][1] and got["pane"][0] <= got["pane"][1] and got["over"] == [] and got["wide"] == [] and got["outRow"] == [], (where, got)
    check(browser.evaluate(MEASURE), where)


# ── the app's own answer ─────────────────────────────────────────────────────
def read_until(browser, expr: str, timeout: float = 20.0) -> bool:
    """The page reads api/chat again and again until `expr` holds."""
    end = time.time() + timeout
    while time.time() < end:
        browser.evaluate("loadChatMarks(); ''")
        if wait_for(browser, expr, 0.5):
            return True
    return False


@pytest.mark.parametrize("size", SIZES)
def test_the_sessions_own_lines_reach_the_tab_and_a_done_one_leaves(served, browser, monkeypatch, size):
    path = served["settings"].motion_dir / f"{NAME}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    late, fresh = line("research on X", 30 * DAY), line("research on Y")
    path.write_text(json.dumps({"v": 1, "lines": [late, fresh]}))
    open_page(browser, served, monkeypatch, size)
    assert read_until(browser, f"!!{ONIT_TAB} && {ONIT_TAB}.textContent.trim() === 'On it · 2'"), state(browser)
    click(browser, ONIT_TAB)
    assert [r["title"] for r in browser.evaluate(ROWS)["rows"]] == ["research on X", "research on Y"] and state(browser)["dot"]
    path.write_text(json.dumps({"v": 1, "lines": [fresh]}))
    assert read_until(browser, f"{ONIT_TAB}.textContent.trim() === 'On it · 1'"), state(browser)
    assert [r["title"] for r in browser.evaluate(ROWS)["rows"]] == ["research on Y"] and not state(browser)["dot"]


# ── only the chat session ────────────────────────────────────────────────────
# Every element outside the pinned box, as laid out, then again with every style rule that names the box deleted from the page's sheets: in one evaluation, so
# nothing else can move between the two. (A sheet from another origin cannot be read and holds none of the app's rules.)
UNSTYLED = """(() => {
  const read = () => [...document.querySelectorAll('body, body *')].filter((n) => !n.closest('#chat-strip-wait')).map((n) => { const r = n.getBoundingClientRect(), c = getComputedStyle(n);
    return [n.tagName, n.id, n.getAttribute('class'), r.left, r.top, r.width, r.height, c.display, c.position, c.zIndex, c.paddingTop, c.paddingBottom, c.marginTop, c.marginBottom, c.overflowY].join(' '); });
  const before = read(); let gone = 0;
  const strip = (list) => { for (let i = list.cssRules.length - 1; i >= 0; i--) { const r = list.cssRules[i];
    if (r.selectorText !== undefined) { if (r.selectorText.includes('#chat-strip-wait')) { list.deleteRule(i); gone++; } } else if (r.cssRules) strip(r); } };
  for (const sheet of document.styleSheets) { try { sheet.cssRules; } catch (e) { continue; } strip(sheet); }
  const after = read();
  return { gone, nodes: before.length, changed: before.map((x, i) => [x, after[i]]).filter(([a, b]) => a !== b).slice(0, 5) }; })()"""


@pytest.mark.parametrize("finger", [False, True], ids=["mouse", "touch"])
@pytest.mark.parametrize("size", SIZES)
def test_a_second_session_has_no_tabs_and_looks_the_same_with_lines_or_without(served, browser, monkeypatch, size, finger):
    transcript_file(served).write_text(code_transcript())
    seen = []
    for extra in ({"motion": []}, {"motion": promises()}):
        open_page(browser, served, monkeypatch, size, api_chat(session="demo-someone-else", waiting=waiting(), **extra), chat="demo-someone-else")
        assert wait_for(browser, "!document.querySelector('#side-chat').hidden", 8.0)
        if finger:
            browser.touch()
        assert wait_for(browser, f"matchMedia('(pointer: coarse)').matches === {json.dumps(finger)}", 10.0)
        browser.settle("document.querySelector('#chat')")
        strip = browser.evaluate("""(() => { const p = document.querySelector('#chat-strip-wait');
          return { hidden: p.hidden, rects: p.getClientRects().length, tabs: document.querySelectorAll('#chat-pane [role=tab], #chat-pane [role=tablist]').length, kids: p.children.length,
                   strip: document.querySelector('#chat-strip').hidden }; })()""")
        assert strip == {"hidden": True, "rects": 0, "tabs": 0, "kids": 0, "strip": True}, (extra, strip)
        seen.append((browser.evaluate(MEASURE_PARITY), browser.evaluate("""Math.round(document.querySelector('#chat').getBoundingClientRect().top
          - document.querySelector('#chat-pane').getBoundingClientRect().top + document.querySelector('#chat-pane').scrollTop)""")))
        bare = browser.evaluate(UNSTYLED)
        assert bare["gone"] > 40 and bare["nodes"] > 40 and bare["changed"] == [], (extra, bare)      # no rule of the box reaches this session's view
    assert seen[0] == seen[1], seen


@pytest.mark.parametrize("size", SIZES)
def test_markup_in_a_line_is_drawn_as_text(served, browser, monkeypatch, size):
    bad = '<img src=x onerror="window.__ran=1"><b>bold</b>'
    open_strip(browser, served, monkeypatch, size, motion=[line(bad), line(bad + " https://example.com/x")])
    click(browser, ONIT_TAB)
    rows = browser.evaluate(ROWS)["rows"]
    assert [(r["title"], r["href"]) for r in rows] == [(bad, None), (bad + " https://example.com/x", None)], rows
    assert browser.evaluate(f"[document.querySelectorAll('#chat-strip-wait img, #chat-strip-wait b, #{ONIT_PANEL} a').length, window.__ran === undefined]") == [0, True]


# ── no sideways scroll, the height cap, the touch targets ────────────────────
WIDE = """(() => { const root = document.scrollingElement, p = document.querySelector('#chat-strip-wait'), pane = document.querySelector('#chat-pane'), vw = document.documentElement.clientWidth;
  const shown = (n) => n.getClientRects().length > 0, name = (n) => (n.id || n.className || n.tagName) + ' ';
  const over = [...p.querySelectorAll('*')].filter(shown).filter((n) => { const r = n.getBoundingClientRect(); return r.right > vw + 0.5 || r.left < -0.5; }).map(name);
  const wide = [p, ...p.querySelectorAll('.wait-bar, .wait-tabs, .wait-tab, .wait, .wait-list, .wait-row, .wait-meta, .wait-sum, .wait-cap')].filter(shown)
    .filter((n) => n.scrollWidth > n.clientWidth + 1).map((n) => name(n) + n.scrollWidth + '>' + n.clientWidth);
  const outRow = [];
  for (const row of [...p.querySelectorAll('.wait-row')].filter(shown)) { const rr = row.getBoundingClientRect();
    for (const n of row.querySelectorAll('.wait-id, .wait-link, .wait-title, .wait-meta, .wait-meta > span')) { const r = n.getBoundingClientRect(); if (r.right > rr.right + 0.5 || r.left < rr.left - 0.5) outRow.push(name(n)); } }
  const parts = [...p.querySelectorAll('.wait-tab, .wait-help, .wait-chev')].filter(shown).map((n) => n.getBoundingClientRect());
  const overlap = parts.some((a, i) => parts.slice(i + 1).some((b) => a.right > b.left + 0.5 && b.right > a.left + 0.5));
  return { vw, doc: [root.scrollWidth, root.clientWidth], body: [document.body.scrollWidth, document.body.clientWidth], pane: [pane.scrollWidth, pane.clientWidth], over, wide, outRow, overlap,
           open: [...p.querySelectorAll('.wait')].filter(shown).map((w) => w.id), parts: parts.length }; })()"""


@pytest.mark.parametrize("which", ["closed", "move", "onit"])
@pytest.mark.parametrize("drawer", [False, True], ids=["drawer-shut", "drawer-open"])
@pytest.mark.parametrize("width", WIDTHS)
def test_no_sideways_scroll_with_the_bar_closed_and_on_each_tab_and_hostile_text(served, browser, monkeypatch, width, drawer, which):
    group = {"en": "G" * 40, "ko": cp(0xACB0) * 40}
    open_strip(browser, served, monkeypatch, (width, 800 if width > 700 else 844), waiting=waiting(12, long=True), motion=hostile(12), group=group)
    assert wait_for(browser, f"{PIN}.querySelectorAll('#{ONIT_PANEL} .wait-row').length === 12", 10.0)
    if width < 700:
        phone(browser, width)
        if drawer:
            drawer_open(browser)
    if which != "closed":
        click(browser, MOVE_TAB if which == "move" else ONIT_TAB)
    browser.settle(PIN)
    where = f"{width} px, drawer {'open' if drawer else 'shut'}, {which}"
    got = browser.evaluate(WIDE)
    assert got["vw"] == width and got["parts"] == (4 if which == "onit" else 3) and got["open"] == {"closed": [], "move": [MOVE_PANEL], "onit": [ONIT_PANEL]}[which], (where, got)
    assert got["doc"][0] <= got["doc"][1] and got["body"][0] <= got["body"][1] and got["pane"][0] <= got["pane"][1], f"{where}: the page or the pane scrolls sideways: {got}"
    assert got["over"] == [] and got["wide"] == [] and got["outRow"] == [] and not got["overlap"], f"{where}: something of the strip is wider than its place: {got}"
    check(browser.evaluate(MEASURE), where)


@pytest.mark.parametrize("width", WIDTHS)
def test_open_the_second_list_stays_within_40vh_scrolls_inside_and_the_bar_stays_put(served, browser, monkeypatch, width):
    open_strip(browser, served, monkeypatch, (width, 800 if width > 700 else 844), motion=hostile(30))
    if width < 700:
        phone(browser, width)
    click(browser, ONIT_TAB)
    browser.settle(PIN)
    got = browser.evaluate("""(() => { const p = document.querySelector('#chat-strip-wait'), w = document.querySelector('#chat-strip-onit-panel'), bar = p.querySelector('.wait-bar');
      const before = bar.getBoundingClientRect().top; w.style.scrollBehavior = 'auto'; w.scrollTop = w.scrollHeight; const rows = w.querySelectorAll('.wait-row');
      return { h: p.getBoundingClientRect().height, vh: innerHeight, room: w.scrollHeight - w.clientHeight, at: Math.round(w.scrollTop), over: getComputedStyle(w).overflowY + ' ' + getComputedStyle(w).overflowX,
               bar: [before, bar.getBoundingClientRect().top, p.getBoundingClientRect().top], barH: bar.getBoundingClientRect().height,
               under: Math.round(w.getBoundingClientRect().bottom - rows[rows.length - 1].getBoundingClientRect().bottom),
               thread: document.querySelector('#chat-pane').getBoundingClientRect().height - p.getBoundingClientRect().height }; })()""")
    assert got["h"] <= 0.4 * got["vh"] + 0.5 and got["room"] > 0 and got["at"] > 0 and got["over"] == "auto hidden", got
    assert got["bar"][0] == got["bar"][1] and abs(got["bar"][1] - got["bar"][2]) < 1 and got["barH"] >= 36, got       # the bar is not squeezed or scrolled away
    assert got["under"] >= 12 and got["thread"] > 0.25 * got["vh"], got


@pytest.mark.parametrize("width", [390, 360, 320])
def test_on_a_touch_screen_the_tabs_the_chevron_and_every_row_give_a_44px_target(served, browser, monkeypatch, width):
    open_strip(browser, served, monkeypatch, (width, 844))
    phone(browser, width)
    browser.touch()
    assert wait_for(browser, "matchMedia('(pointer: coarse)').matches", 10.0)
    read = """(() => { const p = document.querySelector('#chat-strip-wait'), box = (n) => n.getBoundingClientRect(), shown = (n) => n.getClientRects().length > 0;
      return { tabs: [...p.querySelectorAll('.wait-tab')].map((t) => box(t).height), chev: [box(p.querySelector('.wait-chev')).width, box(p.querySelector('.wait-chev')).height],
               help: shown(p.querySelector('.wait-help')) ? [box(p.querySelector('.wait-help')).width, box(p.querySelector('.wait-help')).height] : null,
               rows: [...p.querySelectorAll('.wait-row')].filter(shown).map((r) => box(r).height), links: [...p.querySelectorAll('.wait-link')].filter(shown).map((a) => box(a).height) }; })()"""
    for tab, rows, links in ((ONIT_TAB, 4, 0), (MOVE_TAB, 2, 2)):
        click(browser, tab)
        browser.settle(PIN)
        got = browser.evaluate(read)
        assert len(got["tabs"]) == 2 and all(h >= 43.9 for h in got["tabs"] + got["chev"] + got["rows"]), got
        assert len(got["rows"]) == rows and len(got["links"]) == links and all(h >= 44 for h in got["links"]), got
        # the (?) is on the second tab only, and gives a finger 44 px too
        assert (got["help"] is not None) == (tab == ONIT_TAB) and all(v >= 43.9 for v in (got["help"] or [44])), got


# The first list's title links as a finger meets them (the second list has none). Each link is scrolled to the middle of the list; at five places along each of its
# lines the run of pixels that elementFromPoint gives to that same link is counted upwards and downwards (`short`: the places with under 44). `overlap`: two links'
# boxes that cross. `row`: whether a point of the row beside its link answers as the link. `heights`: the rows whose title is one line.
TAPS = """(() => { const w = document.getElementById('__PANEL__'); w.style.scrollBehavior = 'auto';
  const links = [...w.querySelectorAll('.wait-link')], lines = (a) => [...a.getClientRects()].filter((r) => r.width >= 2);
  const boxes = links.map(lines), overlap = [], short = [], row = [], heights = [];
  boxes.forEach((one, i) => boxes.slice(i + 1).forEach((other, k) => { for (const a of one) for (const b of other) {
    const x = Math.min(a.right, b.right) - Math.max(a.left, b.left), y = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top); if (x > 0.1 && y > 0.1) overlap.push([i, i + 1 + k, y]); } }));
  links.forEach((a, i) => {
    const q = a.getBoundingClientRect(), b = w.getBoundingClientRect(); w.scrollTop += Math.round((q.top + q.bottom - b.top - b.bottom) / 2);
    const own = (x, y) => document.elementFromPoint(x, y) === a;
    lines(a).forEach((r, n) => { for (const t of [0, 0.25, 0.5, 0.75, 1]) {
      const x = r.left + 1 + (r.width - 2) * t, mid = Math.floor((r.top + r.bottom) / 2); let up = mid, down = mid, high = 0;
      if (own(x, mid)) { while (own(x, up - 1)) up--; while (own(x, down + 1)) down++; high = down - up + 1; }
      if (high < 44) short.push([i, n, t, high]); } });
    const li = a.closest('.wait-row'), lr = li.getBoundingClientRect(), all = lines(a), first = all[0];
    const now = a.getBoundingClientRect();
    for (const x of [lr.left + 3, lr.right - 3]) if (x < now.left - 1 || x > now.right + 1) row.push(own(x, (first.top + first.bottom) / 2));
    if (all.length === 1) heights.push(li.getBoundingClientRect().height);
  });
  return { links: links.length, wrapped: boxes.filter((x) => x.length > 1).length, overlap, short, row, heights }; })()"""


def tight_rows() -> list[dict]:
    """The first list: one-line rows next to each other, where tap areas are closest, and one title that wraps."""
    subjects = ["Short one", "Short two", "Short three", "A title that wraps: " + "an item subject that keeps going and going " * 6, "Short five", "Short six"]
    return [{"id": f"demo#{i}", "subject": t, "url": f"https://example.com/moves/{i}"} for i, t in enumerate(subjects, 1)]


@pytest.mark.parametrize("size", SIZES)
def test_on_a_touch_screen_every_title_link_has_44px_of_its_own(served, browser, monkeypatch, size):
    open_strip(browser, served, monkeypatch, size, waiting=tight_rows())
    if size[0] < 700:
        phone(browser, size[0])
    browser.touch()
    assert wait_for(browser, "matchMedia('(pointer: coarse)').matches", 10.0)
    click(browser, MOVE_TAB)
    browser.settle(PIN)
    got = browser.evaluate(TAPS.replace("__PANEL__", MOVE_PANEL))
    assert got["links"] == 6 and got["wrapped"] >= 1, got
    assert got["short"] == [], ("under 44 px of the link's own at these places (link, line, how far along, px)", got)
    assert got["overlap"] == [], got
    assert got["row"] and not any(got["row"]), ("only the link is the link, not its row", got)
    assert len(got["heights"]) >= 4 and max(got["heights"]) <= 45.5, got      # the tallest a one-line row may be: 12 + 20 + 12 and its rule


def test_with_a_mouse_a_title_link_has_no_padding_of_its_own(served, browser, monkeypatch):
    open_strip(browser, served, monkeypatch, DESKTOP, waiting=tight_rows())
    assert browser.evaluate("matchMedia('(pointer: coarse)').matches") is False
    got = browser.evaluate("""[...document.querySelectorAll('#chat-strip-wait .wait-link')].map((a) => { const c = getComputedStyle(a); return [c.paddingTop, c.paddingBottom, c.position].join(' '); })""")
    assert got == ["0px 0px static"] * 6, got


# The selected tab's underline against its list: at rest where the list's first line starts, then scrolled to the end: how far under the underline the list is
# cut, what of the list answers in the 4 px under it, and (`below`) at how many of the same places across it answers just under the cut, so an empty `inside` is
# not a probe that finds nothing anywhere. elementFromPoint answers for the 1 px square that starts at its point, so the last place wholly in the gap is 3 px
# under the underline: from 3.5 the square already reaches the list.
CUT = """(() => { const w = document.getElementById('__PANEL__'); w.style.scrollBehavior = 'auto'; w.scrollTop = 0;
  const under = document.querySelector('#chat-strip-wait .wait-tab[aria-selected="true"]').getBoundingClientRect().bottom;
  const first = [...w.children].find((n) => n.getClientRects().length).getBoundingClientRect().top;
  w.scrollTop = w.scrollHeight; const r = w.getBoundingClientRect(), inside = []; let below = 0;
  const list = (x, y) => { const n = document.elementFromPoint(x, y); return n && n.closest('.wait') ? n : null; };
  for (const x of [r.left + 20, r.left + r.width / 2, r.right - 20]) { for (const dy of [0, 1, 2, 3]) { const n = list(x, under + dy); if (n) inside.push([x, dy, n.className]); }
    if (list(x, r.top + 1)) below++; }
  return { rest: first - under, gap: r.top - under, scrolled: Math.round(w.scrollTop), inside, below }; })()"""


@pytest.mark.parametrize("size", SIZES)
def test_a_list_scrolled_to_its_end_is_cut_below_the_selected_tabs_underline_not_on_it(served, browser, monkeypatch, size):
    open_strip(browser, served, monkeypatch, size, waiting=waiting(30), motion=hostile(30))
    if size[0] < 700:
        phone(browser, size[0])
    for tab, panel in ((MOVE_TAB, MOVE_PANEL), (ONIT_TAB, ONIT_PANEL)):
        click(browser, tab)
        browser.settle(PIN)
        got = browser.evaluate(CUT.replace("__PANEL__", panel))
        assert got["scrolled"] > 0 and got["gap"] >= 3.5 and got["inside"] == [] and got["below"] == 3, (panel, got)
        assert 3.5 <= got["rest"] <= 6.5, (panel, "at rest the list starts about where it did", got)
