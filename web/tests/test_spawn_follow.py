"""The New session and Quick session forms follow a queued start to its end.

The form said "not in the list after four minutes; reload this page" for a session that was live: sala's queue runs one operation
at a time, the start had sat four minutes behind retires, and then took 25 s. Held here, with no browser (CI skips the Chromium
tests; the page's own steps are run in node, the server's through a TestClient on a fake operation folder):

- the status of a queued operation says what it waits behind, counted by verb: the running operation and the queued ones older
  than it; a waiting operation (it has handed the queue on), a later one and an ended one are not counted;
- the page keeps asking while the operation is queued or running (past the old four minutes), goes to Ready with the Open link
  when it is done (the name in the list, or 30 s after done), shows the queue's reason when it ended stuck, cancelled or absorbed,
  and only at the 30-minute cap says the start is still queued or running;
- no text of either form advises reloading the page, and "four minutes" is gone.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess

import pytest

from i18n_node import prelude
from sala_web import spawn as SP
from sala_web.app import STATIC
from test_new_session import env, sala  # noqa: F401  (fixtures)

NODE = shutil.which("node")
APP_JS = (STATIC / "app.js").read_text()
SHARED_JS = (STATIC / "shared.js").read_text()
MINE = "1793157728-417928"


def put(state, op_id: str, verb: str, st: str, *args: str, done: bool = False) -> None:
    d = state / "ops" / ("done" if done else "")
    d.mkdir(parents=True, exist_ok=True)
    d.joinpath(f"{op_id}.op").write_text("".join([f"id={op_id}\n", f"verb={verb}\n", f"state={st}\n", *[f"arg={a}\n" for a in args]]))


def status(env, op_id: str = MINE) -> dict:
    r = env["client"].get("/api/spawn/status", params={"op": op_id})
    assert r.status_code == 200, r.text
    return r.json()


# ── the server ───────────────────────────────────────────────────────────────
def test_a_queued_start_says_what_it_waits_behind_counted_by_verb(env):
    s = env["sala"].state
    put(s, "1793157520-1", "retire", "running", "demo-scratch4")
    put(s, "1793157521-2", "retire", "queued", "demo-scratch5")
    put(s, "1793157522-3", "retire", "queued", "demo-side-sedge98")
    put(s, "1793157523-4", "rename", "queued", "a", "b")
    put(s, MINE, "spawn", "queued", "misc-slate", "--project", "projects/misc")
    put(s, "1793157900-5", "retire", "queued", "later-than-mine")        # behind it, not ahead
    put(s, "1793157400-6", "recycle", "waiting", "--now")                 # waiting has handed the queue on
    put(s, "1793157300-7", "retire", "done", "gone", done=True)           # ended
    d = status(env)
    assert d["state"] == "queued"
    assert d["behind_line"] == "Waiting behind 3 retires and 1 rename (running now: retire demo-scratch4)."
    assert [(a["verb"], a["arg"], a["state"]) for a in d["behind"]] == [
        ("retire", "demo-scratch4", "running"), ("retire", "demo-scratch5", "queued"),
        ("retire", "demo-side-sedge98", "queued"), ("rename", "a", "queued")]


def test_one_operation_ahead_is_named_and_nothing_ahead_is_empty(env):
    s = env["sala"].state
    put(s, MINE, "spawn", "queued", "x")
    d = status(env)
    assert d["behind"] == [] and d["behind_line"] == ""
    put(s, "1793157520-1", "retire", "running", "demo-scratch4")
    assert status(env)["behind_line"] == "Waiting behind retire demo-scratch4 (running)."
    put(s, "1793157520-1", "recycle", "queued", "--now", "--words")      # a flag is not a name
    assert status(env)["behind_line"] == "Waiting behind recycle (queued)."


def test_only_a_queued_operation_carries_the_queue(env):
    s = env["sala"].state
    put(s, "1793157520-1", "retire", "running", "a")
    put(s, MINE, "spawn", "running", "x")
    d = status(env)
    assert "behind" not in d and "behind_line" not in d
    put(s, MINE, "spawn", "done", "x", done=True)
    (s / "ops" / f"{MINE}.op").unlink()
    assert "behind_line" not in status(env)


def test_the_queue_order_is_the_epoch_then_the_pid(tmp_path):
    put(tmp_path, "999999999-9", "retire", "queued", "a")                 # a shorter epoch string sorts after as text
    put(tmp_path, "1000000000-10", "retire", "queued", "b")
    put(tmp_path, "1000000000-9", "spawn", "queued", "me")
    assert [a["arg"] for a in SP.queue_ahead(tmp_path, "1000000000-9")] == ["a"]
    assert [a["arg"] for a in SP.queue_ahead(tmp_path, "1000000000-10")] == ["a", "me"]
    assert SP.queue_ahead(tmp_path / "none", MINE) == [] and SP.queue_ahead(tmp_path, "bad") == []


# ── the page's steps, run in node ────────────────────────────────────────────
def poll_step_source() -> str:
    m = re.search(r"async function nsPollStep\(.*?\n}\n(?=async function nsTrack)", APP_JS, re.S)
    assert m, "nsPollStep is not where the test looks for it"
    return m.group(0)


def follow(script: list[dict]) -> list[dict]:
    """Run nsPollStep (app.js) against a fake clock, a fake /api/spawn/status and a fake sessions list. Each script entry:
    {"at": seconds since Start, "op": the status answer, "listed": whether the name is in the list}; the result per entry is the
    form's state, whether it ended, and the lines the form shows."""
    prog = f"""
{prelude()}
{SHARED_JS}
let now = 1000000; Date.now = () => now;
const state = {{ byName: new Set() }};
let answer = {{}};
globalThis.fetch = async () => ({{ ok: true, json: async () => answer }});
const loadSessions = async () => {{}};
{poll_step_source()}
(async () => {{
  const res = {{ op: "1-1", name: "misc-slate", since: now, state: "queued", opState: "", opResult: "" }};
  const out = [];
  for (const step of {json.dumps(script)}) {{
    now = 1000000 + step.at * 1000; answer = step.op;
    if (step.listed) state.byName.add(res.name); else state.byName.delete(res.name);
    const ended = await nsPollStep(res, () => {{}});
    out.push({{ at: step.at, ended, state: res.state, opState: res.opState, result: res.opResult, wait: nsWaitText(res.state === "starting" ? "running" : res.opState, res.behindLine),
               late: res.state === "late" ? nsLateText(res.opState) : null }});
  }}
  console.log(JSON.stringify(out));
}})();
"""
    out = subprocess.run([NODE, "-e", prog], capture_output=True, text=True, check=True, timeout=30).stdout
    return json.loads(out)


needs_node = pytest.mark.skipif(not NODE, reason="node is not installed")
BEHIND = {"state": "queued", "behind_line": "Waiting behind 2 retires (running now: retire a)."}


@needs_node
def test_the_form_keeps_asking_while_queued_past_the_old_four_minutes_and_says_what_it_waits_behind():
    got = follow([{"at": t, "op": BEHIND} for t in (3, 60, 245, 600, 1500)])
    assert [g["ended"] for g in got] == [False] * 5, got           # 245 s was the old give-up (240 s)
    assert all(g["state"] == "queued" and g["wait"] == BEHIND["behind_line"] for g in got), got
    assert "within a few seconds" in follow([{"at": 3, "op": {"state": "queued"}}])[0]["wait"]


@needs_node
def test_a_start_that_runs_after_the_wait_goes_on_to_ready_with_the_session_link():
    got = follow([
        {"at": 3, "op": BEHIND},
        {"at": 245, "op": {"state": "running"}},
        {"at": 250, "op": {"state": "done", "result": "register: ..."}},                       # done, not in the list yet
        {"at": 255, "op": {"state": "done"}, "listed": True},                                   # the list has it
    ])
    assert [(g["state"], g["ended"]) for g in got] == [("queued", False), ("starting", False), ("starting", False), ("ready", True)], got
    assert "sala is starting the session" in got[1]["wait"]
    # done and the list never shows it: Ready 30 s after the look that saw it done
    got = follow([{"at": 100, "op": {"state": "done"}}, {"at": 120, "op": {"state": "done"}}, {"at": 131, "op": {"state": "done"}}])
    assert [(g["state"], g["ended"]) for g in got] == [("starting", False), ("starting", False), ("ready", True)], got


@needs_node
@pytest.mark.parametrize("st", ["stuck", "cancelled", "absorbed"])
def test_an_operation_that_ended_without_a_session_shows_the_queues_reason(st):
    got = follow([{"at": 3, "op": BEHIND}, {"at": 400, "op": {"state": st, "result": "the lane cannot launch: max is signed out"}}])
    assert (got[1]["state"], got[1]["ended"], got[1]["opState"], got[1]["result"]) == ("failed", True, st, "the lane cannot launch: max is signed out"), got


@needs_node
def test_only_the_thirty_minute_cap_gives_up_and_it_says_the_start_is_still_going():
    got = follow([{"at": 1799, "op": {"state": "running"}}, {"at": 1801, "op": {"state": "running"}}])
    assert [(g["state"], g["ended"]) for g in got] == [("starting", False), ("late", True)], got
    assert "still running" in got[1]["late"] and "30 minutes" in got[1]["late"], got
    got = follow([{"at": 1801, "op": BEHIND}])
    assert got[0]["state"] == "late" and "still queued" in got[0]["late"], got
    for text in (got[0]["late"], follow([{"at": 1801, "op": {"state": "running"}}])[0]["late"]):
        assert not re.search(r"reload|missing|not in the (session )?list|four minutes", text, re.I), text


# ── the words ────────────────────────────────────────────────────────────────
def form_text() -> str:
    """The New session and Quick session forms' code and the shared helpers they use, comments left out."""
    a = APP_JS[APP_JS.index("const NS_NAME_RE"):APP_JS.index("function sdStopTrack")]
    b = SHARED_JS[SHARED_JS.index("following a queued session start"):]
    return "\n".join(l for chunk in (a, b) for l in chunk.splitlines() if not l.lstrip().startswith("//"))


def test_no_text_of_the_forms_advises_a_reload_or_gives_up_at_four_minutes():
    t = form_text()
    assert "NS_POLL_MAX_MS" in t and "four minutes" not in t.lower()
    assert not re.search(r"reload", t, re.I), [l for l in t.splitlines() if re.search(r"reload", l, re.I)]
    assert "reload this page" not in APP_JS and "reload this page" not in SHARED_JS
    assert "not in the session list after" not in APP_JS
