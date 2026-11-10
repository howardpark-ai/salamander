"""A finished create empties the name field of the New session and Quick session pages, so neither calls its own new session a clash.

After a successful Create (or Start) the new session reaches the sessions list the page keeps while the name field still held
its name, and the name check answered "A session called <name> is running already. Pick another name." for the session the page
itself had queued, which reads as a clash. Now a create that is queued empties the name field (the result line and the Open
button stay as they are): with no name there is nothing to warn about and the button is off. A failed create keeps the typed name
so the person can retry. Nothing refills the field on its own afterwards: a reload of the project list, which suggests a name
when the field is empty, skips it until the person picks a project, changes the role or types in the box again.

What a wrong answer costs: a warning under the name of a session that started fine (the person thinks it failed or that a second
one exists and starts it again), a field that fills itself again with another name next to the finished result (a second click
queues a second session nobody asked for), a name lost after a refusal (the retry starts from nothing), or a fix that switches
the running-already warning off for every name. Every check guards one of those.

Held here, in a headless Chromium, through each page's own submit against the stand-in sala of test_new_session.py:
- New session: Create, the operation running, the session in the list, the Ready link shown; then the name field and its error
  text are empty, the result line and the Open link are still there and Create is off; a reload of the project list leaves the
  field empty; typing the name of another running session shows the running-already warning and keeps Create off; a fresh name
  enables Create;
- New session, a refused create: the typed name stays, the refusal is shown, Create can be pressed again;
- the same two for Quick session, with Start and its own wording (a blank name is valid there, sala suggests one, so Start stays
  available for another quick session; the checks are that the field and its error text are empty and the result stays).
Not held: what the page does when the session list never shows the name (test_new_session.py, a spawn that ends without the
session)."""

from __future__ import annotations

import json

from test_board_items_ui import wait_for
from test_new_session import FAKE, click, ns, open_form, open_page, pick, set_value, wait_state  # noqa: F401
from test_new_session import env, sala  # noqa: F401  (fixtures)

OTHER = "demo-other-running"     # a second running session: it is in the page's list once the test says so


def test_new_session_empties_the_name_after_a_create_and_warns_for_another_running_name(sala, served, browser):
    open_form(browser, served)
    pick(browser, "projects/gamma-harbor")
    assert wait_for(browser, "document.querySelector('#ns-name').value === 'gamma-harbor-pink'")
    click(browser, "#ns-submit")
    wait_state(browser, "gamma-harbor-pink: queued")
    sala.marker("running")
    browser.evaluate("window.__names = ['gamma-harbor-pink', " + json.dumps(OTHER) + "]; loadSessions(); ''")
    g = wait_state(browser, "gamma-harbor-pink: ready")
    assert browser.evaluate("state.byName.has('gamma-harbor-pink') && state.byName.has(" + json.dumps(OTHER) + ")")   # the session is in the list
    # the finished page: the field is empty, no error text, the result line and the Open link stay, nothing to press
    assert g["name"] == "" and g["nameErr"] == "" and g["submitDisabled"], g
    assert g["state"] == "gamma-harbor-pink: Ready" and g["link"] == "#s=gamma-harbor-pink" and "Open" in g["status"], g
    assert len(sala.spawns()) == 1
    # the list is read again (as it is when the page is shown again): it does not put a suggestion into the field
    browser.evaluate("nsLoadProjects().then(() => '')")
    assert browser.evaluate("new Promise((ok) => setTimeout(() => ok(document.querySelector('#ns-name').value), 1000))") == ""
    click(browser, "#ns-submit")
    assert len(sala.spawns()) == 1
    # another running session's name is a real clash and says so
    set_value(browser, "#ns-name", OTHER)
    g = ns(browser)
    assert g["nameErr"] == f"A session called {OTHER} is running already. Pick another name." and g["submitDisabled"], g
    set_value(browser, "#ns-name", "gamma-harbor-fresh")
    g = ns(browser)
    assert g["nameErr"] == "" and not g["submitDisabled"], g
    assert g["state"] == "gamma-harbor-pink: Ready" and g["link"] == "#s=gamma-harbor-pink", g       # the result stays while a new name is typed


def test_new_session_has_an_empty_name_from_the_moment_the_create_is_queued(sala, served, browser):
    """The session lands in the list after this (starting, then ready): the field is empty throughout, so nothing is warned."""
    open_form(browser, served)
    pick(browser, "projects/gamma-harbor")
    assert wait_for(browser, "document.querySelector('#ns-name').value === 'gamma-harbor-pink'")
    click(browser, "#ns-submit")
    g = wait_state(browser, "gamma-harbor-pink: queued")
    assert g["name"] == "" and g["nameErr"] == "" and g["submitDisabled"], g
    sala.marker("running")
    wait_state(browser, "gamma-harbor-pink: starting")
    browser.evaluate("window.__names = ['gamma-harbor-pink']; loadSessions(); ''")
    assert wait_for(browser, "state.byName.has('gamma-harbor-pink')", 10.0)
    g = wait_state(browser, "gamma-harbor-pink: ready")
    assert g["name"] == "" and g["nameErr"] == "" and g["submitDisabled"], g


def test_new_session_keeps_the_typed_name_when_the_create_is_refused(sala, served, browser):
    sala.mode("refuse")
    open_form(browser, served)
    pick(browser, "projects/gamma-harbor")
    assert wait_for(browser, "document.querySelector('#ns-name').value === 'gamma-harbor-pink'")
    set_value(browser, "#ns-name", "gamma-harbor-mine")
    click(browser, "#ns-submit")
    assert wait_for(browser, "(document.querySelector('#ns-status pre') || {}).textContent?.includes('refused')", 10.0), ns(browser)
    g = ns(browser)
    assert g["name"] == "gamma-harbor-mine" and g["nameErr"] == "" and not g["submitDisabled"], g       # the retry starts from the same name
    sala.mode("ok")
    click(browser, "#ns-submit")
    g = wait_state(browser, "gamma-harbor-mine: queued")
    assert g["name"] == "" and g["submitDisabled"], g
    assert [(r["argv"][2], r["mode"]) for r in sala.spawns()] == [("gamma-harbor-mine", "refuse"), ("gamma-harbor-mine", "ok")]   # the same name, asked twice


QUICK = """(() => { const q = (s) => document.querySelector(s);
  return { name: q("#sd-name").value, err: q("#sd-name-err").textContent, disabled: q("#sd-submit").disabled,
           state: (q("#sd-status .ns-state") || {}).textContent || "", status: q("#sd-status").innerText,
           link: q("#sd-status a.ns-link") ? q("#sd-status a.ns-link").getAttribute("href") : null }; })()"""


def open_quick(browser, served) -> str:
    open_page(browser, served, 1280, 800)
    browser.evaluate(f"location.hash = {json.dumps('#side=from:' + FAKE)}; ''")
    name = f"{FAKE}-side-wren42"
    assert wait_for(browser, f"document.querySelector('#sd-name').value === {json.dumps(name)} && !document.querySelector('#sd-submit').disabled", 10.0)
    return name


def test_quick_session_empties_the_name_after_a_start_and_warns_for_another_running_name(sala, served, browser):
    name = open_quick(browser, served)
    click(browser, "#sd-submit")
    assert wait_for(browser, "(document.querySelector('#sd-status .ns-state') || {}).textContent?.includes('Queued')", 10.0)
    sala.marker("running")
    other = "demo-side-other1"
    browser.evaluate("window.__names = [" + json.dumps(name) + ", " + json.dumps(other) + "]; loadSessions(); ''")
    assert wait_for(browser, "(document.querySelector('#sd-status .ns-state') || {}).textContent?.endsWith('Ready')", 15.0), browser.evaluate(QUICK)
    g = browser.evaluate(QUICK)
    assert g["name"] == "" and g["err"] == "", g       # a blank name is allowed on this form (sala suggests one), so Start stays available for a new quick session
    assert g["state"] == f"{name}: Ready" and g["link"] == "#s=" + name and "Open" in g["status"], g
    assert len(sala.spawns()) == 1
    set_value(browser, "#sd-name", other)
    g = browser.evaluate(QUICK)
    assert g["err"] == f"A session called {other} is running already. Pick another name, or leave it blank." and g["disabled"], g
    set_value(browser, "#sd-name", "demo-side-fresh2")
    g = browser.evaluate(QUICK)
    assert g["err"] == "" and not g["disabled"] and g["link"] == "#s=" + name, g
    assert len(sala.spawns()) == 1


def test_quick_session_keeps_the_typed_name_when_the_start_is_refused(sala, served, browser):
    open_quick(browser, served)
    sala.mode("refuse")
    set_value(browser, "#sd-name", "demo-side-mine1")
    click(browser, "#sd-submit")
    assert wait_for(browser, "(document.querySelector('#sd-status .ns-state') || {}).textContent === 'Not started'", 10.0), browser.evaluate(QUICK)
    g = browser.evaluate(QUICK)
    assert g["name"] == "demo-side-mine1" and g["err"] == "" and not g["disabled"], g
