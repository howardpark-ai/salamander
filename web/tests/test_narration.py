"""Narration: model text the API sends as a `thinking` block.

Claude Code prints such a block as a normal reply line; sala's chat hid it with the thinking while "Thinking & tool
calls" was off, so a line he saw in the terminal was missing from the chat. The rule is Claude Code's own (2.1.311): a
thinking block's `signature` is base64 of a protobuf, signature field 2 > field 1 > field 8 is a string label, and a
block labelled "narration" with text that is not blank is a reply line (real thinking is labelled "thinking" and stays
behind the toggle). A block without a signature, or with one that does not read, is not narration. The fixtures are
modelled on a real pair of lines (an empty "thinking" block, then a "narration" block, both signed, in one message with
a tool call); the signatures here are built from the same field numbers, with no real content.
"""

from __future__ import annotations

import base64
import json

from conftest import NAME, transcript_file
from sala_web import transcript as TR

SID = "11111111-2222-3333-4444-555555555555"
SENTENCE = "The file ended up empty since the `!` command can't pause"


def _varint(n: int) -> bytes:
    out = b""
    while True:
        b = n & 0x7F
        n >>= 7
        out += bytes([b | (0x80 if n else 0)])
        if not n:
            return out


def _bytes(num: int, data: bytes) -> bytes:
    return _varint(num << 3 | 2) + _varint(len(data)) + data


def sig(label: str | None, *, junk: bytes = b"") -> str:
    """A signature shaped like the real ones: {1: varint, 2: {1: {1,3,7: varint, 8: label}, 2..5: bytes}, 3: varint}."""
    meta = _varint(1 << 3) + _varint(1) + _varint(3 << 3) + _varint(2) + _varint(7 << 3) + _varint(5)
    if label is not None:
        meta += _bytes(8, label.encode())
    body = _bytes(1, meta) + _bytes(2, b"\x00" * 12) + _bytes(3, b"\x01" * 12) + _bytes(4, b"\x02" * 48) + _bytes(5, junk or b"\x03" * 64)
    raw = _varint(1 << 3) + _varint(2) + _bytes(2, body) + _varint(3 << 3) + _varint(1)
    return base64.b64encode(raw).decode()


def msg(*blocks: dict, uuid: str = "a1") -> dict:
    return {"uuid": uuid, "timestamp": "2026-10-27T00:41:54Z", "sessionId": SID, "type": "assistant",
            "message": {"id": "msg_x", "role": "assistant", "model": "claude-sonnet-5-5", "content": list(blocks)}}


def think(text: str, signature: object = "absent") -> dict:
    b: dict = {"type": "thinking", "thinking": text}
    if signature != "absent":
        b["signature"] = signature
    return b


def kinds(d: dict) -> list[str]:
    m = TR.parse_line(d, SID)
    return [b["kind"] for b in m["blocks"]] if m else []


def test_signature_kind_reads_the_label():
    assert TR.signature_kind(sig("narration")) == "narration"
    assert TR.signature_kind(sig("thinking")) == "thinking"
    assert TR.signature_kind(sig(None)) is None  # no label field
    for bad in (None, "", 7, "not base64 !!", base64.b64encode(b"\xff\xff\xff").decode(), base64.b64encode(b"\x12\x05ab").decode()):
        assert TR.signature_kind(bad) is None


def test_signed_narration_shows_as_a_reply():
    m = TR.parse_line(msg(think("", sig("thinking")), think(SENTENCE, sig("narration")),
                          {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "ls"}}), SID)
    assert [b["kind"] for b in m["blocks"]] == ["text", "tool_use"]
    assert m["blocks"][0]["text"] == SENTENCE and m["blocks"][0]["truncated"] is False
    assert m["model"] == "claude-sonnet-5-5"


def test_narration_beside_a_text_block_keeps_order():
    d = msg(think("first", sig("narration")), {"type": "text", "text": "second"}, think("third", sig("narration")))
    m = TR.parse_line(d, SID)
    assert [(b["kind"], b["text"]) for b in m["blocks"]] == [("text", "first"), ("text", "second"), ("text", "third")]


def test_signed_thinking_stays_thinking():
    assert kinds(msg(think("reasoning", sig("thinking")))) == ["thinking"]


def test_empty_blocks_stay_hidden():
    assert kinds(msg(think("", sig("narration")))) == []  # nothing to print
    assert kinds(msg(think("  \n ", sig("narration")))) == []
    assert kinds(msg(think("", sig("thinking")))) == []
    assert kinds(msg(think(""))) == []  # unsigned and empty


def test_unsigned_or_unreadable_thinking_is_not_narration():
    assert kinds(msg(think(SENTENCE))) == ["thinking"]  # no signature field
    assert kinds(msg(think(SENTENCE, ""))) == ["thinking"]
    assert kinds(msg(think(SENTENCE, "@@not-base64@@"))) == ["thinking"]
    assert kinds(msg(think(SENTENCE, sig(None)))) == ["thinking"]


def test_unknown_label_is_not_narration():
    assert kinds(msg(think(SENTENCE, sig("summary")))) == ["thinking"]


def test_long_narration_is_clipped_like_a_reply():
    m = TR.parse_line(msg(think("x" * (TR.TEXT_LIMIT * 5 + 10), sig("narration"))), SID)
    assert len(m["blocks"][0]["text"]) == TR.TEXT_LIMIT * 5 and m["blocks"][0]["truncated"] is True


def test_narration_survives_read_tail(tmp_path):
    p = tmp_path / f"{SID}.jsonl"
    lines = [msg(think("", sig("thinking")), uuid="a1"), msg(think(SENTENCE, sig("narration")), uuid="a2"),
             msg(think("deep", sig("thinking")), uuid="a3")]
    p.write_text("".join(json.dumps(d) + "\n" for d in lines))
    msgs, _ = TR.read_tail(p, SID)
    assert [[b["kind"] for b in m["blocks"]] for m in msgs] == [["text"], ["thinking"]]


# The page: with "Thinking & tool calls" off a narration line is on screen and real thinking is not; with it on, all show.
PROBE = r"""
new Promise((res) => {
  const t0 = Date.now();
  (function poll() {
    if (document.querySelectorAll("#chat > .msg").length < 4 && Date.now() - t0 < 15000) return setTimeout(poll, 100);
    const shown = () => [...document.querySelectorAll("#chat > .msg")]
      .filter((m) => getComputedStyle(m).display !== "none")
      .map((m) => ({ uuid: m.dataset.uuid, text: m.innerText.replace(/\s+/g, " ").trim() }));
    const off = { hide: document.body.classList.contains("hide-tools"), shown: shown() };
    document.body.classList.remove("hide-tools");
    for (const d of document.querySelectorAll("#chat details")) d.open = true;
    const on = { hide: document.body.classList.contains("hide-tools"), shown: shown(),
                 folds: document.querySelectorAll("#chat details.thinking").length };
    res({ off, on });
  })();
})
"""


def test_page_shows_narration_and_hides_thinking_until_the_toggle(served, browser):
    lines = [
        msg(think("", sig("thinking")), think(SENTENCE, sig("narration")),
            {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "ls"}}, uuid="n1"),
        msg(think("signed reasoning", sig("thinking")), uuid="s1"),
        msg(think("unsigned reasoning"), uuid="u1"),
        msg(think("", sig("narration")), uuid="e1"),
        msg({"type": "text", "text": "plain reply"}, uuid="p1"),
    ]
    transcript_file(served).write_text("".join(json.dumps(d) + "\n" for d in lines))
    browser.open(f"{served['url']}/#s={NAME}")
    got = browser.evaluate(PROBE)
    off, on = got["off"], got["on"]
    assert off["hide"] is True
    # toggle off: the narration (its tool call hidden) and the plain reply; no thinking, no empty message
    assert [m["uuid"] for m in off["shown"]] == ["n1", "p1"], off
    # (markdown draws the sentence's backticks as code, so only its first words are compared)
    assert "The file ended up empty since the" in off["shown"][0]["text"]
    assert "reasoning" not in " ".join(m["text"] for m in off["shown"])
    # toggle on: everything with something in it, the real thinking as folds
    assert on["hide"] is False
    assert [m["uuid"] for m in on["shown"]] == ["n1", "s1", "u1", "p1"], on
    assert on["folds"] == 2

