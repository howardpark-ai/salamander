"""The AWS lanes' month-to-date spend (spend.py) however many messages the month holds: the count keeps no list of messages.

The cache is a SQLite file with, per transcript, its inode, offset and TOTALS (per lane and model), and for the month the set of the ids
already counted (a fork copies history). What a wrong answer costs here: a count that stops at some number of messages ("too many
messages to count") so the two cards stop refreshing for the rest of the month; a count that holds the month in memory and is killed by
the memory cap instead; a total that differs from the per-message sum (a copied message counted twice, a streamed reply counted from its
first line, a message on the wrong lane); an upgrade that reads the whole month again, or crashes on the old JSON cache; a damaged cache
file that is never cleared. Every transcript, registry and log is a fake in tmp_path with invented ids and words (conftest.py points the
sala command at nothing); the oracle in this file is a per-message count written the plain way.
"""

from __future__ import annotations

import json
import os
import random
import sqlite3
import stat

import pytest

from sala_web import spend as SPD
from test_spend import A, B, C, _pinned_clock, line, w  # noqa: F401  (the fake world is spend.py's own tests')

SONNET = "claude-sonnet-5-5"   # $10 per million output tokens: 1000 output tokens a message is $0.01


def bulk_line(mid, ts="2026-10-12T00:00:00Z", out=1000, model=SONNET):
    """The smallest assistant line the count reads (a big month is many of them)."""
    return ('{"type":"assistant","timestamp":"%s","message":{"id":"%s","model":"%s","usage":{"input_tokens":0,"output_tokens":%d}}}\n'
            % (ts, mid, model, out))


def write_bulk(path, prefix, n, **kw):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        for i in range(n):
            f.write(bulk_line(f"{prefix}{i:06d}", **kw))


# ── no cap on the number of messages ─────────────────────────────────────────
def test_a_month_past_the_old_message_cap_still_counts(w):
    """The old count refused at 250,000 messages: 'there are too many messages to count'."""
    w.registry("aws-one", A, lane="aws-platform")
    w.registry("aws-two", B, lane="bedrock")
    d = w.claude / "projects" / "-home-alex"
    write_bulk(d / f"{A}.jsonl", "pa", 130_000)
    write_bulk(d / f"{B}.jsonl", "pb", 130_000)
    got = w.count()
    assert w.lane(got, "aws-platform")["calls"] == 130_000 and w.lane(got, "bedrock")["calls"] == 130_000
    assert w.lane(got, "aws-platform")["monthUsd"] == pytest.approx(1300.0)       # 130,000 messages x $0.01
    assert w.lane(got, "bedrock")["monthUsd"] == pytest.approx(1300.0)
    again = w.count()
    assert again["scannedBytes"] == 0 and w.lane(again, "aws-platform")["calls"] == 130_000      # the second count reads nothing and keeps the figures
    write_bulk(d / f"{A}.jsonl", "pc", 10)
    more = w.count()
    assert w.lane(more, "aws-platform")["calls"] == 130_010                                      # and only what was appended is read


def test_the_count_holds_a_bounded_number_of_messages_whatever_the_transcript_size(tmp_path):
    p = tmp_path / "big.jsonl"
    write_bulk(p, "pq", 5_000)
    pending: dict = {}
    seen, closed = [], []

    def fold(mid, rec):
        closed.append(mid)
        seen.append(len(pending))

    end = SPD.read_new(p, 0, 0.0, pending, fold)
    assert end == p.stat().st_size and len(closed) == 5_000 - len(pending)
    assert max(seen) <= SPD.PENDING_MAX and len(pending) == SPD.PENDING_MAX      # a transcript's messages are closed as they go past


def test_the_cache_file_is_owner_only_and_holds_ids_and_numbers_not_text(w):
    w.registry("aws-one", A, lane="aws-platform")
    w.transcript(A, line("m1", SONNET, "2026-10-12T00:00:00Z", out=1000), line("m2", SONNET, "2026-10-12T00:01:00Z", out=1000))
    w.count()
    f = w.state / SPD.SCAN_FILE
    assert stat.S_IMODE(f.stat().st_mode) == 0o600
    assert b"[masked secret]" not in f.read_bytes() and not (w.state / SPD.LEGACY_SCAN_FILE).exists()


def test_the_disk_limit_is_on_the_cache_file_and_says_so_in_plain_words(w, monkeypatch):
    w.registry("aws-one", A, lane="aws-platform")
    w.transcript(A, line("m1", SONNET, "2026-10-12T00:00:00Z", out=1000))
    monkeypatch.setattr(SPD, "MAX_STORE_BYTES", 1)
    with pytest.raises(SPD.SpendError, match="too many messages"):
        w.count()
    monkeypatch.setattr(SPD, "MAX_STORE_BYTES", 2 << 30)
    assert w.lane(w.count(), "aws-platform")["calls"] == 1                         # under its limit it counts, from the same file


# ── the totals are the per-message sum ───────────────────────────────────────
def oracle(world, sessions):
    """The plain count: every message once (the first transcript by session id keeps it, the largest of each token count), on the lane its
    session was on at its time, priced. {lane: (usd, calls, {session: calls})}. `sessions` is [(sid, lane_at(epoch s) -> lane)]."""
    seen: dict[str, dict] = {}
    for sid, lane_at in sorted(sessions):
        for path in sorted((world.claude / "projects").rglob(f"{sid}.jsonl")) + sorted((world.claude / "projects").rglob(f"{sid}/subagents/*.jsonl")):
            for raw in open(path, encoding="utf-8"):
                if not raw.endswith("\n"):
                    continue
                d = json.loads(raw)
                m = d.get("message") or {}
                if d.get("type") != "assistant" or not m.get("usage"):
                    continue
                tok = SPD.usage_tokens(m["usage"])
                t = SPD.parse_iso(d["timestamp"])
                old = seen.get(m["id"])
                if old is None:
                    seen[m["id"]] = {"sid": sid, "t": t, "model": m["model"], "tok": tok, "lane_at": lane_at}
                else:
                    old["tok"] = [max(a, b) for a, b in zip(old["tok"], tok)]
                    if old["sid"] == sid:
                        old["t"], old["model"] = t, m["model"]
    out: dict = {}
    for r in seen.values():
        lane = r["lane_at"](r["t"])
        usd, calls, per = out.setdefault(lane, [0.0, 0, {}])
        out[lane][0] += SPD.price(r["model"], r["tok"]) or 0.0
        out[lane][1] += 1
        per[r["sid"]] = per.get(r["sid"], 0) + 1
    return out


def fixture_lines(rng, prefix, n, t0, models=(SONNET, "claude-opus-5-5")):
    """n messages in order, each one to three lines (a streamed reply: the output grows), one minute apart from t0 (epoch s)."""
    out = []
    for i in range(n):
        mid, model = f"{prefix}{i:04d}", rng.choice(models)
        ts = SPD.datetime.fromtimestamp(t0 + 60 * i, SPD.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        base = rng.randrange(1, 5000)
        for k in range(rng.choice((1, 1, 2, 3))):
            out.append(line(mid, model, ts, inp=rng.randrange(1, 50), w5=rng.randrange(0, 300), cr=rng.randrange(0, 900), out=base * (k + 1)))
    return out


def test_the_totals_equal_the_per_message_sum_through_forks_streams_lane_changes_and_many_reads(w):
    rng = random.Random(7)
    t0 = SPD.parse_iso("2026-10-05T00:00:00Z")
    w.registry("aws-one", A, lane="aws-platform")
    w.registry("aws-two", B, lane="bedrock")
    w.registry("aws-three", C, lane="bedrock")
    switch = "2026-10-05T03:00:00+00:00"                                       # aws-one moves from bedrock to aws-platform
    w.log((switch, "set", "aws-one", "bedrock → aws-platform"))
    ts_switch = SPD.parse_iso(switch)
    lanes = {A: lambda t: "aws-platform" if t >= ts_switch else "bedrock", B: lambda t: "bedrock", C: lambda t: "bedrock"}
    la = fixture_lines(rng, "ma", 400, t0)
    lb = fixture_lines(rng, "mb", 150, t0 + 100)
    copy_of_a = [x for x in la if json.loads(x)["message"]["id"] < "ma0100"]   # C forked from A at message 100: its history is A's lines
    lc = copy_of_a + fixture_lines(rng, "mc", 80, t0 + 7 * 3600)
    sub = fixture_lines(rng, "ms", 40, t0 + 200)                               # a subagent of B
    sessions = [(sid, la_) for sid, la_ in lanes.items()]

    def check(note):
        got = w.count()
        want = oracle(w, sessions)
        for lane in ("aws-platform", "bedrock"):
            usd, calls, per = want.get(lane, [0.0, 0, {}])
            card = w.lane(got, lane)
            assert card["calls"] == calls, (note, lane)
            assert card["monthUsd"] == pytest.approx(usd, abs=1e-3), (note, lane)
            assert {s["sessionId"]: s["calls"] for s in card["sessions"]} == per, (note, lane)

    # read in pieces that cut streamed replies in two, forks arriving later than their parent
    cuts = [0, 137, 301, 520, len(la)]
    for a, b in zip(cuts, cuts[1:]):
        w.transcript(A, *la[a:b])
        w.transcript(B, *lb[a // 4:b // 4])
        check(f"a:{b}")
    w.transcript(B, *sub, sub="agent-xyz.jsonl")
    check("sub")
    w.transcript(C, *lc)
    check("fork")                                                              # a fork's copied history is not counted a second time
    w.transcript(C, *fixture_lines(rng, "mz", 5, t0 + 9 * 3600))
    check("more")


def test_the_rest_of_a_streamed_reply_read_later_is_merged_into_it_not_counted_twice(w):
    w.registry("aws-one", A, lane="aws-platform")
    w.transcript(A, line("m1", SONNET, "2026-10-12T00:00:00Z", out=100_000))                   # $1.00 so far
    first = w.count()
    assert w.lane(first, "aws-platform")["monthUsd"] == pytest.approx(1.0) and w.lane(first, "aws-platform")["calls"] == 1
    w.transcript(A, line("m1", SONNET, "2026-10-12T00:00:05Z", out=150_000))                   # the reply goes on: its complete usage is the larger
    second = w.count()
    assert w.lane(second, "aws-platform")["monthUsd"] == pytest.approx(1.5) and w.lane(second, "aws-platform")["calls"] == 1
    w.transcript(A, *[line(f"n{i}", SONNET, f"2026-10-12T01:0{i}:00Z", out=10_000) for i in range(6)])     # six more close it
    third = w.count()
    assert w.lane(third, "aws-platform")["monthUsd"] == pytest.approx(1.5 + 0.6) and w.lane(third, "aws-platform")["calls"] == 7


def test_a_copied_history_is_counted_once_whichever_reads_first_or_later(w):
    w.registry("aws-one", A, lane="aws-platform")
    w.registry("aws-two", B, lane="aws-platform")
    mine = [line(f"h{i}", SONNET, f"2026-10-12T00:0{i}:00Z", out=100_000) for i in range(8)]       # eight messages, $8
    w.transcript(A, *mine)
    assert w.lane(w.count(), "aws-platform")["monthUsd"] == pytest.approx(8.0)
    w.transcript(B, *mine, line("own", SONNET, "2026-10-12T01:00:00Z", out=100_000))             # the fork: A's history and one reply of its own
    got = w.count()
    assert w.lane(got, "aws-platform")["calls"] == 9 and w.lane(got, "aws-platform")["monthUsd"] == pytest.approx(9.0)
    assert {s["sessionId"]: s["calls"] for s in w.lane(got, "aws-platform")["sessions"]} == {A: 8, B: 1}


def test_a_transcript_replaced_or_dropped_makes_the_month_be_read_again_from_the_first_byte(w):
    w.registry("aws-one", A, lane="aws-platform")
    w.registry("aws-two", B, lane="aws-platform")
    mine = [line(f"h{i}", SONNET, f"2026-10-12T00:0{i}:00Z", out=100_000) for i in range(8)]
    pa = w.transcript(A, *mine)
    w.transcript(B, *mine)
    assert w.lane(w.count(), "aws-platform")["monthUsd"] == pytest.approx(8.0)
    pa.unlink()                                                                # the parent is gone: the fork's copy is now the only record
    got = w.count()
    assert w.lane(got, "aws-platform")["calls"] == 8 and w.lane(got, "aws-platform")["monthUsd"] == pytest.approx(8.0)
    assert got["scannedBytes"] == (w.claude / "projects" / "-home-alex" / f"{B}.jsonl").stat().st_size       # what is left was read afresh


# ── upgrading from the JSON cache an earlier release kept ────────────────────
def legacy_cache(w, month, path, **extra):
    """The cache as the earlier release wrote it: per file its inode, offset and every message of the month."""
    st = path.stat()
    recs = {}
    for raw in open(path, encoding="utf-8"):
        d = json.loads(raw)
        m = d["message"]
        recs[m["id"]] = [int(SPD.parse_iso(d["timestamp"]) * 1000), m["model"], *SPD.usage_tokens(m["usage"])]
    doc = {"v": 1, "month": month, "files": {str(path): {"ino": st.st_ino, "off": st.st_size, "recs": recs}}, **extra}
    w.state.mkdir(exist_ok=True)
    (w.state / SPD.LEGACY_SCAN_FILE).write_text(json.dumps(doc))


def test_an_old_json_cache_is_read_once_into_the_new_one_and_nothing_is_read_again(w):
    w.registry("aws-one", A, lane="aws-platform")
    p = w.transcript(A, *[line(f"o{i}", SONNET, f"2026-10-12T00:0{i}:00Z", out=100_000) for i in range(6)])      # $6
    legacy_cache(w, "2026-10", p)
    got = w.count()
    assert got["scannedBytes"] == 0                                                   # the old cache's offsets carried over
    assert w.lane(got, "aws-platform")["monthUsd"] == pytest.approx(6.0) and w.lane(got, "aws-platform")["calls"] == 6
    assert not (w.state / SPD.LEGACY_SCAN_FILE).exists() and (w.state / SPD.SCAN_FILE).exists()
    w.transcript(A, line("o9", SONNET, "2026-10-12T01:00:00Z", out=100_000))
    after = w.count()
    assert w.lane(after, "aws-platform")["calls"] == 7 and w.lane(after, "aws-platform")["monthUsd"] == pytest.approx(7.0)


def test_an_old_cache_a_streamed_reply_was_open_in_is_merged_when_the_rest_comes(w):
    w.registry("aws-one", A, lane="aws-platform")
    p = w.transcript(A, line("o1", SONNET, "2026-10-12T00:00:00Z", out=100_000))
    legacy_cache(w, "2026-10", p)
    assert w.lane(w.count(), "aws-platform")["monthUsd"] == pytest.approx(1.0)
    w.transcript(A, line("o1", SONNET, "2026-10-12T00:00:09Z", out=300_000))
    got = w.count()
    assert w.lane(got, "aws-platform")["calls"] == 1 and w.lane(got, "aws-platform")["monthUsd"] == pytest.approx(3.0)


@pytest.mark.parametrize("what", ["another month", "not json", "too big", "unknown version", "wrong shape"])
def test_an_old_cache_that_cannot_be_used_is_dropped_and_the_month_is_read_again(w, monkeypatch, what):
    w.registry("aws-one", A, lane="aws-platform")
    p = w.transcript(A, *[line(f"o{i}", SONNET, f"2026-10-12T00:0{i}:00Z", out=100_000) for i in range(3)])
    if what == "another month":
        legacy_cache(w, "2026-09", p)
    elif what == "unknown version":
        legacy_cache(w, "2026-10", p, v=7)
    elif what == "too big":
        legacy_cache(w, "2026-10", p)
        monkeypatch.setattr(SPD, "LEGACY_MAX_BYTES", 10)
    elif what == "wrong shape":
        w.state.mkdir()
        (w.state / SPD.LEGACY_SCAN_FILE).write_text(json.dumps({"v": 1, "month": "2026-10", "files": {str(p): {"ino": "x", "recs": 5}, "q": 3}}))
    else:
        w.state.mkdir()
        (w.state / SPD.LEGACY_SCAN_FILE).write_text("{not json")
    got = w.count()
    assert got["scannedBytes"] == p.stat().st_size                                    # read from the first byte
    assert w.lane(got, "aws-platform")["monthUsd"] == pytest.approx(3.0) and w.lane(got, "aws-platform")["calls"] == 3
    assert not (w.state / SPD.LEGACY_SCAN_FILE).exists()


def test_an_old_cache_beside_a_new_one_is_left_alone(w):
    """After the conversion the JSON file is never read: a copy that comes back (a state directory merged in) changes nothing."""
    w.registry("aws-one", A, lane="aws-platform")
    p = w.transcript(A, line("o1", SONNET, "2026-10-12T00:00:00Z", out=100_000))
    w.count()
    legacy_cache(w, "2026-10", p)
    got = w.count()
    assert got["scannedBytes"] == 0 and w.lane(got, "aws-platform")["calls"] == 1 and (w.state / SPD.LEGACY_SCAN_FILE).exists()


# ── a damaged or foreign cache file ──────────────────────────────────────────
def test_a_cache_of_another_layout_or_month_is_started_again(w):
    w.registry("aws-one", A, lane="aws-platform")
    p = w.transcript(A, line("m1", SONNET, "2026-10-12T00:00:00Z", out=100_000))
    w.count()
    db = sqlite3.connect(w.state / SPD.SCAN_FILE)
    db.execute("UPDATE meta SET v = 99 WHERE k = 'v'")
    db.commit()
    db.close()
    got = w.count()
    assert got["scannedBytes"] == p.stat().st_size and w.lane(got, "aws-platform")["calls"] == 1


def test_a_cache_file_that_breaks_half_way_is_dropped_and_counted_again(w):
    w.registry("aws-one", A, lane="aws-platform")
    p = w.transcript(A, *[line(f"m{i}", SONNET, f"2026-10-12T00:0{i}:00Z", out=100_000) for i in range(5)])
    w.count()
    f = w.state / SPD.SCAN_FILE
    data = bytearray(f.read_bytes())
    for i in range(0, len(data), 4096):                                            # every page's first bytes overwritten: not a database any more
        data[i:i + 64] = os.urandom(64)
    f.write_bytes(bytes(data))
    got = w.count()
    assert w.lane(got, "aws-platform")["calls"] == 5 and got["scannedBytes"] == p.stat().st_size
    assert w.lane(w.count(), "aws-platform")["calls"] == 5
