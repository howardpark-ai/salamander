"""The title bar's layout:

- the session name, with its status dot, is centred in the title bar (the room beside the fixed sidebar block, which is
  the same room whether the sidebar is closed or docked) while the cluster on its right leaves it the room; the title
  holds nothing but the dot and the name; below 400 px (a phone) it is not centred: it starts right after the sidebar button and has all the room up to the cluster;
- the cluster is at the right, in this order: the status badge (working), Reload as an icon, the ⋯ button, the Shell button;
  on a phone nothing overflows or overlaps and the name is not cut for any of them (a board item count button sat first in the cluster
  until Thu Nov 5th 2026; it was removed, so every name has its 43 px and the gap beside it);
- front is --call's orange and background a violet, in the light and the dark theme, each readable on its own fill;
  the badges now live in the ⋯ menu's Session section (test_header_menu.py holds the menu itself).

The header's fold itself (which item leaves for the ⋯ menu, and when) is test_header_fold.py's. Runs in a headless
Chromium when one is installed (conftest.py: `served`, `browser`), else skipped.
"""

from __future__ import annotations

import re
import time

import pytest

from sala_web.app import STATIC
from test_back_button import FAKE
from test_board_items_ui import CONTRAST, wait_for
from test_sidebar_hover import OPEN, click_button, move, open_wide
from test_composer_attach import WAIT_READY
from test_header_fold import inside, set_width

CSS = (STATIC / "style.css").read_text()
NAME = "board-main"
SESSION = {"name": NAME, "role": "front", "lane": "subscription-1", "status": "busy"}   # busy: the status badge "working" is in the bar

LAYOUT = r"""
(() => {
  const q = (s) => document.querySelector(s);
  const box = (e) => { const r = e.getBoundingClientRect(); return { l: r.left, r: r.right, t: r.top, b: r.bottom, w: r.width, h: r.height }; };
  const name = q("#title .name"), end = q("#top-end");
  const shown = (e) => e.getBoundingClientRect().width > 0;
  const cluster = [...q("#top-status").children, q("#menu-reload"), q("#top-menu-btn"), q("#shell-btn")].filter(shown);
  return { width: innerWidth, title: box(q("#title")), top: box(q("#top")), who: box(q("#title .who")), dot: box(q("#title .dot")),
           name: { box: box(name), cut: name.scrollWidth > name.clientWidth, text: name.textContent },
           titleKids: [...q("#title").children].map((e) => e.className || e.id),
           whoKids: [...q("#title .who").children].map((e) => e.className.split(" ")[0]),
           cluster: cluster.map((e) => ({ id: e.id || e.className, text: e.textContent, box: box(e) })),
           end: box(end), btn: box(q("#top-menu-btn")), shell: box(q("#shell-btn")), folded: headerFolded,
           docScroll: document.documentElement.scrollWidth, mainScroll: q("#main").scrollWidth, mainClient: q("#main").clientWidth };
})()
"""


def open_header(browser, served, width: int) -> dict:
    browser.open(f"{served['url']}/#s={NAME}")
    assert browser.evaluate(WAIT_READY)
    set_width(browser, width)
    return browser.evaluate(LAYOUT)


@pytest.mark.parametrize("served", [SESSION], indirect=True)
def test_on_a_desktop_the_name_is_centred_and_the_cluster_sits_at_the_right(served, browser):
    got = open_header(browser, served, 1280)
    assert got["width"] == 1280 and got["folded"] == 0, got
    # the title: the name's block and the cluster, nothing else; the block is the dot and the name, nothing else
    assert got["titleKids"] == ["who", "top-end"] and got["whoKids"] == ["dot", "name"], got
    # the name with its dot is centred in the title bar
    centre = lambda b: (b["l"] + b["r"]) / 2
    assert abs(centre(got["who"]) - centre(got["title"])) <= 3, (got["who"], got["title"])
    assert got["dot"]["r"] <= got["name"]["box"]["l"] and inside(got["who"], got["title"]), got
    assert not got["name"]["cut"], got["name"]
    # the cluster, left to right: the status badge, Reload, the ⋯ button, the Shell button; all right of the name, each whole
    # inside the bar, one cluster (small gaps), the last of them at the bar's right padding
    ids = [c["id"] for c in got["cluster"]]
    assert ids == ["pill busy", "menu-reload", "top-menu-btn", "shell-btn"] and [c["text"] for c in got["cluster"]][0] == "working", got["cluster"]
    prev = got["who"]["r"]
    for c in got["cluster"]:
        assert c["box"]["l"] >= prev - 0.5 and inside(c["box"], got["top"]), (c, prev)
        prev = c["box"]["r"]
    gaps = [b["box"]["l"] - a["box"]["r"] for a, b in zip(got["cluster"], got["cluster"][1:])]
    assert all(0 <= g <= 16 for g in gaps), gaps
    assert 0 <= got["top"]["r"] - got["shell"]["r"] <= 20, (got["shell"], got["top"])
    assert got["docScroll"] <= 1280 and got["mainScroll"] <= got["mainClient"], got


@pytest.mark.parametrize("served", [SESSION], indirect=True)
def test_on_a_phone_nothing_overflows_overlaps_or_cuts_the_name(served, browser):
    got = open_header(browser, served, 390)
    assert got["width"] == 390 and got["docScroll"] <= 390 and got["mainScroll"] <= got["mainClient"], got
    # the items that fold went into the ⋯ menu in the fold order, the
    # Shell button first, as far as the name needed: here (a working session, a 390 px phone) Shell and Reload, the status badge stays
    ids = [c["id"] for c in got["cluster"]]
    assert ids == ["pill busy", "top-menu-btn"] and got["folded"] == 2, (ids, got["folded"])
    assert not got["name"]["cut"] and got["name"]["box"]["w"] > 60, got["name"]
    # in the title bar, left to right: the name, then the cluster in order, none over another, all inside the header
    assert inside(got["who"], got["top"]) and inside(got["end"], got["top"]), got
    prev = got["who"]["r"]
    for c in got["cluster"]:
        assert c["box"]["l"] >= prev - 0.5 and inside(c["box"], got["top"]), (c, prev)
        prev = c["box"]["r"]
    assert got["shell"]["w"] == 0, got["shell"]   # in the menu; its tap target in the bar is test_shell_drawer.py's (the Overview, where it cannot fold)
    # the name is not pushed under the fixed sidebar toggle, which keeps its own room at the left
    toggle = browser.evaluate("document.querySelector('#side-open').getBoundingClientRect().right")
    assert got["who"]["l"] >= toggle, (got["who"], toggle)


@pytest.mark.parametrize("served", [SESSION], indirect=True)
def test_a_long_name_is_cut_centred_never_moved_or_put_under_something(served, browser):
    """An item that cannot sit beside the whole name leaves for the menu (the fold's measuring code reads the new layout).
    Where the 60-character name still does not fit between the two equal side tracks it gets an ellipsis, centred on the
    bar, and is never moved off-centre, under the fixed sidebar block or under the cluster."""
    long = "gamma-harbor-crate-sorting-and-shelf-labeling-march-2031-rn"
    browser.send("Page.enable")
    browser.open(f"{served['url']}/#s={NAME}")
    assert browser.evaluate(WAIT_READY)
    browser.evaluate(f"document.querySelector('#title .name').textContent = {long!r}; layoutHeader(); ''")
    for w in (1280, 1000, 900):
        set_width(browser, w)
        browser.evaluate("layoutHeader(); ''")
        got = browser.evaluate(LAYOUT)
        assert inside(got["who"], got["title"]), (w, got["who"], got["title"])
        if w == 1280:   # room on both sides: centred, whole
            assert abs(centre(got["who"]) - centre(got["top"])) <= 1.5 and not got["name"]["cut"], (w, got["who"], got["top"])
        else:           # centred it would be under the sidebar's block: it moves right as far as it must, never left of the centre
            assert centre(got["who"]) >= centre(got["top"]) - 1.5, (w, got["who"], got["top"])
        assert got["who"]["l"] >= 296 - 0.5, (w, got["who"])   # not under the fixed sidebar block
        for c in got["cluster"]:
            assert c["box"]["l"] >= got["who"]["r"] - 0.5, (w, c, got["who"])


def centre(b: dict) -> float:
    return (b["l"] + b["r"]) / 2


LONG_NAME = "gamma-harbor-crate-sorting-and-shelf-labeling-march-2031-rn"


@pytest.mark.parametrize("name", [NAME, LONG_NAME], ids=["short-name", "long-name"])
@pytest.mark.parametrize("width", [400, 430, 1280])
@pytest.mark.parametrize("served", [SESSION], indirect=True)
def test_the_name_is_centred_on_the_full_bar_at_every_width(served, browser, width, name):
    """On a phone the title is centred on the bar's FULL width, never pushed off-centre by the
    side groups (the toggle at the left, the cluster at the right). The two side tracks are equal, so the name's block
    (dot and name) has its centre on the bar's centre, within a pixel or two, whatever the cluster holds; when the name
    does not fit between the tracks it is cut with an ellipsis, not moved. This holds from
    400 px up: a phone under 400 px left-aligns the name (the test for it follows this one)."""
    browser.open(f"{served['url']}/#s={NAME}")
    assert browser.evaluate(WAIT_READY)
    browser.evaluate(f"document.querySelector('#title .name').textContent = {name!r}; layoutHeader(); ''")
    set_width(browser, width)
    browser.evaluate("layoutHeader(); ''")
    got = browser.evaluate(LAYOUT)
    assert got["width"] == width and got["top"]["l"] == 0 and got["top"]["r"] == width, got["top"]   # the bar is the whole window
    assert abs(centre(got["who"]) - width / 2) <= 1.5, (centre(got["who"]), width / 2, got["who"])
    assert abs(centre(got["title"]) - width / 2) <= 1.5, (got["title"], width)   # the grid itself spans the bar, nothing beside it in the row
    toggle = browser.evaluate("document.querySelector('#side-open').getBoundingClientRect().right")
    assert got["who"]["l"] >= toggle - 0.5 and inside(got["who"], got["top"]), (got["who"], toggle)
    for c in got["cluster"]:
        assert c["box"]["l"] >= got["who"]["r"] - 0.5 and inside(c["box"], got["top"]), (c, got["who"])
    if name == NAME:
        assert not got["name"]["cut"], got["name"]   # a short name fits at every width tested: whole, and centred
    assert got["docScroll"] <= width and got["mainScroll"] <= got["mainClient"], got


PHONE_NAMES = ["board-main", "wiki-hosting-main", "demo-builder-wren42", LONG_NAME]


@pytest.mark.parametrize("name", PHONE_NAMES)
@pytest.mark.parametrize("width", [320, 360, 390, 399])
@pytest.mark.parametrize("served", [SESSION], indirect=True)
def test_below_400_px_the_name_starts_after_the_toggle_and_runs_up_to_the_cluster(served, browser, width, name):
    """Decision: centred, the name got at most about 129 px of a 360 px
    phone (with the item count button, since removed: wiki-hosting-main lost 2 px, demo-builder-wren42 28 px). Under 400 px it starts right after
    the sidebar button (its block one gap, 8 px, after the button's right edge) and has everything up to the cluster; a
    name that is still too long is cut with an ellipsis against the cluster, never under it. The items in the bar are those
    of the centred bar (the fold is measured on the centred grid): the ⋯ button alone."""
    browser.open(f"{served['url']}/#s={NAME}")
    assert browser.evaluate(WAIT_READY)
    browser.evaluate(f"document.querySelector('#title .name').textContent = {name!r}; layoutHeader(); ''")
    set_width(browser, width)
    browser.evaluate("layoutHeader(); ''")
    got = browser.evaluate(LAYOUT)
    toggle = browser.evaluate("document.querySelector('#side-open').getBoundingClientRect().right")
    assert got["width"] == width and got["docScroll"] <= width and got["mainScroll"] <= got["mainClient"], got
    # what is in the bar is what the fold left, in its order: with the room the item count button used to take, "board-main" keeps its
    # status badge from 360 px on (two folded), a longer name folds all three
    folded = got["folded"]
    assert folded in (2, 3) and [c["id"] for c in got["cluster"]] == (["pill busy"] if folded == 2 else []) + ["top-menu-btn"], got["cluster"]
    # the name's block begins right after the toggle: its dot one gap beyond the button's edge, never under it; the name is after the dot
    assert toggle - 0.5 <= got["who"]["l"] <= toggle + 8 + 0.5, (got["who"], toggle)
    assert got["dot"]["l"] >= toggle and got["dot"]["r"] <= got["name"]["box"]["l"], got
    # (so even a short name is left, not centred) and the name stays clear of the cluster
    cluster_l = got["cluster"][0]["box"]["l"]
    assert got["name"]["box"]["r"] <= cluster_l - 8 + 0.5, got
    if name == LONG_NAME:
        assert got["name"]["cut"], got["name"]
        assert got["name"]["box"]["r"] >= cluster_l - 8 - 1.5, got   # cut against the cluster: every pixel up to it is used
    elif width >= 360 or name != "demo-builder-wren42":
        # demo-builder-wren42 is about 156.8 px at 16 px 600; the centred bar gave 128.8 px at 360 px, so it lost 28 px
        assert not got["name"]["cut"], got["name"]
    else:
        assert got["name"]["box"]["w"] >= 130, got["name"]   # 320 px: 141 px of the 157 (centred: 89)


@pytest.mark.parametrize("served", [SESSION], indirect=True)
def test_at_360_px_the_name_has_about_234_px_not_129(served, browser):
    """The decision's numbers, now without the item count button: a 360 px phone. The name's room is the bar less the toggle's 54 px,
    the dot and its gap, the cluster (the "working" badge and the ⋯ button, the item count button gone) and the
    title's gap: about 234 px; with the button it was 181 left-aligned, and 129 centred."""
    browser.open(f"{served['url']}/#s={NAME}")
    assert browser.evaluate(WAIT_READY)
    set_width(browser, 360)
    browser.evaluate(f"document.querySelector('#title .name').textContent = {LONG_NAME!r}; layoutHeader(); ''")
    got = browser.evaluate(LAYOUT)
    assert 228 <= got["name"]["box"]["w"] <= 240 and got["name"]["cut"], got["name"]


STACKSHOT = {"name": "demo-builder-wren42", "role": "front", "lane": "subscription-1", "status": "busy"}   # 156.8 px at 16 px 600: whole at 360 px left-aligned (181 px of room), cut centred (129)

PLACE = r"""
(() => {
  const q = (s) => document.querySelector(s);
  const name = q("#title .name"), toggle = q("#side-open").getBoundingClientRect(), n = q("#title .who").getBoundingClientRect();   // the block: dot and name
  return { width: innerWidth, centredClass: q("#title").classList.contains("fold-centred"), clientWidth: name.clientWidth, scrollWidth: name.scrollWidth,
           cut: name.scrollWidth > name.clientWidth, whoLeft: n.left, whoRight: n.right, toggleRight: toggle.right, folded: headerFolded,
           cols: getComputedStyle(q("#title")).gridTemplateColumns, bar: q("#top").getBoundingClientRect().width,
           inBar: [...q("#top-end").children].filter((e) => e.getBoundingClientRect().width > 0).map((e) => e.id || e.className) };
})()
"""


def place(browser) -> dict:
    return browser.evaluate(PLACE)


def open_stackshot(browser, served, width: int) -> dict:
    browser.open(f"{served['url']}/#s={STACKSHOT['name']}")
    assert browser.evaluate(WAIT_READY)
    return set_width(browser, width)


def assert_left_and_whole(got: dict) -> None:
    """Under 400 px: the name starts one gap after the toggle (not centred), is whole (157 px of the 181 it has), and the fold is the
    centred bar's (the ⋯ button stays, the other three folded)."""
    assert not got["centredClass"], got
    assert got["whoLeft"] - got["toggleRight"] <= 8.5, got   # the block starts one gap after the button; centred, it would start about 100 px further right
    assert not got["cut"] and got["clientWidth"] >= got["scrollWidth"] >= 156, got
    assert got["folded"] == 3 and got["inBar"] == ["top-menu-btn"], got


def assert_centred(got: dict) -> None:
    assert not got["centredClass"], got
    assert abs((got["whoLeft"] + got["whoRight"]) / 2 - got["width"] / 2) <= 1.5, got


@pytest.mark.parametrize("start", [430, 1280])
@pytest.mark.parametrize("served", [STACKSHOT], indirect=True)
def test_the_layout_follows_the_viewport_across_400_px_and_back(served, browser, start):
    """A follow-up (a load of demo-builder-wren42 at 360 px showed the name centred and cut, 133 of 157 px, two reloads
    showed it left-aligned and whole; the device metrics had been set twice, 4 s apart): the layout is decided by the viewport as
    it is now, not as it was at load. Open at a width of 400 px or more, narrow to 360 px (left-aligned, whole), widen again
    (centred), and repeat; and set the same width twice. `fold-centred` is never left on #title."""
    got = open_stackshot(browser, served, start)
    assert_centred(place(browser))
    for _ in range(3):
        set_width(browser, 360)
        assert_left_and_whole(place(browser))
        set_width(browser, 360)   # the same metrics again, as the failing run did (4 s later)
        assert_left_and_whole(place(browser))
        set_width(browser, start)
        assert_centred(place(browser))
    set_width(browser, 399)
    assert_left_and_whole(place(browser))
    set_width(browser, 400)
    assert_centred(place(browser))


@pytest.mark.parametrize("served", [STACKSHOT], indirect=True)
def test_the_layout_follows_the_viewport_from_a_phone_width_up_and_down(served, browser):
    """The other way: loaded at 360 px (left-aligned), widened to 430 px (centred) and narrowed to 320 px and 360 px again."""
    open_stackshot(browser, served, 360)
    assert_left_and_whole(place(browser))
    set_width(browser, 430)
    assert_centred(place(browser))
    set_width(browser, 320)
    got = place(browser)
    assert not got["centredClass"] and got["whoLeft"] - got["toggleRight"] <= 8.5 and got["folded"] == 3, got
    set_width(browser, 360)
    assert_left_and_whole(place(browser))


@pytest.mark.parametrize("served", [STACKSHOT], indirect=True)
def test_a_measure_that_throws_does_not_leave_fold_centred_on(served, browser):
    """nameFits() puts `fold-centred` on #title only while it measures. If the measure throws, the class must still come off (a
    finally), or the bar stays on the centred grid: the name centred and cut, as seen on the live page. Here the name's
    getBoundingClientRect throws on its second call (the one made with the class on)."""
    open_stackshot(browser, served, 360)
    got = browser.evaluate(r"""(() => {
      const n = document.querySelector("#title .name"), real = n.getBoundingClientRect.bind(n);
      let calls = 0, thrown = "";
      n.getBoundingClientRect = () => { if (++calls === 2) throw new Error("boom"); return real(); };
      try { layoutHeader(); } catch (e) { thrown = e.message; }
      delete n.getBoundingClientRect;
      return { thrown, leftOn: document.querySelector("#title").classList.contains("fold-centred") };
    })()""")
    assert got["thrown"] == "boom", got   # the error is not swallowed
    assert got["leftOn"] is False, got
    set_width(browser, 360)
    assert_left_and_whole(place(browser))


@pytest.mark.parametrize("served", [STACKSHOT], indirect=True)
def test_fold_centred_is_never_on_after_a_layout(served, browser):
    """After every layoutHeader() call, at every width tried, in any order, `fold-centred` is off; and the page's own measures
    (the ResizeObserver, the fonts) leave it off: a MutationObserver on #title's class (with the old value) sees it go on and
    then off, in pairs only, and the last change is the one that took it off."""
    open_stackshot(browser, served, 430)
    browser.evaluate(r"""(() => { const t = document.querySelector("#title"); window.__classLog = [];
      new MutationObserver((rs) => { for (const r of rs) window.__classLog.push((r.oldValue || "").includes("fold-centred") ? "off" : "on"); })
        .observe(t, { attributes: true, attributeFilter: ["class"], attributeOldValue: true }); return ""; })()""")
    for w in (360, 430, 399, 400, 320, 1280, 360, 390, 360):
        set_width(browser, w)
        browser.evaluate("layoutHeader(); layoutHeader(); ''")
        assert place(browser)["centredClass"] is False, w
    log = browser.evaluate("new Promise((r) => setTimeout(() => r(window.__classLog), 50))")
    assert log and log[0] == "on" and log[-1] == "off" and all(a != b for a, b in zip(log, log[1:])), log   # on, off, on, off ...


PHONE_QUERY = "@media not all and (min-width: 400px)"


def phone_block() -> str:
    """The text of style.css's phone block (the media rule that left-aligns the name), braces matched."""
    start = CSS.index("@media", CSS.index("a narrow phone (under 400 px"))
    depth = 0
    for j in range(CSS.index("{", start), len(CSS)):
        depth += {"{": 1, "}": -1}.get(CSS[j], 0)
        if depth == 0:
            return CSS[start:j + 1]
    raise AssertionError("unbalanced phone block")


def test_the_phone_rule_is_the_exact_complement_of_400_px_so_no_width_falls_between_the_two_layouts():
    """style.css: under browser zoom the viewport is fractional in CSS px (1000 px at 251% is 398.4, at 250% it is 400); a
    `max-width: 399px` block matched 399 px and below and the centred layout began at `min-width: 400px`, so 399.01 to 399.99 px
    had the centred one, whose name is cut on a phone. The phone block's query is `not all and (min-width: 400px)`, the
    complement of the other. (A fractional viewport cannot be set through DevTools: the metrics override takes whole pixels and an
    iframe's width is snapped to whole pixels, so this one is read from the stylesheet.)"""
    assert "@media (max-width: 399px)" not in CSS and "@media (max-width:399px)" not in CSS
    assert phone_block().startswith(PHONE_QUERY), phone_block()[:80]


def test_the_centred_template_in_the_phone_block_is_the_base_one():
    """The fold measures on the centred grid under 400 px (`#title.fold-centred`), so its columns must be the base `#title` rule's: the
    same text, or the fold would decide on another layout than the one the page shows at 400 px."""
    base = re.search(r"^#title \{[^}]*?grid-template-columns: ([^;]+);", CSS, re.M).group(1)
    folded = re.search(r"#title\.fold-centred \{ grid-template-columns: ([^;]+);", phone_block()).group(1)
    assert base == folded, (base, folded)


THEME = """(() => {
  const rows = document.querySelector('#top-session');
  for (const role of ['front', 'background']) { const p = document.createElement('span'); p.className = 'pill role-' + role; p.textContent = role; p.id = 'probe-' + role; rows.append(p); }
  document.body.classList.add('top-menu-open');
  return ''; })()"""


@pytest.mark.parametrize("scheme", ["light", "dark"])
@pytest.mark.parametrize("served", [SESSION], indirect=True)
def test_front_and_background_have_their_own_colours_readable_in_both_themes(served, browser, scheme):
    browser.open(f"{served['url']}/#s={NAME}")
    assert browser.evaluate(WAIT_READY)
    browser.send("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-color-scheme", "value": scheme}]})
    browser.evaluate(THEME)
    got = {r["text"]: r for r in browser.evaluate(CONTRAST + "('#probe-front, #probe-background')")}
    front, back = got["front"], got["background"]
    assert front["bg"] != back["bg"] and front["bgAlpha"] == 1 and back["bgAlpha"] == 1, (scheme, front, back)
    assert front["ratio"] >= 4.5 and back["ratio"] >= 4.5, (scheme, front, back)   # the words against their own fill
    # (the hues are the tokens': front --call's orange, background a violet)
    px = browser.evaluate("""(() => { const c = (id) => getComputedStyle(document.getElementById(id)); const o = {};
      for (const id of ['probe-front', 'probe-background']) o[id] = { color: c(id).color, border: c(id).borderTopColor }; return o; })()""")
    assert px["probe-front"]["color"] != px["probe-background"]["color"] and px["probe-front"]["border"] != px["probe-background"]["border"], px
    # the real role badge of the session, in the menu's Session section, is drawn the same way (front)
    real = browser.evaluate("getComputedStyle(document.querySelector('#top-session .pill.role-front')).backgroundColor")
    assert real == front["bg"], (real, front["bg"])


def test_the_colour_tokens_exist_for_both_themes():
    light, rest = CSS.split("@media (prefers-color-scheme: dark)", 1)
    media, theme = rest.split(':root[data-theme="dark"]', 1)
    for tok in ("--role-front-text", "--role-back", "--role-back-text"):
        assert tok in light and tok in media and tok in theme, tok
    assert "#top .pill.role-front {" in CSS and "#top .pill.role-background {" in CSS
    assert "var(--accent-solid, var(--call)) 12%" in CSS.split("#top .pill.role-front {", 1)[1].split("}", 1)[0]   # front is the orange (--call, or the solid orange the color tool sets), not the accent's blue


STATES = r"""(() => { const r = (s) => document.querySelector(s).getBoundingClientRect(), who = r("#title .who");
  const cl = r("#top-end"), sb = r("#sidebar"), hit = document.elementFromPoint(100, 25);
  return { body: [...document.body.classList].filter((c) => c.startsWith("side-")).sort(), who: { l: who.left, r: who.right },
           cut: document.querySelector("#title .name").scrollWidth > document.querySelector("#title .name").clientWidth,
           cluster: { l: cl.left }, sidebarRight: sb.right, win: innerWidth,
           // the title's grid must not eat clicks meant for what is under it (the docked sidebar and the fixed block over it)
           hit: !!hit && !!hit.closest("#sidebar, .side-head, #side-open") }; })()"""


def sidebar_states(browser) -> dict:
    """The title's measurements with the sidebar closed, peeking and docked (as test_sidebar_fixed_head.py reaches them)."""
    out = {"closed": browser.evaluate(STATES)}
    move(browser, 3, 400)
    assert wait_for(browser, OPEN, 5.0)
    time.sleep(0.35)
    out["peek"] = browser.evaluate(STATES)
    click_button(browser)
    assert wait_for(browser, "document.getElementById('main').getBoundingClientRect().left === 280", 5.0)
    move(browser, 1000, 500)
    time.sleep(0.3)
    out["docked"] = browser.evaluate(STATES)
    assert out["docked"]["body"] == ["side-pin"], out
    return out


@pytest.mark.parametrize("served", [SESSION], indirect=True)
def test_the_name_stays_put_when_the_sidebar_opens_or_closes_on_a_wide_window(served, browser):
    """The name is centred on the WINDOW, not on the main pane, so docking the sidebar
    (which makes the pane 280 px narrower) does not move it; a peek, which overlays, does not either."""
    open_wide(browser, served, f"#s={FAKE}", width=1400)
    st = sidebar_states(browser)
    for state, got in st.items():
        assert abs(centre(got["who"]) - 700) <= 1.5, (state, got["who"])
        assert not got["cut"] and got["who"]["l"] >= 296 - 0.5 and got["who"]["r"] <= got["cluster"]["l"], (state, got)
    assert abs(centre(st["closed"]["who"]) - centre(st["docked"]["who"])) <= 1, st
    # the part of the title that went back under the docked sidebar lets clicks through to it
    assert st["docked"]["hit"] is True, st["docked"]


@pytest.mark.parametrize("served", [SESSION], indirect=True)
def test_on_a_narrow_window_the_name_moves_only_as_far_as_it_must_to_clear_the_sidebar(served, browser):
    """A 60-character name at 1000 px, between the sidebar (docked, or the block that stays over it) and the cluster: centring
    it on the window would put it under the sidebar, so it moves right until it clears it (its left edge one gap, 12 px,
    after the 296 px the block keeps) and no further; it is the same with the sidebar closed or peeking, and the cluster is
    never overlapped."""
    open_wide(browser, served, f"#s={FAKE}", width=1000)
    browser.evaluate(f"document.querySelector('#title .name').textContent = {LONG_NAME!r}; layoutHeader(); ''")
    st = sidebar_states(browser)
    for state, got in st.items():
        assert 296 - 0.5 <= got["who"]["l"] <= 296 + 12 + 1, (state, got)            # cleared the block, by no more than the gap
        assert centre(got["who"]) > 500 + 1.5, (state, got["who"])                      # it did have to move (right)
        assert got["who"]["r"] <= got["cluster"]["l"] + 0.5, (state, got)               # never over the cluster
        assert got["who"]["l"] >= got["sidebarRight"] - 0.5 or state != "docked", (state, got)
    assert abs(centre(st["closed"]["who"]) - centre(st["docked"]["who"])) <= 1, st
