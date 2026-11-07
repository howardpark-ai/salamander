"""Every Overview lane card ends with one muted line, "updated 7 min ago".

The line is the time of the card's last GOOD reading, never of a try that failed: the answer's own fetchedAt (the swr.py cache
stamps it on a good refresh and keeps it while refreshes fail; a dormant quota lane's answer carries the one its saved answer
holds). An answer without it says "updated unknown", never a time of the page's own. Past the stale mark the words are "as of".
The note (the dormant reason, an error or soft note, a "not counted" warning) is the line directly above it, under the figures.
The line ages with app.js's 30-second tick, so it never reads "7 min ago" an hour later. The card kinds are checked in a headless
Chromium when one is installed (conftest.py: `browser`), else skipped; the server's side (fetchedAt on a dormant lane's answer)
is checked without a browser."""

from __future__ import annotations

import asyncio
import json
from datetime import datetime, timedelta, timezone

import pytest

from sala_web import quota as Q
from sala_web import swr as SWR
from test_credit import wait_for  # noqa: F401
from test_lane_dormant import FRI, SINCE, open_overview, page, record, world  # noqa: F401  (fixtures)

MIN = 60 * 1000


def ago(minutes: float = 0, hours: float = 0, days: float = 0) -> int:
    return int((datetime.now(timezone.utc) - timedelta(minutes=minutes, hours=hours, days=days)).timestamp() * 1000)


LIMITS = [{"label": "Current session", "percent": 40, "severity": "normal", "resetsAt": "2035-05-30T01:44:00Z"},
          {"label": "This week", "percent": 20, "severity": "normal", "resetsAt": "2035-05-30T01:44:00Z"}]
DORMANT = {"reason": "No credit on the API key", "since": FRI}


def stub(quota: list, credit: dict, spend: dict) -> str:
    """A fetch stub installed before the page loads: the three answers the Overview draws its cards from."""
    return """(() => { const real = window.fetch.bind(window);
      const answer = (o) => Promise.resolve(new Response(JSON.stringify(o), { headers: { "Content-Type": "application/json" } }));
      window.fetch = (url, opts) => String(url).startsWith("api/quota") ? answer(%s) : String(url).startsWith("api/credit") ? answer(%s)
        : String(url).startsWith("api/spend") ? answer(%s) : real(url, opts);
    })();""" % (json.dumps({"lanes": quota}), json.dumps(credit), json.dumps(spend))


SEVEN = 6.8   # minutes: reads "7 min ago" for the 42 seconds the page may take to draw it (the words round to the nearest minute)


def fresh_answers(minutes: float = SEVEN) -> str:
    """Every card kind with a note and a good reading `minutes` old: a Max card; a Team card whose check just failed (a soft
    note, the numbers kept); the API card, dormant, with an error and an uncounted-tokens warning; a dormant aws-platform card
    with figures; a Bedrock card that is not set up."""
    t = ago(minutes=minutes)
    quota = [{"lane": "subscription-1", "plan": "Max (20x)", "limits": LIMITS, "fetchedAt": t},
             {"lane": "subscription-2", "plan": "Team", "limits": LIMITS, "fetchedAt": t, "error": "x", "errorKind": "rate_limited", "nextTry": t + 30 * MIN}]
    credit = {"lane": "api", "dormant": DORMANT, "todayUsd": 1.5, "monthUsd": 20.25, "estimatedFrom": None, "monthEstimatedUsd": 0,
              "unpriced": [{"type": "output_tokens", "count": 5000, "model": "claude-fable-5"}], "fetchedAt": t,
              "error": "Admin API answered HTTP 500", "consoleUrl": "https://platform.claude.com/settings/billing"}
    spend = {"month": "2026-10", "since": "2026-10-01T00:00:00Z", "fetchedAt": t, "lanes": [
        {"lane": "aws-platform", "configured": True, "monthUsd": 12.5, "calls": 3, "models": [], "sessions": [], "unpriced": [{"model": "x", "calls": 2}],
         "unmatched": [], "dormant": DORMANT},
        {"lane": "bedrock", "configured": False, "monthUsd": 0, "calls": 0, "models": [], "sessions": [], "unpriced": [], "unmatched": []}]}
    return stub(quota, credit, spend)


# every card as a reader sees it: its children by kind, the last one and the one above it
CARDS = """(() => [...document.querySelectorAll("#q-cards > .q-card")].map((c) => {
  const kids = [...c.children], last = kids[kids.length - 1], above = kids[kids.length - 2];
  const figs = [...c.querySelectorAll(".c-figs, .q-row")].pop(), note = c.querySelector(".q-dormant-line, .q-err");
  const KINDS = ["c-updated", "c-warn", "q-dormant-line", "q-err", "c-estline", "s-est", "c-figs", "q-head", "q-row", "s-list"];
  return { lane: [...c.classList].find((k) => k.startsWith("lane-")).slice(5), cls: c.className,
           last: last.className, lastText: last.textContent, lastTitle: last.title, above: above.className, aboveText: above.textContent,
           classes: kids.map((k) => KINDS.find((x) => k.classList.contains(x)) || k.className),
           noteBelowFigures: !note || !figs || note.getBoundingClientRect().top >= figs.getBoundingClientRect().bottom - 0.5,
           footBelowNote: !note || last.getBoundingClientRect().top >= note.getBoundingClientRect().bottom - 0.5,
           gap: above.getBoundingClientRect() && last.getBoundingClientRect().top - above.getBoundingClientRect().bottom,
           top: c.getBoundingClientRect().top, footTop: last.getBoundingClientRect().top, footBottom: last.getBoundingClientRect().bottom,
           bottom: c.getBoundingClientRect().bottom,
           oneLine: last.getBoundingClientRect().height < 28, right: c.getBoundingClientRect().right,
           footRight: last.getBoundingClientRect().right, cardRight: c.getBoundingClientRect().right,
           text: c.textContent };
}))()"""


def by_lane(browser) -> dict:
    return {c["lane"]: c for c in browser.evaluate(CARDS)}


def open_with(browser, page, script: str, width: int = 1280) -> None:
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": script})
    open_overview(browser, page(), width=width)
    assert wait_for(browser, "document.querySelectorAll('#q-cards .lane-chip:not(.lane-chip-pending)').length === 5")


def test_every_card_ends_with_its_updated_line_and_the_note_sits_right_above_it(world, page, browser):
    open_with(browser, page, fresh_answers())
    cards = by_lane(browser)
    assert sorted(cards) == ["api", "aws-platform", "bedrock", "subscription-1", "subscription-2"], sorted(cards)
    for lane, c in cards.items():
        assert "c-updated" in c["last"].split(), (lane, c["classes"])                      # the last child, on every kind of card
        assert c["lastText"] == "updated 7 min ago", (lane, c["lastText"])                 # relative, not a clock time
        assert c["oneLine"] and c["footRight"] <= c["cardRight"] + 0.5, (lane, c)
        assert c["noteBelowFigures"] and c["footBelowNote"], (lane, c)
        assert "+04" in c["lastTitle"] and ":" in c["lastTitle"], (lane, c["lastTitle"])    # the exact time (the owner's zone) on hover
    # the closing lines sit at the bottom of the card: the notes are right above the time (a few pixels, not the room the row gave
    # the card), and the lines of the cards in one row are on one level
    for lane in ("subscription-2", "api", "aws-platform", "bedrock"):
        assert cards[lane]["gap"] < 12, (lane, cards[lane]["gap"])
    for lane, c in cards.items():
        assert c["bottom"] - c["footBottom"] < 16, (lane, c["bottom"], c["footBottom"])
    row = [c for c in cards.values() if c["top"] == cards["subscription-1"]["top"]]
    assert len(row) >= 2 and len({round(c["footBottom"]) for c in row}) == 1, [(c["lane"], c["footBottom"]) for c in row]
    # the note is the line directly above the updated line
    assert "q-err" in cards["subscription-2"]["above"] and "q-soft" in cards["subscription-2"]["above"], cards["subscription-2"]["classes"]
    assert "q-err" in cards["api"]["above"] and "q-dormant-line" in cards["api"]["classes"], cards["api"]["classes"]
    assert cards["api"]["classes"][-4:] == ["c-warn", "q-dormant-line", "q-err", "c-updated"], cards["api"]["classes"]   # the figures' warning, the reason, the error, the line
    assert cards["aws-platform"]["classes"][-3:] == ["c-warn", "q-dormant-line", "c-updated"], cards["aws-platform"]["classes"]
    assert "q-dormant-line" in cards["bedrock"]["above"] and cards["bedrock"]["aboveText"] == "Not set up on this machine.", cards["bedrock"]
    assert cards["subscription-1"]["above"].startswith("q-row"), cards["subscription-1"]["classes"]              # a card with no note: the rows, then the line


def test_the_words_follow_the_age_and_the_stale_mark(world, page, browser):
    quota = [{"lane": "subscription-1", "plan": "Max (20x)", "limits": LIMITS, "fetchedAt": ago(minutes=0.2)},   # a few seconds
             {"lane": "subscription-2", "plan": "Team", "limits": LIMITS, "fetchedAt": ago(hours=3)}]           # long past the 10-minute mark
    credit = {"lane": "api", "todayUsd": 1, "monthUsd": 2, "unpriced": [], "estimatedFrom": None, "monthEstimatedUsd": 0, "fetchedAt": ago(minutes=12)}
    spend = {"month": "2026-10", "since": "2026-10-01T00:00:00Z", "fetchedAt": ago(days=2), "lanes": [
        {"lane": "aws-platform", "configured": True, "monthUsd": 1, "calls": 1, "models": [], "sessions": [], "unpriced": [], "unmatched": []},
        {"lane": "bedrock", "configured": True, "monthUsd": 1, "calls": 1, "models": [], "sessions": [], "unpriced": [], "unmatched": []}]}
    open_with(browser, page, stub(quota, credit, spend))
    cards = by_lane(browser)
    assert cards["subscription-1"]["lastText"] == "updated just now", cards["subscription-1"]["lastText"]
    assert cards["subscription-2"]["lastText"] == "as of 3 hours ago", cards["subscription-2"]["lastText"]          # stale: its refreshes are failing
    assert cards["api"]["lastText"] == "updated 12 min ago", cards["api"]["lastText"]           # fresh for the credit card (15-minute refresh)
    assert cards["bedrock"]["lastText"] == "as of 2 days ago" and cards["aws-platform"]["lastText"] == "as of 2 days ago"


def test_a_card_without_a_good_reading_says_unknown_never_a_time(world, page, browser):
    # a dormant Team lane that never answered, an error with nothing saved on the API card, a lane with no sign-in, a spend card pending
    quota = [{"lane": "subscription-1", "plan": "Max (20x)", "error": "no sign-in on this lane", "errorKind": "sign_in"},
             {"lane": "subscription-2", "plan": "Team", "dormant": {"reason": "no seat", "since": SINCE}}]
    credit = {"error": "No Admin API key on this machine.", "consoleUrl": "https://platform.claude.com/settings/billing"}
    spend = {"pending": True}
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": stub(quota, credit, spend)})
    open_overview(browser, page(), width=1280)
    assert wait_for(browser, "document.querySelectorAll('#q-cards .c-updated').length === 5")
    cards = by_lane(browser)
    for lane in ("subscription-1", "subscription-2", "api"):
        assert cards[lane]["lastText"] == "updated unknown", (lane, cards[lane]["lastText"])
        assert "c-updated" in cards[lane]["last"].split()
        assert not any(ch.isdigit() for ch in cards[lane]["lastText"]), cards[lane]["lastText"]     # no clock time, no age
    assert cards["subscription-2"]["above"].startswith("q-dormant-line") and cards["subscription-2"]["aboveText"] == "No seat since Mon Jan 5th"
    # a card still waiting for its first answer holds the line's place, empty
    for lane in ("aws-platform", "bedrock"):
        assert cards[lane]["lastText"].strip() == "", (lane, cards[lane]["lastText"])


def test_a_dormant_team_card_shows_the_time_of_its_last_good_check(world, page, browser):
    # the real server: the team lane answered once (saved in state_dir/quota-subscription-2.json), then sala marked it dormant
    world["app"].state.quota._swr["subscription-2"].state["fetchedAt"] = ago(days=3)   # what a restart would load from state_dir/quota-subscription-2.json
    record(world["rec"], ("subscription-2", "dormant", "usage check refused", SINCE, "", "signal"))
    open_overview(browser, page(), width=1280)
    assert wait_for(browser, "document.querySelectorAll('#q-cards .q-dormant').length >= 1 && !document.querySelector('#q-cards .q-pending')")
    team = by_lane(browser)["subscription-2"]
    assert team["lastText"] == "as of 3 days ago", team["lastText"]
    assert team["above"].startswith("q-dormant-line") and team["aboveText"].startswith("Usage check refused since"), team
    assert team["lastTitle"].endswith("+04")


def test_the_server_gives_a_dormant_lane_the_time_of_its_saved_good_answer(world):
    # a restart: the saved answer of a lane that is dormant now is loaded, and its time rides on the dormant answer; nothing is asked
    t = ago(hours=5)
    team = world["tmp"] / "claude-team"
    SWR.write_atomic(world["state"] / "quota-subscription-2.json", {"lane": "subscription-2", "limits": LIMITS, "plan": "Team", "fetchedAt": t})
    asked = []
    cache = Q.QuotaCache({"subscription-2": team}, fetch=lambda token: asked.append(token) or {"limits": []}, state_dir=world["state"])
    d = {"reason": "no seat", "since": SINCE}
    assert asyncio.run(cache.get({"subscription-2": d})) == [{"lane": "subscription-2", "dormant": d, "plan": "Team", "fetchedAt": t}]
    assert asked == []
    # a lane that never answered has none: the card says "updated unknown", the server invents no time
    fresh = Q.QuotaCache({"subscription-2": team}, fetch=lambda token: {"limits": []}, state_dir=world["tmp"] / "empty-state")
    assert asyncio.run(fresh.get({"subscription-2": d})) == [{"lane": "subscription-2", "dormant": d, "plan": "Team"}]


def test_the_line_ages_with_the_page_clock(world, page, browser):
    # the page's clock jumps 2 minutes ahead; the existing 30-second tick (app.js) rewrites the line, no reload
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": "window.__skew = 0; const __now = Date.now.bind(Date); Date.now = () => __now() + window.__skew;"})
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": fresh_answers(5)})
    open_overview(browser, page(), width=1280)
    assert wait_for(browser, "document.querySelectorAll('#q-cards .lane-chip:not(.lane-chip-pending)').length === 5")
    assert by_lane(browser)["subscription-1"]["lastText"] in ("updated 5 min ago", "updated 6 min ago")
    browser.evaluate("window.__skew = 2 * 60 * 1000")
    # 5 + 2 minutes, plus the seconds the test itself took
    assert wait_for(browser, "[...document.querySelectorAll('#q-cards .c-updated')].every((f) => /^updated [78] min ago$/.test(f.textContent))", timeout=45.0), \
        browser.evaluate("[...document.querySelectorAll('#q-cards .c-updated')].map((f) => f.textContent)")


@pytest.mark.parametrize("width", [360, 390])
def test_the_line_fits_a_narrow_card(world, page, browser, width):
    open_with(browser, page, fresh_answers(), width=width)
    cards = by_lane(browser)
    assert all(c["oneLine"] and c["footRight"] <= c["cardRight"] + 0.5 for c in cards.values()), cards
    assert browser.evaluate("document.documentElement.scrollWidth") <= width
