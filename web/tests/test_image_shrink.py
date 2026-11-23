"""An image the page attaches always reaches the session, whatever its size.

The page redraws an image that is over the server's limit (20 MB) or longer than 4000 px on its long side, on a canvas, and
sends that instead: a JPEG, or a PNG when a pixel is see-through. A small image goes up untouched. A shrink that cannot
fit says so in words, and a file that is empty says "came through empty" after one more read.

These run in a headless Chromium (conftest.py: `served`, `browser`) and are skipped without one. The images are made in the
page; the biggest is 5000 x 2500 and a smooth gradient, so it costs a few hundred KB. The byte limit is lowered in the page
(`MAX_IMAGE_BYTES`) to test the size steps, instead of building a file of 20 MB.
"""

from __future__ import annotations

import json
import struct

from conftest import CHAT_READY, NAME

# JS: an image of w x h in the page. kind: "gradient" (opaque), "alpha" (a see-through background with one opaque box), "noise"
# (random pixels, which no encoder makes small); returns a File of the given mime.
MAKE = """
async function makeImage(w, h, kind, mime, name) {
  const c = document.createElement("canvas"); c.width = w; c.height = h;
  const x = c.getContext("2d");
  if (kind === "noise") {
    const img = x.createImageData(w, h), buf = new Uint8Array(img.data.buffer);
    for (let i = 0; i < buf.length; i += 65536) crypto.getRandomValues(buf.subarray(i, Math.min(i + 65536, buf.length)));
    for (let i = 3; i < buf.length; i += 4) buf[i] = 255;
    x.putImageData(img, 0, 0);
  } else if (kind === "alpha") {
    x.fillStyle = "rgb(200, 30, 30)"; x.fillRect(Math.floor(w / 4), Math.floor(h / 4), Math.floor(w / 2), Math.floor(h / 2));
  } else {
    const g = x.createLinearGradient(0, 0, w, h); g.addColorStop(0, "#123"); g.addColorStop(1, "#fa0");
    x.fillStyle = g; x.fillRect(0, 0, w, h);
  }
  const blob = await new Promise((res) => c.toBlob(res, mime));
  return new File([blob], name, { type: mime });
}
"""

# JS: hand a File to the page the way the attach button does, then wait until the upload is over (a chip, or a status line)
FEED = """
async function feed(file) {
  const dt = new DataTransfer(); dt.items.add(file);
  const fi = document.querySelector("#file-input"); fi.files = dt.files;
  fi.dispatchEvent(new Event("change", { bubbles: true }));
  const t0 = Date.now();
  while (Date.now() - t0 < 20000) {
    await new Promise((r) => setTimeout(r, 100));
    if (!document.querySelector("#chips .chip.uploading") && (document.querySelectorAll("#chips .chip").length || document.querySelector("#send-status").textContent)) break;
  }
  return { chips: document.querySelectorAll("#chips .chip").length, names: state.uploads.map((u) => u.name),
           status: document.querySelector("#send-status").textContent };
}
"""


def sof(jpeg: bytes) -> tuple[int, int]:
    """(width, height) of a baseline or progressive JPEG, from its start-of-frame marker."""
    assert jpeg[:2] == b"\xff\xd8", "not a JPEG"
    i = 2
    while i < len(jpeg):
        assert jpeg[i] == 0xFF
        marker = jpeg[i + 1]
        (length,) = struct.unpack(">H", jpeg[i + 2:i + 4])
        if marker in (0xC0, 0xC1, 0xC2):
            h, w = struct.unpack(">HH", jpeg[i + 5:i + 9])
            return w, h
        i += 2 + length
    raise AssertionError("no frame header")


def ihdr(png: bytes) -> tuple[int, int, int]:
    """(width, height, colour type) of a PNG; colour type 6 is RGBA."""
    assert png[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    w, h = struct.unpack(">II", png[16:24])
    return w, h, png[25]


def start(served, browser):
    browser.open(f"{served['url']}/#s={NAME}")
    browser.wait_ready(CHAT_READY)
    browser.evaluate(MAKE + FEED + "true")


def stored(served) -> list:
    d = served["settings"].uploads_dir
    return sorted(d.iterdir()) if d.is_dir() else []


def test_an_image_longer_than_4000_px_goes_up_as_a_jpeg_of_at_most_4000_px(served, browser):
    start(served, browser)
    got = browser.evaluate("""(async () => {
      const f = await makeImage(5000, 2500, "gradient", "image/png", "wide.png");
      const r = await feed(f); r.sourceBytes = f.size; return r; })()""")
    assert got["chips"] == 1 and got["status"] == "", got
    (path,) = stored(served)
    assert path.suffix == ".jpg"
    assert sof(path.read_bytes()) == (4000, 2000)  # the long side is 4000, the proportions are kept


def test_a_see_through_image_stays_a_png_so_its_alpha_survives(served, browser):
    start(served, browser)
    got = browser.evaluate("""(async () => feed(await makeImage(4500, 1000, "alpha", "image/png", "cutout.png")))()""")
    assert got["chips"] == 1 and got["status"] == "", got
    (path,) = stored(served)
    assert path.suffix == ".png"
    assert ihdr(path.read_bytes()) == (4000, 889, 6)  # 1000 * 4000 / 4500, with an alpha channel


def test_a_small_image_goes_up_untouched(served, browser):
    start(served, browser)
    got = browser.evaluate("""(async () => {
      const f = await makeImage(200, 100, "gradient", "image/png", "small.png");
      const r = await feed(f);
      const b = new Uint8Array(await f.arrayBuffer()); let s = ""; for (const v of b) s += String.fromCharCode(v);
      r.b64 = btoa(s); return r; })()""")
    assert got["chips"] == 1 and got["status"] == "", got
    import base64
    (path,) = stored(served)
    assert path.suffix == ".png" and path.read_bytes() == base64.b64decode(got["b64"])


def test_an_image_over_the_byte_limit_steps_its_quality_and_size_down_until_it_fits(served, browser):
    start(served, browser)
    # 1200 x 800 of noise is about 3 MB as a PNG and far over 150 KB as a JPEG at any quality: the size has to come down too
    got = browser.evaluate("""(async () => {
      MAX_IMAGE_BYTES = 150 * 1024;
      const f = await makeImage(1200, 800, "noise", "image/png", "noise.png");
      const r = await feed(f); r.sourceBytes = f.size; return r; })()""")
    assert got["chips"] == 1 and got["status"] == "", got
    assert got["sourceBytes"] > 150 * 1024, got
    (path,) = stored(served)
    data = path.read_bytes()
    assert path.suffix == ".jpg" and len(data) <= 150 * 1024
    w, h = sof(data)
    assert w < 1200 and abs(w / h - 1.5) < 0.02  # smaller, the same shape


def test_an_image_that_cannot_be_made_to_fit_says_so_and_sends_nothing(served, browser):
    start(served, browser)
    got = browser.evaluate("""(async () => {
      MAX_IMAGE_BYTES = 2000;
      return feed(await makeImage(600, 400, "noise", "image/png", "noise.png")); })()""")
    assert got["chips"] == 0 and got["names"] == [], got
    assert "could not be made small enough to attach" in got["status"] and "limit" in got["status"], got
    assert stored(served) == []


def test_an_image_with_no_bytes_says_it_came_through_empty(served, browser):
    start(served, browser)
    got = browser.evaluate("""(async () => feed(new File([], "gone.png", { type: "image/png" })))()""")
    assert got["chips"] == 0, got
    assert got["status"] == "Image upload failed: That image came through empty. Try attaching it again.", got
    assert stored(served) == []


def test_a_file_whose_first_read_is_empty_is_read_once_more_and_goes_up(served, browser):
    start(served, browser)
    got = browser.evaluate("""(async () => {
      const f = await makeImage(120, 80, "gradient", "image/png", "late.png");
      const real = f.arrayBuffer.bind(f); let reads = 0;
      f.arrayBuffer = () => (reads++ === 0 ? Promise.resolve(new ArrayBuffer(0)) : real());
      const r = await feed(f); r.reads = reads; return r; })()""")
    assert got["chips"] == 1 and got["status"] == "", got
    assert got["reads"] == 2, got  # the empty read, then the one that worked: no more
    (path,) = stored(served)
    assert ihdr(path.read_bytes())[:2] == (120, 80)
