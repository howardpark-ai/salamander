"""A Reload in the header's view options (the installed app had no way to reload in-app): standalone display has no browser bar, so the
page offers its own, always there, which keeps the composer's draft as the update banner's button does and brings the
fresh build (the static files are served no-cache and the worker never caches, so a plain reload is enough).

The page parts run in a headless Chromium when one is installed (conftest.py: `served`, `browser`), else skipped.
"""

from __future__ import annotations

import json
import time

import pytest

from conftest import NAME
from sala_web.app import STATIC
from test_composer_attach import WAIT_READY

INDEX = (STATIC / "index.html").read_text()


def test_the_header_has_a_reload_icon():
    """Since the lighter view (Tue Oct 27th 2026) Reload is an icon in the bar: no text label, its name is the
    aria-label and the tooltip."""
    assert '<button id="menu-reload" class="menu-item" type="button" aria-label="Reload the page" title="Reload the page"><svg' in INDEX
    button = INDEX[INDEX.index('<button id="menu-reload"'):]
    button = button[:button.index("</button>")]
    assert button.endswith("</svg>"), button   # nothing after the icon: no word
    # in the title bar's cluster (#top-end), right before the ⋯ button, not behind a condition; it moves into the ⋯ menu
    # (#top-tools) when the session name needs the room, as a row with the word (style.css, ::after), see test_header_fold.py
    assert INDEX.index('id="top-end"') < INDEX.index('id="menu-reload"') < INDEX.index('id="top-menu-btn"') < INDEX.index('id="top-tools"') < INDEX.index("</header>")
    assert '.top-tools #menu-reload::after { content: "Reload"; }' in (STATIC / "style.css").read_text()
    js = (STATIC / "app.js").read_text()
    # the draft is stored before the page goes (the mark names the reload's cause: test_timing_debug.py)
    assert 'function reloadPage(cause) { perfMark("reload", { cause: cause || "unknown" }); saveDraft(); location.reload(); }' in js
    assert '$("#menu-reload").addEventListener("click", (e) => { setTopMenu(false); if (e.detail === 0) $("#top-menu-btn").focus(); reloadPage("menu"); });' in js   # a keyboard activation puts the focus back on ⋯


# the composer's text, whichever element it is (a textarea, or an editable with the page's getText)
COMPOSER_TEXT = ("(() => { const i = document.querySelector('#input'); "
                 "return i.tagName === 'TEXTAREA' ? i.value : (typeof getText === 'function' ? getText() : i.textContent); })()")
MENU = """(() => { const b = document.querySelector("#menu-reload"), r = b.getBoundingClientRect(), m = document.querySelector("#top-tools");
  return { shown: !!(r.width && r.height), w: r.width, h: r.height, label: b.getAttribute("aria-label"), title: b.title,
           text: b.textContent.trim(), word: getComputedStyle(b, "::after").content,
           inMenu: m.contains(b), inBar: document.querySelector("#top-end").contains(b),
           open: document.body.classList.contains("top-menu-open"), width: innerWidth }; })()"""
WAIT_FRESH = """
new Promise((res) => { const t0 = Date.now(); (function poll() {
  if ((!window.__old && document.querySelectorAll("#chat > .msg").length >= 1) || Date.now() - t0 > 15000) res(!window.__old); else setTimeout(poll, 100);
})(); })
"""


def wait_fresh(browser) -> bool:
    """True once the page after the reload shows its messages. The click starts the reload from inside the page, so an
    evaluate issued right after it may land on the page that is going ("Inspected target navigated or closed"): ask again."""
    for _ in range(100):
        try:
            return browser.evaluate(WAIT_FRESH)
        except RuntimeError as e:
            if "navigated or closed" not in str(e):
                raise
            time.sleep(0.1)
    return False


def test_reload_from_the_menu_keeps_the_draft_and_loads_the_fresh_build(served, browser):
    """At a phone's width. The installed app's standalone display cannot be emulated here (DevTools has no
    display-mode feature), and nothing in the page depends on it: the item is in the page's own header."""
    browser.open(f"{served['url']}/#s={NAME}")
    assert browser.evaluate(WAIT_READY)
    bar = browser.evaluate(MENU)
    # an icon in the bar, one tap away: no word, its name is the label and the tooltip, a target of at least 32 px
    assert bar["width"] == 390 and bar["inBar"] and not bar["inMenu"] and bar["shown"] and not bar["open"], bar
    assert bar["text"] == "" and bar["word"] in ("none", "normal"), bar
    assert bar["label"] == "Reload the page" and bar["title"] == "Reload the page" and bar["h"] >= 32 and bar["w"] >= 32, bar
    # a draft in the composer, typed as from a keyboard; saved to storage a moment later
    browser.evaluate("document.querySelector('#input').focus(); ''")
    browser.send("Input.insertText", {"text": "draft 초안 kept"})
    assert browser.evaluate(COMPOSER_TEXT) == "draft 초안 kept"
    key = "localStorage.getItem('salaweb.draft.' + %s)" % json.dumps(NAME)
    browser.evaluate("new Promise((r) => setTimeout(r, 600))")  # saved 400 ms after the last keystroke
    assert browser.evaluate(key) == "draft 초안 kept"
    loaded = browser.evaluate("document.querySelector('meta[name=sala-web-version]').content")
    # the click: a reload navigation, the menu closed, the draft back in the composer and still kept in storage until it is sent
    browser.evaluate("window.__old = true; document.querySelector('#menu-reload').click(); ''")
    assert wait_fresh(browser)
    got = browser.evaluate("""(() => ({ nav: performance.getEntriesByType("navigation")[0].type, text: %s, draftLeft: %s,
      version: document.querySelector('meta[name=sala-web-version]').content, menuOpen: document.body.classList.contains("top-menu-open") }))()"""
                           % (COMPOSER_TEXT, key))
    assert got["nav"] == "reload" and got["text"] == "draft 초안 kept" and got["draftLeft"] == "draft 초안 kept" and not got["menuOpen"], got
    # the page loaded is the server's current build (what the update banner compares against)
    api = browser.evaluate("fetch('api/config', { cache: 'no-store' }).then((r) => r.json()).then((d) => d.version)")
    assert got["version"] == api == loaded and api, got
    # on a wide screen the icon sits in the header itself, no menu to open
    browser.send("Emulation.setDeviceMetricsOverride", {"width": 1280, "height": 800, "deviceScaleFactor": 1, "mobile": False})
    wide = browser.evaluate(MENU)
    assert wide["width"] == 1280 and wide["shown"] and wide["inBar"] and not wide["open"] and wide["h"] >= 28 and wide["text"] == "", wide


LONG = "gamma-harbor-crate-sorting-and-shelf-labeling-march-2031-rn"


@pytest.mark.parametrize("served", [{"name": LONG, "role": "front", "lane": "subscription-2", "status": "busy"}], indirect=True)
def test_where_the_name_needs_the_room_reload_is_a_row_with_its_word_in_the_menu(served, browser):
    """Folded into the ⋯ menu the icon becomes a touch-sized row that says Reload (the bar's icon has no word), and it is
    still the same labelled button."""
    browser.open(f"{served['url']}/#s={LONG}")
    assert browser.evaluate(WAIT_READY)
    browser.send("Emulation.setDeviceMetricsOverride", {"width": 600, "height": 844, "deviceScaleFactor": 1, "mobile": True})
    browser.evaluate("new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))")
    closed = browser.evaluate(MENU)
    assert closed["inMenu"] and not closed["inBar"] and not closed["shown"], closed   # behind the ⋯ button
    browser.evaluate("document.querySelector('#top-menu-btn').click(); ''")
    menu = browser.evaluate(MENU)
    assert menu["open"] and menu["shown"] and menu["h"] >= 44 and menu["w"] >= 44, menu
    assert menu["word"] == '"Reload"' and menu["label"] == "Reload the page" and menu["text"] == "", menu
