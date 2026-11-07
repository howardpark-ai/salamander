"""A fenced code block wraps on screen instead of scrolling sideways, and copies without the wrap (sideways scrolling is difficult to read,
and a pasted copy should be clean).

Rendered from a fake transcript at a desktop and a phone width in a headless Chromium when one is installed (conftest.py:
`served`, `browser`), else skipped. A block holding a 300-character token, one holding a long URL line and one holding a
long command line each fit their box (no sideways scroll) and take more than one screen line; a block of three short lines
keeps exactly its three lines; the copy button hands the clipboard the source text itself, with no newline added (the wrap is
CSS only), and so does a hand selection of the block; the button stays inside the block's top-right corner.
"""

from __future__ import annotations

import json

import pytest

from conftest import NAME, transcript_line, transcript_file

TOKEN = "T" * 300
URL = "https://board.example.test/items/137?view=waiting-on-you&from=demo-maintainer&anchor=" + "f" * 120
CMD = "curl -sS '" + URL + "' -H 'Authorization: Bearer " + "x" * 80 + "' -o out.json && echo done"
SHORT = "first line\nsecond line\nthird line"
SOURCES = [TOKEN, URL, CMD, SHORT]  # the blocks in order
REPLY = "Here they are.\n\n" + "\n\n".join(f"```\n{s}\n```" for s in SOURCES) + "\n"
TRANSCRIPT = (transcript_line("user", [{"type": "text", "text": "show me code"}], "w-1")
              + transcript_line("assistant", [{"type": "text", "text": REPLY}], "w-2", model="claude-opus-5-5"))

WAIT = """
new Promise((res) => { const t0 = Date.now(); (function poll() {
  const n = document.querySelectorAll("#chat .codebox").length;
  if (n >= 4 || Date.now() - t0 > 15000) res(n); else setTimeout(poll, 100);
})(); })
"""

MEASURE = r"""
(() => [...document.querySelectorAll("#chat .codebox")].map((box) => {
  const pre = box.querySelector("pre"), b = box.querySelector(".code-copy"), cs = getComputedStyle(pre);
  const pr = pre.getBoundingClientRect(), br = b.getBoundingClientRect(), lh = parseFloat(cs.lineHeight);
  const vpad = parseFloat(cs.paddingTop) + parseFloat(cs.paddingBottom);
  return { ws: cs.whiteSpace, wrap: cs.overflowWrap, scrollW: pre.scrollWidth, clientW: pre.clientWidth,
           lines: Math.round((pre.clientHeight - vpad) / lh), inside: br.top >= pr.top && br.right <= pr.right && br.left >= pr.left,
           docScroll: document.documentElement.scrollWidth, innerW: innerWidth };
}))()
"""

# what a click on each block's button hands the clipboard (both paths copyText takes are caught), and what selecting the
# block's text by hand gives
COPIED = r"""
new Promise((res) => {
  const got = [];
  try { navigator.clipboard.writeText = (t) => { got.push(t); return Promise.resolve(); }; } catch (e) {}
  if (!navigator.clipboard) Object.defineProperty(navigator, "clipboard", { value: { writeText: (t) => { got.push(t); return Promise.resolve(); } }, configurable: true });
  document.execCommand = () => { got.push(document.activeElement.value); return true; };
  const bs = [...document.querySelectorAll("#chat .code-copy")];
  bs.forEach((b) => b.click());
  (function poll() {
    if (!bs.every((b) => b.classList.contains("done"))) return setTimeout(poll, 20);
    const picked = [...document.querySelectorAll("#chat .codebox pre")].map((pre) => {
      const r = document.createRange(); r.selectNodeContents(pre.querySelector("code") || pre);
      const s = getSelection(); s.removeAllRanges(); s.addRange(r); const t = s.toString(); s.removeAllRanges(); return t;
    });
    res({ got, picked });
  })();
})
"""


@pytest.mark.parametrize("width,height,mobile", [(1280, 800, False), (390, 844, True)])
def test_code_block_wraps_on_screen_and_copies_raw(served, browser, width, height, mobile):
    transcript_file(served).write_text(TRANSCRIPT)
    browser.open(f"{served['url']}/#s={NAME}")
    browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": height, "deviceScaleFactor": 1,
                                                        "mobile": mobile})
    assert browser.evaluate(WAIT) == 4
    got = browser.evaluate(MEASURE)
    assert len(got) == 4, got
    for src, g in zip(SOURCES, got):
        where = f"{src[:30]!r} at {width}px: {json.dumps(g)}"
        assert g["ws"] == "pre-wrap" and g["wrap"] == "anywhere", where
        assert g["scrollW"] <= g["clientW"], where  # no sideways scroll inside the block
        assert g["docScroll"] <= g["innerW"], where
        assert g["inside"], where  # the copy button sits inside the block
    # a long line takes more than one screen line; real newlines keep their own lines, no more
    assert all(g["lines"] > 1 for g in got[:3]), got
    assert got[3]["lines"] == 3, got[3]
    # the button copies the source itself, no line break added by the wrap; a selection by hand gives the same text
    out = browser.evaluate(COPIED)
    assert out["got"] == SOURCES, out
    assert all("\n" not in t for t in out["got"][:3]), out
    assert [p.rstrip("\n") for p in out["picked"]] == SOURCES, out
