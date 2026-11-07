"""A static file that fails to load is asked for again by the page itself, with no reload (the script at the top of index.html's head).

On a mobile network a request is sometimes dropped, and a stylesheet or script that fails is skipped without a word: the side panel's search box
came up unstyled (search.css) and the Colors button was missing (colortool.js) until the page was reloaded. The page now re-requests a file that
failed, a copy placed where the failed one stood, with a cache-busting `&r=`, up to 4 tries per file, then stops.

What a wrong answer costs: a half-made page that stays half-made; a retry that loops for ever against a file that is really gone; a copy added at the
end of the head, which would win the cascade over the v2 layer's own rules; a second color button; a page that asks again for files that loaded.

For each of the three files (search.css, termclip.css, colortool.js) and the wiring script beside the last, on `/` and `/v2/` at a phone's width, the
first request fails (the request aborted, or a 404) and the second goes through: the file comes back, the search box is styled, the Colors button is
drawn and a marker set on the window survives (nothing reloaded). A file that always fails is asked for 5 times in all and then left alone, and the
page still works; a page whose files all load makes no retry. Requests are held and answered by the test through DevTools' Fetch domain.

Not covered: a real phone's network (the failure is staged), the first stylesheet's failure under a real render block, and terminal.html (it loads
termclip.css and the color scripts but has no panel to draw and no script here)."""

from __future__ import annotations

import base64
import select
import time

import pytest

from conftest import NAME

CHAT = f"#s={NAME}"
STYLED = ("(() => { const q = document.getElementById('side-q'), s = getComputedStyle(q);"
          " return s.height === '44px' && s.paddingLeft === '32px' && s.borderTopWidth === '1px'; })()")
TERMCLIP = "getComputedStyle(document.getElementById('terminal-pane')).position === 'relative'"
BUTTON = "document.querySelectorAll('#side-colors .ct-btn').length === 1"
READY = "document.readyState === 'complete' && typeof state !== 'undefined'"
# one check per file: what shows the file is in effect
EFFECT = {"static/search.css": STYLED, "static/termclip.css": TERMCLIP, "static/colortool.js": BUTTON, "static/colortool-sala.js": BUTTON}
MAX_TRIES = 4


class Gate:
    """Holds the requests for the named files and answers them: the first `fail` requests of a file fail (aborted, or a 404), the rest go on.
    `seen` is every URL asked for, by file."""

    def __init__(self, browser, files: dict[str, int], mode: str = "abort"):
        self.b, self.files, self.mode = browser, files, mode
        self.seen: dict[str, list[str]] = {f: [] for f in files}
        self.i = 0
        browser.send("Fetch.enable", {"patterns": [{"urlPattern": "*" + f + "*"} for f in files]})

    def pump(self) -> None:
        """Read what the browser has sent so far (without waiting) and answer every held request."""
        b = self.b
        while b"\0" in b.buf or select.select([b.r], [], [], 0)[0]:
            m = b._recv()
            if "id" not in m:
                b.events.append(m)
        while self.i < len(b.events):
            e = b.events[self.i]
            self.i += 1
            if e.get("method") != "Fetch.requestPaused":
                continue
            p = e["params"]
            url = p["request"]["url"]
            f = next(f for f in self.files if f in url)
            self.seen[f].append(url)
            if len(self.seen[f]) > self.files[f]:
                b.send("Fetch.continueRequest", {"requestId": p["requestId"]})
            elif self.mode == "404":
                b.send("Fetch.fulfillRequest", {"requestId": p["requestId"], "responseCode": 404,
                                                "responseHeaders": [{"name": "Content-Type", "value": "text/plain"}],
                                                "body": base64.b64encode(b"not here").decode()})
            else:
                b.send("Fetch.failRequest", {"requestId": p["requestId"], "errorReason": "Failed"})

    def until(self, expr: str, what: str, secs: float = 20) -> None:
        """Answer requests and read `expr` on the page until it is true."""
        end = time.time() + secs
        while time.time() < end:
            self.pump()
            try:
                if self.b.evaluate(expr):
                    return
            except RuntimeError:
                pass                      # the page is between documents
            time.sleep(0.1)
        raise AssertionError(what)

    def hold(self, secs: float) -> None:
        end = time.time() + secs
        while time.time() < end:
            self.pump()
            time.sleep(0.1)

    def retries(self, f: str) -> list[str]:
        return [u for u in self.seen[f] if "&r=" in u]


def open_page(browser, url: str, gate: Gate) -> None:
    browser.send("Page.enable")
    browser.open(url)                      # phone width, dark scheme
    gate.until(READY, f"{url} did not finish loading")


@pytest.mark.parametrize("mode", ["abort", "404"])
@pytest.mark.parametrize("path", ["/", "/v2/"])
@pytest.mark.parametrize("name", list(EFFECT))
def test_a_file_that_failed_once_comes_back_by_itself_and_is_applied_with_no_reload(served, browser, name, path, mode):
    gate = Gate(browser, {name: 1}, mode)
    open_page(browser, served["url"] + path + CHAT, gate)
    browser.evaluate("window.__still_here = 1; ''")                                    # a reload would lose it
    gate.until(EFFECT[name], f"{name}: not in effect after its first request failed ({mode}); asked for {gate.seen[name]}")
    gate.until(BUTTON, "the Colors button was not drawn")
    gate.until(STYLED, "the search box is not styled")
    assert browser.evaluate("window.__still_here") == 1, "the page was reloaded"
    assert len(gate.seen[name]) == 2 and len(gate.retries(name)) == 1, gate.seen[name]   # asked for again once, with the cache-busting copy
    assert browser.evaluate("document.querySelectorAll('#side-colors .ct-btn').length") == 1, "more than one Colors button"
    # the copy stands where the failed one stood: nothing of the page's own is left after the v2 layer's <style> (v2) or the wiring's scripts (v1)
    kind = "script" if name.endswith(".js") else "link"
    assert browser.evaluate("document.querySelectorAll('%s[%s*=\"%s\"]').length"
                            % (kind, "src" if kind == "script" else "href", name)) == 1, "the failed element was left in the head"
    if name.endswith(".css"):
        assert browser.evaluate("(() => { const l = [...document.head.children]; const me = l.findIndex((e) => (e.getAttribute('href') || '').includes(%r));"
                                " const ex = l.findIndex((e) => e.id === 'v2-extra');"
                                " return me >= 0 && (ex < 0 || me < ex); })()" % name) is True, "the copy is after the v2 layer's rules"


def test_a_file_that_always_fails_is_asked_for_a_bounded_number_of_times_and_the_page_still_works(served, browser):
    name = "static/search.css"
    gate = Gate(browser, {name: 99}, "abort")
    open_page(browser, served["url"] + "/" + CHAT, gate)
    gate.until("document.querySelectorAll('link[href*=\"static/search.css\"]').length >= 1 && true", "no link")
    gate.hold(15)                                                                        # past the checks at 4 s and 12 s
    assert len(gate.seen[name]) == 1 + MAX_TRIES, gate.seen[name]
    gate.hold(3)
    assert len(gate.seen[name]) == 1 + MAX_TRIES, "it asked again after giving up"
    gate.until(BUTTON, "the Colors button is missing because of an unrelated file")
    assert browser.evaluate("document.getElementById('side-q') !== null && document.querySelector('#chat .msg') !== null")


def test_a_page_whose_files_all_load_makes_no_second_request_for_any_file(served, browser):
    files = {f: 0 for f in EFFECT}
    gate = Gate(browser, files)
    open_page(browser, served["url"] + "/" + CHAT, gate)
    gate.until(BUTTON, "the Colors button was not drawn")
    gate.hold(6)                                                                         # past the 4 s check
    assert all(len(u) == 1 for u in gate.seen.values()), gate.seen
    assert not any(gate.retries(f) for f in files)
    gate.until(STYLED, "the search box is not styled")
