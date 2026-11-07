"""What Back does (revised twice). The rules (`app.js`, "selection, hash, history"; `web/README.md`, *Back*):

- two modes, read live at every decision: REPLACE on a phone (max-width 760px) in any browser and in the installed app
  (display-mode standalone) at any width, PUSH in a desktop or tablet browser or a phone wider than 760px;
- replace mode: the sessions and the Overview are peer views of ONE history entry (no history between them); Back closes
  the open layer (the sidebar drawer, the one layer there is), one Back (the New session page, #new, is a view with
  an entry of its own in either mode, so Back returns from it); nothing open:
  Back leaves sala; nothing intercepts that Back (no beforeunload);
- push mode: every view is an entry, so Back and Forward walk the sessions visited; the sidebar is part of the page, so there is no layer at all;
- a layer closed another way (scrim, close button, Escape) has its entry popped at once; a navigation with layers open
  goes back under them first; the entries popped stay ahead as Forward entries and Forward re-opens their layers over the
  view shown (the items sheet that was a second layer was removed Thu Nov 5th 2026: an entry of an earlier build that lists one reads as no layer);
- sala opens on the view it was last on (a session still live, else the Overview) with the sidebar closed, in replace
  mode; a deep link wins; a reload with layers recorded leaves them, so Back leaves with no dead entry under it;
- the composer's unsent text is kept per session, the box emptied when the owner leaves the session (it was sent to the
  wrong session before), and kept over a reload, a closed app and an Overview round trip; sending clears it;
- Chat/Terminal and the ⋯ menu touch no history; the keyboard going up or down closes no layer.

The rule's first loss applies: a Back that leaves sala from a session, walks between views, or closes nothing drops
the owner out of the conversation he was in (the installed app exits) or leaves him in a layer he cannot put away one-handed.
Driven in a headless Chromium with the browser's own history: real taps over DevTools `Input` events (user activation, as
a finger gives), `history.back()`/`forward()`, `Page.getNavigationHistory` for the entries and the position,
`Page.reload`, the installed app (`display-mode: standalone`) emulated in the page, as DevTools has no such feature; a sentinel page is navigated before sala
so that leaving it can be asserted. The three APIs are stubbed as in `test_board_items_ui.py` (several sessions, a board
with items), the fake live session carries the chat.
"""

from __future__ import annotations

import json
import re
import time
from pathlib import Path

import pytest

from test_board_items_ui import BOARD, FAKE, NAMES, PIDS, stub, wait_for, wait_side

A, B, C = FAKE, "demo", "gamma-quiet"
SENTINEL = "/manifest.webmanifest"   # a document of the same origin, before sala in the tab's history
LAST = "salaweb.lastView"
APP_JS = Path(__file__).resolve().parents[1] / "src" / "sala_web" / "static" / "app.js"

# DevTools cannot emulate display-mode (Chromium 155: no such media feature in Emulation.setEmulatedMedia, no
# setDisplayModeOverride), so the installed app is emulated where the page asks: its (display-mode: standalone) query
# answers true, every other query is the browser's
STANDALONE = """(() => { const real = window.matchMedia.bind(window);
  window.matchMedia = (q) => { const m = real(q); if (!/display-mode:\\s*standalone/.test(q)) return m;
    return new Proxy(m, { get: (t, k) => (k === "matches" ? true : typeof t[k] === "function" ? t[k].bind(t) : t[k]) }); }; })();"""

# the list drawn, no layers of an earlier page still being walked back over (a reload with layers)
READY = """typeof nav !== 'undefined' && !!nav.cur && nav.reload === 0 && document.querySelectorAll('#session-list .sess').length === %d""" % len(NAMES)
# no history step in flight, and the drawer not mid-slide (.18 s; a tap meanwhile would land on it)
SETTLED = """typeof nav === 'undefined' || (!nav.busy && nav.pending === null && nav.reload === 0
  && (() => { const r = document.getElementById("sidebar").getBoundingClientRect();
              return innerWidth > 760 || (document.body.classList.contains("side-open") ? r.left === 0 : r.right <= 0); })())"""
PAGE = """(() => typeof nav === 'undefined' ? { sala: false, href: location.href, hash: location.hash, len: history.length } : {
  sala: true, href: location.href, hash: location.hash, len: history.length, state: history.state && history.state.sala,
  overview: document.body.classList.contains("overview-open"), selected: state.selected,
  drawer: document.body.classList.contains("side-open"), newOpen: ns.open, msgs: document.querySelectorAll("#chat > .msg").length,
  name: document.querySelector("#title .name").textContent, tab: state.tab, replace: replaceMode(),
  active: document.activeElement && (document.activeElement.id || document.activeElement.className) })()"""


def open_app(browser, served, hash_: str, width: int = 390, standalone: bool = False, remembered: str | None = None) -> None:
    """The sentinel first (its storage emptied, then `remembered` as the last view when given), then sala at `hash_`;
    the page is ready (the list rendered, the record made)."""
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": stub(PIDS, BOARD)})
    browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 844, "deviceScaleFactor": 1, "mobile": width <= 760})
    browser.send("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-color-scheme", "value": "dark"}]})
    if standalone:
        browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": STANDALONE})
    browser.send("Page.navigate", {"url": served["url"] + SENTINEL})
    assert wait_for(browser, f"location.pathname === {json.dumps(SENTINEL)}")
    browser.evaluate(f"localStorage.clear(); sessionStorage.clear(); {('localStorage.setItem(%s, %s);' % (json.dumps(LAST), json.dumps(remembered))) if remembered else ''} ''")
    browser.send("Page.navigate", {"url": f"{served['url']}/{hash_}"})
    assert wait_for(browser, READY)
    settle(browser)


def settle(browser) -> None:
    assert wait_for(browser, SETTLED, 5.0), browser.evaluate(PAGE)
    browser.evaluate("new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))")


def hist(browser) -> dict:
    """The page (PAGE) with the tab's history: `entries` the hashes of sala's entries after the sentinel (the Forward
    entries a Back leaves included, until a push truncates them), `past` those up to the current one, `i` the position
    (0 the first), `left` when the tab is on the sentinel."""
    h = browser.send("Page.getNavigationHistory")
    urls = [e["url"] for e in h["entries"]]
    s = max(i for i, u in enumerate(urls) if u.endswith(SENTINEL))
    got = browser.evaluate(PAGE)
    if got["sala"] and got["selected"] == FAKE and not got["msgs"]:   # the fake session's chat arrives over the stream: wait for it
        wait_for(browser, "document.querySelectorAll('#chat > .msg').length >= 1", 10.0)
        got = browser.evaluate(PAGE)
    got["entries"] = [u[u.index("#"):] if "#" in u else "" for u in urls[s + 1:]]
    got["i"] = h["currentIndex"] - s - 1
    got["past"] = got["entries"][:got["i"] + 1]
    got["left"] = h["currentIndex"] == s
    return got


def travel(browser, n: int) -> dict:
    """history.go(n), waited for (the traversal is asynchronous), then settled."""
    before = browser.send("Page.getNavigationHistory")["currentIndex"]
    browser.evaluate(f"history.go({n}); ''")
    end = time.time() + 5
    while time.time() < end:
        try:   # a traversal to another document has a moment with no active page to ask
            if browser.send("Page.getNavigationHistory")["currentIndex"] == before + n and browser.evaluate("true"):
                break
        except RuntimeError:
            pass
        time.sleep(0.02)
    else:
        raise AssertionError(f"history.go({n}) did not move from {before}: {hist(browser)}")
    settle(browser)
    return hist(browser)


back = lambda browser: travel(browser, -1)  # noqa: E731
forward = lambda browser: travel(browser, 1)  # noqa: E731


def tap_at(browser, x: float, y: float) -> None:
    for t in ("mousePressed", "mouseReleased"):
        browser.send("Input.dispatchMouseEvent", {"type": t, "x": x, "y": y, "button": "left", "clickCount": 1})
    settle(browser)


SIDE_IN = "document.getElementById('sidebar').getBoundingClientRect().left === 0"
SIDE_OUT = "document.getElementById('sidebar').getBoundingClientRect().right <= 0"


def mouse_to(browser, x: float, y: float) -> None:
    browser.send("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": x, "y": y})


def wide_side(browser, sel: str) -> None:
    """On a wide window the sidebar is over the page and closed: a target in it is reached the way a person
    does, the pointer on the left edge brings it in; a target elsewhere with the pointer away from it, so the sidebar is
    not over the target (a sidebar pinned by a click stays, and is the test's own business)."""
    if not browser.evaluate("innerWidth > 760"):
        return
    if browser.evaluate(f"!!document.querySelector({json.dumps(sel)}).closest('#sidebar')"):
        mouse_to(browser, 3, 400)
        assert wait_for(browser, SIDE_IN, 5.0), sel
    elif not browser.evaluate("document.body.classList.contains('side-pin')"):
        mouse_to(browser, browser.evaluate("innerWidth") - 3, 400)
        assert wait_for(browser, SIDE_OUT, 5.0), sel


def tap(browser, sel: str) -> None:
    """A real click (DevTools Input, user activation) at the element's centre."""
    wide_side(browser, sel)
    box =browser.evaluate(f"""(() => {{ const e = document.querySelector({json.dumps(sel)}); e.scrollIntoView({{ block: "nearest" }});
      const r = e.getBoundingClientRect(); return {{ x: r.x + r.width / 2, y: r.y + r.height / 2, w: r.width, h: r.height, vis: getComputedStyle(e).display !== "none" }}; }})()""")
    assert box["w"] > 0 and box["h"] > 0 and box["vis"], (sel, box)
    tap_at(browser, box["x"], box["y"])


def key(browser, k: str, code: int) -> None:
    browser.send("Input.dispatchKeyEvent", {"type": "keyDown", "key": k, "code": k, "windowsVirtualKeyCode": code})
    browser.send("Input.dispatchKeyEvent", {"type": "keyUp", "key": k, "code": k, "windowsVirtualKeyCode": code})
    settle(browser)


def open_drawer(browser) -> None:
    tap(browser, "#side-open")
    wait_side(browser)


def row(name: str) -> str:
    return f"#session-list .sess[href='#s={name}']"


def table(name: str) -> str:
    return f"#sp-table a[href='#s={name}']"


def in_session(h: dict, name: str) -> None:
    assert h["sala"] and h["hash"] == f"#s={name}" and h["selected"] == name and not h["overview"], h
    assert not h["drawer"], h
    if name == FAKE:
        assert h["msgs"] >= 1, h   # the chat is there, not an empty pane


def on_overview(h: dict) -> None:
    assert h["sala"] and h["hash"] == "#sessions" and h["overview"] and h["selected"] is None, h


def one_entry(h: dict, view: str, layers=()) -> None:
    """Replace mode: the view is the one entry sala has (the entry the app was opened at), `layers` on top of it."""
    assert h["past"] == [view] * (1 + len(layers)) and h["i"] == len(layers) and h["state"]["layers"] == list(layers), h


# ---------- a phone (replace mode) ----------

def test_on_a_phone_the_sessions_and_the_overview_are_peer_views_of_one_entry_and_one_back_leaves(served, browser):
    open_app(browser, served, f"#s={A}")
    h = hist(browser)
    in_session(h, A)
    assert h["replace"] and h["entries"] == [f"#s={A}"] and h["len"] == 3 and h["state"]["layers"] == [], h   # about:blank, the sentinel, sala
    # A → B → C through the drawer: each replaces the one entry (the drawer's own entry is popped first)
    for name in (B, C):
        open_drawer(browser)
        tap(browser, row(name))
        h = hist(browser)
        in_session(h, name)
        one_entry(h, f"#s={name}")
    # the Overview is a peer view: the drawer's row replaces the entry too, the Overview's table opens a session the same way
    open_drawer(browser)
    tap(browser, "#side-ovw")
    h = hist(browser)
    on_overview(h)
    one_entry(h, "#sessions")
    n = h["len"]
    tap(browser, table(A))
    h = hist(browser)
    in_session(h, A)
    one_entry(h, f"#s={A}")
    assert h["len"] == n, h   # a navigation that opens no layer adds no entry at all
    # nothing open: one Back leaves sala for the page before it
    h = back(browser)
    assert h["left"] and not h["sala"] and h["href"].endswith(SENTINEL), h


def test_back_from_the_overview_leaves_and_the_overview_counts_as_a_session_view(served, browser):
    open_app(browser, served, "#sessions")
    h = hist(browser)
    on_overview(h)
    assert h["entries"] == ["#sessions"] and h["len"] == 3, h
    # the drawer opened on the Overview closes on Back and the Overview stays
    open_drawer(browser)
    h = hist(browser)
    assert h["drawer"] and h["state"]["layers"] == ["drawer"] and h["i"] == 1, h
    h = back(browser)
    on_overview(h)
    assert not h["drawer"] and h["i"] == 0, h
    assert back(browser)["left"]


def test_back_closes_the_drawer_and_stays_and_a_row_tapped_in_it_leaves_no_stale_entry(served, browser):
    open_app(browser, served, f"#s={A}")
    open_drawer(browser)
    h = hist(browser)
    assert h["drawer"] and h["past"] == [f"#s={A}"] * 2 and h["i"] == 1 and h["state"]["layers"] == ["drawer"] and h["active"] == "side-close", h
    h = back(browser)   # Back on the sidebar-open view closes the sidebar, it does not exit the app
    in_session(h, A)
    one_entry(h, f"#s={A}")
    assert not h["left"] and wait_for(browser, "document.getElementById('sidebar').getBoundingClientRect().right <= 0", 5.0)   # slid away
    # the scrim and the close button pop the entry
    open_drawer(browser)
    tap_at(browser, 350, 500)   # right of the 300px drawer
    h = hist(browser)
    assert not h["drawer"], h
    one_entry(h, f"#s={A}")
    open_drawer(browser)
    tap(browser, "#side-close")
    h = hist(browser)
    assert not h["drawer"] and h["active"] == "side-open", h   # the focus back on the button that opened it
    one_entry(h, f"#s={A}")
    # a row in the drawer: the drawer's entry is popped, the one entry is replaced; no stale entry is left under it
    open_drawer(browser)
    tap(browser, row(B))
    h = hist(browser)
    in_session(h, B)
    one_entry(h, f"#s={B}")
    # the open session's own row: nothing changes
    open_drawer(browser)
    tap(browser, row(B))
    h = hist(browser)
    in_session(h, B)
    one_entry(h, f"#s={B}")
    assert back(browser)["left"]   # one Back leaves, however many sessions were opened


def test_a_navigation_with_layers_open_goes_back_under_them_first_and_forward_reopens_them_over_the_view_shown(served, browser):
    open_app(browser, served, f"#s={A}")
    open_drawer(browser)
    tap(browser, row(B))
    h = hist(browser)
    in_session(h, B)
    one_entry(h, f"#s={B}")
    assert h["entries"] == [f"#s={B}", f"#s={A}"], h   # the drawer's entry, popped, stays ahead as a Forward entry (A's URL)
    # Forward: the entry keeps the view that is shown and re-opens its drawer over it
    h = forward(browser)
    assert h["selected"] == B and h["hash"] == f"#s={B}" and h["drawer"] and h["state"]["layers"] == ["drawer"], h
    assert back(browser)["selected"] == B


def test_a_reload_with_layers_open_leaves_them_and_one_back_leaves(served, browser):
    open_app(browser, served, f"#s={A}")
    open_drawer(browser)
    assert hist(browser)["i"] == 1
    browser.send("Page.reload")
    assert wait_for(browser, READY)
    settle(browser)
    # the walk back over the dead entries was a same-document traversal: the page is the one the reload made
    assert browser.evaluate("performance.getEntriesByType('navigation')[0].type") == "reload"
    h = hist(browser)
    in_session(h, A)   # not open, not a dead entry to back out of
    assert h["i"] == 0 and h["state"]["layers"] == [], h
    assert back(browser)["left"]


def test_a_launch_with_no_view_opens_the_last_view_with_the_sidebar_closed(served, browser):
    # a session still live
    open_app(browser, served, "", remembered=f"#s={B}")
    h = hist(browser)
    in_session(h, B)
    assert h["replace"] and h["entries"] == [f"#s={B}"] and h["len"] == 3 and h["state"]["layers"] == [] and not h["drawer"], h
    wait_for(browser, "document.getElementById('sidebar').getBoundingClientRect().right <= 0")
    # written into the launch entry: a reload keeps it, and Back leaves
    browser.send("Page.reload")
    assert wait_for(browser, READY)
    settle(browser)
    h = hist(browser)
    in_session(h, B)
    assert h["entries"] == [f"#s={B}"], h
    assert back(browser)["left"]
    # the Overview, remembered or nothing remembered
    open_app(browser, served, "", remembered="#sessions")
    h = hist(browser)
    on_overview(h)
    assert h["entries"] == ["#sessions"] and not h["drawer"], h
    open_app(browser, served, "")
    h = hist(browser)
    on_overview(h)
    assert h["entries"] == ["#sessions"] and not h["drawer"], h
    # a remembered session that is gone
    open_app(browser, served, "", remembered="#s=gone-for-good")
    h = hist(browser)
    on_overview(h)
    assert h["entries"] == ["#sessions"], h
    # a deep link wins over what was remembered
    open_app(browser, served, f"#s={C}", remembered=f"#s={B}")
    in_session(hist(browser), C)
    open_app(browser, served, "#sessions", remembered=f"#s={B}")
    on_overview(hist(browser))


def test_every_view_is_remembered_for_the_next_launch(served, browser):
    open_app(browser, served, f"#s={A}")
    get = f"localStorage.getItem({json.dumps(LAST)})"
    assert browser.evaluate(get) == f"#s={A}"
    open_drawer(browser)
    tap(browser, "#side-ovw")
    assert browser.evaluate(get) == "#sessions"
    tap(browser, table(B))
    assert browser.evaluate(get) == f"#s={B}"


def test_a_session_link_that_outlived_its_session_has_a_way_to_the_overview(served, browser):
    open_app(browser, served, "#s=gone-for-good")
    h = hist(browser)
    assert h["selected"] == "gone-for-good" and "not live" in browser.evaluate("document.querySelector('#chat .empty').textContent"), h
    tap(browser, "#chat .empty a")
    h = hist(browser)
    on_overview(h)
    one_entry(h, "#sessions")
    assert back(browser)["left"]


def test_a_hash_set_from_outside_is_taken_as_the_browser_made_it_and_a_link_in_the_page_follows_the_rules(served, browser):
    open_app(browser, served, f"#s={A}")
    # the address bar or a script: the browser's own push, recorded as it is
    browser.evaluate(f"location.hash = '#s={B}'; ''")
    assert wait_for(browser, f"state.selected === {json.dumps(B)}")
    settle(browser)
    h = hist(browser)
    in_session(h, B)
    assert h["entries"] == [f"#s={A}", f"#s={B}"] and h["i"] == 1 and h["state"]["layers"] == [], h
    # a link in the page (here put into the chat) is sala's: the entry is replaced, none added
    browser.evaluate(f"""const a = document.createElement("a"); a.href = "#s={C}"; a.id = "probe-link"; a.textContent = "C";
      document.getElementById("chat").append(a); ''""")
    browser.evaluate("document.getElementById('probe-link').click(); ''")
    settle(browser)
    h = hist(browser)
    in_session(h, C)
    assert h["entries"] == [f"#s={A}", f"#s={C}"] and h["i"] == 1, h
    # Back shows the entry below, then leaves
    in_session(back(browser), A)
    assert back(browser)["left"]


def test_widening_the_window_pops_the_drawer_entry_and_the_next_navigation_pushes(served, browser):
    open_app(browser, served, f"#s={A}")
    open_drawer(browser)
    assert hist(browser)["i"] == 1
    browser.send("Emulation.setDeviceMetricsOverride", {"width": 1280, "height": 844, "deviceScaleFactor": 1, "mobile": False})
    assert wait_for(browser, "innerWidth === 1280")
    settle(browser)
    h = hist(browser)
    in_session(h, A)
    assert h["i"] == 0 and not h["replace"], h
    # the mode is read at the decision: at 1280 in a browser a row pushes; the entries made before stay
    tap(browser, row(B))
    h = hist(browser)
    in_session(h, B)
    assert h["entries"] == [f"#s={A}", f"#s={B}"] and h["i"] == 1, h
    in_session(back(browser), A)
    # and back to a phone's width: a row replaces the entry it stands on
    browser.send("Emulation.setDeviceMetricsOverride", {"width": 390, "height": 844, "deviceScaleFactor": 1, "mobile": True})
    assert wait_for(browser, "innerWidth === 390")
    settle(browser)
    open_drawer(browser)
    tap(browser, row(C))
    h = hist(browser)
    in_session(h, C)
    one_entry(h, f"#s={C}")
    assert back(browser)["left"]


def test_the_chat_terminal_toggle_and_the_view_menu_touch_no_history(served, browser):
    open_app(browser, served, f"#s={A}")
    before = hist(browser)
    n = browser.evaluate("history.length")
    tap(browser, "#top-menu-btn")
    tap(browser, ".tab[data-tab=terminal]")
    h = hist(browser)
    assert h["tab"] == "terminal" and h["entries"] == before["entries"] and h["i"] == before["i"] and h["state"] == before["state"], h
    assert browser.evaluate("history.length") == n
    tap(browser, "#top-menu-btn")
    tap(browser, ".tab[data-tab=chat]")
    h = hist(browser)
    assert h["tab"] == "chat" and h["entries"] == before["entries"] and h["state"] == before["state"], h
    assert back(browser)["left"]   # one Back, as if the toggle never happened


def test_the_keyboard_going_up_and_down_closes_no_layer(served, browser):
    open_app(browser, served, f"#s={A}")
    open_drawer(browser)
    assert hist(browser)["state"]["layers"] == ["drawer"]
    # the keyboard up (the viewport's height drops), a field blurred, the keyboard down: the layer is where it was
    browser.send("Emulation.setDeviceMetricsOverride", {"width": 390, "height": 450, "deviceScaleFactor": 1, "mobile": True})
    browser.evaluate("document.activeElement && document.activeElement.blur(); window.dispatchEvent(new Event('resize')); ''")
    settle(browser)
    h = hist(browser)
    assert h["drawer"] and h["state"]["layers"] == ["drawer"] and h["i"] == 1, h
    browser.send("Emulation.setDeviceMetricsOverride", {"width": 390, "height": 844, "deviceScaleFactor": 1, "mobile": True})
    settle(browser)
    h = hist(browser)
    assert h["drawer"] and h["i"] == 1, h


def test_escape_closes_the_layer_and_then_has_nothing_to_close(served, browser):
    open_app(browser, served, f"#s={A}")
    open_drawer(browser)
    assert hist(browser)["state"]["layers"] == ["drawer"]
    key(browser, "Escape", 27)
    h = hist(browser)
    in_session(h, A)
    assert h["i"] == 0 and h["active"] == "side-open", h   # the focus back on the button that opened the drawer
    key(browser, "Escape", 27)   # nothing open: nothing to close, nothing to leave
    assert not hist(browser)["left"]


def test_no_beforeunload_handler_stands_between_back_and_leaving(served, browser):
    open_app(browser, served, f"#s={A}")
    open_drawer(browser)
    tap(browser, "#side-close")
    r = browser.send("Runtime.evaluate", {"expression": "getEventListeners(window).beforeunload", "includeCommandLineAPI": True, "returnByValue": True})
    assert r["result"].get("type") == "undefined", r   # no listener registered
    assert browser.evaluate("window.onbeforeunload === null")
    assert not re.search(r"""addEventListener\(\s*["']beforeunload|onbeforeunload\s*=""", APP_JS.read_text())


def test_a_rapid_double_back_closes_the_layer_and_the_second_leaves(served, browser):
    open_app(browser, served, f"#s={A}")
    open_drawer(browser)
    assert hist(browser)["state"]["layers"] == ["drawer"]
    browser.evaluate("history.back(); history.back(); ''")   # the drawer, then sala
    assert wait_for(browser, f"location.pathname === {json.dumps(SENTINEL)}", 5.0)


def test_an_entry_of_the_first_build_is_read_as_no_layers(served, browser):
    open_app(browser, served, f"#s={A}")
    browser.evaluate("""history.replaceState({ sala: { depth: 1, base: "#sessions", overlays: ["drawer"], idx: 5 } }, ""); ''""")
    browser.send("Page.reload")
    assert wait_for(browser, READY)
    settle(browser)
    h = hist(browser)
    in_session(h, A)
    assert not h["drawer"] and h["i"] == 0 and browser.evaluate("nav.cur.layers.length") == 0, h
    open_drawer(browser)   # and the next entry it makes is in the new shape
    assert hist(browser)["state"]["layers"] == ["drawer"]


def test_an_entry_that_lists_the_removed_items_sheet_is_read_as_no_layer(served, browser):
    """The items sheet was a layer until Thu Nov 5th 2026: the history of a tab that was open before the change may hold its entries.
    The record is read without it: nothing opens, nothing is left to back out of."""
    open_app(browser, served, f"#s={A}")
    browser.evaluate(f"""history.replaceState({{ sala: {{ layers: [{{ sheet: {json.dumps(A)} }}], idx: 5 }} }}, ""); ''""")
    browser.send("Page.reload")
    assert wait_for(browser, READY)
    settle(browser)
    h = hist(browser)
    in_session(h, A)
    assert not h["drawer"] and h["i"] == 0 and browser.evaluate("nav.cur.layers.length") == 0, h
    assert back(browser)["left"]


# ---------- the installed app ----------

def test_the_installed_app_at_a_tablet_or_desktop_width_replaces_like_a_phone(served, browser):
    open_app(browser, served, f"#s={A}", width=1280, standalone=True)
    h = hist(browser)
    in_session(h, A)
    assert h["replace"] and h["state"]["layers"] == [], h
    tap(browser, row(B))   # the sidebar is part of the page at this width: a row is a tap away
    tap(browser, row(C))
    h = hist(browser)
    in_session(h, C)
    one_entry(h, f"#s={C}")
    tap(browser, "#side-ovw")
    h = hist(browser)
    on_overview(h)
    one_entry(h, "#sessions")
    # no drawer layer on a wide screen, and no other layer: the session is the one entry, one Back leaves
    tap(browser, table(A))
    h = hist(browser)
    in_session(h, A)
    one_entry(h, f"#s={A}")
    assert back(browser)["left"]
    # a launch with no view opens the last one here as well
    open_app(browser, served, "", width=1280, standalone=True, remembered=f"#s={B}")
    in_session(hist(browser), B)


# ---------- a desktop browser (push mode) ----------

def test_a_desktop_browser_pushes_a_view_per_entry_and_back_walks_the_sessions_visited(served, browser):
    open_app(browser, served, "#sessions", width=1280)
    h = hist(browser)
    on_overview(h)
    assert not h["replace"], h
    for name in (A, B, C):
        tap(browser, row(name))   # the sidebar is static on a desktop: a row is a tap away
    h = hist(browser)
    in_session(h, C)
    assert h["entries"] == ["#sessions", f"#s={A}", f"#s={B}", f"#s={C}"] and h["i"] == 3, h
    # the same session again is no new entry
    tap(browser, row(C))
    assert hist(browser)["i"] == 3
    in_session(back(browser), B)
    in_session(back(browser), A)
    on_overview(back(browser))
    in_session(forward(browser), A)
    # the Overview is a view of its own and pushes too
    tap(browser, "#side-ovw")
    h = hist(browser)
    on_overview(h)
    assert h["entries"] == ["#sessions", f"#s={A}", "#sessions"] and h["i"] == 2, h   # the push cut the Forward entries
    in_session(back(browser), A)
    # nothing is laid over the view in push mode (the items popover that was a layer here was removed): no layer in the record
    h = hist(browser)
    assert h["i"] == 1 and h["state"]["layers"] == [], h
    # the New session page is a view with a link of its own (#new, an entry in either mode), not a layer: Back returns from it
    tap(browser, "#side-new")
    h = hist(browser)
    assert h["newOpen"] and h["hash"] == "#new" and h["state"]["layers"] == [] and h["i"] == 2 and h["entries"][-1] == "#new" and not h["drawer"], h
    h = back(browser)
    assert not h["newOpen"] and h["i"] == 1 and h["hash"] == f"#s={A}", h
    # Get Help on the Overview: a view entry pushed from there
    tap(browser, "#side-ovw")
    tap(browser, "#sp-help")
    h = hist(browser)
    assert h["hash"] == "#s=help-session" and h["entries"][-2:] == ["#sessions", "#s=help-session"], h


def test_a_wide_browser_with_no_hash_opens_on_the_overview_by_replacing_the_launch_entry(served, browser):
    # no empty "Select a session" page; #sessions is written over the launch entry, so no entry is added
    open_app(browser, served, "", width=1280, remembered=f"#s={B}")   # a remembered session is not used here (push mode)
    h = hist(browser)
    on_overview(h)
    assert not h["replace"] and h["entries"] == ["#sessions"] and h["i"] == 0 and h["len"] == 3 and h["state"]["layers"] == [], h
    # Back from it leaves sala, as for a #sessions deep link
    assert back(browser)["left"]
    # a reload keeps the Overview and adds nothing
    open_app(browser, served, "", width=1280)
    browser.send("Page.reload")
    assert wait_for(browser, READY)
    settle(browser)
    h = hist(browser)
    on_overview(h)
    assert h["entries"] == ["#sessions"], h
    # the views pushed from it are entries over that base: Back walks them and returns to the Overview, then leaves
    tap(browser, row(A))
    h = hist(browser)
    in_session(h, A)
    assert h["entries"] == ["#sessions", f"#s={A}"] and h["i"] == 1, h
    on_overview(back(browser))
    assert back(browser)["left"]
    # a deep link to a session is untouched: it opens that session, one entry, and Back leaves
    open_app(browser, served, f"#s={C}", width=1280)
    h = hist(browser)
    in_session(h, C)
    assert h["entries"] == [f"#s={C}"], h
    assert back(browser)["left"]
    # the phone keeps its own rule (the last view, else the Overview) and the installed app too
    open_app(browser, served, "", width=390, remembered=f"#s={B}")
    in_session(hist(browser), B)
    open_app(browser, served, "", width=1280, standalone=True, remembered=f"#s={B}")
    in_session(hist(browser), B)


def test_a_phone_in_landscape_wider_than_the_drawer_layout_pushes_like_a_browser(served, browser):
    open_app(browser, served, f"#s={A}", width=844)
    h = hist(browser)
    in_session(h, A)
    assert not h["replace"], h
    tap(browser, row(B))
    h = hist(browser)
    in_session(h, B)
    assert h["entries"] == [f"#s={A}", f"#s={B}"], h


# ---------- links and rows ----------

def test_modified_clicks_and_links_to_other_pages_are_the_browser_s(served, browser):
    open_app(browser, served, "#sessions")
    assert wait_for(browser, "!!document.querySelector('#sp-table a[href^=\"#s=\"]')")
    # a click is dispatched and what sala left of it read at the window (after sala's handler), then stopped there so
    # the browser opens nothing in the test
    probe = """((sel, init) => { const a = document.querySelector(sel); let left = null;
      window.addEventListener("click", (e) => { left = !e.defaultPrevented; e.preventDefault(); }, { once: true });
      a.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, button: 0, ...init })); return left; })"""
    link = f"#sp-table a[href='#s={A}']"
    for init in ({"ctrlKey": True}, {"metaKey": True}, {"shiftKey": True}, {"altKey": True}):
        assert browser.evaluate(probe + f"({json.dumps(link)}, {json.dumps(init)})") is True, init   # the browser's: a new tab
    assert hist(browser)["entries"] == ["#sessions"]
    # a plain click is sala's
    assert browser.evaluate(probe + f"({json.dumps(link)}, {{}})") is False
    settle(browser)
    h = hist(browser)
    in_session(h, A)
    assert h["past"] == [f"#s={A}"], h


REPLY_LINKS = {"bare": "#s=demo", "full": "{origin}/#s=demo", "overview": "#sessions",
               "stack": "https://board.example.test/items/133", "gh": "https://github.com/example-org/salamander/pull/1",
               "api": "{origin}/api/sessions"}


@pytest.mark.parametrize("width", [390, 1280])
@pytest.mark.parametrize("kind", ["bare", "full", "overview"])
def test_a_link_in_a_reply_to_sala_s_own_page_stays_in_sala(served, browser, width, kind):
    """every link in a reply is target=_blank (md() in app.js), and the installed app on a phone opened a link
    to sala in Chrome's in-app view, a desktop in a new tab. A plain click on a link to sala's own page and route is
    sala's (go), as the sidebar's, with the same history; a modified or middle click is still the browser's (a new tab),
    and so is every link to another origin or another path of this one (target=_blank, outside sala)."""
    open_app(browser, served, f"#s={A}", width=width)
    assert wait_for(browser, "document.querySelectorAll('#chat > .msg').length >= 1", 10.0)
    text = "\n\n".join(f"[{k}]({v})" for k, v in REPLY_LINKS.items())
    browser.evaluate(f"""(() => {{ const d = md({json.dumps(text)}.split("{{origin}}").join(location.origin));
      d.id = "probe-md"; for (const a of d.querySelectorAll("a")) a.dataset.k = a.textContent;
      document.getElementById("chat").append(d); }})(); ''""")
    # the links are what they were: all target=_blank, noopener (the off-origin ones rely on it)
    got = browser.evaluate("[...document.querySelectorAll('#probe-md a')].map((a) => [a.textContent, a.target, a.rel])")
    assert [g[0] for g in got] == list(REPLY_LINKS), got
    assert all(g[1] == "_blank" and g[2] == "noopener noreferrer" for g in got), got
    # a click dispatched and what sala left of it read at the window (after sala's handler), then stopped there so the
    # browser opens nothing in the test
    probe = """((sel, init) => { const a = document.querySelector(sel); let left = null;
      window.addEventListener("click", (e) => { left = !e.defaultPrevented; e.preventDefault(); }, { once: true });
      a.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, button: 0, ...init })); return left; })"""
    pick = lambda k: f"#probe-md a[data-k='{k}']"  # noqa: E731
    before = hist(browser)
    for k in ("stack", "gh", "api"):   # another origin, another path: the browser's, in a new tab
        assert browser.evaluate(probe + f"({json.dumps(pick(k))}, {{}})") is True, k
    for init in ({"ctrlKey": True}, {"metaKey": True}, {"shiftKey": True}, {"altKey": True}, {"button": 1}):
        assert browser.evaluate(probe + f"({json.dumps(pick(kind))}, {json.dumps(init)})") is True, init
    h = hist(browser)
    in_session(h, A)
    assert h["entries"] == before["entries"] and h["i"] == before["i"], h
    # a plain click is sala's
    assert browser.evaluate(probe + f"({json.dumps(pick(kind))}, {{}})") is False
    settle(browser)
    h = hist(browser)
    if kind == "overview":
        on_overview(h)
        want = ["#sessions"] if width <= 760 else [f"#s={A}", "#sessions"]
    else:
        in_session(h, B)
        want = [f"#s={B}"] if width <= 760 else [f"#s={A}", f"#s={B}"]
    assert h["past"] == want, h   # the sidebar click's history: a phone's one entry became the view, a browser pushed one


@pytest.mark.parametrize("width", [390, 1280])
def test_the_overview_link_keeps_working_at_both_widths(served, browser, width):
    open_app(browser, served, f"#s={A}", width=width)
    # the Overview link (#sessions) from the deep link
    if width <= 760:
        open_drawer(browser)
    tap(browser, "#side-ovw")
    h = hist(browser)
    on_overview(h)
    if width <= 760:
        one_entry(h, "#sessions")   # a phone: the one entry became the Overview
        assert back(browser)["left"]
    else:
        assert h["past"] == [f"#s={A}", "#sessions"], h   # a browser: a view pushed
        in_session(back(browser), A)


# ---------- the composer's text ----------

def type_text(browser, text: str) -> None:
    browser.evaluate("document.querySelector('#input').focus(); ''")
    browser.send("Input.insertText", {"text": text})


def drafted(name: str, text: str) -> str:
    return f"localStorage.getItem('salaweb.draft.{name}') === {json.dumps(text)}"


SPY_SEND = """(() => { window.__sent = []; const real = window.fetch;
  window.fetch = (u, o) => { if (String(u).includes("/send")) { __sent.push(JSON.parse(o.body));
    return Promise.resolve(new Response(JSON.stringify({ ok: true }), { status: 200, headers: { "Content-Type": "application/json" } })); }
    return real(u, o); }; return true; })()"""


def test_unsent_text_is_kept_per_session_and_the_composer_is_emptied_on_a_switch(served, browser):
    open_app(browser, served, f"#s={A}")
    type_text(browser, "draft for A 초안")
    assert wait_for(browser, drafted(A, "draft for A 초안"), 3.0)   # saved a moment after the last keystroke
    # to B: A's text is kept, the box is empty (it would have been sent to B), B has its own
    open_drawer(browser)
    tap(browser, row(B))
    assert browser.evaluate("getText()") == "" and browser.evaluate("!!document.querySelector('#composer-editor .cm-placeholder')")
    assert browser.evaluate(f"localStorage.getItem('salaweb.draft.{A}')") == "draft for A 초안"
    type_text(browser, "text for B")
    open_drawer(browser)
    tap(browser, row(A))   # and back: A's text is back, B's kept
    assert browser.evaluate("getText()") == "draft for A 초안"
    assert browser.evaluate(f"localStorage.getItem('salaweb.draft.{B}')") == "text for B"
    # the Overview round trip: the text is kept while it is shown and back after
    open_drawer(browser)
    tap(browser, "#side-ovw")
    assert browser.evaluate(f"localStorage.getItem('salaweb.draft.{A}')") == "draft for A 초안" and browser.evaluate("getText()") == ""
    tap(browser, table(A))
    assert browser.evaluate("getText()") == "draft for A 초안"
    # a closed app: the tab's sessionStorage gone, the text still there after a reload
    browser.evaluate("sessionStorage.clear(); ''")
    browser.send("Page.reload")
    assert wait_for(browser, READY)
    assert wait_for(browser, "getText() === 'draft for A 초안'", 5.0)
    # the button sends it; the draft is gone from the session and from storage, and does not come back
    browser.evaluate(SPY_SEND)
    tap(browser, "#send")
    assert wait_for(browser, "__sent.length === 1 && __sent[0].text === 'draft for A 초안'", 5.0), browser.evaluate("window.__sent")
    assert browser.evaluate("getText()") == "" and browser.evaluate(f"localStorage.getItem('salaweb.draft.{A}')") is None
    open_drawer(browser)
    tap(browser, row(B))
    assert browser.evaluate("getText()") == "text for B"   # B's draft: still B's alone
    open_drawer(browser)
    tap(browser, row(A))
    assert browser.evaluate("getText()") == ""


def test_a_draft_emptied_by_hand_is_dropped_and_one_of_the_first_build_is_carried_over(served, browser):
    open_app(browser, served, f"#s={A}")
    type_text(browser, "x")
    assert wait_for(browser, drafted(A, "x"), 3.0)
    browser.evaluate("selectOffsets(0, 1); ''")   # emptied by hand: the character selected and deleted
    key(browser, "Backspace", 8)
    assert browser.evaluate("getText()") == ""
    assert wait_for(browser, f"localStorage.getItem('salaweb.draft.{A}') === null", 3.0)
    # the first build kept it in this tab's sessionStorage, once
    browser.evaluate(f"sessionStorage.setItem('salaweb.draft.{A}', 'from before'); ''")
    browser.send("Page.reload")
    assert wait_for(browser, READY)
    assert wait_for(browser, "getText() === 'from before'", 5.0)
    assert browser.evaluate(f"sessionStorage.getItem('salaweb.draft.{A}')") is None
    assert browser.evaluate(f"localStorage.getItem('salaweb.draft.{A}')") == "from before"
    # capped, text only
    browser.evaluate("setText('y'.repeat(25000)); saveDraft(); ''")
    assert browser.evaluate(f"localStorage.getItem('salaweb.draft.{A}').length") == 20000

