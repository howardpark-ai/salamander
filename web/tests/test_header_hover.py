"""The header's ⋯ menu opens on hover and sticks on a click (`hoverPin` in app.js). It shared that code with the board items' list under the item count button until Thu Nov 5th 2026, when the button and the list were removed; the menu's checks stay.

Held here, in a headless Chromium at 1280 px with real DevTools mouse events (so pointerType is "mouse"):
- the pointer on the trigger opens it after a moment, and leaving both the trigger and the popover closes it after a moment;
  moving from the trigger onto the menu keeps it open;
- a click on the trigger while it is open by hover PINS it: aria-expanded stays true, it stays after the pointer leaves and
  after 600 ms; a second click, Escape or a click outside closes it; a click before the hover timer has fired opens and pins;
- a tap (touch emulation) opens and closes the ⋯ menu as it always did, and the pointer-less hover logic does nothing.

Timing is polled with generous bounds (CI is loaded), not measured. What no test here can show is a real mouse on a real
browser: a headless Chromium's DevTools events stand in for it. Runs in a headless Chromium when one is installed, else skipped.
"""

from __future__ import annotations

import time

import pytest

from test_board_items_ui import wait_for
from test_composer_attach import WAIT_READY
from test_header_fold import set_width
from test_header_menu import FRONT, key

WAIT_S = 3.0      # an open or a close is polled for this long
HOLD_S = 0.6      # "still open" is read after this long, past both timers
STATE = """(() => { const b = document.body, q = (s) => document.querySelector(s);
  return { menu: b.classList.contains("top-menu-open"), menuAria: q("#top-menu-btn").getAttribute("aria-expanded") }; })()"""
MENU_OPEN = "document.body.classList.contains('top-menu-open')"
CENTRE = "(() => { const r = document.querySelector(%r).getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()"
ELSEWHERE = (640, 600)   # the chat area: nothing of the header or the menu


def open_page(browser, served) -> None:
    browser.open(f"{served['url']}/#s=demo")
    assert browser.evaluate(WAIT_READY)
    set_width(browser, 1280)
    move(browser, *ELSEWHERE)


def move(browser, x: float, y: float) -> None:
    browser.send("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": x, "y": y})


def over(browser, selector: str) -> None:
    c = browser.evaluate(CENTRE % selector)
    move(browser, c["x"], c["y"])


def click(browser, selector: str | None = None, at: tuple[float, float] | None = None) -> None:
    x, y = at or tuple(browser.evaluate(CENTRE % selector).values())
    move(browser, x, y)
    for t in ("mousePressed", "mouseReleased"):
        browser.send("Input.dispatchMouseEvent", {"type": t, "x": x, "y": y, "button": "left", "clickCount": 1})


def holds(browser, expr: str, want: bool, seconds: float = HOLD_S) -> bool:
    """`expr` is `want` now and still is after the timers have had their time."""
    time.sleep(seconds)
    return bool(browser.evaluate(expr)) == want


def menu_state(browser, open_: bool) -> dict:
    s = browser.evaluate(STATE)
    assert s["menu"] == open_ and s["menuAria"] == str(open_).lower(), s
    return s


# the one popover, by its trigger and its popover: (trigger, popover, open-expression, state check)
POPOVERS = {
    "menu": ("#top-menu-btn", "#top-tools", MENU_OPEN, menu_state),
}
BOTH = pytest.mark.parametrize("which", list(POPOVERS))


@BOTH
@pytest.mark.parametrize("served", [FRONT], indirect=True)
def test_hover_opens_it_and_leaving_closes_it(served, browser, which):
    trigger, _, opened, state = POPOVERS[which]
    open_page(browser, served)
    state(browser, False)
    over(browser, trigger)
    assert wait_for(browser, opened, WAIT_S), browser.evaluate(STATE)
    state(browser, True)
    move(browser, *ELSEWHERE)
    assert wait_for(browser, f"!({opened})", WAIT_S), browser.evaluate(STATE)
    state(browser, False)


@BOTH
@pytest.mark.parametrize("served", [FRONT], indirect=True)
def test_it_stays_open_while_the_pointer_is_on_the_popover(served, browser, which):
    trigger, popover, opened, state = POPOVERS[which]
    open_page(browser, served)
    over(browser, trigger)
    assert wait_for(browser, opened, WAIT_S)
    over(browser, popover)                       # off the trigger, onto the popover: the close timer is cancelled
    assert holds(browser, opened, True)
    over(browser, trigger)                       # and back again
    assert holds(browser, opened, True)
    state(browser, True)
    move(browser, *ELSEWHERE)
    assert wait_for(browser, f"!({opened})", WAIT_S)


@BOTH
@pytest.mark.parametrize("closer", ["second-click", "escape", "outside-click"])
@pytest.mark.parametrize("served", [FRONT], indirect=True)
def test_a_click_pins_it_until_a_second_click_escape_or_a_click_outside(served, browser, which, closer):
    trigger, _, opened, state = POPOVERS[which]
    open_page(browser, served)
    over(browser, trigger)
    assert wait_for(browser, opened, WAIT_S)
    click(browser, trigger)                      # a click while it is open by hover: pinned
    state(browser, True)
    move(browser, *ELSEWHERE)                    # the pointer leaves: it stays, now and after the close timer
    assert holds(browser, opened, True)
    assert holds(browser, opened, True)
    state(browser, True)
    if closer == "second-click":
        click(browser, trigger)
    elif closer == "escape":
        key(browser, "Escape", "Escape", 27)
    else:
        click(browser, at=ELSEWHERE)
    assert wait_for(browser, f"!({opened})", WAIT_S), browser.evaluate(STATE)
    state(browser, False)
    if closer == "second-click":                 # the pointer is on the trigger still: no new hover, it stays closed
        assert holds(browser, opened, False)


@BOTH
@pytest.mark.parametrize("served", [FRONT], indirect=True)
def test_a_click_before_the_hover_timer_opens_and_pins_it(served, browser, which):
    trigger, _, opened, state = POPOVERS[which]
    open_page(browser, served)
    click(browser, trigger)                      # the move and the press come straight after each other
    assert wait_for(browser, opened, WAIT_S)
    state(browser, True)
    move(browser, *ELSEWHERE)
    assert holds(browser, opened, True)          # pinned: the pointer leaving does not close it
    assert holds(browser, opened, True)
    state(browser, True)


@pytest.mark.parametrize("served", [FRONT], indirect=True)
def test_a_tap_toggles_the_menu_as_ever_and_hover_does_nothing(served, browser):
    browser.send("Emulation.setTouchEmulationEnabled", {"enabled": True, "maxTouchPoints": 5})
    open_page(browser, served)
    menu_state(browser, False)
    c = browser.evaluate(CENTRE % "#top-menu-btn")

    def tap() -> None:
        browser.send("Input.dispatchTouchEvent", {"type": "touchStart", "touchPoints": [{"x": c["x"], "y": c["y"]}]})
        browser.send("Input.dispatchTouchEvent", {"type": "touchEnd", "touchPoints": []})

    tap()
    assert wait_for(browser, MENU_OPEN, WAIT_S), browser.evaluate(STATE)
    menu_state(browser, True)
    assert holds(browser, MENU_OPEN, True)       # no hover logic closes it: a tap opens, the next tap closes
    tap()
    assert wait_for(browser, f"!({MENU_OPEN})", WAIT_S), browser.evaluate(STATE)
    menu_state(browser, False)
    assert holds(browser, MENU_OPEN, False)      # and the finger being there does not reopen it
    browser.send("Emulation.setTouchEmulationEnabled", {"enabled": False})
