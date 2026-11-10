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
import time
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


def settle(browser, url: str, timeout_s: float = 20.0) -> None:
    """Wait until the navigation to `url` has committed and its document has parsed. Page.navigate returns before the new document is
    attached, so an evaluate straight after browser.open can run in the old (blank) document, or raise because that document went away."""
    end = time.monotonic() + timeout_s
    while time.monotonic() < end:
        try:
            if browser.evaluate(f"location.href.startsWith({json.dumps(url)}) && !!document.documentElement && document.readyState !== 'loading'"):
                return
        except RuntimeError:
            pass   # the old document went away under the call: ask the new one
        time.sleep(0.05)
    raise AssertionError(f"the page at {url} did not load in {timeout_s} s")


def open_page(served, browser, frag: str = "") -> None:
    browser.open(f"{served['url']}/#s={NAME}{frag}")
    settle(browser, served["url"])
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
    # a script that runs before the page's own: it records the lang attribute when the server's <html> is inserted and at every change
    # after, so what the server wrote is held even though the page's scripts (which set the same language) run later
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": """
      window.__langs = [];
      new MutationObserver(() => { const h = document.documentElement; if (h) window.__langs.push(h.lang); })
        .observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ['lang'] });"""})
    browser.open(f"{served['url']}/#s={NAME}")
    settle(browser, served["url"])
    langs = browser.evaluate("window.__langs")
    assert langs and langs[0] == "ko", f"the first document the server sent was not in Korean: {langs}"
    assert set(langs) == {"ko"}, f"the page showed another language before it settled: {langs}"
    assert browser.evaluate(WAIT_READY)
    assert wait_until(browser, "document.querySelector('#side-new .label') && /[" + chr(0xAC00) + "-" + chr(0xD7A3) + "]/.test(document.querySelector('#side-new .label').textContent)")
    assert browser.evaluate("document.querySelector('.side-lang [data-lang=ko]').getAttribute('aria-pressed')") == "true"


SNAP = """(() => { const out = []; for (const e of document.querySelectorAll('*')) {
  for (const [a, t] of [['data-i18n', 'text'], ['data-i18n-title', 'title'], ['data-i18n-aria-label', 'aria-label'],
                        ['data-i18n-placeholder', 'placeholder'], ['data-i18n-word', 'data-word']]) {
    if (e.hasAttribute(a)) out.push([(e.id || e.className || e.tagName) + ' ' + a, t === 'text' ? e.textContent : e.getAttribute(t)]);
  } } return out; })()"""
VIEWS = {"chat": "0", "shell": "document.querySelector('#shell-btn').click()", "overview": "location.hash = '#sessions'",
         "schedules": "location.hash = '#schedules'", "new": "location.hash = '#new'", "search": "location.hash = '#search'"}


def test_the_markup_apply_never_overwrites_a_text_that_script_painted(served, browser):
    """The first apply of the markup runs when the document finishes loading; the header's name, the shell button's tooltip (the host
    arrives with api/config) and the like are painted by script. If such an element carried data-i18n*, whichever ran second would win.
    So an element that script paints has no data-i18n* in the markup, and a fresh apply must change nothing on any view."""
    open_page(served, browser)
    assert wait_until(browser, "typeof state !== 'undefined' && state.host")
    host = browser.evaluate("state.host")
    for lang in ("en", "ko"):
        if lang == "ko":
            choose(browser, "ko")
        for view, js in VIEWS.items():
            browser.evaluate(js + "; ''")
            browser.evaluate("new Promise((r) => setTimeout(r, 400))")
            before = browser.evaluate(SNAP)
            browser.evaluate("SalaI18n.apply(document)")
            after = browser.evaluate(SNAP)
            changed = [(b[0], b[1], a[1]) for b, a in zip(before, after) if b[1] != a[1]]
            assert not changed, f"{lang}/{view}: a fresh apply overwrote script-painted text: {changed}"
        tip = browser.evaluate("document.querySelector('#shell-btn').title")
        assert host in tip and tip.endswith(" (Ctrl+`)"), (lang, tip)
        assert (lang == "en") == tip.startswith("Shell on "), (lang, tip)
