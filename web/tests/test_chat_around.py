"""A chat opened at an entry however far back it is: the page AROUND a line, newer pages after it, and a Search result that lands there.

`GET /api/s/<pid>/transcript?around=<cursor>` gives about n/2 messages before the line that starts at the cursor (a Search result's
`pos`) and the rest from it on, with `before` (older pages, as GET ?before= takes) and `after` (newer pages: GET ?after=<cursor>), plus
`start` and `end` (the file's start / end is in). Checked here: the page in the middle, near the start and near the end of a file, the
newer pages walked to the end without loss or repeat, bad cursors refused (400) like `before`'s, and, in a headless Chromium when one is
installed (conftest.py: `served`, `browser`), on a desktop and on a phone: a Search result 500 messages back opens its chat around it and
lights it; lines written meanwhile wait; scrolling down loads newer pages until the live end, where they show (each once) and the chat
is live again; scrolling up still loads older pages; a subagent's result opens the session's chat at the Agent call that started it.
Every temporary folder is removed when its test ends, passed or failed.
"""

from __future__ import annotations

import json
import os
import shutil
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

import pytest

from conftest import NAME, SID, transcript_file
from sala_web import transcript as TR

ROW = "f0000000-0000-4000-8000-00000000000a"
AGENT_ID = "a1b2c3d4e5"


@pytest.fixture(autouse=True)
def _rm_tmp(tmp_path):
    """pytest keeps its last temporary folders; these are removed as each test ends (after `served` has stopped)."""
    yield
    shutil.rmtree(tmp_path, ignore_errors=True)


def iso(ago_s: float) -> str:
    return datetime.fromtimestamp(time.time() - ago_s, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def msg(i: int, text: str | None = None, ago_s: float | None = None, **extra) -> str:
    kind = "user" if i % 2 == 0 else "assistant"
    d = {"type": kind, "uuid": f"m-{i}", "timestamp": iso(ago_s if ago_s is not None else 3600 - i), "sessionId": SID,
         "message": {"role": kind, "content": [{"type": "text", "text": text if text is not None else f"message {i}"}]}}
    d.update(extra)
    return json.dumps(d) + "\n"


def body(k: int, special: dict[int, str] | None = None) -> str:
    special = special or {}
    return "".join(special.get(i) or msg(i) for i in range(k))


def starts(p) -> dict[str, int]:
    """uuid -> the offset of its line's start."""
    out, pos = {}, 0
    for line in p.read_bytes().split(b"\n")[:-1]:
        try:
            out[json.loads(line)["uuid"]] = pos
        except (ValueError, KeyError):
            pass
        pos += len(line) + 1
    return out


def uuids(msgs):
    return [m["uuid"] for m in msgs]


def rng(a: int, b: int) -> list[str]:
    return [f"m-{i}" for i in range(a, b)]


# ---------- the reads ----------

def test_around_a_line_in_the_middle(tmp_path):
    p = tmp_path / f"{SID}.jsonl"
    p.write_text(body(1000))
    at = starts(p)["m-500"]
    d = TR.read_around(p, SID, at, n=200)
    assert uuids(d["messages"]) == rng(400, 600) and not d["start"] and not d["end"]
    assert d["before"] == starts(p)["m-400"] and d["after"] == starts(p)["m-600"]
    assert uuids(TR.read_before(p, SID, d["before"], 50)[0]) == rng(350, 400)     # the cursors page on as the others do
    assert uuids(TR.read_around(p, SID, str(at), n=10)["messages"]) == rng(495, 505)   # as a query string gives it


def test_around_a_line_near_the_start_fills_the_page_after_it(tmp_path):
    p = tmp_path / f"{SID}.jsonl"
    p.write_text("{\"type\":\"summary\"}\n" + body(400))
    d = TR.read_around(p, SID, starts(p)["m-30"], n=200)
    assert uuids(d["messages"]) == rng(0, 200) and d["start"] and d["before"] == 0 and not d["end"]
    d0 = TR.read_around(p, SID, 0, n=20)
    assert uuids(d0["messages"]) == rng(0, 20) and d0["start"]


def test_around_a_line_near_the_end_says_the_end_is_in(tmp_path):
    p = tmp_path / f"{SID}.jsonl"
    p.write_text(body(400) + '{"type": "user", "uuid": "half-writ')          # a line still being written is left out
    d = TR.read_around(p, SID, starts(p)["m-380"], n=200)
    assert uuids(d["messages"]) == rng(280, 400) and d["end"] and not d["start"]
    assert d["after"] == TR.complete_end(p)
    msgs, cur, end = TR.read_after(p, SID, d["after"])
    assert (msgs, cur, end) == ([], d["after"], True)


def test_newer_pages_walk_to_the_end_without_loss_or_repeat(tmp_path, monkeypatch):
    monkeypatch.setattr(TR, "CHUNK", 777)              # many reads, lines cut at the chunk edges
    p = tmp_path / f"{SID}.jsonl"
    p.write_text(body(230, {57: msg(57, "z" * 5000)}))
    d = TR.read_around(p, SID, starts(p)["m-40"], n=20)
    got, after, end = uuids(d["messages"]), d["after"], d["end"]
    while not end:
        msgs, after, end = TR.read_after(p, SID, after, 33)
        got += uuids(msgs)
    assert got == rng(30, 230)


def test_bad_cursors_are_refused_for_around_and_after(tmp_path):
    p = tmp_path / f"{SID}.jsonl"
    p.write_text(body(5))
    size = p.stat().st_size
    for bad in ("x", "-1", -1, 3, size + 1, "1e3", True, None, 1.5):
        with pytest.raises(TR.BadCursor):
            TR.read_around(p, SID, bad)
        with pytest.raises(TR.BadCursor):
            TR.read_after(p, SID, bad)


# ---------- the API route ----------

def get(url: str) -> tuple[int, dict]:
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


def test_route_gives_the_page_around_and_the_pages_after(served):
    p = transcript_file(served)
    p.write_text(body(700))
    base = f"{served['url']}/api/s/{os.getpid()}/transcript"
    st, d = get(f"{base}?around={starts(p)['m-300']}")
    assert st == 200 and uuids(d["messages"]) == rng(200, 400) and not d["start"] and not d["end"], d.get("error")
    assert d["session"]["sessionId"] == SID and "path" not in d
    st, d2 = get(f"{base}?after={d['after']}")
    assert st == 200 and uuids(d2["messages"]) == rng(400, 600) and not d2["end"] and "before" not in d2
    st, d3 = get(f"{base}?after={d2['after']}")
    assert st == 200 and uuids(d3["messages"]) == rng(600, 700) and d3["end"]
    st, d4 = get(f"{base}?before={d['before']}")
    assert st == 200 and uuids(d4["messages"]) == rng(0, 200) and d4["start"]
    st, d5 = get(f"{base}?around=0&n=6")
    assert st == 200 and uuids(d5["messages"]) == rng(0, 6) and d5["start"]
    st, d6 = get(f"{base}?around={starts(p)['m-699']}")
    assert st == 200 and d6["end"] and uuids(d6["messages"])[-1] == "m-699"


def test_route_refuses_bad_cursors(served):
    p = transcript_file(served)
    p.write_text(body(20))
    base = f"{served['url']}/api/s/{os.getpid()}/transcript"
    for key in ("around", "after"):
        for bad in ("x", "-5", "10", str(p.stat().st_size + 1), "/etc/passwd", "1e3", ""):
            st, e = get(f"{base}?{key}={urllib.request.quote(bad)}")
            assert st == 400 and e["ok"] is False, (key, bad, e)
    st, e = get(f"{base}?around=0&before=0")
    assert st == 400 and e["ok"] is False


# ---------- the page ----------

STUB = """(() => {
  const real = window.fetch.bind(window);
  window.__fetched = [];
  window.fetch = (url, opts) => {
    const u = String(url);
    if (u.includes("/transcript?")) window.__fetched.push(u.replace(/^.*\\?/, ""));
    if (u.startsWith("api/schedules")) return Promise.resolve(new Response(JSON.stringify({ generated: null, timezone: "", timers: [], cron: [],
      counts: { timers: 0, cron: 0, flagged: 0, byReason: {}, packaged: 0 }, scopes: { user: true, system: true } }), { headers: { "Content-Type": "application/json" } }));
    return real(url, opts);
  };
})();"""

K = 800          # messages in the transcript
FAR = 300        # the entry the search finds: 500 back from the end, far outside the chat's last 200
CALL = 120       # the Agent call that started the subagent


def agent_call(i: int) -> str:
    return json.dumps({"type": "assistant", "uuid": f"m-{i}", "timestamp": iso(3600 - i), "sessionId": SID,
                       "message": {"role": "assistant", "content": [
                           {"type": "text", "text": f"message {i}"},
                           {"type": "tool_use", "id": "toolu_far", "name": "Agent", "input": {"description": "dig", "prompt": "go"}}]}}) + "\n"


def agent_result(i: int) -> str:
    return json.dumps({"type": "user", "uuid": f"m-{i}", "timestamp": iso(3600 - i), "sessionId": SID,
                       "toolUseResult": {"status": "completed", "agentId": AGENT_ID},
                       "message": {"role": "user", "content": [
                           {"type": "text", "text": f"message {i}"},
                           {"type": "tool_result", "tool_use_id": "toolu_far", "content": "dug"}]}}) + "\n"


def prepare(served) -> None:
    st = served["settings"].sala_state_dir
    st.mkdir(parents=True, exist_ok=True)
    (st / "sessions.json").write_text(json.dumps({"schema": 1, "sessions": {ROW: {
        "id": ROW, "name": NAME, "role": "front", "state": "live", "transcripts": [{"id": SID, "why": "add"}]}}}))
    p = transcript_file(served)
    p.write_text(body(K, {FAR: msg(FAR, "the quokka is here"), CALL: agent_call(CALL), CALL + 1: agent_result(CALL + 1)}))
    sub = p.parent / SID / "subagents" / f"agent-{AGENT_ID}.jsonl"
    sub.parent.mkdir(parents=True)
    sub.write_text(json.dumps({"type": "assistant", "uuid": "s-1", "timestamp": iso(3000), "sessionId": SID, "isSidechain": True,
                               "agentId": AGENT_ID, "message": {"role": "assistant", "content": [{"type": "text", "text": "a wombat found"}]}}) + "\n")


def wait(browser, expr: str, what: str, ms: int = 15000):
    v = browser.evaluate("""new Promise((res) => { const t0 = Date.now(); (function poll() {
      let v; try { v = (%s); } catch (e) { v = null; }
      if (v || Date.now() - t0 > %d) res(v || null); else setTimeout(poll, 50); })(); })""" % (expr, ms))
    assert v, what
    return v


def search_and_open(browser, q: str) -> None:
    """The Search results page for q, with every agent and messages and tool calls ticked over the last 24 h (an address, as a shared
    link would give it), then its one result's link."""
    browser.evaluate('go("#search?" + new URLSearchParams({ q: %s, hours: "24", front: "1", back: "1", sub: "1", unknown: "1", '
                     'messages: "1", tools: "1", output: "0", thinking: "0" }))' % json.dumps(q))
    wait(browser, 'document.body.classList.contains("search-open")', "the Search page")
    wait(browser, 'document.querySelectorAll("#se-hits a.se-link").length === 1', "the result, with a link to the chat")
    browser.evaluate('document.querySelector("#se-hits a.se-link").click()')
    wait(browser, 'location.hash === "#s=%s"' % NAME, "the session's chat opens")


ORDER = "[...document.querySelectorAll('#chat > .msg')].map((m) => m.dataset.uuid)"

# scroll to the bottom until the .newer line is gone (the live end is in), at most 20 times
SCROLL_DOWN = r"""
new Promise((res) => {
  const p = document.querySelector("#chat-pane"); let n = 0;
  const t0 = Date.now();
  (function step() {
    p.scrollTop = p.scrollHeight; n++;
    if (!document.querySelector("#chat > .newer") || Date.now() - t0 > 20000) res({ steps: n, newer: !!document.querySelector("#chat > .newer") });
    else setTimeout(step, 150);
  })();
})
"""


@pytest.mark.parametrize("w,h,mobile", [(1280, 800, False), (390, 760, True)])
def test_a_result_far_back_opens_there_and_scrolling_down_meets_the_live_end(served, browser, w, h, mobile):
    prepare(served)
    browser.send("Emulation.setDeviceMetricsOverride", {"width": w, "height": h, "deviceScaleFactor": 1, "mobile": mobile})
    if mobile:
        browser.send("Emulation.setTouchEmulationEnabled", {"enabled": True, "maxTouchPoints": 5})
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": STUB})
    browser.open(f"{served['url']}/#sessions", dark=False)
    wait(browser, "typeof state !== 'undefined' && state.byName.has(%s)" % json.dumps(NAME), "the session list")
    search_and_open(browser, "quokka")
    wait(browser, '!!document.querySelector("#chat .msg.search-hit")', "the entry far back is lit")
    got = browser.evaluate("""(() => { const m = document.querySelector("#chat .msg.search-hit"), p = document.querySelector("#chat-pane");
      const r = m.getBoundingClientRect(), pr = p.getBoundingClientRect();
      return { uuid: m.dataset.uuid, inView: r.bottom > pr.top && r.top < pr.bottom, newer: !!document.querySelector("#chat > .newer"),
               pinned: chatScroll.pinned, jump: !document.querySelector("#jump").hidden, sideways: document.documentElement.scrollWidth > innerWidth }; })()""")
    assert got == {"uuid": f"m-{FAR}", "inView": True, "newer": True, "pinned": False, "jump": True, "sideways": False}, got
    order = browser.evaluate(ORDER)
    assert f"m-{FAR}" in order and f"m-{K - 1}" not in order and len(order) <= 220      # the page around it, not the tail
    assert any(f.startswith("around=") for f in browser.evaluate("window.__fetched"))
    wait(browser, "!document.querySelector('#chat .msg.search-hit')", "the light goes after a few seconds", ms=8000)
    # a line written while the chat is far back waits for the live end (the stream keeps it)
    with open(transcript_file(served), "a") as f:
        f.write(msg(K, "written while far back", ago_s=1))
    time.sleep(2.0)
    assert f"m-{K}" not in browser.evaluate(ORDER)
    # scrolled down: newer pages until the live end, then what the stream held, each once
    got = browser.evaluate(SCROLL_DOWN)
    assert not got["newer"], got
    wait(browser, "[...document.querySelectorAll('#chat > .msg')].some((m) => m.dataset.uuid === 'm-%d')" % K, "the line written meanwhile")
    order = browser.evaluate(ORDER)
    assert order[order.index(f"m-{FAR}"):] == rng(FAR, K + 1), order[-5:]
    assert len(order) == len(set(order))
    assert any(f.startswith("after=") for f in browser.evaluate("window.__fetched"))
    # live again: at the bottom it pins, and a new line shows at once
    browser.evaluate("(() => { const p = document.querySelector('#chat-pane'); p.scrollTop = p.scrollHeight; })()")
    wait(browser, "chatScroll.pinned", "pinned at the live end")
    with open(transcript_file(served), "a") as f:
        f.write(msg(K + 1, "after the live end", ago_s=0))
    wait(browser, "[...document.querySelectorAll('#chat > .msg')].some((m) => m.dataset.uuid === 'm-%d')" % (K + 1), "a live line")
    assert browser.evaluate("(() => { const p = document.querySelector('#chat-pane'); return p.scrollHeight - p.scrollTop - p.clientHeight < 80; })()")
    # scrolled up: the older pages still come, down to the start
    browser.evaluate("""new Promise((res) => { const p = document.querySelector('#chat-pane'); const t0 = Date.now();
      (function step() { p.scrollTop = 0; const l = document.querySelector('#chat > .older');
        if ((l && l.classList.contains('at-start')) || Date.now() - t0 > 20000) res(true); else setTimeout(step, 150); })(); })""")
    assert browser.evaluate(ORDER) == rng(0, K + 2)


def test_jump_while_far_back_goes_to_the_live_end(served, browser):
    prepare(served)
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": STUB})
    browser.open(f"{served['url']}/#sessions", dark=False)
    wait(browser, "typeof state !== 'undefined' && state.byName.has(%s)" % json.dumps(NAME), "the session list")
    search_and_open(browser, "quokka")
    wait(browser, '!!document.querySelector("#chat .msg.search-hit")', "the entry far back is lit")
    browser.evaluate('document.querySelector("#jump").click()')
    wait(browser, "chatScroll.pinned && !document.querySelector('#chat > .newer') && "
                  "[...document.querySelectorAll('#chat > .msg')].pop().dataset.uuid === 'm-%d'" % (K - 1), "the live end")
    assert len(browser.evaluate(ORDER)) == 200


def test_an_entry_the_chat_does_not_show_says_it_opens_where_it_was(served, browser):
    """A compaction summary is in the file but not in the chat: opening at it loads the page around it, so the line must not say
    the chat opened at the latest messages."""
    prepare(served)
    p = transcript_file(served)
    summary = json.dumps({"type": "user", "uuid": "sum", "isCompactSummary": True, "timestamp": iso(3600 - FAR), "sessionId": SID,
                          "message": {"role": "user", "content": [{"type": "text", "text": "This session is being continued from a previous conversation"}]}}) + "\n"
    p.write_text(body(K, {FAR: summary}))
    pos = starts(p)["sum"]
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": STUB})
    browser.open(f"{served['url']}/#s={NAME}", dark=False)
    wait(browser, "document.querySelectorAll('#chat > .msg').length === 200", "the tail")
    browser.evaluate("openAt(%s, 'sum', { pos: %d, session: %s })" % (json.dumps(NAME), pos, json.dumps(SID)))
    wait(browser, "document.querySelector('#send-status').textContent.startsWith('That entry')", "the line about the entry")
    assert browser.evaluate("document.querySelector('#send-status').textContent") == "That entry is not shown in this chat; it opens where it was."
    order = browser.evaluate(ORDER)
    assert f"m-{FAR - 1}" in order and f"m-{K - 1}" not in order      # the page around it, not the latest messages


def test_a_subagents_result_opens_the_chat_at_the_agent_call(served, browser):
    """The chat is open at its live end first, so the result finds it loaded without the call in it."""
    prepare(served)
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": STUB})
    browser.open(f"{served['url']}/#s={NAME}", dark=False)
    wait(browser, "document.querySelectorAll('#chat > .msg').length === 200", "the tail")
    search_and_open(browser, "wombat")
    wait(browser, '!!document.querySelector("#chat .msg.search-hit")', "the Agent call is lit")
    assert browser.evaluate('document.querySelector("#chat .msg.search-hit").dataset.uuid') == f"m-{CALL}"
    assert browser.evaluate('!!document.querySelector("#chat .msg.search-hit details.tool")')


def test_a_normal_open_is_unchanged(served, browser):
    prepare(served)
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": STUB})
    browser.open(f"{served['url']}/#s={NAME}", dark=False)
    wait(browser, "document.querySelectorAll('#chat > .msg').length === 200", "the tail")
    got = browser.evaluate("""({ last: [...document.querySelectorAll('#chat > .msg')].pop().dataset.uuid, pinned: chatScroll.pinned,
      newer: !!document.querySelector('#chat > .newer'), fetched: window.__fetched.filter((f) => !f.startsWith("before=")) })""")
    assert got == {"last": f"m-{K - 1}", "pinned": True, "newer": False, "fetched": []}, got
