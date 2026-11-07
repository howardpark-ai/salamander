"""The sidebar on a wide screen: closed on every load, slid over the page by the pointer.

What is held here, in a headless Chromium at 1280 px (real DevTools mouse events, so :hover and mouseenter are the browser's):
- it starts closed on every load and takes no room: #main reaches the left edge; nothing is kept (no pref read or written:
  `sideHidden` is gone from the page's state, from the prefs endpoint, and from every request the page makes; a leftover one
  in prefs.json changes nothing);
- the pointer on the strip along the left edge, or on the toggle (fixed at the top left in every state), slides it in over the page, and the pointer
  leaving takes it away; the way from the button into the sidebar does not shut it;
- a click on the button pins it and DOCKS it beside the page (a peek may cover the title bar, a click-opened sidebar should not): the title bar and chat move right and stay whole, the toggle has not moved, the pointer may leave, the next click closes it at once, for that page only (a reload
  starts closed again);
- it goes as usual while the New session page is up (the page is a view, not a popover anchored to its button);
- a phone keeps its drawer: no edge strip, the pointer does nothing, a tap opens the drawer.

What a wrong answer costs: a sidebar that covers the page and does not go away, one that shuts under the pointer on its way
to a row, or a state the server keeps and the next load opens with."""

from __future__ import annotations

import json
import time
from pathlib import Path

from starlette.testclient import TestClient

from sala_web.app import create_app
from sala_web.config import Settings
from test_back_button import open_app, tap_at
from test_board_items_ui import wait_for

STATIC = Path(__file__).resolve().parents[1] / "src" / "sala_web" / "static"

RECORD_PREFS = """(() => { window.__prefsCalls = []; const real = window.fetch.bind(window);
  window.fetch = (u, o) => { if (String(u).startsWith("api/prefs")) window.__prefsCalls.push({ method: (o && o.method) || "GET", body: (o && o.body) || null });
    return real(u, o); }; })();"""
CLOSED = "document.getElementById('sidebar').getBoundingClientRect().right <= 0"
OPEN = "document.getElementById('sidebar').getBoundingClientRect().left === 0"
BTN = "(() => { const r = document.getElementById('side-open').getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()"
BODY = "[...document.body.classList].filter((c) => c.startsWith('side-')).sort()"


def move(browser, x, y):
    browser.send("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": x, "y": y})


def open_wide(browser, served, hash_="#sessions", width=1280):
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": RECORD_PREFS})
    open_app(browser, served, hash_, width=width)
    # open_app settles on a phone's drawer; here the sidebar is the wide one: it is in place when closed
    assert wait_for(browser, CLOSED, 5.0), browser.evaluate(BODY)


def hold_closed(browser, ms=700):
    """Closed now and still closed after the timers and the slide have had their time."""
    time.sleep(ms / 1000)
    return browser.evaluate(CLOSED)


def test_it_starts_closed_and_takes_no_room(served, browser):
    open_wide(browser, served)
    got = browser.evaluate("""({ right: document.getElementById('sidebar').getBoundingClientRect().right, mainLeft: document.getElementById('main').getBoundingClientRect().left,
      pos: getComputedStyle(document.getElementById('sidebar')).position, classes: %s, expanded: document.getElementById('side-open').getAttribute('aria-expanded'),
      btn: getComputedStyle(document.getElementById('side-open')).display, hide: !!document.getElementById('side-hide') })""" % BODY)
    assert got["right"] <= 0 and got["mainLeft"] == 0 and got["pos"] == "fixed", got           # over the page, with no room of its own
    assert got["classes"] == [] and got["expanded"] == "false" and got["btn"] != "none" and not got["hide"], got


def test_the_left_edge_slides_it_in_and_leaving_takes_it_away(served, browser):
    open_wide(browser, served)
    move(browser, 3, 400)
    assert wait_for(browser, OPEN, 5.0) and browser.evaluate(BODY) == ["side-peek"]
    over = browser.evaluate("(() => { const r = document.getElementById('sidebar').getBoundingClientRect(); return { w: r.width, z: getComputedStyle(document.getElementById('sidebar')).zIndex, mainLeft: document.getElementById('main').getBoundingClientRect().left }; })()")
    assert over["w"] == 280 and over["mainLeft"] == 0, over                                   # over the page: the page did not move
    move(browser, 140, 300)                                                                   # onto the sidebar itself
    assert not hold_closed(browser) and browser.evaluate(OPEN)
    move(browser, 900, 400)                                                                   # away
    assert wait_for(browser, CLOSED, 5.0) and browser.evaluate(BODY) == []


def test_the_button_slides_it_in_and_the_way_into_the_sidebar_does_not_shut_it(served, browser):
    open_wide(browser, served)
    b = browser.evaluate(BTN)
    move(browser, b["x"], b["y"])
    assert wait_for(browser, OPEN, 5.0)
    # the button stays above the sidebar, in its header, and the brand does not sit under it
    geo = browser.evaluate("""(() => { const r = (s) => document.querySelector(s).getBoundingClientRect(), btn = r('#side-open'), brand = r('#sidebar .brand');
      const top = document.elementFromPoint(btn.x + btn.width / 2, btn.y + btn.height / 2);
      return { onTop: !!top.closest('#side-open'), brandAfterBtn: brand.left >= btn.right, btnInSidebar: btn.right <= r('#sidebar').right }; })()""")
    assert geo == {"onTop": True, "brandAfterBtn": True, "btnInSidebar": True}, geo
    move(browser, 60, 120)                                                                    # down the sidebar, over its rows
    move(browser, 140, 220)
    assert not hold_closed(browser)
    move(browser, 1000, 500)
    assert wait_for(browser, CLOSED, 5.0)


def click_button(browser):
    """A real click on the toggle where it is (fixed at the top left: the same place in every state)."""
    b = browser.evaluate(BTN)
    tap_at(browser, b["x"], b["y"])
    return b


GEO = """(() => { const r = (s) => { const e = document.querySelector(s); return e ? e.getBoundingClientRect() : null; };
  const sb = r('#sidebar'), top = r('#top'), main = r('#main'), btn = r('#side-open'), chat = r('#chat-pane'), ov = r('#overview-pane');
  const hit = document.elementFromPoint(btn.x + btn.width / 2, btn.y + btn.height / 2);
  // (the title's grid itself is pulled back under a docked sidebar so the name can stay centred on the window; it is empty there and lets the pointer through, so it is its content that is meant: the name's block and the cluster)
  const kids = [...document.querySelectorAll('#top > *:not(#title), #title > *')].filter((k) => k.getBoundingClientRect().width > 0 && !['absolute', 'fixed'].includes(getComputedStyle(k).position));   // the fixed toggle is not in the bar's row
  return { pos: getComputedStyle(document.getElementById('sidebar')).position, sbLeft: sb.left, sbRight: sb.right, sbW: sb.width, mainLeft: main.left,
           topLeft: top.left, topRight: top.right, kidsMinLeft: Math.min(...kids.map((k) => k.getBoundingClientRect().left)), btnLeft: btn.left,
           btnOnTop: !!hit && !!hit.closest('#side-open'), docScroll: document.documentElement.scrollWidth, vw: document.documentElement.clientWidth,
           edge: getComputedStyle(document.getElementById('side-edge')).display, composerLeft: r('#composer') && r('#composer').width > 0 ? r('#composer').left : null }; })()"""


def test_a_click_docks_it_beside_the_page_the_next_click_closes_it_and_nothing_is_kept(served, browser):
    open_wide(browser, served)
    peek_btn = browser.evaluate(BTN)
    click_button(browser)                                                                     # the pointer arrives (peek), the click pins and docks it
    assert wait_for(browser, "document.getElementById('sidebar').getBoundingClientRect().left === 0 && document.getElementById('main').getBoundingClientRect().left === 280", 5.0)
    assert browser.evaluate(BODY) == ["side-pin"]                                              # the peek is over, only the pin is left
    assert browser.evaluate("document.getElementById('side-open').getAttribute('aria-expanded')") == "true"
    # docked: in the flow beside the page; the title bar starts where the sidebar ends and nothing of it is behind the sidebar
    g = browser.evaluate(GEO)
    assert g["pos"] == "static" and g["sbW"] == 280 and g["sbRight"] == 280 and g["mainLeft"] == 280 and g["topLeft"] == 280, g
    assert g["kidsMinLeft"] >= 280 and g["btnLeft"] == 8 and g["btnOnTop"] and g["topRight"] == g["vw"], g   # the bar's content is beside the sidebar; the toggle did not move, reachable
    assert g["docScroll"] <= g["vw"] and g["edge"] == "none" and (g["composerLeft"] is None or g["composerLeft"] >= 280), g
    assert browser.evaluate(BTN) == peek_btn                                                   # the toggle stays where it was (fixed, in every state)
    move(browser, 1000, 500)                                                                  # the pointer leaves: a docked sidebar stays
    assert not hold_closed(browser) and browser.evaluate(OPEN) and browser.evaluate(GEO)["mainLeft"] == 280
    move(browser, 3, 400)                                                                     # the left edge and the sidebar itself do nothing to it
    move(browser, 140, 300)
    move(browser, 1000, 500)
    time.sleep(0.5)
    assert browser.evaluate(BODY) == ["side-pin"] and browser.evaluate(GEO)["mainLeft"] == 280
    click_button(browser)                                                                     # the same button, in the same place
    assert wait_for(browser, CLOSED, 5.0) and browser.evaluate(BODY) == []                    # closed at once
    g = browser.evaluate(GEO)
    assert g["mainLeft"] == 0 and g["topLeft"] == 0 and g["pos"] == "fixed" and g["btnOnTop"], g   # the page is back at the left edge
    assert browser.evaluate("document.getElementById('side-open').getAttribute('aria-expanded')") == "false"
    time.sleep(0.4)
    assert browser.evaluate(BODY) == [] and browser.evaluate(CLOSED)                          # and it stays closed
    # docked again, then a reload: for that page only
    click_button(browser)
    assert wait_for(browser, "document.getElementById('main').getBoundingClientRect().left === 280", 5.0)
    browser.send("Page.reload")
    assert wait_for(browser, "document.querySelectorAll('#session-list .sess').length > 0 && typeof state !== 'undefined'", 15.0)
    assert wait_for(browser, CLOSED, 5.0) and browser.evaluate(BODY) == []


def test_a_peek_slides_over_the_title_bar_and_the_page_does_not_move(served, browser):
    open_wide(browser, served)
    before = browser.evaluate(GEO)
    move(browser, 3, 400)
    assert wait_for(browser, OPEN, 5.0) and browser.evaluate(BODY) == ["side-peek"]
    g = browser.evaluate(GEO)
    assert g["pos"] == "fixed" and g["mainLeft"] == 0 and g["topLeft"] == 0 and g["sbRight"] == 280, g   # over the page, the title bar behind it
    assert g["topLeft"] == before["topLeft"] and g["btnOnTop"], g                                        # the page stays; the button is above the sidebar


def test_a_peek_then_a_click_docks_it_without_a_flicker(served, browser):
    """Hover opens it over the page, the click on the button docks it: the sidebar is never away from the left edge in between
    (sampled every frame), the title bar ends up at 280 and the pointer resting where the button was changes nothing."""
    open_wide(browser, served)
    b = browser.evaluate(BTN)
    move(browser, b["x"], b["y"])
    assert wait_for(browser, OPEN, 5.0) and browser.evaluate(BODY) == ["side-peek"]
    time.sleep(0.4)
    browser.evaluate("""(() => { window.__s = []; const sb = document.getElementById('sidebar');
      const f = () => { window.__s.push(Math.round(sb.getBoundingClientRect().left)); if (window.__s.length < 90) requestAnimationFrame(f); }; f(); })()""")
    tap_at(browser, b["x"], b["y"])
    assert wait_for(browser, "document.getElementById('main').getBoundingClientRect().left === 280", 5.0)
    time.sleep(1.2)                                                                           # the pointer rests where the button was; its timers have run
    samples = browser.evaluate("window.__s")
    assert len(samples) >= 30 and set(samples) == {0}, samples                                # never off the left edge, never sliding
    assert browser.evaluate(BODY) == ["side-pin"] and browser.evaluate(GEO)["mainLeft"] == 280
    click_button(browser)                                                                     # click again: closes
    assert wait_for(browser, CLOSED, 5.0) and browser.evaluate(BODY) == []


def test_pinned_then_the_pointer_over_the_sidebar_and_a_click_on_the_button_still_closes(served, browser):
    open_wide(browser, served)
    click_button(browser)
    assert wait_for(browser, "document.getElementById('main').getBoundingClientRect().left === 280", 5.0)
    move(browser, 140, 300)                                                                   # on the docked sidebar
    time.sleep(0.4)
    assert browser.evaluate(BODY) == ["side-pin"]
    click_button(browser)
    assert wait_for(browser, CLOSED, 5.0) and browser.evaluate(GEO)["mainLeft"] == 0 and browser.evaluate(BODY) == []


def test_docked_the_overview_and_the_chat_fit_beside_it(served, browser):
    open_wide(browser, served)
    click_button(browser)
    assert wait_for(browser, "document.getElementById('main').getBoundingClientRect().left === 280", 5.0)
    g = browser.evaluate(GEO)
    assert g["docScroll"] <= g["vw"], g
    assert browser.evaluate("(() => { const r = document.getElementById('overview-pane').getBoundingClientRect(); return r.left >= 280 && r.right <= innerWidth; })()")


def test_docked_the_chat_view_moves_right_whole(served, browser):
    from conftest import NAME

    open_wide(browser, served, hash_=f"#s={NAME}")
    assert wait_for(browser, "document.getElementById('composer').getBoundingClientRect().width > 0", 10.0)
    assert browser.evaluate(GEO)["composerLeft"] == 0
    click_button(browser)
    assert wait_for(browser, "document.getElementById('main').getBoundingClientRect().left === 280", 5.0)
    got = browser.evaluate("""(() => { const r = (s) => document.querySelector(s).getBoundingClientRect(); const c = r('#composer'), t = r('#top'), chat = r('#chat-pane');
      return { composer: [c.left, c.right], top: [t.left, t.right], chat: [chat.left, chat.right], vw: innerWidth, scroll: document.documentElement.scrollWidth }; })()""")
    assert got["composer"] == [280, 1280] and got["top"] == [280, 1280] and got["chat"][0] == 280 and got["scroll"] <= got["vw"], got
    click_button(browser)
    assert wait_for(browser, CLOSED, 5.0)
    assert browser.evaluate(GEO)["composerLeft"] == 0                                         # and back


def test_no_pref_is_read_or_written(served, browser):
    # a leftover sideHidden in the saved prefs, from before: it opens nothing and is not served
    state = served["settings"].state_dir
    state.mkdir(parents=True, exist_ok=True)
    (state / "prefs.json").write_text(json.dumps({"sideHidden": True, "showAll": False}))
    open_wide(browser, served)
    b = browser.evaluate(BTN)
    tap_at(browser, b["x"], b["y"])
    assert wait_for(browser, "document.getElementById('main').getBoundingClientRect().left === 280", 5.0)
    click_button(browser)                                                                     # the toggle, over the docked sidebar's top
    assert wait_for(browser, CLOSED, 5.0)
    move(browser, 3, 400)
    assert wait_for(browser, OPEN, 5.0)
    move(browser, 900, 400)
    assert wait_for(browser, CLOSED, 5.0)
    got = browser.evaluate("({ calls: window.__prefsCalls, hasKey: 'sideHidden' in state.prefs })")
    assert got["hasKey"] is False, got                                                       # not read into the page's state
    assert [c for c in got["calls"] if c["method"] != "GET"] == [], got                      # and nothing written: no PUT at all
    assert all("sideHidden" not in (c["body"] or "") for c in got["calls"]), got
    assert json.loads((state / "prefs.json").read_text()) == {"sideHidden": True, "showAll": False}   # the file was not touched either


def test_the_prefs_endpoint_no_longer_has_the_key(tmp_path):
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                        tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"])
    settings.state_dir.mkdir(parents=True)
    (settings.state_dir / "prefs.json").write_text(json.dumps({"sideHidden": True, "showAll": True}))
    c = TestClient(create_app(settings))
    assert "sideHidden" not in c.get("/api/prefs").json() and c.get("/api/prefs").json()["showAll"] is True
    r = c.put("/api/prefs", json={"sideHidden": True})
    assert r.status_code == 400 and "sideHidden" in r.json()["error"]                       # an old page's write is refused, not kept
    assert c.put("/api/prefs", json={"showTools": True}).status_code == 200
    assert "sideHidden" not in json.loads((settings.state_dir / "prefs.json").read_text())  # the leftover is dropped on the next write


def test_the_page_source_has_no_sidehidden_and_no_hide_button():
    for f in ("app.js", "index.html", "style.css", "shared.js", "sessions.js"):
        text = (STATIC / f).read_text()
        assert "sideHidden" not in text and "side-hidden" not in text and "side-hide" not in text, f


def test_it_goes_as_usual_once_the_new_session_page_is_open_and_the_page_stays(served, browser):
    # the form is a page in the main area now, anchored to nothing: the sidebar peeks and leaves
    # as it does over any other view, and the page stays
    open_wide(browser, served)
    move(browser, 3, 400)
    assert wait_for(browser, OPEN, 5.0)
    new = browser.evaluate("(() => { const r = document.getElementById('side-new').getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()")
    tap_at(browser, new["x"], new["y"])
    assert wait_for(browser, "ns.open && location.hash === '#new'", 5.0)
    move(browser, 1000, 500)                                                                  # the pointer leaves for the page
    assert wait_for(browser, CLOSED, 5.0)
    assert browser.evaluate("ns.open && document.body.classList.contains('new-open')")


def test_a_phone_keeps_its_drawer(served, browser):
    open_app(browser, served, "#sessions", width=390)
    assert browser.evaluate("getComputedStyle(document.getElementById('side-edge')).display") == "none"
    move(browser, 3, 400)
    time.sleep(0.4)
    assert browser.evaluate(CLOSED) and browser.evaluate(BODY) == []                          # the pointer does nothing
    tap_at(browser, *(lambda b: (b["x"], b["y"]))(browser.evaluate(BTN)))
    assert wait_for(browser, OPEN, 5.0) and browser.evaluate(BODY) == ["side-open"]           # the drawer, as before


def test_the_keyboard_brings_it_and_the_wide_rules_are_in_the_stylesheet():
    css = (STATIC / "style.css").read_text()
    assert ":has(:focus-visible)" in css and "#side-edge" in css and "body.side-peek #sidebar" in css and "body.side-pin #sidebar" in css
    wide = css[css.index("@media (min-width: 761px) {\n  :root { --top-h"):]
    assert "#sidebar { position: fixed" in wide.split("@media (max-width")[0]
    assert "#side-open { position: fixed" in wide and ".side-head { position: fixed" in wide   # the one fixed block
