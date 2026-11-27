"""Answering a waiting item from the chat session's page (static/chatanswer.js) in a headless Chromium; test_chat_answer.py holds what needs no browser.

The board's frame is stood in for by a small server of this file's own, on another origin than the page: its page counts its loads, says what a test tells it
to say, in the board's message shape, and records what the page posts to it.

The rule: a row of the strip that names a board item opens to the item's frame by a tap, and the newest reply that names the item has it under it; an action in
one place shows in the other; a live frame is never moved or made again; with no word from the frame the plain link is there as before; NO SIDEWAYS SCROLL.

Held here:
  - a row opens and closes, one at a time, its frame made at the first opening and kept; a row without a board address is as before;
  - strip repaints (a re-ordered list, a new row, both tabs, a language change, the list shut and opened) and a growing thread load no frame again;
  - the newest reply naming an item holds the frame, the older one points to it, and the older frame goes only once the newer one has spoken;
  - a message from another origin, another window or about another item, or not of the board's shape, changes nothing; a height is held to a range;
  - markup a reply writes makes no frame, takes no card's look and does not cover a card;
  - a frame that says nothing leaves the plain link, and a late message brings the frame back;
  - a frame whose first word is "answered" (no question shown before) makes its item plain in every place; an open question after that shows normally; an
    answer after a sign-out is the same as a fresh one; a newer reply's such frame leaves the older card's mark; a frame is hidden until its first word;
  - answered and sending show in the strip and under the replies; a closed item is the plain link;
  - a changed question loads its frame once more, and not in a loop; the list's changes and the theme are posted to the frames;
  - with the keyboard up the open list takes the room, the thread keeps about three lines, and the open item's title stays in view;
  - on a touch screen, under the bar of tabs, a plain row's title link, a card's title and its link to the board each give a finger 44 px, a plain row is no
    taller, and the list is cut 4 px below the selected tab's underline, with the keyboard up too, where the open title stays at the list's top;
  - a running command's live block stays under the cards, and neither it nor a reconnect moves or remakes a frame;
  - no sideways scroll at 1280, 390, 360 and 320 px;
  - off, and on another session's page, nothing of this is there.

What a wrong answer costs: an answer typed into a frame is lost when the page repaints, another page's message moves the owner's buttons, a link he could use
disappears behind a frame that never comes, a keyboard that hides what he types about. Runs in a headless Chromium when one is installed (conftest.py), else
is skipped; GitHub CI runs it. Names and texts are invented; the stand-in server stops and every temporary folder is removed as the test ends."""

from __future__ import annotations

import json
import shutil
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

import pytest

from conftest import NAME
from test_board_items_ui import wait_for
from test_chat_layer import OTHER, OTHER_SID, add_session
from test_chat_layer_ui import LIVE_LAST, WAITING, append, live, write
from test_chat_onit_ui import CUT, MOVE_TAB, ONIT_TAB, change, click, promises
from test_chat_session_view_ui import DESKTOP, MEASURE, PHONE, api_chat, check, open_page
from test_chatturns import assistant, human

OPEN = {"state": "open", "height": 200}

PAGE = """<!doctype html><meta charset="utf-8"><body style="margin:0;background:#345">stand-in frame
<script>
const ITEM = %(item)s, LOAD = %(load)d, FIRST = %(first)s;
const say = (data) => parent.postMessage(Object.assign({ source: "stackshot", kind: "answer-frame", v: 1, item: ITEM, height: 200, state: "open", typing: false }, data), "*");
const note = (path, body) => fetch(path, { method: "POST", body: JSON.stringify(Object.assign({ item: ITEM, load: LOAD }, body)) });
addEventListener("message", (e) => {
  if (e.data && e.data.test === "say") say(e.data.data);
  else note("/heard", { origin: e.origin, data: e.data });
});
if (FIRST) say(FIRST);
note("/ready", {});
</script>
"""


class Frames:
    """The stand-in board: `loads` (item, query) of every frame page served, `ready` the loads whose script runs, `heard` what the page posted to a frame,
    `first[item]` what that item's frame says as it loads (None: nothing; unset: open, 200 px high)."""

    def __init__(self):
        self.loads, self.ready, self.heard, self.first = [], [], [], {}
        frames = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                u = urlsplit(self.path)
                parts = u.path.strip("/").split("/")
                if len(parts) != 3 or parts[0] != "items" or parts[2] != "answer-frame" or not parts[1].isdigit():
                    self.send_error(404)
                    return
                item = parts[1]
                frames.loads.append((item, {k: v[0] for k, v in parse_qs(u.query).items()}))
                body = (PAGE % {"item": json.dumps(item), "load": frames.count(item), "first": json.dumps(frames.first.get(item, OPEN))}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self):
                d = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
                (frames.ready if self.path == "/ready" else frames.heard).append(d)
                self.send_response(204)
                self.end_headers()

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.origin = f"http://127.0.0.1:{self.server.server_address[1]}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def url(self, n: int) -> str:
        return f"{self.origin}/items/{n}"

    def count(self, item: str) -> int:
        return sum(1 for i, _ in self.loads if i == item)

    def row(self, n: int, subject: str = "Approve the demo budget") -> dict:
        return {"id": f"item#{n}", "subject": subject, "url": self.url(n)}

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=10)


@pytest.fixture
def frames():
    f = Frames()
    yield f
    f.close()


@pytest.fixture
def other():
    """A second stand-in on an origin of its own: not the board's."""
    f = Frames()
    yield f
    f.close()


@pytest.fixture(autouse=True)
def own_setup(tmp_path, monkeypatch):
    """No setting of the machine's own, and the test's folder removed at its end."""
    monkeypatch.setenv("SALA_CONFIG", str(tmp_path / "sala-config"))
    monkeypatch.delenv("SALA_CHAT_LAYER", raising=False)
    yield
    shutil.rmtree(tmp_path, ignore_errors=True)


# Before any script of the page: api/chat (the strip) answers window.__chat, which a test changes; the thread stays the server's.
STUB = """(() => { if (window.top !== window) return; const real = window.fetch.bind(window); window.__chat = %s;
  window.fetch = (u, o) => String(u) === 'api/chat' ? Promise.resolve(new Response(JSON.stringify(window.__chat), { headers: { 'Content-Type': 'application/json' } })) : real(u, o); })()"""
# the module's two waits, shortened for a test
TIMING = """(() => { if (window.top !== window) return;
  Object.defineProperty(window, 'SalaAnswerFrame', { configurable: true, get() {}, set(v) { Object.assign(v.timing, %s);
    Object.defineProperty(window, 'SalaAnswerFrame', { configurable: true, writable: true, value: v }); } }); })()"""

ROWS = "[...document.querySelectorAll('#chat-strip-wait-panel .wait-row')]"
CARDS = "[...document.querySelectorAll('#chat > .ans-under')]"
KBD = "document.body.classList.contains('ans-kbd')"
SHOWN = "((n) => !!n && n.getClientRects().length > 0 && getComputedStyle(n).visibility !== 'hidden')"


def row(n: int) -> str:
    return f"{ROWS}.find((r) => r.querySelector('.wait-id').textContent === 'item#{n}')"


def row_frame(n: int) -> str:
    return f"{row(n)}.querySelector('.ans-frame')"


def card(i: int) -> str:
    """The i-th card under the replies, from the top; -1 the last."""
    return f"{CARDS}.at({i})"


def card_frame(i: int) -> str:
    return f"{card(i)}.querySelector('.ans-frame')"


def until(ok, what: str, timeout: float = 15.0) -> None:
    end = time.time() + timeout
    while time.time() < end:
        if ok():
            return
        time.sleep(0.05)
    raise AssertionError(what)


def ready(frames: Frames, item: str, n: int = 1) -> None:
    until(lambda: sum(1 for r in frames.ready if r["item"] == item) >= n, f"frame {item} did not load {n} times: {frames.loads}")


def say(browser, frame: str, **data) -> None:
    """The frame at `frame` posts a message of the board's shape to the page, with `data` over it."""
    browser.evaluate(f"{frame}.contentWindow.postMessage({{ test: 'say', data: {json.dumps(data)} }}, '*'); ''")


def wait(browser, expr: str, timeout: float = 15.0) -> None:
    assert wait_for(browser, expr, timeout), expr


def line(browser, node: str) -> str | None:
    """The words of a place's own line, None when it shows none."""
    return browser.evaluate(f"(() => {{ const n = {node}.querySelector('.ans-line'); return n && {SHOWN}(n) ? n.textContent : null; }})()")


def talk(*replies: str) -> list[dict]:
    out = [human("Where do things stand?", 1)]
    for i, text in enumerate(replies):
        out.append(assistant(text, i + 1))
        if i + 1 < len(replies):
            out.append(human("And then?", i + 2))
    return out


def open_answer(browser, served, monkeypatch, waiting: list[dict], replies=("Nothing new to report.",), size=PHONE, layer: str | None = "on",
                timing: dict | None = None, listed: bool = True) -> None:
    """The chat session's page with `waiting` as its first list (opened unless `listed` is False) and `replies` in its thread."""
    write(served, *talk(*replies))
    if layer is None:
        monkeypatch.delenv("SALA_CHAT_LAYER", raising=False)
    else:
        monkeypatch.setenv("SALA_CHAT_LAYER", layer)
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": STUB % json.dumps(api_chat(waiting=waiting))})
    if timing:
        browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": TIMING % json.dumps(timing)})
    open_page(browser, served, monkeypatch, size)
    wait(browser, f"!document.querySelector('#chat-strip').hidden && {ROWS}.length === {len(waiting)}")
    if waiting and listed:
        wait(browser, "!document.querySelector('#chat-strip-wait').hidden")
        click(browser, MOVE_TAB)
        wait(browser, "!document.querySelector('#chat-strip-wait-panel').hidden")


def tap(browser, n: int) -> None:
    click(browser, f"{row(n)}.querySelector('button.ans-head')")


def open_row(browser, frames: Frames, n: int, height: int = 200) -> None:
    before = frames.count(str(n))
    tap(browser, n)
    ready(frames, str(n), before + 1)
    wait(browser, f"{row_frame(n)}.style.height === '{height}px'")


# ── the strip's rows ─────────────────────────────────────────────────────────
@pytest.mark.parametrize("size", [PHONE, DESKTOP], ids=["phone", "desktop"])
def test_a_row_opens_to_its_frame_by_a_tap_one_at_a_time_and_keeps_it(served, browser, monkeypatch, frames, size):
    plain = {"id": "item#3", "subject": "A row from elsewhere", "url": "https://example.com/moves/3"}
    frames.first["1"] = None
    open_answer(browser, served, monkeypatch, [frames.row(1), frames.row(2, "Pick a venue"), plain], size=size)
    assert frames.loads == [], "no frame is made before a row is opened"
    old = browser.evaluate(f"(() => {{ const r = {row(3)}; return [r.querySelectorAll('button, iframe').length, r.querySelector('a.wait-link').href, r.className]; }})()")
    assert old == [0, "https://example.com/moves/3", "wait-row"], old
    assert browser.evaluate(f"{row(1)}.querySelector('button.ans-head').getAttribute('aria-expanded')") == "false"
    assert browser.evaluate(f"{row(1)}.querySelector('button.ans-head').textContent.includes('Approve the demo budget')")
    tap(browser, 1)
    ready(frames, "1")
    assert frames.loads == [("1", {"lang": "en", "theme": "dark"})], frames.loads
    assert browser.evaluate(f"{row_frame(1)}.style.height") == "160px"
    assert browser.evaluate(f"{row_frame(1)}.getAttribute('src').startsWith({json.dumps(frames.url(1) + '/answer-frame?')})")
    assert browser.evaluate(f"!{row_frame(1)}.hasAttribute('sandbox') && {row_frame(1)}.title === 'Answer item#1'")
    say(browser, row_frame(1), height=230)
    wait(browser, f"{row_frame(1)}.style.height === '230px'")
    opened = browser.evaluate(f"""(() => {{ const r = {row(1)}, a = r.querySelector('a.ans-board');
      return [r.querySelector('button.ans-head').getAttribute('aria-expanded'), {SHOWN}({row_frame(1)}), {SHOWN}(a), a.href, a.target, {SHOWN}(r.querySelector(':scope > .wait-subj'))]; }})()""")
    assert opened == ["true", True, True, frames.url(1), "_blank", False], opened
    browser.evaluate(f"window.__f = {row_frame(1)}; window.__w = window.__f.contentWindow; ''")
    tap(browser, 1)
    closed = browser.evaluate(f"[{row(1)}.querySelector('button.ans-head').getAttribute('aria-expanded'), {SHOWN}(window.__f), window.__f.isConnected]")
    assert closed == ["false", False, True], closed
    open_row(browser, frames, 2)
    tap(browser, 1)
    expanded = browser.evaluate(f"{ROWS}.map((r) => r.querySelector('button.ans-head')?.getAttribute('aria-expanded') ?? null)")
    assert expanded == ["true", "false", None], expanded
    assert browser.evaluate(f"{row_frame(1)} === window.__f && window.__f.contentWindow === window.__w")
    assert frames.count("1") == 1 and frames.count("2") == 1, frames.loads


def test_no_repaint_and_no_growing_thread_moves_or_remakes_a_live_frame(served, browser, monkeypatch, frames):
    rows = [frames.row(1), frames.row(2, "Pick a venue"), frames.row(3, "Name the demo")]
    open_answer(browser, served, monkeypatch, rows, replies=("item#1 is ready for your pick.",))
    ready(frames, "1")
    open_row(browser, frames, 1)
    open_row(browser, frames, 2)
    browser.evaluate(f"window.__f = [{row_frame(1)}, {row_frame(2)}, {card_frame(0)}]; window.__w = window.__f.map((f) => f.contentWindow); "
                     "window.__moved = 0; new MutationObserver((rs) => { for (const r of rs) for (const n of r.removedNodes) "
                     "if (n.nodeType === 1 && window.__f.some((f) => n.contains(f))) window.__moved++; }).observe(document.body, { childList: true, subtree: true }); ''")

    def order() -> list[str]:
        return browser.evaluate(f"{ROWS}.map((r) => [r.getBoundingClientRect().top, r.querySelector('.wait-id').textContent]).sort((a, b) => a[0] - b[0]).map((x) => x[1])")

    def same(where: str) -> None:
        got = browser.evaluate("[window.__moved, window.__f.every((f) => f.isConnected), window.__f.every((f, i) => f.contentWindow === window.__w[i])]")
        assert got == [0, True, True], (where, got)
        assert frames.count("1") == 2, (where, frames.loads)

    change(browser, waiting=[rows[2], rows[1], rows[0]])
    wait(browser, f"{row(3)}.getBoundingClientRect().top < {row(1)}.getBoundingClientRect().top")
    assert order() == ["item#3", "item#2", "item#1"]
    same("a re-ordered list")
    change(browser, waiting=[frames.row(4, "A new one"), rows[2], frames.row(2, "Pick a bigger venue"), rows[0]], motion=promises())
    wait(browser, f"{ROWS}.length === 4 && {row(2)}.querySelector('.ans-name').textContent.includes('bigger')")
    assert order() == ["item#4", "item#3", "item#2", "item#1"]
    same("a new row and new words")
    click(browser, ONIT_TAB)
    wait(browser, "!document.querySelector('#chat-strip-onit-panel').hidden")
    click(browser, MOVE_TAB)
    wait(browser, "!document.querySelector('#chat-strip-wait-panel').hidden")
    same("both tabs")
    browser.evaluate("SalaI18n.setLang('ko'); ''")
    wait(browser, f"{row(1)}.querySelector('a.ans-board').textContent === SalaI18n.t('chat.answer.open') && {row_frame(1)}.title === SalaI18n.t('chat.answer.frame', {{ id: 'item#1' }})")
    browser.evaluate("SalaI18n.setLang('en'); ''")
    same("a language change")
    append(served, human("Anything else?", 5), assistant("Only item#2 is new in this one.", 5))
    wait(browser, f"{CARDS}.length === 2")
    ready(frames, "2", 2)
    same("a growing thread")
    change(browser, waiting=[rows[1], rows[0]])
    wait(browser, f"{ROWS}.length === 2")
    assert order() == ["item#2", "item#1"]
    same("rows that left")


def test_the_newest_reply_holds_the_frame_and_the_older_frame_goes_once_the_newer_one_speaks(served, browser, monkeypatch, frames):
    open_answer(browser, served, monkeypatch, [], replies=("item#1 is ready for your pick.",))
    assert browser.evaluate(f"{CARDS}.length") == 0
    change(browser, waiting=[frames.row(1)])   # the list is read after the thread was drawn: the card comes with no new line
    wait(browser, f"{CARDS}.length === 1")
    ready(frames, "1")
    wait(browser, f"{card_frame(0)}.style.height === '200px'")
    under = browser.evaluate(f"(() => {{ const c = {card(0)}; return [c.previousElementSibling.className, c.previousElementSibling.textContent.includes('ready for your pick'), "
                             "c.querySelector('a.wait-link').textContent, c.querySelector('.wait-id').textContent, !c.closest('.msg')]; })()")
    assert "assistant" in under[0] and under[1:] == [True, "Approve the demo budget", "item#1", True], under
    frames.first["1"] = None
    browser.evaluate(f"window.__old = {card_frame(0)}; ''")
    append(served, human("And now?", 3), assistant(f"Still open: {frames.url(1)} waits.", 3))
    wait(browser, f"{CARDS}.length === 2")
    ready(frames, "1", 2)
    both = browser.evaluate(f"[window.__old.isConnected, {SHOWN}(window.__old), !!{card_frame(1)}, {card(0)}.classList.contains('ans-newest'), "
                            f"{card(1)}.classList.contains('ans-newest')]")
    assert both == [True, False, True, False, True], both
    say(browser, card_frame(1), height=210)
    wait(browser, "!window.__old.isConnected")
    assert browser.evaluate(f"{CARDS}.map((c) => c.querySelectorAll('iframe').length)") == [0, 1]
    assert line(browser, card(0)) == browser.evaluate("SalaI18n.t('chat.answer.pointer')")
    assert line(browser, card(1)) is None
    assert frames.count("1") == 2, frames.loads


# ── a frame that never showed a question ─────────────────────────────────────
def plain_looks(browser, n: int) -> list:
    """[row plain, row done, card plain, card done, card line] of the item `n`'s row and its newest card."""
    return browser.evaluate(f"""(() => {{ const r = {row(n)}, c = {CARDS}.filter((x) => x.classList.contains('ans-newest')).at(-1) ?? {card(-1)};
      return [r.classList.contains('ans-plain'), r.classList.contains('ans-done'), c.classList.contains('ans-plain'), c.classList.contains('ans-done'),
        c.querySelector('.ans-line').hidden ? null : c.querySelector('.ans-line').textContent]; }})()""")


def test_a_frames_first_word_of_an_answer_shows_the_item_plain_in_every_place(served, browser, monkeypatch, frames):
    frames.first["1"] = {"state": "answered", "height": 200}
    open_answer(browser, served, monkeypatch, [frames.row(1)], replies=("item#1 is ready.", "item#1 again."))
    ready(frames, "1")
    wait(browser, f"{row(1)}.classList.contains('ans-plain') && {CARDS}.every((c) => c.classList.contains('ans-plain'))")
    got = browser.evaluate(f"""(() => {{ const r = {row(1)}, cs = {CARDS};
      return [r.classList.contains('ans-done'), cs.map((c) => [c.classList.contains('ans-done'), c.querySelector('.ans-line').hidden, c.querySelectorAll('iframe').length]),
        {SHOWN}(r.querySelector('button.ans-head')), {SHOWN}(r.querySelector(':scope > .wait-subj a.wait-link')), {SHOWN}({card_frame(-1)})]; }})()""")
    assert got == [False, [[False, True, 0], [False, True, 1]], False, True, False], got
    assert frames.count("1") == 1, frames.loads


def test_an_item_that_showed_a_question_then_answers_shows_the_answer_in_every_place(served, browser, monkeypatch, frames):
    open_answer(browser, served, monkeypatch, [frames.row(1)], replies=("item#1 is ready.",))
    ready(frames, "1")
    wait(browser, f"{card_frame(0)}.style.height === '200px'")
    say(browser, card_frame(0), state="answered")
    wait(browser, f"{row(1)}.classList.contains('ans-done') && {card(0)}.classList.contains('ans-done')")
    assert plain_looks(browser, 1) == [False, True, False, True, None], plain_looks(browser, 1)
    assert line(browser, row(1)) == browser.evaluate("SalaI18n.t('chat.answer.answered')")


def test_a_newer_reply_whose_frame_first_says_answered_is_plain_and_the_older_card_keeps_its_mark(served, browser, monkeypatch, frames):
    open_answer(browser, served, monkeypatch, [frames.row(1)], replies=("item#1 is ready.",))
    ready(frames, "1")
    wait(browser, f"{card_frame(0)}.style.height === '200px'")
    say(browser, card_frame(0), state="answered")
    wait(browser, f"{card(0)}.classList.contains('ans-done')")
    browser.evaluate(f"window.__old = {card_frame(0)}; ''")
    frames.first["1"] = {"state": "answered", "height": 200}
    append(served, human("And now?", 3), assistant("item#1 again.", 3))
    wait(browser, f"{CARDS}.length === 2")
    ready(frames, "1", 2)
    wait(browser, "!window.__old.isConnected")
    got = browser.evaluate(f"[{card(0)}.classList.contains('ans-plain'), {card(0)}.classList.contains('ans-done'), {card(1)}.classList.contains('ans-plain'), "
                           f"{card(1)}.classList.contains('ans-done'), {SHOWN}({card(1)}.querySelector('iframe') ?? null)]")
    assert got == [False, True, True, False, False], got
    assert line(browser, card(0)) == browser.evaluate("SalaI18n.t('chat.answer.answered')") and line(browser, card(1)) is None


def test_after_a_plain_answer_a_real_question_shows_normally(served, browser, monkeypatch, frames):
    frames.first["1"] = {"state": "answered", "height": 200}
    open_answer(browser, served, monkeypatch, [frames.row(1)], replies=("item#1 is ready.",))
    ready(frames, "1")
    wait(browser, f"{row(1)}.classList.contains('ans-plain') && {card(0)}.classList.contains('ans-plain')")
    frames.first["1"] = {"state": "open", "height": 200}
    append(served, human("And now?", 3), assistant("item#1 needs you.", 3))
    wait(browser, f"{CARDS}.length === 2")
    ready(frames, "1", 2)
    wait(browser, f"{SHOWN}({card_frame(1)}) && {card_frame(1)}.style.height === '200px' && !{card(1)}.classList.contains('ans-plain')")
    assert browser.evaluate(f"[!{row(1)}.classList.contains('ans-plain'), {SHOWN}({row(1)}.querySelector('button.ans-head'))]") == [True, True]


def test_signed_out_then_an_answer_shows_the_item_plain_as_a_fresh_answer_does(served, browser, monkeypatch, frames):
    frames.first["1"] = {"state": "signed_out", "height": 200}
    open_answer(browser, served, monkeypatch, [frames.row(1)], replies=("item#1 is ready.",))
    ready(frames, "1")
    wait(browser, f"{card_frame(0)}.style.height === '200px'")
    say(browser, card_frame(0), state="answered")
    wait(browser, f"{row(1)}.classList.contains('ans-plain') && {card(0)}.classList.contains('ans-plain')")
    assert plain_looks(browser, 1) == [True, False, True, False, None], plain_looks(browser, 1)
    assert browser.evaluate(f"{SHOWN}({card_frame(0)})") is False


def test_a_frame_that_has_not_spoken_is_hidden_until_its_first_word(served, browser, monkeypatch, frames):
    frames.first["1"] = None
    open_answer(browser, served, monkeypatch, [frames.row(1)], replies=("item#1 is ready.",))
    ready(frames, "1")
    assert browser.evaluate(f"getComputedStyle({card_frame(0)}).visibility") == "hidden"
    say(browser, card_frame(0), state="open", height=200)
    wait(browser, f"getComputedStyle({card_frame(0)}).visibility === 'visible'")


# ── messages ─────────────────────────────────────────────────────────────────
def test_only_the_boards_own_message_from_a_frame_of_the_pages_own_changes_anything(served, browser, monkeypatch, frames, other):
    open_answer(browser, served, monkeypatch, [frames.row(1)])
    open_row(browser, frames, 1)
    browser.evaluate("window.__got = 0; addEventListener('message', () => window.__got++); ''")
    frame = row_frame(1)
    state = f"[{frame}.style.height, {row(1)}.className]"
    start = browser.evaluate(state)

    def heard(n: int) -> None:
        wait(browser, f"window.__got >= {n}")

    wrong = [{"item": "2"}, {"item": 1}, {"source": "other"}, {"kind": "other"}, {"v": 2}, {"state": "gone"}]
    for w in wrong:
        say(browser, frame, **{"height": 500, "state": "answered", **w})
    heard(len(wrong))
    # the page's own window posts the right words
    browser.evaluate("window.postMessage({ source: 'stackshot', kind: 'answer-frame', v: 1, item: '1', height: 500, state: 'answered' }, '*'); ''")
    heard(len(wrong) + 1)
    # a frame the page did not make, on another origin, says them
    browser.evaluate(f"window.__x = document.createElement('iframe'); window.__x.src = {json.dumps(other.url(1) + '/answer-frame')}; document.body.append(window.__x); ''")
    ready(other, "1")
    heard(len(wrong) + 2)
    say(browser, "window.__x", height=500, state="answered")
    heard(len(wrong) + 3)
    assert browser.evaluate(state) == start, browser.evaluate(state)
    browser.evaluate("window.__x.remove(); ''")
    for sent, want in ((99999, "2000px"), (10, "40px"), (200.4, "201px"), (300, "300px")):
        say(browser, frame, height=sent)
        wait(browser, f"{frame}.style.height === '{want}'")
    n = browser.evaluate("window.__got")
    for sent in (-5, 0, "700", None):
        say(browser, frame, height=sent)
    heard(n + 4)
    assert browser.evaluate(f"{frame}.style.height") == "300px"
    # the page's own frame taken to another origin: its window is the right one, its origin is not
    other.first["1"] = {"state": "closed", "height": 600}
    n = browser.evaluate("window.__got")
    browser.evaluate(f"{frame}.src = {json.dumps(other.url(1) + '/answer-frame?again')}; ''")
    ready(other, "1", 2)
    heard(n + 1)
    assert browser.evaluate(state) == ["300px", start[1]], browser.evaluate(state)


def test_markup_in_a_reply_makes_no_frame_takes_no_look_and_covers_no_card(served, browser, monkeypatch, frames, other):
    fake = (f'<div class="ans-under ans-newest"><div class="ans-card"><div class="ans-slot"><iframe class="ans-frame" src="{other.url(1)}/answer-frame"></iframe>'
            '</div></div></div>')
    cover = '<div style="position:fixed;left:0;top:0;width:100vw;height:100vh;z-index:2147483647;background:#900">cover</div>'
    open_answer(browser, served, monkeypatch, [frames.row(1)], replies=("item#1 is ready.", f"Look here.\n\n{fake}\n\n{cover}"), listed=False)
    ready(frames, "1")
    wait(browser, f"{card_frame(0)}.style.height === '200px'")
    browser.evaluate(f"{card_frame(0)}.scrollIntoView({{ block: 'center' }}); ''")
    browser.settle("document.querySelector('#chat')")
    # a reply keeps no class (the reply box's sanitizer), so the look-alike card has none of the page's classes and no look at all
    got = browser.evaluate(f"""(() => {{ const f = {card_frame(0)}, r = f.getBoundingClientRect(), fakeCard = document.querySelector('#chat .md [class*="ans-"]');
      return {{ cards: {CARDS}.length, inMd: document.querySelectorAll('#chat .md iframe').length, frames: document.querySelectorAll('#chat iframe').length,
        fake: !!fakeCard, border: fakeCard && getComputedStyle(fakeCard).borderLeftWidth, plain: document.querySelectorAll('#chat .md .ans-card, #chat .md .ans-slot, #chat .md .ans-under').length, top: document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2) === f }}; }})()""")
    assert got == {"cards": 1, "inMd": 0, "frames": 1, "fake": False, "border": None, "plain": 0, "top": True}, got
    assert other.loads == [], other.loads


def test_with_no_word_from_a_frame_the_plain_link_is_there_and_a_late_word_brings_the_frame_back(served, browser, monkeypatch, frames):
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        nobody = f"http://127.0.0.1:{s.getsockname()[1]}"     # an origin nothing answers on once the socket is closed
    dead = nobody + "/items/2"
    frames.first["1"] = None
    rows = [frames.row(1), {"id": "item#2", "subject": "Nobody answers here", "url": dead}]
    open_answer(browser, served, monkeypatch, rows, replies=("item#1 and item#2 both wait.",), timing={"silent": 700})
    wait(browser, f"{CARDS}.length === 2 && {CARDS}.every((c) => c.classList.contains('ans-plain'))")
    cards = browser.evaluate(f"{CARDS}.map((c) => [{SHOWN}(c.querySelector('a.wait-link')), c.querySelector('a.wait-link').href, {SHOWN}(c.querySelector('iframe'))])")
    assert cards == [[True, frames.url(1), False], [True, dead, False]], cards
    tap(browser, 1)
    ready(frames, "1", 2)
    wait(browser, f"{row(1)}.classList.contains('ans-plain')")
    tap(browser, 2)
    wait(browser, f"{row(2)}.classList.contains('ans-plain')")
    for n, url in ((1, frames.url(1)), (2, dead)):
        plain = browser.evaluate(f"""(() => {{ const r = {row(n)}, a = r.querySelector(':scope > .wait-subj a.wait-link'), box = a.getBoundingClientRect();
          return [{SHOWN}(a), a.href, a.target, document.elementFromPoint(box.left + 4, box.top + box.height / 2) === a,
            {SHOWN}(r.querySelector('button.ans-head')), {SHOWN}(r.querySelector('iframe'))]; }})()""")
        assert plain == [True, url, "_blank", True, False, False], (n, plain)
    # the late word: the row's frame and the card's come back
    say(browser, row_frame(1), height=220)
    wait(browser, f"!{row(1)}.classList.contains('ans-plain') && {SHOWN}({row(1)}.querySelector('button.ans-head'))")
    assert browser.evaluate(f"{SHOWN}({row(1)}.querySelector(':scope > .wait-subj'))") is False
    tap(browser, 1)
    wait(browser, f"{SHOWN}({row_frame(1)}) && {row_frame(1)}.style.height === '220px'")
    say(browser, card_frame(0), height=220)
    wait(browser, f"!{card(0)}.classList.contains('ans-plain') && {SHOWN}({card_frame(0)})")


# ── one action, every place ──────────────────────────────────────────────────
def test_sending_and_answered_show_in_the_strip_and_under_the_replies_and_a_closed_item_is_its_link(served, browser, monkeypatch, frames):
    open_answer(browser, served, monkeypatch, [frames.row(1), frames.row(2, "Pick a venue")],
                replies=("item#1 is ready.", "item#1 again, and item#2 too."))
    ready(frames, "1")
    ready(frames, "2")
    wait(browser, f"{CARDS}.length === 3")
    newest = f"{CARDS}.filter((c) => c.classList.contains('ans-newest'))"
    one, two, older = f"{newest}[0]", f"{newest}[1]", card(0)
    open_row(browser, frames, 1)
    tap(browser, 1)   # shut again
    t = lambda key: browser.evaluate(f"SalaI18n.t('{key}')")
    assert line(browser, row(1)) is None
    say(browser, f"{one}.querySelector('iframe')", state="sending")
    wait(browser, f"{row(1)}.querySelector('.ans-line').textContent === SalaI18n.t('chat.answer.sending')")
    assert line(browser, row(1)) == t("chat.answer.sending") and line(browser, older) == t("chat.answer.pointer")
    say(browser, f"{one}.querySelector('iframe')", state="answered")
    wait(browser, f"{row(1)}.classList.contains('ans-done')")
    assert line(browser, row(1)) == t("chat.answer.answered") and line(browser, older) == t("chat.answer.answered")
    assert browser.evaluate(f"[{one}.classList.contains('ans-done'), {older}.classList.contains('ans-done'), {two}.classList.contains('ans-done')]") == [True, True, False]
    # a row that was never opened shows it too, with no frame of its own
    say(browser, f"{two}.querySelector('iframe')", state="answered")
    wait(browser, f"{row(2)}.classList.contains('ans-done')")
    assert line(browser, row(2)) == t("chat.answer.answered") and browser.evaluate(f"!{row_frame(2)}") and frames.count("2") == 1
    say(browser, f"{two}.querySelector('iframe')", state="closed")
    wait(browser, f"{row(2)}.classList.contains('ans-plain')")
    closed = browser.evaluate(f"(() => {{ const r = {row(2)}, c = {two}; return [{SHOWN}(r.querySelector(':scope > .wait-subj a.wait-link')), {SHOWN}(r.querySelector('button')), "
                              f"{SHOWN}(c.querySelector('a.wait-link')), {SHOWN}(c.querySelector('iframe'))]; }})()")
    assert closed == [True, False, True, False], closed
    assert line(browser, row(2)) is None


def test_a_changed_question_loads_its_frame_once_more_and_not_in_a_loop(served, browser, monkeypatch, frames):
    open_answer(browser, served, monkeypatch, [frames.row(1)], timing={"again": 400})
    open_row(browser, frames, 1)
    browser.evaluate(f"window.__f = {row_frame(1)}; window.__h = history.length; ''")
    frames.first["1"] = {"state": "changed", "height": 120}
    say(browser, row_frame(1), state="changed", height=120)
    ready(frames, "1", 2)
    time.sleep(1.5)
    assert frames.count("1") == 2, frames.loads
    assert browser.evaluate(f"[{row_frame(1)} === window.__f, history.length === window.__h]") == [True, True]
    assert line(browser, row(1)) == browser.evaluate("SalaI18n.t('chat.answer.changed')")
    say(browser, row_frame(1), state="open")
    wait(browser, f"{row(1)}.querySelector('.ans-line').hidden")
    time.sleep(0.6)
    say(browser, row_frame(1), state="changed", height=120)
    ready(frames, "1", 3)
    time.sleep(1.5)
    assert frames.count("1") == 3, frames.loads


def test_the_lists_changes_and_the_theme_are_posted_to_the_frames_at_the_boards_origin(served, browser, monkeypatch, frames):
    open_answer(browser, served, monkeypatch, [frames.row(1)], replies=("item#1 is ready.",))
    ready(frames, "1")
    open_row(browser, frames, 1)
    wait(browser, f"{card_frame(0)}.style.height === '200px'")
    assert frames.heard == [], frames.heard
    page = served["url"]

    def told(**what) -> list[dict]:
        want = {"source": "sala", "kind": "answer-frame", "v": 1, **what}
        return [h for h in frames.heard if h["data"] == want and h["origin"] == page]

    change(browser, waiting=[frames.row(1, "Approve the new budget")])
    until(lambda: len({h["load"] for h in told(do="refresh")}) == 2, f"both frames told to read again: {frames.heard}")
    browser.evaluate("document.documentElement.setAttribute('data-theme', 'light'); ''")
    until(lambda: len({h["load"] for h in told(do="theme", theme="light")}) == 2, f"both frames told the theme: {frames.heard}")
    del frames.heard[:]
    change(browser, waiting=[])
    until(lambda: len(told(do="refresh")) >= 1, f"the frame under the reply told the item left: {frames.heard}")
    assert browser.evaluate(f"[{ROWS}.length, {CARDS}.length, !!{card_frame(0)}]") == [0, 1, True]
    assert frames.count("1") == 2, frames.loads


# ── the keyboard ─────────────────────────────────────────────────────────────
GEOMETRY = f"""(() => {{ const box = (s) => document.querySelector(s).getBoundingClientRect(), r = {row(1)}, head = r.querySelector('button.ans-head'),
    h = head.getBoundingClientRect(), name = r.querySelector('.ans-name'), pane = box('#chat-pane'), strip = box('#chat-strip-wait');
  return {{ paneBottom: pane.bottom, stripTop: strip.top, stripBottom: strip.bottom, composerTop: box('#composer').top, headTop: h.top, headBottom: h.bottom,
    headOnTop: head.contains(document.elementFromPoint(h.left + 20, h.top + h.height / 2)), oneLine: getComputedStyle(name).whiteSpace === 'nowrap',
    page: [document.scrollingElement.scrollWidth, document.scrollingElement.clientWidth] }}; }})()"""


def height(browser, h: int) -> None:
    browser.send("Emulation.setDeviceMetricsOverride", {"width": 390, "height": h, "deviceScaleFactor": 1, "mobile": True})
    wait(browser, f"window.innerHeight === {h}")


def kbd_holds(browser, where: str) -> None:
    browser.settle("document.querySelector('#chat-pane')")
    g = browser.evaluate(GEOMETRY)
    assert 60 <= g["paneBottom"] - g["stripBottom"] <= 90, (where, "the thread keeps about three lines", g)
    assert g["stripBottom"] <= g["composerTop"] + 0.5 and g["paneBottom"] <= g["composerTop"] + 0.5, (where, "nothing over the composer", g)
    assert g["stripTop"] - 0.5 <= g["headTop"] and g["headBottom"] <= g["stripBottom"] + 0.5 and g["headOnTop"] and g["oneLine"], (where, "the title", g)
    assert g["page"][0] <= g["page"][1], (where, g)


def test_with_the_keyboard_up_the_open_list_takes_the_room_and_the_title_stays(served, browser, monkeypatch, frames):
    frames.first["1"] = {"state": "open", "height": 900}
    rows = [frames.row(1, "A subject long enough to wrap onto a second and a third line of a phone's narrow strip, and then some more words"), frames.row(2)]
    open_answer(browser, served, monkeypatch, rows, replies=tuple(f"Reply number {i}, with a few words to fill the thread." for i in range(8)))
    browser.touch(True)
    open_row(browser, frames, 1, 900)
    focus = "document.querySelector('#composer .cm-content').focus(); ''"
    browser.evaluate(focus)
    time.sleep(0.3)
    assert not browser.evaluate(KBD), "a focus with the whole screen visible is no keyboard"
    height(browser, 460)
    wait(browser, KBD)
    kbd_holds(browser, "the keyboard up")
    browser.evaluate("document.querySelector('#chat-strip-wait-panel').scrollTop = 600; ''")
    kbd_holds(browser, "the list scrolled")
    browser.evaluate("document.activeElement.blur(); ''")
    wait(browser, f"!{KBD}")
    height(browser, 844)
    browser.evaluate(focus + "; ''")
    time.sleep(0.3)
    assert not browser.evaluate(KBD)
    browser.evaluate("document.activeElement.blur(); ''")
    # a frame says a person types in it
    say(browser, row_frame(1), height=900, typing=True)
    wait(browser, KBD)
    kbd_holds(browser, "typing in the frame")
    say(browser, row_frame(1), height=900, typing=False)
    wait(browser, f"!{KBD}")
    # a shut row takes no room, keyboard or not
    say(browser, row_frame(1), height=900, typing=True)
    wait(browser, KBD)
    tap(browser, 1)
    wait(browser, f"!{KBD}")


def test_a_shorter_window_with_a_mouse_is_no_keyboard(served, browser, monkeypatch, frames):
    open_answer(browser, served, monkeypatch, [frames.row(1)])
    browser.touch(False)
    open_row(browser, frames, 1)
    browser.evaluate("document.querySelector('#composer .cm-content').focus(); ''")
    height(browser, 460)
    time.sleep(0.5)
    assert not browser.evaluate(KBD)


# ── beside the strip's own tap and cut rules, and a running command ──────────
# Every target of the open first list under a finger: the title link of a plain row, a card's own title (a button) and its link to the board. Each is scrolled
# to the middle of the list, and at five places across it the run of pixels that elementFromPoint gives to it is counted upwards and downwards (`short`: the
# places with under 44). `flat`: the heights of the plain rows.
FINGER = """(() => { const w = document.getElementById('chat-strip-wait-panel'); w.style.scrollBehavior = 'auto';
  const shown = (n) => n.getClientRects().length > 0 && getComputedStyle(n).visibility !== 'hidden', kinds = {}, short = [];
  for (const a of [...w.querySelectorAll('.wait-row > .wait-subj a.wait-link, .wait-row button.ans-head, .wait-row a.ans-board')].filter(shown)) {
    const kind = a.classList.contains('wait-link') ? 'link' : a.classList.contains('ans-head') ? 'head' : 'board';
    kinds[kind] = (kinds[kind] || 0) + 1;
    let q = a.getBoundingClientRect(); const b = w.getBoundingClientRect(); w.scrollTop += Math.round((q.top + q.bottom - b.top - b.bottom) / 2); q = a.getClientRects()[0];
    const own = (x, y) => { const n = document.elementFromPoint(x, y); return !!n && a.contains(n); };
    for (const t of [0, 0.25, 0.5, 0.75, 1]) { const x = q.left + 1 + (q.width - 2) * t, mid = Math.floor((q.top + q.bottom) / 2); let up = mid, down = mid, high = 0;
      if (own(x, mid)) { while (own(x, up - 1)) up--; while (own(x, down + 1)) down++; high = down - up + 1; }
      if (high < 44) short.push([a.closest('.wait-row').querySelector('.wait-id').textContent, kind, t, high]); } }
  const flat = [...w.querySelectorAll('.wait-row')].filter((r) => !r.classList.contains('ans') || r.classList.contains('ans-plain')).map((r) => r.getBoundingClientRect().height);
  return { kinds, short, flat, wide: [w.scrollWidth, w.clientWidth] }; })()"""


@pytest.mark.parametrize("size", [PHONE, DESKTOP], ids=["phone", "desktop"])
def test_under_the_bar_of_tabs_every_target_gives_a_finger_44px_and_the_list_is_cut_below_the_underline(served, browser, monkeypatch, frames, size):
    def elsewhere(n: int) -> dict:
        return {"id": f"item#{n}", "subject": f"Elsewhere {n}", "url": f"https://example.com/moves/{n}"}

    # a card, two plain rows, a card, a row whose frame says nothing (the plain link again), and plain rows enough for the list to scroll
    rows = [frames.row(1), elsewhere(2), elsewhere(3), frames.row(4, "Pick a venue"), frames.row(5, "Nobody speaks")] + [elsewhere(n) for n in range(6, 21)]
    frames.first["5"] = None
    open_answer(browser, served, monkeypatch, rows, size=size, timing={"silent": 4000})
    change(browser, motion=promises())
    wait(browser, f"!!{MOVE_TAB}")
    browser.evaluate(f"if (document.querySelector('#chat-strip-wait-panel').hidden) {MOVE_TAB}.click(); ''")
    wait(browser, "document.querySelector('#chat-strip-wait-panel').getClientRects().length > 0")
    browser.touch(True)
    wait(browser, "matchMedia('(pointer: coarse)').matches")
    tap(browser, 5)
    wait(browser, f"{row(5)}.classList.contains('ans-plain')")
    open_row(browser, frames, 1)
    browser.settle("document.querySelector('#chat-strip-wait')")
    got = browser.evaluate(FINGER)
    assert got["kinds"] == {"link": 18, "head": 2, "board": 1}, got
    assert got["short"] == [], ("under 44 px of the target's own at these places (item, kind, how far across, px)", got)
    assert len(got["flat"]) == 18 and max(got["flat"]) <= 45.5, got
    assert got["wide"][0] <= got["wide"][1], got
    for where in ("the list", "the keyboard"):
        if where == "the keyboard":
            say(browser, row_frame(1), height=200, typing=True)
            wait(browser, KBD)
        browser.settle("document.querySelector('#chat-strip-wait')")
        cut = browser.evaluate(CUT.replace("__PANEL__", "chat-strip-wait-panel"))
        assert cut["scrolled"] > 0 and cut["gap"] >= 3.5 and cut["inside"] == [] and cut["below"] == 3, (where, cut)
        assert 3.5 <= cut["rest"] <= 6.5, (where, "at rest the list starts about where it did", cut)
    stuck = browser.evaluate(f"""(() => {{ const w = document.getElementById('chat-strip-wait-panel'); w.scrollTop = 120;
      const under = document.querySelector('#chat-strip-wait .wait-tab[aria-selected="true"]').getBoundingClientRect().bottom;
      const head = {row(1)}.querySelector('button.ans-head'), h = head.getBoundingClientRect(), above = document.elementFromPoint(h.left + 20, under + 2);
      return [Math.round(w.scrollTop), h.top - under, !!(above && above.closest('.wait')), head.contains(document.elementFromPoint(h.left + 20, h.top + h.height / 2))]; }})()""")
    assert stuck[0] == 120 and 3.5 <= stuck[1] <= 5 and stuck[2:] == [False, True], stuck


def test_a_running_commands_live_block_stays_under_the_cards_and_moves_no_frame(served, browser, monkeypatch, frames):
    open_answer(browser, served, monkeypatch, [frames.row(1)], replies=("item#1 is ready.",))
    ready(frames, "1")
    wait(browser, f"{card_frame(0)}.style.height === '200px'")
    browser.evaluate(f"window.__f = {card_frame(0)}; window.__w = window.__f.contentWindow; window.__moved = 0; new MutationObserver((rs) => {{ for (const r of rs) "
                     "for (const n of r.removedNodes) if (n.nodeType === 1 && n.contains(window.__f)) window.__moved++; }).observe(document.body, { childList: true, subtree: true }); ''")

    def same(where: str) -> None:
        got = browser.evaluate("[window.__moved, window.__f.isConnected, window.__f.contentWindow === window.__w]")
        assert got == [0, True, True] and frames.count("1") == 1, (where, got, frames.loads)

    live(browser, WAITING)
    assert browser.evaluate(LIVE_LAST)
    same("a command starting")
    append(served, human("typed in the pane", 3), assistant("Nothing about it.", 4))
    wait(browser, f"document.querySelector('#chat').textContent.includes('Nothing about it.') && {LIVE_LAST}")
    live(browser, {**WAITING, "text": "still waiting"})
    same("a thread growing above the block")
    browser.evaluate("window.__s = state.current; state.es.close(); openStream(window.__s, { resume: true }); ''")
    wait(browser, "!document.querySelector('#live-bang')")
    same("a reconnect")
    live(browser, WAITING)
    wait(browser, LIVE_LAST)
    live(browser, {"running": False})
    assert browser.evaluate("!document.querySelector('#live-bang')")
    same("a command ending")


# ── widths ───────────────────────────────────────────────────────────────────
@pytest.mark.parametrize("width", [1280, 390, 360, 320])
def test_no_sideways_scroll_with_frames_open(served, browser, monkeypatch, frames, width):
    word = "w" * 200
    rows = [frames.row(n, f"[demo] a subject that keeps going and going {word}") for n in (1, 2, 3)]
    frames.first = {n: {"state": "open", "height": 400} for n in ("1", "2", "3")}
    open_answer(browser, served, monkeypatch, rows, replies=(f"item#1 and item#2: {word}", f"item#1 again {word}"),
                size=DESKTOP if width > 700 else (width, 844))
    if width < 700:
        browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 844, "deviceScaleFactor": 1, "mobile": True})
        wait(browser, f"document.documentElement.clientWidth === {width}")
        browser.touch(True)
    wait(browser, f"{CARDS}.length === 3")
    open_row(browser, frames, 1, 400)
    say(browser, card_frame(-1), state="answered", height=400)
    wait(browser, f"{row(1)}.classList.contains('ans-done')")
    for where in ("open", "keyboard"):
        browser.settle("document.querySelector('#chat')")
        check(browser.evaluate(MEASURE), f"{width}px {where}")
        wide = browser.evaluate(f"""[...document.querySelectorAll('.ans-frame')].filter({SHOWN}).map((f) => {{ const r = f.getBoundingClientRect();
          return [r.left >= 0, r.right <= document.documentElement.clientWidth + 0.5, r.width > 200]; }})""")
        assert wide and all(w == [True, True, True] for w in wide), (width, where, wide)
        panel = browser.evaluate("(() => { const p = document.querySelector('#chat-strip-wait-panel'); return [p.scrollWidth, p.clientWidth]; })()")
        assert panel[1] > 0 and panel[0] <= panel[1], (width, where, "the open list scrolls sideways", panel)
        say(browser, row_frame(1), height=400, typing=True)
        wait(browser, KBD)


# ── where nothing of this is ─────────────────────────────────────────────────
def test_with_the_setting_off_the_rows_and_the_thread_are_as_before(served, browser, monkeypatch, frames):
    open_answer(browser, served, monkeypatch, [frames.row(1)], replies=("item#1 is ready.",), layer=None)
    time.sleep(0.5)
    got = browser.evaluate(f"[typeof window.SalaAnswerFrame, document.querySelectorAll('iframe, .ans, .ans-under, .ans-list').length, "
                           f"{ROWS}[0].querySelector('a.wait-link').href, {ROWS}[0].children.length]")
    assert got == ["undefined", 0, frames.url(1), 1], got
    assert frames.loads == []


def test_another_sessions_page_has_nothing_of_it_also_after_the_chat(served, browser, monkeypatch, frames):
    add_session(served, OTHER, OTHER_SID, [human("What waits?", 1), assistant("item#1 is named here too.", 2)])
    open_answer(browser, served, monkeypatch, [frames.row(1)], replies=("item#1 is ready.",))
    ready(frames, "1")
    open_row(browser, frames, 1)
    say(browser, row_frame(1), typing=True)
    wait(browser, KBD)
    browser.evaluate(f"location.hash = '#s={OTHER}'; ''")
    wait(browser, "document.querySelector('#chat').textContent.includes('named here too')")
    wait(browser, f"!{KBD}")
    got = browser.evaluate("[document.querySelectorAll('#chat .ans-under, #chat iframe').length, document.body.classList.contains('chat-session'), "
                           "getComputedStyle(document.querySelector('#chat > .msg')).isolation, document.querySelector('#chat-strip-wait').hidden]")
    assert got == [0, False, "auto", True], got
    loads = len(frames.loads)
    browser.evaluate(f"location.hash = '#s={NAME}'; ''")
    wait(browser, f"{CARDS}.length === 1 && !!{card_frame(0)}")
    until(lambda: len(frames.loads) == loads + 1, f"the thread opened again makes its card's frame again, and the strip keeps its own: {frames.loads}")
    time.sleep(0.5)
    assert len(frames.loads) == loads + 1, frames.loads
