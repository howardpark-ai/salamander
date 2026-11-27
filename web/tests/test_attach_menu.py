"""The attach button on Android: a two-entry menu (photos and videos, files and camera), and every other platform's single tap
straight to the file chooser as before (app.js, the attach button; index.html, #attach-menu and the two file inputs).

The page parts run in a headless Chromium when one is installed (conftest.py: `served`, `browser`); without one they are
skipped. The user agent is set through DevTools before the page loads, so the page's own check (its user agent says Android)
is the one a phone takes. The inputs' click() is replaced in the page by a spy that records the input and returns: a headless
Chromium has no chooser to open, and the choice of input is what these tests pin. A pick is the change event a chooser fires.
"""

from __future__ import annotations

import base64
import json

from conftest import CHAT_READY, NAME
from sala_web.app import STATIC

INDEX = (STATIC / "index.html").read_text()
ANDROID_UA = ("Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36")
IPHONE_UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 "
             "Mobile/15E148 Safari/604.1")
DESKTOP_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64
MP4 = b"\x00\x00\x00\x18ftypmp42" + bytes(range(256)) * 4

SPY = """(() => {
  window.__picks = [];
  for (const id of ["file-input", "photo-input"]) {
    document.getElementById(id).click = function () { window.__picks.push([this.id, this.getAttribute("accept"), this.multiple]); };
  }
  return true; })()"""

STATE = """(() => { const m = document.getElementById("attach-menu"), a = document.getElementById("attach");
  const r = (el) => { const b = el.getBoundingClientRect(); return [b.top, b.height, b.width]; };
  return { shown: getComputedStyle(m).display !== "none", expanded: a.getAttribute("aria-expanded"),
           haspopup: a.getAttribute("aria-haspopup"), role: m.getAttribute("role"), label: m.getAttribute("aria-label"),
           items: [...m.querySelectorAll("[role=menuitem]")].map((b) => ({ text: b.textContent, role: b.getAttribute("role"),
             h: b.getBoundingClientRect().height })), active: document.activeElement && document.activeElement.id,
           composer: r(document.getElementById("composer")), chat: r(document.getElementById("chat")), input: r(document.getElementById("input")),
           picks: window.__picks }; })()"""

WAIT_CHIPS = """
new Promise((res) => { const t0 = Date.now(); (function poll() {
  const chips = document.querySelectorAll("#chips .chip"), up = document.querySelectorAll("#chips .chip.uploading");
  if ((chips.length >= %d && !up.length) || Date.now() - t0 > 15000)
    res({ chips: chips.length, uploading: up.length, names: state.uploads.map((u) => u.name), status: document.querySelector("#send-status").textContent });
  else setTimeout(poll, 100);
})(); })
"""


def pick_into(browser, input_id: str, name: str, mime: str, data: bytes) -> None:
    """What a chooser's pick does to the page: the input gets the file and fires change."""
    browser.evaluate(f"""(() => {{
      const bytes = Uint8Array.from(atob({json.dumps(base64.b64encode(data).decode())}), (c) => c.charCodeAt(0));
      const dt = new DataTransfer(); dt.items.add(new File([bytes], {json.dumps(name)}, {{ type: {json.dumps(mime)} }}));
      const fi = document.getElementById({json.dumps(input_id)}); fi.files = dt.files;
      fi.dispatchEvent(new Event("change", {{ bubbles: true }})); return fi.files.length; }})()""")


def open_page(served, browser, ua: str) -> None:
    browser.send("Emulation.setUserAgentOverride", {"userAgent": ua})
    browser.open(f"{served['url']}/#s={NAME}")
    browser.wait_ready(CHAT_READY)
    browser.evaluate(SPY)


def tap_attach(browser) -> None:
    # a tap on the button: it takes the focus (as a phone's tap does), then the click
    browser.evaluate("(() => { const a = document.getElementById('attach'); a.focus(); a.click(); return true; })()")


def test_markup_has_the_menu_and_the_two_inputs():
    # the chooser input is unchanged; the photo input takes the photo picker (image and video), multiple, hidden
    assert '<input id="file-input" type="file" multiple hidden>' in INDEX
    assert '<input id="photo-input" type="file" accept="image/*,video/*" multiple hidden>' in INDEX
    assert '<div id="attach-menu" class="attach-menu" role="menu" aria-label="Attach menu" data-i18n-aria-label="ui.cmp.menu">' in INDEX
    assert '<button type="button" role="menuitem" id="attach-photos" data-i18n="ui.cmp.photos">Photos and videos</button>' in INDEX
    assert '<button type="button" role="menuitem" id="attach-files" data-i18n="ui.cmp.files">Files and camera</button>' in INDEX


def test_android_tap_opens_the_menu_and_each_entry_opens_its_input(served, browser):
    open_page(served, browser, ANDROID_UA)
    before = browser.evaluate(STATE)
    assert before["shown"] is False and before["expanded"] == "false" and before["haspopup"] == "menu", before
    tap_attach(browser)
    opened = browser.evaluate(STATE)
    assert opened["shown"] is True and opened["expanded"] == "true", opened
    assert opened["role"] == "menu" and opened["label"] == "Attach menu"
    assert [(i["text"], i["role"]) for i in opened["items"]] == [("Photos and videos", "menuitem"), ("Files and camera", "menuitem")]
    assert all(i["h"] >= 44 for i in opened["items"]), opened["items"]
    # the composer and the chat do not move when the menu opens
    assert opened["composer"] == before["composer"] and opened["chat"] == before["chat"] and opened["input"] == before["input"], (before, opened)
    # photos and videos: the photo input, image and video accept, multiple
    browser.evaluate("document.getElementById('attach-photos').click()")
    got = browser.evaluate(STATE)
    assert got["picks"] == [["photo-input", "image/*,video/*", True]], got
    assert got["shown"] is False and got["expanded"] == "false"
    # files and camera: the chooser input, no accept list
    tap_attach(browser)
    browser.evaluate("document.getElementById('attach-files').click()")
    got = browser.evaluate(STATE)
    assert got["picks"] == [["photo-input", "image/*,video/*", True], ["file-input", None, True]], got
    assert got["shown"] is False


def test_android_menu_items_attach_through_the_same_path(served, browser):
    open_page(served, browser, ANDROID_UA)
    uploads = served["settings"].uploads_dir
    # a photo and a video from the photo input; a file from the chooser input
    pick_into(browser, "photo-input", "shot.png", "image/png", PNG)
    got = browser.evaluate(WAIT_CHIPS % 1)
    assert got["chips"] == 1 and got["uploading"] == 0 and got["status"] == "", got
    pick_into(browser, "photo-input", "clip.mp4", "video/mp4", MP4)
    got = browser.evaluate(WAIT_CHIPS % 2)
    assert got["chips"] == 2 and got["uploading"] == 0 and got["status"] == "", got
    assert got["names"][1].endswith("clip.mp4"), got
    # a file from the chooser input: the same chips and the same upload folder
    pick_into(browser, "file-input", "doc.txt", "text/plain", b"not an image")
    got = browser.evaluate(WAIT_CHIPS % 3)
    assert got["chips"] == 3 and got["uploading"] == 0 and got["status"] == "", got
    assert (uploads / got["names"][2]).read_bytes() == b"not an image"
    # both inputs cleared after a pick, so the same photo can come again
    assert browser.evaluate("[document.getElementById('photo-input').value, document.getElementById('file-input').value]") == ["", ""]


def test_menu_closes_on_a_tap_outside_escape_and_focus_leaving_it(served, browser):
    open_page(served, browser, ANDROID_UA)
    # a tap outside (the thread)
    tap_attach(browser)
    browser.evaluate("document.getElementById('chat').dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }))")
    got = browser.evaluate(STATE)
    assert got["shown"] is False and got["expanded"] == "false", got
    # Escape closes it and gives the focus back to the button
    tap_attach(browser)
    browser.evaluate("document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))")
    got = browser.evaluate(STATE)
    assert got["shown"] is False and got["active"] == "attach", got
    # focus moving to the composer closes it; a tap on the button itself toggles it
    tap_attach(browser)
    browser.evaluate("document.getElementById('input').focus()")
    got = browser.evaluate(STATE)
    assert got["shown"] is False, got
    tap_attach(browser)
    assert browser.evaluate(STATE)["shown"] is True
    tap_attach(browser)
    assert browser.evaluate(STATE)["shown"] is False
    # focus moving within the menu keeps it open; the arrow keys walk its entries
    tap_attach(browser)
    browser.evaluate("document.getElementById('attach-photos').focus()")
    assert browser.evaluate(STATE)["shown"] is True
    browser.evaluate("document.getElementById('attach-menu').dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }))")
    assert browser.evaluate(STATE)["active"] == "attach-files"
    browser.evaluate("document.getElementById('attach-menu').dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }))")
    assert browser.evaluate(STATE)["active"] == "attach-photos"


def test_other_platforms_tap_goes_straight_to_the_chooser(served, browser):
    for ua in (IPHONE_UA, DESKTOP_UA):
        open_page(served, browser, ua)
        before = browser.evaluate(STATE)
        assert before["haspopup"] is None and before["expanded"] is None, (ua, before)
        tap_attach(browser)
        got = browser.evaluate(STATE)
        assert got["picks"] == [["file-input", None, True]], (ua, got)
        assert got["shown"] is False and got["expanded"] is None, (ua, got)
        assert got["composer"] == before["composer"], (ua, before, got)
        browser.evaluate("document.getElementById('attach').click()")
        assert len(browser.evaluate("window.__picks")) == 2
        # a pick through the chooser's input attaches as before
        pick_into(browser, "file-input", "shot.png", "image/png", PNG)
        assert browser.evaluate(WAIT_CHIPS % 1)["chips"] == 1, ua
