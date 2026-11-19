"""iPhone and iPad: the viewport meta gets `maximum-scale=1` so WebKit does not zoom in to a focused text field under 16 px
(the composer and the forms are 15 px) and stay zoomed. Every other browser keeps the tag as the file has it: Chrome on Android
honours maximum-scale and would lose pinch zoom. The script is in the head of index.html and terminal.html, after the tag.

Kept (a headless Chromium with a user agent override, the real page served by the `served` fixture): an iPhone, an iPad and an
iPhone in Chrome's iOS build (CriOS: WebKit too) get it; a desktop Chromium, an Android phone (with and without touch points) and
a Mac (a MacIntel platform with no touch screen) do not; iPadOS in its desktop mode (a Mac user agent, platform MacIntel, 5 touch
points) does; the terminal page follows the same rule. Not covered, and why: WebKit itself (no WebKit in the suite).
"""

import re
import time

import pytest

IPHONE = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) "
          "Version/17.5 Mobile/15E148 Safari/604.1")
IPAD = ("Mozilla/5.0 (iPad; CPU OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) "
        "Version/17.5 Mobile/15E148 Safari/604.1")
IOS_CHROME = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) "
              "CriOS/126.0.6478.153 Mobile/15E148 Safari/604.1")
MAC_SAFARI = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
              "Version/17.5 Safari/605.1.15")
ANDROID = ("Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) "
           "Chrome/126.0.0.0 Mobile Safari/537.36")
DESKTOP = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
           "Chrome/126.0.0.0 Safari/537.36")

BASE = "width=device-width, initial-scale=1, viewport-fit=cover, interactive-widget=resizes-content"
TERMINAL_BASE = "width=device-width, initial-scale=1, viewport-fit=cover"
VIEWPORT = "document.querySelector('meta[name=viewport]').content"


def open_as(browser, url, user_agent, platform="", touch_points=None):
    """Open url as that browser: the user agent and navigator.platform set before the page's first script, and
    maxTouchPoints overridden by an init script when given (a headless Chromium has no touch screen: 0)."""
    browser.send("Emulation.setUserAgentOverride", {"userAgent": user_agent, "platform": platform})
    if touch_points is not None:
        browser.send("Page.enable")   # without it the init script is registered and never run
        browser.send("Page.addScriptToEvaluateOnNewDocument", {
            "source": f"Object.defineProperty(navigator, 'maxTouchPoints', {{get: () => {touch_points}}});"})
    browser.open(url)


def wait_loaded(browser, app=True):
    """The main page is ready (app.js has run); the terminal page only has to have loaded."""
    if app:
        browser.wait_ready()
        return
    end = time.time() + 60
    while browser.evaluate("document.readyState") != "complete":
        assert time.time() < end, "the page did not load"
        time.sleep(0.1)


@pytest.mark.parametrize("ua, platform", [(IPHONE, "iPhone"), (IPAD, "iPad"), (IOS_CHROME, "iPhone")])
def test_an_iphone_or_ipad_gets_maximum_scale_1_on_the_main_page(served, browser, ua, platform):
    open_as(browser, served["url"] + "/", ua, platform)
    wait_loaded(browser)
    assert browser.evaluate(VIEWPORT) == BASE + ", maximum-scale=1"


@pytest.mark.parametrize("ua, platform", [(DESKTOP, "Linux x86_64"), (ANDROID, "Linux armv8l"), (MAC_SAFARI, "MacIntel")])
def test_everything_else_keeps_the_tag_as_it_was(served, browser, ua, platform):
    # a Mac (MacIntel, no touch screen) is a Mac, not an iPad: maxTouchPoints is 0 here
    open_as(browser, served["url"] + "/", ua, platform)
    wait_loaded(browser)
    assert browser.evaluate(VIEWPORT) == BASE
    assert browser.evaluate("navigator.maxTouchPoints") == 0


def test_an_ipad_in_desktop_mode_is_told_by_its_touch_screen(served, browser):
    # iPadOS in its default "request desktop website" mode: a Mac user agent, MacIntel, and five touch points
    open_as(browser, served["url"] + "/", MAC_SAFARI, "MacIntel", touch_points=5)
    wait_loaded(browser)
    assert browser.evaluate("navigator.platform + ' ' + navigator.maxTouchPoints") == "MacIntel 5"
    assert browser.evaluate(VIEWPORT) == BASE + ", maximum-scale=1"


def test_android_with_touch_points_is_still_untouched(served, browser):
    # a touch screen alone is not the sign: only a MacIntel platform with touch points is an iPad
    open_as(browser, served["url"] + "/", ANDROID, "Linux armv8l", touch_points=5)
    wait_loaded(browser)
    assert browser.evaluate(VIEWPORT) == BASE


def test_the_tag_in_both_files_stays_plain_and_the_script_follows_it():
    from sala_web.app import STATIC
    for name in ("index.html", "terminal.html"):
        head = (STATIC / name).read_text().split("</head>")[0]
        tag = re.search(r'<meta name="viewport"[^>]*>', head)
        assert tag and "maximum-scale" not in tag.group(0), f"{name}: the tag stays as it is, the script adds the scale for iOS"
        script = head[tag.end():].split("</script>")[0]
        assert 'vp.content += ", maximum-scale=1"' in script, f"{name}: the script follows the tag"
        assert "!/maximum-scale/.test(vp.content)" in script, f"{name}: a tag that has it already is left alone"


def test_the_terminal_page_follows_the_same_rule(served, browser):
    open_as(browser, served["url"] + "/terminal?arg=x", IPHONE, "iPhone")
    wait_loaded(browser, app=False)
    assert browser.evaluate(VIEWPORT) == TERMINAL_BASE + ", maximum-scale=1"


def test_the_terminal_page_on_desktop_is_untouched(served, browser):
    open_as(browser, served["url"] + "/terminal?arg=x", DESKTOP, "Linux x86_64")
    wait_loaded(browser, app=False)
    assert browser.evaluate(VIEWPORT) == TERMINAL_BASE
