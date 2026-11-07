"""The Overview's lane cards drag into an order of the owner's own, and the loose note under them is gone (the line under the cards, "metered and sdk:
billed per use, ...", is not needed).

The order is `laneOrder` in api/prefs (a flat list of lane ids), kept on the server like the sidebar's and the Schedules groups', so
it follows the owner across browsers. What a wrong answer costs is the page he opens every day: a card that jumps back after a reload,
a lane that was added since he dragged drawn first (or lost), an old id that breaks the draw, a drag that also opens a lane's
details page. The prefs checks run on the app alone; the page checks run in a headless Chromium when one is installed (conftest.py:
`browser`), else are skipped, over the real cards of the real app (test_lane_dormant.py's `world`). Nothing here kills a process
by name: the browser and the page servers are closed by their fixtures.
"""

from __future__ import annotations

import json
import time

import pytest
from starlette.testclient import TestClient

from sala_web.app import STATIC
from test_credit import wait_for  # noqa: F401
from test_lane_dormant import FRI, SINCE, open_overview, page, record, world  # noqa: F401  (fixtures)
from test_overview_cards_order import ORDER, READY

DEFAULT = ["subscription-1", "subscription-2", "api", "aws-platform", "bedrock"]


def ids(browser):
    return [x[0] for x in browser.evaluate(ORDER)]


def saved_order(world, want, tries=60):
    """The order in prefs.json once it equals `want` (the page's save is asynchronous)."""
    got = None
    for _ in range(tries):
        try:
            got = json.loads((world["state"] / "prefs.json").read_text()).get("laneOrder")
        except (OSError, ValueError):
            got = None
        if got == want:
            break
        time.sleep(0.1)
    return got


def seed(world, order):
    world["state"].mkdir(parents=True, exist_ok=True)
    (world["state"] / "prefs.json").write_text(json.dumps({"laneOrder": order}))


def open_cards(browser, url, width=1400, tag=""):
    browser.send("Page.enable")
    browser.open(f"{url}/?t={tag}#sessions")
    browser.width, browser.height = width, 900
    browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 900, "deviceScaleFactor": 1, "mobile": False})
    assert wait_for(browser, READY)
    assert wait_for(browser, "document.querySelectorAll('#q-cards .q-grip').length === 5")


def press(browser, name: str, code: int) -> None:
    for t in ("keyDown", "keyUp"):
        browser.send("Input.dispatchKeyEvent", {"type": t, "key": name, "code": name, "windowsVirtualKeyCode": code})


def focus_grip(browser, lane):
    browser.evaluate(f"document.querySelector('#q-cards > .lane-{lane} .q-grip').focus(); ''")


def centre(browser, selector):
    return browser.evaluate(f"""(() => {{ const r = document.querySelector({json.dumps(selector)}).getBoundingClientRect();
      return [r.left + r.width / 2, r.top + r.height / 2]; }})()""")


def drag(browser, frm, to):
    """A mouse drag from one point to another, in steps, the button held."""
    x, y = frm
    browser.send("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": x, "y": y})
    browser.send("Input.dispatchMouseEvent", {"type": "mousePressed", "x": x, "y": y, "button": "left", "buttons": 1, "clickCount": 1})
    for i in range(1, 9):
        browser.send("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": x + (to[0] - x) * i / 8, "y": y + (to[1] - y) * i / 8, "buttons": 1})
    browser.send("Input.dispatchMouseEvent", {"type": "mouseReleased", "x": to[0], "y": to[1], "button": "left", "buttons": 0, "clickCount": 1})


# ---- the prefs key (the app alone) ------------------------------------------------------------------------------------------


@pytest.fixture
def client(tmp_path):
    from sala_web.app import create_app
    from sala_web.config import Settings
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    (claude / "projects").mkdir()
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                        tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"])
    return TestClient(create_app(settings))


def test_the_lane_order_is_a_pref_and_round_trips(client):
    assert client.get("/api/prefs").json()["laneOrder"] == []
    order = ["bedrock", "subscription-1", "api"]
    r = client.put("/api/prefs", json={"laneOrder": order})
    assert r.status_code == 200 and r.json()["laneOrder"] == order
    assert client.put("/api/prefs", json={"showAll": True}).status_code == 200   # another key leaves it alone
    assert client.get("/api/prefs").json()["laneOrder"] == order
    assert client.put("/api/prefs", json={"laneOrder": ["x", "y", "x"]}).json()["laneOrder"] == ["x", "y"]   # repeats dropped
    assert client.put("/api/prefs", json={"laneOrder": "subscription-1"}).status_code == 400
    assert client.put("/api/prefs", json={"laneOrder": [1]}).status_code == 400
    assert client.get("/api/prefs").json()["laneOrder"] == ["x", "y"]   # a refused save changed nothing


# ---- the note is gone -------------------------------------------------------------------------------------------------------


def test_the_standing_note_under_the_cards_is_gone_from_the_source():
    html = (STATIC / "index.html").read_text()
    js = (STATIC / "sessions.js").read_text()
    for text in (html, js):
        assert "billed per use, no quota" not in text
    assert 'id="q-note" class="q-note" role="status"></div>' in html   # the element stays, empty, for the error line only
    assert ".q-note:empty" in (STATIC / "sessions.css").read_text()


def test_the_page_shows_no_note_under_the_cards(world, page, browser):
    record(world["rec"])
    open_cards(browser, page())
    assert browser.evaluate("document.getElementById('q-note').textContent") == ""
    assert browser.evaluate("getComputedStyle(document.getElementById('q-note')).display") == "none"
    assert "billed per use" not in browser.evaluate("document.getElementById('quota').innerText")


# ---- the order in the page --------------------------------------------------------------------------------------------------


def test_with_nothing_saved_the_default_order_and_every_card_has_a_handle(world, page, browser):
    record(world["rec"])
    open_cards(browser, page())
    assert ids(browser) == DEFAULT
    labels = browser.evaluate("[...document.querySelectorAll('#q-cards .q-grip')].map((g) => g.getAttribute('aria-label'))")
    assert labels[0] == "Move the ultra card: drag, or press the arrow keys"
    assert browser.evaluate("document.querySelector('#q-cards .q-grip').tagName") == "BUTTON"


def test_a_saved_order_is_drawn_and_a_new_lane_goes_last_an_unknown_one_is_ignored(world, page, browser):
    record(world["rec"])
    seed(world, ["bedrock", "ghost", "subscription-1"])   # "ghost" has no card; team, api and aws-platform were never placed
    open_cards(browser, page())
    assert ids(browser) == ["bedrock", "subscription-1", "subscription-2", "api", "aws-platform"]


def test_a_saved_order_rules_over_the_state_of_a_lane(world, page, browser):
    # max is dormant: the default puts it below the active lanes, but the owner put it first and it stays there
    record(world["rec"], ("subscription-1", "dormant", "login no longer reports Max", SINCE, "", "signal"),
           ("api", "dormant", "credit used up", FRI, "", "signal"))
    seed(world, ["subscription-1", "api"])
    open_cards(browser, page())
    assert ids(browser) == ["subscription-1", "api", "subscription-2", "aws-platform", "bedrock"]
    states = {x[0]: x[1] for x in browser.evaluate(ORDER)}
    assert states["subscription-1"] == "dormant" and states["api"] == "dormant"


def test_an_empty_saved_order_keeps_the_state_order(world, page, browser):
    record(world["rec"], ("subscription-1", "dormant", "login no longer reports Max", SINCE, "", "signal"))
    open_cards(browser, page())
    assert ids(browser)[-1] == "subscription-1"


def test_a_card_moves_with_the_arrow_keys_and_the_order_is_remembered(world, page, browser):
    record(world["rec"])
    url = page()
    open_cards(browser, url)
    focus_grip(browser, "subscription-1")
    press(browser, "ArrowRight", 39)
    assert ids(browser) == ["subscription-2", "subscription-1", "api", "aws-platform", "bedrock"]
    assert saved_order(world, ["subscription-2", "subscription-1", "api", "aws-platform", "bedrock"]) == ["subscription-2", "subscription-1", "api", "aws-platform", "bedrock"]
    assert browser.evaluate("document.activeElement.closest('.q-card').className.includes('lane-subscription-1')")   # the handle keeps the focus
    press(browser, "ArrowDown", 40)
    assert ids(browser) == ["subscription-2", "api", "subscription-1", "aws-platform", "bedrock"]
    press(browser, "ArrowLeft", 37)
    press(browser, "ArrowUp", 38)
    assert ids(browser) == ["subscription-1", "subscription-2", "api", "aws-platform", "bedrock"]
    # at the start, left does nothing; at the end, right does nothing
    press(browser, "ArrowLeft", 37)
    assert ids(browser)[0] == "subscription-1"
    focus_grip(browser, "bedrock")
    press(browser, "ArrowRight", 39)
    assert ids(browser)[-1] == "bedrock"
    focus_grip(browser, "bedrock")
    press(browser, "ArrowLeft", 37)
    want = ["subscription-1", "subscription-2", "api", "bedrock", "aws-platform"]
    assert ids(browser) == want
    assert saved_order(world, want) == want
    open_cards(browser, url, tag="again")   # a new load of the page draws the order
    assert ids(browser) == want


def test_a_card_drags_by_its_handle_and_the_drag_opens_nothing(world, page, browser):
    record(world["rec"])
    url = page()
    open_cards(browser, url)
    start = centre(browser, "#q-cards > .lane-subscription-1 .q-grip")
    # let go on the "Details ›" link of the third card: the card moves there and the link is not followed
    end = centre(browser, "#q-cards > .lane-api .q-details")
    drag(browser, start, end)
    assert ids(browser) == ["subscription-2", "api", "subscription-1", "aws-platform", "bedrock"]
    want = ["subscription-2", "api", "subscription-1", "aws-platform", "bedrock"]
    assert saved_order(world, want) == want
    assert browser.evaluate("location.hash") == "#sessions"
    assert browser.evaluate("document.querySelectorAll('.q-dragging').length") == 0
    # a drag back to the first place
    drag(browser, centre(browser, "#q-cards > .lane-subscription-1 .q-grip"), centre(browser, "#q-cards > .lane-subscription-2 .q-head"))
    assert ids(browser)[:3] == ["subscription-1", "subscription-2", "api"]
    open_cards(browser, url, tag="again")
    assert ids(browser) == ["subscription-1", "subscription-2", "api", "aws-platform", "bedrock"]


def test_the_cards_own_links_still_work(world, page, browser):
    record(world["rec"])
    open_cards(browser, page())
    x, y = centre(browser, "#q-cards > .lane-subscription-2 .q-details")
    browser.send("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": x, "y": y})
    browser.send("Input.dispatchMouseEvent", {"type": "mousePressed", "x": x, "y": y, "button": "left", "buttons": 1, "clickCount": 1})
    browser.send("Input.dispatchMouseEvent", {"type": "mouseReleased", "x": x, "y": y, "button": "left", "buttons": 0, "clickCount": 1})
    assert wait_for(browser, "location.hash === '#lane=subscription-2'")
    assert ids_on_details(browser) == 0   # and the details page's card has no handle


def ids_on_details(browser):
    assert wait_for(browser, "document.querySelectorAll('#ld-usage .q-card').length === 1")
    return browser.evaluate("document.querySelectorAll('#ld-usage .q-grip').length")


def test_a_pointer_that_is_cancelled_puts_the_card_back(world, page, browser):
    record(world["rec"])
    open_cards(browser, page())
    # a synthetic drag by pointer events, cancelled: nothing is saved, the order is as it was
    browser.evaluate("""(() => { const g = document.querySelector('#q-cards > .lane-subscription-1 .q-grip'), t = document.querySelector('#q-cards > .lane-bedrock').getBoundingClientRect(),
      r = g.getBoundingClientRect(), o = { pointerId: 7, bubbles: true, button: 0, pointerType: 'touch' };
      g.dispatchEvent(new PointerEvent('pointerdown', { ...o, clientX: r.left + 5, clientY: r.top + 5 }));
      window.dispatchEvent(new PointerEvent('pointermove', { ...o, clientX: t.left + 20, clientY: t.top + 40 }));
      window.__moved = [...document.querySelectorAll('#q-cards > .q-card')].map((c) => c.className.match(/lane-([\\w-]+)/)[1]);
      window.dispatchEvent(new PointerEvent('pointercancel', { ...o })); return ''; })()""")
    assert browser.evaluate("window.__moved")[-1] == "subscription-1"   # it followed the pointer
    assert ids(browser) == DEFAULT
    time.sleep(0.5)
    assert not (world["state"] / "prefs.json").exists()


def test_the_page_draws_a_card_that_lands_during_a_drag_after_it(world, page, browser):
    record(world["rec"])
    open_cards(browser, page())
    # the grid is held while a drag is on: a redraw asked for meanwhile waits
    browser.evaluate("""(() => { const g = document.querySelector('#q-cards > .lane-subscription-1 .q-grip'), r = g.getBoundingClientRect();
      g.dispatchEvent(new PointerEvent('pointerdown', { pointerId: 9, bubbles: true, button: 0, clientX: r.left + 5, clientY: r.top + 5 }));
      window.__before = document.querySelector('#q-cards').firstElementChild; document.dispatchEvent(new Event('visibilitychange')); return ''; })()""")
    time.sleep(1.0)
    assert browser.evaluate("document.querySelector('#q-cards').firstElementChild === window.__before")
    browser.evaluate("window.dispatchEvent(new PointerEvent('pointercancel', { pointerId: 9 })); ''")
    assert ids(browser) == DEFAULT
