"""A send that fails says why in plain words on the page, even when the server gave no reason.

The server's own refusals carry their reason in the JSON body and the bubble shows it ("Not sent: <reason>"). A reply with no reason
(an empty 409, a proxy's page in a 502) used to show the HTTP status text alone, or nothing, and a request that never got an answer
showed the browser's "Failed to fetch". These run in a headless Chromium (conftest.py: `served`, `browser`) and are skipped without one.
"""

from __future__ import annotations

import pytest

from test_composer_editable import enter, open_composer, typed

# JS: the answer of the send endpoint, by mode; every other request goes through
STUB = """(() => { const real = window.fetch;
  window.fetch = (u, o) => {
    if (!String(u).includes("/send")) return real(u, o);
    const m = %s;
    if (m.reject) return Promise.reject(new TypeError("Failed to fetch"));
    return Promise.resolve(new Response(m.body, { status: m.status, statusText: m.statusText || "", headers: m.json ? { "Content-Type": "application/json" } : {} })); };
  return true; })()"""
NOTE = """new Promise((res) => { const t0 = Date.now(); (function poll() {
  const n = document.querySelector("#chat .note.err");
  if (n || Date.now() - t0 > 10000) res(n ? n.textContent : null); else setTimeout(poll, 100); })(); })"""


@pytest.mark.parametrize("mode, words", [
    ('{status: 409, statusText: "Conflict", body: ""}', "Not sent: the server answered 409 Conflict and gave no reason"),
    ('{status: 502, body: "<html>Bad gateway</html>"}', "Not sent: the server answered 502 and gave no reason"),
    ('{status: 409, json: true, body: JSON.stringify({ ok: false, error: "no input box in the pane (a dialog or menu may be open); nothing sent" })}',
     "Not sent: no input box in the pane (a dialog or menu may be open); nothing sent"),
    ('{reject: true}', "Not sent: the connection to the server was lost before it answered"),
])
def test_a_failed_send_says_why(served, browser, mode, words):
    open_composer(browser, served)
    assert browser.evaluate(STUB % mode)
    typed(browser, "hello")
    enter(browser)
    assert browser.evaluate(NOTE) == words
