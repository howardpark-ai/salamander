"""The timing debug (temporary): the performance.mark()s app.js leaves at each step of a page load, the
recorder static/timing-debug.js that posts them (with the browser's navigation, resource and long-task timings) to
POST /api/debug/timing when ?debug=timing was opened once, the log state_dir/timing-debug.log and its readable summary
(timingdebug.py, GET /api/debug/timing). Why: after the update banner's Reload following a deploy, a page could show
an empty session list for minutes and then a history that took a minute or two, while the server answered in
milliseconds and nothing said where the time went.

Also the history render the measurement led to (tools/measure_load.py, README "Timing"): a reset's messages are built in
a fragment and swapped in at once, a result finds its tool call through the fragment's own map, the copy icon is cloned
and the sanitized markdown is appended as nodes; what the page shows must be what it showed before, so the render is
checked on a long transcript (tests/bigfixture.py): every result in its call's slot, a result without its call as its
own fold, a live append still pairing with a call from the reset.

The endpoint tests use Starlette's TestClient; the page tests run in a headless Chromium (conftest.py: `served`,
`browser`) and are skipped without one.
"""

from __future__ import annotations

import json
import re
import time
import urllib.request
from datetime import datetime, timedelta, timezone

import pytest
from starlette.testclient import TestClient

from bigfixture import big_transcript
from conftest import NAME, transcript_file, transcript_line
from sala_web import debuglog as DL
from sala_web import timingdebug as TD
from sala_web import tz as TZ
from sala_web.app import STATIC, create_app
from sala_web.config import Settings

APP_JS = (STATIC / "app.js").read_text()
RECORDER_JS = (STATIC / "timing-debug.js").read_text()
ISO_Z = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")
N_MSGS = 50  # ten cycles of the big transcript: 10 tool calls with their results (two of them errors)
N_BOXES = N_MSGS + 1 - 10  # a result that found its call has no box of its own; the orphan has one


@pytest.fixture
def env(tmp_path):
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    (claude / "projects").mkdir()
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                        tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"])
    return {"client": TestClient(create_app(settings)), "log": settings.state_dir / TD.LOG_NAME, "dir": settings.state_dir}


def lines_of(path) -> list[dict]:
    return [json.loads(ln) for ln in path.read_text().splitlines() if ln]


# ---------- the endpoint and the summary ----------

def test_post_appends_records_and_get_summarizes_them(env):
    c, log = env["client"], env["log"]
    recs = [{"seq": 1, "t": 0, "load": "ld1", "client": "cl1", "name": "hello", "ua": "Android 14; Chrome/130", "standalone": True, "nav": {"type": "reload", "redirects": 0}},
            {"seq": 2, "t": 1391.0, "load": "ld1", "client": "cl1", "name": "app.js start"},
            {"seq": 3, "t": 6331.7, "load": "ld1", "client": "cl1", "name": "history:rendered", "count": 200, "bytes": 233874, "ms": 2497},
            {"seq": 4, "t": 7000.26, "load": "ld1", "client": "cl1", "name": "reload", "cause": "banner"}]
    assert c.post("/api/debug/timing", json=recs).status_code == 204
    got = lines_of(log)
    assert [g["name"] for g in got] == ["hello", "app.js start", "history:rendered", "reload"]
    assert all(ISO_Z.match(g["ts"]) and list(g)[0] == "ts" for g in got)
    assert (log.stat().st_mode & 0o777) == 0o600 and (env["dir"].stat().st_mode & 0o777) == 0o700
    # the readable form: the header, then one line a record: time (zone) | load | client | +ms | name | the rest as k=v
    r = c.get("/api/debug/timing")
    assert r.status_code == 200 and r.headers["content-type"].startswith("text/plain") and r.headers["cache-control"] == "no-store"
    lines = r.text.splitlines()
    assert lines[0] == TD.header().rstrip("\n") and len(lines) == 5
    col = lambda off: f"{'ld1':6s} {'cl1':6s} {off:>9}"  # noqa: E731  the load and client columns, the offset right-aligned
    assert re.match(r"^\d{2}:\d{2}:\d{2}\.\d{3} ", lines[1]) and lines[1][13:] == col("+0") + ' hello ua="Android 14; Chrome/130" standalone=yes nav={"type":"reload","redirects":0}', lines[1]
    assert lines[2][13:] == col("+1391") + " app.js start"
    assert lines[3][13:] == col("+6331.7") + " history:rendered count=200 bytes=233874 ms=2497"
    assert lines[4][13:] == col("+7000.3") + " reload cause=banner"
    # the JSON lines themselves with ?raw=1; n limits the tail either way
    raw = c.get("/api/debug/timing?raw=1").text.splitlines()
    assert len(raw) == 4 and json.loads(raw[-1])["cause"] == "banner"
    assert c.get("/api/debug/timing?n=2").text.splitlines()[1:] == lines[3:]
    assert [json.loads(ln)["seq"] for ln in c.get("/api/debug/timing?n=2&raw=1").text.splitlines()] == [3, 4]
    assert c.get("/api/debug/timing?n=x").status_code == 400


def test_an_unknown_debug_log_is_404(env):
    c = env["client"]
    assert c.get("/api/debug/nope").status_code == 404
    assert c.post("/api/debug/nope", json={"a": 1}).status_code == 404
    assert c.post("/api/debug/timing", json={"a": 1}, headers={"Origin": "https://evil.example"}).status_code == 403
    assert c.post("/api/debug/timing", content=b"{nope", headers={"Content-Type": "application/json"}).status_code == 400
    assert c.post("/api/debug/timing", content=b'{"a":1}', headers={"Content-Type": "text/plain"}).status_code == 415
    assert c.post("/api/debug/timing", json=[{"a": 1}] * (DL.MAX_EVENTS + 1)).status_code == 400
    assert not env["log"].exists()
    assert c.post("/api/debug/timing", json={"name": "x", "t": 1}).status_code == 204
    assert len(lines_of(env["log"])) == 1


def test_the_summary_is_in_the_zone_and_keeps_what_it_cannot_parse():
    assert TD.summary("") == "" and TD.summary("\n\n") == ""
    now = datetime.now(timezone.utc)
    today = now.isoformat(timespec="milliseconds").replace("+00:00", "Z")
    other = (now - timedelta(days=3)).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    text = json.dumps({"ts": today, "t": 12.34, "load": "a", "client": "b", "name": "init", "controlled": False, "hash": "#s=x y"}) + "\n" \
        + json.dumps({"ts": other, "load": "a", "client": "b", "name": "longtask", "dur": 806.0, "n": None}) + "\nnot json\n" + json.dumps([1]) + "\n"
    lines = TD.summary(text).splitlines()
    assert lines[0] == TD.header().rstrip("\n") and len(lines) == 5
    local = now.astimezone(TZ.zone())
    col = lambda off: f" {'a':6s} {'b':6s} {off:>9} "  # noqa: E731
    assert lines[1].startswith(local.strftime("%H:%M:")) and lines[1].endswith(col("+12.3") + 'init controlled=no hash="#s=x y"'), lines[1]
    assert lines[2].startswith((now - timedelta(days=3)).astimezone(TZ.zone()).strftime("%b %d %H:%M:")) and lines[2].endswith(col("-") + "longtask dur=806 n=None"), lines[2]
    assert lines[3] == "? not json" and lines[4] == "? [1]"


# ---------- app.js and the recorder ----------

def test_app_js_marks_first_and_loads_the_recorder_only_with_the_flag():
    start, end = APP_JS.index("/* ---------- timing (temporary"), APP_JS.index("/* ---------- end timing loader ---------- */")
    assert start < end < APP_JS.index("const $ = (sel, root = document)")  # first thing in the file: up before anything can throw
    block = APP_JS[start:end]
    assert 'const KEY = "sala.debug.timing"' in block and 'get("debug")' in block
    assert 'want === "timing"' in block and 'want === "off"' in block and "localStorage" in block
    assert "if (!on) return;" in block
    assert 's.src = "static/timing-debug.js?v="' in block and 'api: "api/debug/timing"' in block
    assert "salaTiming" not in APP_JS[end:]  # the rest of app.js only marks
    assert "timing-debug" not in (STATIC / "index.html").read_text()
    for name in ("app.js start", "init", "sessions:request", "sessions:response", "sessions:error", "sessions:rendered", "sessions:painted",
                 "restore", "select", "overview", "stream:open", "stream:opened", "stream:error", "stream:first-event", "stream:reset",
                 "history:rendered", "history:painted", "stream:append", "stream:gone", "version", "reload", "fetch:retry", "fetch:error",
                 "sw:registered", "sw:statechange", "sw:updatefound", "sw:error", "sw:controllerchange"):
        assert f'perfMark("{name}"' in APP_JS, name
    # every reload names its cause
    assert "function reloadPage(cause)" in APP_JS and APP_JS.count("location.reload()") == 1
    assert re.findall(r'reloadPage\("(\w+)"\)', APP_JS) and set(re.findall(r'reloadPage\("(\w+)"\)', APP_JS)) == {"auto", "banner", "menu", "overview"}
    # the recorder: capped, batched, keepalive, a beacon at pagehide; the marks, resources and long tasks observed
    assert "const CAP = 1000" in RECORDER_JS and "const FLUSH_MS = 300" in RECORDER_JS and "keepalive: true" in RECORDER_JS
    assert "navigator.sendBeacon" in RECORDER_JS and '"pagehide"' in RECORDER_JS and '"visibilitychange"' in RECORDER_JS
    for t in ('{ type: "mark" }', '{ type: "resource" }', '{ type: "longtask", buffered: true }'):
        assert t in RECORDER_JS, t
    assert "textContent" not in RECORDER_JS and "innerText" not in RECORDER_JS and ".data" not in RECORDER_JS  # never a message's text


# ---------- in the browser ----------

def log_records(served) -> list[dict]:
    with urllib.request.urlopen(f"{served['url']}/api/debug/timing?raw=1&n=2000", timeout=5) as r:
        return [json.loads(ln) for ln in r.read().decode().splitlines() if ln]


def wait_log(served, pred, timeout: float = 8.0) -> list[dict]:
    t0 = time.monotonic()
    while True:
        recs = log_records(served)
        if pred(recs) or time.monotonic() - t0 > timeout:
            return recs
        time.sleep(0.1)


WAIT_PAINTED = """new Promise((res) => { const t0 = Date.now(); (function poll() {
  if (performance.getEntriesByName("history:painted").length || Date.now() - t0 > 20000) res(performance.getEntriesByName("history:painted").length > 0); else setTimeout(poll, 50);
})(); })"""
WAIT_MSGS = """new Promise((res) => { const t0 = Date.now(); (function poll() {
  if (document.querySelectorAll("#chat > .msg").length >= %d || Date.now() - t0 > 15000) res(document.querySelectorAll("#chat > .msg").length); else setTimeout(poll, 100);
})(); })"""
RENDER = """(() => {
  const calls = [...document.querySelectorAll("#chat details.tool[data-tool-id]")];
  return { msgs: document.querySelectorAll("#chat > .msg").length, calls: calls.length,
           filled: calls.filter((d) => d.querySelector(".result-slot > .result")).length,
           errCalls: calls.filter((d) => d.classList.contains("err") && d.querySelector(".result-slot > .result.err")).length,
           loose: [...document.querySelectorAll("#chat details.tool")].filter((d) => !d.dataset.toolId).map((d) => d.querySelector("summary b").textContent),
           md: document.querySelectorAll("#chat .md").length, links: document.querySelectorAll("#chat .md a[target=_blank][rel]").length,
           codeCopies: [...document.querySelectorAll("#chat .code-copy")].every((b) => b.querySelector("svg rect") && b.getAttribute("aria-label") === "Copy"),
           msgCopies: [...document.querySelectorAll("#chat .copy-btn")].every((b) => b.querySelector("svg rect") && b.title === "Copy"),
           stamps: document.querySelectorAll("#chat .stamp[data-t]").length, folds: document.querySelectorAll("#chat details.thinking").length,
           first: document.querySelector("#chat > .msg").className, lastUuid: [...document.querySelectorAll("#chat > .msg[data-uuid]")].pop().dataset.uuid,
           pinned: (() => { const p = document.querySelector("#chat-pane"); return p.scrollHeight - p.scrollTop - p.clientHeight < 80; })(),
           jumpHidden: document.querySelector("#jump").hidden }; })()"""
STATE = """({ loaded: typeof salaTiming !== "undefined", flag: localStorage.getItem("sala.debug.timing"),
   script: !!document.querySelector('script[src^="static/timing-debug.js"]'), load: typeof salaTiming !== "undefined" ? salaTiming.load : null })"""


def test_the_marks_the_render_and_the_recorder(served, browser):
    # a long transcript, a result whose call is not in it first
    orphan = transcript_line("user", [{"type": "tool_result", "tool_use_id": "toolu_none", "content": "from before the tail"}], "m-0")
    transcript_file(served).write_text(orphan + big_transcript(N_MSGS, scale=0.4))
    browser.open(f"{served['url']}/?debug=timing#s={NAME}")
    assert browser.evaluate(WAIT_PAINTED)
    s = browser.evaluate(STATE)
    assert s["loaded"] and s["flag"] == "1" and s["script"] and len(s["load"]) == 6, s
    # the render, as it was: every result in its call's slot (the errors marked on both), the orphan as its own fold,
    # markdown with its links, a copy button with the icon on each message and code block, the view pinned at the bottom
    r = browser.evaluate(RENDER)
    assert r["msgs"] == N_BOXES and r["calls"] == 10 and r["filled"] == 10 and r["errCalls"] == 2, r
    assert r["loose"] == ["Tool result"] and r["md"] >= 20 and r["links"] >= 20 and r["folds"] == 10, r
    assert r["codeCopies"] and r["msgCopies"] and r["stamps"] >= 20 and r["first"] == "msg user tools-only", r
    assert r["lastUuid"] == f"m-{1000 + N_MSGS}" and r["pinned"] and r["jumpHidden"], r
    # the log: the marks in the order of a load, with their details, each with this load's id and the client's
    recs = wait_log(served, lambda rs: any(x["name"] == "history:painted" for x in rs) and any(x["name"] == "sw:registered" for x in rs))
    by = {}
    for x in recs:
        by.setdefault(x["name"], x)
    order = ["app.js start", "init", "sessions:request", "sessions:response", "sessions:rendered", "restore", "stream:open", "stream:opened",
             "stream:first-event", "stream:reset", "history:rendered", "history:painted"]
    missing = [n for n in order if n not in by]
    assert not missing, (missing, sorted(by))
    ts = [by[n]["t"] for n in order]
    assert ts == sorted(ts) and ts[0] >= 0, list(zip(order, ts))
    assert by["sessions:painted"]["t"] > by["sessions:rendered"]["t"]
    assert by["stream:reset"]["count"] == N_MSGS + 1 and by["stream:reset"]["bytes"] > 10000 and by["stream:reset"]["resumed"] is False
    assert by["history:rendered"]["count"] == N_MSGS + 1 and by["history:rendered"]["ms"] >= 0 and by["history:painted"]["count"] == N_MSGS + 1
    assert by["restore"]["session"] == NAME and by["select"]["session"] == NAME and by["select"]["live"] is True and by["init"]["hash"] == f"#s={NAME}"
    assert by["sessions:response"]["status"] == 200 and by["sessions:rendered"]["count"] == 1
    assert by["version"]["same"] is True and by["version"]["server"] == by["version"]["loaded"]
    assert by["sw:registered"]["controlled"] is False and all(isinstance(by["sw:registered"][k], bool) for k in ("installing", "waiting", "active"))
    hello = by["hello"]
    assert hello["t"] == 0 and "Chrome" in hello["ua"] and hello["standalone"] is False and hello["controlled"] is False and hello["cap"] == 1000
    assert hello["nav"]["type"] == "navigate" and hello["nav"]["redirects"] == 0 and hello["nav"]["responseStart"] > 0 and hello["hash"] == f"#s={NAME}"
    with urllib.request.urlopen(f"{served['url']}/api/config", timeout=5) as resp:
        assert hello["version"] == json.load(resp)["version"] == by["version"]["server"]
    res = {x["url"]: x for x in recs if x["name"] == "resource"}
    assert {"static/app.js", "static/style.css", "api/sessions", "api/config", "manifest.webmanifest"} <= set(res), sorted(res)
    assert res["static/app.js"]["body"] > 50000 and res["static/app.js"]["dur"] >= 0 and res["static/app.js"]["as"] == "script"
    assert res["api/sessions"]["status"] == 200 and not any(u.startswith("api/debug/") for u in res)
    assert by["load"]["nav"]["load"] > 0
    load, client = hello["load"], hello["client"]
    assert all(x["load"] == load and x["client"] == client and ISO_Z.match(x["ts"]) and isinstance(x["seq"], int) for x in recs)
    assert all(list(x)[-5:] == ["seq", "t", "load", "client", "name"] for x in recs)  # a detail never renames a record
    assert len(load) == 6 and len(client) == 6
    # nothing of the transcript's text in the log
    raw = (served["settings"].state_dir / TD.LOG_NAME).read_text()
    assert "from before the tail" not in raw and "board.example.test" not in raw
    # a live append: a result for a call the reset rendered goes into its slot, one for no call becomes its own fold
    with transcript_file(served).open("a") as f:
        f.write(transcript_line("user", [{"type": "tool_result", "tool_use_id": "toolu_0003", "content": "late result"}], "m-live-1"))
        f.write(transcript_line("user", [{"type": "tool_result", "tool_use_id": "toolu_gone", "content": "no call"}], "m-live-2"))
    assert browser.evaluate(WAIT_MSGS % (N_BOXES + 1)) == N_BOXES + 1
    r2 = browser.evaluate(RENDER)
    assert r2["calls"] == 10 and r2["filled"] == 10 and r2["loose"] == ["Tool result", "Tool result"] and r2["lastUuid"] == "m-live-2", r2
    assert browser.evaluate("document.querySelector('#chat details.tool[data-tool-id=toolu_0003] .result-slot').textContent").strip() == "late result"
    recs = wait_log(served, lambda rs: any(x["name"] == "stream:append" for x in rs))
    app = [x for x in recs if x["name"] == "stream:append"]
    assert sum(x["added"] for x in app) == 1 and sum(x["count"] for x in app) == 2  # the paired result added no box
    # the menu's Reload: the reload mark with its cause goes out with the page; the flag persists, the next load says reload
    browser.evaluate("window.__old = true; document.querySelector('#top-menu-btn').click(); document.querySelector('#menu-reload').click(); ''")
    for _ in range(100):
        try:
            if browser.evaluate("!window.__old && " + WAIT_PAINTED):
                break
        except RuntimeError as e:
            if "navigated or closed" not in str(e):
                raise
            time.sleep(0.1)
    recs = wait_log(served, lambda rs: sum(1 for x in rs if x["name"] == "hello") >= 2 and any(x["name"] == "reload" for x in rs))
    rel = next(x for x in recs if x["name"] == "reload")
    assert rel["cause"] == "menu" and rel["load"] == load
    assert any(x["name"] == "pagehide" and x["load"] == load for x in recs)
    hellos = [x for x in recs if x["name"] == "hello"]
    assert len(hellos) == 2 and hellos[1]["nav"]["type"] == "reload" and hellos[1]["load"] != load and hellos[1]["client"] == client
    assert hellos[1]["controlled"] is True  # the worker registered by the first load serves this one
    assert next(x for x in recs if x["name"] == "init" and x["load"] == hellos[1]["load"])["controlled"] is True
    assert browser.evaluate(STATE)["flag"] == "1"
    # the readable form over the socket's GET: one line a record
    with urllib.request.urlopen(f"{served['url']}/api/debug/timing?n=2000", timeout=5) as resp:
        text = resp.read().decode()
    assert text.startswith(TD.header())
    assert re.search(rf"^\d\d:\d\d:\d\d\.\d{{3}} {load} {client} +\+[\d.]+ history:rendered count={N_MSGS + 1} bytes=\d+ ms=\d+$", text, re.M), text[:600]
    assert re.search(rf"^\S+ {load} {client} +\+[\d.]+ reload cause=menu$", text, re.M)
    # ?debug=off clears the flag: nothing loaded, nothing posted from then on
    browser.open(f"{served['url']}/?debug=off#s={NAME}")
    assert browser.evaluate(WAIT_PAINTED)
    assert browser.evaluate(STATE) == {"loaded": False, "flag": None, "script": False, "load": None}
    time.sleep(1.0)  # the previous page's last beacon lands
    n = len(log_records(served))
    browser.send("Page.reload")
    assert browser.evaluate(WAIT_PAINTED)
    time.sleep(1.0)
    assert len(log_records(served)) == n
    assert browser.evaluate("performance.getEntriesByType('mark').length") > 10  # the marks are still made, for nobody


def test_the_header_names_the_zone_of_the_setting_never_a_literal(monkeypatch):
    """The first line says which zone the clock column is in: the SALA_TZ zone's own label (conftest sets Asia/Dubai: +04), another
    zone's label for another zone, and with none set this machine's local zone (TZ), not Asia/Dubai."""
    assert "time +04 |" in TD.header()
    monkeypatch.setenv("SALA_TZ", "Asia/Kolkata")
    assert "time IST |" in TD.header() and "+04" not in TD.header()
    monkeypatch.delenv("SALA_TZ")
    monkeypatch.setenv("TZ", "Etc/UTC")
    assert "time UTC |" in TD.header()
    line = TD.summary(json.dumps({"ts": "2026-10-15T05:05:06.789Z", "load": "a", "client": "b", "name": "x", "t": 1.0}) + "\n").splitlines()[1]
    assert line.endswith("x") and line.startswith("Oct 15 05:05:06"), line   # a past day: date and time in UTC, the zone set
