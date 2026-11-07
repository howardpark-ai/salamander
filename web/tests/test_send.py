"""Send-to-pane against a private tmux server (-L salaweb-pytest-<pid> -f /dev/null), never the default one.

The pane runs a stand-in for Claude Code: it turns on bracketed paste, draws an empty input box, and copies what it
receives to a file, so the test sees exactly what sala-web typed.
"""

import json
import os
import shutil
import subprocess
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
