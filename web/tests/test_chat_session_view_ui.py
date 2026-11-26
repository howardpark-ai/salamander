"""The chat session's own view in a headless Chromium (the text and the payload are test_chat_session_view.py).

The rule: the chat session (SALA_CHAT_SESSION) opens in sala's own view of a session, with three additions: its entry in the sidebar, the strip above the thread
and the assistant's text capped to the left. Nothing else differs, and NO SIDEWAYS SCROLL at any width, whatever a session or the board wrote.

Held here, at 1280 x 800 and 390 x 844 (the width rule also at 360 and 320), with api/chat replaced in the page and the real server behind everything else:
  - the entry is the first line of the views above New session, with its name, "chat", a working dot and a red count; it is hidden when no session is configured;
  - a click opens #s=<name> (selected, aria-current), a phone's drawer closes, the session's own row is hidden while the entry exists and shown when it does not,
    and the Overview still lists the session;
  - the strip shows what waits on the owner, what is in motion and the kept-back switch with its count, sits before #chat in #chat-pane, survives the thread
    being replaced, and is hidden for any other session;
  - one composer, and an image pasted into it is one chip; a working session shows the spinner with no code of its own;
  - the chat session and another session, given the same transcript, differ only in the strip and the cap (header, composer, bubbles, copy button, buttons);
  - no sideways scroll with hostile text (a 300-character word, a long address, wide code, a wide table) in the thread, a waiting subject and a motion line,
    with the drawer open and shut.

What a wrong answer costs: a chat page that looks almost like sala's and drifts from it, a strip a stream event wipes, two rows for one session, a name squeezed to
nothing in the drawer, a phone page that scrolls sideways. Runs in a headless Chromium when one is installed (conftest.py: `served`, `browser`), else is skipped; GitHub
CI runs it. All names are invented."""

from __future__ import annotations

import json
import time

import pytest

from conftest import CHAT_READY, NAME, transcript_file, transcript_line
from test_board_items_ui import wait_for
from test_composer_attach import WAIT_CHIPS
from test_unread_filter import SIDE_IN, show_panel

WORD = "w" * 300
URL = "https://example.com/" + "a-very-long-path-segment/" * 12 + "end?query=" + "q" * 120
CODE = "const veryLongLine = " + "someFunction(argumentNumberOne, argumentNumberTwo, argumentNumberThree) + " * 6 + "done;"
TABLE = "| " + " | ".join(f"column-{i}-with-a-long-heading" for i in range(8)) + " |\n|" + "---|" * 8 + "\n| " + " | ".join("x" * 40 for _ in range(8)) + " |\n"
PHONE, DESKTOP = (390, 844), (1280, 800)
SIZES = [pytest.param(PHONE, id="phone"), pytest.param(DESKTOP, id="desktop")]


def api_chat(**over) -> dict:
    """What GET api/chat answers for the chat session (chatpage.assemble's shape), with what a test changes."""
    d = {"configured": True, "session": NAME, "name": "Ada", "present": "live", "busy": False,
         "keptToday": 7, "keptTodayFloor": False,
         "waiting": [{"id": "item#1", "subject": "Approve the demo budget", "url": "https://example.com/moves/1"},
                     {"id": "item#2", "subject": "Pick a venue", "url": "https://example.com/moves/2"}],
         "motion": [{"text": "drawing slide 4", "at": int(time.time())}]}
    d.update(over)
    return d


def stub(doc: dict) -> str:
    """api/chat answers `window.__chat` (a test changes it live); the rest of the page talks to the real server."""
    return """(() => {
  const real = window.fetch.bind(window), json = (o) => new Response(JSON.stringify(o), { headers: { "Content-Type": "application/json" } });
  window.__chat = %s;
  window.fetch = (url, opts) => String(url).startsWith("api/chat") ? Promise.resolve(json(window.__chat)) : real(url, opts);
})()""" % json.dumps(doc)


def hostile_transcript() -> str:
    reply = f"Here: {WORD}\n\n{URL}\n\n```\n{CODE}\n```\n\n{TABLE}\n`{'c' * 200}`\n"
    # the owner's own turn (a line he typed: the chat session keeps back a user line that has no human origin; the hostile text inside a kept line is test_chat_kept_ui.py's)
    return (transcript_line("user", [{"type": "text", "text": f"{WORD} {URL}"}], "h-1", human=True)
            + transcript_line("assistant", [{"type": "text", "text": reply}], "h-2", model="claude-opus-5-5"))


def code_transcript() -> str:
    return (transcript_line("user", [{"type": "text", "text": "show me the code"}], "p-1", human=True)
            + transcript_line("assistant", [{"type": "text", "text": "Here it is.\n\n```sh\nsala ls\n```\n\nAnd a second paragraph that is long enough to wrap onto a few "
                                             "lines in a narrow window, so the width of the text matters.\n"}], "p-2", model="claude-opus-5-5"))


def open_page(browser, served, monkeypatch, size, doc=None, chat=NAME, hash_=None, ready=True) -> None:
    """The page at `size` with SALA_CHAT_SESSION=`chat` (None: unset) and api/chat answering `doc` (None: the real answer)."""
    if chat is None:
        monkeypatch.delenv("SALA_CHAT_SESSION", raising=False)
    else:
        monkeypatch.setenv("SALA_CHAT_SESSION", chat)
    browser.send("Page.enable")
    browser.send("Page.navigate", {"url": "about:blank"})           # a second open in one test must be a real load, not a change of the hash
    assert wait_for(browser, "location.href === 'about:blank'", 10.0)
    if doc is not None:
        browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": stub(doc)})
    browser.width, browser.height = size
    url = f"{served['url']}/{hash_ if hash_ is not None else '#s=' + NAME}"
    if size[0] < 700:
        browser.open(url, dark=True)
    else:   # a desktop: the sidebar pinned open
        browser.send("Emulation.setDeviceMetricsOverride", {"width": size[0], "height": size[1], "deviceScaleFactor": 1, "mobile": False})
        browser.send("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-color-scheme", "value": "dark"}]})
        browser.send("Page.navigate", {"url": url})
    browser.wait_ready(CHAT_READY if ready else "")


def phone(size) -> bool:
    return size[0] < 700


def drawer_open(browser) -> None:
    if browser.evaluate("document.getElementById('sidebar').getBoundingClientRect().left") != 0:
        browser.evaluate("document.querySelector('#side-open').click(); ''")
    assert wait_for(browser, SIDE_IN, 5.0)


ENTRY = """(() => { const a = document.querySelector('#side-chat'), q = (s) => a.querySelector(s), r = a.getBoundingClientRect();
  const probe = document.createElement('i'); probe.style.background = 'var(--waiting)'; document.body.append(probe);
  const waiting = getComputedStyle(probe).backgroundColor; probe.remove();
  const chip = q('.wchip'), dot = q('.dot'), label = q('.label'), role = q('.role');
  const vis = [...document.querySelectorAll('.side-top > *')].filter((e) => !e.hidden).map((e) => e.id);
  return { hidden: a.hidden, vis, href: a.getAttribute('href'), label: label.textContent, labelW: label.getBoundingClientRect().width,
           cut: label.scrollWidth > label.clientWidth, role: role.textContent, roleRight: role.getBoundingClientRect().right,
           dot: !dot.hidden, chip: chip.hidden ? null : chip.textContent, chipRight: chip.hidden ? 0 : chip.getBoundingClientRect().right,
           chipBg: getComputedStyle(chip).backgroundColor, waiting, right: r.right, left: r.left, top: r.top, bottom: r.bottom,
           newTop: document.querySelector('#side-new').getBoundingClientRect().top, selected: a.classList.contains('selected'),
           current: a.getAttribute('aria-current'), svgs: a.querySelectorAll(':scope > svg').length }; })()"""


# ── the entry ────────────────────────────────────────────────────────────────
@pytest.mark.parametrize("size", SIZES)
def test_the_entry_is_the_first_line_above_new_session_with_its_marks(served, browser, monkeypatch, size):
    open_page(browser, served, monkeypatch, size, api_chat(busy=True), hash_="#sessions", ready=False)
    show_panel(browser)
    assert wait_for(browser, "!document.querySelector('#side-chat').hidden", 8.0)
    e = browser.evaluate(ENTRY)
    assert e["vis"][:3] == ["side-chat", "side-new", "side-ovw"], e
    assert e["bottom"] <= e["newTop"] + 1 and e["svgs"] == 1, e
    assert (e["label"], e["role"], e["dot"], e["chip"], e["href"]) == ("Ada", "chat", True, "2", "#s=" + NAME), e
    assert e["chipBg"] == e["waiting"], e                    # the red of the waiting chips, not the orange unread count
    # the marks follow a changed answer: no working dot, one item in Your move, the singular word
    browser.evaluate("window.__chat = Object.assign({}, window.__chat, { busy: false, waiting: window.__chat.waiting.slice(0, 1) }); loadChatMarks(); ''")
    assert wait_for(browser, "document.querySelector('#side-chat .dot').hidden && document.querySelector('#side-chat .wchip').textContent === '1'", 8.0)
    assert browser.evaluate("document.querySelector('#side-chat .wchip').title") == "1 item in Your move"
    browser.evaluate("window.__chat = Object.assign({}, window.__chat, { waiting: [] }); loadChatMarks(); ''")
    assert wait_for(browser, "document.querySelector('#side-chat .wchip').hidden", 8.0)


@pytest.mark.parametrize("size", SIZES)
def test_the_entry_is_hidden_when_no_chat_session_is_configured(served, browser, monkeypatch, size):
    open_page(browser, served, monkeypatch, size, api_chat(configured=False), chat=None, hash_="#sessions", ready=False)
    show_panel(browser)
    assert browser.evaluate("document.querySelector('#side-chat').hidden")
    assert browser.evaluate("[...document.querySelectorAll('.side-top > *')].filter((e) => !e.hidden)[0].id") == "side-new"


@pytest.mark.parametrize("size", SIZES)
def test_a_long_name_is_cut_by_the_ellipsis_and_the_marks_stay_whole(served, browser, monkeypatch, size):
    open_page(browser, served, monkeypatch, size, api_chat(name="A" * 40, busy=True), hash_="#sessions", ready=False)
    widths = [size[0]] if not phone(size) else [390, 360, 320]
    for w in widths:
        browser.send("Emulation.setDeviceMetricsOverride", {"width": w, "height": size[1], "deviceScaleFactor": 1, "mobile": phone(size)})
        assert wait_for(browser, f"document.documentElement.clientWidth === {w}", 10.0)
        show_panel(browser)
        assert wait_for(browser, "!document.querySelector('#side-chat').hidden", 8.0)
        e = browser.evaluate(ENTRY)
        assert e["cut"] and e["labelW"] >= 48, (w, e)         # cut by its ellipsis, never squeezed to nothing
        assert e["roleRight"] <= e["right"] + 0.5 and e["chipRight"] <= e["right"] + 0.5 and e["dot"], (w, e)
        if phone(size):
            assert e["right"] <= min(300, 0.85 * w) + 1, (w, e)


@pytest.mark.parametrize("size", SIZES)
def test_a_click_opens_the_sessions_own_view_and_a_phones_drawer_closes(served, browser, monkeypatch, size):
    open_page(browser, served, monkeypatch, size, api_chat(), hash_="#sessions", ready=False)
    show_panel(browser)
    assert wait_for(browser, "!document.querySelector('#side-chat').hidden", 8.0)
    browser.evaluate("document.querySelector('#side-chat').click(); ''")
    assert wait_for(browser, "location.hash === '#s=" + NAME + "'", 8.0)
    browser.wait_ready(CHAT_READY)
    e = browser.evaluate(ENTRY)
    assert e["selected"] and e["current"] == "page", e
    assert browser.evaluate("document.body.classList.contains('overview-open')") is False
    assert browser.evaluate("state.selected") == NAME and browser.evaluate("document.querySelectorAll('#top').length") == 1      # sala's own title bar, the one header
    if phone(size):
        assert wait_for(browser, "document.getElementById('sidebar').getBoundingClientRect().left < 0", 5.0), "the drawer closes"
    # leaving it clears both
    browser.evaluate("go('#sessions'); ''")
    assert wait_for(browser, "!document.querySelector('#side-chat').classList.contains('selected') && !document.querySelector('#side-chat').hasAttribute('aria-current')", 8.0)


@pytest.mark.parametrize("size", SIZES)
def test_the_sessions_row_is_hidden_while_the_entry_exists_and_the_overview_still_lists_it(served, browser, monkeypatch, size):
    open_page(browser, served, monkeypatch, size, api_chat(), hash_="#sessions", ready=False)
    show_panel(browser)
    assert wait_for(browser, "!document.querySelector('#side-chat').hidden", 8.0)
    wait_for(browser, "typeof state !== 'undefined' && state.byName.has('" + NAME + "')", 8.0)
    row = f"document.querySelectorAll('#session-list .sess[data-key=\"{NAME}\"]').length"
    assert browser.evaluate(row) == 0
    assert wait_for(browser, f"!!document.querySelector('#overview-pane a[href=\"#s={NAME}\"]')", 10.0), "the Overview lists it and links to #s=<name>"
    # open: still no second row
    browser.evaluate(f"go('#s={NAME}'); ''")
    browser.wait_ready(CHAT_READY)
    assert browser.evaluate(row) == 0 and browser.evaluate("document.querySelectorAll('#side-chat').length") == 1


@pytest.mark.parametrize("size", SIZES)
def test_with_no_chat_session_the_sessions_row_is_its_ordinary_row(served, browser, monkeypatch, size):
    open_page(browser, served, monkeypatch, size, api_chat(configured=False), chat=None, hash_="#sessions", ready=False)
    show_panel(browser)
    row = f"document.querySelectorAll('#session-list .sess[data-key=\"{NAME}\"]').length"
    assert wait_for(browser, row + " === 1", 8.0)
    assert browser.evaluate("document.querySelector('#side-chat').hidden")


# ── the strip ────────────────────────────────────────────────────────────────
STRIP = """(() => { const s = document.querySelector('#chat-strip'), pane = document.querySelector('#chat-pane'), chat = document.querySelector('#chat');
  const w = document.querySelector('#chat-strip-wait');
  const t = (q) => [...s.querySelectorAll(q)].map((n) => n.textContent.trim()), tw = (q) => [...w.querySelectorAll(q)].map((n) => n.textContent.trim());
  const sw = s.querySelector('#chat-strip-kept');
  return { hidden: s.hidden, parent: s.parentElement.id, before: !!(s.compareDocumentPosition(chat) & Node.DOCUMENT_POSITION_FOLLOWING), inside: chat.contains(s),
           cls: document.body.classList.contains('chat-session'), position: getComputedStyle(s).position,
           waiting: tw('.wait-row .wait-subj'), answers: tw('.wait-row .answer'), fresh: tw('.wait-subj .new'), pinned: getComputedStyle(w).position, pinHidden: w.hidden,
           pinParent: w.parentElement.id, pinBefore: !!(w.compareDocumentPosition(s) & Node.DOCUMENT_POSITION_FOLLOWING), motion: t('.mo'), count: t('.count'),
           switchOn: !!sw && !sw.disabled && !sw.checked, switchText: t('.kept-toggle > span'), msgs: chat.querySelectorAll(':scope > .msg').length }; })()"""


@pytest.mark.parametrize("size", SIZES)
def test_the_strip_shows_what_waits_what_is_in_motion_and_the_kept_back_switch_with_its_count(served, browser, monkeypatch, size):
    open_page(browser, served, monkeypatch, size, api_chat(keptToday=12, keptTodayFloor=True))
    assert wait_for(browser, "!document.querySelector('#chat-strip').hidden && document.querySelectorAll('#chat-strip-wait .wait-row').length === 2", 10.0)
    s = browser.evaluate(STRIP)
    assert s["parent"] == "chat-pane" and s["before"] and not s["inside"] and s["cls"] and s["position"] == "static", s    # the motion lines and the switch scroll with the thread
    assert s["pinned"] == "sticky" and not s["pinHidden"] and s["pinParent"] == "chat-pane" and s["pinBefore"], s          # what waits is pinned, before the rest of the strip
    assert s["waiting"] == ["Approve the demo budget", "Pick a venue"] and s["answers"] == ["Answer", "Answer"], s
    assert s["motion"] == ["drawing slide 4"] and s["count"] == ["12+ kept back today"], s
    assert s["switchOn"] and s["switchText"][0].startswith("Show what Ada kept back") and "not active yet" not in s["switchText"], s
    assert s["fresh"] == [], s                                  # the first answer's moves are not "new"
    # a move that came since is marked new; the strip follows the answer
    browser.evaluate("window.__chat = Object.assign({}, window.__chat, { waiting: window.__chat.waiting.concat([{ id: 'item#3', subject: 'A third move', url: '' }]), motion: [] }); loadChatMarks(); ''")
    assert wait_for(browser, "document.querySelectorAll('#chat-strip-wait .wait-row').length === 3", 8.0)
    s = browser.evaluate(STRIP)
    assert s["fresh"] == ["new"] and s["motion"] == ["nothing right now"], s


def test_the_strip_survives_the_thread_being_replaced_and_is_read_again_after_stream_activity(served, browser, monkeypatch):
    open_page(browser, served, monkeypatch, DESKTOP, api_chat())
    assert wait_for(browser, "document.querySelectorAll('#chat-strip-wait .wait-row').length === 2", 10.0)
    browser.evaluate("window.__reads = 0; const f = window.fetch; window.fetch = (u, o) => { if (String(u).startsWith('api/chat')) window.__reads++; return f(u, o); }; "
                     "window.__chat = Object.assign({}, window.__chat, { waiting: [] }); selectSession(state.selected, { force: true }); ''")
    browser.wait_ready(CHAT_READY)          # the stream's reset replaced #chat's children
    assert wait_for(browser, "document.querySelectorAll('#chat-strip-wait .wait-row').length === 0 && document.querySelector('#chat-strip-wait').hidden", 10.0), \
        "the strip was read again after the stream said something changed; with nothing waiting no pinned line is drawn"
    s = browser.evaluate(STRIP)
    assert not s["hidden"] and s["parent"] == "chat-pane" and s["msgs"] >= 1 and browser.evaluate("window.__reads") >= 1, s


@pytest.mark.parametrize("size", SIZES)
def test_no_strip_and_no_class_for_any_other_session(served, browser, monkeypatch, size):
    open_page(browser, served, monkeypatch, size, api_chat(session="demo-someone-else"), chat="demo-someone-else")
    assert wait_for(browser, "!document.querySelector('#side-chat').hidden", 8.0)
    s = browser.evaluate(STRIP)
    assert s["hidden"] and not s["cls"] and s["msgs"] >= 1, s
    assert browser.evaluate(f"document.querySelectorAll('#session-list .sess[data-key=\"{NAME}\"]').length") == 1     # its ordinary row stays


# ── everything else is sala's own ────────────────────────────────────────────
@pytest.mark.parametrize("size", SIZES)
def test_one_composer_and_a_pasted_image_makes_a_chip(served, browser, monkeypatch, size):
    open_page(browser, served, monkeypatch, size, api_chat())
    assert wait_for(browser, "!document.querySelector('#chat-strip').hidden", 10.0)
    assert browser.evaluate("[document.querySelectorAll('#composer').length, document.querySelectorAll('#composer-editor').length, document.querySelectorAll('#attach').length, "
                            "document.querySelectorAll('#send').length]") == [1, 1, 1, 1]
    assert browser.evaluate("document.querySelector('#chat-strip').querySelector('input[type=text], textarea, [contenteditable]') === null")
    browser.evaluate("""(() => { const dt = new DataTransfer();
      dt.items.add(new File([new Uint8Array(16)], "pasted.png", { type: "image/png" }));
      document.querySelector("#input").dispatchEvent(new ClipboardEvent("paste", { clipboardData: dt, bubbles: true, cancelable: true })); return ''; })()""")
    got = browser.evaluate(WAIT_CHIPS % 1)
    assert got["chips"] == 1 and got["uploading"] == 0, got


def test_a_working_chat_session_shows_the_sessions_own_spinner(served, browser, monkeypatch):
    """The spinner is the session view's own (app.js updateInflight): the chat session gets it with no code of its own."""
    sess = served["settings"].claude_dir / "sessions"
    for f in sess.glob("*.json"):
        d = json.loads(f.read_text())
        d["status"] = "busy"
        f.write_text(json.dumps(d))
    open_page(browser, served, monkeypatch, DESKTOP, api_chat(busy=True))
    assert wait_for(browser, "!!document.querySelector('#chat > .inflight .spinner')", 15.0)
    assert browser.evaluate("document.querySelectorAll('#chat-strip .spinner').length") == 0


MEASURE_PARITY = """(() => {
  const props = ['display', 'position', 'fontFamily', 'fontSize', 'fontWeight', 'lineHeight', 'color', 'backgroundColor', 'paddingTop', 'paddingRight', 'paddingBottom', 'paddingLeft',
                 'marginRight', 'marginLeft', 'borderTopWidth', 'borderTopColor', 'borderRadius', 'letterSpacing', 'opacity'];
  const one = (sel, pos) => { const n = document.querySelector(sel); if (!n) return null; const r = n.getBoundingClientRect(), cs = getComputedStyle(n);
    const o = { w: Math.round(r.width * 10) / 10, h: Math.round(r.height * 10) / 10, left: Math.round(r.left * 10) / 10 }; if (pos) o.top = Math.round(r.top * 10) / 10;
    for (const p of props) o[p] = cs[p]; return o; };
  return { header: one('#top', true), title: one('#title .name', true), composer: one('#composer', true), input: one('#composer-editor', true), send: one('#send', true), attach: one('#attach', true),
           bubble: one('#chat .msg.user .bubble'), copy: one('#chat .code-copy'), userMsg: one('#chat .msg.user'), assistantMsg: one('#chat .msg.assistant'),
           ts: one('#chat .msg.assistant .md p'), md: getComputedStyle(document.querySelector('#chat .msg.assistant .md')).maxWidth,
           mdW: document.querySelector('#chat .msg.assistant .md').getBoundingClientRect().width,
           fontSize: getComputedStyle(document.querySelector('#chat .msg.assistant .md')).fontSize, scrollW: document.documentElement.scrollWidth, innerW: innerWidth }; })()"""


@pytest.mark.parametrize("size", SIZES)
def test_the_chat_session_and_another_session_differ_only_in_the_strip_and_the_cap(served, browser, monkeypatch, size):
    """The same transcript opened as the chat session and as an ordinary one: header, title, composer, send and attach buttons, the owner's bubble, the copy
    button and the spacing are the same boxes with the same computed style; the assistant's text is capped in one and not in the other."""
    transcript_file(served).write_text(code_transcript())
    open_page(browser, served, monkeypatch, size, None, chat=NAME)
    assert wait_for(browser, "!document.querySelector('#chat-strip').hidden && document.body.classList.contains('chat-session')", 10.0)
    browser.settle("document.querySelector('#chat')")
    chat = browser.evaluate(MEASURE_PARITY)
    open_page(browser, served, monkeypatch, size, None, chat="demo-someone-else")
    assert wait_for(browser, "document.querySelector('#chat-strip').hidden && !document.body.classList.contains('chat-session')", 10.0)
    browser.settle("document.querySelector('#chat')")
    other = browser.evaluate(MEASURE_PARITY)
    # "title" follows the label too: the chat session's header says its label, the other its name, so the text's width and where the centred name starts differ
    for key in ("header", "title", "composer", "input", "send", "attach", "bubble", "copy", "userMsg", "assistantMsg", "ts", "fontSize"):
        a, b = chat[key], other[key]
        follows_cap = {"copy": {"left"}, "assistantMsg": {"h"}, "ts": {"w", "h"}, "title": {"w", "left"}}.get(key, set())   # the cap narrows the text, so a paragraph wraps in more lines (taller) and the copy button, at its block's right edge, moves in
        assert a is not None and b is not None, (key, a, b)          # every measured node is on both pages
        if isinstance(a, dict):                                       # a box: its geometry and computed style, key by key, minus what follows the cap
            a, b = {k: v for k, v in a.items() if k not in follows_cap}, {k: v for k, v in b.items() if k not in follows_cap}
        assert a == b, (key, a, b)                                    # a scalar (fontSize) is compared as it is
    assert other["md"] in ("none", "100%") and chat["md"] not in ("none", "100%"), (chat["md"], other["md"])     # the cap is a width in ch, the other is the thread's own
    assert chat["mdW"] <= other["mdW"] and chat["scrollW"] <= chat["innerW"] and other["scrollW"] <= other["innerW"], (chat, other)


# ── no sideways scroll ───────────────────────────────────────────────────────
MEASURE = r"""(() => {
  const vw = document.documentElement.clientWidth, root = document.scrollingElement, out = [], scrollers = [];
  const sidebar = document.getElementById('sidebar'), open = sidebar.getBoundingClientRect().left >= 0;
  for (const n of document.querySelectorAll('#sidebar *, #chat-strip, #chat-strip *, #chat, #chat *, #composer, #composer *, #top, #top *')) {
    if (!open && sidebar.contains(n)) continue;       // a shut drawer is off the screen on purpose
    if (n.closest('.md table')) continue;             // sala's own rule for every session: a table wider than the thread scrolls inside its own block (.md table), the page never does
    const cs = getComputedStyle(n);
    if (cs.display === 'none' || !n.getClientRects().length) continue;
    const r = n.getBoundingClientRect();
    if (r.width && (r.right > vw + 0.5 || r.left < -0.5)) out.push((n.id || n.className || n.tagName) + ' ' + (n.textContent || '').trim().slice(0, 24) + ' ' + Math.round(r.left) + '-' + Math.round(r.right));
    if ((cs.overflowX === 'auto' || cs.overflowX === 'scroll') && n.scrollWidth > n.clientWidth + 0.5 && !n.matches('.cm-scroller, .cm-content, #input, #composer-editor *')) scrollers.push(n.tagName + '.' + (n.id || n.className));
  }
  const pane = document.getElementById('chat-pane'), strip = document.getElementById('chat-strip'), pin = document.getElementById('chat-strip-wait');
  return { vw, page: [root.scrollWidth, root.clientWidth], body: [document.body.scrollWidth, document.body.clientWidth], pane: [pane.scrollWidth, pane.clientWidth],
           strip: [strip.scrollWidth, strip.clientWidth, strip.getBoundingClientRect().right], pin: [pin.scrollWidth, pin.clientWidth, pin.getBoundingClientRect().right], outside: out.slice(0, 8), scrollers, open,
           waiting: pin.querySelectorAll('.wait-row').length, motion: strip.querySelectorAll('.mo').length, msgs: document.querySelectorAll('#chat > .msg').length }; })()"""


def check(m: dict, where: str) -> None:
    assert m["page"][0] <= m["page"][1] and m["body"][0] <= m["body"][1], f"{where}: the page scrolls sideways: {m}"
    assert m["pane"][0] <= m["pane"][1], f"{where}: the pane scrolls sideways: {m}"
    assert m["strip"][0] <= m["strip"][1] and m["strip"][2] <= m["vw"] + 0.5, f"{where}: the strip is wider than the window: {m}"
    assert m["pin"][0] <= m["pin"][1] and m["pin"][2] <= m["vw"] + 0.5, f"{where}: the pinned line is wider than the window: {m}"
    assert m["scrollers"] == [], f"{where}: something scrolls by its own overflow: {m}"
    assert m["outside"] == [], f"{where}: something ends outside the window: {m}"


@pytest.mark.parametrize("width", [1280, 390, 360, 320])
@pytest.mark.parametrize("drawer", [False, True], ids=["drawer-shut", "drawer-open"])
def test_no_sideways_scroll_with_hostile_text_in_the_thread_the_strip_and_the_entry(served, browser, monkeypatch, width, drawer):
    transcript_file(served).write_text(hostile_transcript())
    doc = api_chat(name="A" * 40, busy=True, keptToday=123456, keptTodayFloor=True,
                   waiting=[{"id": f"item#{i}", "subject": "[demo] " + "an item subject that keeps going and going " * 8 + WORD, "url": URL} for i in range(3)],
                   motion=[{"text": WORD + " " + "m" * 100, "at": int(time.time())} for _ in range(6)])
    open_page(browser, served, monkeypatch, (width, 800 if width > 700 else 844), doc)
    assert wait_for(browser, "document.querySelectorAll('#chat-strip-wait .wait-row').length === 3 && document.querySelectorAll('#chat-strip .mo').length === 6", 10.0)
    if width < 700:
        browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 844, "deviceScaleFactor": 1, "mobile": True})
        assert wait_for(browser, f"document.documentElement.clientWidth === {width}", 10.0)
        if drawer:
            drawer_open(browser)
    browser.evaluate("(() => { const t = document.querySelector('#input'); t.focus(); document.execCommand('insertText', false, " + json.dumps(WORD + " " + URL) + "); return ''; })()")
    browser.settle("document.querySelector('#chat')")
    m = browser.evaluate(MEASURE)
    assert m["vw"] == width and m["waiting"] == 3 and m["motion"] == 6 and m["msgs"] >= 2, m
    check(m, f"{width} px, drawer {'open' if drawer else 'shut'}")
