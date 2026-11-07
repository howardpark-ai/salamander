"""What the ⋯ menu holds since the lighter view (dynamic information such as "working" stays in the bar, the
static facts go into the menu): a Session section on top (Role and Lane as rows, in their badge colours, and the tmux name when it differs from the
session's), a View section under it (Chat / Terminal as a segmented control of two buttons, the open one `aria-pressed`,
then the "Thinking & tool calls" toggle); the bar keeps the name, the status badge, Reload and the button.

Held here: the menu's contents and order (by the markup and by their boxes), the role and lane badges drawn in the same
colours as before (front the accent's orange, background a violet, each lane its own), Chat / Terminal switching from the
menu by pointer and by keyboard with the state shown on the buttons, and Escape. The fold of the status badge and Reload
into the menu is test_header_fold.py's, the bar's layout test_header_layout.py's, Reload's own behaviour test_reload_menu.py's.
Runs in a headless Chromium when one is installed (conftest.py: `served`, `browser`), else skipped.
"""

from __future__ import annotations

import pytest

from sala_web.app import STATIC
from test_composer_attach import WAIT_READY
from test_header_fold import inside, set_width

INDEX = (STATIC / "index.html").read_text()
FRONT = {"name": "demo", "role": "front", "lane": "subscription-1", "status": "idle"}
BACK = {"name": "demo-builder", "role": "background", "lane": "subscription-2", "status": "busy"}

MENU = r"""
(() => {
  const q = (s) => document.querySelector(s);
  const box = (e) => { const r = e.getBoundingClientRect(); return { l: r.left, r: r.right, t: r.top, b: r.bottom, w: r.width, h: r.height }; };
  const menu = q("#top-tools");
  const rows = [...q("#top-session").querySelectorAll(".srow")].map((r) => ({ label: r.querySelector(".k").textContent, pill: r.querySelector(".pill").textContent,
    cls: r.querySelector(".pill").className, box: box(r) }));
  const colours = (e) => { const c = getComputedStyle(e); return { color: c.color, border: c.borderTopColor, bg: c.backgroundColor }; };
  const probe = (decl) => { const p = document.createElement("span"); p.style.cssText = decl; document.body.append(p); const c = getComputedStyle(p).color; p.remove(); return c; };
  return { open: document.body.classList.contains("top-menu-open"), shown: getComputedStyle(menu).display !== "none", box: box(menu),
           heads: [...menu.querySelectorAll(".menu-head")].map((h) => ({ text: h.textContent, box: box(h) })),
           order: [...menu.querySelectorAll(".menu-head, .srow, .tab, #show-tools")].map((e) => e.matches(".menu-head") ? "h:" + e.textContent : e.matches(".srow") ? "r:" + e.querySelector(".k").textContent : e.matches(".tab") ? "t:" + e.dataset.tab : "toggle"),
           rows, tabs: [...menu.querySelectorAll(".tab")].map((t) => ({ tab: t.dataset.tab, text: t.textContent, tag: t.tagName, pressed: t.getAttribute("aria-pressed"), active: t.classList.contains("active"), box: box(t) })),
           toggle: box(q("#show-tools")),
           role: rows.find((r) => r.label === "Role") && colours(q("#top-session .pill[class*=role-]")),
           lane: rows.find((r) => r.label === "Lane") && colours(q("#top-session .pill[class*=lane-]")),
           want: { front: probe("color: var(--role-front-text)"), back: probe("color: var(--role-back-text)"), "subscription-1": probe("color: var(--lane-subscription-1)"), "subscription-2": probe("color: var(--lane-subscription-2)") },
           inBar: !!q("#top-end").querySelector(".pill[class*=role-], .pill[class*=lane-], .tab"),
           pressedNow: document.activeElement && (document.activeElement.dataset.tab || document.activeElement.id || document.activeElement.tagName),
           tab: state.tab };
})()
"""


def open_menu(browser) -> dict:
    browser.evaluate("document.querySelector('#top-menu-btn').click(); ''")
    return browser.evaluate(MENU)


def key(browser, k: str, code: str, vk: int, text: str | None = None) -> None:
    ev = {"key": k, "code": code, "windowsVirtualKeyCode": vk}
    browser.send("Input.dispatchKeyEvent", {"type": "keyDown", **ev, **({"text": text} if text else {})})
    browser.send("Input.dispatchKeyEvent", {"type": "keyUp", **ev})


def test_the_menu_markup_is_session_then_view_then_the_toggle():
    menu = INDEX[INDEX.index('id="top-tools"'):INDEX.index("</header>")]
    assert menu.index('id="menu-session"') < menu.index('id="menu-view"') < menu.index('id="show-tools"')
    assert menu.index(">Session</h3>") < menu.index('id="top-session"') < menu.index(">View</h3>") < menu.index('class="tabs"') < menu.index('id="show-tools"')
    # the switch: two real buttons in a labelled group, each with its pressed state (not a div, not a link)
    tabs = menu[menu.index('class="tabs"'):menu.index("</div>", menu.index('class="tabs"'))]
    assert 'role="group" aria-label="View"' in tabs
    assert '<button type="button" data-tab="chat" class="tab active" aria-pressed="true">Chat</button>' in tabs
    assert '<button type="button" data-tab="terminal" class="tab" aria-pressed="false">Terminal</button>' in tabs
    # and none of it is in the bar
    bar = INDEX[INDEX.index('id="title"'):INDEX.index('id="top-tools"')]
    assert "Chat" not in bar and "Terminal" not in bar and "role-" not in bar and "lane-" not in bar


@pytest.mark.parametrize("served", [FRONT], indirect=True)
def test_the_menu_lists_session_view_and_thinking_in_that_order(served, browser):
    browser.open(f"{served['url']}/#s=demo")
    assert browser.evaluate(WAIT_READY)
    set_width(browser, 1280)
    closed = browser.evaluate(MENU)
    assert not closed["open"] and not closed["shown"] and not closed["inBar"], closed   # role, lane and the tabs are not in the bar
    m = open_menu(browser)
    assert m["open"] and m["shown"], m
    # by the page's order and by the boxes, top to bottom: the heading Session, its rows (Role, Lane, tmux), the heading View,
    # Chat and Terminal side by side, then the toggle
    assert m["order"] == ["h:Session", "r:Role", "r:Lane", "r:tmux", "h:View", "t:chat", "t:terminal", "toggle"], m["order"]
    session, view = m["heads"]
    assert (session["text"], view["text"]) == ("Session", "View")
    assert session["box"]["b"] <= m["rows"][0]["box"]["t"] and m["rows"][-1]["box"]["b"] <= view["box"]["t"] + 0.5, m
    assert [r["box"]["t"] for r in m["rows"]] == sorted(r["box"]["t"] for r in m["rows"])
    chat, term = m["tabs"]
    assert view["box"]["b"] <= chat["box"]["t"] and chat["box"]["r"] <= term["box"]["l"] + 0.5 and abs(chat["box"]["t"] - term["box"]["t"]) < 1, m["tabs"]
    assert max(chat["box"]["b"], term["box"]["b"]) <= m["toggle"]["t"] + 0.5, (m["tabs"], m["toggle"])
    # the rows say what the badges said: front, the lane's label (no "lane:" in front of it), the tmux name
    assert [(r["label"], r["pill"]) for r in m["rows"]] == [("Role", "front"), ("Lane", "subscription-1"), ("tmux", "x")], m["rows"]
    for part in m["rows"] + m["tabs"]:
        assert inside(part["box"], m["box"]), (part, m["box"])
    # the open view is shown on the buttons
    assert [(t["tab"], t["pressed"], t["active"]) for t in m["tabs"]] == [("chat", "true", True), ("terminal", "false", False)], m["tabs"]
    assert all(t["tag"] == "BUTTON" and t["box"]["h"] >= 28 for t in m["tabs"]), m["tabs"]


@pytest.mark.parametrize("served,role,lane", [(FRONT, "front", "subscription-1"), (BACK, "back", "subscription-2")], indirect=["served"], ids=["front-max", "background-team"])
@pytest.mark.parametrize("scheme", ["light", "dark"])
def test_role_and_lane_keep_their_badge_colours_in_the_menu(served, browser, role, lane, scheme):
    """Front is the accent's orange and background a violet (--role-*-text on a tint of the colour); each lane
    has its own (--lane-*): the colour of the words and a border that is not the plain one, in both themes."""
    browser.open(f"{served['url']}/#s={served['name']}")
    assert browser.evaluate(WAIT_READY)
    browser.send("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-color-scheme", "value": scheme}]})
    m = open_menu(browser)
    assert m["role"]["color"] == m["want"][role] and m["lane"]["color"] == m["want"][lane], (m["role"], m["lane"], m["want"])
    # not the plain grey pill: each has a tinted fill and its own border
    plain = browser.evaluate("(() => { const p = document.createElement('span'); p.className = 'pill'; document.querySelector('#top-session').append(p); const c = getComputedStyle(p); const o = { color: c.color, bg: c.backgroundColor, border: c.borderTopColor }; p.remove(); return o; })()")
    for badge in (m["role"], m["lane"]):
        assert badge["bg"] != plain["bg"] and badge["border"] != plain["border"] and badge["color"] != plain["color"], (badge, plain)
    assert m["role"]["bg"] != m["lane"]["bg"] and m["role"]["border"] != m["lane"]["border"], (m["role"], m["lane"])


@pytest.mark.parametrize("served", [FRONT], indirect=True)
def test_chat_and_terminal_switch_from_the_menu_with_the_state_shown(served, browser):
    browser.open(f"{served['url']}/#s=demo")
    assert browser.evaluate(WAIT_READY)
    for w in (1280, 390):
        set_width(browser, w)
        m = open_menu(browser)
        assert m["tab"] == "chat" and [t["pressed"] for t in m["tabs"]] == ["true", "false"], (w, m["tabs"])
        browser.evaluate("document.querySelector('#top .tab[data-tab=terminal]').click(); ''")
        m = browser.evaluate(MENU)
        assert m["tab"] == "terminal" and not m["open"], (w, m)            # the menu closes on a pick, the pane switched
        assert browser.evaluate("document.querySelector('#terminal-pane').classList.contains('active') && !document.querySelector('#chat-pane').classList.contains('active')"), w
        m = open_menu(browser)                                              # reopened: the state is on the buttons
        assert [(t["pressed"], t["active"]) for t in m["tabs"]] == [("false", False), ("true", True)], (w, m["tabs"])
        browser.evaluate("document.querySelector('#top .tab[data-tab=chat]').click(); ''")
        m = browser.evaluate(MENU)
        assert m["tab"] == "chat" and browser.evaluate("document.querySelector('#chat-pane').classList.contains('active')"), (w, m)


@pytest.mark.parametrize("served", [FRONT], indirect=True)
def test_the_menu_is_reachable_and_operable_from_the_keyboard(served, browser):
    """Tab from the ⋯ button goes to Chat, Terminal and the toggle (the menu follows the button in the page); Enter on
    Terminal switches the view; Escape closes the menu."""
    browser.open(f"{served['url']}/#s=demo")
    assert browser.evaluate(WAIT_READY)
    set_width(browser, 1280)
    browser.evaluate("document.querySelector('#top-menu-btn').focus(); ''")
    key(browser, "Enter", "Enter", 13, "\r")
    m = browser.evaluate(MENU)
    assert m["open"], m
    key(browser, "Tab", "Tab", 9)
    assert browser.evaluate(MENU)["pressedNow"] == "chat"
    key(browser, "Tab", "Tab", 9)
    assert browser.evaluate(MENU)["pressedNow"] == "terminal"
    key(browser, "Enter", "Enter", 13, "\r")
    m = browser.evaluate(MENU)
    assert m["tab"] == "terminal" and not m["open"], m
    m = open_menu(browser)
    assert [t["pressed"] for t in m["tabs"]] == ["false", "true"], m["tabs"]
    key(browser, "Escape", "Escape", 27)
    assert not browser.evaluate(MENU)["open"]
