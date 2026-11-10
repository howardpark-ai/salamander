"""The dormant record on the web side (salamander lib/common.sh "THE DORMANT RECORD"): sala keeps one record per
lane in lane-state.tsv, and this app only reads it. A dormant lane's Overview card keeps its head (the lane pill; its
plan name is on the details page) with ONE line under it ("No seat since Mon Jan 5th") and nothing is asked for it, the New session form leaves the lane out, and a usage check that Anthropic
refuses (HTTP 403) is saved as errorKind "refused", the signal sala's watch reads for the Team lane.

What a wrong answer costs here is a usage check made for a lane that cannot answer it (a request for nothing, or a refusal
that starts a back-off), a card that still draws bars for a lane sala says is gone, or a lane offered in the form that sala
then refuses. Every credentials file is a fake in tmp_path and the usage endpoint and the Admin API are never called: each
test replaces the fetch. The card is checked in a headless Chromium when one is installed (conftest.py: `served`'s sibling
fixtures, `browser`), else that test is skipped."""

from __future__ import annotations

import json
import socket
import threading
import time

import pytest
from starlette.testclient import TestClient

from sala_web import credit as CR
from sala_web import lanestate as LS
from sala_web import quota as Q
from sala_web import sessions as S
from sala_web import swr as SWR
from sala_web.app import create_app
from sala_web.config import Settings
from test_new_session import GOOD, env, sala  # noqa: F401  (fixtures: the form with sala's stand-in)
from test_credit import wait_for  # noqa: F401

TOKEN = "[masked secret]"
USAGE = {"limits": [{"kind": "session", "percent": 12, "severity": "normal", "resets_at": "2026-10-14T10:10:00Z"}]}
SINCE = "2026-01-05T03:00:00Z"   # 07:00 +04 Mon Jan 5th


def creds(d, sub="max", tier="tier_a_20x"):
    d.mkdir(parents=True, exist_ok=True)
    (d / ".credentials.json").write_text(json.dumps({"claudeAiOauth": {
        "accessToken": TOKEN, "refreshToken": "fake-refresh", "expiresAt": int((time.time() + 3600) * 1000),
        "subscriptionType": sub, "rateLimitTier": tier}}))


def record(path, *rows):
    """sala's lane-state.tsv: lane, state, reason, since, posted, by."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join("\t".join(r) + "\n" for r in rows))


@pytest.fixture
def world(tmp_path, monkeypatch):
    claude, team = tmp_path / "claude", tmp_path / "claude-team"
    (claude / "sessions").mkdir(parents=True)
    creds(claude)
    creds(team, sub="team", tier="tier_b")
    monkeypatch.setattr(S, "LANE_DIRS", {"subscription-2": team})
    monkeypatch.setattr(S, "live_tmux_names", lambda: {})
    sala_state = tmp_path / "sala-state"
    sala_state.mkdir()
    # sala's names for the lanes (`sala lane names --json` writes the same table to this file): the pills read them
    (sala_state / "lane-names.json").write_text(json.dumps({"lanes": [
        {"code": "subscription-1", "display": "Ultra", "aliases": ["max"]}, {"code": "subscription-2", "display": "Team", "aliases": ["team"]}]}))
    key = tmp_path / "admin-key"
    key.write_text("admin-key-not-real")
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                        tmux_socket_name="salaweb-pytest-none", roles_cmd=["false"], sala_models=tmp_path / "none.tsv",
                        sala_state_dir=sala_state, admin_key=key)
    app = create_app(settings)
    calls, spend = [], []
    app.state.quota.fetch = lambda token: calls.append(token) or USAGE
    monkeypatch.setattr(CR, "compute", lambda k, fetch, now: spend.append(k) or {
        "todayUsd": 1.0, "monthUsd": 2.0, "consoleUrl": CR.CONSOLE_URL, "unpriced": [], "estimatedFrom": None,
        "monthEstimatedUsd": 0, "usageThrough": None})
    return {"app": app, "settings": settings, "calls": calls, "spend": spend, "rec": sala_state / "lane-state.tsv",
            "tmp": tmp_path, "state": tmp_path / "state"}


def quota_lanes(client):
    for _ in range(200):
        r = client.get("/api/quota")
        assert r.status_code == 200 and TOKEN not in r.text
        got = {x["lane"]: x for x in r.json()["lanes"]}
        if not any(x.get("refreshing") for x in got.values()):
            return got
        time.sleep(0.02)
    raise AssertionError("the quota refresh never landed")


# ── the record, read ─────────────────────────────────────────────────────────
def test_the_record_is_read_for_dormant_lanes_only(tmp_path):
    p = tmp_path / "lane-state.tsv"
    assert LS.dormant(p) == {}   # no file: every lane is active
    record(p, ("api", "dormant", "credit used up", SINCE, "", "signal"), ("bedrock", "active", "", SINCE, "", ""),
           ("subscription-2", "dormant", "no seat", SINCE, SINCE, "hand"))
    assert LS.dormant(p) == {"api": {"reason": "credit used up", "since": SINCE}, "subscription-2": {"reason": "no seat", "since": SINCE}}
    record(p, ("sdk", "dormant", "credit used up", SINCE, "", "signal"))
    assert list(LS.dormant(p)) == ["api"]   # sdk is the api lane's word
    p.write_text("junk\n\tdormant\tx\ty\n\ngarbage line without tabs\nmax\tdormant\n")
    assert LS.dormant(p) == {}   # odd lines read as active; nothing raises
    p.write_bytes(b"\xff\xfe\x00team\tdormant\tno seat\t" + SINCE.encode() + b"\n")
    LS.dormant(p)   # undecodable bytes: still no raise


# ── the card's data ──────────────────────────────────────────────────────────
def test_a_dormant_lane_is_a_head_and_one_line_and_is_asked_nothing(world):
    record(world["rec"], ("subscription-2", "dormant", "no seat", SINCE, "", "signal"))
    with TestClient(world["app"]) as c:
        got = quota_lanes(c)
    # the plan is the sign-in file's word, so the card keeps its head; nothing was asked for it
    assert got["subscription-2"] == {"lane": "subscription-2", "dormant": {"reason": "no seat", "since": SINCE}, "plan": "Team"}
    assert got["subscription-1"]["limits"] and "dormant" not in got["subscription-1"]
    assert world["calls"] == [TOKEN]                                   # max's check only
    assert not (world["state"] / "quota-subscription-2.json").exists()           # nothing cached for the dormant lane
    assert world["calls"].count(TOKEN) == 1


def test_a_dormant_lane_without_a_readable_sign_in_has_no_plan_but_still_a_card(world):
    record(world["rec"], ("subscription-2", "dormant", "no seat", SINCE, "", "signal"))
    creds_file = world["tmp"] / "claude-team" / ".credentials.json"
    for body in ("not json {", json.dumps({"claudeAiOauth": None}), json.dumps([1]), None):
        if body is None:
            creds_file.unlink()
        else:
            creds_file.write_text(body)
        with TestClient(world["app"]) as c:
            got = quota_lanes(c)
        assert got["subscription-2"] == {"lane": "subscription-2", "dormant": {"reason": "no seat", "since": SINCE}}, body
    creds(world["tmp"] / "claude-team", sub="team", tier="tier_b")
    creds_file.write_text(json.dumps({"claudeAiOauth": {"accessToken": TOKEN, "expiresAt": 1000,   # long expired
                                                         "subscriptionType": "team", "rateLimitTier": "tier_b"}}))
    with TestClient(world["app"]) as c:
        assert quota_lanes(c)["subscription-2"]["plan"] == "Team"                 # an expired token still names the plan
    assert not (world["state"] / "quota-subscription-2.json").exists()            # and the lane's cache was never touched


def test_it_asks_again_the_moment_the_lane_is_active(world):
    record(world["rec"], ("subscription-2", "dormant", "no seat", SINCE, "", "signal"))
    with TestClient(world["app"]) as c:
        quota_lanes(c)
        assert len(world["calls"]) == 1
        record(world["rec"], ("subscription-2", "active", "", "2026-01-06T01:00:00Z", "", ""))   # the record says active again
        got = quota_lanes(c)
    assert "dormant" not in got["subscription-2"] and got["subscription-2"]["limits"] and len(world["calls"]) == 2


def test_the_api_answer_keeps_its_spend_beside_the_dormant_record(world):
    # a dormant per-use lane still shows the period's spend. The Admin API is read as when active (a cost-report read with
    # the admin key, not the inference key that has no credit); the answer gains lane and dormant and keeps every figure
    record(world["rec"], ("api", "dormant", "credit used up", SINCE, "", "signal"))
    with TestClient(world["app"]) as c:
        c.get("/api/credit")
        for _ in range(100):
            if world["spend"]:
                break
            time.sleep(0.05)
        time.sleep(0.2)
        r = c.get("/api/credit").json()
        assert world["spend"] == ["admin-key-not-real"]
        assert r["lane"] == "api" and r["dormant"] == {"reason": "credit used up", "since": SINCE}, r
        assert r["monthUsd"] == 2.0 and r["todayUsd"] == 1.0, r
        record(world["rec"], ("api", "active", "", "2026-01-06T01:00:00Z", "", ""))
        r = c.get("/api/credit").json()
    assert "dormant" not in r and "lane" not in r and r["monthUsd"] == 2.0       # active again: the answer as it always was


def test_a_dormant_api_lane_whose_admin_read_fails_has_a_reason_and_no_figures(world, monkeypatch):
    def refuse(k, fetch, now):
        raise RuntimeError("Admin API answered HTTP 401")
    monkeypatch.setattr(CR, "compute", refuse)
    record(world["rec"], ("api", "dormant", "credit used up", SINCE, "", "signal"))
    with TestClient(world["app"]) as c:
        c.get("/api/credit")
        for _ in range(100):
            r = c.get("/api/credit").json()
            if r.get("error"):
                break
            time.sleep(0.05)
    assert r["dormant"]["reason"] == "credit used up" and r["error"] == "Admin API answered HTTP 401" and "monthUsd" not in r, r


def test_the_sdk_word_hides_the_api_card_too(world):
    record(world["rec"], ("sdk", "dormant", "credit used up", SINCE, "", "signal"))
    with TestClient(world["app"]) as c:
        assert c.get("/api/credit").json()["dormant"]["reason"] == "credit used up"


# ── a refused usage check is the Team signal ─────────────────────────────────
def test_a_403_is_a_refusal_saved_for_sala_to_read(world, monkeypatch):
    def refused(token):
        world["calls"].append(token)
        raise Q.Refused()

    world["app"].state.quota.fetch = refused
    with TestClient(world["app"]) as c:
        got = quota_lanes(c)
    assert got["subscription-2"]["errorKind"] == "refused" and got["subscription-2"]["error"] == Q.REFUSED
    saved = json.loads((world["state"] / "quota-subscription-2.json").read_text())
    assert saved["errorKind"] == "refused" and "nextTry" in saved and TOKEN not in json.dumps(saved)   # the file sala's watch reads
    assert abs(got["subscription-2"]["nextTry"] / 1000 - (time.time() + SWR.BACKOFF[0])) < 5                   # and it backs off like a refusal


def test_fetch_usage_maps_403_to_refused_and_keeps_401_as_expired(monkeypatch):
    import urllib.error

    def status(code):
        def f(req, timeout):
            raise urllib.error.HTTPError(req.full_url, code, "x", {}, None)
        return f

    monkeypatch.setattr(Q.urllib.request, "urlopen", status(403))
    with pytest.raises(Q.Refused):
        Q.fetch_usage("t0k")
    monkeypatch.setattr(Q.urllib.request, "urlopen", status(401))
    with pytest.raises(Q.Unauthorized):
        Q.fetch_usage("t0k")


# ── the New session form ─────────────────────────────────────────────────────
def test_the_form_leaves_a_dormant_lane_out_and_refuses_it(env):
    c, sala_ = env["client"], env["sala"]
    assert c.get("/api/spawn/options").json()["lanes"] == ["subscription-1", "subscription-2", "api", "bedrock", "aws-platform"]
    record(env["settings"].sala_state_dir / "lane-state.tsv", ("subscription-2", "dormant", "no seat", SINCE, "", "signal"),
           ("sdk", "dormant", "credit used up", SINCE, "", "signal"))
    assert c.get("/api/spawn/options").json()["lanes"] == ["subscription-1", "bedrock", "aws-platform"]     # team, and api by its sdk word
    r = c.post("/api/spawn", json={**GOOD, "lane": "subscription-2"})
    assert r.status_code == 400 and "lane must be one of subscription-1, bedrock, aws-platform" in r.json()["error"]
    assert sala_.spawns() == []                                        # nothing reached sala
    record(env["settings"].sala_state_dir / "lane-state.tsv", ("subscription-2", "active", "", SINCE, "", ""))
    assert c.get("/api/spawn/options").json()["lanes"] == ["subscription-1", "subscription-2", "api", "bedrock", "aws-platform"]
    record(env["settings"].sala_state_dir / "lane-state.tsv", ("aws-platform", "dormant", "no workspace", SINCE, "", "hand"))
    assert c.get("/api/spawn/options").json()["lanes"] == ["subscription-1", "subscription-2", "api", "bedrock"]           # a lane id from the table needs nothing more


# ── the card on the page ─────────────────────────────────────────────────────
CARDS = """(() => [...document.querySelectorAll("#q-cards > *")].map((c) => ({
  cls: c.className, text: c.textContent.trim(), bars: c.querySelectorAll(".q-bar, [role=progressbar]").length,
  rows: c.querySelectorAll(".q-row").length, h: Math.round(c.getBoundingClientRect().height),
  w: Math.round(c.getBoundingClientRect().width), right: c.getBoundingClientRect().right,
  pills: [...c.querySelectorAll(".q-head .sp-pill:not(.lane-chip)")].map((p) => p.textContent.trim()),
  plan: (c.querySelector(".q-head .q-plan") || {}).textContent || null,
  line: (c.querySelector(".q-dormant-line") || {}).textContent || null,
  chips: [...c.querySelectorAll(".q-head .lane-chip")].map((x) => x.textContent),
  chipCls: (c.querySelector(".q-head .lane-chip") || {}).className || null,
  chipLeftOfDetails: (() => { const ch = c.querySelector(".q-head .lane-chip"), d = c.querySelector(".q-head .q-details");
    return !!ch && !!d && ch.nextElementSibling === d && ch.getBoundingClientRect().right <= d.getBoundingClientRect().left + 0.5; })(),
  headBottom: c.querySelector(".q-head") ? c.querySelector(".q-head").getBoundingClientRect().bottom : null,
  lineTop: c.querySelector(".q-dormant-line") ? c.querySelector(".q-dormant-line").getBoundingClientRect().top : null,
  billing: !!c.querySelector(".c-bill") })))()"""


@pytest.fixture
def page(world):
    import uvicorn

    servers = []

    def start():
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        server = uvicorn.Server(uvicorn.Config(world["app"], host="127.0.0.1", port=port, log_level="warning"))
        t = threading.Thread(target=server.run, daemon=True)
        t.start()
        for _ in range(100):
            if server.started:
                break
            time.sleep(0.05)
        assert server.started
        servers.append((server, t))
        return f"http://127.0.0.1:{port}"

    yield start
    for server, t in servers:
        server.should_exit = True
        t.join(timeout=10)


def open_overview(browser, url, width=390):
    browser.width, browser.height = width, 844
    browser.open(f"{url}/#sessions")
    if width <= 760:   # a phone folds the lane cards into one chip strip: a tap opens them
        assert wait_for(browser, "document.readyState !== 'loading' && !!document.getElementById('q-strip') && getComputedStyle(document.getElementById('q-strip')).display !== 'none'")
        browser.evaluate("if (!document.getElementById('quota').classList.contains('q-open')) document.getElementById('q-strip').click(); ''")
        assert wait_for(browser, "document.getElementById('quota').classList.contains('q-open')")


def test_the_overview_keeps_the_head_of_a_dormant_team_lane_with_one_line_under_it(world, page, browser):
    record(world["rec"], ("subscription-2", "dormant", "no seat", SINCE, "", "signal"))
    open_overview(browser, page())
    assert wait_for(browser, "document.querySelectorAll('#q-cards > *').length >= 3 && !document.querySelector('#q-cards .q-pending')")
    cards = browser.evaluate(CARDS)
    team = next(c for c in cards if "lane-subscription-2" in c["cls"])
    assert team["pills"] == ["team"] and team["plan"] is None, team                        # the head an active card has: the pill; the plan name is the details page's
    assert team["line"] == "No seat since Mon Jan 5th", team
    assert team["lineTop"] >= team["headBottom"], team                                     # the line is under the head
    # the head's link to the lane's page; the last line is the card's "updated" line: this lane never
    # answered, so there is no good reading to date, and the card says so rather than a time
    assert team["text"].replace("⋮⋮", "") == "teamdormantDetails ›No seat since Mon Jan 5thupdated unknown", team
    assert team["bars"] == 0 and team["rows"] == 0 and "q-dormant" in team["cls"]          # no bars, no rows
    assert team["right"] <= 390 and team["h"] < 110, team                                  # a phone fits it, and it is short (head, the reason, the updated line)
    assert team["chips"] == ["dormant"] and "lane-chip-dormant" in team["chipCls"] and team["chipLeftOfDetails"], team
    mx = next(c for c in cards if "lane-subscription-1" in c["cls"])
    assert mx["chips"] == ["active"] and "lane-chip-active" in mx["chipCls"] and mx["chipLeftOfDetails"], mx
    assert mx["rows"] >= 1 and "dormant" not in mx["text"].lower(), mx                      # Max is a full card
    assert mx["pills"] == ["ultra"] and mx["plan"] is None, mx                                # with the same head shape
    assert world["calls"].count(TOKEN) == 1                                                 # one check, for Max only


def test_a_dormant_team_card_without_a_plan_still_has_its_pill(world, page, browser):
    record(world["rec"], ("subscription-2", "dormant", "no seat", SINCE, "", "signal"))
    (world["tmp"] / "claude-team" / ".credentials.json").write_text("garbage")
    open_overview(browser, page())
    assert wait_for(browser, "[...document.querySelectorAll('#q-cards > *')].some((c) => c.textContent.includes('dormant'))")
    team = next(c for c in browser.evaluate(CARDS) if "lane-subscription-2" in c["cls"])
    assert team["pills"] == ["team"] and team["plan"] is None and team["line"] == "No seat since Mon Jan 5th", team


def test_the_overview_shows_the_api_card_with_its_spend_and_the_reason(world, page, browser):
    record(world["rec"], ("api", "dormant", "credit used up", "2026-01-05T20:30:00Z", "", "signal"))   # 00:30 +04 the next day
    open_overview(browser, page())
    assert wait_for(browser, "[...document.querySelectorAll('#q-cards > *')].some((c) => c.textContent.includes('dormant') && c.textContent.includes('This month'))"
                    " && !document.querySelector('#q-cards .c-card.q-pending')")
    cards = browser.evaluate(CARDS)
    api = next(c for c in cards if c["line"] and "lane-api" in c["cls"])
    assert api["pills"] == ["metered", "sdk"] and api["plan"] is None, api                  # the active API card's head
    assert api["line"] == "No credit on the API key since Tue Jan 6th", api                 # the reason stays; the day is the configured zone's
    assert api["lineTop"] >= api["headBottom"], api                                         # under the head
    assert api["chips"] == ["dormant"] and api["bars"] == 0 and not api["billing"], api     # no Billing link on the Overview card
    assert "Spent today" in api["text"] and "This month" in api["text"] and "$2.00" in api["text"] and "$1.00" in api["text"], api   # the figures
    assert world["spend"] == ["admin-key-not-real"]


def test_a_dormant_api_card_whose_figures_cannot_be_read_says_usage_unavailable(world, page, browser, monkeypatch):
    def refuse(k, fetch, now):
        raise RuntimeError("Admin API answered HTTP 401")
    monkeypatch.setattr(CR, "compute", refuse)
    record(world["rec"], ("api", "dormant", "credit used up", "2026-01-05T20:30:00Z", "", "signal"))   # 00:30 +04 the next day
    open_overview(browser, page())
    assert wait_for(browser, "[...document.querySelectorAll('#q-cards > *')].some((c) => c.textContent.includes('Usage unavailable'))")
    api = next(c for c in browser.evaluate(CARDS) if "lane-api" in c["cls"])
    assert api["line"] == "No credit on the API key since Tue Jan 6th" and api["chips"] == ["dormant"], api
    assert "Usage unavailable" in api["text"] and "Admin API answered HTTP 401" in api["text"] and "This month" not in api["text"], api


def test_the_overview_comes_back_to_full_cards_when_the_record_says_active(world, page, browser):
    record(world["rec"], ("subscription-2", "dormant", "no seat", SINCE, "", "signal"))
    open_overview(browser, page())
    assert wait_for(browser, "[...document.querySelectorAll('#q-cards > *')].some((c) => c.textContent.includes('dormant'))")
    record(world["rec"], ("subscription-2", "active", "", "2026-01-06T01:00:00Z", "", ""))
    browser.evaluate("document.dispatchEvent(new Event(\"visibilitychange\"))")             # the page refreshes when it is shown again; ask now
    assert wait_for(browser, "![...document.querySelectorAll('#q-cards > *')].some((c) => c.textContent.includes('dormant'))")
    cards = browser.evaluate(CARDS)
    assert next(c for c in cards if "lane-subscription-2" in c["cls"])["rows"] >= 1


# ── the status chip ──────────────────────────────────────────────
CHIPS_READY = "document.querySelectorAll('#q-cards .lane-chip:not(.lane-chip-pending)').length >= 3 && !document.querySelector('#q-cards .q-pending')"
FRI = "2026-01-05T20:30:00Z"   # 00:30 +04 Tue Jan 6th


def card_of(cards, lane):
    return next(c for c in cards if f"lane-{lane}" in c["cls"])


def test_the_chip_words_the_page_reads_are_the_servers_own_words():
    """The card tells "no sign-in file" and "no Admin API key" from the answers' error text; if either server string is
    reworded the lane would read Active, so the page's list and the two constants are held together here."""
    from pathlib import Path

    js = (Path(__file__).resolve().parent.parent / "src" / "sala_web" / "static" / "sessions.js").read_text()
    words = json.loads(js.split("const NOT_CONFIGURED_WORDS = ", 1)[1].split(";", 1)[0])
    assert words == [Q.NO_SIGN_IN, CR.NO_KEY]
    en = (Path(__file__).resolve().parent.parent / "src" / "sala_web" / "static" / "i18n-en.js").read_text()
    assert '"ov.chip.unconfigured": "not configured"' in en and '"Not set up"' not in js and ': "Not set up"' not in en
    assert '"ov.chip.active": "active"' in en and '"ov.chip.dormant": "dormant"' in en


def test_a_working_lane_has_a_green_active_pill_left_of_details(world, page, browser):
    open_overview(browser, page())
    assert wait_for(browser, CHIPS_READY)
    cards = browser.evaluate(CARDS)
    for lane in ("subscription-1", "subscription-2", "api"):
        c = card_of(cards, lane)
        assert c["chips"] == ["active"] and "lane-chip-active" in c["chipCls"] and c["chipLeftOfDetails"], c
        assert c["right"] <= 390, c
    ink = browser.evaluate("getComputedStyle(document.querySelector('#q-cards .lane-chip-active')).color.match(/\\d+/g).map(Number)")
    r, g, b = ink[:3]
    assert g > r and g > b, ink                                                              # green words; the pill itself: test_lane_status_pill.py


def test_an_expired_sign_in_is_still_an_active_lane(world, page, browser):
    creds_file = world["tmp"] / "claude-team" / ".credentials.json"
    creds_file.write_text(json.dumps({"claudeAiOauth": {"accessToken": TOKEN, "expiresAt": 1000,
                                                         "subscriptionType": "team", "rateLimitTier": "tier_b"}}))
    open_overview(browser, page())
    assert wait_for(browser, CHIPS_READY)
    team = card_of(browser.evaluate(CARDS), "subscription-2")
    assert team["chips"] == ["active"] and "sign-in expired" in team["text"], team


def test_a_lane_with_no_sign_in_file_is_not_configured(world, page, browser):
    (world["tmp"] / "claude-team" / ".credentials.json").unlink()
    open_overview(browser, page())
    assert wait_for(browser, CHIPS_READY)
    cards = browser.evaluate(CARDS)
    team = card_of(cards, "subscription-2")
    assert team["chips"] == ["not configured"] and "lane-chip-unconfigured" in team["chipCls"] and team["chipLeftOfDetails"], team
    assert card_of(cards, "subscription-1")["chips"] == ["active"]


def test_the_api_lane_with_no_admin_key_is_not_configured(world, page, browser):
    world["settings"].admin_key.unlink()
    open_overview(browser, page())
    assert wait_for(browser, CHIPS_READY)
    api = card_of(browser.evaluate(CARDS), "api")
    assert api["chips"] == ["not configured"] and api["chipLeftOfDetails"], api


def test_the_unconfigured_chip_is_unfilled_and_the_dormant_chip_is_filled(world, page, browser):
    record(world["rec"], ("api", "dormant", "credit used up", FRI, "", "signal"))
    (world["tmp"] / "claude-team" / ".credentials.json").unlink()
    open_overview(browser, page())
    assert wait_for(browser, CHIPS_READY)
    got = browser.evaluate("""(() => { const s = (k) => getComputedStyle(document.querySelector('#q-cards .lane-chip-' + k));
      return { un: { border: s('unconfigured').borderTopWidth, style: s('unconfigured').borderTopStyle, bg: s('unconfigured').backgroundColor,
                     dot: document.querySelectorAll('#q-cards .lane-chip-dot').length },
               dor: { bg: s('dormant').backgroundColor } }; })()""")
    assert got["un"]["style"] == "none" and got["un"]["border"] == "0px" and got["un"]["bg"] == "rgba(0, 0, 0, 0)" and got["un"]["dot"] == 0, got
    assert got["dor"]["bg"] != "rgba(0, 0, 0, 0)", got


@pytest.mark.parametrize("reason, line", [
    ("usage check refused", "Usage check refused since Tue Jan 6th"),
    ("credit used up", "No credit on the API key since Tue Jan 6th"),
    ("login no longer reports Max", "Login no longer reports Max since Tue Jan 6th"),
    ("", "Since Tue Jan 6th"),
])
def test_the_dormant_line_is_the_reason_as_a_sentence_and_the_day_without_the_word(world, page, browser, reason, line):
    record(world["rec"], ("subscription-2", "dormant", reason, FRI, "", "signal"))
    open_overview(browser, page())
    assert wait_for(browser, CHIPS_READY)
    team = card_of(browser.evaluate(CARDS), "subscription-2")
    assert team["line"] == line and team["chips"] == ["dormant"], team


def test_a_phone_keeps_the_chip_and_the_link_inside_the_head(world, page, browser):
    record(world["rec"], ("subscription-2", "dormant", "usage check refused", FRI, "", "signal"))
    open_overview(browser, page(), width=320)
    assert wait_for(browser, CHIPS_READY)
    got = browser.evaluate("""[...document.querySelectorAll('#q-cards > .q-card')].map((c) => { const h = c.querySelector('.q-head'), hr = h.getBoundingClientRect();
      const kids = [...h.children].map((k) => k.getBoundingClientRect());
      const ch = c.querySelector('.lane-chip').getBoundingClientRect(), d = c.querySelector('.q-details').getBoundingClientRect();
      return { inside: kids.every((r) => r.left >= hr.left - 1 && r.right <= hr.right + 1), text: c.textContent.slice(0, 40),
               sameRow: Math.abs(ch.top + ch.height / 2 - (d.top + d.height / 2)) < 4, atEnd: hr.right - d.right < 4 }; })""")
    assert all(g["inside"] and g["sameRow"] and g["atEnd"] for g in got), got      # the pair wraps as one and keeps the right end
    assert browser.evaluate("document.documentElement.scrollWidth <= document.documentElement.clientWidth")   # no sideways scroll
