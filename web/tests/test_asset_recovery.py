"""A static file that fails to load is asked for again by the page itself, with no reload (the script at the top of index.html's head).

On a mobile network a request is sometimes dropped, and a stylesheet or script that fails is skipped without a word: the side panel's search box
came up unstyled (search.css) and the Colors button was missing (colortool.js) until the page was reloaded. The page now re-requests a file that
failed, a copy placed where the failed one stood, with a cache-busting `&r=`, up to 4 tries per file, then stops.

What a wrong answer costs: a half-made page that stays half-made; a retry that loops for ever against a file that is really gone; a copy added at the
end of the head, which would win the cascade over the page's own `<style id="look">`; a second color button; a page that asks again for files that loaded.

For each of the three files (search.css, termclip.css, colortool.js) and the wiring script beside the last, on `/` at a phone's width, the
first request fails (the request aborted, or a 404) and the second goes through: the file comes back, the search box is styled, the Colors button is
drawn and a marker set on the window survives (nothing reloaded). A file that always fails is asked for 5 times in all and then left alone, and the
page still works; a page whose files all load makes no retry. Requests are held and answered by the test through DevTools' Fetch domain.

Chrome answers "Invalid InterceptionId" to an answer for a request it does not hold. This file once brought that on itself, now and then: reading
events through the page rather than its connection could take one held request twice and answer it twice (Gate.read). A refused answer still fails
the test, and the error carries what the page did (Gate.report): every held request and what it was answered, every request the page sent or lost,
its navigations, and its state. A staged cancel checks that account.

Not covered: a real phone's network (the failure is staged), the first stylesheet's failure under a real render block, and terminal.html (it loads
termclip.css and the color scripts but has no panel to draw and no script here)."""

from __future__ import annotations

import base64
import json
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
GONE = "Invalid InterceptionId"       # DevTools' answer for a held request that Chrome no longer holds
# what a report keeps of the events: these whatever request they name, the next ones only for a request that was held
ALWAYS = ("Fetch.requestPaused", "Network.requestWillBeSent", "Network.loadingFailed", "Page.frameRequestedNavigation",
          "Page.frameStartedNavigating", "Page.frameStartedLoading", "Page.frameNavigated", "Page.navigatedWithinDocument",
          "Page.domContentEventFired", "Page.loadEventFired", "Inspector.targetCrashed", "Target.detachedFromTarget")
OF_A_HELD_REQUEST = ("Network.requestServedFromCache", "Network.responseReceived", "Network.loadingFinished")
PAGE_STATE = """((files) => ({ url: location.href, readyState: document.readyState, timeOrigin: performance.timeOrigin,
  marker: window.__still_here || null, elements: [...document.querySelectorAll("link[href], script[src]")]
    .filter((e) => files.some((f) => (e.getAttribute("href") || e.getAttribute("src")).includes(f))).map((e) => e.outerHTML) }))(%s)"""


def event_line(e: dict, session: str) -> str:
    """One DevTools event in a line: its name, the ids that tie a held request to the page's own, the URL, and why a load ended."""
    p = e.get("params", {})
    out = {k: p[k] for k in ("requestId", "networkId", "loaderId", "frameId", "type", "resourceType", "timestamp", "errorText",
                             "canceled", "blockedReason", "corsErrorStatus", "url", "reason", "navigationType") if k in p}
    for holder in (p.get("request"), p.get("frame")):
        if holder:
            out.update({k: holder[k] for k in ("url", "loaderId") if k in holder})
    for k in ("response", "redirectResponse"):
        if k in p:
            out[k + "Status"] = p[k].get("status")
    if i := p.get("initiator"):
        at = (i.get("stack", {}).get("callFrames") or [i])[0]
        out["initiator"] = [i.get("type"), at.get("url", "")[-80:], at.get("lineNumber")]
    if "url" in out:
        out["url"] = out["url"][:200]
    other = "" if e.get("sessionId") == session else f" [another session: {e.get('sessionId')}]"
    return f"{e.get('method')}{other} {json.dumps(out)}"


class Gate:
    """Holds the requests for the named files and answers them: the first `fail` requests of a file fail (aborted, or a 404), the rest go on.
    `seen` is every URL asked for, by file. An answer Chrome refuses because it no longer holds the request is raised with report()."""

    def __init__(self, browser, files: dict[str, int], mode: str = "abort"):
        self.b, self.files, self.mode = browser, files, mode
        self.seen: dict[str, list[str]] = {f: [] for f in files}
        self.i = 0
        self.answers: dict[int, str] = {}                 # by a held request's place in the events: what it was answered
        browser.send("Page.enable")                       # report() reads these two domains' events
        browser.send("Network.enable")
        browser.send("Fetch.enable", {"patterns": [{"urlPattern": "*" + f + "*"} for f in files]})

    def read(self) -> None:
        """Take in what the browser has sent so far, without waiting. It reads on the connection itself: a page in a shared Chromium only
        borrows the connection's buffer, and a read through the page would leave it a second one, with an event stuck in one or taken twice."""
        c = self.b.parent or self.b
        while b"\0" in c.buf or select.select([c.r], [], [], 0)[0]:
            m = c._recv()
            if "id" not in m:
                c.events.append(m)

    def pump(self) -> None:
        """Read what the browser has sent so far (without waiting) and answer every held request."""
        b = self.b
        self.read()
        while self.i < len(b.events):
            n, e = self.i, b.events[self.i]
            self.i += 1
            if e.get("method") != "Fetch.requestPaused":
                continue
            p = e["params"]
            url = p["request"]["url"]
            f = next(f for f in self.files if f in url)
            self.seen[f].append(url)
            if len(self.seen[f]) > self.files[f]:
                method, more = "Fetch.continueRequest", {}
            elif self.mode == "404":
                method, more = "Fetch.fulfillRequest", {"responseCode": 404,
                                                        "responseHeaders": [{"name": "Content-Type", "value": "text/plain"}],
                                                        "body": base64.b64encode(b"not here").decode()}
            else:
                method, more = "Fetch.failRequest", {"errorReason": "Failed"}
            try:
                b.send(method, {"requestId": p["requestId"], **more})
            except RuntimeError as err:
                if GONE not in str(err):
                    raise
                self.answers[n] = method + " REFUSED"
                raise RuntimeError(f"{err}\n{self.report(n, f)}") from err
            self.answers[n] = method

    def report(self, n: int, f: str, secs: float = 1.0) -> str:
        """The account of the held request at place `n` in the events, whose answer Chrome refused: the events in the order they arrived, each
        held request with its answer, and the page now. It reads on for `secs` first, as the event of a cancel may come after the refusal."""
        end, notes = time.time() + secs, []
        try:
            while time.time() < end:
                self.read()
                time.sleep(0.05)
        except RuntimeError as err:
            notes.append(f"reading on failed: {err}")
        events = list(self.b.events)
        held = {e["params"].get("networkId") for e in events if e.get("method") == "Fetch.requestPaused"}
        lines = [f"{i:5} {event_line(e, self.b.session)}" + (f"  -> {self.answers[i]}" if i in self.answers else "")
                 for i, e in enumerate(events)
                 if e.get("method") in ALWAYS or (e.get("method") in OF_A_HELD_REQUEST and e["params"].get("requestId") in held)]
        try:
            page = json.dumps(self.b.evaluate(PAGE_STATE % json.dumps(list(self.files))))
        except RuntimeError as err:
            page = f"unreadable: {err}"
        return "\n".join([f"dropped: the held request at event {n}, number {len(self.seen[f])} for {f}", f"asked for: {self.seen}",
                          f"this session: {self.b.session}", *notes, "events:", *lines, f"page now: {page}"])

    def read_until(self, match, what: str, secs: float = 20) -> dict:
        """Read, answering nothing, until an event matches; that event."""
        end = time.time() + secs
        while time.time() < end:
            self.read()
            if found := next((e for e in self.b.events if match(e)), None):
                return found
            time.sleep(0.1)
        raise AssertionError(what)

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
@pytest.mark.parametrize("name", list(EFFECT))
def test_a_file_that_failed_once_comes_back_by_itself_and_is_applied_with_no_reload(served, browser, name, mode):
    gate = Gate(browser, {name: 1}, mode)
    open_page(browser, served["url"] + "/" + CHAT, gate)
    browser.evaluate("window.__still_here = 1; ''")                                    # a reload would lose it
    gate.until(EFFECT[name], f"{name}: not in effect after its first request failed ({mode}); asked for {gate.seen[name]}")
    gate.until(BUTTON, "the Colors button was not drawn")
    gate.until(STYLED, "the search box is not styled")
    assert browser.evaluate("window.__still_here") == 1, "the page was reloaded"
    assert len(gate.seen[name]) == 2 and len(gate.retries(name)) == 1, gate.seen[name]   # asked for again once, with the cache-busting copy
    assert browser.evaluate("document.querySelectorAll('#side-colors .ct-btn').length") == 1, "more than one Colors button"
    # the copy stands where the failed one stood: nothing of the page's own is left after the `<style id="look">` (css) or the wiring's scripts (js)
    kind = "script" if name.endswith(".js") else "link"
    assert browser.evaluate("document.querySelectorAll('%s[%s*=\"%s\"]').length"
                            % (kind, "src" if kind == "script" else "href", name)) == 1, "the failed element was left in the head"
    if name.endswith(".css"):
        assert browser.evaluate("(() => { const l = [...document.head.children]; const me = l.findIndex((e) => (e.getAttribute('href') || '').includes(%r));"
                                " const ex = l.findIndex((e) => e.id === 'look');"
                                " return me >= 0 && ex >= 0 && me < ex; })()" % name) is True, "the copy is after the look's rules"


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


def test_a_held_request_the_page_cancels_fails_with_the_pages_own_account_of_it(served, browser):
    """What a dropped request leaves behind, staged: the page aborts a held fetch, the answer to it is refused, and the error says so."""
    gate = Gate(browser, {"staged-cancel": 0})
    open_page(browser, served["url"] + "/" + CHAT, gate)
    browser.evaluate("window.__stop = new AbortController(); fetch('static/staged-cancel', {signal: window.__stop.signal}).catch(() => {}); ''")
    asked = gate.read_until(lambda e: e.get("method") == "Fetch.requestPaused", "the fetch was not held")["params"]["networkId"]
    browser.evaluate("window.__stop.abort(); ''")
    gate.read_until(lambda e: e.get("method") == "Network.loadingFailed" and e["params"]["requestId"] == asked, "the page reported no cancel")
    time.sleep(0.5)                                                                      # Chrome lets go of it just after
    with pytest.raises(RuntimeError, match=GONE) as got:
        gate.pump()
    lines = str(got.value).split("\n")
    assert any("Fetch.requestPaused" in x and asked in x and x.endswith("Fetch.continueRequest REFUSED") for x in lines), got.value
    assert any("Network.loadingFailed" in x and asked in x and '"canceled": true' in x for x in lines), got.value
    assert any(x.startswith("page now: ") and '"readyState": "complete"' in x for x in lines), got.value
