"""Copy from the Terminal tab reaches the clipboard (on some platforms a selected text in the
terminal view never reached the clipboard).

tmux (set-clipboard on) hands a selection to the terminal as OSC 52, and ttyd 1.7.7's page registers no handler for 52, so the
sequence was dropped. The app now registers one on the ttyd page's `window.term` (same origin), and puts the decoded text on
the clipboard. Here the "ttyd page" is a same-origin about:blank iframe that gets a fake `term` (an object with
`parser.registerOscHandler` that records its handlers); the test calls the recorded handler the way xterm.js would, and reads the
clipboard back. Run in a headless Chromium when one is installed (conftest.py: `served`, `browser`), else skipped.
"""

from __future__ import annotations

import base64
import json

import pytest

from conftest import NAME

OPEN_TERMINAL = """
new Promise((res) => { const t0 = Date.now(); (function poll() {
  if (typeof state !== "undefined" && state.current) {
    state.terminalUrl = "about:blank#";   // a same-origin frame stands in for ttyd
    document.querySelector("#top .tab[data-tab=terminal]").click();
    res(!!document.querySelector("#terminal-pane iframe"));
  } else if (Date.now() - t0 > 15000) res(false); else setTimeout(poll, 50);
})(); })
"""

# a fake xterm.js: records the handlers registered per OSC number; installed on the frame's window after `delay` ms
INSTALL = """
(delay) => new Promise((res) => {
  const f = document.querySelector("#terminal-pane iframe");
  window.__fakeTerm = () => { const calls = []; return { calls, parser: { registerOscHandler(id, fn) { calls.push([id, fn]); return { dispose() {} }; } } }; };
  setTimeout(() => { f.contentWindow.term = window.__fakeTerm(); res(true); }, delay);
})
"""


def b64(s: str | bytes) -> str:
    return base64.b64encode(s.encode() if isinstance(s, str) else s).decode()


def handlers(browser):
    return browser.evaluate("""new Promise((res) => { const t0 = Date.now(); (function poll() {
      const t = document.querySelector("#terminal-pane iframe").contentWindow.term;
      if ((t && t.calls.length) || Date.now() - t0 > 6000) res(t ? t.calls.map((c) => c[0]) : null); else setTimeout(poll, 50);
    })(); })""")


def fire(browser, data: str):
    """What xterm.js does on `ESC ] 52 ; <data> BEL`: the handler registered for 52 gets <data>; its return value is passed back."""
    return browser.evaluate("""(async (data) => {
      const t = document.querySelector("#terminal-pane iframe").contentWindow.term;
      const r = t.calls.filter((c) => c[0] === 52)[0][1](data);
      await new Promise((res) => setTimeout(res, 150));
      return r;
    })(%s)""" % json.dumps(data))


def clip(browser):
    return browser.evaluate("navigator.clipboard.readText()")


def put_marker(browser, text="marker"):
    browser.evaluate("navigator.clipboard.writeText(%s)" % json.dumps(text))


@pytest.fixture
def term(served, browser):
    browser.call("Browser.grantPermissions", {"origin": served["url"], "permissions": ["clipboardReadWrite", "clipboardSanitizedWrite"]})
    browser.send("Emulation.setFocusEmulationEnabled", {"enabled": True})  # navigator.clipboard wants a focused document
    browser.open(f"{served['url']}/#s={NAME}")
    assert browser.evaluate(OPEN_TERMINAL) is True
    return browser


def test_a_term_that_appears_late_is_hooked_once_and_copies(term):
    term.evaluate("(%s)(700)" % INSTALL.strip())            # the page builds its term 0.7 s after the frame loads
    assert handlers(term) == [52]
    term.evaluate("document.querySelector('#terminal-pane iframe').dispatchEvent(new Event('load'))")   # a second look at the same term
    term.evaluate("new Promise((r) => setTimeout(r, 600))")
    assert handlers(term) == [52]                          # still one registration
    assert fire(term, "c;" + b64("ABCD-1234")) is True
    assert clip(term) == "ABCD-1234"


def test_every_where_prefix_and_utf8_text_work(term):
    term.evaluate("(%s)(0)" % INSTALL.strip())
    assert handlers(term) == [52]
    for where in ("c;", "p;", ";", "s0;"):
        put_marker(term)
        text = "한글 코드 " + where.strip(";") + " ✓"
        assert fire(term, where + b64(text)) is True
        assert clip(term) == text, where
    put_marker(term)
    fire(term, "c;" + b64("a\nb\tc 한"))                   # newlines and tabs are kept
    assert clip(term) == "a\nb\tc 한"


@pytest.mark.parametrize("data", ["c;?", "c;", ";", "c", "", "c;!!!not base64!!!", "c;Q", "c;" + b64(b"\xff\xfe\xfa")])
def test_a_query_empty_or_invalid_payload_changes_nothing_and_throws_nothing(term, data):
    term.evaluate("(%s)(0)" % INSTALL.strip())
    assert handlers(term) == [52]
    put_marker(term, "kept")
    assert fire(term, data) is True                        # swallowed, never an exception
    assert clip(term) == "kept"


def test_a_reloaded_terminal_is_hooked_again(term):
    term.evaluate("(%s)(0)" % INSTALL.strip())
    assert handlers(term) == [52]
    # ttyd reloaded in the frame: a new term, then the frame's load event
    term.evaluate("""(() => { const f = document.querySelector("#terminal-pane iframe"); f.contentWindow.term = window.__fakeTerm();
                              f.dispatchEvent(new Event("load")); return 1; })()""")
    assert handlers(term) == [52]
    assert fire(term, "c;" + b64("again")) is True
    assert clip(term) == "again"


def test_no_term_ever_means_no_error_and_a_frame_that_is_gone_stops_the_poll(term):
    # nothing installs a term: the poll runs in the background and the page stays fine; removing the frame ends it
    term.evaluate("document.querySelector('#terminal-pane iframe').remove(); 1")
    term.evaluate("new Promise((r) => setTimeout(r, 600))")
    assert term.evaluate("document.querySelectorAll('#terminal-pane iframe').length") == 0


def test_a_failing_registration_does_not_break_the_frame(term):
    term.evaluate("""(() => { const f = document.querySelector("#terminal-pane iframe");
      f.contentWindow.term = { parser: { registerOscHandler() { throw new Error("nope"); } } }; f.dispatchEvent(new Event("load")); return 1; })()""")
    term.evaluate("new Promise((r) => setTimeout(r, 300))")
    assert term.evaluate("document.querySelectorAll('#terminal-pane iframe').length") == 1
