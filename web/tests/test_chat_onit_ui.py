"""The chat strip's second tab, "On it", in a headless Chromium (the read, the payload and the row helpers are test_involved.py; the pinned line alone, as it is
while that read is unavailable, is test_chat_wait_pin_ui.py).

The rule: when api/chat carries `onIt`, the pinned line is a bar of two tabs, the owner's group and "On it", with a chevron, and one list is open at a time,
inside the same 40vh box; without it the strip is the one line as before, with nothing said. Held here at 1280 x 800 and 390 x 844 (the width rule also at 360
and 320), with api/chat replaced in the page (but for the case of an item that becomes the owner's move, which the app answers itself from a stand-in stackshot):
  - closed: both counts in a bar as high as the line it replaces, no list, an amber dot while a row is late (never for a held one), said in the tab's name too;
  - a tab opens its list and closes it again, the other tab switches, the chevron closes the open list and opens the one last open, a read keeps it open;
  - a tab list for the keyboard and a screen reader: role tablist, tab and tabpanel, aria-selected on the open one, one tab in the Tab order, the arrows, Home and
    End move between the tabs and Enter or Space open the one reached;
  - a row: the id and the title as the link, who, since when, the days of a late one (amber past two days, red past five), the day a held one comes back, no
    "new" tag; the late count over the list; with nothing owed the tab is a quiet 0 and the list says so; with both lists empty nothing is drawn;
  - while the read is unavailable the strip is the one line, and the bar comes and goes with the read;
  - an item that becomes the owner's move stays in the second tab until the first list holds it, then leaves it, the counts and the late dot following;
  - a Korean page names the tab and words the rows in Korean;
  - a session that is not the chat session has no tabs, looks the same whether the list is there or not, and the same again with every style rule of the strip's
    pinned box taken out of the page, with a mouse and on a touch screen;
  - markup in every field is text;
  - NO SIDEWAYS SCROLL, at 1280, 390, 360 and 320 px, closed and on each tab, with long ids, subjects, movers, group names and dates; open, the box stays within
    40vh and the list scrolls inside it; on a touch screen the tabs, the chevron and every row give 44 px;
  - on a touch screen, 390 x 844 and 1280 x 800, on both lists a finger anywhere along a title link has 44 px of that link (read with elementFromPoint), no two
    links' areas overlap, the line under a title takes none of those taps, the rest of the row is no link and a one-line row is no taller; with a mouse the
    link has no padding of its own;
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
from fake_stackshot import FakeStackshot
from sala_web import involved as IV
from sala_web import yourmove as YM
from test_board_items_ui import wait_for
from test_chat_session_view_ui import DESKTOP, MEASURE, MEASURE_PARITY, SIZES, URL, WORD, api_chat, check, code_transcript, drawer_open, open_page

DAY = 86400
WIDTHS = [1280, 390, 360, 320]
PIN = "document.querySelector('#chat-strip-wait')"
MOVE_TAB = "document.querySelector('#chat-strip-tab-move')"
ONIT_TAB = "document.querySelector('#chat-strip-tab-onit')"
CHEVRON = "document.querySelector('#chat-strip-wait .wait-chev')"
MOVE_PANEL, ONIT_PANEL = "chat-strip-wait-panel", "chat-strip-onit-panel"
NOTHING = "Nothing is owed to this chat"


def cp(*codes) -> str:
    return "".join(chr(c) for c in codes)


def promise(n: int, **kw) -> dict:
    d = {"id": f"demo#{n}", "subject": f"Promise {n}", "url": f"https://example.com/promises/{n}", "mover": "x-demo-engineer", "held": False, "until": None,
         "since": int(time.time()) - 60}
    d.update(kw)
    return d


def promises() -> list[dict]:
    """One late (3 days), one red (a week), one held for a day (ten days old, so late if it were not held), one fresh."""
    now = int(time.time())
    return [promise(11, since=now - 3 * DAY - 3600),
            promise(12, since=now - 7 * DAY - 3600, mover="swift-demo-name"),
            promise(13, since=now - 10 * DAY, held=True, until="2027-01-12", mover=NAME),
            promise(14, mover="", url="")]


def hostile(n: int = 3) -> list[dict]:
    long_subject = "[demo] " + "an item subject that keeps going and going " * 6 + WORD + " " + URL
    first = [promise(1, id="item#" + "1" * 75, subject=long_subject, url=URL, mover="m" * 200, held=True, until="9999-12-31", since=1),
             promise(2, subject=WORD, url="", mover="a-very-long-" + "name-" * 36 + "engineer", since=1),
             promise(3, subject=cp(0xD50C, 0xB8E8, 0xB9AC, 0xC6C0, 0x20) * 30 + URL, mover=WORD, since=int(time.time()) - 3 * DAY)]
    return (first + [promise(i, subject=long_subject, mover=WORD, since=1) for i in range(4, n + 1)])[:n]


def waiting(n: int = 2, long: bool = False) -> list[dict]:
    subject = ("an item subject that keeps going " * 6 + WORD + " " + URL) if long else "to answer"
    return [{"id": f"demo#{i}", "subject": f"Move {i} {subject}", "url": f"https://example.com/moves/{i}"} for i in range(1, n + 1)]


def open_strip(browser, served, monkeypatch, size, **over) -> None:
    over.setdefault("waiting", waiting())
    over.setdefault("onIt", promises())
    open_page(browser, served, monkeypatch, size, api_chat(**over))
    assert wait_for(browser, "!document.querySelector('#chat-strip').hidden", 15.0)
    if over["waiting"] or over["onIt"]:
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
  return { pin: shown(p), h: p.getBoundingClientRect().height, toggle: shown(q('.wait-toggle')), bar: shown(q('.wait-bar')), text: p.innerText.trim(),
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
def test_closed_the_bar_shows_both_counts_and_the_late_dot_as_high_as_the_line_it_replaces(served, browser, monkeypatch, size):
    open_page(browser, served, monkeypatch, size, api_chat(waiting=waiting()))
    assert wait_for(browser, f"!{PIN}.hidden", 15.0)
    line = state(browser)
    assert line["toggle"] and not line["bar"], line
    change(browser, onIt=promises())
    assert wait_for(browser, f"{PIN}.querySelector('.wait-bar').getClientRects().length > 0", 10.0)
    s = state(browser)
    assert s["pin"] and not s["toggle"] and s["open"] == [] and abs(s["h"] - line["h"]) <= 1, (line, s)
    assert [t["text"] for t in s["tabs"]] == ["Your move · 2", "On it · 4"] and s["tablist"] == "Chat lists", s
    assert [(t["id"], t["controls"], t["tag"], t["type"]) for t in s["tabs"]] == [("chat-strip-tab-move", MOVE_PANEL, "BUTTON", "button"),
                                                                                ("chat-strip-tab-onit", ONIT_PANEL, "BUTTON", "button")], s
    assert selected(s) == ["false", "false"] and [t["index"] for t in s["tabs"]] == ["0", "-1"] and not [t for t in s["tabs"] if t["zero"]], s
    # two rows are late (3 days and a week); the held one is older than both and does not count
    assert s["dot"] and [t["label"] for t in s["tabs"]] == [None, "On it · 4, 2 older than 2 days"], s
    assert s["chev"] == ["false", "Show the list: Your move", MOVE_PANEL, "Show the list: Your move"], s
    # nothing late: no dot, and the tab's name is its words alone
    change(browser, onIt=[promise(1), promise(2, held=True, since=int(time.time()) - 30 * DAY)])
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
    change(browser, onIt=promises() + [promise(15)])
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
    change(browser, onIt=promises()[:2])
    assert wait_for(browser, f"{ONIT_TAB}.textContent.trim() === 'On it · 2'", 10.0)
    s = state(browser)
    assert s["focus"] == "chat-strip-tab-move" and [t["index"] for t in s["tabs"]] == ["0", "-1"], s


# ── the rows ─────────────────────────────────────────────────────────────────
ROWS = """(() => { const probe = (v) => { const i = document.createElement('i'); i.style.color = 'var(' + v + ')'; document.body.append(i); const c = getComputedStyle(i).color; i.remove(); return c; };
  const warn = probe('--warn'), red = probe('--waiting'), tone = (n) => { const c = getComputedStyle(n).color; return c === warn ? 'amber' : c === red ? 'red' : ''; };
  const p = document.querySelector('#chat-strip-onit-panel'), shown = (n) => !!n && n.getClientRects().length > 0, sum = p.querySelector('.wait-sum');
  return { sum: shown(sum) ? sum.textContent : null, empty: shown(p.querySelector('.wait-empty')) ? p.querySelector('.wait-empty').textContent : null,
    list: shown(p.querySelector('.wait-list')), note: p.querySelector('.wait-cap').textContent,
    rows: [...p.querySelectorAll('.wait-row')].map((r) => { const a = r.querySelector('a'), id = r.querySelector('.wait-id'), t = r.querySelector('.wait-link, .wait-title');
      return { cls: r.className, id: id ? id.textContent : null, title: t.textContent, href: a ? a.getAttribute('href') : null, target: a ? a.target : null, tags: r.querySelectorAll('.new').length,
        under: r.querySelector('.wait-meta').getBoundingClientRect().top >= r.querySelector('.wait-subj').getBoundingClientRect().bottom - 0.5,
        meta: [...r.querySelectorAll('.wait-meta > span')].map((s) => ({ cls: s.className.trim(), text: s.textContent, tip: s.title, tone: tone(s) })) }; }) }; })()"""


@pytest.mark.parametrize("size", SIZES)
def test_a_row_shows_who_since_when_how_late_and_the_day_a_held_one_comes_back(served, browser, monkeypatch, size):
    open_strip(browser, served, monkeypatch, size)
    click(browser, ONIT_TAB)
    got = browser.evaluate(ROWS)
    assert got["sum"] == "2 older than 2 days" and got["empty"] is None and got["list"], got
    assert got["note"].startswith("These lines are the board") and "with no board item" in got["note"], got
    rows = got["rows"]
    assert [r["cls"] for r in rows] == ["wait-row back-row late", "wait-row back-row red", "wait-row back-row", "wait-row back-row"], rows
    assert [(r["id"], r["title"], r["href"], r["target"]) for r in rows] == [
        ("demo#11", "Promise 11", "https://example.com/promises/11", "_blank"), ("demo#12", "Promise 12", "https://example.com/promises/12", "_blank"),
        ("demo#13", "Promise 13", "https://example.com/promises/13", "_blank"), ("demo#14", "Promise 14", None, None)], rows
    assert all(r["under"] and r["tags"] == 0 for r in rows), rows
    late, red, held, fresh = (r["meta"] for r in rows)
    assert [(m["cls"], m["tone"]) for m in late] == [("who", ""), ("late", "amber"), ("late age", "amber")], late
    assert late[0]["text"] == "demo builder" and late[0]["tip"] == "x-demo-engineer" and late[2]["text"] == "3 days", late
    assert re.fullmatch(r"since [A-Z][a-z]{2} \d\d:\d\d", late[1]["text"]), late
    assert [(m["cls"], m["tone"]) for m in red] == [("who", ""), ("red", "red"), ("red age", "red")], red
    assert red[0]["text"] == "swift-demo-name" and red[2]["text"] == "7 days", red
    assert re.fullmatch(r"since [A-Z][a-z]{2} [A-Z][a-z]{2} \d{1,2}(st|nd|rd|th)", red[1]["text"]), red
    assert [m["cls"] for m in held] == ["who", "", "park"] and held[2]["text"] == "parked until Tue Jan 12th", held
    assert held[0]["text"] == "Ada" and held[0]["tip"] == NAME and not [m for m in held if m["tone"]], held          # the chat session by the header's name
    assert [m["cls"] for m in fresh] == [""] and re.fullmatch(r"since ([A-Z][a-z]{2} )?\d\d:\d\d", fresh[0]["text"]), fresh      # no mover: no word for one
    # an item new to the first list since the page's first answer is tagged "new" there; a row of the second list never carries the tag, one with the same id
    # included (the page's own rule: the server's answer never holds an item in both)
    change(browser, onIt=promises() + [promise(3)], waiting=waiting(3))
    assert wait_for(browser, f"{PIN}.querySelectorAll('#{ONIT_PANEL} .wait-row').length === 5", 10.0)
    assert browser.evaluate(f"[document.querySelectorAll('#{ONIT_PANEL} .new').length, document.querySelectorAll('#{MOVE_PANEL} .new').length]") == [0, 1]


@pytest.mark.parametrize("size", SIZES)
def test_with_nothing_owed_the_tab_is_a_quiet_zero_and_with_both_lists_empty_nothing_is_drawn(served, browser, monkeypatch, size):
    open_strip(browser, served, monkeypatch, size, onIt=[])
    s = state(browser)
    assert s["bar"] and [t["text"] for t in s["tabs"]] == ["Your move · 2", "On it · 0"] and [t["zero"] for t in s["tabs"]] == [False, True] and not s["dot"], s
    click(browser, ONIT_TAB)
    got = browser.evaluate(ROWS)
    assert state(browser)["open"] == [ONIT_PANEL] and got["empty"] == NOTHING and not got["list"] and got["sum"] is None and got["rows"] == [], got
    # only the second list has rows: the bar stands, the owner's tab is the quiet one
    change(browser, waiting=[], onIt=[promise(1)])
    assert wait_for(browser, f"{MOVE_TAB}.textContent.trim() === 'Your move · 0' && {ONIT_TAB}.textContent.trim() === 'On it · 1'", 10.0)
    s = state(browser)
    assert s["pin"] and [t["zero"] for t in s["tabs"]] == [True, False] and s["open"] == [ONIT_PANEL] and browser.evaluate(ROWS)["empty"] is None, s
    change(browser, onIt=[])
    assert wait_for(browser, f"{PIN}.hidden", 10.0)
    s = state(browser)
    assert not s["pin"] and s["h"] == 0, s


@pytest.mark.parametrize("size", SIZES)
def test_while_the_read_is_unavailable_the_strip_is_the_one_line_and_the_bar_comes_and_goes_with_it(served, browser, monkeypatch, size):
    open_page(browser, served, monkeypatch, size, api_chat(waiting=waiting()))
    assert wait_for(browser, f"!{PIN}.hidden", 15.0)
    plain = state(browser)
    assert plain["toggle"] and not plain["bar"] and plain["text"] == "Your move · 2" and plain["open"] == [], plain
    assert [(w["role"], w["by"]) for w in plain["panels"] if w["id"] == MOVE_PANEL] == [(None, None)], plain
    click(browser, PIN + ".querySelector('.wait-toggle')")
    assert state(browser)["open"] == [MOVE_PANEL]
    change(browser, onIt=promises())                 # the read arrives: the open list stays open, now the first tab's panel
    assert wait_for(browser, f"{PIN}.querySelector('.wait-bar').getClientRects().length > 0", 10.0)
    s = state(browser)
    assert not s["toggle"] and s["open"] == [MOVE_PANEL] and selected(s) == ["true", "false"], s
    change(browser, onIt=None)                       # and goes: the line again, its list still open
    assert wait_for(browser, f"{PIN}.querySelector('.wait-toggle').getClientRects().length > 0", 10.0)
    s = state(browser)
    assert not s["bar"] and s["open"] == [MOVE_PANEL] and [(w["role"], w["by"]) for w in s["panels"] if w["id"] == MOVE_PANEL] == [(None, None)], s
    change(browser, onIt=promises())
    assert wait_for(browser, f"{PIN}.querySelector('.wait-bar').getClientRects().length > 0", 10.0)
    click(browser, ONIT_TAB)
    change(browser, onIt=None)                       # the second list was open when the read went: it closes, with no word about it
    assert wait_for(browser, f"{PIN}.querySelector('.wait-toggle').getClientRects().length > 0", 10.0)
    s = state(browser)
    assert s["open"] == [] and s["text"] == plain["text"] and abs(s["h"] - plain["h"]) <= 1, (plain, s)
    # with nothing waiting and no read there is no line, as before
    change(browser, waiting=[])
    assert wait_for(browser, f"{PIN}.hidden", 10.0)


@pytest.mark.parametrize("size", SIZES)
def test_a_korean_page_names_the_tab_and_words_the_rows(served, browser, monkeypatch, size):
    open_strip(browser, served, monkeypatch, size)
    click(browser, ONIT_TAB)
    browser.evaluate("SalaI18n.setLang('ko'); ''")
    tab = cp(0xC9C4, 0xD589, 0x20, 0xC911)
    assert wait_for(browser, f"{ONIT_TAB}.textContent.trim() === {json.dumps(tab + ' · 4')}", 10.0), state(browser)
    s = state(browser)
    assert s["tabs"][0]["text"] == cp(0xB0B4, 0x20, 0xCC28, 0xB840) + " · 2" and s["tablist"] == cp(0xCC44, 0xD305, 0x20, 0xBAA9, 0xB85D) and s["open"] == [ONIT_PANEL], s
    rows = browser.evaluate(ROWS)["rows"]
    assert rows[0]["meta"][0]["text"] == "demo builder" and rows[0]["meta"][1]["text"].endswith(cp(0xBD80, 0xD130)), rows
    assert rows[2]["meta"][2]["text"] == "1" + cp(0xC6D4) + " 12" + cp(0xC77C) + "(" + cp(0xD654) + ")" + cp(0xAE4C, 0xC9C0, 0x20, 0xBCF4, 0xB958), rows
    # the owner picked the tab's name knowing the lines under the bar are headed with the same word: that heading is unchanged
    assert browser.evaluate("document.querySelector('#chat-strip .motion .lbl').textContent") == tab


# ── what becomes the owner's move ────────────────────────────────────────────
@pytest.fixture
def board_served(tmp_path, monkeypatch, request):
    """(`served`, a stand-in stackshot it reads): the page's api/chat is the app's own answer, and both lists' reads follow the stand-in at once."""
    monkeypatch.setattr(IV, "TTL", 0.2)                   # before the app is made: a cache takes its TTL then
    monkeypatch.setattr(YM, "TTL", 0.2)
    stack = FakeStackshot(tmp_path / "board-cfg")
    try:
        monkeypatch.setenv("SALA_WEB_STACKSHOT_TOKEN", str(stack.token_file))
        monkeypatch.setenv("SALA_WEB_STACKSHOT_URL", str(stack.url_file))
        yield request.getfixturevalue("served"), stack
    finally:
        stack.close()


def read_until(browser, expr: str, timeout: float = 20.0) -> bool:
    """The page reads api/chat again and again until `expr` holds (an answer comes from the cache, so a change of the board shows a read or two later)."""
    end = time.time() + timeout
    while time.time() < end:
        browser.evaluate("loadChatMarks(); ''")
        if wait_for(browser, expr, 0.5):
            return True
    return False


@pytest.mark.parametrize("size", SIZES)
def test_an_item_that_becomes_the_owners_move_leaves_the_second_tab_and_its_count_and_dot_follow(board_served, browser, monkeypatch, size):
    served, stack = board_served

    def ref(n: int) -> dict:
        return {"shown": f"demo#{n}", "subject": f"Promise {n}", "url": f"https://example.com/promises/{n}"}

    def involved(n: int, where: str = "agents", age: float = 60) -> dict:
        return {**ref(n), "mover": "x-demo-engineer", "list": where, "held": False, "until": None, "state_updated": time.time() - age}

    def counts(move: int, onit: int) -> str:
        return f"{MOVE_TAB}.textContent.trim() === 'Your move · {move}' && {ONIT_TAB}.textContent.trim() === 'On it · {onit}'"

    stack.your_move = [ref(9)]
    stack.involved = {NAME: [involved(1, age=3 * DAY + 3600), involved(2)]}
    open_page(browser, served, monkeypatch, size)
    assert read_until(browser, counts(1, 2)), state(browser)
    s = state(browser)
    assert s["dot"] and s["tabs"][1]["label"] == "On it · 2, 1 older than 2 days", s
    click(browser, ONIT_TAB)
    assert [r["id"] for r in browser.evaluate(ROWS)["rows"]] == ["demo#1", "demo#2"]
    # the late one becomes the owner's move, and only the second read has seen it: it stays where it is, late as before
    stack.involved = {NAME: [{**involved(1, "your-move", 3 * DAY + 3600), "mover": "swift-demo-name"}, involved(2)]}
    assert read_until(browser, f"document.querySelector('#{ONIT_PANEL}').textContent.includes('swift-demo-name')"), state(browser)
    assert browser.evaluate(counts(1, 2)) and state(browser)["dot"], state(browser)
    assert [r["id"] for r in browser.evaluate(ROWS)["rows"]] == ["demo#1", "demo#2"]
    # the first list's read follows
    stack.your_move = [ref(9), ref(1)]
    assert read_until(browser, counts(2, 1)), state(browser)
    s = state(browser)
    assert not s["dot"] and s["tabs"][1]["label"] == "On it · 1" and s["open"] == [ONIT_PANEL], s
    got = browser.evaluate(ROWS)
    assert [r["id"] for r in got["rows"]] == ["demo#2"] and got["sum"] is None, got
    click(browser, MOVE_TAB)
    tagged = browser.evaluate(f"[...document.querySelectorAll('#{MOVE_PANEL} .wait-row')].filter((r) => r.textContent.includes('demo#1'))"
                              ".map((r) => !!r.querySelector('.new'))")
    assert tagged == [True], state(browser)


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
def test_a_second_session_has_no_tabs_and_looks_the_same_with_the_list_there_or_not(served, browser, monkeypatch, size, finger):
    transcript_file(served).write_text(code_transcript())
    seen = []
    for extra in ({}, {"onIt": promises()}):
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
def test_markup_in_every_field_is_drawn_as_text(served, browser, monkeypatch, size):
    bad = '<img src=x onerror="window.__ran=1"><b>bold</b>'
    open_strip(browser, served, monkeypatch, size, onIt=[promise(1, id=bad, subject=bad, mover=bad, url=""), promise(2, subject=bad, mover=bad + "-engineer")])
    click(browser, ONIT_TAB)
    rows = browser.evaluate(ROWS)["rows"]
    assert rows[0]["id"] == bad and rows[0]["title"] == bad and rows[0]["meta"][0]["text"] == bad and rows[1]["meta"][0]["text"] == bad + "-engineer", rows
    assert browser.evaluate(f"[document.querySelectorAll('#chat-strip-wait img, #chat-strip-wait b').length, window.__ran === undefined]") == [0, True]


# ── no sideways scroll, the height cap, the touch targets ────────────────────
WIDE = """(() => { const root = document.scrollingElement, p = document.querySelector('#chat-strip-wait'), pane = document.querySelector('#chat-pane'), vw = document.documentElement.clientWidth;
  const shown = (n) => n.getClientRects().length > 0, name = (n) => (n.id || n.className || n.tagName) + ' ';
  const over = [...p.querySelectorAll('*')].filter(shown).filter((n) => { const r = n.getBoundingClientRect(); return r.right > vw + 0.5 || r.left < -0.5; }).map(name);
  const wide = [p, ...p.querySelectorAll('.wait-bar, .wait-tabs, .wait-tab, .wait, .wait-list, .wait-row, .wait-meta, .wait-sum, .wait-cap')].filter(shown)
    .filter((n) => n.scrollWidth > n.clientWidth + 1).map((n) => name(n) + n.scrollWidth + '>' + n.clientWidth);
  const outRow = [];
  for (const row of [...p.querySelectorAll('.wait-row')].filter(shown)) { const rr = row.getBoundingClientRect();
    for (const n of row.querySelectorAll('.wait-id, .wait-link, .wait-title, .wait-meta, .wait-meta > span')) { const r = n.getBoundingClientRect(); if (r.right > rr.right + 0.5 || r.left < rr.left - 0.5) outRow.push(name(n)); } }
  const parts = [...p.querySelectorAll('.wait-tab, .wait-chev')].filter(shown).map((n) => n.getBoundingClientRect());
  const overlap = parts.some((a, i) => parts.slice(i + 1).some((b) => a.right > b.left + 0.5 && b.right > a.left + 0.5));
  return { vw, doc: [root.scrollWidth, root.clientWidth], body: [document.body.scrollWidth, document.body.clientWidth], pane: [pane.scrollWidth, pane.clientWidth], over, wide, outRow, overlap,
           open: [...p.querySelectorAll('.wait')].filter(shown).map((w) => w.id), parts: parts.length }; })()"""


@pytest.mark.parametrize("which", ["closed", "move", "onit"])
@pytest.mark.parametrize("drawer", [False, True], ids=["drawer-shut", "drawer-open"])
@pytest.mark.parametrize("width", WIDTHS)
def test_no_sideways_scroll_with_the_bar_closed_and_on_each_tab_and_hostile_text(served, browser, monkeypatch, width, drawer, which):
    group = {"en": "G" * 40, "ko": cp(0xACB0) * 40}
    open_strip(browser, served, monkeypatch, (width, 800 if width > 700 else 844), waiting=waiting(12, long=True), onIt=hostile(12), group=group)
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
    assert got["vw"] == width and got["parts"] == 3 and got["open"] == {"closed": [], "move": [MOVE_PANEL], "onit": [ONIT_PANEL]}[which], (where, got)
    assert got["doc"][0] <= got["doc"][1] and got["body"][0] <= got["body"][1] and got["pane"][0] <= got["pane"][1], f"{where}: the page or the pane scrolls sideways: {got}"
    assert got["over"] == [] and got["wide"] == [] and got["outRow"] == [] and not got["overlap"], f"{where}: something of the strip is wider than its place: {got}"
    check(browser.evaluate(MEASURE), where)


@pytest.mark.parametrize("width", WIDTHS)
def test_open_the_second_list_stays_within_40vh_scrolls_inside_and_the_bar_stays_put(served, browser, monkeypatch, width):
    open_strip(browser, served, monkeypatch, (width, 800 if width > 700 else 844), onIt=hostile(30))
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
    click(browser, ONIT_TAB)
    browser.settle(PIN)
    got = browser.evaluate("""(() => { const p = document.querySelector('#chat-strip-wait'), box = (n) => n.getBoundingClientRect();
      return { tabs: [...p.querySelectorAll('.wait-tab')].map((t) => box(t).height), chev: [box(p.querySelector('.wait-chev')).width, box(p.querySelector('.wait-chev')).height],
               rows: [...p.querySelectorAll('#chat-strip-onit-panel .wait-row')].map((r) => box(r).height),
               links: [...p.querySelectorAll('#chat-strip-onit-panel .wait-link')].map((a) => box(a).height) }; })()""")
    assert len(got["tabs"]) == 2 and all(h >= 43.9 for h in got["tabs"] + got["chev"] + got["rows"]), got
    assert len(got["links"]) == 3 and all(h >= 44 for h in got["links"]), got


# One list's title links as a finger meets them. Each link is scrolled to the middle of the list; at five places along each of its lines the run of pixels that
# elementFromPoint gives to that same link is counted upwards and downwards (`short`: the places with under 44). `overlap`: two links' boxes that cross.
# `under`: the links whose box reaches onto the line under the title, `taken`: the places there that something else answers. `row`: whether a point of the row
# beside its link answers as the link. `heights`: the rows whose title and line under it are one line each.
TAPS = """(() => { const w = document.getElementById('__PANEL__'); w.style.scrollBehavior = 'auto';
  const links = [...w.querySelectorAll('.wait-link')], lines = (a) => [...a.getClientRects()].filter((r) => r.width >= 2);
  const boxes = links.map(lines), overlap = [], short = [], taken = [], row = [], heights = []; let under = 0;
  boxes.forEach((one, i) => boxes.slice(i + 1).forEach((other, k) => { for (const a of one) for (const b of other) {
    const x = Math.min(a.right, b.right) - Math.max(a.left, b.left), y = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top); if (x > 0.1 && y > 0.1) overlap.push([i, i + 1 + k, y]); } }));
  links.forEach((a, i) => {
    const q = a.getBoundingClientRect(), b = w.getBoundingClientRect(); w.scrollTop += Math.round((q.top + q.bottom - b.top - b.bottom) / 2);
    const own = (x, y) => document.elementFromPoint(x, y) === a;
    lines(a).forEach((r, n) => { for (const t of [0, 0.25, 0.5, 0.75, 1]) {
      const x = r.left + 1 + (r.width - 2) * t, mid = Math.floor((r.top + r.bottom) / 2); let up = mid, down = mid, high = 0;
      if (own(x, mid)) { while (own(x, up - 1)) up--; while (own(x, down + 1)) down++; high = down - up + 1; }
      if (high < 44) short.push([i, n, t, high]); } });
    const li = a.closest('.wait-row'), lr = li.getBoundingClientRect(), m = li.querySelector('.wait-meta'), all = lines(a), first = all[0], last = all[all.length - 1];
    if (m) { const top = m.getBoundingClientRect().top;
      if (last.bottom > top + 1) { under++; for (const t of [0, 0.5, 1]) for (const y of [top + 0.5, last.bottom - 1]) if (!own(last.left + 1 + (last.width - 2) * t, y)) taken.push([i, t, y - top]); } }
    const now = a.getBoundingClientRect();
    for (const x of [lr.left + 3, lr.right - 3]) if (x < now.left - 1 || x > now.right + 1) row.push(own(x, (first.top + first.bottom) / 2));
    if (all.length === 1 && (!m || m.getBoundingClientRect().height < 20)) heights.push(li.getBoundingClientRect().height);
  });
  return { links: links.length, wrapped: boxes.filter((x) => x.length > 1).length, overlap, short, under, taken, row, heights }; })()"""


def tight_rows() -> dict:
    """Both lists: one-line rows next to each other, where tap areas are closest, and one title that wraps."""
    subjects = ["Short one", "Short two", "Short three", "A title that wraps: " + "an item subject that keeps going and going " * 6, "Short five", "Short six"]
    first = [{"id": f"demo#{i}", "subject": t, "url": f"https://example.com/moves/{i}"} for i, t in enumerate(subjects, 1)]
    second = [promise(20 + i, subject=t, since=int(time.time()) - (3 * DAY + 3600 if i == 1 else 60)) for i, t in enumerate(subjects, 1)]
    return {"waiting": first, "onIt": second}


@pytest.mark.parametrize("size", SIZES)
def test_on_a_touch_screen_every_title_link_has_44px_of_its_own_and_the_line_under_it_takes_no_tap(served, browser, monkeypatch, size):
    open_strip(browser, served, monkeypatch, size, **tight_rows())
    if size[0] < 700:
        phone(browser, size[0])
    browser.touch()
    assert wait_for(browser, "matchMedia('(pointer: coarse)').matches", 10.0)
    # the tallest a one-line row may be: 12 + 20 + 12 and its rule on the first list, 16 more for the line under the title on the second
    seen = {}
    for tab, panel, tallest in ((MOVE_TAB, MOVE_PANEL, 45), (ONIT_TAB, ONIT_PANEL, 61)):
        click(browser, tab)
        browser.settle(PIN)
        seen[panel] = browser.evaluate(TAPS.replace("__PANEL__", panel)), tallest
    for panel, (got, tallest) in seen.items():      # both lists are measured before either is judged, so a failure shows both
        assert got["links"] == 6 and got["wrapped"] >= 1, seen
        assert got["short"] == [], ("under 44 px of the link's own at these places (link, line, how far along, px)", panel, seen)
        assert got["overlap"] == [], (panel, seen)
        assert got["under"] == (6 if panel == ONIT_PANEL else 0) and got["taken"] == [], (panel, seen)
        assert got["row"] and not any(got["row"]), ("only the link is the link, not its row", panel, seen)
        assert len(got["heights"]) >= 4 and max(got["heights"]) <= tallest + 0.5, (panel, seen)


def test_with_a_mouse_a_title_link_has_no_padding_of_its_own(served, browser, monkeypatch):
    open_strip(browser, served, monkeypatch, DESKTOP, **tight_rows())
    assert browser.evaluate("matchMedia('(pointer: coarse)').matches") is False
    got = browser.evaluate("""[...document.querySelectorAll('#chat-strip-wait .wait-link')].map((a) => { const c = getComputedStyle(a); return [c.paddingTop, c.paddingBottom, c.position].join(' '); })""")
    assert got == ["0px 0px static"] * 12, got


# The selected tab's underline against its list: at rest where the list's first line starts, then scrolled to the end: how far under the underline the list is
# cut, and what of the list answers in the 4 px under it.
CUT = """(() => { const w = document.getElementById('__PANEL__'); w.style.scrollBehavior = 'auto'; w.scrollTop = 0;
  const under = document.querySelector('#chat-strip-wait .wait-tab[aria-selected="true"]').getBoundingClientRect().bottom;
  const first = [...w.children].find((n) => n.getClientRects().length).getBoundingClientRect().top;
  w.scrollTop = w.scrollHeight; const r = w.getBoundingClientRect(), inside = [];
  for (const x of [r.left + 20, r.left + r.width / 2, r.right - 20]) for (const dy of [0.5, 1.5, 2.5, 3.5]) { const n = document.elementFromPoint(x, under + dy); if (n && n.closest('.wait')) inside.push([x, dy, n.className]); }
  return { rest: first - under, gap: r.top - under, scrolled: Math.round(w.scrollTop), inside }; })()"""


@pytest.mark.parametrize("size", SIZES)
def test_a_list_scrolled_to_its_end_is_cut_below_the_selected_tabs_underline_not_on_it(served, browser, monkeypatch, size):
    open_strip(browser, served, monkeypatch, size, waiting=waiting(30), onIt=hostile(30))
    if size[0] < 700:
        phone(browser, size[0])
    for tab, panel in ((MOVE_TAB, MOVE_PANEL), (ONIT_TAB, ONIT_PANEL)):
        click(browser, tab)
        browser.settle(PIN)
        got = browser.evaluate(CUT.replace("__PANEL__", panel))
        assert got["scrolled"] > 0 and got["gap"] >= 3.5 and got["inside"] == [], (panel, got)
        assert 3.5 <= got["rest"] <= 6.5, (panel, "at rest the list starts about where it did", got)
