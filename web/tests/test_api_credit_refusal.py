"""The Overview's api card reads the shared API-credit refusal record (apicredit.py, written by a job whose key call comes back
"credit balance is too low") as the dormant sign when sala's lane-state has no api row. Only the card's answer changes: the
record is read, never written, and no key call or Admin API call is made by these tests (the Admin API is a counting fake).
The state dir is a tmp_path via XDG_STATE_HOME; the real ~/.local/state is never read."""

import json
import time

import pytest
from starlette.testclient import TestClient

from sala_web import apicredit as AC
from sala_web import sessions as S
from sala_web.app import create_app
from sala_web.config import Settings

EPOCH = 1767582000   # 2026-01-05T03:00:00Z
SINCE = "2026-01-05T03:00:00Z"


class CountingAdmin:
    def __init__(self):
        self.calls = 0

    def __call__(self, key, path, params):
        self.calls += 1
        return {"data": [], "has_more": False, "next_page": None}


@pytest.fixture
def xdg(tmp_path, monkeypatch):
    base = tmp_path / "xdg"
    monkeypatch.setenv("XDG_STATE_HOME", str(base))
    monkeypatch.setattr(S, "live_tmux_names", lambda: {})
    return base


def write_record(base, text):
    p = base / "api-credit" / "state.json"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)
    return p


def app_for(tmp_path):
    key = tmp_path / "admin-key"
    key.write_text("admin-key-not-real")
    sala_state = tmp_path / "sala-state"
    sala_state.mkdir()
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=tmp_path / "claude",
                        tmux_socket_name="salaweb-pytest-none", roles_cmd=["false"], sala_models=tmp_path / "none.tsv",
                        sala_state_dir=sala_state, admin_key=key)
    app = create_app(settings)
    admin = CountingAdmin()
    app.state.credit.fetch = admin
    return app, admin


def settled(client):
    for _ in range(250):
        r = client.get("/api/credit")
        assert r.status_code == 200
        got = r.json()
        if not got.get("refreshing"):
            return got
        time.sleep(0.02)
    raise AssertionError("the refresh never landed")


# ── the record, read ─────────────────────────────────────────────────────────
def test_a_refusal_record_gives_a_reason_and_the_time_only(xdg, tmp_path):
    write_record(xdg, json.dumps({"refused_at": EPOCH, "by": "briefing", "detail": "Credit balance is too low (secret text)"}))
    assert AC.refusal() == {"reason": AC.REASON, "since": SINCE}


@pytest.mark.parametrize("text", [
    None,                                  # no record at all
    "",                                    # empty
    "{not json",                           # malformed
    "[1, 2]",                              # not an object
    json.dumps({"by": "briefing"}),        # no refused_at
    json.dumps({"refused_at": "soon"}),    # not a number
    json.dumps({"refused_at": True}),      # a bool is not a time
    json.dumps({"refused_at": 1e300}),     # out of range for a time
])
def test_no_readable_refusal_reads_as_no_refusal_known(xdg, text):
    if text is not None:
        write_record(xdg, text)
    assert AC.refusal() is None


def test_an_unreadable_record_reads_as_no_refusal_known(xdg):
    p = write_record(xdg, json.dumps({"refused_at": EPOCH}))
    p.unlink()
    p.mkdir()   # a directory where the file should be: read_text raises IsADirectoryError (an OSError)
    assert AC.refusal() is None


def test_the_module_never_writes_the_record(xdg):
    p = write_record(xdg, json.dumps({"refused_at": EPOCH, "by": "briefing"}))
    before = p.read_text()
    AC.refusal()
    assert p.read_text() == before


# ── the card's answer ─────────────────────────────────────────────────────────
def test_the_card_is_dormant_while_the_shared_record_holds_a_refusal(xdg, tmp_path):
    write_record(xdg, json.dumps({"refused_at": EPOCH, "by": "briefing", "detail": "x"}))
    app, admin = app_for(tmp_path)
    with TestClient(app) as c:
        got = settled(c)
    assert got["lane"] == "api" and got["dormant"] == {"reason": AC.REASON, "since": SINCE}
    assert admin.calls >= 1   # the spend figure is still the Admin API's, as before


def test_no_record_leaves_the_card_active(xdg, tmp_path):
    app, _ = app_for(tmp_path)
    with TestClient(app) as c:
        got = settled(c)
    assert "dormant" not in got and "lane" not in got


def test_sala_record_still_wins_when_present(xdg, tmp_path):
    write_record(xdg, json.dumps({"refused_at": EPOCH, "by": "briefing"}))
    app, _ = app_for(tmp_path)
    (tmp_path / "sala-state" / "lane-state.tsv").write_text(
        "\t".join(["api", "dormant", "credit used up", "2026-01-06T00:00:00Z", "1", "watch"]) + "\n")
    with TestClient(app) as c:
        got = settled(c)
    assert got["lane"] == "api" and got["dormant"]["since"] == "2026-01-06T00:00:00Z"
