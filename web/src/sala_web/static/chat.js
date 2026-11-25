"use strict";
/* The chat page (chat.html; web/README.md, *The chat page*): ONE configured session as one conversation. Everything it shows comes from GET api/chat
   (chatpage.py: the turns by the rule in chatturns.py, the owner's moves from the board feed, the session's own `sala motion` lines, link cards).
   Nothing here decides what is shown: the page draws what the server sent and keeps the same DOM for what did not change.

   - Live: the existing SSE stream of the session (api/s/<pid>/stream) only says "something changed"; the page then asks api/chat again (a debounced
     read, never more than one at a time). A slow poll (30 s, while the tab is visible) covers a session with no stream (asleep) and a stream that
     dropped.
   - Send: the existing POST api/s/<pid>/send (the main chat's path: the same guards, the same duplicate window, the same answers), not a second one.
   - A sleeping session: a sentence and the main chat's wake (POST api/wake, then api/spawn/status until the session is live).
   - No sideways scroll at any width: chat.css; text that came from a session is set with textContent or through marked + DOMPurify, never as markup of its own.
   - Times are in the zone api/chat names (the server's zone setting), through shared.js's zoneFormat. */
(() => {
  const $ = (sel, root = document) => root.querySelector(sel);
  const el = (tag, attrs = {}, ...kids) => {
    const n = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs)) {
      if (v == null || v === false) continue;
      if (k === "class") n.className = v;
      else if (k === "text") n.textContent = v;
      else if (k.startsWith("on")) n.addEventListener(k.slice(2), v);
      else n.setAttribute(k, v === true ? "" : v);
    }
    for (const c of kids) if (c != null) n.append(c);
    return n;
  };
  const sleep = (ms) => new Promise((res) => setTimeout(res, ms));

  const LOADED_VERSION = document.querySelector('meta[name="sala-web-version"]')?.content || "";
  const LOADED_STYLES = document.querySelector('meta[name="sala-web-styles"]')?.content || "";
  const KEPT_KEY = "salaweb.chat.kept";
  const POLL_MS = 30000, DEBOUNCE_MS = 350, WAKE_POLL_MS = 2000, WAKE_GIVE_UP_MS = 240000, PIN_PX = 90, PENDING_MS = 120000;   // a sent message stays as a pending bubble until the transcript shows it, at most this long

  const S = {
    data: null,            // the last good answer of api/chat
    error: "",             // the last read that failed ("" = fine)
    kept: false,           // the switch: show the kept-back lines
    seenWait: null,        // ids of the owner's moves already shown (null until the first answer): one that is not in it is "new"
    newWait: new Set(),
    pending: [],           // sent from this page and not yet in the transcript: {text, at, status, error}
    es: null, esPid: 0,    // the stream
    styles: LOADED_STYLES,
    updateSeen: false,
    pinned: true,          // the page is at its bottom: a new message scrolls into view
    nodes: new Map(),      // an entry's key -> the node drawn for it (a message is made once)
    reading: false, again: false, timer: 0,
    wake: null,            // {state: "asking" | "queued" | "failed" | "late", why}
    sending: false, note: "", noteError: false,
  };
  try { S.kept = localStorage.getItem(KEPT_KEY) === "1"; } catch { /* storage unavailable */ }

  /* ---------- markdown (the main chat's: marked, then DOMPurify, links in a new tab) ---------- */
  if (window.marked && typeof noSingleTildeStrike === "function") noSingleTildeStrike(marked);
  if (window.DOMPurify) {
    DOMPurify.addHook("afterSanitizeAttributes", (node) => {
      if (node.tagName === "A") { node.setAttribute("target", "_blank"); node.setAttribute("rel", "noopener noreferrer"); }
    });
  }
  const isLocalSrc = (s) => (s.startsWith("/") && !s.startsWith("//")) || s.startsWith("~/");
  function md(text) {
    try {
      const d = el("div", { class: "md" });
      d.append(DOMPurify.sanitize(marked.parse(mdPrep(text), { gfm: true, breaks: true }), { RETURN_DOM_FRAGMENT: true }));
      for (const img of d.querySelectorAll("img")) {   // a file on the server's machine is not served here: its caption stands in
        let src = img.getAttribute("src") || "";
        try { src = decodeURI(src); } catch { /* as written */ }
        if (isLocalSrc(src)) img.replaceWith(document.createTextNode(img.getAttribute("alt") || ""));
      }
      return d;
    } catch {
      return el("div", { class: "md", style: "white-space:pre-wrap", text });
    }
  }
  // text as written (what he typed), links tappable: text nodes and <a> elements, never markup
  const linkNodes = (text) => linkTokens(text).map((t) =>
    t.href ? el("a", { href: t.href, target: "_blank", rel: "noopener noreferrer", text: t.text }) : document.createTextNode(t.text));

  /* ---------- times, in the server's zone ---------- */
  const timeFmt = zoneFormat(() => SalaI18n.locale(), { hour: "2-digit", minute: "2-digit", hour12: false });
  const dateTimeFmt = zoneFormat(() => SalaI18n.locale(), { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false });
  const dayFmt = zoneFormat("en-CA", { year: "numeric", month: "2-digit", day: "2-digit" });
  function stamp(ms) {
    if (!Number.isFinite(ms)) return "";
    const d = new Date(ms);
    return dayFmt.format(d) === dayFmt.format(new Date()) ? timeFmt.format(d) : dateTimeFmt.format(d);
  }

  /* ---------- the parts ---------- */
  function cardNode(c) {
    const label = c.kind === "mockup" ? tl("chat.card.mockup", { n: c.n }) : tl("chat.card.artifact");
    const href = c.kind === "mockup" ? "mockup/" + encodeURIComponent(String(c.n)) : c.url;   // relative: the page may sit under a path prefix
    const kids = [el("span", { class: "card-t", text: c.title || label })];
    if (c.title) kids.push(el("span", { class: "card-l", text: label }));
    kids.push(el("span", { class: "card-o", text: tl("chat.card.opens") }));
    return el("a", { class: "card", href, target: "_blank", rel: "noopener noreferrer" }, ...kids);
  }
  const cardsOf = (e) => (Array.isArray(e.cards) ? e.cards.map(cardNode) : []);

  function sourceText(src) {
    const k = src && src.kind;
    if (k === "sala") return tl("chat.src.sala");
    if (k === "board") return tl("chat.src.board");
    if (k === "session" && src.name) return tl("chat.src.session", { name: src.name });
    if (k === "task") return tl("chat.src.task");
    if (k === "system") return tl("chat.src.system");
    return tl("chat.src.other");
  }

  function entryNode(e, d) {
    if (e.k === "kept") {
      const kids = [el("time", { text: stamp(e.ts) }), el("span", { class: "src", text: sourceText(e.src) })];
      if (e.what) kids.push(el("span", { class: "what", text: e.what }));
      if (e.open) kids.push(el("span", { class: "did", text: tl("chat.kept.open") }));
      else if (e.did) kids.push(el("span", { class: "did", text: e.did }));
      return el("div", { class: "kept" }, ...kids);
    }
    const ts = el("div", { class: "ts", text: stamp(e.ts) });
    if (e.k === "me") {
      const body = [...linkNodes(e.text || "")];
      if (e.images) body.push(document.createTextNode((body.length ? " " : "") + "[" + tl("chat.image") + (e.images > 1 ? " ×" + e.images : "") + "]"));
      return el("div", { class: "msg user" }, el("div", { class: "bubble" }, ...body), ...cardsOf(e), ts);
    }
    const kids = [];
    if (e.k === "own") kids.push(el("div", { class: "own", text: tl("chat.own", { name: d.name }) }));
    kids.push(md(e.text || ""), ...cardsOf(e), ts);
    return el("div", { class: "msg assistant" }, ...kids);
  }

  function hash(s) {
    let h = 5381;
    for (let i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) | 0;
    return h >>> 0;
  }
  const keyOf = (e, i) => [e.k, e.id || "i" + i, e.ts || 0, hash((e.text || "") + (e.what || "") + (e.did || "") + (e.open ? "o" : "") + JSON.stringify(e.cards || []))].join(":");

  /* ---------- the page ---------- */
  const root = $("#cp");
  let ui = null;   // the pieces that stay while data changes

  function build() {
    const update = el("div", { class: "cp-update", hidden: true, role: "status" },
      el("span", { ...tx("chat.update") }),
      el("button", { type: "button", class: "cp-btn", ...tx("chat.reload"), onclick: () => location.reload() }));
    const dot = el("i", { "aria-hidden": "true" });
    const nameEl = el("span", { class: "bar-name-text" });
    const stateEl = el("span", { class: "bar-state" });
    const sw = el("input", { type: "checkbox", id: "kept-switch" });
    sw.checked = S.kept;
    sw.addEventListener("change", () => {
      S.kept = sw.checked;
      try { localStorage.setItem(KEPT_KEY, S.kept ? "1" : "0"); } catch { /* storage unavailable */ }
      drawThread();
    });
    const swText = el("span");
    const countEl = el("span", { class: "count" });
    const pane = el("a", { class: "pane-link", target: "_blank", rel: "noopener noreferrer", ...tx("chat.pane") });
    const bar = el("div", { class: "bar" },
      el("h2", { class: "bar-name" }, dot, nameEl, stateEl),
      el("label", { class: "kept-toggle", for: "kept-switch" }, sw, swText, countEl), pane);

    const waitList = el("ul", { class: "wait-list" });
    const waitNote = el("p", { class: "wait-err" });
    const wait = el("section", { class: "wait", "aria-label": tl("chat.wait.h") },
      el("div", { class: "sec-head" }, el("b", { ...tx("chat.wait.h") }), el("span", { ...tx("chat.wait.sub") })), waitList, waitNote,
      el("p", { class: "wait-cap", ...tx("chat.wait.note") }));

    const moList = el("ul", { class: "mo-list" });
    const motion = el("section", { class: "motion", "aria-label": tl("chat.motion.h") }, el("span", { class: "lbl", ...tx("chat.motion.h") }), moList);

    const thread = el("div", { class: "thread", role: "log" });
    const chat = el("div", { class: "chat" }, thread);
    // the working spinner of the main view (style.css .inflight / .spinner), kept out of the thread so the thread's redraw never restarts the spin; in the page only while the session works
    const inflight = el("div", { class: "inflight", role: "status" }, el("span", { class: "spinner" }));

    const ta = el("textarea", { class: "compose-input", rows: "1", enterkeyhint: "send", autocomplete: "off", spellcheck: "true" });
    const send = el("button", { type: "button", class: "send-btn", ...tx("chat.send", null, "aria-label") },
      svg());
    const row = el("div", { class: "compose-row" }, ta, send);
    const note = el("p", { class: "compose-note", role: "status" });
    const sleepBox = el("div", { class: "compose-sleep" });
    const composer = el("div", { class: "composer" }, row, sleepBox, note);

    root.replaceChildren(update, bar, wait, motion, chat, composer);
    ui = { update, dot, nameEl, stateEl, sw, swText, countEl, pane, waitList, waitNote, moList, thread, chat, inflight, ta, send, row, note, sleepBox, composer };

    const coarse = matchMedia("(pointer: coarse)").matches;
    ta.addEventListener("keydown", (ev) => {
      if (ev.key !== "Enter" || ev.shiftKey || ev.isComposing || ev.keyCode === 229) return;
      if (coarse) return;   // a phone's Enter is a new line; the button sends
      ev.preventDefault();
      doSend();
    });
    ta.addEventListener("input", () => { grow(); refreshSend(); });
    send.addEventListener("click", doSend);
  }
  function svg() {
    const ns = "http://www.w3.org/2000/svg";
    const s = document.createElementNS(ns, "svg");
    for (const [k, v] of Object.entries({ width: 16, height: 16, viewBox: "0 0 16 16", fill: "none", stroke: "currentColor", "stroke-width": 2, "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": "true" })) s.setAttribute(k, v);
    const p = document.createElementNS(ns, "path");
    p.setAttribute("d", "M8 13V3M4 7l4-4 4 4");
    s.append(p);
    return s;
  }
  function grow() {
    const ta = ui.ta;
    ta.style.height = "auto";
    ta.style.height = Math.min(ta.scrollHeight, Math.round(innerHeight * 0.4)) + "px";
  }
  function refreshSend() {
    const d = S.data;
    ui.send.disabled = S.sending || !d || d.present !== "live" || !ui.ta.value.trim();
  }

  function drawNone() {
    root.replaceChildren(el("p", { class: "cp-none", ...tx("chat.none") }));
    ui = null;
  }

  function draw() {
    const d = S.data;
    if (!d) return;
    applyZone(d);
    if (!d.configured) { drawNone(); return; }
    if (!ui) build();
    document.title = d.name;
    // the bar
    ui.nameEl.textContent = d.name;
    const st = d.present === "live" ? (d.busy ? "busy" : "idle") : d.present === "sleeping" ? "asleep" : "absent";
    ui.dot.className = st === "busy" ? "busy" : st === "idle" ? "idle" : "";
    const stateWord = st === "busy" ? tl("chat.state.busy") : st === "idle" ? tl("chat.state.idle") : st === "asleep" ? tl("chat.state.asleep") : tl("chat.state.absent");
    ui.dot.title = stateWord;
    ui.stateEl.textContent = st === "asleep" || st === "absent" ? stateWord : "";
    ui.swText.textContent = tl("chat.kept.toggle", { name: d.name });
    const n = d.keptToday | 0;
    ui.countEl.textContent = tl(d.keptTodayFloor ? "chat.kept.floor" : "chat.kept.count", { n });
    ui.pane.setAttribute("href", "./#s=" + encodeURIComponent(d.session));
    ui.pane.setAttribute("title", d.session);
    // waiting on the owner
    const ids = new Set((d.waiting || []).map((w) => w.id));
    if (S.seenWait === null) S.seenWait = ids;
    else for (const id of ids) if (!S.seenWait.has(id)) { S.seenWait.add(id); S.newWait.add(id); }
    ui.waitList.replaceChildren(...(d.waiting || []).map(waitRow));
    if (!ids.size) ui.waitList.append(el("li", { class: "wait-none", ...tx("chat.wait.none") }));
    ui.waitNote.textContent = S.error ? tl("chat.error") : "";
    // in motion
    const mo = d.motion || [];
    ui.moList.replaceChildren(...(mo.length ? mo.map((m) => el("li", { class: "mo", text: m.text })) : [el("li", { class: "mo none", ...tx("chat.motion.none") })]));
    drawThread();
    drawComposer();
    ui.thread.setAttribute("aria-label", tl("chat.thread.aria", { zone: zoneLabel(new Date()) }));
  }

  function waitRow(w) {
    const subj = el("span", { class: "wait-subj" });
    subj.append(w.url ? el("a", { href: w.url, target: "_blank", rel: "noopener noreferrer", text: w.subject || w.id }) : document.createTextNode(w.subject || w.id));
    if (S.newWait.has(w.id)) subj.append(el("span", { class: "new", ...tx("chat.wait.new") }));
    const kids = [subj];
    if (w.url) kids.push(el("a", { class: "answer", href: w.url, target: "_blank", rel: "noopener noreferrer", ...tx("chat.wait.answer") }));
    return el("li", { class: "wait-row" }, ...kids);
  }

  function drawThread() {
    const d = S.data;
    if (!d || !ui) return;
    const wasPinned = S.pinned;
    const next = new Map();
    const nodes = [];
    const list = d.entries || [];
    list.forEach((e, i) => {
      if (e.k === "kept" && !S.kept) return;
      const key = keyOf(e, i);
      let node = S.nodes.get(key);
      if (!node) node = entryNode(e, d);
      next.set(key, node);
      nodes.push(node);
    });
    // what he sent from this page and the transcript does not show yet
    S.pending = S.pending.filter((p) => Date.now() - p.at < PENDING_MS && !list.some((e) => e.k === "me" && (e.text || "").trim() === p.text.trim() && (e.ts || 0) >= p.at - 10000));
    for (const p of S.pending) {
      const b = el("div", { class: "bubble pending" }, ...linkNodes(p.text));
      nodes.push(el("div", { class: "msg user" }, b, el("div", { class: "ts", text: stamp(p.at) })));
    }
    if (!nodes.length) nodes.push(el("p", { class: "empty", ...tx("chat.empty") }));
    S.nodes = next;
    ui.thread.replaceChildren(...nodes);
    drawInflight();
    if (wasPinned) scrollEnd();
  }

  // a small spinner under the last message while the session works, as the main view shows (app.js updateInflight): there while the session is live and busy, gone
  // otherwise. A message sent from this page that the transcript does not show yet adds none: the session's own busy flag says when it works.
  function drawInflight() {
    const d = S.data, n = ui.inflight;
    if (d && d.present === "live" && d.busy) {
      const label = tl("app.working");
      if (n.getAttribute("aria-label") !== label) { n.setAttribute("aria-label", label); n.setAttribute("title", label); }
      if (n.parentNode !== ui.chat) ui.chat.append(n);
    } else if (n.parentNode) n.remove();
  }

  function drawComposer() {
    const d = S.data;
    const live = d.present === "live";
    ui.row.hidden = !live;
    ui.sleepBox.replaceChildren();
    ui.sleepBox.hidden = live;
    ui.ta.placeholder = tl("chat.composer.ph", { name: d.name });
    ui.ta.setAttribute("aria-label", tl("chat.composer.ph", { name: d.name }));
    if (!live) {
      const w = S.wake;
      let text = d.present === "sleeping" ? tl("chat.asleep", { name: d.name }) : tl("chat.absent", { name: d.name });
      if (w && w.state === "queued") text = tl("chat.waking", { name: d.name });
      else if (w && w.state === "asking") text = tl("chat.waking", { name: d.name });
      else if (w && w.state === "failed") text = tl("chat.wakeFailed", { name: d.name, why: w.why || "" });
      else if (w && w.state === "late") text = tl("chat.wakeLate", { name: d.name });
      ui.sleepBox.append(el("span", { text }));
      if (d.present === "sleeping") {
        const busy = w && (w.state === "asking" || w.state === "queued");
        ui.sleepBox.append(el("button", { type: "button", class: "cp-btn", disabled: busy || null, text: tl("chat.wake", { name: d.name }), onclick: wake }));
      }
    }
    ui.note.textContent = S.note;
    ui.note.className = "compose-note" + (S.noteError ? " error" : "");
    ui.note.hidden = !S.note;
    refreshSend();
  }

  function scrollEnd() { window.scrollTo(0, document.documentElement.scrollHeight); }
  addEventListener("scroll", () => {
    S.pinned = innerHeight + scrollY >= document.documentElement.scrollHeight - PIN_PX;
  }, { passive: true });

  /* ---------- reading ---------- */
  async function load() {
    if (S.reading) { S.again = true; return; }
    S.reading = true;
    try {
      const r = await fetch("api/chat", { cache: "no-store" });
      if (!r.ok) throw new Error("HTTP " + r.status);
      const first = S.data === null;
      S.data = await r.json();
      S.error = "";
      noteVersion(S.data.version, S.data.styles);
      draw();
      if (first) scrollEnd();
      openStream();
    } catch {
      S.error = "x";
      if (S.data && ui) ui.waitNote.textContent = tl("chat.error");
      else if (!S.data) root.replaceChildren(el("p", { class: "cp-none", ...tx("chat.error") }));
    } finally {
      S.reading = false;
      if (S.again) { S.again = false; schedule(); }
    }
  }
  function schedule(ms = DEBOUNCE_MS) {
    clearTimeout(S.timer);
    S.timer = setTimeout(load, ms);
  }

  // the existing stream says only that something changed; the page then reads api/chat once
  function openStream() {
    const pid = S.data && S.data.configured && S.data.present === "live" ? S.data.pid : 0;
    if (pid === S.esPid) return;
    if (S.es) { S.es.close(); S.es = null; }
    S.esPid = pid;
    if (!pid || !window.EventSource) return;
    const es = new EventSource(`api/s/${pid}/stream`);
    S.es = es;
    let first = true;
    const changed = () => schedule();
    for (const ev of ["append", "status", "gone", "live"]) es.addEventListener(ev, changed);
    es.addEventListener("reset", () => { if (first) first = false; else changed(); });
  }

  /* ---------- the page's own version: the strip, and the style sheets swapped in place ---------- */
  function swapStyles(v) {
    if (!v || !LOADED_STYLES || v === S.styles) return;
    const before = S.styles;
    S.styles = v;
    for (const old of document.querySelectorAll('link[rel="stylesheet"]')) {
      const m = /^(static\/[^?&]+\.css)(?:[?&]|$)/.exec(old.getAttribute("href") || "");
      if (!m) continue;
      const n = old.cloneNode(false);
      n.setAttribute("href", m[1] + "?v=" + encodeURIComponent(v));
      n.addEventListener("load", () => old.remove());
      n.addEventListener("error", () => { n.remove(); if (S.styles === v) S.styles = before; });
      old.after(n);
    }
  }
  function noteVersion(v, styles) {
    if (styles) swapStyles(styles);
    if (!v || !LOADED_VERSION || v === LOADED_VERSION) return;
    S.updateSeen = true;
    if (ui) ui.update.hidden = false;
  }

  /* ---------- sending: the main chat's path ---------- */
  async function doSend() {
    const d = S.data;
    const text = ui.ta.value.trim();
    if (S.sending || !d || d.present !== "live" || !text) return;
    S.sending = true; S.note = ""; S.noteError = false;
    refreshSend();
    const at = Date.now();
    let ok = false;
    try {
      const r = await fetch(`api/s/${d.pid}/send`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ text, uploads: [] }) });
      const j = await r.json().catch(() => ({}));
      if (r.status === 409 && j.duplicate) ok = true;   // the server pasted this very message moments ago: nothing more to do
      else if (!r.ok || !j.ok) throw new Error(j.error || tl("chat.sendFailed", { why: `${r.status} ${r.statusText}`.trim() }));
      else ok = true;
    } catch (e) {
      S.note = e instanceof TypeError ? tl("chat.noNet") : String(e.message || tl("chat.sendFailed", { why: "" }));
      S.noteError = true;
    }
    S.sending = false;
    if (ok) {
      S.pending.push({ text, at });
      ui.ta.value = "";
      grow();
      S.pinned = true;
      schedule(600);
    }
    if (S.data && ui) { drawThread(); drawComposer(); }
  }

  /* ---------- waking a sleeper: the main chat's wake ---------- */
  async function wake() {
    const d = S.data;
    if (!d || d.present !== "sleeping" || (S.wake && (S.wake.state === "asking" || S.wake.state === "queued"))) return;
    const w = S.wake = { state: "asking", why: "" };
    drawComposer();
    let out;
    try {
      const r = await fetch("api/wake", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name: d.session, how: "button" }) });
      out = { status: r.status, d: await r.json().catch(() => ({})) };
    } catch (e) {
      out = { status: 0, d: { ok: false, error: tl("chat.noNet") } };
    }
    if (out.status === 200 && out.d.ok) { S.wake = null; await load(); return; }
    if (out.status !== 202 || !out.d.ok) { w.state = "failed"; w.why = String(out.d.error || "HTTP " + out.status); drawComposer(); return; }
    w.state = "queued";
    drawComposer();
    const t0 = Date.now();
    while (S.wake === w) {
      await sleep(WAKE_POLL_MS);
      let st = "";
      try {
        const r = await fetch(`api/spawn/status?op=${encodeURIComponent(out.d.op)}`, { cache: "no-store" });
        if (r.ok) { const j = await r.json(); st = j.state || ""; if (nsOpPhase(st) === "failed") w.why = String(j.result || st); }
      } catch { /* the next tick asks again */ }
      await load();
      if (S.wake !== w) return;
      if (S.data && S.data.present === "live") { S.wake = null; drawComposer(); return; }
      if (nsOpPhase(st) === "failed") { w.state = "failed"; drawComposer(); return; }
      if (Date.now() - t0 > WAKE_GIVE_UP_MS) { w.state = "late"; drawComposer(); return; }
    }
  }

  /* ---------- start ---------- */
  SalaI18n.onChange(() => { if (S.data) { S.nodes = new Map(); draw(); } });
  document.addEventListener("visibilitychange", () => { if (!document.hidden) schedule(0); });
  setInterval(() => { if (!document.hidden) load(); }, POLL_MS);
  load();
})();
