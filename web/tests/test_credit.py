"""GET /api/credit: what the API key (metered and sdk lanes) spent today and this month in the configured zone (Asia/Dubai here), from the Admin API's
cost report (complete UTC days, exact) and hourly usage report (the latest hours, estimated at calibrated rates).
Served at once from the last good answer, refreshed in the background (swr.py) and kept under the state dir.

The Admin API is a fake here; the real key file is never read. The card itself is checked in a headless Chromium
when one is installed (conftest.py: `browser`), else those tests are skipped."""

import json
import socket
import threading
import time
import urllib.error
from datetime import date, datetime, timedelta, timezone

import pytest
from starlette.testclient import TestClient

from sala_web import credit as CR
from sala_web import sessions as S
from sala_web import swr as SWR
from sala_web.app import create_app
from sala_web.config import Settings

KEY = "[masked Anthropic key]"
TOKEN = "[masked secret]"
OPUS = "claude-opus-5-5"


def day(ymd, results):
    d = date.fromisoformat(ymd)
    return {"starting_at": f"{d}T00:00:00Z", "ending_at": f"{d + timedelta(days=1)}T00:00:00Z", "results": results}


def hour(ymd, h, results):
    s = datetime.fromisoformat(f"{ymd}T{h:02d}:00:00+00:00")
    return {"starting_at": CR.iso(s), "ending_at": CR.iso(s + timedelta(hours=1)), "results": results}


def cost(model, ttype, cents, window="0-200k"):
    return {"currency": "USD", "amount": str(cents), "cost_type": "tokens", "model": model, "token_type": ttype,
            "context_window": window, "description": "x"}


def use(model, window="0-200k", unc=0, out=0, read=0, w5=0, w1=0, ws=0):
    return {"uncached_input_tokens": unc, "output_tokens": out, "cache_read_input_tokens": read,
            "cache_creation": {"ephemeral_5m_input_tokens": w5, "ephemeral_1h_input_tokens": w1},
            "server_tool_use": {"web_search_requests": ws}, "model": model, "context_window": window}


# Opus output at $20/M (0.002 cents a token), input $4/M, web search 1 cent each.
COST_DAYS = [
    day("2026-09-25", [cost(OPUS, "output_tokens", 99999)]),  # calibration range only: never in the month
    day("2026-09-30", [cost(OPUS, "output_tokens", 1000)]),   # the UTC day the zone's month starts in (20:00 UTC on)
    day("2026-10-14", [cost(OPUS, "output_tokens", 4000), cost(OPUS, "uncached_input_tokens", 400),
                       {"amount": "6", "cost_type": "web_search", "model": None, "token_type": None}]),
    day("2026-10-15", [cost(OPUS, "output_tokens", 4000)]),
]
USAGE_DAYS = [day("2026-09-25", [use(OPUS, out=1_000_000)]), day("2026-09-30", [use(OPUS, out=4_000_000)]),
              day("2026-10-14", [use(OPUS, unc=1_000_000, out=2_000_000, ws=6)]),
              day("2026-10-15", [use(OPUS, out=2_000_000)])]
HOURS = [
    hour("2026-09-30", 19, [use(OPUS, out=1_000_000)]),   # Dubai Sep 30 23:00: last month; a quarter of the day's $10
    hour("2026-09-30", 20, [use(OPUS, out=3_000_000)]),   # Dubai Oct 1 00:00: this month, $7.50
    # Oct 14 has no hourly buckets: its $44.06 is shared evenly over its hours, all of them this month
    hour("2026-10-15", 19, [use(OPUS, out=1_000_000)]),   # Dubai Oct 15 23:00: half of the day's $40
    hour("2026-10-15", 20, [use(OPUS, out=1_000_000)]),   # Dubai Oct 16 00:00: the next day there, the other $20
    hour("2026-10-16", 0, [use(OPUS, out=500_000, ws=2)]),  # not in the cost report yet: estimated, $10.02
    hour("2026-10-16", 1, [use(OPUS, w1=1000), use("claude-haiku-5-5", out=10)]),  # no rate: counted as unpriced
    hour("2026-10-16", 2, []),
    hour("2026-10-16", 19, [use(OPUS, out=1_000_000)]),   # Dubai Oct 16 23:00
    hour("2026-10-16", 20, [use(OPUS, out=500_000)]),     # Dubai Oct 17 00:00
]


class FakeAdmin:
    def __init__(self):
        self.calls = []

    def __call__(self, key, path, params):
        assert key == KEY
        self.calls.append((path, dict(params)))
        if path == CR.COST_PATH:
            # two pages, to follow next_page
            if params.get("page") == "p2":
                return {"data": COST_DAYS[2:], "has_more": False, "next_page": None}
            return {"data": COST_DAYS[:2], "has_more": True, "next_page": "p2"}
        if params["bucket_width"] == "1d":
            return {"data": USAGE_DAYS, "has_more": False, "next_page": None}
        return {"data": HOURS, "has_more": False, "next_page": None}


def at(s):
    return datetime.fromisoformat(s).astimezone(timezone.utc)


def test_spent_today_and_this_month_in_the_configured_zone():
    got = CR.compute(KEY, FakeAdmin(), at("2026-10-16T03:30:00+00:00"))  # Dubai Fri Oct 16 07:30
    assert got["today"] == "2026-10-16" and got["month"] == "2026-10"
    assert got["todayUsd"] == 30.02          # Oct 15 20:00 UTC ($20, exact) + Oct 16 00:00 UTC ($10.02, estimated)
    assert got["todayEstimatedUsd"] == 10.02
    assert got["monthUsd"] == 101.58         # 7.50 + 44.06 + 40 + 10.02
    assert got["monthEstimatedUsd"] == 10.02
    assert got["estimatedFrom"] == "2026-10-16T00:00:00Z"  # the latest hours, which the cost report lacks
    assert got["usageThrough"] == "2026-10-16T03:00:00Z"   # the running hour left out
    assert got["exactThrough"] == "2026-10-16T00:00:00Z"
    assert got["calibratedOn"] == "2026-10-15"
    assert got["unpriced"] == [
        {"model": OPUS, "type": "cache_creation.ephemeral_1h_input_tokens", "count": 1000},
        {"model": "claude-haiku-5-5", "type": "output_tokens", "count": 10},
    ]
    assert got["consoleUrl"] == CR.CONSOLE_URL
    # the promotional credit's fields are gone
    for k in ("leftUsd", "anchor", "grants", "spentExactUsd", "spentEstimatedUsd"):
        assert k not in got


def test_an_hour_from_20_utc_is_the_next_day_in_the_zone():
    # Dubai Sat Oct 17 01:30: today began at Oct 16 20:00 UTC, so only that hour ($10) is today; 19:00 UTC is yesterday
    got = CR.compute(KEY, FakeAdmin(), at("2026-10-16T21:30:00+00:00"))
    assert got["today"] == "2026-10-17"
    assert got["todayUsd"] == 10.0 and got["todayEstimatedUsd"] == 10.0
    assert got["monthUsd"] == 131.58 and got["monthEstimatedUsd"] == 40.02
    # a minute before midnight there it is still Oct 16 (the 19:00 UTC hour is still running, so not counted yet)
    got = CR.compute(KEY, FakeAdmin(), at("2026-10-16T19:59:00+00:00"))
    assert got["today"] == "2026-10-16" and got["todayUsd"] == 30.02


def test_requests_and_paging():
    fake = FakeAdmin()
    CR.compute(KEY, fake, at("2026-10-16T03:30:00+00:00"))
    paths = [c[0] for c in fake.calls]
    assert paths.count(CR.COST_PATH) == 2  # followed next_page
    first = fake.calls[0][1]
    # the month began Sep 30 20:00 UTC in the zone; a week before that day is fetched to calibrate
    assert first["starting_at"] == "2026-09-23T00:00:00Z" and first["group_by[]"] == ["description"]
    hourly = [c[1] for c in fake.calls if c[1].get("bucket_width") == "1h"]
    assert hourly[0]["starting_at"] == "2026-09-30T00:00:00Z"  # the whole first UTC day, to share its cost out
    assert hourly[0]["group_by[]"] == ["model", "context_window"]


def test_calibration_takes_each_key_from_its_latest_day():
    days = {
        date(2026, 10, 12): [cost(OPUS, "output_tokens", 100)],
        date(2026, 10, 13): [cost(OPUS, "output_tokens", 300), cost("m2", "output_tokens", 0)],
    }
    usage = {
        date(2026, 10, 12): [use(OPUS, out=100)],
        date(2026, 10, 13): [use(OPUS, out=100), use("m2", out=50)],
    }
    rates, latest = CR.calibrate(days, usage)
    assert rates == {(OPUS, "0-200k", "output_tokens"): 3.0}  # a zero amount gives no rate
    assert latest == date(2026, 10, 13)


# the server: answered at once, refreshed in the background, one upstream refresh per 15 minutes, kept on disk

@pytest.fixture
def env(tmp_path):
    key = tmp_path / "anthropic" / "admin-key"
    key.parent.mkdir()
    key.write_text(KEY + "\n")
    app = create_app(Settings(claude_dir=tmp_path / "claude", state_dir=tmp_path / "state", admin_key=key))
    fake = FakeAdmin()
    app.state.credit.fetch = fake
    return app, fake, key, tmp_path / "state" / "api-spend.json"


def credit(client):
    """The answer once no background refresh runs."""
    for _ in range(250):
        r = client.get("/api/credit")
        assert r.status_code == 200
        assert KEY not in r.text and "FAKE" not in r.text
        got = r.json()
        if not got.get("refreshing"):
            return got
        time.sleep(0.02)
    raise AssertionError("the refresh never landed")


def test_first_start_answers_at_once_then_fills(env):
    app, fake, _, saved = env
    with TestClient(app) as c:
        first = c.get("/api/credit").json()
        assert first["pending"] is True and first["refreshing"] is True and first["fetchedAt"] is None
        assert first["consoleUrl"] == CR.CONSOLE_URL and "todayUsd" not in first
        got = credit(c)
    assert isinstance(got["todayUsd"], float) and isinstance(got["fetchedAt"], int)
    assert "pending" not in got and "error" not in got
    on_disk = saved.read_text()
    assert KEY not in on_disk and "FAKE" not in on_disk and "x-api-key" not in on_disk
    assert json.loads(on_disk)["todayUsd"] == got["todayUsd"]
    assert oct(saved.stat().st_mode & 0o777) == oct(0o600)


def test_at_most_one_upstream_refresh_per_15_minutes(env, monkeypatch):
    app, fake, *_ = env
    with TestClient(app) as c:
        credit(c)
        n = len(fake.calls)
        assert n > 0
        now = time.monotonic()
        # many viewers over the next 15 minutes: one refresh in all
        for minute in range(0, 15):
            monkeypatch.setattr(SWR.time, "monotonic", lambda m=minute: now + m * 60)
            for _ in range(3):
                credit(c)
        assert len(fake.calls) == n
        monkeypatch.setattr(SWR.time, "monotonic", lambda: now + CR.TTL + 1)
        for _ in range(5):
            credit(c)
    assert len(fake.calls) == 2 * n


def test_a_restart_serves_the_saved_answer_and_refreshes_in_the_background(env):
    app, fake, key, saved = env
    old = {"today": "2026-10-15", "month": "2026-10", "todayUsd": 1.0, "monthUsd": 2.0, "todayEstimatedUsd": 0,
           "monthEstimatedUsd": 0, "estimatedFrom": None, "consoleUrl": CR.CONSOLE_URL,
           "fetchedAt": int((time.time() - 3600) * 1000)}
    SWR.write_atomic(saved, old)
    gate = threading.Event()

    def slow(k, path, params):
        assert gate.wait(10)
        return fake(k, path, params)

    app2 = create_app(app.state.settings)
    app2.state.credit.fetch = slow
    try:
        with TestClient(app2) as c:
            t0 = time.monotonic()
            got = c.get("/api/credit").json()
            assert time.monotonic() - t0 < 1  # never waits on the Admin API
            assert got["todayUsd"] == 1.0 and got["fetchedAt"] == old["fetchedAt"] and got["refreshing"] is True
            assert c.get("/api/credit").json()["todayUsd"] == 1.0  # a second ask while it runs: no second refresh
            gate.set()
            fresh = credit(c)
        assert fresh["todayUsd"] != 1.0 and fresh["fetchedAt"] > old["fetchedAt"]
        assert json.loads(saved.read_text())["fetchedAt"] == fresh["fetchedAt"]  # the stale answer replaced on disk
        assert [p for p, _ in fake.calls].count(CR.COST_PATH) == 2  # one refresh (its two pages)
    finally:
        gate.set()


def test_a_restart_with_a_fresh_saved_answer_asks_nobody(env):
    app, fake, key, saved = env
    SWR.write_atomic(saved, {"todayUsd": 3.0, "monthUsd": 4.0, "fetchedAt": int(time.time() * 1000)})
    app2 = create_app(app.state.settings)
    app2.state.credit.fetch = fake
    with TestClient(app2) as c:
        got = c.get("/api/credit").json()
    assert got["todayUsd"] == 3.0 and "refreshing" not in got and fake.calls == []


def test_error_keeps_the_last_answer_and_retries_a_minute_later(env, monkeypatch):
    app, fake, *_ = env
    with TestClient(app) as c:
        first = credit(c)

        def down(key, path, params):
            raise RuntimeError("Admin API answered HTTP 500")

        app.state.credit.fetch = down
        now = time.monotonic()
        monkeypatch.setattr(SWR.time, "monotonic", lambda: now + CR.TTL + 1)
        got = credit(c)
        assert got["error"] == "Admin API answered HTTP 500"
        assert got["todayUsd"] == first["todayUsd"] and got["fetchedAt"] == first["fetchedAt"]
        app.state.credit.fetch = fake
        monkeypatch.setattr(SWR.time, "monotonic", lambda: now + CR.TTL + 1 + CR.ERROR_RETRY + 1)
        got = credit(c)
    assert "error" not in got


def test_missing_key_is_a_plain_message(env):
    app, fake, key, saved = env
    key.unlink()
    with TestClient(app) as c:
        got = credit(c)
    assert got["error"] == "No Admin API key on this machine." and "todayUsd" not in got
    assert fake.calls == [] and not saved.exists()


def test_unexpected_error_never_carries_its_message(env):
    app, *_ = env

    def boom(key, path, params):
        raise KeyError(key)

    app.state.credit.fetch = boom
    with TestClient(app) as c:
        got = credit(c)
    assert got["error"] == "spend could not be read (KeyError)"


def test_fetch_admin_request_and_errors(monkeypatch):
    seen = {}

    class Resp:
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def read(self):
            return b'{"data": []}'

    def ok(req, timeout):
        seen.update(url=req.full_url, key=req.get_header("X-api-key"), ver=req.get_header("Anthropic-version"),
                    method=req.get_method())
        return Resp()

    monkeypatch.setattr(CR.urllib.request, "urlopen", ok)
    assert CR.fetch_admin(KEY, CR.COST_PATH, {"starting_at": "2026-10-13T00:00:00Z", "group_by[]": ["description"]}) \
        == {"data": []}
    assert seen["url"] == ("https://api.anthropic.com/v1/organizations/cost_report"
                           "?starting_at=2026-10-13T00%3A00%3A00Z&group_by%5B%5D=description")
    assert seen["key"] == KEY and seen["ver"] == "2023-06-01" and seen["method"] == "GET"
    assert KEY not in seen["url"]

    def status(req, timeout):
        raise urllib.error.HTTPError(req.full_url, 401, "x", {}, None)

    monkeypatch.setattr(CR.urllib.request, "urlopen", status)
    with pytest.raises(RuntimeError, match="HTTP 401") as e:
        CR.fetch_admin(KEY, CR.COST_PATH, {})
    assert KEY not in str(e.value)


# the page: one compact card for both lanes, all cards drawn in one pass, no layout shift

USAGE = {"limits": [
    {"kind": "session", "percent": 12, "severity": "normal", "resets_at": "2026-10-14T10:10:00Z"},
    {"kind": "weekly_all", "percent": 64.5, "severity": "warning", "resets_at": "2026-10-21T05:00:00Z"},
    {"kind": "weekly_scoped", "percent": 30, "severity": "normal", "resets_at": "2026-10-21T05:00:00Z",
     "scope": {"model": {"display_name": "Fable"}}},
]}


def spend(today, month, est=0.0, hours_ago=0):
    """An /api/credit answer, as compute would give it, with the latest hours estimated when est > 0."""
    now = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    return {"today": "2026-10-15", "month": "2026-10", "todayUsd": today, "monthUsd": month,
            "todayEstimatedUsd": est, "monthEstimatedUsd": est,
            "estimatedFrom": CR.iso(now - timedelta(hours=3)) if est else None,
            "exactThrough": CR.iso(now - timedelta(hours=4)), "usageThrough": CR.iso(now - timedelta(hours=1)),
            "calibratedOn": "2026-10-14", "unpriced": [], "consoleUrl": CR.CONSOLE_URL,
            "fetchedAt": int((time.time() - hours_ago * 3600) * 1000)}


def lane_creds(d, sub="max", tier="tier_a_20x"):
    d.mkdir(parents=True, exist_ok=True)
    (d / ".credentials.json").write_text(json.dumps({"claudeAiOauth": {
        "accessToken": TOKEN, "refreshToken": "fake-refresh", "expiresAt": int((time.time() + 3600) * 1000),
        "subscriptionType": sub, "rateLimitTier": tier}}))


@pytest.fixture
def page_app(tmp_path, monkeypatch):
    """start(saved=..., fresh=...) → the app on a loopback port, as after a restart: `saved` (an /api/credit answer
    and quota answers that old) on disk or none, upstream held at a gate until the test opens it."""
    import uvicorn

    claude, team = tmp_path / "claude", tmp_path / "claude-team"
    (claude / "sessions").mkdir(parents=True)
    lane_creds(claude)
    lane_creds(team, sub="team", tier="tier_b")
    monkeypatch.setattr(S, "LANE_DIRS", {"subscription-2": team})
    monkeypatch.setattr(S, "live_tmux_names", lambda: {})
    key = tmp_path / "admin-key"
    key.write_text(KEY)
    state = tmp_path / "state"
    gate, servers = threading.Event(), []
    box = {"fresh": spend(12.34, 456.78, est=1.25)}

    def gated_compute(k, fetch, now):
        assert k == KEY and gate.wait(20)
        return dict(box["fresh"])

    def gated_usage(token):
        assert token == TOKEN and gate.wait(20)
        return USAGE

    monkeypatch.setattr(CR, "compute", gated_compute)

    def start(saved_credit=None, saved_age_h=1.0):
        if saved_credit is not None:
            SWR.write_atomic(state / "api-spend.json", saved_credit)
            for lane, plan in (("subscription-1", "Max (20x)"), ("subscription-2", "Team")):
                SWR.write_atomic(state / f"quota-{lane}.json", {
                    "lane": lane, "plan": plan, "fetchedAt": int((time.time() - saved_age_h * 3600) * 1000),
                    "limits": [{"label": "Current session", "percent": 5, "severity": "normal", "resetsAt": "2026-10-14T10:10:00Z"},
                               {"label": "This week", "percent": 50, "severity": "normal", "resetsAt": "2026-10-21T05:00:00Z"},
                               {"label": "Fable this week", "percent": 20, "severity": "normal", "resetsAt": "2026-10-21T05:00:00Z"}]})
        settings = Settings(socket=tmp_path / "s.sock", state_dir=state, claude_dir=claude,
                            tmux_socket_name="salaweb-pytest-none", roles_cmd=["false"], sala_models=tmp_path / "none.tsv",
                            admin_key=key)
        app = create_app(settings)
        app.state.quota.fetch = gated_usage
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning"))
        t = threading.Thread(target=server.run, daemon=True)
        t.start()
        for _ in range(100):
            if server.started:
                break
            time.sleep(0.05)
        assert server.started
        servers.append((server, t))
        return f"http://127.0.0.1:{port}"

    yield {"start": start, "gate": gate, "state": state, "box": box}
    gate.set()
    for server, t in servers:
        server.should_exit = True
        t.join(timeout=10)


# every change of the grid's children, from the first: how many cards, which are placeholders, the grid's height
WATCH = """
window.__grid = [];
new MutationObserver(() => {
  const g = document.getElementById("q-cards");
  if (!g || !g.children.length) return;
  const sig = [...g.children].map((c) => c.className + "|" + c.textContent).join("\\n");
  if (window.__grid.length && window.__grid[window.__grid.length - 1].sig === sig) return;
  window.__grid.push({ sig, n: g.children.length, pending: g.querySelectorAll(".q-pending:not(.s-card)").length,
                       credit: g.querySelectorAll(".c-card:not(.s-card)").length, h: g.getBoundingClientRect().height });
}).observe(document, { childList: true, subtree: true, characterData: true });
"""
CARD = """(() => {
  const vw = document.documentElement.clientWidth, c = document.querySelector("#q-cards .c-card"), g = document.getElementById("q-cards");
  const r = c.getBoundingClientRect(), head = c.querySelector(".q-head");
  const bill = head.querySelector("a.c-bill");
  return { vw, docScroll: document.documentElement.scrollWidth, left: r.left, right: r.right, h: r.height,
           gridH: g.getBoundingClientRect().height, text: c.textContent, pending: c.classList.contains("q-pending"),
           pills: [...head.querySelectorAll(".sp-pill:not(.lane-chip)")].map((p) => p.className + "=" + p.textContent),
           title: (head.querySelector(".q-plan") || {}).textContent,
           bill: bill && { href: bill.href, text: bill.textContent, target: bill.target, right: bill.getBoundingClientRect().right },
           today: (c.querySelector(".c-today .c-v") || {}).textContent, month: (c.querySelector(".c-month .c-v") || {}).textContent,
           est: (c.querySelector(".c-est") || {}).textContent || null,
           bars: c.querySelectorAll(".q-bar, [role=progressbar]").length,
           footLines: Math.round(c.querySelector(".c-foot").getBoundingClientRect().height / parseFloat(getComputedStyle(c.querySelector(".c-foot")).lineHeight)),
           cards: g.children.length };
})()"""


def wait_for(browser, expr, timeout=15.0):
    end = time.time() + timeout
    while time.time() < end:
        if browser.evaluate(expr):
            return True
        time.sleep(0.1)
    return False


def open_overview(browser, url, width=390, height=844):
    browser.send("Page.enable")  # init scripts run only with the Page domain on
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": WATCH})
    browser.width, browser.height = width, height
    browser.open(f"{url}/#sessions")
    if width <= 760:   # a phone folds the lane cards into one chip strip: a tap opens them
        assert wait_for(browser, "document.readyState !== 'loading' && !!document.getElementById('q-strip') && getComputedStyle(document.getElementById('q-strip')).display !== 'none'")
        browser.evaluate("if (!document.getElementById('quota').classList.contains('q-open')) document.getElementById('q-strip').click(); ''")
        assert wait_for(browser, "document.getElementById('quota').classList.contains('q-open')")


def card(browser):
    return browser.evaluate(CARD)


def check_card(m, vw, today, month, max_h=130):
    assert m["vw"] == vw and m["docScroll"] <= vw, m       # no sideways scroll
    assert 0 <= m["left"] and m["right"] <= vw, m
    assert m["pills"] == ["sp-pill lane-api=metered", "sp-pill lane-sdk=sdk"], m
    assert m.get("title") is None, m                           # no plan name beside the pills on the Overview (the details page has it)
    assert m["bill"] is None, m                            # the Billing link is on the lane's details page, not here
    assert m["today"] == today and m["month"] == month, m
    assert "Spent today" in m["text"] and "This month" in m["text"], m
    # the promotional credit card's parts are gone
    assert m["bars"] == 0, m
    for gone in ("left", "granted", "Grants", "expires", "anchor", "Promotional", "exact"):
        assert gone not in m["text"], (gone, m["text"])
    assert m["footLines"] == 1, m  # one short card: the footnote never wraps
    assert m["h"] <= max_h, m


def test_card_shows_spend_for_both_lanes_on_phone_and_desktop(page_app, browser):
    fresh = spend(12.34, 456.78, est=1.25)
    url = page_app["start"](saved_credit=fresh, saved_age_h=0)
    page_app["gate"].set()
    open_overview(browser, url)
    assert wait_for(browser, "!!document.querySelector('#q-cards .c-card:not(.q-pending) .c-today')")
    m = card(browser)
    check_card(m, 390, "$12.34", "$456.78")
    # the latest hours are labelled as estimated, through the latest hour (in the zone)
    through = browser.evaluate(f"""new Intl.DateTimeFormat("en-US", {{ timeZone: "Asia/Dubai", hour: "numeric",
      minute: "2-digit" }}).format(new Date("{fresh['usageThrough']}"))""")
    assert m["est"] and m["est"].startswith("about $1.25 estimated from usage") and m["est"].endswith(through), m
    assert "updated " in m["text"] and "as of" not in m["text"], m
    browser.send("Emulation.setDeviceMetricsOverride", {"width": 1280, "height": 800, "deviceScaleFactor": 1, "mobile": False})
    assert wait_for(browser, "document.documentElement.clientWidth === 1280")
    wide = card(browser)
    # two cards to a row now (a card is at least 400px wide, so never three cramped ones): the grid stretches it to the quota cards' height
    check_card(wide, 1280, "$12.34", "$456.78", max_h=260)


def test_no_estimate_label_when_nothing_is_estimated(page_app, browser):
    url = page_app["start"](saved_credit=spend(1, 2, est=0), saved_age_h=0)
    page_app["gate"].set()
    open_overview(browser, url)
    assert wait_for(browser, "!!document.querySelector('#q-cards .c-card:not(.q-pending) .c-today')")
    m = card(browser)
    assert m["est"] is None and "estimated" not in m["text"] and m["today"] == "$1.00", m


def test_cold_restart_draws_every_card_at_once_without_a_shift(page_app, browser):
    # a restart with hour-old answers on disk, Anthropic held back: the page shows them at once, then the refresh
    stale = spend(1.11, 22.22, est=0.5, hours_ago=1)   # an estimate in both answers: its line (above the "updated" line) is the card's, shift or no shift
    url = page_app["start"](saved_credit=stale, saved_age_h=1)
    open_overview(browser, url)
    assert wait_for(browser, "!!document.querySelector('#q-cards .c-card:not(.q-pending) .c-today')", timeout=5)
    m = card(browser)
    assert m["today"] == "$1.11" and "as of " in m["text"] and m["cards"] == 5, m  # old: "as of" its time
    stale = "[...document.querySelectorAll('#q-cards .q-card:not(.c-card) .c-updated')].filter((f) => f.textContent.startsWith('as of '))"
    assert browser.evaluate(f"{stale}.length") == 2   # the two lane cards end with "as of 1 hour ago"
    before = browser.evaluate("JSON.stringify(document.getElementById('q-cards').getBoundingClientRect())")
    page_app["gate"].set()  # Anthropic answers: the background refresh lands and the page's follow-up picks it up
    assert wait_for(browser, "document.querySelector('#q-cards .c-card .c-today .c-v').textContent === '$12.34'"
                             f" && {stale}.length === 0")
    after = browser.evaluate("JSON.stringify(document.getElementById('q-cards').getBoundingClientRect())")
    assert json.loads(before) == json.loads(after), (before, after)
    grid = browser.evaluate("window.__grid")
    # every state of the grid had all five cards (the quota, credit and two spend cards), from the first paint on, at one height
    assert grid and all(g["n"] == 5 and g["credit"] == 1 for g in grid), grid
    assert len({g["h"] for g in grid if g["h"]}) == 1, grid   # a phone's folded grid is 0 high until the strip is tapped
    # never a mix of answered cards and cards still to come
    assert all(g["pending"] in (0, 3) for g in grid), grid
    # the answers on disk: figures only, no key or token
    for f in page_app["state"].glob("*.json"):
        text = f.read_text()
        assert KEY not in text and TOKEN not in text and "fake-refresh" not in text, f


def test_first_start_with_no_saved_answer_fills_the_placeholders(page_app, browser):
    url = page_app["start"]()
    open_overview(browser, url)
    assert wait_for(browser, "document.querySelectorAll('#q-cards .q-pending').length === 5", timeout=5)
    m = card(browser)
    assert m["pending"] and "Not yet available" in m["text"] and m["today"] == "—", m
    before = browser.evaluate("document.getElementById('q-cards').getBoundingClientRect().height")
    page_app["gate"].set()
    assert wait_for(browser, "!document.querySelector('#q-cards .q-pending')"
                             " && document.querySelector('#q-cards .c-card .c-today .c-v').textContent === '$12.34'")
    after = browser.evaluate("document.getElementById('q-cards').getBoundingClientRect().height")
    assert before == after
    grid = browser.evaluate("window.__grid")
    assert all(g["n"] == 5 for g in grid) and len({g["h"] for g in grid if g["h"]}) == 1, grid   # folded (0 high) until the tap


# the page polls api/credit every 15 minutes (and on each open), never faster: a simulated clock over the intervals
INTERVALS = """(() => {
window.__credit = 0;
const realFetch = window.fetch;
window.fetch = (u, o) => { if (String(u).includes("api/credit")) window.__credit++; return realFetch(u, o); };
window.__iv = new Map();
const realSet = window.setInterval, realClear = window.clearInterval;
window.setInterval = (fn, ms, ...a) => { const id = realSet(fn, ms, ...a); window.__iv.set(id, { fn, ms }); return id; };
window.clearInterval = (id) => { window.__iv.delete(id); return realClear(id); };
window.__advance = (ms) => { for (const { fn, ms: every } of [...window.__iv.values()]) for (let i = 0; i < Math.floor(ms / every); i++) fn(); };
})();"""


def test_the_page_asks_for_the_spend_at_most_every_15_minutes(page_app, browser):
    url = page_app["start"](saved_credit=spend(1, 2), saved_age_h=0)
    page_app["gate"].set()
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": INTERVALS})
    open_overview(browser, url)
    assert wait_for(browser, "!!document.querySelector('#q-cards .c-card:not(.q-pending) .c-today')")
    time.sleep(0.5)
    assert browser.evaluate("window.__credit") == 1  # once, when the overview opens
    browser.evaluate("window.__advance(15 * 60000 - 1); ''")
    time.sleep(0.5)
    assert browser.evaluate("window.__credit") == 1  # 15 minutes less a moment: nothing more
    browser.evaluate("window.__advance(15 * 60000); ''")
    time.sleep(0.5)
    assert browser.evaluate("window.__credit") == 2  # the next 15 minutes: one
    assert browser.evaluate("Math.min(...[...window.__iv.values()].map((v) => v.ms))") == 10000  # the table's own poll
    assert browser.evaluate("[...window.__iv.values()].some((v) => v.ms === 900000)")
