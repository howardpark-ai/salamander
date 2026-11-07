"""Mockup pages: GET /mockup/<n>, an HTML page `sala mockup add` stored (salamander lib/mockup.py, docs/mockup.md).

The pages are plain files under <sala state>/mockups/ (<n>.html, mode 600, in a mode 700 folder); the CLI is the only writer and this module only
reads. A page is somebody's HTML served at the address of the terminal, so every response under /mockup/ (a page, a 404, a 405) carries the
headers below. They make the page a stranger to the site that serves it:

  Content-Security-Policy: sandbox allow-scripts; ...
      `sandbox` without `allow-same-origin` gives the document an opaque origin: no cookies (document.cookie throws), no localStorage, and a
      request it makes goes out as an origin-less cross-site request, so sala's API (same host, cookie-authenticated by the proxy in front) is
      neither readable nor reachable by it. `allow-scripts` is the only token: no forms, popups, modals, top-level navigation, downloads or
      pointer lock. The rest of the policy closes every other way out: default-src 'none' and connect-src 'none' (no fetch, XHR, WebSocket,
      EventSource or beacon), form-action 'none', base-uri 'none', frame-src, worker-src and object-src 'none'. What a mockup needs stays open: inline
      scripts and styles ('unsafe-inline'), data: images and fonts, Google Fonts (a stylesheet from fonts.googleapis.com, font files from
      fonts.gstatic.com). It may be framed by the site's own pages (frame-ancestors 'self') and by nobody else.
  X-Content-Type-Options: nosniff, Referrer-Policy: no-referrer (a link or request from the page never says which sala page it came from),
  Cache-Control: private, no-cache (it sits behind a login; a shared cache never keeps it, and a page removed by the cleanup is gone at the next load).

Sign-in: none here. sala-web has no login of its own, the proxy in front of the site is the login (docs/web-proxy.md), and this route is served by the
same app on the same socket as every other route, so it is behind that login with them; a second scheme would be a second gate to keep right.
"""

from __future__ import annotations

import os
import re
import stat
from pathlib import Path

MAX_BYTES = 5 * 1024 * 1024          # the CLI refuses more; a bigger file put there by hand is not served
NUMBER_RE = re.compile(r"[1-9][0-9]{0,9}")

CSP = "; ".join([
    "sandbox allow-scripts",
    "default-src 'none'",
    "script-src 'unsafe-inline'",
    "style-src 'unsafe-inline' https://fonts.googleapis.com",
    "font-src https://fonts.gstatic.com data:",
    "img-src data:",
    "media-src data:",
    "connect-src 'none'",
    "frame-src 'none'",
    "worker-src 'none'",
    "object-src 'none'",
    "base-uri 'none'",
    "form-action 'none'",
    "frame-ancestors 'self'",
])

METHODS = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]   # all answered by the route, so a refusal has the headers too

HEADERS = {
    "Content-Security-Policy": CSP,
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "Cache-Control": "private, no-cache",
}


def read_page(root: Path, raw: str) -> bytes | None:
    """The bytes of page `raw` (the number as written in the address), or None when there is no such page: not a canonical number, no file, a
    link or anything but a regular file, or one over the cap. The file is opened without following a link."""
    if not NUMBER_RE.fullmatch(raw):
        return None
    try:
        fd = os.open(root / f"{int(raw)}.html", os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError:
        return None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size > MAX_BYTES:
            return None
        with os.fdopen(fd, "rb", closefd=False) as f:
            return f.read(MAX_BYTES + 1)[:MAX_BYTES]
    finally:
        os.close(fd)
