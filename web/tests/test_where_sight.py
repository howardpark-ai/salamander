"""The web UI's sighting for `sala where` (wheresight.py, lib/where.py `seen`): a page request from the owner's box records that box.

Held here: the address is the right-most X-Forwarded-For entry and a missing or non-address header does nothing; only the main page and the
terminal page count (never a static file, an API call or the session redirect); one address is handled once a minute; the answer is the page
whatever the work does (a failing runner, no where.py); and, end to end with a made-up machine list and a tailscale stand-in, a known address is
recorded via web, an unknown one records nothing, and a recent "told" record is not overwritten. Addresses are from the documentation ranges.
"""

import json
import os
import stat
import time

import pytest
from starlette.testclient import TestClient

from sala_web import wheresight as WS
from sala_web.app import create_app
from sala_web.config import Settings

KNOWN = "198.51.100.2"
OTHER = "198.51.100.3"
PUBLIC = "203.0.113.50"


def make_client(tmp_path, **kw):
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True, exist_ok=True)
    (claude / "projects").mkdir(exist_ok=True)
    return TestClient(create_app(Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                                          tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"], **kw)))


@pytest.fixture(autouse=True)
def fresh_throttle():
    WS._last.clear()
    yield
    WS._last.clear()


def wait_for(cond, secs=15.0):
    end = time.time() + secs
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.05)
    return cond()


def settle():
    """Let a started where-seen thread end."""
    import threading
    for t in [t for t in threading.enumerate() if t.name == "where-seen"]:
        t.join(30)


# ---- the address and the throttle -------------------------------------------------------------------------------

def test_the_right_most_entry_is_the_address():
    assert WS.address_of(f"{PUBLIC}, {KNOWN}") == KNOWN
    assert WS.address_of(f"{KNOWN},{PUBLIC}") == PUBLIC
    assert WS.address_of(KNOWN) == KNOWN
    assert WS.address_of("2001:db8::1") == "2001:db8::1"


@pytest.mark.parametrize("value", [None, "", "  ", "unknown", "not-an-ip", f"{KNOWN}, x", f"{KNOWN},", "300.1.1.1"])
def test_a_missing_or_malformed_header_gives_no_address(value):
    assert WS.address_of(value) is None


def test_one_address_is_due_once_a_minute():
    assert WS.due(KNOWN, now=1000.0) is True
    assert WS.due(KNOWN, now=1059.0) is False
    assert WS.due(OTHER, now=1010.0) is True       # another address has its own minute
    assert WS.due(KNOWN, now=1060.0) is True


def test_the_table_is_bounded():
    for i in range(WS._MAX_ADDRESSES):
        assert WS.due(f"2001:db8::{i + 1:x}", now=5000.0)
    assert WS.due("2001:db8:1::9", now=5001.0) is False     # full and nothing old enough to drop
    assert WS.due("2001:db8:1::9", now=5100.0) is True      # the old ones are dropped


# ---- which requests count, and that the page is never harmed ----------------------------------------------------

@pytest.fixture
def calls(monkeypatch):
    seen = []
    monkeypatch.setattr(WS, "_run", lambda addr, settings: seen.append(addr))
    return seen


def test_a_page_request_hands_over_the_right_most_address_once(tmp_path, calls):
    c = make_client(tmp_path)
    h = {"X-Forwarded-For": f"{PUBLIC}, {KNOWN}"}
    assert c.get("/", headers=h).status_code == 200
    assert c.get("/", headers=h).status_code == 200
    assert wait_for(lambda: calls == [KNOWN])
    time.sleep(0.2)
    assert calls == [KNOWN]                             # the second visit is inside the minute


def test_the_terminal_page_counts(tmp_path, calls):
    c = make_client(tmp_path)
    assert c.get("/terminal", headers={"X-Forwarded-For": OTHER}).status_code == 200
    assert wait_for(lambda: calls == [OTHER])


def test_no_header_or_a_bad_one_starts_nothing(tmp_path, calls):
    c = make_client(tmp_path)
    for h in ({}, {"X-Forwarded-For": "garbage"}, {"X-Forwarded-For": f"{KNOWN}, nope"}):
        assert c.get("/", headers=h).status_code == 200
    time.sleep(0.3)
    assert calls == []


def test_assets_polls_and_api_calls_do_not_count(tmp_path, calls):
    c = make_client(tmp_path)
    h = {"X-Forwarded-For": KNOWN}
    for path in ("/api/config", "/api/sessions", "/manifest.webmanifest", "/sw.js", "/static/app.js"):
        c.get(path, headers=h)
    c.get("/sessions", headers=h, follow_redirects=False)
    time.sleep(0.3)
    assert calls == []


def test_a_failing_runner_never_fails_the_page(tmp_path, monkeypatch):
    def boom(addr, settings):
        raise RuntimeError("boom")
    monkeypatch.setattr(WS, "_run", boom)
    assert make_client(tmp_path).get("/", headers={"X-Forwarded-For": KNOWN}).status_code == 200


def test_no_where_script_is_silent(tmp_path, monkeypatch):
    monkeypatch.setattr(WS, "_where_script", lambda: None)
    WS._run(KNOWN, Settings())      # returns, raises nothing


# ---- end to end: the real lib/where.py with a made-up machine list ----------------------------------------------

@pytest.fixture
def world(tmp_path, monkeypatch):
    shim = tmp_path / "shim"
    shim.mkdir()
    ts = {"Self": {"HostName": "host-a", "TailscaleIPs": ["198.51.100.1"]},
          "Peer": {"k1": {"HostName": "host-b", "TailscaleIPs": [KNOWN]}, "k2": {"HostName": "host-c", "TailscaleIPs": [OTHER]}}}
    (tmp_path / "ts.json").write_text(json.dumps(ts))
    tool = shim / "tailscale"
    tool.write_text(f"#!/bin/sh\ncat {tmp_path}/ts.json\n")
    tool.chmod(tool.stat().st_mode | stat.S_IXUSR)
    names = tmp_path / "fleet-names.tsv"
    names.write_text("host-a\tbox-a\tA\nhost-b\tbox-b\tB\nhost-c\tbox-c\tC\n")
    state = tmp_path / "sala-state"
    monkeypatch.setenv("PATH", f"{shim}:{os.environ['PATH']}")
    c = make_client(tmp_path, sala_state_dir=state, fleet_names_file=names)
    return c, state / "where.json"


def record(path):
    return json.loads(path.read_text()) if path.exists() else None


def test_a_known_address_is_recorded_via_web(world):
    c, rec = world
    assert c.get("/", headers={"X-Forwarded-For": f"{PUBLIC}, {KNOWN}"}).status_code == 200
    assert wait_for(lambda: record(rec) is not None)
    settle()
    r = record(rec)
    assert r["box"] == "box-b" and r["via"] == "web"


def test_an_unknown_address_records_nothing_and_overwrites_nothing(world):
    c, rec = world
    c.get("/", headers={"X-Forwarded-For": PUBLIC})
    settle()
    assert record(rec) is None
    rec.parent.mkdir(parents=True, exist_ok=True)
    rec.write_text(json.dumps({"box": "box-a", "at": int(time.time()) - 100, "via": "ssh", "by": ""}))
    WS._last.clear()
    c.get("/", headers={"X-Forwarded-For": "192.0.2.77"})
    settle()
    assert record(rec)["box"] == "box-a"


def test_a_recent_told_record_is_not_overwritten(world):
    c, rec = world
    rec.parent.mkdir(parents=True, exist_ok=True)
    told = {"box": "box-a", "at": int(time.time()) - 3600, "via": "told", "by": "s"}
    rec.write_text(json.dumps(told))
    c.get("/", headers={"X-Forwarded-For": KNOWN})
    settle()
    assert record(rec) == told
