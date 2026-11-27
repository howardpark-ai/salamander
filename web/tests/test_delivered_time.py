"""A message Claude read in the middle of a turn shows the time it reached Claude (transcript.as_delivered), without a browser.

The transcript holds such a message as a queued_command attachment stamped when it was sent. The CLI's queue-operation line with operation
"remove", reason "absorbed_mid_turn" and the attachment's delivery_id, written a few lines before it, is stamped when Claude read it. Checked here:
  - every read (the session's page, older, newer and around pages, the live stream, the chat session's page and thread, the turns that are counted)
    gives that message the record's time, with the sending time kept beside it;
  - a page's cursor or the stream's offset that falls between the two lines gives the same time, as does a record a long way back;
  - with no such record before the attachment (none, one after it, another reason or operation, another id, no id on the attachment, one further back
    than the look reaches) the message keeps the time it had;
  - the order of the lines is the file's, and the times along it never go back at such a message;
  - a message sent is matched by the sending time, so an earlier one read later never marks a newer one with the same words delivered, on the
    server and in the page.

What a wrong answer costs: a message shown above a reply it came after, a page and the live stream that disagree, a message marked delivered that
never reached the session. Texts are invented; every temporary folder is removed as the test ends.

The page's part runs in a headless Chromium when one is installed (conftest.py: `served`, `browser`); without one it is skipped."""

from __future__ import annotations

import json
import shutil
from zoneinfo import ZoneInfo

import pytest

from sala_web import chatkeep as CK
from sala_web import chatthread as T
from sala_web import chatturns as CT
from sala_web import outbox as OB
from sala_web import transcript as TR
from test_bang_pending import opened, send_text
from test_chatturns import OWNER, assistant, human, queued, tool_result, ts

SID = "11111111-2222-3333-4444-555555555555"
SENT, READ = 2, 5
TEXT = "also draw the cover"
PEER = "Another Claude session sent a message:\nfrom: demo-other\n\nThe slides are drawn."


@pytest.fixture(autouse=True)
def _rm_tmp(tmp_path):
    yield
    shutil.rmtree(tmp_path, ignore_errors=True)


def taken(delivery_id="d-1", minute=READ, reason="absorbed_mid_turn", operation="remove") -> dict:
    """The CLI's record of what became of a queued message."""
    return {"type": "queue-operation", "operation": operation, "reason": reason, "deliveryId": delivery_id, "commandUuid": "c-1",
            "timestamp": ts(minute), "sessionId": SID}


def mid(text=TEXT, minute=SENT, delivery_id="d-1", origin="human") -> dict:
    d = queued(text, minute, origin)
    d["uuid"] = f"mid-{delivery_id}"
    if delivery_id is not None:
        d["attachment"]["delivery_id"] = delivery_id
    d["attachment"]["source_uuid"] = "c-1"
    return d


def filler(size: int) -> dict:
    """A line of about `size` bytes that shows nothing and starts no turn."""
    return {"type": "attachment", "uuid": "pad", "timestamp": ts(4), "attachment": {"type": "other", "text": "x" * size}}


def scenario(*between) -> list[dict]:
    return [human("Draw slide 4", 1), assistant("On it.", 3, stop="tool_use", tool=True), tool_result(4), taken(), *between, mid(),
            assistant("Both are drawn.", 6)]


def write(path, lines) -> list[int]:
    """Writes the transcript; the byte each line starts at, then the file's end."""
    offs, o = [], 0
    for d in lines:
        offs.append(o)
        o += len(json.dumps(d).encode()) + 1
    path.write_text("".join(json.dumps(d) + "\n" for d in lines), encoding="utf-8")
    return offs + [o]


def the_message(msgs) -> dict:
    found = [m for m in msgs if m["uuid"].startswith("mid-")]
    assert len(found) == 1, [m["uuid"] for m in msgs]
    return found[0]


def delivered(m) -> bool:
    return m["ts"] == ts(READ) and m["sentTs"] == ts(SENT)


def every_read(path, offs, at) -> dict[str, list[dict]]:
    """The messages of each kind of read that holds the line at byte `at`."""
    end = offs[-1]
    return {
        "tail": TR.read_tail_page(path, SID)[0],
        "before": TR.read_before(path, SID, end)[0],
        "after": TR.read_after(path, SID, 0)[0],
        "around": TR.read_around(path, SID, at)["messages"],
        "stream": TR.read_from(path, SID, 0)[0],
        "chat tail": CK.read_tail_page(path, SID, OWNER, 200)[0],
        "chat before": CK.read_before(path, SID, OWNER, end, 200)[0],
        "chat after": CK.read_after(path, SID, OWNER, 0, 200)[0],
        "chat around": CK.read_around(path, SID, OWNER, at, 200)["messages"],
        "chat stream": CK.read_from(path, CK.Keeper(SID, OWNER), 0)[0],
        "thread tail": T.read_tail_page(path, SID, OWNER, 200)[0],
        "thread before": T.read_before(path, SID, OWNER, end, 200)[0],
        "thread after": T.read_after(path, SID, OWNER, 0, 200)[0],
        "thread around": T.read_around(path, SID, OWNER, at, 200)["messages"],
        "thread stream": T.read_from(path, T.Selector(SID, OWNER), 0)[0],
    }


def test_every_read_stamps_the_message_with_when_claude_read_it(tmp_path):
    p = tmp_path / "t.jsonl"
    offs = write(p, scenario())
    for name, msgs in every_read(p, offs, offs[4]).items():
        assert delivered(the_message(msgs)), (name, the_message(msgs))
        stamps = [m["ts"] for m in msgs]
        assert stamps == sorted(stamps), (name, stamps)      # file order, and the message is no longer above what was written before it
        assert all("sentTs" not in m for m in msgs if not m["uuid"].startswith("mid-")), name
    turns, _reached = CT.read_turns(p, CT._ms(ts(30)), ZoneInfo("UTC"))
    (extra,) = [r["extra_user"] for t in turns for r in t.replies if "extra_user" in r]
    assert extra["ts"] == CT._ms(ts(READ))


def test_a_turn_the_message_starts_and_its_kept_line_carry_that_time(tmp_path):
    p = tmp_path / "t.jsonl"
    write(p, [taken(), mid(PEER, origin="peer"), assistant("Noted.", 6)])
    (kept,) = CK.read_tail_page(p, SID, OWNER, 200)[0]
    assert kept["role"] == "kept" and kept["ts"] == ts(READ)
    assert CT.read_turns(p, CT._ms(ts(30)), ZoneInfo("UTC"))[0][0].start_ts == CT._ms(ts(READ))


def test_a_read_that_starts_between_the_two_lines(tmp_path):
    p = tmp_path / "t.jsonl"
    offs = write(p, scenario(filler(10), filler(10)))
    at = len(offs) - 3                # the attachment's line: the record is three lines before it
    for cut in offs[at - 2: at + 1]:  # every line start after the record, up to the attachment's own
        assert delivered(the_message(TR.read_after(p, SID, cut)[0])), cut
        assert delivered(the_message(TR.read_from(p, SID, cut)[0])), cut
    # a page of one message, asked with the cursor just after the attachment, stops at it: the record is before the page's cursor
    msgs, cursor, _start = TR.read_before(p, SID, offs[at + 1], n=1)
    assert cursor == offs[at] and delivered(msgs[0])


@pytest.mark.parametrize("reader", ["page", "chat", "thread"])
def test_the_stream_gives_the_time_when_the_lines_arrive_in_two_reads(tmp_path, reader):
    p = tmp_path / "t.jsonl"
    lines = scenario()
    cut = len(lines) - 2              # the record is written and read, the attachment not yet
    write(p, lines[:cut])
    if reader == "page":
        _msgs, off = TR.read_tail(p, SID)
        again = lambda: TR.read_from(p, SID, off)
    elif reader == "chat":
        _msgs, _cursor, off, keeper = CK.read_tail_page(p, SID, OWNER, 200)
        again = lambda: CK.read_from(p, keeper, off)
    else:
        _msgs, _cursor, off, selector = T.read_tail_page(p, SID, OWNER, 200)
        again = lambda: T.read_from(p, selector, off)
    write(p, lines)
    assert delivered(the_message(again()[0]))


def test_a_record_a_long_way_back_is_found_and_one_past_the_reach_is_not(tmp_path, monkeypatch):
    p = tmp_path / "t.jsonl"
    offs = write(p, scenario(filler(900 << 10)))
    assert delivered(the_message(TR.read_from(p, SID, offs[-3])[0]))
    monkeypatch.setattr(TR, "REMOVE_BACK", 256 << 10)
    m = the_message(TR.read_from(p, SID, offs[-3])[0])
    assert m["ts"] == ts(SENT) and "sentTs" not in m


def test_a_turn_window_that_starts_between_the_two_lines(tmp_path):
    p = tmp_path / "t.jsonl"
    offs = write(p, scenario())
    size, start = offs[-1], offs[4] - 5      # inside the record's line, so the window's first whole line is the attachment
    got = CT._read_window(p, size, size - start)
    assert [d["timestamp"] for d in got if d["type"] == "attachment"] == [ts(READ)]


@pytest.mark.parametrize("lines", [
    pytest.param([mid()], id="no record"),
    pytest.param([mid(), taken()], id="record after the attachment"),
    pytest.param([taken(reason="delivered_to_agent"), mid()], id="delivered to an agent"),
    pytest.param([taken(reason="agent_stopped"), mid()], id="agent stopped"),
    pytest.param([taken(operation="popAll"), mid()], id="another operation"),
    pytest.param([taken("d-2"), mid()], id="another message's record"),
    pytest.param([taken(), mid(delivery_id=None) | {"uuid": "mid-none"}], id="no delivery id on the attachment"),
    pytest.param([{**taken(), "timestamp": None}, mid()], id="record with no time"),
])
def test_without_a_record_before_it_the_message_keeps_its_time(tmp_path, lines):
    p = tmp_path / "t.jsonl"
    offs = write(p, [human("Draw slide 4", 1), *lines])
    for name, msgs in every_read(p, offs, offs[1]).items():
        m = the_message(msgs)
        assert m["ts"] == ts(SENT) and "sentTs" not in m, (name, m)


def test_the_nearest_record_before_the_attachment_counts(tmp_path):
    p = tmp_path / "t.jsonl"
    write(p, [taken(minute=3), taken(), mid(), taken(minute=9)])
    assert delivered(the_message(TR.read_tail(p, SID)[0]))


def test_an_earlier_message_read_later_does_not_mark_a_newer_one_delivered(tmp_path):
    p = tmp_path / "t.jsonl"
    write(p, [taken(), mid()])
    rows = OB.rows_from_messages(TR.read_tail(p, SID)[0])
    assert rows == [(CT._ms(ts(SENT)), TEXT, 0)]
    newer = {"id": "m2", "text": TEXT, "sentAt": CT._ms(ts(SENT + 1))}      # the same words, sent while the first still waited
    assert OB.delivered_ids([newer], rows) == []
    first = {"id": "m1", "text": TEXT, "sentAt": CT._ms(ts(SENT))}
    assert OB.delivered_ids([first, newer], rows) == ["m1"]


def test_the_page_matches_a_pending_bubble_by_the_sending_time(served, browser):
    opened(browser, served)
    send_text(browser, TEXT)

    def arrives(uuid: str, sent: str) -> None:      # a message read just now, sent at `sent` (a JavaScript expression)
        browser.evaluate(f'renderMessage({{ role: "user", uuid: "{uuid}", blocks: [{{ kind: "text", text: {json.dumps(TEXT)} }}], '
                         f'ts: new Date().toISOString(), sentTs: {sent} }}, {{ live: true }})')

    arrives("mid-old", '"2020-01-01T00:00:00.000Z"')
    assert browser.evaluate("state.pending.length") == 1      # an older message with the same words is not this bubble's copy
    arrives("mid-new", "new Date().toISOString()")
    assert browser.evaluate("state.pending.length") == 0
