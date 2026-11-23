"""A sleeping session's Agents row says the lane and the model its wake will start, never "unknown" and never a model with no version.

A sleeper has no process, so the page cannot read a lane or a launch line from one. It asks sala (`sala sleep --list --json`, lib/sleep.sh), which answers
with the lane (`lane_for_session`: the lanes.tsv row, else the pin, else the default) and the model, effort and lane model ids read off the line `resume_cmd`
builds, the line a wake types; the page then resolves the model family to a version as the CLI does on that lane: the lane's own ANTHROPIC_DEFAULT_<ALIAS>_MODEL
id when it pins one, else the catalog of the `claude` that a wake starts. No rule of sala's is copied here.

What a wrong answer costs: a sleeper that reads "unknown" in the Lane column or "version unknown" in the Model column (the owner cannot tell where it will wake),
a lane or model of the wrong session, a sala run on every 10 s poll (it reads each sleeper's transcript), a sala that is missing or old taking the whole
Overview down, or the plan of a session that is awake replacing what it runs. Held here: the reading of sala's answer, the rows the Overview endpoint
builds for a sleeper (lane, a model pinned by the lane, a model from the catalog), sala asked once for several polls and never when nothing sleeps, a sala that fails or prints
something else leaving the rows as before, and a live session's row untouched. `sala` is a stand-in script in tmp_path; the `claude` is a file with a catalog in it.
"""

from __future__ import annotations

import json
import os
import stat
import sys

import pytest
from starlette.testclient import TestClient

from sala_web import sessions as S
from sala_web.app import create_app
from sala_web.config import Settings
from test_overview import REAL_CATALOG, fake_binary

NAME = "demo-sleeper"
UUID = "7e0b1d52-0a6c-4f1e-9d77-5b1c3a2f9e10"
LIVE_UUID = "c0ffee00-0000-4000-8000-0000000000aa"
SINCE = "2026-11-22T06:10:00Z"
PIN_OPUS = "global.anthropic.claude-opus-5-5"

STUB = r'''#!@@PY@@
"""pytest's stand-in for sala (web/tests/test_wake_plan.py): records its argv; `sleep --list --json` prints the plan the test wrote."""
import json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(HERE, "record.jsonl"), "a", encoding="utf-8") as f:
    f.write(json.dumps(sys.argv[1:]) + "\n")
if sys.argv[1:] == ["sleep", "--list", "--json"]:
    try:
        sys.stdout.write(open(os.path.join(HERE, "plan.txt"), encoding="utf-8").read())
    except OSError:
        sys.exit(1)
'''


class World:
    def __init__(self, tmp_path):
        self.tmp = tmp_path
        self.dir = tmp_path / "bin"
        self.dir.mkdir()
        self.cmd = self.dir / "sala"
        self.cmd.write_text(STUB.replace("@@PY@@", sys.executable))
        self.cmd.chmod(self.cmd.stat().st_mode | stat.S_IXUSR)
        self.state = tmp_path / "sala-state"
        (self.state / "sleeping").mkdir(parents=True)
        self.state.joinpath("pane-map.tsv").write_text("")
        self.claude = tmp_path / "claude"
        (self.claude / "sessions").mkdir(parents=True)
        (self.claude / "projects").mkdir()

    def sleeper(self, name: str = NAME, uuid: str = UUID) -> None:
        (self.state / "sleeping" / uuid).write_text(f"{SINCE} {name}\n")
        with (self.state / "pane-map.tsv").open("a", encoding="utf-8") as f:
            f.write(f"{name}\t{uuid}\t{name}\t/w/work-a\n")

    def plan(self, *entries: dict) -> None:
        (self.dir / "plan.txt").write_text(json.dumps(list(entries)))

    def plan_text(self, text: str) -> None:
        (self.dir / "plan.txt").write_text(text)

    def asked(self) -> list[list[str]]:
        p = self.dir / "record.jsonl"
        return [json.loads(l) for l in p.read_text(encoding="utf-8").splitlines()] if p.exists() else []

    def settings(self, live: list[dict] | None = None) -> Settings:
        for d in live or []:
            (self.claude / "sessions" / f"{d['pid']}.json").write_text(json.dumps(d))
        return Settings(socket=self.tmp / "s.sock", state_dir=self.tmp / "state", claude_dir=self.claude, tmux_socket_name="salaweb-pytest-unused",
                        roles_cmd=["false"], sala_cmd=[str(self.cmd)], sala_state_dir=self.state, sala_models=self.tmp / "none.tsv")

    def overview(self, live: list[dict] | None = None) -> dict[str, dict]:
        c = TestClient(create_app(self.settings(live)))
        return {r["name"]: r for r in c.get("/api/overview").json()["sessions"]}


@pytest.fixture
def world(tmp_path, monkeypatch) -> World:
    monkeypatch.setattr(S, "live_tmux_names", lambda: {})
    monkeypatch.setattr(S, "proc_lane", lambda _pid: "subscription-1")
    monkeypatch.delenv("SALA_SLEEP_DIR", raising=False)
    monkeypatch.delenv("SALA_SIDECAR", raising=False)
    monkeypatch.setenv("SALA_CONFIG", str(tmp_path / "no-sala-config"))
    monkeypatch.setenv("SALA_WEB_SALA_STATE", str(tmp_path / "sala-state"))
    monkeypatch.setenv("HOME", str(tmp_path / "home"))                         # no ~/.local/bin/claude of this machine
    monkeypatch.setenv("PATH", str(tmp_path / "nobin"))                        # and none on the PATH unless a test puts one there
    return World(tmp_path)


def put_claude_on_path(world: World, monkeypatch) -> None:
    d = world.tmp / "pathbin"
    d.mkdir()
    (fake_binary(d / "claude", REAL_CATALOG)).chmod(0o755)   # `which` finds executables only
    monkeypatch.setenv("PATH", str(d))


def live_row(pid: int, name: str, sid: str) -> dict:
    return {"pid": pid, "sessionId": sid, "name": name, "cwd": "/w/live-a", "status": "idle", "tmux": f"{name}:@1.%1", "procStart": S.proc_start(pid)}


# ── the reading of sala's answer ────────────────────────────────────────────────────────────────────────────
def test_parse_wake_plans_reads_the_list_and_nothing_else():
    ok = {"name": "a", "conversation": UUID, "since": SINCE, "lane": "aws-platform", "model": "opus", "effort": "high",
          "env": {"ANTHROPIC_DEFAULT_OPUS_MODEL": PIN_OPUS, "ANTHROPIC_DEFAULT_SONNET_MODEL": "", "AWS_PROFILE": "x"}}
    got = S.parse_wake_plans(json.dumps([ok, {"name": "b", "lane": None, "model": None, "effort": None, "env": {}}, {"lane": "api"}, "junk", {"name": ""}]))
    assert got == {"a": {"lane": "aws-platform", "model": "opus", "effort": "high", "env": {"opus": PIN_OPUS}},
                   "b": {"lane": None, "model": None, "effort": None, "env": {}}}
    for text in ("", "not json", "{}", "null", "sala-test-s\tasleep since Sun\t(conversation x)\n", '{"name": "a"}'):
        assert S.parse_wake_plans(text) == {}, text


# ── the rows ────────────────────────────────────────────────────────────────────────────────────────────────
def test_a_sleeper_shows_the_lane_and_the_model_its_wake_gives_it_with_a_version(world, monkeypatch):
    """A lane that pins a model id (the AWS lanes): the version is that id; the lane is sala's answer, not "unknown"."""
    world.sleeper()
    world.plan({"name": NAME, "conversation": UUID, "since": SINCE, "lane": "aws-platform", "model": "opus", "effort": "high",
                "env": {"ANTHROPIC_DEFAULT_OPUS_MODEL": PIN_OPUS}})
    r = world.overview()[NAME]
    assert r["status"] == "sleeping" and r["sleeping"] == SINCE and r["pid"] == 0
    assert r["lane"] == "aws-platform"
    assert r["model"] == "claude-opus-5-5" and r["modelAlias"]["via"] == "env" and r["effort"] == "high", r
    assert world.asked() == [["sleep", "--list", "--json"]]


def test_a_sleeper_on_a_lane_with_no_pin_takes_the_version_from_the_catalog_of_the_claude_a_wake_starts(world, monkeypatch):
    put_claude_on_path(world, monkeypatch)
    world.sleeper()
    world.plan({"name": NAME, "conversation": UUID, "since": SINCE, "lane": "subscription-2", "model": "sonnet", "effort": None, "env": {}})
    r = world.overview()[NAME]
    assert r["lane"] == "subscription-2" and r["model"] == "claude-sonnet-5-5", r
    assert r["modelAlias"]["via"] == "catalog" and r["modelAlias"]["name"] == "sonnet"
    assert "version unknown" not in json.dumps(r)


def test_a_model_named_with_its_version_is_kept_and_the_lane_is_the_plans(world):
    world.sleeper()
    world.plan({"name": NAME, "conversation": UUID, "since": SINCE, "lane": "bedrock", "model": "claude-opus-4-6", "effort": "low", "env": {}})
    r = world.overview()[NAME]
    assert (r["lane"], r["model"], r["effort"], r["modelAlias"]) == ("bedrock", "claude-opus-4-6", "low", None), r


def test_sala_is_asked_once_for_many_polls_and_not_at_all_when_nothing_sleeps(world):
    world.sleeper()
    world.plan({"name": NAME, "conversation": UUID, "since": SINCE, "lane": "api", "model": "opus", "effort": None, "env": {}})
    c = TestClient(create_app(world.settings()))
    for _ in range(4):
        assert c.get("/api/overview").status_code == 200
    assert world.asked() == [["sleep", "--list", "--json"]]                    # the answer is kept for a while
    (world.state / "sleeping" / UUID).unlink()
    quiet = World.__new__(World)
    quiet.__dict__.update(world.__dict__)
    before = len(world.asked())
    TestClient(create_app(quiet.settings())).get("/api/overview")
    assert len(world.asked()) == before                                         # no sleeper: sala is not run


def test_a_sala_that_fails_or_cannot_say_leaves_the_rows_as_they_were(world):
    world.sleeper()
    for text in (None, "not json at all", "[]"):
        if text is None:
            (world.dir / "plan.txt").unlink(missing_ok=True)                    # the stub exits 1
        else:
            world.plan_text(text)
        r = world.overview()[NAME]
        assert r["status"] == "sleeping" and r["sleeping"] == SINCE and r["lane"] is None, (text, r)   # nothing to say: as before, no error


def test_a_live_session_is_not_changed_by_a_plan_that_names_it(world):
    world.sleeper()
    world.plan({"name": "demo-live", "conversation": LIVE_UUID, "since": SINCE, "lane": "bedrock", "model": "haiku", "effort": None, "env": {}},
               {"name": NAME, "conversation": UUID, "since": SINCE, "lane": "subscription-1", "model": "opus", "effort": None, "env": {}})
    rows = world.overview([live_row(os.getpid(), "demo-live", LIVE_UUID)])
    assert rows["demo-live"]["lane"] == "subscription-1" and rows["demo-live"]["status"] == "idle" and "sleeping" not in rows["demo-live"]
    assert rows[NAME]["lane"] == "subscription-1"
