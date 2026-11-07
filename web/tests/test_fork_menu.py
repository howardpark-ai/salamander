"""Fork, in a session row's ⋯ menu (docs/side-sessions.md). The header has no Fork
button because its fold is measured to the pixel (test_header_fold.py, test_board_items_ui.py); the entry lives in a ⋯ at the end
of each sidebar row instead. It is a link to #side=from:<name>, which opens the Quick session form with the fork of that session
filled in (test_side_sessions.py holds the form); nothing is started until Start quick session is pressed there.

What a wrong answer costs: a fork of another session than the row's, a fork offered where it cannot work (a session with no
tmux pane to take a conversation from: the sdk lane's) and failing later, a menu that stays open over the page or opens the session
under it, or a session started by the menu itself. Every check guards one of those. The browser is a headless Chromium at 1280 px
with real DevTools mouse events; api/sessions is a stub; `sala` is the stand-in of test_new_session.py."""

from __future__ import annotations

import json

from test_board_items_ui import wait_for
from test_composer_attach import WAIT_READY
from test_new_session import env, sala  # noqa: F401  (fixtures)

SESS = """(() => {
  const real = window.fetch.bind(window), json = (o) => new Response(JSON.stringify(o), { headers: { "Content-Type": "application/json" } });
  const sess = (n, extra) => ({ pid: 1, sessionId: n, name: n, cwd: "/x", status: "idle", tmux: "x:@0.%%0", tmuxSession: n, paneId: "%%0",
                                role: "front", project: "projects/alpha", lane: "subscription-1", updatedAt: null, startedAt: null, ...extra });
  window.fetch = (url, opts) => {
    const u = String(url);
    if (u.startsWith("api/sessions")) {
      const sessions = [sess("example-alpha-main"), sess("example-alpha-main-side-onyx07"), sess("example-alpha-sdk", { lane: "sdk", tmux: "", tmuxSession: "", paneId: "" }),
                        sess("example-alpha-api", { lane: "api" })];
      const groups = [{ key: "projects/alpha", title: "alpha", scope: "example", sessions }];
      return Promise.resolve(json({ scopes: [{ key: "example", title: "example", groups }], groups, rolesError: null }));
    }
    if (u.startsWith("api/board-items")) return Promise.resolve(json({ sessions: {}, fetchedAt: Date.now() }));
    return real(url, opts);
  };
})();"""
ROWS = "[...document.querySelectorAll('#session-list .sess')].map((r) => ({ name: r.dataset.key, more: !!r.querySelector('.sess-more') }))"
SIDE_IN = "document.getElementById('sidebar').getBoundingClientRect().left === 0"
MENU = """(() => { const m = document.querySelector('.row-menu'); if (!m) return null; const r = m.getBoundingClientRect();
  return { role: m.getAttribute('role'), label: m.getAttribute('aria-label'), box: r.toJSON(), vw: innerWidth, vh: innerHeight,
           items: [...m.querySelectorAll('[role=menuitem]')].map((a) => ({ text: a.querySelector('span').textContent, href: a.getAttribute('href') })) }; })()"""


def open_list(browser, served) -> None:
    """The sidebar pinned open at 1280 x 800. `browser.open()` emulates a phone, so the desktop viewport is set here and the page is
    loaded after it. Headless Chromium reports `hover: none` and `pointer: fine` either way, which is why the stylesheet's touch rule
    is `(pointer: coarse) and (hover: none)`, the repo's own phone test, and does not apply in the harness."""
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": SESS})
    browser.width, browser.height = 1280, 800
    # browser.open() emulates a phone before it navigates; a hovering desktop is set up the same way, before the page loads
    browser.send("Emulation.setDeviceMetricsOverride", {"width": 1280, "height": 800, "deviceScaleFactor": 1, "mobile": False})
    browser.send("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-color-scheme", "value": "dark"}]})
    browser.send("Page.navigate", {"url": f"{served['url']}/#new"})
    assert browser.evaluate(WAIT_READY)
    browser.evaluate("document.querySelector('#side-open').click(); ''")
    assert wait_for(browser, SIDE_IN, 5.0)
    assert wait_for(browser, "document.querySelectorAll('#session-list .sess').length === 4", 5.0), browser.evaluate(ROWS)


def box(browser, sel: str) -> dict:
    return browser.evaluate(f"(() => {{ const r = document.querySelector({json.dumps(sel)}).getBoundingClientRect(); return {{ x: r.x + r.width / 2, y: r.y + r.height / 2, w: r.width, h: r.height }}; }})()")


def row_sel(name: str, more: bool = False) -> str:
    return f'#session-list .sess[data-key="{name}"]' + (" .sess-more" if more else "")


def hover(browser, name: str) -> None:
    b = box(browser, row_sel(name))
    browser.send("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": b["x"] - 30, "y": b["y"]})


def click_at(browser, x: float, y: float) -> None:
    for t in ("mousePressed", "mouseReleased"):
        browser.send("Input.dispatchMouseEvent", {"type": t, "x": x, "y": y, "button": "left", "clickCount": 1})


def test_the_menu_button_is_on_the_rows_that_can_be_forked_only(sala, served, browser):
    open_list(browser, served)
    rows = {r["name"]: r["more"] for r in browser.evaluate(ROWS)}
    # a session with a pane takes a fork, a quick session too (lib/spawn.sh cuts the new name at the earlier -side-); the sdk lane's session has no pane
    assert rows == {"example-alpha-main": True, "example-alpha-main-side-onyx07": True, "example-alpha-sdk": False, "example-alpha-api": True}, rows
    # shown when the pointer is on the row, not before
    assert browser.evaluate(f"getComputedStyle(document.querySelector({json.dumps(row_sel('example-alpha-main', True))})).display") == "none"
    hover(browser, "example-alpha-main")
    assert browser.evaluate(f"getComputedStyle(document.querySelector({json.dumps(row_sel('example-alpha-main', True))})).display") != "none"
    b = box(browser, row_sel("example-alpha-main", True))
    assert b["h"] >= 18 and b["w"] >= 18, b
    assert browser.evaluate(f"document.querySelector({json.dumps(row_sel('example-alpha-main', True))}).getAttribute('aria-label')") == "Actions for example-alpha-main"


def test_the_menu_offers_fork_and_the_link_opens_the_quick_session_form_for_that_session(sala, served, browser):
    open_list(browser, served)
    h0 = browser.evaluate("location.hash")
    hover(browser, "example-alpha-main")
    b = box(browser, row_sel("example-alpha-main", True))
    click_at(browser, b["x"], b["y"])
    assert wait_for(browser, "document.querySelector('.row-menu') !== null", 5.0)
    m = browser.evaluate(MENU)
    assert m["role"] == "menu" and m["label"] == "Actions for example-alpha-main" and m["items"] == [{"text": "Fork", "href": "#side=from:example-alpha-main"}], m
    assert 0 <= m["box"]["left"] and m["box"]["right"] <= m["vw"] and m["box"]["bottom"] <= m["vh"], m   # whole on the screen
    assert browser.evaluate(f"document.querySelector({json.dumps(row_sel('example-alpha-main', True))}).getAttribute('aria-expanded')") == "true"
    assert browser.evaluate("location.hash") == h0, "opening the menu also followed the row's link"
    # the entry: the page goes to the Quick session form with the fork of THAT session in it, and starts nothing
    it = box(browser, ".row-menu-item")
    click_at(browser, it["x"], it["y"])
    assert wait_for(browser, "document.body.classList.contains('side-mode') && document.querySelector('#sd-fork').value !== ''", 8.0)
    g = browser.evaluate("""({ hash: location.hash, fork: document.querySelector('#sd-fork').value, item: document.querySelector('#sd-item').value,
      summary: document.querySelector('#sd-fork-pick .ns-sum').textContent, menu: !!document.querySelector('.row-menu'), title: document.querySelector('#title .name').textContent })""")
    assert g["hash"] == "#side=from:example-alpha-main" and g["fork"] == "example-alpha-main" and g["item"] == "" and not g["menu"], g
    assert "example-alpha-main" in g["summary"] and g["title"] == "Quick session", g
    assert wait_for(browser, "document.querySelector('#sd-name').value === 'example-alpha-main-side-wren42'", 8.0)
    assert sala.spawns() == []                              # nothing started by the menu: the form's Start button does that


def test_the_menu_of_a_quick_session_forks_it_too(sala, served, browser):
    open_list(browser, served)
    hover(browser, "example-alpha-main-side-onyx07")
    b = box(browser, row_sel("example-alpha-main-side-onyx07", True))
    click_at(browser, b["x"], b["y"])
    assert wait_for(browser, "document.querySelector('.row-menu') !== null", 5.0)
    assert browser.evaluate(MENU)["items"][0]["href"] == "#side=from:example-alpha-main-side-onyx07"


def test_escape_a_click_elsewhere_and_a_second_click_close_it_and_the_keyboard_opens_it(sala, served, browser):
    open_list(browser, served)
    hover(browser, "example-alpha-main")
    b = box(browser, row_sel("example-alpha-main", True))
    click_at(browser, b["x"], b["y"])
    assert wait_for(browser, "document.querySelector('.row-menu') !== null", 5.0)
    click_at(browser, b["x"], b["y"])                                    # the button again
    assert wait_for(browser, "document.querySelector('.row-menu') === null", 5.0)
    click_at(browser, b["x"], b["y"])
    assert wait_for(browser, "document.querySelector('.row-menu') !== null", 5.0)
    click_at(browser, 900, 500)                                          # the page
    assert wait_for(browser, "document.querySelector('.row-menu') === null", 5.0)
    # the keyboard: Enter on the focused button opens it with the first entry focused, Escape closes it and gives the focus back
    # (the row is focused first: that is what shows its ⋯, as a keyboard user's Tab does, then Tab moves onto the button)
    browser.evaluate(f"document.querySelector({json.dumps(row_sel('example-alpha-api'))}).focus(); document.querySelector({json.dumps(row_sel('example-alpha-api', True))}).focus(); ''")
    browser.send("Input.dispatchKeyEvent", {"type": "keyDown", "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13, "text": "\r"})
    browser.send("Input.dispatchKeyEvent", {"type": "keyUp", "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13})
    assert wait_for(browser, "document.querySelector('.row-menu') !== null && document.activeElement.classList.contains('row-menu-item')", 5.0)
    assert browser.evaluate("document.querySelector('.row-menu-item').getAttribute('href')") == "#side=from:example-alpha-api"
    browser.send("Input.dispatchKeyEvent", {"type": "keyDown", "key": "Escape", "code": "Escape", "windowsVirtualKeyCode": 27})
    browser.send("Input.dispatchKeyEvent", {"type": "keyUp", "key": "Escape", "code": "Escape", "windowsVirtualKeyCode": 27})
    assert wait_for(browser, "document.querySelector('.row-menu') === null && document.activeElement.classList.contains('sess-more')", 5.0)


def test_on_a_touch_screen_the_button_is_only_on_the_open_session(sala, served, browser):
    """Nothing hovers on a phone, and a tap leaves a sticky hover: the ⋯ is shown on the open session's row only, so the list is
    not a column of dots."""
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": SESS})
    browser.width, browser.height = 390, 844
    browser.open(f"{served['url']}/#s=example-alpha-api", dark=True)
    assert browser.evaluate(WAIT_READY)
    browser.evaluate("document.querySelector('#side-open').click(); ''")
    assert wait_for(browser, "document.querySelectorAll('#session-list .sess').length === 4", 8.0)
    vis = browser.evaluate("[...document.querySelectorAll('#session-list .sess')].map((r) => [r.dataset.key, r.classList.contains('selected'), r.querySelector('.sess-more') ? getComputedStyle(r.querySelector('.sess-more')).display !== 'none' : null])")
    assert vis == [["example-alpha-main", False, False], ["example-alpha-main-side-onyx07", False, False], ["example-alpha-sdk", False, None], ["example-alpha-api", True, True]], vis
    b = box(browser, row_sel("example-alpha-api", True))
    assert b["h"] >= 18 and b["w"] >= 20, b   # 18px tall like the board mark: under the row's line, so showing it moves nothing
    # the rule that keeps a tapped row from showing a sticky ⋯ is a media query headless Chromium cannot satisfy (it reports a fine
    # pointer even as a phone), so the stylesheet is what is held: hover and focus show it, and a coarse touch screen hides the hover
    import urllib.request
    css = urllib.request.urlopen(f"{served['url']}/static/style.css").read().decode()
    assert ".sess:hover .sess-more" in css and "@media (pointer: coarse) and (hover: none) { .sess:hover:not(.selected) .sess-more" in css


def test_the_session_header_has_nothing_added_for_it(sala, served, browser):
    """Fork is not in the header (its fold is measured to the pixel); the header's own ⋯ stays the one for what folded out of the bar."""
    open_list(browser, served)
    assert browser.evaluate("document.querySelectorAll('#top .sess-more, #top .row-menu, #top [href^=\"#side=\"]').length") == 0
    assert browser.evaluate("[...document.querySelectorAll('#top-tools [href]')].length") == 0
