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


class _Listener:
    """A loopback listener that answers each connection with `chunks` (0.3 s between them), then closes it, or keeps it open when
    `silent_after`. close() stops the accept loop and closes every accepted socket, so no thread or connection outlives the test."""

    def __init__(self, chunks, silent_after=False):
        self.srv = socket.socket()
        self.srv.bind(("127.0.0.1", 0))
        self.srv.listen(8)
        self.srv.settimeout(0.2)                          # accept() wakes up to see the stop flag, whatever the platform does on close
        self.port = self.srv.getsockname()[1]
        self.chunks, self.silent_after = chunks, silent_after
        self.stop, self.conns = threading.Event(), []
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self):
        while not self.stop.is_set():
            try:
                c, _ = self.srv.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            self.conns.append(c)
            try:
                c.recv(4096)
                for ch in self.chunks:
                    c.sendall(ch)
                    time.sleep(0.3)
            except OSError:
                pass
            if not self.silent_after:
                c.close()

    def close(self):
        self.stop.set()
        self.thread.join(timeout=5)
        for c in self.conns:
            c.close()
        self.srv.close()


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
    srv = _Listener([b"HTTP/1.0 200 OK\r\nServer: nginx\r\n\r\nhello"])
    pane = _pane_with_live_child(srv.port)
    try:
        assert pane._wait_listening(1, raising=False) is False
    finally:
        _drop(pane, srv)


def test_ttyd_headers_that_arrive_in_pieces_still_count():
    srv = _Listener([b"HTTP/1.0 200 OK\r\n", b"content-type: text/html\r\nserver: ttyd/1.7.7 (x)\r\n\r\n<html>"])
    pane = _pane_with_live_child(srv.port)
    try:
        assert pane._wait_listening(5, raising=False) is True
    finally:
        _drop(pane, srv)


def test_a_silent_listener_does_not_outlast_the_time_given():
    srv = _Listener([], silent_after=True)
    pane = _pane_with_live_child(srv.port)
    try:
        t0 = time.monotonic()
        assert pane._wait_listening(1, raising=False) is False
        assert time.monotonic() - t0 < 1.15
    finally:
        _drop(pane, srv)


def test_a_truncated_header_block_is_not_an_answer():
    srv = _Listener([b"HTTP/1.0 200 OK\r\nServer: ttyd/1.7.7\r\n"])      # closes before the blank line
    pane = _pane_with_live_child(srv.port)
    try:
        assert pane._wait_listening(1, raising=False) is False
    finally:
        _drop(pane, srv)
