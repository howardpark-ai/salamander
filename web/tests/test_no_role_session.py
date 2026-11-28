"""A session made with `sala spawn --project K --role none` is on no project's agents map, so stackshot's roles give it
neither a role nor a project. Its registry row (sessions.json) carries the project and `no_role` = 1; the page groups it
under that project and counts its replies as unread, as it does for a front agent.

What a wrong answer costs: the session the owner works with sits in Unregistered with no project, and its replies never light the
unread count; a row that later got a role (an agent now) keeps the session's project over what stackshot says; a row with the
project but no mark pulled into a group."""

from __future__ import annotations

import json
import os

from starlette.testclient import TestClient

from sala_web import sessions as S
from sala_web import unread as UR
from sala_web.app import create_app
from sala_web.config import Settings


def sess(name):
    return S.Session(pid=1, session_id="sid-" + name, name=name, cwd="/tmp", status="idle", tmux="", lane="subscription-1")


def row(name, **kw):
    return {"id": "id-" + name, "name": name, "state": "live", "transcripts": [{"id": "sid-" + name}], **kw}


def grouped(rows, names, roles=None):
    live = [sess(n) for n in names]
    S.attach_agent_ids(live, rows)
    out = S.group_sessions(live, roles or {})
    return {s["name"]: (g["key"], s) for sc in out for g in sc["groups"] for s in g["sessions"]}


def test_a_no_role_row_gives_the_session_its_project_and_it_counts_for_unread():
    key, s = grouped([row("example-pink", project="projects/alpha", no_role="1")], ["example-pink"])["example-pink"]
    assert key == "projects/alpha" and s["project"] == "projects/alpha" and s["role"] is None
    assert UR.counts_unread(s)


def test_a_row_with_a_project_and_no_mark_stays_unregistered():
    key, s = grouped([row("example-pink", project="projects/alpha")], ["example-pink"])["example-pink"]
    assert key == S.UNREGISTERED and not UR.counts_unread(s)


def test_a_row_that_got_a_role_is_an_agent_and_stackshot_decides():
    rows = [row("example-pink", project="projects/alpha", no_role="1", role="back")]
    key, s = grouped(rows, ["example-pink"], {"example-pink": {"role": "back", "project": "projects/beta"}})["example-pink"]
    assert key == "projects/beta" and s["role"] == "back" and not UR.counts_unread(s)
    key, _ = grouped(rows, ["example-pink"])["example-pink"]
    assert key == S.UNREGISTERED   # the mark is stale (a role was given): the row's project is not used for it


def test_the_roles_map_wins_when_it_names_the_session():
    rows = [row("example-main", project="projects/alpha", no_role="1")]
    key, s = grouped(rows, ["example-main"], {"example-main": {"role": "front", "project": "projects/beta"}})["example-main"]
    assert (key, s["role"]) == ("projects/beta", "front")


def test_the_listing_endpoint_groups_and_counts_it(tmp_path, monkeypatch):
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    (claude / "projects").mkdir()
    state = tmp_path / "sala-state"
    state.mkdir()
    (state / "sessions.json").write_text(json.dumps({"sessions": {"id-example-pink": row("example-pink", project="projects/alpha", no_role="1")}}))
    (claude / "sessions" / "a.json").write_text(json.dumps(
        {"pid": os.getpid(), "sessionId": "sid-example-pink", "name": "example-pink", "cwd": "/tmp", "status": "idle"}))
    monkeypatch.setattr(S, "proc_lane", lambda p: "subscription-1")
    monkeypatch.setattr(S, "launch_flags", lambda p: {})
    monkeypatch.setattr(S, "live_tmux_names", lambda: {})
    monkeypatch.setattr(S, "model_env", lambda p: {})
    monkeypatch.setattr(S.CatalogCache, "for_pid", lambda self, p: {})
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude, sala_state_dir=state,
                        tmux_socket_name="salaweb-pytest-unused", sala_models=tmp_path / "models.tsv",
                        roles_cmd=["echo", json.dumps({"sessions": {}})])
    c = TestClient(create_app(settings))
    body = c.get("/api/sessions").json()
    assert [g["key"] for g in body["groups"]] == ["projects/alpha"]
    (s,) = body["groups"][0]["sessions"]
    assert s["name"] == "example-pink" and s["role"] is None and "unread_count" in s
