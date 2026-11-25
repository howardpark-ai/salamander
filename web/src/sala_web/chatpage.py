"""The chat page's data (GET /api/chat; the page is static/chat.html, chat.css, chat.js; web/README.md, *The chat page*).

Pure functions over what the server already reads, so each can be tested alone:

  cards(text, host, mockups_dir)   the link cards under a message: a /mockup/<n> link of this site and a claude.ai artifact link
  waiting(board_doc, your_move)    the owner's moves: stackshot's whole Your move list (yourmove.py) when there is one, else the board feed (board.py's cache)
  visible_window(entries, n)       the last `n` shown entries and the kept-back lines among them

No external address is ever fetched from here: a mockup's title is read from the local mockup store (the first 64 KB of its file), and an
artifact link's title is the link text or nothing (the page says "Claude artifact").
"""

from __future__ import annotations

import html
import os
import re
import stat
import time
from pathlib import Path

from . import chatturns as CT
from . import motion as MO
from . import transcript as TR

CARDS_MAX = 6
TITLE_MAX = 90
HEAD_BYTES = 64 * 1024
_LINK = re.compile(r"\[([^\]\n]*)\]\(\s*(<[^>\n]+>|[^\s)]+)[^)\n]*\)|https?://[^\s<>\"'\]\)]+|(?<![\w/.:-])/mockup/[1-9][0-9]{0,9}\b")
_MOCKUP_PATH = re.compile(r"^/mockup/([1-9][0-9]{0,9})$")
_ARTIFACT = re.compile(r"^https://claude\.ai/(?:code/)?artifact/[A-Za-z0-9_-]{1,80}/?$")
_TITLE = re.compile(rb"<title[^>]*>(.*?)</title>", re.S | re.I)


def _mockup_title(root: Path, n: int) -> str:
    """The <title> of stored mockup `n` ("" when it has none, or the file is not there): read from the local store, never over the network."""
    try:
        fd = os.open(root / f"{n}.html", os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError:
        return ""
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return ""
        with os.fdopen(fd, "rb", closefd=False) as f:
            head = f.read(HEAD_BYTES)
    except OSError:
        return ""
    finally:
        os.close(fd)
    m = _TITLE.search(head)
    if not m:
        return ""
    return " ".join(html.unescape(m.group(1).decode("utf-8", "replace")).split())[:TITLE_MAX]


def _same_host(url: str, host: str) -> str | None:
    """The path of `url` when it is an address on `host` (or already a path), else None."""
    if url.startswith("/") and not url.startswith("//"):
        return url.split("?", 1)[0].split("#", 1)[0]
    m = re.match(r"^https?://([^/?#]+)(/[^?#]*)?", url)
    if m and host and m.group(1).lower() == host.lower():
        return m.group(2) or "/"
    return None


def cards(text: str, host: str, mockups_dir: Path) -> list[dict]:
    """The link cards of a message's text, in the order the links appear, each address once, at most CARDS_MAX:
    {"kind": "mockup", "url": "/mockup/<n>", "n": n, "title": <its <title>, or the link text, or "">} for a /mockup/<n> link on this site, and
    {"kind": "artifact", "url": <the claude.ai address>, "title": <the link text, or "">} for a claude.ai artifact link. Any other link is
    left to the message's own text: it gets no card."""
    out: list[dict] = []
    seen: set[str] = set()
    for m in _LINK.finditer(text or ""):
        label = (m.group(1) or "").strip() if m.group(1) is not None else ""
        raw = (m.group(2) or m.group(0)).strip("<>")
        raw = raw.rstrip(".,;:!?")
        path = _same_host(raw, host)
        mm = _MOCKUP_PATH.match(path or "")
        if mm:
            n = int(mm.group(1))
            url = f"/mockup/{n}"
            if url in seen:
                continue
            seen.add(url)
            out.append({"kind": "mockup", "url": url, "n": n,
                        "title": _mockup_title(mockups_dir, n) or " ".join(label.split())[:TITLE_MAX]})
        elif _ARTIFACT.match(raw):
            if raw in seen:
                continue
            seen.add(raw)
            out.append({"kind": "artifact", "url": raw, "title": " ".join(label.split())[:TITLE_MAX] if not label.startswith("http") else ""})
        if len(out) >= CARDS_MAX:
            break
    return out


def waiting(board_doc: dict, your_move: list[dict] | None = None) -> list[dict]:
    """The owner's moves. `your_move` is stackshot's whole Your move list as yourmove.py keeps it (every item of the group, none dropped,
    in the page's own order): when it is a list, even an empty one, that is the answer, passed on as it is. With None (never read, or the
    reads have failed for too long) the strip falls back to the board feed: every row board.py marks `waiting` (the mover is the owner
    with no `via`, or an older stackshot's needs-a-decision-and-not-held), over every session the cache holds, each item once (by id),
    in the board's own order. Rows are passed through as sent (id, subject, url): nothing here writes, rewrites, re-sorts or caps them."""
    if your_move is not None:
        return [dict(w) for w in your_move]
    out: list[dict] = []
    seen: set[str] = set()
    sessions = board_doc.get("sessions") if isinstance(board_doc, dict) else None
    for name in sorted(sessions) if isinstance(sessions, dict) else []:
        entry = sessions[name]
        for it in entry.get("items", []) if isinstance(entry, dict) else []:
            if not isinstance(it, dict) or not it.get("waiting") or it.get("held"):
                continue
            iid = str(it.get("id") or "")
            if not iid or iid in seen:
                continue
            seen.add(iid)
            out.append({"id": iid, "subject": str(it.get("subject") or ""), "url": str(it.get("url") or "")})
    return out


def visible_window(entries: list[dict], n: int) -> list[dict]:
    """The entries from the n-th shown one (me, reply, own) counted from the end to the end: the kept-back lines before it are dropped, those
    after it stay. Fewer than n shown entries: all of them."""
    shown = 0
    cut = 0
    for i in range(len(entries) - 1, -1, -1):
        if entries[i]["k"] != "kept":
            shown += 1
            if shown >= n:
                cut = i
                break
    return entries[cut:]


SHOWN_MAX = 60   # shown entries (what he typed, replies, marked replies) the page holds; the kept-back lines between them come along


def assemble(*, name: str, display: str, owner: str, sess, projects_dir: Path, zone, now_ms: int, host: str, mockups_dir: Path,
             motion_dir: Path, board_doc: dict, cache: dict, your_move: list[dict] | None = None) -> dict:
    """The whole answer of GET /api/chat for the configured session `name` (`sess`: its Session, live or sleeping, or None when sala has no such
    session). `cache` (a dict kept by the caller) holds the last read of a transcript, keyed by its size and time, so a poll of an unchanged
    file costs a stat. `your_move`: the owner's whole Your move list when stackshot's read has one (yourmove.py), else None."""
    entries: list[dict] = []
    kept_today, kept_lines, floor = 0, 0, False
    present = "absent"
    status = ""
    if sess is not None:
        present = "sleeping" if sess.sleeping is not None else "live"
        status = sess.status
        path = TR.transcript_path(projects_dir, sess.cwd, sess.session_id)
        if path is not None:
            midnight = CT.day_start_ms(now_ms, zone)
            strict = status in ("busy", "waiting")
            try:
                st = path.stat()
                stamp = (st.st_size, st.st_mtime_ns, midnight, strict, owner)
            except OSError:
                stamp = None
            hit = cache.get(str(path))
            if stamp is not None and hit is not None and hit[0] == stamp:
                entries, kept_today, floor, kept_lines = hit[1], hit[2], hit[3], hit[4]
            elif stamp is not None:
                turns, reached = CT.read_turns(path, now_ms, zone, strict)
                entries = visible_window(CT.entries(turns, owner, limit=len(turns)), SHOWN_MAX)
                kept_today, floor = CT.kept_today(turns, owner, midnight), not reached
                kept_lines = CT.kept_today(turns, owner, midnight, with_taken=True)
                if len(cache) > 8:
                    cache.clear()
                cache[str(path)] = (stamp, entries, kept_today, floor, kept_lines)
    out_entries = []
    for e in entries:
        e = dict(e)
        if e["k"] in ("me", "reply", "own"):
            c = cards(e.get("text") or "", host, mockups_dir)
            if c:
                e["cards"] = c
        out_entries.append(e)
    return {"configured": True, "session": name, "name": display, "owner": owner, "present": present, "status": status,
            "pid": sess.pid if sess is not None and present == "live" else 0,
            "busy": status in ("busy", "waiting"),
            "entries": out_entries, "keptToday": kept_today, "keptTodayFloor": floor, "keptLines": kept_lines,
            "waiting": waiting(board_doc, your_move), "motion": MO.read_lines(motion_dir, name),
            "now": now_ms}
