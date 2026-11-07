"""The New session form's refinements: the name sala suggests, the project list that folds,
the defaults that say what they are, the model selector, and the composer's bullet.

What a wrong answer costs: a session created under a prefix that is not the project's (gamma-quarry for the example scope's quarry), a name that
exists already (demo-main for a project that has it) so the create fails, a -main for a project that has agents, a list that
never folds on a phone and pushes the form out of sight, a "use default" that hides what the default is, a model typed by hand
into a shell. Every check guards one of those. The browser is a headless Chromium; `sala` is the stand-in of test_new_session.py,
which knows the fake stackshot's agents (`sync_agents`) and answers as sala's `--suggest-name` does: -main only for a front agent of a
project with no agent, else a word (here pink); stackshot is the fake of fake_stackshot.py. tests/spawn.sh holds the real
`sala spawn --suggest-name` (taken names, the record's prefix, the random word); web/tests holds what the page does with its answer."""

from __future__ import annotations

import json
import re
import time

import pytest

from test_board_items_ui import wait_for
from test_composer_attach import WAIT_READY
from test_new_session import ROWS_LOADED, click, ns, open_form, open_more, pick, set_scope, set_value, stub  # noqa: F401
from test_new_session import env, sala  # noqa: F401  (fixtures)
from fake_stackshot import agent, row

QUARRY_AGENTS = {"lamp-main": agent(), "lamp-builder": agent(False, "engineer", "builds"), "lamp-hosting": agent(False, "hosting", "runs the hosting")}


def add_quarry(sala) -> None:
    """The page as stackshot lists it: projects/quarry, in the example scope, three agents, the keeper an agent of ANOTHER project."""
    sala.ss.rows.append(row("projects/quarry", "quarry", "example", agents=QUARRY_AGENTS, keeper="alex-builder"))
    sala.sync_agents()


def suggest_calls(sala) -> list[list[str]]:
    return [r["argv"] for r in sala.records() if r["argv"][:2] == ["spawn", "--suggest-name"]]


def name_is(sala_prefix: str) -> str:
    return f"document.querySelector('#ns-name').value.startsWith({json.dumps(sala_prefix + '-')})"


# ── the name ─────────────────────────────────────────────────────────────────
def test_a_page_with_agents_under_infra_reaches_the_form_with_its_scope_and_agents(env):
    """The shape of projects/quarry (the lead was that its agents did not reach the form; they do): the project
    API passes scope, main and every agent on, the keeper beside them."""
    add_quarry(env["sala"])
    d = env["client"].get("/api/spawn/projects", params={"scope": "example"}).json()
    g = next(p for p in d["projects"] if p["key"] == "projects/quarry")
    assert g["scope"] == "example" and g["main"] == "lamp-main" and g["keeper"] == "alex-builder", g
    assert sorted(g["agents"]) == ["lamp-builder", "lamp-hosting", "lamp-main"], g
    assert not [p for p in env["client"].get("/api/spawn/projects", params={"scope": "gamma"}).json()["projects"] if p["key"] == "projects/quarry"]


def test_scoped_project_is_named_scope_agent_and_never_other_scope_or_main(sala, served, browser):
    add_quarry(sala)
    open_form(browser, served, scope="example")
    pick(browser, "projects/quarry")
    assert wait_for(browser, name_is("lamp")), ns(browser)
    g = ns(browser)
    assert re.fullmatch(r"lamp-[a-z]+", g["name"]) and g["name"] != "lamp-main", g          # a word: it has agents
    assert g["name"] not in QUARRY_AGENTS and not g["submitDisabled"], g
    (argv,) = suggest_calls(sala)
    assert argv[argv.index("--project") + 1] == "projects/quarry" and argv[argv.index("--prefix") + 1] == "lamp", argv   # the project's real prefix, from its main agent
    assert "gamma-quarry" not in json.dumps(sala.records()) and "alex-" not in json.dumps(argv), argv    # the keeper (an agent of another project) is not the prefix
    # the add-to-project line and the words of the create carry the same prefix
    assert g["picked"] and "Create will add" in g["picked"] and g["name"] in g["picked"], g
    # a background agent: asked again with the same prefix
    click(browser, 'input[name="ns-role"][value="back"]')
    end = time.time() + 10
    while time.time() < end and len(suggest_calls(sala)) < 2:
        time.sleep(0.1)
    last = suggest_calls(sala)[-1]
    assert last[last.index("--role") + 1] == "back" and last[last.index("--prefix") + 1] == "lamp", last


def test_main_only_for_a_project_with_no_agent_yet(sala, served, browser):
    open_form(browser, served, scope="gamma")
    # projects/gamma-pantry is listed with no agent: its first front agent is -main
    pick(browser, "projects/gamma-pantry")
    assert wait_for(browser, "document.querySelector('#ns-name').value === 'gamma-pantry-main'"), ns(browser)
    assert "--new" not in suggest_calls(sala)[-1], suggest_calls(sala)[-1]   # a listed project: sala's record says it has no agent
    # a background agent, though, is a word
    click(browser, 'input[name="ns-role"][value="back"]')
    assert wait_for(browser, "document.querySelector('#ns-name').value === 'gamma-pantry-pink'"), ns(browser)
    # gamma-harbor has its main: a front agent is a word too
    click(browser, 'input[name="ns-role"][value="front"]')
    pick(browser, "projects/gamma-harbor")
    assert wait_for(browser, "document.querySelector('#ns-name').value === 'gamma-harbor-pink'"), ns(browser)
    # a project made here has none: -main
    click(browser, "#ns-summary")                                      # open the folded box to type in it
    set_value(browser, "#ns-filter", "zeta-lab")
    click(browser, '#ns-projects .ns-opt[data-key="__new__"]')
    assert wait_for(browser, "document.querySelector('#ns-name').value.endsWith('-main')"), ns(browser)
    assert "zeta-lab" in ns(browser)["name"], ns(browser)
    assert "--new" in suggest_calls(sala)[-1], suggest_calls(sala)[-1]   # no page yet: no record can know it, so the page says it is new


def test_a_main_the_stand_in_offers_for_a_project_with_agents_is_asked_again(sala, served, browser):
    """If sala (or an older one) answers -main for a project that has agents, the page does not use it: it asks again."""
    sala.suggestions("gamma-harbor-main", "gamma-harbor-fox")
    open_form(browser, served, scope="gamma")
    pick(browser, "projects/gamma-harbor")
    assert wait_for(browser, "document.querySelector('#ns-name').value === 'gamma-harbor-fox'"), ns(browser)
    assert len(suggest_calls(sala)) == 2


def test_a_name_of_a_running_session_is_never_the_suggestion(sala, served, browser):
    open_form(browser, served, scope="gamma")
    browser.evaluate("window.__names = ['gamma-harbor-pink', 'gamma-harbor-fox']; loadSessions(); ''")
    assert wait_for(browser, "state.byName.has('gamma-harbor-pink')", 5.0)
    pick(browser, "projects/gamma-harbor")
    # sala's answer (pink) is a running session's name, the page asks again, and when it gets the same answer twice, picks a word itself
    assert wait_for(browser, "document.querySelector('#ns-name').value !== ''", 15.0), ns(browser)
    g = ns(browser)
    assert re.fullmatch(r"gamma-harbor-[a-z]+", g["name"]) and g["name"] not in ("gamma-harbor-pink", "gamma-harbor-fox", "gamma-harbor-main"), g
    assert len(suggest_calls(sala)) == 2, suggest_calls(sala)   # not four calls for one answer
    assert "is running already" not in (g["nameErr"] or ""), g
    # and a name typed that IS a running session's is refused in the form with the reason
    set_value(browser, "#ns-name", "gamma-harbor-pink")
    g = ns(browser)
    assert g["submitDisabled"] and "running already" in g["nameErr"], g


def test_the_words_of_the_suggestion_are_random_words_not_a_fixed_one(sala, served, browser):
    """The page's own fallback (sala not reachable) picks from sala's word list: more than one word over several tries, always the prefix and a word."""
    open_form(browser, served, scope="gamma")
    got = browser.evaluate("""(() => { const out = new Set(); for (let i = 0; i < 40; i++) out.add(nsLocalName("gamma-harbor", "front", true, new Set())); return [...out]; })()""")
    assert len(got) > 5 and all(re.fullmatch(r"gamma-harbor-[a-z]+", n) for n in got) and "gamma-harbor-main" not in got, got
    # -main only for a front agent with no agent on the project, and never one that is taken
    assert browser.evaluate("""[nsLocalName("gamma-pantry", "front", false, new Set()), nsLocalName("gamma-pantry", "front", false, new Set(["gamma-pantry-main"])),
                               nsLocalName("gamma-pantry", "back", false, new Set())]""")[0] == "gamma-pantry-main"
    other = browser.evaluate("""[nsLocalName("gamma-pantry", "front", false, new Set(["gamma-pantry-main"])), nsLocalName("gamma-pantry", "back", false, new Set())]""")
    assert all(re.fullmatch(r"gamma-pantry-[a-z]+", n) and n != "gamma-pantry-main" for n in other), other


# ── the project list ─────────────────────────────────────────────────────────
FOLD = """(() => { const q = (s) => document.querySelector(s), r = (s) => q(s).getBoundingClientRect();
  const keys = [...document.querySelectorAll('#ns-projects .ns-opt .ns-key')];
  return { panelHidden: q('#ns-projpanel').hidden, panelShown: r('#ns-projpanel').height > 0, sumHidden: q('#ns-summary').hidden, expanded: q('#ns-summary').getAttribute('aria-expanded'),
    sum: q('#ns-summary').textContent, sumH: q('#ns-summary').hidden ? 0 : r('#ns-summary').height, sumW: q('#ns-summary').hidden ? 0 : r('#ns-summary').width, formW: r('#ns-form').width,
    headShown: r('#ns-head').height > 0, head: [...document.querySelectorAll('#ns-head > span')].map((s) => s.firstChild.textContent.trim()),
    hk: r('#ns-head .ns-hk').width, ht: r('#ns-head .ns-ht').width, hkLeft: r('#ns-head .ns-hk').left,
    keyW: keys.length ? keys[0].getBoundingClientRect().width : 0, keyLeft: keys.length ? keys[0].getBoundingClientRect().left : 0,
    titleLeft: document.querySelector('#ns-projects .ns-opt .ns-title') ? document.querySelector('#ns-projects .ns-opt .ns-title').getBoundingClientRect().left : 0,
    htLeft: r('#ns-head .ns-ht').left, arrow: getComputedStyle(q('#ns-summary'), '::before').content,
    docScroll: document.documentElement.scrollWidth, vw: document.documentElement.clientWidth, name: q('#ns-name').value }; })()"""


def test_the_list_folds_to_one_line_once_a_project_is_chosen_and_opens_again(sala, served, browser):
    open_form(browser, served, scope="gamma")
    g = browser.evaluate(FOLD)
    assert g["sumHidden"] and g["panelShown"] and g["headShown"], g                              # nothing chosen: the whole box
    pick(browser, "projects/gamma-harbor")
    assert wait_for(browser, "document.querySelector('#ns-projpanel').hidden"), browser.evaluate(FOLD)
    g = browser.evaluate(FOLD)
    assert not g["sumHidden"] and not g["panelShown"] and g["expanded"] == "false", g
    assert "harborHarbor planning" == g["sum"] and g["arrow"] in ('"▸"', '"\\25B8"'), g          # the name, the description, an arrow (closed)
    assert g["sumH"] >= 40, g                                                                       # a thumb can hit it
    # the arrow opens the box again, with the filter focused on a wide screen; picking another folds it again
    click(browser, "#ns-summary")
    g = browser.evaluate(FOLD)
    assert g["panelShown"] and g["expanded"] == "true" and g["arrow"] in ('"▾"', '"\\25BE"'), g
    pick(browser, "projects/gamma-pantry")
    g = browser.evaluate(FOLD)
    assert not g["panelShown"] and g["sum"].startswith("pantry"), g   # (pantry has no description)
    # another scope is another list: unfolded again, nothing chosen
    set_scope(browser, "beta")
    g = browser.evaluate(FOLD)
    assert g["sumHidden"] and g["panelShown"], g


def test_enter_in_the_filter_picks_and_folds_and_the_keyboard_can_reopen(sala, served, browser):
    from test_composer_editable import key
    open_form(browser, served, scope="gamma")
    set_value(browser, "#ns-filter", "harb")
    key(browser, "Enter", "Enter", 13, "\r")
    assert wait_for(browser, "document.querySelector('#ns-projpanel').hidden"), browser.evaluate(FOLD)
    assert browser.evaluate("document.activeElement.id") == "ns-summary"                           # the focus is where the box went
    key(browser, "Enter", "Enter", 13, "\r")                                                       # Enter on the button opens it
    assert wait_for(browser, "!document.querySelector('#ns-projpanel').hidden"), browser.evaluate(FOLD)


def test_the_list_has_a_header_row_and_a_narrow_name_column(sala, served, browser):
    for width, narrow_max in ((1280, 0.3), (390, 0.45)):
        open_form(browser, served, width=width, height=844, scope="gamma")
        g = browser.evaluate(FOLD)
        assert g["head"] == ["Project", "Description"] and g["headShown"], g
        assert g["hk"] < g["ht"] and g["hk"] <= narrow_max * g["formW"] + 1, g                      # the name column is the narrow one, the description the wide
        assert abs(g["keyW"] - g["hk"]) <= 1 and abs(g["keyLeft"] - g["hkLeft"]) <= 16, g             # the rows' columns sit under the header's
        assert g["docScroll"] <= g["vw"], g                                                         # a phone: no sideways scroll


# ── lane, model, effort ──────────────────────────────────────────────────────
@pytest.mark.parametrize("lane, shown", [("subscription-2", "subscription-2"), ("subscription-1", "subscription-1"), ("api", "metered")])   # a lane's own name is the owner's: api is "metered"
def test_use_default_says_what_the_default_is(sala, served, browser, lane, shown):
    sala.lane_default(lane)
    (served["settings"].claude_dir / "settings.json").write_text(json.dumps({"model": "opus[1m]", "effortLevel": "xhigh"}))
    open_form(browser, served, scope="gamma")
    g = ns(browser)
    assert g["lanes"][0] == f"=use default ({shown})", g["lanes"]
    assert g["models"][0] == "=use default (opus[1m])" and g["efforts"][0] == "=use default (xhigh)", g


def test_use_default_says_what_the_default_is_when_sala_answers_late(sala, served, browser):
    """api/spawn/options waits for `sala lane --json` (cut at 4 s), the project list does not wait for the options: with sala
    taking 2 s the rows are in first and the selects hold "use default" alone until the options arrive, when the page draws them
    (the first choice with the lane's default) without a reload. open_form waits for that; this holds the late order on purpose."""
    sala.lane_sleep(2)
    open_form(browser, served, scope="gamma")
    g = ns(browser)
    assert g["lanes"][0] == "=use default (subscription-1)" and len(g["lanes"]) == 6 and g["models"][1] == "opus=opus", g


def test_the_model_is_a_selector_and_other_takes_an_id(sala, served, browser):
    open_form(browser, served, scope="gamma")
    pick(browser, "projects/gamma-harbor")
    assert wait_for(browser, name_is("gamma-harbor")), ns(browser)
    open_more(browser)
    g = ns(browser)
    assert g["models"] == ["=use default", "opus=opus", "sonnet=sonnet", "haiku=haiku", "fable=fable", "__other=other… (a model id)"], g["models"]
    assert browser.evaluate("document.querySelector('#ns-model').tagName") == "SELECT" and g["modelOtherHidden"], g
    # nothing chosen sends no lane, model or effort: the session follows the defaults
    click(browser, "#ns-submit")
    assert wait_for(browser, "(document.querySelector('#ns-status .ns-state') || {}).textContent?.endsWith('Queued')", 15.0), ns(browser)
    argv = sala.spawns()[-1]["argv"]
    assert "--model" not in argv and "--lane" not in argv and "--effort" not in argv, argv
    sala.marker("stuck", "stopped by the test", done=True)   # Start works until the session is ready or has failed: the next one waits for that
    assert wait_for(browser, "(document.querySelector('#ns-status .ns-state') || {}).textContent?.endsWith('Did not start')", 15.0), ns(browser)
    # a chosen model, effort and lane are sent as chosen
    for sel, val in (("#ns-model", "sonnet"), ("#ns-effort", "high"), ("#ns-lane", "subscription-2")):
        browser.evaluate(f"(() => {{ const s = document.querySelector({json.dumps(sel)}); s.value = {json.dumps(val)}; s.dispatchEvent(new Event('change')); return '' }})()")
    set_value(browser, "#ns-name", "gamma-harbor-sonnet")
    click(browser, "#ns-submit")
    end = time.time() + 15
    while time.time() < end and len(sala.spawns()) < 2:
        time.sleep(0.1)
    argv = sala.spawns()[-1]["argv"]
    assert argv[argv.index("--model") + 1] == "sonnet" and argv[argv.index("--effort") + 1] == "high" and argv[argv.index("--lane") + 1] == "subscription-2", argv


# ── the composer ─────────────────────────────────────────────────────────────
def test_the_composer_bullet_is_the_colour_of_the_text_in_both_themes(served, browser):
    from test_composer_editable import open_composer, typed
    open_composer(browser, served)
    typed(browser, "- item")
    assert wait_for(browser, "input.querySelectorAll('.cm-li-mark').length === 1", 5.0)
    probe = """(() => { const m = input.querySelector('.cm-li-mark'), l = input.querySelector('.cm-line');
      return { text: getComputedStyle(l).color, mark: getComputedStyle(m).color, disc: getComputedStyle(m, '::before').backgroundColor }; })()"""
    seen = {}
    for theme in ("dark", "light"):
        browser.send("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-color-scheme", "value": theme}]})
        got = seen[theme] = browser.evaluate(probe)
        assert got["disc"] == got["text"] and got["mark"] == got["text"], (theme, got)               # the disc is drawn by the ::before's background: the text colour
    assert seen["dark"]["text"] != seen["light"]["text"]                                             # the theme did change the colour
