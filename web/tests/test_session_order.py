"""Sessions can be dragged into the order the owner wants, inside their own project, and sala keeps that order.

The same mechanism as the scopes and the projects (app.js, *drag-reorder*; pointer events, a mouse or a pen), the order saved
through api/prefs as `sessionOrder` (a flat list like `groupOrder`, of sala's permanent agent ids: a name changes with a rename and
the order went with it), so it holds after a reload, on another device, across a recycle and across a rename. What a wrong answer
costs: a session that lands in another project's list, an order that is lost on reload or kept only in the browser, a session
that moved on its own (a `-main` sorted first by the page when the owner did not ask), a new session that jumps ahead of the ones he
placed, a rename or a recycle that drops a session's place, a list saved before the ids that is not read any more, or a drag that
also opens the session. Every check guards one of those.

A headless Chromium at 1280 px with real DevTools mouse events; api/sessions is a stub whose projects the test sets, api/prefs is
the app's real endpoint on a temporary state directory (conftest.py: `served`, `browser`)."""

from __future__ import annotations

import json
import time

from test_board_items_ui import wait_for
from test_composer_attach import WAIT_READY

SESS = """(() => {
  const real = window.fetch.bind(window), json = (o) => new Response(JSON.stringify(o), { headers: { "Content-Type": "application/json" } });
  // the agent's permanent id (window.__ids: name -> id; a renamed agent keeps its id) and the process facts a recycle changes
  // (window.__gen: a new pid, pane and conversation id each time); a name in window.__noid has no registry row, so no id
  window.__ids = {}; window.__aliases = {}; window.__noid = []; window.__gen = 0; window.__prefsFail = 0;
  const sess = (n, role) => {
    const o = { pid: 1 + window.__gen, sessionId: n + "-" + window.__gen, name: n, cwd: "/x", status: "idle", tmux: "x:@0.%%" + window.__gen,
                tmuxSession: n, paneId: "%%" + window.__gen, role: role || "front", project: "", lane: "subscription-1", updatedAt: null, startedAt: null };
    if (!window.__noid.includes(n)) o.agentId = window.__ids[n] || "agent-" + n;
    if (window.__aliases[n]) o.aliases = window.__aliases[n];
    return o;
  };
  // two projects in the example scope: the server's order is what the test lists (the engineer BEFORE the main on purpose)
  window.__projects = %s;
  window.fetch = (url, opts) => {
    const u = String(url);
    // window.__prefsFail: how many reads of api/prefs fail (500) before they work again (Infinity: all of them)
    if (u.startsWith("api/prefs") && !(opts && opts.method) && window.__prefsFail > 0) { window.__prefsFail--; return Promise.resolve(new Response("{}", { status: 500 })); }
    if (u.startsWith("api/sessions")) {
      const groups = Object.entries(window.__projects).map(([key, names]) => ({ key, title: key.split("/")[1], scope: "example", sessions: names.map((n) => sess(n, n.endsWith("-engineer") ? "back" : "front")) }));
      return Promise.resolve(json({ scopes: [{ key: "example", title: "example", groups }], groups, rolesError: null }));
    }
    if (u.startsWith("api/board-items")) return Promise.resolve(json({ sessions: {}, fetchedAt: Date.now() }));
    return real(url, opts);
  };
})();"""
PROJECTS = {"projects/alpha": ["example-alpha-engineer", "example-alpha-main", "example-alpha-ui"], "projects/beta": ["example-beta-main", "example-beta-x"]}
LIST = "[...document.querySelectorAll('#session-list .group')].map((g) => ({ key: g.dataset.key, names: [...g.querySelectorAll(':scope > .sess')].map((r) => r.dataset.key) }))"
SIDE_IN = "document.getElementById('sidebar').getBoundingClientRect().left === 0"


def open_list(browser, served, projects=None, hash_="#new") -> None:
    """The sidebar open (pinned by a click on its toggle) over the page, the list drawn from `projects` (`show all` is on so the
    engineer rows are shown: the page hides background agents by default)."""
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": SESS % json.dumps(projects or PROJECTS)})
    browser.width, browser.height = 1280, 800
    browser.open(f"{served['url']}/{hash_}", dark=True)
    assert browser.evaluate(WAIT_READY)
    browser.evaluate("document.querySelector('#side-open').click(); ''")
    assert wait_for(browser, SIDE_IN, 5.0)
    browser.evaluate("(() => { const c = document.querySelector('#show-back'); if (!c.checked) c.click(); return '' })()")
    assert wait_for(browser, "document.querySelectorAll('#session-list .sess').length >= 5", 5.0), browser.evaluate(LIST)


def groups(browser) -> dict:
    return {g["key"]: g["names"] for g in browser.evaluate(LIST)}


def center(browser, name: str) -> tuple[float, float]:
    r = browser.evaluate(f"(() => {{ const r = [...document.querySelectorAll('#session-list .sess')].find((e) => e.dataset.key === {json.dumps(name)}).getBoundingClientRect(); return {{ x: r.x + r.width / 2, y: r.y + r.height / 2, h: r.height }}; }})()")
    return r["x"] - 20, r["y"]


def drag(browser, name: str, to_y: float, steps: int = 8) -> None:
    """A real mouse drag of a row to the height `to_y`: press, move in steps (the page starts a drag after 5 px), release."""
    x, y = center(browser, name)
    ev = {"x": x, "button": "left", "clickCount": 1}
    browser.send("Input.dispatchMouseEvent", {**ev, "y": y, "type": "mouseMoved", "button": "none", "clickCount": 0})
    browser.send("Input.dispatchMouseEvent", {**ev, "y": y, "type": "mousePressed"})
    for i in range(1, steps + 1):
        browser.send("Input.dispatchMouseEvent", {**ev, "y": y + (to_y - y) * i / steps, "type": "mouseMoved", "buttons": 1, "clickCount": 0})
    browser.send("Input.dispatchMouseEvent", {**ev, "y": to_y, "type": "mouseReleased"})
    browser.evaluate("new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))")


def above(browser, name: str) -> float:
    """A height just above the row's middle: dropping there puts the dragged row before `name`."""
    x, y = center(browser, name)
    h = browser.evaluate(f"[...document.querySelectorAll('#session-list .sess')].find((e) => e.dataset.key === {json.dumps(name)}).getBoundingClientRect().height")
    return y - h / 2 + 2


def saved(browser) -> list:
    return browser.evaluate("fetch('api/prefs', { cache: 'no-store' }).then((r) => r.json()).then((d) => d.sessionOrder)")


def ids(*names: str) -> list:
    """The agent ids the stub gives these names (agent-<name>)."""
    return [f"agent-{n}" for n in names]


def reopen(browser) -> None:
    """A reload of the page with the list drawn again (the saved order is read from the server), `show all` on."""
    browser.send("Page.reload")
    assert browser.evaluate(WAIT_READY)
    browser.evaluate("document.querySelector('#side-open').click(); ''")
    assert wait_for(browser, SIDE_IN, 5.0)
    browser.evaluate("(() => { const c = document.querySelector('#show-back'); if (!c.checked) c.click(); return '' })()")
    assert wait_for(browser, "document.querySelectorAll('#session-list .sess').length >= 5", 5.0)


def put_prefs(browser, prefs: dict) -> None:
    """Another device's save (or an older one): the server's prefs, written through the app's own endpoint."""
    r = browser.evaluate("fetch('api/prefs', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(%s) }).then((r) => r.status)" % json.dumps(prefs))
    assert r == 200


def put_order(browser, order: list) -> None:
    put_prefs(browser, {"sessionOrder": order})


def stored(served) -> dict:
    """The prefs file itself (the page's reads of api/prefs may be made to fail)."""
    return json.loads((served["settings"].state_dir / "prefs.json").read_text())


def wait_saved(browser, want: list) -> list:
    """The saved order once it equals `want` (the page's save is asynchronous), else what it is after 5 s."""
    end = time.time() + 5
    while time.time() < end and saved(browser) != want:
        time.sleep(0.1)
    return saved(browser)


def poll(browser) -> None:
    """The page's next poll of api/sessions (what the stub says now), waited for."""
    browser.evaluate("window.__polled = false; loadSessions().then(() => { window.__polled = true; }); ''")
    assert wait_for(browser, "window.__polled === true", 5.0)


def test_without_a_saved_order_the_servers_order_stays_and_no_main_is_moved_first(served, browser):
    open_list(browser, served)
    g = groups(browser)
    assert g["projects/alpha"] == ["example-alpha-engineer", "example-alpha-main", "example-alpha-ui"], g   # the engineer stays before its main: the owner does the reordering
    assert g["projects/beta"] == ["example-beta-main", "example-beta-x"] and saved(browser) == []


def test_a_drag_reorders_inside_its_project_and_sala_keeps_it(served, browser):
    open_list(browser, served)
    drag(browser, "example-alpha-ui", above(browser, "example-alpha-engineer"))
    g = groups(browser)
    assert g["projects/alpha"] == ["example-alpha-ui", "example-alpha-engineer", "example-alpha-main"] and g["projects/beta"] == ["example-beta-main", "example-beta-x"], g
    end = time.time() + 5
    while time.time() < end and saved(browser)[:3] != ids("example-alpha-ui", "example-alpha-engineer", "example-alpha-main"):
        time.sleep(0.1)   # the PUT is the page's own, a moment after the drop
    assert saved(browser)[:3] == ids("example-alpha-ui", "example-alpha-engineer", "example-alpha-main"), saved(browser)   # ids, not names
    # kept by sala, not by the browser: a reload reads it from the server (and so does a page on another device)
    browser.evaluate("localStorage.clear(); sessionStorage.clear(); ''")
    browser.send("Page.reload")
    assert browser.evaluate(WAIT_READY)
    browser.evaluate("document.querySelector('#side-open').click(); ''")
    assert wait_for(browser, SIDE_IN, 5.0)
    browser.evaluate("(() => { const c = document.querySelector('#show-back'); if (!c.checked) c.click(); return '' })()")
    assert wait_for(browser, "document.querySelectorAll('#session-list .sess').length >= 5", 5.0)
    assert groups(browser)["projects/alpha"] == ["example-alpha-ui", "example-alpha-engineer", "example-alpha-main"]


def test_a_drag_does_not_open_the_session_and_a_click_still_does(served, browser):
    open_list(browser, served)
    h0 = browser.evaluate("location.hash")
    drag(browser, "example-alpha-main", above(browser, "example-alpha-engineer"))
    time.sleep(0.3)
    assert browser.evaluate("location.hash") == h0, "the drop also followed the row's link"
    # a press that does not move is the link
    x, y = center(browser, "example-beta-x")
    for t in ("mousePressed", "mouseReleased"):
        browser.send("Input.dispatchMouseEvent", {"type": t, "x": x, "y": y, "button": "left", "clickCount": 1})
    assert wait_for(browser, "location.hash === '#s=example-beta-x'", 5.0), browser.evaluate("location.hash")


def test_the_saved_order_comes_first_a_new_session_follows_it_and_unknown_names_are_ignored(served, browser):
    projects = {"projects/alpha": ["example-alpha-main", "example-alpha-ui", "example-alpha-x"], "projects/beta": ["example-beta-main", "example-beta-x"]}
    open_list(browser, served, projects)
    # saved: a ui before a main (placed by the owner), a name that is not live now, and one of the other project
    r = browser.evaluate("""fetch('api/prefs', { method: 'PUT', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ sessionOrder: ['example-gone-main', 'example-alpha-ui', 'example-beta-x', 'example-alpha-main'] }) }).then((r) => r.status)""")
    assert r == 200
    browser.send("Page.reload")
    assert browser.evaluate(WAIT_READY)
    browser.evaluate("document.querySelector('#side-open').click(); ''")
    assert wait_for(browser, SIDE_IN, 5.0)
    assert wait_for(browser, "document.querySelectorAll('#session-list .sess').length >= 5", 5.0)
    g = groups(browser)
    # the saved ones in the saved order (the other project's name does not matter here), the one not in it after them
    assert g["projects/alpha"] == ["example-alpha-ui", "example-alpha-main", "example-alpha-x"], g
    assert g["projects/beta"] == ["example-beta-x", "example-beta-main"], g
    # a new session appears (the page's next poll): after the saved ones of its project, in the server's order among the unsaved
    browser.evaluate("window.__projects['projects/alpha'].push('example-alpha-new'); loadSessions(); ''")
    assert wait_for(browser, "document.querySelectorAll('#session-list .sess[data-key=\"example-alpha-new\"]').length === 1", 5.0)
    assert groups(browser)["projects/alpha"] == ["example-alpha-ui", "example-alpha-main", "example-alpha-x", "example-alpha-new"]
    # a session that ended is gone; the others keep their places
    browser.evaluate("window.__projects['projects/alpha'] = window.__projects['projects/alpha'].filter((n) => n !== 'example-alpha-ui'); loadSessions(); ''")
    assert wait_for(browser, "document.querySelectorAll('#session-list .sess[data-key=\"example-alpha-ui\"]').length === 0", 5.0)
    assert groups(browser)["projects/alpha"] == ["example-alpha-main", "example-alpha-x", "example-alpha-new"]


def test_a_long_list_of_names_that_are_gone_never_pushes_a_live_session_out_of_the_saved_order(served, browser):
    """The server takes 500 names. Saved names of sessions that ended stay for a while (a returning session finds its place), but a
    drag must keep every live session's place and cut the gone ones instead: at most 100 of them are kept."""
    open_list(browser, served)
    gone = [f"example-gone-{i}" for i in range(497)]
    r = browser.evaluate("fetch('api/prefs', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ sessionOrder: %s }) }).then((r) => r.status)" % json.dumps(gone + ["example-alpha-ui", "example-alpha-main", "example-alpha-engineer"]))
    assert r == 200
    browser.send("Page.reload")
    assert browser.evaluate(WAIT_READY)
    browser.evaluate("document.querySelector('#side-open').click(); ''")
    assert wait_for(browser, SIDE_IN, 5.0)
    browser.evaluate("(() => { const c = document.querySelector('#show-back'); if (!c.checked) c.click(); return '' })()")
    assert wait_for(browser, "document.querySelectorAll('#session-list .sess').length >= 5", 5.0)
    assert groups(browser)["projects/alpha"] == ["example-alpha-ui", "example-alpha-main", "example-alpha-engineer"]
    drag(browser, "example-alpha-engineer", above(browser, "example-alpha-ui"))
    want = ids("example-alpha-engineer", "example-alpha-ui", "example-alpha-main")
    end = time.time() + 5
    while time.time() < end and [n for n in saved(browser) if n.startswith("agent-example-alpha")] != want:
        time.sleep(0.1)
    got = saved(browser)
    assert [n for n in got if n.startswith("agent-example-alpha")] == want, got
    live = set(ids("example-alpha-engineer", "example-alpha-main", "example-alpha-ui"))   # the project dragged in; the other project is not written
    assert live <= set(got) and len(got) <= 500 and len([n for n in got if n not in live]) <= 100, (len(got), [n for n in got if n in live])


def test_a_row_cannot_be_dropped_into_another_project(served, browser):
    open_list(browser, served)
    # dragged onto the other project's rows: it stays in its own, at the end (nothing of the other project moves)
    drag(browser, "example-alpha-engineer", above(browser, "example-beta-main"))
    g = groups(browser)
    assert g["projects/beta"] == ["example-beta-main", "example-beta-x"], g
    assert g["projects/alpha"] == ["example-alpha-main", "example-alpha-ui", "example-alpha-engineer"], g
    assert "example-alpha-engineer" not in g["projects/beta"]
    # the other way: a row of beta dropped over alpha's rows stays in beta
    drag(browser, "example-beta-x", above(browser, "example-alpha-main"))
    g = groups(browser)
    assert g["projects/beta"] == ["example-beta-x", "example-beta-main"] and len(g["projects/alpha"]) == 3, g
    assert "example-beta-x" not in g["projects/alpha"]


ALPHA_DRAGGED = ["example-alpha-ui", "example-alpha-engineer", "example-alpha-main"]


def drag_ui_first(browser) -> None:
    """the owner's drag: the ui agent to the top of alpha; waits until the server holds it (as ids)."""
    drag(browser, "example-alpha-ui", above(browser, "example-alpha-engineer"))
    assert groups(browser)["projects/alpha"] == ALPHA_DRAGGED
    assert wait_saved(browser, ids(*ALPHA_DRAGGED)) == ids(*ALPHA_DRAGGED)      # only the dragged project is written


def test_a_recycle_keeps_the_order(served, browser):
    """The fleet recycle restarts every session: the same agents come back with new pids, panes and conversation ids. The order is
    on the agent, not on any of those."""
    open_list(browser, served)
    drag_ui_first(browser)
    browser.evaluate("window.__gen = 1; ''")        # every process is new
    poll(browser)
    assert browser.evaluate("state.byName.get('example-alpha-ui').pid") == 2     # the page really took the recycled rows
    assert groups(browser)["projects/alpha"] == ALPHA_DRAGGED
    # half the fleet is down for a moment (a recycle brings them back one by one) and comes back: nobody lost a place
    browser.evaluate("window.__projects['projects/alpha'] = ['example-alpha-main']; ''")
    poll(browser)
    browser.evaluate("window.__gen = 2; window.__projects['projects/alpha'] = ['example-alpha-engineer', 'example-alpha-main', 'example-alpha-ui']; ''")
    poll(browser)
    assert groups(browser)["projects/alpha"] == ALPHA_DRAGGED
    assert saved(browser)[:3] == ids(*ALPHA_DRAGGED)      # the page wrote nothing over it


def test_a_rename_keeps_the_place_and_a_new_agent_goes_last(served, browser):
    open_list(browser, served)
    drag_ui_first(browser)
    # `sala rename`: the same agent under a new name (and the old one among its aliases)
    browser.evaluate("""(() => {
      window.__ids['example-alpha-designer'] = 'agent-example-alpha-ui';
      window.__aliases['example-alpha-designer'] = ['example-alpha-ui'];
      window.__projects['projects/alpha'] = ['example-alpha-engineer', 'example-alpha-main', 'example-alpha-designer'];
      return ''; })()""")
    poll(browser)
    assert groups(browser)["projects/alpha"] == ["example-alpha-designer", "example-alpha-engineer", "example-alpha-main"]
    # a new agent with no saved place: after the placed ones of its project, not before them and not in another project
    browser.evaluate("window.__projects['projects/alpha'].push('example-alpha-aaa-new'); ''")
    poll(browser)
    g = groups(browser)
    assert g["projects/alpha"] == ["example-alpha-designer", "example-alpha-engineer", "example-alpha-main", "example-alpha-aaa-new"], g
    assert g["projects/beta"] == ["example-beta-main", "example-beta-x"]
    assert saved(browser)[:3] == ids(*ALPHA_DRAGGED)      # a rename and a new agent change nothing that is saved


def test_an_agent_the_registry_has_no_row_for_keeps_its_place_by_its_name(served, browser):
    open_list(browser, served)
    browser.evaluate("window.__noid = ['example-alpha-ui']; ''")
    poll(browser)
    drag(browser, "example-alpha-ui", above(browser, "example-alpha-engineer"))
    got = wait_saved(browser, ["example-alpha-ui", *ids("example-alpha-engineer", "example-alpha-main")])
    assert got == ["example-alpha-ui", *ids("example-alpha-engineer", "example-alpha-main")], got
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": "window.__noid = ['example-alpha-ui'];"})   # no row from the first paint of the reloaded page
    reopen(browser)
    assert groups(browser)["projects/alpha"] == ALPHA_DRAGGED


def test_an_order_saved_by_names_before_the_ids_is_read_and_becomes_ids(served, browser):
    """The lists saved until now hold session names. They are read as the agents that have those names (or had them: a renamed
    agent's old name is among its aliases) and rewritten once as ids; a name nothing live matches stays as it was."""
    open_list(browser, served)
    old = ["example-gone-main", "example-alpha-ui", "example-beta-x", "example-alpha-old", "example-alpha-engineer"]
    put_order(browser, old)
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": "window.__aliases['example-alpha-main'] = ['example-alpha-old'];"})   # known from the first paint
    reopen(browser)
    g = groups(browser)
    assert g["projects/alpha"] == ["example-alpha-ui", "example-alpha-main", "example-alpha-engineer"], g      # the old name found its agent
    assert g["projects/beta"] == ["example-beta-x", "example-beta-main"], g
    want = ["example-gone-main", *ids("example-alpha-ui", "example-beta-x", "example-alpha-main", "example-alpha-engineer")]
    assert wait_saved(browser, want) == want
    # and the migrated list is the order from now on: a rename of the first one changes nothing
    browser.evaluate("""(() => { window.__ids['example-alpha-zz'] = 'agent-example-alpha-ui';
      window.__projects['projects/alpha'] = ['example-alpha-engineer', 'example-alpha-main', 'example-alpha-zz']; return ''; })()""")
    poll(browser)
    assert groups(browser)["projects/alpha"] == ["example-alpha-zz", "example-alpha-main", "example-alpha-engineer"]
    assert saved(browser) == want


STORED = ids("example-beta-x", "example-beta-main", "example-alpha-main", "example-alpha-ui", "example-alpha-engineer")


def beta_part(order: list) -> list:
    return [n for n in order if "beta" in n]


def test_a_page_that_holds_only_defaults_saves_the_agents_it_moved_and_nothing_else(served, browser):
    """The page read the prefs when the file was missing (a service restarted onto a new state folder), the file was put back, and
    the owner dragged one project's agents on that page. What it saves is that project's order: the other project's saved order, and the
    keys he did not touch, are what the server holds."""
    open_list(browser, served)                                   # loaded with nothing saved
    assert groups(browser)["projects/beta"] == ["example-beta-main", "example-beta-x"]
    put_prefs(browser, {"sessionOrder": STORED, "groupOrder": ["projects/beta", "projects/alpha"], "collapsed": ["scope:other"]})   # the file, put back
    drag(browser, "example-alpha-ui", above(browser, "example-alpha-engineer"))          # the page's alpha is engineer, main, ui
    want_alpha = ids("example-alpha-ui", "example-alpha-engineer", "example-alpha-main")
    end = time.time() + 5
    while time.time() < end and [n for n in saved(browser) if "alpha" in n] != want_alpha:
        time.sleep(0.1)
    got = saved(browser)
    assert [n for n in got if "alpha" in n] == want_alpha, got        # the ui agent was dragged first of its project
    assert beta_part(got) == ids("example-beta-x", "example-beta-main"), got      # the other project: as stored, not the page's default
    prefs = stored(served)
    assert prefs["groupOrder"] == ["projects/beta", "projects/alpha"] and prefs["collapsed"] == ["scope:other"], prefs
    assert groups(browser)["projects/beta"] == ["example-beta-x", "example-beta-main"]      # and the page shows what is stored now


def test_a_page_whose_prefs_failed_to_load_does_not_save_over_the_stored_ones(served, browser):
    open_list(browser, served)
    put_prefs(browser, {"sessionOrder": STORED, "groupOrder": ["projects/beta", "projects/alpha"], "collapsed": ["projects/beta"]})
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": "window.__prefsFail = 1;"})      # the page's first read of the prefs fails
    reopen(browser)
    assert browser.evaluate("JSON.stringify(state.prefs.sessionOrder)") == "[]"      # it holds defaults
    drag(browser, "example-alpha-ui", above(browser, "example-alpha-engineer"))
    end = time.time() + 5
    while time.time() < end and saved(browser)[:3] == STORED[:3]:
        time.sleep(0.1)
    got = saved(browser)
    assert beta_part(got) == ids("example-beta-x", "example-beta-main"), got
    assert [n for n in got if "alpha" in n] == ids("example-alpha-ui", "example-alpha-engineer", "example-alpha-main"), got
    prefs = stored(served)
    assert prefs["groupOrder"] == ["projects/beta", "projects/alpha"] and prefs["collapsed"] == ["projects/beta"], prefs


def test_when_the_stored_prefs_cannot_be_read_nothing_is_saved(served, browser):
    open_list(browser, served)
    put_prefs(browser, {"sessionOrder": STORED, "collapsed": ["projects/beta"]})
    before = stored(served)
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": "window.__prefsFail = Infinity;"})   # every read of the prefs fails
    reopen(browser)
    drag(browser, "example-alpha-ui", above(browser, "example-alpha-engineer"))
    assert wait_for(browser, "document.getElementById('side-note').textContent.includes('could not be read')", 5.0), browser.evaluate("document.getElementById('side-note').textContent")
    time.sleep(0.5)
    assert stored(served) == before                                  # not one byte of the stored prefs was replaced


def test_the_header_is_not_touched(served, browser):
    """No element is added to the session header for this (its fold is measured to the pixel: test_header_fold.py)."""
    open_list(browser, served)
    assert browser.evaluate("[...document.querySelectorAll('#top *')].filter((e) => e.matches('[draggable], .sess-more, .handle')).length") == 0
