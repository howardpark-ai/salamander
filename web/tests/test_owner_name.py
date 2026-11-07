"""The owner's name in the page's own text is a setting (sala_web.config.owner_name, SALA_OWNER_NAME), neutral by default.

Environment first, else a line of sala's config file; unset or empty it is "the owner". It reads in the New session page's hint and in
the words the form queues with the operation (spawn.words_for, side_words_for). conftest.py pins a made-up name for the older tests;
this file starts from nothing and sets what it needs. Every name used here is made up.
"""

import re
from datetime import datetime
from pathlib import Path

import pytest
from starlette.testclient import TestClient

from conftest import guard_pattern
from sala_web import spawn as SP
from sala_web.app import create_app
from sala_web.config import Settings, owner_name

STATIC = Path(__file__).resolve().parent.parent / "src" / "sala_web" / "static"


@pytest.fixture(autouse=True)
def nothing_set(tmp_path, monkeypatch):
    """No sala config and no owner setting: the neutral state."""
    monkeypatch.setenv("SALA_CONFIG", str(tmp_path / "no-such-config"))
    monkeypatch.delenv("SALA_OWNER_NAME", raising=False)


def sala_config(tmp_path, monkeypatch, text: str) -> None:
    f = tmp_path / "sala-config"
    f.write_text(text, encoding="utf-8")
    monkeypatch.setenv("SALA_CONFIG", str(f))


def client_of(tmp_path) -> TestClient:
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True, exist_ok=True)
    (claude / "projects").mkdir(exist_ok=True)
    s = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                 tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"])
    return TestClient(create_app(s))


NOW = datetime(2026, 10, 15, 23, 59)


def test_with_nothing_set_it_is_the_owner():
    assert owner_name() == "the owner"


def test_a_config_line_sets_the_name(tmp_path, monkeypatch):
    sala_config(tmp_path, monkeypatch, 'SALA_OWNER_NAME="Sam Example"\n')
    assert owner_name() == "Sam Example"


def test_the_environment_wins_over_the_config(tmp_path, monkeypatch):
    sala_config(tmp_path, monkeypatch, "SALA_OWNER_NAME=Sam\n")
    monkeypatch.setenv("SALA_OWNER_NAME", "Kim")
    assert owner_name() == "Kim"


def test_empty_is_the_default(monkeypatch):
    monkeypatch.setenv("SALA_OWNER_NAME", "")
    assert owner_name() == "the owner"


def test_it_is_one_short_line(monkeypatch):
    monkeypatch.setenv("SALA_OWNER_NAME", "a\nb   c")
    assert owner_name() == "a b c"
    monkeypatch.setenv("SALA_OWNER_NAME", "x" * 80)
    assert len(owner_name()) == 40


def test_the_words_a_form_queues_carry_it(monkeypatch):
    assert SP.words_for("front", "pytest-a", "projects/example", NOW).startswith("the owner, via the sala web form: new front pytest-a")
    monkeypatch.setenv("SALA_OWNER_NAME", "Sam")
    assert SP.words_for("back", "pytest-b", "projects/example", NOW).startswith("Sam, via the sala web form: new back pytest-b")
    req = SP.SpawnRequest(project="projects/example", role="", name="pytest-s", side=True, item="board#9001")
    assert SP.side_words_for(req, NOW).startswith("Sam, via the sala web form: new side conversation pytest-s")


def test_the_page_says_the_owner_until_the_config_names_one(tmp_path, monkeypatch):
    html = (STATIC / "index.html").read_text(encoding="utf-8")
    assert "a session {{owner}} talks to" in html   # the server fills it in
    client = client_of(tmp_path)
    assert "a session the owner talks to" in client.get("/").text
    sala_config(tmp_path, monkeypatch, 'SALA_OWNER_NAME="Sam Example"\n')
    assert "a session Sam Example talks to" in client.get("/").text   # read on each load


def test_the_name_is_escaped_in_the_page(tmp_path, monkeypatch):
    monkeypatch.setenv("SALA_OWNER_NAME", "<b>Sam</b> & co")
    text = client_of(tmp_path).get("/").text
    assert "a session &lt;b&gt;Sam&lt;/b&gt; &amp; co talks to" in text and "<b>Sam</b>" not in text


def test_no_placeholder_is_left_in_the_page(tmp_path):
    assert "{{owner}}" not in client_of(tmp_path).get("/").text


def test_the_shipped_page_and_the_spawn_words_name_nobody():
    """Runtime text outside comments: the page's static files and the spawn module carry no first-owner name."""
    names = guard_pattern(word=True)   # the names come from the environment (conftest.guard_pattern): the repository names nobody
    html = re.sub(r"<!--.*?-->", "", (STATIC / "index.html").read_text(encoding="utf-8"), flags=re.S)
    assert not names.search(html)
    src = (STATIC.parent / "spawn.py").read_text(encoding="utf-8")
    code = [ln for ln in src.splitlines() if ln.count('f"') + ln.count('"') and "via the sala web form" in ln]
    assert code and not any(names.search(ln) for ln in code)
