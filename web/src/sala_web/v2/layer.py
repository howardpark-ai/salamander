"""Serving the v2 layer: /v2/ and /v2/static/ rendered from the live v1 sources at request time, every other /v2/ path sent on.

    GET /v2                    redirect to /v2/
    GET /v2/                   the page: index.html through the same rendering as / (the {{brand}} / {{v}} fields), after
                               design.html (icons, no manifest link, a title that says v2, the face and the additions)
    GET /v2/static/<file>.css  a v1 stylesheet through design.css (vendor/ is left alone)
    GET /v2/static/app.js      app.js through design.js
    GET /v2/static/fonts/...   D2Coding and its licence, from this package
    GET /v2/static/<other>     the v1 static file, as /static/<other> serves it
    any other /v2/<path>       the handler of <path> (api/..., the event streams, terminal, sw.js): the page's URLs are relative, so
                               from /v2/ they come as /v2/api/..., and the ASGI middleware below drops the prefix before routing

Every transformed file is cached by the mtime of its v1 source and of the pass itself (design.py, extra.css), so a v1 change
shows at the next request with no restart, and a file is rewritten once per change. A pass that raises is logged once and the
untouched v1 file is served: a bug in the layer costs the look, never the page. The cache headers are v1's static ones
(`no-cache`, with an ETag, so a reload is a cheap 304).

The pass never touches `/` or `/static/`: they are served by the routes and the mount they always were.
"""

from __future__ import annotations

import hashlib
import logging
import mimetypes
from pathlib import Path
from typing import Callable

from starlette.exceptions import HTTPException
from starlette.requests import Request
from starlette.responses import FileResponse, Response
from starlette.staticfiles import StaticFiles

from . import design

log = logging.getLogger("sala_web.v2")

PREFIX = "/v2"
HERE = Path(__file__).parent
FONTS = HERE / "fonts"
FONT_FILES = {"fonts/D2Coding-Regular.woff2": "font/woff2", "fonts/OFL.txt": "text/plain; charset=utf-8"}
NO_CACHE = {"Cache-Control": "no-cache"}


class V2Layer:
    """The v2 handlers over a static directory. `v1` is the app's own static app, which serves every file the pass leaves alone."""

    def __init__(self, static: Path, v1: StaticFiles):
        self.static = static.resolve()
        self.v1 = v1
        self._cache: dict[str, tuple[tuple, bytes, str]] = {}
        self._failed: set[str] = set()

    # -- the cache

    def _pass_stamp(self) -> tuple:
        """The pass's own files: a change to the pass invalidates every cached result."""
        return tuple((HERE / n).stat().st_mtime_ns for n in ("design.py", "extra.css"))

    def _cached(self, key: str, source: Path, make: Callable[[str], str]) -> tuple[bytes, str] | None:
        """(body, etag) of make(source text), cached by the source's mtime and the pass's; None when make raises (logged once per key)."""
        st = source.stat()
        stamp = (st.st_mtime_ns, st.st_size, self._pass_stamp())
        hit = self._cache.get(key)
        if hit and hit[0] == stamp:
            return hit[1], hit[2]
        try:
            body = make(source.read_text(encoding="utf-8")).encode("utf-8")
        except Exception:
            if key not in self._failed:
                self._failed.add(key)
                log.exception("v2 design pass failed on %s; serving the v1 file as it is", key)
            self._cache.pop(key, None)
            return None
        etag = '"' + hashlib.sha256(body).hexdigest()[:24] + '"'
        self._cache[key] = (stamp, body, etag)
        self._failed.discard(key)
        return body, etag

    # -- the page

    def index_template(self) -> str:
        """index.html as v2 with its {{...}} fields still in it (the app fills them, as for /); the v1 template if the pass raises."""
        got = self._cached("index.html", self.static / "index.html", lambda t: design.html(t))
        return got[0].decode("utf-8") if got else (self.static / "index.html").read_text(encoding="utf-8")

    # -- the static tree

    async def static_file(self, request: Request) -> Response:
        rel = request.path_params["path"]
        if rel in FONT_FILES:
            return FileResponse(FONTS / rel.split("/", 1)[1], media_type=FONT_FILES[rel], headers=NO_CACHE)
        make = None
        if rel.endswith(".css") and not rel.startswith("vendor/"):
            make = "css"
        elif rel == "app.js":
            make = "js"
        if make is not None:
            source = (self.static / rel).resolve()
            if source.is_file() and source.is_relative_to(self.static):
                # design.css / design.js are looked up now, not captured: the pass is whatever the module holds when asked
                got = self._cached("static/" + rel, source, lambda t: getattr(design, make)(t))
                if got:
                    body, etag = got
                    if request.headers.get("if-none-match") == etag:
                        return Response(status_code=304, headers={"ETag": etag, **NO_CACHE})
                    mt = mimetypes.guess_type(rel)[0] or "text/plain"
                    return Response(body, media_type=mt, headers={"ETag": etag, **NO_CACHE})
        return await self.v1.get_response(rel, request.scope)   # not ours, or the pass raised: the v1 file, with v1's headers


class V2Prefix:
    """ASGI middleware: a /v2/<path> request that is not the page or the static tree is the request for /<path>, whatever its type
    (http, websocket). The prefix is dropped from `path` and `raw_path` and nothing else is changed, so headers, cookies, the query
    string, the body and an open stream behave exactly as without the prefix."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] in ("http", "websocket"):
            path = scope["path"]
            if path.startswith(PREFIX + "/") and path != PREFIX + "/" and not path.startswith(PREFIX + "/static/"):
                scope = dict(scope, path=path[len(PREFIX):])
                raw = scope.get("raw_path")
                if raw and raw.startswith(PREFIX.encode() + b"/"):
                    scope["raw_path"] = raw[len(PREFIX):]
        await self.app(scope, receive, send)
