"""The paperclip's hover highlight stays inside the composer row.

`.attach-btn` is a 44px touch target with negative margins inside `.compose-row` (1px border, 14px radius), so painting the
hover on the button itself spilled a 44px square over the row's border and rounded corner on a desktop. The button now
paints nothing; the highlight (and the keyboard focus ring) is a centred 30px square with 8px radius (the send button's
size and radius) drawn by `::before` behind the icon.

Held here, in a headless Chromium at 1280 px with a real DevTools mouse (so :hover is real; the headless engine reports
`hover: none`, see DROP_TOUCH_RULE, but nothing below depends on that default):
- the button is still 44x44 and the row still one 44px line;
- hovered, the highlight (::before) is 30x30, centred on the button, painted var(--hover), and lies wholly inside the row's
  inner border box (the row's rect inset by its border), with the button's own background still none;
- not hovered, nothing is painted; the ring of a keyboard focus is on the same 30px square, not the 44px box;
- in touch mode (`hover: none`) a tap leaves no stuck highlight.

A pseudo-element has no getBoundingClientRect, so its box is read from its computed size, offsets and margins against the
button's rect. What no test here can show is how it looks on a real screen: the manual check is a mouse over the paperclip.
Runs in a headless Chromium when one is installed, else skipped.
"""

from __future__ import annotations

import time

from conftest import NAME
from test_composer_attach import WAIT_READY

BOXES = """(() => {
  const btn = document.querySelector('#attach'), row = document.querySelector('.compose-row');
  const b = btn.getBoundingClientRect(), r = row.getBoundingClientRect();
  const cs = getComputedStyle(btn), ps = getComputedStyle(btn, '::before'), rs = getComputedStyle(row);
  const px = (v) => parseFloat(v) || 0;
  const left = b.left + px(ps.left) + px(ps.marginLeft), top = b.top + px(ps.top) + px(ps.marginTop);
  const bw = px(rs.borderLeftWidth);
  return { btn: { w: b.width, h: b.height, x: b.left, y: b.top }, row: { h: r.height },
           hl: { w: px(ps.width), h: px(ps.height), left, top, right: left + px(ps.width), bottom: top + px(ps.height),
                 radius: ps.borderTopLeftRadius, bg: ps.backgroundColor, outline: ps.outlineStyle + ' ' + ps.outlineWidth,
                 pos: ps.position, content: ps.content },
           inner: { left: r.left + bw, top: r.top + bw, right: r.right - bw, bottom: r.bottom - bw },
           btnBg: cs.backgroundColor, btnOutline: cs.outlineStyle,
           matchesHover: btn.matches(':hover'), focusVisible: btn.matches(':focus-visible') }; })()"""
CENTRE = "(() => { const r = document.querySelector('#attach').getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()"
HOVER_COLOUR = """(() => { const p = document.createElement('div'); p.style.background = 'var(--hover)';
  document.body.append(p); const c = getComputedStyle(p).backgroundColor; p.remove(); return c; })()"""
# A headless Chromium has no pointing device and reports `hover: none`, so the stylesheet's `@media (hover: none)` rule for the
# paperclip applies in it, and DevTools cannot emulate `hover: hover` (Emulation.setEmulatedMedia does not take the feature).
# The desktop test therefore first shows that rule hides the highlight (the touch case), then deletes that one rule from the
# live stylesheet, which is what a hover-capable device's engine leaves out, and reads the highlight a mouse gets.
DROP_TOUCH_RULE = """(() => { let n = 0;
  for (const sheet of document.styleSheets) { let rules; try { rules = sheet.cssRules; } catch (e) { continue; }
    for (let i = rules.length - 1; i >= 0; i--) {
      const r = rules[i];
    if (r.type === CSSRule.MEDIA_RULE && /hover:\\s*none/.test(r.conditionText) && r.cssText.includes('.attach-btn')) { sheet.deleteRule(i); n++; } } }
  return n; })()"""
TRANSPARENT = {"rgba(0, 0, 0, 0)", "transparent"}
HOVERING = "document.querySelector('#attach').matches(':hover')"
HOVER_NONE = "matchMedia('(hover: none)').matches"
# The viewport override reaches the renderer a moment after its DevTools call returns. A mouse move sent before that is
# hit-tested against the old 390px layout and sets no :hover (a full Chrome, as on GitHub's hosted runners, loses it every
# time; a Chromium on an idle box, about one run in four), so the page is waited on until it is 1280px wide and has painted twice.
SETTLED = "new Promise((ok) => requestAnimationFrame(() => requestAnimationFrame(() => ok(innerWidth))))"


def desktop(browser, served) -> None:
    browser.open(f"{served['url']}/#s={NAME}")
    assert browser.evaluate(WAIT_READY)
    browser.send("Emulation.setDeviceMetricsOverride", {"width": 1280, "height": 800, "deviceScaleFactor": 1, "mobile": False})
    deadline = time.monotonic() + 10
    while browser.evaluate(SETTLED) != 1280:
        assert time.monotonic() < deadline, "the 1280px viewport never took effect"
        time.sleep(0.05)
    mouse(browser, 640, 400)  # the chat area, off the paperclip


def hover_over(browser, x: float, y: float) -> None:
    """Move the mouse onto (x, y) and wait until the engine has applied :hover to the paperclip, moving again while it has not."""
    deadline = time.monotonic() + 10
    while True:
        mouse(browser, x, y)
        for _ in range(10):
            if browser.evaluate(HOVERING):
                return
            time.sleep(0.05)
        assert time.monotonic() < deadline, "the paperclip never matched :hover under the mouse"


def mouse(browser, x: float, y: float) -> None:
    browser.send("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": x, "y": y})


def test_the_hover_is_a_30px_square_inside_the_row(served, browser):
    desktop(browser, served)
    idle = browser.evaluate(BOXES)
    # the hit area is as before; the one-line row is the send button (32 px with a mouse) plus the row's 8 px
    # padding twice and its border: the paperclip's negative margins keep its 44 px box inside that line
    assert (idle["btn"]["w"], idle["btn"]["h"]) == (44, 44), idle
    send = browser.evaluate("document.querySelector('.send-btn').getBoundingClientRect().height")
    assert idle["row"]["h"] == send + 18, (send, idle)
    assert not idle["matchesHover"] and idle["hl"]["bg"] in TRANSPARENT, idle  # nothing painted at rest
    c = browser.evaluate(CENTRE)
    hover_over(browser, c["x"], c["y"])
    stuck = browser.evaluate(BOXES)
    assert stuck["matchesHover"], stuck
    # hover: none (a headless Chromium with no pointing device, a phone): the :hover state a tap leaves paints nothing. An engine
    # that reports a hover-capable device has no such state to check, and the touch rule is dropped below all the same.
    if browser.evaluate(HOVER_NONE):
        assert stuck["hl"]["bg"] in TRANSPARENT, stuck
    assert browser.evaluate(DROP_TOUCH_RULE) == 1
    on = browser.evaluate(BOXES)
    assert on["matchesHover"], on
    hl, btn, inner = on["hl"], on["btn"], on["inner"]
    assert on["btnBg"] in TRANSPARENT, on  # the 44px button itself paints nothing
    assert hl["content"] == '""' and hl["pos"] == "absolute", hl
    assert (hl["w"], hl["h"]) == (30, 30) and hl["radius"] == "8px", hl
    assert hl["bg"] == browser.evaluate(HOVER_COLOUR) and hl["bg"] not in TRANSPARENT, hl
    # centred on the button
    assert abs((hl["left"] + hl["right"]) / 2 - (btn["x"] + 22)) < 0.51, (hl, btn)
    assert abs((hl["top"] + hl["bottom"]) / 2 - (btn["y"] + 22)) < 0.51, (hl, btn)
    # entirely inside the row's inner border box (the border and the rounded corner stay clear)
    assert hl["left"] >= inner["left"] and hl["right"] <= inner["right"], (hl, inner)
    assert hl["top"] >= inner["top"] and hl["bottom"] <= inner["bottom"], (hl, inner)
    # the button is still the same 44x44 and the row the same line while hovered
    assert (btn["w"], btn["h"]) == (44, 44) and on["row"]["h"] == idle["row"]["h"], on
    # leaving it clears the highlight
    mouse(browser, 640, 400)
    for _ in range(40):  # the engine drops :hover a moment after the move, as it set it
        if not browser.evaluate(HOVERING):
            break
        time.sleep(0.05)
    off = browser.evaluate(BOXES)
    assert not off["matchesHover"] and off["hl"]["bg"] in TRANSPARENT, off


def test_the_focus_ring_is_on_the_same_30px_square(served, browser):
    desktop(browser, served)
    # a keyboard focus: a key press first makes the next focus match :focus-visible
    browser.send("Input.dispatchKeyEvent", {"type": "keyDown", "key": "Shift", "code": "ShiftLeft", "windowsVirtualKeyCode": 16})
    browser.send("Input.dispatchKeyEvent", {"type": "keyUp", "key": "Shift", "code": "ShiftLeft", "windowsVirtualKeyCode": 16})
    browser.evaluate("document.querySelector('#attach').focus()")
    f = browser.evaluate(BOXES)
    assert f["focusVisible"], f
    assert f["btnOutline"] == "none", f  # not the 44px box
    assert f["hl"]["outline"] == "solid 2px" and (f["hl"]["w"], f["hl"]["h"]) == (30, 30), f
    # the ring (2px outside the square) is inside the row's inner border box too
    hl, inner = f["hl"], f["inner"]
    assert hl["left"] - 2 >= inner["left"] and hl["right"] + 2 <= inner["right"], (hl, inner)
    assert hl["top"] - 2 >= inner["top"] and hl["bottom"] + 2 <= inner["bottom"], (hl, inner)


def test_a_tap_leaves_no_stuck_highlight(served, browser):
    browser.send("Emulation.setTouchEmulationEnabled", {"enabled": True, "maxTouchPoints": 5})
    browser.open(f"{served['url']}/#s={NAME}")
    assert browser.evaluate(WAIT_READY)
    assert browser.evaluate("matchMedia('(hover: none)').matches")
    c = browser.evaluate(CENTRE)
    browser.send("Input.dispatchTouchEvent", {"type": "touchStart", "touchPoints": [{"x": c["x"], "y": c["y"]}]})
    browser.send("Input.dispatchTouchEvent", {"type": "touchEnd", "touchPoints": []})
    s = browser.evaluate(BOXES)
    assert s["hl"]["bg"] in TRANSPARENT, s
