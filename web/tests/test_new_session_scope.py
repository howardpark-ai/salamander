"""The New session form's project step in a browser (Sat Oct 24th 2026): the scope, the one box with its hidden
matches and its "+ New project" row, and what Create does for each kind of pick, step by step.

What a wrong answer costs here is a project or an agent the owner did not mean (a page made in the wrong scope or under a name
that is not what he typed), a page made twice (a double tap, a retry that repeats a step that was done), a session
queued before its project and agent exist, or a failure he cannot read (a step that stops with no word of why, a raw error
as the only text, the copy-this-to-the-page block that is gone for good). Every check guards one of those. Nothing runs
sala, stackshot, gbrain or tmux: the queue is a stand-in script, stackshot a fake on 127.0.0.1 (fake_stackshot.py, which
refuses a first agent from a label that did not make or list the project, as stackshot does), the page a headless Chromium
(conftest.py: `served`, `browser`)."""

from __future__ import annotations

import json
import time

import fake_stackshot as FS
from test_board_items_ui import wait_for
from test_new_session import click, ns, open_form, pick, set_scope, set_value, unfold, wait_state
from test_new_session import sala  # noqa: F401  (fixture)

ORDER_JS = ("JSON.stringify([...document.querySelector('#ns-projects').children].map("
            "(c) => (c.classList.contains('ns-divider') ? '--divider--' : c.dataset.key || '(empty)')))")


def name_is(name: str) -> str:
    return f"document.querySelector('#ns-name').value === {json.dumps(name)}"


def type_filter(browser, text: str) -> None:
    unfold(browser)   # a chosen project folded the box; typing a name for another one starts with opening it again
    set_value(browser, "#ns-filter", text)


def wait_order(browser, expected: list[str], timeout: float = 10.0) -> dict:
    """The box's children (the divider as `--divider--`, a message as `(empty)`) once they are the expected ones: typing settles
    for a moment before stackshot is asked for the hidden matches."""
    want = json.dumps(expected, separators=(",", ":"), ensure_ascii=False)   # JSON.stringify's spelling
    ok = wait_for(browser, f"{ORDER_JS} === {json.dumps(want)}", timeout)
    g = ns(browser)
    assert ok, (expected, g["order"])
    return g


def calls(sala, which: str) -> list[dict]:
    return sala.ss.calls("/client/" + which)


# ── the box ──────────────────────────────────────────────────────────────────
def test_hidden_matches_show_below_a_divider_only_for_a_typed_query_and_a_note_page_is_not_offered(sala, served, browser):
    open_form(browser, served, scope="gamma")
    g = ns(browser)
    assert g["order"] == ["projects/gamma-harbor", "projects/gamma-pantry", "__new__"] and g["divider"] is None, g
    assert all("q" not in c["query"] for c in sala.ss.calls("/client/projects"))   # nothing typed: no hidden page is asked for
    type_filter(browser, "kayak")
    # no listed project holds "kayak": the divider, the scope's hidden `type: project` pages that do (stackshot also sent a note
    # page, which the form drops), and "+ New project" last
    g = wait_order(browser, ["--divider--", "projects/gamma-old-kayak", "__new__"])
    assert g["divider"] == "existing pages, not listed" and g["disabledRows"] == [], g
    assert sala.ss.calls("/client/projects")[-1]["query"] == {"scope": "gamma", "q": "kayak"}
    assert "projects/gamma-kayak-notes" not in [r["key"] for r in g["rows"]]
    assert g["rows"][-1]["text"] == '+ New project "kayak"kayak' and g["empty"] is None, g
    # a listed match stays above the divider, the hidden one below it
    type_filter(browser, "pantry")
    wait_order(browser, ["projects/gamma-pantry", "--divider--", "projects/gamma-pantry-2019", "__new__"])
    # a query nothing matches shows no divider
    type_filter(browser, "zzz")
    g = wait_order(browser, ["(empty)", "__new__"])
    assert g["divider"] is None and g["empty"] == "No listed project matches."
    # clearing the box brings the plain list back, without the hidden pages
    type_filter(browser, "")
    g = wait_order(browser, ["projects/gamma-harbor", "projects/gamma-pantry", "__new__"])
    assert g["disabledRows"] == ["__new__"]
    # another scope never shows this scope's hidden pages
    type_filter(browser, "old")
    wait_order(browser, ["--divider--", "projects/gamma-old-kayak", "__new__"])
    set_scope(browser, "example")
    g = wait_order(browser, ["--divider--", "projects/old-box", "__new__"])
    assert sala.ss.calls("/client/projects")[-1]["query"] == {"scope": "example", "q": "old"}
    assert calls(sala, "project") == [] and calls(sala, "project-list") == [] and calls(sala, "project-agent") == []   # looking changes nothing


def test_the_new_project_row_follows_the_typed_name_and_gives_way_to_a_project_that_exists(sala, served, browser):
    open_form(browser, served, scope="beta")
    type_filter(browser, "Fresh Idea")
    g = wait_order(browser, ["(empty)", "__new__"])
    assert g["rows"][-1]["text"] == '+ New project "Fresh Idea"fresh-idea', g["rows"]
    pick(browser, "__new__")
    # the name is the one stackshot gives a new page's agents: <scope>-<slug>-main (-main for its first front agent, a random word otherwise)
    assert wait_for(browser, name_is("beta-fresh-idea-main")), ns(browser)
    g = ns(browser)
    assert g["rows"][-1]["sel"] == "true" and not g["submitDisabled"], g
    assert g["picked"] == ("Create will make fresh-idea (beta; its page is written through gbrain and can take a few minutes), "
                           "add beta-fresh-idea-main to it, then start the session."), g["picked"]
    click(browser, 'input[name="ns-role"][value="back"]')
    assert wait_for(browser, name_is("beta-fresh-idea-pink")), ns(browser)
    click(browser, 'input[name="ns-role"][value="front"]')
    assert wait_for(browser, name_is("beta-fresh-idea-main")), ns(browser)
    # typing more changes the project it would make; a slug that starts with the scope is its own name
    type_filter(browser, "beta docs 2")
    assert wait_for(browser, name_is("beta-docs-2-main")), ns(browser)
    assert "make docs-2 (beta" in ns(browser)["picked"]
    # example (a page dir too, here) makes example/<slug>
    set_scope(browser, "example")
    type_filter(browser, "New Box")
    wait_order(browser, ["(empty)", "__new__"])
    pick(browser, "__new__")
    assert wait_for(browser, name_is("example-new-box-main")), ns(browser)
    assert "make new-box (example" in ns(browser)["picked"]
    # nothing but Korean has no slug: the row asks for a name, and Create stays off
    type_filter(browser, "한글 이름")
    g = ns(browser)
    assert g["submitDisabled"] and g["picked"] == "A project name needs letters or digits (a to z, 0 to 9)." and g["rows"][-1]["text"].startswith("+ New project…"), g
    # a name that is an existing project's key is that project: no new-project row, and the pick of a new one is dropped
    type_filter(browser, "New Box")
    pick(browser, "__new__")
    assert wait_for(browser, name_is("example-new-box-main")), ns(browser)   # the name comes from sala a moment after the pick; Create waits for it
    assert not ns(browser)["submitDisabled"]
    sala.ss.rows.append(FS.row("example/new-box", "New Box", "example"))
    set_scope(browser, "beta")
    set_scope(browser, "example")
    g = wait_order(browser, ["example/new-box"])
    assert g["submitDisabled"] and g["picked"] == "", g
    assert calls(sala, "project") == []


# ── the all chip and names only ──────────────────────
TAGS_JS = ("JSON.stringify(Object.fromEntries([...document.querySelectorAll('#ns-projects .ns-opt')].map("
           "(b) => [b.dataset.key, (b.querySelector('.ns-scope-tag') || {}).textContent || null])))")
NAMES_JS = ("JSON.stringify(Object.fromEntries([...document.querySelectorAll('#ns-projects .ns-opt')].map("
            "(b) => [b.dataset.key, (b.querySelector('.ns-key') || {}).textContent])))")
ALL_KEYS = ["projects/beta-docs", "projects/beta-web", "projects/demo", "projects/gamma-harbor", "projects/gamma-pantry", "projects/stackshot"]   # stackshot's order: by key
ALL_SCOPE = {"projects/demo": "example", "projects/beta-docs": "beta", "projects/beta-web": "beta", "projects/gamma-harbor": "gamma",
             "projects/gamma-pantry": "gamma", "projects/stackshot": "example"}
ALL_NAMES = {"projects/demo": "demo", "projects/beta-docs": "docs", "projects/beta-web": "web", "projects/gamma-harbor": "harbor",
             "projects/gamma-pantry": "pantry", "projects/stackshot": "stackshot"}      # the sidebar's names: no folder, no scope prefix


def tags(browser) -> dict:
    return json.loads(browser.evaluate(TAGS_JS))


def names(browser) -> dict:
    return json.loads(browser.evaluate(NAMES_JS))


def no_folder_in_sight(browser) -> None:
    """The box and the line under it never show a page folder (names only)."""
    text = browser.evaluate("document.querySelector('#ns-projects').innerText + '\\n' + document.querySelector('#ns-picked').innerText")
    assert "example/" not in text and "projects/" not in text, text


def reopen(browser, served, **kw) -> dict:
    """The page loaded afresh (a navigation to the same address would not reload it), then the form."""
    browser.send("Page.navigate", {"url": "about:blank"})
    return open_form(browser, served, **kw)


def test_the_all_chip_is_the_last_chip_and_lists_every_scopes_projects_by_name(sala, served, browser):
    open_form(browser, served, scope="gamma")
    g = ns(browser)
    assert [s["scope"] for s in g["scopes"]] == ["beta", "gamma", "example", "all"] and [s["on"] for s in g["scopes"]] == ["false", "true", "false", "false"], g["scopes"]
    assert names(browser) == {"projects/gamma-harbor": "harbor", "projects/gamma-pantry": "pantry", "__new__": '+ New project…'}
    set_scope(browser, "all")
    g = ns(browser)
    assert [s["on"] for s in g["scopes"]] == ["false", "false", "false", "true"], g["scopes"]
    assert g["order"] == ALL_KEYS and g["divider"] is None and g["empty"] is None, g["order"]   # every scope's listed projects, no new-project row
    assert names(browser) == ALL_NAMES and set(tags(browser).values()) == {None}               # no two share a name: no scope beside any
    assert sala.ss.calls("/client/projects")[-1]["query"] == {"scope": "all"}
    assert all(r["h"] >= 40 for r in g["rows"])
    no_folder_in_sight(browser)
    # the names are the sidebar's: sessions.project_title of the key in the row's own scope
    from sala_web.sessions import project_title
    assert {k: project_title(k, sc) for k, sc in ALL_SCOPE.items()} == ALL_NAMES
    # back to one scope: the new-project row is back
    set_scope(browser, "example")
    assert names(browser) == {"projects/demo": "demo", "projects/stackshot": "stackshot", "__new__": "+ New project…"}
    assert ns(browser)["order"][-1] == "__new__"
    no_folder_in_sight(browser)


def test_the_title_is_shown_beside_a_name_and_dropped_when_it_only_repeats_it(sala, served, browser):
    open_form(browser, served, scope="all")
    text = {r["key"]: r["text"] for r in ns(browser)["rows"]}
    assert text["projects/beta-web"] == "webBETA web" and text["projects/gamma-harbor"] == "harborHarbor planning", text
    assert text["projects/stackshot"] == "stackshot" and text["projects/demo"] == "demo", text      # the title is the name: said once


def test_under_all_the_scope_stands_beside_a_name_only_where_two_projects_share_it(sala, served, browser):
    sala.ss.rows.append(FS.row("projects/gamma-demo", "Demo at home", "gamma", agents={"gamma-demo-main": FS.agent()}))   # "demo", as projects/demo is
    open_form(browser, served, scope="all")
    assert tags(browser) == {"projects/demo": "example", "projects/beta-docs": None, "projects/beta-web": None, "projects/gamma-harbor": None,
                             "projects/gamma-demo": "gamma", "projects/gamma-pantry": None, "projects/stackshot": None}
    # the tag is a quiet, small, muted word at the end of the row
    css = browser.evaluate("(() => { const t = document.querySelector('#ns-projects .ns-scope-tag'), k = t.parentElement.querySelector('.ns-key');"
                           " const a = getComputedStyle(t), b = getComputedStyle(k);"
                           " return { size: parseFloat(a.fontSize), keySize: parseFloat(b.fontSize), right: t.getBoundingClientRect().left >= k.getBoundingClientRect().right }; })()")
    assert css["size"] < css["keySize"] and css["right"], css
    # a hidden match that shares a name with a listed project carries it too
    sala.ss.rows.append(FS.row("projects/beta-docs-old", "x", "beta", listed=False))
    sala.ss.rows.append(FS.row("projects/gamma-docs", "Docs at home", "gamma", listed=False))            # "docs", as projects/beta-docs is
    type_filter(browser, "docs")
    wait_for(browser, "document.querySelector('#ns-projects .ns-divider') !== null", 10.0)
    t = tags(browser)
    assert t["projects/beta-docs"] == "beta" and t["projects/gamma-docs"] == "gamma" and t["projects/beta-docs-old"] is None, t
    # one scope: no tags at all
    set_scope(browser, "gamma")
    assert set(tags(browser).values()) == {None}
    no_folder_in_sight(browser)


def test_under_all_typing_filters_the_listed_rows_and_shows_the_hidden_matches_below_the_divider(sala, served, browser):
    open_form(browser, served, scope="all")
    type_filter(browser, "pantry")
    wait_order(browser, ["projects/gamma-pantry", "--divider--", "projects/gamma-pantry-2019"])
    g = ns(browser)
    assert g["divider"] == "existing pages, not listed" and names(browser) == {"projects/gamma-pantry": "pantry", "projects/gamma-pantry-2019": "pantry-2019"}, g
    assert sala.ss.calls("/client/projects")[-1]["query"] == {"scope": "all", "q": "pantry"}
    # the hidden matches of every scope, a note page not among them
    type_filter(browser, "old")
    g = wait_order(browser, ["--divider--", "projects/gamma-old-kayak", "projects/old-box"])    # stackshot's order: by key, across scopes
    assert names(browser) == {"projects/old-box": "old-box", "projects/gamma-old-kayak": "old-kayak"} and g["disabledRows"] == [], g
    type_filter(browser, "kayak")
    g = wait_order(browser, ["--divider--", "projects/gamma-old-kayak"])   # hidden matches are matches: no hint; the note page is not offered
    assert g["disabledRows"] == [] and "projects/gamma-kayak-notes" not in [r["key"] for r in g["rows"]], g
    # the box still finds a project by its key, though the row shows its name
    type_filter(browser, "projects/gamma-harb")
    wait_order(browser, ["projects/gamma-harbor"])
    # a listed match from two scopes at once
    type_filter(browser, "beta")
    wait_order(browser, ["projects/beta-docs", "projects/beta-web", "--divider--", "projects/beta-api"])
    assert names(browser) == {"projects/beta-docs": "docs", "projects/beta-web": "web", "projects/beta-api": "api"}
    no_folder_in_sight(browser)
    # the whole list comes back when the box is cleared
    type_filter(browser, "")
    wait_order(browser, ALL_KEYS)
    assert calls(sala, "project") == [] and calls(sala, "project-list") == [] and calls(sala, "project-agent") == []


def test_under_all_there_is_no_new_project_row_only_a_quiet_hint_when_the_typed_text_matches_nothing(sala, served, browser):
    open_form(browser, served, scope="all")
    g = ns(browser)
    assert "__new__" not in g["order"] and "__hint__" not in g["order"], g["order"]       # nothing typed: no row, no hint
    type_filter(browser, "Fresh Idea")
    g = wait_order(browser, ["(empty)", "__hint__"])
    assert g["empty"] == "No listed project matches." and not any(r["isNew"] for r in g["rows"]) and g["submitDisabled"], g
    hint = browser.evaluate("(() => { const h = document.querySelector('#ns-projects .ns-hintrow'); const s = getComputedStyle(h);"
                            " return { text: h.textContent, size: parseFloat(s.fontSize), isButton: h.tagName === 'BUTTON' }; })()")
    assert hint["text"] == "pick a scope to make a new project" and not hint["isButton"] and hint["size"] <= 12, hint
    # a text that matches a project: no hint either
    type_filter(browser, "harbor")
    g = wait_order(browser, ["projects/gamma-harbor"])
    assert not any(r["isNew"] for r in g["rows"]), g
    # Enter in the box picks the first project shown, as under a scope; with nothing shown it picks nothing (and makes nothing)
    type_filter(browser, "Fresh Idea")
    wait_order(browser, ["(empty)", "__hint__"])
    browser.send("Input.dispatchKeyEvent", {"type": "keyDown", "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13})
    browser.send("Input.dispatchKeyEvent", {"type": "keyUp", "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13})
    g = ns(browser)
    assert g["submitDisabled"] and g["picked"] == "" and g["name"] == "", g
    # a concrete scope with the same text offers the new project again
    set_scope(browser, "beta")
    g = wait_order(browser, ["(empty)", "__new__"])
    assert g["rows"][-1]["text"] == '+ New project "Fresh Idea"fresh-idea', g["rows"]
    no_folder_in_sight(browser)
    assert calls(sala, "project") == []


def test_a_project_picked_under_all_is_made_ready_in_its_own_scope(sala, served, browser):
    open_form(browser, served, scope="all")
    type_filter(browser, "api")
    wait_order(browser, ["--divider--", "projects/beta-api"])
    pick(browser, "projects/beta-api")
    # the agent name takes the row's scope (beta), not "all"
    assert wait_for(browser, name_is("beta-api-main")), ns(browser)
    assert ns(browser)["picked"] == "Create will list api again, add beta-api-main to it, then start the session."
    click(browser, "#ns-submit")
    g = wait_state(browser, "queued", 20.0)
    assert g["steps"] == ["List the project againdone", "Add beta-api-main to the projectdone", "Start the sessiondone"], g["steps"]
    (listed,) = calls(sala, "project-list")
    assert listed["body"] == {"key": sala.ss.find("projects/beta-api")["id"], "scope": "beta", "sender": "sala-web"}   # never "all"
    assert calls(sala, "project") == [] and [r["argv"][2] for r in sala.spawns()] == ["beta-api-main"]
    # a listed project of another scope with agents: sala suggests its name, no extra step
    reopen(browser, served, scope="all")
    pick(browser, "projects/gamma-harbor")
    assert wait_for(browser, name_is("gamma-harbor-pink")), ns(browser)   # a project with agents: a random word, which the form adds to the project
    assert ns(browser)["picked"] == "Create will add gamma-harbor-pink to it, then start the session."
    set_value(browser, "#ns-name", "gamma-harbor-main")                 # the name it lists already: no extra step
    assert ns(browser)["picked"] == ""


def test_the_last_used_scope_may_be_all_and_the_default_is_unchanged(sala, served, browser):
    # nothing remembered: the open session's scope (the fake session is in example), as before
    open_form(browser, served, scope=None)
    assert [s["on"] for s in ns(browser)["scopes"]] == ["false", "false", "true", "false"]
    set_scope(browser, "all")
    assert browser.evaluate("localStorage.getItem('sala.ns.scope')") == "all"
    # the page loaded again: the form opens on all
    reopen(browser, served, scope=None)
    g = ns(browser)
    assert [s["on"] for s in g["scopes"]] == ["false", "false", "false", "true"] and g["order"] == ALL_KEYS, g
    # another scope replaces it, and a remembered scope that is no chip is not used
    set_scope(browser, "gamma")
    assert browser.evaluate("localStorage.getItem('sala.ns.scope')") == "gamma"
    browser.evaluate("localStorage.setItem('sala.ns.scope', 'work'); ''")
    reopen(browser, served, scope=None)
    assert [s["on"] for s in ns(browser)["scopes"]] == ["false", "false", "true", "false"]


# ── Create, kind by kind ─────────────────────────────────────────────────────
def test_a_new_project_is_made_then_the_agent_added_then_the_session_queued_with_progress_and_no_double_send(sala, served, browser):
    sala.ss.new_delay = 3.0
    open_form(browser, served, scope="beta")
    type_filter(browser, "Fresh Idea")
    wait_order(browser, ["(empty)", "__new__"])
    pick(browser, "__new__")
    assert wait_for(browser, name_is("beta-fresh-idea-main")), ns(browser)
    set_value(browser, "#ns-mandate", "# Fresh idea\nWork out whether the idea holds.")
    click(browser, "#ns-submit")
    # the make step is on: the button is off, the progress says what is happening and for how long, nothing later has run
    assert wait_for(browser, "document.querySelectorAll('#ns-status .ns-step').length === 3", 5.0), ns(browser)
    g = ns(browser)
    assert g["pending"] and g["submitDisabled"] and g["state"] == "beta-fresh-idea-main: working…", g
    assert g["steps"][0].startswith("Making the project page, which can take a few minutes (") and g["steps"][0].endswith("working"), g["steps"]
    assert g["steps"][1:] == ["Add beta-fresh-idea-main to the projectwaiting", "Start the sessionwaiting"], g["steps"]
    # a second press and a second submit event while it runs send nothing
    browser.evaluate("document.querySelector('#ns-submit').click(); document.querySelector('#ns-form').requestSubmit(); ''")
    time.sleep(1.5)
    assert len(calls(sala, "project")) == 1 and calls(sala, "project-agent") == [] and sala.spawns() == []
    assert any(f"({n} s)" in ns(browser)["steps"][0] for n in (1, 2, 3)), ns(browser)["steps"]   # the seconds count up
    g = wait_state(browser, "queued", 30.0)
    assert g["state"] == "beta-fresh-idea-main: Queued" and not g["pending"] and g["submitDisabled"], g
    assert g["steps"] == ["Make the project pagedone", "Add beta-fresh-idea-main to the projectdone", "Start the sessiondone"], g["steps"]
    assert "front agent of projects/fresh-idea" in g["status"], g
    # exactly one page made, one agent added, one spawn, with the form's one label
    (made,) = calls(sala, "project")
    assert made["body"] == {"key": "projects/fresh-idea", "scope": "beta", "title": "Fresh Idea", "sender": "sala-web"}
    (added,) = calls(sala, "project-agent")
    pid = sala.ss.find("projects/fresh-idea")["id"]
    assert added["body"] == {"project": pid, "name": "beta-fresh-idea-main", "role": "main", "front": True,
                             "mandate": "Fresh idea", "sender": "sala-web"}   # the mandate's first line, its heading mark dropped
    (spawn,) = sala.spawns()
    assert spawn["argv"][2:7] == ["beta-fresh-idea-main", "--project", "projects/fresh-idea", "--role", "front"]
    assert spawn["mandate"] == "# Fresh idea\nWork out whether the idea holds.\n"
    assert calls(sala, "project-list") == []   # a new project is listed by being made
    # stackshot says the page still owes the agent's line: the form records that and asks the owner for nothing
    assert "recorded with stackshot" in g["status"] and "ADD-TO-PAGE" not in g["status"] and "agents:" not in g["status"], g
    # the project is in the box now, picked
    assert wait_for(browser, "document.querySelector('#ns-projects .ns-opt[data-key=\"projects/fresh-idea\"]') !== null", 5.0)
    g = ns(browser)
    assert g["rows"][0]["key"] == "projects/fresh-idea" and g["rows"][0]["sel"] == "true" and g["order"][-1] != "__new__", g


def test_a_hidden_project_is_listed_again_then_the_agent_added_then_the_session_queued(sala, served, browser):
    open_form(browser, served, scope="gamma")
    type_filter(browser, "old kayak")
    wait_order(browser, ["--divider--", "projects/gamma-old-kayak", "__new__"])
    pick(browser, "projects/gamma-old-kayak")
    assert wait_for(browser, name_is("gamma-old-kayak-main")), ns(browser)
    assert ns(browser)["picked"] == "Create will list old-kayak again, add gamma-old-kayak-main to it, then start the session."
    hidden = sala.ss.find("projects/gamma-old-kayak")
    assert hidden["listed"] is False
    click(browser, "#ns-submit")
    g = wait_state(browser, "queued", 20.0)
    assert g["steps"] == ["List the project againdone", "Add gamma-old-kayak-main to the projectdone", "Start the sessiondone"], g["steps"]
    (listed,) = calls(sala, "project-list")
    assert listed["body"] == {"key": hidden["id"], "scope": "gamma", "sender": "sala-web"}
    (added,) = calls(sala, "project-agent")
    assert added["body"]["project"] == hidden["id"] and added["body"]["mandate"] == "front agent of gamma-old-kayak" and added["body"]["role"] == "main", added
    assert calls(sala, "project") == [] and [r["argv"][2] for r in sala.spawns()] == ["gamma-old-kayak-main"]
    assert sala.ss.find("projects/gamma-old-kayak")["listed"] is True


def test_a_listed_project_whose_agent_is_listed_starts_with_no_extra_step(sala, served, browser):
    open_form(browser, served, scope="gamma")
    pick(browser, "projects/gamma-harbor")
    assert wait_for(browser, name_is("gamma-harbor-pink")), ns(browser)   # a random word: the project has agents
    set_value(browser, "#ns-name", "gamma-harbor-main")                 # the name the project lists already
    assert ns(browser)["picked"] == ""   # nothing to do before the session
    click(browser, "#ns-submit")
    g = wait_state(browser, "queued", 20.0)
    assert g["steps"] == [] and "front agent of projects/gamma-harbor" in g["status"], g
    assert calls(sala, "project") == [] and calls(sala, "project-list") == [] and calls(sala, "project-agent") == []


def test_a_listed_project_with_no_agents_is_confirmed_listed_so_its_first_agent_may_be_added(sala, served, browser):
    # stackshot lets the label that made or listed a project add its first agents; a project listed only through its board
    # items has no such mark, so the form renews it first
    open_form(browser, served, scope="gamma")
    pick(browser, "projects/gamma-pantry")
    assert wait_for(browser, name_is("gamma-pantry-main")), ns(browser)
    click(browser, 'input[name="ns-role"][value="back"]')
    assert wait_for(browser, name_is("gamma-pantry-pink")), ns(browser)
    set_value(browser, "#ns-mandate", "Prepare the tax papers\nsecond line")
    click(browser, "#ns-submit")
    g = wait_state(browser, "queued", 20.0)
    assert g["steps"] == ["Confirm the project is listeddone", "Add gamma-pantry-pink to the projectdone", "Start the sessiondone"], g["steps"]
    (added,) = calls(sala, "project-agent")
    assert added["body"]["front"] is False and added["body"]["role"] == "pink" and added["body"]["mandate"] == "Prepare the tax papers", added
    assert calls(sala, "project-list")[0]["body"]["key"] == sala.ss.find("projects/gamma-pantry")["id"]


# ── when a step fails ────────────────────────────────────────────────────────
def test_a_new_project_that_exists_already_says_so_and_changes_nothing_else(sala, served, browser):
    open_form(browser, served, scope="beta")
    type_filter(browser, "Fresh Idea")
    wait_order(browser, ["(empty)", "__new__"])
    pick(browser, "__new__")
    assert wait_for(browser, name_is("beta-fresh-idea-main")), ns(browser)
    sala.ss.rows.append(FS.row("projects/fresh-idea", "Fresh idea", "beta", listed=False))   # made by someone else a moment ago
    click(browser, "#ns-submit")
    g = wait_state(browser, "beta-fresh-idea-main: stopped", 20.0)
    assert "projects/fresh-idea exists already" in g["status"] and "pick it from the list" in g["status"], g
    assert g["steps"][0].endswith("failed") and g["steps"][1:] == ["Add beta-fresh-idea-main to the projectwaiting", "Start the sessionwaiting"], g["steps"]
    assert "already exists" in g["pre"], g
    assert calls(sala, "project-agent") == [] and sala.spawns() == []
    # the box now finds the page under the divider (it is hidden: nobody listed it), and the typed name is that project, not a new one
    g = wait_order(browser, ["--divider--", "projects/fresh-idea"])
    assert g["submitDisabled"], g
    pick(browser, "projects/fresh-idea")
    assert wait_for(browser, name_is("beta-fresh-idea-main")), ns(browser)
    assert ns(browser)["picked"].startswith("Create will list fresh-idea again")


def test_a_project_being_made_by_another_request_is_said_as_a_wait_and_not_as_a_duplicate(sala, served, browser):
    sala.ss.new_reply = (409, {"error": "projects/fresh-idea is being made by another request: try again in a minute"})
    open_form(browser, served, scope="beta")
    type_filter(browser, "Fresh Idea")
    wait_order(browser, ["(empty)", "__new__"])
    pick(browser, "__new__")
    assert wait_for(browser, name_is("beta-fresh-idea-main")), ns(browser)
    click(browser, "#ns-submit")
    g = wait_state(browser, "beta-fresh-idea-main: stopped", 20.0)
    assert "is being made right now by another request" in g["status"] and "exists already" not in g["status"], g
    assert calls(sala, "project-agent") == [] and sala.spawns() == []
    assert not ns(browser)["submitDisabled"], g   # the form is usable again for a retry


def test_gbrain_refusing_the_page_stops_the_create_and_a_retry_goes_on_from_the_failed_step(sala, served, browser):
    sala.ss.new_reply = (502, {"error": "gbrain refused the new page for projects/fresh-idea: no room; nothing else was recorded"})
    open_form(browser, served, scope="beta")
    type_filter(browser, "Fresh Idea")
    wait_order(browser, ["(empty)", "__new__"])
    pick(browser, "__new__")
    assert wait_for(browser, name_is("beta-fresh-idea-main")), ns(browser)
    click(browser, "#ns-submit")
    g = wait_state(browser, "beta-fresh-idea-main: stopped", 20.0)
    assert "gbrain did not take the new page" in g["status"] and "Create again to retry" in g["status"] and "no room" in g["pre"], g
    assert calls(sala, "project-agent") == [] and sala.spawns() == []
    # the page is made on the retry; then stackshot refuses the agent (not something the form can fix): it stops there, the page done
    sala.ss.new_reply = None
    sala.ss.agent_reply = (403, {"error": "projects/fresh-idea is retired or hidden: list it again first"})
    click(browser, "#ns-submit")
    g = wait_state(browser, "beta-fresh-idea-main: stopped", 20.0)
    assert g["steps"] == ["Make the project pagedone", "Add beta-fresh-idea-main to the projectfailed", "Start the sessionwaiting"], g["steps"]
    assert "projects/fresh-idea is retired or hidden, so stackshot will not add an agent to it" in g["status"] and "Create again to go on from the failed step" in g["status"], g
    assert len(calls(sala, "project")) == 2 and sala.spawns() == []
    # the retry after that does not make the page again
    sala.ss.agent_reply = None
    click(browser, "#ns-submit")
    g = wait_state(browser, "beta-fresh-idea-main: queued", 20.0)
    assert len(calls(sala, "project")) == 2, "the page was made a third time"
    assert len(calls(sala, "project-agent")) == 2 and [r["argv"][2] for r in sala.spawns()] == ["beta-fresh-idea-main"]
    assert g["steps"] == ["Make the project pagedone", "Add beta-fresh-idea-main to the projectdone", "Start the sessiondone"], g["steps"]


def test_a_new_agent_on_a_project_that_has_agents_is_added_and_queued(sala, served, browser):
    # stackshot: the old keeper-or-front-agent refusal is gone; the form adds the agent and starts the session
    open_form(browser, served, scope="gamma")
    pick(browser, "projects/gamma-harbor")
    assert wait_for(browser, name_is("gamma-harbor-pink")), ns(browser)
    set_value(browser, "#ns-name", "gamma-harbor-extra")
    click(browser, "#ns-submit")
    g = wait_state(browser, "gamma-harbor-extra: queued", 20.0)
    assert [x["body"]["name"] for x in calls(sala, "project-agent")] == ["gamma-harbor-extra"]
    assert [r["argv"][2] for r in sala.spawns()] == ["gamma-harbor-extra"], g


def test_a_taken_name_is_said_in_plain_words_and_nothing_is_queued(sala, served, browser):
    sala.ss.pending_names.add("gamma-harbor-extra")
    open_form(browser, served, scope="gamma")
    pick(browser, "projects/gamma-harbor")
    assert wait_for(browser, name_is("gamma-harbor-pink")), ns(browser)
    set_value(browser, "#ns-name", "gamma-harbor-extra")
    click(browser, "#ns-submit")
    g = wait_state(browser, "gamma-harbor-extra: stopped", 20.0)
    assert "gamma-harbor-extra is already taken" in g["status"] and "Change the name, then Create again" in g["status"], g   # stackshot's reason, then the words
    assert "already taken" in g["pre"] and sala.spawns() == [], g
    assert "keeper" not in g["status"] and "front agents" not in g["status"], g


def test_a_project_that_turns_out_retired_or_hidden_is_said_in_plain_words(sala, served, browser):
    sala.ss.agent_reply = (403, {"error": "projects/gamma-harbor is retired or hidden: list it again first"})
    open_form(browser, served, scope="gamma")
    pick(browser, "projects/gamma-harbor")
    assert wait_for(browser, name_is("gamma-harbor-pink")), ns(browser)
    set_value(browser, "#ns-name", "gamma-harbor-extra")
    click(browser, "#ns-submit")
    g = wait_state(browser, "gamma-harbor-extra: stopped", 20.0)
    assert "projects/gamma-harbor is retired or hidden, so stackshot will not add an agent to it. Pick another project." in g["status"], g
    assert "retired or hidden: list it again first" in g["pre"] and sala.spawns() == [], g


def test_a_spawn_that_does_not_see_the_new_agent_yet_is_asked_again_and_then_succeeds(sala, served, browser):
    # sala reads stackshot's record a moment after a change: the queue's first answers are "not listed", then it queues
    sala.mode("exit3")
    open_form(browser, served, scope="gamma")
    pick(browser, "projects/gamma-pantry")
    assert wait_for(browser, name_is("gamma-pantry-main")), ns(browser)
    click(browser, "#ns-submit")
    assert wait_for(browser, "document.querySelector('#ns-status .ns-step.waiting') !== null", 15.0), ns(browser)
    assert "has not seen the change yet" in ns(browser)["status"]
    sala.mode("ok")
    g = wait_state(browser, "queued", 20.0)
    assert len(sala.spawns()) >= 2 and g["steps"][-1] == "Start the sessiondone"


def test_stackshot_being_down_is_said_for_the_list_and_for_create(sala, served, browser):
    sala.ss.projects_reply = (503, {"error": "the project record cannot be read right now"})
    open_form(browser, served, scope=None)
    assert wait_for(browser, "(document.querySelector('#ns-projects .ns-empty') || {}).textContent?.startsWith('Could not read the project list')", 15.0), ns(browser)
    g = ns(browser)
    assert "the project record cannot be read right now" in g["empty"] and g["order"][-1] == "__new__", g
    # a scope switch asks again, and the list comes back
    sala.ss.projects_reply = None
    set_scope(browser, "gamma")
    assert ns(browser)["order"] == ["projects/gamma-harbor", "projects/gamma-pantry", "__new__"]
    # Create with stackshot gone: the step that needed it stops, in words, and nothing is queued
    type_filter(browser, "Fresh Idea")
    wait_order(browser, ["(empty)", "__new__"])
    pick(browser, "__new__")
    assert wait_for(browser, name_is("gamma-fresh-idea-main")), ns(browser)
    sala.ss.close()
    click(browser, "#ns-submit")
    g = wait_state(browser, "gamma-fresh-idea-main: stopped", 20.0)
    assert g["steps"][0].endswith("failed") and "stackshot unreachable" in g["status"] and sala.spawns() == [], g


# ── widths ───────────────────────────────────────────────────────────────────
def test_the_scope_and_the_box_fit_a_phone_and_a_desktop_and_a_long_refusal_never_scrolls_sideways(sala, served, browser):
    sala.ss.agent_reply = (403, {"error": "retired or hidden: " + "a very long reason " * 30 + "x" * 200})
    open_form(browser, served, width=390, height=844, scope="gamma")
    browser.touch()   # the 40 px sizes below are touch sizes: the look draws controls 32 px under a mouse, 44 px under a thumb
    type_filter(browser, "kayak")
    wait_order(browser, ["--divider--", "projects/gamma-old-kayak", "__new__"])
    pick(browser, "projects/gamma-old-kayak")
    assert wait_for(browser, name_is("gamma-old-kayak-main")), ns(browser)
    set_value(browser, "#ns-name", "gamma-old-kayak-" + "x" * 30)
    click(browser, "#ns-submit")
    wait_state(browser, "stopped", 20.0)
    unfold(browser)   # the rows are measured with the project box open
    for width, height in ((320, 700), (390, 844), (1280, 800)):
        browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": height, "deviceScaleFactor": 1, "mobile": width <= 760})
        browser.evaluate("new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))")
        g = ns(browser)
        assert g["open"] and g["vw"] == width, g
        assert g["docScroll"] <= width and g["bodyScroll"] <= width and g["formScroll"] <= g["formClient"], (width, g)
        assert g["box"]["left"] >= 0 and g["box"]["right"] <= width + 1, (width, g)
        assert all(s["h"] >= 40 for s in g["scopes"]) and all(r["h"] >= 40 for r in g["rows"]), (width, g["scopes"], g["rows"])
        assert len(g["steps"]) == 3, g


def test_the_all_chip_and_the_scope_tags_fit_a_phone_and_a_desktop(sala, served, browser):
    sala.ss.rows.append(FS.row("projects/beta-a-project-with-a-very-long-page-name-for-the-tag-to-squeeze", "A project with a very long title as well " * 3, "beta"))
    sala.ss.rows.append(FS.row("projects/gamma-a-project-with-a-very-long-page-name-for-the-tag-to-squeeze", "Twin of the long one", "gamma"))   # the same name in another scope: its tag shows
    open_form(browser, served, width=390, height=844, scope="all")
    browser.touch()   # the 40 px sizes below are touch sizes: the look draws controls 32 px under a mouse, 44 px under a thumb
    for width, height in ((320, 700), (390, 844), (1280, 800)):
        browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": height, "deviceScaleFactor": 1, "mobile": width <= 760})
        browser.evaluate("new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))")
        g = ns(browser)
        assert g["open"] and g["vw"] == width and len(g["scopes"]) == 4 and g["scopes"][-1]["scope"] == "all" and g["scopes"][-1]["on"] == "true", (width, g["scopes"])
        assert g["docScroll"] <= width and g["bodyScroll"] <= width and g["formScroll"] <= g["formClient"], (width, g)
        assert g["box"]["left"] >= 0 and g["box"]["right"] <= width + 1, (width, g)
        assert all(s["h"] >= 40 for s in g["scopes"]) and all(r["h"] >= 40 for r in g["rows"]), (width, g["scopes"], g["rows"])
        # every chip and every row's tag is whole inside the sheet
        inside = browser.evaluate("(() => { const s = document.querySelector('#new-pane').getBoundingClientRect();"
                                  " return [...document.querySelectorAll('#ns-scopes .ns-chip, #ns-projects .ns-scope-tag')].every((e) => { const r = e.getBoundingClientRect();"
                                  " return r.width > 0 && r.left >= s.left - 1 && r.right <= s.right + 1; }); })()")
        assert inside, width
    assert sorted(v for v in tags(browser).values() if v) == ["beta", "gamma"] and len(tags(browser)) == 8
