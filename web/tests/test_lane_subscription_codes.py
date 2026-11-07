"""The account lanes' codes became subscription-1 (was max) and subscription-2 (was team); sala's side of the rename is its own tests. What
this app stores and sends uses the new codes, and the old words stay as aliases on every read, as awsplatform did for aws-platform
(test_lane_rename.py): sala's files written before the change (lane-state.tsv, lanes.tsv, lane-default, sessions.json, spend-lanes.json),
a saved link, a saved lane order, a form loaded before (the spawn payload), a schedule's X-Model-Lane and a saved quota-max.json all
read as the new code, and nothing stored is rewritten.

A lane's display name ("Ultra", "Team") is sala's, not this app's: `sala lane names --json`, else lane-names.json in sala's state
directory, else the code itself (lanenames.py, GET /api/lane-names, `laneLabel` in static/shared.js). No display name is written under
web/src; the tests below feed the names in through a stand-in sala or a file.

What a wrong answer costs: a dormant lane that reads as active because its record is keyed by the old word, a saved quota (and the wait it
carries) stranded under the old file name so the usage endpoint is asked again at once, a spawn from an old form refused as "lane must be
one of", a pill with no colour, a card that says "undefined" before the names arrive, or a display name baked into the page, which would
make the next rename a second code change. Nothing here runs the real sala or Anthropic: the sala command is a script in tmp_path, the
usage fetch a lambda; every folder is pytest's tmp_path, removed by pytest.
"""

from __future__ import annotations

import asyncio
import json
import re
import shutil
import subprocess
import sys
import time

import pytest
from starlette.testclient import TestClient

from sala_web import lanenames as LNM
from sala_web import lanes as LN
from sala_web import lanestate as LS
from sala_web import quota as Q
from sala_web import schedules as SCH
from sala_web import sessions as S
from sala_web import spawn as SP
from sala_web import spend as SPD
from sala_web.app import STATIC, create_app
from sala_web.config import Settings

OLD1, OLD2, NEW1, NEW2 = "max", "team", "subscription-1", "subscription-2"
NAMES = {"lanes": [
    {"code": NEW1, "display": "Ultra", "aliases": [OLD1]},
    {"code": NEW2, "display": "Team", "aliases": [OLD2]},
    {"code": "api", "display": "API", "aliases": []},
    {"code": "bedrock", "display": "Bedrock", "aliases": []},
    {"code": "aws-platform", "display": "Claude Platform on AWS", "aliases": ["awsplatform"]},
]}


def static(name: str) -> str:
    return (STATIC / name).read_text(encoding="utf-8")


# ── the words ────────────────────────────────────────────────────────────────
def test_the_old_words_read_as_the_new_codes_and_nothing_else_moves():
    assert LS.RENAMED == {"awsplatform": "aws-platform", OLD1: NEW1, OLD2: NEW2}
    assert LS.ALIASES == {"sdk": "api", **LS.RENAMED}
    for old, new in ((OLD1, NEW1), (OLD2, NEW2), ("awsplatform", "aws-platform"), (NEW1, NEW1), ("api", "api"), ("bedrock", "bedrock")):
        assert LS.norm(old) == new and LS.renamed(old) == new, old
    assert LS.norm("sdk") == "api" and LS.renamed("sdk") == "sdk"      # sdk stays its own word where the two lanes are told apart
    assert LS.norm(None) is None and LS.renamed(5) == 5


def test_the_dormant_record_keyed_by_an_old_word_is_the_new_lane_s(tmp_path):
    p = tmp_path / "lane-state.tsv"
    p.write_text(f"{OLD1}\tdormant\tlimit\t2026-01-05T03:00:00Z\t\thand\n{OLD2}\tdormant\tseat gone\t2026-01-06T03:00:00Z\t\tsignal\n")
    d = LS.dormant(p)
    assert d == {NEW1: {"reason": "limit", "since": "2026-01-05T03:00:00Z"}, NEW2: {"reason": "seat gone", "since": "2026-01-06T03:00:00Z"}}, d
    p.write_text(f"{NEW2}\tdormant\tseat gone\t2026-01-06T03:00:00Z\t\tsignal\n")
    assert set(LS.dormant(p)) == {NEW2}


# ── what spend reads of sala's files ─────────────────────────────────────────
def test_spend_counts_the_old_words_in_sala_s_files_as_the_new_lanes(tmp_path):
    assert SPD.canonical(OLD1) == NEW1 and SPD.canonical(OLD2) == NEW2 and SPD.canonical("sdk") == "api"
    sala = tmp_path / "sala"
    sala.mkdir()
    (sala / "lanes.tsv").write_text(f"pane\t{OLD2}\n")
    (sala / "sessions.json").write_text(json.dumps({"schema": 1, "sessions": {
        "a1": {"id": "a1", "name": "pane", "lane": None, "aliases": [], "state": "live", "transcripts": [{"id": "a1"}]},
        "b2": {"id": "b2", "name": "reg", "lane": OLD1, "aliases": [], "state": "live", "transcripts": [{"id": "b2"}]}}}))
    (sala / "lane-default").write_text(OLD1 + "\n")
    f = SPD.Facts(sala, [], {})
    assert f.current("a1") == NEW2, "lanes.tsv says team"
    assert f.current("b2") == NEW1, "the registry says max"
    assert f.current("nobody") == NEW1 and f.default_at(0) == NEW1, "lane-default says max"
    (sala / "lane-default").unlink()
    assert SPD.Facts(sala, [], {}).default_at(0) == NEW1, "no lane-default: the first lane, by its new code"


# ── what a client sends ──────────────────────────────────────────────────────
GOOD = {"project": "projects/example", "role": "front", "name": "x-main"}


def test_a_spawn_payload_with_an_old_word_is_the_new_lane_and_the_error_lists_the_new_codes():
    lanes = [NEW1, NEW2, "api", "bedrock", "aws-platform"]
    for old, new in ((OLD1, NEW1), (OLD2, NEW2), (NEW1, NEW1), (NEW2, NEW2)):
        r = SP.validate({**GOOD, "lane": old}, ["projects", "infra"], lanes)
        assert not isinstance(r, tuple) and r.lane == new, (old, r)
    r = SP.validate({**GOOD, "lane": "sdk"}, ["projects", "infra"], lanes)
    assert isinstance(r, tuple) and r[0] == 400, r      # sdk is still not a spawn lane
    r = SP.validate({**GOOD, "lane": "nope"}, ["projects", "infra"], lanes)
    assert r == (400, f"lane must be one of {NEW1}, {NEW2}, api, bedrock, aws-platform"), r


def test_the_spawn_lanes_are_the_new_codes():
    assert S.SPAWN_LANES[:2] == (NEW1, NEW2) and set(S.SPAWN_LANES) == {NEW1, NEW2, "api", "bedrock", "aws-platform"}
    assert set(S.LANE_DIRS) == {NEW2}


def test_sala_s_default_and_its_lane_table_answer_to_both_words():
    assert LN.default_of(json.dumps({"default": OLD1})) == NEW1 and LN.default_of(json.dumps({"default": NEW2})) == NEW2
    rows = LN.parse_table(json.dumps({"default": OLD1, "lanes": [
        {"id": NEW1, "label": "x", "status": "active"}, {"id": OLD2, "label": "y", "status": "inactive"}]}))
    a, b = LN.record_of(rows, OLD1), LN.record_of(rows, NEW1)
    assert a is not None and a == b and a["id"] == NEW1
    assert LN.record_of(rows, NEW2)["id"] == NEW2 and LN.record_of(rows, OLD2) == LN.record_of(rows, NEW2)    # the table's own id read the old way too


# ── schedules ────────────────────────────────────────────────────────────────
@pytest.mark.parametrize("word,want", [(OLD1, NEW1), (OLD2, NEW2), (NEW1, NEW1), (NEW2, NEW2), ("Max", NEW1), ("bedrock", "bedrock"),
                                       ("sdk", "sdk"), ("none", "none")])
def test_x_model_lane_takes_both_words(word, want):
    text = f"[Unit]\nDescription=x\n# which model lane this job bills to\nX-Model-Lane={word}\n\n[Service]\nType=oneshot\n"
    assert SCH.model_lane(text) == want
    assert set(SCH.LANES) >= {NEW1, NEW2} and not {OLD1, OLD2} & set(SCH.LANES)     # the checked list is the new codes only
    assert SCH.model_lane("[Unit]\nDescription=x\n") is None


# ── the quota cache ──────────────────────────────────────────────────────────
def saved(lane: str, **kw) -> dict:
    return {"lane": lane, "limits": [{"label": "Current session", "percent": 12, "severity": "normal", "resetsAt": None}],
            "plan": "Max (20x)", "fetchedAt": int(time.time() * 1000), **kw}


def test_a_quota_saved_under_the_old_name_is_read_and_the_new_file_is_what_is_written(tmp_path):
    (tmp_path / f"quota-{OLD1}.json").write_text(json.dumps(saved(OLD1)))
    (tmp_path / f"quota-{OLD2}.json").write_text(json.dumps(saved(OLD2, plan="Team")))
    asked = []

    def fetch(token):
        asked.append(token)
        return {"limits": []}

    async def run():
        c = Q.QuotaCache({NEW1: tmp_path / "c1", NEW2: tmp_path / "c2"}, fetch=fetch, state_dir=tmp_path)
        return await c.get()

    got = {x["lane"]: x for x in asyncio.run(run())}
    assert set(got) == {NEW1, NEW2}, "the answers say the new codes, never the old words"
    assert got[NEW1]["limits"][0]["percent"] == 12 and not got[NEW1].get("pending") and got[NEW1]["plan"] == "Max (20x)", got
    assert got[NEW2]["plan"] == "Team" and not got[NEW2].get("pending")
    assert asked == [], "a saved answer that is not due yet is served, and nothing is asked"
    assert (tmp_path / f"quota-{OLD1}.json").exists() and (tmp_path / f"quota-{OLD2}.json").exists(), "the old files are left as they are"


def test_a_failed_check_writes_the_new_file_name_and_the_new_file_wins_over_the_old(tmp_path):
    (tmp_path / f"quota-{OLD1}.json").write_text(json.dumps(saved(OLD1, plan="old file")))
    (tmp_path / f"quota-{NEW1}.json").write_text(json.dumps(saved(NEW1, plan="new file")))
    got = asyncio.run(Q.QuotaCache({NEW1: tmp_path / "c1"}, state_dir=tmp_path).get())
    assert got[0]["plan"] == "new file" and got[0]["lane"] == NEW1
    assert json.loads((tmp_path / f"quota-{OLD1}.json").read_text())["plan"] == "old file"


def test_the_saved_wait_in_an_old_file_is_kept(tmp_path):
    nxt = int((time.time() + 900) * 1000)
    (tmp_path / f"quota-{OLD2}.json").write_text(json.dumps(saved(OLD2, errorKind="rate_limited", nextTry=nxt, fetchedAt=int((time.time() - 3600) * 1000))))
    asked = []
    c = Q.QuotaCache({NEW2: tmp_path / "c2"}, fetch=lambda t: asked.append(t) or {"limits": []}, state_dir=tmp_path)
    got = asyncio.run(c.get())[0]
    assert got["errorKind"] == "rate_limited" and got["nextTry"] == nxt and got["lane"] == NEW2 and asked == []


def test_a_quota_file_for_another_lane_is_not_taken(tmp_path):
    (tmp_path / f"quota-{OLD1}.json").write_text(json.dumps(saved(OLD2)))      # a file under max's name that says team inside
    got = asyncio.run(Q.QuotaCache({NEW1: tmp_path / "c1"}, fetch=lambda t: {"limits": []}, state_dir=tmp_path).get())[0]
    assert got.get("pending") is True and got["lane"] == NEW1


# ── the names table ──────────────────────────────────────────────────────────
def test_parse_keeps_good_rows_and_the_label_answers_for_aliases():
    rows = LNM.parse("a notice before\n" + json.dumps(NAMES))
    assert [r["code"] for r in rows] == [NEW1, NEW2, "api", "bedrock", "aws-platform"]
    assert LNM.label(rows, NEW1) == "Ultra" and LNM.label(rows, OLD1) == "Ultra" and LNM.label(rows, OLD2) == "Team"
    assert LNM.label(rows, "awsplatform") == "Claude Platform on AWS" and LNM.label(rows, "nope") == "nope"
    bad = json.dumps({"lanes": [{"code": "Bad Code!", "display": "x"}, {"code": NEW1, "display": "  \x01 "}, {"code": NEW1, "display": "dup"},
                                {"code": "api", "display": "A" * 100, "aliases": ["ok", "NOT OK", 3]}, 7]})
    got = LNM.parse(bad)
    assert [r["code"] for r in got] == [NEW1, "api"] and got[0]["display"] == NEW1, "an empty name is the code; a repeated code is dropped"
    assert len(got[1]["display"]) == LNM.DISPLAY_MAX and got[1]["aliases"] == ["ok"]
    for junk in ("", "no json", "[]", '{"lanes": 3}', '{"lanes": []}', '{"lanes": [1, "x"]}'):
        assert LNM.parse(junk) is None, junk


def test_without_any_names_the_table_is_the_codes_themselves():
    rows = LNM.codes_only()
    assert {r["code"] for r in rows} == {NEW1, NEW2, "aws-platform", "api", "bedrock"}
    assert all(r["display"] == r["code"] for r in rows)
    assert LNM.label(rows, OLD1) == NEW1


def test_the_table_comes_from_the_command_then_the_file_then_what_it_had_then_the_codes(tmp_path):
    out = {"v": json.dumps(NAMES)}
    calls = []

    async def run():
        calls.append(1)
        return out["v"]

    async def scenario():
        t = LNM.LaneNames(run, tmp_path, ttl=0.0)
        assert (await t.get())["lanes"][0]["display"] == "Ultra"
        out["v"] = None                                              # the command stops answering: no file, so the table it had
        assert (await t.get())["lanes"][0]["display"] == "Ultra"
        (tmp_path / LNM.FILE).write_text(json.dumps({"lanes": [{"code": NEW1, "display": "From file"}]}))
        none = LNM.LaneNames(lambda: asyncio.sleep(0, result=None), tmp_path, ttl=0.0)
        assert (await none.get())["lanes"][0]["display"] == "From file"      # the file, when the command does not answer
        fresh = LNM.LaneNames(lambda: asyncio.sleep(0, result=None), tmp_path / "empty", ttl=0.0)
        assert all(r["display"] == r["code"] for r in (await fresh.get())["lanes"])
        slow = LNM.LaneNames(run, tmp_path, ttl=3600.0)
        out["v"] = json.dumps(NAMES)
        n = len(calls)
        await slow.get()
        await slow.get()
        assert len(calls) == n + 1, "an answer is kept for its ttl: one command, not two"

    asyncio.run(scenario())


def settings_with(tmp_path, sala_cmd=None, **kw):
    return Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=tmp_path / "claude",
                    tmux_socket_name="salaweb-pytest-none", roles_cmd=["false"], sala_models=tmp_path / "none.tsv",
                    sala_state_dir=tmp_path / "sala-state", **({"sala_cmd": sala_cmd} if sala_cmd else {}), **kw)


STUB = '''#!{py}
import sys
if sys.argv[1:] == ["lane", "names", "--json"]:
    print({text!r})
    sys.exit(0)
sys.stderr.write("stub: unexpected call\\n")
sys.exit(2)
'''


def test_the_endpoint_serves_sala_s_names(tmp_path, monkeypatch):
    stub = tmp_path / "sala-stub"
    stub.write_text(STUB.format(py=sys.executable, text=json.dumps(NAMES)), encoding="utf-8")
    stub.chmod(0o755)
    monkeypatch.setenv("SALA_WEB_SALA_CMD", str(stub))
    (tmp_path / "claude" / "sessions").mkdir(parents=True)
    monkeypatch.setattr(S, "live_tmux_names", lambda: {})
    with TestClient(create_app(settings_with(tmp_path))) as c:
        r = c.get("/api/lane-names")
    assert r.status_code == 200 and r.json() == {"lanes": LNM.parse(json.dumps(NAMES))}, r.text
    assert {x["code"]: x["display"] for x in r.json()["lanes"]}[NEW1] == "Ultra"


def test_the_endpoint_falls_back_to_the_file_and_then_to_the_codes_when_sala_is_missing(tmp_path, monkeypatch):
    monkeypatch.setenv("SALA_WEB_SALA_CMD", str(tmp_path / "no-such-sala"))
    (tmp_path / "claude" / "sessions").mkdir(parents=True)
    monkeypatch.setattr(S, "live_tmux_names", lambda: {})
    with TestClient(create_app(settings_with(tmp_path))) as c:
        r = c.get("/api/lane-names")
        assert r.status_code == 200, r.text
        assert all(x["display"] == x["code"] for x in r.json()["lanes"]) and NEW1 in {x["code"] for x in r.json()["lanes"]}, r.text
    (tmp_path / "sala-state").mkdir()
    (tmp_path / "sala-state" / LNM.FILE).write_text(json.dumps(NAMES))
    with TestClient(create_app(settings_with(tmp_path))) as c:
        got = {x["code"]: x["display"] for x in c.get("/api/lane-names").json()["lanes"]}
    assert got[NEW1] == "Ultra" and got[NEW2] == "Team", got


def test_the_lane_route_answers_the_old_word_as_the_new_lane(tmp_path, monkeypatch):
    # GET /api/lanes/<id> asks sala's lane table; with none, the lane word still reads as the new code in what it says of the state
    monkeypatch.setenv("SALA_WEB_SALA_CMD", str(tmp_path / "no-such-sala"))
    (tmp_path / "claude" / "sessions").mkdir(parents=True)
    (tmp_path / "sala-state").mkdir()
    (tmp_path / "sala-state" / "lane-state.tsv").write_text(f"{OLD2}\tdormant\tseat gone\t2026-01-06T03:00:00Z\t\tsignal\n")
    monkeypatch.setattr(S, "live_tmux_names", lambda: {})
    with TestClient(create_app(settings_with(tmp_path))) as c:
        old, new = c.get(f"/api/lanes/{OLD2}"), c.get(f"/api/lanes/{NEW2}")
    assert old.status_code == 200 and new.status_code == 200
    assert old.json()["lane"] == NEW2 == new.json()["lane"] and old.json()["state"] == new.json()["state"]
    assert new.json()["state"]["state"] == "dormant" and new.json()["state"]["reason"] == "seat gone"


# ── the page ─────────────────────────────────────────────────────────────────
NODE = r"""
const fs = require('fs');
const src = fs.readFileSync(process.argv[1], 'utf8');
const m = /\/\/ <lane-words>[^\n]*\n([\s\S]*?)\/\/ <\/lane-words>/.exec(src);
const out = (function () {
  eval(m[1] + '; globalThis.__t = { laneNorm, laneLabel, laneLabelOr, applyLaneNames, laneNames, LANE_LABEL };');
  const t = globalThis.__t;
  const r = {};
  r.norm = [t.laneNorm('max'), t.laneNorm('team'), t.laneNorm('awsplatform'), t.laneNorm('subscription-1'), t.laneNorm('api'),
            t.laneNorm('sdk'), t.laneNorm(undefined), t.laneNorm(null), t.laneNorm('constructor'), t.laneNorm('toString')];
  r.before = [t.laneLabel('subscription-1'), t.laneLabel('max'), t.laneLabel('api'), t.laneLabel('sdk'), t.laneLabel('bedrock'),
              t.laneLabel('aws-platform'), t.laneLabel('awsplatform'), t.laneLabel('whatever'), t.laneLabel(undefined)];
  r.changed1 = t.applyLaneNames(JSON.parse(process.argv[2]));
  r.changed2 = t.applyLaneNames(JSON.parse(process.argv[2]));
  r.junk = [t.applyLaneNames(null), t.applyLaneNames({}), t.applyLaneNames({ lanes: 3 }), t.applyLaneNames({ lanes: [null, 1, { code: 3 }, { code: 'x', display: '' }] })];
  r.after = [t.laneLabel('subscription-1'), t.laneLabel('max'), t.laneLabel('subscription-2'), t.laneLabel('team'), t.laneLabel('api'),
             t.laneLabel('sdk'), t.laneLabel('bedrock'), t.laneLabel('aws-platform'), t.laneLabel('awsplatform'), t.laneLabel('constructor')];
  r.or = [t.laneLabelOr('bedrock', 'other'), t.laneLabelOr('nope', 'other'), t.laneLabelOr('team', 'other')];
  return r;
})();
console.log(JSON.stringify(out));
"""


def node_run():
    node = shutil.which("node")
    if not node:
        pytest.skip("no node")
    return json.loads(subprocess.run([node, "-e", NODE, str(STATIC / "shared.js"), json.dumps(NAMES)], capture_output=True, text=True,
                                     check=True, timeout=30).stdout)


def test_laneNorm_and_laneLabel_in_node():
    r = node_run()
    assert r["norm"] == [NEW1, NEW2, "aws-platform", NEW1, "api", "sdk", None, None, "constructor", "toString"], r["norm"]
    # before the names arrive a lane says the word it is stored as (never a baked-in name), the overrides still hold
    assert r["before"][:8] == [NEW1, NEW1, "metered", "sdk", "bedrock", "aws-platform", "aws-platform", "whatever"], r["before"]
    assert r["changed1"] is True and r["changed2"] is False, "a second identical table changes nothing, so nothing redraws"
    assert r["junk"] == [False, False, False, False]
    # with the names: sala's display, lower case, for the code and for its old word; the overrides keep api, sdk, aws-platform, bedrock
    assert r["after"] == ["ultra", "ultra", "team", "team", "metered", "sdk", "bedrock", "aws-platform", "aws-platform", "constructor"], r["after"]
    assert r["or"] == ["bedrock", "other", "team"]


def test_the_css_draws_both_codes_and_keeps_the_old_classes_as_aliases():
    style, sessions_css, schedules_css = static("style.css"), static("sessions.css"), static("schedules.css")
    for var in ("--lane-subscription-1", "--lane-subscription-2"):
        assert style.count(var + ":") >= 3, f"{var}: light, dark by preference and dark by choice"
    assert re.search(r"\.lane-subscription-1\s*,\s*\.lane-max\s*\{\s*--lane:\s*var\(--lane-subscription-1\)", style)
    assert re.search(r"\.lane-subscription-2\s*,\s*\.lane-team\s*\{\s*--lane:\s*var\(--lane-subscription-2\)", style)
    for css in (style, sessions_css, schedules_css):
        for cls in (".lane-subscription-1", ".lane-subscription-2", ".lane-max", ".lane-team"):
            assert cls in css, (cls, "missing from a coloured-pill list")
    assert "--lane-max" not in style + sessions_css + schedules_css and "--lane-team" not in style + sessions_css + schedules_css, \
        "no variable under an old name is left behind"


def test_no_display_name_and_no_lane_called_max_is_written_in_the_page_or_the_server():
    """The names are sala's (`sala lane names --json`); a literal here would be a second place to change at the next rename."""
    src = STATIC.parent
    for p in sorted(src.rglob("*")):
        if not p.is_file() or p.suffix not in {".py", ".js", ".css", ".html"} or "vendor" in p.parts:
            continue
        text = p.read_text(encoding="utf-8", errors="replace")
        # Anthropic's plan names and Google's plan are not lane names: strip the lines that are about a plan
        lines = [ln for ln in text.splitlines() if not re.search(r"PLAN_NAMES|PLAN_WORDS|google_ai_ultra|Google AI Ultra|subscriptionType|plan_label", ln)]
        body = "\n".join(lines)
        assert not re.search(r"\bUltra\b", body), f"{p.relative_to(src)}: a display name written in code"
        if p.suffix in {".js", ".py"}:
            assert not re.search(r"""["'`]Max["'`]""", body), f"{p.relative_to(src)}: a lane called Max"
        assert not re.search(r"""\.lane-(max|team)\b""", body) or p.suffix == ".css", f"{p.relative_to(src)}: an old lane class in code"


def test_the_pages_read_a_lane_s_name_through_laneLabel():
    app, sessions, schedules, shared = static("app.js"), static("sessions.js"), static("schedules.js"), static("shared.js")
    assert "laneLabel(" in app and "laneLabel(" in sessions and "laneLabel(" in schedules
    assert "loadLaneNames" in app and "api/lane-names" in shared
    for text in (app, sessions, schedules):
        assert "LANE_LABEL[" not in text, "a label read straight from the override table would skip sala's names"
    assert 'PLACEHOLDER_LANES=["subscription-1","subscription-2"]' in sessions.replace(" ", "")


def test_the_js_files_parse():
    node = shutil.which("node")
    if not node:
        pytest.skip("no node")
    for name in ("shared.js", "app.js", "sessions.js", "schedules.js"):
        subprocess.run([node, "--check", str(STATIC / name)], check=True, capture_output=True, timeout=30)
