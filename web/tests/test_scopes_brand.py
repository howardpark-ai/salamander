"""The scopes and the title bar's name are settings, and nothing about them is built in (sala_web.scopes, config.brand_suffix).

Scopes come from SALA_SCOPES and SALA_DEFAULT_SCOPE (environment, else a line of sala's config file) when SALA_SCOPES is set, else
from stackshot's own file ($XDG_CONFIG_HOME/stackshot/stackshot.toml, [project_scopes] order and default), else there are none. SALA_BRAND_SUFFIX
is what follows "salamander" in the page's title bar; unset, the bar says "salamander" alone. conftest.py gives the older tests
their own made-up scopes through the environment; this file starts from nothing and sets what it needs. The scope names used here
are made up ("work", "home", "lab") and name nobody.
"""

import json
import re
from pathlib import Path

import pytest
from starlette.testclient import TestClient

from conftest import guard_pattern
from sala_web import projpick as PP
from sala_web import scopes as SC
from sala_web import sessions as S
from sala_web.app import create_app
from sala_web.config import Settings, brand_suffix, sala_setting

STATIC = Path(__file__).resolve().parent.parent / "src" / "sala_web" / "static"


@pytest.fixture(autouse=True)
def nothing_set(tmp_path, monkeypatch):
    """No stackshot file, no sala config, no scope or brand setting: the neutral state."""
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "xdg"))
    monkeypatch.setenv("SALA_CONFIG", str(tmp_path / "no-such-config"))
    for v in ("SALA_SCOPES", "SALA_DEFAULT_SCOPE", "SALA_BRAND_SUFFIX", "SALA_HELP_SESSION"):
        monkeypatch.delenv(v, raising=False)


def stackshot_toml(tmp_path, text: str) -> None:
    d = tmp_path / "xdg" / "stackshot"
    d.mkdir(parents=True, exist_ok=True)
    (d / "stackshot.toml").write_text(text, encoding="utf-8")


def sala_config(tmp_path, monkeypatch, text: str) -> None:
    f = tmp_path / "sala-config"
    f.write_text(text, encoding="utf-8")
    monkeypatch.setenv("SALA_CONFIG", str(f))


def config_of(tmp_path) -> dict:
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True, exist_ok=True)
    (claude / "projects").mkdir(exist_ok=True)
    s = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                 tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"])
    return TestClient(create_app(s)).get("/api/config").json()


# ── where the scopes come from ───────────────────────────────────────────────
def test_with_nothing_set_there_are_no_scopes_and_no_default():
    assert SC.names() == [] and SC.default() == ""


def test_the_setting_gives_the_scopes_in_its_order(monkeypatch):
    monkeypatch.setenv("SALA_SCOPES", "work home lab")
    assert SC.names() == ["work", "home", "lab"] and SC.default() == "work"   # no default set: the first
    monkeypatch.setenv("SALA_DEFAULT_SCOPE", "home")
    assert SC.default() == "home"
    monkeypatch.setenv("SALA_DEFAULT_SCOPE", "elsewhere")
    assert SC.default() == "work"   # a default that is not a scope is not one


def test_the_setting_is_read_from_sala_config_when_the_environment_has_none(tmp_path, monkeypatch):
    sala_config(tmp_path, monkeypatch, 'SALA_SCOPES="work home"   # the fleet\nSALA_DEFAULT_SCOPE=home\n')
    assert SC.names() == ["work", "home"] and SC.default() == "home"


def test_a_set_scopes_setting_wins_over_stackshots_file_order_and_default_included(tmp_path, monkeypatch):
    stackshot_toml(tmp_path, '[project_scopes]\norder = ["lab", "field"]\ndefault = "field"\n')
    monkeypatch.setenv("SALA_SCOPES", "home work")
    assert SC.names() == ["home", "work"] and SC.default() == "home"   # the file's default is not one of the setting's scopes
    monkeypatch.setenv("SALA_DEFAULT_SCOPE", "work")
    assert SC.default() == "work"


def test_stackshots_file_is_used_only_when_the_setting_is_unset(tmp_path, monkeypatch):
    stackshot_toml(tmp_path, '[project_scopes]\norder = ["lab", "field"]\ndefault = "field"\n')
    assert SC.names() == ["lab", "field"] and SC.default() == "field"
    monkeypatch.setenv("SALA_SCOPES", "   ")   # blank is unset
    assert SC.names() == ["lab", "field"]
    monkeypatch.setenv("SALA_SCOPES", "work")
    assert SC.names() == ["work"]


def test_a_stackshot_file_without_scopes_leaves_the_setting(tmp_path, monkeypatch):
    stackshot_toml(tmp_path, '[instance]\nboard_url = "https://board.example.com"\n')
    monkeypatch.setenv("SALA_SCOPES", "work home")
    assert SC.names() == ["work", "home"]


def test_an_odd_scope_entry_is_dropped_not_trusted(tmp_path):
    stackshot_toml(tmp_path, '[project_scopes]\norder = ["work", "Bad Name", 3, "work", "../x", "home"]\n')
    assert SC.names() == ["work", "home"]


def test_a_changed_file_is_seen_without_a_restart(tmp_path):
    stackshot_toml(tmp_path, '[project_scopes]\norder = ["work"]\n')
    assert SC.names() == ["work"]
    stackshot_toml(tmp_path, '[project_scopes]\norder = ["work", "home"]\n')
    assert SC.names() == ["work", "home"]


# ── what uses them ───────────────────────────────────────────────────────────
def test_a_session_is_in_the_scope_its_name_starts_with(monkeypatch):
    assert S.session_scope("work-docs-main") == S.OTHER_SCOPE   # none set: everything is "other"
    monkeypatch.setenv("SALA_SCOPES", "work home")
    assert S.session_scope("work-docs-main") == "work" and S.session_scope("home-garden-main") == "home"
    assert S.session_scope("lab-x-main") == S.OTHER_SCOPE and S.session_scope("scratch") == S.OTHER_SCOPE
    assert S.project_title("projects/work-docs", "work") == "docs"


def test_the_sidebar_groups_follow_the_scopes_then_other(monkeypatch):
    roles = {n: {"role": "front", "project": "projects/" + n} for n in ("home-a-main", "work-b-main", "stray-c-main")}
    live = [S.Session(pid=1, session_id=n, name=n, cwd="/tmp", status="idle", tmux="") for n in roles]
    assert [g["key"] for g in S.group_sessions(live, roles)] == ["other"]   # none set: one group, nothing built in
    monkeypatch.setenv("SALA_SCOPES", "work home")
    assert [g["key"] for g in S.group_sessions(live, roles)] == ["work", "home", "other"]
    monkeypatch.setenv("SALA_SCOPES", "home work")
    assert [g["key"] for g in S.group_sessions(live, roles)] == ["home", "work", "other"]


def test_the_project_form_checks_a_scope_against_the_list_when_there_is_one(monkeypatch):
    new = {"key": "projects/ir", "scope": "work"}
    assert PP.validate_new(new, ["projects"]) != (400, "")   # none set: any scope-shaped name goes through to stackshot
    assert isinstance(PP.validate_new(new, ["projects"]), dict)
    assert PP.validate_new({**new, "scope": "Not A Scope"}, ["projects"])[0] == 400
    assert "lowercase letters, digits and dashes" in PP.validate_new({**new, "scope": "Not A Scope"}, ["projects"])[1]
    monkeypatch.setenv("SALA_SCOPES", "work home")
    assert isinstance(PP.validate_new(new, ["projects"]), dict)
    code, msg = PP.validate_new({**new, "scope": "lab"}, ["projects"])
    assert code == 400 and msg == "scope must be one of work, home"
    assert PP.validate_query({"scope": "all"}) == ("all", "") and PP.validate_query({"scope": "home", "q": "x"}) == ("home", "x")
    assert PP.validate_query({"scope": "lab"}) == (400, "scope must be one of work, home, all")
    assert PP.validate_list({"key": "projects/ir", "scope": "lab"}, ["projects"]) == (400, "scope must be one of work, home")


# ── what the page is told ────────────────────────────────────────────────────
def test_the_page_is_told_no_scopes_and_no_brand_by_default(tmp_path):
    c = config_of(tmp_path)
    assert c["brand"] == "" and c["scopes"] == [] and c["defaultScope"] == ""


def test_the_page_is_told_the_scopes_the_default_and_the_brand(tmp_path, monkeypatch):
    sala_config(tmp_path, monkeypatch, "SALA_SCOPES='work home'\nSALA_DEFAULT_SCOPE=home\nSALA_BRAND_SUFFIX=\"example fleet\"\n")
    c = config_of(tmp_path)
    assert c["scopes"] == ["work", "home"] and c["defaultScope"] == "home" and c["brand"] == "example fleet"


def test_the_brand_is_one_short_line(monkeypatch):
    monkeypatch.setenv("SALA_BRAND_SUFFIX", "  a\tb \n c  ")
    assert brand_suffix() == "a b c"
    monkeypatch.setenv("SALA_BRAND_SUFFIX", "x" * 100)
    assert len(brand_suffix()) == 40
    assert sala_setting("SALA_BRAND_SUFFIX").startswith("x")


# ── the shipped page, manifest and units name no owner ───────────────────────
OWNER = guard_pattern(re.I)   # the names to keep out come from the environment (conftest.guard_pattern): the repository names nobody


def test_the_page_says_salamander_alone_until_the_config_adds_a_suffix(tmp_path, monkeypatch):
    html = (STATIC / "index.html").read_text(encoding="utf-8")
    assert '<span class="brand">{{brand}}</span>' in html   # the server fills it in
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True, exist_ok=True)
    (claude / "projects").mkdir(exist_ok=True)
    s = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                 tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"])
    client = TestClient(create_app(s))
    assert '<span class="brand">salamander</span>' in client.get("/").text
    sala_config(tmp_path, monkeypatch, 'SALA_BRAND_SUFFIX="example fleet"\n')
    assert '<span class="brand">salamander : example fleet</span>' in client.get("/").text   # read on each load
    m = re.search(r"<title>(.*?)</title>", html)
    assert m and not OWNER.search(m.group(1))
    js = (STATIC / "app.js").read_text(encoding="utf-8")
    assert 'suffix ? "salamander : " + suffix : "salamander"' in js


def test_the_manifest_names_no_owner_and_no_machine():
    man = json.loads((STATIC / "manifest.webmanifest").read_text(encoding="utf-8"))
    for k in ("name", "short_name", "description"):
        assert man[k] and not OWNER.search(man[k]), (k, man[k])


def test_the_page_script_has_no_scope_list_of_its_own():
    js = (STATIC / "app.js").read_text(encoding="utf-8")
    assert "NS_SCOPES" not in js and '["alpha", "beta", "gamma"]' not in js


def test_the_shipped_unit_descriptions_name_no_owner_and_no_machine():
    root = Path(__file__).resolve().parents[2]
    files = [*(root / "systemd").glob("*"), *(root / "web" / "contrib").glob("*")]
    descs = [(f.name, line) for f in files if f.is_file() for line in f.read_text(encoding="utf-8", errors="replace").splitlines()
             if line.startswith("Description=")]
    assert descs
    for name, line in descs:
        assert not OWNER.search(line), (name, line)


def test_the_get_help_chip_opens_the_session_the_setting_names_and_is_absent_without_one(tmp_path, monkeypatch):
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True, exist_ok=True)
    (claude / "projects").mkdir(exist_ok=True)
    s = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                 tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"])
    client = TestClient(create_app(s))
    html = client.get("/").text
    assert 'id="sp-help"' not in html and "{{help}}" not in html and "<!--help-->" not in html   # nothing set: no chip
    sala_config(tmp_path, monkeypatch, "SALA_HELP_SESSION=ui-helper\n")
    html = client.get("/").text
    assert 'id="sp-help"' in html and 'href="#s=ui-helper"' in html and "{{help}}" not in html   # read on each load
    sala_config(tmp_path, monkeypatch, 'SALA_HELP_SESSION="a b<script>"\n')
    assert 'id="sp-help"' not in client.get("/").text   # not a session name: no chip


# ── the pages checkout and its dirs: SALA_WEB_* first, then stackshot's own file, then sala's SALA_BRAIN_DIR / SALA_PAGE_DIRS ──
def test_with_nothing_set_there_is_no_pages_checkout_and_the_dir_is_projects(monkeypatch):
    from sala_web import config as C
    for v in ("SALA_WEB_BRAIN_DIR", "SALA_WEB_PAGE_DIRS", "SALA_BRAIN_DIR", "SALA_PAGE_DIRS"):
        monkeypatch.delenv(v, raising=False)
    assert C._brain_dir() is None and C._page_dirs() == ["projects"]


def test_the_pages_checkout_and_dirs_come_from_sala_config(tmp_path, monkeypatch):
    from sala_web import config as C
    for v in ("SALA_WEB_BRAIN_DIR", "SALA_WEB_PAGE_DIRS", "SALA_BRAIN_DIR", "SALA_PAGE_DIRS"):
        monkeypatch.delenv(v, raising=False)
    cfg = tmp_path / "config"
    cfg.write_text('SALA_BRAIN_DIR=~/demo-pages\nSALA_PAGE_DIRS="projects ops"   # made-up\n', encoding="utf-8")
    monkeypatch.setenv("SALA_CONFIG", str(cfg))
    assert C._brain_dir() == C.Path.home() / "demo-pages" and C._page_dirs() == ["projects", "ops"]


def test_no_pages_checkout_is_an_empty_project_list_with_its_reason():
    import asyncio
    from sala_web import spawn as SP
    cache = SP.PagesCache(None, ["projects"])
    assert asyncio.run(cache.get()) == [] and cache.error == "no pages checkout: SALA_BRAIN_DIR is not set"
