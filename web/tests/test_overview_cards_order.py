"""The Overview's lane cards: active lanes first, and three to a row.

The order is by the state the card's own chip says: active, then dormant, then not configured; inside a group the cards keep
the order they are drawn in (max, team, api, aws-platform, bedrock). The AWS cards' missing "By model" and "Sessions"
sections are test_spend_cards.py's. What a wrong answer costs is the page the owner opens every day: a dormant lane drawn above the
lanes he is using, or a card so wide that only two fit a row and the page scrolls. The checks run in a headless Chromium when one
is installed (conftest.py: `browser`), else are skipped; the cards are the real ones, from the real answers of the app over fake
sign-in files (test_lane_dormant.py's `world`).
"""

from __future__ import annotations

import pytest

from test_credit import wait_for  # noqa: F401
from test_lane_dormant import FRI, SINCE, open_overview, page, record, world  # noqa: F401  (fixtures)

READY = ("document.querySelectorAll('#q-cards > .q-card').length === 5 && !document.querySelector('#q-cards .q-pending')"
         " && !document.querySelector('#q-cards .lane-chip-pending')")
ORDER = ("[...document.querySelectorAll('#q-cards > .q-card')].map((c) => [c.className.match(/lane-([\\w-]+)/)[1],"
         " c.querySelector('.lane-chip').textContent])")


def lanes(browser):
    return browser.evaluate(ORDER)


def test_active_cards_come_first_then_dormant_then_not_configured(world, page, browser):
    # max and api dormant, aws-platform not set up on this machine; team and bedrock are active
    record(world["rec"], ("subscription-1", "dormant", "login no longer reports Max", SINCE, "", "signal"),
           ("api", "dormant", "credit used up", FRI, "", "signal"))

    async def table():
        return {"aws-platform": False, "bedrock": True}

    world["app"].state.spend.lane_status = table
    open_overview(browser, page(), width=1400)
    assert wait_for(browser, READY)
    assert lanes(browser) == [["subscription-2", "active"], ["bedrock", "active"],
                              ["subscription-1", "dormant"], ["api", "dormant"],
                              ["aws-platform", "not configured"]]


def test_with_every_lane_active_the_order_is_unchanged(world, page, browser):
    record(world["rec"])
    open_overview(browser, page(), width=1400)
    assert wait_for(browser, READY)
    assert [x[0] for x in lanes(browser)] == ["subscription-1", "subscription-2", "api", "aws-platform", "bedrock"]
    assert {x[1] for x in lanes(browser)} == {"active"}


def test_a_lane_that_becomes_dormant_moves_down_on_the_next_draw(world, page, browser):
    record(world["rec"])
    open_overview(browser, page(), width=1400)
    assert wait_for(browser, READY)
    assert lanes(browser)[0] == ["subscription-1", "active"]
    record(world["rec"], ("subscription-1", "dormant", "login no longer reports Max", SINCE, "", "signal"))
    browser.evaluate("document.dispatchEvent(new Event('visibilitychange')); ''")   # the page refreshes when it is shown again; ask now
    assert wait_for(browser, "document.querySelector('#q-cards > .q-card:last-child').className.includes('lane-subscription-1')", 30.0)
    assert lanes(browser) == [["subscription-2", "active"], ["api", "active"], ["aws-platform", "active"], ["bedrock", "active"], ["subscription-1", "dormant"]]


# the grid: three columns on a desktop, two on a tablet, one on a phone, each card smaller than the 400px floor it had
GRID = """(() => { const g = document.getElementById('q-cards'), cs = [...g.children].map((c) => c.getBoundingClientRect());
  return { tracks: getComputedStyle(g).gridTemplateColumns.split(' ').length, firstRow: cs.filter((r) => Math.abs(r.top - cs[0].top) < 2).length,
           widest: Math.round(Math.max(...cs.map((r) => r.width))), smallest: Math.round(Math.min(...cs.map((r) => r.width))),
           scroll: document.documentElement.scrollWidth - document.documentElement.clientWidth }; })()"""


@pytest.mark.parametrize("width,columns", [(1920, 3), (1400, 3), (1024, 3), (760, 2), (390, 1)])
def test_three_cards_fit_a_row_on_a_desktop_and_it_steps_down(world, page, browser, width, columns):
    record(world["rec"])
    open_overview(browser, page(), width=width)
    browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 900, "deviceScaleFactor": 1, "mobile": False})
    assert wait_for(browser, f"document.documentElement.clientWidth === {width}")
    assert wait_for(browser, READY)
    if width <= 760:   # a phone folds the cards into one chip strip; a tap on the strip opens the grid
        browser.evaluate("if (!document.getElementById('quota').classList.contains('q-open')) document.getElementById('q-strip').click(); ''")
        assert wait_for(browser, "document.querySelector('#quota').classList.contains('q-open')")
    got = browser.evaluate(GRID)
    assert got["tracks"] == columns and got["firstRow"] == columns, (width, got)
    assert got["scroll"] <= 0, (width, got)
    if columns == 3:
        assert got["widest"] <= 360, (width, got)   # the cards are smaller: the 1100px page holds three (they were 400px or more, two to a row)
