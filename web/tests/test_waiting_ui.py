"""A message that waits to be read (static/waiting.js, the server's outbox behind it).

It is one state whatever holds it: a dashed bubble with "Waiting" under it, no time, Edit and Cancel. While a question or permission dialog is
open the line says to answer it first, and a message already in the pane offers no button (Edit and Cancel can not take it back then, and
Send now waits for the dialog). Otherwise a message in the terminal's queue offers Send now beside Edit and Cancel. Cancel and Edit ask the
server to take the message back and say what happened: taken back, or too late. A bubble goes when its message is delivered or withdrawn, a
reload draws the waiting ones again from the server's list, and nothing is wider than a 360 px phone.

The page runs in a headless Chromium when one is installed (conftest.py: `served`, `browser`); without one these are skipped. Where a test
needs a state the fake session can not reach (a message in a pane), the outbox is answered in the page; the others use the real server."""

from __future__ import annotations

import json
import time

import pytest

from conftest import CHAT_READY, NAME
from test_board_items_ui import wait_for
from test_composer_editable import enter, typed
from test_sleeper_transcript import SPY, open_sleeper, readable, sent  # noqa: F401  (readable: a fixture)
from test_sleeping_sessions import NAME as SLEEPER
from test_sleeping_sessions import OP, slept, wake  # noqa: F401  (fixtures)

# JS: the outbox answered in the page. `__box` is the server's list (a GET), `__posts` every POST; a cancel waits for `__answer(status, body)`
STUB = """(() => { window.__box = []; window.__posts = []; window.__netDown = false; const real = window.fetch;
  const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
  window.fetch = (u, o) => {
    const url = String(u);
    if (!url.startsWith("api/outbox/")) return real(u, o);
    if (!o || o.method !== "POST") return Promise.resolve(json({ ok: true, messages: __box }));
    const body = JSON.parse(o.body);
    __posts.push({ url, body });
    if (window.__netDown) return Promise.reject(new TypeError("Failed to fetch"));
    if (url.endsWith("/cancel")) return new Promise((res) => { window.__answer = (status, answer) => { if (answer.messages) __box = answer.messages; res(json(answer, status)); }; });
    const now = Date.now(), m = { id: "p" + __posts.length, cid: body.cid, text: body.text, uploads: body.uploads, state: "queued", reason: null, error: "", created: now, updated: now };
    __box = [...__box, m];
    return Promise.resolve(json({ ok: true, message: m, messages: __box }));
  };
  return true; })()"""
BUBBLES = """[...document.querySelectorAll("#chat > .msg.local")].map((n) => ({ text: n.querySelector(".bubble")?.textContent, cls: n.className,
  line: n.querySelector(".waiting-line .st span")?.textContent || "", buttons: [...n.querySelectorAll(".note-actions button")].map((b) => b.textContent),
  note: n.querySelector(".note.err")?.textContent || "", time: !!n.querySelector(".stamp"), copy: !!n.querySelector(".copy-btn"),
  border: n.querySelector(".bubble") ? getComputedStyle(n.querySelector(".bubble")).borderTopStyle : "" }))"""
STATUS = "document.querySelector('#send-status').textContent"
DIALOG = "answer Claude's question first"


def msg(i: int, text: str, state: str = "queued", reason: str | None = None, uploads: tuple = (), error: str = "", age: int = 0) -> dict:
    now = int(time.time() * 1000) - age
    return {"id": f"m{i}", "cid": f"c{i}", "text": text, "uploads": list(uploads), "state": state, "reason": reason, "detail": "", "error": error,
            "created": now + i, "updated": now + i}


def opened(browser, served, stub: bool = True) -> None:
    browser.open(f"{served['url']}/#s={NAME}")
    browser.wait_ready(CHAT_READY)
    if stub:
        assert browser.evaluate(STUB)


def show(browser, *messages: dict) -> None:
    """The server's list is now `messages`, and the page is told."""
    browser.evaluate(f"window.__box = {json.dumps(list(messages))}; SalaWaiting.sync({json.dumps(NAME)}, __box, true); ''")


def bubbles(browser) -> list[dict]:
    return browser.evaluate(BUBBLES)


def press(browser, text: str, button: str) -> None:
    browser.evaluate(f"""[...document.querySelectorAll("#chat > .msg.local")].find((n) => n.querySelector(".bubble").textContent === {json.dumps(text)})
      .querySelectorAll(".note-actions button").forEach((b) => {{ if (b.textContent === {json.dumps(button)}) b.click(); }}); ''""")


def send(browser, text: str) -> None:
    browser.evaluate("document.querySelector('#input').focus(); ''")
    typed(browser, text)
    enter(browser)


def test_held_and_queued_messages_are_one_dashed_state_with_edit_and_cancel_and_no_time(served, browser):
    opened(browser, served)
    show(browser, msg(1, "first", "queued"), msg(2, "second", "typing"), msg(3, "third", "held", "draft"), msg(4, "fourth", "held", "ahead"))
    got = bubbles(browser)
    assert [b["text"] for b in got] == ["first", "second", "third", "fourth"], got
    for b in got:
        # the two in the terminal's queue also offer Send now (test_send_now_ui.py); the two held by the server do not
        want = ["Send now", "Edit", "Cancel"] if b["text"] in ("first", "second") else ["Edit", "Cancel"]
        assert "waiting" in b["cls"] and b["line"] == "Waiting" and b["buttons"] == want, b
        assert b["border"] == "dashed" and not b["time"] and b["copy"], b
    # the same list again draws nothing anew (a button under a finger stays)
    browser.evaluate("window.__node = document.querySelector('#chat > .msg.local'); SalaWaiting.sync(%s, __box, true); ''" % json.dumps(NAME))
    assert browser.evaluate("window.__node === document.querySelector('#chat > .msg.local')")


@pytest.mark.parametrize("served", [{"status": "waiting"}], indirect=True)
def test_a_dialog_says_why_and_a_message_in_the_pane_offers_nothing(served, browser):
    opened(browser, served)
    show(browser, msg(1, "in the pane", "queued"), msg(2, "held back", "held", "dialog"))
    got = bubbles(browser)
    assert [b["line"] for b in got] == [f"Waiting · {DIALOG}"] * 2, got
    assert [b["buttons"] for b in got] == [[], ["Edit", "Cancel"]], got


@pytest.mark.parametrize("served", [{"status": "busy"}], indirect=True)
def test_a_menu_claude_did_not_open_gives_no_reason(served, browser):
    opened(browser, served)
    show(browser, msg(1, "in the pane", "queued"), msg(2, "held back", "held", "dialog"))
    got = bubbles(browser)
    assert [b["line"] for b in got] == ["Waiting"] * 2, got
    assert [b["buttons"] for b in got] == [[], ["Edit", "Cancel"]], got


@pytest.mark.parametrize("queued", [msg(1, "with a file", uploads=("a/b.txt",)), msg(1, "/cost")], ids=["upload", "slash"])
def test_what_can_not_be_pulled_out_of_the_pane_offers_nothing(served, browser, queued):
    opened(browser, served)
    show(browser, queued, msg(2, "not typed yet", "held", "ahead"))
    # the one in the pane can not be taken back, but it can be sent now (test_send_now_ui.py)
    assert [b["buttons"] for b in bubbles(browser)] == [["Send now"], ["Edit", "Cancel"]]


def test_cancel_says_the_others_move_and_then_that_claude_did_not_get_it(served, browser):
    opened(browser, served)
    one, two = msg(1, "one"), msg(2, "two")
    show(browser, one, two)
    press(browser, "one", "Cancel")
    got = bubbles(browser)
    assert [b["line"] for b in got] == ["Taking it back…", "Taking it out briefly and putting it back…"], got
    assert [b["buttons"] for b in got] == [[], []], got
    assert browser.evaluate("__posts.map((p) => p.url)") == [f"api/outbox/{NAME}/m1/cancel"]
    gone = {**one, "state": "withdrawn", "updated": one["updated"] + 10}
    browser.evaluate(f"__answer(200, {json.dumps({'ok': True, 'message': gone, 'messages': [gone, two]})}); ''")
    assert wait_for(browser, "document.querySelectorAll('#chat > .msg.local').length === 1", 5.0), bubbles(browser)
    assert browser.evaluate(STATUS) == "Cancelled. Claude did not get it."
    assert bubbles(browser)[0]["line"] == "Waiting" and bubbles(browser)[0]["buttons"] == ["Send now", "Edit", "Cancel"]
    show(browser, one, two)   # an older list that still has it brings nothing back
    assert [b["text"] for b in bubbles(browser)] == ["two"]


def test_edit_puts_the_taken_back_message_in_the_composer(served, browser):
    opened(browser, served)
    one = msg(1, "change me\nand this line")
    show(browser, one)
    press(browser, one["text"], "Edit")
    browser.evaluate(f"__answer(200, {json.dumps({'ok': True, 'messages': [{**one, 'state': 'withdrawn'}]})}); ''")
    assert wait_for(browser, f"getText() === {json.dumps(one['text'])}", 5.0)
    assert bubbles(browser) == [] and browser.evaluate(STATUS) == "Taken back. Sent again, it goes to the end of the line."


@pytest.mark.parametrize("button, answer, words, left", [
    ("Cancel", {"tooLate": True}, "Claude had already read it, so it was not cancelled.", []),
    ("Edit", {"tooLate": True}, "Claude had already read it, so it was not changed.", []),
    ("Cancel", {"busy": True}, "It could not be taken back just now. Try again in a moment.", ["Send now", "Edit", "Cancel"]),
])
def test_a_refused_take_back_says_so_and_a_read_message_loses_its_buttons(served, browser, button, answer, words, left):
    opened(browser, served)
    one = msg(1, "too late")
    show(browser, one)
    press(browser, "too late", button)
    browser.evaluate(f"__answer(409, {json.dumps({'ok': False, 'error': 'x', 'messages': [one], **answer})}); ''")
    assert wait_for(browser, f"{STATUS} === {json.dumps(words)}", 5.0), browser.evaluate(STATUS)
    assert [b["buttons"] for b in bubbles(browser)] == [left] and browser.evaluate("getText()") == ""


def test_a_delivered_message_waits_for_the_transcripts_copy_and_a_withdrawn_one_goes_at_once(served, browser):
    opened(browser, served)
    send(browser, "watch me")
    assert wait_for(browser, "document.querySelector('#chat > .msg.local .note-actions') !== null", 5.0), bubbles(browser)
    box = browser.evaluate("__box")
    done = {**box[0], "state": "delivered", "updated": box[0]["updated"] + 10}
    show(browser, done)
    got = bubbles(browser)
    assert len(got) == 1 and got[0]["buttons"] == [] and not got[0]["time"], got
    assert wait_for(browser, "document.querySelectorAll('#chat > .msg.local').length === 0", 8.0)
    show(browser, msg(2, "gone"))
    show(browser, {**msg(2, "gone", "withdrawn"), "updated": int(time.time() * 1000) + 1000})
    assert bubbles(browser) == []


def test_the_transcripts_copy_takes_the_bubbles_place(served, browser):
    opened(browser, served)
    send(browser, "read me")
    assert wait_for(browser, "document.querySelector('#chat > .msg.local .note-actions') !== null", 5.0), bubbles(browser)
    browser.evaluate("renderMessage({ role: 'user', uuid: 'w-1', ts: new Date().toISOString(), blocks: [{ kind: 'text', text: 'read me' }] }, { live: true }); ''")
    assert bubbles(browser) == [] and browser.evaluate("state.pending.length") == 0
    show(browser, *browser.evaluate("__box"))   # the list that still says queued brings no second one
    assert bubbles(browser) == []


# the bottom of the chat, top to bottom: the working mark, the question card, each waiting bubble and anything that has reached Claude
ORDER = """[...document.querySelector("#chat").children].filter((n) => n.matches(".msg, .inflight, .q-card")).map((n) =>
  n.matches(".inflight") ? "mark" : n.matches(".q-card") ? "card" : n.matches(".msg.waiting") ? "waiting " + n.querySelector(".bubble").textContent : n.textContent)"""
REPLY = ("renderMessage({ role: 'assistant', uuid: 'z-1', ts: new Date().toISOString(), blocks: [{ kind: 'text', text: 'a later reply' }] }, "
         "{ live: true }); ''")


def tail(browser, n: int) -> list[str]:
    return browser.evaluate(ORDER)[-n:]


@pytest.mark.parametrize("served", [{"status": "busy"}], indirect=True)
def test_what_waits_stands_below_the_working_mark_and_what_arrives_goes_above_it(served, browser):
    opened(browser, served)
    assert wait_for(browser, "!!document.querySelector('#chat > .inflight')", 10.0)
    for i, text in enumerate(("first", "second"), 1):
        send(browser, text)
        assert wait_for(browser, f"document.querySelectorAll('#chat > .msg.waiting .note-actions').length === {i}", 5.0), bubbles(browser)
    assert tail(browser, 3) == ["mark", "waiting first", "waiting second"], browser.evaluate(ORDER)
    browser.evaluate(REPLY)
    got = tail(browser, 4)
    assert "a later reply" in got[0] and got[1:] == ["mark", "waiting first", "waiting second"], got
    browser.evaluate("updateInflight(); updateInflight(); ''")   # each status event paints it again
    assert tail(browser, 4) == got


@pytest.mark.parametrize("served", [{"status": "busy"}], indirect=True)
def test_a_failed_message_stays_above_the_mark_until_it_is_sent_again_and_then_joins_the_end(served, browser):
    opened(browser, served)
    assert wait_for(browser, "!!document.querySelector('#chat > .inflight')", 10.0)
    one, two = msg(1, "broke", "failed", error="the pane went away"), msg(2, "still queued")
    show(browser, one, two)
    got = tail(browser, 3)
    assert got[0].startswith("broke") and got[1:] == ["mark", "waiting still queued"], got
    press(browser, "broke", "Retry")
    browser.evaluate(f"__answer(200, {json.dumps({'ok': True, 'messages': [two, {**one, 'state': 'withdrawn'}]})}); ''")
    assert wait_for(browser, f"JSON.stringify({ORDER}.slice(-3)) === '[\"mark\",\"waiting still queued\",\"waiting broke\"]'", 5.0), browser.evaluate(ORDER)


@pytest.mark.parametrize("served", [{"status": "waiting"}], indirect=True)
def test_what_waits_stands_above_the_question_card(served, browser):
    opened(browser, served)
    browser.evaluate("document.querySelector('#chat').append(el('div', { class: 'q-card' })); ''")   # the fake session has no pane to read a card from
    show(browser, msg(1, "from the server", "held", "dialog"))
    send(browser, "typed here")
    assert wait_for(browser, "document.querySelectorAll('#chat > .msg.waiting').length === 2", 5.0), bubbles(browser)
    assert tail(browser, 3) == ["waiting from the server", "waiting typed here", "card"], browser.evaluate(ORDER)


def test_a_failed_message_is_withdrawn_before_it_is_sent_again(served, browser):
    opened(browser, served)
    show(browser, msg(1, "broke", "failed", error="the pane went away"))
    got = bubbles(browser)
    assert "failed" in got[0]["cls"] and got[0]["note"] == "Not sent: the pane went away" and got[0]["buttons"] == ["Retry", "Edit"], got
    press(browser, "broke", "Retry")
    browser.evaluate("__answer(200, { ok: true, messages: [] }); ''")
    assert wait_for(browser, "__posts.length === 2", 5.0)
    posts = browser.evaluate("__posts")
    assert posts[0]["url"].endswith("/m1/cancel") and posts[1]["url"] == f"api/outbox/{NAME}", posts
    assert posts[1]["body"]["text"] == "broke" and posts[1]["body"]["cid"] != "c1", posts
    assert wait_for(browser, "document.querySelector('#chat > .msg.local.waiting') !== null", 5.0)


def test_a_send_with_no_answer_keeps_its_id_for_the_retry(served, browser):
    opened(browser, served)
    browser.evaluate("window.__netDown = true; ''")
    send(browser, "lost on the way")
    assert wait_for(browser, "document.querySelector('#chat > .msg.local.failed') !== null", 5.0), bubbles(browser)
    assert "connection to the server was lost" in bubbles(browser)[0]["note"]
    browser.evaluate("window.__netDown = false; ''")
    press(browser, "lost on the way", "Retry")
    assert wait_for(browser, "__posts.length === 2 && !!document.querySelector('#chat > .msg.local.waiting .note-actions')", 5.0), bubbles(browser)
    first, again = browser.evaluate("__posts")
    assert first["body"]["cid"] == again["body"]["cid"]


@pytest.mark.parametrize("served", [{"status": "waiting"}], indirect=True)
@pytest.mark.parametrize("width", [360, 1280])
def test_nothing_of_a_waiting_message_is_wider_than_the_screen(served, browser, width):
    opened(browser, served)
    browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 800, "deviceScaleFactor": 1, "mobile": width < 700})
    assert wait_for(browser, f"document.documentElement.clientWidth === {width}", 10.0)
    show(browser, msg(1, "x" * 400, "held", "dialog"), msg(2, "a long message " * 30, "queued"), msg(3, "y" * 200, "failed", error="z" * 200))
    browser.settle("document.querySelector('#chat')")
    got = browser.evaluate("""(() => { const vw = document.documentElement.clientWidth;
      const out = [...document.querySelectorAll('#chat > .msg.local, #chat > .msg.local *')].filter((n) => n.getClientRects().length)
        .map((n) => [n.getAttribute('class') || n.tagName, n.getBoundingClientRect()]).filter(([, r]) => r.right > vw + 0.5 || r.left < -0.5);
      return { out: out.map(([c, r]) => c + ' ' + Math.round(r.left) + '-' + Math.round(r.right)).slice(0, 8), doc: document.documentElement.scrollWidth,
               pane: pane().scrollWidth - pane().clientWidth, n: document.querySelectorAll('#chat > .msg.local').length }; })()""")
    assert got["n"] == 3 and got["out"] == [] and got["doc"] <= width and got["pane"] <= 0, got


def server_list(browser, name: str) -> list[dict]:
    return browser.evaluate(f"fetch('api/outbox/{name}').then((r) => r.json()).then((d) => d.messages)")


def test_a_reload_draws_the_waiting_message_again_and_cancel_withdraws_it_on_the_server(served, browser):
    opened(browser, served, stub=False)   # the real server: the fake session has no pane, so it holds the message
    send(browser, "kept by the server")
    shown = "document.querySelector('#chat > .msg.local.waiting .note-actions') !== null"
    assert wait_for(browser, shown, 10.0), bubbles(browser)
    assert [m["state"] for m in server_list(browser, NAME)] == ["held"]
    browser.reload(CHAT_READY)
    assert wait_for(browser, shown, 10.0), bubbles(browser)
    got = bubbles(browser)
    assert len(got) == 1 and got[0]["text"] == "kept by the server" and got[0]["buttons"] == ["Edit", "Cancel"] and not got[0]["time"], got
    press(browser, "kept by the server", "Cancel")
    assert wait_for(browser, "document.querySelectorAll('#chat > .msg.local').length === 0", 10.0), bubbles(browser)
    assert [m["state"] for m in server_list(browser, NAME)] == ["withdrawn"]


def test_a_sleepers_message_is_held_by_the_server_and_a_reload_follows_the_same_wake(readable, wake, browser):
    wake.mode("queued")
    wake.op("queued")
    open_sleeper(browser, readable)
    assert wait_for(browser, "document.querySelectorAll('#chat > .msg').length === 2", 15.0)
    send(browser, "wake and answer me")
    stored = "JSON.parse(localStorage.getItem('salaweb.held') || '{}')['%s']" % SLEEPER
    assert wait_for(browser, f"!!{stored} && {stored}.op === {json.dumps(OP)}", 20.0), bubbles(browser)
    assert browser.evaluate(stored) == {"op": OP, "msgs": []}   # the server holds the message; the page keeps only the wake it follows
    (argv,) = wake.wakes()
    assert "sent a message to the sleeping session" in argv[7], argv
    assert [(m["state"], m["reason"]) for m in server_list(browser, SLEEPER)] == [("held", "asleep")] and sent(browser) == []
    browser.reload()
    assert wait_for(browser, "state.sleepView === %s" % json.dumps(SLEEPER), 20.0)
    assert browser.evaluate(SPY) is True
    assert wait_for(browser, "document.querySelector('#chat > .msg.local.waiting .note-actions') !== null", 15.0), bubbles(browser)
    got = bubbles(browser)
    assert len(got) == 1 and got[0]["text"] == "wake and answer me" and got[0]["buttons"] == ["Edit", "Cancel"], got
    time.sleep(5)
    assert len(wake.wakes()) == 1   # the queued operation is followed, not asked again
    press(browser, "wake and answer me", "Cancel")
    assert wait_for(browser, "document.querySelectorAll('#chat > .msg.local').length === 0", 10.0), bubbles(browser)
    assert [m["state"] for m in server_list(browser, SLEEPER)] == ["withdrawn"] and sent(browser) == []
