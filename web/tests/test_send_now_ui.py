"""The "Send now" button under a waiting message that is in the session's terminal queue (static/waiting.js view, app.js sendNow): it posts
to the session's send-now route, says why in the status line when the server refuses, and never makes the page scroll sideways at a
phone's width (the owner's rule), the longest refusal shown.

The route is stubbed in the page (the fake session has no pane); the bubble is the waiting one test_waiting_ui.py draws, from the outbox
answered in the page. A headless Chromium runs it when one is installed (conftest.py: `served`, `browser`); without one the tests are skipped.
"""

from __future__ import annotations

import json

import pytest

from sala_web import sendnow as SN
from test_waiting_ui import msg, opened, show

# the send-now answers come from __answers, in order; every request is kept in __sent (other requests go on to the page's fetch)
STUB = """(() => { window.__sent = []; window.__answers = []; const prev = window.fetch;
  window.fetch = (u, o) => { if (!String(u).endsWith("/send-now")) return prev(u, o);
    __sent.push({ url: String(u), method: o.method, body: o.body }); const a = __answers.shift() || { status: 200, body: { ok: true } };
    return Promise.resolve(new Response(JSON.stringify(a.body), { status: a.status, headers: { "Content-Type": "application/json" } })); };
  return true; })()"""
PRESS = """new Promise((res) => { const b = document.querySelector("#chat button.send-now"), n = __sent.length, t0 = Date.now(); b.click();
  (function poll() { if ((__sent.length > n && !b.disabled) || Date.now() - t0 > 5000)
    res({ label: b.textContent, disabled: b.disabled, status: document.querySelector("#send-status").textContent,
          kind: document.querySelector("#send-status").className, sent: __sent }); else setTimeout(poll, 20); })(); })"""
MEASURE = """(() => { const box = (n) => ({ sw: n.scrollWidth, cw: n.clientWidth, right: n.getBoundingClientRect().right });
  return { vw: document.documentElement.clientWidth, html: box(document.documentElement), body: box(document.body),
           chat: box(document.querySelector("#chat")), status: box(document.querySelector("#send-status")),
           button: box(document.querySelector("#chat button.send-now")) }; })()"""


def test_the_button_posts_to_the_sessions_route_and_a_refusal_is_shown(served, browser):
    opened(browser, served)
    assert browser.evaluate(STUB)
    show(browser, msg(1, "one more thing", "queued"))
    refusal = {"status": 409, "body": {"ok": False, "error": SN.NOT_ONE_STEP}}
    browser.evaluate(f"__answers.push({json.dumps(refusal)})")
    got = browser.evaluate(PRESS)
    assert got["label"] == "Send now" and not got["disabled"], got
    assert got["status"] == f"Not sent now: {SN.NOT_ONE_STEP}" and got["kind"] == "error", got
    assert len(got["sent"]) == 1 and got["sent"][0]["method"] == "POST" and got["sent"][0]["body"] == "{}", got
    assert got["sent"][0]["url"].startswith("api/s/") and got["sent"][0]["url"].endswith("/send-now"), got
    got = browser.evaluate(PRESS)                       # the next press is taken: the old reason goes
    assert got["status"] == "" and len(got["sent"]) == 2, got


@pytest.mark.parametrize("width", [390, 320])
def test_the_button_and_the_longest_refusal_never_scroll_the_page_sideways(served, browser, width):
    opened(browser, served)
    browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 844, "deviceScaleFactor": 1, "mobile": False})
    assert browser.evaluate(STUB)
    show(browser, msg(1, "one more thing", "queued"))
    longest = max([SN.NOT_ONE_STEP, SN.NO_STEP, SN.BANG, SN.NO_QUEUED, *SN.NOT_READY.values()], key=len)
    browser.evaluate(f"__answers.push({json.dumps({'status': 409, 'body': {'ok': False, 'error': longest}})})")
    assert browser.evaluate(PRESS)["kind"] == "error"
    browser.settle("document.querySelector('#chat')")
    m = browser.evaluate(MEASURE)
    assert m["vw"] == width, m
    for part in ("html", "body", "chat", "status"):
        assert m[part]["sw"] <= m[part]["cw"], f"the {part} scrolls sideways at {width} px: {m}"
    assert m["button"]["right"] <= width + 0.5, m
