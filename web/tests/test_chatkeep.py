"""The chat session's transcript with the turns its owner did not start kept back (chatkeep.py), without a browser.

The rule that decides who started a turn is chatturns.py's (test_chatturns.py holds it); this file holds what the chat session's reads do with it:
  - a turn the owner started streams WHOLE (tool calls, narration, results), exactly as sala shows any turn; the owner's mark is never drawn;
  - a turn something else started is ONE "kept" message in place of its lines, sent again with the same uuid when its reply lands, and withdrawn
    ({"gone": true}) when its reply opens with the owner's mark (the reply alone shows instead); the owner speaking into it keeps the line and shows the rest;
  - a line the rule does not recognize (an unknown origin) is kept back and counted, never shown and never lost;
  - the count of the switch (chatturns.kept_today with_taken) equals the kept lines;
  - one state machine for every read: a page of history, an older page, a newer page, a page around a Search result and the live stream (a tail read and
    then appends, cut anywhere) all give the same thread; pages hold whole turns whatever the window, and every cursor is a line's start;
  - the HTTP routes: the chat session's transcript and stream carry the kept lines, another session's are as they were.

What a wrong answer costs: a hidden turn's tool calls on the owner's page, a turn he started that loses a line, a line kept back that nobody counts, an older page
that cuts a turn in two or repeats a line, a stream that shows something the history does not. Names are invented; every temporary folder is removed as the test ends."""

from __future__ import annotations

import json
import shutil
import threading
import time
import urllib.error
import urllib.request

import pytest

from conftest import NAME, transcript_file
from sala_web import chatkeep as CK
from sala_web import chatturns as CT
from sala_web import transcript as TR
from test_chatturns import OWNER, assistant, human, peer, queued, tool_result

SID = "11111111-2222-3333-4444-555555555555"


@pytest.fixture(autouse=True)
def _rm_tmp(tmp_path):
    yield
    shutil.rmtree(tmp_path, ignore_errors=True)


def sala_line(text, minute=0):
    d = human("<!-- sala --> " + text, minute)
    return d


def strange(text, minute=0):
    d = human(text, minute)
    d["origin"] = {"kind": "mystery"}
    return d


def scenario() -> list[dict]:
    """One transcript of every kind of turn: the owner's (with tool calls), another session's (with tool calls), the board's with a reply for the owner, a line sala
    typed, a line of an unknown origin, a message delivered into a turn the owner started, and a hidden turn the owner then spoke into."""
    return [
        human("What is due on Friday?", 1),
        assistant("Let me look.", 1, stop="tool_use", tool=True), tool_result(1),
        assistant("The deck is due at noon.", 2),
        peer("Another Claude session sent a message:\nfrom: chat-other\n\nThe slides are drawn.", 3),
        assistant("Checking.", 3, stop="tool_use", tool=True), tool_result(3),
        assistant("Noted.\nNothing for you; I filed it.", 4),
        peer("Another Claude session sent a message:\nfrom: stackshot\n\nItem 7 changed.", 5),
        assistant("[for Rowan] Item 7 needs your answer today.", 6),
        sala_line("wake up", 7),
        assistant("Awake.", 7),
        strange("a line nobody knows", 8),
        assistant("Handled.", 8),
        human("Draw slide 4", 9),
        assistant("On it.", 9, stop="tool_use", tool=True), tool_result(9),
        peer("Another Claude session sent a message:\nfrom: chat-other\n\nBuild green.", 10),
        assistant("[for Rowan] Slide 4 is drawn.", 11),
        peer("Another Claude session sent a message:\nfrom: chat-third\n\nPlease review.", 12),
        human("hold on, what is this?", 13),
        assistant("A review request; I will pass it on.", 14),
    ]


def write(path, lines) -> None:
    path.write_text("".join(json.dumps(d) + "\n" for d in lines), encoding="utf-8")


def fold(messages: list[dict]) -> list[dict]:
    """What the page holds after it has drawn these messages in order: a kept line again replaces the first, a withdrawn one is removed."""
    out: list[dict] = []
    for m in messages:
        if m["role"] != CK.KEPT:
            out.append(m)
        elif m.get("gone"):
            out = [x for x in out if not (x["role"] == CK.KEPT and x["uuid"] == m["uuid"])]
        else:
            for i, x in enumerate(out):
                if x["role"] == CK.KEPT and x["uuid"] == m["uuid"]:
                    out[i] = m
                    break
            else:
                out.append(m)
    return out


def texts(m: dict) -> str:
    return "\n".join(b.get("text", "") for b in m["blocks"] if b.get("kind") == "text")


def whole(tmp_path, lines, **kw):
    p = tmp_path / f"{SID}.jsonl"
    write(p, lines)
    msgs, cursor, end, kp = CK.read_tail_page(p, SID, OWNER, 10_000, **kw)
    assert cursor == 0
    return p, msgs


# ── what shows ───────────────────────────────────────────────────────────────
def test_a_turn_the_owner_started_shows_whole_with_its_tool_calls(tmp_path):
    _, msgs = whole(tmp_path, scenario())
    first = [m for m in msgs if m["role"] != CK.KEPT][:4]
    assert [m["role"] for m in first] == ["user", "assistant", "user", "assistant"]
    assert [b["kind"] for b in first[1]["blocks"]] == ["text", "tool_use"] and first[2]["blocks"][0]["kind"] == "tool_result"
    assert texts(first[0]) == "What is due on Friday?" and texts(first[3]) == "The deck is due at noon."


def test_a_hidden_turn_is_one_kept_line_and_none_of_its_lines_show(tmp_path):
    _, msgs = whole(tmp_path, scenario())
    kept = [m for m in msgs if m["role"] == CK.KEPT]
    other = kept[0]["kept"]
    assert other == {"src": {"kind": "session", "name": "chat-other"}, "what": "The slides are drawn.", "did": "Nothing for you; I filed it.", "open": False}
    everything = json.dumps(msgs)
    assert "Checking." not in everything and "The slides are drawn" in json.dumps(kept[0]), "its tool call and narration never show; its message is the line's `what`"
    assert kept[0]["blocks"] == [] and kept[0]["ts"].startswith("2026-10-14T10:03")


def test_the_five_kinds_of_kept_line_and_the_two_that_do_not_stay(tmp_path):
    _, msgs = whole(tmp_path, scenario())
    kept = [(m["kept"]["src"]["kind"], m["kept"]["src"]["name"], m["kept"]["did"], m["kept"]["open"]) for m in msgs if m["role"] == CK.KEPT]
    assert kept == [("session", "chat-other", "Nothing for you; I filed it.", False),   # another session
                    ("sala", "", "Awake.", False),                                      # a line sala typed (its mark), recorded as the owner's keys
                    ("other", "", "Handled.", False),                                   # an origin the rule does not know: kept back and counted, never shown
                    ("session", "chat-third", "", False)]                               # the owner spoke into it: the line stays, closed
    assert not any("a line nobody knows" in json.dumps(m) for m in msgs if m["role"] != CK.KEPT)


def test_a_hidden_turn_for_the_owner_shows_its_reply_alone_without_the_mark_and_has_no_kept_line(tmp_path):
    _, msgs = whole(tmp_path, scenario())
    shown = [texts(m) for m in msgs if m["role"] == "assistant"]
    assert "Item 7 needs your answer today." in shown and "Slide 4 is drawn." in shown
    assert not any("[for" in t for t in shown) and "[for Rowan]" not in json.dumps(msgs)
    assert not any(m["role"] == CK.KEPT and m["kept"]["what"] in ("Item 7 changed.",) for m in msgs)
    own = next(m for m in msgs if texts(m) == "Item 7 needs your answer today.")
    assert [b["kind"] for b in own["blocks"]] == ["text"]


def test_the_mark_is_never_drawn_in_a_turn_the_owner_started_either(tmp_path):
    lines = [human("Ping me when it is done", 1), assistant("[for Rowan] It is done.", 2),
             human("again", 3), assistant("[for Rowan]", 4)]
    _, msgs = whole(tmp_path, lines)
    assert [texts(m) for m in msgs if m["role"] == "assistant"] == ["It is done.", "[for Rowan]"], "a reply that is only the mark keeps its text: nothing is dropped"


def test_a_message_delivered_into_a_turn_the_owner_started_is_shown_as_sala_shows_it_and_is_not_kept(tmp_path):
    _, msgs = whole(tmp_path, [human("go", 1), assistant("working", 1, stop="tool_use", tool=True),
                               peer("Another Claude session sent a message:\nfrom: chat-other\n\nFYI", 2), tool_result(2), assistant("done", 3)])
    assert not [m for m in msgs if m["role"] == CK.KEPT]
    assert [b["kind"] for m in msgs for b in m["blocks"]].count("notice") == 1


def test_the_owner_speaking_into_a_hidden_turn_makes_it_his_and_the_rest_shows(tmp_path):
    lines = [peer("Another Claude session sent a message:\nfrom: chat-third\n\nPlease review.", 1), assistant("looking", 1, stop="tool_use", tool=True),
             human("what is this?", 2), assistant("a review", 3)]
    _, msgs = whole(tmp_path, lines)
    assert [m["role"] for m in msgs] == ["kept", "user", "assistant"]
    assert msgs[0]["kept"]["open"] is False and "looking" not in json.dumps(msgs)


def test_a_user_line_with_no_origin_is_kept_back_and_the_same_line_typed_is_shown(tmp_path):
    """Claude Code records `origin: {kind: human}` for what the person typed; a line with none is not recognized as his, so it is delivered: kept back and counted, never lost."""
    bare = {"type": "user", "uuid": "bare-1", "timestamp": "2026-10-14T10:00:00.000Z", "message": {"role": "user", "content": "no origin here"}}
    _, msgs = whole(tmp_path, [bare, assistant("ok", 1)])
    assert [m["role"] for m in msgs] == [CK.KEPT] and "no origin here" in msgs[0]["kept"]["what"]
    _, msgs = whole(tmp_path, [human("no origin here", 0), assistant("ok", 1)])
    assert [m["role"] for m in msgs] == ["user", "assistant"]


def test_a_hidden_turn_still_working_is_an_open_line_and_the_reply_lands_on_the_same_line(tmp_path):
    p = tmp_path / f"{SID}.jsonl"
    write(p, [peer("Another Claude session sent a message:\nfrom: chat-other\n\nBuild please.", 1), assistant("starting", 1, stop="tool_use", tool=True)])
    msgs, cursor, off, kp = CK.read_tail_page(p, SID, OWNER, 100)
    assert len(msgs) == 1 and msgs[0]["kept"]["open"] is True and msgs[0]["kept"]["did"] == ""
    with p.open("a", encoding="utf-8") as f:
        f.write(json.dumps(tool_result(2)) + "\n" + json.dumps(assistant("Built.\nAll green.", 3)) + "\n")
    more, off2 = CK.read_from(p, kp, off)
    assert len(more) == 1 and more[0]["uuid"] == msgs[0]["uuid"] and more[0]["kept"]["did"] == "All green." and more[0]["kept"]["open"] is False
    assert fold(msgs + more)[0]["kept"]["did"] == "All green." and len(fold(msgs + more)) == 1
    assert off2 == p.stat().st_size


def test_a_reply_for_the_owner_that_lands_later_withdraws_the_line_and_shows_itself(tmp_path):
    p = tmp_path / f"{SID}.jsonl"
    write(p, [peer("Another Claude session sent a message:\nfrom: stackshot\n\nItem 7 changed.", 1)])
    msgs, _, off, kp = CK.read_tail_page(p, SID, OWNER, 100)
    assert [m["role"] for m in msgs] == ["kept"]
    with p.open("a", encoding="utf-8") as f:
        f.write(json.dumps(assistant("[for Rowan] Item 7 needs you.", 2)) + "\n")
    more, _ = CK.read_from(p, kp, off)
    assert [m["role"] for m in more] == ["assistant", "kept"] and more[1]["gone"] is True and more[1]["uuid"] == msgs[0]["uuid"]
    after = fold(msgs + more)
    assert [m["role"] for m in after] == ["assistant"] and texts(after[0]) == "Item 7 needs you."


def test_a_reply_still_being_written_does_not_close_the_turn_while_the_session_works(tmp_path):
    lines = [human("hello", 1), assistant("half a thought", 2, stop=None),
             peer("Another Claude session sent a message:\nfrom: chat-other\n\nhi", 3)]
    _, working = whole(tmp_path, lines, strict=True)
    assert not [m for m in working if m["role"] == CK.KEPT], "the owner's turn is still open: the message joins it"
    _, idle = whole(tmp_path, lines, strict=False)
    assert [m["role"] for m in idle].count(CK.KEPT) == 1


# ── the count ────────────────────────────────────────────────────────────────
def test_the_count_of_the_switch_is_the_number_of_kept_lines(tmp_path):
    lines = scenario()
    _, msgs = whole(tmp_path, lines)
    kept = [m for m in msgs if m["role"] == CK.KEPT]
    assert len(kept) == 4
    assert CT.kept_today(CT.build_turns(lines), OWNER, 0, with_taken=True) == 4
    assert CT.kept_today(CT.build_turns(lines), OWNER, 0) == 3, "the count without the taken-over turns is as it was: a turn the owner took over is his"


@pytest.mark.parametrize("cut", range(1, 20))
def test_the_count_holds_for_a_transcript_cut_anywhere(tmp_path, cut):
    lines = scenario()[:cut]
    _, msgs = whole(tmp_path, lines)
    assert len([m for m in msgs if m["role"] == CK.KEPT]) == CT.kept_today(CT.build_turns(lines), OWNER, 0, with_taken=True)


# ── every read gives the same thread ─────────────────────────────────────────
@pytest.mark.parametrize("cut", range(1, 20))
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


@pytest.mark.parametrize("n", [1, 2, 3, 5, 8])
@pytest.mark.parametrize("window", [200, 700, 1 << 20])
def test_older_pages_make_the_whole_thread_without_a_repeat_and_never_cut_a_turn(tmp_path, monkeypatch, n, window):
    monkeypatch.setattr(CK, "WINDOW_FIRST", window)
    lines = scenario()
    p, full = whole(tmp_path, lines)
    starts = {0} | {i + 1 for i, c in enumerate(p.read_bytes()) if c == 0x0A}
    page, cursor, _end, _kp = CK.read_tail_page(p, SID, OWNER, n)
    got = [page]
    while cursor:
        assert cursor in starts
        older, cursor, at_start = CK.read_before(p, SID, OWNER, cursor, n)
        assert at_start == (cursor == 0) and older
        got.insert(0, older)
    flat = [m for pg in got for m in pg]
    assert flat == full
    for pg in got:     # a page holds whole turns: its first message starts one (the owner's line, or a kept line), never a reply or a tool call
        assert pg[0]["role"] == CK.KEPT or (pg[0]["role"] == "user" and pg[0]["blocks"][0]["kind"] != "tool_result") or pg[0]["role"] == "assistant" and "[for" not in json.dumps(pg[0])


@pytest.mark.parametrize("n", [1, 3, 6])
def test_newer_pages_make_the_whole_thread_too(tmp_path, n):
    p, full = whole(tmp_path, scenario())
    got, cursor, at_end = [], 0, False
    for _ in range(40):
        pg, cursor, at_end = CK.read_after(p, SID, OWNER, cursor, n)
        got += pg
        if at_end:
            break
    assert at_end and got == full


def test_a_page_around_a_line_holds_the_turn_it_is_in(tmp_path):
    p, full = whole(tmp_path, scenario())
    data = p.read_bytes()
    at = data.index(b'"Checking."')
    at = data.rfind(b"\n", 0, at) + 1                  # the line of the hidden turn's tool call
    d = CK.read_around(p, SID, OWNER, at, 4)
    assert any(m["role"] == CK.KEPT and m["kept"]["src"]["name"] == "chat-other" for m in d["messages"]) and "Checking." not in json.dumps(d["messages"])
    at2 = data.rfind(b"\n", 0, data.index(b'"Let me look."')) + 1
    d2 = CK.read_around(p, SID, OWNER, at2, 4)
    assert [texts(m) for m in d2["messages"] if m["role"] == "user" and m["blocks"][0]["kind"] == "text"][0] == "What is due on Friday?"
    assert d2["start"] is True and fold(d2["messages"])[:4] == full[:4]
    got = fold(d["messages"])
    assert got and got == full[full.index(got[0]):full.index(got[0]) + len(got)], "a page around a line is a stretch of the thread, whole turns"


def test_a_turn_longer_than_a_page_is_never_cut(tmp_path):
    lines = [human("big job", 1)]
    for i in range(30):
        lines += [assistant(f"step {i}", 2, stop="tool_use", tool=True), tool_result(2)]
    lines.append(assistant("all done", 3))
    p = tmp_path / f"{SID}.jsonl"
    write(p, lines)
    page, cursor, _end, _kp = CK.read_tail_page(p, SID, OWNER, 5)
    assert len(page) == 62 and cursor == 0


def test_a_look_back_that_finds_no_closing_reply_still_reads_and_shows_every_line(tmp_path, monkeypatch):
    monkeypatch.setattr(CK, "SYNC_MAX", 64)
    monkeypatch.setattr(CK, "WINDOW_FIRST", 300)
    p, full = whole(tmp_path, scenario())
    page, cursor, _end, _kp = CK.read_tail_page(p, SID, OWNER, 3)
    assert page and (page == full[len(full) - len(page):] or cursor > 0)


def test_lines_that_are_not_messages_and_a_line_still_being_written_are_skipped(tmp_path):
    p = tmp_path / f"{SID}.jsonl"
    p.write_text(json.dumps({"type": "summary", "summary": "x"}) + "\n" + json.dumps(human("hi", 1)) + "\n" + json.dumps(assistant("hello", 2))[:30], encoding="utf-8")
    page, cursor, end, _ = CK.read_tail_page(p, SID, OWNER, 10)
    assert [m["role"] for m in page] == ["user"] and cursor == 0 and end == len(json.dumps({"type": "summary", "summary": "x"}) + "\n" + json.dumps(human("hi", 1)) + "\n")


# ── the HTTP routes ──────────────────────────────────────────────────────────
def get_json(url: str):
    with urllib.request.urlopen(url, timeout=10) as r:
        return json.load(r)


def pid() -> int:
    import os
    return os.getpid()


def test_the_chat_sessions_transcript_keeps_the_hidden_turns_back_and_another_session_is_as_it_was(served, monkeypatch):
    monkeypatch.setenv("SALA_OWNER_NAME", OWNER)
    write(transcript_file(served), scenario())
    monkeypatch.delenv("SALA_CHAT_SESSION", raising=False)
    plain = get_json(f"{served['url']}/api/s/{pid()}/transcript")
    assert not [m for m in plain["messages"] if m["role"] == CK.KEPT] and "Checking." in json.dumps(plain["messages"])
    monkeypatch.setenv("SALA_CHAT_SESSION", NAME)
    d = get_json(f"{served['url']}/api/s/{pid()}/transcript")
    kept = [m for m in d["messages"] if m["role"] == CK.KEPT]
    assert len(kept) == 4 and "Checking." not in json.dumps(d["messages"]) and "[for Rowan]" not in json.dumps(d["messages"])
    assert d["start"] is True and d["before"] == 0 and d["offset"] == transcript_file(served).stat().st_size
    older = get_json(f"{served['url']}/api/s/{pid()}/transcript?before={d['before']}")
    assert older["messages"] == []
    around = get_json(f"{served['url']}/api/s/{pid()}/transcript?around=0&n=6")
    assert around["messages"] and around["start"] is True
    after = get_json(f"{served['url']}/api/s/{pid()}/transcript?after=0&n=1000")
    assert fold(after["messages"]) == d["messages"] and after["end"] is True


def test_the_chat_sessions_transcript_refuses_a_cursor_that_is_not_a_line_start(served, monkeypatch):
    monkeypatch.setenv("SALA_CHAT_SESSION", NAME)
    write(transcript_file(served), scenario())
    for q in ("before=7", "after=7", "around=7", "before=x"):
        with pytest.raises(urllib.error.HTTPError) as e:
            get_json(f"{served['url']}/api/s/{pid()}/transcript?{q}")
        assert e.value.code == 400


def read_events(resp, want: int, out: list, stop: threading.Event) -> None:
    ev = None
    try:
        for raw in resp:
            line = raw.decode().rstrip("\n")
            if line.startswith("event: "):
                ev = line[7:]
            elif line.startswith("data: ") and ev:
                out.append((ev, json.loads(line[6:])))
                ev = None
                if len(out) >= want or stop.is_set():
                    return
    except (OSError, AttributeError, ValueError):
        return      # the test closed the stream under the reader


def test_the_chat_sessions_stream_sends_the_thread_and_then_the_lines_that_come_in(served, monkeypatch):
    monkeypatch.setenv("SALA_CHAT_SESSION", NAME)
    monkeypatch.setenv("SALA_OWNER_NAME", OWNER)
    path = transcript_file(served)
    lines = scenario()
    write(path, lines[:6])
    events: list = []
    stop = threading.Event()
    resp = urllib.request.urlopen(f"{served['url']}/api/s/{pid()}/stream", timeout=20)
    t = threading.Thread(target=read_events, args=(resp, 99, events, stop), daemon=True)
    t.start()
    try:
        def wait(pred, secs=15.0):
            end = time.time() + secs
            while time.time() < end:
                if pred():
                    return True
                time.sleep(0.1)
            return False
        assert wait(lambda: any(e == "reset" for e, _ in events))
        reset = next(d for e, d in events if e == "reset")
        assert [m["role"] for m in reset["messages"]].count(CK.KEPT) == 1 and "Checking." not in json.dumps(reset["messages"])
        with path.open("a", encoding="utf-8") as f:
            f.write("".join(json.dumps(d) + "\n" for d in lines[6:]))
        assert wait(lambda: any(e == "append" for e, _ in events))
        time.sleep(1.5)
        appended = [m for e, d in events if e == "append" for m in d["messages"]]
        both = fold(reset["messages"] + appended)
        _, full = whole_from(path)
        assert both == full and len([m for m in both if m["role"] == CK.KEPT]) == 4
    finally:
        stop.set()
        resp.close()
        t.join(timeout=5)


def whole_from(path):
    msgs, cursor, _end, _kp = CK.read_tail_page(path, SID, OWNER, 10_000)
    return cursor, msgs
