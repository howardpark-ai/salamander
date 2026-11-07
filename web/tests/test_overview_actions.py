"""The sessions overview's head carries Reload and Get Help (the Overview had no Reload, and Get Help was
loose text rather than a chip). The overview hides the header's view options (and with them its Reload), so the overview has its
own, wired to the same reloadPage; Get Help is a chip with an icon that opens help-session.

The page parts run in a headless Chromium when one is installed (conftest.py: `served`, `browser`), else skipped.
"""

from __future__ import annotations

import re
import time

from sala_web.app import STATIC

INDEX = (STATIC / "index.html").read_text()


def test_the_overview_head_has_reload_and_get_help():
    head = INDEX[INDEX.index('<div class="sp-head">'):INDEX.index('<section id="quota"')]
    assert '<button id="sp-reload" class="sp-btn" type="button" aria-label="Reload the page"' in head
    # the file holds the chip with the session placeholder, inside markers the server drops when SALA_HELP_SESSION is unset
    assert re.search(r'<!--help--><a id="sp-help" class="sp-btn sp-help" href="#s=\{\{help\}\}" title="[^"]*\{\{help\}\}[^"]*"><svg ', head)
    assert head.index("<!--help-->") < head.index('id="sp-help"') < head.index("<!--/help-->")
    assert ">Get Help</a>" in head and head.index('id="sp-reload"') < head.index('id="sp-help"')
    assert "Ask demo-web" not in INDEX and "sp-ask" not in INDEX
    # every id in the page once: the overview's Reload is not a second #menu-reload or #reload-btn
    ids = re.findall(r'\sid="([^"]+)"', INDEX)
    assert len(ids) == len(set(ids)), sorted(i for i in ids if ids.count(i) > 1)
    js = (STATIC / "app.js").read_text()
    assert '$("#sp-reload").addEventListener("click", () => reloadPage("overview"));' in js  # the cause: test_timing_debug.py


WAIT_OVERVIEW = """
new Promise((res) => { const t0 = Date.now(); (function poll() {
  const b = document.querySelector("#sp-reload"), ok = !window.__old && !!document.body
    && document.body.classList.contains("overview-open") && !!b && b.getBoundingClientRect().width > 0;
  if (ok || Date.now() - t0 > 15000) res(!!ok); else setTimeout(poll, 100);
})(); })
"""
MEASURE = """(() => {
  const vw = document.documentElement.clientWidth, head = document.querySelector("#overview-pane .sp-head"), pane = document.querySelector("#overview-pane");
  const box = (s) => { const e = document.querySelector(s), r = e.getBoundingClientRect(), cs = getComputedStyle(e);
    return { left: r.left, right: r.right, top: r.top, w: r.width, h: r.height, text: e.textContent.trim(), inHead: head.contains(e),
             border: parseFloat(cs.borderTopWidth), radius: parseFloat(cs.borderTopLeftRadius), svg: !!e.querySelector("svg"),
             href: e.getAttribute("href"), title: e.getAttribute("title") }; };
  const ids = [...document.querySelectorAll("[id]")].map((e) => e.id);
  return { vw, docScroll: document.documentElement.scrollWidth, paneScroll: pane.scrollWidth, paneClient: pane.clientWidth,
           reload: box("#sp-reload"), help: box("#sp-help"), dupIds: ids.filter((id, i) => ids.indexOf(id) !== i) };
})()"""


def wait_overview(browser) -> bool:
    """True once the overview shows its head. After a click that reloads, an evaluate may land on the page that is
    going ("Inspected target navigated or closed"): ask again."""
    for _ in range(100):
        try:
            return browser.evaluate(WAIT_OVERVIEW)
        except RuntimeError as e:
            if "navigated or closed" not in str(e):
                raise
            time.sleep(0.1)
    return False


def check_chips(m: dict, vw: int) -> None:
    assert m["vw"] == vw and not m["dupIds"], m
    # nothing wider than the viewport, the page nor the overview
    assert m["docScroll"] <= vw and m["paneScroll"] <= m["paneClient"], m
    for k in ("reload", "help"):
        c = m[k]
        assert c["inHead"] and c["svg"] and c["border"] >= 1 and c["radius"] >= 12, (k, c)
        assert 0 <= c["left"] and c["right"] <= vw, (k, c)
    assert m["reload"]["text"] == "Reload" and m["help"]["text"] == "Get Help", m
    assert m["help"]["href"] == "#s=help-session" and "help-session" in m["help"]["title"], m
    # Reload first, Get Help after it, on one row
    assert m["reload"]["right"] <= m["help"]["left"] and abs(m["reload"]["top"] - m["help"]["top"]) < 1, m


def test_overview_reload_and_get_help_in_the_browser(served, browser):
    browser.open(f"{served['url']}/#sessions")
    assert wait_overview(browser)
    phone = browser.evaluate(MEASURE)
    check_chips(phone, 390)
    assert phone["reload"]["h"] >= 40 and phone["help"]["h"] >= 40, phone  # touch-sized on a phone
    # Reload: a reload navigation that comes back to the overview
    browser.evaluate("window.__old = true; document.querySelector('#sp-reload').click(); ''")
    assert wait_overview(browser)
    nav = browser.evaluate("performance.getEntriesByType('navigation')[0].type + ' ' + location.hash")
    assert nav == "reload #sessions", nav
    # Get Help opens help-session in place of the overview
    browser.evaluate("document.querySelector('#sp-help').click(); ''")
    got = browser.evaluate("""new Promise((res) => setTimeout(() => res({ hash: location.hash,
      open: document.body.classList.contains("overview-open") }), 300))""")
    assert got == {"hash": "#s=help-session", "open": False}, got
    # a wide screen: the same two chips at the head's right end
    browser.send("Emulation.setDeviceMetricsOverride", {"width": 1280, "height": 800, "deviceScaleFactor": 1, "mobile": False})
    browser.evaluate("location.hash = '#sessions'; ''")
    assert wait_overview(browser)
    wide = browser.evaluate(MEASURE)
    check_chips(wide, 1280)
    assert wide["reload"]["h"] == 32 and wide["help"]["h"] == 32, wide
