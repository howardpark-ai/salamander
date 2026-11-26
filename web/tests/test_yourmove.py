"""The chat page's Your move strip reads stackshot's whole Your move list (yourmove.py), not the per-session board feed.

What is held: the group's name that rides on the answer (`group`: {"en", "ko"}, taken whole or not at all: both words 1..40 characters once stripped, no control
character, no markup; an older stackshot's answer with none, or a bad one, is no group and never an error), kept with the list, in the state file and in GET /api/chat; the parse (every item in the order sent, each id once, no cap, a row without an id left out, an answer that is no list
refused); the cache (answered at once from the last good list, a refresh in the background, the first answer None so the page falls back
to the feed, an empty list an answer); a failed read keeping the last good list for ten minutes and the feed after that; the state file
carrying no token; the read itself against a stand-in stackshot on a real socket (bearer token, the path, a 401); and GET /api/chat end to
end: seven moves where the feed has two, the read failing (the cached list, then the feed), an empty list an empty strip.
The client API is a fake; the real token file is never read (conftest points the defaults at missing files). All names are invented."""

import asyncio
import json
import os
import time
import types

import pytest
from starlette.testclient import TestClient

from fake_stackshot import FakeStackshot
from sala_web import board as B
from sala_web import sessions as S
from sala_web import yourmove as YM
from sala_web.app import create_app
from sala_web.config import Settings

TOKEN = "[masked machine token]"
SESSION = "chat-test-ada"


def move(n, subject=None, **kw):
    d = {"shown": f"item#{n}", "subject": subject or f"[x] move {n}", "url": f"https://tracker.example.test/t/{n}", "ask": "Which one?", "updated": 1792800000.0 + n}
    d.update(kw)
    return d


def ids(rows):
    return [r["id"] for r in rows]


class FakeRead:
    """stackshot's read: answers `reply` (a list of rows, or an exception to raise), counts the calls, keeps what it was given."""

    def __init__(self, reply, group=None):
        self.reply = reply
        self.group = group          # the answer's "group", whatever it is; None leaves the key out (an older stackshot)
        self.calls = []

    def __call__(self, url, token):
        self.calls.append((url, token))
        if isinstance(self.reply, BaseException):
            raise self.reply
        return {"items": self.reply} if self.group is None else {"items": self.reply, "group": self.group}


def cache_for(tmp_path, fetch, state=True):
    cfg = tmp_path / "cfg"
    cfg.mkdir(exist_ok=True)
    (cfg / "client.token").write_text(TOKEN + "\n")
    (cfg / "client.url").write_text("http://127.0.0.1:1\n")
    return YM.YourMoveCache(cfg / "client.token", cfg / "client.url", (tmp_path / "state" / "your-move.json") if state else None, fetch=fetch)


async def settle(cache):
    """The list once the background refresh that is running has landed."""
    got = cache.items()
    task = cache._swr._task
    if task is not None:
        await task
        got = cache.items()
    return got


def run(coro):
    return asyncio.run(coro)


# ---------- the parse ----------

def test_parse_keeps_every_item_in_the_order_sent_with_the_strips_fields():
    rows = YM.parse({"items": [move(7), move(3, subject="  two   words "), move(5)]})
    assert rows == [{"id": "item#7", "subject": "[x] move 7", "url": "https://tracker.example.test/t/7"},
                    {"id": "item#3", "subject": "two words", "url": "https://tracker.example.test/t/3"},
                    {"id": "item#5", "subject": "[x] move 5", "url": "https://tracker.example.test/t/5"}]


def test_parse_has_no_cap_at_twenty_or_a_hundred_items():
    assert ids(YM.parse({"items": [move(i) for i in range(1, 151)]})) == [f"item#{i}" for i in range(1, 151)]


def test_parse_leaves_out_a_row_without_an_id_and_a_repeat_and_keeps_a_row_without_a_url():
    rows = YM.parse({"items": [move(1), {"subject": "no id"}, "junk", None, move(1, subject="again"), move(2, url="javascript:alert(1)"), move(3, url="/t/3")]})
    assert ids(rows) == ["item#1", "item#2", "item#3"]
    assert rows[0]["subject"] == "[x] move 1"        # the first of a repeated id stands
    assert rows[1]["url"] == "" and rows[2]["url"] == "/t/3"


def test_parse_of_an_empty_group_is_an_empty_list_and_of_anything_else_an_error():
    assert YM.parse({"items": []}) == []
    for bad in (None, [], {}, {"items": "x"}, "text"):
        with pytest.raises(RuntimeError):
            YM.parse(bad)


# ---------- the cache ----------

def test_the_first_answer_is_none_so_the_page_uses_the_feed_then_the_list_lands(tmp_path):
    fake = FakeRead([move(i) for i in (4, 1, 3)])
    cache = cache_for(tmp_path, fake)

    async def go():
        assert cache.items() is None                       # asked at once, never waited for
        return await settle(cache)
    got = run(go())
    assert ids(got) == ["item#4", "item#1", "item#3"] and len(fake.calls) == 1
    assert fake.calls[0] == ("http://127.0.0.1:1", TOKEN)


def test_seven_items_are_seven_entries_in_order(tmp_path):
    fake = FakeRead([move(i) for i in (7, 6, 5, 4, 3, 2, 1)])
    got = run(settle(cache_for(tmp_path, fake)))
    assert ids(got) == [f"item#{i}" for i in (7, 6, 5, 4, 3, 2, 1)]


def test_an_empty_group_is_an_empty_list_which_is_an_answer(tmp_path):
    got = run(settle(cache_for(tmp_path, FakeRead([]))))
    assert got == [] and got is not None


def test_the_list_is_read_at_most_once_per_ttl_however_many_pages_ask(tmp_path):
    fake = FakeRead([move(1)])
    cache = cache_for(tmp_path, fake)

    async def go():
        await settle(cache)
        for _ in range(20):
            cache.items()
        await asyncio.sleep(0)
    run(go())
    assert len(fake.calls) == 1


def test_a_failed_read_keeps_the_last_good_list_and_says_nothing_wrong(tmp_path):
    fake = FakeRead([move(1), move(2)])
    cache = cache_for(tmp_path, fake)

    async def go():
        first = await settle(cache)
        fake.reply = RuntimeError("stackshot unreachable (refused)")
        cache._swr.expire()
        after = await settle(cache)
        return first, after
    first, after = run(go())
    assert ids(first) == ids(after) == ["item#1", "item#2"]
    assert len(fake.calls) == 2


def test_the_last_good_list_stands_for_ten_minutes_then_the_feed_takes_over(tmp_path, monkeypatch):
    fake = FakeRead([move(1)])
    cache = cache_for(tmp_path, fake)

    async def go():
        await settle(cache)
        fake.reply = RuntimeError("stackshot unreachable (refused)")
        t0 = time.time()
        out = []
        for later in (60, YM.STALE_MAX - 5, YM.STALE_MAX + 5):
            monkeypatch.setattr(YM, "time", types.SimpleNamespace(time=lambda later=later: t0 + later))
            cache._swr.expire()
            out.append(await settle(cache))
        return out
    inside_a, inside_b, outside = run(go())
    assert ids(inside_a) == ids(inside_b) == ["item#1"] and outside is None


def test_with_nothing_cached_and_the_read_failing_the_answer_is_none(tmp_path):
    cache = cache_for(tmp_path, FakeRead(RuntimeError("stackshot answered HTTP 502")))
    assert run(settle(cache)) is None


@pytest.mark.parametrize("err", [B.Unauthorized(), ValueError("x"), KeyError("k")])
def test_a_refused_or_broken_read_is_none_and_never_leaks_the_token(tmp_path, err):
    cache = cache_for(tmp_path, FakeRead(err))
    assert run(settle(cache)) is None
    assert TOKEN not in json.dumps(cache._swr.state, default=str)


def test_a_missing_token_file_is_a_plain_failure_not_a_crash(tmp_path):
    cache = YM.YourMoveCache(tmp_path / "no-token", tmp_path / "no-url", None, fetch=FakeRead([move(1)]))
    assert run(settle(cache)) is None


def test_the_saved_list_is_text_without_the_token_and_a_restart_serves_it(tmp_path):
    fake = FakeRead([move(2), move(1)])
    saved = tmp_path / "state" / "your-move.json"
    run(settle(cache_for(tmp_path, fake)))
    on_disk = saved.read_text()
    assert TOKEN not in on_disk and "Bearer" not in on_disk and "127.0.0.1" not in on_disk
    assert [r["id"] for r in json.loads(on_disk)["items"]] == ["item#2", "item#1"]
    again = cache_for(tmp_path, FakeRead(RuntimeError("down")))     # a restart, the server down
    assert ids(again.items()) == ["item#2", "item#1"]


# ---------- the read itself, against a stand-in on a real socket ----------

@pytest.fixture
def fake_stack(tmp_path):
    f = FakeStackshot(tmp_path / "stackshot-cfg")
    yield f
    f.close()


def test_the_read_sends_the_bearer_token_to_the_your_move_route(fake_stack):
    fake_stack.your_move = [move(i) for i in range(1, 26)]
    got = YM.fetch_your_move(fake_stack.url, fake_stack.token)
    assert len(YM.parse(got)) == 25
    assert [r["path"] for r in fake_stack.requests] == ["/client/your-move"]
    assert "query" in fake_stack.requests[0] and fake_stack.requests[0]["query"] == {}      # no key, no query


def test_the_read_maps_a_401_and_other_errors_without_the_token(fake_stack):
    with pytest.raises(B.Unauthorized):
        YM.fetch_your_move(fake_stack.url, "wrong")
    fake_stack.your_move_reply = (503, "busy")
    with pytest.raises(RuntimeError) as e:
        YM.fetch_your_move(fake_stack.url, fake_stack.token)
    assert "503" in str(e.value) and fake_stack.token not in str(e.value) and fake_stack.url not in str(e.value)
    fake_stack.your_move_reply = (200, "not json")
    with pytest.raises(RuntimeError):
        YM.fetch_your_move(fake_stack.url, fake_stack.token)


# ---------- GET /api/chat end to end ----------

def feed_rows(*ns):
    return [{"shown": f"item#{n}", "subject": f"[x] feed {n}", "needs": ["decision"], "held": False} for n in ns]


@pytest.fixture
def chat_app(tmp_path, monkeypatch, fake_stack):
    monkeypatch.setenv("SALA_CHAT_SESSION", SESSION)
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    pid = os.getpid()
    (claude / "sessions" / f"{pid}.json").write_text(json.dumps(
        {"pid": pid, "sessionId": "bbbbbbbb-0000-4000-8000-000000000002", "name": SESSION, "cwd": "/x", "status": "idle", "tmux": "x:@0.%0",
         "procStart": S.proc_start(pid)}))
    monkeypatch.setattr(S, "live_tmux_names", lambda: {})
    settings = Settings(claude_dir=claude, state_dir=tmp_path / "state", stackshot_token=fake_stack.token_file, stackshot_url=fake_stack.url_file,
                        stackshot_web="https://tracker.example.test", admin_key=tmp_path / "none-key", roles_cmd=["false"], sala_models=tmp_path / "none.tsv")
    app = create_app(settings)
    feed = {"rows": feed_rows(1, 2)}
    app.state.board.fetch = lambda url, token, key: {"items": feed["rows"]}
    return app, feed, fake_stack


def chat(client, *, expect=None):
    """/api/chat once neither background read is running (and, with `expect`, until the strip has those ids)."""
    app = client.app
    for _ in range(300):
        r = client.get("/api/chat")
        assert r.status_code == 200
        assert TOKEN not in r.text and "Bearer" not in r.text
        quiet = not app.state.board._swr.running and not app.state.your_move._swr.running
        if quiet and (expect is None or ids(r.json()["waiting"]) == expect):
            return r.json()
        time.sleep(0.02)
    raise AssertionError("the reads never settled: " + json.dumps(r.json()["waiting"]))


def test_the_strip_shows_all_seven_moves_where_the_feed_has_two(chat_app):
    app, feed, stack = chat_app
    stack.your_move = [move(i) for i in (7, 1, 6, 2, 5, 3, 4)]
    with TestClient(app) as c:
        d = chat(c, expect=[f"item#{i}" for i in (7, 1, 6, 2, 5, 3, 4)])
    assert len(d["waiting"]) == 7 and d["waiting"][0] == {"id": "item#7", "subject": "[x] move 7", "url": "https://tracker.example.test/t/7"}


def test_the_strip_is_not_capped_at_twenty_five_moves(chat_app):
    app, feed, stack = chat_app
    stack.your_move = [move(i) for i in range(1, 26)]
    with TestClient(app) as c:
        d = chat(c, expect=[f"item#{i}" for i in range(1, 26)])
    assert len(d["waiting"]) == 25


def test_an_empty_your_move_group_is_an_empty_strip_even_when_the_feed_has_rows(chat_app):
    app, feed, stack = chat_app
    stack.your_move = []
    with TestClient(app) as c:
        d = chat(c, expect=[])
    assert d["waiting"] == []


def test_the_read_failing_keeps_the_last_good_list_then_falls_back_to_the_feed(chat_app, monkeypatch):
    app, feed, stack = chat_app
    stack.your_move = [move(i) for i in (3, 2, 1)]
    with TestClient(app) as c:
        assert ids(chat(c, expect=["item#3", "item#2", "item#1"])["waiting"]) == ["item#3", "item#2", "item#1"]
        stack.your_move_reply = (502, "bad gateway")
        app.state.your_move._swr.expire()
        assert ids(chat(c, expect=["item#3", "item#2", "item#1"])["waiting"]) == ["item#3", "item#2", "item#1"]   # the cached list
        t0 = time.time()
        monkeypatch.setattr(YM, "time", types.SimpleNamespace(time=lambda: t0 + YM.STALE_MAX + 30))
        app.state.your_move._swr.expire()
        assert ids(chat(c, expect=["item#1", "item#2"])["waiting"]) == ["item#1", "item#2"]                       # the feed's two


def test_with_no_list_ever_read_the_strip_is_the_feeds(chat_app):
    app, feed, stack = chat_app
    stack.your_move_reply = (500, "boom")
    with TestClient(app) as c:
        d = chat(c, expect=["item#1", "item#2"])
    assert [w["subject"] for w in d["waiting"]] == ["[x] feed 1", "[x] feed 2"]


# ---------- the group's name: stackshot's own words for the strip ----------

def cp(*codes):
    return "".join(chr(c) for c in codes)


KO_LABEL = cp(0xACB0, 0xC815)          # a made-up Korean label for the renamed group
GOOD = {"en": "Decide demo", "ko": KO_LABEL}


def test_parse_group_takes_a_well_formed_group_whole_and_strips_the_words():
    assert YM.parse_group({"items": [], "group": GOOD}) == GOOD
    assert YM.parse_group({"items": [], "group": {"en": "  Decide  ", "ko": f" {KO_LABEL} ", "extra": 1}}) == {"en": "Decide", "ko": KO_LABEL}
    assert YM.parse_group({"group": {"en": "x" * 40, "ko": "y"}}) == {"en": "x" * 40, "ko": "y"}          # 40 is the longest
    assert YM.parse_group({"group": {"en": "Same", "ko": "Same"}}) == {"en": "Same", "ko": "Same"}        # no catalog: ko equals en, still a group


@pytest.mark.parametrize("group", [
    None, "Your move", 7, [], ["a", "b"], {}, {"en": "Only"}, {"ko": "Only"}, {"en": "a", "ko": None}, {"en": 1, "ko": 2}, {"en": ["a"], "ko": "b"},
    {"en": "", "ko": "b"}, {"en": "a", "ko": "   "}, {"en": "x" * 41, "ko": "b"}, {"en": "a", "ko": "y" * 41},
    {"en": "<b>Group</b>", "ko": "b"}, {"en": "a", "ko": "x > y"},
    {"en": "line\nbreak", "ko": "b"}, {"en": "a", "ko": "tab\there"}, {"en": "nul\x00", "ko": "b"}, {"en": "a\n", "ko": "b"},
    {"en": "zero" + chr(0x200B) + "width", "ko": "b"}, {"en": "a", "ko": "bidi" + chr(0x202E) + "flip"}, {"en": "esc\x1b[31m", "ko": "b"},
])
def test_parse_group_is_no_group_for_anything_else_and_never_raises(group):
    assert YM.parse_group({"items": [], "group": group}) is None


@pytest.mark.parametrize("body", [None, [], "text", 3, {}, {"items": []}])
def test_parse_group_is_no_group_when_the_answer_has_none(body):
    assert YM.parse_group(body) is None


def test_the_group_rides_with_the_list_and_a_bad_group_leaves_the_list_alone(tmp_path):
    cache = cache_for(tmp_path, FakeRead([move(1), move(2)], group=GOOD))
    got = run(settle(cache))
    assert ids(got) == ["item#1", "item#2"] and cache.group() == GOOD
    for i, bad in enumerate(({"en": "<i>x</i>", "ko": "y"}, {"en": "only"}, "text")):
        (tmp_path / f"o{i}").mkdir()
        other = cache_for(tmp_path / f"o{i}", FakeRead([move(1)], group=bad))
        assert ids(run(settle(other))) == ["item#1"] and other.group() is None


def test_an_older_stackshot_has_no_group_and_a_later_answer_without_one_drops_it(tmp_path):
    fake = FakeRead([move(1)])
    cache = cache_for(tmp_path, fake)
    assert ids(run(settle(cache))) == ["item#1"] and cache.group() is None

    async def go():
        fake.group = GOOD
        cache._swr.expire()
        await settle(cache)
        first = cache.group()
        fake.group = None                       # stackshot rolled back to a version that sends none
        cache._swr.expire()
        await settle(cache)
        return first, cache.group()
    first, after = run(go())
    assert first == GOOD and after is None


def test_a_failed_read_keeps_the_last_good_group_and_it_goes_with_the_list_after_ten_minutes(tmp_path, monkeypatch):
    fake = FakeRead([move(1)], group=GOOD)
    cache = cache_for(tmp_path, fake)

    async def go():
        await settle(cache)
        fake.reply = RuntimeError("stackshot unreachable (refused)")
        t0 = time.time()
        out = []
        for later in (60, YM.STALE_MAX + 5):
            monkeypatch.setattr(YM, "time", types.SimpleNamespace(time=lambda later=later: t0 + later))
            cache._swr.expire()
            await settle(cache)
            out.append(cache.group())
        return out
    inside, outside = run(go())
    assert inside == GOOD and outside is None


def test_the_saved_state_carries_the_group_a_restart_serves_it_and_an_old_or_edited_file_has_none(tmp_path):
    saved = tmp_path / "state" / "your-move.json"
    run(settle(cache_for(tmp_path, FakeRead([move(1)], group=GOOD))))
    assert json.loads(saved.read_text())["group"] == GOOD and TOKEN not in saved.read_text()
    assert cache_for(tmp_path, FakeRead(RuntimeError("down"))).group() == GOOD
    doc = json.loads(saved.read_text())
    del doc["group"]                                                  # a file an older sala wrote
    saved.write_text(json.dumps(doc))
    again = cache_for(tmp_path, FakeRead(RuntimeError("down")))
    assert ids(again.items()) == ["item#1"] and again.group() is None
    doc["group"] = {"en": "<b>x</b>", "ko": "y"}                      # a hand-edited file is read again, not trusted
    saved.write_text(json.dumps(doc))
    assert cache_for(tmp_path, FakeRead(RuntimeError("down"))).group() is None


def test_the_stand_in_answer_with_a_group_reaches_api_chat_and_a_later_bad_one_drops_it(chat_app):
    app, feed, stack = chat_app
    stack.your_move = [move(1)]
    stack.your_move_group = GOOD
    with TestClient(app) as c:
        d = chat(c, expect=["item#1"])
        assert d["group"] == GOOD and d["waiting"][0]["id"] == "item#1"
        stack.your_move_group = {"en": "Renamed", "ko": "<bad>"}      # a bad group on a later read: no group, the list stays
        app.state.your_move._swr.expire()
        for _ in range(300):
            d = chat(c, expect=["item#1"])
            if d["group"] is None:
                break
            time.sleep(0.02)
        assert d["group"] is None and d["waiting"][0]["id"] == "item#1"


def test_api_chat_has_no_group_for_an_older_stackshot(chat_app):
    app, feed, stack = chat_app
    stack.your_move = [move(1)]                                       # no group key in the answer
    with TestClient(app) as c:
        assert chat(c, expect=["item#1"])["group"] is None


def test_api_chat_has_no_group_while_the_strip_is_the_feeds(chat_app):
    app, feed, stack = chat_app
    stack.your_move_group = GOOD
    stack.your_move_reply = (500, "boom")                             # no list read: the feed's rows, and no group
    with TestClient(app) as c:
        d = chat(c, expect=["item#1", "item#2"])
    assert d["group"] is None
