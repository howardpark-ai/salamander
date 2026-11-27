"""Send now (POST /api/s/<pid>/send-now): whether Claude Code's chord that sends the waiting messages at once, Ctrl+X Ctrl+S
(its action chat:sendNow), may be pressed in a session's pane. Nothing here touches a pane: a screen and a transcript go in, a refusal
(a sentence for the page) or None comes out.

Measured on Claude Code 2.1.332 in sessions made for the measurement (not a documented contract). The safe case: one step runs in the
foreground (a command, a subagent) and shows the hint that it can move to the background, the reply that asked for it is fully written,
and a message waits behind it. The chord then moves the step to the background, where it goes on, and Claude reads every waiting message.
An MCP tool shows no such hint, so it is refused although the chord would move it too. With a dialog open or with nothing waiting the
chord does nothing. It loses work or types something in these cases, so all of them are refused:

- text in the input line is submitted;
- a call that has not started is cancelled (a hook still runs before it, or it is a later call of the same reply). A reply still being
  written is refused for this reason: the chord cuts it, but a call that reply has already finished is in no transcript line yet and can
  be told from the running one by nothing on the screen;
- a running command is cancelled when background tasks are turned off (the screen then shows no hint to background it), and when a
  `!` command runs or waits in the queue;
- on the screen of one subagent (opened from the list under the input line) the subagent's own command is lost.

Both readings must agree. The screen: the input line empty, no dialog, "Queued · ctrl+x ctrl+s to send now" under the waiting messages
and the hint "(ctrl+b to run in background)" as the line just above them. The transcript: the latest reply is complete (stop_reason
"tool_use", which Claude Code writes only once the whole reply has come in) and exactly one of its calls has no result.
A screen or a line in any other shape is refused: another key bound to the action, another version's wording, a pane too narrow for
either line.
"""

from __future__ import annotations

import json
import os
import re
from pathlib import Path

from . import tmuxio as T

QUEUED_RE = re.compile(r"^\s*⎿\s+Queued · ctrl\+x ctrl\+s to send now$")   # ⎿ is the corner glyph under a message
# "ctrl+b ctrl+b (twice)" is how Claude Code words the hint inside a tmux whose prefix is Ctrl+B
HINT_RE = re.compile(r"^\s+\(ctrl\+b(?: ctrl\+b \(twice\))? to run in background\)$")
AGENT_BOX = "Message @"          # the empty input line of one subagent's screen
TAIL_BYTES = 4 << 20             # how much of the transcript's end is read for the latest reply

NOTHING = "nothing was pressed"
NO_QUEUED = f"the terminal shows no waiting message it can send now; {NOTHING}"
NO_STEP = f"no running step that can move to the background, so sending now could cancel it; {NOTHING}"
BANG = f"a ! command is running or waiting, and sending now would cancel the running step; {NOTHING}"
NOT_ONE_STEP = f"Claude is not on a single running step (it may still be writing its reply), so sending now could cancel one; {NOTHING}"
NO_TRANSCRIPT = f"the transcript cannot be read, so what is running is not known; {NOTHING}"
# by the reason the outbox's readiness check gives (outbox.REASONS)
NOT_READY = {
    "dialog": f"a dialog is open in the pane; {NOTHING}",
    "draft": f"the terminal's input line holds text, which sending now would submit; {NOTHING}",
    "noInput": f"the terminal shows no input line; {NOTHING}",
}
UNREADABLE = f"the session's pane cannot be read; {NOTHING}"


def screen_refusal(captured: str) -> str | None:
    """Why the chord must not be pressed on this screen (a capture with escape sequences), or None when the screen shows the safe case."""
    state, box_text = T.input_box(captured)
    if T.overlay(captured):
        return NOT_READY["dialog"]
    if state != "empty":
        return NOT_READY["draft" if state == "text" else "noInput"]
    if T.shell_mode(captured):
        return f"the input line is in ! mode; {NOTHING}"
    if box_text.startswith(AGENT_BOX):
        return f"the terminal shows a subagent's own screen, where sending now loses its command; {NOTHING}"
    lines = [T.plain(ln).replace("\xa0", " ").rstrip() for ln in T.above_box(captured)]
    queued = [i for i, ln in enumerate(lines) if QUEUED_RE.match(ln)]
    if len(queued) != 1:
        return NO_QUEUED
    if any(ln.startswith(T.SHELL + " ") for ln in lines[queued[0] + 1:]):
        return BANG
    # upward from the "Queued" line: the waiting messages (each starts "❯ " in the first column, its other lines are indented),
    # and directly above the first of them the running step's hint
    top = ""            # the highest non-blank line passed so far
    for i in range(queued[0] - 1, -1, -1):
        ln = lines[i]
        if HINT_RE.match(ln):
            if not top.startswith(T.PROMPT):
                return NO_STEP
            # the hint of a `!` command the owner runs reads the same: that command's echo is then the nearest turn above it
            turn = next((x for x in reversed(lines[:i]) if x.startswith((*T.TURN_GLYPHS, T.SHELL + " "))), "")
            return BANG if turn.startswith(T.SHELL) else None
        if ln.startswith(T.SHELL + " "):
            return BANG
        if ln and not ln.startswith((T.PROMPT, "  ")):
            return NO_STEP
        top = ln or top
    return NO_STEP


def transcript_refusal(path: Path | None) -> str | None:
    """Why the chord must not be pressed by what the transcript at `path` ends with, or None when its latest reply is complete and exactly
    one of that reply's calls has no result."""
    if path is None:
        return NO_TRANSCRIPT
    try:
        with open(path, "rb") as f:
            size = f.seek(0, os.SEEK_END)
            f.seek(max(0, size - TAIL_BYTES))
            raw = f.read()
    except OSError:
        return NO_TRANSCRIPT
    if not raw.endswith(b"\n"):
        return f"the transcript is being written; {NOTHING}"
    lines = raw.split(b"\n")
    if size > TAIL_BYTES:
        lines = lines[1:]                  # the first line is a part
    reply: object = None                   # the latest reply's message id
    calls: dict[str, object] = {}          # its calls' ids -> the stop_reason on the line that holds each
    done: set[str] = set()                 # the ids that have a result
    for ln in lines:
        try:
            d = json.loads(ln)
        except ValueError:
            continue
        if not isinstance(d, dict) or d.get("isSidechain") or d.get("type") not in ("assistant", "user"):
            continue
        m = d.get("message") if isinstance(d.get("message"), dict) else {}
        content = m.get("content")
        blocks = [b for b in content if isinstance(b, dict)] if isinstance(content, list) else []
        if d["type"] == "assistant":
            if m.get("id") != reply or reply is None:
                reply, calls = m.get("id"), {}
            calls.update({str(b.get("id")): m.get("stop_reason") for b in blocks if b.get("type") == "tool_use"})
            continue
        results = {str(b.get("tool_use_id")) for b in blocks if b.get("type") == "tool_result"}
        done |= results
        if not d.get("isMeta") and (not results or len(results) != len(content)):
            reply, calls = None, {}        # a prompt or an interrupt after the reply: that turn is over
    if any(stop != "tool_use" for stop in calls.values()) or len(set(calls) - done) != 1:
        return NOT_ONE_STEP
    return None
