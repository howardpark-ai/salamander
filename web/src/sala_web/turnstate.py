"""Whether a turn is in progress: the one answer behind the web app's wheel, busy dot and "working" words.

The CLI's registry row says "busy" while a turn runs, and also while only background work (subagents, workflows, teammates) runs after
the turn has ended and the pane waits at its prompt (CLI 2.1.332). The end of a turn is in the transcript, so a "busy" row whose last turn
has ended reads "idle" in the web app: sessions.read_live_sessions asks shown_status for every row, so every page and route agree. Only
the web app reads this; sala's own busy checks (recycle, sleep, retire, the typing guards), where background work counts, do not.

A turn is over when the last main-chain line that says anything of it is one of:
    - a `system` line of subtype turn_duration (what the CLI writes when a turn completes);
    - the interrupt line, a `user` line with no origin whose whole text is "[Request interrupted by user]" (or "... for tool use]"),
      unless a message written within FLUSH_MS before it went into the turn with it, which then goes on;
    - the line of a request that ended in an API error (an assistant line with isApiErrorMessage).
Any later user or assistant line is a turn running. Lines that say nothing either way are passed over: a subagent's, a compaction's,
a slash command the CLI ran by itself (its name line and its output), and every other type.

Unsure stays as the registry says: no transcript, no line found within SCAN_MAX of the end, an end that was never written. One more
case: a row that turned "busy" after the turn ended, less than GRACE_MS ago, is believed, because a new turn's first line may not be
written yet. A row that was busy all along (background work) gives no such sign, and its next turn shows with its first line.

Cost: only a "busy" row is looked at. A file whose size and time are unchanged costs one stat; a file that grew is read from its end back
to where the last look stopped.
"""

from __future__ import annotations

import json
import mmap
import re
import time
from pathlib import Path

from . import chatturns as CT
from . import transcript as TR

GRACE_MS = 30_000
FLUSH_MS = 2_000
SCAN_MAX = 32 << 20
CACHE_MAX = 500

_LINE = re.compile(rb'"type": ?"(?:user|assistant)"|"subtype": ?"(?:turn_duration|local_command)"')
_INTERRUPT = re.compile(r"\[Request interrupted by user(?: for tool use)?\]")
_OUTPUT = ("<local-command-stdout>", "<local-command-stderr>")
_COMMAND = ("<command-name>", "<command-message>")
_NOTE = ("<local-command-caveat>", "<system-reminder>")

_cache: dict[str, tuple[tuple[int, int, int], int, int | None]] = {}   # path -> ((inode, size, mtime_ns), the offset read up to, the answer)


def _says(d: object) -> str:
    """What one transcript line says of the turn: "over", "interrupt", "prompt" (a message that went in), "running", "output" or
    "command" (a slash command's two lines), or "" for nothing."""
    if not isinstance(d, dict) or d.get("isSidechain") or d.get("isCompactSummary") or d.get("isVisibleInTranscriptOnly"):
        return ""
    t = d.get("type")
    if t == "system":
        if d.get("subtype") == "turn_duration":
            return "over"
        return "output" if d.get("subtype") == "local_command" and str(d.get("content", "")).lstrip().startswith(_OUTPUT) else ""
    msg = d.get("message")
    if not isinstance(msg, dict):
        return ""
    if t == "assistant":
        if d.get("isApiErrorMessage") is True:
            return "over"
        return "" if msg.get("model") == "<synthetic>" else "running"
    if t != "user":
        return ""
    content = msg.get("content")
    if CT._is_tool_result(d, content):
        return "running"
    text = CT._texts(content)[0].strip()
    if d.get("isMeta"):
        return "" if text.startswith(_NOTE) else "prompt"
    if text.startswith(_OUTPUT):
        return "output"
    if text.startswith(_COMMAND):
        return "command"
    if d.get("origin") is None and _INTERRUPT.fullmatch(text):
        return "interrupt"
    return "prompt"


def _look(m: mmap.mmap, end: int, floor: int) -> tuple[bool, int | None]:
    """Read the complete lines before `end`, newest first. -> (True, when the turn ended in epoch ms, or None for a turn that runs), or
    (False, None) when no line down to `floor` says either."""
    pos, local, stopped = end, False, None
    while pos > floor and end - pos < SCAN_MAX:
        start = m.rfind(b"\n", 0, pos - 1) + 1
        found, pos = _LINE.search(m, start, pos), start
        if found is None:
            continue
        try:
            d = json.loads(m[start:m.find(b"\n", start)])
        except ValueError:
            continue
        what = _says(d)
        if not what:
            continue
        ts = CT._ms(d.get("timestamp"))
        if stopped is not None:               # behind an interrupt line: did a message go in with it?
            if ts is None or ts < stopped - FLUSH_MS:
                return True, stopped
            if what == "prompt":
                return True, None
        elif what == "output":
            local, floor = True, 0            # its command may stand before `floor`, where the answer was read with it unanswered
        elif what == "command" and local:
            local = False
        elif what == "interrupt" and ts is not None:
            stopped, floor = ts, 0
        else:
            return True, ts if what == "over" else None
    return (True, stopped) if stopped is not None else (False, None)


def ended_at(path: Path) -> int | None:
    """When the transcript's last turn ended, in epoch ms; None while one runs, and when the file does not say."""
    try:
        st = path.stat()
        stamp = (st.st_ino, st.st_size, st.st_mtime_ns)
        hit = _cache.get(str(path))
        if hit is not None and hit[0] == stamp:
            return hit[2]
        with path.open("rb") as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as m:
            end = m.rfind(b"\n") + 1          # a line still being written is left for the next look
            floor = hit[1] if hit is not None and hit[0][0] == st.st_ino and hit[1] <= end else 0
            found, answer = _look(m, end, floor)
    except (OSError, ValueError):             # ValueError: an empty file cannot be mapped
        return None
    if not found and floor and end - floor < SCAN_MAX:
        answer = hit[2]                       # nothing new says anything of the turn
    if len(_cache) >= CACHE_MAX:
        _cache.clear()
    _cache[str(path)] = (stamp, end, answer)
    return answer


def shown_status(projects_dir: Path, cwd: str, session_id: str, status: str, since: object) -> str:
    """The status the web app shows for a registry row: `status` as it is, except that a "busy" row whose turn is over reads "idle".
    `since`: the row's statusUpdatedAt (epoch ms), when it last changed."""
    if status != "busy":
        return status
    path = TR.transcript_path(projects_dir, cwd, session_id)
    over = ended_at(path) if path is not None else None
    if over is None:
        return status
    if isinstance(since, int) and since > over and time.time() * 1000 - since < GRACE_MS:
        return status
    return "idle"
