"""The chat session's own layer (SALA_CHAT_LAYER, static/chatlayer.js) in a headless Chromium; test_chat_layer.py holds what needs no browser.

The rule: with the setting on, the chat session's thread holds the owner's messages and the replies to them and nothing else, NO SIDEWAYS SCROLL at any width,
and every other session's page is the page it is with the setting off.

Held here, against the real server:
  - only what GET api/chat/thread answers is drawn, on opening and as the transcript grows: no line between tool calls, no tool card, no subagent or task
    notice, no kept-back line;
  - a sent message shows at once and gives way to the transcript's copy, and an older message with the same words does not take its place;
  - the link cards are the ones the session view draws, and what a reply writes in HTML is cut down to the same markup as there;
  - the working mark: the open turn's words beside it only in the language of the owner's last message, else the bare mark;
  - older messages come as the reader scrolls up, and the place is kept;
  - a failed read, a reconnect, a long absence, a language change, a reload, a session asleep, not running or gone from the list;
  - while the thread loads (a cold load, a reload, a switch inside the page, the open session opened again), no frame has the strip's rows above it, a message
    still on its way or not; they are there once the thread is, or once its read failed;
  - the chat's address with the setting off and on, by test_chat_boot_ui.py's own frame recorder and checks (static/chatboot.js and the loading rule of
    style.css): a load and a reload show no other view, no frame has the rows without a message under them, on a load, a reload, a switch from another session
    and a sleeping chat session, and they stay away with a thread that never arrives;
  - the pinned bar of two tabs (test_chat_onit_ui.py holds the bar itself) has the same markup, boxes, paint and behavior with the setting on and off, stays and
    works while the thread loads, and brings no sideways scroll, closed or on either tab;
  - no sideways scroll at 1280, 390, 360 and 320 px with long words, long addresses, wide tables, wide code and images, and as the width changes;
  - the composer sends the same request with the setting on and off;
  - a running "!" command has the session view's live block with its Stop button, looking as with the setting off, with no sideways scroll at the four widths;
    it stays under the thread, and goes with the command's end, a reconnect or another session;
  - the images a reply sent (drawn as the session view draws them), the questions it asked with their numbered options, an API error and an interrupt are in the
    thread, with no sideways scroll at the four widths; the interrupt line takes no pending bubble and sets no language;
  - a "!" or slash command and its output are in the thread, the output taking the live block's place and the command's line its pending bubble's; a command's
    output leaves the open turn's words beside the working mark;
  - a sent file that is no image shows its name and caption with nothing to tap; a question says whether it takes several answers and, where the page never
    hears of a card, how to answer it until a message of the thread follows; the answers show on the owner's side and take no pending bubble; no sideways
    scroll at the four widths with any of these;
  - off, the chat session and another one are drawn by the session view; on, the other session's page is the same, opened directly or from the chat;
  - while the card of a waiting question (dialogcard.js) shows a question and can answer it, the thread draws no second copy and no line on how to answer;
    in a call of several questions the ones the card does not show stay; with no card, another dialog's card, previews or a card that cannot answer, the
    question stays as text and the line names the Terminal tab; the card stays last and answers with one tap; no sideways scroll at the four widths.

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

import test_chat_boot_ui as boot
from conftest import CHAT_READY, CWD, NAME, SID, transcript_file
from send_stub import OUTBOX
from test_bang_live import LIVE_EVENT
from test_bang_live import STATE as LIVE_BLOCK
from test_board_items_ui import wait_for
from test_chat_layer import OTHER, add_session
from test_chat_link_cards_ui import ART, mockup, reply_text
from test_chat_onit_ui import CHEVRON, MOVE_PANEL, MOVE_TAB, ONIT_PANEL, ONIT_TAB, PIN, WIDE, click, cp, key, promises, state, waiting
from test_chat_onit_ui import hostile as onit_hostile
from test_chat_session_view_ui import CODE, DESKTOP, MEASURE, PHONE, SIZES, TABLE, URL, WORD, api_chat, check, open_page
from test_chat_thread import ASK, OVERLOADED, answered, api_error, asked, banged, call, command_output, interrupt, local, task
from test_chatturns import assistant, human, peer, tool_result
from test_composer_attach import WAIT_CHIPS, pick
from test_question_card_ui import MEASURE as CARD_MEASURE, check as card_check, choice, serve_card
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
  """ + OUTBOX + """
  window.fetch = (url, opts) => {
    const u = String(url);
    if (u.startsWith('api/chat/thread')) {
      window.__reads.push(u);
      if (window.__fail) return Promise.resolve(new Response('{}', { status: 502 }));
    }
    const box = __outboxAnswer(u, opts);
    if (box) {
      if (opts && opts.method === 'POST') window.__sent.push({ url: u, method: opts.method, headers: opts.headers, body: JSON.parse(opts.body) });
      return box;
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
        browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": strip_only(doc)})
    open_page(browser, served, monkeypatch, size, hash_=hash_, ready=ready)


def strip_only(doc: dict) -> str:
    """The script that makes api/chat (the strip) answer `doc`; api/chat/thread stays the server's."""
    return """(() => { const real = window.fetch.bind(window);
      window.fetch = (u, o) => String(u) === 'api/chat'
        ? Promise.resolve(new Response(JSON.stringify(%s), { headers: { 'Content-Type': 'application/json' } })) : real(u, o); })()""" % json.dumps(doc)


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


def test_what_a_reply_writes_in_html_is_cut_down_as_in_the_session_view(served, browser, monkeypatch):
    written = ('Words first.\n\n<form action="/nowhere"><input name="who"><button>go</button></form>\n\n'
               '<img src="missing.png" onerror="window.__ran = 1">\n\n<a href="javascript:window.__ran = 1">tap</a>\n\n'
               '<script>window.__ran = 1</script>\n\nWords last.')
    write(served, human("show it", 1), assistant(written, 2))
    reply = "(() => { const m = document.querySelector('#chat .msg.assistant .md'); return m && m.textContent.includes('Words last.') ? m.innerHTML : null; })()"
    drawn = {}
    for layer in (None, "on"):
        open_chat(browser, served, monkeypatch, PHONE, layer=layer)
        assert wait_for(browser, f"{LAYERED} === {json.dumps(layer == 'on')} && !!{reply}", 20.0)
        drawn[layer] = browser.evaluate(reply)
        assert browser.evaluate("document.querySelectorAll('#chat .md :is(form, script, [onerror], a[href^=\"javascript\"])').length") == 0
        assert browser.evaluate("typeof window.__ran") == "undefined"
    assert drawn["on"] == drawn[None]


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
        assert sent["body"].pop("cid"), sent   # the page's own id for the message, new each time
        assert wait_for(browser, "state.pending.length === 1 && state.pending[0].status === 'waiting'", 10.0)
        bubble = browser.evaluate("(() => { const b = document.querySelector('#chat > .msg.local'); return [b.className, b.querySelector('.bubble').textContent, "
                                  "b.querySelector('.sf-name').textContent]; })()")
        got[layer] = (sent, bubble, browser.evaluate("[document.querySelectorAll('#chips .chip').length, getText()]"))
    assert got["on"] == got[None], got
    assert got["on"][0]["method"] == "POST" and got["on"][0]["url"] == f"api/outbox/{NAME}", got
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
    # a read that failed is not a thread still loading: the strip is there
    assert wait_for(browser, "document.querySelectorAll('#chat-strip-onit-panel .back-row').length >= 1 && "
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
    """A thread whose read is held: api/chat has answered and the strip under the pinned part is not on screen; then the thread arrives and the strip is there."""
    assert wait_for(browser, f"window.__held >= 1 && document.querySelectorAll('#chat-strip-onit-panel .back-row').length >= 1 && {ABOVE}[0]", 30.0)
    assert browser.evaluate(FRAMES)
    assert browser.evaluate(ABOVE) == [True, False]
    assert browser.evaluate("!document.querySelector('#chat-strip').hidden && document.querySelector('#chat-strip-wait').getClientRects().length > 0"), \
        "only what scrolls with the thread is held back: the pinned part stays"
    browser.evaluate("window.__hold = false; ''")
    thread_is(browser, SHOWN)
    assert browser.evaluate(FRAMES)
    assert browser.evaluate(ABOVE) == [False, True]
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
                             "document.querySelectorAll('#chat-strip-onit-panel .back-row').length >= 1", 30.0)
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
    assert wait_for(browser, f"window.__held >= 1 && document.querySelectorAll('#chat-strip-onit-panel .back-row').length >= 1 && {ABOVE}[0]", 30.0)
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


def test_a_session_opened_again_has_the_same_loading_state_with_the_setting_off_and_on(served, browser, monkeypatch):
    """The chat session's loading line has no row of the strip above it (off by style.css, on by the layer's sheet too); another session has no strip."""
    write(served, *mixed())
    add_session(served, OTHER, "22222222-3333-4444-5555-666666666666", other_lines())
    chat, other = {}, {}
    for layer in ("off", "on"):
        open_chat(browser, served, monkeypatch, PHONE, layer=layer, doc=strip_doc())
        assert wait_for(browser, "document.querySelectorAll('#chat-strip-onit-panel .back-row').length >= 1", 20.0)
        chat[layer] = browser.evaluate(f"selectSession('{NAME}', {{ force: true }}); {ABOVE}")
        browser.evaluate(f"go('#s={OTHER}'); ''")
        other_ready(browser)
        other[layer] = browser.evaluate(f"selectSession('{OTHER}', {{ force: true }}); {ABOVE}.concat(document.body.classList.contains('chat-layer'))")
    assert chat["on"] == chat["off"] == [True, False]
    assert other["on"] == other["off"] == [True, False, False]


# ── the first paint of the chat's address ────────────────────────────────────
# static/chatboot.js and style.css's loading rule are in the page with the setting off and on; the recorder, the delays and the checks are test_chat_boot_ui.py's
LAYERS = ["off", "on"]
ROWS_SHOWN = {"off": boot.ROWS, "on": boot.ROWS - 1}     # the layer's sheet hides the kept-back switch: its thread has no kept-back line, so nothing scrolls with it


def long_thread() -> list[dict]:
    """A thread many screens long, every turn the owner's own, each with its final reply."""
    return [line for i in range(1, 31) for line in (human(f"question {i}", i), assistant(f"answer {i}\n\nand more of it", i))]


def rows_only_over_messages(seen: list[dict]) -> None:
    assert not any(f["rows"] and not f["msgs"] for f in seen), [f for f in seen if f["rows"] and not f["msgs"]][:3]


@pytest.mark.parametrize("layer", LAYERS)
@pytest.mark.parametrize("size", SIZES)
def test_a_load_and_a_reload_of_the_chat_address_show_no_other_view_with_the_setting_off_and_on(served, browser, monkeypatch, size, layer):
    write(served, *long_thread())
    monkeypatch.setenv("SALA_CHAT_LAYER", layer)
    boot.prepare(browser, served, monkeypatch)
    boot.load(browser, served, monkeypatch, size, "#s=" + NAME)
    for again in (False, True):
        if again:
            browser.evaluate("window.__stale = true; ''")
            browser.send("Page.reload")
        boot.until(browser, "!window.__stale && " + boot.CHAT_DRAWN)
        seen = boot.frames(browser)
        boot.check_chat_load(seen, "en")        # nothing of another view, the loading line, then the chat under its label
        rows_only_over_messages(seen)
        assert browser.evaluate(LAYERED) is (layer == "on")


@pytest.mark.parametrize("layer", LAYERS)
@pytest.mark.parametrize("size", SIZES)
def test_the_rows_wait_for_the_thread_on_the_chat_address_with_the_setting_off_and_on(served, browser, monkeypatch, size, layer):
    """api/chat answers at once and the thread comes late, so the strip is on all the while the loading line stands."""
    write(served, *long_thread())
    boot.second_session(served)
    monkeypatch.setenv("SALA_CHAT_LAYER", layer)
    boot.prepare(browser, served, monkeypatch, reads=boot.QUICK, stream_ms=boot.LATE_STREAM_MS, extra=[strip_only(api_chat(name=boot.LABEL))])
    boot.load(browser, served, monkeypatch, size, "#s=" + NAME)
    for step in ("a load", "a reload", "from another session"):
        if step == "a reload":
            browser.evaluate("window.__stale = true; ''")
            browser.send("Page.reload")
        elif step == "from another session":
            browser.evaluate("location.hash = 's=demo-other'; ''")
            boot.until(browser, f"{boot.NAME_EL}.textContent === 'demo-other' && document.querySelector('#chat').textContent.includes('{boot.OTHER_SAYS}')")
            browser.evaluate("window.__frames.length = 0; document.querySelector('#side-chat').click(); ''")
        boot.until(browser, "!window.__stale && " + boot.CHAT_DRAWN)
        seen = boot.frames(browser)
        boot.check_rows(seen)       # no frame has the loading line and the rows together; the strip was on and the pinned line drawn while it stood
        rows_only_over_messages(seen)
        assert seen[-1]["rows"] == ROWS_SHOWN[layer] and seen[-1]["msgs"] >= 1, (step, seen[-1])
        assert browser.evaluate(LAYERED) is (layer == "on"), step
        boot.check_rows_above_a_long_thread(browser, ROWS_SHOWN[layer])


@pytest.mark.parametrize("layer", LAYERS)
def test_a_thread_that_never_arrives_keeps_the_rows_away_with_the_setting_off_and_on(served, browser, monkeypatch, layer):
    monkeypatch.setenv("SALA_CHAT_LAYER", layer)
    boot.prepare(browser, served, monkeypatch, reads=boot.QUICK, stream_ms=600_000, extra=[strip_only(api_chat(name=boot.LABEL))])
    boot.load(browser, served, monkeypatch, PHONE, "#s=" + NAME)
    boot.until(browser, f"location.protocol === 'http:' && !!{boot.NAME_EL} && {boot.NAME_EL}.textContent === '{boot.LABEL}' && {boot.LET_GO} && "
                        "!document.querySelector('#chat-strip').hidden && !document.querySelector('#chat-strip-wait').hidden")
    time.sleep(1.0)
    seen = boot.frames(browser)
    boot.check_rows(seen)
    last = seen[-1]
    assert (last["loading"], last["on"], last["rows"], last["bar"]) == (True, True, 0, True), last


@pytest.mark.parametrize("layer", LAYERS)
def test_a_sleeping_chat_session_has_its_rows_with_the_setting_off_and_on(wake, served, browser, monkeypatch, layer):  # noqa: F811
    """The layer takes no sleeping session, so the rows come with the sleeper's thread as without it."""
    wake.sleeper(name="demo-asleep", cwd=CWD)
    transcript_file(served).with_name(boot.SLEEP_UUID + ".jsonl").write_text(boot.long_thread())
    monkeypatch.setenv("SALA_CHAT_LAYER", layer)
    boot.prepare(browser, served, monkeypatch, reads=boot.QUICK, stream_ms=boot.LATE_STREAM_MS,
                 extra=[strip_only(api_chat(session="demo-asleep", name=boot.LABEL))])
    boot.load(browser, served, monkeypatch, PHONE, "#s=demo-asleep", chat="demo-asleep")
    boot.until(browser, "location.protocol === 'http:' && !!document.querySelector('#chat > .msg') && !document.querySelector('#chat-strip').hidden && "
                        "!document.querySelector('#chat-strip-wait').hidden")
    seen = boot.frames(browser)
    boot.check_rows(seen)
    rows_only_over_messages(seen)
    assert seen[-1]["rows"] == boot.ROWS, seen[-1]
    assert not browser.evaluate(LAYERED)
    boot.check_rows_above_a_long_thread(browser)


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
                             "document.querySelectorAll('#chat-strip-wait-panel .wait-row').length === 2", 30.0), browser.evaluate(INSIDE)


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


# ── the pinned bar of two tabs ───────────────────────────────────────────────
# The box pinned over the thread (the bar, its two tabs, the chevron, the open list): its markup, and every element's box and paint, the dots before them too
PINNED = """(() => { const props = ['display', 'position', 'fontSize', 'fontWeight', 'lineHeight', 'color', 'backgroundColor', 'backgroundImage', 'paddingTop',
    'paddingLeft', 'marginTop', 'borderBottomWidth', 'borderBottomColor', 'outlineStyle', 'overflowX', 'overflowY', 'overflowWrap', 'maxHeight', 'zIndex'];
  const p = document.querySelector('#chat-strip-wait');
  return { html: p.outerHTML, boxes: [p, ...p.querySelectorAll('*')].map((n) => { const cs = getComputedStyle(n), r = n.getBoundingClientRect(), dot = getComputedStyle(n, '::before');
    return [n.tagName, n.getAttribute('class') || '', ...[r.left, r.top, r.width, r.height].map((v) => Math.round(v)), ...props.map((v) => cs[v]), dot.content,
            dot.backgroundColor].join('|'); }) }; })()"""


def bar_walk(browser) -> list:
    """The pinned box through its states, each noted: closed, each tab open, the chevron closing the list and opening it again, the open one's tab closing it, and
    the keyboard moving to the other tab and opening it."""
    seen = []

    def note(step: str) -> None:
        # the chevron turns over .12s (style.css .chev) while the box stands still, so settle alone would let a walk be measured mid-turn
        assert wait_for(browser, f"{PIN}.getAnimations({{ subtree: true }}).length === 0", 10.0), (step, state(browser))
        browser.settle(PIN)
        seen.append((step, state(browser), browser.evaluate(PINNED)))

    note("closed")
    for step, node in (("On it", ONIT_TAB), ("Your move", MOVE_TAB), ("the chevron closes", CHEVRON), ("the chevron opens", CHEVRON), ("its tab closes", MOVE_TAB)):
        click(browser, node)
        note(step)
    browser.evaluate(MOVE_TAB + ".focus(); ''")
    key(browser, "ArrowRight", "ArrowRight", 39)
    key(browser, "Enter", "Enter", 13, "\r")
    assert wait_for(browser, f"{ONIT_TAB}.getAttribute('aria-selected') === 'true'", 5.0), state(browser)
    note("the keyboard")
    return seen


@pytest.mark.parametrize("size", SIZES)
def test_the_pinned_bar_and_both_tabs_look_and_work_the_same_with_the_setting_on_and_off(served, browser, monkeypatch, size):
    # long enough for the pane to scroll in both views, so that a scroll bar takes the same room in each
    write(served, *long_thread())
    doc = api_chat(waiting=waiting(), motion=promises())
    walks = {}
    for layer in ("off", "on"):
        open_chat(browser, served, monkeypatch, size, layer=layer, doc=doc)
        assert wait_for(browser, f"{LAYERED} === {json.dumps(layer == 'on')} && !{PIN}.hidden && document.querySelectorAll('#chat > .msg').length >= 30", 30.0)
        walks[layer] = bar_walk(browser)
    assert [s["open"] for _, s, _ in walks["on"]] == [[], [ONIT_PANEL], [MOVE_PANEL], [], [MOVE_PANEL], [], [ONIT_PANEL]], walks["on"]
    assert all(s["pin"] and s["bar"] and [r["rows"] for r in s["panels"]] == [2, 4] for _, s, _ in walks["on"]), walks["on"]
    for off, on in zip(walks["off"], walks["on"], strict=True):
        assert on == off, off[0]


@pytest.mark.parametrize("size", SIZES)
def test_the_pinned_bar_stays_and_works_while_the_thread_loads(served, browser, monkeypatch, size):
    write(served, *mixed())
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": HOLD})
    open_chat(browser, served, monkeypatch, size, ready=False, doc=api_chat(waiting=waiting(), motion=promises()))
    assert wait_for(browser, f"window.__held >= 1 && document.querySelectorAll('#chat-strip-onit-panel .back-row').length >= 1 && !{PIN}.hidden && {ABOVE}[0]", 30.0)
    assert browser.evaluate(FRAMES)
    s = state(browser)
    assert s["pin"] and s["bar"] and s["open"] == [] and browser.evaluate(ABOVE) == [True, False], s
    for node, panel, rows in ((ONIT_TAB, ONIT_PANEL, 4), (MOVE_TAB, MOVE_PANEL, 2)):
        click(browser, node)
        s = state(browser)
        assert s["open"] == [panel] and [p["rows"] for p in s["panels"] if p["id"] == panel] == [rows], s
    assert browser.evaluate(ABOVE) == [True, False]
    browser.evaluate("window.__hold = false; ''")
    thread_is(browser, SHOWN)
    assert browser.evaluate(FRAMES)
    s = state(browser)
    assert s["bar"] and s["open"] == [MOVE_PANEL] and browser.evaluate(ABOVE) == [False, True], s    # the list opened while loading is still open
    assert browser.evaluate("window.__above") == []


@pytest.mark.parametrize("served", [{"status": "busy"}], indirect=True)
@pytest.mark.parametrize("width", [1280, 390, 360, 320])
def test_no_sideways_scroll_with_the_pinned_bar_closed_and_on_each_tab(served, browser, monkeypatch, width):
    write(served, *hostile(served))
    doc = api_chat(name="A" * 40, busy=True, group={"en": "G" * 40, "ko": cp(0xACB0) * 40}, waiting=waiting(12, long=True), motion=onit_hostile(12))
    open_chat(browser, served, monkeypatch, (width, 800 if width > 700 else 844), doc=doc)
    if width < 700:
        browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 844, "deviceScaleFactor": 1, "mobile": True})
        assert wait_for(browser, f"document.documentElement.clientWidth === {width}", 10.0)
    assert wait_for(browser, "document.querySelectorAll('#chat > .msg').length >= 3 && !!document.querySelector('#chat .cl-turn:not([hidden])') && "
                             "!!document.querySelector('#chat .msg img') && "
                             "[...document.querySelectorAll('#chat .msg img')].every((i) => i.complete && i.naturalWidth > 0) && "
                             "document.querySelectorAll('#chat-strip-wait .wait-row').length === 24", 30.0), browser.evaluate(INSIDE)
    for which, node, panels in (("closed", None, []), ("Your move", MOVE_TAB, [MOVE_PANEL]), ("On it", ONIT_TAB, [ONIT_PANEL])):
        if node:
            click(browser, node)
        browser.settle(PIN)
        got, where = browser.evaluate(WIDE), f"{width} px, {which}"
        assert got["vw"] == width and got["parts"] == (4 if which == "On it" else 3) and got["open"] == panels, (where, got)    # the (?) help button joins the tabs and the chevron on On it only
        assert got["doc"][0] <= got["doc"][1] and got["body"][0] <= got["body"][1] and got["pane"][0] <= got["pane"][1], (where, got)
        assert got["over"] == [] and got["wide"] == [] and got["outRow"] == [] and not got["overlap"], (where, got)
        check_layer(browser, width)


# ── a running "!" command ────────────────────────────────────────────────────
# The block is the session view's own (app.js applyLive and stopLive). A `live` event is given to the open stream's own listener, as test_bang_live.py gives it.
LIVE_TEXT = f"{WORD}\n{URL}\n{CODE}\n\t\t{'-' * 400}\n{'=' * 90}  {'word ' * 80}\n" + "\n".join(f"step {i}" for i in range(60))
LIVE_RUNNING = {"running": True, "command": f"demo {WORD} {URL}", "uuid": "b-1", "text": LIVE_TEXT}
WAITING = {"running": True, "command": "sleep 20", "uuid": "b-1", "text": "code: ABCD-1234"}
LONG_ERROR = "tmux failed: /srv/demo/work/" + "socket" * 60
# the block as it looks: its markup, and each part's place across, size and paint
LIVE_LOOK = """(() => { const props = ['display', 'fontFamily', 'fontSize', 'lineHeight', 'color', 'backgroundColor', 'paddingTop', 'paddingLeft', 'marginTop',
    'marginBottom', 'borderTopWidth', 'borderTopLeftRadius', 'whiteSpace', 'maxHeight', 'overflowX', 'overflowY'];
  const b = document.querySelector('#live-bang');
  return { html: b.outerHTML, boxes: [b, ...b.querySelectorAll('*')].map((n) => { const cs = getComputedStyle(n), r = n.getBoundingClientRect();
    return [n.className, Math.round(r.left), Math.round(r.width), Math.round(r.height), ...props.map((p) => cs[p])].join('|'); }) }; })()"""
# a part of the block that ends outside the window, or holds more across than its box (cut off, or scrolling sideways)
LIVE_WIDE = """(() => { const vw = document.documentElement.clientWidth, b = document.querySelector('#live-bang');
  const all = [b, ...b.querySelectorAll('*')].filter((n) => n.getClientRects().length);
  return { parts: all.length, out: all.filter((n) => { const r = n.getBoundingClientRect(); return r.right > vw + 0.5 || r.left < -0.5; }).map((n) => n.className),
           wide: all.filter((n) => n.clientWidth && n.scrollWidth > n.clientWidth + 1).map((n) => n.className + ' ' + n.scrollWidth + '>' + n.clientWidth) }; })()"""
# one block, and nothing that is shown stands under it
LIVE_LAST = """(() => { const shown = [...document.querySelector('#chat').children].filter((n) => n.getClientRects().length);
  return document.querySelectorAll('#live-bang').length === 1 && shown.pop() === document.querySelector('#live-bang'); })()"""
# Stop is on screen and nothing covers it
STOP_REACHED = """(() => { const b = document.querySelector('#live-bang .live-stop'), r = b.getBoundingClientRect();
  return document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2) === b; })()"""
# Stop's request is noted, and refused with a long word in the reason
STOP_SPY = """(() => { const real = window.fetch; window.__stops = [];
  window.fetch = (u, o) => { if (!String(u).endsWith('/stop')) return real(u, o); window.__stops.push([String(u), o.method, o.body]);
    return Promise.resolve(new Response(JSON.stringify({ ok: false, error: %s }), { status: 502 })); }; return true; })()"""


def live(browser, event: dict) -> None:
    browser.evaluate(LIVE_EVENT % json.dumps(event))


@pytest.mark.parametrize("width", [1280, 390, 360, 320])
def test_a_running_command_has_the_session_views_live_block_and_stop_and_no_sideways_scroll(served, browser, monkeypatch, width):
    write(served, *long_thread())   # long enough for the pane to scroll in both views, so that a scroll bar takes the same room in each
    looks = {}
    for layer in ("off", "on"):
        open_chat(browser, served, monkeypatch, (width, 800 if width > 700 else 844), layer=layer)
        if width < 700:
            browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 844, "deviceScaleFactor": 1, "mobile": True})
            assert wait_for(browser, f"document.documentElement.clientWidth === {width}", 10.0)
        assert wait_for(browser, f"{LAYERED} === {json.dumps(layer == 'on')} && document.querySelectorAll('#chat > .msg').length >= 30", 30.0)
        assert browser.evaluate(LIVE_BLOCK) is None
        live(browser, LIVE_RUNNING)
        got = browser.evaluate(LIVE_BLOCK)
        assert got == {"out": LIVE_TEXT, "stop": "Stop", "last": True, "label": "Running in the terminal", "note": "", "n": 1}, (layer, got)
        browser.settle("document.querySelector('#live-bang')")
        looks[layer] = browser.evaluate(LIVE_LOOK)
    assert looks["on"] == looks["off"]
    assert browser.evaluate(STOP_REACHED), "a command that starts leaves the reader at the end, with Stop in view"
    browser.evaluate(STOP_SPY % json.dumps(LONG_ERROR))
    browser.evaluate("document.querySelector('#live-bang .live-stop').click(); ''")
    assert wait_for(browser, f"document.querySelector('#live-bang .live-note').textContent === {json.dumps(LONG_ERROR)}", 10.0), browser.evaluate(LIVE_BLOCK)
    assert browser.evaluate("window.__stops") == [[f"api/s/{os.getpid()}/stop", "POST", "{}"]]
    browser.settle("document.querySelector('#chat')")
    m, block = browser.evaluate(MEASURE), browser.evaluate(LIVE_WIDE)
    assert m["vw"] == width, m
    check(m, f"{width} px with a running command")
    assert block["parts"] == 6 and block["out"] == [] and block["wide"] == [], (width, block)


def test_the_live_block_stays_under_the_growing_thread_and_goes_with_its_end_a_reconnect_or_another_session(served, browser, monkeypatch):
    write(served, human("go on", 1), assistant("Done.", 2))
    add_session(served, OTHER, "22222222-3333-4444-5555-666666666666", other_lines())
    open_chat(browser, served, monkeypatch)
    rows = [["me", "go on"], ["reply", "Done."]]
    thread_is(browser, rows)
    live(browser, WAITING)
    assert browser.evaluate(LIVE_LAST)
    browser.evaluate("window.__block = document.querySelector('#live-bang'); ''")
    # a message sent, a transcript that grows, a session at work: what the layer draws goes above the block, which is never made again
    send(browser, "and now?")
    session_status(served, "busy")
    append(served, human("typed in the pane", 3), assistant("Noted.", 4), human("one more", 5))
    thread_is(browser, rows + [["me", "typed in the pane"], ["reply", "Noted."], ["me", "one more"], ["me", "and now?"]])
    assert wait_for(browser, f"!!document.querySelector('#chat > .cl-mark') && {LIVE_LAST}", 20.0), browser.evaluate(LIVE_BLOCK)
    live(browser, {**WAITING, "text": "code: ABCD-1234\nwaiting"})
    got = browser.evaluate(LIVE_BLOCK)
    assert got["out"] == "code: ABCD-1234\nwaiting" and got["n"] == 1, got
    assert browser.evaluate("window.__block === document.querySelector('#live-bang')")
    live(browser, {"running": False})
    assert browser.evaluate(LIVE_BLOCK) is None
    # a reconnect takes the block with its reset, as in the session view (the stream sends it again while the command runs), and keeps the thread
    live(browser, WAITING)
    browser.evaluate("window.__s = state.current; state.es.close(); openStream(window.__s, { resume: true }); ''")
    assert wait_for(browser, "!document.querySelector('#live-bang')", 20.0)
    assert browser.evaluate("document.querySelectorAll('#chat > .msg:not(.local)').length") == 5
    live(browser, WAITING)
    assert wait_for(browser, LIVE_LAST, 10.0), browser.evaluate(LIVE_BLOCK)
    browser.evaluate(f"go('#s={OTHER}'); ''")
    other_ready(browser)
    assert browser.evaluate(LIVE_BLOCK) is None


def test_a_command_running_while_the_thread_loads_ends_up_under_the_thread_with_stop_in_view(served, browser, monkeypatch):
    write(served, *long_thread())
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": HOLD})
    open_chat(browser, served, monkeypatch, ready=False)
    assert wait_for(browser, "window.__held >= 1 && !!document.querySelector('#chat > .empty')", 30.0)
    live(browser, WAITING)
    assert browser.evaluate(LIVE_LAST)
    browser.evaluate("window.__hold = false; ''")
    assert wait_for(browser, f"document.querySelectorAll('#chat > .msg').length >= 30 && {LIVE_LAST} && {STOP_REACHED}", 30.0), browser.evaluate(LIVE_BLOCK)


# each message of the transcript: whose it is and the words of its command line, its command's output or its text
COMMANDS = """[...document.querySelectorAll('#chat > .msg:not(.local)')].map((m) => [m.classList.contains('user') ? 'me' : 'reply',
  [...m.querySelectorAll(':scope > .cmd, :scope > .bang-out pre, :scope > details.notice pre, :scope > .bubble, :scope > .md')]
    .map((n) => n.textContent.trim()).join(' / ')])"""


@pytest.mark.parametrize("size", SIZES)
def test_a_commands_line_and_output_are_in_the_layers_thread_and_the_output_takes_the_live_blocks_place(served, browser, monkeypatch, size):
    write(served, human("go on", 1), assistant("Done.", 2))
    open_chat(browser, served, monkeypatch, size)
    thread_is(browser, [["me", "go on"], ["reply", "Done."]])
    send(browser, "! ls demo")
    assert browser.evaluate(PENDING) == ["! ls demo"]
    live(browser, {"running": True, "command": "ls demo", "uuid": "b-1", "text": "a.txt"})
    assert browser.evaluate("!!document.querySelector('#live-bang')")
    # the records alone end the block: no event of the stream says the command is over here
    command, output = banged("ls demo", 3, "a.txt")
    command["timestamp"] = now()   # a bubble is taken only by a line recorded around its send
    append(served, command, output, assistant("One file.", 4))
    want = [["me", "go on"], ["reply", "Done."], ["me", "! ls demo"], ["me", "a.txt"], ["reply", "One file."]]
    assert wait_for(browser, f"{COMMANDS}.length === {len(want)} && !document.querySelector('#live-bang')", 20.0), browser.evaluate(COMMANDS)
    assert browser.evaluate(COMMANDS) == want
    assert browser.evaluate(PENDING) == [] and browser.evaluate("state.pending.length") == 0, "the command's line takes its bubble's place"
    # a slash command that ran locally
    append(served, *local("/model", 5))
    want += [["me", "/model"], ["me", "done"]]
    assert wait_for(browser, f"{COMMANDS}.length === {len(want)}", 20.0), browser.evaluate(COMMANDS)
    assert browser.evaluate(COMMANDS) == want


@pytest.mark.parametrize("served", [{"status": "busy"}], indirect=True)
def test_a_commands_output_leaves_the_open_turns_words_beside_the_mark(served, browser, monkeypatch):
    write(served, human(KO_OWNER, 1), assistant(KO_TURN, 2, stop="tool_use", tool=True), tool_result(2))
    open_chat(browser, served, monkeypatch)
    assert wait_for(browser, f"(({MARK}) || {{}}).turn === {json.dumps(KO_TURN)}", 20.0), browser.evaluate(MARK)
    # the stream's append hands the line over as the transcript's page would
    output = {"uuid": "o-1", "role": "user", "blocks": [{"kind": "bang_output", "label": "command output", "text": "plain output", "truncated": False}]}
    handed = f"SalaThreadLayer.append(state.byName.get(state.selected), {{ messages: [{json.dumps(output)}] }}); ({MARK}).turn"
    assert browser.evaluate(handed) == KO_TURN


HOW = "[...document.querySelectorAll('#chat .cl-ask-how')].map((n) => [n.textContent, n.getClientRects().length > 0])"
HOW_ONE = "To answer, send an option's number here or use the Terminal tab. To answer in your own words, send esc first, then your message."
HOW_MANY = "To answer, use the Terminal tab. To answer in your own words, send esc first, then your message."
HOW_TERM = "To answer, use the Terminal tab."


def no_card_route(browser) -> None:
    """api/s/<pid>/dialog answers 404, as a server without the route does: the page never hears what the pane shows."""
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": r"""(() => { const real = window.fetch.bind(window);
  window.fetch = (url, opts) => (/^api\/s\/\d+\/dialog$/.test(String(url)) ? Promise.resolve(new Response("", { status: 404 })) : real(url, opts)); })()"""})
SENT_FILE = """[...document.querySelectorAll('#chat > .msg.assistant > .cl-file')].map((f) => [f.querySelector('.sf-name').textContent,
  f.querySelector('.cl-file-cap').textContent, f.querySelectorAll('a, button').length, !!f.querySelector('svg')])"""
ANSWERS = "[...document.querySelectorAll('#chat > .msg.user > .cl-answer .cl-answer-one')].map((n) => [...n.children].map((c) => c.textContent))"


@pytest.mark.parametrize("served", [{"status": "waiting"}], indirect=True)
@pytest.mark.parametrize("size", SIZES)
def test_a_sent_file_a_question_and_its_answer_show_and_how_to_answer_stands_until_the_thread_moves_on(served, browser, monkeypatch, size):
    report = call("SendUserFile", {"files": ["/w/demo/report.docx"], "caption": "The figures", "status": "normal"}, 1)
    write(served, human("send it", 1), report, tool_result(1), assistant("Sent.", 2), human("pick one", 3), asked(4))
    no_card_route(browser)
    open_chat(browser, served, monkeypatch, size)
    assert wait_for(browser, f"{LAYERED} && {HOW}.length === 1", 20.0), browser.evaluate(THREAD)
    assert browser.evaluate(SENT_FILE) == [["report.docx", "The figures", 0, True]]
    notes = "[...document.querySelectorAll('#chat .cl-ask')].map((q) => (q.querySelector('.cl-ask-multi') || {}).textContent || '')"
    assert browser.evaluate(notes) == ["", "You can pick more than one."]
    assert browser.evaluate(HOW) == [[HOW_MANY, True]]
    # a message on its way leaves the words on screen
    send(browser, "esc")
    assert browser.evaluate(PENDING) == ["esc"]
    assert browser.evaluate(HOW) == [[HOW_MANY, True]]
    append(served, answered({"Which colour?": "Blue", "Which size?": ["Small"]}, 5))
    assert wait_for(browser, f"{ANSWERS}.length === 2", 20.0), browser.evaluate(THREAD)
    assert browser.evaluate(ANSWERS) == [["Which colour?", "Blue"], ["Which size?", "Small"]]
    assert browser.evaluate(HOW) == [[HOW_MANY, False]]
    assert browser.evaluate(PENDING) == ["esc"], "the answer's line is no copy of a message on its way"
    append(served, assistant("Blue it is.", 6), human("and again", 7), asked(8, [one_question("Colour", "Which colour?", ("Red", "warm"), ("Blue", "cool"))]))
    assert wait_for(browser, f"{HOW}.length === 2", 20.0), browser.evaluate(THREAD)
    assert browser.evaluate(HOW) == [[HOW_MANY, False], [HOW_ONE, True]]
    # a question with previews: a number sent from here would only move the dialog's focus, so the line does not offer one
    append(served, human("once more", 9), asked(10, ASK[:1]))
    assert wait_for(browser, f"{HOW}.length === 3", 20.0), browser.evaluate(THREAD)
    assert browser.evaluate(HOW)[-1] == [HOW_MANY, True]
    assert browser.evaluate("document.querySelectorAll('#chat > .q-card').length") == 0


# a box of a message that ends outside the window or holds more across than itself
MESSAGES_WIDE = """(() => { const vw = document.documentElement.clientWidth, out = [], wide = [];
  for (const n of document.querySelectorAll('#chat > .msg, #chat > .msg *')) {
    if (!n.getClientRects().length || n.closest('svg')) continue;
    const r = n.getBoundingClientRect();
    if (r.width && (r.right > vw + 0.5 || r.left < -0.5)) out.push(n.tagName + '.' + n.className + ' ' + Math.round(r.left) + '-' + Math.round(r.right));
    if (n.clientWidth && n.scrollWidth > n.clientWidth + 1) wide.push(n.tagName + '.' + n.className + ' ' + n.scrollWidth + '>' + n.clientWidth);
  }
  const count = (s) => document.querySelectorAll('#chat ' + s).length;
  return { out: out.slice(0, 8), wide: wide.slice(0, 8), drawn: ['.cl-file', '.cl-answer', '.cmd', '.bang-out', 'details.notice', '.cl-ask', '.cl-ask-how'].map(count) }; })()"""


@pytest.mark.parametrize("served", [{"status": "waiting"}], indirect=True)
@pytest.mark.parametrize("width", [1280, 390, 360, 320])
def test_no_sideways_scroll_with_commands_their_output_sent_files_and_answers(served, browser, monkeypatch, width):
    asking = f"{WORD} {URL}"
    questions = [{"header": WORD, "question": asking, "multiSelect": True, "options": [{"label": WORD, "description": CODE}]}]
    files = call("SendUserFile", {"files": ["/w/demo/" + "f" * 200 + ".docx"], "caption": f"{URL} {WORD}", "status": "normal"}, 1)
    write(served, human("send it", 1), files, tool_result(1), asked(2, questions), answered({asking: f"{CODE} {WORD} {URL}"}, 3, questions),
          assistant("Taken.", 4), *banged(f"demo {WORD} {URL}", 5, LIVE_TEXT),
          *local(f"/{WORD}", 6, output=lambda _, minute: command_output(LIVE_TEXT, minute)), human("again", 7), asked(8, questions))
    open_chat(browser, served, monkeypatch, (width, 800 if width > 700 else 844), doc=strip_doc())
    if width < 700:
        browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 844, "deviceScaleFactor": 1, "mobile": True})
        assert wait_for(browser, f"document.documentElement.clientWidth === {width}", 10.0)
    ready = f"{LAYERED} && document.querySelectorAll('#chat .cl-ask').length === 2 && document.querySelectorAll('#chat-strip-wait-panel .wait-row').length === 2"
    assert wait_for(browser, ready, 30.0), browser.evaluate(MESSAGES_WIDE)
    browser.evaluate("document.querySelectorAll('#chat details').forEach((d) => { d.open = true; }); ''")   # what a fold holds, too
    browser.settle("document.querySelector('#chat')")
    m, got = browser.evaluate(MEASURE), browser.evaluate(MESSAGES_WIDE)
    assert m["vw"] == width, m
    check(m, f"{width} px with commands, files and answers")
    assert got == {"out": [], "wide": [], "drawn": [1, 1, 2, 1, 1, 2, 2]}, (width, got)


# the questions of the thread (their words, and whether each is on screen), the how-to lines on screen, the card's title, whether the card is the last
# thing in #chat, and how many of the thread's messages take room
ASKS = """(() => { const on = (n) => n.getClientRects().length > 0, chat = document.querySelector('#chat'), card = chat.querySelector(':scope > .q-card');
  return { asks: [...chat.querySelectorAll('.cl-ask')].map((q) => [q.querySelector('.cl-ask-q').textContent, on(q)]),
    how: [...chat.querySelectorAll('.cl-ask-how')].filter(on).map((n) => n.textContent),
    card: [...chat.querySelectorAll(':scope > .q-card .q-title')].map((n) => n.textContent),
    last: !!card && chat.lastElementChild === card, messages: [...chat.querySelectorAll(':scope > .msg')].filter(on).length }; })()"""
OWN_ROWS = (("Type something.", ""), ("Chat about this", ""))     # the rows Claude Code adds under the options of a question of one answer


def one_question(header: str, asking: str, *options: tuple, multi: bool = False) -> dict:
    """A question of an AskUserQuestion call, as the transcript records it."""
    return {"header": header, "question": asking, "multiSelect": multi,
            "options": [{"label": label, "description": desc} for label, desc in options]}


def pane_card(title: str, *options: tuple, multi: bool = False) -> dict:
    """The card the server reads from a pane that shows these words over these options (tmuxio.card)."""
    rows = [{"n": n, "label": label, "description": desc, "checked": False} for n, (label, desc) in enumerate(options, 1)]
    return {"kind": "multi" if multi else "choice", "title": title, "focus": None, "options": rows,
            "text": title + "\n" + "\n".join(f"{o['n']}. {o['label']}" for o in rows)}


def open_at(browser, served, monkeypatch, width: int) -> None:
    open_chat(browser, served, monkeypatch, (width, 800 if width > 700 else 844))
    if width < 700:
        browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 844, "deviceScaleFactor": 1, "mobile": True})
        assert wait_for(browser, f"document.documentElement.clientWidth === {width}", 10.0)


def change_card(browser, card: dict | None) -> None:
    """What the stubbed route answers from now on (serve_card), read at once."""
    browser.evaluate(f"window.__card = {json.dumps(card)}; SalaQuestionCard.poll(); ''")


def shows(browser, want: dict) -> None:
    assert wait_for(browser, f"{LAYERED} && JSON.stringify({ASKS}) === JSON.stringify({json.dumps(want)})", 30.0), (want, browser.evaluate(ASKS))
    browser.settle("document.querySelector('#chat')")
    assert browser.evaluate(ASKS) == want


@pytest.mark.parametrize("served", [{"status": "waiting"}], indirect=True)
@pytest.mark.parametrize("width", [1280, 390, 360, 320])
def test_a_waiting_question_shows_as_the_card_alone_and_as_text_where_no_card_answers_it(served, browser, monkeypatch, width):
    asking = f"Which one for {WORD}?"
    options = [("Red " + WORD, "It is described at length. " + URL), ("Blue", "cool")]
    questions = [one_question("Pick", asking, *options)]
    title = "☐ Pick\n" + asking
    card = pane_card(title, *options, *OWN_ROWS)
    write(served, human(EN, 1), asked(2, questions))
    serve_card(browser, card)
    open_at(browser, served, monkeypatch, width)
    # the card alone: no second copy of the question, no line on how to answer, and no empty message in its place
    alone = {"asks": [[asking, False]], "how": [], "card": [title], "last": True, "messages": 1}
    shows(browser, alone)
    m = browser.evaluate(CARD_MEASURE)
    assert m["vw"] == width and (m["buttons"], m["boxes"]) == (4, 0), m
    card_check(m, f"{width} px, the card under the layer's thread")
    browser.evaluate("document.querySelectorAll('#chat > .q-card button.q-opt')[1].click(); ''")
    assert wait_for(browser, "window.__posts.length === 1", 10.0)
    assert browser.evaluate("window.__posts[0]") == {"expect": card["text"], "key": "2"}
    # the server reads no card on the pane: the thread's text is back, and the Terminal tab is the way to answer
    text_only = {"asks": [[asking, True]], "how": [HOW_TERM], "card": [], "last": False, "messages": 2}
    shows(browser, text_only)
    rest = browser.evaluate(MESSAGES_WIDE)
    m = browser.evaluate(MEASURE)
    check(m, f"{width} px, the question as text")
    assert rest["out"] == [] and rest["wide"] == [], (width, rest)
    # another dialog's card is not this question's: the text stays above it
    change_card(browser, choice(3))
    shows(browser, {**text_only, "card": ["Which one should it be?"], "last": True})
    change_card(browser, card)
    shows(browser, alone)
    # answered: the question is the thread's record again, under it the answer as before; the card stays last while the wait lasts
    append(served, answered({asking: "Blue"}, 3, questions))
    shows(browser, {"asks": [[asking, True]], "how": [], "card": [title], "last": True, "messages": 3})
    assert browser.evaluate(ANSWERS) == [[asking, "Blue"]]


@pytest.mark.parametrize("served", [{"status": "waiting"}], indirect=True)
@pytest.mark.parametrize("width", [1280, 390, 360, 320])
def test_a_call_of_several_questions_never_hides_one_the_card_does_not_show(served, browser, monkeypatch, width):
    colour, size = "Which colour?", f"Which sizes for {WORD}?"
    colours, sizes = [("Red", "warm"), ("Blue", "cool")], [("Small", ""), ("Large " + WORD, URL)]
    questions = [one_question("Colour", colour, *colours), one_question("Size", size, *sizes, multi=True)]
    tabs = "←  ☐ Colour  ☐ Size  ✔ Submit  →\n"
    first = pane_card(tabs + colour, *colours, *OWN_ROWS)
    second = pane_card(size, *sizes, multi=True)
    review = pane_card(f"{tabs}Review your answers\n● {colour}\n→ Blue\n● {size}\n→ Small", ("Submit answers", ""), ("Cancel", ""))
    write(served, human(EN, 1), asked(2, questions))
    serve_card(browser, first)
    open_at(browser, served, monkeypatch, width)

    def fits(want: dict) -> None:
        shows(browser, want)
        m, rest = browser.evaluate(MEASURE), browser.evaluate(MESSAGES_WIDE)
        check(m, f"{width} px, {want['card']}")
        assert rest["out"] == [] and rest["wide"] == [], (width, rest)
        if want["card"]:
            card_check(browser.evaluate(CARD_MEASURE), f"{width} px, {want['card']}")

    # the card shows one question at a time: the other stays in the thread, with no line on how to answer
    fits({"asks": [[colour, False], [size, True]], "how": [], "card": [first["title"]], "last": True, "messages": 2})
    change_card(browser, second)
    fits({"asks": [[colour, True], [size, False]], "how": [], "card": [size], "last": True, "messages": 2})
    # the review lists both with their answers
    change_card(browser, review)
    fits({"asks": [[colour, False], [size, False]], "how": [], "card": [review["title"]], "last": True, "messages": 1})
    # a question of several answers that is not the last reads from the pane as a card of one answer, which cannot answer it
    change_card(browser, pane_card(size, *[("[ ] " + label, desc) for label, desc in sizes]))
    fits({"asks": [[colour, True], [size, True]], "how": [HOW_TERM], "card": [size], "last": True, "messages": 2})
    change_card(browser, None)
    fits({"asks": [[colour, True], [size, True]], "how": [HOW_TERM], "card": [], "last": False, "messages": 2})


@pytest.mark.parametrize("served", [{"status": "waiting"}], indirect=True)
@pytest.mark.parametrize("width", [1280, 390, 360, 320])
def test_a_question_with_previews_stays_in_the_thread_beside_a_card_for_it(served, browser, monkeypatch, width):
    options = [(o["label"], o["description"]) for o in ASK[0]["options"]]
    card = pane_card(ASK[0]["question"], *options)
    write(served, human(EN, 1), asked(2, ASK[:1]))
    serve_card(browser, card)
    open_at(browser, served, monkeypatch, width)
    shows(browser, {"asks": [[ASK[0]["question"], True]], "how": [HOW_TERM], "card": [ASK[0]["question"]], "last": True, "messages": 2})
    assert browser.evaluate("document.querySelector('#chat .cl-ask-preview').textContent") == "<b>swatch</b>"


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


# ── the rest of a reply: sent images, asked questions, an API error, an interrupt ───────────────────────────────
@pytest.fixture
def pictures(tmp_path, monkeypatch):
    """The only folder a sent image may be read from; named before the app is (`served` comes after it in a test's arguments)."""
    folder = tmp_path / "pictures"
    folder.mkdir()
    monkeypatch.setenv("SALA_WEB_IMAGE_ROOTS", str(folder))
    return folder


def picture_call(folder, name: str, caption: str, minute: int, uuid: str) -> dict:
    line = call("SendUserFile", {"files": [str(folder / name)], "caption": caption, "status": "normal"}, minute)
    return line | {"uuid": uuid}       # the image route refuses the helpers' short ids


FIGURES = """[...document.querySelectorAll('#chat figure.sent')].map((f) => { const i = f.querySelector('img'), m = f.querySelector('.sent-missing');
  if (i) f.scrollIntoView(); return [f.closest('.msg').className, i ? i.complete && i.naturalWidth : 0, m ? m.textContent : '',
  (f.querySelector('figcaption') || {}).textContent || '']; })"""
ASKED_DOM = """[...document.querySelectorAll('#chat > .msg.assistant > .cl-ask')].map((q) => [q.querySelector('.cl-ask-head').textContent,
  q.querySelector('.cl-ask-q').textContent, [...q.querySelectorAll('ol > li')].map((li) => [...li.children].map((c) => c.textContent))])"""


@pytest.mark.parametrize("served", [{"status": "waiting"}], indirect=True)
@pytest.mark.parametrize("size", SIZES)
def test_a_replys_images_questions_api_error_and_interrupt_are_in_the_layers_thread(pictures, served, browser, monkeypatch, size):
    (pictures / "overview.png").write_bytes(png(64, 48))
    image = picture_call(pictures, "overview.png", "The overview", 1, "33333333-4444-4555-8666-777777777771")
    write(served, human("draw it", 1), image, tool_result(1), assistant("Drawn.", 2),
          human("go", 3), api_error(minute=3), human("stop there", 4), interrupt(4),
          human("pick one", 5), asked(5))
    figure = "document.querySelector('#chat figure.sent').outerHTML"
    loaded = f"(() => {{ const f = {FIGURES}; return f.length === 1 && f[0][1] === 64; }})()"
    open_chat(browser, served, monkeypatch, size, layer=None)
    assert wait_for(browser, loaded, 30.0), browser.evaluate(FIGURES)
    plain = browser.evaluate(figure)
    open_chat(browser, served, monkeypatch, size)
    assert wait_for(browser, f"{LAYERED} && document.querySelectorAll('#chat .cl-ask').length === 2 && {loaded}", 30.0), browser.evaluate(THREAD)
    assert browser.evaluate(figure) == plain, "drawn as the session view draws it"
    assert browser.evaluate(FIGURES) == [["msg assistant", 64, "", "The overview"]]
    assert browser.evaluate(ASKED_DOM) == [
        ["Colour", "Which colour?", [["Red", "warm"], ["Blue", "cool", "<b>swatch</b>"]]],
        ["Size", "Which size?", [["Small"]]]]
    assert browser.evaluate(THREAD) == [
        ["me", "draw it"], ["reply", ""], ["reply", "Drawn."], ["me", "go"], ["reply", OVERLOADED], ["me", "stop there"],
        ["me", "[Request interrupted by user]"], ["me", "pick one"], ["reply", ""]]
    assert browser.evaluate("document.querySelectorAll('#chat details, #chat .kept, #chat .tool').length") == 0
    # a read of the newest page leaves what is drawn as it is
    browser.evaluate("window.__q = document.querySelector('#chat .cl-ask'); SalaThreadLayer.refresh()")
    append(served, tool_result(5), assistant("Red it is.", 6))
    assert wait_for(browser, "document.querySelector('#chat').textContent.includes('Red it is.')", 20.0)
    assert browser.evaluate("window.__q === document.querySelector('#chat .cl-ask') && document.querySelectorAll('#chat .cl-ask').length === 2")


@pytest.mark.parametrize("served", [{"status": "busy"}], indirect=True)
def test_the_interrupt_line_takes_no_pending_bubble_and_says_nothing_of_the_owners_language(served, browser, monkeypatch):
    write(served, human(KO_OWNER, 1), interrupt(1), assistant(KO_TURN, 2, stop="tool_use", tool=True), tool_result(2))
    open_chat(browser, served, monkeypatch)
    assert wait_for(browser, "document.querySelectorAll('#chat > .msg.user').length === 2 && !!document.querySelector('#chat > .cl-mark')", 20.0)
    assert browser.evaluate(MARK)["turn"] == KO_TURN, "held against the owner's own last message, not the interrupt line"
    write(served, human("go on", 3))
    browser.evaluate("SalaThreadLayer.refresh()")
    thread_is(browser, [["me", "go on"]])
    send(browser, "one more thing")
    assert browser.evaluate(PENDING) == ["one more thing"]
    line = interrupt(4)
    line["timestamp"] = now()
    append(served, line)
    assert wait_for(browser, "[...document.querySelectorAll('#chat > .msg:not(.local)')].some((m) => m.textContent.includes('Request interrupted'))", 20.0)
    assert browser.evaluate(PENDING) == ["one more thing"] and browser.evaluate("state.pending.length") == 1


# every box of what this section draws ends inside the window and holds its own words
REST_WIDE = """(() => { const vw = document.documentElement.clientWidth, out = [], wide = [];
  for (const n of document.querySelectorAll('#chat .cl-ask, #chat .cl-ask *, #chat figure.sent, #chat figure.sent *, #chat > .msg .bubble, #chat > .msg .md')) {
    if (!n.getClientRects().length) continue;
    const r = n.getBoundingClientRect();
    if (r.width && (r.right > vw + 0.5 || r.left < -0.5)) out.push(n.tagName + '.' + n.className + ' ' + Math.round(r.left) + '-' + Math.round(r.right));
    if (n.clientWidth && n.scrollWidth > n.clientWidth + 1) wide.push(n.tagName + '.' + n.className + ' ' + n.scrollWidth + '>' + n.clientWidth);
  }
  return { out: out.slice(0, 8), wide: wide.slice(0, 8), asked: document.querySelectorAll('#chat .cl-ask').length,
           images: document.querySelectorAll('#chat figure.sent img').length, missing: document.querySelectorAll('#chat .sent-missing').length }; })()"""


@pytest.mark.parametrize("served", [{"status": "waiting"}], indirect=True)
@pytest.mark.parametrize("width", [1280, 390, 360, 320])
def test_no_sideways_scroll_with_sent_images_questions_an_api_error_and_an_interrupt(pictures, served, browser, monkeypatch, width):
    long_name, gone_name = "n" * 200 + ".png", "g" * 200 + ".png"
    (pictures / long_name).write_bytes(png(2400, 60))
    wide_words = f"{WORD} {URL}\n{CODE}"
    questions = [{"header": WORD, "question": wide_words, "options": [
        {"label": WORD, "description": wide_words, "preview": f"{CODE}\n{WORD}\n" + "-" * 200},
        {"label": URL, "description": "a long description " * 20}]}]
    write(served, human("draw it " + WORD, 1), picture_call(pictures, long_name, WORD, 1, "33333333-4444-4555-8666-777777777772"),
          picture_call(pictures, gone_name, "a long caption " * 20, 1, "33333333-4444-4555-8666-777777777773"), tool_result(1),
          api_error('API Error: 400 {"type":"error","detail":"' + WORD + '"} ' + URL, 2),
          human("stop " + WORD, 3), interrupt(3), human("pick " + WORD, 4), asked(4, questions))
    open_chat(browser, served, monkeypatch, (width, 800 if width > 700 else 844), doc=strip_doc())
    if width < 700:
        browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 844, "deviceScaleFactor": 1, "mobile": True})
        assert wait_for(browser, f"document.documentElement.clientWidth === {width}", 10.0)
    ready = (f"(() => {{ const f = {FIGURES}; return f.length === 2 && f.some((x) => x[1] === 2400) && f.some((x) => !!x[2]) && "
             "document.querySelectorAll('#chat .cl-ask').length === 1 && document.querySelectorAll('#chat-strip-wait-panel .wait-row').length === 2; })()")
    assert wait_for(browser, ready, 30.0), browser.evaluate(REST_WIDE)
    browser.settle("document.querySelector('#chat')")
    m, rest = browser.evaluate(MEASURE), browser.evaluate(REST_WIDE)
    assert m["vw"] == width, m
    check(m, f"{width} px with the rest of the replies")
    assert rest == {"out": [], "wide": [], "asked": 1, "images": 1, "missing": 1}, (width, rest)
