"""The Shell's key log: what the keyboard sends to the terminal in the Shell drawer (and the full-size Shell page), kept in a file
so that a key that does nothing (the Hangul/English key, which on some Windows keyboard types is read as a plain Alt, or whose
keydown Chromium loses while the IME is switching) can be read off afterwards instead of guessed at.

The page (static/termclip.js `hookShellTerminal`) listens on the terminal frame and posts batches to `POST /api/shell/keylog`.
Nothing the person types may land here, so the rule is held twice, in the page and again here, where a buggy or hostile client
is met. The log records which NON-CHARACTER keys were pressed and when, and that IME activity happened and when, never which
letter keys:
- a keydown or keyup is kept only when its `key` is on the list KEY_NAMES (`Alt`, `HangulMode`, `Process`, `Enter`, `F5`, ...), by
  exact match; a typed character, or any name no key sends, drops the event;
- its `code` (the physical key) is kept only from the list CODES (`AltRight`, `Lang1`, `Enter`, ...) or empty; a code that names a
  letter, digit, punctuation or numpad key (`KeyG`, `Digit1`, `Comma`, `Numpad5`, `Space`) is never stored; its `keyCode` only from
  KEYCODES, else 0;
- an IME event (`key` Process, Unidentified, Dead or Compose, or `isComposing`, or `keyCode` 229) keeps the physical `code`, the real
  `keyCode` and the Shift state of the key behind it in the browser, which on a 2-set Korean layout spell the Hangul being typed
  (a password): the server rewrites such an event to code "", keyCode 0, shift false, whatever the client sent, so an old client
  that still sends `Process` with `KeyG` is rewritten, never stored as sent;
- a composition event is `{t, type}` and nothing else: its `data` is the text being composed.
Every field is checked for type and range and an event with any other field, a missing one or a bad value is dropped whole; what is
stored is rebuilt from the checked fields.

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
T_MIN, T_MAX = 946_684_800_000, 4_102_444_800_000   # milliseconds since the epoch: Jan 1st 2000 to Jan 1st 2100
KEY_EVENTS = ("keydown", "keyup")
COMPOSITION_EVENTS = ("compositionstart", "compositionupdate", "compositionend")
KEY_FIELDS = frozenset({"t", "type", "key", "code", "keyCode", "isComposing", "shift", "ctrl", "alt", "meta"})
COMPOSITION_FIELDS = frozenset({"t", "type"})   # no text: a composition is what the person is typing
FLAGS = ("isComposing", "shift", "ctrl", "alt", "meta")
# The names of keys that type no character (KeyboardEvent.key), by exact match: the same list is in termclip.js (KEYLOG_KEYS).
KEY_NAMES = frozenset({
    "Alt", "AltGraph", "Control", "Shift", "Meta", "CapsLock", "NumLock", "ScrollLock", "HangulMode", "HanjaMode", "JunjaMode",
    "KanjiMode", "KanaMode", "Convert", "NonConvert", "Process", "Unidentified", "Dead", "Compose", "Enter", "Backspace", "Delete",
    "Tab", "Escape", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Home", "End", "PageUp", "PageDown", "Insert", "ContextMenu",
    "Clear", *(f"F{n}" for n in range(1, 25))})
# The physical names (KeyboardEvent.code) of those same keys, and empty when the browser has none. Never a letter, digit, punctuation
# or numpad digit key.
CODES = frozenset({
    "", "AltLeft", "AltRight", "ControlLeft", "ControlRight", "ShiftLeft", "ShiftRight", "MetaLeft", "MetaRight", "CapsLock", "NumLock",
    "ScrollLock", "Lang1", "Lang2", "Lang3", "Lang4", "Lang5", "Convert", "NonConvert", "KanaMode", "Enter", "NumpadEnter", "Backspace",
    "Delete", "Tab", "Escape", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Home", "End", "PageUp", "PageDown", "Insert",
    "ContextMenu", *(f"F{n}" for n in range(1, 25))})
# The legacy keyCodes of those keys (Backspace 8, Tab 9, Clear 12, Enter 13, Shift 16, Control 17, Alt 18, CapsLock 20, Hangul 21,
# Junja 23, Hanja 25, Escape 27, Convert 28, NonConvert 29, paging and arrows 33-40, Insert 45, Delete 46, Meta and ContextMenu 91-93,
# F1 to F24 112-135, NumLock 144, ScrollLock 145); 229 (an IME's "processing") is an IME event, rewritten below. Any other keyCode is
# stored as 0.
KEYCODES = frozenset({8, 9, 12, 13, 16, 17, 18, 20, 21, 23, 25, 27, 28, 29, *range(33, 41), 45, 46, 91, 92, 93, *range(112, 136), 144, 145})
IME_KEYS = frozenset({"Process", "Unidentified", "Dead", "Compose"})
IME_KEYCODE = 229
CODE_SHAPE = re.compile(r"[A-Za-z0-9]{0,24}")        # what a code looks like, checked before an IME event's is rewritten


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
        key, code, key_code = event["key"], event["code"], event["keyCode"]
        if not (isinstance(key, str) and key in KEY_NAMES and isinstance(code, str) and CODE_SHAPE.fullmatch(code)):
            return None
        if not _int(key_code, 0, 65535) or not all(isinstance(event[f], bool) for f in FLAGS):
            return None
        out = {"t": event["t"], "type": kind, "key": key, "code": code, "keyCode": key_code, **{f: event[f] for f in FLAGS}}
        if key in IME_KEYS or out["isComposing"] or key_code == IME_KEYCODE:
            out.update(code="", keyCode=0, shift=False)     # the key behind an IME event is a letter of what is being typed
        elif code not in CODES:
            return None
        elif key_code not in KEYCODES:
            out["keyCode"] = 0
        return out
    if kind in COMPOSITION_EVENTS:
        if set(event) != COMPOSITION_FIELDS:
            return None
        return {"t": event["t"], "type": kind}
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
        # ensure_ascii: a line is plain ASCII, so no character of any kind can break the file
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
