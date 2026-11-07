"""The Shell drawer's server half: the tmux session of SALA_SHELL_SESSION, the key row's endpoint, and that no list shows it.

The drawer is a small console at the bottom of the page: a ttyd iframe on `/tty/?arg=<session>`. ttyd-tmux-attach attaches only
to a session that already exists, so the server makes it: `POST /api/shell/open` creates a plain login bash in the home directory
when there is none and touches an existing one not at all. `POST /api/shell/keys` sends one key (from a fixed list of tmux key
names, never text) to it, for the phone's key row. And the shell session is no Claude session: no list of sessions shows it.

Real tmux, on a private server: a socket of its own in a short TMUX_TMPDIR (a unix socket path is capped at 108 bytes, and a CI
runner's pytest tmp_path is longer than that, so the socket folder is `/tmp/hpt-*`, made with mkdtemp), `-f /dev/null` (no
config), an isolated HOME. The server is stopped with its own `kill-server`; both temp folders are locked (flock) while the test
runs and the socket folder is removed at the end, whatever the outcome; nothing is killed by name and the fleet's tmux server is never addressed.
"""

from __future__ import annotations

import fcntl
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import pytest
from starlette.testclient import TestClient

from sala_web import sessions as S
from sala_web import tmuxio as T
from sala_web.app import create_app
from sala_web.config import SHELL_SESSION, Settings

pytestmark = pytest.mark.skipif(shutil.which("tmux") is None, reason="needs tmux")


class Box:
    """A private tmux server (own TMUX_TMPDIR and socket name), an isolated HOME, the app on it, and the cleanup."""

    def __init__(self, tmp_path, monkeypatch):
        self.tmp = tmp_path
        self.home = tmp_path / "home"
        self.home.mkdir()
        self.tmuxdir = Path(tempfile.mkdtemp(prefix="hpt-", dir="/tmp"))   # short: the socket path must stay under 108 bytes
        self.sock = f"salaweb-pytest-shell-{os.getpid()}"
        monkeypatch.setenv("HOME", str(self.home))
        monkeypatch.setenv("TMUX_TMPDIR", str(self.tmuxdir))
        monkeypatch.delenv("TMUX", raising=False)
        monkeypatch.setattr(S, "live_tmux_names", lambda: {})
        self.lock = os.open(tmp_path, os.O_RDONLY)   # the temp folders are locked while the test runs (systemd-tmpfiles ageing honors flock)
        fcntl.flock(self.lock, fcntl.LOCK_SH)
        self.lock2 = os.open(self.tmuxdir, os.O_RDONLY)
        fcntl.flock(self.lock2, fcntl.LOCK_SH)
        self.claude = tmp_path / "claude"
        (self.claude / "sessions").mkdir(parents=True)
        (self.claude / "projects").mkdir()
        self.settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=self.claude,
                                 tmux_socket_name=self.sock, roles_cmd=["false"], sala_models=tmp_path / "none.tsv",
                                 admin_key=tmp_path / "none-key")
        self.client = TestClient(create_app(self.settings))

    def tmux(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(["tmux", "-L", self.sock, "-f", "/dev/null", *args], capture_output=True, text=True,
                              env={**os.environ, "HOME": str(self.home), "TMUX_TMPDIR": str(self.tmuxdir)})

    def post(self, path: str, body: object = None, **kw):
        return self.client.post(path, json=body if body is not None else {}, **kw)

    def pane_field(self, field: str) -> str:
        return self.tmux("display-message", "-p", "-t", "=" + SHELL_SESSION + ":", "#{" + field + "}").stdout.strip()

    def wait_for(self, path, want: str, secs: float = 8) -> str:
        end = time.time() + secs
        text = ""
        while time.time() < end:
            if path.exists():
                text = path.read_text()
                if want in text:
                    return text
            time.sleep(0.05)
        return text

    def close(self):
        try:
            self.tmux("kill-server")
        finally:
            try:
                shutil.rmtree(self.tmuxdir, ignore_errors=True)
            finally:
                for fd in (self.lock2, self.lock):
                    fcntl.flock(fd, fcntl.LOCK_UN)
                    os.close(fd)


@pytest.fixture
def box(tmp_path, monkeypatch):
    b = Box(tmp_path, monkeypatch)
    try:
        yield b
    finally:
        b.close()


def test_open_creates_the_shell_when_missing_and_reuses_it_when_present(box):
    assert box.tmux("has-session", "-t", "=" + SHELL_SESSION).returncode != 0
    r = box.post("/api/shell/open")
    assert r.status_code == 200, r.text
    assert r.json() == {"ok": True, "session": SHELL_SESSION, "created": True}
    # a plain login bash in the home directory (the isolated one), alone in its session
    assert box.tmux("has-session", "-t", "=" + SHELL_SESSION).returncode == 0
    for _ in range(60):
        if box.pane_field("pane_current_command") == "bash":
            break
        time.sleep(0.05)
    assert box.pane_field("pane_current_command") == "bash"
    assert os.path.realpath(box.pane_field("pane_current_path")) == os.path.realpath(box.home)
    assert box.tmux("list-sessions", "-F", "#{session_name}").stdout.split() == [SHELL_SESSION]
    pane = box.pane_field("pane_id")
    # asked again, it is reused: same pane, nothing created, nothing sent to it
    r = box.post("/api/shell/open")
    assert r.status_code == 200 and r.json()["created"] is False
    assert box.pane_field("pane_id") == pane
    assert box.tmux("list-sessions", "-F", "#{session_name}").stdout.split() == [SHELL_SESSION]
    # once the shell has ended, the next open makes a new one and says so (the page then reloads its frame)
    box.tmux("kill-session", "-t", "=" + SHELL_SESSION)
    assert box.post("/api/shell/open").json()["created"] is True


def _scroll_on_clear(box) -> str:
    return box.tmux("show-options", "-w", "-A", "-v", "-t", "=" + SHELL_SESSION + ":", "scroll-on-clear").stdout.strip()


def test_the_shell_window_has_scroll_on_clear_off_when_made_and_when_already_there(box):
    # ble.sh redraws its prompt on every resize and tmux's scroll-on-clear would save each one into the history
    import asyncio
    assert asyncio.run(T.ensure_shell_session(box.settings)) is True
    assert _scroll_on_clear(box) == "off"
    # a session made before this setting existed (the option still at its default) gets it on the next ensure, nothing else changed
    box.tmux("kill-session", "-t", "=" + SHELL_SESSION)
    box.tmux("new-session", "-d", "-s", SHELL_SESSION, "sleep", "300")
    assert _scroll_on_clear(box) == "on"
    pane = box.pane_field("pane_id")
    assert asyncio.run(T.ensure_shell_session(box.settings)) is False
    assert _scroll_on_clear(box) == "off"
    assert box.pane_field("pane_id") == pane
    assert asyncio.run(T.ensure_shell_session(box.settings)) is False   # idempotent
    assert _scroll_on_clear(box) == "off"
    # only this session: another session's window keeps the default
    box.tmux("new-session", "-d", "-s", "someone-else", "sleep", "300")
    assert box.tmux("show-options", "-w", "-A", "-v", "-t", "=someone-else:", "scroll-on-clear").stdout.strip() == "on"


def test_open_never_touches_other_sessions(box):
    box.tmux("new-session", "-d", "-s", "someone-else", "sleep", "300")
    box.post("/api/shell/open")
    assert sorted(box.tmux("list-sessions", "-F", "#{session_name}").stdout.split()) == [SHELL_SESSION, "someone-else"]


def test_two_opens_at_once_make_one_shell(box):
    import asyncio

    async def both():
        return await asyncio.gather(T.ensure_shell_session(box.settings), T.ensure_shell_session(box.settings))
    created = asyncio.run(both())
    assert sorted(created) == [False, True]
    assert box.tmux("list-sessions", "-F", "#{session_name}").stdout.split() == [SHELL_SESSION]


def test_the_posts_are_guarded_like_the_other_posts(box):
    for path in ("/api/shell/open", "/api/shell/keys"):
        assert box.client.post(path, content="{}", headers={"content-type": "text/plain"}).status_code == 415
        assert box.post(path, {"key": "Tab"}, headers={"origin": "https://evil.example"}).status_code == 403
    assert box.client.get("/api/shell/open").status_code == 405
    assert box.tmux("has-session", "-t", "=" + SHELL_SESSION).returncode != 0   # none of that made a shell


@pytest.mark.parametrize("bad", [
    "ls", "ls\n", "echo hi", "C-c; rm x", "Enter ", " Tab", "tab", "escape", "C-A", "C-1", "M-x", "F1", "Space", "-l", "",
    "Tab Tab", "Escape\nEnter", "C-c C-c", "$(id)", "C-" + "a" * 3, "\x1b", "\x03",
])
def test_the_keys_endpoint_refuses_anything_off_its_list(box, bad):
    box.post("/api/shell/open")
    r = box.post("/api/shell/keys", {"key": bad})
    assert r.status_code == 400, (bad, r.text)


@pytest.mark.parametrize("body", [{}, {"key": None}, {"key": 3}, {"key": ["Tab"]}, {"key": {"a": 1}}, {"keys": "Tab"}, ["Tab"], "Tab", 7])
def test_the_keys_endpoint_takes_only_a_key_string(box, body):
    box.post("/api/shell/open")
    assert box.client.post("/api/shell/keys", json=body).status_code == 400
    assert box.client.post("/api/shell/keys", content="not json", headers={"content-type": "application/json"}).status_code == 400


def test_the_list_is_fixed_and_holds_only_names_not_text():
    assert {"Escape", "Tab", "Up", "Down", "C-c", "C-a", "C-z"} <= T.SHELL_KEYS
    assert "a" not in T.SHELL_KEYS and "ls" not in T.SHELL_KEYS
    import asyncio
    with pytest.raises(T.TmuxError):
        asyncio.run(T.send_shell_key(Settings(tmux_socket_name="salaweb-pytest-none"), "ls"))


def test_a_key_reaches_the_shell_and_only_the_shell(box):
    other = box.tmp / "other.txt"
    box.tmux("new-session", "-d", "-s", "someone-else", f"cat -v > {other}")
    box.post("/api/shell/open")
    out = box.tmp / "keys.txt"
    for _ in range(60):   # bash is up
        if box.pane_field("pane_current_command") == "bash":
            break
        time.sleep(0.05)
    box.tmux("send-keys", "-t", "=" + SHELL_SESSION + ":", "-l", f"cat -vT > {out}")
    box.tmux("send-keys", "-t", "=" + SHELL_SESSION + ":", "Enter")
    time.sleep(0.4)
    for k in ("Tab", "Escape", "C-a", "Enter", "C-d"):
        r = box.post("/api/shell/keys", {"key": k})
        assert r.status_code == 200 and r.json() == {"ok": True, "sent": k}, (k, r.text)
    text = box.wait_for(out, "^A")
    assert text.startswith("^I^[^A"), repr(text)       # Tab, Escape, Ctrl+A, in that order, as cat -v shows them
    assert not other.exists() or other.read_text() == ""   # the other session got nothing


def test_a_key_with_no_shell_running_is_a_plain_error_and_makes_none(box):
    r = box.post("/api/shell/keys", {"key": "Tab"})
    assert r.status_code == 502 and "not running" in r.json()["error"]
    assert box.tmux("has-session", "-t", "=" + SHELL_SESSION).returncode != 0


def test_the_shell_is_in_no_list_of_sessions(box, monkeypatch):
    """A registry row that points into the shell session (a claude someone started by hand inside it) is not listed: not by the
    session reader, not by /api/sessions; a row in any other tmux session is."""
    pid = os.getpid()
    rows = {"shellrow": {"name": "in-the-shell", "tmux": f"{SHELL_SESSION}:@0.%7"},
            "normal": {"name": "a-claude", "tmux": "a-claude:@1.%9"}}
    for key, extra in rows.items():
        # one registry row each: the pid is this process's (alive); the second needs a pid of its own, so a second live process
        p = pid if key == "shellrow" else os.getppid()
        (box.claude / "sessions" / f"{p}.json").write_text(json.dumps(
            {"pid": p, "sessionId": f"aaaaaaaa-0000-4000-8000-00000000000{len(key) % 9}", "cwd": "/tmp", "status": "idle",
             "procStart": S.proc_start(p), **extra}))
    names = sorted(s.name for s in S.read_live_sessions(box.settings))
    assert names == ["a-claude"], names
    for path in ("/api/sessions", "/api/overview"):   # the sidebar's list and the Overview's cards
        r = box.client.get(path)
        assert r.status_code == 200, (path, r.text)
        text = json.dumps(r.json())
        assert "in-the-shell" not in text and "a-claude" in text, path


def test_the_shell_lock_is_made_per_event_loop_on_first_use():
    """No lock exists at import; each running loop gets its own, and the same one again within that loop (review)."""
    import asyncio

    async def two():
        return T._shell_lock(), T._shell_lock()

    a1, a2 = asyncio.run(two())
    b1, _ = asyncio.run(two())
    assert a1 is a2 and a1 is not b1


def test_the_session_name_comes_from_SALA_SHELL_SESSION_with_the_same_default(tmp_path):
    """sala-web reads the setting sala's lib/common.sh reads: unset or empty it is sala-shell (no owner's name is built in); a name in
    the environment wins over one in sala's config file, which is read as text when the environment has none. A fresh interpreter,
    since the name is read once at import."""
    cfg = tmp_path / "config"

    def name(env_extra, config=None):
        env = {k: v for k, v in os.environ.items() if k not in ("SALA_SHELL_SESSION", "SALA_CONFIG")}
        env["SALA_CONFIG"] = str(cfg)
        cfg.write_text(config if config is not None else "")
        env.update(env_extra)
        env["PYTHONPATH"] = os.pathsep.join(sys.path)
        r = subprocess.run([sys.executable, "-c", "from sala_web.config import SHELL_SESSION as s; print(s)"],
                           capture_output=True, text=True, env=env)
        assert r.returncode == 0, r.stderr
        return r.stdout.strip()

    assert name({}) == "sala-shell"
    assert name({"SALA_SHELL_SESSION": ""}) == "sala-shell"
    assert name({"SALA_SHELL_SESSION": "my-console"}) == "my-console"
    # the config file: the owner's line is all a box needs
    assert name({}, "SALA_SHELL_SESSION=my-console\n") == "my-console"
    assert name({}, "#SALA_SHELL_SESSION=commented\n") == "sala-shell"
    assert name({}, "export SALA_SHELL_SESSION='quoted-name'  # a note\n") == "quoted-name"
    assert name({}, "SALA_SHELL_SESSION=first\nSALA_SHELL_SESSION=second\n") == "second"   # the last assignment wins, as when sourced
    assert name({"SALA_SHELL_SESSION": "from-env"}, "SALA_SHELL_SESSION=from-file\n") == "from-env"
    assert name({}, "SALA_SHELL_SESSION_OTHER=nope\n") == "sala-shell"
