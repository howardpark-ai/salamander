"""The composer on CodeMirror 6:
a list item is drawn as a dot with a slight indent when a line becomes a list ("- " becomes a dot, "1. " keeps its number,
styled as a list); the caret skips the marker (it is never between the "-" and the space, nor inside "1. "); Backspace at
the start of an item's text visibly leaves the list; Tab indents and Shift+Tab outdents; and the text SENT stays plain
markdown, "- item" and "1. item", the document string untouched by any of it. What must stay as it was: the keyboard's
image paste, a Korean IME composition, Enter on a phone, the draft, the send button.

The keys, the tabs, the lists that continue, the IME guards and the draft are held by test_composer_editable.py,
test_composer_lists.py, test_composer_touch.py and test_back_button.py, which run on this editor; this file holds what is
new: the vendored bundle (and how it is wired), the drawn markers (the bullet a disc about the text's size), the caret
rules (it rests at the item's text and never before the marker), Backspace, a composition inside an item,
a file dropped on the editor, the undo history after a send, and the look at three widths in both themes.

Keys and compositions go through DevTools (Input.dispatchKeyEvent, Input.insertText, Input.imeSetComposition), trusted, as in
the other composer suites. What no test here can show: a real phone keyboard (its Enter, its image chip, its Korean
composition), the font (the headless browser falls back to a system font).
"""

from __future__ import annotations

import base64
import json
import re
import time

from conftest import NAME
from sala_web.app import STATIC
from test_composer_attach import PNG, WAIT_CHIPS
from test_composer_editable import STATE, enter, key, open_composer, typed
from test_composer_lists import caret, escape, put, sel, tab
from test_composer_touch import WAIT_SENT, tap_send, touch
from test_reply_footer import contrast

BUNDLE = STATIC / "vendor" / "cm6-composer.min.js"
RECIPE = STATIC.parent.parent.parent / "vendor-src" / "cm6-composer"
INDEX = (STATIC / "index.html").read_text()
APP = (STATIC / "app.js").read_text()
VERSIONS = {"@codemirror/state": "6.7.6", "@codemirror/view": "6.43.13", "@codemirror/commands": "6.11.1"}

MARKS = "[...input.querySelectorAll('.cm-li-mark')].map((m) => m.textContent)"
LEVELS = "[...input.querySelectorAll('.cm-line.cm-li')].map((l) => l.style.getPropertyValue('--li-level'))"


# ---------- the bundle: vendored, pinned, served from /static, loaded before the app ----------

def test_the_bundle_is_vendored_pinned_and_loaded_before_the_app():
    head = BUNDLE.read_bytes()[:1500].decode()
    assert head.startswith("/*!") and "MIT" in head and "CodeMirror" in head and "web/vendor-src/cm6-composer/LICENSE" in head
    for v in VERSIONS.values():
        assert v in head, v
    assert BUNDLE.read_bytes().count(b"\n") < 60  # minified: one bundle, not a source tree
    body = BUNDLE.read_bytes().decode(errors="replace")
    assert not re.search(r"\bimport\(|importScripts|jsdelivr|unpkg|cdnjs|cdn\.", body)  # nothing is loaded from elsewhere at runtime
    # the recipe that reproduces it, with the exact versions, the lockfile and the license
    assert (RECIPE / "LICENSE").read_text().startswith("MIT License")
    for f in ("README.md", "entry.js", "package.json", "package-lock.json", "banner.txt"):
        assert (RECIPE / f).is_file(), f
    pkg = json.loads((RECIPE / "package.json").read_text())
    assert pkg["dependencies"] == VERSIONS and pkg["devDependencies"] == {"esbuild": "0.28.2"}
    lock = json.loads((RECIPE / "package-lock.json").read_text())
    for name, v in VERSIONS.items():
        assert lock["packages"]["node_modules/" + name]["version"] == v, name
    readme = (RECIPE / "README.md").read_text()
    assert "npm ci" in readme and "npm run build" in readme and "sha256" in readme
    for v in VERSIONS.values():
        assert v in readme, v
    # the page loads it as a classic script before app.js, from its own static directory, and CodeMirror's EditContext is off
    # (the keyboard's image insertion goes to the contenteditable)
    names = ("static/vendor/cm6-composer.min.js", "static/app.js")
    assert [INDEX.index(n) for n in names] == sorted(INDEX.index(n) for n in names)
    assert "EDIT_CONTEXT = false" in (RECIPE / "entry.js").read_text() and "EDIT_CONTEXT" in body
    assert "cm6Composer.createEditor" in APP and "contenteditable" in APP


def test_the_bundle_is_served_and_nothing_else_is_loaded(served, browser):
    open_composer(browser, served)
    got = browser.evaluate("""(() => { const res = performance.getEntriesByType("resource").map((e) => e.name);
      return { scripts: res.filter((n) => /[.]js([?]|$)/.test(n)), v: cm6Composer.versions, fn: typeof cm6Composer.createEditor }; })()""")
    assert any(n.startswith(served["url"] + "/static/vendor/cm6-composer.min.js") for n in got["scripts"]), got["scripts"]
    assert all(n.startswith(served["url"] + "/") for n in got["scripts"]), got["scripts"]  # no script from elsewhere
    assert got["v"] == VERSIONS and got["fn"] == "function"
    r = browser.evaluate("fetch('static/vendor/cm6-composer.min.js').then((r) => [r.status, r.headers.get('content-type')])")
    assert r[0] == 200 and "javascript" in r[1], r


# ---------- the markers: drawn, never typed ----------

def test_a_list_line_is_drawn_with_a_dot_and_the_text_sent_stays_markdown(served, browser):
    open_composer(browser, served)
    typed(browser, "- a")
    s = sel(browser)
    assert s["text"] == "- a" and caret(s) == 3, s
    assert browser.evaluate(MARKS) == ["•"] and browser.evaluate(LEVELS) == ["0"]
    # the dot is a widget in place of the "- ": the line's visible text is the dot and the item; the glyph sits a little in
    # from the left, the text clear of it, and it is styled apart from the text
    got = browser.evaluate("""(() => { const l = input.querySelector(".cm-line.cm-li"), m = l.querySelector(".cm-li-mark");
      const t = [...l.childNodes].filter((n) => n.nodeType === 3).map((n) => { const r = document.createRange(); r.selectNodeContents(n); return r.getBoundingClientRect().left; })[0];
      return { line: l.textContent, mark: m.textContent, w: m.getBoundingClientRect().width, lineLeft: l.getBoundingClientRect().left,
               markLeft: m.getBoundingClientRect().left + parseFloat(getComputedStyle(m).paddingLeft), textLeft: t,  /* the disc's left edge */ markColor: getComputedStyle(m).color, textColor: getComputedStyle(l).color,
               editable: m.getAttribute("contenteditable") }; })()""")
    assert got["line"] == "•a" and got["mark"] == "•" and got["w"] >= 16 and got["editable"] == "false", got
    assert got["markLeft"] > got["lineLeft"] + 2 and got["textLeft"] >= got["markLeft"] + 10, got   # a slight indent, the text clear of the dot
    assert got["markColor"] == got["textColor"], got   # the bullet is the text's colour, no longer the muted one (test_new_session_ux.py checks the disc itself, in both themes)
    # the new line continues the list; what the send carries is the plain markdown, byte for byte
    enter(browser, shift=True)
    typed(browser, "b")
    enter(browser, shift=True)
    enter(browser, shift=True)   # the empty item ends the list
    typed(browser, "1. one")
    enter(browser, shift=True)
    typed(browser, "two")
    s = sel(browser)
    assert s["text"] == "- a\n- b\n1. one\n2. two", s["text"]
    assert browser.evaluate(MARKS) == ["•", "•", "1.", "2."]
    want = s["text"]
    enter(browser)
    sent = browser.evaluate("__sent")
    assert sent == [{"text": want, "uploads": []}], sent
    assert "•" not in want and "•" not in sent[0]["text"]   # no glyph in what is sent
    assert browser.evaluate("document.querySelector('#chat .msg.user.local .bubble').textContent") == want


def test_ordered_items_keep_their_number_and_are_styled_as_a_list(served, browser):
    open_composer(browser, served)
    typed(browser, "1. a")
    s = sel(browser)
    assert s["text"] == "1. a" and browser.evaluate(MARKS) == ["1."] and caret(s) == 4, s
    got = browser.evaluate("""(() => { const m = input.querySelector(".cm-li-mark"), l = input.querySelector(".cm-line");
      return { cls: m.className, ls: getComputedStyle(l).paddingLeft, ti: getComputedStyle(l).textIndent, num: getComputedStyle(m).fontVariantNumeric }; })()""")
    assert "cm-li-num" in got["cls"] and got["ls"] != "0px" and got["ti"] != "0px" and "tabular" in got["num"], got  # hanging indent, aligned digits
    # a star is a dot too; a nested item sits further in; "-a", "1.a" and a dash mid-line are not lists
    for text, marks, levels in [("* a", ["•"], ["0"]), ("  - a", ["•"], ["1"]), ("    1. a", ["1."], ["2"]), ("-a", [], []), ("1.a", [], []),
                                ("a - b", [], []), ("- a\nplain\n- b", ["•", "•"], ["0", "0"])]:
        put(browser, text, len(text))
        assert browser.evaluate(MARKS) == marks and browser.evaluate(LEVELS) == levels, (text, browser.evaluate(MARKS))
        assert sel(browser)["text"] == text
    put(browser, "- a\n  - b", 9)
    lefts = browser.evaluate("[...input.querySelectorAll('.cm-li-mark')].map((m) => m.getBoundingClientRect().left)")
    assert lefts[1] > lefts[0] + 10, lefts   # the nested dot sits further right
    # a long item wraps under its text, not under the dot
    put(browser, "- " + "word " * 40, 200)
    got = browser.evaluate("""(() => { const l = input.querySelector(".cm-line.cm-li"), m = l.querySelector(".cm-li-mark"); const r = document.createRange();
      r.selectNodeContents([...l.childNodes].filter((n) => n.nodeType === 3)[0]); const rects = [...r.getClientRects()];
      return { rows: new Set(rects.map((x) => Math.round(x.top))).size, firstLeft: Math.min(...rects.map((x) => x.left)), markRight: m.getBoundingClientRect().right }; })()""")
    assert got["rows"] >= 2 and got["firstLeft"] >= got["markRight"] - 1, got


# ---------- the caret ----------

def arrow(browser, name: str, shift: bool = False) -> None:
    key(browser, "Arrow" + name, "Arrow" + name, {"Left": 37, "Up": 38, "Right": 39, "Down": 40}[name], modifiers=8 if shift else 0)


def click_at(browser, x: float, y: float) -> None:
    for t in ("mousePressed", "mouseReleased"):
        browser.send("Input.dispatchMouseEvent", {"type": t, "x": x, "y": y, "button": "left", "clickCount": 1})


def test_the_caret_never_lands_inside_a_marker(served, browser):
    open_composer(browser, served)
    put(browser, "- abc", 5)
    # ArrowLeft from the text's start skips the whole "- ": the caret is at 2, never 1, and not before the marker (
    # 0 is not a place for it, so the key stops at the text's start)
    seen = []
    for _ in range(5):
        arrow(browser, "Left")
        seen.append(caret(sel(browser)))
    assert seen == [4, 3, 2, 2, 2], seen
    arrow(browser, "Right")
    assert caret(sel(browser)) == 3
    # a nested item: the indent is part of the marker
    put(browser, "  - x", 5)
    arrow(browser, "Left")
    assert caret(sel(browser)) == 4
    arrow(browser, "Left")
    assert caret(sel(browser)) == 4
    arrow(browser, "Right")
    assert caret(sel(browser)) == 5
    # a numbered item
    put(browser, "12. x", 5)
    arrow(browser, "Left")
    arrow(browser, "Left")
    assert caret(sel(browser)) == 4
    # vertical motion onto the marker's columns lands on the text's start, never before the marker
    put(browser, "- abc\nxy", 7)
    arrow(browser, "Up")
    assert caret(sel(browser)) >= 2, sel(browser)["sel"]
    put(browser, "xy\n- abc", 1)
    arrow(browser, "Down")
    assert caret(sel(browser)) >= 5, sel(browser)["sel"]
    # a programmatic move inside the marker, or to the line's start, lands on the text's start (the caret rule; a range keeps
    # an end at the line's start, below)
    put(browser, "- abc", 0)
    browser.evaluate("selectOffsets(1, 1); ''")
    assert caret(sel(browser)) == 2
    put(browser, "- abc", 5)
    browser.evaluate("selectOffsets(1, 1); ''")
    assert caret(sel(browser)) == 2
    # a selection may not end inside it either; an end in the marker is put at the item's text (a range does not
    # take the bullet)
    put(browser, "- abc", 5)
    browser.evaluate("selectOffsets(1, 5, true); ''")
    s = sel(browser)
    assert s["sel"] == {"start": 2, "end": 5, "backward": True}, s["sel"]
    # shift+arrow does not extend over the marker: on the first line there is nothing above, so nothing happens
    put(browser, "- abc", 2)
    arrow(browser, "Left", shift=True)
    assert sel(browser)["sel"] == {"start": 2, "end": 2, "backward": False}
    # a tap on the dot: the caret lands at the item's text, never in the marker or before it; a tap on the text lands in the text
    put(browser, "- abc", 5)
    box = browser.evaluate("(() => { const r = input.querySelector('.cm-li-mark').getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2, right: r.right }; })()")
    click_at(browser, box["x"], box["y"])
    assert caret(sel(browser)) == 2, sel(browser)["sel"]
    click_at(browser, box["x"] - 4, box["y"])
    assert caret(sel(browser)) == 2, sel(browser)["sel"]
    click_at(browser, box["right"] + 2, box["y"])
    assert caret(sel(browser)) in (2, 3), sel(browser)["sel"]
    # typing "at the line's start" types into the item's text (the caret is there), never in front of the marker
    put(browser, "- abc", 0)
    typed(browser, "x")
    s = sel(browser)
    assert s["text"] == "- xabc" and caret(s) == 3 and browser.evaluate(MARKS) == ["•"], s
    # spaces put in front of the marker by the page (a change that is not typed at the caret) make a nested item and the caret
    # stays with the text
    for spaces, level, want in [(" ", "0", 3), ("  ", "1", 4)]:   # one space: not a whole level yet
        put(browser, "- abc", 0)
        browser.evaluate("composer.dispatch({ changes: { from: 0, insert: %s } }); ''" % json.dumps(spaces))
        s = sel(browser)
        assert s["text"] == spaces + "- abc" and caret(s) == want and browser.evaluate(LEVELS) == [level] and browser.evaluate(MARKS) == ["•"], s


# ---------- the bullet's size and the caret at a list line's start ----------
# the bullet was way too small and a caret could sit in front of it, which felt awkward; "- " still becomes a bullet and both are
# fixed: a drawn disc about the text's size across, and a caret that rests at the item's text and never before the marker.

# the ink of a screenshot of `r` (x, y, w, h in CSS px): the box of the pixels that differ from the corner's, by more than half
INK = """(async (b64) => { const img = new Image(); img.src = 'data:image/png;base64,' + b64; await img.decode();
  const c = document.createElement('canvas'); c.width = img.width; c.height = img.height; const g = c.getContext('2d'); g.drawImage(img, 0, 0);
  const d = g.getImageData(0, 0, c.width, c.height).data; const bg = [d[0], d[1], d[2]];
  let x0 = 1e9, y0 = 1e9, x1 = -1, y1 = -1;
  for (let y = 0; y < c.height; y++) for (let x = 0; x < c.width; x++) { const i = (y * c.width + x) * 4;
    if (Math.abs(d[i] - bg[0]) + Math.abs(d[i + 1] - bg[1]) + Math.abs(d[i + 2] - bg[2]) > 150) { x0 = Math.min(x0, x); y0 = Math.min(y0, y); x1 = Math.max(x1, x); y1 = Math.max(y1, y); } }
  return { x0, y0, x1, y1, w: x1 - x0 + 1, h: y1 - y0 + 1 }; })('%s')"""
# a list line's marker box and its text's box, the font size, and the "•" glyph the bullet used to be, measured in the text's font
BULLET = """((n) => { const l = input.querySelectorAll('.cm-line.cm-li')[n], m = l.querySelector('.cm-li-mark'), mr = m.getBoundingClientRect();
  const t = [...l.childNodes].find((x) => x.nodeType === 3), rg = document.createRange(); rg.selectNodeContents(t); const tr = rg.getBoundingClientRect();
  const cs = getComputedStyle(l), ctx = document.createElement('canvas').getContext('2d');
  ctx.font = cs.fontStyle + ' ' + cs.fontWeight + ' ' + cs.fontSize + ' ' + cs.fontFamily; const g = ctx.measureText('\\u2022');
  return { mark: { x: mr.x, y: mr.y, w: mr.width, h: mr.height }, text: { x: tr.x, y: tr.y, w: tr.width, h: tr.height }, fs: parseFloat(cs.fontSize),
           fill: getComputedStyle(m).webkitTextFillColor, disc_css: parseFloat(getComputedStyle(m, '::before').width), old: { w: g.actualBoundingBoxLeft + g.actualBoundingBoxRight, h: g.actualBoundingBoxAscent + g.actualBoundingBoxDescent } }; })(%d)"""


def ink(browser, r: dict) -> dict:
    shot = browser.send("Page.captureScreenshot", {"format": "png", "clip": {"x": r["x"], "y": r["y"], "width": r["w"], "height": r["h"], "scale": 1}})["data"]
    return browser.evaluate(INK % shot)


def drag(browser, x0: float, y0: float, x1: float, y1: float) -> None:
    browser.send("Input.dispatchMouseEvent", {"type": "mousePressed", "x": x0, "y": y0, "button": "left", "buttons": 1, "clickCount": 1})
    for i in range(1, 6):
        browser.send("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": x0 + (x1 - x0) * i / 5, "y": y0 + (y1 - y0) * i / 5, "button": "left", "buttons": 1})
    browser.send("Input.dispatchMouseEvent", {"type": "mouseReleased", "x": x1, "y": y1, "button": "left", "buttons": 0, "clickCount": 1})


def rng(s: dict) -> tuple:
    return (s["sel"]["start"], s["sel"]["end"], s["sel"]["backward"])


def test_a_selection_never_takes_a_bullet_with_its_ends(served, browser):
    # Shift+Home used to select the bullet. A range may not
    # start at a list line's start or inside its marker: the start is the item's text. Its end inside a marker is the line's
    # start, before the bullet. Select All (the whole document) is the one range that keeps the first marker.
    open_composer(browser, served)
    # Shift+Home: to the item's text, from the end and from the middle, on the first line and a later one; the anchor stays
    for text, at, want in [("- abc", 5, (2, 5, True)), ("- abc", 4, (2, 4, True)), ("  - abc", 7, (4, 7, True)), ("1. abc", 6, (3, 6, True)),
                           ("xy\n- abc", 8, (5, 8, True)), ("xy\n  1. abc", 9, (8, 9, True)), ("xy\nabc", 5, (3, 5, True))]:
        put(browser, text, at)
        key(browser, "Home", "Home", 36, modifiers=8)
        s = sel(browser)
        assert rng(s) == want and s["text"] == text, (text, at, s["sel"])
        key(browser, "Home", "Home", 36, modifiers=8)   # again: it stays
        assert rng(sel(browser)) == want, (text, at, sel(browser)["sel"])
    # Shift+Home with a forward selection that starts at the item's text: the range closes to a caret there
    put(browser, "- abc", 2, 4)
    key(browser, "Home", "Home", 36, modifiers=8)
    assert rng(sel(browser)) == (2, 2, False)
    # Shift+Left at the item's text start: the head goes on to the end of the line above (the anchor stays), as ArrowLeft does,
    # and does not take the marker; then on, one character at a time
    put(browser, "xy\n- abc", 5)
    seen = []
    for _ in range(3):
        arrow(browser, "Left", shift=True)
        seen.append(rng(sel(browser)))
    assert seen == [(2, 5, True), (1, 5, True), (0, 5, True)], seen
    put(browser, "- a\n  - b\nxy", 9)   # a nested item: the text starts after the indent too
    seen = []
    for _ in range(2):
        arrow(browser, "Left", shift=True)
        seen.append(rng(sel(browser)))
    assert seen == [(8, 9, True), (3, 9, True)], seen
    # on the first line there is nothing above: it stops at the text
    put(browser, "- abc", 4)
    for _ in range(4):
        arrow(browser, "Left", shift=True)
    assert rng(sel(browser)) == (2, 4, True)
    # a range reaching forward to the item's text start: the editor's own key shortens it, to the line's start (before the bullet)
    put(browser, "xy\n- abc", 0, 5)
    arrow(browser, "Left", shift=True)
    assert rng(sel(browser)) == (0, 3, False), sel(browser)["sel"]
    # Shift+Up onto a list line: the head is the item's text, never the marker; Shift+Down onto one: it ends in the item's text,
    # or before the bullet when it would land in the marker
    for text, at, name, want in [("- abc\nxy", 7, "Up", (2, 7, True)), ("- abc\nxy", 8, "Up", (2, 8, True)), ("1. abc\nxy", 8, "Up", (3, 8, True)),
                                 ("  - abc\nxy", 9, "Up", (4, 9, True)), ("xy\n- abc", 1, "Down", (1, 3, False)),
                                 ("xy\n  - abc", 0, "Down", (0, 3, False)), ("- a\n- b\n- c", 2, "Down", (2, 6, False))]:
        put(browser, text, at)
        arrow(browser, name, shift=True)
        s = sel(browser)
        assert rng(s) == want and s["text"] == text, (text, at, name, s["sel"])
    # Ctrl+Shift+Up, Down and Left (the page's own keys) hold to the same rule
    go = ("(() => { selectOffsets(%d, %d, false); document.querySelector('#input').dispatchEvent(new KeyboardEvent('keydown', "
          "{ key: %s, ctrlKey: true, shiftKey: true, bubbles: true, cancelable: true })); return selectionOf(); })()")
    browser.evaluate("setText('ab\\n- cd\\n- ef'); ''")
    assert browser.evaluate(go % (7, 7, json.dumps("ArrowUp"))) == {"start": 5, "end": 7, "backward": True}
    assert browser.evaluate(go % (5, 5, json.dumps("ArrowLeft"))) == {"start": 2, "end": 5, "backward": True}
    assert browser.evaluate(go % (1, 1, json.dumps("ArrowDown"))) == {"start": 1, "end": 3, "backward": False}
    # a drag that begins on a bullet starts at the item's text, one that ends on a bullet ends before it (or at the text)
    put(browser, "- abc\n- def\n- ghi", 17)
    box = browser.evaluate("""[...input.querySelectorAll('.cm-li-mark')].map((m) => { const r = m.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2, left: r.x + 1 }; })""")
    right = browser.evaluate("input.getBoundingClientRect().right - 4")
    drag(browser, box[0]["x"], box[0]["y"], right, box[1]["y"])   # from the first bullet to the end of the second line
    assert rng(sel(browser)) == (2, 11, False), sel(browser)["sel"]
    drag(browser, right, box[1]["y"], box[0]["x"], box[0]["y"])   # and back, ending on the first bullet
    assert rng(sel(browser)) == (2, 11, True), sel(browser)["sel"]
    drag(browser, right, box[0]["y"], box[2]["left"], box[2]["y"])   # from the end of the first line onto the third bullet
    assert rng(sel(browser)) == (5, 12, False), sel(browser)["sel"]
    put(browser, "- abc\n- def\n- ghi", 17)   # (a press inside a selection starts a drag of its text)
    drag(browser, box[1]["x"], box[1]["y"], box[2]["x"], box[2]["y"])   # bullet to bullet: the item's text of the second line, the third's start
    s = sel(browser)
    assert s["sel"]["start"] == 8 and s["sel"]["end"] in (12, 14) and s["text"] == "- abc\n- def\n- ghi", s["sel"]
    # Select All keeps the first marker: it is the whole document
    put(browser, "- abc\n- def", 4)
    key(browser, "a", "KeyA", 65, modifiers=2, commands=["SelectAll"])
    assert rng(sel(browser)) == (0, 11, False)
    # typing over a Shift+Home selection replaces the item's text and leaves the marker
    put(browser, "- abc", 5)
    key(browser, "Home", "Home", 36, modifiers=8)
    typed(browser, "x")
    s = sel(browser)
    assert s["text"] == "- x" and caret(s) == 3 and browser.evaluate(MARKS) == ["•"], s


def test_the_bullet_is_a_disc_sized_like_the_text_and_aligned_in_both_themes(served, browser):
    open_composer(browser, served)
    put(browser, "- xxxx\n  - xxxx\n1. xxxx", 24)
    browser.evaluate("input.blur(); ''")   # no caret in the pictures
    assert browser.evaluate(MARKS) == ["•", "•", "1."] and sel(browser)["text"] == "- xxxx\n  - xxxx\n1. xxxx"   # still the glyph in the DOM, still the text
    for dark in (True, False):
        browser.send("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-color-scheme", "value": "dark" if dark else "light"}]})
        browser.evaluate("new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))")
        discs = []
        for n in (0, 1):   # an item and a nested one
            b = browser.evaluate(BULLET % n)
            disc, letters = ink(browser, b["mark"]), ink(browser, b["text"])   # the pixels of the disc, and of "xxxx" beside it
            where = (("dark" if dark else "light"), n, b, disc, letters)
            fs = b["fs"]
            # clearly bigger than the "•" glyph it replaced (about 4 px at 15 px in this browser), and about the size of the text's
            # lowercase letters across: not under 0.45 of the font size, not a blob over 0.8
            assert disc["w"] >= 0.45 * fs and disc["h"] >= 0.45 * fs and disc["w"] <= 0.8 * fs and disc["h"] <= 0.8 * fs, where
            # the disc is drawn at half the font size by the CSS, whatever font the machine falls back to: that is the exact check
            assert abs(b["disc_css"] - 0.5 * fs) <= 0.01, where
            # and bigger than the "•" this machine's font would have drawn: by a pixel or more each way. The glyph's size is the font's
            # (4 px in one fallback font, 5 px in another at 15 px), so a ratio between the two flaked on a runner whose font has the larger bullet
            assert disc["w"] >= b["old"]["w"] + 1 and disc["h"] >= b["old"]["h"] + 1, where
            assert abs(disc["w"] - disc["h"]) <= 2, where   # round
            # aligned: the disc's middle is on the middle of the letters' ink (a lowercase x), within 2 px
            disc_mid = b["mark"]["y"] + disc["y0"] + disc["h"] / 2
            letter_mid = b["text"]["y"] + letters["y0"] + letters["h"] / 2
            assert abs(disc_mid - letter_mid) <= 2, (disc_mid, letter_mid, where)
            # the marker box is as it was (1.5em, the text clear of it) and its "•" is there but unpainted
            assert abs(b["mark"]["w"] - 1.5 * fs) <= 0.5 and b["text"]["x"] >= b["mark"]["x"] + b["mark"]["w"] - 0.5, where
            assert b["fill"] == "rgba(0, 0, 0, 0)", where
            discs.append(b["mark"]["x"] + disc["x0"])
        assert discs[1] > discs[0] + 10, discs   # the nested disc sits further in


def test_the_caret_rests_at_the_items_text_never_before_the_marker(served, browser):
    open_composer(browser, served)
    # put at the line's start, or inside the marker: on the text, for every kind of marker and level; a caret already on the text stays
    for text, start in [("- abc", 2), ("* abc", 2), ("  - abc", 4), ("    - abc", 6), ("1. abc", 3), ("12. abc", 4), ("  3. abc", 5), ("- ", 2)]:
        for at in range(0, start + 1):
            put(browser, text, at)
            assert caret(sel(browser)) == start, (text, at, sel(browser)["sel"])
        put(browser, text, len(text))
        assert caret(sel(browser)) == len(text)
    # later lines too, with a plain line before and after
    for text, at, want in [("xy\n- abc", 3, 5), ("xy\n  - abc\nz", 3, 7), ("- a\n- b\n- c", 4, 6), ("- a\n- b\n- c", 8, 10), ("- a\n\n1. b", 5, 8)]:
        put(browser, text, at)
        assert caret(sel(browser)) == want and sel(browser)["text"] == text, (text, at, sel(browser)["sel"])
    # a programmatic selection to the line start, from the page's own code or a transaction
    put(browser, "- abc\n- def", 11)
    browser.evaluate("selectOffsets(0, 0); ''")
    assert caret(sel(browser)) == 2
    browser.evaluate("selectOffsets(6, 6); ''")
    assert caret(sel(browser)) == 8
    browser.evaluate("composer.dispatch({ selection: { anchor: 0 } }); ''")
    assert caret(sel(browser)) == 2
    # an edit that makes the marker around the caret (the "- " typed at a line's start): the caret is on the text
    put(browser, "abc", 0)
    typed(browser, "- ")
    s = sel(browser)
    assert s["text"] == "- abc" and caret(s) == 2 and browser.evaluate(MARKS) == ["•"], s
    # Home: to the item's text, from the text and from the middle, on the first line and a later one; again, it stays
    for text, at, want in [("- abc", 5, 2), ("- abc", 2, 2), ("  - abc", 7, 4), ("xy\n- abc", 8, 5), ("xy\n  1. abc", 9, 8), ("xy\nabc", 5, 3)]:
        put(browser, text, at)
        key(browser, "Home", "Home", 36)
        assert caret(sel(browser)) == want, (text, at, sel(browser)["sel"])
        key(browser, "Home", "Home", 36)
        assert caret(sel(browser)) == want
    # ArrowLeft stops at the item's text; from there it goes on to the end of the line above, as from any line's start
    put(browser, "- abc", 4)
    seen = []
    for _ in range(4):
        arrow(browser, "Left")
        seen.append(caret(sel(browser)))
    assert seen == [3, 2, 2, 2], seen   # the first line: nothing above
    put(browser, "xy\n- abc", 6)
    seen = []
    for _ in range(3):
        arrow(browser, "Left")
        seen.append(caret(sel(browser)))
    assert seen == [5, 2, 1], seen   # the text's start, the end of "xy", one character back
    put(browser, "xy\n  - abc", 7)
    arrow(browser, "Left")
    assert caret(sel(browser)) == 2
    put(browser, "xy\n1. abc", 6)
    arrow(browser, "Left")
    assert caret(sel(browser)) == 2
    # ArrowRight from the end of the line above lands on the text, skipping the marker whole
    put(browser, "xy\n- abc", 2)
    arrow(browser, "Right")
    assert caret(sel(browser)) == 5
    # ArrowDown and ArrowUp onto a list line land on the text, whatever column they come from
    for text, at, key_name, want in [("xy\n- abc", 0, "Down", 5), ("xy\n- abc", 1, "Down", 5), ("xy\n  - abc", 0, "Down", 7),
                                     ("- abc\nxy", 6, "Up", 2), ("- abc\nxy", 7, "Up", 2), ("- abc\nxy", 8, "Up", 2), ("1. abc\nxy", 8, "Up", 3), ("  - abc\nxy", 9, "Up", 4)]:
        put(browser, text, at)
        arrow(browser, key_name)
        assert caret(sel(browser)) == want, (text, at, key_name, sel(browser)["sel"])
    # Ctrl+Left from the text's start goes on to the end of the line above; Ctrl+Up to the line above's start, and from mid-text
    # to the item's text; Ctrl+Down to the next line's text
    go = ("(() => { selectOffsets(%d, %d, false); document.querySelector('#input').dispatchEvent(new KeyboardEvent('keydown', "
          "{ key: %s, ctrlKey: true, shiftKey: false, bubbles: true, cancelable: true })); return selectionOf(); })()")
    ctrl = lambda at, k: browser.evaluate(go % (at, at, json.dumps(k)))  # noqa: E731
    browser.evaluate("setText('ab\\n- cd\\n- ef'); ''")
    assert ctrl(5, "ArrowLeft") == {"start": 2, "end": 2, "backward": False}
    assert ctrl(7, "ArrowUp") == {"start": 5, "end": 5, "backward": False}
    assert ctrl(5, "ArrowUp") == {"start": 0, "end": 0, "backward": False}
    assert ctrl(1, "ArrowDown") == {"start": 5, "end": 5, "backward": False}
    assert ctrl(5, "ArrowDown") == {"start": 10, "end": 10, "backward": False}
    # a tap at, before or on the bullet lands on the text, on a later line and on a nested item too
    put(browser, "xy\n- abc\n  - def", 16)
    for line, want in [(0, 5), (1, 13)]:
        box = browser.evaluate("(() => { const l = input.querySelectorAll('.cm-line.cm-li')[%d], m = l.querySelector('.cm-li-mark'), r = m.getBoundingClientRect();"
                               " return { y: r.y + r.height / 2, left: l.getBoundingClientRect().left, dot: r.x + r.width / 2, right: r.right }; })()" % line)
        for x in (box["left"] + 1, box["dot"], box["right"] - 2):
            click_at(browser, x, box["y"])
            assert caret(sel(browser)) == want, (line, x, sel(browser)["sel"])
    # Select All keeps its start at the line's start: the first marker is part of it (the one range that holds a marker's end;
    # Shift+Home, Shift+Left and a drag do not, see test_a_selection_never_takes_a_bullet_with_its_ends)
    put(browser, "- abc\n- def", 0, 11)
    s = sel(browser)
    assert s["sel"] == {"start": 0, "end": 11, "backward": False}, s["sel"]
    put(browser, "- abc", 5)
    key(browser, "a", "KeyA", 65, modifiers=2, commands=["SelectAll"])
    assert sel(browser)["sel"] == {"start": 0, "end": 5, "backward": False}
    arrow(browser, "Right")   # the range collapses to its end
    assert caret(sel(browser)) == 5


def test_backspace_where_the_caret_lands_leaves_the_list_and_the_text_sent_is_the_markdown(served, browser):
    open_composer(browser, served)
    # the caret put at the line's start is at the item's text, so Backspace there is the one that leaves the list
    for text, at, want, c in [("- abc", 0, "abc", 0), ("  - abc", 0, "abc", 0), ("1. a", 1, "a", 0), ("- a\n- b", 4, "- a\nb", 4), ("* x\n  * y", 4, "* x\ny", 4)]:
        put(browser, text, at)
        key(browser, "Backspace", "Backspace", 8)
        s = sel(browser)
        assert s["text"] == want and caret(s) == c, (text, s)
    # typing there goes into the text; what is sent is "- item", byte for byte, and no glyph with it
    put(browser, "- tem", 0)
    typed(browser, "i")
    s = sel(browser)
    assert s["text"] == "- item" and caret(s) == 3 and browser.evaluate(MARKS) == ["•"], s
    enter(browser)
    assert browser.evaluate("__sent") == [{"text": "- item", "uploads": []}]
    put(browser, "  - a\n1. b", 0)
    typed(browser, "x")
    assert sel(browser)["text"] == "  - xa\n1. b"


def test_a_korean_composition_where_the_caret_landed_at_the_line_start_commits_after_the_marker(served, browser):
    open_composer(browser, served)
    for prefix, rest, at in [("- ", "", 0), ("  - ", "", 1), ("1. ", "", 0), ("- ", "abc", 0), ("  * ", "abc", 3)]:
        put(browser, prefix + rest, at)
        for syl in ["ㅎ", "하", "한"]:
            browser.send("Input.imeSetComposition", {"text": syl, "selectionStart": 1, "selectionEnd": 1})
            s = sel(browser)
            assert s["text"] == prefix + syl + rest and len(browser.evaluate(MARKS)) == 1, (prefix, rest, s)   # the marker stays drawn
        typed(browser, "한")
        s = sel(browser)
        assert s["text"] == prefix + "한" + rest and caret(s) == len(prefix) + 1 and len(browser.evaluate(MARKS)) == 1, (prefix, rest, s)


# ---------- Backspace ----------

def backspace(browser) -> None:
    key(browser, "Backspace", "Backspace", 8)


def test_backspace_at_the_items_start_leaves_the_list(served, browser):
    open_composer(browser, served)
    for text, at, want, c in [("- abc", 2, "abc", 0), ("  - abc", 4, "abc", 0), ("1. a", 3, "a", 0), ("- a\n- ", 6, "- a\n", 4),
                              ("* x\n  * y", 8, "* x\ny", 4), ("- ", 2, "", 0)]:
        put(browser, text, at)
        backspace(browser)
        s = sel(browser)
        assert s["text"] == want and caret(s) == c, (text, s)
    # the line is plain afterwards: no dot, no hanging padding, the text at the line's left edge
    put(browser, "x\n- abc", 4)
    left_before = browser.evaluate("input.querySelectorAll('.cm-line')[1].querySelector('span.cm-li-mark').getBoundingClientRect().left")
    backspace(browser)
    got = browser.evaluate("""(() => { const l = input.querySelectorAll('.cm-line')[1]; const r = document.createRange(); r.selectNodeContents(l.firstChild);
      return { marks: input.querySelectorAll('.cm-li-mark, .cm-li').length, text: getText(), textLeft: r.getBoundingClientRect().left, lineLeft: l.getBoundingClientRect().left,
               pad: getComputedStyle(l).paddingLeft }; })()""")
    assert got["marks"] == 0 and got["text"] == "x\nabc" and got["pad"] == "0px" and got["textLeft"] <= got["lineLeft"] + 1, got
    assert got["textLeft"] < left_before + 16   # the text moved to where the dot was: visibly out of the list
    # Backspace elsewhere is the ordinary one: in the middle of the text, and at a plain line's start (it joins the lines)
    put(browser, "- abc", 4)
    backspace(browser)
    s = sel(browser)
    assert s["text"] == "- ac" and caret(s) == 3 and browser.evaluate(MARKS) == ["•"], s
    put(browser, "x\ny", 2)
    backspace(browser)
    assert sel(browser)["text"] == "xy"
    # a selection is deleted whole; its ends are not in a marker, so the first marker stays and the second goes
    put(browser, "- abc\n- def", 1, 8)
    backspace(browser)
    s = sel(browser)
    assert s["text"] == "- def" and caret(s) == 2, s
    # Backspace right after the list is left does not eat more: the next one deletes a character of the text
    put(browser, "- ab", 2)
    backspace(browser)
    backspace(browser)
    assert sel(browser)["text"] == "ab"
    put(browser, "ab", 2)
    backspace(browser)
    assert sel(browser)["text"] == "a"


# ---------- a Korean composition inside an item ----------

def test_a_korean_composition_in_a_list_item_commits_after_the_marker(served, browser):
    open_composer(browser, served)
    browser.evaluate("""window.__comp = []; for (const t of ["compositionstart", "compositionupdate", "compositionend"])
      input.addEventListener(t, (e) => __comp.push(t + ":" + e.data)); ''""")
    put(browser, "- ", 2)
    for syl in ["ㄱ", "그", "글"]:
        browser.send("Input.imeSetComposition", {"text": syl, "selectionStart": 1, "selectionEnd": 1})
        s = sel(browser)
        assert s["text"] == "- " + syl and browser.evaluate(MARKS) == ["•"], s   # the marker stays drawn while it composes
    typed(browser, "글")
    s = sel(browser)
    assert s["text"] == "- 글" and caret(s) == 3 and browser.evaluate(MARKS) == ["•"] and s["sent"] == [], s
    comp = browser.evaluate("__comp")
    assert comp[0] == "compositionstart:" and comp[-1] == "compositionend:글", comp
    # an Enter with keyCode 229 (an IME's key) during a composition changes nothing: no send, no new item
    for syl in ["ㅁ", "마"]:
        browser.send("Input.imeSetComposition", {"text": syl, "selectionStart": 1, "selectionEnd": 1})
    browser.send("Input.dispatchKeyEvent", {"type": "keyDown", "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 229})
    browser.send("Input.dispatchKeyEvent", {"type": "keyUp", "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 229})
    s = sel(browser)
    assert s["sent"] == [] and s["text"] == "- 글마" and browser.evaluate(MARKS) == ["•"], s
    # Backspace with keyCode 229 at the item's start (the IME deleting its own syllable) does not leave the list
    browser.send("Input.dispatchKeyEvent", {"type": "keyDown", "key": "Backspace", "code": "Backspace", "windowsVirtualKeyCode": 229})
    browser.send("Input.dispatchKeyEvent", {"type": "keyUp", "key": "Backspace", "code": "Backspace", "windowsVirtualKeyCode": 229})
    assert browser.evaluate(MARKS) == ["•"]
    typed(browser, "마")
    assert sel(browser)["text"] == "- 글마" and browser.evaluate(MARKS) == ["•"]
    # the composed text in the middle of a numbered list sends as typed
    put(browser, "1. ", 3)
    for syl in ["ㅎ", "하", "한"]:
        browser.send("Input.imeSetComposition", {"text": syl, "selectionStart": 1, "selectionEnd": 1})
    typed(browser, "한")
    enter(browser, shift=True)
    typed(browser, "둘")
    s = sel(browser)
    assert s["text"] == "1. 한\n2. 둘" and browser.evaluate(MARKS) == ["1.", "2."], s
    enter(browser)
    assert browser.evaluate("__sent.at(-1)") == {"text": "1. 한\n2. 둘", "uploads": []}


# ---------- images, files, undo ----------

def test_an_image_pasted_into_a_list_item_is_a_chip_and_leaves_the_document(served, browser):
    open_composer(browser, served)
    put(browser, "- a\n- b", 7)
    png = json.dumps(base64.b64encode(PNG).decode())
    browser.evaluate(f"""(() => {{ const bytes = Uint8Array.from(atob({png}), (c) => c.charCodeAt(0)); const dt = new DataTransfer();
      dt.items.add(new File([bytes], "kb.png", {{ type: "image/png" }}));
      input.dispatchEvent(new ClipboardEvent("paste", {{ clipboardData: dt, bubbles: true, cancelable: true }})); }})()""")
    got = browser.evaluate(WAIT_CHIPS % 1)
    assert got["chips"] == 1 and got["uploading"] == 0 and got["status"] == "", got
    s = sel(browser)
    assert s["text"] == "- a\n- b" and caret(s) == 7 and browser.evaluate(MARKS) == ["•", "•"], s
    # a text paste is the editor's own: it lands at the caret as plain text, in one undo step
    browser.evaluate("""(() => { const dt = new DataTransfer(); dt.setData("text/plain", "\\n- c"); dt.setData("text/html", "<b>x</b>");
      input.dispatchEvent(new ClipboardEvent("paste", { clipboardData: dt, bubbles: true, cancelable: true })); })()""")
    s = sel(browser)
    assert s["text"] == "- a\n- b\n- c" and browser.evaluate(MARKS) == ["•", "•", "•"], s
    enter(browser)
    sent = browser.evaluate("__sent")
    assert len(sent) == 1 and sent[0]["text"] == "- a\n- b\n- c" and len(sent[0]["uploads"]) == 1, sent


def test_a_file_dropped_on_the_editor_is_a_chip_never_text(served, browser):
    """CodeMirror's own drop handler reads a dropped file as text and inserts it; the composer must not: the window's drop
    handler attaches an image, and nothing lands in the document."""
    open_composer(browser, served)
    put(browser, "- keep", 6)
    png = json.dumps(base64.b64encode(PNG).decode())
    browser.evaluate(f"""(() => {{ const bytes = Uint8Array.from(atob({png}), (c) => c.charCodeAt(0)); const dt = new DataTransfer();
      dt.items.add(new File([bytes], "dropped.png", {{ type: "image/png" }}));
      const e = new DragEvent("drop", {{ dataTransfer: dt, bubbles: true, cancelable: true, clientX: 20, clientY: 10 }});
      input.dispatchEvent(e); return e.defaultPrevented; }})()""")
    got = browser.evaluate(WAIT_CHIPS % 1)
    assert got["chips"] == 1 and got["uploading"] == 0, got
    time.sleep(0.3)  # CodeMirror reads a dropped file asynchronously; had it taken this one, the text would change now
    assert sel(browser)["text"] == "- keep"


def test_a_sent_message_cannot_be_undone_back_into_the_box(served, browser):
    open_composer(browser, served)
    typed(browser, "- first")
    enter(browser)
    assert browser.evaluate(WAIT_SENT)
    assert sel(browser)["text"] == ""
    key(browser, "z", "KeyZ", 90, modifiers=2, commands=["Undo"])
    assert sel(browser)["text"] == ""   # the history started over with the empty box
    typed(browser, "next")
    key(browser, "z", "KeyZ", 90, modifiers=2, commands=["Undo"])
    assert sel(browser)["text"] == ""   # and typing is undone as usual
    key(browser, "y", "KeyY", 89, modifiers=2, commands=["Redo"])
    assert sel(browser)["text"] == "next"


def test_a_list_draft_comes_back_drawn_and_a_switch_leaves_no_undo(served, browser):
    open_composer(browser, served)
    typed(browser, "- a")
    enter(browser, shift=True)
    typed(browser, "b")
    browser.evaluate("new Promise((r) => setTimeout(r, 600))")   # saved 400 ms after the last key
    key_js = "localStorage.getItem('salaweb.draft.' + %s)" % json.dumps(NAME)
    assert browser.evaluate(key_js) == "- a\n- b"                 # the draft is the plain markdown
    browser.evaluate("window.__old = true; ''")
    browser.send("Page.reload")
    assert browser.evaluate("new Promise((res) => { const t0 = Date.now(); (function poll() { if ((!window.__old && document.querySelectorAll('#chat > .msg').length >= 1) || Date.now() - t0 > 15000) res(!window.__old); else setTimeout(poll, 100); })(); })")
    s = browser.evaluate(STATE)
    assert s["text"] == "- a\n- b" and browser.evaluate(MARKS) == ["•", "•"], s


# ---------- the look: three widths, both themes ----------

LONG = ("- a list item long enough to wrap on a phone and then some more words so that it wraps on a tablet as well, with a URL "
        "https://example.com/a/very/long/path/that/does/not/break/anywhere/at/all/0123456789012345678901234567890123456789\n"
        "  - nested item that also wraps around onto the next line when the screen is narrow enough for it\n"
        "1. 한글 항목도 줄바꿈이 됩니다. 긴 문장을 넣어서 여러 줄로 넘어가게 합니다. 그리고 더 길게 씁니다.\n"
        "plainwordwithoutanyspaceatallxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
MEASURE = """(() => { const q = (s) => document.querySelector(s); const ed = q('.cm-editor'), sc = q('.cm-scroller'), c = q('#input'), row = q('.compose-row');
  const r = row.getBoundingClientRect(), cs = getComputedStyle(c);
  return { vw: innerWidth, docScroll: document.documentElement.scrollWidth, bodyScroll: document.body.scrollWidth, scroller: [sc.scrollWidth, sc.clientWidth],
    rowInside: r.left >= 0 && r.right <= innerWidth + 0.5, send: q('#send').getBoundingClientRect().right <= innerWidth + 0.5,
    color: cs.color, panel: getComputedStyle(row).backgroundColor, mark: getComputedStyle(q('.cm-li-mark')).color,
    lineHeight: cs.lineHeight, scrolls: sc.scrollHeight > sc.clientHeight + 1, maxH: getComputedStyle(sc).maxHeight, h: sc.getBoundingClientRect().height, vh: innerHeight }; })()"""


def test_the_look_at_three_widths_in_both_themes(served, browser):
    open_composer(browser, served)
    put(browser, LONG, len(LONG))
    for w, h, mobile in ((320, 700, True), (390, 844, True), (1280, 800, False)):
        browser.send("Emulation.setDeviceMetricsOverride", {"width": w, "height": h, "deviceScaleFactor": 1, "mobile": mobile})
        end = time.time() + 5
        while time.time() < end and browser.evaluate("innerWidth") != w:
            time.sleep(0.05)
        for dark in (True, False):
            browser.send("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-color-scheme", "value": "dark" if dark else "light"}]})
            browser.evaluate("new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))")
            m = browser.evaluate(MEASURE)
            where = ("dark" if dark else "light", w)
            assert m["vw"] == w and m["docScroll"] <= w and m["bodyScroll"] <= w and m["rowInside"] and m["send"], (where, m)
            assert m["scroller"][0] <= m["scroller"][1] + 1, (where, m)         # long lines wrap, no sideways scroll
            assert m["lineHeight"] == "22px", (where, m)
            assert (m["scrolls"] or w == 1280) and m["h"] <= m["vh"] * 0.4 + 1, (where, m)   # past 40vh the editor scrolls instead of growing
            assert contrast(m["color"], m["panel"]) >= 4.5 and contrast(m["mark"], m["panel"]) >= 4.5, (where, m)
            var = browser.evaluate("(() => { const t = document.createElement('span'); document.body.append(t);"
                                   " const read = (v) => { t.style.color = `var(${v})`; return getComputedStyle(t).color; }; const out = { text: read('--text'), muted: read('--muted') }; t.remove(); return out; })()")
            assert m["color"] == var["text"] and m["mark"] == var["text"], (where, m, var)   # the app's variables follow the scheme; the bullet is the text's colour, no longer --muted


def test_the_editor_grows_with_its_lines_and_the_row_stays_one_line_tall_when_empty(served, browser):
    open_composer(browser, served)
    one = browser.evaluate("document.querySelector('.compose-row').getBoundingClientRect().height")
    put(browser, "a\nb\nc", 5)
    three = browser.evaluate("document.querySelector('.compose-row').getBoundingClientRect().height")
    assert abs((three - one) - 44) < 1.5, (one, three)   # two more lines of 22px
    put(browser, "", 0)
    assert abs(browser.evaluate("document.querySelector('.compose-row').getBoundingClientRect().height") - one) < 1.5
    # the send button is 30px and the empty editor is as tall, so the row is the button's height plus padding and border
    assert browser.evaluate("input.getBoundingClientRect().height") == 30
    escape(browser)
