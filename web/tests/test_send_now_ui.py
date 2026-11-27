"""The "Send now" button under a waiting message that is in the session's terminal queue (static/waiting.js view, app.js sendNow): it posts
to the session's send-now route, says why in the status line, in the page's language, when the server refuses, keeps what it does in a
tooltip (behind a (?) on a phone), and never makes the page scroll sideways at a phone's width (the owner's rule), the longest refusal
shown.

The route is stubbed in the page (the fake session has no pane); the bubble is the waiting one test_waiting_ui.py draws, from the outbox
answered in the page. A headless Chromium runs it when one is installed (conftest.py: `served`, `browser`); without one the tests are skipped.
"""

from __future__ import annotations

import json

import pytest

from sala_web import sendnow as SN
from test_board_items_ui import wait_for
from test_i18n import EN, KO
from test_waiting_ui import STATUS, msg, opened, show

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
HELP = """(() => { const q = (s) => document.querySelector("#chat " + s), h = q("button.send-now-help"), p = q(".send-now-pop");
  const shown = (n) => n.getClientRects().length > 0, r = p.getBoundingClientRect();
  return { title: q("button.send-now").title, help: shown(h), label: h.getAttribute("aria-label"), expanded: h.getAttribute("aria-expanded"),
           pop: shown(p), text: p.textContent, chat: document.querySelector("#chat").innerText, left: r.left, right: r.right,
           sent: __sent.length, vw: document.documentElement.clientWidth }; })()"""
TAP_HELP = "document.querySelector('#chat button.send-now-help').click(); ''"
TABLES = {"en": EN, "ko": KO}


def said(lang: str, code: str, **values: str) -> str:
    """The status line's words for the refusal `code` in `lang`."""
    why = TABLES[lang][f"app.sendnow.why.{code}"]
    for name, value in values.items():
        why = why.replace("{%s}" % name, value)
    return TABLES[lang]["app.sendnow.failed"].replace("{error}", why)


def answer(browser, status: int, **body) -> None:
    browser.evaluate(f"__answers.push({json.dumps({'status': status, 'body': {'ok': False, **body}})}); ''")


def test_the_button_posts_to_the_sessions_route_and_a_refusal_is_said_in_the_pages_language(served, browser):
    opened(browser, served)
    assert browser.evaluate(STUB)
    show(browser, msg(1, "one more thing", "queued"))
    answer(browser, 409, error=SN.NOT_ONE_STEP, code="notOneStep")
    got = browser.evaluate(PRESS)
    assert got["label"] == "Send now" and not got["disabled"], got
    assert got["status"] == f"Not sent now: {SN.NOT_ONE_STEP}" == said("en", "notOneStep") and got["kind"] == "error", got
    assert len(got["sent"]) == 1 and got["sent"][0]["method"] == "POST" and got["sent"][0]["body"] == "{}", got
    assert got["sent"][0]["url"].startswith("api/s/") and got["sent"][0]["url"].endswith("/send-now"), got
    browser.evaluate("SalaI18n.setLang('ko'); ''")       # the reason on screen is worded again
    assert browser.evaluate(STATUS) == said("ko", "notOneStep")
    answer(browser, 502, error="tmux failed: gone", code="tmux", detail="gone")
    got = browser.evaluate(PRESS)
    assert got["label"] == KO["app.sendnow.button"] and got["status"] == said("ko", "tmux", detail="gone"), got
    answer(browser, 409, error="a reason of a newer server", code="notYetKnown")     # no words for it: the server's own
    got = browser.evaluate(PRESS)
    assert got["status"] == KO["app.sendnow.failed"].replace("{error}", "a reason of a newer server"), got
    got = browser.evaluate(PRESS)                       # the next press is taken: the old reason goes
    assert got["status"] == "" and len(got["sent"]) == 4, got


@pytest.mark.parametrize("lang", ["en", "ko"])
def test_what_the_button_does_is_in_its_tooltip_and_on_a_phone_behind_a_question_mark(served, browser, lang):
    opened(browser, served)
    assert browser.evaluate(STUB)
    show(browser, msg(1, "one more thing", "queued"))
    browser.evaluate(f"SalaI18n.setLang('{lang}'); ''")
    tip = TABLES[lang]["app.sendnow.tip"]
    # where a pointer hovers: the button's own tooltip, and nothing more on the page
    h = browser.evaluate(HELP)
    assert h["title"] == tip and not h["help"] and not h["pop"] and tip not in h["chat"], h
    # a phone: a (?) beside the button, whose tap shows the words and sends nothing
    browser.send("Emulation.setDeviceMetricsOverride", {"width": 320, "height": 844, "deviceScaleFactor": 1, "mobile": False})
    browser.touch()
    assert wait_for(browser, "document.querySelector('#chat button.send-now-help').getClientRects().length > 0", 5.0)
    h = browser.evaluate(HELP)
    assert h["help"] and not h["pop"] and tip not in h["chat"] and h["label"] == TABLES[lang]["app.sendnow.help"], h
    browser.evaluate(TAP_HELP)
    h = browser.evaluate(HELP)
    assert h["pop"] and h["text"] == tip and h["expanded"] == "true" and h["sent"] == 0, h
    assert h["left"] >= -0.5 and h["right"] <= h["vw"] + 0.5, h
    for shut in (TAP_HELP, "document.querySelector('#chat').click(); ''",
                 "document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); ''"):
        if not browser.evaluate(HELP)["pop"]:
            browser.evaluate(TAP_HELP)
        browser.evaluate(shut)
        h = browser.evaluate(HELP)
        assert not h["pop"] and h["expanded"] == "false" and h["sent"] == 0, (shut, h)


@pytest.mark.parametrize("width", [390, 320])
def test_the_button_and_the_longest_refusal_never_scroll_the_page_sideways(served, browser, width):
    opened(browser, served)
    browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 844, "deviceScaleFactor": 1, "mobile": False})
    browser.touch()
    assert browser.evaluate(STUB)
    show(browser, msg(1, "one more thing", "queued"))
    for lang, table in TABLES.items():
        browser.evaluate(f"SalaI18n.setLang('{lang}'); ''")
        code = max(SN.CODES.values(), key=lambda c: len(table[f"app.sendnow.why.{c}"]))
        answer(browser, 409, error=table[f"app.sendnow.why.{code}"], code=code, detail="gone")
        assert browser.evaluate(PRESS)["kind"] == "error"
        browser.settle("document.querySelector('#chat')")
        m = browser.evaluate(MEASURE)
        assert m["vw"] == width, m
        for part in ("html", "body", "chat", "status"):
            assert m[part]["sw"] <= m[part]["cw"], f"the {part} scrolls sideways at {width} px in {lang}: {m}"
        assert m["button"]["right"] <= width + 0.5, m
