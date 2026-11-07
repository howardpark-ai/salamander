"""Numbered lists in a reply render as lists (a reply's numbered items showed as paragraph text).

The cause, found by running the vendored marked 12.0.2 with the page's options (gfm, breaks) in node: CommonMark lets a
list interrupt a paragraph only when it starts at "1.", so "Next steps:\\n6. x\\n7. y" is one paragraph (the items shown
as lines, flush left), while the items after a blank line are a real, indented list; a reply with item 6 under prose and
items 7 to 10 after a blank line showed 6 flush left and 7 to 10 indented. `mdPrep` (shared.js) puts a blank line before
such an item. Held here:

- the cause, kept as a canary: marked alone, given a numbered run under a prose line, still makes a paragraph (if a
  later marked starts a list there, `mdPrep` has become redundant and this test says so);
- `mdPrep` in node, with marked: a run starting above 1 under prose, a continued run (11 to 13 under a line after a list),
  a run under a bold heading line, ")" items, all become lists with the right start; and what must NOT change: a list
  starting at 1, a list with blank lines between items or with indented sub-bullets, items inside a code fence (and after
  one), dates at a line's start ("2026. 10. 16.", "16. 10. 2026."), a lone number with no neighbour in the reply, a number
  mid-sentence ("v2. Next"), an indented continuation, text without a numbered line (returned as it is, the same string);
- a line directly after a bullet stays a lazy continuation of that bullet (CommonMark; the choice is recorded here);
- the rendered page (headless Chromium when one is installed, conftest.py: `served`, `browser`, else skipped): the
  screenshot's shape renders as lists, one `<ol>` per run with `start` set, nothing left as paragraph text, the item
  marks indented the same, a code fence's numbers untouched.
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


def run_node(script: str) -> str:
    assert NODE, "node is not installed"
    return subprocess.run([NODE, "-e", script], capture_output=True, text=True, check=True, timeout=30).stdout


def render(texts: list[str], prep: bool = True) -> list[str]:
    """The page's markdown path, in node: mdPrep (or the text itself) into marked with the options md() uses."""
    fn = "mdPrep" if prep else "(t) => t"
    script = (f"const {{ marked }} = require({json.dumps(str(MARKED))});\n{SHARED}\n"
              f"console.log(JSON.stringify({json.dumps(texts)}.map((t) => marked.parse(({fn})(t), {{ gfm: true, breaks: true }}))));")
    return json.loads(run_node(script))


def prep(texts: list[str]) -> list[str]:
    return json.loads(run_node(SHARED + f"\nconsole.log(JSON.stringify({json.dumps(texts)}.map(mdPrep)));"))


# the screenshot's shape: item 6 right under prose, a blank line, 7 to 10 a list, prose, 11 to 13 right under it
SHOT = ("Plan for the picnic:\n6. Tiles\n\n7. Paint\n8. Floor\n9. Doors\n10. Lights\n\nThen the rest:\n11. Move in\n12. Clean\n13. Done")
PROSE_RUN = "Next steps:\n6. x\n7. y\n8. z"
BOLD_RUN = "**Steps**\n2. a\n3. b\n4. c"
PAREN = "Pick:\n2) a\n3) b"


@pytest.mark.skipif(not NODE, reason="node is not installed")
def test_the_cause_marked_alone_makes_a_paragraph_of_a_run_that_does_not_start_at_one():
    html = render([PROSE_RUN, SHOT], prep=False)
    assert "<ol" not in html[0] and html[0] == "<p>Next steps:<br>6. x<br>7. y<br>8. z</p>\n"
    # the screenshot: 6 and 11 to 13 are paragraph text, 7 to 10 the only list
    assert html[1].count("<ol") == 1 and '<ol start="7">' in html[1] and "<p>Plan for the picnic:<br>6. Tiles</p>" in html[1]
    assert "<p>Then the rest:<br>11. Move in<br>12. Clean<br>13. Done</p>" in html[1]


@pytest.mark.skipif(not NODE, reason="node is not installed")
def test_a_numbered_run_under_prose_becomes_a_list():
    html = render([PROSE_RUN, SHOT, BOLD_RUN, PAREN])
    assert html[0] == '<p>Next steps:</p>\n<ol start="6">\n<li>x</li>\n<li>y</li>\n<li>z</li>\n</ol>\n'
    # item 6 now opens the list that 7 to 10 continue (a blank line between items only loosens it), 11 to 13 a second one
    assert html[1].count("<ol") == 2 and "<br>6." not in html[1] and "<br>11." not in html[1]
    assert html[1].count('<ol start="6">') == 1 and html[1].count('<ol start="11">') == 1 and "<li><p>Lights</p>" in html[1]
    assert html[2] == '<p><strong>Steps</strong></p>\n<ol start="2">\n<li>a</li>\n<li>b</li>\n<li>c</li>\n</ol>\n'
    assert html[3] == '<p>Pick:</p>\n<ol start="2">\n<li>a</li>\n<li>b</li>\n</ol>\n'


@pytest.mark.skipif(not NODE, reason="node is not installed")
def test_standard_markdown_is_left_as_it_is():
    cases = [
        "1. one\n2. two\n3. three",                                  # starts at 1
        "Steps:\n1. one\n2. two",                                     # 1 already interrupts a paragraph
        "1. one\n\n2. two\n\n3. three",                               # loose list
        "1. one\n   - sub\n   - sub2\n2. two\n3. three",              # sub-bullets
        "1. one\n2. two\ntext\n3. three",                             # a lazy continuation inside an item
        "- bullet\nplain line after",                                 # a line after a bullet
        "- a\n6. x\n7. y",                                            # the line above is a list item
        "5. a\n   more\n6. b",                                        # an indented continuation above
        "intro\n2026. 10. 16. was the day",                           # a date at a line's start
        "intro\n16. 10. 2026. was the day\n17. 10. 2026. next",       # a day-first date, even in a run
        "intro\n16. 2026 meeting",                                    # a lone number: no neighbour in the reply
        "We shipped v2. Next we test 3. Then 4.",                     # numbers mid-sentence
        "```\nintro\n6. x\n7. y\n```",                                # inside a code fence
        "~~~sh\nintro\n6. x\n7. y\n~~~\n6. after",                    # a tilde fence; the line after it
        "Fence:\n```\ncode\n```\n3. a\n4. b",                         # directly after a closing fence (already a list)
        "plain text, no list",
        "",
        "7.5 is a number, not 7. a list",
        "intro\n6.x\n7.y",                                            # no space after the dot: not an item
    ]
    for text, got, want in zip(cases, prep(cases), cases):
        assert got == want, (text, got)  # the string is unchanged, so the html is too


@pytest.mark.skipif(not NODE, reason="node is not installed")
def test_a_line_after_a_bullet_stays_part_of_it():
    # CommonMark's lazy continuation, as claude.ai shows it with a line break; not changed (no way to tell a
    # new paragraph from a wrapped line without a blank line, and a wrong guess would split a bullet that wraps)
    assert render(["- bullet\nplain line after"])[0] == "<ul>\n<li>bullet<br>plain line after</li>\n</ul>\n"


@pytest.mark.skipif(not NODE, reason="node is not installed")
def test_a_prepared_run_keeps_its_fence_and_its_neighbours():
    text = "Intro:\n```\nsala ls\n6. not an item\n7. nor this\n```\nNext:\n3. a\n4. b\n\nAfter:\n- x\n5. y"
    got = prep([text])[0]
    # the run 3 and 4 gets its blank line; the fenced numbers and the line under a bullet do not
    assert got == "Intro:\n```\nsala ls\n6. not an item\n7. nor this\n```\nNext:\n\n3. a\n4. b\n\nAfter:\n- x\n5. y"
    html = render([text])[0]
    assert html.count("<ol") == 2 and "6. not an item\n7. nor this" in html


REPLY = SHOT + "\n\n```\nintro\n6. in a fence\n7. still\n```\n\nSteps:\n2. a\n3. b"
TRANSCRIPT = (transcript_line("user", [{"type": "text", "text": "plan"}], "l-1")
              + transcript_line("assistant", [{"type": "text", "text": REPLY}], "l-2", model="claude-opus-5-5"))

PROBE = r"""
new Promise((res) => { const t0 = Date.now(); (function poll() {
  const md = document.querySelector("#chat > .msg.assistant > .md");
  if (!md && Date.now() - t0 < 15000) return setTimeout(poll, 100);
  res({
    ols: [...md.querySelectorAll(":scope > ol")].map((ol) => ({ start: ol.getAttribute("start"), items: [...ol.children].map((li) => li.textContent.trim()),
        left: ol.getBoundingClientRect().left, itemLeft: ol.firstElementChild.getBoundingClientRect().left, pad: parseFloat(getComputedStyle(ol).paddingLeft) })),
    paras: [...md.querySelectorAll(":scope > p")].map((p) => p.innerHTML),
    code: md.querySelector("pre").textContent,
    left: md.getBoundingClientRect().left });
})(); })
"""


def test_the_page_renders_the_screenshots_shape_as_lists(served, browser):
    transcript_file(served).write_text(TRANSCRIPT)
    browser.open(f"{served['url']}/#s={NAME}")
    got = browser.evaluate(PROBE)
    assert got["paras"] == ["Plan for the picnic:", "Then the rest:", "Steps:"], got["paras"]  # no number left in paragraph text
    assert [(o["start"], o["items"]) for o in got["ols"]] == [
        ("6", ["Tiles", "Paint", "Floor", "Doors", "Lights"]), ("11", ["Move in", "Clean", "Done"]), ("2", ["a", "b"])]
    # every list is indented the same, so no run looks flush left against another
    assert len({(o["left"], o["itemLeft"], o["pad"]) for o in got["ols"]}) == 1 and got["ols"][0]["pad"] > 0
    assert got["code"].strip().splitlines() == ["intro", "6. in a fence", "7. still"]
