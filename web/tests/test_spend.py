"""The AWS lanes' month-to-date spend (spend.py, GET /api/spend): an estimate at list prices counted from this
machine's own Claude Code transcripts, per lane, per model and per session, for the aws-platform (Claude Platform on AWS)
and bedrock lanes, which have no usage or cost API we can read.

What a wrong answer costs: a figure the owner acts on that is too low (a streamed reply counted from its first line, whose
output tokens are partial; a cache write priced as an input token; a subagent's usage left out) or too high (a reply counted
twice because a fork copied its history, another lane's usage put on an AWS lane, last month's usage in this month), a
model with no price counted as $0 without a word, a re-read of every transcript on every refresh, or a prompt or a reply
leaving a transcript. The prices below are worked out by hand in the comments. Every transcript, registry and log is a fake
in tmp_path; nothing asks AWS or Anthropic and no real sala runs (conftest.py points the sala command at nothing).
"""

from __future__ import annotations

import json
import os
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone

import pytest
from starlette.testclient import TestClient

from sala_web import sessions as S
from sala_web import spend as SPD
from sala_web import swr as SWR
from sala_web.app import create_app
from sala_web.config import Settings

NOW = datetime(2026, 10, 23, 12, 0, tzinfo=timezone.utc)
A, B, C, D = (f"{c * 8}-0000-4000-8000-000000000001" for c in "abcd")
SECRET = "PROMPT-TEXT-THAT-MUST-NEVER-LEAVE"


def usage(inp=0, w5=0, w1=0, cr=0, out=0, legacy=False):
    """A message.usage as Claude Code writes it: the two cache-write tiers under cache_creation, or (legacy) only the sum."""
    u = {"input_tokens": inp, "cache_creation_input_tokens": w5 + w1, "cache_read_input_tokens": cr, "output_tokens": out}
    if not legacy:
        u["cache_creation"] = {"ephemeral_5m_input_tokens": w5, "ephemeral_1h_input_tokens": w1}
    return u


def line(mid, model, ts, **tok):
    """One assistant line of a transcript, with a reply text and a tool input that must never leave it."""
    return json.dumps({"type": "assistant", "uuid": f"u-{mid}-{tok}", "timestamp": ts, "requestId": f"req_{mid}",
                       "message": {"id": mid, "model": model, "usage": usage(**tok),
                                   "content": [{"type": "text", "text": SECRET},
                                               {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": SECRET}}]}}) + "\n"


def user_line(ts="2026-10-20T10:00:00.000Z"):
    return json.dumps({"type": "user", "timestamp": ts, "message": {"role": "user", "content": SECRET}}) + "\n"


@dataclass
class Live:
    session_id: str
    name: str
    lane: str | None
    started_at: int | None = None


class World:
    """A claude dir, a sala state dir and an sala-web state dir in tmp_path, and the count over them."""

    def __init__(self, tmp_path):
        self.tmp = tmp_path
        self.claude, self.sala, self.state = tmp_path / "claude", tmp_path / "sala", tmp_path / "state"
        self.claude.mkdir(parents=True)
        self.sala.mkdir()
        self.settings = Settings(socket=tmp_path / "s.sock", state_dir=self.state, claude_dir=self.claude,
                                 tmux_socket_name="salaweb-pytest-none", roles_cmd=["false"], sala_models=tmp_path / "none.tsv",
                                 sala_state_dir=self.sala, admin_key=tmp_path / "none-key")
        self.rows: list[dict] = []

    def registry(self, name, sid, lane="subscription-1", aliases=()):
        self.rows.append({"id": sid, "name": name, "lane": lane, "aliases": list(aliases), "state": "live",
                          "transcripts": [{"id": sid, "machine": "a", "at": "2026-10-01T00:00:00Z", "why": "import"}]})
        (self.sala / "sessions.json").write_text(json.dumps({"schema": 1, "sessions": {r["id"]: r for r in self.rows}}))

    def log(self, *rows):
        """lanes.log rows: (when, op, session, "old → new")."""
        with open(self.sala / "lanes.log", "a", encoding="utf-8") as f:
            for when, op, who, change in rows:
                f.write(f"{when}\t{op}\t{who}\t{change}\tpytest\n")

    def transcript(self, sid, *lines, sub=None, proj="-home-alex"):
        d = self.claude / "projects" / proj
        p = (d / sid / "subagents" / sub) if sub else (d / f"{sid}.jsonl")
        p.parent.mkdir(parents=True, exist_ok=True)
        with open(p, "a", encoding="utf-8") as f:
            f.writelines(lines)
        return p

    def count(self, live=(), configured=None, now=NOW, cache=True):
        return SPD.compute(self.settings, list(live), configured or {}, now,
                           self.state / "spend-scan.json" if cache else None, self.state / "spend-lanes.json" if cache else None)

    def lane(self, got, lane):
        return next(x for x in got["lanes"] if x["lane"] == lane)


def touch(path, when):
    """Set a file's modification time (a count skips transcripts not modified since its month began)."""
    os.utime(path, (when.timestamp(), when.timestamp()))


class _FrozenDatetime(datetime):
    """datetime whose now() is NOW, so the endpoint's "this month" is the fixtures' October whatever the real date is."""

    @classmethod
    def now(cls, tz=None):
        return NOW.astimezone(tz) if tz else NOW.replace(tzinfo=None)


@pytest.fixture(autouse=True)
def _pinned_clock(monkeypatch):
    """Every test in this file runs at NOW: the fixtures carry fixed October 2026 times, and spend.py reads the real clock
    (datetime.now) when the endpoint counts, so without this they pass only inside October 2026."""
    monkeypatch.setattr(SPD, "datetime", _FrozenDatetime)


@pytest.fixture
def w(tmp_path, monkeypatch):
    monkeypatch.setattr(S, "live_tmux_names", lambda: {})   # never the default tmux server's names
    return World(tmp_path)


# ── the model ids and the prices ─────────────────────────────────────────────
@pytest.mark.parametrize("raw, want", [
    ("claude-opus-5-5", "claude-opus-5-5"),
    ("global.anthropic.claude-opus-5-5", "claude-opus-5-5"),
    ("us.anthropic.claude-sonnet-5-5-v1:0", "claude-sonnet-5-5"),
    ("anthropic.claude-haiku-5-5-20260101-v1:0", "claude-haiku-5-5"),
    ("eu.anthropic.claude-opus-5-5", "claude-opus-5-5"),
    ("apac.anthropic.claude-haiku-4-5-20251001-v1:0", "claude-haiku-4-5"),
    ("claude-haiku-4-5-20251001", "claude-haiku-4-5"),
    ("claude-opus-5-5[1m]", "claude-opus-5-5"),
    ("CLAUDE-OPUS-5-5", "claude-opus-5-5"),
    # a bare ":0", Vertex's @date and @default, an inference-profile ARN, and the [1m] on a provider id
    ("anthropic.claude-opus-5-5:0", "claude-opus-5-5"),
    ("anthropic.claude-3-5-sonnet-20241022-v2:0", "claude-3-5-sonnet"),
    ("claude-sonnet-4-5@20250929", "claude-sonnet-4-5"),
    ("claude-opus-5-5@default", "claude-opus-5-5"),
    ("arn:aws:bedrock:us-east-1:123456789012:inference-profile/global.anthropic.claude-sonnet-5-5", "claude-sonnet-5-5"),
    ("arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.anthropic.claude-haiku-4-5-20251001-v1:0", "claude-haiku-4-5"),
    ("global.anthropic.claude-opus-5-5[1m]", "claude-opus-5-5"),
    ("<synthetic>", "<synthetic>"),
    (None, ""),
])
def test_a_model_id_is_normalised_whatever_the_lane_calls_it(raw, want):
    assert SPD.normalize_model(raw) == want


def test_the_widened_forms_price_like_the_plain_id():
    tok = [10**6] * 5
    for raw in ("anthropic.claude-opus-5-5:0", "claude-opus-5-5@20260101", "claude-opus-5-5@default",
                "arn:aws:bedrock:us-east-1:1:inference-profile/global.anthropic.claude-opus-5-5"):
        assert SPD.price(raw, tok) == SPD.price("claude-opus-5-5", tok) is not None, raw
    assert SPD.price("global.anthropic.nonsense", tok) is None


def test_prices_are_list_price_with_each_cache_tier_apart():
    # a million of every kind of token on Opus 5.5: $4 input + $5 five-minute cache write + $8 one-hour cache write + $0.20 cache read + $20 output
    assert SPD.price("claude-opus-5-5", [10**6] * 5) == pytest.approx(37.2)
    # Sonnet 5.5: 1000 in at $2, 2000 five-minute writes at $2.50, 3000 one-hour writes at $4, 4000 reads at $0.10, 500 out at $10 per MTok:
    # (2000 + 5000 + 12000 + 400 + 5000) / 1e6
    assert SPD.price("claude-sonnet-5-5", [1000, 2000, 3000, 4000, 500]) == pytest.approx(0.0244)
    # Haiku 5.5: (100 * 0.1 + 100 * 0.125 + 100 * 0.2 + 100 * 0.01 + 100 * 0.5) / 1e6 = 0.0000935
    assert SPD.price("claude-haiku-5-5", [100] * 5) == pytest.approx(0.0000935)
    # a Bedrock id is the same model at the same price
    assert SPD.price("global.anthropic.claude-sonnet-5-5-v1:0", [1000, 2000, 3000, 4000, 500]) == pytest.approx(0.0244)
    assert SPD.price("claude-opus-4-8", [1, 1, 1, 1, 1]) is None     # no rate: None, never 0


def test_usage_tokens_reads_both_cache_tiers_and_an_old_row_as_five_minute():
    assert SPD.usage_tokens(usage(inp=1, w5=2, w1=3, cr=4, out=5)) == [1, 2, 3, 4, 5]
    assert SPD.usage_tokens(usage(inp=1, w5=7, cr=4, out=5, legacy=True)) == [1, 7, 0, 4, 5]
    assert SPD.usage_tokens({}) == [0, 0, 0, 0, 0]
    assert SPD.usage_tokens({"input_tokens": "x", "output_tokens": None, "cache_creation": {"ephemeral_1h_input_tokens": 9}}) == [0, 0, 9, 0, 0]


# ── the count ────────────────────────────────────────────────────────────────
def test_a_streamed_reply_is_counted_once_with_its_complete_usage_and_the_cache_tiers_apart(w):
    w.registry("aws-one", A, lane="aws-platform")
    w.transcript(A,
                 user_line(),
                 # one reply, streamed as three lines of the same message id: the output grows 10, 40, 90; the last is the reply's
                 line("msg_1", "claude-opus-5-5", "2026-10-20T10:00:01.000Z", inp=100, w1=2000, cr=5000, out=10),
                 line("msg_1", "claude-opus-5-5", "2026-10-20T10:00:02.000Z", inp=100, w1=2000, cr=5000, out=40),
                 line("msg_1", "claude-opus-5-5", "2026-10-20T10:00:03.000Z", inp=100, w1=2000, cr=5000, out=90),
                 line("msg_2", "claude-sonnet-5-5", "2026-10-20T10:01:00.000Z", inp=1000, w5=2000, w1=3000, cr=4000, out=500))
    got = w.count()
    aws = w.lane(got, "aws-platform")
    # msg_1: (100*4 + 2000*8 + 5000*0.20 + 90*20) / 1e6 = (400 + 16000 + 1000 + 1800) / 1e6 = 0.0192;  msg_2: 0.0244 (above)
    assert aws["monthUsd"] == pytest.approx(0.0436) and aws["calls"] == 2
    assert [(m["model"], m["usd"], m["calls"]) for m in aws["models"]] == [("claude-sonnet-5-5", 0.0244, 1), ("claude-opus-5-5", 0.0192, 1)]
    assert w.lane(got, "bedrock")["monthUsd"] == 0 and w.lane(got, "bedrock")["sessions"] == []
    assert got["month"] == "2026-10" and got["since"] == "2026-10-01T00:00:00Z"


def test_a_session_is_listed_with_its_share_and_whether_it_runs(w):
    w.registry("big", A, lane="bedrock")
    w.registry("small", B, lane="bedrock")
    w.transcript(A, line("m1", "claude-sonnet-5-5", "2026-10-10T00:00:00Z", out=300_000))    # 300000 * $10 / 1e6 = $3.00
    w.transcript(B, line("m2", "claude-sonnet-5-5", "2026-10-10T00:00:00Z", out=100_000))    # $1.00
    got = w.count(live=[Live(B, "small", "bedrock", 1_790_000_000_000)])
    b = w.lane(got, "bedrock")
    assert b["monthUsd"] == pytest.approx(4.0)
    assert [(s["name"], s["usd"], s["share"], s["live"]) for s in b["sessions"]] == [("big", 3.0, 0.75, False), ("small", 1.0, 0.25, True)]
    assert abs(sum(s["share"] for s in b["sessions"]) - 1) < 1e-9


def test_the_month_is_the_utc_calendar_month(w):
    w.registry("aws-one", A, lane="aws-platform")
    p = w.transcript(A,
                 line("old", "claude-sonnet-5-5", "2026-09-30T23:59:59.999Z", out=1_000_000),     # September: not counted
                 line("first", "claude-sonnet-5-5", "2026-10-01T00:00:00.000Z", out=100_000),     # the first instant of October: counted, $1.00
                 line("last", "claude-sonnet-5-5", "2026-10-23T11:59:59.000Z", out=100_000))      # $1.00
    got = w.count()
    assert w.lane(got, "aws-platform")["monthUsd"] == pytest.approx(2.0) and w.lane(got, "aws-platform")["calls"] == 2
    # the Console resets on the 1st, UTC: on Nov 1st 00:00:01 UTC October's usage is gone and the month starts again
    touch(p, datetime(2026, 11, 1, 0, 0, 1, tzinfo=timezone.utc))
    nov = w.count(now=datetime(2026, 11, 1, 0, 0, 1, tzinfo=timezone.utc))
    assert nov["month"] == "2026-11" and nov["since"] == "2026-11-01T00:00:00Z"
    assert w.lane(nov, "aws-platform")["monthUsd"] == 0
    w.transcript(A, line("nov1", "claude-sonnet-5-5", "2026-11-01T00:00:00.500Z", out=100_000))
    touch(p, datetime(2026, 11, 1, 0, 0, 2, tzinfo=timezone.utc))
    nov = w.count(now=datetime(2026, 11, 1, 0, 0, 2, tzinfo=timezone.utc))
    assert w.lane(nov, "aws-platform")["monthUsd"] == pytest.approx(1.0)
    # the 23:30 UTC / 03:30 +04 case: an early morning of Nov 1st in a zone ahead of UTC is still October's last UTC hours
    assert w.count(now=datetime(2026, 10, 31, 23, 30, tzinfo=timezone.utc))["month"] == "2026-10"


def test_a_model_without_a_price_is_listed_not_counted_as_zero(w):
    w.registry("aws-one", A, lane="aws-platform")
    w.transcript(A,
                 line("p", "us.anthropic.claude-haiku-5-5-v1:0", "2026-10-12T00:00:00Z", inp=1_000_000),   # a Bedrock id: Haiku 5.5, $0.10
                 line("u1", "claude-opus-4-8", "2026-10-12T00:00:01Z", out=1000),
                 line("u2", "claude-opus-4-8", "2026-10-12T00:00:02Z", out=2000),
                 line("s", "<synthetic>", "2026-10-12T00:00:03Z", out=5))
    aws = w.lane(w.count(), "aws-platform")
    assert aws["monthUsd"] == pytest.approx(0.1) and [m["model"] for m in aws["models"]] == ["claude-haiku-5-5"]
    assert aws["unpriced"] == [{"model": "claude-opus-4-8", "calls": 2, "tokens": 3000}]
    assert aws["calls"] == 3      # the replies that were counted or listed; a <synthetic> refusal is neither


def test_subagent_transcripts_count_for_their_session_and_a_copied_reply_once(w):
    w.registry("aws-one", A, lane="aws-platform")
    w.transcript(A, line("main", "claude-sonnet-5-5", "2026-10-12T00:00:00Z", out=100_000))                         # $1.00
    w.transcript(A, line("sub1", "claude-sonnet-5-5", "2026-10-12T00:00:05Z", out=200_000),                         # $2.00, in a subagent file
                 line("main", "claude-sonnet-5-5", "2026-10-12T00:00:00Z", out=100_000), sub="agent-1.jsonl")        # a copy of the main reply
    w.transcript(A, line("sub2", "claude-sonnet-5-5", "2026-10-12T00:00:06Z", out=300_000), sub="deeper/agent-2.jsonl")  # $3.00
    w.transcript(B, line("main", "claude-sonnet-5-5", "2026-10-12T00:00:00Z", out=100_000))                          # a fork of B holding the same reply
    w.registry("fork", B, lane="aws-platform")
    aws = w.lane(w.count(), "aws-platform")
    assert aws["monthUsd"] == pytest.approx(6.0) and aws["calls"] == 3
    assert [(s["name"], s["usd"]) for s in aws["sessions"]] == [("aws-one", 6.0)]    # the fork's copy is not counted again


def test_only_sessions_on_an_aws_lane_are_read_and_old_files_are_skipped(w):
    w.registry("on-max", A, lane="subscription-1")
    w.registry("aws-one", B, lane="aws-platform")
    w.registry("stale", C, lane="aws-platform")
    w.transcript(A, line("a", "claude-sonnet-5-5", "2026-10-12T00:00:00Z", out=900_000))
    pb = w.transcript(B, line("b", "claude-sonnet-5-5", "2026-10-12T00:00:00Z", out=100_000))
    pc = w.transcript(C, line("c", "claude-sonnet-5-5", "2026-10-12T00:00:00Z", out=100_000))
    old = datetime(2026, 9, 15).timestamp()
    os.utime(pc, (old, old))                                    # untouched since September
    got = w.count()
    assert got["scannedBytes"] == pb.stat().st_size and got["sessionsRead"] == 1       # not the max session's file, not the stale one
    assert w.lane(got, "aws-platform")["monthUsd"] == pytest.approx(1.0)


def test_nothing_but_numbers_and_names_is_kept_or_returned(w):
    w.registry("aws-one", A, lane="aws-platform")
    w.transcript(A, user_line(), line("m", "claude-sonnet-5-5", "2026-10-12T00:00:00Z", inp=5, out=7))
    got = w.count(live=[Live(A, "aws-one", "aws-platform", 1_790_000_000_000)])
    assert SECRET not in json.dumps(got)
    for f in w.state.iterdir():
        assert SECRET not in f.read_text(), f.name
    saved = json.loads((w.state / "spend-scan.json").read_text())
    rec = next(iter(next(iter(saved["files"].values()))["recs"].values()))
    assert rec[1] == "claude-sonnet-5-5" and all(isinstance(x, int) for x in rec[2:]) and len(rec) == 7     # time, model, five counts


# ── the lane a message was on ────────────────────────────────────────────────
def test_the_lane_follows_sala_s_record_message_by_message(w):
    w.registry("mover", A, lane="bedrock")              # its lane NOW
    w.log(("2026-10-02T00:00:00+00:00", "set", "mover", "(default) → max"),
          ("2026-10-10T00:00:00+00:00", "set", "mover", "max → aws-platform"),
          ("2026-10-15T00:00:00+00:00", "set", "mover", "aws-platform → bedrock"))
    w.transcript(A,
                 line("before", "claude-sonnet-5-5", "2026-10-01T06:00:00Z", out=100_000),   # before the first change: its old lane, the default, max
                 line("on-max", "claude-sonnet-5-5", "2026-10-05T00:00:00Z", out=200_000),
                 line("on-aws", "claude-sonnet-5-5", "2026-10-12T00:00:00Z", out=300_000),   # $3.00
                 line("on-bed", "claude-sonnet-5-5", "2026-10-20T00:00:00Z", out=400_000))   # $4.00
    got = w.count()
    assert w.lane(got, "aws-platform")["monthUsd"] == pytest.approx(3.0) and w.lane(got, "bedrock")["monthUsd"] == pytest.approx(4.0)
    assert w.lane(got, "aws-platform")["calls"] == 1 and w.lane(got, "bedrock")["calls"] == 1


def test_the_first_change_s_old_lane_counts_when_it_was_an_aws_lane(w):
    w.registry("leaver", A, lane="subscription-1")
    w.log(("2026-10-10T00:00:00+00:00", "set", "leaver", "aws-platform → max"))
    w.transcript(A, line("early", "claude-sonnet-5-5", "2026-10-03T00:00:00Z", out=100_000),     # $1.00 on aws-platform
                 line("late", "claude-sonnet-5-5", "2026-10-11T00:00:00Z", out=900_000))
    got = w.count()
    assert w.lane(got, "aws-platform")["monthUsd"] == pytest.approx(1.0) and w.lane(got, "bedrock")["monthUsd"] == 0


def test_the_default_lane_is_read_as_it_was_at_the_time(w):
    w.registry("y", A, lane="subscription-1")
    w.log(("2026-10-08T00:00:00+00:00", "default", "-", "max → bedrock"),          # the default moves to bedrock on Oct 8
          ("2026-10-12T00:00:00+00:00", "drop", "y", "aws-platform → (default)"))   # y leaves aws-platform for the default on Oct 12
    w.transcript(A, line("aws", "claude-sonnet-5-5", "2026-10-11T00:00:00Z", out=100_000),    # $1.00 aws-platform
                 line("dflt", "claude-sonnet-5-5", "2026-10-13T00:00:00Z", out=200_000))      # the default then: bedrock, $2.00
    got = w.count()
    assert w.lane(got, "aws-platform")["monthUsd"] == pytest.approx(1.0) and w.lane(got, "bedrock")["monthUsd"] == pytest.approx(2.0)


def test_a_rename_keeps_the_lane_across_the_old_and_the_new_name(w):
    w.registry("new-name", A, lane="aws-platform", aliases=["old-name"])
    w.log(("2026-10-03T00:00:00+00:00", "set", "old-name", "(default) → aws-platform"),
          ("2026-10-10T00:00:05+00:00", "drop", "old-name", "aws-platform → (default)"),         # sala's rename: a drop of the old name ...
          ("2026-10-10T00:00:05+00:00", "set", "new-name", "(default) → aws-platform"))          # ... then a set of the new one, in one second
    w.transcript(A, line("a", "claude-sonnet-5-5", "2026-10-05T00:00:00Z", out=100_000),
                 line("b", "claude-sonnet-5-5", "2026-10-10T00:00:30Z", out=100_000),
                 line("c", "claude-sonnet-5-5", "2026-10-15T00:00:00Z", out=100_000))
    assert w.lane(w.count(), "aws-platform")["monthUsd"] == pytest.approx(3.0)       # the default (max) in between never took a message


def test_a_session_with_no_record_is_on_its_current_lane_for_all_its_messages(w):
    # the documented fallback: no change in lanes.log for it, so the registry row's lane
    w.registry("by-hand", A, lane="bedrock")
    w.transcript(A, line("a", "claude-sonnet-5-5", "2026-10-02T00:00:00Z", out=100_000),
                 line("b", "claude-sonnet-5-5", "2026-10-20T00:00:00Z", out=100_000))
    assert w.lane(w.count(), "bedrock")["monthUsd"] == pytest.approx(2.0)


def test_a_live_process_is_the_truth_for_a_session_sala_never_recorded(w):
    w.registry("by-hand", A, lane="subscription-1")                   # sala's row says max; the process runs on aws-platform
    w.transcript(A, line("a", "claude-sonnet-5-5", "2026-10-20T00:00:00Z", out=100_000))
    started = int(datetime(2026, 10, 15, tzinfo=timezone.utc).timestamp() * 1000)
    got = w.count(live=[Live(A, "by-hand", "aws-platform", started)])
    assert w.lane(got, "aws-platform")["monthUsd"] == pytest.approx(1.0)
    # remembered after the process is gone: the next count (no live session) still reads it
    assert json.loads((w.state / "spend-lanes.json").read_text())["sessions"][A]["seen"] == [[started, "aws-platform"]]
    assert w.lane(w.count(), "aws-platform")["monthUsd"] == pytest.approx(1.0)
    # then the session is relaunched on max (a later sighting): its messages from then on are max's
    w.transcript(A, line("b", "claude-sonnet-5-5", "2026-10-22T00:00:00Z", out=900_000))
    later = int(datetime(2026, 10, 21, tzinfo=timezone.utc).timestamp() * 1000)
    got = w.count(live=[Live(A, "by-hand", "subscription-1", later)])
    assert w.lane(got, "aws-platform")["monthUsd"] == pytest.approx(1.0)


def test_a_session_on_max_is_never_remembered(w):
    w.registry("plain", A, lane="subscription-1")
    w.count(live=[Live(A, "plain", "subscription-1", 1_790_000_000_000), Live(B, "other", None, None)])
    assert not (w.state / "spend-lanes.json").exists()


def test_a_session_named_in_the_record_with_no_transcript_to_find_is_said_not_dropped(w):
    w.log(("2026-10-10T00:00:00+00:00", "set", "ghost", "(default) → aws-platform"),
          ("2026-10-10T00:00:00+00:00", "set", "plain", "(default) → max"))
    got = w.count()
    assert w.lane(got, "aws-platform")["unmatched"] == ["ghost"] and w.lane(got, "bedrock")["unmatched"] == []


# ── keeping it cheap ─────────────────────────────────────────────────────────
def test_a_second_count_reads_only_what_was_appended(w):
    w.registry("aws-one", A, lane="aws-platform")
    p = w.transcript(A, line("m1", "claude-sonnet-5-5", "2026-10-12T00:00:00Z", out=100_000))          # $1.00
    first = w.count()
    assert first["scannedBytes"] == p.stat().st_size and w.lane(first, "aws-platform")["monthUsd"] == pytest.approx(1.0)
    assert w.count()["scannedBytes"] == 0                                                                  # nothing new: nothing read
    before = p.stat().st_size
    # one new message, and the rest of a streamed one we already have (its output grows from 100000 to 150000: $1.50)
    w.transcript(A, line("m2", "claude-sonnet-5-5", "2026-10-12T01:00:00Z", out=200_000),
                 line("m1", "claude-sonnet-5-5", "2026-10-12T00:00:00Z", out=150_000))
    got = w.count()
    assert got["scannedBytes"] == p.stat().st_size - before                                                # only the new bytes
    assert w.lane(got, "aws-platform")["monthUsd"] == pytest.approx(3.5) and w.lane(got, "aws-platform")["calls"] == 2


def test_a_line_still_being_written_is_read_when_it_is_whole(w):
    w.registry("aws-one", A, lane="aws-platform")
    p = w.transcript(A, line("m1", "claude-sonnet-5-5", "2026-10-12T00:00:00Z", out=100_000))
    w.count()
    whole = line("m2", "claude-sonnet-5-5", "2026-10-12T01:00:00Z", out=100_000)
    with open(p, "a", encoding="utf-8") as f:
        f.write(whole[:60])                                   # half a line, no newline
    got = w.count()
    assert got["scannedBytes"] == 0 and w.lane(got, "aws-platform")["calls"] == 1
    with open(p, "a", encoding="utf-8") as f:
        f.write(whole[60:])
    got = w.count()
    assert got["scannedBytes"] == len(whole.encode()) and w.lane(got, "aws-platform")["monthUsd"] == pytest.approx(2.0)


def test_a_file_that_shrank_or_was_replaced_is_read_again_from_the_start(w):
    w.registry("aws-one", A, lane="aws-platform")
    p = w.transcript(A, line("m1", "claude-sonnet-5-5", "2026-10-12T00:00:00Z", out=100_000),
                     line("m2", "claude-sonnet-5-5", "2026-10-12T01:00:00Z", out=100_000))
    w.count()
    p.unlink()
    w.transcript(A, line("m3", "claude-sonnet-5-5", "2026-10-12T02:00:00Z", out=300_000))
    got = w.count()
    assert got["scannedBytes"] == p.stat().st_size and w.lane(got, "aws-platform")["monthUsd"] == pytest.approx(3.0)


def test_a_new_month_starts_the_cache_again(w):
    w.registry("aws-one", A, lane="aws-platform")
    p = w.transcript(A, line("o", "claude-sonnet-5-5", "2026-10-31T00:00:00Z", out=100_000),
                     line("n", "claude-sonnet-5-5", "2026-11-02T00:00:00Z", out=200_000))
    w.count()
    touch(p, datetime(2026, 11, 3, tzinfo=timezone.utc))
    nov = w.count(now=datetime(2026, 11, 3, tzinfo=timezone.utc))
    assert nov["scannedBytes"] == p.stat().st_size and w.lane(nov, "aws-platform")["monthUsd"] == pytest.approx(2.0)


def test_a_broken_cache_is_ignored(w):
    w.registry("aws-one", A, lane="aws-platform")
    w.transcript(A, line("m1", "claude-sonnet-5-5", "2026-10-12T00:00:00Z", out=100_000))
    w.state.mkdir()
    (w.state / "spend-scan.json").write_text("{not json")
    (w.state / "spend-lanes.json").write_text('{"sessions": {"x": 5}}')
    assert w.lane(w.count(), "aws-platform")["monthUsd"] == pytest.approx(1.0)


# ── what cannot be counted ───────────────────────────────────────────────────
def test_unreadable_records_are_a_plain_sentence_and_missing_ones_are_just_empty(w):
    got = w.count()                                                   # no sala state at all: nothing on the lanes, no error
    assert [x["monthUsd"] for x in got["lanes"]] == [0, 0]
    w.sala.joinpath("sessions.json").write_text("{broken")
    with pytest.raises(SPD.SpendError, match="session record could not be read"):
        w.count()
    w.sala.joinpath("sessions.json").unlink()
    w.sala.joinpath("lanes.log").mkdir()                              # a directory where the file should be: unreadable
    with pytest.raises(SPD.SpendError, match="lane record could not be read"):
        w.count()


def test_no_transcripts_folder_for_a_session_that_needs_one_is_a_plain_sentence(w):
    w.registry("aws-one", A, lane="aws-platform")
    with pytest.raises(SPD.SpendError, match="transcripts folder could not be read"):
        w.count()


# ── the endpoint ─────────────────────────────────────────────────────────────
def poll(client, until=lambda d: not d.get("pending") and not d.get("refreshing"), timeout=10.0):
    end = time.time() + timeout
    while time.time() < end:
        d = client.get("/api/spend").json()
        if until(d):
            return d
        time.sleep(0.02)
    raise AssertionError(f"the answer never came: {d}")


def test_the_endpoint_is_pending_until_the_first_count_lands_and_then_serves_it(w, monkeypatch):
    w.registry("aws-one", A, lane="aws-platform")
    w.transcript(A, line("m1", "claude-sonnet-5-5", "2026-10-12T00:00:00Z", out=100_000))
    gate, real = threading.Event(), SPD.compute

    def slow(*a, **k):
        gate.wait(10)
        return real(*a, **k)

    monkeypatch.setattr(SPD, "compute", slow)
    app = create_app(w.settings)
    with TestClient(app) as c:
        first = c.get("/api/spend")
        assert first.status_code == 200 and first.headers["cache-control"] == "no-store"
        assert first.json()["pending"] is True and first.json()["lanes"] == [] and first.json()["refreshing"] is True
        assert c.get("/api/spend").json()["pending"] is True               # a second ask while it runs starts no other count
        gate.set()
        d = poll(c)
    aws = next(x for x in d["lanes"] if x["lane"] == "aws-platform")
    assert aws["monthUsd"] == pytest.approx(1.0) and d["fetchedAt"] and "pending" not in d
    assert [s["name"] for s in aws["sessions"]] == ["aws-one"]
    saved = json.loads((w.state / "spend-aws.json").read_text())
    assert saved["lanes"] and "pending" not in saved and "refreshing" not in saved and SECRET not in json.dumps(saved)


def test_a_restart_serves_the_saved_answer_at_once(w):
    w.registry("aws-one", A, lane="aws-platform")
    w.transcript(A, line("m1", "claude-sonnet-5-5", "2026-10-12T00:00:00Z", out=100_000))
    with TestClient(create_app(w.settings)) as c:
        poll(c)
    with TestClient(create_app(w.settings)) as c:
        d = c.get("/api/spend").json()
    assert not d.get("pending") and next(x for x in d["lanes"] if x["lane"] == "aws-platform")["monthUsd"] == pytest.approx(1.0)


def test_the_endpoint_never_raises_and_says_what_it_could_not_count(w):
    w.sala.joinpath("sessions.json").write_text("{broken")
    app = create_app(w.settings)
    with TestClient(app) as c:
        d = poll(c, until=lambda d: bool(d.get("error")))
        assert c.get("/api/spend").status_code == 200
        assert d["error"] == "sala's session record could not be read" and d["pending"] is True and d["lanes"] == []
        # fixed: the next try (a minute later, here at once) clears it
        w.sala.joinpath("sessions.json").unlink()
        app.state.spend._swr._next = 0
        d = poll(c, until=lambda d: not d.get("error") and not d.get("pending") and not d.get("refreshing"))
    assert [x["monthUsd"] for x in d["lanes"]] == [0, 0]


def test_a_failed_refresh_keeps_the_last_figures_with_the_error(w):
    w.registry("aws-one", A, lane="aws-platform")
    w.transcript(A, line("m1", "claude-sonnet-5-5", "2026-10-12T00:00:00Z", out=100_000))
    app = create_app(w.settings)
    with TestClient(app) as c:
        poll(c)
        w.sala.joinpath("sessions.json").write_text("{broken")
        app.state.spend._swr._next = 0
        d = poll(c, until=lambda d: bool(d.get("error")))
    assert d["error"] and next(x for x in d["lanes"] if x["lane"] == "aws-platform")["monthUsd"] == pytest.approx(1.0)


def test_a_dormant_lane_keeps_its_figures_and_gains_the_record_in_the_answer(w):
    # the count is local, so a dormant lane keeps its month; its entry only gains "dormant"
    w.registry("aws-one", A, lane="aws-platform")
    w.transcript(A, line("m1", "claude-sonnet-5-5", "2026-10-12T00:00:00Z", out=100_000))
    (w.sala / "lane-state.tsv").write_text("aws-platform\tdormant\tno workspace\t2026-01-05T03:00:00Z\t\thand\n")
    dormant = {"reason": "no workspace", "since": "2026-01-05T03:00:00Z"}
    app = create_app(w.settings)
    with TestClient(app) as c:
        d = poll(c)
        got = {x["lane"]: x for x in d["lanes"]}
        assert got["aws-platform"]["dormant"] == dormant and got["aws-platform"]["monthUsd"] == pytest.approx(1.0)
        assert got["aws-platform"]["calls"] == 1 and got["aws-platform"]["sessions"], got["aws-platform"]
        assert got["bedrock"]["monthUsd"] == 0 and "dormant" not in got["bedrock"]
        # before the first count lands, a dormant lane is the stub {lane, dormant}
        app.state.spend._swr.state = {"lanes": [], "pending": True}
        stub = c.get("/api/spend").json()
    assert {"lane": "aws-platform", "dormant": dormant} in stub["lanes"]


def test_configured_comes_from_sala_s_lane_table(w):
    import sys

    stub = w.tmp / "sala-stub"
    table = {"default": "subscription-1", "lanes": [
        {"id": "bedrock", "label": "Bedrock", "status": "active"}, {"id": "aws-platform", "label": "Claude Platform on AWS", "status": "not set up"}]}
    stub.write_text(f"#!{sys.executable}\nimport sys\nassert sys.argv[1:] == ['lane', '--json']\nprint({json.dumps(table)!r})\n")
    stub.chmod(0o755)
    settings = Settings(**{**w.settings.__dict__, "sala_cmd": [str(stub)]})
    with TestClient(create_app(settings)) as c:
        d = poll(c)
    got = {x["lane"]: x for x in d["lanes"]}
    assert got["bedrock"]["configured"] is True and got["aws-platform"]["configured"] is False


def test_an_unknown_lane_table_leaves_configured_unknown(w):
    with TestClient(create_app(w.settings)) as c:       # conftest.py points the sala command at nothing
        d = poll(c)
    assert all(x["configured"] is None for x in d["lanes"])


def test_it_is_counted_every_five_minutes_and_a_failure_is_tried_again_after_one(w):
    swr = create_app(w.settings).state.spend._swr
    assert isinstance(swr, SWR.Revalidating) and swr.ttl == SPD.TTL == 300.0 and swr.error_retry == SPD.ERROR_RETRY == 60.0
