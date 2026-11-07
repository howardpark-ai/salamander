"""A lane's details page : each lane card on the Overview has a "Details ›"
link in its head, to `#lane=<id>`, a view of the Overview's pane with a Back button. The page shows the lane's record (sala's
lane table, `sala lane --json`, through `GET /api/lanes/<id>`), its state (lane-state.tsv: active, dormant and why, not set
up), its usage as the card shows it (the same answers and the same drawing code) and the sessions on the lane, each linked.

What a wrong answer costs here: a file path of a key or a sign-in file reaching the page (the API lane's `credential` field
names two), a secret read from a sign-in file and shown, a lane's page that shows one lane's figures under another's name, a
dormant lane drawn as active, a failing `sala lane` that blanks the whole page instead of one section, or a Back button that
leaves a second Overview entry in the history or leaves sala altogether. Nothing here runs the real sala: `sala` is a
stand-in script in tmp_path that records its argv and prints a lane table as `sala lane --json` does, in the mode the test
set; the sign-in files are fakes, the usage endpoint and the Admin API are never called (test_lane_dormant.py's `world`).
The page parts run in a headless Chromium when one is installed (conftest.py: `served`, `browser`), else are skipped.
"""

from __future__ import annotations

import json
import os
import sys

import pytest
from starlette.testclient import TestClient

from sala_web import lanes as LN
from sala_web.app import STATIC
from test_back_button import back, forward, hist, open_app, settle, tap
from test_board_items_ui import wait_for
from test_lane_dormant import CARDS, SINCE, TOKEN, creds, page, quota_lanes, record, world  # noqa: F401  (fixtures: the app, its page)

INDEX = (STATIC / "index.html").read_text()
SESSIONS_JS = (STATIC / "sessions.js").read_text()
APP_JS = (STATIC / "app.js").read_text()

KEY_FILE, WS_FILE = "~/.config/anthropic/api-key-secret-name", "~/.config/anthropic/workspace-id"
TABLE = {
    "default": "subscription-1",
    "lanes": [
        {"id": "subscription-1", "label": "Ultra", "provider": "anthropic", "client": "claude-code", "org": "Example Org", "project": None,
         "billing": "subscription", "payment": None, "plan": "max_20x", "account": "alex@example.com", "credential": "login",
         "region": None, "status": "active"},
        {"id": "subscription-2", "label": "Team", "provider": "anthropic", "client": "claude-code", "org": "ExampleOrg", "project": None,
         "billing": "subscription", "payment": None, "plan": None, "account": "alex@example.com", "credential": "login",
         "region": None, "status": "inactive"},
        {"id": "api", "label": "API", "provider": "anthropic", "client": "claude-code", "org": "unconfirmed", "project": None,
         "billing": "usage", "payment": "prepaid", "plan": None, "account": "alex@example.com",
         "credential": f"key file {KEY_FILE} + workspace id file {WS_FILE}", "region": None, "status": "inactive"},
        {"id": "bedrock", "label": "Bedrock", "provider": "amazon-bedrock", "client": "claude-code", "org": "AWS account",
         "project": None, "billing": "usage", "payment": "postpaid", "plan": None, "account": "alex+bedrock@example.com",
         "credential": "AWS profile", "region": "us-east-1", "status": "not set up"},
        {"id": "aws-platform", "label": "Claude Platform on AWS", "provider": "anthropic", "client": "claude-code",
         "org": "AWS-linked Anthropic organization", "project": "wrkspc_01EXAMPLE", "billing": "usage", "payment": "postpaid",
         "plan": None, "account": "alex+bedrock@example.com", "credential": "AWS profile", "region": "us-east-1",
         "status": "not set up"},
    ],
    "aliases": {"sdk": {"lane": "api", "client": "claude-agent-sdk"}},
}

# what `sala lane names --json` prints (sala's display names; the page reads them through GET /api/lane-names)
NAMES = {"lanes": [{"code": "subscription-1", "display": "Ultra", "aliases": ["max"]}, {"code": "subscription-2", "display": "Team", "aliases": ["team"]},
                   {"code": "api", "display": "API", "aliases": []}, {"code": "bedrock", "display": "Bedrock", "aliases": []},
                   {"code": "aws-platform", "display": "Claude Platform on AWS", "aliases": ["awsplatform"]}]}

STUB = r'''#!@@PY@@
"""pytest's stand-in for sala (web/tests/test_lane_details.py): records its argv next to itself and prints the lane table as
`sala lane --json` does, in the mode the test set."""
import json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
def ctl(name, default):
    try:
        with open(os.path.join(HERE, "lanes-" + name), encoding="utf-8") as f:
            return f.read().strip() or default
    except OSError:
        return default
if sys.argv[1:] == ["lane", "names", "--json"]:   # sala's display names: asked by every page load, not a call of the lane table, so not recorded
    print(json.dumps(@@NAMES@@))
    sys.exit(0)
with open(os.path.join(HERE, "lanes-record.jsonl"), "a", encoding="utf-8") as f:
    f.write(json.dumps(sys.argv[1:]) + "\n")
if sys.argv[1:] != ["lane", "--json"]:
    sys.stderr.write("stub: unexpected call\n")
    sys.exit(2)
mode = ctl("mode", "ok")
table = json.dumps(@@TABLE@@, indent=2)
if mode == "fail":
    sys.stderr.write("lane table broken\n")
    sys.exit(1)
if mode == "garbage":
    print("this is not a lane table")
elif mode == "nolanes":
    print('{"default": "subscription-1"}')
elif mode == "noise":
    print("a notice before the table\n" + table)
else:
    print(table)
'''


class Stub:
    def __init__(self, tmp_path):
        self.cmd = tmp_path / "lanes-sala"
        self.cmd.write_text(STUB.replace("@@PY@@", sys.executable).replace("@@TABLE@@", repr(TABLE)).replace("@@NAMES@@", repr(NAMES)), encoding="utf-8")
        self.cmd.chmod(0o755)
        self.dir = tmp_path

    def mode(self, m: str) -> None:
        (self.dir / "lanes-mode").write_text(m)

    def calls(self) -> list[list[str]]:
        p = self.dir / "lanes-record.jsonl"
        return [json.loads(x) for x in p.read_text().splitlines()] if p.exists() else []


@pytest.fixture
def stub_sala(tmp_path, monkeypatch):
    """The stand-in, set as the sala command of every Settings made after it (list it before `world` or `served`)."""
    s = Stub(tmp_path)
    monkeypatch.setenv("SALA_WEB_SALA_CMD", str(s.cmd))
    return s


def get(world, lane):
    with TestClient(world["app"]) as c:
        return c.get(f"/api/lanes/{lane}")


# ── what the server shapes ───────────────────────────────────────────────────
def test_plain_takes_every_file_path_out_and_keeps_the_words():
    assert LN.plain(f"key file {KEY_FILE} + workspace id file {WS_FILE}") == "key file + workspace id file"
    assert LN.plain("login") == "login" and LN.plain("AWS profile") == "AWS profile"
    for v in ("a key at /etc/secret/key.json", "x ~/y z", "C:\\Users\\alex\\key.txt", "../up/file", "./here"):
        out = LN.plain(v)
        assert "/" not in out and "~" not in out and "\\" not in out, (v, out)
    assert LN.plain("alex+bedrock@example.com") == "alex+bedrock@example.com"     # an account's plus and dots stay
    assert LN.plain("line\none\x00two") == "line one two" and LN.plain(None) == "" and LN.plain(5) == ""
    assert len(LN.plain("x" * 1000)) == LN.VALUE_MAX


def test_the_record_is_the_lane_s_row_and_sdk_reads_as_api():
    rows = LN.parse_table("a notice\n" + json.dumps(TABLE))
    api = LN.record_of(rows, "api")
    assert api["billing"] == "usage" and api["payment"] == "prepaid" and api["plan"] == "" and api["region"] == ""
    assert api["credential"] == "key file + workspace id file"
    assert LN.record_of(rows, "sdk") == api and LN.record_of(rows, "nope") is None
    for bad in ("", "no json", '{"lanes": 3}', "[1]"):
        with pytest.raises(ValueError):
            LN.parse_table(bad)


# ── GET /api/lanes/<id> ──────────────────────────────────────────────────────
def test_the_endpoint_answers_a_lane_s_record_with_no_path_and_no_secret(stub_sala, world):
    r = get(world, "api")
    d = r.json()
    assert r.status_code == 200 and r.headers["cache-control"] == "no-store"
    assert d["lane"] == "api" and d["error"] is None and d["state"] == {"state": "active"}
    assert d["record"]["credential"] == "key file + workspace id file" and d["record"]["payment"] == "prepaid"
    assert stub_sala.calls() == [["lane", "--json"]]                    # the one read-only call, nothing else
    for lane in ("subscription-1", "subscription-2", "api", "bedrock", "aws-platform", "sdk"):
        text = get(world, lane).text
        assert "~" not in text and ".config" not in text and "secret-name" not in text and TOKEN not in text, (lane, text)
        assert "/" not in text.replace("application/json", ""), (lane, text)


def test_sdk_is_the_api_lane_and_an_unknown_one_is_a_404_and_a_bad_id_a_400(stub_sala, world):
    assert get(world, "sdk").json()["lane"] == "api"
    r = get(world, "nope")
    assert r.status_code == 404 and "no such lane" in r.json()["error"]
    for bad in ("A%20B", "x" * 40, "-x"):
        assert get(world, bad).status_code == 400, bad


def test_the_state_is_the_dormant_record_else_the_tables_not_set_up_else_active(stub_sala, world):
    assert get(world, "subscription-1").json()["state"] == {"state": "active"}
    assert get(world, "bedrock").json()["state"] == {"state": "not set up"}
    assert get(world, "aws-platform").json()["state"] == {"state": "not set up"}
    record(world["rec"], ("subscription-2", "dormant", "no seat", SINCE, "", "signal"), ("sdk", "dormant", "credit used up", SINCE, "", "signal"))
    assert get(world, "subscription-2").json()["state"] == {"state": "dormant", "reason": "no seat", "since": SINCE}
    assert get(world, "api").json()["state"]["reason"] == "credit used up"          # api, by its sdk word
    assert get(world, "subscription-1").json()["state"] == {"state": "active"}
    record(world["rec"], ("subscription-2", "active", "", "2026-01-06T01:00:00Z", "", ""))
    assert get(world, "subscription-2").json()["state"] == {"state": "active"}              # read at each request


def test_a_table_sala_cannot_print_is_one_clear_answer_and_the_state_still_comes(stub_sala, world):
    record(world["rec"], ("subscription-2", "dormant", "no seat", SINCE, "", "signal"))
    for mode, why in (("fail", "sala exited 1"), ("garbage", "no JSON"), ("nolanes", "no lanes")):
        stub_sala.mode(mode)
        r = get(world, "subscription-2")
        d = r.json()
        assert r.status_code == 200 and d["record"] is None and why in d["error"], (mode, d)
        assert d["state"]["state"] == "dormant"                                    # lane-state.tsv needs no sala
        assert get(world, "subscription-1").json()["state"] == {"state": "unknown"}
    stub_sala.mode("noise")
    assert get(world, "subscription-1").json()["record"]["plan"] == "max_20x"                  # a notice before the table is skipped


def test_sala_missing_is_the_same_clear_answer(world, monkeypatch, tmp_path):
    from sala_web.config import Settings
    from sala_web.app import create_app
    s = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=world["settings"].claude_dir,
                 tmux_socket_name="salaweb-pytest-none", roles_cmd=["false"], sala_cmd=[str(tmp_path / "no-such-sala")],
                 sala_state_dir=tmp_path / "none")
    with TestClient(create_app(s)) as c:
        d = c.get("/api/lanes/max").json()
    assert d["record"] is None and "could not run sala" in d["error"] and d["state"] == {"state": "unknown"}


# ── the page ─────────────────────────────────────────────────────────────────
def test_the_page_has_the_pieces_once():
    for i in ("ld", "ld-back", "ld-title", "ld-count", "ld-reload", "ld-note", "ld-line", "ld-record", "ld-usage", "ld-table"):
        assert INDEX.count(f'id="{i}"') == 1, i
    assert '<a id="ld-back" class="sp-btn" href="#sessions"' in INDEX
    assert '$("#ld-reload").addEventListener("click", () => reloadPage("overview"));' in APP_JS     # the cause test_timing_debug.py lists
    for secret_word in ("credentials.json", "accessToken", "refreshToken"):
        assert secret_word not in SESSIONS_JS.split("A LANE'S DETAILS PAGE")[1]


PHONE_ROWS = [
    {"name": n, "pid": 1, "sessionId": n, "scope": "example", "project": "projects/demo", "projectTitle": "demo", "role": "front",
     "status": st, "lane": lane, "model": "claude-opus-5-5", "effort": "high", "modelSource": "launch", "effortSource": "launch", "modelAlias": None}
    for n, st, lane in (("on-max-a", "working", "subscription-1"), ("on-max-b", "idle", "subscription-1"), ("on-team", "idle", "subscription-2"),
                        ("on-api", "idle", "api"), ("on-sdk", "working", "sdk"))
]
OVERVIEW_STUB = """(() => { const real = window.fetch.bind(window);
  window.fetch = (url, opts) => String(url).startsWith("api/overview")
    ? Promise.resolve(new Response(JSON.stringify({ sessions: %s, rolesError: null }), { headers: { "Content-Type": "application/json" } }))
    : real(url, opts); })();""" % json.dumps(PHONE_ROWS)

LANE_PAGE = """(() => {
  const q = (s) => document.querySelector(s), all = (s) => [...document.querySelectorAll(s)];
  const vw = document.documentElement.clientWidth, pane = q("#overview-pane");
  const dl = q("#ld-record dl");
  return { hash: location.hash, laneOpen: document.body.classList.contains("lane-open"), overviewOpen: document.body.classList.contains("overview-open"),
    shown: getComputedStyle(q("#ld")).display !== "none", listHidden: getComputedStyle(q("#overview-pane > .sp:not(.ld)")).display === "none",
    title: q("#ld-title .sp-pill:not(.lane-chip)").textContent + q("#ld-title .ld-name").textContent, name: q("#title .name").textContent, docTitle: document.title, count: q("#ld-count").textContent,
    note: q("#ld-note").textContent,
    headPills: all("#ld-title .lane-chip").length,
    chip: q("#ld-title .lane-chip") ? q("#ld-title .lane-chip").textContent : null, chipCls: q("#ld-title .lane-chip") ? q("#ld-title .lane-chip").className : "",
    line: q("#ld-line").textContent, lineShown: getComputedStyle(q("#ld-line")).display !== "none" && q("#ld-line").getBoundingClientRect().height > 0,
    statusCard: !!q("#ld-status, #ld-h-status") || all("#ld .ld-h").map((h) => h.textContent).includes("Status"),
    headOrder: [...q("#ld-title").children].map((e) => e.className.split(" ")[0] === "sp-pill" && !e.classList.contains("lane-chip") ? "label" : e.classList.contains("lane-chip") ? "chip" : "name"),
    recordText: q("#ld-record").textContent.trim(),
    record: dl ? Object.fromEntries([...dl.querySelectorAll("dt")].map((t) => [t.textContent, t.nextElementSibling.textContent])) : null,
    usage: { cards: all("#ld-usage .q-card").length, text: q("#ld-usage").textContent.trim(), bars: all("#ld-usage [role=progressbar]").length,
             details: all("#ld-usage .q-details").length, bill: all("#ld-usage .c-bill").map((a) => a.href), dormant: all("#ld-usage .q-dormant-line").map((x) => x.textContent),
             chips: all("#ld-usage .lane-chip").map((x) => x.textContent), headEnds: all("#ld-usage .q-head-end").length,
             emptyHeadKids: all("#ld-usage .q-head > *").filter((e) => !e.textContent.trim() && !e.children.length).length,
             headKinds: all("#ld-usage .q-head > *").map((e) => e.className.split(" ")[0] + (e.classList.contains("lane-chip") ? "!chip" : "")),
             pills: all("#ld-usage .q-head .sp-pill:not(.lane-chip)").map((x) => x.textContent),
             figs: all("#ld-usage .c-v").map((x) => x.textContent) },
    sessions: all("#ld-table tbody tr").map((tr) => ({ text: tr.textContent.trim(), link: tr.querySelector("a") ? tr.querySelector("a").getAttribute("href") : null,
                                                       lane: tr.querySelector("td:last-child .sp-pill") ? tr.querySelector("td:last-child .sp-pill").textContent : null })),
    back: { href: q("#ld-back").getAttribute("href"), text: q("#ld-back").textContent.trim(), h: q("#ld-back").getBoundingClientRect().height },
    cols: ["#ld-record", "#ld-usage"].map((id) => { const r = q(id).closest(".ld-sec").getBoundingClientRect(); return { left: r.left, right: r.right, top: r.top, bottom: r.bottom }; }),
    headRects: { title: q("#ld-title").getBoundingClientRect().toJSON(), chip: q("#ld-title .lane-chip") ? q("#ld-title .lane-chip").getBoundingClientRect().toJSON() : null,
                 name: q("#ld-title .ld-name").getBoundingClientRect().toJSON(), count: q("#ld-count").getBoundingClientRect().toJSON(), line: q("#ld-line").getBoundingClientRect().toJSON(),
                 head: q("#ld .sp-head").getBoundingClientRect().toJSON() },
    vw, docScroll: document.documentElement.scrollWidth, paneScroll: pane.scrollWidth, paneClient: pane.clientWidth,
    right: Math.max(...all("#ld *").filter((e) => !e.closest(".sp-wrap") && e.getBoundingClientRect().width).map((e) => e.getBoundingClientRect().right)) };   // the table scrolls inside its box
})()"""


def open_lane(browser, url, hash_="#lane=subscription-1", width=390, ready="true"):
    """The lane's page opened by its address, once the record has been answered (or failed), the usage has an answer and
    the sessions are listed; `ready` is one more condition."""
    browser.width, browser.height = width, 844
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": OVERVIEW_STUB})
    browser.open(f"{url}/{hash_}")
    assert wait_for(browser, "!!document.body && document.body.classList.contains('lane-open') && "
                             "!/Loading/.test(document.querySelector('#ld-record').textContent) && "
                             f"!document.querySelector('#ld-usage .q-pending') && document.querySelectorAll('#ld-table tbody tr').length > 0 && !!({ready})")
    return browser.evaluate(LANE_PAGE)


def test_every_lane_card_has_a_details_link_in_its_head_dormant_ones_too(stub_sala, world, page, browser):
    record(world["rec"], ("subscription-2", "dormant", "no seat", SINCE, "", "signal"))
    browser.width, browser.height = 390, 844
    browser.open(f"{page()}/#sessions")
    assert wait_for(browser, "document.querySelectorAll('#q-cards > *').length >= 5 && !document.querySelector('#q-cards .q-pending')")
    got = browser.evaluate("""[...document.querySelectorAll("#q-cards > .q-card")].map((c) => { const a = c.querySelector(".q-head a.q-details");
      const h = c.querySelector(".q-head").getBoundingClientRect(), r = a && a.getBoundingClientRect(), cr = c.getBoundingClientRect();
      return { cls: c.className, href: a && a.getAttribute("href"), text: a && a.textContent, label: a && a.getAttribute("aria-label"),
               inHead: !!a && r.top >= h.top - 1 && r.bottom <= h.bottom + 1, rightEdge: a ? Math.round(cr.right - r.right) : null }; })""")
    by = {next(w for w in ("lane-subscription-1", "lane-subscription-2", "lane-api", "lane-bedrock", "lane-aws-platform") if w in c["cls"]): c for c in got}
    assert set(by) == {"lane-subscription-1", "lane-subscription-2", "lane-api", "lane-bedrock", "lane-aws-platform"}, got   # the two AWS spend cards too
    for lane, c in (("subscription-1", by["lane-subscription-1"]), ("subscription-2", by["lane-subscription-2"]), ("api", by["lane-api"]),
                    ("bedrock", by["lane-bedrock"]), ("aws-platform", by["lane-aws-platform"])):
        assert c["href"] == f"#lane={lane}" and c["text"] == "Details ›" and c["inHead"], c
        assert c["label"].startswith("Details of the ") and c["label"].endswith(" lane"), c
        # at the head's right end (the card pads 16 px); the API card has no Billing link here, it is on the details page
        assert c["rightEdge"] <= 20, c
    assert "q-dormant" in by["lane-subscription-2"]["cls"]
    # the dormant card is still a head and one line under it
    team = next(c for c in browser.evaluate(CARDS) if "lane-subscription-2" in c["cls"])
    assert team["line"] == "No seat since Mon Jan 5th" and team["lineTop"] >= team["headBottom"], team


def test_the_max_page_has_its_record_its_state_its_limits_and_its_own_sessions(stub_sala, world, page, browser):
    p = open_lane(browser, page())
    assert p["laneOpen"] and p["overviewOpen"] and p["shown"] and p["listHidden"] and p["hash"] == "#lane=subscription-1"
    assert p["name"] == "Lane ultra" and p["docTitle"] == "Lane ultra" and p["title"] == "ultraultra lane", p
    assert p["record"] == {"Provider": "anthropic", "Client": "claude-code", "Organization": "Example Org", "Billing": "Subscription",
                           "Plan": "Max 20x", "Account": "alex@example.com", "Signs in with": "Login"}, p["record"]
    assert p["chip"] == "active" and "lane-chip-active" in p["chipCls"] and p["line"] == "" and not p["lineShown"] and p["note"] == ""   # an active lane: a pill, no line
    assert not p["statusCard"]
    # the usage is the card's own: limits with bars, no link to itself
    assert p["usage"]["cards"] == 1 and p["usage"]["bars"] >= 1 and "12% used" in p["usage"]["text"] and p["usage"]["details"] == 0, p["usage"]
    assert p["usage"]["chips"] == [] and p["usage"]["headEnds"] == 0 and p["headPills"] == 1, p["usage"]   # the Usage card wears no status pill: the page head's is the one
    assert p["usage"]["emptyHeadKids"] == 0 and p["usage"]["pills"] == ["ultra"], p["usage"]            # no empty stand-in left in its head; the lane label stays
    assert "ultraMax (20x)" in p["usage"]["text"], p["usage"]                               # the plan name stays on the details page
    # only the sessions on this lane, in the overview's order, each a link to the session
    assert [s["link"] for s in p["sessions"]] == ["#s=on-max-a", "#s=on-max-b"] and p["count"] == "2 live sessions", p["sessions"]
    assert all("ultra" in s["lane"] for s in p["sessions"])
    # a phone: nothing wider than the screen, the Back chip touch-sized
    assert p["docScroll"] <= p["vw"] and p["paneScroll"] <= p["paneClient"] and p["right"] <= p["vw"], p
    assert p["back"] == {"href": "#sessions", "text": "Back", "h": p["back"]["h"]} and p["back"]["h"] >= 40, p["back"]
    assert world["calls"].count(TOKEN) == 2                                           # one usage check per lane, as the Overview makes them: the page asks nothing more


def test_the_api_page_has_the_spend_the_billing_link_and_the_sdk_sessions_and_no_path(stub_sala, world, page, browser):
    p = open_lane(browser, page(), "#lane=api", ready="document.querySelector('#ld-usage .c-figs')")
    assert p["name"] == "Lane metered" and p["title"] == "meteredmetered lane", p
    assert p["record"] == {"Provider": "anthropic", "Client": "claude-code", "Organization": "unconfirmed", "Billing": "Usage",
                           "Payment": "Prepaid", "Account": "alex@example.com", "Signs in with": "Key file + workspace id file"}, p["record"]
    assert "~" not in p["recordText"] and "/" not in p["recordText"] and "secret-name" not in p["recordText"]
    assert p["usage"]["figs"] == ["$1.00", "$2.00"] and p["usage"]["bill"] == ["https://platform.claude.com/settings/billing"], p["usage"]
    assert "Spent today" in p["usage"]["text"] and p["usage"]["details"] == 0 and p["usage"]["chips"] == []
    assert p["usage"]["emptyHeadKids"] == 0 and p["headPills"] == 1 and p["usage"]["pills"] == ["metered", "sdk"], p["usage"]   # the billing link is the card's only right end now
    assert [s["link"] for s in p["sessions"]] == ["#s=on-api", "#s=on-sdk"], p["sessions"]
    assert [s["lane"] for s in p["sessions"]] == ["metered", "sdk"], p["sessions"]     # the pill says which client
    assert world["spend"]                                                              # the figures are credit.py's, asked once for the card


def test_a_dormant_lane_says_so_and_why_and_its_usage_is_the_cards_one_line(stub_sala, world, page, browser):
    record(world["rec"], ("subscription-2", "dormant", "no seat", SINCE, "", "signal"))
    p = open_lane(browser, page(), "#lane=subscription-2", ready="document.querySelector('#ld-title .lane-chip-dormant')")
    assert p["chip"] == "dormant" and "lane-chip-dormant" in p["chipCls"], p
    assert p["line"] == "No usage check is made for it, and the New session form does not offer it." and "since" not in p["line"], p["line"]   # the day is on the card's line, not said twice
    assert p["usage"]["chips"] == [] and p["usage"]["headEnds"] == 0 and p["headPills"] == 1, p["usage"]   # no pill in the card's head, one in the page's
    assert p["usage"]["emptyHeadKids"] == 0, p["usage"]
    assert p["usage"]["dormant"] == ["No seat since Mon Jan 5th"] and p["usage"]["bars"] == 0, p["usage"]
    assert p["record"]["Organization"] == "ExampleOrg" and "Plan" not in p["record"]        # an empty field is left out
    assert [s["link"] for s in p["sessions"]] == ["#s=on-team"], p["sessions"]
    api = open_lane(browser, page(), "#lane=api", ready="document.querySelector('#ld-usage')")
    assert api["chip"] == "active" and api["line"] == ""                              # the others are not dormant


def test_a_dormant_per_use_lane_keeps_its_spend_on_its_page_and_does_not_say_no_check_is_made(stub_sala, world, page, browser):
    # only the account lanes (team, max) are asked nothing when dormant; api keeps its figures beside the reason
    record(world["rec"], ("api", "dormant", "credit used up", SINCE, "", "signal"))
    p = open_lane(browser, page(), "#lane=api", ready="document.querySelector('#ld-title .lane-chip-dormant') && document.querySelector('#ld-usage .c-month .c-v')")
    assert p["chip"] == "dormant" and p["line"] == "The New session form does not offer it.", p
    assert p["usage"]["dormant"] == ["No credit on the API key since Mon Jan 5th"], p["usage"]
    assert "$2.00" in p["usage"]["text"] and "No usage check" not in p["usage"]["text"], p["usage"]


def test_a_lane_not_set_up_shows_the_spend_card_saying_so(stub_sala, world, page, browser):
    p = open_lane(browser, page(), "#lane=bedrock")
    assert p["chip"] == "not configured" and "lane-chip-unconfigured" in p["chipCls"] and p["line"] == "No session can be put on this lane yet.", p
    assert p["record"]["Region"] == "us-east-1" and p["record"]["Payment"] == "Postpaid", p["record"]
    # the lane's spend card says in plain words that nothing is set up, with no chip of its own and no figures
    assert "Not set up on this machine." in p["usage"]["text"] and p["usage"]["cards"] == 1 and p["usage"]["chips"] == [], p["usage"]
    assert p["headPills"] == 1 and p["usage"]["emptyHeadKids"] == 0 and p["usage"]["headEnds"] == 0, p["usage"]
    assert p["usage"]["figs"] == [] and "No usage check" not in p["usage"]["text"], p["usage"]
    assert p["sessions"] == [{"text": "No live sessions on this lane.", "link": None, "lane": None}] and p["count"] == "0 live sessions"


def test_the_aws_platform_lane_s_record_shows_its_workspace_and_the_not_set_up_spend_card(stub_sala, world, page, browser):
    d = get(world, "aws-platform").json()
    assert d["lane"] == "aws-platform" and d["record"]["label"] == "Claude Platform on AWS" and d["record"]["provider"] == "anthropic"
    assert d["record"]["project"] == "wrkspc_01EXAMPLE" and d["record"]["credential"] == "AWS profile"   # the workspace id is no secret
    p = open_lane(browser, page(), "#lane=aws-platform")
    assert p["chip"] == "not configured" and "lane-chip-unconfigured" in p["chipCls"] and p["line"] == "No session can be put on this lane yet.", p
    assert p["record"]["Region"] == "us-east-1" and p["record"]["Payment"] == "Postpaid", p["record"]
    assert p["record"]["Project"] == "wrkspc_01EXAMPLE" and p["record"]["Provider"] == "anthropic", p["record"]
    assert "Not set up on this machine." in p["usage"]["text"] and p["usage"]["cards"] == 1 and p["usage"]["figs"] == [], p["usage"]   # the spend card
    assert p["title"] == "aws-platform" + "aws-platform lane", p["title"]        # the pill's label, then the lane word the labels use (not the record's own "Claude Platform on AWS")


def test_a_table_sala_cannot_print_blanks_one_section_and_not_the_page(stub_sala, world, page, browser):
    stub_sala.mode("fail")
    p = open_lane(browser, page(), "#lane=subscription-1", ready="document.querySelector('#ld-record .ld-none')")
    assert p["recordText"] == "The lane record is not available just now." and p["record"] is None, p
    assert "could not be read just now (sala exited 1)" in p["note"] and p["chip"] is None and p["line"].startswith("Not available just now"), p
    assert p["usage"]["bars"] >= 1 and len(p["sessions"]) == 2                          # usage and sessions are the cards' answers
    # it comes back with the next ask: the quota timer, or the page being shown again
    stub_sala.mode("ok")
    browser.evaluate("document.dispatchEvent(new Event('visibilitychange')); ''")
    assert wait_for(browser, "!!document.querySelector('#ld-record dl') && document.querySelector('#ld-note').textContent === ''")


def test_an_unknown_lane_says_so(stub_sala, world, page, browser):
    p = open_lane(browser, page(), "#lane=nope", ready="document.querySelector('#ld-record .ld-none')")
    assert p["recordText"] == "sala's lane table has no lane called nope." and p["note"] == "", p
    assert p["usage"]["text"] == "No usage check is made for this lane." and p["title"].endswith("nope lane")


# ── Back ─────────────────────────────────────────────────────────────────────
def test_in_a_browser_the_details_link_pushes_and_the_back_button_is_the_browsers_back(stub_sala, served, browser):
    open_app(browser, served, "#sessions", width=1280)
    tap(browser, "a.q-details[href='#lane=subscription-1']")
    h = hist(browser)
    assert h["hash"] == "#lane=subscription-1" and h["overview"] and h["entries"] == ["#sessions", "#lane=subscription-1"] and h["i"] == 1, h
    assert wait_for(browser, "document.body.classList.contains('lane-open')")
    tap(browser, "#ld-back")
    h = hist(browser)
    assert h["hash"] == "#sessions" and h["entries"] == ["#sessions", "#lane=subscription-1"] and h["i"] == 0, h   # back, not a third entry
    assert browser.evaluate("!document.body.classList.contains('lane-open')") and h["name"] == "Overview"
    assert forward(browser)["hash"] == "#lane=subscription-1"                                       # Forward re-opens the lane page
    assert back(browser)["hash"] == "#sessions"                                          # and the browser's own Back is the same walk


def test_a_lane_page_opened_by_its_address_has_no_overview_under_it_so_back_pushes_one(stub_sala, served, browser):
    open_app(browser, served, "#lane=subscription-2", width=1280)
    h = hist(browser)
    assert h["hash"] == "#lane=subscription-2" and h["overview"] and h["entries"] == ["#lane=subscription-2"], h
    assert browser.evaluate("document.querySelector('#title .name').textContent") == "Lane team"
    tap(browser, "#ld-back")
    h = hist(browser)
    assert h["hash"] == "#sessions" and h["entries"] == ["#lane=subscription-2", "#sessions"] and h["i"] == 1, h
    assert back(browser)["hash"] == "#lane=subscription-2"


def test_on_a_phone_the_lane_page_replaces_the_view_and_one_back_leaves(stub_sala, served, browser):
    open_app(browser, served, "#sessions", width=390)
    assert wait_for(browser, "document.readyState !== 'loading' && !!document.getElementById('q-strip') && getComputedStyle(document.getElementById('q-strip')).display !== 'none'")
    tap(browser, "#q-strip")     # a phone folds the lane cards into one chip strip: a tap opens them
    assert wait_for(browser, "document.getElementById('quota').classList.contains('q-open')")
    tap(browser, "a.q-details[href='#lane=api']")
    h = hist(browser)
    assert h["hash"] == "#lane=api" and h["entries"] == ["#lane=api"] and h["replace"], h        # one entry, replaced
    tap(browser, "#ld-back")
    h = hist(browser)
    assert h["hash"] == "#sessions" and h["entries"] == ["#sessions"] and h["name"] == "Overview", h
    tap(browser, "a.q-details[href='#lane=subscription-1']")
    assert hist(browser)["hash"] == "#lane=subscription-1"
    assert back(browser)["left"]      # Back left sala: nothing walked between the views


def test_a_session_opened_from_the_lane_page_comes_back_to_it_in_a_browser(stub_sala, served, browser):
    open_app(browser, served, "#sessions", width=1280)
    tap(browser, "a.q-details[href='#lane=subscription-1']")
    assert wait_for(browser, "!!document.querySelector('#ld-table a[href^=\"#s=\"]')")
    tap(browser, "#ld-table a[href^='#s=']")
    h = hist(browser)
    assert h["hash"].startswith("#s=") and not h["overview"], h
    h = back(browser)
    assert h["hash"] == "#lane=subscription-1" and h["overview"] and wait_for(browser, "document.body.classList.contains('lane-open')"), h


def test_a_reload_keeps_the_lane_page(stub_sala, served, browser):
    open_app(browser, served, "#lane=subscription-1", width=1280)
    browser.send("Page.reload")
    assert wait_for(browser, "typeof nav !== 'undefined' && !!nav.cur && document.body.classList.contains('lane-open') && !!document.querySelector('#ld-record dl')", 15.0)
    settle(browser)
    assert hist(browser)["hash"] == "#lane=subscription-1"
