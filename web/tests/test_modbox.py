"""modbox.py: asking a pane's claude, through sala's in-session mod, what its prompt box holds.

Against a stand-in mod (modsock.FakeMod): a real unix socket that takes the request line and writes the reply file, a registry row
and the presence stamp, all in temp folders that are removed when each test ends. The helper must answer the text, or None for every
way it can fail (the caller then does what it did before the mod was asked), and must never hold the event loop.
"""

import asyncio
import json
import os
import time

import pytest

from modsock import FakeMod
from sala_web import modbox as MB
from sala_web.config import Settings

PID = os.getpid()   # a live process: its start time is read from /proc


@pytest.fixture
def env(tmp_path, monkeypatch):
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    state = tmp_path / "salastate"
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude, sala_state_dir=state)
    mods: list[FakeMod] = []

    def make(**kw) -> FakeMod:
        m = FakeMod(PID, claude, **kw)
        mods.append(m)
        monkeypatch.setenv("XDG_RUNTIME_DIR", str(m.root / "run"))
        return m

    try:
        yield {"settings": settings, "claude": claude, "make": make, "state": state, "monkeypatch": monkeypatch}
    finally:
        for m in mods:
            m.close()


def ask(env, wait=1.0):
    return asyncio.run(MB.draft(env["settings"], PID, wait=wait))


def test_the_boxs_own_text_comes_back_exactly(env):
    text = "first line\n  indented second  \nthird with two  spaces  "
    m = env["make"](text=text)
    assert ask(env) == text
    # the request is the marked line plus the note for the model, on the socket, as the shell side sends it
    assert m.requests == 1
    first, note = m.lines[0].split("\n", 1)
    assert first.startswith("[sala-mod] draft ") and MB.REQID_RE.fullmatch(first.split(" ")[2])
    assert note.startswith("(An automatic control line from salamander")
    assert m.replies_left() == []   # the reply file was read and removed


def test_an_empty_box_is_an_empty_string_not_none(env):
    env["make"](text="")
    assert ask(env) == ""


@pytest.mark.parametrize("kw", [
    {"stamp": False},                                          # no stamp: no mod
    {"version": 0},                                            # a mod older than this side speaks
    {"stamp_at_ms": 1_000_000},                                # written long before the process started: a pane resumed without the mod
    {"mode": "silent"},                                        # a mod that says nothing
    {"mode": "refused"},                                       # a reply that is not ok
    {"mode": "badjson"},                                       # a reply that is not JSON
    {"row": False},                                            # no registry row for the pid
], ids=["no-stamp", "old-version", "old-stamp", "silent", "refused", "bad-json", "no-row"])
def test_every_failure_is_none(env, kw):
    m = env["make"](text="MESSAGE", **kw)
    assert ask(env, wait=0.4) is None
    if kw.get("stamp") is False or "version" in kw or "stamp_at_ms" in kw or kw.get("row") is False:
        assert m.requests == 0   # nobody was asked: the push is not made without a mod to answer
    assert m.replies_left() == []


def test_a_stamp_for_another_session_or_not_present_is_none(env):
    m = env["make"](text="MESSAGE", stamp=False)
    stamp = m.run_dir / f"{m.session_id}.json"
    now = int(time.time() * 1000)
    stamp.write_text(json.dumps({"present": True, "version": 1, "sessionId": "cccccccc-0000-0000-0000-000000000000", "at": now}))
    assert ask(env, wait=0.3) is None
    stamp.write_text(json.dumps({"present": False, "version": 1, "sessionId": m.session_id, "at": now}))
    assert ask(env, wait=0.3) is None
    stamp.write_text("not json")
    assert ask(env, wait=0.3) is None
    stamp.write_text(json.dumps({"present": True, "version": 1, "sessionId": m.session_id, "at": now}))
    assert ask(env) == "MESSAGE"   # and the right stamp is read again, nothing was remembered
    assert m.requests == 1


def test_a_socket_that_is_gone_is_none(env):
    m = env["make"](text="MESSAGE")
    m._srv.close()
    os.unlink(m.sock_path)
    assert ask(env, wait=0.3) is None


def test_a_socket_that_is_a_plain_file_is_none(env):
    m = env["make"](text="MESSAGE")
    m._srv.close()
    os.unlink(m.sock_path)
    open(m.sock_path, "w").close()
    assert ask(env, wait=0.3) is None


def test_the_stamp_in_the_state_folder_counts_when_there_is_no_runtime_dir(env):
    m = env["make"](text="MESSAGE", run_dir=env["state"] / "mod")
    env["monkeypatch"].delenv("XDG_RUNTIME_DIR")
    assert ask(env) == "MESSAGE"
    assert m.requests == 1


def test_a_reply_that_comes_within_the_wait_is_taken_and_one_after_it_is_not(env):
    env["make"](text="MESSAGE", mode="late", delay=0.4)
    assert ask(env, wait=2.0) == "MESSAGE"


def test_a_reply_after_the_wait_is_none_and_the_wait_is_bounded(env):
    env["make"](text="MESSAGE", mode="late", delay=1.5)
    start = time.monotonic()
    assert ask(env, wait=0.3) is None
    assert time.monotonic() - start < 1.2


def test_a_reply_for_another_request_is_not_taken(env):
    m = env["make"](text="MESSAGE", mode="silent")

    async def go():
        task = asyncio.create_task(MB.draft(env["settings"], PID, wait=0.5))
        await asyncio.sleep(0.1)
        # a reply file for some other request id: not this one's
        (m.run_dir / f"{m.session_id}.other-1.reply.json").write_text(json.dumps({"reqid": "other-1", "ok": True, "text": "NOT MINE"}))
        return await task

    assert asyncio.run(go()) is None


def test_the_event_loop_keeps_running_while_the_mod_is_silent(env):
    env["make"](text="MESSAGE", mode="silent")

    async def go():
        ticks = 0
        stop = False

        async def ticker():
            nonlocal ticks
            while not stop:
                ticks += 1
                await asyncio.sleep(0.01)

        t = asyncio.create_task(ticker())
        got = await MB.draft(env["settings"], PID, wait=0.5)
        stop = True
        await t
        return got, ticks

    got, ticks = asyncio.run(go())
    assert got is None
    assert ticks > 20   # about 50 ticks fit in half a second; a blocked loop would have one or two


def test_a_stamp_written_just_before_the_process_started_still_counts(env):
    """2 s of slack, as the shell side has: the clock the stamp's `at` comes from and the process's start tick are not one clock."""
    start = MB.process_start(PID)
    assert start is not None
    env["make"](text="MESSAGE", stamp_at_ms=int((start - 1) * 1000))
    assert ask(env) == "MESSAGE"


def test_the_process_start_of_a_dead_pid_is_none():
    assert MB.process_start(2 ** 22 + 12345) is None


# ---- fill: put a text in the box through the mod -------------------------------------------------------------------------------

def test_fill_puts_the_text_in_and_says_what_the_box_holds(env):
    m = env["make"](fill_mode="ok")
    text = "one\ntwo \"q\" \\ é\n\n  three"
    got = asyncio.run(MB.fill(env["settings"], PID, text, "replace"))
    assert got == MB.Filled(True, None, text, len(text))
    assert m.fills == [(text, "replace")]
    assert m.replies_left() == []        # the reply is gone
    assert not list(m.run_dir.glob("*.fill.json*"))   # and so is the payload


def test_fill_of_nothing_by_insert_is_the_probe_and_changes_nothing(env):
    m = env["make"](fill_mode="ok", text="owner words")
    got = asyncio.run(MB.fill(env["settings"], PID, "", "insert"))
    assert got == MB.Filled(True, None, "owner words", 11) and m.text == "owner words"


def test_fill_under_a_dialog_says_so_and_leaves_the_draft(env):
    m = env["make"](fill_mode="ok", dialog=True, text="draft")
    got = asyncio.run(MB.fill(env["settings"], PID, "new", "replace"))
    assert got is not None and got.refusal == "dialog" and got.is_filled is False and got.text == "draft"
    assert m.text == "draft"


def test_the_payload_never_rides_on_the_socket_line(env):
    m = env["make"](fill_mode="ok")
    asyncio.run(MB.fill(env["settings"], PID, "SECRET-WORDS", "replace"))
    assert m.lines and all("SECRET-WORDS" not in ln for ln in m.lines)


@pytest.mark.parametrize("fill_mode", ["unknown", "silent", "badjson"])
def test_fill_of_a_mod_that_has_no_such_verb_or_says_nothing_useful_is_none(env, fill_mode):
    env["make"](fill_mode=fill_mode)
    start = time.monotonic()
    assert asyncio.run(MB.fill(env["settings"], PID, "x", "replace", wait=0.4)) is None
    assert time.monotonic() - start < 3


@pytest.mark.parametrize("kw", [{"stamp": False}, {"version": 0}, {"stamp_at_ms": 1_000_000}, {"row": False}])
def test_fill_with_no_mod_to_ask_is_none_and_nobody_is_asked(env, kw):
    m = env["make"](fill_mode="ok", **kw)
    assert asyncio.run(MB.fill(env["settings"], PID, "x", "replace")) is None
    assert m.fill_requests == 0


def test_fill_refuses_a_mode_it_does_not_know_and_a_text_too_long_without_asking(env):
    m = env["make"](fill_mode="ok")
    assert asyncio.run(MB.fill(env["settings"], PID, "x", "swap")) is None
    assert asyncio.run(MB.fill(env["settings"], PID, "x" * (MB.MAX_FILL + 1), "replace")) is None
    assert m.fill_requests == 0


@pytest.mark.parametrize("reply", [{"isFilled": "yes", "text": "", "cursor": 0}, {"isFilled": True, "text": 5, "cursor": 0},
                                   {"isFilled": True, "text": "", "cursor": "0"}, {"isFilled": True, "text": "", "cursor": True},
                                   {"isFilled": True, "text": "", "cursor": 0, "refusal": 5}])
def test_fill_with_a_reply_not_shaped_as_an_answer_is_none(env, reply, monkeypatch):
    env["make"](fill_mode="ok")

    async def fake_ask(settings, pid, verb, payload=None, wait=MB.REPLY_WAIT):
        return {"ok": True, "reqid": "x", **reply}

    monkeypatch.setattr(MB, "_ask", fake_ask)
    assert asyncio.run(MB.fill(env["settings"], PID, "x", "replace")) is None


def test_the_payload_file_is_private_and_removed_when_the_mod_never_answers(env):
    m = env["make"](fill_mode="silent")
    seen = []
    real = MB._write_private

    def spy(path, value):
        ok = real(path, value)
        seen.append((path.name, oct(path.stat().st_mode & 0o777)))
        return ok

    env["monkeypatch"].setattr(MB, "_write_private", spy)
    assert asyncio.run(MB.fill(env["settings"], PID, "x", "replace", wait=0.3)) is None
    assert seen and seen[0][0].endswith(".fill.json") and seen[0][1] == "0o600"
    assert not list(m.run_dir.glob("*.fill.json*"))


@pytest.mark.parametrize("sent,box", [
    ("a\r\nb", "a\nb"), ("a\rb", "a\nb"), ("a​b", "ab"), ("a\x00b\x07c\x1bd", "abcd"), ("hello   \n\n  \n", "hello"),
    ("  lead", "  lead"), ("tab\there", "tab\there"), ("é", "é"),
])
def test_normalize_is_what_the_cli_keeps_of_a_text(sent, box):
    assert MB.normalize(sent) == box
