"""The New session form is a page, not a pop-up. The route and the history (open from the button, Back, reload on the link) are in
test_new_session.py beside the form's other checks; this file holds what makes it a page rather than a sheet.

What a wrong answer costs: a project description cut to "…" so the owner cannot tell two projects apart before he picks one
(the reason for the page), an ordinary create that needs the page scrolled so the Create button or the Open link is out of
sight, a pop-up left behind in the code that a later change opens again, and a page that breaks the sidebar beside it. Every
check guards one of those. A headless Chromium against the same stand-ins as the form's other tests (conftest.py: `served`,
`browser`; fake_stackshot.py)."""

from __future__ import annotations

import json
import re

import fake_stackshot as FS
from test_board_items_ui import wait_for
from test_new_session import APP_JS, INDEX, STATIC, click, ns, open_form, pick, set_value, wait_state
from test_new_session import sala  # noqa: F401  (fixture)

LONG = ("Repaint the garden shed: the colour samples, the primer, the brush list, the weekend plan "
        "and the tool shelf layout")                                                  # under 120 characters; stackshot's title limit is 120
assert len(LONG) <= 120
CSS = (STATIC / "style.css").read_text()

DESCRIPTIONS = """(() => [...document.querySelectorAll('#ns-projects .ns-title')].map((t) => {
  const cs = getComputedStyle(t), r = t.getBoundingClientRect(), row = t.closest('.ns-opt').getBoundingClientRect();
  return { text: t.textContent, whiteSpace: cs.whiteSpace, textOverflow: cs.textOverflow, overflow: cs.overflow, lineClamp: cs.webkitLineClamp || cs.lineClamp || "none",
           maxHeight: cs.maxHeight, scrollH: t.scrollHeight, clientH: t.clientHeight, scrollW: t.scrollWidth, clientW: t.clientWidth, h: r.height,
           line: parseFloat(cs.lineHeight), inRow: r.top >= row.top - 1 && r.bottom <= row.bottom + 1 && r.right <= row.right + 1 };
}))()"""

FIT = """(() => { const f = document.querySelector('#ns-form'), s = document.querySelector('#ns-submit').getBoundingClientRect(),
  link = document.querySelector('#ns-status a.ns-link'), st = document.querySelector('#ns-status').getBoundingClientRect(), vh = document.documentElement.clientHeight;
  return { formScrollH: f.scrollHeight, formClientH: f.clientHeight, docScrollH: document.documentElement.scrollHeight, docClientH: vh,
           bodyScrollH: document.body.scrollHeight, submitBottom: s.bottom, statusBottom: st.height ? st.bottom : 0, linkBottom: link ? link.getBoundingClientRect().bottom : 0, vh }; })()"""


def fits(browser, where: str) -> dict:
    """Nothing to scroll: the form, the document and the body hold everything, and Create (and the steps, once there are any) are on the screen."""
    g = browser.evaluate(FIT)
    assert g["formScrollH"] <= g["formClientH"] and g["docScrollH"] <= g["docClientH"] and g["bodyScrollH"] <= g["docClientH"], (where, g)
    assert g["submitBottom"] <= g["vh"] and g["statusBottom"] <= g["vh"] and g["linkBottom"] <= g["vh"], (where, g)
    return g


def in_view(browser, where: str) -> dict:
    """Once the steps are on the page the form may be taller than the screen (one column), but its foot (Create, the steps, the Open
    button) is pinned to the bottom edge, so all of it is on the screen at once and the document itself never scrolls."""
    g = browser.evaluate(FIT)
    assert g["docScrollH"] <= g["docClientH"] and g["bodyScrollH"] <= g["docClientH"], (where, g)
    assert 0 < g["submitBottom"] <= g["vh"] and g["statusBottom"] <= g["vh"] and g["linkBottom"] <= g["vh"], (where, g)
    top = browser.evaluate("document.querySelector('#ns-submit').getBoundingClientRect().top - document.querySelector('#ns-form').getBoundingClientRect().top")
    assert top >= 0, (where, top)                                                       # not scrolled up out of the form's own box
    return g


def test_a_description_is_shown_whole_never_clamped_or_cut(sala, served, browser):
    sala.ss.rows.append(FS.row("projects/gamma-kiln", LONG, "gamma", agents={"gamma-kiln-main": FS.agent()}))
    for width, height in ((1280, 800), (390, 844)):
        open_form(browser, served, width=width, height=height, scope="gamma")
        rows = browser.evaluate(DESCRIPTIONS)
        long = next(r for r in rows if r["text"] == LONG)             # all of it is in the page's text
        assert long["whiteSpace"] in ("normal", "pre-wrap", "break-spaces") and long["textOverflow"] == "clip", (width, long)
        assert long["lineClamp"] in ("none", "") and long["maxHeight"] == "none" and long["overflow"] == "visible", (width, long)
        assert long["scrollH"] <= long["clientH"] + 1 and long["scrollW"] <= long["clientW"] + 1, (width, long)   # nothing is hidden inside the box
        assert long["h"] >= 1.9 * long["line"] and long["inRow"], (width, long)                                     # it wraps onto more than one line, inside its row
        assert all(r["scrollH"] <= r["clientH"] + 1 and r["scrollW"] <= r["clientW"] + 1 and r["inRow"] and r["textOverflow"] == "clip" for r in rows), (width, rows)
    # the same under "all", where the rows of every scope stand together
    click(browser, "#ns-scopes .ns-chip[data-scope=all]")
    assert wait_for(browser, "document.querySelector('#ns-projects').getAttribute('aria-busy') === 'false'", 10.0)
    assert any(r["text"] == LONG for r in browser.evaluate(DESCRIPTIONS))


def test_an_ordinary_create_needs_no_scrolling_on_a_desktop(sala, served, browser):
    # a long description and a scope with many projects: the list scrolls inside its box when it must, the page never does
    sala.ss.rows.append(FS.row("projects/gamma-kiln", LONG, "gamma", agents={"gamma-kiln-main": FS.agent()}))
    for i in range(14):
        sala.ss.rows.append(FS.row(f"projects/gamma-extra-{i:02d}", f"Extra project number {i:02d} with a title of some length to wrap", "gamma"))
    open_form(browser, served, width=1280, height=800, scope="gamma")
    fits(browser, "opened")
    assert browser.evaluate("document.querySelectorAll('#ns-projects .ns-opt').length") >= 18
    pick(browser, "projects/gamma-harbor")
    assert wait_for(browser, "document.querySelector('#ns-name').value === 'gamma-harbor-pink'"), ns(browser)
    fits(browser, "picked")
    set_value(browser, "#ns-name", "gamma-harbor-main")
    fits(browser, "named")
    click(browser, "#ns-submit")
    wait_state(browser, "queued")
    in_view(browser, "queued")                                                           # the steps are on the page
    sala.marker("running")
    wait_state(browser, "starting")
    in_view(browser, "starting")
    browser.evaluate("window.__names = ['gamma-harbor-main']; ''")
    g = wait_state(browser, "ready")
    assert g["link"] == "#s=gamma-harbor-main", g
    f = in_view(browser, "ready")
    assert f["linkBottom"] > 0                                                           # the Open button is on the page
    # the lane fold open: Create and the steps stay on the screen, the fields scroll under them
    browser.evaluate("document.querySelector('#ns-form details').open = true; ''")
    in_view(browser, "details open")
    # one column: the project list, then the name under it
    cols = browser.evaluate("(() => { const a = document.querySelector('#ns-summary').getBoundingClientRect(), b = document.querySelector('#ns-name').getBoundingClientRect(); return { a: a.bottom, b: b.top, al: a.left, bl: b.left }; })()")
    assert cols["a"] <= cols["b"] and cols["al"] == cols["bl"], cols


def test_a_new_project_create_with_all_three_steps_and_the_open_button_fits_too(sala, served, browser):
    open_form(browser, served, width=1280, height=800, scope="beta")
    set_value(browser, "#ns-filter", "Fresh Idea")
    assert wait_for(browser, "document.querySelector('#ns-projects .ns-opt[data-key=\"__new__\"]:not([disabled])') !== null", 10.0), ns(browser)
    pick(browser, "__new__")
    assert wait_for(browser, "document.querySelector('#ns-name').value === 'beta-fresh-idea-main'"), ns(browser)
    set_value(browser, "#ns-mandate", "# Fresh idea\nWork out whether the idea holds.")
    in_view(browser, "typed")                      # the new project's note (what Create will make) is two lines: the fields may scroll under the pinned foot, Create is in view
    click(browser, "#ns-submit")
    g = wait_state(browser, "queued", 30.0)
    assert len(g["steps"]) == 3, g
    in_view(browser, "queued, three steps")
    browser.evaluate("window.__names = ['beta-fresh-idea-main']; ''")
    sala.marker("running")
    g = wait_state(browser, "ready", 30.0)
    assert g["link"] == "#s=beta-fresh-idea-main" and len(g["steps"]) == 3, g
    assert in_view(browser, "ready, three steps and the Open button")["linkBottom"] > 0


def test_a_phone_has_one_column_and_scrolls(sala, served, browser):
    sala.ss.rows.append(FS.row("projects/gamma-kiln", LONG, "gamma", agents={"gamma-kiln-main": FS.agent()}))
    open_form(browser, served, width=390, height=844, scope="gamma")
    g = browser.evaluate(FIT)
    assert g["formScrollH"] > g["formClientH"], g                                        # the page scrolls (inside the form), the document does not
    assert g["docScrollH"] <= g["docClientH"], g
    cols = browser.evaluate("(() => { const a = document.querySelector('#ns-projects').getBoundingClientRect(), b = document.querySelector('#ns-name').getBoundingClientRect(); return { a: a.bottom, b: b.top, w: a.width }; })()")
    assert cols["a"] <= cols["b"] and cols["w"] >= 300, cols                             # the name is under the list, not beside it
    assert browser.evaluate("document.documentElement.scrollWidth") <= 390


def test_the_sidebar_stays_usable_beside_the_page_and_a_session_row_leaves_it(sala, served, browser):
    open_form(browser, served, width=1280, height=800, scope="gamma")
    assert browser.evaluate("document.querySelector('#side-new').classList.contains('selected')")
    assert not browser.evaluate("document.querySelector('#side-ovw').classList.contains('selected')")
    assert browser.evaluate("document.querySelectorAll('#session-list .sess').length") >= 1
    click(browser, "#session-list .sess")
    assert wait_for(browser, "!document.body.classList.contains('new-open') && state.selected !== null && !nav.busy", 5.0), ns(browser)
    assert not browser.evaluate("document.querySelector('#side-new').classList.contains('selected')")
    # the form keeps what was typed while another view is up
    click(browser, "#side-new")
    assert wait_for(browser, "document.body.classList.contains('new-open') && !nav.busy", 5.0)
    assert ns(browser)["hash"] == "#new"


def test_nothing_of_the_pop_up_is_left_and_the_page_is_routed_like_a_view():
    for gone in ("new-sheet", "new-scrim", "nsOpen", "nsClose", "placePopover(nsEl", 'defineLayer("new"'):
        assert gone not in APP_JS and gone not in INDEX, gone
    assert ".new-sheet" not in CSS and "aria-expanded" not in re.search(r'<a id="side-new"[^>]*>', INDEX).group(0)
    assert 'const newHash = (h = location.hash) => h === "#new";' in APP_JS
    assert 'a.hash === "#new"' in APP_JS                                                # a plain click on the link is sala's (go)
    assert "body.new-open #new-pane { display: flex; flex-direction: column; }" in CSS
    # the popover helper was the items sheet's alone and went with it
    assert "function placePopover(" not in APP_JS and "placeSheet" not in APP_JS
    assert json.loads(json.dumps(LONG)) == LONG
