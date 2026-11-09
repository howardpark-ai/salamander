"""A reply's footer apart from its body.

The notes a session leaves at the very end of a reply under the standing rules ("Write-up: …", "Board …",
"Page …", each with its "- " bullets) render smaller and dimmed under a thin rule, each note a block of its own, so four
"Page …:" notes no longer run into one paragraph (a long reply). Held here: the splitting rule
(`splitFooter` in shared.js, run in node and in the page: which trailing run is a footer, which stays body); the footer's
size against the body's, its colour (the --muted token, AA contrast in both themes), the rule above it and none when the
footer is the whole reply, one block per note, its links still anchors in the accent (a link on one line has an invisible
`::after` box 3px above and below its text, a tap target no smaller than a body link's; a link that wraps has none,
`.wrapped` from markWrappedLinks in app.js, and its own text is the target; no vertical padding on an inline box, which put
a link's text off the footer text's row at fractional browser zoom; pinned at 100%, 110%, 125% and 150%), a long URL
wrapping with no sideways scroll at 320, 390 and 1280 px; a reply without a footer rendering exactly as md() alone renders it, and a footer-looking line in the middle of a reply staying body; copying a reply
copying its text unchanged, a code block's copy button staying with the body; the same split on the stream's append.
The closing paragraph a session puts after its footer (the ask the rulebook puts last; such replies showed with the
old unstyled footer) renders as body text under the dimmed footer, in that order, and a bold note lead
(`**Write-up:**`, `**Board:**`) counts as the plain one; two paragraphs after a run keep the reply as it was. The page
runs in a headless Chromium when one is installed (conftest.py: `served`, `browser`), else skipped; the rule's cases run
in node like linkTokens's (test_chat_links.py).
"""

from __future__ import annotations

import json
import shutil
import subprocess
import time

import pytest

from conftest import ASSISTANT_MD, NAME, transcript_file, transcript_line
from sala_web.app import STATIC

NODE = shutil.which("node")
SHARED = (STATIC / "shared.js").read_text()
WEB = "https://board.example.test"
LONG_URL = "https://github.com/example-org/notes-repo/blob/main/projects/sala.md#" + "a-long-anchor-" * 16

WRITEUP = "Done. The PR is merged and deployed.\n\nWrite-up: none, the PR body holds the record."
BLOCK = ("Merged #107 and deployed.\n\n"
         f"Board:\n- [board#26]({WEB}/items/26): the footer, in review\n- [board#88]({WEB}/items/88): no change\n\n"
         "Page projects/sala: timeline line added.\n\nWrite-up: none, the PR body holds the record.")
ONE_LINE = "Deployed.\nBoard board#26: no change, the item is the PR's."
LISTED = f"Deployed.\n\nBoard:\n- [board#26]({WEB}/items/26): no change\n- board#88: no change\nPage: no change, timeline line only."
PAGES = ("Four pages touched.\n\nPage: done. The Current state was rewritten.\nPage projects/stackshot: timeline line added.\n"
         f"Page projects/sala: no change.\nPage projects/box-a: `MACHINE_SPEC` row updated, see [the page]({LONG_URL}).")
# a note followed by two paragraphs: body (one paragraph would be the closing ask, ASK below)
MIDDLE = "Write-up: none, nothing new here.\n\nBut one more thing: the deploy is still running.\n\nI will report when it ends."
WHOLE = "Board board#26: no change, the item is the PR's.\nWrite-up: none."
CODE = "Run it:\n\n```sh\nsala ls\n```\n\nWrite-up: none."
# a footer followed by the closing ask (the two shapes that showed unstyled): plain leads, and bold leads with a list
ASK = ("Both items are stale.\n\nBoard board#23: stale, both.\n"
       "Page: [projects/demo/guide](https://github.com/example-org/notes-repo/blob/main/projects/demo/guide.md) updated.\n\n"
       f"Drop both items? Answer yes or no on [board#23]({WEB}/items/23), or here.")
BOLD_ASK = (f"Done.\n\n**Board:**\n- [board#27]({WEB}/items/27): proposed\n\n**Write-up**: none, the proposal is on the item.\n\n"
            f"To decide, pick **Proposed form** or **Front only first** on [board#27]({WEB}/items/27), or tell me what to change.")
TWO_TAIL = "Done.\n\nWrite-up: none.\n\nFirst closing paragraph.\n\nSecond closing paragraph."
# footer links that wrap in a narrow column (the zoom test opens it at 320 px): a link text of many words, and a slug with no
# space in it, each in a note of its own
WRAP = (f"Done.\n\nPage projects/sala: updated, see [the page holding the long write-up of this change and what it did to the footer links]({WEB}/p/1) now."
        f"\nWrite-up: none.")
SLUG = ("Done.\n\nPage: [projects/box-a/machine-spec-inventory-and-the-long-slug-of-a-page-name-that-must-break-anywhere]"
        f"({WEB}/p/2)\nWrite-up: none.")
# in chat order; the uuid names the case in the probe's answer
CASES = {"writeup": WRITEUP, "block": BLOCK, "oneline": ONE_LINE, "listed": LISTED, "pages": PAGES, "middle": MIDDLE,
         "none": ASSISTANT_MD, "whole": WHOLE, "code": CODE, "ask": ASK, "boldask": BOLD_ASK, "twotail": TWO_TAIL,
         "wrap": WRAP, "slug": SLUG}
TRANSCRIPT = transcript_line("user", [{"type": "text", "text": "report"}], "f-u") + "".join(
    transcript_line("assistant", [{"type": "text", "text": t}], f"f-{k}", model="claude-opus-5-5") for k, t in CASES.items())


def run_node(script: str) -> str:
    assert NODE, "node is not installed"
    return subprocess.run([NODE, "-e", script], capture_output=True, text=True, check=True, timeout=30).stdout


def split(texts: list[str]) -> list[dict]:
    return json.loads(run_node(SHARED + f"\nconsole.log(JSON.stringify({json.dumps(texts)}.map(splitFooter)));"))


@pytest.mark.skipif(not NODE, reason="node is not installed")
def test_the_rule_splits_a_trailing_run_of_notes_and_nothing_else():
    got = dict(zip(CASES, split(list(CASES.values()))))
    # a Write-up line after a blank line; a Board line right after prose (a strong note needs no blank line)
    assert got["writeup"] == {"body": "Done. The PR is merged and deployed.", "footer": "Write-up: none, the PR body holds the record.",
                              "notes": ["Write-up: none, the PR body holds the record."], "tail": ""}
    assert got["oneline"] == {"body": "Deployed.", "footer": "Board board#26: no change, the item is the PR's.",
                              "notes": ["Board board#26: no change, the item is the PR's."], "tail": ""}
    # Board with its bullets, then Page, then Write-up: one footer, three notes, the bullets with their Board line
    b = got["block"]
    assert b["body"] == "Merged #107 and deployed." and b["footer"] == BLOCK[len(b["body"]) + 2:] and b["tail"] == ""
    assert [n.split("\n")[0] for n in b["notes"]] == ["Board:", "Page projects/sala: timeline line added.",
                                                      "Write-up: none, the PR body holds the record."]
    assert b["notes"][0].count("\n- ") == 2
    # a Board note with its bullets, then a Page line: two notes, the Page line a note of its own in the footer
    k = got["listed"]
    assert k["body"] == "Deployed." and len(k["notes"]) == 2 and k["notes"][0].startswith("Board:\n- ") and k["notes"][0].count("\n- ") == 2
    assert k["notes"][1] == "Page: no change, timeline line only." and k["tail"] == ""
    # four Page lines, adjacent: a footer of four notes, one per line (two or more Page notes need no blank line)
    assert got["pages"]["body"] == "Four pages touched." and len(got["pages"]["notes"]) == 4
    assert all(n.startswith("Page") and "\n" not in n for n in got["pages"]["notes"])
    # a footer-looking line followed by two paragraphs is body; a reply with no note is untouched (body is the text itself)
    assert got["middle"] == {"body": MIDDLE, "footer": None, "notes": [], "tail": ""}
    assert got["none"] == {"body": ASSISTANT_MD, "footer": None, "notes": [], "tail": ""}
    # the footer as the whole reply: an empty body
    assert got["whole"] == {"body": "", "footer": WHOLE, "notes": ["Board board#26: no change, the item is the PR's.", "Write-up: none."], "tail": ""}
    assert got["code"]["body"] == "Run it:\n\n```sh\nsala ls\n```" and got["code"]["notes"] == ["Write-up: none."]
    # a footer, then the closing ask: body, the notes, and the ask as the tail (plain leads and bold ones alike)
    a = got["ask"]
    assert a["body"] == "Both items are stale." and [n[:5] for n in a["notes"]] == ["Board", "Page:"]
    assert a["tail"] == ASK.split("\n\n")[-1] and a["footer"] == ASK.split("\n\n")[1]
    ba = got["boldask"]
    assert ba["body"] == "Done." and [n.split("\n")[0] for n in ba["notes"]] == ["**Board:**", "**Write-up**: none, the proposal is on the item."]
    assert ba["notes"][0].count("\n- ") == 1 and ba["tail"] == BOLD_ASK.split("\n\n")[-1]
    # two paragraphs after the run: not a footer, the reply as it was
    assert got["twotail"] == {"body": TWO_TAIL, "footer": None, "notes": [], "tail": ""}


@pytest.mark.skipif(not NODE, reason="node is not installed")
def test_the_rule_keeps_prose_that_only_looks_like_a_note():
    cases = [
        "Done.\nPage projects/x: changed.",                       # one Page note right after prose: body
        "Done.\n\nPage projects/x: changed.",                     # the same after a blank line: footer
        "Page projects/x: changed.",                              # the same as the whole reply: footer
        "The deck:\n\nPage 1: the title\nPage 2: the problem",    # a deck's pages are prose, blank line or not
        "Some news.\n\nBoard members meet on Friday.",            # "Board" starting a sentence is prose
        "Changes:\n- a\n- b\n\nWrite-up: none.",                  # bullets above the first note stay in the body
        "Board:\n- [board#9001](https://x/9001): a\nWrite-up: none.",   # a Write-up right under a bullet is its own note
        "Hi.\n\nWrite-up: none.\n\n\n",                           # trailing blank lines belong to nobody
        "Write-up: none.\n```\ncode\n```",                        # a fenced block right under the note: no footer
        "",
        "Cleaned up.\n\nPages are long, so I split them in two.",   # prose starting with "Pages", no colon: prose
    ]
    got = split(cases)
    assert got[0]["footer"] is None
    assert got[1] == {"body": "Done.", "footer": "Page projects/x: changed.", "notes": ["Page projects/x: changed."], "tail": ""}
    assert got[2] == {"body": "", "footer": "Page projects/x: changed.", "notes": ["Page projects/x: changed."], "tail": ""}
    assert got[3]["footer"] is None and got[4]["footer"] is None
    assert got[5] == {"body": "Changes:\n- a\n- b", "footer": "Write-up: none.", "notes": ["Write-up: none."], "tail": ""}
    assert got[6]["body"] == "" and got[6]["notes"] == ["Board:\n- [board#9001](https://x/9001): a", "Write-up: none."]
    assert got[7] == {"body": "Hi.", "footer": "Write-up: none.", "notes": ["Write-up: none."], "tail": ""}
    assert got[8]["footer"] is None and got[9] == {"body": "", "footer": None, "notes": [], "tail": ""}
    assert got[10]["footer"] is None
    for text, r in zip(cases, got):
        if r["footer"] is None:
            assert r["body"] == text and r["tail"] == ""  # nothing changes for a reply without a footer


@pytest.mark.skipif(not NODE, reason="node is not installed")
def test_the_rule_allows_one_closing_paragraph_after_a_footer_with_a_strong_note():
    cases = [
        "Done.\n\nPage projects/x: changed.\nPage projects/y: changed.\n\nShall I go on?",   # Page notes alone before a paragraph: body
        "Status.\n\nBoard board#9005: waiting on CI.\n\nThe runner was out of disk; I cleaned it.",  # a Board note, one paragraph: footer + tail
        "Hi.\n\nBoard: x\n\nWrite-up: none.\nwrapped line",       # the closing paragraph begins with a note line: body
        "Hi.\n\nWrite-up: none.\n\n" + "\n".join(f"line {i}" for i in range(9)),  # a closing paragraph of 9 lines: body
        "Hi.\n\nWrite-up: none.\n\n" + "\n".join(f"line {i}" for i in range(8)),  # 8 lines: the cap
        "Hi.\n\nWrite-up: none.\n\nPick one:\n- A\n- B",         # the ask with its options is one paragraph
        "Write-up: none.\n\nOK to go?",                           # the footer starts the reply: no body, a tail
        "Hi.\n\nWrite-up: none.\n\nSign-in link:\nhttps://example.com/x\n\n",  # trailing blank lines after the tail
        "Hi.\n\n**Write-up:** none.",                            # bold leads read as the plain ones
        "Hi.\n**Board board#26:** no change.",
        "Hi.\n\n__Page:__ done.",
        "Hi.\n\n**Board:** no change",
        "Hi.\n\n**Board** members met.",                         # a bold word that is not a lead: prose
        "Hi.\n\nPage [`projects/sala`](https://example.com/p): changed.",  # a backticked slug is a Page note
    ]
    got = split(cases)
    assert got[0]["footer"] is None
    assert got[1] == {"body": "Status.", "footer": "Board board#9005: waiting on CI.", "notes": ["Board board#9005: waiting on CI."],
                      "tail": "The runner was out of disk; I cleaned it."}
    assert got[2]["footer"] is None and got[3]["footer"] is None
    assert got[4]["footer"] == "Write-up: none." and got[4]["tail"].count("\n") == 7
    assert got[5] == {"body": "Hi.", "footer": "Write-up: none.", "notes": ["Write-up: none."], "tail": "Pick one:\n- A\n- B"}
    assert got[6] == {"body": "", "footer": "Write-up: none.", "notes": ["Write-up: none."], "tail": "OK to go?"}
    assert got[7] == {"body": "Hi.", "footer": "Write-up: none.", "notes": ["Write-up: none."], "tail": "Sign-in link:\nhttps://example.com/x"}
    for i, lead in ((8, "**Write-up:**"), (9, "**Board board#26:**"), (10, "__Page:__"), (11, "**Board:**")):
        assert got[i]["body"] == "Hi." and got[i]["notes"] == [cases[i].split("\n")[-1]] and got[i]["tail"] == "", (i, got[i])
        assert got[i]["footer"].startswith(lead)
    assert got[12]["footer"] is None
    assert got[13]["footer"] == cases[13].split("\n\n")[1] and got[13]["body"] == "Hi."
    for text, r in zip(cases, got):
        if r["footer"] is None:
            assert r["body"] == text and r["tail"] == ""


# a footer in the middle of the reply (a reply put a step, a list and a code
# block after its Write-up and Board lines)
AFTER = ("Your step: run these on box-a.\n\n" + "\n".join(f"{i}. do thing {i}" for i in range(1, 8)) + "\n\n"
         "Then check the result:\n\n```sh\nsala ls\nBoard: not a note, inside a fence\n```")
MID_BOARD = "Write-up: none, the PR body holds the record.\n\nBoard:\n- board#9001: a\n- board#9002: b\n- board#9003: c"
MID_BODY = "Fixed the thing, three files touched."


@pytest.mark.skipif(not NODE, reason="node is not installed")
def test_the_rule_finds_a_write_up_and_board_run_wherever_it_sits():
    shaped = f"{MID_BODY}\n\n{MID_BOARD}\n\n{AFTER}"
    no_writeup = f"{MID_BODY}\n\nBoard:\n- board#9001: a\n- board#9002: b\n- board#9003: c\n\n{AFTER}"
    fenced = "Run it:\n\n```\nWrite-up: none.\nBoard: x\n```\n\nThen this paragraph.\n\nAnd another one."
    mid_body = "Notes:\n\nBoard: the board is a list of items.\n\nSecond paragraph.\n\nThird paragraph."
    in_list = "Notes:\n\n- Board: one\n- Write-up: two\n\nA paragraph.\n\nAnother."
    wrapped = "Hi.\n\nBoard: x\n\nWrite-up: none.\nwrapped line"
    two = ("A.\n\nWrite-up: none, first.\nBoard board#9001: first.\n\nMore prose here.\n\n"
           "Write-up: none, second.\nBoard board#9002: second.\n\n1. one\n2. two\n\nEnd.")
    got = dict(zip(["shaped", "no_writeup", "fenced", "mid_body", "in_list", "wrapped", "two"],
                   split([shaped, no_writeup, fenced, mid_body, in_list, wrapped, two])))
    # (a) the shape of the reply that slipped: body, footer (a Write-up line, a Board line with 3 bullets), then everything after as the tail
    s = got["shaped"]
    assert s["body"] == MID_BODY and s["footer"] == MID_BOARD and s["tail"] == AFTER
    assert s["notes"] == ["Write-up: none, the PR body holds the record.", "Board:\n- board#9001: a\n- board#9002: b\n- board#9003: c"]
    # (b) the same without the Write-up line: as before, no footer
    assert got["no_writeup"] == {"body": no_writeup, "footer": None, "notes": [], "tail": ""}
    # (c) a Board: mention inside a fenced block, mid-body, in a body list item, or with prose right under a Write-up: body
    for k in ("fenced", "mid_body", "in_list", "wrapped"):
        assert got[k]["footer"] is None and got[k]["tail"] == "", k
    assert got["fenced"]["body"] == fenced
    # (e) two qualifying runs: the last one is the footer, the first stays in the body
    t = got["two"]
    assert t["footer"] == "Write-up: none, second.\nBoard board#9002: second." and t["tail"] == "1. one\n2. two\n\nEnd."
    assert t["body"].startswith("A.\n\nWrite-up: none, first.") and t["body"].endswith("More prose here.")


@pytest.mark.skipif(not NODE, reason="node is not installed")
def test_the_old_footer_shapes_still_split_the_same_with_the_anywhere_rule():
    # (d) the footer at the very end; before one short closing paragraph
    end = f"{MID_BODY}\n\n{MID_BOARD}"
    ask = f"{MID_BODY}\n\n{MID_BOARD}\n\nOK to go?"
    long_tail = f"{MID_BODY}\n\n{MID_BOARD}\n\n" + "\n".join(f"line {i}" for i in range(9))
    e, a, lt = split([end, ask, long_tail])
    assert e["body"] == MID_BODY and e["footer"] == MID_BOARD and e["tail"] == "" and len(e["notes"]) == 2
    assert a["body"] == MID_BODY and a["footer"] == MID_BOARD and a["tail"] == "OK to go?"
    # a nine-line closing paragraph used to leave the reply as body; with a Write-up and a Board line it is the tail now
    assert lt["footer"] == MID_BOARD and lt["tail"] == "\n".join(f"line {i}" for i in range(9))


# every assistant message's .md blocks, each scrolled into view first (hit-testing needs the links on screen)
PROBE = r"""
new Promise((res0) => requestAnimationFrame(() => requestAnimationFrame(res0))).then(() => new Promise((res) => { const t0 = Date.now(); (function poll() {
  const msgs = document.querySelectorAll("#chat > .msg.assistant");
  if (msgs.length < %d && Date.now() - t0 < 15000) return setTimeout(poll, 100);
  const probe = document.createElement("span"); probe.style.color = "var(--muted)"; document.body.append(probe);
  const muted = getComputedStyle(probe).color; probe.remove();
  const clear = (c) => c === "transparent" || /^rgba\(.*, 0\)$/.test(c);
  const bgOf = (e) => { for (let n = e; n; n = n.parentElement) { const c = getComputedStyle(n).backgroundColor; if (!clear(c)) return c; } return null; };
  // the tap target of a link, per line of its text, probed in the middle of that line's own x-range so a neighbouring line's
  // glyphs (a CJK fallback font's included) are never what is hit. inside: the link is what is found in the middle of the
  // line's text box. above2 / below2: the link is still what is found 2px above / below the text (the ::after box of a link
  // on one line; a plain inline link's box ends at its text). farAbove / farBelow: 8px above the first line and below the
  // last one, well past the 3px target, the element found there is not this link (whatever else it is)
  const onLink = (a, x, y) => { const e = document.elementFromPoint(x, y); return !!e && (e === a || a.contains(e)); };
  const lineRects = (a) => { const rg = document.createRange(); rg.selectNodeContents(a);
    return [...rg.getClientRects()].filter((f) => f.width > 0 && f.height > 0); };
  const tap = (a) => { const fr = lineRects(a), mid = (f) => f.left + f.width / 2;
    if (!fr.length) return { frags: [] };
    const first = fr[0], last = fr[fr.length - 1];
    return { frags: fr.map((f) => ({ w: f.width, inside: onLink(a, mid(f), f.top + f.height / 2),
                                     above2: onLink(a, mid(f), f.top - 2), below2: onLink(a, mid(f), f.bottom + 2) })),
             farAbove: onLink(a, mid(first), first.top - 8), farBelow: onLink(a, mid(last), last.bottom + 8) }; };
  const r2 = (r) => ({ top: r.top, bottom: r.bottom, left: r.left, right: r.right, height: r.height, width: r.width });
  const out = [...msgs].map((m) => {
    m.scrollIntoView({ block: "start" });
    return { uuid: m.dataset.uuid, mdCount: m.querySelectorAll(".md").length, copyBtn: !!m.querySelector(":scope > .actions .copy-btn"),
      mds: [...m.querySelectorAll(":scope > .md")].map((d) => { const cs = getComputedStyle(d); return {
        cls: d.className, html: d.outerHTML, fontSize: parseFloat(cs.fontSize), color: cs.color, bg: bgOf(d),
        borderTop: cs.borderTopWidth + " " + cs.borderTopStyle + " " + cs.borderTopColor, box: r2(d.getBoundingClientRect()),
        blocks: [...d.children].map((c) => ({ tag: c.tagName, box: r2(c.getBoundingClientRect()), text: c.textContent.slice(0, 24) })),
        links: [...d.querySelectorAll("a")].map((a) => { const r = a.getBoundingClientRect(), acs = getComputedStyle(a);
          // the middle of the link's first line box: a link broken over two lines has a bounding box whose middle is the gap between them
          const f = a.getClientRects()[0], hit = document.elementFromPoint(f.left + Math.min(f.width / 2, 24), f.top + f.height / 2);
          return { href: a.getAttribute("href"), target: a.getAttribute("target"), rel: a.getAttribute("rel"), color: acs.color,
                   deco: acs.textDecorationLine, h: r.height, w: r.width, right: r.right, hit: !!hit && (hit === a || a.contains(hit)),
                   display: acs.display, padTop: acs.paddingTop, padBottom: acs.paddingBottom,
                   wrapped: a.classList.contains("wrapped"), afterDisplay: getComputedStyle(a, "::after").display,
                   afterH: parseFloat(getComputedStyle(a, "::after").height), ...tap(a) }; }),
        copies: d.querySelectorAll(".code-copy").length }; }) };
  });
  const pane = document.getElementById("chat-pane");
  res({ width: innerWidth, muted, rule: getComputedStyle(document.getElementById("composer")).borderTopColor,
        docScroll: document.documentElement.scrollWidth, paneScroll: pane.scrollWidth, paneClient: pane.clientWidth, msgs: out });
})(); }))
"""

COPY = r"""
new Promise((res) => {
  Object.defineProperty(navigator, "clipboard", { configurable: true,
    value: { writeText: (t) => { window.__copied = t; return Promise.resolve(); } } });
  document.querySelector('#chat > .msg[data-uuid="f-block"] .copy-btn').click();
  const t0 = Date.now();
  (function poll() { if (window.__copied !== undefined) res(window.__copied); else if (Date.now() - t0 > 5000) res(null); else setTimeout(poll, 20); })();
})
"""


def contrast(fg: str, bg: str) -> float:
    """WCAG 2 contrast of two opaque rgb() strings as the browser computed them."""
    def lum(s: str) -> float:
        parts = [float(x) for x in s[s.index("(") + 1:s.index(")")].split(",")[:3]]
        lin = [(x / 255) / 12.92 if x / 255 <= 0.04045 else ((x / 255 + 0.055) / 1.055) ** 2.4 for x in parts]
        return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]
    assert fg.startswith("rgb(") and bg.startswith("rgb("), (fg, bg)  # opaque, or the ratio means nothing
    hi, lo = sorted((lum(fg), lum(bg)), reverse=True)
    return (hi + 0.05) / (lo + 0.05)


def assert_footer_link_target(name: str, a: dict, body_links: list[dict] | None = None) -> None:
    """A footer link is a plain inline box with no vertical padding (padding on an inline box put the link's text a device
    pixel off the footer text's row at a fractional browser zoom on Windows Chrome). On one line it has an ::after tap area
    reaching 2px above and below its text; on two or more it carries .wrapped and its ::after is off, and every line of its
    text still hits the link inside its own text box. Either way the element 8px past the first and last line is not the link."""
    assert a["display"] == "inline" and a["padTop"] == "0px" and a["padBottom"] == "0px", (name, "a footer link is a plain inline box", a)
    assert a["frags"], (name, "no text line was measured", a)
    assert a["wrapped"] == (len(a["frags"]) > 1), (name, "a link on two lines or more, and only that, carries .wrapped", a)
    if a["wrapped"]:
        assert a["afterDisplay"] == "none", (name, "a wrapped link keeps a partial ::after area", a)
    else:
        assert a["afterDisplay"] != "none", (name, "a one-line link lost its ::after tap area", a)
        if body_links:   # the tap target of a one-line link is its ::after box, no smaller than a body link's
            assert a["afterH"] >= min(x["h"] for x in body_links) - 0.5, (name, a["afterH"], [x["h"] for x in body_links])
    for i, f in enumerate(a["frags"]):
        assert f["inside"], (name, "line", i, "does not hit the link inside its own text", a["frags"], a["wrapped"])
        if not a["wrapped"]:
            assert f["above2"] and f["below2"], (name, "line", i, "has lost its tap target around the text", a)
    assert not a["farAbove"] and not a["farBelow"], (name, "the tap target reaches 8px past the link", a)


def by_case(got: dict) -> dict:
    return {m["uuid"][2:]: m for m in got["msgs"]}


def probe(browser) -> dict:
    got = browser.evaluate(PROBE % len(CASES))
    assert len(got["msgs"]) == len(CASES), [m["uuid"] for m in got["msgs"]]
    return got


def footer_of(m: dict) -> dict:
    fs = [d for d in m["mds"] if "footer" in d["cls"].split()]
    assert len(fs) == 1, [d["cls"] for d in m["mds"]]
    return fs[0]


def test_the_footer_renders_apart_from_the_body(served, browser):
    transcript_file(served).write_text(TRANSCRIPT)
    browser.open(f"{served['url']}/#s={NAME}")
    got = probe(browser)
    assert got["width"] == 390
    c = by_case(got)
    body_links = [a for a in c["none"]["mds"][0]["links"] if a["href"]]
    body_size = c["none"]["mds"][0]["fontSize"]
    assert body_size == 15 and body_links, c["none"]   # the look's 15 px reading size
    for name in ("writeup", "block", "oneline", "listed", "pages", "code"):
        m = c[name]
        assert len(m["mds"]) == 2 and m["mdCount"] == 2, (name, [d["cls"] for d in m["mds"]])
        body, foot = m["mds"]
        assert body["cls"] == "md" and foot["cls"] == "md footer ruled", name
        assert body["fontSize"] == body_size and foot["fontSize"] < body_size and abs(foot["fontSize"] - 0.85 * body_size) <= 0.3, (name, foot["fontSize"])   # 0.85 x 15 = 12.75, snapped to the look's 13 px step
        # dimmed with the --muted token on the page's background, AA at this size; under a 1px rule in the border token
        assert foot["color"] == got["muted"] and foot["color"] != body["color"], (name, foot["color"], got["muted"])
        assert foot["bg"] and contrast(foot["color"], foot["bg"]) >= 4.5, (name, foot["color"], foot["bg"])
        assert foot["borderTop"] == "1px solid " + got["rule"], (name, foot["borderTop"], got["rule"])
        assert body["borderTop"].startswith("0px"), (name, body["borderTop"])
        assert foot["box"]["top"] >= body["box"]["bottom"] + 7, (name, body["box"], foot["box"])  # the margin above the rule (8 px on the look's grid, was 10)
        assert m["copyBtn"], name
    # one block per note, each on its own line: Board (then its list), Page, Write-up; four Page notes four blocks
    tags = lambda f: [b["tag"] for b in f["blocks"]]  # noqa: E731
    assert tags(footer_of(c["block"])) == ["P", "UL", "P", "P"], footer_of(c["block"])["blocks"]
    assert tags(footer_of(c["listed"])) == ["P", "UL", "P"]   # Board and its list, then the Page note as a block of its own
    pages = footer_of(c["pages"])
    assert tags(pages) == ["P", "P", "P", "P"] and [b["text"][:4] for b in pages["blocks"]] == ["Page"] * 4
    for a, b in zip(pages["blocks"], pages["blocks"][1:]):
        assert b["box"]["top"] >= a["box"]["bottom"] - 0.5, (a, b)
    assert tags(footer_of(c["writeup"])) == ["P"] and tags(footer_of(c["oneline"])) == ["P"]
    # links inside: anchors in the accent (not underlined, in the look), tappable where they are, no smaller a target than a body link's
    for name, want in (("block", [f"{WEB}/items/26", f"{WEB}/items/88"]), ("listed", [f"{WEB}/items/26"]), ("pages", [LONG_URL])):
        f = footer_of(c[name])
        assert [a["href"] for a in f["links"]] == want, (name, f["links"])
        for a in f["links"]:
            assert a["target"] == "_blank" and a["rel"] == "noopener noreferrer", a
            assert a["color"] == body_links[0]["color"] and a["color"] != f["color"] and "underline" not in a["deco"], (name, a, f["color"])   # the look marks a link by its accent colour alone
            assert a["hit"], (name, a)
            assert_footer_link_target(name, a, body_links)
    # the whole reply a footer: dimmed and small, but no rule above and nothing else in the message
    w = c["whole"]
    assert len(w["mds"]) == 1 and w["mds"][0]["cls"] == "md footer", w["mds"]
    assert w["mds"][0]["fontSize"] < body_size and w["mds"][0]["color"] == got["muted"] and w["mds"][0]["borderTop"].startswith("0px"), w["mds"][0]
    assert tags(w["mds"][0]) == ["P", "P"]
    # a footer-looking line in the middle, a reply without one, two paragraphs after a note: a single .md, rendered
    # exactly as md() renders the text
    for name in ("middle", "none", "twotail"):
        m = c[name]
        assert len(m["mds"]) == 1 and m["mds"][0]["cls"] == "md", (name, [d["cls"] for d in m["mds"]])
        assert m["mds"][0]["html"] == browser.evaluate(f"md({json.dumps(CASES[name])}).outerHTML"), name
    # a footer followed by the closing ask: body, the dimmed footer under its rule, then the ask as body text (full size,
    # the text colour, no rule, a gap above), in that order, its links tappable; bold leads the same
    body_color = c["none"]["mds"][0]["color"]
    for name, hrefs in (("ask", [f"{WEB}/items/23"]), ("boldask", [f"{WEB}/items/27"])):
        m = c[name]
        assert [d["cls"] for d in m["mds"]] == ["md", "md footer ruled", "md tail"] and m["mdCount"] == 3, (name, [d["cls"] for d in m["mds"]])
        body, foot, tail = m["mds"]
        assert body["box"]["bottom"] + 7 <= foot["box"]["top"] and foot["box"]["bottom"] + 7 <= tail["box"]["top"], (name, body["box"], foot["box"], tail["box"])
        assert foot["fontSize"] < body_size and foot["color"] == got["muted"], (name, foot)
        assert tail["fontSize"] == body_size and tail["color"] == body_color and tail["borderTop"].startswith("0px"), (name, tail)
        assert tags(tail) == ["P"] and tail["blocks"][0]["text"][:2] in ("Dr", "To"), tail["blocks"]
        assert [a["href"] for a in tail["links"]] == hrefs, (name, tail["links"])
        for a in tail["links"]:
            assert a["hit"] and a["target"] == "_blank" and a["rel"] == "noopener noreferrer" and a["color"] == body_links[0]["color"], (name, a)
            assert a["h"] >= min(x["h"] for x in body_links) - 0.5, (name, a)
        assert m["copyBtn"], name
    assert tags(footer_of(c["ask"])) == ["P", "P"] and tags(footer_of(c["boldask"])) == ["P", "UL", "P"]
    assert footer_of(c["boldask"])["blocks"][0]["text"] == "Board:"  # the bold lead rendered, not its asterisks
    # a code block's copy button stays with the body; the footer gets none
    body, foot = c["code"]["mds"]
    assert body["copies"] == 1 and foot["copies"] == 0, c["code"]["mds"]
    # the message's copy button copies the text as written, footer and all
    assert browser.evaluate(COPY) == BLOCK


def test_the_footer_keeps_contrast_in_the_light_theme(served, browser):
    transcript_file(served).write_text(TRANSCRIPT)
    browser.open(f"{served['url']}/#s={NAME}", dark=False)
    got = probe(browser)
    c = by_case(got)
    seen = {}
    for theme in ("light", "dark"):
        browser.send("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-color-scheme", "value": theme}]})
        browser.evaluate("new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))")
        got = probe(browser)
        c = by_case(got)
        f = footer_of(c["block"])
        assert f["color"] == got["muted"] and f["bg"], (theme, f)
        ratio = contrast(f["color"], f["bg"])
        assert ratio >= 4.5, (theme, f["color"], f["bg"], ratio)
        seen[theme] = (f["color"], f["bg"], ratio)
        assert f["borderTop"] == "1px solid " + got["rule"], (theme, f["borderTop"])
    assert seen["light"][1] != seen["dark"][1], seen  # the theme did change under the measure


@pytest.mark.parametrize("width", [320, 390, 1280])
def test_no_sideways_scroll_with_a_long_url_in_the_footer(served, browser, width):
    transcript_file(served).write_text(TRANSCRIPT)
    browser.open(f"{served['url']}/#s={NAME}")
    browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 844, "deviceScaleFactor": 1, "mobile": width <= 760})
    got = probe(browser)
    assert got["width"] == width
    assert got["docScroll"] <= width and got["paneScroll"] <= got["paneClient"], got
    c = by_case(got)
    for name in ("pages", "block", "listed", "ask", "boldask"):
        f = footer_of(c[name])
        assert f["box"]["right"] <= width and f["box"]["left"] >= 0, (name, f["box"])
        for a in f["links"]:
            assert a["right"] <= width + 0.5 and a["hit"], (name, a)
        for b in f["blocks"]:
            assert b["box"]["right"] <= width + 0.5, (name, b)
    for name in ("ask", "boldask"):
        tail = c[name]["mds"][-1]
        assert tail["cls"] == "md tail" and tail["box"]["right"] <= width and all(a["right"] <= width + 0.5 and a["hit"] for a in tail["links"]), (name, tail)


def test_a_reply_arriving_on_the_stream_gets_the_same_footer(served, browser):
    """The stream's "append" renders through the same path as the history: a footer arrives split."""
    path = transcript_file(served)
    path.write_text(transcript_line("user", [{"type": "text", "text": "report"}], "f-u")
                    + transcript_line("assistant", [{"type": "text", "text": ASSISTANT_MD}], "f-none", model="claude-opus-5-5"))
    browser.open(f"{served['url']}/#s={NAME}")
    assert browser.evaluate("""new Promise((res) => { const t0 = Date.now(); (function poll() {
      if (document.querySelector('#chat > .msg[data-uuid="f-none"]') || Date.now() - t0 > 15000) res(!!document.querySelector('#chat > .msg[data-uuid="f-none"]'));
      else setTimeout(poll, 100); })(); })""")
    with path.open("a") as f:
        f.write(transcript_line("assistant", [{"type": "text", "text": BLOCK}], "f-live", model="claude-opus-5-5"))
    end = time.time() + 15
    live = None
    while time.time() < end and not live:
        live = browser.evaluate("""(() => { const m = document.querySelector('#chat > .msg[data-uuid="f-live"]'); if (!m) return null;
          return { mds: [...m.querySelectorAll(":scope > .md")].map((d) => d.className) }; })()""")
        if not live:
            time.sleep(0.2)
    assert live == {"mds": ["md", "md footer ruled"]}, live
    assert browser.evaluate("""[...document.querySelectorAll('#chat > .msg[data-uuid="f-live"] .md.footer > *')].map((c) => c.tagName)""") == ["P", "UL", "P", "P"]


# every footer link of a case against the same link with the footer rule's effect taken off (a plain inline box, no padding
# or margin, nothing positioned): the same lines at the same places and the paragraph the same height
LEVEL = r"""(() => {
  const msg = document.querySelector('#chat > .msg[data-uuid="f-%s"]');
  const links = [...msg.querySelectorAll(".md.footer a[href]")];
  const lines = (a) => { const rg = document.createRange(); rg.selectNodeContents(a);
    return [...rg.getClientRects()].filter((f) => f.width > 0 && f.height > 0).map((f) => [f.top, f.left, f.width, f.height]); };
  const out = links.map((a) => { const p = a.closest("li, p"), h = () => p.getBoundingClientRect().height;
    const own = { lines: lines(a), h: h() };
    a.style.cssText = "display: inline; padding: 0; margin: 0; max-width: none; position: static";
    const plain = { lines: lines(a), h: h() };
    a.style.cssText = "";
    return { own, plain }; });
  // anything between a link and the pane that is not overflow: visible would cut its tap target
  const clips = []; for (let n = links[0].parentElement; n && n.id !== "chat-pane"; n = n.parentElement) {
    const o = getComputedStyle(n); if (o.overflowY !== "visible" || o.overflowX !== "visible") clips.push(n.className || n.tagName); }
  return { links: out, clips }; })()"""


@pytest.mark.parametrize("scale", [1, 1.1, 1.25, 1.5])
@pytest.mark.parametrize("width", [320, 390])
def test_a_footer_link_sits_level_with_the_footer_text_at_fractional_zoom(served, browser, scale, width):
    """The rule `.md.footer a[href] { padding: 3px 0 }` (the tap target) put a link's text a device pixel or two
    below the footer's own text on Windows Chrome at fractional browser zoom (level at 100%). Padding on an inline box
    snaps its text to another pixel row there; headless Chromium on Linux does not show it, so the check pins the cause and
    the effects that can be seen here. A footer link is a plain inline box with no vertical padding: for every fixture, a
    wrapped one too (a link of many words, a slug with no space in it, at 320 and 390 px), its lines sit at the same places
    and its paragraph is the same height as with the footer rule's effect taken off, so a layout change such as an
    inline-block, which moves a long link and the words around it onto rows of their own, fails here. The tap target: a link
    on one line reaches 2px above and below its text (::after); a link on two lines or more has no ::after (.wrapped) and
    each line still hits the link inside its text; the element 8px past the first and last line is never the link; all
    probed in each line's own x-range. Nothing between the link and the pane clips it."""
    transcript_file(served).write_text(TRANSCRIPT)
    browser.open(f"{served['url']}/#s={NAME}")
    browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 844, "deviceScaleFactor": scale, "mobile": False})
    got = probe(browser)
    c = by_case(got)
    body_links = [a for a in c["none"]["mds"][0]["links"] if a["href"]]
    assert body_links
    for name in ("block", "listed", "pages", "wrap", "slug"):
        f = footer_of(c[name])
        assert f["links"], name
        for a in f["links"]:
            if name in ("wrap", "slug"):   # these wrap in a column this narrow, whatever the zoom
                assert len(a["frags"]) >= 2, (name, "the link no longer wraps", a)
                assert all(g["w"] <= width for g in a["frags"]), (name, "a line of the link is wider than the page", a)
            assert_footer_link_target(name, a, body_links)
        assert f["box"]["right"] <= width + 0.5, (name, "the footer scrolls sideways", f["box"])
    for name in ("block", "listed", "pages", "wrap", "slug"):   # every fixture, the wrapped ones too: a layout change fails here
        lvl = browser.evaluate(LEVEL % name)
        assert lvl["links"], name
        for k, link in enumerate(lvl["links"]):
            assert len(link["own"]["lines"]) == len(link["plain"]["lines"]), (name, k, "the link breaks over other lines than a plain inline link", link)
            for mine, plain in zip(link["own"]["lines"], link["plain"]["lines"]):
                assert all(abs(x - y) < 0.01 for x, y in zip(mine, plain)), (name, k, "a line of the link is off the place a plain inline link's is", link)
            assert abs(link["own"]["h"] - link["plain"]["h"]) < 0.01, (name, k, "the link changes its paragraph's height", link)
        assert lvl["clips"] == [], (name, "something between the link and the pane clips its tap target", lvl)


def test_a_footer_link_gains_and_loses_its_wrapped_mark_as_the_chat_width_changes(served, browser):
    """Where a link breaks depends on the column's width, so .wrapped follows it: a slug that fits on one line in a wide
    window has its ::after tap area, loses it when a narrow window breaks it over lines, and gets it back."""
    transcript_file(served).write_text(TRANSCRIPT)
    browser.open(f"{served['url']}/#s={NAME}")
    seen = {}
    for width in (320, 1280, 320):
        browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 844, "deviceScaleFactor": 1, "mobile": False})
        a = footer_of(by_case(probe(browser))["slug"])["links"][0]
        # only the mark and the ::after here: back at 320 the sidebar drawer stays open over the text, so no hit test
        assert a["wrapped"] == (len(a["frags"]) > 1) and (a["afterDisplay"] == "none") == a["wrapped"], (width, a)
        seen.setdefault(width, []).append(a["wrapped"])
    assert seen == {320: [True, True], 1280: [False]}, seen

