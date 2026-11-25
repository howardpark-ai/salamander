"""The chat page's turns (chatturns.py): who started a turn, what shows, what is kept back.

The rule was established from real transcripts (the module's docstring has it and the shapes below are the ones those transcripts hold); the
fixtures here are small, made-up lines of exactly those shapes. Names and texts are invented (`chat-test`, `chat-other`, "Rowan").

What is held:
  - typed (origin.kind human; a queued_command attachment with origin human; a slash command typed in the pane) starts the owner's turn;
  - delivered (peer, task-notification, plugin, the meta lines with no origin, an sdk prompt, an unknown kind) starts a hidden turn;
  - tool results, sidechain lines and compaction stubs are no turn at all;
  - only the FINAL reply of a turn shows: narration before a tool call (stop_reason tool_use) never does;
  - a hidden turn shows only when its final reply opens with the owner's mark, `[for Rowan]`, and then without the mark;
  - every other hidden turn is one kept line (never nothing), with the source in plain words and the reply's last line, footer notes aside.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

from sala_web import chatturns as CT

OWNER = "Rowan"
_n = [0]


def ts(minute: int, hour: int = 10, day: int = 14) -> str:
    return f"2026-10-{day:02d}T{hour:02d}:{minute:02d}:00.000Z"


def _id() -> str:
    _n[0] += 1
    return f"u-{_n[0]}"


def human(text, minute=0, **kw):
    d = {"type": "user", "uuid": _id(), "timestamp": ts(minute), "origin": {"kind": "human"}, "promptSource": "typed",
         "message": {"role": "user", "content": text}}
    d.update(kw)
    return d


def queued(text, minute=0, origin="human"):
    return {"type": "attachment", "uuid": _id(), "timestamp": ts(minute),
            "attachment": {"type": "queued_command", "prompt": text, "origin": {"kind": origin}, "commandMode": "prompt"}}


def peer(text, minute=0, **kw):
    d = {"type": "user", "uuid": _id(), "timestamp": ts(minute), "isMeta": True, "origin": {"kind": "peer"},
         "message": {"role": "user", "content": [{"type": "text", "text": text}]}}
    d.update(kw)
    return d


def assistant(text, minute=0, stop="end_turn", tool=False):
    content = [{"type": "text", "text": text}]
    if tool:
        content.append({"type": "tool_use", "id": "t1", "name": "Bash", "input": {}})
    return {"type": "assistant", "uuid": _id(), "timestamp": ts(minute),
            "message": {"role": "assistant", "model": "claude-opus-5-5", "stop_reason": stop, "content": content}}


def tool_result(minute=0):
    return {"type": "user", "uuid": _id(), "timestamp": ts(minute), "toolUseResult": {"stdout": "ok"},
            "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": "ok"}]}}


def entries(lines, owner=OWNER, strict=False):
    return CT.entries(CT.build_turns(lines, strict), owner)


def kinds(es):
    return [e["k"] for e in es]


# ---------- what the owner typed, and the final reply ----------

def test_a_typed_message_and_the_final_reply_show_and_the_tool_calls_do_not():
    es = entries([human("What is due on Friday?", 1),
                  assistant("Let me look.", 1, stop="tool_use", tool=True), tool_result(1),
                  assistant("Checking the notes too.", 2, stop="tool_use", tool=True), tool_result(2),
                  assistant("The deck is due at noon.", 3)])
    assert kinds(es) == ["me", "reply"]
    assert es[0]["text"] == "What is due on Friday?" and es[1]["text"] == "The deck is due at noon."


def test_a_reply_that_is_still_being_written_does_not_show_while_the_session_works():
    lines = [human("Hello", 1), assistant("Half a thought", 2, stop=None)]
    assert kinds(entries(lines, strict=True)) == ["me"]
    assert kinds(entries(lines, strict=False)) == ["me", "reply"]


def test_a_message_typed_while_the_session_works_joins_the_turn_and_one_reply_follows():
    es = entries([human("Start the redraw", 1), assistant("On it.", 1, stop="tool_use", tool=True), tool_result(1),
                  queued("and use headline B", 2), assistant("Redrawn with headline B.", 3)])
    assert kinds(es) == ["me", "me", "reply"]
    assert es[1]["text"] == "and use headline B"


def test_a_message_after_a_final_reply_starts_a_new_turn():
    es = entries([human("one", 1), assistant("first", 2), human("two", 3), assistant("second", 4)])
    assert kinds(es) == ["me", "reply", "me", "reply"]


def test_a_slash_command_typed_in_the_pane_is_the_owners_and_its_output_is_not_a_turn():
    cmd = {"type": "user", "uuid": _id(), "timestamp": ts(1), "message": {"role": "user", "content": "<command-name>/model</command-name>\n<command-args>opus</command-args>"}}
    out = {"type": "user", "uuid": _id(), "timestamp": ts(1), "message": {"role": "user", "content": "<local-command-stdout>Set model</local-command-stdout>"}}
    es = entries([cmd, out])
    assert kinds(es) == ["me"] and es[0]["text"] == "/model opus"


def test_images_pasted_with_a_message_are_counted_not_shown():
    d = human("see this", 1)
    d["message"]["content"] = [{"type": "text", "text": "see this"}, {"type": "image", "source": {}}]
    es = entries([d, assistant("Seen.", 2)])
    assert es[0]["images"] == 1 and es[0]["text"] == "see this"


# ---------- what something else started ----------

def test_a_turn_another_session_started_is_one_kept_line_with_its_source_and_the_replys_last_line():
    es = entries([peer("Another Claude session sent a message:\nfrom: chat-other\n\nThe slides are drawn, please check them.", 5),
                  assistant("Noted.\nNothing for you; I filed it on the item.", 6)])
    assert kinds(es) == ["kept"]
    k = es[0]
    assert k["src"] == {"kind": "session", "name": "chat-other"}
    assert k["what"] == "The slides are drawn, please check them."
    assert k["did"] == "Nothing for you; I filed it on the item."
    assert k["open"] is False


def test_the_board_sala_and_a_background_task_are_told_apart_in_plain_words():
    cases = [
        ("Another Claude session sent a message:\nfrom: stackshot\n\nAn item changed.", "board"),
        ("Another Claude session sent a message:\n[stackshot message] from chat-other · Tue 10:00 · to x\n\nHello", "session"),
        ("Another Claude session sent a message:\n[sala op 123] reboot done", "sala"),
        ("Another Claude session sent a message:\n[sala note 4] you left a note", "sala"),
        ("Another Claude session sent a message:\n[anchor] item 7: a reply came", "board"),
        ('Another Claude session sent a message:\n<cross-session-message from="x:/y" from-name="chat-other">\nhi\n</cross-session-message>', "session"),
    ]
    for text, kind in cases:
        es = entries([peer(text, 1), assistant("ok", 2)])
        assert es[0]["k"] == "kept" and es[0]["src"]["kind"] == kind, (text, es)
    task = {"type": "user", "uuid": _id(), "timestamp": ts(1), "origin": {"kind": "task-notification"},
            "message": {"role": "user", "content": "<task-notification><summary>Background command \"wait\" completed</summary></task-notification>"}}
    es = entries([task, assistant("ok", 2)])
    assert es[0]["src"]["kind"] == "task" and es[0]["what"] == 'Background command "wait" completed'


def test_a_hidden_turn_shows_only_when_its_reply_opens_with_the_owners_mark_and_the_mark_goes():
    es = entries([peer("Another Claude session sent a message:\nfrom: chat-other\n\nSlide 4 is in.", 1),
                  assistant("[for Rowan] The new slide 4 is in: one chart.", 2)])
    assert kinds(es) == ["own"] and es[0]["text"] == "The new slide 4 is in: one chart."


def test_a_mark_for_someone_else_or_in_the_middle_of_a_reply_does_not_show_the_turn():
    for reply in ("[for Someone] hi", "Noted. [for Rowan] hi", "[for Rowan]"):
        es = entries([peer("Another Claude session sent a message:\nfrom: chat-other\n\nhi", 1), assistant(reply, 2)])
        assert kinds(es) == ["kept"], reply


def test_a_hidden_turn_with_no_reply_yet_is_a_kept_line_that_says_so():
    es = entries([peer("Another Claude session sent a message:\nfrom: chat-other\n\nhi", 1)])
    assert kinds(es) == ["kept"] and es[0]["open"] is True


def test_the_owner_speaking_into_a_turn_something_else_started_makes_it_his():
    es = entries([peer("Another Claude session sent a message:\nfrom: chat-other\n\nhi", 1), human("wait, hold on", 2), assistant("Holding.", 3)])
    assert kinds(es) == ["me", "reply"]


def test_a_delivered_message_while_a_turn_is_open_joins_it_and_adds_no_line():
    es = entries([human("start", 1), assistant("working", 1, stop="tool_use", tool=True), tool_result(1),
                  peer("Another Claude session sent a message:\nfrom: chat-other\n\nFYI", 2), assistant("done", 3)])
    assert kinds(es) == ["me", "reply"]


def test_a_hook_that_sends_a_turn_back_for_one_more_reply_belongs_to_that_turn():
    hook = {"type": "user", "uuid": _id(), "timestamp": ts(3), "isMeta": True,
            "message": {"role": "user", "content": "Stop hook feedback:\n[hook]: add a line"}}
    es = entries([human("go", 1), assistant("first reply", 2), hook, assistant("second reply", 4)])
    assert kinds(es) == ["me", "reply", "reply"]


def test_what_is_no_turn_start_is_skipped_and_what_is_not_recognized_is_kept_back_not_lost():
    side = peer("hi", 1, isSidechain=True)
    stub = {"type": "user", "uuid": _id(), "timestamp": ts(1), "isCompactSummary": True, "message": {"role": "user", "content": "This session is being continued"}}
    sdk = {"type": "user", "uuid": _id(), "timestamp": ts(2), "promptSource": "sdk", "message": {"role": "user", "content": "Summarize the page"}}
    odd = peer("Something new", 3, origin={"kind": "brand-new-kind"}, isMeta=False)
    es = entries([side, stub, sdk, assistant("ok", 2), odd, assistant("ok", 3)])
    assert kinds(es) == ["kept", "kept"]
    assert es[0]["src"]["kind"] == "system" and es[1]["src"]["kind"] == "other"   # an sdk prompt is the system's; an unknown origin kind is "another session"


def test_a_typed_message_in_a_queued_attachment_is_the_owners_and_a_peer_one_is_not():
    es = entries([queued("typed while busy", 1), assistant("ok", 2), queued("Another Claude session sent a message:\nfrom: chat-other\n\nx", 3, origin="peer"), assistant("ok", 4)])
    assert kinds(es) == ["me", "reply", "kept"]


# ---------- the kept line's words ----------

def test_the_replys_last_line_skips_the_footer_notes():
    reply = "Handled.\nThe slide is redrawn and checked.\n\nWrite-up: none, nothing new.\nBoard: [item 9](https://tracker.example.test/t/9)\n- item one\n"
    es = entries([peer("Another Claude session sent a message:\nfrom: chat-other\n\nhi", 1), assistant(reply, 2)])
    assert es[0]["did"] == "The slide is redrawn and checked."


def test_a_long_phrase_is_clipped_and_links_become_their_text():
    long = "word " * 80
    es = entries([peer("Another Claude session sent a message:\nfrom: chat-other\n\n" + long, 1),
                  assistant("See [the page](https://example.com/page) " + long, 2)])
    assert len(es[0]["what"]) <= CT.PHRASE_MAX and es[0]["what"].endswith("\u2026")
    assert len(es[0]["did"]) <= CT.DID_MAX and "https://" not in es[0]["did"]


# ---------- today's count and the window ----------

def test_kept_today_counts_the_hidden_turns_since_midnight_in_the_zone():
    zone = ZoneInfo("Asia/Dubai")   # UTC+4: midnight is 20:00 UTC the evening before
    lines = [peer("Another Claude session sent a message:\nfrom: chat-other\n\nold", 0, timestamp="2026-10-13T19:59:00.000Z"), assistant("ok", 1, ),
             peer("Another Claude session sent a message:\nfrom: chat-other\n\nnew one", 0, timestamp="2026-10-13T20:01:00.000Z"), assistant("ok", 2),
             peer("Another Claude session sent a message:\nfrom: chat-other\n\nnew two", 0, timestamp="2026-10-14T05:00:00.000Z"), assistant("[for Rowan] shown", 3),
             peer("Another Claude session sent a message:\nfrom: stackshot\n\nnew three", 0, timestamp="2026-10-14T06:00:00.000Z"), assistant("ok", 4)]
    turns = CT.build_turns(lines)
    now = int(datetime(2026, 10, 14, 12, 0, tzinfo=timezone.utc).timestamp() * 1000)
    midnight = CT.day_start_ms(now, zone)
    assert midnight == int(datetime(2026, 10, 13, 20, 0, tzinfo=timezone.utc).timestamp() * 1000)
    assert CT.kept_today(turns, OWNER, midnight) == 2   # "new one" and "new three"; the marked one is shown, the old one is yesterday


def test_read_turns_reads_a_transcript_from_the_end_and_says_when_it_reached_today(tmp_path):
    p = tmp_path / "t.jsonl"
    p.write_text("\n".join(json.dumps(d) for d in [human("hello", 1), assistant("hi", 2)]) + "\n")
    now = int(datetime(2026, 10, 14, 12, 0, tzinfo=timezone.utc).timestamp() * 1000)
    turns, reached = CT.read_turns(p, now, ZoneInfo("Asia/Dubai"))
    assert reached is True and len(turns) == 1
    assert CT.read_turns(tmp_path / "missing.jsonl", now, ZoneInfo("UTC")) == ([], True)


def test_a_half_written_last_line_and_foreign_lines_are_skipped(tmp_path):
    p = tmp_path / "t.jsonl"
    p.write_text(json.dumps(human("hello", 1)) + "\n" + json.dumps({"type": "summary", "x": 1}) + "\nnot json\n" + json.dumps(assistant("hi", 2)) + '\n{"type": "assistant", "mess')
    turns, _ = CT.read_turns(p, int(datetime(2026, 10, 14, 12, tzinfo=timezone.utc).timestamp() * 1000), ZoneInfo("UTC"))
    assert [e["k"] for e in CT.entries(turns, OWNER)] == ["me", "reply"]
