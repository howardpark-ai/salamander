"""Indent and Outdent buttons for a phone, which has no Tab key.

They show above the keyboard only on a touch screen, with the editor focused and the caret on a numbered item, and are hidden
on every other line and on a computer. A tap runs the command Tab and Shift+Tab run (renumbering included) and must not take
the focus, or the keyboard would close. Headless Chromium over DevTools, a tap as a press and a release of the mouse
on the button in a touch-emulated page (DevTools touch events hang this Chromium now and then; the handlers are the mouse and click ones either way), a computer as the default context. What no test here can show: a real
phone keyboard staying up.
"""

from __future__ import annotations

import json

from sala_web.app import STATIC
from test_composer_editable import open_composer
from test_composer_touch import touch

LIST = "1. a\n2. b\n3. c"
STATE = """(() => ({ text: getText(), sel: selectionOf(), focus: document.activeElement ? document.activeElement.id : null }))()"""
BOX = """(() => { const k = document.querySelector('#list-keys'), shown = getComputedStyle(k).display !== 'none' && !k.hidden;
  const r = (id) => { const b = document.querySelector(id).getBoundingClientRect(); return [b.width, b.height]; };
  return { shown, out: r('#list-outdent'), ind: r('#list-indent'), bottom: k.getBoundingClientRect().bottom,
           rowTop: document.querySelector('.compose-row').getBoundingClientRect().top,
           names: [...k.querySelectorAll('button')].map((b) => [b.getAttribute('aria-label'), b.title]) }; })()"""


def at(browser, text: str, line: int, focus: bool = True) -> None:
    """The composer set to `text`, the caret at the end of line `line` (1-based), the editor focused or not."""
    start = len("\n".join(text.split("\n")[:line - 1])) + (1 if line > 1 else 0) + len(text.split("\n")[line - 1])
    browser.evaluate("setText(%s); %s selectOffsets(%d, %d); ''" % (json.dumps(text), "composer.focus();" if focus else "", start, start))


def shown(browser) -> bool:
    return browser.evaluate(BOX)["shown"]


def tap(browser, selector: str) -> None:
    """A press and a release on the button, the way a finger's tap reaches the page (mousedown, mouseup, click)."""
    # after a moment (a headless page may draw no frame to wait for), so the layout the buttons' appearance made has been drawn when the finger lands
    x, y = browser.evaluate("new Promise((res) => setTimeout(() => { const r = document.querySelector(%s).getBoundingClientRect(); res([r.x + r.width / 2, r.y + r.height / 2]); }, 100))" % json.dumps(selector))
    for kind in ("mousePressed", "mouseReleased"):
        browser.send("Input.dispatchMouseEvent", {"type": kind, "x": x, "y": y, "button": "left", "buttons": 1 if kind == "mousePressed" else 0, "clickCount": 1})


def test_no_buttons_on_a_computer(served, browser):
    touch(browser, False)
    open_composer(browser, served)
    assert not browser.evaluate("matchMedia('(pointer: coarse)').matches")
    at(browser, LIST, 2)
    assert not shown(browser)
    assert browser.evaluate("document.querySelector('#list-keys').hidden")


def test_the_pair_shows_only_on_a_numbered_line(served, browser):
    touch(browser)
    open_composer(browser, served)
    assert browser.evaluate("matchMedia('(pointer: coarse)').matches")
    for text, line, want in [("plain", 1, False), (LIST, 2, True), ("- a\n- b", 2, False), ("1. a\n\nplain", 3, False), ("1. a\n\nplain", 2, False),
                             ("1. a\n  2. b", 2, True)]:
        at(browser, text, line)
        assert shown(browser) is want, (text, line)
    # the caret moving from a numbered line to a plain one, and back, follows
    at(browser, "1. a\nplain", 1)
    assert shown(browser)
    browser.evaluate("selectOffsets(getText().length, getText().length); ''")
    assert not shown(browser)
    # an edit that makes the line a numbered item shows it; a blur hides it
    at(browser, "1.", 1)
    assert not shown(browser)
    browser.send("Input.insertText", {"text": " a"})
    assert shown(browser)
    # the editor's own focus handling runs a moment after the blur
    assert browser.evaluate("""new Promise((res) => { composer.contentDOM.blur(); const t0 = Date.now();
      (function poll() { if (document.querySelector('#list-keys').hidden || Date.now() - t0 > 3000) res(document.querySelector('#list-keys').hidden); else setTimeout(poll, 20); })(); })""")


def test_the_buttons_are_44px_named_and_above_the_row(served, browser):
    touch(browser)
    open_composer(browser, served)
    at(browser, LIST, 2)
    box = browser.evaluate(BOX)
    assert box["shown"]
    for w, h in (box["out"], box["ind"]):
        assert w >= 44 and h >= 44, box
    assert box["names"] == [["Outdent", "Outdent"], ["Indent", "Indent"]], box
    assert box["bottom"] <= box["rowTop"], box   # over the composer's row, which is above the keyboard
    assert browser.evaluate("document.querySelector('#list-keys').closest('#composer') !== null")


def test_a_tap_nests_and_renumbers_like_tab_and_keeps_the_focus(served, browser):
    touch(browser)
    open_composer(browser, served)
    at(browser, LIST, 2)
    tap(browser, "#list-indent")
    s = browser.evaluate(STATE)
    assert s["text"] == "1. a\n  1. b\n2. c" and s["focus"] == "input", s
    assert s["sel"]["start"] == s["sel"]["end"] == len("1. a\n  1. b"), s
    assert shown(browser)
    tap(browser, "#list-outdent")
    s = browser.evaluate(STATE)
    assert s["text"] == LIST and s["focus"] == "input", s
    assert s["sel"]["start"] == s["sel"]["end"] == len("1. a\n2. b"), s


def test_a_tap_is_the_same_edit_as_the_key(served, browser):
    # the same text and caret through the Tab command and through the button come to the same document and caret
    touch(browser)
    open_composer(browser, served)
    at(browser, "1. a\n2. b\n  1. c\n3. d", 2)
    browser.evaluate("document.querySelector('#input').dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', code: 'Tab', keyCode: 9, bubbles: true, cancelable: true })); ''")
    by_key = browser.evaluate(STATE)
    at(browser, "1. a\n2. b\n  1. c\n3. d", 2)
    tap(browser, "#list-indent")
    assert browser.evaluate(STATE) == by_key


def test_the_words_are_in_both_languages_and_the_page_has_no_text_in_them():
    en, ko = (STATIC / "i18n-en.js").read_text(), (STATIC / "i18n-ko.js").read_text()
    for k in ("ui.cmp.indent", "ui.cmp.outdent"):
        assert f'"{k}"' in en and f'"{k}"' in ko
    html = (STATIC / "index.html").read_text()
    block = html[html.index('<div id="list-keys"'):]
    block = block[:block.index("</div>")]
    assert 'data-i18n-aria-label="ui.cmp.indent"' in block and 'data-i18n-title="ui.cmp.outdent"' in block
