"""The chat session's kept-back switch in a headless Chromium (the rule and the reads are test_chatkeep.py; the page's text is test_chat_session_view.py).

The chat session (SALA_CHAT_SESSION) is sala's own view of a session. The server keeps back a turn its owner did not start: each is one quiet line in the thread, drawn
only while the strip's switch is on, and the switch's count is the number of those lines. A turn the owner started shows whole, as sala shows any turn. Held here, at
1280 x 800 and 390 x 844, against the real server and a real transcript (nothing about api/chat or the stream is replaced):
  - the switch is live (not disabled, no "not active yet"), off at first: the kept lines are in the thread and hidden, and the owner's turns, tool calls included, show;
  - a click shows every kept line (one quiet line each: time, where it came from, what it was, what the session did), a second click hides them, and the count in the
    strip equals the number of lines, never fewer: a line the rule does not know and a line sala typed are among them;
  - no "[for ...]" mark and no `<!-- sala -->` mark is drawn anywhere on the page, switch on or off; a hidden turn's own tool calls and narration are not in the page;
  - a hidden turn that arrives while the page is open adds its line and the count; its reply lands on the same line (no second line); a reply for the owner shows
    itself, the mark off, and takes the line away;
  - the same composer, once, and the header stay where they are when the thread scrolls;
  - NO SIDEWAYS SCROLL, at 1280, 390, 360 and 320 px, with the switch off and on, drawer shut and open, with a 300-character word, a long address, wide code and a wide
    table in the owner's turns and in the kept lines.

What a wrong answer costs: a hidden turn's tool calls on the owner's page, a count that disagrees with the lines, a switch that does nothing, a second line for one turn,
a mark drawn, a page that scrolls sideways. Runs in a headless Chromium when one is installed (conftest.py: `served`, `browser`), else is skipped; GitHub CI runs it.
All names are invented."""

from __future__ import annotations

import json
import time

import pytest

from conftest import CHAT_READY, NAME, transcript_file
from test_board_items_ui import wait_for
from test_chat_session_view_ui import (CODE, DESKTOP, MEASURE, PHONE, SIZES, TABLE, URL, WORD, check, drawer_open, open_page)
from test_chatkeep import assistant, human, peer, scenario, sala_line, strange, tool_result

OWNER = "Rowan"


def stamp(lines: list[dict], end_ms: int | None = None) -> list[dict]:
    """The lines with the clock of the last few seconds (the count is of today), in order."""
    end = (end_ms or int(time.time() * 1000)) - 1000
    out = []
    for i, d in enumerate(lines):
        d = json.loads(json.dumps(d))
        t = end - (len(lines) - i) * 5
        d["timestamp"] = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t / 1000)) + ".%03dZ" % (t % 1000)
        out.append(d)
    return out


def write(served, lines: list[dict]) -> None:
    transcript_file(served).write_text("".join(json.dumps(d) + "\n" for d in lines), encoding="utf-8")


def append(served, lines: list[dict]) -> None:
    with transcript_file(served).open("a", encoding="utf-8") as f:
        f.write("".join(json.dumps(d) + "\n" for d in stamp(lines)))


def open_real(browser, served, monkeypatch, size, **kw) -> None:
    monkeypatch.setenv("SALA_OWNER_NAME", OWNER)
    open_page(browser, served, monkeypatch, size, None, **kw)
    assert wait_for(browser, "!document.querySelector('#chat-strip').hidden && document.querySelector('#chat-strip .count') !== null", 15.0)


LINES = """(() => { const chat = document.querySelector('#chat'), shown = (n) => n.getClientRects().length > 0;
  const kept = [...chat.querySelectorAll(':scope > .msg.kept')];
  return { kept: kept.length, visible: kept.filter(shown).length, count: (document.querySelector('#chat-strip .count') || {}).textContent || '',
           on: document.body.classList.contains('chat-kept-on'), text: kept.map((n) => n.textContent.trim()),
           page: document.body.innerText,
           dom: chat.textContent + ' | ' + document.querySelector('#chat-strip').textContent + ' | ' + chat.innerHTML,
           sw: (() => { const s = document.querySelector('#chat-strip-kept'); return s ? { disabled: s.disabled, checked: s.checked } : null; })(),
           soon: document.querySelector('#chat-strip .kept-toggle').textContent.includes('not active') }; })()"""


def click_switch(browser) -> None:
    browser.evaluate("document.querySelector('#chat-strip-kept').click(); ''")


# ── the switch ───────────────────────────────────────────────────────────────
@pytest.mark.parametrize("size", SIZES)
def test_the_switch_shows_and_hides_the_kept_lines_and_its_count_is_the_number_of_lines(served, browser, monkeypatch, size):
    write(served, stamp(scenario()))
    open_real(browser, served, monkeypatch, size)
    assert wait_for(browser, "document.querySelectorAll('#chat > .msg.kept').length === 4", 10.0)
    s = browser.evaluate(LINES)
    assert s["sw"] == {"disabled": False, "checked": False} and not s["soon"] and not s["on"], s
    assert s["visible"] == 0 and "4 kept back today" in s["count"], s
    for gone in ("Checking.", "[for", "<!-- sala", "&lt;!-- sala", "sala -->"):
        assert gone not in s["dom"], gone       # in the page at all, hidden or not: a hidden turn's own lines are never sent, and no mark is drawn
    assert "What is due on Friday?" in s["page"] and "The deck is due at noon." in s["page"], "the owner's turns show"
    assert "Item 7 needs your answer today." in s["page"] and "Slide 4 is drawn." in s["page"], "a hidden turn for the owner shows its reply, the mark off"
    assert browser.evaluate("document.querySelectorAll('#chat details.tool').length") >= 1, "a turn the owner started streams whole: its tool call is there"
    click_switch(browser)
    assert wait_for(browser, "document.querySelectorAll('#chat > .msg.kept').length === 4 && [...document.querySelectorAll('#chat > .msg.kept')].every((n) => n.getClientRects().length)", 5.0)
    s = browser.evaluate(LINES)
    assert s["on"] and s["visible"] == 4 and s["sw"]["checked"], s
    assert str(s["visible"]) in s["count"].split()[0], "the count in the strip is the number of lines"
    joined = "\n".join(s["text"])
    for want in ("from chat-other", "The slides are drawn.", "Nothing for you; I filed it.", "from sala", "wake up", "Awake.", "from another session", "a line nobody knows", "Handled.",
                 "from chat-third", "Please review."):
        assert want in joined, (want, s["text"])
    assert "Checking." not in s["dom"] and "[for" not in s["dom"] and "<!-- sala" not in s["dom"]
    click_switch(browser)
    assert wait_for(browser, "document.querySelectorAll('#chat > .msg.kept').length === 4 && ![...document.querySelectorAll('#chat > .msg.kept')].some((n) => n.getClientRects().length)", 5.0)
    assert not browser.evaluate("document.body.classList.contains('chat-kept-on')")


@pytest.mark.parametrize("size", SIZES)
def test_a_hidden_turn_that_arrives_adds_a_line_and_the_count_and_its_reply_lands_on_the_same_line(served, browser, monkeypatch, size):
    write(served, stamp([human("hello", 1), assistant("hi", 2)]))
    open_real(browser, served, monkeypatch, size)
    click_switch(browser)
    assert wait_for(browser, "document.body.classList.contains('chat-kept-on') && document.querySelector('#chat-strip .count').textContent.startsWith('0 ')", 8.0)
    append(served, [peer("Another Claude session sent a message:\nfrom: chat-other\n\nBuild please.", 3), assistant("starting", 3, stop="tool_use", tool=True)])
    assert wait_for(browser, "document.querySelectorAll('#chat > .msg.kept').length === 1", 15.0)
    assert wait_for(browser, "document.querySelector('#chat-strip .count').textContent.startsWith('1 ')", 15.0)
    s = browser.evaluate(LINES)
    assert s["visible"] == 1 and "still working" in s["text"][0] and "Build please." in s["text"][0] and "starting" not in s["dom"], s
    append(served, [tool_result(4), assistant("Built.\nAll green.", 5)])
    assert wait_for(browser, "document.querySelector('#chat > .msg.kept') && document.querySelector('#chat > .msg.kept').textContent.includes('All green.')", 15.0)
    s = browser.evaluate(LINES)
    assert s["kept"] == 1 and "still working" not in s["text"][0], s
    append(served, [peer("Another Claude session sent a message:\nfrom: stackshot\n\nItem 7 changed.", 6)])
    assert wait_for(browser, "document.querySelectorAll('#chat > .msg.kept').length === 2", 15.0)
    append(served, [assistant("[for Rowan] Item 7 needs your answer.", 7)])
    assert wait_for(browser, "document.querySelectorAll('#chat > .msg.kept').length === 1 && document.body.innerText.includes('Item 7 needs your answer.')", 15.0)
    s = browser.evaluate(LINES)
    assert "[for" not in s["dom"] and s["kept"] == 1, s
    assert wait_for(browser, "document.querySelector('#chat-strip .count').textContent.startsWith('1 ')", 15.0), "the count follows the lines"


def test_the_owner_s_own_turn_streams_its_lines_as_they_arrive(served, browser, monkeypatch):
    write(served, stamp([human("first", 1), assistant("one", 2)]))
    open_real(browser, served, monkeypatch, DESKTOP)
    append(served, [human("start the redraw", 3), assistant("On it, drawing now.", 3, stop="tool_use", tool=True)])
    assert wait_for(browser, "document.body.innerText.includes('On it, drawing now.') && document.querySelectorAll('#chat details.tool').length >= 1", 15.0), \
        "the acknowledgement written before a tool call is on the page while the turn is still going"
    append(served, [tool_result(4), assistant("Redrawn.", 5)])
    assert wait_for(browser, "document.body.innerText.includes('Redrawn.')", 15.0)


# ── the page keeps what sala's view has ──────────────────────────────────────
def test_the_header_stays_when_the_thread_scrolls_and_there_is_one_composer(served, browser, monkeypatch):
    lines = []
    for i in range(40):
        lines += [human(f"question {i}", 1), assistant(("An answer that goes on. " * 30) + str(i), 2)]
    write(served, stamp(lines))
    open_real(browser, served, monkeypatch, DESKTOP)
    before = browser.evaluate("(() => { const r = document.querySelector('#top').getBoundingClientRect(); return [r.top, r.height]; })()")
    browser.evaluate("(() => { const p = document.querySelector('#chat-pane'); p.scrollTop = p.scrollHeight; window.scrollTo(0, 99999); return ''; })()")
    time.sleep(0.4)
    after = browser.evaluate("(() => { const r = document.querySelector('#top').getBoundingClientRect(), p = document.querySelector('#chat-pane');"
                             " return [r.top, r.height, p.scrollTop, document.scrollingElement.scrollTop]; })()")
    assert after[0] == before[0] and after[1] == before[1] > 0 and after[2] > 0 and after[3] == 0, (before, after)
    assert browser.evaluate("[document.querySelectorAll('#composer').length, document.querySelectorAll('#input').length, document.querySelectorAll('#attach-btn, #attach').length]")[:2] == [1, 1]


# ── no sideways scroll ───────────────────────────────────────────────────────
def hostile() -> list[dict]:
    reply = f"Here: {WORD}\n\n{URL}\n\n```\n{CODE}\n```\n\n{TABLE}\n`{'c' * 200}`\n"
    return [human(f"{WORD} {URL}", 1), assistant(reply, 2),
            peer(f"Another Claude session sent a message:\nfrom: {'n' * 60}\n\n{WORD} {URL}", 3),
            assistant(f"{WORD}\n{URL} {'d' * 200}", 4),
            sala_line(f"{WORD} {URL}", 5), assistant("w" * 400, 5),
            strange("x" * 300, 6), assistant(f"| {'y' * 200} |", 6),
            peer("Another Claude session sent a message:\nfrom: stackshot\n\nstill going", 7)]


KEPT_MEASURE = """(() => { const out = [];
  for (const n of document.querySelectorAll('#chat > .msg.kept, #chat > .msg.kept *')) {
    if (!n.getClientRects().length) continue;
    if (n.scrollWidth > n.clientWidth + 0.5 && n.matches('.msg.kept, .msg.kept > *')) out.push(n.className + ' ' + n.scrollWidth + '>' + n.clientWidth);
  }
  return out; })()"""


@pytest.mark.parametrize("width", [1280, 390, 360, 320])
@pytest.mark.parametrize("drawer", [False, True], ids=["drawer-shut", "drawer-open"])
@pytest.mark.parametrize("on", [False, True], ids=["switch-off", "switch-on"])
def test_no_sideways_scroll_with_the_switch_off_and_on_and_hostile_text_in_the_owner_s_turns_and_the_kept_lines(served, browser, monkeypatch, width, drawer, on):
    write(served, stamp(hostile()))
    open_real(browser, served, monkeypatch, (width, 800 if width > 700 else 844))
    assert wait_for(browser, "document.querySelectorAll('#chat > .msg.kept').length === 4", 10.0)
    if width < 700:
        browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 844, "deviceScaleFactor": 1, "mobile": True})
        assert wait_for(browser, f"document.documentElement.clientWidth === {width}", 10.0)
        if drawer:
            drawer_open(browser)
    if on:
        click_switch(browser)
        assert wait_for(browser, "[...document.querySelectorAll('#chat > .msg.kept')].every((n) => n.getClientRects().length)", 5.0)
    browser.settle("document.querySelector('#chat')")
    m = browser.evaluate(MEASURE)
    assert m["vw"] == width and m["msgs"] >= 4, m
    check(m, f"{width} px, drawer {'open' if drawer else 'shut'}, switch {'on' if on else 'off'}")
    assert browser.evaluate(KEPT_MEASURE) == [], "a kept line is never wider than the thread"
