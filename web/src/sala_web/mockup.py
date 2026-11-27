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

import html
import os
import re
import stat
from datetime import datetime, timedelta, timezone
from pathlib import Path

MAX_BYTES = 5 * 1024 * 1024          # the CLI refuses more; a bigger file put there by hand is not served
NUMBER_RE = re.compile(r"[1-9][0-9]{0,9}")
VERSIONS_DIR = "versions"            # <mockups>/versions/<n>/<id>.html: the versions `sala mockup update` and `undo` saved (lib/mockup.py)
VERSION_ID_RE = re.compile(r"(\d{8}T\d{6}\.\d{6}Z)")   # a version's id, also its address: the UTC time it was replaced, to the microsecond
VERSION_ADDR_RE = re.compile(r"([^/]+)/versions/([^/]+)")  # the part of /mockup/<rest> after the number: <n>/versions/<id>
KST = timezone(timedelta(hours=9), "KST")
_DAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
_MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")

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


def with_back_link(text: str, bar: str = BACK_LINK) -> str:
    """`text` with `bar` (BACK_LINK, or the bar of a version view) put at the top of the body: right after the opening <body> tag; a page with none
    gets it after </head>, else after <html>, else after the doctype, else first. Script, style and comment bodies are skipped when looking, so a
    "<body>" in a string is not the tag."""
    masked = _MASK_RE.sub(lambda m: " " * len(m.group(0)), text)
    for rx in [_BODY_RE, *_AFTER_RE]:
        m = rx.search(masked)
        if m:
            return text[:m.end()] + bar + text[m.end():]
    return bar + text


def valid_id(vid: str) -> bool:
    """An id of the CLI's form that is also a real time (month 13 is not one), so the label below cannot fail on it."""
    if not VERSION_ID_RE.fullmatch(vid):
        return False
    try:
        datetime.strptime(vid, "%Y%m%dT%H%M%S.%fZ")
    except ValueError:
        return False
    return True


def kst_label(vid: str) -> str:
    """A version id (the time that version was replaced) in Korea time, in the words sala uses elsewhere: "Wed Oct 28th 14:07 KST"."""
    when = datetime.strptime(vid, "%Y%m%dT%H%M%S.%fZ").replace(tzinfo=timezone.utc).astimezone(KST)
    day = when.day
    suffix = "th" if 11 <= day % 100 <= 13 else {1: "st", 2: "nd", 3: "rd"}.get(day % 10, "th")
    return "%s %s %d%s %02d:%02d KST" % (_DAYS[when.weekday()], _MONTHS[when.month - 1], day, suffix, when.hour, when.minute)


# The history icon: a clock with a return arrow, drawn in SVG so no image or script is needed. A tap opens the list (a <details>, so no script).
# It sits at the right end of the back link's row (the link is that much narrower, so neither covers the other); the list is in the flow under
# that row, never over the page, and each of its rows is 44 px high.
_ICON = ('<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round" '
         'stroke-linejoin="round" aria-hidden="true"><path d="M3 12a9 9 0 1 0 3-6.7L3 8"/><path d="M3 3v5h5"/><path d="M12 7v5l3 2"/></svg>')
_BAR_STYLE = "all:initial;display:block;box-sizing:border-box;width:100%;max-width:100%;background:#161617;"
_ROW_STYLE = ("all:initial;display:block;box-sizing:border-box;min-height:44px;line-height:44px;padding:0 16px;"
              "font:600 16px/44px system-ui,sans-serif;color:#fff;text-decoration:none;white-space:nowrap;overflow:hidden;"
              "text-overflow:ellipsis;cursor:pointer")


def history_block(n: int, ids: list) -> str:
    """The bar of page n: BACK_LINK, and, when there is a saved earlier version (`ids`, newest first), the history icon in the same row that opens
    the list of versions. Each links to its own address, /mockup/<n>/versions/<id>, and reads "Until <time>": its id is when it was replaced."""
    if not ids:
        return BACK_LINK
    rows = "".join('<li style="all:initial;display:block"><a href="%d/versions/%s" style="%s">Until %s</a></li>'
                   % (n, vid, _ROW_STYLE, html.escape(kst_label(vid))) for vid in ids)
    return ('<div data-sala-back style="%sposition:relative">'
            '<a href="../chat" style="%s;width:calc(100%% - 54px)">&larr; Back to sala</a>'
            '<details data-sala-versions style="all:initial;display:block">'
            '<summary aria-label="Earlier versions" title="Earlier versions" style="all:initial;display:flex;position:absolute;top:0;right:0;'
            'box-sizing:border-box;width:54px;height:44px;justify-content:center;align-items:center;cursor:pointer;list-style:none">%s</summary>'
            '<ol style="all:initial;display:block;box-sizing:border-box;margin:0;padding:0;list-style:none">%s</ol>'
            '</details></div>' % (_BAR_STYLE, _ROW_STYLE, _ICON, rows))


def version_block(n: int, vid: str) -> str:
    """The bar of a version view: a way back to the current page (`../../<n>` is relative to /mockup/<n>/versions/<id>), and until when the version was the page."""
    return ('<div data-sala-back style="%s">'
            '<a href="../../%d" style="%s">&larr; Current page</a>'
            '<span data-sala-when style="all:initial;display:block;box-sizing:border-box;padding:0 16px 0 0;font:400 14px/44px system-ui,'
            'sans-serif;color:#bbb;white-space:nowrap">Until %s</span></div>'
            % (_BAR_STYLE, n, _ROW_STYLE, html.escape(kst_label(vid))))


def _is_real_dir(path: Path) -> bool:
    """A folder that is a folder, not a link to one (lstat: a link is not followed)."""
    try:
        return stat.S_ISDIR(os.lstat(path).st_mode)
    except OSError:
        return False


def _is_regular(path: Path) -> bool:
    try:
        return stat.S_ISREG(os.lstat(path).st_mode)
    except OSError:
        return False


def _read_file(path: Path) -> bytes | None:
    """The bytes of a regular file at `path`, or None: a link, a directory, a missing file, or one over the cap. Opened without following a link."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
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


def read_page(root: Path, raw: str) -> bytes | None:
    """The bytes of page `raw` (the number as written in the address), or None when there is no such page: not a canonical number, no file, a
    link or anything but a regular file, or one over the cap. The file is opened without following a link."""
    if not NUMBER_RE.fullmatch(raw):
        return None
    return _read_file(root / f"{int(raw)}.html")


def read_version(root: Path, raw_n: str, raw_id: str) -> bytes | None:
    """The bytes of version `raw_id` of page `raw_n`, or None. Both must be exactly the canonical forms (a number, and an id the CLI names
    versions by), so the only file this can open is <root>/versions/<n>/<id>.html: a path with a slash, a dot-dot or a link does not get here."""
    if not NUMBER_RE.fullmatch(raw_n) or not valid_id(raw_id):
        return None
    n = str(int(raw_n))
    if not _is_regular(root / f"{n}.html") or not _is_real_dir(root / VERSIONS_DIR) or not _is_real_dir(root / VERSIONS_DIR / n):
        return None   # a version of a page that is gone is not shown; a link on the way down is not followed
    return _read_file(root / VERSIONS_DIR / n / f"{raw_id}.html")


def list_versions(root: Path, raw: str) -> list:
    """The ids of the saved versions of page `raw`, newest first. Only names of the CLI's form that are regular files count; a folder
    that is a link is not read. [] when there are none."""
    if not NUMBER_RE.fullmatch(raw):
        return []
    vdir = root / VERSIONS_DIR / str(int(raw))
    if not _is_real_dir(root / VERSIONS_DIR) or not _is_real_dir(vdir):
        return []
    try:
        names = os.listdir(vdir)
    except OSError:
        return []
    ids = []
    for name in names:
        if not (name.endswith(".html") and valid_id(name[:-5])):
            continue
        try:
            if stat.S_ISREG(os.lstat(vdir / name).st_mode):
                ids.append(name[:-5])
        except OSError:
            pass
    return sorted(ids, reverse=True)
