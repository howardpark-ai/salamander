"""The Agents list never scrolls sideways: the owner's rule, held for good, for the plain list and for every way of grouping it.

The rule: "horizontal scroll in this table is a hard no". The Agents table is laid out fixed (its columns add up to its box), a long cell is cut with an
ellipsis, and on a phone (760 px and under) the rows are wrapped cards with the header row hidden and the group headings the card's full width. This test
holds it for any later change to the columns, the groups or the look: with the Surface column present and names, models, lanes and a group heading that are
all far too long, at a desktop width and at phone widths, in the plain list and grouped by each of Status, Lane and Role (every group open, and a group folded),
the table, its box, the pane, the body and the page must have scrollWidth <= clientWidth, no box may scroll by its own overflow, and no cell or heading may end
outside the box. The second table (the same columns) is held the same way by test_table_width.py.

What a wrong answer costs: the table the owner reads every day grows a scroll bar, or a card is wider than the window and its last words are cut.

It runs in a headless Chromium when one is installed (conftest.py: `served`, `browser`), else is skipped; GitHub CI runs it (the browser tests run there, not on
the test box). The page's fetch of api/overview and api/prefs is replaced before it loads (test_agents_groups_ui.py). All names are invented.
"""

from __future__ import annotations

import pytest

from test_agents_groups_ui import SLEPT, open_agents, puts, row  # noqa: F401
from test_board_items_ui import wait_for

WIDTHS = [1920, 1280, 1024, 900, 761, 760, 390, 320]
LONG_LANE = "example-lane-with-a-very-long-name-for-the-width-test"
LONG_MODEL = "example-model-with-a-very-long-identifier-for-the-width-test-20261101"
LONG_NAME = "example-width-check-agent-with-a-very-long-name-that-keeps-going-for-the-test-"

ROWS = [
    row(LONG_NAME + "front-sala", "front", project="a-project-with-a-rather-long-title-for-the-width-test"),
    row(LONG_NAME + "front-slack", "front", surface="slack", status="needs input", model=LONG_MODEL),
    row(LONG_NAME + "back", "back", status="shell", lane=LONG_LANE, model="claude-fable-5-1[1m]", effort=None),
    row(LONG_NAME + "sleeper", "front", status="sleeping", lane=LONG_LANE, model=LONG_MODEL, sleeping=True),
    row("example-short", "front"),
    row("example-no-role", "", project=None, model=None, effort=None),
    row("example-odd-role", "a-role-word-an-old-registry-row-could-carry-that-is-long", status="working"),
]
# the group buttons and what each makes of ROWS (a lane the cards do not know, the long one, is a group of its own)
BY = ["", "status", "lane", "role"]

# one reading: the box, the table, the pane, the page and every cell, heading and card's right edge against the box's
MEASURE = r"""(() => {
  const table = document.getElementById("sp-table"), wrap = table.parentElement, pane = document.getElementById("overview-pane");
  const w = wrap.getBoundingClientRect(), t = table.getBoundingClientRect(), out = [], scrollers = [];
  for (const c of table.querySelectorAll("th, td, a, .sp-tag, .sp-pill, .ag-gh, .ag-gname, .sp-status")) {
    const r = c.getBoundingClientRect();
    if (r.width && c.getClientRects().length && getComputedStyle(c).display !== "none" && (r.right > w.right + 0.5 || r.left < w.left - 0.5))
      out.push((c.className || c.tagName) + " " + c.textContent.trim().slice(0, 30) + " spans " + Math.round(r.left) + "-" + Math.round(r.right) + " of " + Math.round(w.left) + "-" + Math.round(w.right));
  }
  for (const n of [wrap, table, pane, document.body, document.documentElement, ...table.querySelectorAll("tbody, tr, td")]) {
    const o = getComputedStyle(n).overflowX;
    if ((o === "auto" || o === "scroll") && n.scrollWidth > n.clientWidth) scrollers.push(n.tagName + "." + n.className);
  }
  return { table: { sw: table.scrollWidth, cw: table.clientWidth, right: t.right }, wrap: { sw: wrap.scrollWidth, cw: wrap.clientWidth, right: w.right, overflowX: getComputedStyle(wrap).overflowX },
           body: { sw: document.body.scrollWidth, cw: document.body.clientWidth }, html: { sw: document.documentElement.scrollWidth, cw: document.documentElement.clientWidth },
           pane: { sw: pane.scrollWidth, cw: pane.clientWidth }, vw: document.documentElement.clientWidth, folded: wrap.classList.contains("fold"),
           header: getComputedStyle(table.querySelector("thead")).display !== "none", heads: table.querySelectorAll(".ag-gh").length,
           rows: table.querySelectorAll("tbody tr:not(.ag-g)").length, outside: out, scrollers };
})()"""


def check(m: dict, where: str, rows: int | None) -> None:
    """rows: how many agent rows are drawn (None: not asked, a folded group hides its own)."""
    assert rows is None or m["rows"] == rows, (where, m)
    for part in ("table", "wrap", "body", "html", "pane"):
        assert m[part]["sw"] <= m[part]["cw"], f"{where}: the {part} scrolls sideways ({m[part]['sw']} > {m[part]['cw']}): {m}"
    assert m["table"]["right"] <= m["wrap"]["right"] + 0.5, f"{where}: the table is wider than its box: {m}"
    assert m["outside"] == [], f"{where}: cells end outside the box: {m['outside']}"
    assert m["scrollers"] == [] and m["wrap"]["overflowX"] in ("clip", "hidden", "visible"), f"{where}: something scrolls by its own overflow: {m}"


def resize(browser, width: int) -> None:
    browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 900, "deviceScaleFactor": 1, "mobile": False})
    assert wait_for(browser, f"document.documentElement.clientWidth === {width}", 10.0)
    browser.settle("document.getElementById('overview-pane')")


@pytest.mark.parametrize("by", BY, ids=["plain", "by-status", "by-lane", "by-role"])
def test_agents_no_sideways_scroll(served, browser, by):
    """The plain list and each grouping, at a desktop width and at phone widths: nothing scrolls sideways."""
    open_agents(browser, served, ROWS, held={"agentsGroup": by}, width=WIDTHS[0])
    if by:
        assert wait_for(browser, "document.querySelectorAll('#sp-table .ag-g').length > 1")
    for width in WIDTHS:
        resize(browser, width)
        m = browser.evaluate(MEASURE)
        assert m["vw"] == width, m
        assert bool(m["heads"]) == bool(by), (by, m)
        check(m, f"by {by or 'nothing'} at {width} px", len(ROWS))
        if width <= 760:
            assert m["folded"] and not m["header"], f"by {by or 'nothing'} at {width} px: a phone's rows are cards: {m}"
        elif width >= 1024:
            assert not m["folded"] and m["header"], f"by {by or 'nothing'} at {width} px: a desktop's list is a table: {m}"


@pytest.mark.parametrize("by", BY[1:], ids=["by-status", "by-lane", "by-role"])
def test_agents_no_sideways_scroll_with_a_group_folded_and_after_sorting(served, browser, by):
    """Folding a group and sorting a column (the headings stay one row each) change no width."""
    open_agents(browser, served, ROWS, held={"agentsGroup": by}, width=1280)
    assert wait_for(browser, "document.querySelectorAll('#sp-table .ag-g').length > 1")
    browser.evaluate("document.querySelector('#sp-table .ag-gh').click()")
    assert wait_for(browser, "document.querySelector('#sp-table .ag-gh').getAttribute('aria-expanded') === 'false'")
    browser.evaluate("document.querySelector('#sp-table th[data-key=\"model\"] button').click()")
    heads = browser.evaluate("document.querySelectorAll('#sp-table .ag-gh').length")
    for width in (1280, 390):
        resize(browser, width)
        m = browser.evaluate(MEASURE)
        assert m["heads"] == heads and m["rows"] < len(ROWS), m   # the folded group's rows are gone, its heading is not
        check(m, f"by {by}, one group folded, sorted by model, at {width} px", None)
