"""Tab as an indent and lists that continue (Tab indents rather than moving the focus on to the
send button; a dash and a space turn into a bullet). The composer stays plain text, so a bullet is the "- " as typed and the pane
receives exactly what is shown; what the page adds is the indent (Tab, Shift+Tab) and the next item's marker on the key
that makes a new line (Shift+Enter on a desktop, Enter in touch mode). These tests hold that to the letter: the text after
each key, the caret and the selection, the focus (Tab stays in the box; Escape then Tab leaves it), the send payload with
its indents and markers byte for byte, the draft across a reload, native undo, and the guards (a modifier held, an IME
composition) under which the keys are the browser's own.

Keys go through DevTools (Input.dispatchKeyEvent), trusted, so the browser's own editing runs on them, as in
test_composer_editable.py; the guards that a trusted key cannot carry (isComposing, keyCode 229) are checked with
synthetic events on the handler. What no test here can show is a phone keyboard or a real Korean IME:
whether it finishes a composition before an Enter, and what a Tab key on an attached keyboard arrives as.
"""

from __future__ import annotations

import json

import pytest

from conftest import NAME
from test_composer_editable import STATE, WAIT_FRESH, enter, key, open_composer, typed
from test_composer_touch import MODE, WAIT_SENT, tap_send, touch

# the text, the selection in text offsets, where the focus is, and the rest of STATE
SEL = """(() => { const s = %s; s.sel = selectionOf(); s.focus = document.activeElement ? document.activeElement.id || document.activeElement.tagName : null;
  return s; })()""" % STATE


def tab(browser, shift: bool = False) -> None:
    key(browser, "Tab", "Tab", 9, modifiers=8 if shift else 0)


def escape(browser) -> None:
    key(browser, "Escape", "Escape", 27)


def undo(browser) -> None:
    key(browser, "z", "KeyZ", 90, modifiers=2, commands=["Undo"])


def put(browser, text: str, start: int, end: int | None = None, backward: bool = False) -> None:
    """The composer set to `text` with the selection at the offsets (the caret, when `end` is left out)."""
    browser.evaluate("setText(%s); selectOffsets(%d, %d, %s); ''" % (json.dumps(text), start, start if end is None else end, "true" if backward else "false"))


def sel(browser) -> dict:
    return browser.evaluate(SEL)


def caret(s: dict) -> int:
    assert s["sel"]["start"] == s["sel"]["end"], s["sel"]
    return s["sel"]["start"]


@pytest.mark.parametrize("mode", ["desktop", "touch"])
def test_tab_indents_at_the_caret_and_keeps_the_focus(served, browser, mode):
    touch(browser, mode == "touch")
    open_composer(browser, served)
    assert browser.evaluate(MODE) == (mode == "touch")
    # the empty box: two spaces, the focus still in the box (not on the send button), the placeholder gone, nothing to send
    tab(browser)
    s = sel(browser)
    assert s["text"] == "  " and s["focus"] == "input" and caret(s) == 2 and not s["empty"] and not s["sendEnabled"] and s["lines"] == 1, s
    typed(browser, "a")
    s = sel(browser)
    assert s["text"] == "  a" and s["sendEnabled"], s
    # mid-line: at the caret, the caret after the spaces
    put(browser, "abcd", 2)
    tab(browser)
    s = sel(browser)
    assert s["text"] == "ab  cd" and caret(s) == 4 and s["focus"] == "input", s
    # a selection within the line is replaced
    put(browser, "abcd", 1, 3)
    tab(browser)
    s = sel(browser)
    assert s["text"] == "a  d" and caret(s) == 3, s
    # a second Tab is a second indent, not a focus move
    tab(browser)
    s = sel(browser)
    assert s["text"] == "a    d" and caret(s) == 5 and s["focus"] == "input" and s["sent"] == [], s


def test_shift_tab_takes_up_to_two_leading_spaces_off_the_line(served, browser):
    open_composer(browser, served)
    put(browser, "    a", 5)
    tab(browser, shift=True)
    s = sel(browser)
    assert s["text"] == "  a" and caret(s) == 3 and s["focus"] == "input", s
    tab(browser, shift=True)
    s = sel(browser)
    assert s["text"] == "a" and caret(s) == 1, s
    # none to take: nothing changes, and the key is still the page's (no focus move backwards)
    tab(browser, shift=True)
    s = sel(browser)
    assert s["text"] == "a" and caret(s) == 1 and s["focus"] == "input", s
    # one space: one taken; the caret inside the spaces lands at the line's start
    put(browser, " x", 1)
    tab(browser, shift=True)
    s = sel(browser)
    assert s["text"] == "x" and caret(s) == 0, s
    put(browser, "   b", 4)  # three: two taken
    tab(browser, shift=True)
    s = sel(browser)
    assert s["text"] == " b" and caret(s) == 2, s
    # only the caret's line, with the lines around it untouched (the caret, between the two spaces, lands at the start)
    put(browser, "  p\n  q\n  r", 5)
    tab(browser, shift=True)
    s = sel(browser)
    assert s["text"] == "  p\nq\n  r" and caret(s) == 4, s
    # a selection within the line is kept on its text
    put(browser, "  ab", 2, 4)
    tab(browser, shift=True)
    s = sel(browser)
    assert s["text"] == "ab" and s["sel"] == {"start": 0, "end": 2, "backward": False}, s


def test_tab_nests_a_list_item_and_shift_tab_unnests_it(served, browser):
    open_composer(browser, served)
    put(browser, "- a", 3)
    tab(browser)
    s = sel(browser)
    assert s["text"] == "  - a" and caret(s) == 5 and s["focus"] == "input", s  # the caret stays on its text
    tab(browser)
    s = sel(browser)
    assert s["text"] == "    - a" and caret(s) == 7, s
    tab(browser, shift=True)
    s = sel(browser)
    assert s["text"] == "  - a" and caret(s) == 5, s
    # the caret moves with the text; a number and a star nest too; the empty item as well
    for text, want in [("1. a", "  1. a"), ("* a", "  * a"), ("- ", "  - "), ("x\n- a", "x\n  - a")]:
        put(browser, text, len(text))
        tab(browser)
        s = sel(browser)
        assert s["text"] == want and caret(s) == len(text) + 2, (text, s)
    # the caret never rests at a list line's start: put there it is on the text, and the nest keeps it on the text
    for text, at, want, c in [("- a", 0, "  - a", 4), ("1. a", 0, "  1. a", 5), ("x\n- a", 2, "x\n  - a", 6)]:
        put(browser, text, at)
        assert caret(sel(browser)) == at + (3 if text[0] == "1" else 2), (text, sel(browser))
        tab(browser)
        s = sel(browser)
        assert s["text"] == want and caret(s) == c, (text, s)
    # a range starting at the line's start keeps its start before the marker, the indent drawn with it
    put(browser, "- abc", 0, 5)
    tab(browser)
    s = sel(browser)
    assert s["text"] == "  - abc" and s["sel"] == {"start": 0, "end": 7, "backward": False}, s
    # a selection on a list line stays on its text
    put(browser, "- abc", 2, 5)
    tab(browser)
    s = sel(browser)
    assert s["text"] == "  - abc" and s["sel"] == {"start": 4, "end": 7, "backward": False}, s
    # not a list line: "-" without its space, "1.a", a dash mid-line
    for text in ["-a", "1.a", "a - b"]:
        put(browser, text, 0)
        tab(browser)
        s = sel(browser)
        assert s["text"] == "  " + text and caret(s) == 2, (text, s)


def test_a_selection_across_lines_indents_and_outdents_every_line_it_touches(served, browser):
    open_composer(browser, served)
    put(browser, "a\nb\nc", 0, 3)  # "a" and "b"
    tab(browser)
    s = sel(browser)
    assert s["text"] == "  a\n  b\nc" and s["sel"] == {"start": 2, "end": 7, "backward": False}, s
    tab(browser, shift=True)
    s = sel(browser)
    assert s["text"] == "a\nb\nc" and s["sel"] == {"start": 0, "end": 3, "backward": False}, s
    # a selection that ends at a line's start leaves that line out; backward stays backward
    put(browser, "a\nb\nc", 0, 4, backward=True)
    tab(browser)
    s = sel(browser)
    assert s["text"] == "  a\n  b\nc" and s["sel"] == {"start": 2, "end": 8, "backward": True}, s
    tab(browser, shift=True)
    s = sel(browser)
    assert s["text"] == "a\nb\nc" and s["sel"] == {"start": 0, "end": 4, "backward": True}, s
    # outdent takes what each line has: two, one, none; the selection's ends follow their own lines
    put(browser, "  a\n b\nc\n    d", 1, 12)  # the end three spaces into the last line: one space in once two are gone
    tab(browser, shift=True)
    s = sel(browser)
    assert s["text"] == "a\nb\nc\n  d" and s["sel"] == {"start": 0, "end": 7, "backward": False}, s
    # list lines in the selection nest as lines, the markers kept
    put(browser, "- a\n- b", 0, 7)
    tab(browser)
    s = sel(browser)
    assert s["text"] == "  - a\n  - b" and s["sel"] == {"start": 0, "end": 11, "backward": False}, s  # the first item stays selected whole
    # nothing to outdent on any line: nothing changes, the key is taken
    put(browser, "a\nb", 0, 3)
    tab(browser, shift=True)
    s = sel(browser)
    assert s["text"] == "a\nb" and s["sel"] == {"start": 0, "end": 3, "backward": False} and s["focus"] == "input", s


def test_escape_then_tab_leaves_the_box(served, browser):
    open_composer(browser, served)
    typed(browser, "x")
    escape(browser)
    tab(browser)
    s = sel(browser)
    assert s["focus"] != "input" and s["text"] == "x", s  # the browser's own Tab: the focus moved on, no indent
    # the focus coming back arms it again
    browser.evaluate("document.querySelector('#input').focus(); focusEnd(); ''")
    tab(browser)
    s = sel(browser)
    assert s["text"] == "x  " and s["focus"] == "input", s
    # any other key after Escape arms it again (a key press here, not Input.insertText, which fires no keydown)
    escape(browser)
    key(browser, "y", "KeyY", 89, text="y")
    tab(browser)
    s = sel(browser)
    assert s["text"] == "x  y  " and s["focus"] == "input", s
    # Escape twice stays disarmed; a modifier pressed on its own (the Shift of a Shift+Tab) does not arm it
    escape(browser)
    escape(browser)
    key(browser, "Shift", "ShiftLeft", 16, modifiers=8)
    tab(browser, shift=True)
    s = sel(browser)
    assert s["focus"] != "input" and s["text"] == "x  y  ", s
    # one Tab passes, then it is armed again: the next Tab, back in the box, indents
    browser.evaluate("document.querySelector('#input').focus(); focusEnd(); ''")
    tab(browser)
    s = sel(browser)
    assert s["text"] == "x  y    " and s["focus"] == "input", s
    # Escape closes nothing of the composer's: the text and the caret stay
    escape(browser)
    s = sel(browser)
    assert s["text"] == "x  y    " and caret(s) == 8 and s["focus"] == "input", s


def test_tab_with_a_modifier_or_during_a_composition_is_the_browsers_own(served, browser):
    """The guards a trusted key cannot carry from here, checked on the handler: a synthetic keydown comes back not
    prevented (the browser would move the focus or let the IME have it), and the text is untouched."""
    open_composer(browser, served)
    put(browser, "- a", 3)
    fire = """(() => { const i = document.querySelector("#input"); const e = new KeyboardEvent("keydown", Object.assign({ bubbles: true, cancelable: true }, %s));
      const passed = i.dispatchEvent(e); return [passed, getText()]; })()"""
    for init in [{"key": "Tab", "ctrlKey": True}, {"key": "Tab", "altKey": True}, {"key": "Tab", "metaKey": True},
                 {"key": "Tab", "shiftKey": True, "ctrlKey": True}, {"key": "Tab", "isComposing": True}, {"key": "Tab", "keyCode": 229},
                 {"key": "Enter", "shiftKey": True, "isComposing": True}, {"key": "Enter", "shiftKey": True, "keyCode": 229}]:
        assert browser.evaluate(fire % json.dumps(init)) == [True, "- a"], init
    # between compositionstart and compositionend (the IME's window, whatever isComposing says on the key): the same
    browser.evaluate("""document.querySelector("#input").dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true })); ''""")
    for init in [{"key": "Tab"}, {"key": "Tab", "shiftKey": True}, {"key": "Enter", "shiftKey": True}]:
        assert browser.evaluate(fire % json.dumps(init)) == [True, "- a"], init
    browser.evaluate("""document.querySelector("#input").dispatchEvent(new CompositionEvent("compositionend", { bubbles: true })); ''""")
    # the composition over, the keys are the page's again
    assert browser.evaluate(fire % json.dumps({"key": "Tab"})) == [False, "  - a"]
    assert browser.evaluate(fire % json.dumps({"key": "Enter", "shiftKey": True})) == [False, "  - a\n  - "]
    assert browser.evaluate(fire % json.dumps({"key": "Tab", "shiftKey": True})) == [False, "  - a\n- "]
    # a real composition through DevTools: the IME's keys (keyCode 229) during it change nothing of the page's, and the
    # commit hands Tab back
    put(browser, "- ", 2)
    for syl in ["ㅎ", "하", "한"]:
        browser.send("Input.imeSetComposition", {"text": syl, "selectionStart": 1, "selectionEnd": 1})
    browser.send("Input.dispatchKeyEvent", {"type": "keyDown", "key": "Process", "code": "Tab", "windowsVirtualKeyCode": 229})
    browser.send("Input.dispatchKeyEvent", {"type": "keyUp", "key": "Process", "code": "Tab", "windowsVirtualKeyCode": 229})
    s = sel(browser)
    assert s["text"] == "- 한" and s["sent"] == [], s
    typed(browser, "한")  # the commit
    tab(browser)
    s = sel(browser)
    assert s["text"] == "  - 한" and caret(s) == 5, s


def test_shift_enter_continues_a_list_on_a_desktop(served, browser):
    open_composer(browser, served)
    assert not browser.evaluate(MODE)
    typed(browser, "- a")
    enter(browser, shift=True)
    s = sel(browser)
    assert s["text"] == "- a\n- " and caret(s) == 6 and s["lines"] == 2 and s["sent"] == [] and s["sendEnabled"], s
    typed(browser, "b")
    enter(browser, shift=True)
    typed(browser, "c")
    s = sel(browser)
    assert s["text"] == "- a\n- b\n- c" and s["lines"] == 3, s
    # a number counts up; the indent is kept; a star stays a star
    for text, want in [("1. a", "1. a\n2. "), ("9. a", "9. a\n10. "), ("  - a", "  - a\n  - "), ("    3. a", "    3. a\n    4. "),
                       ("* a", "* a\n* "), ("x\n- y", "x\n- y\n- "), ("- a\n\n1. b", "- a\n\n1. b\n2. ")]:
        put(browser, text, len(text))
        enter(browser, shift=True)
        s = sel(browser)
        assert s["text"] == want and caret(s) == len(want) and s["sent"] == [], (text, s)
    # the item typed on continues again: "1. a" Shift+Enter "x" Shift+Enter -> "3. "
    put(browser, "1. a", 4)
    enter(browser, shift=True)
    typed(browser, "x")
    enter(browser, shift=True)
    s = sel(browser)
    assert s["text"] == "1. a\n2. x\n3. " and caret(s) == 13, s
    # the dash and the space typed at a line's start are the text "- " (the pane gets it as typed), drawn as a dot
    put(browser, "", 0)
    typed(browser, "- ")
    s = sel(browser)
    assert s["text"] == "- " and browser.evaluate("[...input.querySelectorAll('.cm-li-mark')].map((m) => m.textContent)") == ["•"], s


def test_enter_on_an_empty_item_ends_the_list(served, browser):
    open_composer(browser, served)
    typed(browser, "- a")
    enter(browser, shift=True)
    enter(browser, shift=True)  # on "- ": the marker goes, the line stays, empty
    s = sel(browser)
    assert s["text"] == "- a\n" and caret(s) == 4 and s["lines"] == 2 and s["sent"] == [] and s["sendEnabled"], s
    enter(browser, shift=True)  # a plain line: the browser's own break
    s = sel(browser)
    assert s["text"] == "- a\n\n" and caret(s) == 5 and s["lines"] == 3, s
    typed(browser, "after")
    s = sel(browser)
    assert s["text"] == "- a\n\nafter", s
    # the indent goes with the marker; a numbered item too; an item of spaces alone counts as empty
    for text, want in [("x\n  - ", "x\n"), ("1. a\n2. ", "1. a\n"), ("- ", ""), ("* ", ""), ("-  ", ""), ("- a\n- \n- b", "- a\n\n- b")]:
        put(browser, text, text.index("\n- \n") + 3 if "\n- \n" in text else len(text))
        enter(browser, shift=True)
        s = sel(browser)
        assert s["text"] == want and caret(s) == (text.index("\n- \n") + 1 if "\n- \n" in text else len(want)) and s["sent"] == [], (text, s)
    s = sel(browser)
    assert s["empty"] is False and s["sendEnabled"], s
    put(browser, "- ", 2)
    enter(browser, shift=True)
    s = sel(browser)
    assert s["text"] == "" and s["empty"] and not s["sendEnabled"], s  # the box empty again: placeholder back, nothing to send


def test_enter_mid_line_splits_the_item(served, browser):
    open_composer(browser, served)
    put(browser, "- abcd", 4)
    enter(browser, shift=True)
    s = sel(browser)
    assert s["text"] == "- ab\n- cd" and caret(s) == 7, s  # the caret after the new marker, before the moved text
    put(browser, "  2. abcd", 7)
    enter(browser, shift=True)
    s = sel(browser)
    assert s["text"] == "  2. ab\n  3. cd" and caret(s) == 13, s
    # a selection within the line is replaced, then the list continues
    put(browser, "- abcd", 4, 6)
    enter(browser, shift=True)
    s = sel(browser)
    assert s["text"] == "- ab\n- " and caret(s) == 7, s
    # the caret never rests before the marker: put at the line's start, or inside the marker, it is at the text's
    # start, so the break there is the one below
    put(browser, "- abcd", 1)
    assert caret(sel(browser)) == 2
    put(browser, "- abcd", 0)
    assert caret(sel(browser)) == 2
    enter(browser, shift=True)
    s = sel(browser)
    assert s["text"] == "- \n- abcd" and caret(s) == 5, s
    # a range over the marker alone is a caret at the item's text (a selection does not take a bullet), the break is
    # the one below
    put(browser, "- abcd", 0, 2)
    assert caret(sel(browser)) == 2
    enter(browser, shift=True)
    s = sel(browser)
    assert s["text"] == "- \n- abcd" and caret(s) == 5, s
    # the caret right after the marker, before the text: the item moves down behind a marker of its own
    put(browser, "- abcd", 2)
    enter(browser, shift=True)
    s = sel(browser)
    assert s["text"] == "- \n- abcd" and caret(s) == 5, s
    # a selection across lines: the browser's own break
    put(browser, "- a\n- b", 2, 6)
    enter(browser, shift=True)
    s = sel(browser)
    assert s["text"] == "- \nb" and caret(s) == 3 and s["sent"] == [], s


def test_a_plain_line_breaks_as_before_and_the_payload_is_the_text(served, browser):
    open_composer(browser, served)
    typed(browser, "hello")
    enter(browser, shift=True)
    s = sel(browser)
    assert s["text"] == "hello\n" and caret(s) == 6, s  # a plain break, as without the feature
    for text in ["a - b", "-x", "1.a", "1) a", "  plain", "-"]:
        put(browser, text, len(text))
        enter(browser, shift=True)
        s = sel(browser)
        assert s["text"] == text + "\n" and caret(s) == len(text) + 1, (text, s)
    # what is sent is the box's text, indents and markers and all, byte for byte
    put(browser, "", 0)
    typed(browser, "- a")
    enter(browser, shift=True)   # "- a\n- "
    tab(browser)                 # "- a\n  - "
    typed(browser, "b")
    enter(browser, shift=True)   # "- a\n  - b\n  - "
    tab(browser, shift=True)     # "- a\n  - b\n- "
    enter(browser, shift=True)   # the empty item ends the list: "- a\n  - b\n"
    typed(browser, "1. c")
    enter(browser, shift=True)   # "…1. c\n2. "
    typed(browser, "d")
    enter(browser, shift=True)   # "…2. d\n3. "
    enter(browser, shift=True)   # ends: "…2. d\n"
    enter(browser, shift=True)   # a plain break: "…2. d\n\n"
    typed(browser, "  tail")
    s = sel(browser)
    assert s["text"] == "- a\n  - b\n1. c\n2. d\n\n  tail" and s["lines"] == 6, s
    enter(browser)
    s = sel(browser)
    assert s["sent"] == [{"text": "- a\n  - b\n1. c\n2. d\n\n  tail", "uploads": []}] and s["text"] == "" and s["empty"], s
    assert browser.evaluate("document.querySelector('#chat .msg.user.local .bubble').textContent") == "- a\n  - b\n1. c\n2. d\n\n  tail"
    # a trailing marker is sent as it stands
    assert browser.evaluate(WAIT_SENT)
    typed(browser, "- q")
    enter(browser, shift=True)
    enter(browser)
    assert [m["text"] for m in browser.evaluate("__sent")] == ["- a\n  - b\n1. c\n2. d\n\n  tail", "- q\n- "]


def test_touch_mode_enter_continues_a_list_and_the_button_sends_the_text(served, browser):
    touch(browser)
    open_composer(browser, served)
    assert browser.evaluate(MODE)
    typed(browser, "- a")
    enter(browser)
    s = sel(browser)
    assert s["text"] == "- a\n- " and caret(s) == 6 and s["sent"] == [] and s["lines"] == 2, s
    typed(browser, "b")
    enter(browser)
    enter(browser)  # the empty item ends the list
    s = sel(browser)
    assert s["text"] == "- a\n- b\n" and caret(s) == 8 and s["sent"] == [], s
    typed(browser, "plain")
    enter(browser)  # a plain line: Enter is a new line, as before, nothing sent
    typed(browser, "1. x")
    enter(browser)
    typed(browser, "y")
    enter(browser, shift=True)  # a keyboard attached: Shift+Enter continues too
    s = sel(browser)
    assert s["text"] == "- a\n- b\nplain\n1. x\n2. y\n3. " and s["sent"] == [] and s["lines"] == 6, s
    tab(browser)  # a Tab key on an attached keyboard: the same nesting
    typed(browser, "z")
    s = sel(browser)
    assert s["text"] == "- a\n- b\nplain\n1. x\n2. y\n  3. z" and s["focus"] == "input", s
    tap_send(browser)
    s = sel(browser)
    assert s["sent"] == [{"text": "- a\n- b\nplain\n1. x\n2. y\n  3. z", "uploads": []}] and s["text"] == "" and s["empty"], s
    assert browser.evaluate("document.querySelector('#chat .msg.user.local .bubble').textContent") == "- a\n- b\nplain\n1. x\n2. y\n  3. z"
    # Ctrl+Enter sends the text as it stands, a trailing marker included. The tap on Send took the focus off the composer, as on a
    # phone, where the next thing is a tap on the composer: it is focused here (the placeholder is no longer in the
    # empty line, so the browser's selection after the reset is not left where this typing used to happen to land)
    browser.evaluate("document.querySelector('#input').focus()")
    typed(browser, "- q")
    enter(browser)
    key(browser, "Enter", "Enter", 13, "\r", modifiers=2)
    assert [m["text"] for m in browser.evaluate("__sent")] == ["- a\n- b\nplain\n1. x\n2. y\n  3. z", "- q\n- "]


def test_undo_takes_back_one_key_at_a_time(served, browser):
    open_composer(browser, served)
    typed(browser, "- a")
    enter(browser, shift=True)
    s = sel(browser)
    assert s["text"] == "- a\n- ", s
    undo(browser)
    s = sel(browser)
    assert s["text"] == "- a" and caret(s) == 3, s  # the continuation is one step
    tab(browser)
    assert sel(browser)["text"] == "  - a"
    undo(browser)
    s = sel(browser)
    assert s["text"] == "- a", s
    put(browser, "    a\n  b", 0, 9)
    tab(browser, shift=True)
    assert sel(browser)["text"] == "  a\nb"
    undo(browser)
    assert sel(browser)["text"] == "    a\n  b"
    put(browser, "- a\n- ", 6)
    enter(browser, shift=True)
    assert sel(browser)["text"] == "- a\n"
    undo(browser)
    s = sel(browser)
    assert s["text"] == "- a\n- ", s


def test_a_draft_with_its_indents_and_markers_survives_a_reload(served, browser):
    open_composer(browser, served)
    typed(browser, "- a")
    enter(browser, shift=True)
    tab(browser)
    typed(browser, "b")
    enter(browser, shift=True)
    typed(browser, "c")
    assert sel(browser)["text"] == "- a\n  - b\n  - c"
    key_js = "localStorage.getItem('salaweb.draft.' + %s)" % json.dumps(NAME)
    browser.evaluate("new Promise((r) => setTimeout(r, 600))")  # saved 400 ms after the last keystroke
    assert browser.evaluate(key_js) == "- a\n  - b\n  - c"
    browser.evaluate("window.__old = true; ''")
    browser.send("Page.reload")
    assert browser.evaluate(WAIT_FRESH)
    s = browser.evaluate(STATE)
    assert s["text"] == "- a\n  - b\n  - c" and s["sendEnabled"] and s["lines"] == 3, s
    assert browser.evaluate(key_js) == "- a\n  - b\n  - c"  # kept until it is sent
