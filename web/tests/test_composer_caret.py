"""The empty composer's caret sits at the line's start, never behind the placeholder (on Chrome on Android the cursor
sometimes sat behind the explanatory text).

CodeMirror's own placeholder() is an inline, non-editable span inside the empty line (`<div.cm-line><img.cm-widgetBuffer><span.cm-
placeholder contenteditable=false><br></div>`). That line has three places the DOM selection can be: before the span, after the
span, and before the `<br>`. A phone's tap hit-test picks the one nearest the finger, which is the one after the span for a tap
past the text's middle; CodeMirror maps all of them to document offset 0 and so leaves the browser's choice alone, and the browser
then draws the caret (and Android its teardrop handle) after the span's text. Measured here before the fix: the caret of a DOM
selection placed after the span is painted at the end of "Message the session". (An out-of-flow span inside the line did not cure
it: the browser then paints no caret at all at the two places beside a non-editable span.) The fix is in the bundle's entry.js: the
placeholder is a div of its own in the editor's box, not in the contenteditable, so the empty line is a lone `<br>` with one place
for the caret.

Chromium paints the caret in the same way for a DOM selection set by a script, so these tests set the selection to each place and
find the caret in a screenshot: the composer's caret colour is made pure red for the test, the editable's box is captured at scale
1, and the columns that hold red pixels are the caret. (A collapsed range has no client rects here, so a range measurement cannot
show it.) What no test here can show is the phone's own tap and its handle.

The page parts run in a headless Chromium when one is installed (conftest.py: `served`, `browser`), and are skipped without one.
"""

from __future__ import annotations

import base64
import struct
import time
import zlib

import pytest

from test_composer_editable import key, open_composer, typed

RED = "(() => { const s = document.createElement('style'); s.id = 'caret-red'; s.textContent = '#input { caret-color: #ff0000 !important; caret-animation: manual !important; }'; document.head.append(s); })()"
LINE_SEL = "(() => { const l = document.querySelector('#input .cm-line'); getSelection().collapse(l, %d); return l.childNodes.length; })()"
LAYOUT = """(() => { const i = document.querySelector('#input'), l = i.querySelector('.cm-line'), p = document.querySelector('#composer-editor .cm-placeholder');
  const ir = i.getBoundingClientRect(), lr = l.getBoundingClientRect(), pr = p && p.getBoundingClientRect(), cs = p && getComputedStyle(p);
  return { input: [ir.left, ir.right, ir.height], line: [lr.left, lr.right, lr.height], ph: pr && [pr.left, pr.right, pr.width, pr.height],
           position: cs && cs.position, scrollW: document.documentElement.scrollWidth, innerW: innerWidth }; })()"""


def png_pixels(data: bytes) -> tuple[int, int, int, bytes]:
    """(width, height, bytes per pixel, the unfiltered rows) of an 8-bit RGB or RGBA PNG (what Page.captureScreenshot makes)."""
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    pos, idat, w = 8, b"", 0
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            w, h, depth, ctype = struct.unpack(">IIBB", body[:10])
            assert depth == 8 and ctype in (2, 6), (depth, ctype)
        elif kind == b"IDAT":
            idat += body
        pos += 12 + n
    bpp = 4 if ctype == 6 else 3
    raw, stride, rows, prev = zlib.decompress(idat), w * bpp, [], bytearray(w * bpp)
    for y in range(h):
        f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + b) & 255
            elif f == 3:
                line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(bytes(line))
        prev = line
    return w, h, bpp, b"".join(rows)


def red_columns(browser) -> list[int]:
    """The columns, counted from the editable's left edge, in which the red caret is painted (the native caret blinks about once a second: the test style turns the animation off where Chromium honors `caret-animation`,
    and the loop looks for 3 seconds where it does not)."""
    r = browser.evaluate("(() => { const r = document.querySelector('#input').getBoundingClientRect(); return [r.left, r.top, r.width, r.height]; })()")
    left, top, width, height = r
    for _ in range(30):
        shot = browser.send("Page.captureScreenshot", {"format": "png", "clip": {"x": left - 4, "y": top, "width": width + 8, "height": height, "scale": 1}})
        w, h, bpp, px = png_pixels(base64.b64decode(shot["data"]))
        cols = sorted({x for y in range(h) for x in range(w)
                       if px[(y * w + x) * bpp] > 200 and px[(y * w + x) * bpp + 1] < 60 and px[(y * w + x) * bpp + 2] < 60})
        if cols:
            return [c - 4 for c in cols]
        time.sleep(0.1)
    return []


def empty_composer(browser, served) -> None:
    open_composer(browser, served)
    browser.evaluate(RED)
    assert browser.evaluate("!!document.querySelector('#composer-editor .cm-placeholder') && getText() === ''")


@pytest.mark.parametrize("place", [0, 1])
def test_the_empty_caret_is_at_the_line_start(served, browser, place):
    empty_composer(browser, served)
    # the empty line holds nothing but its <br>: no placeholder span, no widget buffer, so no second place for the caret
    assert browser.evaluate("document.querySelector('#input .cm-line').innerHTML") == "<br>"
    assert browser.evaluate(LINE_SEL % place) == 1
    cols = red_columns(browser)
    assert cols, "no caret found in the screenshot"
    # the content box's left edge is column 0: the caret (1px wide) is there, not after the text
    assert max(cols) <= 2, (place, cols)


def test_the_placeholder_is_over_the_line_and_outside_the_editable(served, browser):
    empty_composer(browser, served)
    got = browser.evaluate(LAYOUT)
    assert got["position"] == "absolute", got
    assert browser.evaluate("!document.querySelector('#input').contains(document.querySelector('.cm-placeholder'))")
    # at the line's start, one line high, the composer still the send button's 30px
    assert abs(got["ph"][0] - got["line"][0]) <= 1 and got["ph"][2] > 40 and got["ph"][3] == 22, got
    assert got["input"][2] == 30, got
    assert got["scrollW"] <= got["innerW"], got


def test_the_placeholder_shows_when_empty_and_hides_when_typed(served, browser):
    empty_composer(browser, served)
    typed(browser, "abc")
    assert browser.evaluate("!document.querySelector('#composer-editor .cm-placeholder') && getText() === 'abc'")
    cols = red_columns(browser)
    assert cols and min(cols) > 2, cols  # the caret follows the text, not the line's start
    key(browser, "a", "KeyA", 65, modifiers=2)
    key(browser, "Delete", "Delete", 46)
    assert browser.evaluate("!!document.querySelector('#composer-editor .cm-placeholder') && getText() === ''")
    assert max(red_columns(browser)) <= 2


def test_a_composition_hides_the_placeholder(served, browser):
    empty_composer(browser, served)
    browser.send("Input.imeSetComposition", {"text": "ㅎ", "selectionStart": 1, "selectionEnd": 1})
    assert browser.evaluate("!document.querySelector('#composer-editor .cm-placeholder')")
    browser.send("Input.imeSetComposition", {"text": "하", "selectionStart": 1, "selectionEnd": 1})
    assert browser.evaluate("!document.querySelector('#composer-editor .cm-placeholder')")


def test_a_long_placeholder_stays_in_its_line_on_a_narrow_phone(served, browser):
    empty_composer(browser, served)
    browser.send("Emulation.setDeviceMetricsOverride", {"width": 360, "height": 740, "deviceScaleFactor": 1, "mobile": True})
    # the long, desktop wording on a 360px phone (the app picks the short one there; this is the worst case)
    browser.evaluate("cm6Composer.setPlaceholder(composer, 'Message the session (Enter sends, Shift+Enter for a new line)')")
    # the viewport change and the new placeholder leave the caret unpainted until the editable is focused afresh (a bare focus() on
    # the already focused editable is a no-op and left it unpainted: found by running it)
    browser.evaluate("document.querySelector('#input').blur(); document.querySelector('#input').focus()")
    got = browser.evaluate(LAYOUT)
    assert got["ph"][1] <= got["input"][1] + 0.5 and got["ph"][3] == 22, got  # inside the box, on one line (an ellipsis)
    assert got["input"][2] == 30 and got["scrollW"] <= got["innerW"], got
    assert max(red_columns(browser)) <= 2
