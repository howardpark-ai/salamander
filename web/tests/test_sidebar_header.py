"""The sidebar's top header is the app's icon and "salamander : <suffix>" on one line, the suffix being the SALA_BRAND_SUFFIX setting
(unset, the words are "salamander" alone; this file sets a made-up suffix so the longer form is the one measured).

Held here: the page markup (the icon is an <img> of the installed app's icon file with alt="" and a fixed width and height, the
text exact, the page <title> and the manifest still "sala"); and, in a headless Chromium, the header at 1280 px (the sidebar
pinned open, and peeking, where the header leaves 52 px for the toggle, fixed over it) and at 390 px (the drawer): the icon loaded and
20 x 20, the text the exact words on one line, icon and text on one row, nothing cut or beyond the sidebar, no overlap with the
drawer's close button."""

from __future__ import annotations

import time

import pytest
from starlette.testclient import TestClient

from sala_web.app import create_app
from sala_web.config import Settings
from test_back_button import open_app, tap_at
from test_board_items_ui import wait_for
from test_sidebar_hover import BODY, BTN, OPEN, click_button, move, open_wide

SUFFIX = "example fleet"
TEXT = "salamander : " + SUFFIX


@pytest.fixture(autouse=True)
def brand_suffix(monkeypatch):
    monkeypatch.setenv("SALA_BRAND_SUFFIX", SUFFIX)

MEASURE = r"""(() => {
  const head = document.querySelector('#sidebar .side-head'), line = head.querySelector('.brand-line'), img = line.querySelector('img'), text = line.querySelector('.brand');
  const r = (e) => { const b = e.getBoundingClientRect(); return { l: b.left, r: b.right, t: b.top, b: b.bottom, w: b.width, h: b.height }; };
  // the text is on one line when every client rect of its text node has the same top
  const range = document.createRange(); range.selectNodeContents(text);
  const tops = [...range.getClientRects()].filter((x) => x.width > 0).map((x) => Math.round(x.top));
  const close = document.getElementById('side-close'), sb = document.getElementById('sidebar').getBoundingClientRect();
  const ir = r(img), tr = r(text), cr = close && getComputedStyle(close).display !== 'none' ? r(close) : null;
  return { alt: img.getAttribute('alt'), src: img.getAttribute('src'), loaded: img.complete && img.naturalWidth > 0, attrW: img.getAttribute('width'), attrH: img.getAttribute('height'),
    img: ir, text: tr, textContent: text.textContent, lineText: line.textContent, tops: [...new Set(tops)], close: cr, headH: head.getBoundingClientRect().height,
    sbLeft: sb.left, sbRight: sb.right, lineScroll: line.scrollWidth - line.clientWidth, headScroll: head.scrollWidth - head.clientWidth,
    slack: (cr ? cr.l : sb.right - parseFloat(getComputedStyle(head).paddingRight)) - tr.r,
    sameRow: Math.abs((ir.t + ir.b) / 2 - (tr.t + tr.b) / 2) <= 3, docScroll: document.documentElement.scrollWidth - document.documentElement.clientWidth }; })()"""


def client(tmp_path):
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    (claude / "projects").mkdir()
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                        tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"])
    return TestClient(create_app(settings))


def test_the_markup_has_the_icon_and_the_words_and_the_name_stays_sala(tmp_path):
    c = client(tmp_path)
    html = c.get("/").text
    assert '<img class="brand-icon" src="static/icons/icon-192.png" width="20" height="20" alt="">' in html
    assert f'<span class="brand">{TEXT}</span>' in html and "{{brand}}" not in html           # the full text is in the served page (no flash); app.js repaints it from api/config
    assert c.get("/api/config").json()["brand"] == SUFFIX
    assert "<title>sala</title>" in html and "<span>sala was updated.</span>" in html          # the page's name and the banner keep "sala"
    assert c.get("/manifest.webmanifest").json()["name"] == "sala"
    assert c.get("/static/icons/icon-192.png").status_code == 200                              # the file the header and the installed app share


def check(got, where):
    assert got["alt"] == "" and got["src"] == "static/icons/icon-192.png" and got["loaded"], (where, got)   # decorative, the app's icon, loaded
    assert got["attrW"] == "20" and got["attrH"] == "20" and (got["img"]["w"], got["img"]["h"]) == (20, 20), (where, "the icon's size is not fixed", got)
    assert got["textContent"] == TEXT and got["lineText"] == TEXT, (where, got)                          # the exact words (the icon has no text)
    assert len(got["tops"]) == 1 and got["sameRow"] and got["text"]["h"] < 30 and got["headH"] <= 56, (where, "not one line", got)
    assert got["img"]["r"] <= got["text"]["l"] + 0.5, (where, "the icon is not before the words", got)
    assert got["lineScroll"] <= 0 and got["headScroll"] <= 0 and got["docScroll"] <= 0, (where, "something is cut or scrolls", got)
    assert got["img"]["l"] >= got["sbLeft"] and got["text"]["r"] <= got["sbRight"], (where, "outside the sidebar", got)
    assert got["slack"] >= 5, (where, "the words have no room to spare for a wider font", got["slack"])   # 5.8 px at 1280 in the look: the words are 15 px (was 14) and the gap 8 px (was 6)
    if got["close"]:
        assert got["text"]["r"] <= got["close"]["l"], (where, "the words run under the close button", got)


def test_a_pinned_sidebar_at_1280_shows_the_icon_and_the_words_on_one_line(served, browser):
    open_wide(browser, served)
    click_button(browser)
    assert wait_for(browser, "document.getElementById('sidebar').getBoundingClientRect().left === 0 && document.getElementById('main').getBoundingClientRect().left === 280", 5.0)
    assert browser.evaluate(BODY) == ["side-pin"]
    check(browser.evaluate(MEASURE), "pinned 1280")


def test_a_peeking_sidebar_at_1280_leaves_room_for_the_button_and_still_fits_the_words(served, browser):
    open_wide(browser, served)
    move(browser, 3, 400)
    assert wait_for(browser, OPEN, 5.0) and browser.evaluate(BODY) == ["side-peek"]
    time.sleep(0.3)                                                                           # the slide is over
    got = browser.evaluate(MEASURE)
    check(got, "peek 1280")
    btn = browser.evaluate("(() => { const b = document.getElementById('side-open').getBoundingClientRect(); return { r: b.right }; })()")
    assert got["img"]["l"] >= btn["r"] - 0.5, ("the icon sits under the toggle", got, btn)


def test_the_drawer_at_390_shows_the_icon_and_the_words_on_one_line(served, browser):
    open_app(browser, served, "#sessions", width=390)
    b = browser.evaluate(BTN)
    tap_at(browser, b["x"], b["y"])
    assert wait_for(browser, OPEN, 5.0) and browser.evaluate(BODY) == ["side-open"]
    time.sleep(0.3)
    got = browser.evaluate(MEASURE)
    assert got["close"] is not None, got                                                       # the drawer's own close button is there
    check(got, "drawer 390")
