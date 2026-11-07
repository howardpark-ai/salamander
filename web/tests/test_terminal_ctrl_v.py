"""Ctrl+V pastes in the Terminal tab on Windows and Linux (ttyd 1.7.7 page, xterm.js).

Why it did not: for Ctrl+<letter> xterm.js sends the control character (Ctrl+V is 0x16) and cancels the keydown, so the browser
never fires `paste`; Shift+Insert is left alone and pasted. `hookTerminalClipboard` (static/termclip.js) now attaches a custom key handler to
the frame's `window.term` that returns false for Ctrl+V (Shift allowed; no Alt, no Meta; not on a Mac), so xterm leaves the key
to the browser, whose default is the paste.

Two levels here, both in the headless Chromium of conftest.py (skipped without one):

* a fake `term` in a same-origin about:blank frame (as test_terminal_osc52.py): the handler the app attaches, called with plain
  key events: which keys it lets the browser have, which go on to xterm, a Mac, the hook being made once, a reloaded frame;
* the real thing: the real ttyd binary (skipped when it or tmux is not installed) attached to a scratch tmux session on a PRIVATE
  tmux socket in its own temp folder, a pane that prints what it reads (`cat -v` with the terminal in raw mode), the app and ttyd
  behind one same-origin address (a small byte-level router below stands in for the reverse proxy of docs/web-proxy.md), and real
  key events through DevTools `Input.dispatchKeyEvent` (with the editing command `paste` that the browser attaches to Ctrl+V,
  Ctrl+Shift+V and Shift+Insert): the clipboard's text reaches the pane, Ctrl+C still arrives as 0x03, a Mac still sends 0x16.
"""

from __future__ import annotations

import json

import pytest

from conftest import NAME
from ttyd_harness import ALT, CTRL, SHIFT, press, real_ttyd


# ---------------------------------------------------------------- the handler, against a fake term

OPEN_TERMINAL = """
new Promise((res) => { const t0 = Date.now(); (function poll() {
  if (typeof state !== "undefined" && state.current) {
    state.terminalUrl = "about:blank#";   // a same-origin frame stands in for ttyd
    document.querySelector("#top .tab[data-tab=terminal]").click();
    res(!!document.querySelector("#terminal-pane iframe"));
  } else if (Date.now() - t0 > 15000) res(false); else setTimeout(poll, 50);
})(); })
"""

# a fake xterm.js that records the custom key handlers attached to it (as xterm.js has one slot, the last one is the live one)
INSTALL = """
(delay) => new Promise((res) => {
  const f = document.querySelector("#terminal-pane iframe");
  window.__fakeTerm = () => ({ attached: [], parser: { registerOscHandler() { return { dispose() {} }; } },
                               attachCustomKeyEventHandler(fn) { this.attached.push(fn); } });
  setTimeout(() => { f.contentWindow.term = window.__fakeTerm(); res(true); }, delay);
})
"""

# what xterm.js asks its handler: return true = xterm takes the key as usual, false = xterm ignores it, the browser handles it
VERDICT = """
((ev) => { const t = document.querySelector("#terminal-pane iframe").contentWindow.term;
           return t.attached[t.attached.length - 1](Object.assign({ type: "keydown", ctrlKey: false, shiftKey: false, altKey: false, metaKey: false }, ev)); })
"""


def verdict(browser, **ev):
    return browser.evaluate("(%s)(%s)" % (VERDICT.strip(), json.dumps(ev)))


def attached(browser) -> int:
    return browser.evaluate("""new Promise((res) => { const t0 = Date.now(); (function poll() {
      const t = document.querySelector("#terminal-pane iframe").contentWindow.term;
      if ((t && t.attached.length) || Date.now() - t0 > 6000) res(t ? t.attached.length : null); else setTimeout(poll, 50);
    })(); })""")


@pytest.fixture
def fake(served, browser):
    browser.open(f"{served['url']}/#s={NAME}")
    assert browser.evaluate(OPEN_TERMINAL) is True
    return browser


def test_ctrl_v_and_ctrl_shift_v_are_left_to_the_browser(fake):
    fake.evaluate("(%s)(0)" % INSTALL.strip())
    assert attached(fake) == 1
    assert verdict(fake, ctrlKey=True, key="v") is False
    assert verdict(fake, ctrlKey=True, key="V") is False                       # Caps Lock
    assert verdict(fake, ctrlKey=True, shiftKey=True, key="V") is False        # Ctrl+Shift+V pastes too


@pytest.mark.parametrize("ev", [
    dict(ctrlKey=True, key="c"),                                  # Ctrl+C goes to the pane
    dict(ctrlKey=True, key="x"),
    dict(ctrlKey=True, key="z"),
    dict(key="v"),                                                # plain v
    dict(shiftKey=True, key="V"),
    dict(ctrlKey=True, altKey=True, key="v"),                     # AltGr on some layouts reports Ctrl+Alt
    dict(ctrlKey=True, metaKey=True, key="v"),
    dict(metaKey=True, key="v"),
    dict(shiftKey=True, key="Insert"),                            # the browser pastes it already; xterm leaves it alone
    dict(ctrlKey=True, key="Insert"),
    dict(ctrlKey=True, key="Dead"),
    dict(type="keyup", ctrlKey=True, key="v"),                    # only the keydown
    dict(type="keypress", ctrlKey=True, key="v"),
])
def test_every_other_key_still_goes_to_xterm(fake, ev):
    fake.evaluate("(%s)(0)" % INSTALL.strip())
    assert attached(fake) == 1
    assert verdict(fake, **ev) is True


@pytest.mark.parametrize("ev", [dict(ctrlKey=True, key="v"), dict(ctrlKey=True, shiftKey=True, key="V"), dict(ctrlKey=True, key="c")])
def test_on_a_mac_everything_goes_to_xterm(fake, ev):
    fake.evaluate("""Object.defineProperty(navigator, "platform", { get: () => "MacIntel", configurable: true }); 1""")
    fake.evaluate("(%s)(0)" % INSTALL.strip())
    assert attached(fake) == 1
    assert verdict(fake, **ev) is True


def test_the_handler_is_attached_once_per_term_and_again_for_a_reloaded_frame(fake):
    fake.evaluate("(%s)(700)" % INSTALL.strip())                  # the page builds its term 0.7 s after the frame loads
    assert attached(fake) == 1
    fake.evaluate("document.querySelector('#terminal-pane iframe').dispatchEvent(new Event('load'))")   # a second look at the same term
    fake.evaluate("new Promise((r) => setTimeout(r, 600))")
    assert attached(fake) == 1
    # ttyd reloaded in the frame: a new term, then the frame's load event
    fake.evaluate("""(() => { const f = document.querySelector("#terminal-pane iframe"); f.contentWindow.term = window.__fakeTerm();
                              f.dispatchEvent(new Event("load")); return 1; })()""")
    assert attached(fake) == 1                                    # the new term has its own handler
    assert verdict(fake, ctrlKey=True, key="v") is False


def test_a_term_without_a_key_handler_slot_or_one_that_throws_is_left_working(fake):
    # a term of the shape test_terminal_osc52.py uses (no attachCustomKeyEventHandler), then one whose attach throws
    fake.evaluate("""(() => { const f = document.querySelector("#terminal-pane iframe");
      f.contentWindow.term = { parser: { registerOscHandler() { return { dispose() {} }; } } }; f.dispatchEvent(new Event("load")); return 1; })()""")
    fake.evaluate("""(() => { const f = document.querySelector("#terminal-pane iframe");
      f.contentWindow.term = { parser: { registerOscHandler() { return { dispose() {} }; } }, attachCustomKeyEventHandler() { throw new Error("nope"); } };
      f.dispatchEvent(new Event("load")); return 1; })()""")
    fake.evaluate("new Promise((r) => setTimeout(r, 300))")
    assert fake.evaluate("document.querySelectorAll('#terminal-pane iframe').length") == 1


# ---------------------------------------------------------------- the real ttyd on a private tmux socket (ttyd_harness.py)


@pytest.fixture
def real(served, browser):
    with real_ttyd(served) as (pane, port):
        url = f"http://127.0.0.1:{port}"
        browser.call("Browser.grantPermissions", {"origin": url, "permissions": ["clipboardReadWrite", "clipboardSanitizedWrite"]})
        browser.send("Emulation.setFocusEmulationEnabled", {"enabled": True})
        browser.open(f"{url}/#s={NAME}")
        assert browser.evaluate("""new Promise((res) => { const t0 = Date.now(); (function poll() {
          if (typeof state !== "undefined" && state.current) {
            document.querySelector("#top .tab[data-tab=terminal]").click();
            res(!!document.querySelector("#terminal-pane iframe"));
          } else if (Date.now() - t0 > 15000) res(false); else setTimeout(poll, 50);
        })(); })""") is True
        # ttyd's page has connected and drawn the pane (READY is on its screen), the app's hook has had its look at the new term (it polls
        # every 250 ms: a person cannot press a key inside that gap, a test can; up to 3 s, and no failure here, so that a build without the
        # hook fails at its own assertion), and the terminal has the focus
        assert browser.evaluate("""new Promise((res) => { const t0 = Date.now(); (function poll() {
          let t = null;
          try { t = document.querySelector("#terminal-pane iframe").contentWindow.term; } catch (e) { res("cross-origin"); return; }
          const rows = t && t.buffer ? Array.from({ length: t.rows }, (_, i) => t.buffer.active.getLine(i)?.translateToString(true) || "") : [];
          if (rows.join("\\n").includes("READY")) {
            const hooked = () => typeof t._core._customKeyEventHandler === "function";
            const t1 = Date.now(); (function wait() { if (hooked() || Date.now() - t1 > 3000) { t.focus(); res("ready"); } else setTimeout(wait, 50); })();
          }
          else if (Date.now() - t0 > 20000) res("timeout: " + rows.join("|")); else setTimeout(poll, 100);
        })(); })""") == "ready"
        yield {"browser": browser, "pane": pane, "url": url}


def set_clipboard(b, text: str):
    b.evaluate("navigator.clipboard.writeText(%s)" % json.dumps(text))


def test_the_clipboard_sees_a_plain_typed_key_first(real):
    # the control for the rest: a key reaches the pane through this browser, this ttyd and this tmux
    press(real["browser"], "q", "KeyQ", 81, text="q")
    assert real["pane"].wait_for("q") is True


def test_ctrl_v_pastes_the_clipboard_into_the_pane(real):
    set_clipboard(real["browser"], "pasted-by-ctrl-v")
    press(real["browser"], "v", "KeyV", 86, CTRL, commands=["paste"])
    assert real["pane"].wait_for("pasted-by-ctrl-v") is True, real["pane"].text()
    assert "^V" not in real["pane"].text()                 # and no 0x16 went along


def test_ctrl_shift_v_pastes_the_clipboard_into_the_pane(real):
    set_clipboard(real["browser"], "pasted-by-ctrl-shift-v")
    press(real["browser"], "V", "KeyV", 86, CTRL | SHIFT, commands=["paste"])
    assert real["pane"].wait_for("pasted-by-ctrl-shift-v") is True
    assert "^V" not in real["pane"].text()


def test_shift_insert_still_pastes(real):
    set_clipboard(real["browser"], "pasted-by-shift-insert")
    press(real["browser"], "Insert", "Insert", 45, SHIFT, commands=["paste"])
    assert real["pane"].wait_for("pasted-by-shift-insert") is True


@pytest.mark.parametrize("letter,caret", [("c", "^C"), ("x", "^X"), ("z", "^Z")])
def test_other_ctrl_keys_still_reach_the_pane(real, letter, caret):
    set_clipboard(real["browser"], "must-not-appear")
    press(real["browser"], letter, "Key" + letter.upper(), ord(letter.upper()), CTRL, commands=["copy"] if letter == "c" else None)
    assert real["pane"].wait_for(caret) is True            # 0x03, 0x18, 0x1a, as cat -v writes them
    assert "must-not-appear" not in real["pane"].text()


def test_ctrl_alt_v_is_not_a_paste(real):
    set_clipboard(real["browser"], "must-not-appear")
    press(real["browser"], "v", "KeyV", 86, CTRL | ALT, commands=["paste"])
    assert real["pane"].wait_for("^V") is True
    assert "must-not-appear" not in real["pane"].text()


def test_on_a_mac_ctrl_v_stays_xterms_and_sends_0x16(real):
    b = real["browser"]
    b.send("Emulation.setUserAgentOverride", {"userAgent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36",
                                              "platform": "MacIntel"})
    assert b.evaluate("navigator.platform") == "MacIntel"
    set_clipboard(b, "must-not-appear")
    press(b, "v", "KeyV", 86, CTRL, commands=["paste"])
    assert real["pane"].wait_for("^V") is True              # xterm sent 0x16 and cancelled the event: no paste
    assert "must-not-appear" not in real["pane"].text()
