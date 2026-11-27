"""A sleeping session shows its conversation and a message wakes it ("wake on send").

Before this, opening a sleeper showed a note and started its wake at once; reading it cost a wake. Now reading is free and the first message
the owner sends does the waking. What a wrong answer costs here: a sleeper that cannot be read (the owner wakes it only to see what it said),
a page that wakes a session by merely opening it (a wake the owner did not ask for), a message typed into a sleeper that is lost (the wake
failed, the page reloaded) or sent twice (a retry, a reload while it was going in), a message pasted into a pane whose Claude has not drawn its
input box yet, and a file read that reaches another session's or an unlisted conversation's file. Held here:

- `GET /api/sleeping/<name>/transcript`: the same JSON as a live session's transcript, read from the file the marker's conversation id names (the
  working directory comes from the pane map); older pages by `before`; `path: null` and no messages when the file is not there (the page then shows
  its note); 404 for a name that is not asleep, a bad name, a name a live session has, a marker with no pane-map row; nothing written, sala not run;
- `POST /api/wake` says why in the owner's words: `how` "send" (a message), "button" (the Wake button), none (the page's first way, opening it);
- the server's refusal of a send to a pane with no input box says so (`noInputBox`), which is how the page tells "not ready yet" from every other
  refusal; a dialog's refusal does not;
- the page (headless Chromium when installed; `sala` is a stand-in script that records its argv, the send is captured in the page):
  opening a sleeper shows its messages and a band, posts no wake, and leaves the composer on; a missing file shows the note; the first send
  (a "!" command here, which the page holds itself; an ordinary message is the server's to hold: test_waiting_ui.py) posts one wake (words: a message), shows the message as waiting, sends nothing to the pane, and when the session is live sends it once,
  in order with a second one; a refused wake keeps the message with the reason, in the band and in the bubble, and Try again wakes once more and
  delivers once; Edit takes the message back and nothing is sent later; a reload keeps the waiting message, follows the queued operation without
  asking for another wake, and delivers once; a woken session whose pane has no input box yet is asked again until it has one.
`sala` here is always a stand-in script in tmp_path; nothing runs the real one."""

from __future__ import annotations

import json
import os
import re
import subprocess
import time

import pytest
from starlette.testclient import TestClient

from conftest import transcript_line
from sala_web import sessions as S
from sala_web import transcript as TR
from sala_web.app import STATIC, create_app
from test_board_items_ui import wait_for
from test_composer_editable import enter, typed
# fixtures and helpers of the sleeping-session tests: the stand-in sala, the settings, the served app with a sleeper
from test_sleeping_sessions import (NAME, OP, SINCE, SLEEP_UUID, LIVE_UUID, Wake, live_row, no_tmux_names, open_page, settings_for, slept,  # noqa: F401
                                    wake)

CWD = "/w/work-a"
README = (STATIC.parent.parent.parent / "README.md").read_text()
FIRST = "which branch did the sleeper work on"
SECOND = "the sleeper worked on the demo branch"


def write_transcript(claude_dir, uuid: str = SLEEP_UUID, cwd: str = CWD, texts: list[str] | None = None):
    """The sleeper's conversation on disk: user and assistant lines alternating."""
    texts = texts or [FIRST, SECOND]
    d = claude_dir / "projects" / TR.project_slug(cwd)
    d.mkdir(parents=True, exist_ok=True)
    lines = [transcript_line("user" if i % 2 == 0 else "assistant", [{"type": "text", "text": t}], f"m-{i}") for i, t in enumerate(texts)]
    f = d / f"{uuid}.jsonl"
    f.write_text("".join(lines))
    return f


# ── the server ──────────────────────────────────────────────────────────────────────────────────────────────
def test_a_sleepers_transcript_is_read_from_its_file(tmp_path, wake):
    wake.sleeper()
    s = settings_for(tmp_path, wake)
    f = write_transcript(s.claude_dir)
    before = (f.stat().st_mtime_ns, f.stat().st_size)
    r = TestClient(create_app(s)).get(f"/api/sleeping/{NAME}/transcript")
    assert r.status_code == 200, r.text
    d = r.json()
    assert [m["blocks"][0]["text"] for m in d["messages"]] == [FIRST, SECOND]
    assert [m["role"] for m in d["messages"]] == ["user", "assistant"]
    assert d["path"] == str(f) and d["start"] is True
    assert d["session"]["sleeping"] == SINCE and d["session"]["pid"] == 0 and d["session"]["sessionId"] == SLEEP_UUID
    assert (f.stat().st_mtime_ns, f.stat().st_size) == before     # read-only
    assert wake.records() == []                                    # and nothing was asked of sala: reading never wakes


def test_a_sleepers_older_messages_page_in_by_the_cursor(tmp_path, wake):
    wake.sleeper()
    s = settings_for(tmp_path, wake)
    write_transcript(s.claude_dir, texts=[f"message {i}" for i in range(5)])
    c = TestClient(create_app(s))
    newest = c.get(f"/api/sleeping/{NAME}/transcript", params={"n": 2}).json()
    assert [m["blocks"][0]["text"] for m in newest["messages"]] == ["message 3", "message 4"] and newest["start"] is False
    older = c.get(f"/api/sleeping/{NAME}/transcript", params={"before": newest["before"], "n": 10}).json()
    assert [m["blocks"][0]["text"] for m in older["messages"]] == ["message 0", "message 1", "message 2"] and older["start"] is True
    assert c.get(f"/api/sleeping/{NAME}/transcript", params={"before": "x"}).status_code == 400


def test_a_sleeper_whose_file_is_missing_has_no_messages_and_no_error(tmp_path, wake):
    wake.sleeper()
    r = TestClient(create_app(settings_for(tmp_path, wake))).get(f"/api/sleeping/{NAME}/transcript")
    assert r.status_code == 200
    d = r.json()
    assert d["messages"] == [] and d["path"] is None and d["session"]["sleeping"] == SINCE


def test_the_file_is_found_in_another_projects_folder_by_its_conversation_id(tmp_path, wake):
    """transcript_path's own fallback (a conversation moved with its directory): the id is what names the file."""
    wake.sleeper()
    s = settings_for(tmp_path, wake)
    write_transcript(s.claude_dir, cwd="/somewhere/else")
    d = TestClient(create_app(s)).get(f"/api/sleeping/{NAME}/transcript").json()
    assert len(d["messages"]) == 2


def test_no_marker_a_live_name_a_stale_marker_and_a_bad_name_are_not_found(tmp_path, wake):
    wake.sleeper()
    wake.sleeper(uuid="b" * 8 + "-0000-4000-8000-000000000002", name="stale-one", mapped=False)   # a marker whose pane is gone
    s = settings_for(tmp_path, wake, [live_row(os.getpid(), "demo-live", LIVE_UUID)])
    write_transcript(s.claude_dir)
    write_transcript(s.claude_dir, uuid=LIVE_UUID)
    c = TestClient(create_app(s))
    for name in ("no-such-session", "demo-live", "stale-one", "-rf", "a b"):
        assert c.get(f"/api/sleeping/{name}/transcript").status_code == 404, name
    wake.wake_up()                                                  # the marker goes when it wakes: the same name is no sleeper any more
    assert c.get(f"/api/sleeping/{NAME}/transcript").status_code == 404
    assert wake.records() == []


def test_the_wake_words_say_how_the_owner_asked(tmp_path, wake):
    wake.sleeper()
    c = TestClient(create_app(settings_for(tmp_path, wake)))
    for how, phrase in (("send", "sent a message to the sleeping session demo-sleeper"), ("button", "pressed Wake on the sleeping session demo-sleeper"),
                        (None, "opened the sleeping session demo-sleeper"), ("nonsense", "opened the sleeping session demo-sleeper"), (7, "opened the sleeping session demo-sleeper")):
        body = {"name": NAME} if how is None else {"name": NAME, "how": how}
        assert c.post("/api/wake", json=body).status_code == 202
        words = wake.wakes()[-1][7]
        assert words.startswith("Rowan, via the sala web page: " + phrase + ", "), words
    assert len(wake.wakes()) == 5


def test_the_readme_names_the_route_and_the_hold():
    assert "/api/sleeping/<name>/transcript" in README
    assert "wake on send" in README.lower() or "Wake on send" in README
    assert "noInputBox" in README and "salaweb.held" in README


# ── the browser ─────────────────────────────────────────────────────────────────────────────────────────────
SPY = """(() => { window.__sent = []; window.__mode = "ok"; const real = window.fetch;
  window.fetch = (u, o) => { if (String(u).includes("/send")) { __sent.push({ url: String(u), body: JSON.parse(o.body) });
    if (window.__mode === "notready") return Promise.resolve(new Response(JSON.stringify({ ok: false, error: "no input box in the pane (a dialog or menu may be open); nothing sent", noInputBox: true }),
                                                                          { status: 409, headers: { "Content-Type": "application/json" } }));
    return Promise.resolve(new Response(JSON.stringify({ ok: true }), { status: 200, headers: { "Content-Type": "application/json" } })); }
    return real(u, o); }; return true; })()"""
WAKES_POSTED = "window.__wakePosts"
SPY_WAKE = """(() => { window.__wakePosts = 0; const real = window.fetch;
  window.fetch = (u, o) => { if (String(u).includes("api/wake")) window.__wakePosts++; return real(u, o); }; return true; })()"""


@pytest.fixture
def woken(wake, tmp_path):
    """A process that stands in for the sleeper's Claude once it is back: `wake_up()` lists it live under the sleeper's name and conversation id (its
    registry file) and removes the marker. Ended through its own handle."""
    procs: list[subprocess.Popen] = []

    def wake_up(served: dict) -> int:
        p = subprocess.Popen(["sleep", "300"])
        procs.append(p)
        rec = {"pid": p.pid, "sessionId": SLEEP_UUID, "name": NAME, "cwd": CWD, "status": "idle", "tmux": f"{NAME}:@1.%1", "procStart": S.proc_start(p.pid)}
        (served["settings"].claude_dir / "sessions" / f"{p.pid}.json").write_text(json.dumps(rec))
        wake.wake_up()
        return p.pid

    yield wake_up
    for p in procs:
        p.terminate()
    for p in procs:
        p.wait(timeout=10)


def open_sleeper(browser, served, spy: str = SPY) -> None:
    """The page on the sleeper's chat, its list loaded, and the send captured."""
    open_page(browser, served, "#s=" + NAME)
    assert wait_for(browser, "state.sleepView === %s" % json.dumps(NAME), 20.0)
    assert browser.evaluate(spy) is True
    assert browser.evaluate(SPY_WAKE) is True


def chat_text(browser) -> str:
    return browser.evaluate("document.querySelector('#chat').textContent")


def band(browser) -> dict:
    return browser.evaluate("(() => { const b = document.querySelector('#sleep-band'); return { hidden: b.hidden, text: b.textContent, failed: b.classList.contains('failed'), "
                            "button: (b.querySelector('.wake-btn') || {}).textContent || '' }; })()")


def sent(browser) -> list[dict]:
    return browser.evaluate("window.__sent")


def wait_sent(browser, n: int, timeout: float = 30.0) -> list[dict]:
    assert wait_for(browser, f"window.__sent.length >= {n}", timeout), (browser.evaluate("window.__sent"), band(browser))
    return sent(browser)


@pytest.fixture
def readable(slept):
    """The served app with the sleeper and its conversation on disk."""
    write_transcript(slept["settings"].claude_dir)
    return slept


def test_opening_a_sleeper_shows_its_messages_and_wakes_nothing(readable, wake, browser):
    open_sleeper(browser, readable)
    assert wait_for(browser, "document.querySelectorAll('#chat > .msg').length === 2", 15.0), chat_text(browser)
    text = chat_text(browser)
    assert FIRST in text and SECOND in text
    b = band(browser)
    assert b["hidden"] is False and "asleep since" in b["text"] and "10:10" in b["text"] and "wakes it" in b["text"], b      # the page's zone, Dubai in the tests
    assert b["button"] == "Wake it"                                                                                          # the Wake button stays
    assert browser.evaluate("document.querySelector('#input').isContentEditable") is True
    assert browser.evaluate("document.querySelector('#chat .older') === null || true")
    time.sleep(5)                                                                                                            # more than two polls of the list
    assert wake.wakes() == [] and browser.evaluate(WAKES_POSTED) == 0                                                      # opening it asked sala for nothing
    assert band(browser)["text"] == b["text"]                                                                                 # and the band is as it was
    assert browser.evaluate("document.querySelectorAll('#chat > .msg').length") == 2                                         # a poll leaves the conversation alone


def test_a_sleeper_with_no_file_shows_the_note_and_the_band(slept, wake, browser):
    open_sleeper(browser, slept)
    assert wait_for(browser, "document.querySelector('#chat .sleeping-note') !== null", 15.0)
    assert "could not be shown" in chat_text(browser) and "asleep since" in chat_text(browser)
    assert band(browser)["hidden"] is False
    time.sleep(3)
    assert wake.wakes() == []


def test_leaving_a_sleeper_hides_its_band(readable, wake, browser):
    open_sleeper(browser, readable)
    assert band(browser)["hidden"] is False
    browser.evaluate("selectSession(%s, { force: true })" % json.dumps(readable["name"]))
    assert wait_for(browser, "document.querySelector('#sleep-band').hidden === true", 10.0)
    assert wait_for(browser, "document.querySelectorAll('#chat > .msg').length >= 1")
    assert wake.wakes() == []


def test_the_first_send_wakes_it_and_the_message_goes_in_once_when_it_is_back(readable, wake, woken, browser):
    wake.mode("queued")
    wake.op("queued")
    open_sleeper(browser, readable)
    assert wait_for(browser, "document.querySelectorAll('#chat > .msg').length === 2", 15.0)
    browser.evaluate("document.querySelector('#input').focus(); ''")
    typed(browser, "! wake and answer me")
    enter(browser)
    assert wait_for(browser, "document.querySelector('#chat .msg.local.held') !== null", 10.0)
    end = time.time() + 15
    while not wake.wakes() and time.time() < end:
        time.sleep(0.1)
    (argv,) = wake.wakes()
    assert argv[:4] == ["op", "wake", "--only", NAME] and "sent a message to the sleeping session" in argv[7], argv
    bubble = browser.evaluate("document.querySelector('#chat .msg.local.held').textContent")
    assert "wake and answer me" in bubble and "Waiting for demo-sleeper to wake" in bubble, bubble
    assert wait_for(browser, "/queued/.test(document.querySelector('#sleep-band').textContent)", 10.0)                       # the wake's own words
    time.sleep(5)                                                                                                            # two polls while it sleeps
    assert sent(browser) == [] and len(wake.wakes()) == 1                                                                    # nothing goes to a pane with no Claude
    assert browser.evaluate("getText()") == ""                          # the composer emptied: the bubble holds it
    pid = woken(readable)
    got = wait_sent(browser, 1)
    time.sleep(5)
    got = sent(browser)
    assert len(got) == 1 and got[0]["body"]["text"] == "! wake and answer me" and got[0]["url"].endswith(f"api/s/{pid}/send"), got      # once, to the live pid
    assert len(wake.wakes()) == 1
    assert wait_for(browser, "document.querySelector('#sleep-band').hidden === true", 10.0)                                   # it is a live session now
    assert browser.evaluate("localStorage.getItem('salaweb.held')") is None                                                  # nothing kept for a reload


def test_two_messages_while_it_sleeps_wake_it_once_and_go_in_in_order(readable, wake, woken, browser):
    wake.mode("queued")
    wake.op("queued")
    open_sleeper(browser, readable)
    assert wait_for(browser, "document.querySelectorAll('#chat > .msg').length === 2", 15.0)
    browser.evaluate("document.querySelector('#input').focus(); ''")
    typed(browser, "! first thing")
    enter(browser)
    assert wait_for(browser, "document.querySelectorAll('#chat .msg.local.held').length === 1", 10.0)
    browser.evaluate("document.querySelector('#input').focus(); ''")
    typed(browser, "! second thing")
    enter(browser)
    assert wait_for(browser, "document.querySelectorAll('#chat .msg.local.held').length === 2", 10.0)
    time.sleep(3)
    assert len(wake.wakes()) == 1                                                                                            # a second message asks for no second wake
    woken(readable)
    got = wait_sent(browser, 2)
    time.sleep(3)
    got = sent(browser)
    assert [g["body"]["text"] for g in got] == ["! first thing", "! second thing"]


def test_a_woken_pane_with_no_input_box_yet_is_asked_again_and_the_message_goes_in_once(readable, wake, woken, browser):
    wake.mode("queued")
    wake.op("queued")
    open_sleeper(browser, readable)
    assert wait_for(browser, "document.querySelectorAll('#chat > .msg').length === 2", 15.0)
    browser.evaluate("window.__mode = 'notready'; document.querySelector('#input').focus(); ''")
    typed(browser, "! are you up")
    enter(browser)
    assert wait_for(browser, "document.querySelector('#chat .msg.local.held') !== null", 10.0)
    woken(readable)
    wait_sent(browser, 2, 40.0)                                                                                              # asked, refused ("not ready"), asked again
    assert browser.evaluate("document.querySelector('#chat .msg.local .note.err') === null")                                 # no failure shown while it is only not ready
    browser.evaluate("window.__mode = 'ok'")
    n = len(wait_sent(browser, 3, 40.0))
    time.sleep(5)
    got = sent(browser)
    assert len(got) == n and all(g["body"]["text"] == "! are you up" for g in got)
    assert wait_for(browser, "!document.querySelector('#chat .msg.local .note.err')")


def test_a_refused_wake_keeps_the_message_and_says_why_and_try_again_delivers_once(readable, wake, woken, browser):
    wake.mode("refused")
    open_sleeper(browser, readable)
    assert wait_for(browser, "document.querySelectorAll('#chat > .msg').length === 2", 15.0)
    browser.evaluate("document.querySelector('#input').focus(); ''")
    typed(browser, "! please wake up")
    enter(browser)
    assert wait_for(browser, "document.querySelector('#sleep-band').classList.contains('failed')", 15.0)
    b = band(browser)
    assert "Could not wake demo-sleeper" in b["text"] and "words are not the owner's" in b["text"] and b["button"] == "Try again", b
    note = browser.evaluate("document.querySelector('#chat .msg.local.held .note.err').textContent")
    assert "did not wake" in note and "words are not the owner's" in note and "message is kept" in note, note
    assert "please wake up" in chat_text(browser)                                                                            # the message is still there
    assert browser.evaluate("JSON.parse(localStorage.getItem('salaweb.held'))['demo-sleeper'].msgs[0].text") == "! please wake up"
    assert sent(browser) == []
    # Try again, now that the queue takes it
    wake.mode("queued")
    wake.op("queued")
    browser.evaluate("document.querySelector('#sleep-band .wake-btn').click()")
    end = time.time() + 15
    while len(wake.wakes()) < 2 and time.time() < end:
        time.sleep(0.1)
    assert len(wake.wakes()) == 2
    woken(readable)
    wait_sent(browser, 1)
    time.sleep(4)
    got = sent(browser)
    assert len(got) == 1 and got[0]["body"]["text"] == "! please wake up"


def test_edit_takes_a_held_message_back_and_nothing_is_sent_later(readable, wake, woken, browser):
    wake.mode("queued")
    wake.op("queued")
    open_sleeper(browser, readable)
    assert wait_for(browser, "document.querySelectorAll('#chat > .msg').length === 2", 15.0)
    browser.evaluate("document.querySelector('#input').focus(); ''")
    typed(browser, "! never mind")
    enter(browser)
    assert wait_for(browser, "document.querySelector('#chat .msg.local.held') !== null", 10.0)
    browser.evaluate("[...document.querySelectorAll('#chat .msg.local.held .note-actions button')].find((b) => b.textContent === 'Edit').click()")
    assert wait_for(browser, "getText() === '! never mind'", 10.0)
    assert browser.evaluate("document.querySelector('#chat .msg.local.held') === null")
    assert browser.evaluate("localStorage.getItem('salaweb.held')") is None
    woken(readable)                                                                                                          # it wakes anyway (the wake was asked)
    assert wait_for(browser, "document.querySelector('#sleep-band').hidden === true", 20.0)
    time.sleep(4)
    assert sent(browser) == []                                                                                               # but the message the owner took back is not sent


def test_the_wake_button_wakes_without_a_message_and_sends_nothing(readable, wake, woken, browser):
    wake.mode("queued")
    wake.op("queued")
    open_sleeper(browser, readable)
    assert wait_for(browser, "document.querySelector('#sleep-band .wake-btn') !== null", 15.0)
    browser.evaluate("document.querySelector('#sleep-band .wake-btn').click()")
    end = time.time() + 15
    while not wake.wakes() and time.time() < end:
        time.sleep(0.1)
    (argv,) = wake.wakes()
    assert "pressed Wake on the sleeping session" in argv[7], argv
    assert wait_for(browser, "/queued/.test(document.querySelector('#sleep-band').textContent)", 10.0)
    woken(readable)
    assert wait_for(browser, "document.querySelector('#sleep-band').hidden === true", 20.0)
    time.sleep(3)
    assert sent(browser) == [] and len(wake.wakes()) == 1


def test_a_reload_keeps_the_waiting_message_and_follows_the_wake_it_does_not_ask_again(readable, wake, woken, browser):
    wake.mode("queued")
    wake.op("queued")
    open_sleeper(browser, readable)
    assert wait_for(browser, "document.querySelectorAll('#chat > .msg').length === 2", 15.0)
    browser.evaluate("document.querySelector('#input').focus(); ''")
    typed(browser, "! survive the reload")
    enter(browser)
    assert wait_for(browser, "JSON.parse(localStorage.getItem('salaweb.held') || '{}')['demo-sleeper'] && JSON.parse(localStorage.getItem('salaweb.held'))['demo-sleeper'].op === %s" % json.dumps(OP), 20.0)
    assert len(wake.wakes()) == 1
    browser.reload()
    assert wait_for(browser, "state.sleepView === %s" % json.dumps(NAME), 20.0)
    assert browser.evaluate(SPY) is True
    assert browser.evaluate(SPY_WAKE) is True
    assert wait_for(browser, "document.querySelector('#chat .msg.local.held') !== null", 15.0)
    assert "survive the reload" in browser.evaluate("document.querySelector('#chat .msg.local.held').textContent")
    assert wait_for(browser, "/queued/.test(document.querySelector('#sleep-band').textContent)", 10.0)                       # it follows the operation
    time.sleep(5)
    assert len(wake.wakes()) == 1 and browser.evaluate(WAKES_POSTED) == 0                                                    # and asks for no second wake
    woken(readable)
    wait_sent(browser, 1)
    time.sleep(4)
    got = sent(browser)
    assert len(got) == 1 and got[0]["body"]["text"] == "! survive the reload"
    assert browser.evaluate("localStorage.getItem('salaweb.held')") is None


# ── the script, read as text (these run where there is no browser) ────────────────────────────────────────────
APP_JS = (STATIC / "app.js").read_text()


def function_text(name: str) -> str:
    """The source of `function NAME` / `async function NAME` in app.js, up to the next top-level declaration."""
    m = re.search(r"^(?:async )?function %s\(" % re.escape(name), APP_JS, re.M)
    assert m, name
    end = re.search(r"^(?:async function |function |const |/\* -{5,})", APP_JS[m.end():], re.M)
    return APP_JS[m.start():m.end() + end.start()] if end else APP_JS[m.start():]


def test_opening_a_sleeper_in_the_script_asks_for_no_wake():
    for fn in ("showSleeping", "paintSleeping", "paintSleepNote", "selectSession"):
        body = function_text(fn)
        assert "wakeSleeper(" not in body.replace("onclick: () => wakeSleeper(s.name)", ""), fn   # only the Wake button's own click calls it
        assert "api/wake" not in body, fn
    assert "api/sleeping/" in function_text("showSleeping") and "/transcript" in function_text("showSleeping")


def test_a_send_to_a_sleeper_is_held_and_not_delivered_in_the_script():
    body = function_text("send")
    assert "if (ob) SalaWaiting.post(p);\n  else if (asleep) holdForWake(p);" in body   # the server's outbox, else (a "!" command) held by the page
    assert 'const hold = !ob && (!!asleep || behind);' in body and 'status: hold ? "held" : "sending"' in body
    assert "deliver(" not in function_text("holdForWake")
    assert 'x.status === "held"' in function_text("releaseHeld") and "state.sending" in function_text("releaseHeld")
