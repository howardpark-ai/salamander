"""The only tmux access sala-web has: read a pane (display, capture-pane), paste into it (load-buffer,
paste-buffer -p, send-keys Enter), answer a numbered dialog in it (send-keys of one digit, or Escape), and stop a running
`!` command (send-keys of Escape, then Ctrl-C).

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
OPTION_RE = re.compile(r"^(?:" + PROMPT + r"\s*)?([1-9])\.\s+\S")
BOX_SIDES = "│┃|"  # a dialog drawn inside a box: its side borders are not part of the text
DIALOG_KEYS = {str(d) for d in range(1, 10)} | {"Escape"}
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
    attaches to a session that is already there (otherwise it asks), so the drawer calls this before its iframe loads. The
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
    Escape (cancel), or Ctrl-C (the Stop button's second key). Nothing else is ever sent this way."""
    _check_pane(pane)
    if key not in DIALOG_KEYS and key != STOP_KEY:
        raise TmuxError(f"refusing to send key {key!r}")
    await run_tmux(settings, "send-keys", "-t", pane, key)


def _visible_runs(line: str) -> list[tuple[str, bool]]:
    """Split a captured line (capture-pane -e) into (text, dim) runs, dropping escape sequences."""
    line = OSC_RE.sub("", line)
    line = OTHER_ESC_RE.sub("", line)
    runs: list[tuple[str, bool]] = []
    dim = False
    pos = 0
    for m in CSI_RE.finditer(line):
        if m.start() > pos:
            runs.append((line[pos:m.start()], dim))
        pos = m.end()
        if m.group(2) != "m":
            continue
        params = m.group(1).replace(":", ";").split(";") if m.group(1) else [""]
        k = 0
        while k < len(params):
            p = params[k]
            if p in ("", "0", "22"):
                dim = False
            elif p == "2":
                dim = True
            elif p in ("38", "48", "58"):
                if k + 1 < len(params) and params[k + 1] == "5":
                    k += 2
                elif k + 1 < len(params) and params[k + 1] == "2":
                    k += 4
            k += 1
    if pos < len(line):
        runs.append((line[pos:], dim))
    return runs


def plain(line: str) -> str:
    return "".join(t for t, _ in _visible_runs(line))


def _is_rule(line: str) -> bool:
    """A horizontal rule: mostly rule characters, or a long run of them, a short label, and rule characters again.

    Claude Code draws the session name inside the rule above the input box ("──── name ─────"). At 50 columns a
    24-character name leaves about 52% of the line as rule characters, under the 60% a plain rule needs, and the
    pane can draw a single rule character after the label ("───────── example-main ─"). So a line that
    starts with a run of 3 or more rule characters and ends with 1 or more, around one short label set off by
    spaces, counts too, with rule characters at least 40% of the line and the whole line at least 10 characters.
    """
    s = plain(line).replace("\u00a0", " ").strip()
    if len(s) < 10:
        return False
    n = s.count(RULE_CHAR)
    if n >= 0.6 * len(s):
        return True
    lead = len(s) - len(s.lstrip(RULE_CHAR))
    trail = len(s) - len(s.rstrip(RULE_CHAR))
    if lead < 3 or trail < 1 or n < 0.4 * len(s):
        return False
    label = s[lead:len(s) - trail]
    return label[:1] == " " and label[-1:] == " " and len(label.strip()) <= 40


def _glyph(line: str) -> str | None:
    """The box glyph a line starts with (❯, or ! in shell mode), or None."""
    t = plain(line).replace("\u00a0", " ").lstrip()
    return next((g for g in BOX_GLYPHS if t.startswith(g)), None)


def _box(lines: list[str], rule_idx: list[int]):
    """Yield (first, bottom, glyph) for each candidate input box, last one first: a rule, then a line starting with a
    box glyph; bottom is the next rule after it, or None (never for a shell-mode box)."""
    for top in reversed(rule_idx):
        first = top + 1
        if first >= len(lines):
            continue
        glyph = _glyph(lines[first])
        if not glyph:
            continue
        bottom = next((i for i in rule_idx if i > first), None)
        if glyph == SHELL and bottom is None:
            continue  # the footer hint "! for bash mode" under every empty box starts with "!", a box needs its bottom rule
        yield first, bottom, glyph


def input_box(captured: str) -> tuple[str, str]:
    """Find Claude Code's input box (a line starting with ❯, or ! in shell mode, between two horizontal rules) and
    say whether it holds text. Dim text is the placeholder suggestion and counts as empty.

    Returns ("empty" | "text" | "missing", the box's visible text).
    """
    lines = captured.split("\n")
    rule_idx = [i for i, ln in enumerate(lines) if _is_rule(ln)]
    for first, bottom, glyph in _box(lines, rule_idx):
        if bottom is None:
            continue
        content_chars: list[str] = []
        all_text: list[str] = []
        for i in range(first, bottom):
            runs = _visible_runs(lines[i])
            if i == first:
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
        return ("text" if visible else "empty"), "".join(all_text).replace(" ", " ").strip()
    return "missing", ""


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
