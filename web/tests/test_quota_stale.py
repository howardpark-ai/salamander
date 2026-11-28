"""A lane whose saved numbers are old, or whose last usage check was refused, is never shown as a live figure.

The lane cards (GET /api/quota, the Overview) and the Usage analysis tab (usage.py, a flat lane's "weekly limit used") read
the same saved answers. An answer is stale (quota.is_stale) when its last good reading is older than quota.STALE_AFTER
(three refresh periods) or its last check was refused; a lane the dormant record lists is a head and no figures at all.
Every credentials file, state file and lane record here is a fake in tmp_path; nothing asks Anthropic. The card is checked in a
headless Chromium when one is installed (conftest.py: `browser`), else that test is skipped."""

import asyncio
import json
import time

import pytest
from starlette.testclient import TestClient

from sala_web import quota as Q
from sala_web import sessions as S
from sala_web import swr as SWR
from sala_web.app import create_app
from sala_web.config import Settings

from test_quota import SAVED_LIMITS, USAGE, creds, lane_creds, lanes, page_app, wait_for  # noqa: F401
from test_usage import NOW, World, at, quota, w  # noqa: F401

MIN = 60 * 1000


def ms_ago(minutes):
    return int(time.time() * 1000) - int(minutes * MIN)


def save(state, lane, fetched_ago_min, **extra):
    state.mkdir(parents=True, exist_ok=True)
    SWR.write_atomic(state / f"quota-{lane}.json", {"lane": lane, "plan": "Max (20x)", "limits": SAVED_LIMITS,
                                                    "fetchedAt": ms_ago(fetched_ago_min), **extra})


def refused(next_try_ago_min):
    """What sala-web saved for a lane whose check was refused, as found on disk long after: its wait is over."""
    return {"errorKind": "refused", "nextTry": ms_ago(next_try_ago_min)}


@pytest.fixture
def env(tmp_path, monkeypatch):
    d1, d2 = tmp_path / "claude", tmp_path / "claude-team"
    monkeypatch.setattr(S, "LANE_DIRS", {"subscription-2": d2})
    creds(d1)
    creds(d2, sub="team", tier="demo_claude_team")
    sala = tmp_path / "sala"
    sala.mkdir()
    state = tmp_path / "state"

    def app(fetch=lambda token: USAGE):
        a = create_app(Settings(claude_dir=d1, state_dir=state, sala_state_dir=sala))
        a.state.quota.fetch = fetch
        return a

    return app, state, sala


def test_the_age_after_which_a_reading_is_stale_is_three_refresh_periods():
    assert Q.STALE_AFTER == 3 * Q.TTL == 900.0
    now = 1_800_000_000.0
    at_ms = lambda s: int((now - s) * 1000)   # noqa: E731
    assert not Q.is_stale({"fetchedAt": at_ms(Q.STALE_AFTER - 1)}, now)
    assert Q.is_stale({"fetchedAt": at_ms(Q.STALE_AFTER + 1)}, now)


def test_refused_is_stale_whatever_the_age_and_a_dormant_head_or_a_pending_answer_has_no_figure_to_mark():
    now = time.time()
    assert Q.is_stale({"errorKind": "refused", "fetchedAt": int(now * 1000)}, now)
    assert Q.is_stale({"errorKind": "refused"}, now)
    assert not Q.is_stale({"errorKind": "rate_limited", "fetchedAt": int(now * 1000)}, now)
    assert not Q.is_stale({"dormant": {"reason": "", "since": ""}, "fetchedAt": 1}, now)
    assert not Q.is_stale({"pending": True, "fetchedAt": None, "limits": []}, now)


def test_a_fresh_lane_has_its_numbers_and_no_stale_mark(env):
    app, state, _ = env
    save(state, "subscription-1", 1)
    save(state, "subscription-2", 2)
    with TestClient(app()) as c:
        got = lanes(c)
    for lane in ("subscription-1", "subscription-2"):
        assert "stale" not in got[lane] and got[lane]["limits"] and "errorKind" not in got[lane]


def test_a_lane_refused_and_never_retried_is_marked_stale(env):
    """The shape found on disk: refused once, nextTry long past, the numbers from before. The wait is over, so the lane is asked
    again, is refused again, and stays stale."""
    app, state, _ = env
    save(state, "subscription-1", 1)
    save(state, "subscription-2", 60 * 24 * 19, **refused(60 * 24 * 10))

    def fetch(token):
        raise Q.Refused()

    with TestClient(app(fetch)) as c:
        got = lanes(c)
    assert "stale" not in got["subscription-1"]
    assert got["subscription-2"]["stale"] is True and got["subscription-2"]["errorKind"] == "refused"


def test_an_old_lane_still_holding_its_percent_is_marked_stale_whatever_error_it_has(env):
    """An old reading with no error saved on it (the file's errorKind is dropped on a restart once its wait has passed): a failing
    check keeps the numbers, and it is the age that marks them."""
    app, state, _ = env
    save(state, "subscription-1", 1)
    save(state, "subscription-2", 60 * 24 * 27)

    def fetch(token):
        raise Q.Unavailable("usage endpoint answered HTTP 500")

    with TestClient(app(fetch)) as c:
        got = lanes(c)
    assert got["subscription-2"]["limits"] and got["subscription-2"]["errorKind"] == "failed" and got["subscription-2"]["stale"] is True
    assert "stale" not in got["subscription-1"]


def test_a_lane_in_the_dormant_record_is_a_head_with_no_numbers_and_no_stale_mark(env):
    app, state, sala = env
    save(state, "subscription-1", 1)
    save(state, "subscription-2", 60 * 24 * 19, **refused(60 * 24 * 10))
    (sala / "lane-state.tsv").write_text("subscription-2\tdormant\tusage check refused\t2026-11-09T14:32:04Z\tposted\tby\n")
    with TestClient(app()) as c:
        got = lanes(c)
    two = got["subscription-2"]
    assert two["dormant"]["reason"] == "usage check refused"
    assert "limits" not in two and "stale" not in two and "percent" not in json.dumps(two)
    assert two["fetchedAt"] > 0   # the card's "updated ... ago" line keeps the time of the last good reading


def stale_usage(**extra):
    return [{"lane": "subscription-1", "fetchedAt": int(NOW * 1000), **quota()[0], **extra}]


def test_the_usage_tab_shows_a_fresh_lane_percent(w):
    got = w.count(q=stale_usage())
    lane = {r["code"]: r for r in got["lanes"]}["subscription-1"]
    assert lane["quota"] == {"percent": 40, "resetsAt": int(at(28, 5))}


@pytest.mark.parametrize("extra", [
    {"fetchedAt": int((NOW - 3600) * 1000)},
    {"fetchedAt": int((NOW - 19 * 86400) * 1000), "errorKind": "refused"},
    {"errorKind": "refused"},
], ids=["old", "old and refused", "refused just now"])
def test_the_usage_tab_gives_a_stale_lane_no_percent(w, extra):
    got = w.count(q=stale_usage(**extra))
    lane = {r["code"]: r for r in got["lanes"]}["subscription-1"]
    assert lane["quota"] is None and lane["flat"] is True


def test_the_usage_tab_draws_no_card_figure_for_a_dormant_lane(w):
    got = w.count(q=[{"lane": "subscription-1", "dormant": {"reason": "", "since": ""}, "fetchedAt": int(NOW * 1000)}])
    assert {r["code"]: r for r in got["lanes"]}["subscription-1"]["quota"] is None


def pcts(browser):
    return browser.evaluate("""[...document.querySelectorAll('#q-cards .q-card:not(.c-card)')].map((c) => ({
      lane: [...c.classList].find((k) => k.startsWith('lane-')).slice(5), stale: c.classList.contains('q-stale'),
      pcts: [...c.querySelectorAll('.q-pct')].map((n) => n.textContent), full: [...c.querySelectorAll('.q-fill')].map((n) => n.style.width) }))""")


def test_the_card_says_stale_where_a_percent_was_and_a_fresh_card_keeps_its_numbers(page_app, browser):
    state = page_app["state"]
    save(state, "subscription-1", 1)
    save(state, "subscription-2", 60 * 24 * 19, errorKind="refused", nextTry=ms_ago(-60 * 24))
    url = page_app["start"](lambda token: USAGE)
    browser.open(f"{url}/#sessions")
    # the cards first draw placeholder rows with a dash while the answer is pending: read only once no percent reads the dash
    assert wait_for(browser, """(() => { const n = [...document.querySelectorAll('#q-cards .q-card:not(.c-card) .q-pct')];
      return n.length >= 6 && n.every((x) => x.textContent.trim() && x.textContent.trim() !== '\\u2014' && x.textContent.trim() !== '-'); })()""")
    cards = {c["lane"]: c for c in pcts(browser)}
    assert cards["subscription-1"]["stale"] is False
    assert cards["subscription-1"]["pcts"] == ["5% used", "50% used", "20% used"]
    two = cards["subscription-2"]
    assert two["stale"] is True and len(two["pcts"]) == 3
    assert all("%" not in t and not any(ch.isdigit() for ch in t) for t in two["pcts"]), two
    assert two["full"] == ["0%", "0%", "0%"]
    assert two["pcts"] == ["stale"] * 3


# ── the scheduled job asks for a refresh of the lanes it reports ─────────────
def job_cache(tmp_path, asked, dormant_lane=None):
    for n in (1, 2, 3):
        lane_creds(tmp_path / f"claude-{n}")

    def fetch(token):
        asked.append(1)
        return USAGE

    return Q.QuotaCache({f"subscription-{n}": tmp_path / f"claude-{n}" for n in (1, 2, 3)}, fetch=fetch, state_dir=tmp_path / "state")


def test_the_job_refreshes_a_due_live_lane_so_its_percent_is_kept_and_leaves_refused_and_dormant_lanes_out(tmp_path):
    state = tmp_path / "state"
    save(state, "subscription-1", 60)                                                     # live lane, nobody polled for an hour: due
    save(state, "subscription-2", 60 * 24, errorKind="refused", nextTry=ms_ago(-60 * 24))  # refused and waiting: nothing is asked
    save(state, "subscription-3", 60)                                                     # dormant: nothing is asked
    asked = []
    q = job_cache(tmp_path, asked)
    dormant = {"subscription-3": {"reason": "idle", "since": "x"}}
    assert Q.is_stale(q.saved(dormant)[0])                                                # what the job used to read: an old reading
    asyncio.run(q.refresh_due(dormant))
    one, two, three = q.saved(dormant)
    assert len(asked) == 1 and not Q.is_stale(one) and one["limits"][1]["percent"] == 64.5
    assert Q.is_stale(two) and three == {"lane": "subscription-3", "dormant": dormant["subscription-3"]}


def test_the_job_asks_nothing_for_a_lane_inside_its_ttl(tmp_path):
    save(tmp_path / "state", "subscription-1", 1)
    asked = []
    q = job_cache(tmp_path, asked)
    asyncio.run(q.refresh_due({"subscription-2": {"reason": "", "since": ""}, "subscription-3": {"reason": "", "since": ""}}))
    assert asked == [] and not Q.is_stale(q.saved()[0])
