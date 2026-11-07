"""The AWS lanes' spend cards on the Overview and on the lane details pages (sessions.js spendCard, spend.py).

One card for the aws-platform lane (pill "aws-platform") and one for bedrock, after the API card: this month's spend as an
estimate at list prices since the first of the UTC month, the models (name, $, share), the sessions on the lane (name linked
while it runs, $, share; the top five, then "and K more ›"), the chip (Active, Dormant, Not configured), and in plain words
what could not be counted. The Overview cards of both lanes leave the models, the sessions and the "No sessions have used this lane yet." line out
(the by-model and sessions lists are not needed on these cards); each
lane's details page keeps all of them. The checks run in a headless Chromium when one is installed (conftest.py: `browser`), else are
skipped; the server's answer is real in the state tests (fake transcripts in tmp_path, test_spend.py's `World`) and stubbed in
the extremes (pending, the widest figures), and the geometry is test_lane_cards_nowrap.py's: at each width from a phone to a
wide screen no label wraps or is cut, the head is one row, the page does not scroll sideways.
"""

from __future__ import annotations

import json
import os
import time
from datetime import datetime, timedelta, timezone

import pytest
from starlette.testclient import TestClient

from sala_web import sessions as S
from sala_web import spend as SPD
from test_lane_cards_nowrap import MEASURE, WIDTHS, report, viewport
from test_lane_dormant import SINCE, open_overview, page, record, world  # noqa: F401  (fixtures: the app, its page)
from test_credit import wait_for
from test_spend import A, B, C, D, SECRET, Live, World, line  # noqa: F401

# the measurement of test_lane_cards_nowrap.py with the spend cards' own labels added to what must stay on one line and uncut
SELECTOR = ".q-name, .q-reset, .q-pct, .c-k, .c-v\")"
MEASURE_S = MEASURE.replace(SELECTOR, ".q-name, .q-reset, .q-pct, .c-k, .c-v, .s-h, .s-name, .s-usd, .s-share, .s-est, .s-more\")")
# a session's name is free text and may be longer than the card: it gives way with an ellipsis (its full name is the title), like the plan name
# must still be one line
MEASURE_S = MEASURE_S.replace('.q-plan"))', '.q-plan, .s-name"))')
assert MEASURE_S != MEASURE and ".q-plan, .s-name" in MEASURE_S

ZONE = timezone(timedelta(hours=4))   # Asia/Dubai, the zone conftest pins
NOW = datetime.now(timezone.utc)
START = SPD.month_start(NOW)
WHEN = max(NOW - timedelta(hours=1), START + timedelta(seconds=1)).strftime("%Y-%m-%dT%H:%M:%SZ")   # in this UTC month, always
SINCE_WORDS = START.astimezone(ZONE).strftime("%a %b") + " 1st"
READY = ("document.querySelectorAll('#q-cards .s-card').length === 2 && !document.querySelector('#q-cards .s-card.q-pending')"
         " && document.querySelectorAll('#q-cards .s-card .lane-chip:not(.lane-chip-pending)').length === 2")

# every spend card, as a reader sees it
SCARDS = """(() => [...document.querySelectorAll(%s)].map((c) => { const t = (s) => (c.querySelector(s) || {}).textContent || null;
  const list = (h) => { const l = [...c.querySelectorAll('.s-list')].find((x) => x.querySelector('.s-h').textContent === h);
    return l ? [...l.querySelectorAll('.s-row')].map((r) => ({ name: r.querySelector('.s-name').textContent, usd: r.querySelector('.s-usd').textContent,
      share: r.querySelector('.s-share').textContent, link: (r.querySelector('.s-name a') || {}).getAttribute ? r.querySelector('.s-name a').getAttribute('href') : null })) : null; };
  const more = c.querySelector('.s-more');
  return { cls: c.className, pills: [...c.querySelectorAll('.q-head .sp-pill:not(.lane-chip)')].map((p) => p.textContent), chips: [...c.querySelectorAll('.q-head .lane-chip')].map((x) => x.textContent),
    chipCls: (c.querySelector('.q-head .lane-chip') || {}).className || null, figure: t('.c-v'), key: t('.c-k'), est: t('.s-est'), estTitle: (c.querySelector('.s-est') || {}).title || null,
    models: list('By model'), sessions: list('Sessions'), more: more ? { text: more.textContent, href: more.getAttribute('href') } : null,
    warns: [...c.querySelectorAll('.c-warn')].map((x) => x.textContent), err: t('.q-err'), dormant: t('.q-dormant-line'),
    plain: [...c.querySelectorAll('.c-line:not(.c-warn):not(.c-foot)')].map((x) => x.textContent), foot: [...c.querySelectorAll('.c-foot:not(.s-est)')].map((x) => x.textContent),
    details: !!c.querySelector('.q-details'), pending: c.classList.contains('q-pending'), text: c.textContent }; }))()"""


def cards(browser, where="'#q-cards .s-card'"):
    return browser.evaluate(SCARDS % where)


def card_of(got, lane):
    return next(c for c in got if "lane-" + lane in c["cls"])


class Aws(World):
    """test_spend.py's World over the directories of test_lane_dormant.py's `world` (the app the page talks to)."""

    def __init__(self, world):
        s = world["settings"]
        self.tmp, self.settings, self.claude, self.sala, self.state, self.rows = world["tmp"], s, s.claude_dir, s.sala_state_dir, s.state_dir, []
        self.sala.mkdir(parents=True, exist_ok=True)

    def live(self, sid, name):
        """A live session in the registry of ~/.claude/sessions: this test process, which proc_lane is told runs on aws-platform."""
        pid = os.getpid()
        (self.claude / "sessions").mkdir(parents=True, exist_ok=True)
        (self.claude / "sessions" / f"{pid}.json").write_text(json.dumps(
            {"pid": pid, "sessionId": sid, "name": name, "cwd": "/home/alex", "status": "idle", "tmux": "x:@0.%0", "procStart": S.proc_start(pid)}))


@pytest.fixture
def aws(world, monkeypatch):
    monkeypatch.setattr(S, "proc_lane", lambda pid: "aws-platform")
    return Aws(world)


def populate(aws):
    """aws-platform: aws-big (running; Opus $2.00 + Sonnet $1.00) and aws-small (Sonnet $2.00); bedrock: bed-one (Haiku $0.50)."""
    aws.registry("aws-big", A, lane="aws-platform")
    aws.registry("aws-small", B, lane="aws-platform")
    aws.registry("bed-one", C, lane="bedrock")
    aws.transcript(A, line("a1", "claude-opus-5-5", WHEN, out=100_000), line("a2", "claude-sonnet-5-5", WHEN, out=100_000))    # 100000 * $20 / 1e6 = $2.00; $1.00
    aws.transcript(B, line("b1", "claude-sonnet-5-5", WHEN, out=200_000))                                                       # $2.00
    aws.transcript(C, line("c1", "global.anthropic.claude-haiku-5-5", WHEN, out=1_000_000))                                     # 1e6 * $0.50 / 1e6 = $0.50
    aws.live(A, "aws-big")


# ── the card, drawn from a real count ────────────────────────────────────────
def test_the_cards_show_the_month_as_an_estimate_with_models_and_sessions(world, aws, page, browser):
    populate(aws)
    open_overview(browser, page())
    assert wait_for(browser, READY)
    got = cards(browser)
    assert [c["pills"] for c in got] == [["aws-platform"], ["bedrock"]]                        # after the API card, in this order
    assert browser.evaluate("[...document.querySelectorAll('#q-cards > .q-card')].map((c) => c.className.match(/lane-([\\w-]+)/)[1])") == \
        ["subscription-1", "subscription-2", "api", "aws-platform", "bedrock"]
    p, b = card_of(got, "aws-platform"), card_of(got, "bedrock")
    assert p["chips"] == ["active"] and "lane-chip-active" in p["chipCls"] and p["details"] and not p["pending"]
    assert p["key"] == "This month" and p["figure"] == "$5.00"                                 # 2 + 1 + 2
    assert p["est"] == "Estimate at list prices since " + SINCE_WORDS, p
    assert "can differ" in p["estTitle"] and "UTC month" in p["estTitle"]
    # the aws platform card on the Overview is the figure and its estimate and nothing below them; the models and the
    # sessions are its details page's (below)
    assert p["models"] is None and p["sessions"] is None and p["more"] is None and p["warns"] == [] and p["err"] is None, p
    assert "By model" not in p["text"] and "Sessions" not in p["text"], p["text"]
    assert len(p["foot"]) == 1 and p["foot"][0].startswith("updated ")
    # the same for bedrock: its figure and estimate, no lists
    assert b["figure"] == "$0.50" and b["est"] == "Estimate at list prices since " + SINCE_WORDS, b
    assert b["models"] is None and b["sessions"] is None and b["more"] is None and b["warns"] == [] and b["err"] is None, b
    assert "By model" not in b["text"] and "Sessions" not in b["text"], b["text"]
    assert len(b["foot"]) == 1 and b["foot"][0].startswith("updated ")
    assert SECRET not in browser.evaluate("document.body.innerText")


def test_the_aws_platform_details_page_keeps_the_models_and_the_sessions(world, aws, page, browser):
    populate(aws)
    open_overview(browser, page())
    assert wait_for(browser, READY)
    browser.evaluate("location.hash = '#lane=aws-platform'")
    assert wait_for(browser, "document.body.classList.contains('lane-open') && !!document.querySelector('#ld-usage .s-card .s-list')")
    d = cards(browser, "'#ld-usage .s-card'")[0]
    assert d["models"] == [{"name": "Sonnet 5.5", "usd": "$3.00", "share": "60%", "link": None},
                           {"name": "Opus 5.5", "usd": "$2.00", "share": "40%", "link": None}]
    assert d["sessions"] == [{"name": "aws-big", "usd": "$3.00", "share": "60%", "link": "#s=aws-big"},   # running: a link to the session
                             {"name": "aws-small", "usd": "$2.00", "share": "40%", "link": None}]          # not running: plain
    assert d["more"] is None and d["figure"] == "$5.00"


def test_the_bedrock_details_page_keeps_the_models_and_the_sessions(world, aws, page, browser):
    populate(aws)
    open_overview(browser, page())
    assert wait_for(browser, READY)
    browser.evaluate("location.hash = '#lane=bedrock'")
    assert wait_for(browser, "document.body.classList.contains('lane-open') && !!document.querySelector('#ld-usage .s-card .s-list')")
    d = cards(browser, "'#ld-usage .s-card'")[0]
    assert d["pills"] == ["bedrock"] and d["figure"] == "$0.50" and d["more"] is None, d
    assert d["models"] == [{"name": "Haiku 5.5", "usd": "$0.50", "share": "100%", "link": None}]
    assert d["sessions"] == [{"name": "bed-one", "usd": "$0.50", "share": "100%", "link": None}]


def test_a_lane_with_no_usage_yet_is_active_with_zero_dollars(world, aws, page, browser):
    open_overview(browser, page())
    assert wait_for(browser, READY)
    for c in cards(browser):
        assert c["chips"] == ["active"] and c["figure"] == "$0.00" and c["est"] == "Estimate at list prices since " + SINCE_WORDS, c
        # the Overview card of an AWS lane has no "No sessions" line either, and no lists
        assert c["plain"] == [] and c["models"] is None and c["sessions"] is None, c
    # the details page keeps the line, for either lane
    for lane in ("aws-platform", "bedrock"):
        browser.evaluate(f"location.hash = '#lane={lane}'")
        assert wait_for(browser, f"document.body.classList.contains('lane-open') && !!document.querySelector('#ld-usage .s-card.lane-{lane}:not(.q-pending)')")
        d = cards(browser, "'#ld-usage .s-card'")[0]
        assert any("No sessions have used this lane yet." in x for x in d["plain"]), d["plain"]
        browser.evaluate("location.hash = '#sessions'")
        assert wait_for(browser, "!document.body.classList.contains('lane-open')")


def test_the_overview_lists_no_sessions_and_the_details_page_lists_all_of_them(world, aws, page, browser):
    for i in range(7):
        sid = f"{i + 1}0000000-0000-4000-8000-000000000001"
        aws.registry(f"bed-{i + 1}", sid, lane="bedrock")
        aws.transcript(sid, line(f"m{i}", "claude-sonnet-5-5", WHEN, out=(7 - i) * 100_000))      # bed-1 $7.00, bed-2 $6.00 ... bed-7 $1.00
    open_overview(browser, page())
    assert wait_for(browser, READY)
    b = card_of(cards(browser), "bedrock")
    assert b["sessions"] is None and b["models"] is None and b["more"] is None and b["figure"] == "$28.00", b   # no "and 2 more ›" either
    # the lane's details page: the same card with every session (the biggest first), the explanation, and no link to itself
    browser.evaluate("location.hash = '#lane=bedrock'")
    assert wait_for(browser, "document.body.classList.contains('lane-open') && !!document.querySelector('#ld-usage .s-card:not(.q-pending)')")
    d = cards(browser, "'#ld-usage .s-card'")[0]
    assert [s["name"] for s in d["sessions"]] == [f"bed-{i}" for i in range(1, 8)] and d["more"] is None and not d["details"], d
    assert [s["usd"] for s in d["sessions"]][:3] == ["$7.00", "$6.00", "$5.00"] and d["models"][0]["share"] == "100%"
    assert any("real bill and can differ" in x for x in d["plain"]), d["plain"]
    assert d["chips"] == [] and d["figure"] == "$28.00" and d["pills"] == ["bedrock"]   # no status pill in the details-page card


def test_the_aws_platform_details_page_draws_the_card_and_its_sessions_table(world, aws, page, browser):
    populate(aws)
    open_overview(browser, page())
    assert wait_for(browser, READY)
    browser.evaluate("location.hash = '#lane=aws-platform'")
    assert wait_for(browser, "document.body.classList.contains('lane-open') && !!document.querySelector('#ld-usage .s-card .s-list')")
    d = cards(browser, "'#ld-usage .s-card'")
    assert len(d) == 1 and d[0]["figure"] == "$5.00" and d[0]["pills"] == ["aws-platform"] and not d[0]["details"]
    assert browser.evaluate("document.querySelector('#ld-title').textContent").startswith("aws-platform")
    # Decision: the lane reads "aws-platform", hyphen and all, in the label, the details title and the spend pill
    assert browser.evaluate("LANE_LABEL['aws-platform']") == "aws-platform"
    assert browser.evaluate("document.querySelector('#ld-title').textContent") == "aws-platform" + "aws-platform lane"
    assert d[0]["pills"] == ["aws-platform"] and "aws platform" not in browser.evaluate("document.body.innerText").lower()
    assert "No usage check is made" not in browser.evaluate("document.getElementById('ld-usage').textContent")


# ── states ───────────────────────────────────────────────────────────────────
def test_a_lane_that_is_not_set_up_says_so_and_counts_nothing(world, aws, page, browser):
    async def table():
        return {"aws-platform": False, "bedrock": True}

    world["app"].state.spend.lane_status = table
    open_overview(browser, page())
    assert wait_for(browser, "document.querySelectorAll('#q-cards .s-card .lane-chip:not(.lane-chip-pending)').length === 2")
    got = cards(browser)
    p, b = card_of(got, "aws-platform"), card_of(got, "bedrock")
    assert p["chips"] == ["not configured"] and "lane-chip-unconfigured" in p["chipCls"] and p["dormant"] == "Not set up on this machine."
    assert p["figure"] is None and p["details"]
    assert b["chips"] == ["active"] and b["figure"] == "$0.00"


def test_a_dormant_lane_keeps_its_month_and_its_reason(world, aws, page, browser):
    # dormant is a chip and a line, not the end of the figures; the count is local, so nothing is asked of anyone
    populate(aws)
    record(world["rec"], ("aws-platform", "dormant", "no workspace", SINCE, "", "hand"))
    open_overview(browser, page())
    assert wait_for(browser, "document.querySelectorAll('#q-cards .lane-aws-platform .lane-chip:not(.lane-chip-pending)').length === 1 && !document.querySelector('#q-cards .s-card.q-pending')")
    got = cards(browser, "'#q-cards .lane-aws-platform, #q-cards .lane-bedrock'")
    p = card_of(got, "aws-platform")
    assert p["chips"] == ["dormant"] and p["dormant"] == "No workspace since Mon Jan 5th" and p["details"], p
    assert p["key"] == "This month" and p["figure"] == "$5.00" and p["est"] == "Estimate at list prices since " + SINCE_WORDS, p
    assert p["foot"] and p["foot"][0].startswith("updated "), p
    assert card_of(got, "bedrock")["figure"] == "$0.50"


def test_a_dormant_lane_with_nothing_spent_shows_zero_not_blank(world, aws, page, browser):
    record(world["rec"], ("bedrock", "dormant", "no workspace", SINCE, "", "hand"))
    open_overview(browser, page())
    assert wait_for(browser, "document.querySelectorAll('#q-cards .lane-bedrock .lane-chip:not(.lane-chip-pending)').length === 1 && !document.querySelector('#q-cards .s-card.q-pending')")
    b = card_of(cards(browser, "'#q-cards .lane-bedrock'"), "bedrock")
    assert b["chips"] == ["dormant"] and b["dormant"] == "No workspace since Mon Jan 5th", b
    assert b["figure"] == "$0.00" and b["est"] == "Estimate at list prices since " + SINCE_WORDS, b


def test_the_spend_answer_of_a_dormant_lane_has_its_figures_and_the_record(world, aws):
    populate(aws)
    record(world["rec"], ("aws-platform", "dormant", "no workspace", SINCE, "", "hand"))
    with TestClient(world["app"]) as c:
        for _ in range(200):
            r = c.get("/api/spend").json()
            if r.get("lanes") and any(x.get("monthUsd") for x in r["lanes"]):
                break
            time.sleep(0.05)
        got = {x["lane"]: x for x in r["lanes"]}
        assert got["aws-platform"]["dormant"] == {"reason": "no workspace", "since": SINCE}, r
        assert got["aws-platform"]["monthUsd"] == 5.0 and got["aws-platform"]["sessions"], r      # the figures stay, "dormant" is added
        assert "dormant" not in got["bedrock"] and got["bedrock"]["monthUsd"] == 0.5
        # before the first count lands the dormant lane is a stub the card draws as pending
        fresh = {"lanes": [], "pending": True}
        world["app"].state.spend._swr.state = fresh
        stub = c.get("/api/spend").json()
        assert {"lane": "aws-platform", "dormant": {"reason": "no workspace", "since": SINCE}} in stub["lanes"], stub


def test_models_without_a_price_and_sessions_without_a_transcript_are_said_in_plain_words(world, aws, page, browser):
    populate(aws)
    aws.transcript(B, line("u1", "claude-opus-4-8", WHEN, out=5), line("u2", "claude-opus-4-8", WHEN, out=5))
    aws.log(("2026-10-02T00:00:00+00:00", "set", "ghost", "(default) → aws-platform"))
    open_overview(browser, page())
    assert wait_for(browser, READY)
    p = card_of(cards(browser), "aws-platform")
    assert p["figure"] == "$5.00"                                       # the unpriced replies add nothing, and say so
    assert p["warns"] == ["Not counted (no list price known): 2 replies on Opus 4.8.",
                          "Not counted: a session on this lane whose transcript was not found (ghost)."], p["warns"]


def test_a_count_that_cannot_be_made_says_so_on_the_card_and_never_a_blank(world, aws, page, browser):
    aws.sala.joinpath("sessions.json").write_text("{broken")
    open_overview(browser, page())
    assert wait_for(browser, "document.querySelectorAll('#q-cards .s-card .q-err').length === 2")
    for c in cards(browser):
        assert c["err"] == "sala's session record could not be read" and c["figure"] is None and c["details"], c
        assert c["chips"] == ["active"] and c["models"] is None, c       # no figure at all: not "$0.00", which would be a claim
    # it is counted once the record is readable again; the saved answer then replaces the sentence
    aws.sala.joinpath("sessions.json").unlink()
    populate(aws)
    world["app"].state.spend._swr._next = 0
    browser.evaluate("document.dispatchEvent(new Event('visibilitychange')); ''")
    assert wait_for(browser, "document.querySelectorAll('#q-cards .s-card .q-err').length === 0 && document.querySelectorAll('#q-cards .s-card .c-v').length === 2", 30.0)


def test_before_the_first_count_the_card_is_quiet(world, page, browser):
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": """(() => { const real = window.fetch.bind(window);
      window.fetch = (url, opts) => String(url).startsWith("api/spend") ? Promise.resolve(new Response(JSON.stringify({ pending: true, lanes: [] }),
        { headers: { "Content-Type": "application/json" } })) : real(url, opts); })();"""})
    open_overview(browser, page())
    assert wait_for(browser, "document.querySelectorAll('#q-cards .s-card.q-pending').length === 2 && !document.querySelector('#q-cards .q-card:not(.s-card).q-pending')")
    for c in cards(browser):
        assert c["pending"] and c["figure"] == "—" and c["est"] == "Not yet available" and c["err"] is None, c
        assert c["chips"] == ["active"] and "lane-chip-pending" in c["chipCls"], c      # the invisible stand-in: no "Active" before it is known
    opacity = browser.evaluate("getComputedStyle(document.querySelector('#q-cards .s-card.q-pending .c-figs')).opacity")
    assert float(opacity) < 0.6


def test_a_failed_request_keeps_the_figures_and_says_so(world, aws, page, browser):
    populate(aws)
    open_overview(browser, page())
    assert wait_for(browser, READY)
    browser.evaluate("""(() => { const real = window.fetch.bind(window); window.fetch = (url, opts) => String(url).startsWith("api/spend")
      ? Promise.resolve(new Response("nope", { status: 500 })) : real(url, opts); })()""")
    browser.evaluate("document.dispatchEvent(new Event('visibilitychange')); ''")
    assert wait_for(browser, "document.querySelectorAll('#q-cards .s-card .q-err').length === 2")
    p = card_of(cards(browser), "aws-platform")
    assert p["err"] == "Could not refresh just now: Could not load the AWS spend (HTTP 500); retrying." and p["figure"] == "$5.00", p


# ── no label wraps or is cut, at any width ───────────────────────────────────
WIDE = {"month": "2026-10", "since": START.strftime("%Y-%m-%dT%H:%M:%SZ"), "fetchedAt": int((NOW - timedelta(minutes=40)).timestamp() * 1000),
        "lanes": [
            {"lane": "aws-platform", "configured": True, "monthUsd": 12345.67, "calls": 9, "unmatched": ["ghost-one", "ghost-two"],
             "unpriced": [{"model": "claude-opus-4-8", "calls": 1200, "tokens": 5}],
             "models": [{"model": "claude-fable-5-1", "usd": 9000.0, "calls": 4}, {"model": "claude-opus-5-5", "usd": 3000.5, "calls": 4},
                        {"model": "claude-haiku-4-5", "usd": 0.001, "calls": 1}],
             "sessions": [{"name": n, "sessionId": str(i), "usd": 2000.0 / (i + 1), "share": 2000.0 / (i + 1) / 12345.67, "live": i % 2 == 0}
                          for i, n in enumerate(["demo-a", "demo-b", "demo-c", "demo-d", "demo-e", "demo-f",
                                                 "demo-g-long-name-for-the-wrap-check-notes-main"])]},
        ]}
WIDE["lanes"].append({**WIDE["lanes"][0], "lane": "bedrock"})   # bedrock carries the same long lists (neither Overview card draws them; each lane's details page does)


def wide_stub(answer) -> str:
    return """(() => { const real = window.fetch.bind(window); window.fetch = (url, opts) => String(url).startsWith("api/spend")
      ? Promise.resolve(new Response(JSON.stringify(%s), { headers: { "Content-Type": "application/json" } })) : real(url, opts); })();""" % json.dumps(answer)


def assert_rows_inside(browser, sel):
    """A long session name is cut with an ellipsis inside its row: no row is wider than its card, and the full name is the title."""
    bad = browser.evaluate("""[...document.querySelectorAll(%s)].flatMap((c) => { const cr = c.getBoundingClientRect();
      return [...c.querySelectorAll(".s-row, .s-row > *")].filter((e) => e.getBoundingClientRect().right > cr.right + 0.5 || e.scrollWidth > e.clientWidth + 1 && !e.matches(".s-name"))
        .map((e) => e.className + ": " + e.textContent); })""" % json.dumps(sel))
    assert bad == [], bad


@pytest.mark.parametrize("width", WIDTHS)
def test_the_spend_cards_keep_every_label_on_one_line_at_any_width(world, page, browser, width):
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": wide_stub(WIDE)})
    open_overview(browser, page(), width=width)
    viewport(browser, width)
    assert wait_for(browser, "document.querySelectorAll('#q-cards .s-card .lane-chip:not(.lane-chip-pending)').length === 2")
    got = browser.evaluate(f"({MEASURE_S})('#q-cards > .s-card')")
    assert len(got["cards"]) == 2
    report(got, width)
    for c in cards(browser):
        assert c["models"] is None and c["sessions"] is None and c["more"] is None, c   # neither AWS card lists them on the Overview
    assert_rows_inside(browser, "#q-cards > .s-card")
    # all the other cards of the Overview still hold
    report(browser.evaluate(f"({MEASURE_S})('#q-cards > .q-card')"), width)


@pytest.mark.parametrize("lane", ["aws-platform", "bedrock"])
@pytest.mark.parametrize("width", WIDTHS)
def test_the_details_page_card_keeps_every_label_on_one_line_at_any_width(world, page, browser, lane, width):
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": wide_stub(WIDE)})
    open_overview(browser, page(), width=width)
    viewport(browser, width)
    assert wait_for(browser, "document.querySelectorAll('#q-cards .s-card .lane-chip:not(.lane-chip-pending)').length === 2")
    browser.evaluate(f"location.hash = '#lane={lane}'")
    assert wait_for(browser, "document.body.classList.contains('lane-open') && !!document.querySelector('#ld-usage .s-card:not(.q-pending)')")
    report(browser.evaluate(f"({MEASURE_S})('#ld-usage .s-card')"), width)
    assert_rows_inside(browser, "#ld-usage .s-card")
    assert len(cards(browser, "'#ld-usage .s-card'")[0]["sessions"]) == 7        # the details page lists all of them, aws platform's included
