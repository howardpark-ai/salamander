"""Hosts: the web UI moved to a host of its own, and an earlier hostname was retired. The app has no host list of its own: whatever Host a request carries is
served the same way, a navigation is never redirected, and a POST or PUT is accepted when its Origin matches the Host
it came in on and refused otherwise. A browser still sending the old hostname is just one more unknown host."""

import json
import os

import pytest
from starlette.testclient import TestClient

from sala_web import app as A
from sala_web import sessions as S
from sala_web.app import create_app
from sala_web.config import Settings

# OLD stands for a retired hostname
OLD, NEW = "term.example.test", "sala.example.test"
HTML = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8"  # a navigation


def settings_for(tmp_path, **kw) -> Settings:
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True, exist_ok=True)
    (claude / "projects").mkdir(exist_ok=True)
    return Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                    tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"], **kw)


@pytest.fixture
def env(tmp_path):
    settings = settings_for(tmp_path)
    app = create_app(settings)
    pid = os.getpid()  # this test process stands in for a live session
    rec = {"pid": pid, "sessionId": "aaaaaaaa-0000-0000-0000-000000000000", "cwd": "/tmp", "name": "me",
           "status": "idle", "tmux": "", "procStart": S.proc_start(pid)}
    (settings.claude_dir / "sessions" / f"{pid}.json").write_text(json.dumps(rec))
    return {"app": app, "client": TestClient(app), "pid": pid, "settings": settings}


def get(client: TestClient, path: str, host: str, accept: str = HTML, method: str = "GET", **kw):
    return client.request(method, path, headers={"Host": host, "Accept": accept, **kw.pop("headers", {})},
                          follow_redirects=False, **kw)


def test_a_navigation_on_the_retired_host_is_served_like_on_any_host_not_redirected(env):
    c = env["client"]
    for host in (OLD, f"{OLD}:443", "unknown.example", NEW):
        r = get(c, "/", host)
        assert r.status_code == 200 and "<title>sala</title>" in r.text and "location" not in r.headers, host
        assert get(c, "/", host, method="HEAD").status_code == 200, host
        assert get(c, "/sessions", host).status_code == 302 and get(c, "/sessions", host).headers["location"] == "./#sessions"
        assert get(c, "/manifest.webmanifest", host, accept="application/manifest+json,*/*").status_code == 200, host
        assert get(c, "/sw.js", host, accept="*/*").status_code == 200, host
        assert get(c, "/api/config", host, accept="*/*").status_code == 200, host
    # the index's own redirect of ttyd's old link form is the only redirect a host gets, the same on every host
    for host in (OLD, NEW):
        r = get(c, "/?arg=demo", host)
        assert r.status_code == 302 and r.headers["location"] == "/terminal?arg=demo", host


def test_a_post_or_put_on_the_retired_host_is_judged_by_its_origin_like_any_host(env):
    c = env["client"]
    # no host list: an Origin that matches the Host the request came in on is same-origin on any host
    for host in (OLD, NEW, "unknown.example"):
        r = c.put("/api/prefs", json={"showAll": True}, headers={"Host": host, "Origin": f"https://{host}"})
        assert r.status_code == 200 and r.json()["showAll"] is True, host
    # an Origin that names another host is a cross-site request: refused, for the retired name and the live one alike
    assert c.put("/api/prefs", json={"showAll": False}, headers={"Host": NEW, "Origin": f"https://{OLD}"}).status_code == 403
    assert c.put("/api/prefs", json={"showAll": False}, headers={"Host": OLD, "Origin": f"https://{NEW}"}).status_code == 403
    assert c.put("/api/prefs", json={"showAll": False}, headers={"Host": OLD, "Origin": "https://evil.example"}).status_code == 403
    assert c.put("/api/prefs", json={"showAll": False}, headers={"Host": NEW, "Origin": "https://evil.example"}).status_code == 403
    assert c.put("/api/prefs", json={"showAll": False}, headers={"Host": OLD, "Origin": "null"}).status_code == 403
    # a POST that names text/html in Accept (a form) is refused for its type by the handler, not redirected
    r = c.post("/api/upload", content=b"x", headers={"Host": OLD, "Accept": HTML, "Content-Type": "text/plain"},
               follow_redirects=False)
    assert r.status_code == 415


def test_the_sala_host_serves_the_page_the_api_and_the_stream(env):
    c, pid = env["client"], env["pid"]
    assert get(c, "/api/sessions", NEW, accept="*/*").status_code == 200
    assert get(c, f"/api/s/{pid}/transcript", NEW, accept="*/*").status_code == 200
    assert get(c, "/api/prefs", NEW, accept="*/*").status_code == 200
    assert get(c, "/static/style.css", NEW, accept="text/css,*/*;q=0.1").status_code == 200
    assert get(c, "/static/app.js", NEW, accept="*/*").status_code == 200
    r = c.post("/api/upload", content=b"\x89PNG\r\n\x1a\nx", headers={"Host": NEW, "Origin": f"https://{NEW}",
                                                                  "Content-Type": "image/png"})
    assert r.status_code == 200 and r.json()["ok"] is True
    env["app"].state.shutting_down.set()  # the stream ends at once instead of tailing
    with c.stream("GET", f"/api/s/{pid}/stream", headers={"Host": NEW, "Accept": "text/event-stream"}) as r:
        assert r.status_code == 200
        body = r.read().decode()
    assert body.startswith(f"retry: {A.SSE_RETRY_MS}\n\n") and "event: version" in body


def test_any_other_host_is_untouched(env):
    c = env["client"]
    for host in ("testserver", NEW, "localhost", "127.0.0.1:8000", "x", "[::1]:8000"):
        r = c.get("/?arg=", headers={"Host": host, "Accept": HTML}, follow_redirects=False)
        assert r.status_code == 302 and r.headers["location"] == "/terminal?arg=", host  # the index's own redirect
        r = c.get("/", headers={"Host": host, "Accept": HTML}, follow_redirects=False)
        assert r.status_code == 200 and "<title>sala</title>" in r.text, host
        assert c.get("/manifest.webmanifest", headers={"Host": host}).status_code == 200, host
    assert c.get("/").status_code == 200  # the tests' own client, no Host of its own


def test_there_are_no_host_settings(tmp_path, monkeypatch):
    # SALA_WEB_CANONICAL_HOST / SALA_WEB_OLD_HOSTS are gone: set in the environment, they change nothing
    monkeypatch.setenv("SALA_WEB_CANONICAL_HOST", NEW)
    monkeypatch.setenv("SALA_WEB_OLD_HOSTS", OLD)
    s = settings_for(tmp_path)
    assert not hasattr(s, "canonical_host") and not hasattr(s, "old_hosts")
    c = TestClient(create_app(s))
    assert get(c, "/", OLD).status_code == 200
