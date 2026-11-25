"""The chat page (/chat) never scrolls sideways: the owner's rule for every page, held for this one with hostile content.

The rule: no horizontal scroll anywhere, at any width from 320 px up, whatever a session wrote. The page is built for it (chat.css): every box may shrink
(min-width: 0), long words and addresses wrap anywhere, a code block wraps its lines, a table is laid out fixed in the message's width, and the page
itself clips. This test holds it for any later change: GET api/chat is replaced before the page loads with an answer full of what breaks a layout (a
300-character word, a long address, a wide code block, a wide table, a long item subject, a long motion line, a long kept-back line, a card with a long
title, a long name for the session), at 1280, 360 and 320 px, with the kept-back lines shown and hidden, with a long unbroken draft in the composer,
and for a sleeping session (the plain sentence and its button). The page, its body and every box must have scrollWidth <= clientWidth, no box may scroll
by its own overflow, and no visible element may end outside the window.

What a wrong answer costs: a page the owner reads on a phone grows a sideways scroll bar, or a message is wider than the window and its end is cut.

It runs in a headless Chromium when one is installed (conftest.py: `browser`), else is skipped; GitHub CI runs it (the browser tests run there, not on the
test box). All names are invented."""

from __future__ import annotations

import json
import time

import pytest

from test_board_items_ui import wait_for

WIDTHS = [1280, 360, 320]
WORD = "w" * 300
URL = "https://example.com/" + "a-very-long-path-segment/" * 12 + "end?query=" + "q" * 120
CODE = "const veryLongLine = " + "someFunction(argumentNumberOne, argumentNumberTwo, argumentNumberThree) + " * 6 + "done;"
TABLE = "| " + " | ".join(f"column-{i}-with-a-long-heading" for i in range(8)) + " |\n|" + "---|" * 8 + "\n| " + " | ".join("x" * 40 for _ in range(8)) + " |\n"
SUBJECT = "[chat-test] " + "an item subject that keeps going and going " * 8 + WORD
NOW = int(time.time() * 1000)


def answer(present: str = "live") -> dict:
    return {
        "configured": True, "session": "chat-test-" + "very-long-session-name-" * 3 + "ada", "name": "A" * 40, "owner": "Rowan",
        "present": present, "status": "idle", "pid": 4242 if present == "live" else 0, "busy": False,
        "version": "v", "styles": "s", "timezone": "Asia/Dubai", "tzLabel": "+04", "tzOffsetMin": 240, "now": NOW,
        "entries": [
            {"k": "me", "ts": NOW - 90000, "text": f"{WORD} {URL}\n\n```\n{CODE}\n```", "cards": [{"kind": "mockup", "url": "/mockup/3", "n": 3, "title": "T" * 200}]},
            {"k": "reply", "ts": NOW - 60000,
             "text": f"Here it is: {WORD}\n\n{URL}\n\n```\n{CODE}\n```\n\n{TABLE}\n`{'c' * 200}`\n\n- {WORD}\n\n> {WORD}\n\n![a picture]({URL})",
             "cards": [{"kind": "artifact", "url": "https://claude.ai/artifact/abc", "title": "L" * 200}]},
            {"k": "kept", "ts": NOW - 50000, "src": {"kind": "session", "name": "chat-test-" + "n" * 80}, "what": WORD, "did": WORD, "open": False},
            {"k": "kept", "ts": NOW - 40000, "src": {"kind": "board"}, "what": "short", "did": "", "open": True},
            {"k": "own", "ts": NOW - 30000, "text": f"[mark removed] {WORD} {URL}"},
        ],
        "keptToday": 123456, "keptTodayFloor": True,
        "waiting": [{"id": f"item#{i}", "subject": SUBJECT, "url": URL} for i in range(3)],
        "motion": [{"text": WORD + " " + "m" * 100, "at": int(time.time())} for _ in range(8)],
    }


def stub(doc: dict) -> str:
    return """(() => {
  const real = window.fetch.bind(window), json = (o) => new Response(JSON.stringify(o), { headers: { "Content-Type": "application/json" } });
  window.EventSource = undefined;   // no stream: the page reads api/chat on its own
  window.fetch = (url, opts) => String(url).startsWith("api/chat") ? Promise.resolve(json(%s)) : real(url, opts);
})()""" % json.dumps(doc)


MEASURE = r"""(() => {
  const root = document.scrollingElement, vw = document.documentElement.clientWidth, out = [], scrollers = [];
  for (const n of document.querySelectorAll("body *")) {
    const cs = getComputedStyle(n);
    if (cs.display === "none" || !n.getClientRects().length) continue;
    const r = n.getBoundingClientRect();
    if (r.width && (r.right > vw + 0.5 || r.left < -0.5)) out.push((n.className || n.tagName) + " " + (n.textContent || "").trim().slice(0, 24) + " " + Math.round(r.left) + "-" + Math.round(r.right));
    if ((cs.overflowX === "auto" || cs.overflowX === "scroll") && n.scrollWidth > n.clientWidth) scrollers.push(n.tagName + "." + n.className);
  }
  return { vw, page: { sw: root.scrollWidth, cw: root.clientWidth }, body: { sw: document.body.scrollWidth, cw: document.body.clientWidth },
           msgs: document.querySelectorAll(".thread .msg").length, kept: document.querySelectorAll(".thread .kept").length,
           outside: out.slice(0, 8), scrollers };
})()"""


def check(m: dict, where: str) -> None:
    assert m["page"]["sw"] <= m["page"]["cw"], f"{where}: the page scrolls sideways: {m}"
    assert m["body"]["sw"] <= m["body"]["cw"], f"{where}: the body scrolls sideways: {m}"
    assert m["scrollers"] == [], f"{where}: something scrolls by its own overflow: {m}"
    assert m["outside"] == [], f"{where}: something ends outside the window: {m}"


def resize(browser, width: int) -> None:
    browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 800, "deviceScaleFactor": 1, "mobile": width < 700})
    assert wait_for(browser, f"document.documentElement.clientWidth === {width}", 10.0)
    browser.settle("document.getElementById('cp')")


def open_chat(browser, served, doc: dict, width: int) -> None:
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": stub(doc)})
    browser.width, browser.height = width, 800
    browser.open(f"{served['url']}/chat")
    assert wait_for(browser, "document.querySelectorAll('.thread .msg').length >= 3 || !!document.querySelector('.compose-sleep:not([hidden])')", 60.0), "the page did not draw"


@pytest.mark.parametrize("kept", [False, True], ids=["kept-hidden", "kept-shown"])
def test_chat_no_sideways_scroll(served, browser, kept):
    """The hostile answer, at each width, with the kept-back lines hidden and shown, and a long unbroken draft in the composer."""
    open_chat(browser, served, answer("live"), WIDTHS[0])
    if kept:
        browser.evaluate("document.querySelector('#kept-switch').click(); ''")
        assert wait_for(browser, "document.querySelectorAll('.thread .kept').length === 2")
    browser.evaluate("(() => { const t = document.querySelector('.compose-input'); t.value = " + json.dumps(WORD + " " + URL) + "; t.dispatchEvent(new Event('input')); })()")
    for width in WIDTHS:
        resize(browser, width)
        m = browser.evaluate(MEASURE)
        assert m["vw"] == width and m["msgs"] >= 3, m
        assert (m["kept"] == 2) == kept, m
        check(m, f"{'kept shown' if kept else 'kept hidden'} at {width} px")


def test_chat_no_sideways_scroll_for_a_sleeping_session(served, browser):
    """The plain sentence and its button for a session that is asleep."""
    open_chat(browser, served, answer("sleeping"), WIDTHS[0])
    for width in WIDTHS:
        resize(browser, width)
        m = browser.evaluate(MEASURE)
        assert m["vw"] == width, m
        check(m, f"asleep at {width} px")
