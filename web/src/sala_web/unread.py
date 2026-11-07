"""How many replies each front agent has written since the owner last opened it (the sidebar's orange count; it replaced
the "New" chip).

The read state lives on the server, in `state_dir/read-state.json` (`$XDG_STATE_HOME/sala-web/read-state.json`), so the phone
and the desktop agree: `{"version": 1, "sessions": {"<session name>": {"read": <epoch ms>, "seen": <epoch ms>}}}`.
"read" is the time of the latest reply the owner has opened that session on or after; "seen" is the last time the session was
listed (entries not seen for SEEN_KEEP_DAYS are dropped, so the file does not grow with every session that ever lived).

`annotate` sets two fields on every session: `unread_count`, the number of replies with a timestamp after "read", and
`unread`, which is `unread_count > 0`. A reply is the text of a turn that ended (transcript._ends_turn: a main-thread
assistant line with text that is not followed by a tool call; narration between tool calls is not one). Only a front
agent (stackshot's role `front`) has a count; a background agent, a quick session and a session with no project have 0.
A turn still running does not count yet: while the session is not `idle` (busy, or waiting for an answer) only a line that
says it ended its turn counts, so the text being written at this moment is left out, and the replies of turns that already
ended stay counted. A session with no entry yet is on first sight: its entry is made at the latest reply's time, so
nothing is unread on the first list after a deploy, and only a reply after that is.

The count is read from the transcript's tail (transcript.count_replies_since) and capped at COUNT_MAX = transcript.REPLY_COUNT_MAX
(10): the scan stops there, so `10` means "10 or more" and the page shows 9+ for anything above 9. A session so far behind that
10 replies lie past the scan's byte limit (16 MB of tail) shows fewer; 9+ is a floor, never an exact number.

Opening a session in the UI posts POST /api/read, which moves "read" up to the session's latest reply (never down). The server
computes the time itself from the transcript, so a page cannot mark a reply it has not been shown by sending a time.
"""

from __future__ import annotations

import contextlib
import json
import os
import tempfile
import threading
import time
from pathlib import Path

from . import transcript as TR

FILE_NAME = "read-state.json"
FORMAT_VERSION = 1
MISS_RECHECK_S = 30       # a session whose transcript was not found is looked for again after this long
PATH_CACHE_MAX = 500
COUNT_MAX = TR.REPLY_COUNT_MAX   # the most replies counted for one session: 10 = "10 or more"
SEEN_KEEP_DAYS = 30
SEEN_REFRESH_MS = 24 * 3600 * 1000   # "seen" is rewritten at most once a day per session: a poll does not write the file


def _write(path: Path, data: dict) -> None:
    """Temp file in the same directory, fsync, rename over the old file: a reader sees the old state or the new, never half."""
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".read-state-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, ensure_ascii=False)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


class ReadState:
    """The per-session read markers (see the module docstring); safe to call from several threads."""

    def __init__(self, path: Path, projects_dir: Path):
        self.path = path
        self.projects_dir = projects_dir
        self.replies = TR.ReplyCache()
        self._paths: dict[tuple[str, str], tuple[Path | None, float]] = {}
        self._lock = threading.Lock()
        self._sessions: dict[str, dict] | None = None   # loaded on first use

    def _load(self) -> dict[str, dict]:
        if self._sessions is None:
            out: dict[str, dict] = {}
            try:
                saved = json.loads(self.path.read_text())
                rows = saved.get("sessions") if isinstance(saved, dict) else None
                for name, e in (rows.items() if isinstance(rows, dict) else ()):
                    if isinstance(name, str) and isinstance(e, dict) and isinstance(e.get("read"), (int, float)) \
                            and not isinstance(e.get("read"), bool):
                        seen = e.get("seen")
                        out[name] = {"read": int(e["read"]), "seen": int(seen) if isinstance(seen, (int, float)) else 0}
            except (OSError, ValueError):
                pass   # no file yet, or an unreadable one: every session is on first sight again (read, never a flood of chips)
            self._sessions = out
        return self._sessions

    def _save(self, rows: dict[str, dict], now_ms: int) -> None:
        cutoff = now_ms - SEEN_KEEP_DAYS * 86400 * 1000
        for name in [n for n, e in rows.items() if e["seen"] < cutoff]:
            del rows[name]
        try:
            _write(self.path, {"version": FORMAT_VERSION, "sessions": rows})
        except OSError:
            pass   # the markers stay in memory; the next change writes again

    def _path(self, cwd: str, session_id: str, fresh: bool = False) -> Path | None:
        """transcript_path, remembered per session: a transcript not under the cwd's slug costs a glob over every project
        directory, which a poll every 10 s per front agent should not repeat. A found path is reused while the file exists;
        a miss is reused for MISS_RECHECK_S (the transcript of a new session appears with its first message)."""
        key = (cwd, session_id)
        hit = self._paths.get(key)
        if hit is not None:
            path, at = hit
            if path is not None and path.is_file():
                return path
            if path is None and not fresh and time.monotonic() - at < MISS_RECHECK_S:
                return None
        path = TR.transcript_path(self.projects_dir, cwd, session_id)
        if len(self._paths) >= PATH_CACHE_MAX:
            self._paths.clear()
        self._paths[key] = (path, time.monotonic())
        return path

    def reply_ts(self, cwd: str, session_id: str, fresh: bool = False) -> int | None:
        """The time (epoch ms) of the session's latest reply, None when it has none (or no transcript). `fresh` looks for
        a transcript again even when a recent look found none (opening a session is not a poll)."""
        path = self._path(cwd, session_id, fresh)
        got = self.replies.get(path) if path else None
        return got["ts"] if got else None

    def reply_count(self, cwd: str, session_id: str, since_ms: int, strict: bool = False) -> int:
        """The replies of the session newer than `since_ms`, at most COUNT_MAX; 0 with no transcript."""
        path = self._path(cwd, session_id)
        return self.replies.count_since(path, since_ms, strict) if path else 0

    def annotate(self, scopes: list[dict], now_ms: int | None = None) -> None:
        """Set `unread_count` (an int) and `unread` (a bool, count > 0) on every session dict of group_sessions()'s result,
        making the entry of a front agent seen for the first time (read: nothing is unread on first sight)."""
        now = int(time.time() * 1000) if now_ms is None else now_ms
        with self._lock:
            rows = self._load()
            dirty = False
            for sc in scopes:
                for g in sc["groups"]:
                    for s in g["sessions"]:
                        s["unread"] = False
                        s["unread_count"] = 0
                        if s.get("role") != "front":
                            continue
                        cwd, sid = s.get("cwd") or "", s.get("sessionId") or ""
                        e = rows.get(s["name"])
                        if e is None:
                            rows[s["name"]] = {"read": self.reply_ts(cwd, sid) or 0, "seen": now}
                            dirty = True
                            continue
                        if now - e["seen"] > SEEN_REFRESH_MS:
                            e["seen"] = now
                            dirty = True
                        n = self.reply_count(cwd, sid, e["read"], strict=s.get("status") != "idle")
                        s["unread_count"] = n
                        s["unread"] = n > 0
            if dirty:
                self._save(rows, now)

    def mark_read(self, name: str, cwd: str, session_id: str, now_ms: int | None = None) -> bool:
        """The session's marker moves up to its latest reply; True when it moved (or was made)."""
        now = int(time.time() * 1000) if now_ms is None else now_ms
        with self._lock:
            rows = self._load()
            ts = self.reply_ts(cwd, session_id, fresh=True) or 0
            e = rows.get(name)
            if e is not None and ts <= e["read"]:
                return False
            rows[name] = {"read": max(ts, e["read"] if e else 0), "seen": now}
            self._save(rows, now)
            return True
