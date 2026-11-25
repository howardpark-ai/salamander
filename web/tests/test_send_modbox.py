"""A send whose input box the screen cannot read: Enter is pressed only when the pane's mod says the box holds the message.

The pane runs a stand-in for Claude Code on a private tmux server (-L salaweb-modbox-<pid> -f /dev/null): it draws a screen, records
what it receives, and after a paste redraws another screen (one with no input box the reader can find, one with a numbered dialog, or
an intact box), so the send finds its box "missing" exactly where a scrolled box was once not found. The mod is modsock.FakeMod.
Without a mod stamp, or with a mod that is silent or says something else, the send is refused as it always was.
"""

import json
import logging
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

import pytest
from starlette.testclient import TestClient

from modsock import FakeMod
from sala_web import sessions as S
from sala_web.app import create_app
from sala_web.config import Settings

pytestmark = pytest.mark.skipif(shutil.which("tmux") is None, reason="needs tmux")

PASTE_END = b"\x1b[201~"
SCRIPT = r'''
import os, sys, tty
out, initial, after = sys.argv[1], sys.argv[2], sys.argv[3]
RULE = "─" * 40


def draw(kind):
    sys.stdout.write("\x1b[2J\x1b[H")
    if kind == "box":
        sys.stdout.write("old output\n" + RULE + "\n❯ \x1b[2mTry \"something\"\x1b[0m\n" + RULE + "\n")
    elif kind == "text":
        sys.stdout.write("old output\n" + RULE + "\n❯ OWNER-WORDS-3321\n" + RULE + "\n")
    elif kind == "full":
        sys.stdout.write("old output\n" + RULE + "\n❯ the pasted words are in the box\n" + RULE + "\n")
    elif kind == "dialog":
        sys.stdout.write("old output\n" + RULE + "\nDo you want to proceed?\n❯ 1. Yes\n  2. No\n")
    else:
        sys.stdout.write("working on something, no box on this screen\n")
    sys.stdout.flush()


sys.stdout.write("\x1b[?2004h")
draw(initial)
tty.setcbreak(0)
done = False
while True:
    data = os.read(0, 65536)
    if not data:
        break
    with open(out, "ab") as f:
        f.write(data)
    if not done and b"\x1b[201~" in data:
        done = True
        draw(after)
'''


@pytest.fixture
def rig(tmp_path, monkeypatch):
    sock = f"salaweb-modbox-{os.getpid()}"
    base = ["tmux", "-L", sock, "-f", "/dev/null"]
    script = tmp_path / "fakepane.py"
    script.write_text(SCRIPT)
    mods: list[FakeMod] = []
    started = []

    def start(initial: str, after: str, **mod_kw):
        out = tmp_path / "received.bin"
        subprocess.run(base + ["new-session", "-d", "-s", "fake", "-x", "120", "-y", "20",
                               f"{sys.executable} {script} {out} {initial} {after}"], check=True)
        started.append(True)
        info = subprocess.run(base + ["display-message", "-p", "-t", "fake", "#{pane_id} #{pane_pid}"],
                              check=True, capture_output=True, text=True).stdout.split()
        pane, pid = info[0], int(info[1])
        for _ in range(50):   # until the first screen is drawn
            cap = subprocess.run(base + ["capture-pane", "-p", "-t", pane], capture_output=True, text=True).stdout
            if cap.strip():
                break
            time.sleep(0.1)
        claude = tmp_path / "claude"
        (claude / "sessions").mkdir(parents=True, exist_ok=True)
        (claude / "projects").mkdir(exist_ok=True)
        settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude, tmux_socket_name=sock,
                            roles_cmd=["false"], sala_state_dir=tmp_path / "salastate")
        extra = {"tmux": f"fake:@0.{pane}", "procStart": S.proc_start(pid)}
        if mod_kw.pop("no_mod", False):
            (claude / "sessions" / f"{pid}.json").write_text(json.dumps(
                {"pid": pid, "sessionId": "aaaaaaaa-0000-0000-0000-000000000000", "cwd": "/tmp", "name": f"s{pid}",
                 "status": "idle", **extra}))
            mod = None
        else:
            mod = FakeMod(pid, claude, row_extra=extra, **mod_kw)
            mods.append(mod)
            monkeypatch.setenv("XDG_RUNTIME_DIR", str(mod.root / "run"))
        client = TestClient(create_app(settings))
        return {"client": client, "url": f"/api/s/{pid}/send", "out": out, "mod": mod, "pane": pane, "settings": settings}

    try:
        yield start
    finally:
        for m in mods:
            m.close()
        subprocess.run(base + ["kill-server"], capture_output=True)
        # tmux keeps the socket file after kill-server: remove it, or /tmp/tmux-<uid> gains one per run
        (Path(os.environ.get("TMUX_TMPDIR") or "/tmp") / f"tmux-{os.getuid()}" / sock).unlink(missing_ok=True)


def received(r) -> bytes:
    return r["out"].read_bytes() if r["out"].exists() else b""


def wait_for(r, ends: bytes) -> bytes:
    for _ in range(40):
        if received(r).endswith(ends):
            break
        time.sleep(0.1)
    return received(r)


def settle(r) -> bytes:
    """What the pane received once nothing more comes: a refused send is checked after the keys it might have sent would have landed."""
    time.sleep(0.6)
    return received(r)


def msgs(caplog) -> list[str]:
    return [x.getMessage() for x in caplog.records if x.name == "sala_web"]


def test_missing_and_the_mods_text_is_the_message_presses_enter(rig, caplog):
    caplog.set_level(logging.INFO, logger="sala_web")
    r = rig("box", "nobox", text="hello there")
    resp = r["client"].post(r["url"], json={"text": "hello there"})
    assert resp.status_code == 200, resp.text
    assert resp.json()["confirmedByMod"] is True
    assert wait_for(r, PASTE_END + b"\n") == b"\x1b[200~hello there" + PASTE_END + b"\n"
    assert r["mod"].requests == 1
    # visible in the log, and the text is not
    assert any("mod's prompt text is the message, Enter pressed" in m for m in msgs(caplog))
    assert "hello there" not in caplog.text


def test_whitespace_is_not_a_difference_the_screen_wraps_and_the_box_does_not_indent(rig):
    sent = "line one\nline two  \n\nline four"
    r = rig("box", "nobox", text="line one\n  line two\nline four  ")   # indented and trimmed, blank line gone: the same words
    resp = r["client"].post(r["url"], json={"text": sent})
    assert resp.status_code == 200, resp.text
    assert wait_for(r, PASTE_END + b"\n").endswith(PASTE_END + b"\n")


@pytest.mark.parametrize("box", ["[Pasted text #1 +5 lines]", "[Image #1] hello there", "hello", "hello there and more",
                                 "OWNER words hello there", ""])
def test_missing_and_the_mods_text_is_something_else_is_refused_as_before(rig, caplog, box):
    caplog.set_level(logging.INFO, logger="sala_web")
    r = rig("box", "nobox", text=box)
    resp = r["client"].post(r["url"], json={"text": "hello there"})
    assert resp.status_code == 409 and "disappeared while pasting; pasted but not submitted" in resp.json()["error"]
    assert "confirmedByMod" not in resp.json()
    assert settle(r) == b"\x1b[200~hello there" + PASTE_END   # pasted, no Enter
    assert r["mod"].requests == 1
    assert not any("Enter pressed" in m for m in msgs(caplog))
    assert "hello there" not in caplog.text and (not box or box not in caplog.text)


def test_missing_and_no_stamp_is_refused_as_before_and_nobody_is_asked(rig):
    r = rig("box", "nobox", text="hello there", stamp=False)
    resp = r["client"].post(r["url"], json={"text": "hello there"})
    assert resp.status_code == 409 and "disappeared while pasting" in resp.json()["error"]
    assert settle(r) == b"\x1b[200~hello there" + PASTE_END
    assert r["mod"].requests == 0


@pytest.mark.parametrize("kw", [{"version": 0}, {"stamp_at_ms": 1_000_000}], ids=["old-mod", "stale-stamp"])
def test_missing_and_an_old_mod_or_a_stale_stamp_is_refused_as_before(rig, kw):
    r = rig("box", "nobox", text="hello there", **kw)
    resp = r["client"].post(r["url"], json={"text": "hello there"})
    assert resp.status_code == 409 and "disappeared while pasting" in resp.json()["error"]
    assert settle(r) == b"\x1b[200~hello there" + PASTE_END
    assert r["mod"].requests == 0


def test_a_pane_with_no_mod_at_all_keeps_the_screen_reading_alone(rig):
    r = rig("box", "nobox", no_mod=True)
    resp = r["client"].post(r["url"], json={"text": "hello there"})
    assert resp.status_code == 409 and "disappeared while pasting" in resp.json()["error"]
    assert settle(r) == b"\x1b[200~hello there" + PASTE_END


def test_missing_and_the_mod_is_silent_is_refused_after_a_bounded_wait(rig):
    r = rig("box", "nobox", text="hello there", mode="silent")
    start = time.monotonic()
    resp = r["client"].post(r["url"], json={"text": "hello there"})
    took = time.monotonic() - start
    assert resp.status_code == 409 and "disappeared while pasting" in resp.json()["error"]
    assert took < 6, took   # the 0.3 s settle, the 2 s wait, and tmux
    assert settle(r) == b"\x1b[200~hello there" + PASTE_END
    assert r["mod"].replies_left() == []


@pytest.mark.parametrize("mode", ["refused", "badjson"])
def test_missing_and_the_mod_answers_badly_is_refused_as_before(rig, mode):
    r = rig("box", "nobox", text="hello there", mode=mode)
    resp = r["client"].post(r["url"], json={"text": "hello there"})
    assert resp.status_code == 409 and "disappeared while pasting" in resp.json()["error"]
    assert settle(r) == b"\x1b[200~hello there" + PASTE_END


def test_missing_with_a_dialog_on_the_screen_is_refused_and_the_mod_is_not_even_asked(rig):
    r = rig("box", "dialog", text="hello there")   # an Enter would answer the dialog
    resp = r["client"].post(r["url"], json={"text": "hello there"})
    assert resp.status_code == 409 and "disappeared while pasting" in resp.json()["error"]
    assert settle(r) == b"\x1b[200~hello there" + PASTE_END
    assert r["mod"].requests == 0


def test_a_box_the_screen_reads_is_unchanged_and_the_mod_is_never_asked(rig):
    r = rig("box", "full", text="hello there")
    resp = r["client"].post(r["url"], json={"text": "hello there"})
    assert resp.status_code == 200 and "confirmedByMod" not in resp.json()
    assert wait_for(r, PASTE_END + b"\n").endswith(PASTE_END + b"\n")
    assert r["mod"].requests == 0


def test_a_box_that_holds_text_before_the_paste_is_refused_as_before_and_the_mod_is_never_asked(rig):
    r = rig("text", "full", text="OWNER-WORDS-3321")
    resp = r["client"].post(r["url"], json={"text": "hello there"})
    assert resp.status_code == 409 and resp.json()["error"] == "pane input box is not empty; nothing sent"
    assert resp.json()["boxText"] == "OWNER-WORDS-3321"
    assert settle(r) == b""
    assert r["mod"].requests == 0


def test_a_file_path_and_text_are_compared_as_pasted(rig, tmp_path):
    r = rig("box", "nobox", text="")
    up = r["client"].post("/api/upload", params={"name": "notes.txt"}, content=b"abc", headers={"Content-Type": "text/plain"}).json()
    path = up["path"]
    r["mod"].text = f"{path} look at this"
    resp = r["client"].post(r["url"], json={"text": "look at this", "uploads": [up["name"]]})
    assert resp.status_code == 200 and resp.json()["confirmedByMod"] is True and resp.json()["filesPasted"] == 1
    assert wait_for(r, PASTE_END + b"\n").endswith(PASTE_END + b"\n")


def test_an_image_chip_is_not_the_message(rig):
    """What the mod says for an attached image is "[Image #1] text", never the path: the compare refuses it."""
    r = rig("box", "nobox", text="")
    up = r["client"].post("/api/upload", content=b"\x89PNG fake", headers={"Content-Type": "image/png"}).json()
    r["mod"].text = "[Image #1] look at this"
    resp = r["client"].post(r["url"], json={"text": "look at this", "uploads": [up["name"]]})
    assert resp.status_code == 409 and "disappeared while pasting" in resp.json()["error"]
    assert not settle(r).endswith(PASTE_END + b"\n")


# ---- Retry of a message that was pasted while the box could not be read ------------------------------------------------------

def test_a_retry_with_no_box_on_the_screen_and_the_message_in_the_mods_box_presses_enter(rig, caplog):
    caplog.set_level(logging.INFO, logger="sala_web")
    r = rig("nobox", "nobox", text="hello there")
    resp = r["client"].post(r["url"], json={"text": "hello there", "retry": True})
    assert resp.status_code == 200, resp.text
    assert resp.json()["resubmitted"] is True and resp.json()["confirmedByMod"] is True
    assert wait_for(r, b"\n") == b"\n"   # only Enter: nothing is pasted a second time
    assert any("(retry)" in m and "Enter pressed" in m for m in msgs(caplog))
    assert "hello there" not in caplog.text


def test_a_retry_whose_message_is_not_in_the_mods_box_is_refused_as_before(rig):
    r = rig("nobox", "nobox", text="something the owner typed")
    resp = r["client"].post(r["url"], json={"text": "hello there", "retry": True})
    assert resp.status_code == 409 and resp.json()["noInputBox"] is True
    assert settle(r) == b""


def test_a_plain_send_with_no_box_on_the_screen_never_asks_the_mod(rig):
    r = rig("nobox", "nobox", text="hello there")
    resp = r["client"].post(r["url"], json={"text": "hello there"})
    assert resp.status_code == 409 and resp.json()["noInputBox"] is True
    assert settle(r) == b"" and r["mod"].requests == 0


def test_a_retry_with_a_dialog_on_the_screen_answers_no_dialog_and_never_asks_the_mod(rig):
    r = rig("dialog", "dialog", text="hello there")
    resp = r["client"].post(r["url"], json={"text": "hello there", "retry": True})
    assert resp.status_code == 409 and "a dialog is open in the pane" in resp.json()["error"]
    assert settle(r) == b"" and r["mod"].requests == 0


def test_a_retry_that_also_replaces_the_boxs_text_never_asks_the_mod(rig):
    r = rig("nobox", "nobox", text="hello there")
    resp = r["client"].post(r["url"], json={"text": "hello there", "retry": True, "replace": "x"})
    assert resp.status_code == 409 and settle(r) == b"" and r["mod"].requests == 0


def test_a_retry_with_no_stamp_is_refused_as_before(rig):
    r = rig("nobox", "nobox", text="hello there", stamp=False)
    resp = r["client"].post(r["url"], json={"text": "hello there", "retry": True})
    assert resp.status_code == 409 and resp.json()["noInputBox"] is True
    assert settle(r) == b"" and r["mod"].requests == 0
