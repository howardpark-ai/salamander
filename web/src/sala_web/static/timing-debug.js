"use strict";
/* sala timing recorder (temporary): where a page load's milliseconds go, posted to api/debug/timing
   (timingdebug.py), where the maintainer reads them over the unix socket. Loaded by the block at the top of app.js only
   when the flag is on (?debug=timing once, kept in localStorage so the installed app keeps it; ?debug=off clears it).
   What it records, each with the page load's id (new every load), the client's id (kept in localStorage) and the ms
   offset from the navigation's start:
   - the performance.mark()s app.js leaves (perfMark): app.js start, init, the session list requested, answered,
     rendered and painted, a session restored, the stream opened, its first event, its reset (count, bytes) and the
     history rendered (count, bytes, ms) and painted, appends, a version check (the server's and the page's), a reload
     and its cause, the service worker's lifecycle, a fetch retried or failed;
   - a "hello" with the browser (user agent, short), the installed-app mode, whether a worker controls the page, the
     build, and the navigation timing (its type: navigate, reload or back_forward; redirects, response start, DOMContentLoaded, load);
   - the resource timing of the page's own files and API calls (start, duration, time to first byte, bytes
     transferred (0: from the cache without a request), body bytes, how long the worker took before the request went
     out, the status);
   - long tasks (over 50 ms: start and duration), visibility changes, pageshow (from the back/forward cache or not),
     online/offline, and errors thrown (message and place, never a stack's text beyond that).
   Never the text of a message, a session's transcript or anything typed. Records are batched for 300 ms and sent with
   fetch keepalive; at pagehide the queue goes with sendBeacon; a failed post is dropped; at most CAP records a load.
   Remove with the rest of the timing debug (README "Timing"). */
window.salaTiming = (() => {
  const CAP = 1000;
  const FLUSH_MS = 300;
  const RESOURCE_CAP = 80;
  const cfg = { api: "api/debug/timing" };
  let queue = [], timer = null, count = 0, seq = 0, started = false, capped = false, seenMarks = 0, resources = 0;

  const rid = (n) => {
    try { const a = new Uint8Array(n); crypto.getRandomValues(a); return [...a].map((b) => (b % 36).toString(36)).join(""); }
    catch { return Math.random().toString(36).slice(2, 2 + n); }
  };
  const load = rid(6);
  let client = "nostore";
  try {
    client = localStorage.getItem("sala.debug.client") || "";
    if (!client) { client = rid(6); localStorage.setItem("sala.debug.client", client); }
  } catch { /* storage unavailable */ }
  const r1 = (x) => Math.round(x * 10) / 10;
  // "Android 14; Chrome/130" from the user agent (the full string goes in the hello, once)
  function shortUa() {
    const ua = navigator.userAgent || "";
    const os = (/Android [\d.]+|iPhone OS [\d_]+|Windows NT [\d.]+|Mac OS X [\d_]+|CrOS|Linux/.exec(ua) || [""])[0];
    const br = (/(?:Chrome|CriOS|Firefox|Safari|Edg|SamsungBrowser)\/[\d.]+/.exec(ua) || [""])[0];
    return [os, br].filter(Boolean).join("; ") || ua.slice(0, 60);
  }
  const shortUrl = (u) => String(u || "").replace(/^https?:\/\/[^/]+\//, "").replace(/\?v=[^&]*/, "").slice(0, 80);

  function rec(name, t, detail) {
    if (count >= CAP) {
      if (!capped) { capped = true; queue.push({ seq: ++seq, t: r1(performance.now()), load, client, name: "cap-reached", cap: CAP }); schedule(); }
      return false;
    }
    count++;
    // the record's own columns last: a detail cannot rename the record (a mark's detail never uses these keys)
    queue.push({ ...(detail || {}), seq: ++seq, t: r1(t == null ? performance.now() : t), load, client, name });
    schedule();
    return true;
  }
  function schedule() { if (!timer) timer = setTimeout(flush, FLUSH_MS); }
  function flush(beacon) {
    clearTimeout(timer); timer = null;
    if (!queue.length) return;
    const batch = queue; queue = [];
    const body = JSON.stringify(batch);
    try {
      if (beacon && navigator.sendBeacon && navigator.sendBeacon(cfg.api, new Blob([body], { type: "application/json" }))) return;
      fetch(cfg.api, { method: "POST", headers: { "Content-Type": "application/json" }, body, keepalive: true, cache: "no-store" })
        .catch(() => { /* dropped: the log is best effort */ });
    } catch { /* fetch itself threw: dropped */ }
  }

  // the marks app.js made so far, in order, each once; called at start, on every new mark and at pagehide
  function sweepMarks() {
    let marks = [];
    try { marks = performance.getEntriesByType("mark"); } catch { return; }
    for (; seenMarks < marks.length; seenMarks++) {
      const m = marks[seenMarks];
      rec(m.name, m.startTime, m.detail && typeof m.detail === "object" ? m.detail : (m.detail == null ? null : { detail: String(m.detail).slice(0, 120) }));
    }
  }
  function navInfo() {
    const n = performance.getEntriesByType("navigation")[0];
    if (!n) return null;
    return { type: n.type, redirects: n.redirectCount, worker: r1(n.workerStart), fetchStart: r1(n.fetchStart), responseStart: r1(n.responseStart),
             responseEnd: r1(n.responseEnd), dcl: r1(n.domContentLoadedEventStart), load: r1(n.loadEventEnd), transfer: n.transferSize,
             body: n.encodedBodySize, delivery: n.deliveryType || null, protocol: n.nextHopProtocol || null };
  }
  function resource(e) {
    if (resources >= RESOURCE_CAP) return;
    const url = shortUrl(e.name);
    if (!/^(static\/|api\/|manifest|sw\.js|debug\/)/.test(url) && !/cdn\./.test(e.name)) return;
    if (url.startsWith("api/debug/")) return;  // this recorder's own posts
    resources++;
    rec("resource", e.startTime, { url, dur: r1(e.duration), ttfb: r1(e.responseStart ? e.responseStart - e.startTime : 0), size: e.transferSize,
                                   body: e.encodedBodySize, worker: e.workerStart ? r1(e.workerStart - e.startTime) : 0,
                                   status: e.responseStatus || null, delivery: e.deliveryType || null, as: e.initiatorType });
  }
  function hello() {
    const ua = navigator.userAgentData;
    let standalone = null;
    try { standalone = window.matchMedia("(display-mode: standalone)").matches; } catch { /* none */ }
    rec("hello", 0, { ua: shortUa(), uaFull: (navigator.userAgent || "").slice(0, 200),
      uaData: ua ? { platform: ua.platform, mobile: ua.mobile, brands: (ua.brands || []).map((b) => b.brand + "/" + b.version).join(" ") } : null,
      standalone, visibility: document.visibilityState, referrer: shortUrl(document.referrer), hash: location.hash.slice(0, 40),
      controlled: !!(navigator.serviceWorker && navigator.serviceWorker.controller),
      version: (document.querySelector('meta[name="sala-web-version"]') || {}).content || null,
      nav: navInfo(), cores: navigator.hardwareConcurrency || null, memory: navigator.deviceMemory || null,
      conn: navigator.connection ? { type: navigator.connection.effectiveType, rtt: navigator.connection.rtt, down: navigator.connection.downlink, save: navigator.connection.saveData } : null,
      cap: CAP });
  }

  function start(opts) {
    if (started) return;
    started = true;
    Object.assign(cfg, opts || {});
    hello();
    for (const e of window.__salaTimingErrors || []) rec("error", e.t, { msg: e.msg, src: e.src || null, line: e.line || null, early: true });
    window.__salaTimingErrors = [];
    window.addEventListener("error", (e) => rec("error", null, { msg: String(e.message || e).slice(0, 200), src: String(e.filename || "").slice(-60), line: e.lineno || null }));
    window.addEventListener("unhandledrejection", (e) => rec("error", null, { msg: String((e.reason && e.reason.message) || e.reason).slice(0, 200), rejection: true }));
    sweepMarks();
    try { new PerformanceObserver(() => sweepMarks()).observe({ type: "mark" }); } catch { /* no observer: pagehide sweeps */ }
    try {
      for (const e of performance.getEntriesByType("resource")) resource(e);
      new PerformanceObserver((l) => { for (const e of l.getEntries()) resource(e); }).observe({ type: "resource" });
    } catch { /* no resource timing */ }
    try {
      new PerformanceObserver((l) => { for (const e of l.getEntries()) rec("longtask", e.startTime, { dur: r1(e.duration) }); }).observe({ type: "longtask", buffered: true });
    } catch { rec("longtask", null, { unsupported: true }); }
    // a tick after the load event, so the navigation timing's loadEventEnd is in
    if (document.readyState !== "complete") window.addEventListener("load", () => setTimeout(() => rec("load", null, { nav: navInfo() }), 0), { once: true });
    document.addEventListener("visibilitychange", () => { rec("visibility", null, { state: document.visibilityState }); if (document.hidden) { sweepMarks(); flush(); } });
    window.addEventListener("pageshow", (e) => rec("pageshow", null, { persisted: !!e.persisted }));
    window.addEventListener("pagehide", (e) => { rec("pagehide", null, { persisted: !!e.persisted }); sweepMarks(); flush(true); });
    window.addEventListener("online", () => rec("online"));
    window.addEventListener("offline", () => rec("offline"));
    viewportWatch();
  }

  // The viewports and the composer's place (the composer's lower half under the screen's edge after
  // a keyboard paste and the keyboard's close; app.js "the shell's height"). A "viewport" record at start, on a resize
  // of the visual viewport or the window, a scroll of the visual viewport, the composer taking or losing the focus (a
  // keyboard likely up or down), and once more half a second after the last of those (settled); one a frame, and only
  // when a value changed. why: which of those; vvH, vvTop, scale: visualViewport height, offsetTop, scale; inner:
  // innerHeight; clientH: documentElement.clientHeight; dvh: 100dvh measured; app: #app's height and appVar the --app-h
  // the page set; compTop, compBottom, rowBottom, modelBottom: the composer's box, the compose row's and the model
  // line's bottoms; pad: the composer's bottom padding (10 + the safe-area inset); focus: the composer has the focus.
  // Numbers and names only: never what the composer holds.
  function viewportWatch() {
    let last = "", raf = 0, late = 0, probe = null;
    const take = (why) => {
      raf = 0;
      const vv = window.visualViewport, root = document.documentElement;
      const app = document.getElementById("app"), comp = document.getElementById("composer");
      const row = document.querySelector(".compose-row"), ml = document.getElementById("model-line");
      if (!probe && document.body) {
        probe = document.createElement("div");
        probe.style.cssText = "position:fixed;top:0;left:0;width:0;height:100dvh;visibility:hidden;pointer-events:none";
        document.body.append(probe);
      }
      const bottom = (n) => (n && !n.hidden ? r1(n.getBoundingClientRect().bottom) : null);
      const d = { why, vvH: vv ? r1(vv.height) : null, vvTop: vv ? r1(vv.offsetTop) : null, scale: vv ? r1(vv.scale) : null,
                  inner: window.innerHeight, clientH: root.clientHeight, dvh: probe ? probe.offsetHeight : null,
                  app: app ? r1(app.getBoundingClientRect().height) : null, appVar: root.style.getPropertyValue("--app-h") || null,
                  compTop: comp ? r1(comp.getBoundingClientRect().top) : null, compBottom: bottom(comp), rowBottom: bottom(row), modelBottom: bottom(ml),
                  pad: comp ? getComputedStyle(comp).paddingBottom : null,
                  focus: !!document.activeElement && document.activeElement.id === "input" };
      const key = JSON.stringify([d.vvH, d.vvTop, d.scale, d.inner, d.clientH, d.dvh, d.app, d.appVar, d.compTop, d.compBottom, d.rowBottom, d.modelBottom, d.pad, d.focus]);
      if (key === last && why !== "start") return;
      last = key;
      rec("viewport", null, d);
    };
    const soon = (why) => {
      if (!raf) raf = requestAnimationFrame(() => take(why));
      clearTimeout(late);
      late = setTimeout(() => take("settled"), 500);
    };
    take("start");
    if (window.visualViewport) {
      window.visualViewport.addEventListener("resize", () => soon("vv-resize"));
      window.visualViewport.addEventListener("scroll", () => soon("vv-scroll"));
    }
    window.addEventListener("resize", () => soon("resize"));
    document.addEventListener("focusin", (e) => { if (e.target && e.target.id === "input") soon("focus"); });
    document.addEventListener("focusout", (e) => { if (e.target && e.target.id === "input") soon("blur"); });
  }
  return { start, record: rec, flush, count: () => count, load, client, CAP };
})();
