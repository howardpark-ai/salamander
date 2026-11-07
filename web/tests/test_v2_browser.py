"""/v2/ in a headless Chromium at 390, 768, 1024 and 1440 px: every page the stubs can reach, drawn by the v2 layer.

The layer rewrites v1's stylesheets, page and script at request time; nothing in the text tests (test_v2_design.py, test_v2_layer.py)
proves that the result still draws a page that fits and loads. For each width and each page this opens /v2/ and checks: the
document is no wider than the window (no sideways scroll), on a wide screen the content column is at most 920 px, nothing is
logged as an error (console, uncaught exceptions, failed requests), the D2Coding face loads from the address the page names, the page
has no manifest and no service worker registration (so the installed app is untouched), and the tab says v2.

What a wrong answer costs: a v2 page that scrolls sideways on a phone, a column wider than the others, a font that 404s, a script
error on a screen v1 draws without one, or a second installed app. NOT covered (docs/test-coverage.md): coarse-pointer sizes
(44 px controls: a headless page cannot emulate `pointer: coarse` through this driver), a real phone's browser, and live data
(long names, many agents, a real board).

Pages: the Overview's Agents, Schedules and Machines tabs, a chat, Search results, the New session page and the Quick session page.
Stubs: api/schedules (as test_search_ui.py) and the project list of the New session page (stackshot is not run); the page's two CDN stylesheets are blocked, so the run needs no network. The Quick session and lane pages are left out: they call sala's CLI, which tests do not run.
"""

from __future__ import annotations

import json
import time
from datetime import datetime, timezone

import pytest

from conftest import CWD, NAME, SID, transcript_file

WIDTHS = [390, 768, 1024, 1440]
STUB = """(() => {
  const real = window.fetch.bind(window);
  const json = (o) => Promise.resolve(new Response(JSON.stringify(o), { headers: { "Content-Type": "application/json" } }));
  window.fetch = (url, opts) => {
    const u = String(url);
    if (u.startsWith("api/schedules")) return json({ generated: null, timezone: "", timers: [], cron: [],
      counts: { timers: 0, cron: 0, flagged: 0, byReason: {}, packaged: 0 }, scopes: { user: true, system: true } });
    if (u.startsWith("api/spawn/projects")) return json({ ok: true, scopes: ["example", "beta", "gamma"], projects: [
      { key: "projects/gamma-kiln", name: "gamma-kiln", title: "The kiln room", description: "A made-up description of a sample project", scope: "gamma", agents: {} },
      { key: "projects/gamma-garden", name: "gamma-garden", title: "Garden", description: "Sample planting notes", scope: "gamma", agents: {} }] });
    return real(url, opts);
  };
})();"""
ROW = "f0000000-0000-4000-8000-00000000000a"


def now_iso(ago_s: float = 60) -> str:
    return datetime.fromtimestamp(time.time() - ago_s, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def prepare(served) -> None:
    """A registry row for the fake session and a fresh reply, so that Search finds something and the Agents table has a row."""
    st = served["settings"].sala_state_dir
    st.mkdir(parents=True, exist_ok=True)
    (st / "sessions.json").write_text(json.dumps({"schema": 1, "sessions": {ROW: {
        "id": ROW, "name": NAME, "role": "front", "state": "live", "transcripts": [{"id": SID, "why": "add"}]}}}))
    line = {"type": "assistant", "uuid": "a-v2", "timestamp": now_iso(), "message": {"role": "assistant", "content": [{"type": "text", "text": "the zebra answer, in v2"}]}}
    with open(transcript_file(served), "a", encoding="utf-8") as f:
        f.write(json.dumps(line) + "\n")


def settle(browser, expr: str, what: str, ms: int = 15000):
    v = browser.evaluate("""new Promise((res) => { const t0 = Date.now(); (function poll() {
      let v; try { v = (%s); } catch (e) { v = null; }
      if (v || Date.now() - t0 > %d) res(v ? true : null); else setTimeout(poll, 100); })(); })""" % (expr, ms))
    assert v, what
    return v


# (name, hash, a condition that says the page is drawn, the selector of its content column or None)
PAGES = [
    ("agents", "#sessions", "document.querySelectorAll('#sp-table tbody tr').length > 0 && getComputedStyle(document.querySelector('#overview-pane')).display !== 'none'", "#overview-pane .sp"),
    ("schedules", "#schedules", "document.querySelector('#overview-pane').dataset.tab === 'schedules' && document.querySelector('#sc-reload')", "#overview-pane .sp"),
    ("machines", "#machines", "document.querySelector('#overview-pane').dataset.tab === 'machines' && document.querySelector('#mc-reload')", "#overview-pane .sp"),
    ("chat", f"#s={NAME}", "document.querySelectorAll('#chat .msg').length > 0", "#chat"),
    ("search", "#search?q=zebra&hours=24", "document.querySelectorAll('#se-hits .se-hit').length > 0", "#search-pane .se-page"),
    ("new", "#new", "getComputedStyle(document.querySelector('#new-pane')).display !== 'none' && document.querySelector('#ns-form')", "#new-pane .np-col"),
]


def errors_of(browser) -> list[str]:
    """What the page reported since the last call: console errors, uncaught exceptions, requests that failed or answered 4xx/5xx."""
    browser.evaluate("1")   # reads whatever DevTools sent meanwhile
    out = []
    for e in browser.events:
        m, p = e.get("method"), e.get("params", {})
        if m == "Runtime.exceptionThrown":
            out.append("exception: " + str(p["exceptionDetails"].get("exception", {}).get("description") or p["exceptionDetails"].get("text"))[:200])
        elif m == "Runtime.consoleAPICalled" and p.get("type") == "error":
            out.append("console.error: " + " ".join(str(a.get("value", a.get("description", ""))) for a in p.get("args", []))[:200])
        elif m == "Log.entryAdded" and p["entry"].get("level") == "error" and "cdn.jsdelivr.net" not in p["entry"].get("url", "") + p["entry"].get("text", ""):
            out.append("log: " + p["entry"].get("text", "")[:120] + " " + p["entry"].get("url", "")[:120])
    browser.events.clear()
    return out


@pytest.mark.parametrize("width", WIDTHS)
def test_each_page_fits_the_window_draws_its_column_loads_the_code_face_and_logs_no_error(served, browser, width):
    prepare(served)
    browser.send("Page.enable")
    browser.send("Runtime.enable")
    browser.send("Log.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": STUB})
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": "window.open = () => null;"})
    # the page links two external stylesheets (the text face, the old code face's CDN): blocked, so the run needs no network and the
    # entries it logs for them are told apart below
    browser.send("Network.enable")
    browser.send("Network.setBlockedURLs", {"urls": ["https://cdn.jsdelivr.net/*"]})
    browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 844, "deviceScaleFactor": 1, "mobile": width <= 760})
    seen = []
    for name, hash_, ready, col in PAGES:
        browser.send("Page.navigate", {"url": "about:blank"})
        browser.send("Page.navigate", {"url": f"{served['url']}/v2/{hash_}"})
        settle(browser, "typeof state !== 'undefined' && state.byName.has(%s)" % json.dumps(NAME), f"{name}: the app did not start at {width}px")
        settle(browser, ready, f"{name}: the page was not drawn at {width}px")
        facts = browser.evaluate("""(async () => {
          await document.fonts.load('13px D2Coding', 'a');
          const col = document.querySelector(%s);
          const faces = [...document.fonts].filter((f) => f.family.replace(/"/g, '') === 'D2Coding');
          return {
            title: document.title, scroll: document.documentElement.scrollWidth, inner: innerWidth,
            col: col ? Math.round(col.getBoundingClientRect().width) : null,
            faces: faces.map((f) => f.status),
            manifest: !!document.querySelector('link[rel=manifest]'),
            workers: (await navigator.serviceWorker.getRegistrations()).length,
            path: location.pathname,
          };
        })()""" % json.dumps(col))
        seen.append((name, facts))
        assert facts["path"] == "/v2/", (name, facts)
        assert facts["title"].startswith("v2 · "), (name, facts)
        assert facts["scroll"] <= facts["inner"], f"{name} at {width}px scrolls sideways: {facts}"
        if width >= 1024:
            assert facts["col"] is not None and facts["col"] <= 920, f"{name} at {width}px: the column is {facts['col']}px"
        assert facts["faces"] == ["loaded"], f"{name}: the D2Coding face did not load: {facts}"
        assert not facts["manifest"] and facts["workers"] == 0, (name, facts)
        errs = errors_of(browser)
        assert not errs, f"{name} at {width}px logged errors: {errs}"
    assert len(seen) == len(PAGES)
