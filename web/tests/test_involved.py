"""The second tab of the chat strip ("On it") is fed by stackshot's read of the items the chat session is the contact of or an observer on (involved.py).

What is held: the parse (every item in the order sent, each id once, no cap, only the fields the tab uses, an address kept only when it is a whole http(s) one, a
day and a time kept only when they are one, an answer that is no list refused); the cache (answered at once from the last good list, a refresh in the background,
nothing until a first answer, an empty list an answer, a failed read keeping the last good list for ten minutes and nothing after, an answer never handed out for
another session than the one it was read for, a state file with no token); the read itself against a stand-in stackshot on a real socket (bearer token, the path,
the key, a 401, a 404); GET /api/chat end to end (the key `onIt` only while the read is available, the session's name from the setting and never from a request,
nothing read with no chat session, a second session changing nothing); and, in node, the page's own helpers for a row: late after two days and red after five,
never for a held or timeless one, since when, the day a held one comes back, who moves it, all as text.
The page in a browser is test_chat_onit_ui.py. The client API is a fake; the real token file is never read (conftest points the defaults at missing files). All names
are invented; Korean is built from code points."""

import asyncio
import json
import os
import re
import time
import types

import pytest
from starlette.testclient import TestClient

from fake_stackshot import FakeStackshot
from i18n_node import STATIC, prelude
from sala_web import board as B
from sala_web import involved as IV
from sala_web import sessions as S
from sala_web.app import create_app
from sala_web.config import Settings
from test_i18n import needs_node, run_node

TOKEN = "demo-token-for-tests"
SESSION = "chat-test-ada"
OTHER = "demo-other-session"
T0 = 1792800000.0


def cp(*codes):
    return "".join(chr(c) for c in codes)


def item(n, subject=None, **kw):
    d = {"shown": f"demo#{n}", "subject": subject or f"[x] promise {n}", "url": f"https://tracker.example.test/promises/{n}", "mover": "x-demo-engineer",
         "contact": SESSION, "observers": [], "list": "agents", "held": False, "until": None, "state_updated": T0 + n, "updated": T0 + n}
    d.update(kw)
    return d


def row(n, **kw):
    d = {"id": f"demo#{n}", "subject": f"[x] promise {n}", "url": f"https://tracker.example.test/promises/{n}", "mover": "x-demo-engineer",
         "held": False, "until": None, "since": int(T0 + n)}
    d.update(kw)
    return d


def ids(rows):
    return [r["id"] for r in rows]


# ---------- the parse ----------

def test_parse_keeps_every_item_in_the_order_sent_with_only_the_fields_the_tab_uses():
    got = IV.parse({"items": [item(7), item(3, subject="  two \n  words "), item(5, list="your-move", mover="demo owner"),
                              item(2, held=True, until="2027-01-12", list="waiting")]})
    assert got == [row(7), row(3, subject="two words"), row(5, mover="demo owner"), row(2, held=True, until="2027-01-12")]


def test_parse_has_no_cap_and_an_empty_answer_is_an_empty_list():
    assert ids(IV.parse({"items": [item(i) for i in range(1, 151)]})) == [f"demo#{i}" for i in range(1, 151)]
    assert IV.parse({"items": []}) == []


def test_parse_leaves_out_a_row_without_an_id_and_a_repeat():
    got = IV.parse({"items": [item(1), {"subject": "no id"}, "junk", None, item(1, subject="again"), item(2)]})
    assert ids(got) == ["demo#1", "demo#2"] and got[0]["subject"] == "[x] promise 1"


@pytest.mark.parametrize("url", ["", "/items/3", "items/3", "javascript:alert(1)", "data:text/html,x", "//elsewhere.example.test/3", None, 7])
def test_parse_keeps_an_address_only_when_it_is_a_whole_http_one(url):
    assert IV.parse({"items": [item(1, url=url)]})[0]["url"] == ""


def test_parse_keeps_a_http_and_a_https_address():
    got = IV.parse({"items": [item(1, url="http://a.example.test/promises/1"), item(2, url=" https://b.example.test/promises/2 ")]})
    assert [r["url"] for r in got] == ["http://a.example.test/promises/1", "https://b.example.test/promises/2"]


@pytest.mark.parametrize("until", [None, "", "soon", "2027-13-01", "2027-02-30", "2027-1-2", "2027-01-12T09:00", 20270112, ["2027-01-12"]])
def test_parse_keeps_a_day_only_when_it_is_one(until):
    assert IV.parse({"items": [item(1, held=True, until=until)]})[0]["until"] is None


@pytest.mark.parametrize("since", [None, "yesterday", True, 0, -5, 1e12, float("nan"), float("inf"), {}])
def test_parse_keeps_a_time_only_when_it_is_one(since):
    assert IV.parse({"items": [item(1, state_updated=since)]})[0]["since"] is None


def test_parse_takes_the_since_of_the_state_and_not_of_the_last_write_and_tolerates_odd_words():
    got = IV.parse({"items": [item(1, state_updated=None, updated=T0), item(2, mover=None, held="yes"), item(3, mover={"name": "x"}),
                              item(4, mover="  a \n b "), item(5, mover="m" * 500, subject="s" * 5000)]})
    assert got[0]["since"] is None
    assert got[1]["mover"] == "" and got[1]["held"] is False and got[2]["mover"] == "" and got[3]["mover"] == "a b"
    assert len(got[4]["mover"]) == IV.MOVER_MAX and len(got[4]["subject"]) < 5000


@pytest.mark.parametrize("bad", [None, [], {}, {"items": "x"}, {"items": {}}, "text", 3])
def test_parse_of_anything_that_is_no_list_of_items_is_an_error(bad):
    with pytest.raises(RuntimeError):
        IV.parse(bad)


# ---------- the cache ----------

class FakeRead:
    """stackshot's read: answers `reply` (a list of items, or an exception to raise) and keeps what it was given."""

    def __init__(self, reply):
        self.reply = reply
        self.calls = []

    def __call__(self, url, token, key):
        self.calls.append((url, token, key))
        if isinstance(self.reply, BaseException):
            raise self.reply
        return {"items": self.reply}


def cache_for(tmp_path, fetch, state=True):
    cfg = tmp_path / "cfg"
    cfg.mkdir(exist_ok=True)
    (cfg / "client.token").write_text(TOKEN + "\n")
    (cfg / "client.url").write_text("http://127.0.0.1:1\n")
    return IV.InvolvedCache(cfg / "client.token", cfg / "client.url", (tmp_path / "state" / "involved.json") if state else None, fetch=fetch)


async def settle(cache, key=SESSION):
    """The list once the background refresh that is running has landed."""
    got = cache.items(key)
    task = cache._swr._task
    if task is not None:
        await task
        got = cache.items(key)
    return got


def run(coro):
    return asyncio.run(coro)


def restart(tmp_path, key):
    """What a new process hands out for `key` from the saved state, the server down."""
    cache = cache_for(tmp_path, FakeRead(RuntimeError("down")))

    async def go():
        at_once = cache.items(key)
        await settle(cache, key)
        return at_once
    return run(go())


def test_the_first_answer_is_none_then_the_list_lands_read_for_that_session(tmp_path):
    fake = FakeRead([item(4), item(1)])
    cache = cache_for(tmp_path, fake)

    async def go():
        assert cache.items(SESSION) is None                      # asked at once, never waited for
        return await settle(cache)
    assert ids(run(go())) == ["demo#4", "demo#1"]
    assert fake.calls == [("http://127.0.0.1:1", TOKEN, SESSION)]


def test_an_empty_list_is_an_answer(tmp_path):
    got = run(settle(cache_for(tmp_path, FakeRead([]))))
    assert got == [] and got is not None


def test_the_list_is_read_at_most_once_per_ttl_however_many_pages_ask(tmp_path):
    fake = FakeRead([item(1)])
    cache = cache_for(tmp_path, fake)

    async def go():
        await settle(cache)
        for _ in range(20):
            cache.items(SESSION)
        await asyncio.sleep(0)
    run(go())
    assert len(fake.calls) == 1


def test_a_failed_read_keeps_the_last_good_list_for_ten_minutes_and_then_there_is_none(tmp_path, monkeypatch):
    fake = FakeRead([item(1)])
    cache = cache_for(tmp_path, fake)

    async def go():
        await settle(cache)
        fake.reply = RuntimeError("stackshot unreachable (refused)")
        t0 = time.time()
        out = []
        for later in (60, IV.STALE_MAX - 5, IV.STALE_MAX + 5):
            monkeypatch.setattr(IV, "time", types.SimpleNamespace(time=lambda later=later: t0 + later))
            cache._swr.expire()
            out.append(await settle(cache))
        return out
    inside_a, inside_b, outside = run(go())
    assert ids(inside_a) == ids(inside_b) == ["demo#1"] and outside is None
    assert len(fake.calls) == 4


@pytest.mark.parametrize("err", [RuntimeError("stackshot answered HTTP 404"), RuntimeError("stackshot answered HTTP 502"), B.Unauthorized(), ValueError("x"), KeyError("k")])
def test_with_nothing_read_a_failing_read_is_none_and_keeps_no_token(tmp_path, err):
    cache = cache_for(tmp_path, FakeRead(err))
    assert run(settle(cache)) is None
    assert TOKEN not in json.dumps(cache._swr.state, default=str)


def test_an_answer_that_is_no_list_is_none(tmp_path):
    assert run(settle(cache_for(tmp_path, lambda url, token, key: {"items": "x"}))) is None


def test_a_missing_token_file_is_a_plain_failure_not_a_crash(tmp_path):
    fake = FakeRead([item(1)])
    cache = IV.InvolvedCache(tmp_path / "no-token", tmp_path / "no-url", None, fetch=fake)
    assert run(settle(cache)) is None and fake.calls == []


def test_the_saved_list_is_text_without_the_token_and_a_restart_serves_it_to_the_same_session_only(tmp_path):
    saved = tmp_path / "state" / "involved.json"
    run(settle(cache_for(tmp_path, FakeRead([item(2), item(1)]))))
    on_disk = saved.read_text()
    assert TOKEN not in on_disk and "Bearer" not in on_disk and "127.0.0.1" not in on_disk
    assert json.loads(on_disk)["key"] == SESSION and ids(json.loads(on_disk)["items"]) == ["demo#2", "demo#1"]
    assert ids(restart(tmp_path, SESSION)) == ["demo#2", "demo#1"]
    assert restart(tmp_path, OTHER) is None


def test_a_saved_file_that_names_no_session_is_not_trusted(tmp_path):
    saved = tmp_path / "state" / "involved.json"
    run(settle(cache_for(tmp_path, FakeRead([item(1)]))))
    doc = json.loads(saved.read_text())
    del doc["key"]
    saved.write_text(json.dumps(doc))
    assert restart(tmp_path, SESSION) is None


def test_when_the_setting_names_another_session_the_old_ones_list_is_never_handed_out(tmp_path):
    fake = FakeRead([item(1)])
    cache = cache_for(tmp_path, fake)

    async def go():
        await settle(cache)
        fake.reply = [item(9)]
        at_once = cache.items(OTHER)
        return at_once, await settle(cache, OTHER)
    at_once, after = run(go())
    assert at_once is None and ids(after) == ["demo#9"]
    assert [c[2] for c in fake.calls] == [SESSION, OTHER]


# ---------- the read itself, against a stand-in on a real socket ----------

@pytest.fixture
def fake_stack(tmp_path):
    f = FakeStackshot(tmp_path / "stackshot-cfg")
    yield f
    f.close()


def test_the_read_sends_the_bearer_token_and_the_session_as_the_key(fake_stack):
    odd = "a session&key=other #1"
    fake_stack.involved = {SESSION: [item(i) for i in range(1, 26)], odd: [item(99)]}
    assert len(IV.parse(IV.fetch_involved(fake_stack.url, fake_stack.token, SESSION))) == 25
    assert ids(IV.parse(IV.fetch_involved(fake_stack.url, fake_stack.token, odd))) == ["demo#99"]      # sent encoded: one key, whatever it holds
    assert IV.parse(IV.fetch_involved(fake_stack.url, fake_stack.token, "demo-unknown")) == []
    assert [(r["path"], r["query"]) for r in fake_stack.requests] == [("/client/involved", {"key": k}) for k in (SESSION, odd, "demo-unknown")]


def test_the_read_maps_a_401_a_server_without_it_and_other_errors_without_the_token(fake_stack):
    with pytest.raises(B.Unauthorized):
        IV.fetch_involved(fake_stack.url, "wrong", SESSION)
    for reply, said in ((None, "404"), ((400, "key is required"), "400"), ((503, "busy"), "503"), ((200, "not json"), "unreadable")):
        fake_stack.involved_reply = reply
        with pytest.raises(RuntimeError) as e:
            IV.fetch_involved(fake_stack.url, fake_stack.token, SESSION)
        assert said in str(e.value) and fake_stack.token not in str(e.value) and fake_stack.url not in str(e.value)


# ---------- GET /api/chat end to end ----------

def write_session(claude, name, sid, pid):
    (claude / "sessions" / f"{pid}.json").write_text(json.dumps(
        {"pid": pid, "sessionId": sid, "name": name, "cwd": "/x", "status": "idle", "tmux": "x:@0.%0", "procStart": S.proc_start(pid)}))


@pytest.fixture
def chat_app(tmp_path, monkeypatch, fake_stack):
    monkeypatch.setenv("SALA_CHAT_SESSION", SESSION)
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    write_session(claude, SESSION, "bbbbbbbb-0000-4000-8000-000000000002", os.getpid())
    write_session(claude, OTHER, "cccccccc-0000-4000-8000-000000000003", os.getppid())
    monkeypatch.setattr(S, "live_tmux_names", lambda: {})
    settings = Settings(claude_dir=claude, state_dir=tmp_path / "state", stackshot_token=fake_stack.token_file, stackshot_url=fake_stack.url_file,
                        stackshot_web="https://tracker.example.test", admin_key=tmp_path / "none-key", roles_cmd=["false"], sala_models=tmp_path / "none.tsv")
    app = create_app(settings)
    app.state.board.fetch = lambda url, token, key: {"items": []}
    return app, fake_stack


def chat(client, path="/api/chat", *, until=None):
    """/api/chat once no background read is running (and, with `until`, until the answer passes it)."""
    state = client.app.state
    d = None
    for _ in range(300):
        r = client.get(path)
        assert r.status_code == 200
        assert client.app_token not in r.text and "Bearer" not in r.text
        d = r.json()
        quiet = not (state.board._swr.running or state.your_move._swr.running or state.involved._swr.running)
        if quiet and (until is None or until(d)):
            return d
        time.sleep(0.02)
    raise AssertionError("the reads never settled: " + json.dumps(d))


def client_for(app, stack):
    c = TestClient(app)
    c.app_token = stack.token
    return c


def asked(stack):
    return [r["query"] for r in stack.requests if r["path"] == "/client/involved"]


def test_api_chat_carries_the_chat_sessions_list_as_on_it(chat_app):
    app, stack = chat_app
    stack.involved = {SESSION: [item(2, list="your-move", mover="demo owner"), item(1, held=True, until="2027-01-12")], OTHER: [item(50)]}
    stack.your_move = [{"shown": "demo#2", "subject": "[x] promise 2", "url": "https://tracker.example.test/promises/2"}]
    with client_for(app, stack) as c:
        d = chat(c, until=lambda d: "onIt" in d and d["waiting"])
    assert d["onIt"] == [row(2, mover="demo owner"), row(1, held=True, until="2027-01-12")]
    assert ids(d["waiting"]) == ["demo#2"]                       # an item on the owner's move too is in both: what each read returns
    assert asked(stack) and all(q == {"key": SESSION} for q in asked(stack))


def test_an_empty_answer_is_an_empty_on_it(chat_app):
    app, stack = chat_app
    stack.involved = {}
    with client_for(app, stack) as c:
        assert chat(c, until=lambda d: "onIt" in d)["onIt"] == []


def test_no_request_can_name_the_session_the_read_asks_for(chat_app):
    app, stack = chat_app
    stack.involved = {SESSION: [item(1)], OTHER: [item(50)]}
    with client_for(app, stack) as c:
        for query in (f"?key={OTHER}", f"?session={OTHER}&name={OTHER}", f"?s={OTHER}"):
            app.state.involved._swr.expire()
            d = chat(c, "/api/chat" + query, until=lambda d: "onIt" in d)
            assert d["session"] == SESSION and ids(d["onIt"]) == ["demo#1"], query
        c.get("/api/chat", headers={"X-Sala-Chat-Session": OTHER})
    assert asked(stack) and all(q == {"key": SESSION} for q in asked(stack))


@pytest.mark.parametrize("reply", [None, (404, "no such read"), (500, "boom"), (401, "unauthorized"), (200, "not json"), (200, {"items": "x"})])
def test_while_the_read_is_unavailable_api_chat_has_no_on_it_and_says_nothing(chat_app, reply):
    app, stack = chat_app
    stack.involved_reply = reply                                  # None with `involved` None: a server without the read
    with client_for(app, stack) as c:
        d = chat(c, until=lambda d: asked(stack) and not app.state.involved._swr.running)
    assert "onIt" not in d and asked(stack)
    assert not [k for k in d if re.search("error|involved", k, re.I)], d


def test_with_no_token_there_is_no_read_and_no_on_it(chat_app):
    app, stack = chat_app
    stack.involved = {SESSION: [item(1)]}
    stack.token_file.unlink()
    with client_for(app, stack) as c:
        d = chat(c)
        d = chat(c)
    assert "onIt" not in d and asked(stack) == []


def test_a_failure_after_a_good_read_keeps_the_list_then_it_goes_and_the_rest_of_the_answer_stays(chat_app, monkeypatch):
    app, stack = chat_app
    stack.involved = {SESSION: [item(2), item(1)]}
    with client_for(app, stack) as c:
        good = chat(c, until=lambda d: "onIt" in d)
        stack.involved_reply = (502, "bad gateway")
        app.state.involved._swr.expire()
        assert chat(c)["onIt"] == good["onIt"]
        t0 = time.time()
        monkeypatch.setattr(IV, "time", types.SimpleNamespace(time=lambda: t0 + IV.STALE_MAX + 30))
        app.state.involved._swr.expire()
        d = chat(c, until=lambda d: "onIt" not in d)
    assert set(good) - set(d) == {"onIt"} and d["session"] == SESSION


def test_the_list_changes_nothing_else_in_the_answer_and_nothing_of_another_session(chat_app):
    app, stack = chat_app
    with client_for(app, stack) as c:
        before = chat(c, until=lambda d: asked(stack))
        listed = c.get("/api/sessions").json()
        stack.involved = {SESSION: [item(1)], OTHER: [item(50)]}
        app.state.involved._swr.expire()
        after = chat(c, until=lambda d: "onIt" in d)
        relisted = c.get("/api/sessions").json()
    assert set(after) - set(before) == {"onIt"} and {k: after[k] for k in before} == before
    assert OTHER in json.dumps(listed) and relisted == listed and "onIt" not in json.dumps(relisted)
    assert all(q == {"key": SESSION} for q in asked(stack))              # a second session is never asked about


def test_with_no_chat_session_nothing_is_read(chat_app, monkeypatch):
    app, stack = chat_app
    stack.involved = {SESSION: [item(1)]}
    monkeypatch.delenv("SALA_CHAT_SESSION")
    with client_for(app, stack) as c:
        for _ in range(3):
            assert c.get("/api/chat").json() == {"configured": False}
            time.sleep(0.05)
    assert asked(stack) == []


# ---------- the page's helpers for a row, in node ----------

APP_JS = (STATIC / "app.js").read_text(encoding="utf-8")
SHARED_JS = (STATIC / "shared.js").read_text(encoding="utf-8")

HARNESS = r"""
const zone = { name: %(zone)s, label: "" };
%(zone_format)s
const el = (tag, attrs = {}, ...kids) => {
  const n = { tag, cls: attrs.class || "", text: attrs.text, title: attrs.title, href: attrs.href, kids: kids.filter(Boolean) };
  n.classList = { add: (c) => { n.cls = n.cls ? n.cls + " " + c : c; } };
  n.append = (...k) => n.kids.push(...k);
  return n;
};
const chatView = { data: { session: "chat-test-ada", name: "Ada" }, fresh: new Set(["demo#1"]) };
%(helpers)s
const at = (iso) => Date.parse(iso) / 1000;
"""


def helpers(body: str, lang: str = "en", zone: str = "Asia/Seoul"):
    cut = lambda src, pattern: re.search(pattern, src, re.S | re.M).group(0)
    program = prelude(lang) + HARNESS % {
        "zone": json.dumps(zone),
        "zone_format": cut(SHARED_JS, r"^function zoneFormat\(locale, opts\) \{.*?\n\}\n"),
        "helpers": cut(APP_JS, r"^const CHAT_LATE_DAYS = .*?(?=^function paintChatStrip\(\))"),
    }
    return run_node(program + body)


@needs_node
def test_a_row_is_late_after_two_days_red_after_five_and_never_when_held_or_timeless():
    got = helpers(r"""
const now = Date.parse("2027-01-08T12:00:00+09:00"), s = now / 1000, day = 86400;
const rows = [[0, false], [2 * day, false], [2 * day + 1, false], [5 * day, false], [5 * day + 1, false], [40 * day, false], [40 * day, true]]
  .map(([ago, held]) => ({ since: s - ago, held }));
rows.push({ since: null, held: false });
console.log(JSON.stringify(rows.map((w) => [chatBackTone(w, now), Math.floor(chatBackAge(w, now))])));
""")
    assert got == [["", 0], ["", 2], ["late", 2], ["late", 5], ["red", 5], ["red", 40], ["", 0], ["", 0]]


@needs_node
def test_since_is_a_time_today_a_weekday_and_a_time_within_a_week_and_a_date_before_that():
    got = helpers(r"""
const now = Date.parse("2027-01-08T12:00:00+09:00");
console.log(JSON.stringify(["2027-01-08T00:00:00+09:00", "2027-01-08T09:05:00+09:00", "2027-01-07T23:59:00+09:00", "2027-01-02T08:00:00+09:00",
  "2027-01-01T08:00:00+09:00", "2026-12-22T08:00:00+09:00"].map((t) => chatSinceText(at(t), now))));
""")
    assert got == ["since 00:00", "since 09:05", "since Thu 23:59", "since Sat 08:00", "since Fri Jan 1st", "since Tue Dec 22nd"]


@needs_node
def test_a_date_takes_the_right_ending():
    got = helpers(r"""
console.log(JSON.stringify([1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 31].map((n) => chatDayAsSent("2027-01-" + String(n).padStart(2, "0")).split(" ").pop())));
""")
    assert got == ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "23rd", "31st"]


@needs_node
@pytest.mark.parametrize("zone", ["Pacific/Kiritimati", "Asia/Seoul", "America/Los_Angeles", "Pacific/Pago_Pago"])
def test_the_day_a_held_item_comes_back_is_the_day_as_sent_in_every_zone(zone):
    assert helpers('console.log(JSON.stringify(chatDayAsSent("2027-01-12")));', zone=zone) == "Tue Jan 12th"


@needs_node
def test_a_korean_page_words_the_dates_as_korean_ones_with_no_space_before_the_weekday():
    got = helpers(r"""
const now = Date.parse("2027-01-08T12:00:00+09:00");
console.log(JSON.stringify([chatSinceText(at("2027-01-08T09:05:00+09:00"), now), chatSinceText(at("2027-01-06T18:30:00+09:00"), now),
  chatSinceText(at("2027-01-01T08:00:00+09:00"), now), chatDayAsSent("2027-01-12")]));
""", lang="ko")
    month, day, since = cp(0xC6D4), cp(0xC77C), cp(0xBD80, 0xD130)
    wed, fri, tue = cp(0xC218), cp(0xAE08), cp(0xD654)
    assert got == [f"09:05{since}", f"{wed} 18:30{since}", f"1{month} 1{day}({fri}){since}", f"1{month} 12{day}({tue})"]


@needs_node
def test_who_moves_a_row_reads_as_a_person_would_say_it_and_anything_else_as_sent():
    got = helpers(r"""
console.log(JSON.stringify(["chat-test-ada", "x-demo-engineer", "x-demo-main", "demo-engineer", "x-demo-two-engineer", "swift-demo-name", "Demo Person",
  "Demo-Person-main", "engineer", "main", "x--main", "<b>x</b>-engineer", "constructor", "x-constructor"].map((m) => chatMoverName(m, chatView.data))));
""")
    assert got == ["Ada", "demo builder", "demo main", "demo builder", "demo two builder", "swift-demo-name", "Demo Person",
                   "Demo-Person-main", "engineer", "main", "x--main", "<b>x</b>-engineer", "constructor", "x-constructor"]


@needs_node
def test_a_row_is_drawn_from_its_parts_as_text_and_never_carries_the_new_tag():
    got = helpers(r"""
const now = Date.parse("2027-01-08T12:00:00+09:00");
const rows = [
  { id: "demo#1", subject: "<img src=x onerror=1>", url: "https://tracker.example.test/promises/1", mover: "x-demo-engineer", held: false, until: null, since: at("2027-01-01T08:00:00+09:00") },
  { id: "demo#2", subject: "held", url: "", mover: "", held: true, until: "2027-01-12", since: at("2026-12-01T08:00:00+09:00") },
  { id: "demo#3", subject: "late", url: "", mover: "chat-test-ada", held: false, until: "2027-01-12", since: at("2027-01-05T08:00:00+09:00") },
  { id: "demo#4", subject: "held with no day", url: "", mover: "", held: true, until: null, since: null },
].map((w) => chatBackRow(w, now));
const flat = (n) => ({ cls: n.cls, text: n.text, title: n.title, href: n.href, kids: n.kids.map(flat) });
console.log(JSON.stringify([rows.map(flat), chatWaitRow({ id: "demo#1", subject: "s", url: "" }).kids[0].kids.map((k) => k.cls)]));
""")
    rows, first_list = got
    assert [r["cls"] for r in rows] == ["wait-row back-row red", "wait-row back-row", "wait-row back-row late", "wait-row back-row"]
    subj, meta = rows[0]["kids"]
    assert [(k["cls"], k.get("text")) for k in subj["kids"]] == [("wait-id", "demo#1"), ("wait-link", "<img src=x onerror=1>")]       # no "new" tag here
    assert [(k["cls"], k.get("text")) for k in meta["kids"]] == [("who", "demo builder"), ("red", "since Fri Jan 1st"), ("red age", "7 days")]
    assert meta["kids"][0]["title"] == "x-demo-engineer"
    assert [(k["cls"], k.get("text")) for k in rows[1]["kids"][1]["kids"]] == [("", "since Tue Dec 1st"), ("park", "parked until Tue Jan 12th")]
    assert [(k["cls"], k.get("text")) for k in rows[2]["kids"][1]["kids"]] == [("who", "Ada"), ("late", "since Tue 08:00"), ("late age", "3 days")]
    assert rows[3]["kids"][1]["kids"] == []
    assert first_list == ["wait-id", "wait-title", "new"]                                    # the first list keeps its tag
