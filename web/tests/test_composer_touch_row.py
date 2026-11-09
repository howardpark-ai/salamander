"""The one-line composer row keeps its height under a finger: the Send button is drawn at 30 px with a 44 px tap area.

The look sizes its controls by pointer (`--ctl`: 32 px with a mouse, 44 px on a touch screen). Sizing the Send button by
`--ctl` too made it 44 px tall on a phone, and the composer's row (8 px padding twice, a 1 px border twice, the button between)
grew from 48 px to 62 px, 14 px of the screen taken from the conversation on every phone. The button is now drawn at 30 px on a
touch screen and reaches its 44 px tap area with an `::after` box, the way the paperclip (`.attach-btn`) reaches its own: the
box is part of the button for a tap and takes no room in the row.

Held here, in a headless Chromium:
- on a 412 px touch screen (`(pointer: coarse)`): the one-line row is 48 px, the Send button is drawn 30 x 30 and its tap
  area is 44 x 44, read two ways: the `::after` box's computed size, and what a tap lands on (the point just inside each
  edge of the 44 px square hits the button, the point just outside does not);
- the other controls still follow `--ctl` there: the Shell button is at least 44 px tall;
- with a mouse, at 1280 px: the row is 50 px, the button 32 x 32, and the button has no `::after` box (desktop is as it was).

Runs in a headless Chromium when one is installed, else skipped.
"""

from __future__ import annotations

import time

from conftest import NAME
from test_composer_attach import WAIT_READY

# The viewport override reaches the renderer a moment after its DevTools call returns: wait until the page is that wide.
SETTLED = "new Promise((ok) => requestAnimationFrame(() => requestAnimationFrame(() => ok(innerWidth))))"
MEASURE = """(() => {
  const send = document.querySelector('.send-btn'), row = document.querySelector('.compose-row');
  const s = send.getBoundingClientRect(), r = row.getBoundingClientRect(), a = getComputedStyle(send, '::after');
  const hits = (x, y) => document.elementFromPoint(x, y) === send;
  const cx = s.left + s.width / 2, cy = s.top + s.height / 2;
  return { coarse: matchMedia('(pointer: coarse)').matches, width: innerWidth, row: r.height, send: [s.width, s.height],
           shell: document.querySelector('#shell-btn').getBoundingClientRect().height,
           after: { content: a.content, w: a.width, h: a.height },
           inside: [hits(cx - 21, cy), hits(cx + 21, cy), hits(cx, cy - 21), hits(cx, cy + 21)],
           outside: [hits(cx - 23, cy), hits(cx + 23, cy), hits(cx, cy - 23), hits(cx, cy + 23)] };
})()"""


def resize(browser, width: int, height: int, mobile: bool) -> None:
    browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": height, "deviceScaleFactor": 1, "mobile": mobile})
    deadline = time.monotonic() + 10
    while browser.evaluate(SETTLED) != width:
        assert time.monotonic() < deadline, f"the {width}px viewport never took effect"
        time.sleep(0.05)


def test_a_phone_keeps_the_one_line_row_at_48px_with_a_30px_send_and_a_44px_tap_area(served, browser):
    browser.open(f"{served['url']}/#s={NAME}")
    assert browser.evaluate(WAIT_READY)
    browser.touch()
    resize(browser, 412, 915, True)
    m = browser.evaluate(MEASURE)
    assert m["coarse"] and m["width"] == 412, m
    assert m["row"] == 48, m                     # 8 + 30 + 8 padding and 2 px of border: the button no taller than 30
    assert m["send"] == [30, 30], m              # drawn at 30 px
    assert m["after"]["content"] == '""' and (m["after"]["w"], m["after"]["h"]) == ("44px", "44px"), m   # its tap area, 44 px
    assert all(m["inside"]) and not any(m["outside"]), m   # a tap anywhere in the 44 px square lands on the button, none beyond it
    assert m["shell"] >= 44, m                   # the other controls keep the 44 px of --ctl


def test_a_desktop_keeps_the_row_at_50px_and_the_send_button_at_32px_with_no_extra_tap_area(served, browser):
    browser.open(f"{served['url']}/#s={NAME}")
    assert browser.evaluate(WAIT_READY)
    resize(browser, 1280, 800, False)
    m = browser.evaluate(MEASURE)
    assert not m["coarse"] and m["width"] == 1280, m
    assert m["row"] == 50 and m["send"] == [32, 32], m
    assert m["after"]["content"] == "none", m
