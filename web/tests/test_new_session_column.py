"""The New session page is ONE centered column, and its project list is a box of six rows that scrolls inside itself and can be
dragged taller.

What a wrong answer costs: two columns come back and the name, mandate and Create sit far from the project that was picked; a
column wider than a screen reading line, or one pinned to the left edge; a list so tall that Create falls off the screen, or so
short that the projects cannot be told apart; a drag handle that is not there (or sits under the scrollbar, where it cannot be
grabbed); a remembered height that a stray value in the browser's storage turns into a zero-height list, or a browser that
refuses its storage taking the whole page down with it; and a project description cut or hidden by the wider rows (that one is
in test_new_session_page.py). A headless Chromium against the same stand-ins as the form's other tests (conftest.py: `served`,
`browser`; fake_stackshot.py)."""

from __future__ import annotations

import json

import fake_stackshot as FS
from test_board_items_ui import wait_for
from test_new_session import click, ns, open_form, pick, set_value, wait_state
from test_new_session import sala  # noqa: F401  (fixture)

KEY = "sala.ns.list-h"
ROW = 40                                                                                # a row's height; six of them, the list's padding and its border
DEFAULT = 6 * ROW + 8 + 2

LIST = """(() => { const l = document.querySelector('#ns-projects'), cs = getComputedStyle(l), r = l.getBoundingClientRect(),
  rows = [...l.querySelectorAll('.ns-opt')];
  return { h: r.height, w: r.width, left: r.left, right: r.right, bottom: r.bottom, resize: cs.resize, overflowY: cs.overflowY, minH: parseFloat(cs.minHeight),
           maxH: cs.maxHeight, scrollH: l.scrollHeight, clientH: l.clientHeight, rows: rows.length, stored: (() => { try { return localStorage.getItem('sala.ns.list-h'); } catch (e) { return 'throws'; } })(),
           inline: l.style.height, vh: innerHeight }; })()"""

COLUMN = """(() => { const rect = (s) => { const r = document.querySelector(s).getBoundingClientRect(); return { left: r.left, right: r.right, width: r.width }; };
  return { pane: rect('#new-pane'), scopes: rect('#ns-scopes'), filter: rect('#ns-filter'), list: rect('#ns-projects'), role: rect('.ns-role'), name: rect('#ns-name'),
           mandate: rect('#ns-mandate'), submit: rect('#ns-submit'), more: rect('.ns-more'), docW: document.documentElement.scrollWidth, vw: document.documentElement.clientWidth }; })()"""


def many(sala, n: int = 14) -> None:
    for i in range(n):
        sala.ss.rows.append(FS.row(f"projects/gamma-extra-{i:02d}", f"Extra project number {i:02d} with a title of some length to wrap", "gamma"))


def stored(browser, value) -> None:
    """A value in the browser's storage before the page loads (the next navigation); None leaves it alone."""
    src = f"try {{ localStorage.setItem({json.dumps(KEY)}, {json.dumps(value)}); }} catch (e) {{}}"
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": src})


def refuse_storage(browser) -> None:
    """A browser that throws on every storage call (a private window, blocked site data)."""
    src = ("for (const m of ['getItem', 'setItem', 'removeItem', 'clear']) Storage.prototype[m] = function () { throw new DOMException('blocked', 'SecurityError'); };"
           " Object.defineProperty(window, 'localStorage', { get() { throw new DOMException('blocked', 'SecurityError'); } });")
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": src})


def drag_corner(browser, dy: int) -> None:
    """The list's lower right corner pulled by `dy` pixels with the mouse: the browser's own resize handle, a real press, move and release."""
    browser.send("Emulation.setDeviceMetricsOverride", {"width": browser.width, "height": browser.height, "deviceScaleFactor": 1, "mobile": False})
    browser.evaluate("document.querySelector('#ns-projects').scrollIntoView({block: 'nearest'}); new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))")
    g = browser.evaluate(LIST)
    x, y = g["right"] - 5, g["bottom"] - 5
    ev = {"x": x, "y": y, "button": "left", "clickCount": 1, "pointerType": "mouse"}
    browser.send("Input.dispatchMouseEvent", {**ev, "type": "mouseMoved", "button": "none", "clickCount": 0})
    browser.send("Input.dispatchMouseEvent", {**ev, "type": "mousePressed"})
    for step in range(1, 6):
        browser.send("Input.dispatchMouseEvent", {**ev, "type": "mouseMoved", "y": y + dy * step / 5, "button": "left", "buttons": 1, "clickCount": 0})
    browser.send("Input.dispatchMouseEvent", {**ev, "type": "mouseReleased", "y": y + dy})


# ── the column ───────────────────────────────────────────────────────────────
def test_one_column_every_field_shares_one_left_edge_and_width_and_it_is_centered(sala, served, browser):
    many(sala)
    open_form(browser, served, width=1280, height=800, scope="gamma")
    c = browser.evaluate(COLUMN)
    fields = [c[k] for k in ("scopes", "filter", "list", "role", "name", "mandate", "more")]
    # the project step and the rest are one stack: the same left edge and the same width, the scope chips (which are as wide as they
    # are) starting on it too
    for key in ("filter", "list", "role", "name", "mandate", "more"):
        assert abs(c[key]["left"] - c["list"]["left"]) <= 1 and abs(c[key]["width"] - c["list"]["width"]) <= 1, (key, c)
    assert c["submit"]["left"] == c["list"]["left"], c
    assert 600 <= c["list"]["width"] <= 760 + 1, c                                      # about 760 px, never the two-column halves nor the whole screen
    # centered in the main area (the pane), with the same room on both sides
    left, right = c["list"]["left"] - c["pane"]["left"], c["pane"]["right"] - c["list"]["right"]
    assert abs(left - right) <= 2 and left > 100, (left, right, c)
    assert c["docW"] <= c["vw"] and all(f["right"] <= c["pane"]["right"] for f in fields), c
    # nothing sits beside the list: the name is under it, and the order is scope, project, role, name, mandate, Create
    tops = browser.evaluate("['#ns-scopes', '#ns-filter', '#ns-projects', '.ns-role', '#ns-name', '#ns-mandate', '.ns-more', '#ns-submit'].map((s) => document.querySelector(s).getBoundingClientRect().top)")
    assert tops == sorted(tops) and len(set(round(t) for t in tops[1:])) == len(tops) - 1, tops


def test_the_column_is_as_wide_as_a_big_screen_allows_and_fills_a_phone_with_side_padding(sala, served, browser):
    open_form(browser, served, width=1920, height=1080, scope="gamma")
    c = browser.evaluate(COLUMN)
    assert 700 <= c["list"]["width"] <= 761 and abs((c["list"]["left"] - c["pane"]["left"]) - (c["pane"]["right"] - c["list"]["right"])) <= 2, c
    open_form(browser, served, width=390, height=844, scope="gamma")
    c = browser.evaluate(COLUMN)
    assert c["docW"] <= 390 and 16 <= c["list"]["left"] <= 24 and c["list"]["width"] >= 390 - 2 * 24, c            # the full width, a gutter each side
    assert c["name"]["left"] == c["list"]["left"] and c["mandate"]["width"] == c["list"]["width"] and c["submit"]["left"] == c["list"]["left"], c


# ── the list: six rows, its own scroll, a handle ─────────────────────────────
def test_the_list_is_six_rows_tall_and_scrolls_inside_itself_however_many_rows_there_are(sala, served, browser):
    many(sala)
    for width, height in ((1280, 800), (390, 844)):
        open_form(browser, served, width=width, height=height, scope="gamma")
        g = browser.evaluate(LIST)
        assert abs(g["h"] - DEFAULT) <= 2 and g["rows"] >= 16, (width, g)
        assert g["scrollH"] > g["clientH"] + 40 and g["overflowY"] == "auto", (width, g)                                 # more rows than fit: it scrolls, the page does not
        browser.evaluate("(() => { const l = document.querySelector('#ns-projects'); l.scrollTop = l.scrollHeight; })()")
        last = browser.evaluate("(() => { const l = document.querySelector('#ns-projects').getBoundingClientRect(), r = [...document.querySelectorAll('#ns-projects .ns-opt')].pop().getBoundingClientRect(); return { top: r.top, bottom: r.bottom, lb: l.bottom, lt: l.top }; })()")
        assert last["bottom"] <= last["lb"] + 1 and last["top"] >= last["lt"], (width, last)                                 # the last row scrolls fully into view, inside the box
        assert browser.evaluate(LIST)["h"] == g["h"], width                                                                  # scrolling never changes the box
    # a scope with few rows keeps the box (the same six rows of room), and the page still needs no scrolling at 1280 x 800
    open_form(browser, served, width=1280, height=800, scope="beta")
    assert abs(browser.evaluate(LIST)["h"] - DEFAULT) <= 2


def test_the_list_has_a_drag_handle_that_works_and_the_height_it_ends_on_is_kept(sala, served, browser):
    many(sala)
    open_form(browser, served, width=1280, height=800, scope="gamma")
    g = browser.evaluate(LIST)
    assert g["resize"] == "vertical" and g["overflowY"] == "auto" and g["minH"] == 130, g                              # three rows at least; the handle needs overflow
    assert g["stored"] is None and abs(g["h"] - DEFAULT) <= 2, g                                                         # nothing stored before a drag
    drag_corner(browser, 120)
    assert wait_for(browser, "Math.abs(document.querySelector('#ns-projects').getBoundingClientRect().height - 370) <= 6", 5.0), browser.evaluate(LIST)
    g = browser.evaluate(LIST)
    assert g["stored"] is not None and abs(int(g["stored"]) - g["h"]) <= 2, g                                           # saved when the drag ended
    assert g["scrollH"] > g["clientH"] and g["rows"] >= 16, g                                                            # the rows still scroll inside the taller box
    # dragged smaller than three rows: the box stops at three rows
    drag_corner(browser, -400)
    g = browser.evaluate(LIST)
    assert 128 <= g["h"] <= 132 and int(g["stored"]) >= 130, g
    # a click on a row is not a drag: nothing is saved by it
    browser.evaluate("localStorage.removeItem('sala.ns.list-h'); ''")
    click(browser, "#ns-projects .ns-opt")
    assert browser.evaluate(LIST)["stored"] is None


def test_the_handle_is_not_under_the_scrollbar_and_the_rows_leave_it_room(sala, served, browser):
    many(sala)
    open_form(browser, served, width=1280, height=800, scope="gamma")
    # the corner square (24 x 24) is the list's own: the element hit there is the list, not a row, so a press starts a resize
    hit = browser.evaluate("(() => { const r = document.querySelector('#ns-projects').getBoundingClientRect(); const e = document.elementFromPoint(r.right - 5, r.bottom - 5); return e && e.id; })()")
    assert hit == "ns-projects", hit
    # a visible hint says so on a desktop, none on a phone (where a drag on the corner is not a thing)
    assert browser.evaluate("getComputedStyle(document.querySelector('#ns-head .only-wide')).display") != "none"


def test_a_stored_height_is_applied_on_load_and_a_bad_one_is_ignored_or_cut_to_the_screen(sala, served, browser):
    many(sala)
    stored(browser, "400")
    open_form(browser, served, width=1280, height=800, scope="gamma")
    g = browser.evaluate(LIST)
    assert abs(g["h"] - 400) <= 2 and g["inline"] == "400px", g
    for bad in ("abc", "", "-300", "12.5e2", "50", "129", "0", "NaN", "Infinity", " 400", "400px"):
        browser.send("Page.navigate", {"url": "about:blank"})
        browser.evaluate("1")
        browser.send("Page.enable")
        src = f"try {{ localStorage.setItem({json.dumps(KEY)}, {json.dumps(bad)}); }} catch (e) {{}}"
        browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": src})
        open_form(browser, served, width=1280, height=800, scope="gamma")
        g = browser.evaluate(LIST)
        assert abs(g["h"] - DEFAULT) <= 2 and g["inline"] == "", (bad, g)                                                  # the default, as if nothing were stored
    # a height from a bigger screen is cut to this one: Create is still reachable, the list never fills the window
    browser.send("Page.navigate", {"url": "about:blank"})
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": f"try {{ localStorage.setItem({json.dumps(KEY)}, '5000'); }} catch (e) {{}}"})
    open_form(browser, served, width=1280, height=800, scope="gamma")
    g = browser.evaluate(LIST)
    assert 130 <= g["h"] <= 800 - 120 + 1, g
    top = browser.evaluate("document.querySelector('#ns-submit').getBoundingClientRect().bottom")
    assert top <= 800, top                                                                 # Create is still on the screen: the form scrolls, the foot is pinned


def test_a_browser_that_refuses_its_storage_still_has_the_whole_page(sala, served, browser):
    many(sala)
    refuse_storage(browser)
    open_form(browser, served, width=1280, height=800, scope="gamma")                        # the scope is read from storage too: the page opens anyway
    g = browser.evaluate(LIST)
    assert abs(g["h"] - DEFAULT) <= 2 and g["stored"] == "throws" and g["rows"] >= 16, g
    errors = browser.evaluate("window.__errs = []; addEventListener('error', (e) => window.__errs.push(String(e.message))); addEventListener('unhandledrejection', (e) => window.__errs.push(String(e.reason))); 0")
    drag_corner(browser, 100)                                                              # the drag works and saves nothing, quietly
    assert browser.evaluate(LIST)["h"] > DEFAULT + 60
    pick(browser, "projects/gamma-harbor")
    assert wait_for(browser, "document.querySelector('#ns-name').value === 'gamma-harbor-pink'", 10.0), ns(browser)
    set_value(browser, "#ns-name", "gamma-harbor-main")
    click(browser, "#ns-scopes .ns-chip[data-scope=example]")                                # a scope chip writes the remembered scope: it must not throw either
    assert wait_for(browser, "document.querySelector('#ns-projects').getAttribute('aria-busy') === 'false'", 10.0)
    assert browser.evaluate("window.__errs") == [], browser.evaluate("window.__errs")
    assert not ns(browser)["hidden"] and errors == 0


# ── no scrolling for an ordinary create, and a phone ─────────────────────────
def test_an_ordinary_create_at_1280_by_800_needs_no_page_scroll_with_the_default_list(sala, served, browser):
    many(sala)
    open_form(browser, served, width=1280, height=800, scope="gamma")
    pick(browser, "projects/gamma-harbor")
    assert wait_for(browser, "document.querySelector('#ns-name').value === 'gamma-harbor-pink'", 10.0), ns(browser)
    set_value(browser, "#ns-mandate", "Keep the harbor tidy.")
    g = browser.evaluate("(() => { const f = document.querySelector('#ns-form'), s = document.querySelector('#ns-submit').getBoundingClientRect(); return { sh: f.scrollHeight, ch: f.clientHeight, doc: document.documentElement.scrollHeight, vh: innerHeight, sb: s.bottom, st: f.scrollTop }; })()")
    assert g["sh"] <= g["ch"] and g["doc"] <= g["vh"] and g["sb"] <= g["vh"] and g["st"] == 0, g              # fields, Create: no scroll at all


def test_a_phone_gets_the_same_column_and_scrolls_to_reach_create(sala, served, browser):
    many(sala)
    open_form(browser, served, width=390, height=844, scope="gamma")
    g = browser.evaluate("(() => { const f = document.querySelector('#ns-form'); return { sh: f.scrollHeight, ch: f.clientHeight, sw: f.scrollWidth, cw: f.clientWidth, doc: document.documentElement.scrollWidth }; })()")
    assert g["sh"] > g["ch"] and g["sw"] <= g["cw"] and g["doc"] <= 390, g                                    # the list open: the page scrolls, sideways never
    pick(browser, "projects/gamma-harbor")                                                                      # the list folds to one line once a project is chosen
    assert wait_for(browser, "document.querySelector('#ns-name').value === 'gamma-harbor-pink'", 10.0), ns(browser)
    g = browser.evaluate("(() => { const f = document.querySelector('#ns-form'); return { sw: f.scrollWidth, cw: f.clientWidth, doc: document.documentElement.scrollWidth }; })()")
    assert g["sw"] <= g["cw"] and g["doc"] <= 390, g
    browser.evaluate("document.querySelector('#ns-submit').scrollIntoView({block: 'center'}); ''")
    assert browser.evaluate("(() => { const r = document.querySelector('#ns-submit').getBoundingClientRect(); return r.top >= 0 && r.bottom <= innerHeight; })()")
    click(browser, "#ns-submit")
    wait_state(browser, "queued")
    assert browser.evaluate("getComputedStyle(document.querySelector('.ns-foot')).position") == "static"            # no pinned foot on a phone
    browser.evaluate("document.querySelector('#ns-status').scrollIntoView({block: 'end'}); ''")
    assert browser.evaluate("document.querySelector('#ns-status').getBoundingClientRect().bottom <= innerHeight + 1")   # a pixel of slack: the scroll position is a whole pixel, the status's text lines are not
