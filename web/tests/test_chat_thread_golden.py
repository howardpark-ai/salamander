"""The second-session golden: what the existing routes answer for a session that is NOT the chat session, recorded before the chat thread read
(chatthread.py, GET /api/chat/thread) was added, and held unchanged.

The recording is tests/fixtures/chat_thread_golden.json, made by this file run against the code of the commit before that change
(SALA_WEB_WRITE_GOLDEN=1 writes it instead of comparing; write it only from code whose answers are meant to be the new baseline). Held, with no chat
session configured and with one configured under another name: the transcript route (the last page, an older page, a newer page, a page around a line), the
stream's `reset`, GET /api/sessions and GET /api/chat. The comparison is of the JSON text, so a key that moves, appears or goes fails it too.

What a wrong answer costs: a change made for the chat session's thread that alters what any other session's page shows. Names and texts are invented; every
temporary folder is removed as the test ends."""

from __future__ import annotations

import base64
import json
import os
import shutil
import urllib.request
from pathlib import Path

import pytest

import conftest
from conftest import transcript_file

GOLDEN = Path(__file__).parent / "fixtures" / "chat_thread_golden.json"
WORK = "/srv/demo/work"        # the fake session's folder in the recording: made up, and under nobody's home
OWNER = "Owner"
OTHER_CHAT = "demo-chat"       # a configured chat session that is not the session read here, and that does not run
PIXEL = base64.b64encode(b"\x89PNG\r\n\x1a\n").decode()
SERVED = [{"lane": "subscription-1"}]   # the lane is pinned: it would otherwise be read from the test runner's own environment


@pytest.fixture(autouse=True)
def _rm_tmp(tmp_path):
    yield
    shutil.rmtree(tmp_path, ignore_errors=True)


@pytest.fixture(autouse=True)
def _made_up_folder(monkeypatch):
    """`served` and transcript_file read conftest's CWD as they run; here it is the folder the recording holds."""
    monkeypatch.setattr(conftest, "CWD", WORK)


def line(n: int, kind: str, content, **more) -> dict:
    return {"type": kind, "uuid": f"g-{n}", "timestamp": f"2026-10-14T10:{n:02d}:00.000Z",
            "message": {"role": kind, "content": content}, **more}


def typed(n: int, content, source: str = "typed") -> dict:
    return line(n, "user", content, origin={"kind": "human"}, promptSource=source)


def delivered(n: int, text: str, kind: str = "peer", meta: bool = True) -> dict:
    return line(n, "user", [{"type": "text", "text": text}], origin={"kind": kind}, isMeta=meta)


def said(n: int, text: str, stop: str = "end_turn", *more) -> dict:
    d = line(n, "assistant", [{"type": "text", "text": text}, *more])
    d["message"].update(model="claude-opus-5-5", stop_reason=stop)
    return d


def queued(n: int, text: str, origin: str, meta: bool = False) -> dict:
    return {"type": "attachment", "uuid": f"g-{n}", "timestamp": f"2026-10-14T10:{n:02d}:00.000Z",
            "attachment": {"type": "queued_command", "prompt": text, "origin": {"kind": origin}, "commandMode": "prompt", "isMeta": meta}}


def transcript() -> list[dict]:
    peer = "Another Claude session sent a message:\nfrom: demo-peer\n\n"
    return [
        typed(1, [{"type": "text", "text": "What is open on demo#1?"}, {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": PIXEL}}]),
        said(2, "Looking.", "tool_use", {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "true"}}),
        line(3, "user", [{"type": "tool_result", "tool_use_id": "t1", "content": "ok"}], toolUseResult={"stdout": "ok"}),
        line(4, "assistant", [{"type": "thinking", "thinking": "weighing it"}]),
        said(5, "Two things, see /mockup/1 and https://claude.ai/artifact/demo-id"),
        delivered(6, peer + "The build is green."),
        said(7, "Noted."),
        line(8, "user", "Stop hook feedback:\nadd a line", isMeta=True),
        said(9, "[for Owner] Added."),
        queued(10, "and the second one?", "human"),
        queued(11, peer + "One more thing.", "peer", True),
        said(12, "The second one waits."),
        line(13, "user", "<task-notification><summary>a job finished</summary></task-notification>", origin={"kind": "task-notification"}),
        said(14, "Filed."),
        typed(15, "<!-- sala --> wake up"),
        said(16, "Awake."),
        line(17, "user", "<command-name>/demo</command-name><command-args>one</command-args>"),
        said(18, "Done."),
        typed(19, "thanks", "queued"),
        said(20, "You are welcome."),
    ]


def get(url: str):
    with urllib.request.urlopen(url, timeout=10) as r:
        return json.load(r)


def first_reset(url: str) -> dict:
    """The data of the stream's first `reset` event; the stream is closed as soon as it has come."""
    with urllib.request.urlopen(url, timeout=20) as resp:
        event = None
        for raw in resp:
            text = raw.decode().rstrip("\n")
            if text.startswith("event: "):
                event = text[7:]
            elif text.startswith("data: ") and event == "reset":
                return json.loads(text[6:])
    raise AssertionError("the stream ended with no reset")


def steady(value):
    """The answer with what differs from run to run named instead of kept: this process's id and the transcript's temporary path."""
    if isinstance(value, dict):
        return {k: "<pid>" if k == "pid" and v == os.getpid() else "<path>" if k == "path" and isinstance(v, str) else steady(v) for k, v in value.items()}
    if isinstance(value, list):
        return [steady(v) for v in value]
    return value


def record(served: dict, monkeypatch) -> dict:
    path = transcript_file(served)
    lines = [json.dumps(d) + "\n" for d in transcript()]
    path.write_text("".join(lines), encoding="utf-8")
    middle = len("".join(lines[:9]).encode())
    base = f"{served['url']}/api/s/{os.getpid()}"
    out: dict = {}
    for case, chat in (("no chat session", None), ("another chat session", OTHER_CHAT)):
        if chat is None:
            monkeypatch.delenv("SALA_CHAT_SESSION", raising=False)
        else:
            monkeypatch.setenv("SALA_CHAT_SESSION", chat)
        tail = get(base + "/transcript?n=6")
        out[case] = steady({
            "transcript": get(base + "/transcript"),
            "tail": tail,
            "before": get(f"{base}/transcript?before={tail['before']}&n=4"),
            "after": get(base + "/transcript?after=0&n=5"),
            "around": get(f"{base}/transcript?around={middle}&n=6"),
            "reset": first_reset(base + "/stream"),
            "sessions": get(served["url"] + "/api/sessions"),
            "chat": get(served["url"] + "/api/chat"),
        })
    return out


@pytest.mark.parametrize("served", SERVED, indirect=True)
def test_another_sessions_answers_are_the_ones_recorded_before_the_thread_read(served, monkeypatch):
    monkeypatch.setenv("SALA_OWNER_NAME", OWNER)
    got = record(served, monkeypatch)
    if os.environ.get("SALA_WEB_WRITE_GOLDEN"):
        GOLDEN.write_text(json.dumps(got, indent=1) + "\n", encoding="utf-8")
    want = json.loads(GOLDEN.read_text(encoding="utf-8"))
    assert list(got) == list(want)
    for case in want:
        assert list(got[case]) == list(want[case]), case
        for name in want[case]:
            assert json.dumps(got[case][name]) == json.dumps(want[case][name]), f"{case}: {name}"
