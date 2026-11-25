"""What an open page compares to know whether it must reload: two versions made from the CONTENT of the page's own files.

The page is everything under static/: the HTML shells (index.html, terminal.html), the scripts, the vendor files, the fonts and
icons, the manifest and the service worker. Its version (`page`) is a hash of those files' bytes and paths, the style sheets
(*.css) left out. A page that finds the server's `page` differs from the one it was served shows the "Reload" strip; the same
files give the same version, whatever their modification times and whichever commit the server runs, so a release that restarts
the server and changes nothing the browser loads shows nothing.

The style sheets have their own version (`styles`): a change there is applied to the open page by swapping the sheets' links in
place (app.js swapStyles), with no reload, so it never moves `page`. A `<style>` block inside index.html or terminal.html is part of
that HTML file, so it counts as the page.

A file is hashed once and again only when its size or modification time changes (the time is only the cache's key, never part of the
version), so a call costs one stat per file.
"""

from __future__ import annotations

import hashlib
from pathlib import Path

STYLE_SUFFIX = ".css"
DIGITS = 12

# (path, size, mtime_ns) -> the file's sha256 hex: a file is read again only when it changed
_hashes: dict[tuple[str, int, int], str] = {}


def _file_hash(p: Path, st) -> str:
    key = (str(p), st.st_size, st.st_mtime_ns)
    h = _hashes.get(key)
    if h is None:
        h = hashlib.sha256(p.read_bytes()).hexdigest()
        if len(_hashes) > 4096:   # a bound only: a tree has a few dozen files
            _hashes.clear()
        _hashes[key] = h
    return h


def versions(root: Path) -> tuple[str, str]:
    """(page, styles) of the files under `root`: each a short hex digest of the files' relative paths and contents."""
    page, styles = hashlib.sha256(), hashlib.sha256()
    for p in sorted(root.rglob("*")):
        try:
            if not p.is_file():
                continue
            h = _file_hash(p, p.stat())
        except OSError:   # a file removed between the listing and the read (a deploy in progress): the next call sees the new tree
            continue
        d = styles if p.suffix == STYLE_SUFFIX else page
        d.update(p.relative_to(root).as_posix().encode() + b"\0" + h.encode() + b"\n")
    return page.hexdigest()[:DIGITS], styles.hexdigest()[:DIGITS]
