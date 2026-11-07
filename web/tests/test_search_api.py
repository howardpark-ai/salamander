"""GET /api/search (app.py get_search over search.py): the query, the range and the switches in, the matches out.

What a wrong answer costs: a request that makes the server read a file the client named, a bad range or query that gets a trace instead of
a sentence, a search that never says it was cut, or a read that changes anything. The route sits in the same app as every other /api
route (sala-web has no login of its own: it listens on a unix socket behind the Access app), so there is no second door to test.

The tree of fake transcripts and the temporary folder it lives in (locked while the test runs, removed when it ends) are
test_search.py's; here the clock is the real one, so each entry is written relative to now.
"""

from __future__ import annotations

import json
import sys
import time

import pytest
from starlette.testclient import TestClient

import test_search as T
from test_search import tree  # noqa: F401  (the fixture)
from sala_web import app as APP
from sala_web.app import create_app
from sala_web.config import Settings


@pytest.fixture
def api(tree, monkeypatch):  # noqa: F811
    monkeypatch.setattr(T, "NOW", time.time())
    claude = tree.root / "claude"
    claude.mkdir()
    (claude / "projects").symlink_to(tree.projects)
    state = tree.root / "sala-state"
    state.mkdir()
    (state / "sessions.json").write_text(tree.registry.read_text())
    roles = {"sessions": {"alpha-builder": {"role": "back", "project": "projects/alpha"}}}
    settings = Settings(socket=tree.root / "s.sock", state_dir=tree.root / "state", claude_dir=claude, sala_state_dir=state,
                        tmux_socket_name="salaweb-pytest-unused", roles_cmd=[sys.executable, "-c", f"print({json.dumps(roles)!r})"])
    tree.write(T.SID_FRONT, T.text("user", "needle in a message", 1, "m") + T.tool_out("needle in output", 1, "o")
               + T.text("user", "needle five hours ago", 5, "old"))
    tree.write(T.SID_BACK, T.text("assistant", "needle from the builder", 0.5, "b"))
    tree.write(T.SID_FRONT, T.text("assistant", "needle from a subagent", 0.2, "s"), sub="aa11")
    return TestClient(create_app(settings)), tree


def test_a_search_answers_with_the_matches_and_no_transcript(api):
    client, tree = api
    r = client.get("/api/search", params={"q": "NEEDLE"})
    assert r.status_code == 200 and r.headers["cache-control"] == "no-store"
    d = r.json()
    assert [x["uuid"] for x in d["results"]] == ["s", "b", "m", "old"]                  # newest first; the 5 h one is in the 24 h default range
    assert d["words"] == ["needle"] and d["capped"] is False and d["timedOut"] is False and d["cap"] == 200
    assert d["tzLabel"] == "+04" and d["fromText"].endswith("+04") and d["toText"].endswith("+04")
    by = {x["uuid"]: x for x in d["results"]}
    assert (by["m"]["role"], by["m"]["name"], by["m"]["agent"]) == ("front", "alpha-main", T.R_FRONT)
    assert (by["b"]["role"], by["b"]["name"]) == ("back", "alpha-builder")             # the row has no role; stackshot's answer fills it
    assert (by["s"]["sub"], by["s"]["agent"]) == (True, T.R_FRONT)
    assert set(by["m"]) == {"agent", "name", "role", "sub", "kind", "tool", "session", "uuid", "ts", "snippet", "when", "at", "pos", "target"}
    assert len(json.dumps(d)) < 5000                                                    # a few snippets, never the files


def test_the_switches_default_to_messages_and_tool_calls_and_the_counts_show_what_the_rest_hold(api):
    client, _ = api
    d = client.get("/api/search", params={"q": "needle"}).json()
    assert "o" not in {x["uuid"] for x in d["results"]}
    assert d["counts"]["content"]["output"] == 1 and d["counts"]["agents"] == {"front": 2, "back": 1, "sub": 1, "unknown": 0}
    d = client.get("/api/search", params={"q": "needle", "output": "1"}).json()
    assert "o" in {x["uuid"] for x in d["results"]}
    d = client.get("/api/search", params={"q": "needle", "front": "0", "sub": "0"}).json()
    assert [x["uuid"] for x in d["results"]] == ["b"]
    d = client.get("/api/search", params={"q": "needle", "messages": "0", "tools": "0"}).json()
    assert d["results"] == [] and d["matches"] == 0 and d["counts"]["content"]["messages"] == 4


def test_the_range_is_hours_or_dates(api):
    client, _ = api
    assert {x["uuid"] for x in client.get("/api/search", params={"q": "needle", "hours": "2"}).json()["results"]} == {"m", "b", "s"}
    assert {x["uuid"] for x in client.get("/api/search", params={"q": "needle", "hours": "6"}).json()["results"]} == {"m", "b", "s", "old"}
    now = time.time()
    fmt = lambda t: time.strftime("%Y-%m-%dT%H:%M", time.gmtime(t + 4 * 3600))      # the tests run in Asia/Dubai (conftest)
    d = client.get("/api/search", params={"q": "needle", "from": fmt(now - 6 * 3600), "to": fmt(now - 4 * 3600)}).json()
    assert [x["uuid"] for x in d["results"]] == ["old"]
    d = client.get("/api/search", params={"q": "needle", "from": str(now - 6 * 3600), "to": str(now - 4 * 3600)}).json()
    assert [x["uuid"] for x in d["results"]] == ["old"]
    d = client.get("/api/search", params={"q": "needle", "from": fmt(now - 2 * 3600)}).json()     # no To: up to now
    assert {x["uuid"] for x in d["results"]} == {"m", "b", "s"}


@pytest.mark.parametrize("params", [
    {}, {"q": ""}, {"q": "   "}, {"q": "x" * 201}, {"q": " ".join("w%d" % i for i in range(9))},
    {"q": "a", "hours": "abc"}, {"q": "a", "hours": "0"}, {"q": "a", "hours": "-3"}, {"q": "a", "hours": "nan"}, {"q": "a", "hours": "inf"},
    {"q": "a", "hours": "9000"},
    {"q": "a", "from": "/etc/passwd"}, {"q": "a", "from": "../../x"}, {"q": "a", "to": "2026-11-01T09:00"},
    {"q": "a", "from": "2026-11-03T09:00", "to": "2026-11-01T09:00"}, {"q": "a", "from": "1", "to": "2000000000"},
])
def test_a_bad_request_is_a_400_with_a_sentence(api, params):
    client, _ = api
    r = client.get("/api/search", params=params)
    assert r.status_code == 400
    d = r.json()
    assert d["ok"] is False and d["error"].endswith(".") and "Traceback" not in d["error"]


def test_no_parameter_reaches_the_file_system(api):
    client, tree = api
    before = tree.digest()
    d = client.get("/api/search", params={"q": "root:x:0", "path": "/etc", "dir": "/etc", "file": "/etc/passwd", "projects": "/",
                                          "root": "/", "session": T.SID_FRONT, "../": "x"}).json()
    assert d["results"] == [] and d["files"]["all"] == 3                            # the three transcripts of the tree, whatever was named
    d = client.get("/api/search", params={"q": "../../etc/passwd"}).json()         # a query is words, not a path
    assert d["results"] == []
    assert tree.digest() == before                                             # and nothing was written


def test_a_third_search_is_refused_with_a_sentence(api, monkeypatch):
    monkeypatch.setattr(APP, "SEARCH_PARALLEL", 0)
    client = TestClient(create_app(api[0].app.state.settings))
    r = client.get("/api/search", params={"q": "needle"})
    assert r.status_code == 429 and r.json()["error"].endswith(".")


def test_the_route_is_a_get_in_the_same_app_as_the_other_api_routes(api):
    client, _ = api
    assert client.post("/api/search", json={"q": "needle"}).status_code == 405
    assert client.put("/api/search").status_code == 405
    routes = {r.path: r for r in client.app.routes}
    assert routes["/api/search"].methods >= {"GET"} and "POST" not in routes["/api/search"].methods
    assert "/api/schedules" in routes            # one app, one door: whatever fronts the others fronts this
