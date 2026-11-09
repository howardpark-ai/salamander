"""The Digest view's sentence builder (usage_digest.py) and its route (GET /api/usage/digest): the week in a few plain sentences, written by code
from the rows the Usage analysis tab already counts.

What a wrong answer costs: a sentence that says a figure the Report does not (a total, a billed share, a busiest day or a top name that differs from
the table), flat-plan dollars described as billed, a comparison the wrong way round ("up" for a drop) or against the wrong hours, a limit shown for a
week that is over, a literal "NaN", "undefined" or "None" or an ISO date in a sentence read by a person, a token count where dollars belong, a week with
no replies or with no earlier week to compare with that breaks instead of saying so, wording that changes with the order of the rows (a scheduled job
that delivers it would send a different report each time), a model call or a second transcript scan hiding behind the route, and a wording that drifts
away from the Report's own (the flat-plan and machines notes live in static/usage.js).

The builder is a pure function over made-up answers (no transcript, no clock). The route runs over fake transcripts in tmp_path: nothing asks Anthropic
or AWS and no real sala runs (conftest.py).
"""

from __future__ import annotations

import copy
import json
import re
import time

import pytest
from starlette.testclient import TestClient

from sala_web import usage as U
from sala_web import usage_digest as G
from sala_web.app import STATIC, create_app
from test_usage import A, B, SECRET, World, prompt, reply   # noqa: F401  (the fake transcripts and registry are the data layer's own)

FIELDS = ["day", "lane", "model", "project", "agent", "folder", "usd", "replies", "tokens"]
RESET_EPOCH = 1794200400   # Mon Nov 9th 2026 14:00 KST


def row(day, lane, model, project, agent, usd, replies):
    return [day, lane, model, project, agent, "/srv/people/u1", usd, replies, [0, 0, 0, 0, 0]]


def week(i, total, billed, replies, start="2026-10-28T14:00", end="2026-11-04T14:00"):
    return {"id": i, "start": 0, "end": 0, "startKst": start, "endKst": end, "days": [], "current": i == 0, "total": total, "billed": billed, "replies": replies}


def lane(code, label, flat, quota=None):
    return {"code": code, "label": label, "billing": "subscription" if flat else "usage", "flat": flat, "known": True, "quota": quota}


ROWS = [
    row("2026-11-04", "lane-1", "claude-opus-5", "proj-a", "proj-a-main", 120.50, 40),
    row("2026-11-05", "lane-1", "claude-sonnet-5-5", "proj-a", "proj-a-build", 30.25, 10),
    row("2026-11-05", "lane-2", "claude-sonnet-5-5", "proj-b", "proj-b-main", 12.40, 5),
    row("2026-11-06", "lane-2", "claude-opus-5", "(unnamed)", "(unnamed)", 3.10, 2),
]
LANES = [lane("lane-1", "Lane One", True, {"percent": 42.0, "resetsAt": RESET_EPOCH}), lane("lane-2", "Lane Two", False)]


def answer(week_id=0, rows=ROWS, lanes=LANES, weeks=None, same=120.0, reset=True):
    if weeks is None:
        weeks = [week(0, 166.25, 15.5, 57, "2026-11-04T14:00", "2026-11-11T14:00"), week(1, 100.0, 10.0, 30), week(2, 80.0, 9.0, 20, "2026-10-21T14:00", "2026-10-28T14:00")]
    return {"week": week_id, "resetKnown": reset, "fields": FIELDS, "rows": copy.deepcopy(rows), "weeks": weeks, "lanes": copy.deepcopy(lanes),
            "sameHours": {"prevTotal": same, "elapsedH": 70.0} if week_id == 0 else None}


# ── the sentences of a normal week ───────────────────────────────────────────
def test_the_running_week_in_seven_sentences_from_the_total_to_the_weekly_limit():
    assert G.digest(answer()) == [
        "This week, since Wed Nov 4th, 57 replies on this machine cost $166.25 at list prices: $15.50 was billed, and the other $150.75 ran on a flat plan, so it was not billed.",
        "The busiest day was Wed Nov 4th: $120.50, or 72% of the week.",
        "The largest share ran on Lane One (flat plan, not billed): $150.75, or 91% of the week.",
        "Opus 5 took the most among the models: $123.60, or 74% of the week.",
        "The project that took the most was proj-a ($150.75, or 91%), and the agent that took the most was proj-a-main ($120.50, or 72%).",
        "Compared with the same hours of the week before ($120.00), that is up 39%, or $46.25 more.",
        "Lane One's weekly limit is 42% used so far, and it resets on Mon Nov 9th at 2:00 PM KST.",
    ]


def test_a_closed_week_names_its_days_compares_with_the_week_before_it_and_has_no_limit_sentence():
    got = G.digest(answer(1))
    assert got[0].startswith("Last week (Wed Oct 28th to Wed Nov 4th), 57 replies on this machine cost $166.25 at list prices")
    assert got[-1] == "Compared with the week before it ($80.00), that is up 108%, or $86.25 more."
    assert not any("limit" in s for s in got)
    assert 4 <= len(got) <= 7


def test_the_oldest_week_says_there_is_no_earlier_week_to_compare_with():
    got = G.digest(answer(2))
    assert got[0].startswith("Two weeks ago (Wed Oct 21st to Wed Oct 28th),")
    assert got[-1] == "The count reaches back three weeks, so there is no earlier week to compare this one with."


def test_a_drop_is_down_the_same_is_about_the_same_and_an_earlier_week_with_no_spend_is_said_plainly():
    assert G.digest(answer(same=200.0))[5] == "Compared with the same hours of the week before ($200.00), that is down 17%, or $33.75 less."
    assert G.digest(answer(same=166.0))[5] == "That is about the same as the same hours of the week before ($166.00)."
    zero = G.digest(answer(same=0.0))[5]
    assert zero == "Nothing had been spent over the same hours of the week before, and it ended at $100.00, so there is no change to work out."
    weeks = [week(0, 166.25, 15.5, 57), week(1, 0.0, 0.0, 0), week(2, 0.0, 0.0, 0)]
    first = G.digest(answer(weeks=weeks, same=0.0))
    assert first[5] == "Nothing was counted in the week before, so there is nothing to compare this week with."
    assert G.digest(answer(1, weeks=weeks))[-1] == "Nothing was counted in the week before, so there is nothing to compare this week with."


def test_the_limit_is_for_the_running_week_only_and_only_when_the_quota_answer_has_it():
    assert any("weekly limit" in s for s in G.digest(answer()))
    no_quota = [lane("lane-1", "Lane One", True, None), lane("lane-2", "Lane Two", False)]
    assert not any("limit" in s for s in G.digest(answer(lanes=no_quota)))
    per_use_quota = [lane("lane-1", "Lane One", True), lane("lane-2", "Lane Two", False, {"percent": 10, "resetsAt": RESET_EPOCH})]
    assert not any("limit" in s for s in G.digest(answer(lanes=per_use_quota)))                     # a limit belongs to a flat plan
    two = [lane("lane-1", "Lane One", True, {"percent": 4.5, "resetsAt": RESET_EPOCH}), lane("lane-2", "Lane Two", True, {"percent": 100, "resetsAt": RESET_EPOCH + 3600})]
    assert G.digest(answer(lanes=two))[-1] == ("Lane One's weekly limit is 4.5% used so far, and it resets on Mon Nov 9th at 2:00 PM KST; "
                                               "Lane Two's weekly limit is 100% used so far, and it resets on Mon Nov 9th at 3:00 PM KST.")
    assert not any("limit" in s for s in G.digest(answer(1, lanes=two)))


# ── partial and odd weeks ────────────────────────────────────────────────────
def test_a_week_with_no_replies_says_so_in_one_sentence():
    assert G.digest(answer(rows=[], weeks=[week(0, 0, 0, 0, "2026-11-04T14:00", "2026-11-11T14:00"), week(1, 0, 0, 0), week(2, 0, 0, 0)])) == \
        ["This week, since Wed Nov 4th, no replies were counted on this machine."]


def test_replies_on_a_model_with_no_price_are_a_zero_and_never_a_division_by_zero():
    rows = [row("2026-11-04", "lane-1", "mystery-model", "proj-a", "proj-a-main", 0.0, 3)]
    assert G.digest(answer(rows=rows)) == ["This week, since Wed Nov 4th, 3 replies on this machine cost $0.00, because no list price is known for the models used."]


def test_only_flat_plan_spend_is_none_of_it_billed_and_all_of_it_on_one_lane_one_model_one_day():
    rows = [row("2026-11-05", "lane-1", "claude-opus-5", "proj-a", "proj-a-main", 8.0, 1)]
    got = G.digest(answer(rows=rows, weeks=[week(0, 8.0, 0.0, 1, "2026-11-04T14:00", "2026-11-11T14:00"), week(1, 0, 0, 0), week(2, 0, 0, 0)]))
    assert got[:5] == [
        "This week, since Wed Nov 4th, 1 reply on this machine cost $8.00 at list prices, and none of it was billed.",
        "All of it was on Thu Nov 5th.",
        "All of it ran on Lane One (flat plan, not billed).",
        "All of it used Opus 5.",
        "All of it was in the project proj-a, and the agent that took the most was proj-a-main ($8.00, or 100%).",
    ]


def test_spend_on_per_use_lanes_only_is_all_of_it_billed():
    rows = [row("2026-11-05", "lane-2", "claude-sonnet-5-5", "proj-b", "proj-b-main", 5.0, 2), row("2026-11-06", "lane-2", "claude-sonnet-5-4", "proj-b", "proj-b-main", 5.0, 2)]
    got = G.digest(answer(rows=rows))
    assert got[0].endswith("cost $10.00 at list prices, and all of it was billed.")
    assert got[2] == "All of it ran on Lane Two (billed per use, estimate)."
    assert got[1] == "The busiest day was Thu Nov 5th: $5.00, or 50% of the week."          # a tie goes to the earlier day, whatever the order of the rows


def test_sessions_with_no_name_are_said_in_words_and_not_as_a_literal():
    rows = [row("2026-11-05", "lane-1", "claude-opus-5", "(unnamed)", "(unnamed)", 9.0, 3), row("2026-11-05", "lane-1", "claude-opus-5", "proj-a", "proj-a-main", 1.0, 1)]
    got = G.digest(answer(rows=rows))
    assert got[4] == "Sessions sala does not know by name took the most ($9.00, or 90%)."
    only = G.digest(answer(rows=rows[:1]))
    assert only[4] == "All of it was sessions sala does not know by name."
    many = [row("2026-11-05", "lane-1", "claude-opus-5", "(unnamed)", "(unnamed)", 3.0, 3), row("2026-11-05", "lane-1", "claude-opus-5", "proj-c", "proj-c-main", 4.0, 1),
            row("2026-11-05", "lane-1", "claude-opus-5", "proj-c", "proj-c-two", 1.0, 1)]
    assert G.digest(answer(rows=many))[4] == "The project that took the most was proj-c ($5.00, or 62%), and the agent that took the most was proj-c-main ($4.00, or 50%)."
    big = [row("2026-11-05", "lane-1", "claude-opus-5", "(unnamed)", "(unnamed)", 6.0, 3), row("2026-11-05", "lane-1", "claude-opus-5", "proj-c", "proj-c-main", 4.0, 1),
           row("2026-11-05", "lane-1", "claude-opus-5", "proj-a", "proj-a-main", 2.0, 1)]
    assert G.digest(answer(rows=big))[4] == "Sessions sala does not know by name took the most ($6.00, or 50%)."
    assert not any("(unnamed)" in s for s in got + only + G.digest(answer(rows=many)) + G.digest(answer(rows=big)))


def test_without_a_known_weekly_reset_the_weeks_are_the_last_seven_days_and_the_ones_before():
    assert G.digest(answer(reset=False))[0].startswith("In the last seven days, 57 replies")
    assert G.digest(answer(1, reset=False))[0].startswith("In the seven days before that,")
    assert G.digest(answer(2, reset=False))[0].startswith("In the seven days before those,")


def test_one_reply_is_singular_and_a_thousand_gets_a_comma():
    rows = [row("2026-11-05", "lane-2", "claude-opus-5", "proj-b", "proj-b-main", 1234.5, 1234)]
    assert "1,234 replies on this machine cost $1,234.50" in G.digest(answer(rows=rows))[0]


# ── properties every answer keeps ────────────────────────────────────────────
BAD = re.compile(r"\bNaN\b|\bnan\b|\bNone\b|\bundefined\b|\bnull\b|\b[Ii]nfinity\b|\b[Tt]okens?\b|\b\d{4}-\d{2}-\d{2}\b|[{}\[\]]")


@pytest.mark.parametrize("variant", ["normal", "closed", "oldest", "empty", "unpriced", "flat", "unknown-reset", "no-comparison", "tiny"])
def test_no_sentence_has_a_placeholder_an_iso_date_or_a_token_count_and_there_are_never_more_than_seven(variant):
    weeks0 = [week(0, 166.25, 15.5, 57, "2026-11-04T14:00", "2026-11-11T14:00"), week(1, 100.0, 10.0, 30), week(2, 80.0, 9.0, 20)]
    kw = {"normal": {}, "closed": {"week_id": 1}, "oldest": {"week_id": 2}, "empty": {"rows": []}, "unknown-reset": {"reset": False},
          "unpriced": {"rows": [row("2026-11-04", "lane-1", "x", "p", "a", 0.0, 2)]},
          "flat": {"rows": [row("2026-11-04", "lane-1", "claude-opus-5", "p", "a", 3.0, 2)]},
          "no-comparison": {"weeks": [week(0, 5, 5, 3), week(1, 0, 0, 0), week(2, 0, 0, 0)]},
          "tiny": {"rows": [row("2026-11-04", "lane-2", "claude-haiku-4-5", "p", "a", 0.004, 1)]}}[variant]
    got = G.digest(answer(**{**{"weeks": weeks0}, **kw}))
    assert 1 <= len(got) <= 7
    for s in got:
        assert s.endswith(".") and not BAD.search(s), s
        assert "$" not in s or re.search(r"\$\d", s)


def test_the_sentences_do_not_depend_on_the_order_of_the_rows_and_a_normal_week_has_four_to_seven():
    a = answer()
    b = answer()
    b["rows"].reverse()
    assert G.digest(a) == G.digest(b) == G.digest(a)
    assert 4 <= len(G.digest(a)) <= 7


def test_all_of_it_is_said_only_when_it_is_all_and_a_share_that_rounds_to_the_whole_is_over_99_percent():
    rows = [row("2026-11-04", "lane-2", "claude-opus-5", "p", "a", 100.0, 2), row("2026-11-05", "lane-2", "claude-sonnet-5-5", "p", "b", 0.2, 1)]
    got = G.digest(answer(rows=rows))
    assert got[1] == "The busiest day was Wed Nov 4th: $100.00, or over 99% of the week."
    assert got[2] == "All of it ran on Lane Two (billed per use, estimate)."
    assert got[3] == "Opus 5 took the most among the models: $100.00, or over 99% of the week."
    assert got[4] == "All of it was in the project p, and the agent that took the most was a ($100.00, or over 99%)."
    assert G.percent(0.2, 100) == "under 1%" and G.percent(1, 100) == "1%" and G.percent(0.4, 100) == "under 1%" and G.percent(9.96, 100) == "10%"
    assert G.percent(72.4, 100) == "72%" and G.percent(4.5, 100) == "4.5%" and G.percent(100, 100) == "100%" and G.percent(5, 0) == "under 1%"


def test_odd_input_says_less_and_never_raises():
    assert G.digest({}) == [] and G.digest(None) == [] and G.digest({"week": 5, "weeks": []}) == [] and G.digest({"week": 0}) == []
    odd = answer()
    odd["rows"] = [None, [1], ["d"], row("2026-11-04", "lane-1", "claude-opus-5", "p", "a", float("nan"), "x"), row("2026-11-04", "lane-1", "claude-opus-5", "p", "a", 2.0, 1)]
    odd["weeks"] = [None, "x"]
    odd["lanes"] = [None, {"code": "lane-1", "flat": True, "quota": {"percent": "x"}}]
    odd["sameHours"] = "x"
    got = G.digest(odd)
    assert got and all(not BAD.search(s) for s in got), got


def test_dates_read_like_sat_nov_7th_and_money_like_12_40():
    assert [G.day_text(f"2026-11-{d:02d}") for d in (1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 30)] == [
        "Sun Nov 1st", "Mon Nov 2nd", "Tue Nov 3rd", "Wed Nov 4th", "Wed Nov 11th", "Thu Nov 12th", "Fri Nov 13th", "Sat Nov 21st", "Sun Nov 22nd", "Mon Nov 23rd", "Mon Nov 30th"]
    assert G.day_text("2026-11-07") == "Sat Nov 7th" and G.day_text("nonsense") == "nonsense"
    assert G.time_text(RESET_EPOCH) == "Mon Nov 9th at 2:00 PM KST" and G.time_text(RESET_EPOCH - 5 * 3600 - 1800) == "Mon Nov 9th at 8:30 AM KST"
    assert G.time_text(RESET_EPOCH + 10 * 3600) == "Tue Nov 10th at 12:00 AM KST"
    assert G.money(12.4) == "$12.40" and G.money(0) == "$0.00" and G.money(1234567.891) == "$1,234,567.89"
    assert [G.model_text(m) for m in ("claude-opus-5", "claude-sonnet-4-5", "claude-sonnet-5-5-20260101", "claude-opus-5[1m]", "something-else")] == [
        "Opus 5", "Sonnet 4.5", "Sonnet 5.5", "Opus 5 (1M)", "something-else"]


# ── no model, one count, the Report's words ──────────────────────────────────
def test_the_module_imports_nothing_that_could_call_a_model_or_read_a_file():
    src = (STATIC.parent / "usage_digest.py").read_text()
    assert sorted(set(re.findall(r"^(?:from|import) ([\w.]+)", src, re.M))) == ["__future__", "datetime", "re"]


def test_the_wording_shared_with_the_report_is_the_reports_own():
    js = (STATIC / "usage.js").read_text()
    assert G.FLAT in js and G.PER_USE in js and G.SCOPE in js, "usage_digest.py's FLAT, PER_USE and SCOPE must be the words of usage.js's WORDS block"
    assert re.search(r'weeks: \["This week", "Previous week", "2 weeks ago"\]', js)


# ── the route ────────────────────────────────────────────────────────────────
@pytest.fixture
def world(tmp_path, monkeypatch):
    from sala_web import sessions as S
    monkeypatch.setattr(S, "live_tmux_names", lambda: {})
    return World(tmp_path)


def digest_of(c, query="week=0", tries=100):
    """The digest once a count has been made: a visit makes none, so a "noCount" answer is followed by one Reload (`fresh=1`)."""
    reloaded = False
    for _ in range(tries):
        r = c.get(f"/api/usage/digest?{query}" + ("&fresh=1" if reloaded == "now" else ""))
        assert r.status_code == 200, r.text
        d = r.json()
        if reloaded == "now":
            reloaded = True
        elif d.get("noCount") and not reloaded:
            reloaded = "now"
            continue
        if not d.get("pending") and not d.get("refreshing"):
            return d
        time.sleep(0.1)
    raise AssertionError("the count never finished")


def test_the_route_writes_the_sentences_of_the_report_s_own_count_with_one_scan_and_no_text_of_a_transcript(world, monkeypatch):
    now = time.time()
    world.registry("example-alpha-build", A)
    world.transcript(A, prompt(now - 3600, cwd="/srv/people/u1"), reply("m1", "claude-sonnet-5-5", now - 3600, out=100_000),
                     reply("m2", "claude-sonnet-5-5", now - 8 * 86400, out=200_000), mtime=now)
    counts = []
    real = U.compute
    monkeypatch.setattr(U, "compute", lambda *a, **k: counts.append(1) or real(*a, **k))
    with TestClient(create_app(world.settings)) as c:
        first = c.get("/api/usage/digest?week=0").json()
        assert first.get("noCount") and not first.get("pending") and first["sentences"] == [], first   # at once, and no count made by looking
        d0 = digest_of(c, "week=0")
        d1 = digest_of(c, "week=1")
        report = c.get("/api/usage?week=0").json()
        bad = [c.get(f"/api/usage/digest?week={x}") for x in ("3", "-1", "x")]
    assert len(counts) == 1, "the digest reads the Report's cached count: one scan for both routes"
    assert d0["week"] == 0 and d1["week"] == 1 and d0["scope"] == G.SCOPE and d0["tzLabel"] == "KST" and d0["range"]["current"] is True and d1["range"]["current"] is False
    assert d0["sentences"] == G.digest(report)
    assert d0["sentences"][0].startswith("In the last seven days, 1 reply on this machine cost $1.00 at list prices, and none of it was billed.")
    assert any(s.startswith("Compared with the same hours of the week before ($2.00), that is down 50%, or $1.00 less.") for s in d0["sentences"])
    assert d1["sentences"][0].startswith("In the seven days before that, 1 reply on this machine cost $2.00")
    assert [x.status_code for x in bad] == [400, 400, 400]
    assert SECRET not in json.dumps([d0, d1]) and "token" not in json.dumps(d0["sentences"]).lower()


def test_before_any_count_the_answer_says_so_with_no_sentences():
    out = G.answer({"noCount": True, "week": 2, "weeks": [], "rows": []})
    assert out["noCount"] is True and "pending" not in out and out["sentences"] == [] and out["week"] == 2 and out["range"] is None


def test_while_a_reloads_count_runs_the_answer_is_pending_with_no_sentences():
    out = G.answer({"pending": True, "week": 1, "weeks": [], "rows": []})
    assert out["pending"] is True and out["sentences"] == [] and out["week"] == 1 and out["range"] is None and out["scope"] == G.SCOPE


def test_a_failed_count_keeps_the_last_sentences_and_carries_the_error_in_words():
    a = answer()
    a["error"] = "the usage could not be counted (RuntimeError)"
    out = G.answer(a)
    assert out["error"] == a["error"] and out["sentences"] == G.digest(answer()) and out["range"]["current"] is True
    assert G.answer(None)["sentences"] == [] and G.answer("x")["week"] == 0


def test_the_route_is_in_the_apps_route_table_and_the_header_comment(world):
    app = create_app(world.settings)
    assert "/api/usage/digest" in [getattr(r, "path", "") for r in app.routes]
    assert "/api/usage/digest?week=<0|1|2>" in (STATIC.parent / "app.py").read_text()
