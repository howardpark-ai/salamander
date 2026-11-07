"""A running `!` command shown live in the chat, read from the pane.

Claude Code writes a `!` command's output to the transcript only when the command ends or times out, and the chat read
only the transcript, so a command that waits (a command that waits for input) showed nothing. The stream sends
`live` events with the pane's text while a `!` command runs, and `POST /api/s/<pid>/stop` sends Escape (then Ctrl-C).
An earlier version gated both on a `<bash-input>` transcript record and on a pane with no input box; a real-pane check on Claude Code
2.1.312 found neither (no `bash-` line in the transcript until the command ends; the input box stays on screen, with the
output, `+14 lines (18s)`, `(ctrl+b ctrl+b (twice) to run in background)` and a footer `esc to interrupt`). The pane now decides
(`tmuxio.bang_pane`, checked on text in test_bang_pane.py); the transcript record is a fallback, kept for a Claude Code that
writes one and draws no input box.

Checked here: the fallback's detection on transcript fixtures (running, finished, stderr, no `!` record, a stale record
after a prompt, the incremental scan); the pane text of the fallback trimmed to the command's output; the stream's `live`
event with a fake pane, for a pane that shows a running command and a transcript with no `!` record at all (shown, changed,
cleared when the pane is back to its prompt, shown again on a reconnect, never shown for a model turn or a model's own Bash
call that shows `esc to interrupt`, one look every couple of seconds when nothing runs) and for the fallback; the Stop endpoint
(Escape only when that stops it, Ctrl-C when not, keys only to that session's pane, 409 with nothing sent when nothing runs
or only a model turn does, the origin and content-type guards); and, in a headless Chromium, that a `live` event renders the
block with a Stop button and that the clear event removes it.

The panes are a stand-in for Claude Code on a private tmux server (-L salaweb-pytest-live-<pid> -f /dev/null), killed in
teardown: a Python program in raw mode that draws a screen from a file and records the keys it receives (hex) in another.
"""

from __future__ import annotations

import http.client
import json
import os
import shutil
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

import pytest
from starlette.testclient import TestClient

from conftest import NAME
from test_composer_attach import WAIT_READY
from sala_web import app as A
from sala_web import sessions as S
from sala_web import tmuxio as T
from sala_web import transcript as TR
from sala_web.app import create_app
from sala_web.config import Settings

RULE = "─" * 40
# the screen of a Claude Code that draws no input box while a command runs, and records it in the transcript: the fallback
RUNNING = "! sleep 20; echo hi\nFirst copy your one-time code: ABCD-1234\nOpen https://example.com/device\n\n✻ Running… (3s · esc to interrupt)\n"
# Claude Code 2.1.312's screens (tests/fixtures/pane-*.txt), no `!` record in the transcript
PANE_RUNNING = (Path(__file__).parent / "fixtures" / "pane-bang-running.txt").read_text()
PANE_FINISHED = (Path(__file__).parent / "fixtures" / "pane-bang-finished.txt").read_text()
PANE_TURN = (Path(__file__).parent / "fixtures" / "pane-assistant-turn.txt").read_text()
PANE_BASH_TOOL = (Path(__file__).parent / "fixtures" / "pane-assistant-bash-tool.txt").read_text()
PANE_OUT = ("Hit:1 http://archive.ubuntu.com/ubuntu resolute InRelease\n"
            "Get:2 http://archive.ubuntu.com/ubuntu resolute-updates InRelease [126 kB]\n"
            "Reading package lists...\nBuilding dependency tree...")
IDLE = f"old output\n{RULE}\n❯\n{RULE}\n"
PANE_SID = "bbbbbbbb-0000-4000-8000-000000000001"

FAKE_PANE = r"""
import os, shutil, sys, threading, time, tty
screen, keys, idle = sys.argv[1], sys.argv[2], sys.argv[3]
tty.setraw(0)
def reader():
    while True:
        data = os.read(0, 32)
        if not data:
            return
        with open(keys, "a") as f:
            f.write(data.hex() + "\n")
        if idle != "-" and b"\x1b" in data:  # Escape stops the command: the screen goes back to the input box
            shutil.copy(idle, screen)
threading.Thread(target=reader, daemon=True).start()
last = None
while True:
    try:
        cur = open(screen).read()
    except OSError:
        cur = ""
    if cur != last:
        last = cur
        sys.stdout.write("\x1b[2J\x1b[H" + cur.replace("\n", "\r\n"))
        sys.stdout.flush()
    time.sleep(0.05)
"""


def user_line(content, uuid, ts="2026-10-27T10:00:00.000Z") -> str:
    return json.dumps({"type": "user", "uuid": uuid, "timestamp": ts, "message": {"role": "user", "content": content}}) + "\n"


def assistant_line(text, uuid) -> str:
    return json.dumps({"type": "assistant", "uuid": uuid, "timestamp": "2026-10-27T10:00:01.000Z",
                       "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}}) + "\n"


PROMPT = user_line("run it", "u-1")
BANG_IN = user_line("<bash-input>sleep 20; echo hi</bash-input>", "b-1")
BANG_OUT = user_line("<bash-stdout>hi</bash-stdout><bash-stderr></bash-stderr>", "b-2")


# ---------- the detection, on transcript fixtures ----------

def written(tmp_path, *lines: str):
    p = tmp_path / "t.jsonl"
    p.write_text("".join(lines))
    return p


def test_a_bash_input_with_no_output_record_is_running(tmp_path):
    p = written(tmp_path, PROMPT, assistant_line("ok", "a-1"), BANG_IN)
    got = TR.bang_running(p)
    assert got == {"command": "sleep 20; echo hi", "uuid": "b-1", "ts": "2026-10-27T10:00:00.000Z"}, got


def test_a_finished_command_is_not_running(tmp_path):
    assert TR.bang_running(written(tmp_path, PROMPT, BANG_IN, BANG_OUT)) is None
    # stderr alone ends it too
    assert TR.bang_running(written(tmp_path, BANG_IN, user_line("<bash-stderr>boom</bash-stderr>", "b-3"))) is None
    # an earlier finished command, a later running one: the later one
    p = written(tmp_path, BANG_IN, BANG_OUT, user_line("<bash-input>second</bash-input>", "b-4"))
    assert TR.bang_running(p)["command"] == "second"


def test_no_bash_input_is_not_running(tmp_path):
    assert TR.bang_running(written(tmp_path, PROMPT, assistant_line("hello", "a-1"))) is None
    assert TR.bang_running(written(tmp_path)) is None
    assert TR.bang_running(tmp_path / "missing.jsonl") is None


def test_a_prompt_after_the_record_makes_it_stale(tmp_path):
    # the command died without an output record and the conversation went on: not running
    p = written(tmp_path, BANG_IN, assistant_line("ok", "a-1"), user_line("what now?", "u-2"))
    assert TR.bang_running(p) is None
    # a notice or a tool result in between is not a prompt of the owner's
    note = user_line("<task-notification><summary>done</summary></task-notification>", "n-1")
    result = user_line([{"type": "tool_result", "tool_use_id": "t1", "content": "x"}], "r-1")
    assert TR.bang_running(written(tmp_path, BANG_IN, note, result))["uuid"] == "b-1"


def test_the_record_is_found_beyond_the_first_window(tmp_path):
    filler = "".join(assistant_line("x" * 2000, f"a-{i}") for i in range(300))  # ~600 KB after the record
    p = written(tmp_path, BANG_IN, filler)
    assert TR.bang_running(p, first=64 << 10) is not None
    assert TR.bang_running(p, first=64 << 10, cap=128 << 10) is None  # past the cap it is not looked for


def test_the_incremental_scan_follows_the_lines_appended(tmp_path):
    p = written(tmp_path, PROMPT)
    end = p.stat().st_size
    assert TR.bang_scan(p, end, end, None) is None
    with p.open("a") as f:
        f.write(BANG_IN)
    new = p.stat().st_size
    running = TR.bang_scan(p, end, new, None)
    assert running and running["command"] == "sleep 20; echo hi"
    with p.open("a") as f:
        f.write(assistant_line("still going", "a-2"))
    assert TR.bang_scan(p, new, p.stat().st_size, running) == running  # an assistant line does not end it
    mid = p.stat().st_size
    with p.open("a") as f:
        f.write(BANG_OUT)
    assert TR.bang_scan(p, mid, p.stat().st_size, running) is None


# ---------- the pane text ----------

def test_live_text_is_the_output_below_the_command_without_chrome():
    captured = f"earlier chat\nmore\n{RUNNING}"
    assert T.live_text(captured, "sleep 20; echo hi") == "First copy your one-time code: ABCD-1234\nOpen https://example.com/device"
    # the input area's rules and the footer under them are cut; a rule higher up (the command's own) stays
    body = "\n".join(f"o{i}" for i in range(12))
    captured = f"! make\nbuilding\n{RULE}\n{body}\n\n{RULE}\n❯\n{RULE}\n  ? for shortcuts\n"
    assert T.live_text(captured, "make") == f"building\n{RULE}\n{body}"
    # without the command's echo the whole screen is shown; escape sequences are dropped
    assert T.live_text("\x1b[2mdim\x1b[0m line\n", "nothing like it") == "dim line"
    # bounded: the last 40 lines, each cut
    many = "\n".join(f"line {i}" for i in range(100))
    got = T.live_text(many, "").split("\n")
    assert len(got) == T.LIVE_LINES and got[-1] == "line 99"
    assert len(T.live_text("y" * 5000, "")) == T.LIVE_LINE_CHARS


def test_send_key_takes_ctrl_c_and_still_refuses_other_keys():
    assert T.STOP_KEY == "C-c"
    with pytest.raises(T.TmuxError):
        asyncio_run(T.send_key(Settings(tmux_socket_name="salaweb-pytest-none"), "%0", "q"))


def asyncio_run(coro):
    import asyncio
    return asyncio.run(coro)


# ---------- the stream and Stop, against fake panes ----------

pytestmark_tmux = pytest.mark.skipif(shutil.which("tmux") is None, reason="needs tmux")


class Panes:
    """A private tmux server with fake Claude Code panes, each with a screen file and a keys file."""

    def __init__(self, tmp_path):
        self.tmp = tmp_path
        self.sock = f"salaweb-pytest-live-{os.getpid()}"
        self.base = ["tmux", "-L", self.sock, "-f", "/dev/null"]
        self.prog = tmp_path / "fake_pane.py"
        self.prog.write_text(FAKE_PANE)
        (tmp_path / "idle.txt").write_text(IDLE)
        self.claude = tmp_path / "claude"
        (self.claude / "sessions").mkdir(parents=True)
        (self.claude / "projects").mkdir()
        self.settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=self.claude,
                                 tmux_socket_name=self.sock, roles_cmd=["false"])
        self.n = 0

    def add(self, screen: str, transcript: str, escape_ends: bool = False) -> dict:
        """A pane showing `screen`, registered as a live session whose transcript holds `transcript`."""
        self.n += 1
        name = f"fake{self.n}"
        scr, keys = self.tmp / f"{name}.screen", self.tmp / f"{name}.keys"
        scr.write_text(screen)
        keys.write_text("")
        cmd = f"{sys.executable} {self.prog} {scr} {keys} {self.tmp / 'idle.txt' if escape_ends else '-'}"
        subprocess.run(self.base + ["new-session", "-d", "-s", name, "-x", "120", "-y", "20", cmd], check=True)
        info = subprocess.run(self.base + ["display-message", "-p", "-t", name, "#{pane_id} #{pane_pid}"],
                              check=True, capture_output=True, text=True).stdout.split()
        pane, pid = info[0], int(info[1])
        sid = f"aaaaaaaa-0000-4000-8000-00000000000{self.n}"
        rec = {"pid": pid, "sessionId": sid, "cwd": "/tmp", "name": name, "status": "busy", "tmux": f"{name}:@0.{pane}",
               "procStart": S.proc_start(pid)}
        (self.claude / "sessions" / f"{pid}.json").write_text(json.dumps(rec))
        tdir = self.claude / "projects" / TR.project_slug("/tmp")
        tdir.mkdir(exist_ok=True)
        t = tdir / f"{sid}.jsonl"
        t.write_text(transcript)
        for _ in range(60):  # wait until the screen is drawn
            cap = subprocess.run(self.base + ["capture-pane", "-p", "-t", pane], capture_output=True, text=True).stdout
            if cap.strip():
                break
            time.sleep(0.1)
        return {"name": name, "pane": pane, "pid": pid, "screen": scr, "keys": keys, "transcript": t}

    def keys(self, p: dict) -> list[str]:
        for _ in range(20):  # the fake pane writes a key down a moment after tmux sends it
            time.sleep(0.05)
        return p["keys"].read_text().split()

    def close(self):
        subprocess.run(self.base + ["kill-server"], capture_output=True)
        # tmux 3.6 keeps the socket file after kill-server: remove it, or /tmp/tmux-<uid> gains one per run
        (Path(os.environ.get("TMUX_TMPDIR") or "/tmp") / f"tmux-{os.getuid()}" / self.sock).unlink(missing_ok=True)


@pytest.fixture
def panes(tmp_path):
    p = Panes(tmp_path)
    try:
        yield p
    finally:
        p.close()


class Sse:
    """The events of a stream of a served app, read in a thread: [(name, data)], waited for by a predicate."""

    def __init__(self, port: int, pid: int):
        self.events: list[tuple[str, object]] = []
        self.conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
        self.conn.request("GET", f"/api/s/{pid}/stream")
        self.resp = self.conn.getresponse()
        self.t = threading.Thread(target=self._read, daemon=True)
        self.t.start()

    def _read(self):
        name = None
        try:
            for raw in self.resp:
                line = raw.decode().rstrip("\n")
                if line.startswith("event: "):
                    name = line[7:]
                elif line.startswith("data: ") and name:
                    self.events.append((name, json.loads(line[6:])))
                    name = None
        except (OSError, ValueError, AttributeError, http.client.HTTPException):
            pass

    def names(self) -> list[str]:
        return [n for n, _ in self.events]

    def lives(self) -> list[dict]:
        return [d for n, d in self.events if n == "live"]

    def wait(self, pred, timeout: float = 8.0) -> bool:
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if pred(self):
                return True
            time.sleep(0.05)
        return False

    def close(self):
        # shut the socket down first: close() alone waits for the reader thread, which is blocked in a read
        try:
            if self.conn.sock:
                self.conn.sock.shutdown(socket.SHUT_RDWR)
            self.conn.close()
        except OSError:
            pass
        self.t.join(timeout=5)


@pytest.fixture
def server(panes):
    import uvicorn
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    app = create_app(panes.settings)
    srv = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning"))
    t = threading.Thread(target=srv.run, daemon=True)
    t.start()
    for _ in range(100):
        if srv.started:
            break
        time.sleep(0.05)
    assert srv.started
    opened: list[Sse] = []

    def open_stream(pid: int) -> Sse:
        sse = Sse(port, pid)
        opened.append(sse)
        return sse
    try:
        yield open_stream
    finally:
        for sse in opened:
            sse.close()
        app.state.shutting_down.set()  # ends any stream still open, so the server stops at once
        srv.should_exit = True
        t.join(timeout=10)


@pytestmark_tmux
def test_the_stream_shows_a_running_command_changes_it_and_clears_it_when_the_output_lands(panes, server):
    p = panes.add(RUNNING, PROMPT + BANG_IN)
    sse = server(p["pid"])
    assert sse.wait(lambda s: s.lives()), sse.names()
    first = sse.lives()[0]
    assert first == {"running": True, "command": "sleep 20; echo hi", "uuid": "b-1",
                     "text": "First copy your one-time code: ABCD-1234\nOpen https://example.com/device"}, first
    assert sse.names().index("live") > sse.names().index("reset")  # a refresh gets the block right after the history
    # more output: a new event with the new text; the same text again is not sent again
    p["screen"].write_text(RUNNING.replace("Open https", "Then wait. Open https"))
    assert sse.wait(lambda s: len(s.lives()) == 2), sse.lives()
    assert "Then wait." in sse.lives()[1]["text"]
    time.sleep(2.0)
    assert len(sse.lives()) == 2
    # the output record lands: the normal append, then the clear
    with p["transcript"].open("a") as f:
        f.write(BANG_OUT)
    assert sse.wait(lambda s: s.lives()[-1] == {"running": False}), sse.lives()
    names = sse.names()
    assert names.index("append") < len(names) - 1 - names[::-1].index("live")  # the notice first, then the block goes
    n = len(sse.lives())
    time.sleep(2.0)
    assert len(sse.lives()) == n  # nothing more once it is over


@pytestmark_tmux
def test_the_block_goes_when_the_input_box_is_back_though_no_output_record_came(panes, server):
    p = panes.add(RUNNING, PROMPT + BANG_IN)
    sse = server(p["pid"])
    assert sse.wait(lambda s: s.lives())
    p["screen"].write_text(IDLE)
    assert sse.wait(lambda s: s.lives()[-1] == {"running": False}), sse.lives()


@pytestmark_tmux
def test_a_reconnect_during_the_command_shows_the_block_again(panes, server):
    p = panes.add(RUNNING, PROMPT + BANG_IN)
    one = server(p["pid"])
    assert one.wait(lambda s: s.lives())
    one.close()
    two = server(p["pid"])
    assert two.wait(lambda s: s.lives() and s.lives()[0]["running"]), two.names()
    assert two.names()[:2] == ["version", "status"] and "reset" in two.names()


@pytestmark_tmux
def test_an_idle_pane_gets_a_look_every_couple_of_seconds_and_no_live_event(panes, server, monkeypatch):
    calls = []
    real = T.capture

    async def counting(settings, pane):
        calls.append(pane)
        return await real(settings, pane)
    monkeypatch.setattr(T, "capture", counting)
    p = panes.add(IDLE, PROMPT + assistant_line("hello", "a-1") + BANG_IN + BANG_OUT)
    sse = server(p["pid"])
    assert sse.wait(lambda s: "reset" in s.names())
    with p["transcript"].open("a") as f:  # the transcript grows, and still no command is running
        f.write(assistant_line("more", "a-2"))
    assert sse.wait(lambda s: "append" in s.names())
    time.sleep(2.5)
    assert sse.lives() == [] and 1 <= len(calls) <= 3, (sse.lives(), calls)  # LIVE_LOOK_EVERY, not the 0.7 s of a running command


@pytestmark_tmux
def test_a_command_started_while_the_page_is_open_shows_up(panes, server):
    p = panes.add(IDLE, PROMPT)
    sse = server(p["pid"])
    assert sse.wait(lambda s: "reset" in s.names())
    p["screen"].write_text(RUNNING)
    with p["transcript"].open("a") as f:
        f.write(BANG_IN)
    assert sse.wait(lambda s: s.lives() and s.lives()[0]["running"]), sse.names()


# ---------- the stream, with Claude Code 2.1.312's screens: the pane decides, the transcript has no `!` record ----------

@pytestmark_tmux
def test_a_running_command_is_shown_from_the_pane_alone_and_cleared_when_the_prompt_is_back(panes, server):
    p = panes.add(PANE_RUNNING, PROMPT + assistant_line("ok", "a-1"))  # no bash- line in the transcript
    assert "bash-" not in p["transcript"].read_text()
    sse = server(p["pid"])
    assert sse.wait(lambda s: s.lives()), sse.names()
    assert sse.lives()[0] == {"running": True, "command": "sudo apt update", "uuid": "", "text": PANE_OUT}, sse.lives()
    assert sse.names().index("live") > sse.names().index("reset")
    # the fold counter ticks and the hint stays: the text is the same, so nothing more is sent
    p["screen"].write_text(PANE_RUNNING.replace("(18s)", "(19s)"))
    time.sleep(2.0)
    assert len(sse.lives()) == 1, sse.lives()
    # more output: a new event
    p["screen"].write_text(PANE_RUNNING.replace("Building dependency tree...", "Building dependency tree... Done"))
    assert sse.wait(lambda s: len(s.lives()) == 2) and sse.lives()[1]["text"].endswith("Done"), sse.lives()
    # the command ends: the prompt is back, no `esc to interrupt`
    p["screen"].write_text(PANE_FINISHED)
    assert sse.wait(lambda s: s.lives()[-1] == {"running": False}), sse.lives()


@pytestmark_tmux
def test_a_command_started_while_the_page_is_open_is_found_without_any_transcript_line(panes, server):
    p = panes.add(IDLE, PROMPT)
    sse = server(p["pid"])
    assert sse.wait(lambda s: "reset" in s.names())
    p["screen"].write_text(PANE_RUNNING)
    assert sse.wait(lambda s: s.lives() and s.lives()[0]["running"], timeout=10), sse.names()


@pytestmark_tmux
def test_a_reconnect_shows_the_pane_command_again(panes, server):
    p = panes.add(PANE_RUNNING, PROMPT)
    one = server(p["pid"])
    assert one.wait(lambda s: s.lives())
    one.close()
    two = server(p["pid"])
    assert two.wait(lambda s: s.lives() and s.lives()[0]["running"]), two.names()


@pytestmark_tmux
def test_a_model_turn_with_esc_to_interrupt_never_shows_a_live_block(panes, server):
    turn = panes.add(PANE_TURN, PROMPT + assistant_line("working", "a-1"))
    tool = panes.add(PANE_BASH_TOOL, PROMPT + assistant_line("working", "a-1"))  # the same hint, under a model's Bash call
    one, two = server(turn["pid"]), server(tool["pid"])
    assert one.wait(lambda s: "reset" in s.names()) and two.wait(lambda s: "reset" in s.names())
    time.sleep(4.5)  # two or three looks at each
    assert one.lives() == [] and two.lives() == [], (one.lives(), two.lives())


# ---------- Stop ----------

def stop(client, pid, **kw):
    kw.setdefault("json", {})
    return client.post(f"/api/s/{pid}/stop", **kw)


@pytestmark_tmux
def test_stop_sends_escape_alone_when_that_ends_the_command(panes, monkeypatch):
    monkeypatch.setattr(A, "STOP_WAIT", 0.4)
    p = panes.add(RUNNING, PROMPT + BANG_IN, escape_ends=True)
    client = TestClient(create_app(panes.settings))
    r = stop(client, p["pid"])
    assert r.status_code == 200 and r.json() == {"ok": True, "sent": ["Escape"]}, r.text
    assert panes.keys(p) == ["1b"]


@pytestmark_tmux
def test_stop_sends_ctrl_c_too_when_the_command_still_runs(panes, monkeypatch):
    monkeypatch.setattr(A, "STOP_WAIT", 0.4)
    p = panes.add(RUNNING, PROMPT + BANG_IN)  # Escape changes nothing on this screen
    client = TestClient(create_app(panes.settings))
    r = stop(client, p["pid"])
    assert r.status_code == 200 and r.json()["sent"] == ["Escape", "C-c"], r.text
    assert panes.keys(p) == ["1b", "03"]


@pytestmark_tmux
def test_stop_sends_keys_only_to_that_sessions_pane(panes, monkeypatch):
    monkeypatch.setattr(A, "STOP_WAIT", 0.2)
    a = panes.add(RUNNING, PROMPT + BANG_IN)
    b = panes.add(RUNNING, PROMPT + BANG_IN)
    client = TestClient(create_app(panes.settings))
    assert stop(client, a["pid"]).status_code == 200
    assert panes.keys(a) == ["1b", "03"] and panes.keys(b) == []


@pytestmark_tmux
def test_stop_is_refused_with_nothing_sent_when_no_command_runs(panes):
    client = TestClient(create_app(panes.settings))
    # the transcript says the command ended
    done = panes.add(IDLE, PROMPT + BANG_IN + BANG_OUT)
    r = stop(client, done["pid"])
    assert r.status_code == 409 and "no ! command is running" in r.json()["error"], r.text
    # the transcript says it runs but the pane shows its input box (a stale record)
    stale = panes.add(IDLE, PROMPT + BANG_IN)
    assert stop(client, stale["pid"]).status_code == 409
    # an ordinary busy session: a reply being written, no `!` record
    busy = panes.add("thinking…\n", PROMPT + assistant_line("working", "a-1"))
    assert stop(client, busy["pid"]).status_code == 409
    for p in (done, stale, busy):
        assert panes.keys(p) == []


@pytestmark_tmux
def test_stop_works_from_the_pane_alone(panes, monkeypatch):
    monkeypatch.setattr(A, "STOP_WAIT", 0.4)
    p = panes.add(PANE_RUNNING, PROMPT + assistant_line("ok", "a-1"), escape_ends=True)  # no `!` record in the transcript
    client = TestClient(create_app(panes.settings))
    r = stop(client, p["pid"])
    assert r.status_code == 200 and r.json() == {"ok": True, "sent": ["Escape"]}, r.text
    assert panes.keys(p) == ["1b"]
    # Escape changes nothing on this one: Ctrl-C follows
    q = panes.add(PANE_RUNNING, PROMPT)
    r = stop(client, q["pid"])
    assert r.status_code == 200 and r.json()["sent"] == ["Escape", "C-c"], r.text
    assert panes.keys(q) == ["1b", "03"]


@pytestmark_tmux
def test_stop_is_refused_with_nothing_sent_for_a_finished_command_and_for_model_turns(panes):
    client = TestClient(create_app(panes.settings))
    made = [panes.add(PANE_FINISHED, PROMPT + BANG_IN + BANG_OUT),
            panes.add(PANE_TURN, PROMPT + assistant_line("working", "a-1")),
            panes.add(PANE_BASH_TOOL, PROMPT + assistant_line("working", "a-1"))]
    for p in made:
        r = stop(client, p["pid"])
        assert r.status_code == 409 and r.json()["error"] == "no ! command is running in this session; nothing sent", (p["name"], r.text)
    for p in made:
        assert panes.keys(p) == []


@pytestmark_tmux
def test_stop_checks_origin_content_type_and_session(panes):
    p = panes.add(RUNNING, PROMPT + BANG_IN)
    client = TestClient(create_app(panes.settings))
    assert stop(client, p["pid"], headers={"Origin": "https://evil.example"}).status_code == 403
    assert client.post(f"/api/s/{p['pid']}/stop", content=b"{}", headers={"Content-Type": "text/plain"}).status_code == 415
    assert stop(client, 999999).status_code == 404
    assert client.get(f"/api/s/{p['pid']}/stop").status_code == 405
    assert panes.keys(p) == []


# ---------- the page ----------

STATE = """(() => { const b = document.querySelector("#live-bang"); const chat = document.querySelector("#chat");
  return b ? { out: b.querySelector(".live-out").textContent, stop: b.querySelector("button.live-stop")?.textContent,
    last: chat.lastElementChild === b, label: b.querySelector(".live-label").textContent,
    note: b.querySelector(".live-note").hidden ? "" : b.querySelector(".live-note").textContent, n: chat.querySelectorAll("#live-bang").length } : null; })()"""
LIVE_EVENT = """state.es.dispatchEvent(new MessageEvent("live", { data: JSON.stringify(%s) }))"""


def test_a_live_event_renders_the_block_with_stop_and_the_clear_event_removes_it(served, browser):
    browser.open(f"{served['url']}/#s={NAME}")
    assert browser.evaluate(WAIT_READY)
    assert browser.evaluate(STATE) is None
    # a live event, as the stream delivers it (the page's own listener)
    browser.evaluate(LIVE_EVENT % json.dumps({"running": True, "command": "sleep 20", "uuid": "b-1", "text": "code: ABCD-1234"}))
    got = browser.evaluate(STATE)
    assert got == {"out": "code: ABCD-1234", "stop": "Stop", "last": True, "label": "Running in the terminal", "note": "", "n": 1}, got
    # a changed text updates the same block; a message that arrives goes above it
    browser.evaluate(LIVE_EVENT % json.dumps({"running": True, "command": "sleep 20", "uuid": "b-1", "text": "code: ABCD-1234\nwaiting"}))
    browser.evaluate('renderMessage({ role: "assistant", uuid: "a-9", blocks: [{ kind: "text", text: "meanwhile" }] }, { live: true })')
    got = browser.evaluate(STATE)
    assert got["out"] == "code: ABCD-1234\nwaiting" and got["last"] and got["n"] == 1, got
    # the clear event takes it away
    browser.evaluate(LIVE_EVENT % json.dumps({"running": False}))
    assert browser.evaluate(STATE) is None


def test_the_stop_button_posts_to_stop_and_says_what_happened(served, browser):
    browser.open(f"{served['url']}/#s={NAME}")
    assert browser.evaluate(WAIT_READY)
    browser.evaluate("""(() => { window.__stops = []; const real = window.fetch;
      window.fetch = (u, o) => { if (String(u).endsWith("/stop")) { __stops.push({ u: String(u), method: o.method, body: o.body, type: o.headers["Content-Type"] });
        return Promise.resolve(new Response(JSON.stringify(window.__reply), { status: window.__status, headers: { "Content-Type": "application/json" } })); }
        return real(u, o); }; window.__reply = { ok: true, sent: ["Escape", "C-c"] }; window.__status = 200; return true; })()""")
    browser.evaluate(LIVE_EVENT % json.dumps({"running": True, "command": "sleep 20", "text": "x"}))
    pid = os.getpid()
    browser.evaluate("document.querySelector('#live-bang .live-stop').click()")
    browser.evaluate("new Promise((r) => setTimeout(r, 300))")
    stops = browser.evaluate("__stops")
    assert stops == [{"u": f"api/s/{pid}/stop", "method": "POST", "body": "{}", "type": "application/json"}], stops
    assert "Stop sent (Escape, Ctrl-C)" in browser.evaluate(STATE)["note"]
    # a refusal is shown as the server worded it, and the block stays
    browser.evaluate("""new Promise((r) => setTimeout(r, 2200))""")
    browser.evaluate('window.__reply = { ok: false, error: "no ! command is running in this session; nothing sent" }; window.__status = 409')
    browser.evaluate("document.querySelector('#live-bang .live-stop').click()")
    browser.evaluate("new Promise((r) => setTimeout(r, 300))")
    got = browser.evaluate(STATE)
    assert got and "no ! command is running" in got["note"], got
