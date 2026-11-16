"""The Shell's key log: what the keyboard sends to the terminal in the Shell drawer (and the full-size Shell page), kept in a file
so that a key that does nothing (the Hangul/English key, which on some Windows keyboard types is read as a plain Alt, or whose
keydown Chromium loses while the IME is switching) can be read off afterwards instead of guessed at.

The page (static/termclip.js `hookShellTerminal`) listens on the terminal frame and posts batches to `POST /api/shell/keylog`.
Nothing the person types may land here, so the rule is held twice, in the page and again here, where a buggy or hostile client
is met: a keydown or keyup is kept only when its `key` is a NAME (`Alt`, `HangulMode`, `Process`, `Enter`, ...: ASCII letters and
digits, two or more of them), never a typed character; a composition event keeps its `data` cut to MAX_DATA characters (it is
what the IME was composing, which is what tells whether the Hangul mode switched). Every field is checked for type and range and
an event with any other field, a missing one or a bad value is dropped whole; what is stored is rebuilt from the checked fields.

The file, `<state_dir>/shell-keylog.jsonl`: one JSON object a line, mode 0600, never over MAX_FILE bytes: a write that would pass
the cap first keeps the newest half of the file (rewritten through a temp file in the same folder, then renamed over it).
"""

from __future__ import annotations

import json
import os
import re
import tempfile
import threading
from pathlib import Path

FILE_NAME = "shell-keylog.jsonl"
MAX_BODY = 32 * 1024          # one POST
MAX_EVENTS = 50               # events in one POST
MAX_FILE = 256 * 1024         # the file never grows past this
MAX_DATA = 16                 # characters of a composition event's data
T_MIN, T_MAX = 946_684_800_000, 4_102_444_800_000   # milliseconds since the epoch: Jan 1st 2000 to Jan 1st 2100
KEY_EVENTS = ("keydown", "keyup")
COMPOSITION_EVENTS = ("compositionstart", "compositionupdate", "compositionend")
KEY_FIELDS = frozenset({"t", "type", "key", "code", "keyCode", "isComposing", "shift", "ctrl", "alt", "meta"})
COMPOSITION_FIELDS = frozenset({"t", "type", "data"})
FLAGS = ("isComposing", "shift", "ctrl", "alt", "meta")
KEY_NAME = re.compile(r"[A-Za-z][A-Za-z0-9]{1,23}")   # a key's name: never a single typed character
CODE_NAME = re.compile(r"[A-Za-z0-9]{0,24}")         # a physical key's name (AltRight, Lang1, KeyA, ...), empty when the browser has none


def _int(v: object, lo: int, hi: int) -> bool:
    return isinstance(v, int) and not isinstance(v, bool) and lo <= v <= hi


def clean(event: object) -> dict | None:
    """The event as it will be stored, or None when it is not one this log keeps (wrong shape, a bad value, a typed character)."""
    if not isinstance(event, dict):
        return None
    kind = event.get("type")
    if not _int(event.get("t"), T_MIN, T_MAX):
        return None
    if kind in KEY_EVENTS:
        if set(event) != KEY_FIELDS:
            return None
        key, code = event["key"], event["code"]
        if not (isinstance(key, str) and KEY_NAME.fullmatch(key) and isinstance(code, str) and CODE_NAME.fullmatch(code)):
            return None
        if not _int(event["keyCode"], 0, 65535) or not all(isinstance(event[f], bool) for f in FLAGS):
            return None
        return {"t": event["t"], "type": kind, "key": key, "code": code, "keyCode": event["keyCode"],
                **{f: event[f] for f in FLAGS}}
    if kind in COMPOSITION_EVENTS:
        if set(event) != COMPOSITION_FIELDS:
            return None
        data = event["data"]
        if not isinstance(data, str) or len(data) > MAX_DATA:
            return None
        return {"t": event["t"], "type": kind, "data": data}
    return None


def clean_all(events: list) -> list[dict]:
    """The events that pass `clean`, in order."""
    return [e for e in map(clean, events) if e is not None]


class KeyLog:
    """The log file. `append` blocks (run it in a threadpool); one lock covers the size check, the trim and the write."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.lock = threading.Lock()

    def append(self, events: list[dict]) -> int:
        """Write one line per (already cleaned) event; the number written. Past MAX_FILE the oldest half goes first."""
        # ensure_ascii: a line is plain ASCII, so a lone surrogate or a line separator in `data` cannot break the file
        lines = [json.dumps(e, separators=(",", ":")) + "\n" for e in events]
        while lines and sum(map(len, lines)) > MAX_FILE // 2:     # not reachable with MAX_EVENTS of these events; the cap is kept regardless
            lines.pop(0)
        if not lines:
            return 0
        data = "".join(lines).encode("ascii")
        with self.lock:
            self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            try:
                size = self.path.stat().st_size
            except OSError:
                size = 0
            if size + len(data) > MAX_FILE:
                self._keep_newest_half(data)
            else:
                fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
                try:
                    os.fchmod(fd, 0o600)
                    os.write(fd, data)
                finally:
                    os.close(fd)
        return len(lines)

    def _keep_newest_half(self, data: bytes) -> None:
        """Rewrite the file as its newest whole lines that fit in half the cap, then `data`: a temp file in the same folder, renamed over."""
        try:
            old = self.path.read_bytes()
        except OSError:
            old = b""
        keep = old[-(MAX_FILE // 2):] if len(old) > MAX_FILE // 2 else old
        if len(keep) < len(old):                       # cut inside a line: that line goes
            nl = keep.find(b"\n")
            keep = keep[nl + 1:] if nl >= 0 else b""
        fd, tmp = tempfile.mkstemp(prefix=".shell-keylog-", dir=self.path.parent)   # 0600
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(keep + data)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, self.path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
