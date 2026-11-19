"""The ttyd harness picks another port when the one it chose is taken before ttyd binds it."""

import shutil
import socket
import tempfile

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
