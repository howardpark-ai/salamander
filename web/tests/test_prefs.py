"""GET/PUT /api/prefs: the page's saved preferences in state_dir/prefs.json."""

import json
import os

import pytest
from starlette.testclient import TestClient

from sala_web import app as A
from sala_web.app import create_app
from sala_web.config import Settings

DEFAULTS = {"scopeOrder": [], "groupOrder": [], "sessionOrder": [], "collapsed": [], "laneOrder": [], "showAll": False, "unreadOnly": False,
            "showTools": False, "shellHeight": 300, "lang": "en"}


@pytest.fixture
def env(tmp_path):
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    (claude / "projects").mkdir()
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                        tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"])
    return {"client": TestClient(create_app(settings)), "file": settings.state_dir / "prefs.json",
            "dir": settings.state_dir}


def test_defaults_when_nothing_saved(env):
    r = env["client"].get("/api/prefs")
    assert r.status_code == 200
    assert r.json() == DEFAULTS
    assert not env["file"].exists()


def test_round_trip_and_merge(env):
    c = env["client"]
    r = c.put("/api/prefs", json={"groupOrder": ["projects/b", "Unregistered", "projects/a"]})
    assert r.status_code == 200, r.text
    assert r.json()["groupOrder"] == ["projects/b", "Unregistered", "projects/a"]
    # a later PUT of another key keeps the order
    assert c.put("/api/prefs", json={"showAll": True}).status_code == 200
    want = {**DEFAULTS, "groupOrder": ["projects/b", "Unregistered", "projects/a"], "showAll": True}
    assert c.get("/api/prefs").json() == want
    assert json.loads(env["file"].read_text()) == want
    # the scope order and the collapsed list are lists of keys too
    r = c.put("/api/prefs", json={"scopeOrder": ["gamma", "example"], "collapsed": ["scope:beta", "projects/b"]})
    assert r.status_code == 200 and r.json()["collapsed"] == ["scope:beta", "projects/b"]
    assert c.get("/api/prefs").json()["groupOrder"] == ["projects/b", "Unregistered", "projects/a"]
    assert (env["file"].stat().st_mode & 0o777) == 0o600
    # repeats are dropped, first place kept
    assert c.put("/api/prefs", json={"groupOrder": ["x", "y", "x"]}).json()["groupOrder"] == ["x", "y"]


def test_the_order_of_sessions_is_kept_like_the_groups(env):
    """Decision: sessions are reordered inside their project and the order is kept by sala: a flat
    list of session names in the file, so it holds after a reload and on another device."""
    c = env["client"]
    order = ["demo-main", "demo-builder", "gamma-harbor-main"]
    r = c.put("/api/prefs", json={"sessionOrder": order})
    assert r.status_code == 200 and r.json()["sessionOrder"] == order
    assert c.put("/api/prefs", json={"groupOrder": ["projects/a"]}).status_code == 200   # another key leaves it alone
    assert c.get("/api/prefs").json()["sessionOrder"] == order
    assert json.loads(env["file"].read_text())["sessionOrder"] == order
    assert c.put("/api/prefs", json={"sessionOrder": ["a", "b", "a"]}).json()["sessionOrder"] == ["a", "b"]   # repeats dropped
    assert c.put("/api/prefs", json={"sessionOrder": []}).json()["sessionOrder"] == []
    for bad in ({"sessionOrder": "demo-main"}, {"sessionOrder": [1]}, {"sessionOrder": [""]},
                {"sessionOrder": [f"s{i}" for i in range(A.PREFS_MAX_GROUPS + 1)]}):
        assert c.put("/api/prefs", json=bad).status_code == 400, bad


def test_the_unread_filter_is_kept_like_show_all_sessions(env):
    """The Unread entry's on/off is a pref of the server's, so the phone and the desktop agree and a reload keeps it; off by default."""
    c = env["client"]
    assert c.get("/api/prefs").json()["unreadOnly"] is False
    assert c.put("/api/prefs", json={"unreadOnly": True}).json()["unreadOnly"] is True
    assert c.put("/api/prefs", json={"showAll": True}).status_code == 200      # another key leaves it alone
    assert c.get("/api/prefs").json()["unreadOnly"] is True
    assert json.loads(env["file"].read_text())["unreadOnly"] is True
    assert c.put("/api/prefs", json={"unreadOnly": "yes"}).status_code == 400
    assert c.get("/api/prefs").json()["unreadOnly"] is True


def test_the_shell_drawer_height_is_kept_like_the_lane_order(env):
    """Decision: the Shell drawer's height follows the user across browsers, so it is a pref, a whole
    number of pixels; the page keeps it inside the window. Default 300."""
    c = env["client"]
    assert c.get("/api/prefs").json()["shellHeight"] == 300
    r = c.put("/api/prefs", json={"shellHeight": 420})
    assert r.status_code == 200 and r.json()["shellHeight"] == 420
    assert c.put("/api/prefs", json={"showAll": True}).status_code == 200      # another key leaves it alone
    assert c.get("/api/prefs").json()["shellHeight"] == 420
    assert json.loads(env["file"].read_text())["shellHeight"] == 420
    for bad in ({"shellHeight": "420"}, {"shellHeight": 420.5}, {"shellHeight": True}, {"shellHeight": None}, {"shellHeight": 0},
                {"shellHeight": 119}, {"shellHeight": 4001}, {"shellHeight": -300}, {"shellHeight": [300]}):
        assert c.put("/api/prefs", json=bad).status_code == 400, bad
    assert c.get("/api/prefs").json()["shellHeight"] == 420


def test_the_interface_language_is_kept_and_named_in_the_served_page(env):
    """The language follows the person across browsers, so it is a pref: "en" (the default) or "ko". The served page names it in
    <html lang>, so the first paint is already in it; anything else is refused and a damaged saved value reads as English."""
    c = env["client"]
    assert c.get("/api/prefs").json()["lang"] == "en" and '<html lang="en">' in c.get("/").text
    r = c.put("/api/prefs", json={"lang": "ko"})
    assert r.status_code == 200 and r.json()["lang"] == "ko"
    assert json.loads(env["file"].read_text())["lang"] == "ko" and '<html lang="ko">' in c.get("/").text
    for bad in ({"lang": "fr"}, {"lang": ""}, {"lang": None}, {"lang": True}, {"lang": ["ko"]}):
        assert c.put("/api/prefs", json=bad).status_code == 400, bad
    assert c.get("/api/prefs").json()["lang"] == "ko"
    env["file"].write_text(json.dumps({"lang": "xx"}))
    assert c.get("/api/prefs").json()["lang"] == "en" and '<html lang="en">' in c.get("/").text


@pytest.mark.parametrize("body", [
    [1, 2],
    {"groupOrder": "projects/a"},
    {"groupOrder": ["ok", 3]},
    {"groupOrder": [""]},
    {"groupOrder": ["a" * 513]},
    {"groupOrder": [f"g{i}" for i in range(A.PREFS_MAX_GROUPS + 1)]},
    {"showAll": "yes"},
    {"unreadOnly": 1},
    {"scopeOrder": "gamma"},
    {"collapsed": [None]},
    {"theme": "dark"},
    {"groupOrder": [], "extra": 1},
])
def test_validation(env, body):
    r = env["client"].put("/api/prefs", json=body)
    assert r.status_code == 400, r.text
    assert not env["file"].exists()


def test_bad_json_and_too_large(env):
    c = env["client"]
    assert c.put("/api/prefs", content=b"{nope", headers={"Content-Type": "application/json"}).status_code == 400
    big = json.dumps({"groupOrder": ["k" * 500] * 200}).encode()  # over 64 KB
    assert len(big) > A.PREFS_MAX_BYTES
    assert c.put("/api/prefs", content=big, headers={"Content-Type": "application/json"}).status_code == 413
    assert not env["file"].exists()


def test_cross_origin_and_wrong_content_type_refused(env):
    c = env["client"]
    assert c.put("/api/prefs", json={"showAll": True}, headers={"Origin": "https://evil.example"}).status_code == 403
    assert c.put("/api/prefs", json={"showAll": True}, headers={"Origin": "null"}).status_code == 403
    assert c.put("/api/prefs", content=b'{"showAll": true}', headers={"Content-Type": "text/plain"}).status_code == 415
    assert c.post("/api/prefs", json={"showAll": True}).status_code == 405
    assert not env["file"].exists()
    # same origin as the Host is fine
    assert c.put("/api/prefs", json={"showAll": True}, headers={"Origin": "http://testserver"}).status_code == 200


def test_write_is_atomic(env, monkeypatch):
    c = env["client"]
    assert c.put("/api/prefs", json={"groupOrder": ["old"]}).status_code == 200
    before = env["file"].read_text()

    def boom(src, dst):
        # the new content is complete in a temp file next to the target before the rename
        assert os.path.dirname(src) == str(env["dir"]) and json.loads(open(src).read())["groupOrder"] == ["new"]
        raise OSError(28, "No space left on device")

    monkeypatch.setattr(A.os, "replace", boom)
    r = c.put("/api/prefs", json={"groupOrder": ["new"]})
    assert r.status_code == 500 and "No space left" in r.json()["error"]
    assert env["file"].read_text() == before
    assert sorted(p.name for p in env["dir"].iterdir()) == ["prefs.json"]  # no temp file left behind


def test_unreadable_file_gives_defaults(env):
    env["dir"].mkdir(parents=True)
    env["file"].write_text("{not json")
    assert env["client"].get("/api/prefs").json() == DEFAULTS
    assert env["client"].put("/api/prefs", json={"showAll": True}).json()["groupOrder"] == []  # PUT starts afresh
    # key by key: an unknown key is dropped and a bad one falls back to its default, the rest is kept
    env["file"].write_text(json.dumps({"groupOrder": ["a"], "showAll": "yes", "junk": 1}))
    assert env["client"].get("/api/prefs").json() == {**DEFAULTS, "groupOrder": ["a"]}
