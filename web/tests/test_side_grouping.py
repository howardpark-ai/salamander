"""Where a quick (side) session sits in the sidebar and the overview (Quick > Fork made
example-lamp-share-side-drift42 and the page listed it under Unregistered).

A side session is on no project's agents map, so stackshot's roles give it no project. sala keeps a record for it
(`<sala state>/side/<name>.side`, written by `sala spawn --side`): kind fork or discuss, origin, project, item. The page groups
it by that record: a fork under the group its origin has, a discuss session under the project of its item; a missing record, or
one that leads to no project, keeps today's Unregistered.

What a wrong answer costs: a fork or a discuss session lost in Unregistered, away from the project the owner started it for; a fork
put in a group its origin is not in; a side session given a role it must not have (the origin's, so it sorts as an agent); a
record that breaks the list when it is odd (empty, no origin, a loop of forks); the overview and the sidebar disagreeing."""

from __future__ import annotations

import json
import os

from starlette.testclient import TestClient

from sala_web import sessions as S
from sala_web.app import create_app
from sala_web.config import Settings


def sess(name):
    return S.Session(pid=1, session_id=name, name=name, cwd="/tmp", status="idle", tmux="", lane="subscription-1")


def record(side_dir, name, kind, origin="", project="", item="board#41"):
    side_dir.mkdir(parents=True, exist_ok=True)
    (side_dir / f"{name}.side").write_text(
        f"name={name}\nkind={kind}\norigin={origin}\nproject={project}\nitem={item}\nagents=\nsummary_to=\nstarted=1\nuuid=u\n")


ROLES = {
    "example-lamp-share": {"role": "back", "project": "projects/gbrain"},
    "example-lamp-main": {"role": "front", "project": "projects/gbrain"},
    "gamma-harbor-main": {"role": "front", "project": "projects/harbor-room-b"},
}


def where(scopes, name):
    """(scope key, group key, session json) of a session in the grouped payload."""
    for sc in scopes:
        for g in sc["groups"]:
            for s in g["sessions"]:
                if s["name"] == name:
                    return sc["key"], g["key"], s
    raise AssertionError(f"{name} is not listed")


def test_a_fork_sits_in_its_origins_group(tmp_path):
    record(tmp_path, "example-lamp-share-side-drift42", "fork", origin="example-lamp-share", project="projects/gbrain")
    live = [sess("example-lamp-main"), sess("example-lamp-share"), sess("example-lamp-share-side-drift42")]
    scopes = S.group_sessions(live, ROLES, S.side_records(tmp_path))
    scope, group, s = where(scopes, "example-lamp-share-side-drift42")
    assert (scope, group) == ("example", "projects/gbrain")
    assert [x["name"] for x in scopes[0]["groups"][0]["sessions"]] == [
        "example-lamp-main", "example-lamp-share", "example-lamp-share-side-drift42"]   # after the agents: it has no role
    assert s["role"] is None and s["project"] == "projects/gbrain"
    assert s["side"] == {"kind": "fork", "origin": "example-lamp-share", "item": "board#41"}   # still marked as a side session
    assert "side" not in where(scopes, "example-lamp-main")[2]
    assert not any(sc["key"] == "Unregistered" for sc in scopes)


def test_a_fork_follows_where_its_origin_is_now_not_the_project_the_record_kept(tmp_path):
    record(tmp_path, "gamma-harbor-main-side-wren42", "fork", origin="gamma-harbor-main", project="projects/old-page")
    scopes = S.group_sessions([sess("gamma-harbor-main"), sess("gamma-harbor-main-side-wren42")], ROLES, S.side_records(tmp_path))
    assert where(scopes, "gamma-harbor-main-side-wren42")[:2] == ("gamma", "projects/harbor-room-b")


def test_a_fork_whose_origin_is_gone_takes_the_project_its_record_kept(tmp_path):
    record(tmp_path, "example-lamp-share-side-drift42", "fork", origin="example-lamp-share", project="projects/gbrain")
    scopes = S.group_sessions([sess("example-lamp-share-side-drift42")], {}, S.side_records(tmp_path))
    assert where(scopes, "example-lamp-share-side-drift42")[:2] == ("example", "projects/gbrain")


def test_a_fork_of_a_fork_follows_the_chain_to_the_agent(tmp_path):
    record(tmp_path, "example-lamp-share-side-wren01", "fork", origin="example-lamp-share")   # the record kept no project
    record(tmp_path, "example-lamp-share-side-oak02", "fork", origin="example-lamp-share-side-wren01")
    live = [sess("example-lamp-share"), sess("example-lamp-share-side-wren01"), sess("example-lamp-share-side-oak02")]
    scopes = S.group_sessions(live, ROLES, S.side_records(tmp_path))
    assert where(scopes, "example-lamp-share-side-wren01")[:2] == ("example", "projects/gbrain")
    assert where(scopes, "example-lamp-share-side-oak02")[:2] == ("example", "projects/gbrain")


def test_a_discuss_session_sits_in_the_project_of_its_item(tmp_path):
    record(tmp_path, "gamma-harbor-side-onyx07", "discuss", project="projects/harbor-room-b", item="board#38")
    live = [sess("gamma-harbor-main"), sess("gamma-harbor-side-onyx07")]
    scopes = S.group_sessions(live, ROLES, S.side_records(tmp_path))
    scope, group, s = where(scopes, "gamma-harbor-side-onyx07")
    assert (scope, group) == ("gamma", "projects/harbor-room-b")
    assert s["role"] is None and s["side"]["kind"] == "discuss" and s["side"]["item"] == "board#38"


def test_a_discuss_session_of_a_project_with_no_other_live_session_makes_the_group(tmp_path):
    record(tmp_path, "example-demo-side-wren42", "discuss", project="projects/salamander")
    scopes = S.group_sessions([sess("example-demo-side-wren42")], {}, S.side_records(tmp_path))
    assert where(scopes, "example-demo-side-wren42")[:2] == ("example", "projects/salamander")


def test_no_record_stays_unregistered(tmp_path):
    scopes = S.group_sessions([sess("example-lamp-share-side-drift42")], ROLES, S.side_records(tmp_path))
    assert where(scopes, "example-lamp-share-side-drift42")[:2] == ("Unregistered", "Unregistered")
    assert "side" not in where(scopes, "example-lamp-share-side-drift42")[2]
    assert S.side_records(tmp_path / "no-such-dir") == {} and S.side_records(None) == {}


def test_a_record_that_leads_to_no_project_stays_unregistered_but_is_marked(tmp_path):
    record(tmp_path, "example-x-side-wren01", "fork", origin="example-unlisted")             # the origin is on no page
    record(tmp_path, "example-x-side-oak02", "fork", origin="")                           # no origin at all
    record(tmp_path, "example-x-side-elm03", "discuss", project="")                       # a discuss session with no project
    record(tmp_path, "example-x-side-d04", "fork", origin="example-x-side-e05")           # a loop of forks
    record(tmp_path, "example-x-side-e05", "fork", origin="example-x-side-d04")
    (tmp_path / "junk.side").write_text("not a record\n")
    names = ["example-x-side-wren01", "example-x-side-oak02", "example-x-side-elm03", "example-x-side-d04", "example-x-side-e05"]
    scopes = S.group_sessions([sess(n) for n in names], ROLES, S.side_records(tmp_path))
    for n in names:
        assert where(scopes, n)[:2] == ("Unregistered", "Unregistered"), n
    assert where(scopes, "example-x-side-wren01")[2]["side"]["kind"] == "fork"


def test_a_session_stackshot_knows_keeps_its_own_project_and_role(tmp_path):
    record(tmp_path, "example-lamp-main", "fork", origin="gamma-harbor-main")   # an odd record for a listed agent
    scopes = S.group_sessions([sess("example-lamp-main")], ROLES, S.side_records(tmp_path))
    scope, group, s = where(scopes, "example-lamp-main")
    assert (scope, group, s["role"]) == ("example", "projects/gbrain", "front")


def test_the_overview_rows_group_the_same_way(tmp_path):
    record(tmp_path, "example-lamp-share-side-drift42", "fork", origin="example-lamp-share")
    record(tmp_path, "gamma-harbor-side-onyx07", "discuss", project="projects/harbor-room-b")
    live = [sess("scratch-1"), sess("gamma-harbor-side-onyx07"), sess("example-lamp-share-side-drift42"), sess("example-lamp-share")]
    rows = {r["name"]: r for r in S.overview_rows(live, ROLES, S.side_records(tmp_path))}
    assert (rows["example-lamp-share-side-drift42"]["scope"], rows["example-lamp-share-side-drift42"]["project"],
            rows["example-lamp-share-side-drift42"]["projectTitle"]) == ("example", "projects/gbrain", "gbrain")
    assert rows["gamma-harbor-side-onyx07"]["scope"] == "gamma" and rows["gamma-harbor-side-onyx07"]["role"] is None
    assert rows["scratch-1"]["scope"] == "Unregistered"
    assert [r["name"] for r in S.overview_rows(live, ROLES, S.side_records(tmp_path))].index("example-lamp-share") < \
        [r["name"] for r in S.overview_rows(live, ROLES, S.side_records(tmp_path))].index("example-lamp-share-side-drift42")


def test_the_endpoints_read_the_record_from_salas_state_directory(tmp_path, monkeypatch):
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    (claude / "projects").mkdir()
    state = tmp_path / "sala-state"
    record(state / "side", "example-lamp-share-side-drift42", "fork", origin="example-lamp-share")
    (claude / "sessions" / "a.json").write_text(json.dumps(
        {"pid": os.getpid(), "sessionId": "sid-a", "name": "example-lamp-share-side-drift42", "cwd": "/tmp", "status": "idle"}))
    monkeypatch.setattr(S, "proc_lane", lambda p: "subscription-1")
    monkeypatch.setattr(S, "launch_flags", lambda p: {})
    monkeypatch.setattr(S, "live_tmux_names", lambda: {})
    monkeypatch.setattr(S, "model_env", lambda p: {})
    monkeypatch.setattr(S.CatalogCache, "for_pid", lambda self, p: {})
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude, sala_state_dir=state,
                        tmux_socket_name="salaweb-pytest-unused", sala_models=tmp_path / "models.tsv",
                        roles_cmd=["echo", json.dumps({"sessions": {"example-lamp-share": {"role": "back", "project": "projects/gbrain"}}})])
    c = TestClient(create_app(settings))
    body = c.get("/api/sessions").json()
    assert [g["key"] for g in body["groups"]] == ["projects/gbrain"]
    assert body["groups"][0]["sessions"][0]["side"]["origin"] == "example-lamp-share"
    (row,) = c.get("/api/overview").json()["sessions"]
    assert row["scope"] == "example" and row["project"] == "projects/gbrain"
    # without the record: Unregistered, as before
    (state / "side" / "example-lamp-share-side-drift42.side").unlink()
    assert [g["key"] for g in c.get("/api/sessions").json()["groups"]] == ["Unregistered"]
    assert c.get("/api/overview").json()["sessions"][0]["scope"] == "Unregistered"
