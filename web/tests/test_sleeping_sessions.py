"""Sleeping sessions in the page (sleep stage 3): a session sala put to sleep (its claude ended on purpose, its tmux session, pane and
pane-map row stay, a marker file named by its conversation id says `<ISO-Z time> <name>`) shows as "sleeping" everywhere the page lists
sessions, never as a dead or crashed one. Opening it shows its conversation and does not wake it; a message, or its Wake button, does
(web/tests/test_sleeper_transcript.py).

What a wrong answer costs here: a sleeper that looks dead or idle (the owner recycles or retires a session that is only asleep), a sleeper
missing from the sidebar or the Overview (he cannot find the way to wake it), a stale marker listed as a session (a row nobody can open),
a sleeper listed beside the live session of the same conversation (two rows for one session while a wake is in flight), a wake that is
queued for a name that is awake or for a name the page never listed, or a wake asked without the owner's own words (the queue refuses
a plain shell's wake). Held here:

- `read_sleeping_sessions`: a marker plus a pane-map row is a Session (pid 0, status "sleeping", the marker's time); a marker with no
  pane-map row (stale), a bad name, a conversation or name a live session already has, a dotfile, and no marker at all give none;
- the JSON the page reads (`api/sessions`, `api/overview`) carries `sleeping` on a sleeper and on nothing else, the live rows unchanged;
- `POST /api/wake`: queues `sala op wake --only NAME --from sala-web --words "<owner>, via the sala web page: …"` for a sleeper (202 with the
  op id), says `awake` (200, nothing queued) for a name that is not asleep, answers sala's refusal (409), refuses a bad body (400) and
  never runs sala for a name it did not list;
- the page: the sleeping state in the sidebar and the Overview (a hollow dot, the word, the time in the page's zone), and the Wake button asks
  api/wake once and follows the operation (headless Chromium when installed; `sala` is a stand-in script that records its argv).
`sala` here is always a stand-in script in tmp_path; nothing runs the real one."""

from __future__ import annotations

import json
import os
import re
import shutil
import stat
import subprocess
import sys
import time
import urllib.request

import pytest
from starlette.testclient import TestClient

from sala_web import sessions as S
from sala_web import spawn as SP
from sala_web.app import STATIC, create_app
from sala_web.config import Settings
from i18n_node import prelude
from test_board_items_ui import wait_for

SLEEP_UUID = "7e0b1d52-0a6c-4f1e-9d77-5b1c3a2f9e10"
OTHER_UUID = "a1b2c3d4-0000-4000-8000-000000000001"
LIVE_UUID = "c0ffee00-0000-4000-8000-0000000000aa"
SINCE = "2026-11-22T06:10:00Z"             # 15:10 KST; the test zone (conftest: SALA_TZ) is Dubai, +04
OP = "1760600000-4242"
NAME = "demo-sleeper"
ROOT = STATIC.parent.parent.parent         # web/
README = (ROOT / "README.md").read_text()
APP_JS = (STATIC / "app.js").read_text()
NODE = shutil.which("node")

STUB = r'''#!@@PY@@
"""pytest's stand-in for sala (web/tests/test_sleeping_sessions.py): records its argv, answers as the queue does in the mode the test set."""
import json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
try:
    mode = open(os.path.join(HERE, "wake-mode"), encoding="utf-8").read().strip() or "queued"
except OSError:
    mode = "queued"
with open(os.path.join(HERE, "wake-record.jsonl"), "a", encoding="utf-8") as f:
    f.write(json.dumps({"argv": sys.argv[1:]}) + "\n")
if mode == "queued":
    print("queued op @@OP@@: wake demo-sleeper")
elif mode == "awake":
    print("demo-sleeper: not sleeping, nothing to wake")
elif mode == "refused":
    print("refused: the words are not the owner's", file=sys.stderr)
    sys.exit(3)
else:
    print("something else entirely")
'''


class Wake:
    """The stand-in `sala`, the sala state directory (markers, pane map, ops) and helpers to make a sleeper."""

    def __init__(self, tmp_path):
        self.dir = tmp_path / "wakebin"
        self.dir.mkdir()
        self.cmd = self.dir / "sala"
        self.cmd.write_text(STUB.replace("@@PY@@", sys.executable).replace("@@OP@@", OP))
        self.cmd.chmod(self.cmd.stat().st_mode | stat.S_IXUSR)
        self.state = tmp_path / "sala-state"
        (self.state / "sleeping").mkdir(parents=True)
        (self.state / "ops").mkdir()
        self.pane_map = self.state / "pane-map.tsv"
        self.pane_map.write_text("")

    def mode(self, m: str) -> None:
        (self.dir / "wake-mode").write_text(m)

    def sleeper(self, uuid: str = SLEEP_UUID, name: str = NAME, when: str = SINCE, cwd: str = "/w/work-a", mapped: bool = True) -> None:
        (self.state / "sleeping" / uuid).write_text(f"{when} {name}\n")
        if mapped:
            with self.pane_map.open("a", encoding="utf-8") as f:
                f.write(f"{name}\t{uuid}\t{name}\t{cwd}\n")

    def wake_up(self, uuid: str = SLEEP_UUID) -> None:
        (self.state / "sleeping" / uuid).unlink(missing_ok=True)

    def op(self, state: str, result: str = "") -> None:
        (self.state / "ops" / f"{OP}.op").write_text(f"verb=wake\nstate={state}\nresult={result}\nfrom=sala-web\ntime=1760600000\narg=x\n")

    def wakes(self) -> list[list[str]]:
        """The `op wake` calls only: a page also asks sala for its lane names and the like."""
        return [a for a in self.records() if a[:2] == ["op", "wake"]]

    def records(self) -> list[list[str]]:
        p = self.dir / "wake-record.jsonl"
        return [json.loads(l)["argv"] for l in p.read_text(encoding="utf-8").splitlines()] if p.exists() else []


@pytest.fixture
def wake(tmp_path, monkeypatch) -> Wake:
    w = Wake(tmp_path)
    monkeypatch.setenv("SALA_WEB_SALA_CMD", str(w.cmd))
    monkeypatch.setenv("SALA_WEB_SALA_STATE", str(w.state))
    monkeypatch.delenv("SALA_SLEEP_DIR", raising=False)
    monkeypatch.delenv("SALA_SIDECAR", raising=False)
    monkeypatch.setenv("SALA_CONFIG", str(tmp_path / "no-sala-config"))   # a setting in the machine's own config must not move the markers
    return w


def settings_for(tmp_path, wake: Wake, live: list[dict] | None = None) -> Settings:
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True, exist_ok=True)
    (claude / "projects").mkdir(exist_ok=True)
    for d in live or []:
        (claude / "sessions" / f"{d['pid']}.json").write_text(json.dumps(d))
    return Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude, tmux_socket_name="salaweb-pytest-unused",
                    roles_cmd=["false"], sala_cmd=[str(wake.cmd)], sala_state_dir=wake.state)


@pytest.fixture(autouse=True)
def no_tmux_names(monkeypatch):
    monkeypatch.setattr(S, "live_tmux_names", lambda: {})
    monkeypatch.setattr(S, "proc_lane", lambda _pid: "subscription-1")


def live_row(pid: int, name: str, sid: str) -> dict:
    return {"pid": pid, "sessionId": sid, "name": name, "cwd": "/w/live-a", "status": "idle", "tmux": f"{name}:@1.%1",
            "procStart": S.proc_start(pid)}


# ── the reading ────────────────────────────────────────────────────────────────────────────────────────────
def test_a_marker_with_a_pane_map_row_is_a_sleeping_session(tmp_path, wake):
    wake.sleeper()
    out = S.read_sleeping_sessions(settings_for(tmp_path, wake), [])
    assert [(s.pid, s.name, s.status, s.sleeping, s.session_id, s.cwd) for s in out] == \
        [(0, NAME, "sleeping", SINCE, SLEEP_UUID, "/w/work-a")]
    j = out[0].to_json()
    assert j["sleeping"] == SINCE and j["status"] == "sleeping" and j["pid"] == 0


def test_what_is_not_a_session_is_not_listed(tmp_path, wake):
    wake.sleeper(uuid=OTHER_UUID, name="stale-one", mapped=False)               # a marker whose pane is gone
    wake.sleeper(uuid="b" * 8 + "-0000-4000-8000-000000000002", name="Bad Name!")   # a name the page never takes
    (wake.state / "sleeping" / ".tmp-write").write_text(f"{SINCE} dotfile\n")   # sala's half-written file
    (wake.state / "sleeping" / "empty-name").write_text(f"{SINCE}\n")
    assert S.read_sleeping_sessions(settings_for(tmp_path, wake), []) == []


def test_a_conversation_or_a_name_a_live_session_has_is_not_listed_twice(tmp_path, wake):
    wake.sleeper()                                    # asleep: SLEEP_UUID, NAME
    wake.sleeper(uuid=OTHER_UUID, name="demo-other")
    live = [live_row(os.getpid(), NAME, "11111111-0000-4000-8000-000000000003")]            # a wake in flight: the same name, live
    s = settings_for(tmp_path, wake, live)
    names = [x.name for x in S.read_sleeping_sessions(s, S.read_live_sessions(s))]
    assert names == ["demo-other"]
    live = [live_row(os.getpid(), "renamed-live", SLEEP_UUID)]                              # the same conversation, live under another name
    s = settings_for(tmp_path, wake, live)
    names = [x.name for x in S.read_sleeping_sessions(s, S.read_live_sessions(s))]
    assert names == ["demo-other"]


def test_no_marker_directory_lists_nothing(tmp_path, wake):
    (wake.state / "sleeping").rmdir()
    assert S.read_sleeping_sessions(settings_for(tmp_path, wake), []) == []


# ── the JSON the page reads ─────────────────────────────────────────────────────────────────────────────────
def test_api_sessions_and_overview_list_a_sleeper_and_leave_a_live_row_alone(tmp_path, wake):
    wake.sleeper()
    s = settings_for(tmp_path, wake, [live_row(os.getpid(), "demo-live", LIVE_UUID)])
    c = TestClient(create_app(s))
    rows = {r["name"]: r for sc in c.get("/api/sessions").json()["scopes"] for g in sc["groups"] for r in g["sessions"]}
    assert set(rows) == {NAME, "demo-live"}
    assert rows[NAME]["sleeping"] == SINCE and rows[NAME]["status"] == "sleeping" and rows[NAME]["pid"] == 0
    assert "sleeping" not in rows["demo-live"] and rows["demo-live"]["status"] == "idle"
    ov = {r["name"]: r for r in c.get("/api/overview").json()["sessions"]}
    assert ov[NAME]["sleeping"] == SINCE and ov[NAME]["status"] == "sleeping"
    assert "sleeping" not in ov["demo-live"]


def test_a_sleeper_has_no_process_to_open_read_or_send_to(tmp_path, wake):
    wake.sleeper()
    c = TestClient(create_app(settings_for(tmp_path, wake)))
    assert c.get("/api/s/0/transcript").status_code == 404
    assert c.post("/api/s/0/send", json={"text": "hi"}).status_code == 404


# ── POST /api/wake ──────────────────────────────────────────────────────────────────────────────────────────
WORDS_RE = re.compile(r"^Rowan, via the sala web page: opened the sleeping session demo-sleeper, "
                      r"\d\d:\d\d (Mon|Tue|Wed|Thu|Fri|Sat|Sun) [A-Z][a-z]{2} \d{1,2}(st|nd|rd|th) \+04$")


def test_wake_queues_the_verb_with_the_owners_words(tmp_path, wake):
    wake.sleeper()
    r = TestClient(create_app(settings_for(tmp_path, wake))).post("/api/wake", json={"name": NAME})
    assert r.status_code == 202, r.text
    assert r.json()["ok"] is True and r.json()["op"] == OP and r.json()["name"] == NAME
    (argv,) = wake.records()
    assert argv[:6] == ["op", "wake", "--only", NAME, "--from", "sala-web"] and argv[6] == "--words" and len(argv) == 8
    assert WORDS_RE.match(argv[7]), argv[7]


def test_wake_of_a_name_that_is_not_asleep_queues_nothing(tmp_path, wake):
    wake.sleeper()
    c = TestClient(create_app(settings_for(tmp_path, wake, [live_row(os.getpid(), "demo-live", LIVE_UUID)])))
    for name in ("demo-live", "no-such-session"):
        r = c.post("/api/wake", json={"name": name})
        assert r.status_code == 200 and r.json() == {"ok": True, "code": "awake", "name": name}
    assert wake.records() == []                       # sala was never run


def test_wake_says_awake_when_sala_says_not_sleeping(tmp_path, wake):
    wake.sleeper()
    wake.mode("awake")                                # it woke between the page's list and the click
    r = TestClient(create_app(settings_for(tmp_path, wake))).post("/api/wake", json={"name": NAME})
    assert r.status_code == 200 and r.json()["code"] == "awake"


def test_wake_passes_on_a_refusal_and_an_odd_answer(tmp_path, wake):
    wake.sleeper()
    c = TestClient(create_app(settings_for(tmp_path, wake)))
    wake.mode("refused")
    r = c.post("/api/wake", json={"name": NAME})
    assert r.status_code == 409 and r.json()["ok"] is False and "words are not the owner's" in r.json()["error"]
    wake.mode("odd")
    r = c.post("/api/wake", json={"name": NAME})
    assert r.status_code == 502 and r.json()["ok"] is False


@pytest.mark.parametrize("body", [{}, {"name": 7}, {"name": ""}, {"name": "-rf"}, {"name": "a b"}, ["demo"]])
def test_wake_refuses_a_body_that_is_no_session_name(tmp_path, wake, body):
    wake.sleeper()
    r = TestClient(create_app(settings_for(tmp_path, wake))).post("/api/wake", json=body)
    assert r.status_code == 400
    assert wake.records() == []


def test_wake_argv_and_words_shape():
    assert SP.wake_argv(["sala"], "n", "w") == ["sala", "op", "wake", "--only", "n", "--from", "sala-web", "--words", "w"]
    assert SP.parse_wake(0, f"queued op {OP}: wake x\n", "", "x")[0] == 202
    assert SP.parse_wake(0, "x: not sleeping, nothing to wake\n", "", "x") == (200, {"ok": True, "code": "awake", "name": "x"})
    assert SP.parse_wake(4, "", "no\n", "x")[0] == 409


# ── the page's own text ─────────────────────────────────────────────────────────────────────────────────────
def test_the_readme_and_the_app_name_the_wake_route():
    assert "POST /api/wake" in README
    assert 'Route("/api/wake"' in (STATIC.parent / "app.py").read_text()
    assert 'nsPost("api/wake"' in APP_JS
    assert "sleeping" in README


@pytest.mark.skipif(not NODE, reason="node is not installed")
def test_the_sleep_time_is_written_in_the_pages_zone_never_utc():
    """static/shared.js `sleptAt`: the marker's ISO-Z time in the zone api/config told (KST, say), the zone's label after it, and "" for a word that is no time."""
    shared = (STATIC / "shared.js").read_text()
    zone_js = shared[shared.index("const zone = {"):shared.index('// "5 min ago" for a time t (epoch ms)')]
    body = """
const out = {};
applyZone({ timezone: "Asia/Seoul", tzLabel: "KST", tzOffsetMin: 540 });
out.kst = sleptAt("2026-11-22T06:10:00Z");
applyZone({ timezone: "Asia/Dubai", tzLabel: "+04", tzOffsetMin: 240 });
out.dubai = sleptAt("2026-11-22T06:10:00Z");
out.bad = sleptAt("not a time");
out.empty = sleptAt("");
console.log(JSON.stringify(out));
"""
    script = prelude("en") + "\n" + zone_js + "\n" + body
    env = {"PATH": "/usr/bin:/bin:/usr/local/bin", "TZ": "America/Los_Angeles"}
    out = json.loads(subprocess.run([NODE, "-e", script], capture_output=True, text=True, check=True, timeout=30, env=env).stdout)
    assert "15:10" in out["kst"] and out["kst"].endswith("KST") and "Sun" in out["kst"] and "Nov 22" in out["kst"], out
    assert "10:10" in out["dubai"] and out["dubai"].endswith("+04"), out
    assert out["bad"] == "" and out["empty"] == ""


# ── the browser ─────────────────────────────────────────────────────────────────────────────────────────────
@pytest.fixture
def slept(wake, served):
    """The served app, with one sleeper beside its live fake session; the sleeper is made after the app starts (the lists are read per request)."""
    wake.sleeper()
    return served


def open_page(browser, served, hash_: str = "") -> None:
    browser.send("Page.enable")
    browser.send("Emulation.setDeviceMetricsOverride", {"width": 1100, "height": 800, "deviceScaleFactor": 1, "mobile": False})
    browser.send("Page.navigate", {"url": served["url"] + "/" + hash_})
    assert wait_for(browser, "document.readyState === 'complete' && typeof loadSessions === 'function' && !!document.querySelector('#session-list .sess')")


SIDEBAR_ROW = ("(() => { const r = [...document.querySelectorAll('#session-list .sess')].find(e => e.querySelector('.label').textContent === %s);"
               " return r ? { dot: r.querySelector('.dot').className, tag: (r.querySelector('.slp') || {}).textContent || '', title: r.title } : null; })()")


@pytest.fixture
def slept_shown(slept):
    """The same, with the side panel's "Show sleeping sessions" box checked (it is off by default, and then the list leaves a sleeper out: test_hide_sleeping.py)."""
    req = urllib.request.Request(slept["url"] + "/api/prefs", data=json.dumps({"showSleeping": True}).encode(), method="PUT",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        assert r.status == 200
    return slept


def test_the_sidebar_marks_a_sleeper_sleeping_and_a_live_session_not(slept_shown, browser):
    slept = slept_shown
    open_page(browser, slept)
    assert wait_for(browser, SIDEBAR_ROW % json.dumps(NAME) + " !== null")
    row = browser.evaluate(SIDEBAR_ROW % json.dumps(NAME))
    assert "sleeping" in row["dot"].split() and row["tag"] == "sleeping"
    assert re.search(r"asleep since .*\+04", row["title"]), row["title"]             # the page's zone (Dubai in the tests), never UTC or the box's
    assert "10:10" in row["title"]                                                   # 06:10Z is 10:10 at +04
    live = browser.evaluate(SIDEBAR_ROW % json.dumps(slept["name"]))
    assert "sleeping" not in live["dot"].split() and live["tag"] == ""


def test_the_overview_row_says_sleeping_and_no_time(slept, browser):
    """The Agents row says only "sleeping" (the time it went to sleep is in the sleeper's own band, and a longer status would widen the table: web/tests/test_table_width.py)."""
    open_page(browser, slept, "#sessions")
    assert wait_for(browser, "[...document.querySelectorAll('#sp-table tr')].some(r => /sleeping/.test(r.textContent))", 15.0)
    cells = browser.evaluate("[...document.querySelectorAll('#sp-table tr')].find(r => /sleeping/.test(r.textContent)).children.length && "
                             "[...[...document.querySelectorAll('#sp-table tr')].find(r => /sleeping/.test(r.textContent)).children].map(c => c.textContent.trim())")
    assert cells[0] == NAME and cells[3] == "sleeping", cells                      # the status cell is the one word
    assert "since" not in "".join(cells) and "10:10" not in "".join(cells), cells
    assert "version unknown" not in "".join(cells), cells


def test_opening_a_sleeper_asks_nothing_and_its_wake_button_asks_once_and_follows_it(slept_shown, wake, browser):
    slept = slept_shown
    wake.mode("queued")
    wake.op("queued")
    open_page(browser, slept)
    assert wait_for(browser, SIDEBAR_ROW % json.dumps(NAME) + " !== null")
    browser.evaluate("selectSession(%s, { force: true })" % json.dumps(NAME))
    assert wait_for(browser, "document.querySelector('#sleep-band .wake-btn') !== null", 15.0)
    time.sleep(2.5)                                                                   # more than one poll of the list
    assert wake.wakes() == []                                                       # opening it woke nothing
    browser.evaluate("document.querySelector('#sleep-band .wake-btn').click()")
    assert wait_for(browser, "/queued|Waking/.test(document.querySelector('#sleep-band').textContent)", 15.0)
    end = time.time() + 15                                                            # the line says "Waking" before the POST is answered
    while not wake.wakes() and time.time() < end:
        time.sleep(0.1)
    assert [a[:4] for a in wake.wakes()] == [["op", "wake", "--only", NAME]]         # asked once, however many polls
    time.sleep(2.5)                                                                   # more than one poll of the list and of the operation
    assert len(wake.wakes()) == 1
    # a wake that fails shows its words and a button to try again
    wake.op("stuck", "pane gone")
    assert wait_for(browser, "document.querySelector('#sleep-band .wake-btn') !== null && document.querySelector('#sleep-band').classList.contains('failed')", 20.0)
    assert "pane gone" in browser.evaluate("document.querySelector('#sleep-band').textContent")
    # the session is awake: its marker is gone, the next list drops the sleeping entry and the page stops following
    wake.wake_up()
    browser.evaluate("loadSessions()")
    assert wait_for(browser, "!waking.has(%s)" % json.dumps(NAME), 20.0)


def test_a_queued_wake_draws_no_stray_text_in_the_sleep_band(slept_shown, browser):
    """While a wake is queued or waking, the band has no Wake button, and the button's empty slot must not print the text "null"."""
    slept = slept_shown
    open_page(browser, slept)
    assert wait_for(browser, SIDEBAR_ROW % json.dumps(NAME) + " !== null")
    browser.evaluate("selectSession(%s, { force: true })" % json.dumps(NAME))
    assert wait_for(browser, "document.querySelector('#sleep-band .wake-btn') !== null", 15.0)
    out = browser.evaluate(
        "(() => { waking.set(%s, { state: 'queued', op: '', error: '', since: Date.now() });"
        " paintSleeping(state.byName.get(%s));"
        " const band = document.querySelector('#sleep-band');"
        " return { text: band.textContent, stray: [...band.childNodes].filter(n => n.nodeType === 3 && n.textContent.trim() !== '').map(n => n.textContent),"
        " button: band.querySelectorAll('.wake-btn').length, line: band.querySelector('.wake-line') ? band.querySelector('.wake-line').textContent : null }; })()"
        % (json.dumps(NAME), json.dumps(NAME)))
    assert "null" not in out["text"], out
    assert out["stray"] == [], out
    assert out["button"] == 0, out
    assert out["line"], out
