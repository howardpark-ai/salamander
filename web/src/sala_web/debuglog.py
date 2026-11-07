"""The debug logs' common ground (temporary, Wed Oct 14th 2026): a file of JSON objects, one a line, that a page posts
records to, with the server's UTC time in "ts"; capped, trimmed and rotated. One log uses it now: the timing log
(timingdebug.py, README "Timing": where a page load's milliseconds went); the input debug, its first user, was retired on
Thu Oct 15th 2026, and the paste probe (Fri Oct 30th 2026) with it. Remove with the last of them.

Payloads cannot land here even by mistake: a POST body is capped (MAX_BODY), every string in a record is cut to MAX_STR
characters (a data: URL, an HTML flavour, a text would be far longer), lists to MAX_LIST entries, nesting to MAX_DEPTH,
and a string under a content-like key (CONTENT_KEYS) is replaced by its length. The log rotates to <name>.1 once it
passes MAX_LOG bytes.
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path

MAX_BODY = 64 * 1024            # one POST
MAX_LOG = 2 * 1024 * 1024       # rotate past this
MAX_EVENTS = 500                # records in one POST (the pages send batches of a few)
TAIL_LINES = 200                # GET's default
TAIL_MAX = 2000
MAX_STR = 300                   # longer strings are cut: metadata fits, a payload does not
MAX_LIST = 50
MAX_KEYS = 60
MAX_DEPTH = 5
# keys that could only carry a payload (an event's data, an <img>'s src, a flavour's text): a string under one of them
# is replaced by its length, whatever the page sent
CONTENT_KEYS = frozenset({"data", "src", "html", "text", "value", "innerHTML", "innerText", "textContent", "dataUrl", "base64", "bytes"})


def trim(value: object, depth: int = 0) -> object:
    """The value with every string cut to MAX_STR, lists to MAX_LIST, objects to MAX_KEYS keys, nesting to MAX_DEPTH,
    and a string under a CONTENT_KEYS key replaced by its length."""
    if isinstance(value, str):
        return value if len(value) <= MAX_STR else value[:MAX_STR] + f"…(+{len(value) - MAX_STR} chars)"
    if value is None or isinstance(value, (bool, int, float)):
        return value
    if depth >= MAX_DEPTH:
        return "…"
    if isinstance(value, list):
        out = [trim(v, depth + 1) for v in value[:MAX_LIST]]
        if len(value) > MAX_LIST:
            out.append(f"…(+{len(value) - MAX_LIST} more)")
        return out
    if isinstance(value, dict):
        out = {}
        for k, v in list(value.items())[:MAX_KEYS]:
            k = str(k)[:64]
            out[k] = f"(dropped, {len(v)} chars)" if k in CONTENT_KEYS and isinstance(v, str) else trim(v, depth + 1)
        return out
    return str(value)[:MAX_STR]


def events_of(body: object) -> list[dict] | str:
    """The records in a POST body (one object, or a list of them), or an error message."""
    events = body if isinstance(body, list) else [body]
    if not events:
        return "no events"
    if len(events) > MAX_EVENTS:
        return f"more than {MAX_EVENTS} events in one post"
    if not all(isinstance(e, dict) for e in events):
        return "each event must be a JSON object"
    return events


class DebugLog:
    """Append records to the log file and read its tail. append is blocking (run it in a threadpool, under a lock)."""

    def __init__(self, path: Path) -> None:
        self.path = path

    def append(self, events: list[dict]) -> int:
        """Write one line per event, "ts" (the server's UTC time) first; returns the number of lines written."""
        ts = datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
        lines = []
        for e in events:
            rec = trim(e)
            assert isinstance(rec, dict)
            rec = {"ts": ts, **{k: v for k, v in rec.items() if k != "ts"}}
            lines.append(json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n")
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.rotate()
        fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8") as f:
            f.write("".join(lines))
        return len(lines)

    def rotate(self) -> None:
        """Past MAX_LOG bytes the file becomes <name>.1 (replacing an older .1) and a new one starts."""
        try:
            size = self.path.stat().st_size
        except OSError:
            return
        if size >= MAX_LOG:
            os.replace(self.path, self.path.with_name(self.path.name + ".1"))

    def tail(self, n: int) -> str:
        """The last n lines, as text; "" when there is no log yet."""
        try:
            data = self.path.read_bytes()
        except OSError:
            return ""
        # split on "\n" only: the lines are JSON, and splitlines() would also cut at \x0b, \x0c, \x85,   and  ,
        # which a record's strings may hold unescaped
        lines = data.decode("utf-8", "replace").split("\n")
        if lines and lines[-1] == "":
            lines.pop()
        return "".join(ln + "\n" for ln in lines[-n:]) if n > 0 else ""
