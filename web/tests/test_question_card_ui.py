"""The card a waiting question is drawn as, in a headless Chromium (the server's reading of the screen is test_question_card.py).

The rules held here, in the session view and in the chat session's view:
  - while the session's status is "waiting" and api/s/<pid>/dialog says a card, the thread ends with a card: the question's words, a button for each option
    (a question of one answer) or a checkbox row for each (a question of several) with one Send and a hint that names it (both say Next, in the page's
    language, when the pane's button is Next), and a Cancel; the options are not a numbered list;
  - one tap on a button sends that option's number with the words of the question; ticking boxes and tapping Send sends the picks, in order; Cancel sends esc;
  - when the pane shows no question the card is gone; a session that does not wait has no card;
  - every tap target is at least 44 px tall;
  - NO SIDEWAYS SCROLL, at 1280, 390, 360 and 320 px, with long words, a long address and a long list of options: the page, the pane, the thread, the card and
    everything in it are never wider than the window, and nothing in the card scrolls by its own overflow.

What a wrong answer costs: a question the owner cannot answer from a phone, a card wider than the window, a stale card that answers the wrong question.
Runs in a headless Chromium when one is installed (conftest.py: `served`, `browser`), else is skipped; GitHub CI runs it. All names are invented."""

from __future__ import annotations

import json

import pytest

from conftest import NAME
from test_board_items_ui import wait_for
from test_chat_session_view_ui import api_chat, open_page

WORD = "w" * 200
URL = "https://example.com/" + "a-very-long-path-segment/" * 10 + "end"


def choice(n: int = 3, long: bool = False) -> dict:
    return {"kind": "choice", "text": "Pick one\n" + "\n".join(f"{i}. Option {i}" for i in range(1, n + 1)), "focus": None,
            "title": ("Which one should it be? " + WORD + " " + URL) if long else "Which one should it be?",
            "options": [{"n": i, "label": f"Option {i}" + (" " + WORD if long else ""), "description": ("It is described at length. " + URL) if long else f"About {i}", "checked": False}
                        for i in range(1, n + 1)]}


def multi(n: int = 4, long: bool = False) -> dict:
    return {**choice(n, long), "kind": "multi", "text": "Pick any\n" + "\n".join(f"{i}. [ ] Option {i}" for i in range(1, n + 1)), "focus": 1}


def serve_card(browser, card) -> None:
    """api/s/<pid>/dialog answers `window.__card` (a test changes it live); the posts are kept in `window.__posts`."""
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": """(() => {
  const real = window.fetch.bind(window), json = (o, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });
  window.__card = %s; window.__posts = [];
  window.fetch = (url, opts) => {
    if (/^api\\/s\\/\\d+\\/dialog$/.test(String(url))) {
      if (opts && opts.method === "POST") { window.__posts.push(JSON.parse(opts.body)); window.__card = null; return Promise.resolve(json({ ok: true, sent: [] })); }
      return Promise.resolve(json({ card: window.__card }));
    }
    return real(url, opts);
  };
})()""" % json.dumps(card)})


def open_card(browser, served, monkeypatch, width, card, layer) -> None:
    serve_card(browser, card)
    open_page(browser, served, monkeypatch, (width, 844 if width < 700 else 800), api_chat(waiting=[]) if layer else None, chat=NAME if layer else None)
    assert wait_for(browser, "!!document.querySelector('#chat > .q-card')", 20.0)


MEASURE = r"""(() => {
  const vw = document.documentElement.clientWidth, root = document.scrollingElement, card = document.querySelector('#chat > .q-card'), out = [], scrollers = [], small = [];
  for (const n of [card, ...card.querySelectorAll('*')]) {
    const r = n.getBoundingClientRect(), cs = getComputedStyle(n);
    if (r.width && (r.right > vw + 0.5 || r.left < -0.5)) out.push((n.className || n.tagName) + ' ' + Math.round(r.left) + '-' + Math.round(r.right));
    if ((cs.overflowX === 'auto' || cs.overflowX === 'scroll') && n.scrollWidth > n.clientWidth + 0.5) scrollers.push(n.tagName + '.' + n.className);
    if (n.matches('button, label.q-opt') && r.height < 43.5) small.push(n.className + ' ' + Math.round(r.height));
  }
  const pane = document.getElementById('chat-pane'), chat = document.getElementById('chat');
  return { vw, page: [root.scrollWidth, root.clientWidth], body: [document.body.scrollWidth, document.body.clientWidth], pane: [pane.scrollWidth, pane.clientWidth],
           chat: [chat.scrollWidth, chat.clientWidth], card: [card.scrollWidth, card.clientWidth], out: out.slice(0, 8), scrollers, small,
           last: chat.lastElementChild === card, buttons: card.querySelectorAll('button.q-opt').length, boxes: card.querySelectorAll('input[type=checkbox]').length,
           numbered: card.querySelectorAll('ol, li').length }; })()"""


def check(m: dict, where: str) -> None:
    assert m["page"][0] <= m["page"][1] and m["body"][0] <= m["body"][1], f"{where}: the page scrolls sideways: {m}"
    assert m["pane"][0] <= m["pane"][1] and m["chat"][0] <= m["chat"][1], f"{where}: the pane or the thread scrolls sideways: {m}"
    assert m["card"][0] <= m["card"][1], f"{where}: the card is wider than its box: {m}"
    assert m["out"] == [] and m["scrollers"] == [], f"{where}: something ends outside the window or scrolls by itself: {m}"
    assert m["small"] == [], f"{where}: a tap target is under 44 px: {m}"


@pytest.mark.parametrize("served", [{"status": "waiting"}], indirect=True)
@pytest.mark.parametrize("layer", [False, True], ids=["session-view", "chat-view"])
@pytest.mark.parametrize("width", [1280, 390, 360, 320])
@pytest.mark.parametrize("kind", ["choice", "multi"])
def test_no_sideways_scroll_with_long_words_and_many_options(served, browser, monkeypatch, width, layer, kind):
    card = choice(12, long=True) if kind == "choice" else multi(12, long=True)
    open_card(browser, served, monkeypatch, width, card, layer)
    m = browser.evaluate(MEASURE)
    check(m, f"{kind} at {width} ({'chat' if layer else 'session'} view)")
    assert m["last"] and m["numbered"] == 0
    assert (m["buttons"], m["boxes"]) == ((12, 0) if kind == "choice" else (0, 12))


@pytest.mark.parametrize("served", [{"status": "waiting"}], indirect=True)
@pytest.mark.parametrize("layer", [False, True], ids=["session-view", "chat-view"])
def test_a_tap_on_an_option_sends_its_number_with_the_words_of_the_question(served, browser, monkeypatch, layer):
    card = choice(3)
    open_card(browser, served, monkeypatch, 390, card, layer)
    assert browser.evaluate("[...document.querySelectorAll('#chat > .q-card button.q-opt')].map((b) => b.textContent.trim())") == \
        ["Option 1About 1", "Option 2About 2", "Option 3About 3"]
    browser.evaluate("document.querySelectorAll('#chat > .q-card button.q-opt')[1].click(); ''")
    assert wait_for(browser, "window.__posts.length === 1", 10.0)
    assert browser.evaluate("window.__posts[0]") == {"expect": card["text"], "key": "2"}
    assert wait_for(browser, "!document.querySelector('#chat > .q-card')", 10.0)     # the pane shows no question now


@pytest.mark.parametrize("served", [{"status": "waiting"}], indirect=True)
@pytest.mark.parametrize("layer", [False, True], ids=["session-view", "chat-view"])
def test_boxes_and_one_send_answer_a_question_of_several(served, browser, monkeypatch, layer):
    card = multi(4)
    open_card(browser, served, monkeypatch, 390, card, layer)
    browser.evaluate("(() => { const b = document.querySelectorAll('#chat > .q-card input[type=checkbox]'); b[2].click(); b[0].click(); b[3].click(); b[3].click(); })(); ''")
    assert browser.evaluate("[...document.querySelectorAll('#chat > .q-card input')].map((b) => b.checked)") == [True, False, True, False]
    assert browser.evaluate("window.__posts.length") == 0     # nothing is sent by ticking
    browser.evaluate("document.querySelector('#chat > .q-card .q-send').click(); ''")
    assert wait_for(browser, "window.__posts.length === 1", 10.0)
    assert browser.evaluate("window.__posts[0]") == {"expect": card["text"], "picks": [1, 3]}


@pytest.mark.parametrize("served", [{"status": "waiting"}], indirect=True)
@pytest.mark.parametrize("lang", ["en", "ko"])
def test_the_send_button_and_its_hint_of_a_question_that_is_not_the_last_say_next_in_the_pages_language(served, browser, monkeypatch, lang):
    open_card(browser, served, monkeypatch, 390, {**multi(3), "button": "Submit"}, False)
    browser.evaluate(f"SalaI18n.setLang('{lang}'); ''")
    for button, key, hint in (("Next", "app.st.cardNext", "app.st.cardMultiNext"), ("Submit", "app.st.cardSend", "app.st.cardMulti")):
        # other words each time, so the card is drawn again in the chosen language
        browser.evaluate(f"window.__card = {json.dumps({**multi(3), 'button': button, 'text': 'Pick ' + button})}; window.SalaQuestionCard.poll(); ''")
        assert wait_for(browser, f"(document.querySelector('#chat > .q-card .q-send') || {{}}).textContent === SalaI18n.t('{key}')", 10.0)
        shown, want, named = browser.evaluate(f"[document.querySelector('#chat > .q-card .q-hint').textContent, SalaI18n.t('{hint}'), SalaI18n.t('{key}')]")
        other = browser.evaluate(f"SalaI18n.t('{'app.st.cardSend' if button == 'Next' else 'app.st.cardNext'}')")
        assert shown == want and named in shown and other not in shown, (button, shown)
    words = browser.evaluate("[SalaI18n.t('app.st.cardNext'), SalaI18n.t('app.st.cardSend'), SalaI18n.lang]")
    assert words[2] == lang and words[0] != words[1] and (words[0] == "Next") == (lang == "en")


@pytest.mark.parametrize("served", [{"status": "waiting"}], indirect=True)
def test_cancel_sends_esc(served, browser, monkeypatch):
    card = choice(2)
    open_card(browser, served, monkeypatch, 390, card, False)
    browser.evaluate("document.querySelector('#chat > .q-card .q-esc').click(); ''")
    assert wait_for(browser, "window.__posts.length === 1", 10.0)
    assert browser.evaluate("window.__posts[0]") == {"expect": card["text"], "key": "esc"}


@pytest.mark.parametrize("served", [{"status": "waiting"}], indirect=True)
def test_the_card_goes_when_the_pane_shows_no_question(served, browser, monkeypatch):
    open_card(browser, served, monkeypatch, 390, choice(2), False)
    browser.evaluate("window.__card = null; window.SalaQuestionCard.poll(); ''")
    assert wait_for(browser, "!document.querySelector('#chat > .q-card')", 10.0)


@pytest.mark.parametrize("served", [{"status": "idle"}], indirect=True)
def test_a_session_that_does_not_wait_has_no_card(served, browser, monkeypatch):
    serve_card(browser, choice(2))
    open_page(browser, served, monkeypatch, (390, 844), None, chat=None)
    assert browser.evaluate("document.querySelectorAll('#chat > .q-card').length") == 0
