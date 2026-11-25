"""The Agents list: the columns, "Group by", and what the server keeps of it. Nothing here needs a browser.

The Agents tab lists every session in one table: Agent, Role, Surface, Status, Model, Effort, Lane. There is no Project column (the project is the agent
name's tooltip). Surface says where a front agent answers its owner, "sala" or "slack", and is a dash for any other row. Above the table are three
"Group by" buttons (Status, Lane, Role); a lit one clicked again is the plain list, which is the default. A group is a heading row that folds its rows.

Held here, in node and over the app's own prefs endpoint:

- the groups' order and membership (static/shared.js agentGroups): status needs input, working, shell, idle, sleeping; role front, back, then any other
  role word, then no role; lane in the lane cards' order the caller passes, a lane without a card after them, no lane last; a group with no rows is left
  out; the rows keep the order they came in (the header's sort) inside their group; a renamed lane word (max) joins the group of its new code;
- the choice and the folded groups are api/prefs' agentsGroup and agentsFolded: plain by default, an unknown way of grouping is refused on a write and
  ignored on a read of a saved file, the folds are a list of keys like the other lists;
- the markup: no Project column in the Agents table or the lane page's table, Surface right after Role, the three buttons are an aria-pressed toggle
  group, the heading rows are buttons that say aria-expanded, the table is laid out fixed.

What a wrong answer costs: a group in the wrong place (the Agents the owner needs to answer sorted under the sleepers), a heading that hides rows it
does not count, a saved grouping that a bad value in the state file turns into an empty list, or a column that makes the table scroll sideways.
The browser side (the buttons, the folds, the widths) is test_agents_groups_ui.py and test_agents_no_sideways_scroll.py. All names are invented.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess

import pytest
from starlette.testclient import TestClient

from sala_web.app import STATIC, create_app
from sala_web.config import Settings

NODE = shutil.which("node")
needs_node = pytest.mark.skipif(not NODE, reason="node is not installed")
INDEX = (STATIC / "index.html").read_text()
CSS = (STATIC / "sessions.css").read_text()
JS = (STATIC / "sessions.js").read_text()

PROGRAM = r"""
const fs = require('fs');
const text = fs.readFileSync(process.argv[1], 'utf8');
const block = (name) => new RegExp('// <' + name + '>[^\\n]*\\n([\\s\\S]*?)// </' + name + '>').exec(text)[1];
eval(block('lane-words') + block('agent-group-words') + 'globalThis.api = { agentGroups, agentGroupKey, AGENT_GROUPS };');
const G = globalThis.api;
const row = (name, role, status, lane) => ({ name, role, status, lane });
const rows = [
  row('a', 'back', 'idle', 'bedrock'), row('b', 'front', 'sleeping', 'subscription-1'), row('c', 'front', 'working', 'subscription-1'),
  row('d', '', 'idle', ''), row('e', 'front', 'needs input', 'api'), row('f', 'odd', 'shell', 'zzz-new-lane'), row('g', 'back', 'weird', 'max'),
  row('h', 'front', 'idle', 'bedrock'),
];
const show = (by, laneIds) => G.agentGroups(rows, by, laneIds).map((g) => [g.key, g.rows.map((r) => r.name)]);
console.log(JSON.stringify({
  names: G.AGENT_GROUPS,
  status: show('status'),
  role: show('role'),
  lane: show('lane', ['subscription-1', 'subscription-2', 'api', 'aws-platform', 'bedrock']),
  laneNoCards: show('lane', []),
  none: G.agentGroups(rows, '', []), unknown: G.agentGroups(rows, 'project', []), empty: G.agentGroups([], 'role', []),
  key: [G.agentGroupKey('lane', row('x', 'front', 'idle', 'max')), G.agentGroupKey('lane', row('x', 'front', 'idle', undefined)), G.agentGroupKey('role', row('x', undefined, 'idle', 'api'))],
}));
"""


def run() -> dict:
    out = subprocess.run([NODE, "-e", PROGRAM, str(STATIC / "shared.js")], capture_output=True, text=True, check=True, timeout=60).stdout
    return json.loads(out)


@needs_node
def test_groups_come_in_their_order_and_keep_the_rows_order_inside():
    g = run()
    assert g["names"] == ["status", "lane", "role"]
    # status: needs input, working, shell, idle, sleeping; a status the page does not know after them
    assert g["status"] == [["needs input", ["e"]], ["working", ["c"]], ["shell", ["f"]], ["idle", ["a", "d", "h"]], ["sleeping", ["b"]], ["weird", ["g"]]]
    # role: front, back, any other word, then no role
    assert g["role"] == [["front", ["b", "c", "e", "h"]], ["back", ["a", "g"]], ["odd", ["f"]], ["", ["d"]]]
    # lane: the cards' order; the renamed word (max) is subscription-1; a lane with no card after them; no lane last
    assert g["lane"] == [["subscription-1", ["b", "c", "g"]], ["api", ["e"]], ["bedrock", ["a", "h"]], ["zzz-new-lane", ["f"]], ["", ["d"]]]
    # no cards yet: the lanes with a name by name, no lane still last
    assert [k for k, _ in g["laneNoCards"]] == ["api", "bedrock", "subscription-1", "zzz-new-lane", ""]


@needs_node
def test_a_group_exists_only_for_a_row_and_a_plain_list_has_none():
    g = run()
    assert g["none"] == [] and g["unknown"] == [] and g["empty"] == []
    assert g["key"] == ["subscription-1", "", ""]


# ── what the server keeps ───────────────────────────────────────────────────────────────────────────────────────

@pytest.fixture
def env(tmp_path):
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    (claude / "projects").mkdir()
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                        tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"])
    return {"client": TestClient(create_app(settings)), "file": settings.state_dir / "prefs.json"}


def test_a_fresh_browser_gets_the_plain_list(env):
    prefs = env["client"].get("/api/prefs").json()
    assert prefs["agentsGroup"] == "" and prefs["agentsFolded"] == []


def test_the_grouping_and_the_folds_are_saved_and_a_later_save_of_another_key_keeps_them(env):
    c = env["client"]
    for by in ("status", "lane", "role", ""):
        r = c.put("/api/prefs", json={"agentsGroup": by})
        assert r.status_code == 200 and r.json()["agentsGroup"] == by, (by, r.text)
    assert c.put("/api/prefs", json={"agentsGroup": "role", "agentsFolded": ["role:back", "role:", "role:back"]}).json()["agentsFolded"] == ["role:back", "role:"]
    assert c.put("/api/prefs", json={"showAll": True}).status_code == 200
    got = c.get("/api/prefs").json()
    assert got["agentsGroup"] == "role" and got["agentsFolded"] == ["role:back", "role:"]
    assert json.loads(env["file"].read_text())["agentsGroup"] == "role"


@pytest.mark.parametrize("bad", ["project", "Status", " status", 3, None, True, ["status"], {"by": "status"}])
def test_an_unknown_way_of_grouping_is_refused_and_changes_nothing(env, bad):
    c = env["client"]
    assert c.put("/api/prefs", json={"agentsGroup": "lane"}).status_code == 200
    assert c.put("/api/prefs", json={"agentsGroup": bad}).status_code == 400
    assert c.get("/api/prefs").json()["agentsGroup"] == "lane"


@pytest.mark.parametrize("bad", ["role:back", [1], [""], [["a"]], None])
def test_the_folds_are_a_list_of_non_empty_strings(env, bad):
    assert env["client"].put("/api/prefs", json={"agentsFolded": bad}).status_code == 400


def test_a_saved_file_with_an_unknown_grouping_reads_as_plain_and_keeps_the_other_keys(env):
    env["file"].parent.mkdir(parents=True, exist_ok=True)
    env["file"].write_text(json.dumps({"agentsGroup": "project", "agentsFolded": ["status:idle"], "showAll": True}))
    got = env["client"].get("/api/prefs").json()
    assert got["agentsGroup"] == "" and got["agentsFolded"] == ["status:idle"] and got["showAll"] is True


# ── the markup ──────────────────────────────────────────────────────────────────────────────────────────────────

def agents_head() -> list[str]:
    head = INDEX.split('id="sp-table"')[1].split("</thead>")[0]
    return re.findall(r'<th data-key="(\w+)"', head)


def test_the_agents_table_has_no_project_column_and_surface_follows_role():
    assert agents_head() == ["name", "role", "surface", "status", "model", "effort", "lane"]
    lane_head = INDEX.split('id="ld-table"')[1].split("</thead>")[0]
    assert re.findall(r'data-i18n="([\w.]+)"', lane_head) == ["common.session", "common.role", "ui.col.surface", "common.status", "common.model", "common.effort", "common.lane"]
    assert "cellText.project" not in JS and "projectLabel(r), r.project" not in JS   # the project is the name's tooltip alone
    assert 'link.title = r.projectTitle ? projectLabel(r) : tl("ov.row.unregistered")' in JS


def test_the_group_buttons_are_a_pressed_toggle_group_and_the_headings_are_expandable_buttons():
    bar = INDEX.split('id="ag-bar"')[1].split("</div>")[0]
    assert re.findall(r'data-by="(\w+)" aria-pressed="false"', bar) == ["status", "lane", "role"]
    assert '<div id="ag-bar" class="ag-bar" role="group" aria-labelledby="ag-lbl">' in INDEX
    assert 'b.setAttribute("aria-expanded", String(open))' in JS and 'b.type = "button"' in JS
    assert 'b.setAttribute("aria-pressed", String(b.dataset.by === by))' in JS


def test_both_tables_are_laid_out_fixed_with_columns_that_add_up_and_nothing_scrolls():
    assert re.search(r"#sp-table, #ld-table\) \{[^}]*table-layout: fixed", CSS)
    widths = dict(re.findall(r"\.c-(\w+) \{ width: (\d+)%; \}", CSS))
    assert list(widths) == ["name", "role", "surface", "status", "model", "effort", "lane"] and sum(map(int, widths.values())) == 100, widths
    cols = re.findall(r'<col class="c-(\w+)">', INDEX)
    assert cols == list(widths) * 2   # the Agents table's colgroup and the lane page's
    assert not re.search(r"overflow(-x)?: *(auto|scroll)", CSS.split("#overview-pane .sp-wrap {")[1].split("\n")[0])
