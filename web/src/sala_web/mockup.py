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


# The link at the top of every served page. A page opened from a reply in the installed app has no address bar, and the page is not sala, so it
# would be a dead end: this is a plain in-flow link (not fixed, so it covers nothing of the design), at least 44 px high, as wide as the page and
# no wider (border-box, no margin), to the chat route. "../chat" is relative to /mockup/<n>, so it works under any path prefix; /chat answers a 302
# to the chat session (or the main page). Inline style only: the page's own sheet cannot be relied on, and the policy allows inline styles.
BACK_LINK = ('<div data-sala-back style="all:initial;display:block;box-sizing:border-box;width:100%;max-width:100%;background:#161617;">'
             '<a href="../chat" style="all:initial;display:block;box-sizing:border-box;min-height:44px;line-height:44px;padding:0 16px;'
             'font:600 16px/44px system-ui,sans-serif;color:#fff;text-decoration:none;white-space:nowrap;overflow:hidden;'
             'text-overflow:ellipsis;cursor:pointer">&larr; Back to sala</a></div>')
_MASK_RE = re.compile(r"<script\b.*?(?:</script\s*>|\Z)|<style\b.*?(?:</style\s*>|\Z)|<!--.*?(?:-->|\Z)", re.I | re.S)
_BODY_RE = re.compile(r"<body\b[^>]*>", re.I)
_AFTER_RE = [re.compile(p, re.I) for p in (r"</head\s*>", r"<html\b[^>]*>", r"<!doctype[^>]*>")]


def with_back_link(text: str) -> str:
    """`text` with BACK_LINK put at the top of the body: right after the opening <body> tag; a page with none gets it after </head>, else after <html>,
    else after the doctype, else first. Script, style and comment bodies are skipped when looking, so a "<body>" in a string is not the tag."""
    masked = _MASK_RE.sub(lambda m: " " * len(m.group(0)), text)
    for rx in [_BODY_RE, *_AFTER_RE]:
        m = rx.search(masked)
        if m:
            return text[:m.end()] + BACK_LINK + text[m.end():]
    return BACK_LINK + text


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
