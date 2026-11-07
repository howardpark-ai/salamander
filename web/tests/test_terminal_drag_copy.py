"""Copy and paste in every view of a terminal: the Terminal tab, the Shell drawer and the full-size page ("Open full size").

tmux (set-clipboard on, mouse on) hands a finished drag to the terminal as OSC 52, and the app's handler on the ttyd page's term
(`hookTerminalClipboard`, static/termclip.js) writes it with `copyText`. Chrome lets a page write to the clipboard only within
about 5 s of a click or key press, counted from the mouse-DOWN of a drag, not its mouse-up. A short drag is inside that window; a
long one (a selection longer than the drawer, with the mouse held at its edge while the pane scrolls) is not: the OSC 52 sequence
arrives after the window closed, navigator.clipboard and execCommand both refuse, and the text was dropped without a word. Now a
refused copy leaves the text under a "Copy" button over the terminal, and that button's click is the gesture that copies it. The
offer has no timer: it goes away on its click, on a newer selection, or when a key is typed in that terminal.

The full-size page (static/terminal.html, GET /terminal) is what the drawer's "Open full size" link opens: ttyd's page in a frame
filling the window, hooked like the other two. A bare ttyd page in a tab has no hook, so a drag there copied nothing at all.

Two levels, both in the headless Chromium of conftest.py (skipped without one):

* the real ttyd 1.7.7 on a scratch tmux session (private socket, mouse on, set-clipboard on, the clipboard terminal feature, as
  the production tmux.conf sets them), the app and ttyd behind one address (ttyd_harness.py), and real mouse drags and key
  presses made with DevTools input events in each of the three views (the drawer's server half replaced as in
  test_shell_drawer.py; the full-size view is opened from the drawer's own link). The page is given no clipboard permission
  before a drag, so the browser's own rule applies: a quick drag copies, a slow one is offered, and the button's click copies;
  Ctrl+V pastes the clipboard into the pane;
* a fake `term` (as test_terminal_osc52.py) for the offer itself: shown only for a refused copy, one at a time, no timer, gone
  after its use, on a key typed in the terminal, and when the frame loads another page.
"""

from __future__ import annotations

import json

import pytest

from conftest import NAME
from sala_web import tmuxio as T
from ttyd_harness import CTRL, press, real_ttyd

LINE = "DRAGME-alpha beta gamma"
# the pane prints the line, READY, then what it reads (raw mode, control characters as ^X): a paste shows up in it
CMD = f"stty -icanon -echo -isig -ixon -iexten; echo {LINE}; echo READY; exec cat -v"
# what the production tmux.conf sets for the clipboard (status off only to keep the pane's first row where the text is)
OPTIONS = (("set", "-g", "status", "off"), ("set", "-g", "mouse", "on"), ("set", "-g", "set-clipboard", "on"),
           ("set", "-as", "terminal-features", ",*:clipboard"))
OFFER = ".term-copy-offer"


def until(b, expr: str, secs: float = 20):
    """Poll a JS expression until it is truthy; its last value (an object or element as true/false)."""
    return b.evaluate("new Promise((res) => { const t0 = Date.now(); (function poll() { let v = false; try { v = (%s); } catch (e) {} "
                      "if (v || Date.now() - t0 > %d) res(typeof v === 'object' ? !!v : v); else setTimeout(poll, 50); })(); })" % (expr, secs * 1000))


def wait_ms(b, ms: int):
    b.evaluate("new Promise((r) => setTimeout(r, %d))" % ms)


def clipboard(b) -> str:
    """The clipboard's text; read permission is granted only now, after the drag, so that the drag ran under the browser's own rule."""
    return b.evaluate("navigator.clipboard.readText().catch((e) => 'ERR ' + e)")


VIEWS = {"tab": ("#terminal-pane iframe", "#terminal-pane"), "drawer": ("#shell-term iframe", "#shell-term"),
         "full": ("#term-full iframe", "#term-full")}


@pytest.fixture(params=["tab", "drawer", "full"])
def where(request, served, browser, monkeypatch):
    async def ensure(settings):
        return True
    monkeypatch.setattr(T, "ensure_shell_session", ensure)             # the drawer's tmux half is not asked: the frame is ttyd's
    with real_ttyd(served, CMD, OPTIONS) as (pane, port):
        url = f"http://127.0.0.1:{port}"
        browser.open(f"{url}/#s={NAME}")
        browser.send("Emulation.setDeviceMetricsOverride", {"width": 1200, "height": 900, "deviceScaleFactor": 1, "mobile": False})
        assert until(browser, "typeof state !== 'undefined' && state.current")
        if request.param == "tab":
            browser.evaluate("document.querySelector('#top .tab[data-tab=terminal]').click(); 1")
        else:
            browser.evaluate("document.querySelector('#shell-btn').click(); 1")
        if request.param == "full":
            # the page the drawer's own link opens, in this tab (the link opens a new one)
            assert until(browser, "document.querySelector('#shell-full').getAttribute('href').startsWith('terminal?arg=')")
            link = browser.evaluate("document.querySelector('#shell-full').href")
            assert link == f"{url}/terminal?arg=sala-shell"
            browser.send("Page.navigate", {"url": link})
        sel, host = VIEWS[request.param]
        assert until(browser, f"document.querySelector({json.dumps(sel)})")
        # ttyd has drawn the pane, tmux has switched the mouse on, the app's hook has had its look at the term; the term has the focus
        assert until(browser, f"""(() => {{ const t = document.querySelector({json.dumps(sel)}).contentWindow.term;
          const ok = t && t.buffer && Array.from({{ length: t.rows }}, (_, i) => t.buffer.active.getLine(i).translateToString(true)).join('|').includes('READY')
            && t._core.coreMouseService.activeProtocol !== 'NONE' && typeof t._core._customKeyEventHandler === 'function';
          if (ok) t.focus(); return ok; }})()""")
        yield {"b": browser, "sel": sel, "url": url, "host": host, "view": request.param}


def mouse(b, kind: str, x: float, y: float, down: bool):
    b.send("Input.dispatchMouseEvent", {"type": kind, "x": x, "y": y, "button": "left" if (down or kind == "mouseReleased") else "none",
                                        "buttons": 1 if down else 0, "clickCount": 1})


def drag_line(w, hold_ms: int):
    """A real drag over the first row of the pane (the line of text), taking `hold_ms` from mouse-down to mouse-up."""
    b = w["b"]
    g = b.evaluate("""(() => { const f = document.querySelector(%s); const r = f.getBoundingClientRect(); const t = f.contentWindow.term;
      const sc = f.contentDocument.querySelector(".xterm-screen").getBoundingClientRect();
      return { x: r.left + sc.left, y: r.top + sc.top, cw: sc.width / t.cols, ch: sc.height / t.rows }; })()""" % json.dumps(w["sel"]))
    y = g["y"] + 0.5 * g["ch"]
    x0, x1 = g["x"] + 0.5 * g["cw"], g["x"] + (len(LINE) + 0.5) * g["cw"]
    mouse(b, "mouseMoved", x0, y, False)
    mouse(b, "mousePressed", x0, y, True)
    steps = 8
    for i in range(1, steps + 1):
        mouse(b, "mouseMoved", x0 + (x1 - x0) * i / steps, y, True)
        if hold_ms:
            wait_ms(b, hold_ms // steps)
    mouse(b, "mouseReleased", x1, y, False)


def clipboard_text(b) -> str:
    """The clipboard's text once there is some (up to 6 s), else ''."""
    return b.evaluate("""new Promise((res) => { const t0 = Date.now(); (async function poll() { let t = ""; try { t = await navigator.clipboard.readText(); } catch (e) { t = "ERR " + e; }
      if (t || Date.now() - t0 > 6000) res(t); else setTimeout(poll, 100); })(); })""")


def allow_reading(w):
    w["b"].call("Browser.grantPermissions", {"origin": w["url"], "permissions": ["clipboardReadWrite", "clipboardSanitizedWrite"]})


def test_a_quick_drag_copies_the_text_and_offers_nothing(where):
    drag_line(where, 0)
    allow_reading(where)
    assert clipboard_text(where["b"]).strip() == LINE
    assert where["b"].evaluate("document.querySelectorAll(%s).length" % json.dumps(OFFER)) == 0


def test_a_drag_that_took_too_long_is_offered_and_the_button_copies_it(where):
    b = where["b"]
    drag_line(where, 8000)                                              # mouse-down to mouse-up: past the browser's 5 s
    assert until(b, f"document.querySelector({json.dumps(where['host'] + ' ' + OFFER)})", 10) is True
    allow_reading(where)
    assert clipboard(b) == ""                                           # the browser refused: nothing was copied by itself
    box = b.evaluate("""(() => { const r = document.querySelector(%s).getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; })()""" % json.dumps(where["host"] + " " + OFFER + " button"))
    mouse(b, "mouseMoved", box["x"], box["y"], False)
    mouse(b, "mousePressed", box["x"], box["y"], True)
    mouse(b, "mouseReleased", box["x"], box["y"], False)                # a real click: the gesture the write needs
    assert clipboard_text(b).strip() == LINE
    assert b.evaluate("document.querySelector(%s).textContent" % json.dumps(where["host"] + " " + OFFER)).startswith("Copied")


def test_ctrl_v_pastes_the_clipboard_into_the_pane(where):
    b = where["b"]
    allow_reading(where)                                                # a paste reads the clipboard: the page may now
    b.evaluate("navigator.clipboard.writeText('pasted-in-%s')" % where["view"])
    press(b, "v", "KeyV", 86, CTRL, commands=["paste"])
    deadline = "pasted-in-" + where["view"]
    got = b.evaluate("""new Promise((res) => { const t0 = Date.now(); (function poll() { const t = document.querySelector(%s).contentWindow.term;
      const text = Array.from({ length: t.rows }, (_, i) => t.buffer.active.getLine(i).translateToString(true)).join("|");
      if (text.includes(%s) || Date.now() - t0 > 8000) res(text); else setTimeout(poll, 100); })(); })""" % (json.dumps(where["sel"]), json.dumps(deadline)))
    assert deadline in got and "^V" not in got                          # the text arrived, and no 0x16 went along


# ---------------------------------------------------------------- the offer itself, against a fake term

OPEN_TERMINAL = """
new Promise((res) => { const t0 = Date.now(); (function poll() {
  if (typeof state !== "undefined" && state.current) {
    state.terminalUrl = "about:blank#";   // a same-origin frame stands in for ttyd
    document.querySelector("#top .tab[data-tab=terminal]").click();
    res(!!document.querySelector("#terminal-pane iframe"));
  } else if (Date.now() - t0 > 15000) res(false); else setTimeout(poll, 50);
})(); })
"""

# the page's own copy attempts are scripted: `refuse` makes both navigator.clipboard and execCommand fail; every success is recorded
SCRIPT_CLIPBOARD = """
(() => {
  window.__copied = []; window.__refuse = true;
  Object.defineProperty(navigator, "clipboard", { configurable: true, value: { writeText: (t) => window.__refuse ? Promise.reject(new Error("refused")) : (window.__copied.push(t), Promise.resolve()) } });
  document.execCommand = () => false;
  const f = document.querySelector("#terminal-pane iframe");
  const osc = [];
  f.contentWindow.term = { parser: { registerOscHandler(id, fn) { osc.push([id, fn]); return { dispose() {} }; } } };
  window.__osc = (data) => osc.filter((c) => c[0] === 52)[0][1](data);
  return 1;
})()
"""


@pytest.fixture
def fake(served, browser):
    browser.open(f"{served['url']}/#s={NAME}")
    assert browser.evaluate(OPEN_TERMINAL) is True
    browser.evaluate(SCRIPT_CLIPBOARD)
    browser.evaluate("document.querySelector('#terminal-pane iframe').dispatchEvent(new Event('load')); 1")
    until(browser, "window.__osc")
    return browser


def b64(s: str) -> str:
    import base64
    return base64.b64encode(s.encode()).decode()


def offers(b) -> list:
    return b.evaluate("[...document.querySelectorAll('#terminal-pane .term-copy-offer')].map((e) => e.textContent)")


def test_a_refused_copy_is_offered_once_and_the_newest_selection_wins(fake):
    fake.evaluate("window.__osc(%s)" % json.dumps("c;" + b64("first")))
    assert until(fake, "document.querySelector('#terminal-pane .term-copy-offer')") is True
    fake.evaluate("window.__osc(%s)" % json.dumps("c;" + b64("second")))
    wait_ms(fake, 300)
    assert len(offers(fake)) == 1                                       # a newer selection replaces the offer
    fake.evaluate("window.__refuse = false; document.querySelector('#terminal-pane .term-copy-offer button').click()")
    assert until(fake, "window.__copied.length") == 1
    assert fake.evaluate("window.__copied") == ["second"]
    assert until(fake, "document.querySelector('#terminal-pane .term-copy-offer').textContent.startsWith('Copied')") is True
    assert until(fake, "!document.querySelector('#terminal-pane .term-copy-offer')", 5) is True      # and goes away after its use


def test_a_copy_that_works_offers_nothing_and_a_refused_button_says_so(fake):
    fake.evaluate("window.__refuse = false; window.__osc(%s)" % json.dumps("c;" + b64("fine")))
    wait_ms(fake, 400)
    assert fake.evaluate("window.__copied") == ["fine"] and offers(fake) == []
    fake.evaluate("window.__refuse = true; window.__osc(%s)" % json.dumps("c;" + b64("later")))
    assert until(fake, "document.querySelector('#terminal-pane .term-copy-offer')") is True
    fake.evaluate("document.querySelector('#terminal-pane .term-copy-offer button').click()")      # still refused
    assert until(fake, "document.querySelector('#terminal-pane .term-copy-offer').textContent.startsWith('Copy failed')") is True
    assert fake.evaluate("window.__copied") == ["fine"]


def test_no_offer_for_a_frame_that_is_gone(fake):
    fake.evaluate("window.__keep = window.__osc; document.querySelector('#terminal-pane iframe').remove(); window.__keep(%s)" % json.dumps("c;" + b64("orphan")))
    wait_ms(fake, 300)
    assert fake.evaluate("document.querySelectorAll('.term-copy-offer').length") == 0


def test_the_offer_has_no_timer(fake):
    # every delay the page schedules while the offer is made is short: nothing is set to expire it (a click is a fresh gesture)
    fake.evaluate("""(() => { window.__delays = []; const st = window.setTimeout.bind(window);
      window.setTimeout = (fn, ms, ...a) => { window.__delays.push(ms || 0); return st(fn, ms, ...a); }; return 1; })()""")
    fake.evaluate("window.__osc(%s)" % json.dumps("c;" + b64("kept")))
    assert until(fake, "document.querySelector('#terminal-pane .term-copy-offer')") is True
    wait_ms(fake, 500)
    assert max(fake.evaluate("window.__delays") or [0]) < 5000
    assert len(offers(fake)) == 1


def test_a_key_typed_in_the_terminal_dismisses_the_offer(fake):
    fake.evaluate("window.__osc(%s)" % json.dumps("c;" + b64("typed over")))
    assert until(fake, "document.querySelector('#terminal-pane .term-copy-offer')") is True
    fake.evaluate("""(() => { const d = document.querySelector('#terminal-pane iframe').contentDocument;
      d.dispatchEvent(new KeyboardEvent('keydown', { key: 'a', bubbles: true })); return 1; })()""")
    assert until(fake, "!document.querySelector('#terminal-pane .term-copy-offer')", 5) is True


def test_a_key_typed_elsewhere_leaves_the_offer(fake):
    fake.evaluate("window.__osc(%s)" % json.dumps("c;" + b64("still here")))
    assert until(fake, "document.querySelector('#terminal-pane .term-copy-offer')") is True
    fake.evaluate("document.dispatchEvent(new KeyboardEvent('keydown', { key: 'a', bubbles: true })); 1")
    wait_ms(fake, 400)
    assert len(offers(fake)) == 1


def test_a_frame_that_loads_another_page_drops_the_offer(fake):
    fake.evaluate("window.__osc(%s)" % json.dumps("c;" + b64("old page")))
    assert until(fake, "document.querySelector('#terminal-pane .term-copy-offer')") is True
    fake.evaluate("document.querySelector('#terminal-pane iframe').dispatchEvent(new Event('load')); 1")
    assert until(fake, "!document.querySelector('#terminal-pane .term-copy-offer')", 5) is True
