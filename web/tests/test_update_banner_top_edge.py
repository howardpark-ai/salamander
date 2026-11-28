"""On a phone nothing fixed and top-anchored is left rendered over the top of the screen while the drawer is closed.

The phone's sidebar drawer is `position: fixed`, anchored at the top and as tall as the screen, and used to be closed by sliding it
off to the left with a transform only. It stayed rendered there. iOS 26 WebKit reads a rendered, top-anchored fixed box as a top
bar and softens the strip under the status bar for it, so the "sala was updated" strip, the first thing under the status bar,
came out blurred, and taps near the top edge were taken badly. The closed drawer is now hidden (`visibility: hidden`, held back
until the slide has ended), and opening it shows it at once.

Held here, in a headless Chromium at a phone's size with the update strip shown: closed, the drawer is hidden and no fixed box
that is rendered touches the top of the screen; the strip's Reload button is what a point on it hits; opened, the drawer is
visible and on screen; closed again, it is hidden once the slide has ended. The real iOS blur cannot be driven from this box, so
the test pins the cause (a rendered fixed top box), not the pixels.

Runs in a headless Chromium when one is installed, else skipped.
"""

from __future__ import annotations

import time

from conftest import CHAT_READY, NAME
from test_composer_touch_row import resize

STATE = """(() => {
  const banner = document.getElementById('update-banner'), btn = document.getElementById('reload-btn');
  banner.hidden = false;
  const side = document.getElementById('sidebar'), cs = getComputedStyle(side), r = side.getBoundingClientRect();
  const b = btn.getBoundingClientRect();
  const hit = document.elementFromPoint(b.left + b.width / 2, b.top + b.height / 2);
  const rendered = [...document.body.querySelectorAll('*')].filter((e) => {
    const s = getComputedStyle(e), q = e.getBoundingClientRect();
    return s.position === 'fixed' && s.display !== 'none' && s.visibility !== 'hidden' && q.width > 0 && q.height > 0
      && q.top <= 0 && q.bottom > 0 && q.right > 0 && q.left < innerWidth;
  }).map((e) => e.id || e.className);
  return { visibility: cs.visibility, pos: cs.position, left: r.left, right: r.right, open: document.body.classList.contains('side-open'),
    topFixed: rendered, hitReload: !!hit && (hit === btn || btn.contains(hit)) };
})()"""


def settle(browser, want: str) -> dict:
    deadline = time.monotonic() + 5
    while True:
        s = browser.evaluate(STATE)
        arrived = s["visibility"] == want and (want == "hidden" or s["left"] >= 0)  # opening flips visibility first, the slide follows
        if arrived or time.monotonic() > deadline:
            return s
        time.sleep(0.05)


def test_the_closed_phone_drawer_is_hidden_and_no_fixed_box_lies_over_the_top(served, browser):
    browser.open(f"{served['url']}/#s={NAME}")
    browser.wait_ready(CHAT_READY)
    browser.touch()
    resize(browser, 412, 915, True)

    s = settle(browser, "hidden")
    assert s["pos"] == "fixed" and s["right"] <= 0 and not s["open"], s
    assert s["visibility"] == "hidden", s
    assert s["topFixed"] == [], s
    assert s["hitReload"], s

    browser.evaluate("document.body.classList.add('side-open'); ''")
    s = settle(browser, "visible")
    assert s["visibility"] == "visible" and s["left"] >= 0 and s["right"] > 0 and s["open"], s

    browser.evaluate("document.body.classList.remove('side-open'); ''")
    s = settle(browser, "hidden")
    assert s["visibility"] == "hidden" and s["topFixed"] == [], s
