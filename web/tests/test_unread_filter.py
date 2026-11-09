"""The Unread entry under Overview in the side panel, and the "Unread only" filter it turns on (app.js "the unread reply count").

The entry shows the total of the unread reply counts the panel already shows on its rows (unread.py: front agents only, the open
agent never); one tap turns the filter on, a second turns it off. On, the list holds the agents with an unread reply under their
project and scope headings, plus the open agent until the owner leaves it; headings read as open (the saved folds are not
touched); an empty list says "Nothing unread"; background agents have no count, so they never show. The on/off is the `unreadOnly`
pref, kept by the server like "Show all sessions", so the phone and the desktop agree and a reload keeps it.

What a wrong answer costs: an unread reply hidden behind a folded heading or a background agent's row, a row that vanishes under the
pointer the moment its replies count as read, folds that are lost or changed by looking at the filter, a total that disagrees with
the rows, or a filter that is forgotten on reload. The pure rules run in node; the page is a headless Chromium on `/` and on `/v2/`
(the same app, drawn by the v2 layer), at a phone's width and at a desktop's. api/sessions is a stub, api/prefs the app's own."""

from __future__ import annotations

import json
import shutil
import subprocess
import urllib.request

import pytest

from sala_web.app import STATIC
from test_board_items_ui import wait_for
from test_composer_attach import WAIT_READY

# ── the pure rules, in node ───────────────────────────────────────────────────
NODE = r"""
const fs = require('fs');
const src = fs.readFileSync(process.argv[1], 'utf8');
const m = /\/\/ <unread-words>[^\n]*\n([\s\S]*?)\/\/ <\/unread-words>/.exec(src);
eval(m[1] + 'globalThis.api = { unreadOfSession, unreadTotal, unreadKept };');
const { unreadOfSession, unreadTotal, unreadKept } = globalThis.api;
const f = (name, n, extra) => ({ name, role: 'front', unread_count: n, unread: n > 0, ...extra });
const all = [f('a', 2), f('b', 0), f('c', 1), f('eng', 0, { role: 'back' }), f('d', 0, { unread_count: undefined, unread: true }),
             f('e', 0, { role: 'side', unread_count: 4 }), f('g', 12)];
console.log(JSON.stringify({
  of: all.map((s) => unreadOfSession(s, null)),
  ofOpen: unreadOfSession(f('a', 2), 'a'), ofNull: [unreadOfSession(null, null), unreadOfSession({}, null)],
  total: unreadTotal(all, null), totalOpenA: unreadTotal(all, 'a'),
  kept: unreadKept(all, null).map((s) => s.name),
  keptOpenRead: unreadKept(all, 'b').map((s) => s.name),      // the open agent stays although it has nothing unread
  keptOpenA: unreadKept(all, 'a').map((s) => s.name),         // ... and an open agent with replies is the open one, never counted twice
  keptOpenBack: unreadKept(all, 'eng').map((s) => s.name),
  none: unreadKept([f('x', 0), f('y', 0)], null), noneOpen: unreadKept([f('x', 0), f('y', 0)], 'y').map((s) => s.name),
}));
"""


def test_the_filter_rules_in_node():
    node = shutil.which("node")
    if not node:
        pytest.skip("no node")
    out = subprocess.run([node, "-e", NODE, str(STATIC / "shared.js")], capture_output=True, text=True, check=True).stdout
    got = json.loads(out)
    assert got["of"] == [2, 0, 1, 0, 1, 0, 12], got           # a count; none for a background or side agent; `unread` with no count reads as 1
    assert got["ofOpen"] == 0 and got["ofNull"] == [0, 0], got
    assert got["total"] == 16 and got["totalOpenA"] == 14, got
    assert got["kept"] == ["a", "c", "d", "g"], got            # background agents never; a side agent has no count
    assert got["keptOpenRead"] == ["a", "b", "c", "d", "g"], got
    assert got["keptOpenA"] == ["a", "c", "d", "g"], got
    assert got["keptOpenBack"] == ["a", "c", "eng", "d", "g"], got   # an open background agent stays too (it is the page's open one)
    assert got["none"] == [] and got["noneOpen"] == ["y"], got


# ── the page ──────────────────────────────────────────────────────────────────
SESS = """(() => {
  const real = window.fetch.bind(window), json = (o) => new Response(JSON.stringify(o), { headers: { "Content-Type": "application/json" } });
  // window.__unread: name -> the unread reply count the server would send (a front agent only); opening a session reads it
  window.__unread = %s;
  const sess = (n, role) => ({ pid: 1, sessionId: n, name: n, cwd: "/x", status: "idle", tmux: "x:@0.%%0", tmuxSession: n, paneId: "%%0",
    role, project: "", lane: "subscription-1", updatedAt: null, startedAt: null, agentId: "agent-" + n,
    unread_count: role === "front" ? (window.__unread[n] || 0) : 0, unread: role === "front" && (window.__unread[n] || 0) > 0 });
  const proj = (key, names) => ({ key: "projects/" + key, title: key, scope: "example", sessions: names.map((n) => sess(n, n.endsWith("-engineer") ? "back" : "front")) });
  window.fetch = (url, opts) => {
    const u = String(url);
    if (u.startsWith("api/sessions")) {
      const groups = [proj("alpha", ["example-alpha-engineer", "example-alpha-main", "example-alpha-ui"]), proj("beta", ["example-beta-main", "example-beta-x"]),
                      proj("gamma", ["example-gamma-engineer", "example-gamma-main"])];
      return Promise.resolve(json({ scopes: [{ key: "example", title: "example", groups }], groups, rolesError: null }));
    }
    if (u.startsWith("api/read")) { window.__unread[JSON.parse(opts.body).name] = 0; return Promise.resolve(json({ ok: true })); }
    if (u.startsWith("api/board-items")) return Promise.resolve(json({ sessions: {}, fetchedAt: Date.now() }));
    return real(url, opts);
  };
})();"""
UNREAD = {"example-alpha-main": 2, "example-beta-main": 1, "example-gamma-main": 3}          # total 6
ROWS = "[...document.querySelectorAll('#session-list .sess')].map((r) => r.dataset.key)"
HEADS = "[...document.querySelectorAll('#session-list .group-title')].map((h) => [h.dataset.ckey, h.getAttribute('aria-expanded')])"
ENTRY = """(() => { const b = document.querySelector('#side-unread'), c = b.querySelector('.ucount'), top = [...document.querySelectorAll('.side-top > *')].map((e) => e.id);
  return { top, pressed: b.getAttribute('aria-pressed'), label: b.querySelector('.label').textContent, selected: b.classList.contains('selected'),
           count: c ? c.textContent : null, countLabel: c ? c.getAttribute('aria-label') : null, tag: b.tagName,
           empty: [...document.querySelectorAll('#session-list .empty')].map((e) => e.textContent) }; })()"""
VIEWS = [pytest.param("", id="v1"), pytest.param("/v2", id="v2")]
WIDTHS = [pytest.param(390, id="phone"), pytest.param(1280, id="desktop")]
SIDE_IN = "document.getElementById('sidebar').getBoundingClientRect().left === 0"


def put_prefs(served, prefs: dict) -> None:
    req = urllib.request.Request(f"{served['url']}/api/prefs", data=json.dumps(prefs).encode(), method="PUT", headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        assert r.status == 200


def get_prefs(served) -> dict:
    with urllib.request.urlopen(f"{served['url']}/api/prefs", timeout=10) as r:
        return json.load(r)


def open_panel(browser, served, base: str, width: int, unread=None, hash_="#sessions") -> None:
    """The page at `base` ("" or "/v2") with the side panel open, drawn from the stub."""
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": SESS % json.dumps(UNREAD if unread is None else unread)})
    browser.width, browser.height = width, 844 if width < 700 else 800
    url = f"{served['url']}{base}/{hash_}"
    if width < 700:
        browser.open(url, dark=True)                                      # a phone: the drawer
    else:                                                                 # a desktop that hovers: the sidebar pinned open
        browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 800, "deviceScaleFactor": 1, "mobile": False})
        browser.send("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-color-scheme", "value": "dark"}]})
        browser.send("Page.navigate", {"url": url})
    assert browser.evaluate(WAIT_READY)
    show_panel(browser)


def show_panel(browser) -> None:
    browser.evaluate("(() => { if (document.getElementById('sidebar').getBoundingClientRect().left !== 0) document.querySelector('#side-open').click(); return ''; })()")
    assert wait_for(browser, SIDE_IN, 5.0)
    assert wait_for(browser, "document.querySelectorAll('#session-list .sess').length > 0 || document.querySelector('#session-list .empty') !== null", 8.0)


def tap_unread(browser) -> None:
    browser.evaluate("document.querySelector('#side-unread').click(); ''")


def poll(browser) -> None:
    browser.evaluate("window.__polled = false; loadSessions().then(() => { window.__polled = true; }); ''")
    assert wait_for(browser, "window.__polled === true", 5.0)


def wait_rows(browser, want: list, secs: float = 6.0) -> list:
    assert wait_for(browser, f"JSON.stringify({ROWS}) === {json.dumps(json.dumps(want, separators=(",", ":")))}", secs), browser.evaluate(ROWS)
    return browser.evaluate(ROWS)


@pytest.mark.parametrize("width", WIDTHS)
@pytest.mark.parametrize("base", VIEWS)
def test_the_entry_sits_under_overview_with_the_total_and_a_tap_filters_the_list(served, browser, base, width):
    put_prefs(served, {"collapsed": ["projects/gamma"], "showAll": True})                    # the gamma project is folded; background agents are shown
    open_panel(browser, served, base, width)
    e = browser.evaluate(ENTRY)
    assert e["top"] == ["side-new", "side-ovw", "side-unread"] and e["tag"] == "BUTTON", e   # under Overview, a toggle and not a link
    assert (e["pressed"], e["label"], e["selected"], e["count"]) == ("false", "Unread", False, "6"), e
    assert e["countLabel"] == "6 unread replies in all agents", e
    # off: every row of the open projects, background agents too (Show all sessions is on), gamma folded to its heading
    assert wait_rows(browser, ["example-alpha-engineer", "example-alpha-main", "example-alpha-ui", "example-beta-main", "example-beta-x"]) is not None
    assert dict(browser.evaluate(HEADS))["projects/gamma"] == "false"
    tap_unread(browser)
    # on: only the agents with an unread reply, gamma open although it is folded, background agents never
    wait_rows(browser, ["example-alpha-main", "example-beta-main", "example-gamma-main"])
    e = browser.evaluate(ENTRY)
    assert (e["pressed"], e["label"], e["selected"], e["count"], e["empty"]) == ("true", "Unread only", True, "6", []), e
    assert dict(browser.evaluate(HEADS)) == {"projects/alpha": "true", "projects/beta": "true", "projects/gamma": "true"}, browser.evaluate(HEADS)
    assert browser.evaluate("document.querySelector('#side-unread').getBoundingClientRect().top > document.querySelector('#side-ovw').getBoundingClientRect().bottom - 1")
    # the entry is a toggle: the drawer stays open on a phone, and no page is opened
    assert browser.evaluate(SIDE_IN) and browser.evaluate("location.hash") == "#sessions"
    # a tap on a heading folds nothing while the filter is on: the saved folds are as they were
    browser.evaluate("document.querySelector('#session-list .group-title').click(); ''")
    assert get_prefs(served)["collapsed"] == ["projects/gamma"]
    # off again: the list and the fold are back, the count is the same
    tap_unread(browser)
    wait_rows(browser, ["example-alpha-engineer", "example-alpha-main", "example-alpha-ui", "example-beta-main", "example-beta-x"])
    assert dict(browser.evaluate(HEADS))["projects/gamma"] == "false"
    e = browser.evaluate(ENTRY)
    assert (e["pressed"], e["label"], e["count"]) == ("false", "Unread", "6"), e
    assert get_prefs(served)["collapsed"] == ["projects/gamma"]


@pytest.mark.parametrize("base", VIEWS)
def test_the_choice_is_kept_by_the_server_and_survives_a_reload(served, browser, base):
    assert get_prefs(served)["unreadOnly"] is False
    open_panel(browser, served, base, 390)
    tap_unread(browser)
    for _ in range(50):                                                                       # the save is asynchronous
        if get_prefs(served)["unreadOnly"]:
            break
        browser.evaluate("new Promise((r) => setTimeout(r, 100))")
    assert get_prefs(served)["unreadOnly"] is True
    browser.send("Page.reload")
    assert browser.evaluate(WAIT_READY)
    show_panel(browser)
    wait_rows(browser, ["example-alpha-main", "example-beta-main", "example-gamma-main"])    # the first paint after the reload is already filtered
    assert browser.evaluate(ENTRY)["pressed"] == "true"
    # another device that turned it off: the next load shows everything
    put_prefs(served, {"unreadOnly": False})
    browser.send("Page.reload")
    assert browser.evaluate(WAIT_READY)
    show_panel(browser)
    assert browser.evaluate(ENTRY)["pressed"] == "false" and "example-alpha-ui" in browser.evaluate(ROWS)


@pytest.mark.parametrize("base", VIEWS)
def test_the_open_agent_stays_until_the_owner_leaves_it_and_is_not_counted(served, browser, base):
    put_prefs(served, {"unreadOnly": True})
    open_panel(browser, served, base, 1280, hash_="#s=example-alpha-main")
    # opened: its replies are read (the stub's api/read), yet its row stays, without a count; the total no longer holds its 2
    wait_rows(browser, ["example-alpha-main", "example-beta-main", "example-gamma-main"])
    poll(browser)
    assert browser.evaluate(ENTRY)["count"] == "4"
    assert browser.evaluate("document.querySelector('#session-list .sess[data-key=\"example-alpha-main\"] .ucount')") is None
    # a reply that lands in another agent joins the list
    browser.evaluate("window.__unread['example-beta-x'] = 1; ''")
    poll(browser)
    wait_rows(browser, ["example-alpha-main", "example-beta-main", "example-beta-x", "example-gamma-main"])
    # leaving it for another agent: the first goes (it has nothing unread), the new open one stays
    browser.evaluate("location.hash = '#s=example-beta-x'; ''")
    wait_rows(browser, ["example-beta-main", "example-beta-x", "example-gamma-main"])
    # leaving for the Overview: no agent is open, so only the unread ones remain
    browser.evaluate("location.hash = '#sessions'; ''")
    wait_rows(browser, ["example-beta-main", "example-gamma-main"])
    assert browser.evaluate(ENTRY)["count"] == "4"


@pytest.mark.parametrize("base", VIEWS)
def test_nothing_unread_says_so_and_a_background_agent_never_shows(served, browser, base):
    put_prefs(served, {"unreadOnly": True, "showAll": True})
    open_panel(browser, served, base, 390, unread={})
    assert wait_rows(browser, []) == []
    e = browser.evaluate(ENTRY)
    assert e["empty"] == ["Nothing unread"] and e["count"] is None and e["pressed"] == "true", e   # no count chip at zero
    # the open agent is still the one row, with the line under it
    browser.evaluate("location.hash = '#s=example-alpha-ui'; ''")
    wait_rows(browser, ["example-alpha-ui"])
    assert browser.evaluate(ENTRY)["empty"] == ["Nothing unread"]
    # the open one is a background agent: it stays while open, like any open agent
    browser.evaluate("location.hash = '#s=example-gamma-engineer'; ''")
    wait_rows(browser, ["example-gamma-engineer"])
    # something arrives: the line goes, the row comes
    browser.evaluate("location.hash = '#sessions'; window.__unread['example-beta-x'] = 1; ''")
    poll(browser)
    wait_rows(browser, ["example-beta-x"])
    e = browser.evaluate(ENTRY)
    assert e["empty"] == [] and e["count"] == "1", e
    # turned off with nothing unread: the ordinary list, no line
    browser.evaluate("window.__unread['example-beta-x'] = 0; ''")
    poll(browser)
    tap_unread(browser)
    assert wait_for(browser, "document.querySelectorAll('#session-list .sess').length >= 5", 5.0)
    assert browser.evaluate(ENTRY)["empty"] == []


@pytest.mark.parametrize("base", VIEWS)
def test_the_total_follows_the_rows_and_reads_9_plus_above_nine(served, browser, base):
    open_panel(browser, served, base, 390, unread={"example-alpha-main": 7, "example-beta-main": 4})
    assert browser.evaluate(ENTRY)["count"] == "9+"
    assert browser.evaluate(ENTRY)["countLabel"] == "More than 9 unread replies in all agents"
    browser.evaluate("window.__unread['example-beta-main'] = 0; window.__unread['example-alpha-main'] = 1; ''")
    poll(browser)
    assert browser.evaluate(ENTRY)["count"] == "1" and browser.evaluate(ENTRY)["countLabel"] == "1 unread reply in all agents"
