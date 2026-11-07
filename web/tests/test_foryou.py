"""stackshot's For you list, server side (foryou.py): GET /api/for-you, POST /api/for-you/seen and
POST /api/items/<key>/watch, all calls to stackshot's client API with this machine's token and the label `sala-web`.

What a wrong answer costs here is a row the owner never sees or one he cannot get rid of, a flag set on the wrong item or on
none, a refusal shown as a success, a trace or the token on the page, a value that reaches stackshot unchecked. Every check
guards one of those. The shapes of the two POSTs are stackshot's (as the coordinator described them; nothing here called the
live stackshot): they live in foryou.py and the fake (fake_stackshot.py), and the tests of the shapes on their own (the first half)
change with them. Nothing reaches the
real stackshot or the network: stackshot is a fake on 127.0.0.1 that the app reaches through two files in a temporary
directory, exactly as it reaches the board. No page shows the list now."""

from __future__ import annotations

import json
import time

import pytest
from starlette.testclient import TestClient

from fake_stackshot import foryou_row
from sala_web import foryou as FY
from sala_web import swr as SWR
from sala_web.app import create_app
from test_new_session import env, sala  # noqa: F401  (fixtures)


# ── the shapes on their own ──────────────────────────────────────────────────
def test_a_row_keeps_the_fields_the_page_uses_and_nothing_else():
    r = FY.clean_row({**foryou_row(7, "decision", "board#35", "Needs you", urgent=True, slacked=True), "secret": "no", "when": "2 min ago"})
    assert r == {"id": 7, "kind": "decision", "item": "board#35", "project": "projects/gamma-sala", "what": "Needs you", "url": "https://board.example.test/items/35",
                 "urgent": True, "ts": 1792800000.0, "when": "2 min ago", "slacked": True}
    # a row with no usable number or nothing to say is no row; a bool is no number; a digit string is one
    assert FY.clean_row({"id": True, "what": "x"}) is None and FY.clean_row({"id": "x", "what": "x"}) is None and FY.clean_row({"id": 1, "what": "  "}) is None
    assert FY.clean_row("text") is None and FY.clean_row({"what": "x"}) is None
    assert FY.clean_row({"id": "12", "what": "x"})["id"] == 12
    # the page links the url: only http(s) goes through; an item that is not board#N is dropped; text is cut and one line
    assert FY.clean_row({"id": 1, "what": "x", "url": "javascript:alert(1)"})["url"] == ""
    assert FY.clean_row({"id": 1, "what": "x", "url": "https://a.example/x"})["url"] == "https://a.example/x"
    assert FY.clean_row({"id": 1, "what": "x", "item": "not an item"})["item"] == "" and FY.clean_row({"id": 1, "what": "x", "item": "s9#1"})["item"] == "s9#1"
    assert FY.clean_row({"id": 1, "what": "a\n  b\tc" + "z" * 400})["what"].startswith("a b cz") and len(FY.clean_row({"id": 1, "what": "z" * 400})["what"]) == FY.WHAT_MAX
    assert FY.clean_row({"id": 1, "what": "x", "urgent": "yes"})["urgent"] is False      # only a real true marks it
    assert FY.clean_row({"id": 1, "what": "x", "ts": "soon"})["ts"] is None


def test_the_list_parse_keeps_the_order_drops_bad_rows_and_cleans_the_flags():
    body = {"generated": "2026-10-24T00:00:00Z", "rows": [foryou_row(3, "closed", "board#9001", "c"), "junk", foryou_row(2, "due", "board#9002", "d"), {"id": 1}],
            "flags": {"board#9001": "mute", "board#9002": "watch", "board#9003": "default", "s9": "mute", "board#9004": 5, 7: "mute"}}
    got = FY.parse_list(body)
    assert [r["id"] for r in got["rows"]] == [3, 2] and got["generated"] == "2026-10-24T00:00:00Z"
    assert got["flags"] == {"board#9001": "mute", "board#9002": "watch"}      # only {board#N: watch | mute}
    assert FY.parse_list({"rows": []}) == {"generated": "", "rows": [], "flags": {}}
    assert len(FY.parse_list({"rows": [foryou_row(i, "closed", "board#9001", "x") for i in range(1, 400)]})["rows"]) == FY.ROWS_MAX
    for bad in ("text", None, [], {"rows": "x"}, {"flags": {}}, {"rows": None}):
        with pytest.raises(RuntimeError, match="not the For you list"):
            FY.parse_list(bad)


def test_the_two_confirmations_are_read_loosely():
    assert FY.parse_seen({"ok": True, "seen": [3, "4", True, "x"], "rows": [foryou_row(2, "due", "board#9002", "d")]}) == {"seen": [3, 4], "rows": FY.clean_rows([foryou_row(2, "due", "board#9002", "d")])}
    assert FY.parse_seen({"ok": True}) == {"seen": [], "rows": None}      # no rows in the answer: the caller drops the seen ids itself
    with pytest.raises(RuntimeError):
        FY.parse_seen("text")
    assert FY.parse_watch({"item": "board#9009", "state": "mute", "flags": {"board#9009": "mute"}}, "board#9001", "watch") == {"item": "board#9009", "state": "mute", "flags": {"board#9009": "mute"}}
    assert FY.parse_watch({"ok": True}, "board#9001", "watch") == {"item": "board#9001", "state": "watch", "flags": None}      # the answer's gaps are what was asked
    assert FY.parse_watch({"item": "x", "state": "loud", "flags": []}, "board#9001", "mute") == {"item": "board#9001", "state": "mute", "flags": None}
    with pytest.raises(RuntimeError):
        FY.parse_watch([], "board#9001", "mute")


def test_what_goes_out_is_checked_first():
    assert FY.validate_seen({"id": 41}) == {"id": 41, "sender": "sala-web"} and FY.validate_seen({"id": "all"}) == {"id": "all", "sender": "sala-web"}
    for bad in ({}, {"id": 0}, {"id": -3}, {"id": True}, {"id": "41"}, {"id": "ALL"}, {"id": 1.5}, {"id": None}, {"id": [1]}, {"id": 1, "sender": "x"}, [], "all", None, {"id": 10**13}):
        assert FY.validate_seen(bad)[0] == 400, bad
    assert FY.item_key("board#25") == "board#25" and FY.item_key(" 25 ") == "board#25" and FY.item_key("025") is None
    for bad in ("board#", "board#09001", "s9", "board#9001;id", "board#9001/watch", "../x", "", None, 25, "board#" + "9" * 10, "Board#9001"):
        assert FY.item_key(bad) is None, bad
    for st in FY.STATES:
        assert FY.validate_watch("25", {"state": st}) == ("board#25", {"state": st, "sender": "sala-web"})
    assert FY.STATES == ("watch", "mute", "default")
    for key, body in (("x", {"state": "mute"}), ("25", {}), ("25", {"state": "loud"}), ("25", {"state": "mute", "sender": "x"}), ("25", {"state": None}), ("25", []), ("25", "mute")):
        assert FY.validate_watch(key, body)[0] == 400, (key, body)
    assert FY.watch_path("board#25") == "items/board%2325/watch" and FY.SENDER == "sala-web"


def test_a_refusal_is_a_plain_sentence_for_every_status():
    R = lambda s, d=None: FY.PP.Reply(s, d)   # noqa: E731
    assert FY.sentence(R(403, {"error": "refused: sender 'x'"}), "mark it seen", "gone") == (403, "stackshot does not let this page mark it seen: it accepts that only from sala on the machine that runs the agents (stackshot says: refused: sender 'x')")
    assert FY.sentence(R(404, {"error": "no item board#9009"}), "x", "stackshot does not know that item.") == (404, "stackshot does not know that item. (stackshot says: no item board#9009)")
    assert FY.sentence(R(404, "plain text"), "x", "Gone.") == (404, "Gone.")
    assert FY.sentence(R(400, {"error": "state = watch | mute | default"}), "change the flag", "g")[0] == 400
    assert FY.sentence(R(401, "unauthorized"), "x", "g") == (502, FY.REFUSED)
    assert FY.sentence(R(0, {"error": "stackshot unreachable (refused)"}), "x", "g") == (502, "stackshot unreachable (refused)")
    assert FY.sentence(R(-1, {"error": "No stackshot token on this machine."}), "x", "g") == (502, "No stackshot token on this machine.")
    assert FY.sentence(R(500, {"error": "boom\nTraceback"}), "x", "g") == (502, "stackshot answered HTTP 500")   # a multi-line message is not passed on
    assert FY.sentence(R(500, {"error": "z" * 300}), "x", "g") == (502, "stackshot answered HTTP 500")


# ── the server ───────────────────────────────────────────────────────────────
def live(env):
    return TestClient(env["client"].app)


def get_list(c) -> dict:
    """The answer once no background read runs."""
    for _ in range(250):
        r = c.get("/api/for-you")
        assert r.status_code == 200 and r.headers["cache-control"] == "no-store"
        got = r.json()
        if not got.get("refreshing"):
            return got
        time.sleep(0.02)
    raise AssertionError("the read never landed")


def due(env):
    env["client"].app.state.foryou._swr._next = 0.0


def test_the_list_is_answered_at_once_then_filled_from_stackshot(env):
    ss = env["ss"]
    with live(env) as c:
        first = c.get("/api/for-you").json()
        assert first["pending"] is True and first["refreshing"] is True and first["rows"] == [] and first["flags"] == {} and first["fetchedAt"] is None
        got = get_list(c)
    assert [r["id"] for r in got["rows"]] == [41, 40, 39, 38]      # newest first, as sent
    assert got["rows"][0] == {"id": 41, "kind": "decision", "item": "board#35", "project": "projects/gamma-sala", "what": "Needs your decision: show For you in the items sheet",
                              "url": "https://board.example.test/items/35", "urgent": True, "ts": 1792800000.0, "when": "2 min ago", "slacked": False}
    assert got["flags"] == {} and got["generated"] == "2026-10-24T00:00:00Z" and isinstance(got["fetchedAt"], int) and "pending" not in got and "error" not in got
    calls = ss.calls("/client/for-you")
    assert len(calls) == 1 and calls[0]["method"] == "GET"
    assert ss.token not in json.dumps(got) and ss.url not in json.dumps(got)


def test_one_read_a_minute_however_many_pages_ask(env, monkeypatch):
    ss = env["ss"]
    with live(env) as c:
        get_list(c)
        now = time.monotonic()
        for sec in range(0, 60, 5):
            monkeypatch.setattr(SWR.time, "monotonic", lambda s=sec: now + s)
            for _ in range(3):
                get_list(c)
        assert len(ss.calls("/client/for-you")) == 1
        monkeypatch.setattr(SWR.time, "monotonic", lambda: now + FY.TTL + 1)
        ss.foryou = ss.foryou[:1]
        for _ in range(3):
            got = get_list(c)
    assert len(ss.calls("/client/for-you")) == 2 and [r["id"] for r in got["rows"]] == [41]
    assert FY.TTL == 60.0 and FY.ERROR_RETRY < FY.TTL


def test_a_failed_read_keeps_the_last_list_and_says_why_in_plain_words(env):
    ss = env["ss"]
    with live(env) as c:
        get_list(c)
        for reply, words in (((500, {"error": "boom"}), "stackshot answered HTTP 500 (stackshot says: boom)"), ((401, "unauthorized"), FY.REFUSED),
                             ((200, {"rows": "x"}), "stackshot sent an answer that is not the For you list"), ((404, "no route"), "stackshot has no For you list")):
            ss.foryou_reply = reply
            due(env)
            c.get("/api/for-you")
            got = get_list(c)
            assert got["error"] == words and [r["id"] for r in got["rows"]] == [41, 40, 39, 38] and isinstance(got["fetchedAt"], int), (reply, got)
            assert "Traceback" not in json.dumps(got) and ss.token not in json.dumps(got)
        ss.foryou_reply = None
        due(env)
        c.get("/api/for-you")
        assert "error" not in get_list(c)      # the next good read clears it


def test_without_a_token_or_a_server_the_answer_says_so_and_nothing_is_dialled(env, tmp_path):
    ss = env["ss"]
    ss.token_file.unlink()
    with live(env) as c:
        got = get_list(c)
        assert got["error"] == "No stackshot token on this machine." and got["rows"] == [] and got["fetchedAt"] is None
    assert ss.requests == []
    ss.token_file.write_text(ss.token + "\n")
    ss.url_file.write_text("http://127.0.0.1:1\n")      # nothing listens there
    due(env)
    with live(env) as c:
        got = get_list(c)
    assert got["error"].startswith("stackshot unreachable") and ss.token not in json.dumps(got) and "127.0.0.1:1" not in json.dumps(got)


def test_seen_marks_one_entry_and_the_list_changes_at_once(env):
    c, ss = env["client"], env["ss"]
    with live(env) as c:
        get_list(c)
        r = c.post("/api/for-you/seen", json={"id": 40})
        assert r.status_code == 200 and r.headers["cache-control"] == "no-store", r.text
        d = r.json()
        assert d["ok"] and d["seen"] == [40] and [x["id"] for x in d["rows"]] == [41, 39, 38] and d["flags"] == {} and isinstance(d["fetchedAt"], int)
        assert ss.calls("/client/for-you/seen")[-1]["body"] == {"id": 40, "sender": "sala-web"}
        # the next ask has it gone without another read of stackshot
        n = len(ss.calls("/client/for-you"))
        assert [x["id"] for x in get_list(c)["rows"]] == [41, 39, 38] and len(ss.calls("/client/for-you")) == n
        # all
        d = c.post("/api/for-you/seen", json={"id": "all"}).json()
        assert d["ok"] and d["seen"] == [38, 39, 41] and d["rows"] == []
        assert ss.calls("/client/for-you/seen")[-1]["body"] == {"id": "all", "sender": "sala-web"}
        assert get_list(c)["rows"] == []


def test_a_seen_answer_without_rows_leaves_the_list_without_the_seen_ids(env):
    ss = env["ss"]
    ss.seen_without_rows = True
    with live(env) as c:
        get_list(c)
        d = c.post("/api/for-you/seen", json={"id": 41}).json()
        assert d["ok"] and [x["id"] for x in d["rows"]] == [40, 39, 38]
        d = c.post("/api/for-you/seen", json={"id": "all"}).json()
        assert d["ok"] and d["rows"] == []


def test_seen_twice_or_of_an_entry_already_gone_is_not_an_error(env):
    """stackshot answers 404 for an id that is not on its list, one already marked seen included: a second tap, or the
    entry seen on another page, is "already gone": the row leaves the list here, no error, nothing else changes."""
    ss = env["ss"]
    with live(env) as c:
        get_list(c)
        assert c.post("/api/for-you/seen", json={"id": 40}).json()["seen"] == [40]
        r = c.post("/api/for-you/seen", json={"id": 40})                    # the double click
        assert ss.calls("/client/for-you/seen")[-1]["body"] == {"id": 40, "sender": "sala-web"} and len(ss.calls("/client/for-you/seen")) == 2
        assert r.status_code == 200 and r.json()["ok"] is True and r.json()["seen"] == [] and [x["id"] for x in r.json()["rows"]] == [41, 39, 38], r.text
        # an entry seen elsewhere while our list still has it: stackshot says 404, the row goes from ours
        ss.foryou = [x for x in ss.foryou if x["id"] != 39]
        r = c.post("/api/for-you/seen", json={"id": 39})
        assert r.status_code == 200 and r.json()["ok"] is True and [x["id"] for x in r.json()["rows"]] == [41, 38], r.text
        assert [x["id"] for x in get_list(c)["rows"]] == [41, 38]
        # an id that never existed is the same to stackshot, so the same here; "all" on an empty list is a plain 200
        assert c.post("/api/for-you/seen", json={"id": 999}).json()["ok"] is True
        assert c.post("/api/for-you/seen", json={"id": "all"}).json()["seen"] == [38, 41]
        assert c.post("/api/for-you/seen", json={"id": "all"}).json() == {**c.post("/api/for-you/seen", json={"id": "all"}).json(), "ok": True, "seen": [], "rows": []}


def test_seen_before_the_first_read_still_answers_with_the_list(env):
    with live(env) as c:     # nothing has read the list yet: the page asked for Seen first (a restart in between)
        d = c.post("/api/for-you/seen", json={"id": 41}).json()
        assert d["ok"] and [x["id"] for x in d["rows"]] == [40, 39, 38] and isinstance(d["fetchedAt"], int)


@pytest.mark.parametrize("body", [{}, {"id": 0}, {"id": -1}, {"id": True}, {"id": "41"}, {"id": "ALL"}, {"id": 1.5}, {"id": None}, {"id": 1, "x": 2}, [], "all"])
def test_a_bad_seen_is_refused_here_and_never_reaches_stackshot(env, body):
    with live(env) as c:
        r = c.post("/api/for-you/seen", json=body)
        assert r.status_code == 400 and r.json()["ok"] is False and r.json()["error"], r.text
    assert env["ss"].calls("/client/for-you/seen") == []


def test_stackshots_refusals_of_seen_are_plain_sentences(env):
    ss = env["ss"]
    with live(env) as c:
        get_list(c)
        for status, body, words in ((403, {"error": "refused: sender 'sala-web' is not on box-a"}, "stackshot does not let this page mark it seen"),
                                    (400, {"error": "bad body"}, "stackshot did not accept that request to mark it seen"),
                                    (500, "boom", "stackshot answered HTTP 500"), (200, "text", "stackshot sent an answer that is not a confirmation"), (401, "no", FY.REFUSED)):
            ss.seen_reply = (status, body)
            r = c.post("/api/for-you/seen", json={"id": 41})
            assert r.json()["ok"] is False and r.json()["error"].startswith(words), (status, r.text)
            assert r.status_code == (502 if status in (500, 200, 401) else status), (status, r.status_code)
            assert "Traceback" not in r.text and ss.token not in r.text
        assert [x["id"] for x in get_list(c)["rows"]] == [41, 40, 39, 38]      # a refusal changed nothing here
    ss.token_file.unlink()
    with live(env) as c:
        r = c.post("/api/for-you/seen", json={"id": 41})
        assert r.status_code == 502 and r.json()["error"] == "No stackshot token on this machine."


@pytest.mark.parametrize("path", ["/api/items/board%2335/watch", "/api/items/35/watch"])
def test_watch_and_mute_set_the_flag_for_the_item(env, path):
    ss = env["ss"]
    with live(env) as c:
        get_list(c)
        r = c.post(path, json={"state": "mute"})
        assert r.status_code == 200 and r.headers["cache-control"] == "no-store", r.text
        d = r.json()
        assert d["ok"] and d["item"] == "board#35" and d["state"] == "mute" and d["flags"] == {"board#35": "mute"}
        call = ss.calls("/client/items/board%2335/watch")[-1]
        assert call["body"] == {"state": "mute", "sender": "sala-web"}, ss.requests[-1]
        assert get_list(c)["flags"] == {"board#35": "mute"}                    # the cached list carries it
        d = c.post(path, json={"state": "watch"}).json()
        assert d["flags"] == {"board#35": "watch"} and d["state"] == "watch"
        d = c.post(path, json={"state": "default"}).json()
        assert d["flags"] == {} and d["state"] == "default" and get_list(c)["flags"] == {}


def test_a_watch_answer_without_flags_is_put_into_the_flags_we_had(env):
    ss = env["ss"]
    ss.flags = {"board#37": "mute"}
    ss.watch_without_flags = True
    with live(env) as c:
        assert get_list(c)["flags"] == {"board#37": "mute"}
        d = c.post("/api/items/35/watch", json={"state": "mute"}).json()
        assert d["ok"] and d["flags"] == {"board#37": "mute", "board#35": "mute"}
        d = c.post("/api/items/37/watch", json={"state": "default"}).json()
        assert d["flags"] == {"board#35": "mute"}


@pytest.mark.parametrize("key,body", [("x", {"state": "mute"}), ("0", {"state": "mute"}), ("s9", {"state": "mute"}), ("255", {}), ("255", {"state": "loud"}),
                                      ("255", {"state": "mute", "sender": "x"}), ("255", []), ("board%23", {"state": "mute"}), ("255;id", {"state": "mute"})])
def test_a_bad_watch_is_refused_here_and_never_reaches_stackshot(env, key, body):
    with live(env) as c:
        r = c.post(f"/api/items/{key}/watch", json=body)
        assert r.status_code == 400 and r.json()["ok"] is False and r.json()["error"], r.text
    assert [q for q in env["ss"].requests if q["method"] == "POST"] == []


def test_stackshots_refusals_of_watch_are_plain_sentences(env):
    ss = env["ss"]
    with live(env) as c:
        r = c.post("/api/items/83/watch", json={"state": "mute"})      # an item stackshot does not know
        assert r.status_code == 404 and r.json() == {"ok": False, "error": "stackshot does not know that item. (stackshot says: no item board#83)"}
        for status, body, words in ((403, {"error": "refused"}, "stackshot does not let this page change the flag"), (400, {"error": "bad state"}, "stackshot did not accept that request to change the flag"),
                                    (503, "later", "stackshot answered HTTP 503"), (200, [], "stackshot sent an answer that is not a confirmation")):
            ss.watch_reply = (status, body)
            r = c.post("/api/items/35/watch", json={"state": "mute"})
            assert r.json()["ok"] is False and r.json()["error"].startswith(words), (status, r.text)
        ss.watch_reply = None
        assert ss.flags == {} and get_list(c)["flags"] == {}


def test_every_post_has_the_origin_content_type_and_size_guards(env):
    ss = env["ss"]
    with live(env) as c:
        for path, body in (("/api/for-you/seen", {"id": 41}), ("/api/items/35/watch", {"state": "mute"})):
            assert c.post(path, json=body, headers={"Origin": "https://evil.example"}).status_code == 403, path
            assert c.post(path, json=body, headers={"Origin": "null"}).status_code == 403, path
            assert c.post(path, content=json.dumps(body).encode(), headers={"Content-Type": "text/plain"}).status_code == 415, path
            assert c.post(path, content=b"{not json", headers={"Content-Type": "application/json"}).status_code == 400, path
            assert c.post(path, content=b"{" + b" " * (16 * 1024) + b"}", headers={"Content-Type": "application/json"}).status_code == 413, path
            assert c.get(path).status_code == 405, path
        assert c.post("/api/for-you", json={}).status_code == 405
    assert [r for r in ss.requests if r["method"] == "POST"] == []


def test_the_token_never_reaches_a_page_a_log_or_a_file(env, tmp_path):
    ss = env["ss"]
    with live(env) as c:
        seen = [get_list(c), c.post("/api/for-you/seen", json={"id": 41}).json(), c.post("/api/items/35/watch", json={"state": "mute"}).json()]
        ss.watch_reply = (500, {"error": "boom"})
        seen.append(c.post("/api/items/35/watch", json={"state": "mute"}).json())
    blob = json.dumps(seen)
    assert ss.token not in blob and ss.url not in blob and "Bearer" not in blob
    # nothing of it is kept under the state dir (the list is held in memory only)
    state = env["settings"].state_dir
    assert not state.exists() or not any(ss.token in p.read_text(errors="ignore") for p in state.rglob("*") if p.is_file())
