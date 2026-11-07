"""Explorer's drill-down on the Usage analysis tab's data layer (usage.py: reply_list, UsageCache.replies, GET /api/usage/replies): the single replies
behind a filter, newest first, capped, with the count and the dollars of all that match.

What a wrong answer costs: a drill-down whose dollars are not the dollars of the row it was opened from (the owner taps a figure and the replies behind it
do not add up to it), a reply counted twice or in the wrong week or on the wrong day, a list that is not the newest first or is not capped (a week with
tens of thousands of replies sent to a phone), a second read of every transcript for a tap, a prompt, a reply text or a token count in the answer, a filter
on a name that leaves the other names in, and a restart that serves a list of nothing as if there were no replies. Every transcript, registry and state
file here is a fake in tmp_path; nothing asks Anthropic or AWS.
"""

from __future__ import annotations

import json
import time

import pytest
from starlette.testclient import TestClient

from sala_web import usage as U
from sala_web.app import create_app

from test_usage import A, B, C, NOW, SECRET, at, fresh_times, get_usage, prompt, reply, rows_of, w   # noqa: F401  (the fake transcripts and registry are the data layer's own)


def fake_week(w):
    """Three agents on two lanes over three days of NOW's week: sonnet $1 + $2 + $3 (A, subscription-1), opus $5 (B, bedrock), sonnet $4 (C, subscription-1)."""
    w.registry("example-alpha-build", A)
    w.registry("example-beta-main", B, lane="bedrock")
    w.registry("example-alpha-test", C)
    w.transcript(A, prompt(at(22, 1), cwd="/work/example-repo"),
                 reply("a1", "claude-sonnet-5-5", at(22, 1), out=100_000), reply("a2", "claude-sonnet-5-5", at(22, 2), out=200_000),
                 reply("a3", "claude-sonnet-5-5", at(23, 1), out=300_000))
    w.transcript(B, prompt(at(22, 3), cwd="/work/other-repo"), reply("b1", "claude-opus-5", at(22, 3), out=200_000), proj="-work-other-repo")
    w.transcript(C, prompt(at(23, 2), cwd="/work/example-repo"), reply("c1", "claude-sonnet-5-5", at(23, 2), out=400_000))
    return w.count()


def store_of(w) -> dict:
    return w.holder["replies"]


# ── the list ─────────────────────────────────────────────────────────────────
def test_the_replies_of_a_filter_are_listed_newest_first_with_the_time_in_kst_and_add_up_to_the_row_they_come_from(w):
    got = fake_week(w)
    out = U.reply_list(store_of(w), 0, {"lane": ["subscription-1"], "model": ["claude-sonnet-5-5"]})
    assert out["fields"] == U.REPLY_FIELDS and out["total"] == 4 and out["shown"] == 4 and not out["capped"] and out["week"] == 0
    times = [r[0] for r in out["rows"]]
    assert times == sorted(times, reverse=True), "newest first"
    assert out["rows"][0] == ["2026-10-23T11:00:00", "2026-10-23", "subscription-1", "claude-sonnet-5-5", "example-alpha", "example-alpha-test", "/work/example-repo", pytest.approx(4.0)]
    assert times[-1] == "2026-10-22T10:00:00"                                                       # 01:00 UTC is 10:00 KST
    assert out["usd"] == pytest.approx(10.0) and sum(r[7] for r in out["rows"]) == pytest.approx(10.0)
    rows = [r for r in rows_of(got, lane="subscription-1", model="claude-sonnet-5-5")]
    assert sum(r[7] for r in rows) == pytest.approx(out["usd"]) and sum(r[8] for r in rows) == out["total"]   # the drill-down is the row, reply by reply


def test_every_dimension_filters_and_a_dimension_not_named_matches_anything(w):
    fake_week(w)
    st = store_of(w)
    assert U.reply_list(st, 0, {})["total"] == 5 and U.reply_list(st, 0, {})["usd"] == pytest.approx(15.0)
    assert U.reply_list(st, 0, {"day": ["2026-10-22"]})["total"] == 3
    assert U.reply_list(st, 0, {"model": ["claude-opus-5"]})["usd"] == pytest.approx(5.0)
    assert U.reply_list(st, 0, {"project": ["example-alpha"]})["total"] == 4
    assert U.reply_list(st, 0, {"agent": ["example-alpha-test"]})["usd"] == pytest.approx(4.0)
    assert U.reply_list(st, 0, {"folder": ["/work/other-repo"]})["total"] == 1
    assert U.reply_list(st, 0, {"lane": ["bedrock"], "day": ["2026-10-23"]})["total"] == 0                      # filters narrow each other
    assert U.reply_list(st, 0, {"lane": ["bedrock", "subscription-1"]})["total"] == 5                          # several values of one dimension are alternatives
    assert U.reply_list(st, 0, {"nonsense": ["x"], "lane": []})["total"] == 5                                    # an unknown name or an empty list filters nothing


def test_the_list_is_capped_and_says_how_many_there_are_in_all_and_their_dollars(w, monkeypatch):
    w.registry("example-alpha-build", A)
    w.transcript(A, prompt(at(22, 1), cwd="/work/example-repo"),
                 *[reply(f"m{i}", "claude-sonnet-5-5", at(22, 1) + i * 60, out=10_000) for i in range(30)])   # 30 replies of $0.10
    w.count()
    st = store_of(w)
    out = U.reply_list(st, 0, {}, limit=10)
    assert out["shown"] == 10 and out["total"] == 30 and out["capped"] and out["usd"] == pytest.approx(3.0)
    assert [r[0] for r in out["rows"]] == [f"2026-10-22T10:{29 - i:02d}:00" for i in range(10)], "the ten newest"
    monkeypatch.setattr(U, "REPLIES_CAP", 12)
    out = U.reply_list(st, 0, {}, limit=500)
    assert out["shown"] == 12 and out["cap"] == 12 and out["capped"], "a larger limit than the cap is the cap"
    assert U.reply_list(st, 0, {}, limit=0)["shown"] == 1, "never an empty page for a nonsense limit"


def test_a_reply_lands_in_its_own_week_and_a_forked_or_streamed_reply_is_listed_once(w):
    w.registry("example-alpha-build", A)
    w.registry("example-alpha-test", C)
    line = reply("m1", "claude-sonnet-5-5", at(22, 1), out=100_000)
    w.transcript(A, prompt(at(22, 1)), line, line, reply("m1", "claude-sonnet-5-5", at(22, 1), out=150_000), reply("old", "claude-sonnet-5-5", at(15, 1), out=200_000))
    w.transcript(C, line)                                                                # a fork copies history
    w.count()
    st = store_of(w)
    this, prev = U.reply_list(st, 0, {}), U.reply_list(st, 1, {})
    assert (this["total"], prev["total"]) == (1, 1) and U.reply_list(st, 2, {})["total"] == 0
    assert this["usd"] == pytest.approx(1.5), "the largest counts of the one reply"
    assert prev["rows"][0][0] == "2026-10-15T10:00:00"


def test_a_model_with_no_price_is_listed_at_zero_dollars_never_dropped(w):
    w.registry("example-alpha-build", A)
    w.transcript(A, reply("m1", "claude-mystery-9", at(22, 1), out=100_000))
    w.count()
    out = U.reply_list(store_of(w), 0, {})
    assert out["total"] == 1 and out["usd"] == 0 and out["rows"][0][3] == "claude-mystery-9"


def test_the_records_hold_no_text_and_no_token_count(w):
    fake_week(w)
    st = store_of(w)
    assert SECRET not in json.dumps(st) and SECRET not in json.dumps(U.reply_list(st, 0, {}))
    assert all(len(r) == 3 for r in st["recs"]), "a reply's record is its time, its row key and its dollars: no token field"


def test_a_second_count_replaces_the_records_whole_and_reads_no_transcript(w, monkeypatch):
    fake_week(w)
    first = store_of(w)
    monkeypatch.setattr(U.Reader, "read_new", lambda *a, **k: (_ for _ in ()).throw(AssertionError("a transcript was opened")))
    w.count()
    second = store_of(w)
    assert second is not first and second["recs"] == first["recs"] and second["keys"] == first["keys"]


# ── the endpoint ─────────────────────────────────────────────────────────────
def replies_of(c, query="week=0", tries=100):
    for _ in range(tries):
        r = c.get(f"/api/usage/replies?{query}")
        assert r.status_code == 200, r.text
        d = r.json()
        if not d.get("pending"):
            return d
        time.sleep(0.1)
    raise AssertionError("the replies never came")


def test_the_endpoint_lists_the_replies_behind_a_filter_and_they_add_up_to_the_report_row(w):
    one_hour_ago, eight_days_ago = fresh_times()
    w.registry("example-alpha-build", A)
    w.transcript(A, prompt(one_hour_ago, cwd="/work/example-repo"), reply("m1", "claude-sonnet-5-5", one_hour_ago, out=100_000),
                 reply("m2", "claude-sonnet-5-5", eight_days_ago, out=200_000), mtime=time.time())
    with TestClient(create_app(w.settings)) as c:
        first = c.get("/api/usage/replies?week=0").json()
        assert first.get("pending") or first["rows"], first                                         # at once: the list, or "pending" the page asks again on
        d0 = replies_of(c, "week=0&lane=subscription-1")
        d1 = replies_of(c, "week=1")
        rep = get_usage(c, "week=0")
        none = replies_of(c, "week=0&lane=bedrock")
        bad = [c.get(f"/api/usage/replies?{q}") for q in ("week=3", "week=x", "week=-1", "week=0&limit=0", "week=0&limit=x")]
    assert d0["fields"] == U.REPLY_FIELDS and d0["total"] == 1 and d0["shown"] == 1 and not d0["capped"]
    assert d0["rows"][0][2:7] == ["subscription-1", "claude-sonnet-5-5", "example-alpha", "example-alpha-build", "/work/example-repo"]
    assert d0["usd"] == pytest.approx(rep["rows"][0][6]) and d1["usd"] == pytest.approx(2.0) and d1["total"] == 1
    assert none["total"] == 0 and none["rows"] == []
    assert [x.status_code for x in bad] == [400] * 5
    assert SECRET not in json.dumps([d0, d1])


def test_the_endpoint_filters_on_repeated_names_as_alternatives_and_ignores_names_it_does_not_know(w):
    one_hour_ago, _ = fresh_times()
    w.registry("example-alpha-build", A)
    w.registry("example-beta-main", B, lane="bedrock")
    w.transcript(A, reply("a1", "claude-sonnet-5-5", one_hour_ago, out=100_000), mtime=time.time())
    w.transcript(B, reply("b1", "claude-opus-5", one_hour_ago, out=100_000), mtime=time.time(), proj="-work-other-repo")
    with TestClient(create_app(w.settings)) as c:
        both = replies_of(c, "week=0&lane=bedrock&lane=subscription-1")
        one = replies_of(c, "week=0&model=claude-opus-5&tokens=1")
    assert both["total"] == 2 and one["total"] == 1 and one["rows"][0][3] == "claude-opus-5"


def test_after_a_restart_the_saved_rows_are_served_at_once_and_the_replies_are_pending_until_a_count_makes_them(w):
    one_hour_ago, _ = fresh_times()
    w.registry("example-alpha-build", A)
    w.transcript(A, reply("m1", "claude-sonnet-5-5", one_hour_ago, out=100_000), mtime=time.time())
    with TestClient(create_app(w.settings)) as c:
        get_usage(c, "week=0")
        assert replies_of(c)["total"] == 1                                                         # the first server counted: its replies are there
    with TestClient(create_app(w.settings)) as c:                                                  # a new process, the state dir as it was left
        rows = c.get("/api/usage?week=0").json()
        assert not rows.get("pending") and rows["weeks"][0]["total"] == pytest.approx(1)           # the saved answer, at once
        first = c.get("/api/usage/replies?week=0").json()
        assert first.get("pending") and first["rows"] == []                                        # no records in this process yet: pending, never an empty list
        got = replies_of(c)
    assert got["total"] == 1 and got["usd"] == pytest.approx(1.0)


def test_with_no_records_and_a_failed_count_the_endpoint_says_so_in_words_and_not_pending_forever(w, monkeypatch):
    w.registry("example-alpha-build", A)

    def boom(*a, **k):
        raise RuntimeError(SECRET)

    monkeypatch.setattr(U, "compute", boom)
    with TestClient(create_app(w.settings)) as c:
        c.get("/api/usage/replies?week=0")
        for _ in range(100):
            d = c.get("/api/usage/replies?week=0").json()
            if d.get("error"):
                break
            time.sleep(0.1)
    assert d.get("error") and not d.get("pending") and SECRET not in json.dumps(d)
