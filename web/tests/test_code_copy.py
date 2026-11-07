"""The copy button on a code block sits evenly in its corner (on desktop Chrome it was a bit misaligned, too close to
the top).

On a one-line block the button is centred on the line; on a taller block it stays in the top-right corner with the same
inset from the top and from the right (the one-line centring inset, so both cases agree). Pressing it ("Copied", or
"Copy failed" where the clipboard is refused) changes neither its height nor its corner. Inline code gets no button. Rendered from a fake transcript at a desktop and a phone width in a headless Chromium when one is installed
(conftest.py: `served`, `browser`), else skipped.
"""

from __future__ import annotations

import json

import pytest

from conftest import NAME, transcript_line, transcript_file

LONG = "curl -sS 'https://board.example.test/items/137?view=waiting-on-you&anchor=" + "f" * 160 + "' -o out.json"
REPLY = (
    "Inline `code` and `sala ls` in a sentence.\n\n"
    "```sh\nsala ls\n```\n\n"
    "```\nfirst line\nsecond line\nthird line\n```\n\n"
    "```\n" + "\n".join(f"line {i}" for i in range(1, 21)) + "\n```\n\n"
    "```sh\n" + LONG + "\n```\n"
)
TRANSCRIPT = (transcript_line("user", [{"type": "text", "text": "show me code"}], "c-1")
              + transcript_line("assistant", [{"type": "text", "text": REPLY}], "c-2", model="claude-opus-5-5"))
LINES = [1, 3, 20, 0]  # the blocks in order: a short one-line block, three lines, twenty lines, one long line (0: it wraps onto several screen lines, so it is a taller block)

WAIT = """
new Promise((res) => { const t0 = Date.now(); (function poll() {
  const n = document.querySelectorAll("#chat .codebox").length;
  if (n >= 4 || Date.now() - t0 > 15000) res(n); else setTimeout(poll, 100);
})(); })
"""

# The page is not still when the four blocks first exist: the fonts finish loading (a pixel of shift) and the chat then pins
# itself to the bottom a few frames later (the first block's button moves tens of pixels up the viewport), a little later on a slow
# runner. So the geometry is read once the web fonts are loaded and the viewport position of every block and button has been the
# same for 150 ms of consecutive frames, never on a fixed delay.
SETTLE = r"""
document.fonts.ready.then(() => new Promise((res) => {
  const t0 = performance.now(); let prev = null, since = t0;
  (function frame() {
    const now = performance.now();
    const cur = JSON.stringify([...document.querySelectorAll("#chat .codebox")].map((box) => {
      const r = box.querySelector("pre").getBoundingClientRect(), b = box.querySelector(".code-copy").getBoundingClientRect();
      return [r.top, r.height, r.right, b.top, b.right];
    }));
    if (cur !== prev) { prev = cur; since = now; }
    if (now - since >= 150 || now - t0 > 15000) res(now - since >= 150);
    else requestAnimationFrame(frame);
  })();
}))
"""

# each code block's box (the area inside its borders, without a horizontal scrollbar) and its button
MEASURE = r"""
(() => {
  const r2 = (r) => ({ top: r.top, bottom: r.bottom, left: r.left, right: r.right, height: r.height, width: r.width });
  return [...document.querySelectorAll("#chat .codebox")].map((box) => {
    const pre = box.querySelector("pre"), b = box.querySelector(".code-copy"), pr = pre.getBoundingClientRect();
    // clientHeight/clientWidth are whole pixels; the scrollbars' sizes are taken off the exact box instead
    const sbH = pre.offsetHeight - pre.clientHeight - 2 * pre.clientTop, sbW = pre.offsetWidth - pre.clientWidth - 2 * pre.clientLeft;
    const inner = { top: pr.top + pre.clientTop, left: pr.left + pre.clientLeft, height: pr.height - 2 * pre.clientTop - sbH,
                    right: pr.right - pre.clientLeft - sbW };
    return { pre: r2(pr), inner, btn: r2(b.getBoundingClientRect()), scrolls: pre.scrollWidth > pre.clientWidth };
  });
})()
"""

PRESS = r"""
new Promise((res) => {
  const bs = [...document.querySelectorAll("#chat .code-copy")];
  bs.forEach((b) => b.click());
  (function poll() {
    if (bs.every((b) => b.classList.contains("done")))
      // the corner is read from the block's own box, so a scroll of the chat between the two readings cannot move it
      res(bs.map((b) => { const r = b.getBoundingClientRect(), pr = b.closest(".codebox").querySelector("pre").getBoundingClientRect();
                          return { top: r.top - pr.top, right: pr.right - r.right, height: r.height, label: b.textContent }; }));
    else setTimeout(poll, 20);
  })();
})
"""

INLINE = r"""
(() => ({ inline: [...document.querySelectorAll("#chat .md code")].filter((c) => !c.closest("pre")).length,
          buttons: document.querySelectorAll("#chat .code-copy").length,
          boxes: document.querySelectorAll("#chat .codebox").length }))()
"""


@pytest.mark.parametrize("width,height,mobile", [(1280, 800, False), (390, 844, True)])
def test_code_copy_button_sits_evenly_in_its_corner(served, browser, width, height, mobile):
    transcript_file(served).write_text(TRANSCRIPT)
    browser.open(f"{served['url']}/#s={NAME}")
    browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": height, "deviceScaleFactor": 1,
                                                        "mobile": mobile})
    assert browser.evaluate(WAIT) == 4
    assert browser.evaluate(SETTLE), "the page did not settle (fonts, scroll position) within 15 seconds"
    got = browser.evaluate(MEASURE)
    assert len(got) == 4, got
    one_line_inset = None
    for lines, g in zip(LINES, got):
        inner, btn = g["inner"], g["btn"]
        top, right = btn["top"] - inner["top"], inner["right"] - btn["right"]
        where = f"{lines}-line block at {width}px: {json.dumps(g)}"
        assert 4 <= top <= 12 and 4 <= right <= 12, where
        if lines == 1:
            # centred on the line: the same space above and below the button inside the block
            below = inner["top"] + inner["height"] - btn["bottom"]
            assert abs(top - below) <= 0.5, where
            one_line_inset = top if one_line_inset is None else one_line_inset
        # the same inset from the top as from the right, on every block
        assert abs(top - right) <= 0.5, where
    assert not got[3]["scrolls"], "the long line wraps inside its block, it does not scroll"
    # every block has the one-line block's inset
    assert all(abs(g["btn"]["top"] - g["inner"]["top"] - one_line_inset) <= 0.5 for g in got), got
    # pressed: neither the height nor the corner moves
    pressed = browser.evaluate(PRESS)
    for g, p in zip(got, pressed):
        assert p["label"] in ("Copied", "Copy failed"), p
        assert abs(p["height"] - g["btn"]["height"]) <= 0.5, (g, p)
        assert abs(p["top"] - (g["btn"]["top"] - g["pre"]["top"])) <= 0.5, (g, p)
        assert abs(p["right"] - (g["pre"]["right"] - g["btn"]["right"])) <= 0.5, (g, p)
    # inline code is not a block: no button of its own
    inl = browser.evaluate(INLINE)
    assert inl == {"inline": 2, "buttons": 4, "boxes": 4}, inl
