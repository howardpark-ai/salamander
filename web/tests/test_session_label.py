"""The name drawn for a session: one function, the label the sidebar's entry shows (no browser here; test_session_label_ui.py holds the page).

The rule: the chat session (SALA_CHAT_SESSION) is drawn under the label api/chat gives it (SALA_CHAT_NAME, else the last word of its name, capitalized).
The sidebar's entry has always shown it; the header at the top of the session view, the tab's title and every other place that draws the session's name as a
title for a person take the SAME label from the SAME function (shared.js sessionLabelFrom, called through app.js sessionLabel), never a second copy of the
logic. Only what is DRAWN changes: the real name stays the key of the route (#s=<name>), every api call, every link and every queued message, and the header's
tooltip gives it. A name a person types or copies (the New session form's pickers) stays the real one.

What a wrong answer costs: a header that says one thing while the sidebar says another for the same session, a link or a message sent to the label, a
label that goes stale in the header when it is renamed while the page is open.

Held here without a browser: the label function (run in node), and the text of the page's script. All names are invented."""

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
SESSIONS_JS = (STATIC / "sessions.js").read_text(encoding="utf-8")
SEARCH_JS = (STATIC / "search.js").read_text(encoding="utf-8")
EN = (STATIC / "i18n-en.js").read_text(encoding="utf-8")

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
def test_the_chat_session_reads_as_its_label_and_every_other_name_as_itself():
    g = run()
    assert g["label"] == "Demo One"
    assert g["other"] == "demo-two"                              # another session is never relabelled
    assert g["renamed"] == "Demo Three"                          # the label is read live from the last answer, never kept
    assert g["unanswered"] == ["demo-one", "demo-one"]           # before api/chat has answered: the real name
    assert g["notConfigured"] == "demo-one"                      # no chat session configured: the real name
    assert g["configuredNotTrue"] == ["demo-one", "demo-one"]
    assert g["noName"] == ["demo-one"] * 3                       # no label: the real name is the fallback
    assert g["noSession"] == "demo-one"


def test_there_is_one_label_function_and_nothing_else_decides_a_label():
    assert SHARED.count("const sessionLabelFrom =") == 1
    assert APP_JS.count("function sessionLabel(") == 1
    assert "function sessionLabel(name) { return sessionLabelFrom(chatView.data, name); }" in APP_JS
    for src in (APP_JS, SESSIONS_JS, SEARCH_JS):                  # no second copy of the logic: nobody else reads api/chat's name to draw a session
        assert "chatView.data.name" not in src
    assert "textContent = d.name" not in body_of(APP_JS, "function paintChatEntry()")


# ── every place that draws the name goes through it ──────────────────────────
def test_the_sidebar_entry_the_header_and_the_tab_title_take_the_same_label():
    assert 'a.querySelector(".label").textContent = sessionLabel(d.session);' in body_of(APP_JS, "function paintChatEntry()")
    header = body_of(APP_JS, "function updateHeader(s)")
    assert "setHeaderName(sessionLabel(s.name), s.name);" in header and "setTitle(sessionLabel(s.name));" in header
    # the header's name is written in one place: the one that sets the tooltip with it
    assert '$("#title .name").textContent' not in APP_JS and 'const n = $("#title .name");' in body_of(APP_JS, "function setHeaderName(")
    assert "textContent = s.name" not in header


def test_the_header_tooltip_gives_the_real_name_only_where_a_label_stands_in():
    fn = body_of(APP_JS, "function setHeaderName(")
    assert "if (real && real !== text) n.title = real; else n.removeAttribute(\"title\");" in fn
    assert "n.textContent = text;" in fn and "innerHTML" not in fn          # text only, never markup


def test_a_sleeping_session_and_one_not_running_are_drawn_under_the_label_too():
    head = body_of(APP_JS, "function paintSleepHead(s)")
    assert "setHeaderName(sessionLabel(s.name), s.name);" in head and "setTitle(sessionLabel(s.name));" in head
    assert "paintSleepHead(s);" in body_of(APP_JS, "async function showSleeping(s)")
    retitle = body_of(APP_JS, "function retitle()")
    assert "else if (sleeperHere()) paintSleepHead(sleeperHere());" in retitle
    assert 'tl("app.notRunning", { name: sessionLabel(state.selected) })' in retitle and "setTitle(state.selected ? sessionLabel(state.selected) : \"sala\");" in retitle
    assert 'setTitle(name ? sessionLabel(name) : "sala");' in APP_JS
    band = body_of(APP_JS, "function paintSleeping(s)")
    assert "const who = sessionLabel(s.name);" in band and "{ name: s.name" not in band
    assert 'tl("app.sleeping.body", { name: sessionLabel(s.name), when })' in body_of(APP_JS, "function paintSleepNote(s)")
    assert 'tl("app.pend.held", { name: sessionLabel(p.session) })' in APP_JS


def test_the_rows_the_strip_the_terminal_frame_and_the_search_take_it_too():
    assert 'el("span", { class: "label", text: sessionLabel(s.name) })' in body_of(APP_JS, "function sessRow(s)")
    assert 'tl("app.sess.actions", { name: sessionLabel(s.name) })' in APP_JS and "{ name: s.name }) }" not in APP_JS
    assert 'tl("chat.kept.toggle", { name: sessionLabel(d.session) })' in body_of(APP_JS, "function paintChatStrip()")
    assert APP_JS.count('tl("term.frameTitleFor", { name: sessionLabel(') == 3        # the frame when it is made, after a language change, after a label change
    assert 'tl("chat.src.session", { name: sessionLabel(src.name) })' in APP_JS
    assert "link.textContent = sessionLabel(r.name);" in body_of(SESSIONS_JS, "function sessionRow(r)")
    assert "name: (r) => sessionLabel(r.name)," in SESSIONS_JS
    assert SESSIONS_JS.count("sessionLabel(s.name)") == 2                            # the spend cards' session lists
    assert 'text: sessionLabel(h.name)' in SEARCH_JS and 'tl("srch.hit.open", { name: sessionLabel(h.name) })' in SEARCH_JS


def test_the_real_name_stays_the_key_of_the_route_the_links_and_the_calls():
    row = body_of(APP_JS, "function sessRow(s)")
    assert 'href: "#s=" + encodeURIComponent(s.name),' in row and '"data-key": s.name' in row and "title: `${s.name} · " in row
    assert 'a.setAttribute("href", "#s=" + encodeURIComponent(d.session));' in body_of(APP_JS, "function paintChatEntry()")
    assert 'link.href = "#s=" + encodeURIComponent(r.name);' in SESSIONS_JS
    assert 'href: "#side=from:" + s.name' in APP_JS                                      # the fork link is by the real name


# ── a label that changes while the page is open ──────────────────────────────
def test_a_label_that_comes_changes_or_goes_draws_every_title_again():
    marks = body_of(APP_JS, "function chatMarks(d)")
    assert "const was = chatEntryOn(), key = chatLabelKey();" in marks and "if (chatLabelKey() !== key) relabel();" in marks
    assert 'return d && d.configured ? d.session + "\\n" + d.name : "";' in APP_JS      # the key changes with the session, the label or the entry going
    relabel = body_of(APP_JS, "function relabel()")
    for needle in ("retitle();", "overview.redraw();", 'tl("term.frameTitleFor", { name: sessionLabel(state.current.name) })', "redrawPending(p)", "paintSleeping(sl)"):
        assert needle in relabel, needle
    assert "api/chat" in APP_JS and "CHAT_MARKS_MS" in APP_JS                          # the read that carries a rename is polled


def test_no_new_text_is_added_for_a_person_to_translate():
    for key in ("app.notRunning", "app.sleeping.band", "chat.kept.toggle", "term.frameTitleFor", "app.sess.actions"):
        assert f'"{key}"' in EN                                                        # the same keys, now fed the label
