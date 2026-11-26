"""A background task's notice is drawn nowhere in the chat session's view (chatkeep.py, chatturns.py), without a browser.

A `<task-notification>` line (a subagent or a background command finished) is the one row the owner of the chat session does not need to read. Held here:
  - in a turn the owner started it draws no row (no "notice" block, no text of it), whether it is a user line or a queued_command attachment, while the owner's
    messages, the replies and the tool calls of that turn stay exactly as they were;
  - when it starts a turn of its own there is no kept line for it and the turn is not counted: the count of the switch (chatturns.kept_today with_taken)
    still equals the number of kept lines, for a transcript cut anywhere, with other kinds of hidden turn beside it counted as before;
  - a reply of such a turn that opens with the owner's mark still shows (the mark off), and the owner speaking into the turn makes it his with no line left behind;
  - the stream gives the thread the history gives, cut anywhere;
  - only the chat session's view drops it: the line itself is still classified as delivered (chatturns.classify_user) and the ordinary reader, which every
    other session's view uses (transcript.parse_line), still draws the notice, so nothing is removed from the transcript data.

What a wrong answer costs: a task row the owner told us to hide, a kept line nobody counts or a count of lines that are not there, an empty bubble where the
row was, or the notice gone from the sessions where it is useful. Names are invented; every temporary folder is removed as the test ends."""

from __future__ import annotations

import json
import shutil

import pytest

from sala_web import chatkeep as CK
from sala_web import chatturns as CT
from sala_web import transcript as TR
from test_chatkeep import SID, fold, texts, whole, write
from test_chatturns import OWNER, _id, assistant, human, peer, ts, tool_result


@pytest.fixture(autouse=True)
def _rm_tmp(tmp_path):
    yield
    shutil.rmtree(tmp_path, ignore_errors=True)


def body(summary: str) -> str:
    return ("<task-notification>\n<task-id>b0000demo</task-id>\n<status>completed</status>\n"
            f"<summary>{summary}</summary>\n</task-notification>")


def task(summary: str = 'Agent "Check demo#1" finished', minute: int = 0) -> dict:
    """The notice as a user line (origin task-notification)."""
    return {"type": "user", "uuid": _id(), "timestamp": ts(minute), "origin": {"kind": "task-notification"},
            "message": {"role": "user", "content": body(summary)}}


def task_queued(summary: str = 'Agent "Check demo#1" finished', minute: int = 0) -> dict:
    """The notice that arrived while the session was busy: a queued_command attachment."""
    return {"type": "attachment", "uuid": _id(), "timestamp": ts(minute),
            "attachment": {"type": "queued_command", "commandMode": "task-notification", "prompt": body(summary)}}


def kinds(msgs: list[dict]) -> list[str]:
    return [b["kind"] for m in msgs for b in m.get("blocks", [])]


def scenario() -> list[dict]:
    """The owner's turn with a notice in the middle, a notice that starts a hidden turn, one that starts a turn with a reply for the owner, one the owner
    spoke into, and another session's message (the one hidden turn that is still counted)."""
    return [
        human("Check demo-one", 1),
        assistant("Starting.", 1, stop="tool_use", tool=True), task(minute=2), tool_result(2),
        assistant("Checked.", 3),
        task('Background command "build" completed', 4), assistant("Noted the build.\nNothing for you.", 4),
        task('Agent "Review demo#2" finished', 5), assistant("[for Rowan] The review of demo#2 is done.", 6),
        peer("Another Claude session sent a message:\nfrom: demo-other\n\nSlides drawn.", 7), assistant("Filed.", 7),
        task_queued('Agent "Draw demo#3" finished', 8), assistant("working", 8, stop="tool_use", tool=True),
        human("what is that?", 9), assistant("A drawing task.", 10),
    ]


# ── no row, no count ─────────────────────────────────────────────────────────
@pytest.mark.parametrize("make", [task, task_queued])
def test_a_notice_inside_a_turn_the_owner_started_draws_no_row_and_leaves_the_turn_as_it_was(tmp_path, make):
    lines = [human("Check demo-one", 1), assistant("Starting.", 1, stop="tool_use", tool=True), make(minute=2), tool_result(2), assistant("Checked.", 3)]
    plain = [d for d in lines if d is not lines[2]]
    _, msgs = whole(tmp_path, lines)
    _, bare = whole(tmp_path, plain)
    assert "notice" not in kinds(msgs) and "finished" not in json.dumps(msgs) and "task-notification" not in json.dumps(msgs)
    assert msgs == bare, "the turn is exactly what it is without the notice: no empty bubble, no gap"
    assert [m["role"] for m in msgs] == ["user", "assistant", "user", "assistant"] and texts(msgs[-1]) == "Checked."


@pytest.mark.parametrize("make", [task, task_queued])
def test_the_ordinary_reader_still_draws_the_notice_and_the_line_is_still_delivered(make):
    d = make()
    m = TR.parse_line(d, SID)
    assert m is not None and [b["kind"] for b in m["blocks"]] == ["notice"] and m["blocks"][0]["label"] == 'Agent "Check demo#1" finished'
    e = CT.classify_user(d)
    assert e is not None and e["by"] == "other" and e["src"]["kind"] == "task", "the rule is unchanged: only the chat session's thread leaves it out"


def test_a_notice_that_starts_a_turn_has_no_kept_line_and_is_not_counted(tmp_path):
    lines = [human("hello", 1), assistant("hi", 2), task('Background command "build" completed', 3), assistant("Noted.\nAll fine.", 3)]
    _, msgs = whole(tmp_path, lines)
    assert [m["role"] for m in msgs] == ["user", "assistant"] and CK.KEPT not in [m["role"] for m in msgs]
    turns = CT.build_turns(lines)
    assert CT.kept_today(turns, OWNER, 0, with_taken=True) == 0 and CT.kept_today(turns, OWNER, 0) == 0
    assert "Noted." not in json.dumps(msgs), "the turn's own lines stay back, as every hidden turn's"


def test_a_reply_for_the_owner_in_such_a_turn_still_shows_without_the_mark_and_with_no_line(tmp_path):
    lines = [task('Agent "Review demo#2" finished', 1), assistant("[for Rowan] The review is done.", 2)]
    _, msgs = whole(tmp_path, lines)
    assert [m["role"] for m in msgs] == ["assistant"] and texts(msgs[0]) == "The review is done." and "[for" not in json.dumps(msgs)


def test_the_owner_speaking_into_such_a_turn_makes_it_his_and_leaves_no_line(tmp_path):
    lines = [task_queued(minute=1), assistant("working", 1, stop="tool_use", tool=True), human("what is that?", 2), assistant("A task.", 3)]
    _, msgs = whole(tmp_path, lines)
    assert [m["role"] for m in msgs] == ["user", "assistant"] and texts(msgs[1]) == "A task."
    turns = CT.build_turns(lines)
    assert turns[0].by == "human" and turns[0].taken and turns[0].task
    assert CT.kept_today(turns, OWNER, 0, with_taken=True) == 0, "taken over, it would have been counted as a line: it has none"


def test_other_hidden_turns_keep_their_lines_and_their_count(tmp_path):
    lines = scenario()
    _, msgs = whole(tmp_path, lines)
    kept = [m for m in msgs if m["role"] == CK.KEPT]
    assert [m["kept"]["src"]["kind"] for m in kept] == ["session"], "the one hidden turn that is not a task's"
    assert "notice" not in kinds(msgs) and "finished" not in json.dumps(msgs)
    shown = [texts(m) for m in msgs if m["role"] == "assistant"]
    assert "Checked." in shown and "The review of demo#2 is done." in shown and "A drawing task." in shown
    assert CT.kept_today(CT.build_turns(lines), OWNER, 0, with_taken=True) == len(kept) == 1
    assert CT.kept_today(CT.build_turns(lines), OWNER, 0) == 1


@pytest.mark.parametrize("cut", range(1, 15))
def test_the_count_equals_the_kept_lines_for_a_transcript_cut_anywhere(tmp_path, cut):
    lines = scenario()[:cut]
    _, msgs = whole(tmp_path, lines)
    assert len([m for m in msgs if m["role"] == CK.KEPT]) == CT.kept_today(CT.build_turns(lines), OWNER, 0, with_taken=True)


@pytest.mark.parametrize("cut", range(1, 15))
def test_the_stream_cut_anywhere_gives_the_thread_the_history_gives(tmp_path, cut):
    lines = scenario()
    p = tmp_path / f"{SID}.jsonl"
    _, full = whole(tmp_path, lines)
    write(p, lines[:cut])
    first, _, off, kp = CK.read_tail_page(p, SID, OWNER, 10_000)
    with p.open("a", encoding="utf-8") as f:
        f.write("".join(json.dumps(d) + "\n" for d in lines[cut:]))
    more, end = CK.read_from(p, kp, off)
    assert end == p.stat().st_size
    assert fold(first + more) == full


@pytest.mark.parametrize("n", [1, 2, 3, 5])
def test_older_pages_make_the_whole_thread_with_no_repeat_and_no_task_row(tmp_path, n):
    lines = scenario()
    p = tmp_path / f"{SID}.jsonl"
    _, full = whole(tmp_path, lines)
    msgs, cursor, _end, _kp = CK.read_tail_page(p, SID, OWNER, n)
    got = list(msgs)
    while cursor:
        older, cursor, _ = CK.read_before(p, SID, OWNER, cursor, n)
        got = older + got
    assert fold(got) == full and "notice" not in kinds(got)


def test_the_transcript_file_is_not_touched(tmp_path):
    lines = scenario()
    p = tmp_path / f"{SID}.jsonl"
    write(p, lines)
    before = p.read_bytes()
    CK.read_tail_page(p, SID, OWNER, 10_000)
    assert p.read_bytes() == before and before.count(b"<task-notification>") == 4
