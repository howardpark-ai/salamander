"""The chat session's server side: GET /chat (an address that leads into sala's own view), GET /api/chat (the data of the entry and the strip), the settings that
name the session, the link cards, the board lines, the motion lines.

What is held:
  - nothing configured (the default): /api/chat says so and /chat leads to the sessions' own page; the session name is never in the code, only in SALA_CHAT_SESSION;
  - /chat is a redirect, relative to wherever the app is mounted, to #s=<the session> (or to the app's own page with none set), and serves no page of its own;
  - the display name defaults to the part of the session name after its last hyphen, capitalized, and SALA_CHAT_NAME replaces it;
  - cards: a /mockup/<n> link and a claude.ai artifact link become cards, any other link none, nothing is fetched (the mockup's title is read from
    the local store);
  - waiting: stackshot's whole Your move list when there is one (every item, none dropped or re-sorted, no cap, an empty list an empty strip), else the
    board's rows with a move for the owner, each item once over every session, the board's words passed through;
  - motion: the session's own lines, at most 8, each at most 120 characters, an old one gone, a hand-made file that is not the format harmless;
  - /api/chat for a live session carries what the entry and the strip draw (name, live or not, working, the count of kept-back lines, the board lines, the
    motion lines) in one answer, and nothing the session's own view draws itself (no thread, no pid).
All names are invented."""

from __future__ import annotations

import json
import re
import time
import urllib.error
import urllib.request
from pathlib import Path

import pytest

from conftest import NAME, transcript_file
from sala_web import chatpage as CP
from sala_web import motion as MO
from sala_web.config import chat_name, chat_session

HOST = "sala.example.test"


# ---------- the settings ----------

def test_nothing_is_configured_by_default(monkeypatch):
    monkeypatch.delenv("SALA_CHAT_SESSION", raising=False)
    monkeypatch.delenv("SALA_CHAT_NAME", raising=False)
    assert chat_session() == "" and chat_name() == ""


def test_the_display_name_is_the_part_after_the_last_hyphen_unless_a_setting_says_otherwise(monkeypatch):
    monkeypatch.setenv("SALA_CHAT_SESSION", "chat-test-ada")
    monkeypatch.delenv("SALA_CHAT_NAME", raising=False)
    assert chat_session() == "chat-test-ada" and chat_name() == "Ada"
    monkeypatch.setenv("SALA_CHAT_NAME", "  Ada   Lovelace  ")
    assert chat_name() == "Ada Lovelace"


@pytest.mark.parametrize("bad", ["has space", "../x", "-lead", "a" * 65, "semi;colon"])
def test_a_session_name_that_is_not_one_means_nothing_is_configured(monkeypatch, bad):
    monkeypatch.setenv("SALA_CHAT_SESSION", bad)
    assert chat_session() == ""


# ---------- cards ----------

def store(tmp_path: Path, n: int, title: str | None) -> Path:
    root = tmp_path / "mockups"
    root.mkdir(exist_ok=True)
    (root / f"{n}.html").write_text(f"<!doctype html><title>{title}</title><p>x</p>" if title is not None else "<p>no title</p>")
    return root


def test_a_mockup_link_becomes_a_card_titled_from_the_local_store(tmp_path):
    root = store(tmp_path, 7, "Pricing page &amp; plans")
    got = CP.cards("see [the mockup](/mockup/7) now", HOST, root)
    assert got == [{"kind": "mockup", "url": "/mockup/7", "n": 7, "title": "Pricing page & plans"}]


def test_a_mockup_link_on_this_site_by_full_address_and_a_bare_path_are_the_same_card_once(tmp_path):
    root = store(tmp_path, 3, "Three")
    got = CP.cards(f"https://{HOST}/mockup/3 and /mockup/3 and [again](https://{HOST}/mockup/3?x=1)", HOST, root)
    assert [c["n"] for c in got] == [3]


def test_a_mockup_link_on_another_site_is_no_card_and_a_missing_title_falls_back_to_the_link_text(tmp_path):
    root = tmp_path / "none"
    assert CP.cards("https://other.example.test/mockup/3", HOST, root) == []
    assert CP.cards("[Page two](/mockup/2)", HOST, root)[0]["title"] == "Page two"
    assert CP.cards("/mockup/2", HOST, root)[0]["title"] == ""


def test_an_artifact_link_becomes_a_card_with_the_link_text_and_no_other_link_does(tmp_path):
    text = ("[Plan](https://claude.ai/artifact/AbC123_x-9) and https://claude.ai/code/artifact/0a1b2c3d, "
            "also https://example.com/page and [site](https://claude.ai/chat/abc) and https://claude.ai/artifact/")
    got = CP.cards(text, HOST, tmp_path)
    assert got == [{"kind": "artifact", "url": "https://claude.ai/artifact/AbC123_x-9", "title": "Plan"},
                   {"kind": "artifact", "url": "https://claude.ai/code/artifact/0a1b2c3d", "title": ""}]


def test_no_more_than_six_cards_and_no_network_is_touched(tmp_path, monkeypatch):
    def boom(*a, **k):
        raise AssertionError("a card must never fetch anything")
    monkeypatch.setattr(urllib.request, "urlopen", boom)
    text = " ".join(f"https://claude.ai/artifact/id{i}" for i in range(12))
    assert len(CP.cards(text, HOST, tmp_path)) == CP.CARDS_MAX


def test_a_mockup_that_is_a_link_to_elsewhere_is_never_read(tmp_path):
    root = tmp_path / "mockups"
    root.mkdir()
    (tmp_path / "secret.html").write_text("<title>secret</title>")
    (root / "5.html").symlink_to(tmp_path / "secret.html")
    assert CP.cards("/mockup/5", HOST, root)[0]["title"] == ""   # a symlink is not followed


# ---------- waiting ----------

def row(i, subject, waiting=True, held=False):
    return {"id": f"item#{i}", "subject": subject, "needs": ["decision"], "waiting": waiting, "held": held, "url": f"https://tracker.example.test/t/{i}"}


def test_waiting_is_the_boards_own_rows_once_each_over_every_session():
    doc = {"sessions": {
        "chat-a": {"items": [row(1, "[x] decide A"), row(2, "[x] not mine", waiting=False), row(3, "[x] parked", held=True)], "waiting": 1},
        "chat-b": {"items": [row(1, "[x] decide A"), row(4, "[x] decide B " + "very long " * 30)], "waiting": 2},
    }}
    got = CP.waiting(doc)
    assert [w["id"] for w in got] == ["item#1", "item#4"]
    assert got[0] == {"id": "item#1", "subject": "[x] decide A", "url": "https://tracker.example.test/t/1"}
    assert got[1]["subject"].startswith("[x] decide B")   # passed through, not cut or rewritten


def test_waiting_is_empty_for_no_board_or_a_board_that_failed():
    assert CP.waiting({}) == [] and CP.waiting({"error": "no token"}) == [] and CP.waiting(None) == []


def entry(i):
    return {"id": f"item#{i}", "subject": f"[x] move {i}", "url": f"https://tracker.example.test/t/{i}"}


def test_waiting_is_the_your_move_list_whole_and_in_its_order_when_there_is_one():
    feed = {"sessions": {"chat-a": {"items": [row(9, "[x] only this one")], "waiting": 1}}}
    mine = [entry(i) for i in (7, 3, 5, 1, 6, 2, 4)]          # not sorted: the strip keeps the page's own order
    got = CP.waiting(feed, mine)
    assert got == mine and len(got) == 7                      # seven moves, where the feed has one; none dropped, none re-sorted
    assert [w["id"] for w in got] == ["item#7", "item#3", "item#5", "item#1", "item#6", "item#2", "item#4"]
    assert set(got[0]) == {"id", "subject", "url"}            # the entry the page's script reads


def test_waiting_has_no_cap_over_twenty_moves():
    mine = [entry(i) for i in range(1, 61)]
    assert [w["id"] for w in CP.waiting({}, mine)] == [f"item#{i}" for i in range(1, 61)]


def test_waiting_with_an_empty_your_move_list_is_an_empty_strip_not_the_feed():
    feed = {"sessions": {"chat-a": {"items": [row(1, "[x] a stale row")], "waiting": 1}}}
    assert CP.waiting(feed, []) == []


def test_waiting_falls_back_to_the_feed_when_there_is_no_your_move_list():
    feed = {"sessions": {"chat-a": {"items": [row(1, "[x] decide A")], "waiting": 1}}}
    assert [w["id"] for w in CP.waiting(feed, None)] == ["item#1"] and CP.waiting(feed) == CP.waiting(feed, None)


def test_assemble_carries_the_your_move_list_as_the_strip(tmp_path):
    mine = [entry(i) for i in range(1, 8)]
    doc = CP.assemble(name="chat-test-ada", display="Ada", owner="Rowan", sess=None, projects_dir=tmp_path, zone=None, now_ms=1_800_000_000_000,
                      motion_dir=tmp_path, board_doc={"sessions": {}}, cache={}, your_move=mine)
    assert doc["waiting"] == mine


# ---------- motion ----------

def write_motion(root: Path, session: str, rows) -> None:
    root.mkdir(parents=True, exist_ok=True)
    (root / f"{session}.json").write_text(json.dumps({"v": 1, "lines": rows}))


def test_motion_lines_in_force_oldest_first_at_most_eight_and_cut_at_120(tmp_path):
    now = 1_800_000_000
    rows = [{"text": f"line {i}", "at": now - 100 + i} for i in range(10)]
    rows.insert(0, {"text": "too old", "at": now - 90_000})
    rows.append({"text": "x" * 300, "at": now})
    write_motion(tmp_path, "chat-a", rows)
    got = MO.read_lines(tmp_path, "chat-a", now)
    assert len(got) == MO.MAX_LINES and got[0]["text"] == "line 0"
    assert all(len(g["text"]) <= MO.MAX_CHARS for g in MO.read_lines(tmp_path, "chat-a", now))
    assert "too old" not in [g["text"] for g in got]


def test_a_motion_file_that_is_not_the_format_is_harmless(tmp_path):
    for body in ("not json", "[]", '{"lines": "x"}', '{"lines": [1, {"text": 3, "at": 1}, {"text": "a", "at": "now"}, {"text": "ok", "at": true}]}'):
        (tmp_path / "chat-a.json").write_text(body)
        assert MO.read_lines(tmp_path, "chat-a", 10**10) == []
    assert MO.read_lines(tmp_path, "../chat-a", 1) == [] and MO.read_lines(tmp_path, "missing", 1) == []


def test_a_motion_file_that_is_a_link_is_not_followed(tmp_path):
    real = tmp_path / "real.json"
    real.write_text(json.dumps({"v": 1, "lines": [{"text": "x", "at": 1}]}))
    (tmp_path / "chat-a.json").symlink_to(real)
    assert MO.read_lines(tmp_path, "chat-a", 2) == []


# ---------- the page and its data, served ----------

def get(url: str):
    with urllib.request.urlopen(url, timeout=20) as r:
        return r.status, r.headers, r.read()


class _NoFollow(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def get_raw(url: str):
    """(status, Location, body) of one request, a redirect not followed."""
    try:
        with urllib.request.build_opener(_NoFollow).open(url, timeout=20) as r:
            return r.status, r.headers.get("Location"), r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("Location"), e.read()


def test_the_chat_address_redirects_into_the_session_s_own_view_relative_to_the_app(served, monkeypatch):
    monkeypatch.setenv("SALA_CHAT_SESSION", NAME)
    status, location, body = get_raw(served["url"] + "/chat")
    assert status in (302, 307) and location == "./#s=" + NAME and body == b""
    assert not location.startswith("/"), "relative to the app's own prefix, never the host's root"


def test_the_chat_address_with_no_session_set_leads_to_the_app_s_own_page(served, monkeypatch):
    monkeypatch.delenv("SALA_CHAT_SESSION", raising=False)
    status, location, _ = get_raw(served["url"] + "/chat")
    assert status in (302, 307) and location == "./"


def test_the_redirect_lands_on_sala_s_page_and_no_page_of_its_own_is_served(served, monkeypatch):
    monkeypatch.setenv("SALA_CHAT_SESSION", NAME)
    with urllib.request.urlopen(served["url"] + "/chat", timeout=20) as r:      # followed: the app's own page
        page = r.read().decode()
        assert r.status == 200 and r.geturl() == served["url"] + "/#s=" + NAME
    assert 'id="chat-strip"' in page and "static/chat.js" not in page and "static/chat.css" not in page
    for gone in ("chat.html", "chat.js", "chat.css"):
        assert get_raw(served["url"] + "/static/" + gone)[0] == 404, gone


def test_api_chat_without_a_configured_session_says_so(served, monkeypatch):
    monkeypatch.delenv("SALA_CHAT_SESSION", raising=False)
    status, headers, body = get(served["url"] + "/api/chat")
    d = json.loads(body)
    assert status == 200 and d == {"configured": False}
    assert headers["Cache-Control"] == "no-store"


def test_api_chat_for_a_live_session_has_what_the_entry_and_the_strip_draw_and_nothing_else(served, monkeypatch):
    monkeypatch.setenv("SALA_CHAT_SESSION", NAME)
    monkeypatch.setenv("SALA_OWNER_NAME", "Rowan")
    write_motion(served["settings"].motion_dir, NAME, [{"text": "drawing slide 4", "at": int(time.time())}])
    now = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())

    def line(d):
        d.setdefault("timestamp", now)
        return json.dumps(d) + "\n"
    transcript_file(served).write_text(
        line({"type": "user", "uuid": "u1", "origin": {"kind": "human"}, "promptSource": "typed",
              "message": {"role": "user", "content": "show me /mockup/4"}})
        + line({"type": "assistant", "uuid": "a1", "message": {"role": "assistant", "stop_reason": "tool_use",
                                                                 "content": [{"type": "text", "text": "Looking."}, {"type": "tool_use", "id": "t", "name": "Bash", "input": {}}]}})
        + line({"type": "assistant", "uuid": "a2", "message": {"role": "assistant", "stop_reason": "end_turn",
                                                                 "content": [{"type": "text", "text": "Here: [page](/mockup/4)"}]}})
        + line({"type": "user", "uuid": "u2", "isMeta": True, "origin": {"kind": "peer"},
                "message": {"role": "user", "content": [{"type": "text", "text": "Another Claude session sent a message:\nfrom: chat-other\n\nFYI the build is green."}]}})
        + line({"type": "assistant", "uuid": "a3", "message": {"role": "assistant", "stop_reason": "end_turn", "content": [{"type": "text", "text": "Noted."}]}}))
    status, headers, body = get(served["url"] + "/api/chat")
    d = json.loads(body)
    assert status == 200 and d["configured"] is True and d["present"] == "live" and d["session"] == NAME and d["name"] == "Fake"
    assert set(d) == {"configured", "session", "name", "present", "busy", "keptToday", "keptTodayFloor", "keptLines", "waiting", "group", "motion"}, sorted(d)
    assert d["group"] is None                      # no stackshot read answered here: the page's own words
    assert d["keptToday"] == 1 and d["keptTodayFloor"] is False and d["keptLines"] == 1
    assert [m["text"] for m in d["motion"]] == ["drawing slide 4"]
    assert d["waiting"] == [] and d["busy"] is False


def test_api_chat_for_a_session_sala_does_not_have_says_absent(served, monkeypatch):
    monkeypatch.setenv("SALA_CHAT_SESSION", "chat-test-nobody")
    d = json.loads(get(served["url"] + "/api/chat")[2])
    assert d["configured"] is True and d["present"] == "absent" and d["busy"] is False and d["name"] == "Nobody"


