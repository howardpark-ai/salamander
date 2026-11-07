"""The v2 layer's routes (sala_web/v2/layer.py): /v2/ next to the unchanged page, over HTTP.

/v2/ serves today's page and today's files through the v2 design pass, at request time, cached by file mtime. What has to hold is
that / and /static/ stay byte for byte what they were, that the v2 page cannot touch the installed app (no manifest link, no service
worker), that every /v2/<path> the page's relative URLs make reaches the handler it would have without the prefix (api, event
streams, the terminal page, the worker file), and that a pass that raises costs the look and not the page.

What a wrong answer costs: a v1 page that changed because v2 was added (the owner's daily tool), a second "install app" offer or a
second worker registered from a page meant for trying things, a /v2 screen whose data calls 404, a v2 stylesheet served as
text/plain (the page unstyled), a font that never loads, or a 500 on the page when the pass meets a v1 rule it did not expect.

No browser here (test_v2_browser.py draws the pages): Starlette's TestClient over a fake empty state, and the middleware on its own
with a fake inner app, where a websocket scope can be sent.
"""

from __future__ import annotations

import asyncio
import json
import logging
import shutil
import time
import urllib.request
from pathlib import Path

import pytest
from starlette.applications import Starlette
from starlette.routing import Route
from starlette.staticfiles import StaticFiles
from starlette.testclient import TestClient

from conftest import NAME, SID
from sala_web.app import STATIC, create_app
from sala_web.config import Settings
from sala_web.v2 import design
from sala_web.v2.layer import PREFIX, V2Layer, V2Prefix

HERE = Path(__file__).parent


@pytest.fixture
def client(tmp_path):
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    (claude / "projects").mkdir()
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                        tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"])
    return TestClient(create_app(settings))


def static_files() -> list[str]:
    return sorted(p.relative_to(STATIC).as_posix() for p in STATIC.rglob("*") if p.is_file())


# ----------------------------------------------------------------------------- v1 stays as it is

def test_v1_page_and_static_files_are_what_they_were_with_v2_in_the_app(client):
    before = client.get("/")
    assert before.status_code == 200
    assert 'rel="manifest"' in before.text and "<title>sala</title>" in before.text
    assert "v2-extra" not in before.text and "v2 · " not in before.text and "D2Coding" not in before.text
    # every static file, byte for byte; a v2 request in between changes nothing about them
    client.get("/v2/")
    client.get("/v2/static/style.css")
    client.get("/v2/static/app.js")
    for rel in static_files():
        r = client.get("/static/" + rel)
        assert r.status_code == 200, rel
        assert r.content == (STATIC / rel).read_bytes(), rel
        assert r.headers["cache-control"] == "no-cache", rel
    after = client.get("/")
    assert after.text == before.text
    assert "v2 · " not in client.get("/static/app.js").text


def test_the_worker_and_the_manifest_are_still_served_at_the_root(client):
    assert client.get("/manifest.webmanifest").content == (STATIC / "manifest.webmanifest").read_bytes()
    assert client.get("/sw.js").content == (STATIC / "sw.js").read_bytes()


# ----------------------------------------------------------------------------- the page

def test_slashless_v2_redirects_to_the_page_and_keeps_the_query(client):
    r = client.get("/v2", follow_redirects=False)
    assert r.status_code == 302 and r.headers["location"] == "v2/"
    r = client.get("/v2?x=1#s=a", follow_redirects=False)
    assert r.headers["location"] == "v2/?x=1"
    assert client.get("/v2").status_code == 200   # followed: lands on the page


def test_the_v2_page_is_the_same_page_through_the_same_rendering_with_the_marks(client):
    v1, v2 = client.get("/"), client.get("/v2/")
    assert v2.status_code == 200 and v2.headers["content-type"].startswith("text/html")
    assert v2.headers["cache-control"] == "no-cache"
    assert "<title>v2 · sala</title>" in v2.text
    # the template fields are filled, as for /: the brand, the build, the asset version, the owner's name
    assert "{{" not in v2.text
    assert "salamander" in v2.text
    assert 'name="sala-web-version"' in v2.text
    # the same page: every id of v1's markup is there
    import re
    ids = lambda t: set(re.findall(r'\bid="([^"]+)"', t))
    assert ids(v1.text) <= ids(v2.text)
    assert 'id="v2-extra"' in v2.text


def test_the_v2_page_cannot_touch_the_installed_app(client):
    page = client.get("/v2/").text
    assert 'rel="manifest"' not in page and "manifest.webmanifest" not in page
    # no script of the page registers a worker: app.js is the only one that did, and its guard is switched off
    import re
    for src in re.findall(r'<script src="(static/[^"?]+)', page):
        body = client.get("/v2/" + src).text
        assert 'if ("serviceWorker" in navigator)' not in body, src
        if src.endswith("app.js"):
            assert "if (false) {   // v2: no service worker of its own" in body   # the dead branch; test_v2_browser.py checks no worker exists


def test_the_page_asks_for_v2_files_by_relative_addresses_so_they_resolve_under_the_prefix(client):
    import re
    page = client.get("/v2/").text
    urls = re.findall(r'(?:href|src)="([^"#]+)"', page)
    local = [u for u in urls if not re.match(r"(https?:|data:|//)", u)]
    assert local and all(not u.startswith("/") for u in local), [u for u in local if u.startswith("/")]


def test_arg_links_still_reach_the_terminal_page(client):
    r = client.get("/v2/?arg=x", follow_redirects=False)
    assert r.status_code == 302 and r.headers["location"] == "/terminal?arg=x"


# ----------------------------------------------------------------------------- static files

def test_stylesheets_are_the_passes_output_and_served_as_css(client):
    for name in sorted(p.name for p in STATIC.glob("*.css")):
        r = client.get("/v2/static/" + name)
        assert r.status_code == 200, name
        assert r.headers["content-type"].startswith("text/css"), name
        assert r.headers["cache-control"] == "no-cache" and r.headers["etag"], name
        assert r.text == design.css((STATIC / name).read_text(encoding="utf-8")), name
    css = "".join(client.get("/v2/static/" + p.name).text for p in STATIC.glob("*.css"))
    import re
    assert not re.search(r"jetbrains", re.sub(r"/\*.*?\*/", "", css, flags=re.S), re.I)   # no other font is named
    assert css != "".join((p).read_text(encoding="utf-8") for p in STATIC.glob("*.css"))


def test_app_js_is_the_passes_output_and_every_other_file_is_v1s_own_bytes(client):
    r = client.get("/v2/static/app.js")
    assert r.status_code == 200 and r.headers["content-type"].startswith("text/javascript")
    assert r.text == design.js((STATIC / "app.js").read_text(encoding="utf-8"))
    for rel in static_files():
        if rel.endswith(".css") and not rel.startswith("vendor/") or rel == "app.js":
            continue
        got = client.get("/v2/static/" + rel)
        assert got.status_code == 200, rel
        assert got.content == (STATIC / rel).read_bytes(), rel   # vendor/, the icons, the other scripts, sw.js


def test_the_code_font_is_served_with_a_font_type_and_its_licence_travels_with_it(client):
    r = client.get("/v2/static/fonts/D2Coding-Regular.woff2")
    assert r.status_code == 200
    assert r.headers["content-type"] == "font/woff2" and r.headers["cache-control"] == "no-cache"
    assert r.content[:4] == b"wOF2" and len(r.content) > 100_000
    lic = client.get("/v2/static/fonts/OFL.txt")
    assert lic.status_code == 200 and "SIL OPEN FONT LICENSE" in lic.text.upper()
    # the page names exactly this address, relative
    assert 'url("static/fonts/D2Coding-Regular.woff2")' in client.get("/v2/").text
    # the font is a v2 file: v1 has no such address
    assert client.get("/static/fonts/D2Coding-Regular.woff2").status_code == 404


def test_a_missing_file_and_a_path_out_of_the_tree_are_404s(client):
    assert client.get("/v2/static/nope.css").status_code == 404
    assert client.get("/v2/static/nope.js").status_code == 404
    for evil in ("..%2fapp.py", "..%2f..%2fv2%2fdesign.py", "%2e%2e/app.py", "fonts/..%2f..%2fapp.py"):
        r = client.get("/v2/static/" + evil)
        assert r.status_code == 404, (evil, r.status_code)


def test_a_conditional_request_gets_a_304_and_head_works(client):
    r = client.get("/v2/static/style.css")
    again = client.get("/v2/static/style.css", headers={"If-None-Match": r.headers["etag"]})
    assert again.status_code == 304 and not again.content
    h = client.head("/v2/static/style.css")
    assert h.status_code == 200 and h.headers["content-type"].startswith("text/css")


# ----------------------------------------------------------------------------- the other paths

def test_the_apis_the_page_calls_answer_under_the_prefix_as_they_do_without_it(client):
    for path in ("api/config", "api/sessions", "api/overview", "api/lane-names", "api/prefs", "api/search?q=zebra", "api/nope"):
        a, b = client.get("/" + path), client.get("/v2/" + path)
        assert (a.status_code, a.headers["content-type"]) == (b.status_code, b.headers["content-type"]), path
        assert a.content == b.content, path
    # writes too, with a body: the same refusal / the same answer
    body = json.dumps({"name": "nobody"})
    a = client.post("/api/read", content=body, headers={"Content-Type": "application/json"})
    b = client.post("/v2/api/read", content=body, headers={"Content-Type": "application/json"})
    assert a.status_code == b.status_code and a.content == b.content
    assert client.put("/v2/api/prefs", json={"theme": "dark"}).status_code == client.put("/api/prefs", json={"theme": "dark"}).status_code
    # the pages that are not the page: the worker, the terminal page, the manifest
    assert client.get("/v2/sw.js").content == client.get("/sw.js").content
    assert client.get("/v2/terminal").content == client.get("/terminal").content
    assert client.get("/v2/manifest.webmanifest").content == client.get("/manifest.webmanifest").content


def test_the_event_stream_opens_under_the_prefix(served):
    import os
    url = f"{served['url']}/v2/api/s/{os.getpid()}/stream"
    with urllib.request.urlopen(url, timeout=10) as r:
        assert r.status == 200 and r.headers["content-type"].startswith("text/event-stream")
        first = r.readline()
    assert first, "the stream sent nothing"


class Recorder:
    """A fake inner app: keeps the scope it was called with."""
    scopes: list

    def __init__(self):
        self.scopes = []

    async def __call__(self, scope, receive, send):
        self.scopes.append(scope)


def call(kind: str, path: str, **extra) -> dict:
    rec = Recorder()
    scope = {"type": kind, "path": path, "raw_path": path.encode(), "query_string": b"a=1", "root_path": "",
             "headers": [(b"cookie", b"CF_Authorization=abc; x=1"), (b"host", b"h")], **extra}
    asyncio.run(V2Prefix(rec)(scope, None, None))
    assert len(rec.scopes) == 1
    return rec.scopes[0]


@pytest.mark.parametrize("kind", ["http", "websocket"])
def test_the_prefix_is_dropped_from_any_other_path_and_nothing_else_changes(kind):
    got = call(kind, "/v2/api/s/7/stream")
    assert got["path"] == "/api/s/7/stream" and got["raw_path"] == b"/api/s/7/stream"
    # the cookie (the sign-in in front of the app), the query and the headers are the request's own
    assert got["headers"] == [(b"cookie", b"CF_Authorization=abc; x=1"), (b"host", b"h")]
    assert got["query_string"] == b"a=1" and got["root_path"] == ""
    assert call(kind, "/v2/ws")["path"] == "/ws"


@pytest.mark.parametrize("path", ["/", "/v2", "/v2/", "/v2/static/style.css", "/v2/static/", "/v22/x", "/v2x", "/api/v2/x", "/static/v2/x"])
def test_the_paths_that_are_the_layers_own_or_not_v2s_are_left_alone(path):
    assert call("http", path)["path"] == path


def test_other_scope_types_pass_through():
    rec = Recorder()
    asyncio.run(V2Prefix(rec)({"type": "lifespan", "path": "/v2/x"}, None, None))
    assert rec.scopes[0]["path"] == "/v2/x"


# ----------------------------------------------------------------------------- a pass that raises, and the cache

def boom(_text):
    raise ValueError("a rule the pass did not expect")


def test_a_pass_that_raises_serves_the_v1_file_and_logs_once(client, monkeypatch, caplog):
    monkeypatch.setattr(design, "css", boom)
    monkeypatch.setattr(design, "js", boom)
    monkeypatch.setattr(design, "html", boom)
    with caplog.at_level(logging.WARNING, logger="sala_web.v2"):
        for _ in range(3):
            r = client.get("/v2/static/style.css")
            assert r.status_code == 200 and r.content == (STATIC / "style.css").read_bytes()
            r = client.get("/v2/static/app.js")
            assert r.status_code == 200 and r.content == (STATIC / "app.js").read_bytes()
            r = client.get("/v2/")
            assert r.status_code == 200 and "<title>sala</title>" in r.text   # v1's page, rendered as /
    failed = [r.getMessage() for r in caplog.records if r.name == "sala_web.v2" and "failed" in r.getMessage()]
    assert len(failed) == 3, failed   # one per file, not one per request
    # and it is not stuck: once the pass works the same process serves v2 again
    monkeypatch.undo()
    assert "v2 · " in client.get("/v2/static/app.js").text
    assert "<title>v2 · sala</title>" in client.get("/v2/").text


def test_a_result_is_cached_by_the_sources_mtime_and_made_again_when_it_changes(tmp_path, monkeypatch):
    static = tmp_path / "static"
    static.mkdir()
    (static / "a.css").write_text(".x { font-size: 14px; }\n")
    calls = []
    real = design.css

    def counting(text):
        calls.append(text)
        return real(text)
    monkeypatch.setattr(design, "css", counting)
    layer = V2Layer(static, StaticFiles(directory=static))
    c = TestClient(Starlette(routes=[Route("/v2/static/{path:path}", layer.static_file)]))
    assert c.get("/v2/static/a.css").text == ".x { font-size: 15px; }\n"
    c.get("/v2/static/a.css")
    c.get("/v2/static/a.css")
    assert len(calls) == 1
    time.sleep(0.01)
    (static / "a.css").write_text(".x { font-size: 17px; }\n")
    assert c.get("/v2/static/a.css").text == ".x { font-size: 17px; }\n"
    assert len(calls) == 2


def test_the_licence_file_is_in_the_package_beside_the_font():
    fonts = Path(design.__file__).parent / "fonts"
    assert (fonts / "D2Coding-Regular.woff2").is_file() and (fonts / "OFL.txt").is_file()
    assert "SIL OPEN FONT LICENSE" in (fonts / "OFL.txt").read_text().upper()
