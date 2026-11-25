"""A one-line row's button is slim under a finger on every page: 30 px drawn, a 44 px tap area, no sideways scroll (the shared `.slim-touch` class).

The owner's rule: the style guide fixes it once. The class `.slim-touch` in style.css draws a one-line row's button 30 px high under a coarse pointer
and gives it a 44 px tap area as an `::after` box that takes no room. It was written for the main page's Send and Reload inside index.html's own style, so /chat
(which does not load that style) got a tall Send of its own. This test holds it on each page, in a headless Chromium on a 412 px touch screen:
- the main page's Send and the update strip's Reload: drawn 30 px high, the `::after` box 44 px high (and at least 44 px wide), and the page does not scroll sideways;
- the chat page's Send: drawn 30 x 30, the `::after` box 44 x 44, the compose row no taller than 52 px (it was 62 with a 44 px Send), and the page does not scroll sideways at 412 and 320 px;
- with a mouse at 1280 px, as before: the chat Send is 32 x 32 with no `::after` box.

The rule's text (one rule, no copy, every page loads style.css) is held in test_slim_touch_rule.py. A browser test: it runs in a headless Chromium when one
is installed, else is skipped; GitHub CI runs it. All names are invented.
"""

from __future__ import annotations

from conftest import CHAT_READY, NAME
from test_chat_no_sideways_scroll import MEASURE as CHAT_SCROLL, answer, check, open_chat, stub
from test_board_items_ui import wait_for
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


def test_the_chat_pages_send_is_30px_with_a_44px_tap_area_and_the_page_does_not_scroll_sideways(served, browser):
    open_chat(browser, served, answer("live"), 412)
    browser.touch()
    for width in (412, 320):
        resize(browser, width, 915, True)
        browser.settle("document.getElementById('cp')")
        m = browser.evaluate(BUTTON + "('.send-btn', false)")
        row = browser.evaluate("document.querySelector('.compose-row').getBoundingClientRect().height")
        assert m["coarse"] and m["width"] == width, m
        assert m["drawn"] == [30, 30], m
        assert m["after"]["content"] == '""' and tap_area(m) == (44, 44) and m["position"] == "relative", m
        assert row <= 52, row                                          # the textarea's line sets the row (50 px); a 44 px Send made it 62
        check(browser.evaluate(CHAT_SCROLL), f"chat at {width} px with a touch screen")


def test_the_chat_pages_send_keeps_32px_and_no_tap_box_with_a_mouse(served, browser):
    open_chat(browser, served, answer("live"), 1280)
    resize(browser, 1280, 800, False)
    m = browser.evaluate(BUTTON + "('.send-btn', false)")
    assert not m["coarse"] and m["width"] == 1280, m
    assert m["drawn"] == [32, 32] and m["after"]["content"] == "none", m


DISABLED = """(() => {
  const b = document.querySelector('.send-btn'); b.disabled = true; const c = getComputedStyle(b), r = b.getBoundingClientRect();
  return { bg: c.backgroundColor, fg: c.color, op: c.opacity, size: [r.width, r.height] };
})()"""


def theme(browser, dark: bool) -> None:
    browser.send("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-color-scheme", "value": "dark" if dark else "light"}]})


def test_the_chat_pages_disabled_send_looks_like_the_main_pages(served, browser):
    """The same background, text color, opacity and (with a mouse) size on both pages, in the light theme and the dark one (the emulated theme is set before each page opens: it stays on the tab once set, so a light run after a dark one would still be dark)."""
    main = {}
    for dark in (False, True):
        theme(browser, dark)
        browser.open(f"{served['url']}/#s={NAME}", dark=dark)
        browser.wait_ready(CHAT_READY)
        resize(browser, 1280, 800, False)
        main[dark] = browser.evaluate(DISABLED)
        assert browser.evaluate(f"matchMedia('(prefers-color-scheme: dark)').matches") is dark
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": stub(answer("live"))})
    for dark in (False, True):
        theme(browser, dark)
        browser.open(f"{served['url']}/chat", dark=dark)
        assert wait_for(browser, "document.querySelectorAll('.thread .msg').length >= 3", 60.0), "the chat page did not draw"
        resize(browser, 1280, 800, False)
        assert browser.evaluate(f"matchMedia('(prefers-color-scheme: dark)').matches") is dark
        chat = browser.evaluate(DISABLED)
        assert chat == main[dark], f"/chat's disabled Send differs from the main page's ({'dark' if dark else 'light'}): {chat} vs {main[dark]}"
    assert main[False] != main[True], main   # the two themes differ, so the comparison is not of one theme twice
    assert main[True]["size"] == [32, 32], main
