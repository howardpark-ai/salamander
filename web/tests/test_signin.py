"""A sign-in proxy in front of sala (static/signin.js, docs/web-proxy.md): once its sign-in has ended, the page loads itself again, once.

The proxy is stood in for by a layer in front of the served app: signed out, a page load is sent to a sign-in page and every other request is
answered 401. A terminal frame is a small page that reads its token the way ttyd does before it opens its websocket again.

What a wrong answer costs: a page that sits dead until it is reloaded by hand; a page that reloads for ever, or reloads a signed-in reader for a
server that is down; typed text, an unsent message or an attached file gone with the reload; a reader left on another page after the sign-in.

Not covered: a real proxy and a real provider's sign-in, a real ttyd's reconnect, the installed app on a phone."""

from __future__ import annotations

import re
import time

import pytest

import conftest
from conftest import CHAT_READY, NAME
from sala_web import app as A

CHAT = f"#s={NAME}"
RELOADED = "salaweb.signin.reload"
LEFTOVERS = "Object.keys(localStorage).concat(Object.keys(sessionStorage)).filter((k) => k.startsWith('salaweb.signin'))"
# ttyd's page, as far as signin.js looks: window.term once it is up, and the token read it makes before each reconnect
FRAME = (b"<!doctype html><title>terminal</title><script>window.term = { options: null };"
         b"window.reconnect = () => fetch('token').then((r) => r.status);</script>")


def api(path: str) -> bool:
    return path.startswith("/api/")


def everything(path: str) -> bool:
    return True


class Proxy:
    """`deny` (path -> bool) says which requests are refused, None for none: a page load among them is sent to /sign-in, any other request gets
    `status`. `loads` is the path of every page load of sala's own pages."""

    def __init__(self):
        self.deny = None
        self.status = 401
        self.loads: list[str] = []

    def wrap(self, app):
        async def front(scope, receive, send):
            if scope["type"] != "http":
                return await app(scope, receive, send)

            async def reply(status: int, body: bytes = b"", headers: tuple = ()):
                await send({"type": "http.response.start", "status": status,
                            "headers": [(b"content-type", b"text/html"), (b"cache-control", b"no-store"), *headers]})
                await send({"type": "http.response.body", "body": body})

            path = scope["path"]
            if path == "/sign-in":
                return await reply(200, b"<!doctype html><title>sign in</title>")
            page = (b"sec-fetch-dest", b"document") in scope["headers"]
            if page:
                self.loads.append(path)
            if self.deny and self.deny(path):
                return await (reply(302, headers=((b"location", b"/sign-in"),)) if page else reply(self.status, b"Unauthorized"))
            if path.startswith("/tty/"):
                return await reply(200, b'{"token":""}' if path == "/tty/token" else FRAME)
            await app(scope, receive, send)
        return front


@pytest.fixture
def proxy(monkeypatch):
    """Puts the stand-in proxy in front of the app `served` starts (it must come before `served`)."""
    p, real = Proxy(), conftest.create_app
    monkeypatch.setattr(conftest, "create_app", lambda settings: p.wrap(real(settings)))
    return p


def until(check, what: str, secs: float = 20) -> None:
    end = time.time() + secs
    while time.time() < end:
        try:
            if check():
                return
        except RuntimeError:
            pass   # the page is between two documents
        time.sleep(0.1)
    raise AssertionError(what)


def open_chat(served, browser) -> None:
    browser.open(f"{served['url']}/{CHAT}")
    browser.wait_ready(CHAT_READY)
    browser.evaluate("window.__marker = 1; ''")


def attach(browser) -> None:
    browser.evaluate("addFile(new File(['x'], 'notes.txt', { type: 'text/plain' })); ''")
    until(lambda: browser.evaluate("state.uploads.length === 1 && !!state.uploads[0].name"), "the file did not go up")


def sign_in(proxy, browser) -> None:
    """At the sign-in page, then back to sala's first page as a provider that dropped the address' fragment would send the browser."""
    until(lambda: browser.evaluate("document.title === 'sign in'"), f"not sent to the sign-in; page loads: {proxy.loads}")
    time.sleep(0.5)
    assert len(proxy.loads) == 2, proxy.loads   # the first load and one reload
    proxy.deny = None
    browser.evaluate("location.replace('/'); ''")
    browser.wait_ready(CHAT_READY)


def test_both_pages_load_it_before_what_reads_the_address_or_asks_and_sala_itself_sends_no_401():
    tag = '<script src="static/signin.js?v={{v}}"></script>'
    for name, later in (("index.html", ("static/chatboot.js", "static/app.js")), ("terminal.html", ("static/terminal.js",))):
        text = (A.STATIC / name).read_text(encoding="utf-8")
        assert text.count(tag) == 1 and all(text.index(tag) < text.index(s) for s in later), name
    # signin.js takes a 401 for the proxy's: an answer of sala's own with that status would reload the page
    for f in A.STATIC.parent.glob("*.py"):
        assert not re.search(r"status_code\s*=\s*401|_err\(\s*401|return \(?401\b", f.read_text(encoding="utf-8")), f.name


def test_a_signed_in_page_and_one_whose_server_fails_are_left_alone(proxy, served, browser):
    open_chat(served, browser)
    proxy.deny = api
    for status in (502, 403, 503):
        proxy.status = status
        browser.evaluate("(async () => { await checkVersion(); await fetch('api/sessions'); SalaSignin.check(); })()")
    # one request refused while api/config still answers: not the sign-in
    proxy.status, proxy.deny = 401, lambda path: path == "/api/sessions"
    assert browser.evaluate("fetch('api/sessions').then((r) => r.status)") == 401
    time.sleep(1.5)
    assert proxy.loads == ["/"] and browser.evaluate("window.__marker") == 1
    assert browser.evaluate(LEFTOVERS) == []
    # where the reload cannot be remembered there is none: it could repeat for ever
    browser.evaluate("Storage.prototype.setItem = () => { throw new DOMException('full', 'QuotaExceededError'); }; ''")
    proxy.deny = api
    browser.evaluate("SalaSignin.check(); ''")
    time.sleep(1.5)
    assert proxy.loads == ["/"] and browser.evaluate("window.__marker") == 1


def test_a_refused_send_reloads_once_and_after_the_sign_in_nothing_typed_is_gone(proxy, served, browser):
    open_chat(served, browser)
    attach(browser)
    proxy.deny = everything
    browser.evaluate("""(() => {
      setText('first message'); send(); setText('an unfinished draft');
      const m = document.getElementById('ns-mandate'); m.value = 'half a mandate'; m.dispatchEvent(new Event('input', { bubbles: true }));
    })()""")
    sign_in(proxy, browser)
    until(lambda: browser.evaluate("document.querySelectorAll('#chat > .msg.local.failed').length === 1"), "the unsent message is not back")
    bubble = browser.evaluate("document.querySelector('#chat > .msg.local.failed').textContent")
    assert "first message" in bubble and "notes.txt" in bubble, bubble
    assert browser.evaluate("[...document.querySelectorAll('#chat > .msg.local.failed button')].some((b) => b.textContent === tl('app.pend.retry'))")
    assert browser.evaluate("location.hash") == CHAT
    assert browser.evaluate("getText()") == "an unfinished draft"
    assert browser.evaluate("document.getElementById('ns-mandate').value") == "half a mandate"
    assert browser.evaluate(LEFTOVERS) == [RELOADED]   # what was kept is taken once
    assert proxy.loads == ["/", "/", "/"]


def test_a_stream_that_stops_asks_whether_the_sign_in_ended_and_the_attached_file_stays(proxy, served, browser):
    open_chat(served, browser)
    attach(browser)
    browser.evaluate("setText('kept draft'); ''")
    # the stream, api/config and the page alone are refused: nothing else the page asks within this test could notice
    proxy.deny = lambda path: path in ("/", "/api/config") or path.endswith("/stream")
    browser.evaluate("state.es.close(); openStream(state.current); ''")
    sign_in(proxy, browser)
    until(lambda: browser.evaluate("document.querySelectorAll('#chips > *').length === 1"), "the attached file is not back")
    assert browser.evaluate("state.uploads[0].fileName") == "notes.txt"
    assert browser.evaluate("getText()") == "kept draft" and browser.evaluate("location.hash") == CHAT


def test_a_refused_upload_asks_whether_the_sign_in_ended(proxy, served, browser):
    open_chat(served, browser)
    # the upload, api/config and the page alone are refused: nothing else the page asks within this test could notice
    proxy.deny = lambda path: path in ("/", "/api/config", "/api/upload")
    browser.evaluate("addFile(new File(['x'], 'notes.txt', { type: 'text/plain' })); ''")
    sign_in(proxy, browser)
    assert browser.evaluate("location.hash") == CHAT


def test_requests_still_refused_after_the_reload_never_reload_it_again(proxy, served, browser):
    proxy.deny = api   # the page itself loads, its requests stay refused
    browser.open(f"{served['url']}/{CHAT}")
    reloaded = ("performance.getEntriesByType('navigation')[0].type === 'reload' && document.readyState === 'complete'"
                " && typeof checkVersion === 'function'")
    until(lambda: len(proxy.loads) == 2 and browser.evaluate(reloaded), f"no reload: {proxy.loads}", 60)
    for _ in range(3):
        browser.evaluate("(async () => { SalaSignin.check(); await fetch('api/sessions'); await checkVersion(); })()")
        time.sleep(0.7)
    assert proxy.loads == ["/", "/"]
    # signed in again, then out again at once: not yet; a minute after the last reload, once more
    proxy.deny = None
    assert browser.evaluate("fetch('api/config').then((r) => r.status)") == 200
    proxy.deny = api
    browser.evaluate("fetch('api/config'); ''")
    time.sleep(1.5)
    assert proxy.loads == ["/", "/"]
    browser.evaluate(f"""(() => {{
      const g = JSON.parse(sessionStorage.getItem('{RELOADED}'));
      sessionStorage.setItem('{RELOADED}', JSON.stringify({{ ...g, at: g.at - 61000 }}));
      fetch('api/config');
    }})()""")
    until(lambda: len(proxy.loads) == 3, f"no reload for a later sign-out: {proxy.loads}")
    time.sleep(1.5)
    assert proxy.loads == ["/", "/", "/"]


FRAME_UP = ("(() => { const f = document.querySelector('#term-full iframe');"
            " return !!(f && f.contentWindow.reconnect && f.contentDocument.readyState === 'complete'); })()")


@pytest.mark.parametrize("how, status, reloads", [("reconnect", 401, True), ("frame", 401, True), ("frame", 502, False)])
def test_a_terminal_that_connects_again_notices_the_ended_sign_in(proxy, served, browser, how, status, reloads):
    browser.open(f"{served['url']}/terminal?arg=demo")
    until(lambda: browser.evaluate(FRAME_UP), "the terminal frame did not come up", 60)
    time.sleep(0.5)   # its load event has been heard
    # a 502 is a terminal service that is down while sala answers; a 401 is the proxy's, on api/config too
    proxy.status = status
    proxy.deny = everything if reloads else (lambda path: path.startswith("/tty/"))
    act = "f.contentWindow.reconnect()" if how == "reconnect" else "f.src = f.src"
    browser.evaluate(f"(() => {{ const f = document.querySelector('#term-full iframe'); {act}; }})()")
    if reloads:
        until(lambda: browser.evaluate("document.title === 'sign in'"), f"not sent to the sign-in; page loads: {proxy.loads}")
        time.sleep(0.5)
        assert proxy.loads == ["/terminal", "/terminal"]
    else:
        time.sleep(5)   # past the time a frame is given to show a terminal
        assert proxy.loads == ["/terminal"]
