"""Quoting a reply's selected text into the composer, in a headless Chromium (chatquote.js, the composer hook in app.js, the bubble in renderMessage and pendingNode).

The rule: a button (desktop) or a chip (touch) shows only for a selection inside one assistant reply. A tap puts the selected lines, each with "> ", at the END of
the composer, as typed text would go: after typed text on the next line, two quotes with nothing typed between separated by one empty line. Nothing is sent by the
tap, the draft is kept, and the send trims only the leading empty lines and the trailing whitespace. A user's message shows its "> " runs as a blockquote with the
lines after it outside it, the links kept.

Held here: the button and the chip shown for a reply and not for the composer, the user's message or the sidebar; the composer text for a single line, a multi-line
selection, typed text before a quote and two quotes in a row; the draft kept and nothing sent; the send's trim; the bubble with the line after a quote and the links
inside a quote; on a phone (390 x 844, touch) the chip above the bottom 78 px; on a desktop the button beside the END of the selection for a single line, a multi-line
selection and a selection dragged backwards. What a wrong answer costs: a quote that lands mid-draft or is sent by the tap, a bubble that swallows the line after the
quote, a chip under the phone's bottom band where the browser's own bar sits, a button that jumps to the start of the selection. Runs in a headless Chromium when one
is installed (conftest.py: `served`, `browser`), else is skipped; GitHub CI runs it. All text is invented."""

from __future__ import annotations

import json
import time

import pytest

from conftest import NAME, transcript_file, transcript_line
from send_stub import spy_send
from test_board_items_ui import wait_for
from test_chat_session_view_ui import api_chat, open_page
from test_composer_editable import typed

REPLY = "Alpha line one is here.\n\nBeta second paragraph text.\n\nGamma third line ends now."
USER = "My own question"
PHONE, DESKTOP = (390, 844), (1280, 800)
BTN = ".quote-btn:not([hidden]), .quote-chip:not([hidden])"
BAR_H = 78
SPY = spy_send()


def transcript() -> str:
    return (transcript_line("user", [{"type": "text", "text": USER}], "q-1", human=True)
            + transcript_line("assistant", [{"type": "text", "text": REPLY}], "q-2", model="claude-opus-5-5"))


def open_reply(browser, served, monkeypatch, size, touch: bool = False, chat=NAME, doc=None) -> None:
    transcript_file(served).write_text(transcript())
    open_page(browser, served, monkeypatch, size, doc, chat=chat)
    assert wait_for(browser, "!!document.querySelector('.msg.assistant .md p')", 10.0)
    if touch:
        browser.touch(True)
        assert wait_for(browser, "matchMedia('(pointer: coarse) and (hover: none)').matches", 10.0)
    browser.evaluate(SPY)


def select(browser, start: str, end: str, backward: bool = False) -> None:
    """Selects from the first `start` to the `end` in the reply (dragged backwards when asked: the anchor is at the end)."""
    browser.evaluate("""(() => {
  const nodes = [], w = document.createTreeWalker(document.querySelector('.msg.assistant .md'), NodeFilter.SHOW_TEXT); let n;
  while ((n = w.nextNode())) nodes.push(n);
  const a = nodes.find((x) => x.textContent.includes(%(s)s)), b = nodes.find((x) => x.textContent.includes(%(e)s));
  const so = a.textContent.indexOf(%(s)s), eo = b.textContent.indexOf(%(e)s) + %(elen)d;
  const r = document.createRange(); r.setStart(a, so); r.setEnd(b, eo);
  const s = getSelection(); s.removeAllRanges();
  if (%(back)s) s.setBaseAndExtent(b, eo, a, so); else s.addRange(r);
  return s.toString(); })()""" % {"s": json.dumps(start), "e": json.dumps(end), "elen": len(end), "back": "true" if backward else "false"})
    assert wait_for(browser, f"!!document.querySelector({json.dumps(BTN)})", 5.0)


def select_element(browser, selector: str) -> None:
    browser.evaluate("(() => { const r = document.createRange(); r.selectNodeContents(document.querySelector(%s));"
                     " const s = getSelection(); s.removeAllRanges(); s.addRange(r); })()" % json.dumps(selector))
    time.sleep(0.5)   # the selection event runs on the next frame; the absence is checked after it


def tap(browser, selector: str = BTN) -> None:
    x, y = browser.evaluate("(() => { const r = document.querySelector(%s).getBoundingClientRect();"
                            " return [r.left + r.width / 2, r.top + r.height / 2]; })()" % json.dumps(selector))
    for kind in ("mousePressed", "mouseReleased"):
        browser.send("Input.dispatchMouseEvent", {"type": kind, "x": x, "y": y, "button": "left", "clickCount": 1})


RECT = "(() => { const b = document.querySelector(%s); if (!b) return null; const r = b.getBoundingClientRect();" \
       " return { left: r.left, right: r.right, top: r.top, bottom: r.bottom, cls: b.className, vw: innerWidth, vh: innerHeight }; })()" % json.dumps(BTN)
END_CHAR = """(() => { const r = getSelection().getRangeAt(0), e = r.endContainer, o = r.endOffset;
  const c = document.createRange(); c.setStart(e, o - 1); c.setEnd(e, o); const q = c.getBoundingClientRect();
  return { left: q.left, right: q.right, top: q.top, bottom: q.bottom }; })()"""
COMPOSER = "getText()"


def composer_is(browser, text: str) -> bool:
    return wait_for(browser, "getText() === %s" % json.dumps(text), 5.0)


# ── presence and absence ─────────────────────────────────────────────────────
@pytest.mark.parametrize("size", [pytest.param(DESKTOP, id="desktop"), pytest.param(PHONE, id="phone")])
def test_the_button_shows_for_a_reply_selection_and_not_elsewhere(served, browser, monkeypatch, size):
    open_reply(browser, served, monkeypatch, size)
    select(browser, "Alpha", "is here.")
    assert browser.evaluate(RECT)["cls"] in ("quote-btn", "quote-chip")
    browser.evaluate("setText('typed words'); document.querySelector('#input').focus();")
    select_element(browser, "#input")
    assert browser.evaluate(f"!document.querySelector({json.dumps(BTN)})"), "the composer's own text"
    select_element(browser, ".msg.user .bubble")
    assert browser.evaluate(f"!document.querySelector({json.dumps(BTN)})"), "the user's own message"
    select_element(browser, "#sidebar")
    assert browser.evaluate(f"!document.querySelector({json.dumps(BTN)})"), "the sidebar"


def test_the_button_shows_in_the_chat_session_view_too(served, browser, monkeypatch):
    open_reply(browser, served, monkeypatch, DESKTOP, chat=NAME, doc=api_chat())
    select(browser, "Alpha", "is here.")
    assert browser.evaluate(RECT)["cls"] == "quote-btn"


# ── the composer text ────────────────────────────────────────────────────────
def test_a_tap_on_an_empty_composer_puts_the_quote_at_its_end_and_sends_nothing(served, browser, monkeypatch):
    open_reply(browser, served, monkeypatch, DESKTOP)
    select(browser, "Alpha", "is here.")
    tap(browser)
    assert composer_is(browser, "> Alpha line one is here.\n")
    assert browser.evaluate("(window.__sent || []).length") == 0
    assert browser.evaluate("document.activeElement === document.querySelector('#input')")
    assert browser.evaluate(f"!document.querySelector({json.dumps(BTN)})")


def test_a_quote_after_typed_text_starts_on_the_next_line(served, browser, monkeypatch):
    open_reply(browser, served, monkeypatch, DESKTOP)
    browser.evaluate("document.querySelector('#input').focus()")
    typed(browser, "Hello")
    select(browser, "Alpha", "is here.")
    tap(browser)
    assert composer_is(browser, "Hello\n> Alpha line one is here.\n")


def test_two_quotes_with_nothing_typed_between_are_one_empty_line_apart(served, browser, monkeypatch):
    open_reply(browser, served, monkeypatch, DESKTOP)
    select(browser, "Alpha", "is here.")
    tap(browser)
    assert composer_is(browser, "> Alpha line one is here.\n")
    select(browser, "Beta", "text.")
    tap(browser)
    assert composer_is(browser, "> Alpha line one is here.\n\n> Beta second paragraph text.\n")


def test_a_multi_line_selection_quotes_every_selected_line(served, browser, monkeypatch):
    open_reply(browser, served, monkeypatch, DESKTOP)
    select(browser, "Alpha", "ends now.")
    tap(browser)
    assert wait_for(browser, "getText().endsWith('> Gamma third line ends now.\\n')", 5.0)
    lines = browser.evaluate("getText()").split("\n")[:-1]
    assert lines[0] == "> Alpha line one is here." and "Beta second paragraph text." in lines
    assert all(line == ">" or line.startswith("> ") for line in lines), lines


def test_the_draft_is_kept_after_a_quote(served, browser, monkeypatch):
    open_reply(browser, served, monkeypatch, DESKTOP)
    select(browser, "Alpha", "is here.")
    tap(browser)
    assert composer_is(browser, "> Alpha line one is here.\n")
    assert wait_for(browser, "Object.values(localStorage).includes(getText())", 8.0)
    assert browser.evaluate("!document.querySelector('#send').disabled")


def test_sending_trims_the_leading_empty_lines_and_the_trailing_whitespace(served, browser, monkeypatch):
    open_reply(browser, served, monkeypatch, DESKTOP)
    browser.evaluate("setText('\\n\\n  \\n> Alpha line one is here.\\n\\n'); refreshSendButton();")
    tap(browser, "#send")
    assert wait_for(browser, "(window.__sent || []).length === 1", 8.0)
    assert browser.evaluate("window.__sent[0].text") == "> Alpha line one is here."


# ── the user's bubble ────────────────────────────────────────────────────────
BUBBLE = """(() => { const b = [...document.querySelectorAll('.msg.user .bubble')].pop();
  return { kids: [...b.children].map((c) => [c.tagName, c.textContent]),
           margin: getComputedStyle(b.querySelector('blockquote')).marginTop + ' ' + getComputedStyle(b.querySelector('blockquote')).marginBottom,
           links: [...b.querySelectorAll('blockquote a')].map((a) => a.getAttribute('href')),
           outside: [...b.querySelectorAll(':scope > div a')].map((a) => a.getAttribute('href')) }; })()"""


def send_text(browser, text: str) -> None:
    browser.evaluate("setText(%s); refreshSendButton();" % json.dumps(text))
    tap(browser, "#send")


def test_a_sent_quote_is_a_blockquote_and_the_line_after_it_is_outside(served, browser, monkeypatch):
    open_reply(browser, served, monkeypatch, DESKTOP)
    send_text(browser, "> Alpha line one is here.\n> Beta\nAfter the quote")
    assert wait_for(browser, "!!document.querySelector('.msg.user .bubble blockquote')", 8.0)
    b = browser.evaluate(BUBBLE)
    assert b["kids"] == [["BLOCKQUOTE", "Alpha line one is here.\nBeta"], ["DIV", "After the quote"]], b
    assert b["margin"] == "0px 0px", b


def test_links_inside_a_quote_stay_links(served, browser, monkeypatch):
    open_reply(browser, served, monkeypatch, DESKTOP)
    send_text(browser, "> See https://example.com/quoted-page here\nand https://example.com/plain")
    assert wait_for(browser, "!!document.querySelector('.msg.user .bubble blockquote a')", 8.0)
    b = browser.evaluate(BUBBLE)
    assert b["links"] == ["https://example.com/quoted-page"], b
    assert b["outside"] == ["https://example.com/plain"], b


# ── placement ────────────────────────────────────────────────────────────────
@pytest.mark.parametrize("start,end,backward", [
    pytest.param("Alpha", "is here.", False, id="single-line"),
    pytest.param("Alpha", "ends now.", False, id="multi-line"),
    pytest.param("Alpha", "ends now.", True, id="multi-line-backwards"),
    pytest.param("Alpha", "is here.", True, id="single-line-backwards"),
])
def test_on_a_desktop_the_button_is_beside_the_end_of_the_selection(served, browser, monkeypatch, start, end, backward):
    open_reply(browser, served, monkeypatch, DESKTOP)
    select(browser, start, end, backward)
    b, e = browser.evaluate(RECT), browser.evaluate(END_CHAR)
    assert b["cls"] == "quote-btn", b
    assert 0 <= b["left"] - e["right"] <= 16, (b, e)        # right of the last selected character
    assert b["top"] < e["bottom"] and b["bottom"] > e["top"], (b, e)   # on the same line
    assert 0 <= b["left"] and b["right"] <= b["vw"] and 0 <= b["top"] and b["bottom"] <= b["vh"], b


def test_on_a_phone_the_chip_stays_above_the_bottom_band(served, browser, monkeypatch):
    open_reply(browser, served, monkeypatch, PHONE, touch=True)
    select(browser, "Alpha", "is here.")
    b, e = browser.evaluate(RECT), browser.evaluate(END_CHAR)
    assert b["cls"] == "quote-chip", b
    assert b["bottom"] <= b["vh"] - BAR_H, b
    assert 0 <= b["left"] and b["right"] <= b["vw"] and 0 <= b["top"], b
    assert abs(b["top"] - e["top"]) <= 120, (b, e)           # near the end of the selection
    tap(browser)
    assert composer_is(browser, "> Alpha line one is here.\n")
