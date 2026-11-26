"""The chat session's own layer (SALA_CHAT_LAYER, static/chatlayer.js), without a browser; test_chat_layer_ui.py holds the page.

What is held:
  - the setting: off by default, on only for on|1|yes|true, from the environment or sala's config file, read at each page load;
  - off, the served page names neither of the layer's files and is the same page with its two include lines gone; on, it takes the sheet after the other
    sheets and the script before app.js, each with its version;
  - no api answer depends on the setting, for the chat session or for another one;
  - app.js hands over in the places web/README.md names and nowhere else;
  - a running "!" command's live block is the session view's own: the event reaches it with the layer on, and the layer holds no copy of it;
  - the layer's pure functions, run in node: which language a text is in, the first line of a reply, how a newer read joins what is held;
  - why the layer reads the newest page and not `after`: `after` leaves out the later reply of a turn that was open at that cursor.

What a wrong answer costs: a page that changes with the setting off, another session's page or answers changing with it on, turn text shown in a language the
owner did not write, messages lost or doubled as the thread grows, a reply that never arrives. Names and texts are invented; every temporary folder is
removed as the test ends."""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import urllib.request

import pytest

from conftest import NAME, transcript_file
from sala_web import config as C
from sala_web import sessions as S
from sala_web import transcript as TR
from sala_web.app import STATIC
from test_chat_thread import get, said, write
from test_chatturns import assistant, human, peer, tool_result

NODE = shutil.which("node")
needs_node = pytest.mark.skipif(not NODE, reason="node is not installed")

APP_JS = (STATIC / "app.js").read_text(encoding="utf-8")
LAYER_JS = STATIC / "chatlayer.js"
OTHER, OTHER_SID, OTHER_CWD = "demo-other", "22222222-3333-4444-5555-666666666666", "/srv/demo/work"


@pytest.fixture(autouse=True)
def own_config(tmp_path, monkeypatch):
    """No setting of the machine's own: the config file is one of this test's, absent until a test writes it."""
    monkeypatch.setenv("SALA_CONFIG", str(tmp_path / "sala-config"))
    monkeypatch.delenv("SALA_CHAT_LAYER", raising=False)
    yield
    shutil.rmtree(tmp_path, ignore_errors=True)


def text(url: str) -> str:
    with urllib.request.urlopen(url, timeout=10) as r:
        return r.read().decode("utf-8")


# ── the setting ──────────────────────────────────────────────────────────────
def test_the_setting_is_off_when_nothing_says_anything():
    assert C.chat_layer() is False


@pytest.mark.parametrize("value", ["on", "1", "yes", "true", " On ", "TRUE", "Yes"])
def test_these_values_turn_it_on(monkeypatch, value):
    monkeypatch.setenv("SALA_CHAT_LAYER", value)
    assert C.chat_layer() is True


@pytest.mark.parametrize("value", ["", "off", "0", "no", "false", "maybe", "2", "enabled", "on please"])
def test_every_other_value_leaves_it_off(monkeypatch, value):
    monkeypatch.setenv("SALA_CHAT_LAYER", value)
    assert C.chat_layer() is False


def test_the_setting_is_read_from_salas_config_file_and_the_environment_wins(tmp_path, monkeypatch):
    conf = tmp_path / "sala-config"
    conf.write_text("SALA_CHAT_LAYER=on   # the chat page's own layer\n", encoding="utf-8")
    assert C.chat_layer() is True
    monkeypatch.setenv("SALA_CHAT_LAYER", "off")
    assert C.chat_layer() is False
    monkeypatch.delenv("SALA_CHAT_LAYER")
    conf.write_text("#SALA_CHAT_LAYER=off\n", encoding="utf-8")
    assert C.chat_layer() is False


# ── the page ─────────────────────────────────────────────────────────────────
def test_off_the_page_has_no_trace_of_the_layer_and_on_it_gains_two_lines_and_nothing_else(served, monkeypatch):
    base = served["url"] + "/"
    unset = text(base)
    for value in ("off", "0", "maybe"):
        monkeypatch.setenv("SALA_CHAT_LAYER", value)
        assert text(base) == unset, value
    monkeypatch.setenv("SALA_CHAT_LAYER", "on")
    on = text(base)                                                   # read at each page load: the same running app
    for trace in ("chatlayer", "chat-layer", "SalaThreadLayer"):
        assert trace not in unset, trace
    lines = on.splitlines(True)
    added = [line for line in lines if "static/chatlayer." in line]
    assert len(added) == 2
    assert "".join(line for line in lines if line not in added) == unset
    sheet = re.search(r'<link rel="stylesheet" href="static/chatlayer\.css\?v=[^"{}]+">', on)
    script = re.search(r'<script src="static/chatlayer\.js\?v=[^"{}]+"></script>', on)
    assert sheet and script
    assert sheet.start() > on.index('href="static/termclip.css')
    assert script.start() < on.index('<script src="static/app.js')
    monkeypatch.setenv("SALA_CHAT_LAYER", "off")
    assert text(base) == unset


def test_both_files_are_served(served):
    assert "window.SalaThreadLayer" in text(served["url"] + "/static/chatlayer.js")
    assert "body.chat-layer" in text(served["url"] + "/static/chatlayer.css")


def test_every_rule_of_the_layers_sheet_is_under_its_own_body_class():
    css = re.sub(r"/\*.*?\*/", "", (STATIC / "chatlayer.css").read_text(encoding="utf-8"), flags=re.S)
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
            assert p.strip().startswith("body.chat-layer "), selectors


def add_session(served, name: str, sid: str, lines: list[dict]) -> int:
    """A second live session beside the fixture's: the test runner's parent process stands for its claude."""
    claude, pid = served["settings"].claude_dir, os.getppid()
    (claude / "sessions" / f"{pid}.json").write_text(json.dumps(
        {"pid": pid, "sessionId": sid, "name": name, "cwd": OTHER_CWD, "status": "idle", "tmux": "y:@0.%1", "procStart": S.proc_start(pid)}))
    project = claude / "projects" / TR.project_slug(OTHER_CWD)
    project.mkdir(parents=True, exist_ok=True)
    write(project / f"{sid}.jsonl", lines)
    return pid


def test_no_api_answer_depends_on_the_setting_for_the_chat_session_or_another(served, monkeypatch):
    monkeypatch.setenv("SALA_CHAT_SESSION", NAME)
    lines = [human("go", 1), assistant("Looking.", 1, stop="tool_use", tool=True), tool_result(1), assistant("Done.", 2),
             peer("Another Claude session sent a message:\nfrom: demo-third\n\nBuilt.", 3), assistant("Noted.", 4)]
    write(transcript_file(served), lines)
    other = add_session(served, OTHER, OTHER_SID, lines)
    paths = ["/api/sessions", "/api/chat", "/api/chat/thread", "/api/chat/thread?replies=1", f"/api/s/{os.getpid()}/transcript",
             f"/api/s/{other}/transcript"]
    off = {p: get(served["url"] + p)[2] for p in paths}
    monkeypatch.setenv("SALA_CHAT_LAYER", "on")
    assert {p: get(served["url"] + p)[2] for p in paths} == off
    assert "Looking." in json.dumps(off[f"/api/s/{other}/transcript"]) and "Noted." in json.dumps(off[f"/api/s/{other}/transcript"])


# ── the shared script's handover ─────────────────────────────────────────────
def test_app_js_hands_over_in_the_named_places_and_nowhere_else():
    code = [line.split("//")[0].strip() for line in APP_JS.splitlines()]
    uses = [line for line in code if re.search(r"SalaThreadLayer|\blayer\.(takes|reset|append|status)\(|\|\| layer\)|if \(layer\b", line)]
    assert uses == [
        "if (window.SalaThreadLayer) SalaThreadLayer.sync();",
        "const layer = window.SalaThreadLayer && SalaThreadLayer.takes(s) ? SalaThreadLayer : null;",
        "if (layer) { layer.reset(s, d, resumed); chatStripSoon(); return; }",
        "if (layer) { layer.append(s, d); chatStripSoon(); return; }",
        "if (layer) layer.status(s);",
    ]
    for f in sorted(STATIC.glob("*.js")):
        if f.name not in ("app.js", "chatlayer.js"):
            assert "SalaThreadLayer" not in f.read_text(encoding="utf-8"), f.name


def test_a_running_commands_live_block_is_the_session_views_own():
    """The stream's `live` event reaches applyLive whether or not the layer draws the thread, and the layer holds no part of the block or of its Stop."""
    listener = APP_JS[APP_JS.index('es.addEventListener("live"'):APP_JS.index('es.addEventListener("status"')]
    assert "if (state.es !== es) return;" in listener and "applyLive(d);" in listener and "layer" not in listener, listener
    layer = LAYER_JS.read_text(encoding="utf-8") + (STATIC / "chatlayer.css").read_text(encoding="utf-8")
    assert not re.findall(r"live-(?:head|label|stop|out)\b|stopLive|app\.live\.|api/s/", layer)


# ── the pure functions, in node ──────────────────────────────────────────────
PROGRAM = r"""
const fs = require('fs');
globalThis.window = {};
eval(fs.readFileSync(process.argv[1], 'utf8'));
const { langOf, firstLine, mergePage } = window.SalaThreadLayer;
const cases = JSON.parse(fs.readFileSync(0, 'utf8'));
console.log(JSON.stringify({ lang: cases.lang.map(langOf), line: cases.line.map(firstLine), merge: cases.merge.map(([h, p]) => mergePage(h, p)) }));
"""


def run(lang=(), line=(), merge=()) -> dict:
    out = subprocess.run([NODE, "-e", PROGRAM, str(LAYER_JS)], input=json.dumps({"lang": list(lang), "line": list(line), "merge": list(merge)}),
                         capture_output=True, text=True, check=True, timeout=60).stdout
    return json.loads(out)


KO = "\uc9c0\uae08 \uc124\uc815 \ud30c\uc77c\uc744 \uc77d\uace0 \uc788\uc2b5\ub2c8\ub2e4."
KO_WITH_NAMES = "sala \uc124\uc815\uc744 \ud655\uc778\ud558\uace0 README \ub3c4 \uc77d\uaca0\uc2b5\ub2c8\ub2e4"


@needs_node
def test_the_language_of_a_text_is_korean_latin_or_neither():
    cases = [
        ("Reading the settings file now.", "latin"),
        (KO, "ko"),
        (KO_WITH_NAMES, "ko"),
        ("Please check the \ud30c\uc77c now and then go on", "latin"),                          # one Korean word in many
        ("Please check \ud30c\uc77c \uc124\uc815 \ud655\uc778 now", "ko"),                      # half of them
        ("```py\nprint('hello world, this is code')\n```\n" + KO, "ko"),                        # code says nothing
        (KO + " `npm run build` https://example.com/a/long/address", "ko"),                    # neither do addresses
        ("\u3053\u308c\u306f\u30c6\u30b9\u30c8\u3067\u3059", None),                              # another script
        ("1234 !! 56%", None),
        ("`only = code`", None),
        ("https://example.com/only/an/address", None),
        ("", None),
    ]
    assert run(lang=[c for c, _ in cases])["lang"] == [want for _, want in cases]


@needs_node
def test_the_first_line_of_a_reply_is_plain_words_on_one_line():
    cases = [
        ("## The plan\n- first step", "The plan"),
        ("```sh\nsala ls\n```\nDone with the list.", "Done with the list."),
        ("---\n\n> quoted  words\there", "quoted words here"),
        ("See [the page](https://example.com/x) in **bold** `now`", "See the page in bold now"),
        ("1. count the rows", "count the rows"),
        ("\n\n   \n", ""),
        ("```\nonly code, never closed", ""),
        ("x" * 500, "x" * 200),
        ("\U0001F600" * 150 + "y" * 100, "\U0001F600" * 150 + "y" * 50),                       # cut by characters, never inside one
    ]
    assert run(line=[c for c, _ in cases])["line"] == [want for _, want in cases]


def held(ids: str, before: int | None, start: bool = False) -> dict:
    return {"items": [{"uuid": i, "v": "held"} for i in ids], "before": before, "start": start}


def page(ids: str, before: int, start: bool = False) -> dict:
    return {"messages": [{"uuid": i, "v": "page"} for i in ids], "before": before, "start": start}


@needs_node
def test_a_newer_read_joins_what_is_held_by_uuid():
    cases = [
        (held("", None), page("ab", 0, True)),          # the first read
        (held("abc", 10), page("bcd", 20)),             # the end moved on: what is older stays, with its cursor
        (held("cd", 30), page("bcd", 20)),              # the read reaches further back
        (held("bc", 10), page("bcd", 20)),              # from the same message on
        (held("bc", 10), page("bcd", 0, True)),         # the same, and the file's start
        (held("ab", 10), page("xy", 90)),               # nothing in common: what was read stands
        (held("abc", 10), page("cd", 40)),
        (held("ab", 10), page("", 99)),                 # an empty page with more before it says nothing
        (held("ab", 10), page("", 0, True)),            # an empty thread
    ]
    got = run(merge=cases)["merge"]
    flat = [("".join(m["uuid"] for m in g["items"]), g["before"], g["start"]) for g in got]
    assert flat == [("ab", 0, True), ("abcd", 10, False), ("bcd", 20, False), ("bcd", 10, False), ("bcd", 0, True), ("xy", 90, False),
                    ("abcd", 10, False), ("ab", 10, False), ("", 0, True)]
    assert [m["v"] for m in got[1]["items"]] == ["held", "page", "page", "page"]     # the newer copy of a message wins


# ── why the newest page ──────────────────────────────────────────────────────
def test_after_a_cursor_leaves_out_the_later_reply_of_an_open_turn_and_the_newest_page_has_it(served, monkeypatch):
    monkeypatch.setenv("SALA_CHAT_SESSION", NAME)
    path = transcript_file(served)
    write(path, [human("go", 1), assistant("Working.", 1, stop="tool_use", tool=True), tool_result(1)])
    base = served["url"] + "/api/chat/thread"
    first = get(base)[2]
    assert said(first["messages"]) == [("user", "go")]
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(assistant("Done.", 2)) + "\n")
    assert said(get(f"{base}?after={first['offset']}")[2]["messages"]) == []
    assert said(get(base + "?n=40")[2]["messages"]) == [("user", "go"), ("assistant", "Done.")]
