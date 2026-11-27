"""The second tab of the chat strip ("On it") lists what the chat session has promised to report back: its own `sala motion` lines.

What is held: GET /api/chat carries the configured chat session's lines as `motion`, oldest first, each with the time it was first added, however old, until the
session takes it off; never another session's, and no request names a session; nothing with no chat session; and, in node, the page's own helpers for a row: late
after two days and red after five, never for a line with no time, since when, and a row drawn from the topic alone, as text, with no id, no link, no name and no
"new" tag. The reader of the file is test_chatpage.py, the CLI that writes it tests/motion.sh, the page in a browser test_chat_onit_ui.py. All names are invented;
Korean is built from code points."""

import json
import os
import re
import time

import pytest
from starlette.testclient import TestClient

from i18n_node import STATIC, prelude
from sala_web import sessions as S
from sala_web.app import create_app
from sala_web.config import Settings
from test_i18n import needs_node, run_node

SESSION = "chat-test-ada"
OTHER = "demo-other-session"
DAY = 86400


def cp(*codes):
    return "".join(chr(c) for c in codes)


# ---------- GET /api/chat end to end ----------

def write_motion(settings, session, rows):
    settings.motion_dir.mkdir(parents=True, exist_ok=True)
    (settings.motion_dir / f"{session}.json").write_text(json.dumps({"v": 1, "lines": rows}))


@pytest.fixture
def chat_app(tmp_path, monkeypatch):
    monkeypatch.setenv("SALA_CHAT_SESSION", SESSION)
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    for name, sid, pid in ((SESSION, "bbbbbbbb-0000-4000-8000-000000000002", os.getpid()), (OTHER, "cccccccc-0000-4000-8000-000000000003", os.getppid())):
        (claude / "sessions" / f"{pid}.json").write_text(json.dumps(
            {"pid": pid, "sessionId": sid, "name": name, "cwd": "/x", "status": "idle", "tmux": "x:@0.%0", "procStart": S.proc_start(pid)}))
    monkeypatch.setattr(S, "live_tmux_names", lambda: {})
    settings = Settings(claude_dir=claude, state_dir=tmp_path / "state", admin_key=tmp_path / "none-key", roles_cmd=["false"], sala_models=tmp_path / "none.tsv")
    assert settings.motion_dir.is_relative_to(tmp_path)          # never this machine's own state
    return create_app(settings), settings


def test_api_chat_carries_the_chat_sessions_lines_oldest_first_with_their_first_time_however_old(chat_app):
    app, settings = chat_app
    now = int(time.time())
    lines = [{"text": "a promise from last month", "at": now - 30 * DAY}, {"text": "research on X", "at": now - 60}]
    write_motion(settings, SESSION, lines)
    write_motion(settings, OTHER, [{"text": "another session's promise", "at": now}])
    with TestClient(app) as c:
        r = c.get("/api/chat")
    assert r.status_code == 200 and r.json()["session"] == SESSION and r.json()["motion"] == lines
    assert "onIt" not in r.json() and "another session's promise" not in r.text


def test_a_line_taken_off_is_gone_at_the_next_read_and_with_no_line_the_list_is_empty(chat_app):
    app, settings = chat_app
    now = int(time.time())
    one, two = {"text": "one", "at": now - 5}, {"text": "two", "at": now - 4}
    with TestClient(app) as c:
        assert c.get("/api/chat").json()["motion"] == []
        write_motion(settings, SESSION, [one, two])
        assert c.get("/api/chat").json()["motion"] == [one, two]
        write_motion(settings, SESSION, [two])
        assert c.get("/api/chat").json()["motion"] == [two]
        write_motion(settings, SESSION, [])
        assert c.get("/api/chat").json()["motion"] == []


def test_no_request_can_name_the_session_whose_lines_are_read(chat_app):
    app, settings = chat_app
    now = int(time.time())
    write_motion(settings, SESSION, [{"text": "mine", "at": now}])
    write_motion(settings, OTHER, [{"text": "theirs", "at": now}])
    with TestClient(app) as c:
        for query in (f"?key={OTHER}", f"?session={OTHER}&name={OTHER}", f"?s={OTHER}"):
            d = c.get("/api/chat" + query).json()
            assert d["session"] == SESSION and [m["text"] for m in d["motion"]] == ["mine"], query
        assert [m["text"] for m in c.get("/api/chat", headers={"X-Sala-Chat-Session": OTHER}).json()["motion"]] == ["mine"]


def test_with_no_chat_session_no_line_is_served(chat_app, monkeypatch):
    app, settings = chat_app
    write_motion(settings, SESSION, [{"text": "mine", "at": int(time.time())}])
    monkeypatch.delenv("SALA_CHAT_SESSION")
    with TestClient(app) as c:
        assert c.get("/api/chat").json() == {"configured": False}


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
const chatView = { data: { session: "chat-test-ada", name: "Ada" }, fresh: new Set(["demo#1", undefined]) };
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
def test_a_row_is_late_after_two_days_red_after_five_and_never_when_it_has_no_time():
    got = helpers(r"""
const now = Date.parse("2027-01-08T12:00:00+09:00"), s = now / 1000, day = 86400;
const rows = [0, 2 * day, 2 * day + 1, 5 * day, 5 * day + 1, 40 * day].map((ago) => ({ at: s - ago }));
rows.push({});
console.log(JSON.stringify(rows.map((m) => [chatBackTone(m, now), Math.floor(chatBackAge(m, now))])));
""")
    assert got == [["", 0], ["", 2], ["late", 2], ["late", 5], ["red", 5], ["red", 40], ["", 0]]


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
const now = Date.parse("2027-03-01T12:00:00+09:00");
console.log(JSON.stringify([1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 31].map((n) => chatSinceText(at("2027-01-" + String(n).padStart(2, "0") + "T08:00:00+09:00"), now).split(" ").pop())));
""")
    assert got == ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "23rd", "31st"]


@needs_node
def test_a_korean_page_words_the_dates_as_korean_ones_with_no_space_before_the_weekday():
    got = helpers(r"""
const now = Date.parse("2027-01-08T12:00:00+09:00");
console.log(JSON.stringify([chatSinceText(at("2027-01-08T09:05:00+09:00"), now), chatSinceText(at("2027-01-06T18:30:00+09:00"), now),
  chatSinceText(at("2027-01-01T08:00:00+09:00"), now)]));
""", lang="ko")
    month, day, since = cp(0xC6D4), cp(0xC77C), cp(0xBD80, 0xD130)
    wed, fri = cp(0xC218), cp(0xAE08)
    assert got == [f"09:05{since}", f"{wed} 18:30{since}", f"1{month} 1{day}({fri}){since}"]


@needs_node
def test_a_row_is_the_topic_as_text_and_since_when_with_no_id_no_link_no_name_and_no_new_tag():
    got = helpers(r"""
const now = Date.parse("2027-01-08T12:00:00+09:00");
const rows = [
  { text: "<img src=x onerror=1> https://tracker.example.test/promises/1", at: at("2027-01-01T08:00:00+09:00") },
  { text: "research on X", at: at("2027-01-08T09:05:00+09:00") },
  { text: "late", at: at("2027-01-05T08:00:00+09:00") },
  { text: "no time" },
].map((m) => chatBackRow(m, now));
const flat = (n) => ({ tag: n.tag, cls: n.cls, text: n.text, href: n.href, title: n.title, kids: n.kids.map(flat) });
console.log(JSON.stringify([rows.map(flat), chatWaitRow({ id: "demo#1", subject: "s", url: "" }).kids[0].kids.map((k) => k.cls)]));
""")
    rows, first_list = got
    assert [r["cls"] for r in rows] == ["wait-row back-row red", "wait-row back-row", "wait-row back-row late", "wait-row back-row"]
    subj, meta = rows[0]["kids"]
    assert [(k["tag"], k["cls"], k.get("text")) for k in subj["kids"]] == [("span", "wait-title", "<img src=x onerror=1> https://tracker.example.test/promises/1")]
    assert [(k["cls"], k.get("text")) for k in meta["kids"]] == [("red", "since Fri Jan 1st"), ("red age", "7 days")]
    assert [(k["cls"], k.get("text")) for k in rows[1]["kids"][1]["kids"]] == [("", "since 09:05")]
    assert [(k["cls"], k.get("text")) for k in rows[2]["kids"][1]["kids"]] == [("late", "since Tue 08:00"), ("late age", "3 days")]
    assert rows[3]["kids"][1]["kids"] == []
    assert not [k for r in rows for part in r["kids"] for k in part["kids"] if k.get("href") or k.get("title")]
    assert first_list == ["wait-id", "wait-title", "new"]                                    # the first list keeps its id and its tag
