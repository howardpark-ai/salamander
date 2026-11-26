"""The API spend limit on the aws-platform card (spend.py read_api_limit, GET /api/spend, sessions.js limitStrip).

Anthropic's "Monthly Claude API Spend Exceeding Thresholds" emails say the threshold, the API tier and when API use is paused until. A
briefing job (contrib/briefing/aws_limit.py) keeps the newest email's three facts in sala's state dir (aws-api-limit.json); the server reads
that file at each ask and adds `api_limit` to the aws-platform lane's entry (null when there is none, or it is unreadable); the Overview
card draws one line under the figure: `Limit $1,000 · Tier 3 · Paused until Tue Dec 1st`. It never wraps (a narrow card cuts its end with an
ellipsis) and its tooltip is the whole text with the pause instant in the SALA_TZ zone, the email's date and the source. A newest email more
than 14 days old keeps the figures and adds `as of <day>, no newer email`; after the pause instant the strip says `Pause ended <day>`.

The data tests need no browser. The card tests run in a headless Chromium when one is installed (conftest.py: `browser`), else are skipped.
Made-up data throughout: the organization is "Example Org". The file counts only for the organization SALA_AWS_LIMIT_ORG names (an autouse
fixture sets it to "Example Org"; the tests of the setting itself change it) and only with finite, sane numbers.
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

import pytest
from starlette.testclient import TestClient

from sala_web import spend as SPD
from sala_web.app import create_app
from test_lane_dormant import open_overview, page, world  # noqa: F401  (fixtures: the app, its page)
from test_credit import wait_for
from test_spend import A, B, World, line, poll, w  # noqa: F401  (w: the count's World, for the endpoint)
from test_spend_cards import READY, WHEN, ZONE, aws, cards, card_of  # noqa: F401

NOW = datetime(2026, 11, 20, 10, 0, 0, tzinfo=timezone.utc)
ISO = "%Y-%m-%dT%H:%M:%SZ"


def doc(email_days_ago=3, until=None, now=NOW, **over):
    """A state file's content as aws_limit.py writes it: the email `email_days_ago` before `now`, the pause until midnight UTC on Dec 1st."""
    sent = now - timedelta(days=email_days_ago)
    d = {"v": 1, "limit": 1000, "tier": 3, "paused_until": (until or datetime(2026, 12, 1, tzinfo=timezone.utc)).strftime(ISO),
         "email_date": sent.strftime(ISO), "org": "Example Org", "fetched_at": now.strftime(ISO)}
    d.update(over)
    return d


@pytest.fixture(autouse=True)
def the_organization(monkeypatch):
    """The setting the job and the endpoint read: the environment, else sala's config (conftest points SALA_CONFIG at nothing)."""
    monkeypatch.setenv("SALA_AWS_LIMIT_ORG", "Example Org")


def raw(**over):
    """The state file's text with a value written as JSON text (1e309, NaN, a huge integer: what json.dumps of a Python value cannot say)."""
    base = {k: v for k, v in doc().items() if k not in over}
    text = json.dumps(base)[:-1]
    return text + "".join(', "%s": %s' % (k, v) for k, v in over.items()) + "}"


def put(tmp_path, content):
    p = tmp_path / SPD.LIMIT_FILE
    p.write_text(content if isinstance(content, str) else json.dumps(content))
    return p


# ── the file, read ───────────────────────────────────────────────────────────
def test_a_good_file_is_read_with_its_facts_and_no_flags(tmp_path):
    got = SPD.read_api_limit(put(tmp_path, doc()), NOW)
    assert got == {"limit": 1000, "tier": 3, "pausedUntil": "2026-12-01T00:00:00Z", "emailDate": "2026-11-17T10:00:00Z",
                   "fetchedAt": "2026-11-20T10:00:00Z", "org": "Example Org", "stale": False, "staleDays": 3, "pauseEnded": False}


def test_a_missing_file_is_none(tmp_path):
    assert SPD.read_api_limit(tmp_path / "nope.json", NOW) is None
    assert SPD.read_api_limit(None, NOW) is None
    assert SPD.read_api_limit(tmp_path, NOW) is None          # a folder where the file should be


@pytest.mark.parametrize("content", [
    "{broken", "", "[]", "null", '{"v": 2}', json.dumps({**doc(), "v": 2}),
    json.dumps({k: v for k, v in doc().items() if k != "limit"}), json.dumps({k: v for k, v in doc().items() if k != "tier"}),
    json.dumps({k: v for k, v in doc().items() if k != "paused_until"}), json.dumps({k: v for k, v in doc().items() if k != "email_date"}),
    json.dumps(doc(limit=True)), json.dumps(doc(tier="3")), json.dumps(doc(tier=-1)),
    json.dumps(doc(paused_until="soon")), json.dumps(doc(email_date="yesterday")),
    # corrupt numbers: infinity (1e309 reads as one), NaN, negative, zero, a string, a huge integer, a limit at the bound, an absurd tier
    raw(limit="1e309"), raw(limit="-1e309"), raw(limit="NaN"), raw(limit="Infinity"), raw(limit="-1"), raw(limit="0"), raw(limit="-0.0"),
    raw(limit='"1000"'), raw(limit="1" + "0" * 400), raw(limit="1e9"), raw(limit="1000000000"), raw(limit="[1000]"), raw(limit="null"),
    raw(tier="1e309"), raw(tier="NaN"), raw(tier="1" + "0" * 400), raw(tier="1001"), raw(tier="3.5"), raw(tier="null"),
    raw(limit="1" + "0" * 5000),
])
def test_a_corrupt_or_incomplete_file_is_none_never_an_error(tmp_path, content):
    assert SPD.read_api_limit(put(tmp_path, content), NOW) is None


def test_a_deeply_nested_file_is_none_never_an_error(tmp_path):
    assert SPD.read_api_limit(put(tmp_path, "[" * 100_000), NOW) is None
    assert SPD.read_api_limit(put(tmp_path, '{"v": 1, "org": "Example Org", "limit": ' + "[" * 100_000), NOW) is None


def test_undecodable_bytes_are_none(tmp_path):
    p = tmp_path / SPD.LIMIT_FILE
    p.write_bytes(b"\xff\xfe\x00{")
    assert SPD.read_api_limit(p, NOW) is None


def test_sane_numbers_at_the_edges_are_read(tmp_path):
    for limit, want in ((0.01, 0.01), (2500.5, 2500.5), (999999999, 999999999), (1e8, 1e8)):
        assert SPD.read_api_limit(put(tmp_path, doc(limit=limit)), NOW)["limit"] == want
    assert SPD.read_api_limit(put(tmp_path, doc(tier=0)), NOW)["tier"] == 0
    assert SPD.read_api_limit(put(tmp_path, doc(tier=1000)), NOW)["tier"] == 1000


def test_the_fetch_time_is_optional_and_the_organization_is_not(tmp_path):
    d = doc()
    del d["fetched_at"]
    got = SPD.read_api_limit(put(tmp_path, d), NOW)
    assert got["fetchedAt"] is None and got["limit"] == 1000 and got["org"] == "Example Org"
    del d["org"]   # a file that names no organization cannot be shown for one
    assert SPD.read_api_limit(put(tmp_path, d), NOW) is None
    assert SPD.read_api_limit(put(tmp_path, doc(org=7)), NOW) is None


# ── the organization: the file counts only for the one the job is set to read ────
def test_the_file_is_served_only_for_the_organization_the_setting_names(tmp_path, monkeypatch):
    p = put(tmp_path, doc())
    assert SPD.read_api_limit(p, NOW)["limit"] == 1000                       # equal: served
    monkeypatch.setenv("SALA_AWS_LIMIT_ORG", "Other Org")
    assert SPD.read_api_limit(p, NOW) is None                                # changed: the old organization's figure is not shown
    monkeypatch.setenv("SALA_AWS_LIMIT_ORG", "")
    assert SPD.read_api_limit(p, NOW) is None                                # cleared: nothing
    monkeypatch.delenv("SALA_AWS_LIMIT_ORG")
    assert SPD.read_api_limit(p, NOW) is None                                # unset (and no config line): nothing
    monkeypatch.setenv("SALA_AWS_LIMIT_ORG", "   ")
    assert SPD.read_api_limit(p, NOW) is None                                # blank: nothing


def test_the_organization_is_compared_as_the_job_compares_it(tmp_path, monkeypatch):
    p = put(tmp_path, doc(org="Example  Org."))
    for name in ("Example Org", "example org", " EXAMPLE ORG. "):
        monkeypatch.setenv("SALA_AWS_LIMIT_ORG", name)
        assert SPD.read_api_limit(p, NOW)["limit"] == 1000, name
    for name in ("Example Org 2", "Example", "Org", "Example-Org"):
        monkeypatch.setenv("SALA_AWS_LIMIT_ORG", name)
        assert SPD.read_api_limit(p, NOW) is None, name


def test_the_organization_comes_from_sala_config_when_the_environment_does_not_set_it(tmp_path, monkeypatch):
    cfg = tmp_path / "config"
    cfg.write_text('# sala\nSALA_AWS_LIMIT_ORG="Example Org"   # the organization\n')
    monkeypatch.delenv("SALA_AWS_LIMIT_ORG")
    monkeypatch.setenv("SALA_CONFIG", str(cfg))
    p = put(tmp_path, doc())
    assert SPD.read_api_limit(p, NOW)["limit"] == 1000
    cfg.write_text("SALA_AWS_LIMIT_ORG=Other Org\n")
    assert SPD.read_api_limit(p, NOW) is None
    cfg.write_text("#SALA_AWS_LIMIT_ORG=Example Org\n")                       # commented out: unset
    assert SPD.read_api_limit(p, NOW) is None


def test_an_explicit_organization_argument_wins_over_the_setting(tmp_path):
    p = put(tmp_path, doc())
    assert SPD.read_api_limit(p, NOW, org="Example Org")["limit"] == 1000
    assert SPD.read_api_limit(p, NOW, org="Other Org") is None
    assert SPD.read_api_limit(p, NOW, org="") is None


def test_an_email_older_than_14_days_is_stale_and_one_of_exactly_14_is_not(tmp_path):
    assert SPD.read_api_limit(put(tmp_path, doc(email_days_ago=14)), NOW)["stale"] is False
    got = SPD.read_api_limit(put(tmp_path, doc(email_days_ago=14, email_date=(NOW - timedelta(days=14, seconds=1)).strftime(ISO))), NOW)
    assert got["stale"] is True and got["staleDays"] == 14
    got = SPD.read_api_limit(put(tmp_path, doc(email_days_ago=22)), NOW)
    assert got["stale"] is True and got["staleDays"] == 22 and got["limit"] == 1000 and got["tier"] == 3   # the figures stay


def test_the_pause_is_ended_from_its_instant_on(tmp_path):
    until = datetime(2026, 12, 1, tzinfo=timezone.utc)
    assert SPD.read_api_limit(put(tmp_path, doc()), until - timedelta(seconds=1))["pauseEnded"] is False
    assert SPD.read_api_limit(put(tmp_path, doc()), until)["pauseEnded"] is True
    got = SPD.read_api_limit(put(tmp_path, doc()), until + timedelta(days=1))
    assert got["pauseEnded"] is True and got["stale"] is True   # the 17th's email is 14 days and a day old on Dec 2nd: both flags


def test_the_real_clock_is_the_default(tmp_path):
    fresh = doc(now=datetime.now(timezone.utc), email_days_ago=1, until=datetime.now(timezone.utc) + timedelta(days=5))
    got = SPD.read_api_limit(put(tmp_path, fresh))
    assert got["stale"] is False and got["pauseEnded"] is False


# ── GET /api/spend ───────────────────────────────────────────────────────────
def test_the_endpoint_adds_api_limit_to_the_aws_platform_lane_only(w, monkeypatch):
    w.registry("aws-one", A, lane="aws-platform")
    w.transcript(A, line("m1", "claude-sonnet-5-5", WHEN, out=100_000))
    fresh = doc(now=datetime.now(timezone.utc), email_days_ago=2, until=datetime.now(timezone.utc) + timedelta(days=9))
    (w.sala / SPD.LIMIT_FILE).write_text(json.dumps(fresh))
    with TestClient(create_app(w.settings)) as c:
        d = poll(c)
    lanes = {x["lane"]: x for x in d["lanes"]}
    want = {"limit": 1000, "tier": 3, "pausedUntil": fresh["paused_until"], "emailDate": fresh["email_date"], "fetchedAt": fresh["fetched_at"],
            "org": "Example Org", "stale": False, "staleDays": 2, "pauseEnded": False}
    assert lanes["aws-platform"]["api_limit"] == want
    assert "api_limit" not in lanes["bedrock"]


def test_the_endpoint_says_null_with_no_file_and_never_raises_on_a_bad_one(w):
    w.registry("aws-one", A, lane="aws-platform")
    w.transcript(A, line("m1", "claude-sonnet-5-5", WHEN, out=100_000))
    with TestClient(create_app(w.settings)) as c:
        d = poll(c)
        assert next(x for x in d["lanes"] if x["lane"] == "aws-platform")["api_limit"] is None
        (w.sala / SPD.LIMIT_FILE).write_text("{broken")
        r = c.get("/api/spend")
        assert r.status_code == 200 and next(x for x in r.json()["lanes"] if x["lane"] == "aws-platform")["api_limit"] is None
        (w.sala / SPD.LIMIT_FILE).write_text(json.dumps(doc(now=datetime.now(timezone.utc))))   # fixed after the first ask: read again at the next
        got = next(x for x in c.get("/api/spend").json()["lanes"] if x["lane"] == "aws-platform")["api_limit"]
        assert got["limit"] == 1000 and got["org"] == "Example Org"


def _api_limit(c):
    r = c.get("/api/spend")
    assert r.status_code == 200, r.text
    return next(x for x in r.json()["lanes"] if x["lane"] == "aws-platform")["api_limit"]


@pytest.mark.parametrize("limit", ["1e309", "-1e309", "NaN", "Infinity", "-1", "0", '"1000"', "1" + "0" * 400, "1e9", "[1]", "null"])
def test_a_corrupt_limit_makes_api_limit_null_and_the_endpoint_still_answers_200(w, limit):
    w.registry("aws-one", A, lane="aws-platform")
    w.transcript(A, line("m1", "claude-sonnet-5-5", WHEN, out=100_000))
    (w.sala / SPD.LIMIT_FILE).write_text(raw(limit=limit))
    with TestClient(create_app(w.settings)) as c:
        poll(c)
        assert _api_limit(c) is None
        (w.sala / SPD.LIMIT_FILE).write_text(json.dumps(doc(now=datetime.now(timezone.utc))))   # the file mended: served again
        assert _api_limit(c)["limit"] == 1000


def test_a_deeply_nested_file_makes_api_limit_null_and_the_endpoint_still_answers_200(w):
    w.registry("aws-one", A, lane="aws-platform")
    w.transcript(A, line("m1", "claude-sonnet-5-5", WHEN, out=100_000))
    (w.sala / SPD.LIMIT_FILE).write_text("[" * 100_000)
    with TestClient(create_app(w.settings)) as c:
        poll(c)
        assert _api_limit(c) is None
        (w.sala / SPD.LIMIT_FILE).write_text(json.dumps(doc(now=datetime.now(timezone.utc))))   # the file mended: served again
        assert _api_limit(c)["limit"] == 1000


def test_the_endpoint_serves_the_file_only_while_the_organization_setting_names_its_organization(w, monkeypatch):
    w.registry("aws-one", A, lane="aws-platform")
    w.transcript(A, line("m1", "claude-sonnet-5-5", WHEN, out=100_000))
    (w.sala / SPD.LIMIT_FILE).write_text(json.dumps(doc(now=datetime.now(timezone.utc))))
    with TestClient(create_app(w.settings)) as c:
        poll(c)
        assert _api_limit(c)["org"] == "Example Org"                       # equal: served
        monkeypatch.setenv("SALA_AWS_LIMIT_ORG", "Other Org")
        assert _api_limit(c) is None                                       # changed: null, at the next ask, no restart
        monkeypatch.delenv("SALA_AWS_LIMIT_ORG")
        assert _api_limit(c) is None                                       # unset: null
        monkeypatch.setenv("SALA_AWS_LIMIT_ORG", "Example Org")
        assert _api_limit(c)["limit"] == 1000                              # back: served


def test_a_dormant_aws_platform_lane_still_carries_the_limit(w):
    from test_lane_dormant import SINCE
    (w.sala / "lane-state.tsv").write_text("\t".join(("aws-platform", "dormant", "paused", SINCE, "", "hand")) + "\n")
    (w.sala / SPD.LIMIT_FILE).write_text(json.dumps(doc(now=datetime.now(timezone.utc))))
    with TestClient(create_app(w.settings)) as c:
        d = poll(c)
    assert next(x for x in d["lanes"] if x["lane"] == "aws-platform")["api_limit"]["tier"] == 3


# ── the card ─────────────────────────────────────────────────────────────────
def ordinal(n):
    return f"{n}th" if 11 <= n % 100 <= 13 else f"{n}{ {1: 'st', 2: 'nd', 3: 'rd'}.get(n % 10, 'th') }"


def words(dt):
    """The card's day words in the zone conftest pins (Asia/Dubai): `Tue Dec 1st`."""
    d = dt.astimezone(ZONE)
    return f"{d.strftime('%a %b')} {ordinal(d.day)}"


def utc_midnight(days_from_now):
    n = datetime.now(timezone.utc) + timedelta(days=days_from_now)
    return datetime(n.year, n.month, n.day, tzinfo=timezone.utc)


def state(aws, email_days_ago, until_days=None, **over):
    now = datetime.now(timezone.utc)
    d = doc(email_days_ago=email_days_ago, until=utc_midnight(10 if until_days is None else until_days), now=now, **over)
    (aws.sala / SPD.LIMIT_FILE).write_text(json.dumps(d))
    return d, datetime.strptime(d["email_date"], ISO).replace(tzinfo=timezone.utc), datetime.strptime(d["paused_until"], ISO).replace(tzinfo=timezone.utc)


STRIPS = """(() => { const c = document.querySelector('#q-cards .s-card.lane-%s'); if (!c) return null;
  const all = [...c.querySelectorAll('.l-strip')];
  const kids = [...c.children].map((x) => x.className.split(' ')[0]);
  return { n: all.length, texts: all.map((x) => x.textContent), titles: all.map((x) => x.title), kids,
    style: all.length ? (() => { const s = getComputedStyle(all[0]); return { ws: s.whiteSpace, ov: s.overflow, to: s.textOverflow }; })() : null }; })()"""


def strips(browser, lane="aws-platform"):
    return browser.evaluate(STRIPS % lane)


def open_card(world, aws, page, browser):
    aws.registry("aws-one", A, lane="aws-platform")
    aws.transcript(A, line("a1", "claude-sonnet-5-5", WHEN, out=100_000))
    open_overview(browser, page())
    assert wait_for(browser, READY)


def test_the_strip_reads_limit_tier_and_paused_until_under_the_figure(world, aws, page, browser):
    d, sent, until = state(aws, email_days_ago=3)
    open_card(world, aws, page, browser)
    got = strips(browser)
    assert got["n"] == 1, got
    assert got["texts"] == [f"Limit $1,000 · Tier 3 · Paused until {words(until)}"], got
    # under the figure and above the estimate line, as the mockup draws it
    assert got["kids"].index("c-figs") + 1 == got["kids"].index("l-strip") and got["kids"].index("l-strip") + 1 == got["kids"].index("c-line"), got["kids"]
    # the tooltip: the whole text, the pause instant with its time and zone, the email's date and the source
    t = got["titles"][0]
    assert "Limit $1,000 a month" in t and "Tier 3" in t and f"API usage paused until {words(until)}" in t and "+04" in t, t
    assert 'Source: Anthropic email "Monthly Claude API Spend Exceeding Thresholds" (Example Org)' in t and words(sent) in t, t
    assert "No newer email" not in t
    assert card_of(cards(browser), "aws-platform")["figure"] == "$1.00"


def test_the_strip_never_wraps_and_a_narrow_card_cuts_its_end_with_an_ellipsis(world, aws, page, browser):
    state(aws, email_days_ago=3)
    open_card(world, aws, page, browser)
    got = strips(browser)
    assert got["style"] == {"ws": "nowrap", "ov": "hidden", "to": "ellipsis"}, got
    m = browser.evaluate("""(() => { const s = document.querySelector('#q-cards .s-card.lane-aws-platform .l-strip'), lh = parseFloat(getComputedStyle(s).lineHeight);
      const full = { cut: s.scrollWidth > s.clientWidth, h: s.clientHeight };
      s.style.width = '90px'; const narrow = { cut: s.scrollWidth > s.clientWidth, h: s.clientHeight };
      return { lh, full, narrow, title: s.title }; })()""")
    assert m["full"]["cut"] is False, m                       # at the card's width the whole line shows
    assert m["narrow"]["cut"] is True, m                      # narrower: the end is cut (the ellipsis), not wrapped
    assert m["narrow"]["h"] == m["full"]["h"] and m["narrow"]["h"] < 2 * m["lh"], m   # still one line
    assert "Tier 3" in m["title"]                              # the whole text stays in the tooltip


def test_a_stale_email_keeps_the_figures_and_adds_the_as_of_marker(world, aws, page, browser):
    d, sent, until = state(aws, email_days_ago=15)
    open_card(world, aws, page, browser)
    got = strips(browser)
    assert got["n"] == 2, got
    assert got["texts"] == [f"Limit $1,000 · Tier 3 · Paused until {words(until)}", f"as of {words(sent)}, no newer email"], got
    assert all("No newer email for 15 days." in t for t in got["titles"]), got["titles"]
    assert "l-asof" in browser.evaluate("document.querySelectorAll('#q-cards .s-card.lane-aws-platform .l-strip')[1].className")


def test_an_email_13_days_old_is_not_marked(world, aws, page, browser):
    state(aws, email_days_ago=13)
    open_card(world, aws, page, browser)
    assert strips(browser)["n"] == 1


def test_after_the_pause_instant_the_strip_says_pause_ended(world, aws, page, browser):
    d, sent, until = state(aws, email_days_ago=5, until_days=-2)
    open_card(world, aws, page, browser)
    got = strips(browser)
    assert got["n"] == 1 and got["texts"] == [f"Limit $1,000 · Tier 3 · Pause ended {words(until)}"], got   # a fresh email: no as-of marker
    assert "the API usage pause ended" in got["titles"][0] and "paused until" not in got["titles"][0], got["titles"]


def test_a_stale_email_after_the_pause_instant_says_pause_ended_and_keeps_the_marker(world, aws, page, browser):
    d, sent, until = state(aws, email_days_ago=22, until_days=-2)
    open_card(world, aws, page, browser)
    got = strips(browser)
    assert got["texts"] == [f"Limit $1,000 · Tier 3 · Pause ended {words(until)}", f"as of {words(sent)}, no newer email"], got


@pytest.mark.parametrize("content", [None, "{broken", json.dumps({"v": 1, "limit": "x"})])
def test_no_file_or_a_bad_one_leaves_the_card_as_it_is_with_no_error(world, aws, page, browser, content):
    if content is not None:
        (aws.sala / SPD.LIMIT_FILE).write_text(content)
    open_card(world, aws, page, browser)
    got = strips(browser)
    assert got["n"] == 0, got
    c = card_of(cards(browser), "aws-platform")
    assert c["figure"] == "$1.00" and c["err"] is None and c["warns"] == [] and "Limit" not in c["text"], c


def test_the_other_lane_and_the_details_page_have_no_strip(world, aws, page, browser):
    state(aws, email_days_ago=3)
    open_card(world, aws, page, browser)
    assert strips(browser, "bedrock")["n"] == 0
    browser.evaluate("location.hash = '#lane=aws-platform'")
    assert wait_for(browser, "document.body.classList.contains('lane-open') && !!document.querySelector('#ld-usage .s-card:not(.q-pending)')")
    assert browser.evaluate("document.querySelectorAll('#ld-usage .l-strip').length") == 0
