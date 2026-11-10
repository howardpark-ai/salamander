"""The attach button and the paste path of the composer (on Android Chrome neither a paste nor a drop reached the composer).

The page parts run in a headless Chromium when one is installed (conftest.py: `served`, `browser`); without one they
are skipped. The file input is fed through DevTools (DOM.setFileInputFiles fires the input's change event), which is
the same event a chooser's pick fires.
"""

from __future__ import annotations

import base64
import json

from conftest import NAME
from sala_web.app import STATIC

INDEX = (STATIC / "index.html").read_text()
PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64  # the server stores bytes; it does not decode them


def test_composer_has_the_attach_control():
    # the chooser takes any file, multiple, hidden behind a named button
    assert '<input id="file-input" type="file" multiple hidden>' in INDEX
    assert '<button id="attach" class="attach-btn" type="button" aria-label="Attach files" data-i18n-aria-label="ui.cmp.attach"' in INDEX
    assert '<div id="drop-hint" data-i18n="ui.cmp.drop">Drop files to attach</div>' in INDEX


WAIT_READY = """
new Promise((res) => { const t0 = Date.now(); (function poll() {
  if (document.querySelectorAll("#chat > .msg").length >= 1 || Date.now() - t0 > 15000) res(true); else setTimeout(poll, 100);
})(); })
"""
WAIT_CHIPS = """
new Promise((res) => { const t0 = Date.now(); (function poll() {
  const chips = document.querySelectorAll("#chips .chip"), up = document.querySelectorAll("#chips .chip.uploading");
  if ((chips.length >= %d && !up.length) || Date.now() - t0 > 15000)
    res({ chips: chips.length, uploading: up.length, names: state.uploads.map((u) => u.name), cleared: document.querySelector("#file-input").value === "",
          sendEnabled: !document.querySelector("#send").disabled, status: document.querySelector("#send-status").textContent,
          attachBusy: document.querySelector("#attach").getAttribute("aria-busy") });
  else setTimeout(poll, 100);
})(); })
"""


def pick(browser, name: str, mime: str, data: bytes) -> None:
    """What a chooser's pick does to the page: the file input gets the file and fires change. (DevTools'
    DOM.setFileInputFiles would take a path the snap-confined chromium cannot read under /tmp.)"""
    browser.evaluate(f"""(() => {{
      const bytes = Uint8Array.from(atob({json.dumps(base64.b64encode(data).decode())}), (c) => c.charCodeAt(0));
      const dt = new DataTransfer(); dt.items.add(new File([bytes], {json.dumps(name)}, {{ type: {json.dumps(mime)} }}));
      const fi = document.querySelector("#file-input"); fi.files = dt.files;
      fi.dispatchEvent(new Event("change", {{ bubbles: true }})); return fi.files.length; }})()""")


def test_attach_button_feeds_the_same_upload_path_as_a_paste(served, browser):
    browser.open(f"{served['url']}/#s={NAME}")
    assert browser.evaluate(WAIT_READY)
    # the button: a 44 px touch target with a name, over the hidden chooser
    att = browser.evaluate("(() => { const a = document.querySelector('#attach'), r = a.getBoundingClientRect(); "
                           "return { w: r.width, h: r.height, label: a.getAttribute('aria-label'), disabled: a.disabled, "
                           "type: a.type, width: innerWidth }; })()")
    assert att["width"] == 390 and att["w"] >= 44 and att["h"] >= 44 and att["type"] == "button", att
    assert att["label"] == "Attach files" and not att["disabled"]
    # a pick through the chooser: the file goes up api/upload, shows as a chip, send is enabled, the input is cleared
    pick(browser, "shot.png", "image/png", PNG)
    got = browser.evaluate(WAIT_CHIPS % 1)
    assert got["chips"] == 1 and got["uploading"] == 0 and got["cleared"] and got["sendEnabled"], got
    assert got["status"] == "" and got["attachBusy"] == "false"
    assert len(got["names"]) == 1 and got["names"][0]
    uploads = served["settings"].uploads_dir
    assert (uploads / got["names"][0]).read_bytes() == PNG
    # the same photo again (the value was cleared, so the chooser's change fires for it): a second chip
    pick(browser, "shot.png", "image/png", PNG)
    got = browser.evaluate(WAIT_CHIPS % 2)
    assert got["chips"] == 2 and got["cleared"], got
    assert len(list(uploads.iterdir())) == 2
    # a file of another type is a file chip now, stored in a folder of its own beside the images
    pick(browser, "doc.txt", "text/plain", b"not an image")
    got = browser.evaluate(WAIT_CHIPS % 3)
    assert got["chips"] == 3 and got["uploading"] == 0 and got["status"] == "" and got["cleared"], got
    assert got["names"][2].endswith("/doc.txt")
    assert (uploads / got["names"][2]).read_bytes() == b"not an image"
    # a paste with an image file lands in the same chips (the browser fills both clipboardData.files and .items)
    browser.evaluate("""(() => { const dt = new DataTransfer();
      dt.items.add(new File([new Uint8Array(16)], "pasted.png", { type: "image/png" }));
      document.querySelector("#input").dispatchEvent(new ClipboardEvent("paste", { clipboardData: dt, bubbles: true, cancelable: true }));
      return dt.files.length + "/" + dt.items.length; })()""")
    got = browser.evaluate(WAIT_CHIPS % 4)
    assert got["chips"] == 4 and got["uploading"] == 0, got  # one chip, not one per source
    assert len(list(uploads.iterdir())) == 4  # three images and the folder of doc.txt


def test_paste_reads_clipboard_items_only_when_files_is_empty(served, browser):
    """clipboardData.files holds every file a paste carries (HTML spec); .items is read only when files is empty, a net for
    a browser that fills items alone. Chromium's shape for a clipboard image (two chips for one paste on Android Chrome): files holds a File, and items[0].getAsFile() makes a new File on every call, "image.png" with
    lastModified = the time of the call, so reading it beside files gave a second File no field could match."""
    browser.open(f"{served['url']}/#s={NAME}")
    assert browser.evaluate(WAIT_READY)
    got = browser.evaluate("""(() => {
      const f = new File([new Uint8Array(4)], "a.png", { type: "image/png" });
      const t = new File([new Uint8Array(4)], "a.txt", { type: "text/plain" });
      const item = (file) => ({ kind: "file", type: file.type, getAsFile: () => file });
      // Chromium's clipboard item: a fresh File per getAsFile() call, a later lastModified each time
      let calls = 0, stamp = 1791991172262;
      const fresh = () => { calls++; return new File([new Uint8Array(4)], "image.png", { type: "image/png", lastModified: (stamp += 3) }); };
      const chrome = { kind: "file", type: "image/png", getAsFile: fresh };
      const chromeShape = clipboardImages({ files: [new File([new Uint8Array(4)], "image.png", { type: "image/png", lastModified: stamp })], items: [chrome] }).length;
      const callsWithFiles = calls;
      return {
        filesOnly: clipboardImages({ files: [f], items: [] }).length,
        itemsOnly: clipboardImages({ files: [], items: [item(f)] }).length,
        both: clipboardImages({ files: [f], items: [item(f)] }).length,
        chromeShape, callsWithFiles,
        itemsOnlyFresh: clipboardImages({ files: [], items: [chrome, chrome] }).length,
        twoInFiles: clipboardImages({ files: [f, new File([new Uint8Array(5)], "b.png", { type: "image/png" })], items: [item(f)] }).length,
        nonImage: clipboardImages({ files: [t], items: [item(t), { kind: "string", type: "text/plain" }] }).length,
        none: clipboardImages(null).length,
      }; })()""")
    assert got == {"filesOnly": 1, "itemsOnly": 1, "both": 1, "chromeShape": 1, "callsWithFiles": 0, "itemsOnlyFresh": 2,
                   "twoInFiles": 2, "nonImage": 0, "none": 0}, json.dumps(got)
    # the paste handler takes any file: clipboardFiles is the same read without the image filter
    got = browser.evaluate("""(() => {
      const t = new File([new Uint8Array(4)], "a.txt", { type: "text/plain" });
      const m = new File([new Uint8Array(4)], "a.mp4", { type: "video/mp4" });
      const item = (file) => ({ kind: "file", type: file.type, getAsFile: () => file });
      return { files: clipboardFiles({ files: [t, m], items: [] }).length, itemsOnly: clipboardFiles({ files: [], items: [item(m), { kind: "string" }] }).length,
               imagesOfThem: clipboardImages({ files: [t, m], items: [] }).length, none: clipboardFiles(null).length }; })()""")
    assert got == {"files": 2, "itemsOnly": 1, "imagesOfThem": 0, "none": 0}, json.dumps(got)


CAPTURE_SEND = """
(() => { window.__sent = []; const real = window.fetch;
  window.fetch = (url, opts) => String(url).includes("/send")
    ? (window.__sent.push(JSON.parse(opts.body)), Promise.resolve(new Response(JSON.stringify({ ok: true, imagesPasted: 0, imagesAttached: 0, filesPasted: 1 }), { status: 200 })))
    : real(url, opts);
  return true; })()
"""


def test_a_non_image_file_shows_as_a_file_chip_and_send_carries_its_path_reference(served, browser):
    """attach (the chooser's change), paste and drop take any file; a non-image shows as a chip with a file
    icon, its name and its size, uploads to uploads/<folder>/<safe name>, and send carries the reference."""
    browser.open(f"{served['url']}/#s={NAME}")
    assert browser.evaluate(WAIT_READY)
    mp4 = b"\x00\x00\x00\x18ftypmp42" + bytes(range(256)) * 6   # about 1.5 KB of binary
    pick(browser, "my holiday clip.mp4", "video/mp4", mp4)
    got = browser.evaluate(WAIT_CHIPS % 1)
    assert got["chips"] == 1 and got["uploading"] == 0 and got["sendEnabled"] and got["status"] == "", got
    chip = browser.evaluate("""(() => { const c = document.querySelector("#chips .chip.file"), b = c.querySelector("button");
      return { cls: c.className, role: c.getAttribute("role"), label: c.getAttribute("aria-label"), img: !!c.querySelector("img"),
               icon: !!c.querySelector("svg.fc-icon"), name: c.querySelector(".fc-name").textContent,
               meta: c.querySelector(".fc-meta").textContent, btnLabel: b.getAttribute("aria-label"), btnType: b.type,
               btnTab: b.tabIndex, bar: getComputedStyle(c.querySelector(".fc-bar")).display }; })()""")
    assert chip["icon"] and not chip["img"] and chip["name"] == "my holiday clip.mp4" and chip["meta"] == "1.5 KB", chip
    assert chip["role"] == "group" and chip["label"] == "Attached file my holiday clip.mp4", chip
    assert chip["btnLabel"] == "Remove my holiday clip.mp4" and chip["btnType"] == "button" and chip["btnTab"] >= 0, chip
    assert chip["bar"] == "none"  # no progress bar once it is up
    ref = got["names"][0]
    assert ref.endswith("/my_holiday_clip.mp4")
    assert (served["settings"].uploads_dir / ref).read_bytes() == mp4
    # a paste carrying a non-image file lands in a chip too
    browser.evaluate("""(() => { const dt = new DataTransfer();
      dt.items.add(new File([new Uint8Array(2048)], "notes.pdf", { type: "application/pdf" }));
      document.querySelector("#input").dispatchEvent(new ClipboardEvent("paste", { clipboardData: dt, bubbles: true, cancelable: true }));
      return dt.files.length; })()""")
    got = browser.evaluate(WAIT_CHIPS % 2)
    assert got["chips"] == 2 and got["uploading"] == 0 and got["names"][1].endswith("/notes.pdf"), got
    assert browser.evaluate("document.querySelectorAll('#chips .chip.file .fc-meta')[1].textContent") == "2.0 KB"
    # send: the references go in the request, the sent bubble shows the files by name and size, the chips clear
    assert browser.evaluate(CAPTURE_SEND)
    browser.evaluate("document.querySelector('#send').click()")
    sent = browser.evaluate("""new Promise((res) => { const t0 = Date.now(); (function poll() {
      if (window.__sent.length || Date.now() - t0 > 5000) res(window.__sent); else setTimeout(poll, 50); })(); })""")
    assert sent == [{"text": "", "uploads": got["names"]}], sent
    bubble = browser.evaluate("""[...document.querySelectorAll("#chat .msg.local .sent-file")].map((n) =>
      n.querySelector(".sf-name").textContent + "|" + n.querySelector(".sf-size").textContent)""")
    assert bubble == ["my holiday clip.mp4|1.5 KB", "notes.pdf|2.0 KB"], bubble
    assert browser.evaluate("document.querySelectorAll('#chips .chip').length") == 0


def test_a_file_chip_shows_progress_and_an_error_and_remove_stops_the_upload(served, browser):
    browser.open(f"{served['url']}/#s={NAME}")
    assert browser.evaluate(WAIT_READY)
    got = browser.evaluate("""(async () => {
      let aborted = 0;
      const big = 640 * 1024 * 1024;
      state.uploads.push({ id: 901, kind: "file", fileName: "big.mov", size: big, loaded: big / 2,
                           uploading: true, name: null, error: "", xhr: { abort: () => { aborted++; } } });
      state.uploads.push({ id: 902, kind: "file", fileName: "bad.zip", size: 1000, loaded: 0, uploading: false, name: null, error: "file too large (limit 500 MB)" });
      renderChips(); await new Promise((r) => setTimeout(r, 50));
      const [up, bad] = document.querySelectorAll("#chips .chip.file");
      const out = { up: up.className, upMeta: up.querySelector(".fc-meta").textContent, upBar: up.querySelector(".fc-bar").style.width,
                    barShown: getComputedStyle(up.querySelector(".fc-bar")).display,
                    bad: bad.className, badMeta: bad.querySelector(".fc-meta").textContent, badTitle: bad.title,
                    sendWhileUploading: document.querySelector("#send").disabled };
      up.querySelector("button").click();   // remove the one still going up
      out.aborted = aborted; out.left = state.uploads.map((u) => u.id);
      state.uploads = []; renderChips();
      state.uploads.push({ id: 903, kind: "file", fileName: "e.txt", size: 1, error: "boom", uploading: false, name: null });
      renderChips();
      out.sendWithOnlyAnError = document.querySelector("#send").disabled;
      state.uploads = []; renderChips();
      return out; })()""")
    assert got["up"] == "chip file uploading" and got["upMeta"] == "Uploading 50% of 640 MB" and got["upBar"] == "50%", got
    assert got["barShown"] != "none" and got["sendWhileUploading"] is True, got
    assert got["bad"] == "chip file failed" and got["badMeta"] == "Failed: file too large (limit 500 MB)", got
    assert "file too large" in got["badTitle"] and got["aborted"] == 1 and got["left"] == [902], got
    assert got["sendWithOnlyAnError"] is True, got  # a chip that failed is nothing to send
