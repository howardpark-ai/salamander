"""The socket and state settings after the units were renamed to sala-web (README, *Renamed units*): SALA_WEB_SOCKET and
SALA_WEB_STATE_DIR pin the paths (sala's config file is read after the environment), and the old socket paths are kept working for one release by a symlink the app makes at start, only when the
old path's parent directory exists."""

import os
import shutil
import socket
import tempfile
import threading
from pathlib import Path

import pytest

from sala_web import app as A
from sala_web.config import Settings


@pytest.fixture
def short():
    """A short directory for the sockets: a unix socket path has a limit of about 108 bytes, which a CI runner's tmp_path
    can pass. Removed after the test."""
    d = Path(tempfile.mkdtemp(prefix="sw-", dir="/tmp"))
    yield d
    shutil.rmtree(d, ignore_errors=True)


@pytest.fixture(autouse=True)
def clean_env(monkeypatch, tmp_path, short):
    for v in ("SALA_WEB_SOCKET", "SALA_WEB_STATE_DIR", "SALA_WEB_COMPAT_SOCKET",
              "SALA_WEB_COMPAT_TTYD_SOCKET", "SALA_WEB_TTYD_SOCKET"):
        monkeypatch.delenv(v, raising=False)
    monkeypatch.setenv("SALA_CONFIG", str(tmp_path / "no-config"))
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(short / "run"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))


def test_defaults_carry_the_new_name(tmp_path, short):
    s = Settings()
    assert s.socket == short / "run" / "sala-web" / "sala-web.sock"
    assert s.state_dir == tmp_path / "state" / "sala-web"
    assert s.ttyd_socket == short / "run" / "sala-web-ttyd" / "ttyd.sock"
    assert s.compat_socket is None and s.compat_ttyd_socket is None


def test_the_environment_wins_over_sala_config(tmp_path, monkeypatch):
    cfg = tmp_path / "config"
    cfg.write_text('SALA_WEB_SOCKET="$HOME/cfg.sock"   # pinned\nSALA_WEB_STATE_DIR=~/cfg-state\n')
    monkeypatch.setenv("SALA_CONFIG", str(cfg))
    home = Path.home()
    assert Settings().socket == home / "cfg.sock" and Settings().state_dir == home / "cfg-state"
    monkeypatch.setenv("SALA_WEB_SOCKET", "/x/new.sock")
    monkeypatch.setenv("SALA_WEB_STATE_DIR", "/x/new-state")
    assert Settings().socket == Path("/x/new.sock") and Settings().state_dir == Path("/x/new-state")


def serve(path: Path) -> socket.socket:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(str(path))
    s.listen(1)
    return s


def test_old_paths_become_links_to_the_new_sockets(short, monkeypatch):
    run = short / "run"
    (run / "sala-web").mkdir(parents=True)
    (run / "old").mkdir()
    (run / "old-ttyd").mkdir()
    old, old_ttyd = run / "old" / "old.sock", run / "old-ttyd" / "ttyd.sock"
    stale = serve(old)   # the socket file the old unit left behind (systemd does not remove it on stop)
    stale.close()
    monkeypatch.setenv("SALA_WEB_COMPAT_SOCKET", str(old))
    monkeypatch.setenv("SALA_WEB_COMPAT_TTYD_SOCKET", str(old_ttyd))
    s = Settings()
    own = s.socket
    listener = serve(own)
    try:
        made = A.link_compat_sockets(s, own)
        assert made == [(old, own), (old_ttyd, s.ttyd_socket)]
        assert old.is_symlink() and os.readlink(old) == str(own)
        assert old_ttyd.is_symlink() and os.readlink(old_ttyd) == str(s.ttyd_socket)   # dangling until ttyd starts
        # a client of the old path (a proxy not yet repointed) reaches the new socket
        got = []
        t = threading.Thread(target=lambda: got.append(listener.accept()[0]))
        t.start()
        c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        c.connect(str(old))
        t.join(5)
        assert got
        c.close()
        got[0].close()
        # a second start changes nothing
        assert A.link_compat_sockets(s, own) == made and os.readlink(old) == str(own)
    finally:
        listener.close()
    assert not list(run.glob("old/.*")), "no temporary link left beside the old path"


def test_nothing_is_made_without_the_parent_or_over_something_else(short, monkeypatch, capsys):
    run = short / "run"
    (run / "sala-web").mkdir(parents=True)
    monkeypatch.setenv("SALA_WEB_COMPAT_SOCKET", str(run / "gone" / "old.sock"))   # its directory does not exist
    keep = run / "keep"
    keep.mkdir()
    (keep / "ttyd.sock").write_text("a regular file")   # not a socket and not a link: left alone
    monkeypatch.setenv("SALA_WEB_COMPAT_TTYD_SOCKET", str(keep / "ttyd.sock"))
    s = Settings()
    assert A.link_compat_sockets(s, s.socket) == []
    assert not (run / "gone").exists()
    assert (keep / "ttyd.sock").read_text() == "a regular file"
    err = capsys.readouterr().err
    assert "does not exist" in err and "left alone" in err


def test_unset_means_nothing(tmp_path):
    s = Settings()
    assert A.link_compat_sockets(s, s.socket) == []


def test_the_bound_path_of_an_activated_socket(short):
    p = short / "a.sock"
    s = serve(p)
    try:
        assert A._bound_path(s.fileno()) == p
        s.getsockname()   # the probe used a duplicate: the listener is still open
    finally:
        s.close()
