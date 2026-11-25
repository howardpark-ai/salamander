"""The chat session is sala's own view of a session with three additions (no browser here; test_chat_session_view_ui.py holds the page).

The rule: the session the server is set to talk to (SALA_CHAT_SESSION) is opened like every other session, with the same header, thread, composer (box, attach button,
image paste), spacing and buttons. What it adds is a short list, and a difference outside the list is a defect:
  - its entry, the first line of the sidebar's views above New session, with its name, a small "chat", a working dot and a red count of what waits on the owner;
  - the strip above the thread (what waits on the owner, what is in motion, the kept-back switch with its count), outside #chat because showTail replaces #chat's children;
  - the assistant's messages capped to the left, as on the first page.
The server marks the session with `"chat": true` in api/sessions, and only that session: every other session's payload is as it was. The kept-back switch
works (the server keeps the turns the owner did not start back: test_chatkeep.py; the page draws each as one quiet line the switch shows or hides), and the first page (/chat, chat.html, chat.js, chat.css) is untouched until it is retired.

What a wrong answer costs: a second page drawn to look like sala's, a strip that showTail wipes on the first stream event, a name squeezed to nothing in the narrow drawer,
two rows for one session, a sideways scroll bar on a phone, or a first page that stopped working before its replacement is live.

Held here without a browser: the payload, and the text of the page, its script and its style sheet. All names are invented."""

from __future__ import annotations

import json
import re
import urllib.request

import pytest

from sala_web import sessions as S
from sala_web.app import STATIC
from conftest import NAME

INDEX = (STATIC / "index.html").read_text(encoding="utf-8")
APP_JS = (STATIC / "app.js").read_text(encoding="utf-8")
STYLE = (STATIC / "style.css").read_text(encoding="utf-8")
EN = (STATIC / "i18n-en.js").read_text(encoding="utf-8")
KO = (STATIC / "i18n-ko.js").read_text(encoding="utf-8")


def session(name: str) -> S.Session:
    return S.Session(pid=4242, session_id="s-1", name=name, cwd="/srv/demo", status="idle", tmux="x:@0.%0")


def body_of(src: str, head: str) -> str:
    """The text of the function whose declaration starts with `head`, up to the closing brace at the start of a line."""
    i = src.index(head)
    return src[i:src.index("\n}\n", i)]


# ── the payload ──────────────────────────────────────────────────────────────
def test_only_the_chat_session_carries_the_chat_key_and_no_other_key_changes(monkeypatch):
    monkeypatch.setenv("SALA_CHAT_SESSION", "demo-chat")
    plain = session("demo-other").to_json()
    assert "chat" not in plain
    chat = session("demo-chat").to_json()
    assert chat["chat"] is True
    assert {k: v for k, v in chat.items() if k != "chat"} == {**plain, "name": "demo-chat"}   # nothing else differs between the two


@pytest.mark.parametrize("value", [None, "", "not a name!", "demo-chat-2"])
def test_no_session_carries_it_when_none_is_configured_or_the_name_differs(monkeypatch, value):
    if value is None:
        monkeypatch.delenv("SALA_CHAT_SESSION", raising=False)
    else:
        monkeypatch.setenv("SALA_CHAT_SESSION", value)
    assert "chat" not in session("demo-chat").to_json()


def test_a_sleeping_chat_session_carries_it_too(monkeypatch):
    monkeypatch.setenv("SALA_CHAT_SESSION", "demo-chat")
    s = session("demo-chat")
    s.sleeping = "2026-10-14T03:00:00Z"
    assert s.to_json()["chat"] is True and s.to_json()["sleeping"] == s.sleeping


def groups(served) -> list[dict]:
    with urllib.request.urlopen(served["url"] + "/api/sessions", timeout=10) as r:
        d = json.load(r)
    return [x for g in d["groups"] for x in g["sessions"]]


def test_api_sessions_marks_the_configured_session_only(served, monkeypatch):
    monkeypatch.delenv("SALA_CHAT_SESSION", raising=False)
    assert all("chat" not in x for x in groups(served))
    monkeypatch.setenv("SALA_CHAT_SESSION", "demo-someone-else")
    assert all("chat" not in x for x in groups(served))
    monkeypatch.setenv("SALA_CHAT_SESSION", NAME)
    marked = [x for x in groups(served) if x.get("chat")]
    assert [x["name"] for x in marked] == [NAME]


# ── the markup ───────────────────────────────────────────────────────────────
def test_the_entry_is_the_first_line_of_the_views_above_new_session():
    top = INDEX[INDEX.index('<nav class="side-top"'):INDEX.index("</nav>", INDEX.index('<nav class="side-top"'))]
    ids = re.findall(r'<(?:a|button) id="(side-[a-z]+)"', top)
    assert ids[0] == "side-chat" and ids.index("side-chat") < ids.index("side-new") < ids.index("side-ovw"), ids
    entry = re.search(r'<a id="side-chat"[^>]*>.*?</a>', top, re.S).group(0)
    assert 'class="sess side-ovw side-chat"' in entry and " hidden " in entry, "a row like the others, hidden until api/chat says a session is set"
    assert re.search(r'<svg width="18" height="18" viewBox="0 0 24 24"[^>]*stroke-width="2" stroke-linecap="round" stroke-linejoin="round"', entry)
    assert entry.count('class="label"') == 1 and 'class="role"' in entry and 'class="dot busy" hidden' in entry and 'class="wchip" hidden' in entry
    assert 'data-i18n="ui.side.chatRole"' in entry and 'data-i18n-title="ui.side.chatTip"' in entry
    assert "#chat" not in entry, "its href is the session's own #s=<name>, set from api/chat"


def test_the_strip_is_a_sibling_before_chat_and_not_inside_it():
    pane = INDEX[INDEX.index('<section id="chat-pane"'):INDEX.index("</section>", INDEX.index('<section id="chat-pane"'))]
    strip, chat = pane.index('<div id="chat-strip"'), pane.index('<div id="chat">')
    assert strip < chat
    assert re.search(r'<div id="chat-strip"[^>]*hidden></div>', pane), "closed before #chat opens: not a parent of it, and not inside it"
    assert len(re.findall(r'id="chat-strip"', INDEX)) == 1
    # showTail and leaveSession replace #chat's children; nothing there touches the strip
    assert "chat-strip" not in body_of(APP_JS, "function showTail(") and "chat-strip" not in body_of(APP_JS, "function leaveSession(")


def test_the_composer_is_sala_s_own_and_nothing_here_draws_another():
    ids = re.findall(r'\sid="([^"]+)"', INDEX)
    assert len(ids) == len(set(ids)), sorted({i for i in ids if ids.count(i) > 1})
    for one in ("composer", "composer-editor", "attach", "file-input", "send", "chips"):
        assert ids.count(one) == 1, one
    assert "<textarea" not in re.search(r'<div id="chat-strip".*?</div>', INDEX).group(0)
    assert "static/chat.js" not in INDEX and "static/chat.css" not in INDEX, "the first page's script and sheet are not loaded into sala's page"
    assert "static/chat.js" not in APP_JS and "SalaChat" not in APP_JS


# ── the script ───────────────────────────────────────────────────────────────
def test_the_flag_decides_the_strip_and_the_body_class_and_the_entry_hides_the_sessions_own_row():
    assert "const chatSelected = () =>" in APP_JS and "s.chat === true" in APP_JS
    sync = body_of(APP_JS, "function chatSync()")
    assert 'document.body.classList.toggle("chat-session", flagged)' in sync and "strip.hidden = !on" in sync
    # opening, leaving and a refreshed list all re-decide it
    for head in ("function selectSession(", "function leaveSession()", "async function loadSessions()"):
        assert "chatSync()" in body_of(APP_JS, head), head
    vis = body_of(APP_JS, "const visibleSessions = (g) => {").replace("\n};", "")
    assert "!isChatRow(s)" in vis
    assert "const isChatRow = (s) => !!s && s.chat === true && chatEntryOn();" in APP_JS, "the row stays visible while no entry exists"


def test_the_chat_sessions_unread_count_stays_out_of_the_unread_total():
    assert "unreadTotal(unreadSessions(), state.selected)" in body_of(APP_JS, "function paintUnreadEntry()")
    assert "unreadTotal(unreadSessions(), state.selected)" in body_of(APP_JS, "function renderSidebar()")
    assert "liveSessions().filter((s) => !isChatRow(s))" in APP_JS


def test_the_marks_come_from_api_chat_on_a_timer_that_pauses_while_the_page_is_hidden():
    ms = int(re.search(r"const CHAT_MARKS_MS = (\d+)", APP_JS).group(1))
    assert 20000 <= ms <= 30000
    assert re.search(r"function pollChatMarks\(\) \{ if \(!document\.hidden\) loadChatMarks\(\); \}", APP_JS)
    assert "setInterval(pollChatMarks, CHAT_MARKS_MS)" in APP_JS, "runs whether or not the chat session is open"
    assert 'fetch("api/chat"' in body_of(APP_JS, "async function loadChatMarks()")
    # the open strip is read again after stream activity, debounced
    soon = body_of(APP_JS, "function chatStripSoon()")
    assert "setTimeout" in soon and "CHAT_STRIP_MS" in soon and "!chatSelected()" in soon
    assert APP_JS.count("chatStripSoon();") >= 3, "after a reset, an append and a status event of the stream"


def test_the_entry_names_the_session_from_api_chat_and_the_drawer_closes_after_it():
    paint = body_of(APP_JS, "function paintChatEntry()")
    assert 'a.setAttribute("href", "#s=" + encodeURIComponent(d.session))' in paint
    assert 'a.classList.toggle("selected", here)' in paint and 'a.setAttribute("aria-current", "page")' in paint and 'a.removeAttribute("aria-current")' in paint
    assert "a.hidden = !on" in paint and "dot.hidden = !busy" in paint and "chip.hidden = !waiting" in paint
    assert 'for (const id of ["#side-chat", "#side-ovw", "#side-new"])' in APP_JS


def test_the_switch_works_and_the_count_floors_with_a_plus():
    build = body_of(APP_JS, "function buildChatStrip()")
    assert "disabled" not in build and "keptOff" not in build and "not active" not in build, "the switch is live: nothing says it is off"
    assert 'addEventListener("change"' in build and "chatView.kept = sw.checked" in build and 'class: "kept-toggle"' in build
    paint = body_of(APP_JS, "function paintChatStrip()")
    assert '"chat.kept.floor" : "chat.kept.count"' in paint and "d.keptLines ?? d.keptToday" in paint
    assert 'classList.toggle("chat-kept-on", flagged && chatView.kept)' in body_of(APP_JS, "function chatSync()")
    for key in ("chat.wait.h", "chat.wait.sub", "chat.wait.none", "chat.wait.note", "chat.wait.answer", "chat.wait.new", "chat.motion.h", "chat.motion.none", "chat.kept.toggle"):
        assert f'"{key}"' in APP_JS, key


# ── the style sheet ──────────────────────────────────────────────────────────
def rules(css: str) -> list[tuple[str, str]]:
    """(selector, body) of every flat rule of a style sheet (a rule inside an @media block is read as the rule it is)."""
    css = re.sub(r"/\*.*?\*/", "", css, flags=re.S)
    out = []
    for m in re.finditer(r"([^{}]+)\{([^{}]*)\}", css):
        sel = m.group(1).strip()
        if sel.startswith("@media"):          # "@media (...) { sel" arrives as one selector: the part after the media query's own bracket
            sel = sel.split(")", 1)[1].strip() if ")" in sel else sel
        out.append((sel, m.group(2)))
    return out


def test_the_left_cap_is_one_rule_on_the_assistants_text_under_the_chat_session_class():
    caps = [(s, b) for s, b in rules(STYLE) if "chat-session" in s and ".msg.assistant .md" in s]
    assert len(caps) == 1 and "max-width: 68ch" in caps[0][1] and "#chat" in caps[0][0], caps


def test_the_strip_s_rules_are_scoped_to_it_and_the_entry_has_a_floor_for_its_name():
    first_page = re.compile(r"\.(wait|wait-\w+|sec-head|motion|mo|mo-list|kept-toggle|kept-row|answer|new|count)(?![\w-])")
    start = STYLE.index("The strip's rules are the first page's")
    block = STYLE[STYLE.index("*/", start) + 2:STYLE.index("@media (pointer: coarse) { #chat-strip")]
    for sel, _ in rules(block):
        sel = sel.strip()
        assert sel.startswith("#chat-strip") and ", " not in re.sub(r"\([^)]*\)", "", sel).replace(", #chat-strip", ""), sel
    for sel, _ in rules(STYLE):                 # and the first page's bare class names are nowhere else in the sheet
        for part in re.sub(r"\([^)]*\)", "()", sel).split(","):
            assert not first_page.match(part.strip()), part
    entry = " ".join(b for s, b in rules(STYLE) if s == ".side-chat .label")
    assert "min-width: 48px" in entry, "a long name gives way to its ellipsis, never to nothing"
    chip = " ".join(b for s, b in rules(STYLE) if s.startswith(".wchip") and "hidden" not in s)
    assert "var(--waiting)" in chip and "var(--waiting-text)" in chip, "the red of what waits on the owner, not the orange unread count"


def test_nothing_the_chat_session_adds_scrolls_sideways():
    mine = [(s, b) for s, b in rules(STYLE) if "#chat-strip" in s or "chat-session" in s or ".side-chat" in s or ".wchip" in s or "#chat-pane" in s and "chat-session" in s]
    assert len(mine) > 20
    for sel, body in mine:
        assert not re.search(r"overflow(-x)?\s*:\s*(scroll|auto)", body), (sel, body)
    strip = " ".join(b for s, b in rules(STYLE) if "#chat-strip" in s)
    assert "overflow-wrap: anywhere" in strip and "min-width: 0" in strip


def test_the_first_page_keeps_its_own_copy_of_what_the_strip_copied():
    """The strip's rules and pieces were copied into sala's own page, not moved: /chat (chat.html, chat.js, chat.css) still carries its own and knows nothing of the
    strip or the body class, so it works as before until a later step retires it (that step removes this test)."""
    css = (STATIC / "chat.css").read_text(encoding="utf-8")
    js = (STATIC / "chat.js").read_text(encoding="utf-8")
    html = (STATIC / "chat.html").read_text(encoding="utf-8")
    for piece in (".kept-toggle", ".wait-list", ".mo-list", ".sec-head"):
        assert f"body.chat-page {piece}" in css, piece
    for piece in ('"wait-list"', '"mo-list"', '"kept-toggle"'):
        assert piece in js, piece
    for name, text in (("chat.css", css), ("chat.js", js), ("chat.html", html)):
        assert "chat-strip" not in text and "chat-session" not in text and "side-chat" not in text, name


# ── the words ────────────────────────────────────────────────────────────────
@pytest.mark.parametrize("key", ["ui.side.chatRole", "ui.side.chatTip", "ui.side.chatWait.one", "ui.side.chatWait.other"])
def test_the_new_strings_are_in_english_and_in_korean_as_escapes(key):
    ko_key = key.replace(".one", ".other")
    assert f'"{key}": ' in EN and f'"{ko_key}": ' in KO
    line = next(l for l in KO.splitlines() if l.lstrip().startswith(f'"{ko_key}":'))
    assert re.search(r"\\u[0-9a-f]{4}", line) and line.isascii(), line


@pytest.mark.parametrize("key", ["chat.wait.h", "chat.wait.sub", "chat.wait.none", "chat.wait.note", "chat.wait.answer", "chat.wait.new", "chat.motion.h", "chat.motion.none",
                                 "chat.kept.toggle", "chat.kept.count", "chat.kept.floor", "chat.kept.open", "chat.state.busy",
                                 "chat.src.sala", "chat.src.board", "chat.src.session", "chat.src.task", "chat.src.system", "chat.src.other"])
def test_the_strips_strings_are_the_first_pages_own(key):
    assert f'"{key}": ' in EN and f'"{key}": ' in KO


def test_the_kept_lines_are_drawn_by_one_function_in_sala_s_own_renderer_and_hidden_unless_the_switch_is_on():
    assert 'if (m.role === "kept") return renderKept(m, into);' in body_of(APP_JS, "function renderMessage(")
    kept = body_of(APP_JS, "function renderKept(")
    assert "m.gone" in kept and "old.replaceWith(box)" in kept and "appendToChat(box, into)" in kept and "return false" in kept   # never counted as a new message
    assert "innerHTML" not in kept, "what a session wrote is set as text"
    assert APP_JS.count("function renderMessage(") == 1 and "chat.js" not in INDEX and "chat.css" not in INDEX, "no second renderer, no second page"
    shown = [b for s, b in rules(STYLE) if s == "#chat .msg.kept"]
    assert shown and "display: none" in shown[0], "off by default, whatever the session"
    on = [b for s, b in rules(STYLE) if s == "body.chat-kept-on #chat .msg.kept"]
    assert on and "display: flex" in on[0] and not re.search(r"overflow(-x)?\s*:\s*(scroll|auto)", on[0])
