"""The chat is a view inside sala's own page (#chat), with sala's sidebar, title bar and composer, on a desktop and on a phone.

The rule: the session the server is set to talk to (SALA_CHAT_SESSION) is one more view beside the Overview and the New session page. Its entry is the
first line of the sidebar's views, above New session: a chat-bubble icon, the session's display name with a small "chat", a working dot while it works and
a red count of what waits on the owner. It opens at #chat, inside the same frame as every session: sala's title bar stays where it is while the thread
scrolls under it, and the composer is sala's own (the CodeMirror box, the attach button, an image pasted into it as a chip, Send), not a second copy.
chat.js draws the thread for both this view and the page of its own (/chat), from one set of rendering code. No sideways scroll anywhere, at any width.

What a wrong answer costs: a chat the owner has to leave sala to read, a title bar that scrolls away with the thread, a composer that cannot take a pasted
image, an entry that squeezes the session's name to nothing in the narrow drawer, a count that shows nothing waiting, and a page that grows a sideways
scroll bar on a phone. Every check guards one of those.

The first half is plain text (no server, no browser). The second half runs in a headless Chromium when one is installed (conftest.py: `served`, `browser`),
else is skipped; GitHub CI runs it. api/chat and the chat session's send are replaced in the page; the upload goes to the real server. All names are invented."""

from __future__ import annotations

import json
import re

import pytest

from sala_web.app import STATIC
from test_board_items_ui import wait_for
from test_chat_no_sideways_scroll import URL, WORD, answer
from test_composer_attach import PNG, WAIT_CHIPS

INDEX = (STATIC / "index.html").read_text(encoding="utf-8")
APP_JS = (STATIC / "app.js").read_text(encoding="utf-8")
CHAT_JS = (STATIC / "chat.js").read_text(encoding="utf-8")
CHAT_CSS = (STATIC / "chat.css").read_text(encoding="utf-8")
STYLE = (STATIC / "style.css").read_text(encoding="utf-8")
CHAT_HTML = (STATIC / "chat.html").read_text(encoding="utf-8")


def body_of(src: str, head: str) -> str:
    """The text of the function whose declaration starts with `head`, up to the closing brace at the start of a line."""
    i = src.index(head)
    return src[i:src.index("\n}\n", i)]


# ── the markup ───────────────────────────────────────────────────────────────
def test_the_entry_is_the_first_line_of_the_views_above_new_session():
    top = INDEX[INDEX.index('<nav class="side-top"'):INDEX.index("</nav>", INDEX.index('<nav class="side-top"'))]
    ids = re.findall(r'<(?:a|button) id="(side-[a-z]+)"', top)
    assert ids[0] == "side-chat" and ids.index("side-chat") < ids.index("side-new") < ids.index("side-ovw"), ids
    entry = re.search(r'<a id="side-chat"[^>]*>.*?</a>', top, re.S).group(0)
    assert 'href="#chat"' in entry and 'class="sess side-ovw side-chat"' in entry
    assert " hidden " in entry or ' hidden title' in entry, "hidden until api/chat says a session is set"
    assert re.search(r'<svg width="18" height="18" viewBox="0 0 24 24"[^>]*stroke-width="2" stroke-linecap="round" stroke-linejoin="round"', entry)
    assert entry.count('class="label"') == 1 and 'class="role"' in entry and 'class="dot busy" hidden' in entry and 'class="wchip" hidden' in entry
    assert 'data-i18n="ui.side.chatRole"' in entry and 'data-i18n-title="ui.side.chatTip"' in entry


def test_the_view_has_a_pane_of_its_own_and_the_composer_is_not_copied():
    assert len(re.findall(r'<section id="cview-pane" class="pane"', INDEX)) == 1
    assert 'id="cv" class="cv"' in INDEX and 'id="chat-pane"' in INDEX      # the session's own pane is another one
    ids = re.findall(r'\sid="([^"]+)"', INDEX)
    assert len(ids) == len(set(ids)), sorted({i for i in ids if ids.count(i) > 1})
    for one in ("composer", "composer-editor", "attach", "file-input", "send", "chips", "send-status"):
        assert ids.count(one) == 1, one                                       # sala's composer, once: the view uses it
    assert 'static/chat.css' in INDEX and "static/chat.js" not in INDEX      # the thread's styles are in the page; the script comes on the first open


def test_the_pages_script_is_loaded_lazily_and_mounted_once():
    lazy = body_of(APP_JS, "function chatModule()")
    assert 'replace("static/app.js", "static/chat.js")' in lazy and "chatView.loading" in lazy and ".mount($(\"#cv\")" in lazy
    assert 'scroller: $("#cview-pane")' in lazy                              # the pane is the scroller: the title bar and the composer stay
    assert APP_JS.count('"static/chat.js"') == 1                              # named once, in the loader


# ── the routing ──────────────────────────────────────────────────────────────
def test_app_js_routes_remembers_and_titles_the_view_like_the_other_views():
    assert 'const chatHash = (h = location.hash) => h === "#chat";' in APP_JS
    assert re.search(r"else if \(chatHash\(\)\) showChatPage\(\);", body_of(APP_JS, "function route()"))
    assert 'chatOpen() ? "#chat"' in APP_JS.split("const shownHash", 1)[1].split("\n", 1)[0]
    assert 'a.hash === "#chat"' in APP_JS                                    # an in-page link to it goes through go(), as every view's
    assert 'else if (on("chat-open")) chatHeader(chatView.data);' in body_of(APP_JS, "function retitle()")
    assert 'for (const id of ["#side-chat", "#side-ovw", "#side-new"])' in APP_JS   # a phone's drawer closes after the entry is chosen
    assert APP_JS.count("!chatHash()") == 2                                  # a launch at #chat is not sent to the Overview


def test_every_other_view_switches_the_chat_view_off():
    for head in ("function showOverview()", "function showNewPage()", "function showSearchPage()", "function selectSession("):
        assert "setChatPage(false)" in body_of(APP_JS, head), head
    on = body_of(APP_JS, "function showChatPage()")
    assert all(f in on for f in ("leaveSession();", "setOverview(false);", "setNewPage(false);", "setSearchPage(false);", "setChatPage(true);"))
    sw = body_of(APP_JS, "function setChatPage(on)")
    assert 'document.body.classList.toggle("chat-open", on)' in sw and 'a.setAttribute("aria-current", "page")' in sw and 'a.removeAttribute("aria-current")' in sw
    assert 'a.classList.toggle("selected", on)' in sw and "chatView.mod.hide()" in sw and "m.show()" in sw


def test_the_marks_come_from_api_chat_on_a_timer_that_pauses_while_the_page_is_hidden():
    ms = int(re.search(r"const CHAT_MARKS_MS = (\d+);", APP_JS).group(1))
    assert 20000 <= ms <= 30000
    poll = body_of(APP_JS, "async function pollChatMarks()")
    assert "document.hidden" in poll and 'fetch("api/chat"' in poll
    assert "setInterval(pollChatMarks, CHAT_MARKS_MS)" in APP_JS             # runs whether or not the view is open (the open view reads api/chat itself)
    marks = body_of(APP_JS, "function chatMarks(d)")
    assert "a.hidden = !on" in marks and "dot.hidden = !busy" in marks and "chip.hidden = !waiting" in marks and ".label" in marks


def test_the_composer_sends_to_the_chat_session_through_the_chat_modules_path():
    assert "if (chatOpen()) { chatSend(); return; }" in body_of(APP_JS, "function send()")
    cs = body_of(APP_JS, "async function chatSend()")
    assert "m.send(text, names)" in cs and "state.uploads.filter((u) => u.name).map((u) => u.name)" in cs
    assert "chatOpen() && !(chatView.mod && chatView.mod.canSend())" in body_of(APP_JS, "function refreshSendButton()")
    assert "const draftName = () => state.selected || (chatOpen()" in APP_JS
    submit = CHAT_JS[CHAT_JS.index("  async function submit("):].split("\n  }\n", 1)[0]
    assert "`api/s/${d.pid}/send`" in submit and "JSON.stringify({ text, uploads })" in submit
    do = CHAT_JS[CHAT_JS.index("  async function doSend()"):].split("\n  }\n", 1)[0]
    assert "submit(" in do                                                   # the page of its own sends through the same function


# ── one drawing code for both pages ─────────────────────────────────────────
def test_chat_js_is_one_file_for_the_page_of_its_own_and_the_view():
    for name in ("entryNode", "drawThread", "waitRow", "cardNode", "md", "draw", "build", "drawComposer", "load"):
        assert CHAT_JS.count(f"function {name}(") == 1, name                   # each defined once, whichever page runs it
    assert "entryNode" not in APP_JS and "drawThread" not in APP_JS         # app.js holds none of the drawing: it mounts the module
    assert "window.SalaChat = {" in CHAT_JS
    for member in ("mount(host, o)", "show()", "hide()", "canSend:", "send:"):
        assert member in CHAT_JS.split("window.SalaChat = {", 1)[1], member
    assert 'document.body.classList.contains("chat-page")' in CHAT_JS        # the page of its own starts itself; the view waits to be mounted
    assert "if (!EMBED) { start(); load(); return; }" in CHAT_JS
    assert '<script src="static/chat.js?v={{v}}"></script>' in CHAT_HTML and "chat-page" in CHAT_HTML   # that page is as it was
    for bad in ("innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval(", "new Function"):
        assert bad not in CHAT_JS, bad


def test_the_view_scrolls_inside_its_pane_and_the_page_of_its_own_in_the_window():
    se = CHAT_JS[CHAT_JS.index("  function scrollEnd()"):].split("\n  };\n", 1)[0]
    assert "opts.scroller.scrollTop = opts.scroller.scrollHeight" in se and "window.scrollTo(0, document.documentElement.scrollHeight)" in se
    assert "opts.scroller.addEventListener(\"scroll\", onScroll" in CHAT_JS


# ── the style sheets ─────────────────────────────────────────────────────────
def test_the_views_rules_hide_what_is_a_sessions_and_keep_the_composer_and_the_title_dot():
    rule = re.search(r"body\.chat-open #chat-pane,[^{]*\{ display: none; \}", STYLE).group(0)
    for hidden in ("#chat-pane", "#terminal-pane", "#menu-reload", "#top-tools", "#top-menu-btn", "#composer > .jump"):
        assert hidden in rule, hidden
    assert "#composer," not in rule and "#composer " not in rule.replace("#composer > .jump", "") and "#title .dot" not in rule
    assert "body.chat-open #cview-pane { display: block; }" in STYLE
    assert re.search(r"#cview-pane \{ overflow-y: auto; overflow-x: hidden; \}", STYLE)


def test_no_sideways_scroll_rule_is_given_up_anywhere_in_the_views_styles():
    new = CHAT_CSS[CHAT_CSS.index("---- the chat view inside sala's page"):]
    chunks = [CHAT_CSS, new] + [m for m in re.findall(r"[^}]*(?:cview|chat-open|side-chat|wchip)[^{]*\{[^}]*\}", STYLE)]
    for c in chunks:
        assert not re.search(r"overflow(?:-x)?\s*:\s*(?:scroll|auto)", re.sub(r"overflow-y\s*:[^;}]*", "", c).replace("overflow-x: hidden", "")), c[:120]
    assert "body.chat-page" in CHAT_CSS and ":is(body.chat-page, .cv)" in CHAT_CSS   # the thread's rules serve both pages


def test_the_entry_keeps_room_for_the_name_and_marks_the_row_in_the_waiting_red():
    assert re.search(r"\.side-chat \.label \{ min-width: 48px; \}", STYLE) and ".side-chat .role { flex: none; }" in STYLE
    wchip = re.search(r"\.wchip \{[^}]*\}", STYLE).group(0)
    assert "background: var(--waiting)" in wchip and "color: var(--waiting-text)" in wchip and "flex: none" in wchip
    assert "ucount" not in INDEX[INDEX.index('<a id="side-chat"'):INDEX.index("</a>", INDEX.index('<a id="side-chat"'))]   # not the orange count


# ── in a browser ─────────────────────────────────────────────────────────────
CHAT_PID = 4242
STUB = """(() => {
  const real = window.fetch.bind(window), json = (o) => new Response(JSON.stringify(o), { headers: { "Content-Type": "application/json" } });
  window.EventSource = undefined;
  window.__chatDoc = %s;
  window.__sends = [];
  window.fetch = (url, opts) => {
    const u = String(url);
    if (u.startsWith("api/chat")) return Promise.resolve(json(window.__chatDoc));
    if (u === "api/s/%d/send") { window.__sends.push(JSON.parse(opts.body)); return Promise.resolve(json({ ok: true })); }
    return real(url, opts);
  };
})()"""
READY = "document.body.classList.contains('chat-open') && document.querySelectorAll('#cv .thread .msg').length >= 1"
SIDE_IN = "document.getElementById('sidebar').getBoundingClientRect().left === 0"
SIDE_OUT = "document.getElementById('sidebar').getBoundingClientRect().right <= 0"
SIZES = [pytest.param(1280, 800, id="desktop"), pytest.param(390, 844, id="phone")]


def doc(present: str = "live", busy: bool = False, waiting: int = 0, name: str = "Ada", configured: bool = True, turns: int = 2) -> dict:
    """An api/chat answer; `turns` of two messages each, enough to make the thread scroll when many."""
    now = 1_800_000_000_000
    entries = []
    for i in range(turns):
        entries.append({"k": "me", "ts": now - (turns - i) * 60000 - 30000, "text": f"question {i}"})
        entries.append({"k": "reply", "ts": now - (turns - i) * 60000, "text": f"answer {i}\n\n" + "a line of the reply.\n\n" * 6})
    return {
        "configured": configured, "session": "demo-chat", "name": name, "owner": "Rowan", "present": present, "status": "busy" if busy else "idle",
        "pid": CHAT_PID if present == "live" else 0, "busy": busy, "version": "", "styles": "", "timezone": "UTC", "tzLabel": "UTC", "tzOffsetMin": 0,
        "now": now, "entries": entries if configured else [], "keptToday": 0, "keptTodayFloor": False,
        "waiting": [{"id": f"item#{i}", "subject": f"a move {i}", "url": "https://example.com/" + str(i)} for i in range(waiting)], "motion": [],
    }


def open_page(browser, served, d: dict, width: int, height: int, hash_: str = "", sidebar: bool = False, ready: str = "") -> None:
    """The page with api/chat answering `d`; `hash_` "#chat" opens the view at once; `sidebar` shows the side panel (the drawer on a phone)."""
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": STUB % (json.dumps(d), CHAT_PID)})
    browser.width, browser.height = width, height
    url = f"{served['url']}/{hash_}"
    if width < 700:
        browser.open(url, dark=True)
    else:                                                                    # a desktop that hovers
        browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": height, "deviceScaleFactor": 1, "mobile": False})
        browser.send("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-color-scheme", "value": "dark"}]})
        browser.send("Page.navigate", {"url": url})
    browser.wait_ready()
    if ready:
        assert wait_for(browser, ready, 60.0), "the page did not draw"
    if sidebar:
        show_side(browser)


def show_side(browser) -> None:
    browser.evaluate("(() => { if (document.getElementById('sidebar').getBoundingClientRect().left !== 0) document.querySelector('#side-open').click(); return ''; })()")
    assert wait_for(browser, SIDE_IN, 5.0)


ENTRY = """(() => { const q = (s) => document.querySelector(s), a = q('#side-chat'), top = [...document.querySelectorAll('.side-top > *')].filter((e) => !e.hidden).map((e) => e.id);
  const r = (e) => { const b = e.getBoundingClientRect(); return { top: b.top, bottom: b.bottom, left: b.left, right: b.right, w: b.width, h: b.height }; };
  const label = a.querySelector('.label'), chip = a.querySelector('.wchip'), dot = a.querySelector('.dot');
  return { top, hidden: a.hidden, shown: getComputedStyle(a).display !== 'none', box: r(a), newBox: r(q('#side-new')), label: label.textContent, labelW: label.getBoundingClientRect().width,
    labelClipped: label.scrollWidth > label.clientWidth, role: a.querySelector('.role').textContent, icon: !!a.querySelector('svg'), href: a.getAttribute('href'),
    dot: !dot.hidden && getComputedStyle(dot).display !== 'none', chip: chip.hidden ? null : chip.textContent, chipBg: getComputedStyle(chip).backgroundColor,
    chipLabel: chip.getAttribute('aria-label'), selected: a.classList.contains('selected'), current: a.getAttribute('aria-current'),
    fits: a.scrollWidth <= a.clientWidth + 1 && r(a).right <= q('#sidebar').getBoundingClientRect().right + 0.5 }; })()"""


@pytest.mark.parametrize("width,height", SIZES)
def test_the_entry_is_the_first_line_above_new_session_with_its_icon_name_and_marks(served, browser, width, height):
    open_page(browser, served, doc(busy=True, waiting=5), width, height, sidebar=True)
    assert wait_for(browser, "!document.querySelector('#side-chat').hidden", 20.0)
    e = browser.evaluate(ENTRY)
    assert e["top"][:3] == ["side-chat", "side-new", "side-ovw"] and e["shown"], e
    assert e["box"]["bottom"] <= e["newBox"]["top"] + 0.5 and e["box"]["top"] < e["newBox"]["top"], e         # one line, above New session
    assert (e["label"], e["role"], e["icon"], e["href"]) == ("Ada", "chat", True, "#chat"), e
    assert e["dot"] and e["chip"] == "5" and e["chipLabel"] == "5 moves waiting on you", e
    assert e["chipBg"] == browser.evaluate("(() => { const s = document.createElement('i'); s.style.background = 'var(--waiting)'; document.body.append(s); const c = getComputedStyle(s).backgroundColor; s.remove(); return c; })()"), e
    assert not e["selected"] and e["current"] is None and e["fits"], e


def test_the_marks_follow_api_chat_the_dot_when_it_works_the_count_when_moves_wait(served, browser):
    open_page(browser, served, doc(busy=False, waiting=0), 1280, 800, sidebar=True)
    assert wait_for(browser, "!document.querySelector('#side-chat').hidden", 20.0)
    e = browser.evaluate(ENTRY)
    assert not e["dot"] and e["chip"] is None, e                                                            # idle, nothing waiting: no marks
    browser.evaluate("window.__chatDoc = " + json.dumps(doc(busy=True, waiting=1)) + "; pollChatMarks(); ''")
    assert wait_for(browser, "!document.querySelector('#side-chat .dot').hidden && document.querySelector('#side-chat .wchip').textContent === '1'", 10.0)
    assert browser.evaluate(ENTRY)["chipLabel"] == "1 move waiting on you"
    browser.evaluate("window.__chatDoc = " + json.dumps(doc(present="sleeping", busy=False, waiting=0)) + "; pollChatMarks(); ''")
    assert wait_for(browser, "document.querySelector('#side-chat .dot').hidden && document.querySelector('#side-chat .wchip').hidden", 10.0)


def test_the_entry_is_hidden_when_no_session_is_set(served, browser):
    open_page(browser, served, doc(configured=False), 1280, 800, sidebar=True)
    assert wait_for(browser, "typeof chatView !== 'undefined' && chatView.data !== null", 20.0)
    e = browser.evaluate(ENTRY)
    assert e["hidden"] and not e["shown"] and e["top"][0] == "side-new", e


@pytest.mark.parametrize("width,height", SIZES)
def test_a_click_opens_the_view_inside_sala_and_a_phones_drawer_closes(served, browser, width, height):
    open_page(browser, served, doc(busy=True, waiting=2), width, height, hash_="#sessions", sidebar=True)
    assert wait_for(browser, "!document.querySelector('#side-chat').hidden", 20.0)
    browser.evaluate("document.querySelector('#side-chat').click(); ''")
    assert wait_for(browser, READY, 30.0), "the view did not draw its thread"
    e = browser.evaluate(ENTRY)
    assert e["selected"] and e["current"] == "page", e
    assert browser.evaluate("location.hash") == "#chat" and browser.evaluate("document.querySelector('#side-ovw').classList.contains('selected')") is False
    assert browser.evaluate("document.querySelector('#title .name').textContent") == "Ada"
    assert browser.evaluate("!!document.querySelector('#title .pill.busy')")                                  # the working badge, as a session's title bar has it
    assert browser.evaluate("getComputedStyle(document.querySelector('#chat-pane')).display") == "none"
    assert browser.evaluate("getComputedStyle(document.querySelector('#cview-pane')).display") == "block"
    if width < 700:
        assert wait_for(browser, SIDE_OUT, 5.0), "the drawer stayed open after the entry was chosen"
    show_side(browser)
    browser.evaluate("document.querySelector('#side-ovw').click(); ''")                                      # leaving: the entry is no longer the page
    assert wait_for(browser, "!document.body.classList.contains('chat-open')", 10.0)
    e = browser.evaluate(ENTRY)
    assert not e["selected"] and e["current"] is None, e


@pytest.mark.parametrize("width,height", SIZES)
def test_the_title_bar_stays_while_the_thread_scrolls(served, browser, width, height):
    open_page(browser, served, doc(turns=30), width, height, hash_="#chat", ready=READY)
    probe = """(() => { const q = (s) => document.querySelector(s), p = q('#cview-pane'), t = q('#top').getBoundingClientRect(), c = q('#composer').getBoundingClientRect();
      return { top: t.top, bottom: t.bottom, comp: c.top, sh: p.scrollHeight, ch: p.clientHeight, st: p.scrollTop, win: document.scrollingElement.scrollTop }; })()"""
    before = browser.evaluate(probe)
    assert before["sh"] > before["ch"] + 200, before                                                          # the thread is longer than the pane
    assert before["st"] > 0, before                                                                           # it opened at the end of the thread
    browser.evaluate("document.querySelector('#cview-pane').scrollTop = 0; ''")
    after = browser.evaluate(probe)
    assert after["st"] == 0 and after["win"] == 0, after
    assert after["top"] == before["top"] and after["bottom"] == before["bottom"] and after["comp"] == before["comp"], (before, after)   # title bar and composer did not move


@pytest.mark.parametrize("width,height", SIZES)
def test_the_composer_is_salas_own_with_attach_and_a_pasted_image_makes_a_chip(served, browser, width, height):
    open_page(browser, served, doc(), width, height, hash_="#chat", ready=READY)
    seen = browser.evaluate("""(() => { const q = (s) => document.querySelector(s), vis = (e) => !!e && getComputedStyle(e).display !== 'none' && e.getBoundingClientRect().height > 0;
      return { composer: vis(q('#composer')), attach: vis(q('#attach')), editor: vis(q('#composer-editor')), send: vis(q('#send')), own: document.querySelectorAll('#cv textarea, #cv .compose-row, #cv .send-btn').length,
               editable: q('#input') && q('#input').getAttribute('contenteditable') }; })()""")
    assert seen == {"composer": True, "attach": True, "editor": True, "send": True, "own": 0, "editable": "true"}, seen
    b64 = json.dumps(__import__("base64").b64encode(PNG).decode())
    assert browser.evaluate(f"""(() => {{ const bytes = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
      const e = new ClipboardEvent("paste", {{ bubbles: true, cancelable: true }});
      Object.defineProperty(e, "clipboardData", {{ value: {{ files: [new File([bytes({b64})], "shot.png", {{ type: "image/png" }})], items: [], types: ["Files"], getData: () => "" }} }});
      return !document.querySelector("#input").dispatchEvent(e); }})()""")
    got = browser.evaluate(WAIT_CHIPS % 1)
    assert got["chips"] == 1 and got["uploading"] == 0 and len(got["names"]) == 1, got                       # the chip, uploaded through the page's own path


@pytest.mark.parametrize("width,height", SIZES)
def test_send_posts_to_the_chat_session_with_the_uploaded_names_and_clears_the_box(served, browser, width, height):
    open_page(browser, served, doc(), width, height, hash_="#chat", ready=READY)
    b64 = json.dumps(__import__("base64").b64encode(PNG).decode())
    browser.evaluate(f"""(() => {{ const bytes = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
      const e = new ClipboardEvent("paste", {{ bubbles: true, cancelable: true }});
      Object.defineProperty(e, "clipboardData", {{ value: {{ files: [new File([bytes({b64})], "shot.png", {{ type: "image/png" }})], items: [], types: ["Files"], getData: () => "" }} }});
      document.querySelector("#input").dispatchEvent(e); setText("hello demo"); refreshSendButton(); return ''; }})()""")
    got = browser.evaluate(WAIT_CHIPS % 1)
    assert got["chips"] == 1 and got["sendEnabled"], got
    browser.evaluate("document.querySelector('#send').click(); ''")
    assert wait_for(browser, "window.__sends.length === 1", 10.0)
    sent = browser.evaluate("window.__sends[0]")
    assert sent["text"] == "hello demo" and sent["uploads"] == got["names"], sent                          # the chat session's send (api/s/<pid>/send), with the file
    assert wait_for(browser, "getText() === '' && document.querySelectorAll('#chips .chip').length === 0", 10.0)
    assert wait_for(browser, "[...document.querySelectorAll('#cv .bubble.pending')].some((b) => b.textContent.startsWith('hello demo'))", 10.0)   # shown at once, as on the page of its own
    assert browser.evaluate("location.hash") == "#chat" and browser.evaluate("state.selected") is None


def test_a_sleeping_session_shows_the_wake_line_and_send_is_off(served, browser):
    open_page(browser, served, doc(present="sleeping"), 390, 844, hash_="#chat", ready="document.body.classList.contains('chat-open') && !!document.querySelector('#cv .compose-sleep:not([hidden]) button')")
    assert browser.evaluate("document.querySelector('#send').disabled") is True
    assert "asleep" in browser.evaluate("document.querySelector('#cv .compose-sleep').textContent")


def test_a_typed_draft_is_kept_for_the_chat_session_and_comes_back(served, browser):
    open_page(browser, served, doc(), 1280, 800, hash_="#chat", ready=READY)
    browser.evaluate("setText('half a thought'); saveDraft(); ''")
    assert browser.evaluate("localStorage.getItem('salaweb.draft.demo-chat')") == "half a thought"
    show_side(browser)
    browser.evaluate("document.querySelector('#side-ovw').click(); ''")
    assert wait_for(browser, "getText() === '' && !document.body.classList.contains('chat-open')", 10.0)
    browser.evaluate("document.querySelector('#side-chat').click(); ''")
    assert wait_for(browser, "document.body.classList.contains('chat-open') && getText() === 'half a thought'", 10.0)


# the page, its body and every box inside the main area (and the sidebar when it is shown) end inside the window; nothing scrolls by its own overflow
MEASURE = r"""(() => {
  const root = document.scrollingElement, vw = document.documentElement.clientWidth, out = [], scrollers = [];
  const sb = document.getElementById('sidebar').getBoundingClientRect(), side = sb.left >= 0 && sb.right > 0;
  for (const n of document.querySelectorAll("#main *, #sidebar *")) {
    if (!side && n.closest("#sidebar")) continue;
    if (n.closest("#composer-editor") && n.id !== "composer-editor") continue;   // sala's own editor (its own tests hold its inside)
    const cs = getComputedStyle(n);
    if (cs.display === "none" || !n.getClientRects().length) continue;
    const r = n.getBoundingClientRect();
    if (r.width && (r.right > vw + 0.5 || r.left < -0.5)) out.push((n.id || n.className || n.tagName) + " " + (n.textContent || "").trim().slice(0, 24) + " " + Math.round(r.left) + "-" + Math.round(r.right));
    if ((cs.overflowX === "auto" || cs.overflowX === "scroll") && n.scrollWidth > n.clientWidth && !n.closest(".cm-scroller")) scrollers.push(n.tagName + "." + n.className);
  }
  const pane = document.getElementById('cview-pane');
  return { vw, page: { sw: root.scrollWidth, cw: root.clientWidth }, body: { sw: document.body.scrollWidth, cw: document.body.clientWidth },
           pane: { sw: pane.scrollWidth, cw: pane.clientWidth }, msgs: document.querySelectorAll("#cv .thread .msg").length, side, outside: out.slice(0, 8), scrollers };
})()"""


def no_sideways(m: dict, where: str) -> None:
    assert m["page"]["sw"] <= m["page"]["cw"], f"{where}: the page scrolls sideways: {m}"
    assert m["body"]["sw"] <= m["body"]["cw"], f"{where}: the body scrolls sideways: {m}"
    assert m["pane"]["sw"] <= m["pane"]["cw"], f"{where}: the view scrolls sideways: {m}"
    assert m["scrollers"] == [], f"{where}: something scrolls by its own overflow: {m}"
    assert m["outside"] == [], f"{where}: something ends outside the window: {m}"


def resize(browser, width: int, height: int) -> None:
    browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": height, "deviceScaleFactor": 1, "mobile": width < 700})
    assert wait_for(browser, f"document.documentElement.clientWidth === {width}", 10.0)
    browser.settle("document.getElementById('cview-pane')")


@pytest.mark.parametrize("present", ["live", "sleeping"])
def test_no_sideways_scroll_in_the_view_with_the_drawer_open_or_shut_at_every_width(served, browser, present):
    """The hostile answer of the chat page's own test (a 300-character word, a long address, wide code and tables, a 40-letter name, long moves) in the view."""
    d = answer(present)
    d["name"] = "A" * 40
    open_page(browser, served, d, 1280, 800, hash_="#chat", ready="document.body.classList.contains('chat-open') && (document.querySelectorAll('#cv .thread .msg').length >= 3 || !!document.querySelector('#cv .compose-sleep:not([hidden])'))")
    browser.evaluate("setText(" + json.dumps(WORD + " " + URL) + "); ''")                                      # a long unbroken draft in sala's composer
    for width, height in ((1280, 800), (390, 844), (320, 640)):
        resize(browser, width, height)
        no_sideways(browser.evaluate(MEASURE), f"{present}, view, {width} px")
        show_side(browser)                                                                                       # the drawer (or the pinned sidebar) open, entry with its long name
        m = browser.evaluate(MEASURE)
        assert m["side"], m
        no_sideways(m, f"{present}, drawer open, {width} px")
        e = browser.evaluate(ENTRY)
        assert e["labelW"] >= 48 and e["label"] == "A" * 40 and e["fits"], (width, e)                           # the long name is clipped by its ellipsis, not squeezed away
        if width < 700:
            browser.evaluate("document.querySelector('#side-close').click(); ''")
            assert wait_for(browser, SIDE_OUT, 5.0)
