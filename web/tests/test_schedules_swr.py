"""GET /api/schedules is served the way the lane cards are (swr.py): the last reading at once, a fresh one read in the background
once it is 30 s old, the page never waiting on systemd (about 1 s of systemctl calls). The collector is a fake here, so the tests
need no systemd: it counts its reads, can be held on a gate and can fail.

What a wrong answer costs: a tab that waits again on every open (the reason for this), a refresh started per request (a page
polling would start a pile of systemctl runs), a failed read that blanks the table, or the error text of an exception on the page.
Nothing here starts a process or writes a file; the browser side of it is in test_schedules.py.
"""

from __future__ import annotations

import threading
import time

import pytest
from starlette.testclient import TestClient

from sala_web import schedules as SCH
from sala_web.app import create_app
from sala_web.config import Settings

SECRET_LOOKING = "boom /home/someone/.token=abc123"


def reading(n: int) -> dict:
    return {"generated": SCH.zone_time(1_793_000_000 + n), "timezone": "Asia/Dubai", "tzLabel": "+04",
            "timers": [{"name": f"job-{n}.timer"}], "cron": [],
            "counts": {"timers": 1, "cron": 0, "packaged": 0, "flagged": 0, "byReason": {}}, "scopes": {"user": True, "system": False}}


class Collector:
    """The fake systemd read: reading number n on its n-th call; `gate` holds it until set; `fail` makes it raise."""

    def __init__(self):
        self.n = 0
        self.gate: threading.Event | None = None
        self.fail = False

    def __call__(self) -> dict:
        self.n += 1
        n = self.n
        if self.gate is not None:
            assert self.gate.wait(10), "the test never released the read"
        if self.fail:
            raise OSError(SECRET_LOOKING)
        return reading(n)


@pytest.fixture
def env(tmp_path):
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    (claude / "projects").mkdir()
    app = create_app(Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                              tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"]))
    fake = Collector()
    app.state.schedules._collector = fake
    return app, fake


def names(got):
    return [t["name"] for t in got["timers"]]


def entered(fake, n):
    """Wait until the collector has been called n times. A request only schedules the read (a task, then a worker thread), so
    the call is not yet counted when the answer comes back; on a loaded machine that takes a while."""
    for _ in range(500):
        if fake.n >= n:
            return
        time.sleep(0.01)
    raise AssertionError(f"the collector was called {fake.n} times, not {n}")


def settled(c, path="/api/schedules"):
    """The answer once no read is running."""
    for _ in range(250):
        got = c.get(path).json()
        if not got.get("refreshing"):
            return got
        time.sleep(0.02)
    raise AssertionError("the read never landed")


def test_the_first_request_after_a_restart_starts_the_read_and_the_page_is_told_to_ask_again(env):
    app, fake = env
    with TestClient(app) as c:
        first = c.get("/api/schedules").json()
        assert first["pending"] is True and first["refreshing"] is True and first["fetchedAt"] is None and first["timers"] == []
        got = settled(c)
    assert names(got) == ["job-1.timer"] and isinstance(got["fetchedAt"], int) and "pending" not in got and "error" not in got
    assert got["generated"]["epoch"] == 1_793_000_001 and abs(got["fetchedAt"] / 1000 - time.time()) < 60   # the reading carries its age
    assert fake.n == 1


def test_a_later_request_gets_the_stored_reading_at_once_and_a_new_one_replaces_it(env):
    app, fake = env
    with TestClient(app) as c:
        settled(c)
        before = c.get("/api/schedules").json()
        assert names(before) == ["job-1.timer"] and "refreshing" not in before
        fake.gate = threading.Event()        # the next read is slow: a request must not wait for it
        app.state.schedules._swr.expire()    # the reading is now older than its TTL
        t0 = time.perf_counter()
        stale = c.get("/api/schedules").json()
        again = c.get("/api/schedules").json()
        took = time.perf_counter() - t0
        assert took < 0.1, took              # both answers, with a read held open behind them
        assert names(stale) == names(again) == ["job-1.timer"] and stale["fetchedAt"] == before["fetchedAt"]
        assert stale["refreshing"] is True and again["refreshing"] is True
        entered(fake, 2)                     # the read behind both requests has started...
        fake.gate.set()
        got = settled(c)
    assert names(got) == ["job-2.timer"] and got["fetchedAt"] >= before["fetchedAt"]
    assert fake.n == 2                       # ...and it was the only one, never one per request


def test_a_reading_inside_its_ttl_is_not_read_again(env):
    app, fake = env
    with TestClient(app) as c:
        settled(c)
        for _ in range(20):
            got = c.get("/api/schedules").json()
            assert names(got) == ["job-1.timer"] and "refreshing" not in got
    assert fake.n == 1


def test_a_failed_read_keeps_the_last_reading_and_says_so_without_the_error_text(env):
    app, fake = env
    with TestClient(app) as c:
        good = settled(c)
        fake.fail = True
        app.state.schedules._swr.expire()
        c.get("/api/schedules")
        got = settled(c)
        assert names(got) == ["job-1.timer"] and got["fetchedAt"] == good["fetchedAt"]   # the table stays
        assert got["error"] and got["errorKind"] == "failed" and SECRET_LOOKING not in str(got) and "abc123" not in str(got)
        assert fake.n == 2
        c.get("/api/schedules")                                                         # inside the retry wait: no new read
        assert fake.n == 2
        fake.fail = False
        app.state.schedules._swr.expire()                                               # the wait is over
        c.get("/api/schedules")
        healed = settled(c)
    assert names(healed) == ["job-3.timer"] and "error" not in healed and "errorKind" not in healed


def test_a_first_read_that_fails_leaves_the_answer_pending_with_the_error(env):
    app, fake = env
    fake.fail = True
    with TestClient(app) as c:
        c.get("/api/schedules")
        got = settled(c)
        assert got["pending"] is True and got["fetchedAt"] is None and got["error"] and SECRET_LOOKING not in str(got)
        fake.fail = False
        app.state.schedules._swr.expire()
        c.get("/api/schedules")
        assert names(settled(c)) == ["job-2.timer"]


def test_reload_makes_the_reading_due_now_but_still_answers_at_once(env):
    app, fake = env
    with TestClient(app) as c:
        settled(c)
        fake.gate = threading.Event()
        t0 = time.perf_counter()
        r = c.get("/api/schedules?fresh=1").json()
        again = c.get("/api/schedules?fresh=1").json()   # a second Reload while the read runs starts no other
        assert time.perf_counter() - t0 < 0.1
        assert names(r) == names(again) == ["job-1.timer"] and r["refreshing"] is True
        entered(fake, 2)
        fake.gate.set()
        assert names(settled(c)) == ["job-2.timer"]
        assert fake.n == 2
        assert c.get("/api/schedules?fresh=0").json().get("refreshing") is None   # only fresh=1 asks for a new read
    assert fake.n == 2


def test_the_reading_is_kept_in_memory_only(env):
    app, _fake = env
    with TestClient(app) as c:
        settled(c)
    assert app.state.schedules._swr.path is None
    assert not (app.state.settings.state_dir.exists() and any(app.state.settings.state_dir.glob("*sched*")))
