"""Older messages, a page at a time, as the chat is scrolled to its top.

The chat opens with the last 200 messages of the transcript and a cursor, `before`: the byte offset in the transcript where
they begin. `GET /api/s/<pid>/transcript?before=<cursor>` gives the 200 messages that end before it, the next cursor and
`start` (the file's start was reached); `transcript.read_before` reads the file backwards from the offset in CHUNK-sized
reads, never whole. Checked here: the cursor math over a whole file paged to its start (no message lost or repeated, the
cursor always a line's start), non-message lines at the start, a message that spans a chunk edge, the max_bytes stop,
bad cursors refused (not an integer, negative, past the end, mid-line), the API route on the fake session, and, in a headless
Chromium when one is installed (conftest.py: `served`, `browser`), the page: scrolled to its top it loads the page before,
puts it above the oldest message with the message in view kept where it was on the screen, and stops at "Start of this
conversation", on a desktop and on a phone. Every temporary folder is removed when its test ends, passed or failed.
"""

from __future__ import annotations

import json
import shutil
import urllib.error
import urllib.request

import pytest

from conftest import NAME, transcript_file, transcript_line
from sala_web import transcript as TR

SID = "11111111-2222-3333-4444-555555555555"


@pytest.fixture(autouse=True)
def _rm_tmp(tmp_path):
    """pytest keeps its last temporary folders; these are removed as each test ends (after `served` has stopped)."""
    yield
    shutil.rmtree(tmp_path, ignore_errors=True)


def row(i: int, text: str | None = None) -> str:
    return json.dumps({"type": "user", "uuid": f"u{i}", "timestamp": "2026-10-13T00:00:00Z", "sessionId": SID,
                       "message": {"role": "user", "content": text if text is not None else f"msg {i}"}}) + "\n"


def write(tmp_path, *parts: str):
    p = tmp_path / f"{SID}.jsonl"
    p.write_bytes("".join(parts).encode())
    return p


def uuids(msgs):
    return [m["uuid"] for m in msgs]


def line_starts(p) -> set[int]:
    data = p.read_bytes()
    return {0} | {i + 1 for i, c in enumerate(data) if c == 0x0A}


# ---------- the backwards page read ----------

def test_pages_back_to_the_start_without_loss_or_repeat(tmp_path):
    p = write(tmp_path, *(row(i) for i in range(23)))
    msgs, cursor, end = TR.read_tail_page(p, SID, n=5)
    assert uuids(msgs) == [f"u{i}" for i in range(18, 23)] and end == p.stat().st_size
    assert cursor == p.read_bytes().index(row(18).encode())
    got = msgs
    starts = line_starts(p)
    pages = 0
    while cursor:
        assert cursor in starts
        older, cursor, at_start = TR.read_before(p, SID, cursor, n=5)
        assert at_start == (cursor == 0)
        got = older + got
        pages += 1
    assert uuids(got) == [f"u{i}" for i in range(23)] and pages == 4
    # at the start: an empty page, still at the start
    assert TR.read_before(p, SID, 0, n=5) == ([], 0, True)


def test_cursor_from_the_tail_and_the_whole_file_in_one_page(tmp_path):
    p = write(tmp_path, *(row(i) for i in range(3)))
    msgs, cursor, _ = TR.read_tail_page(p, SID, n=200)
    assert uuids(msgs) == ["u0", "u1", "u2"] and cursor == 0
    # read_tail keeps its old answer: the messages and the end to tail from
    assert TR.read_tail(p, SID, n=2) == (msgs[1:], p.stat().st_size)


def test_lines_that_are_not_messages_at_the_start_are_passed_over(tmp_path):
    p = write(tmp_path, '{"type": "summary"}\n', "\n", "not json\n", row(0), row(1), row(2))
    _, cursor, _ = TR.read_tail_page(p, SID, n=2)
    assert cursor == p.read_bytes().index(row(1).encode())
    older, cursor, at_start = TR.read_before(p, SID, cursor, n=2)
    assert uuids(older) == ["u0"] and cursor == 0 and at_start


def test_a_message_spanning_a_chunk_edge(tmp_path, monkeypatch):
    monkeypatch.setattr(TR, "CHUNK", 64)  # rows are ~150 bytes: every one crosses an edge, the long one several
    p = write(tmp_path, row(0), row(1, "x" * 1000), row(2), row(3), row(4))
    msgs, cursor, _ = TR.read_tail_page(p, SID, n=2)
    assert uuids(msgs) == ["u3", "u4"]
    older, cursor, at_start = TR.read_before(p, SID, cursor, n=2)
    assert uuids(older) == ["u1", "u2"] and older[0]["blocks"][0]["text"] == "x" * 1000
    assert cursor == len(row(0).encode()) and not at_start
    older, cursor, at_start = TR.read_before(p, SID, cursor, n=2)
    assert uuids(older) == ["u0"] and cursor == 0 and at_start


def test_a_line_still_being_written_is_left_out(tmp_path):
    p = write(tmp_path, row(0), row(1), '{"type": "user", "uuid": "half')
    msgs, cursor, end = TR.read_tail_page(p, SID, n=1)
    assert uuids(msgs) == ["u1"] and end == len((row(0) + row(1)).encode())
    with pytest.raises(TR.BadCursor):
        TR.read_before(p, SID, p.stat().st_size, n=1)  # past the complete lines
    assert uuids(TR.read_before(p, SID, cursor, n=1)[0]) == ["u0"]


def test_max_bytes_stops_with_a_cursor_to_go_on_from(tmp_path, monkeypatch):
    monkeypatch.setattr(TR, "CHUNK", 200)
    filler = "".join(json.dumps({"type": "progress", "pad": "p" * 150, "k": i}) + "\n" for i in range(20))
    p = write(tmp_path, row(0), filler, row(1))
    msgs, cursor, _ = TR.read_tail_page(p, SID, n=1)
    older, cursor2, at_start = TR.read_before(p, SID, cursor, n=1, max_bytes=500)
    assert older == [] and not at_start and 0 < cursor2 < cursor and cursor2 in line_starts(p)
    while not at_start:
        older, cursor2, at_start = TR.read_before(p, SID, cursor2, n=1, max_bytes=500)
        if older:
            break
    assert uuids(older) == ["u0"]


@pytest.mark.parametrize("bad", ["abc", "-1", "1.5", "", " 3", "0x10", "١٢", "9" * 40, -1, 1.5, True, None, [3]])
def test_bad_cursors_are_refused(tmp_path, bad):
    p = write(tmp_path, row(0), row(1))
    with pytest.raises(TR.BadCursor):
        TR.read_before(p, SID, bad)


def test_a_cursor_past_the_end_or_mid_line_is_refused(tmp_path):
    p = write(tmp_path, row(0), row(1))
    size = p.stat().st_size
    for bad in (size + 1, 5, len(row(0).encode()) - 1, str(size + 100)):
        with pytest.raises(TR.BadCursor):
            TR.read_before(p, SID, bad)
    assert uuids(TR.read_before(p, SID, str(size))[0]) == ["u0", "u1"]  # the end itself, as a query string gives it


# ---------- the API route ----------

def get(url: str) -> tuple[int, dict]:
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


def many(k: int, long_at: int | None = None) -> str:
    return "".join(transcript_line("user" if i % 2 == 0 else "assistant",
                                   [{"type": "text", "text": ("y" * 3000 if i == long_at else f"message {i}")}], f"m-{i}")
                   for i in range(k))


def test_route_pages_back_and_refuses_bad_cursors(served):
    import os
    transcript_file(served).write_text(many(450))
    base = f"{served['url']}/api/s/{os.getpid()}/transcript"
    st, d = get(base)
    assert st == 200 and len(d["messages"]) == 200 and d["messages"][0]["uuid"] == "m-250" and not d["start"]
    st, d2 = get(f"{base}?before={d['before']}")
    assert st == 200 and [m["uuid"] for m in d2["messages"]] == [f"m-{i}" for i in range(50, 250)] and not d2["start"]
    assert "path" not in d2
    st, d3 = get(f"{base}?before={d2['before']}")
    assert st == 200 and [m["uuid"] for m in d3["messages"]] == [f"m-{i}" for i in range(50)]
    assert d3["start"] and d3["before"] == 0
    st, d4 = get(f"{base}?before=0&n=5")
    assert st == 200 and d4 == {**d4, "messages": [], "before": 0, "start": True}
    for bad in ("x", "-5", "10", str(transcript_file(served).stat().st_size + 1), "/etc/passwd", "1e3"):
        st, e = get(f"{base}?before={urllib.request.quote(bad)}")
        assert st == 400 and e["ok"] is False, (bad, e)
    st, e = get(f"{base}?n=lots")
    assert st == 400


def test_route_on_a_short_transcript_says_start(served):
    import os
    st, d = get(f"{served['url']}/api/s/{os.getpid()}/transcript")
    assert st == 200 and d["before"] == 0 and d["start"] is True


# ---------- the page ----------

WAIT_COUNT = """
new Promise((res) => { const t0 = Date.now(); (function poll() {
  const n = document.querySelectorAll("#chat > .msg").length;
  if (n >= %d || Date.now() - t0 > 15000) res(n); else setTimeout(poll, 50);
})(); })
"""

# scroll to the top and report where the message that was in view sits on the screen before and after the older page lands
SCROLL_TOP = r"""
new Promise((res) => {
  const p = document.querySelector("#chat-pane"), chat = document.querySelector("#chat");
  const before = chat.querySelectorAll(":scope > .msg").length;
  p.scrollTop = 0;
  const first = chat.querySelector(":scope > .msg");
  const y0 = first.getBoundingClientRect().top;
  const line = chat.querySelector(":scope > .older");
  const seen = [line ? line.textContent : null];
  // every text the line takes, however briefly (a fast local fetch is over between two polls)
  if (line) new MutationObserver(() => { if (!seen.includes(line.textContent)) seen.push(line.textContent); })
    .observe(line, { childList: true, characterData: true, subtree: true });
  const t0 = Date.now();
  (function poll() {
    const l = chat.querySelector(":scope > .older");
    if (l && !seen.includes(l.textContent)) seen.push(l.textContent);
    const n = chat.querySelectorAll(":scope > .msg").length;
    if ((n > before && !(l && l.textContent.startsWith("Loading"))) || Date.now() - t0 > 15000) {
      requestAnimationFrame(() => res({
        before, after: n, uuid: first.dataset.uuid, y0, y1: first.getBoundingClientRect().top,
        firstNow: chat.querySelector(":scope > .msg").dataset.uuid, older: chat.firstElementChild.className,
        text: l ? l.textContent : null, atStart: l ? l.classList.contains("at-start") : null, seen, scrollTop: p.scrollTop,
      }));
    } else setTimeout(poll, 20);
  })();
})
"""


@pytest.mark.parametrize("w,h,mobile", [(1280, 800, False), (390, 760, True)])
def test_scrolling_to_the_top_loads_older_messages_in_place(served, browser, w, h, mobile):
    transcript_file(served).write_text(many(450, long_at=120))
    browser.send("Emulation.setDeviceMetricsOverride", {"width": w, "height": h, "deviceScaleFactor": 1, "mobile": mobile})
    if mobile:
        browser.send("Emulation.setTouchEmulationEnabled", {"enabled": True, "maxTouchPoints": 5})
    browser.open(f"{served['url']}/#s={NAME}")
    assert browser.evaluate(WAIT_COUNT % 200) == 200
    top = browser.evaluate("(() => { const l = document.querySelector('#chat > .older'); "
                           "return l && {first: l === document.querySelector('#chat').firstElementChild, text: l.textContent}; })()")
    assert top == {"first": True, "text": ""}
    got = browser.evaluate(SCROLL_TOP)
    assert got["before"] == 200 and got["after"] == 400, got
    assert got["uuid"] == "m-250" and got["firstNow"] == "m-50", got
    assert abs(got["y1"] - got["y0"]) <= 2 and got["scrollTop"] > 0, got  # the message read stays put
    assert "Loading older messages…" in got["seen"] and got["text"] == "" and not got["atStart"], got
    # in order, none twice
    order = browser.evaluate("[...document.querySelectorAll('#chat > .msg')].map((m) => m.dataset.uuid)")
    assert order == [f"m-{i}" for i in range(50, 450)]
    got = browser.evaluate(SCROLL_TOP)
    assert got["after"] == 450 and got["firstNow"] == "m-0" and abs(got["y1"] - got["y0"]) <= 2, got
    assert got["text"] == "Start of this conversation" and got["atStart"] and got["older"] == "older at-start", got
    # at the start nothing more is fetched
    n = browser.evaluate("""new Promise((res) => { const p = document.querySelector('#chat-pane'); p.scrollTop = 0;
      setTimeout(() => res(document.querySelectorAll('#chat > .msg').length), 600); })""")
    assert n == 450


def test_a_short_conversation_shows_its_start(served, browser):
    browser.open(f"{served['url']}/#s={NAME}")
    assert browser.evaluate(WAIT_COUNT % 1) >= 1
    assert browser.evaluate("document.querySelector('#chat > .older').textContent") == "Start of this conversation"
