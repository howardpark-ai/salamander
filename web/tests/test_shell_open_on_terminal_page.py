"""The full-size terminal page (/terminal, static/terminal.html and terminal.js) asks for the Shell's tmux session before it loads ttyd.

ttyd's attach command only attaches to a session that is there, and a page opened without the drawer (a bookmark, a restored browser
tab, an old `/?arg=` link, "Open full size" on a host where the drawer was never opened) used to show `No tmux session named ...`.
When ?arg equals the Shell session's name (api/config `shellSession`), the page now does `POST api/shell/open` (the drawer's call) and only
then sets the frame's src; it waits for the answer for a bounded time and loads the frame whatever the answer; any other ?arg is
attached as it is and nothing is made.

* the source: the call, the bound, the order, the one condition (static, no browser);
* the page in a headless Chromium (conftest.py; skipped without one) against the app on a loopback port: the frame is not there while the
  open is pending, it is there once the open has answered, a refused open loads it anyway, a hung open loads it after the bound, another
  session makes no call.

The tmux half is replaced by a recorder (`ensure_shell_session`): nothing here makes a real tmux session. The frame's /tty/ address
has no ttyd behind it in this app, which is no matter: the test looks at the frame element, not at what loads in it.
"""

from __future__ import annotations

import asyncio
import threading
import time

import pytest

from sala_web import tmuxio as T
from sala_web.app import STATIC
from sala_web.config import SHELL_SESSION

TERMINAL_JS = (STATIC / "terminal.js").read_text()
FRAME = "document.querySelector('#term-full iframe')"


# ---------------------------------------------------------------- the source


def test_the_page_opens_the_shell_session_before_it_sets_the_frame_src_and_only_for_the_shell():
    assert TERMINAL_JS.count('"api/shell/open"') == 1                                   # the drawer's call, the same address
    assert 'method: "POST", headers: { "Content-Type": "application/json" }, body: "{}"' in TERMINAL_JS     # the drawer's headers and body
    cond = "if (arg && arg === shellSession) await openShellSession();"
    assert TERMINAL_JS.count(cond) == 1
    assert TERMINAL_JS.index(cond) < TERMINAL_JS.index("frame.src = base +")            # the open is awaited before the frame has a src
    assert TERMINAL_JS.index("c.shellSession") < TERMINAL_JS.index(cond)                # the name comes from api/config, as on the main page
    # bounded, and a failed call is swallowed so that the frame loads anyway
    assert "SHELL_OPEN_WAIT_MS = 8000" in TERMINAL_JS and "ctl.abort()" in TERMINAL_JS and "signal: ctl.signal" in TERMINAL_JS
    start = TERMINAL_JS.index("async function openShellSession()")
    body = TERMINAL_JS[start:TERMINAL_JS.index("\n}\n", start)]
    assert "catch {" in body and "throw" not in body


def test_the_served_page_loads_that_script(tmp_path):
    from starlette.testclient import TestClient

    from sala_web.app import create_app
    from test_shell_start import make_settings
    page = TestClient(create_app(make_settings(tmp_path))).get("/terminal?arg=" + SHELL_SESSION)
    assert page.status_code == 200 and 'src="static/terminal.js?v=' in page.text


# ---------------------------------------------------------------- the page


class Opens:
    """Stands in for `ensure_shell_session`: counts the calls, holds each one until `gate` is set, and fails when `fail` is."""

    def __init__(self):
        self.calls = 0
        self.gate = threading.Event()
        self.gate.set()
        self.fail = False

    async def ensure(self, settings):
        self.calls += 1
        await asyncio.get_running_loop().run_in_executor(None, self.gate.wait, 30)
        if self.fail:
            raise T.TmuxError("tmux new-session: refused")
        return False


@pytest.fixture
def opens(monkeypatch):
    o = Opens()
    monkeypatch.setattr(T, "ensure_shell_session", o.ensure)
    try:
        yield o
    finally:
        o.gate.set()                                  # never leaves a held call behind


def until(b, expr: str, secs: float = 20):
    return b.evaluate("new Promise((res) => { const t0 = Date.now(); (function poll() { let v = false; try { v = (%s); } catch (e) {} "
                      "if (v || Date.now() - t0 > %d) res(!!v); else setTimeout(poll, 50); })(); })" % (expr, secs * 1000))


def wait_calls(o: Opens, n: int, secs: float = 20) -> None:
    end = time.time() + secs
    while o.calls < n and time.time() < end:
        time.sleep(0.05)
    assert o.calls == n


def open_page(browser, served, arg: str) -> None:
    browser.open(f"{served['url']}/terminal?arg={arg}")


def test_the_shell_page_asks_for_the_session_once_and_loads_the_frame_only_after_the_answer(served, browser, opens):
    opens.gate.clear()                                # the answer is held
    open_page(browser, served, SHELL_SESSION)
    wait_calls(opens, 1)
    assert until(browser, "document.getElementById('term-full')") is True
    time.sleep(0.5)
    assert browser.evaluate(f"{FRAME} === null") is True                  # no frame while the open is pending
    opens.gate.set()
    assert until(browser, FRAME) is True
    assert browser.evaluate(f"{FRAME}.src").endswith("/tty/?arg=" + SHELL_SESSION)
    time.sleep(0.3)
    assert opens.calls == 1                                              # one open, not one per load


def test_a_refused_open_still_loads_the_frame(served, browser, opens):
    opens.fail = True                                 # the server answers 502
    open_page(browser, served, SHELL_SESSION)
    assert until(browser, FRAME) is True
    assert opens.calls == 1
    assert browser.evaluate(f"{FRAME}.src").endswith("/tty/?arg=" + SHELL_SESSION)


def test_an_open_that_never_answers_loads_the_frame_after_the_bound(served, browser, opens):
    opens.gate.clear()
    t0 = time.time()
    open_page(browser, served, SHELL_SESSION)
    wait_calls(opens, 1)
    assert browser.evaluate(f"{FRAME} === null") is True
    assert until(browser, FRAME, 25) is True          # the page's own bound is 8 s
    assert 6 < time.time() - t0 < 24
    assert browser.evaluate(f"{FRAME}.src").endswith("/tty/?arg=" + SHELL_SESSION)


@pytest.mark.parametrize("arg", ["some-claude-session", "sala-shell-not", ""])
def test_any_other_session_is_attached_as_it_is_and_makes_no_call(served, browser, opens, arg):
    open_page(browser, served, arg)
    assert until(browser, FRAME) is True
    assert browser.evaluate(f"{FRAME}.src").endswith("/tty/?arg=" + arg)
    time.sleep(0.5)
    assert opens.calls == 0
