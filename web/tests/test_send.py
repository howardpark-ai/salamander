"""Send-to-pane against a private tmux server (-L salaweb-pytest-<pid> -f /dev/null), never the default one.

The pane runs a stand-in for Claude Code: it turns on bracketed paste, draws an empty input box, and copies what it
receives to a file, so the test sees exactly what sala-web typed.
"""

import json
import os
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path

import pytest
from starlette.testclient import TestClient

from sala_web import sessions as S
from sala_web.app import create_app
from sala_web.config import Settings

pytestmark = pytest.mark.skipif(shutil.which("tmux") is None, reason="needs tmux")

FAKE = r"""#!/bin/sh
printf '\033[?2004h'
printf 'old output\n'
printf '\342\224\200%.0s' $(seq 40); printf '\n'
printf '\342\235\257 \033[2mTry "something"\033[0m\n'
printf '\342\224\200%.0s' $(seq 40); printf '\n'
stty -echo
exec cat > "$1"
"""


# Two more stand-ins, drawn as Claude Code draws them. NARROW: a 50-column rule carrying a 23-character session name
# (only about half of it is rule characters), above an empty "❯" box. SHELL: after "!" was typed, "!" where "❯" stood.
FAKE_NARROW = r"""#!/bin/sh
printf '\033[?2004h'
printf 'old output\n'
printf '\342\224\200%.0s' $(seq 4); printf ' demo-builder-side-oak02 '; printf '\342\224\200%.0s' $(seq 21); printf '\n'
printf '\342\235\257\302\240\033[2mTry "something"\033[0m\n'
printf '\342\224\200%.0s' $(seq 50); printf '\n'
stty -echo
exec cat > "$1"
"""
FAKE_SHELL = FAKE_NARROW.replace(r"""printf '\342\235\257\302\240\033[2mTry "something"\033[0m\n'""", r"printf '!\302\240\n'")


@pytest.fixture
def tmux_env(tmp_path):
    sock = f"salaweb-pytest-{os.getpid()}"
    script = tmp_path / "fake.sh"
    script.write_text(FAKE)
    script.chmod(0o755)
    out = tmp_path / "received.txt"
    base = ["tmux", "-L", sock, "-f", "/dev/null"]
    subprocess.run(base + ["new-session", "-d", "-s", "fake", "-x", "120", "-y", "20", f"{script} {out}"], check=True)
    try:
        info = subprocess.run(base + ["display-message", "-p", "-t", "fake", "#{pane_id} #{pane_pid}"],
                              check=True, capture_output=True, text=True).stdout.split()
        pane, pid = info[0], int(info[1])
        for _ in range(50):  # wait until the box is drawn
            cap = subprocess.run(base + ["capture-pane", "-p", "-t", pane], capture_output=True, text=True).stdout
            if "Try" in cap:
                break
            time.sleep(0.1)
        claude = tmp_path / "claude"
        (claude / "sessions").mkdir(parents=True)
        (claude / "projects").mkdir()
        state = tmp_path / "state"
        settings = Settings(socket=tmp_path / "s.sock", state_dir=state, claude_dir=claude, tmux_socket_name=sock,
                            roles_cmd=["false"])
        yield {"base": base, "pane": pane, "pid": pid, "out": out, "settings": settings, "claude": claude}
    finally:
        subprocess.run(base + ["kill-server"], capture_output=True)
        # tmux 3.6 keeps the socket file after kill-server: remove it, or /tmp/tmux-<uid> gains one per run
        (Path(os.environ.get("TMUX_TMPDIR") or "/tmp") / f"tmux-{os.getuid()}" / sock).unlink(missing_ok=True)


def register(env, pid, pane):
    rec = {"pid": pid, "sessionId": "aaaaaaaa-0000-0000-0000-000000000000", "cwd": "/tmp", "name": f"s{pid}",
           "status": "idle", "tmux": f"fake:@0.{pane}", "procStart": S.proc_start(pid)}
    (env["claude"] / "sessions" / f"{pid}.json").write_text(json.dumps(rec))


def test_send_pastes_image_path_and_text_then_enter(tmux_env):
    register(tmux_env, tmux_env["pid"], tmux_env["pane"])
    client = TestClient(create_app(tmux_env["settings"]))
    r = client.post("/api/upload", content=b"\x89PNG fake", headers={"Content-Type": "image/png"})
    name = r.json()["name"]
    r = client.post(f"/api/s/{tmux_env['pid']}/send", json={"text": "hello\nworld", "uploads": [name]})
    assert r.status_code == 200, r.text
    assert r.json()["imagesPasted"] == 1
    path = tmux_env["settings"].uploads_dir / name
    want = f"\x1b[200~{path}\x1b[201~\x1b[200~ hello\nworld\x1b[201~\n"
    for _ in range(30):
        if tmux_env["out"].exists() and tmux_env["out"].read_text() == want:
            break
        time.sleep(0.1)
    assert tmux_env["out"].read_text() == want


def test_send_pastes_the_path_of_a_non_image_file(tmux_env):
    """a file that is not an image is pasted as its full path, "<uploads>/<folder>/<safe name>", beside the
    images' paths and the text; it is not counted as an image (the pane draws no chip for it, so nothing is waited for)."""
    register(tmux_env, tmux_env["pid"], tmux_env["pane"])
    client = TestClient(create_app(tmux_env["settings"]))
    up = client.post("/api/upload", params={"name": "my clip (1).mp4"}, content=b"\x00\x00\x00\x18ftypmp42",
                     headers={"Content-Type": "video/mp4"}).json()
    assert up["name"].endswith("/my_clip_1_.mp4")
    start = time.monotonic()
    r = client.post(f"/api/s/{tmux_env['pid']}/send", json={"text": "look at this", "uploads": [up["name"]]})
    assert r.status_code == 200, r.text
    assert r.json()["imagesPasted"] == 0 and r.json()["filesPasted"] == 1
    assert time.monotonic() - start < 2.5  # no wait for a chip that never comes
    path = tmux_env["settings"].uploads_dir / up["name"]
    assert path.is_file() and str(path) == up["path"]
    want = f"\x1b[200~{path}\x1b[201~\x1b[200~ look at this\x1b[201~\n"
    for _ in range(30):
        if tmux_env["out"].exists() and tmux_env["out"].read_text() == want:
            break
        time.sleep(0.1)
    assert tmux_env["out"].read_text() == want


def test_send_refuses_a_bad_or_missing_file_reference(tmux_env):
    register(tmux_env, tmux_env["pid"], tmux_env["pane"])
    client = TestClient(create_app(tmux_env["settings"]))
    url = f"/api/s/{tmux_env['pid']}/send"
    up = client.post("/api/upload", params={"name": "a.pdf"}, content=b"%PDF", headers={"Content-Type": "application/pdf"}).json()
    folder = up["name"].split("/")[0]
    for bad in (f"{folder}/../../../etc/passwd", f"{folder}/..", f"{folder}/sub/a.pdf", f"/{folder}/a.pdf", f"{folder}/.a.pdf",
                f"{folder}/a b.pdf", f"{folder}/a..pdf", "../" + up["name"], f"{folder}\\a.pdf", "etc/passwd", folder, ""):
        r = client.post(url, json={"text": "x", "uploads": [bad]})
        assert r.status_code == 400 and r.json()["error"] == "bad upload names", bad
    r = client.post(url, json={"text": "x", "uploads": [5]})
    assert r.status_code == 400
    # well formed, but no such file: refused, and nothing was pasted
    r = client.post(url, json={"text": "x", "uploads": ["0" * 32 + "/gone.pdf"]})
    assert r.status_code == 400 and "missing" in r.json()["error"]
    # a symlink out of the uploads folder is not a stored file
    outside = tmux_env["settings"].state_dir / "outside.txt"
    outside.write_text("secret")
    link_dir = tmux_env["settings"].uploads_dir / ("1" * 32)
    link_dir.mkdir()
    (link_dir / "evil.txt").symlink_to(outside)
    r = client.post(url, json={"text": "x", "uploads": ["1" * 32 + "/evil.txt"]})
    assert r.status_code == 400
    assert not tmux_env["out"].exists() or tmux_env["out"].read_text() == ""


def test_refuses_pane_of_another_process(tmux_env):
    # a live pid (this test process) whose record points at a pane it does not own
    register(tmux_env, os.getpid(), tmux_env["pane"])
    client = TestClient(create_app(tmux_env["settings"]))
    r = client.post(f"/api/s/{os.getpid()}/send", json={"text": "x"})
    assert r.status_code == 409 and "does not belong" in r.json()["error"]


def test_refuses_missing_pane(tmux_env):
    register(tmux_env, tmux_env["pid"], "%999")
    client = TestClient(create_app(tmux_env["settings"]))
    r = client.post(f"/api/s/{tmux_env['pid']}/send", json={"text": "x"})
    assert r.status_code == 409 and "not found" in r.json()["error"]


def test_refuses_when_box_has_text(tmux_env):
    register(tmux_env, tmux_env["pid"], tmux_env["pane"])
    # draw text into the box line the way Claude Code would (the fake pane ignores input, so print it directly)
    subprocess.run(tmux_env["base"] + ["respawn-pane", "-k", "-t", tmux_env["pane"],
                   "printf '\\342\\224\\200%.0s' $(seq 40); printf '\\n\\342\\235\\257 draft\\n';"
                   " printf '\\342\\224\\200%.0s' $(seq 40); sleep 30"], check=True)
    time.sleep(0.5)
    newpid = int(subprocess.run(tmux_env["base"] + ["display-message", "-p", "-t", tmux_env["pane"], "#{pane_pid}"],
                                capture_output=True, text=True).stdout)
    register(tmux_env, newpid, tmux_env["pane"])
    client = TestClient(create_app(tmux_env["settings"]))
    r = client.post(f"/api/s/{newpid}/send", json={"text": "x"})
    assert r.status_code == 409 and "not empty" in r.json()["error"]


def test_sessions_and_upload_validation(tmux_env):
    register(tmux_env, tmux_env["pid"], tmux_env["pane"])
    client = TestClient(create_app(tmux_env["settings"]))
    groups = client.get("/api/sessions").json()["groups"]
    assert groups[-1]["title"] == "Unregistered" and groups[-1]["sessions"][0]["pid"] == tmux_env["pid"]
    assert client.post("/api/upload", content=b"x", headers={"Content-Type": "text/plain"}).status_code == 415
    r = client.post(f"/api/s/{tmux_env['pid']}/send", json={"text": "x", "uploads": ["../../etc/passwd"]})
    assert r.status_code == 400


def test_cross_origin_and_wrong_content_type_refused(tmux_env):
    register(tmux_env, tmux_env["pid"], tmux_env["pane"])
    client = TestClient(create_app(tmux_env["settings"]))
    url = f"/api/s/{tmux_env['pid']}/send"
    assert client.post(url, json={"text": "x"}, headers={"Origin": "https://evil.example"}).status_code == 403
    assert client.post(url, content=b'{"text":"x"}', headers={"Content-Type": "text/plain"}).status_code == 415
    assert not tmux_env["out"].exists() or tmux_env["out"].read_text() == ""


def test_double_submit_is_refused_within_window():
    from sala_web import app as A
    assert A.DUP_WINDOW >= 5


def _respawn(env, script_text, name):
    """Replace the pane's process with a stand-in drawing another screen, register it and return its pid."""
    script = env["out"].parent / name
    script.write_text(script_text)
    script.chmod(0o755)
    subprocess.run(env["base"] + ["respawn-pane", "-k", "-t", env["pane"], f"{script} {env['out']}"], check=True)
    for _ in range(50):
        cap = subprocess.run(env["base"] + ["capture-pane", "-p", "-t", env["pane"]], capture_output=True,
                             text=True).stdout
        if "demo-builder-side-oak02" in cap and cap.rstrip().endswith("─" * 50):
            break
        time.sleep(0.1)
    pid = int(subprocess.run(env["base"] + ["display-message", "-p", "-t", env["pane"], "#{pane_pid}"],
                             capture_output=True, text=True, check=True).stdout)
    register(env, pid, env["pane"])
    return pid


def _received(env, want):
    for _ in range(30):
        if env["out"].exists() and env["out"].read_text() == want:
            break
        time.sleep(0.1)
    return env["out"].read_text()


def test_narrow_pane_with_the_name_in_its_rule_accepts_a_send(tmux_env):
    # before: "no input box in the pane" (the rule is under 60% rule characters)
    pid = _respawn(tmux_env, FAKE_NARROW, "fake-narrow.sh")
    client = TestClient(create_app(tmux_env["settings"]))
    r = client.post(f"/api/s/{pid}/send", json={"text": "hi"})
    assert r.status_code == 200, r.text
    want = "\x1b[200~hi\x1b[201~\n"
    assert _received(tmux_env, want) == want


def test_command_sent_to_a_pane_in_shell_mode_gets_no_second_bang(tmux_env):
    pid = _respawn(tmux_env, FAKE_SHELL, "fake-shell.sh")
    client = TestClient(create_app(tmux_env["settings"]))
    r = client.post(f"/api/s/{pid}/send", json={"text": "!ls -la"})
    assert r.status_code == 200, r.text
    want = "\x1b[200~ls -la\x1b[201~\n"
    assert _received(tmux_env, want) == want


def test_text_without_a_bang_goes_into_a_shell_mode_box_as_it_is(tmux_env):
    pid = _respawn(tmux_env, FAKE_SHELL, "fake-shell.sh")
    client = TestClient(create_app(tmux_env["settings"]))
    r = client.post(f"/api/s/{pid}/send", json={"text": "ls -la"})
    assert r.status_code == 200, r.text
    want = "\x1b[200~ls -la\x1b[201~\n"
    assert _received(tmux_env, want) == want


def test_a_lone_bang_in_shell_mode_sends_nothing(tmux_env):
    pid = _respawn(tmux_env, FAKE_SHELL, "fake-shell.sh")
    client = TestClient(create_app(tmux_env["settings"]))
    r = client.post(f"/api/s/{pid}/send", json={"text": " ! "})
    assert r.status_code == 400
    time.sleep(0.3)
    assert tmux_env["out"].read_text() == ""  # the stand-in's file exists, and nothing reached it


def test_bang_text_in_a_prompt_box_is_left_alone(tmux_env):
    register(tmux_env, tmux_env["pid"], tmux_env["pane"])
    client = TestClient(create_app(tmux_env["settings"]))
    r = client.post(f"/api/s/{tmux_env['pid']}/send", json={"text": "!ls"})
    assert r.status_code == 200, r.text
    want = "\x1b[200~!ls\x1b[201~\n"
    assert _received(tmux_env, want) == want


# --- Replace, against a real tmux and a stand-in whose input box edits like Claude Code's (measured on 2.1.330) -------------------
# The stand-in holds a draft (DRAFT, the cursor at CURSOR or the end), turns on bracketed paste, redraws its box after every key
# and records what Enter submits. Ctrl+U deletes to the start of the cursor's line (at a line's start, the newline before it),
# End goes to the end of the line, Delete removes the character after the cursor.
FAKE_EDIT = r"""
import json, os, sys, tty
out, text = sys.argv[1], os.environ.get("DRAFT", "")
cur = int(os.environ["CURSOR"]) if os.environ.get("CURSOR") else len(text)
fd = sys.stdin.fileno()
tty.setraw(fd)
def draw():
    rule = "─" * 40
    body = ("❯ " + text.replace("\n", "\r\n  ")) if text else '❯ \x1b[2mTry "something"\x1b[0m'
    sys.stdout.write("\x1b[H\x1b[2J" + "old output\r\n" + rule + "\r\n" + body + "\r\n" + rule + "\r\n")
    sys.stdout.flush()
sys.stdout.write("\x1b[?2004h")
draw()
buf = b""
paste = None
while True:
    chunk = os.read(fd, 4096)
    if not chunk:
        break
    buf += chunk
    while buf:
        if paste is not None:
            end = buf.find(b"\x1b[201~")
            if end < 0:
                paste += buf; buf = b""; break
            paste += buf[:end]; buf = buf[end + 6:]
            ins = paste.decode().replace("\r", "\n")
            text, cur, paste = text[:cur] + ins + text[cur:], cur + len(ins), None
            continue
        if buf.startswith(b"\x1b[200~"):
            paste, buf = b"", buf[6:]
        elif buf[:1] == b"\x1b":
            m = next((s for s in (b"\x1b[F", b"\x1bOF", b"\x1b[4~", b"\x1b[8~") if buf.startswith(s)), None)
            if m:
                e = text.find("\n", cur); cur = len(text) if e < 0 else e
                buf = buf[len(m):]
            elif buf.startswith(b"\x1b[3~"):
                text = text[:cur] + text[cur + 1:]; buf = buf[4:]
            elif len(buf) < 4:
                break
            else:
                buf = buf[1:]
        elif buf[:1] == b"\x15":
            start = text.rfind("\n", 0, cur) + 1
            if cur > start:
                text, cur = text[:start] + text[cur:], start
            elif cur > 0:
                text, cur = text[:cur - 1] + text[cur:], cur - 1
            buf = buf[1:]
        elif buf[:1] == b"\r":
            with open(out, "a") as f:
                f.write(json.dumps(text) + "\n")
            text, cur, buf = "", 0, buf[1:]
        else:
            buf = buf[1:]
    draw()
"""


@pytest.fixture
def edit_env(tmp_path):
    sock = f"salaweb-pytest-edit-{os.getpid()}"
    script = tmp_path / "fake_edit.py"
    script.write_text(FAKE_EDIT)
    out = tmp_path / "submitted.txt"
    base = ["tmux", "-L", sock, "-f", "/dev/null"]

    def start(draft, cursor=None):
        env = f"DRAFT={shlex.quote(draft)}" + (f" CURSOR={cursor}" if cursor is not None else "")
        cmd = f"env {env} {shlex.quote(sys.executable)} {shlex.quote(str(script))} {shlex.quote(str(out))}"
        subprocess.run(base + ["new-session", "-d", "-s", "fake", "-x", "120", "-y", "20", cmd], check=True)
        info = subprocess.run(base + ["display-message", "-p", "-t", "fake", "#{pane_id} #{pane_pid}"],
                              check=True, capture_output=True, text=True).stdout.split()
        pane, pid = info[0], int(info[1])
        for _ in range(50):
            cap = subprocess.run(base + ["capture-pane", "-p", "-t", pane], capture_output=True, text=True).stdout
            if "❯" in cap:
                break
            time.sleep(0.1)
        claude = tmp_path / "claude"
        (claude / "sessions").mkdir(parents=True)
        (claude / "projects").mkdir()
        settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                            tmux_socket_name=sock, roles_cmd=["false"])
        made = {"base": base, "pane": pane, "pid": pid, "out": out, "settings": settings, "claude": claude}
        register(made, pid, pane)
        return TestClient(create_app(settings)), made

    try:
        yield start
    finally:
        subprocess.run(base + ["kill-server"], capture_output=True)
        (Path(os.environ.get("TMUX_TMPDIR") or "/tmp") / f"tmux-{os.getuid()}" / sock).unlink(missing_ok=True)


def _submitted(env):
    for _ in range(30):
        if env["out"].exists() and env["out"].read_text():
            break
        time.sleep(0.1)
    return [json.loads(ln) for ln in env["out"].read_text().splitlines()] if env["out"].exists() else []


@pytest.mark.parametrize("draft,cursor", [("left over", None), ("one\ntwo\nthree", None), ("alpha beta\ngamma", 3), ("alpha\nbeta", 0)],
                         ids=["one-line", "three-lines", "cursor-inside", "cursor-at-start"])
def test_replace_clears_what_the_owner_left_and_sends_only_the_message(edit_env, draft, cursor):
    client, env = edit_env(draft, cursor)
    url = f"/api/s/{env['pid']}/send"
    r = client.post(url, json={"text": "new message"})
    assert r.status_code == 409 and r.json()["boxText"] == draft, r.text
    r = client.post(url, json={"text": "new message", "replace": r.json()["boxText"]})
    assert r.status_code == 200, r.text
    assert _submitted(env) == ["new message"]  # nothing of the draft went with it


def test_replace_refuses_a_box_that_changed_since_the_page_saw_it(edit_env):
    client, env = edit_env("what is there now")
    r = client.post(f"/api/s/{env['pid']}/send", json={"text": "new message", "replace": "what the page saw"})
    assert r.status_code == 409 and r.json()["boxText"] == "what is there now" and r.json()["boxChanged"] is True
    time.sleep(0.3)
    assert not env["out"].exists()
    cap = subprocess.run(env["base"] + ["capture-pane", "-p", "-t", env["pane"]], capture_output=True, text=True).stdout
    assert "what is there now" in cap  # the box was left as it was


# ---- every refused send is logged with its path, status and reason, never the typed text ------------------------------------

def _refusals(caplog):
    return [r.getMessage() for r in caplog.records if r.name == "sala_web"]


def test_a_refused_send_is_logged_with_its_path_status_and_reason(tmux_env, caplog):
    import logging
    caplog.set_level(logging.INFO, logger="sala_web")
    register(tmux_env, tmux_env["pid"], tmux_env["pane"])
    client = TestClient(create_app(tmux_env["settings"]))
    url = f"/api/s/{tmux_env['pid']}/send"
    typed = "TYPED-TEXT-9137"
    assert client.post(url, json={"text": typed, "uploads": ["../x"]}).status_code == 400
    assert client.post(url, json={"text": typed}, headers={"Origin": "https://evil.example"}).status_code == 403
    assert client.post(url, content=b"{}", headers={"Content-Type": "text/plain"}).status_code == 415
    assert client.post("/api/s/1/send", json={"text": typed}).status_code == 404
    assert client.post(url, json={"text": "  ", "uploads": []}).status_code == 400
    assert _refusals(caplog) == [
        f"send refused: {url} 400 bad upload names",
        f"send refused: {url} 403 cross-origin request refused",
        f"send refused: {url} 415 send takes application/json",
        "send refused: /api/s/1/send 404 no live session with that pid",
        f"send refused: {url} 400 nothing to send",
    ]
    assert typed not in caplog.text
    # an accepted send says nothing
    caplog.clear()
    assert client.post(url, json={"text": typed}).status_code == 200
    assert _refusals(caplog) == []


def test_a_refused_send_logs_its_reason_but_not_the_text_in_the_pane_box(tmux_env, caplog):
    import logging
    caplog.set_level(logging.INFO, logger="sala_web")
    subprocess.run(tmux_env["base"] + ["respawn-pane", "-k", "-t", tmux_env["pane"],
                   "printf '\\342\\224\\200%.0s' $(seq 40); printf '\\n\\342\\235\\257 BOX-TEXT-5521\\n';"
                   " printf '\\342\\224\\200%.0s' $(seq 40); sleep 30"], check=True)
    time.sleep(0.5)
    pid = int(subprocess.run(tmux_env["base"] + ["display-message", "-p", "-t", tmux_env["pane"], "#{pane_pid}"],
                             capture_output=True, text=True).stdout)
    register(tmux_env, pid, tmux_env["pane"])
    client = TestClient(create_app(tmux_env["settings"]))
    r = client.post(f"/api/s/{pid}/send", json={"text": "TYPED-TEXT-9137"})
    assert r.status_code == 409 and r.json()["boxText"] == "BOX-TEXT-5521"  # the page is told what the box holds
    assert _refusals(caplog) == [f"send refused: /api/s/{pid}/send 409 pane input box is not empty; nothing sent"]
    assert "BOX-TEXT-5521" not in caplog.text and "TYPED-TEXT-9137" not in caplog.text


def test_a_send_that_fails_inside_is_logged_as_a_500_with_its_exception(tmux_env, caplog, monkeypatch):
    import logging
    from sala_web import tmuxio as T
    caplog.set_level(logging.INFO, logger="sala_web")
    register(tmux_env, tmux_env["pid"], tmux_env["pane"])

    async def boom(*a, **k):
        raise RuntimeError("it broke\nover two lines")
    monkeypatch.setattr(T, "pane_pid", boom)
    client = TestClient(create_app(tmux_env["settings"]), raise_server_exceptions=False)
    url = f"/api/s/{tmux_env['pid']}/send"
    assert client.post(url, json={"text": "TYPED-TEXT-9137"}).status_code == 500
    assert _refusals(caplog) == [f"send refused: {url} 500 RuntimeError: it broke over two lines"]
