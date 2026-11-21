"""Operation log pages: GET /op/<id> serves the log of one `sala op` operation as plain text (salamander lib/op.sh, docs/op-log-page.md).

The log is the file the CLI writes, <log dir>/salamander-op-<id>.log (lib/op.sh `op_oplog`; the log dir is SALA_LOG_DIR there, default ~/.claude). The
operation's Slack post ends in a link to this page instead of the file's path, so the owner can read what the operation did from a phone. This module
only reads; the CLI is the only writer.

What is served is the file as it is: it is NOT parsed and NOT redacted. The page is as private as the whole site (it sits behind the proxy's sign-in,
docs/web-proxy.md; sala-web has no login of its own, and a second scheme would be a second gate to keep right), and an operation's log holds what the
operation printed: session names, paths, the verb's own output.

The address is the only input: the id must match ID_RE (digits, one dash: the epoch second and the process id the CLI builds an id from), and the file
path is built from nothing else. The file is opened without following a link and must be a regular file; a link, a folder, a pipe or anything else
is "no such log". Only the last MAX_BYTES are served; a longer log is cut from the front, and the first line of the page says so.

Every answer under /op/ (a log, a 404, a 405) carries the headers below: the page is private (never kept by a shared cache), is plain text that a
browser must not sniff into anything else, says nothing about which page linked to it, and has a policy that allows nothing to load or run.
"""

from __future__ import annotations

import os
import re
import stat
from pathlib import Path

MAX_BYTES = 256 * 1024
ID_RE = re.compile(r"[0-9]{6,12}-[0-9]{1,10}")

HEADERS = {
    "Cache-Control": "private, no-store",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "Content-Security-Policy": "default-src 'none'; sandbox",
}

METHODS = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "TRACE", "CONNECT"]   # every method, so Starlette's own 405 (no headers, a wrong Allow) never answers under /op


def read_log(root: Path, raw: str) -> str | None:
    """The text of the log of operation `raw` (the id as written in the address), or None when there is no such log: not an id, no file, a link or
    anything but a regular file. The last MAX_BYTES at most; when the log is longer, the first line says that lines were cut. Bytes that are not
    UTF-8 are replaced, never an error."""
    if not ID_RE.fullmatch(raw):
        return None
    try:
        # O_NONBLOCK: opening a pipe someone put there by hand must not wait for a writer (it is refused just below)
        fd = os.open(root / f"salamander-op-{raw}.log", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    except OSError:
        return None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            return None
        size = st.st_size
        cut = size > MAX_BYTES
        with os.fdopen(fd, "rb", closefd=False) as f:
            if cut:
                f.seek(size - MAX_BYTES - 1)       # one byte more: the one just before the cut says whether the tail starts on a line
            data = f.read(MAX_BYTES + 1 if cut else MAX_BYTES)
    finally:
        os.close(fd)
    before = b""
    if cut:
        before, data = data[:1], data[1:]
    text = data.decode("utf-8", errors="replace")
    if not cut:
        return text
    if before != b"\n":   # the cut fell inside a line: that fragment is left out (a cut on a line start leaves every line whole)
        nl = text.find("\n")
        if nl >= 0:
            text = text[nl + 1:]
    return f"[earlier lines cut: showing the last {MAX_BYTES // 1024} KB of {size} bytes]\n{text}"
