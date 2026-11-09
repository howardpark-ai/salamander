"""When the Usage analysis count is made (usage.py `UsageCache`, swr.py `peek`/`start`/`refresh_now`/`reload`, usage_job.py, contrib/sala-web-usage-count): a job of its
own once a day, and the tab's Reload; never a visit.

What a wrong build costs: a visit that starts a count (the first one reads every recent transcript and the page then asks again every few seconds for as long as it
runs, which is how the tab came to be slow after every restart of the app), a Reload that blocks the server or starts a second count beside one that runs, a restarted
app that counts again instead of serving what the last count saved (rows and the drill-down's replies), a daily job whose count the app does not pick up until the next
restart, a job that exits 0 after a failed count or that replaces the last saved count with nothing, and a tab with no count that polls for ever or says nothing.
Every transcript, registry and state file is a fake in tmp_path; the job runs as the real command in a subprocess with an empty PATH (no tmux, no sala), a private HOME
and the fake state directory; nothing asks Anthropic or AWS.
"""

from __future__ import annotations

import asyncio
import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

import pytest
from starlette.testclient import TestClient

from sala_web import quota as Q
from sala_web import swr as SWR
from sala_web import usage as U
from sala_web import usage_job as J
from sala_web.app import create_app

from test_usage import A, SECRET, fresh_times, get_usage, reply, w   # noqa: F401  (the fake transcripts and registry are the data layer's own)

WEB = Path(__file__).resolve().parents[1]
SAVED = ("usage-answer.json", "usage-replies.json", "usage-scan.json")


def one_transcript(w, out=100_000, mid="m1"):
    one_hour_ago, _ = fresh_times()
    w.registry("example-alpha-build", A)
    w.transcript(A, reply(mid, "claude-sonnet-5-5", one_hour_ago, out=out), mtime=time.time())


def counting(monkeypatch, hold: threading.Event | None = None, fail: bool = False):
    """Wrap the count: the number of calls, each held until `hold` is set (a bounded wait) when one is given, or raising."""
    real = U.compute
    rec = {"calls": 0}

    def wrapped(*a, **k):
        rec["calls"] += 1
        if hold is not None:
            hold.wait(5)
        if fail:
            raise RuntimeError(SECRET)
        return real(*a, **k)

    monkeypatch.setattr(U, "compute", wrapped)
    return rec


def job_env(w, tmp_path) -> dict:
    """The environment of the job command: an empty PATH (no tmux, no sala), a private HOME, and this test's state, Claude and sala directories."""
    empty = tmp_path / "empty-path"
    empty.mkdir(exist_ok=True)
    home = tmp_path / "home"
    home.mkdir(exist_ok=True)
    return {"PATH": str(empty), "HOME": str(home), "XDG_CONFIG_HOME": str(home / "config"), "XDG_STATE_HOME": str(home / "state"), "SALA_CONFIG": "/nonexistent/sala-config",
            "SALA_WEB_STATE_DIR": str(w.state), "SALA_WEB_CLAUDE_DIR": str(w.claude), "SALA_WEB_SALA_STATE": str(w.sala), "SALA_WEB_SALA_CMD": str(empty / "no-sala"),
            "TMUX_TMPDIR": str(empty)}   # a tmux that is on the PATH looks for its server here: there is none


def run_job(w, tmp_path, argv=None, **env):
    return subprocess.run(argv or [sys.executable, "-m", "sala_web.usage_job"], env={**job_env(w, tmp_path), **env}, capture_output=True, text=True, timeout=120, cwd=tmp_path)


# ── a visit counts nothing ───────────────────────────────────────────────────
def test_a_visit_starts_no_count_whatever_it_asks_and_the_answer_says_there_is_none(w, monkeypatch):
    one_transcript(w)
    rec = counting(monkeypatch)
    with TestClient(create_app(w.settings)) as c:
        got = [c.get(f"/api/usage?week={wk}").json() for wk in (0, 1, 2, 0)]            # the tab, the Explorer's weeks
        got.append(c.get("/api/usage/digest?week=0").json())                            # the Digest
        got.append(c.get("/api/usage/replies?week=0").json())                           # the Explorer's drill-down
        time.sleep(0.3)
        got.append(c.get("/api/usage?week=0").json())
    assert rec["calls"] == 0
    assert all(g.get("noCount") is True and "pending" not in g and "refreshing" not in g and not g.get("rows") for g in got), got
    assert got[4]["sentences"] == []


def test_a_visit_to_a_count_a_month_old_starts_none_either_and_serves_it_as_it_is(w, monkeypatch):
    one_transcript(w)
    with TestClient(create_app(w.settings)) as c:
        old = get_usage(c)                                                                # a count, made by a Reload
    saved = json.loads((w.state / "usage-answer.json").read_text())
    saved["fetchedAt"] -= 30 * 86400 * 1000
    (w.state / "usage-answer.json").write_text(json.dumps(saved))
    rec = counting(monkeypatch)
    with TestClient(create_app(w.settings)) as c:
        got = [c.get("/api/usage?week=0").json() for _ in range(3)]
        time.sleep(0.3)
    assert rec["calls"] == 0
    assert all(not g.get("pending") and not g.get("refreshing") and g["rows"] == old["rows"] and g["generated"] == old["generated"] for g in got)


# ── Reload ───────────────────────────────────────────────────────────────────
def test_reload_counts_in_a_thread_once_however_often_it_is_pressed_and_the_server_stays_free(w, monkeypatch):
    one_transcript(w)
    hold = threading.Event()
    rec = counting(monkeypatch, hold=hold)
    try:
        with TestClient(create_app(w.settings)) as c:
            first = c.get("/api/usage?week=0&fresh=1").json()
            assert first.get("pending") and first.get("refreshing") and first["rows"] == []   # at once: "counting", the page asks again
            t0 = time.monotonic()
            again = [c.get("/api/usage?week=0&fresh=1").json(), c.get("/api/usage/digest?week=0&fresh=1").json(), c.get("/api/usage/replies?week=0").json()]
            assert time.monotonic() - t0 < 1.5                                              # the count holds a thread, not the event loop
            assert all(g.get("pending") for g in again), again
            hold.set()
            done = get_usage(c)
    finally:
        hold.set()
    assert rec["calls"] == 1 and done["rows"] and not done.get("refreshing")


def test_a_failed_reload_leaves_the_last_count_and_says_so_in_words(w, monkeypatch):
    one_transcript(w)
    with TestClient(create_app(w.settings)) as c:
        good = get_usage(c)
        counting(monkeypatch, fail=True)
        c.get("/api/usage?week=0&fresh=1")
        after = get_usage(c)
    assert after["rows"] == good["rows"] and after["generated"] == good["generated"]
    assert after["error"] and SECRET not in json.dumps(after)


# ── a restart, and the job's count ───────────────────────────────────────────
def test_a_fresh_server_with_a_saved_count_serves_rows_digest_and_replies_without_counting(w, monkeypatch):
    one_transcript(w)
    with TestClient(create_app(w.settings)) as c:
        before = (get_usage(c), c.get("/api/usage/replies?week=0").json())
    rec = counting(monkeypatch)
    with TestClient(create_app(w.settings)) as c:
        rows, digest, replies = c.get("/api/usage?week=0").json(), c.get("/api/usage/digest?week=0").json(), c.get("/api/usage/replies?week=0").json()
    assert rec["calls"] == 0
    assert rows["rows"] == before[0]["rows"] and digest["sentences"] and replies == before[1] and replies["total"] == 1


def test_the_job_command_counts_and_saves_what_the_app_reads_and_exits_zero(w, tmp_path):
    one_transcript(w)
    done = run_job(w, tmp_path)
    assert done.returncode == 0, done.stderr
    for name in SAVED:
        assert (w.state / name).is_file(), name
        assert SECRET not in (w.state / name).read_text()                                      # names, counts and dollars only
    answer = json.loads((w.state / "usage-answer.json").read_text())
    assert answer["weeks"][0]["total"] == pytest.approx(1) and answer["replies"] == 1 and "refreshing" not in answer and "pending" not in answer
    with TestClient(create_app(w.settings)) as c:                                              # a server that never counted serves the job's count
        assert c.get("/api/usage?week=0").json()["weeks"][0]["total"] == pytest.approx(1)
        assert c.get("/api/usage/replies?week=0").json()["total"] == 1


def test_a_count_the_job_makes_while_the_app_runs_is_served_without_a_restart(w, tmp_path, monkeypatch):
    one_transcript(w)
    with TestClient(create_app(w.settings)) as c:
        assert get_usage(c)["weeks"][0]["total"] == pytest.approx(1)
        assert c.get("/api/usage/replies?week=0").json()["total"] == 1
        one_transcript(w, out=200_000, mid="m2")                                                # two more dollars since
        assert c.get("/api/usage?week=0").json()["weeks"][0]["total"] == pytest.approx(1)      # not counted by being looked at
        rec = counting(monkeypatch)
        done = run_job(w, tmp_path)
        assert done.returncode == 0, done.stderr
        assert c.get("/api/usage?week=0").json()["weeks"][0]["total"] == pytest.approx(3)
        assert c.get("/api/usage/replies?week=0").json()["total"] == 2
    assert rec["calls"] == 0                                                                   # the app read the job's files, it counted nothing


def test_a_second_run_of_the_job_reads_only_what_grew_since_the_first(w, tmp_path):
    one_transcript(w)
    assert run_job(w, tmp_path).returncode == 0
    first = json.loads((w.state / "usage-answer.json").read_text())
    one_transcript(w, out=200_000, mid="m2")
    assert run_job(w, tmp_path).returncode == 0
    second = json.loads((w.state / "usage-answer.json").read_text())
    assert second["weeks"][0]["total"] == pytest.approx(3) and 0 < second["scannedBytes"] < first["scannedBytes"] * 1.5   # the scan cache was saved by the first run


def test_a_failing_count_exits_non_zero_with_one_plain_line_and_leaves_the_saved_count_alone(w, monkeypatch, capsys):
    one_transcript(w)
    assert asyncio.run(J.run(w.settings)) == 0
    saved = {n: (w.state / n).read_bytes() for n in SAVED}
    counting(monkeypatch, fail=True)
    assert asyncio.run(J.run(w.settings)) == 1
    err = capsys.readouterr().err
    assert err.count("\n") == 1 and err.startswith("sala-web usage count failed: ") and SECRET not in err
    assert {n: (w.state / n).read_bytes() for n in SAVED} == saved


def test_a_failing_first_count_exits_non_zero_and_writes_no_count(w, monkeypatch):
    one_transcript(w)
    counting(monkeypatch, fail=True)
    assert asyncio.run(J.run(w.settings)) == 1
    assert not (w.state / "usage-answer.json").exists() and not (w.state / "usage-replies.json").exists()


def test_the_command_line_takes_nothing_and_the_wrapper_runs_the_job_in_the_web_environment(w, tmp_path):
    with pytest.raises(SystemExit) as e:
        J.main(["--nothing"])
    assert e.value.code == 2
    wrapper = WEB / "contrib" / "sala-web-usage-count"
    assert os.access(wrapper, os.X_OK)
    if not (WEB / ".venv" / "bin" / "python").exists():
        pytest.skip("no web/.venv here: the wrapper runs the job with it")
    one_transcript(w)
    done = run_job(w, tmp_path, [str(wrapper)], PATH="/usr/bin:/bin")                         # for the script's `env bash`; it sets its own PATH from there on
    assert done.returncode == 0, done.stderr
    assert (w.state / "usage-answer.json").is_file()


# ── the parts it is made of ──────────────────────────────────────────────────
def test_the_saved_quota_is_read_and_nothing_is_asked(tmp_path):
    (tmp_path / "quota-subscription-1.json").write_text(json.dumps({"lane": "subscription-1", "fetchedAt": 1, "limits": [{"label": "This week", "percent": 7}]}))

    def ask(token):
        raise AssertionError("the usage endpoint was asked")

    q = Q.QuotaCache({"subscription-1": tmp_path / "no-login", "subscription-2": tmp_path / "no-login-2"}, fetch=ask, state_dir=tmp_path)
    got = q.saved({"subscription-2": {"reason": "idle", "since": "x"}})
    assert got[0]["limits"] == [{"label": "This week", "percent": 7}] and got[1] == {"lane": "subscription-2", "dormant": {"reason": "idle", "since": "x"}}


def test_peek_starts_nothing_start_and_refresh_now_never_run_two_and_reload_reads_a_newer_file(tmp_path):
    path = tmp_path / "ans.json"
    calls = []

    async def refresh():
        calls.append(1)
        await asyncio.sleep(0.05)
        return {"v": len(calls)}

    async def go():
        r = SWR.Revalidating(path, 0.0, 1.0, {"v": 0})                                    # a ttl of zero: `serve` would start one at once
        assert r.peek()["pending"] is True and not calls                                   # `peek` never does
        await asyncio.gather(r.refresh_now(refresh), r.refresh_now(refresh))              # two Reloads at once: one count
        assert len(calls) == 1 and r.peek()["v"] == 1 and not r.running
        r.start(refresh)
        r.start(refresh)
        assert r.running
        await asyncio.wait([r._task])
        assert len(calls) == 2
        SWR.write_atomic(path, {"v": 9, "fetchedAt": int(time.time() * 1000)})            # another process wrote a count
        r.reload()
        assert r.peek()["v"] == 9
        r.start(refresh)
        SWR.write_atomic(path, {"v": 10, "fetchedAt": int(time.time() * 1000)})
        r.reload()                                                                          # a refresh running here is left alone
        assert r.peek()["v"] == 9
        await asyncio.wait([r._task])

    asyncio.run(go())
