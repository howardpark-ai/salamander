"""Nothing in the chat is wider than the chat (on Android Chrome a message overflowed to the
left: a background-task notice pill, one unwrapped line wider than the phone, right-aligned, so its left
part was off the screen).

Every chat element that can carry a long text is rendered from a transcript of long lines (a task notification with
and without spaces in its summary, a message from a session with a long name, a slash command and a ! command with a
long path, command output, a tool call with a long name and a long command, tool results with a long URL and hash, a
reply with a long bare URL, inline code and a code block with a long line, a prompt bubble with a long token) and
measured at four phone widths and on a desktop: each box stays inside the chat pane, a code block wraps inside its
own box, and neither the page nor the pane scrolls sideways. Runs in a headless Chromium when one is installed
(conftest.py: `served`, `browser`), else skipped.
"""

from __future__ import annotations

import json

from conftest import NAME, transcript_line, transcript_file

TOKEN = "/tmp/claude-1000/-home-me-demo-tools-demo-tools--claude-worktrees-new-task/00000000-0000-4000-8000-0000000000c1/tasks/b0000test.output"
URL = "https://board.example.test/items/137?view=waiting-on-you&from=demo-maintainer&anchor=" + "f" * 100
HASH = "sha256:" + "0123456789abcdef" * 8
LONG_SUMMARY = ('Background command "Wait for the sala-web heartbeat on sala.example.test to switch the links and report '
                'what changed" completed (exit code 0)')
LONG_NAME = "mcp__plugin_demo_tracker__tracker-check-next-steps"


def task_notification(summary: str) -> str:
    return ("<task-notification>\n<task-id>b0000test</task-id>\n<tool-use-id>toolu_01TESTTESTTESTTESTTEST00</tool-use-id>\n"
            f"<output-file>{TOKEN}</output-file>\n<status>completed</status>\n<summary>{summary}</summary>\n</task-notification>")


def queued_notification(summary: str, uuid: str) -> str:
    # a task notification that arrived while the session was busy: a queued_command attachment, not a user line
    return json.dumps({"type": "attachment", "uuid": uuid, "timestamp": "2026-10-14T03:00:00.000Z",
                       "attachment": {"type": "queued_command", "commandMode": "task-notification",
                                      "prompt": task_notification(summary)}}) + "\n"


LONG_TRANSCRIPT = (
    transcript_line("user", [{"type": "text", "text": f"please read {TOKEN} and {URL} then {HASH}"}], "o-1")
    + transcript_line("assistant", [
        {"type": "thinking", "thinking": f"The file is {TOKEN} and the digest {HASH}."},
        {"type": "text", "text": f"Fetched {URL} into `{TOKEN}`.\n\n```\n$ sha256sum {TOKEN}\n{HASH}  {TOKEN}\n```\n\nDone."},
        {"type": "tool_use", "id": "o-t1", "name": "Bash", "input": {"command": f"curl -sS '{URL}' -o {TOKEN} && sha256sum {TOKEN}"}},
        {"type": "tool_use", "id": "o-t2", "name": LONG_NAME, "input": {"page_id": HASH}},
    ], "o-2", model="claude-opus-5-5")
    + transcript_line("user", [{"type": "tool_result", "tool_use_id": "o-t1", "content": f"{HASH}  {TOKEN}\n{URL}"}], "o-3")
    + transcript_line("user", [{"type": "tool_result", "tool_use_id": "o-t2", "is_error": True, "content": f"not found: {URL}"}], "o-4")
    + transcript_line("user", [{"type": "tool_result", "tool_use_id": "o-none", "content": f"orphan result {HASH} {URL}"}], "o-5")
    + transcript_line("user", [{"type": "text", "text": f"<command-name>/pickup</command-name>\n<command-args>{TOKEN}</command-args>"}], "o-6")
    + transcript_line("user", [{"type": "text", "text": f"<bash-input>sha256sum {TOKEN} | tee {TOKEN}.sum</bash-input>"}], "o-7")
    + transcript_line("user", [{"type": "text", "text": f"<local-command-stdout>{HASH}  {TOKEN}\n{URL}</local-command-stdout>"}], "o-8")
    + transcript_line("user", [{"type": "text", "text": "Another Claude session sent a message:\nfrom: demo\n\nshort one"}], "o-9", meta=True)
    + transcript_line("user", [{"type": "text", "text": "Another Claude session sent a message:\n"
                                "from: demo-maintainer-web-pill-overflow-subagent-with-a-long-name\n\n"
                                f"Alex's go on {URL}\n{HASH}"}], "o-10", meta=True)
    + transcript_line("user", [{"type": "text", "text": task_notification(LONG_SUMMARY)}], "o-11")
    + queued_notification(f'Background command "sha256sum {TOKEN}" completed (exit code 0)', "o-12")
)
MSGS = 10  # the two tool results that matched a tool call land inside it and make no message of their own

WAIT = """
new Promise((res) => { const t0 = Date.now(); (function poll() {
  if (document.querySelectorAll("#chat > .msg").length >= %d || Date.now() - t0 > 15000)
    res(document.querySelectorAll("#chat > .msg").length); else setTimeout(poll, 100);
})(); })
""" % MSGS

# every element of the chat against the pane's edges; what sits inside a box that scrolls on its own (a code block)
# may run past the edge by design, and that box itself is checked
MEASURE = r"""
(() => {
  const pane = document.querySelector("#chat-pane"), pr = pane.getBoundingClientRect();
  const scroller = (e) => { const cs = getComputedStyle(e); return /auto|scroll/.test(cs.overflowX) && e.scrollWidth > e.clientWidth; };
  const bad = [];
  for (const e of document.querySelectorAll("#chat *")) {
    const r = e.getBoundingClientRect();
    if (!r.width && !r.height) continue;
    let p = e.parentElement, inside = false;
    while (p && p !== pane) { if (scroller(p)) { inside = true; break; } p = p.parentElement; }
    if (inside) continue;
    if (r.left < pr.left - 0.5 || r.right > pr.right + 0.5)
      bad.push({ tag: e.tagName.toLowerCase(), cls: e.className, left: Math.round(r.left), right: Math.round(r.right),
                 text: e.textContent.trim().slice(0, 50) });
  }
  const sums = [...document.querySelectorAll("#chat details.notice > summary .sum")].map((s) =>
    ({ text: s.textContent.slice(0, 30), clipped: s.scrollWidth > s.clientWidth + 1, h: s.getBoundingClientRect().height }));
  const pills = [...document.querySelectorAll("#chat .msg.user > details.notice")].map((d) => d.getBoundingClientRect().width);
  return { width: innerWidth, pane: [Math.round(pr.left), Math.round(pr.right)], bad, msgs: document.querySelectorAll("#chat > .msg").length,
           docScroll: document.documentElement.scrollWidth, paneScroll: pane.scrollWidth, paneClient: pane.clientWidth,
           pres: [...document.querySelectorAll("#chat .md pre")].map((p) => ({ ox: getComputedStyle(p).overflowX, scrollW: p.scrollWidth, clientW: p.clientWidth })),
           sums, pills, paneWidth: pr.width };
})()
"""


WIDTHS = ((320, 700, True), (360, 780, True), (390, 844, True), (430, 932, True), (1280, 800, False))
OPEN_ALL = '(() => { for (const d of document.querySelectorAll("#chat details")) d.open = true; document.body.classList.remove("hide-tools"); return 1; })()'


def measure(browser, w: int, h: int, mobile: bool) -> dict:
    browser.send("Emulation.setDeviceMetricsOverride", {"width": w, "height": h, "deviceScaleFactor": 1, "mobile": mobile})
    got = browser.evaluate(MEASURE)
    assert got["width"] == w and got["msgs"] == MSGS, got
    assert got["bad"] == [], f"at {w}px: {json.dumps(got['bad'], indent=1)}"
    assert got["docScroll"] <= w and got["paneScroll"] <= got["paneClient"], got
    # the reply's code block with the long line wraps inside its own box: no sideways scroll
    assert got["pres"] and all(p["scrollW"] <= p["clientW"] for p in got["pres"]), got["pres"]
    # a notice pill wraps its label instead of clipping it: nothing hidden, the long one on more than one line
    assert all(not s["clipped"] for s in got["sums"]), got["sums"]
    assert max(s["h"] for s in got["sums"]) > 1.5 * min(s["h"] for s in got["sums"]), got["sums"]
    assert max(got["pills"]) <= got["paneWidth"], got["pills"]
    return got


def test_long_chat_lines_stay_inside_the_pane_at_every_width(served, browser):
    transcript_file(served).write_text(LONG_TRANSCRIPT)
    browser.open(f"{served['url']}/#s={NAME}")
    assert browser.evaluate(WAIT) == MSGS
    # as the page opens: folds closed, tool calls hidden; a short pill keeps its own width (right-aligned, as before)
    for w, h, mobile in WIDTHS:
        got = measure(browser, w, h, mobile)
        assert min(got["pills"]) < got["paneWidth"] / 2, got["pills"]
    # every fold open and tool calls shown (an open fold is as wide as its body)
    browser.evaluate(OPEN_ALL)
    for w, h, mobile in WIDTHS:
        measure(browser, w, h, mobile)
