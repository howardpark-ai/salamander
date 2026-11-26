"""The chat session's own layer (SALA_CHAT_LAYER, static/chatlayer.js) in a headless Chromium; test_chat_layer.py holds what needs no browser.

The rule: with the setting on, the chat session's thread holds the owner's messages and the replies to them and nothing else, NO SIDEWAYS SCROLL at any width,
and every other session's page is the page it is with the setting off.

Held here, against the real server:
  - only what GET api/chat/thread answers is drawn, on opening and as the transcript grows: no line between tool calls, no tool card, no subagent or task
    notice, no kept-back line;
  - a sent message shows at once and gives way to the transcript's copy, and an older message with the same words does not take its place;
  - the link cards are the ones the session view draws;
  - the working mark: the open turn's words beside it only in the language of the owner's last message, else the bare mark;
  - older messages come as the reader scrolls up, and the place is kept;
  - a failed read, a reconnect, a long absence, a language change, a reload, a session asleep, not running or gone from the list;
  - while the thread loads (a cold load, a reload, a switch inside the page, the open session opened again), no frame has the strip's rows above it, a message
    still on its way or not; they are there once the thread is, or once its read failed;
  - no sideways scroll at 1280, 390, 360 and 320 px with long words, long addresses, wide tables, wide code and images, and as the width changes;
  - the composer sends the same request with the setting on and off;
  - off, the chat session and another one are drawn by the session view; on, the other session's page is the same, opened directly or from the chat.

What a wrong answer costs: the owner reads the session's own working lines as answers, a reply never arrives or arrives twice, a phone page that scrolls
sideways, another session's page changed by a setting that is not its own. Runs in a headless Chromium when one is installed (conftest.py: `served`,
`browser`), else is skipped; GitHub CI runs it. Names and texts are invented; every temporary folder is removed as the test ends."""

from __future__ import annotations

import base64
import json
import os
import shutil
import struct
import time
import zlib
from datetime import datetime, timezone

import pytest

from conftest import CHAT_READY, CWD, NAME, SID, transcript_file
from test_board_items_ui import wait_for
from test_chat_layer import OTHER, add_session
from test_chat_link_cards_ui import ART, mockup, reply_text
from test_chat_session_view_ui import CODE, DESKTOP, MEASURE, PHONE, SIZES, TABLE, URL, WORD, api_chat, check, open_page
from test_chat_thread import task
from test_chatturns import assistant, human, peer, tool_result
from test_composer_attach import WAIT_CHIPS, pick
from test_sleeping_sessions import wake  # noqa: F401  (a fixture: the stand-in sala and its sleeping markers)

OWNER = "Rowan"
EN, EN_TURN = "Please check the demo build.", "Reading the build log now."
KO_OWNER = "\ub370\ubaa8 \ube4c\ub4dc\ub97c \ud655\uc778\ud574 \uc8fc\uc138\uc694."
KO_TURN = "\ube4c\ub4dc \uae30\ub85d\uc744 \uc77d\uace0 \uc788\uc2b5\ub2c8\ub2e4."

# Before any script of the page: the thread's reads are counted (and fail while window.__fail), and a send is kept and answered here.
SPY = """(() => {
  if (window.__spied) return;
  window.__spied = true;
  const real = window.fetch.bind(window);
  window.__reads = []; window.__sent = []; window.__fail = %s;
  window.fetch = (url, opts) => {
    const u = String(url);
    if (u.startsWith('api/chat/thread')) {
      window.__reads.push(u);
      if (window.__fail) return Promise.resolve(new Response('{}', { status: 502 }));
    }
    if (u.endsWith('/send')) {
      window.__sent.push({ url: u, method: opts.method, headers: opts.headers, body: JSON.parse(opts.body) });
      return Promise.resolve(new Response(JSON.stringify({ ok: true, imagesPasted: 0, imagesAttached: 0 }), { status: 200 }));
    }
    return real(url, opts);
  };
})()"""

# every message of the thread, in order: whose it is and its words
THREAD = """[...document.querySelectorAll('#chat > .msg')].map((m) => [
  m.classList.contains('user') ? 'me' : m.classList.contains('assistant') ? 'reply' : m.className,
  [...m.querySelectorAll(':scope > .bubble, :scope > .md')].map((n) => n.textContent.trim()).join(' / ')])"""

MARK = """(() => { const m = document.querySelector('#chat > .cl-mark'); if (!m) return null; const t = m.querySelector('.cl-turn');
  return { spinner: !!m.querySelector('.spinner'), turn: t.hidden ? '' : t.textContent, title: m.title,
           after: [...document.querySelectorAll('#chat > .msg')].every((n) => !!(n.compareDocumentPosition(m) & Node.DOCUMENT_POSITION_FOLLOWING)),
           others: [...document.querySelectorAll('#chat > .inflight')].filter((n) => getComputedStyle(n).display !== 'none').length }; })()"""

PENDING = "[...document.querySelectorAll('#chat > .msg.local')].map((n) => n.querySelector('.bubble').textContent)"
LAYERED = "document.body.classList.contains('chat-layer')"
LAYER_NODES = "document.querySelectorAll('#chat > .cl-older, #chat > .cl-fail, #chat > .cl-mark').length"


@pytest.fixture(autouse=True)
def own_setup(tmp_path, monkeypatch):
    """No setting of the machine's own, the owner's name of these texts, and the test's folder removed at its end."""
    monkeypatch.setenv("SALA_CONFIG", str(tmp_path / "sala-config"))
    monkeypatch.setenv("SALA_OWNER_NAME", OWNER)
    monkeypatch.delenv("SALA_CHAT_LAYER", raising=False)
    yield
    shutil.rmtree(tmp_path, ignore_errors=True)


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def write(served, *lines: dict) -> None:
    transcript_file(served).write_text("".join(json.dumps(d) + "\n" for d in lines), encoding="utf-8")


def append(served, *lines: dict) -> None:
    with transcript_file(served).open("a", encoding="utf-8") as f:
        f.write("".join(json.dumps(d) + "\n" for d in lines))


def session_status(served, status: str) -> None:
    f = served["settings"].claude_dir / "sessions" / f"{os.getpid()}.json"
    d = json.loads(f.read_text())
    d["status"] = status
    f.write_text(json.dumps(d))


def end_session(served) -> None:
    (served["settings"].claude_dir / "sessions" / f"{os.getpid()}.json").unlink()


def open_chat(browser, served, monkeypatch, size=PHONE, layer: str | None = "on", fail: bool = False, hash_=None, ready: bool = True, doc=None) -> None:
    if layer is None:
        monkeypatch.delenv("SALA_CHAT_LAYER", raising=False)
    else:
        monkeypatch.setenv("SALA_CHAT_LAYER", layer)
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": SPY % ("true" if fail else "false")})
    if doc is not None:
        # api/chat (the strip) answers `doc`; api/chat/thread stays the server's
        browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": """(() => { const real = window.fetch.bind(window);
          window.fetch = (u, o) => String(u) === 'api/chat'
            ? Promise.resolve(new Response(JSON.stringify(%s), { headers: { 'Content-Type': 'application/json' } })) : real(u, o); })()""" % json.dumps(doc)})
    open_page(browser, served, monkeypatch, size, hash_=hash_, ready=ready)


def thread_is(browser, want: list, timeout: float = 20.0) -> None:
    same = json.dumps(want, separators=(",", ":"), ensure_ascii=False)
    wait_for(browser, f"JSON.stringify({THREAD}) === {json.dumps(same)}", timeout)
    assert browser.evaluate(THREAD) == want


def typed(text: str) -> str:
    """The script that writes a message and taps Send: setText alone leaves the button off, as the app's own callers know."""
    return f"setText({json.dumps(text)}); refreshSendButton(); document.querySelector('#send').click(); ''"


def send(browser, text: str) -> None:
    browser.evaluate(typed(text))


def mixed() -> list[dict]:
    """A turn of the owner's with a tool call and a subagent's line in it, two turns something else started (one marked for the owner) and a job's notice."""
    return [human(EN, 1),
            assistant("Reading the build log first.", 1, stop="tool_use", tool=True), tool_result(1),
            {**assistant("A subagent is narrating.", 1), "isSidechain": True},
            assistant("The demo build passed.", 2),
            peer("Another Claude session sent a message:\nfrom: demo-third\n\nPeer text here.", 3),
            assistant("Checking the peer's note.", 3, stop="tool_use", tool=True), tool_result(3),
            assistant("Noted for the record.", 3),
            task(4), assistant("Filed the finished job.", 4),
            peer("Another Claude session sent a message:\nfrom: demo-third\n\nSecond note.", 5),
            assistant(f"[for {OWNER}] A demo step needs your answer.", 5)]


SHOWN = [["me", EN], ["reply", "The demo build passed."], ["reply", "A demo step needs your answer."]]
NEVER = ["Reading the build log", "subagent is narrating", "Peer text", "Checking the peer", "Noted for the record", "Filed the finished job", "job finished",
         "Second note"]


# ── what is drawn ────────────────────────────────────────────────────────────
@pytest.mark.parametrize("size", SIZES)
def test_only_the_owners_messages_and_the_replies_to_them_are_drawn_also_as_the_thread_grows(served, browser, monkeypatch, size):
    write(served, *mixed())
    open_chat(browser, served, monkeypatch, size)
    thread_is(browser, SHOWN)
    assert browser.evaluate(LAYERED)
    clean = "(() => { const c = document.querySelector('#chat'); return [c.textContent, c.querySelectorAll('details, .kept, .notice, .tool, .cmd').length]; })()"
    words, cards = browser.evaluate(clean)
    assert cards == 0 and not [w for w in NEVER if w in words], words
    browser.evaluate("window.__first = document.querySelector('#chat > .msg'); ''")
    append(served, human("And the tests?", 6), assistant("Running them now, one moment.", 6, stop="tool_use", tool=True), tool_result(6))
    thread_is(browser, SHOWN + [["me", "And the tests?"]])
    append(served, assistant("All the tests passed.", 7))
    thread_is(browser, SHOWN + [["me", "And the tests?"], ["reply", "All the tests passed."]])
    append(served, task(8), assistant("Another job was filed.", 8), human("Thanks.", 9))
    thread_is(browser, SHOWN + [["me", "And the tests?"], ["reply", "All the tests passed."], ["me", "Thanks."]])
    words, cards = browser.evaluate(clean)
    assert cards == 0 and "Running them now" not in words and "Another job" not in words, words
    assert browser.evaluate("window.__first === document.querySelector('#chat > .msg')"), "a drawn message is not drawn again"
    assert browser.evaluate("!document.querySelector('#chat > .cl-mark')"), "an idle session has no working mark"


@pytest.mark.parametrize("size", SIZES)
def test_the_link_cards_are_the_ones_the_session_view_draws(served, browser, monkeypatch, size):
    mockup(served, 3, "Pricing page")
    write(served, human("show me the pages", 1), assistant(reply_text(), 2))
    cards = ("[...document.querySelectorAll('#chat .msg.assistant a.link-card')].map((a) => [a.getAttribute('href'), a.querySelector('.lc-t').textContent, "
             "a.target, a.rel])")
    open_chat(browser, served, monkeypatch, size, layer=None)
    assert wait_for(browser, f"{cards}.length >= 2", 20.0)
    plain = browser.evaluate(cards)
    open_chat(browser, served, monkeypatch, size)
    assert wait_for(browser, f"{LAYERED} && {cards}.length >= {len(plain)}", 20.0)
    assert browser.evaluate(cards) == plain
    assert [c[0] for c in plain][:2] == ["mockup/3", ART] and plain[0][1] == "Pricing page", plain
    # a reply that arrives while the page is open has its card too
    append(served, human("one more", 3), assistant("Here: [the page again](/mockup/3).", 4))
    assert wait_for(browser, f"{cards}.length === {len(plain) + 1}", 20.0), browser.evaluate(cards)


# ── a sent message ───────────────────────────────────────────────────────────
@pytest.mark.parametrize("size", SIZES)
def test_a_sent_message_shows_at_once_and_gives_way_to_the_transcripts_copy(served, browser, monkeypatch, size):
    write(served, human("go on", 1), assistant("Done.", 2))
    open_chat(browser, served, monkeypatch, size)
    thread_is(browser, [["me", "go on"], ["reply", "Done."]])
    send(browser, "go on")
    assert browser.evaluate(PENDING) == ["go on"], "shown before any answer"
    # a read of the thread leaves it: the older message with the same words is not its copy
    browser.evaluate("SalaThreadLayer.refresh()")
    assert browser.evaluate(PENDING) == ["go on"]
    thread_is(browser, [["me", "go on"], ["reply", "Done."], ["me", "go on"]])
    sent = human("go on")
    sent["timestamp"] = now()
    append(served, sent)
    assert wait_for(browser, f"!document.querySelector('#chat > .msg.local') && !!document.querySelector('#chat > .msg[data-uuid=\"{sent['uuid']}\"]')", 20.0)
    thread_is(browser, [["me", "go on"], ["reply", "Done."], ["me", "go on"]])
    assert browser.evaluate("state.pending.length") == 0
    append(served, assistant("Going on.", 3))
    thread_is(browser, [["me", "go on"], ["reply", "Done."], ["me", "go on"], ["reply", "Going on."]])


def test_the_composer_sends_the_same_request_with_the_setting_on_and_off(served, browser, monkeypatch):
    got = {}
    for layer in (None, "on"):
        write(served, human("go on", 1), assistant("Done.", 2))
        open_chat(browser, served, monkeypatch, PHONE, layer=layer)
        assert browser.evaluate(LAYERED) is (layer == "on")
        pick(browser, "demo notes.txt", "text/plain", b"made-up notes\n")
        chips = browser.evaluate(WAIT_CHIPS % 1)
        assert chips["chips"] == 1 and chips["uploading"] == 0, chips
        send(browser, "Read the notes.\nThen answer.")
        assert wait_for(browser, "window.__sent.length === 1", 10.0)
        sent = browser.evaluate("window.__sent[0]")
        assert sent["body"]["uploads"] == chips["names"], sent
        sent["body"]["uploads"] = [n.rsplit("/", 1)[-1] for n in sent["body"]["uploads"]]   # the folder a file is stored in is new each time
        assert wait_for(browser, "state.pending.length === 1 && state.pending[0].status === 'sent'", 10.0)
        bubble = browser.evaluate("(() => { const b = document.querySelector('#chat > .msg.local'); return [b.className, b.querySelector('.bubble').textContent, "
                                  "b.querySelector('.sf-name').textContent]; })()")
        got[layer] = (sent, bubble, browser.evaluate("[document.querySelectorAll('#chips .chip').length, getText()]"))
    assert got["on"] == got[None], got
    assert got["on"][0]["method"] == "POST" and got["on"][0]["url"] == f"api/s/{os.getpid()}/send", got
    assert got["on"][0]["body"]["text"] == "Read the notes.\nThen answer." and got["on"][2] == [0, ""], got


# ── the working mark ─────────────────────────────────────────────────────────
@pytest.mark.parametrize("served", [{"status": "busy"}], indirect=True)
@pytest.mark.parametrize("asked,turn,shown", [(EN, EN_TURN, True), (KO_OWNER, EN_TURN, False), (KO_OWNER, KO_TURN, True), (EN, KO_TURN, False)],
                         ids=["latin-latin", "korean-latin", "korean-korean", "latin-korean"])
def test_the_working_mark_shows_the_turns_words_only_in_the_language_of_the_owners_last_message(served, browser, monkeypatch, asked, turn, shown):
    write(served, human(asked, 1), assistant(turn + "\n\nMore detail follows.", 1, stop="tool_use", tool=True), tool_result(1))
    open_chat(browser, served, monkeypatch)
    thread_is(browser, [["me", asked]])
    assert wait_for(browser, "!!document.querySelector('#chat > .cl-mark')", 20.0)
    m = browser.evaluate(MARK)
    assert m["spinner"] and m["turn"] == (turn if shown else "") and m["after"] and m["others"] == 0 and m["title"], m
    # the next line of the same turn takes its place under the same rule
    second = turn.replace(".", " again.")
    append(served, assistant(second, 2, stop="tool_use", tool=True), tool_result(2))
    if shown:
        assert wait_for(browser, f"document.querySelector('#chat .cl-turn').textContent === {json.dumps(second)}", 20.0), browser.evaluate(MARK)
    thread_is(browser, [["me", asked]])
    assert browser.evaluate(MARK)["turn"] == (second if shown else "")
    # the reply ends the turn: the mark goes
    append(served, assistant("The reply.", 3))
    session_status(served, "idle")
    assert wait_for(browser, "!document.querySelector('#chat > .cl-mark')", 20.0)
    thread_is(browser, [["me", asked], ["reply", "The reply."]])


@pytest.mark.parametrize("served", [{"status": "busy"}], indirect=True)
def test_a_message_just_sent_sets_the_language_the_mark_is_held_against(served, browser, monkeypatch):
    write(served, human(KO_OWNER, 1), assistant(EN_TURN, 1, stop="tool_use", tool=True), tool_result(1))
    open_chat(browser, served, monkeypatch)
    assert wait_for(browser, "!!document.querySelector('#chat > .cl-mark')", 20.0)
    assert browser.evaluate(MARK)["turn"] == ""
    send(browser, "go on in English please")
    assert wait_for(browser, f"document.querySelector('#chat .cl-turn').textContent === {json.dumps(EN_TURN)}", 10.0), browser.evaluate(MARK)
    m = browser.evaluate(MARK)
    assert m["after"], "the mark stays under the bubble"


# ── older messages ───────────────────────────────────────────────────────────
@pytest.mark.parametrize("size", SIZES)
def test_older_messages_come_as_the_reader_scrolls_up_and_the_place_is_kept(served, browser, monkeypatch, size):
    turns = 130                                                       # 260 messages, more than one page (200)
    write(served, *[d for i in range(turns) for d in (human(f"question {i}", 1), assistant(f"answer {i}", 1))])
    every = [row for i in range(turns) for row in (["me", f"question {i}"], ["reply", f"answer {i}"])]
    open_chat(browser, served, monkeypatch, size)
    assert wait_for(browser, "document.querySelectorAll('#chat > .msg').length === 200", 30.0)
    assert browser.evaluate(THREAD) == every[-200:]
    assert browser.evaluate("!!document.querySelector('#chat > .cl-older') && distFromBottom() < 80"), "opens at the end"
    top = browser.evaluate("(() => { const p = pane(), m = document.querySelector('#chat > .msg'); p.scrollTop = 0; window.__top = m; "
                           "return m.getBoundingClientRect().top - p.getBoundingClientRect().top; })()")
    assert wait_for(browser, f"document.querySelectorAll('#chat > .msg').length === {2 * turns}", 30.0)
    assert browser.evaluate(THREAD) == every
    moved = browser.evaluate("window.__top.getBoundingClientRect().top - pane().getBoundingClientRect().top") - top
    assert abs(moved) <= 2, moved
    assert browser.evaluate("document.querySelector('#chat > .cl-older').textContent") == "Start of this conversation"
    assert [u for u in browser.evaluate("window.__reads") if "before=" in u]
    # a new message while the reader is up there: it is added at the end and the place stays
    place = browser.evaluate("pane().scrollTop")
    append(served, human("a later question", 2))
    assert wait_for(browser, f"document.querySelectorAll('#chat > .msg').length === {2 * turns + 1}", 20.0)
    assert abs(browser.evaluate("pane().scrollTop") - place) <= 2
    assert wait_for(browser, "!document.querySelector('#jump').hidden", 5.0)


# ── trouble ──────────────────────────────────────────────────────────────────
def test_a_failed_read_says_so_offers_retry_and_tries_again_by_itself(served, browser, monkeypatch):
    write(served, human("go on", 1), assistant("Done.", 2))
    open_chat(browser, served, monkeypatch, fail=True, ready=False, doc=strip_doc())
    assert wait_for(browser, "!!document.querySelector('#chat > .cl-fail')", 20.0)
    # a read that failed is not a thread still loading: the strip's rows are there
    assert wait_for(browser, "document.querySelectorAll('#chat-strip .mo').length >= 1 && "
                             "document.querySelector('#chat-strip').getClientRects().length > 0", 20.0)
    assert browser.evaluate("[document.querySelectorAll('#chat > .msg').length, document.querySelectorAll('#chat > .empty').length]") == [0, 0]
    assert browser.evaluate("document.querySelector('#chat .cl-fail span').textContent")
    browser.evaluate("window.__fail = false; document.querySelector('#chat .cl-fail button').click(); ''")
    thread_is(browser, [["me", "go on"], ["reply", "Done."]])
    assert wait_for(browser, "!document.querySelector('#chat > .cl-fail')", 5.0)
    # a later read fails: what was read stays, and the next try needs no tap
    browser.evaluate("window.__fail = true; SalaThreadLayer.refresh()")
    assert wait_for(browser, "!!document.querySelector('#chat > .cl-fail')", 10.0)
    thread_is(browser, [["me", "go on"], ["reply", "Done."]])
    browser.evaluate("window.__fail = false; ''")
    assert wait_for(browser, "!document.querySelector('#chat > .cl-fail')", 40.0)
    thread_is(browser, [["me", "go on"], ["reply", "Done."]])


@pytest.mark.parametrize("missed", [1, 30], ids=["a-little", "more-than-one-read"])
def test_a_reconnect_keeps_what_is_shown_and_brings_what_was_missed_once(served, browser, monkeypatch, missed):
    """30 missed turns are 60 messages, more than a live read asks for (40): the layer follows older pages until they meet what it holds."""
    write(served, human("go on", 1), assistant("Done.", 2))
    open_chat(browser, served, monkeypatch)
    thread_is(browser, [["me", "go on"], ["reply", "Done."]])
    browser.evaluate("window.__first = document.querySelector('#chat > .msg'); window.__s = state.current; state.es.close(); window.__reads.length = 0; ''")
    append(served, *[d for i in range(missed) for d in (human(f"question {i}", 3), assistant(f"answer {i}", 3))])
    browser.evaluate("openStream(window.__s, { resume: true }); ''")
    thread_is(browser, [["me", "go on"], ["reply", "Done."]] + [row for i in range(missed) for row in (["me", f"question {i}"], ["reply", f"answer {i}"])])
    assert browser.evaluate("window.__first === document.querySelector('#chat > .msg')")
    assert bool([u for u in browser.evaluate("window.__reads") if "before=" in u]) is (missed > 20)


def test_a_language_change_rewords_the_layer_and_leaves_the_messages(served, browser, monkeypatch):
    session_status(served, "busy")
    write(served, human("go on", 1), assistant("Done.", 2), human("and more", 3))
    open_chat(browser, served, monkeypatch)
    rows = [["me", "go on"], ["reply", "Done."], ["me", "and more"]]
    thread_is(browser, rows)
    assert wait_for(browser, "!!document.querySelector('#chat > .cl-mark')", 10.0)
    words = ("[document.querySelector('#chat > .cl-older').textContent, document.querySelector('#chat > .cl-mark').title, "
             "document.querySelector('#chat > .cl-mark').getAttribute('aria-label')]")
    english = browser.evaluate(words)
    assert english == ["Start of this conversation", "Working", "Working"]
    browser.evaluate("SalaI18n.setLang('ko'); ''")
    hangul = "(w) => /\\p{Script=Hangul}/u.test(w)"
    assert wait_for(browser, f"{words}.every({hangul})", 10.0), browser.evaluate(words)
    thread_is(browser, rows)
    browser.evaluate("SalaI18n.setLang('en'); ''")
    assert wait_for(browser, f"JSON.stringify({words}) === {json.dumps(json.dumps(english, separators=(',', ':')))}", 10.0)


def test_a_reload_draws_the_thread_once_and_a_setting_turned_off_gives_the_session_view_back(served, browser, monkeypatch):
    write(served, *mixed())
    open_chat(browser, served, monkeypatch)
    thread_is(browser, SHOWN)
    browser.reload(CHAT_READY)
    thread_is(browser, SHOWN)
    assert browser.evaluate(LAYERED) and browser.evaluate("document.querySelectorAll('#chat > .cl-older').length") == 1
    monkeypatch.setenv("SALA_CHAT_LAYER", "off")
    browser.reload(CHAT_READY)
    assert wait_for(browser, "document.querySelector('#chat').textContent.includes('Reading the build log first.')", 20.0)
    assert not browser.evaluate(LAYERED) and browser.evaluate("typeof window.SalaThreadLayer") == "undefined"


def test_a_session_that_is_not_running_shows_what_sala_shows(served, browser, monkeypatch):
    end_session(served)
    open_chat(browser, served, monkeypatch, ready=False)
    assert wait_for(browser, "!!document.querySelector('#chat > .empty a[href=\"#sessions\"]')", 20.0)
    assert not browser.evaluate(LAYERED) and browser.evaluate(LAYER_NODES) == 0 and browser.evaluate("window.__reads") == []


def test_a_session_that_leaves_the_list_keeps_its_thread_under_the_same_rule_and_is_read_no_more(served, browser, monkeypatch):
    write(served, *mixed())
    open_chat(browser, served, monkeypatch)
    thread_is(browser, SHOWN)
    end_session(served)
    browser.evaluate("loadSessions()")
    assert wait_for(browser, f"!state.byName.has('{NAME}')", 20.0)
    thread_is(browser, SHOWN)
    reads = browser.evaluate("window.__reads.length")
    browser.evaluate(f"SalaThreadLayer.status({{ name: '{NAME}' }}); SalaThreadLayer.refresh()")
    thread_is(browser, SHOWN)
    assert browser.evaluate("window.__reads.length") == reads
    assert browser.evaluate(LAYERED) and browser.evaluate("document.querySelectorAll('#chat > .cl-mark, #chat > .cl-older').length") == 0


def test_a_sleeping_chat_session_is_shown_as_sala_shows_it_and_the_layer_returns_when_it_wakes(wake, served, browser, monkeypatch):  # noqa: F811
    write(served, *mixed())
    record = served["settings"].claude_dir / "sessions" / f"{os.getpid()}.json"
    live = record.read_text()
    open_chat(browser, served, monkeypatch)
    thread_is(browser, SHOWN)
    # it goes to sleep while open
    record.unlink()
    wake.sleeper(uuid=SID, name=NAME, cwd=CWD)
    browser.evaluate("loadSessions()")
    assert wait_for(browser, "!document.querySelector('#sleep-band').hidden && document.querySelector('#chat').textContent.includes('Reading the build log first.')", 20.0)
    assert not browser.evaluate(LAYERED) and browser.evaluate(LAYER_NODES) == 0
    # opened asleep, from a fresh load
    browser.reload(CHAT_READY)
    assert wait_for(browser, "!document.querySelector('#sleep-band').hidden", 20.0)
    assert not browser.evaluate(LAYERED) and browser.evaluate("window.__reads") == []
    # awake again
    wake.wake_up(SID)
    record.write_text(live)
    browser.evaluate("loadSessions()")
    assert wait_for(browser, f"{LAYERED} && document.querySelector('#sleep-band').hidden", 20.0)
    thread_is(browser, SHOWN)


# ── while the thread loads ───────────────────────────────────────────────────
# Before any script of the page: the thread's reads wait while window.__hold, and every frame of the layer's page in which the strip's rows are laid out while
# no message of the thread is there yet is noted.
HOLD = """(() => {
  if (window.__above) return;
  window.__above = []; window.__hold = true; window.__held = 0;
  const real = window.fetch.bind(window);
  window.fetch = (u, o) => {
    if (!String(u).startsWith('api/chat/thread') || !window.__hold) return real(u, o);
    window.__held++;
    return new Promise((res, rej) => { (function wait() { if (window.__hold) setTimeout(wait, 30); else real(u, o).then(res, rej); })(); });
  };
  const look = () => {
    const s = document.querySelector('#chat-strip');
    if (s && s.getClientRects().length && document.body.classList.contains('chat-layer') && !document.querySelector('#chat > .msg:not(.local)'))
      window.__above.push(s.textContent.trim().slice(0, 40));
    requestAnimationFrame(look);
  };
  requestAnimationFrame(look);
})()"""

# [the loading line is in the thread, the strip is laid out]
ABOVE = """[!!document.querySelector('#chat > .empty[data-i18n="app.loadingTranscript"]'), document.querySelector('#chat-strip').getClientRects().length > 0]"""
FRAMES = "new Promise((res) => { let n = 6; (function next() { if (n--) requestAnimationFrame(next); else res(true); })(); })"


def held_then_shown(browser) -> None:
    """A thread whose read is held: the strip has its rows and none of them is on screen; then the thread arrives and the strip is there."""
    assert wait_for(browser, f"window.__held >= 1 && document.querySelectorAll('#chat-strip .mo').length >= 1 && {ABOVE}[0]", 30.0)
    assert browser.evaluate(FRAMES)
    assert browser.evaluate(ABOVE) == [True, False]
    assert browser.evaluate("!document.querySelector('#chat-strip').hidden && document.querySelector('#chat-strip-wait').getClientRects().length > 0"), \
        "only the rows that scroll with the thread are held back: the pinned line stays"
    browser.evaluate("window.__hold = false; ''")
    thread_is(browser, SHOWN)
    assert browser.evaluate(FRAMES)
    assert browser.evaluate(ABOVE) == [False, True]
    assert browser.evaluate("document.querySelector('#chat-strip .mo').getClientRects().length > 0")
    assert browser.evaluate("window.__above") == []


@pytest.mark.parametrize("size", SIZES)
def test_the_strips_rows_are_never_on_screen_above_a_loading_thread(served, browser, monkeypatch, size):
    write(served, *mixed())
    add_session(served, OTHER, "22222222-3333-4444-5555-666666666666", other_lines())
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": HOLD})
    # a cold load
    open_chat(browser, served, monkeypatch, size, ready=False, doc=strip_doc())
    held_then_shown(browser)
    # a reload
    browser.reload()
    held_then_shown(browser)
    # a switch inside the page: to another session and back
    browser.evaluate(f"go('#s={OTHER}'); ''")
    other_ready(browser)
    browser.evaluate("window.__above = []; window.__held = 0; window.__hold = true; ''")
    browser.evaluate(f"go('#s={NAME}'); ''")
    held_then_shown(browser)
    # the open session opened again where it is, its thread already read
    browser.evaluate("window.__above = []; window.__held = 0; window.__hold = true; ''")
    browser.evaluate(f"selectSession('{NAME}', {{ force: true }}); ''")
    held_then_shown(browser)


# [messages of the thread, lines that stand for an empty one (the loading line among them), the strip is laid out]
UNDER = """[document.querySelectorAll('#chat > .msg:not(.local)').length, document.querySelectorAll('#chat > .empty').length,
    document.querySelector('#chat-strip').getClientRects().length > 0]"""


def under_a_bubble(browser, sent: list[str]) -> None:
    """A thread whose read is held, with messages on their way and so no loading line: none of the strip's rows is on screen until the thread is in."""
    assert wait_for(browser, f"window.__held >= 1 && document.querySelectorAll('#chat > .msg.local').length === {len(sent)} && "
                             "document.querySelectorAll('#chat-strip .mo').length >= 1", 30.0)
    assert browser.evaluate(FRAMES)
    assert browser.evaluate(PENDING) == sent
    assert browser.evaluate(UNDER) == [0, 0, False]
    assert browser.evaluate("!document.querySelector('#chat-strip').hidden")


def arrives(browser, sent: list[str]) -> None:
    browser.evaluate("window.__hold = false; ''")
    thread_is(browser, SHOWN + [["me", text] for text in sent])
    assert browser.evaluate(FRAMES)
    assert browser.evaluate(UNDER) == [len(SHOWN), 0, True]
    assert browser.evaluate("window.__above") == []


@pytest.mark.parametrize("size", SIZES)
def test_a_message_on_its_way_does_not_bring_the_strips_rows_onto_a_loading_thread(served, browser, monkeypatch, size):
    write(served, *mixed())
    add_session(served, OTHER, "22222222-3333-4444-5555-666666666666", other_lines())
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": HOLD})
    # sent while the first read is out: the bubble takes the loading line's place
    open_chat(browser, served, monkeypatch, size, ready=False, doc=strip_doc())
    assert wait_for(browser, f"window.__held >= 1 && document.querySelectorAll('#chat-strip .mo').length >= 1 && {ABOVE}[0]", 30.0)
    first, second = "Sent while loading.", "And one more."
    send(browser, first)
    under_a_bubble(browser, [first])
    # away and back with it still on its way: the thread is drawn with the bubble and no loading line
    browser.evaluate(f"go('#s={OTHER}'); ''")
    other_ready(browser)
    browser.evaluate("window.__above = []; window.__held = 0; window.__hold = true; ''")
    browser.evaluate(f"go('#s={NAME}'); ''")
    under_a_bubble(browser, [first])
    arrives(browser, [first])
    # opened again where it is, and a message sent in that very task
    browser.evaluate("window.__above = []; window.__held = 0; window.__hold = true; ''")
    browser.evaluate(f"selectSession('{NAME}', {{ force: true }}); {typed(second)}")
    under_a_bubble(browser, [first, second])
    arrives(browser, [first, second])


def test_a_loading_thread_the_layer_does_not_draw_has_the_strip_it_has_today(served, browser, monkeypatch):
    """Off, the chat session's loading line has the strip above it, as it did; another session has no strip, off or on."""
    write(served, *mixed())
    add_session(served, OTHER, "22222222-3333-4444-5555-666666666666", other_lines())
    other = {}
    for layer in ("off", "on"):
        open_chat(browser, served, monkeypatch, PHONE, layer=layer, doc=strip_doc())
        assert wait_for(browser, "document.querySelectorAll('#chat-strip .mo').length >= 1", 20.0)
        if layer == "off":
            assert browser.evaluate(f"selectSession('{NAME}', {{ force: true }}); {ABOVE}") == [True, True]
        browser.evaluate(f"go('#s={OTHER}'); ''")
        other_ready(browser)
        other[layer] = browser.evaluate(f"selectSession('{OTHER}', {{ force: true }}); {ABOVE}.concat(document.body.classList.contains('chat-layer'))")
    assert other["on"] == other["off"] == [True, False, False]


# ── no sideways scroll ───────────────────────────────────────────────────────
def png(width: int, height: int) -> bytes:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    rows = (b"\x00" + b"\x80" * (width * 3)) * height
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


def hostile(served) -> list[dict]:
    mockup(served, 3, "A very long page title " * 6 + WORD)
    image = {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": base64.b64encode(png(2400, 60)).decode()}}
    pair = f"| name | value |\n|---|---|\n| {'n' * 90} | {URL} |\n"
    deep = "".join(f"{'  ' * i}- level {i} {'d' * 60}\n" for i in range(7))
    reply = (f"Here: {WORD}\n\n{URL}\n\n[{'a long link text ' * 12}{WORD}]({URL})\n\n```\n{CODE}\n{WORD}\n```\n\n{TABLE}\n{pair}\n{deep}\n"
             f"`{'c' * 200}`\n\n# {WORD}\n\n> {WORD}\n\nThe page: [{'t' * 150}](/mockup/3)\n")
    # the picture's own message has a uuid as a transcript writes it: the image route refuses the helpers' short ids
    return [human([{"type": "text", "text": f"{WORD} {URL}"}, image], 1, uuid="33333333-4444-4555-8666-777777777777"), assistant(reply, 2),
            human("keep going " + WORD, 3), assistant("Working through " + "a long line of turn text " * 20, 3, stop="tool_use", tool=True), tool_result(3)]


# the layer's own tables, images, code blocks and bubbles: MEASURE leaves tables to sala's rule for every session, which the layer replaces
INSIDE = """(() => { const vw = document.documentElement.clientWidth, out = [];
  for (const n of document.querySelectorAll('#chat .md table, #chat .md table *, #chat img, #chat a.link-card, #chat .cl-mark, #chat .cl-turn')) {
    if (!n.getClientRects().length) continue;
    const r = n.getBoundingClientRect();
    if (r.width && (r.right > vw + 0.5 || r.left < -0.5)) out.push(n.tagName + ' ' + (n.textContent || '').trim().slice(0, 24) + ' ' + Math.round(r.right));
  }
  const clipped = [...document.querySelectorAll('#chat pre, #chat .md, #chat .bubble, #chat .md table, #chat .md :is(th, td)')]
    .filter((n) => n.clientWidth && n.scrollWidth > n.clientWidth + 1).map((n) => n.tagName + ' ' + n.scrollWidth + '>' + n.clientWidth);
  const tables = [...document.querySelectorAll('#chat .md table')].map((t) => ({ w: t.getBoundingClientRect().width, room: t.parentElement.clientWidth,
    stacked: t.classList.contains('cl-stacked') }));
  const images = [...document.querySelectorAll('#chat .msg img')];
  return { out: out.slice(0, 8), clipped: clipped.slice(0, 8), tables, images: images.length, loaded: images.every((i) => i.complete && i.naturalWidth > 0),
           pending: document.querySelectorAll('#chat > .msg.local').length, mark: !!document.querySelector('#chat > .cl-mark .cl-turn:not([hidden])') }; })()"""


def check_layer(browser, width: int) -> dict:
    browser.settle("document.querySelector('#chat')")
    m, inside = browser.evaluate(MEASURE), browser.evaluate(INSIDE)
    assert m["vw"] == width, m
    check(m, f"{width} px")
    assert inside["out"] == [] and inside["clipped"] == [], (width, inside)
    assert len(inside["tables"]) == 2 and all(t["w"] <= t["room"] + 0.5 for t in inside["tables"]), (width, inside)
    assert inside["images"] >= 1 and inside["loaded"], (width, inside)
    return inside


def hostile_ready(browser) -> None:
    assert wait_for(browser, "document.querySelectorAll('#chat > .msg').length >= 3 && !!document.querySelector('#chat .cl-turn:not([hidden])') && "
                             "!!document.querySelector('#chat .msg img') && "
                             "[...document.querySelectorAll('#chat .msg img')].every((i) => i.complete && i.naturalWidth > 0) && "
                             "document.querySelectorAll('#chat-strip-wait .wait-row').length === 2", 30.0), browser.evaluate(INSIDE)


def strip_doc() -> dict:
    return api_chat(name="A" * 40, busy=True, waiting=[{"id": f"item#{i}", "subject": "[demo] " + "a long subject " * 8 + WORD, "url": URL} for i in range(2)],
                    motion=[{"text": WORD, "at": int(time.time())}])


@pytest.mark.parametrize("served", [{"status": "busy"}], indirect=True)
@pytest.mark.parametrize("width", [1280, 390, 360, 320])
def test_no_sideways_scroll_with_long_words_tables_code_links_and_images(served, browser, monkeypatch, width):
    write(served, *hostile(served))
    open_chat(browser, served, monkeypatch, (width, 800 if width > 700 else 844), doc=strip_doc())
    if width < 700:
        browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 844, "deviceScaleFactor": 1, "mobile": True})
        assert wait_for(browser, f"document.documentElement.clientWidth === {width}", 10.0)
    hostile_ready(browser)
    send(browser, f"{WORD} {URL}")
    inside = check_layer(browser, width)
    assert inside["pending"] == 1 and inside["mark"], inside
    if width < 700:
        assert all(t["stacked"] for t in inside["tables"]), inside


@pytest.mark.parametrize("served", [{"status": "busy"}], indirect=True)
def test_a_changed_width_lays_the_tables_out_again(served, browser, monkeypatch):
    short = "| a | b |\n|---|---|\n| one | two |\n"
    lines = hostile(served)
    write(served, *lines, human("and a small table", 4), assistant(short, 4))
    open_chat(browser, served, monkeypatch, DESKTOP, doc=strip_doc())
    small = "(() => { const t = [...document.querySelectorAll('#chat .md table')].pop(); return [t.classList.contains('cl-stacked'), getComputedStyle(t.tHead).display]; })()"
    wide = ("(() => { const t = document.querySelector('#chat .md table'); const td = t.querySelector('td'); return [t.classList.contains('cl-stacked'), "
            "getComputedStyle(t.tHead).display, getComputedStyle(td).display, td.dataset.label || '']; })()")
    assert wait_for(browser, "document.querySelectorAll('#chat .md table').length === 3", 30.0)
    for width, mobile in ((1280, False), (320, True), (390, True), (360, True), (1280, False)):
        browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 844, "deviceScaleFactor": 1, "mobile": mobile})
        assert wait_for(browser, f"document.documentElement.clientWidth === {width}", 10.0)
        browser.settle("document.querySelector('#chat')")
        assert wait_for(browser, "[...document.querySelectorAll('#chat .md table')].every((t) => t.getBoundingClientRect().width <= t.parentElement.clientWidth + 0.5)", 10.0)
        m = browser.evaluate(MEASURE)
        check(m, f"{width} px after a change of width")
        assert browser.evaluate(INSIDE)["out"] == [], width
        assert browser.evaluate(small) == [False, "table-header-group"], width               # a table that fits stays a table
        if mobile:
            assert browser.evaluate(wide) == [True, "none", "block", "column-0-with-a-long-heading"], width


# ── every other page ─────────────────────────────────────────────────────────
# the thread, the title bar and the composer: the elements, their boxes and how they are painted
SNAPSHOT = """(() => { const props = ['display', 'position', 'fontSize', 'lineHeight', 'color', 'backgroundColor', 'paddingTop', 'paddingLeft', 'marginTop',
    'marginBottom', 'borderTopWidth', 'overflowX', 'overflowWrap', 'whiteSpace', 'maxWidth'];
  const boxes = (sel) => [...document.querySelectorAll(sel + ', ' + sel + ' *')].map((n) => { const cs = getComputedStyle(n), r = n.getBoundingClientRect();
    return [n.tagName, n.getAttribute('class') || '', ...[r.left, r.top, r.width, r.height].map((v) => Math.round(v)), ...props.map((p) => cs[p])].join('|'); });
  return { body: document.body.className, chat: document.querySelector('#chat').innerHTML, boxes: [...boxes('#chat-pane'), ...boxes('#top'), ...boxes('#composer')],
           width: [document.documentElement.scrollWidth, innerWidth] }; })()"""


def other_ready(browser) -> None:
    assert wait_for(browser, f"state.selected === '{OTHER}' && document.querySelector('#chat').textContent.includes('Noted for the record.') && "
                             "document.querySelectorAll('#chat .md table').length === 1", 30.0)
    browser.settle("document.querySelector('#chat')")


def other_lines() -> list[dict]:
    return mixed() + [human("a table please", 6), assistant(TABLE + f"\n{WORD}\n\n```\n{CODE}\n```\n", 6)]


def test_off_the_chat_session_and_another_one_are_drawn_by_the_session_view(served, browser, monkeypatch):
    write(served, *mixed())
    add_session(served, OTHER, "22222222-3333-4444-5555-666666666666", other_lines())
    for value in (None, "off"):
        open_chat(browser, served, monkeypatch, DESKTOP, layer=value)
        assert wait_for(browser, "document.querySelector('#chat').textContent.includes('Filed the finished job.') || !!document.querySelector('#chat > .msg.kept')", 20.0)
        assert browser.evaluate("document.querySelector('#chat').textContent.includes('Reading the build log first.')")
        assert browser.evaluate("document.querySelectorAll('#chat > .msg.kept').length") >= 1
        for hash_ in (None, f"#s={OTHER}"):
            if hash_:
                open_chat(browser, served, monkeypatch, DESKTOP, layer=value, hash_=hash_)
                other_ready(browser)
            assert browser.evaluate("typeof window.SalaThreadLayer") == "undefined"
            assert browser.evaluate("document.querySelectorAll('script[src*=chatlayer], link[href*=chatlayer]').length") == 0
            assert not browser.evaluate(LAYERED) and browser.evaluate(LAYER_NODES) == 0 and browser.evaluate("window.__reads") == []


@pytest.mark.parametrize("size", SIZES)
def test_on_another_sessions_page_is_the_page_it_is_with_the_setting_off(served, browser, monkeypatch, size):
    write(served, *mixed())
    add_session(served, OTHER, "22222222-3333-4444-5555-666666666666", other_lines())
    direct, after_chat = {}, {}
    for layer in ("off", "on"):
        open_chat(browser, served, monkeypatch, size, layer=layer, hash_=f"#s={OTHER}")
        other_ready(browser)
        direct[layer] = browser.evaluate(SNAPSHOT)
        assert browser.evaluate("window.__reads") == []
        # from the chat session to the other one, in the same page: nothing of the chat's page stays behind
        open_chat(browser, served, monkeypatch, size, layer=layer)
        assert wait_for(browser, f"{LAYERED} === {json.dumps(layer == 'on')} && document.querySelector('#chat').textContent.includes('The demo build passed.')", 20.0)
        browser.evaluate(f"go('#s={OTHER}'); ''")
        other_ready(browser)
        after_chat[layer] = browser.evaluate(SNAPSHOT)
        assert browser.evaluate("window.__reads.length = 0; loadSessions().then(() => window.__reads)") == []
        assert browser.evaluate(LAYER_NODES) == 0
    assert direct["on"] == direct["off"]
    assert after_chat["on"] == after_chat["off"]
    # and back: the chat session is the layer's again
    browser.evaluate(f"go('#s={NAME}'); ''")
    assert wait_for(browser, f"{LAYERED} && !!document.querySelector('#chat > .cl-older')", 20.0)
    thread_is(browser, SHOWN)
