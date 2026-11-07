"""What a started session shows while it comes up (on the Quick session form the button said the
creation was queued and after some time offered the link, with no sign of what was going on or what to expect). Both forms, New session and Quick session, show the same:

  · Start's button is disabled and says "Starting…" from the press until the session is ready or has failed, then the idle label
    comes back; a second press cannot send a second spawn;
  · a line of steps, Queued, Starting the session, Ready, with the current one named in words and aria-current="step"
    (never a colour alone), following the queue's marker (queued, running) and the sessions list (the name appears);
  · the seconds so far, with what a start usually takes (sala's own records of its spawns: 27 to 65 seconds, three of eleven
    over two minutes when other operations were queued ahead);
  · the operation id in small text after the message, not as the headline;
  · a failure in plain words with what to try, and the queue's result line below in small text;
  · at Ready, the Open link is a primary-styled button, larger than the text around it, with the focus, so Enter opens it.

What a wrong answer costs: a person who presses Start twice, or who watches a line that says "queued" for a minute and does not know
whether anything happens. Nothing here runs sala (the stand-in of test_new_session.py); the marker the queue would write is the
test's `sala.marker`, and the session list is the page's stub (`window.__names`)."""

from __future__ import annotations

import json
import re

import pytest

from test_board_items_ui import wait_for
from test_composer_editable import key
from test_new_session import OP, click, ns, open_form, pick
from test_new_session import env, sala  # noqa: F401  (fixtures)
from test_side_sessions import form, open_hash, settle  # noqa: F401

NAME_NS = "gamma-harbor-pink"
NAME_SD = "demo-side-wren42"

# everything the tests read of one form's status, by the id prefix of the form (ns or sd)
SNAP = r"""((p) => {
  const q = (s) => document.querySelector(s), st = q("#" + p + "-status"), btn = q("#" + p + "-submit"), t = (e) => (e ? e.textContent : null);
  const fs = (e) => (e ? parseFloat(getComputedStyle(e).fontSize) : null), bg = (e) => (e ? getComputedStyle(e).backgroundColor : null);
  const open = st.querySelector("a.ns-open"), at = document.activeElement;
  // the primary fill as the stylesheet defines it: an enabled .ns-submit button (the form's own Start button is disabled at Ready, and a disabled one is a flat grey in the dark theme)
  const primaryBg = () => { const b = document.createElement("button"); b.className = "ns-submit"; b.style.display = "none"; document.body.appendChild(b); const c = bg(b); b.remove(); return c; };
  return { state: t(st.querySelector(".ns-state")), btnDisabled: btn.disabled, btnText: btn.textContent, btnBusy: btn.getAttribute("aria-busy"),
    progress: [...st.querySelectorAll(".ns-progress .ns-prog")].map((li) => ({ label: t(li.querySelector(".ns-prog-label")), word: t(li.querySelector(".ns-prog-state")), current: li.getAttribute("aria-current") })),
    elapsed: t(st.querySelector(".ns-elapsed")), op: t(st.querySelector(".ns-op")), opSize: fs(st.querySelector(".ns-op")), stateSize: fs(st.querySelector(".ns-state")),
    text: st.innerText, result: t(st.querySelector(".ns-result")), resultSize: fs(st.querySelector(".ns-result")),
    open: open ? { href: open.getAttribute("href"), size: fs(open), bg: bg(open), h: open.getBoundingClientRect().height, tag: open.tagName, focused: at === open } : null,
    primaryBg: primaryBg(), btnSize: fs(btn), btnH: btn.getBoundingClientRect().height, hash: location.hash };
})"""

FORMS = {
    "ns": {"name": NAME_NS, "idle": "Create session"},
    "sd": {"name": NAME_SD, "idle": "Start quick session"},
}


def snap(browser, p: str) -> dict:
    return browser.evaluate(f"({SNAP})({json.dumps(p)})")


def wait_head(browser, p: str, head: str, timeout: float = 15.0) -> dict:
    cond = f"((document.querySelector('#{p}-status .ns-state') || {{}}).textContent || '').endsWith({json.dumps(': ' + head)})"
    assert wait_for(browser, cond, timeout), snap(browser, p)
    return snap(browser, p)


def start(browser, served, p: str) -> None:
    """Open the form as a person would and press Start on its default session."""
    if p == "ns":
        open_form(browser, served)
        pick(browser, "projects/gamma-harbor")
        assert wait_for(browser, f"document.querySelector('#ns-name').value === '{NAME_NS}'"), ns(browser)
    else:
        open_hash(browser, served, "#side=board#38")
        settle(browser, "document.querySelector('#sd-project').value !== '' && !document.querySelector('#sd-submit').disabled")
    click(browser, f"#{p}-submit")


def current(g: dict) -> list[str]:
    return [s["label"] for s in g["progress"] if s["current"] == "step"]


@pytest.mark.parametrize("p", ["ns", "sd"])
def test_start_works_until_the_session_is_ready_or_has_failed(sala, served, browser, p):
    start(browser, served, p)
    g = wait_head(browser, p, "Queued")
    assert g["btnDisabled"] and g["btnText"] == "Starting…" and g["btnBusy"] == "true", g   # working, from the press on
    browser.evaluate(f"document.querySelector('#{p}-submit').click(); document.querySelector('#{p}-form').requestSubmit(); ''")   # no second spawn
    sala.marker("stuck", "the lane cannot launch: max is signed out", done=True)
    g = wait_head(browser, p, "Did not start")
    assert not g["btnDisabled"] and g["btnText"] == FORMS[p]["idle"] and g["btnBusy"] == "false", g   # usable again for a retry
    assert len(sala.spawns()) == 1, sala.spawns()


@pytest.mark.parametrize("p", ["ns", "sd"])
def test_the_line_of_steps_follows_the_queue_and_the_sessions_list(sala, served, browser, p):
    start(browser, served, p)
    g = wait_head(browser, p, "Queued")
    assert [s["label"] for s in g["progress"]] == ["Queued", "Starting the session", "Ready"], g
    assert current(g) == ["Queued"] and [s["word"] for s in g["progress"]] == ["now", "next", "next"], g   # the current one in words, not a colour alone
    sala.marker("running")   # the queue's watch started the operation
    g = wait_head(browser, p, "Starting the session")
    assert current(g) == ["Starting the session"] and [s["word"] for s in g["progress"]] == ["done", "now", "next"], g
    assert g["open"] is None, g
    browser.evaluate(f"window.__names = ['{FORMS[p]['name']}']; ''")   # the name appears in the sessions list
    g = wait_head(browser, p, "Ready")
    assert current(g) == ["Ready"] and [s["word"] for s in g["progress"]] == ["done", "done", "done"], g
    assert g["btnBusy"] == "false" and g["btnText"] == FORMS[p]["idle"], g   # no longer working (the name field now holds a running session's name, which the form refuses as before)
    assert "Loading the conversation" not in g["text"]   # the sessions list has no sign of that step, so none is shown


@pytest.mark.parametrize("p", ["ns", "sd"])
def test_the_seconds_so_far_count_up_with_what_a_start_usually_takes(sala, served, browser, p):
    start(browser, served, p)
    g = wait_head(browser, p, "Queued")
    m = re.match(r"(\d+) s so far\. Usually 30 seconds to a minute", g["elapsed"] or "")
    assert m, g
    first = int(m.group(1))
    assert wait_for(browser, f"+((document.querySelector('#{p}-status .ns-elapsed') || {{}}).textContent || '0').split(' ')[0] >= {first + 2}", 8.0), snap(browser, p)
    browser.evaluate(f"window.__names = ['{FORMS[p]['name']}']; ''")
    g = wait_head(browser, p, "Ready")
    assert re.fullmatch(r"Took \d+ s\.", g["elapsed"] or ""), g   # what it took, once it is ready


@pytest.mark.parametrize("p", ["ns", "sd"])
def test_the_operation_id_is_small_text_after_the_message_not_the_headline(sala, served, browser, p):
    start(browser, served, p)
    g = wait_head(browser, p, "Queued")
    assert g["op"] == f"Operation {OP}" and OP not in g["state"] and "Queued as op" not in g["text"], g
    assert g["opSize"] < g["stateSize"] and g["opSize"] <= 12, g
    assert g["text"].index("sala has the request") < g["text"].index(f"Operation {OP}"), g["text"]


@pytest.mark.parametrize("p", ["ns", "sd"])
def test_a_failure_says_what_failed_and_what_to_try_in_plain_words(sala, served, browser, p):
    start(browser, served, p)
    wait_head(browser, p, "Queued")
    sala.marker("stuck", "the lane cannot launch: max is signed out", done=True)
    g = wait_head(browser, p, "Did not start")
    assert "The session did not start. Try again; if it fails twice, tell help-session." in g["text"]   # conftest's SALA_HELP_SESSION, g
    assert g["result"] and "stuck: the lane cannot launch: max is signed out" in g["result"] and g["resultSize"] < g["stateSize"], g   # the technical line, small, below
    assert g["text"].index("The session did not start") < g["text"].index("Result: stuck"), g["text"]
    assert [s["word"] for s in g["progress"]] == ["stopped here", "not reached", "not reached"] and current(g) == ["Queued"], g
    assert g["open"] is None


@pytest.mark.parametrize("p", ["ns", "sd"])
def test_at_ready_open_is_the_primary_button_with_the_focus(sala, served, browser, p):
    start(browser, served, p)
    wait_head(browser, p, "Queued")
    browser.evaluate(f"window.__names = ['{FORMS[p]['name']}']; ''")
    g = wait_head(browser, p, "Ready")
    o = g["open"]
    assert o and o["tag"] == "A" and o["href"] == "#s=" + FORMS[p]["name"], g
    assert o["bg"] == g["primaryBg"], g                               # the primary style: the enabled primary button's fill (the disabled Start is grey)
    assert o["size"] > g["stateSize"] and o["size"] > g["btnSize"] and o["h"] >= 44, g   # larger than the text around it
    assert o["focused"], g                                            # so Enter opens it
    key(browser, "Enter", "Enter", 13, "\r")
    assert wait_for(browser, f"location.hash === '#s={FORMS[p]['name']}'", 5.0), snap(browser, p)
