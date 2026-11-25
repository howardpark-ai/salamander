"""Deploys: the build version (index, /api/config, the SSE "version" event), streams that end at shutdown, and
systemd socket activation."""

import json
import os
import re
import subprocess
import threading
import time

import pytest
from starlette.testclient import TestClient

from sala_web import app as A
from sala_web import sessions as S
from sala_web.app import create_app
from sala_web.config import Settings


@pytest.fixture
def env(tmp_path):
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    (claude / "projects").mkdir()
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                        tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"])
    app = create_app(settings)
    # this test process stands in for a live session (no transcript yet)
    pid = os.getpid()
    rec = {"pid": pid, "sessionId": "aaaaaaaa-0000-0000-0000-000000000000", "cwd": "/tmp", "name": "me",
           "status": "idle", "tmux": "", "procStart": S.proc_start(pid)}
    (claude / "sessions" / f"{pid}.json").write_text(json.dumps(rec))
    return {"app": app, "client": TestClient(app), "pid": pid}


def events(body: str) -> list[tuple[str, dict]]:
    out = []
    for block in body.split("\n\n"):
        name = re.search(r"^event: (.+)$", block, re.M)
        data = re.search(r"^data: (.+)$", block, re.M)
        if name and data:
            out.append((name.group(1), json.loads(data.group(1))))
    return out


def test_config_carries_the_build_version(env):
    r = env["client"].get("/api/config")
    assert r.status_code == 200
    d = r.json()
    v = env["app"].state.build_version()
    sv = env["app"].state.styles_version()
    assert d["version"] == v and v and d["styles"] == sv and sv
    assert re.fullmatch(r"[0-9a-f]{12}", v) and re.fullmatch(r"[0-9a-f]{12}", sv)  # a hash of the page's files, not a time or a commit
    assert r.headers["cache-control"] == "no-store"
    # the page carries the same versions, so a freshly loaded page never sees itself as outdated
    html = env["client"].get("/").text
    assert f'<meta name="sala-web-version" content="{v}">' in html
    assert f'<meta name="sala-web-styles" content="{sv}">' in html
    assert "{{" not in html
    # the style sheets' links carry the styles version, everything else the page's (pageversion.py): a style-only change
    # moves the one and never the other
    css = re.findall(r'<link rel="stylesheet" href="(static/[^"]+\.css)\?v=([^"]+)"', html)
    assert css and {q for _, q in css} == {sv}
    scripts = re.findall(r'<script src="(static/[^"]+\.js)\?v=([^"]+)"', html)
    assert scripts and {q for _, q in scripts} == {v}


def test_version_follows_the_content_of_the_page_not_the_files_times(env, monkeypatch, tmp_path):
    static = tmp_path / "static"
    static.mkdir()
    f = static / "app.js"
    f.write_text("x")
    os.utime(f, (1_000_000, 1_000_000))
    monkeypatch.setattr(A, "STATIC", static)
    v1 = env["client"].get("/api/config").json()["version"]
    os.utime(f, (2_000_000, 2_000_000))  # a fast-forward rewrote the file with the same bytes
    assert env["client"].get("/api/config").json()["version"] == v1
    f.write_text("y")  # one byte of the page changed
    assert env["client"].get("/api/config").json()["version"] != v1


def test_stream_starts_with_retry_and_version_and_ends_at_shutdown(env):
    env["app"].state.shutting_down.set()
    with env["client"].stream("GET", f"/api/s/{env['pid']}/stream") as r:
        assert r.status_code == 200
        body = r.read().decode()
    assert body.startswith(f"retry: {A.SSE_RETRY_MS}\n\n")
    evs = events(body)
    assert evs[0] == ("version", {"version": env["app"].state.build_version(), "styles": env["app"].state.styles_version()})


def test_open_stream_ends_soon_after_shutdown_starts(env):
    t = threading.Timer(1.0, env["app"].state.shutting_down.set)
    t.start()
    t0 = time.monotonic()
    with env["client"].stream("GET", f"/api/s/{env['pid']}/stream") as r:
        body = r.read().decode()
    took = time.monotonic() - t0
    t.join()
    names = [n for n, _ in events(body)]
    assert names[:2] == ["version", "status"] and "reset" in names
    assert took < 3, took  # one tick of the loop, not the 15 s ping interval


def test_systemd_listen_fd(monkeypatch):
    for k, v in {"LISTEN_PID": str(os.getpid()), "LISTEN_FDS": "1", "LISTEN_FDNAMES": "sala-web.socket"}.items():
        monkeypatch.setenv(k, v)
    assert A._systemd_listen_fd() == 3
    assert "LISTEN_PID" not in os.environ and "LISTEN_FDS" not in os.environ  # children do not inherit them
    monkeypatch.setenv("LISTEN_PID", "1")  # meant for another process
    monkeypatch.setenv("LISTEN_FDS", "1")
    assert A._systemd_listen_fd() is None
    monkeypatch.delenv("LISTEN_PID", raising=False)
    monkeypatch.delenv("LISTEN_FDS", raising=False)
    assert A._systemd_listen_fd() is None


def test_commit_is_found_from_a_subdirectory_of_a_larger_checkout(tmp_path, monkeypatch):
    # sala-web is web/ of the salamander repo: no web/.git, the commit is the repo's (found by walking up from the
    # package's directory); outside any checkout the version carries no commit and nothing fails
    repo = tmp_path / "repo"
    pkg = repo / "web" / "src" / "sala_web"
    pkg.mkdir(parents=True)
    (pkg / "app.py").write_text("")
    ident = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@x", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@x"}
    g = ["git", "-c", "commit.gpgsign=false", "-C", str(repo)]
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    subprocess.run(g + ["add", "."], check=True)
    subprocess.run(g + ["commit", "-q", "-m", "x"], check=True, env={**os.environ, **ident})
    head = subprocess.run(g + ["rev-parse", "--short", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    assert A._git_commit(pkg) == head and head
    monkeypatch.setenv("GIT_CEILING_DIRECTORIES", str(tmp_path))  # git looks no higher than this for a checkout
    bare = tmp_path / "nogit" / "src" / "sala_web"
    bare.mkdir(parents=True)
    assert A._git_commit(bare) == ""
