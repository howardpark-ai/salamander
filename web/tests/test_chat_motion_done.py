"""The owner's side of a done motion line: a done line stays on the list until the owner confirms it (MO.confirm, POST /api/chat/motion/confirm),
its result link is the given link or the first reply at or after its done time (chatpage.reply_pos, the `mine` list of GET /api/chat). A reply found is kept
and a miss reads only what the transcript gained since; the link `motion done --link` takes is one that lands somewhere (the CLI's rule and the page's, held
to the anchors static/address.js reads, under node when it is there).

All names are invented. Nothing here reaches the network: the app runs on 127.0.0.1 (conftest's served fixture) and the transcript is written by the test.
"""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

import pytest

from conftest import NAME, SID, transcript_file
from sala_web import chatpage as CP
from sala_web import motion as MO
from test_addresses import run_node


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


@pytest.fixture
def reads(monkeypatch):
    """What reply_pos reads of a transcript: one [path, offset it sought to, bytes it got] per open."""
    seen: list[list] = []

    class Counted:
        def __init__(self, path, mode):
            self.f, self.row = open(path, mode), [str(path), 0, 0]
            seen.append(self.row)

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            self.f.close()

        def seek(self, at):
            self.row[1] = at
            return self.f.seek(at)

        def read(self, n=-1):
            got = self.f.read(n)
            self.row[2] += len(got)
            return got

        def __iter__(self):
            for line in self.f:
                self.row[2] += len(line)
                yield line

    monkeypatch.setattr(CP, "open", Counted, raising=False)    # chatpage's own `open` only
    return seen


def append(path, text: str) -> None:
    with path.open("a") as f:
        f.write(text)


T0 = 1_800_000_000_000


def test_reply_pos_keeps_a_reply_it_found_while_the_transcript_grows(tmp_path, reads):
    path = tmp_path / "t.jsonl"
    path.write_text(reply_line("a1", T0 + 1_000))
    cache: dict = {}
    first = CP.reply_pos(path, T0, False, cache)
    assert first == (0, "a1") and len(reads) == 1
    for i in range(3):
        append(path, reply_line(f"later{i}", T0 + 2_000 + i))
        assert CP.reply_pos(path, T0, False, cache) == first
    assert CP.reply_pos(path, T0, False, cache) == first
    assert len(reads) == 1 and len(cache) == 1


def test_reply_pos_after_a_miss_reads_only_what_was_appended(tmp_path, reads):
    path = tmp_path / "t.jsonl"
    body = "".join(filler_line(f"u{i}", T0 - 1_000 + i) for i in range(20))
    path.write_text(body)
    cache: dict = {}
    assert CP.reply_pos(path, T0, False, cache) is None and reads == [[str(path), 0, len(body)]]
    assert CP.reply_pos(path, T0, False, cache) is None and len(reads) == 1              # nothing new: nothing read
    more = filler_line("u-new", T0 + 1_000)
    append(path, more)
    assert CP.reply_pos(path, T0, False, cache) is None and reads[1:] == [[str(path), len(body), len(more)]]
    reply = reply_line("a1", T0 + 2_000)
    append(path, reply[:40])                                                             # a line still being written
    at = len(body) + len(more)
    assert CP.reply_pos(path, T0, False, cache) is None and reads[2] == [str(path), at, 40]
    assert CP.reply_pos(path, T0, False, cache) is None and len(reads) == 3
    append(path, reply[40:])
    assert CP.reply_pos(path, T0, False, cache) == (at, "a1") and reads[3] == [str(path), at, len(reply)]


def test_reply_pos_takes_the_first_of_the_appended_replies_and_not_one_before_the_done_time(tmp_path):
    path = tmp_path / "t.jsonl"
    path.write_text(filler_line("u1", T0 - 1_000))
    cache: dict = {}
    assert CP.reply_pos(path, T0, False, cache) is None
    append(path, reply_line("old", T0 - 500) + reply_line("a1", T0 + 1) + reply_line("a2", T0 + 2))
    got = CP.reply_pos(path, T0, False, cache)
    assert got is not None and got[1] == "a1" and got == CP.reply_pos(path, T0, False, {})


@pytest.mark.parametrize("how", ["shrunk", "replaced"])
def test_reply_pos_looks_afresh_at_a_transcript_that_shrank_or_was_replaced(tmp_path, how):
    path = tmp_path / "t.jsonl"
    path.write_text(filler_line("u1", T0 - 1_000) + reply_line("a1", T0 + 1_000))
    cache: dict = {}
    assert CP.reply_pos(path, T0, False, cache)[1] == "a1"
    if how == "shrunk":
        path.write_text(reply_line("b1", T0 + 3_000))
    else:   # another file under the same name, and a longer one
        other = tmp_path / "new.jsonl"
        other.write_text("".join(filler_line(f"n{i}", T0 - 100 + i) for i in range(9)) + reply_line("b1", T0 + 3_000))
        assert other.stat().st_size > path.stat().st_size
        os.replace(other, path)
    got = CP.reply_pos(path, T0, False, cache)
    assert got is not None and got[1] == "b1" and got == CP.reply_pos(path, T0, False, {})


def test_reply_pos_never_links_a_later_reply_when_the_first_is_out_of_reach(tmp_path, reads, monkeypatch):
    monkeypatch.setattr(CP, "REPLY_WINDOW_FIRST", 256)
    monkeypatch.setattr(CP, "REPLY_WINDOW_MAX", 512)
    path = tmp_path / "t.jsonl"
    path.write_text(reply_line("first", T0 + 1_000) + "".join(filler_line(f"u{i}", T0 + 2_000 + i) for i in range(10)))
    cache: dict = {}
    assert CP.reply_pos(path, T0, False, cache) is None
    looked = len(reads)
    append(path, reply_line("later", T0 + 9_000))
    assert CP.reply_pos(path, T0, False, cache) is None and len(reads) == looked


def test_reply_pos_records_nothing_when_the_read_fails(tmp_path, monkeypatch):
    path = tmp_path / "t.jsonl"
    path.write_text(reply_line("a1", T0 + 1_000))
    cache: dict = {}

    def refuse(*args):
        raise OSError("no")

    monkeypatch.setattr(CP, "open", refuse, raising=False)
    assert CP.reply_pos(path, T0, False, cache) is None and cache == {}
    monkeypatch.delattr(CP, "open")
    assert CP.reply_pos(path, T0, False, cache) == (0, "a1")


# ---------- the link `motion done --link` takes: the CLI's rule (lib/motion.py) and the page's reader (motion.py) ----------

spec = importlib.util.spec_from_file_location("sala_lib_motion", Path(__file__).resolve().parents[2] / "lib" / "motion.py")
CLI = importlib.util.module_from_spec(spec)
spec.loader.exec_module(CLI)

ANCHORS = ["#s=chat-a", "#s=a%2Fb", "#lane=subscription-1", "#sessions", "#schedules", "#machines", "#usage", "#new", "#search", "#search?q=zebra&hours=24",
           "#side=", "#side=from:chat-a", "#side=item%2338"]
TAKEN = ANCHORS + ["https://example.com/r", "https://example.com/r#nope", "/", "/mockup/4", "/s/chat-a#x"]
REFUSED = ["#", "#nope", "#s=", "#lane=", "#lane=a&b", "#session", "#sessions2", "#searching", "#side", "#new?x", "s=chat-a", "mockup/4", "//example.com/x",
           "/\\example.com/x", "http://example.com/r", "javascript:alert", "#s=a b", "https://", "", "/" + "x" * 500]


@pytest.mark.parametrize("link", TAKEN)
def test_a_link_that_lands_somewhere_is_taken_by_both(link):
    assert CLI.link_ok(link) and MO._link_ok(link)


@pytest.mark.parametrize("link", REFUSED)
def test_a_link_that_lands_nowhere_is_refused_by_both(link):
    assert not CLI.link_ok(link) and not MO._link_ok(link)


@pytest.mark.skipif(not shutil.which("node"), reason="node is not installed")
def test_every_anchor_that_is_taken_is_a_view_the_page_reads():
    got = run_node(f"""const page = load("https://sala.example.test/");
      console.log(JSON.stringify({json.dumps(ANCHORS + ["#nope", "#"])}.map((v) => page.A.path(v))));""")
    assert all(isinstance(p, str) and p for p in got[:-2]) and got[-2:] == [None, None], got


def test_a_stored_anchor_that_names_no_view_is_dropped_on_read(tmp_path):
    write_motion(tmp_path, "chat-a", [{"text": "a", "at": 5, "done": 7, "link": "#nope"}, {"text": "b", "at": 6, "done": 7, "link": "#usage"}])
    assert [r.get("link") for r in MO.read_lines(tmp_path, "chat-a")] == [None, "#usage"]
    assert [r.get("link") for r in CLI.load(str(tmp_path / "chat-a.json"))] == [None, "#usage"]


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


def test_the_replies_found_outlive_the_polls_of_a_growing_transcript(chat_on, monkeypatch):
    # eight done lines are more entries than the transcript counts keep: the counts being emptied must not take them along
    now_s = int(time.time())
    write_motion(chat_on["settings"].motion_dir, NAME, [{"text": f"line {i}", "at": now_s - 600, "done": now_s - 300 + i} for i in range(8)])
    transcript_file(chat_on).write_text(reply_line("a-late", (now_s - 100) * 1000))
    looked: list = []
    real = CP._reply_back
    monkeypatch.setattr(CP, "_reply_back", lambda *args: looked.append(args[2]) or real(*args))
    for i in range(12):
        append(transcript_file(chat_on), filler_line(f"more{i}", now_s * 1000))
        with urllib.request.urlopen(chat_on["url"] + "/api/chat", timeout=20) as r:
            d = json.loads(r.read())
        assert [m["jump"]["uuid"] for m in d["mine"]] == ["a-late"] * 8
    assert len(looked) == 8, "one first look for each done line, however often the transcript grew"
