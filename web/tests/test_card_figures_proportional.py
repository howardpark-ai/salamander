"""A lone figure on a card is drawn with proportional digits, and the figures of a column keep tabular ones.

A figure such as "$3.11" must not show gaps between its digits. `.c-v` (the figure of the API and AWS spend cards) must not use
`font-variant-numeric: tabular-nums`, which sets every digit in a slot as wide as the widest, so a narrow "1" sits in a full-width
slot and the text reads as spaced out. Tabular digits are for numbers that line up in a column; a figure that stands alone, with
no other number above or below it to line up with, is set proportionally.

Alone, so proportional: the spend and usage cards' figure (`.c-v`), the phone strip's chips (`.q-chip`) and the tabs' counts (`.ov-n`). In a column, so tabular: the quota rows'
percents (`.q-pct`, stacked and right-aligned), the models' and sessions' amounts and shares (`.s-usd`, `.s-share`).

The checks are the computed style of each class, at a desktop's width and a phone's, on the Overview's own cards drawn from stubbed
answers and on the bedrock lane's details page, in a headless Chromium when one is installed (conftest.py: `browser`), else skipped;
and, when the page's font has narrower digits than its widest (Pretendard does; a runner without it does not, and then the check
says nothing), that a card's figure measures narrower for "1111" than for "0000", which is what the reader saw.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone

import pytest

from test_card_updated_line import LIMITS, ago, open_with, stub
from test_credit import wait_for  # noqa: F401
from test_lane_dormant import page, world  # noqa: F401  (fixtures)

NOW = datetime.now(timezone.utc)
SINCE = NOW.replace(day=1, hour=0, minute=0, second=0, microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def answers() -> str:
    """Every kind of card with figures made of the narrow digit: a Max card, the API card, both AWS cards."""
    t = ago(minutes=1)
    quota = [{"lane": "subscription-1", "plan": "Max (20x)", "limits": LIMITS, "fetchedAt": t},
             {"lane": "subscription-2", "plan": "Team", "limits": LIMITS, "fetchedAt": t}]
    credit = {"lane": "api", "todayUsd": 1.11, "monthUsd": 111.11, "unpriced": [], "estimatedFrom": None, "monthEstimatedUsd": 0, "fetchedAt": t}
    lane = lambda name, usd: {"lane": name, "configured": True, "monthUsd": usd, "calls": 3, "unpriced": [], "unmatched": [],  # noqa: E731
                              "models": [{"model": "claude-haiku-4-5", "usd": usd, "calls": 3}],
                              "sessions": [{"name": "one", "sessionId": "1", "usd": usd - 1, "share": (usd - 1) / usd, "live": False},
                                           {"name": "two", "sessionId": "2", "usd": 1.0, "share": 1 / usd, "live": False}]}
    spend = {"month": "2026-11", "since": SINCE, "fetchedAt": t, "lanes": [lane("aws-platform", 11.11), lane("bedrock", 3.11)]}
    return stub(quota, credit, spend)


# what a class is set in, as the page computes it: [class, style, how many of it the page holds]
READ = """(sels) => Object.fromEntries(sels.map((s) => { const els = [...document.querySelectorAll(s)];
  return [s, { n: els.length, styles: [...new Set(els.map((e) => getComputedStyle(e).fontVariantNumeric))] }]; }))"""

# alone: proportional
LONE = ["#q-cards .c-v", ".ov-n"]
CHIP = "#q-chips .q-chip"   # the phone strip (sessions.css draws it at 760 px and narrower): measured there
# in a column: tabular
COLUMN = ["#q-cards .q-row .q-pct"]


def read(browser, sels: list[str]) -> dict:
    return browser.evaluate(f"({READ})({json.dumps(sels)})")


@pytest.mark.parametrize("width", [1280, 390])
def test_a_lone_figure_on_a_card_has_proportional_digits_and_a_column_keeps_tabular(world, page, browser, width):
    open_with(browser, page, answers(), width=width)
    assert wait_for(browser, "document.querySelectorAll('#q-chips .q-chip').length > 0 && !!document.querySelector('#q-cards .q-row .q-pct')")
    lone = LONE + ([CHIP] if width <= 760 else [])
    got = read(browser, lone + COLUMN)
    for sel in lone:
        assert got[sel]["n"] > 0, (width, sel, "the page drew none of it")
        assert got[sel]["styles"] == ["proportional-nums"], (width, sel, got[sel])
    for sel in COLUMN:
        assert got[sel]["n"] > 0, (width, sel, "the page drew none of it")
        assert got[sel]["styles"] == ["tabular-nums"], (width, sel, got[sel])
    # the figures to check: the bedrock card's "$3.11", the API card's two
    assert browser.evaluate("[...document.querySelectorAll('#q-cards .c-v')].map((e) => e.textContent)") == ["$1.11", "$111.11", "$11.11", "$3.11"]


def test_the_amounts_and_shares_of_the_models_and_sessions_lists_keep_tabular_digits(world, page, browser):
    open_with(browser, page, answers(), width=1280)
    browser.evaluate("location.hash = '#lane=bedrock'")
    assert wait_for(browser, "document.body.classList.contains('lane-open') && !!document.querySelector('#ld-usage .s-card .s-list')")
    got = read(browser, ["#ld-usage .s-usd", "#ld-usage .s-share", "#ld-usage .c-v"])
    assert got["#ld-usage .s-usd"]["n"] == 3 and got["#ld-usage .s-usd"]["styles"] == ["tabular-nums"], got
    assert got["#ld-usage .s-share"]["n"] == 3 and got["#ld-usage .s-share"]["styles"] == ["tabular-nums"], got
    assert got["#ld-usage .c-v"]["n"] == 1 and got["#ld-usage .c-v"]["styles"] == ["proportional-nums"], got


# the figure of a card measured against itself: "1111" and "0000" set in the card's own style. Under tabular digits both are as wide
# as the widest digit; under proportional ones "1111" is narrower, when the font has narrower digits (measured here in the same
# font with the style forced to proportional, which tells whether the font has any).
WIDTHS = r"""(() => { const el = document.querySelector("#q-cards .s-card.lane-bedrock .c-v");
  const wid = (text, forced) => { const s = el.cloneNode(); s.textContent = text; if (forced) s.style.fontVariantNumeric = forced;
    el.parentNode.append(s); const w = s.getBoundingClientRect().width; s.remove(); return w; };
  return { ones: wid("1111"), zeros: wid("0000"), fontOnes: wid("1111", "proportional-nums"), fontZeros: wid("0000", "proportional-nums") }; })()"""


@pytest.mark.parametrize("width", [1280, 390])
def test_the_bedrock_figure_has_no_gaps_between_its_digits(world, page, browser, width):
    open_with(browser, page, answers(), width=width)
    if width <= 760:
        assert wait_for(browser, "document.getElementById('quota').classList.contains('q-open')")
    assert wait_for(browser, "!!document.querySelector('#q-cards .s-card.lane-bedrock .c-v')")
    w = browser.evaluate(WIDTHS)
    if w["fontOnes"] >= w["fontZeros"] - 0.5:
        return   # this font's digits are all one width: a gap cannot show, nothing to say
    assert w["ones"] < w["zeros"] - 0.5, (width, "the digits sit in slots of one width", w)
    assert abs(w["ones"] - w["fontOnes"]) < 0.5 and abs(w["zeros"] - w["fontZeros"]) < 0.5, (width, w)


def test_the_ultra_card_draws_no_cloud_credit_row_even_when_an_answer_still_carries_the_old_key(world, page, browser):
    """The temporary Cloud credit row is gone: a quota answer saved before the removal may still hold `cloudCredit`, and the card ignores it."""
    t = ago(minutes=1)
    old = [{"lane": "subscription-1", "plan": "Max (20x)", "limits": LIMITS, "fetchedAt": t,
            "cloudCredit": {"limit": 111, "used": 11, "remaining": 100, "endsAt": "2035-11-08T07:59:00Z"}},
           {"lane": "subscription-2", "plan": "Team", "limits": LIMITS, "fetchedAt": t}]
    open_with(browser, page, stub(old, {"lane": "api", "todayUsd": 0, "monthUsd": 0, "unpriced": [], "estimatedFrom": None,
                                        "monthEstimatedUsd": 0, "fetchedAt": t}, {"month": "2026-11", "since": SINCE, "fetchedAt": t, "lanes": []}))
    assert wait_for(browser, "!!document.querySelector('#q-cards .q-row .q-pct')")
    assert browser.evaluate("document.querySelectorAll('#q-cards .q-cloud').length") == 0
    assert "Cloud credit" not in browser.evaluate("document.getElementById('q-cards').textContent")
