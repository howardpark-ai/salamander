"""The app makes the Shell's tmux session itself when it starts (app.bring_up_shell, called by the lifespan).

The session is made by `tmuxio.ensure_shell_session`, which the drawer's POST api/shell/open used to be the only caller of; a host
that was just moved had no such session until the drawer was opened once, and a page that attaches to it without the drawer
(/terminal, a bookmark) said `No tmux session named ...`. Now the start does it, once, best effort:

* it calls ensure once when a tmux server answers, and not at all when none does (making the session would start a bare tmux server
  ahead of sala's own restore: the full-size page then asks for the session itself, test_shell_open_on_terminal_page.py);
* a failure (a refused command, a missing tmux, a hang) is printed and never stops the app;
* the real thing on a private tmux server: the session appears when a server is up, and no server is started when none is.

No test here touches the user's own tmux server: the fakes replace the tmux half, and the real run uses a private `-L` socket in a short
TMUX_TMPDIR (a unix socket path is capped at 108 bytes), `-f /dev/null`-equivalent isolation through an empty HOME, the temp folders locked
while the test runs, and the server stopped with its own `kill-server`; nothing is killed by name.
"""

from __future__ import annotations

import fcntl
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest
from starlette.testclient import TestClient

from sala_web import app as APP
from sala_web import tmuxio as T
from sala_web.app import create_app
from sala_web.config import SHELL_SESSION, Settings


def make_settings(tmp_path, sock: str = "salaweb-pytest-none") -> Settings:
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True, exist_ok=True)
    (claude / "projects").mkdir(exist_ok=True)
    return Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude, tmux_socket_name=sock,
                    roles_cmd=["false"], sala_models=tmp_path / "none.tsv", admin_key=tmp_path / "none-key")


class Fakes:
    """Stands in for the tmux half: whether a server answers, and what ensure does."""

    def __init__(self, monkeypatch, server: bool = True, ensure=None):
        self.ensures = 0
        self.checks = 0

        async def server_running(settings):
            self.checks += 1
            return server

        async def default_ensure(settings):
            return True

        self._ensure = ensure or default_ensure

        async def counting_ensure(settings):
            self.ensures += 1
            return await self._ensure(settings)

        monkeypatch.setattr(T, "server_running", server_running)
        monkeypatch.setattr(T, "ensure_shell_session", counting_ensure)


def test_the_start_calls_ensure_once_when_a_tmux_server_answers(tmp_path, monkeypatch):
    f = Fakes(monkeypatch, server=True)
    with TestClient(create_app(make_settings(tmp_path))) as c:
        assert f.ensures == 1
        assert c.get("/api/config").status_code == 200
    assert f.ensures == 1                                   # not again at shutdown, nor by serving a request


def test_the_start_makes_nothing_when_no_tmux_server_answers(tmp_path, monkeypatch):
    f = Fakes(monkeypatch, server=False)
    with TestClient(create_app(make_settings(tmp_path))) as c:
        assert c.get("/api/config").status_code == 200
    assert f.checks == 1 and f.ensures == 0


def test_a_failing_ensure_never_stops_the_app(tmp_path, monkeypatch, capsys):
    async def boom(settings):
        raise T.TmuxError("tmux new-session: server exited unexpectedly")
    f = Fakes(monkeypatch, ensure=boom)
    with TestClient(create_app(make_settings(tmp_path))) as c:
        assert c.get("/api/config").status_code == 200       # up and serving
    assert f.ensures == 1
    err = capsys.readouterr().err
    assert "could not bring up the Shell session" in err and "server exited unexpectedly" in err


@pytest.mark.parametrize("exc", [OSError("tmux: not found"), RuntimeError("anything"), TimeoutError()])
def test_any_failure_of_ensure_is_logged_and_the_app_starts(tmp_path, monkeypatch, capsys, exc):
    async def boom(settings):
        raise exc
    Fakes(monkeypatch, ensure=boom)
    with TestClient(create_app(make_settings(tmp_path))) as c:
        assert c.get("/api/config").status_code == 200
    assert "could not bring up the Shell session" in capsys.readouterr().err


def test_a_tmux_that_hangs_holds_the_start_only_for_the_bound(tmp_path, monkeypatch, capsys):
    import asyncio

    async def hang(settings):
        await asyncio.sleep(60)
    monkeypatch.setattr(APP, "SHELL_START_WAIT", 0.2)
    Fakes(monkeypatch, ensure=hang)
    with TestClient(create_app(make_settings(tmp_path))) as c:
        assert c.get("/api/config").status_code == 200
    assert "could not bring up the Shell session" in capsys.readouterr().err


def test_a_failing_server_check_never_stops_the_app_either(tmp_path, monkeypatch, capsys):
    async def broken(settings):
        raise FileNotFoundError("tmux")
    monkeypatch.setattr(T, "server_running", broken)
    with TestClient(create_app(make_settings(tmp_path))) as c:
        assert c.get("/api/config").status_code == 200
    assert "could not bring up the Shell session" in capsys.readouterr().err


# ---------------------------------------------------------------- the real tmux, on a private server


@pytest.fixture
def private_tmux(tmp_path, monkeypatch):
    if shutil.which("tmux") is None:
        pytest.skip("needs tmux")
    home = tmp_path / "home"
    home.mkdir()
    tmuxdir = Path(tempfile.mkdtemp(prefix="hpt-", dir="/tmp"))      # short: the socket path must stay under 108 bytes
    sock = f"salaweb-pytest-start-{os.getpid()}"
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("TMUX_TMPDIR", str(tmuxdir))
    monkeypatch.delenv("TMUX", raising=False)
    locks = []
    for d in (tmp_path, tmuxdir):                                    # locked while the test runs (systemd-tmpfiles ageing honors flock)
        fd = os.open(d, os.O_RDONLY)
        fcntl.flock(fd, fcntl.LOCK_SH)
        locks.append(fd)

    def tmux(*args: str) -> subprocess.CompletedProcess:
        return subprocess.run(["tmux", "-L", sock, "-f", "/dev/null", *args], capture_output=True, text=True,
                              env={**os.environ, "HOME": str(home), "TMUX_TMPDIR": str(tmuxdir)})
    try:
        yield sock, tmux
    finally:
        try:
            tmux("kill-server")
        finally:
            try:
                shutil.rmtree(tmuxdir, ignore_errors=True)
            finally:
                for fd in locks:
                    fcntl.flock(fd, fcntl.LOCK_UN)
                    os.close(fd)


def test_with_a_server_up_the_start_makes_the_shell_session_and_touches_nothing_else(tmp_path, private_tmux):
    sock, tmux = private_tmux
    assert tmux("new-session", "-d", "-s", "someone-else", "sleep", "300").returncode == 0
    assert tmux("has-session", "-t", "=" + SHELL_SESSION).returncode != 0
    with TestClient(create_app(make_settings(tmp_path, sock))):
        assert tmux("has-session", "-t", "=" + SHELL_SESSION).returncode == 0
    assert sorted(tmux("list-sessions", "-F", "#{session_name}").stdout.split()) == [SHELL_SESSION, "someone-else"]
    # a second start finds it and makes nothing more
    pane = tmux("display-message", "-p", "-t", "=" + SHELL_SESSION + ":", "#{pane_id}").stdout.strip()
    with TestClient(create_app(make_settings(tmp_path, sock))):
        pass
    assert tmux("display-message", "-p", "-t", "=" + SHELL_SESSION + ":", "#{pane_id}").stdout.strip() == pane
    assert tmux("list-sessions", "-F", "#{session_name}").stdout.count("\n") == 2


def test_with_no_server_the_start_starts_none_and_makes_no_session(tmp_path, private_tmux):
    sock, tmux = private_tmux
    assert tmux("list-sessions").returncode != 0                     # the premise: no server on this socket
    with TestClient(create_app(make_settings(tmp_path, sock))) as c:
        assert c.get("/api/config").status_code == 200
    assert tmux("list-sessions").returncode != 0                     # still none: the start did not bring up a bare server
