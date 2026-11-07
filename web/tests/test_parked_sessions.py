"""A conversation moved into a background job is ONE session.

The CLI's "← for agents" view moves a session's conversation into a background job: the pane's claude stays as a viewer
(status "shell", `parkedJobId`) and ~/.claude/sessions holds a second row for the job (`kind` "bg", `jobId`, the same name).
The shapes below follow the rows the CLI writes, with fake values.
"""

import json
import os

from sala_web import sessions as S
from sala_web.config import Settings

PANE_SID = "bbbbbbbb-0000-4000-8000-0000000000b1"        # the conversation as it stood when it was moved
JOB_SID = "eeeeeeee-0000-4000-8000-0000000000e1"         # the job's conversation: the live one
JOB_ID = "eeeeeeee"


def pane_row(pid, **extra):
    d = {"pid": pid, "sessionId": PANE_SID, "startedAt": 1793177235703, "version": "2.1.312", "kind": "interactive",
         "entrypoint": "cli", "tmux": "demo-builder:@31.%31", "name": "demo-builder",
         "nameSource": "user", "updatedAt": 1793185380596, "status": "shell", "statusUpdatedAt": 1793185183544,
         "parkedJobId": JOB_ID, "cwd": "/home/alex/stackshot"}
    d.update(extra)
    return d


def bg_row(pid, **extra):
    d = {"pid": pid, "sessionId": JOB_SID, "startedAt": 1793185383417, "version": "2.1.312", "kind": "bg",
         "entrypoint": "cli", "name": "demo-builder", "nameSince": 1793185383418, "jobId": JOB_ID,
         "status": "idle", "updatedAt": 1793187512848, "statusUpdatedAt": 1793187512848, "cwd": "/home/alex/stackshot"}
    d.update(extra)
    return d


def other_row(pid, name="demo-helper"):
    return {"pid": pid, "sessionId": "5c1d0d0e-0000-4000-8000-000000000001", "kind": "interactive", "name": name,
            "tmux": name + ":@1.%1", "status": "busy", "updatedAt": 1793187000000, "cwd": "/home/alex/salamander"}


def setup(tmp_path, monkeypatch, rows):
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True, exist_ok=True)
    for d in rows:
        (claude / "sessions" / f"{d['pid']}.json").write_text(json.dumps(d))
    monkeypatch.setattr(S, "proc_lane", lambda p: "subscription-1")
    monkeypatch.setattr(S, "live_tmux_names", lambda: {})   # never the default tmux server's names
    return Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude)


# two live pids that are not each other (no procStart recorded, so a row counts as alive)
P1, P2, P3 = os.getpid(), os.getppid(), 1


def test_the_pane_and_its_job_are_one_row(tmp_path, monkeypatch):
    settings = setup(tmp_path, monkeypatch, [pane_row(P1), bg_row(P2), other_row(P3)])
    live = {s.name: s for s in S.read_live_sessions(settings)}
    assert sorted(live) == ["demo-builder", "demo-helper"]
    s = live["demo-builder"]
    assert s.pid == P1 and s.tmux == "demo-builder:@31.%31"      # the pane's row carries the identity
    assert s.parked_job == JOB_ID
    assert s.status == "idle"                                                # the job's, not the viewer's "shell"
    assert s.session_id == JOB_SID                                           # the live conversation: transcript, model, spend
    assert s.updated_at == 1793187512848                                     # the newer of the two
    assert s.to_json()["parkedJob"] == JOB_ID


def test_the_status_follows_the_job(tmp_path, monkeypatch):
    for job, shown in [("idle", "idle"), ("busy", "working"), ("waiting", "needs input")]:
        settings = setup(tmp_path, monkeypatch, [pane_row(P1), bg_row(P2, status=job)])
        rows = S.overview_rows(S.read_live_sessions(settings), {})
        assert len(rows) == 1
        assert rows[0]["status"] == shown and rows[0]["parkedJob"] == JOB_ID and rows[0]["sessionId"] == JOB_SID
        for f in (tmp_path / "claude" / "sessions").glob("*.json"):
            f.unlink()


def test_the_sidebar_groups_hold_one_entry(tmp_path, monkeypatch):
    settings = setup(tmp_path, monkeypatch, [pane_row(P1), bg_row(P2)])
    roles = {"demo-builder": {"role": "back", "project": "projects/stackshot"}}
    out = S.group_sessions(S.read_live_sessions(settings), roles)
    names = [s["name"] for sc in out for g in sc["groups"] for s in g["sessions"]]
    assert names == ["demo-builder"]


def test_a_job_whose_viewer_is_gone_stays_listed(tmp_path, monkeypatch):
    settings = setup(tmp_path, monkeypatch, [bg_row(P2)])
    live = S.read_live_sessions(settings)
    assert [(s.name, s.status, s.parked_job) for s in live] == [("demo-builder", "idle", None)]


def test_a_pane_whose_job_is_dead_keeps_its_own_state_and_the_mark(tmp_path, monkeypatch):
    # the job's process is gone (its row is stale, a dead pid): the viewer is all that is left
    settings = setup(tmp_path, monkeypatch, [pane_row(P1), bg_row(2 ** 22 + 12345)])
    live = S.read_live_sessions(settings)
    assert len(live) == 1
    s = live[0]
    assert (s.status, s.session_id, s.parked_job) == ("shell", PANE_SID, JOB_ID)


def test_an_older_cli_names_the_fork_by_its_whole_uuid(tmp_path, monkeypatch):
    # CLI 2.1.28x: parkedJobId is the fork's full uuid and its row has no jobId
    fork = bg_row(P2)
    del fork["jobId"]
    fork["kind"] = "interactive"
    settings = setup(tmp_path, monkeypatch, [pane_row(P1, parkedJobId=JOB_SID), fork])
    live = S.read_live_sessions(settings)
    assert [(s.pid, s.status, s.session_id) for s in live] == [(P1, "idle", JOB_SID)]


def test_an_unparked_session_is_unchanged(tmp_path, monkeypatch):
    settings = setup(tmp_path, monkeypatch, [other_row(P3)])
    s = S.read_live_sessions(settings)[0]
    assert (s.status, s.session_id, s.parked_job) == ("busy", "5c1d0d0e-0000-4000-8000-000000000001", None)
    assert "parkedJob" not in s.to_json()
    row = S.overview_rows([s], {})[0]
    assert "parkedJob" not in row and row["status"] == "working"
