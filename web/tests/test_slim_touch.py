"""A one-line row's button is slim under a finger on every page: 30 px drawn, a 44 px tap area, no sideways scroll (the shared `.slim-touch` class).

The owner's rule: the style guide fixes it once. The class `.slim-touch` in style.css draws a one-line row's button 30 px high under a coarse pointer
and gives it a 44 px tap area as an `::after` box that takes no room. It was written for the main page's Send and Reload inside index.html's own style, so the chat page (a page of its own, since retired:
the chat session is sala's own view now, with the one Send) got a tall Send of its own. This test holds it in a headless Chromium on a 412 px touch screen:
- the main page's Send and the update strip's Reload: drawn 30 px high, the `::after` box 44 px high (and at least 44 px wide), and the page does not scroll sideways.

The rule's text (one rule, no copy, every page loads style.css) is held in test_slim_touch_rule.py. A browser test: it runs in a headless Chromium when one
is installed, else is skipped; GitHub CI runs it. All names are invented.
"""

from __future__ import annotations

from conftest import CHAT_READY, NAME
from test_composer_touch_row import resize

NO_SIDEWAYS = "(() => { const r = document.scrollingElement; return { sw: r.scrollWidth, cw: r.clientWidth, w: innerWidth }; })()"

BUTTON = """((sel, show) => {
  if (show) document.getElementById('update-banner').hidden = false;
  const b = document.querySelector(sel), r = b.getBoundingClientRect(), a = getComputedStyle(b, '::after');
  return { coarse: matchMedia('(pointer: coarse)').matches, width: innerWidth, drawn: [r.width, r.height],
           after: { content: a.content, w: a.width, h: a.height }, position: getComputedStyle(b).position };
})"""


def tap_area(m: dict) -> tuple[float, float]:
    return float(m["after"]["w"][:-2]), float(m["after"]["h"][:-2])


def test_the_main_pages_send_and_reload_are_30px_with_a_44px_tap_area_and_the_page_does_not_scroll_sideways(served, browser):
    browser.open(f"{served['url']}/#s={NAME}")
    browser.wait_ready(CHAT_READY)
    browser.touch()
    for width in (412, 320):
        resize(browser, width, 915, True)
        send = browser.evaluate(BUTTON + "('#send', false)")
        reload_ = browser.evaluate(BUTTON + "('#reload-btn', true)")
        for name, m in (("Send", send), ("Reload", reload_)):
            assert m["coarse"] and m["width"] == width, (name, m)
            assert m["drawn"][1] == 30, (name, m)                      # drawn 30 px high
            assert m["after"]["content"] == '""' and m["position"] == "relative", (name, m)
            assert tap_area(m)[1] == 44 and tap_area(m)[0] >= 44, (name, m)   # a 44 px tap area
        assert send["drawn"] == [30, 30], send
        page = browser.evaluate(NO_SIDEWAYS)
        assert page["sw"] <= page["cw"], f"the main page scrolls sideways at {width} px: {page}"
