"""The only tmux access sala-web has: read a pane (display, capture-pane), paste into it (load-buffer,
paste-buffer -p, send-keys Enter), answer a numbered dialog in it (send-keys of one digit, or Escape), and stop a running
`!` command (send-keys of Escape, then Ctrl-C), and, only when the page's Replace asks for it or the outbox finds text in the box, empty the input box of text
that is there (send-keys of Ctrl+U, End and Delete: clear_box).

Nothing here kills, renames or restarts a session, window or pane. The one thing it creates is the Shell drawer's own tmux
session, `sala-shell` (sala's SALA_SHELL_SESSION) (ensure_shell_session): a plain login bash, never a Claude pane, and the one place
send_shell_key sends keys to (from a fixed list of key names, never text).

Image paths go in by bracketed paste (paste-buffer -p): the step-0 probe showed Claude Code turns a pasted image
path into an "[Image #N]" chip, while the same path typed with send-keys -l stays raw text.
"""

from __future__ import annotations

import asyncio
import os
import re
import secrets
import string
import weakref

from .config import SHELL_SESSION, Settings

PANE_RE = re.compile(r"^%\d+$")
CSI_RE = re.compile(r"\x1b\[([0-9;:?]*)([A-Za-z])")
OSC_RE = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")
OTHER_ESC_RE = re.compile(r"\x1b[()][A-Za-z0-9]|\x1b[=>78]")
PROMPT = "❯"  # ❯
SHELL = "!"  # the box's first glyph after "!" is typed: Claude Code's shell mode draws "!" where "❯" stood
BOX_GLYPHS = (PROMPT, SHELL)
RULE_CHAR = "─"  # ─
CHIP_RE = re.compile(r"\[Image #\d+\]")
# the label Claude Code draws in the rule above an input box that holds more lines than it shows ("──── ↑ 1 more ────"):
# its first glyph line has scrolled out of view, and a "↓ N more" label shows in the rule below when the tail is cut off
MORE_ABOVE_RE = re.compile(r"\u2191\s*\d+\s+more\b")
MORE_BELOW_RE = re.compile(r"\u2193\s*\d+\s+more\b")
OPTION_RE = re.compile(r"^(?:" + PROMPT + r"\s*)?([1-9])\.\s+\S")
BOX_SIDES = "│┃|"  # a dialog drawn inside a box: its side borders are not part of the text
DIALOG_KEYS = {str(d) for d in range(1, 10)} | {"Escape"}
MULTI_KEYS = {"Down", "Enter"}  # a multi-select question's own keys (the answer to a card): Down to reach its Submit row, Enter on it
SETTLE_S = 0.15  # the wait after a key for the pane to draw it, before the screen is read again
STOP_KEY = "C-c"  # the second key of Stop (Escape is the first): only the Stop endpoint sends it
# the keys the Shell drawer's key row may send to the shell session (tmux key names): the phone's row (Esc, Tab, Ctrl, the
# arrows, Ctrl+C) and the Ctrl-letter a sticky Ctrl turns a typed letter into. Never free text: send-keys without -l would read
# a longer string as a key name or as literal text, so only these exact names pass.
SHELL_KEYS = frozenset({"Escape", "Tab", "Up", "Down", "Left", "Right", "Enter", "BSpace"}
                       | {f"C-{c}" for c in string.ascii_lowercase})
LIVE_LINES = 40   # the most lines of a running command's screen the chat shows
LIVE_LINE_CHARS = 400
# a spinner / status line Claude Code draws under a running command: "✻ Running… (12s · esc to interrupt)"
STATUS_RE = re.compile(r"esc to interrupt|ctrl\+c to (?:interrupt|cancel|stop)|^[✻✶✳✢✽·*●⏺]\s*\S+…(?:\s*\(.*\))?$", re.I)


# What Claude Code 2.1.312 draws while a `!` command runs (a real-pane check): the command's echo "! <command>",
# its output folded to a few lines, "+14 lines (18s)", "(ctrl+b ctrl+b (twice) to run in background)", and, under the input
# box that stays on screen, a footer with "esc to interrupt". The transcript has no record of the command until it ends.
INTERRUPT_RE = re.compile(r"esc to interrupt", re.I)
BG_HINT_RE = re.compile(r"ctrl\+b.*run in background", re.I)
# the elapsed-time line Claude Code 2.1.312 draws under a running `!` command, whole line after the "⎿" glyph and the
# indent are dropped: "+14 lines (18s)" after output, a bare "(4s)" after short output, "Running… (3s)" for a quiet one
FOLD_TIMER_RE = re.compile(r"^(?:\+\d+ lines? )?(?:Running… )?\((?:\d+h )?(?:\d+m )?\d+s\)$")
BANG_ECHO_RE = re.compile(r"^!\s+(\S.*)$")  # the echo is at column 0
TURN_GLYPHS = ("●", "⏺", "❯")  # a line at column 0 that starts with one begins a reply, a tool call or a prompt of the owner's


class TmuxError(RuntimeError):
    pass


async def run_tmux(settings: Settings, *args: str, stdin: bytes | None = None, timeout: float = 10) -> str:
    cmd = ["tmux"]
    if settings.tmux_socket_name:
        cmd += ["-L", settings.tmux_socket_name]
    cmd += list(args)
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdin=asyncio.subprocess.PIPE if stdin is not None else asyncio.subprocess.DEVNULL,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    out, err = await asyncio.wait_for(proc.communicate(stdin), timeout=timeout)
    if proc.returncode != 0:
        raise TmuxError(f"tmux {args[0]}: {err.decode(errors='replace').strip() or proc.returncode}")
    return out.decode(errors="replace")


_shell_locks: "weakref.WeakKeyDictionary[asyncio.AbstractEventLoop, asyncio.Lock]" = weakref.WeakKeyDictionary()


def _shell_lock() -> asyncio.Lock:
    """The shell lock of the running event loop, made on first use: one lock shared by two loops (a test's, a reload's) would
    be bound to the first."""
    loop = asyncio.get_running_loop()
    lock = _shell_locks.get(loop)
    if lock is None:
        lock = _shell_locks[loop] = asyncio.Lock()
    return lock


async def ensure_shell_session(settings: Settings) -> bool:
    """Make sure the Shell drawer's tmux session exists; True when this call created it. ttyd-tmux-attach only
    attaches to a session that is already there (otherwise it asks), so this is called when sala-web starts (app.bring_up_shell, only
    when a tmux server answers), by `POST /api/shell/open` (the drawer before its iframe loads, the full-size page before its frame
    when ?arg is the Shell session). Only the one configured name is ever made here, never another a page asks for. The
    session is a plain login bash in the home directory: `new-session -d -s <SALA_SHELL_SESSION> -c ~ bash -l`. An existing session is
    never restarted or sent anything (`=` makes the name an exact match); both paths only set its window option `scroll-on-clear off`.
    Two calls at once, or a second sala-web, are safe: the loser of the race
    sees "duplicate session" and re-checks."""
    async with _shell_lock():
        if await _has_session(settings, SHELL_SESSION):
            await _shell_scroll_on_clear_off(settings)
            return False
        try:
            await run_tmux(settings, "new-session", "-d", "-s", SHELL_SESSION, "-c", os.path.expanduser("~"), "bash", "-l")
        except TmuxError:
            if await _has_session(settings, SHELL_SESSION):
                await _shell_scroll_on_clear_off(settings)
                return False
            raise
        await _shell_scroll_on_clear_off(settings)
        return True


async def server_running(settings: Settings) -> bool:
    """True when a tmux server answers on this app's socket. `new-session` would start one, so a caller that must not start a
    server (sala-web's own start-up, which would otherwise bring up a bare tmux server ahead of sala's restore) asks first."""
    try:
        await run_tmux(settings, "list-sessions", "-F", "#{session_name}")
    except TmuxError:
        return False
    return True


async def _shell_scroll_on_clear_off(settings: Settings) -> None:
    """Turn `scroll-on-clear` off on the Shell session's window (this session only; the global tmux config is not touched).
    Why: the Shell's `bash -l` loads ble.sh, which redraws its prompt with `\\r\\e[J` on every terminal resize. With the prompt on
    the pane's top row, tmux 3.6 takes that `\\e[J` at home for a full clear and, with the default `scroll-on-clear on`, pushes
    the screen into scrollback; ttyd resizes on attach and the drawer on every height change, so stray bare-prompt lines pile
    up in the history and show when a drag-select scrolls into copy mode. The cost: `clear` in the Shell no longer keeps the
    old screen in scrollback. Setting an option is idempotent, so every ensure call does it, which also reaches a Shell that
    is already running. A tmux without the option refuses it; that is ignored."""
    try:
        await run_tmux(settings, "set-option", "-w", "-t", "=" + SHELL_SESSION + ":", "scroll-on-clear", "off")
    except TmuxError:
        pass


async def _has_session(settings: Settings, name: str) -> bool:
    try:
        await run_tmux(settings, "has-session", "-t", "=" + name)
    except TmuxError:
        return False
    return True


async def send_shell_key(settings: Settings, key: str) -> None:
    """One key from SHELL_KEYS into the Shell session's active pane, and nowhere else. Nothing outside the list is sent."""
    if key not in SHELL_KEYS:
        raise TmuxError(f"refusing to send key {key!r}")
    if not await _has_session(settings, SHELL_SESSION):
        raise TmuxError("the shell is not running")
    await run_tmux(settings, "send-keys", "-t", "=" + SHELL_SESSION + ":", key)


def _check_pane(pane: str) -> None:
    if not PANE_RE.match(pane or ""):
        raise TmuxError(f"bad pane id {pane!r}")


async def pane_pid(settings: Settings, pane: str) -> int:
    _check_pane(pane)
    out = await run_tmux(settings, "display-message", "-p", "-t", pane, "#{pane_id} #{pane_pid}")
    parts = out.split()
    # display-message on a missing pane can print nothing and still exit 0
    if len(parts) != 2 or parts[0] != pane or not parts[1].isdigit():
        raise TmuxError(f"no pane {pane} on this tmux server")
    return int(parts[1])


async def capture(settings: Settings, pane: str) -> str:
    _check_pane(pane)
    return await run_tmux(settings, "capture-pane", "-e", "-p", "-t", pane)


async def paste(settings: Settings, pane: str, text: str) -> None:
    """Bracketed paste of text into the pane, through a uniquely named buffer that paste-buffer -d deletes."""
    _check_pane(pane)
    buf = f"sala-web-{secrets.token_hex(6)}"
    await run_tmux(settings, "load-buffer", "-b", buf, "-", stdin=text.encode())
    await run_tmux(settings, "paste-buffer", "-p", "-d", "-b", buf, "-t", pane)


async def send_enter(settings: Settings, pane: str) -> None:
    _check_pane(pane)
    await run_tmux(settings, "send-keys", "-t", pane, "Enter")


async def send_key(settings: Settings, pane: str, key: str) -> None:
    """One keypress into the pane: a digit 1-9 (Claude Code's selection dialogs pick that option at once, no Enter),
    Escape (cancel), Down or Enter (a multi-select question's, MULTI_KEYS), or Ctrl-C (the Stop button's second key).
    Nothing else is ever sent this way."""
    _check_pane(pane)
    if key not in DIALOG_KEYS and key not in MULTI_KEYS and key != STOP_KEY:
        raise TmuxError(f"refusing to send key {key!r}")
    await run_tmux(settings, "send-keys", "-t", pane, key)


def _visible_runs(line: str) -> list[tuple[str, bool]]:
    """Split a captured line (capture-pane -e) into (text, dim) runs, dropping escape sequences.

    Claude Code draws its placeholder with the cursor on the first character: that cell is reverse video and the rest
    is dim (tmux writes the change as ESC[0;2m). A reverse-video run right before a dim run is the first character of
    that dim text, so it is returned as dim; a cursor after or inside typed text is not followed by dim text and stays
    typed.
    """
    line = OSC_RE.sub("", line)
    line = OTHER_ESC_RE.sub("", line)
    raw: list[tuple[str, bool, bool]] = []
    dim = False
    rev = False
    pos = 0
    for m in CSI_RE.finditer(line):
        if m.start() > pos:
            raw.append((line[pos:m.start()], dim, rev))
        pos = m.end()
        if m.group(2) != "m":
            continue
        params = m.group(1).replace(":", ";").split(";") if m.group(1) else [""]
        k = 0
        while k < len(params):
            p = params[k]
            if p in ("", "0"):
                dim = rev = False
            elif p == "22":
                dim = False
            elif p == "2":
                dim = True
            elif p == "7":
                rev = True
            elif p == "27":
                rev = False
            elif p in ("38", "48", "58"):
                if k + 1 < len(params) and params[k + 1] == "5":
                    k += 2
                elif k + 1 < len(params) and params[k + 1] == "2":
                    k += 4
            k += 1
    if pos < len(line):
        raw.append((line[pos:], dim, rev))
    return [(t, d or (r and i + 1 < len(raw) and raw[i + 1][1])) for i, (t, d, r) in enumerate(raw)]


def plain(line: str) -> str:
    return "".join(t for t, _ in _visible_runs(line))


RULE_LABEL_MAX = 40       # the longest label with spaces in it (a label like "↑ 1 more", or a short name)
RULE_NAME_MAX = 64        # the longest label that is one word, which is how a session name reads
RULE_LABELS_MAX = 3       # "↑ N more" and the session name are what Claude Code draws; one spare
RULE_GAP_RE = re.compile(RULE_CHAR + "{2,}")


def _is_rule(line: str) -> bool:
    """A horizontal rule: mostly rule characters, or a run of them, one or more labels, and rule characters again.

    Claude Code draws labels inside the rule of the input box: the session name ("──── name ─────"), and, on the top
    rule of a box that has scrolled, "↑ N more" in front of it ("──── ↑ 1 more ──── name ──"). A long name or a narrow
    pane leaves far less than the 60% of rule characters a plain rule needs (a 25-character name at 80 columns leaves
    about 20%), and the pane can draw a single rule character after the last label ("───────── example-main ─").
    So a line counts too when it starts with a run of 3 or more rule characters, ends with 1 or more, and between
    them holds up to three labels set off by spaces and separated by runs of 2 or more rule characters. A label is
    either at most 40 characters or a single word of at most 64 (a session name; prose has spaces). Rule characters
    must be at least 40% of the line around one label and at least 10% around several (the labels take most of the
    width there), and the whole line at least 10 characters.
    """
    s = plain(line).replace("\u00a0", " ").strip()
    if len(s) < 10:
        return False
    n = s.count(RULE_CHAR)
    if n >= 0.6 * len(s):
        return True
    lead = len(s) - len(s.lstrip(RULE_CHAR))
    trail = len(s) - len(s.rstrip(RULE_CHAR))
    if lead < 3 or trail < 1:
        return False
    labels = RULE_GAP_RE.split(s[lead:len(s) - trail])
    if len(labels) > RULE_LABELS_MAX or n < (0.4 if len(labels) == 1 else 0.1) * len(s):
        return False
    for label in labels:
        word = label.strip()
        if label[:1] != " " or label[-1:] != " " or not word:
            return False
        if len(word) > RULE_LABEL_MAX and (len(word) > RULE_NAME_MAX or word.split() != [word]):
            return False
    return True


def _glyph(line: str) -> str | None:
    """The box glyph a line starts with (❯, or ! in shell mode), or None."""
    t = plain(line).replace("\u00a0", " ").lstrip()
    return next((g for g in BOX_GLYPHS if t.startswith(g)), None)


def _box(lines: list[str], rule_idx: list[int]):
    """Yield (first, bottom, glyph) for each candidate input box, last one first: a rule, then a line starting with a
    box glyph; bottom is the next rule after it, or None (never for a shell-mode box).

    A box that holds more lines than it shows has scrolled its glyph line out of view: its top rule then carries an
    "↑ N more" label and the first visible line is a continuation line with no glyph. That is a box too, when a bottom
    rule closes it with at least one line between; its glyph is None. A label like that over no closing rule is not
    a box, nor is any other label."""
    for top in reversed(rule_idx):
        first = top + 1
        if first >= len(lines):
            continue
        if MORE_ABOVE_RE.search(plain(lines[top])):
            bottom = next((i for i in rule_idx if i > top), None)
            if bottom is not None and bottom > first:
                yield first, bottom, None
            continue
        glyph = _glyph(lines[first])
        if not glyph:
            continue
        bottom = next((i for i in rule_idx if i > first), None)
        if glyph == SHELL and bottom is None:
            continue  # the footer hint "! for bash mode" under every empty box starts with "!", a box needs its bottom rule
        yield first, bottom, glyph


def _used_box(lines: list[str]):
    """(first, bottom, glyph) of the input box input_box reads: the last candidate box that has a bottom rule, or None."""
    rule_idx = [i for i, ln in enumerate(lines) if _is_rule(ln)]
    return next(((first, bottom, glyph) for first, bottom, glyph in _box(lines, rule_idx) if bottom is not None), None)


def input_box(captured: str) -> tuple[str, str]:
    """Find Claude Code's input box (a line starting with ❯, or ! in shell mode, between two horizontal rules) and
    say whether it holds text. Dim text is the placeholder suggestion and counts as empty. A box scrolled past its
    glyph line (its top rule says "↑ N more") has no glyph line to find: it holds text by definition, and its visible
    text is the lines between its two rules.

    Returns ("empty" | "text" | "missing", the box's visible text).
    """
    lines = captured.split("\n")
    used = _used_box(lines)
    if used is None:
        return "missing", ""
    first, bottom, glyph = used
    content_chars: list[str] = []
    all_text: list[str] = []
    for i in range(first, bottom):
        runs = _visible_runs(lines[i])
        if i == first and glyph:
            # drop everything up to and including the prompt glyph
            seen = False
            kept: list[tuple[str, bool]] = []
            for t, d in runs:
                if not seen and glyph in t:
                    t = t.split(glyph, 1)[1]
                    seen = True
                elif not seen:
                    continue
                kept.append((t, d))
            runs = kept
        for t, d in runs:
            all_text.append(t)
            if not d:
                content_chars.append(t)
        all_text.append("\n")
    visible = "".join(content_chars).replace(" ", " ").strip()
    # a scrolled box (no glyph) always holds text: its glyph line is out of view and "↑ N more" says so
    return ("text" if visible or glyph is None else "empty"), "".join(all_text).replace(" ", " ").strip()


def _box_rows(captured: str) -> tuple[str, ...]:
    """The rows between the input box's rules as plain text, trailing spaces dropped: what clear_box compares to see whether a
    key changed the box. input_box's text strips the blank line a Ctrl+U leaves behind, so it cannot tell that key from none."""
    lines = captured.split("\n")
    used = _used_box(lines)
    if used is None:
        return ()
    first, bottom, _ = used
    return tuple(plain(ln).replace("\u00a0", " ").rstrip() for ln in lines[first:bottom])


def shown_text(box_text: str) -> str:
    """The text input_box read, as the page shows it and as Replace echoes it back: the two spaces Claude Code indents every
    line after the first with (they sit under the "\u276f ") are dropped, so the lines read as the owner typed them."""
    first, *rest = box_text.split("\n")
    return "\n".join([first, *(ln[2:] if ln.startswith("  ") else ln for ln in rest)])


RETRY_MIN_PARTIAL = 12  # characters a part of the retried message must have to count as the message


def box_hidden(captured: str) -> tuple[bool, bool]:
    """(above, below): whether the input box input_box reads has lines out of view. above is true when its top rule
    says "↑ N more" (its first lines have scrolled out), below when its bottom rule says "↓ N more" (its last lines are
    cut off). Both are read from the rules of that very box, never from another rule in the pane; (False, False) when
    there is no box."""
    lines = captured.split("\n")
    used = _used_box(lines)
    if used is None:
        return False, False
    first, bottom, _ = used
    return (bool(MORE_ABOVE_RE.search(plain(lines[first - 1]))),
            bool(MORE_BELOW_RE.search(plain(lines[bottom]))))


def retry_matches(box_text: str, message: str, above: bool = False, below: bool = False) -> bool:
    """True when the input box's visible text is the message being retried. A box that shows all of its text must
    equal the message. A part counts only on the side the box says is hidden (above and below come from box_hidden):
    with only "↑ N more" the text may be the message's tail, with only "↓ N more" its head, with both a slice of it
    (contained in it); a part must have at least RETRY_MIN_PARTIAL characters. Whitespace is ignored: the pane wraps
    lines at its own width, in the middle of a word when the word is longer than the line, and indents the lines it
    continues."""
    box, msg = "".join(box_text.split()), "".join(message.split())
    if not box or not msg:
        return False
    if box == msg:
        return True
    if len(box) < RETRY_MIN_PARTIAL:
        return False
    if above and below:
        return box in msg
    if above:
        return msg.endswith(box)
    if below:
        return msg.startswith(box)
    return False


def shell_mode(captured: str) -> bool:
    """True when the last input box is in shell mode (its first glyph is !, not ❯)."""
    lines = captured.split("\n")
    rule_idx = [i for i, ln in enumerate(lines) if _is_rule(ln)]
    for _first, bottom, glyph in _box(lines, rule_idx):
        if bottom is not None:
            return glyph == SHELL
    return False


def count_chips(captured: str) -> int:
    lines = captured.split("\n")
    rule_idx = [i for i, ln in enumerate(lines) if _is_rule(ln)]
    for first, bottom, _glyph_ in _box(lines, rule_idx):
        bottom = len(lines) if bottom is None else bottom
        return len(CHIP_RE.findall("\n".join(plain(ln) for ln in lines[first:bottom])))
    return 0


def dialog(captured: str) -> tuple[list[str], str]:
    """Find a numbered selection dialog in the pane: Claude Code's permission prompts and menus draw "❯ 1. Yes" on
    the focused option and "  2. No" on the others, below a horizontal rule.

    The options are the run 1, 2, 3... that holds the last focused line, below the last rule above it. Returns (the
    option numbers as strings, the dialog's visible text, which tells one dialog from the next), or ([], "").
    """
    raw = captured.split("\n")
    lines = [plain(ln).replace("\u00a0", " ").strip().strip(BOX_SIDES).strip() for ln in raw]
    focused = next((i for i in range(len(lines) - 1, -1, -1)
                    if lines[i].startswith(PROMPT) and OPTION_RE.match(lines[i])), None)
    if focused is None:
        return [], ""
    top = next((i for i in range(focused - 1, -1, -1) if _is_rule(raw[i])), -1) + 1
    options: list[str] = []
    first = last = -1
    for i in range(top, len(lines)):
        m = OPTION_RE.match(lines[i])
        if not m:
            continue
        n = m.group(1)
        if n == str(len(options) + 1):
            options.append(n)
            first = i if n == "1" else first
            last = i
        elif i <= focused:
            # the count broke above the focused line: what came before was a list, not this dialog
            options, first, last = (["1"], i, i) if n == "1" else ([], -1, -1)
        else:
            break
    if not options or not first <= focused <= last:
        return [], ""
    text = "\n".join(ln.replace(PROMPT, " ").strip() for ln in lines[top:last + 1] if ln)
    return options, text


CHECK_ROW_RE = re.compile(r"^(?:" + PROMPT + r"\s*)?([1-9])\.\s+\[([ ✔xX])\]\s*(\S.*)$")   # "1. [ ] Alpha", "2. [✔] Beta"
SUBMIT_ROW_RE = re.compile(r"^(?:" + PROMPT + r"\s*)?Submit$")
FREE_TEXT_LABEL = "Type something"   # the multi-select question's last row: the free-text answer, which a button cannot give


def multi_dialog(captured: str) -> dict | None:
    """The multi-select question Claude Code draws in the pane (AskUserQuestion with several answers allowed), or None. Its options are rows
    "1. [ ] Alpha" ("[✔]" once chosen) with their descriptions under them, the last row being "Type something" (the free-text answer), and a row
    "Submit" under them; the focus mark sits on one of those rows. A digit toggles that option, Down moves the focus a row, and Enter on Submit goes
    on to the answers' review (a numbered dialog of its own). Read from panes of Claude Code 2.1.332 (tests/fixtures/capture-ask-multi*.txt).

    Returns {"rows": [{"n", "label", "description", "checked", "focused"}], "focus": the focused row's number, "submit", or None, "title": the
    words above the rows, "text": the dialog's text}: the rows are the run 1, 2, 3... that ends right above the Submit row, below the last rule
    above it. None for any other screen."""
    raw = captured.split("\n")
    lines = [plain(ln).replace("\u00a0", " ").strip().strip(BOX_SIDES).strip() for ln in raw]
    submit = next((i for i in range(len(lines) - 1, -1, -1) if SUBMIT_ROW_RE.match(lines[i])), None)
    if submit is None:
        return None
    top = next((i for i in range(submit - 1, -1, -1) if _is_rule(raw[i])), -1) + 1
    rows: list[dict] = []
    first = submit
    for i in range(top, submit):
        m = CHECK_ROW_RE.match(lines[i])
        if m:
            if m.group(1) != str(len(rows) + 1):
                return None
            first = min(first, i)
            rows.append({"n": len(rows) + 1, "label": m.group(3).strip(), "description": "", "checked": m.group(2) != " ",
                         "focused": lines[i].startswith(PROMPT)})
        elif rows and lines[i]:
            rows[-1]["description"] = (rows[-1]["description"] + " " + lines[i]).strip()
    if len(rows) < 2:      # a real one holds an option and the free-text row at least
        return None
    focus = "submit" if lines[submit].startswith(PROMPT) else next((r["n"] for r in rows if r["focused"]), None)
    return {"rows": rows, "focus": focus, "title": "\n".join(ln for ln in lines[top:first] if ln and ln[0] not in "←→"),   # not the tab bar ("← ☐ Pick ✔ Submit →")
            "text": "\n".join(ln.replace(PROMPT, " ").strip() for ln in lines[top:submit + 1] if ln)}


def card(captured: str) -> dict | None:
    """What the page draws as a card with buttons for the question or dialog the pane shows, or None (nothing is drawn then).
    {"kind": "choice" | "multi", "text": the dialog's words (an answer names them to say which dialog it is for), "title": the words above
    the options, "options": [{"n", "label", "description", "checked"}], "focus"}. Only a screen where overlay() says something sits over the
    prompt box counts, so a numbered line of the conversation is never a card. The free-text row of a multi-select question is left out:
    a button cannot type."""
    if not overlay(captured):
        return None
    m = multi_dialog(captured)
    if m is not None:
        options = [{k: r[k] for k in ("n", "label", "description", "checked")} for r in m["rows"] if r["label"] != FREE_TEXT_LABEL]
        return {"kind": "multi", "text": m["text"], "title": m["title"], "options": options, "focus": m["focus"]} if options else None
    numbers, text = dialog(captured)
    if not numbers:
        return None
    head: list[str] = []
    options: list[dict] = []
    for ln in text.split("\n"):
        found = OPTION_RE.match(ln)
        if found and found.group(1) == str(len(options) + 1):
            options.append({"n": len(options) + 1, "label": ln.split(".", 1)[1].strip(), "description": "", "checked": False})
        elif options:
            options[-1]["description"] = (options[-1]["description"] + " " + ln).strip()
        else:
            head.append(ln)
    if len(options) != len(numbers):
        return None
    return {"kind": "choice", "text": text, "title": "\n".join(head), "options": options, "focus": None}


# What Claude Code 2.1.332 draws in the last line of the screen when something sits over the prompt box and a key goes to it, not
# to the box (a real-pane check): the model picker (Alt+P) "... Enter to save · Esc to cancel", the prompt history search (Ctrl+R)
# "ctrl+s to change scope · Esc to cancel", the detailed transcript (Ctrl+O) "Showing detailed transcript · ctrl+o to toggle ...".
# The prompt box's own footer never says either, so the last two non-blank lines (a footer wrapped on a narrow pane runs onto two)
# are the only place looked in: a line quoted higher up the conversation is not an overlay.
OVERLAY_FOOTER_RE = re.compile(r"Esc\s+to\s+cancel\s*$|Showing\s+detailed\s+transcript\b")


def overlay(captured: str) -> bool:
    """True when the screen positively shows something over the prompt box that would take an Enter instead of it: a numbered
    dialog with nothing drawn below it (the model picker is one; a numbered line in the conversation above a prompt box, such
    as the owner's own "1. fix this", has the box's rules below it and is not), or the footer of a picker, the history search
    or the transcript view (OVERLAY_FOOTER_RE). False for everything else, a screen where no prompt box can be found
    included: the pane's mod says what the box holds, the screen only refuses."""
    raw = captured.split("\n")
    lines = [plain(ln).replace("\u00a0", " ").strip() for ln in raw]
    tail = [ln for ln in lines if ln][-2:]
    if OVERLAY_FOOTER_RE.search(" ".join(tail)):
        return True
    if multi_dialog(captured) is not None:
        return True
    if not dialog(captured)[0]:
        return False
    focused = next((i for i in range(len(lines) - 1, -1, -1)
                    if lines[i].strip(BOX_SIDES).strip().startswith(PROMPT) and OPTION_RE.match(lines[i].strip(BOX_SIDES).strip())), None)
    return focused is not None and not any(_is_rule(raw[i]) for i in range(focused + 1, len(raw)))


def _is_timer(line: str) -> bool:
    """True for the elapsed-time line of a running command ("+14 lines (18s)", "(4s)", "Running… (3s)"), whatever
    indent or "⎿" glyph it carries: it ticks every second, so it marks the command and is never part of its text."""
    return bool(FOLD_TIMER_RE.match(line.strip().lstrip("⎿").strip()))


def bang_pane(captured: str, max_lines: int = LIVE_LINES) -> dict | None:
    """The running `!` command the pane shows, as {"command", "text"}, or None.

    A `!` command leaves nothing in the transcript until it ends and the pane keeps its input box, so the pane is the
    only place to tell. It is running when all of these hold: (1) above the input box (the whole screen when there is
    none) the nearest line that starts a turn at column 0 is the command's echo, "! <command>" (a reply "●", a tool call
    "⏺" or a prompt "❯" nearer than any echo means something else is on screen: a model's own Bash call shows the same
    "ctrl+b … run in background" hint and ends up here); (2) under the echo there is the background hint or the fold
    counter "+N lines (Ns)", a bare "(Ns)" or "Running… (Ns)" (a finished command shows neither: its fold ends in "(ctrl+o to expand)"); (3) "esc to
    interrupt" is on the screen under the echo (the footer, or a status line).

    text is what the command printed: the lines between the echo and the input box, without the hint, the elapsed-time
    line and status lines (the counter ticks every second and would make every capture a change), the "⎿" glyph, the common
    indent and the blank lines at both ends; the last max_lines lines, each cut at LIVE_LINE_CHARS."""
    raw = captured.split("\n")
    lines = [plain(ln).replace(" ", " ").rstrip() for ln in raw]
    box = next(_box(raw, [i for i, ln in enumerate(raw) if _is_rule(ln)]), None)
    end = max(box[0] - 1, 0) if box else len(lines)  # the rule above the input box
    echo, command = None, ""
    for i in range(end - 1, -1, -1):
        m = BANG_ECHO_RE.match(lines[i])
        if m:
            echo, command = i, m.group(1).strip()
            break
        if lines[i].startswith(TURN_GLYPHS):
            return None
    if echo is None:
        return None
    body = lines[echo + 1:end]
    if not any(BG_HINT_RE.search(ln) or _is_timer(ln) for ln in body):
        return None
    if not any(INTERRUPT_RE.search(ln) for ln in lines[echo + 1:]):
        return None
    kept = [ln for ln in body if not (BG_HINT_RE.search(ln) or _is_timer(ln) or STATUS_RE.search(ln.strip()))]
    kept = [re.sub(r"^(\s*)⎿", r"\1 ", ln) for ln in kept]  # the glyph becomes a blank: the first line keeps its column
    indent = min((len(ln) - len(ln.lstrip()) for ln in kept if ln.strip()), default=0)
    kept = [ln[indent:] for ln in kept]
    while kept and not kept[-1].strip():
        kept.pop()
    while kept and not kept[0].strip():
        kept.pop(0)
    return {"command": command, "text": "\n".join(ln[:LIVE_LINE_CHARS] for ln in kept[-max_lines:])}


def live_text(captured: str, command: str = "", max_lines: int = LIVE_LINES) -> str:
    """For a pane with no input box (the fallback for a transcript that does record the command; bang_pane is the
    detection for a Claude Code that keeps its box): the part of a pane's screen worth showing while a `!` command runs: plain text (escape sequences dropped), the part
    below the command's echo (the last line that holds the command's first line; the whole screen when none does), without
    the trailing blank lines, the input area's rules and the footer under them, or the spinner and status lines
    Claude Code draws under the command; at most max_lines lines, the last ones, each cut at LIVE_LINE_CHARS."""
    lines = [plain(ln).replace("\u00a0", " ").rstrip() for ln in captured.split("\n")]
    raw = captured.split("\n")
    first = " ".join(command.split("\n", 1)[0].split())[:60]
    if first:
        echo = next((i for i in range(len(lines) - 1, -1, -1) if first in " ".join(lines[i].split())), None)
        if echo is not None:
            lines, raw = lines[echo + 1:], raw[echo + 1:]
    # the input area's rules and the footer under them (at most 8 lines from the bottom) are not the command's output;
    # a rule higher up is the command's own
    tail = next((i for i, ln in enumerate(raw) if len(raw) - i <= 8 and _is_rule(ln)), None)
    if tail is not None:
        lines = lines[:tail]
    lines = [ln for ln in lines if not STATUS_RE.search(ln.strip())]
    while lines and not lines[-1].strip():
        lines.pop()
    while lines and not lines[0].strip():
        lines.pop(0)
    return "\n".join(ln[:LIVE_LINE_CHARS] for ln in lines[-max_lines:])


# --- clearing the input box (the page's Replace) ----------------------------------------------------------------------------
# Measured on Claude Code 2.1.330 and again on 2.1.332 (a one-, two- and three-line paste emptied by clear_box) in a pane of its own (private tmux socket, isolated HOME, nothing submitted): Ctrl+U deletes
# from the cursor to the start of its line, and at a line's start it deletes the newline before it, so it clears a box of N
# lines from the end in 2N-1 presses and Backspace adds nothing; End moves the cursor to the end of its line, and Delete
# removes what lies after the cursor. A paste of four lines or more is one "[Pasted text #1 +3 lines]" chip, which one Ctrl+U
# removes. Ctrl+C would clear the box in one key but also stops a running turn, and on a box already empty it arms "Press Ctrl-C
# again to exit"; a double Escape did not clear it in the same measurement. So neither is used.
EDIT_KEYS = frozenset({"C-u", "End", "Delete"})
CLEAR_MAX_KEYS = 120       # the keys one clear may send in all; past it the box is reported as not cleared
CLEAR_SETTLE = 0.06        # seconds a redraw gets before the box is read after a key
CLEAR_STALL_SETTLE = 0.15  # the second look at a box that did not change, before the key is judged to have done nothing
# the keys tried, in this order, each time the one before changed nothing: Ctrl+U (the cursor is at the end of the text), End
# then Ctrl+U (the cursor is inside it), Delete (text lies after the cursor); a key that changes the box starts the plan again
CLEAR_PLAN = (("C-u",), ("End", "C-u"), ("Delete",))


async def send_edit_key(settings: Settings, pane: str, key: str) -> None:
    """One editing key into the pane's input box, from EDIT_KEYS only (Ctrl+U, End, Delete). Only the page's Replace and the outbox's
    clearing of text in the box send them, and only to clear the box. Nothing else is ever sent this way."""
    _check_pane(pane)
    if key not in EDIT_KEYS:
        raise TmuxError(f"refusing to send key {key!r}")
    await run_tmux(settings, "send-keys", "-t", pane, key)


async def clear_box(settings: Settings, pane: str) -> tuple[bool, str]:
    """Empty the pane's input box with CLEAR_PLAN's keys, reading the box after every key and stopping as soon as it reads
    empty. Returns (True, "") when it is empty, else (False, why): the box went away, no key changed it, or CLEAR_MAX_KEYS were
    sent. It types nothing else, so a caller that gets False has put no message into a half-cleared box."""
    sent = 0

    async def look() -> tuple[str, str, tuple[str, ...]]:
        captured = await capture(settings, pane)
        state, text = input_box(captured)
        return state, text, _box_rows(captured)

    async def press(key: str, before: tuple[str, ...]) -> tuple[str, str, tuple[str, ...]]:
        # the box after the key; a box that looks unchanged is read once more (a slow redraw is not a key that did nothing)
        nonlocal sent
        sent += 1
        await send_edit_key(settings, pane, key)
        await asyncio.sleep(CLEAR_SETTLE)
        now = await look()
        if holds(now[0], now[2]) and now[2] == before:
            await asyncio.sleep(CLEAR_STALL_SETTLE)
            now = await look()
        return now

    def holds(state: str, rows: tuple[str, ...]) -> bool:
        # a box that reads "text", or reads empty but still has a blank row after the first: the newline a Ctrl+U left, which
        # would put the message on a second line (a placeholder that wraps has no blank row)
        return state == "text" or (state == "empty" and any(not r.strip() for r in rows[1:]))

    state, text, rows = await look()
    while holds(state, rows):
        progressed = False
        for step in CLEAR_PLAN:
            if sent + len(step) > CLEAR_MAX_KEYS:
                return False, f"the input box still holds text after {sent} keys"
            for key in step:
                state, _, now_rows = await press(key, rows)
                if state == "missing":
                    break
            if state == "missing":
                break
            if now_rows != rows:
                rows, progressed = now_rows, True
                break
        if state == "missing":
            break
        if not progressed:
            return False, "the input box did not clear (Ctrl+U, End and Delete changed nothing)"
    if state == "missing":
        return False, "the input box disappeared while clearing it"
    return True, ""
