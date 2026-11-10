"""The app is called "sala" wherever a user sees its name: the page title, the update banner, the manifest and the tab title the page keeps. The sidebar's header says
"salamander", and its configured suffix after it, beside the app's icon (test_sidebar_header.py).
The package, the units and the socket are named sala-web (sala_web), the settings are SALA_WEB_*, and an
identifier such as the version meta's name says sala-web; none of them is shown to a user."""

import re

import pytest
from starlette.testclient import TestClient

from sala_web.app import STATIC, create_app
from sala_web.config import Settings

from conftest import NAME

NAME_ATTRS = re.compile(r'(?:title|alt|placeholder|aria-label)="([^"]*)"')


@pytest.fixture
def client(tmp_path):
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    (claude / "projects").mkdir()
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                        tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"])
    return TestClient(create_app(settings))


def test_the_page_names_the_app_sala(client):
    html = client.get("/").text
    assert "<title>sala</title>" in html
    assert '<span class="brand">salamander</span>' in html   # the sidebar's header, served with its text (no suffix set); the name elsewhere stays sala
    assert '<span data-i18n="ui.banner.updated">sala was updated.</span>' in html
    # nothing the page shows says sala-web: the text between tags and the attributes a user can read
    shown = " ".join(re.findall(r">([^<]*)<", html)) + " " + " ".join(NAME_ATTRS.findall(html))
    assert "sala-web" not in shown.lower() and "salaweb" not in shown.lower(), shown
    assert '<meta name="sala-web-version"' in html  # an identifier app.js reads, never shown


def test_the_served_header_carries_the_suffix_escaped(client, monkeypatch):
    monkeypatch.setenv("SALA_BRAND_SUFFIX", "example fleet")
    assert '<span class="brand">salamander : example fleet</span>' in client.get("/").text   # in the markup, so a reload has no flash
    monkeypatch.setenv("SALA_BRAND_SUFFIX", "a<b>&c")
    html = client.get("/").text
    assert '<span class="brand">salamander : a&lt;b&gt;&amp;c</span>' in html and "{{brand}}" not in html


def test_the_manifest_and_the_scripts_name_it_sala(client):
    m = client.get("/manifest.webmanifest").json()
    assert m["name"] == "sala" and m["short_name"] == "sala"
    js = (STATIC / "app.js").read_text()
    assert 'let wantTitle = "sala";' in js and 'setTitle(name || "sala")' in js
    assert 'document.querySelector(\'meta[name="sala-web-version"]\')' in js  # reads the meta the page carries


def test_the_tab_title_is_sala_then_the_session_name(served, browser, monkeypatch):
    monkeypatch.setenv("SALA_BRAND_SUFFIX", "example fleet")
    browser.width, browser.height = 1280, 800   # a wide browser window with no view opens on the Overview (test_back_button.py)
    browser.open(f"{served['url']}/")
    wait = ("new Promise((res) => { const t0 = Date.now(); (function poll() {"
            "  if (document.querySelectorAll('#session-list .sess').length < 1 && Date.now() - t0 < 15000)"
            "    return setTimeout(poll, 100);"
            "  res({ title: document.title, brand: document.querySelector('#sidebar .brand').textContent });"
            "})(); })")
    got = browser.evaluate(wait)
    assert got == {"title": "Overview", "brand": "salamander : example fleet"}, got   # the sidebar's header; the tab names the view
    browser.open(f"{served['url']}/#s={NAME}")
    title = browser.evaluate("new Promise((res) => { const t0 = Date.now(); (function poll() {"
                             f"  if (document.title !== {NAME!r} && Date.now() - t0 < 15000) return setTimeout(poll, 100);"
                             "  res(document.title); })(); })")
    assert title == NAME
