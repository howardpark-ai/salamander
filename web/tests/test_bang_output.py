"""The output of a finished `!` command shows open under its command: a box headed
"Output · N lines" with a Fold button (aria-expanded), the first 12 lines and a "Show all N lines" button when there are
more, the truncation note kept when the text was clipped. A slash command's output (local-command-stdout) stays a closed
fold. When the command ends, the live block of the running command is replaced by this box in the same place.

Rendered from a fake transcript at a desktop and a phone width in a headless Chromium when one is installed (conftest.py:
`served`, `browser`), else skipped. The classification itself is in test_transcript.py.
"""

from __future__ import annotations

import json

import pytest

from conftest import NAME, transcript_line, transcript_file

SHORT = "one\ntwo\nthree"
LONG = "\n".join(f"row {i} https://example.com/r{i}" for i in range(1, 31))


def bang(cmd: str, out: str, n: int) -> str:
    return (transcript_line("user", [{"type": "text", "text": f"<bash-input>{cmd}</bash-input>"}], f"bi-{n}")
            + transcript_line("user", [{"type": "text", "text": f"<bash-stdout>{out}</bash-stdout><bash-stderr></bash-stderr>"}], f"bo-{n}"))


TRANSCRIPT = (transcript_line("user", [{"type": "text", "text": "hello"}], "u-1")
              + bang("echo short", SHORT, 1)
              + bang("seq 30", LONG, 2)
              + bang("true", "", 3)
              + transcript_line("user", [{"type": "text", "text": "<local-command-stdout>slash output</local-command-stdout>"}], "lc-1"))

WAIT = """
new Promise((res) => { const t0 = Date.now(); (function poll() {
  const n = document.querySelectorAll("#chat .bang-out").length, f = document.querySelectorAll("#chat details.notice").length;
  if ((n >= 3 && f >= 1) || Date.now() - t0 > 15000) res([n, f]); else setTimeout(poll, 100);
})(); })
"""

# each box: title, the pre's text and line count, the buttons, aria and visibility, and whether it fits the chat
INSPECT = r"""
(() => [...document.querySelectorAll("#chat .bang-out")].map((b) => {
  const fold = b.querySelector(".bang-fold"), more = b.querySelector(".bang-more"), body = b.querySelector(".bang-body");
  const pre = b.querySelector("pre"), r = b.getBoundingClientRect(), c = document.querySelector("#chat").getBoundingClientRect();
  return { title: b.querySelector(".bang-title").textContent, text: pre.textContent, lines: pre.textContent ? pre.textContent.split("\n").length : 0,
           fold: fold.textContent, foldTag: fold.tagName, foldType: fold.type, expanded: fold.getAttribute("aria-expanded"),
           controls: fold.getAttribute("aria-controls"), bodyId: body.id, bodyHidden: body.hidden, bodyShown: body.getBoundingClientRect().height > 0,
           more: more ? more.textContent : null, moreTag: more ? more.tagName : null, inDetails: !!b.closest("details"),
           links: pre.querySelectorAll("a").length, inChat: r.left >= c.left - 0.5 && r.right <= c.right + 0.5,
           docScroll: document.documentElement.scrollWidth, innerW: innerWidth };
}))()
"""


def opened(served, browser, width: int, height: int, mobile: bool, transcript: str = TRANSCRIPT) -> None:
    transcript_file(served).write_text(transcript)
    browser.open(f"{served['url']}/#s={NAME}")
    browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": height, "deviceScaleFactor": 1, "mobile": mobile})


@pytest.mark.parametrize("width,height,mobile", [(1280, 800, False), (390, 844, True)])
def test_the_output_shows_open_under_its_command(served, browser, width, height, mobile):
    opened(served, browser, width, height, mobile)
    assert browser.evaluate(WAIT) == [3, 1]
    got = browser.evaluate(INSPECT)
    short, long_, none = got
    where = json.dumps(got)
    # the short output: open, its three lines, no "Show all", real buttons
    assert short["title"] == "Output · 3 lines" and short["text"] == SHORT, where
    assert short["more"] is None and not short["inDetails"], where
    assert (short["foldTag"], short["foldType"], short["fold"]) == ("BUTTON", "button", "Fold output"), where
    assert short["expanded"] == "true" and short["controls"] == short["bodyId"] and short["bodyShown"], where
    # it sits right under its command line
    order = browser.evaluate("""[...document.querySelectorAll('#chat .msg')].map((m) => m.querySelector('.cmd') ? 'cmd:' + m.querySelector('.cmd').textContent
      : m.querySelector('.bang-out') ? 'out' : m.querySelector('details.notice') ? 'notice' : 'other')""")
    assert order == ["other", "cmd:! echo short", "out", "cmd:! seq 30", "out", "cmd:! true", "out", "notice"], order
    # over twelve lines: the first twelve (links still links) and a "Show all 30 lines" button
    assert long_["title"] == "Output · 30 lines" and long_["lines"] == 12, where
    assert long_["text"] == "\n".join(LONG.split("\n")[:12]) and long_["links"] == 12, where
    assert (long_["more"], long_["moreTag"]) == ("Show all 30 lines", "BUTTON"), where
    # no output at all
    assert none["title"] == "Output · 0 lines" and none["text"] == "(no output)", where
    # nothing sticks out of the chat, at either width
    assert all(g["inChat"] and g["docScroll"] <= g["innerW"] for g in got), where


def test_show_all_opens_the_rest_in_place(served, browser):
    opened(served, browser, 390, 844, True)
    assert browser.evaluate(WAIT) == [3, 1]
    browser.evaluate("document.querySelectorAll('#chat .bang-more')[0].click()")
    got = browser.evaluate(INSPECT)[1]
    assert got["text"] == LONG and got["lines"] == 30 and got["more"] is None, got
    assert got["title"] == "Output · 30 lines" and got["links"] == 30, got


def test_keyboard_access_focus_stays_and_the_text_scrolls(served, browser):
    opened(served, browser, 390, 844, True)
    assert browser.evaluate(WAIT) == [3, 1]
    # the text is a keyboard-scrollable region; an empty output has none
    got = browser.evaluate("[...document.querySelectorAll('#chat .bang-out pre')].map((p) => p.getAttribute('tabindex'))")
    assert got == ["0", "0", None], got
    # Show all removes its own button: focus moves to the Fold button, not to the page body
    browser.evaluate("document.querySelectorAll('#chat .bang-more')[0].focus()")
    assert browser.evaluate("document.activeElement.className") == "bang-more"
    browser.evaluate("document.activeElement.click()")
    got = browser.evaluate("({ cls: document.activeElement.className, tag: document.activeElement.tagName, "
                           "inBox: !!document.activeElement.closest('.bang-out') })")
    assert got == {"cls": "bang-fold", "tag": "BUTTON", "inBox": True}, got


def test_fold_closes_and_opens_it(served, browser):
    opened(served, browser, 390, 844, True)
    assert browser.evaluate(WAIT) == [3, 1]
    click = "document.querySelectorAll('#chat .bang-fold')[1].click()"
    browser.evaluate(click)
    g = browser.evaluate(INSPECT)[1]
    assert g["expanded"] == "false" and g["bodyHidden"] and not g["bodyShown"] and g["fold"] == "Fold output", g  # the label is constant; aria-expanded carries the state
    assert g["title"] == "Output · 30 lines", g  # the header stays
    browser.evaluate(click)
    g = browser.evaluate(INSPECT)[1]
    assert g["expanded"] == "true" and not g["bodyHidden"] and g["bodyShown"] and g["fold"] == "Fold output", g
    # the other boxes were not touched
    assert [x["expanded"] for x in browser.evaluate(INSPECT)] == ["true", "true", "true"]


def test_a_slash_command_output_stays_a_closed_fold(served, browser):
    opened(served, browser, 390, 844, True)
    assert browser.evaluate(WAIT) == [3, 1]
    got = browser.evaluate("""(() => { const d = document.querySelector('#chat details.notice'); return { open: d.open, sum: d.querySelector('summary').textContent }; })()""")
    assert got == {"open": False, "sum": "command output"}, got


def test_a_clipped_output_keeps_its_truncation_note(served, browser):
    block = {"kind": "bang_output", "label": "command output", "text": LONG, "truncated": True}
    opened(served, browser, 390, 844, True, transcript_line("user", [{"type": "text", "text": "hello"}], "u-1"))
    browser.evaluate("new Promise((res) => { const t0 = Date.now(); (function p() { if (document.querySelector('#chat .msg') || Date.now() - t0 > 10000) res(1); else setTimeout(p, 50); })(); })")
    browser.evaluate(f"renderMessage({{ role: 'user', uuid: 'x', blocks: [{json.dumps(block)}] }}, {{ live: true }})")
    assert browser.evaluate("document.querySelector('#chat .bang-out .trunc')?.textContent") == "(truncated)"


def test_the_live_block_becomes_the_box_in_the_same_place(served, browser):
    opened(served, browser, 390, 844, True, transcript_line("user", [{"type": "text", "text": "hello"}], "u-1"))
    browser.evaluate("new Promise((res) => { const t0 = Date.now(); (function p() { if (document.querySelector('#chat .msg') || Date.now() - t0 > 10000) res(1); else setTimeout(p, 50); })(); })")
    browser.evaluate("applyLive({ running: true, command: 'sleep 5; echo hi', text: 'line a\\nline b' })")
    assert browser.evaluate("!!document.querySelector('#chat > #live-bang')")
    top_live = browser.evaluate("document.querySelector('#live-bang').getBoundingClientRect().top")
    # the transcript's two records land (the command line, then its output), then the stream says it is no longer running
    browser.evaluate("renderMessage({ role: 'user', uuid: 'bi', blocks: [{ kind: 'command', text: '! sleep 5; echo hi' }] }, { live: true })")
    top_cmd_after = browser.evaluate("document.querySelector('#chat .msg .cmd').getBoundingClientRect().bottom")
    block = {"kind": "bang_output", "label": "command output", "text": "hi", "truncated": False}
    browser.evaluate(f"renderMessage({{ role: 'user', uuid: 'bo', blocks: [{json.dumps(block)}] }}, {{ live: true }})")
    # the live block is gone at once (no frame with both), the box is where it was, right under the command line
    assert browser.evaluate("document.querySelectorAll('#live-bang').length") == 0
    got = browser.evaluate("""(() => { const kids = [...document.querySelector('#chat').children].map((n) => n.id === 'live-bang' ? 'live' : n.querySelector('.bang-out') ? 'out' : n.querySelector('.cmd') ? 'cmd' : 'other');
      return { kids, top: document.querySelector('.bang-out').getBoundingClientRect().top }; })()""")
    assert got["kids"][-2:] == ["cmd", "out"], got
    assert abs(got["top"] - top_cmd_after) < 30, (got, top_live, top_cmd_after)
    # the stream's own "not running" afterwards changes nothing
    browser.evaluate("applyLive({ running: false })")
    assert browser.evaluate("document.querySelectorAll('#chat .bang-out').length") == 1
