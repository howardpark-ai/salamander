"""The pages' addresses in a headless Chromium (static/address.js; the server's side and the script's own rules: test_addresses.py):
a view's path survives a reload, a link of before (/#s=<name>) becomes the view's path in place, Back and Forward walk the paths, and
all of it holds with the app under a path prefix. The browser, the stubbed APIs and the history helpers are test_back_button.py's.
"""

from __future__ import annotations

import time

import pytest

import conftest
from conftest import CHAT_READY, NAME, PAGE_READY
from test_back_button import B, C, back, forward, hist, in_session, on_overview, open_app, reload, row, tap

AT = "location.pathname + location.search + location.hash"
# what the page asked for under a view's folder instead of the app's root: a relative address that was resolved against the view's
MISPLACED = r"performance.getEntriesByType('resource').map((e) => e.name).filter((n) => /\/(s|lane)\/(static|api|s|lane)\//.test(n))"
PREFIX = "/some/prefix"


def until(browser, expr: str, timeout: float = 60.0) -> None:
    """Wait for `expr`, across a navigation to another document (where a call can fail for a moment)."""
    end, last = time.time() + timeout, None
    while time.time() < end:
        try:
            if browser.evaluate(expr):
                return
        except RuntimeError as e:
            last = e
        time.sleep(0.1)
    raise AssertionError(f"not within {timeout:.0f} s: {expr}; last error: {last}")


def addresses(browser) -> list[str]:
    """The path and query of each history entry of sala's (those after the sentinel open_app starts from)."""
    urls = [e["url"] for e in browser.send("Page.getNavigationHistory")["entries"]]
    s = max(i for i, u in enumerate(urls) if u.endswith("/manifest.webmanifest"))
    return ["/" + u.split("/", 3)[3] for u in urls[s + 1:]]


@pytest.mark.parametrize("width", [390, 1280])
def test_a_reload_on_a_session_s_address_shows_that_session(served, browser, width):
    open_app(browser, served, f"s/{B}", width=width)
    for _ in range(2):
        in_session(hist(browser), B)
        assert browser.evaluate(AT) == f"/s/{B}" and browser.evaluate(MISPLACED) == []
        reload(browser, f"state.selected === '{B}'")
    assert addresses(browser) == [f"/s/{B}"]


@pytest.mark.parametrize("old, new, shown", [
    (f"#s={B}", f"/s/{B}", f"state.selected === '{B}'"),
    ("#sessions", "/overview", "document.body.classList.contains('overview-open')"),
    ("#usage", "/usage", "document.querySelector('#overview-pane').dataset.tab === 'usage'"),
    ("#new", "/new", "ns.open"),
    ("#lane=api", "/lane/api", "document.body.classList.contains('lane-open')"),
    ("#search?q=zebra&hours=24", "/search?q=zebra&hours=24", "SalaAddress.here().startsWith('#search?')"),
])
def test_a_link_of_before_opens_its_view_at_the_view_s_address(served, browser, old, new, shown):
    open_app(browser, served, old, width=1280)
    until(browser, shown)
    assert browser.evaluate(AT) == new
    assert addresses(browser) == [new], "rewritten in place: no entry added, none left with the old form"
    reload(browser, shown)
    assert browser.evaluate(AT) == new and browser.evaluate(MISPLACED) == []
    assert back(browser)["left"]


def test_back_and_forward_walk_the_addresses_before_and_after_a_reload(served, browser):
    open_app(browser, served, "overview", width=1280)
    on_overview(hist(browser))
    for name in (B, C):
        tap(browser, row(name))
    assert addresses(browser) == ["/overview", f"/s/{B}", f"/s/{C}"]
    in_session(back(browser), B)
    assert browser.evaluate(AT) == f"/s/{B}"
    on_overview(back(browser))
    assert browser.evaluate(AT) == "/overview"
    in_session(forward(browser), B)
    # after a reload the entries around are other documents, each loaded from the server at its own address
    reload(browser, f"state.selected === '{B}'")
    for step, path, shown in ((1, f"/s/{C}", f"state.selected === '{C}'"), (-1, f"/s/{B}", f"state.selected === '{B}'"),
                              (-1, "/overview", "document.body.classList.contains('overview-open')")):
        browser.evaluate(f"history.go({step}); ''")
        until(browser, f"{PAGE_READY} && location.pathname === '{path}' && {shown}")
        assert browser.evaluate(MISPLACED) == []
    assert addresses(browser) == ["/overview", f"/s/{B}", f"/s/{C}"]


@pytest.fixture
def prefixed(monkeypatch):
    """Puts the app `served` starts under PREFIX, as a proxy that strips it would; the list is what was asked for outside it.
    It must come before `served`."""
    outside: list[str] = []
    real = conftest.create_app

    def create(settings):
        app = real(settings)

        async def front(scope, receive, send):
            if scope["type"] != "http":
                return await app(scope, receive, send)
            if not scope["path"].startswith(PREFIX + "/"):
                if scope["path"] != "/favicon.ico":
                    outside.append(scope["path"])
                await send({"type": "http.response.start", "status": 404, "headers": []})
                return await send({"type": "http.response.body", "body": b""})
            inner = dict(scope, path=scope["path"][len(PREFIX):], raw_path=scope["raw_path"][len(PREFIX):])
            await app(inner, receive, send)
        return front

    monkeypatch.setattr(conftest, "create_app", create)
    return outside


def test_under_a_path_prefix_the_addresses_stay_inside_it(prefixed, served, browser):
    root = served["url"] + PREFIX
    browser.open(f"{root}/s/{NAME}")
    browser.wait_ready(CHAT_READY)
    assert browser.evaluate(AT) == f"{PREFIX}/s/{NAME}"
    browser.reload(CHAT_READY)
    browser.evaluate("document.querySelector('#side-ovw').click(); ''")
    until(browser, f"location.pathname === '{PREFIX}/overview' && document.body.classList.contains('overview-open')")
    browser.reload("document.body.classList.contains('overview-open')")
    browser.evaluate("window.__stale = true; ''")
    browser.open(f"{root}/#s={NAME}")
    browser.wait_ready(CHAT_READY)
    assert browser.evaluate(AT) == f"{PREFIX}/s/{NAME}" and browser.evaluate(MISPLACED) == []
    assert prefixed == [], "every address the page asked for was under the prefix"
