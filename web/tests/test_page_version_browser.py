"""In a real page: a server restart shows no "Reload" strip, a change to the page shows it, and a change to the style sheets alone is
swapped in place, with no strip and no reload.

The app serves a copy of static/ (`static_copy`), so a test can change the files the way a release does and then run the page's own
version check (the one that runs every 60 s): the page asks api/config and compares the answer with what it loaded.

- a "restart": every file touched (a new modification time, the same bytes) and the check run: no strip, nothing reloaded (a marker
  on the window survives), and the versions the page holds are the ones it had;
- a page change: one more line in app.js: the strip comes up (the page is visible and its composer holds text, so it does not
  reload by itself) and its Reload button is the same one as before;
- a style-only change: a rule added to style.css: the page swaps the sheet link in place, the new rule is in force within moments,
  there is still one link per sheet, no strip, the marker and the composer's text are as they were;
- the title suffix, the zone and the Shell names changed on the server are on the page after the same check, with no reload.

Runs in a headless Chromium when one is installed, else skipped (conftest.py: `served`, `browser`).
"""

from __future__ import annotations

import os
import shutil
import time

import pytest

from conftest import CHAT_READY, NAME
from sala_web import app as A

STRIP = "(() => { const b = document.getElementById('update-banner'); return !!b && !b.hidden && b.offsetHeight > 0; })()"
CHECK = "checkVersion().then(() => ({ strip: %s, styles: upd.styles, loaded: LOADED_STYLES, marker: window.__marker === 1 }))" % STRIP


@pytest.fixture
def static_copy(tmp_path, monkeypatch):
    """The app serves this copy of static/, which a test changes the way a release does (it must come before `served`)."""
    dst = tmp_path / "static"
    shutil.copytree(A.STATIC, dst)
    monkeypatch.setattr(A, "STATIC", dst)
    return dst


def touch_all(root) -> None:
    now = time.time() + 100   # a later time on every file: a checkout that wrote the same bytes again
    for p in root.rglob("*"):
        if p.is_file():
            os.utime(p, (now, now))


def wait_for(browser, condition: str, timeout_ms: int = 15000):
    return browser.evaluate("new Promise((res) => { const t0 = Date.now(); (function poll() {"
                            f"  const v = ({condition});"
                            f"  if (v || Date.now() - t0 > {timeout_ms}) return res(v);"
                            "  setTimeout(poll, 100); })(); })")


def open_chat(served, browser):
    browser.open(f"{served['url']}/#s={NAME}")
    browser.wait_ready(CHAT_READY)
    browser.evaluate("window.__marker = 1; ''")


def test_a_restart_that_changes_no_page_file_shows_no_strip(static_copy, served, browser):
    open_chat(served, browser)
    before = browser.evaluate("({ v: LOADED_VERSION, s: LOADED_STYLES })")
    assert before["v"] and before["s"]
    touch_all(static_copy)
    got = browser.evaluate(CHECK)
    assert got == {"strip": False, "styles": before["s"], "loaded": before["s"], "marker": True}, got
    assert browser.evaluate("upd.available") is False


def test_a_change_to_the_page_shows_the_strip(static_copy, served, browser):
    open_chat(served, browser)
    browser.evaluate("document.querySelector('#input').focus(); ''")
    browser.send("Input.insertText", {"text": "typed, not sent"})   # a composer with text never reloads by itself
    app_js = static_copy / "app.js"
    app_js.write_text(app_js.read_text() + "\n// a release changed the page\n")
    got = browser.evaluate(CHECK)
    assert got["strip"] is True and got["marker"] is True, got
    assert browser.evaluate("upd.available") is True
    assert browser.evaluate("document.getElementById('reload-btn').textContent.trim()") == "Reload"


def test_a_style_only_change_is_applied_in_place(static_copy, served, browser):
    open_chat(served, browser)
    browser.evaluate("document.querySelector('#input').focus(); ''")
    browser.send("Input.insertText", {"text": "draft kept"})
    links = browser.evaluate("[...document.querySelectorAll('link[rel=stylesheet][href^=\"static/\"]')].map((l) => l.getAttribute('href').split('?')[0])")
    assert links and "static/style.css" in links
    style = static_copy / "style.css"
    style.write_text(style.read_text() + "\n:root { --page-version-probe: 12px; }\n")
    got = browser.evaluate(CHECK)
    assert got["strip"] is False and got["marker"] is True and got["styles"] != got["loaded"], got
    # the new rule is in force once the new sheets have loaded, and the old ones are gone: one link per sheet
    assert wait_for(browser, "getComputedStyle(document.documentElement).getPropertyValue('--page-version-probe').trim() === '12px'")
    assert wait_for(browser, "document.querySelectorAll('link[rel=stylesheet][href^=\"static/\"]').length === %d" % len(links))
    now = browser.evaluate("[...document.querySelectorAll('link[rel=stylesheet][href^=\"static/\"]')].map((l) => l.getAttribute('href'))")
    assert [h.split("?")[0] for h in now] == links and all(h.endswith("?v=" + got["styles"]) for h in now), now
    # nothing was reloaded or lost
    assert browser.evaluate("window.__marker") == 1
    assert browser.evaluate("performance.getEntriesByType('navigation')[0].type") != "reload"
    assert browser.evaluate("getText()") == "draft kept"
    assert browser.evaluate("upd.available") is False
    # a second check with nothing new swaps nothing
    again = browser.evaluate(CHECK)
    assert again["strip"] is False and again["styles"] == got["styles"]


def test_the_suffix_the_zone_and_the_shell_names_follow_the_server_without_a_reload(static_copy, served, browser, monkeypatch):
    open_chat(served, browser)
    assert browser.evaluate("document.querySelector('.brand').textContent") == "salamander"
    monkeypatch.setenv("SALA_BRAND_SUFFIX", "second fleet")
    monkeypatch.setenv("SALA_TZ", "Europe/Berlin")
    monkeypatch.setattr(A, "SHELL_SESSION", "other-shell")
    got = browser.evaluate("checkVersion().then(() => ({ brand: document.querySelector('.brand').textContent, zone: zone.name, "
                           "shell: state.shellSession, chip: document.getElementById('shell-chip').textContent, marker: window.__marker === 1 }))")
    assert got["brand"] == "salamander : second fleet" and got["zone"] == "Europe/Berlin", got
    assert got["shell"] == "other-shell" and got["chip"].endswith("other-shell") and got["marker"] is True, got
