"""A lone "~" in a reply is text; only "~~x~~" strikes.

The cause: the vendored marked 12.0.2 takes a single "~" for GFM strikethrough too (its `del` rule is
`^(~~?)...\\1`), so "10~19% ... 12k~46" in one paragraph struck out everything between the two tildes.
`noSingleTildeStrike` (shared.js, called by app.js) overrides marked's `del` tokenizer: a span that starts with "~~" is
left to marked's own rule, any other "~" is text. Held here:

- the cause, kept as a canary: marked alone still strikes between two lone tildes (if a later marked stops doing that, the
  override has become redundant and this test says so);
- with the override: "10~19% and 12k~46" has no `<del>` and both tildes are in the text; a lone tilde, a range, and
  "~/path" stay text;
- "~~x~~" still gives `<del>x</del>`, and the same html as marked alone inside a list, a table cell, bold and with bold
  inside it;
- a "~" inside an inline code span, a backtick fence and a tilde fence is untouched;
- the rendered page (headless Chromium when one is installed, conftest.py: `served`, `browser`, else skipped): the same
  three, in a real reply.
"""

from __future__ import annotations

import json
import shutil
import subprocess

import pytest

from conftest import NAME, transcript_file, transcript_line
from sala_web.app import STATIC

NODE = shutil.which("node")
SHARED = (STATIC / "shared.js").read_text()
MARKED = STATIC / "vendor" / "marked.min.js"

RANGE = "10~19% and 12k~46"
CODE = "Use `1~2 and 3~4` here.\n\n```\na~b and c~d\n```\n\n~~~\ne~f and g~h\n~~~"
STRIKE_SHAPES = [
    "~~x~~",
    "before ~~gone~~ after",
    "- ~~a~~ b\n- c",
    "| a | b |\n|---|---|\n| ~~x~~ | 1~2 |",
    "**~~x~~**",
    "~~a **b** c~~",
    "~~one~~ and 1~2 and ~~two~~",
]


def render(texts: list[str], patched: bool) -> list[str]:
    """The page's markdown path in node (marked with the options md() uses), with or without the override."""
    assert NODE, "node is not installed"
    setup = "noSingleTildeStrike(marked);" if patched else ""
    script = (f"const {{ marked }} = require({json.dumps(str(MARKED))});\n{SHARED}\n{setup}\n"
              f"console.log(JSON.stringify({json.dumps(texts)}.map((t) => marked.parse(t, {{ gfm: true, breaks: true }}))));")
    out = subprocess.run([NODE, "-e", script], capture_output=True, text=True, check=True, timeout=30).stdout
    return json.loads(out)


@pytest.mark.skipif(not NODE, reason="node is not installed")
def test_the_cause_marked_alone_strikes_between_two_lone_tildes():
    assert render([RANGE], patched=False) == ["<p>10<del>19% and 12k</del>46</p>\n"]


@pytest.mark.skipif(not NODE, reason="node is not installed")
def test_a_lone_tilde_is_text_and_nothing_is_struck():
    cases = [RANGE, "about ~5 minutes", "~/notes and ~/bin", "a ~ b ~ c", "~a~", "x ~~ y", "~~unclosed and 1~2"]
    for text, html in zip(cases, render(cases, patched=True)):
        assert "<del" not in html, (text, html)
    got = render([RANGE], patched=True)[0]
    assert got == "<p>10~19% and 12k~46</p>\n"


@pytest.mark.skipif(not NODE, reason="node is not installed")
def test_a_double_tilde_pair_still_strikes_exactly_as_before():
    assert render(["~~x~~"], patched=True) == ["<p><del>x</del></p>\n"]
    # the same html as marked alone in a list, a table cell, bold, nested bold, and two pairs around a lone tilde
    # (the last differs from marked alone only by the lone tilde: marked alone struck "~2 and ~" as a span)
    for text in STRIKE_SHAPES[:-1]:
        assert render([text], patched=True) == render([text], patched=False), text
    assert render([STRIKE_SHAPES[-1]], patched=True) == ["<p><del>one</del> and 1~2 and <del>two</del></p>\n"]


@pytest.mark.skipif(not NODE, reason="node is not installed")
def test_a_tilde_in_code_is_untouched():
    html = render([CODE], patched=True)[0]
    assert html == render([CODE], patched=False)[0]
    assert "<code>1~2 and 3~4</code>" in html and "a~b and c~d" in html and "e~f and g~h" in html and "<del" not in html


REPLY = f"{RANGE}\n\n~~x~~ done\n\n{CODE}"
TRANSCRIPT = (transcript_line("user", [{"type": "text", "text": "range"}], "l-1")
              + transcript_line("assistant", [{"type": "text", "text": REPLY}], "l-2", model="claude-opus-5-5"))

PROBE = r"""
new Promise((res) => { const t0 = Date.now(); (function poll() {
  const md = document.querySelector("#chat > .msg.assistant > .md");
  if (!md && Date.now() - t0 < 15000) return setTimeout(poll, 100);
  res({
    first: md.querySelector("p").textContent,
    dels: [...md.querySelectorAll("del")].map((d) => d.outerHTML),
    inline: md.querySelector("code").textContent,
    pres: [...md.querySelectorAll("pre")].map((p) => p.textContent.trim()) });
})(); })
"""


def test_the_page_shows_a_lone_tilde_and_strikes_only_a_pair(served, browser):
    transcript_file(served).write_text(TRANSCRIPT)
    browser.open(f"{served['url']}/#s={NAME}")
    got = browser.evaluate(PROBE)
    assert got["first"] == RANGE, got["first"]                  # both tildes visible, text between not struck
    assert got["dels"] == ["<del>x</del>"], got["dels"]         # the pair, and only it
    assert got["inline"] == "1~2 and 3~4"                       # a code span, a backtick fence and a tilde fence untouched
    assert got["pres"] == ["a~b and c~d", "e~f and g~h"]
