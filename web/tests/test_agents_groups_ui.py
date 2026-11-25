"""The Agents list in a browser: the Surface column, the "Group by" buttons, the heading rows that fold, and the choice that is saved.

The page runs in a headless Chromium when one is installed (conftest.py: `served`, `browser`), else the tests are skipped; CI runs them. The page's own
fetch of api/overview is replaced before it loads (as test_table_width.py does) by fixed rows, and api/prefs is a stand-in that keeps what the page
PUTs (window.__puts) and answers the saved choice a test gives it, so nothing is written and a test never sees another's choice.

Held here: no Project column and the project as the name's tooltip ("unregistered" for a row with no project); Surface is "sala" or "slack" for a front
agent and a dash for a back agent and a row with no role, slack in the accent colour; the plain list is the default; each button groups in its order with
the rows' counts, a lit button clicked again is the plain list; a heading is a button that says aria-expanded and folds its rows, the fold is saved; the
header's sort works inside each group; a saved grouping and its folds are drawn on load; the lane groups follow the lane cards' order; on a phone the
rows are cards, the headings are full-width and at least 40px high, and so are the group buttons. All names are invented.
"""

from __future__ import annotations

import json

from test_board_items_ui import wait_for

SLEPT = "2026-11-22T06:10:00Z"


def row(name, role, *, status="idle", lane="subscription-1", surface=None, project="alpha", model="claude-opus-5-5", effort="high", sleeping=None):
    d = {"name": name, "pid": 0 if sleeping else 1, "sessionId": name, "scope": "example", "project": ("projects/" + project) if project else None,
         "projectTitle": project or None, "role": role, "status": status, "lane": lane, "model": model, "effort": effort,
         "modelSource": "launch", "effortSource": "launch", "modelAlias": None}
    if surface:
        d["surface"] = surface
    if sleeping:
        d["sleeping"] = SLEPT
    return d


ROWS = [
    row("example-alpha-main", "front"),
    row("example-alpha-slack", "front", surface="slack", status="needs input", model="claude-sonnet-5-5", effort="low"),
    row("example-alpha-engineer", "back", model="claude-sonnet-5-5", effort="medium"),
    row("example-beta-main", "front", status="working", lane="bedrock", project="beta"),
    row("example-beta-engineer", "back", status="shell", lane="bedrock", project="beta", model="claude-fable-5-1", effort="max"),
    row("example-gamma-nap", "front", status="sleeping", lane="bedrock", project="gamma", sleeping=True),
    row("scratch-20261125-amber", "", lane="api", project=None, model="claude-haiku-5-5"),
]


def stub(rows, held) -> str:
    """The page's fetch: api/overview answers `rows`; api/prefs answers the real prefs with `held` over them and keeps a PUT (window.__puts)."""
    return """(() => {
  const rows = %s, held = %s, real = window.fetch.bind(window);
  const json = (o) => new Response(JSON.stringify(o), { headers: { "Content-Type": "application/json" } });
  window.__puts = [];
  window.fetch = (url, opts) => {
    const u = String(url);
    if (u.startsWith("api/overview")) return Promise.resolve(json({ sessions: rows, rolesError: null }));
    if (u.startsWith("api/prefs")) {
      if (opts && opts.method === "PUT") { const b = JSON.parse(opts.body); window.__puts.push(b); Object.assign(held, b); return Promise.resolve(json({ ok: true, ...held })); }
      return real(url, opts).then((r) => r.json()).then((d) => json({ ...d, ...held }));
    }
    return real(url, opts);
  };
})();""" % (json.dumps(rows), json.dumps(held))


def open_agents(browser, served, rows=ROWS, held=None, width=1280, links=None) -> None:
    """Open the Agents tab with `rows` and the saved prefs `held`. `links`: how many agent names the list draws once it is up (the rows, unless a saved fold
    hides some: a folded group draws its heading and none of its rows, so a test that opens with folds says how many are left)."""
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": stub(rows, held or {})})
    browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 900, "deviceScaleFactor": 1, "mobile": False})
    browser.send("Page.navigate", {"url": served["url"] + "/#sessions"})
    want = f"document.querySelectorAll('#sp-table tbody tr td a').length === {len(rows) if links is None else links}"
    assert wait_for(browser, f"document.readyState === 'complete' && !!({want})", 30.0)
    browser.settle("document.getElementById('overview-pane')")


# what the table shows now: for each tbody a heading (its words, its aria-expanded) and the names of the rows under it
SHOWN = """[...document.querySelectorAll('#sp-table tbody')].map((tb) => {
  const g = tb.querySelector('.ag-gh');
  return { head: g ? g.querySelector('.ag-gname').textContent : null, n: g ? g.querySelector('.ag-gn').textContent : null, open: g ? g.getAttribute('aria-expanded') : null,
           names: [...tb.querySelectorAll('tr:not(.ag-g) td:first-child a')].map((a) => a.textContent) };
})"""
PRESSED = "[...document.querySelectorAll('#ag-bar [data-by]')].map((b) => b.dataset.by + ':' + b.getAttribute('aria-pressed'))"


def click(browser, sel: str) -> None:
    assert browser.evaluate(f"(() => {{ const n = document.querySelector({json.dumps(sel)}); if (!n) return false; n.click(); return true; }})()"), sel


def puts(browser) -> list:
    return browser.evaluate("window.__puts")


def test_the_list_is_plain_by_default_with_a_surface_column_and_the_project_in_the_names_tooltip(served, browser):
    open_agents(browser, served)
    assert browser.evaluate("[...document.querySelectorAll('#sp-table th')].map((th) => th.dataset.key)") == ["name", "role", "surface", "status", "model", "effort", "lane"]
    assert browser.evaluate("document.querySelectorAll('#sp-table .ag-g').length") == 0 and len(browser.evaluate(SHOWN)) == 1
    assert browser.evaluate(PRESSED) == ["status:false", "lane:false", "role:false"]
    cells = browser.evaluate("""Object.fromEntries([...document.querySelectorAll('#sp-table tbody tr')].map((tr) => { const c = tr.children;
      return [c[0].textContent, { role: c[1].textContent, surface: c[2].textContent, cls: c[2].firstElementChild.className, color: getComputedStyle(c[2].firstElementChild).color,
                                  dash: c[2].classList.contains('ag-dash'), tip: c[0].querySelector('a').title }]; }))""")
    assert cells["example-alpha-main"]["surface"] == "sala" and cells["example-alpha-slack"]["surface"] == "slack"   # an absent surface is sala
    assert cells["example-alpha-engineer"]["surface"] == "–" and cells["example-alpha-engineer"]["dash"]       # a back agent: a dash
    assert cells["scratch-20261125-amber"]["surface"] == "–" and cells["scratch-20261125-amber"]["role"] == "none"   # no role: a dash
    accent = browser.evaluate("(() => { const s = document.createElement('span'); s.style.color = getComputedStyle(document.documentElement).getPropertyValue('--accent'); document.body.append(s); const c = getComputedStyle(s).color; s.remove(); return c; })()")
    assert cells["example-alpha-slack"]["color"] == accent != cells["example-alpha-main"]["color"], (cells["example-alpha-slack"], accent)
    # the project is the name's tooltip: scope/project; no project: the word unregistered
    assert cells["example-alpha-main"]["tip"] == "example/alpha" and cells["example-beta-main"]["tip"] == "example/beta"
    assert cells["scratch-20261125-amber"]["tip"] == "unregistered"


def test_each_button_groups_in_its_order_with_counts_and_a_lit_one_clicked_again_is_the_plain_list(served, browser):
    open_agents(browser, served)
    click(browser, "#ag-bar [data-by=status]")
    assert wait_for(browser, "document.querySelectorAll('#sp-table .ag-g').length === 5")
    assert browser.evaluate(PRESSED) == ["status:true", "lane:false", "role:false"]
    shown = browser.evaluate(SHOWN)
    assert [(g["head"], g["n"]) for g in shown] == [("needs input", "1"), ("working", "1"), ("shell", "1"), ("idle", "3"), ("sleeping", "1")]   # empty groups are left out
    assert shown[3]["names"] == ["example-alpha-main", "example-alpha-engineer", "scratch-20261125-amber"] and all(g["open"] == "true" for g in shown)
    assert wait_for(browser, "window.__puts.length && window.__puts[window.__puts.length - 1].agentsGroup === 'status'"), puts(browser)
    click(browser, "#ag-bar [data-by=role]")
    assert wait_for(browser, "document.querySelectorAll('#sp-table .ag-g').length === 3")
    assert [(g["head"], g["n"]) for g in browser.evaluate(SHOWN)] == [("front", "4"), ("back", "2"), ("no role", "1")]
    assert browser.evaluate(PRESSED) == ["status:false", "lane:false", "role:true"]
    click(browser, "#ag-bar [data-by=lane]")
    assert wait_for(browser, "document.querySelectorAll('#sp-table .ag-g').length === 3")
    lanes = browser.evaluate(SHOWN)
    assert len(lanes) == 3 and sum(int(g["n"]) for g in lanes) == len(ROWS), lanes
    # a lit button again: the plain list
    click(browser, "#ag-bar [data-by=lane]")
    assert wait_for(browser, "document.querySelectorAll('#sp-table .ag-g').length === 0")
    assert browser.evaluate(PRESSED) == ["status:false", "lane:false", "role:false"]
    assert wait_for(browser, "window.__puts[window.__puts.length - 1].agentsGroup === ''"), puts(browser)
    assert len(browser.evaluate(SHOWN)) == 1 and len(browser.evaluate(SHOWN)[0]["names"]) == len(ROWS)


def test_the_lane_groups_follow_the_lane_cards_order_and_use_the_lane_columns_names(served, browser):
    open_agents(browser, served, held={"agentsGroup": "lane"})
    assert wait_for(browser, "document.querySelectorAll('#sp-table .ag-g').length === 3")
    # the groups follow the cards as they stand, and the cards may still be redrawn by an answer that lands late: wait for the two to agree
    same = """(() => {
      const cards = [...document.querySelectorAll('#q-cards > .q-card')].map((c) => (/\\blane-([\\w-]+)/.exec(c.className) || [])[1]);
      const rank = (c) => (cards.includes(c) ? cards.indexOf(c) : cards.length);   // a lane with no card goes after the cards, in name order
      const order = ['subscription-1', 'bedrock', 'api'].sort((a, b) => rank(a) - rank(b) || (a < b ? -1 : 1)).map((code) => laneLabel(code));
      const heads = [...document.querySelectorAll('#sp-table .ag-gname')].map((n) => n.textContent);
      window.__lanes = { heads, order, cards };
      return heads.length === 3 && heads.join('|') === order.join('|');
    })()"""
    ok = wait_for(browser, same, 20.0)
    got = browser.evaluate("window.__lanes")
    assert ok, got
    assert got["heads"] == got["order"], got


def test_a_heading_folds_its_rows_is_saved_and_keeps_the_sort_inside_each_group(served, browser):
    open_agents(browser, served, held={"agentsGroup": "role"})
    assert wait_for(browser, "document.querySelectorAll('#sp-table .ag-g').length === 3")
    head = browser.evaluate("(() => { const b = document.querySelector('#sp-table .ag-gh'); return { tag: b.tagName, type: b.type, expanded: b.getAttribute('aria-expanded') }; })()")
    assert head == {"tag": "BUTTON", "type": "button", "expanded": "true"}
    # sort by effort: inside front and inside back, never across them
    browser.evaluate("document.querySelector('#sp-table th[data-key=\"effort\"] button').click()")
    shown = browser.evaluate(SHOWN)
    assert shown[0]["names"] == ["example-alpha-slack", "example-alpha-main", "example-beta-main", "example-gamma-nap"], shown[0]   # low, high, high, high (server order breaks the tie)
    assert shown[1]["names"] == ["example-alpha-engineer", "example-beta-engineer"], shown[1]                                         # medium, max
    # fold back: its rows go, the heading stays and says so, the choice is saved
    click(browser, "#sp-table .ag-gh[data-gkey='role:back']")
    assert wait_for(browser, "document.querySelector(\"#sp-table .ag-gh[data-gkey='role:back']\").getAttribute('aria-expanded') === 'false'")
    shown = browser.evaluate(SHOWN)
    assert shown[1]["names"] == [] and shown[1]["head"] == "back" and shown[1]["n"] == "2" and shown[0]["open"] == "true"
    # the save reads the server's list first and sends after: wait for the PUT
    assert wait_for(browser, "window.__puts.some((p) => Array.isArray(p.agentsFolded) && p.agentsFolded.join() === 'role:back')"), puts(browser)
    assert browser.evaluate("document.activeElement.dataset.gkey") == "role:back"   # the redraw keeps the focus on the heading
    click(browser, "#sp-table .ag-gh[data-gkey='role:back']")
    assert wait_for(browser, "document.querySelector(\"#sp-table .ag-gh[data-gkey='role:back']\").getAttribute('aria-expanded') === 'true'")
    assert len(browser.evaluate(SHOWN)[1]["names"]) == 2
    assert wait_for(browser, "window.__puts.filter((p) => Array.isArray(p.agentsFolded)).pop().agentsFolded.length === 0"), puts(browser)


def test_a_saved_grouping_and_its_folds_are_drawn_on_load(served, browser):
    open_agents(browser, served, held={"agentsGroup": "status", "agentsFolded": ["status:idle", "role:front"]}, links=len(ROWS) - 3)   # the three idle rows are folded away
    assert wait_for(browser, "document.querySelectorAll('#sp-table .ag-g').length === 5")
    shown = browser.evaluate(SHOWN)
    assert [(g["head"], g["open"]) for g in shown] == [("needs input", "true"), ("working", "true"), ("shell", "true"), ("idle", "false"), ("sleeping", "true")]
    assert shown[3]["names"] == [] and shown[3]["n"] == "3"   # a fold belongs to the way of grouping it was made in: role:front does nothing here
    assert browser.evaluate(PRESSED) == ["status:true", "lane:false", "role:false"]


def test_a_saved_value_the_page_does_not_know_is_the_plain_list(served, browser):
    open_agents(browser, served, held={"agentsGroup": "project"})
    assert browser.evaluate("document.querySelectorAll('#sp-table .ag-g').length") == 0 and browser.evaluate(PRESSED) == ["status:false", "lane:false", "role:false"]


def test_on_a_phone_the_rows_are_cards_and_the_buttons_and_headings_are_touch_sized(served, browser):
    open_agents(browser, served, held={"agentsGroup": "role"}, width=390)
    assert wait_for(browser, "document.querySelectorAll('#sp-table .ag-g').length === 3")
    m = browser.evaluate("""(() => {
      const box = (n) => { const r = n.getBoundingClientRect(); return { w: Math.round(r.width), h: Math.round(r.height) }; };
      const wrap = document.querySelector('#sp-table').parentElement, w = wrap.getBoundingClientRect().width;
      return { fold: wrap.classList.contains('fold'), header: getComputedStyle(document.querySelector('#sp-table thead')).display, wrap: w,
               chips: [...document.querySelectorAll('#ag-bar [data-by]')].map((b) => box(b).h), heads: [...document.querySelectorAll('#sp-table .ag-gh')].map(box),
               dash: [...document.querySelectorAll('#sp-table td.ag-dash')].map((c) => getComputedStyle(c).display) };
    })()""")
    assert m["fold"] and m["header"] == "none", m
    assert min(m["chips"]) >= 40 and all(h["h"] >= 40 for h in m["heads"]), m
    assert all(h["w"] >= m["wrap"] - 2 for h in m["heads"]), m   # a heading is the card's full width
    assert set(m["dash"]) == {"none"}, m                         # a card leaves the dash out
