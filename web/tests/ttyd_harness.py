"""A real ttyd on a scratch tmux session, for the browser tests of the Terminal tab and the Shell drawer.

`Pane` is a tmux session on a PRIVATE socket (its own temp folder, TMUX_TMPDIR) with a real ttyd attached to it; `Router` puts the
app (conftest.py `served`) and that ttyd behind one same-origin loopback address, as the reverse proxy of docs/web-proxy.md does,
so that the app can reach the frame's `window.term`. `real_ttyd` is the fixture body: temp folder locked while it runs and removed
at the end, ttyd stopped by its own pid, the private tmux server stopped through its own socket, the router stopped.
"""

from __future__ import annotations

import asyncio
import contextlib
import fcntl
import os
import re
import shutil
import socket
import subprocess
import tempfile
import threading
import time

import pytest

# the pane prints READY, then what it reads: raw mode (no echo, no line editing, no signals), `cat -v` writes control characters as ^X
READ_CMD = "stty -icanon -echo -isig -ixon -iexten; echo READY; exec cat -v"


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Router:
    """A byte-level router on one loopback port: a request whose path starts with /tty goes to ttyd, every other one to the app, so
    that the app's page and ttyd's page are one origin (the frame's `term` is readable from the app, as behind the real proxy).
    Each request is sent with `Connection: close`, so the first request line of a connection is all the routing there is; a
    websocket upgrade is piped through as it is."""

    def __init__(self, app_port: int, ttyd_port: int):
        self.app_port, self.ttyd_port = app_port, ttyd_port
        self.port = _free_port()
        self.loop = asyncio.new_event_loop()
        self.ready = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        self.thread.start()
        assert self.ready.wait(10)

    def stop(self):
        self.loop.call_soon_threadsafe(self.stop_ev.set)
        self.thread.join(timeout=10)

    def _run(self):
        asyncio.set_event_loop(self.loop)
        self.loop.run_until_complete(self._serve())

    async def _serve(self):
        self.stop_ev = asyncio.Event()
        server = await asyncio.start_server(self._handle, "127.0.0.1", self.port)
        self.ready.set()
        await self.stop_ev.wait()
        server.close()
        await asyncio.sleep(0.05)

    async def _handle(self, reader, writer):
        up_w = None
        try:
            head = await reader.readuntil(b"\r\n\r\n")
            path = head.split(b" ", 2)[1]
            port = self.ttyd_port if path.startswith(b"/tty") else self.app_port
            if b"upgrade: websocket" not in head.lower():
                head = re.sub(rb"(?im)^connection:[^\r\n]*\r\n", b"", head).replace(b"\r\n\r\n", b"\r\nConnection: close\r\n\r\n", 1)
            m = re.search(rb"(?im)^content-length:\s*(\d+)", head)
            body = await reader.readexactly(int(m.group(1))) if m else b""
            up_r, up_w = await asyncio.open_connection("127.0.0.1", port)
            up_w.write(head + body)
            await up_w.drain()

            async def pipe(src, dst):
                try:
                    while chunk := await src.read(65536):
                        dst.write(chunk)
                        await dst.drain()
                except (ConnectionError, OSError):
                    pass
                finally:
                    try:
                        dst.close()
                    except Exception:
                        pass

            await asyncio.gather(pipe(reader, up_w), pipe(up_r, writer))
        except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, ConnectionError, OSError):
            pass
        finally:
            for w in (writer, up_w):
                try:
                    if w:
                        w.close()
                except Exception:
                    pass


class Pane:
    """ttyd attached to a scratch tmux session, both on a private socket in a temp folder of their own."""

    def __init__(self, tmp: str, cmd: str = READ_CMD, options: tuple = ()):
        self.tmp, self.cmd, self.options = tmp, cmd, options
        self.sock = "ctrlv-" + os.path.basename(tmp)[-8:]
        self.env = {k: v for k, v in os.environ.items() if k not in ("TMUX", "TMUX_PANE")}
        self.env["TMUX_TMPDIR"] = tmp
        self.ttyd = None

    def tmux(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(["tmux", "-L", self.sock, "-f", "/dev/null", *args], env=self.env, capture_output=True, text=True, timeout=20)

    def start(self, ttyd_port: int):
        self.ttyd_port = ttyd_port
        r = self.tmux("new-session", "-d", "-s", "scratch", "-x", "100", "-y", "20", f"sh -c '{self.cmd}'")
        assert r.returncode == 0, r.stderr
        for opt in self.options:                          # tmux settings of this private server, e.g. ("set", "-g", "mouse", "on")
            r = self.tmux(*opt)
            assert r.returncode == 0, r.stderr
        self._spawn_ttyd()

    def _spawn_ttyd(self):
        ttyd_port = self.ttyd_port
        self.ttyd = subprocess.Popen(
            ["ttyd", "-i", "127.0.0.1", "-p", str(ttyd_port), "-b", "/tty", "-W", "tmux", "-L", self.sock, "-f", "/dev/null", "attach", "-t", "scratch"],
            env=self.env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def restart_ttyd(self):
        """ttyd stopped and started again on the same port (the service restarting): the page's websocket drops and reconnects."""
        self.ttyd.terminate()
        self.ttyd.wait(timeout=10)
        self._spawn_ttyd()

    def text(self) -> str:
        return self.tmux("capture-pane", "-p", "-t", "scratch").stdout

    def wait_for(self, needle: str, seconds: float = 8) -> bool:
        t0 = time.time()
        while time.time() - t0 < seconds:
            if needle in self.text():
                return True
            time.sleep(0.1)
        return False

    def stop(self):
        if self.ttyd and self.ttyd.poll() is None:       # the process this test started, by its pid
            self.ttyd.terminate()
            try:
                self.ttyd.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.ttyd.kill()
                self.ttyd.wait(timeout=10)
        self.tmux("kill-server")                          # the private socket's server: nobody else's


@contextlib.contextmanager
def real_ttyd(served, cmd: str = READ_CMD, options: tuple = ()):
    """(pane, router.port) with the app and ttyd behind one address; skips when ttyd or tmux is not installed."""
    if not shutil.which("ttyd") or not shutil.which("tmux"):
        pytest.skip("ttyd or tmux is not installed")
    tmp = tempfile.mkdtemp(prefix="salaweb-ctrlv-")
    lock = os.open(tmp, os.O_RDONLY)
    fcntl.flock(lock, fcntl.LOCK_EX)                      # held while the test runs (systemd-tmpfiles ageing honours it)
    pane, router = Pane(tmp, cmd, options), None
    try:
        ttyd_port = _free_port()
        pane.start(ttyd_port)
        router = Router(int(served["url"].rsplit(":", 1)[1]), ttyd_port)
        router.start()
        yield pane, router.port
    finally:
        try:
            pane.stop()
        finally:
            if router:
                router.stop()
            os.close(lock)
            shutil.rmtree(tmp, ignore_errors=True)


ALT, CTRL, META, SHIFT = 1, 2, 4, 8   # DevTools modifier bits (Alt 1, Ctrl 2, Meta/Command 4, Shift 8)


def press(b, key: str, code: str, vk: int, modifiers: int = 0, text: str | None = None, commands: list[str] | None = None):
    """A real key press on the page's focused element (the frame's xterm textarea): the DevTools key event goes through the
    browser's own key handling, so the page's keydown handlers, their preventDefault and the editing command all apply."""
    ev = {"key": key, "code": code, "windowsVirtualKeyCode": vk, "nativeVirtualKeyCode": vk, "modifiers": modifiers}
    if text:
        ev["text"] = text
    down = dict(ev, type="keyDown" if text else "rawKeyDown")
    if commands:
        down["commands"] = commands
    b.send("Input.dispatchKeyEvent", down)
    b.send("Input.dispatchKeyEvent", dict(ev, type="keyUp"))
