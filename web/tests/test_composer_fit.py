"""The composer stays on the screen: the shell (#app) is as tall as what is visible (the visual viewport, --app-h set by
app.js, 100dvh as the stylesheet's own value), the composer pads the bottom safe-area inset, and the timing log can
show the viewports (README "The screen's height").

Why (seen on Android Chrome): right after a keyboard image paste and the
keyboard's close, the composer's lower half (the paperclip, the send button, the model line) sat under the screen's
bottom edge, about 50 CSS px lower than two minutes later with nothing changed: the page had been laid out for a
layout viewport taller than the visible part of the screen. Chrome on Android brings the layout viewport (100dvh,
innerHeight) up to date only once its own bars finish showing or hiding, and a page that cannot scroll gives it no
scroll to do it on; the visual viewport is what it draws, so the shell follows that.

What a headless Chromium can and cannot show: Emulation.setDeviceMetricsOverride resizes both viewports at once, which
is what the keyboard does under interactive-widget=resizes-content (and what a bar's show or hide does once the layout
viewport has caught up); a visual viewport shorter than the layout viewport at scale 1 (the state the phone was in)
cannot be produced through the protocol (the viewport clip of setDeviceMetricsOverride and setVisibleSize change
neither viewport in this build), so that state is staged by shadowing visualViewport.height on the page and
dispatching its resize event: what the page does with the value is tested, not that Chrome reports it. The same goes
for iOS WebKit's keyboard (it ignores interactive-widget=resizes-content, leaves the layout viewport at full height and
scrolls the page up, so visualViewport.offsetTop > 0): offsetTop, height and scale are shadowed the same way and --app-top,
#app, the sidebar and the shell drawer are checked against them, in the narrow layout and in the wide one (an iPhone in
landscape: the toggle and header block, the edge strip and the sidebar are position: fixed from the layout viewport's top);
WebKit itself is not run here, so the real iPhone is the manual check. A real gesture
bar, Chrome's real safe-area insets and its real transitions are a phone's to show (the manual check in the README).

The soft keyboard also covers the home bar, but iOS keeps reporting the bottom inset, so html.kbd-up (set while an editable
element has the focus and the visual viewport is over 100 px shorter than the layout viewport, at scale 1) takes the inset off
the composer, the New session form and the shell drawer. Chromium's setSafeAreaInsetsOverride gives the nonzero inset; the
iOS keyboard is the staged offset, height and scale above; the Android lag (about 50 px) and a zoom must leave it off.
"""

from __future__ import annotations

import re

import pytest
from conftest import CDP, CHAT_READY, NAME, chromium_binary
from sala_web import timingdebug as TD
from sala_web.app import STATIC
from test_composer_attach import WAIT_CHIPS
from test_timing_debug import log_records, wait_log

APP_JS = (STATIC / "app.js").read_text()
CSS = (STATIC / "style.css").read_text()
RECORDER_JS = (STATIC / "timing-debug.js").read_text()

FIT = """(() => {
  const box = (s) => { const n = document.querySelector(s); if (!n || n.hidden) return null; const b = n.getBoundingClientRect();
    return { top: Math.round(b.top * 10) / 10, bottom: Math.round(b.bottom * 10) / 10, left: Math.round(b.left * 10) / 10, right: Math.round(b.right * 10) / 10 }; };
  const probe = document.createElement("div"); probe.style.cssText = "position:fixed;top:0;left:0;width:0;height:100dvh;visibility:hidden";
  document.body.append(probe); const dvh = probe.offsetHeight; probe.remove();
  return { vvH: visualViewport.height, vvTop: visualViewport.offsetTop, scale: visualViewport.scale, inner: innerHeight, dvh,
           appH: document.querySelector("#app").getBoundingClientRect().height, appVar: document.documentElement.style.getPropertyValue("--app-h"),
           composer: box("#composer"), row: box(".compose-row"), model: box("#model-line"), attach: box("#attach"), send: box("#send"),
           input: box("#input"), chips: document.querySelector("#chips").childElementCount ? box("#chips") : null,
           chatH: document.querySelector("#chat-pane").getBoundingClientRect().height, topH: document.querySelector("#top").getBoundingClientRect().height,
           pad: parseFloat(getComputedStyle(document.querySelector("#composer")).paddingBottom), modelText: document.querySelector("#model-line").textContent }; })()"""
WAIT_APP = """new Promise((res) => { const t0 = Date.now(); (function poll() {
  const h = document.querySelector("#app").getBoundingClientRect().height;
  if (Math.abs(h - %s) < 0.6 || Date.now() - t0 > 5000) res(h); else setTimeout(poll, 30); })(); })"""
WAIT_VAR = """new Promise((res) => { const t0 = Date.now(); (function poll() {
  const v = document.documentElement.style.getPropertyValue("--app-h");
  if (v === %s || Date.now() - t0 > 5000) res(v); else setTimeout(poll, 30); })(); })"""
WAIT_MODEL = """new Promise((res) => { const t0 = Date.now(); (function poll() {
  if (!document.querySelector("#model-line").hidden || Date.now() - t0 > 10000) res(!document.querySelector("#model-line").hidden); else setTimeout(poll, 50); })(); })"""
PASTE = """(() => { const dt = new DataTransfer();
  dt.items.add(new File([new Uint8Array(16)], "pasted.png", { type: "image/png" }));
  document.querySelector("#input").dispatchEvent(new ClipboardEvent("paste", { clipboardData: dt, bubbles: true, cancelable: true })); return 1; })()"""
STAGE_LAG = """(() => { Object.defineProperty(visualViewport, "height", { get: () => %d, configurable: true });
  visualViewport.dispatchEvent(new Event("resize")); return innerHeight; })()"""
UNSTAGE_LAG = """(() => { delete visualViewport.height; visualViewport.dispatchEvent(new Event("resize")); return visualViewport.height; })()"""
# iOS WebKit with the keyboard up: the layout viewport stays full height and the page is scrolled up, so the visual viewport
# is `top` px below the layout viewport's top; a resize and a scroll event, as WebKit sends both (scale as given)
STAGE_IOS = """(() => { const v = {offsetTop: %s, height: %s, scale: %s};
  for (const k in v) Object.defineProperty(visualViewport, k, { get: () => v[k], configurable: true });
  visualViewport.dispatchEvent(new Event("resize")); visualViewport.dispatchEvent(new Event("scroll")); return innerHeight; })()"""
UNSTAGE_IOS = """(() => { for (const k of ["offsetTop", "height", "scale"]) delete visualViewport[k];
  visualViewport.dispatchEvent(new Event("resize")); visualViewport.dispatchEvent(new Event("scroll")); return visualViewport.height; })()"""
IOS_BOXES = """(() => { const r = (s) => { const n = document.querySelector(s); const b = n.getBoundingClientRect(); return { top: b.top, bottom: b.bottom }; };
  const root = document.documentElement.style;
  return { appTop: root.getPropertyValue("--app-top"), appH: root.getPropertyValue("--app-h"), app: r("#app"), bar: r("#top"), composer: r("#composer"),
           send: r("#send"), model: r("#model-line"), sidebar: r("#sidebar"), vvTop: visualViewport.offsetTop }; })()"""
WAIT_TOP = """new Promise((res) => { const t0 = Date.now(); (function poll() {
  const v = document.documentElement.style.getPropertyValue("--app-top");
  if (v === %s || Date.now() - t0 > 5000) res(v); else setTimeout(poll, 30); })(); })"""


def metrics(browser, height: int, width: int = 390, mobile: bool = True) -> None:
    browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": height, "deviceScaleFactor": 1, "mobile": mobile})


def assert_fits(f: dict, visible: float, inset: float, *, chips: bool = False) -> None:
    """The shell ends at the visible bottom, the composer with it, and every control of the composer (the row with its
    paperclip, input and send button; the chips; the model line) ends above the inset (the gesture bar's room)."""
    assert abs(f["appH"] - visible) < 0.6, (f["appH"], visible)
    assert f["composer"] and visible - 0.6 <= f["composer"]["bottom"] <= visible + 0.6, (f["composer"], visible)
    assert f["composer"]["top"] >= 0 and f["composer"]["top"] < f["composer"]["bottom"], f["composer"]
    assert f["pad"] == 10 + inset, (f["pad"], inset)
    for k in ("row", "attach", "send", "input", "model") + (("chips",) if chips else ()):
        b = f[k]
        assert b, (k, f)
        assert b["bottom"] <= visible - inset + 0.6 and b["top"] >= 0 and b["left"] >= 0 and b["right"] <= 390.6, (k, b, visible, inset)
    assert f["model"]["bottom"] <= visible - inset + 0.6 and f["modelText"] == "Opus 5.5", f["model"]
    assert f["chatH"] > 40 and f["topH"] > 0, (f["chatH"], f["topH"])  # the chat keeps room; the header is on the screen


def test_the_stylesheet_and_the_script_size_the_shell_from_the_visible_area():
    assert re.search(r"#app\s*\{[^}]*height:\s*var\(--app-h,\s*100dvh\)", CSS)
    assert re.search(r"#sidebar\s*\{[^}]*inset:\s*var\(--app-top,\s*0px\) auto auto 0;\s*height:\s*var\(--app-h,\s*100dvh\)", CSS)  # the narrow one
    # iOS: the visual viewport's offset below the layout viewport's top moves the shell, the narrow sidebar and the drawer's bottom
    assert re.search(r"#app\s*\{[^}]*height:\s*var\(--app-h,\s*100dvh\);\s*position:\s*relative;\s*top:\s*var\(--app-top,\s*0px\)", CSS)
    assert re.search(r"\.shell-drawer\s*\{[^}]*bottom:\s*calc\(100dvh - var\(--app-h,\s*100dvh\) - var\(--app-top,\s*0px\)\)", CSS)
    # iOS, wide layout: the fixed pieces are placed from the layout viewport's top, so --fixed-top adds the offset to --inset-top (the
    # safe area and the banner), the edge strip and the closed sidebar start at the offset, and the sidebar's padding-top keeps
    # --inset-top only (docked, it sits in #app, which the offset has moved already: counting it again would double it)
    wide = CSS[CSS.index("@media (min-width: 761px) {\n  :root { --top-h"):].split("@media (max-width")[0]
    assert re.search(r"--inset-top:\s*calc\(env\(safe-area-inset-top\) \+ var\(--banner-h\)\);\s*--fixed-top:\s*calc\(var\(--app-top,\s*0px\) \+ var\(--inset-top\)\)", wide)
    assert re.search(r"#side-edge\s*\{[^}]*top:\s*var\(--app-top,\s*0px\);\s*height:\s*var\(--app-h,\s*100dvh\)", wide)
    assert re.search(r"#sidebar\s*\{[^}]*inset:\s*var\(--app-top,\s*0px\) auto auto -280px;\s*height:\s*var\(--app-h,\s*100dvh\);\s*padding-top:\s*calc\(var\(--inset-top\) \+ var\(--top-h\)\)", wide)
    assert "#side-open { position: fixed; z-index: 32; left: 8px; top: calc(var(--fixed-top) +" in wide and ".side-head { position: fixed; z-index: 31; left: 0; top: var(--fixed-top);" in wide
    assert "var(--fixed-top)" not in re.search(r"#sidebar\s*\{[^}]*\}", wide).group(0)  # the sidebar's own padding never counts the offset
    assert re.search(r"#composer\s*\{[^}]*padding:[^;]*calc\(10px \+ env\(safe-area-inset-bottom\)\)", CSS)
    # the soft keyboard up (html.kbd-up): the bottom inset is dropped; the originals above stay for the keyboard down
    assert re.search(r"\.kbd-up #composer\s*\{\s*padding-bottom:\s*10px;\s*\}", CSS)
    narrow = CSS[CSS.index("@media (max-width: 760px) {   /* a phone: the same column"):].split("@media (max-width: 520px)")[0]
    assert re.search(r"\.ns-form\s*\{[^}]*calc\(24px \+ env\(safe-area-inset-bottom\)\)", narrow)
    assert re.search(r"\.kbd-up \.ns-form\s*\{\s*padding-bottom:\s*24px;\s*\}", narrow)
    drawer = CSS[CSS.index("/* a bottom sheet at the visible bottom of the screen"):]
    assert re.search(r"\.shell-drawer\s*\{[^}]*padding-bottom:\s*env\(safe-area-inset-bottom\)", drawer)
    assert re.search(r"\.kbd-up \.shell-drawer\s*\{\s*padding-bottom:\s*0;\s*\}", drawer)
    assert "viewport-fit=cover" in (STATIC / "index.html").read_text() and "interactive-widget=resizes-content" in (STATIC / "index.html").read_text()
    block = APP_JS[APP_JS.index("/* ---------- the shell's height"):APP_JS.index("/* ---------- copy ----------")]
    assert 'root.style.setProperty("--app-h", h + "px")' in block and 'root.style.removeProperty("--app-h")' in block
    assert 'root.style.setProperty("--app-top", top + "px")' in block and "vv.offsetTop" in block
    assert block.count('root.style.removeProperty("--app-top")') == 2  # unset at an offset of 0, and while zoomed
    assert "vv.scale > 1.01" in block and "requestAnimationFrame(fitShell)" in block and "setTimeout(fitShell, 350)" in block
    for ev in ('window.visualViewport.addEventListener("resize", fitShellSoon)', 'window.visualViewport.addEventListener("scroll", fitShellSoon)',
               'window.addEventListener("resize", fitShellSoon)', 'window.addEventListener("pageshow", fitShellSoon)', '"visibilitychange"'):
        assert ev in block, ev
    # the shell's own height is the visual viewport's, never the layout viewport's: innerHeight is read once, for the keyboard
    assert block.count("innerHeight") == 1 and "window.innerHeight - vv.height > KBD_MIN" in block and "const KBD_MIN = 100;" in block
    assert 'root.classList.toggle("kbd-up", editableFocused() && ' in block and block.count('root.classList.remove("kbd-up")') == 1  # the zoomed branch
    assert "document.activeElement" in block and "textarea" in block and "contenteditable" in block
    for ev in ('document.addEventListener("focusin", fitShellSoon)', 'document.addEventListener("focusout", fitShellSoon)'):
        assert ev in block, ev
    # the recorder's viewport records (opt-in with the rest of it): the fields the phone check reads, and no text
    assert 'rec("viewport", null, d)' in RECORDER_JS and "viewportWatch();" in RECORDER_JS
    for k in ("vvH", "vvTop", "scale", "inner", "clientH", "dvh", "app", "appVar", "compTop", "compBottom", "rowBottom", "modelBottom", "pad", "focus"):
        assert f"{k}:" in RECORDER_JS, k
    assert "client:" not in RECORDER_JS[RECORDER_JS.index("function viewportWatch"):]  # the record's own column (the client id) would take it
    for why in ('"start"', '"vv-resize"', '"vv-scroll"', '"resize"', '"focus"', '"blur"', '"settled"'):
        assert why in RECORDER_JS, why


def test_the_composer_stays_on_the_screen_through_keyboard_paste_bars_and_a_stale_layout_viewport(served, browser):
    browser.open(f"{served['url']}/#s={NAME}")
    browser.wait_ready(CHAT_READY)
    assert browser.evaluate(WAIT_MODEL)
    f = browser.evaluate(FIT)
    assert f["vvH"] == 844 and f["inner"] == 844 and f["dvh"] == 844 and f["appVar"] == "844px" and f["scale"] == 1 and f["vvTop"] == 0, f
    assert_fits(f, 844, 0)
    # a 34 px gesture bar (the inset Chrome reports with viewport-fit=cover): the row and the model line end above it
    try:
        browser.send("Emulation.setSafeAreaInsetsOverride", {"insets": {"top": 0, "bottom": 34, "left": 0, "right": 0}})
    except RuntimeError as e:
        pytest.skip(f"this Chromium cannot emulate safe-area insets: {e}")
    f = browser.evaluate(FIT)
    assert_fits(f, 844, 34)
    assert f["row"]["bottom"] <= 810 and f["model"]["bottom"] <= 810, f
    # the keyboard opens (resizes-content: both viewports shrink): the composer sits above it, the chat keeps room
    browser.evaluate("document.querySelector('#input').focus(); 1")
    metrics(browser, 500)
    assert abs(browser.evaluate(WAIT_APP % 500) - 500) < 0.6
    f = browser.evaluate(FIT)
    assert f["vvH"] == 500 and f["inner"] == 500 and f["appVar"] == "500px", f
    assert_fits(f, 500, 34)
    # a keyboard paste adds a chip row: the composer grows upward, everything of it still on the screen
    browser.evaluate(PASTE)
    got = browser.evaluate(WAIT_CHIPS % 1)
    assert got["chips"] == 1 and got["uploading"] == 0, got
    f = browser.evaluate(FIT)
    assert_fits(f, 500, 34, chips=True)
    assert f["chips"]["bottom"] <= f["row"]["top"], f
    # the keyboard closes: the shell grows back to the screen, the composer with its chip row and model line whole
    browser.evaluate("document.querySelector('#input').blur(); 1")
    metrics(browser, 844)
    assert abs(browser.evaluate(WAIT_APP % 844) - 844) < 0.6
    f = browser.evaluate(FIT)
    assert f["vvH"] == 844 and f["appVar"] == "844px", f
    assert_fits(f, 844, 34, chips=True)
    # the address bar shows (a 56 px shorter viewport) and hides again
    metrics(browser, 788)
    assert abs(browser.evaluate(WAIT_APP % 788) - 788) < 0.6
    assert_fits(browser.evaluate(FIT), 788, 34, chips=True)
    metrics(browser, 844)
    assert abs(browser.evaluate(WAIT_APP % 844) - 844) < 0.6
    assert_fits(browser.evaluate(FIT), 844, 34, chips=True)
    # the phone's state: the layout viewport (innerHeight, 100dvh) still 844 while 788 are visible; the shell follows
    # the visible part, so the composer's bottom is at 788, not 844 (staged, see the module docstring)
    assert browser.evaluate(STAGE_LAG % 788) == 844
    assert abs(browser.evaluate(WAIT_APP % 788) - 788) < 0.6
    f = browser.evaluate(FIT)
    assert f["inner"] == 844 and f["dvh"] == 844 and f["vvH"] == 788 and f["appVar"] == "788px", f
    assert_fits(f, 788, 34, chips=True)
    assert browser.evaluate(UNSTAGE_LAG) == 844
    assert abs(browser.evaluate(WAIT_APP % 844) - 844) < 0.6
    assert_fits(browser.evaluate(FIT), 844, 34, chips=True)
    # a pinch-zoom halves the visual viewport in CSS px without hiding anything: the variable is dropped, 100dvh holds
    browser.send("Emulation.setPageScaleFactor", {"pageScaleFactor": 2})
    assert browser.evaluate(WAIT_VAR % '""') == ""  # the visual viewport's resize, a frame later
    f = browser.evaluate(FIT)
    assert f["scale"] == 2 and f["vvH"] == 422 and f["appH"] == 844 and f["dvh"] == 844, f
    browser.send("Emulation.setPageScaleFactor", {"pageScaleFactor": 1})
    assert browser.evaluate(WAIT_VAR % '"844px"') == "844px"
    f = browser.evaluate(FIT)
    assert f["scale"] == 1 and f["appVar"] == "844px", f
    assert_fits(f, 844, 34, chips=True)
    # the sidebar at a phone's width spans the visible part too (its toggle at the bottom), not the layout viewport
    browser.evaluate(STAGE_LAG % 788)
    assert abs(browser.evaluate(WAIT_APP % 788) - 788) < 0.6
    side = browser.evaluate("(() => { document.body.classList.add('side-open'); const b = document.querySelector('#sidebar').getBoundingClientRect(); "
                            "const t = document.querySelector('#sidebar .toggle').getBoundingClientRect(); return { top: b.top, bottom: b.bottom, toggle: t.bottom, "
                            "pos: getComputedStyle(document.querySelector('#sidebar')).position }; })()")
    assert side["pos"] == "fixed" and side["top"] == 0 and abs(side["bottom"] - 788) < 0.6 and side["toggle"] <= 788 - 34, side
    browser.evaluate(UNSTAGE_LAG)


def test_the_shell_follows_the_visual_viewports_offset_on_ios(served, browser):
    """iOS WebKit with the keyboard up (staged, see the module docstring): the visual viewport is `top` px below the layout
    viewport's top, `h` px tall. #app covers exactly it: the title bar starts at `top`, the composer ends at top + h."""
    browser.open(f"{served['url']}/#s={NAME}")
    browser.wait_ready(CHAT_READY)
    assert browser.evaluate(WAIT_MODEL)
    base = browser.evaluate(IOS_BOXES)
    assert base["appTop"] == "" and base["app"] == {"top": 0, "bottom": 844} and base["bar"]["top"] == 0, base  # nothing moves at 0
    # the keyboard up: the layout viewport stays 844 tall, the page is scrolled up by 336 px, 508 px are visible (336 + 508 = 844)
    assert browser.evaluate(STAGE_IOS % (336, 508, 1)) == 844
    assert browser.evaluate(WAIT_TOP % '"336px"') == "336px"
    assert abs(browser.evaluate(WAIT_APP % 508) - 508) < 0.6
    f = browser.evaluate(IOS_BOXES)
    assert f["appTop"] == "336px" and f["appH"] == "508px" and f["vvTop"] == 336, f
    assert f["app"] == {"top": 336, "bottom": 844}, f
    assert f["bar"]["top"] == 336, f                                       # the title bar is the first thing on the screen
    assert abs(f["composer"]["bottom"] - 844) < 0.6 and f["composer"]["top"] > f["bar"]["top"], f   # and no band under the composer
    assert f["model"]["bottom"] <= 844 and f["send"]["bottom"] <= 844 and f["send"]["top"] >= 336, f
    # another offset, not adding up to the layout viewport's height (a bar still showing): the bottom is top + height wherever it lands
    browser.evaluate(STAGE_IOS % (60, 500, 1))
    assert browser.evaluate(WAIT_TOP % '"60px"') == "60px"
    assert abs(browser.evaluate(WAIT_APP % 500) - 500) < 0.6
    f = browser.evaluate(IOS_BOXES)
    assert f["app"] == {"top": 60, "bottom": 560} and f["bar"]["top"] == 60 and abs(f["composer"]["bottom"] - 560) < 0.6, f
    # the narrow sidebar, opened, starts at the offset and ends at the visible bottom
    browser.evaluate("document.body.classList.add('side-open'); 1")
    f = browser.evaluate(IOS_BOXES)
    assert f["sidebar"] == {"top": 60, "bottom": 560}, f
    browser.evaluate("document.body.classList.remove('side-open'); 1")
    # the shell drawer (a bottom sheet) ends at the visible bottom, 60 % of the visible height tall
    d = browser.evaluate("(() => { const d = document.querySelector('#shell-drawer'); d.hidden = false; document.body.classList.add('shell-open');"
                         "const b = d.getBoundingClientRect(); return { top: b.top, bottom: b.bottom, h: b.height, pos: getComputedStyle(d).position }; })()")
    assert d["pos"] == "fixed" and abs(d["bottom"] - 560) < 0.6 and abs(d["h"] - 300) < 0.6, d
    browser.evaluate("document.querySelector('#shell-drawer').hidden = true; document.body.classList.remove('shell-open'); 1")
    # the offset back to 0 (the keyboard closes): the variable is unset and nothing is moved, the height as it was
    browser.evaluate(STAGE_IOS % (0, 844, 1))
    assert browser.evaluate(WAIT_TOP % '""') == ""
    assert abs(browser.evaluate(WAIT_APP % 844) - 844) < 0.6
    f = browser.evaluate(IOS_BOXES)
    assert f["appTop"] == "" and f["appH"] == "844px" and f["app"] == {"top": 0, "bottom": 844} and f["bar"]["top"] == 0, f
    # a pinch-zoom (scale above 1) drops both variables whatever the offset: 100dvh holds, #app at the page top
    browser.evaluate(STAGE_IOS % (100, 422, 2))
    assert browser.evaluate(WAIT_VAR % '""') == ""
    f = browser.evaluate(IOS_BOXES)
    assert f["appTop"] == "" and f["appH"] == "" and f["app"] == {"top": 0, "bottom": 844}, f
    # the zoom back to 1 with the offset still there: both are set again
    browser.evaluate(STAGE_IOS % (100, 744, 1))
    assert browser.evaluate(WAIT_TOP % '"100px"') == "100px"
    f = browser.evaluate(IOS_BOXES)
    assert f["appH"] == "744px" and f["app"] == {"top": 100, "bottom": 844}, f
    browser.evaluate(UNSTAGE_IOS)
    assert browser.evaluate(WAIT_TOP % '""') == ""
    assert abs(browser.evaluate(WAIT_APP % 844) - 844) < 0.6


WAIT_KBD = """new Promise((res) => { const t0 = Date.now(); (function poll() {
  const on = document.documentElement.classList.contains("kbd-up");
  if (on === %s || Date.now() - t0 > 3000) res(on); else setTimeout(poll, 30); })(); })"""
SETTLE = "new Promise((res) => setTimeout(() => res(document.documentElement.classList.contains('kbd-up')), 500))"   # past the 350 ms late pass
KBD_PADS = """(() => { const pad = (s) => parseFloat(getComputedStyle(document.querySelector(s)).paddingBottom);
  const d = document.querySelector("#shell-drawer"), was = d.hidden; d.hidden = false;
  const out = { on: document.documentElement.classList.contains("kbd-up"), composer: pad("#composer"), ns: pad("#ns-form"), drawer: pad("#shell-drawer"),
                focus: document.activeElement ? document.activeElement.id : null }; d.hidden = was; return out; })()"""
KBD_DOWN = {"on": False, "composer": 44, "ns": 58, "drawer": 34}   # no keyboard: the 34 px inset counts everywhere
KBD_UP = {"on": True, "composer": 10, "ns": 24, "drawer": 0}       # the soft keyboard up: it does not


def test_the_keyboard_drops_the_bottom_inset_on_ios(served, browser):
    """An iPhone with the soft keyboard up keeps reporting the 34 px home-bar inset while the keyboard covers the bar: with an
    editable element focused and the visual viewport 336 px shorter than the layout viewport (staged), html.kbd-up takes the
    inset off the composer (10), the New session form (24) and the shell drawer (0); with the keyboard down, with nothing
    editable focused (a hardware keyboard), on Android's ~50 px lag and under a zoom, nothing changes (44, 58, 34)."""
    browser.open(f"{served['url']}/#s={NAME}")
    browser.wait_ready(CHAT_READY)
    assert browser.evaluate(WAIT_MODEL)
    try:
        browser.send("Emulation.setSafeAreaInsetsOverride", {"insets": {"top": 0, "bottom": 34, "left": 0, "right": 0}})
    except RuntimeError as e:
        pytest.skip(f"this Chromium cannot emulate safe-area insets: {e}")
    f = browser.evaluate(KBD_PADS)
    assert {k: f[k] for k in KBD_DOWN} == KBD_DOWN, f
    # the keyboard up (iOS, staged): the composer has the focus and 508 of 844 px are visible
    browser.evaluate("document.querySelector('#input').focus(); 1")
    assert browser.evaluate(STAGE_IOS % (336, 508, 1)) == 844
    assert browser.evaluate(WAIT_KBD % "true") is True
    f = browser.evaluate(KBD_PADS)
    assert {k: f[k] for k in KBD_UP} == KBD_UP and f["focus"] == "input", f
    assert abs(browser.evaluate(WAIT_APP % 508) - 508) < 0.6
    c = browser.evaluate(FIT)
    assert abs(c["composer"]["bottom"] - 844) < 0.6 and c["pad"] == 10, c
    assert c["composer"]["bottom"] - c["model"]["bottom"] < 10.6, c   # the composer's last line sits on the keyboard with its 10 px, no inset band
    # the same stage with nothing focused (a hardware keyboard: no soft keyboard covers anything): the inset stays
    browser.evaluate("document.activeElement.blur(); 1")
    assert browser.evaluate(WAIT_KBD % "false") is False
    f = browser.evaluate(KBD_PADS)
    assert {k: f[k] for k in KBD_DOWN} == KBD_DOWN and f["focus"] == "", f
    # a focused element that opens no keyboard (a button) does not count either
    browser.evaluate("document.querySelector('#send').focus(); 1")
    assert browser.evaluate(SETTLE) is False
    # a focused frame (the terminal in the shell drawer or the Terminal tab) counts: its typing comes from the soft keyboard
    browser.evaluate("""(() => { const f = document.createElement("iframe"); f.id = "kbd-probe-frame"; f.src = "about:blank";
      document.body.append(f); f.focus(); return document.activeElement === f; })()""")
    assert browser.evaluate(WAIT_KBD % "true") is True
    browser.evaluate("document.querySelector('#kbd-probe-frame').remove(); 1")
    assert browser.evaluate(WAIT_KBD % "false") is False
    # an editable again: on; the keyboard down (offset and height unstaged): off, the inset back
    browser.evaluate("document.querySelector('#input').focus(); 1")
    assert browser.evaluate(WAIT_KBD % "true") is True
    browser.evaluate(UNSTAGE_IOS)
    assert browser.evaluate(WAIT_KBD % "false") is False
    assert abs(browser.evaluate(WAIT_APP % 844) - 844) < 0.6
    f = browser.evaluate(KBD_PADS)
    assert {k: f[k] for k in KBD_DOWN} == KBD_DOWN and f["focus"] == "input", f
    # Android Chrome: the visual viewport lags the layout viewport by about 50 px (a bar still showing), the input focused: off
    assert browser.evaluate(STAGE_LAG % 788) == 844
    assert abs(browser.evaluate(WAIT_APP % 788) - 788) < 0.6
    assert browser.evaluate(SETTLE) is False
    f = browser.evaluate(KBD_PADS)
    assert {k: f[k] for k in KBD_DOWN} == KBD_DOWN and f["focus"] == "input", f
    # the threshold: 100 px shorter is not a keyboard, 101 is
    assert browser.evaluate(STAGE_LAG % 744) == 844
    assert abs(browser.evaluate(WAIT_APP % 744) - 744) < 0.6
    assert browser.evaluate(SETTLE) is False
    assert browser.evaluate(STAGE_LAG % 743) == 844
    assert abs(browser.evaluate(WAIT_APP % 743) - 743) < 0.6
    assert browser.evaluate(SETTLE) is True
    browser.evaluate(UNSTAGE_LAG)
    assert browser.evaluate(WAIT_KBD % "false") is False
    assert abs(browser.evaluate(WAIT_APP % 844) - 844) < 0.6
    # a pinch-zoom while the keyboard is up: off (the variables are dropped with it), the inset back
    browser.evaluate(STAGE_IOS % (336, 508, 1))
    assert browser.evaluate(WAIT_KBD % "true") is True
    browser.evaluate(STAGE_IOS % (100, 422, 2))
    assert browser.evaluate(WAIT_KBD % "false") is False
    assert browser.evaluate(WAIT_VAR % '""') == ""
    f = browser.evaluate(KBD_PADS)
    assert {k: f[k] for k in KBD_DOWN} == KBD_DOWN, f
    # the zoom back to 1 with the keyboard still up: on again; then the keyboard closes
    browser.evaluate(STAGE_IOS % (336, 508, 1))
    assert browser.evaluate(WAIT_KBD % "true") is True
    browser.evaluate(UNSTAGE_IOS)
    assert browser.evaluate(WAIT_KBD % "false") is False
    browser.evaluate("document.activeElement.blur(); 1")


WIDE_BOXES = """(() => { const r = (s) => { const n = document.querySelector(s); const b = n.getBoundingClientRect(); return { top: b.top, bottom: b.bottom, left: b.left }; };
  const root = document.documentElement.style, sb = document.querySelector("#sidebar");
  return { appTop: root.getPropertyValue("--app-top"), app: r("#app"), bar: r("#top"), head: r("#sidebar .side-head"), toggle: r("#side-open"),
           edge: r("#side-edge"), sidebar: r("#sidebar"), search: r("#side-search"), pos: getComputedStyle(sb).position,
           edgeDisplay: getComputedStyle(document.querySelector("#side-edge")).display, banner: document.querySelector("#update-banner").offsetHeight,
           bannerVar: root.getPropertyValue("--banner-h") }; })()"""
WAIT_PEEK = """new Promise((res) => { const t0 = Date.now(); (function poll() { const l = document.querySelector("#sidebar").getBoundingClientRect().left;
  if (l === 0 || Date.now() - t0 > 5000) res(l); else setTimeout(poll, 30); })(); })"""   # the slide (left .18s) has run
WAIT_BANNER = """new Promise((res) => { const t0 = Date.now(); (function poll() { const v = document.documentElement.style.getPropertyValue("--banner-h");
  if ((v && v !== "0px") || Date.now() - t0 > 5000) res(v); else setTimeout(poll, 30); })(); })"""


def test_the_wide_layouts_fixed_pieces_follow_the_visual_viewports_offset_on_ios(served, browser):
    """An iPhone in landscape (844 x 390, wider than 760 px, so the wide layout) with the keyboard up (staged, see the module
    docstring): the toggle and header block, the edge strip and the sidebar are position: fixed from the layout viewport's top,
    so each must be moved by the offset. At offset N: the block's top is N + its top at 0, the strip and the sidebar span N to
    N + h with the sidebar's first row where it was below its top, and docked (body.side-pin) the sidebar is in the flow, so
    #top starts at N and the block still lines up with it (the offset counted once, not twice). At 0 nothing moves."""
    metrics(browser, 390, width=844)   # not browser.open: it would put the 390 x 844 viewport back
    browser.send("Page.navigate", {"url": f"{served['url']}/#s={NAME}"})
    browser.wait_ready(CHAT_READY)
    assert browser.evaluate(WAIT_MODEL)
    base = browser.evaluate(WIDE_BOXES)
    assert base["pos"] == "fixed" and base["edgeDisplay"] != "none", base                              # the wide layout, closed
    assert base["appTop"] == "" and base["app"]["top"] == 0 and base["head"]["top"] == 0 and base["toggle"]["top"] == (54 - 32) / 2, base
    assert base["edge"] == {"top": 0, "bottom": 390, "left": 0} and base["sidebar"]["top"] == 0 and base["sidebar"]["bottom"] == 390, base
    first = base["search"]["top"] - base["sidebar"]["top"]
    assert first >= 54, base                                                                            # the row under the header block
    # the keyboard up, landscape: the layout viewport stays 390 tall, the page is scrolled up by 150, 240 are visible
    assert browser.evaluate(STAGE_IOS % (150, 240, 1)) == 390
    assert browser.evaluate(WAIT_TOP % '"150px"') == "150px"
    assert abs(browser.evaluate(WAIT_APP % 240) - 240) < 0.6
    f = browser.evaluate(WIDE_BOXES)
    assert f["app"]["top"] == 150 and f["bar"]["top"] == 150, f
    assert f["head"]["top"] == 150 + base["head"]["top"] and f["head"]["top"] == f["bar"]["top"], f      # the block sits on the title bar
    assert f["toggle"]["top"] == 150 + base["toggle"]["top"], f
    assert f["edge"] == {"top": 150, "bottom": 390, "left": 0}, f                                       # the strip covers the visible part
    # peeking: the sidebar slides in over the page, from the screen's top to its bottom, its first row where it was
    browser.evaluate("document.body.classList.add('side-peek'); 1")
    assert browser.evaluate(WAIT_PEEK) == 0
    p = browser.evaluate(WIDE_BOXES)
    assert p["pos"] == "fixed" and p["sidebar"]["left"] == 0 and p["sidebar"]["top"] == 150 and abs(p["sidebar"]["bottom"] - 390) < 0.6, p
    assert abs(p["search"]["top"] - p["sidebar"]["top"] - first) < 0.6, (p, first)
    assert p["head"]["top"] == 150 + base["head"]["top"] and p["head"]["top"] == p["bar"]["top"], p
    # another offset that does not add up to the layout viewport's height (a bar still showing): top N, bottom N + h wherever it lands
    browser.evaluate(STAGE_IOS % (40, 300, 1))
    assert browser.evaluate(WAIT_TOP % '"40px"') == "40px"
    assert abs(browser.evaluate(WAIT_APP % 300) - 300) < 0.6
    p = browser.evaluate(WIDE_BOXES)
    assert p["sidebar"]["top"] == 40 and abs(p["sidebar"]["bottom"] - 340) < 0.6 and p["head"]["top"] == 40 + base["head"]["top"], p
    assert abs(p["search"]["top"] - 40 - first) < 0.6, (p, first)
    browser.evaluate(STAGE_IOS % (150, 240, 1))
    assert browser.evaluate(WAIT_TOP % '"150px"') == "150px"
    assert abs(browser.evaluate(WAIT_APP % 240) - 240) < 0.6
    browser.evaluate("document.body.classList.remove('side-peek'); 1")
    # an update banner (it pushes the title bar down by its height): the block follows it, on top of the offset
    browser.evaluate("document.querySelector('#update-banner').hidden = false; 1")
    b = browser.evaluate(WAIT_BANNER)
    assert b and b != "0px", b
    f = browser.evaluate(WIDE_BOXES)
    assert f["banner"] > 0 and f["bar"]["top"] == 150 + f["banner"] and f["head"]["top"] == f["bar"]["top"], f
    # docked: the sidebar is in the flow of #app (which the offset has moved), the block still lines up with the title bar
    browser.evaluate("document.body.classList.add('side-pin'); 1")
    d = browser.evaluate(WIDE_BOXES)
    assert d["pos"] == "static" and d["edgeDisplay"] == "none", d
    assert d["app"]["top"] == 150 and d["sidebar"]["top"] == 150 and abs(d["sidebar"]["bottom"] - 390) < 0.6, d
    assert d["bar"]["top"] == 150 + d["banner"] and d["head"]["top"] == d["bar"]["top"], d              # 150, not 300
    assert d["toggle"]["top"] == d["bar"]["top"] + (54 - 32) / 2, d
    assert abs(d["search"]["top"] - d["sidebar"]["top"] - first - d["banner"]) < 0.6, (d, first)        # padding-top: the banner once, not the offset
    browser.evaluate("document.querySelector('#update-banner').hidden = true; document.body.classList.remove('side-pin'); 1")
    # the offset back to 0 (the keyboard closes): the variable is unset and every piece is where it was
    browser.evaluate(STAGE_IOS % (0, 390, 1))
    assert browser.evaluate(WAIT_TOP % '""') == ""
    assert abs(browser.evaluate(WAIT_APP % 390) - 390) < 0.6
    z = browser.evaluate(WIDE_BOXES)
    for k in ("app", "bar", "head", "toggle", "edge", "sidebar"):
        assert z[k] == base[k], (k, z[k], base[k])
    assert z["appTop"] == "" and abs(z["search"]["top"] - base["search"]["top"]) < 0.6, z
    browser.evaluate(UNSTAGE_IOS)
    assert browser.evaluate(WAIT_TOP % '""') == ""


def test_the_desktop_layout_is_unchanged(served):
    binary = chromium_binary()
    if not binary:
        pytest.skip("no headless Chromium")
    try:
        c = CDP(binary, 1280, 800)
    except RuntimeError as e:
        pytest.skip(f"{binary} did not start headless here: {e}")
    try:
        metrics(c, 800, width=1280, mobile=False)
        c.send("Page.navigate", {"url": f"{served['url']}/#s={NAME}"})
        c.wait_ready(CHAT_READY)
        assert c.evaluate(WAIT_MODEL)
        f = c.evaluate(FIT)
        assert f["vvH"] == 800 and f["inner"] == 800 and f["dvh"] == 800 and f["appH"] == 800 and f["appVar"] == "800px", f
        assert f["composer"]["bottom"] == 800 and f["composer"]["left"] == 0 and f["composer"]["right"] == 1280, f  # the sidebar is over the page, not beside it
        assert f["row"]["bottom"] <= 790 and f["model"]["bottom"] <= 790 and f["pad"] == 10, f
        side = c.evaluate("(() => { const s = document.querySelector('#sidebar'), b = s.getBoundingClientRect(); "
                          "return { pos: getComputedStyle(s).position, w: b.width, top: b.top, bottom: b.bottom, display: getComputedStyle(s).display }; })()")
        assert side == {"pos": "fixed", "w": 280, "top": 0, "bottom": 800, "display": "flex"}, side   # over the page, closed
        # a window resize follows, as it did
        metrics(c, 600, width=1280, mobile=False)
        assert abs(c.evaluate(WAIT_APP % 600) - 600) < 0.6
        f = c.evaluate(FIT)
        assert f["appVar"] == "600px" and f["composer"]["bottom"] == 600 and f["row"]["bottom"] <= 590 and f["chatH"] > 100, f
    finally:
        c.close()


def test_the_timing_log_records_the_viewports(served, browser):
    browser.open(f"{served['url']}/?debug=timing#s={NAME}")
    browser.wait_ready(CHAT_READY)
    assert browser.evaluate(WAIT_MODEL)
    recs = wait_log(served, lambda rs: any(x["name"] == "viewport" and x["why"] == "start" for x in rs))
    start = next(x for x in recs if x["name"] == "viewport" and x["why"] == "start")
    assert start["vvH"] == 844 and start["vvTop"] == 0 and start["scale"] == 1 and start["inner"] == 844 and start["clientH"] == 844, start
    assert len(start["client"]) == 6 and len(start["load"]) == 6, start  # the record's own columns, untouched by the detail
    assert start["dvh"] == 844 and start["app"] == 844 and start["appVar"] == "844px" and start["compBottom"] == 844, start
    assert 0 < start["compTop"] < start["rowBottom"] < 844 and start["pad"] == "10px" and start["focus"] is False, start
    # a record is taken on an event, not on a render: the focus (a keyboard about to open) carries the model line's
    # bottom, in by then (WAIT_MODEL above), and the focus itself
    browser.evaluate("document.querySelector('#input').focus(); 1")
    recs = wait_log(served, lambda rs: any(x["name"] == "viewport" and x["why"] == "focus" for x in rs))
    foc = next(x for x in recs if x["name"] == "viewport" and x["why"] == "focus")
    assert foc["focus"] is True and foc["modelBottom"] and foc["rowBottom"] < foc["modelBottom"] <= 844 - 10, foc
    # the keyboard (both viewports to 500): a record on the resize with the shell and the composer following
    metrics(browser, 500)
    recs = wait_log(served, lambda rs: any(x["name"] == "viewport" and x["vvH"] == 500 and x["why"] == "settled" for x in rs))
    first = next(x for x in recs if x["name"] == "viewport" and x["vvH"] == 500)
    assert first["why"] in ("vv-resize", "resize") and first["inner"] == 500 and first["app"] == 500 and first["appVar"] == "500px", first
    assert first["compBottom"] == 500 and first["rowBottom"] <= 490 and first["focus"] is True, first
    # back to the whole screen; nothing of the composer's text or the transcript in the log
    browser.evaluate("setText('secret draft'); 1")
    metrics(browser, 844)
    recs = wait_log(served, lambda rs: sum(1 for x in rs if x["name"] == "viewport" and x["vvH"] == 844 and x["why"] in ("vv-resize", "resize")) >= 1)
    back = [x for x in recs if x["name"] == "viewport" and x["vvH"] == 844 and x["why"] in ("vv-resize", "resize")][-1]
    assert back["app"] == 844 and back["compBottom"] == 844 and back["dvh"] == 844, back
    raw = (served["settings"].state_dir / TD.LOG_NAME).read_text()
    assert "secret draft" not in raw and "please look at" not in raw
    vps = [x for x in log_records(served) if x["name"] == "viewport"]
    assert all(set(x) >= {"why", "vvH", "vvTop", "scale", "inner", "clientH", "dvh", "app", "appVar", "compTop", "compBottom", "rowBottom", "modelBottom", "pad", "focus"} for x in vps)
    assert len(vps) == len({(x["seq"]) for x in vps}) and len(vps) < 60, len(vps)  # one a frame, only on a change
