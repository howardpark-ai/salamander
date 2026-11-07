"""The unread reply count (it replaced the "New" chip and the board count on the rows): a
front agent's sidebar row carries a filled orange count of the replies it has written since the owner last opened it, at the row's far
right; a folded project or scope header carries the total of the sessions inside. Each turn that ended in a reply adds one, a turn
still running does not count yet, above 9 it reads 9+, and a background agent never has one.

What a wrong answer costs: a count on a session he already read (he stops trusting it), no count on a reply he missed (the point of
it), a count on a background agent he never reads, a count on the session he has open, a phone and a desktop that disagree about
what is read, a deploy that lights every row at once, or a row that grows for it. The server decides (unread.py and
transcript.count_replies_since: front agent, replies of ended turns newer than the marker in state_dir/read-state.json; first sight
of a session = read), so most checks read the transcript scan, the marker store, the endpoints and the polled list; the browser
checks hold what the page does with `unread_count` (the count on the row and the total on a folded header, 9+, none on the open
session or a background row, the count clears on open and tells the server, and no row or header changes height for it).
The browser is a headless Chromium at 1280 px; api/sessions is a stub with a mutable count by session name (the server's rules are
held above it)."""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.request

import pytest

from conftest import SID, transcript_file
from sala_web import transcript as TR
from sala_web import unread as UR
from test_board_items_ui import CONTRAST, wait_for
from test_composer_attach import WAIT_READY
from test_fork_menu import box, row_sel
from test_new_session import env, sala  # noqa: F401  (fixtures)

DAY_MS = 86400 * 1000
T0 = 1_790_000_000_000   # a fixed "now", epoch ms


def iso(ms: int) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(ms / 1000)) + f".{ms % 1000:03d}Z"


def line(kind: str, ms: int, content, uuid: str, **extra) -> str:
    d = {"type": kind, "uuid": uuid, "timestamp": iso(ms), "message": {"role": kind, "content": content, **extra.pop("message", {})}, **extra}
    return json.dumps(d) + "\n"


def reply(ms: int, uuid: str = "a", text: str = "Done.", **extra) -> str:
    return line("assistant", ms, [{"type": "text", "text": text}], uuid, **extra)


# ---------- the reply of a transcript ----------

def test_latest_reply_is_the_last_main_thread_assistant_text(tmp_path):
    p = tmp_path / "t.jsonl"
    p.write_text(
        reply(T0 + 1000, "r1")
        + line("user", T0 + 2000, [{"type": "text", "text": "ok"}], "u1")
        + reply(T0 + 3000, "r2")
        # none of these is a reply the owner can read: a tool call alone, thinking alone, a blank text, a sub-agent's line, a
        # meta line, the CLI's own synthetic line (an interrupt or an API error)
        + line("assistant", T0 + 4000, [{"type": "tool_use", "id": "t", "name": "Bash", "input": {}}], "x1")
        + line("assistant", T0 + 5000, [{"type": "thinking", "thinking": "hm"}], "x2")
        + reply(T0 + 6000, "x3", text="  ")
        + reply(T0 + 7000, "x4", isSidechain=True)
        + reply(T0 + 8000, "x5", isMeta=True)
        + line("assistant", T0 + 9000, [{"type": "text", "text": "No response requested."}], "x6", message={"model": "<synthetic>"}))
    assert TR.latest_reply(p) == {"uuid": "r2", "ts": T0 + 3000}


def test_latest_reply_none_when_there_is_none_or_the_file_is_gone(tmp_path):
    p = tmp_path / "t.jsonl"
    p.write_text(line("user", T0, [{"type": "text", "text": "hi"}], "u1") + "not json {\n")
    assert TR.latest_reply(p) is None
    assert TR.latest_reply(tmp_path / "gone.jsonl") is None


def test_latest_reply_widens_the_tail_for_a_reply_far_back(tmp_path):
    p = tmp_path / "t.jsonl"
    filler = "".join(line("user", T0 + i, [{"type": "tool_result", "tool_use_id": "t", "content": "x" * 5000}], f"f{i}") for i in range(80))
    p.write_text(reply(T0, "old") + filler)
    assert p.stat().st_size > 300 * 1024   # past the first 256 KB window
    assert TR.latest_reply(p) == {"uuid": "old", "ts": T0}


def test_reply_cache_rereads_only_when_the_file_changes(tmp_path):
    p = tmp_path / "t.jsonl"
    p.write_text(reply(T0, "r1"))
    c = TR.ReplyCache()
    assert c.get(p)["uuid"] == "r1"
    with p.open("a") as f:
        f.write(reply(T0 + 1000, "r2"))
    assert c.get(p) == {"uuid": "r2", "ts": T0 + 1000}
    p.unlink()
    assert c.get(p) is None


# ---------- the count of replies since a time ----------

def ended(ms: int, uuid: str, stop: str | None = "end_turn", text: str = "Done.", **extra) -> str:
    """A reply the way the CLI writes a finished one: the message carries its stop_reason."""
    return reply(ms, uuid, text, message={"stop_reason": stop}, **extra)


def test_count_replies_since_counts_only_the_replies_after_the_time(tmp_path):
    p = tmp_path / "t.jsonl"
    p.write_text(ended(T0 + 1000, "r1") + line("user", T0 + 1500, [{"type": "text", "text": "go on"}], "u1")
                 + ended(T0 + 2000, "r2") + ended(T0 + 3000, "r3"))
    assert TR.count_replies_since(p, T0) == 3
    assert TR.count_replies_since(p, T0 + 1000) == 2          # a reply at the marker's own time is read
    assert TR.count_replies_since(p, T0 + 2999) == 1
    assert TR.count_replies_since(p, T0 + 3000) == 0
    assert TR.count_replies_since(tmp_path / "gone.jsonl", 0) == 0


def test_narration_before_a_tool_call_is_not_a_reply(tmp_path):
    """Text the model writes on its way to a tool call (stop_reason tool_use), a tool call alone, thinking alone, a blank text, a
    sub-agent's line, a meta line and a synthetic line are not replies; the turn's last text is."""
    p = tmp_path / "t.jsonl"
    p.write_text(reply(T0 + 1000, "n1", text="Let me look.", message={"stop_reason": "tool_use"})
                 + line("assistant", T0 + 1100, [{"type": "tool_use", "id": "t", "name": "Bash", "input": {}}], "x1", message={"stop_reason": "tool_use"})
                 + line("assistant", T0 + 1200, [{"type": "thinking", "thinking": "hm"}], "x2")
                 + ended(T0 + 1300, "x3", text="  ") + ended(T0 + 1400, "x4", isSidechain=True) + ended(T0 + 1500, "x5", isMeta=True)
                 + line("assistant", T0 + 1600, [{"type": "text", "text": "No response requested."}], "x6", message={"model": "<synthetic>", "stop_reason": "stop_sequence"})
                 + ended(T0 + 2000, "r1"))
    assert TR.count_replies_since(p, 0) == 1
    assert TR.count_replies_since(p, 0, strict=True) == 1


def test_a_running_turns_text_is_not_counted_until_it_says_it_ended(tmp_path):
    """No stop_reason yet is what the CLI writes while a message streams: it counts for an idle session (nothing is streaming,
    and older transcripts have none) and not for a busy one. The turns that ended before stay counted."""
    p = tmp_path / "t.jsonl"
    p.write_text(ended(T0 + 1000, "r1") + ended(T0 + 2000, "r2") + reply(T0 + 3000, "streaming"))
    assert TR.count_replies_since(p, 0) == 3
    assert TR.count_replies_since(p, 0, strict=True) == 2
    assert TR.count_replies_since(p, T0 + 1000, strict=True) == 1


def test_the_count_stops_at_the_limit_and_widens_the_tail_for_a_reader_far_behind(tmp_path):
    p = tmp_path / "t.jsonl"
    p.write_text("".join(ended(T0 + i, f"r{i}") for i in range(1, 30)))
    assert TR.count_replies_since(p, 0) == TR.REPLY_COUNT_MAX == 10
    assert TR.count_replies_since(p, 0, limit=4) == 4
    assert TR.count_replies_since(p, T0 + 26) == 3
    # three replies at the start, then 400 KB of tool output after them: the first 256 KB window holds none of them, and the
    # marker is before all three, so the scan widens (4x) to reach them
    filler = "".join(line("user", T0 + 100 + i, [{"type": "tool_result", "tool_use_id": "t", "content": "x" * 5000}], f"f{i}") for i in range(80))
    p.write_text(ended(T0 + 1, "a") + ended(T0 + 2, "b") + ended(T0 + 3, "c") + filler)
    assert p.stat().st_size > 300 * 1024
    assert TR.count_replies_since(p, 0) == 3
    assert TR.count_replies_since(p, T0 + 2) == 1
    # past the byte cap the scan stops short: 9+ is a floor, not an exact number
    assert TR.count_replies_since(p, 0, cap=TR.REPLY_TAIL) == 0


def test_the_count_cache_rereads_only_when_the_file_the_marker_or_the_strictness_changes(tmp_path, monkeypatch):
    p = tmp_path / "t.jsonl"
    p.write_text(ended(T0 + 1000, "r1"))
    calls = []
    real = TR.count_replies_since
    monkeypatch.setattr(TR, "count_replies_since", lambda *a, **k: calls.append(a) or real(*a, **k))
    c = TR.ReplyCache()
    assert [c.count_since(p, 0) for _ in range(3)] == [1, 1, 1] and len(calls) == 1
    assert c.count_since(p, T0 + 1000) == 0 and len(calls) == 2         # another marker
    assert c.count_since(p, T0 + 1000, strict=True) == 0 and len(calls) == 3
    with p.open("a") as f:
        f.write(ended(T0 + 2000, "r2"))
    assert c.count_since(p, T0 + 1000, strict=True) == 1 and len(calls) == 4
    p.unlink()
    assert c.count_since(p, 0) == 0


# ---------- the marker store ----------

def scopes_of(*sessions: dict) -> list[dict]:
    return [{"key": "example", "title": "example", "groups": [{"key": "projects/alpha", "title": "alpha", "sessions": list(sessions)}]}]


def sdict(name: str, role: str | None = "front", status: str = "idle") -> dict:
    return {"name": name, "cwd": "/home/alex/work", "sessionId": SID, "status": status, "role": role}


@pytest.fixture
def store(tmp_path):
    projects = tmp_path / "projects"
    d = projects / TR.project_slug("/home/alex/work")
    d.mkdir(parents=True)
    t = d / f"{SID}.jsonl"
    t.write_text(reply(T0, "r0"))
    return {"path": tmp_path / "state" / UR.FILE_NAME, "projects": projects, "transcript": t, "state": UR.ReadState(tmp_path / "state" / UR.FILE_NAME, projects)}


def append_reply(store, ms: int, uuid: str) -> None:
    with store["transcript"].open("a") as f:
        f.write(reply(ms, uuid))


def unread_of(store, s: dict, now: int) -> bool:
    store["state"].annotate(scopes_of(s), now)
    assert s["unread"] is (s["unread_count"] > 0)
    return s["unread"]


def count_of(store, s: dict, now: int) -> int:
    store["state"].annotate(scopes_of(s), now)
    return s["unread_count"]


def test_first_sight_is_read_and_a_later_reply_is_unread_until_opened(store):
    st = store["state"]
    s = sdict("example-alpha-main")
    assert unread_of(store, s, T0 + 1) is False                       # a deploy lights nothing
    data = json.loads(store["path"].read_text())
    assert data["version"] == 1 and data["sessions"]["example-alpha-main"] == {"read": T0, "seen": T0 + 1}
    append_reply(store, T0 + 5000, "r1")
    assert unread_of(store, sdict("example-alpha-main"), T0 + 6000) is True
    assert st.mark_read("example-alpha-main", "/home/alex/work", SID, T0 + 7000) is True
    assert unread_of(store, sdict("example-alpha-main"), T0 + 8000) is False
    assert st.mark_read("example-alpha-main", "/home/alex/work", SID, T0 + 9000) is False   # nothing newer: nothing moved
    assert json.loads(store["path"].read_text())["sessions"]["example-alpha-main"]["read"] == T0 + 5000


def test_the_count_grows_with_each_reply_and_is_cleared_by_opening(store):
    assert count_of(store, sdict("example-alpha-main"), T0 + 1) == 0       # first sight: the sample's reply is read
    for i in range(1, 4):
        append_reply(store, T0 + i * 1000, f"r{i}")
        assert count_of(store, sdict("example-alpha-main"), T0 + i * 1000 + 1) == i
    for i in range(4, 15):
        append_reply(store, T0 + i * 1000, f"r{i}")
    assert count_of(store, sdict("example-alpha-main"), T0 + 20_000) == UR.COUNT_MAX == 10   # 10 means 10 or more: the page shows 9+
    assert store["state"].mark_read("example-alpha-main", "/home/alex/work", SID, T0 + 21_000) is True
    assert count_of(store, sdict("example-alpha-main"), T0 + 22_000) == 0
    append_reply(store, T0 + 30_000, "r30")
    assert count_of(store, sdict("example-alpha-main"), T0 + 31_000) == 1  # and counting starts again from the reply after


def test_a_turn_still_running_does_not_count_and_the_ended_ones_stay_counted(store):
    unread_of(store, sdict("example-alpha-main"), T0 + 1)
    with store["transcript"].open("a") as f:
        f.write(ended(T0 + 1000, "r1") + ended(T0 + 2000, "r2"))
        f.write(reply(T0 + 3000, "streaming"))                             # the running turn's text, no stop_reason yet
    assert count_of(store, sdict("example-alpha-main", status="busy"), T0 + 4000) == 2
    assert count_of(store, sdict("example-alpha-main", status="waiting"), T0 + 4000) == 2
    assert count_of(store, sdict("example-alpha-main", status="idle"), T0 + 4000) == 3   # it ended: nothing streams now


def test_only_an_idle_front_agent_is_ever_unread(store):
    unread_of(store, sdict("example-alpha-main"), T0 + 1)               # first sight, made read
    for name in ("example-alpha-back", "example-alpha-side", "example-alpha-nobody"):
        unread_of(store, sdict(name), T0 + 1)
    append_reply(store, T0 + 5000, "r1")
    now = T0 + 6000
    assert unread_of(store, sdict("example-alpha-main", "front", "idle"), now) is True
    for status in ("busy", "waiting", "shell"):                        # a turn still running, an answer asked for, no claude
        assert unread_of(store, sdict("example-alpha-main", "front", status), now) is False, status
    # a background agent, a session with another or no role: never, whatever its transcript says
    for role in ("back", "other", None):
        s = sdict("example-alpha-back", role)
        store["state"].annotate(scopes_of(s), now)
        assert s["unread"] is False and s["unread_count"] == 0, role


def test_a_front_agent_with_no_reply_yet_is_not_unread_and_its_first_reply_is(store):
    store["transcript"].write_text(line("user", T0, [{"type": "text", "text": "hi"}], "u1"))
    assert unread_of(store, sdict("example-alpha-main"), T0 + 1) is False
    assert json.loads(store["path"].read_text())["sessions"]["example-alpha-main"]["read"] == 0
    append_reply(store, T0 + 2000, "r1")
    assert unread_of(store, sdict("example-alpha-main"), T0 + 3000) is True


def test_the_marker_survives_a_restart_and_is_shared_by_the_file(store):
    unread_of(store, sdict("example-alpha-main"), T0 + 1)
    append_reply(store, T0 + 5000, "r1")
    other = UR.ReadState(store["path"], store["projects"])             # a restarted app, or the phone's request after the desktop's
    s = sdict("example-alpha-main")
    other.annotate(scopes_of(s), T0 + 6000)
    assert s["unread"] is True
    other.mark_read("example-alpha-main", "/home/alex/work", SID, T0 + 7000)
    again = UR.ReadState(store["path"], store["projects"])
    s2 = sdict("example-alpha-main")
    again.annotate(scopes_of(s2), T0 + 8000)
    assert s2["unread"] is False


def test_an_unreadable_file_means_first_sight_not_a_flood(store):
    store["path"].parent.mkdir(parents=True)
    store["path"].write_text("{ not json")
    append_reply(store, T0 + 5000, "r1")
    assert unread_of(store, sdict("example-alpha-main"), T0 + 6000) is False


def test_entries_not_seen_for_a_month_are_dropped_and_a_poll_does_not_rewrite_the_file(store):
    unread_of(store, sdict("example-alpha-main"), T0)
    unread_of(store, sdict("example-alpha-gone"), T0)
    mtime = store["path"].stat().st_mtime_ns
    unread_of(store, sdict("example-alpha-main"), T0 + 60_000)           # a minute on: nothing to write
    assert store["path"].stat().st_mtime_ns == mtime
    unread_of(store, sdict("example-alpha-main"), T0 + 31 * DAY_MS)       # a month on: "main" is refreshed, "gone" is dropped
    assert set(json.loads(store["path"].read_text())["sessions"]) == {"example-alpha-main"}


def test_a_transcript_outside_the_cwd_slug_is_found_once_not_on_every_poll(store, monkeypatch):
    """A transcript under another project's directory costs a glob over all of them: remembered per session."""
    other = store["projects"] / "-some-other-dir"
    other.mkdir()
    moved = other / store["transcript"].name
    store["transcript"].rename(moved)
    calls = []
    real = TR.transcript_path
    monkeypatch.setattr(TR, "transcript_path", lambda *a: calls.append(a) or real(*a))
    for i in range(3):
        assert unread_of(store, sdict("example-alpha-main"), T0 + i) is False
    assert len(calls) == 1
    assert json.loads(store["path"].read_text())["sessions"]["example-alpha-main"]["read"] == T0   # it was found
    # a reply after the move is seen through the remembered path
    with moved.open("a") as f:
        f.write(reply(T0 + 5000, "r1"))
    assert unread_of(store, sdict("example-alpha-main"), T0 + 6000) is True and len(calls) == 1
    # a miss is remembered too, but opening the session looks again
    moved.rename(store["transcript"])
    store["state"]._paths.clear()
    n = len(calls)
    for i in range(3):
        unread_of(store, sdict("example-alpha-main"), T0 + 7000 + i)
    assert len(calls) == n + 1
    store["transcript"].unlink()
    store["state"]._paths.clear()
    n = len(calls)
    store["state"].reply_ts("/home/alex/work", SID)
    store["state"].reply_ts("/home/alex/work", SID)
    assert len(calls) == n + 1
    store["state"].reply_ts("/home/alex/work", SID, fresh=True)
    assert len(calls) == n + 2


def test_the_file_is_written_whole_with_no_temp_file_left(store):
    unread_of(store, sdict("example-alpha-main"), T0)
    assert [p.name for p in store["path"].parent.iterdir()] == [UR.FILE_NAME]


# ---------- the endpoints ----------

def call(url: str, method: str, path: str, body=None, ctype: str | None = "application/json", headers: dict | None = None):
    data = body if isinstance(body, bytes) else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(url + path, data=data, method=method, headers={**({"Content-Type": ctype} if ctype else {}), **(headers or {})})
    def body_of(raw: bytes):
        try:
            return json.loads(raw or b"null")
        except ValueError:
            return raw.decode(errors="replace")   # e.g. the router's plain "Method Not Allowed"
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, body_of(r.read())
    except urllib.error.HTTPError as e:
        return e.code, body_of(e.read())


def me(served, path="/api/sessions"):
    code, data = call(served["url"], "GET", path)
    assert code == 200
    return next(s for sc in data["scopes"] for g in sc["groups"] for s in g["sessions"] if s["name"] == served["name"])


def reply_now(served, uuid: str, ahead_s: int = 60) -> None:
    """A reply in the fake session's transcript, stamped a minute after the sample's own."""
    with transcript_file(served).open("a") as f:
        f.write(reply(int(time.time() * 1000) + ahead_s * 1000, uuid))


FRONT = [{"name": "example-alpha-main", "role": "front"}]
BACK = [{"name": "example-alpha-back", "role": "back"}]
BUSY = [{"name": "example-alpha-main", "role": "front", "status": "busy"}]


@pytest.mark.parametrize("served", FRONT, indirect=True)
def test_a_front_agent_counts_its_new_replies_until_mark_read(served):
    s = me(served)
    assert s["role"] == "front" and s["unread"] is False and s["unread_count"] == 0     # first sight: the sample's old reply is read
    reply_now(served, "r-new")
    s = me(served)
    assert s["unread"] is True and s["unread_count"] == 1
    reply_now(served, "r-new2", ahead_s=90)
    reply_now(served, "r-new3", ahead_s=120)
    assert me(served)["unread_count"] == 3                             # one a reply
    code, body = call(served["url"], "POST", "/api/read", {"name": served["name"]})
    assert (code, body["ok"], body["moved"]) == (200, True, True)
    s = me(served)
    assert s["unread"] is False and s["unread_count"] == 0             # opening clears the count
    assert call(served["url"], "POST", "/api/read", {"name": served["name"]})[1]["moved"] is False   # nothing newer
    # the marker is in the state dir the app already uses, shared by every client
    saved = json.loads((served["settings"].state_dir / UR.FILE_NAME).read_text())
    assert served["name"] in saved["sessions"] and saved["version"] == 1
    reply_now(served, "r-newer", ahead_s=300)
    s = me(served)
    assert s["unread"] is True and s["unread_count"] == 1              # and the next reply counts again


@pytest.mark.parametrize("served", FRONT, indirect=True)
def test_the_count_stops_at_ten(served):
    me(served)
    for i in range(14):
        reply_now(served, f"r-{i}", ahead_s=60 + i)
    assert me(served)["unread_count"] == UR.COUNT_MAX == 10            # "10 or more": the page shows 9+


@pytest.mark.parametrize("served", BACK, indirect=True)
def test_a_background_agent_is_never_unread(served):
    me(served)
    reply_now(served, "r-new")
    s = me(served)
    assert s["role"] == "back" and s["unread"] is False and s["unread_count"] == 0


@pytest.mark.parametrize("served", BUSY, indirect=True)
def test_a_busy_front_agent_counts_only_what_has_ended(served):
    me(served)
    reply_now(served, "r-new")                                         # no stop_reason: the text of the turn running now
    s = me(served)
    assert s["status"] == "busy" and s["unread"] is False and s["unread_count"] == 0
    with transcript_file(served).open("a") as f:
        f.write(ended(int(time.time() * 1000) + 120_000, "r-ended"))
    assert me(served)["unread_count"] == 1                             # a turn that ended before the running one began


@pytest.mark.parametrize("served", FRONT, indirect=True)
def test_mark_read_refusals(served):
    url = served["url"]
    assert call(url, "POST", "/api/read", {"name": "example-alpha-nobody"})[0] == 404
    assert call(url, "POST", "/api/read", {"name": 3})[0] == 400
    assert call(url, "POST", "/api/read", {})[0] == 400
    assert call(url, "POST", "/api/read", [1])[0] == 400
    assert call(url, "POST", "/api/read", b"{ no", ctype="application/json")[0] == 400
    assert call(url, "POST", "/api/read", {"name": served["name"]}, ctype="text/plain")[0] == 415
    assert call(url, "POST", "/api/read", {"name": served["name"]}, ctype=None)[0] == 415
    assert call(url, "POST", "/api/read", {"name": "x" * 5000})[0] == 413
    assert call(url, "POST", "/api/read", {"name": served["name"]}, headers={"Origin": "https://evil.example"})[0] == 403
    assert call(url, "POST", "/api/read", {"name": served["name"]}, headers={"Origin": "null"})[0] == 403
    assert call(url, "GET", "/api/read")[0] == 405
    # a page cannot mark a reply it was not shown: a time in the body is not read
    reply_now(served, "r-new")
    call(url, "POST", "/api/read", {"name": served["name"], "read": 1, "ts": 1})
    assert me(served)["unread_count"] == 0
    reply_now(served, "r-newer", ahead_s=300)
    call(url, "POST", "/api/read", {"name": served["name"], "read": 10**15})
    assert me(served)["unread_count"] == 0


# ---------- the page ----------

SESS = """(() => {
  const real = window.fetch.bind(window), json = (o, status) => new Response(JSON.stringify(o), { status: status || 200, headers: { "Content-Type": "application/json" } });
  window.__unread = %(unread)s;     // the server's answer (unread_count), by session name
  window.__reads = [];              // the api/read posts the page made
  const sess = (n, extra) => ({ pid: 1, sessionId: n, name: n, cwd: "/x", status: "idle", tmux: "x:@0.%%0", tmuxSession: n, paneId: "%%0",
                                role: "front", project: "projects/alpha", lane: "subscription-1", updatedAt: null, startedAt: null, unread: !!window.__unread[n], unread_count: window.__unread[n] || 0, ...extra });
  window.fetch = (url, opts) => {
    const u = String(url);
    if (u.startsWith("api/sessions")) {
      const sessions = [sess("example-alpha-main"), sess("example-alpha-quiet"), sess("example-alpha-back", { role: "back" }), sess("example-alpha-busy", { status: "busy" })];
      const groups = [{ key: "projects/alpha", title: "alpha", scope: "example", sessions }];
      return Promise.resolve(json({ scopes: [{ key: "example", title: "example", groups }], groups, rolesError: null }));
    }
    if (u.startsWith("api/read")) {
      const name = JSON.parse(opts.body).name;
      window.__reads.push(name); window.__unread[name] = 0;
      return Promise.resolve(json({ ok: true, name, moved: true }));
    }
    if (u.startsWith("api/board-items")) return Promise.resolve(json({ sessions: {}, fetchedAt: Date.now() }));
    return real(url, opts);
  };
})();"""
UNREAD = {"example-alpha-main": 3, "example-alpha-back": 5, "example-alpha-busy": 12}   # the stub sends a count for the background row too: the page still shows none
CHIPS = "[...document.querySelectorAll('#session-list .sess')].map((r) => ({ name: r.dataset.key, chip: r.querySelector('.ucount') ? r.querySelector('.ucount').textContent : null, label: r.querySelector('.ucount') ? r.querySelector('.ucount').getAttribute('aria-label') : null }))"
HEADCHIPS = "[...document.querySelectorAll('#session-list .group-title, #session-list .scope-title')].map((h) => ({ ckey: h.dataset.ckey, chip: !!h.querySelector('.ucount'), text: h.querySelector('.ucount') ? h.querySelector('.ucount').textContent : null, label: h.querySelector('.ucount') ? h.querySelector('.ucount').getAttribute('aria-label') : null }))"
GEOM = """[...document.querySelectorAll('#session-list .sess, #session-list .group-title, #session-list .scope-title')].map((e) => {
  const r = e.getBoundingClientRect(); return { k: e.dataset.key || e.dataset.ckey, h: r.height, top: r.top }; })"""
SIDE_IN = "document.getElementById('sidebar').getBoundingClientRect().left === 0"


def put_prefs(served, **prefs) -> None:
    assert call(served["url"], "PUT", "/api/prefs", prefs)[0] == 200


def open_page(browser, served, unread=UNREAD, hash_="#new", rows=3) -> None:
    """The page with the stub's four sessions; the background one is listed only with showAll, so the default is three rows."""
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": SESS % {"unread": json.dumps(unread)}})
    browser.width, browser.height = 1280, 800
    browser.send("Emulation.setDeviceMetricsOverride", {"width": 1280, "height": 800, "deviceScaleFactor": 1, "mobile": False})
    browser.send("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-color-scheme", "value": "dark"}]})
    browser.send("Page.navigate", {"url": f"{served['url']}/{hash_}"})
    assert browser.evaluate(WAIT_READY)
    browser.evaluate("document.querySelector('#side-open').click(); ''")
    assert wait_for(browser, SIDE_IN, 5.0)
    assert wait_for(browser, f"document.querySelectorAll('#session-list .sess').length === {rows}", 8.0), browser.evaluate(CHIPS)


def chips(browser) -> dict:
    return {r["name"]: r["chip"] for r in browser.evaluate(CHIPS)}


def test_the_count_is_on_a_front_row_only_at_its_far_right_and_reads_9_plus(sala, served, browser):
    put_prefs(served, showAll=True)                                    # the background row is listed too
    open_page(browser, served, rows=4)
    assert chips(browser) == {"example-alpha-main": "3", "example-alpha-quiet": None, "example-alpha-back": None, "example-alpha-busy": "9+"}, browser.evaluate(CHIPS)
    labels = {r["name"]: r["label"] for r in browser.evaluate(CHIPS)}
    assert labels["example-alpha-main"] == "3 unread replies in example-alpha-main"
    assert labels["example-alpha-busy"] == "More than 9 unread replies in example-alpha-busy"
    # nothing was marked read by looking at the list
    assert browser.evaluate("window.__reads") == []
    # after the label and the ⋯, at the row's far right; the row carries no board count any more
    order = browser.evaluate("[...document.querySelector('#session-list .sess[data-key=\"example-alpha-main\"]').children].map((c) => c.className.split(' ')[0])")
    assert order == ["dot", "label", "sess-more", "ucount"], order
    st = browser.evaluate("""(() => { const c = document.querySelector('.ucount'), cs = getComputedStyle(c), r = c.getBoundingClientRect(), row = c.parentElement.getBoundingClientRect(),
      p = document.createElement('i'); p.style.background = 'var(--accent)'; p.style.color = 'var(--accent-text)'; document.body.append(p);
      const accent = getComputedStyle(p).backgroundColor, accentText = getComputedStyle(p).color; p.remove();
      return { h: r.height, w: r.width, color: cs.color, bg: cs.backgroundColor, accent, accentText, fs: cs.fontSize, fw: cs.fontWeight, radius: cs.borderTopLeftRadius,
               pl: cs.paddingLeft, pr: cs.paddingRight, minw: cs.minWidth, gap: row.right - r.right }; })()""")
    assert st["h"] == 18 and st["w"] >= 20 and st["minw"] == "20px" and st["fs"] == "11px" and st["fw"] == "600", st
    assert st["radius"] == "9px" and st["pl"] == "6px" and st["pr"] == "6px", st
    # the dark theme's shipped small label (the shipped dark look): the one orange on a deep brown fill; the accent is still the page's orange
    assert (st["color"], st["bg"]) == ("rgb(240, 160, 106)", "rgb(58, 38, 25)") and st["color"] == st["accent"], st
    assert st["gap"] < 16, st                                                          # at the right end
    assert browser.evaluate("document.querySelectorAll('#session-list .bmark, #session-list .newchip').length") == 0


def test_the_count_is_filled_in_both_themes(sala, served, browser):
    """The light theme's count is the page's accent filled, --accent-text (white) on it. The dark theme's is the shipped small label: the orange
    (#f0a06a) text on a deep brown fill (#3a2619). Either differs from the sidebar's background."""
    open_page(browser, served)
    probe = "(() => { const c = document.querySelector('.ucount'), cs = getComputedStyle(c); return [cs.color, cs.backgroundColor, getComputedStyle(document.getElementById('sidebar')).backgroundColor]; })()"
    dark = browser.evaluate(probe)
    browser.send("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-color-scheme", "value": "light"}]})
    assert wait_for(browser, f"JSON.stringify({probe}) !== {json.dumps(json.dumps(dark))}", 5.0), dark
    light = browser.evaluate(probe)
    for (color, bg, side), want in ((dark, ("rgb(240, 160, 106)", "rgb(58, 38, 25)")), (light, ("rgb(255, 255, 255)", "rgb(173, 70, 8)"))):
        assert bg != side and (color, bg) == want, (color, bg, side)


def test_the_count_holds_the_ui_component_contrast_in_both_themes(sala, served, browser):
    """The count's text on its fill, measured as the browser computed both, in the dark and the light theme. The count is an 11 px/600
    figure, so it holds AA text contrast (4.5:1): the light theme's accent measures 5.9:1 with white, the dark theme's shipped label (#f0a06a on #3a2619)
    6.8:1. A change that drops either theme under 4.5:1 fails here."""
    open_page(browser, served)
    for theme in ("dark", "light"):
        browser.send("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-color-scheme", "value": theme}]})
        assert wait_for(browser, "document.querySelector('.ucount') !== null", 5.0)
        got = browser.evaluate(CONTRAST + "('.ucount')")
        assert got, theme
        for t in got:
            assert t["fgAlpha"] == 1 and t["bgAlpha"] == 1 and t["ratio"] >= 4.5, (theme, t)


def test_opening_the_row_clears_the_count_and_tells_the_server(sala, served, browser):
    open_page(browser, served)
    assert chips(browser)["example-alpha-main"] == "3"
    b = box(browser, row_sel("example-alpha-main"))
    for t in ("mousePressed", "mouseReleased"):
        browser.send("Input.dispatchMouseEvent", {"type": t, "x": b["x"] - 40, "y": b["y"], "button": "left", "clickCount": 1})
    assert wait_for(browser, "document.querySelector('#session-list .sess.selected') !== null", 8.0)
    assert wait_for(browser, "window.__reads.length === 1", 5.0), browser.evaluate("window.__reads")
    assert browser.evaluate("window.__reads") == ["example-alpha-main"]
    assert wait_for(browser, "document.querySelector('#session-list .sess[data-key=\"example-alpha-main\"] .ucount') === null", 5.0)
    # the next poll (the server now says 0) keeps it clear
    browser.evaluate("loadSessions(); ''")
    time.sleep(0.5)
    assert chips(browser)["example-alpha-main"] is None


def test_a_reply_that_lands_in_the_open_session_never_marks_it(sala, served, browser):
    open_page(browser, served, unread={}, hash_="#s=example-alpha-quiet")
    assert wait_for(browser, "document.querySelector('#session-list .sess.selected') !== null", 8.0)
    # the server says the open session now has an unread reply (it landed while the page was open)
    browser.evaluate("window.__unread['example-alpha-quiet'] = 2; loadSessions(); ''")
    assert wait_for(browser, "window.__reads.includes('example-alpha-quiet')", 5.0), "the page did not mark the open session read"
    assert chips(browser)["example-alpha-quiet"] is None
    # and in between the poll and the post the open row never shows the count
    browser.evaluate("window.__reads = []; window.__unread['example-alpha-quiet'] = 2; Object.assign(state.byName.get('example-alpha-quiet'), { unread: true, unread_count: 2 }); renderSidebar(); ''")
    assert chips(browser)["example-alpha-quiet"] is None


def test_leaving_a_session_reads_what_landed_since_the_last_poll(sala, served, browser):
    """The local count only knows the last poll: a reply that landed after it (server count 2, local count still 0) is
    read on leaving all the same, or the next poll would count a reply the owner has seen."""
    open_page(browser, served, unread={}, hash_="#s=example-alpha-quiet")
    assert wait_for(browser, "document.querySelector('#session-list .sess.selected') !== null", 8.0)
    browser.evaluate("window.__reads = []; ''")   # whatever the page posted on the way in
    browser.evaluate("window.__unread['example-alpha-quiet'] = 2; ''")   # newer replies on the server; no poll has run
    assert browser.evaluate("state.byName.get('example-alpha-quiet').unread_count") == 0
    browser.evaluate("selectSession('example-alpha-main'); ''")
    assert wait_for(browser, "window.__reads.includes('example-alpha-quiet')", 5.0), browser.evaluate("window.__reads")
    assert browser.evaluate("window.__unread['example-alpha-quiet']") == 0          # the server's answer is read now
    browser.evaluate("loadSessions(); ''")
    time.sleep(0.5)
    assert chips(browser)["example-alpha-quiet"] is None


def test_opening_a_session_reads_what_landed_since_the_last_poll(sala, served, browser):
    open_page(browser, served, unread={})
    assert chips(browser)["example-alpha-quiet"] is None
    browser.evaluate("window.__unread['example-alpha-quiet'] = 2; ''")   # landed after the last poll
    browser.evaluate("selectSession('example-alpha-quiet'); ''")
    assert wait_for(browser, "window.__reads.includes('example-alpha-quiet')", 5.0), browser.evaluate("window.__reads")
    assert browser.evaluate("window.__unread['example-alpha-quiet']") == 0
    browser.evaluate("selectSession('example-alpha-main'); ''")
    browser.evaluate("loadSessions(); ''")
    time.sleep(0.5)
    assert chips(browser)["example-alpha-quiet"] is None


def test_a_hidden_page_marks_nothing(sala, served, browser):
    """the owner is not looking: a reply that lands then stays counted until the page is in view."""
    open_page(browser, served, unread={}, hash_="#s=example-alpha-quiet")
    assert wait_for(browser, "document.querySelector('#session-list .sess.selected') !== null", 8.0)
    browser.send("Emulation.setFocusEmulationEnabled", {"enabled": False})
    browser.evaluate("window.__reads = []; ''")   # opening it (page in view) posted once
    browser.evaluate("Object.defineProperty(document, 'hidden', { configurable: true, get: () => true }); window.__unread['example-alpha-quiet'] = 2; loadSessions(); ''")
    time.sleep(1.0)
    assert browser.evaluate("window.__reads") == []
    browser.evaluate("Object.defineProperty(document, 'hidden', { configurable: true, get: () => false }); document.dispatchEvent(new Event('visibilitychange')); ''")
    assert wait_for(browser, "window.__reads.includes('example-alpha-quiet')", 5.0)


def test_a_folded_project_and_its_scope_show_the_total_of_the_sessions_inside(sala, served, browser):
    inside = {"example-alpha-main": 2, "example-alpha-quiet": 3, "example-alpha-back": 4}   # the background agent's 4 is not in the total
    put_prefs(served, collapsed=["projects/alpha"])
    open_page(browser, served, unread=inside, rows=0)
    assert wait_for(browser, "document.querySelector('#session-list .group-title') !== null", 5.0)
    heads = {h["ckey"]: h for h in browser.evaluate(HEADCHIPS)}
    assert heads["projects/alpha"]["text"] == "5" and heads["projects/alpha"]["label"] == "5 unread replies in alpha", heads
    assert heads["scope:example"]["chip"] is False, heads            # the scope is open: its project header says it
    assert browser.evaluate(CHIPS) == []                           # the folded project lists no rows
    # a folded scope shows it too
    put_prefs(served, collapsed=["scope:example"])
    browser.send("Page.reload")
    assert browser.evaluate(WAIT_READY)
    browser.evaluate("document.querySelector('#side-open').click(); ''")
    assert wait_for(browser, "document.querySelector('#session-list .scope-title') !== null", 8.0)
    heads = {h["ckey"]: h for h in browser.evaluate(HEADCHIPS)}
    assert heads["scope:example"]["text"] == "5" and heads["scope:example"]["label"] == "5 unread replies in example", heads


def test_a_header_total_reads_9_plus_above_9(sala, served, browser):
    put_prefs(served, collapsed=["projects/alpha"])
    open_page(browser, served, unread={"example-alpha-main": 6, "example-alpha-quiet": 4}, rows=0)    # 10: past 9
    assert wait_for(browser, "document.querySelector('#session-list .group-title .ucount') !== null", 5.0)
    heads = {h["ckey"]: h for h in browser.evaluate(HEADCHIPS)}
    assert heads["projects/alpha"]["text"] == "9+" and heads["projects/alpha"]["label"] == "More than 9 unread replies in alpha", heads
    browser.evaluate("window.__unread['example-alpha-main'] = 5; window.__unread['example-alpha-quiet'] = 4; loadSessions(); ''")    # 9: exactly
    assert wait_for(browser, "document.querySelector('#session-list .group-title .ucount').textContent === '9'", 5.0)


def test_a_header_with_nothing_unread_has_no_count(sala, served, browser):
    put_prefs(served, collapsed=["projects/alpha"])
    open_page(browser, served, unread={}, rows=0)
    assert wait_for(browser, "document.querySelector('#session-list .group-title') !== null", 5.0)
    assert not any(h["chip"] for h in browser.evaluate(HEADCHIPS))
    put_prefs(served, collapsed=[])
    browser.send("Page.reload")
    assert browser.evaluate(WAIT_READY)


def test_the_folded_header_of_the_open_session_has_no_count_for_it(sala, served, browser):
    """The open session never counts, also when its project is folded around it."""
    put_prefs(served, collapsed=["projects/alpha"])
    open_page(browser, served, unread={"example-alpha-main": 4}, hash_="#s=example-alpha-main", rows=1)
    assert wait_for(browser, "window.__reads.includes('example-alpha-main')", 5.0)
    assert wait_for(browser, "!document.querySelector('#session-list .group-title .ucount')", 5.0), browser.evaluate(HEADCHIPS)


def test_a_count_changes_no_row_or_header_height(sala, served, browser):
    """The same rule as test_sidebar_no_twitch.py: nothing a row or a header can show moves the rows under it."""
    put_prefs(served, showAll=True)
    open_page(browser, served, unread={}, rows=4)
    base = browser.evaluate(GEOM)
    browser.evaluate("window.__unread['example-alpha-main'] = 3; window.__unread['example-alpha-quiet'] = 12; loadSessions(); ''")
    assert wait_for(browser, "document.querySelectorAll('#session-list .ucount').length === 2", 5.0)
    now = browser.evaluate(GEOM)
    assert [(g["k"], g["h"], g["top"]) for g in now] == [(g["k"], g["h"], g["top"]) for g in base]
    # folded with a count: the project header keeps its height too
    browser.evaluate("toggleCollapsed('projects/alpha'); ''")           # the page's own fold (saves the pref, redraws)
    assert wait_for(browser, "document.querySelector('#session-list .group-title .ucount') !== null", 8.0)
    h_with = browser.evaluate("document.querySelector('#session-list .group-title').getBoundingClientRect().height")
    browser.evaluate("document.querySelector('#session-list .group-title .ucount').remove(); ''")
    h_without = browser.evaluate("document.querySelector('#session-list .group-title').getBoundingClientRect().height")
    assert abs(h_with - h_without) < 0.01, (h_with, h_without)


def test_the_sidebar_text_describes_the_count():
    """The text that teaches a mark changes with the mark."""
    import pathlib
    readme = (pathlib.Path(__file__).parent.parent / "README.md").read_text()
    assert "The unread reply count" in readme and "unread_count" in readme and "read-state.json" in readme and "POST /api/read" in readme
    assert "The New chip" not in readme
