"""Quick sessions in the web UI (quick side conversations, renamed Quick session in lib/spawn.sh A SIDE SESSION, web/README.md,
*Quick sessions*). A quick session goes through the New session page's queue (`POST /api/spawn` -> `sala op spawn NAME
--side …`), with its own form under the hash `#side=…`:
  · the Discuss link of stackshot, https://sala.example.test/#side=<id>, where the id is everything after "side=" in any form the
    board shows (an older s9, a temporary board-tmp-box#3, which holds a "#" itself): the form opens with the item
    filled in, its project and owner looked up from stackshot (`GET /api/spawn/item`);
  · the link #side=from:<name>: a fork of that session (no button in the header: its fold is measured to the pixel).

What a wrong answer costs: a session started about another item or project than the link named, a fork of the wrong agent, a role or
an agents-map line the side session must not have, a blank name that never gets a name, an id with a "#" cut short by the router
or lost on the way to sala, a shape the backend would refuse sent to it anyway, or the page's New session form broken by the new
one. Every check guards one of those. Nothing here runs sala: `sala` is the stand-in of test_new_session.py; stackshot is the fake
of fake_stackshot.py; the browser tests run in a headless Chromium (conftest.py: `served`, `browser`)."""

from __future__ import annotations

import json

import pytest

from test_board_items_ui import wait_for
from test_new_session import APP_JS, FAKE, INDEX, OP, README, STATIC, WORDS_RE, click, open_page, set_value  # noqa: F401
from test_new_session import env, sala  # noqa: F401  (fixtures)

SIDE_WORDS_RE_PART = "Rowan, via the sala web form: new side conversation "


# ── the server ───────────────────────────────────────────────────────────────
def test_a_fresh_start_about_an_item_is_queued_as_side_with_no_role(env):
    c, s = env["client"], env["sala"]
    body = {"side": True, "project": "projects/gamma-harbor", "item": "board#38", "agents": "demo-builder,gamma-harbor-main",
            "name": "gamma-harbor-side-wren42", "mandate": "Only the deploy question."}
    r = c.post("/api/spawn", json=body)
    assert r.status_code == 202, r.text
    assert r.json()["ok"] and r.json()["op"] == OP and r.json()["side"] is True and r.json()["role"] == ""
    (rec,) = s.spawns()
    argv = rec["argv"]
    path = argv[argv.index("--mandate") + 1]
    assert argv == ["op", "spawn", "gamma-harbor-side-wren42", "--side", "--project", "projects/gamma-harbor", "--item", "board#38", "--agents",
                    "demo-builder,gamma-harbor-main", "--mandate", path, "--from", "sala-web", "--words", argv[-1]]
    assert "--role" not in argv
    assert argv[-1].startswith(SIDE_WORDS_RE_PART + "gamma-harbor-side-wren42 (about board#38 in projects/gamma-harbor), ") and argv[-1].endswith(" +04")
    assert rec["mandate"] == "Only the deploy question.\n"


def test_a_fork_is_queued_with_fork_of_and_no_project(env):
    c, s = env["client"], env["sala"]
    r = c.post("/api/spawn", json={"side": True, "fork_of": "demo-main", "name": "demo-main-side-onyx07", "item": "s9"})
    assert r.status_code == 202, r.text
    argv = s.spawns()[-1]["argv"]
    assert argv == ["op", "spawn", "demo-main-side-onyx07", "--side", "--fork-of", "demo-main", "--item", "s9", "--from", "sala-web", "--words", argv[-1]]
    assert "(a fork of demo-main, about s9)" in argv[-1]


@pytest.mark.parametrize("item", ["board#38", "s9", "board-tmp-box#3", "a5"])
def test_every_form_of_the_item_id_is_passed_whole(env, item):
    """The id may itself hold a "#": it reaches sala as one argument, unchanged."""
    r = env["client"].post("/api/spawn", json={"side": True, "project": "projects/demo", "item": item, "name": "demo-side-wren42"})
    assert r.status_code == 202, r.text
    argv = env["sala"].spawns()[-1]["argv"]
    assert argv[argv.index("--item") + 1] == item


def test_a_blank_name_is_the_one_sala_suggests(env):
    c, s = env["client"], env["sala"]
    r = c.post("/api/spawn", json={"side": True, "project": "projects/demo", "item": "board#38"})
    assert r.status_code == 202, r.text
    assert r.json()["name"] == "demo-side-wren42"
    assert s.records()[-2]["argv"] == ["spawn", "--suggest-name", "--side", "--project", "projects/demo"]
    assert s.spawns()[-1]["argv"][2] == "demo-side-wren42"
    r = c.post("/api/spawn", json={"side": True, "fork_of": "gamma-harbor-main", "name": ""})
    assert r.status_code == 202 and r.json()["name"] == "gamma-harbor-main-side-wren42"
    assert s.records()[-2]["argv"] == ["spawn", "--suggest-name", "--side", "--fork-of", "gamma-harbor-main"]


def test_the_suggested_name_of_a_side_conversation(env):
    c, s = env["client"], env["sala"]
    assert c.get("/api/spawn/suggest", params={"side": "1", "fork_of": "demo-main"}).json() == {"name": "demo-main-side-wren42"}
    assert c.get("/api/spawn/suggest", params={"side": "1", "project": "projects/demo"}).json() == {"name": "demo-side-wren42"}
    n = len(s.records())
    assert c.get("/api/spawn/suggest", params={"side": "1"}).status_code == 400
    assert c.get("/api/spawn/suggest", params={"side": "1", "project": "sala"}).status_code == 400
    assert c.get("/api/spawn/suggest", params={"side": "1", "fork_of": "x; id"}).status_code == 400
    assert len(s.records()) == n   # a bad shape never reaches sala


@pytest.mark.parametrize("body", [
    {"side": True},                                                                           # nothing to be about
    {"side": True, "project": "projects/demo"},                                                  # a project without its item
    {"side": True, "project": "projects/demo", "item": "38"},                                   # not an id as the board shows it
    {"side": True, "project": "projects/demo", "item": "board#"},
    {"side": True, "project": "projects/demo", "item": "board#38; id"},
    {"side": True, "project": "projects/demo", "item": "board#38", "role": "front"},            # a side session has no role
    {"side": True, "project": "projects/demo", "item": "board#38", "fork_of": "demo-main"},   # a fork takes no project
    {"side": True, "fork_of": "demo-main", "agents": "a"},                              # nor agents
    {"side": True, "fork_of": "Demo Main"},
    {"side": True, "project": "notes/x", "item": "board#38"},
    {"side": True, "project": "projects/demo", "item": "board#38", "agents": "A B"},
    {"side": True, "project": "projects/demo", "item": "board#38", "name": "demo-main"},       # a name without -side-
    {"side": True, "project": "projects/demo", "item": "board#38", "name": "Example-Side-X"},
    {"side": True, "project": "projects/demo", "item": "board#38", "lane": "sdk"},
    {"side": "yes", "project": "projects/demo", "item": "board#38"},
    {"project": "projects/demo", "role": "front", "name": "demo-main", "item": "board#38"},   # an item without side
    {"project": "projects/demo", "role": "front", "name": "demo-main", "fork_of": "x"},
])
def test_a_shape_the_backend_refuses_never_reaches_sala(env, body):
    r = env["client"].post("/api/spawn", json=body)
    assert r.status_code == 400, (body, r.status_code, r.text)
    assert env["sala"].spawns() == []


def test_the_item_lookup_fills_the_project_and_owner(env):
    c, ss = env["client"], env["ss"]
    r = c.get("/api/spawn/item", params={"id": "board#38"})
    assert r.status_code == 200 and r.headers["cache-control"] == "no-store"
    assert r.json() == {"ok": True, "item": "board#38", "project": "projects/demo", "owner": "demo-builder", "status": "open"}
    q = [x for x in ss.requests if x["path"] == "/client/item-facts"][-1]["query"]
    assert q["ids"] == "g38" and q["key"] == "sala-web"            # the store id: board#N -> gN
    assert c.get("/api/spawn/item", params={"id": "s9"}).json()["project"] == "projects/gamma-harbor"
    assert [x for x in ss.requests if x["path"] == "/client/item-facts"][-1]["query"]["ids"] == "s9"
    r = c.get("/api/spawn/item", params={"id": "board-tmp-box#3"}).json()
    assert r["project"] == "projects/beta-web" and r["owner"] == "" and r["status"] == "closed"   # an owner that is no agent name is left out
    assert [x for x in ss.requests if x["path"] == "/client/item-facts"][-1]["query"]["ids"] == "l3"
    assert c.get("/api/spawn/item", params={"id": "board#81"}).status_code == 404
    n = len(ss.requests)
    assert c.get("/api/spawn/item", params={"id": "999"}).status_code == 400
    assert c.get("/api/spawn/item", params={"id": "board#9001,g2"}).status_code == 400
    assert len(ss.requests) == n


def test_the_markup_and_the_rules_the_code_keeps():
    assert 'id="sd-form"' in INDEX and 'id="np-switch"' in INDEX and 'id="np-new"' in INDEX and 'id="np-quick"' in INDEX
    assert 'name="sd-kind"' not in INDEX                                              # no radios: the two fields are optional and independent
    assert 'id="sd-item-pick"' in INDEX and 'id="sd-fork-pick"' in INDEX
    assert "sd-role" not in INDEX and 'name="sd-role"' not in INDEX                    # a quick session has no role
    form_ns = INDEX[INDEX.index('<form id="ns-form"'):INDEX.index("</form>", INDEX.index('<form id="ns-form"'))]
    form_sd = INDEX[INDEX.index('<form id="sd-form"'):INDEX.index("</form>", INDEX.index('<form id="sd-form"'))]
    assert 'href="#side="' not in form_ns and 'href="#new"' not in form_sd               # the switch at the top replaced the loose links
    assert "Side conversation" not in INDEX and "Side conversation" not in APP_JS         # the name the owner uses is Quick session
    start = APP_JS.index("/* QUICK SESSIONS (")
    section = APP_JS[start:APP_JS.index("sdEl.name.addEventListener", start)]
    assert ".innerHTML" not in section and "insertAdjacentHTML" not in section
    assert 'nsPost("api/spawn", body)' in section
    assert "\"from:\"" in APP_JS and "const sideHash" in APP_JS
    assert "Quick session" in README and "Side conversations" not in README


# ── the page ─────────────────────────────────────────────────────────────────
FORM = """(() => {
  const q = (s) => document.querySelector(s), v = (s) => q(s).value, vis = (s) => getComputedStyle(q(s)).display !== "none";
  const sw = q("#np-switch").getBoundingClientRect(), pane = q("#new-pane").getBoundingClientRect();
  return { sideMode: document.body.classList.contains("side-mode"), newOpen: document.body.classList.contains("new-open"),
    sdVisible: vis("#sd-form"), nsVisible: vis("#ns-form"), title: q("#title .name").textContent, hash: location.hash,
    item: v("#sd-item"), project: v("#sd-project"), agents: v("#sd-agents"),
    fork: v("#sd-fork"), name: v("#sd-name"), nameErr: q("#sd-name-err").textContent, note: q("#sd-note").textContent,
    need: q("#sd-need").textContent, extraVisible: !q("#sd-item-extra").hidden, submitDisabled: q("#sd-submit").disabled,
    submitText: q("#sd-submit").textContent,
    itemSummary: q("#sd-item-pick .ns-sum").textContent, forkSummary: q("#sd-fork-pick .ns-sum").textContent,
    state: (q("#sd-status .ns-state") || {}).textContent || "", status: q("#sd-status").innerText,
    link: q("#sd-status a.ns-link") ? q("#sd-status a.ns-link").getAttribute("href") : null,
    projects: [...document.querySelectorAll("#sd-projects option")].map((o) => o.value),
    switchTop: sw.top - pane.top, switchBox: sw.toJSON(), switchFirst: q("#new-pane").firstElementChild.id,
    chips: [...document.querySelectorAll("#np-switch .ns-chip")].map((a) => ({ id: a.id, text: a.textContent, current: a.getAttribute("aria-current"), w: a.getBoundingClientRect().width })),
    docScroll: document.documentElement.scrollWidth, vw: document.documentElement.clientWidth };
})()"""

ITEMS = {"demo-builder": {"items": [{"id": "board#38", "subject": "Side chat basics"}, {"id": "board#39", "subject": "Form layout"}]},
         "gamma-harbor-main": {"items": [{"id": "s9", "subject": "Shelf layout"}]}}


def form(browser) -> dict:
    return browser.evaluate(FORM)


def open_hash(browser, served, hash_: str, width=1280, height=800) -> None:
    open_page(browser, served, width, height)
    browser.evaluate(f"location.hash = {json.dumps(hash_)}; ''")


def settle(browser, cond: str, timeout: float = 10.0) -> dict:
    assert wait_for(browser, cond, timeout), form(browser)
    return form(browser)


def give_items(browser) -> None:
    """The board answers with open items for two live sessions; the page's own loader reads them (the pickers list them)."""
    browser.evaluate(f"window.__items = {json.dumps(ITEMS)}; loadBoard(); ''")
    assert wait_for(browser, "Object.keys(board.sessions).length === 2", 5.0)


def open_picker(browser, which: str) -> None:
    click(browser, f"#sd-{which}-pick .ns-sum")
    assert wait_for(browser, f"!document.querySelector('#sd-{which}-pick .ns-panel').hidden", 5.0)


def rows(browser, which: str) -> list[dict]:
    return browser.evaluate(f"""[...document.querySelectorAll('#sd-{which}-pick .ns-list .ns-opt')].map((b) => ({{ key: b.dataset.key, text: b.textContent, typed: b.classList.contains('ns-new') }}))""")


@pytest.mark.parametrize("item, project, owner", [
    ("board#38", "projects/demo", "demo-builder"),
    ("s9", "projects/gamma-harbor", ""),
    ("board-tmp-box#3", "projects/beta-web", ""),
])
def test_the_discuss_link_opens_the_form_with_the_item_whatever_its_form(sala, served, browser, item, project, owner):
    open_hash(browser, served, "#side=" + item)
    g = settle(browser, "document.querySelector('#sd-project').value !== '' && document.querySelector('#sd-name').value !== ''")
    assert g["sideMode"] and g["newOpen"] and g["sdVisible"] and not g["nsVisible"] and g["title"] == "Quick session", g
    assert g["item"] == item and g["project"] == project and g["agents"] == owner and g["fork"] == "", g   # the whole id, "#" and all
    assert item in g["itemSummary"] and g["extraVisible"] and not g["submitDisabled"], g
    assert g["name"].endswith("-side-wren42"), g
    assert g["hash"] == "#side=" + item
    assert g["docScroll"] <= g["vw"], g


def test_a_submit_queues_the_quick_session_and_the_link_appears(sala, served, browser):
    open_hash(browser, served, "#side=board#38")
    settle(browser, "document.querySelector('#sd-project').value !== '' && !document.querySelector('#sd-submit').disabled")
    set_value(browser, "#sd-mandate", "Only the deploy question.")
    click(browser, "#sd-submit")
    g = settle(browser, "(document.querySelector('#sd-status .ns-state') || {}).textContent?.includes('Queued')")
    (rec,) = sala.spawns()
    argv = rec["argv"]
    assert argv[:6] == ["op", "spawn", "demo-side-wren42", "--side", "--project", "projects/demo"] and argv[argv.index("--item") + 1] == "board#38", argv
    assert argv[argv.index("--agents") + 1] == "demo-builder" and "--role" not in argv, argv
    assert rec["mandate"] == "Only the deploy question.\n"
    # the session appears in the list: the link to it
    browser.evaluate("window.__names.push('demo-side-wren42'); loadSessions(); ''")
    g = settle(browser, "(document.querySelector('#sd-status .ns-state') || {}).textContent?.endsWith('Ready')", 15.0)
    assert g["link"] == "#s=demo-side-wren42", g


def test_the_fork_link_opens_the_form_for_a_fork_of_that_session(sala, served, browser):
    # no Fork button in the session header: the header's fold is measured to the pixel (test_header_fold.py) and has no room for one
    open_hash(browser, served, f"#side=from:{FAKE}")
    g = settle(browser, "document.body.classList.contains('side-mode') && document.querySelector('#sd-name').value !== ''")
    assert g["fork"] == FAKE and FAKE in g["forkSummary"] and g["item"] == "" and not g["extraVisible"], g
    assert g["name"] == f"{FAKE}-side-wren42" and not g["submitDisabled"] and g["need"] == "", g
    click(browser, "#sd-submit")
    settle(browser, "(document.querySelector('#sd-status .ns-state') || {}).textContent?.includes('Queued')")
    argv = sala.spawns()[-1]["argv"]
    assert argv[:5] == ["op", "spawn", f"{FAKE}-side-wren42", "--side", "--fork-of"] and argv[5] == FAKE and "--project" not in argv and "--item" not in argv, argv


def test_the_switch_is_at_the_top_of_both_forms_and_there_are_no_loose_links(sala, served, browser):
    open_page(browser, served, 1280, 800)
    click(browser, "#side-new")
    assert wait_for(browser, "document.body.classList.contains('new-open')", 5.0)
    g = form(browser)
    assert g["newOpen"] and not g["sideMode"] and g["nsVisible"] and not g["sdVisible"] and g["title"] == "New session" and g["hash"] == "#new", g
    assert g["switchFirst"] == "np-switch" and g["switchTop"] <= 24, g           # the very top of the page, above both forms
    assert [(c["text"], c["current"]) for c in g["chips"]] == [("New session", "page"), ("Quick session", None)], g
    new_box = g["switchBox"]
    # no loose text link left in either form
    assert browser.evaluate("document.querySelectorAll('#ns-form a[href=\"#side=\"], #sd-form a[href=\"#new\"]').length") == 0
    click(browser, "#np-quick")
    g = settle(browser, "document.body.classList.contains('side-mode')")
    assert g["sdVisible"] and not g["nsVisible"] and g["hash"] == "#side=" and g["submitDisabled"] and g["title"] == "Quick session", g   # a blank form: nothing to submit yet
    assert [(c["text"], c["current"]) for c in g["chips"]] == [("New session", None), ("Quick session", "page")], g
    assert g["switchBox"] == new_box and g["switchFirst"] == "np-switch", (g["switchBox"], new_box)   # the same switch, in the same place
    click(browser, "#np-new")
    g = settle(browser, "!document.body.classList.contains('side-mode')")
    assert g["nsVisible"] and not g["sdVisible"] and g["title"] == "New session" and g["hash"] == "#new", g
    # the segmented look is the scope selector's: the same chip class, the current one coloured as a checked scope is, the same height
    got = browser.evaluate("""(() => { const cur = document.querySelector('#np-new'), other = document.querySelector('#np-quick'),
      on = document.querySelector('#ns-scopes .ns-chip[aria-checked="true"]'), off = document.querySelector('#ns-scopes .ns-chip[aria-checked="false"]'), cs = (e) => getComputedStyle(e);
      return { curBg: cs(cur).backgroundColor, onBg: cs(on).backgroundColor, otherBg: cs(other).backgroundColor, offBg: cs(off).backgroundColor, curColor: cs(cur).color, onColor: cs(on).color,
               h: [cur, other, on, off].map((e) => Math.round(e.getBoundingClientRect().height)) }; })()""")
    assert got["curBg"] == got["onBg"] and got["curColor"] == got["onColor"] and got["otherBg"] == got["offBg"] and got["curBg"] != got["otherBg"], got
    assert min(got["h"]) >= 32 and max(got["h"]) - min(got["h"]) <= 4, got   # the look's control height under a mouse (32 px; 44 px under a thumb); these 36 on a desktop to keep the form on one screen


def test_the_item_and_the_fork_are_both_optional_and_independent(sala, served, browser):
    open_hash(browser, served, "#side=")
    g = settle(browser, "document.body.classList.contains('side-mode')")
    # neither: the form says what it needs and the button waits
    assert g["submitDisabled"] and "Pick a board item, a session to fork, or both" in g["need"] and g["item"] == "" and g["fork"] == "", g
    assert g["submitText"] == "Start quick session" and not g["extraVisible"], g
    # the item picker lists the open items of the live sessions, newest number first, each with its subject and owner
    give_items(browser)
    open_picker(browser, "item")
    r = rows(browser, "item")
    assert [x["key"] for x in r] == ["board#39", "board#38", "s9"] and "Form layout" in r[0]["text"] and "demo-builder" in r[0]["text"], r
    # the search box narrows by id, subject or owner; an id typed in full can be used as it is
    set_value(browser, "#sd-item-pick input[type=search]", "shelf")
    assert [x["key"] for x in rows(browser, "item")] == ["s9"]
    set_value(browser, "#sd-item-pick input[type=search]", "board#81")
    r = rows(browser, "item")
    assert [(x["key"], x["typed"]) for x in r] == [("board#81", True)], r
    set_value(browser, "#sd-item-pick input[type=search]", "38")
    assert [x["key"] for x in rows(browser, "item")] == ["board#38"]
    click(browser, '#sd-item-pick .ns-opt[data-key="board#38"]')
    g = settle(browser, "document.querySelector('#sd-project').value !== '' && document.querySelector('#sd-name').value !== ''")
    # an item alone: its project and owner are looked up, the folded picker says which one, the project fields show
    assert g["item"] == "board#38" and "board#38" in g["itemSummary"] and g["project"] == "projects/demo" and g["extraVisible"] and not g["submitDisabled"], g
    assert g["name"] == "demo-side-wren42" and g["hash"] == "#side=", g       # choosing in the form does not rewrite the link
    # the fork picker lists the running sessions; choosing one beside the item keeps both (the item as the topic of the fork)
    open_picker(browser, "fork")
    r = rows(browser, "fork")
    assert [x["key"] for x in r] == [FAKE] and "projects/demo" in r[0]["text"], r
    click(browser, f'#sd-fork-pick .ns-opt[data-key="{FAKE}"]')
    g = settle(browser, f"document.querySelector('#sd-name').value === '{FAKE}-side-wren42'")
    assert g["fork"] == FAKE and g["item"] == "board#38" and not g["extraVisible"] and not g["submitDisabled"], g   # a fork takes no project
    click(browser, "#sd-submit")
    settle(browser, "(document.querySelector('#sd-status .ns-state') || {}).textContent?.includes('Queued')")
    argv = sala.spawns()[-1]["argv"]
    assert argv[:6] == ["op", "spawn", f"{FAKE}-side-wren42", "--side", "--fork-of", FAKE] and argv[argv.index("--item") + 1] == "board#38" and "--project" not in argv, argv
    sala.marker("stuck", "stopped by the test", done=True)   # Start works until the session is ready or has failed
    settle(browser, "(document.querySelector('#sd-status .ns-state') || {}).textContent?.endsWith('Did not start')", 15.0)
    # clear the item (the x beside it): the fork alone is enough
    click(browser, "#sd-item-pick .ns-clear")
    g = form(browser)
    assert g["item"] == "" and g["fork"] == FAKE and "none chosen" in g["itemSummary"], g
    settle(browser, "!document.querySelector('#sd-submit').disabled")
    # clear the fork too: nothing left, the need comes back
    click(browser, "#sd-fork-pick .ns-clear")
    g = form(browser)
    assert g["fork"] == "" and g["submitDisabled"] and "Pick a board item" in g["need"], g


def test_an_item_alone_needs_its_project_said_in_words(sala, served, browser):
    open_hash(browser, served, "#side=")
    settle(browser, "document.body.classList.contains('side-mode')")
    open_picker(browser, "item")
    set_value(browser, "#sd-item-pick input[type=search]", "board#81")
    click(browser, '#sd-item-pick .ns-opt[data-key="board#81"]')       # an item stackshot does not know: no project can be looked up
    g = settle(browser, "document.querySelector('#sd-note').textContent.includes('board#81')")
    assert g["extraVisible"] and g["submitDisabled"] and "needs its project page" in g["need"], g
    set_value(browser, "#sd-project", "projects/demo")
    g = form(browser)
    assert not g["submitDisabled"] and g["need"] == "", g


def test_a_name_without_side_is_refused_in_the_form(sala, served, browser):
    open_hash(browser, served, "#side=board#38")
    # the page puts the suggested name into the field once sala has answered (after the item lookup enabled the button): typing
    # before that lands the suggestion between the field's select and the typed text, which then follows it instead of replacing it
    settle(browser, "!document.querySelector('#sd-submit').disabled && document.querySelector('#sd-name').value !== ''")
    set_value(browser, "#sd-name", "demo-main")
    g = settle(browser, "document.querySelector('#sd-name-err').textContent.includes('-side-')")
    assert g["name"] == "demo-main" and g["submitDisabled"], g
    set_value(browser, "#sd-name", "")
    g = settle(browser, "!document.querySelector('#sd-submit').disabled")          # blank = suggested
    assert g["name"] == "" and g["nameErr"] == "", g
    assert sala.spawns() == []


def test_a_refusal_shows_the_reason_in_the_form(sala, served, browser):
    sala.mode("refuse")
    open_hash(browser, served, f"#side=from:{FAKE}")
    settle(browser, "!document.querySelector('#sd-submit').disabled")
    click(browser, "#sd-submit")
    assert wait_for(browser, "(document.querySelector('#sd-status pre') || {}).textContent?.includes('live already')", 10.0), form(browser)
    g = form(browser)
    assert g["state"] == "Not started" and "Why" in g["status"] and "✗ refused" in g["status"], g
    assert not g["submitDisabled"]                       # usable again for the retry


def test_a_phone_has_no_sideways_scroll(sala, served, browser):
    open_hash(browser, served, "#side=board-tmp-box#3", 320, 700)
    g = settle(browser, "document.querySelector('#sd-project').value !== ''")
    assert g["sdVisible"] and g["docScroll"] <= g["vw"] == 320, g
