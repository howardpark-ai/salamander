"""The page's side of Replace: a send the server refuses because the pane's input box holds text comes back as a 409 that
carries the box's text. The failed bubble shows that text and offers Replace, which sends the same message again with
`replace` set to exactly the text it showed; a box that changed meanwhile comes back with its new text and the bubble says so.

The send is stubbed in the page (the fake session has no pane). A headless Chromium runs it when one is installed
(conftest.py: `served`, `browser`); without one the tests are skipped.
"""

from __future__ import annotations

import json

from test_bang_pending import BUBBLES, SETTLED, opened, send_text

# the next /send answers come from __answers, in order; every request body is kept in __sent
STUB = """(() => { window.__sent = []; window.__answers = []; const real = window.fetch;
  window.fetch = (u, o) => { if (!String(u).includes("/send")) return real(u, o);
    __sent.push(JSON.parse(o.body)); const a = __answers.shift() || { status: 200, body: { ok: true } };
    return Promise.resolve(new Response(JSON.stringify(a.body), { status: a.status, headers: { "Content-Type": "application/json" } })); };
  return true; })()"""
HELD = {"status": 409, "body": {"ok": False, "error": "pane input box is not empty; nothing sent", "boxText": "left over\nsecond line",
                                 "boxHidden": False, "boxChanged": False}}


def test_a_refused_send_shows_the_boxes_text_and_offers_replace(served, browser):
    opened(browser, served)
    browser.evaluate(STUB)
    browser.evaluate(f"__answers.push({json.dumps(HELD)})")
    send_text(browser, "my message")
    got = browser.evaluate(BUBBLES)
    assert len(got) == 1 and "failed" in got[0]["cls"], got
    assert got[0]["buttons"] == ["Replace", "Retry", "Edit"], got
    assert browser.evaluate('document.querySelector("#chat .msg.local .box-text").textContent') == "left over\nsecond line"
    assert "Not sent:" not in got[0]["note"]  # the bubble says what the box holds, not the raw error


def test_replace_sends_again_with_the_text_it_showed_and_the_bubble_goes_on_as_sent(served, browser):
    opened(browser, served)
    browser.evaluate(STUB)
    browser.evaluate(f"__answers.push({json.dumps(HELD)})")
    send_text(browser, "my message")
    browser.evaluate('document.querySelector("#chat .msg.local .replace-btn").click(); ""')
    assert browser.evaluate(SETTLED)
    sent = browser.evaluate("__sent")
    assert len(sent) == 2 and "replace" not in sent[0], sent
    assert sent[1]["text"] == "my message" and sent[1]["replace"] == "left over\nsecond line" and "retry" not in sent[1], sent
    assert browser.evaluate("state.pending[0].status") == "sent"
    assert browser.evaluate('document.querySelector("#chat .msg.local .box-text")') is None


def test_a_box_that_changed_is_shown_again_with_its_new_text(served, browser):
    opened(browser, served)
    changed = {"status": 409, "body": {"ok": False, "error": "the pane input box changed since it was shown; nothing cleared or sent",
                                       "boxText": "typed since", "boxHidden": True, "boxChanged": True}}
    browser.evaluate(STUB)
    j = json.dumps
    browser.evaluate(f"__answers.push({j(HELD)}, {j(changed)})")
    send_text(browser, "my message")
    browser.evaluate('document.querySelector("#chat .msg.local .replace-btn").click(); ""')
    assert browser.evaluate(SETTLED)
    got = browser.evaluate(BUBBLES)
    assert got[0]["buttons"] == ["Replace", "Retry", "Edit"], got
    assert browser.evaluate('document.querySelector("#chat .msg.local .box-text").textContent') == "typed since"
    assert "changed" in got[0]["note"] and "out of view" in browser.evaluate('document.querySelector("#chat .msg.local").textContent')
    # Replace again sends what it shows now
    browser.evaluate('document.querySelector("#chat .msg.local .replace-btn").click(); ""')
    assert browser.evaluate(SETTLED)
    assert browser.evaluate("__sent[2].replace") == "typed since"


def test_a_shell_command_refused_for_a_full_box_offers_replace_but_no_retry(served, browser):
    opened(browser, served)
    browser.evaluate(STUB)
    browser.evaluate(f"__answers.push({json.dumps(HELD)})")
    send_text(browser, "! ls")
    got = browser.evaluate(BUBBLES)
    assert got[0]["buttons"] == ["Replace", "Edit"], got
