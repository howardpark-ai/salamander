"""Measure a page load of sala in a headless Chromium with a phone's CPU and network: where the milliseconds go
between the navigation and the history on screen (temporary, Wed Oct 14th 2026; README "Timing").

Serves the app on a loopback port with a fleet of fake sessions (tests/bigfixture.py: 44 sessions over the three
scopes, their pids live `sleep`s) and one session whose transcript gives a reset of 200 messages sized to a byte
target (233 KB: the web UI session's history on Wed Oct 14th), then drives playwright's chrome-headless-shell over the
DevTools protocol (tests/conftest.py: CDP) at a phone's width, with `Emulation.setCPUThrottlingRate` (6x: a mid-range
Android phone against this box) and `Network.emulateNetworkConditions` (Chrome's "Slow 4G": 1.6 Mbit/s down, 750 kbit/s
up, 150 ms RTT), and reads the marks app.js leaves (perfMark), the browser's navigation and resource timings, its long
tasks, and a CPU profile (Profiler domain) aggregated by function. Three loads: cold (the first visit, no service
worker yet), a reload with the worker controlling the page, and an unthrottled cold load as the floor.

    uv run --frozen python tools/measure_load.py [--cpu 6] [--rtt 150] [--down 1.6] [--up 0.75] [--messages 200]
                                                 [--bytes 233000] [--sessions 44] [--runs 1] [--top 15]

Nothing here runs in the app; it touches no tmux server (the fake sessions point at no pane) and no real registry.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "tests"))
sys.path.insert(0, str(HERE.parent / "src"))

from conftest import CDP, SID, chromium_binary  # noqa: E402
from bigfixture import fit_scale, fleet  # noqa: E402
from sala_web import sessions as S  # noqa: E402
from sala_web import transcript as TR  # noqa: E402
from sala_web.app import create_app  # noqa: E402
from sala_web.config import Settings  # noqa: E402

MARKS = ["app.js start", "init", "sessions:request", "sessions:response", "sessions:rendered", "sessions:painted", "restore",
         "stream:open", "stream:opened", "stream:first-event", "stream:reset", "history:rendered", "history:painted"]

# installed before every document: long tasks from the first script on (the observer's buffer alone holds a few)
INIT = r"""
window.__longs = [];
try { new PerformanceObserver((l) => { for (const e of l.getEntries()) window.__longs.push([Math.round(e.startTime), Math.round(e.duration)]); })
        .observe({ type: "longtask", buffered: true }); } catch (e) { window.__longs.push(["unsupported", String(e)]); }
"""
COLLECT = r"""
(() => { try {
  const marks = performance.getEntriesByType("mark").map((m) => ({ name: m.name, t: Math.round(m.startTime * 10) / 10, detail: m.detail || null }));
  const nav = performance.getEntriesByType("navigation")[0];
  const n = nav ? { type: nav.type, fetchStart: nav.fetchStart, responseStart: nav.responseStart, responseEnd: nav.responseEnd,
                    dcl: nav.domContentLoadedEventStart, load: nav.loadEventEnd, transfer: nav.transferSize, worker: nav.workerStart, redirects: nav.redirectCount } : null;
  const res = performance.getEntriesByType("resource").map((r) => ({ url: r.name.replace(/^https?:\/\/[^/]+\//, "").replace(/\?v=.*/, ""),
    start: Math.round(r.startTime), dur: Math.round(r.duration), ttfb: Math.round(r.responseStart - r.startTime), size: r.transferSize,
    body: r.encodedBodySize, worker: r.workerStart ? Math.round(r.workerStart - r.startTime) : 0, type: r.initiatorType }));
  return { marks, nav: n, res, longs: window.__longs || [], msgs: document.querySelectorAll("#chat > .msg").length,
           rows: document.querySelectorAll("#session-list .sess").length, controlled: !!(navigator.serviceWorker && navigator.serviceWorker.controller) };
} catch (e) { return { error: String(e && e.stack || e), marks: [], nav: null, res: [], longs: [], msgs: -1, rows: -1, controlled: null }; } })()
"""
WAIT_PAINTED = """
new Promise((res) => { const t0 = Date.now(); (function poll() {
  if (performance.getEntriesByName("history:painted").length || Date.now() - t0 > %d) res(performance.getEntriesByName("history:painted").length > 0);
  else setTimeout(poll, 100);
})(); })
"""


class Served:
    """The app on 127.0.0.1 with a fleet of live fake sessions (one `sleep` each) and the big transcript on `name`."""

    def __init__(self, n_sessions: int, n_messages: int, target_bytes: int):
        self.tmp = Path(tempfile.mkdtemp(prefix="web-timing-measure-"))
        claude = self.tmp / "claude"
        (claude / "sessions").mkdir(parents=True)
        self.procs: list[subprocess.Popen] = []
        self.fleet = fleet(n_sessions)
        cwd = "/home/alex/work"
        for i, s in enumerate(self.fleet):
            p = subprocess.Popen(["sleep", "3600"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.procs.append(p)
            sid = SID if i == 0 else f"aaaaaaaa-0000-4000-8000-{i:012d}"
            (claude / "sessions" / f"{p.pid}.json").write_text(json.dumps(
                {"pid": p.pid, "sessionId": sid, "name": s["name"], "cwd": cwd if i == 0 else f"/home/alex/w{i}",
                 "status": ("busy", "idle", "idle", "waiting")[i % 4], "tmux": f"{s['name']}:@0.%{i}", "procStart": S.proc_start(p.pid)}))
        self.name = self.fleet[0]["name"]
        self.pid = self.procs[0].pid
        proj = claude / "projects" / TR.project_slug(cwd)
        proj.mkdir(parents=True)
        text, self.scale, self.bytes = fit_scale(target_bytes, SID, n_messages)
        (proj / f"{SID}.jsonl").write_text(text)
        roles = {"sessions": {s["name"]: {"role": s["role"], "project": s["project"]} for s in self.fleet}}
        S.live_tmux_names = lambda: {}  # never the default tmux server's names
        self.settings = Settings(socket=self.tmp / "s.sock", state_dir=self.tmp / "state", claude_dir=claude,
                                 tmux_socket_name="salaweb-measure-none", roles_cmd=["echo", json.dumps(roles)],
                                 sala_models=self.tmp / "none.tsv", admin_key=self.tmp / "none-key")
        import uvicorn
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        self.url = f"http://127.0.0.1:{port}"
        self.server = uvicorn.Server(uvicorn.Config(create_app(self.settings), host="127.0.0.1", port=port, log_level="warning"))
        self.thread = threading.Thread(target=self.server.run, daemon=True)
        self.thread.start()
        for _ in range(100):
            if self.server.started:
                break
            time.sleep(0.05)
        assert self.server.started

    def close(self) -> None:
        self.server.should_exit = True
        self.thread.join(timeout=10)
        for p in self.procs:
            p.kill()
        shutil.rmtree(self.tmp, ignore_errors=True)


def aggregate(profile: dict, top: int) -> tuple[list[tuple[str, float]], dict[str, float]]:
    """Self time per function (ms) and per script, from a Profiler.stop profile."""
    nodes = {n["id"]: n for n in profile["nodes"]}
    self_us: dict[int, float] = {}
    for node_id, dt in zip(profile["samples"], profile["timeDeltas"]):
        self_us[node_id] = self_us.get(node_id, 0) + dt
    by_fn: dict[str, float] = {}
    by_url: dict[str, float] = {}
    for node_id, us in self_us.items():
        cf = nodes[node_id]["callFrame"]
        url = cf["url"].rsplit("/", 1)[-1].split("?")[0] or "(native)"
        fn = cf["functionName"] or "(anonymous)"
        key = f"{fn}  [{url}:{cf['lineNumber'] + 1}]" if cf["url"] else fn
        by_fn[key] = by_fn.get(key, 0) + us / 1000
        by_url[url if cf["url"] else fn] = by_url.get(url if cf["url"] else fn, 0) + us / 1000
    return sorted(by_fn.items(), key=lambda kv: -kv[1])[:top], dict(sorted(by_url.items(), key=lambda kv: -kv[1]))


def one_load(c: CDP, url: str, how: str, cpu: float, net: dict | None, timeout_ms: int, top: int) -> dict:
    c.send("Page.enable")
    c.send("Page.addScriptToEvaluateOnNewDocument", {"source": INIT})
    c.send("Network.enable")
    if net:
        c.send("Network.emulateNetworkConditions", {"offline": False, **net})
    else:
        c.send("Network.emulateNetworkConditions", {"offline": False, "latency": 0, "downloadThroughput": -1, "uploadThroughput": -1})
    c.send("Emulation.setCPUThrottlingRate", {"rate": cpu})
    c.send("Profiler.enable")
    c.send("Profiler.setSamplingInterval", {"interval": 250})
    c.send("Profiler.start")
    if how == "reload":
        c.send("Page.reload")
    else:
        c.send("Page.navigate", {"url": url})
    painted = c.evaluate(WAIT_PAINTED % timeout_ms, timeout_ms=timeout_ms + 5000)
    time.sleep(0.5)  # the paint mark's frame, the last resource entries
    got = c.evaluate(COLLECT, timeout_ms=10000)
    prof = c.send("Profiler.stop")["profile"]
    c.send("Profiler.disable")
    c.send("Network.disable")
    got["painted"] = painted
    got["top"], got["by_url"] = aggregate(prof, top)
    return got


def report(label: str, got: dict) -> None:
    if got.get("error"):
        print(f"\n=== {label}: the collection failed: {got['error']}")
    marks = {m["name"]: m for m in got["marks"]}
    print(f"\n=== {label}: painted={got['painted']} nav={got['nav'] and got['nav']['type']} controlled={got['controlled']} "
          f"rows={got['rows']} msgs={got['msgs']}")
    nav = got["nav"] or {}
    print(f"  navigation: responseStart {nav.get('responseStart', 0):.0f}  DCL {nav.get('dcl', 0):.0f}  load {nav.get('load', 0):.0f}  "
          f"transfer {nav.get('transfer')}  workerStart {nav.get('worker', 0):.0f}")
    prev = 0.0
    for name in MARKS:
        m = marks.get(name)
        if not m:
            print(f"  {name:20s}      (no mark)")
            continue
        d = m["detail"] or {}
        extra = " ".join(f"{k}={v}" for k, v in d.items() if k in ("count", "bytes", "ms", "status", "opens", "name"))
        print(f"  {name:20s} {m['t']:9.1f} ms  (+{m['t'] - prev:7.1f})  {extra}")
        prev = m["t"]
    longs = [x for x in got["longs"] if isinstance(x[0], int)]
    print(f"  long tasks: {len(longs)}, total {sum(d for _, d in longs)} ms, longest {max([d for _, d in longs] or [0])} ms; "
          + " ".join(f"@{s}+{d}" for s, d in longs[:12]))
    print("  resources (start, dur, ttfb, transfer, body, workerStart):")
    for r in sorted(got["res"], key=lambda r: r["start"]):
        if r["url"].startswith(("static/", "api/", "manifest", "sw.js")) or "cdn" in r["url"]:
            print(f"    {r['url'][:48]:48s} {r['start']:6d} {r['dur']:6d} {r['ttfb']:6d} {r['size']:7d} {r['body']:7d} {r['worker']:4d}")
    print("  CPU self time by script (ms):", ", ".join(f"{k} {v:.0f}" for k, v in list(got["by_url"].items())[:8]))
    print("  top functions by self time (ms):")
    for k, v in got["top"]:
        print(f"    {v:8.1f}  {k}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--cpu", type=float, default=6)
    ap.add_argument("--rtt", type=float, default=150, help="ms")
    ap.add_argument("--down", type=float, default=1.6, help="Mbit/s")
    ap.add_argument("--up", type=float, default=0.75, help="Mbit/s")
    ap.add_argument("--messages", type=int, default=200)
    ap.add_argument("--bytes", type=int, default=233_000)
    ap.add_argument("--sessions", type=int, default=44)
    ap.add_argument("--runs", type=int, default=1)
    ap.add_argument("--top", type=int, default=15)
    ap.add_argument("--timeout", type=int, default=120_000, help="ms to wait for the history to paint")
    ap.add_argument("--json", help="also write every run's raw collection to this file")
    args = ap.parse_args()
    binary = chromium_binary()
    if not binary:
        sys.exit("no headless Chromium found (chromium on PATH or playwright's chrome-headless-shell)")
    served = Served(args.sessions, args.messages, args.bytes)
    net = {"latency": args.rtt, "downloadThroughput": args.down * 1_000_000 / 8, "uploadThroughput": args.up * 1_000_000 / 8}
    print(f"app at {served.url}; {len(served.fleet)} sessions; the open session {served.name!r} (pid {served.pid}) with a reset of "
          f"{served.bytes} bytes for {args.messages} messages (scale {served.scale:.2f}); chromium {binary}")
    print(f"throttle: CPU {args.cpu}x, network {args.down} Mbit/s down / {args.up} up / {args.rtt} ms RTT")
    raws = []
    try:
        for run in range(args.runs):
            c = CDP(binary, 390, 844)
            try:
                c.send("Emulation.setDeviceMetricsOverride", {"width": 390, "height": 844, "deviceScaleFactor": 1, "mobile": True})
                c.send("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-color-scheme", "value": "dark"}]})
                url = f"{served.url}/#s={served.name}"
                cold = one_load(c, url, "navigate", args.cpu, net, args.timeout, args.top)
                report(f"run {run + 1}: cold load, throttled", cold)
                time.sleep(1.0)  # the worker's install settles
                warm = one_load(c, url, "reload", args.cpu, net, args.timeout, args.top)
                report(f"run {run + 1}: reload under the service worker, throttled", warm)
                raws += [{"run": run + 1, "how": "cold", **cold}, {"run": run + 1, "how": "reload", **warm}]
            finally:
                c.close()
        c = CDP(binary, 390, 844)
        try:
            c.send("Emulation.setDeviceMetricsOverride", {"width": 390, "height": 844, "deviceScaleFactor": 1, "mobile": True})
            floor = one_load(c, f"{served.url}/#s={served.name}", "navigate", 1, None, args.timeout, args.top)
            report("floor: cold load, no throttling", floor)
            raws.append({"run": 0, "how": "floor", **floor})
        finally:
            c.close()
    finally:
        served.close()
    if args.json:
        Path(args.json).write_text(json.dumps(raws, indent=1))


if __name__ == "__main__":
    main()
