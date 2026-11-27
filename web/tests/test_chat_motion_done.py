"""The owner's side of a done motion line: a done line stays on the list until the owner confirms it (MO.confirm, POST /api/chat/motion/confirm),
its result link is the given link or the first reply at or after its done time (chatpage.reply_pos, the `mine` list of GET /api/chat).

All names are invented. Nothing here reaches the network: the app runs on 127.0.0.1 (conftest's served fixture) and the transcript is written by the test.
"""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

import pytest

from conftest import NAME, SID, transcript_file
from sala_web import chatpage as CP
from sala_web import motion as MO


def iso(ms: int) -> str:
    return datetime.fromtimestamp(ms / 1000, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def reply_line(uuid: str, ms: int) -> str:
    return json.dumps({"type": "assistant", "uuid": uuid, "timestamp": iso(ms),
                       "message": {"role": "assistant", "stop_reason": "end_turn", "content": [{"type": "text", "text": "done"}]}}) + "\n"


def filler_line(uuid: str, ms: int) -> str:
    return json.dumps({"type": "user", "uuid": uuid, "timestamp": iso(ms), "origin": {"kind": "human"}, "promptSource": "typed",
                       "message": {"role": "user", "content": "x" * 150}}) + "\n"


def write_motion(root, session, rows) -> None:
    root.mkdir(parents=True, exist_ok=True)
    (root / f"{session}.json").write_text(json.dumps({"v": 1, "lines": rows}))


# ---------- confirm (the one write of the owner's side) ----------

def test_confirm_removes_only_the_done_line_it_is_given(tmp_path):
    write_motion(tmp_path, "chat-a", [{"text": "a", "at": 5, "done": 7}, {"text": "b", "at": 6}])
    assert MO.confirm(tmp_path, "chat-a", "b", 6) == "unknown"          # not done: nothing to confirm
    assert MO.confirm(tmp_path, "chat-a", "a", 4) == "unknown"          # the wrong time is not that line
    assert MO.confirm(tmp_path, "chat-a", "zz", 5) == "unknown"         # no such line
    assert MO.confirm(tmp_path, "../x", "a", 5) == "unknown"            # a name that is not a session name
    assert MO.confirm(tmp_path, "chat-none", "a", 5) == "unknown"       # no file
    assert MO.confirm(tmp_path, "chat-a", "a", 5) == "ok"
    assert json.loads((tmp_path / "chat-a.json").read_text()) == {"v": 1, "lines": [{"text": "b", "at": 6}]}


def test_a_line_confirmed_twice_is_a_clean_refusal(tmp_path):
    write_motion(tmp_path, "chat-a", [{"text": "a", "at": 5, "done": 7}])
    assert MO.confirm(tmp_path, "chat-a", "a", 5) == "ok"
    assert MO.confirm(tmp_path, "chat-a", "a", 5) == "unknown"


# ---------- reply_pos (the first reply at or after a done time, by a backward scan) ----------

def test_reply_pos_is_the_first_reply_at_or_after_the_done_time(tmp_path):
    t0 = 1_800_000_000_000
    path = tmp_path / "t.jsonl"
    first = filler_line("u1", t0)
    a1 = reply_line("a1", t0 + 1_000)
    a2 = reply_line("a2", t0 + 5_000)
    path.write_text(first + a1 + a2)
    got = CP.reply_pos(path, t0 + 2_000, False, {})
    assert got == (len((first + a1).encode()), "a2")
    assert CP.reply_pos(path, t0 + 9_000, False, {}) is None           # no reply yet at or after it


def test_reply_pos_reads_back_far_enough_for_a_reply_further_up(tmp_path, monkeypatch):
    monkeypatch.setattr(CP, "REPLY_WINDOW_FIRST", 256)                 # force the doubling
    t0 = 1_800_000_000_000
    path = tmp_path / "t.jsonl"
    body = reply_line("early", t0 + 10_000) + "".join(filler_line(f"u{i}", t0 + 20_000 + i) for i in range(200)) + reply_line("late", t0 + 150_000)
    path.write_text(body)
    got = CP.reply_pos(path, t0 + 100_000, False, {})
    assert got is not None and got[1] == "late"
    assert CP.reply_pos(path, t0 + 5_000, False, {})[1] == "early"    # older than the whole window: found at the start


def test_reply_pos_is_cached_per_transcript_stamp(tmp_path):
    t0 = 1_800_000_000_000
    path = tmp_path / "t.jsonl"
    path.write_text(reply_line("a1", t0 + 1_000))
    cache: dict = {}
    first = CP.reply_pos(path, t0, False, cache)
    assert first is not None and first[1] == "a1"
    assert CP.reply_pos(path, t0, False, cache) == first
    assert len(cache) == 1


# ---------- the route: POST /api/chat/motion/confirm ----------

def post(url: str, body: bytes, headers: dict) -> tuple[int, bytes]:
    req = urllib.request.Request(url, data=body, method="POST", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


JSON = {"Content-Type": "application/json"}


@pytest.fixture
def chat_on(served, monkeypatch):
    monkeypatch.setenv("SALA_CHAT_SESSION", NAME)
    return served


def test_confirm_route_refusals_and_the_one_clear(chat_on):
    base = chat_on["url"] + "/api/chat/motion/confirm"
    root = chat_on["settings"].motion_dir
    write_motion(root, NAME, [{"text": "drawing slide 4", "at": 100, "done": 200}])
    good = json.dumps({"text": "drawing slide 4", "at": 100}).encode()
    status, _ = post(base, good, {"Content-Type": "application/json", "Origin": "http://evil.example"})
    assert status == 403
    status, _ = post(base, good, {"Content-Type": "text/plain"})
    assert status == 415
    status, _ = post(base, b"{not json", JSON)
    assert status == 400
    status, _ = post(base, json.dumps({"text": "x" * 5000, "at": 100}).encode(), JSON)
    assert status == 413
    status, _ = post(base, json.dumps({"text": "a", "at": True}).encode(), JSON)
    assert status == 400
    status, _ = post(base, json.dumps({"text": "nothing", "at": 100}).encode(), JSON)
    assert status == 409
    status, body = post(base, good, JSON)
    assert status == 200 and json.loads(body) == {"ok": True}
    status, _ = post(base, good, JSON)                                   # confirmed twice: a clean refusal
    assert status == 409


def test_a_done_line_is_on_mine_with_the_reply_it_links_to(chat_on):
    now_s = int(time.time())                  # motion.py's times are epoch seconds; the transcript's are written in ms below
    write_motion(chat_on["settings"].motion_dir, NAME, [
        {"text": "drawing slide 4", "at": now_s - 600, "done": now_s - 300},
        {"text": "open line", "at": now_s - 60},
        {"text": "with a link", "at": now_s - 600, "done": now_s - 300, "link": "/mockup/4"},
    ])
    transcript_file(chat_on).write_text(reply_line("a-late", (now_s - 100) * 1000))
    with urllib.request.urlopen(chat_on["url"] + "/api/chat", timeout=20) as r:
        d = json.loads(r.read())
    assert [m["text"] for m in d["motion"]] == ["open line"]
    by = {m["text"]: m for m in d["mine"]}
    assert by["drawing slide 4"]["jump"]["uuid"] == "a-late"
    assert by["drawing slide 4"]["jump"]["session"] == SID
    assert "jump" not in by["with a link"] and by["with a link"]["link"] == "/mockup/4"
