"""The chat session's "In motion" lines: what a session set for itself with `sala motion` (lib/motion.py, docs/subcommands.md).

One small JSON file per session, <sala state>/motion/<session>.json: {"v": 1, "lines": [{"text": str, "at": epoch seconds}]}. The CLI is the
only writer (an exclusive lock, a temporary file renamed into place); this module only reads, so it never sees half a file. A line is in
force for 24 hours from when it was set; an older one is left out here, as the CLI leaves it out of `list` (the CLI drops it from the file at
its next write). At most 8 lines are shown, each at most 120 characters (a longer one in a hand-made file is cut, with an ellipsis, and a
non-string or a malformed row is skipped). No model writes or filters these lines: what the session set is what the page shows.
"""

from __future__ import annotations

import json
import os
import re
import stat
import time
from pathlib import Path

MAX_LINES = 8
MAX_CHARS = 120
TTL_S = 24 * 3600
MAX_FILE = 64 * 1024
NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")


def read_lines(root: Path, session: str, now_s: float | None = None) -> list[dict]:
    """The lines in force for `session`, oldest first: [{"text", "at"}]; [] for no file, a file that is not the format, or a name that is no
    session name. The file is opened without following a link and read only when it is a regular file of a sane size."""
    if not NAME_RE.fullmatch(session or ""):
        return []
    now_s = time.time() if now_s is None else now_s
    try:
        fd = os.open(root / f"{session}.json", os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError:
        return []
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size > MAX_FILE:
            return []
        with os.fdopen(fd, "rb", closefd=False) as f:
            raw = f.read(MAX_FILE + 1)
    except OSError:
        return []
    finally:
        os.close(fd)
    try:
        doc = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return []
    rows = doc.get("lines") if isinstance(doc, dict) else None
    out: list[dict] = []
    for r in rows if isinstance(rows, list) else []:
        if not isinstance(r, dict) or not isinstance(r.get("text"), str):
            continue
        at = r.get("at")
        if isinstance(at, bool) or not isinstance(at, int) or now_s - at >= TTL_S:
            continue
        text = " ".join(r["text"].split())
        if not text:
            continue
        if len(text) > MAX_CHARS:
            text = text[: MAX_CHARS - 1].rstrip() + "…"
        out.append({"text": text, "at": at})
    return out[:MAX_LINES]
