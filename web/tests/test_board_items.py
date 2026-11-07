"""GET /api/board-items: each live session's open stackshot items, read from stackshot's client API with this
machine's token, served at once from the last good answer and refreshed in the background (swr.py, one round of reads a
minute for the live sessions, four at a time), kept under the state dir as text only.

What is held here: the parse (waiting = needs lists "decision" and the item is not held; held passed through; the item
page's address from the shown id), the cache (answered at once, one round per TTL however many pages ask, a restart
serving the saved answer while it refreshes once), the state file carrying no token, a missing token / a 401 / an
unreachable server answered with a plain error string that carries no secret, a session whose read fails keeping its last
answer, and the concurrency cap. The client API is a fake here; the real token file is never read (conftest points the
defaults at missing files). The page's markers and sheet are test_board_items_ui.py's."""

import json
import os
import threading
import time
import urllib.error

import pytest
from starlette.testclient import TestClient

from sala_web import board as B
from sala_web import sessions as S
from sala_web import swr as SWR
from sala_web.app import create_app
from sala_web.config import Settings

TOKEN = "[masked machine token]"
URL = "http://127.0.0.1:1"   # never dialled: the fake answers
WEB = "https://stackshot.example"


def item(shown, needs=(), held=False, subject=None, **kw):
    d = {"gid": "g" + shown.split("#")[-1], "shown": shown, "subject": subject or f"[gamma] {shown}", "needs": list(needs),
         "next": "", "state_updated": 1.0, "confirmed": 2.0, "updated": 3.0, "held": held}
    d.update(kw)
    return d


ANSWERS = {
    "demo": [item("board#25", ["demo", "demo-maintainer"]),
                   item("board#18", ["Decision"], held=True),            # on hold: out of his queue, whatever its needs
                   item("board#21", ["decision"]),
                   item("s9", ["external"])],
    "demo-web": [item("board#24", ["demo-builder"], held=True)],
    "gamma-harbor": [],
}


class FakeBoard:
    """The client API: records every read, answers from ANSWERS (an unknown key has nothing), fails on demand."""

    def __init__(self, delay=0.0):
        self.calls = []
        self.fail = {}       # key -> exception to raise
        self.delay = delay
        self.lock = threading.Lock()
        self.inflight = 0
        self.max_inflight = 0

    def __call__(self, url, token, key):
        assert url == URL and token == TOKEN
        with self.lock:
            self.calls.append(key)
            self.inflight += 1
            self.max_inflight = max(self.max_inflight, self.inflight)
        try:
            if self.delay:
                time.sleep(self.delay)
            if key in self.fail:
                raise self.fail[key]
            return {"items": ANSWERS.get(key, [])}
        finally:
            with self.lock:
                self.inflight -= 1


# the parse

def test_waiting_is_a_decision_not_on_hold_and_the_shape_is_the_pages():
    got = B.parse_items({"items": ANSWERS["demo"]}, WEB)
    by = {i["id"]: i for i in got}
    assert by["board#21"]["waiting"] and not by["board#21"]["held"]
    assert not by["board#18"]["waiting"] and by["board#18"]["held"]       # held: on hold, not waiting on the owner
    assert not by["board#25"]["waiting"] and by["board#25"]["needs"] == ["demo", "demo-maintainer"]
    assert not by["s9"]["waiting"] and by["s9"]["needs"] == ["external"]  # someone else's move, not his
    assert by["board#21"]["url"] == WEB + "/items/21" and by["s9"]["url"] == WEB + "/items/s9"
    assert set(by["board#21"]) == {"id", "subject", "needs", "waiting", "held", "url"}
    # waiting first, held last, the server's order within each group
    assert [i["id"] for i in got] == ["board#21", "board#25", "s9", "board#18"]
    assert B.session_entry(got)["waiting"] == 1
    # "decision" in any case counts; held never does
    assert B.waits_on_owner(["DECISION"], False) and B.waits_on_owner([" decision "], False)
    assert not B.waits_on_owner(["decision"], True) and not B.waits_on_owner(["external", "demo"], False)


def test_the_one_rules_fields_pass_through_and_the_red_count_is_the_movers():
    """stackshot's mover / wait / expected_by / overdue / step reach the page as they come; with a mover,
    "waiting on the owner" is mover.kind == owner with no via; without one (an older stackshot) the needs rule stands."""
    owner = {"kind": "owner", "who": "Alex"}
    got = B.parse_items({"items": [
        item("board#9001", ["decision"], mover=owner, wait="needs", expected_by=1792647000.9, overdue=True, step=1),
        item("board#9002", ["demo-maintainer"], mover={"kind": "session", "who": "demo-maintainer"}, wait="needs",
             expected_by=1792627500, overdue=False, step=0),
        item("board#9003", ["decision"], held=True, mover={"kind": "owner", "who": "Alex", "via": "board#9001"}, wait="after",
             expected_by=1792647000),                                      # waits after board#9001, which is in his queue
        item("board#9004", [], mover={"kind": "outside", "who": "sala (pane recycle)"}, wait="recycle", held=True),
        item("board#9005", ["decision"]),                                      # no fields: the needs rule
    ]}, WEB)
    by = {i["id"]: i for i in got}
    assert by["board#9001"]["mover"] == owner and by["board#9001"]["wait"] == "needs" and by["board#9001"]["expected_by"] == 1792647000
    assert by["board#9001"]["overdue"] is True and by["board#9001"]["step"] == 1 and by["board#9001"]["waiting"]
    assert by["board#9002"]["mover"] == {"kind": "session", "who": "demo-maintainer"} and by["board#9002"]["overdue"] is False
    assert not by["board#9002"]["waiting"]
    assert by["board#9003"]["mover"]["via"] == "board#9001" and not by["board#9003"]["waiting"]        # not counted twice
    assert not by["board#9004"]["waiting"] and "expected_by" not in by["board#9004"] and by["board#9004"]["held"]  # no date: none invented
    assert set(by["board#9005"]) == {"id", "subject", "needs", "waiting", "held", "url"} and by["board#9005"]["waiting"]
    assert B.session_entry(got)["waiting"] == 2   # board#9001 and the older-shaped board#9005


def test_the_owner_mover_kind_counts_as_waiting_on_him_unless_the_item_waits_via_another():
    """mover.kind "owner" passes through and counts as waiting on him, unless the item waits `via` another."""
    kind = "owner"
    got = B.parse_items({"items": [
        item("board#9001", ["decision"], mover={"kind": kind, "who": "Alex"}, wait="needs"),
        item("board#9002", ["decision"], held=True, mover={"kind": kind, "who": "Alex", "via": "board#9001"}, wait="after"),
    ]}, WEB)
    by = {i["id"]: i for i in got}
    assert by["board#9001"]["mover"] == {"kind": kind, "who": "Alex"} and by["board#9001"]["waiting"]
    assert by["board#9002"]["mover"]["via"] == "board#9001" and not by["board#9002"]["waiting"]
    assert B.waits_on_owner_by_mover({"kind": kind}) and not B.waits_on_owner_by_mover({"kind": kind, "via": "board#9001"})
    assert B.session_entry(got)["waiting"] == 1


@pytest.mark.parametrize("value", ["decision", "owner", " Owner "])
def test_an_owner_needs_value_puts_an_item_without_a_mover_in_his_queue(value):
    """The needs rule reads "decision" and "owner"; a held item
    never waits, and "external" is someone else's move."""
    assert B.waits_on_owner([value], False) and not B.waits_on_owner([value], True)
    got = B.parse_items({"items": [item("board#9001", [value]), item("board#9002", ["external", "demo"])]}, WEB)
    assert [i["waiting"] for i in got] == [True, False]
    assert not B.waits_on_owner(["external", "demo"], False)


def test_a_legacy_owner_spelling_is_no_longer_read():
    assert not B.waits_on_owner_by_mover({"kind": "legacy-owner"}) and not B.waits_on_owner(["legacy-owner"], False)


def test_an_unknown_mover_kind_is_still_left_out():
    got = B.parse_items({"items": [item("board#9001", [], mover={"kind": "robot", "who": "x"})]}, WEB)
    assert "mover" not in got[0]


def test_state_and_list_pass_through_for_stackshots_three_lists():
    """stackshot's per-row `state` (always sent) and its `list` (coming) reach the page, which sorts the items
    into Your move, Agents at work and Waiting from them; nothing else is invented."""
    got = B.parse_items({"items": [
        item("board#9001", state="your-call"), item("board#9002", state=" doing "), item("board#9003", state="parked", list="waiting"),
        item("board#9004", list="your-move"), item("board#9005", state="verifying", list="agents"), item("board#9006"),
    ]}, WEB)
    by = {i["id"]: i for i in got}
    assert by["board#9001"]["state"] == "your-call" and "list" not in by["board#9001"]
    assert by["board#9002"]["state"] == "doing"
    assert by["board#9003"]["state"] == "parked" and by["board#9003"]["list"] == "waiting"
    assert "state" not in by["board#9004"] and by["board#9004"]["list"] == "your-move"
    assert by["board#9005"]["state"] == "verifying" and by["board#9005"]["list"] == "agents"
    assert set(by["board#9006"]) == {"id", "subject", "needs", "waiting", "held", "url"}   # neither sent: neither invented


def test_a_verifying_items_end_wait_passes_through():
    """Review: stackshot sends wait "end" for a verifying item (its end date), which home.list_of puts in Waiting;
    the wait kind, its date and overdue must reach the page, or the row sits in Waiting with no line."""
    got = B.parse_items({"items": [
        item("board#9001", state="verifying", list="waiting", mover={"kind": "session", "who": "demo"}, wait="end",
             expected_by=1792627500, overdue=True),
    ]}, WEB)
    assert got[0]["wait"] == "end" and got[0]["expected_by"] == 1792627500 and got[0]["overdue"] is True
    assert "end" in B.WAIT_KINDS and "expected" not in B.WAIT_KINDS      # only the kinds stackshot sends


def test_malformed_state_and_list_are_dropped_and_a_long_state_is_cut():
    got = B.parse_items({"items": [
        item("board#9001", state=3, list="someday"), item("board#9002", state="  ", list=["your-move"]), item("board#9003", state=None, list={"a": 1}),
        item("board#9004", state="s" * 400, list="Waiting"),
    ]}, WEB)
    assert [set(i) for i in got[:3]] == [{"id", "subject", "needs", "waiting", "held", "url"}] * 3
    assert got[3]["state"] == "s" * B.STATE_MAX and "list" not in got[3]       # only the three lists exactly as stackshot spells them


def test_malformed_wait_fields_are_dropped_not_passed_on():
    got = B.parse_items({"items": [
        item("board#9001", mover="Alex", wait="someday", expected_by="soon", overdue="yes", step=-1),
        item("board#9002", mover={"kind": "robot", "who": "x"}, wait=None, expected_by=0, overdue=None, step=True),
        item("board#9003", mover={"kind": "session", "who": "w" * 400, "via": "v" * 400}, wait="idle", expected_by=True),
    ]}, WEB)
    assert [set(i) for i in got[:2]] == [{"id", "subject", "needs", "waiting", "held", "url"}] * 2
    m = got[2]["mover"]
    assert len(m["who"]) == B.WHO_MAX and len(m["via"]) == B.WHO_MAX and got[2]["wait"] == "idle" and "expected_by" not in got[2]


def test_item_addresses_follow_stackshots_ids():
    assert B.item_href("board#25") == "25"
    assert B.item_href("board-tmp-box#3") == "board-tmp-box-3"   # a temporary id, until it takes its issue number
    assert B.item_href("s9") == "s9" and B.item_href("a5") == "a5" and B.item_href("g46") == "g46"
    assert B.item_url("https://stackshot.example/", "board#25") == "https://stackshot.example/items/25"
    assert B.item_url(WEB, "odd id/with#chars") == WEB + "/items/odd%20id%2Fwith%23chars"


def test_no_board_address_means_no_link(tmp_path, monkeypatch):
    """The board's web address has no default of its own: SALA_WEB_STACKSHOT_WEB, else [instance] board_url in stackshot.toml,
    else empty, and an item then carries an empty url (the page shows it as text)."""
    from sala_web.config import Settings
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
    monkeypatch.delenv("SALA_WEB_STACKSHOT_WEB", raising=False)
    assert Settings().stackshot_web == ""
    assert B.item_url("", "board#25") == "" and B.item_url("  ", "board#25") == ""
    assert B.parse_items({"items": [item("board#9007")]}, "")[0]["url"] == ""
    (tmp_path / "stackshot").mkdir()
    (tmp_path / "stackshot" / "stackshot.toml").write_text('[instance]\nboard_url = "https://board.example/"\n')
    assert Settings().stackshot_web == "https://board.example"
    monkeypatch.setenv("SALA_WEB_STACKSHOT_WEB", "https://other.example")
    assert Settings().stackshot_web == "https://other.example"
    monkeypatch.setenv("SALA_WEB_STACKSHOT_WEB", "")
    assert Settings().stackshot_web == ""


def test_parse_skips_what_is_not_an_item_and_refuses_a_wrong_answer():
    got = B.parse_items({"items": [item("board#9001", subject="x" * 400), "junk", {"gid": "g2"}, {"shown": "", "subject": "no id"},
                                   {"shown": "board#9003", "needs": "decision"}]}, WEB)
    assert [i["id"] for i in got] == ["board#9001", "g2", "board#9003"]
    assert len(got[0]["subject"]) == B.SUBJECT_MAX
    assert got[2]["needs"] == [] and not got[2]["waiting"]   # needs that is not a list: nothing
    for bad in ({}, {"items": "x"}, [], None):
        with pytest.raises(RuntimeError):
            B.parse_items(bad, WEB)


# the server: answered at once, one round per TTL, kept on disk, errors as plain strings

@pytest.fixture
def env(tmp_path, monkeypatch):
    cfg = tmp_path / "stackshot"
    cfg.mkdir()
    (cfg / "client.token").write_text(TOKEN + "\n")
    (cfg / "client.url").write_text(URL + "\n")
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    pid = os.getpid()
    for n, name in enumerate(("demo", "demo-web", "gamma-harbor")):  # three live sessions: this process's pid
        (claude / "sessions" / f"{n}.json").write_text(json.dumps(
            {"pid": pid, "sessionId": f"0000000{n}-0000-4000-8000-000000000000", "name": name, "cwd": "/x", "status": "idle",
             "tmux": "x:@0.%0", "procStart": S.proc_start(pid)}))
    monkeypatch.setattr(S, "live_tmux_names", lambda: {})
    settings = Settings(claude_dir=claude, state_dir=tmp_path / "state", stackshot_token=cfg / "client.token",
                        stackshot_url=cfg / "client.url", stackshot_web=WEB, admin_key=tmp_path / "none-key",
                        roles_cmd=["false"], sala_models=tmp_path / "none.tsv")
    app = create_app(settings)
    fake = FakeBoard()
    app.state.board.fetch = fake
    return app, fake, cfg, tmp_path / "state" / "board-items.json"


def board(client):
    """The answer once no background refresh runs."""
    for _ in range(250):
        r = client.get("/api/board-items")
        assert r.status_code == 200
        assert TOKEN not in r.text and "Bearer" not in r.text
        got = r.json()
        if not got.get("refreshing"):
            return got
        time.sleep(0.02)
    raise AssertionError("the refresh never landed")


def test_first_start_answers_at_once_then_fills_for_every_live_session(env):
    app, fake, _, saved = env
    with TestClient(app) as c:
        first = c.get("/api/board-items").json()
        assert first["pending"] is True and first["refreshing"] is True and first["fetchedAt"] is None and first["sessions"] == {}
        got = board(c)
    assert sorted(fake.calls) == ["demo", "demo-web", "gamma-harbor"]   # the live sessions, each once
    assert set(got["sessions"]) == {"demo", "demo-web", "gamma-harbor"}
    sala = got["sessions"]["demo"]
    assert sala["waiting"] == 1 and [i["id"] for i in sala["items"]] == ["board#21", "board#25", "s9", "board#18"]
    assert sala["items"][0] == {"id": "board#21", "subject": "[gamma] board#21", "needs": ["decision"], "waiting": True,
                                "held": False, "url": WEB + "/items/21"}
    assert got["sessions"]["gamma-harbor"] == {"items": [], "waiting": 0}
    assert isinstance(got["fetchedAt"], int) and "pending" not in got and "error" not in got and "partial" not in got
    on_disk = saved.read_text()
    assert TOKEN not in on_disk and "Bearer" not in on_disk and "Authorization" not in on_disk and URL not in on_disk
    assert json.loads(on_disk)["sessions"]["demo"]["waiting"] == 1
    assert oct(saved.stat().st_mode & 0o777) == oct(0o600)


def test_one_round_of_reads_per_minute_however_many_pages_ask(env, monkeypatch):
    app, fake, *_ = env
    with TestClient(app) as c:
        board(c)
        n = len(fake.calls)
        assert n == 3
        now = time.monotonic()
        for sec in range(0, 60, 5):   # many viewers over the minute: no further read
            monkeypatch.setattr(SWR.time, "monotonic", lambda s=sec: now + s)
            for _ in range(3):
                board(c)
        assert len(fake.calls) == n
        monkeypatch.setattr(SWR.time, "monotonic", lambda: now + B.TTL + 1)
        for _ in range(5):
            board(c)
    assert len(fake.calls) == 2 * n
    assert B.TTL == 60.0 and B.ERROR_RETRY < B.TTL


def test_a_restart_serves_the_saved_answer_and_refreshes_once_in_the_background(env):
    app, fake, cfg, saved = env
    old = {"sessions": {"demo": {"items": [{"id": "board#9001", "subject": "old", "needs": ["decision"], "waiting": True,
                                                   "held": False, "url": WEB + "/items/9001"}], "waiting": 1}},
           "fetchedAt": int((time.time() - 3600) * 1000)}
    SWR.write_atomic(saved, old)
    gate = threading.Event()

    def slow(url, token, key):
        assert gate.wait(10)
        return fake(url, token, key)

    app2 = create_app(app.state.settings)
    app2.state.board.fetch = slow
    try:
        with TestClient(app2) as c:
            t0 = time.monotonic()
            got = c.get("/api/board-items").json()
            assert time.monotonic() - t0 < 1   # never waits on the board
            assert got["sessions"]["demo"]["items"][0]["id"] == "board#9001" and got["fetchedAt"] == old["fetchedAt"] and got["refreshing"] is True
            assert c.get("/api/board-items").json()["sessions"]["demo"]["waiting"] == 1   # a second ask while it runs: no second round
            gate.set()
            fresh = board(c)
        assert fresh["sessions"]["demo"]["items"][0]["id"] == "board#21" and fresh["fetchedAt"] > old["fetchedAt"]
        assert json.loads(saved.read_text())["fetchedAt"] == fresh["fetchedAt"]
        assert sorted(fake.calls) == ["demo", "demo-web", "gamma-harbor"]   # one round
    finally:
        gate.set()


def test_a_restart_with_a_fresh_saved_answer_asks_nobody(env):
    app, fake, _, saved = env
    SWR.write_atomic(saved, {"sessions": {"demo": {"items": [], "waiting": 0}}, "fetchedAt": int(time.time() * 1000)})
    app2 = create_app(app.state.settings)
    app2.state.board.fetch = fake
    with TestClient(app2) as c:
        got = c.get("/api/board-items").json()
    assert got["sessions"] == {"demo": {"items": [], "waiting": 0}} and "refreshing" not in got and fake.calls == []


def test_missing_token_is_a_plain_message_and_nothing_is_asked(env):
    app, fake, cfg, saved = env
    (cfg / "client.token").unlink()
    with TestClient(app) as c:
        got = board(c)
    assert got["error"] == "No stackshot token on this machine." and got["sessions"] == {}
    assert fake.calls == [] and not saved.exists()
    (cfg / "client.token").write_text(TOKEN)
    (cfg / "client.url").unlink()
    app2 = create_app(app.state.settings)
    app2.state.board.fetch = fake
    with TestClient(app2) as c:
        got = board(c)
    assert got["error"] == "No stackshot server address on this machine." and fake.calls == []


def test_a_refused_token_an_unreachable_board_and_an_unexpected_error_carry_no_secret(env, monkeypatch):
    app, fake, *_ = env
    with TestClient(app) as c:
        first = board(c)
        now = time.monotonic()
        fake.fail = {k: B.Unauthorized() for k in ANSWERS}
        monkeypatch.setattr(SWR.time, "monotonic", lambda: now + B.TTL + 1)
        got = board(c)
        assert got["error"] == B.REFUSED and got["sessions"] == first["sessions"] and got["fetchedAt"] == first["fetchedAt"]
        fake.fail = {k: RuntimeError("stackshot unreachable (Connection refused)") for k in ANSWERS}
        monkeypatch.setattr(SWR.time, "monotonic", lambda: now + B.TTL + 1 + B.ERROR_RETRY + 1)
        got = board(c)
        assert got["error"] == "stackshot unreachable (Connection refused)" and got["sessions"] == first["sessions"]
        fake.fail = {k: KeyError(TOKEN) for k in ANSWERS}
        monkeypatch.setattr(SWR.time, "monotonic", lambda: now + B.TTL + 1 + 2 * (B.ERROR_RETRY + 1))
        got = board(c)
        assert got["error"] == "board could not be read (KeyError)"
        fake.fail = {}
        monkeypatch.setattr(SWR.time, "monotonic", lambda: now + B.TTL + 1 + 3 * (B.ERROR_RETRY + 1))
        got = board(c)
    assert "error" not in got and got["sessions"]["demo"]["waiting"] == 1


def test_a_session_whose_read_fails_keeps_its_last_answer(env, monkeypatch):
    app, fake, *_ = env
    with TestClient(app) as c:
        first = board(c)
        now = time.monotonic()
        fake.fail = {"demo": RuntimeError("stackshot answered HTTP 500")}
        ANSWERS["gamma-harbor"].append(item("board#30", ["decision"]))
        try:
            monkeypatch.setattr(SWR.time, "monotonic", lambda: now + B.TTL + 1)
            got = board(c)
        finally:
            ANSWERS["gamma-harbor"].pop()
    assert "error" not in got and got["partial"] == 1
    assert got["sessions"]["demo"] == first["sessions"]["demo"]        # the last answer stands
    assert got["sessions"]["gamma-harbor"]["waiting"] == 1                              # the others refreshed
    assert got["fetchedAt"] > first["fetchedAt"]


def test_at_most_four_reads_in_flight(tmp_path):
    cfg = tmp_path / "stackshot"
    cfg.mkdir()
    (cfg / "client.token").write_text(TOKEN)
    (cfg / "client.url").write_text(URL)
    fake = FakeBoard(delay=0.05)
    cache = B.BoardCache(cfg / "client.token", cfg / "client.url", WEB, None, fetch=fake)
    names = [f"s{i}" for i in range(12)]

    async def run():
        first = await cache.get(names)
        assert first["pending"] and first["refreshing"]
        for _ in range(200):
            await __import__("asyncio").sleep(0.02)
            got = await cache.get(names)
            if not got.get("refreshing"):
                return got
        raise AssertionError("never landed")

    got = __import__("asyncio").run(run())
    assert sorted(fake.calls) == sorted(names) and fake.max_inflight <= B.CONCURRENCY == 4 and fake.max_inflight >= 2
    assert set(got["sessions"]) == set(names)


def test_read_url_takes_the_environment_over_the_file_and_refuses_a_non_url(tmp_path, monkeypatch):
    f = tmp_path / "client.url"
    f.write_text("http://127.0.0.1:8020/\n")
    monkeypatch.delenv("STACKSHOT_URL", raising=False)
    assert B.read_url(f) == "http://127.0.0.1:8020"
    monkeypatch.setenv("STACKSHOT_URL", "https://board.example/")
    assert B.read_url(f) == "https://board.example"
    monkeypatch.delenv("STACKSHOT_URL", raising=False)
    f.write_text("not a url")
    with pytest.raises(B.ConfigError):
        B.read_url(f)


def test_fetch_items_request_and_errors(monkeypatch):
    seen = {}

    class Resp:
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def read(self):
            return b'{"items": []}'

    def ok(req, timeout):
        seen.update(url=req.full_url, auth=req.get_header("Authorization"), method=req.get_method())
        return Resp()

    monkeypatch.setattr(B.urllib.request, "urlopen", ok)
    assert B.fetch_items(URL, TOKEN, "demo key/x") == {"items": []}
    assert seen["url"] == URL + "/client/items?key=demo+key%2Fx" and seen["auth"] == "Bearer " + TOKEN and seen["method"] == "GET"
    assert TOKEN not in seen["url"]

    def status(code):
        def f(req, timeout):
            raise urllib.error.HTTPError(req.full_url, code, "x", {}, None)
        return f

    monkeypatch.setattr(B.urllib.request, "urlopen", status(401))
    with pytest.raises(B.Unauthorized):
        B.fetch_items(URL, TOKEN, "k")
    monkeypatch.setattr(B.urllib.request, "urlopen", status(500))
    with pytest.raises(RuntimeError, match="HTTP 500") as e:
        B.fetch_items(URL, TOKEN, "k")
    assert TOKEN not in str(e.value) and URL not in str(e.value)

    def down(req, timeout):
        raise urllib.error.URLError(OSError(111, "Connection refused"))

    monkeypatch.setattr(B.urllib.request, "urlopen", down)
    with pytest.raises(RuntimeError, match="unreachable") as e:
        B.fetch_items(URL, TOKEN, "k")
    assert TOKEN not in str(e.value)
