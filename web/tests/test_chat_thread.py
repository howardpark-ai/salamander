"""The chat session's own thread (chatthread.py, GET /api/chat/thread), without a browser: what the owner wrote and what was answered to them, and nothing else.

Who wrote a line is chatturns.classify_user's decision (test_chatturns.py holds that rule) and the turns are chatkeep.Keeper's; this file holds what the
thread does with them:
  - shown: every message the owner wrote (typed, typed while busy and queued, an accepted suggestion, no promptSource, a queued_command attachment, a slash
    command typed in the pane; text and image blocks), the final replies of the turns they started (whatever stop reason, cut off included), and a reply of
    any other turn only when it opens with the owner's mark, without it;
  - not shown: tool calls and results, thinking, narration, delivered messages (another session, a task notice, a hook, a line sala typed), command output,
    sidechain, synthetic and compaction lines, text on the way to a tool call, a line still without a stop reason;
  - the owner speaking into a delivered turn takes it over; a turn is open until a reply closes it, an interrupt of the owner's turn ends it, or their
    command turns out to have run locally (which leaves the turn as the command found it), so a later delivered message's reply needs the mark;
  - a page, an older page, a newer page, a page around a line and a tail read followed by appends cut at every line give the same thread; pages hold whole
    turns, every cursor is a line's start, and a long transcript is not read whole for one page;
  - the route: nothing with no chat session set, the configured session alone (live or sleeping), 400 for a bad query.

What a wrong answer costs: another session's words or a tool's output in the thread, a message of the owner's or its answer missing, a page that repeats or
drops a line. Names and texts are invented; every temporary folder is removed as the test ends."""

from __future__ import annotations

import base64
import json
import os
import shutil
import urllib.error
import urllib.request

import pytest
from starlette.testclient import TestClient

from conftest import NAME, transcript_file
from sala_web import chatthread as T
from sala_web import sessions as S
from sala_web import transcript as TR
from sala_web.app import create_app
from test_chatturns import OWNER, assistant, human, peer, queued, tool_result, ts
from test_sleeping_sessions import NAME as SLEEPER, SLEEP_UUID, settings_for, wake  # noqa: F401  (wake is a fixture)

SID = "11111111-2222-3333-4444-555555555555"
PEER = "Another Claude session sent a message:\nfrom: demo-other\n\n"
ART = "https://claude.ai/artifact/demo-plan"


@pytest.fixture(autouse=True)
def _rm_tmp(tmp_path):
    yield
    shutil.rmtree(tmp_path, ignore_errors=True)


# ── lines ────────────────────────────────────────────────────────────────────
def slash(name: str, args: str, minute: int = 0) -> dict:
    """A slash command typed in the pane: no origin."""
    text = f"<command-name>{name}</command-name>\n<command-message>{name[1:]}</command-message>\n<command-args>{args}</command-args>"
    return {"type": "user", "uuid": f"cmd-{minute}", "timestamp": ts(minute), "message": {"role": "user", "content": text}}


def command_output(text: str, minute: int = 0) -> dict:
    return {"type": "user", "uuid": f"out-{minute}", "timestamp": ts(minute),
            "message": {"role": "user", "content": f"<local-command-stdout>{text}</local-command-stdout>"}}


def meta(text: str, minute: int = 0) -> dict:
    """A hook's feedback or a skill's text: meta, no origin."""
    return {"type": "user", "uuid": f"meta-{minute}-{len(text)}", "timestamp": ts(minute), "isMeta": True, "message": {"role": "user", "content": text}}


def task(minute: int = 0) -> dict:
    return {"type": "user", "uuid": f"task-{minute}", "timestamp": ts(minute), "origin": {"kind": "task-notification"},
            "message": {"role": "user", "content": "<task-notification><summary>a job finished</summary></task-notification>"}}


def system_output(text: str, minute: int = 0) -> dict:
    """A command's local output recorded as a system line."""
    return {"type": "system", "subtype": "local_command", "uuid": f"sys-{minute}", "timestamp": ts(minute), "isMeta": False, "level": "info",
            "content": f"<local-command-stdout>{text}</local-command-stdout>"}


def system_command(name: str, minute: int = 0) -> dict:
    """A command recorded as a system line, the form that is no turn line."""
    return system_output("", minute) | {"uuid": f"syscmd-{minute}", "content": f"<command-name>{name}</command-name>"}


def error_output(text: str, minute: int = 0) -> dict:
    return {"type": "user", "uuid": f"err-{minute}", "timestamp": ts(minute),
            "message": {"role": "user", "content": f"<local-command-stderr>{text}</local-command-stderr>"}}


def caveat(minute: int = 0) -> dict:
    """The notice Claude Code writes ahead of a command it runs locally."""
    return meta("<local-command-caveat>Caveat: a command run here follows.</local-command-caveat>", minute)


def local(name: str, minute: int = 0, output=command_output) -> list[dict]:
    """A command typed in the pane that ran locally, as the transcript holds it."""
    return [caveat(minute), slash(name, "", minute), output("done", minute)]


def skill(name: str, minute: int = 0) -> dict:
    """A command the session answers: recorded with the owner's origin."""
    return human(f"<command-message>{name[1:]}</command-message>\n<command-name>{name}</command-name>", minute)


def interrupt(minute: int = 0, tool: bool = False) -> dict:
    words = "[Request interrupted by user for tool use]" if tool else "[Request interrupted by user]"
    return {"type": "user", "uuid": f"int-{minute}", "timestamp": ts(minute), "promptId": "demo-prompt",
            "message": {"role": "user", "content": [{"type": "text", "text": words}]}}


def follow_up(text: str, minute: int = 0) -> dict:
    """A plugin's follow-up to the turn before it."""
    return meta(text, minute) | {"origin": {"kind": "plugin"}}


def work(minute: int = 0) -> list[dict]:
    return [assistant("On it.", minute, stop="tool_use", tool=True), tool_result(minute)]


def queued_peer(text: str, minute: int = 0) -> dict:
    d = queued(PEER + text, minute, origin="peer")
    d["attachment"]["isMeta"] = True
    return d


def hook_success(minute: int = 0) -> dict:
    return {"type": "attachment", "uuid": f"hook-{minute}", "timestamp": ts(minute),
            "attachment": {"type": "hook_success", "hookName": "Stop", "content": "hook output nobody wrote", "stdout": "ok"}}


def thinking(text: str, minute: int = 0, signature: str = "") -> dict:
    d = assistant("x", minute)
    d["message"]["content"] = [{"type": "thinking", "thinking": text, "signature": signature}]
    return d


def narration_signature() -> str:
    """A thinking block's signature that labels it narration (transcript.signature_kind): protobuf field 2 > field 1 > field 8, a string."""
    word = b"narration"
    inner = bytes([0x42, len(word)]) + word
    middle = bytes([0x0A, len(inner)]) + inner
    return base64.b64encode(bytes([0x12, len(middle)]) + middle).decode()


def sourced(text: str, source: str | None, minute: int = 0) -> dict:
    d = human(text, minute)
    if source is None:
        del d["promptSource"]
    else:
        d["promptSource"] = source
    return d


def scenario() -> list[dict]:
    return [
        human("What is due on Friday?", 1),
        assistant("Let me look.", 1, stop="tool_use", tool=True), tool_result(1),
        thinking("weighing the dates", 1),
        assistant("The deck is due at noon.", 2),
        peer(PEER + "The slides are drawn.", 3),
        assistant("Checking.", 3, stop="tool_use", tool=True), tool_result(3),
        assistant("Noted, nothing to report.", 4),
        peer(PEER.replace("demo-other", "stackshot") + "demo#7 changed.", 5),
        assistant("[for Rowan] demo#7 needs your answer today.", 6),
        task(7), assistant("Filed the job.", 7),
        task(8), assistant("[for Rowan]: The job finished.", 8),
        human("<!-- sala --> wake up", 9), assistant("Awake.", 9),
        human("Draw slide 4", 10),
        assistant("On it.", 10, stop="tool_use", tool=True), tool_result(10),
        peer(PEER + "The build is green.", 11),                         # relayed in the middle of the owner's turn
        hook_success(11),
        assistant("Slide 4 is drawn.", 11),
        meta("Stop hook feedback:\nadd a line for the record", 12),
        assistant("And the line is added.", 12),
        queued("and slide 5?", 13),
        queued_peer("Another thing.", 13),
        assistant("Slide 5 is next.", 14),
        sourced("typed while you worked", "queued", 15), assistant("Read.", 15),
        sourced("yes, do that", "suggestion_accepted", 16), assistant("Doing it.", 16),
        sourced("no source on record", None, 17), assistant("Recorded.", 17),
        slash("/demo", "one two", 18), command_output("demo ran", 18), assistant("The command is done.", 18),
        meta("Base directory for this skill: /nowhere", 19),            # a hidden turn nobody marked
        assistant("Skill read.", 19),
        peer(PEER + "Please review.", 20),
        assistant("Looking at it.", 20, stop="tool_use", tool=True), tool_result(20),
        human("hold on, what is this?", 21),                            # the owner takes the delivered turn over
        assistant("A review request; I will pass it on.", 22),
    ]


THREAD = [
    ("user", "What is due on Friday?"),
    ("assistant", "The deck is due at noon."),
    ("assistant", "demo#7 needs your answer today."),
    ("assistant", "The job finished."),
    ("user", "Draw slide 4"),
    ("assistant", "Slide 4 is drawn."),
    ("assistant", "And the line is added."),
    ("user", "and slide 5?"),
    ("assistant", "Slide 5 is next."),
    ("user", "typed while you worked"),
    ("assistant", "Read."),
    ("user", "yes, do that"),
    ("assistant", "Doing it."),
    ("user", "no source on record"),
    ("assistant", "Recorded."),
    ("user", "/demo one two"),
    ("assistant", "The command is done."),
    ("user", "hold on, what is this?"),
    ("assistant", "A review request; I will pass it on."),
]


def endings() -> dict[str, tuple[list[dict], list[tuple[str, str]]]]:
    """Turns that an interrupt or a local command touches: name -> (its lines, what the thread shows of them). Each ends with its turn closed or ended,
    so the cases read one after another show the same as each read alone."""
    news = PEER + "news"
    return {
        "interrupt, then a delivered message": (
            [human("Draw slide 1", 1), *work(1), interrupt(1, tool=True), peer(news, 2), assistant("Filed the news.", 2)],
            [("user", "Draw slide 1")]),
        "interrupt, then a delivered reply for the owner": (
            [human("Draw slide 2", 3), interrupt(3), peer(news, 4), assistant("[for Rowan] The build broke.", 4)],
            [("user", "Draw slide 2"), ("assistant", "The build broke.")]),
        "interrupt, then the owner's message": (
            [human("Draw slide 3", 5), interrupt(5), human("no, the next one", 6), peer(news, 6), assistant("The next one it is.", 7)],
            [("user", "Draw slide 3"), ("user", "no, the next one"), ("assistant", "The next one it is.")]),
        "interrupt, then the work goes on": (
            [human("Draw slide 5", 8), interrupt(8), *work(8), peer(news, 9), assistant("Slide 5 is drawn.", 9)],
            [("user", "Draw slide 5"), ("assistant", "Slide 5 is drawn.")]),
        "interrupt of a delivered turn": (
            [peer(news, 10), interrupt(10), peer(news, 10), assistant("Filed.", 11)],
            []),
        "local command, then a delivered message": (
            [*local("/model", 12), peer(news, 12), assistant("Filed the model news.", 13)],
            [("user", "/model")]),
        "output as a system line, then a task notice": (
            [caveat(14), slash("/status", "", 14), system_output("fine", 14), task(14), assistant("Filed the job.", 15)],
            [("user", "/status")]),
        "two commands, then a follow-up": (
            [*local("/one", 16, error_output), *local("/two", 16), follow_up("a plugin adds", 17), assistant("Added.", 17)],
            [("user", "/one"), ("user", "/two")]),
        "command after an interrupt": (
            [human("Draw slide 6", 17), interrupt(17), *local("/clear-up", 17), peer(news, 17), assistant("Filed.", 17)],
            [("user", "Draw slide 6"), ("user", "/clear-up")]),
        "command while the owner's turn works": (
            [human("Draw slide 7", 18), *work(18), *local("/effort", 19), peer(news, 19), assistant("Slide 7 is drawn.", 20)],
            [("user", "Draw slide 7"), ("user", "/effort"), ("assistant", "Slide 7 is drawn.")]),
        "command before the first reply": (
            [human("Draw slide 8", 20), *local("/fast", 20), peer(news, 20), assistant("Slide 8 is drawn.", 20)],
            [("user", "Draw slide 8"), ("user", "/fast"), ("assistant", "Slide 8 is drawn.")]),
        "command while a delivered turn works": (
            [peer(PEER + "review", 21), *work(21), *local("/cost", 21), peer(news, 21), assistant("Review filed.", 22)],
            [("user", "/cost")]),
        "command while a delivered turn works, reply for the owner": (
            [peer(PEER + "review", 21), *work(21), *local("/usage", 21), assistant("[for Rowan] Review done.", 22)],
            [("user", "/usage"), ("assistant", "Review done.")]),
        "command that is answered": (
            [skill("/review", 23), meta("Base directory for this skill: /nowhere", 23), *work(23), peer(news, 24), assistant("Reviewed.", 24)],
            [("user", "/review"), ("assistant", "Reviewed.")]),
        "the interrupt's words, typed or sent": (
            [human("Quote it", 25), human("[Request interrupted by user]", 25), peer(PEER + "[Request interrupted by user]", 25),
             assistant("Understood.", 26)],
            [("user", "Quote it"), ("user", "[Request interrupted by user]"), ("assistant", "Understood.")]),
        "interrupt of a follow-up, then another": (
            [human("Send it", 27), assistant("Sent.", 27), follow_up("add a line", 27), interrupt(27), follow_up("add it again", 27),
             assistant("Added again.", 27)],
            [("user", "Send it"), ("assistant", "Sent.")]),
        "output after the session began to answer": (
            [skill("/deep", 28), *work(28), command_output("ran", 28), peer(news, 28), assistant("Done in depth.", 28)],
            [("user", "/deep"), ("assistant", "Done in depth.")]),
        "output after another message came in": (
            [slash("/odd", "", 29), peer(news, 29), command_output("ran", 29), peer(news, 29), assistant("Counted.", 29)],
            [("user", "/odd"), ("assistant", "Counted.")]),
        "a command recorded as system lines alone, after their message": (
            [human("Draw slide 9", 29), system_command("/status", 29), system_output("fine", 29), peer(news, 29), assistant("Slide 9 is drawn.", 29)],
            [("user", "Draw slide 9"), ("assistant", "Slide 9 is drawn.")]),
        "a reply cut off": (
            [human("Write it all", 30), assistant("The first half", 30, stop="max_tokens"), peer(news, 31), assistant("Filed.", 31)],
            [("user", "Write it all"), ("assistant", "The first half")]),
    }


def endings_lines() -> list[dict]:
    return [d for lines, _ in endings().values() for d in lines]


ENDINGS_THREAD = [m for _, shown in endings().values() for m in shown]


def write(path, lines) -> None:
    path.write_text("".join(json.dumps(d) + "\n" for d in lines), encoding="utf-8")


def said(msgs: list[dict]) -> list[tuple[str, str]]:
    return [(m["role"], "\n".join(b.get("text", "") for b in m["blocks"] if b["kind"] != "image")) for m in msgs]


def thread(tmp_path, lines) -> tuple[list[dict], T.Selector]:
    p = tmp_path / f"{SID}.jsonl"
    write(p, lines)
    msgs, cursor, _end, sel = T.read_tail_page(p, SID, OWNER, 10_000)
    assert cursor == 0
    return msgs, sel


# ── what shows ───────────────────────────────────────────────────────────────
def test_the_thread_is_the_owners_messages_and_the_replies_to_them(tmp_path):
    msgs, sel = thread(tmp_path, scenario())
    assert said(msgs) == THREAD
    assert sel.open is False
    assert {b["kind"] for m in msgs for b in m["blocks"]} == {"text", "command"}
    assert all(m["role"] in ("user", "assistant") for m in msgs), "no kept line"
    assert "[for" not in json.dumps(msgs)


@pytest.mark.parametrize("line", [human("typed", 1), sourced("queued", "queued", 1), sourced("accepted", "suggestion_accepted", 1),
                                  sourced("unnamed", None, 1), queued("while busy", 1), slash("/demo", "", 1)],
                         ids=["typed", "queued", "suggestion", "no-source", "attachment", "slash"])
def test_what_the_owner_wrote_is_drawn_as_the_sessions_page_draws_it(tmp_path, line):
    msgs, sel = thread(tmp_path, [line])
    assert msgs == [TR.parse_line(line, SID)] and sel.open is True


def test_a_line_sala_typed_is_not_the_owners_and_its_reply_shows_only_when_marked(tmp_path):
    msgs, _ = thread(tmp_path, [human("<!-- sala --> wake up", 1), assistant("Awake.", 1),
                                sourced("<!-- sala --> wrap up", "queued", 2), assistant("[for Rowan] Wrapped up.", 2),
                                queued("<!-- sala --> go on", 3), assistant("Going on.", 3)])
    assert said(msgs) == [("assistant", "Wrapped up.")]


def test_an_image_the_owner_sent_keeps_its_address(tmp_path):
    line = human([{"type": "text", "text": "look at this"}, {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "iVBORw0K"}}], 1)
    msgs, _ = thread(tmp_path, [line])
    assert [b["kind"] for b in msgs[0]["blocks"]] == ["text", "image"]
    assert msgs[0]["blocks"][1]["url"] == f"api/image/{SID}/{line['uuid']}/1/-1"


def test_a_reply_is_its_text_blocks_alone_and_each_keeps_its_place(tmp_path):
    sig = narration_signature()
    assert TR.signature_kind(sig) == TR.NARRATION
    reply = assistant("x", 2)
    reply["message"]["content"] = [{"type": "thinking", "thinking": "said on the way", "signature": sig},
                                   {"type": "text", "text": "Here it is: ![chart](/w/demo/chart.png)"},
                                   {"type": "tool_use", "id": "t9", "name": "Bash", "input": {}}]
    msgs, _ = thread(tmp_path, [human("show me", 1), thinking("more of the way", 1, sig), reply])
    assert said(msgs)[1] == ("assistant", "Here it is: ![chart](/w/demo/chart.png)")
    assert [b["kind"] for b in msgs[1]["blocks"]] == ["text"]
    assert msgs[1]["blocks"][0]["localImages"][0]["url"] == f"api/md-image/{SID}/{reply['uuid']}/1/0"
    assert msgs[1]["model"] == "claude-opus-5-5"


@pytest.mark.parametrize("mark", ["[for Rowan]", "[for rowan]:", "[for the owner]", "[for owner]\n"])
def test_the_owners_mark_lets_a_hidden_turns_reply_through_and_is_taken_off(tmp_path, mark):
    msgs, _ = thread(tmp_path, [peer(PEER + "news", 1), assistant(f"{mark} Read this.", 2)])
    assert said(msgs) == [("assistant", "Read this.")]


def test_a_reply_that_is_only_the_mark_keeps_its_text_in_the_owners_turn_and_shows_nowhere_else(tmp_path):
    msgs, _ = thread(tmp_path, [peer(PEER + "news", 1), assistant("[for Rowan]", 2), human("and?", 3), assistant("[for Rowan]", 4)])
    assert said(msgs) == [("user", "and?"), ("assistant", "[for Rowan]")]


def test_a_mark_in_the_middle_of_a_reply_or_for_someone_else_is_no_mark(tmp_path):
    msgs, _ = thread(tmp_path, [peer(PEER + "news", 1), assistant("Read this [for Rowan]", 2),
                                peer(PEER + "more", 3), assistant("[for demo-other] Done.", 4)])
    assert msgs == []


def test_a_line_that_belongs_to_no_turn_shows_a_reply_only_when_marked(tmp_path):
    msgs, _ = thread(tmp_path, [assistant("Left over from before.", 1)])
    assert msgs == []
    msgs, _ = thread(tmp_path, [assistant("[for Rowan] Left over, for you.", 1)])
    assert said(msgs) == [("assistant", "Left over, for you.")]


def test_sidechain_synthetic_and_compaction_lines_are_nothing(tmp_path):
    side, synthetic, side_user = assistant("a subagent speaks", 2), assistant("API Error", 2), human("a subagent is asked", 2)
    side["isSidechain"] = side_user["isSidechain"] = True
    synthetic["message"]["model"] = "<synthetic>"
    summary = human("This session is being continued", 3, isCompactSummary=True)
    msgs, sel = thread(tmp_path, [human("go", 1), side_user, side, synthetic, summary, assistant("Gone.", 4)])
    assert said(msgs) == [("user", "go"), ("assistant", "Gone.")] and sel.open is False


@pytest.mark.parametrize("stop", ["end_turn", "max_tokens", "stop_sequence", "refusal"])
def test_a_final_reply_shows_whatever_stopped_it_and_closes_its_turn(tmp_path, stop):
    msgs, sel = thread(tmp_path, [human("go", 1), assistant("half a sen", 2, stop=stop), peer(PEER + "news", 3), assistant("Noted.", 4)])
    assert said(msgs) == [("user", "go"), ("assistant", "half a sen")] and sel.open is False
    msgs, sel = thread(tmp_path, [peer(PEER + "news", 1), assistant("[for Rowan] half a sen", 2, stop=stop)])
    assert said(msgs) == [("assistant", "half a sen")] and sel.open is False
    msgs, _ = thread(tmp_path, [peer(PEER + "news", 1), assistant("half a sen", 2, stop=stop)])
    assert msgs == []


@pytest.mark.parametrize("kind", ["tool_use", "no stop reason", "synthetic", "sidechain", "meta"])
def test_what_is_no_final_reply_is_not_shown_and_leaves_the_turn_open(tmp_path, kind):
    line = assistant("not the answer", 2, stop={"tool_use": "tool_use", "no stop reason": None}.get(kind, "max_tokens"))
    if kind == "synthetic":
        line["message"]["model"] = "<synthetic>"
    if kind in ("sidechain", "meta"):
        line["isSidechain" if kind == "sidechain" else "isMeta"] = True
    msgs, sel = thread(tmp_path, [human("go", 1), line])
    assert said(msgs) == [("user", "go")] and sel.open is True


# ── a turn with no reply ─────────────────────────────────────────────────────
@pytest.mark.parametrize("name", list(endings()))
def test_an_interrupt_or_a_local_command_never_lets_a_delivered_reply_in(tmp_path, name):
    lines, shown = endings()[name]
    assert said(thread(tmp_path, lines)[0]) == shown


def test_the_endings_read_one_after_another_show_the_same(tmp_path):
    msgs, _ = thread(tmp_path, endings_lines())
    assert said(msgs) == ENDINGS_THREAD


@pytest.mark.parametrize("lines, is_open", [
    ([human("go", 1), interrupt(2)], False),
    ([human("go", 1), *work(1), interrupt(2, tool=True)], False),
    ([human("go", 1), interrupt(2), *work(3)], True),
    (local("/model", 1), False),
    ([slash("/model", "", 1), system_output("fine", 1)], False),
    ([slash("/model", "", 1)], True),
    ([human("go", 1), *local("/effort", 2)], True),
    ([peer(PEER + "news", 1), *local("/effort", 2)], True),
    ([human("go", 1), assistant("Done.", 2), caveat(3)], False),
], ids=["interrupt", "interrupt-tool", "work-again", "command", "system-output", "command-alone", "in-their-turn", "in-a-delivered-turn", "caveat"])
def test_a_turn_with_no_reply_is_open_only_while_something_is_left_of_it(tmp_path, lines, is_open):
    assert thread(tmp_path, lines)[1].open is is_open
    assert T.is_open(tmp_path / f"{SID}.jsonl", SID, OWNER) is is_open


@pytest.mark.parametrize("lines", [
    [slash("/quiet", "", 1)],
    [human("go", 1), assistant("API Error", 1) | {"isApiErrorMessage": True, "message": {"role": "assistant", "model": "<synthetic>",
                                                  "stop_reason": "stop_sequence", "content": [{"type": "text", "text": "API Error"}]}}],
    [human("go", 1)],
], ids=["command-with-no-output", "api-error", "nothing-recorded"])
def test_a_turn_the_transcript_does_not_end_stays_the_owners(tmp_path, lines):
    """No line says these turns are over, so the next delivered message's reply counts as theirs (the module docstring says so)."""
    msgs, _ = thread(tmp_path, [*lines, peer(PEER + "news", 2), assistant("Counted.", 3)])
    assert said(msgs)[-1] == ("assistant", "Counted.")


def test_a_read_never_starts_at_a_commands_caveat(tmp_path, monkeypatch):
    monkeypatch.setattr(T, "WINDOW_FIRST", 1)
    p = tmp_path / f"{SID}.jsonl"
    write(p, [human("go", 1), assistant("Done.", 2), caveat(3), follow_up("a plugin adds", 3), assistant("Added.", 4)])
    msgs, cursor, _, _ = T.read_tail_page(p, SID, OWNER, 1)
    assert said(msgs) == [("user", "go"), ("assistant", "Done."), ("assistant", "Added.")] and cursor == 0


def test_a_turn_is_open_until_a_reply_closes_it(tmp_path):
    assert thread(tmp_path, [human("go", 1)])[1].open is True
    assert thread(tmp_path, [human("go", 1), assistant("Looking.", 1, stop="tool_use", tool=True), tool_result(1)])[1].open is True
    assert thread(tmp_path, [human("go", 1), assistant("Done.", 2)])[1].open is False
    assert thread(tmp_path, [peer(PEER + "news", 1)])[1].open is True
    p = tmp_path / f"{SID}.jsonl"
    assert T.is_open(p, SID, OWNER) is True
    write(p, [peer(PEER + "news", 1), assistant("Noted.", 2)])
    assert T.is_open(p, SID, OWNER) is False


# ── pages ────────────────────────────────────────────────────────────────────
def long_lines() -> list[dict]:
    """The scenario four times, with a long stretch that shows nothing in the middle and a large tool result in an owner's turn."""
    quiet = [x for i in range(12) for x in (peer(PEER + f"item {i}", 30), assistant(f"Filed {i}.", 30))]
    big = tool_result(31)
    big["toolUseResult"] = {"stdout": "y" * 5000}
    return (scenario() + quiet + [human("read the big file", 31), assistant("Reading.", 31, stop="tool_use", tool=True), big, assistant("Read it.", 31)]
            + scenario() + [peer(PEER + "last", 40), assistant("Filed.", 40)] + scenario() + quiet + scenario())


def long_endings() -> list[dict]:
    """The turns with no reply three times over, with stretches that show nothing between them."""
    quiet = [x for i in range(12) for x in (peer(PEER + f"item {i}", 30), assistant(f"Filed {i}.", 30))]
    return endings_lines() + quiet + endings_lines() + endings_lines()


LONG = {"scenario": long_lines, "endings": long_endings}
SIZES = [(1 << 20, 256 << 10, 4 << 20), (300, 128, 900), (64, 7, 1 << 20), (2000, 4096, 1)]   # WINDOW_FIRST, STEP, PAGE_BYTES


@pytest.fixture(params=SIZES, ids=["real", "small", "tiny", "one-turn"])
def sizes(request, monkeypatch):
    for name, value in zip(("WINDOW_FIRST", "STEP", "PAGE_BYTES"), request.param):
        monkeypatch.setattr(T, name, value)


def starts(path) -> set[int]:
    out, o = {0}, 0
    for line in path.read_bytes().split(b"\n")[:-1]:
        o += len(line) + 1
        out.add(o)
    return out


def full(path) -> list[dict]:
    """The whole file read forwards in one go: what every page is a part of."""
    found, _ = T._scan(path, SID, OWNER, 0, TR.complete_end(path))
    return [it["m"] for g in found for it in g]


@pytest.mark.parametrize("which", list(LONG))
def test_a_read_from_any_turn_start_is_the_rest_of_the_whole_read(tmp_path, sizes, which):
    p = tmp_path / f"{SID}.jsonl"
    write(p, LONG[which]())
    end = TR.complete_end(p)
    items = [it for g in T._scan(p, SID, OWNER, 0, end)[0] for it in g]
    for pos in sorted(starts(p)):
        start = T._turn_start(p, pos)
        assert start in starts(p) and start <= pos
        got = [it["m"] for g in T._scan(p, SID, OWNER, start, end)[0] for it in g]
        assert got == [it["m"] for it in items if it["off"] >= start], (pos, start)


@pytest.mark.parametrize("which", list(LONG))
@pytest.mark.parametrize("n", [1, 3, 8, 500])
def test_older_pages_add_up_to_the_whole_thread(tmp_path, sizes, n, which):
    p = tmp_path / f"{SID}.jsonl"
    write(p, LONG[which]())
    want = full(p)
    msgs, cursor, end, _ = T.read_tail_page(p, SID, OWNER, n)
    assert end == p.stat().st_size
    got = msgs
    while cursor:
        assert cursor in starts(p)
        older, nxt, start = T.read_before(p, SID, OWNER, cursor, n)
        assert nxt < cursor and start == (nxt == 0)
        got, cursor = older + got, nxt
    assert got == want
    if which == "endings":
        assert said(want) == ENDINGS_THREAD * 3
    else:
        assert said(want).count(("user", "Draw slide 4")) == 4


@pytest.mark.parametrize("which", list(LONG))
@pytest.mark.parametrize("n", [1, 3, 8, 500])
def test_newer_pages_add_up_to_the_whole_thread(tmp_path, sizes, n, which):
    p = tmp_path / f"{SID}.jsonl"
    write(p, LONG[which]())
    got, cursor, at_end = [], 0, False
    while not at_end:
        more, nxt, at_end = T.read_after(p, SID, OWNER, cursor, n)
        assert nxt > cursor and nxt in starts(p)
        got, cursor = got + more, nxt
    assert got == full(p) and cursor == p.stat().st_size


@pytest.mark.parametrize("which", list(LONG))
def test_a_page_around_a_line_is_a_run_of_the_thread_that_holds_its_turn(tmp_path, sizes, which):
    p = tmp_path / f"{SID}.jsonl"
    write(p, LONG[which]())
    want = full(p)
    ids = [json.dumps(m) for m in want]
    for at in sorted(starts(p))[::5]:
        d = T.read_around(p, SID, OWNER, at, 6)
        got = [json.dumps(m) for m in d["messages"]]
        assert d["start"] == (d["before"] == 0) and d["before"] in starts(p) and d["after"] in starts(p)
        if got:
            assert any(ids[i:i + len(got)] == got for i in range(len(ids))), at
        older: list = []
        cursor = d["before"]
        while cursor:
            more, cursor, _ = T.read_before(p, SID, OWNER, cursor, 10_000)
            older = more + older
        newer: list = []
        cursor, at_end = d["after"], d["end"]
        while not at_end:
            more, cursor, at_end = T.read_after(p, SID, OWNER, cursor, 10_000)
            newer += more
        assert older + d["messages"] + newer == want, at


def test_a_page_around_a_message_holds_it(tmp_path, monkeypatch):
    monkeypatch.setattr(T, "WINDOW_FIRST", 200)
    p = tmp_path / f"{SID}.jsonl"
    lines = long_lines()
    write(p, lines)
    offs, o = [], 0
    for d in lines:
        offs.append(o)
        o += len(json.dumps(d).encode()) + 1
    i = next(i for i, d in enumerate(lines) if d["type"] == "user" and d["message"]["content"] == "read the big file")
    got = T.read_around(p, SID, OWNER, offs[i + 3], 4)                     # the turn's reply: its question comes with it
    assert ("user", "read the big file") in said(got["messages"]) and ("assistant", "Read it.") in said(got["messages"])


def test_a_hooks_follow_up_is_never_cut_from_its_turn(tmp_path, monkeypatch):
    monkeypatch.setattr(T, "WINDOW_FIRST", 1)
    p = tmp_path / f"{SID}.jsonl"
    write(p, [human("go", 1), assistant("Done.", 2), meta("Stop hook feedback:\nadd a line", 3), assistant("Added.", 4)])
    msgs, cursor, _, _ = T.read_tail_page(p, SID, OWNER, 1)
    assert said(msgs) == [("user", "go"), ("assistant", "Done."), ("assistant", "Added.")] and cursor == 0


def test_the_end_of_a_long_transcript_is_read_without_the_rest(tmp_path, monkeypatch):
    for name, value in (("WINDOW_FIRST", 2000), ("STEP", 512), ("PAGE_BYTES", 6000)):
        monkeypatch.setattr(T, name, value)
    p = tmp_path / f"{SID}.jsonl"
    write(p, [x for _ in range(60) for x in scenario()])
    read: list[int] = []
    real = T.CK._lines
    monkeypatch.setattr(T.CK, "_lines", lambda path, start, end: (read.append(start), real(path, start, end))[1])
    msgs, cursor, _, _ = T.read_tail_page(p, SID, OWNER, 10_000)
    assert msgs and 0 < cursor and min(read) > p.stat().st_size * 3 // 4
    assert len(read) == len(set(read)), "no segment is read twice"


def test_a_stretch_that_shows_nothing_does_not_end_a_page_empty(tmp_path, monkeypatch):
    monkeypatch.setattr(T, "WINDOW_FIRST", 100)
    monkeypatch.setattr(T, "PAGE_BYTES", 200)
    p = tmp_path / f"{SID}.jsonl"
    write(p, [human("first", 1), assistant("One.", 1)] + [x for i in range(80) for x in (peer(PEER + f"{i}", 2), assistant("Filed.", 2))])
    msgs, cursor, _, _ = T.read_tail_page(p, SID, OWNER, 5)
    assert said(msgs) == [("user", "first"), ("assistant", "One.")] and cursor == 0


@pytest.mark.parametrize("make", [scenario, endings_lines], ids=["scenario", "endings"])
@pytest.mark.parametrize("n", [1, 3, 10_000])
def test_a_tail_read_and_appends_equal_the_history_wherever_the_file_is_cut(tmp_path, monkeypatch, n, make):
    monkeypatch.setattr(T, "WINDOW_FIRST", 300)
    p = tmp_path / f"{SID}.jsonl"
    raw = [(json.dumps(d) + "\n").encode() for d in make()]
    p.write_bytes(b"".join(raw))
    want = full(p)
    for k in range(len(raw) + 1):
        for torn in (b"", raw[k][: len(raw[k]) // 2] if k < len(raw) else b""):      # a line still being written is not read
            p.write_bytes(b"".join(raw[:k]) + torn)
            msgs, _, end, sel = T.read_tail_page(p, SID, OWNER, n)
            p.write_bytes(b"".join(raw))
            more, off = T.read_from(p, sel, end)
            got = msgs + more
            assert off == p.stat().st_size and got == want[len(want) - len(got):] and (n < 10_000 or got == want), (k, bool(torn))


@pytest.mark.parametrize("make, shown", [(scenario, THREAD), (endings_lines, ENDINGS_THREAD)], ids=["scenario", "endings"])
def test_appends_one_line_at_a_time_equal_the_history(tmp_path, make, shown):
    p = tmp_path / f"{SID}.jsonl"
    p.write_bytes(b"")
    _, _, end, sel = T.read_tail_page(p, SID, OWNER, 10)
    got: list = []
    with p.open("ab") as f:
        for d in make():
            f.write((json.dumps(d) + "\n").encode())
            f.flush()
            more, end = T.read_from(p, sel, end)
            got += more
    assert got == full(p) and said(got) == shown


@pytest.mark.parametrize("bad", ["x", "-1", "3", "999999999", ""])
def test_a_bad_cursor_is_refused(tmp_path, bad):
    p = tmp_path / f"{SID}.jsonl"
    write(p, scenario())
    for read in (T.read_before, T.read_after, T.read_around):
        with pytest.raises(TR.BadCursor):
            read(p, SID, OWNER, bad, 5)


def test_the_tail_page_is_read_again_only_when_the_file_changed(tmp_path, monkeypatch):
    p = tmp_path / f"{SID}.jsonl"
    write(p, [human("go", 1)])
    reads: list[int] = []
    real = T.read_tail_page
    monkeypatch.setattr(T, "read_tail_page", lambda *a: (reads.append(1), real(*a))[1])
    cache: dict = {}
    first = T.tail(p, SID, OWNER, 5, cache)
    assert T.tail(p, SID, OWNER, 5, cache) is first and len(reads) == 1 and first[3] is True
    with p.open("a", encoding="utf-8") as f:
        f.write(json.dumps(assistant("Done.", 2)) + "\n")
    msgs, _, end, open_ = T.tail(p, SID, OWNER, 5, cache)
    assert len(reads) == 2 and said(msgs) == [("user", "go"), ("assistant", "Done.")] and open_ is False and end == p.stat().st_size
    for n in range(20, 40):
        T.tail(p, SID, OWNER, n, cache)
    assert len(cache) <= T.CACHE_MAX


# ── the route ────────────────────────────────────────────────────────────────
def get(url: str) -> tuple[int, dict, dict]:
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            return r.status, dict(r.headers), json.load(r)
    except urllib.error.HTTPError as e:
        body = e.read()
        return e.code, dict(e.headers), json.loads(body) if body.startswith(b"{") else {}


def test_with_no_chat_session_set_the_answer_is_the_empty_one(served, monkeypatch):
    monkeypatch.delenv("SALA_CHAT_SESSION", raising=False)
    write(transcript_file(served), scenario())
    status, headers, d = get(served["url"] + "/api/chat/thread")
    assert status == 200 and d == {"configured": False} and headers["cache-control"] == "no-store"
    assert get(served["url"] + "/api/chat")[2] == d


def test_the_chat_session_gets_its_thread_with_the_cards_of_its_replies(served, monkeypatch):
    monkeypatch.setenv("SALA_CHAT_SESSION", NAME)
    monkeypatch.setenv("SALA_OWNER_NAME", OWNER)
    path = transcript_file(served)
    lines = scenario() + [human("the plan?", 50), assistant(f"Here: [the plan]({ART})", 51)]
    write(path, lines)
    status, headers, d = get(served["url"] + "/api/chat/thread")
    assert status == 200 and headers["cache-control"] == "no-store"
    assert list(d) == ["session", "messages", "offset", "before", "start", "busy", "cards"]
    assert d["session"] == NAME and d["offset"] == path.stat().st_size and d["before"] == 0 and d["start"] is True and d["busy"] is False
    assert said(d["messages"]) == THREAD + [("user", "the plan?"), ("assistant", f"Here: [the plan]({ART})")]
    last = d["messages"][-1]
    assert last["cards"] == [{"kind": "artifact", "url": ART, "title": "the plan"}]
    assert d["cards"] == {last["uuid"]: last["cards"]}
    text = json.dumps(d)
    assert "Checking." not in text and "tool_result" not in text and "weighing the dates" not in text and "demo-other" not in text
    assert get(served["url"] + "/api/chat/thread")[2] == d, "a cached page answers the same"


def test_the_cards_follow_the_host_of_each_request_and_leave_the_cached_page_alone(tmp_path):
    p = tmp_path / "projects" / TR.project_slug("/w/demo") / f"{SID}.jsonl"
    p.parent.mkdir(parents=True)
    write(p, [human("page?", 1), assistant("https://here.example.test/mockup/4", 2)])
    sess = S.Session(pid=1, session_id=SID, name="demo-chat", cwd="/w/demo", status="idle", tmux="")
    cache: dict = {}

    def ask(host: str) -> dict:
        return T.answer(name="demo-chat", sess=sess, projects_dir=tmp_path / "projects", owner=OWNER, n=10, before=None, around=None, after=None,
                        host=host, mockups_dir=tmp_path / "mockups", cache=cache)

    assert [c["url"] for c in ask("here.example.test")["messages"][1]["cards"]]
    other = ask("other.example.test")
    assert other["cards"] == {} and "cards" not in other["messages"][1]
    assert all("cards" not in m for m in next(iter(cache.values()))[1][0])


def test_older_newer_and_around_pages_carry_the_transcript_routes_keys(served, monkeypatch):
    monkeypatch.setenv("SALA_CHAT_SESSION", NAME)
    monkeypatch.setenv("SALA_OWNER_NAME", OWNER)
    write(transcript_file(served), scenario())
    base = served["url"] + "/api/chat/thread"
    tail = get(base + "?n=3")[2]
    assert tail["start"] is False and said(tail["messages"]) == THREAD[-len(tail["messages"]):]
    older = get(f"{base}?before={tail['before']}&n=500")[2]
    assert list(older) == ["session", "messages", "before", "start", "busy", "cards"] and older["start"] is True
    assert said(older["messages"] + tail["messages"]) == THREAD
    newer = get(f"{base}?after=0&n=500")[2]
    assert list(newer) == ["session", "messages", "after", "end", "busy", "cards"] and newer["end"] is True and said(newer["messages"]) == THREAD
    around = get(f"{base}?around={tail['before']}&n=4")[2]
    assert list(around) == ["session", "messages", "before", "start", "after", "end", "busy", "cards"] and around["messages"]


@pytest.mark.parametrize("query", ["n=x", "before=1", "after=x", "around=99999999", "before=0&after=0", "around=0&before=0"])
def test_a_bad_query_is_a_400(served, monkeypatch, query):
    monkeypatch.setenv("SALA_CHAT_SESSION", NAME)
    write(transcript_file(served), scenario())
    status, _, d = get(f"{served['url']}/api/chat/thread?{query}")
    assert status == 400 and d["error"]


def test_no_other_session_is_ever_served_here(served, monkeypatch):
    monkeypatch.setenv("SALA_CHAT_SESSION", "demo-chat")          # configured and not running; the live session is another one
    write(transcript_file(served), scenario())
    base = served["url"] + "/api/chat/thread"
    for query in ("", f"?session={NAME}", f"?pid={os.getpid()}", f"?name={NAME}&n=5"):
        status, _, d = get(base + query)
        assert status == 200 and d == {"session": "demo-chat", "messages": [], "offset": 0, "before": 0, "start": True, "busy": False, "cards": {}}
    for url in (f"{base}/{os.getpid()}", f"{base}/{NAME}"):
        assert get(url)[0] == 404


@pytest.mark.parametrize("served", [{"status": "busy"}, {"status": "waiting"}, {"status": "idle"}], indirect=True, ids=["busy", "waiting", "idle"])
def test_busy_is_an_open_turn_of_a_working_session(served, monkeypatch, request):
    monkeypatch.setenv("SALA_CHAT_SESSION", NAME)
    path = transcript_file(served)
    working = request.node.callspec.id != "idle"
    base = served["url"] + "/api/chat/thread"
    write(path, [human("go", 1)])
    assert get(base)[2]["busy"] is working and get(base + "?after=0")[2]["busy"] is working
    write(path, [human("go", 1), assistant("Done.", 2)])
    assert get(base)[2]["busy"] is False and get(base + "?after=0")[2]["busy"] is False


def test_a_sleeping_chat_session_is_read_from_its_file_and_not_woken(tmp_path, monkeypatch, wake):
    monkeypatch.setattr(S, "live_tmux_names", lambda: {})
    monkeypatch.setenv("SALA_CHAT_SESSION", SLEEPER)
    monkeypatch.setenv("SALA_OWNER_NAME", OWNER)
    wake.sleeper()
    settings = settings_for(tmp_path, wake)
    p = settings.claude_dir / "projects" / TR.project_slug("/w/work-a") / f"{SLEEP_UUID}.jsonl"
    p.parent.mkdir(parents=True)
    write(p, [human("before you sleep", 1), assistant("Good night.", 2)])
    d = TestClient(create_app(settings)).get("/api/chat/thread").json()
    assert d["session"] == SLEEPER and d["busy"] is False
    assert said(d["messages"]) == [("user", "before you sleep"), ("assistant", "Good night.")]
    assert wake.records() == []
