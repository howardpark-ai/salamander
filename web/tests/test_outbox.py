"""The outbox's store and its reading of the transcript (outbox.py), on made-up data: no tmux, no browser, no network.

What a wrong answer costs: a message that is lost (dropped from the list before the session has it), sent twice (a "lost" verdict without
evidence, a restart that sends what was half typed again), taken back after it is in the pane (the owner thinks it was cancelled), or shown
in a state it is not in (the page says delivered for a message the session never read). Held here:

- the list is one file a session, written whole and renamed into place, the folder mode 700 and the file 600, no temporary file left
  behind, an odd session name never a path, a corrupt file set aside and not a crash;
- a message left `typing` by a stopped server is `failed` with its text kept (it may or may not have gone in), never sent again;
- only the oldest held message is tried, and the page is told the others wait behind it;
- cancel works on held and failed messages and answers "too late" (nothing changed) for typing, queued and delivered ones;
- the transcript's user lines, queued_command attachments and a joined line ("T1 T2") mark the right messages delivered, in order, never
  one that was typed after the line and never one the line does not show, and an older one no line matches does not stop the newer ones;
- a typed message is accounted for only by an enqueue line of its own, and the input box's text is read as the messages it holds and what
  is left over;
- a message is "lost" only with an enqueue line that carries exactly it, no line after that took it, in the CLI's first-in-first-out order;
- for a take-back, the CLI's queue is read from those lines, only sala's own messages are matched in it, and the lines written after the
  Up say which came back, which the session took first and which nothing speaks of; no line is read twice or missed between the two looks;
- the cleared-text log (what sala emptied out of a pane's input line before it typed a message) is one JSON line a record, mode 600, with the
  text as it was (a multi-line draft whole, Korean as itself), and past its size keeps the newest whole lines, not a cut one.
"""

from __future__ import annotations

import json
import stat

import pytest

from sala_web import outbox as OB


@pytest.fixture
def box(tmp_path):
    t = {"now": 1_000_000}
    b = OB.Outbox(tmp_path / "outbox", clock=lambda: t["now"])
    b.t = t
    return b


def test_a_message_is_a_held_entry_at_the_end_of_the_list(box):
    a, created = box.add("s1", "first", [])
    b, _ = box.add("s1", "second", ["u.png"])
    assert created and a["state"] == OB.HELD and a["id"] != b["id"]
    assert [e["text"] for e in box.entries("s1")] == ["first", "second"] and box.entries("s1")[1]["uploads"] == ["u.png"]
    assert box.entries("other") == []


def test_the_page_asking_twice_with_one_cid_is_one_message(box):
    a, c1 = box.add("s1", "same", [], cid="abc-123")
    b, c2 = box.add("s1", "same", [], cid="abc-123")
    assert c1 and not c2 and a["id"] == b["id"] and len(box.entries("s1")) == 1


def test_the_file_is_private_whole_and_alone(box, tmp_path):
    word = "h" + chr(0xE9) + "llo " + chr(0xC548) + chr(0xB155)       # an accent and two Hangul syllables, built so that the file holds no literal one
    box.add("demo-session", word, [])
    root = tmp_path / "outbox"
    assert stat.S_IMODE(root.stat().st_mode) == 0o700
    files = sorted(p.name for p in root.iterdir())
    assert files == ["demo-session.json"]                                    # no temporary file stays
    assert stat.S_IMODE((root / files[0]).stat().st_mode) == 0o600
    d = json.loads((root / files[0]).read_text(encoding="utf-8"))
    assert d["name"] == "demo-session" and d["messages"][0]["text"] == word        # written as itself, not as escapes


def test_an_odd_session_name_is_never_a_path(box, tmp_path):
    for name in ("../../etc/x", "a/b", ".hidden", "-rf", "has space", "x.json", "a" * 300):
        box.add(name, "t", [])
    inside = {p.name for p in (tmp_path / "outbox").iterdir()}
    assert len(inside) == 7 and all("/" not in n and not n.startswith(".") for n in inside), inside
    assert list(tmp_path.iterdir()) == [tmp_path / "outbox"]                  # nothing outside the folder
    assert OB.file_key("a b") != OB.file_key("a_b")                          # two names never share a file


def test_a_new_process_reads_what_the_last_one_wrote(box, tmp_path):
    box.add("s1", "kept", [])
    again = OB.Outbox(tmp_path / "outbox")
    assert [e["text"] for e in again.entries("s1")] == ["kept"]
    assert again.names_with_work() == ["s1"]


def test_a_message_left_typing_is_failed_with_its_text_never_resent(box, tmp_path):
    e, _ = box.add("s1", "half typed", [])
    box.update("s1", e["id"], state=OB.TYPING)
    again = OB.Outbox(tmp_path / "outbox")
    (got,) = again.entries("s1")
    assert got["state"] == OB.FAILED and got["text"] == "half typed" and "restarted" in got["error"]
    assert again.head("s1") is None and again.names_with_work() == []         # nothing to send
    scanned = OB.Outbox(tmp_path / "outbox")
    assert scanned.names_with_work() == [] and scanned.entries("s1")[0]["state"] == OB.FAILED   # the scan at start settles it too


def test_a_corrupt_file_is_an_empty_list_not_a_crash(box, tmp_path):
    (tmp_path / "outbox").mkdir(mode=0o700)
    (tmp_path / "outbox" / "s1.json").write_text("{not json")
    again = OB.Outbox(tmp_path / "outbox")
    assert again.entries("s1") == [] and again.names_with_work() == []
    again.add("s1", "new", [])
    assert [e["text"] for e in again.entries("s1")] == ["new"]


def test_only_the_oldest_held_message_is_the_head_and_the_page_is_told_the_rest_wait(box):
    a, _ = box.add("s1", "one", [])
    b, _ = box.add("s1", "two", [])
    assert box.head("s1")["id"] == a["id"]
    view = OB.public(box.entries("s1"))
    assert [m["reason"] for m in view] == [None, "ahead"]
    box.update("s1", a["id"], state=OB.TYPING)
    assert box.head("s1") is None                                              # nothing is tried while one is being typed
    box.update("s1", a["id"], state=OB.QUEUED)
    assert box.head("s1")["id"] == b["id"]


def test_cancel_takes_back_a_held_or_failed_message_and_only_those(box):
    ids = {}
    for state in (OB.HELD, OB.FAILED, OB.TYPING, OB.QUEUED, OB.DELIVERED):
        e, _ = box.add("s1", state, [])
        box.update("s1", e["id"], state=state)
        ids[state] = e["id"]
    assert box.withdraw("s1", ids[OB.HELD])["state"] == OB.WITHDRAWN
    assert box.withdraw("s1", ids[OB.HELD])["state"] == OB.WITHDRAWN            # asked again: as it is
    assert box.withdraw("s1", ids[OB.FAILED])["state"] == OB.WITHDRAWN
    for state in (OB.TYPING, OB.QUEUED, OB.DELIVERED):
        with pytest.raises(OB.TooLate) as late:
            box.withdraw("s1", ids[state])
        assert late.value.entry["state"] == state and box.get("s1", ids[state])["state"] == state
    with pytest.raises(OB.NotFound):
        box.withdraw("s1", "nope")


def test_old_ends_leave_the_file_but_nothing_that_is_still_work(box):
    a, _ = box.add("s1", "gone soon", [])
    box.withdraw("s1", a["id"])
    q, _ = box.add("s1", "in the pane", [])
    box.update("s1", q["id"], state=OB.QUEUED)
    box.t["now"] += OB.RETAIN_S * 1000 + 1
    b, _ = box.add("s1", "new", [])                                           # any write tidies
    assert [e["id"] for e in box.entries("s1")] == [q["id"], b["id"]]          # the withdrawn one is gone, the queued one stays however old


def test_an_update_that_changes_nothing_is_not_a_new_version(box):
    a, _ = box.add("s1", "t", [])
    box.update("s1", a["id"], reason="dialog")
    v = box.version("s1")
    box.update("s1", a["id"], reason="dialog")
    assert box.version("s1") == v                                              # an open stream is not told again for nothing
    box.update("s1", a["id"], reason="draft")
    assert box.version("s1") == v + 1


# ── the transcript ────────────────────────────────────────────────────────────────────────────────────────────
def entry(i, text, sent, uploads=()):
    return {"id": f"m{i}", "text": text, "sentAt": sent, "uploads": list(uploads), "state": OB.QUEUED}


def row(t, text, images=0):
    return (t, OB.norm_text(text), images)


def test_a_line_that_has_the_message_marks_it_delivered(box):
    got = OB.delivered_ids([entry(1, "hello  there\n", 1000)], [row(1500, "hello there")])
    assert got == ["m1"]


def test_a_line_from_before_the_message_does_not_(box):
    assert OB.delivered_ids([entry(1, "again", 100_000)], [row(50_000, "again")]) == []
    assert OB.delivered_ids([entry(1, "again", 100_000)], [row(100_000 - OB.SLACK_MS + 1, "again")]) == ["m1"]


def test_messages_the_cli_joined_into_one_line_are_each_delivered_in_order(box):
    queued = [entry(1, "T1", 1000), entry(2, "T2", 1100), entry(3, "T3", 1200)]
    assert OB.delivered_ids(queued, [row(2000, "T1\nT2")]) == ["m1", "m2"]     # T3 has its own line, later
    assert OB.delivered_ids(queued, [row(2000, "T1\nT2"), row(2100, "T3")]) == ["m1", "m2", "m3"]


def test_a_message_the_lines_do_not_show_stays_queued(box):
    queued = [entry(1, "first", 1000), entry(2, "second", 1100)]
    assert OB.delivered_ids(queued, [row(2000, "something else")]) == []
    assert OB.delivered_ids(queued, []) == []


def test_an_older_message_no_line_matches_does_not_stop_the_newer_ones(box):
    queued = [entry(1, "lost", 1000), entry(2, "second", 1100), entry(3, "third", 1200)]
    assert OB.delivered_ids(queued, [row(2000, "second")]) == ["m2"]
    assert OB.delivered_ids(queued, [row(2000, "second\nthird")]) == ["m2", "m3"]
    assert OB.delivered_ids(queued, [row(2000, "second"), row(2100, "lost")]) == ["m2", "m1"]
    # past the unmatched one, only whole words at the start of a line count: not its end, not the start of a longer word
    assert OB.delivered_ids(queued, [row(2000, "not the second"), row(2100, "secondly")]) == []


def test_a_typed_message_is_accounted_for_by_one_enqueue_line_of_its_own(box):
    def line(op, ts, text):
        return {"op": op, "ts": ts, "text": text, "raw": text}

    a, again = entry(1, "go on", 10_000), entry(2, "go on", 11_000)
    assert OB.unaccounted([a, again], []) == [a, again]
    assert OB.unaccounted([again, a], [line("enqueue", 12_000, "go on")]) == [again]               # one line, the older one's
    assert OB.unaccounted([a], [line("enqueue", 10_000 - OB.SLACK_MS - 1, "go on")]) == [a]        # written before it was typed
    assert OB.unaccounted([a], [line("popAll", 12_000, "go on")]) == [a]                           # only an enqueue line speaks
    # typed again after an Up pulled it: the line written before that Up is the earlier typing's
    retyped = entry(1, "go on", 20_000)
    before = [line("enqueue", 18_000, "go on"), line("popAll", 19_000, "go on")]
    assert OB.unaccounted([retyped], before) == [retyped]
    assert OB.unaccounted([retyped], [*before, line("enqueue", 21_000, "go on")]) == []
    up = entry(3, "see", 10_000, ["x.png"])
    assert OB.unaccounted([up], [line("enqueue", 11_000, "/srv/state/uploads/x.png see")]) == []   # the path comes first
    assert OB.unaccounted([entry(4, "! ls", 10_000)], [line("enqueue", 11_000, "ls")]) == []


def test_the_input_box_is_read_as_the_messages_it_holds_and_what_is_left_over():
    assert OB.box_parts("A\nB\nC", ["A", "B"]) == ([True, True], ["C"])
    assert OB.box_parts("A\nB\nC", ["C", "A", "B"]) == ([True, True, True], [])
    assert OB.box_parts("typed here\nA", ["A", "B"]) == ([True, False], ["typed here"])
    assert OB.box_parts("one two th\nree\nB", ["one two three", "B"]) == ([True, True], [])        # wrapped at the pane's width
    assert OB.box_parts("go\ngo", ["go"]) == ([True], ["go"])                                      # each part counts once
    assert OB.box_parts("let us go", ["go"]) == ([False], ["let us go"])                           # a message stands on lines of its own
    assert OB.box_parts("line one\n\n  line two", ["line one\n\n  line two"]) == ([True], [])
    assert OB.box_parts("", ["A"]) == ([False], [])


def chip(n, breaks):
    return f"[Pasted text #{n} +{breaks} lines]"


def test_folded_pastes_count_as_read_only_when_each_pairs_with_a_message_the_up_named():
    six, other_six, long = "a\nb\nc\nd\ne\nf", "g\nh\ni\nj\nk\nl", "\n".join("x" * 41)
    paired = OB.chips_paired
    assert paired(chip(1, 5), [six])
    assert paired(f"{chip(1, 5)}\n{chip(2, 40)}", [six, long])
    assert paired(f"{chip(7, 40)}\n{chip(8, 5)}", [six, long])                                   # by count, not by place
    assert paired(f"{chip(1, 5)}\n{chip(2, 5)}", [six, other_six])
    assert paired(f"one\n{chip(1, 5)}\ntwo\nshort\n  second line", ["one", six, "two", "short\n  second line"])
    assert paired(f"{six}\n{chip(1, 5)}", [six, other_six])                                       # one drawn open, one folded
    assert paired(chip(1, 6), [six + "\n"]) and paired(chip(1, 7), ["\n" + six + "\n"])            # breaks at the ends count too
    assert not paired(chip(1, 5), [])                                                            # a chip nothing names
    assert not paired(f"{chip(1, 5)}\n{chip(2, 5)}", [six])                                       # one chip more than messages
    assert not paired(chip(1, 5), [six, other_six])                                              # a message with no place in the box
    assert not paired(chip(1, 5), [six, "one"])
    assert not paired(chip(1, 6), [six])                                                         # the count differs
    assert not paired(chip(1, 5), [six + "\n"])
    assert not paired(f"{chip(1, 5)}\n{chip(2, 5)}", [six, long])
    assert not paired(f"typed here\n{chip(1, 5)}", [six])                                         # other text
    assert paired(f"{chip(1, 5)}\none\ntwo", [six, "one two"])                                    # as the pane's width wraps it
    assert not paired(f"one\n{chip(1, 5)}\ntwo", ["one two", six])                                # no message is found across a chip
    assert not paired(f"{chip(1, 5)} typed after it", [six])                                      # a chip is a line of its own
    assert not paired(f"typed before it {chip(1, 5)}", [six])
    assert not paired("[Pasted text #1]", ["y" * 900])                                            # no line count: nothing to pair by
    assert not paired("[...Truncated text #1 +5 lines]", [six])
    assert not paired(f"{chip(1, 5)}\n[Pasted text #2]", [six, "y" * 900])
    assert not paired("one", ["one"])                                                             # no chip at all: not this function's case
    assert not paired("", [])


def test_a_file_s_path_before_the_text_and_an_image_chip_do_not_hide_the_message(box):
    f = entry(1, "look at this", 1000, ["abc/clip.mp4"])
    assert OB.delivered_ids([f], [row(2000, "/srv/state/uploads/abc/clip.mp4 look at this")]) == ["m1"]
    img = entry(2, "see", 1000, ["x.png"])
    assert OB.delivered_ids([img], [row(2000, "[Image #1] see", 1)]) == ["m2"]
    only = entry(3, "", 1000, ["x.png"])
    assert OB.delivered_ids([only], [row(2000, "", 1)]) == ["m3"]


def test_the_pasted_content_wrapper_is_taken_off_both_sides(box):
    wrapped = '<pasted_content id="3"> line one\nline two</pasted_content>'
    assert OB.norm_text(wrapped) == "line one line two"
    assert OB.delivered_ids([entry(1, "line one\nline two", 1000)], [row(2000, wrapped)]) == ["m1"]


def test_rows_come_from_user_lines_and_queued_commands_only(box):
    msgs = [
        {"role": "assistant", "ts": "2026-11-26T01:00:00Z", "blocks": [{"kind": "text", "text": "hello"}]},
        {"role": "user", "ts": "2026-11-26T01:00:01Z", "blocks": [{"kind": "text", "text": "hello"}]},
        {"role": "user", "ts": "2026-11-26T01:00:02Z", "blocks": [{"kind": "notice", "text": "task done"}]},
        {"role": "user", "ts": "not a time", "blocks": [{"kind": "text", "text": "x"}]},
        {"role": "user", "ts": "2026-11-26T01:00:03Z", "blocks": [{"kind": "image"}]},
    ]
    rows = OB.rows_from_messages(msgs)
    assert [(r[1], r[2]) for r in rows] == [("hello", 0), ("", 1)]


def write_lines(path, lines):
    path.write_text("".join(json.dumps(x) + "\n" for x in lines), encoding="utf-8")


def op(operation, ts, content=None):
    d = {"type": "queue-operation", "operation": operation, "timestamp": ts, "sessionId": "s"}
    if content is not None:
        d["content"] = content
    return d


def test_the_queue_lines_at_the_end_of_a_transcript_are_read(tmp_path):
    p = tmp_path / "t.jsonl"
    write_lines(p, [{"type": "user", "timestamp": "2026-11-26T01:00:00Z"}, op("enqueue", "2026-11-26T01:00:01Z", "Q1  alpha"),
                    op("dequeue", "2026-11-26T01:00:09Z"), op("enqueue", "2026-11-26T00:00:00Z", "older")])
    since = OB.ts_ms("2026-11-26T01:00:00Z")
    got = OB.read_ops(p, since)
    assert [(o["op"], o["text"]) for o in got] == [("enqueue", "Q1 alpha"), ("dequeue", None)]
    assert OB.read_ops(tmp_path / "missing.jsonl", 0) == []
    big = tmp_path / "big.jsonl"
    big.write_text("x" * 5000 + "\n" + json.dumps(op("enqueue", "2026-11-26T01:00:01Z", "late")) + "\n")
    assert [o["text"] for o in OB.read_ops(big, 0, max_bytes=400)] == ["late"]    # a part of a line at the cut is skipped


def test_a_message_is_lost_only_with_an_enqueue_line_nothing_took(box):
    t0 = OB.ts_ms("2026-11-26T01:00:00Z")
    q = [entry(1, "Z1", t0)]
    assert OB.lost_ids(q, [{"op": "enqueue", "ts": t0 + 5, "text": "Z1"}]) == ["m1"]              # probe m: only the enqueue line
    assert OB.lost_ids(q, []) == []                                                              # no line at all: not evidence
    assert OB.lost_ids(q, [{"op": "enqueue", "ts": t0 + 5, "text": "other"}]) == []             # another message's line
    assert OB.lost_ids(q, [{"op": "enqueue", "ts": t0 + 5, "text": None}]) == []                # no content (a compaction): not evidence
    assert OB.lost_ids(q, [{"op": "enqueue", "ts": t0 + 5, "text": "Z1"}, {"op": "dequeue", "ts": t0 + 9, "text": None}]) == []   # taken
    assert OB.lost_ids(q, [{"op": "enqueue", "ts": t0 + 5, "text": "Z1"}, {"op": "remove", "ts": t0 + 9, "text": "Z1"}]) == []
    assert OB.lost_ids(q, [{"op": "enqueue", "ts": t0 - 10 * OB.SLACK_MS, "text": "Z1"}]) == []  # a line from before the message was sent


def test_the_queue_is_first_in_first_out_so_one_taken_line_is_the_first_messages(box):
    t0 = OB.ts_ms("2026-11-26T01:00:00Z")
    q = [entry(1, "A", t0), entry(2, "B", t0 + 10)]
    ops = [{"op": "enqueue", "ts": t0 + 1, "text": "A"}, {"op": "enqueue", "ts": t0 + 11, "text": "B"}, {"op": "dequeue", "ts": t0 + 50, "text": None}]
    assert OB.lost_ids(q, ops) == ["m2"]                                                         # A was taken, B was not
    assert OB.lost_ids(q, ops[:2]) == ["m1", "m2"]
    same = [entry(1, "ok", t0), entry(2, "ok", t0 + 10)]
    two = [{"op": "enqueue", "ts": t0 + 1, "text": "ok"}, {"op": "enqueue", "ts": t0 + 11, "text": "ok"}, {"op": "dequeue", "ts": t0 + 50, "text": None}]
    assert OB.lost_ids(same, two) == ["m2"]                                                      # equal messages take one line each


def test_the_cleared_text_log_keeps_what_was_cleared_whole_in_a_private_file(tmp_path):
    log = OB.ClearedLog(tmp_path / "state" / OB.CLEARED_FILE, clock=lambda: 42)
    text = "line one\nline two \u00e9\u4e2d\n"
    log.append("me", text)
    log.append("other", "x")
    assert log.read() == [{"t": 42, "session": "me", "text": text}, {"t": 42, "session": "other", "text": "x"}]
    assert stat.S_IMODE((tmp_path / "state" / OB.CLEARED_FILE).stat().st_mode) == 0o600
    assert OB.ClearedLog(tmp_path / "nothing.jsonl").read() == []                          # no file: an empty list


def test_the_cleared_text_log_past_its_size_keeps_the_newest_whole_lines(tmp_path, monkeypatch):
    monkeypatch.setattr(OB, "CLEARED_MAX", 2000)
    log = OB.ClearedLog(tmp_path / OB.CLEARED_FILE, clock=lambda: 1)
    for i in range(60):
        log.append("me", f"draft number {i} " + "x" * 40)
    rows = log.read()
    assert rows and rows[-1]["text"].startswith("draft number 59 ")                         # the newest is there
    assert rows[0]["text"].startswith("draft number ") and len(rows) < 60                  # the oldest went, and no line is cut in two
    raw = (tmp_path / OB.CLEARED_FILE).read_text(encoding="utf-8")
    assert len(raw.encode("utf-8")) <= 2000 and all(ln.startswith("{") and ln.endswith("}") for ln in raw.splitlines())
    assert [p.name for p in tmp_path.iterdir()] == [OB.CLEARED_FILE]                       # no temporary file left behind


def _op(op, text=None, ts=10, raw=None):
    return {"op": op, "ts": ts, "text": text, "raw": raw}


def test_the_queue_is_the_enqueued_texts_less_the_named_ones_and_a_bare_dequeue_takes_the_oldest_message():
    enq = lambda t: _op("enqueue", t)
    assert OB.queue_items([enq("A"), enq("B")]) == ["A", "B"]
    assert OB.queue_items([enq("A"), enq("B"), _op("popAll", "A"), _op("popAll", "B")]) == []
    assert OB.queue_items([enq("A"), enq("B"), enq("C"), _op("remove", "B")]) == ["A", "C"]
    assert OB.queue_items([enq("A"), _op("remove", "from before the look")]) == ["A"]
    note = "<task-notification><task-id>x</task-id></task-notification>"
    assert OB.queue_items([enq(note), enq("A"), enq("B"), _op("dequeue")]) == [note, "B"]
    assert OB.queue_items([enq(note), _op("dequeue")]) == []
    assert OB.queue_items([enq("A"), enq(None)]) == ["A", None]                       # a textless enqueue matches no message
    assert OB.queue_items([]) == []


def test_the_newest_queued_item_takes_the_newest_message_with_its_words_and_the_rest_is_foreign():
    queued = [{"id": "old", "text": "ok"}, {"id": "b", "text": "two\nlines"}, {"id": "new", "text": "ok"}]
    note = "<task-notification>n</task-notification>"
    wanted, foreign = OB.match_queue([note, OB.norm_text("two\nlines"), "ok"], queued)
    assert [i for i, _t in wanted] == ["b", "new"] and foreign == []
    wanted, foreign = OB.match_queue(["ok", "who typed this", None], queued)
    assert [i for i, _t in wanted] == ["new"] and foreign == ["who typed this", None]


def test_a_popall_line_names_a_message_only_when_stamped_after_it_was_sent_one_line_each():
    queued = [{"id": "a", "text": "ok", "sentAt": 100}, {"id": "b", "text": "ok", "sentAt": 100}, {"id": "c", "text": "late", "sentAt": 100}]
    ops = [_op("popAll", "ok", ts=150), _op("popAll", "late", ts=50), _op("remove", "late", ts=150)]
    assert OB.popped_ids(queued, ops) == ["a"]
    assert OB.popped_ids(queued, ops + [_op("popAll", "ok", ts=160)]) == ["a", "b"]


def test_the_lines_after_the_up_say_what_came_back_what_the_session_took_and_what_nothing_speaks_of():
    wanted = [("a", "A"), ("b", "B"), ("c", "C"), ("d", "D")]
    ops = [_op("remove", "A"), _op("popAll", "C"), _op("popAll", "X", raw="X\n  as typed"), _op("dequeue")]
    assert OB.settle_take_back(wanted, ops) == (["c"], ["a", "b"], ["d"], ["X\n  as typed"])
    assert OB.settle_take_back(wanted, []) == ([], [], ["a", "b", "c", "d"], [])
    assert OB.settle_take_back([], [_op("popAll", "<system-reminder>x")]) == ([], [], [], [])


def test_a_look_at_the_queue_and_the_read_after_it_see_every_line_once_even_a_half_written_one(tmp_path):
    f = tmp_path / "t.jsonl"
    line = lambda t: json.dumps({"type": "queue-operation", "operation": "enqueue", "timestamp": "2026-11-27T00:00:00.000Z", "content": t})
    half = line("second")
    f.write_text(line("first") + "\n" + half[:30], encoding="utf-8")
    mark, ops = OB.snapshot_ops(f, 0, 1 << 20)
    assert [o["text"] for o in ops] == ["first"]
    with f.open("a", encoding="utf-8") as out:
        out.write(half[30:] + "\n" + line('<pasted_content id="ab12">\nthird\n  indented\n</pasted_content id="ab12">') + "\n")
    later = OB.read_ops(f, 0, start=mark)
    assert [o["text"] for o in later] == ["second", OB.norm_text("third indented")] and later[1]["raw"] == "third\n  indented"
    assert OB.snapshot_ops(tmp_path / "none", 0, 100) == (0, [])
