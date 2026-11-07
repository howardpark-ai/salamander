"""The sidebar's toggle and header are one fixed block at the top left (as in Notion and Claude, where the hover view and the
toggled-on view are nearly the same).

Held here, in a headless Chromium at 1280 px (real DevTools mouse events), in the dark and the light theme:
- the toggle (#side-open) and the header (the icon and "salamander : <suffix>") sit in the SAME place, at the same size, with the same
  text, whether the sidebar is closed, peeking (hover) or pinned: boxes equal within half a pixel;
- both are position: fixed, above the title bar and the sidebar, and what is under them is empty: the title bar's first content is not
  covered in the closed and the peeking state (a peek covers the left 280 px) and starts where a docked bar's does;
- a pinned sidebar still DOCKS: the title bar starts right of it, nothing of the bar behind the sidebar;
- the peek's panel is the pinned sidebar's (same box, background, border, rows, scroll), and differs only in that it overlays, with a
  light shadow;
- the block follows the title bar when the update banner pushes it down; the header lets the pointer through (only the toggle
  peeks and pins); the toggle's tooltip says Show/Hide sidebar;
- a phone (390 px) keeps its drawer: the toggle is in the title bar, the header on one line at the drawer's top, neither fixed.

What a wrong answer costs: a toggle that jumps under the pointer when the sidebar opens, a header that says something else when
pinned, a title bar whose name sits under the fixed block."""

from __future__ import annotations

import time

import pytest

from test_back_button import open_app, tap_at
from test_board_items_ui import wait_for
from test_sidebar_hover import BODY, BTN, CLOSED, OPEN, click_button, move, open_wide

TEXT = "salamander : example fleet"


@pytest.fixture(autouse=True)
def brand_suffix(monkeypatch):
    monkeypatch.setenv("SALA_BRAND_SUFFIX", "example fleet")
BLOCK = r"""(() => { const box = (e) => { const b = e.getBoundingClientRect(); return [b.left, b.top, b.width, b.height]; };
  const q = (s) => document.querySelector(s), head = q('.side-head');
  const first = [...q('#title').children].find((c) => c.getBoundingClientRect().width > 0 && getComputedStyle(c).display !== 'none');
  const fb = first.getBoundingClientRect(), hit = document.elementFromPoint(fb.left + Math.min(fb.width, 6) / 2 + 1, fb.top + fb.height / 2);
  return { btn: box(q('#side-open')), head: box(head), icon: box(q('.side-head .brand-icon')), brand: box(q('.side-head .brand')),
    text: head.querySelector('.brand-line').textContent, btnPos: getComputedStyle(q('#side-open')).position, headPos: getComputedStyle(head).position,
    firstLeft: fb.left, firstHit: !!hit && !!hit.closest('#title'), topLeft: q('#top').getBoundingClientRect().left,
    brandRight: q('.side-head .brand').getBoundingClientRect().right,
    btnTop: !!document.elementFromPoint(q('#side-open').getBoundingClientRect().x + 17, q('#side-open').getBoundingClientRect().y + 16).closest('#side-open'),
    title: q('#side-open').title, expanded: q('#side-open').getAttribute('aria-expanded'), body: [...document.body.classList].filter((c) => c.startsWith('side-')).sort() }; })()"""
PANEL = r"""(() => { const q = (s) => document.querySelector(s), box = (e) => { const b = e.getBoundingClientRect(); return [b.left, b.top, b.width, b.height]; };
  const sb = q('#sidebar'), cs = getComputedStyle(sb), list = getComputedStyle(q('#session-list'));
  return { box: box(sb), bg: cs.backgroundColor, border: cs.borderRightWidth + ' ' + cs.borderRightStyle + ' ' + cs.borderRightColor, shadow: cs.boxShadow,
    rows: ['#side-new', '#side-ovw', '#session-list', '#show-back'].map((s) => box(q(s))), overflowY: list.overflowY, padTop: cs.paddingTop,
    headBg: getComputedStyle(q('.side-head')).backgroundColor }; })()"""


def same(a, b, where, tol=0.5):
    assert len(a) == len(b) and all(abs(x - y) <= tol for x, y in zip(a, b)), (where, a, b)


def three_states(browser):
    """The block's measurements closed, peeking and pinned (in that order), the page's own pointer moves."""
    out = {"closed": browser.evaluate(BLOCK)}
    move(browser, 3, 400)
    assert wait_for(browser, OPEN, 5.0) and browser.evaluate(BODY) == ["side-peek"]
    time.sleep(0.35)                                                                          # the slide is over
    out["peek"] = browser.evaluate(BLOCK)
    out["peek_panel"] = browser.evaluate(PANEL)
    click_button(browser)
    assert wait_for(browser, "document.getElementById('main').getBoundingClientRect().left === 280", 5.0)
    move(browser, 1000, 500)
    time.sleep(0.3)
    assert browser.evaluate(BODY) == ["side-pin"]
    out["pin"] = browser.evaluate(BLOCK)
    out["pin_panel"] = browser.evaluate(PANEL)
    return out


def check_block(st):
    c, p, d = st["closed"], st["peek"], st["pin"]
    for k in ("btn", "head", "icon", "brand"):
        same(c[k], p[k], f"{k} closed vs peek")
        same(c[k], d[k], f"{k} closed vs pinned")
    assert c["text"] == p["text"] == d["text"] == TEXT, (c["text"], p["text"], d["text"])    # the same words in all three, not "sala" in one
    for s in (c, p, d):
        assert s["btnPos"] == "fixed" and s["headPos"] == "fixed" and s["btnTop"], s
        assert s["brand"][0] + s["brand"][2] <= s["head"][0] + s["head"][2] + 0.5 and s["icon"][0] >= s["btn"][0] + s["btn"][2], s   # icon after the toggle, words inside the block
    assert (c["expanded"], p["expanded"], d["expanded"]) == ("false", "true", "true"), st
    assert (c["title"], p["title"], d["title"]) == ("Show sidebar", "Hide sidebar", "Hide sidebar"), st   # the tooltip, as Claude's "Show sidebar"
    # the title bar's first content: clear of the block in every state, under nothing in closed and peek (a peek covers 280 px),
    # and, between closed and docked, moved only by the bar's centre (below)
    assert c["firstLeft"] >= c["brandRight"] and c["firstLeft"] >= 280 and c["firstHit"], ("closed", c)
    assert p["firstLeft"] >= 280 and p["firstHit"], ("peek", p)
    assert p["topLeft"] == c["topLeft"] == 0, "a peek does not move the page"
    assert d["topLeft"] == 280 and d["firstLeft"] >= 280 and d["firstHit"], ("pinned docks", d)
    # (the session name is centred on the window, not on the bar, so docking, which makes the bar 280 px narrower, leaves it
    # where it was while it fits; test_header_layout.py holds that at 1400 px and what happens at a narrow one)
    assert abs(d["firstLeft"] - c["firstLeft"]) <= 1, ("the title bar's name moves between closed and docked", c["firstLeft"], d["firstLeft"])
    # the peek is the pinned sidebar, drawn over the page
    pp, dp = st["peek_panel"], st["pin_panel"]
    same(pp["box"], dp["box"], "the panel's box")
    for k in ("rows",):
        for a, b in zip(pp[k], dp[k]):
            same(a, b, "a row of the panel")
    assert pp["bg"] == dp["bg"] and pp["border"] == dp["border"] and pp["overflowY"] == dp["overflowY"] and pp["padTop"] == dp["padTop"], (pp, dp)
    assert pp["shadow"] != "none" and dp["shadow"] == "none", (pp["shadow"], dp["shadow"])   # the peek overlays: a light shadow; the dock does not
    assert pp["headBg"] == dp["headBg"] == "rgba(0, 0, 0, 0)", (pp, dp)                       # the header takes what is under it


def test_the_toggle_and_the_header_do_not_move_or_change_between_closed_peek_and_pinned(served, browser):
    open_wide(browser, served)
    check_block(three_states(browser))


def test_the_same_in_the_light_theme(served, browser):
    open_wide(browser, served)
    browser.send("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-color-scheme", "value": "light"}]})
    time.sleep(0.2)
    st = three_states(browser)
    check_block(st)
    # readable on the sidebar's own colour: the words are not the sidebar's background
    assert browser.evaluate("getComputedStyle(document.querySelector('.side-head .brand')).color !== getComputedStyle(document.getElementById('sidebar')).backgroundColor")


def test_the_same_with_a_session_open(served, browser):
    from conftest import NAME

    open_wide(browser, served, hash_=f"#s={NAME}")
    assert wait_for(browser, "document.querySelector('#title .name').textContent.length > 0", 10.0)
    check_block(three_states(browser))


def test_the_header_lets_the_pointer_through_and_only_the_toggle_peeks(served, browser):
    open_wide(browser, served)
    head = browser.evaluate("(() => { const r = document.querySelector('.side-head .brand').getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()")
    move(browser, head["x"], head["y"])
    time.sleep(0.7)
    assert browser.evaluate(CLOSED) and browser.evaluate(BODY) == []                          # the words are not a button
    assert browser.evaluate(f"!document.elementFromPoint({head['x']}, {head['y']}).closest('.side-head')")
    b = browser.evaluate(BTN)
    move(browser, b["x"], b["y"])
    assert wait_for(browser, OPEN, 5.0)                                                       # the toggle is


def test_the_block_follows_the_title_bar_down_when_the_update_banner_shows(served, browser):
    open_wide(browser, served)
    browser.evaluate("document.getElementById('update-banner').hidden = false; ''")
    got = None
    for _ in range(40):
        got = browser.evaluate("""(() => { const r = (s) => document.querySelector(s).getBoundingClientRect(), top = r('#top'), btn = r('#side-open'), head = r('.side-head');
          return { topTop: top.top, btnDy: btn.top - top.top, headDy: head.top - top.top, headH: head.height, topH: top.height }; })()""")
        if got["topTop"] > 20 and abs(got["headDy"]) <= 0.5:   # the observer has set --banner-h
            break
        time.sleep(0.05)
    assert got["topTop"] > 20 and abs(got["btnDy"] - 11) <= 0.5 and abs(got["headDy"]) <= 0.5 and abs(got["headH"] - got["topH"]) <= 1, got
    browser.evaluate("document.getElementById('update-banner').hidden = true; ''")
    assert wait_for(browser, "document.getElementById('top').getBoundingClientRect().top === 0 && Math.round(document.getElementById('side-open').getBoundingClientRect().top) === 11", 5.0)


def test_a_phone_keeps_its_toggle_in_the_bar_and_the_header_in_the_drawer(served, browser):
    open_app(browser, served, "#sessions", width=390)
    got = browser.evaluate("""(() => { const q = (s) => document.querySelector(s), cs = (s) => getComputedStyle(q(s)), r = (s) => q(s).getBoundingClientRect();
      return { btnPos: cs('#side-open').position, headPos: cs('.side-head').position, btnInTop: q('#top').contains(q('#side-open')), headInSide: q('#sidebar').contains(q('.side-head')),
               topPadLeft: cs('#top').paddingLeft, btnLeft: r('#side-open').left, topLeft: r('#top').left }; })()""")
    assert got["btnPos"] != "fixed" and got["headPos"] != "fixed" and got["btnInTop"] and got["headInSide"], got
    # no room kept for the fixed block on a phone; the bar has no side padding (the name is centred on the whole bar)
    # and the toggle is drawn over its left end, 12 px in (position: absolute inside #top, not fixed)
    assert got["topPadLeft"] == "0px" and got["btnPos"] == "absolute" and 11 <= got["btnLeft"] - got["topLeft"] <= 13, got
    tap_at(browser, *(lambda b: (b["x"], b["y"]))(browser.evaluate(BTN)))
    assert wait_for(browser, OPEN, 5.0) and browser.evaluate(BODY) == ["side-open"]
    time.sleep(0.3)
    line = browser.evaluate("""(() => { const l = document.querySelector('.brand-line').getBoundingClientRect(), s = document.getElementById('sidebar').getBoundingClientRect(),
      c = document.getElementById('side-close').getBoundingClientRect(), t = document.querySelector('.brand').getBoundingClientRect(); return { oneLine: l.height < 30, inside: l.left >= s.left && t.right <= c.left, text: document.querySelector('.brand').textContent }; })()""")
    assert line == {"oneLine": True, "inside": True, "text": TEXT}, line
