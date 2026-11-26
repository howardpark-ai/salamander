"""The composer's placeholder and its name for a screen reader follow the page's language every time, in a headless Chromium (conftest.py: `served`, `browser`).

On a Korean page the placeholder read "Message the session" (English) after a message had been sent: the editor is made once, with the words of that
moment, and cm6Composer.resetDoc (every send, session switch and draft put back) gave those words back (test_composer_words.py has the cause and the
model; this file holds the real page). Held at a phone's width (the short placeholder) and in a wide window (the long one), against the real server:
  - a page loaded with a Korean preference has the Korean placeholder and aria-label after load;
  - after the language switches to Korean (as the page does when the saved choice arrives after the first paint) and back, and after a send (the box emptied)
    in each language, the placeholder and the aria-label are the active language's, never the other's;
  - after switching to another view (the draft kept, the box emptied) and back (the draft put back and cleared), they are the language's too.
Polling, no fixed sleeps. Korean is read from the page's own table (test_i18n.py's `KO`), never written here."""

from __future__ import annotations

import json
import urllib.request

import pytest

from conftest import CHAT_READY, NAME
from test_i18n import EN, KO
from test_i18n_browser import choose, open_page, wait_until

PHONE = (390, 844)
DESKTOP = (1280, 800)
PH = "(document.querySelector('#composer .cm-placeholder') || {}).textContent"
ARIA = "(document.querySelector('#input') || { getAttribute: () => null }).getAttribute('aria-label')"


def words(table: dict, size) -> tuple[list[str], str]:
    """(the placeholders the table allows at `size`, the aria-label): the short one on a phone; wide, the keyboard's or the touch screen's (the emulated
    device decides which, and either is the language's)."""
    ph = [table["app.composer.label"]] if size[0] <= 760 else [table["app.composer.phKeys"], table["app.composer.phTouch"]]
    return ph, table["app.composer.label"]


def put_lang(served, lang: str) -> None:
    req = urllib.request.Request(f"{served['url']}/api/prefs", data=json.dumps({"lang": lang}).encode(),
                                 headers={"Content-Type": "application/json"}, method="PUT")
    with urllib.request.urlopen(req) as r:
        assert r.status == 200 and json.load(r)["lang"] == lang


def open_at(served, browser, size) -> None:
    browser.width, browser.height = size
    open_page(served, browser)
    browser.wait_ready(CHAT_READY)


def reads(browser, size, lang_table) -> bool:
    ph, aria = words(lang_table, size)
    return wait_until(browser, f"{json.dumps(ph)}.includes({PH}) && {ARIA} === {json.dumps(aria)}")


def empty_the_box(browser) -> None:
    """What a send and a session switch do to the box: the text replaced, the placeholder back over the empty line."""
    browser.evaluate('setText("a message"); setText(""); refreshSendButton(); true')
    assert wait_until(browser, f"!!{PH}")


@pytest.mark.parametrize("size", [PHONE, DESKTOP])
def test_a_page_loaded_with_a_korean_preference_has_the_korean_placeholder_and_name(served, browser, size):
    put_lang(served, "ko")
    open_at(served, browser, size)
    assert browser.evaluate("document.documentElement.lang") == "ko"
    assert reads(browser, size, KO), (browser.evaluate(PH), browser.evaluate(ARIA))
    assert browser.evaluate(PH) not in words(EN, size)[0]


@pytest.mark.parametrize("size", [PHONE, DESKTOP])
def test_the_words_follow_a_language_switch_and_a_send_in_each_language(served, browser, size):
    open_at(served, browser, size)
    assert reads(browser, size, EN)
    choose(browser, "ko")
    assert reads(browser, size, KO)
    empty_the_box(browser)
    assert reads(browser, size, KO), "a send in Korean must not bring the English words back"
    choose(browser, "en")
    assert reads(browser, size, EN)
    empty_the_box(browser)
    assert reads(browser, size, EN)
    choose(browser, "ko")
    empty_the_box(browser)
    assert reads(browser, size, KO)


@pytest.mark.parametrize("size", [PHONE, DESKTOP])
def test_a_language_that_arrives_after_the_first_paint_is_kept_over_a_send(served, browser, size):
    """The page was made in English and the saved language (Korean) arrives by the page's own call (loadPrefs): the box made with the English words."""
    open_at(served, browser, size)
    assert reads(browser, size, EN)
    browser.evaluate("SalaI18n.setLang('ko'); true")
    assert reads(browser, size, KO)
    empty_the_box(browser)
    assert reads(browser, size, KO)


@pytest.mark.parametrize("size", [PHONE, DESKTOP])
def test_the_words_hold_after_leaving_the_session_and_coming_back_with_a_draft(served, browser, size):
    open_at(served, browser, size)
    choose(browser, "ko")
    assert reads(browser, size, KO)
    browser.evaluate('setText("a draft kept for this session"); refreshSendButton(); saveDraft(); true')
    browser.evaluate("location.hash = '#sessions'; true")
    assert wait_until(browser, "document.getElementById('overview-pane') && document.getElementById('overview-pane').offsetParent !== null")
    browser.evaluate(f"location.hash = '#s={NAME}'; true")
    browser.wait_ready(CHAT_READY)
    assert wait_until(browser, "getText() === 'a draft kept for this session'"), "the draft is put back"
    browser.evaluate('setText(""); refreshSendButton(); true')
    assert reads(browser, size, KO), "the box emptied after the draft came back"
    browser.evaluate("location.hash = '#sessions'; true")
    assert wait_until(browser, "document.getElementById('overview-pane').offsetParent !== null")
    browser.evaluate(f"location.hash = '#s={NAME}'; true")
    browser.wait_ready(CHAT_READY)
    assert reads(browser, size, KO)
