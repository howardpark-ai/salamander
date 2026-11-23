"""The side panel's "Show sleeping sessions" box: sleeping sessions are left out of the list unless it is checked.

A session sala put to sleep stays in the registry of the page, so the list that shows every agent of a project grew a row for each one
that nobody is working with. The box under the list (`#show-sleeping`, beside "Show all sessions", the same markup and a pref kept by the
server like it: `showSleeping`, off by default) leaves them out; checked, they come back in their usual places, marked sleeping. The open
session never leaves the list, and neither does the project it sits in while it is open; a project whose sessions all sleep leaves the list
with them. The Overview is not the side panel: it lists every session whatever the box says.

What a wrong answer costs: a sleeper the owner cannot find to wake (the box ignored, or the Overview dropping it too), the session he is
looking at vanishing from under him when it is a sleeper, an empty project heading left in the list, a choice that is forgotten on
reload or is not the same on the phone and the desktop. The list is drawn by a headless Chromium over `/`: from a stub of api/sessions
for the projects (an all-sleeping one included), and from the app's own server for the Overview and the saved choice. api/prefs is the app's own."""

from __future__ import annotations

import json
import shutil
import subprocess
import time
import urllib.error
import urllib.request

import pytest

from sala_web.app import STATIC
from test_board_items_ui import wait_for
from test_sleeping_sessions import NAME, SIDEBAR_ROW, Wake, no_tmux_names, open_page, slept, wake  # noqa: F401 (fixtures)
from test_unread_filter import get_prefs, put_prefs, show_panel

SLEEP_AT = "2026-11-22T06:10:00Z"
# alpha: two awake, one asleep; beta: every session asleep; gamma: one awake, one asleep (beside a background agent)
STUB = """(() => {
  const real = window.fetch.bind(window), json = (o) => new Response(JSON.stringify(o), { headers: { "Content-Type": "application/json" } });
  const sess = (n, role) => ({ pid: n.includes("-nap") ? 0 : 1, sessionId: n, name: n, cwd: "/x", status: n.includes("-nap") ? "sleeping" : "idle",
    tmux: "x:@0.%%0", tmuxSession: n, paneId: "%%0", role, project: "", lane: "subscription-1", updatedAt: null, startedAt: null, agentId: "agent-" + n,
    unread_count: 0, unread: false, ...(n.includes("-nap") ? { sleeping: "%(at)s" } : {}) });
  const proj = (key, names) => ({ key: "projects/" + key, title: key, scope: "example", sessions: names.map((n) => sess(n, n.endsWith("-engineer") ? "back" : "front")) });
  window.fetch = (url, opts) => {
    const u = String(url);
    if (u.startsWith("api/sessions")) {
      const groups = [proj("alpha", ["example-alpha-main", "example-alpha-nap", "example-alpha-ui"]), proj("beta", ["example-beta-nap", "example-beta-nap2"]),
                      proj("gamma", ["example-gamma-engineer", "example-gamma-main", "example-gamma-nap"])];
      return Promise.resolve(json({ scopes: [{ key: "example", title: "example", groups }], groups, rolesError: null }));
    }
    if (u.startsWith("api/board-items")) return Promise.resolve(json({ sessions: {}, fetchedAt: Date.now() }));
    return real(url, opts);
  };
})();""" % {"at": SLEEP_AT}
ROWS = "[...document.querySelectorAll('#session-list .sess')].map((r) => r.dataset.key)"
HEADS = "[...document.querySelectorAll('#session-list .group-title')].map((h) => h.dataset.ckey)"
BOX = "(() => { const b = document.querySelector('#show-sleeping'); return b ? b.checked : null; })()"
AWAKE = ["example-alpha-main", "example-alpha-ui", "example-gamma-main"]
ASLEEP = ["example-alpha-nap", "example-beta-nap", "example-beta-nap2", "example-gamma-nap"]
EVERYONE = ["example-alpha-main", "example-alpha-nap", "example-alpha-ui", "example-beta-nap", "example-beta-nap2", "example-gamma-main", "example-gamma-nap"]


def open_stub(browser, served, hash_="") -> None:
    """The page with the side panel open on a desktop, drawn from the stub."""
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": STUB})
    browser.width, browser.height = 1280, 800
    browser.send("Emulation.setDeviceMetricsOverride", {"width": 1280, "height": 800, "deviceScaleFactor": 1, "mobile": False})
    browser.send("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-color-scheme", "value": "dark"}]})
    browser.send("Page.navigate", {"url": f"{served['url']}/{hash_}"})
    browser.wait_ready()
    show_panel(browser)


def wait_rows(browser, want: list, secs: float = 6.0) -> list:
    assert wait_for(browser, f"JSON.stringify({ROWS}) === {json.dumps(json.dumps(want, separators=(',', ':')))}", secs), browser.evaluate(ROWS)
    return browser.evaluate(ROWS)


def tick(browser) -> None:
    browser.evaluate("document.querySelector('#show-sleeping').click(); ''")


def saved(served, want: bool) -> None:
    """The save is asynchronous: wait until the server holds `want`."""
    for _ in range(50):
        if get_prefs(served)["showSleeping"] is want:
            return
        time.sleep(0.1)
    assert get_prefs(served)["showSleeping"] is want


# ── the rule, in node ────────────────────────────────────────────────────────
NODE = r"""
const fs = require('fs');
const text = fs.readFileSync(process.argv[1], 'utf8');
const m = /\/\/ <sleeping-words>[^\n]*\n([\s\S]*?)\/\/ <\/sleeping-words>/.exec(text);
eval(m[1] + 'globalThis.api = { sleepersKept };');
const { sleepersKept } = globalThis.api;
const live = (name) => ({ name, status: 'idle', pid: 1 }), nap = (name, at) => ({ name, status: 'sleeping', pid: 0, sleeping: at === undefined ? '2026-11-22T06:10:00Z' : at });
const project = [live('a'), nap('b'), live('c'), nap('d', '')];             // a sleeper's key may be an empty word: it is still a sleeper
const names = (l) => l.map((s) => s.name);
console.log(JSON.stringify({
  off: names(sleepersKept(project, null, false)),
  offOpenSleeper: names(sleepersKept(project, 'b', false)),
  offOpenAwake: names(sleepersKept(project, 'a', false)),
  offOpenOther: names(sleepersKept(project, 'zzz', false)),
  on: names(sleepersKept(project, null, true)),
  onOpen: names(sleepersKept(project, 'b', true)),
  onlySleepers: names(sleepersKept([nap('x'), nap('y')], null, false)),
  onlySleepersOpen: names(sleepersKept([nap('x'), nap('y')], 'y', false)),
  empty: names(sleepersKept([], null, false)),
  undefinedBox: names(sleepersKept(project, null, undefined)),
  sameRows: sleepersKept(project, null, true) === project,
}));
"""


def test_the_rule_in_node():
    node = shutil.which("node")
    if not node:
        pytest.skip("no node")
    out = subprocess.run([node, "-e", NODE, str(STATIC / "shared.js")], capture_output=True, text=True, check=True, timeout=30).stdout
    got = json.loads(out)
    assert got["off"] == ["a", "c"], got                       # off: the sleepers go, the others keep their order
    assert got["offOpenSleeper"] == ["a", "b", "c"], got       # the open sleeper stays, its sleeping neighbour does not
    assert got["offOpenAwake"] == ["a", "c"] and got["offOpenOther"] == ["a", "c"], got
    assert got["on"] == ["a", "b", "c", "d"] and got["onOpen"] == ["a", "b", "c", "d"] and got["sameRows"] is True, got   # on: everyone, in place
    assert got["onlySleepers"] == [] and got["onlySleepersOpen"] == ["y"], got   # a project that only sleeps lists nothing (so it has no heading), unless one is open
    assert got["empty"] == [] and got["undefinedBox"] == ["a", "c"], got         # a pref the server never sent reads as off


def test_the_page_draws_its_list_through_the_rule_and_saves_the_box():
    app_js = (STATIC / "app.js").read_text()
    assert "sleepersKept(" in app_js and 'savePrefs({ showSleeping: e.target.checked })' in app_js
    assert '$("#show-sleeping").checked = !!state.prefs.showSleeping' in app_js


# ── the box and the list ─────────────────────────────────────────────────────
def test_sleepers_and_a_project_that_only_sleeps_are_left_out_until_the_box_is_checked(served, browser):
    assert get_prefs(served)["showSleeping"] is False
    open_stub(browser, served)
    assert browser.evaluate(BOX) is False                                  # off by default
    wait_rows(browser, AWAKE)                                              # the sleepers are not listed
    assert browser.evaluate(HEADS) == ["projects/alpha", "projects/gamma"]  # beta, whose sessions all sleep, has no heading either
    tick(browser)                                                          # on: every session, in its usual place, the sleepers marked
    wait_rows(browser, EVERYONE)
    assert browser.evaluate(HEADS) == ["projects/alpha", "projects/beta", "projects/gamma"]
    tags = browser.evaluate("[...document.querySelectorAll('#session-list .sess')].filter((r) => r.querySelector('.slp')).map((r) => r.dataset.key)")
    assert tags == ASLEEP
    tick(browser)                                                          # off again: back to the awake ones
    wait_rows(browser, AWAKE)
    assert browser.evaluate(HEADS) == ["projects/alpha", "projects/gamma"]


def test_the_box_sits_beside_show_all_sessions_and_says_what_it_does(served, browser):
    open_stub(browser, served)
    got = browser.evaluate("""(() => { const a = document.querySelector('#show-back').closest('label'), b = document.querySelector('#show-sleeping').closest('label');
      return { text: b.textContent.trim(), cls: b.className, tag: b.tagName, type: document.querySelector('#show-sleeping').type,
               next: a.nextElementSibling === b, tip: document.querySelector('#show-sleeping').title }; })()""")
    assert got["text"] == "Show sleeping sessions" and got["cls"] == "toggle" and got["tag"] == "LABEL" and got["type"] == "checkbox", got
    assert got["next"] and got["tip"], got                                 # the same markup as the background agents' box, right under it


def test_the_open_sleeper_stays_and_so_does_its_project_while_it_is_open(served, browser):
    open_stub(browser, served, "#s=example-beta-nap2")
    wait_rows(browser, ["example-alpha-main", "example-alpha-ui", "example-beta-nap2", "example-gamma-main"])   # not its sleeping neighbour
    assert browser.evaluate(HEADS) == ["projects/alpha", "projects/beta", "projects/gamma"]
    browser.evaluate("location.hash = '#s=example-alpha-nap'; ''")         # leaving it for another sleeper: the first goes, the new one stays
    wait_rows(browser, ["example-alpha-main", "example-alpha-nap", "example-alpha-ui", "example-gamma-main"])
    assert browser.evaluate(HEADS) == ["projects/alpha", "projects/gamma"]
    browser.evaluate("location.hash = '#sessions'; ''")                    # leaving it for the Overview: no session is open, so none stays
    wait_rows(browser, AWAKE)


def test_a_background_agent_is_still_hidden_by_its_own_box_and_the_two_boxes_agree(served, browser):
    open_stub(browser, served)
    wait_rows(browser, AWAKE)
    browser.evaluate("document.querySelector('#show-back').click(); ''")  # background agents on, sleepers still off
    wait_rows(browser, ["example-alpha-main", "example-alpha-ui", "example-gamma-engineer", "example-gamma-main"])
    tick(browser)
    wait_rows(browser, EVERYONE[:5] + ["example-gamma-engineer", "example-gamma-main", "example-gamma-nap"])
    browser.evaluate("document.querySelector('#show-back').click(); ''")  # background agents off again, sleepers on
    wait_rows(browser, EVERYONE)


# ── the saved choice ─────────────────────────────────────────────────────────
def test_the_choice_is_kept_by_the_server_and_survives_a_reload(served, browser):
    open_stub(browser, served)
    wait_rows(browser, AWAKE)
    tick(browser)
    saved(served, True)
    browser.reload()
    show_panel(browser)
    assert browser.evaluate(BOX) is True
    wait_rows(browser, EVERYONE)                                           # the first paint after the reload is already the long list
    put_prefs(served, {"showSleeping": False})                             # another device that turned it off: the next load hides them
    browser.reload()
    show_panel(browser)
    assert browser.evaluate(BOX) is False
    wait_rows(browser, AWAKE)


def test_the_prefs_route_refuses_a_box_that_is_not_true_or_false(served):
    req = urllib.request.Request(f"{served['url']}/api/prefs", data=json.dumps({"showSleeping": "yes"}).encode(), method="PUT",
                                 headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=10)
        raise AssertionError("a string was taken for a bool")
    except urllib.error.HTTPError as e:
        assert e.code == 400
    assert get_prefs(served)["showSleeping"] is False


# ── the Overview and a real sleeper ──────────────────────────────────────────
def test_the_overview_lists_a_sleeper_the_side_panel_leaves_out(slept, browser):
    open_page(browser, slept, "#sessions")
    assert wait_for(browser, "[...document.querySelectorAll('#sp-table tr')].some(r => /sleeping/.test(r.textContent))", 15.0)
    assert NAME in browser.evaluate("[...document.querySelectorAll('#sp-table tr')].find(r => /sleeping/.test(r.textContent)).textContent")
    assert wait_for(browser, "document.querySelectorAll('#session-list .sess').length > 0", 5.0)
    assert browser.evaluate(BOX) is False
    assert browser.evaluate(SIDEBAR_ROW % json.dumps(NAME)) is None        # the side panel has no row for it ...
    assert browser.evaluate(SIDEBAR_ROW % json.dumps(slept["name"])) is not None   # ... and keeps the awake one
    show_panel(browser)
    tick(browser)                                                          # the box on: the row is back, and the Overview is as it was
    assert wait_for(browser, SIDEBAR_ROW % json.dumps(NAME) + " !== null", 5.0)
    assert len(browser.evaluate("[...document.querySelectorAll('#sp-table tr')].filter(r => /sleeping/.test(r.textContent)).map(r => 1)")) == 1


def test_a_real_sleeper_that_is_open_stays_listed(slept, browser):
    open_page(browser, slept, "#s=" + NAME)
    assert wait_for(browser, SIDEBAR_ROW % json.dumps(NAME) + " !== null", 10.0)
    assert browser.evaluate(BOX) is False                                  # the box is off, the open sleeper is listed all the same
    browser.evaluate("location.hash = '#sessions'; ''")
    assert wait_for(browser, SIDEBAR_ROW % json.dumps(NAME) + " === null", 10.0)
