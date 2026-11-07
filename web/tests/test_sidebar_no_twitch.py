"""The sidebar does not twitch: moving the pointer between a project header and the session rows
moved rows up and down by a pixel or two. The row's ⋯ button is `display: none` until the row is hovered, focused or
selected, and at 22px it was taller than the row's content (the 18px board mark sets that height), so the hovered row grew and
every row under it shifted. Anything shown on hover must fit inside the height the row has without it.

What a wrong answer costs: a list that jitters under the pointer, so a click lands on the row that has just moved. The check
reads every row's and header's height and top with the pointer away, then with it on each session row, each header, and on the
⋯ button focused, and allows no change at all. The browser is a headless Chromium at 1280 px with real DevTools
mouse events; api/sessions is a stub (test_fork_menu.py's)."""

from __future__ import annotations

import json

from test_board_items_ui import wait_for
from test_fork_menu import box, hover, open_list, row_sel
from test_new_session import env, sala  # noqa: F401  (fixtures)

# the height and the top of every row and header, in list order
GEOM = """[...document.querySelectorAll('#session-list .sess, #session-list .group-title, #session-list .scope-title')].map((e) => {
  const r = e.getBoundingClientRect();
  return { k: e.dataset.key || e.dataset.ckey || e.className, cls: e.className, offsetHeight: e.offsetHeight, h: r.height, top: r.top }; })"""
EPS = 0.01   # layout is fractional (a 14px line at 1.55 is 21.7px): a 22px button made a hovered row 0.3px taller, enough to move the rows under it
NAMES = ["example-alpha-main", "example-alpha-main-side-onyx07", "example-alpha-sdk", "example-alpha-api"]


def geom(browser) -> list[dict]:
    return browser.evaluate(GEOM)


def away(browser) -> None:
    browser.send("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": 1270, "y": 790})   # over the page, off the sidebar


def same(base: list[dict], now: list[dict], where: str) -> None:
    assert len(base) == len(now), (where, base, now)
    for a, b in zip(base, now):
        assert a["k"] == b["k"], (where, a, b)
        assert abs(a["offsetHeight"] - b["offsetHeight"]) < EPS and abs(a["h"] - b["h"]) < EPS, (where, "height changed", a, b)
        assert abs(a["top"] - b["top"]) < EPS, (where, "moved", a, b)


def walk(browser, where: str) -> list[dict]:
    away(browser)
    base = geom(browser)
    heads = [g for g in base if "title" in g["cls"]]
    assert len(heads) >= 2 and len(base) >= 6, base           # a scope header, a project header and the four rows
    for name in NAMES:
        hover(browser, name)
        same(base, geom(browser), f"{where}: pointer on {name}")
    for h in heads:
        b = box(browser, f'#session-list [data-ckey="{h["k"]}"]')
        browser.send("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": b["x"] - 30, "y": b["y"]})
        same(base, geom(browser), f"{where}: pointer on header {h['k']}")
        away(browser)
        same(base, geom(browser), f"{where}: pointer away again")
    return base


def test_no_row_or_header_changes_height_or_moves_when_the_pointer_or_focus_arrives(sala, served, browser):
    open_list(browser, served)
    base = walk(browser, "nothing selected")
    rows = [g for g in base if g["cls"].startswith("sess")]
    assert len({g["offsetHeight"] for g in rows}) == 1, rows       # one row height: with ⋯ and without
    # keyboard focus on a row's ⋯ shows it, and moves nothing
    away(browser)
    hover(browser, "example-alpha-main")
    browser.evaluate(f"document.querySelector({json.dumps(row_sel('example-alpha-main', True))}).focus(); ''")
    assert browser.evaluate("document.activeElement.classList.contains('sess-more')")
    away(browser)
    same(base, geom(browser), "⋯ focused, pointer away")
    browser.evaluate("document.activeElement.blur(); ''")
    same(base, geom(browser), "blurred")


def test_the_open_sessions_row_is_as_tall_as_the_others_and_hover_still_moves_nothing(sala, served, browser):
    """The open row shows its ⋯ all the time (and on a phone only that row does): it must not be the taller one."""
    open_list(browser, served)
    browser.evaluate("location.hash = '#s=example-alpha-api'; ''")
    assert wait_for(browser, "document.querySelector('#session-list .sess.selected') !== null", 8.0)
    away(browser)
    assert browser.evaluate("getComputedStyle(document.querySelector('#session-list .sess.selected .sess-more')).display") != "none"
    base = walk(browser, "api selected")
    rows = [g for g in base if g["cls"].startswith("sess")]
    assert len({g["offsetHeight"] for g in rows}) == 1, rows
