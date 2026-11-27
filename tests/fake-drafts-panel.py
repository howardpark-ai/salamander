#!/usr/bin/env python3
"""The fake CLI's feedback drafts panel and exit gate (tests/fake-claude.c, FAKE_DRAFTS_PANEL), drawn with the real CLI's
words. Nothing leaves the machine: "sending" deletes the draft file and writes one line to the log.

  fake-drafts-panel.py panel <session>   what /feedback opens: the drafts list, a review, the send
  fake-drafts-panel.py gate <session>    what /exit meets when <session> has a queued draft

Exit code: 0 the CLI goes on (for `gate`, the exit proceeds); 1 never used by a panel the user closes.
The drafts are $HOME/.claude/feedback/drafts/*.json. Knobs (env):
  FAKE_PANEL_STYLE  choices (2.1.332: "Not now" / report only / with transcript; default) · toggle (up to 2.1.331:
                    "Send transcript: yes" above "Send feedback") · unknown (a review with neither)
  FAKE_TRANSCRIPT   1 the draft's transcript is available (default) · 0 it has expired
  FAKE_SEND         ok (default) · fail (the service is out of reach)
  FAKE_LONG         1 a review longer than the screen: choices style shows the choices after one Down; toggle style
                    shows them only in a window of 100 rows or more
  FAKE_DROP_ENTER   1 the first Enter on a send line is dropped
  FAKE_PANEL_LOG    "open|sent <title> transcript=yes|no|failed <title>|discard <title> <how>|dropped|closed" lines
"""
import glob
import json
import os
import select
import signal
import sys
import termios

mode, session = sys.argv[1], sys.argv[2]
env = os.environ.get
STYLE, SEND = env("FAKE_PANEL_STYLE", "choices"), env("FAKE_SEND", "ok")
TRANSCRIPT, LONG = env("FAKE_TRANSCRIPT", "1") == "1", env("FAKE_LONG") == "1"
DRAFTS = os.path.join(os.environ["HOME"], ".claude", "feedback", "drafts")
dropped = False


def log(line):
    if env("FAKE_PANEL_LOG"):
        with open(env("FAKE_PANEL_LOG"), "a") as f:
            f.write(line + "\n")


def queued():
    out = []
    for path in sorted(glob.glob(os.path.join(DRAFTS, "*.json"))):
        with open(path) as f:
            d = json.load(f)
        if d.get("status") == "queued":
            out.append((path, d))
    return out


screen = None          # draws the screen as it is now: run again when the window's size changes, as the CLI repaints


def draw(lines):
    """The panel at the screen's foot, under the transcript that fills the rest, as in a session that has worked a while."""
    lines = ["❯ /feedback", "▔" * 60] + lines
    above = ["  an earlier line of the transcript"] * max(os.get_terminal_size(1).lines - len(lines) - 1, 0)
    sys.stdout.write("\033[2J\033[H" + "\n".join(above + lines))
    sys.stdout.flush()


def show(fn, *args):
    global screen
    screen = lambda: fn(*args)
    screen()


signal.signal(signal.SIGWINCH, lambda *_: screen and screen())


def key():
    chunk = os.read(0, 1)
    if chunk == b"\x1b":
        while select.select([0], [], [], 0.05)[0]:
            chunk += os.read(0, 1)
            if len(chunk) >= 3:
                break
    names = {b"\r": "enter", b"\n": "enter", b"\x1b": "esc", b"\x1b[A": "up", b"\x1b[B": "down",
             b"\x1bOA": "up", b"\x1bOB": "down", b"\x1b[D": "left", b"\x1bOD": "left", b"d": "d"}
    return names.get(chunk, "other")


def listing(cursor, from_gate):
    rows = queued()
    out = ["  Feedback drafts"]
    if not rows:
        out.append("  No feedback drafts yet")
    for i, (_, d) in enumerate(rows):
        out.append("  %s %s   bug · 1m" % ("❯" if i == cursor else " ", d["title"]))
    if not from_gate:
        out.append("  %s + Write new feedback" % ("❯" if cursor == len(rows) else " "))
    out.append("  Enter to review · d to discard · Esc to close")
    draw(out)


def review(draft, focus, toggle, error, scrolled):
    """The review's lines. focus: 0.. over the rows the style has; toggle: the transcript's yes/no."""
    body = ["  Feedback drafts", "    Type: bug", "    Title:", "      " + draft["title"], "    Details:"]
    body += ["      │ line %d of a throwaway draft" % i for i in range(80 if LONG else 2)]
    if LONG and (not scrolled if STYLE == "choices" else os.get_terminal_size(1).lines < 100):
        room = max(os.get_terminal_size(1).lines - 4, 5)
        draw(body[:room] + ["      ↓"])
        return
    tail = ["    Environment info (linux x64) is always attached."]
    if error:
        tail += ["  ✘ Couldn't send feedback (couldn't reach the service).", "    The draft is still queued. Try again later."]
    mark = lambda i: "❯" if i == focus else " "
    if STYLE == "choices":
        tail += ["  %s Not now" % mark(0), "  %s Send feedback, report only" % mark(1)]
        if TRANSCRIPT:
            tail += ["  %s Send feedback with transcript" % mark(2), "      Sends this conversation to Anthropic"]
        else:
            tail += ["      The transcript has expired"]
        tail.append("  ↑/↓ to move · Enter to confirm · d to discard · Esc to go back")
    elif STYLE == "toggle":
        if not TRANSCRIPT:
            tail.append("    Send transcript: expired (report only)")
        else:
            word = "yes" if toggle else "no"
            note = "sends this conversation to Anthropic" if toggle else "report only"
            shown = "◀ %s ▶" % word if focus == 0 else word
            tail.append("  %s Send transcript: %s · %s" % (mark(0), shown, note))
        tail += ["  %s Send feedback" % mark(1), "  ↑/↓ to move · Enter to send · d to discard · Esc to later"]
    else:
        tail += ["  %s Maybe later" % mark(0), "  %s Share it" % mark(1), "  Esc to go back"]
    room = os.get_terminal_size(1).lines - len(tail) - 1
    draw((body[-room:] if len(body) > room else body) + tail)


def send(path, draft, with_transcript):
    """True when the panel goes on (receipt shown and a key taken), False on a failed send."""
    if SEND == "fail":
        log("failed " + draft["title"])
        return False
    log("sent %s transcript=%s" % (draft["title"], "yes" if with_transcript else "no"))
    os.unlink(path)
    show(draw, ["  Feedback drafts", "  ✔ Feedback sent (receipt 0a1b2c3d). Thanks!", "  Any key to continue"])
    key()
    return True


def one_review(path, draft):
    global dropped
    focus = 0 if STYLE == "choices" else 1
    toggle, error, scrolled = True, False, False
    last = {"choices": 2 if TRANSCRIPT else 1, "toggle": 1, "unknown": 1}[STYLE]
    while True:
        show(review, draft, focus, toggle, error, scrolled)
        k = key()
        if k == "esc":
            return
        if k == "d":
            os.unlink(path)
            log("discard %s d" % draft["title"])
            return
        if k == "up":
            scrolled, focus = True, max(focus - 1, 0 if (STYLE != "toggle" or TRANSCRIPT) else 1)
        elif k == "down":
            scrolled, focus = True, min(focus + 1, last)
        elif k in ("left", "other") and STYLE == "toggle" and focus == 0:
            toggle = False
        elif k == "enter":
            if LONG and STYLE == "choices" and not scrolled:
                scrolled = True
                continue
            sends = (STYLE == "choices" and focus > 0) or (STYLE != "choices" and focus == 1)
            if not sends:
                return
            if env("FAKE_DROP_ENTER") == "1" and not dropped:
                dropped = True
                log("dropped")
                continue
            with_transcript = focus == 2 if STYLE == "choices" else (TRANSCRIPT and toggle)
            if send(path, draft, with_transcript):
                return
            error, focus = True, (0 if STYLE == "choices" else 1)


def panel(from_gate):
    log("open")
    cursor = 0
    while True:
        show(listing, cursor, from_gate)
        k = key()
        rows = queued()
        if k == "esc":
            break
        if k == "enter" and cursor < len(rows):
            one_review(*rows[cursor])
            if not queued():
                break
        elif k == "d" and cursor < len(rows):
            os.unlink(rows[cursor][0])
            log("discard %s d" % rows[cursor][1]["title"])
    log("closed")


def gate():
    mine = [(p, d) for p, d in queued() if d.get("source_session_id") == session]
    if not mine:
        return
    while True:
        show(draw, ["  You have %d unsent feedback draft%s" % (len(mine), "" if len(mine) == 1 else "s"),
                    "  Enter to review & send · Esc to discard and exit"])
        k = key()
        if k == "enter":
            panel(True)
            return
        if k == "esc":
            for path, d in mine:
                os.unlink(path)
                log("discard %s gate" % d["title"])
            return


old = termios.tcgetattr(0)
raw = termios.tcgetattr(0)
raw[3] &= ~(termios.ICANON | termios.ECHO)
raw[6][termios.VMIN], raw[6][termios.VTIME] = 1, 0
try:
    termios.tcsetattr(0, termios.TCSANOW, raw)
    if mode == "gate":
        gate()
    else:
        panel(False)
finally:
    termios.tcsetattr(0, termios.TCSANOW, old)
    sys.stdout.write("\033[2J\033[H")
    sys.stdout.flush()
