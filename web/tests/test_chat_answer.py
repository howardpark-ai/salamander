"""Answering a waiting item from the chat session's page (static/chatanswer.js), without a browser; test_chat_answer_ui.py holds the page.

What is held:
  - the served page: off it names neither of the two files; on, they stand on the chat layer's two include lines, after the layer's own, before app.js;
  - app.js hands the first list over in one place, chatlayer.js asks in one place, and no other file knows the module;
  - the module names no address of a board (the frame's origin comes from the item's own link) and posts to a named origin only;
  - every rule of its sheet is under the chat session's body class;
  - its pure functions, run in node: which link is a board item's and where its frame is, which lines of a reply are card markers and how the reply
    reads with them taken out, which messages are the board's.

What a wrong answer costs: a page that changes with the setting off, a frame of a wrong address, a message from another page taken for the board's, an item
named by another item's number. Names and texts are invented; every temporary folder is removed as the test ends."""

from __future__ import annotations

import json
import re
import shutil
import subprocess

import pytest

from sala_web.app import STATIC
from test_chat_layer import own_config, text  # noqa: F401  (own_config: an autouse fixture, this file's own config and its removal)

NODE = shutil.which("node")
needs_node = pytest.mark.skipif(not NODE, reason="node is not installed")

JS = STATIC / "chatanswer.js"
SOURCE = JS.read_text(encoding="utf-8")
BOARD, LOCAL = "https://board.example", "http://127.0.0.1:8123"     # invented boards


def code(name: str) -> list[str]:
    """The lines of a script without their // comments (an address in a string keeps its //)."""
    return [re.sub(r"(^|\s)//\s.*$", "", line).strip() for line in (STATIC / name).read_text(encoding="utf-8").splitlines()]


# ── the page ─────────────────────────────────────────────────────────────────
def test_the_two_files_are_on_the_layers_include_lines_and_off_the_page_names_neither(served, monkeypatch):
    base = served["url"] + "/"
    off = text(base)
    for trace in ("chatanswer", "SalaAnswerFrame", "chat-layer"):
        assert trace not in off, trace
    monkeypatch.setenv("SALA_CHAT_LAYER", "on")
    on = text(base)
    sheet = re.search(r'<link rel="stylesheet" href="static/chatlayer\.css\?v=[^"{}]+"><link rel="stylesheet" href="static/chatanswer\.css\?v=[^"{}]+">', on)
    script = re.search(r'<script src="static/chatlayer\.js\?v=[^"{}]+"></script><script src="static/chatanswer\.js\?v=[^"{}]+"></script>', on)
    assert sheet and script
    assert script.end() < on.index('<script src="static/app.js')
    assert "".join(line for line in on.splitlines(True) if "static/chatanswer." not in line) == off
    assert "window.SalaAnswerFrame" in text(served["url"] + "/static/chatanswer.js")
    assert "body.chat-session" in text(served["url"] + "/static/chatanswer.css")


def test_the_shared_script_and_the_layer_hand_over_in_one_place_each():
    uses = [line for line in code("app.js") if "SalaAnswerFrame" in line]
    assert uses == ["if (window.SalaAnswerFrame) text = SalaAnswerFrame.hideMarks(text);",
                    "if (window.SalaAnswerFrame) SalaAnswerFrame.strip(u.waitList, waiting, chatWaitRow);"]
    assert [line for line in code("app.js") if "chatWaitRow(w)" in line] == ["else u.waitList.replaceChildren(...waiting.map((w) => chatWaitRow(w)));"]
    assert [line for line in code("chatlayer.js") if "SalaAnswerFrame" in line] == [
        "const under = window.SalaAnswerFrame ? SalaAnswerFrame.thread(drawn.map(([m]) => m), redraw) : null;"]
    for f in sorted(STATIC.glob("*.js")):
        if f.name not in ("app.js", "chatlayer.js", "chatanswer.js"):
            assert "SalaAnswerFrame" not in f.read_text(encoding="utf-8"), f.name


def test_the_module_names_no_board_and_posts_to_a_named_origin_only():
    assert re.findall(r"https?://[\w.-]+", SOURCE) == []
    posts = re.findall(r"\.postMessage\(.*", SOURCE)
    assert len(posts) == 1 and posts[0].endswith(", box.origin);"), posts
    assert "sandbox" not in SOURCE and "innerHTML =" not in SOURCE


def test_every_rule_of_the_sheet_is_under_the_chat_sessions_body_class():
    css = re.sub(r"/\*.*?\*/", "", (STATIC / "chatanswer.css").read_text(encoding="utf-8"), flags=re.S)
    css = re.sub(r"@media[^{]*\{", "", css)
    rules = [block.rsplit("{", 1)[0].strip() for block in css.split("}") if "{" in block]
    assert rules
    for selectors in rules:
        parts, depth, part = [], 0, ""
        for ch in selectors:
            depth += (ch == "(") - (ch == ")")
            if ch == "," and not depth:
                parts.append(part)
                part = ""
            else:
                part += ch
        for p in parts + [part]:
            assert re.match(r"body\.chat-session(\.ans-kbd)? ", p.strip()), selectors


# ── the pure functions, in node ──────────────────────────────────────────────
PROGRAM = r"""
const fs = require('fs');
globalThis.window = {};
eval(fs.readFileSync(process.argv[1], 'utf8'));
const { address, markers, hideMarks, read } = window.SalaAnswerFrame;
const c = JSON.parse(fs.readFileSync(0, 'utf8'));
console.log(JSON.stringify({ address: c.address.map(address), markers: c.markers.map((t) => markers(t)), hide: c.hide.map((t) => hideMarks(t)),
  read: c.read.map(([d, item]) => read(d, item)) }));
"""


def run(address=(), markers=(), hide=(), read=()) -> dict:
    payload = {"address": list(address), "markers": list(markers), "hide": list(hide), "read": list(read)}
    out = subprocess.run([NODE, "-e", PROGRAM, str(JS)], input=json.dumps(payload), capture_output=True, text=True, check=True, timeout=60).stdout
    return json.loads(out)


def at(origin: str, item: str, path: str) -> dict:
    return {"origin": origin, "item": item, "page": origin + path}


@needs_node
def test_only_the_address_of_a_boards_item_page_gives_a_frame():
    cases = [
        (BOARD + "/items/42", at(BOARD, "42", "/items/42")),
        (BOARD + "/items/42/", at(BOARD, "42", "/items/42")),
        (BOARD + "/sub/items/tmp-7?x=1#y", at(BOARD, "tmp-7", "/sub/items/tmp-7")),
        (LOCAL + "/items/9", at(LOCAL, "9", "/items/9")),
        (BOARD + "/items/a%23b", at(BOARD, "a#b", "/items/a%23b")),
        (BOARD + "/moves/42", None),
        (BOARD + "/items/", None),
        (BOARD + "/items/42/answer-frame", None),
        (BOARD + "/?next=/items/42", None),
        ("/items/42", None),
        ("javascript:alert(1)//items/42", None),
        ("data:text/html,/items/42", None),
        ("", None),
        (None, None),
    ]
    assert run(address=[u for u, _ in cases])["address"] == [w for _, w in cases]


@needs_node
def test_a_card_is_asked_for_by_a_marker_line_of_its_own_outside_code_and_quotes():
    page = BOARD + "/items/7"
    cases = [
        ("[card: item#7]", [{"i": 0, "url": None, "id": "item#7"}]),
        ("   [card: item#7]  ", [{"i": 0, "url": None, "id": "item#7"}]),
        ("Intro.\n[card: item#7]\nOutro.", [{"i": 1, "url": None, "id": "item#7"}]),
        (f"[card: [item#7]({page})]", [{"i": 0, "url": page, "id": None}]),
        ("[card: item#7]\n[card: item#8]", [{"i": 0, "url": None, "id": "item#7"}, {"i": 1, "url": None, "id": "item#8"}]),
        ("[card: item#8]\n[card: item#7]\n[card: item#8]", [{"i": 0, "url": None, "id": "item#8"}, {"i": 1, "url": None, "id": "item#7"},
                                                               {"i": 2, "url": None, "id": "item#8"}]),
        ("item#7 is ready.", []),                        # a plain mention is no card
        (f"Look at {page}.", []),                         # nor a plain link
        ("item [card: item#7] is ready.", []),           # in a sentence
        ("    [card: item#7]", []),                      # four spaces: an indented code block
        ("> [card: item#7]", []),                         # a quote
        ("- [card: item#7]", []),                         # a list item
        ("`[card: item#7]`", []),                         # inline code
        ("[card: item#7`]", []),                          # a backquote is not a character of an id
        ("[card: item#7", []),                            # still being written
        ("[card: item#7] and more", []),
        ("[card: ]", []),
        ("[card: board 7]", []),
        ("[card: [item#7](ftp://board.example/items/7)]", []),
        ("[card: item#7]]", []),
        ("```\n[card: item#7]\n```", []),                # a fenced block
        ("~~~\n[card: item#7]\n~~~", []),
        ("````\n```\n[card: item#7]\n````\n[card: item#8]", [{"i": 4, "url": None, "id": "item#8"}]),   # closes only with its own length
        ("```\n[card: item#7]", []),                      # a fence that is not closed runs to the end
        ("```\n```\n[card: item#7]", [{"i": 2, "url": None, "id": "item#7"}]),
    ]
    got = run(markers=[t for t, _ in cases])["markers"]
    assert got == [w for _, w in cases], [(c[0], g) for c, g in zip(cases, got) if g != c[1]]


@needs_node
def test_a_reply_reads_without_its_marker_lines_and_its_code_and_quotes_keep_theirs():
    cases = [
        ("Done.\n[card: item#7]\nNext.", "Done.\nNext."),
        ("[card: item#7]", ""),
        ("[card: item#7]\n[card: item#8]\nTwo.", "Two."),
        ("```\n[card: item#7]\n```", "```\n[card: item#7]\n```"),
        ("> [card: item#7]\nText [card: item#7]", "> [card: item#7]\nText [card: item#7]"),
        ("No marker here.", "No marker here."),
    ]
    got = run(hide=[t for t, _ in cases])["hide"]
    assert got == [w for _, w in cases], list(zip(cases, got))


@needs_node
def test_only_the_boards_message_about_the_frames_own_item_is_read_and_its_height_is_held_to_a_range():
    good = {"source": "stackshot", "kind": "answer-frame", "v": 1, "item": "42", "height": 200, "state": "open", "typing": False}

    def one(**over) -> list:
        return [{**good, **over}, "42"]

    states = ["open", "sending", "answered", "changed", "closed", "signed_out"]
    got = run(read=[one(state=s) for s in states])["read"]
    assert got == [{"state": s, "height": 200, "typing": False} for s in states]
    wrong = [one(source="sala"), one(kind="other"), one(v=2), one(v="1"), one(item="43"), one(item=42), one(state="gone"), one(state=None),
             [None, "42"], ["open", "42"], [[good], "42"]]
    assert run(read=wrong)["read"] == [None] * len(wrong)
    heights = [(1, 40), (40, 40), (199.2, 200), (2000, 2000), (10 ** 9, 2000), (0, None), (-3, None), ("300", None), (None, None)]
    got = run(read=[one(height=h) for h, _ in heights])["read"]
    assert [m["height"] for m in got] == [w for _, w in heights]
    assert [m["typing"] for m in run(read=[one(typing=True), one(typing="yes"), one(typing=1)])["read"]] == [True, False, False]
