"""Enter on a phone (Shift+Enter did not give a new line on some phone keyboards): an on-screen keyboard has no Shift to hold with Enter, so in touch mode (`(pointer: coarse) and (hover:
none)`) Enter is a new line and only the Send button or Ctrl/Cmd+Enter sends; a desktop keeps Enter sends, Shift+Enter a
new line; an Enter during an IME composition sends nothing in either mode, and the placeholder names the mode.

Touch mode is emulated through DevTools (Emulation.setTouchEmulationEnabled: pointer coarse, hover none, five touch
points; the `browser` fixture's mobile viewport alone leaves the pointer fine), the keys and compositions as in
test_composer_editable.py. What no test here can show is the phone keyboard itself: whether the phone keyboard sends its
Enter as a key event or as commitText("\\n") (Chromium turns either into one Enter key press, key "Enter" keyCode 13),
and whether it finishes a Korean composition before it (then the browser commits and breaks the line once on its own).
"""

from __future__ import annotations

import json

import pytest

from test_composer_editable import STATE, enter, key, open_composer, typed

TOUCH = "(pointer: coarse) and (hover: none)"
MODE = "matchMedia(%s).matches" % json.dumps(TOUCH)
PLACEHOLDER = "(document.querySelector('#composer-editor .cm-placeholder') || {}).textContent"
# the placeholder once the media query's change event has run (it follows the emulation change asynchronously)
PLACEHOLDER_IS = """new Promise((res) => { const t0 = Date.now(); (function poll() { const c = %s;
  if (c === %s || Date.now() - t0 > 3000) res(c); else setTimeout(poll, 20); })(); })"""
# the delivery over: send() ignores a key while one is in flight (test_composer_editable.py)
WAIT_SENT = """new Promise((res) => { const t0 = Date.now(); (function poll() {
  if (!state.sending || Date.now() - t0 > 5000) res(!state.sending); else setTimeout(poll, 20); })(); })"""


def touch(browser, on: bool = True) -> None:
    browser.send("Emulation.setTouchEmulationEnabled", {"enabled": on, "maxTouchPoints": 5 if on else 1})


def tap_send(browser) -> None:
    """A finger on the Send button (touchStart, touchEnd; the browser makes the click), the delivery awaited."""
    x, y = browser.evaluate("(() => { const r = document.querySelector('#send').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })()")
    browser.send("Input.dispatchTouchEvent", {"type": "touchStart", "touchPoints": [{"x": x, "y": y}]})
    browser.send("Input.dispatchTouchEvent", {"type": "touchEnd", "touchPoints": []})
    assert browser.evaluate(WAIT_SENT)


def compose(browser, syllables: list[str]) -> None:
    for syl in syllables:
        browser.send("Input.imeSetComposition", {"text": syl, "selectionStart": 1, "selectionEnd": 1})


def test_touch_mode_enter_is_a_new_line_and_the_button_sends(served, browser):
    touch(browser)
    open_composer(browser, served)
    assert browser.evaluate(MODE)
    typed(browser, "hello 안녕")
    enter(browser)
    s = browser.evaluate(STATE)
    assert s["text"] == "hello 안녕\n" and s["lines"] == 2 and s["sent"] == [] and s["sendEnabled"], s
    typed(browser, " second")
    enter(browser)
    enter(browser)  # a blank line
    typed(browser, "third")
    enter(browser, shift=True)  # a keyboard attached: Shift+Enter is the browser's own line break, as before
    typed(browser, "fourth")
    s = browser.evaluate(STATE)
    assert s["text"] == "hello 안녕\n second\n\nthird\nfourth" and s["lines"] == 5 and s["sent"] == [], s
    tap_send(browser)
    s = browser.evaluate(STATE)
    assert s["sent"] == [{"text": "hello 안녕\n second\n\nthird\nfourth", "uploads": []}], s
    assert s["text"] == "" and s["empty"] and not s["sendEnabled"], s
    assert browser.evaluate("document.querySelector('#chat .msg.user.local .bubble').textContent") == "hello 안녕\n second\n\nthird\nfourth"
    # an empty composer: the button sends nothing
    tap_send(browser)
    assert len(browser.evaluate("__sent")) == 1


def test_touch_mode_ctrl_or_cmd_enter_sends(served, browser):
    touch(browser)
    open_composer(browser, served)
    typed(browser, "a")
    enter(browser)
    typed(browser, "b")
    key(browser, "Enter", "Enter", 13, "\r", modifiers=2)  # Ctrl
    s = browser.evaluate(STATE)
    assert s["sent"] == [{"text": "a\nb", "uploads": []}] and s["text"] == "", s
    assert browser.evaluate(WAIT_SENT)
    typed(browser, "c")
    key(browser, "Enter", "Enter", 13, "\r", modifiers=4)  # Meta (Cmd)
    s = browser.evaluate(STATE)
    assert [m["text"] for m in s["sent"]] == ["a\nb", "c"] and s["text"] == "", s


def test_desktop_mode_enter_sends_and_shift_enter_is_a_new_line(served, browser):
    open_composer(browser, served)
    assert not browser.evaluate(MODE)
    typed(browser, "a")
    enter(browser, shift=True)
    typed(browser, "b")
    s = browser.evaluate(STATE)
    assert s["text"] == "a\nb" and s["sent"] == [], s
    enter(browser)
    s = browser.evaluate(STATE)
    assert s["sent"] == [{"text": "a\nb", "uploads": []}] and s["text"] == "", s
    assert browser.evaluate(WAIT_SENT)
    typed(browser, "c")
    key(browser, "Enter", "Enter", 13, "\r", modifiers=2)  # Ctrl+Enter sends here too
    assert [m["text"] for m in browser.evaluate("__sent")] == ["a\nb", "c"]


@pytest.mark.parametrize("mode", ["touch", "desktop"])
def test_an_enter_during_a_composition_sends_nothing_in_either_mode(served, browser, mode):
    touch(browser, mode == "touch")
    open_composer(browser, served)
    assert browser.evaluate(MODE) == (mode == "touch")
    typed(browser, "abc ")
    compose(browser, ["ㅎ", "하", "한"])
    # the IME takes the Enter (keyCode 229, no text): nothing sent, nothing inserted, the composition goes on
    browser.send("Input.dispatchKeyEvent", {"type": "keyDown", "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 229})
    browser.send("Input.dispatchKeyEvent", {"type": "keyUp", "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 229})
    s = browser.evaluate(STATE)
    assert s["sent"] == [] and s["text"] == "abc 한", s
    typed(browser, "한")  # the commit: compositionend
    # the composition over, a line break is the page's again (touch: Enter; a desktop: Shift+Enter), as text
    enter(browser, shift=(mode == "desktop"))
    s = browser.evaluate(STATE)
    assert s["sent"] == [] and s["text"] == "abc 한\n", s
    typed(browser, "x")
    compose(browser, ["ㄱ", "그", "글"])
    # an Enter key passed through while the composition is still open (isComposing, as an IME that does not finish the
    # composition first would do): the browser's own commit and at most its one line break; the page neither sends nor
    # adds a line of its own. (What DevTools leaves behind here is not the phone's: the composition range stays open on
    # the syllable until the next commit.)
    enter(browser)
    s = browser.evaluate(STATE)
    assert s["sent"] == [] and s["text"].startswith("abc 한\nx글") and s["text"].count("\n") <= 2, s
    typed(browser, "글")  # the commit
    s = browser.evaluate(STATE)
    assert s["sent"] == [] and s["text"].startswith("abc 한\nx글"), s
    before = s["text"]
    if mode == "touch":
        tap_send(browser)
    else:
        enter(browser)
    assert browser.evaluate("__sent") == [{"text": before, "uploads": []}]  # the payload is the box's text, byte for byte


def test_a_newline_committed_as_text_is_a_line(served, browser):
    """An IME that commits "\\n" as text rather than an Enter key (Chrome on Android turns the exact "\\n" into a key, other
    browsers may not): the line reads as one and nothing is sent."""
    touch(browser)
    open_composer(browser, served)
    typed(browser, "a")
    browser.send("Input.insertText", {"text": "\n"})
    typed(browser, "b")
    s = browser.evaluate(STATE)
    assert s["text"] == "a\nb" and s["sent"] == [] and s["lines"] == 2, s
    tap_send(browser)
    assert browser.evaluate("__sent") == [{"text": "a\nb", "uploads": []}]


def test_placeholder_names_the_mode(served, browser):
    touch(browser)
    open_composer(browser, served)
    assert browser.evaluate(PLACEHOLDER) == "Message the session"  # a phone's width: the short one in any mode
    browser.send("Emulation.setDeviceMetricsOverride", {"width": 1024, "height": 768, "deviceScaleFactor": 1, "mobile": True})
    wide_touch = "Message the session (Enter adds a line, tap Send)"
    wide_desktop = "Message the session (Enter sends, Shift+Enter for a new line)"
    assert browser.evaluate(PLACEHOLDER_IS % (PLACEHOLDER, json.dumps(wide_touch))) == wide_touch
    assert "Shift" not in browser.evaluate("document.querySelector('#input').getAttribute('aria-placeholder')")
    touch(browser, False)  # the pointer turns fine (Android desktop mode, a dock): the mode is desktop and the hint follows
    assert browser.evaluate(PLACEHOLDER_IS % (PLACEHOLDER, json.dumps(wide_desktop))) == wide_desktop
    touch(browser, True)
    assert browser.evaluate(PLACEHOLDER_IS % (PLACEHOLDER, json.dumps(wide_touch))) == wide_touch
