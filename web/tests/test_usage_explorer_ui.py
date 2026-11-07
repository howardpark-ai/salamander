"""The Usage analysis tab's Explorer view in a browser (static/usage-explorer.js, usage-explorer.css, the panel in index.html, the replies route), at a phone's
width (390) and a desktop's (1280), over the same made-up transcripts as the Report's tests (the page reads the real api/usage and api/usage/replies, which count
fake transcripts and a fake registry written to the test's temporary folder; nothing reaches Anthropic or AWS and no real transcript of this box is read).

What a wrong answer costs: two sides that do not add up to the Report, an A and a B swapped or mixed up, a filter that narrows one side and not the other, a
break-down whose rows do not sum to the side, a tap on a row whose replies are not the replies of that row and that side, a list of replies that is not capped or
does not say how many there are, a flat-plan figure that is not labelled "not billed" or that counts as billed, a token count on a page of dollars, a view that
reads the server when it is not on screen, a phone that scrolls sideways or has a control too small to hit, markup built from data (an agent named
`<img onerror=...>` must stay text), and an error in the page's console.

The page runs in a headless Chromium when one is installed (conftest.py: `served`, `browser`), else skipped. Set SALA_USAGE_SHOTS to a folder to leave a screenshot
of each width there.
"""

from __future__ import annotations

import json
import time

import pytest

from test_usage import A, B, C, D, prompt, reply   # noqa: F401  (the fake transcripts and registry are the data layer's own)
from test_usage_ui import DESKTOP, EVIL, PHONE, click, errors, fake_replies, open_tab, screenshot, wait, warm, world_of


def open_explorer(served, browser, size: dict = DESKTOP, hash_: str = "#usage") -> None:
    open_tab(served, browser, size, hash_)
    click(browser, '#us-views [data-v="explorer"]')
    wait(browser, 'document.querySelectorAll("#ex-tbody tr[data-k]").length > 0', "the Explorer's table")


def select(browser, sel: str, value: str) -> None:
    browser.evaluate(f"""(() => {{ const s = document.querySelector({json.dumps(sel)}); s.value = {json.dumps(value)}; s.dispatchEvent(new Event("change", {{ bubbles: true }})); return ""; }})()""")


def shown(browser) -> dict:
    return browser.evaluate("""(() => { const t = (n) => n ? n.textContent.replace(/\\s+/g, " ").trim() : null, q = (s) => document.querySelector(s), qa = (s) => [...document.querySelectorAll(s)];
      const opt = (s) => qa(s + " option").map((o) => [o.value, t(o), o.selected]);
      return {
        tab: q("#overview-pane").dataset.tab, hidden: q("#us-v-explorer").hidden, views: qa("#us-views button").map((b) => [t(b), b.getAttribute("aria-selected")]),
        cmp: qa("#ex-cmp button").map((b) => [t(b), b.getAttribute("aria-pressed")]), by: qa("#ex-by button").map((b) => [t(b), b.getAttribute("aria-pressed")]),
        a: opt("#ex-sa"), b: opt("#ex-sb"),
        filters: qa(".ex-f select").map((s) => [s.dataset.f, s.value, [...s.options].length]),
        clear: !!q("[data-clear]"), range: t(q(".ex-range")), note: t(q("#ex-note")),
        sides: qa(".ex-side").map((c) => [t(c.querySelector(".ex-sn")), t(c.querySelector(".ex-amt")), t(c.querySelector(".us-sub")), t(c.querySelector(".ex-lane")), t(c.querySelector(".ex-delta"))]),
        head: qa("#ex-thead th").map((th) => [t(th), th.getAttribute("aria-sort")]),
        rows: qa("#ex-tbody tr[data-k]").map((r) => [r.dataset.k, t(r.querySelector(".ex-nm")), [...r.querySelectorAll("td.r b")].map(t), t(r.querySelector("td.ex-d")), r.classList.contains("us-on"), !!r.querySelector(".ex-nb")]),
        replies: q("#ex-replies").hidden ? null : { head: t(q("#ex-replies .ex-rh")), sum: t(q(".ex-rsum")), msg: t(q(".ex-rmsg")),
          side: qa("#ex-replies [data-rside]").map((b) => [b.dataset.rside, t(b), b.getAttribute("aria-pressed")]),
          rows: qa("#ex-replies .ex-rt tbody tr").map((r) => [...r.children].map((c) => c.innerText.replace(/\\s+/g, " ").trim())) },
        notes: t(q("#ex-notes")), upd: t(q("#ex-upd")), panel: t(q("#us-v-explorer")), fetches: window.__usFetches,
      }; })()""")


def sums(m: dict) -> tuple[float, float]:
    """The dollars of the A column and of the B column of the table."""
    return (sum(float(r[2][0][1:].replace(",", "")) for r in m["rows"]), sum(float(r[2][1][1:].replace(",", "")) for r in m["rows"]))


# ── the view ─────────────────────────────────────────────────────────────────
def test_the_markup_has_the_explorer_panel_its_files_and_usage_js_has_the_view_hook():
    from sala_web.app import STATIC
    html = (STATIC / "index.html").read_text()
    assert 'href="static/usage-explorer.css?v={{v}}"' in html and 'src="static/usage-explorer.js?v={{v}}"' in html
    assert html.index("static/usage.js?") < html.index("static/usage-explorer.js?"), "usage.js first: Explorer registers itself with it"
    for i in ("ex-ctl", "ex-body", "ex-sides", "ex-table", "ex-replies", "ex-notes", "ex-note", "ex-upd"):
        assert f'id="{i}"' in html
    assert "usageExplorer" not in (STATIC / "usage.js").read_text(), "the two files meet at registerView only"
    assert "registerView" in (STATIC / "usage.js").read_text() and "registerView" in (STATIC / "usage-explorer.js").read_text()


def test_the_explorer_opens_from_the_views_control_compares_the_two_costliest_lanes_and_reads_nothing_while_it_is_not_on_screen(served, browser):
    open_tab(served, browser, DESKTOP)
    browser.evaluate("new Promise((r) => setTimeout(r, 600))")
    assert browser.evaluate("window.__usFetches") == 1, "the Report alone reads: the Explorer is not on screen"
    click(browser, '#us-views [data-v="explorer"]')
    wait(browser, 'document.querySelectorAll("#ex-tbody tr[data-k]").length > 0', "the Explorer's table")
    m = shown(browser)
    assert m["hidden"] is False and m["views"][1] == ["Explorer", "true"] and "coming next" not in m["panel"]
    assert browser.evaluate("window.__usFetches") == 2, "one read when it opened"
    click(browser, '#us-views [data-v="report"]')
    browser.evaluate("new Promise((r) => setTimeout(r, 800))")
    assert browser.evaluate("window.__usFetches") == 2 and errors(browser) == []


def test_the_default_comparison_is_the_two_costliest_lanes_in_dollars_with_the_flat_plan_not_billed_and_no_token_on_the_page(served, browser):
    open_explorer(served, browser)
    m = shown(browser)
    assert m["cmp"] == [["Week", "false"], ["Day", "false"], ["Lane", "true"], ["Model", "false"], ["Project", "false"], ["Agent", "false"], ["Folder", "false"]], m["cmp"]
    assert [x[0] for x in m["a"] if x[2]] == ["subscription-1"] and [x[0] for x in m["b"] if x[2]] == ["bedrock"], (m["a"], m["b"])
    assert m["sides"][0][:4] == ["subscription-1", "$15.00", "at list prices · about $0.00 billed · 2 replies", "flat plan, not billed · at list prices"], m["sides"]
    assert m["sides"][1][:4] == ["bedrock", "$5.00", "at list prices · about $5.00 billed · 1 replies", "billed per use (estimate)"], m["sides"]
    assert m["sides"][1][4] == "-67% vs A (−$10.00)", m["sides"][1]
    assert [b[0] for b in m["by"]] == ["Day", "Model", "Project", "Agent", "Folder"] and [b[0] for b in m["by"] if b[1] == "true"] == ["Model"], m["by"]
    assert [(r[0], r[1], r[2]) for r in m["rows"]] == [("claude-sonnet-5-5", "Sonnet 5.5", ["$15.00", "$0.00"]), ("claude-opus-5", "Opus 5", ["$0.00", "$5.00"])], m["rows"]
    assert sums(m) == (15.0, 5.0)
    assert "Other machines are not counted: only this machine's sessions." in m["notes"]
    assert "Prices are list prices per million tokens, copied from sala's price table." in m["notes"]
    assert m["upd"].startswith("counted "), m["upd"]
    assert "token" not in m["panel"].replace("Prices are list prices per million tokens", "").lower(), "the page shows dollars, never a token count"
    assert errors(browser) == []
    screenshot(browser, "usage-explorer-1280.png")


@pytest.mark.parametrize("cmp,a,b", [
    ("model", "claude-sonnet-5-5", "claude-opus-5"),
    ("agent", "example-alpha-build", "example-beta-main"),
])
def test_each_dimension_compares_its_two_costliest_values_and_both_sides_add_up_to_their_table_columns(served, browser, cmp, a, b):
    open_explorer(served, browser)
    click(browser, f'#ex-cmp [data-c="{cmp}"]')
    wait(browser, f'document.querySelector("#ex-cmp [data-c={cmp}]").getAttribute("aria-pressed") === "true"', "the dimension is on")
    m = shown(browser)
    assert [x[0] for x in m["a"] if x[2]] == [a] and [x[0] for x in m["b"] if x[2]] == [b], (m["a"], m["b"])
    assert [s[1] for s in m["sides"]] == ["$15.00", "$5.00"], m["sides"]
    assert sums(m) == (15.0, 5.0), "the break-down adds up to its side"
    assert cmp not in [x[0].lower() for x in m["by"]] and sum(x[1] == "true" for x in m["by"]) == 1, "the compared dimension is not a break-down, and one break-down is on"
    assert errors(browser) == []


def test_comparing_the_dimension_that_is_the_break_down_moves_the_break_down_and_comparing_days_picks_the_two_latest(served, browser):
    open_explorer(served, browser)
    click(browser, '#ex-by [data-b="project"]')
    assert [b[0] for b in shown(browser)["by"] if b[1] == "true"] == ["Project"]
    click(browser, '#ex-cmp [data-c="project"]')
    m = shown(browser)
    assert [b[0] for b in m["by"]] == ["Day", "Lane", "Model", "Agent", "Folder"], "the compared dimension is not a break-down"
    assert sum(b[1] == "true" for b in m["by"]) == 1
    click(browser, '#ex-cmp [data-c="day"]')
    m = shown(browser)
    a, b = [x[0] for x in m["a"] if x[2]][0], [x[0] for x in m["b"] if x[2]][0]
    days = sorted({x[0] for x in m["a"] if x[0]}, reverse=True)
    assert (a, b) == (days[0], days[1]), "A is the latest day with replies, B the one before"
    assert errors(browser) == []


def test_changing_a_or_b_changes_that_side_and_its_column_and_a_none_leaves_the_card_empty(served, browser):
    open_explorer(served, browser)
    select(browser, "#ex-sa", "bedrock")
    select(browser, "#ex-sb", "subscription-1")
    m = shown(browser)
    assert [s[1] for s in m["sides"]] == ["$5.00", "$15.00"] and sums(m) == (5.0, 15.0), m["sides"]
    assert m["sides"][1][4] == "+200% vs A (+$10.00)", m["sides"][1]
    select(browser, "#ex-sb", "")
    m = shown(browser)
    assert len(m["sides"]) == 2 and "Nothing to compare" in browser.evaluate('document.querySelectorAll(".ex-side")[1].textContent'), m["sides"]
    assert sums(m)[1] == 0 and errors(browser) == []


def test_a_where_filter_narrows_both_sides_and_the_break_down_and_clear_filters_removes_it(served, browser):
    open_explorer(served, browser)
    assert shown(browser)["clear"] is False
    select(browser, "#ex-f-agent", "example-alpha-build")
    m = shown(browser)
    assert [s[1] for s in m["sides"]] == ["$15.00", "$0.00"] and sums(m) == (15.0, 0.0) and m["clear"] is True, m["sides"]
    assert {f[0]: f[1] for f in m["filters"]}["agent"] == "example-alpha-build"
    assert [o for o in browser.evaluate('[...document.querySelectorAll("#ex-f-model option")].map((o) => o.value)')] == ["", "claude-sonnet-5-5"], "the other filters offer only what the first leaves"
    click(browser, "[data-clear]")
    m = shown(browser)
    assert [s[1] for s in m["sides"]] == ["$15.00", "$5.00"] and m["clear"] is False
    assert "lane" not in [f[0] for f in m["filters"]], "the compared dimension is not a filter"
    assert errors(browser) == []


def test_comparing_weeks_reads_both_weeks_and_shows_each_weeks_figures(served, browser):
    open_explorer(served, browser)
    click(browser, '#ex-cmp [data-c="week"]')
    wait(browser, '[...document.querySelectorAll(".ex-side .ex-amt")].map((n) => n.textContent.trim()).join() === "$20.00,$3.00"', "this week against the previous week")
    m = shown(browser)
    assert sums(m) == (20.0, 3.0), m["sides"]
    assert "week" not in [f[0] for f in m["filters"]], "no week filter while weeks are compared"
    assert errors(browser) == []


def test_the_week_filter_picks_the_week_of_the_comparison(served, browser):
    open_explorer(served, browser)
    select(browser, "#ex-f-week", "1")
    wait(browser, '[...document.querySelectorAll(".ex-side .ex-amt")].map((n) => n.textContent.trim()).join() === "$3.00,$0.00"', "last week's figures")
    assert shown(browser)["rows"][0][2] == ["$3.00", "$0.00"] and errors(browser) == []


# ── down to a single reply ───────────────────────────────────────────────────
DATE = r"^[A-Z][a-z]{2} [A-Z][a-z]{2} \d{1,2}(st|nd|rd|th) \d\d:\d\d:\d\d$"


def test_a_tap_on_a_row_lists_the_replies_behind_it_for_a_and_for_b_newest_first_in_dollars(served, browser):
    import re
    open_explorer(served, browser)
    click(browser, '#ex-tbody tr[data-k="claude-sonnet-5-5"]')
    wait(browser, 'document.querySelectorAll("#ex-replies .ex-rt tbody tr").length === 2', "the two replies behind Sonnet on A")
    r = shown(browser)["replies"]
    assert r["sum"] == "2 replies · $15.00" and [s[:2] for s in r["side"]] == [["a", "Asubscription-1"], ["b", "Bbedrock"]] and r["side"][0][2] == "true", r
    first, second = r["rows"]
    assert re.match(DATE, first[0]) and re.match(DATE, second[0]), (first, second)
    assert first[1:] == ["Sonnet 5.5", "subscription-1 not billed", "example-alpha-build", "$10.00"], first
    assert second[1:] == ["Sonnet 5.5", "subscription-1 not billed", "example-alpha-build", "$5.00"], second
    assert shown(browser)["rows"][0][4] is True, "the picked row is marked"
    click(browser, '#ex-replies [data-rside="b"]')
    wait(browser, '(document.querySelector("#ex-replies .ex-rmsg") || {}).textContent === "No replies in this selection."', "the empty list for B")
    r = shown(browser)["replies"]
    assert r["msg"] == "No replies in this selection." and r["sum"] == "0 replies · $0.00" and r["side"][1][2] == "true", r
    click(browser, '#ex-tbody tr[data-k="claude-opus-5"]')
    wait(browser, 'document.querySelectorAll("#ex-replies .ex-rt tbody tr").length === 1', "the Opus reply on B")
    assert shown(browser)["replies"]["rows"][0][1:] == ["Opus 5", "bedrock", "example-beta-main", "$5.00"]
    click(browser, '#ex-tbody tr[data-k="claude-opus-5"]')
    assert shown(browser)["replies"] is None and errors(browser) == []
    screenshot(browser, "usage-explorer-replies-1280.png")


def test_a_long_list_is_capped_at_200_and_says_how_many_there_are_in_all(served, browser):
    now = time.time()
    open_tab(served, browser, DESKTOP)
    w = world_of(served)
    w.registry("example-gamma-run", D)
    w.transcript(D, prompt(now - 5000, cwd="/work/example-repo"), *[reply(f"g{i}", "claude-sonnet-5-5", now - 4000 + i * 10, out=1000) for i in range(230)], mtime=now)
    click(browser, "#us-reload")
    click(browser, '#us-views [data-v="explorer"]')
    click(browser, '#ex-by [data-b="agent"]')
    wait(browser, '!!document.querySelector("#ex-tbody tr[data-k=example-gamma-run]")', "the new agent's row (the count after Reload)", 30000)
    click(browser, '#ex-tbody tr[data-k="example-gamma-run"]')
    select(browser, "#ex-sa", "subscription-1")
    wait(browser, 'document.querySelectorAll("#ex-replies .ex-rt tbody tr").length > 0', "the replies", 30000)
    r = shown(browser)["replies"]
    assert len(r["rows"]) == 200 and r["sum"].startswith("230 replies") and r["sum"].endswith("the newest 200 of 230"), r["sum"]
    assert errors(browser) == []


def test_a_failed_read_of_the_replies_says_so_and_a_new_tap_tries_again(served, browser):
    open_explorer(served, browser)
    browser.evaluate("""(() => { const real = window.fetch.bind(window); window.__failReplies = true;
      window.fetch = (url, opts) => String(url).startsWith("api/usage/replies") && window.__failReplies ? Promise.resolve(new Response("nope", { status: 500 })) : real(url, opts);
      return ""; })()""")
    click(browser, '#ex-tbody tr[data-k="claude-sonnet-5-5"]')
    wait(browser, '!!document.querySelector("#ex-replies .ex-rmsg.error")', "the error")
    assert "Could not read the replies" in shown(browser)["replies"]["msg"]
    browser.evaluate('window.__failReplies = false; ""')
    click(browser, '#ex-replies [data-rside="a"]')
    wait(browser, 'document.querySelectorAll("#ex-replies .ex-rt tbody tr").length === 2', "the replies after the retry")


def test_a_failed_read_of_the_usage_keeps_the_last_figures_and_says_so(served, browser):
    open_explorer(served, browser)
    browser.evaluate("""(() => { const real = window.fetch.bind(window);
      window.fetch = (url, opts) => String(url).startsWith("api/usage") ? Promise.resolve(new Response("nope", { status: 500 })) : real(url, opts);
      return ""; })()""")
    click(browser, "#us-reload")
    wait(browser, 'document.querySelector("#ex-note").textContent.length > 0', "the note")
    m = shown(browser)
    assert m["sides"][0][1] == "$15.00" and "500" in m["note"], m


def test_the_table_sorts_by_a_column_and_flips_on_a_second_tap(served, browser):
    open_explorer(served, browser)
    assert [r[0] for r in shown(browser)["rows"]] == ["claude-sonnet-5-5", "claude-opus-5"]
    click(browser, '#ex-thead [data-sort="b"]')
    assert [r[0] for r in shown(browser)["rows"]] == ["claude-opus-5", "claude-sonnet-5-5"]
    click(browser, '#ex-thead [data-sort="b"]')
    m = shown(browser)
    assert [r[0] for r in m["rows"]] == ["claude-sonnet-5-5", "claude-opus-5"]
    click(browser, '#ex-thead [data-sort="k"]')
    names = [r[1] for r in shown(browser)["rows"]]
    assert names == sorted(names, key=str.lower)


def test_a_name_from_the_registry_is_text_never_markup(served, browser):
    now = time.time()
    open_tab(served, browser, DESKTOP)
    w = world_of(served)
    w.transcript(C, reply("c1", "claude-sonnet-5-5", now - 600, out=100_000), mtime=now)      # the registry already names this session after the markup
    click(browser, "#us-reload")
    click(browser, '#us-views [data-v="explorer"]')
    click(browser, '#ex-cmp [data-c="agent"]')
    wait(browser, '[...document.querySelectorAll("#ex-sb option")].some((o) => o.textContent.includes("onerror"))', "the markup-like name in the pickers", 30000)
    select(browser, "#ex-sb", EVIL)
    m = browser.evaluate('({ pwned: window.__pwned || 0, imgs: document.querySelectorAll("#ov-usage img").length, name: document.querySelectorAll(".ex-side .ex-sn")[1].textContent })')
    assert m == {"pwned": 0, "imgs": 0, "name": EVIL}, m
    assert errors(browser) == []


def test_reload_asks_for_a_fresh_count_from_the_explorer_too(served, browser):
    open_explorer(served, browser)
    before = browser.evaluate("window.__usFetches")
    click(browser, "#us-reload")
    wait(browser, f"window.__usFetches >= {before} + 1", "a new read")
    assert errors(browser) == []


# ── the layout ───────────────────────────────────────────────────────────────
@pytest.mark.parametrize("size,name", [(DESKTOP, "desktop"), (PHONE, "phone")])
def test_the_layout_never_scrolls_sideways_the_two_sides_stay_side_by_side_and_a_phone_has_44px_targets(served, browser, size, name):
    open_explorer(served, browser, size)
    for c in ("agent", "folder", "model", "week", "lane"):
        click(browser, f'#ex-cmp [data-c="{c}"]')
    click(browser, "#ex-tbody tr[data-k]")
    wait(browser, '!!document.querySelector("#ex-replies .ex-rsum")', "the replies panel")
    m = browser.evaluate("""(() => { const vw = document.documentElement.clientWidth, r = (n) => n.getBoundingClientRect();
      const over = [...document.querySelectorAll("#us-v-explorer *")].filter((n) => r(n).right > vw + 0.5 && n.getClientRects().length).map((n) => n.className || n.tagName);
      const small = [...document.querySelectorAll("#us-v-explorer button, #us-v-explorer select, #ex-tbody tr")].filter((n) => n.getClientRects().length && r(n).height < 43.5).map((n) => (n.id || n.className || n.tagName) + ":" + Math.round(r(n).height));
      const sides = [...document.querySelectorAll(".ex-side")].map((c) => [Math.round(r(c).left), Math.round(r(c).top), Math.round(r(c).width)]);
      return { vw, doc: document.documentElement.scrollWidth, body: document.body.scrollWidth, over, small, sides }; })()""")
    assert m["doc"] <= m["vw"] and m["body"] <= m["vw"] + 1, m
    assert m["over"] == [], m["over"]
    assert len(m["sides"]) == 2 and m["sides"][0][1] == m["sides"][1][1] and m["sides"][0][0] < m["sides"][1][0], m["sides"]
    if name == "phone":
        assert m["small"] == [], m["small"]
    assert errors(browser) == []
    screenshot(browser, f"usage-explorer-{size['width']}-wide-names.png", 3200)


