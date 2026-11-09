"""The board items on the page: what is NOT drawn from them, and what still reads them (changed Thu Nov 5th 2026).

The page used to show a session's open board items in three places: an item count button in the session's title bar, the
items sheet that button opened, and a red count on the Agents table's Session cell that opened the same sheet. All three were
removed, because open items are read on the board, not on this page. What is held here: the page's markup, script and stylesheets
carry no trace of them; with a board that answers items for the open session, the title bar has no such button, the page
has no sheet and no scrim, the Agents table has no count; the sidebar rows still carry no board count (the
unread reply count is there); and the one reader of the data that stays, the New session page's board item picker, still lists the
items of the live sessions. The page still asks for the board once a minute (the picker's data). The server side
(api/board-items, board.py) is untouched: test_board_items.py.

This module is also the shared harness of the browser tests: `stub` (api/sessions, api/overview and api/board-items as fixed
answers installed before the page loads), `open_page`, `wait_for`, `wait_side`, `CONTRAST`, and the fake sessions. Runs in a
headless Chromium when one is installed (conftest.py: `served`, `browser`), else skipped."""

from __future__ import annotations

import json
import os
import re
import time

import pytest

from sala_web.app import STATIC
from test_composer_attach import WAIT_READY
from test_overview_columns import row

INDEX = (STATIC / "index.html").read_text()
WEB = "https://board.example.test"
FAKE = "pytest-fake"   # conftest's live session (its pid is this process): the one the tests open

NAMES = [FAKE, "demo", "gamma-quiet", "gamma-held", "gamma-many"]


def sess(name, pid):
    return {"pid": pid, "sessionId": name, "name": name, "cwd": "/x", "status": "idle", "tmux": "x:@0.%0", "tmuxSession": name,
            "paneId": "%0", "role": "front", "project": "projects/demo", "lane": "subscription-1", "updatedAt": None, "startedAt": None}


def it(shown, subject, needs=(), held=False, state=None):
    """An item as the server passes it through. `state` is stackshot's per-row state; unless given, a decision is
    your-call, a held item parked, an external one outside and the rest doing."""
    low = [n.lower() for n in needs]
    if state is None:
        state = "parked" if held else "your-call" if "decision" in low else "outside" if "external" in low else "doing"
    return {"id": shown, "subject": subject, "needs": list(needs), "waiting": "decision" in low and not held,
            "held": held, "url": f"{WEB}/items/{shown.split('#')[-1]}", "state": state}


BOARD = {
    FAKE: {"items": [it("board#21", "[gamma] decide the sheet", ["decision"]), it("board#25", "[gamma] board items in sala", ["demo", FAKE]),
                     it("board#18", "[gamma] parked question", ["decision"], held=True)], "waiting": 1},
    "demo": {"items": [], "waiting": 0},
    "gamma-quiet": {"items": [it("board#10", "[gamma] one", ["external"]), it("board#11", "[gamma] two")], "waiting": 0},
    "gamma-held": {"items": [it("board#20", "[gamma] on hold only", held=True)], "waiting": 0},
    "gamma-many": {"items": [it(f"board#{300 + i}", f"[gamma] item {i} " + "with a long subject that wraps on a phone " * 2) for i in range(40)], "waiting": 0},
}
OVERVIEW_ROWS = [row(n, "claude-opus-5-5", "high") for n in NAMES]


def stub(sessions_pids: dict, board: dict, gated: bool = False) -> str:
    """fetch stubs for api/sessions (one scope, one project, these sessions), api/overview (the same as rows) and
    api/board-items (`board`; with gated, answered only once window.__releaseBoard() is called; failing while
    window.__boardFail is set); counts the board requests in window.__boardCalls."""
    sessions = {"scopes": [{"key": "example", "title": "example", "groups": [{"key": "projects/demo", "title": "demo", "scope": "example",
                                                                            "sessions": [sess(n, p) for n, p in sessions_pids.items()]}]}],
                "rolesError": None}
    sessions["groups"] = sessions["scopes"][0]["groups"]
    return """(() => {
  const real = window.fetch.bind(window), json = (o) => new Response(JSON.stringify(o), { headers: { "Content-Type": "application/json" } });
  window.__boardCalls = 0; window.__boardFail = false;
  let release = null; const gate = new Promise((r) => { release = r; }); window.__releaseBoard = () => release();
  window.fetch = (url, opts) => {
    const u = String(url);
    if (u.startsWith("api/sessions")) return Promise.resolve(json(%s));
    if (u.startsWith("api/overview")) return Promise.resolve(json({ sessions: %s, rolesError: null }));
    if (u.startsWith("api/board-items")) {
      window.__boardCalls++;
      if (window.__boardFail) return Promise.resolve(new Response("", { status: 503 }));
      const body = json({ sessions: %s, fetchedAt: Date.now() });
      return %s ? gate.then(() => body) : Promise.resolve(body);
    }
    return real(url, opts);
  };
})();""" % (json.dumps(sessions), json.dumps(OVERVIEW_ROWS), json.dumps(board), "true" if gated else "false")


PIDS = {FAKE: os.getpid(), **{n: 1 for n in NAMES if n != FAKE}}

# the board has landed when the page's own record of it holds the sessions' items (the one reader left is the New session picker)
WAIT_BOARD = """
new Promise((res) => { const t0 = Date.now(); (function poll() {
  const ok = typeof board !== "undefined" && board.loaded && Object.keys(board.sessions).length > 0;
  if (ok || Date.now() - t0 > 15000) res(!!ok); else setTimeout(poll, 100);
})(); })"""
# WCAG 2 contrast of an element's text on its own (opaque) background, as the browser computed both
CONTRAST = r"""((sel) => {
  const parse = (s) => { let m = /^rgba?\(([\d.]+),\s*([\d.]+),\s*([\d.]+)(?:,\s*([\d.]+))?\)$/.exec(s);
    if (m) return { c: [+m[1] / 255, +m[2] / 255, +m[3] / 255], a: m[4] === undefined ? 1 : +m[4] };
    m = /^color\(srgb ([\d.e-]+) ([\d.e-]+) ([\d.e-]+)(?: \/ ([\d.]+))?\)$/.exec(s);
    if (m) return { c: [+m[1], +m[2], +m[3]], a: m[4] === undefined ? 1 : +m[4] };
    throw new Error("colour " + s); };
  const lum = ({ c }) => c.map((x) => (x <= 0.04045 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4))
    .reduce((s, x, i) => s + x * [0.2126, 0.7152, 0.0722][i], 0);
  return [...document.querySelectorAll(sel)].map((t) => {
    const cs = getComputedStyle(t), fg = parse(cs.color), bg = parse(cs.backgroundColor);
    const [hi, lo] = [lum(fg), lum(bg)].sort((a, b) => b - a);
    return { cls: t.className, text: t.textContent.slice(0, 30), fgAlpha: fg.a, bgAlpha: bg.a, ratio: (hi + 0.05) / (lo + 0.05), size: parseFloat(cs.fontSize), bg: cs.backgroundColor };
  });
})"""


def wait_for(browser, expr, timeout=15.0):
    end = time.time() + timeout
    while time.time() < end:
        if browser.evaluate(expr):
            return True
        time.sleep(0.1)
    return False


def wait_side(browser) -> None:
    """The phone sidebar slides in over .18 s (style.css): measure it only once it is in place."""
    assert wait_for(browser, "document.getElementById('sidebar').getBoundingClientRect().left === 0", 5.0)


def open_page(browser, served, hash_: str, board=BOARD, gated=False, dark=True, width=390, height=844):
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": stub(PIDS, board, gated)})
    browser.width, browser.height = width, height
    browser.open(f"{served['url']}/{hash_}", dark=dark)


def click(browser, sel: str) -> None:
    browser.evaluate(f"document.querySelector({json.dumps(sel)}).click(); ''")


# ── the sources: nothing of the button, the sheet or the count is left ────────────────────────────────────────────────
GONE_MARKUP = ["board-chip", "board-sheet", "board-scrim", "bchip", "bs-list", "bs-item", "bs-group"]
GONE_CSS = [r"\.bchip", r"\.board-sheet", r"\.board-scrim", r"\.bs-[a-z]+", r"\.btag", r"\.sp-wait", r"\.fy-[a-z]+", "hover-board-sheet"]
GONE_JS = ["board-chip", "board-sheet", "board-scrim", "fillBoardChip", "updateBoardChip", "openSheet", "closeSheet", "showSheet", "hideSheet",
           "renderSheet", "sheetItem", "waitMark", "sp-wait", "yourMoveCount", "boardLists", "boardListOf", "BOARD_LISTS", "setBoard",
           "FOR_YOU_HIDDEN", "loadForYou", "renderForYou", "BOARD_ICON", "boardHover"]


def sources() -> dict:
    """Every file the page loads that could carry the removed pieces, as text."""
    names = ["index.html", "app.js", "sessions.js", "shared.js", "style.css", "sessions.css", "search.css", "machines.css", "schedules.css", "termclip.css"]
    return {n: (STATIC / n).read_text(encoding="utf-8") for n in names}   # index.html carries the look's inline <style>


def test_the_sources_carry_no_item_count_button_sheet_or_count():
    src = sources()
    for name, text in src.items():
        if name.endswith("html"):
            assert not [w for w in GONE_MARKUP if w in text], (name, [w for w in GONE_MARKUP if w in text])
            t = text[text.index('id="title"'):text.index('id="top-tools"')]
            assert not re.search(r"<button[^>]*class=\"bchip", t)
            assert 'aria-controls="board-sheet"' not in text
        elif name.endswith("css"):
            assert not [w for w in GONE_CSS if re.search(w, text)], (name, [w for w in GONE_CSS if re.search(w, text)])
        else:
            assert not [w for w in GONE_JS if w in text], (name, [w for w in GONE_JS if w in text])
    # the title bar's cluster is the status badge, Reload, the ⋯ button, the Shell button: no button between the name and the badge
    t = INDEX[INDEX.index('id="title"'):INDEX.index('id="top-tools"')]
    assert t.index('class="name"') < t.index('id="top-status"') < t.index('id="menu-reload"')
    # the Agents table's Session cell is the session's link alone
    js = (STATIC / "sessions.js").read_text(encoding="utf-8")
    assert "tr.append(\n    td(link)," in js
    # the stylesheet keeps the unread count's rule: it is the sidebar row's count, which stays
    assert re.search(r"\.ucount \{[^}]*flex: none;", (STATIC / "style.css").read_text(encoding="utf-8"))


def test_the_one_reader_that_stays_is_still_in_the_script():
    js = (STATIC / "app.js").read_text(encoding="utf-8")
    assert 'fetch("api/board-items"' in js and "async function loadBoard()" in js
    assert "function sdItemRows()" in js and "board.sessions" in js and "rows: sdItemRows" in js
    assert "setInterval(() => { if (!document.hidden) loadBoard(); }, BOARD_MS);" in js and "const BOARD_MS = 60000;" in js


# ── the page ──────────────────────────────────────────────────────────────────────────────────────────────────────────
TITLE_BAR = """(() => {
  const q = (s) => document.querySelector(s);
  return { children: [...q("#top-end").children].map((e) => e.id || e.className).filter(Boolean),
           chip: !!q("#board-chip") || !!q(".bchip"), sheet: !!q("#board-sheet") || !!q(".board-sheet"), scrim: !!q("#board-scrim") || !!q(".board-scrim"),
           ariaControls: !!q("[aria-controls='board-sheet']"), sheetInTree: document.body.innerHTML.includes("board-sheet"),
           name: q("#title .name").textContent, boardItems: Object.values(board.sessions).reduce((n, b) => n + b.items.length, 0) };
})()"""
AGENTS = """(() => ({
  names: [...document.querySelectorAll("#sp-table tbody tr td:first-child a")].map((a) => a.textContent),
  counts: document.querySelectorAll("#sp-table .sp-wait").length,
  firstCells: [...document.querySelectorAll("#sp-table tbody tr td:first-child")].map((c) => c.children.length),
  sheet: !!document.getElementById("board-sheet"), docScroll: document.documentElement.scrollWidth, vw: innerWidth }))()"""


def test_a_session_with_open_items_has_no_button_in_the_title_bar_and_the_agents_table_has_no_count(served, browser):
    # the board answers items for the open session (three, one of them waiting on the owner): the page holds them, and draws none of them
    open_page(browser, served, f"#s={FAKE}", width=1280, height=800)
    assert browser.evaluate(WAIT_READY)
    assert browser.evaluate(WAIT_BOARD)
    time.sleep(0.5)   # a late repaint would still draw one
    t = browser.evaluate(TITLE_BAR)
    assert t["boardItems"] >= 3 and t["name"] == FAKE, t
    assert not (t["chip"] or t["sheet"] or t["scrim"] or t["ariaControls"] or t["sheetInTree"]), t
    assert not any(c in t["children"] for c in ("board-chip", "bchip")), t["children"]
    # a phone's width as well: the one cluster is the same
    browser.send("Emulation.setDeviceMetricsOverride", {"width": 390, "height": 844, "deviceScaleFactor": 1, "mobile": True})
    t = browser.evaluate(TITLE_BAR)
    assert not (t["chip"] or t["sheet"] or t["scrim"]), t
    # the Agents table: every session is there (FAKE has an item in Your move), none has a count, the cell is the link alone
    browser.evaluate("location.hash = '#sessions'; ''")
    assert wait_for(browser, "document.querySelectorAll('#sp-table tbody tr td:first-child a').length === %d" % len(NAMES))
    a = browser.evaluate(AGENTS)
    assert sorted(a["names"]) == sorted(NAMES), a
    assert a["counts"] == 0 and set(a["firstCells"]) == {1} and not a["sheet"], a
    assert a["docScroll"] <= a["vw"], a


def test_the_sidebar_rows_carry_no_board_count(served, browser):
    """the board count left the sidebar rows earlier (the unread reply count took the row's right end); it is on no row now."""
    open_page(browser, served, f"#s={FAKE}")
    assert browser.evaluate(WAIT_BOARD)
    click(browser, "#side-open")
    wait_side(browser)
    assert browser.evaluate("document.querySelectorAll('#session-list .sess').length") == len(NAMES)
    assert browser.evaluate("document.querySelectorAll('#session-list .bmark').length") == 0
    assert not re.search(r"\.bmark\b|boardMark", (STATIC / "style.css").read_text() + (STATIC / "app.js").read_text())


def test_the_new_session_picker_still_gets_the_items_of_the_live_sessions(served, browser):
    # the Quick session form's board item picker reads the same data (board.sessions, from api/board-items), newest number first
    open_page(browser, served, "#side=", width=1280, height=800)
    assert browser.evaluate(WAIT_BOARD)
    assert wait_for(browser, "document.body.classList.contains('side-mode')")
    keys = browser.evaluate("sdItemRows().map((r) => r.key)")
    want = sorted({i["id"] for b in BOARD.values() for i in b["items"]}, key=lambda k: -int(k.split("#")[1]))
    assert keys == want and "board#21" in keys and len(keys) == 3 + 2 + 1 + 40, keys
    assert "[gamma] decide the sheet" in browser.evaluate("sdItemRows().find((r) => r.key === 'board#21').desc")
    click(browser, "#sd-item-pick .ns-sum")
    assert wait_for(browser, "!document.querySelector('#sd-item-pick .ns-panel').hidden", 5.0)
    shown = browser.evaluate("[...document.querySelectorAll('#sd-item-pick .ns-list .ns-opt')].map((b) => b.dataset.key)")
    assert shown and set(shown) <= set(want) and "board#21" in shown, shown


INTERVALS = """(() => {
window.__iv = new Map();
const realSet = window.setInterval, realClear = window.clearInterval;
window.setInterval = (fn, ms, ...a) => { const id = realSet(fn, ms, ...a); window.__iv.set(id, { fn, ms }); return id; };
window.clearInterval = (id) => { window.__iv.delete(id); return realClear(id); };
window.__advance = (ms) => { for (const { fn, ms: every } of [...window.__iv.values()]) for (let i = 0; i < Math.floor(ms / every); i++) fn(); };
})();"""


def test_the_page_asks_for_the_board_once_a_minute(served, browser):
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": INTERVALS})
    open_page(browser, served, f"#s={FAKE}")
    assert browser.evaluate(WAIT_READY)
    assert browser.evaluate(WAIT_BOARD)
    time.sleep(0.5)
    assert browser.evaluate("window.__boardCalls") == 1   # once, with the page's load
    browser.evaluate("window.__advance(60000 - 1); ''")
    time.sleep(0.3)
    assert browser.evaluate("window.__boardCalls") == 1
    browser.evaluate("window.__advance(60000); ''")
    time.sleep(0.3)
    assert browser.evaluate("window.__boardCalls") == 2   # the next minute: one
    assert browser.evaluate("[...window.__iv.values()].some((v) => v.ms === 60000)")
    # a failed poll changes nothing the page holds, and shows no error on the page
    before = browser.evaluate("JSON.stringify(board.sessions)")
    browser.evaluate("window.__boardFail = true; ''")
    browser.evaluate("loadBoard()")
    assert browser.evaluate("JSON.stringify(board.sessions)") == before
    assert browser.evaluate("document.body.textContent").count("503") == 0
