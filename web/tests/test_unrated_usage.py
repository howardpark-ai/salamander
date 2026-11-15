"""The API card's tokens that the cost report has no rate for yet: counted at list prices, one quiet line on the card, the rows on the details page.

What a wrong answer costs here: a card that shows $0.00 for a month that spent dollars (the old behaviour: the tokens listed in
orange and left out of the figure), a long token list that fills the card, a model that no price table covers shown as $0 instead of
as not counted, a table that runs off a phone's edge, or a string that is missing in Korean. The page parts run in a headless
Chromium when one is installed (conftest.py: `browser`), else are skipped; the answers of api/credit are stubbed, the strings are
read from the two tables (the Korean text is written in i18n-ko.js alone, as escapes).
"""

from __future__ import annotations

import pytest

from test_card_updated_line import ago, open_with, stub
from test_credit import wait_for  # noqa: F401
from test_i18n import EN, KO
from test_lane_dormant import page, world  # noqa: F401  (fixtures)

SONNET, HAIKU = "claude-sonnet-5-5", "claude-haiku-4-5"


def credit(**over) -> dict:
    """An api/credit answer as credit.compute gives it, with a month of Sonnet 5.5 and a few Haiku 4.5 tokens priced at list prices."""
    base = {"lane": "api", "today": "2026-11-16", "month": "2026-11", "todayUsd": 0, "monthUsd": 2.94,
            "todayEstimatedUsd": 0, "monthEstimatedUsd": 0, "estimatedFrom": None, "exactThrough": None, "usageThrough": None,
            "calibratedOn": None, "todayListPriceUsd": 0, "monthListPriceUsd": 2.94, "consoleUrl": "https://platform.claude.com/settings/billing",
            "listPriced": [
                {"model": SONNET, "type": "cache_read_input_tokens", "count": 2_709_000, "usd": 0.2709},
                {"model": SONNET, "type": "cache_creation.ephemeral_5m_input_tokens", "count": 762_000, "usd": 1.9051},
                {"model": SONNET, "type": "uncached_input_tokens", "count": 218_000, "usd": 0.436},
                {"model": SONNET, "type": "output_tokens", "count": 32_000, "usd": 0.32},
                {"model": HAIKU, "type": "output_tokens", "count": 5, "usd": 0.000025},
                {"model": HAIKU, "type": "uncached_input_tokens", "count": 20, "usd": 0.00002},
            ], "unpriced": [], "fetchedAt": ago(minutes=3)}
    return {**base, **over}


def answers(c: dict) -> str:
    t = ago(minutes=3)
    return stub([{"lane": "subscription-1", "plan": "Max (20x)", "fetchedAt": t, "limits": []},
                 {"lane": "subscription-2", "plan": "Team", "fetchedAt": t, "limits": []}], c,
                {"month": "2026-11", "since": "2026-11-01T00:00:00Z", "fetchedAt": t, "lanes": []})


CARD = """(() => { const c = document.querySelector("#q-cards .c-card.lane-api"); const q = (s) => [...c.querySelectorAll(s)];
  return { figs: q(".c-v").map((e) => e.textContent), lines: q(".c-line").map((e) => ({ cls: e.className, text: e.textContent })),
           text: c.textContent }; })()"""
TABLE = """(() => { const card = document.querySelector("#ld-usage .ur-card"); if (!card) return null;
  const rows = [...card.querySelectorAll("tbody tr")].map((r) => [...r.children].map((e) => e.textContent));
  const t = card.querySelector("table"), box = card.getBoundingClientRect();
  return { title: card.querySelector(".ur-h").textContent, note: card.querySelector(".ur-note").textContent,
           head: [...card.querySelectorAll("thead th")].map((e) => e.textContent), rows,
           sumClass: card.querySelector("tbody tr:last-child").className,
           cardRight: box.right, tableRight: t.getBoundingClientRect().right, scroll: t.scrollWidth, client: t.clientWidth,
           pageScroll: document.documentElement.scrollWidth, pageClient: document.documentElement.clientWidth,
           usageCards: document.querySelectorAll("#ld-usage > .q-card").length }; })()"""


def en(key: str) -> str:
    return EN[key]


def test_the_card_counts_the_list_price_and_says_so_in_one_gray_line_with_no_token_list(world, page, browser):
    open_with(browser, page, answers(credit()), width=1280)
    assert wait_for(browser, "!!document.querySelector('#q-cards .c-card.lane-api .c-v')")
    card = browser.evaluate(CARD)
    assert card["figs"] == ["$0.00", "$2.94"], card                      # the month counts the tokens, at list price
    est = [ln for ln in card["lines"] if "c-listest" in ln["cls"].split()]
    assert [ln["text"] for ln in est] == ["Partly estimated at list price"] and "c-warn" not in est[0]["cls"], card["lines"]
    assert not [ln for ln in card["lines"] if "c-warn" in ln["cls"].split()], card["lines"]   # no orange line at all
    for word in ("Not counted", "tokens", "2709000", "Sonnet", "cache"):
        assert word not in card["text"], (word, card["text"])             # no token list on the card


def test_nothing_estimated_is_no_line(world, page, browser):
    open_with(browser, page, answers(credit(listPriced=[], monthListPriceUsd=0, monthUsd=0)), width=1280)
    assert wait_for(browser, "!!document.querySelector('#q-cards .c-card.lane-api .c-v')")
    card = browser.evaluate(CARD)
    assert card["figs"] == ["$0.00", "$0.00"] and not [ln for ln in card["lines"] if "c-listest" in ln["cls"]], card


def test_a_model_with_no_price_is_a_short_notice_on_the_card_and_a_not_counted_row_in_the_table(world, page, browser):
    mystery = [{"model": "claude-mystery-9", "type": "output_tokens", "count": 1234}]
    open_with(browser, page, answers(credit(unpriced=mystery)), width=1280)
    assert wait_for(browser, "!!document.querySelector('#q-cards .c-card.lane-api .c-v')")
    card = browser.evaluate(CARD)
    warn = [ln["text"] for ln in card["lines"] if "c-warn" in ln["cls"].split()]
    assert warn == [en("ov.c.notCountedSome")] and "1.2K" not in card["text"] and "Mystery" not in card["text"], card   # no model or token on the card
    browser.evaluate("location.hash = '#lane=api'")
    assert wait_for(browser, "!!document.querySelector('#ld-usage .ur-card')")
    page_card = browser.evaluate(CARD.replace('"#q-cards .c-card.lane-api"', '"#ld-usage .c-card.lane-api"'))
    assert [ln["text"] for ln in page_card["lines"] if "c-warn" in ln["cls"].split()] == [en("ov.c.notCountedSomeBelow")], page_card
    t = browser.evaluate(TABLE)
    # the priced rows, their total, then (outside the total) the model no price covers, its cost cell "not counted", never $0
    assert t["rows"][-1] == ["Mystery 9", "output", "1.2K", "not counted"], t["rows"]
    assert t["rows"][-2][0] == "Total" and t["rows"][-2][3] == "$2.93", t["rows"]


def test_the_details_page_lists_the_usage_without_a_confirmed_rate_with_a_total(world, page, browser):
    open_with(browser, page, answers(credit()), width=1280)
    browser.evaluate("location.hash = '#lane=api'")
    assert wait_for(browser, "!!document.querySelector('#ld-usage .ur-card')")
    t = browser.evaluate(TABLE)
    assert t["title"] == "Usage without a confirmed rate yet"
    assert t["note"] == "These models are not in the cost report yet. They leave this table once it covers them."
    assert t["head"] == ["Model", "Kind", "Tokens", "At list price"]
    assert t["rows"] == [
        ["Sonnet 5.5", "cache read", "2.7M", "$0.27"],
        ["Sonnet 5.5", "cache write (5 min)", "762K", "$1.91"],
        ["Sonnet 5.5", "input", "218K", "$0.44"],
        ["Sonnet 5.5", "output", "32K", "$0.32"],
        ["Haiku 4.5", "input \u00b7 output", "25", "$0.00"],    # rows that round to $0.00 are one row
        ["Total", "", "3.7M", "$2.93"],
    ], t["rows"]
    assert "ur-sum" in t["sumClass"].split() and t["usageCards"] == 2   # the card, and the table in a card of its own


def test_a_page_with_nothing_priced_at_list_has_no_table(world, page, browser):
    open_with(browser, page, answers(credit(listPriced=[], monthListPriceUsd=0, monthUsd=0)), width=1280)
    browser.evaluate("location.hash = '#lane=api'")
    assert wait_for(browser, "document.body.classList.contains('lane-open') && !!document.querySelector('#ld-usage .c-card.lane-api .c-v')")
    assert browser.evaluate(TABLE) is None


def test_the_korean_words(world, page, browser):
    mystery = [{"model": "claude-mystery-9", "type": "output_tokens", "count": 1234}]
    open_with(browser, page, answers(credit(unpriced=mystery)), width=1280)
    browser.evaluate("SalaI18n.setLang('ko')")
    assert wait_for(browser, "document.documentElement.lang === 'ko'")
    assert wait_for(browser, "!!document.querySelector('#q-cards .c-card.lane-api .c-listest')")
    card = browser.evaluate(CARD)
    est = [ln["text"] for ln in card["lines"] if "c-listest" in ln["cls"].split()]
    assert est == [KO["ov.c.listPriceEst"]] == ["\uc77c\ubd80\ub294 \uc815\uac00 \uae30\uc900 \ucd94\uc815"], card["lines"]
    assert [ln["text"] for ln in card["lines"] if "c-warn" in ln["cls"].split()] == [KO["ov.c.notCountedSome"]], card["lines"]
    browser.evaluate("location.hash = '#lane=api'")
    assert wait_for(browser, "!!document.querySelector('#ld-usage .ur-card')")
    t = browser.evaluate(TABLE)
    assert t["title"] == KO["ov.unrated.title"] and t["note"] == KO["ov.unrated.note"], t
    assert t["head"] == [KO[f"ov.unrated.{k}"] for k in ("model", "kind", "tokens", "cost")], t["head"]
    assert t["rows"][0][:2] == ["Sonnet 5.5", KO["ov.kind.cacheRead"]] and t["rows"][1][1] == KO["ov.kind.cacheWrite5m"], t["rows"]
    assert t["rows"][4][1] == KO["ov.kind.input"] + " \u00b7 " + KO["ov.kind.output"], t["rows"]
    assert t["rows"][-2][0] == KO["ov.unrated.total"] and t["rows"][-1][3] == KO["ov.unrated.notCounted"], t["rows"]
    assert t["rows"][0][2] == "270.9\ub9cc", t["rows"][0]                   # the page's own number formatter: the tens of thousands
    # and back to English: the table is worded again from the answer it holds
    browser.evaluate("SalaI18n.setLang('en')")
    assert wait_for(browser, "document.querySelector('#ld-usage .ur-h').textContent === 'Usage without a confirmed rate yet'")


@pytest.mark.parametrize("lang", ["en", "ko"])
def test_on_a_phone_the_table_does_not_run_off_the_edge(world, page, browser, lang):
    mystery = [{"model": "claude-mystery-9", "type": "cache_creation.ephemeral_1h_input_tokens", "count": 1234}]
    open_with(browser, page, answers(credit(unpriced=mystery)), width=390)
    browser.evaluate(f"SalaI18n.setLang('{lang}')")
    browser.evaluate("location.hash = '#lane=api'")
    assert wait_for(browser, "!!document.querySelector('#ld-usage .ur-card')")
    t = browser.evaluate(TABLE)
    assert t["scroll"] <= t["client"] + 1, (lang, "the table is wider than its box", t)
    assert t["tableRight"] <= t["cardRight"] + 0.5 and t["cardRight"] <= 390 + 0.5, (lang, t)
    assert t["pageScroll"] <= t["pageClient"], (lang, "the page scrolls sideways", t)
