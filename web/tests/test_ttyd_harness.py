"""The ttyd harness picks another port when the one it chose is taken before ttyd binds it."""

import shutil
import socket
import subprocess
import tempfile
import threading
import time

import pytest

from ttyd_harness import Pane


def test_a_port_held_by_another_listener_is_not_taken_for_ttyd():
    if not shutil.which("ttyd") or not shutil.which("tmux"):
        pytest.skip("ttyd or tmux is not installed")
    held = socket.socket()
    held.bind(("127.0.0.1", 0))
    held.listen(8)                                        # accepts connections but never answers as ttyd
    taken = held.getsockname()[1]
    tmp = tempfile.mkdtemp(prefix="salaweb-ctrlv-")
    pane = Pane(tmp)
    try:
        pane.start(taken)
        assert pane.ttyd_port != taken
        assert pane.ttyd.poll() is None
    finally:
        pane.stop()
        held.close()
        shutil.rmtree(tmp, ignore_errors=True)


def _listener(chunks, silent_after=False):
    """A loopback listener that answers each connection with `chunks` (pause between them), then stays open if silent_after."""
    srv = socket.socket()
    srv.bind(("127.0.0.1", 0))
    srv.listen(8)

    def serve():
        while True:
            try:
                c, _ = srv.accept()
            except OSError:
                return
            c.recv(4096)
            for ch in chunks:
                c.sendall(ch)
                time.sleep(0.3)
            if not silent_after:
                c.close()

    threading.Thread(target=serve, daemon=True).start()
    return srv


def _pane_with_live_child(port):
    pane = Pane(tempfile.mkdtemp(prefix="salaweb-ctrlv-"))
    pane.ttyd = subprocess.Popen(["sleep", "30"])       # a child that stays alive, so only the answer decides
    pane.ttyd_port = port
    return pane


def _drop(pane, srv):
    pane.ttyd.kill()
    pane.ttyd.wait(timeout=10)
    srv.close()
    shutil.rmtree(pane.tmp, ignore_errors=True)


def test_an_unrelated_http_answer_is_not_ttyd_even_with_the_child_alive():
    srv = _listener([b"HTTP/1.0 200 OK\r\nServer: nginx\r\n\r\nhello"])
    pane = _pane_with_live_child(srv.getsockname()[1])
    try:
        assert pane._wait_listening(1, raising=False) is False
    finally:
        _drop(pane, srv)


def test_ttyd_headers_that_arrive_in_pieces_still_count():
    srv = _listener([b"HTTP/1.0 200 OK\r\n", b"content-type: text/html\r\nserver: ttyd/1.7.7 (x)\r\n\r\n<html>"])
    pane = _pane_with_live_child(srv.getsockname()[1])
    try:
        assert pane._wait_listening(5, raising=False) is True
    finally:
        _drop(pane, srv)


def test_a_silent_listener_does_not_outlast_the_time_given():
    srv = _listener([], silent_after=True)
    pane = _pane_with_live_child(srv.getsockname()[1])
    try:
        t0 = time.monotonic()
        assert pane._wait_listening(1, raising=False) is False
        assert time.monotonic() - t0 < 1.5
    finally:
        _drop(pane, srv)
