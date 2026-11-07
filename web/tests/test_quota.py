"""GET /api/quota: each account lane's limits from the usage endpoint, cached, without ever exposing the token; a
refusal (429) or a failure backs off per lane and the card says so in plain words over the saved numbers.

Every credentials file here is a fake in tmp_path; the real ones are never read, and the usage endpoint is never called:
every test replaces the fetch. The card is checked in a headless Chromium when one is installed (conftest.py:
`browser`), else those tests are skipped."""

import email.utils
import json
import socket
import threading
import time
import urllib.error

import pytest
from starlette.testclient import TestClient

from sala_web import quota as Q
from sala_web import sessions as S
from sala_web import swr as SWR
from sala_web.app import create_app
from sala_web.config import Settings

TOKEN = "fake-token-never-shown"
USAGE = {"limits": [
    {"kind": "session", "percent": 12, "severity": "normal", "resets_at": "2026-10-14T10:10:00Z"},
    {"kind": "weekly_all", "percent": 64.5, "severity": "warning", "resets_at": "2026-10-21T05:00:00Z"},
    {"kind": "weekly_scoped", "percent": 30, "severity": "normal", "resets_at": "2026-10-21T05:00:00Z",
     "scope": {"model": {"display_name": "Fable"}}},
]}


def creds(d, token=TOKEN, expires_in=3600, sub="max", tier="demo_claude_max_20x"):
    d.mkdir(parents=True, exist_ok=True)
    (d / ".credentials.json").write_text(json.dumps({"claudeAiOauth": {
        "accessToken": token, "refreshToken": "fake-refresh", "expiresAt": int((time.time() + expires_in) * 1000),
        "subscriptionType": sub, "rateLimitTier": tier}}))


@pytest.fixture
def env(tmp_path, monkeypatch):
    max_dir, team_dir = tmp_path / "claude", tmp_path / "claude-team"
    monkeypatch.setattr(S, "LANE_DIRS", {"subscription-2": team_dir})
    creds(max_dir)
    creds(team_dir, sub="team", tier="demo_claude_team")
    app = create_app(Settings(claude_dir=max_dir, state_dir=tmp_path / "state"))
    calls = []

    def fetch(token):
        calls.append(token)
        return USAGE

    app.state.quota.fetch = fetch
    return app, calls, max_dir, team_dir


def lanes(client):
    """The answer once no background refresh runs (the first ask starts one and is answered at once)."""
    for _ in range(200):
        r = client.get("/api/quota")
        assert r.status_code == 200
        assert TOKEN not in r.text and "fake-refresh" not in r.text
        got = {x["lane"]: x for x in r.json()["lanes"]}
        if not any(x.get("refreshing") for x in got.values()):
            return got
        time.sleep(0.02)
    raise AssertionError("the quota refresh never landed")


def test_labels_percents_and_plan(env):
    app, calls, *_ = env
    with TestClient(app) as c:
        got = lanes(c)
    assert set(got) == {"subscription-1", "subscription-2"}
    assert got["subscription-1"]["plan"] == "Max (20x)" and got["subscription-2"]["plan"] == "Team"
    assert got["subscription-1"]["limits"] == [
        {"label": "Current session", "percent": 12, "severity": "normal", "resetsAt": "2026-10-14T10:10:00Z"},
        {"label": "This week", "percent": 64.5, "severity": "warning", "resetsAt": "2026-10-21T05:00:00Z"},
        {"label": "Fable this week", "percent": 30, "severity": "normal", "resetsAt": "2026-10-21T05:00:00Z"},
    ]
    assert "error" not in got["subscription-1"] and isinstance(got["subscription-1"]["fetchedAt"], int)
    assert calls == [TOKEN, TOKEN]


def test_the_answer_carries_no_cloud_credit(env, monkeypatch):
    """The temporary Cloud credit row is gone: a usage answer that still holds the undocumented credit block adds nothing to /api/quota."""
    app, *_ = env
    app.state.quota.fetch = lambda token: {**USAGE, "iguana_necktie": {
        "limit_dollars": 250, "used_dollars": 89.12, "remaining_dollars": 160.88, "resets_at": "2035-11-08T07:59:00Z"}}
    with TestClient(app) as c:
        got = lanes(c)
    assert got["subscription-1"]["limits"] and all("cloudCredit" not in x for x in got.values())
    assert not hasattr(Q, "parse_cloud_credit")


def test_answer_is_cached_per_lane(env, monkeypatch):
    app, calls, *_ = env
    with TestClient(app) as c:
        lanes(c)
        lanes(c)
        assert len(calls) == 2  # one per lane, the second ask is served from the cache
        now = time.monotonic()
        monkeypatch.setattr(SWR.time, "monotonic", lambda: now + Q.TTL + 1)
        lanes(c)
    assert len(calls) == 4


def test_expired_token_is_not_sent(env, tmp_path):
    app, calls, _, team_dir = env
    creds(team_dir, expires_in=-60)
    with TestClient(app) as c:
        got = lanes(c)
    assert got["subscription-2"]["error"] == Q.EXPIRED and got["subscription-2"]["limits"] == []
    assert "error" not in got["subscription-1"]
    assert calls == [TOKEN]  # only max's
    # nothing was asked, so no backing off: looked at again at the page's next poll, and no wait saved
    assert got["subscription-2"]["errorKind"] == "sign_in"
    assert abs(got["subscription-2"]["nextTry"] / 1000 - (time.time() + Q.ERROR_RETRY)) < 5
    assert not (tmp_path / "state" / "quota-subscription-2.json").exists()


def test_401_keeps_the_last_good_answer_and_retries_at_the_next_poll(env, monkeypatch):
    app, calls, *_ = env
    with TestClient(app) as c:
        first = lanes(c)

        def unauthorized(token):
            calls.append(token)
            raise Q.Unauthorized()

        app.state.quota.fetch = unauthorized
        now = time.monotonic()
        monkeypatch.setattr(SWR.time, "monotonic", lambda: now + Q.TTL + 1)
        got = lanes(c)
        assert got["subscription-1"]["error"] == Q.EXPIRED and got["subscription-1"]["errorKind"] == "sign_in"
        assert got["subscription-1"]["limits"] == first["subscription-1"]["limits"]  # last good answer kept
        assert got["subscription-1"]["fetchedAt"] == first["subscription-1"]["fetchedAt"]
        app.state.quota.fetch = lambda token: USAGE
        monkeypatch.setattr(SWR.time, "monotonic", lambda: now + Q.TTL + 1 + Q.ERROR_RETRY + 1)
        got = lanes(c)
    assert "error" not in got["subscription-1"]  # a minute later it is asked again, and the error clears


def test_missing_and_broken_sign_in(env):
    app, calls, max_dir, team_dir = env
    (team_dir / ".credentials.json").unlink()
    (max_dir / ".credentials.json").write_text('{"claudeAiOauth": {"accessToken": "' + TOKEN + '", ')
    with TestClient(app) as c:
        got = lanes(c)
    assert got["subscription-2"]["error"] == "no sign-in on this lane"
    assert got["subscription-1"]["error"] == "sign-in file unreadable"
    assert calls == []


def test_unexpected_error_never_carries_its_message(env):
    app, *_ = env

    def boom(token):
        raise KeyError(token)

    app.state.quota.fetch = boom
    with TestClient(app) as c:
        got = lanes(c)
    assert got["subscription-1"]["error"] == "quota could not be read (KeyError)"
    # and it backs off like any failed check (a minute first), rather than retrying every poll
    assert got["subscription-1"]["errorKind"] == "failed"
    assert abs(got["subscription-1"]["nextTry"] / 1000 - (time.time() + SWR.BACKOFF[0])) < 5


def test_fetch_usage_request_and_errors(monkeypatch):
    seen = {}

    class Resp:
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def read(self):
            return json.dumps(USAGE).encode()

    def ok(req, timeout):
        seen.update(url=req.full_url, auth=req.get_header("Authorization"), beta=req.get_header("Anthropic-beta"),
                    ua=req.get_header("User-agent"), method=req.get_method())
        return Resp()

    monkeypatch.setattr(Q.urllib.request, "urlopen", ok)
    assert Q.fetch_usage("t0k") == USAGE
    assert seen == {"url": Q.USAGE_URL, "auth": "Bearer t0k", "beta": "oauth-2025-04-20", "ua": "sala-web",
                    "method": "GET"}

    def status(code):
        def f(req, timeout):
            raise urllib.error.HTTPError(req.full_url, code, "x", {}, None)
        return f

    monkeypatch.setattr(Q.urllib.request, "urlopen", status(401))
    with pytest.raises(Q.Unauthorized):
        Q.fetch_usage("t0k")
    monkeypatch.setattr(Q.urllib.request, "urlopen", status(500))
    with pytest.raises(Q.Unavailable, match="HTTP 500") as e:
        Q.fetch_usage("t0k")
    assert "t0k" not in str(e.value)
    assert isinstance(e.value, RuntimeError)


def status_with(code, headers):
    def f(req, timeout):
        raise urllib.error.HTTPError(req.full_url, code, "x", headers, None)
    return f


def test_429_is_rate_limited_with_its_retry_after(monkeypatch):
    # seconds
    monkeypatch.setattr(Q.urllib.request, "urlopen", status_with(429, {"Retry-After": "600"}))
    with pytest.raises(Q.RateLimited) as e:
        Q.fetch_usage("t0k")
    assert e.value.retry_after == 600.0 and "t0k" not in str(e.value)
    # an HTTP date: seconds from now
    at = email.utils.formatdate(time.time() + 900, usegmt=True)
    monkeypatch.setattr(Q.urllib.request, "urlopen", status_with(429, {"Retry-After": at}))
    with pytest.raises(Q.RateLimited) as e:
        Q.fetch_usage("t0k")
    assert 895 <= e.value.retry_after <= 901
    # none, or one that cannot be read: the series decides
    monkeypatch.setattr(Q.urllib.request, "urlopen", status_with(429, {}))
    with pytest.raises(Q.RateLimited) as e:
        Q.fetch_usage("t0k")
    assert e.value.retry_after is None
    monkeypatch.setattr(Q.urllib.request, "urlopen", status_with(429, {"Retry-After": "soon"}))
    with pytest.raises(Q.RateLimited) as e:
        Q.fetch_usage("t0k")
    assert e.value.retry_after is None


def test_retry_after_seconds():
    now = 1_800_000_000.0
    assert Q.retry_after_seconds("120") == 120.0
    assert Q.retry_after_seconds(" 7 ") == 7.0
    assert Q.retry_after_seconds(email.utils.formatdate(now + 1800, usegmt=True), now) == 1800.0
    assert Q.retry_after_seconds("Thu, 01 Jan 1970 00:00:00 GMT", now) < 0  # a date gone by: swr clamps it to a minute
    for bad in (None, "", "   ", "soon", "-5", "1.5", "Thu, 99 Foo 2026"):
        assert Q.retry_after_seconds(bad, now) is None, bad


def test_parsing_odd_entries():
    assert Q.parse_limits({"limits": [
        {"kind": "weekly_scoped", "percent": None, "scope": {}},
        {"kind": "monthly_extra", "percent": "7"},
        "junk",
    ]}) == [
        {"label": "Scoped this week", "percent": None, "severity": "normal", "resetsAt": None},
        {"label": "Monthly extra", "percent": None, "severity": "normal", "resetsAt": None},
    ]
    assert Q.parse_limits({}) == []
    assert Q.plan_label("max", "demo_claude_max_5x") == "Max (5x)"
    assert Q.plan_label("weird", "x") is None and Q.plan_label(None, None) is None


def test_answers_are_kept_on_disk_and_served_at_once_after_a_restart(env, tmp_path):
    # a card that waits on Anthropic used to appear late. A restart serves the saved answer at
    # once, refreshing in the background only when it is due; the file holds the limits and plan, never the token.
    app, calls, *_ = env
    with TestClient(app) as c:
        first = lanes(c)
    for lane in ("subscription-1", "subscription-2"):
        text = (tmp_path / "state" / f"quota-{lane}.json").read_text()
        assert TOKEN not in text and "fake-refresh" not in text and "accessToken" not in text
        assert json.loads(text)["limits"] == first[lane]["limits"]
    n = len(calls)
    app2 = create_app(app.state.settings)  # a restart: the saved answers are fresh, so nobody is asked
    app2.state.quota.fetch = lambda token: calls.append(token) or USAGE
    with TestClient(app2) as c:
        got = c.get("/api/quota").json()["lanes"]
    assert [x["limits"] for x in got] == [first["subscription-1"]["limits"], first["subscription-2"]["limits"]]
    assert not any(x.get("refreshing") or x.get("pending") for x in got) and len(calls) == n
    # an hour later, upstream hanging: still answered at once, from the saved answer
    for lane in ("subscription-1", "subscription-2"):
        p = tmp_path / "state" / f"quota-{lane}.json"
        SWR.write_atomic(p, {**json.loads(p.read_text()), "fetchedAt": int((time.time() - 3600) * 1000)})
    gate = threading.Event()
    app3 = create_app(app.state.settings)
    app3.state.quota.fetch = lambda token: gate.wait(10) and USAGE
    try:
        with TestClient(app3) as c:
            t0 = time.monotonic()
            got = c.get("/api/quota").json()["lanes"]
            assert time.monotonic() - t0 < 1
            assert all(x["refreshing"] and x["limits"] for x in got)
            gate.set()
            fresh = lanes(c)
        assert fresh["subscription-1"]["fetchedAt"] > got[0]["fetchedAt"]
    finally:
        gate.set()


# A refusal or a failure backs off per lane (the Team card read "usage endpoint answered HTTP 429" in red, the
# refusal retried every 55 s). The clock the cache schedules by is jumped; time.time stays real, so nextTry (epoch ms,
# what the card shows) is checked against the wall clock. The counter on the fake fetch is the proof that nothing is sent
# while a lane waits.

@pytest.fixture
def jump(monkeypatch):
    """jump(seconds): the cache's clock reads that much past the test's start (absolute, not cumulative)."""
    real = time.monotonic
    off = {"s": 0.0}
    monkeypatch.setattr(SWR.time, "monotonic", lambda: real() + off["s"])

    def set_offset(seconds):
        off["s"] = float(seconds)
    return set_offset


def refusing(calls, retry_after=None):
    def f(token):
        calls.append(token)
        raise Q.RateLimited(retry_after)
    return f


def failing(calls, message="usage endpoint answered HTTP 500"):
    def f(token):
        calls.append(token)
        raise Q.Unavailable(message)
    return f


def near(ms, seconds_from_now, slack=5):
    return abs(ms / 1000 - (time.time() + seconds_from_now)) < slack


def test_429_with_retry_after_waits_that_long_and_sends_nothing_meanwhile(env, jump):
    app, calls, *_ = env
    with TestClient(app) as c:
        first = lanes(c)
        app.state.quota.fetch = refusing(calls, 600.0)
        jump(Q.TTL + 1)
        got = lanes(c)
        assert len(calls) == 4  # one refusal per lane
        for lane in ("subscription-1", "subscription-2"):
            assert got[lane]["errorKind"] == "rate_limited" and got[lane]["error"] == Q.RATE_LIMITED
            assert got[lane]["limits"] == first[lane]["limits"] and got[lane]["fetchedAt"] == first[lane]["fetchedAt"]
            assert near(got[lane]["nextTry"], 600)
        # the whole wait, polled often: the saved numbers, nothing sent
        for s in (1, 60, 300, 599):
            jump(Q.TTL + 1 + s)
            again = lanes(c)
            assert len(calls) == 4 and again["subscription-1"]["limits"] == first["subscription-1"]["limits"] and "refreshing" not in again["subscription-1"]
        jump(Q.TTL + 1 + 601)
        lanes(c)
        assert len(calls) == 6


def test_retry_after_is_clamped_to_a_minute_and_three_hours(env, jump):
    app, calls, *_ = env
    with TestClient(app) as c:
        lanes(c)
        app.state.quota.fetch = refusing(calls, 5.0)
        jump(Q.TTL + 1)
        got = lanes(c)
        assert near(got["subscription-1"]["nextTry"], SWR.RETRY_AFTER_MIN)
        jump(Q.TTL + 1 + 59)
        lanes(c)
        assert len(calls) == 4
        app.state.quota.fetch = refusing(calls, 99_999.0)
        jump(Q.TTL + 1 + 61)
        got = lanes(c)
        assert len(calls) == 6 and near(got["subscription-1"]["nextTry"], SWR.RETRY_AFTER_MAX)
        jump(Q.TTL + 1 + 61 + SWR.RETRY_AFTER_MAX - 2)
        lanes(c)
        assert len(calls) == 6


def test_a_real_429_with_retry_after_2418_is_waited_out_and_a_dropped_network_keeps_the_numbers(env, jump, monkeypatch):
    """The live defect, end to end through fetch_usage (urlopen is the only fake): Anthropic's 429 with `Retry-After:
    2418` is not asked again every 55 s but after 2418 s (inside the clamp), the card's numbers kept; a URLError keeps
    the last good limits too, with the error as the quiet kind `failed`, not the 429 kind."""
    app, calls, *_ = env
    with TestClient(app) as c:
        first = lanes(c)
        sent = []
        app.state.quota.fetch = Q.fetch_usage
        monkeypatch.setattr(Q.urllib.request, "urlopen", lambda req, timeout: sent.append(req) or status_with(
            429, {"Retry-After": "2418"})(req, timeout))
        jump(Q.TTL + 1)
        got = lanes(c)
        assert len(sent) == 2  # one refused ask per lane
        for lane in ("subscription-1", "subscription-2"):
            assert got[lane]["errorKind"] == "rate_limited" and got[lane]["limits"] == first[lane]["limits"]
            assert near(got[lane]["nextTry"], 2418)
        for s in range(55, 2418, 55):  # the 55 s page poll, all through the wait
            jump(Q.TTL + 1 + s)
            lanes(c)
        jump(Q.TTL + 1 + 2417)
        lanes(c)
        assert len(sent) == 2, "asked again before Retry-After was over"
        jump(Q.TTL + 1 + 2419)
        lanes(c)
        assert len(sent) == 4
        # the network drops (a URLError out of urlopen): the numbers stay, the error is quiet and says failed
        def down(req, timeout):
            sent.append(req)
            raise urllib.error.URLError(socket.gaierror(-3, "Temporary failure in name resolution"))
        monkeypatch.setattr(Q.urllib.request, "urlopen", down)
        jump(Q.TTL + 1 + 2419 + 2418 + 1)
        got = lanes(c)
        assert len(sent) == 6
        for lane in ("subscription-1", "subscription-2"):
            assert got[lane]["errorKind"] == "failed" and got[lane]["error"] == "usage endpoint unreachable (URLError)"
            assert got[lane]["limits"] == first[lane]["limits"] and got[lane]["fetchedAt"] == first[lane]["fetchedAt"]
            ahead = got[lane]["nextTry"] / 1000 - time.time()  # a backed-off wait, not the 55 s poll
            assert 55 < ahead <= 1800 + 5, ahead


def test_429_without_retry_after_backs_off_2_4_8_16_30_30_minutes(env, jump):
    app, calls, *_ = env
    with TestClient(app) as c:
        lanes(c)
        app.state.quota.fetch = refusing(calls)
        at = Q.TTL + 1
        jump(at)
        waits = [120, 240, 480, 960, 1800, 1800, 1800]
        for i, w in enumerate(waits):
            got = lanes(c)  # the (i+1)-th refusal in a row, just taken
            assert len(calls) == 2 + 2 * (i + 1), (i, calls)
            assert near(got["subscription-1"]["nextTry"], w) and near(got["subscription-2"]["nextTry"], w), (i, w, got["subscription-1"]["nextTry"])
            jump(at + w - 2)
            lanes(c)
            assert len(calls) == 2 + 2 * (i + 1), (i, "sent during the wait")
            at += w
            jump(at)
        lanes(c)
        assert len(calls) == 2 + 2 * (len(waits) + 1)


def test_a_success_resets_the_backoff(env, jump):
    app, calls, *_ = env
    with TestClient(app) as c:
        lanes(c)
        app.state.quota.fetch = refusing(calls)
        at = Q.TTL + 1
        jump(at)
        lanes(c)            # 2 minutes
        at += 120
        jump(at)
        got = lanes(c)      # 4 minutes
        assert near(got["subscription-1"]["nextTry"], 240)
        app.state.quota.fetch = lambda token: calls.append(token) or USAGE
        at += 240
        jump(at)
        got = lanes(c)
        for lane in ("subscription-1", "subscription-2"):
            assert "error" not in got[lane] and "errorKind" not in got[lane] and "nextTry" not in got[lane]
        app.state.quota.fetch = refusing(calls)
        at += Q.TTL + 1
        jump(at)
        got = lanes(c)
        assert near(got["subscription-1"]["nextTry"], 120)  # the series starts over


def test_other_failures_back_off_from_a_minute(env, jump):
    app, calls, *_ = env
    with TestClient(app) as c:
        first = lanes(c)
        app.state.quota.fetch = failing(calls)
        at = Q.TTL + 1
        jump(at)
        waits = [60, 120, 240, 480, 960, 1800, 1800]
        for i, w in enumerate(waits):
            if i == 3:  # no network, mid-series: the same series goes on
                app.state.quota.fetch = failing(calls, "usage endpoint unreachable (URLError)")
            got = lanes(c)
            assert len(calls) == 2 + 2 * (i + 1), (i, calls)
            assert got["subscription-1"]["errorKind"] == "failed" and got["subscription-1"]["limits"] == first["subscription-1"]["limits"]
            assert got["subscription-1"]["error"].startswith("usage endpoint ")
            assert near(got["subscription-1"]["nextTry"], w), (i, w)
            jump(at + w - 2)
            lanes(c)
            assert len(calls) == 2 + 2 * (i + 1), (i, "sent during the wait")
            at += w
            jump(at)


def test_each_lane_backs_off_on_its_own(env, jump):
    app, calls, _, team_dir = env
    creds(team_dir, token="team-fake-token", sub="team", tier="demo_claude_team")

    def fetch(token):
        calls.append(token)
        if token == "team-fake-token":
            raise Q.RateLimited(None)
        return USAGE

    app.state.quota.fetch = fetch
    with TestClient(app) as c:
        got = lanes(c)
        assert "error" not in got["subscription-1"] and got["subscription-2"]["errorKind"] == "rate_limited"
        assert calls == [TOKEN, "team-fake-token"]
        assert "team-fake-token" not in c.get("/api/quota").text
        jump(121)  # team's 2 minutes are over; max's answer is still fresh
        lanes(c)
        assert calls == [TOKEN, "team-fake-token", "team-fake-token"]
        jump(Q.TTL + 1)  # max is due by its TTL; team now waits 4 minutes
        lanes(c)
        assert calls[-1] == TOKEN and len(calls) == 4
        jump(121 + 239)
        lanes(c)
        assert len(calls) == 4
        jump(121 + 241)
        got = lanes(c)
        assert len(calls) == 5 and calls[-1] == "team-fake-token"
        assert "error" not in got["subscription-1"] and got["subscription-2"]["errorKind"] == "rate_limited"
        assert "nextTry" not in got["subscription-1"] and near(got["subscription-2"]["nextTry"], 480)


def test_a_restart_keeps_waiting_as_the_saved_next_try_says(env, tmp_path, jump):
    app, calls, *_ = env
    with TestClient(app) as c:
        first = lanes(c)
        app.state.quota.fetch = refusing(calls)
        jump(Q.TTL + 1)
        got = lanes(c)
    n = len(calls)
    for lane in ("subscription-1", "subscription-2"):
        p = tmp_path / "state" / f"quota-{lane}.json"
        text = p.read_text()
        saved = json.loads(text)
        # the wait is in the file, next to the figures; never the error text, the flags or the token
        assert saved["nextTry"] == got[lane]["nextTry"] and saved["errorKind"] == "rate_limited"
        assert saved["limits"] == first[lane]["limits"] and saved["fetchedAt"] == first[lane]["fetchedAt"]
        assert saved["plan"] == got[lane]["plan"]
        assert not {"error", "pending", "refreshing"} & set(saved)
        assert TOKEN not in text and "fake-refresh" not in text and "accessToken" not in text and "Bearer" not in text
        assert oct(p.stat().st_mode & 0o777) == oct(0o600)
        # an old answer and a wait of 10 minutes still ahead (so the wait, not the TTL, is what holds the restart)
        SWR.write_atomic(p, {**saved, "fetchedAt": int((time.time() - 3600) * 1000),
                             "nextTry": int((time.time() + 600) * 1000)})
    app2 = create_app(app.state.settings)
    app2.state.quota.fetch = lambda token: calls.append(token) or USAGE
    with TestClient(app2) as c:
        for _ in range(5):
            r = c.get("/api/quota")
            assert TOKEN not in r.text
        got2 = {x["lane"]: x for x in r.json()["lanes"]}
    assert len(calls) == n  # nothing sent
    for lane in ("subscription-1", "subscription-2"):
        assert got2[lane]["limits"] == first[lane]["limits"] and got2[lane]["plan"] == first[lane]["plan"]
        assert got2[lane]["errorKind"] == "rate_limited" and got2[lane]["error"] == SWR.RESUMED["rate_limited"]
        assert near(got2[lane]["nextTry"], 600) and "refreshing" not in got2[lane] and "pending" not in got2[lane]
    # a saved wait that is over: the restart refreshes at once, and the wait is gone from the answer
    for lane in ("subscription-1", "subscription-2"):
        p = tmp_path / "state" / f"quota-{lane}.json"
        SWR.write_atomic(p, {**json.loads(p.read_text()), "nextTry": int((time.time() - 1) * 1000)})
    app3 = create_app(app.state.settings)
    app3.state.quota.fetch = lambda token: calls.append(token) or USAGE
    with TestClient(app3) as c:
        got3 = lanes(c)
    assert len(calls) == n + 2
    for lane in ("subscription-1", "subscription-2"):
        assert "error" not in got3[lane] and "nextTry" not in got3[lane] and "errorKind" not in got3[lane]
        assert got3[lane]["fetchedAt"] > first[lane]["fetchedAt"]
    saved = json.loads((tmp_path / "state" / "quota-subscription-1.json").read_text())
    assert "nextTry" not in saved and "errorKind" not in saved


def test_a_refusal_before_any_answer_is_kept_across_a_restart(env, tmp_path):
    app, calls, *_ = env
    app.state.quota.fetch = refusing(calls)
    with TestClient(app) as c:
        got = lanes(c)
    assert got["subscription-1"]["pending"] is True and got["subscription-1"]["fetchedAt"] is None
    assert got["subscription-1"]["errorKind"] == "rate_limited" and near(got["subscription-1"]["nextTry"], 120)
    p = tmp_path / "state" / "quota-subscription-1.json"
    saved = json.loads(p.read_text())
    assert saved["fetchedAt"] is None and saved["limits"] == [] and saved["nextTry"] == got["subscription-1"]["nextTry"]
    assert "error" not in saved and TOKEN not in p.read_text()
    n = len(calls)
    app2 = create_app(app.state.settings)
    app2.state.quota.fetch = lambda token: calls.append(token) or USAGE
    with TestClient(app2) as c:
        got2 = {x["lane"]: x for x in c.get("/api/quota").json()["lanes"]}
    assert len(calls) == n
    assert got2["subscription-1"]["pending"] is True and got2["subscription-1"]["limits"] == [] and "refreshing" not in got2["subscription-1"]
    assert got2["subscription-1"]["errorKind"] == "rate_limited" and got2["subscription-1"]["nextTry"] == saved["nextTry"]
    assert got2["subscription-1"]["error"] == SWR.RESUMED["rate_limited"]


# The card: a failed check over saved numbers is a quiet line (the muted token, AA contrast on the card in both
# themes) with the numbers' time and the next try; red only with nothing saved; a good answer has no line. The kinds
# are what is asserted (class, colour token, the times present), not the English.

def lane_creds(d, sub="max", tier="demo_claude_max_20x"):
    creds(d, sub=sub, tier=tier)


SAVED_LIMITS = [
    {"label": "Current session", "percent": 5, "severity": "normal", "resetsAt": "2026-10-14T10:10:00Z"},
    {"label": "This week", "percent": 50, "severity": "normal", "resetsAt": "2026-10-21T05:00:00Z"},
    {"label": "Fable this week", "percent": 20, "severity": "normal", "resetsAt": "2026-10-21T05:00:00Z"},
]


@pytest.fixture
def page_app(tmp_path, monkeypatch):
    """start(fetch, saved_age_h=None) → the app on a loopback port with that fake fetch for both lanes, and, with an
    age, a saved answer that old per lane on disk (as after a restart)."""
    import uvicorn

    claude, team = tmp_path / "claude", tmp_path / "claude-team"
    (claude / "sessions").mkdir(parents=True)
    lane_creds(claude)
    lane_creds(team, sub="team", tier="demo_claude_team")
    monkeypatch.setattr(S, "LANE_DIRS", {"subscription-2": team})
    monkeypatch.setattr(S, "live_tmux_names", lambda: {})
    state = tmp_path / "state"
    servers = []

    def start(fetch, saved_age_h=None):
        if saved_age_h is not None:
            for lane, plan in (("subscription-1", "Max (20x)"), ("subscription-2", "Team")):
                SWR.write_atomic(state / f"quota-{lane}.json", {
                    "lane": lane, "plan": plan, "fetchedAt": int((time.time() - saved_age_h * 3600) * 1000),
                    "limits": SAVED_LIMITS})
        settings = Settings(socket=tmp_path / "s.sock", state_dir=state, claude_dir=claude,
                            tmux_socket_name="salaweb-pytest-none", roles_cmd=["false"], sala_models=tmp_path / "none.tsv",
                            admin_key=tmp_path / "none-key")
        app = create_app(settings)
        app.state.quota.fetch = fetch
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

    yield {"start": start, "state": state}
    for server, t in servers:
        server.should_exit = True
        t.join(timeout=10)


def raising(make):
    def f(token):
        assert token == TOKEN
        raise make()
    return f


# the lane cards: each one's error line with its class, computed colour and contrast on the card, and the colour the
# page's tokens compute to, so the line can be matched to a token rather than to a hex value
CARDS = """(() => {
  const toks = {};
  for (const t of ["--muted", "--error", "--faint"]) {
    const p = document.createElement("span"); p.style.color = `var(${t})`; document.body.append(p);
    toks[t] = getComputedStyle(p).color; p.remove();
  }
  const lin = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; };
  const lum = (c) => { const [r, g, b] = c.match(/[\\d.]+/g).slice(0, 3).map(Number); return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b); };
  const contrast = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
  const cards = [...document.querySelectorAll("#q-cards .q-card:not(.c-card)")].map((c) => {
    const e = c.querySelector(".q-err"), bg = getComputedStyle(c).backgroundColor;
    return { lane: [...c.classList].find((k) => k.startsWith("lane-")).slice(5), pending: c.classList.contains("q-pending"),
             rows: c.querySelectorAll(".q-row").length, asof: !!c.querySelector(".q-asof"), bg,
             err: e && { cls: e.className, text: e.textContent, title: e.title, color: getComputedStyle(e).color,
                         contrast: contrast(getComputedStyle(e).color, bg) } };
  });
  return { toks, cards, dark: matchMedia("(prefers-color-scheme: dark)").matches };
})()"""


def open_overview(browser, url, dark):
    browser.send("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-color-scheme", "value": "dark" if dark else "light"}]})
    browser.open(f"{url}/#sessions", dark=dark)


def wait_for(browser, expr, timeout=15.0):
    end = time.time() + timeout
    while time.time() < end:
        if browser.evaluate(expr):
            return True
        time.sleep(0.1)
    return False


def zone_time(browser, ms):
    """The time as the card writes one (its own Intl, Asia/Dubai, 12-hour): what to look for in the line."""
    return browser.evaluate(f'new Intl.DateTimeFormat("en-US", {{ timeZone: "Asia/Dubai", hour: "numeric", minute: "2-digit" }}).format(new Date({ms}))')


def api_lanes(browser):
    return {x["lane"]: x for x in browser.evaluate("fetch('api/quota', { cache: 'no-store' }).then((r) => r.json())")["lanes"]}


@pytest.mark.parametrize("make", [lambda: Q.RateLimited(None), lambda: Q.Unavailable("usage endpoint answered HTTP 500")],
                         ids=["rate_limited", "failed"])
def test_card_with_saved_numbers_is_quiet_not_red_in_both_themes(page_app, browser, make):
    url = page_app["start"](raising(make), saved_age_h=1)
    for dark in (True, False):
        open_overview(browser, url, dark)
        assert wait_for(browser, "document.querySelectorAll('#q-cards .q-card:not(.c-card) .q-err').length === 2")
        m = browser.evaluate(CARDS)
        assert m["dark"] is dark and len(m["cards"]) == 2, m
        api = api_lanes(browser)
        for card in m["cards"]:
            q, e = api[card["lane"]], card["err"]
            assert q["errorKind"] == ("rate_limited" if isinstance(make(), Q.RateLimited) else "failed")
            assert "q-soft" in e["cls"].split(), e
            assert e["color"] == m["toks"]["--muted"] and e["color"] != m["toks"]["--error"], (e, m["toks"])
            assert e["color"].startswith("rgb(") and card["bg"].startswith("rgb("), (e, card)  # opaque: the ratio is real
            assert e["contrast"] >= 4.5, (dark, e)
            assert card["rows"] == 3 and not card["pending"] and not card["asof"], card  # the numbers stay; one time, not two
            assert zone_time(browser, q["fetchedAt"]) in e["text"] and zone_time(browser, q["nextTry"]) in e["text"], (e, q)
            for word in ("endpoint", "HTTP", "429", "500"):
                assert word not in e["text"], e
            if q["errorKind"] == "failed":
                assert e["title"] == q["error"]  # the server's words, on hover only


@pytest.mark.parametrize("make", [lambda: Q.RateLimited(None), lambda: Q.Unavailable("usage endpoint unreachable (URLError)")],
                         ids=["rate_limited", "failed"])
def test_card_with_nothing_saved_is_red(page_app, browser, make):
    url = page_app["start"](raising(make))
    open_overview(browser, url, dark=True)
    assert wait_for(browser, "document.querySelectorAll('#q-cards .q-card:not(.c-card) .q-err').length === 2")
    m = browser.evaluate(CARDS)
    api = api_lanes(browser)
    for card in m["cards"]:
        q, e = api[card["lane"]], card["err"]
        assert q["fetchedAt"] is None
        assert "q-soft" not in e["cls"].split() and e["color"] == m["toks"]["--error"], (e, m["toks"])
        assert card["rows"] == 0 and not card["pending"], card
        assert zone_time(browser, q["nextTry"]) in e["text"], (e, q)
        for word in ("endpoint", "HTTP", "URLError"):
            assert word not in e["text"], e


def test_card_with_a_good_answer_has_no_error_line(page_app, browser):
    url = page_app["start"](lambda token: USAGE)
    open_overview(browser, url, dark=True)
    assert wait_for(browser, "document.querySelectorAll('#q-cards .q-card:not(.c-card):not(.q-pending) .q-row').length === 6")
    m = browser.evaluate(CARDS)
    assert all(c["err"] is None and c["rows"] == 3 and not c["asof"] for c in m["cards"]), m
    # on the lane cards only: the spend card has its own line (no Admin key here)
    assert browser.evaluate("document.querySelectorAll('#q-cards .q-card:not(.c-card) :is(.q-err, .q-soft)').length") == 0
