"""The transcript search core (search.py): the time range, each filter box, the cap, results keyed on the agent's permanent id with its
current name, the role fill, and what a query can and cannot reach.

What a wrong answer costs: a match missing because the range or a box was read wrong (the search exists to find the one thing said
yesterday), a result under an old name or split in two by a /clear, a subagent's lines credited to nobody, a transcript changed or a file
outside the projects directory read, or a search that runs so long it holds the server.

The core takes the projects directory, the registry file and the roles as arguments, so every test builds a small tree of fake
transcripts in a temporary folder (locked while the test runs, removed when it ends, pass or fail) and nothing of this machine's own
~/.claude is read.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import shutil
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

import pytest

from sala_web import search as SR

NOW = datetime(2026, 11, 2, 12, 0, 0, tzinfo=timezone.utc).timestamp()
HOUR = 3600

SID_FRONT = "11111111-0000-4000-8000-000000000001"     # R_FRONT's first conversation
SID_FRONT2 = "11111111-0000-4000-8000-000000000002"    # ... and the one after a /clear
SID_BACK = "22222222-0000-4000-8000-000000000001"      # R_BACK: no role in the registry, stackshot knows it
SID_UNK = "33333333-0000-4000-8000-000000000001"      # R_UNK: nobody knows
SID_LOOSE = "44444444-0000-4000-8000-000000000001"     # no registry row at all
R_FRONT, R_BACK, R_UNK = "f0000000-0000-4000-8000-00000000000a", "b0000000-0000-4000-8000-00000000000b", "c0000000-0000-4000-8000-00000000000c"


def iso(epoch: float) -> str:
    return datetime.fromtimestamp(epoch, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def line(kind: str, content, ago_h: float, uuid: str, meta: bool = False) -> str:
    d = {"type": kind, "uuid": uuid, "timestamp": iso(NOW - ago_h * HOUR), "message": {"role": kind, "content": content}}
    if meta:
        d["isMeta"] = True
    return json.dumps(d, ensure_ascii=False) + "\n"


def text(kind: str, s: str, ago_h: float, uuid: str, **kw) -> str:
    return line(kind, [{"type": "text", "text": s}], ago_h, uuid, **kw)


def tool_call(name: str, inp: dict, ago_h: float, uuid: str) -> str:
    return line("assistant", [{"type": "tool_use", "id": "t-" + uuid, "name": name, "input": inp}], ago_h, uuid)


def tool_out(s, ago_h: float, uuid: str) -> str:
    return line("user", [{"type": "tool_result", "tool_use_id": "t", "content": s}], ago_h, uuid)


def thinking(s: str, ago_h: float, uuid: str) -> str:
    return line("assistant", [{"type": "thinking", "thinking": s, "signature": "x"}], ago_h, uuid)


class Tree:
    """A temporary projects directory, registry file and roles, locked while it exists."""

    def __init__(self, root: Path):
        self.root = root
        self.projects = root / "projects"
        self.registry = root / "sessions.json"
        self.proj = self.projects / "-home-alex-work"
        self.proj.mkdir(parents=True)
        self.roles: dict = {}

    def write(self, sid: str, body: str, sub: str | None = None, age_h: float = 0.1) -> Path:
        """A transcript file (a subagent's when `sub` names it), last written `age_h` hours before NOW."""
        d = self.proj if sub is None else self.proj / sid / "subagents"
        d.mkdir(parents=True, exist_ok=True)
        p = d / (f"{sid}.jsonl" if sub is None else f"agent-{sub}.jsonl")
        p.write_text(body, encoding="utf-8")
        t = NOW - age_h * HOUR
        os.utime(p, (t, t))
        return p

    def set_registry(self, rows: list[dict]) -> None:
        self.registry.write_text(json.dumps({"schema": 1, "sessions": {r["id"]: r for r in rows}}), encoding="utf-8")

    def run(self, words, hours: float = 24, **kw):
        extra = {k: kw.pop(k) for k in ("deadline_s", "cap", "clock") if k in kw}
        p = SR.Params(words=SR.parse_words(words) if isinstance(words, str) else words, since=NOW - hours * HOUR, until=NOW, **kw)
        return SR.run(p, self.projects, self.registry, self.roles, now=NOW, **extra)

    def digest(self) -> str:
        h = hashlib.sha256()
        for p in sorted(self.projects.rglob("*")):
            if p.is_file():
                h.update(str(p).encode() + p.read_bytes() + str(p.stat().st_mtime_ns).encode())
        return h.hexdigest()


@pytest.fixture
def tree():
    root = tempfile.mkdtemp(prefix="salaweb-search-")
    fd = os.open(root, os.O_RDONLY)
    fcntl.flock(fd, fcntl.LOCK_EX)    # systemd-tmpfiles ageing honours a lock on the folder
    try:
        t = Tree(Path(root))
        t.set_registry([
            {"id": R_FRONT, "name": "alpha-main", "aliases": ["alpha-old"], "role": "front", "state": "live",
             "transcripts": [{"id": SID_FRONT, "why": "add"}, {"id": SID_FRONT2, "why": "clear"}]},
            {"id": R_BACK, "name": "alpha-builder", "role": None, "state": "live", "transcripts": [{"id": SID_BACK}]},
            {"id": R_UNK, "name": "scratch-x", "role": None, "state": "retired", "transcripts": [{"id": SID_UNK}]},
        ])
        t.roles = {"alpha-builder": {"role": "back", "project": "projects/alpha"}}
        yield t
    finally:
        os.close(fd)
        shutil.rmtree(root, ignore_errors=True)


# ---------- the query ----------

def test_the_query_is_words_and_a_quoted_phrase_is_one_word():
    assert SR.parse_words('  Scroll-On-Clear  "two words" x') == ["scroll-on-clear", "two words", "x"]


@pytest.mark.parametrize("q", ["", "   ", '""', "x" * (SR.MAX_QUERY + 1), " ".join("w%d" % i for i in range(SR.MAX_WORDS + 1))])
def test_a_bad_query_is_refused_with_a_sentence(q):
    with pytest.raises(SR.SearchError) as e:
        SR.parse_words(q)
    assert str(e.value).endswith(".")


def test_a_moment_is_epoch_seconds_or_a_local_date_in_the_pages_zone():
    from zoneinfo import ZoneInfo
    zone = ZoneInfo("Asia/Dubai")
    assert SR.parse_when("1793553104", zone) == 1793553104
    assert SR.parse_when("2026-11-01T09:00", zone) == datetime(2026, 11, 1, 5, 0, tzinfo=timezone.utc).timestamp()
    assert SR.parse_when("2026-11-01T09:00+00:00", zone) == datetime(2026, 11, 1, 9, 0, tzinfo=timezone.utc).timestamp()
    for bad in ("/etc/passwd", "../x", "yesterday", ""):
        with pytest.raises(SR.SearchError):
            SR.parse_when(bad, zone)


# ---------- the time range ----------

def test_only_entries_inside_the_range_match(tree):
    tree.write(SID_FRONT, text("user", "needle one hour ago", 1, "u1") + text("user", "needle two days ago", 48, "u2")
               + text("user", "needle thirty hours ago", 30, "u3"))
    r24 = tree.run("needle")
    assert [x["uuid"] for x in r24["results"]] == ["u1"]
    assert [x["uuid"] for x in tree.run("needle", hours=72)["results"]] == ["u1", "u3", "u2"]     # newest first
    assert [x["uuid"] for x in tree.run("needle", hours=0.5)["results"]] == []
    # explicit dates: from 40 h to 20 h ago
    p = SR.Params(words=["needle"], since=NOW - 40 * HOUR, until=NOW - 20 * HOUR)
    r = SR.run(p, tree.projects, tree.registry, tree.roles, now=NOW)
    assert [x["uuid"] for x in r["results"]] == ["u3"]


def test_a_file_last_written_before_the_range_is_never_opened(tree):
    tree.write(SID_FRONT, text("user", "needle", 1, "u1"), age_h=1)
    old = tree.write(SID_BACK, text("user", "needle", 100, "u9"), age_h=100)
    r = tree.run("needle", hours=24)
    assert [x["uuid"] for x in r["results"]] == ["u1"]
    assert r["files"] == {"scanned": 1, "inRange": 1, "all": 2}
    assert old.exists()


def test_a_big_file_is_entered_at_the_range_and_loses_nothing(tree):
    pad = "x" * 300
    items = [(40 - i * 40 / 6000, f"filler {i} {pad}", f"f{i}") for i in range(6000)]     # 40 h ago .. now, ~2.3 MB, in time order
    items += [(2.0, "needle just inside", "in"), (1.0, "needle at the edge", "edge")]
    body = "".join(text("user", t, ago, u) for ago, t, u in sorted(items, key=lambda x: -x[0]))
    p = tree.write(SID_FRONT, body, age_h=0)
    assert p.stat().st_size > SR.BISECT_MIN
    with open(p, "rb") as f:
        off = SR.start_offset(f, p.stat().st_size, SR._iso_prefix(NOW - 3 * HOUR))
    assert off > p.stat().st_size // 2                    # the head was skipped
    assert [x["uuid"] for x in tree.run("needle", hours=3)["results"]] == ["edge", "in"]
    assert len(tree.run("filler", hours=40.1, cap=10000)["results"]) == 6000   # a range covering the file reads all of it
    # the bisect never lands after a line that is in the range
    for hrs in (1, 5, 13, 24, 39):
        got = {x["uuid"] for x in tree.run("filler", hours=hrs, cap=10000)["results"]}
        want = {f"f{i}" for i in range(6000) if SR._epoch(iso(NOW - (40 - i * 40 / 6000) * HOUR)) >= NOW - hrs * HOUR}
        assert got == want, hrs


# ---------- the boxes ----------

def feed(tree):
    tree.write(SID_FRONT, text("user", "needle in a message", 1, "m") + tool_call("Bash", {"command": "echo needle", "description": "x"}, 1, "c")
               + tool_out("needle in output", 1, "o") + thinking("needle in thought", 1, "t") + thinking("   ", 1, "t0"))
    tree.write(SID_BACK, text("assistant", "needle from the builder", 1, "b"))
    tree.write(SID_UNK, text("user", "needle from nobody", 1, "n"))
    tree.write(SID_FRONT, text("assistant", "needle from a subagent", 1, "s"), sub="aa11")


def uuids(r):
    return sorted(x["uuid"] for x in r["results"])


def test_the_default_boxes_are_messages_and_tool_calls_on_output_and_thinking_off(tree):
    feed(tree)
    assert uuids(tree.run("needle")) == ["b", "c", "m", "n", "s"]


@pytest.mark.parametrize("content,want", [({"messages"}, ["b", "m", "n", "s"]), ({"tools"}, ["c"]), ({"output"}, ["o"]), ({"thinking"}, ["t"]),
                                          ({"messages", "tools", "output", "thinking"}, ["b", "c", "m", "n", "o", "s", "t"]), (set(), [])])
def test_each_content_box(tree, content, want):
    feed(tree)
    assert uuids(tree.run("needle", content=content)) == want


@pytest.mark.parametrize("agents,want", [({"front"}, ["c", "m"]), ({"back"}, ["b"]), ({"sub"}, ["s"]), ({"unknown"}, ["n"]),
                                         ({"front", "back"}, ["b", "c", "m"]), (set(), [])])
def test_each_agent_box(tree, agents, want):
    feed(tree)
    assert uuids(tree.run("needle", agents=agents)) == want


def test_the_content_kinds_and_labels(tree):
    feed(tree)
    r = {x["uuid"]: x for x in tree.run("needle", content={"messages", "tools", "output", "thinking"})["results"]}
    assert (r["m"]["kind"], r["c"]["kind"], r["c"]["tool"], r["o"]["kind"], r["t"]["kind"]) == ("messages", "tools", "Bash", "output", "thinking")
    assert "".join(t for t, _ in r["c"]["snippet"]) == 'command: "echo needle", description: "x"'


def test_a_tool_call_is_searched_as_its_input_and_labelled_by_its_tool(tree):
    tree.write(SID_FRONT, tool_call("mcp__stackshot__update", {"summary": "The bare prompts come from scroll-on-clear", "done": [1]}, 1, "c"))
    r = tree.run("scroll-on-clear")["results"][0]
    assert r["tool"] == "stackshot update"
    assert tree.run('summary "bare prompts"')["results"][0]["uuid"] == "c"       # `key: "value"`, a string as it is, never JSON-escaped


def test_notices_are_left_out(tree):
    tree.write(SID_FRONT, text("user", "<system-reminder>needle in a reminder</system-reminder>", 1, "r")
               + text("user", "<local-command-stdout>needle from a command</local-command-stdout>", 1, "l")
               + text("user", "needle in a hook note", 1, "h", meta=True)
               + line("user", "plain needle prompt", 1, "p")
               + line("user", "<system-reminder>x</system-reminder>needle after a reminder", 1, "q")
               + json.dumps({"type": "attachment", "uuid": "a", "timestamp": iso(NOW - HOUR), "attachment": {"text": "needle"}}) + "\n"
               + json.dumps({"type": "summary", "summary": "needle"}) + "\n")
    assert uuids(tree.run("needle")) == ["p", "q"]


def test_the_counts_are_what_each_box_adds_given_the_other_group(tree):
    feed(tree)
    r = tree.run("needle")      # defaults: output and thinking off
    assert r["counts"]["content"] == {"messages": 4, "tools": 1, "output": 1, "thinking": 1}        # all agents are on
    assert r["counts"]["agents"] == {"front": 2, "back": 1, "sub": 1, "unknown": 1}                 # messages and tool calls only
    r = tree.run("needle", agents={"front"}, content={"messages"})
    assert r["matches"] == 1 and uuids(r) == ["m"]
    assert r["counts"]["content"] == {"messages": 1, "tools": 1, "output": 1, "thinking": 1}        # front only
    assert r["counts"]["agents"] == {"front": 1, "back": 1, "sub": 1, "unknown": 1}                 # messages only


# ---------- the words ----------

def test_every_word_must_be_in_the_same_entry_case_insensitively(tree):
    tree.write(SID_FRONT, text("user", "Scroll On Clear here", 1, "a") + text("user", "scroll only", 1, "b") + text("user", "clear only", 1, "c")
               + text("user", "Ünïcode ÉCLAIR ok", 1, "d") + text("user", "naïve re-entrant (x) [y] .* $ ^", 1, "e"))
    assert uuids(tree.run("scroll CLEAR")) == ["a"]
    assert uuids(tree.run('"on clear"')) == ["a"]
    assert uuids(tree.run("éclair ünïcode")) == ["d"]         # a non-ASCII word is matched on the parsed text, not the raw line
    assert uuids(tree.run(".* $ ^ (x) [y]")) == ["e"]         # no regular expression: these are letters
    assert uuids(tree.run("nonexistent-word")) == []


def test_a_word_json_escapes_is_still_found(tree):
    tree.write(SID_FRONT, text("user", 'she said "hi\\there" and left\nnew line', 1, "q"))
    assert uuids(tree.run('"hi\\there"')) == ["q"]
    assert uuids(tree.run('"left new"')) == []         # the phrase is "left new" with a space; the entry has a newline there
    assert uuids(tree.run("left line")) == ["q"]       # two words, both in the entry


def test_a_snippet_marks_the_words_and_shortens_long_text(tree):
    tree.write(SID_FRONT, text("user", "a " * 300 + "NEEDLE and Haystack " + "b " * 300 + "\n\n   tail", 1, "m")
               + text("user", "😀😀 needle 😀", 1, "e"))
    r = {x["uuid"]: x for x in tree.run("needle haystack")["results"]}
    parts = r["m"]["snippet"]
    flat = "".join(t for t, _ in parts)
    assert flat.startswith("…") and flat.endswith("…") and len(flat) < SR.SNIPPET_BEFORE + SR.SNIPPET_AFTER + 10
    assert [t for t, hit in parts if hit] == ["NEEDLE", "Haystack"]
    e = tree.run("needle")["results"]
    assert [p for x in e if x["uuid"] == "e" for p in x["snippet"]] == [["😀😀 ", 0], ["needle", 1], [" 😀", 0]]


# ---------- the agents ----------

def test_results_are_keyed_on_the_permanent_id_and_shown_by_the_current_name(tree):
    tree.write(SID_FRONT, text("user", "needle before the clear", 3, "u1"))
    tree.write(SID_FRONT2, text("user", "needle after the clear", 2, "u2"))
    tree.write(SID_FRONT2, text("assistant", "needle in its subagent", 1.5, "u3"), sub="bb22")
    r = tree.run("needle")["results"]
    assert {x["agent"] for x in r} == {R_FRONT}                         # one agent across a /clear, and its subagent
    assert {x["name"] for x in r} == {"alpha-main"}                      # the current name, not the alias "alpha-old"
    assert [(x["uuid"], x["sub"]) for x in r] == [("u3", True), ("u2", False), ("u1", False)]
    assert {x["session"] for x in r} == {SID_FRONT, SID_FRONT2}          # a subagent's session is its agent's


def test_a_rename_changes_the_name_not_the_key(tree):
    tree.write(SID_FRONT, text("user", "needle", 1, "u"))
    before = tree.run("needle")["results"][0]
    rows = json.loads(tree.registry.read_text())["sessions"]
    rows[R_FRONT]["name"], rows[R_FRONT]["aliases"] = "beta-main", ["alpha-main", "alpha-old"]
    tree.registry.write_text(json.dumps({"sessions": rows}))
    after = tree.run("needle")["results"][0]
    assert (before["agent"], before["name"]) == (R_FRONT, "alpha-main") and (after["agent"], after["name"]) == (R_FRONT, "beta-main")


def test_the_role_comes_from_the_registry_then_stackshot_then_unknown(tree):
    feed(tree)
    r = {x["uuid"]: x for x in tree.run("needle")["results"]}
    assert (r["m"]["role"], r["m"]["sub"]) == ("front", False)           # the registry row says front
    assert r["b"]["role"] == "back"                                      # the row has none; stackshot's agents map says back
    assert r["n"]["role"] == "unknown"                                   # nobody knows: its own bucket, not dropped
    assert (r["s"]["role"], r["s"]["sub"]) == ("front", True)            # a subagent shows its agent's role
    # a keeper counts as background; a name the agent had before is looked up too
    tree.roles = {"alpha-builder": {"role": "keeper"}, "old-scratch": {"role": "front"}}
    got = {x["uuid"]: x["role"] for x in tree.run("needle")["results"]}
    assert (got["b"], got["n"]) == ("back", "unknown")
    rows = json.loads(tree.registry.read_text())["sessions"]
    rows[R_UNK].update(name="renamed", aliases=["old-scratch"])
    tree.registry.write_text(json.dumps({"sessions": rows}))
    assert {x["uuid"]: x["role"] for x in tree.run("needle")["results"]}["n"] == "front"
    # a role the registry itself holds wins over stackshot
    rows[R_FRONT]["role"] = "back"
    tree.registry.write_text(json.dumps({"sessions": rows}))
    tree.roles = {"alpha-main": {"role": "front"}}
    assert {x["uuid"]: x["role"] for x in tree.run("needle")["results"]}["m"] == "back"


def test_a_transcript_with_no_row_is_its_own_agent(tree):
    tree.write(SID_LOOSE, text("user", "needle headless", 1, "h"))
    r = tree.run("needle")["results"][0]
    assert (r["agent"], r["name"], r["role"]) == ("session:" + SID_LOOSE, "session 44444444", "unknown")


def test_a_missing_or_corrupt_registry_is_survived(tree):
    tree.write(SID_FRONT, text("user", "needle", 1, "u"))
    tree.registry.write_text("{not json")
    assert tree.run("needle")["results"][0]["agent"] == "session:" + SID_FRONT
    tree.registry.unlink()
    assert tree.run("needle")["shown"] == 1
    tree.registry.write_text(json.dumps({"sessions": ["x"]}))
    assert tree.run("needle")["shown"] == 1


# ---------- the cap, the clock, the files ----------

def test_the_cap_keeps_the_newest_and_says_so(tree):
    tree.write(SID_FRONT, "".join(text("user", f"needle {i}", 10 - i, f"u{i}") for i in range(8)))
    r = tree.run("needle", cap=3)
    assert [x["uuid"] for x in r["results"]] == ["u7", "u6", "u5"]
    assert (r["matches"], r["shown"], r["cap"], r["capped"]) == (8, 3, 3, True)
    r = tree.run("needle", cap=8)
    assert (r["matches"], r["shown"], r["capped"]) == (8, 8, False)
    assert SR.CAP == 200


def test_a_search_past_its_deadline_stops_and_says_so(tree):
    tree.write(SID_FRONT, text("user", "needle", 1, "u"))
    r = tree.run("needle", deadline_s=0)
    assert r["timedOut"] is True and r["results"] == [] and r["files"]["scanned"] == 0
    assert tree.run("needle")["timedOut"] is False


def test_the_deadline_is_checked_inside_a_big_file_too(tree, monkeypatch):
    tree.write(SID_FRONT, "".join(text("user", f"needle {i}", 1, f"u{i}") for i in range(2000)))
    monkeypatch.setattr(SR, "CHECK_EVERY", 1)
    ticks = iter(range(100_000))
    r = tree.run("needle", deadline_s=1.0, cap=5000, clock=lambda: next(ticks) / 100)       # each look at the clock is 10 ms later
    assert r["timedOut"] is True and 0 < r["matches"] < 2000


def test_only_real_transcripts_under_the_projects_directory_are_read(tree):
    tree.write(SID_FRONT, text("user", "needle real", 1, "real"))
    outside = tree.root / "outside.jsonl"
    outside.write_text(text("user", "needle outside", 1, "out"))
    os.symlink(outside, tree.proj / "55555555-0000-4000-8000-000000000001.jsonl")        # a symlinked file
    os.symlink(tree.root, tree.proj / "66666666-0000-4000-8000-000000000001")            # a symlinked folder
    (tree.proj / "notes.jsonl").write_text(text("user", "needle not a session id", 1, "nid"))
    (tree.proj / SID_FRONT).mkdir(exist_ok=True)
    (tree.proj / SID_FRONT / "tool-results").mkdir()
    (tree.proj / SID_FRONT / "tool-results" / "77777777-0000-4000-8000-000000000001.jsonl").write_text(text("user", "needle result", 1, "tr"))
    (tree.projects / "88888888-0000-4000-8000-000000000001.jsonl").write_text(text("user", "needle straight in", 1, "top"))
    (tree.proj / "plain.txt").write_text("needle")
    assert uuids(tree.run("needle")) == ["real"]


def test_a_search_changes_nothing_on_disk(tree):
    feed(tree)
    before = tree.digest()
    tree.run("needle", content={"messages", "tools", "output", "thinking"})
    tree.run("zzz")
    assert tree.digest() == before
    assert not list(tree.root.glob("*.tmp"))


def test_a_time_is_given_in_the_pages_zone(tree):
    tree.write(SID_FRONT, text("user", "needle", 1, "u"))
    r = tree.run("needle")["results"][0]
    assert r["when"] == "today 15:00" and r["at"] == "Mon Nov 2nd 15:00 +04"       # 11:00 UTC; the tests run in Asia/Dubai (conftest)
    assert r["ts"] == int((NOW - HOUR) * 1000)
    out = tree.run("needle")
    assert out["toText"] == "Mon Nov 2nd 16:00 +04" and out["fromText"] == "Sun Nov 1st 16:00 +04"


# ---------- where a result opens ----------

def line_at(p: Path, pos: int) -> dict:
    """The transcript line that starts at byte `pos` (which must be a line's start)."""
    data = p.read_bytes()
    assert pos == 0 or data[pos - 1:pos] == b"\n"
    return json.loads(data[pos:data.index(b"\n", pos)])


def test_a_result_carries_its_lines_byte_offset_and_uuid(tree):
    p = tree.write(SID_FRONT, text("user", "first — non-ascii ✓ before", 3, "a") + text("assistant", "needle one", 2, "b")
                   + text("user", "plain", 1.5, "c") + text("assistant", "needle two", 1, "d"))
    r = tree.run("needle")
    for h in r["results"]:
        assert h["target"] == h["uuid"] and line_at(p, h["pos"])["uuid"] == h["uuid"]
    assert [h["uuid"] for h in r["results"]] == ["d", "b"]


def test_a_big_file_entered_by_the_bisect_still_gives_true_offsets(tree):
    pad = "x" * 300
    body = "".join(text("user", f"filler {i} {pad}" + (" needle" if i % 500 == 7 else ""), 40 - i * 40 / 6000, f"f{i}") for i in range(6000))
    p = tree.write(SID_FRONT, body, age_h=0)
    assert p.stat().st_size > SR.BISECT_MIN
    r = tree.run("needle", hours=10, cap=10000)
    assert r["results"]
    for h in r["results"]:
        assert line_at(p, h["pos"])["uuid"] == h["uuid"]


def agent_call(tuid: str, ago_h: float, uuid: str, name: str = "Agent") -> str:
    return line("assistant", [{"type": "text", "text": "starting a helper"},
                              {"type": "tool_use", "id": tuid, "name": name, "input": {"description": "look around", "prompt": "go"}}], ago_h, uuid)


def agent_result(tuid: str, agent_id: str, ago_h: float, uuid: str) -> str:
    d = json.loads(line("user", [{"type": "tool_result", "tool_use_id": tuid, "content": [{"type": "text", "text": "done"}]}], ago_h, uuid))
    d["toolUseResult"] = {"status": "completed", "agentId": agent_id, "content": [{"type": "text", "text": "done"}]}
    return json.dumps(d) + "\n"


def progress(tuid: str, agent_id: str, ago_h: float) -> str:
    return json.dumps({"type": "progress", "timestamp": iso(NOW - ago_h * HOUR), "parentToolUseID": tuid, "toolUseID": "x",
                       "data": {"type": "agent_progress", "agentId": agent_id}}) + "\n"


def sub_line(agent_id: str, s: str, ago_h: float, uuid: str) -> str:
    d = json.loads(text("assistant", s, ago_h, uuid))
    d.update(isSidechain=True, agentId=agent_id, sessionId=SID_FRONT)
    return json.dumps(d) + "\n"


def test_a_subagents_result_opens_the_parent_chat_at_the_call_that_started_it(tree):
    parent = tree.write(SID_FRONT, text("user", "please look", 3, "p0") + agent_call("toolu_A", 2.9, "call-a")
                        + agent_call("toolu_B", 2.8, "call-b", name="Task")
                        + agent_result("toolu_B", "bbb222", 2.0, "res-b") + agent_result("toolu_A", "aaa111", 1.9, "res-a"))
    tree.write(SID_FRONT, sub_line("aaa111", "needle from helper a", 2.5, "sa1"), sub="aaa111")
    tree.write(SID_FRONT, sub_line("bbb222", "needle from helper b", 2.4, "sb1"), sub="bbb222")
    r = tree.run("needle")
    by = {h["uuid"]: h for h in r["results"]}
    assert set(by) == {"sa1", "sb1"} and all(h["sub"] for h in by.values())
    assert by["sa1"]["target"] == "call-a" and line_at(parent, by["sa1"]["pos"])["uuid"] == "call-a"
    assert by["sb1"]["target"] == "call-b" and line_at(parent, by["sb1"]["pos"])["uuid"] == "call-b"
    assert not any(k.startswith("_") for h in r["results"] for k in h)     # nothing private leaks into the answer


def test_a_running_subagent_is_found_through_its_progress_line(tree):
    parent = tree.write(SID_FRONT, agent_call("toolu_C", 2, "call-c") + progress("toolu_C", "ccc333", 1.9))
    tree.write(SID_FRONT, sub_line("ccc333", "needle while running", 1.8, "sc1"), sub="ccc333")
    h = tree.run("needle")["results"][0]
    assert h["target"] == "call-c" and line_at(parent, h["pos"])["uuid"] == "call-c"


def test_a_subagent_whose_call_is_not_found_has_no_place(tree):
    tree.write(SID_FRONT, text("user", "no agent call here", 3, "p0"))
    tree.write(SID_FRONT, sub_line("ddd444", "needle orphan", 1, "sd1"), sub="ddd444")
    tree.write(SID_BACK, sub_line("eee555", "needle with no parent file", 1, "se1"), sub="eee555")
    hs = tree.run("needle")["results"]
    assert {h["uuid"] for h in hs} == {"sd1", "se1"}
    assert all(h["pos"] is None and h["target"] == "" for h in hs)


def test_spawn_points_reads_the_link_from_the_parents_lines():
    root = Path(tempfile.mkdtemp(prefix="salaweb-spawn-"))
    try:
        p = root / "s.jsonl"
        body = agent_call("toolu_X", 2, "call-x") + agent_result("toolu_X", "xx1", 1, "res-x") + agent_call("toolu_Y", 1, "call-y")
        p.write_text(body)
        got = SR.spawn_points(str(p), {"xx1", "nope"})
        assert set(got) == {"xx1"} and got["xx1"][1] == "call-x" and line_at(p, got["xx1"][0])["uuid"] == "call-x"
        assert SR.spawn_points(str(root / "missing.jsonl"), {"xx1"}) == {}
        assert SR.subagent_id("/a/b/subagents/agent-abc_1.jsonl") == "abc_1"
        assert SR.subagent_id("/a/b/subagents/other.jsonl", "q9") == "q9" and SR.subagent_id("/x/other.jsonl", "../x") is None
        assert SR.parent_transcript("/p/proj/sid/subagents/agent-a.jsonl") == "/p/proj/sid.jsonl"
    finally:
        shutil.rmtree(root, ignore_errors=True)


# ---------- lines the chat never shows ----------

SUMMARY = ("This session is being continued from a previous conversation that ran out of context. The summary below covers the "
           "earlier part of the conversation: the quokka plan.")


def compaction(ago_h: float, uuid: str) -> str:
    """What a /compact writes: a boundary system line, then the summary as a user line flagged isCompactSummary."""
    boundary = json.dumps({"type": "system", "subtype": "compact_boundary", "uuid": uuid + "-b", "timestamp": iso(NOW - ago_h * HOUR),
                           "content": "Conversation compacted", "compactMetadata": {"trigger": "manual", "preTokens": 150000}}) + "\n"
    d = json.loads(text("user", SUMMARY, ago_h, uuid))
    d["isCompactSummary"] = True
    return boundary + json.dumps(d) + "\n"


def test_a_compaction_summary_is_not_a_result_and_the_message_after_it_still_opens_at_itself(tree):
    from sala_web import transcript as TR
    p = tree.write(SID_FRONT, text("user", "start the quokka plan", 5, "u0") + text("assistant", "ok", 4.9, "a0")
                   + compaction(3, "sum") + text("user", "quokka again after the compaction", 2, "u1") + text("assistant", "done", 1.9, "a1"))
    r = tree.run("quokka")
    by = {h["uuid"]: h for h in r["results"]}
    assert set(by) == {"u0", "u1"}                       # the summary mentions quokka and is not offered
    pos = by["u1"]["pos"]
    assert line_at(p, pos)["uuid"] == "u1"
    page = TR.read_around(p, SID_FRONT, pos, n=10)
    assert "u1" in [m["uuid"] for m in page["messages"]]         # the chat opens at it and shows it
    assert "sum" not in [m["uuid"] for m in page["messages"]]    # the summary is why the chat could not light it


def test_search_and_the_chat_skip_the_same_lines():
    import inspect
    from sala_web import transcript as TR
    base = json.loads(text("assistant", "needle", 1, "x"))
    for flag, shown_in_a_subagent in (("isCompactSummary", False), ("isVisibleInTranscriptOnly", False), ("isSidechain", True)):
        d = dict(base, **{flag: True})
        assert TR.parse_line(d, SID_FRONT) is None and list(SR.entries(d)) == [], flag
        assert bool(list(SR.entries(d, subagent=True))) is shown_in_a_subagent, flag
    assert TR.parse_line(base, SID_FRONT) is not None and [k for k, _t, _x in SR.entries(base)] == ["messages"]
    # one function holds the rule: search names no flag of its own, so the two cannot drift
    src = inspect.getsource(SR)
    assert "never_shown" in src and not any(f in src for f in ("isCompactSummary", "isVisibleInTranscriptOnly", "isSidechain"))
