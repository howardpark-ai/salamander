"""/v2 redirects to /, and what the page's look needs from the server is served: the manifest, the worker, the code face and its licence.

The look was first tried at `/v2/` next to the page at `/`. It is the page now, and `/v2`, `/v2/` and every path under it answer a temporary
redirect to `/` for a while, so an old bookmark and the installed app's older link land on the page. The redirect is relative (it holds under
whatever path prefix a proxy adds), keeps the query and nothing of the path (`/v2/x` goes to `/`), and answers GET and HEAD.

What a wrong answer costs: an old bookmark or the installed app's older link that lands on a 404, a redirect that is permanent (a browser that
remembers it after the redirect is dropped), a redirect to an absolute address that breaks behind a path prefix, a query dropped (the old
`?arg=` terminal links), the manifest or the worker no longer served (the installed app stops updating or installing), a font that 404s or
is served as text, or a licence left behind.

No browser here: Starlette's TestClient over a fake empty state.
"""

from __future__ import annotations

import pytest
from starlette.testclient import TestClient

from sala_web.app import STATIC, create_app
from sala_web.config import Settings


@pytest.fixture
def client(tmp_path):
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    (claude / "projects").mkdir()
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                        tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"])
    return TestClient(create_app(settings))


@pytest.mark.parametrize("path, to", [
    ("/v2", "./"),
    ("/v2/", "../"),
    ("/v2/x", "../"),
    ("/v2/static/style.css", "../../"),
    ("/v2/api/sessions", "../../"),
    ("/v2/a/b/c", "../../../"),
])
def test_v2_and_every_path_under_it_redirect_temporarily_to_the_page(client, path, to):
    r = client.get(path, follow_redirects=False)
    assert r.status_code == 307, (path, r.status_code)
    assert r.headers["location"] == to, (path, r.headers["location"])
    assert r.headers.get("cache-control", "").startswith("no-") or "max-age" not in r.headers.get("cache-control", ""), "a temporary redirect is never cached for long"


@pytest.mark.parametrize("path", ["/v2", "/v2/", "/v2/x", "/v2/static/app.js", "/v2/terminal"])
def test_the_redirect_lands_on_the_page(client, path):
    r = client.get(path)   # followed
    assert r.status_code == 200 and r.url.path == "/"
    assert "<title>sala</title>" in r.text


def test_the_query_is_kept_and_a_path_is_not(client):
    r = client.get("/v2/?arg=sess", follow_redirects=False)
    assert r.status_code == 307 and r.headers["location"] == "../?arg=sess"
    r = client.get("/v2?x=1&y=2", follow_redirects=False)
    assert r.headers["location"] == "./?x=1&y=2"
    r = client.get("/v2/some/path?q=a%20b", follow_redirects=False)
    assert r.headers["location"] == "../../?q=a%20b"
    # an old terminal link keeps working: /v2/?arg=x -> /?arg=x -> /terminal?arg=x
    r = client.get("/v2/?arg=x", follow_redirects=True)
    assert r.url.path == "/terminal" and r.url.query == b"arg=x"


def test_head_redirects_too_and_a_write_is_not_taken_for_a_page(client):
    assert client.head("/v2/", follow_redirects=False).status_code == 307
    assert client.post("/v2/api/read", json={"name": "x"}, follow_redirects=False).status_code == 405
    assert client.get("/v2x", follow_redirects=False).status_code == 404   # not under /v2/


def test_nothing_else_is_served_under_v2_and_the_page_has_no_v2_address(client):
    page = client.get("/").text
    assert "/v2" not in page
    for name in ("app.js", "style.css"):
        assert "/v2" not in client.get("/static/" + name).text


# ----------------------------------------------------------------------------- what the installed app and the look need

def test_the_manifest_and_the_worker_are_served_at_the_root_and_the_page_links_the_first(client):
    assert client.get("/manifest.webmanifest").content == (STATIC / "manifest.webmanifest").read_bytes()
    sw = client.get("/sw.js")
    assert sw.status_code == 200 and sw.content == (STATIC / "sw.js").read_bytes()
    assert sw.headers["content-type"].startswith("text/javascript") and sw.headers["cache-control"] == "no-cache"
    assert 'rel="manifest" href="manifest.webmanifest"' in client.get("/").text
    # the script registers the worker from the site root
    app = client.get("/static/app.js").text
    assert 'if ("serviceWorker" in navigator)' in app and 'register("sw.js"' in app.replace("'", '"')


def test_the_code_font_is_served_with_a_font_type_and_its_licence_travels_with_it(client):
    r = client.get("/static/fonts/D2Coding-Regular.woff2")
    assert r.status_code == 200
    assert r.headers["content-type"] in ("font/woff2", "application/font-woff2") and r.headers["cache-control"] == "no-cache"
    assert r.content[:4] == b"wOF2" and len(r.content) > 100_000
    lic = client.get("/static/fonts/OFL.txt")
    assert lic.status_code == 200 and "SIL OPEN FONT LICENSE" in lic.text.upper()
    # the page names exactly this address, relative
    assert 'url("static/fonts/D2Coding-Regular.woff2")' in client.get("/").text
    # a path out of the tree is a 404
    for evil in ("..%2fapp.py", "%2e%2e/app.py", "fonts/..%2f..%2fapp.py"):
        assert client.get("/static/" + evil).status_code == 404, evil
