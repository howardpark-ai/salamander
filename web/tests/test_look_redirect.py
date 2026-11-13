"""/v2 is not an address any more, and what the page's look needs from the server is served: the manifest, the worker, the code face and its licence.

The look was first tried at `/v2/` next to the page at `/`. It is the page now, and the address that used to redirect to `/` for a while is
dropped: `/v2`, `/v2/` and every path under it answer what any unknown path answers (a 404), not a redirect. This file kept its name from the
time it tested that redirect (renaming it would touch the suites map, the timings and the coverage list for no gain); it is now about the page
at `/` and what it links.

What a wrong answer costs: `/v2` answering again (a redirect or a page) after it was dropped, a `/v2` address left in the page or in a script or
stylesheet, the manifest or the worker no longer served (the installed app stops updating or installing), a font that 404s or is served as
text, or a licence left behind.

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


@pytest.mark.parametrize("path", ["/v2", "/v2/", "/v2/x", "/v2/static/app.js", "/v2/a/b?arg=x", "/v2x"])
def test_v2_and_what_is_under_it_are_a_404_not_a_redirect(client, path):
    for method in (client.get, client.head):
        r = method(path, follow_redirects=False)
        assert r.status_code == 404, (method.__name__, path, r.status_code)
        assert "location" not in r.headers, (method.__name__, path)


def test_the_page_and_the_static_files_have_no_v2_address(client):
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
