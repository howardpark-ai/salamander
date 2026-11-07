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
dispatching its resize event: what the page does with the value is tested, not that Chrome reports it. A real gesture
bar, Chrome's real safe-area insets and its real transitions are a phone's to show (the manual check in the README).
"""

from __future__ import annotations

import re

import pytest
from conftest import CDP, NAME, chromium_binary
from sala_web import timingdebug as TD
from sala_web.app import STATIC
from test_composer_attach import WAIT_CHIPS, WAIT_READY
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
    assert re.search(r"#sidebar\s*\{[^}]*inset:\s*0 auto auto 0;\s*height:\s*var\(--app-h,\s*100dvh\)", CSS)  # the narrow one
    assert re.search(r"#composer\s*\{[^}]*padding:[^;]*calc\(10px \+ env\(safe-area-inset-bottom\)\)", CSS)
    assert "viewport-fit=cover" in (STATIC / "index.html").read_text() and "interactive-widget=resizes-content" in (STATIC / "index.html").read_text()
    block = APP_JS[APP_JS.index("/* ---------- the shell's height"):APP_JS.index("/* ---------- copy ----------")]
    assert 'root.style.setProperty("--app-h", h + "px")' in block and 'root.style.removeProperty("--app-h")' in block
    assert "vv.scale > 1.01" in block and "requestAnimationFrame(fitShell)" in block and "setTimeout(fitShell, 350)" in block
    for ev in ('window.visualViewport.addEventListener("resize", fitShellSoon)', 'window.visualViewport.addEventListener("scroll", fitShellSoon)',
               'window.addEventListener("resize", fitShellSoon)', 'window.addEventListener("pageshow", fitShellSoon)', '"visibilitychange"'):
        assert ev in block, ev
    assert "innerHeight" not in block  # the visual viewport, never the layout viewport's height
    # the recorder's viewport records (opt-in with the rest of it): the fields the phone check reads, and no text
    assert 'rec("viewport", null, d)' in RECORDER_JS and "viewportWatch();" in RECORDER_JS
    for k in ("vvH", "vvTop", "scale", "inner", "clientH", "dvh", "app", "appVar", "compTop", "compBottom", "rowBottom", "modelBottom", "pad", "focus"):
        assert f"{k}:" in RECORDER_JS, k
    assert "client:" not in RECORDER_JS[RECORDER_JS.index("function viewportWatch"):]  # the record's own column (the client id) would take it
    for why in ('"start"', '"vv-resize"', '"vv-scroll"', '"resize"', '"focus"', '"blur"', '"settled"'):
        assert why in RECORDER_JS, why


def test_the_composer_stays_on_the_screen_through_keyboard_paste_bars_and_a_stale_layout_viewport(served, browser):
    browser.open(f"{served['url']}/#s={NAME}")
    assert browser.evaluate(WAIT_READY) and browser.evaluate(WAIT_MODEL)
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
        assert c.evaluate(WAIT_READY) and c.evaluate(WAIT_MODEL)
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
    assert browser.evaluate(WAIT_READY) and browser.evaluate(WAIT_MODEL)
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
