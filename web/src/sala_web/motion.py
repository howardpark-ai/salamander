"""The second list of the chat session's strip ("On it") and its "my turn" list: the lines a session set for itself with `sala motion` (lib/motion.py, docs/subcommands.md).

One small JSON file per session, <sala state>/motion/<session>.json: {"v": 1, "lines": [{"text": str, "at": epoch seconds, "done": epoch seconds
(absent while open), "link": str (absent unless `motion done --link` gave one)}]}. The CLI is the writer (an exclusive lock, a temporary file renamed
into place). This module reads, and its one write is the owner's acknowledgement of a done line (`confirm`, for the Confirm tap and for a reply to
the line): it takes the same lock and writes the same way, and removes the line. An open line stays until the session marks it done or clears it, a
done one (the CLI keeps one only for the chat session) until the owner acknowledges it: nothing here ages one out.
`at` is when the line was first set; `done` is when the session marked it done. At most 8 lines are shown, each at most 120 characters (a longer one
in a hand-made file is cut, with an ellipsis; a non-string, a time no clock says or a malformed row is skipped). No model writes or filters these
lines: what the session set is what the page shows.
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import stat
import tempfile
from pathlib import Path

MAX_LINES = 8
MAX_CHARS = 120
MAX_FILE = 64 * 1024
LINK_MAX = 500
NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
# an https address; a path on this site ("//host", and "/\host" which a browser reads the same way, are another site); or one of the page's own "#..." views,
# the forms static/address.js reads (any other anchor would open the app's root)
LINK_RE = re.compile(r"https://\S+|/(?![/\\])\S*|#(?:sessions|schedules|machines|usage|new|search(?:\?\S*)?|side=\S*|(?:s|lane)=[^&\s]+)")


def _link_ok(raw: object) -> bool:
    """The same rule as lib/motion.py: an https address, an in-app path or one of the page's own anchors, no white space, at most LINK_MAX characters."""
    return isinstance(raw, str) and len(raw) <= LINK_MAX and LINK_RE.fullmatch(raw) is not None


def _rows(doc: object) -> list[dict]:
    """The rows of a parsed file, each a dict with its text and at (and done, link when marked); a malformed row is skipped."""
    rows = doc.get("lines") if isinstance(doc, dict) else None
    out: list[dict] = []
    for r in rows if isinstance(rows, list) else []:
        if not isinstance(r, dict) or not isinstance(r.get("text"), str):
            continue
        at = r.get("at")
        # the bounds keep out what no clock says (and what a browser's date cannot hold): the page words `at` as a day and a time
        if isinstance(at, bool) or not isinstance(at, int) or not 0 < at < 10**11:
            continue
        text = " ".join(r["text"].split())
        if not text:
            continue
        if len(text) > MAX_CHARS:
            text = text[: MAX_CHARS - 1].rstrip() + "…"
        row: dict = {"text": text, "at": at}
        done = r.get("done")
        if done is not None:
            if isinstance(done, bool) or not isinstance(done, int) or not 0 < done < 10**11:
                continue
            row["done"] = done
            if _link_ok(r.get("link")):
                row["link"] = r["link"]
        out.append(row)
    return out[:MAX_LINES]


def _open(root: Path, session: str, flags: int):
    """The file's descriptor (no link followed), or None when there is none to read."""
    if not NAME_RE.fullmatch(session or ""):
        return None
    try:
        return os.open(root / f"{session}.json", flags | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError:
        return None


def _load(root: Path, session: str) -> object:
    """The parsed file, or None for no file, a file that is not the format, or one that is too large."""
    fd = _open(root, session, os.O_RDONLY)
    if fd is None:
        return None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size > MAX_FILE:
            return None
        with os.fdopen(fd, "rb", closefd=False) as f:
            raw = f.read(MAX_FILE + 1)
    except OSError:
        return None
    finally:
        os.close(fd)
    try:
        return json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None


def read_lines(root: Path, session: str) -> list[dict]:
    """`session`'s lines, oldest first: [{"text", "at"}] for an open line, plus "done" (and "link") for a done one; [] for no file, a file that is
    not the format, or a name that is no session name. The file is opened without following a link and read only when it is a regular file of
    a sane size."""
    return _rows(_load(root, session))


def confirm(root: Path, session: str, text: str, at: int) -> str:
    """The owner's acknowledgement of a done line (a confirm, or a reply to it): the line whose text and `at` match and that is done is removed from
    the file, under the CLI's lock, the file replaced whole. Returns "ok", or "unknown" for no such done line (a line not done, one already
    acknowledged, or no file)."""
    if not NAME_RE.fullmatch(session or ""):
        return "unknown"
    try:
        lock = os.open(root / ".lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    except OSError:
        return "unknown"
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        doc = _load(root, session)
        rows = doc.get("lines") if isinstance(doc, dict) else None
        if not isinstance(rows, list):
            return "unknown"
        hit = None
        for k, r in enumerate(rows):
            if isinstance(r, dict) and r.get("text") == text and r.get("at") == at and r.get("done") is not None:
                hit = k
                break
        if hit is None:
            return "unknown"
        del rows[hit]
        _write(root, session, {"v": 1, "lines": rows})
        return "ok"
    finally:
        os.close(lock)


def _write(root: Path, session: str, doc: dict) -> None:
    """The file written whole: a temporary file in the same folder, flushed, then renamed over the old one (as lib/motion.py does)."""
    fd, tmp = tempfile.mkstemp(dir=str(root), prefix=session + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(doc, f, ensure_ascii=False)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, root / f"{session}.json")
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass
