"""The Overview's Usage analysis tab in a browser (static/usage.js, usage.css, the tab and panel in index.html, app.js's tab routing), at a phone's
width (390) and a desktop's (1280): the tab shell with its three views (Explorer has its own file, test_usage_explorer_ui.py), and the Report view over a made-up set of transcripts (the page reads the real
api/usage, which counts fake transcripts and a fake registry written to the test's temporary folder; nothing reaches Anthropic or AWS and no real
transcript of this box is read: conftest.py points the second login's folders at none).

What a wrong answer costs: a tab that is not reachable by its link, Back or the keyboard, a Report that shows a different sum than the rows add up
to, a filter that leaves the total or the table unfiltered, a week switch that keeps the old week's figures, a token count on a page that shows dollars
only, a phone that scrolls sideways or has a control too small to hit, an error in the page's console, markup built from data (an agent named
`<img onerror=…>` must stay text).

The page runs in a headless Chromium when one is installed (conftest.py: `served`, `browser`), else skipped. Set SALA_USAGE_SHOTS to a folder to leave
a screenshot of each width there.
"""

from __future__ import annotations

import base64
import json
import os
import time
import urllib.request

import pytest

from test_usage import A, B, C, reply, prompt, World   # noqa: F401  (the fake transcripts and registry are the data layer's own)

SHOTS = os.environ.get("SALA_USAGE_SHOTS")
DESKTOP = {"width": 1280, "height": 1600, "deviceScaleFactor": 1, "mobile": False}
PHONE = {"width": 390, "height": 844, "deviceScaleFactor": 1, "mobile": True}
COUNT = """(() => { const real = window.fetch.bind(window); window.__usFetches = 0;
  window.fetch = (url, opts) => { if (String(url).startsWith("api/usage")) window.__usFetches++; return real(url, opts); }; })();"""
EVIL = '<img src=x onerror="window.__pwned=1">'


def wait(browser, expr: str, what: str, ms: int = 15000):
    v = browser.evaluate("""new Promise((res) => { const t0 = Date.now(); (function poll() {
      let v; try { v = (%s); } catch (e) { v = null; }
      if (v || Date.now() - t0 > %d) res(v || null); else setTimeout(poll, 100); })(); })""" % (expr, ms))
    assert v, what
    return v


def world_of(served: dict) -> World:
    """test_usage.World over the served app's own folders (its claude dir, sala state dir and state dir)."""
    s = served["settings"]
    s.sala_state_dir.mkdir(parents=True, exist_ok=True)
    w = World.__new__(World)
    w.claude, w.sala, w.state, w.settings, w.rows, w.holder = s.claude_dir, s.sala_state_dir, s.state_dir, s, [], {}
    return w


def fake_replies(served: dict):
    """Three replies this week on two lanes and one last week, written to the served app's own folders (the sala registry too):
    $10 + $5 (sonnet, subscription-1, the first agent), $5 (opus, bedrock, the second) and $3 a week back."""
    w = world_of(served)
    w.registry("example-alpha-build", A, lane="subscription-1")
    w.registry("example-beta-main", B, lane="bedrock")
    w.registry(EVIL, C, lane="subscription-1")
    now = time.time()
    w.transcript(A, prompt(now - 3600, cwd="/work/example-repo"), reply("a1", "claude-sonnet-5-5", now - 3600, out=1_000_000),
                 reply("a2", "claude-sonnet-5-5", now - 2 * 86400, out=500_000), reply("a3", "claude-sonnet-5-5", now - 9 * 86400, out=300_000), mtime=now)
    w.transcript(B, prompt(now - 3 * 3600, cwd="/work/other-repo"), reply("b1", "claude-opus-5", now - 3 * 3600, out=200_000), mtime=now, proj="-work-other-repo")
    return now


def warm(served: dict) -> None:
    """A fresh server has no count (a visit makes none: the daily job and the tab's Reload do): make one the way Reload does (`fresh=1`) and wait
    for it, so the page opens on figures."""
    fresh = ""
    for _ in range(100):
        with urllib.request.urlopen(served["url"] + "/api/usage?week=0" + fresh) as r:
            d = json.load(r)
        fresh = ""
        if d.get("noCount"):
            fresh = "&fresh=1"
        elif not d.get("pending") and not d.get("refreshing"):
            return
        time.sleep(0.1)
    raise AssertionError(f"the count never finished: { {k: d.get(k) for k in ('noCount', 'pending', 'refreshing', 'error', 'stale')} }")


def open_tab(served, browser, size: dict, hash_: str = "#usage", ready: bool = True) -> None:
    fake_replies(served)
    warm(served)
    browser.send("Page.enable")
    browser.send("Runtime.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": COUNT})
    browser.open(f"{served['url']}/{hash_}", dark=True)
    browser.send("Emulation.setDeviceMetricsOverride", size)
    if ready:
        wait(browser, 'document.querySelectorAll("#us-tbody tr[data-k]").length > 0', "the Report's table")
    else:
        wait(browser, 'document.querySelector("#overview-pane") && document.body.classList.contains("overview-open")', "the Overview")


def shown(browser) -> dict:
    return browser.evaluate("""(() => { const t = (n) => n.textContent.replace(/\\s+/g, " ").trim(), q = (s) => document.querySelector(s);
      return {
        tab: q("#overview-pane").dataset.tab, hash: location.hash,
        views: [...document.querySelectorAll("#us-views button")].map((b) => [t(b), b.getAttribute("aria-selected")]),
        weeks: [...document.querySelectorAll("#us-weeks button")].map((b) => [t(b), b.getAttribute("aria-pressed")]),
        range: t(q("#us-range")), hero: q("#us-hero .us-big").firstChild.textContent.trim(), sub: t(q("#us-hero .us-sub")), flt: !!q("#us-hero .us-flt"),
        lanes: [...document.querySelectorAll("#us-lanes .us-lane")].map((c) => [t(c.querySelector(".us-pill")), t(c.querySelector(".us-amt")), t(c.querySelector(".us-sm")), c.getAttribute("aria-pressed")]),
        group: [...document.querySelectorAll("#us-group button")].map((b) => [t(b), b.getAttribute("aria-pressed")]),
        chips: [...document.querySelectorAll("#us-filters .us-chip")].map(t),
        ctitle: t(q("#us-ctitle")), bars: document.querySelectorAll("#us-plot rect[data-d]").length,
        head: [...document.querySelectorAll("#us-thead th")].map(t),
        rows: [...document.querySelectorAll("#us-tbody tr[data-k]")].map((r) => [r.dataset.k, t(r.querySelector(".us-nm")), t(r.querySelector("td.r")), r.classList.contains("us-on")]),
        notes: t(q("#us-notes")), upd: t(q("#us-upd")), note: t(q("#us-note")),
        panel: t(q("#ov-usage")),
      }; })()""")


def errors(browser) -> list:
    out = []
    for e in browser.events:
        if e.get("method") == "Runtime.exceptionThrown":
            out.append(e["params"]["exceptionDetails"].get("text", "exception"))
        elif e.get("method") == "Runtime.consoleAPICalled" and e["params"].get("type") in ("error", "assert"):
            out.append(" ".join(str(a.get("value", a.get("description", ""))) for a in e["params"].get("args", [])))
    return out


def click(browser, sel: str) -> None:
    browser.evaluate(f"document.querySelector({json.dumps(sel)}).click(); ''")


def screenshot(browser, name: str, height: int = 2400) -> None:
    if SHOTS:
        os.makedirs(SHOTS, exist_ok=True)
        size = browser.evaluate("[innerWidth, innerHeight]")
        browser.send("Emulation.setDeviceMetricsOverride", {"width": size[0], "height": height, "deviceScaleFactor": 1, "mobile": size[0] < 600})
        with open(os.path.join(SHOTS, name), "wb") as f:
            f.write(base64.b64decode(browser.send("Page.captureScreenshot", {"format": "png"})["data"]))


# ── the shell ────────────────────────────────────────────────────────────────
def test_the_markup_has_the_tab_after_machines_its_panel_its_files_and_the_hash_registered_in_app_js():
    import re
    from sala_web.app import STATIC
    html = (STATIC / "index.html").read_text()
    assert re.search(r'<a id="ov-tab-usage"[^>]*href="#usage"[^>]*aria-selected="false"', html)
    assert re.findall(r'<a id="ov-tab-(\w+)"', html)[-1] == "usage"
    assert "Usage analysis" in html and 'id="ov-usage"' in html and 'id="us-reload"' in html
    assert 'href="static/usage.css?v={{v}}"' in html and 'src="static/usage.js?v={{v}}"' in html
    js = (STATIC / "app.js").read_text()
    assert "usageHash" in js and "usage.start()" in js and "usage.stop()" in js and '"usage"' in js


def test_the_tab_opens_on_its_link_with_the_report_first_explorer_and_digest_built(served, browser):
    open_tab(served, browser, DESKTOP)
    m = shown(browser)
    assert m["tab"] == "usage" and m["hash"] == "#usage"
    assert m["views"] == [["Report", "true"], ["Explorer", "false"], ["Digest", "false"]]
    click(browser, '#us-views [data-v="explorer"]')
    assert browser.evaluate('[document.querySelector("#us-v-report").hidden, document.querySelector("#us-v-explorer").hidden, document.querySelector("#us-v-digest").hidden]') == [True, False, True]
    assert "coming next" not in browser.evaluate('document.querySelector("#us-v-explorer").textContent')      # Explorer is built (test_usage_explorer_ui.py)
    click(browser, '#us-views [data-v="digest"]')
    assert browser.evaluate('[document.querySelector("#us-v-report").hidden, document.querySelector("#us-v-explorer").hidden, document.querySelector("#us-v-digest").hidden]') == [True, True, False]
    assert "coming next" not in browser.evaluate('document.querySelector("#us-v-digest").textContent')   # the Digest is built (test_usage_digest_ui.py)
    browser.evaluate("""document.querySelector("#us-views").dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true })); ''""")   # Digest → Report: the arrows wrap
    wait(browser, 'document.querySelector("#us-v-report").hidden === false', "ArrowRight wraps to Report")
    assert [v[1] for v in shown(browser)["views"]] == ["true", "false", "false"]
    assert errors(browser) == []


def test_the_tab_reads_when_it_opens_and_on_reload_and_the_other_tabs_never_read_it(served, browser):
    open_tab(served, browser, DESKTOP, "#sessions", ready=False)
    wait(browser, '!!document.querySelector("#sp-table")', "the Agents tab")
    browser.evaluate("new Promise((r) => setTimeout(r, 800))")
    assert browser.evaluate("window.__usFetches") == 0                                      # not read, not shown
    click(browser, "#ov-tab-usage")
    wait(browser, 'document.querySelectorAll("#us-tbody tr[data-k]").length > 0', "the table after the tab opened")
    assert browser.evaluate("location.hash") == "#usage" and browser.evaluate("window.__usFetches") == 1
    click(browser, "#us-reload")
    wait(browser, "window.__usFetches === 2", "Reload reads again")
    click(browser, "#ov-tab-sessions")
    browser.evaluate("new Promise((r) => setTimeout(r, 800))")
    assert browser.evaluate("window.__usFetches") == 2 and browser.evaluate('document.querySelector("#ov-usage").offsetParent') is None


# ── the Report ───────────────────────────────────────────────────────────────
def test_the_report_shows_the_total_the_lanes_and_the_notes_in_dollars_and_never_a_token(served, browser):
    open_tab(served, browser, DESKTOP)
    m = shown(browser)
    assert m["weeks"] == [["This week", "true"], ["Previous week", "false"], ["2 weeks ago", "false"]]
    assert m["hero"] == "$20.00" and m["sub"] == "at list prices · about $5.00 billed · 3 replies", m
    assert m["lanes"] == [["subscription-1", "$15.00", "flat plan, not billed · at list prices", "false"],
                          ["bedrock", "$5.00", "billed per use (estimate)", "false"]], m["lanes"]
    assert m["group"] == [["Day", "false"], ["Lane", "true"], ["Model", "false"], ["Project", "false"], ["Agent", "false"], ["Folder", "false"]]
    assert m["head"][0] == "Lane" and "Cost" in " ".join(m["head"]) and m["bars"] == 8, m
    assert [r[2] for r in m["rows"]] == ["$15.00", "$5.00"]
    assert "Other machines are not counted: only this machine's sessions." in m["notes"]
    assert "Prices are list prices per million tokens, copied from sala's price table. As of " in m["notes"]
    assert "token" not in m["panel"].replace("Prices are list prices per million tokens", "").lower(), "the page shows dollars, never a token count"
    assert m["upd"].startswith("counted ") and "the last seven days" in m["range"], m                  # no weekly reset is known here (no quota answer)
    assert errors(browser) == []
    screenshot(browser, "usage-1280.png")


@pytest.mark.parametrize("group,expected", [
    ("day", None),
    ("lane", [("subscription-1", "$15.00"), ("bedrock", "$5.00")]),
    ("model", [("claude-sonnet-5-5", "$15.00"), ("claude-opus-5", "$5.00")]),
    ("project", [("example-alpha", "$15.00"), ("example-beta", "$5.00")]),
    ("agent", [("example-alpha-build", "$15.00"), ("example-beta-main", "$5.00")]),
    ("folder", [("/work/example-repo", "$15.00"), ("/work/other-repo", "$5.00")]),
])
def test_group_by_changes_the_chart_and_the_table_and_every_grouping_adds_up_to_the_total(served, browser, group, expected):
    open_tab(served, browser, DESKTOP)
    click(browser, f'#us-group [data-g="{group}"]')
    wait(browser, f'document.querySelector("#us-group [data-g={group}]").getAttribute("aria-pressed") === "true"', "the grouping is on")
    m = shown(browser)
    rows = [(r[0], r[2]) for r in m["rows"]]
    if expected is None:                                                                     # by day: one row per day with replies, summing to the total
        assert sum(float(r[1][1:]) for r in rows) == pytest.approx(20.0) and len(rows) >= 2
        assert m["ctitle"] == "COST BY DAY"
    else:
        assert rows == expected, rows
        assert m["ctitle"] == "COST BY DAY, STACKED BY " + group.upper()
    assert m["hero"] == "$20.00"                                                             # the grouping never changes the total
    assert errors(browser) == []


def test_a_name_from_a_transcript_registry_is_text_never_markup(served, browser):
    now = time.time()
    open_tab(served, browser, DESKTOP)   # the registry already names a session after the markup; it has no reply yet: give it one
    w = world_of(served)
    w.transcript(C, reply("c1", "claude-sonnet-5-5", now - 600, out=100_000), mtime=now)
    click(browser, "#us-reload")
    click(browser, '#us-group [data-g="agent"]')
    wait(browser, '[...document.querySelectorAll("#us-tbody .us-nm")].some((n) => n.textContent.includes("onerror"))', "the markup-like name in the table")
    m = browser.evaluate('({ pwned: window.__pwned || 0, imgs: document.querySelectorAll("#ov-usage img").length })')
    assert m == {"pwned": 0, "imgs": 0}, m


def test_a_tap_on_a_lane_card_filters_the_total_the_chart_and_the_table_and_a_chip_or_the_card_clears_it(served, browser):
    open_tab(served, browser, DESKTOP)
    click(browser, '#us-lanes .us-lane[data-k="bedrock"]')
    wait(browser, 'document.querySelectorAll("#us-filters .us-chip").length === 1', "the filter chip")
    m = shown(browser)
    assert m["hero"] == "$5.00" and m["flt"] and m["sub"] == "at list prices · about $5.00 billed · 1 replies", m
    assert [r[2] for r in m["rows"]] == ["$5.00"] and len(m["chips"]) == 1 and m["chips"][0].startswith("Lane:")
    assert sorted(c[3] for c in m["lanes"]) == ["false", "true"]
    assert len(m["lanes"]) == 2, "the other lane's card stays, so the filter can be changed from it"
    click(browser, "#us-filters .us-chip")
    wait(browser, 'document.querySelectorAll("#us-filters .us-chip").length === 0', "the chip is gone")
    m = shown(browser)
    assert m["hero"] == "$20.00" and not m["flt"] and len(m["rows"]) == 2
    click(browser, '#us-lanes .us-lane[data-k="bedrock"]')
    click(browser, '#us-lanes .us-lane[data-k="bedrock"]')                                  # a second tap on the same card clears it
    assert shown(browser)["hero"] == "$20.00"
    assert errors(browser) == []


def test_a_tap_on_a_table_row_a_day_in_the_chart_and_a_key_name_each_filter_and_clear_all_empties_them(served, browser):
    open_tab(served, browser, DESKTOP)
    click(browser, '#us-group [data-g="agent"]')
    click(browser, '#us-tbody tr[data-k="example-beta-main"]')
    wait(browser, 'document.querySelectorAll("#us-filters .us-chip").length === 1', "the row's chip")
    m = shown(browser)
    assert m["hero"] == "$5.00" and [(r[1], r[3]) for r in m["rows"]] == [("example-beta-main", True)], m
    day = browser.evaluate("""(() => { const rs = [...document.querySelectorAll("#us-plot rect[data-d]")]; return rs.map((r) => r.dataset.d); })()""")
    assert len(day) == 8
    # a day with no reply from the selected agent filters to nothing; its bar is tapped, then cleared by a second tap
    click(browser, '#us-filters .us-chip')
    now = time.time()
    today = time.strftime("%Y-%m-%d", time.gmtime(now + 9 * 3600))
    browser.evaluate(f'document.querySelector("#us-plot rect[data-d=\\"{today}\\"]").dispatchEvent(new MouseEvent("click", {{ bubbles: true }})); ""')
    wait(browser, 'document.querySelectorAll("#us-filters .us-chip").length === 1', "the day's chip")
    assert shown(browser)["chips"][0].startswith("Day:")
    click(browser, '#us-legend span')                                                        # a key name filters by the grouping (agent) as well: two chips, so "Clear all"
    wait(browser, 'document.querySelectorAll("#us-filters .us-chip").length === 3', "the key's chip and Clear all")
    click(browser, "#us-filters .us-clear")
    wait(browser, 'document.querySelectorAll("#us-filters .us-chip").length === 0', "all cleared")
    assert shown(browser)["hero"] == "$20.00" and errors(browser) == []


def test_the_table_sorts_by_a_column_and_flips_on_a_second_tap(served, browser):
    open_tab(served, browser, DESKTOP)
    assert [r[0] for r in shown(browser)["rows"]] == ["subscription-1", "bedrock"]               # by cost, largest first
    click(browser, '#us-thead [data-s="k"]')                                                    # by name, A to Z (the lane's shown name)
    first = [r[1] for r in shown(browser)["rows"]]
    assert first == sorted(first, key=str.lower)
    click(browser, '#us-thead [data-s="k"]')
    assert [r[1] for r in shown(browser)["rows"]] == sorted(first, key=str.lower, reverse=True)
    assert browser.evaluate('document.querySelector("#us-thead th[aria-sort=descending], #us-thead th[aria-sort=ascending]").textContent.trim()') == "Lane"


def test_a_week_switch_asks_again_and_shows_that_weeks_figures_and_clears_the_filters(served, browser):
    open_tab(served, browser, DESKTOP)
    click(browser, '#us-lanes .us-lane[data-k="bedrock"]')
    wait(browser, 'document.querySelectorAll("#us-filters .us-chip").length === 1', "the chip")
    before = browser.evaluate("window.__usFetches")
    click(browser, '#us-weeks [data-w="1"]')
    wait(browser, 'document.querySelector("#us-hero .us-big").textContent.trim() === "$3.00"', "last week's total")
    m = shown(browser)
    assert m["weeks"][1] == ["Previous week", "true"] and m["chips"] == [] and not m["flt"], m          # a filter of one week does not carry to the next
    assert m["sub"] == "at list prices · about $0.00 billed · 1 replies" and [r[2] for r in m["rows"]] == ["$3.00"], m
    assert browser.evaluate("window.__usFetches") == before + 1
    click(browser, '#us-weeks [data-w="2"]')
    wait(browser, 'document.querySelector("#us-hero .us-big").textContent.trim() === "$0.00"', "the empty week")
    assert shown(browser)["rows"] == [] and "Nothing in this selection." in shown(browser)["panel"]
    click(browser, '#us-weeks [data-w="0"]')
    wait(browser, 'document.querySelector("#us-hero .us-big").textContent.trim() === "$20.00"', "this week again")
    assert errors(browser) == []


def test_a_failed_read_keeps_the_last_figures_and_says_so(served, browser):
    open_tab(served, browser, DESKTOP)
    browser.evaluate("""(() => { const real = window.fetch.bind(window);
      window.fetch = (url, opts) => String(url).startsWith("api/usage") ? Promise.resolve(new Response("nope", { status: 500 })) : real(url, opts); })(); ''""")
    click(browser, "#us-reload")
    wait(browser, 'document.querySelector("#us-note").textContent.startsWith("Could not read the usage")', "the note")
    m = shown(browser)
    assert m["hero"] == "$20.00" and "the server answered 500" in m["note"], m


# ── the layout ───────────────────────────────────────────────────────────────
@pytest.mark.parametrize("size,name", [(DESKTOP, "desktop"), (PHONE, "phone")])
def test_the_layout_never_scrolls_sideways_and_a_phone_has_44px_targets_and_four_tabs_in_one_bar(served, browser, size, name):
    open_tab(served, browser, size)
    for g in ("agent", "folder", "model", "day", "lane"):                                       # the widest names are the likeliest to push the page
        click(browser, f'#us-group [data-g="{g}"]')
    m = browser.evaluate("""(() => { const vw = document.documentElement.clientWidth, r = (n) => n.getBoundingClientRect();
      const over = [...document.querySelectorAll("#ov-usage *")].filter((n) => r(n).right > vw + 0.5 && n.getClientRects().length && !n.closest(".us-tw, .us-seg, .us-pw")).map((n) => n.className || n.tagName);
      const small = [...document.querySelectorAll("#ov-usage button, #us-reload, .ov-tab, #us-tbody tr")].filter((n) => n.getClientRects().length && r(n).height < 43.5).map((n) => (n.id || n.className || n.tagName) + ":" + Math.round(r(n).height));
      return { vw, doc: document.documentElement.scrollWidth, body: document.body.scrollWidth, pane: document.querySelector("#overview-pane").scrollWidth,
               paneClient: document.querySelector("#overview-pane").clientWidth, over, small,
               tabs: [...document.querySelectorAll(".ov-tab")].map((a) => a.textContent.trim().replace(/\\s+/g, " ")),
               bar: [document.querySelector(".ov-bar").scrollWidth, document.querySelector(".ov-bar").clientWidth],
               lastRight: Math.round(r(document.querySelector("#ov-tab-usage")).right), reload: [Math.round(r(document.querySelector("#us-reload")).left), Math.round(r(document.querySelector("#us-reload")).width)],
               clipped: [...document.querySelectorAll(".ov-tab")].filter((a) => a.scrollWidth > a.clientWidth + 1).map((a) => a.id),
               lanes: new Set([...document.querySelectorAll("#us-lanes .us-lane")].map((c) => Math.round(r(c).top))).size,
               cols: [...document.querySelectorAll("#us-thead th")].filter((th) => th.getClientRects().length).length }; })()""")
    assert m["doc"] <= m["vw"] and m["body"] <= m["vw"] + 1 and m["pane"] <= m["paneClient"], m      # no sideways scroll
    assert m["over"] == [], m["over"]
    assert m["bar"][0] <= m["bar"][1] and m["tabs"][1:] == ["Schedules", "Machines", "Usage analysis"], m                 # four tabs and the Reload fit the bar
    assert m["lastRight"] <= m["reload"][0] and m["clipped"] == [], m                              # the Reload sits beside the last tab, never over it
    if name == "phone":
        assert m["small"] == [], m["small"]                                                         # every control a comfortable target
        assert m["lanes"] == 2 and m["cols"] == 2, m                                                # one card to a line; the table keeps its name and its cost
    else:
        assert m["lanes"] == 1 and m["cols"] == 5, m                                                # the lane cards side by side; all five columns
    assert errors(browser) == []
    screenshot(browser, f"usage-{size['width']}.png", 3000)
