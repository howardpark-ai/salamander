"""The New session form's project step, server side (Sat Oct 24th 2026; projpick.py): the scope's project list, the
new project's job, the project listed again and the agent added to the project, all calls to stackshot's client API.

What a wrong answer costs here is a project, a page or an agent the owner did not ask for, or one he asked for that is not
made: a value that is not checked reaching stackshot (a shell character, a scope that is not one, a sender other than the
form's own label); a second page made by a double tap; a page made twice because a long call was cut off; a refusal lost on
the way or shown as a success; the token or the address of stackshot leaving the app. Every check guards one of those.
Nothing here reaches the real stackshot, a gbrain or the network: stackshot is a fake on 127.0.0.1 (fake_stackshot.py) that
the app reaches through two files in a temporary directory, exactly as it reaches the board; nothing runs sala."""

from __future__ import annotations

import json
import threading
import time

import pytest
from starlette.testclient import TestClient

from fake_stackshot import FakeStackshot, retired_rows
from sala_web import projpick as PP
from sala_web.app import create_app
from sala_web.config import Settings
from test_new_session import env, sala  # noqa: F401  (fixtures)


def wait_job(c, job: str, timeout: float = 10.0) -> dict:
    end = time.time() + timeout
    while time.time() < end:
        r = c.get("/api/spawn/project/job", params={"id": job})
        assert r.status_code == 200, r.text
        if r.json()["state"] == "done":
            return r.json()
        time.sleep(0.05)
    raise AssertionError("the job did not end")


# ── the list ─────────────────────────────────────────────────────────────────
def test_the_scopes_list_comes_from_stackshot_with_only_the_fields_the_form_uses(env):
    c, ss = env["client"], env["ss"]
    r = c.get("/api/spawn/projects", params={"scope": "gamma"})
    assert r.status_code == 200 and r.headers["cache-control"] == "no-store"
    d = r.json()
    assert d["ok"] and d["scope"] == "gamma" and d["scopes"] == ["beta", "gamma", "example"]
    assert [p["key"] for p in d["projects"]] == ["projects/gamma-harbor", "projects/gamma-pantry"]   # the listed ones, by key; no query, no hidden
    first = d["projects"][0]
    assert set(first) == {"id", "key", "title", "name", "type", "scope", "listed", "hidden", "keeper", "main", "agents"}
    assert first["agents"] == {"gamma-harbor-main": {"front": True, "role": "main"}}   # no mandate line, no page text
    assert ss.calls("/client/projects")[-1]["query"] == {"scope": "gamma"}
    # a query brings the scope's hidden matches too, marked hidden; stackshot also sends a note page, which the form drops
    d = c.get("/api/spawn/projects", params={"scope": "gamma", "q": "KAYAK"}).json()
    assert ss.calls("/client/projects")[-1]["query"] == {"scope": "gamma", "q": "KAYAK"}
    assert [(p["key"], p["hidden"], p["type"]) for p in d["projects"] if p["hidden"]] == [("projects/gamma-old-kayak", True, "project")]
    assert [p["key"] for p in d["projects"] if not p["hidden"]] == ["projects/gamma-harbor", "projects/gamma-pantry"]   # listed rows are not filtered by q here


@pytest.mark.parametrize("params", [{}, {"scope": ""}, {"scope": "ALL!"}, {"scope": "work"}, {"scope": "all;id"}, {"scope": "all,gamma"}, {"scope": "gamma; id"}, {"scope": "gamma", "q": "x" * 201},
                                    {"scope": "gamma", "q": "a\nb"}])
def test_a_bad_scope_or_query_is_refused_here_and_never_reaches_stackshot(env, params):
    r = env["client"].get("/api/spawn/projects", params=params)
    assert r.status_code == 400 and r.json()["ok"] is False, r.text
    assert env["ss"].requests == []


def test_all_is_a_scope_for_the_list_query_alone_and_its_rows_keep_their_own_scope(env):
    c, ss = env["client"], env["ss"]
    for given in ("all", " ALL "):    # the scope is trimmed and lowercased, as for the others
        d = c.get("/api/spawn/projects", params={"scope": given}).json()
        assert d["ok"] and d["scope"] == "all" and d["scopes"] == ["beta", "gamma", "example"], d   # `scopes` stays the three real ones
        assert ss.calls("/client/projects")[-1]["query"] == {"scope": "all"}
    listed = [(p["key"], p["scope"]) for p in d["projects"]]
    assert listed == sorted(listed) and {sc for _, sc in listed} == {"beta", "gamma", "example"} and len(listed) == 6, listed   # every scope's listed projects, by key
    assert all(not p["hidden"] for p in d["projects"])
    # with a query the hidden matches of every scope come too, marked hidden, each with its scope
    d = c.get("/api/spawn/projects", params={"scope": "all", "q": "pan"}).json()
    assert ss.calls("/client/projects")[-1]["query"] == {"scope": "all", "q": "pan"}
    assert [(p["key"], p["scope"]) for p in d["projects"] if p["hidden"]] == [("projects/gamma-pantry-2019", "gamma")]
    # stackshot answering `scopes` with "all" in it does not make a fourth real scope
    ss.projects_reply = (200, {"scope": "all", "q": "", "scopes": ["beta", "gamma", "example", "all"], "projects": []})
    assert c.get("/api/spawn/projects", params={"scope": "all"}).json()["scopes"] == ["beta", "gamma", "example"]


def test_all_is_never_the_scope_of_a_new_project_or_of_a_project_list(env):
    c, ss = env["client"], env["ss"]
    r = c.post("/api/spawn/project", json={**NEW, "scope": "all"})
    assert r.status_code == 400 and r.json()["error"].startswith("scope must be one of example, beta, gamma") and "all" not in r.json()["error"], r.text
    r = c.post("/api/spawn/project-list", json={"key": "projects/gamma-pantry", "scope": "all"})
    assert r.status_code == 400 and r.json()["ok"] is False, r.text
    assert PP.validate_new({**NEW, "scope": "all"}, ["projects", "infra"])[0] == 400
    assert PP.validate_list({"key": "projects/gamma-pantry", "scope": "all"}, ["projects", "infra"])[0] == 400
    assert PP.validate_query({"scope": "all"}) == ("all", "") and PP.validate_query({"scope": "gamma", "q": " x "}) == ("gamma", "x")
    assert ss.calls("/client/project") == [] and ss.calls("/client/project-list") == []


def test_retired_projects_are_dropped_when_stackshot_marks_them(env):
    """stackshot lists retired pages today and is being asked to stop. If it marks them (`retired: true`, or
    `status` archived or retired, any case), none reaches the page, listed or hidden; an unmarked row is still shown."""
    c, ss = env["client"], env["ss"]
    ss.rows += retired_rows()
    keys = lambda d: [p["key"] for p in d["projects"]]   # noqa: E731
    d = c.get("/api/spawn/projects", params={"scope": "all", "q": "gone"}).json()
    assert "projects/gamma-widget" in keys(d) and "projects/gamma-bench-blog" not in keys(d)
    assert not {"projects/beta-old-web", "projects/example-gone", "projects/gamma-hidden-gone"} & set(keys(d)), keys(d)
    for scope, gone in (("gamma", "projects/gamma-bench-blog"), ("beta", "projects/beta-old-web"), ("example", "projects/example-gone")):
        assert gone not in keys(c.get("/api/spawn/projects", params={"scope": scope}).json())
    assert keys(c.get("/api/spawn/projects", params={"scope": "example"}).json()) == ["projects/demo", "projects/stackshot"]   # the rest as before
    # only a real mark counts: another status, a false mark, a string "true" are no reason to drop a row
    rows = [{"key": "projects/a", "type": "project", "status": "active"}, {"key": "projects/b", "type": "project", "retired": False}, {"key": "projects/c", "type": "project", "status": None},
            {"key": "projects/d", "type": "project", "status": " Archived "}, {"key": "projects/e", "type": "project", "retired": "true"}]
    assert [p["key"] for p in PP.clean_projects({"projects": rows})["projects"]] == ["projects/a", "projects/b", "projects/c", "projects/e"]


def test_stackshots_failures_reach_the_page_in_plain_words_without_the_token_or_the_address(env, tmp_path):
    c, ss = env["client"], env["ss"]
    ss.projects_reply = (503, {"error": "the project record cannot be read right now: a damaged id file"})
    r = c.get("/api/spawn/projects", params={"scope": "gamma"})
    assert r.status_code == 503 and r.json()["code"] == "busy" and "damaged id file" in r.json()["error"]
    ss.projects_reply = (200, {"not": "a list"})
    r = c.get("/api/spawn/projects", params={"scope": "gamma"})
    assert r.status_code == 502 and "not the project list" in r.json()["error"]
    ss.projects_reply = (401, "unauthorized")
    r = c.get("/api/spawn/projects", params={"scope": "gamma"})
    assert r.status_code == 502 and r.json()["code"] == "refused" and "refused this machine's token" in r.json()["error"]
    ss.projects_reply = None
    # nothing listening: the reason is the network's, with no address in it
    ss.close()
    r = c.get("/api/spawn/projects", params={"scope": "gamma"})
    assert r.status_code == 502 and r.json()["code"] == "unreachable" and ss.url not in r.text and str(ss.server.server_address[1]) not in r.text
    # no token file on this machine
    settings = Settings(socket=tmp_path / "s9.sock", state_dir=tmp_path / "state9", claude_dir=env["settings"].claude_dir, tmux_socket_name="salaweb-pytest-unused",
                        roles_cmd=["false"], stackshot_token=tmp_path / "nowhere" / "client.token", stackshot_url=ss.url_file, **env["sala"].settings_kw())
    r = TestClient(create_app(settings)).get("/api/spawn/projects", params={"scope": "gamma"})
    assert r.status_code == 502 and r.json()["code"] == "config" and r.json()["error"] == "No stackshot token on this machine."


def test_the_token_goes_to_stackshot_as_a_bearer_and_nowhere_else(env):
    c, ss = env["client"], env["ss"]
    texts = [c.get("/api/spawn/projects", params={"scope": "gamma"}).text,
             c.post("/api/spawn/project-list", json={"key": "projects/gamma-pantry"}).text,
             c.get("/api/spawn/options").text]
    assert all(ss.token not in t for t in texts)
    assert ss.token not in json.dumps(ss.requests)   # the fake keeps what it was asked, never the header
    ss.token_file.write_text("wrong-token\n")        # a token stackshot does not know: 401, and the answer still carries neither
    r = c.get("/api/spawn/projects", params={"scope": "gamma"})
    assert r.status_code == 502 and r.json()["code"] == "refused" and "wrong-token" not in r.text


# ── a new project ────────────────────────────────────────────────────────────
NEW = {"key": "projects/fresh-idea", "scope": "beta", "title": "Fresh Idea"}


def test_a_new_project_is_a_job_the_page_asks_about_and_stackshot_gets_exactly_the_checked_values(env):
    c, ss = env["client"], env["ss"]
    ss.new_delay = 0.6
    r = c.post("/api/spawn/project", json=NEW)
    assert r.status_code == 202 and r.json()["ok"] and len(r.json()["job"]) == 16
    job = r.json()["job"]
    assert c.get("/api/spawn/project/job", params={"id": job}).json()["state"] == "running"   # the call is still on: the page waits
    done = wait_job(c, job)
    assert done["status"] == 200 and done["result"]["ok"] and done["result"]["key"] == "projects/fresh-idea" and done["result"]["created"] is True
    assert done["result"]["id"].startswith("prj_")
    (call,) = ss.calls("/client/project")
    assert call["body"] == {"key": "projects/fresh-idea", "scope": "beta", "title": "Fresh Idea", "sender": "sala-web"}   # the form's one label
    # the new project is in the scope's list now, listed
    keys = [p["key"] for p in c.get("/api/spawn/projects", params={"scope": "beta"}).json()["projects"]]
    assert "projects/fresh-idea" in keys
    # without a title the field is not sent; the answer stays for the page to read again
    r = c.post("/api/spawn/project", json={"key": "projects/another", "scope": "example"})
    wait_job(c, r.json()["job"])
    assert ss.calls("/client/project")[-1]["body"] == {"key": "projects/another", "scope": "example", "sender": "sala-web"}
    assert c.get("/api/spawn/project/job", params={"id": job}).json()["result"]["ok"]


def test_a_second_project_while_one_is_being_made_is_refused(env):
    c, ss = env["client"], env["ss"]
    ss.new_delay = 1.0
    job = c.post("/api/spawn/project", json=NEW).json()["job"]
    time.sleep(0.2)
    second = c.post("/api/spawn/project", json={**NEW, "key": "projects/other-idea"})
    assert second.status_code == 409 and second.json()["code"] == "busy", second.text
    wait_job(c, job)
    assert [x["body"]["key"] for x in ss.calls("/client/project")] == ["projects/fresh-idea"]   # one page, once
    third = c.post("/api/spawn/project", json={**NEW, "key": "projects/other-idea"})   # free again once it ended
    assert third.status_code == 202
    wait_job(c, third.json()["job"])


def test_stackshots_refusals_of_a_new_project_are_the_jobs_answer(env):
    c, ss = env["client"], env["ss"]
    wait_job(c, c.post("/api/spawn/project", json=NEW).json()["job"])
    # the page exists: a 409 that the page words as "pick it from the list"
    done = wait_job(c, c.post("/api/spawn/project", json=NEW).json()["job"])
    assert done["status"] == 409 and done["result"]["code"] == "exists" and done["result"]["ok"] is False and "already exists" in done["result"]["error"]
    # gbrain refused or did not answer: 502, stackshot's reason
    ss.new_reply = (502, {"error": "gbrain refused the new page for projects/x: boom; nothing else was recorded"})
    done = wait_job(c, c.post("/api/spawn/project", json={**NEW, "key": "projects/x"}).json()["job"])
    assert done["status"] == 502 and done["result"]["code"] == "gbrain" and "boom" in done["result"]["error"]
    ss.new_reply = (400, {"error": "key = projects/<slug> or infra/<slug>"})
    done = wait_job(c, c.post("/api/spawn/project", json={**NEW, "key": "projects/y"}).json()["job"])
    assert done["status"] == 400 and done["result"]["code"] == "bad"
    # stackshot gone while the job runs: the job ends with the reason, not a hang
    ss.new_reply = None
    ss.close()
    done = wait_job(c, c.post("/api/spawn/project", json={**NEW, "key": "projects/z"}).json()["job"])
    assert done["status"] == 502 and done["result"]["code"] == "unreachable"


@pytest.mark.parametrize("body", [
    [1], {"scope": "gamma"}, {"key": "projects/x"}, {**NEW, "scope": "all"}, {**NEW, "scope": "work"}, {**NEW, "scope": ["gamma"]},
    {**NEW, "key": "x"}, {**NEW, "key": "notes/x"}, {**NEW, "key": "projects/X"}, {**NEW, "key": "projects/a/b"}, {**NEW, "key": "projects/"},
    {**NEW, "key": "projects/a;id"}, {**NEW, "key": "projects/$(id)"}, {**NEW, "key": "projects/-a"}, {**NEW, "key": "projects/a--b"},
    {**NEW, "key": "projects/" + "a" * 61}, {**NEW, "key": "../etc/x"}, {**NEW, "key": 5},
    {**NEW, "title": 'A "quoted" title'}, {**NEW, "title": "a\\b"}, {**NEW, "title": "x" * 121}, {**NEW, "title": "tab\u0007bell"},
    {**NEW, "sender": "somebody"}, {**NEW, "cwd": "/tmp"},      # the label is the server's, never the page's
])
def test_a_bad_project_is_refused_here_and_never_reaches_stackshot(env, body):
    r = env["client"].post("/api/spawn/project", json=body)
    assert r.status_code == 400, r.text
    assert r.json()["ok"] is False and r.json()["error"]
    assert env["ss"].calls("/client/project") == []


def test_a_slug_at_the_limit_and_a_title_with_korean_pass(env):
    c, ss = env["client"], env["ss"]
    r = c.post("/api/spawn/project", json={"key": "projects/" + "a" * 60, "scope": "gamma", "title": "샘플 리모델링"})
    assert r.status_code == 202
    wait_job(c, r.json()["job"])
    assert ss.calls("/client/project")[0]["body"]["title"] == "샘플 리모델링"
    # whitespace in a title (a newline, a run of spaces) is one space, as the page writes it
    wait_job(c, c.post("/api/spawn/project", json={"key": "projects/two-lines", "scope": "gamma", "title": "two\n  lines"}).json()["job"])
    assert ss.calls("/client/project")[-1]["body"]["title"] == "two lines"


def test_the_job_lookup_takes_only_a_job_id(env):
    c = env["client"]
    for bad in ("", "abc", "../x", "0" * 15, "g" * 16, "0" * 16 + "0"):
        assert c.get("/api/spawn/project/job", params={"id": bad}).status_code == 404, bad
    assert c.get("/api/spawn/project/job").status_code == 404


# ── listed again, and the agent ──────────────────────────────────────────────
def test_a_hidden_project_is_listed_again_by_its_id_or_key(env):
    c, ss = env["client"], env["ss"]
    hidden = ss.find("projects/gamma-old-kayak")
    assert hidden["listed"] is False
    r = c.post("/api/spawn/project-list", json={"key": hidden["id"], "scope": "gamma"})
    assert r.status_code == 200, r.text
    assert r.json()["ok"] and r.json()["key"] == "projects/gamma-old-kayak" and r.json()["changed"] is True
    assert ss.calls("/client/project-list")[-1]["body"] == {"key": hidden["id"], "scope": "gamma", "sender": "sala-web"}
    assert ss.find("projects/gamma-old-kayak")["listed"] is True
    # said again: nothing changes; by key, without a scope
    r = c.post("/api/spawn/project-list", json={"key": "projects/gamma-old-kayak"})
    assert r.status_code == 200 and r.json()["changed"] is False
    assert ss.calls("/client/project-list")[-1]["body"] == {"key": "projects/gamma-old-kayak", "sender": "sala-web"}
    # stackshot refuses a note page, and an unknown one
    r = c.post("/api/spawn/project-list", json={"key": "projects/gamma-kayak-notes"})
    assert r.status_code == 400 and r.json()["code"] == "bad" and "note" in r.json()["error"]
    r = c.post("/api/spawn/project-list", json={"key": "projects/nope"})
    assert r.status_code == 404 and r.json()["code"] == "not-found"


@pytest.mark.parametrize("body", [[1], {}, {"key": "gamma-x"}, {"key": "projects/a b"}, {"key": "prj_xyz"}, {"key": "prj_0123456789"}, {"key": "projects/a;id"},
                                  {"key": "projects/x", "scope": "all"}, {"key": "projects/x", "sender": "me"}, {"key": 5}])
def test_a_bad_list_is_refused_here(env, body):
    assert env["client"].post("/api/spawn/project-list", json=body).status_code == 400
    assert env["ss"].calls("/client/project-list") == []


AGENT = {"project": "projects/beta-docs", "name": "beta-docs-main", "role": "main", "front": True, "mandate": "the project's main agent"}


def test_the_agent_is_added_to_the_project_and_the_owed_page_line_is_in_the_answer(env):
    c, ss = env["client"], env["ss"]
    c.post("/api/spawn/project-list", json={"key": "projects/beta-docs", "scope": "beta"})   # the label that lists a project may add its first agent
    r = c.post("/api/spawn/project-agent", json={**AGENT, "mandate": "  the project's\n main   agent  "})
    assert r.status_code == 200, r.text
    d = r.json()
    assert d["ok"] and d["key"] == "projects/beta-docs" and d["pageOwed"] is True and "beta-docs-main: the project's main agent" in d["pageYaml"]
    assert ss.calls("/client/project-agent")[-1]["body"] == {**AGENT, "mandate": "the project's main agent", "sender": "sala-web"}   # one line, the form's label
    # a second agent of the same label: allowed; a background one is front false
    r = c.post("/api/spawn/project-agent", json={**AGENT, "name": "beta-docs-helper", "role": "helper", "front": False, "mandate": "watches the inbox"})
    assert r.status_code == 200 and ss.calls("/client/project-agent")[-1]["body"]["front"] is False
    # stackshot: with an agents map already on the page the owed lines are entries only; passed on as they are
    d2 = r.json()
    assert d2["pageYaml"].startswith("  beta-docs-helper: ") and "agents:" not in d2["pageYaml"] and "existing agents" in d2["note"]
    assert d["pageYaml"].startswith("agents:\n")


def test_a_project_being_made_by_another_request_is_a_wait_not_a_duplicate(env):
    c, ss = env["client"], env["ss"]
    ss.new_reply = (409, {"error": "projects/fresh-idea is being made by another request: try again in a minute"})
    done = wait_job(c, c.post("/api/spawn/project", json=NEW).json()["job"])
    assert done["status"] == 409 and done["result"]["code"] == "in-progress" and done["result"]["ok"] is False
    # an existing page stays `exists`
    ss.new_reply = (409, {"error": "projects/fresh-idea already exists: list it again"})
    done = wait_job(c, c.post("/api/spawn/project", json=NEW).json()["job"])
    assert done["result"]["code"] == "exists"


def test_a_mandate_with_a_control_character_is_refused_before_stackshot(env):
    c, ss = env["client"], env["ss"]
    r = c.post("/api/spawn/project-agent", json={**AGENT, "mandate": "watches\u0007 the inbox"})
    assert r.status_code == 400 and "control character" in r.json().get("error", r.text)
    assert ss.calls("/client/project-agent") == []


def test_an_agent_is_added_to_a_project_that_has_agents_already(env):
    c, ss = env["client"], env["ss"]
    # stackshot: sala-web may add an agent to ANY listed project, one with agents already included
    r = c.post("/api/spawn/project-agent", json={**AGENT, "project": "projects/gamma-harbor", "name": "gamma-harbor-helper", "role": "helper", "front": False})
    assert r.status_code == 200 and r.json()["ok"] is True and r.json()["key"] == "projects/gamma-harbor", r.text
    assert "gamma-harbor-helper" in ss.find("projects/gamma-harbor")["agents"]


def test_stackshots_403_for_a_retired_or_hidden_project_and_409_for_a_taken_name_pass_through(env):
    c, ss = env["client"], env["ss"]
    # 403: a hidden project (not listed again first); the old keeper-or-front-agent refusal is gone
    r = c.post("/api/spawn/project-agent", json={**AGENT, "project": "projects/gamma-old-kayak", "name": "gamma-old-kayak-main", "role": "main", "front": True})
    assert r.status_code == 403 and r.json()["code"] == "not-allowed" and r.json()["step"] == "agent" and "retired or hidden" in r.json()["error"], r.text
    # 409: a name another project's agent holds, or one pending from another sender
    r = c.post("/api/spawn/project-agent", json={**AGENT, "project": "projects/beta-docs", "name": "beta-docs-main"})
    assert r.status_code == 200
    ss.pending_names.add("beta-docs-helper")
    r = c.post("/api/spawn/project-agent", json={**AGENT, "name": "beta-docs-helper", "role": "helper", "front": False})
    assert r.status_code == 409 and r.json()["code"] == "exists" and "already taken" in r.json()["error"], r.text
    ss.agent_reply = (409, {"error": "beta-docs-main is already listed on projects/beta-docs as front (main): 'x'; the page is the authority"})
    r = c.post("/api/spawn/project-agent", json=AGENT)
    assert r.status_code == 409 and r.json()["code"] == "exists" and "the page is the authority" in r.json()["error"]
    ss.agent_reply = (400, {"error": "'x-main' does not start with the project's name: an agent of projects/beta-docs is called beta-docs-<role>"})
    r = c.post("/api/spawn/project-agent", json=AGENT)
    assert r.status_code == 400 and "is called beta-docs-<role>" in r.json()["error"]


@pytest.mark.parametrize("patch", [
    {"project": "x"}, {"project": "projects/a;id"}, {"project": "prj_xx"}, {"project": 5}, {"name": "Beta-Main"}, {"name": "-x"}, {"name": "x" * 49}, {"name": ""},
    {"name": "a b"}, {"role": ""}, {"role": "a b"}, {"role": "x" * 33}, {"role": "-x"}, {"role": "a;id"}, {"front": "true"}, {"front": 1}, {"front": None},
    {"mandate": ""}, {"mandate": "  \n "}, {"mandate": "x" * 601}, {"mandate": ["x"]}, {"sender": "sala-web"}, {"cwd": "/tmp"},
])
def test_a_bad_agent_is_refused_here_and_never_reaches_stackshot(env, patch):
    r = env["client"].post("/api/spawn/project-agent", json={**AGENT, **patch})
    assert r.status_code == 400, r.text
    assert env["ss"].calls("/client/project-agent") == []


def test_every_post_has_the_origin_content_type_and_size_guards(env):
    c, ss = env["client"], env["ss"]
    for path, body in (("/api/spawn/project", NEW), ("/api/spawn/project-list", {"key": "projects/gamma-pantry"}), ("/api/spawn/project-agent", AGENT)):
        assert c.post(path, json=body, headers={"Origin": "https://evil.example"}).status_code == 403, path
        assert c.post(path, json=body, headers={"Origin": "null"}).status_code == 403, path
        assert c.post(path, content=json.dumps(body).encode(), headers={"Content-Type": "text/plain"}).status_code == 415, path
        assert c.post(path, content=b"{not json", headers={"Content-Type": "application/json"}).status_code == 400, path
        assert c.post(path, content=b"{" + b" " * (16 * 1024) + b"}", headers={"Content-Type": "application/json"}).status_code == 413, path
        assert c.get(path).status_code in (404, 405), path
    assert [r for r in ss.requests if r["method"] == "POST"] == []


# ── the shapes on their own ──────────────────────────────────────────────────
def test_the_value_shapes():
    dirs = ["projects", "infra"]
    assert PP.new_key_ok("projects/a-b-1", dirs) and PP.new_key_ok("projects/x", dirs)
    assert not any(PP.new_key_ok(k, dirs) for k in ("projects/a/b", "projects", "notes/x", "projects/A", "projects/a_b", "projects/-a", "projects/a-", "projects/", 5, None))
    h8 = "0a1b" + "2c3d"   # an id is prj_ plus 8 lower-case hex digits; built here so no fixed id sits in the file
    assert PP.project_ref_ok("prj_" + h8, dirs) and PP.project_ref_ok("projects/stackshot/sessions", dirs) and not PP.project_ref_ok("prj_" + h8.upper(), dirs)
    assert PP.title_ok("Fresh Idea") and not PP.title_ok('a"b') and not PP.title_ok("a\\b") and not PP.title_ok("a\tb") and not PP.title_ok("x" * 121)
    assert PP.SENDER == "sala-web" == __import__("sala_web.spawn", fromlist=["FROM"]).FROM
    c = PP.clean_projects({"scope": "gamma", "scopes": ["gamma"], "projects": [{"key": "projects/x", "id": "prj_1", "type": "project", "secret": "no", "agents": {"a": {"front": True, "role": "main", "mandate_line": "m", "page_owed": True}, "b": 1}}, 7, {"nokey": 1}]})
    assert c["projects"] == [{"id": "prj_1", "key": "projects/x", "title": "", "name": "", "type": "project", "scope": "", "listed": False, "hidden": False, "keeper": "", "main": "",
                              "agents": {"a": {"front": True, "role": "main", "page_owed": True}}}]
    assert PP.clean_projects("text") is None and PP.clean_projects({"projects": "x"}) is None


def test_the_picker_lists_only_type_project_pages():
    """The one source of truth is the page's `type`: a page with agents, items or a mark but another type (or none) is no project to
    pick, hidden or listed."""
    def r(key, **kw):
        return {"key": key, "listed": True, **kw}
    rows = [r("projects/a", type="project"), r("projects/b", type="Project"), r("projects/c", type="note", agents={"c-main": {"front": True, "role": "main"}}),
            r("projects/a/sub", type="reference"), r("projects/d"), r("projects/e", type=None), r("projects/f", type="project", status="archived"),
            r("projects/g", type="note", listed=False, hidden=True), r("projects/h", type="project", listed=False, hidden=True)]
    out = PP.clean_projects({"scope": "all", "scopes": ["gamma"], "projects": rows})
    assert [(p["key"], p["type"]) for p in out["projects"]] == [("projects/a", "project"), ("projects/b", "Project"), ("projects/h", "project")]
