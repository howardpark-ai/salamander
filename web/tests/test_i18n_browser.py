"""The KO/EN control at the foot of the session list, in a headless Chromium (conftest.py: `served`, `browser`).

Held here:

- the page starts in English, with `<html lang="en">`, and the control shows English as the chosen one;
- a tap on KO words the sidebar, the composer and the buttons in Korean, sets `<html lang="ko">`, saves the choice on the server
  (api/prefs) and keeps it across a reload, where the page is served already in Korean;
- the chat's own text (the messages of the transcript) and a half-typed message in the composer are the same after the switch,
  and a tap on EN brings back every English word the page had before;
- the age on a message ("27 days ago") and the date in its tooltip are worded in the active language;
- the New session form keeps what was typed in it when the language changes, and words its labels and hints anew;
- a choice already saved on the server is the page's language from its first paint, with no English shown first.

Not covered here: every string (test_i18n.py checks the tables against the markup and the scripts), a real phone's keyboard.
"""

from __future__ import annotations

import json
import re
import urllib.request

from conftest import NAME

HANGUL = re.compile("[" + chr(0xAC00) + "-" + chr(0xD7A3) + "]")

WAIT_READY = """
new Promise((res) => { const t0 = Date.now(); (function poll() {
  if (document.querySelectorAll("#chat > .msg").length >= 1 || Date.now() - t0 > 15000) res(true); else setTimeout(poll, 100);
})(); })
"""
# what a person reads in the chrome of the page, by role (not the chat)
WORDS = """
(() => {
  const t = (s) => (document.querySelector(s) || {}).textContent;
  const a = (s, n) => (document.querySelector(s) || { getAttribute: () => null }).getAttribute(n);
  return {
    lang: document.documentElement.lang,
    newSession: t("#side-new .label"), overview: t("#side-ovw .label"), unread: t("#side-unread .label"),
    searchPh: a("#side-q", "placeholder"), sendLabel: a("#send", "aria-label"),
    composerPh: (document.querySelector("#composer .cm-placeholder") || {}).textContent,
    sideNewTip: a("#side-new", "title"),
    langPressed: [...document.querySelectorAll(".side-lang [data-lang]")].map((b) => b.dataset.lang + ":" + b.getAttribute("aria-pressed")),
  };
})()
"""
CHAT = ("[...document.querySelectorAll('#chat > .msg')].map((m) => { const c = m.cloneNode(true);"
        " c.querySelectorAll('.stamp, .copy-btn, button, summary').forEach((e) => e.remove()); return c.textContent; })")


def wait_until(browser, expr: str, timeout_ms: int = 8000):
    return browser.evaluate(f"""new Promise((res) => {{ const t0 = Date.now(); (function poll() {{
      let v = false; try {{ v = ({expr}); }} catch (e) {{}}
      if (v || Date.now() - t0 > {timeout_ms}) res(!!v); else setTimeout(poll, 50);
    }})(); }})""")


def open_page(served, browser, frag: str = "") -> None:
    browser.open(f"{served['url']}/#s={NAME}{frag}")
    assert browser.evaluate(WAIT_READY)
    # the language is applied by the page's scripts; its control is wired once app.js has run
    assert wait_until(browser, "typeof SalaI18n !== 'undefined' && document.querySelector('.side-lang [data-lang]')")


def choose(browser, lang: str) -> None:
    browser.evaluate(f"document.querySelector('.side-lang [data-lang={lang}]').click()")
    assert wait_until(browser, f"document.documentElement.lang === '{lang}'")


def saved_lang(served) -> str:
    with urllib.request.urlopen(f"{served['url']}/api/prefs") as r:
        return json.load(r)["lang"]


def test_the_page_starts_in_english_with_the_control_showing_it(served, browser):
    open_page(served, browser)
    w = browser.evaluate(WORDS)
    assert w["lang"] == "en"
    assert w["newSession"] == "New session" and w["overview"] == "Overview" and w["unread"] == "Unread"
    assert w["searchPh"] == "Search" and w["sendLabel"] == "Send"
    assert w["langPressed"] == ["ko:false", "en:true"], w
    assert saved_lang(served) == "en"


def test_ko_words_the_chrome_in_korean_saves_it_and_keeps_it_over_a_reload(served, browser):
    open_page(served, browser)
    en = browser.evaluate(WORDS)
    choose(browser, "ko")
    ko = browser.evaluate(WORDS)
    assert ko["lang"] == "ko"
    for k in ("newSession", "overview", "unread", "searchPh", "sendLabel", "sideNewTip"):
        assert ko[k] != en[k] and HANGUL.search(ko[k]), (k, ko[k])
    assert ko["composerPh"] and ko["composerPh"] != en["composerPh"] and HANGUL.search(ko["composerPh"]), ko["composerPh"]
    assert ko["langPressed"] == ["ko:true", "en:false"], ko
    assert wait_until(browser, "true")
    assert saved_lang(served) == "ko"
    # a reload: served in Korean from the first paint
    open_page(served, browser)
    again = browser.evaluate(WORDS)
    assert again == ko, (again, ko)


def test_a_switch_leaves_the_chat_and_the_half_typed_message_alone_and_en_restores_every_word(served, browser):
    open_page(served, browser)
    en = browser.evaluate(WORDS)
    chat_before = browser.evaluate(CHAT)
    assert len(chat_before) >= 3 and any("please look at" in m for m in chat_before), chat_before
    draft = "half a message with english words, 12345 and some/dir/file"
    browser.evaluate(f"setText({json.dumps(draft)})")
    choose(browser, "ko")
    assert browser.evaluate("getText()") == draft, "the typed draft must survive a language switch"
    assert browser.evaluate(CHAT) == chat_before, "message text is never translated"
    choose(browser, "en")
    assert browser.evaluate("getText()") == draft
    assert browser.evaluate(CHAT) == chat_before
    browser.evaluate('setText("")')   # the composer's hint shows only while it is empty
    assert wait_until(browser, "document.querySelector('#composer .cm-placeholder')")
    assert browser.evaluate(WORDS) == en
    assert saved_lang(served) == "en"


def test_the_age_and_the_date_of_a_message_follow_the_language(served, browser):
    open_page(served, browser)
    snap = "[...document.querySelectorAll('#chat .stamp')].map((s) => ({ text: s.textContent, title: s.title }))"
    en = browser.evaluate(snap)
    assert en and re.search(r"ago$", en[0]["text"]), en
    choose(browser, "ko")
    ko = browser.evaluate(snap)
    assert len(ko) == len(en)
    for e, k in zip(en, ko):
        assert k["text"] != e["text"] and HANGUL.search(k["text"]), (e, k)
        assert re.search(r"\d", k["text"]), k
        assert k["title"] != e["title"] and HANGUL.search(k["title"]), (e, k)
    choose(browser, "en")
    assert browser.evaluate(snap) == en


def test_the_new_session_form_keeps_what_was_typed_and_rewords_its_labels(served, browser):
    open_page(served, browser)
    browser.evaluate("location.hash = '#new'")
    assert wait_until(browser, "document.querySelector('#ns-form') && document.querySelector('#ns-form').offsetParent !== null")
    typed = "Keep this mandate text exactly"
    browser.evaluate(f"""(() => {{ const m = document.querySelector('#ns-mandate'); m.value = {json.dumps(typed)};
      m.dispatchEvent(new Event('input', {{ bubbles: true }})); }})()""")
    labels = "({ mandate: document.querySelector('label[for=ns-mandate] span').textContent, ph: document.querySelector('#ns-mandate').placeholder, " \
             "create: document.querySelector('#ns-submit').textContent, value: document.querySelector('#ns-mandate').value })"
    en = browser.evaluate(labels)
    assert en["mandate"] == "Mandate" and en["value"] == typed
    choose(browser, "ko")
    ko = browser.evaluate(labels)
    assert ko["value"] == typed, "typed input must survive the switch"
    for k in ("mandate", "ph", "create"):
        assert ko[k] != en[k] and HANGUL.search(ko[k]), (k, ko[k])
    choose(browser, "en")
    assert browser.evaluate(labels) == en


def test_a_choice_saved_on_the_server_is_the_language_from_the_first_paint(served, browser):
    req = urllib.request.Request(f"{served['url']}/api/prefs", data=json.dumps({"lang": "ko"}).encode(), method="PUT",
                                 headers={"content-type": "application/json"})
    with urllib.request.urlopen(req) as r:
        assert json.load(r)["ok"]
    browser.open(f"{served['url']}/#s={NAME}")
    # before any script of the page has changed anything: the attribute the server wrote
    assert browser.evaluate("document.documentElement.lang") == "ko"
    assert browser.evaluate(WAIT_READY)
    assert wait_until(browser, "document.querySelector('#side-new .label') && /[" + chr(0xAC00) + "-" + chr(0xD7A3) + "]/.test(document.querySelector('#side-new .label').textContent)")
    assert browser.evaluate("document.querySelector('.side-lang [data-lang=ko]').getAttribute('aria-pressed')") == "true"
