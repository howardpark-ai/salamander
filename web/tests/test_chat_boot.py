"""The first paint of the chat session's address (no browser here; test_chat_boot_ui.py records the frames).

The rule: a load of the chat session's address (SALA_CHAT_SESSION: `#s=<the session>`, which /chat redirects to, or a phone's or the installed app's launch with no
address whose last view was that session) shows nothing of another view while it loads: not the served header "Select a session", not "Pick a session on the left.",
and not the session's bare name ahead of its label. static/chatboot.js does that and nothing else; index.html names it only when a chat session is set; every other
address, and every page with none set, is as it was. It lets go when the page draws anything else, on an uncaught error and after a time limit.

What a wrong answer costs: another view flashing on the chat's address; a header or a thread left blank for good; another session's first paint changed.

Held here: what the server serves with and without a chat session, the decision and the whole script run in node against a stand-in for the page, and the words the
script shares with app.js and index.html. All names are invented."""

from __future__ import annotations

import json
import re
import shutil
import subprocess

import pytest
from starlette.testclient import TestClient

from sala_web.app import STATIC, create_app
from sala_web.config import Settings

NODE = shutil.which("node")
needs_node = pytest.mark.skipif(not NODE, reason="node is not installed")

BOOT = STATIC / "chatboot.js"
INDEX = (STATIC / "index.html").read_text(encoding="utf-8")
APP_JS = (STATIC / "app.js").read_text(encoding="utf-8")
BLOCK = re.compile(r"<!--chatboot-->.*?<!--/chatboot-->\n", re.S)


@pytest.fixture
def client(tmp_path):
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    (claude / "projects").mkdir()
    return TestClient(create_app(Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                                          tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"])))


# ── what the server serves ───────────────────────────────────────────────────
def test_with_no_chat_session_the_page_does_not_name_the_script(client, monkeypatch):
    monkeypatch.delenv("SALA_CHAT_SESSION", raising=False)
    html = client.get("/").text
    for trace in ("chatboot", "chatSession", "data-chat-session"):
        assert trace not in html, trace
    assert "<script src=\"static/vendor/cm6-composer.min.js?v=" in html
    # the lines around the dropped block meet as they did without it
    assert re.search(r'<script src="static/vendor/cm6-composer\.min\.js\?v=[0-9a-f]+"></script>\n<!-- the look\'s additions', html)


def test_with_a_chat_session_the_page_adds_one_script_in_the_head_and_nothing_else(client, monkeypatch):
    monkeypatch.delenv("SALA_CHAT_SESSION", raising=False)
    plain = client.get("/").text
    monkeypatch.setenv("SALA_CHAT_SESSION", "demo-chat")   # read on each load
    monkeypatch.setenv("SALA_CHAT_NAME", "Demo Label")
    html = client.get("/").text
    tags = re.findall(r'<script src="static/chatboot\.js\?v=([0-9a-f]+)" data-chat-session="demo-chat"></script>', html)
    assert len(tags) == 1 and f'static/app.js?v={tags[0]}"' in html, "versioned as the other scripts are"
    assert html.index("static/chatboot.js") < html.index('<style id="look">') < html.index("</head>")
    assert len(BLOCK.findall(html)) == 1 and BLOCK.sub("", html) == plain, "the block is the only difference"
    assert "{{chatSession}}" not in html and "Demo Label" not in html


@pytest.mark.parametrize("value", ["", "  ", 'a b<script>', '"demo', "x" * 65])
def test_a_setting_that_is_no_session_name_serves_the_page_without_the_script(client, monkeypatch, value):
    monkeypatch.setenv("SALA_CHAT_SESSION", value)
    html = client.get("/").text
    assert "chatboot" not in html and "{{chatSession}}" not in html


def test_the_script_is_served_and_checked_again_on_every_load(client):
    r = client.get("/static/chatboot.js")
    assert r.status_code == 200 and r.content == BOOT.read_bytes() and "javascript" in r.headers["content-type"]
    assert r.headers["cache-control"] == "no-cache"


def test_the_full_size_terminal_does_not_take_the_script(client, monkeypatch):
    monkeypatch.setenv("SALA_CHAT_SESSION", "demo-chat")
    assert "chatboot" not in client.get("/terminal?arg=x").text


# ── the words it shares with the page ────────────────────────────────────────
def test_the_script_reads_the_page_by_the_names_the_page_uses():
    boot = BOOT.read_text(encoding="utf-8")
    # where app.js reopens the last view, and where it keeps it
    for query in ("(max-width: 760px)", "(display-mode: standalone)"):
        assert f'media("{query}")' in boot and f'window.matchMedia("{query}")' in APP_JS, query
    assert 'localStorage.getItem("salaweb.lastView")' in boot and 'const LAST_VIEW = "salaweb.lastView";' in APP_JS
    # the markup's placeholder, the other views' classes, the sleeper's dot and the sidebar's entry
    assert INDEX.count('<div id="chat"><div class="empty" data-i18n="ui.chat.pick">') == 1
    for cls in ("overview-open", "new-open", "search-open"):
        assert f"body.{cls}" in boot and f'"{cls}"' in APP_JS, cls
    assert '$("#title .dot").className = "dot sleeping";' in APP_JS and '<a id="side-chat" ' in INDEX
    assert "a.hidden = !on;" in APP_JS
    # it writes nothing into the page's own elements
    assert not re.search(r"\.(textContent|innerHTML|hidden|className)\s*=[^=]", boot.replace("style.textContent =", ""))


# ── the decision, in node ────────────────────────────────────────────────────
def node(program: str) -> object:
    out = subprocess.run([NODE, "-e", program, str(BOOT)], capture_output=True, text=True, timeout=60)
    assert out.returncode == 0, out.stderr
    return json.loads(out.stdout)


WORDS = r"""
const text = require('fs').readFileSync(process.argv[1], 'utf8');
const words = /\/\/ <chat-boot-words>[^\n]*\n([\s\S]*?)\/\/ <\/chat-boot-words>/.exec(text)[1];
const { chatBootWanted, chatBootHolds } = new Function(words + 'return { chatBootWanted, chatBootHolds };')();
"""


@needs_node
@pytest.mark.parametrize("hash_, reopens, last, wanted", [
    ("#s=demo-chat", False, "", True),
    ("#s=demo-chat", True, "#sessions", True),
    ("#s=demo%2Dchat", False, "", True),
    ("#s=demo-other", False, "", False),
    ("#s=demo-other", True, "#s=demo-chat", False),       # an address wins over the last view
    ("#s=demo-chat-two", False, "", False),
    ("#s=%", False, "", False),
    ("#sessions", True, "#s=demo-chat", False),
    ("#new", True, "#s=demo-chat", False),
    ("#side=demo-chat", False, "", False),
    ("#search?s=demo-chat", False, "", False),
    ("", True, "#s=demo-chat", True),                     # a phone or the installed app, launched with no address
    ("", False, "#s=demo-chat", False),                   # a wide browser opens the Overview
    ("", True, "#s=demo-other", False),
    ("", True, "#sessions", False),
    ("", True, "", False),
])
def test_only_a_load_on_its_way_to_the_chat_session_is_held(hash_, reopens, last, wanted):
    args = json.dumps(["demo-chat", hash_, reopens, last])
    assert node(WORDS + f"console.log(JSON.stringify(chatBootWanted(...{args})));") is wanted


DRAWN = {"drawn": True, "elsewhere": False, "asleep": False, "answered": False, "name": "demo-chat"}


@needs_node
@pytest.mark.parametrize("page, holds", [
    ({**DRAWN, "drawn": False, "name": "Select a session"}, True),
    ({**DRAWN, "drawn": False, "answered": True}, True),                     # api/chat first: the placeholder is still there
    (DRAWN, True),                                                           # the chat's header ahead of its label
    ({**DRAWN, "answered": True, "name": "Demo Label"}, False),
    ({**DRAWN, "answered": True}, False),                                    # a label that is the session's own name
    ({**DRAWN, "name": "demo-chat (not running)"}, False),
    ({**DRAWN, "asleep": True}, False),
    ({**DRAWN, "elsewhere": True}, False),
    ({**DRAWN, "name": "demo-other"}, False),
])
def test_the_page_is_held_until_it_shows_the_chat_or_anything_else(page, holds):
    assert node(WORDS + f"console.log(JSON.stringify(chatBootHolds('demo-chat', {json.dumps(page)})));") is holds


# ── the whole script, against a stand-in for the page ────────────────────────
STAND_IN = r"""
const src = require('fs').readFileSync(process.argv[1], 'utf8');
function load({ hash = '#s=demo-chat', session = 'demo-chat', body = null, narrow = false, standalone = false, last = '', noStorage = false } = {}) {
  const seen = { attrs: new Set(), listeners: {}, timers: [], styled: false, watching: false };
  const page = { first: 'ui.chat.pick', name: 'Select a session', elsewhere: false, asleep: false, answered: false };
  let changed = null;
  const style = { textContent: '', remove() { seen.styled = false; } };
  const env = {
    document: {
      body,
      currentScript: { getAttribute: (k) => (k === 'data-chat-session' ? session : null), after: (n) => { seen.styled = n === style; } },
      documentElement: { setAttribute: (k) => seen.attrs.add(k), removeAttribute: (k) => seen.attrs.delete(k) },
      createElement: () => style,
      querySelector: (s) => {
        if (s === '#chat > :first-child') return { getAttribute: () => page.first };
        if (s === '#title .name') return { textContent: page.name };
        if (s === '#side-chat') return { hidden: !page.answered };
        if (s === 'body.overview-open, body.new-open, body.search-open') return page.elsewhere ? {} : null;
        if (s === '#title .dot.sleeping') return page.asleep ? {} : null;
        throw new Error('a selector the stand-in does not know: ' + s);
      },
    },
    SalaAddress: { here: () => hash },   // static/address.js: the view the address names
    window: { matchMedia: (q) => ({ matches: (q === '(max-width: 760px)' && narrow) || (q === '(display-mode: standalone)' && standalone) }) },
    localStorage: { getItem: (k) => { if (noStorage) throw new Error('no storage'); return k === 'salaweb.lastView' ? last : null; } },
    MutationObserver: class { constructor(f) { changed = f; } observe() { seen.watching = true; } disconnect() { seen.watching = false; } },
    addEventListener: (t, f) => { (seen.listeners[t] = seen.listeners[t] || []).push(f); },
    removeEventListener: (t, f) => { seen.listeners[t] = (seen.listeners[t] || []).filter((g) => g !== f); },
    setTimeout: (f, ms) => { seen.timers.push({ f, ms }); },
  };
  new Function(...Object.keys(env), src)(...Object.values(env));
  return {
    held: () => seen.attrs.has('data-chat-boot') && seen.styled,
    clean: () => !seen.attrs.size && !seen.styled && !seen.watching && !(seen.listeners.error || []).length && !(seen.listeners.unhandledrejection || []).length,
    untouched: () => !seen.attrs.size && !seen.styled && !seen.watching && !Object.keys(seen.listeners).length && !seen.timers.length,
    draw: (patch) => { Object.assign(page, patch); if (seen.watching) changed([]); },
    fire: (t, e = {}) => (seen.listeners[t] || []).slice().forEach((f) => f({ type: t, ...e })),
    timers: seen.timers,
  };
}
"""


@needs_node
def test_a_chat_load_is_held_until_the_label_is_there():
    got = node(STAND_IN + r"""
const p = load(), steps = [p.held()];
p.draw({ name: 'Select a session' });                                   steps.push(p.held());   // app.js words the header at its start
p.draw({ first: 'app.loadingTranscript', name: 'demo-chat' });          steps.push(p.held());   // the chat is open, api/chat is not back
p.draw({ answered: true, name: 'Demo Label' });                         steps.push(p.held());
const q = load(); q.draw({ answered: true }); const first = q.held();   q.draw({ first: 'app.loadingTranscript', name: 'Demo Label' });
console.log(JSON.stringify({ steps, clean: p.clean(), answeredFirst: [first, q.held(), q.clean()] }));
""")
    assert got == {"steps": [True, True, True, False], "clean": True, "answeredFirst": [True, False, True]}


@needs_node
@pytest.mark.parametrize("patch", [
    {"first": None, "name": "demo-chat (not running)"},
    {"first": "app.loadingTranscript", "asleep": True},
    {"first": "app.pickSession", "elsewhere": True, "name": "Overview"},
    {"first": "app.loadingTranscript", "name": "demo-other"},
], ids=["not-running", "asleep", "overview", "another-session"])
def test_anything_else_the_page_draws_lets_go(patch):
    patch = {"name": "demo-chat", **patch}
    got = node(STAND_IN + f"const p = load(); p.draw({json.dumps(patch)}); console.log(JSON.stringify([p.held(), p.clean()]));")
    assert got == [False, True]


@needs_node
def test_an_uncaught_error_lets_go_and_a_file_that_failed_to_load_does_not():
    got = node(STAND_IN + r"""
const a = load(); a.fire('error'); const resource = a.held(); a.fire('error', { error: null }); const noObject = a.held(); a.fire('error', { error: new Error('staged') });
const b = load(); b.fire('unhandledrejection', { reason: 'staged' });
console.log(JSON.stringify({ resource, noObject, thrown: [a.held(), a.clean()], refused: [b.held(), b.clean()] }));
""")
    assert got == {"resource": True, "noObject": True, "thrown": [False, True], "refused": [False, True]}


@needs_node
def test_a_page_that_draws_nothing_is_let_go_after_the_time_limits():
    got = node(STAND_IN + r"""
const a = load(), atStart = a.timers.map((t) => t.ms); a.timers[0].f();
const b = load(); b.fire('DOMContentLoaded'); const added = b.timers.slice(1).map((t) => t.ms), before = b.held(); b.timers[1].f();
console.log(JSON.stringify({ atStart, atMost: [a.held(), a.clean()], added, afterRead: [before, b.held(), b.clean()] }));
""")
    assert got == {"atStart": [30000], "atMost": [False, True], "added": [10000], "afterRead": [True, False, True]}


@needs_node
def test_every_other_load_is_left_alone():
    got = node(STAND_IN + r"""
const last = '#s=demo-chat', chat = { hash: '', last };
console.log(JSON.stringify({
  inert: [load({ hash: '#s=demo-other' }), load({ hash: '#sessions', narrow: true, last }), load(chat), load({ hash: '', narrow: true, last: '#sessions' }),
          load({ hash: '', narrow: true, noStorage: true }),
          load({ session: null }),            // the copy the page asks for again after a failed load
          load({ body: {} })                  // run after the first paint
         ].map((p) => p.untouched()),
  held: [load({ ...chat, narrow: true }), load({ ...chat, standalone: true }), load({ narrow: true, noStorage: true })].map((p) => p.held()),
}));
""")
    assert got == {"inert": [True] * 7, "held": [True] * 3}
