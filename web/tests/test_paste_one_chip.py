"""One Ctrl+V of a screenshot-sized image makes one chip and one upload, and the image goes up at a size the pane attaches.

A field report (Chrome on a desktop): one Ctrl+V of a 3000 x 4000 image stored two byte-identical PNGs of 19 MB, 38 ms apart (so
two uploads started in one task), and the pane's session received neither (a JPEG of 2.9 MB sent next did arrive). The page parts
run in a headless Chromium when one is installed (conftest.py: `served`, `browser`) and are skipped without one.

- a paste event that carries one picture twice (two Files, other names and times, the same bytes) makes one chip;
- a paste, its beforeinput and the <img> that follows are one gesture even when reading a big clipboard image takes more than
  the second the gesture window lasts (the window now counts from when the later link began);
- a real trusted Ctrl+V of a 3000 x 4000 image (a PNG of about 15 MB on the clipboard) makes one chip and one stored file, a JPEG.
"""

from __future__ import annotations

import json

from test_composer_attach import PNG, WAIT_CHIPS
from test_composer_editable import STATE, key, open_composer, typed


def b64(data: bytes) -> str:
    import base64
    return json.dumps(base64.b64encode(data).decode())


# JS: events made the way Chromium delivers them, on an own property (a DataTransfer built in a page cannot hold two Files that
# differ only in name and time). `files` is a getter, so a test can make reading it slow, as it is for a big clipboard image.
SHAPES = """
const bytes = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
const editable = document.querySelector("#input");
const busy = (ms) => { const t = performance.now(); while (performance.now() - t < ms); };
const png = (name, stamp, data) => new File([data], name, { type: "image/png", lastModified: stamp });
const cd = (files, slow) => ({ get files() { if (slow) busy(slow); return files; }, items: [], types: ["Files"], getData: () => "" });
const paste = (files, slow) => { const e = new ClipboardEvent("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(e, "clipboardData", { value: cd(files, slow) }); return !editable.dispatchEvent(e); };
const beforeinput = (files, slow) => { const e = new InputEvent("beforeinput", { inputType: "insertFromPaste", bubbles: true, cancelable: true });
  Object.defineProperty(e, "dataTransfer", { value: cd(files, slow) }); return !editable.dispatchEvent(e); };
const insert = (data) => { const img = document.createElement("img"); img.src = "data:image/png;base64," + data; editable.append(img); return 1; };
"""
CHIPS_AFTER = "new Promise((r) => setTimeout(() => r(document.querySelectorAll('#chips .chip').length), %d))"


def test_one_paste_that_carries_one_picture_twice_makes_one_chip(served, browser):
    open_composer(browser, served)
    a, c = PNG, PNG[:-1] + b"\x01"  # the same size, other bytes
    a64, c64 = b64(a), b64(c)
    # two Files of one paste, the same bytes under two names and times: one chip
    assert browser.evaluate(f"""(() => {{ {SHAPES}
      return paste([png("image.png", 1791991172262, bytes({a64})), png("screenshot.png", 1791991172301, bytes({a64}))]); }})()""")
    got = browser.evaluate(WAIT_CHIPS % 1)
    assert got["chips"] == 1 and got["uploading"] == 0 and got["status"] == "", got
    assert browser.evaluate(CHIPS_AFTER % 600) == 1
    # the same size and other bytes are two pictures: two chips
    assert browser.evaluate(f"""(() => {{ {SHAPES}
      return paste([png("a.png", 1, bytes({a64})), png("c.png", 2, bytes({c64}))]); }})()""")
    got = browser.evaluate(WAIT_CHIPS % 3)
    assert got["chips"] == 3 and got["uploading"] == 0, got
    # the same bytes in two beforeinput Files: one chip (other bytes than the pastes above, which are one gesture's window old)
    d64 = b64(PNG + b"\x00")
    assert browser.evaluate(f"""(() => {{ {SHAPES}
      return beforeinput([png("x.png", 1, bytes({d64})), png("y.png", 2, bytes({d64}))]); }})()""")
    got = browser.evaluate(WAIT_CHIPS % 4)
    assert got["chips"] == 4 and got["uploading"] == 0, got
    assert browser.evaluate(CHIPS_AFTER % 600) == 4
    # a file that is not an image is never merged with its twin
    assert browser.evaluate("""(() => { const editable = document.querySelector("#input");
      const f = (n) => new File([new Uint8Array([1, 2, 3])], n, { type: "text/plain" });
      const e = new ClipboardEvent("paste", { bubbles: true, cancelable: true });
      Object.defineProperty(e, "clipboardData", { value: { files: [f("a.txt"), f("b.txt")], items: [], types: ["Files"], getData: () => "" } });
      return !editable.dispatchEvent(e); })()""")
    got = browser.evaluate(WAIT_CHIPS % 6)
    assert got["chips"] == 6 and got["uploading"] == 0, got
    stored = list(served["settings"].uploads_dir.iterdir())
    assert len(stored) == 6  # four images and the two folders of the text files
    images = sorted(p.read_bytes() for p in stored if p.is_file())
    assert len(images) == 4 and images.count(a) == 2 and images.count(c) == 1 and images.count(PNG + b"\x00") == 1


def test_a_slow_clipboard_read_does_not_make_the_next_link_a_new_gesture(served, browser):
    """Reading `files` of a 3000 x 4000 clipboard image encodes it as a PNG: a second or more on each read, once for the paste and
    once for its beforeinput. The gesture window (one second) used to be measured at the end of that read, so the beforeinput
    was a new gesture, and the <img> after it too: three chips for one paste. Here each read is 1.2 s."""
    open_composer(browser, served)
    a64 = b64(PNG)
    chain = browser.evaluate(f"""(() => {{ {SHAPES}
      const f = () => [png("image.png", Date.now(), bytes({a64}))];
      return [paste(f(), 1200), beforeinput(f(), 1200), insert({a64})]; }})()""", timeout_ms=60000)
    assert chain == [True, True, 1]
    got = browser.evaluate(WAIT_CHIPS % 1)
    assert got["chips"] == 1 and got["uploading"] == 0 and got["status"] == "", got
    assert browser.evaluate(CHIPS_AFTER % 1500) == 1
    assert browser.evaluate("input.querySelectorAll('img:not(.cm-widgetBuffer)').length") == 0
    assert len(list(served["settings"].uploads_dir.iterdir())) == 1


# JS: a 3000 x 4000 opaque image (a smooth gradient with a little noise: a PNG of about 15 MB, the size a phone photo
# pasted from the clipboard gets) put on the clipboard as image/png; resolves to its byte size
BIG_ON_CLIPBOARD = """(async () => {
  const w = 3000, h = 4000, c = document.createElement("canvas"); c.width = w; c.height = h;
  const x = c.getContext("2d"), img = x.createImageData(w, h), d = img.data, noise = new Uint8Array(65536);
  crypto.getRandomValues(noise);
  for (let y = 0, i = 0; y < h; y++) for (let px = 0; px < w; px++, i += 4) {
    const n = noise[(i >> 2) & 65535];
    d[i] = ((px * 255 / w) + (n & 15)) & 255; d[i + 1] = ((y * 255 / h) + ((n >> 2) & 15)) & 255; d[i + 2] = (128 + ((n >> 4) & 15)) & 255; d[i + 3] = 255;
  }
  x.putImageData(img, 0, 0);
  const blob = await new Promise((r) => c.toBlob(r, "image/png"));
  await navigator.clipboard.write([new ClipboardItem({ "image/png": blob })]); return blob.size; })()"""

EVENTS = """(() => { const i = document.querySelector("#input"); window.__log = []; const t0 = performance.now();
  for (const t of ["paste", "beforeinput", "input"]) i.addEventListener(t, (e) => __log.push([Math.round(performance.now() - t0), t, e.inputType || "", e.defaultPrevented]), true);
  i.focus(); const s = getSelection(); s.selectAllChildren(i); s.collapseToEnd(); return document.activeElement.id; })()"""

# resolves once no chip is uploading and the chip count has been the same for `quiet` ms
SETTLE = """new Promise((res) => { const t0 = Date.now(); let last = -1, since = Date.now(); (function poll() {
  const n = document.querySelectorAll("#chips .chip").length, up = document.querySelectorAll("#chips .chip.uploading").length;
  if (n !== last) { last = n; since = Date.now(); }
  if ((!up && n >= 1 && Date.now() - since > %d) || Date.now() - t0 > 90000)
    res({ chips: n, uploading: up, names: state.uploads.map((u) => u.name), status: document.querySelector("#send-status").textContent, log: window.__log });
  else setTimeout(poll, 100); })(); })"""


def test_a_real_paste_of_a_big_image_makes_one_chip_and_goes_up_as_a_jpeg(served, browser):
    browser.call("Browser.grantPermissions", {"origin": served["url"], "permissions": ["clipboardReadWrite", "clipboardSanitizedWrite"]})
    browser.send("Emulation.setFocusEmulationEnabled", {"enabled": True})
    open_composer(browser, served)
    typed(browser, "keep ")
    size = browser.evaluate(BIG_ON_CLIPBOARD, timeout_ms=120000)
    assert size > 8 * 1024 * 1024, size  # a screenshot-sized image, not a small one
    assert browser.evaluate(EVENTS) == "input"
    key(browser, "v", "KeyV", 86, modifiers=2, commands=["Paste"])
    got = browser.evaluate(SETTLE % 2500, timeout_ms=120000)
    stored = sorted(served["settings"].uploads_dir.iterdir())
    detail = json.dumps({**got, "stored": [p.stat().st_size for p in stored]})
    assert got["chips"] == 1 and len(got["names"]) == 1 and len(stored) == 1, detail
    assert got["status"] == "", detail
    data = stored[0].read_bytes()
    assert stored[0].suffix == ".jpg" and data[:2] == b"\xff\xd8" and len(data) < size, detail  # a JPEG, smaller than the clipboard's PNG
    assert browser.evaluate(STATE)["text"] == "keep "
