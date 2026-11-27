"""The Overview's api card and the api lane's details page read the shared API-credit refusal record (apicredit.py, written by a
job whose key call comes back "credit balance is too low") as the dormant sign when sala's lane-state has no api row. Only what
is displayed changes: the New session form still offers the lane, so the page must not say it does not. The record is read,
never written, and no key call or Admin API call is made by these tests (the Admin API is a counting fake). The state dir is a
tmp_path via XDG_STATE_HOME; the real ~/.local/state is never read. The page parts run in a headless Chromium when one is
installed (conftest.py: `browser`), else are skipped."""

import json
import re
import time

import pytest
from starlette.testclient import TestClient

from sala_web import apicredit as AC
from sala_web import sessions as S
from sala_web.app import STATIC, create_app
from sala_web.config import Settings
from test_board_items_ui import wait_for
from test_lane_details import LANE_PAGE, get, open_lane, stub_sala  # noqa: F401  (fixture: the lane table's stand-in)
from test_lane_dormant import page, record, world  # noqa: F401  (fixtures: the app, its page)
from test_new_session import GOOD, env, sala  # noqa: F401  (fixtures: the form with sala's stand-in)

EPOCH = 1767582000   # 2026-01-05T03:00:00Z
SINCE = "2026-01-05T03:00:00Z"
REFUSED = {"state": "dormant", "reason": "credit used up", "since": SINCE, "source": "refusal"}
NOT_OFFERED = "The New session form does not offer it."


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
        "\t".join(["api", "dormant", "held by hand", "2026-01-06T00:00:00Z", "1", "hand"]) + "\n")
    with TestClient(app) as c:
        got = settled(c)
    assert got["lane"] == "api" and got["dormant"] == {"reason": "held by hand", "since": "2026-01-06T00:00:00Z"}


# ── the reason, in the page's words ──────────────────────────────────────────
def strings(lang):
    """The page's string table of one language, as {key: text}."""
    text = (STATIC / f"i18n-{lang}.js").read_text(encoding="utf-8")
    return {k: json.loads(v) for k, v in re.findall(r'^\s*"(ov\.[\w.]+)": ("(?:[^"\\]|\\.)*"),?\s*$', text, re.M)}


def test_the_reason_is_one_the_page_words_in_both_languages():
    js = (STATIC / "sessions.js").read_text(encoding="utf-8")
    words = js.split("const REASON_WORDS = ", 1)[1].split(";", 1)[0]
    assert f'"{AC.REASON}": "ov.reason.creditUsedUp"' in words
    en, ko = strings("en"), strings("ko")
    assert en["ov.reason.creditUsedUp"] == "No credit on the API key"
    assert not ko["ov.reason.creditUsedUp"].isascii()


# ── the details page's answer ─────────────────────────────────────────────────
@pytest.mark.parametrize("word", ["api", "sdk"])
def test_the_lane_s_details_are_dormant_by_the_refusal_with_the_card_s_reason_and_time(xdg, stub_sala, world, word):
    write_record(xdg, json.dumps({"refused_at": EPOCH, "by": "briefing", "detail": "secret text"}))
    r = get(world, word)
    d = r.json()
    assert r.status_code == 200 and d["lane"] == "api" and d["error"] is None and d["state"] == REFUSED, d
    assert "secret text" not in r.text and "briefing" not in r.text
    with TestClient(world["app"]) as c:
        card = settled(c)
    assert card["dormant"] == {k: d["state"][k] for k in ("reason", "since")}, card


@pytest.mark.parametrize("row", ["api", "sdk"])
def test_sala_s_row_wins_on_the_details_page_and_is_answered_as_before(xdg, stub_sala, world, row):
    write_record(xdg, json.dumps({"refused_at": EPOCH}))
    record(world["rec"], (row, "dormant", "held by hand", "2026-01-06T00:00:00Z", "", "hand"))
    for word in ("api", "sdk"):
        assert get(world, word).json()["state"] == {"state": "dormant", "reason": "held by hand", "since": "2026-01-06T00:00:00Z"}


def test_the_refusal_says_nothing_of_another_lane_and_ends_with_the_record(xdg, stub_sala, world):
    p = write_record(xdg, json.dumps({"refused_at": EPOCH}))
    assert get(world, "subscription-1").json()["state"] == {"state": "active"}
    assert get(world, "aws-platform").json()["state"] == {"state": "not set up"}
    assert get(world, "api").json()["state"] == REFUSED
    p.unlink()   # a successful key call removes it
    assert get(world, "api").json()["state"] == {"state": "active"}


def test_the_refusal_shows_when_sala_cannot_print_its_table(xdg, stub_sala, world):
    write_record(xdg, json.dumps({"refused_at": EPOCH}))
    stub_sala.mode("fail")
    d = get(world, "api").json()
    assert d["record"] is None and d["error"] == "sala exited 1" and d["state"] == REFUSED, d


def test_the_new_session_form_still_offers_the_lane_under_a_refusal_alone(xdg, env):
    # why the details page does not say "The New session form does not offer it." for a refusal: it does offer it
    write_record(xdg, json.dumps({"refused_at": EPOCH}))
    c = env["client"]
    assert "api" in c.get("/api/spawn/options").json()["lanes"]
    r = c.post("/api/spawn", json={**GOOD, "lane": "api"})
    assert r.status_code == 202, r.text
    (sent,) = env["sala"].spawns()
    assert sent["argv"][sent["argv"].index("--lane") + 1] == "api", sent


# ── the details page, drawn ───────────────────────────────────────────────────
DORMANT_READY = "document.querySelector('#ld-title .lane-chip-dormant') && document.querySelector('#ld-usage .q-dormant-line')"


@pytest.mark.parametrize("word", ["api", "sdk"])
def test_the_page_shows_the_refusal_in_english_and_korean_without_the_form_line(xdg, stub_sala, world, page, browser, word):
    write_record(xdg, json.dumps({"refused_at": EPOCH}))
    p = open_lane(browser, page(), f"#lane={word}", ready=DORMANT_READY)
    assert p["chip"] == "dormant" and "lane-chip-dormant" in p["chipCls"] and p["headPills"] == 1, p
    assert p["line"] == "" and not p["lineShown"], p
    assert p["usage"]["dormant"] == ["No credit on the API key since Mon Jan 5th"], p["usage"]
    assert NOT_OFFERED not in browser.evaluate("document.querySelector('#ld').textContent")
    ko = strings("ko")
    browser.evaluate("SalaI18n.setLang('ko'); ''")
    reason = json.dumps(ko["ov.reason.creditUsedUp"])
    assert wait_for(browser, f"(document.querySelector('#ld-usage .q-dormant-line') || {{}}).textContent?.startsWith({reason})")
    k = browser.evaluate(LANE_PAGE)
    assert k["chip"] == ko["ov.chip.dormant"] and k["line"] == "" and not k["lineShown"], k
    assert ko["ov.lane.dormantPerUse"] not in browser.evaluate("document.querySelector('#ld').textContent")
    assert "credit used up" not in k["usage"]["text"] and "No credit" not in k["usage"]["text"], k["usage"]


def test_the_page_of_a_row_in_sala_s_record_still_says_the_form_line(xdg, stub_sala, world, page, browser):
    write_record(xdg, json.dumps({"refused_at": EPOCH}))
    record(world["rec"], ("api", "dormant", "credit used up", "2026-01-05T20:30:00Z", "", "signal"))   # 00:30 +04 the next day
    for word in ("api", "sdk"):
        p = open_lane(browser, page(), f"#lane={word}", ready=DORMANT_READY)
        assert p["chip"] == "dormant" and p["line"] == NOT_OFFERED, p
        assert p["usage"]["dormant"] == ["No credit on the API key since Tue Jan 6th"], p["usage"]
