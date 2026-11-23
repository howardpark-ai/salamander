"""The Overview's tables never scroll sideways, at any window width.

The rule (the owner's, and a page's tables follow it for good): the Agents table and the table of a lane's sessions fit the width they are given. Where their
columns do not fit, the rows fold into cards (the phone's layout) instead of scrolling inside their box; a long cell wraps or is cut with an ellipsis, it never
widens the table. This test holds it, and a change that would let a table scroll sideways fails it.

What a wrong answer costs: the table the owner reads every day grows a scroll bar (it did, when a sleeping row said "sleeping since <date> KST" and "version
unknown" and every column stayed on one line inside a scrolling box), or a card that is too wide for the window cuts its last words off.

The data is fixed: the page's own fetch of api/overview is replaced before the page loads (as test_overview_columns.py does), by rows that are made to be
hard: sleeping sessions with a long name, a long model and a long lane name, a sleeper whose model is a bare alias with no version, a long project. At each width
(1920, 1280, 1024, 900, 761, 760, 390 px) and for both tables (the Agents table on the Overview, the sessions table of a lane's details page) the table, its box and
the page's own scrollers must have scrollWidth <= clientWidth, and every cell must end inside the box. A second case holds the other half: a table that fits stays
a table (its header row is there) on a wide window, and is cards at a phone's width.

The pages run in a headless Chromium when one is installed (conftest.py: `served`, `browser`), else are skipped; CI runs them.
All names are invented.
"""

from __future__ import annotations

import json

import pytest

from test_board_items_ui import wait_for

WIDTHS = [1920, 1280, 1024, 900, 761, 760, 390]
SLEPT = "2026-11-22T06:10:00Z"
LONG_LANE = "example-lane-with-a-very-long-name-for-the-width-test"
LONG_MODEL = "example-model-with-a-very-long-identifier-for-the-width-test-20261101"


def row(name, *, lane="subscription-1", model="claude-opus-5-5", effort="high", status="idle", sleeping=None, project="x", alias=None, source=None):
    d = {"name": name, "pid": 0 if sleeping else 1, "sessionId": name, "scope": "example", "project": "projects/" + project, "projectTitle": project,
         "role": "back", "status": status, "lane": lane, "model": model, "effort": effort,
         "modelSource": "alias" if alias else ("launch" if model else None), "effortSource": "launch" if effort else None, "modelAlias": alias}
    if sleeping:
        d["sleeping"] = sleeping
    return d


# hard rows, all on subscription-1 unless they say otherwise (the lane page lists the rows of its lane)
HARD = [
    row("example-a-live-agent", project="plain"),
    row("example-width-check-archive-sleeper-with-a-long-name-3", status="sleeping", sleeping=SLEPT, model=LONG_MODEL,
        project="a-project-with-a-rather-long-title-for-the-width-test"),
    row("example-sleeper-on-a-long-lane", status="sleeping", sleeping=SLEPT, lane=LONG_LANE, model=LONG_MODEL),
    row("example-sleeper-alias", status="sleeping", sleeping=SLEPT, model="opus", alias={"name": "opus", "from": "launch", "via": None, "binary": None}),
    row("example-sleeper-fable", status="sleeping", sleeping=SLEPT, model="claude-fable-5-1[1m]", effort=None),
]
# rows that fit anywhere: short names, no long cell
SHORT = [row("ex-a", project="p"), row("ex-b", status="sleeping", sleeping=SLEPT, model="claude-sonnet-5-5", effort="low", project="p")]


def stub(rows) -> str:
    return """(() => {
  const rows = %s, real = window.fetch.bind(window);
  window.fetch = (url, opts) => String(url).startsWith("api/overview")
    ? Promise.resolve(new Response(JSON.stringify({ sessions: rows, rolesError: null }), { headers: { "Content-Type": "application/json" } }))
    : real(url, opts);
})();""" % json.dumps(rows)


# one reading of a table: its box, the table itself and the page's own scrollers; every cell's right edge against the box's
MEASURE = r"""(sel) => {
  const table = document.querySelector(sel), wrap = table.parentElement, pane = document.getElementById("overview-pane");
  const w = wrap.getBoundingClientRect(), t = table.getBoundingClientRect();
  const out = [];
  for (const c of table.querySelectorAll("th, td, a, .sp-tag, .sp-pill")) {
    const r = c.getBoundingClientRect();
    if (r.width && c.getClientRects().length && getComputedStyle(c).display !== "none" && r.right > w.right + 0.5) out.push((c.className || c.tagName) + " " + c.textContent.trim().slice(0, 30) + " ends at " + Math.round(r.right) + " of " + Math.round(w.right));
  }
  return { table: { sw: table.scrollWidth, cw: table.clientWidth, right: t.right }, wrap: { sw: wrap.scrollWidth, cw: wrap.clientWidth, right: w.right, overflowX: getComputedStyle(wrap).overflowX },
           body: { sw: document.body.scrollWidth, cw: document.body.clientWidth }, html: { sw: document.documentElement.scrollWidth, cw: document.documentElement.clientWidth },
           pane: { sw: pane.scrollWidth, cw: pane.clientWidth }, vw: document.documentElement.clientWidth,
           folded: wrap.classList.contains("fold"), header: getComputedStyle(table.querySelector("thead")).display !== "none",
           rows: table.querySelectorAll("tbody tr").length, outside: out };
}"""


def open_at(browser, served, rows, hash_: str, width: int, ready: str) -> str:
    """Open the page at `width` with api/overview answering `rows`; the id of the stub script (a test that opens again removes it first)."""
    browser.send("Page.enable")
    ident = browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": stub(rows)})["identifier"]
    browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 900, "deviceScaleFactor": 1, "mobile": False})
    browser.send("Page.navigate", {"url": served["url"] + "/" + hash_})
    assert wait_for(browser, f"document.readyState === 'complete' && !!({ready})", 30.0)
    return ident


def resize(browser, width: int) -> None:
    browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 900, "deviceScaleFactor": 1, "mobile": False})
    assert wait_for(browser, f"document.documentElement.clientWidth === {width}", 10.0)
    browser.settle("document.getElementById('overview-pane')")   # the fonts are in and the layout has stopped moving: the fold is decided


def check(m: dict, where: str) -> None:
    """The one rule, in the words of the failure: nothing scrolls sideways and nothing ends outside the box."""
    assert m["rows"] >= len(HARD) - 1, (where, m)
    for part in ("table", "wrap", "body", "html", "pane"):
        assert m[part]["sw"] <= m[part]["cw"], f"{where}: the {part} scrolls sideways ({m[part]['sw']} > {m[part]['cw']}): {m}"
    assert m["table"]["right"] <= m["wrap"]["right"] + 0.5, f"{where}: the table is wider than its box: {m}"
    assert m["outside"] == [], f"{where}: cells end outside the box: {m['outside']}"
    assert m["wrap"]["overflowX"] in ("clip", "hidden", "visible"), f"{where}: the box scrolls ({m['wrap']['overflowX']})"   # never auto or scroll


AGENTS_READY = "document.querySelectorAll('#sp-table tbody tr td a').length === %d"
LANE_READY = "document.body.classList.contains('lane-open') && document.querySelectorAll('#ld-table tbody tr td a').length === %d"


@pytest.mark.parametrize("hash_,sel,ready,count", [
    ("#sessions", "#sp-table", AGENTS_READY, len(HARD)),
    ("#lane=subscription-1", "#ld-table", LANE_READY, len(HARD) - 1),     # the row on the long lane is on that lane's own page
    ("#lane=" + LONG_LANE, "#ld-table", LANE_READY, 1),
], ids=["agents", "lane-details", "lane-details-long-lane"])
def test_a_table_never_scrolls_sideways_at_any_width(served, browser, hash_, sel, ready, count):
    open_at(browser, served, HARD, hash_, WIDTHS[0], ready % count)
    for width in WIDTHS:
        resize(browser, width)
        m = browser.evaluate(f"({MEASURE})({json.dumps(sel)})")
        assert m["vw"] == width, m
        if count > 1:
            check(m, f"{sel} at {width} px")
        else:   # one row: the long lane's own page, the same rule
            for part in ("table", "wrap", "body", "html", "pane"):
                assert m[part]["sw"] <= m[part]["cw"], f"{sel} at {width} px: the {part} scrolls sideways: {m}"
            assert m["outside"] == [], f"{sel} at {width} px: cells end outside the box: {m['outside']}"
        if width <= 760:
            assert m["folded"] and not m["header"], f"{sel} at {width} px: a phone's rows are cards: {m}"


def test_a_sleepers_row_is_short_and_a_table_that_fits_stays_a_table(served, browser):
    """A sleeper's status cell is the one word and its model never says "version unknown" (the long words widened the table once); a table whose
    columns fit stays a table on a wide window and is cards on a phone."""
    ident = open_at(browser, served, HARD, "#sessions", 1920, AGENTS_READY % len(HARD))
    cells = browser.evaluate("""[...document.querySelectorAll('#sp-table tbody tr')].filter((r) => r.querySelector('.sp-status .dot.sleeping')).map((r) =>
      [...r.children].map((c) => c.textContent.trim()))""")
    assert len(cells) == 4, cells
    for c in cells:
        assert c[3] == "sleeping", c
        assert "since" not in " ".join(c) and "version unknown" not in " ".join(c), c
    browser.send("Page.removeScriptToEvaluateOnNewDocument", {"identifier": ident})
    browser.send("Page.navigate", {"url": "about:blank"})
    open_at(browser, served, SHORT, "#sessions", 1920, AGENTS_READY % len(SHORT))
    resize(browser, 1920)
    wide = browser.evaluate(f"({MEASURE})('#sp-table')")
    assert wide["header"] and not wide["folded"], f"short rows at 1920 px are a table: {wide}"
    resize(browser, 390)
    phone = browser.evaluate(f"({MEASURE})('#sp-table')")
    assert phone["folded"] and not phone["header"], f"short rows at 390 px are cards: {phone}"
    assert phone["table"]["sw"] <= phone["table"]["cw"] and phone["wrap"]["sw"] <= phone["wrap"]["cw"]
