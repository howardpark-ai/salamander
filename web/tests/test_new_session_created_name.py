"""The New session and Quick session pages never call the session they just created a clash.

After a successful Create (or Start) the new session reaches the sessions list the page keeps, and the name field still holds
its name. The name check used to run again at that point and answered "A session called <name> is running already. Pick
another name." for the session the page itself had queued, which reads as a clash. Now the page remembers the name it
queued (`ns.created`, `sd.created`): that exact name shows no error text and Create (Start) stays disabled, so it cannot be
sent twice; the first edit of the name drops the memory and the ordinary checks apply again.

What a wrong answer costs: a warning under the name of a session that started fine (the person thinks it failed or that
a second one exists and starts it again), or the opposite fix that leaves Create enabled and queues the same name twice, or one
that switches the running-already warning off for every name. Every check guards one of those.

Held here, in a headless Chromium, through each page's own submit against the stand-in sala of test_new_session.py:
- New session: Create, the operation running, the session in the list, the Ready link shown; then the name error text is empty
  and Create is disabled; typing the name of another running session shows the running-already warning and keeps Create disabled;
  typing a fresh name enables Create and clears the text;
- the same for Quick session, with Start.
Not held: what the page does when the session list never shows the name (test_new_session.py, a spawn that ends without the
session), and a second Create of the same name after the first session has ended (the name has to be edited first)."""

from __future__ import annotations

import json

from test_board_items_ui import wait_for
from test_new_session import FAKE, click, ns, open_form, open_page, pick, set_value, wait_state  # noqa: F401
from test_new_session import env, sala  # noqa: F401  (fixtures)

OTHER = "demo-other-running"     # a second running session: it is in the page's list from the start of the test


def add_running(browser, *names: str) -> None:
    browser.evaluate(f"window.__names.push(...{json.dumps(list(names))}); loadSessions(); ''")
    for n in names:
        assert wait_for(browser, f"state.byName.has({json.dumps(n)})", 10.0), n


def test_new_session_does_not_call_its_own_new_session_a_clash(sala, served, browser):
    open_form(browser, served)
    pick(browser, "projects/gamma-harbor")
    assert wait_for(browser, "document.querySelector('#ns-name').value === 'gamma-harbor-pink'")
    click(browser, "#ns-submit")
    wait_state(browser, "gamma-harbor-pink: queued")
    sala.marker("running")
    browser.evaluate("window.__names = ['gamma-harbor-pink', " + json.dumps(OTHER) + "]; loadSessions(); ''")
    g = wait_state(browser, "gamma-harbor-pink: ready")
    assert g["link"] == "#s=gamma-harbor-pink", g
    assert browser.evaluate("state.byName.has('gamma-harbor-pink') && state.byName.has(" + json.dumps(OTHER) + ")")   # the session is in the list
    # the finished page: no error text for the name the page created, and it cannot be submitted again
    g = ns(browser)
    assert g["name"] == "gamma-harbor-pink" and g["nameErr"] == "" and g["submitDisabled"], g
    assert len(sala.spawns()) == 1
    # a click on the disabled button queues nothing
    click(browser, "#ns-submit")
    assert len(sala.spawns()) == 1
    # editing the name: another running session's name is a real clash and says so
    set_value(browser, "#ns-name", OTHER)
    g = ns(browser)
    assert g["nameErr"] == f"A session called {OTHER} is running already. Pick another name." and g["submitDisabled"], g
    # a fresh name: the ordinary checks pass, Create is enabled
    set_value(browser, "#ns-name", "gamma-harbor-fresh")
    g = ns(browser)
    assert g["nameErr"] == "" and not g["submitDisabled"], g
    # typing the created name again is an edit like any other: the running-already warning applies to it now
    set_value(browser, "#ns-name", "gamma-harbor-pink")
    g = ns(browser)
    assert "is running already" in g["nameErr"] and g["submitDisabled"], g
    assert len(sala.spawns()) == 1


def test_new_session_shows_no_warning_for_its_own_name_while_it_starts(sala, served, browser):
    """The moment the session reaches the list (before the status reads Ready) is the one the warning used to show in."""
    open_form(browser, served)
    pick(browser, "projects/gamma-harbor")
    assert wait_for(browser, "document.querySelector('#ns-name').value === 'gamma-harbor-pink'")
    click(browser, "#ns-submit")
    wait_state(browser, "gamma-harbor-pink: queued")
    sala.marker("running")
    wait_state(browser, "gamma-harbor-pink: starting")
    assert ns(browser)["nameErr"] == ""
    add_running(browser, "gamma-harbor-pink")
    wait_state(browser, "gamma-harbor-pink: ready")
    g = ns(browser)
    assert g["nameErr"] == "" and g["submitDisabled"], g


QUICK = """(() => { const q = (s) => document.querySelector(s);
  return { name: q("#sd-name").value, err: q("#sd-name-err").textContent, disabled: q("#sd-submit").disabled,
           state: (q("#sd-status .ns-state") || {}).textContent || "", link: q("#sd-status a.ns-link") ? q("#sd-status a.ns-link").getAttribute("href") : null }; })()"""


def test_quick_session_does_not_call_its_own_new_session_a_clash(sala, served, browser):
    open_page(browser, served, 1280, 800)
    browser.evaluate(f"location.hash = {json.dumps('#side=from:' + FAKE)}; ''")
    name = f"{FAKE}-side-wren42"
    assert wait_for(browser, f"document.querySelector('#sd-name').value === {json.dumps(name)} && !document.querySelector('#sd-submit').disabled", 10.0)
    click(browser, "#sd-submit")
    assert wait_for(browser, "(document.querySelector('#sd-status .ns-state') || {}).textContent?.includes('Queued')", 10.0)
    sala.marker("running")
    other = "demo-side-other1"
    browser.evaluate("window.__names = [" + json.dumps(name) + ", " + json.dumps(other) + "]; loadSessions(); ''")
    assert wait_for(browser, "(document.querySelector('#sd-status .ns-state') || {}).textContent?.endsWith('Ready')", 15.0), browser.evaluate(QUICK)
    g = browser.evaluate(QUICK)
    assert g["name"] == name and g["err"] == "" and g["disabled"] and g["link"] == "#s=" + name, g
    assert len(sala.spawns()) == 1
    set_value(browser, "#sd-name", other)
    g = browser.evaluate(QUICK)
    assert g["err"] == f"A session called {other} is running already. Pick another name, or leave it blank." and g["disabled"], g
    set_value(browser, "#sd-name", "demo-side-fresh2")
    g = browser.evaluate(QUICK)
    assert g["err"] == "" and not g["disabled"], g
    set_value(browser, "#sd-name", name)
    g = browser.evaluate(QUICK)
    assert "is running already" in g["err"] and g["disabled"], g
    assert len(sala.spawns()) == 1
