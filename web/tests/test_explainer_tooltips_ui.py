"""The (?) beside a text that explains, as a person meets it in headless Chromium: a mouse that rests on it, the keyboard's focus, a finger's tap, Escape and a
press elsewhere, and a box that stays inside a phone's width. The markup and the scripts are read as text in test_explainer_tooltips.py."""
import json
import time

import pytest

from test_board_items_ui import wait_for
from test_chat_onit_ui import HELP_BTN, MOVE_NOTE, MOVE_TAB, helped, open_strip, phone
from test_composer_editable import key
from test_new_session import click, ns, open_form, sala  # noqa: F401  (sala is a fixture)

SPOT = """((id) => { const b = document.querySelector('[aria-controls="' + id + '"]'), p = document.getElementById(id), br = b.getBoundingClientRect(), r = p.getBoundingClientRect();
  const shown = p.getClientRects().length > 0;
  return { shown, expanded: b.getAttribute('aria-expanded'), x: br.left + br.width / 2, y: br.top + br.height / 2, w: br.width, h: br.height,
    px: r.left + r.width / 2, py: r.top + 8, left: r.left, right: r.right, vw: document.documentElement.clientWidth,
    onTop: shown && p.contains(document.elementFromPoint(r.left + r.width / 2, r.top + 8)) }; })"""


def spot(browser, pid: str, scroll: bool = False) -> dict:
    if scroll:
        browser.evaluate(f"document.querySelector('[aria-controls=\"{pid}\"]').scrollIntoView({{ block: 'center' }}); ''")
    return browser.evaluate(f"{SPOT}({json.dumps(pid)})")


def shows(browser, pid: str, on: bool) -> None:
    assert wait_for(browser, f"document.getElementById({json.dumps(pid)}).hidden === {json.dumps(not on)}", 5.0), (on, spot(browser, pid))
    assert spot(browser, pid)["expanded"] == ("true" if on else "false")


def stays(browser, pid: str) -> None:
    time.sleep(0.6)   # longer than the wait before a box a mouse left is shut
    shows(browser, pid, True)


def mouse(browser, x: float, y: float) -> None:
    browser.send("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": x, "y": y})


def press(browser, x: float, y: float) -> None:
    mouse(browser, x, y)
    for kind in ("mousePressed", "mouseReleased"):
        browser.send("Input.dispatchMouseEvent", {"type": kind, "x": x, "y": y, "button": "left", "clickCount": 1})


def tap(browser, x: float, y: float) -> None:
    browser.send("Input.dispatchTouchEvent", {"type": "touchStart", "touchPoints": [{"x": x, "y": y}]})
    browser.send("Input.dispatchTouchEvent", {"type": "touchEnd", "touchPoints": []})


ROLE = "document.querySelector('input[name=ns-role]:checked').value"
AWAY = (1270, 790)


def test_a_mouse_resting_on_the_marker_shows_the_box_and_a_press_keeps_it(sala, served, browser):
    open_form(browser, served, width=1280, height=800)
    session, back = "exp-ui-ns-sessionHint", "exp-ui-ns-backHint"
    at = spot(browser, session, scroll=True)
    assert not at["shown"] and at["expanded"] == "false", at
    mouse(browser, at["x"], at["y"])
    shows(browser, session, True)
    box = spot(browser, session)
    assert box["onTop"] and box["left"] >= 0 and box["right"] <= box["vw"], box
    mouse(browser, box["px"], box["py"])          # the way into the box does not shut it
    stays(browser, session)
    mouse(browser, *AWAY)
    shows(browser, session, False)
    # hover, then a press: kept until the next press, wherever the mouse goes
    at = spot(browser, session)
    mouse(browser, at["x"], at["y"])
    shows(browser, session, True)
    press(browser, at["x"], at["y"])
    mouse(browser, *AWAY)
    stays(browser, session)
    press(browser, at["x"], at["y"])
    shows(browser, session, False)
    # the (?) beside the other choice picks nothing, and a press elsewhere shuts its box
    other = spot(browser, back)
    press(browser, other["x"], other["y"])
    shows(browser, back, True)
    assert browser.evaluate(ROLE) == "none"
    press(browser, *AWAY)
    shows(browser, back, False)
    # the one in a fold's summary does not unfold it
    more = spot(browser, "exp-ui-ns-defaultHint", scroll=True)
    press(browser, more["x"], more["y"])
    shows(browser, "exp-ui-ns-defaultHint", True)
    assert browser.evaluate("document.querySelector('.ns-more').open") is False


def test_the_keyboard_focus_shows_the_box_and_escape_shuts_only_the_box(sala, served, browser):
    open_form(browser, served, width=1280, height=800)
    pid, button = "ns-name-hint", "document.activeElement.getAttribute('aria-controls')"
    browser.evaluate("document.querySelector('#ns-name').focus(); ''")
    key(browser, "Tab", "Tab", 9, modifiers=8)    # back from the field to its (?)
    assert wait_for(browser, f"{button} === '{pid}'", 5.0), browser.evaluate("document.activeElement.outerHTML")
    shows(browser, pid, True)
    key(browser, "Escape", "Escape", 27)
    shows(browser, pid, False)
    assert browser.evaluate(button) == pid and browser.evaluate("SalaAddress.here()") == "#new" and ns(browser)["open"]
    key(browser, "Enter", "Enter", 13, "\r")
    shows(browser, pid, True)
    key(browser, "Tab", "Tab", 9)                 # on to the field: the box goes
    shows(browser, pid, False)
    assert browser.evaluate("document.activeElement.id") == "ns-name"


@pytest.mark.parametrize("width", [360, 390])
def test_a_tap_shows_each_box_of_the_new_session_forms_inside_a_phones_width(sala, served, browser, width):
    open_form(browser, served, width=width, height=844)
    browser.touch()
    assert wait_for(browser, "matchMedia('(pointer: coarse)').matches", 10.0)
    seen = "[...document.querySelectorAll('#new-pane .exp-help')].filter((b) => b.getClientRects().length).map((b) => b.getAttribute('aria-controls'))"
    want = {False: {"exp-ui-ns-sessionHint", "exp-ui-ns-backHint", "ns-name-hint", "exp-ui-ns-defaultHint"},
            True: {"exp-ui-sd-itemHint", "exp-ui-sd-forkHint", "exp-ui-sd-nameHint", "exp-ui-sd-topicHint"}}
    for quick in (False, True):
        if quick:
            click(browser, "#np-quick")
            assert wait_for(browser, "document.querySelector('[aria-controls=exp-ui-sd-itemHint]').getClientRects().length > 0", 5.0)
        ids = browser.evaluate(seen)
        assert want[quick] <= set(ids), ids
        for pid in ids:
            at = spot(browser, pid, scroll=True)
            assert at["w"] >= 43.9 and at["h"] >= 43.9 and not at["shown"], (pid, at)
            tap(browser, at["x"], at["y"])
            shows(browser, pid, True)
            box = spot(browser, pid)
            assert box["onTop"] and box["left"] >= 0 and box["right"] <= box["vw"] + 0.5, (pid, box)
            assert browser.evaluate("document.documentElement.scrollWidth") <= width, pid
            tap(browser, box["x"], box["y"])
            shows(browser, pid, False)
        if not quick:
            assert browser.evaluate(ROLE) == "none" and browser.evaluate("document.querySelector('.ns-more').open") is False


def test_the_chat_bars_marker_answers_a_mouse_and_the_keyboard(served, browser, monkeypatch):
    open_strip(browser, served, monkeypatch, (1280, 800))
    click(browser, "#chat-strip-tab-move")
    pop = "chat-strip-onit-help"
    at = spot(browser, pop)
    assert not at["shown"], at
    mouse(browser, at["x"], at["y"])
    shows(browser, pop, True)
    assert helped(browser)["text"] == MOVE_NOTE
    mouse(browser, 640, 790)
    shows(browser, pop, False)
    browser.evaluate(MOVE_TAB + ".focus(); ''")
    key(browser, "Tab", "Tab", 9)                 # the other tab is not in the tab order: the (?) is next
    assert wait_for(browser, f"document.activeElement === {HELP_BTN}", 5.0), browser.evaluate("document.activeElement.outerHTML")
    shows(browser, pop, True)
    key(browser, "Escape", "Escape", 27)
    shows(browser, pop, False)
    assert browser.evaluate(f"document.activeElement === {HELP_BTN}")


@pytest.mark.parametrize("width", [360, 390])
def test_a_tap_on_the_chat_bars_marker_shows_the_note_and_a_tap_elsewhere_shuts_it(served, browser, monkeypatch, width):
    open_strip(browser, served, monkeypatch, (width, 844))
    phone(browser, width)
    browser.touch()
    assert wait_for(browser, "matchMedia('(pointer: coarse)').matches", 10.0)
    browser.evaluate(MOVE_TAB + ".click(); ''")
    pop = "chat-strip-onit-help"
    browser.settle("document.querySelector('#chat-strip-wait')")
    at = spot(browser, pop)
    tap(browser, at["x"], at["y"])
    shows(browser, pop, True)
    h = helped(browser)
    assert h["text"] == MOVE_NOTE and h["box"]["left"] >= 0 and h["box"]["right"] <= width + 0.5, h
    tap(browser, width / 2, 780)
    shows(browser, pop, False)
