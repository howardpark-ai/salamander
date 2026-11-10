"""The Shell drawer on the page (a small console at the bottom of the page, opened and closed
with a button). The server half (the tmux session of SALA_SHELL_SESSION, the key endpoint, the lists that never show it) is test_shell_backend.py's.

What is held here, by the markup and by the boxes the page draws:
- the Shell button at the right end of the title bar on every page (chat, Overview, New session), `aria-expanded` following the
  drawer, its title naming Ctrl+`; icon only and a 44 px square on a phone;
- nothing is loaded before the first open (no frame, no call to api/shell/open); the first open asks the server for the shell
  and builds one ttyd frame on `/tty/?arg=<session>` (the name and this machine's hostname come from api/config, none is written into the page); closing hides the drawer and keeps the frame (the shell keeps running),
  and the next open reuses it unless the server says it had to make a new shell (`created`);
- a wide screen: the drawer docks under the page and the composer sits above it, at the height kept in api/prefs (shellHeight),
  the handle drags it and the new height is saved; Ctrl+` toggles unless focus is in the composer; Escape does not close it;
- open/closed is remembered across a page load and survives leaving for the Overview and back;
- a phone: a bottom sheet of about 60% of the screen over a dim backdrop, a Close button of 44 px, and a key row whose buttons
  (Esc, Tab, Ctrl, up, down, Ctrl+C; 44 x 40 px at least) send fixed key names to api/shell/keys, Ctrl arming the next key.
The real tmux is never touched: the server's `ensure_shell_session` and `send_shell_key` are replaced by recorders.
Runs in a headless Chromium when one is installed (conftest.py: `served`, `browser`), else skipped.
"""

from __future__ import annotations

import json
import socket
import time

import pytest

from conftest import NAME
from sala_web import tmuxio as T
from sala_web.app import STATIC
from test_composer_attach import WAIT_READY

HOST = socket.gethostname().split(".")[0]      # api/config tells the page the machine; the session is SALA_SHELL_SESSION (conftest leaves it unset: sala-shell)
SESSION = "sala-shell"
INDEX = (STATIC / "index.html").read_text()
APP_JS = (STATIC / "app.js").read_text()

STATE = r"""
(() => {
  const q = (s) => document.querySelector(s);
  const box = (e) => { const r = e.getBoundingClientRect(); return { l: r.left, r: r.right, t: r.top, b: r.bottom, w: r.width, h: r.height }; };
  const d = q("#shell-drawer"), btn = q("#shell-btn");
  return { btn: box(btn), btnShown: getComputedStyle(btn).display !== "none", expanded: btn.getAttribute("aria-expanded"), title: btn.title,
           label: getComputedStyle(q(".shell-label")).display, bar: box(q("#top")),
           hidden: d.hidden, drawer: d.hidden ? null : box(d), scrim: getComputedStyle(q("#shell-scrim")).display,
           composer: box(q("#composer")), composerShown: getComputedStyle(q("#composer")).display !== "none",
           frames: [...document.querySelectorAll("#shell-term iframe")].map((f) => f.getAttribute("src")), open: document.body.classList.contains("shell-open"),
           vh: innerHeight, vw: innerWidth, full: q("#shell-full").getAttribute("href"), shellH: d.style.getPropertyValue("--shell-h") };
})()
"""


def until(browser, expr: str, secs: float = 15):
    """Poll a JS expression until it is truthy; its last value."""
    return browser.evaluate("new Promise((res) => { const t0 = Date.now(); (function poll() { let v = false; try { v = (%s); } catch (e) {} "
                            "if (v || Date.now() - t0 > %d) res(v); else setTimeout(poll, 50); })(); })" % (expr, secs * 1000))


def settle(browser):
    browser.evaluate("new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(r, 60))))")


def st(browser) -> dict:
    return browser.evaluate(STATE)


def click(browser, sel: str):
    browser.evaluate("document.querySelector(%s).click(); ''" % json.dumps(sel))


def wide(browser, w: int = 1100, h: int = 800):
    browser.send("Emulation.setDeviceMetricsOverride", {"width": w, "height": h, "deviceScaleFactor": 1, "mobile": False})
    settle(browser)


def reload(browser):
    browser.send("Page.reload")
    assert until(browser, "document.readyState === 'complete' && typeof state !== 'undefined' && state.current && document.querySelectorAll('#chat > .msg').length")
    settle(browser)


def key(browser, k: str, code: str, vk: int, modifiers: int = 0):
    ev = {"key": k, "code": code, "windowsVirtualKeyCode": vk, "modifiers": modifiers}
    browser.send("Input.dispatchKeyEvent", {"type": "keyDown", **ev})
    browser.send("Input.dispatchKeyEvent", {"type": "keyUp", **ev})


class Fake:
    """Stands in for the tmux half: `ensure_shell_session` says created (first time, or as `created` is set), `send_shell_key` records."""

    def __init__(self):
        self.opens = 0
        self.created = [True]
        self.keys: list[str] = []

    async def ensure(self, settings):
        self.opens += 1
        return self.created.pop(0) if self.created else False

    async def send(self, settings, key):
        self.keys.append(key)


@pytest.fixture
def fake(monkeypatch):
    f = Fake()
    monkeypatch.setattr(T, "ensure_shell_session", f.ensure)
    monkeypatch.setattr(T, "send_shell_key", f.send)
    return f


@pytest.fixture
def chat(served, browser, fake):
    browser.call("Browser.grantPermissions", {"origin": served["url"], "permissions": ["clipboardReadWrite", "clipboardSanitizedWrite"]})
    browser.send("Emulation.setFocusEmulationEnabled", {"enabled": True})
    browser.open(f"{served['url']}/#s={NAME}")
    assert browser.evaluate(WAIT_READY)
    until(browser, "typeof state !== 'undefined' && state.current")
    browser.served = served
    return browser


def test_the_markup_has_the_button_and_the_drawer():
    end = INDEX[INDEX.index('id="top-end"'):INDEX.index('id="top-tools"')]
    assert '<button id="shell-btn"' in end                                      # in the title bar's right cluster
    assert end.index('id="shell-btn"') < end.index('id="top-menu-btn"')         # before the ⋯ button in the page, so Tab from it goes into its menu
    assert ".shell-btn { order: 1;" in (STATIC / "style.css").read_text()          # and drawn after it: the right end of the bar
    btn = end[end.index('<button id="shell-btn"'):]
    btn = btn[:btn.index("</button>")]
    assert 'aria-expanded="false"' in btn and 'aria-controls="shell-drawer"' in btn and 'title="Shell (Ctrl+`)"' in btn
    assert 'class="shell-label" data-i18n="common.shell">Shell<' in btn
    assert '<section id="shell-drawer" class="shell-drawer" aria-label="Shell" data-i18n-aria-label="common.shell" hidden>' in INDEX
    assert 'href="terminal" target="_blank" rel="noopener" data-i18n="ui.shell.full">Open full size</a>' in INDEX     # the session is added from api/config
    assert 'title="Close (the shell keeps running)" data-i18n-title="ui.shell.closeTip"' in INDEX
    assert 'id="shell-chip"' in INDEX and "owner-shell" not in INDEX and "Shell on " not in INDEX   # no owner's name, and no machine named in the markup
    keys = INDEX[INDEX.index('id="shell-keys"'):]
    keys = keys[:keys.index("</div>")]
    assert [k.split('"')[1] for k in keys.split('data-key=')[1:]] == ["Escape", "Tab", "ctrl", "Up", "Down", "C-c"]
    assert APP_JS.count('"api/shell/open"') == 1 and APP_JS.count('"api/shell/keys"') == 1
    assert "SHELL_OPEN_KEY" in APP_JS and "shellHeight" in APP_JS           # open state in localStorage, height in prefs
    frame_fn = APP_JS[APP_JS.index("async function ensureShellFrame()"):]
    frame_fn = frame_fn[:frame_fn.index("\n}\n")]
    assert "encodeURIComponent(session)" in frame_fn and "state.shellSession" not in frame_fn   # the frame attaches to the session api/shell/open returned


def test_the_button_is_on_every_page_and_nothing_loads_before_it_is_used(chat, fake):
    b = chat
    b.touch()   # a phone: the 44 px square is the touch size (a mouse gets the look's 32 px)
    for hash_ in (f"#s={NAME}", "#sessions", "#new"):
        b.evaluate("location.hash = %s; ''" % json.dumps(hash_))
        settle(b)
        s = st(b)
        assert s["btnShown"] and s["btn"]["w"] >= 44 and s["btn"]["h"] >= 44, (hash_, s["btn"])      # a phone: icon only, a 44 px square
        assert s["label"] == "none" and s["btn"]["r"] <= s["vw"] and s["btn"]["t"] >= s["bar"]["t"] - 8 and s["btn"]["b"] <= s["bar"]["b"] + 8, (hash_, s)
        assert s["expanded"] == "false" and s["hidden"] and s["frames"] == [] and not s["open"], (hash_, s)
    assert b.evaluate("document.querySelector('#shell-btn').getAttribute('aria-label')") == "Shell"
    assert fake.opens == 0 and fake.keys == []


def test_a_phone_opens_a_sheet_with_a_frame_and_closes_it_without_losing_the_shell(chat, fake):
    b = chat
    click(b, "#shell-btn")
    assert until(b, "document.querySelectorAll('#shell-term iframe').length")
    s = st(b)
    assert s["expanded"] == "true" and not s["hidden"] and s["open"] and s["scrim"] == "block"
    assert s["frames"] == ["/tty/?arg=" + SESSION] and fake.opens == 1
    assert 0.55 * s["vh"] <= s["drawer"]["h"] <= 0.65 * s["vh"], s                      # about 60% of the screen
    assert abs(s["drawer"]["b"] - s["vh"]) <= 1 and s["drawer"]["l"] == 0 and s["drawer"]["r"] == s["vw"]   # a sheet at the bottom edge
    radius = b.evaluate("getComputedStyle(document.querySelector('#shell-drawer')).borderTopLeftRadius")
    assert radius == "8px"   # the look's largest corner (was 16 px)
    close = b.evaluate("(() => { const r = document.querySelector('#shell-close').getBoundingClientRect(); return { h: r.height, w: r.width, text: document.querySelector('#shell-close').textContent.trim() }; })()")
    assert close["h"] >= 44 and close["text"] == "Close", close
    assert b.evaluate("document.querySelector('.shell-chip').textContent") == HOST + " · " + SESSION
    frame = b.evaluate("(() => { const f = document.querySelector('#shell-term iframe'); f.dataset.mark = 'first'; return f.getAttribute('allow'); })()")
    assert frame == "clipboard-read; clipboard-write"
    # closing: the sheet and the backdrop go, the frame stays, the next open reuses it (the server made no new shell)
    click(b, "#shell-close")
    s = st(b)
    assert s["expanded"] == "false" and s["hidden"] and s["scrim"] == "none" and not s["open"] and len(s["frames"]) == 1
    click(b, "#shell-btn")
    assert until(b, "document.querySelector('#shell-drawer').hidden === false && %d" % 1)
    deadline = time.time() + 5
    while fake.opens < 2 and time.time() < deadline:     # each open asks the server again (cheap), the frame stays
        time.sleep(0.05)
    assert fake.opens == 2
    assert b.evaluate("document.querySelector('#shell-term iframe').dataset.mark") == "first"
    # the backdrop closes it, so does Escape
    click(b, "#shell-scrim")
    assert st(b)["hidden"]
    click(b, "#shell-btn")
    b.evaluate("document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); ''")
    assert st(b)["hidden"]


def test_a_shell_that_had_ended_gets_a_new_frame(chat, fake):
    b = chat
    fake.created = [True, True]          # the server had to make a new shell the second time
    click(b, "#shell-btn")
    assert until(b, "document.querySelectorAll('#shell-term iframe').length")
    b.evaluate("document.querySelector('#shell-term iframe').dataset.mark = 'old'; ''")
    click(b, "#shell-btn")
    click(b, "#shell-btn")
    assert until(b, "document.querySelector('#shell-term iframe') && document.querySelector('#shell-term iframe').dataset.mark !== 'old'")


def test_the_key_row_sends_fixed_key_names_and_ctrl_arms_the_next_key(chat, fake):
    b = chat
    click(b, "#shell-btn")
    assert until(b, "document.querySelectorAll('#shell-term iframe').length")
    boxes = b.evaluate("[...document.querySelectorAll('#shell-keys button')].map((e) => { const r = e.getBoundingClientRect(); "
                       "return { text: e.textContent.trim(), key: e.dataset.key, w: r.width, h: r.height, font: getComputedStyle(e).fontFamily, r: r.right }; })")
    assert [x["text"] for x in boxes] == ["Esc", "Tab", "Ctrl", "↑", "↓", "Ctrl+C"], boxes
    assert all(x["w"] >= 44 and x["h"] >= 40 and "mono" in x["font"].lower() for x in boxes), boxes
    assert all(x["r"] <= 390 for x in boxes)
    for k in ("Escape", "Tab", "Up", "Down", "C-c"):
        click(b, f"#shell-keys [data-key='{k}']")
    deadline = time.time() + 5
    while len(fake.keys) < 5 and time.time() < deadline:
        time.sleep(0.05)
    assert fake.keys == ["Escape", "Tab", "Up", "Down", "C-c"], fake.keys
    # Ctrl is sticky for one key: armed (pressed), the next row key goes, Ctrl disarms
    fake.keys.clear()
    click(b, "#shell-ctrl")
    assert b.evaluate("document.querySelector('#shell-ctrl').getAttribute('aria-pressed')") == "true"
    click(b, "#shell-keys [data-key='C-c']")
    click(b, "#shell-keys [data-key='Tab']")
    deadline = time.time() + 5
    while len(fake.keys) < 2 and time.time() < deadline:
        time.sleep(0.05)
    assert fake.keys == ["C-c", "Tab"] and b.evaluate("document.querySelector('#shell-ctrl').getAttribute('aria-pressed')") == "false"
    # and a letter typed in the terminal while Ctrl is armed goes as Ctrl+letter (the frame is same-origin: ttyd is behind this server)
    fake.keys.clear()
    assert until(b, "document.querySelector('#shell-term iframe').contentDocument && document.querySelector('#shell-term iframe').contentDocument.__shellCtrl")
    click(b, "#shell-ctrl")
    b.evaluate("document.querySelector('#shell-term iframe').contentDocument.dispatchEvent(new KeyboardEvent('keydown', { key: 'X', bubbles: true, cancelable: true })); ''")
    deadline = time.time() + 5
    while not fake.keys and time.time() < deadline:
        time.sleep(0.05)
    assert fake.keys == ["C-x"] and b.evaluate("document.querySelector('#shell-ctrl').getAttribute('aria-pressed')") == "false"
    # disarmed, a letter is left to the terminal
    b.evaluate("document.querySelector('#shell-term iframe').contentDocument.dispatchEvent(new KeyboardEvent('keydown', { key: 'x', bubbles: true, cancelable: true })); ''")
    time.sleep(0.3)
    assert fake.keys == ["C-x"]


def test_a_press_on_a_key_does_not_take_the_focus_from_the_terminal(chat, fake):
    b = chat
    click(b, "#shell-btn")
    assert until(b, "document.querySelectorAll('#shell-term iframe').length")
    # pointerdown and mousedown on a row button are cancelled (so the soft keyboard stays); a press elsewhere in the drawer is not
    got = b.evaluate("""(() => {
      const press = (el, type) => { const e = new Event(type, { bubbles: true, cancelable: true }); el.dispatchEvent(e); return e.defaultPrevented; };
      const k = document.querySelector("#shell-keys [data-key='Tab']");
      return { pd: press(k, "pointerdown"), md: press(k, "mousedown"), other: press(document.querySelector("#shell-close"), "mousedown") };
    })()""")
    assert got == {"pd": True, "md": True, "other": False}, got
    # and the click still sends the key
    click(b, "#shell-keys [data-key='Tab']")
    deadline = time.time() + 5
    while not fake.keys and time.time() < deadline:
        time.sleep(0.05)
    assert fake.keys == ["Tab"], fake.keys


def test_a_key_the_server_refuses_is_said_in_the_drawer(chat, fake, monkeypatch):
    b = chat

    async def broken(settings, key):
        raise T.TmuxError("the shell is not running")
    monkeypatch.setattr(T, "send_shell_key", broken)
    click(b, "#shell-btn")
    assert until(b, "document.querySelectorAll('#shell-term iframe').length")
    click(b, "#shell-keys [data-key='Tab']")
    assert "not running" in until(b, "document.querySelector('#shell-note').textContent")


def test_a_wide_screen_docks_the_drawer_under_the_composer(chat, fake):
    b = chat
    wide(b)
    s = st(b)
    assert s["label"] != "none" and s["btn"]["h"] <= 36 and s["btnShown"]
    assert s["title"] == "Shell on " + HOST + " (Ctrl+`)"          # painted when api/config arrives, before the first open
    click(b, "#shell-btn")
    assert until(b, "document.querySelectorAll('#shell-term iframe').length")
    settle(b)
    s = st(b)
    assert s["expanded"] == "true" and s["scrim"] == "none"                              # no backdrop on a wide screen
    assert abs(s["drawer"]["h"] - 300) <= 2, s["drawer"]                               # the default height
    assert abs(s["drawer"]["b"] - s["vh"]) <= 1                                         # at the bottom edge
    assert s["composer"]["b"] <= s["drawer"]["t"] + 1 and s["composer"]["h"] > 20      # the composer moved up above it
    assert s["full"] == "terminal?arg=" + SESSION
    keys = b.evaluate("getComputedStyle(document.querySelector('#shell-keys')).display")
    assert keys == "none"                                                              # the key row is the phone's
    b.evaluate("document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); ''")
    assert not st(b)["hidden"]                                                         # Escape closes a sheet, not the docked drawer
    click(b, "#shell-close")
    s = st(b)
    assert s["hidden"] and s["expanded"] == "false" and s["composer"]["b"] >= s["vh"] - 2


def test_ctrl_backtick_toggles_unless_focus_is_in_the_composer(chat, fake):
    b = chat
    wide(b)
    b.evaluate("document.activeElement && document.activeElement.blur(); ''")
    key(b, "`", "Backquote", 192, 2)
    assert until(b, "document.querySelector('#shell-drawer').hidden === false")
    assert st(b)["expanded"] == "true"
    # The first open builds the shell frame after the server answers, and on a wide screen the frame takes the focus when it has
    # loaded (that is the app's design: a terminal needs the keys). A keydown in the frame never reaches the page, so a second press
    # sent while that is still coming (a slow machine) would be lost. Wait for the frame's load (the app marks its document then),
    # let the focus move settle, and take the focus off the frame again, as the first press started from a page with none.
    assert until(b, "(() => { const f = document.querySelector('#shell-term iframe'); return !!(f && f.contentDocument && f.contentDocument.__shellCtrl); })()")
    settle(b)
    b.evaluate("document.activeElement && document.activeElement.blur(); ''")
    key(b, "`", "Backquote", 192, 2)
    assert until(b, "document.querySelector('#shell-drawer').hidden === true")
    # focus in the composer (a contenteditable): the shortcut is left alone
    # (a late load of the shell frame must not take the focus from it: the app skips that when the drawer is closed by then; the focus
    # is asked for until it sticks, as the frame's own load may still be settling)
    assert until(b, "(document.querySelector('#input').focus(), document.activeElement.isContentEditable)")
    time.sleep(0.3)
    assert b.evaluate("document.activeElement.isContentEditable") is True
    key(b, "`", "Backquote", 192, 2)
    time.sleep(0.3)
    assert st(b)["hidden"]
    # no Ctrl, no toggle
    b.evaluate("document.activeElement.blur(); ''")
    key(b, "`", "Backquote", 192, 0)
    time.sleep(0.3)
    assert st(b)["hidden"]


def test_open_state_survives_a_reload_and_leaving_for_the_overview(chat, fake):
    b = chat
    wide(b)
    click(b, "#shell-btn")
    assert until(b, "document.querySelectorAll('#shell-term iframe').length")
    b.evaluate("document.querySelector('#shell-term iframe').dataset.mark = 'kept'; location.hash = '#sessions'; ''")
    settle(b)
    s = st(b)
    assert not s["hidden"] and s["btnShown"] and s["drawer"]["b"] >= s["vh"] - 1       # still there on the Overview, at the bottom
    assert b.evaluate("document.querySelector('#shell-term iframe').dataset.mark") == "kept"
    b.evaluate("location.hash = '#s=%s'; ''" % NAME)
    settle(b)
    assert not st(b)["hidden"] and b.evaluate("document.querySelector('#shell-term iframe').dataset.mark") == "kept"
    reload(b)
    assert until(b, "document.querySelector('#shell-drawer').hidden === false")        # remembered across a page load
    assert until(b, "document.querySelectorAll('#shell-term iframe').length")
    assert st(b)["expanded"] == "true"
    click(b, "#shell-close")
    reload(b)
    settle(b)
    assert st(b)["hidden"]                                                              # closed stays closed
    assert b.evaluate("document.querySelectorAll('#shell-term iframe').length") == 0     # and nothing was loaded for it


def test_the_height_comes_from_prefs_and_a_drag_saves_it(chat, fake):
    b = chat
    wide(b)
    assert b.evaluate("fetch('api/prefs', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ shellHeight: 420 }) }).then((r) => r.status)") == 200
    reload(b)
    click(b, "#shell-btn")
    assert until(b, "document.querySelectorAll('#shell-term iframe').length")
    settle(b)
    s = st(b)
    assert abs(s["drawer"]["h"] - 420) <= 2, s["drawer"]
    # drag the handle up 60 px: the drawer grows by 60 and the new height is saved in prefs
    r = b.evaluate("(() => { const r = document.querySelector('#shell-handle').getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2, c: getComputedStyle(document.querySelector('#shell-handle')).cursor, bw: document.querySelector('#shell-handle span').getBoundingClientRect().width, bh: document.querySelector('#shell-handle span').getBoundingClientRect().height }; })()")
    assert r["c"] == "ns-resize" and abs(r["bw"] - 44) <= 0.5 and abs(r["bh"] - 4) <= 0.5
    b.send("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": r["x"], "y": r["y"]})
    b.send("Input.dispatchMouseEvent", {"type": "mousePressed", "x": r["x"], "y": r["y"], "button": "left", "clickCount": 1})
    for step in range(1, 7):
        b.send("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": r["x"], "y": r["y"] - 10 * step, "button": "left", "buttons": 1})
    b.send("Input.dispatchMouseEvent", {"type": "mouseReleased", "x": r["x"], "y": r["y"] - 60, "button": "left", "clickCount": 1})
    settle(b)
    assert abs(st(b)["drawer"]["h"] - 480) <= 2, st(b)["drawer"]
    got = None
    deadline = time.time() + 6
    while time.time() < deadline:
        got = b.evaluate("fetch('api/prefs', { cache: 'no-store' }).then((r) => r.json()).then((p) => p.shellHeight)")
        if got == 480:
            break
        time.sleep(0.2)
    assert got == 480, got
    # a height beyond the window is held to three quarters of it
    b.evaluate("state.prefs.shellHeight = 4000; applyShellHeight(); ''")
    assert st(b)["drawer"]["h"] <= 0.75 * st(b)["vh"] + 1


def phone(browser, w: int = 320, h: int = 800):
    browser.send("Emulation.setDeviceMetricsOverride", {"width": w, "height": h, "deviceScaleFactor": 1, "mobile": True})
    settle(browser)


FOLDED = "(() => { const b = document.querySelector('#shell-btn'); return { inMenu: !!b.closest('#top-tools'), inBar: !!b.closest('#top-end') && !b.closest('#top-tools'), expanded: b.getAttribute('aria-expanded'), menuOpen: document.body.classList.contains('top-menu-open'), active: document.activeElement && document.activeElement.id }; })()"


def test_the_shell_row_in_the_menu_opens_and_closes_the_drawer(chat, fake):
    """Decision: where the name needs the room, the Shell button is the first item to
    fold into the ⋯ menu, as a row. It is the same button: the row opens and closes the drawer as the bar's button does, its
    aria-expanded follows, a tap closes the menu, and closing the drawer from inside returns the focus to the ⋯ button."""
    b = chat
    phone(b, 320)
    f = b.evaluate(FOLDED)
    assert f["inMenu"] and not f["inBar"] and f["expanded"] == "false", f      # a 320 px phone: Shell is in the menu (the short name needs it gone)
    click(b, "#top-menu-btn")
    assert b.evaluate(FOLDED)["menuOpen"]
    assert b.evaluate("document.querySelector('#shell-btn').getBoundingClientRect().height") >= 44
    click(b, "#shell-btn")                                                    # open from the row: the sheet, the menu closed
    assert until(b, "document.querySelectorAll('#shell-term iframe').length")
    s, f = st(b), b.evaluate(FOLDED)
    assert not s["hidden"] and s["open"] and s["expanded"] == "true" and f["expanded"] == "true" and not f["menuOpen"], (s, f)
    assert s["frames"] == ["/tty/?arg=" + SESSION] and fake.opens == 1
    # State sync of the row, not a user path: on a real phone the open sheet's scrim covers ⋯ (a user closes with Close or the scrim,
    # below), so the menu is opened and the row clicked by script. The row shows the open state, and a click on it closes the drawer.
    click(b, "#top-menu-btn")
    assert b.evaluate(FOLDED)["expanded"] == "true"
    click(b, "#shell-btn")
    s, f = st(b), b.evaluate(FOLDED)
    assert s["hidden"] and not s["open"] and s["expanded"] == "false" and f["expanded"] == "false" and not f["menuOpen"], (s, f)
    # closed from inside the sheet while focus is in it (the way a user closes it): the focus goes to the ⋯ button (the row is in a closed menu)
    click(b, "#top-menu-btn")
    click(b, "#shell-btn")
    assert not st(b)["hidden"]
    b.evaluate("document.querySelector('#shell-close').focus(); ''")
    click(b, "#shell-close")
    f = b.evaluate(FOLDED)
    assert st(b)["hidden"] and f["expanded"] == "false" and f["active"] == "top-menu-btn", f
    # Ctrl+` toggles from the keyboard whether the button is in the bar or the menu
    b.evaluate("document.activeElement && document.activeElement.blur(); ''")
    key(b, "`", "Backquote", 192, 2)
    assert until(b, "document.querySelector('#shell-drawer').hidden === false")
    assert b.evaluate(FOLDED)["expanded"] == "true"
    # wider: the button is back in the bar with its state kept, the drawer still open
    wide(b, 1280)
    f = b.evaluate(FOLDED)
    assert f["inBar"] and f["expanded"] == "true" and not st(b)["hidden"], f


def test_the_shell_button_stays_in_the_bar_where_there_is_no_menu(chat, fake):
    """The Overview and the New session page hide the ⋯ button and its menu, so the button must not fold into it there (it
    would be out of reach): at a width that folds it on a session, it stays in the bar on those pages."""
    b = chat
    b.touch()   # a phone: the bar holds the 44 px touch square
    phone(b, 320)
    assert b.evaluate(FOLDED)["inMenu"]
    for hash_ in ("#sessions", "#new"):
        b.evaluate("location.hash = %s; ''" % json.dumps(hash_))
        settle(b)
        f, s = b.evaluate(FOLDED), st(b)
        assert f["inBar"] and not f["inMenu"] and s["btnShown"] and s["btn"]["w"] >= 44 and s["btn"]["h"] >= 44 and s["btn"]["r"] <= s["vw"], (hash_, f, s["btn"])
        click(b, "#shell-btn")
        assert until(b, "document.querySelector('#shell-drawer').hidden === false")
        click(b, "#shell-close")
        assert st(b)["hidden"]
    b.evaluate("location.hash = %s; ''" % json.dumps(f"#s={NAME}"))
    settle(b)
    assert b.evaluate(FOLDED)["inMenu"]      # back on a session: it folds again


def test_a_layout_pass_keeps_the_focus_on_the_shell_button(chat, fake):
    """The layout pass used to re-insert Shell, Reload and the badge on every call, which blurs a focused node: a focused Shell
    button in the bar lost its focus when the window resized or the badge changed. Now a node is moved only when it is out of place."""
    b = chat
    wide(b, 1100)
    assert b.evaluate(FOLDED)["inBar"]
    b.evaluate("document.querySelector('#shell-btn').focus(); ''")
    assert b.evaluate("document.activeElement.id") == "shell-btn"
    b.evaluate("layoutHeader(); layoutHeader(); ''")
    assert b.evaluate("document.activeElement.id") == "shell-btn"
    b.evaluate("document.querySelector('#menu-reload').focus(); layoutHeader(); ''")
    assert b.evaluate("document.activeElement.id") == "menu-reload"


def test_the_folded_shell_row_from_the_keyboard_leaves_the_focus_on_the_menu_button(chat, fake):
    """A keyboard activation (click detail 0) of the folded Shell row closes the menu under the focus: it goes back to ⋯, not to the
    body. A mouse click (detail 1) is left alone."""
    b = chat
    phone(b, 320)
    assert b.evaluate(FOLDED)["inMenu"]
    click(b, "#top-menu-btn")
    b.evaluate("document.querySelector('#shell-btn').focus(); ''")
    click(b, "#shell-btn")                       # element.click(): detail 0, as Enter or Space on the focused row
    f = b.evaluate(FOLDED)
    assert not f["menuOpen"] and f["expanded"] == "true" and f["active"] == "top-menu-btn", f
    click(b, "#shell-close")
    assert st(b)["hidden"]
    click(b, "#top-menu-btn")
    b.evaluate("document.querySelector('#shell-btn').dispatchEvent(new MouseEvent('click', { bubbles: true, detail: 1 })); ''")
    f = b.evaluate(FOLDED)
    assert not f["menuOpen"] and f["expanded"] == "true", f
