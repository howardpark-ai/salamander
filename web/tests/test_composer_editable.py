"""The composer as a contenteditable (on Android Chrome with an on-screen keyboard, image select worked
but paste from the keyboard did not):
a phone keyboard offers its image insertion only to an editor that declares image types, which Chrome on Android does
for a contenteditable and not for a textarea. The editable is CodeMirror 6's (`#input` is its
contenteditable); these tests hold it to the textarea's behaviour, as they did the hand-made one: Enter sends the
text unchanged, Shift+Enter is a new line, every space and blank line round-trips to the send payload byte for byte, an
HTML paste lands as plain text, every way an image can reach the editable makes a chip, the placeholder, the draft
across a reload, a Korean IME composition, and Ctrl+arrows.

The page parts run in a headless Chromium when one is installed (conftest.py: `served`, `browser`); without one they
are skipped. Keys and IME compositions go through DevTools (Input.dispatchKeyEvent, Input.insertText,
Input.imeSetComposition), which are trusted events, so the browser's own editing runs on them. What no test here can
show is the phone keyboard itself: whether Chrome on the phone advertises image types for this editable and how it
delivers the image; the three delivery paths are each exercised with a synthetic event or DOM insertion instead.
"""

from __future__ import annotations

import base64
import json

from conftest import NAME
from sala_web.app import STATIC
from test_composer_attach import PNG, WAIT_CHIPS, WAIT_READY

INDEX = (STATIC / "index.html").read_text()
# the send is captured in the page: the fake session has no pane, and the payload is what these tests are about
SPY_SEND = """(() => { window.__sent = []; const real = window.fetch;
  window.fetch = (u, o) => { if (String(u).includes("/send")) { __sent.push(JSON.parse(o.body));
    return Promise.resolve(new Response(JSON.stringify({ ok: true }), { status: 200, headers: { "Content-Type": "application/json" } })); }
    return real(u, o); }; document.querySelector("#input").focus(); return document.activeElement.id; })()"""
STATE = """({ text: getText(), empty: !!document.querySelector("#composer-editor .cm-placeholder"),
   sent: window.__sent || [], sendEnabled: !document.querySelector("#send").disabled,
   lines: Math.round((document.querySelector("#input").getBoundingClientRect().height - 8) / 22) })"""


def key(browser, k: str, code: str, vk: int, text: str | None = None, modifiers: int = 0, commands: list | None = None) -> None:
    down: dict = {"type": "keyDown", "key": k, "code": code, "windowsVirtualKeyCode": vk, "modifiers": modifiers}
    if text is not None:
        down["text"] = text
    if commands:
        down["commands"] = commands
    browser.send("Input.dispatchKeyEvent", down)
    browser.send("Input.dispatchKeyEvent", {"type": "keyUp", "key": k, "code": code, "windowsVirtualKeyCode": vk, "modifiers": modifiers})


def enter(browser, shift: bool = False) -> None:
    key(browser, "Enter", "Enter", 13, "\r", 8 if shift else 0)


def typed(browser, text: str) -> None:
    browser.send("Input.insertText", {"text": text})


def open_composer(browser, served) -> None:
    browser.open(f"{served['url']}/#s={NAME}")
    assert browser.evaluate(WAIT_READY)
    assert browser.evaluate(SPY_SEND) == "input"


def test_the_composer_is_a_contenteditable_div():
    # index.html holds the mount; app.js makes the editor in it (CodeMirror 6, vendor/cm6-composer.min.js)
    assert '<textarea id="input"' not in INDEX
    assert '<div id="composer-editor"></div>' in INDEX and '<div id="input"' not in INDEX
    assert 'static/vendor/cm6-composer.min.js?v={{v}}' in INDEX


def test_editable_type_and_the_text_it_reads(served, browser):
    open_composer(browser, served)
    got = browser.evaluate("""(() => { const i = document.querySelector("#input"); return {
      editable: i.isContentEditable, mode: i.contentEditable, modify: getComputedStyle(i).getPropertyValue("-webkit-user-modify"),
      ws: getComputedStyle(i).whiteSpace, role: i.getAttribute("role"), tag: i.tagName }; })()""")
    # contenteditable="true" and user-modify read-write (CodeMirror's own plaintext-only is overridden in style.css: the keyboard's
    # image insertion), spaces kept as typed (CodeMirror's wrapping is break-spaces)
    assert got == {"editable": True, "mode": "true", "modify": "read-write", "ws": "break-spaces", "role": "textbox", "tag": "DIV"}, got
    assert browser.evaluate("input.closest('.cm-editor') !== null && input.classList.contains('cm-content') && document.querySelector('#composer-editor > .cm-editor') !== null")
    # setText/getText round-trip, byte for byte: spaces at the ends, blank lines, a trailing newline, tabs, Korean
    samples = ["a", " a ", "  lead", "trail  ", "a\nb", "a\n\nb", "a\n", "a\n\n", "\n", "\n\n", "\na", " \n \n ", "tab\there",
               "한글 입력\n두 번째 줄", "x" * 300 + "\n" + "y" * 300, ""]
    got = browser.evaluate("(() => { const out = []; for (const s of %s) { setText(s); out.push([s, getText(), !!document.querySelector('#composer-editor .cm-placeholder')]); } return out; })()"
                           % json.dumps(samples))
    assert [g[1] for g in got] == samples, json.dumps(got)
    assert [g[2] for g in got] == [s == "" for s in samples]
    # the text's line count is the editable's rendered line count (22px a line, 8px padding; min-height is one line)
    got = browser.evaluate("""(() => { const out = {}; for (const t of ["a", "a\\nb", "a\\n\\nb", "a\\n", "\\n\\n", "x".repeat(0)]) {
      setText(t); out[JSON.stringify(t)] = [Math.round((input.getBoundingClientRect().height - 8) / 22), Math.max(1, t.split("\\n").length)]; } setText(""); return out; })()""")
    bad = {k: v for k, v in got.items() if v[0] != v[1]}
    assert not bad, json.dumps(bad)
    # the text is the document, not the DOM: a node the browser puts into a line is not text
    assert browser.evaluate("(() => { setText('ab'); input.firstChild.append(document.createElement('b')); const t = getText(); setText(''); return t; })()") == "ab"


def test_typing_enter_sends_the_text_unchanged(served, browser):
    open_composer(browser, served)
    typed(browser, " hello 안녕 ")  # a leading and a trailing space
    s = browser.evaluate(STATE)
    assert s["text"] == " hello 안녕 " and not s["empty"] and s["sendEnabled"] and s["lines"] == 1, s
    enter(browser, shift=True)
    s = browser.evaluate(STATE)
    assert s["text"] == " hello 안녕 \n" and s["lines"] == 2 and s["sent"] == [], s  # a new line, nothing sent
    typed(browser, "  second ")
    enter(browser, shift=True)
    enter(browser, shift=True)  # a blank line
    typed(browser, "third")
    s = browser.evaluate(STATE)
    assert s["text"] == " hello 안녕 \n  second \n\nthird" and s["lines"] == 4, s
    enter(browser)
    s = browser.evaluate(STATE)
    assert s["sent"] == [{"text": " hello 안녕 \n  second \n\nthird", "uploads": []}], s
    assert s["text"] == "" and s["empty"] and not s["sendEnabled"], s
    # the message shows at once as a pending bubble with the text as written
    assert browser.evaluate("document.querySelector('#chat .msg.user.local .bubble').textContent") == " hello 안녕 \n  second \n\nthird"
    # typing again after the send works (the caret is still in the editable) and an empty composer sends nothing.
    # First the delivery must be over: send() ignores Enter while one is in flight, and the stubbed fetch's answer is
    # read in a later task, which the frames after the pending bubble (the chat growing, the view re-pinned) can push
    # past the next key DevTools sends (2 of 4 runs on main failed here before this wait, Thu Oct 15th 2026).
    assert browser.evaluate("""new Promise((res) => { const t0 = Date.now(); (function poll() {
      if (!state.sending || Date.now() - t0 > 5000) res(!state.sending); else setTimeout(poll, 20); })(); })""")
    typed(browser, "again")
    enter(browser)
    enter(browser)
    s = browser.evaluate(STATE)
    assert [m["text"] for m in s["sent"]] == [" hello 안녕 \n  second \n\nthird", "again"] and s["text"] == "", s


def test_a_paste_with_html_lands_as_plain_text(served, browser):
    open_composer(browser, served)
    typed(browser, "before ")
    # a real paste through a trusted key: rich HTML copied in the page (the headless clipboard holds text/html too)
    browser.evaluate("""(() => { const r = document.createElement("div"); r.id = "gbp-rich"; document.body.append(r);
      r.innerHTML = "<b>bold</b> and <i>italic</i><br>line2<p>para</p>";
      const s = getSelection(); s.selectAllChildren(r); const ok = document.execCommand("copy"); r.remove();
      const i = document.querySelector("#input"); i.focus(); s.selectAllChildren(i); s.collapseToEnd(); return ok; })()""")
    key(browser, "v", "KeyV", 86, modifiers=2, commands=["Paste"])
    s = browser.evaluate(STATE)
    assert s["text"] == "before bold and italic\nline2\npara", s
    html = browser.evaluate("input.innerHTML")
    assert "<b>" not in html and "<i>" not in html and "<p>" not in html and "style" not in html.replace('style="pointer-events: none;"', ""), html
    # the same through a paste event with text/html (the page's own handler, no clipboard involved)
    typed(browser, " ")
    browser.evaluate("""(() => { const dt = new DataTransfer(); dt.setData("text/plain", "x\\r\\ny"); dt.setData("text/html", "<u>x</u><br>y");
      return document.querySelector("#input").dispatchEvent(new ClipboardEvent("paste", { clipboardData: dt, bubbles: true, cancelable: true })); })()""")
    s = browser.evaluate(STATE)
    assert s["text"] == "before bold and italic\nline2\npara x\ny" and "<u>" not in browser.evaluate("input.innerHTML"), s
    # a formatting command is refused
    key(browser, "b", "KeyB", 66, modifiers=2, commands=["ToggleBold"])
    typed(browser, "Z")
    s = browser.evaluate(STATE)
    assert s["text"].endswith("yZ") and "<b>" not in browser.evaluate("input.innerHTML"), s
    enter(browser)
    assert browser.evaluate("__sent[0].text") == "before bold and italic\nline2\npara x\nyZ"


def b64(data: bytes) -> str:
    return json.dumps(base64.b64encode(data).decode())


def test_every_image_path_into_the_editable_makes_a_chip(served, browser):
    open_composer(browser, served)
    typed(browser, "text stays")
    # three images of their own (a byte apart): the three paths are three gestures here, and a later link of one gesture
    # skips the bytes an earlier link attached within the second (test_one_gesture_through_every_link_makes_one_chip)
    png_a, png_b, png_c = PNG, PNG + b"\x00", PNG + b"\x00\x00"
    file_js = lambda png: f"new File([Uint8Array.from(atob({b64(png)}), (c) => c.charCodeAt(0))], 'kb.png', {{ type: 'image/png' }})"  # noqa: E731
    # 1. a paste event carrying the image file (what a desktop paste and the Android paste menu give)
    browser.evaluate(f"""(() => {{ const dt = new DataTransfer(); dt.items.add({file_js(png_a)});
      document.querySelector("#input").dispatchEvent(new ClipboardEvent("paste", {{ clipboardData: dt, bubbles: true, cancelable: true }})); }})()""")
    got = browser.evaluate(WAIT_CHIPS % 1)
    assert got["chips"] == 1 and got["uploading"] == 0 and got["status"] == "", got
    # 2. beforeinput insertFromPaste with the file in its DataTransfer and no paste event before it
    prevented = browser.evaluate(f"""(() => {{ const dt = new DataTransfer(); dt.items.add({file_js(png_b)});
      const e = new InputEvent("beforeinput", {{ inputType: "insertFromPaste", dataTransfer: dt, bubbles: true, cancelable: true }});
      return !document.querySelector("#input").dispatchEvent(e); }})()""")
    assert prevented
    got = browser.evaluate(WAIT_CHIPS % 2)
    assert got["chips"] == 2 and got["uploading"] == 0, got
    # 3. an <img> the browser put into the editable (a data: image, as Chrome's own bitmap paste makes): lifted into a
    #    chip with the same bytes, removed from the editable, the text around it intact
    browser.evaluate(f"""(() => {{ const i = document.querySelector("#input"); const img = document.createElement("img");
      img.src = "data:image/png;base64," + {b64(png_c)}; const d = document.createElement("div"); d.append(img); i.append(d); return i.innerHTML.length; }})()""")
    got = browser.evaluate(WAIT_CHIPS % 3)
    assert got["chips"] == 3 and got["uploading"] == 0 and got["status"] == "", got
    s = browser.evaluate(STATE)
    assert s["text"] == "text stays" and browser.evaluate("input.querySelectorAll('img:not(.cm-widgetBuffer), .cm-content > div:not(.cm-line)').length") == 0, s
    uploads = served["settings"].uploads_dir
    assert sorted(p.read_bytes() for p in uploads.iterdir()) == [png_a, png_b, png_c]
    assert got["names"][2].endswith(".png")
    # the send carries the three uploads with the text
    enter(browser)
    sent = browser.evaluate("__sent")
    assert len(sent) == 1 and sent[0]["text"] == "text stays" and sorted(sent[0]["uploads"]) == sorted(got["names"])
    assert browser.evaluate("document.querySelectorAll('#chips .chip').length") == 0


def test_placeholder_shows_only_while_empty(served, browser):
    open_composer(browser, served)
    ph = "(document.querySelector('#composer-editor .cm-placeholder') || {}).textContent || null"
    assert browser.evaluate(ph) == "Message the session"  # the phone's short one (390px wide)
    assert browser.evaluate("input.getAttribute('aria-placeholder')") == "Message the session"
    typed(browser, "x")
    assert browser.evaluate(ph) is None and not browser.evaluate(STATE)["empty"]
    key(browser, "Backspace", "Backspace", 8)
    s = browser.evaluate(STATE)
    assert s["empty"] and s["text"] == "", s
    assert browser.evaluate(ph) == "Message the session"
    # emptied by a select-all and a delete, and by a cut: empty, and the send button stays off
    typed(browser, "abc")
    key(browser, "a", "KeyA", 65, modifiers=2)
    key(browser, "Delete", "Delete", 46)
    s = browser.evaluate(STATE)
    assert s["empty"] and s["text"] == "" and not s["sendEnabled"], s
    # a composition in progress is not empty
    browser.send("Input.imeSetComposition", {"text": "ㅎ", "selectionStart": 1, "selectionEnd": 1})
    assert not browser.evaluate(STATE)["empty"]


WAIT_FRESH = """
new Promise((res) => { const t0 = Date.now(); (function poll() {
  if ((!window.__old && document.querySelectorAll("#chat > .msg").length >= 1) || Date.now() - t0 > 15000) res(!window.__old); else setTimeout(poll, 100);
})(); })
"""


def test_a_draft_survives_a_reload(served, browser):
    open_composer(browser, served)
    typed(browser, " 초안 draft ")
    enter(browser, shift=True)
    typed(browser, "line 2")
    key_js = "localStorage.getItem('salaweb.draft.' + %s)" % json.dumps(NAME)
    browser.evaluate("new Promise((r) => setTimeout(r, 600))")  # saved 400 ms after the last keystroke, and kept in this browser
    assert browser.evaluate(key_js) == " 초안 draft \nline 2"
    # a real reload (opening the same #s= URL again would be a hash navigation)
    browser.evaluate("window.__old = true; ''")
    browser.send("Page.reload")
    assert browser.evaluate(WAIT_FRESH)
    s = browser.evaluate(STATE)
    assert s["text"] == " 초안 draft \nline 2" and not s["empty"] and s["sendEnabled"] and s["lines"] == 2, s
    assert browser.evaluate(key_js) == " 초안 draft \nline 2"  # kept until it is sent
    # the restored draft edits on: the caret goes to the end on focus-and-edit, and what is sent is the whole text
    assert browser.evaluate(SPY_SEND) == "input"
    browser.evaluate("focusEnd(); ''")
    typed(browser, "!")
    enter(browser)
    assert browser.evaluate("__sent[0].text") == " 초안 draft \nline 2!"
    assert browser.evaluate(key_js) is None  # sent: nothing to come back to


def test_a_korean_composition_keeps_its_text(served, browser):
    open_composer(browser, served)
    browser.evaluate("""window.__comp = []; for (const t of ["compositionstart", "compositionupdate", "compositionend"])
      document.querySelector("#input").addEventListener(t, (e) => __comp.push(t + ":" + e.data)); ''""")
    typed(browser, "abc ")
    for syl in ["ㅎ", "하", "한"]:
        browser.send("Input.imeSetComposition", {"text": syl, "selectionStart": 1, "selectionEnd": 1})
    s = browser.evaluate(STATE)
    assert s["text"] == "abc 한" and not s["empty"], s
    # Enter while composing arrives as keyCode 229 (the IME takes it): nothing is sent, the composition goes on
    browser.send("Input.dispatchKeyEvent", {"type": "keyDown", "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 229})
    browser.send("Input.dispatchKeyEvent", {"type": "keyUp", "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 229})
    s = browser.evaluate(STATE)
    assert s["sent"] == [] and s["text"] == "abc 한", s
    typed(browser, "한")  # the commit
    for syl in ["ㄱ", "그", "글"]:
        browser.send("Input.imeSetComposition", {"text": syl, "selectionStart": 1, "selectionEnd": 1})
    typed(browser, "글")
    s = browser.evaluate(STATE)
    assert s["text"] == "abc 한글", s
    assert "\n" not in browser.evaluate("input.textContent") and browser.evaluate("input.querySelectorAll('.cm-line').length") == 1
    comp = browser.evaluate("__comp")
    assert comp[0] == "compositionstart:" and "compositionupdate:한" in comp and "compositionend:한" in comp and comp[-1] == "compositionend:글", comp
    enter(browser)
    assert browser.evaluate("__sent") == [{"text": "abc 한글", "uploads": []}]


def test_ctrl_arrows_cross_line_breaks_as_before(served, browser):
    open_composer(browser, served)
    browser.evaluate("setText('ab\\ncd\\nef'); ''")
    go = ("(() => { selectOffsets(%d, %d, %s); document.querySelector('#input').dispatchEvent(new KeyboardEvent('keydown', "
          "{ key: %s, ctrlKey: true, shiftKey: %s, bubbles: true, cancelable: true })); return selectionOf(); })()")
    arrow = lambda start, end, back, k, shift=False: browser.evaluate(go % (start, end, "true" if back else "false", json.dumps(k), "true" if shift else "false"))  # noqa: E731
    assert arrow(3, 3, False, "ArrowLeft") == {"start": 2, "end": 2, "backward": False}    # across the break before "cd"
    assert arrow(2, 2, False, "ArrowRight") == {"start": 3, "end": 3, "backward": False}   # and back over it
    assert arrow(1, 1, False, "ArrowLeft") == {"start": 0, "end": 0, "backward": False}    # not at a break: the editor's own (by words)
    assert arrow(4, 4, False, "ArrowUp") == {"start": 3, "end": 3, "backward": False}      # to the start of the line
    assert arrow(3, 3, False, "ArrowUp") == {"start": 0, "end": 0, "backward": False}      # from a line start, a line up
    assert arrow(0, 0, False, "ArrowDown") == {"start": 3, "end": 3, "backward": False}    # the next line's start
    assert arrow(7, 7, False, "ArrowDown") == {"start": 8, "end": 8, "backward": False}    # the last line: its end
    assert arrow(4, 4, False, "ArrowUp", shift=True) == {"start": 3, "end": 4, "backward": True}  # Shift extends backward
    assert arrow(3, 4, True, "ArrowUp", shift=True) == {"start": 0, "end": 4, "backward": True}
    assert arrow(3, 3, False, "ArrowDown", shift=True) == {"start": 3, "end": 6, "backward": False}
    # the selection API agrees with the browser's: the editor's selection reads back in text offsets, and so does one the browser makes
    got = browser.evaluate("""(() => { selectOffsets(1, 7); const a = [getText(), selectionOf()]; const s = getSelection();
      const lines = input.querySelectorAll(".cm-line"); s.setBaseAndExtent(lines[0].firstChild, 1, lines[2].firstChild, 1);
      return new Promise((res) => setTimeout(() => res([a, selectionOf()]), 100)); })()""")
    assert got == [["ab\ncd\nef", {"start": 1, "end": 7, "backward": False}], {"start": 1, "end": 7, "backward": False}], got


# the chip count once the asynchronous paths (an <img> lift fetches its bytes) have had their say
CHIPS_AFTER = "new Promise((r) => setTimeout(() => r(document.querySelectorAll('#chips .chip').length), %d))"
# Chromium's delivery shape for one clipboard image, synthetic: the image in `files`, and an `items` entry whose
# getAsFile() makes a fresh File on every call ("image.png", a later lastModified each time), on an event the page's
# handler reads through an own property (a DataTransfer built in a page returns one File, so it cannot show this)
CHROME_SHAPE = """
const bytes = Uint8Array.from(atob(%s), (c) => c.charCodeAt(0));
let stamp = 1791991172262;
const fresh = () => new File([bytes], "image.png", { type: "image/png", lastModified: (stamp += 3) });
const shape = () => ({ files: [fresh()], items: [{ kind: "file", type: "image/png", getAsFile: fresh }], types: ["Files"], getData: () => "" });
const editable = document.querySelector("#input");
const paste = () => { const e = new ClipboardEvent("paste", { bubbles: true, cancelable: true }); Object.defineProperty(e, "clipboardData", { value: shape() }); return !editable.dispatchEvent(e); };
const beforeinput = () => { const e = new InputEvent("beforeinput", { inputType: "insertFromPaste", bubbles: true, cancelable: true }); Object.defineProperty(e, "dataTransfer", { value: shape() }); return !editable.dispatchEvent(e); };
const insert = () => { const img = document.createElement("img"); img.src = "data:image/png;base64," + %s; editable.append(img); return editable.querySelectorAll("img").length; };
"""


def test_one_gesture_through_every_link_makes_one_chip(served, browser):
    """Chromium delivers one paste as a chain: the paste event, then beforeinput insertFromPaste with the same files, then
    the <img> it inserts; the page stops it at the first link (preventDefault). Here the chain runs on regardless, as a
    browser that ignored the cancel would: Chrome's shape on the paste event (the image in files and as a fresh File from
    getAsFile(); two chips for one paste), the same on beforeinput, then the <img>. Exactly
    one chip. The same image pasted again is a second chip (two gestures on one link are never merged), and an image that
    enters at beforeinput and then as an <img> is one chip. The phone itself cannot be driven from here."""
    open_composer(browser, served)
    typed(browser, "text stays")
    png_a, png_b = PNG, PNG + b"\x00"
    chain = browser.evaluate(f"""(() => {{ {CHROME_SHAPE % (b64(png_a), b64(png_a))} return [paste(), beforeinput(), insert()]; }})()""")
    assert chain == [True, True, 1]  # the paste and the beforeinput were taken, the <img> went in
    got = browser.evaluate(WAIT_CHIPS % 1)
    assert got["chips"] == 1 and got["uploading"] == 0 and got["status"] == "", got
    assert browser.evaluate(CHIPS_AFTER % 400) == 1
    s = browser.evaluate(STATE)
    assert s["text"] == "text stays" and browser.evaluate("input.querySelectorAll('img:not(.cm-widgetBuffer)').length") == 0, s
    # the same image pasted again, at once: a second chip
    assert browser.evaluate(f"""(() => {{ {CHROME_SHAPE % (b64(png_a), b64(png_a))} return paste(); }})()""")
    got = browser.evaluate(WAIT_CHIPS % 2)
    assert got["chips"] == 2 and got["uploading"] == 0, got
    # another image, entering at beforeinput (no paste event) and then as the <img> that would follow it: one chip
    assert browser.evaluate(f"""(() => {{ {CHROME_SHAPE % (b64(png_b), b64(png_b))} return [beforeinput(), insert()]; }})()""") == [True, 1]
    got = browser.evaluate(WAIT_CHIPS % 3)
    assert got["chips"] == 3 and got["uploading"] == 0, got
    assert browser.evaluate(CHIPS_AFTER % 400) == 3
    uploads = served["settings"].uploads_dir
    assert sorted(p.read_bytes() for p in uploads.iterdir()) == [png_a, png_a, png_b]
    assert browser.evaluate("input.querySelectorAll('img:not(.cm-widgetBuffer)').length") == 0


def test_a_real_clipboard_image_paste_makes_one_chip(served, browser):
    """A PNG on the clipboard, pasted with a trusted Ctrl+V into the composer (the desktop paste; the phone keyboard's
    insertion with Chrome's media-insertion flag reaches the page as a paste too). What Chromium 155 hands the handler is
    recorded first: the image in clipboardData.files and from items[0].getAsFile(), distinct File objects named image.png
    of one size with rising lastModified stamps. One chip, nothing inserted into the editable, no beforeinput after the
    prevented paste; the same image pasted again is a second chip."""
    browser.call("Browser.grantPermissions", {"origin": served["url"], "permissions": ["clipboardReadWrite", "clipboardSanitizedWrite"]})
    browser.send("Emulation.setFocusEmulationEnabled", {"enabled": True})  # navigator.clipboard.write wants a focused document
    open_composer(browser, served)
    typed(browser, "keep ")
    size = browser.evaluate("""(async () => { const c = document.createElement("canvas"); c.width = c.height = 2;
      const g = c.getContext("2d"); g.fillStyle = "#c96442"; g.fillRect(0, 0, 2, 2);
      const blob = await new Promise((r) => c.toBlob(r, "image/png"));
      await navigator.clipboard.write([new ClipboardItem({ "image/png": blob })]); return blob.size; })()""")
    assert size > 0
    browser.evaluate("""(() => { const i = document.querySelector("#input"); window.__shape = []; window.__events = [];
      i.addEventListener("paste", (e) => { const cd = e.clipboardData; const f = cd.files[0], g1 = cd.items[0].getAsFile(), g2 = cd.items[0].getAsFile();
        __shape.push({ files: cd.files.length, items: cd.items.length, names: [f.name, g1.name, g2.name], oneSize: f.size === g1.size && g1.size === g2.size,
                       distinct: f !== g1 && g1 !== g2, rising: f.lastModified <= g1.lastModified && g1.lastModified <= g2.lastModified }); }, true);
      for (const t of ["beforeinput", "input"]) i.addEventListener(t, (e) => __events.push(t + ":" + e.inputType));
      i.focus(); const s = getSelection(); s.selectAllChildren(i); s.collapseToEnd(); return document.activeElement.id; })()""")
    key(browser, "v", "KeyV", 86, modifiers=2, commands=["Paste"])
    got = browser.evaluate(WAIT_CHIPS % 1)
    assert got["chips"] == 1 and got["uploading"] == 0 and got["status"] == "", got
    assert browser.evaluate("__shape") == [{"files": 1, "items": 1, "names": ["image.png", "image.png", "image.png"], "oneSize": True, "distinct": True, "rising": True}]
    assert browser.evaluate("__events") == []
    assert browser.evaluate(CHIPS_AFTER % 400) == 1
    s = browser.evaluate(STATE)
    assert s["text"] == "keep " and browser.evaluate("input.querySelectorAll('img:not(.cm-widgetBuffer)').length") == 0, s
    key(browser, "v", "KeyV", 86, modifiers=2, commands=["Paste"])
    got = browser.evaluate(WAIT_CHIPS % 2)
    assert got["chips"] == 2 and got["uploading"] == 0, got
    uploads = served["settings"].uploads_dir
    files = sorted(p.read_bytes() for p in uploads.iterdir())
    assert len(files) == 2 and files[0] == files[1] and files[0].startswith(b"\x89PNG")


# The Android keyboard's image (a regression: pasting an image from the keyboard was lost on
# mobile; no POST /api/upload reached the server). An Android keyboard's clipboard, image suggestions,
# stickers and GIFs hand the editable an image through commitContent as a paste or a beforeinput, as a File with no name, or
# of no type, or only in clipboardData.items. The handlers take every file now, so a File of no type or no bytes
# was uploaded as a generic file and the browser's own <img> insertion, which liftImage attaches, was cancelled.
ANDROID_SHAPES = """
const editable = document.querySelector("#input");
window.__xhr = []; const realOpen = XMLHttpRequest.prototype.open;
XMLHttpRequest.prototype.open = function (m, u, ...r) { __xhr.push(decodeURIComponent(String(u).split("name=")[1] || "")); return realOpen.call(this, m, u, ...r); };
const bytes = (b64) => Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
const mk = (b64, name, type) => new File([bytes(b64)], name, { type });
const itemsOnly = (f) => ({ files: [], items: [{ kind: "string", type: "text/plain" }, { kind: "file", type: f.type, getAsFile: () => f }], types: ["Files"], getData: () => "" });
const withFiles = (...fs) => ({ files: fs, items: fs.map((f) => ({ kind: "file", type: f.type, getAsFile: () => f })), types: ["Files"], getData: () => "" });
// true when the page cancelled the event (took the files), false when it left it to the browser
const paste = (cd) => { const e = new ClipboardEvent("paste", { bubbles: true, cancelable: true }); Object.defineProperty(e, "clipboardData", { value: cd }); return !editable.dispatchEvent(e); };
const beforeinput = (dt) => { const e = new InputEvent("beforeinput", { inputType: "insertFromPaste", bubbles: true, cancelable: true }); Object.defineProperty(e, "dataTransfer", { value: dt }); return !editable.dispatchEvent(e); };
const insertImg = (b64, mime) => { const img = document.createElement("img"); img.src = "data:" + mime + ";base64," + b64; const d = document.createElement("div"); d.append(img); editable.append(d); };
const clear = () => { state.uploads = []; renderChips(); __xhr.length = 0; };
"""
CHIP_KINDS = "[...document.querySelectorAll('#chips .chip')].map((c) => c.classList.contains('file') ? 'file:' + c.querySelector('.fc-name').textContent : 'image')"


def stored(served) -> dict:
    root = served["settings"].uploads_dir
    return {str(p.relative_to(root)): p.read_bytes() for p in root.rglob("*") if p.is_file()}


def test_an_android_keyboard_image_in_items_only_or_with_no_name_attaches(served, browser):
    open_composer(browser, served)
    browser.evaluate(ANDROID_SHAPES + "''")
    # (a) a paste whose clipboardData.files is empty and whose items hold the file (kind 'file' -> getAsFile()): an image chip
    assert browser.evaluate(f"paste(itemsOnly(mk({b64(PNG)}, 'image.png', 'image/png')))") is True
    got = browser.evaluate(WAIT_CHIPS % 1)
    assert got["chips"] == 1 and got["uploading"] == 0 and got["status"] == "", got
    assert browser.evaluate(CHIP_KINDS) == ["image"] and list(stored(served).values()) == [PNG]
    browser.evaluate("clear()")
    # (b) a file with an empty name and type image/png, on the paste event and on beforeinput: the image path, no name needed
    assert browser.evaluate(f"paste(withFiles(mk({b64(PNG + b'b')}, '', 'image/png')))") is True
    assert browser.evaluate(f"beforeinput(withFiles(mk({b64(PNG + b'cc')}, '', 'image/png')))") is True  # another size: not the same gesture
    got = browser.evaluate(WAIT_CHIPS % 2)
    assert got["chips"] == 2 and got["uploading"] == 0 and got["status"] == "", got
    assert browser.evaluate(CHIP_KINDS) == ["image", "image"]
    assert sorted(v for k, v in stored(served).items() if k.endswith(".png")) == sorted([PNG, PNG + b"b", PNG + b"cc"])
    browser.evaluate("clear()")
    # a nameless file that is not an image is named from its type: pasted-<time>.mp4 here, .bin when the type says nothing
    mp4 = b"\x00\x00\x00\x18ftypmp42" + bytes(64)
    assert browser.evaluate(f"paste(withFiles(mk({b64(mp4)}, '', 'video/mp4')))") is True
    assert browser.evaluate(f"beforeinput(itemsOnly(mk({b64(mp4 + b'x')}, '', 'application/x-weird')))") is True
    got = browser.evaluate(WAIT_CHIPS % 2)
    assert got["chips"] == 2 and got["uploading"] == 0 and got["status"] == "", got
    sent = browser.evaluate("__xhr")
    assert len(sent) == 2 and sent[0].startswith("pasted-") and sent[0].endswith(".mp4") and sent[1].startswith("pasted-") and sent[1].endswith(".bin"), sent
    kinds = browser.evaluate(CHIP_KINDS)
    assert kinds == ["file:" + sent[0], "file:" + sent[1]], kinds
    assert [got["names"][0].split("/")[1], got["names"][1].split("/")[1]] == sent
    s = stored(served)
    assert s[got["names"][0]] == mp4 and s[got["names"][1]] == mp4 + b"x"



def test_a_beforeinput_file_of_no_type_or_no_bytes_is_left_to_the_browser_and_its_img_is_lifted(served, browser):
    """The regression itself: an insertion whose File has no type (or none of its bytes) must not stop the browser's own
    <img> insertion, which liftImage turns into a thumbnail chip. A real file of any type, an unknown extension included,
    still attaches."""
    open_composer(browser, served)
    browser.evaluate(ANDROID_SHAPES + "''")
    # (c) beforeinput with a File of empty type (no name, a name without an extension, in items only): not cancelled, no chip ...
    taken = browser.evaluate(f"[beforeinput(withFiles(mk({b64(PNG)}, 'image', ''))), beforeinput(withFiles(mk({b64(PNG)}, '', ''))), "
                             f"beforeinput(itemsOnly(mk({b64(PNG)}, '', '')))]")
    assert taken == [False, False, False]
    assert browser.evaluate(CHIPS_AFTER % 200) == 0
    # ... then the <img> the browser inserts, whose blob has no usable type (octet-stream): the bytes say it is a png
    browser.evaluate(f"insertImg({b64(PNG)}, 'application/octet-stream'); ''")
    got = browser.evaluate(WAIT_CHIPS % 1)
    assert got["chips"] == 1 and got["uploading"] == 0 and got["status"] == "", got
    assert browser.evaluate(CHIP_KINDS) == ["image"] and list(stored(served).values()) == [PNG]
    assert list(stored(served))[0].endswith(".png")
    assert browser.evaluate("input.querySelectorAll('img:not(.cm-widgetBuffer)').length") == 0
    browser.evaluate("clear()")
    # a file with no bytes, typed or not, is left alone as well
    assert browser.evaluate("[beforeinput(withFiles(new File([], 'empty.png', { type: 'image/png' }))), "
                            "beforeinput(withFiles(new File([], 'empty.mp4', { type: 'video/mp4' })))]") == [False, False]
    # an image's extension with no type is the browser's too; a real file of no type with an unknown extension is taken
    data = b"col\n1\n"
    assert browser.evaluate(f"[beforeinput(withFiles(mk({b64(PNG)}, 'IMG_1.png', ''))), beforeinput(withFiles(mk({b64(data)}, 'table.parquet', '')))]") == [False, True]
    got = browser.evaluate(WAIT_CHIPS % 1)
    assert got["chips"] == 1 and got["uploading"] == 0, got
    assert browser.evaluate(CHIP_KINDS) == ["file:table.parquet"] and browser.evaluate("__xhr") == ["table.parquet"]
    assert stored(served)[got["names"][0]] == data
    assert browser.evaluate(CHIPS_AFTER % 200) == 1
    browser.evaluate("clear()")
    # the paste event takes a File of no type (the editor cancels a text-less paste itself, so no <img> would follow): a
    # png told by its bytes is an image chip, anything else a file named from its type
    assert browser.evaluate(f"paste(withFiles(mk({b64(PNG + b'p')}, '', '')))") is True
    got = browser.evaluate(WAIT_CHIPS % 1)
    assert got["chips"] == 1 and got["uploading"] == 0 and got["status"] == "", got
    assert browser.evaluate(CHIP_KINDS) == ["image"] and browser.evaluate("__xhr") == []
    assert got["names"][0].endswith(".png") and stored(served)[got["names"][0]] == PNG + b"p"
    browser.evaluate("clear()")
    # the chooser's pick of a PNG that carries no type is an image chip all the same
    browser.evaluate(f"""(() => {{ const dt = new DataTransfer(); dt.items.add(mk({b64(PNG + b'z')}, 'camera', ''));
      const fi = document.querySelector("#file-input"); fi.files = dt.files; fi.dispatchEvent(new Event("change", {{ bubbles: true }})); }})()""")
    got = browser.evaluate(WAIT_CHIPS % 1)
    assert got["chips"] == 1 and got["uploading"] == 0 and got["status"] == "", got
    assert browser.evaluate(CHIP_KINDS) == ["image"] and browser.evaluate("__xhr") == []
    assert stored(served)[got["names"][0]] == PNG + b"z"
