"""The Surface column's icons: sala's app icon before "sala", the Slack logo before "slack", a bare dash for a back agent. No browser needed.

The Agents table (and the lane page's table, and a phone's cards, which are the same rows) shows where a front agent answers its owner as an icon and the
word: `[icon] sala`, `[icon] slack`. The icon is decorative (alt empty): the word beside it carries the meaning, stays the cell's text and is still the
column's sort key. A row with no surface (a back agent, a row with no role) keeps the dash and gets no icon. One helper (sessions.js surfaceCell) builds the
cell for every table and card, and the icon files are served from static/icons (sala's own app icon, reused, and the Slack logo committed with a notice).

Held here, in node with a tiny stand-in for the document, over the app's static route, and on the sources:

- a slack row holds an img whose src ends slack-logo.svg and the text "slack"; a sala row (the surface key absent, or "sala") holds the icon-192.png img and
  "sala"; a back agent and a row with no role hold neither img and only the dash, which a phone's card leaves out (class ag-dash);
- the img is decorative (alt empty) and 16 by 16; the cell is a flex row with an 8px gap (the 4px grid) whose icon does not shrink, and its word keeps the
  ellipsis; the sala icon is rounded on the page's 4px corner;
- the one helper serves both tables (sessionRow calls it, nothing else builds the cell);
- the app serves /static/icons/slack-logo.svg as image/svg+xml with a 200, and the file is the four-colour logo with only paths (no script, no link out);
- the trademark notice sits beside the file and says what it must.

What a wrong answer costs: the logo that does not load (a wrong type, a wrong path), a long word that pushes the icon out or the table wider, a dash row that
gets a logo, or a logo committed with no word about whose it is. The browser side (the real sizes) is one assertion of test_agents_groups_ui.py.
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
JS = (STATIC / "sessions.js").read_text(encoding="utf-8")
CSS = (STATIC / "sessions.css").read_text(encoding="utf-8")
ICONS = STATIC / "icons"

PROGRAM = r"""
const fs = require('fs');
const text = fs.readFileSync(process.argv[1], 'utf8');
const between = (a, b) => text.slice(text.indexOf(a), text.indexOf(b));
// a stand-in for the document: an element keeps its class, text, attributes and children, which is all the cell needs
class El {
  constructor(tag) { this.tagName = tag; this.className = ''; this.children = []; this._text = ''; }
  append(...kids) { for (const k of kids) this.children.push(k); }
  set textContent(t) { this._text = String(t); }
  get textContent() { return this._text + this.children.map((c) => c.textContent).join(''); }
}
globalThis.document = { createElement: (tag) => new El(tag.toUpperCase()) };
eval(between('function td(', '// The model as a family') + between('const SURFACE_ICON', '// one session') + 'globalThis.surfaceCell = surfaceCell;');
const show = (r) => {
  const cell = surfaceCell(r);
  const imgs = [];
  const walk = (n) => { if (n.tagName === 'IMG') imgs.push({ src: n.src, alt: n.alt, width: n.width, height: n.height, cls: n.className }); n.children.forEach(walk); };
  walk(cell);
  return { text: cell.textContent, imgs, cellClass: cell.className, wrapper: cell.children[0] ? cell.children[0].className : null };
};
console.log(JSON.stringify({
  sala: show({ role: 'front' }),
  salaNamed: show({ role: 'front', surface: 'sala' }),
  slack: show({ role: 'front', surface: 'slack' }),
  back: show({ role: 'back' }),
  noRole: show({ role: '' }),
  backSlackKey: show({ role: 'back', surface: 'slack' }),
}));
"""


def cells() -> dict:
    out = subprocess.run([NODE, "-e", PROGRAM, str(STATIC / "sessions.js")], capture_output=True, text=True, check=True, timeout=60).stdout
    return json.loads(out)


@needs_node
def test_a_slack_row_holds_the_slack_logo_and_the_word_slack():
    c = cells()["slack"]
    assert c["text"] == "slack"
    assert len(c["imgs"]) == 1 and c["imgs"][0]["src"].endswith("slack-logo.svg"), c
    assert "ag-slack" in c["wrapper"]   # the word stays in the accent colour


@needs_node
def test_a_sala_row_holds_the_sala_icon_and_the_word_sala_whether_the_key_is_absent_or_sala():
    for key in ("sala", "salaNamed"):
        c = cells()[key]
        assert c["text"] == "sala"
        assert len(c["imgs"]) == 1 and c["imgs"][0]["src"].endswith("icon-192.png"), c
        assert "ag-slack" not in c["wrapper"]


@needs_node
def test_a_back_agent_and_a_row_with_no_role_hold_only_the_dash_and_no_image():
    got = cells()
    for key in ("back", "noRole", "backSlackKey"):   # a slack key on a back agent is not a front agent's surface
        assert got[key]["imgs"] == [] and got[key]["text"] == "–", (key, got[key])
        assert got[key]["cellClass"] == "ag-dash"    # a phone's card leaves the dash out


@needs_node
def test_the_icons_are_decorative_and_sixteen_pixels():
    got = cells()
    for key in ("sala", "slack"):
        img = got[key]["imgs"][0]
        assert img["alt"] == "" and img["width"] == 16 and img["height"] == 16, img


def test_one_helper_builds_the_cell_for_the_table_and_the_lane_page_and_the_cards():
    assert len(re.findall(r"\bsurfaceCell\(", JS)) == 2   # its definition and the one call in sessionRow
    assert re.search(r"tr\.append\(\s*td\(link\),[^;]*?surfaceCell\(r\),", JS, re.S)
    assert JS.count("slack-logo.svg") == 1 and JS.count("icon-192.png") == 1 and JS.count("document.createElement(\"img\")") == 1
    # the lane page's table is drawn by the same row function, and the cards are the same cells under .fold
    assert JS.count(".map(sessionRow)") >= 3   # the grouped Agents table, the plain one, the lane page's


def test_the_cell_is_a_flex_row_on_the_grid_with_an_icon_that_does_not_shrink_and_a_word_that_keeps_its_ellipsis():
    box = re.search(r"\.ag-surf \{([^}]*)\}", CSS).group(1)
    assert "display: flex" in box and "gap: 8px" in box and "min-width: 0" in box
    assert re.search(r"\.ag-surf img \{[^}]*flex: none;[^}]*width: 16px;[^}]*height: 16px", CSS)
    word = re.search(r"\.ag-surf-t \{([^}]*)\}", CSS).group(1)
    assert "text-overflow: ellipsis" in word and "overflow: hidden" in word and "min-width: 0" in word
    assert re.search(r"\.ag-ico-sala \{[^}]*border-radius: 4px", CSS)
    # the columns of the table are as they were
    widths = dict(re.findall(r"\.c-(\w+) \{ width: (\d+)%; \}", CSS))
    assert list(widths.values()) == ["25", "8", "11", "13", "17", "12", "14"]


# ── the files and the route ─────────────────────────────────────────────────────────────────────────────────────

@pytest.fixture
def client(tmp_path):
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    (claude / "projects").mkdir()
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                        tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"])
    return TestClient(create_app(settings))


def test_the_app_serves_the_slack_logo_as_an_svg_and_the_sala_icon_as_a_png(client):
    r = client.get("/static/icons/slack-logo.svg")
    assert r.status_code == 200 and r.headers["content-type"].split(";")[0] == "image/svg+xml", (r.status_code, r.headers["content-type"])
    assert r.headers["cache-control"] == "no-cache"
    assert r.content == (ICONS / "slack-logo.svg").read_bytes()
    r = client.get("/static/icons/icon-192.png")
    assert r.status_code == 200 and r.headers["content-type"] == "image/png"


def test_the_logo_is_the_four_colour_mark_made_of_paths_only():
    svg = (ICONS / "slack-logo.svg").read_text(encoding="utf-8")
    assert svg.startswith('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 122.8 122.8">')
    assert len(re.findall(r"<path ", svg)) == 4 and len({c.lower() for c in re.findall(r'fill="(#[0-9a-fA-F]{6})"', svg)}) == 4
    assert not re.search(r"<script|<style|<image|<use|href=|onload|<foreignObject", svg, re.I)   # nothing that runs or loads


def test_the_trademark_notice_sits_beside_the_logo_and_excludes_it_from_the_license():
    notice = " ".join((ICONS / "NOTICE.md").read_text(encoding="utf-8").split())
    for must in ("trademark of Slack Technologies, LLC (Salesforce)", "only to mark which agents are reached through Slack",
                 "not affiliated with, endorsed by or sponsored by Slack", "All rights in the logo remain with its owner",
                 "does not cover `slack-logo.svg`"):
        assert must in notice, must
