"""The header gives the session name its space first; what does not fit beside it folds into the ⋯ menu (on a desktop window of
about 1000 px the name was cut off, the badges cut mid-pill and the view options whole).

Since the lighter view the bar holds the name, the status badge (working / needs input), Reload as an icon, the ⋯ button and the Shell
button (a board item count button sat before the badge until Thu Nov 5th 2026 and is gone, so the cluster has 43 px more room); the menu holds the Session section
(role, lane, tmux), the View section (Chat / Terminal, the thinking toggle) and what folded. The fold is measured, never a
breakpoint (app.js, "header: the name first"): at every width here, with a 60-character name and with a short one, the
name is never cut while anything else is still in the bar; nothing in the bar is clipped (every pill whole); what left
the bar is in the menu and nothing else, in the fold order (the Shell button first: on a 360 px phone the session name was cut by it;
then Reload, then the status badge); the tabs and the thinking
toggle are in the menu at every width and never in the bar,
so the ⋯ button is always there; the menu's items work from there and the page never scrolls
sideways. Runs in a headless Chromium when one is installed (conftest.py: `served`, `browser`), else skipped.
"""

from __future__ import annotations

import json

import pytest

from sala_web.app import STATIC
from test_composer_attach import WAIT_READY
from test_reload_menu import wait_fresh

INDEX = (STATIC / "index.html").read_text()
CSS = (STATIC / "style.css").read_text()
LONG = "gamma-harbor-crate-sorting-and-shelf-relabeling-mar-2031-rnn"
assert len(LONG) == 60
LONG_SESSION = {"name": LONG, "role": "front", "lane": "subscription-2", "status": "busy"}
SHORT_SESSION = {"name": "board-main", "role": "front", "lane": "subscription-2", "status": "busy"}
WIDTHS = (1600, 1280, 1000, 996, 900, 800, 762, 600, 390, 360, 320)   # 996: the header has the room the ~1000 px window had under a docked 280 px sidebar (the bar keeps 296 px at the left for the fixed toggle and header, 16 at the right: 996 - 296 - 16 = 684, what 762 px had beside the old in-bar toggle)
FOLD = ("shell", "reload", "status")  # the order in which items leave the bar (app.js FOLD); the tabs and the toggle are not in it: always in the menu
BAR_PILLS = ["working"]   # the status badge of LONG_SESSION and SHORT_SESSION, where it is in the bar
SESSION_PILLS = ["front", "subscription-2", "x"]   # the Session section's badges: role, lane (its label, no "lane:" in front of it), the tmux name
ALWAYS_IN_MENU = ("tools", "tabs", "session", "view")

MEASURE = r"""
(() => {
  const q = (s) => document.querySelector(s);
  const box = (e) => { const r = e.getBoundingClientRect(); return { l: r.left, r: r.right, t: r.top, b: r.bottom, w: r.width, h: r.height }; };
  const top = q("#top"), end = q("#top-end"), menu = q("#top-tools"), btn = q("#top-menu-btn"), name = q("#title .name");
  const els = { shell: q("#shell-btn"), reload: q("#menu-reload"), status: q("#top-status"), tools: q(".top-toggle"), tabs: q("#top .tabs"), session: q("#menu-session"), view: q("#menu-view") };
  const items = {};
  for (const [k, e] of Object.entries(els)) {
    const b = box(e);
    items[k] = { inBar: end.contains(e), inMenu: menu.contains(e), visible: !!(b.w && b.h), box: b };
  }
  const pills = [...document.querySelectorAll("#top .pill")].map((p) => ({ text: p.textContent, box: box(p), inBar: end.contains(p), inMenu: menu.contains(p) }));
  return { width: innerWidth, top: box(top), items, pills, folded: headerFolded,
           name: { text: name.textContent, box: box(name), cut: name.scrollWidth > name.clientWidth },
           btn: { visible: !!btn.getBoundingClientRect().width, hidden: btn.hidden, expanded: btn.getAttribute("aria-expanded"), box: box(btn) },
           menuOpen: document.body.classList.contains("top-menu-open"), menuShown: getComputedStyle(menu).display !== "none", menuBox: box(menu),
           docScroll: document.documentElement.scrollWidth, mainScroll: q("#main").scrollWidth, mainClient: q("#main").clientWidth };
})()
"""
STATE = """(() => ({ checked: document.querySelector("#show-tools").checked, hideTools: document.body.classList.contains("hide-tools"),
  tab: state.tab, terminal: document.querySelector("#terminal-pane").classList.contains("active"),
  activeTab: document.querySelector("#top .tab.active").dataset.tab, open: document.body.classList.contains("top-menu-open"),
  expanded: document.querySelector("#top-menu-btn").getAttribute("aria-expanded"), folded: headerFolded,
  pressed: [...document.querySelectorAll("#top .tab")].map((t) => t.dataset.tab + "=" + t.getAttribute("aria-pressed")) }))()"""


def inside(inner: dict, outer: dict, tol: float = 0.5) -> bool:
    return (inner["l"] >= outer["l"] - tol and inner["r"] <= outer["r"] + tol
            and inner["t"] >= outer["t"] - tol and inner["b"] <= outer["b"] + tol)


def set_width(browser, w: int) -> dict:
    browser.send("Emulation.setDeviceMetricsOverride", {"width": w, "height": 844, "deviceScaleFactor": 1, "mobile": w <= 760})
    browser.evaluate("new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))")  # the ResizeObserver has run
    got = browser.evaluate(MEASURE)
    assert got["width"] == w, got
    return got


def check(got: dict, badge: bool = True) -> list[str]:
    """The header's invariants at one width; returns the items in the menu (in fold order). `badge`: the session shows the status badge
    (it is working); an idle one has none, and the empty badge in the bar is not drawn."""
    w, items = got["width"], got["items"]
    in_bar = [k for k in FOLD if items[k]["inBar"]]
    in_menu = [k for k in FOLD if items[k]["inMenu"]]
    # the tabs, the thinking toggle and the Session section: in the menu at every width, never in the bar
    for k in ALWAYS_IN_MENU:
        assert items[k]["inMenu"] and not items[k]["inBar"], (w, k, items[k])
    # every foldable item is in the bar or in the menu, never both or neither; what left is a prefix of the fold order
    assert sorted(in_bar + in_menu) == sorted(FOLD) and not set(in_bar) & set(in_menu), (w, in_bar, in_menu)
    assert tuple(in_menu) == FOLD[:len(in_menu)] and got["folded"] == len(in_menu), (w, in_menu, got["folded"])
    # the name is whole while anything else is still in the bar, and always inside the header
    if in_bar:
        assert not got["name"]["cut"], (w, in_bar, got["name"])
    assert got["name"]["box"]["w"] > 0 and inside(got["name"]["box"], got["top"]), (w, got["name"], got["top"])
    # nothing in the bar is clipped: each item inside the header, after the name; every pill whole inside the badge's box
    for k in in_bar:
        it = items[k]
        if k == "status" and not badge:
            continue
        assert it["visible"] and inside(it["box"], got["top"]) and it["box"]["l"] >= got["name"]["box"]["r"] - 0.5, (w, k, it, got["top"])
    bar = [p for p in got["pills"] if p["inBar"]]
    assert [p["text"] for p in bar] == (BAR_PILLS if "status" in in_bar and badge else []), got["pills"]
    for p in bar:
        assert p["box"]["w"] > 30 and inside(p["box"], items["status"]["box"]) and inside(p["box"], got["top"]), (w, p, items["status"])
    menu_pills = [p["text"] for p in got["pills"] if p["inMenu"]]
    assert menu_pills == SESSION_PILLS + (BAR_PILLS if "status" in in_menu and badge else []), (w, menu_pills)
    # the ⋯ button at every width (the tabs and the toggle are always in the menu), inside the header, after the name; the
    # menu closed, its items unseen
    assert got["btn"]["visible"] and not got["btn"]["hidden"], (w, got["btn"])
    assert inside(got["btn"]["box"], got["top"]) and got["btn"]["box"]["l"] >= got["name"]["box"]["r"] - 0.5, (w, got["btn"], got["name"])
    assert not got["menuOpen"] and not got["menuShown"] and got["btn"]["expanded"] == "false", (w, got["btn"], got["menuOpen"])
    assert all(not items[k]["visible"] for k in in_menu + list(ALWAYS_IN_MENU)), (w, in_menu, items)
    # nothing scrolls sideways
    assert got["docScroll"] <= w and got["mainScroll"] <= got["mainClient"], (w, got["docScroll"], got["mainScroll"], got["mainClient"])
    return in_menu


def check_menu(browser, in_menu: list[str]) -> None:
    """The ⋯ menu opened: the Session section, the View section (the switch, then the toggle) and what left the bar are
    there, seen and inside the page, in that order; Escape and an outside click close it."""
    browser.evaluate("document.querySelector('#top-menu-btn').click(); ''")
    got = browser.evaluate(MEASURE)
    w, items = got["width"], got["items"]
    page = {"l": 0, "r": w, "t": 0, "b": 844}
    assert got["menuOpen"] and got["menuShown"] and got["btn"]["expanded"] == "true" and inside(got["menuBox"], page), (w, got["menuBox"])
    for k in list(ALWAYS_IN_MENU) + in_menu:
        it = items[k]
        assert it["visible"] and inside(it["box"], got["menuBox"]), (w, k, it, got["menuBox"])
    # top to bottom: Session, then View with the switch above the toggle, then a folded Reload
    assert items["session"]["box"]["b"] <= items["view"]["box"]["t"] + 0.5, (w, items["session"], items["view"])
    assert items["tabs"]["box"]["b"] <= items["tools"]["box"]["t"] + 0.5 and inside(items["tabs"]["box"], items["view"]["box"]), (w, items["tabs"], items["tools"])
    assert inside(items["tools"]["box"], items["view"]["box"]), (w, items["tools"], items["view"])
    # then the folded Shell row (an icon and its word, 44 px to tap), then a folded Reload
    if "shell" in in_menu:
        assert items["shell"]["box"]["t"] >= items["view"]["box"]["b"] - 0.5 and items["shell"]["box"]["h"] >= 44, (w, items["shell"])
        assert browser.evaluate("document.querySelector('#shell-btn').textContent.trim()") == "Shell"
        assert browser.evaluate("getComputedStyle(document.querySelector('#shell-btn .shell-label')).display") != "none"
        assert browser.evaluate("getComputedStyle(document.querySelector('#shell-btn'), '::before').display") == "none"   # not the phone's drawn box
    if "reload" in in_menu:
        assert items["reload"]["box"]["t"] >= items["view"]["box"]["b"] - 0.5 and items["reload"]["box"]["h"] >= 44, (w, items["reload"])
        if "shell" in in_menu:
            assert items["reload"]["box"]["t"] >= items["shell"]["box"]["b"] - 0.5, (w, items["shell"], items["reload"])
    if "status" in in_menu:
        assert inside(items["status"]["box"], items["session"]["box"]), (w, items["status"], items["session"])
    for p in got["pills"]:
        if p["inMenu"]:
            assert p["box"]["w"] > 20 and inside(p["box"], got["menuBox"]), (w, p)
    assert got["docScroll"] <= w, got["docScroll"]
    browser.evaluate("document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); ''")
    assert browser.evaluate(STATE)["expanded"] == "false"
    browser.evaluate("document.querySelector('#top-menu-btn').click(); ''")
    assert browser.evaluate(STATE)["open"]
    browser.evaluate("document.querySelector('#chat').click(); ''")  # outside
    assert not browser.evaluate(STATE)["open"]


def assert_monotone(folded: dict, header_w: dict) -> None:
    """A wider header never folds more than a narrower one."""
    by_header = sorted((header_w[w], folded[w], w) for w in folded)
    assert [f for _, f, _ in by_header] == sorted((f for _, f, _ in by_header), reverse=True), by_header


def test_the_header_markup_and_styles():
    # the name, then the cluster (the status badge, Reload, the ⋯ button), then the menu, which holds the Session
    # and View sections; the pills styled wherever they are under #top, and no breakpoint hides the badge or the menu
    assert INDEX.index('id="title"') < INDEX.index('id="top-status"') < INDEX.index('id="menu-reload"') \
        < INDEX.index('id="top-menu-btn"') < INDEX.index('id="top-tools"') < INDEX.index("</header>")
    assert 'id="board-chip"' not in INDEX and "bchip" not in INDEX + CSS   # the item count button is gone
    assert 'id="top-bar"' not in INDEX and "top-bar" not in CSS   # Chat/Terminal and Reload are no longer a bar of their own
    assert 'id="top-menu-btn" class="icon-btn" aria-label="View options" data-i18n-aria-label="ui.hdr.viewOptions" aria-expanded="false" aria-controls="top-tools">' in INDEX
    bar = INDEX[INDEX.index('id="title"'):INDEX.index('id="top-tools"')]
    menu = INDEX[INDEX.index('id="top-tools"'):INDEX.index("</header>")]
    assert 'class="tabs"' not in bar and 'id="show-tools"' not in bar and 'class="pill' not in bar   # nothing static in the bar
    assert menu.index("Session</h3>") < menu.index('class="tabs"') < menu.index('id="show-tools"') and ">View</h3>" in menu
    assert "#top .pill {" in CSS and "#title .pill" not in CSS and "#top-status { flex: none;" in CSS  # a badge is never squeezed


@pytest.mark.parametrize("served", [LONG_SESSION], indirect=True)
def test_a_long_name_keeps_its_width_and_the_rest_folds_in_order(served, browser):
    browser.open(f"{served['url']}/#s={LONG}")
    assert browser.evaluate(WAIT_READY)
    folded, header_w = {}, {}
    for w in WIDTHS:
        got = set_width(browser, w)
        assert got["name"]["text"] == LONG
        in_menu = check(got)
        folded[w] = len(in_menu)
        header_w[w] = got["top"]["w"]
        check_menu(browser, in_menu)
    # a narrower header folds more, never less (the header, not the window: now the sidebar is over the page
    # on a wide window, so its header is all of the window, and 996 px has the header the
    # ~1000 px window had when the sidebar took 280 px of it, the width that showed the defect: the bar keeps 296 px at the left for the
    # fixed toggle and header): the name whole,
    # everything folded; at a phone's width only the name and the ⋯ button are left, and the name's ellipsis is the
    # last resort
    assert_monotone(folded, header_w)
    assert folded[320] == 3 and folded[1600] == 0, folded
    got = set_width(browser, 320)
    assert got["name"]["cut"] and got["name"]["box"]["r"] <= got["btn"]["box"]["l"], got["name"]
    # the 60-character name is whole at 1280 px (centred) and at 996 px (where centring would put it under the sidebar's block it
    # moves right only as far as it must, test_header_layout.py), and cut only when the two sides leave it no room
    for w in (1280, 996):
        got = set_width(browser, w)
        assert not got["name"]["cut"] and got["name"]["box"]["w"] > 400, (w, got["name"])


@pytest.mark.parametrize("served", [SHORT_SESSION], indirect=True)
def test_a_short_name_leaves_the_controls_in_the_bar(served, browser):
    browser.open(f"{served['url']}/#s=board-main")
    assert browser.evaluate(WAIT_READY)
    folded, header_w = {}, {}
    for w in WIDTHS:
        got = set_width(browser, w)
        in_menu = check(got)
        folded[w] = len(in_menu)
        header_w[w] = got["top"]["w"]
        check_menu(browser, in_menu)
    assert_monotone(folded, header_w)
    # a wide window shows the cluster whole (the badge, the Reload icon, the Shell button); a phone folds the Shell button first, then
    # Reload, then the badge: the two side tracks are equal (the name is centred on the bar), so at 320 px the name needs all three
    # gone
    assert folded[1600] == 0 and folded[1280] == 0 and folded[996] == 0 and folded[320] == 3, folded


@pytest.mark.parametrize("served", [LONG_SESSION], indirect=True)
def test_the_menu_items_work_where_they_are(served, browser):
    """At a width where everything that can fold has folded, the tabs, the toggle and Reload work from the menu, the tab
    keeps its state back in the bar when the window widens, and the fold is there again after the reload."""
    browser.open(f"{served['url']}/#s={LONG}")
    assert browser.evaluate(WAIT_READY)
    got = set_width(browser, 600)
    assert check(got) == list(FOLD), got["items"]
    s0 = browser.evaluate(STATE)
    assert not s0["checked"] and s0["hideTools"] and s0["tab"] == "chat" and s0["folded"] == 3, s0
    assert s0["pressed"] == ["chat=true", "terminal=false"], s0
    browser.evaluate("document.querySelector('#top-menu-btn').click(); ''")
    # the thinking toggle: the pref and the chat follow, the menu stays open (a toggle is not a navigation)
    browser.evaluate("document.querySelector('#show-tools').click(); ''")
    s1 = browser.evaluate(STATE)
    assert s1["checked"] and not s1["hideTools"] and s1["open"], s1
    # the Terminal tab: the view switches and the menu closes
    browser.evaluate("document.querySelector('#top .tab[data-tab=terminal]').click(); ''")
    s2 = browser.evaluate(STATE)
    assert s2["tab"] == "terminal" and s2["terminal"] and s2["activeTab"] == "terminal" and not s2["open"] and s2["expanded"] == "false", s2
    assert s2["pressed"] == ["chat=false", "terminal=true"], s2
    # wider: Reload is back in the bar; the switch is where it was (the menu), Terminal still the open view, the toggle still on
    got = set_width(browser, 1600)
    assert check(got) == []
    s3 = browser.evaluate(STATE)
    assert s3["tab"] == "terminal" and s3["activeTab"] == "terminal" and s3["checked"], s3
    browser.evaluate("document.querySelector('#top-menu-btn').click(); ''")
    browser.evaluate("document.querySelector('#top .tab[data-tab=chat]').click(); ''")
    assert browser.evaluate(STATE)["tab"] == "chat"
    # Reload from the menu where it has folded: a reload navigation, and the page comes back folded, the toggle's pref kept
    got = set_width(browser, 600)
    assert check(got) == list(FOLD)
    browser.evaluate("document.querySelector('#top-menu-btn').click(); ''")
    assert browser.evaluate(STATE)["open"]
    browser.evaluate("window.__old = true; document.querySelector('#menu-reload').click(); ''")
    assert wait_fresh(browser)
    nav = browser.evaluate('performance.getEntriesByType("navigation")[0].type')
    assert nav == "reload"
    browser.evaluate("new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))")
    got = browser.evaluate(MEASURE)
    assert got["width"] == 600 and check(got) == list(FOLD) and got["name"]["text"] == LONG, got["name"]
    s4 = browser.evaluate(STATE)
    assert s4["checked"] and not s4["hideTools"] and not s4["open"], s4
    assert json.loads(browser.evaluate("JSON.stringify(state.prefs)"))["showTools"] is True


@pytest.mark.parametrize("served", [SHORT_SESSION], indirect=True)
def test_the_thinking_toggle_is_in_the_menu_at_every_width(served, browser):
    """Decision: with a short name and the
    whole bar free the toggle is still not in the header but in the ⋯ menu, which has its button; it works from there
    (a click, the Space key on the focused box) with the menu staying open, and the pref is saved."""
    browser.open(f"{served['url']}/#s=board-main")
    assert browser.evaluate(WAIT_READY)
    for w in (1600, 996, 390):
        got = set_width(browser, w)
        it = got["items"]["tools"]
        assert it["inMenu"] and not it["inBar"] and not it["visible"], (w, it)
        assert got["btn"]["visible"] and not got["btn"]["hidden"], (w, got["btn"])
    got = set_width(browser, 1600)
    assert got["folded"] == 0 and not got["items"]["reload"]["inMenu"], got  # the rest of the bar is still all inline
    browser.evaluate("document.querySelector('#top-menu-btn').click(); ''")
    got = browser.evaluate(MEASURE)
    assert got["menuShown"] and got["items"]["tools"]["visible"] and inside(got["items"]["tools"]["box"], got["menuBox"]), got["items"]["tools"]
    assert got["items"]["tools"]["box"]["h"] >= 30, got["items"]["tools"]  # a row to tap
    assert not browser.evaluate(STATE)["checked"]
    browser.evaluate("document.querySelector('#show-tools').click(); ''")
    s1 = browser.evaluate(STATE)
    assert s1["checked"] and not s1["hideTools"] and s1["open"], s1
    # the keyboard: the box takes focus and Space flips it back
    browser.evaluate("document.querySelector('#show-tools').focus(); ''")
    browser.send("Input.dispatchKeyEvent", {"type": "keyDown", "key": " ", "code": "Space", "text": " ", "windowsVirtualKeyCode": 32})
    browser.send("Input.dispatchKeyEvent", {"type": "keyUp", "key": " ", "code": "Space", "windowsVirtualKeyCode": 32})
    s2 = browser.evaluate(STATE)
    assert not s2["checked"] and s2["hideTools"], s2
    browser.evaluate("document.querySelector('#show-tools').click(); ''")
    assert json.loads(browser.evaluate("JSON.stringify(state.prefs)"))["showTools"] is True


# at 360 px with no status badge the bar leaves the name about a dozen characters beside Shell: "beta" fits with everything in the bar,
# "board-main-qa" needs Shell gone only, "gamma-harbor-shelves-annex" Reload gone as well (the fold order, Shell first)
PHONE_NAMES = (("beta", []), ("board-main-qa", ["shell"]), ("gamma-harbor-shelves-annex", ["shell", "reload"]))   # 4, 13 and 26 characters
# the name with Shell put back into the bar, measured with the page's own nameFits(), then the layout restored
SHELL_BACK_IN_BAR = """(() => { const end = document.querySelector("#top-end");
  end.insertBefore(titleBar.shell, document.querySelector("#top-menu-btn"));
  const fits = nameFits(); layoutHeader(); return fits; })()"""


@pytest.mark.parametrize("served", [{"name": n, "role": "front", "lane": "subscription-2", "status": "idle"} for n, _ in PHONE_NAMES], indirect=True, ids=[n for n, _ in PHONE_NAMES])
def test_on_a_360_px_phone_the_shell_button_folds_first(served, browser):
    """Decision: on a 360 px phone the session name was
    cut by the Shell button added later. Shell is the first item of the fold, so it is the one that goes into the ⋯ menu
    (as a row with its icon and its word); the name then fits whole, and Reload (and
    the status badge), which come after it in the fold order, leave only if the name still does not fit. A desktop width is
    unchanged. PHONE_NAMES says how many go for each name."""
    name = served["name"]
    browser.open(f"{served['url']}/#s={name}")
    assert browser.evaluate(WAIT_READY)
    folds = dict(PHONE_NAMES)[name]
    got = set_width(browser, 360)
    assert got["name"]["text"] == name
    # with Shell back in the bar the name would be cut (the defect); the page's own layout puts it in the menu and the name fits
    assert browser.evaluate(SHELL_BACK_IN_BAR) is bool(not folds)
    got = set_width(browser, 360)
    assert check(got, badge=False) == folds and got["folded"] == len(folds), got["items"]
    assert not got["name"]["cut"] and got["name"]["box"]["w"] > 30, got["name"]
    # Reload stays in the bar while the name fits without folding it
    assert got["items"]["reload"]["inBar"] is ("reload" not in folds), got["items"]["reload"]
    # the Shell row in the menu (when it has folded), with its icon and its word, and its state still the drawer's
    check_menu(browser, folds)
    if folds:
        row = browser.evaluate("""(() => { const b = document.querySelector("#shell-btn");
          return { inMenu: !!b.closest("#top-tools"), svg: !!b.querySelector("svg"), text: b.textContent.trim(), expanded: b.getAttribute("aria-expanded"),
                   controls: b.getAttribute("aria-controls") }; })()""")
        assert row == {"inMenu": True, "svg": True, "text": "Shell", "expanded": "false", "controls": "shell-drawer"}, row
    # a desktop width: Shell is back in the bar with its word, nothing folded
    for w in (1280, 996):
        got = set_width(browser, w)
        assert check(got, badge=False) == [] and got["folded"] == 0, (w, got["items"])
        assert got["items"]["shell"]["inBar"] and got["items"]["shell"]["visible"], (w, got["items"]["shell"])
        assert browser.evaluate("getComputedStyle(document.querySelector('#shell-btn .shell-label')).display") != "none"
