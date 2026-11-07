"""Which pages are projects: the sidebar's groups read the pages' `type` field and nothing else.

A group exists only for a page whose frontmatter `type` is `project`. A session whose agents map sits on a sub-page or a note page
(`projects/a/b`, whose type is not project) is grouped under the nearest parent by slug prefix that is a project (`projects/a`);
a session with no such page on the way stays in Unregistered. Without a pages checkout to read there is no `type` to go by, and
the groups are the roles' projects as stackshot names them.

What a wrong answer costs: a note page or a sub-page growing a group of its own in the sidebar, next to the project it belongs to;
a session of a project vanishing into Unregistered because its page is read for the wrong key; the sidebar and the overview
(which reads the same groups) disagreeing; a missing pages checkout emptying every group."""

from __future__ import annotations

import asyncio
import json
import os
import time
import types

from starlette.testclient import TestClient

from sala_web import sessions as S
from sala_web import spawn as SP
from sala_web.app import create_app
from sala_web.config import Settings

TYPES = {
    "projects/stackshot": "project",
    "projects/stackshot/demo-guide": "reference",
    "projects/stackshot/demo-states/demo-model": "note",
    "projects/gbrain": "project",
    "projects/gbrain-notes": "note",
    "projects/untyped": "",
    "projects/harbor": "project",
}

ROLES = {
    "example-board-main": {"role": "front", "project": "projects/stackshot"},
    "example-board-docs": {"role": "back", "project": "projects/stackshot/demo-guide"},
    "example-board-deep": {"role": "back", "project": "projects/stackshot/demo-states/demo-model"},
    "example-lamp-main": {"role": "front", "project": "projects/gbrain"},
    "example-lamp-notes": {"role": "back", "project": "projects/gbrain-notes"},       # a note page with agents: no group of its own
    "example-loose-main": {"role": "front", "project": "projects/untyped"},           # no `type` at all
    "example-ghost-main": {"role": "front", "project": "projects/not-in-the-mirror"},
    "gamma-harbor-main": {"role": "front", "project": "projects/harbor"},
}


def sess(name):
    return S.Session(pid=1, session_id=name, name=name, cwd="/tmp", status="idle", tmux="", lane="subscription-1")


def keys_of(scopes):
    return {s["name"]: g["key"] for sc in scopes for g in sc["groups"] for s in g["sessions"]}


def test_nearest_project_is_the_page_or_its_nearest_project_parent_by_slug_prefix():
    n = S.nearest_project
    assert n("projects/stackshot", TYPES) == "projects/stackshot"
    assert n("projects/stackshot/demo-guide", TYPES) == "projects/stackshot"
    assert n("projects/stackshot/demo-states/demo-model", TYPES) == "projects/stackshot"          # two levels up
    assert n("projects/gbrain-notes", TYPES) is None                                               # a note: not a prefix match on gbrain
    assert n("projects/untyped", TYPES) is None and n("projects/not-in-the-mirror", TYPES) is None
    assert n("projects", TYPES) is None and n("", TYPES) is None
    # the nearest wins, not the topmost
    assert n("projects/a/b/c", {"projects/a": "project", "projects/a/b": "project"}) == "projects/a/b"
    # the directory alone is no page, whatever it is called
    assert n("projects/a", {"projects": "project"}) is None


def test_a_group_exists_only_for_a_type_project_page_and_sub_pages_roll_up():
    live = [sess(n) for n in ROLES] + [sess("example-nobody")]
    scopes = S.group_sessions(live, ROLES, types=TYPES)
    where = keys_of(scopes)
    assert where["example-board-main"] == where["example-board-docs"] == where["example-board-deep"] == "projects/stackshot"
    assert where["example-lamp-main"] == "projects/gbrain" and where["gamma-harbor-main"] == "projects/harbor"
    # a page with agents but no type project gets no group; its sessions are Unregistered, as is a page the mirror lacks
    assert where["example-lamp-notes"] == where["example-loose-main"] == where["example-ghost-main"] == where["example-nobody"] == "Unregistered"
    groups = {g["key"] for sc in scopes for g in sc["groups"]}
    assert groups == {"projects/stackshot", "projects/gbrain", "projects/harbor", "Unregistered"}
    board = next(g for sc in scopes for g in sc["groups"] if g["key"] == "projects/stackshot")
    assert [s["name"] for s in board["sessions"]] == ["example-board-main", "example-board-deep", "example-board-docs"]   # front first, then by name
    assert {s["project"] for s in board["sessions"]} == {"projects/stackshot"}          # the session's own project is the group's


def test_without_types_the_roles_projects_are_the_groups():
    live = [sess(n) for n in ROLES]
    where = keys_of(S.group_sessions(live, ROLES))
    assert where["example-lamp-notes"] == "projects/gbrain-notes" and where["example-board-docs"] == "projects/stackshot/demo-guide"


def test_a_side_session_rolls_up_with_the_group_it_is_put_in():
    record = {"example-board-side-x1": {"kind": "discuss", "origin": "", "project": "projects/stackshot/demo-guide", "item": "board#9001"},
              "example-lamp-side-y2": {"kind": "fork", "origin": "example-board-docs", "project": "", "item": ""}}
    live = [sess("example-board-docs"), sess("example-board-side-x1"), sess("example-lamp-side-y2")]
    where = keys_of(S.group_sessions(live, ROLES, record, TYPES))
    assert where == {"example-board-docs": "projects/stackshot", "example-board-side-x1": "projects/stackshot", "example-lamp-side-y2": "projects/stackshot"}
    # a record that leads to a page that is no project (and has none above it) leaves the session in Unregistered
    record = {"example-lamp-side-z3": {"kind": "discuss", "origin": "", "project": "projects/gbrain-notes", "item": "board#9002"}}
    assert keys_of(S.group_sessions([sess("example-lamp-side-z3")], ROLES, record, TYPES)) == {"example-lamp-side-z3": "Unregistered"}


def test_the_overview_rows_follow_the_same_groups():
    rows = {r["name"]: r for r in S.overview_rows([sess(n) for n in ROLES], ROLES, types=TYPES)}
    assert rows["example-board-deep"]["project"] == "projects/stackshot" and rows["example-board-deep"]["projectTitle"] == "stackshot"
    assert rows["example-lamp-notes"]["project"] is None and rows["example-lamp-notes"]["scope"] == "Unregistered"


# ── the pages' type, read from the pages checkout ───────────────────────────
def write_page(brain, key, text):
    f = brain / (key + ".md")
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(text, encoding="utf-8")


def make_brain(brain):
    write_page(brain, "projects/stackshot", "---\ntitle: stackshot\ntype: project\n---\n# stackshot\n")
    write_page(brain, "projects/stackshot/demo-guide", "---\ntitle: Sessions per project\ntype: reference\n---\n")
    write_page(brain, "projects/stackshot/demo-states/demo-model", "---\ntitle: Item model\ntype: Note\n---\n")
    write_page(brain, "projects/gbrain", "---\ntitle: gbrain\ntype: \"project\"\n---\n")
    write_page(brain, "projects/untyped", "---\ntitle: Untyped\n---\n")
    write_page(brain, "projects/bare", "no frontmatter at all\n")
    write_page(brain, "projects/old-name", "---\ntitle: Old\ntype: redirect\nto: projects/gbrain\n---\n")
    write_page(brain, "projects/README", "---\ntype: project\n---\n")
    write_page(brain, "notes/elsewhere", "---\ntype: project\n---\n")      # not under a page directory


def test_page_types_reads_the_type_field_of_every_page_under_the_page_directories(tmp_path):
    brain = tmp_path / "brain"
    make_brain(brain)
    t = SP.page_types(brain, ["projects"])
    assert t == {"projects/stackshot": "project", "projects/stackshot/demo-guide": "reference",
                 "projects/stackshot/demo-states/demo-model": "note", "projects/gbrain": "project",
                 "projects/untyped": "", "projects/bare": "", "projects/old-name": "redirect"}
    # the project list the form's spawn step uses is unchanged by it: a redirect stub is still not a page
    assert "projects/old-name" not in [p["key"] for p in SP.list_pages(brain, ["projects"])]


def test_the_pages_cache_gives_the_types_and_none_without_a_checkout(tmp_path):
    brain = tmp_path / "brain"
    make_brain(brain)
    cache = SP.PagesCache(brain, ["projects"])
    types = asyncio.run(cache.types())
    assert types["projects/stackshot"] == "project" and types["projects/stackshot/demo-guide"] == "reference"
    assert [p["key"] for p in asyncio.run(cache.get())][0] == "projects/bare"
    gone = SP.PagesCache(tmp_path / "missing", ["projects"])
    assert asyncio.run(gone.types()) is None and "no pages checkout" in (gone.error or "")
    assert asyncio.run(SP.PagesCache(None, ["projects"]).types()) is None


def test_the_pages_cache_reads_on_its_first_ask_even_just_after_the_machine_booted(tmp_path, monkeypatch):
    """time.monotonic() counts from the machine's boot, so a "not read yet" marker of 0.0 looked like a read a moment ago for
    the first PAGES_TTL seconds of the machine's life, and the form's first ask in that window got an empty project list (a
    CI runner that starts its job seconds after it boots hit this). The clock is set to 5 s of uptime here; nothing is slept."""
    brain = tmp_path / "brain"
    make_brain(brain)
    monkeypatch.setattr(SP, "time", types.SimpleNamespace(monotonic=lambda: 5.0, time=time.time))
    cache = SP.PagesCache(brain, ["projects"])
    keys = [p["key"] for p in asyncio.run(cache.get())]
    assert keys and keys[0] == "projects/bare" and cache.error is None, (keys, cache.error)
    (brain / "projects" / "added-later.md").write_text("---\ntitle: Added\ntype: project\n---\n")
    assert [p["key"] for p in asyncio.run(cache.get())] == keys   # a second ask inside the TTL still reuses the read


# ── the endpoints ────────────────────────────────────────────────────────────
def app_client(tmp_path, monkeypatch, roles, brain):
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    (claude / "projects").mkdir()
    for i, name in enumerate(roles):
        (claude / "sessions" / f"{i}.json").write_text(json.dumps(
            {"pid": os.getpid(), "sessionId": f"sid-{i}", "name": name, "cwd": "/tmp", "status": "idle"}))
    monkeypatch.setattr(S, "proc_lane", lambda p: "subscription-1")
    monkeypatch.setattr(S, "launch_flags", lambda p: {})
    monkeypatch.setattr(S, "live_tmux_names", lambda: {})
    monkeypatch.setattr(S, "model_env", lambda p: {})
    monkeypatch.setattr(S.CatalogCache, "for_pid", lambda self, p: {})
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude, sala_state_dir=tmp_path / "sala-state",
                        tmux_socket_name="salaweb-pytest-unused", sala_models=tmp_path / "models.tsv", brain_dir=brain, page_dirs=["projects"],
                        roles_cmd=["echo", json.dumps({"sessions": roles})])
    return TestClient(create_app(settings))


def test_the_sidebar_and_the_overview_group_by_the_pages_type(tmp_path, monkeypatch):
    brain = tmp_path / "brain"
    make_brain(brain)
    roles = {"example-board-main": {"role": "front", "project": "projects/stackshot"},
             "example-board-docs": {"role": "back", "project": "projects/stackshot/demo-guide"},
             "example-lamp-main": {"role": "front", "project": "projects/gbrain"},
             "example-loose-main": {"role": "front", "project": "projects/untyped"}}
    c = app_client(tmp_path, monkeypatch, roles, brain)
    body = c.get("/api/sessions").json()
    assert sorted(g["key"] for g in body["groups"]) == ["Unregistered", "projects/gbrain", "projects/stackshot"]
    stack = next(g for g in body["groups"] if g["key"] == "projects/stackshot")
    assert [s["name"] for s in stack["sessions"]] == ["example-board-main", "example-board-docs"]
    rows = {r["name"]: r for r in c.get("/api/overview").json()["sessions"]}
    assert rows["example-board-docs"]["project"] == "projects/stackshot" and rows["example-loose-main"]["scope"] == "Unregistered"


def test_without_a_pages_checkout_the_groups_are_the_roles_projects(tmp_path, monkeypatch):
    roles = {"example-lamp-notes": {"role": "back", "project": "projects/gbrain-notes"}}
    c = app_client(tmp_path, monkeypatch, roles, None)
    assert [g["key"] for g in c.get("/api/sessions").json()["groups"]] == ["projects/gbrain-notes"]
