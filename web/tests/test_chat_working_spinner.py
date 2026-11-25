"""The chat page (/chat) shows the main view's working spinner under the last message while its session works.

The rule: when GET api/chat says the session is live and busy, one small spinner (style.css's `.inflight` holding a `.spinner`, the same look and label as the
main view's) stands after the last entry of the message list, above the composer. When the session is idle, asleep or not running there is none. It
appears and goes when api/chat flips `busy`, without the page drawing the messages again, and a page that was at its bottom stays there. With the spinner
showing the page still has no sideways scroll at 320, 360 and 1280 px. A message the owner has just sent from the page and the transcript does not show
yet adds no spinner of its own: the session's busy flag says when it works.

What a wrong answer costs: a session that is hard at work reads as idle (nothing moves under its last message), a spinner that stays after the work is done,
two spinners, a list that jumps or redraws every message when the flag flips, or a phone page that scrolls sideways.

It runs in a headless Chromium when one is installed (conftest.py: `browser`), else is skipped; GitHub CI runs it (the browser tests run there, not on the
test box). All names are invented."""

from __future__ import annotations

import json
import time

import pytest

from test_board_items_ui import wait_for
from test_chat_no_sideways_scroll import MEASURE, WIDTHS, answer, check, resize

NOW = int(time.time() * 1000)


def doc(present: str = "live", busy: bool = False, turns: int = 2) -> dict:
    entries = []
    for i in range(turns):
        entries.append({"k": "me", "ts": NOW - (turns - i) * 60000 - 30000, "text": f"question {i}"})
        entries.append({"k": "reply", "ts": NOW - (turns - i) * 60000, "text": f"answer {i}\n\n" + "a line of the reply.\n\n" * 4})
    return {
        "configured": True, "session": "chat-test-ada", "name": "Ada", "owner": "Rowan", "present": present,
        "status": "busy" if busy else "idle", "pid": 4242 if present == "live" else 0, "busy": busy,
        "version": "", "styles": "", "timezone": "UTC", "tzLabel": "UTC", "tzOffsetMin": 0, "now": NOW,
        "entries": entries, "keptToday": 0, "keptTodayFloor": False, "waiting": [], "motion": [],
    }


def stub(first: dict) -> str:
    """api/chat answers window.__chatDoc, which a test changes; no stream, so the page reads again only when told to (see `reread`)."""
    return """(() => {
  const real = window.fetch.bind(window), json = (o) => new Response(JSON.stringify(o), { headers: { "Content-Type": "application/json" } });
  window.EventSource = undefined;
  window.__chatDoc = %s;
  window.fetch = (url, opts) => String(url).startsWith("api/chat") ? Promise.resolve(json(window.__chatDoc)) : real(url, opts);
})()""" % json.dumps(first)


def open_chat(browser, served, first: dict, width: int = 390, height: int = 800) -> None:
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": stub(first)})
    browser.width, browser.height = width, height
    browser.open(f"{served['url']}/chat")
    assert wait_for(browser, "document.querySelectorAll('.thread .msg').length >= 2", 60.0), "the page did not draw"


def reread(browser, **change) -> None:
    """Change what api/chat answers and have the page read it now (the visibility event is the page's own cue to read at once)."""
    browser.evaluate("(() => { Object.assign(window.__chatDoc, " + json.dumps(change) + "); document.dispatchEvent(new Event('visibilitychange')); })(); ''")


def spinners(browser) -> int:
    return browser.evaluate("document.querySelectorAll('.inflight .spinner').length")


def test_a_live_busy_session_shows_one_spinner_under_its_last_message(served, browser):
    open_chat(browser, served, doc(busy=True))
    assert wait_for(browser, "document.querySelectorAll('.inflight .spinner').length === 1"), "no spinner for a busy session"
    m = browser.evaluate("""(() => {
  const n = document.querySelector('.inflight'), s = n.querySelector('.spinner'), last = Array.from(document.querySelectorAll('.thread > *')).pop();
  const nr = n.getBoundingClientRect(), sr = s.getBoundingClientRect(), lr = last.getBoundingClientRect(), cr = document.querySelector('.composer').getBoundingClientRect();
  return { all: document.querySelectorAll('.inflight').length, role: n.getAttribute('role'), label: n.getAttribute('aria-label'), title: n.getAttribute('title'),
           w: sr.width, h: sr.height, display: getComputedStyle(s).display, anim: getComputedStyle(s).animationName,
           after: n.previousElementSibling === document.querySelector('.thread'), below: nr.top >= lr.bottom - 0.5, aboveComposer: nr.bottom <= cr.top + 0.5 };
})()""")
    assert m["all"] == 1 and m["role"] == "status" and m["label"] and m["label"] != "app.working" and m["title"] == m["label"], m
    assert (m["w"], m["h"], m["display"], m["anim"]) == (16, 16, "inline-block", "spin"), m
    assert m["after"] and m["below"] and m["aboveComposer"], m


def test_an_idle_session_shows_none(served, browser):
    open_chat(browser, served, doc(busy=False))
    assert wait_for(browser, "document.querySelector('.bar-name i.idle') !== null")
    assert spinners(browser) == 0 and browser.evaluate("document.querySelectorAll('.inflight').length") == 0


@pytest.mark.parametrize("present", ["sleeping", "absent"])
def test_a_session_that_is_not_live_shows_none_even_if_it_says_busy(served, browser, present):
    open_chat(browser, served, doc(present=present, busy=True))
    assert wait_for(browser, "document.querySelector('.bar-name i') !== null")
    assert spinners(browser) == 0 and browser.evaluate("document.querySelectorAll('.inflight').length") == 0


def test_the_spinner_follows_the_busy_flag_without_drawing_the_messages_again(served, browser):
    open_chat(browser, served, doc(busy=False))
    assert spinners(browser) == 0
    browser.evaluate("document.querySelectorAll('.thread .msg').forEach((n, i) => { n.__kept = i + 1; }); ''")
    for busy in (True, False, True, False):
        reread(browser, busy=busy)
        assert wait_for(browser, f"document.querySelectorAll('.inflight .spinner').length === {1 if busy else 0}"), f"busy={busy}: the spinner did not follow"
        assert browser.evaluate("document.querySelectorAll('.inflight').length") == (1 if busy else 0)
        kept = browser.evaluate("Array.from(document.querySelectorAll('.thread .msg')).map((n) => n.__kept || 0).join(',')")
        assert kept == "1,2,3,4", f"busy={busy}: the messages were drawn again ({kept})"
    # the same spinner node stays while the flag stays busy: a redraw does not restart its spin
    reread(browser, busy=True)
    assert wait_for(browser, "document.querySelectorAll('.inflight .spinner').length === 1")
    browser.evaluate("document.querySelector('.inflight').__same = true; ''")
    reread(browser, busy=True, keptToday=5)   # any change draws the page again
    assert wait_for(browser, "document.querySelector('.count').textContent.includes('5')")
    assert browser.evaluate("document.querySelector('.inflight').__same === true")


def test_a_page_at_its_bottom_stays_there_when_the_spinner_comes_and_goes(served, browser):
    open_chat(browser, served, doc(busy=False, turns=14), height=600)
    assert wait_for(browser, "document.documentElement.scrollHeight > innerHeight + 400"), "the page is not tall enough to scroll"
    at_bottom = "innerHeight + scrollY >= document.documentElement.scrollHeight - 2"
    assert wait_for(browser, at_bottom), "the page did not open at its bottom"
    for busy in (True, False, True):
        reread(browser, busy=busy)
        assert wait_for(browser, f"document.querySelectorAll('.inflight .spinner').length === {1 if busy else 0}")
        assert wait_for(browser, at_bottom), f"busy={busy}: the page left its bottom"


@pytest.mark.parametrize("width", WIDTHS)
def test_no_sideways_scroll_with_the_spinner_showing(served, browser, width):
    first = answer("live")
    first["busy"] = True
    first["status"] = "busy"
    open_chat(browser, served, first, width=WIDTHS[0], height=800)
    assert wait_for(browser, "document.querySelectorAll('.inflight .spinner').length === 1")
    resize(browser, width)
    m = browser.evaluate(MEASURE)
    assert m["vw"] == width and m["msgs"] >= 3, m
    assert browser.evaluate("document.querySelectorAll('.inflight .spinner').length") == 1
    check(m, f"spinner showing at {width} px")
