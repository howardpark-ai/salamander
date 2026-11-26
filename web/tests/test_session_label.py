"""The chat session's header and tab title say its label (no browser here; test_session_label_ui.py holds the page).

The rule: while the open session IS the chat session (SALA_CHAT_SESSION), the header's name and the tab's title say the label api/chat gives it (SALA_CHAT_NAME, else
the last word of its name, capitalized), the text the sidebar's entry already shows, from ONE function (shared.js sessionLabelFrom). The header's tooltip gives the real
name. Every other session, and every other view, is drawn exactly as before: the label is used at one call site only, behind the chat session's own test.

What a wrong answer costs: a header that says one thing while the sidebar says another for the same session; a label that leaks into another session's header, the
Overview, a search hit or a frame title; a label that goes stale after a rename.

Held here without a browser: the function (run in node) and the text of the page's scripts. All names are invented."""

from __future__ import annotations

import json
import shutil
import subprocess

import pytest

from sala_web.app import STATIC

NODE = shutil.which("node")
needs_node = pytest.mark.skipif(not NODE, reason="node is not installed")

SHARED = (STATIC / "shared.js").read_text(encoding="utf-8")
APP_JS = (STATIC / "app.js").read_text(encoding="utf-8")

PROGRAM = r"""
const fs = require('fs');
const text = fs.readFileSync(process.argv[1], 'utf8');
const block = (name) => new RegExp('// <' + name + '>[^\\n]*\\n([\\s\\S]*?)// </' + name + '>').exec(text)[1];
eval(block('label-words') + 'globalThis.api = { sessionLabelFrom };');
const f = globalThis.api.sessionLabelFrom;
const chat = { configured: true, session: 'demo-one', name: 'Demo One' };
console.log(JSON.stringify({
  label: f(chat, 'demo-one'),
  other: f(chat, 'demo-two'),
  unanswered: [f(null, 'demo-one'), f(undefined, 'demo-one')],
  notConfigured: f({ ...chat, configured: false }, 'demo-one'),
  configuredNotTrue: [f({ ...chat, configured: 1 }, 'demo-one'), f({ ...chat, configured: 'yes' }, 'demo-one')],
  noName: [f({ ...chat, name: '' }, 'demo-one'), f({ ...chat, name: undefined }, 'demo-one'), f({ ...chat, name: 7 }, 'demo-one')],
  noSession: f({ configured: true, name: 'Demo One' }, 'demo-one'),
  renamed: f({ ...chat, name: 'Demo Three' }, 'demo-one'),
}));
"""


def run() -> dict:
    out = subprocess.run([NODE, "-e", PROGRAM, str(STATIC / "shared.js")], capture_output=True, text=True, check=True, timeout=60).stdout
    return json.loads(out)


def body_of(src: str, head: str) -> str:
    """The text of the function whose declaration starts with `head`, up to the closing brace at the start of a line."""
    i = src.index(head)
    return src[i:src.index("\n}\n", i)]


# ── the function ─────────────────────────────────────────────────────────────
@needs_node
def test_only_the_chat_session_reads_as_its_label_and_every_other_name_as_itself():
    g = run()
    assert g["label"] == "Demo One"
    assert g["other"] == "demo-two"                              # another session is never relabelled
    assert g["renamed"] == "Demo Three"                          # read live from the last answer, never kept
    assert g["unanswered"] == ["demo-one", "demo-one"]           # before api/chat has answered: the real name
    assert g["notConfigured"] == "demo-one"                      # no chat session configured: the real name
    assert g["configuredNotTrue"] == ["demo-one", "demo-one"]
    assert g["noName"] == ["demo-one"] * 3                       # no label: the real name is the fallback
    assert g["noSession"] == "demo-one"


# ── the label is used in one place, behind the chat session's own test ────────
def test_the_label_function_has_one_definition_and_one_call_in_the_header():
    assert SHARED.count("const sessionLabelFrom =") == 1
    for f in sorted(STATIC.glob("*.js")):
        if f.name not in ("shared.js", "app.js"):
            assert "sessionLabelFrom" not in f.read_text(encoding="utf-8"), f.name     # no other script draws a label
    assert APP_JS.count("sessionLabelFrom(") == 1
    header = body_of(APP_JS, "function updateHeader(s)")
    assert "const shown = isChatRow(s) ? sessionLabelFrom(chatView.data, s.name) : s.name;" in header     # gated: the chat session's own row only
    assert "setTitle(shown);" in header and '$("#title .name").textContent = s.name;' in header           # the tab title; the old line stays as it was
    assert APP_JS.count('el("span", { title: s.name, text: shown })') == 1                                # the tooltip is the real name, text only


def test_every_other_view_and_session_keeps_its_old_header_and_title_code():
    assert APP_JS.count("setTitle(shown)") == 1
    for old in ('setTitle(tl("common.overview"));', 'setTitle(tl("ui.newSession"));', 'setTitle(tl("common.search"));', 'setTitle(name || "sala");', "setTitle(s.name);"):
        assert old in APP_JS, old                                # the Overview, the New session page, the Search page, a session not running, a sleeping session
    assert 'tl("app.notRunning", { name })' in APP_JS and 'tl(when ? "app.sleeping.band" : "app.sleeping.bandNoTime", { name: s.name, when })' in APP_JS
    assert "sessionLabel(" not in APP_JS                         # no second label function: nothing else is drawn from a label
    assert 'a.querySelector(".label").textContent = d.name;' in body_of(APP_JS, "function paintChatEntry()")   # the sidebar entry is as it was


def test_the_real_name_stays_the_key_of_the_route_and_the_entry_link():
    assert 'a.setAttribute("href", "#s=" + encodeURIComponent(d.session));' in body_of(APP_JS, "function paintChatEntry()")
    assert "state.current = s;" in body_of(APP_JS, "function updateHeader(s)")                           # the session object is the real one


# ── a label that changes while the page is open ──────────────────────────────
def test_a_label_that_comes_changes_or_goes_redraws_the_header_of_the_open_chat_session_only():
    marks = body_of(APP_JS, "function chatMarks(d)")
    assert "const was = chatEntryOn(), label = chatLabelKey(), wasHere = isChatRow(state.current);" in marks     # taken before the answer replaces the data: a label that goes leaves isChatRow false
    assert "if (chatLabelKey() !== label && (wasHere || isChatRow(state.current))) updateHeader(state.current);" in marks
    assert 'const chatLabelKey = () => (chatEntryOn() ? chatView.data.session + "\\n" + chatView.data.name : "");' in APP_JS
    assert APP_JS.count("chatLabelKey()") == 2                                                           # the one read of api/chat carries the rename
    assert "function pollChatMarks() { if (!document.hidden) loadChatMarks(); }" in APP_JS and "setInterval(pollChatMarks, CHAT_MARKS_MS);" in APP_JS


def test_the_labels_span_is_cut_by_its_own_ellipsis_and_the_rule_matches_only_that_span():
    css = (STATIC / "style.css").read_text(encoding="utf-8")
    rule = "#title .name > span[title] { display: inline-block; max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; vertical-align: bottom; }"
    assert css.count(rule) == 1                                  # the span's own box ends inside the bar, so no box of the header runs past the window
    assert css.count("#title .name > span") == 1                 # no other rule touches it, and nothing else in the header is styled for the label
