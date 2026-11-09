"""The Usage analysis tab's data layer (usage.py, GET /api/usage): every assistant reply of this machine's Claude Code transcripts, at list prices,
aggregated by week, day (KST), lane, model, project, agent and folder.

What a wrong answer costs: a figure the owner acts on that is too high (a streamed reply or a forked history counted twice, the same transcripts
counted under two logins) or too low (a subagent's usage left out, a reply of another week counted in this one), a week that does not run from
one weekly reset to the next, a day that is not a KST day, a model with no price counted as $0 without a word, a re-read of every transcript on
every refresh, or a prompt or a reply leaving a transcript. Every transcript, registry and state file here is a fake in tmp_path; nothing asks
Anthropic or AWS and no real sala runs (conftest.py points the sala command at nothing and the second login's folders at none).
"""

from __future__ import annotations

import json
import os
import time
from datetime import datetime, timezone

import pytest
from starlette.testclient import TestClient

from sala_web import sessions as S
from sala_web import usage as U
from sala_web.app import create_app
from sala_web.config import Settings

SECRET = "[masked secret]"
A, B, C, D = (f"{c * 8}-0000-4000-8000-000000000001" for c in "abcd")
NOW = datetime(2026, 10, 23, 12, 0, tzinfo=timezone.utc).timestamp()     # Fri Oct 23rd 21:00 KST
RESET = "2026-10-28T05:00:00Z"                                             # the next weekly reset: Wed Oct 28th 14:00 KST
LANE_ROWS = [{"id": "subscription-1", "billing": "subscription"}, {"id": "bedrock", "billing": "usage"}]


def iso(epoch: float) -> str:
    return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def at(day: int, hour: int = 0, month: int = 10) -> float:
    """An epoch second of 2026 (UTC) in the fixtures' October."""
    return datetime(2026, month, day, hour, 0, tzinfo=timezone.utc).timestamp()


def quota(reset=RESET, lane="subscription-1", percent=40):
    return [{"lane": lane, "limits": [{"label": U.WEEKLY_LABEL, "percent": percent, "resetsAt": reset}]}]


def reply(mid, model, t, inp=0, w5=0, w1=0, cr=0, out=0):
    """One assistant line of a transcript, with a reply text and a tool input that must never leave it."""
    u = {"input_tokens": inp, "cache_creation_input_tokens": w5 + w1, "cache_read_input_tokens": cr, "output_tokens": out,
         "cache_creation": {"ephemeral_5m_input_tokens": w5, "ephemeral_1h_input_tokens": w1}}
    return json.dumps({"type": "assistant", "uuid": f"u-{mid}-{out}", "timestamp": iso(t), "requestId": f"req_{mid}",
                       "message": {"id": mid, "model": model, "usage": u,
                                   "content": [{"type": "text", "text": SECRET}, {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": SECRET}}]}}) + "\n"


def prompt(t, cwd=None):
    d = {"type": "user", "timestamp": iso(t), "message": {"role": "user", "content": SECRET}}
    if cwd:
        d["cwd"] = cwd
    return json.dumps(d) + "\n"


class World:
    """A claude dir, a sala state dir and an sala-web state dir in tmp_path, and the count over them."""

    def __init__(self, tmp_path):
        self.claude, self.sala, self.state = tmp_path / "claude", tmp_path / "sala", tmp_path / "state"
        self.claude.mkdir(parents=True)
        self.sala.mkdir()
        self.state.mkdir()
        self.settings = Settings(socket=tmp_path / "s.sock", state_dir=self.state, claude_dir=self.claude, tmux_socket_name="salaweb-pytest-none",
                                 roles_cmd=["false"], sala_models=tmp_path / "none.tsv", sala_state_dir=self.sala, admin_key=tmp_path / "none-key")
        self.rows: list[dict] = []
        self.holder: dict = {"path": self.state / "usage-scan.json"}

    def registry(self, name, sid, lane="subscription-1"):
        self.rows.append({"id": sid, "name": name, "lane": lane, "aliases": [], "state": "live",
                          "transcripts": [{"id": sid, "machine": "a", "at": "2026-10-01T00:00:00Z", "why": "import"}]})
        (self.sala / "sessions.json").write_text(json.dumps({"schema": 1, "sessions": {r["id"]: r for r in self.rows}}))

    def transcript(self, sid, *lines, sub=None, proj="-work-example-repo", mtime=NOW):
        d = self.claude / "projects" / proj
        p = (d / sid / "subagents" / sub) if sub else (d / f"{sid}.jsonl")
        p.parent.mkdir(parents=True, exist_ok=True)
        with open(p, "a", encoding="utf-8") as f:
            f.writelines(lines)
        os.utime(p, (mtime, mtime))
        return p

    def count(self, q=None, now=NOW, rows=LANE_ROWS, anchor=None):
        return U.compute(self.settings, [], rows, [], quota() if q is None else q, now, self.holder, None, anchor)


@pytest.fixture
def w(tmp_path, monkeypatch):
    monkeypatch.setattr(S, "live_tmux_names", lambda: {})   # never the default tmux server's names
    return World(tmp_path)


def rows_of(got, **where):
    """The rows of the count (all weeks: [week, day, lane, model, project, agent, folder, usd, replies, tokens]) that match the named columns."""
    col = {"week": 0, "day": 1, "lane": 2, "model": 3, "project": 4, "agent": 5, "folder": 6}
    return [r for r in got["rows"] if all(r[col[k]] == v for k, v in where.items())]


# ── the weeks and the days ───────────────────────────────────────────────────
def test_a_week_runs_from_one_weekly_reset_to_the_next_and_there_are_three():
    reset = at(28, 5)
    got, known = U.week_bounds(reset, NOW)
    assert known and got == [(reset - 7 * 86400, reset), (reset - 14 * 86400, reset - 7 * 86400), (reset - 21 * 86400, reset - 14 * 86400)]


def test_a_reset_that_has_passed_is_rolled_forward_by_whole_weeks_and_a_far_one_back():
    got, _ = U.week_bounds(at(14, 5), NOW)                    # last week's reset, from an old quota answer
    assert got[0] == (at(21, 5), at(28, 5))
    got, _ = U.week_bounds(at(28, 5) + 3 * 7 * 86400, NOW)    # a reset three weeks ahead
    assert got[0] == (at(21, 5), at(28, 5))


def test_with_no_reset_known_the_weeks_are_seven_day_windows_ending_now():
    got, known = U.week_bounds(None, NOW)
    assert not known and got[0] == (NOW - 7 * 86400, NOW) and got[2][0] == NOW - 21 * 86400


def test_a_day_is_a_kst_day_and_a_week_lists_the_days_it_touches():
    assert U.day_of(at(23, 14) + 3599) == "2026-10-23"       # 23:59:59 KST
    assert U.day_of(at(23, 15)) == "2026-10-24"              # midnight KST
    assert U.kst_minute(at(28, 5)) == "2026-10-28T14:00"
    assert U.days_between(at(21, 5), at(28, 5)) == [f"2026-10-{d}" for d in (21, 22, 23, 24, 25, 26, 27, 28)]
    assert U.days_between(at(21, 15), at(28, 15)) == [f"2026-10-{d}" for d in (22, 23, 24, 25, 26, 27, 28)]   # ends at KST midnight: that day is not one of them


# ── the names ────────────────────────────────────────────────────────────────
def test_the_project_is_the_agent_name_up_to_its_project_part():
    scopes = ["example", "beta"]
    assert U.project_of("example-alpha-build", scopes) == "example-alpha"
    assert U.project_of("beta-main", scopes) == "beta-main"
    assert U.project_of("loose-thing-x", scopes) == "loose"            # a first part that is no scope
    assert U.project_of("solo", scopes) == "solo"
    assert U.project_of(U.UNNAMED, scopes) == U.UNNAMED
    assert U.project_of("a-b-c", []) == "a-b" and U.project_of("a-b", []) == "a"   # with no scope configured


def test_the_folder_is_the_session_start_directory_with_a_worktree_counted_as_its_repo_and_home_as_a_tilde():
    home = "/srv/people/u1"
    assert U.folder_of("/srv/people/u1", "-srv-people-u1", home) == "~"
    assert U.folder_of("/srv/people/u1/proj", "-x", home) == "~/proj"
    assert U.folder_of("/srv/people/u1/proj/.claude/worktrees/agent-1", "-x", home) == "~/proj"
    assert U.folder_of("/srv/data/", "-x", home) == "/srv/data"
    assert U.folder_of(None, "-srv-people-u1", home) == "~"                                         # no cwd in the transcript: the folder name Claude Code made
    assert U.folder_of(None, "-srv-people-u1-proj", home) == "proj"
    assert U.folder_of(None, "-srv-people-u1-proj--claude-worktrees-a1", home) == "proj"


# ── the count ────────────────────────────────────────────────────────────────
def test_a_reply_is_priced_from_the_table_and_lands_on_its_week_day_lane_agent_and_folder(w):
    w.registry("example-alpha-build", A)
    # 1M input at $2 + 100k output at $10 = $3.00 on sonnet; 200k cache read at $0.10 = $0.02
    w.transcript(A, prompt(at(22, 1), cwd="/work/example-repo"), reply("m1", "claude-sonnet-5-5", at(22, 1), inp=1_000_000, out=100_000),
                 reply("m2", "claude-sonnet-5-5", at(22, 2), cr=200_000))
    got = w.count()
    (r,) = rows_of(got, week=0, day="2026-10-22", lane="subscription-1", model="claude-sonnet-5-5", project="example-alpha", agent="example-alpha-build")
    assert r[6] == "/work/example-repo" and r[7] == pytest.approx(3.02) and r[8] == 2
    assert r[9] == [1_000_000, 0, 0, 200_000, 100_000]                                         # the tokens stay on record, in the table's order
    assert got["weeks"][0]["total"] == pytest.approx(3.02) and got["weeks"][0]["replies"] == 2 and got["weeks"][1]["total"] == 0
    assert got["prices"]["asOf"] and got["prices"]["models"]["claude-sonnet-5-5"]["input"] == 2     # the table and its as-of marker, once


def test_the_cache_write_tiers_have_their_own_price(w):
    w.registry("example-alpha-build", A)
    w.transcript(A, reply("m1", "claude-sonnet-5-5", at(22, 1), w5=1_000_000, w1=1_000_000))
    (r,) = w.count()["rows"]
    assert r[7] == pytest.approx(2.5 + 4)


def test_a_streamed_reply_and_a_forked_history_are_counted_once_with_the_largest_counts(w):
    w.registry("example-alpha-build", A)
    w.registry("example-beta-build", B)
    # one reply streamed as three lines of one message id: the last has the full output
    w.transcript(A, reply("m1", "claude-sonnet-5-5", at(22, 1), out=10), reply("m1", "claude-sonnet-5-5", at(22, 1), out=500_000),
                 reply("m1", "claude-sonnet-5-5", at(22, 1), out=300_000))
    # a fork copies that history into another file: the same message id again
    w.transcript(B, reply("m1", "claude-sonnet-5-5", at(22, 1), out=500_000), reply("m9", "claude-sonnet-5-5", at(22, 3), out=100_000))
    got = w.count()
    assert got["weeks"][0]["replies"] == 2 and got["weeks"][0]["total"] == pytest.approx(5 + 1)


def test_a_subagent_transcript_is_counted_for_the_session_whose_folder_holds_it(w):
    w.registry("example-alpha-build", A)
    w.transcript(A, reply("m1", "claude-sonnet-5-5", at(22, 1), out=100_000))
    w.transcript(A, reply("s1", "claude-haiku-4-5", at(22, 2), out=1_000_000), sub="agent-xyz.jsonl")
    got = w.count()
    assert {r[3]: r[5] for r in got["rows"]} == {"claude-sonnet-5-5": "example-alpha-build", "claude-haiku-4-5": "example-alpha-build"}
    assert got["weeks"][0]["total"] == pytest.approx(1 + 5)


def test_a_session_the_registry_does_not_know_is_unnamed_and_its_project_is_too(w):
    w.transcript(C, reply("m1", "claude-sonnet-5-5", at(22, 1), out=100_000))
    (r,) = w.count()["rows"]
    assert r[4] == U.UNNAMED and r[5] == U.UNNAMED and r[2] == "subscription-1"


def test_the_lane_is_the_lane_of_the_session_and_billed_leaves_out_the_flat_plan(w):
    w.registry("example-alpha-build", A, lane="subscription-1")
    w.registry("example-beta-build", B, lane="bedrock")
    w.transcript(A, reply("m1", "claude-sonnet-5-5", at(22, 1), out=100_000))      # $1.00 flat
    w.transcript(B, reply("m2", "claude-sonnet-5-5", at(22, 1), out=200_000))      # $2.00 billed
    got = w.count()
    assert got["weeks"][0]["total"] == pytest.approx(3) and got["weeks"][0]["billed"] == pytest.approx(2)
    lanes = {x["code"]: x for x in got["lanes"]}
    assert lanes["subscription-1"]["flat"] is True and lanes["subscription-1"]["billing"] == "subscription" and lanes["subscription-1"]["known"] is True
    assert lanes["bedrock"]["flat"] is False and lanes["bedrock"]["billing"] == "usage"
    assert lanes["subscription-1"]["quota"] == {"percent": 40, "resetsAt": int(at(28, 5))}      # the weekly limit used, from the quota answer


def test_with_no_lane_table_an_account_lane_is_flat_and_the_rest_billed_and_known_says_so(w):
    w.registry("example-alpha-build", A, lane="subscription-1")
    w.registry("example-beta-build", B, lane="bedrock")
    w.transcript(A, reply("m1", "claude-sonnet-5-5", at(22, 1), out=100_000))
    w.transcript(B, reply("m2", "claude-sonnet-5-5", at(22, 1), out=200_000))
    lanes = {x["code"]: x for x in w.count(rows=[])["lanes"]}
    assert lanes["subscription-1"]["flat"] is True and lanes["bedrock"]["flat"] is False and not lanes["bedrock"]["known"]


def test_replies_of_the_three_weeks_land_in_their_own_week_and_older_or_later_ones_in_none(w):
    w.registry("example-alpha-build", A)
    w.transcript(A, reply("w0", "claude-sonnet-5-5", at(21, 6), out=100_000),     # just after the reset: week 0
                 reply("w1", "claude-sonnet-5-5", at(21, 4), out=100_000),        # an hour before it: week 1
                 reply("w2", "claude-sonnet-5-5", at(14, 4), out=100_000),        # week 2
                 reply("old", "claude-sonnet-5-5", at(7, 4), out=100_000),        # before week 2 began
                 reply("late", "claude-sonnet-5-5", at(28, 6), out=100_000))      # after week 0 ends
    got = w.count()
    assert [x["replies"] for x in got["weeks"]] == [1, 1, 1]
    assert [r[0] for r in got["rows"]] == [0, 1, 2]
    assert got["weeks"][0]["startKst"] == "2026-10-21T14:00" and got["weeks"][0]["endKst"] == "2026-10-28T14:00" and got["resetKnown"] is True


def test_a_reply_at_kst_midnight_belongs_to_the_next_day(w):
    w.registry("example-alpha-build", A)
    w.transcript(A, reply("a", "claude-sonnet-5-5", at(22, 14) + 3599, out=1), reply("b", "claude-sonnet-5-5", at(22, 15), out=1))
    days = sorted(r[1] for r in w.count()["rows"])
    assert days == ["2026-10-22", "2026-10-23"]


def test_a_model_with_no_price_costs_nothing_and_is_listed_never_silently_dropped(w):
    w.registry("example-alpha-build", A)
    w.transcript(A, reply("m1", "claude-mystery-9", at(22, 1), out=1_000_000), reply("m2", "claude-mystery-9", at(22, 2), out=1_000_000))
    got = w.count()
    assert got["unpriced"] == [{"model": "claude-mystery-9", "replies": 2}]
    assert got["weeks"][0]["total"] == 0 and got["weeks"][0]["replies"] == 2


def test_a_worktree_is_counted_under_its_repo_folder(w):
    w.registry("example-alpha-build", A)
    w.transcript(A, prompt(at(22, 1), cwd="/work/example-repo/.claude/worktrees/agent-1"), reply("m1", "claude-sonnet-5-5", at(22, 1), out=1))
    (r,) = w.count()["rows"]
    assert r[6] == "/work/example-repo"


def test_the_answer_carries_no_prompt_reply_or_tool_text(w):
    w.registry("example-alpha-build", A)
    w.transcript(A, prompt(at(22, 1), cwd="/work/example-repo"), reply("m1", "claude-sonnet-5-5", at(22, 1), out=1))
    assert SECRET not in json.dumps(w.count())
    w.holder["scan"].save(force=True)
    assert SECRET not in (w.state / "usage-scan.json").read_text()


def test_the_last_saved_anchor_stands_in_when_the_quota_has_no_reset(w):
    w.registry("example-alpha-build", A)
    w.transcript(A, reply("m1", "claude-sonnet-5-5", at(22, 1), out=100_000))
    got = w.count(q=[], anchor=at(28, 5))
    assert got["resetKnown"] is True and got["anchor"] == int(at(28, 5)) and got["weeks"][0]["total"] == pytest.approx(1)
    assert w.count(q=[])["resetKnown"] is False


def test_a_reset_answer_with_fractions_of_a_second_is_one_week_boundary(w):
    got = w.count(q=quota("2026-10-28T05:00:00.412Z"))
    assert got["weeks"][0]["end"] == int(at(28, 5))


def test_the_same_hours_of_last_week_is_the_dollars_of_week_one_over_the_hours_week_zero_has_run(w):
    w.registry("example-alpha-build", A)
    # week 0 began Wed Oct 21st 05:00 UTC, so at NOW (Oct 23rd 12:00) it has run 55 h; the same 55 h of week 1 end Oct 18th 12:00 + 1 week = Oct 16th 12:00
    w.transcript(A, reply("p1", "claude-sonnet-5-5", at(15, 6), out=100_000), reply("p2", "claude-sonnet-5-5", at(19, 6), out=100_000))
    got = w.count()
    assert got["sameHours"]["elapsedH"] == 55.0 and got["sameHours"]["prevTotal"] == pytest.approx(1)


# ── keeping it cheap ─────────────────────────────────────────────────────────
def test_a_second_count_opens_no_transcript_and_a_grown_one_reads_only_what_was_added(w):
    w.registry("example-alpha-build", A)
    p = w.transcript(A, prompt(at(22, 1), cwd="/work/example-repo"), reply("m1", "claude-sonnet-5-5", at(22, 1), out=100_000))
    first = w.count()
    assert first["scannedBytes"] == p.stat().st_size
    assert w.count()["scannedBytes"] == 0                                                  # nothing changed: not opened
    before = p.stat().st_size
    w.transcript(A, reply("m2", "claude-sonnet-5-5", at(22, 2), out=100_000), mtime=NOW + 5)
    third = w.count()
    assert third["scannedBytes"] == p.stat().st_size - before                              # only the new line
    assert third["weeks"][0]["replies"] == 2 and third["weeks"][0]["total"] == pytest.approx(2)


def test_a_line_still_being_written_is_read_when_it_is_complete(w):
    w.registry("example-alpha-build", A)
    whole = reply("m1", "claude-sonnet-5-5", at(22, 1), out=100_000)
    p = w.transcript(A, whole[: len(whole) // 2], mtime=NOW)
    assert w.count()["weeks"][0]["replies"] == 0
    with open(p, "a", encoding="utf-8") as f:
        f.write(whole[len(whole) // 2:])
    os.utime(p, (NOW + 5, NOW + 5))
    assert w.count()["weeks"][0]["replies"] == 1


def test_a_replaced_or_shortened_transcript_is_read_again_from_its_start(w):
    w.registry("example-alpha-build", A)
    p = w.transcript(A, reply("m1", "claude-sonnet-5-5", at(22, 1), out=100_000), reply("m2", "claude-sonnet-5-5", at(22, 2), out=100_000))
    assert w.count()["weeks"][0]["replies"] == 2
    p.unlink()
    w.transcript(A, reply("m3", "claude-sonnet-5-5", at(22, 3), out=100_000), mtime=NOW + 10)   # a new file at the same path (a new inode)
    got = w.count()
    assert got["weeks"][0]["replies"] == 1 and got["scannedBytes"] == p.stat().st_size


def test_the_scan_cache_is_saved_and_a_new_process_does_not_read_the_transcripts_again(w):
    w.registry("example-alpha-build", A)
    p = w.transcript(A, reply("m1", "claude-sonnet-5-5", at(22, 1), out=100_000))
    w.count()
    w.holder["scan"].save(force=True)
    saved = w.state / "usage-scan.json"
    assert saved.exists() and SECRET not in saved.read_text()
    w.holder = {"path": saved}                                                             # a new process: only the file is left
    got = w.count()
    assert got["scannedBytes"] == 0 and got["weeks"][0]["replies"] == 1 and p.exists()


def test_a_cache_built_for_a_narrower_window_is_discarded_not_trusted(w):
    w.registry("example-alpha-build", A)
    w.transcript(A, reply("m1", "claude-sonnet-5-5", at(22, 1), out=100_000))
    w.count(q=quota(RESET))
    w.holder["scan"].save(force=True)
    w.holder = {"path": w.state / "usage-scan.json"}
    later = w.count(q=quota("2026-11-04T05:00:00Z"), now=at(30, 12))                       # the window moved forward: the saved one reaches further back, still good
    assert later["weeks"][0]["start"] == int(at(28, 5))
    assert later["scannedBytes"] == 0
    w.holder = {"path": w.state / "usage-scan.json"}
    earlier = w.count(q=quota("2026-10-21T05:00:00Z"), now=at(15, 12))                     # the window moves back past what the file was built for
    assert earlier["scannedBytes"] > 0


def test_a_transcript_outside_the_window_is_not_opened(w):
    w.registry("example-alpha-build", A)
    w.transcript(A, reply("m1", "claude-sonnet-5-5", at(22, 1), out=100_000), mtime=at(1, 0))     # last touched Oct 1st: before week 2 began
    got = w.count()
    assert got["transcripts"] == 0 and got["scannedBytes"] == 0 and got["rows"] == []


def test_a_second_login_folder_that_links_to_the_first_is_counted_once_and_a_separate_one_has_its_lane(w, monkeypatch, tmp_path):
    w.registry("example-alpha-build", A, lane="subscription-1")
    w.transcript(A, reply("m1", "claude-sonnet-5-5", at(22, 1), out=100_000))
    team = tmp_path / "team"
    team.mkdir()
    (team / "projects").symlink_to(w.claude / "projects")
    monkeypatch.setattr(U, "_login_dirs", lambda: {"subscription-2": team})
    got = w.count()
    assert got["weeks"][0]["replies"] == 1 and rows_of(got)[0][2] == "subscription-1"       # once, on the lane the records say
    other = tmp_path / "other"
    (other / "projects" / "-work-other").mkdir(parents=True)
    (other / "projects" / "-work-other" / f"{D}.jsonl").write_text(reply("x1", "claude-sonnet-5-5", at(22, 1), out=100_000))
    os.utime(other / "projects" / "-work-other" / f"{D}.jsonl", (NOW, NOW))
    monkeypatch.setattr(U, "_login_dirs", lambda: {"subscription-2": team, "subscription-3": other})
    w.holder = {"path": None}
    got = w.count()
    assert {r[2] for r in got["rows"]} == {"subscription-1", "subscription-3"}               # the separate login's replies carry its fixed lane


# ── the endpoint ─────────────────────────────────────────────────────────────
def fresh_times():
    now = time.time()
    return now - 3600, now - 8 * 86400


def get_usage(c, query="week=0", tries=100):
    """The week's answer once a count has been made. A visit makes none (test_usage_count.py), so an answer of "noCount" is followed by one Reload
    (`fresh=1`, what the tab's Reload button asks), then the count is waited for."""
    reloaded = False
    for _ in range(tries):
        r = c.get(f"/api/usage?{query}" + ("&fresh=1" if reloaded == "now" else ""))
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


def test_the_endpoint_serves_a_week_at_once_with_its_rows_and_never_a_text_of_a_transcript(w):
    one_hour_ago, eight_days_ago = fresh_times()
    w.registry("example-alpha-build", A)
    w.transcript(A, prompt(one_hour_ago, cwd="/work/example-repo"), reply("m1", "claude-sonnet-5-5", one_hour_ago, out=100_000),
                 reply("m2", "claude-sonnet-5-5", eight_days_ago, out=200_000), mtime=time.time())
    with TestClient(create_app(w.settings)) as c:
        first = c.get("/api/usage?week=0").json()
        assert first.get("noCount") and not first.get("pending") and not first["rows"], first   # at once, and no count made by looking
        d0 = get_usage(c, "week=0")
        d1 = get_usage(c, "week=1")
        bad = [c.get(f"/api/usage?week={x}") for x in ("3", "-1", "x")]
    assert d0["fields"] == U.FIELDS and d0["week"] == 0 and d1["week"] == 1 and d0["tz"] == "Asia/Seoul" and d0["now"] > 0
    assert len(d0["rows"]) == 1 and len(d1["rows"]) == 1
    day, lane, model, project, agent, folder, usd, replies, tokens = d0["rows"][0]            # the week column is dropped from a week's rows
    assert (lane, model, project, agent, folder, replies, tokens[4]) == ("subscription-1", "claude-sonnet-5-5", "example-alpha", "example-alpha-build", "/work/example-repo", 1, 100_000)
    assert usd == pytest.approx(1.0) and d1["rows"][0][6] == pytest.approx(2.0)
    assert [x.status_code for x in bad] == [400, 400, 400]
    assert SECRET not in json.dumps([d0, d1])


def test_the_endpoint_refresh_keeps_the_last_answer_when_a_count_fails(w, monkeypatch):
    one_hour_ago, _ = fresh_times()
    w.registry("example-alpha-build", A)
    w.transcript(A, reply("m1", "claude-sonnet-5-5", one_hour_ago, out=100_000), mtime=time.time())
    with TestClient(create_app(w.settings)) as c:
        good = get_usage(c)
        assert good["weeks"][0]["total"] == pytest.approx(1)

        def boom(*a, **k):
            raise RuntimeError(SECRET)

        monkeypatch.setattr(U, "compute", boom)
        c.get("/api/usage?week=0&fresh=1")
        time.sleep(0.5)
        after = get_usage(c)
    assert after["weeks"][0]["total"] == pytest.approx(1)                                       # the last good answer stays
    assert "error" in after and SECRET not in json.dumps(after)                                  # in plain words, never the exception's text
