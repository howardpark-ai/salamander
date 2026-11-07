"""A `!` shell command typed in the chat box: `! python3 /tmp/x.py` ran
once and its output showed, but a second bubble with the same text stayed at the bottom marked "Queued: not in the
transcript yet". Claude Code records a `!` input as a <bash-input> entry, which transcript.py turns into a "command"
block ("! <command>"), never a text block, so the pending bubble (matched against text blocks only) never merged and
flipped to "queued" after QUEUED_AFTER_MS. Checked here: the parser's block for a real <bash-input> record (its shape from
a real transcript: a plain user record, then a separate <bash-stdout> record), a pending `!` bubble merging with that
block (whitespace-normalised, the "!" with or without a space), a different command or an old one not merging, an
ordinary message still merging and still turning "queued", the `!` bubble never turning "queued" and offering no Retry,
and a `!` bubble not taken by the "first new prompt" fallback of an ordinary message.

The page parts run in a headless Chromium when one is installed (conftest.py: `served`, `browser`); without one they are
skipped. The send is stubbed in the page (the fake session has no pane), and the 60 s timer is captured and fired by hand.
"""

from __future__ import annotations

import json

from conftest import NAME, SID
from sala_web import transcript as TR
from test_composer_attach import WAIT_READY
from test_composer_editable import SPY_SEND, enter, typed

ARM = """(() => { window.__timers = []; const real = window.setTimeout;
  window.setTimeout = (f, ms, ...a) => { if (ms === QUEUED_AFTER_MS) { __timers.push(f); return 0; } return real(f, ms, ...a); };
  window.__fail = false; const f0 = window.fetch;
  window.fetch = (u, o) => { if (String(u).includes("/send") && window.__fail) return Promise.reject(new Error("network down")); return f0(u, o); };
  return true; })()"""
SETTLED = """new Promise((res) => { const t0 = Date.now(); (function poll() {
  if (!state.sending || Date.now() - t0 > 5000) res(!state.sending); else setTimeout(poll, 20); })(); })"""
BUBBLES = """[...document.querySelectorAll("#chat > .msg.local")].map((n) => ({ cls: n.className, text: n.querySelector(".bubble")?.textContent,
  note: n.querySelector(".note")?.textContent || "", buttons: [...n.querySelectorAll(".note-actions button")].map((b) => b.textContent) }))"""


def line(content, uuid="b-1", ts="2026-10-21T20:26:30.402Z") -> dict:
    return {"type": "user", "uuid": uuid, "timestamp": ts, "message": {"role": "user", "content": content}}


def opened(browser, served) -> None:
    browser.open(f"{served['url']}/#s={NAME}")
    assert browser.evaluate(WAIT_READY)
    assert browser.evaluate(SPY_SEND) == "input"
    assert browser.evaluate(ARM)


def send_text(browser, text: str) -> None:
    typed(browser, text)
    enter(browser)
    assert browser.evaluate(SETTLED)


def command_msg(text: str, ts: str | None = None) -> str:
    """renderMessage(...) for a user message holding one command block, as the stream delivers it (live)."""
    t = f", ts: {json.dumps(ts)}" if ts else ""
    return (f'renderMessage({{ role: "user", uuid: "bang-{abs(hash(text))}", blocks: [{{ kind: "command", text: {json.dumps(text)} }}]{t} }}, '
            "{ live: true })")


def test_a_bash_input_record_is_a_command_block():
    # the shape of a real record: a plain user record whose content is the tag, then a separate bash-stdout record
    m = TR.parse_line(line("<bash-input>python3 /tmp/x.py</bash-input>"), SID)
    assert m["blocks"] == [{"kind": "command", "text": "! python3 /tmp/x.py"}], m
    m = TR.parse_line(line("<bash-stdout>hello</bash-stdout><bash-stderr></bash-stderr>", uuid="b-2"), SID)
    assert [b["kind"] for b in m["blocks"]] == ["bang_output"] and m["blocks"][0]["label"] == "command output", m


def test_a_bang_bubble_merges_with_its_command_entry(served, browser):
    opened(browser, served)
    send_text(browser, "!  python3   /tmp/x.py ")
    assert browser.evaluate(BUBBLES + ".length") == 1
    # the transcript's entry has the command with one space after the "!" and single spaces: the same command
    browser.evaluate(command_msg("! python3 /tmp/x.py"))
    assert browser.evaluate("state.pending.length") == 0
    got = browser.evaluate(BUBBLES)
    assert got == [], got  # the pending bubble is gone; the real entry is the one command line
    assert browser.evaluate("[...document.querySelectorAll('#chat .msg.user .cmd')].map((n) => n.textContent)") == ["! python3 /tmp/x.py"]
    # the timer, had it run after the merge, does nothing
    browser.evaluate("__timers.forEach((f) => f())")
    assert browser.evaluate(BUBBLES) == []


def test_another_command_or_an_old_entry_does_not_merge(served, browser):
    opened(browser, served)
    send_text(browser, "! python3 /tmp/x.py")
    browser.evaluate(command_msg("! python3 /tmp/other.py"))
    assert browser.evaluate("state.pending.length") == 1
    # an entry from before the send (more than 2 minutes older) is an older run of the same command
    browser.evaluate(command_msg("! python3 /tmp/x.py", ts="2020-01-01T00:00:00.000Z"))
    assert browser.evaluate("state.pending.length") == 1
    # a slash command is not a shell command and merges with nothing here
    browser.evaluate(command_msg("/model opus"))
    assert browser.evaluate("state.pending.length") == 1


def test_a_bang_bubble_never_turns_queued_and_offers_no_retry(served, browser):
    opened(browser, served)
    send_text(browser, "! python3 /tmp/x.py")
    assert browser.evaluate("__timers.length") == 1
    browser.evaluate("__timers.forEach((f) => f())")
    got = browser.evaluate(BUBBLES)
    assert len(got) == 1 and "queued" not in got[0]["cls"] and "Queued" not in got[0]["note"], got
    assert "not sent twice" in got[0]["note"] and got[0]["buttons"] == [], got
    assert browser.evaluate("state.pending[0].status") == "sent"


def test_a_failed_bang_send_offers_edit_but_no_retry(served, browser):
    opened(browser, served)
    browser.evaluate("window.__fail = true")
    send_text(browser, "! rm /tmp/x")
    got = browser.evaluate(BUBBLES)
    assert len(got) == 1 and "failed" in got[0]["cls"] and got[0]["buttons"] == ["Edit"], got


def test_an_ordinary_message_still_merges_and_still_turns_queued(served, browser):
    opened(browser, served)
    send_text(browser, "hello there")
    browser.evaluate("__timers.forEach((f) => f())")
    got = browser.evaluate(BUBBLES)
    assert len(got) == 1 and "queued" in got[0]["cls"] and "Queued: not in the transcript yet" in got[0]["note"], got
    browser.evaluate('renderMessage({ role: "user", uuid: "o-1", blocks: [{ kind: "text", text: "hello  there" }] }, { live: true })')
    assert browser.evaluate("state.pending.length") == 0 and browser.evaluate(BUBBLES) == []
    # a failed ordinary message keeps its Retry
    browser.evaluate("window.__fail = true")
    send_text(browser, "again")
    assert browser.evaluate(BUBBLES)[0]["buttons"] == ["Retry", "Edit"]


def test_the_fallback_does_not_take_a_bang_bubble(served, browser):
    opened(browser, served)
    send_text(browser, "! sleep 1")
    # a live ordinary prompt whose text matches no pending bubble would take the oldest one; not a shell command's
    browser.evaluate('renderMessage({ role: "user", uuid: "o-2", blocks: [{ kind: "text", text: "something else" }] }, { live: true })')
    assert browser.evaluate("state.pending.length") == 1
