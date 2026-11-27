"""`/chat` is an address into sala's own view now, in a headless Chromium (the server's side, a 302 with a relative `Location`, is test_chatpage.py).

The chat session (SALA_CHAT_SESSION) used to have a page of its own at /chat. That page is retired: /chat leads to the main page at `#s=<the session>`, where the session opens like every
other, with its strip and its entry. Held here, at 1280 x 800 and 390 x 844 (the width rule also at 360 and 320):
  - opening /chat ends on `/#s=<the session>` with that session selected and its strip showing, not on a page of its own;
  - with no session set, /chat ends on the main page with no strip and no chat session class;
  - a working chat session shows the spinner every session shows (app.js updateInflight, no code of its own for the chat session), under the last message and drawn, and an idle one shows none;
  - arriving through /chat, no width from 1280 to 320 px scrolls sideways, drawer shut or open, with hostile text in the thread, a waiting subject and a promised line.

What a wrong answer costs: a dead /chat link, a redirect that leaves the app's prefix, a second page served beside the view, a chat session that does not show it is working, a phone page that
scrolls sideways. Runs in a headless Chromium when one is installed (conftest.py: `served`, `browser`), else is skipped; GitHub CI runs it. All names are invented."""

from __future__ import annotations

import json
import time

import pytest

from conftest import NAME, transcript_file
from test_board_items_ui import wait_for
from test_chat_session_view_ui import MEASURE, SIZES, URL, WORD, api_chat, check, drawer_open, hostile_transcript, open_page


def set_status(served, status: str) -> None:
    for f in (served["settings"].claude_dir / "sessions").glob("*.json"):
        d = json.loads(f.read_text())
        d["status"] = status
        f.write_text(json.dumps(d))


@pytest.mark.parametrize("size", SIZES)
def test_chat_leads_into_the_session_s_own_view(served, browser, monkeypatch, size):
    open_page(browser, served, monkeypatch, size, None, hash_="chat")
    assert browser.evaluate("location.pathname + location.hash") == "/s/" + NAME
    assert wait_for(browser, "!document.querySelector('#chat-strip').hidden && document.body.classList.contains('chat-session')", 10.0)
    assert browser.evaluate("state.selected") == NAME
    assert browser.evaluate("document.querySelectorAll('#composer').length") == 1


@pytest.mark.parametrize("size", SIZES)
def test_chat_with_no_session_set_ends_on_the_main_page(served, browser, monkeypatch, size):
    open_page(browser, served, monkeypatch, size, None, chat=None, hash_="chat", ready=False)
    assert wait_for(browser, "typeof loadSessions === 'function' && document.readyState === 'complete'", 15.0)
    assert browser.evaluate("location.pathname") in ("/", "/overview") and not browser.evaluate("location.hash")
    assert browser.evaluate("document.querySelector('#chat-strip').hidden") is True
    assert browser.evaluate("document.body.classList.contains('chat-session')") is False


@pytest.mark.parametrize("size", SIZES)
def test_a_working_chat_session_shows_the_spinner_every_session_shows(served, browser, monkeypatch, size):
    set_status(served, "busy")
    open_page(browser, served, monkeypatch, size, None, hash_="chat")
    assert wait_for(browser, "document.body.classList.contains('chat-session') && !!document.querySelector('#chat > .inflight .spinner')", 15.0)
    spin = browser.evaluate("(() => { const n = document.querySelector('#chat > .inflight .spinner'), r = n.getBoundingClientRect(), "
                            "last = document.querySelector('#chat').lastElementChild; return { w: r.width, h: r.height, last: last.className, "
                            "role: n.parentElement.getAttribute('role'), strip: document.querySelectorAll('#chat-strip .spinner').length }; })()")
    assert spin["w"] > 0 and spin["h"] > 0 and spin["role"] == "status" and "inflight" in spin["last"], spin      # drawn, announced, the last thing in the thread
    assert spin["strip"] == 0, "the strip draws none of its own: the spinner is the session view's"


@pytest.mark.parametrize("size", SIZES)
def test_an_idle_chat_session_shows_no_spinner(served, browser, monkeypatch, size):
    set_status(served, "idle")
    open_page(browser, served, monkeypatch, size, None, hash_="chat")
    assert wait_for(browser, "document.body.classList.contains('chat-session')", 10.0)
    browser.settle("document.querySelector('#chat')")
    assert browser.evaluate("document.querySelectorAll('.inflight, .spinner').length") == 0


@pytest.mark.parametrize("width", [1280, 390, 360, 320])
@pytest.mark.parametrize("drawer", [False, True], ids=["drawer-shut", "drawer-open"])
def test_arriving_through_chat_no_width_scrolls_sideways(served, browser, monkeypatch, width, drawer):
    transcript_file(served).write_text(hostile_transcript())
    set_status(served, "busy")
    doc = api_chat(name="A" * 40, busy=True, keptToday=123456, keptTodayFloor=True,
                   waiting=[{"id": f"item#{i}", "subject": "[demo] " + "an item subject that keeps going and going " * 8 + WORD, "url": URL} for i in range(3)],
                   motion=[{"text": WORD + " " + "m" * 100, "at": int(time.time())} for _ in range(6)])
    size = (width, 800 if width > 700 else 844)
    open_page(browser, served, monkeypatch, size, doc, hash_="chat")
    assert wait_for(browser, "document.querySelectorAll('#chat-strip-wait-panel .wait-row').length === 3 && document.querySelectorAll('#chat-strip-onit-panel .back-row').length === 6", 10.0)
    browser.evaluate("document.querySelector('#chat-strip-tab-onit').click(); ''")          # the promised lines' list is the open one while the page is measured
    if width < 700:
        browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 844, "deviceScaleFactor": 1, "mobile": True})
        assert wait_for(browser, f"document.documentElement.clientWidth === {width}", 10.0)
        if drawer:
            drawer_open(browser)
    browser.settle("document.querySelector('#chat')")
    m = browser.evaluate(MEASURE)
    assert m["vw"] == width and m["waiting"] == 3 and m["motion"] == 6 and m["msgs"] >= 2, m
    assert browser.evaluate("!!document.querySelector('#chat > .inflight .spinner')") is True      # the spinner is in the measured thread too
    check(m, f"/chat, {width} px, drawer {'open' if drawer else 'shut'}")
