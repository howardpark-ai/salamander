"""The lane awsplatform became aws-platform (salamander tests/lane-rename.sh is
sala's side). The old name stays a WORD for the lane on this side too: sala's files written before the rename (lanes.log, lanes.tsv,
lane-state.tsv, sessions.json, spend-lanes.json's sightings), a saved link or view (#lane=awsplatform), a form loaded before (the spawn
payload) and an API call that still says it all read as the new name, and nothing here writes the old one.

What a wrong answer costs: a month's spend figure for the lane that drops the messages sala recorded under the old name, a dormant lane
that reads as active because its record is keyed by the old word, a saved link that opens "sala does not know this lane", a lane pill
with no colour, or a spawn from an old form refused as "lane must be one of". Hyphen safety is checked where a name is a token here: a JS
object key (LANE_LABEL), a CSS class (lane-aws-platform), a URL hash, a JSON value, a file name (nothing is named by the lane)."""

from __future__ import annotations

import json
import re

import pytest
from starlette.testclient import TestClient

from sala_web import lanes as LN
from sala_web import lanestate as LS
from sala_web import spawn as SP
from sala_web import spend as SPD
from sala_web.app import STATIC
from test_lane_details import TABLE, get, open_lane, stub_sala, world, page  # noqa: F401  (fixtures: sala's stand-in, the app, its page)
from test_spend import A, line, w  # noqa: F401  (the spend world)

OLD, NEW = "awsplatform", "aws-platform"


# ── the readers of sala's files ──────────────────────────────────────────────
def test_the_dormant_record_keyed_by_the_old_word_is_the_new_lane_s(tmp_path):
    p = tmp_path / "lane-state.tsv"
    p.write_text(f"{OLD}\tdormant\tno workspace\t2026-01-05T03:00:00Z\t\thand\nteam\tdormant\tseat gone\t2026-01-06T03:00:00Z\t\tsignal\n")
    d = LS.dormant(p)
    assert set(d) == {NEW, "subscription-2"} and d[NEW] == {"reason": "no workspace", "since": "2026-01-05T03:00:00Z"}, d
    p.write_text(f"{NEW}\tdormant\twhy\t2026-01-05T03:00:00Z\t\thand\n")
    assert set(LS.dormant(p)) == {NEW}
    assert LS.ALIASES == {"sdk": "api", OLD: NEW, "max": "subscription-1", "team": "subscription-2"}


def test_the_lane_table_answers_for_the_old_word_too():
    rows = LN.parse_table(json.dumps(TABLE))
    a = LN.record_of(rows, NEW)
    assert a is not None and a["label"] == "Claude Platform on AWS"
    assert LN.record_of(rows, OLD) == a and LN.record_of(rows, "api") == LN.record_of(rows, "sdk")
    assert LN.LANE_ID_RE.match(NEW) and LN.LANE_ID_RE.match(OLD)    # a hyphen is a legal lane id on the details route


def test_the_details_route_answers_the_old_word_as_the_new_lane(stub_sala, world):
    old, new = get(world, OLD), get(world, NEW)
    assert old.status_code == 200 and new.status_code == 200
    assert old.json()["lane"] == NEW and old.json()["record"] == new.json()["record"] and old.json()["state"] == new.json()["state"]
    assert get(world, "aws_platform").status_code == 404 and get(world, "-aws").status_code == 400   # the underscore is no lane; a leading dash no id


def test_canonical_in_the_spend_counter():
    assert SPD.canonical(OLD) == NEW and SPD.canonical(NEW) == NEW and SPD.canonical("sdk") == "api" and SPD.canonical("max") == "subscription-1"
    assert SPD.LANES == (NEW, "bedrock")


def test_messages_sala_recorded_under_the_old_name_count_for_the_new_lane(w):
    # lanes.log, the registry's lane and the sightings all say awsplatform, as they do in the live state today
    w.registry("pane", A, lane=OLD)
    w.log(("2026-10-03T00:00:00+00:00", "set", "pane", f"(default) → {OLD}"),
          ("2026-10-10T00:00:00+00:00", "set", "pane", f"{OLD} → bedrock"),
          ("2026-10-15T00:00:00+00:00", "set", "pane", f"bedrock → {NEW}"))
    w.transcript(A, line("a", "claude-sonnet-5-5", "2026-10-05T00:00:00Z", out=100_000),      # $1.00 on the lane under its old name
                 line("b", "claude-sonnet-5-5", "2026-10-12T00:00:00Z", out=200_000),         # $2.00 on bedrock
                 line("c", "claude-sonnet-5-5", "2026-10-16T00:00:00Z", out=100_000))         # $1.00 on the lane under its new name
    got = w.count()
    assert w.lane(got, NEW)["monthUsd"] == pytest.approx(2.0) and w.lane(got, "bedrock")["monthUsd"] == pytest.approx(2.0), got
    assert [x["lane"] for x in got["lanes"]] == [NEW, "bedrock"]


def test_a_tsv_row_a_default_and_a_saved_sighting_with_the_old_word_are_read_as_the_new_one(w):
    (w.sala / "lanes.tsv").write_text(f"pane\t{OLD}\n")
    (w.sala / "sessions.json").write_text(json.dumps({"schema": 1, "sessions": {A: {
        "id": A, "name": "pane", "lane": None, "aliases": [], "state": "live",
        "transcripts": [{"id": A, "machine": "a", "at": "2026-10-01T00:00:00Z", "why": "import"}]}}}))
    w.transcript(A, line("a", "claude-sonnet-5-5", "2026-10-05T00:00:00Z", out=100_000))
    assert w.lane(w.count(), NEW)["monthUsd"] == pytest.approx(1.0)                         # lanes.tsv, the session's current lane
    (w.sala / "lanes.tsv").write_text("")
    (w.sala / "lane-default").write_text(OLD + "\n")
    assert w.lane(w.count(cache=False), NEW)["monthUsd"] == pytest.approx(1.0)              # the default lane
    (w.sala / "lane-default").write_text("max\n")
    (w.state / "spend-lanes.json").write_text(json.dumps({"v": 1, "sessions": {A: {"name": "pane", "seen": [[1788000000000, OLD]]}}}))
    assert w.lane(w.count(), NEW)["monthUsd"] == pytest.approx(1.0)                         # a sighting saved before the rename


# ── what a client sends ──────────────────────────────────────────────────────
GOOD = {"project": "projects/example", "role": "front", "name": "x-main"}


def test_a_spawn_payload_with_the_old_word_is_the_new_lane():
    lanes = ["subscription-1", "api", "bedrock", NEW]
    for word in (OLD, NEW):
        r = SP.validate({**GOOD, "lane": word}, ["projects", "infra"], lanes)
        assert not isinstance(r, tuple) and r.lane == NEW, (word, r)
        s = SP.validate({**GOOD, "role": "", "side": True, "item": "board#9001", "fork_of": "x-main", "lane": word}, ["projects", "infra"], lanes)
        assert isinstance(s, tuple) or s.lane == NEW, (word, s)
    r = SP.validate({**GOOD, "lane": "aws_platform"}, ["projects", "infra"], lanes)
    assert r == (400, "lane must be one of subscription-1, api, bedrock, aws-platform")


# ── the page ─────────────────────────────────────────────────────────────────
def static(name):
    return (STATIC / name).read_text(encoding="utf-8")


def test_the_hyphen_is_safe_where_the_name_is_a_token_in_the_page_s_code():
    shared, style, sessions_css = static("shared.js"), static("style.css"), static("sessions.css")
    assert re.search(r'LANE_LABEL = \{[^}]*"aws-platform": "aws-platform"', shared), "a hyphenated JS object key must be quoted"
    assert not re.search(r'[{,]\s*aws-platform\s*:', shared + static("sessions.js") + static("app.js")), "an unquoted hyphenated key is a subtraction"
    assert "--lane-aws-platform:" in style and ".lane-aws-platform" in style and ".lane-awsplatform" in style         # the class, and the old class still drawn
    assert ".lane-awsplatform" in sessions_css
    assert "--lane-awsplatform" not in style + sessions_css                                                          # no variable under the old name left behind
    assert 'const laneNorm' in shared and '"aws-platform"' in shared


NODE_NORM = r"""
const fs = require('fs');
const src = fs.readFileSync(process.argv[1], 'utf8');
const m = /\/\/ <lane-words>[^\n]*\n([\s\S]*?)\/\/ <\/lane-words>/.exec(src);
eval(m[1] + 'globalThis.laneNorm = laneNorm; globalThis.LANE_LABEL = LANE_LABEL;');
console.log(JSON.stringify([laneNorm('awsplatform'), laneNorm('aws-platform'), laneNorm('max'), laneNorm(undefined), laneNorm(null),
                            LANE_LABEL[laneNorm('awsplatform')], LANE_LABEL['aws-platform']]));
"""


def test_laneNorm_in_node():
    import shutil, subprocess
    node = shutil.which("node")
    if not node:
        pytest.skip("no node")
    out = subprocess.run([node, "-e", NODE_NORM, str(STATIC / "shared.js")], capture_output=True, text=True, check=True).stdout
    assert json.loads(out) == [NEW, NEW, "subscription-1", None, None, "aws-platform", "aws-platform"], out


def test_a_saved_link_to_the_old_name_opens_the_lane_s_page(stub_sala, world, page, browser):
    p = open_lane(browser, page(), "#lane=awsplatform")
    assert p["title"] == "aws-platform" + "aws-platform lane" and p["record"]["Project"] == "wrkspc_01EXAMPLE", p
    assert browser.evaluate("location.hash") in ("#lane=awsplatform", "#lane=aws-platform")
    assert "lane-aws-platform" in browser.evaluate("document.querySelector('#ld-title .sp-pill').className")
