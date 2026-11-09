"use strict";
/* sala-web frontend: session sidebar, chat transcript over SSE, terminal iframe, composer, and the sessions overview
   (#sessions) in the same main area. No build step. laneLabel and modelLabel come from shared.js, overview from
   sessions.js. */

/* ---------- timing (temporary, Wed Oct 14th 2026; README "Timing"; remove with static/timing-debug.js) ----------
   perfMark puts a performance.mark() at each step of a page load (this file starting, the session list requested,
   rendered and painted, a session restored, the stream opened, its reset received, the history rendered and painted,
   a reload and its cause, the service worker's lifecycle). Always on: a mark costs microseconds, stays in the page
   and nothing reads it unless the flag is on. With ?debug=timing opened once in the browser (kept in localStorage, so
   the installed app keeps it; ?debug=off clears it) static/timing-debug.js is loaded, which posts the marks, the
   browser's own navigation and resource timings and its long tasks to api/debug/timing, where the maintainer reads
   them over the unix socket. First in this file, so the recorder still loads when something further down throws;
   errors thrown before it is up are kept for it. Why: a phone showed an empty session list for minutes after
   the update banner's Reload, then a history that took a minute or two, while the server answered in milliseconds. */
const perfMark = (name, detail) => { try { performance.mark(name, detail ? { detail } : undefined); } catch { /* no User Timing */ } };
perfMark("app.js start");
(function timingLoader() {
  const KEY = "sala.debug.timing";
  const want = new URLSearchParams(location.search).get("debug");
  let on = false;
  try {
    if (want === "timing") localStorage.setItem(KEY, "1");
    else if (want === "off") localStorage.removeItem(KEY);
    on = localStorage.getItem(KEY) === "1";
  } catch { /* storage unavailable: stays off */ }
  if (!on) return;
  window.__salaTimingErrors = [];
  const keep = (msg, extra) => { if (window.__salaTimingErrors.length < 50) window.__salaTimingErrors.push({ t: Math.round(performance.now()), msg: String(msg).slice(0, 200), ...extra }); };
  window.addEventListener("error", (e) => keep(e.message || e, { src: String(e.filename || "").slice(-60), line: e.lineno }));
  window.addEventListener("unhandledrejection", (e) => keep((e.reason && e.reason.message) || e.reason, {}));
  const s = document.createElement("script");
  s.src = "static/timing-debug.js?v=" + encodeURIComponent((document.querySelector('meta[name="sala-web-version"]') || {}).content || "");
  s.onload = () => { if (window.salaTiming) window.salaTiming.start({ api: "api/debug/timing" }); };
  document.head.append(s);
})();
/* ---------- end timing loader ---------- */

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

const state = {
  byName: new Map(),
  selected: null,       // session name (kept in the URL hash)
  current: null,        // the selected session object (pid etc.)
  es: null,             // EventSource
  defaultScope: "",     // the scope a new project starts in (api/config)
  scopes: [],           // this box's scopes (api/config) and other, each with its project groups; Unregistered last
  prefs: { scopeOrder: [], groupOrder: [], sessionOrder: [], collapsed: [], laneOrder: [], showAll: false, unreadOnly: false, showTools: false, shellHeight: 300 },  // server-side (api/prefs): follows the owner
  prefsNote: "",
  tab: "chat",
  terminalUrl: "/tty/?arg=",
  shellSession: "sala-shell",   // the Shell drawer's tmux session, from api/config (sala's SALA_SHELL_SESSION)
  host: "",             // this machine's short name, from api/config
  termLoadedFor: null,
  uploads: [],          // {id, name, url, uploading}
  sending: false,
  pending: [],          // sent from this page, not yet seen in the transcript: {id, session, text, images, status, ...}
};

/* ---------- fetch with brief retries (a restart of the server, a Cloudflare origin error) ---------- */
// Only for requests that are safe to repeat (GETs, the prefs PUT, an upload under a new random name); a send is
// never repeated on its own: its pending bubble offers Retry.
const RETRY_STATUS = new Set([502, 503, 504, 520, 521, 522, 523, 524, 530]);
const sleep = (ms) => new Promise((res) => setTimeout(res, ms));
async function apiFetch(url, opts = {}, { tries = 5 } = {}) {
  let delay = 400;
  for (let i = 1; ; i++) {
    try {
      const r = await fetch(url, opts);
      if (!RETRY_STATUS.has(r.status) || i >= tries) return r;
      perfMark("fetch:retry", { url: String(url).slice(0, 40), status: r.status, try: i });
    } catch (e) {
      perfMark("fetch:error", { url: String(url).slice(0, 40), msg: String(e && e.message || e).slice(0, 80), try: i });
      if (i >= tries) throw e;
    }
    await sleep(delay);
    delay = Math.min(delay * 2, 3000);
  }
}

/* ---------- markdown ---------- */
if (window.marked) noSingleTildeStrike(marked);  // only ~~x~~ strikes; a lone ~ is text (shared.js)
if (window.DOMPurify) {
  DOMPurify.addHook("afterSanitizeAttributes", (node) => {
    if (node.tagName === "A") { node.setAttribute("target", "_blank"); node.setAttribute("rel", "noopener noreferrer"); }
  });
}
// A markdown image in a reply that names a file on this machine (![caption](/home/…/mock.png) or ![caption](~/…)): the
// server hands each such image of a text block a URL (b.localImages: {src as written, url}); the image is drawn inline
// there, lazy, tap to open it full size, the caption under it. When the server refuses it or cannot find the file, a
// muted "image not shown: <reason>" takes its place (never a broken-image icon) and the caption stays. A local path the
// server offered no URL for (a reply's text that was cut, a narration line) gets the same line without a request.
const isLocalSrc = (s) => (s.startsWith("/") && !s.startsWith("//")) || s.startsWith("~/");
function localImage(img, url) {
  const caption = (img.getAttribute("alt") || "").trim();
  const box = el("span", { class: "md-local" });
  const note = (why) => {
    box.replaceChildren(el("span", { class: "md-local-missing", text: "image not shown: " + why }));
    if (caption) box.append(el("span", { class: "md-local-cap", text: caption }));
  };
  if (!url) { note("the reply does not name this image"); return box; }
  const pic = el("img", { class: "md-local-img", src: url, alt: caption || "image", loading: "lazy", decoding: "async" });
  box.append(el("a", { href: url, target: "_blank", rel: "noopener", title: "Open the full image" }, pic));
  if (caption) box.append(el("span", { class: "md-local-cap", text: caption }));
  pic.addEventListener("error", async () => {
    let why = "the file could not be loaded";
    try {
      const r = await fetch(url);
      if (!r.ok) why = ((await r.json()).error) || why;
    } catch { /* keep the generic reason */ }
    note(why);
  }, { once: true });
  return box;
}
function localImages(d, offered) {
  const byPath = new Map((offered || []).map((o) => [o.src, o.url]));
  for (const img of d.querySelectorAll("img")) {
    const raw = img.getAttribute("src") || "";
    let src = raw;
    try { src = decodeURI(raw); } catch { /* keep it as marked wrote it */ }  // marked writes the href percent-encoded
    if (!isLocalSrc(src)) continue;
    const box = localImage(img, byPath.get(src) || byPath.get(raw));
    const host = img.closest("a");
    (host && host.parentNode ? host : img).replaceWith(box);
  }
}
function md(text, offered = null) {
  try {
    const html = marked.parse(mdPrep(text), { gfm: true, breaks: true });  // a single newline is a line break, as claude.ai renders it
    const d = el("div", { class: "md" });
    // the sanitized nodes themselves, not their HTML to parse a second time (the same tree; measured as a slice of a
    // long history's render, Wed Oct 14th 2026)
    d.append(DOMPurify.sanitize(html, { RETURN_DOM_FRAGMENT: true }));
    localImages(d, offered);
    // a copy button in the top-right corner of each fenced code block (outside the <pre>, so it does not scroll away)
    for (const p of d.querySelectorAll("pre")) {
      const raw = (p.querySelector("code") || p).textContent.replace(/\n$/, "");  // marked adds one trailing newline
      const box = el("div", { class: "codebox" });
      p.replaceWith(box);
      box.append(p, copyButton(raw, "code-copy"));
    }
    return d;
  } catch {
    return el("div", { class: "md", style: "white-space:pre-wrap", text });
  }
}
// A reply's text: its markdown, and, when the text ends in a footer (splitFooter in shared.js: the "Write-up:", "Board …"
// and "Page …" notes a session leaves last), that footer as a block of its own after the body (.md.footer:
// smaller, dimmed, under a thin rule unless it starts the reply), each note rendered on its own so the notes keep
// their lines, and the closing paragraph a session puts after the footer (its ask), when there is one, as body text
// under it (.md.tail: full size, the text colour, a small gap and no rule). Without a footer the one md()
// node as before; `last` is false for a text block another text block follows, since a footer ends the reply. The
// copy button gets the text itself, so copying is unchanged.
function replyNodes(text, last, offered = null) {
  const { body, notes, tail } = last ? splitFooter(text) : { body: text, notes: [], tail: "" };
  if (!notes.length) return [md(text, offered)];
  const footer = el("div", { class: "md footer" + (body ? " ruled" : "") });
  for (const n of notes) footer.append(...md(n, offered).childNodes);
  const out = body ? [md(body, offered), footer] : [footer];
  if (tail) { const t = md(tail, offered); t.classList.add("tail"); out.push(t); }
  return out;
}
// A footer link broken over two or more lines gets .wrapped, which turns its ::after tap area off (style.css: that box is
// one rectangle from the first line's left edge to the last line's right edge, partial or empty for a wrapped link, so a
// wrapped link keeps its own text box, already a line or more tall, as the target). Reads every link first, then writes,
// so the page lays out once. It runs on each message added to the chat and, since the lines depend on the column's width,
// again whenever the chat's width changes (see the observers by #chat below).
function markWrappedLinks(...roots) {
  const links = roots.flatMap((root) => [...root.querySelectorAll(".md.footer a[href]")]);
  const wrapped = links.map((a) => a.getClientRects().length > 1);
  links.forEach((a, i) => a.classList.toggle("wrapped", wrapped[i]));
}
// Text shown as written (a prompt bubble, a message from another session, a tool result) with its links tappable:
// text nodes and <a> elements from linkTokens (shared.js), never innerHTML. A phone showed
// "[board#N](https://board.example.test/items/N)" as plain text in these.
const linkNodes = (text) => linkTokens(text).map((t) =>
  t.href ? el("a", { href: t.href, target: "_blank", rel: "noopener noreferrer", text: t.text }) : document.createTextNode(t.text));
const linkedPre = (text) => el("pre", {}, ...linkNodes(text));

/* ---------- prefs ---------- */
async function loadPrefs() {
  try {
    const r = await apiFetch("api/prefs", { cache: "no-store" });
    if (r.ok) Object.assign(state.prefs, await r.json());
  } catch { /* defaults */ }
}
async function savePrefs(patch) {
  Object.assign(state.prefs, patch);
  try {
    const r = await apiFetch("api/prefs", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify(patch) });
    const d = await r.json().catch(() => ({}));
    if (!r.ok || !d.ok) throw new Error(d.error || r.statusText);
    state.prefsNote = "";
  } catch (e) {
    state.prefsNote = "Could not save the setting: " + e.message;
  }
  showSideNote();
}
/* A list in the prefs (an order, the folded headers) is saved from what the server holds when it is saved, never from this
   page's copy. The copy is what the page read at load: defaults when the file was missing or the read failed (a service
   restarted onto a new state folder), old when another device has saved since. Writing a list computed from it put the defaults
   (or the old order) over the stored one; a drag of one project's agents rewrote every project's. So: `compute(list)` gives the
   new list from a list (the page's copy first, so the page redraws at once), the server's current list is read, `compute` is
   applied to THAT, and only that key is sent. When the server's list cannot be read nothing is sent (and the setting says so). */
const listSaves = {};
async function saveList(key, compute) {
  state.prefs[key] = compute(state.prefs[key] || []);
  const n = (listSaves[key] = (listSaves[key] || 0) + 1);
  let cur;
  try {
    const r = await apiFetch("api/prefs", { cache: "no-store" });
    const d = await r.json();
    if (!r.ok || !Array.isArray(d[key])) throw new Error(r.statusText || "no such list");
    cur = d[key];
  } catch (e) {
    state.prefsNote = "Could not save the setting: the saved settings could not be read (" + (e && e.message || e) + ").";
    showSideNote();
    return false;
  }
  const next = compute(cur);
  const same = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);
  if (n === listSaves[key] && !same(next, state.prefs[key])) { state.prefs[key] = next; if (key !== "laneOrder") renderSidebar(); }
  if (same(next, cur)) return true;   // the server has it already
  await savePrefs({ [key]: next });
  return true;
}

/* ---------- sidebar ---------- */
let rolesNote = "";
function showSideNote() { $("#side-note").textContent = [rolesNote, state.prefsNote].filter(Boolean).join(" "); }

async function loadSessions() {
  let data;
  perfMark("sessions:request");
  try {
    const r = await apiFetch("api/sessions", { cache: "no-store" });
    data = await r.json();
    perfMark("sessions:response", { status: r.status });
  } catch (e) {
    perfMark("sessions:error", { msg: String(e && e.message || e).slice(0, 120) });
    rolesNote = "Could not load sessions."; showSideNote();
    setConn("api", true);
    return;
  }
  setConn("api", false);
  state.scopes = data.scopes || [];
  migrateSessionOrder();
  state.byName = new Map();
  for (const sc of state.scopes) for (const g of sc.groups) for (const s of g.sessions) state.byName.set(s.name, s);
  rolesNote = data.rolesError ? "Roles unavailable; grouping may be stale." : ""; showSideNote();
  renderSidebar();
  perfMark("sessions:rendered", { count: state.byName.size });
  // a reply that arrived while the owner has this session open (and is looking at the page) is read as it lands
  if (state.selected && !document.hidden) markRead(state.selected);
  // keep the selection in step with the registry (a relaunched session gets a new pid)
  if (state.selected) {
    const s = state.byName.get(state.selected);
    if (s && (!state.current || s.pid !== state.current.pid)) selectSession(state.selected, { force: true });
    else if (s) updateHeader(s);
  }
}

// background agents work out of the owner's sight: hidden unless the toggle is on (or one is selected)
const HIDDEN_ROLES = new Set(["back"]);
const visibleSessions = (g) => {
  const shown = orderedSessions(g).filter((s) => state.prefs.showAll || !HIDDEN_ROLES.has(s.role) || s.name === state.selected);
  return state.prefs.unreadOnly ? unreadKept(shown, state.selected) : shown;   // "Unread only": the Unread entry, below
};

/* ---------- the unread reply count (which replaced the "New" chip) ----------
   A front agent's row carries a filled orange count at its right end: the replies it has written since the owner last opened it.
   Each turn that ended in a reply adds one; a turn still running does not count yet. A folded project or scope header carries
   the total of the sessions inside. Above 9 it reads 9+. The server counts (unread.py: front agents only, from the transcript,
   after the read marker kept in state_dir/read-state.json, so the phone and the desktop agree, at most 10 a session) and
   sends `unread_count` with every session. The open session never shows one: opening it, and any reply that lands while it
   is open and the page is in view, moves its marker up to its latest reply (POST api/read; the server takes the time from the
   transcript). Background agents never get a count (the server sends them 0).

   The Unread entry under Overview shows the total of those counts and, tapped, turns the "Unread only" filter on (tap again: off): the
   list then holds only the agents with an unread reply, under their project and scope headings, plus the open one until the owner
   leaves it. Headings read as open while it is on (the saved fold list is not touched, so the folds come back when it is off), and a
   list with nothing unread says "Nothing unread". Background agents have no count, so they are not in it. The choice is the
   `unreadOnly` pref, kept like "Show all sessions" (one setting for the phone and the desktop). */
const UNREAD_SHOWN_MAX = 9;
const unreadOf = (s) => unreadOfSession(s, state.selected);   // shared.js, which the tests also run in node
const unreadChip = (n, label) => el("span", { class: "ucount", role: "img", "aria-label": label, title: label, text: n > UNREAD_SHOWN_MAX ? UNREAD_SHOWN_MAX + "+" : String(n) });
const unreadLabel = (n, where) => (n > UNREAD_SHOWN_MAX ? `More than ${UNREAD_SHOWN_MAX} unread replies` : plural(n, "unread reply", "unread replies")) + (where ? ` in ${where}` : "");
const marking = new Set();
// `force` is for opening and leaving a session: the local count only reflects the last 10 s poll, so a reply that
// landed since is not in it, and skipping the post would leave that reply counted after the owner read it. The server never
// moves a marker down, so the extra call is harmless. The poll-driven call stays guarded by the count (no post every 10 s).
function markRead(name, { force = false } = {}) {
  const s = name && state.byName.get(name);
  if (!s || (!force && !s.unread) || marking.has(name)) return;
  const was = { unread: !!s.unread, count: s.unread_count };
  s.unread = false; s.unread_count = 0;  // at once, so the count does not wait for the next poll; the server moves the marker
  marking.add(name);
  apiFetch("api/read", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name }) })
    .catch(() => { s.unread = was.unread; s.unread_count = was.count; })   // not saved: the next poll tells the truth
    .finally(() => { marking.delete(name); renderSidebar(); });
}

// the Unread entry (index.html #side-unread): the total of the counts, and whether the filter is on; renderSidebar draws it, and every change of a count passes through that
function paintUnreadEntry() {
  const b = $("#side-unread"), on = !!state.prefs.unreadOnly;
  b.classList.toggle("selected", on);
  b.setAttribute("aria-pressed", String(on));
  b.querySelector(".label").textContent = on ? "Unread only" : "Unread";
  b.title = on ? "Showing only agents with unread replies: tap to show all" : "Show only agents with unread replies";
  const n = unreadTotal(liveSessions(), state.selected), old = b.querySelector(".ucount");
  if (old) old.remove();
  if (n) b.append(unreadChip(n, unreadLabel(n, "all agents")));
}
$("#side-unread").addEventListener("click", () => { savePrefs({ unreadOnly: !state.prefs.unreadOnly }); renderSidebar(); });

// the saved order first; entries not in it keep the server's order after them (so Unregistered stays last unless moved)
function inOrder(items, saved, keyOf = (x) => x.key) {
  const idx = new Map((saved || []).map((k, i) => [k, i]));
  const listed = items.filter((x) => idx.has(keyOf(x))).sort((a, b) => idx.get(keyOf(a)) - idx.get(keyOf(b)));
  return [...listed, ...items.filter((x) => !idx.has(keyOf(x)))];
}
// the sessions of one project in the owner's saved order (api/prefs sessionOrder, a flat list): a session not in it (new, or never
// moved) follows the saved ones in the order the server gave; keys not live now are ignored. A session is keyed by sala's
// permanent id for the agent (agentId: it outlives a rename, a recycle and a /clear), and by its name when it has none (a run
// sala keeps no record of). Lists saved before the ids hold names: migrateSessionOrder turns them into ids on the first load.
const sessKey = (s) => s.agentId || s.name;
const orderedSessions = (g) => inOrder(g.sessions, state.prefs.sessionOrder, sessKey);
const liveSessions = () => state.scopes.flatMap((sc) => sc.groups.flatMap((g) => g.sessions));
// a list saved by names read as ids: an old entry is the agent that has the name now, else had it (a rename); a name nothing live
// matches stays as it was
function sessionOrderAsIds(saved) {
  const all = liveSessions();
  const live = new Set(all.map(sessKey));
  const byName = new Map();
  for (const s of all) if (s.agentId) byName.set(s.name, s.agentId);
  const names = new Set(all.map((s) => s.name));
  for (const s of all) for (const a of s.aliases || []) if (s.agentId && !names.has(a) && !byName.has(a)) byName.set(a, s.agentId);
  return [...new Set(saved.map((k) => (live.has(k) ? k : byName.get(k) || k)))];
}
let migratingOrder = false;
async function migrateSessionOrder() {   // once: from here the list holds ids
  const saved = state.prefs.sessionOrder || [];
  const out = sessionOrderAsIds(saved);
  if (migratingOrder || (out.length === saved.length && out.every((k, i) => k === saved[i]))) return;
  migratingOrder = true;
  try { await saveList("sessionOrder", sessionOrderAsIds); } finally { migratingOrder = false; }
}
// the list after a drag inside one project: only that project's agents are written (the visible ones, in their new order, take the
// visible slots, hidden ones keep theirs); every other entry stays as the list had it. Entries of agents that ended are kept (a
// returning one finds its place) but at most 100, and never at the cost of a live one or past the 500 the server takes
function sessionOrderWith(cur, g, visibleNew) {
  const base = inOrder(g.sessions, cur, sessKey).map(sessKey);
  const inGroup = new Set(base);
  const vis = visibleNew.filter((k) => inGroup.has(k));
  const visSet = new Set(vis);
  let i = 0;
  const grp = base.map((k) => (visSet.has(k) ? vis[i++] : k));
  const rest = cur.filter((k) => !inGroup.has(k));
  const live = new Set(liveSessions().map(sessKey));
  let extra = Math.max(rest.length + grp.length - 500, rest.filter((k) => !live.has(k)).length - 100, 0);
  for (let j = rest.length - 1; j >= 0 && extra > 0; j--) if (!live.has(rest[j])) { rest.splice(j, 1); extra--; }
  return [...rest, ...grp];
}
const orderedScopes = () => inOrder(state.scopes, state.prefs.scopeOrder);
const orderedGroups = (sc) => inOrder(sc.groups, state.prefs.groupOrder);
const isCollapsed = (k) => (state.prefs.collapsed || []).includes(k);
const isFolded = (k) => !state.prefs.unreadOnly && isCollapsed(k);   // while the filter is on every heading reads as open
function toggleCollapsed(k) {
  if (state.prefs.unreadOnly) return;   // a fold now would change the saved list with nothing to show for it
  saveList("collapsed", (cur) => (cur.includes(k) ? cur.filter((x) => x !== k) : [...cur, k]));
  renderSidebar();
}

// a drawn chevron (a text glyph like ⌄ sits on the baseline and never centres): points right when folded, down when open
function chevron(collapsed) {
  const ns = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(ns, "svg");
  svg.setAttribute("viewBox", "0 0 16 16"); svg.setAttribute("class", "chev" + (collapsed ? " folded" : "")); svg.setAttribute("aria-hidden", "true");
  const p = document.createElementNS(ns, "path");
  p.setAttribute("d", "M4 6l4 4 4-4"); p.setAttribute("fill", "none"); p.setAttribute("stroke", "currentColor");
  p.setAttribute("stroke-width", "1.6"); p.setAttribute("stroke-linecap", "round"); p.setAttribute("stroke-linejoin", "round");
  svg.append(p);
  return svg;
}

// a scope or project header: click (no movement) collapses, drag reorders; a collapsed one shows a busy dot
function header(cls, ckey, title, tip, collapsed, sessions) {
  const busy = collapsed && sessions.some((s) => s.status === "busy");
  const sel = collapsed && sessions.some((s) => s.name === state.selected);
  const h = el("div", { class: cls + (sel ? " has-selected" : ""), title: tip + (state.prefs.unreadOnly ? " (open while only unread agents show; drag to reorder)" : " (click to fold, drag to reorder)"),
                        role: "button", tabindex: "0", "aria-expanded": String(!collapsed), "data-ckey": ckey },
    el("span", { class: "t", text: title }),
    chevron(collapsed),  // right after the label, like claude.ai
    busy ? el("span", { class: "dot busy", title: "A session in here is busy" }) : null,
    collapsed ? (() => { const n = sessions.reduce((t, x) => t + unreadOf(x), 0); return n ? unreadChip(n, unreadLabel(n, title)) : null; })() : null,
    el("span", { class: "handle", "aria-hidden": "true", text: "⋮⋮" }));
  h.addEventListener("pointerdown", (e) => dragStart(e, h));
  // on touch there is no drag (a swipe scrolls the list), so a tap folds through click, which a scroll never fires
  h.addEventListener("click", () => { if (h.dataset.tap) { delete h.dataset.tap; toggleCollapsed(ckey); } });
  h.addEventListener("keydown", (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); toggleCollapsed(ckey); } });
  return h;
}
function sessRow(s) {
  // a real link, so Ctrl/Cmd/middle-click and "open in new tab" work; a plain click just follows the hash
  return el("a", {
    class: "sess" + (s.name === state.selected ? " selected" : ""),
    href: "#s=" + encodeURIComponent(s.name),
    title: `${s.name} · ${s.status}${s.role ? " · " + s.role : ""}${s.parkedJob ? " · in background job " + s.parkedJob : ""}`,
    "data-key": s.name, "data-okey": sessKey(s), draggable: "false",
    onclick: (e) => { if (!(e.ctrlKey || e.metaKey || e.shiftKey || e.button !== 0)) setDrawer(false); },  // hidden now; its history entry goes with the navigation (go)
    // a press that moves reorders it within its project; one that does not is the link's click
    onpointerdown: (e) => dragStart(e, e.currentTarget),
  }, el("span", { class: "dot " + dotClass(s.status) }), el("span", { class: "label", text: s.name }),
     s.role && s.role !== "front" ? el("span", { class: "role", text: s.role }) : null,
     rowMenuBtn(s), (() => { const n = unreadOf(s); return n ? unreadChip(n, unreadLabel(n, s.name)) : null; })());  // the ⋯ sits left of the count: the count stays at the row's far right, hovered or not
}

/* ---------- a session row's ⋯ menu (Fork lives here, not in the header, whose fold is measured to the pixel) ----------
   The ⋯ at the end of a row, left of the item count (on hover or focus, and always on the open session's row; on a touch screen only there, since
   nothing hovers) opens a small menu under it. Its one entry now is Fork: a link to #side=from:<name>, which opens the Quick
   session form with the fork of that session filled in (the same form and queue as the deep link; nothing is started until
   Start quick session is pressed there). A row gets the ⋯ only when something can be done with it: a fork continues the
   conversation of a live claude (lib/spawn.sh side_origin: a tmux session with one in it), so a session with no tmux pane (the
   sdk lane's, which has no transcript to continue) has none. A quick session itself can be forked, as lib/spawn.sh allows
   (the new name is cut at the earlier -side-). */
const canFork = (s) => !!(s && s.tmuxSession && s.lane !== "sdk");
const rowMenuItems = (s) => [canFork(s) ? { label: "Fork", hint: "A quick session that continues this session's conversation", href: "#side=from:" + s.name } : null].filter(Boolean);
let rowMenu = null;  // {name, node}
function rowMenuBtn(s) {
  if (!rowMenuItems(s).length) return null;
  const b = el("span", { class: "sess-more", role: "button", tabindex: "0", "aria-haspopup": "menu", "aria-expanded": String(!!rowMenu && rowMenu.name === s.name),
                         "aria-label": `Actions for ${s.name}`, title: "Fork this session…", text: "⋯" });
  const open_ = (e) => { e.preventDefault(); e.stopPropagation(); if (rowMenu && rowMenu.name === s.name) closeRowMenu(true); else openRowMenu(s, b, e.type === "keydown"); };
  b.addEventListener("pointerdown", (e) => e.stopPropagation());  // not the start of a drag-reorder
  b.addEventListener("click", open_);
  b.addEventListener("keydown", (e) => { if (e.key === "Enter" || e.key === " " || e.key === "ArrowDown") open_(e); });
  return b;
}
function closeRowMenu(refocus) {
  if (!rowMenu) return;
  const { name, node } = rowMenu;
  rowMenu = null;
  node.remove();
  document.removeEventListener("pointerdown", rowMenuOutside, true);
  document.removeEventListener("keydown", rowMenuKey, true);
  window.removeEventListener("resize", closeRowMenu);
  $("#session-list").removeEventListener("scroll", closeRowMenu);
  const b = rowButton(name);
  // the focus goes back first: while its menu is open the button is shown, and a hidden button cannot take focus
  if (b) { if (refocus === true) b.focus({ preventScroll: true }); b.setAttribute("aria-expanded", "false"); }
}
const rowButton = (name) => [...document.querySelectorAll("#session-list .sess")].find((r) => r.dataset.key === name)?.querySelector(".sess-more") || null;
const rowMenuOutside = (e) => { if (rowMenu && !rowMenu.node.contains(e.target) && !e.target.closest?.(".sess-more")) closeRowMenu(); };
function rowMenuKey(e) {
  if (!rowMenu) return;
  const items = [...rowMenu.node.querySelectorAll("[role=menuitem]")], i = items.indexOf(document.activeElement);
  if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); closeRowMenu(true); }
  else if (e.key === "ArrowDown") { e.preventDefault(); items[(i + 1) % items.length].focus(); }
  else if (e.key === "ArrowUp") { e.preventDefault(); items[(i - 1 + items.length) % items.length].focus(); }
  else if (e.key === "Tab") closeRowMenu();
}
function openRowMenu(s, btn, byKey) {
  closeRowMenu();
  const node = el("div", { class: "row-menu", role: "menu", "aria-label": `Actions for ${s.name}` },
    ...rowMenuItems(s).map((it) => el("a", { class: "row-menu-item", role: "menuitem", href: it.href, title: it.hint,
      onclick: () => { closeRowMenu(); setDrawer(false); } }, el("span", { text: it.label }), el("span", { class: "hint", text: it.hint }))));
  document.body.append(node);
  rowMenu = { name: s.name, node };
  btn.setAttribute("aria-expanded", "true");
  const r = btn.getBoundingClientRect(), w = node.getBoundingClientRect();
  node.style.top = Math.min(r.bottom + 4, innerHeight - w.height - 8) + "px";
  node.style.left = Math.max(8, Math.min(r.right - w.width, innerWidth - w.width - 8)) + "px";
  document.addEventListener("pointerdown", rowMenuOutside, true);
  document.addEventListener("keydown", rowMenuKey, true);
  window.addEventListener("resize", closeRowMenu);
  $("#session-list").addEventListener("scroll", closeRowMenu);
  if (byKey) node.querySelector("[role=menuitem]").focus();
}

let sidebarDirty = false;
function renderSidebar() {
  if (drag) { sidebarDirty = true; return; }  // never redraw under a drag; the drop redraws
  sidebarDirty = false;
  const nav = $("#session-list");
  const keepTop = nav.scrollTop;
  nav.replaceChildren();
  for (const sc of orderedScopes()) {
    const groups = orderedGroups(sc).map((g) => ({ g, shown: visibleSessions(g) })).filter((x) => x.shown.length);
    if (!groups.length) continue;
    const sKey = "scope:" + sc.key;
    const folded = isFolded(sKey);
    const all = groups.flatMap((x) => x.shown);
    const body = el("div", { class: "scope-body" });
    if (folded) {
      const sel = all.find((s) => s.name === state.selected);  // a folded scope still shows the open session
      if (sel) body.append(sessRow(sel));
    } else if (sc.flat) {
      for (const s of groups[0].shown) body.append(sessRow(s));
    } else {
      for (const { g, shown } of groups) {
        const c = isFolded(g.key);
        const box = el("div", { class: "group", "data-key": g.key }, header("group-title", g.key, g.title, g.key, c, shown));
        for (const s of c ? shown.filter((x) => x.name === state.selected) : shown) box.append(sessRow(s));
        body.append(box);
      }
    }
    nav.append(el("div", { class: "scope" + (sc.flat ? " flat" : ""), "data-key": sc.key },
      header("scope-title", sKey, sc.title, sc.flat ? "Sessions with no project" : "Scope: " + sc.key, folded, all), body));
  }
  // the filter on and nothing unread (the open agent, if any, is the one row above): the line says so
  if (state.prefs.unreadOnly && !unreadTotal(liveSessions(), state.selected)) nav.append(el("div", { class: "empty", role: "status", text: "Nothing unread" }));
  else if (!nav.children.length) nav.append(el("div", { class: "empty", text: "No live sessions." }));
  nav.scrollTop = keepTop;
  paintUnreadEntry();
  if (rowMenu && !rowButton(rowMenu.name)) closeRowMenu();  // its session is gone (or folded away): the menu goes with it
  if (!listPainted) {  // the first paint of the list: after the next frame has been drawn (timing, above)
    listPainted = true;
    requestAnimationFrame(() => requestAnimationFrame(() => perfMark("sessions:painted", { count: state.byName.size })));
  }
}
let listPainted = false;
const dotClass = (st) => (["busy", "idle", "shell", "waiting"].includes(st) ? st : "");

/* ---------- drag-reorder of scopes and of projects within their scope (pointer events: mouse and touch) ---------- */
// The dragged item follows the pointer by a transform and a line marks where it will land; the DOM changes only on
// drop, because moving the captured element mid-drag would drop the pointer capture. A press without movement is a
// click, which folds or unfolds the header instead.
let drag = null;  // {head, box, list, sel, level, nav, id, y0, y, scroll0, line, before, started}
const DRAG_THRESHOLD = 5;

function dragStart(e, head) {
  const isSess = head.classList.contains("sess");
  if (e.pointerType === "touch") { if (!isSess) head.dataset.tap = "1"; return; }  // reorder with a mouse or pen only (a touch on a session is just its link)
  if (drag || (e.pointerType === "mouse" && e.button !== 0)) return;
  const nav = $("#session-list");
  const level = isSess ? "session" : head.classList.contains("scope-title") ? "scope" : "group";
  // a session row is its own box, inside its project's group, and only that group's rows are its siblings: no drop elsewhere
  const box = isSess ? head : head.parentElement;
  drag = { head, box, list: box.parentElement, sel: level === "scope" ? ".scope" : level === "group" ? ".group" : ".sess", level, nav,
           id: e.pointerId, y0: e.clientY, y: e.clientY, scroll0: nav.scrollTop, line: null, before: undefined, started: false };
  try { head.setPointerCapture(e.pointerId); } catch { /* pointer already gone */ }
  head.addEventListener("pointermove", dragMove);
  head.addEventListener("pointerup", dragEnd);
  head.addEventListener("pointercancel", dragCancel);
  head.addEventListener("lostpointercapture", dragCancel);
}
function dragMove(e) {
  if (!drag || e.pointerId !== drag.id) return;
  drag.y = e.clientY;
  if (!drag.started) {
    if (Math.abs(drag.y - drag.y0) < DRAG_THRESHOLD) return;  // a tap or click stays a tap
    drag.started = true;
    drag.box.classList.add("dragging");
    document.body.classList.add("reordering");
    drag.line = el("div", { class: "drop-line", "aria-hidden": "true" });
    const nr = drag.nav.getBoundingClientRect();
    drag.line.style.left = Math.max(8, drag.list.getBoundingClientRect().left - nr.left) + "px";
    drag.nav.append(drag.line);
    requestAnimationFrame(dragTick);
  }
  e.preventDefault();
  dragPlace();
}
const siblingsOf = (d) => [...d.list.querySelectorAll(`:scope > ${d.sel}`)];
const nextItem = (d) => { const xs = siblingsOf(d); return xs[xs.indexOf(d.box) + 1] || null; };
function dragPlace() {
  const d = drag;
  d.box.style.transform = `translateY(${d.y - d.y0 + d.nav.scrollTop - d.scroll0}px)`;
  const others = siblingsOf(d).filter((g) => g !== d.box);
  const before = others.find((g) => { const r = g.getBoundingClientRect(); return d.y < r.top + r.height / 2; }) || null;
  d.before = before;
  const moved = before !== nextItem(d);
  d.line.hidden = !moved;
  if (moved) {
    const nr = d.nav.getBoundingClientRect();
    const last = others[others.length - 1];
    const at = before ? before.getBoundingClientRect().top - 4 : (last ? last.getBoundingClientRect().bottom + 2 : nr.top);
    d.line.style.top = (at - nr.top + d.nav.scrollTop) + "px";
  }
}
function dragTick() {  // scroll the list while the pointer is near its top or bottom edge
  if (!drag || !drag.started) return;
  const r = drag.nav.getBoundingClientRect();
  const edge = 36;
  const v = drag.y < r.top + edge ? -Math.ceil((r.top + edge - drag.y) / 4) : drag.y > r.bottom - edge ? Math.ceil((drag.y - r.bottom + edge) / 4) : 0;
  if (v) { drag.nav.scrollTop += v; dragPlace(); }
  requestAnimationFrame(dragTick);
}
function dragFinish() {
  const d = drag;
  drag = null;
  d.head.removeEventListener("pointermove", dragMove);
  d.head.removeEventListener("pointerup", dragEnd);
  d.head.removeEventListener("pointercancel", dragCancel);
  d.head.removeEventListener("lostpointercapture", dragCancel);
  try { d.head.releasePointerCapture(d.id); } catch { /* released */ }
  d.box.classList.remove("dragging");
  d.box.style.transform = "";
  if (d.line) d.line.remove();
  document.body.classList.remove("reordering");
  return d;
}
function dragEnd(e) {
  if (!drag || e.pointerId !== drag.id) return;
  const d = dragFinish();
  if (!d.started) { if (d.level !== "session") toggleCollapsed(d.head.dataset.ckey); return; }  // a press on a session that never moved is its link's click
  if (d.level === "session") {  // the row was dragged: the click that follows the release must not open it
    const swallow = (ev) => { ev.preventDefault(); ev.stopPropagation(); };
    window.addEventListener("click", swallow, { capture: true, once: true });
    setTimeout(() => window.removeEventListener("click", swallow, { capture: true }), 100);
  }
  if (d.before !== undefined && d.before !== nextItem(d)) {
    d.list.insertBefore(d.box, d.before);
    const keys = siblingsOf(d).map((x) => (d.level === "session" ? x.dataset.okey : x.dataset.key));
    if (d.level === "scope") {
      saveList("scopeOrder", (cur) => mergeOrder(keys, inOrder(state.scopes, cur).map((x) => x.key), cur));
    } else if (d.level === "session") {
      const name = d.box.dataset.key;
      const g = state.scopes.flatMap((sc) => sc.groups).find((x) => x.sessions.some((s) => s.name === name));
      if (g) saveList("sessionOrder", (cur) => sessionOrderWith(cur, g, keys));
    } else {
      saveList("groupOrder", (cur) => mergeOrder(keys, orderedScopes().flatMap((sc) => inOrder(sc.groups, cur).map((g) => g.key)), cur));
    }
  }
  renderSidebar();
}
function dragCancel(e) {
  if (!drag || (e.pointerId != null && e.pointerId !== drag.id)) return;
  dragFinish();
  renderSidebar();  // put everything back where the saved order says
}
// The new full order: the moved visible entries take the visible entries' slots, everything else (hidden groups,
// other scopes' projects) keeps its slot, and saved entries that are gone now stay after the entry they followed
// (they may come back).
function mergeOrder(visibleNew, full, saved, maxStale = Infinity) {
  const vis = visibleNew.filter((k) => full.includes(k));
  const visSet = new Set(vis);
  let i = 0;
  const order = full.map((k) => (visSet.has(k) ? vis[i++] : k));
  const present = new Set(order);
  const after = new Map();
  let prev = null;
  for (const k of saved || []) {
    if (present.has(k)) prev = k;
    else { if (!after.has(prev)) after.set(prev, []); after.get(prev).push(k); }
  }
  const out = [...(after.get(null) || [])];
  for (const k of order) out.push(k, ...(after.get(k) || []));
  // names that are no longer live are kept so a returning one finds its place, but they never push a live one out: more than
  // maxStale of them, or more entries than the server takes (500), and the stale ones go first, from the end
  const live = new Set(full);
  let extra = Math.max(out.length - 500, out.filter((k) => !live.has(k)).length - maxStale, 0);
  for (let i = out.length - 1; i >= 0 && extra > 0; i--) if (!live.has(out[i])) { out.splice(i, 1); extra--; }
  return out.slice(0, 500);
}

// the tab title is the app's ("sala"): re-assert it if anything (e.g. the framed
// terminal) changes it
let wantTitle = "sala";
function setTitle(t) { wantTitle = t; document.title = t; }
new MutationObserver(() => { if (document.title !== wantTitle) document.title = wantTitle; })
  .observe(document.querySelector("title"), { childList: true, characterData: true, subtree: true });

/* ---------- header: the name first, the rest folds into the ⋯ menu ----------
   The title bar holds the session name, centred in the bar, and, in one cluster at its right end (#top-end,
   "lighter view"), the status badge (#top-status: working / needs input), Reload as an icon and the ⋯
   button. Role, lane and the tmux name (the session's static facts) and Chat / Terminal are in the ⋯ menu (#top-tools),
   always: the "Session" section (#top-session) and the "View" section (the switch, then the thinking toggle). The bar is a
   grid with two equal side tracks, each at least the cluster's width (and the toggle's room at the left), so the name is
   centred on the bar's full width (on a phone as well) and has what is left between the tracks; it is
   cut with an ellipsis, never moved, when it does not fit. nameFits() below measures that layout as it is.
   The name is the one thing that never gives way while anything else is still in the bar (on a desktop window of ~1000 px
   the name matters more than the icons, which fold into the menu as on a phone). So nothing is
   decided by a breakpoint: on every resize of the header, and whenever the name, the badge or the fonts change, everything
   goes back into the bar, and items leave it for the ⋯ menu in FOLD order, one at a time, until the name has its full
   width. FOLD: the Shell button first, then Reload
   (on a desktop the browser has its own; the item is there for the installed app), then the status badge, last because it is
   the dynamic fact worth seeing (it is also the dot beside the name and the row in the sidebar). The elements move (one Shell button, one Reload, one status badge), so their listeners go with them, and a folded
   Shell is the same button: the same click handler and the same aria-expanded, which setShell keeps. A folded Shell and
   Reload become rows with their word, the badge a row of the Session section. Where the menu is not there (the Overview and the
   New session page hide the ⋯ button and its menu) the Shell button stays in the bar: a button folded into a hidden menu would be
   out of reach. */
const titleBar = { name: $("#title .name"), status: $("#top-status"), session: $("#top-session"), reload: $("#menu-reload"), shell: $("#shell-btn") };
const FOLD = [titleBar.shell, titleBar.reload, titleBar.status];  // the tabs and the thinking toggle are not in it: always in the menu
let headerFolded = 0;  // how many of FOLD are in the menu (tests read it)
// the name's full width against the width the bar leaves it: a flex: none probe for the former (one layout), so the
// answer is exact where scrollWidth and clientWidth, both rounded, would miss an overflow under a pixel
function nameFits() {
  // the side tracks of the title grid are equal (style.css #title): each is at least the cluster's width, so the name is
  // centred on the bar and has what is left between them. The cluster is measured at its own width (--cl cleared first)
  const title = $("#title");
  title.style.setProperty("--cl", "0px");
  title.style.setProperty("--cl", $("#top-end").getBoundingClientRect().width + "px");
  const n = titleBar.name;
  let want;
  n.style.flex = "none";
  try { want = n.getBoundingClientRect().width; } finally { n.style.flex = ""; }
  // under 400 px the name is left-aligned and has more room than the centred one (style.css), but the fold keeps
  // its decisions: it is measured on the centred grid (`fold-centred`, set and cleared inside this call, so nothing is painted
  // with it), and the same items stay in the bar as before; the name's extra room is not given back to Shell, Reload or the badge.
  // The class comes off in a finally: a measure that threw with it on would leave the bar on the centred grid, the name centred
  // and cut, until the next layout
  title.classList.add("fold-centred");
  try { return n.getBoundingClientRect().width >= want - 0.01; } finally { title.classList.remove("fold-centred"); }
}
function layoutHeader() {
  const end = $("#top-end"), menu = $("#top-tools"), btn = $("#top-menu-btn");
  // everything back into the bar first (no paint happens in between), then fold until the name fits; the ⋯ button is
  // always in the bar and takes its room before the fold is measured
  // a node is moved only when it is not already where it belongs: re-parenting a node blurs it, so a focused Shell button
  // (or Reload) in the bar would lose its focus on every layout; one that did get moved (folded and put back) gets it back
  const focused = document.activeElement;
  const place = (node, before) => { if (node.parentNode !== end || node.nextSibling !== before) end.insertBefore(node, before); };
  place(titleBar.shell, btn);   // its place in the markup: after Reload, before the ⋯ button (style.css draws it after the button)
  place(titleBar.reload, titleBar.shell);
  place(titleBar.status, titleBar.reload);
  headerFolded = 0;
  const menuGone = getComputedStyle(btn).display === "none";   // the Overview and the New session page have no ⋯ menu
  if (!nameFits()) {
    for (const el of FOLD) {
      if (el === titleBar.shell && menuGone) continue;
      (el === titleBar.status ? titleBar.session : menu).append(el);
      headerFolded++;
      if (nameFits()) break;
    }
  }
  if (focused && focused !== document.body && document.activeElement !== focused && FOLD.includes(focused)) {
    try { focused.focus({ preventScroll: true }); } catch { /* not focusable where it is now (a closed menu) */ }
  }
}
new ResizeObserver(layoutHeader).observe($("#top"));  // also fires once on observe: the first layout
new ResizeObserver(layoutHeader).observe($("#top-end"));  // the cluster grew or shrank (the badge changed): the side tracks follow
if (document.fonts) { document.fonts.ready.then(layoutHeader); document.fonts.addEventListener("loadingdone", layoutHeader); }  // a web font changes the widths

// the header's badges are empty where no session is open (the overview, the new-session page, nothing chosen)
function clearHeaderBadges() { titleBar.status.textContent = ""; titleBar.session.querySelectorAll(".srow").forEach((r) => r.remove()); }
// one row of the menu's Session section: the word, then the badge in its colours
function sessionRow(label, pill) { return el("div", { class: "srow" }, el("span", { class: "k", text: label }), pill); }

function updateHeader(s) {
  state.current = s;
  $("#title .dot").className = "dot " + dotClass(s.status);
  $("#title .dot").title = s.status || "";
  $("#title .name").textContent = s.name;
  // the bar keeps the dynamic badge only (working / needs input); the menu's Session section has the static facts: its
  // role, its lane, and the tmux name only when it differs (the session name already says scope and project). The status
  // badge may sit in that section's row list (folded), so the rows are replaced, not the whole list
  titleBar.status.replaceChildren(...[
    s.status === "busy" ? el("span", { class: "pill busy", text: "working" }) : null,
    s.status === "waiting" ? el("span", { class: "pill waiting", text: "needs input" }) : null].filter(Boolean));  // replaceChildren(null) would print "null"
  titleBar.session.querySelectorAll(".srow").forEach((r) => r.remove());
  titleBar.session.prepend(...[
    s.role ? sessionRow("Role", el("span", { class: "pill role-" + s.role, text: s.role })) : null,
    s.lane ? sessionRow("Lane", el("span", { class: "pill lane-" + laneNorm(s.lane), title: "the account this session runs on (sala lane)", text: laneLabel(s.lane) })) : null,
    s.tmuxSession && s.tmuxSession !== s.name ? sessionRow("tmux", el("span", { class: "pill mono", title: "tmux session", text: s.tmuxSession })) : null].filter(Boolean));
  setTitle(s.name);
  layoutHeader();
  updateInflight();
}
// in flight: a small spinner under the last message while the session works, as claude.ai shows
function updateInflight() {
  const chat = $("#chat");
  let n = chat.querySelector(":scope > .inflight");
  if (!(state.current && state.current.status === "busy") || ahead.active) { if (n) n.remove(); return; }   // far back: it shows at the live end
  if (!n) n = el("div", { class: "inflight", role: "status", title: "Working", "aria-label": "Working" }, el("span", { class: "spinner" }));
  if (chat.lastElementChild !== n) chat.append(n);
}

/* ---------- board items ----------
   Each live session's open stackshot items, from api/board-items: the server reads stackshot's client API at most one
   round a minute for the live sessions and answers at once from its cache, so a poll here costs it nothing. The page
   draws nothing of them in a session or on the Overview (the title bar's item count button, the items sheet and the
   Agents table's red count were removed Thu Nov 5th 2026); they are kept for one reader, the New session page's board
   item picker (sdItemRows, "new session" below), which lists the open items of the live sessions from `board.sessions`.
   Polled every 60 s while the page is visible, once on load and when it comes back into view; a failed poll changes
   nothing, so a board that is away leaves the last list in place. */
const BOARD_MS = 60000;
const BOARD_FOLLOW_MS = 1500;  // the server's first answer after a start is a placeholder while it reads: ask again soon,
const BOARD_FOLLOW_MAX = 10;   // a few times
const board = { sessions: {}, fetchedAt: null, error: null, pending: true, loaded: false, lastAt: 0, follow: 0 };
async function loadBoard() {
  board.lastAt = Date.now();
  let d;
  try {
    const r = await fetch("api/board-items", { cache: "no-store" });
    if (!r.ok) throw new Error("HTTP " + r.status);
    d = await r.json();
  } catch { return; }  // what is kept stays; the next poll asks again
  if (d.sessions && typeof d.sessions === "object") board.sessions = d.sessions;
  board.fetchedAt = d.fetchedAt || null;
  board.error = d.error || null;
  board.pending = !!d.pending;
  board.loaded = true;
  if (d.refreshing && d.pending && board.follow++ < BOARD_FOLLOW_MAX) setTimeout(loadBoard, BOARD_FOLLOW_MS);
  else if (!d.refreshing) board.follow = 0;
}
const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;

// A popover a mouse opens by hovering its trigger (after IN ms) and closes OUT ms after the pointer has left both the trigger
// and the popover; a click on the trigger while it is open that way pins it (it stays after the pointer leaves), and a second
// click, Escape or a click outside closes it. Touch and pen get none of it: a tap toggles as before. `els` are the selectors
// of the trigger and the popover, `open`/`close` the page's own; every open and close calls reset(), so what opens it any other
// way is a pin. `cls` is a body class while it is open by hover alone (a stylesheet may let the pointer through a scrim then).
// A close with the pointer left on the trigger (the second click, which lands on the scrim over it) must not open it again when
// the browser re-checks what is under the pointer: `still` holds hover off until the pointer has left the trigger
const HOVER_IN_MS = 150, HOVER_OUT_MS = 300;   // out: long enough to cross the gap between the trigger and the popover
const mouseAt = { x: -1, y: -1 };
for (const t of ["pointermove", "pointerdown"]) document.addEventListener(t, (e) => { if (e.pointerType === "mouse") { mouseAt.x = e.clientX; mouseAt.y = e.clientY; } }, true);
function hoverPin(els, isOpen, open, close, cls) {
  const h = { on: false, timer: 0, still: false };
  h.set = (on) => { h.on = on; document.body.classList.toggle(cls, on); };
  h.reset = () => {
    clearTimeout(h.timer);
    h.set(false);
    const r = $(els[0]).getBoundingClientRect();
    h.still = mouseAt.x >= r.left && mouseAt.x <= r.right && mouseAt.y >= r.top && mouseAt.y <= r.bottom;
  };
  h.pin = () => { if (!h.on) return false; h.reset(); return true; };
  const enter = (e) => {
    clearTimeout(h.timer);   // a pending close is off
    if (e.pointerType !== "mouse" || isOpen() || h.still) return;
    h.timer = setTimeout(() => { open(); h.set(true); }, HOVER_IN_MS);
  };
  const leave = (e) => {
    if (e.pointerType !== "mouse") return;
    h.still = false;
    clearTimeout(h.timer);   // a pending open is off
    if (h.on) h.timer = setTimeout(close, HOVER_OUT_MS);
  };
  for (const sel of els) { $(sel).addEventListener("pointerenter", enter); $(sel).addEventListener("pointerleave", leave); }
  return h;
}
/* ---------- new session (the project step rebuilt Sat Oct 24th 2026) ----------
   The one way this page makes a session, and it makes none itself: the form queues `sala op spawn` through POST
   api/spawn (the server runs it as an argv list, the mandate as a file, with the owner's words on the marker), then shows
   what the queue answered. Queued: the op id, then the link to the session once it is in the list (sala's marker through
   api/spawn/status and the sessions list, asked every few seconds for up to four minutes; nothing here blocks the page,
   and the sheet can be closed and reopened meanwhile). Anything else: the queue's own words, as text (textContent; never
   innerHTML).
   The project step is a scope (api/config names them: sala's SALA_SCOPES, else stackshot's list) and ONE box: the scope's listed projects, which
   typing filters here (key, name or title holds the text); with text typed, the scope's hidden pages that match come from
   stackshot (api/spawn/projects?q=) under a divider, "existing pages, not listed" (only `type: project` pages are here: the
   server drops every other row); and last "+ New project <typed>". Nothing is asked of the owner beyond the scope, the project, the
   agent's name, role and mandate, and Create. Create does the rest in order, one step shown at a time and each skipped when
   it is not needed or was done already (a retry after a failure goes on from the failed step): a new project is made first
   (api/spawn/project; its gbrain page can take minutes, so the server runs it as a job this page asks about every two
   seconds for up to five and a half; the button stays disabled meanwhile, so it is never sent twice), a hidden one is
   listed again (api/spawn/project-list), the agent is added to the project (api/spawn/project-agent) unless the project
   lists the name already, and then the session is queued (api/spawn). The lines the project's page still owes for the
   agent stay with stackshot's record (page_owed); nothing of them is the owner's to copy. The mandate is a plain textarea and
   no key of it is intercepted, so a Korean IME's Enter and Tab are the browser's; it is required for a back agent (nobody
   briefs a background agent) and optional for a front one. Lane, model and effort fold away; empty = the session follows
   the settings, and an empty one is not sent. One create in flight at a time: the button is disabled until it ends. */
const NS_NAME_RE = /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/;   // sala's agent_name_ok; the length cap comes with the options
const NS_MODEL_RE = /^[A-Za-z0-9._-]*$/;                  // spawn's --model check
// (the poll interval, the 30-minute cap and the verdict of one look are shared.js: NS_POLL_MS, NS_POLL_MAX_MS, nsVerdict)
const NS_OPTIONS_MS = 60000;                              // the options and the project lists are read again after this long
const NS_JOB_POLL_MS = 2000, NS_JOB_MAX_MS = 330000;      // a new project's page: stackshot waits 300 s for gbrain
const NS_RECORD_WAITS = [4000, 4000, 6000];               // waits before the spawn is asked again when stackshot's record has not caught up
const NS_QUERY_MS = 250;                                  // typing settles this long before the hidden matches are asked for
const NS_ALL = "all";                                     // the last chip: every scope's projects together (a view; a project is made in a real scope)
const NS_HIDDEN_LABEL = "existing pages, not listed";
const ns = { dups: new Set(), options: null, optionsAt: 0, scopes: [], scope: null, listed: {}, listedAt: {}, hiddenRows: [], hiddenScope: "",
             listError: null, loading: false, listSeq: 0, qTimer: null, picked: null, pickedNew: false, nameEdited: false, suggestSeq: 0,
             pending: false, result: null, track: null, tick: null, open: false, from: null, done: new Set(), refs: new Map(), folded: false };
const nsEl = {
  pane: $("#new-pane"), btn: $("#side-new"), form: $("#ns-form"),
  scopes: $("#ns-scopes"), filter: $("#ns-filter"), list: $("#ns-projects"), picked: $("#ns-picked"), name: $("#ns-name"),
  summary: $("#ns-summary"), panel: $("#ns-projpanel"),
  nameErr: $("#ns-name-err"), mandate: $("#ns-mandate"), mandateHint: $("#ns-mandate-hint"), mandateErr: $("#ns-mandate-err"),
  lane: $("#ns-lane"), model: $("#ns-model"), modelOther: $("#ns-model-other"), effort: $("#ns-effort"), submit: $("#ns-submit"), pending: $("#ns-pending"),
  status: $("#ns-status") };
const NS_OTHER = "__other";   // the model choice that opens the id box
// the model the form sends: the choice, or the id typed under "other…"; "" = use the default
const nsModelValue = () => (nsEl.model.value === NS_OTHER ? nsEl.modelOther.value.trim() : nsEl.model.value);
/* The project list's height: six rows by default, dragged taller from its lower right corner (CSS resize: vertical). The
   height the user ends a drag on is kept in the browser ("sala.ns.list-h", whole pixels) and put back on load; a stored
   value that is not a number, or is under three rows, is ignored, and one over the screen is cut to it. Every read and write
   is guarded: a browser that refuses its storage still has the page, at the default height. */
const NS_LIST_KEY = "sala.ns.list-h", NS_LIST_MIN = 130;
const nsListMax = () => Math.max(NS_LIST_MIN, (window.innerHeight || 800) - 120);
function nsRestoreListHeight() {
  let v = null;
  try { v = localStorage.getItem(NS_LIST_KEY); } catch { /* private window */ }
  const h = v !== null && /^\d{1,5}$/.test(v) ? Number(v) : NaN;
  if (!(h >= NS_LIST_MIN)) return;   // nothing stored, not a number, or under three rows
  nsEl.list.style.height = `${Math.min(h, nsListMax())}px`;
}
function nsSaveListHeight() {
  const h = Math.round(nsEl.list.getBoundingClientRect().height);
  if (!(h >= NS_LIST_MIN)) return;
  try { localStorage.setItem(NS_LIST_KEY, String(Math.min(h, nsListMax()))); } catch { /* private window */ }
}
// a drag that starts on the list's own corner (not on a row) is a resize; it is saved when the button comes up
let nsSizing = false;
nsEl.list.addEventListener("pointerdown", (e) => {
  const r = nsEl.list.getBoundingClientRect();
  nsSizing = e.target === nsEl.list && e.clientX >= r.right - 24 && e.clientY >= r.bottom - 24;
});
for (const t of ["pointerup", "mouseup", "pointercancel", "touchend"]) {
  document.addEventListener(t, () => { if (nsSizing) { nsSizing = false; nsSaveListHeight(); } }, true);
}
nsRestoreListHeight();
const nsRole = () => (document.querySelector('input[name="ns-role"]:checked') || {}).value || "front";
const utf8Len = (t) => new TextEncoder().encode(t).length;
class NsStop extends Error {}   // a step failed and said so; the chain ends

// the scope the form opens on: the last one used (all included), else the open session's, else the default scope (api/config), else the first
function nsFirstScope() {
  let saved = null;
  try { saved = localStorage.getItem("sala.ns.scope"); } catch { /* private window */ }
  if (saved && (saved === NS_ALL || ns.scopes.includes(saved))) return saved;
  const from = state.selected || ns.from;   // the page for #new has no session selected: the one it was opened from
  const sc = state.scopes.find((x) => x.groups.some((g) => g.sessions.some((s) => s.name === from)));
  return sc && ns.scopes.includes(sc.key) ? sc.key : ns.scopes.includes(state.defaultScope) ? state.defaultScope : ns.scopes[0] || NS_ALL;
}
async function nsLoadOptions(force = false) {
  if (ns.options && !force && Date.now() - ns.optionsAt < NS_OPTIONS_MS) return ns.options;
  try {
    const r = await apiFetch("api/spawn/options", { cache: "no-store" });
    if (!r.ok) throw new Error("HTTP " + r.status);
    ns.options = await r.json();
    ns.optionsAt = Date.now();
  } catch (e) {
    if (!ns.options) ns.options = { dirs: ["projects", "infra"], lanes: [], efforts: ["low", "medium", "high", "xhigh", "max"], models: ["opus", "sonnet", "haiku", "fable"], defaults: {}, nameMax: 48, mandateMax: 20480 };
  }
  nsFillFixed();
  nsValidate();
  return ns.options;
}
// the lanes, models and efforts, from the options; what was picked stays picked when it is still offered. The first choice of
// each is "use default (<what it is now>)": the value a session with nothing chosen follows (the options' `defaults`: sala's
// default lane, settings.json's model and effort), and "use default" alone when the server could not read it.
function nsDefaultLabel(value, label) {
  return value ? `use default (${label ? label(value) : value})` : "use default";
}
function nsFillFixed() {
  const o = ns.options, d = o.defaults || {};
  const fill = (sel, values, dflt, label, extra) => {
    const keep = sel.value;
    sel.replaceChildren(el("option", { value: "", text: nsDefaultLabel(dflt, label) }), ...values.map((v) => el("option", { value: v, text: label ? label(v) : v })), ...(extra || []));
    sel.value = values.includes(keep) || (extra && keep === NS_OTHER) ? keep : "";
  };
  fill(nsEl.lane, o.lanes || [], d.lane, (v) => laneLabel(v));
  fill(nsEl.model, o.models || [], d.model, null, [el("option", { value: NS_OTHER, text: "other… (a model id)" })]);
  fill(nsEl.effort, o.efforts || [], d.effort);
  nsEl.modelOther.hidden = nsEl.model.value !== NS_OTHER;
  nsEl.name.maxLength = o.nameMax || 48;
}

// ── the scope and the project box ───────────────────────────────────────────
function nsRenderScopes() {
  nsEl.scopes.replaceChildren(...[...ns.scopes, NS_ALL].map((s) => {
    const on = s === ns.scope;
    const b = el("button", { class: "ns-chip", type: "button", role: "radio", "aria-checked": String(on), "data-scope": s, text: s });
    b.addEventListener("click", () => nsSetScope(s));
    return b;
  }));
}
function nsSetScope(s) {
  if (s === ns.scope) return;
  ns.scope = s;
  try { localStorage.setItem("sala.ns.scope", s); } catch { /* private window */ }
  ns.picked = null; ns.pickedNew = false; ns.hiddenRows = []; ns.hiddenScope = ""; ns.folded = false;
  if (!ns.nameEdited) nsEl.name.value = "";
  nsRenderScopes();
  nsLoadProjects();
  nsRenderProjects();
  nsValidate();
}
// the scope's projects from stackshot; with text typed, its hidden matches come with them. A newer ask wins.
async function nsLoadProjects() {
  const scope = ns.scope, q = nsEl.filter.value.trim(), seq = ++ns.listSeq;
  ns.loading = true;
  nsRenderProjects();
  try {
    const r = await apiFetch(`api/spawn/projects?scope=${encodeURIComponent(scope)}${q ? "&q=" + encodeURIComponent(q) : ""}`, { cache: "no-store" }, { tries: 2 });
    const d = await r.json().catch(() => ({}));
    if (seq !== ns.listSeq) return;
    if (!r.ok || !d.ok) throw new Error(d.error || "HTTP " + r.status);
    ns.listed[scope] = (d.projects || []).filter((p) => !p.hidden);
    ns.listedAt[scope] = Date.now();
    ns.hiddenRows = (d.projects || []).filter((p) => p.hidden);
    ns.hiddenScope = scope;
    ns.listError = null;
    if (Array.isArray(d.scopes) && d.scopes.length && d.scopes.join() !== ns.scopes.join()) { ns.scopes = d.scopes; nsRenderScopes(); }
  } catch (e) {
    if (seq !== ns.listSeq) return;
    ns.listError = "Could not read the project list: " + (e.message || e);
  }
  ns.loading = false;
  nsRenderProjects();
  if (!nsEl.name.value) nsSuggest();
  nsValidate();
}
// what the box shows: the listed rows that hold the typed text, then the hidden matches stackshot sent for it
function nsVisible() {
  const q = nsEl.filter.value.trim().toLowerCase();
  const hit = (p) => !q || [p.key, p.name, p.title].some((x) => (x || "").toLowerCase().includes(q));
  const all = ns.listed[ns.scope] || [];
  const keys = new Set(all.map((p) => p.key));
  const hidden = q && ns.hiddenScope === ns.scope ? ns.hiddenRows.filter((p) => hit(p) && !keys.has(p.key)) : [];
  return { q, listed: all.filter(hit), hidden, keys: new Set([...keys, ...hidden.map((p) => p.key)]) };
}
// a slug is lowercase letters, digits and dashes (stackshot's); the typed name is its title
const nsSlugOf = (t) => t.normalize("NFKD").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 60).replace(/-+$/, "");
const nsProjectPrefixOf = (key, scope) => { const slug = key.slice(key.lastIndexOf("/") + 1); return !scope || slug.startsWith(scope + "-") ? slug : scope + "-" + slug; };
function nsNewDraft() {
  const text = nsEl.filter.value.trim().replace(/\s+/g, " ");
  const slug = nsSlugOf(text), dirs = (ns.options && ns.options.dirs) || ["projects", "infra"];
  const dir = dirs.includes(ns.scope) ? ns.scope : dirs.includes("projects") ? "projects" : dirs[0];
  const title = text.length <= 120 && !/["\\]/.test(text) ? text : "";
  return { text, slug, key: slug ? dir + "/" + slug : "", title };
}
// the picked project: an existing row (listed or hidden), or what "+ New project" would make from the typed text
function nsSelection() {
  if (ns.pickedNew) {
    const d = nsNewDraft();
    return d.key ? { kind: "new", key: d.key, id: "", title: d.title, scope: ns.scope, agents: {}, main: "" } : null;
  }
  if (!ns.picked) return null;
  const row = [...(ns.listed[ns.scope] || []), ...ns.hiddenRows].find((p) => p.key === ns.picked);
  return row ? { kind: row.hidden ? "hidden" : "listed", key: row.key, id: row.id, title: row.title, scope: row.scope || (ns.scope === NS_ALL ? "" : ns.scope), agents: row.agents || {}, main: row.main || "" } : null;
}
// a project's name in the box is what the sidebar calls it (sessions.project_title): the key without its folder (projects/, or another page dir)
// and without its scope's prefix; the key stays what is sent
const nsNameOf = (key, scope) => {
  const t = key.includes("/") ? key.slice(key.indexOf("/") + 1) : key;
  return scope && t.startsWith(scope + "-") && t.length > scope.length + 1 ? t.slice(scope.length + 1) : t;
};
const nsRowName = (p) => nsNameOf(p.key, p.scope || (ns.scope === NS_ALL ? "" : ns.scope));
// under "all", the names that two known projects share: only those rows carry their scope beside the name
function nsDuplicateNames() {
  const count = new Map();
  for (const p of [...(ns.listed[NS_ALL] || []), ...(ns.hiddenScope === NS_ALL ? ns.hiddenRows : [])]) count.set(nsRowName(p), (count.get(nsRowName(p)) || 0) + 1);
  return new Set([...count].filter(([, n]) => n > 1).map(([name]) => name));
}
function nsRenderProjects() {
  const { q, listed, hidden, keys } = nsVisible();
  ns.dups = ns.scope === NS_ALL ? nsDuplicateNames() : new Set();
  nsEl.list.setAttribute("aria-busy", String(ns.loading));
  if (ns.pickedNew && nsNewDraft().key && keys.has(nsNewDraft().key)) ns.pickedNew = false;   // the typed name is a project that exists: it is that one
  const rows = listed.map((p) => nsOption(p));
  if (!rows.length && !hidden.length) {
    const text = ns.listError ? ns.listError : ns.loading && !ns.listed[ns.scope] ? "Reading the project list…"
      : q ? "No listed project matches." : "No listed project in this scope yet.";
    rows.push(el("div", { class: "ns-empty", text }));
  }
  if (hidden.length) rows.push(el("div", { class: "ns-divider", role: "separator", text: NS_HIDDEN_LABEL }), ...hidden.map((p) => nsOption(p)));
  const d = nsNewDraft();
  if (ns.scope === NS_ALL) {   // a project is made in one scope: under "all" there is no new-project row, only a word when the text matches nothing
    if (d.text && !listed.length && !hidden.length) rows.push(el("div", { class: "ns-hintrow", "data-key": "__hint__", text: "pick a scope to make a new project" }));
  } else if (!d.slug) rows.push(nsNewOption("+ New project…", "type its name in the box above", true));
  else if (!keys.has(d.key)) rows.push(nsNewOption(`+ New project "${d.text}"`, nsNameOf(d.key, ns.scope), false));
  nsEl.list.replaceChildren(...rows);
  nsRenderFold();
  nsPickedNote();
}
// Once a project is picked the box (the filter, the header and the list) folds to one line: the project's name and description
// and an arrow that opens it again. Picking another project from the opened box folds it again.
function nsRenderFold() {
  const sel = nsSelection();
  nsEl.summary.hidden = !sel;
  const folded = !!sel && ns.folded;
  nsEl.panel.hidden = folded;
  nsEl.summary.setAttribute("aria-expanded", String(!folded));
  nsEl.summary.title = folded ? "Show the project list" : "Fold the project list";
  if (!sel) { nsEl.summary.replaceChildren(); return; }
  const name = sel.kind === "new" ? `+ ${nsNameOf(sel.key, sel.scope)}` : nsNameOf(sel.key, sel.scope);
  const desc = sel.kind === "new" ? "new project" : sel.title && sel.title.trim().toLowerCase() !== name.toLowerCase() ? sel.title : "";
  nsEl.summary.setAttribute("aria-label", `Project ${name}${desc ? ": " + desc : ""}. ${folded ? "Show" : "Fold"} the project list`);
  nsEl.summary.replaceChildren(...[el("span", { class: "ns-key", text: name }), desc ? el("span", { class: "ns-title", text: desc }) : null].filter(Boolean));  // replaceChildren(null) would print "null"
}
function nsFold(on, focus) {
  ns.folded = on;
  nsRenderFold();
  if (on) { if (focus) nsEl.summary.focus({ preventScroll: true }); }
  else if (!narrow()) nsEl.filter.focus({ preventScroll: true });   // no keyboard pops up on a phone until a field is tapped
}
function nsOption(p) {
  const selected = !ns.pickedNew && ns.picked === p.key;
  const name = nsRowName(p);
  const b = el("button", { class: "ns-opt" + (p.hidden ? " ns-hid" : ""), type: "button", role: "option", "aria-selected": String(selected), "data-key": p.key,
                           title: name },
    el("span", { class: "ns-key", text: name }),
    p.title && p.title.trim().toLowerCase() !== name.toLowerCase() ? el("span", { class: "ns-title", text: p.title }) : null,
    ns.scope === NS_ALL && p.scope && ns.dups.has(name) ? el("span", { class: "ns-scope-tag", text: p.scope }) : null);   // under "all", the scope only where two projects share a name
  b.addEventListener("click", () => nsPick(p.key));
  return b;
}
function nsNewOption(label, sub, inert) {
  const b = el("button", { class: "ns-opt ns-new", type: "button", role: "option", "aria-selected": String(ns.pickedNew && !inert), "data-key": "__new__", disabled: inert,
                           title: inert ? "Type the new project's name in the box above" : "Make this project and its page" },
    el("span", { class: "ns-key", text: label }), el("span", { class: "ns-title", text: sub }));
  if (!inert) b.addEventListener("click", () => nsPickNew());
  return b;
}
function nsPick(key) {
  const fromEnter = document.activeElement === nsEl.filter;
  ns.pickedNew = false; ns.picked = key; ns.nameEdited = false; ns.folded = true;
  nsRenderProjects(); nsSuggest(); nsValidate();
  if (fromEnter) nsEl.summary.focus({ preventScroll: true });   // the box folded under the keyboard: the arrow is where it goes on
}
function nsPickNew() {
  if (ns.scope === NS_ALL) return;   // a project is made in one scope; the all view has no new-project row
  const fromEnter = document.activeElement === nsEl.filter;
  ns.pickedNew = true; ns.picked = null; ns.nameEdited = false; ns.folded = true;
  nsRenderProjects(); nsSuggest(); nsValidate();
  if (fromEnter) nsEl.summary.focus({ preventScroll: true });
}
/* The agent's name (-main is suggested only when a new project is created, otherwise a random name such as -pink; before that, a project's name in a scope proposed a name made of the scope and the project, which could already exist):
   the prefix is the project's REAL one: its main agent's name without -main, else what all its agents' names share (projects/lamp,
   listed under example, is example-lamp), else stackshot's page-name rule for a project with no agent (<scope>-<slug>: a new project,
   or one listed with none). The name is `<prefix>-main` only for a front agent of a project with no agent yet; every other name is
   `<prefix>-<word>`, a word picked at random. sala picks it (`sala spawn --suggest-name … --prefix`, which skips a tmux session, a
   running claude and any agent on a project's map in stackshot's record), and this page asks again when the answer is a name it
   knows to be taken (a running session, an agent of any project in the lists it has loaded) or a -main for a project that has
   agents; if sala cannot be asked, the page picks the word itself from the same rule. */
const NS_WORDS = ["fox", "lark", "wren", "moss", "ember", "flint", "slate", "quill", "cairn", "drift", "glade", "tide", "vane", "reed", "birch",
  "heron", "otter", "sable", "thorn", "vale", "amber", "crest", "fern", "gorse", "haven", "ivy", "juniper", "kelp", "larch",
  "mica", "nettle", "onyx", "pike", "quartz", "rowan", "sedge", "topaz", "umber", "willow", "yarrow"];   // lib/spawn.sh's WORDS
function nsPrefixOf(sel) {
  const agents = sel.agents || {}, names = Object.keys(agents).sort();
  const main = sel.main && sel.main.endsWith("-main") ? sel.main : names.find((n) => agents[n].front && n.endsWith("-main"));
  if (main) return main.slice(0, -5);
  if (names.length) {   // no -main agent: the leading dash-parts every agent's name has (one agent: its name without its last part, the role)
    const parts = names.map((n) => n.split("-")), common = [];
    for (let i = 0; i < parts[0].length && parts.every((p) => p[i] === parts[0][i]); i++) common.push(parts[0][i]);
    if (names.length === 1) common.pop();
    if (common.length) return common.join("-");
  }
  return nsProjectPrefixOf(sel.key, sel.scope);
}
// every name the page knows to be in use: the running sessions, and the agents of every project in the lists it has loaded
function nsKnownNames(sel) {
  const known = new Set(state.byName.keys());
  for (const rows of Object.values(ns.listed)) for (const p of rows) for (const n of Object.keys(p.agents || {})) known.add(n);
  for (const n of Object.keys((sel && sel.agents) || {})) known.add(n);
  return known;
}
function nsLocalName(prefix, role, hasAgents, known) {
  const cap = (ns.options && ns.options.nameMax) || 48;
  const free = (n) => n.length <= cap && !known.has(n);
  if (role === "front" && !hasAgents && free(prefix + "-main")) return prefix + "-main";
  for (let i = 0; i < 60; i++) {
    const n = prefix + "-" + NS_WORDS[Math.floor(Math.random() * NS_WORDS.length)];
    if (free(n)) return n;
  }
  return "";
}
async function nsSuggest() {
  const sel = nsSelection();
  if (!sel || ns.nameEdited) return;
  const seq = ++ns.suggestSeq, role = nsRole(), prefix = nsPrefixOf(sel), known = nsKnownNames(sel), hasAgents = Object.keys(sel.agents || {}).length > 0;
  let name = "", last = null;
  for (let i = 0; i < 4 && !name; i++) {
    try {
      // new=1: the project has no page yet, so sala's record cannot know it and would answer a word; a new project's first front is -main
      const r = await apiFetch(`api/spawn/suggest?project=${encodeURIComponent(sel.key)}&role=${encodeURIComponent(role)}&prefix=${encodeURIComponent(prefix)}${sel.kind === "new" ? "&new=1" : ""}`, { cache: "no-store" });
      const d = await r.json().catch(() => ({}));
      if (seq !== ns.suggestSeq) return;   // a later change asked again
      if (!r.ok || !d.name) break;         // sala could not say: the page picks
      if (!known.has(d.name) && !(hasAgents && d.name === prefix + "-main")) name = d.name;
      else if (d.name === last) break;     // the same refused answer again: asking more would only repeat it, the page picks
      last = d.name;
    } catch { break; }
  }
  if (seq !== ns.suggestSeq || ns.nameEdited) return;
  if (!name) name = nsLocalName(prefix, role, hasAgents, known);
  if (name && nsEl.name.value !== name) { nsEl.name.value = name; nsValidate(); }
}

// ── what Create does for the picked project ─────────────────────────────────
// the part of an agent's name after the project's name: "demo-builder" → "builder" (stackshot's role)
function nsAgentRole(name, sel) {
  const prefixes = [nsProjectPrefixOf(sel.key, sel.scope), sel.main.endsWith("-main") ? sel.main.slice(0, -5) : ""].filter(Boolean);
  for (const p of prefixes) if (name.startsWith(p + "-") && name.length > p.length + 1) { const r = name.slice(p.length + 1); if (r.length <= 32) return r; }
  return name.split("-").pop().slice(0, 32);
}
// the agent's one line on the project's page: the mandate's first line (70 characters, a heading's # dropped), else a plain one
function nsAgentLine(mandate, sel, kind) {   // kind: front or back
  const first = (mandate.split("\n").find((l) => l.trim()) || "").replace(/^\s*#+\s*/, "").replace(/\s+/g, " ").trim();
  return Array.from(first).slice(0, 70).join("") || `${kind} agent of ${sel.key.slice(sel.key.lastIndexOf("/") + 1)}`;
}
// the steps for the pick: make the page (new), list it again (hidden, or listed with no agent yet: stackshot lets the label
// that listed a project add its first agents), add the agent (unless the project lists the name), start the session
function nsPlan(sel, name) {
  const steps = [];
  const has = Object.prototype.hasOwnProperty.call(sel.agents, name);
  if (sel.kind === "new" || ns.done.has("make:" + sel.key)) steps.push({ id: "make", label: "Make the project page" });   // made by an earlier try of this form: shown done
  else if (!has && (sel.kind === "hidden" || !Object.keys(sel.agents).length)) steps.push({ id: "list", label: sel.kind === "hidden" ? "List the project again" : "Confirm the project is listed" });
  if (!has) steps.push({ id: "agent", label: `Add ${name} to the project` });
  steps.push({ id: "spawn", label: "Start the session" });
  return steps.map((s) => ({ ...s, state: "todo" }));
}
function nsPickedNote() {
  const sel = nsSelection(), name = nsEl.name.value.trim() || "the agent";
  let t = "";
  if (ns.pickedNew && !sel) t = "A project name needs letters or digits (a to z, 0 to 9).";
  else if (sel) {
    const plan = nsPlan(sel, nsEl.name.value.trim()).map((s) => s.id);
    const parts = [];
    const pname = nsNameOf(sel.key, sel.scope);
    if (plan.includes("make")) parts.push(`make ${pname} (${sel.scope}; its page is written through gbrain and can take a few minutes)`);
    if (plan.includes("list")) parts.push(sel.kind === "hidden" ? `list ${pname} again` : "");
    if (plan.includes("agent")) parts.push(`add ${name} to it`);
    const todo = parts.filter(Boolean);
    t = todo.length ? `Create will ${todo.join(", ")}, then start the session.` : "";
  }
  nsEl.picked.textContent = t;
}
// the same checks the server and sala make, so a refusal shows here first; the button is enabled only when all pass
function nsValidate() {
  const o = ns.options || {};
  const nameMax = o.nameMax || 48, mandateMax = o.mandateMax || 20480;
  const name = nsEl.name.value.trim(), role = nsRole(), mandate = nsEl.mandate.value;
  const nameErr = name && (!NS_NAME_RE.test(name) || name.length > nameMax)
    ? `Lowercase letters, digits and dashes, no dash at either end, at most ${nameMax} characters.`
    : name && state.byName.has(name) ? `A session called ${name} is running already. Pick another name.` : "";
  nsEl.nameErr.textContent = nameErr;
  const bytes = utf8Len(mandate);
  const mandateErr = bytes > mandateMax ? `The mandate is over ${Math.round(mandateMax / 1024)} KB (${Math.round(bytes / 1024)} KB).`
    : role === "back" && !mandate.trim() ? "A background agent needs a mandate: it reads it at its first prompt, and nobody briefs it." : "";
  nsEl.mandateErr.textContent = mandateErr;
  nsEl.mandateHint.textContent = role === "back" ? "required for a background agent" : "optional for a front agent";
  nsPickedNote();
  nsEl.modelOther.hidden = nsEl.model.value !== NS_OTHER;
  const modelOk = nsEl.model.value !== NS_OTHER || (nsEl.modelOther.value.trim() !== "" && NS_MODEL_RE.test(nsEl.modelOther.value.trim()));
  const busy = nsBusyOf(ns.result);
  const ok = !!nsSelection() && !!name && !nameErr && !mandateErr && modelOk && !ns.pending && !busy;
  nsBusyButton(nsEl.submit, busy || ns.pending);
  nsEl.submit.disabled = !ok;
  return ok;
}
const nsPost = async (url, body) => {   // fetch, not apiFetch: none of these is ever repeated on its own
  try {
    const r = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
    return { status: r.status, d: await r.json().catch(() => ({})) };
  } catch (err) {
    return { status: 0, d: { ok: false, code: "unreachable", error: "Could not reach sala: " + (err && err.message || err) } };
  }
};
// the page asks about the job that makes the project until it is done; a poll that fails is asked again (a phone that slept)
async function nsWaitJob(job, step) {
  const t0 = Date.now();
  step.since = t0;
  while (Date.now() - t0 < NS_JOB_MAX_MS) {
    await sleep(NS_JOB_POLL_MS);
    try {
      const r = await fetch(`api/spawn/project/job?id=${encodeURIComponent(job)}`, { cache: "no-store" });
      const d = await r.json().catch(() => null);
      if (r.status === 404) return { status: 404, d: { ok: false, code: "lost", error: (d && d.error) || "The job is gone." } };
      if (r.ok && d && d.state === "done") return { status: d.status, d: d.result || {} };
    } catch { /* asked again */ }
  }
  return { status: 0, d: { ok: false, code: "timeout", error: "stackshot did not finish the page within five minutes." } };
}
// a refusal in plain words, by the step it came from
function nsWords(id, d, status, sel, name) {
  const code = d.code || "";
  if (id === "make" && code === "exists") return `${sel.key} exists already. Type its name in the box and pick it from the list, then Create.`;
  if (id === "make" && code === "in-progress") return `${sel.key} is being made right now by another request. Wait a minute, then type its name in the box to look for it, or Create again.`;
  if (id === "make" && code === "gbrain") return "gbrain did not take the new page, and nothing else was recorded. Create again to retry.";
  if (id === "make" && (code === "lost" || code === "timeout")) return `${d.error} The project may exist now: type its name in the box to look for it. Create again continues if it does not.`;
  if (id === "agent" && code === "not-allowed") return `${sel.key} is retired or hidden, so stackshot will not add an agent to it. Pick another project.`;
  if (id === "agent" && code === "exists") return `stackshot would not take ${name} as an agent of ${sel.key} (its reason is above). Change the name, then Create again.`;
  if (id === "spawn" && code === "not-listed") return `sala's check does not see ${name} on the project yet. Create again in a minute.`;
  if (id === "spawn" && code === "no-page") return `sala does not see the page ${d.page || sel.key} yet. Create again in a minute.`;
  if (id === "spawn" && code === "busy") return "Another session is being queued. Create again in a moment.";
  if (code === "config" || code === "unreachable" || code === "refused") return d.error || "stackshot could not be reached.";
  return d.error || `HTTP ${status}`;
}
async function nsSubmit(e) {
  e.preventDefault();
  if (ns.pending || !nsValidate()) return;
  const sel = nsSelection(), role = nsRole(), name = nsEl.name.value.trim(), mandate = nsEl.mandate.value;
  const body = { role, name };
  if (mandate.trim()) body.mandate = mandate;
  for (const [k, v] of [["lane", nsEl.lane.value.trim()], ["model", nsModelValue()], ["effort", nsEl.effort.value.trim()]]) if (v) body[k] = v;
  ns.pending = true;
  nsEl.pending.hidden = false;
  nsValidate();
  nsStopTrack();
  const res = { kind: "working", name, project: sel.key, role, steps: nsPlan(sel, name), wait: "", error: null, pageOwed: false };
  ns.result = res;
  clearInterval(ns.tick);
  ns.tick = setInterval(nsRenderStatus, 1000);   // the seconds of a long step
  nsRenderStatus();
  try {
    await nsRun(sel, body, res);
  } catch (err) {
    if (!(err instanceof NsStop)) ns.result = { kind: "failed", name, steps: res.steps, error: String(err && err.message || err), words: "Something went wrong in this page. The start may already be queued: look in the session list before creating it again." };
  }
  clearInterval(ns.tick); ns.tick = null;
  ns.pending = false;
  nsEl.pending.hidden = true;
  nsRenderStatus();
  nsValidate();
}
async function nsRun(sel, body, res) {
  const step = (id) => res.steps.find((s) => s.id === id);
  const stop = (id, d, status) => {
    step(id).state = "failed";
    ns.result = { kind: "failed", name: body.name, steps: res.steps, failedStep: id, words: nsWords(id, d, status, sel, body.name), error: String(d.error || `HTTP ${status}`) };
    throw new NsStop();
  };
  const begin = (id) => { step(id).state = "active"; step(id).since = Date.now(); nsRenderStatus(); };
  let ref = ns.refs.get(sel.key) || sel.id || sel.key;
  const record = () => res.steps.some((s) => ["make", "list", "agent"].includes(s.id));
  if (step("make")) {
    if (ns.done.has("make:" + sel.key)) step("make").state = "done";
    else {
      begin("make");
      const sent = await nsPost("api/spawn/project", { key: sel.key, scope: sel.scope, ...(sel.title ? { title: sel.title } : {}) });
      const out = sent.status === 202 && sent.d.job ? await nsWaitJob(sent.d.job, step("make")) : sent;
      if (out.status !== 200 || !out.d.ok) {
        if (out.d.code === "exists") nsLoadProjects();   // the page is there: the box shows it
        stop("make", out.d, out.status);
      }
      ref = out.d.id || sel.key;
      ns.refs.set(sel.key, ref);
      ns.done.add("make:" + sel.key);
      step("make").state = "done";
      ns.pickedNew = false; ns.picked = sel.key;   // it is a project of the scope now: the box lists it, selected
      nsLoadProjects();   // not awaited
    }
  }
  if (step("list")) {
    if (ns.done.has("list:" + sel.key)) step("list").state = "done";
    else {
      begin("list");
      const out = await nsPost("api/spawn/project-list", { key: sel.id || sel.key, ...(sel.scope ? { scope: sel.scope } : {}) });
      if (out.status !== 200 || !out.d.ok) stop("list", out.d, out.status);
      ns.done.add("list:" + sel.key);
      step("list").state = "done";
    }
  }
  if (step("agent")) {
    if (ns.done.has(`agent:${sel.key}:${body.name}`)) step("agent").state = "done";
    else {
      begin("agent");
      const role = nsAgentRole(body.name, sel);
      const out = await nsPost("api/spawn/project-agent", { project: ref, name: body.name, role, front: body.role === "front", mandate: nsAgentLine(body.mandate || "", sel, body.role) });
      if (out.status !== 200 || !out.d.ok) stop("agent", out.d, out.status);
      if (out.d.pageOwed) res.pageOwed = true;
      ns.done.add(`agent:${sel.key}:${body.name}`);
      step("agent").state = "done";
    }
  }
  // stackshot's record is read by sala within moments of a change: a spawn that does not see the project or the agent yet is asked again
  for (let tries = 0; ; tries++) {
    begin("spawn");
    const out = await nsPost("api/spawn", { ...body, project: sel.key });
    if (out.status === 202 && out.d.ok) {
      step("spawn").state = "done";
      ns.result = { kind: "queued", op: out.d.op, name: out.d.name, project: out.d.project, role: out.d.role, since: Date.now(), state: "queued", opState: "", opResult: "",
                    steps: res.steps, pageOwed: res.pageOwed };
      nsTrack();
      return;
    }
    if (["not-listed", "no-page"].includes(out.d.code) && record() && tries < NS_RECORD_WAITS.length) {
      step("spawn").state = "waiting";
      res.wait = "sala's check has not seen the change yet; asking again.";
      nsRenderStatus();
      await sleep(NS_RECORD_WAITS[tries]);
      continue;
    }
    stop("spawn", out.d, out.status);
  }
}
function nsStopTrack() { if (ns.track) { clearTimeout(ns.track); ns.track = null; } }
// The form follows the operation to its end: queued → starting (the marker running or waiting) → ready (done, with
// the name in the sessions list, or 30 s after done); stuck, cancelled or absorbed → failed with the queue's result line. While
// it is queued the server says what it waits behind (`behind_line`). The 30-minute cap is the last resort and says the start is
// still going (shared.js nsVerdict). Shared by the New session form and the quick session form: res is the form's queued result,
// render its own status drawer. True when it ended.
async function nsPollStep(res, render) {
  const end = (st) => { res.state = st; res.doneAt = Date.now(); render(); return true; };
  const verdict = () => nsVerdict(res.opState, state.byName.has(res.name), Date.now() - res.since, res.opDoneAt ? Date.now() - res.opDoneAt : 0);
  if (verdict() === "ready") return end("ready");
  try {
    const r = await fetch(`api/spawn/status?op=${encodeURIComponent(res.op)}`, { cache: "no-store" });
    if (r.ok) {
      const d = await r.json();
      res.opState = d.state || ""; res.opResult = d.result || ""; res.behindLine = d.behind_line || "";
      if (res.opState === "done" && !res.opDoneAt) res.opDoneAt = Date.now();
    }
  } catch { /* the next tick asks again */ }
  let v = verdict();
  if (v === "failed" || v === "ready" || v === "late") return end(v);
  res.state = v;
  res.reached = res.state;
  render();
  await loadSessions();   // the new session is in the list as soon as its registry row lands
  v = verdict();
  if (v === "ready" || v === "late") return end(v);
  return false;
}
async function nsTrack() {
  nsStopTrack();
  const res = ns.result;
  if (!res || res.kind !== "queued") return;
  if (await nsPollStep(res, nsRenderStatus) || ns.result !== res) return;
  ns.track = setTimeout(nsTrack, nsPollDelay(Date.now() - res.since));
}
// ── what a queued session shows (a start used to give no sign of what was going on or what to expect) ─────────────
// Start's button says it is working until the session is ready or has failed; a line of steps names the one the session is
// at (a word and aria-current, never a colour alone); the seconds so far and what a start usually takes; the operation id
// small and last; at Ready the Open button is the main thing, focused. There is no step for loading the conversation: the
// sessions list carries no sign of it (a row exists as soon as claude runs), so none is shown rather than a made-up one.
const NS_STEPS = [["queued", "Queued"], ["starting", "Starting the session"], ["ready", "Ready"]];
const NS_USUALLY = "Usually 30 seconds to a minute; a few minutes if sala has other work queued first.";
const nsBusyOf = (res) => !!res && res.kind === "queued" && (res.state === "queued" || res.state === "starting");
function nsSeconds(ms) {
  const t = Math.max(0, Math.round(ms / 1000));
  return t < 60 ? `${t} s` : `${Math.floor(t / 60)} min ${t % 60} s`;
}
// Start's button while its work is on: disabled, a spinner and "Starting…" (the idle label comes back on its own)
function nsBusyButton(btn, busy) {
  if (btn.getAttribute("aria-busy") === String(busy)) return;
  btn.setAttribute("aria-busy", String(busy));
  if (busy) {
    btn.dataset.idle = btn.textContent;
    btn.replaceChildren(el("span", { class: "ns-spin", "aria-hidden": "true" }), document.createTextNode("Starting…"));
  } else btn.replaceChildren(document.createTextNode(btn.dataset.idle || btn.textContent));
}
// who a twice-failed start is reported to: the session SALA_HELP_SESSION names (the Get Help chip's, which the server puts
// in the page only when it is set); none set, the words name no session
function tellHelp() {
  const a = document.getElementById("sp-help"), h = a ? decodeURIComponent((a.getAttribute("href") || "").replace(/^#s=/, "")) : "";
  return h ? "tell " + h : "tell whoever looks after sala on this machine";
}
function nsProgressList(res) {
  const at = Math.max(0, NS_STEPS.findIndex(([id]) => id === (res.state === "failed" || res.state === "late" ? res.reached || "queued" : res.state)));
  const stopped = res.state === "failed" || res.state === "late";
  return el("ol", { class: "ns-progress", "aria-label": "Progress" }, ...NS_STEPS.map(([, label], i) => {
    const word = i < at || (i === at && res.state === "ready") ? "done" : i === at ? (res.state === "failed" ? "stopped here" : res.state === "late" ? "still waiting" : "now")
      : stopped && res.state === "failed" ? "not reached" : "next";
    const attrs = { class: "ns-prog" + (i === at ? " current" : "") + (i < at || (i === at && res.state === "ready") ? " done" : "") };
    if (i === at) attrs["aria-current"] = "step";
    return el("li", attrs, el("span", { class: "ns-prog-label", text: label }), el("span", { class: "ns-prog-state", text: word }));
  }));
}
function nsElapsedText(res) {
  return res.doneAt && res.state === "ready" ? `Took ${nsSeconds(res.doneAt - res.since)}.` : `${nsSeconds(Date.now() - res.since)} so far. ${NS_USUALLY}`;
}
// the seconds change in place once a second, so a screen reader is not read the whole status again each time
function nsElapsedTick(res, host, current) {
  const live = nsBusyOf(res);
  if (live && !res.etick) {
    res.etick = setInterval(() => {
      const p = host.querySelector(".ns-elapsed");
      if (current() !== res || !nsBusyOf(res)) { clearInterval(res.etick); res.etick = null; }
      else if (p) p.textContent = nsElapsedText(res);
    }, 1000);
  } else if (!live && res.etick) { clearInterval(res.etick); res.etick = null; }
}
// what both forms show for a session that is queued: the same words; opts: steps (the create's own steps), about (what it is), note
function nsQueuedKids(res, opts) {
  const kids = [], failed = res.state === "failed";
  const headline = { queued: "Queued", starting: "Starting the session", ready: "Ready", failed: "Did not start", late: "Still going" }[res.state] || res.state;
  const state = el("div", { class: "ns-state " + (failed ? "failed" : res.state), text: `${res.name}: ${headline}` });
  if (res.state === "ready") {
    // a plain in-page link: the click goes through go() ("selection, hash, history"), which closes the
    // drawer by its history entry before it opens the session. Beside the headline: the main thing on the screen
    kids.push(el("div", { class: "ns-top" }, state,
      el("a", { class: "ns-link ns-open", href: "#s=" + encodeURIComponent(res.name) }, document.createTextNode("Open "), el("span", { class: "ns-key", text: res.name }))));
  } else kids.push(state);
  kids.push(nsProgressList(res));
  if (opts.steps) kids.push(opts.steps);
  if (res.state === "queued" || res.state === "starting") kids.push(el("p", { text: nsWaitText(res.state === "starting" ? "running" : res.opState, res.behindLine) }));
  else if (failed) kids.push(el("p", { text: "The session did not start. Try again; if it fails twice, " + tellHelp() + "." }),
    el("p", { class: "ns-hint ns-result", text: `Result: ${res.opState}: ${res.opResult || "no result line"}. sala posts the result in Slack too.` }));
  else if (res.state === "late") kids.push(el("p", { text: nsLateText(res.opState) }));
  if (opts.note) kids.push(opts.note);
  const meta = [];
  if (opts.about) meta.push(el("p", { class: "ns-hint ns-about", text: opts.about }));
  if (nsBusyOf(res) || res.state === "ready") meta.push(el("p", { class: "ns-hint ns-elapsed", "aria-live": "off", text: nsElapsedText(res) }));
  meta.push(el("p", { class: "ns-hint ns-op", text: `Operation ${res.op}` }));
  kids.push(el("div", { class: "ns-meta" }, ...meta));
  return kids;
}
// Open takes the focus once, so Enter opens the session (not while the person is typing in a field of the form)
function nsFocusOpen(host, res) {
  if (res.state !== "ready" || res.focused) return;
  const a = host.querySelector("a.ns-open");
  const at = document.activeElement;
  if (!a || !a.getClientRects().length || (at && /^(INPUT|TEXTAREA|SELECT)$/.test(at.tagName))) return;
  res.focused = true;
  a.focus();
}
// the steps of a create with more than the spawn in it, each with its state in words (never a colour alone)
function nsStepsList(steps) {
  if (!steps || steps.length < 2) return null;
  const words = { todo: "waiting", active: "working", done: "done", failed: "failed", waiting: "asking again" };
  return el("ol", { class: "ns-steps" }, ...steps.map((s) => {
    let label = s.label;
    if (s.id === "make" && s.state === "active") label = `Making the project page, which can take a few minutes (${Math.max(0, Math.round((Date.now() - (s.since || Date.now())) / 1000))} s)`;
    return el("li", { class: "ns-step " + s.state }, el("span", { class: "ns-step-label", text: label }), el("span", { class: "ns-step-state", text: words[s.state] || s.state }));
  }));
}
function nsRenderStatus() {
  const res = ns.result, kids = [];
  const line = (cls, text) => el("div", { class: "ns-state " + cls, text });
  if (!res) { nsEl.status.replaceChildren(); return; }
  if (res.kind === "working") {
    kids.push(line("pending", `${res.name}: working…`), nsStepsList(res.steps) || el("p", { class: "ns-hint", text: "Asking sala to queue the session…" }));
    if (res.wait) kids.push(el("p", { class: "ns-hint", text: res.wait }));
  } else if (res.kind === "queued") {
    kids.push(...nsQueuedKids(res, {
      steps: nsStepsList(res.steps),
      about: `A ${res.role} agent of ${res.project}.`,
      note: res.pageOwed ? el("p", { class: "ns-hint", text: "The agent's line on the project page is recorded with stackshot, which keeps it until the page lists it." }) : null,
    }));
    nsElapsedTick(res, nsEl.status, () => ns.result);
  } else if (res.kind === "failed") {
    // the refusal first and whole, in the server's own words (a failed create must show why), then what to do about it
    const who = res.failedStep && res.failedStep !== "spawn" ? "stackshot" : "sala";
    kids.push(line("failed", `${res.name ? res.name + ": " : ""}${res.failedStep === "spawn" || !res.failedStep ? "not queued" : "stopped"}`), nsStepsList(res.steps),
              el("p", { class: "ns-reason", text: `Why: ${who} answered` }), el("div", { class: "ns-pre" }, el("pre", { class: "ns-why", text: res.error })),
              res.words && res.words !== res.error ? el("p", { text: res.words }) : null);
    if (res.steps && res.steps.some((s) => s.state === "done") && res.steps.length > 1) kids.push(el("p", { class: "ns-hint", text: "Create again to go on from the failed step; the steps that are done are not repeated." }));
  }
  nsEl.status.replaceChildren(...kids.filter(Boolean));
  if (res.kind === "queued") nsFocusOpen(nsEl.status, res);
  if (nsEl.submit.getAttribute("aria-busy") !== String(nsBusyOf(res) || ns.pending)) nsValidate();   // Start's button follows the session's progress
}
// The page for #new is shown and hidden by the route (setNewPage, "selection, hash, history"): nsShow when it is drawn,
// nsHide when another view takes the main area. What was typed and the last result stay in the page across the two.
function nsShow() {
  if (ns.open) return;
  ns.open = true;
  if (!ns.scope) { ns.scope = nsFirstScope(); nsRenderScopes(); }
  nsValidate();
  nsRenderStatus();
  const stale = !ns.listedAt[ns.scope] || Date.now() - ns.listedAt[ns.scope] > NS_OPTIONS_MS;
  Promise.all([nsLoadOptions(), stale ? nsLoadProjects() : (nsRenderProjects(), null)]);
  (narrow() ? nsEl.pane : nsEl.filter).focus({ preventScroll: true });   // no keyboard pops up on a phone until a field is tapped
}
function nsHide() { ns.open = false; }

/* QUICK SESSIONS (called side conversations inside sala and in the API: `side`, `fork_of`, `item`; docs/side-sessions.md;
   renamed on the page). The New session page's other form (#sd-form, shown while the hash is #side=…): a short
   talk with the owner started in one step, through the same queue as the New session form (POST api/spawn with side: true). Two fields,
   BOTH OPTIONAL and independent, each a picker built like the project box (a one-line summary with an arrow, a search box, a header
   row and a list; a typed id is accepted too):
   · BOARD ITEM: a fresh session scoped to the item's project page. The list is the open items of the live sessions that the page
     already has (api/board-items); any other id can be typed. The item's project and owner are looked up (api/spawn/item) and fill
     the project and agents fields, which show only for an item without a fork.
   · SESSION TO FORK: the live sessions the page lists. The new session continues that one's conversation.
   Either alone, or both (a fork about an item): sala's backend needs one of the two to know what the talk is about (a start with
   neither has no page to scope it to and no conversation to continue; lib/spawn.sh), so the form says so and keeps Start off until
   one is chosen. The Discuss link of stackshot, <sala's address>/#side=<id> (e.g. https://sala.example.com/#side=<id>), opens the form with the item chosen. The id is
   everything after "side=", whatever it looks like: board#N, an older sN, a temporary board-tmp-box#N (it may itself hold a
   "#"). The link #side=from:<name> opens it with that session chosen (no button in the session header: its fold is measured to the
   pixel). A blank name is the suggested one (<prefix>-side-<word><nn>, api/spawn/suggest?side=1). */
const SD_ITEM_RE = /^(?:board#\d+|board-tmp-[a-z0-9]+(?:-[a-z0-9]+)*#\d+|[a-z]\d+)$/;
const SD_NAME_RE = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const SD_PROJECT_RE = /^[a-z]+\/[a-z0-9]/;
const sdEl = { form: $("#sd-form"), item: $("#sd-item"), project: $("#sd-project"), agents: $("#sd-agents"), fork: $("#sd-fork"),
  name: $("#sd-name"), nameErr: $("#sd-name-err"), mandate: $("#sd-mandate"), submit: $("#sd-submit"), pending: $("#sd-pending"),
  status: $("#sd-status"), note: $("#sd-note"), need: $("#sd-need"), extra: $("#sd-item-extra"),
  projects: $("#sd-projects"), itemPick: $("#sd-item-pick"), forkPick: $("#sd-fork-pick") };
const sd = { applied: null, pending: false, result: null, track: null, tick: null, nameEdited: false, suggestSeq: 0, lookupSeq: 0 };
const sdItemId = () => sdEl.item.value.trim();
const sdForkName = () => sdEl.fork.value.trim();
function sdDecode(t) { try { return decodeURIComponent(t); } catch { return t; } }
// "#side=<id>[&project=<key>&agents=<a,b>]" or "#side=from:<name>" -> { kind, item | from, project, agents }; an empty value is the blank form.
// The id is everything up to the first "&" (an id has none), and it may hold "#".
function sdParse(h) {
  const rest = h.slice("#side=".length), amp = rest.indexOf("&");
  const main = sdDecode(amp < 0 ? rest : rest.slice(0, amp)).trim();
  const extra = new URLSearchParams(amp < 0 ? "" : rest.slice(amp + 1));
  const out = { project: (extra.get("project") || "").trim(), agents: (extra.get("agents") || "").trim() };
  if (main.startsWith("from:")) return { ...out, kind: "fork", from: main.slice(5).trim() };
  return { ...out, kind: "item", item: main };
}

/* A picker for the quick session's two fields: the project box's look (nsPick's one-line summary with an arrow, a search box, a
   header row, the list), for any list. cfg: noun, none (the summary of an empty field), placeholder, head [name column, description
   column], empty / noMatch (the list's words), rows() -> [{key, name, desc}], typed(text) -> a row for text that is not in the
   list but is a valid value, or null, onChange(key). `set` and `clear` do not call onChange (the caller is the one changing). */
function nsPicker(host, cfg) {
  const st = { key: "", row: null, open: false };
  const sum = el("button", { class: "ns-sum", type: "button", "aria-expanded": "false", "aria-haspopup": "listbox" });
  const clear = el("button", { class: "ns-clear", type: "button", hidden: true, title: `Clear the ${cfg.noun}`, "aria-label": `Clear the ${cfg.noun}`, text: "×" });
  const search = el("input", { type: "search", placeholder: cfg.placeholder, "aria-label": `Search the ${cfg.noun}s`, autocapitalize: "off", spellcheck: "false" });
  const list = el("div", { class: "ns-list", role: "listbox", "aria-label": cfg.noun + "s", tabindex: "-1" });
  const panel = el("div", { class: "ns-panel", hidden: true }, search,
    el("div", { class: "ns-head" }, el("span", { class: "ns-hk", text: cfg.head[0] }), el("span", { class: "ns-ht", text: cfg.head[1] })), list);
  host.replaceChildren(el("div", { class: "ns-pickrow" }, sum, clear), panel);
  const opt = (r, typed) => el("button", { class: "ns-opt" + (typed ? " ns-new" : ""), type: "button", role: "option", "aria-selected": String(r.key === st.key), "data-key": r.key,
                                           onclick: () => choose(r) },
    el("span", { class: "ns-key", text: r.name }), r.desc ? el("span", { class: "ns-title", text: r.desc }) : null);
  function render() {
    const q = search.value.trim(), all = cfg.rows();
    const hit = all.filter((r) => !q || [r.key, r.name, r.desc].some((x) => (x || "").toLowerCase().includes(q.toLowerCase())));
    const typed = q && !all.some((r) => r.key === q) ? cfg.typed(q) : null;
    const rows = hit.map((r) => opt(r, false));
    if (typed) rows.push(opt(typed, true));
    if (!rows.length) rows.push(el("div", { class: "ns-empty", text: q ? cfg.noMatch : cfg.empty }));
    list.replaceChildren(...rows);
    panel.hidden = !st.open;
    sum.setAttribute("aria-expanded", String(st.open));
    sum.title = st.open ? `Fold the ${cfg.noun} list` : `Show the ${cfg.noun} list`;
    const r = st.key ? st.row || { key: st.key, name: st.key, desc: "" } : null;
    sum.setAttribute("aria-label", r ? `${cfg.noun}: ${r.name}${r.desc ? ", " + r.desc : ""}. ${st.open ? "Fold" : "Show"} the list` : `${cfg.noun}: ${cfg.none}. Show the list`);
    sum.replaceChildren(...(r ? [el("span", { class: "ns-key", text: r.name }), r.desc ? el("span", { class: "ns-title", text: r.desc }) : null].filter(Boolean) : [el("span", { class: "ns-none", text: cfg.none })]));
    clear.hidden = !r;
  }
  function choose(r) {
    st.key = r.key; st.row = r; st.open = false; search.value = "";
    render();
    sum.focus({ preventScroll: true });
    cfg.onChange(st.key);
  }
  sum.addEventListener("click", () => { st.open = !st.open; render(); if (st.open && !narrow()) search.focus({ preventScroll: true }); });
  clear.addEventListener("click", () => { st.key = ""; st.row = null; render(); cfg.onChange(""); });
  search.addEventListener("input", render);
  search.addEventListener("keydown", (e) => {   // Enter picks the first row shown, and never submits the form
    if (e.key !== "Enter" || e.isComposing) return;
    e.preventDefault();
    const first = list.querySelector(".ns-opt");
    if (first) first.click();
  });
  render();
  return {
    get value() { return st.key; },
    set(key) { st.key = key || ""; st.row = key ? cfg.rows().find((r) => r.key === key) || null : null; st.open = false; search.value = ""; render(); },
    render,
  };
}
// the open board items the page knows: those of the live sessions (api/board-items), one row per item, newest number first
function sdItemRows() {
  const seen = new Map();
  for (const [session, b] of Object.entries(board.sessions || {})) {
    for (const i of (b && b.items) || []) {
      if (!i.id || !SD_ITEM_RE.test(i.id)) continue;
      const r = seen.get(i.id) || { key: i.id, name: i.id, subject: i.subject || "", owners: [] };
      r.owners.push(session);
      seen.set(i.id, r);
    }
  }
  const num = (id) => Number((/#(\d+)$/.exec(id) || [0, 0])[1]);
  return [...seen.values()].sort((a, b) => num(b.key) - num(a.key) || a.key.localeCompare(b.key))
    .map((r) => ({ key: r.key, name: r.name, desc: [r.subject, r.owners.length ? `(${r.owners[0]})` : ""].filter(Boolean).join(" ") }));
}
// the running sessions the page lists, by name; a row says its project and role
function sdSessionRows() {
  return [...state.byName.values()].sort((a, b) => a.name.localeCompare(b.name))
    .map((s) => ({ key: s.name, name: s.name, desc: [s.project, s.role, s.status].filter(Boolean).join(" · ") }));
}
const sdItemPick = nsPicker(sdEl.itemPick, {
  noun: "board item", none: "none chosen (optional)", placeholder: "Search the open items, or type an id such as board#9001", head: ["Item", "Subject (owner)"],
  empty: "No open board items of the running sessions are known yet. Type an id above.", noMatch: "No open item matches. A full id can be used as typed.",
  rows: sdItemRows, typed: (t) => (SD_ITEM_RE.test(t) ? { key: t, name: t, desc: "use this id as typed" } : null),
  onChange: (key) => sdChanged("item", key) });
const sdForkPick = nsPicker(sdEl.forkPick, {
  noun: "session", none: "none chosen (optional)", placeholder: "Search the running sessions", head: ["Session", "Project · role · state"],
  empty: "No running session is listed.", noMatch: "No running session matches.",
  rows: sdSessionRows, typed: (t) => (SD_NAME_RE.test(t) && t.length <= 48 ? { key: t, name: t, desc: "use this name as typed" } : null),
  onChange: (key) => sdChanged("fork", key) });
// the user chose (or cleared) one of the two: the name is suggested again, an item is looked up
function sdChanged(which, key) {
  if (which === "item") { sdEl.item.value = key; sdEl.project.value = ""; sdEl.agents.value = ""; sdEl.note.textContent = ""; }
  else sdEl.fork.value = key;
  sdEl.name.value = ""; sd.nameEdited = false;
  sdValidate();
  if (which === "item" && key) sdLookup().then(sdSuggest); else sdSuggest();
}
// the hash decides which form the page shows; its values are put into the form once per hash (route() calls again for the same one)
function sdMode() {
  const on = sideHash();
  document.body.classList.toggle("side-mode", on);
  const t = on ? "Quick session" : "New session";
  setTitle(t);
  $("#title .name").textContent = t;
  for (const [id, current] of [["#np-new", !on], ["#np-quick", on]]) {   // the switch at the top of the page, the same on both forms
    const a = $(id);
    if (current) a.setAttribute("aria-current", "page"); else a.removeAttribute("aria-current");
  }
  if (!on) { sd.applied = null; return; }
  if (sd.applied === location.hash) return;
  sd.applied = location.hash;
  sdApply(sdParse(location.hash));
}
async function sdApply(p) {
  sdEl.name.value = ""; sd.nameEdited = false;
  sdEl.note.textContent = "";
  sdEl.item.value = p.kind === "item" ? p.item || "" : "";
  sdEl.fork.value = p.kind === "fork" ? p.from || "" : "";
  sdEl.project.value = p.kind === "item" ? p.project || "" : "";
  sdEl.agents.value = p.kind === "item" ? p.agents || "" : "";
  sdItemPick.set(sdEl.item.value);
  sdForkPick.set(sdEl.fork.value);
  sdFillLists();
  sdValidate();
  if (sdItemId()) await sdLookup();
  sdSuggest();
}
// the project pages the project field offers
async function sdFillLists() {
  const o = await nsLoadOptions();
  sdEl.projects.replaceChildren(...((o && o.projects) || []).map((x) => el("option", { value: x.key, label: x.title || "" })));
}
// the item's project and owner from stackshot, into the fields still empty
async function sdLookup() {
  const seq = ++sd.lookupSeq, id = sdItemId();
  if (!SD_ITEM_RE.test(id)) return;
  sdEl.note.textContent = `Looking up ${id}…`;
  try {
    const r = await apiFetch(`api/spawn/item?id=${encodeURIComponent(id)}`, { cache: "no-store" });
    const d = await r.json().catch(() => ({}));
    if (seq !== sd.lookupSeq) return;
    if (!r.ok || !d.ok) { sdEl.note.textContent = `${id}: ${d.error || "HTTP " + r.status}. Fill in the project by hand.`; sdValidate(); return; }
    if (!sdEl.project.value.trim() && d.project) sdEl.project.value = d.project;
    if (!sdEl.agents.value.trim() && d.owner) sdEl.agents.value = d.owner;
    sdEl.note.textContent = `${d.item || id}${d.status && d.status !== "open" ? " (" + d.status + ")" : ""}: project ${d.project || "unknown"}${d.owner ? ", owner " + d.owner : ""}.`;
  } catch (e) {
    if (seq === sd.lookupSeq) sdEl.note.textContent = `Could not look up ${id}. Fill in the project by hand.`;
  }
  sdValidate();
}
async function sdSuggest() {
  const seq = ++sd.suggestSeq, fork = sdForkName(), project = sdEl.project.value.trim();
  if (sd.nameEdited || (!fork && !project)) return;
  const q = fork ? `fork_of=${encodeURIComponent(fork)}` : `project=${encodeURIComponent(project)}`;
  for (let i = 0; i < 3; i++) {   // sala never suggests a name it knows to be taken; the page also skips a running session's name
    try {
      const r = await apiFetch(`api/spawn/suggest?side=1&${q}`, { cache: "no-store" });
      const d = await r.json().catch(() => ({}));
      if (seq !== sd.suggestSeq || sd.nameEdited || !r.ok || !d.name) return;
      if (state.byName.has(d.name)) continue;
      sdEl.name.value = d.name;
      sdValidate();
      return;
    } catch { return; /* the name stays blank: sala suggests one at submit */ }
  }
}
// what the form still needs, in words: one of the two fields is needed (the backend's rule), a board item alone needs its project
function sdNeed() {
  const item = sdItemId(), fork = sdForkName();
  if (!item && !fork) return "Pick a board item, a session to fork, or both. sala needs one of them to know what the talk is about.";
  if (item && !SD_ITEM_RE.test(item)) return "That is not a board item id as the board shows it (board#N, sN).";
  if (fork && !SD_NAME_RE.test(fork)) return "That is not a session name.";
  if (!fork && !SD_PROJECT_RE.test(sdEl.project.value.trim())) return "A board item without a session to fork needs its project page: fill it in below.";
  return "";
}
function sdValidate() {
  const name = sdEl.name.value.trim();
  let err = "";
  if (name && (!SD_NAME_RE.test(name) || !name.includes("-side-") || name.length > 48)) err = "Lowercase letters, digits and dashes, with -side- in it, at most 48 characters; or leave it blank.";
  else if (name && state.byName.has(name)) err = `A session called ${name} is running already. Pick another name, or leave it blank.`;
  sdEl.nameErr.textContent = err;
  sdEl.extra.hidden = !(sdItemId() && !sdForkName());   // the project and the agents belong to an item without a fork
  const need = sdNeed();
  sdEl.need.textContent = need;
  const busy = nsBusyOf(sd.result);
  const ok = !err && !need && !sd.pending && !busy;
  nsBusyButton(sdEl.submit, busy || sd.pending);
  sdEl.submit.disabled = !ok;
  return ok;
}
async function sdSubmit(e) {
  e.preventDefault();
  if (sd.pending || !sdValidate()) return;
  const fork = sdForkName(), item = sdItemId(), body = { side: true };
  if (fork) { body.fork_of = fork; if (item) body.item = item; }
  else {
    body.project = sdEl.project.value.trim(); body.item = item;
    if (sdEl.agents.value.trim()) body.agents = sdEl.agents.value.trim();
  }
  if (sdEl.name.value.trim()) body.name = sdEl.name.value.trim();
  if (sdEl.mandate.value.trim()) body.mandate = sdEl.mandate.value;
  sd.pending = true; sdEl.pending.hidden = false; sdValidate();
  sdStopTrack();
  sd.result = { kind: "working" };
  sdRenderStatus();
  const out = await nsPost("api/spawn", body);
  if (out.status === 202 && out.d.ok) {
    sd.result = { kind: "queued", op: out.d.op, name: out.d.name, since: Date.now(), state: "queued", opState: "", opResult: "" };
    sdTrack();
  } else {
    sd.result = { kind: "failed", error: String(out.d.error || `HTTP ${out.status}`) };
  }
  sd.pending = false; sdEl.pending.hidden = true;
  sdRenderStatus(); sdValidate();
}
function sdStopTrack() { if (sd.track) { clearTimeout(sd.track); sd.track = null; } }
async function sdTrack() {
  sdStopTrack();
  const res = sd.result;
  if (!res || res.kind !== "queued") return;
  if (await nsPollStep(res, sdRenderStatus) || sd.result !== res) return;
  sd.track = setTimeout(sdTrack, nsPollDelay(Date.now() - res.since));
}
function sdRenderStatus() {
  const res = sd.result, kids = [], line = (cls, text) => el("div", { class: "ns-state " + cls, text });
  if (!res) { sdEl.status.replaceChildren(); return; }
  if (res.kind === "working") kids.push(line("pending", "Asking sala to queue the quick session…"));
  else if (res.kind === "failed") kids.push(line("failed", "Not started"), el("p", { text: "The quick session was not started. Check the reason below, then try again; if it fails twice, " + tellHelp() + "." }),
    el("p", { class: "ns-hint ns-reason", text: "Why: sala answered" }), el("div", { class: "ns-pre" }, el("pre", { class: "ns-why", text: res.error })));
  else {
    kids.push(...nsQueuedKids(res, {}));
    nsElapsedTick(res, sdEl.status, () => sd.result);
  }
  sdEl.status.replaceChildren(...kids);
  if (res.kind === "queued") nsFocusOpen(sdEl.status, res);
  if (sdEl.submit.getAttribute("aria-busy") !== String(nsBusyOf(res) || sd.pending)) sdValidate();   // Start's button follows the session's progress
}
sdEl.form.addEventListener("submit", sdSubmit);
for (const f of [sdEl.agents, sdEl.mandate]) f.addEventListener("input", sdValidate);
sdEl.project.addEventListener("input", () => { sdValidate(); clearTimeout(sd.sugTimer); sd.sugTimer = setTimeout(sdSuggest, 400); });
sdEl.name.addEventListener("input", () => { sd.nameEdited = sdEl.name.value.trim() !== ""; sdValidate(); });
// typing filters the listed rows at once; once it settles, stackshot is asked for the hidden matches of the text
nsEl.filter.addEventListener("input", () => {
  if (ns.pickedNew && !ns.nameEdited) nsEl.name.value = "";
  nsRenderProjects();
  if (ns.pickedNew) { nsSuggest(); nsValidate(); }
  clearTimeout(ns.qTimer);
  ns.qTimer = setTimeout(() => { if (nsEl.filter.value.trim() || ns.hiddenRows.length) nsLoadProjects(); }, NS_QUERY_MS);
});
// Enter in the box picks the first project shown (else the new-project row when a name is typed), never submits the form
nsEl.filter.addEventListener("keydown", (e) => {
  if (e.key !== "Enter" || e.isComposing) return;
  e.preventDefault();
  const first = nsEl.list.querySelector(".ns-opt:not(.ns-new):not([disabled])");
  if (first) nsPick(first.dataset.key);
  else if (ns.scope !== NS_ALL && nsNewDraft().slug) nsPickNew();
});
for (const r of document.querySelectorAll('input[name="ns-role"]')) r.addEventListener("change", () => { nsSuggest(); nsValidate(); });
nsEl.name.addEventListener("input", () => { ns.nameEdited = true; nsValidate(); });
nsEl.mandate.addEventListener("input", nsValidate);   // no keydown handler: Enter and Tab stay the browser's (a Korean IME needs them)
nsEl.model.addEventListener("change", nsValidate);
nsEl.modelOther.addEventListener("input", nsValidate);
nsEl.summary.addEventListener("click", () => nsFold(!ns.folded));   // the arrow: fold or open the project box
nsEl.form.addEventListener("submit", nsSubmit);

/* ---------- selection, hash, history ----------
   #s=<name> opens a session, #sessions the overview; no hash opens the overview in a wide browser (push mode; the hash
   is rewritten to #sessions in place), a phone or the installed app opens on the view it was last on (below).

   What Back does (revised twice). Two
   modes, read live at every decision (a resize or a rotation changes the next action; entries already made stay):
   - Replace mode: a phone (the drawer layout, max-width 760px) in any browser, and the installed app (display-mode
     standalone) at any width. The sessions and the Overview are peer views of ONE history entry: go() replaces it, so
     Back never walks between views. Back closes the top layer and stays; with no layer open it leaves sala (the app
     exits). Nothing intercepts that Back (no beforeunload), and nothing is pushed on a launch.
   - Push mode: a desktop browser, a tablet browser, a phone in landscape wider than 760px. Every view is an entry (the
     Overview too), so the browser's Back and Forward walk the sessions visited, as claude.ai and chatgpt.com do.
   A layer is something laid over the view that Back should close first: the sidebar drawer (a phone only; on a wide
   screen the sidebar is part of the page, so a wide screen has no layer). Each open layer is one pushed entry, with the same URL and the layers named in history.state. Back closes
   the top one, so one Back closes one layer. A layer closed another way (its button, the scrim, Escape) has its entry
   popped at once, so the next Back is not spent on an entry that changes nothing. Entries are pushed from taps only: a
   browser skips entries pushed without a user gesture (Chromium's history manipulation intervention). A navigation
   while a layer is open first goes back under the layers (nav.pending), then replaces or pushes; the entries popped stay
   ahead as Forward entries, as after any Back (no API truncates them without a push), and Forward re-opens their layers
   over the view that is shown (a Forward entry of another view keeps the view).
   Layers are a registry (defineLayer): the history primitives and the handlers know no kind by name, so another (an image
   viewer; sala has none, thumbnails open in a new tab) is one more defineLayer.
   A phone or the installed app opens on the view it was last on (localStorage salaweb.lastView, written on every view),
   with the sidebar closed: a session still live, else the Overview. The result is written to the launch entry, so a
   reload keeps it. A wide browser (push mode) has no last view to keep: with no hash it opens on the Overview, #sessions
   written over the launch entry with replaceState (no entry added, so the nav base is #sessions and Back from it leaves
   sala, as for a #sessions deep link). A deep link (#s=<name>, #sessions) wins over it. A reload with layers recorded leaves them (the
   entries under the page are walked back over at once): Back then leaves, with no dead entry under it.
   A hash change sala did not make (the address bar, a script; every link in the page goes through go) arrives as the
   browser's own pushed entry with no state. It is taken as it is and recorded. history.state is {sala: {layers, idx}},
   idx growing with every push so a popstate knows whether it travelled back or forward; layers the open layers, bottom
   first ("drawer"). An entry of an earlier build may also list an items sheet ({sheet: name}), a layer that is gone: navRecord drops what is not defined. An entry of the first build (depth, base, overlays) reads as no layers. The
   Chat/Terminal toggle and the ⋯ menu touch no history (the menu is a dropdown a tap outside closes, not a page).
   Tests: tests/test_back_button.py. */
function hashName(h = location.hash) {
  const m = /(?:^|&)s=([^&]*)/.exec(h.slice(1));
  if (!m) return null;
  try { return decodeURIComponent(m[1]); } catch { return m[1]; }
}
const schedulesHash = (h = location.hash) => h === "#schedules";        // the Overview's Schedules tab (it was a page of its own once, so an old link lands here)
// #search?q=…: the Search results page, a page of its own (search.js); the query and the filters are in the address
const searchHash = (h = location.hash) => h === "#search" || h.startsWith("#search?");
const machinesHash = (h = location.hash) => h === "#machines";              // the Overview's Machines tab
const usageHash = (h = location.hash) => h === "#usage";                    // the Overview's Usage analysis tab
const overviewHash = () => location.hash === "#sessions" || schedulesHash() || machinesHash() || usageHash();   // any of the Overview's four tabs
const TAB_HASH = { sessions: "#sessions", schedules: "#schedules", machines: "#machines", usage: "#usage" };    // each tab's link
// #lane=<id>: a lane's details page, a view of the Overview's pane; null for any other hash
function laneHashId(h = location.hash) {
  const m = /^#lane=([^&]*)$/.exec(h);
  if (!m) return null;
  try { return laneNorm(decodeURIComponent(m[1])) || null; } catch { return laneNorm(m[1]) || null; }
}
const overviewFamily = () => overviewHash() || laneHashId() !== null;
// #new: the New session page, a view of its own in the main area (not a layer: it has a link, so a reload and a
// shared link open it); every in-page navigation to it is an entry (go), so Back returns to the view it was opened from
const sideHash = (h = location.hash) => h.startsWith("#side=");   // a side conversation: the New session page's other form
const newHash = (h = location.hash) => h === "#new";
const newPageHash = (h = location.hash) => newHash(h) || sideHash(h);   // either form of the New session page
// the view last shown, kept across launches (the installed app reopens on it)
const LAST_VIEW = "salaweb.lastView";
function rememberView(h) { try { localStorage.setItem(LAST_VIEW, h); } catch { /* storage unavailable */ } }
function rememberedView() { try { return localStorage.getItem(LAST_VIEW) || ""; } catch { return ""; } }
// the page for the hash: the overview once, or a session (selectSession is a no-op for the open one)
function route() {
  if (newPageHash()) { showNewPage(); sdMode(); }
  else if (searchHash()) showSearchPage();
  else if (overviewFamily()) {
    if (!document.body.classList.contains("overview-open")) showOverview();
    overview.showLane(laneHashId());  // a lane's details page, or (null) the Overview itself
    // #schedules, #machines and #usage open the Overview on their tabs
    setOverviewTab(laneHashId() !== null ? "sessions" : schedulesHash() ? "schedules" : machinesHash() ? "machines" : usageHash() ? "usage" : "sessions");
    setOverviewTitle();
  } else selectSession(hashName());
  if (overviewHash() || hashName()) rememberView(location.hash);
}
// phone portrait in any browser, or the installed app at any width: one entry for the views. Else a browser with its
// own Back button: an entry per view.
const replaceMode = () => narrow() || window.matchMedia("(display-mode: standalone)").matches;

const NAV_STUCK_MS = 1000;
const nav = { cur: null, pending: null, busy: null, idx: 0, reload: 0, laneIdx: -1 };  // cur: this entry's record; busy: the timer while a history.go is in flight; reload: layers the entry had when the page loaded; laneIdx: the idx of the entry a lane's page was pushed on from the Overview
const layers = {};  // kind -> { isOpen(rec?), show(rec), hide(), close() } ; close is the user's (hides and pops the entry)
const layerKind = (r) => (typeof r === "string" ? r : r && typeof r === "object" ? Object.keys(r)[0] : "");
function defineLayer(kind, impl) { layers[kind] = impl; }
const layerOpen = (r) => { const l = layers[layerKind(r)]; return !!l && l.isOpen(r); };
const navRecord = (s) => {
  const r = s && s.sala;
  if (!r || typeof r !== "object" || typeof r.idx !== "number") return null;
  return { layers: Array.isArray(r.layers) ? r.layers.filter((x) => layers[layerKind(x)]) : [], idx: r.idx };
};
function navWrite(st, hash, push) {
  nav.cur = st;
  try { history[push ? "pushState" : "replaceState"]({ sala: st }, "", location.pathname + location.search + (hash || "")); }
  catch { /* a browser refusing (too many writes in a row): the page still changes */ }
}
function navBack(n) {
  clearTimeout(nav.busy);
  nav.busy = setTimeout(navStuck, NAV_STUCK_MS);
  history.go(-n);
}
function hideLayers() { for (const l of Object.values(layers)) if (l.isOpen()) l.hide(); }
// no popstate came: the entries under this one are not there (a history the browser cut, a record out of step with
// it); carry on from the entry we are on, its layers taken as closed
function navStuck() {
  nav.busy = null;
  hideLayers();
  navWrite({ layers: [], idx: (navRecord(history.state) || nav.cur).idx }, location.hash, false);
  const h = nav.pending;
  nav.pending = null;
  if (h !== null) go(h); else route();
}
// an in-page navigation to #s=<name> or #sessions, by the rules above; push: an entry in either mode (a search result opened
// from the results page, so Back from its chat returns to the results on a phone too)
function go(hash, { push = false } = {}) {
  const st = nav.cur, down = st.layers.length;  // the layer entries on top of this one
  if (nav.busy || down) {
    nav.pending = hash;
    if (!nav.busy) navBack(down);
    return;
  }
  if (hash === location.hash) { route(); return; }  // where we are already
  const fromOverview = Object.values(TAB_HASH).includes(shownHash());
  if (replaceMode() && !push && !newPageHash(hash)) navWrite({ layers: [], idx: st.idx }, hash, false);   // the page for #new is an entry in either mode: Back returns from it
  else navWrite({ layers: [], idx: ++nav.idx }, hash, true);
  // a lane's page opened from the Overview in push mode: the entry under it is the Overview, so its Back button is the browser's Back
  nav.laneIdx = fromOverview && !replaceMode() && laneHashId(hash) !== null ? nav.idx : -1;
  route();
}
function pushLayer(r) {
  if (nav.busy) return;  // a pop in flight: this entry is about to go; nothing to put on it
  navWrite({ layers: [...nav.cur.layers, r], idx: ++nav.idx }, location.hash, true);
}
function retagLayer(kind, r) {
  navWrite({ layers: nav.cur.layers.map((x) => (layerKind(x) === kind ? r : x)), idx: nav.cur.idx }, location.hash, false);
}
function popLayer(kind) {
  const st = nav.cur, top = st.layers[st.layers.length - 1];
  if (top !== undefined && layerKind(top) === kind && !nav.busy) { navBack(1); return; }
  // closed under another layer, or while a pop is in flight: out of this entry's record; its own entry below is
  // then stale, and a Back onto it skips it
  const left = st.layers.filter((x) => layerKind(x) !== kind);
  if (left.length !== st.layers.length) navWrite({ layers: left, idx: st.idx }, location.hash, false);
}
// Escape: the top layer, one per press (the record's order, else whatever is open, the last defined first)
function closeTopLayer() {
  const kinds = [...(nav.cur ? nav.cur.layers : []).map(layerKind).reverse(), ...Object.keys(layers).reverse()];
  const k = kinds.find((x) => layers[x] && layers[x].isOpen());
  if (k) layers[k].close();
}
// the page's layers as the entry lists them: travelling back, what it does not list closes and an entry listing one
// that is not open is stale and skipped (true); forward, what it lists opens again
function syncLayers(st, back) {
  const wanted = (kind) => st.layers.find((x) => layerKind(x) === kind);
  for (const [kind, l] of Object.entries(layers)) if (!wanted(kind) && l.isOpen()) l.hide();
  const missing = st.layers.some((x) => !layerOpen(x));
  if (missing && back) { navBack(1); return true; }
  for (const x of st.layers) if (!layerOpen(x)) layers[layerKind(x)].show(x);
  return false;
}
// the hash of the page shown now (what route() last drew)
const shownHash = () => (document.body.classList.contains("new-open") ? (sideHash() ? location.hash : "#new") : document.body.classList.contains("search-open") ? searchAt
  : document.body.classList.contains("overview-open")
  ? (overview.laneId() !== null ? "#lane=" + encodeURIComponent(overview.laneId()) : TAB_HASH[overviewTab] || "#sessions")
  : (state.selected ? "#s=" + encodeURIComponent(state.selected) : ""));
window.addEventListener("popstate", (e) => {
  const was = nav.cur;
  if (!was) return;  // before init: init routes from the hash and the state it finds
  clearTimeout(nav.busy); nav.busy = null;
  let st = navRecord(e.state);
  if (!st) {
    // an entry without a record (above): the same place again is a same-hash navigation that wiped the record, put
    // back; else the entry is taken as it is and recorded
    if (location.hash === shownHash()) { navWrite(was, location.hash, false); return; }
    nav.pending = null;
    st = { layers: [], idx: ++nav.idx };
    navWrite(st, location.hash, false);
  } else if (replaceMode() && st.layers.length && location.hash !== shownHash()) {
    // a Forward entry of a view since replaced: it keeps the view that is shown and re-opens its layers over it
    navWrite(st, shownHash(), false);
  } else nav.cur = st;
  if (syncLayers(st, st.idx < was.idx)) return;
  if (nav.pending !== null) { const h = nav.pending; nav.pending = null; go(h); return; }
  if (location.hash !== shownHash()) route();  // a layer's entry has the page's own hash: nothing to redraw
});
// a plain click on an in-page link to a session or the overview is sala's (go); a modified click, another target or
// another page is the browser's. A link with target=_blank still counts when it points at sala's own page and route
// (a link in a reply: every link there is made target=_blank, for the off-origin ones): on a phone the
// installed app would open it in Chrome's in-app view, on a desktop in a new tab, and it should stay in sala. The
// same-page, same-route test below is what keeps a stackshot or GitHub link (another origin) outside.
document.addEventListener("click", (e) => {
  if (e.defaultPrevented || e.button !== 0 || e.ctrlKey || e.metaKey || e.shiftKey || e.altKey) return;
  const a = e.target.closest("a[href]");
  if (!a || (a.target && a.target !== "_self" && a.target !== "_blank") || a.origin !== location.origin || a.pathname !== location.pathname || a.search !== location.search) return;
  if (!(a.hash === "#sessions" || a.hash === "#schedules" || a.hash === "#machines" || searchHash(a.hash) || a.hash === "#new" || sideHash(a.hash) || a.hash.startsWith("#s=") || laneHashId(a.hash) !== null)) return;
  e.preventDefault();
  // the lane page's Back button, when the Overview is the entry under it: the browser's Back, so the history keeps no
  // second Overview entry; else it is the link it looks like
  if (a.id === "ld-back" && !replaceMode() && nav.laneIdx === nav.cur.idx && !nav.cur.layers.length && !nav.busy) { navBack(1); return; }
  go(a.hash);
});
// the sidebar drawer: a phone's sidebar slides over the page. Open or not is the body's class, whatever the width (the
// widening handler runs after the media query flipped)
const drawerIsOpen = () => document.body.classList.contains("side-open");
function setDrawer(on) {
  const was = drawerIsOpen();
  document.body.classList.toggle("side-open", on);
  if (!on && was && $("#sidebar").contains(document.activeElement) && $("#side-open").offsetParent) $("#side-open").focus({ preventScroll: true });
}
function showDrawer() { setDrawer(true); $("#side-close").focus({ preventScroll: true }); }
function openDrawer() { showDrawer(); pushLayer("drawer"); }
function closeDrawer() { setDrawer(false); popLayer("drawer"); }
defineLayer("drawer", { isOpen: drawerIsOpen, show: () => { if (narrow()) showDrawer(); }, hide: () => setDrawer(false), close: closeDrawer });

// this entry's record, read before anything else runs: layers an earlier page left on it are not opened again (init
// walks back over them), the entry is made for a first load
(function navInit() {
  const st = navRecord(history.state);
  nav.reload = st ? st.layers.length : 0;
  nav.cur = { layers: [], idx: st ? st.idx : 0 };
  nav.idx = nav.cur.idx;
  if (!st) navWrite(nav.cur, location.hash, false);
})();

// a page (the overview, the New session page) replaces the session in the main area: its stream and terminal close, and
// no session is selected
function leaveSession() {
  leaveComposer();
  if (state.es) { state.es.close(); state.es = null; }
  clearTimeout(reopen.timer); reopen.timer = null;
  setConn("sse", false);
  clearStatus();
  state.selected = null;
  state.current = null;
  state.modelInfo = null; updateModelLine();
  state.termLoadedFor = null;
  $("#terminal-pane").replaceChildren();
  $("#chat").replaceChildren(el("div", { class: "empty", text: "Pick a session on the left." }));
}
function showOverview() {
  perfMark("overview");
  leaveSession();
  setNewPage(false);
  setSearchPage(false);
  setOverview(true);
  renderSidebar();
  setTitle("Overview");
  $("#title .name").textContent = "Overview";
  clearHeaderBadges();
  layoutHeader();
  updateJump();
}
// the New session page (#new): shown once; route() calls it again for a same-hash navigation and it changes nothing
function showNewPage() {
  if (document.body.classList.contains("new-open")) return;
  perfMark("new");
  if (state.selected) ns.from = state.selected;
  leaveSession();
  setOverview(false);
  setSearchPage(false);
  setNewPage(true);
  renderSidebar();
  setTitle("New session");
  $("#title .name").textContent = "New session";
  clearHeaderBadges();
  layoutHeader();
  updateJump();
}
// the Search results page (#search?…): shown for every address of it; search.js draws the search the address describes (a filter
// change on the page rewrites the address in place, replaceHash, and searchAt follows it)
let searchAt = "";
function showSearchPage() {
  searchAt = location.hash;
  if (!document.body.classList.contains("search-open")) {
    perfMark("search");
    leaveSession();
    setOverview(false);
    setNewPage(false);
    setSearchPage(true);
    renderSidebar();
    setTitle("Search");
    $("#title .name").textContent = "Search";
    clearHeaderBadges();
      layoutHeader();
    updateJump();
  }
  search.show(location.hash);
}
function setSearchPage(on) {
  if (document.body.classList.contains("search-open") === on) return;
  document.body.classList.toggle("search-open", on);
  if (on) setTopMenu(false); else search.hide();
}
// the page's own address changed in place (a filter on the Search page): the entry is rewritten, no entry is added
function replaceHash(h) {
  if (h === location.hash) return;
  searchAt = h;
  navWrite(nav.cur, h, false);
}
function setNewPage(on) {
  if (document.body.classList.contains("new-open") === on) return;
  document.body.classList.toggle("new-open", on);
  $("#side-new").classList.toggle("selected", on);
  if (on) { $("#side-new").setAttribute("aria-current", "page"); setTopMenu(false); nsShow(); }
  else { $("#side-new").removeAttribute("aria-current"); nsHide(); document.body.classList.remove("side-mode"); }
}
// the header's name and the tab's title: "Overview", or "Lane <label>" on a lane's details page
function setOverviewTitle() {
  const id = overview.laneId(), t = id === null ? "Overview" : "Lane " + laneLabel(id);
  setTitle(t);
  $("#title .name").textContent = t;
}
/* the Overview's four tabs: "sessions" (Agents, #sessions), "schedules" (#schedules), "machines" (#machines) and "usage" (Usage analysis, #usage). The pane's data-tab shows the
   one panel (sessions.css); the Schedules, Machines and Usage tabs read their api when they open, and again on their Reload, never by themselves, so
   schedules.start() / machines.start() / usage.start() run on the change to the tab only and .stop() on any change away (the Overview closing included).
   Search is not a tab: it is the sidebar's box and a page of its own (search.js) */
const OV_TABS = ["sessions", "schedules", "machines", "usage"];
let overviewTab = "sessions";
function setOverviewTab(tab) {
  const was = overviewTab;
  overviewTab = tab;
  $("#overview-pane").dataset.tab = tab;
  for (const t of OV_TABS) {
    const a = $("#ov-tab-" + t);
    a.setAttribute("aria-selected", String(t === tab));
    a.tabIndex = t === tab ? 0 : -1;
  }
  if (tab === was) return;
  if (tab === "schedules") schedules.start(); else if (was === "schedules") schedules.stop();
  if (tab === "machines") machines.start(); else if (was === "machines") machines.stop();
  if (tab === "usage") usage.start(); else if (was === "usage") usage.stop();
}
// arrow keys move between the tabs, as a tab list does (each is a link: Back, a reload and a shared link reach it)
$("#overview-pane .ov-tabs").addEventListener("keydown", (e) => {
  if (e.key !== "ArrowLeft" && e.key !== "ArrowRight") return;
  e.preventDefault();
  const to = OV_TABS[(OV_TABS.indexOf(overviewTab) + (e.key === "ArrowRight" ? 1 : OV_TABS.length - 1)) % OV_TABS.length];
  go(TAB_HASH[to]);
  $("#ov-tab-" + to).focus();
});
function setOverview(on) {
  document.body.classList.toggle("overview-open", on);
  if (!on) setOverviewTab("sessions");
  $("#side-ovw").classList.toggle("selected", on);
  if (on) { $("#side-ovw").setAttribute("aria-current", "page"); setTopMenu(false); overview.start(); }
  else { $("#side-ovw").removeAttribute("aria-current"); overview.stop(); }
}

function selectSession(name, { force = false } = {}) {
  setOverview(false);
  setNewPage(false);
  setSearchPage(false);
  if (!force && name === state.selected && state.es) return;
  aheadStop();   // a chat opened far back (a Search result) ends with its stream
  const switching = name !== state.selected;
  if (switching) {
    chatScroll.pinned = true; leaveComposer();  // opening a session lands at the bottom; the old one's draft is kept
    if (state.selected && !document.hidden) markRead(state.selected, { force: true });  // a reply that came in while it was open is read too
  }
  state.selected = name;
  if (!document.hidden) markRead(name, { force: true });  // opening a session reads its latest reply
  if (switching) restoreDraft(name);
  state.modelInfo = null; updateModelLine();
  const s = state.byName.get(name);
  perfMark("select", { session: name || "", live: !!s, force });
  if (state.es) { state.es.close(); state.es = null; }
  clearTimeout(reopen.timer); reopen.timer = null;
  setConn("sse", false);
  clearStatus();
  renderSidebar();
  const chat = $("#chat");
  if (!s) {
    state.current = null;
    setTitle(name || "sala");
    $("#title .name").textContent = name ? name + " (not running)" : "Select a session";
    clearHeaderBadges();
      $("#title .dot").className = "dot";
    layoutHeader();
    // a session link that outlived its session (an old bookmark, a stale launch view): the way out is a link, not Back
    chat.replaceChildren(name ? el("div", { class: "empty" }, "That session is not live. ", el("a", { href: "#sessions", text: "Open the Overview" }))
                              : el("div", { class: "empty", text: "Pick a session on the left." }));
    updateJump();
    return;
  }
  updateHeader(s);
  chat.replaceChildren(el("div", { class: "empty", text: "Loading transcript…" }));
  updateJump();
  if (state.tab === "terminal") loadTerminal(); // otherwise the iframe loads on first open of the tab
  openStream(s);
}

// The stream drops when the server restarts (a deploy). EventSource reconnects by itself (the server asks for a
// 1 s retry); if the browser gives up (an error status during the restart) we reopen it, backing off to 15 s.
// The first "reset" on a reconnected stream replaces the chat with the same tail, so it keeps the scroll state:
// pinned stays at the bottom, a reader scrolled up keeps the message they were reading in place.
const reopen = { timer: null, delay: 1000 };
function openStream(s, { resume = false } = {}) {
  perfMark("stream:open", { pid: s.pid, resume });
  const es = new EventSource(`api/s/${s.pid}/stream`);
  state.es = es;
  let opens = 0;
  let resumeReset = false;
  let events = 0;
  es.addEventListener("open", () => {
    opens++;
    perfMark("stream:opened", { opens });
    resumeReset = resume || opens > 1;
    reopen.delay = 1000;
    setConn("sse", false);
  });
  es.addEventListener("error", () => {
    if (state.es !== es) return;
    perfMark("stream:error", { state: es.readyState });
    setConn("sse", true);
    if (es.readyState === EventSource.CLOSED) scheduleReopen(s.name);
  });
  es.addEventListener("version", (e) => {
    if (!events++) perfMark("stream:first-event");  // the server's first event on every stream
    try { noteVersion(JSON.parse(e.data).version); } catch { /* ignore */ }
  });
  es.addEventListener("reset", (e) => {
    const t0 = performance.now();
    const d = JSON.parse(e.data);
    perfMark("stream:reset", { count: d.messages.length, bytes: e.data.length, resumed: resumeReset });
    const resumed = resumeReset;
    resumeReset = false;
    const sid = d.session ? d.session.sessionId : null;
    if (ahead.active && ahead.pid === s.pid) {
      // the chat is open far back (a Search result): it stays where it is read, and this tail waits for the newer pages to meet it
      if (sid === ahead.sid) { ahead.buffer = d.messages.slice(); return; }
      aheadStop();   // another transcript (a /clear): the view's cursors mean nothing in it
    }
    const f = state.focusAt && state.focusAt.name === s.name ? state.focusAt : null;
    if (f && Number.isInteger(f.pos) && f.session === sid && !d.messages.some((m) => m.uuid === f.uuid)) {
      openAround(s, f, d);   // the entry is older than the tail: load the page around it instead
      return;
    }
    showTail(s, d, resumed, t0, e.data.length);
  });
  es.addEventListener("append", (e) => {
    const d = JSON.parse(e.data);
    if (ahead.active && ahead.pid === s.pid) { ahead.buffer.push(...d.messages); return; }   // shown when the newer pages reach the live end
    const empty = $("#chat > .empty");
    if (empty && d.messages.length) empty.remove();
    let added = 0;
    for (const m of d.messages) added += renderMessage(m, { live: true }) ? 1 : 0;
    perfMark("stream:append", { count: d.messages.length, added, bytes: e.data.length });
    if (chatScroll.pinned) { if (state.tab === "chat") scrollToBottom(); }
    else if (added) chatScroll.unseen = true;
    updateJump();
  });
  es.addEventListener("live", (e) => {
    if (state.es !== es) return;
    let d; try { d = JSON.parse(e.data); } catch { return; }
    if (ahead.active && ahead.pid === s.pid) { ahead.live = d; return; }   // the live block belongs under the live end, not this page
    applyLive(d);
  });
  es.addEventListener("status", (e) => {
    const d = JSON.parse(e.data);
    if (state.current && state.current.pid === s.pid) { state.current.status = d.status; updateHeader(state.current); }
    const row = state.byName.get(s.name); if (row) { row.status = d.status; renderSidebar(); }
  });
  es.addEventListener("gone", () => {
    perfMark("stream:gone");
    es.close();
    if (state.es === es) { state.es = null; setConn("sse", false); }
    setStatus("The session ended.", "error");
    loadSessions();
  });
}
/* the stream's tail shown as the chat (a "reset"): resumed = a reconnect of the same chat, which keeps the reader's place */
function showTail(s, d, resumed, t0 = performance.now(), bytes = 0) {
  const chat = $("#chat");
  const keep = resumed && state.tab === "chat" && !chatScroll.pinned ? scrollAnchor() : null;
  const lastBefore = lastUuid();
  // built detached and swapped in at once: 200 inserts into the live chat each rescanned it for the pending
  // bubbles and the tool call a result belongs to, and each invalidated style (measured Wed Oct 14th 2026)
  const frag = document.createDocumentFragment();
  const tools = new Map();
  for (const m of d.messages) renderMessage(m, { into: frag, tools });
  chat.replaceChildren(frag);
  for (const p of state.pending) if (p.session === s.name) chat.append(p.node);  // not in the transcript yet
  if (!chat.children.length) chat.append(el("div", { class: "empty", text: d.note || "No messages yet." }));
  olderReset(d.messages.length ? s.pid : null, d);  // the line at the top that loads older messages as it comes into view
  updateInflight();
  if (!resumed) { chatScroll.pinned = true; chatScroll.unseen = false; }
  if (chatScroll.pinned) { if (state.tab === "chat") scrollToBottom(); }
  else {
    if (keep) restoreAnchor(keep);
    if (lastUuid() !== lastBefore) chatScroll.unseen = true;  // messages came in while the stream was down
  }
  if (state.focusAt && state.focusAt.name === s.name) focusEntry(chat);   // a Search result opened this chat at an entry
  updateJump();
  perfMark("history:rendered", { count: d.messages.length, bytes, ms: Math.round(performance.now() - t0) });
  requestAnimationFrame(() => requestAnimationFrame(() => perfMark("history:painted", { count: d.messages.length })));
}
function scheduleReopen(name) {
  clearTimeout(reopen.timer);
  const stillDown = () => state.selected === name && (!state.es || state.es.readyState === EventSource.CLOSED);
  reopen.timer = setTimeout(async () => {
    reopen.timer = null;
    if (!stillDown()) return;
    reopen.delay = Math.min(reopen.delay * 2, 15000);
    await loadSessions();  // a relaunched session has a new pid: loadSessions reselects it
    if (!stillDown()) return;
    const s = state.byName.get(name);
    if (!s) { selectSession(name, { force: true }); return; }
    openStream(s, { resume: true });
  }, reopen.delay);
}
/* Open a session's chat at an entry, for a Search result (search.js calls openAt). uuid: the entry to light (for a subagent's result, the
   Agent/Task call that started it); place: {pos, session}, the entry's line in the session's transcript (a byte offset, the cursor
   GET transcript?around= takes) and the Claude session id that transcript is of. The stream's "reset" brings the last 200 messages:
   an entry among them is scrolled to there; an older one opens the chat AROUND it (openAround: older pages above as the chat is
   scrolled up, newer ones below as it is scrolled down, until they meet the live end and live updates show again). An entry in an
   earlier conversation of the session (before a /clear: another transcript) is not in its chat: the chat opens at its latest message
   and a line in the status strip says so; an entry the chat never shows (the page around it loaded, but it is not among the
   messages) says "not shown in this chat; it opens where it was". A tool call the chat hides (Show tools off) leaves the view at the message before it. The
   entry is scrolled to the middle, unpinned, and lit for a few seconds (.search-hit). */
function openAt(name, uuid, place = null) {
  if (!uuid) { state.focusAt = null; go("#s=" + encodeURIComponent(name), { push: !!(place && place.push) }); return; }   // no entry to find: just the chat
  const pos = place && Number.isInteger(place.pos) ? place.pos : null;
  const f = state.focusAt = { name, uuid, pos, session: place ? place.session || null : null };
  const open = state.selected === name && !!state.es;   // its chat is loaded already: no "reset" is coming
  go("#s=" + encodeURIComponent(name), { push: !!(place && place.push) });
  if (open && state.focusAt === f) {
    const s = state.current;
    const here = $("#chat").querySelector(`:scope > .msg[data-uuid="${CSS.escape(uuid)}"]`);
    if (!here && pos !== null && s && s.sessionId === f.session) selectSession(name, { force: true });   // a fresh reset, then openAround
    else focusEntry($("#chat"));
    return;
  }
  setTimeout(() => { if (state.focusAt === f) state.focusAt = null; }, 15000);   // the chat never loaded: forget it
}
function focusEntry(chat) {
  const f = state.focusAt;
  state.focusAt = null;
  let m = f.uuid ? chat.querySelector(`:scope > .msg[data-uuid="${CSS.escape(f.uuid)}"]`) : null;
  while (m && m.offsetParent === null) m = m.previousElementSibling;   // a hidden tool row: the nearest one shown before it
  if (m && !m.classList.contains("msg")) m = null;
  if (!m) {
    const s = state.current;
    setStatus(f.session && s && s.sessionId && s.sessionId !== f.session
      ? "That entry is from an earlier conversation of this session (before a /clear); the chat shows the current one."
      : ahead.active   // opened around the entry (openAround): the chat is where the entry was, it just does not show it
        ? "That entry is not shown in this chat; it opens where it was."
        : "That entry is not in this chat; it opens at the latest messages.", "");
    return;
  }
  chatScroll.pinned = false;
  m.scrollIntoView({ block: "center" });
  chatScroll.lastTop = pane().scrollTop;
  m.classList.add("search-hit");
  setTimeout(() => m.classList.remove("search-hit"), 4000);
}

const lastUuid = () => { const xs = $("#chat").querySelectorAll(":scope > .msg[data-uuid]"); return xs.length ? xs[xs.length - 1].dataset.uuid : null; };
function scrollAnchor() {
  const p = pane();
  const top = p.getBoundingClientRect().top;
  for (const m of $("#chat").querySelectorAll(":scope > .msg[data-uuid]")) {
    const r = m.getBoundingClientRect();
    if (r.bottom > top) return { uuid: m.dataset.uuid, off: r.top - top, scrollTop: p.scrollTop };
  }
  return { uuid: null, off: 0, scrollTop: p.scrollTop };
}
function restoreAnchor(a) {
  const p = pane();
  const m = a.uuid && $("#chat").querySelector(`:scope > .msg[data-uuid="${CSS.escape(a.uuid)}"]`);
  if (m) p.scrollTop += m.getBoundingClientRect().top - p.getBoundingClientRect().top - a.off;
  else p.scrollTop = a.scrollTop;
  chatScroll.lastTop = p.scrollTop;
}

/* ---------- chat scroll: pinned to the bottom like a chat app ---------- */
// Pinned: the view follows the bottom (on open, as late content such as images changes height, on new messages).
// Only the user scrolling up unpins; reaching the bottom again re-pins. Programmatic scrolls only ever go down,
// so they cannot unpin.
const chatScroll = { pinned: true, unseen: false, lastTop: 0, savedTop: 0, toggledAt: 0 };
const NEAR_BOTTOM = 80;
const pane = () => $("#chat-pane");
const distFromBottom = () => { const p = pane(); return p.scrollHeight - p.scrollTop - p.clientHeight; };
function scrollToBottom() { const p = pane(); p.scrollTop = p.scrollHeight; chatScroll.lastTop = p.scrollTop; }
function pinToBottom() { if (ahead.active) { goLive(); return; } chatScroll.pinned = true; chatScroll.unseen = false; if (state.tab === "chat") scrollToBottom(); updateJump(); }
function updateJump() {
  const b = $("#jump");
  const show = state.tab === "chat" && !!state.current && !chatScroll.pinned && (ahead.active || distFromBottom() > NEAR_BOTTOM);
  b.hidden = !show;
  b.textContent = chatScroll.unseen ? "↓ New messages" : "↓";
  b.classList.toggle("wide", chatScroll.unseen);
}
pane().addEventListener("scroll", () => {
  const p = pane();
  if (state.tab !== "chat" || !p.clientHeight) return;
  if (ahead.active) chatScroll.pinned = false;   // far back: the bottom is a page's end, not the live end
  else if (distFromBottom() < NEAR_BOTTOM) { chatScroll.pinned = true; chatScroll.unseen = false; }
  else if (p.scrollTop < chatScroll.lastTop) chatScroll.pinned = false;
  chatScroll.lastTop = p.scrollTop;
  updateJump();
}, { passive: true });
// Re-scroll while pinned whenever the content or the viewport changes size (images, fonts, the composer growing,
// the phone keyboard). It runs after layout and before paint, so nothing visibly jumps.
new ResizeObserver(() => {
  if (state.tab !== "chat" || !pane().clientHeight) return;
  if (performance.now() - chatScroll.toggledAt < 400) {
    // the user opened or closed a fold: leave the view where it is
    chatScroll.pinned = !ahead.active && distFromBottom() < NEAR_BOTTOM;
  } else if (chatScroll.pinned) scrollToBottom();
  updateJump();
}).observe($("#chat"));
new ResizeObserver(() => { if (chatScroll.pinned && state.tab === "chat" && pane().clientHeight) scrollToBottom(); updateJump(); }).observe(pane());
// footer links that wrap lose their ::after tap area (markWrappedLinks): when a message is added, and when the chat's width
// changes (a resize, a browser zoom, the sidebar), which is the only thing that moves a line break; not on its height
new MutationObserver((recs) => markWrappedLinks(...recs.flatMap((r) => [...r.addedNodes].filter((n) => n.nodeType === 1))))
  .observe($("#chat"), { childList: true });
let chatWidth = -1;
new ResizeObserver(() => { const w = $("#chat").clientWidth; if (w !== chatWidth) { chatWidth = w; markWrappedLinks($("#chat")); } }).observe($("#chat"));
$("#chat").addEventListener("click", (e) => { if (e.target.closest("summary")) chatScroll.toggledAt = performance.now(); });
$("#jump").addEventListener("click", pinToBottom);

/* ---------- older messages: a page at a time as the chat is scrolled to its top ---------- */
// The stream's reset carries the last 200 messages and `before`, a cursor (a byte offset into the session's transcript)
// for the page that ends where they begin; `start` says the file's start is already in. A line at the top of the chat
// (.older) is watched: when it comes within OLDER_MARGIN px of the view, GET transcript?before=<cursor> fetches the 200
// messages before it, one fetch at a time, and they go in above the oldest shown with the reading position kept (the
// first message in view stays where it was on the screen, whatever the browser's own scroll anchoring did). At the
// file's start the line reads "Start of this conversation" and nothing more is fetched. Earlier conversations (before a
// /clear: another transcript file) are not loaded. A reset (a reconnect, another session) starts it over, and a fetch
// still running for the old one is dropped (gen).
const OLDER_MARGIN = 300;
const older = { pid: null, before: null, start: true, loading: false, gen: 0, failed: false };
const olderObs = new IntersectionObserver((es) => {
  if (es.some((e) => e.isIntersecting)) loadOlder();
}, { root: pane(), rootMargin: `${OLDER_MARGIN}px 0px 0px 0px` });
function olderLine() {
  const n = $("#chat > .older");
  if (!n) return;
  n.textContent = older.loading ? "Loading older messages…" : older.start ? "Start of this conversation"
    : older.failed ? "Could not load older messages. Scroll up to try again." : "";
  n.classList.toggle("at-start", older.start && !older.loading);
}
// pid null: no history to page (no messages, no session); d: the reset's {before, start}
function olderReset(pid, d) {
  older.gen++;
  older.loading = false; older.failed = false;
  olderObs.disconnect();
  if (pid == null || !d) { older.pid = null; older.before = null; older.start = true; return; }
  older.pid = pid;
  // an older server sends no cursor: nothing to page, and no marker either
  older.before = Number.isInteger(d.before) ? d.before : null;
  older.start = older.before === null || !!d.start;
  if (older.before === null) return;
  const line = el("div", { class: "older", role: "status", "aria-live": "polite" });
  $("#chat").prepend(line);
  olderLine();
  if (!older.start) olderObs.observe(line);
}
// the sentinel is within reach of the view (the observer fires only when that changes: a short page is checked again here)
function olderInReach() {
  const n = $("#chat > .older"), p = pane();
  if (!n || state.tab !== "chat" || !p.clientHeight) return false;
  return n.getBoundingClientRect().bottom > p.getBoundingClientRect().top - OLDER_MARGIN;
}
async function loadOlder() {
  if (older.loading || older.start || older.before === null || older.pid === null) return;
  if (state.tab !== "chat" || !pane().clientHeight) return;  // a hidden chat (the Terminal tab) fetches nothing
  const gen = older.gen, pid = older.pid;
  older.loading = true; older.failed = false;
  olderLine();
  let d = null;
  try {
    const r = await fetch(`api/s/${pid}/transcript?before=${older.before}`);
    if (r.ok) d = await r.json();
  } catch { /* shown below */ }
  if (gen !== older.gen) return;  // a reset (or another session) replaced the chat meanwhile
  older.loading = false;
  if (!d || !Array.isArray(d.messages) || !Number.isInteger(d.before)) { older.failed = true; olderLine(); return; }
  prependOlder(d.messages);
  older.before = d.before;
  older.start = !!d.start || d.before === 0;
  olderLine();
  if (older.start) { olderObs.disconnect(); return; }
  // still at the top (a short page, a tall screen): the next page, after this one has been laid out
  requestAnimationFrame(() => { if (gen === older.gen && olderInReach()) loadOlder(); });
}
function prependOlder(msgs) {
  const chat = $("#chat"), p = pane(), line = $("#chat > .older");
  if (!msgs.length || !line) return;
  // the first element below the line that is in view (or the first one): it stays put on the screen
  const top = p.getBoundingClientRect().top;
  let anchor = line.nextElementSibling;
  for (let n = anchor; n; n = n.nextElementSibling) { if (n.getBoundingClientRect().bottom > top) { anchor = n; break; } }
  const was = anchor ? anchor.getBoundingClientRect().top : 0;
  const frag = document.createDocumentFragment();
  const tools = new Map();
  for (const m of msgs) renderMessage(m, { into: frag, tools, older: true });
  line.after(frag);
  if (anchor) p.scrollTop += anchor.getBoundingClientRect().top - was;
  chatScroll.lastTop = p.scrollTop;
  updateJump();
}

/* ---------- a chat opened far back: the page around an entry, newer pages below it ---------- */
// openAround: GET transcript?around=<pos> gives about 100 messages before the entry and 100 from it on, with `before` (older pages, the
// .older line at the top as usual) and `after`, the cursor for the next newer page. A line at the bottom (.newer) is watched like .older:
// within OLDER_MARGIN px of the view, GET transcript?after=<cursor> brings the next 200 below. While the chat is "ahead" of nothing (not
// at the live end) the stream keeps running but its tail and appends wait in ahead.buffer (and its live `!` block in ahead.live); the
// view is never pinned, and ↓ (the jump button) goes to the live end at once (a fresh open of the chat). When a newer page reaches the
// end of the file (`end`), the waiting messages not already shown (by uuid) go in below it, then any pending bubbles and the live block,
// and the chat is live again as after a normal open. Leaving the chat, another session, or a /clear ends it (aheadStop).
const ahead = { active: false, pid: null, sid: null, after: null, loading: false, failed: false, gen: 0, buffer: [], live: null };
const newerObs = new IntersectionObserver((es) => {
  if (es.some((e) => e.isIntersecting)) loadNewer();
}, { root: pane(), rootMargin: `0px 0px ${OLDER_MARGIN}px 0px` });
function aheadStop() {
  ahead.gen++;
  if (!ahead.active) return;
  Object.assign(ahead, { active: false, loading: false, failed: false, buffer: [], live: null });
  newerObs.disconnect();
  const n = $("#chat > .newer");
  if (n) n.remove();
}
function newerLine() {
  const n = $("#chat > .newer");
  if (n) n.textContent = ahead.loading ? "Loading newer messages…" : ahead.failed ? "Could not load newer messages. Scroll down to try again." : "";
}
function noteModel(msgs) {
  for (const m of msgs) if (m.role === "assistant" && m.model) state.modelInfo = { model: m.model, effort: m.effort || "" };
  updateModelLine();
}
async function openAround(s, f, d) {
  state.focusAt = null;
  aheadStop();
  const gen = ahead.gen;
  Object.assign(ahead, { active: true, pid: s.pid, sid: d.session.sessionId, after: null, loading: true, failed: false, buffer: d.messages.slice(), live: null });
  const chat = $("#chat");
  olderReset(null);
  chat.replaceChildren(el("div", { class: "empty", text: "Loading the conversation at that entry…" }));
  chatScroll.pinned = false; chatScroll.unseen = false;
  noteModel(d.messages);   // the composer's model is the live end's, not the page's
  updateInflight(); updateJump();
  let r = null;
  try {
    const res = await fetch(`api/s/${s.pid}/transcript?around=${f.pos}`);
    if (res.ok) r = await res.json();
  } catch { /* shown below */ }
  if (gen !== ahead.gen) return;   // another open, another session, or a /clear meanwhile
  ahead.loading = false;
  if (!r || !Array.isArray(r.messages) || !Number.isInteger(r.after) || !Number.isInteger(r.before) || (r.session && r.session.sessionId !== ahead.sid)) {
    const tail = ahead.buffer;
    aheadStop();
    showTail(s, { ...d, messages: tail }, false);
    setStatus("Could not load the conversation at that entry; the chat shows its latest messages.", "error");
    return;
  }
  const frag = document.createDocumentFragment();
  const tools = new Map();
  for (const m of r.messages) renderMessage(m, { into: frag, tools, older: true });
  chat.replaceChildren(frag);
  olderReset(s.pid, { before: r.before, start: r.start });
  ahead.after = r.after;
  const line = el("div", { class: "newer", role: "status", "aria-live": "polite" });
  chat.append(line);
  if (r.end) joinLive(); else newerObs.observe(line);
  state.focusAt = f;
  focusEntry(chat);
  updateJump();
}
function newerInReach() {
  const n = $("#chat > .newer"), p = pane();
  if (!n || state.tab !== "chat" || !p.clientHeight) return false;
  return n.getBoundingClientRect().top < p.getBoundingClientRect().bottom + OLDER_MARGIN;
}
async function loadNewer() {
  if (!ahead.active || ahead.loading || ahead.after === null) return;
  if (state.tab !== "chat" || !pane().clientHeight) return;   // a hidden chat (the Terminal tab) fetches nothing
  const gen = ahead.gen, pid = ahead.pid;
  ahead.loading = true; ahead.failed = false;
  newerLine();
  let d = null;
  try {
    const r = await fetch(`api/s/${pid}/transcript?after=${ahead.after}`);
    if (r.ok) d = await r.json();
  } catch { /* shown below */ }
  if (gen !== ahead.gen) return;
  ahead.loading = false;
  if (!d || !Array.isArray(d.messages) || !Number.isInteger(d.after) || (d.session && d.session.sessionId !== ahead.sid)) {
    ahead.failed = true; newerLine(); return;
  }
  const line = $("#chat > .newer");
  const frag = document.createDocumentFragment();
  const tools = new Map();
  for (const m of d.messages) renderMessage(m, { into: frag, tools, older: true });
  if (line) line.before(frag);
  ahead.after = d.after;
  newerLine();
  if (d.end) { joinLive(); return; }
  updateJump();
  requestAnimationFrame(() => { if (gen === ahead.gen && newerInReach()) loadNewer(); });
}
// the newer pages met the live end: what the stream brought meanwhile goes in below (each message once), and the chat is live again
function joinLive() {
  const chat = $("#chat");
  const have = new Set([...chat.querySelectorAll(":scope > .msg[data-uuid]")].map((n) => n.dataset.uuid));
  const buf = ahead.buffer, live = ahead.live;
  aheadStop();
  for (const m of buf) if (!(m.uuid && have.has(m.uuid))) renderMessage(m, { live: true });
  for (const p of state.pending) if (p.session === state.selected && !p.node.isConnected) chat.append(p.node);
  if (live) applyLive(live);
  updateInflight();
  if (distFromBottom() < NEAR_BOTTOM) { chatScroll.pinned = true; chatScroll.unseen = false; }
  updateJump();
}
// ↓ while the chat is open far back: the live end, as a normal open shows it
function goLive() {
  const name = state.selected;
  aheadStop();
  selectSession(name, { force: true });
}

/* ---------- the shell's height: what is on the screen ---------- */
// #app is as tall as the visual viewport (visualViewport.height: the part of the page the browser draws), through
// --app-h on <html>; the stylesheet's own value, without this script, is 100dvh. Why not 100dvh alone: that is the
// layout viewport, which Chrome on Android brings up to date only once its own bars (the address bar, the strip over
// the gesture bar) have finished showing or hiding, and after the keyboard closes it can stay at the taller,
// bars-hidden height while the bars are back on the screen; the page is then laid out taller than what is visible and
// its bottom, the composer's lower half, sits under the screen's edge until a scroll or a tap makes Chrome lay it out
// again, which a page that cannot scroll never gives it (on Android Chrome: the
// composer cut off right after a keyboard image paste and the keyboard's close; whole two minutes later, nothing
// changed). The visual viewport is kept current through those transitions, so the shell follows it: on its resize and
// scroll, the window's resize, and when the page is shown again. The keyboard shrinks it the same way
// (interactive-widget=resizes-content in index.html resizes both viewports), so the composer stays above the keyboard
// as before. A pinch-zoom shrinks the visual viewport in CSS pixels without hiding anything: at a scale above 1 the
// variable is dropped and 100dvh holds.
const shellFit = { h: null, raf: 0, late: 0 };
function fitShell() {
  shellFit.raf = 0;
  const vv = window.visualViewport, root = document.documentElement;
  if (!vv) return;
  if (vv.scale > 1.01 || !(vv.height > 0)) {
    if (shellFit.h !== null) { shellFit.h = null; root.style.removeProperty("--app-h"); }
    return;
  }
  const h = Math.round(vv.height * 10) / 10;
  if (h === shellFit.h) return;
  shellFit.h = h;
  root.style.setProperty("--app-h", h + "px");
}
// one layout a frame while something animates (the keyboard, a bar), and a late pass once it has settled, in case the
// last event came before the bar's final position
function fitShellSoon() {
  if (!shellFit.raf) shellFit.raf = requestAnimationFrame(fitShell);
  clearTimeout(shellFit.late);
  shellFit.late = setTimeout(fitShell, 350);
}
if (window.visualViewport) {
  window.visualViewport.addEventListener("resize", fitShellSoon);
  window.visualViewport.addEventListener("scroll", fitShellSoon);
  window.addEventListener("resize", fitShellSoon);
  window.addEventListener("pageshow", fitShellSoon);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) fitShellSoon(); });
  fitShell();
}

/* ---------- copy ---------- */
const ICON_COPY = '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V6a2 2 0 0 1 2-2h9"/></svg>';
const ICON_CHECK = '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>';
// "5 min ago" on hover (relTime is in shared.js: the Overview cards' last line uses it too); the exact time (SALA_TZ zone, with its label) in the tooltip; refreshed every 30 s
const ZONE_FMT = zoneFormat("en-US", { weekday: "short", month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false });
const zoneWhen = (t) => ZONE_FMT.format(t) + " " + zoneLabel(new Date(t));   // "Thu, Oct 22, 09:05 UTC": the SALA_TZ zone and its own label
function stamp(ts) {
  const t = typeof ts === "number" ? ts : Date.parse(ts || "");
  if (Number.isNaN(t)) return null;
  return el("span", { class: "stamp", "data-t": String(t), title: zoneWhen(t), text: relTime(t) });
}
setInterval(() => {
  document.querySelectorAll(".stamp[data-t]").forEach((e) => { e.textContent = relTime(+e.dataset.t); });
  // the Overview cards' last line (sessions.js updatedFoot) ages on this same tick
  document.querySelectorAll(".c-updated[data-t]").forEach((e) => { e.textContent = agoLine(+e.dataset.t, +e.dataset.stale); });
}, 30000);
function copyBar(text, ts) { return el("div", { class: "actions" }, stamp(ts), copyButton(text, "copy-btn", "Copy message")); }
// the icon parsed once and cloned: an innerHTML parse per button was a visible slice of a long history's render
const svgNode = (svg) => { const t = document.createElement("template"); t.innerHTML = svg; return t.content.firstElementChild; };
const COPY_ICON = svgNode(ICON_COPY);
function copyButton(text, cls, label = "Copy") {
  const b = el("button", { class: cls, type: "button", title: "Copy", "aria-label": label });
  b.append(COPY_ICON.cloneNode(true));
  b.addEventListener("click", async () => {
    const ok = await copyText(text);
    b.innerHTML = ok ? ICON_CHECK + "<span>Copied</span>" : "<span>Copy failed</span>";
    b.classList.add("done");
    clearTimeout(b._t);
    b._t = setTimeout(() => { b.innerHTML = ICON_COPY; b.classList.remove("done"); }, 1600);
  });
  return b;
}

/* ---------- chat rendering ---------- */
function fold(cls, summaryKids, bodyKids) {
  return el("details", { class: "fold " + cls }, el("summary", {}, ...summaryKids), el("div", { class: "body" }, ...bodyKids));
}
const pre = (text) => el("pre", { text });
// The output of a finished `!` command: open under its "! <cmd>" line, in a box headed "Output · N lines" with a
// Fold button (aria-expanded) that closes and opens it. Over BANG_LINES lines only the first BANG_LINES show, and a
// "Show all N lines" button opens the rest in place. Everything else a notice carries (a slash command's output, a message
// from another session, a task notification) stays a closed fold.
const BANG_LINES = 12;
let bangSeq = 0;
function bangOutput(b) {
  const text = String(b.text || "");
  const all = text ? text.split("\n") : [];
  const n = all.length;
  const id = "bang-out-" + (++bangSeq);
  // the text is a keyboard-scrollable region (tabindex 0, named); an empty output has nothing to scroll
  const out = el("pre", n ? { tabindex: "0", "aria-label": "Command output text" } : {}, ...(n ? linkNodes(n > BANG_LINES ? all.slice(0, BANG_LINES).join("\n") : text) : [el("span", { class: "bang-none", text: "(no output)" })]));
  const body = el("div", { class: "bang-body", id }, out);
  if (n > BANG_LINES) {
    const more = el("button", { type: "button", class: "bang-more", text: `Show all ${n} lines`, onclick: () => {
      out.replaceChildren(...linkNodes(text));
      foldBtn.focus();  // this button is about to go: focus moves to the Fold button, not to the page body
      more.remove();
    } });
    body.append(more);
  }
  const note = truncNote(b);
  if (note) body.append(note);
  // the label stays "Fold output"; aria-expanded carries the state (the arrow in the CSS shows it to the eye)
  const foldBtn = el("button", { type: "button", class: "bang-fold", text: "Fold output", "aria-expanded": "true", "aria-controls": id });
  foldBtn.addEventListener("click", () => {
    const open = foldBtn.getAttribute("aria-expanded") !== "true";
    foldBtn.setAttribute("aria-expanded", open ? "true" : "false");
    body.hidden = !open;
  });
  return el("div", { class: "bang-out", role: "group", "aria-label": "Command output" },
    el("div", { class: "bang-head" }, el("span", { class: "bang-title", text: `Output · ${n} ${n === 1 ? "line" : "lines"}` }), foldBtn),
    body);
}
const truncNote = (b) => (b.truncated ? el("div", { class: "trunc", text: "(truncated)" }) : null);
function thumbs(urls) {
  if (!urls || !urls.length) return null;
  // not lazy: images settle while the view is still pinned to the bottom, instead of shifting it later
  return el("div", { class: "thumbs" }, ...urls.map((u) =>
    el("a", { href: u, target: "_blank", rel: "noopener" }, el("img", { class: "thumb", src: u, alt: "image" }))));
}
// An image the session sent with SendUserFile, inline in its reply: lazy (a long history does not fetch every image at
// once; a placeholder keeps the height until it loads, and the pinned view follows the resize), tap to open the full
// image in a new tab, the caption under it. A file that is gone, too large or not served shows its name instead.
function sentImage(b) {
  const img = el("img", { class: "sent-img", src: b.url, alt: b.caption || b.name || "image sent by the session", loading: "lazy", decoding: "async" });
  const fig = el("figure", { class: "sent" }, el("a", { href: b.url, target: "_blank", rel: "noopener", title: "Open the full image" }, img));
  img.addEventListener("error", () => fig.replaceChildren(el("div", { class: "sent-missing", text: "Image not available: " + (b.name || "file") })), { once: true });
  if (b.caption) fig.append(el("figcaption", { text: b.caption }));
  return fig;
}
// pending bubbles stay at the bottom until the transcript has them, so real messages go in above them
// (a detached host, a reset's fragment, holds no pending bubbles: the node goes at its end)
const appendToChat = (node, host = null) => {
  if (host) { host.append(node); return; }
  const chat = $("#chat");
  chat.insertBefore(node, chat.querySelector(":scope > .msg.pending, :scope > .inflight, :scope > .live-bang"));
};

// The live block of a running `!` command. Claude Code writes a `!` command's output to the transcript only when
// the command ends, so while it runs the server sends "live" events with the pane's text ({running: true, command, text})
// and, when the output record lands or the input box is back, {running: false}. The block sits at the bottom of the chat,
// under the command's own line, with a Stop button; the command's output box (the bang_output block, bangOutput) replaces it when the command ends.
// There is no answer box here (an answer to a running command is not sent from the page).
function applyLive(d) {
  const chat = $("#chat");
  let box = $("#live-bang");
  if (!d || !d.running) { if (box) box.remove(); return; }
  if (!box) {
    box = el("div", { id: "live-bang", class: "live-bang" },
      el("div", { class: "live-head" },
        el("span", { class: "live-label", text: "Running in the terminal" }),
        el("button", { type: "button", class: "live-stop", text: "Stop", onclick: stopLive })),
      el("pre", { class: "live-out" }),
      el("div", { class: "live-note", hidden: true }));
  }
  const out = $(".live-out", box);
  const text = d.text || "(no output yet)";
  if (out.textContent !== text) { out.textContent = text; out.scrollTop = out.scrollHeight; }
  box.title = d.command ? "! " + d.command : "";
  if (box.parentNode !== chat || box.nextElementSibling) chat.append(box);  // always the last thing in the chat
  if (chatScroll.pinned) { if (state.tab === "chat") scrollToBottom(); }
  updateJump();
}
function liveNote(text, isErr) {
  const n = $("#live-bang .live-note");
  if (!n) return;
  n.hidden = !text;
  n.textContent = text || "";
  n.className = "live-note" + (isErr ? " err" : "");
}
async function stopLive(ev) {
  const btn = ev.currentTarget;
  const s = state.byName.get(state.selected);
  if (!s) return;
  btn.disabled = true;
  liveNote("Stopping…");
  try {
    const r = await fetch(`api/s/${s.pid}/stop`, { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
    const j = await r.json().catch(() => ({}));
    if (r.ok) liveNote("Stop sent (" + (j.sent || []).map((k) => (k === "C-c" ? "Ctrl-C" : k)).join(", ") + "). Waiting for the command to end.");
    else liveNote(j.error || `Stop failed (${r.status})`, true);
  } catch (e) {
    liveNote("Could not reach the server: " + (e && e.message ? e.message : e), true);
  }
  setTimeout(() => { btn.disabled = false; }, 2000);
}

// "Opus 5.5 @ high", from the session's latest reply (a /model or /effort change shows after the next reply)
function updateModelLine() {
  const n = $("#model-line"), mi = state.modelInfo;
  n.hidden = !mi;
  if (mi) { n.textContent = modelLabel(mi.model) + (mi.effort ? " @ " + mi.effort : ""); n.title = mi.model; }
}
// into: a detached host the message goes into instead of the chat (a reset builds its fragment there); tools: that
// host's tool calls by id, so a result finds its call without a scan of everything rendered before it
// older: m is from a page before the ones shown (loadOlder): it says nothing of the current model and answers no pending bubble
function renderMessage(m, { live = false, into = null, tools = null, older = false } = {}) {
  if (!older && m.role === "assistant" && m.model) { state.modelInfo = { model: m.model, effort: m.effort || "" }; updateModelLine(); }
  const host = into || $("#chat");
  if (!older && m.role === "user") { const p = matchPending(m, live); if (p) dropPending(p); }
  // a message made only of thinking and tool calls/results disappears whole when they are hidden (no empty gap)
  const toolsOnly = m.blocks.length > 0 && m.blocks.every((b) => b.kind === "tool_use" || b.kind === "tool_result" || b.kind === "thinking");
  const box = el("div", { class: "msg " + m.role + (toolsOnly ? " tools-only" : ""), "data-uuid": m.uuid });
  const images = [];
  const texts = [];
  const lastText = m.blocks.filter((b) => b.kind === "text").pop();  // the one that may end in a footer
  for (const b of m.blocks) {
    switch (b.kind) {
      case "text":
        if (m.role === "user") box.append(el("div", { class: "bubble" }, ...linkNodes(b.text)));
        else box.append(...replyNodes(b.text, b === lastText, b.localImages));
        texts.push(b.text);
        if (b.truncated) box.append(truncNote(b));
        break;
      case "command":
        box.append(el("span", { class: "cmd", text: b.text }));
        break;
      case "notice":
        box.append(fold("notice", [el("span", { class: "sum", text: b.label || "notice" })], [linkedPre(b.text), truncNote(b)]));
        break;
      case "bang_output":
        // the output record is what ends the running command's live block: the box takes its place in this same tick
        if (live && !into) { const lb = $("#live-bang"); if (lb) lb.remove(); }
        box.append(bangOutput(b));
        break;
      case "thinking":
        box.append(fold("thinking", [el("span", { text: "Thinking" })], [md(b.text)]));
        break;
      case "tool_use": {
        const d = fold("tool", [el("b", { text: b.name }), el("span", { class: "sum", text: b.summary || "" })],
          [pre(b.input), truncNote(b), el("div", { class: "result-slot" })]);
        if (b.id) { d.dataset.toolId = b.id; if (tools && !tools.has(b.id)) tools.set(b.id, d); }  // the first one, as a query finds it
        box.append(d);
        break;
      }
      case "tool_result": {
        const res = el("div", { class: "result" + (b.isError ? " err" : "") }, linkedPre(b.text || "(no output)"), truncNote(b), thumbs(b.images));
        const target = b.toolUseId && ((tools && tools.get(b.toolUseId)) || host.querySelector(`details.tool[data-tool-id="${CSS.escape(b.toolUseId)}"]`));
        if (target) {
          $(".result-slot", target).replaceChildren(res);
          if (b.isError) target.classList.add("err");
        } else {
          box.append(fold("tool" + (b.isError ? " err" : ""), [el("b", { text: "Tool result" })], [res]));
        }
        break;
      }
      case "image":
        images.push(b.url);
        break;
      case "file_image":
        box.append(sentImage(b));
        break;
    }
  }
  if (images.length) {
    const t = thumbs(images);
    if (m.role === "user") box.prepend(t); else box.append(t);
  }
  if (!box.children.length) return false;
  const copy = texts.join("\n\n").trim();
  if (copy) box.append(copyBar(copy, m.ts));  // no text, no copy/time row
  appendToChat(box, into);
  return true;
}

/* ---------- optimistic send: the message shows at once, then merges with the transcript's copy ---------- */
let pendingSeq = 0;
const QUEUED_AFTER_MS = 60000;
// Claude Code records a pasted image as "[Image #N]" in the prompt text; whitespace may differ
// (the server strips Claude Code's <pasted_content id="..."> wrapper too; done here as well so an older server matches)
const normText = (t) => String(t || "").replace(/<\/?pasted_content(?:\s+id="[^"]*")?\s*>/g, " ")
  .replace(/\[Image #\d+\]/g, " ").replace(/\s+/g, " ").trim();

// "! cmd" runs a shell command in the pane (Claude Code's bash mode). Claude Code records it as a <bash-input> entry, which
// the server turns into a "command" block with the text "! cmd", never a text block: a pending bubble for it merges with
// that block by the command, and is never offered a resend or shown as queued (a shell command run twice is the danger).
const isBang = (t) => /^\s*!/.test(String(t || ""));
const bangCmd = (t) => String(t || "").replace(/^\s*!\s*/, "").replace(/\s+/g, " ").trim();

// live: m is a new line from the stream (not the replay in a reset), so it may take the fallback below
function matchPending(m, live) {
  const bang = m.blocks.find((b) => b.kind === "command" && isBang(b.text));
  if (bang) {
    const bts = Date.parse(m.ts || "");
    const want = bangCmd(bang.text);
    return state.pending.find((p) => p.session === state.selected && isBang(p.text) && bangCmd(p.text) === want
      && (Number.isNaN(bts) || bts >= p.sentAt - 120000)) || null;
  }
  const texts = m.blocks.filter((b) => b.kind === "text").map((b) => b.text);
  const t = normText(texts.join("\n"));
  const n = m.blocks.filter((b) => b.kind === "image").length;
  if (!t && !n) return null;
  const ts = Date.parse(m.ts || "");
  const cands = state.pending.filter((p) => {
    if (p.session !== state.selected) return false;
    if (!Number.isNaN(ts) && ts < p.sentAt - 120000) return false;  // an older identical prompt is not this one
    const pt = normText(p.text);
    if (!pt && !t) return p.images.length === n;
    // a long prompt may come back truncated (TEXT_LIMIT): compare the start
    return pt === t || (pt.length >= 40 && t.length >= 40 && pt.slice(0, 200) === t.slice(0, 200));
  });
  const exact = cands.find((p) => p.images.length === n) || cands[0];
  if (exact) return exact;
  // Fallback when Claude Code changed the text in a way not foreseen here: the first new prompt of the owner's own
  // (a text block, not a notice) to arrive after a send is that send, so it takes the oldest pending bubble.
  if (!live || !texts.length) return null;
  return state.pending.find((p) => p.session === state.selected && !isBang(p.text) && (Number.isNaN(ts) || ts >= p.sentAt - 10000)) || null;
}

function dropPending(p, { keepImages = false } = {}) {
  clearTimeout(p.timer);
  p.merged = true;
  state.pending = state.pending.filter((x) => x !== p);
  p.node.remove();
  if (!keepImages) for (const im of p.images) if (im.url) URL.revokeObjectURL(im.url);
}

function pendingNode(p) {
  const box = el("div", { class: "msg user local " + p.status + (p.status === "queued" ? "" : " pending") });
  const t = thumbs(p.images.filter((im) => !im.file).map((im) => im.url));
  if (t) box.append(t);
  const sentFiles = p.images.filter((im) => im.file);
  if (sentFiles.length) box.append(el("div", { class: "sent-files" }, ...sentFiles.map((im) =>
    el("div", { class: "sent-file", title: im.file.name }, fileIcon(), el("span", { class: "sf-name", text: im.file.name }),
      el("span", { class: "sf-size", text: humanSize(im.file.size) })))));
  if (p.text.trim()) box.append(el("div", { class: "bubble" }, ...linkNodes(p.text)));
  if (p.status === "sending") box.append(el("div", { class: "note", text: "Sending…" }));
  else if (p.status === "sent" && p.late) box.append(el("div", { class: "note", text: "Sent: not in the transcript yet. A shell command is not sent twice; check the Terminal tab." }));
  else if (p.status === "queued") box.append(el("div", { class: "note", text: "Queued: not in the transcript yet" }));
  else if (p.status === "failed") {
    box.append(el("div", { class: "note err", text: "Not sent: " + p.error }),
      el("div", { class: "note-actions" },
        // no Retry for a shell command: the failed request may have reached the pane, and a second send would run it twice
        ...(isBang(p.text) ? [] : [el("button", { type: "button", text: "Retry", onclick: () => retryPending(p) })]),
        el("button", { type: "button", text: "Edit", onclick: () => editPending(p) })));
  }
  box.append(copyBar(p.text, p.sentAt));
  return box;
}
function redrawPending(p) {
  const n = pendingNode(p);
  if (p.node && p.node.isConnected) p.node.replaceWith(n);
  p.node = n;
}

async function deliver(p) {
  const s = state.byName.get(p.session);
  state.sending = true; refreshSendButton();
  try {
    if (!s) throw new Error("the session is not live");
    const r = await fetch(`api/s/${s.pid}/send`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text: p.text, uploads: p.images.map((im) => im.name) }),
    });
    const d = await r.json().catch(() => ({}));
    if (r.status === 409 && d.duplicate) {  // the server already pasted this exact message moments ago: drop the copy
      p.merged = true; clearTimeout(p.timer); state.pending = state.pending.filter((x) => x !== p);
      if (p.node) p.node.remove();
      setStatus("That message was already sent a moment ago; not sent twice.", "ok");
      return;
    }
    if (!r.ok || !d.ok) throw new Error(d.error || r.statusText);
    if (d.dialogAnswer) {  // a keypress answering a dialog: it never shows in the transcript, so no bubble waits for it
      dropPending(p);
      setStatus(d.dialogAnswer === "Escape" ? "Closed the dialog (Esc)." : `Answered the dialog with ${d.dialogAnswer}.`, "ok");
      return;
    }
    if (d.imagesPasted && d.imagesAttached < d.imagesPasted) {
      setStatus(`${d.imagesAttached} of ${d.imagesPasted} images showed as attached in the pane.`, "error");
    }
    if (p.merged) return;
    p.status = "sent"; redrawPending(p);
    p.timer = setTimeout(() => {
      if (p.merged || p.status !== "sent") return;
      if (isBang(p.text)) p.late = true; else p.status = "queued";  // a shell command never reads as "queued"
      redrawPending(p);
    }, QUEUED_AFTER_MS);
  } catch (e) {
    if (p.merged) return;
    p.status = "failed"; p.error = e.message || "unknown error"; redrawPending(p);
  } finally {
    state.sending = false; refreshSendButton();
  }
}
function retryPending(p) {
  if (state.sending) return;
  p.status = "sending"; p.sentAt = Date.now(); redrawPending(p);
  pinToBottom();
  deliver(p);
}
function editPending(p) {
  dropPending(p, { keepImages: true });
  const cur = getText();
  setText(p.text + (cur ? "\n" + cur : ""));
  for (const im of p.images) {
    state.uploads.push(im.file ? { id: ++uploadSeq, kind: "file", name: im.name, fileName: im.file.name, size: im.file.size, uploading: false }
                               : { id: ++uploadSeq, name: im.name, url: im.url, uploading: false });
  }
  renderChips(); focusEnd();
  updateJump();
}

/* ---------- tabs and terminal ---------- */
function setTab(tab) {
  if (state.tab === "chat" && tab !== "chat") chatScroll.savedTop = pane().scrollTop;
  state.tab = tab;
  for (const b of document.querySelectorAll(".tab")) { b.classList.toggle("active", b.dataset.tab === tab); b.setAttribute("aria-pressed", String(b.dataset.tab === tab)); }
  $("#chat-pane").classList.toggle("active", tab === "chat");
  $("#terminal-pane").classList.toggle("active", tab === "terminal");
  if (tab === "chat") {
    if (chatScroll.pinned) scrollToBottom();
    else { pane().scrollTop = chatScroll.savedTop; chatScroll.lastTop = pane().scrollTop; }
  }
  updateJump();
  if (tab === "terminal") loadTerminal();
}
function loadTerminal() {
  const s = state.current;
  const host = $("#terminal-pane");
  if (!s) { host.replaceChildren(el("div", { class: "empty", text: "Pick a session first." })); return; }
  if (state.termLoadedFor === s.tmuxSession && host.querySelector("iframe")) return;
  state.termLoadedFor = s.tmuxSession;
  const frame = el("iframe", { src: state.terminalUrl + encodeURIComponent(s.tmuxSession), title: "Terminal for " + s.name, allow: "clipboard-read; clipboard-write" });
  host.replaceChildren(frame);
  hookTerminalClipboard(frame);
}

/* ---------- composer ---------- */
// The composer is CodeMirror 6 (vendor/cm6-composer.min.js, built from web/vendor-src/cm6-composer): a list item is drawn as a dot with a slight indent while the text stays plain markdown ("- item",
// "1. item"), the caret skips the marker, Backspace at an item's start leaves the list, Tab indents. What the keys do (Enter
// and Shift+Enter, Tab and Shift+Tab, the list continuing, Ctrl+arrows, the guard for an IME composition) is in the
// bundle's entry.js; this file wires the editor to the page: the send, the draft, the placeholder, the images.
//
// Its editable is a contenteditable="true" with the id "input" (`input`, below), not a textarea, so that a phone keyboard
// offers its image insertion: a keyboard on Android (its clipboard chips, its GIFs) inserts an image through
// InputConnection.commitContent, which it offers only to an editor that declares image MIME types, and Chrome on Android
// declares them for a contenteditable, not for a textarea (there the attach button worked, but a paste from
// the keyboard did not). It is "true", not "plaintext-only": an <img> the browser inserts on its own is lifted out into a chip
// (liftImage), and a plaintext-only editable refuses the <img> instead (Chromium 155: execCommand insertImage returns
// false there, insertHTML drops it). For the same reason the bundle turns CodeMirror's EditContext off (it would take the
// keyboard away from the contenteditable on Android).
// getText/setText/selectionOf/selectOffsets are the textarea's value and selection API for the rest of this file; the
// document is the text that is sent, byte for byte.
const touchMode = window.matchMedia("(pointer: coarse) and (hover: none)");
// the long placeholder wraps on a phone; there the short one. Wide and in touch mode (a tablet): Enter is a new line there.
const placeholderFor = () => (window.matchMedia("(max-width: 760px)").matches ? "Message the session"
  : touchMode.matches ? "Message the session (Enter adds a line, tap Send)" : "Message the session (Enter sends, Shift+Enter for a new line)");
watchForInsertedImages($("#composer-editor"));
const composer = cm6Composer.createEditor($("#composer-editor"), {
  id: "input", label: "Message the session", placeholder: placeholderFor(),
  // Enter sends on a desktop, and Shift+Enter is a new line. In touch mode, a phone or a tablet typing on its on-screen
  // keyboard (`(pointer: coarse) and (hover: none)`), Enter is a new line and only the Send button or Ctrl/Cmd+Enter sends,
  // as in the Claude app: an on-screen keyboard has no Shift to hold with Enter (Shift+Enter did not give a new line
  // on some phone keyboards). A keyboard attached to a tablet
  // keeps Shift+Enter and Ctrl/Cmd+Enter. Android in desktop mode (desktop windowing) reports a fine pointer with
  // hover and gets the desktop rule; a phone or tablet with a mouse or keyboard attached stays in touch mode, since
  // Chromium keeps the touchscreen its primary pointer there (ui/base/pointer/pointer_device_android.cc). The query is read
  // at the key, not at load, so a dock is followed. Never during an IME composition (keyCode 229 or isComposing): the
  // bundle's commands leave the key to the browser then.
  touch: () => touchMode.matches,
  onSend: () => send(),
  onChange: () => { refreshSendButton(); saveDraftSoon(); },   // a change by typing, a paste or a key; setText makes none (callers refresh)
  extensions: [composerImageHandlers()],
});
const input = composer.contentDOM;   // the editable, #input
const getText = () => composer.state.doc.toString();
// the text replaced as a textarea's value= does: no change event, no undo step (the history starts over), the caret at the end
function setText(v) { cm6Composer.resetDoc(composer, v); }
function selectionOf() { const r = composer.state.selection.main; return { start: r.from, end: r.to, backward: r.head < r.anchor }; }
function selectOffsets(start, end, backward = false) {
  const len = composer.state.doc.length, a = Math.max(0, Math.min(start, len)), b = Math.max(0, Math.min(end, len));
  composer.dispatch({ selection: backward ? { anchor: b, head: a } : { anchor: a, head: b } });
}
function focusEnd() { composer.focus(); const n = getText().length; selectOffsets(n, n); composer.dispatch({ effects: cm6Composer.EditorView.scrollIntoView(n) }); }  // as a textarea's value= leaves the caret
function setStatus(msg, kind) { const n = $("#send-status"); n.textContent = msg; n.className = kind || ""; }
function clearStatus() { setStatus("", ""); }
function refreshSendButton() {
  const uploading = state.uploads.some((u) => u.uploading);
  $("#send").disabled = state.sending || uploading || (!getText().trim() && !state.uploads.some((u) => u.name));
  // the attach button stays usable while an upload is in flight (a second photo can be picked), busy-marked meanwhile
  const att = $("#attach");
  att.disabled = state.sending;
  att.classList.toggle("busy", uploading);
  att.setAttribute("aria-busy", String(uploading));
}

function renderChips() {
  const box = $("#chips");
  box.replaceChildren(...state.uploads.map((u) => u.kind === "file" ? fileChip(u) :
    el("div", { class: "chip" + (u.uploading ? " uploading" : ""), title: u.error || "" },
      el("img", { src: u.url, alt: "attached image" }),
      el("button", { "aria-label": "Remove image", text: "×", onclick: () => removeUpload(u.id) }))));
  refreshSendButton();
}
// A file that is not an image: a chip with a generic file icon, its name, and under it its size, the
// upload's progress while it goes up, or the error that stopped it. Progress repaints the two nodes in place
// (paintFileChip), so a long upload does not rebuild the chip, and the remove button keeps its focus.
const MAX_FILE_BYTES = 500 * 1024 * 1024;  // the server's cap (config.max_file_upload_bytes); checked here so a bigger file is not sent at all
function humanSize(n) {
  if (!(n >= 0)) return "";
  if (n < 1024) return n + " B";
  const units = ["KB", "MB", "GB"];
  let v = n / 1024, i = 0;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return (v >= 10 ? Math.round(v) : v.toFixed(1)) + " " + units[i];
}
function fileIcon() {
  const ns = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(ns, "svg");
  svg.setAttribute("viewBox", "0 0 20 20"); svg.setAttribute("width", "20"); svg.setAttribute("height", "20");
  svg.setAttribute("class", "fc-icon"); svg.setAttribute("aria-hidden", "true");
  const path = document.createElementNS(ns, "path");
  path.setAttribute("d", "M5 2.5h6.5L15 6v11.5H5zM11.5 2.5V6H15");
  path.setAttribute("fill", "none"); path.setAttribute("stroke", "currentColor");
  path.setAttribute("stroke-width", "1.4"); path.setAttribute("stroke-linejoin", "round");
  svg.append(path);
  return svg;
}
function paintFileChip(u) {
  if (!u.metaEl || !u.metaEl.isConnected) return;
  const pct = u.size ? Math.min(100, Math.floor(100 * (u.loaded || 0) / u.size)) : 0;
  u.metaEl.textContent = u.error ? "Failed: " + u.error : u.uploading ? `Uploading ${pct}% of ${humanSize(u.size)}` : humanSize(u.size);
  u.barEl.style.width = (u.uploading ? pct : 0) + "%";
}
function fileChip(u) {
  u.metaEl = el("span", { class: "fc-meta" });
  u.barEl = el("span", { class: "fc-bar" });
  const chip = el("div", { class: "chip file" + (u.uploading ? " uploading" : "") + (u.error ? " failed" : ""), role: "group",
                           "aria-label": "Attached file " + u.fileName, title: u.error ? u.fileName + ": " + u.error : u.fileName },
    fileIcon(), el("span", { class: "fc-text" }, el("span", { class: "fc-name", text: u.fileName }), u.metaEl), u.barEl,
    el("button", { type: "button", "aria-label": "Remove " + u.fileName, text: "×", onclick: () => removeUpload(u.id) }));
  queueMicrotask(() => paintFileChip(u));  // the nodes are in the page once renderChips has put them there
  return chip;
}
function removeUpload(id) {
  const u = state.uploads.find((x) => x.id === id);
  if (u && u.xhr) u.xhr.abort();  // a file still going up stops with its chip
  if (u && u.url) URL.revokeObjectURL(u.url);
  state.uploads = state.uploads.filter((x) => x.id !== id);
  renderChips();
}
let uploadSeq = 0;
async function addImage(file) {
  if (!file || !/^image\/(png|jpeg|gif|webp)$/.test(file.type)) {
    setStatus(`Not attached: ${file ? file.type || "unknown type" : "no file"} (png, jpeg, gif or webp only).`, "error");
    return;
  }
  const u = { id: ++uploadSeq, url: URL.createObjectURL(file), uploading: true, name: null };
  state.uploads.push(u);
  renderChips();
  try {
    const r = await apiFetch("api/upload", { method: "POST", headers: { "Content-Type": file.type }, body: file });
    const d = await r.json();
    if (!r.ok || !d.ok) throw new Error(d.error || r.statusText);
    u.name = d.name;
  } catch (e) {
    setStatus("Image upload failed: " + e.message, "error");
    state.uploads = state.uploads.filter((x) => x !== u);
  }
  u.uploading = false;
  renderChips();
}

// Any file but a png, jpeg, gif or webp goes up as the raw body of api/upload?name=<its name>, in an XMLHttpRequest for
// its progress (fetch has none for an upload). The server streams it to disk and answers with the reference send takes.
// A file with no name (an Android keyboard's or a share sheet's blob) is named from its type: pasted-<time>.<ext>, .bin
// when the type says nothing; the server makes the name safe all the same (safe_upload_name).
const NAME_EXT = { "video/mp4": "mp4", "video/webm": "webm", "video/quicktime": "mov", "audio/mpeg": "mp3", "audio/mp4": "m4a", "audio/ogg": "ogg",
                   "audio/wav": "wav", "application/pdf": "pdf", "application/zip": "zip", "application/json": "json", "text/plain": "txt",
                   "text/markdown": "md", "text/csv": "csv", "text/html": "html", "image/heic": "heic", "image/heif": "heif",
                   "image/avif": "avif", "image/bmp": "bmp", "image/svg+xml": "svg", "image/png": "png", "image/jpeg": "jpg",
                   "image/gif": "gif", "image/webp": "webp" };
function attachmentName(file) {
  if ((file.name || "").trim()) return file.name;
  const type = (file.type || "").split(";")[0].trim().toLowerCase();
  return `pasted-${Date.now()}.${NAME_EXT[type] || "bin"}`;
}
function addFile(file) {
  const u = { id: ++uploadSeq, kind: "file", fileName: attachmentName(file), size: file.size, loaded: 0, uploading: true, name: null, error: "" };
  state.uploads.push(u);
  const fail = (msg) => {
    u.uploading = false; u.error = msg; u.xhr = null;
    setStatus(`Upload failed: ${u.fileName}: ${msg}`, "error");
    renderChips();
  };
  renderChips();
  if (file.size > MAX_FILE_BYTES) { fail(`too large (${humanSize(file.size)}; the limit is ${humanSize(MAX_FILE_BYTES)})`); return Promise.resolve(); }
  return new Promise((resolve) => {
    const xhr = new XMLHttpRequest();
    u.xhr = xhr;
    xhr.open("POST", "api/upload?name=" + encodeURIComponent(u.fileName));
    xhr.setRequestHeader("Content-Type", "application/octet-stream");
    xhr.upload.onprogress = (e) => { u.loaded = e.loaded; paintFileChip(u); };
    xhr.onload = () => {
      let d = {};
      try { d = JSON.parse(xhr.responseText); } catch (e) { /* not JSON: a proxy's page */ }
      if (xhr.status >= 200 && xhr.status < 300 && d.ok) { u.name = d.name; u.uploading = false; u.xhr = null; u.loaded = u.size; renderChips(); }
      else fail(d.error || xhr.statusText || "HTTP " + xhr.status);
      resolve();
    };
    xhr.onerror = () => { fail("the connection was lost"); resolve(); };
    xhr.onabort = () => resolve();
    xhr.send(file);
  });
}
// A file of no type that is in fact a png, jpeg, gif or webp (told by its bytes) goes up as an image, thumbnail and all.
async function addAttachment(file) {
  if (!file.type && file.size) {
    let type = "";
    try { type = await sniffImageType(file); } catch (e) { /* unreadable: it goes up as it is, and the upload says why it failed */ }
    if (type) file = new File([file], file.name || `pasted-${Date.now()}.${IMAGE_EXT[type]}`, { type });
  }
  return /^image\/(png|jpeg|gif|webp)$/.test(file.type) ? addImage(file) : addFile(file);
}

function send() {
  const s = state.current;
  if (!s) { setStatus("Pick a session first.", "error"); return; }
  if (state.sending || state.uploads.some((u) => u.uploading)) return;
  const text = getText();
  const ups = state.uploads.filter((u) => u.name);
  if (!text.trim() && !ups.length) return;
  // show it at once, like claude.ai; the composer empties now and the bubble holds the text if sending fails
  const p = { id: ++pendingSeq, session: s.name, text, images: ups.map((u) => ({ name: u.name, url: u.url, file: u.kind === "file" ? { name: u.fileName, size: u.size } : null })),
              status: "sending", sentAt: Date.now() };
  state.pending.push(p);
  setText("");
  clearDraft(s.name);   // sent: nothing to come back to
  state.uploads = []; renderChips();
  clearStatus();
  redrawPending(p);
  const empty = $("#chat > .empty");
  if (empty) empty.remove();
  $("#chat").insertBefore(p.node, $("#chat > .inflight"));  // above the spinner, if one is showing
  pinToBottom();
  deliver(p);
}

// Pasted images are clipboardData.files: it holds one File per item of kind "file", the same objects on every read
// (HTML spec, [SameObject]); clipboardData.items is read only when files is empty, a net for a browser that fills
// items alone. Reading both and deduplicating the File objects by their fields attached two chips for one paste
// (on Android Chrome, and the same on a desktop Chrome): Chromium 155 makes a new File for every
// items[i].getAsFile() call, "image.png" with lastModified = the time of the call, so the File in files (made when
// the event was built) and the one getAsFile() returned differed by a few ms, and no field told them apart
// (web/tests/test_composer_attach.py).
function clipboardFiles(cd) {
  if (!cd) return [];
  const files = [...(cd.files || [])];
  if (!files.length) for (const i of cd.items || []) if (i.kind === "file") { const f = i.getAsFile(); if (f) files.push(f); }
  return files;
}
const clipboardImages = (cd) => clipboardFiles(cd).filter((f) => f.type.startsWith("image/"));
// What beforeinput takes (it takes every file now; that broke the Android keyboard's image: its clipboard,
// image suggestions, stickers and GIFs reach the editable through commitContent as an insertion carrying a File of NO
// TYPE, or no bytes; before, clipboardImages() filtered it out, the browser inserted the <img> itself and liftImage
// attached it; after, the File went to addFile, the browser's <img> was cancelled, and nothing was attached). A file with no
// bytes, or with no type and no name that names a kind of file (no extension, or an image's extension), is left to the
// browser here; a real file of any type, mp4 and PDF included, is taken. The paste event takes every file instead: the
// editor cancels a paste that holds no text itself, so no <img> would follow, and addAttachment tells an image by its bytes.
const NAMED_FILE_RE = /\.(?!(?:png|jpe?g|gif|webp|bmp|heic|heif|avif|svg)$)[A-Za-z0-9]{1,10}$/i;
function leftToBrowser(f) {
  return !f.size || (!f.type && !NAMED_FILE_RE.test(f.name || ""));
}
const takenFiles = (cd) => clipboardFiles(cd).filter((f) => !leftToBrowser(f));
// Everything that can carry an image into the editable feeds addImage, and the text that comes with it stays plain:
// 1. the paste event (a desktop paste, the Android paste menu, a keyboard's clipboard chip when Chrome delivers it so):
//    files become chips; text with an HTML flavour goes in as its plain text; a plain-only paste is the browser's own;
// 2. beforeinput, for an insertion that reaches the editable without a paste event (a keyboard's commitContent may
//    arrive as insertFromPaste or insertFromDrop with a DataTransfer, an autocorrect as insertReplacementText): files
//    become chips, HTML becomes its text; formatting commands (Ctrl+B, a format from a menu) are refused;
// 3. an <img> that the browser put into the editable itself (its own paste of a bitmap, a keyboard's insertion): lifted
//    out into a chip by liftImage (watchForInsertedImages) and removed.
// One gesture, one chip: these are the links of one chain (Chromium 155: the paste event, then beforeinput
// insertFromPaste with the same files, then the <img> it inserts), and the link that attaches the files stops the
// chain (preventDefault: no beforeinput after a prevented paste, no <img> after a prevented beforeinput). Should a
// browser run a later link all the same, it carries the same bytes under another File object, so a later link skips
// what an earlier link attached within the last second, by size and type (nothing else survives the new File). Only a
// later link checks: two pastes of one image in a row are two chips, so are two <img> in one insertion.
const GESTURE_MS = 1000;
let gestures = [];  // what a link attached: [{link, size, type, at}], links 1 (paste, drop), 2 (beforeinput), 3 (<img>)
function noteGesture(link, files) {
  const at = performance.now();
  gestures = gestures.filter((g) => at - g.at < GESTURE_MS);
  for (const f of files) gestures.push({ link, size: f.size, type: f.type, at });
}
function fromEarlierLink(link, f) {
  const at = performance.now();
  return gestures.some((g) => g.link < link && at - g.at < GESTURE_MS && g.size === f.size && (g.type === f.type || !g.type));
}
// The editor's own handlers run after these (EditorView.domEventHandlers, returning true cancels them): a paste of text,
// plain or with an HTML flavour, is the editor's, which inserts its plain text as one undo step; images never reach it
// (an image-only paste would otherwise replace the selection with nothing).
function composerImageHandlers() {
  return cm6Composer.EditorView.domEventHandlers({
    paste(e) {
      const files = clipboardFiles(e.clipboardData);   // any file; an image stays a thumbnail (addAttachment)
      if (!files.length) return false;
      noteGesture(1, files); files.forEach(addAttachment);
      return true;
    },
    beforeinput(e) {
      const dt = e.dataTransfer;
      if (!dt) return false;
      const files = takenFiles(dt);
      if (!files.length) return false;
      const fresh = files.filter((f) => !fromEarlierLink(2, f));
      noteGesture(2, fresh);
      fresh.forEach(addAttachment);
      return true;
    },
    // files dropped on the editor are the window's drop handler's (below); the editor must not read them as text
    drop(e) { return !!(e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files.length); },
  });
}
// An image whose type the keyboard did not give: told by its first bytes (the four types the server takes as images)
async function sniffImageType(blob) {
  const b = new Uint8Array(await blob.slice(0, 12).arrayBuffer());
  const at = (i, str) => [...str].every((c, k) => b[i + k] === c.charCodeAt(0));
  if (b[0] === 0x89 && at(1, "PNG")) return "image/png";
  if (b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return "image/jpeg";
  if (at(0, "GIF8")) return "image/gif";
  if (at(0, "RIFF") && at(8, "WEBP")) return "image/webp";
  return "";
}
const IMAGE_EXT = { "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp" };
const lifted = new WeakSet();
let liftSeq = 0;
async function liftImage(img) {
  // CodeMirror's own <img class="cm-widgetBuffer"> beside a widget (a list marker) has no src and is not an image
  if (lifted.has(img) || img.classList.contains("cm-widgetBuffer") || !img.getAttribute("src")) return;
  lifted.add(img);
  const src = img.getAttribute("src");
  const parent = img.parentNode;
  img.remove();   // the editor may have taken it out of its line already
  if (parent && parent !== input && !parent.classList.contains("cm-line") && !parent.childNodes.length) parent.remove();  // the wrapper it came in, now empty
  refreshSendButton();
  try {
    const blob = await (await fetch(src)).blob();
    // the type the keyboard gave if it is an image the server takes; else the bytes tell (a blob of no type, or "application/octet-stream")
    const given = [blob.type, src.startsWith("data:") ? src.slice(5, src.search(/[;,]/)) : ""].find((t) => IMAGE_EXT[t]);
    const type = given || await sniffImageType(blob) || blob.type;
    const file = new File([blob], `keyboard-${++liftSeq}.${IMAGE_EXT[type] || "img"}`, { type });
    if (fromEarlierLink(3, file)) return;  // the paste or beforeinput of this gesture attached it already
    await addImage(file);
  } catch (e) {
    setStatus("Could not read the inserted image: " + (e.message || e), "error");
  }
}
// An <img> the browser puts into the editable is lifted out into a chip. The observer is made, and watches the editor's
// mount, before the editor exists: observers are called in the order they were made, so this one removes the node (and the
// <div> it came in) before CodeMirror's own observer reads the DOM and takes the new block for a line of text.
function watchForInsertedImages(host) {
  new MutationObserver((muts) => {
    for (const m of muts) for (const n of m.addedNodes) {
      if (n.nodeType !== Node.ELEMENT_NODE) continue;   // not isConnected: the editor may have dropped the node already
      if (n.tagName === "IMG") liftImage(n);
      else for (const im of n.querySelectorAll("img")) liftImage(im);
    }
  }).observe(host, { childList: true, subtree: true });
}
$("#send").addEventListener("click", send);
// The attach button, for a phone where paste and drag-drop do not reach the composer: a hidden file input behind it
// (no accept: any file, multiple; on Android the chooser offers camera, gallery and files), feeding the same
// addAttachment path as a paste. The value is cleared after each pick, so the same photo can be chosen
// again (a "change" would not fire for it otherwise).
const fileInput = $("#file-input");
$("#attach").addEventListener("click", () => { if (!state.sending) fileInput.click(); });
fileInput.addEventListener("change", () => {
  const files = [...(fileInput.files || [])];
  fileInput.value = "";
  files.forEach(addAttachment);
});

let dragDepth = 0;
window.addEventListener("dragenter", (e) => { if (e.dataTransfer?.types?.includes("Files")) { dragDepth++; document.body.classList.add("dragging"); } });
window.addEventListener("dragleave", () => { if (--dragDepth <= 0) { dragDepth = 0; document.body.classList.remove("dragging"); } });
window.addEventListener("dragover", (e) => { if (e.dataTransfer?.types?.includes("Files")) e.preventDefault(); });
window.addEventListener("drop", (e) => {
  dragDepth = 0; document.body.classList.remove("dragging");
  const files = [...(e.dataTransfer?.files || [])];
  if (files.length) { e.preventDefault(); noteGesture(1, files); files.forEach(addAttachment); }
});

/* ---------- deploys: the reload banner, the connection state, drafts across a reload ---------- */
// The page remembers the build it loaded (rendered into the HTML) and compares it with the server's: at the start of
// every stream, every 60 s, and when the tab comes back into view. A newer build shows the banner; the page reloads
// by itself only when nothing can be lost (tab hidden, composer empty, no upload or unsent message), else it waits
// for the click. The Terminal iframe is left alone until the page reloads.
const LOADED_VERSION = document.querySelector('meta[name="sala-web-version"]')?.content || "";
const upd = { available: false, lastCheck: 0 };
const AUTO_RELOAD_GAP_MS = 60000;  // never more than one automatic reload a minute in a tab (no reload loop)

function noteVersion(v) {
  perfMark("version", { server: v || "", loaded: LOADED_VERSION, same: v === LOADED_VERSION });
  if (!v || !LOADED_VERSION || v === LOADED_VERSION) return;
  upd.available = true;
  $("#update-banner").hidden = false;
  maybeAutoReload();
}
function safeToAutoReload() {
  return document.hidden && !getText().trim() && !state.uploads.length && !state.sending &&
    !state.pending.some((p) => p.status === "sending" || p.status === "failed");
}
function maybeAutoReload() {
  if (!upd.available || !safeToAutoReload()) return;
  let last = 0;
  try { last = Number(sessionStorage.getItem("salaweb.autoReloadAt")) || 0; } catch { /* storage unavailable */ }
  if (Date.now() - last < AUTO_RELOAD_GAP_MS) return;
  try { sessionStorage.setItem("salaweb.autoReloadAt", String(Date.now())); } catch { /* storage unavailable */ }
  reloadPage("auto");
}
// cause: who asked (auto, banner, menu, overview), marked for the timing log before the page goes
function reloadPage(cause) { perfMark("reload", { cause: cause || "unknown" }); saveDraft(); location.reload(); }
async function checkVersion() {
  upd.lastCheck = Date.now();
  try {
    const r = await fetch("api/config", { cache: "no-store" });
    if (r.ok) noteVersion((await r.json()).version);
  } catch { /* the server is restarting: the next check or the stream will tell */ }
}
const checkSoon = () => { if (Date.now() - upd.lastCheck > 5000) checkVersion(); };

// The composer's text, per session: unsent text is kept for the session it was typed in and comes back when
// The owner returns to it (the composer itself is emptied when he leaves, so it is never sent to another session). Kept in
// localStorage, so it also survives the installed app being closed; text only (attached images are not kept). Saved
// 400 ms after the last keystroke, on leaving the session, and when the page goes (pagehide, hidden); removed once the
// text is sent or emptied.
const DRAFT_MAX = 20000, DRAFT_MS = 400;
const draftKey = (name) => "salaweb.draft." + name;
let draftTimer = null;
function saveDraft(name = state.selected) {
  clearTimeout(draftTimer); draftTimer = null;
  if (!name) return;
  try {
    const t = getText();
    if (t.trim()) localStorage.setItem(draftKey(name), t.slice(0, DRAFT_MAX));
    else localStorage.removeItem(draftKey(name));
  } catch { /* storage unavailable */ }
}
function saveDraftSoon() { clearTimeout(draftTimer); draftTimer = setTimeout(saveDraft, DRAFT_MS); }
function clearDraft(name) {
  clearTimeout(draftTimer); draftTimer = null;
  try { localStorage.removeItem(draftKey(name)); sessionStorage.removeItem(draftKey(name)); } catch { /* storage unavailable */ }
}
function restoreDraft(name) {
  if (!name) return;
  try {
    let t = localStorage.getItem(draftKey(name));
    if (t == null) {   // a draft the first build kept for this tab: carried over once
      t = sessionStorage.getItem(draftKey(name));
      if (t != null) { sessionStorage.removeItem(draftKey(name)); if (t.trim()) localStorage.setItem(draftKey(name), t.slice(0, DRAFT_MAX)); }
    }
    if (t && !getText()) { setText(t); refreshSendButton(); }
  } catch { /* storage unavailable */ }
}
// leaving the session the composer belongs to (another session, the Overview): its text is kept and the box emptied
function leaveComposer() {
  if (!state.selected) return;
  saveDraft();
  if (getText()) { setText(""); refreshSendButton(); }
}

// "Reconnecting…" in the header while the stream or the API is unreachable; shown only if it lasts past 800 ms,
// so a quick restart does not flash it
const connDown = new Set();
let connTimer = null;
function setConn(key, down) {
  if (down) connDown.add(key); else connDown.delete(key);
  const pill = $("#conn");
  if (!connDown.size) { clearTimeout(connTimer); connTimer = null; if (!pill.hidden) { pill.hidden = true; layoutHeader(); } return; }
  if (pill.hidden && !connTimer) {
    connTimer = setTimeout(() => { connTimer = null; if (connDown.size) { pill.hidden = false; layoutHeader(); } }, 800);  // it takes room beside the name
  }
}

$("#reload-btn").addEventListener("click", () => reloadPage("banner"));
window.addEventListener("pagehide", () => saveDraft());
document.addEventListener("visibilitychange", () => { if (document.hidden) { saveDraft(); maybeAutoReload(); } else checkSoon(); });
window.addEventListener("focus", checkSoon);

/* ---------- wiring ---------- */
for (const b of document.querySelectorAll(".tab")) b.addEventListener("click", () => { setTab(b.dataset.tab); setTopMenu(false); });
// the view options sit in a menu under the "⋯" button; a click outside or Escape closes it. A mouse opens it on hover and a
// click on the button pins it (hoverPin: open on hover, stick upon click); touch and pen only tap
const topHover = hoverPin(["#top-menu-btn", "#top-tools"], () => document.body.classList.contains("top-menu-open"), () => setTopMenu(true), () => setTopMenu(false), "hover-top-menu");
function setTopMenu(open) {
  topHover.reset();
  document.body.classList.toggle("top-menu-open", open);
  $("#top-menu-btn").setAttribute("aria-expanded", String(open));
}
$("#top-menu-btn").addEventListener("click", (e) => {
  e.stopPropagation();
  if (topHover.pin()) return;   // open by hover: the click pins it
  setTopMenu(!document.body.classList.contains("top-menu-open"));
});
// Reload in the view options (the installed app has no browser bar): the same path as the
// update banner's button, so the composer's draft is in sessionStorage before the page goes
$("#menu-reload").addEventListener("click", (e) => { setTopMenu(false); if (e.detail === 0) $("#top-menu-btn").focus(); reloadPage("menu"); });   // from the keyboard (detail 0) the focus goes back to ⋯, not to the body
// the overview hides the view options, so it carries the same Reload in its own head
$("#sp-reload").addEventListener("click", () => reloadPage("overview"));
$("#ld-reload").addEventListener("click", () => reloadPage("overview"));  // a lane's details page has the same head chip
document.addEventListener("click", (e) => { if (!e.target.closest("#top-tools, #top-menu-btn")) setTopMenu(false); });
// Escape closes the menu and the top layer (one per press); not one an IME is handling (a Korean composition in the mandate box)
document.addEventListener("keydown", (e) => { if (e.key === "Escape" && !e.isComposing) { setTopMenu(false); closeTopLayer(); } });
function setPlaceholder() { cm6Composer.setPlaceholder(composer, placeholderFor()); }
setPlaceholder();
window.matchMedia("(max-width: 760px)").addEventListener("change", setPlaceholder);
touchMode.addEventListener("change", setPlaceholder);
$("#show-back").addEventListener("change", (e) => { savePrefs({ showAll: e.target.checked }); renderSidebar(); });
// tool calls (and their results) are hidden by default; the class keeps them in the page, so the toggle needs no re-render
function applyShowTools() { document.body.classList.toggle("hide-tools", !state.prefs.showTools); $("#show-tools").checked = !!state.prefs.showTools; }
$("#show-tools").addEventListener("change", (e) => { savePrefs({ showTools: e.target.checked }); applyShowTools(); });
/* ---------- the sidebar on a wide screen ----------
   It is closed on every load; nothing of it is kept (no pref, no storage). The pointer on the
   strip along the left edge (#side-edge) or on the toggle (#side-open) peeks it open, and leaving the three (the strip, the
   toggle, the sidebar itself) closes it after a short moment, so the way from the toggle to the sidebar does not shut it.
   The toggle and the header (.side-head) are one fixed block at the top left, the same in every state (style.css).
   A click on the toggle pins it until the next click, for this page only, and a pinned sidebar DOCKS beside the page (the title bar and chat move right; a peek slides over the page, title bar included). It stays open while the New session form
   is up or a group is being dragged, and while the pointer is still on it. A phone keeps its drawer. */
const narrow = () => window.matchMedia("(max-width: 760px)").matches;
const side = { peek: false, pin: false, timer: 0 };
const SIDE_LEAVE_MS = 250;
function sideApply() {
  document.body.classList.toggle("side-peek", side.peek);
  document.body.classList.toggle("side-pin", side.pin);
  const btn = $("#side-open"), shown = side.peek || side.pin;
  btn.setAttribute("aria-expanded", String(shown));
  btn.setAttribute("aria-label", shown ? "Hide session list" : "Show session list");
  btn.title = shown ? "Hide sidebar" : "Show sidebar";
}
function sidePeek() {
  clearTimeout(side.timer);
  if (narrow() || side.pin) return;   // docked: it is open, there is nothing to peek
  side.peek = true;
  sideApply();
}
function sideLeave() {
  clearTimeout(side.timer);
  if (!narrow() && side.peek) side.timer = setTimeout(sideSettle, SIDE_LEAVE_MS);
}
function sideSettle() {
  const held = !!drag || ["#side-edge", "#sidebar", "#side-open"].some((s) => $(s).matches(":hover"));
  if (held) { side.timer = setTimeout(sideSettle, SIDE_LEAVE_MS); return; }
  side.peek = false;
  sideApply();
}
// the update banner sits above the title bar and pushes it down; the fixed toggle and header follow it (style.css, --banner-h)
new ResizeObserver(() => document.documentElement.style.setProperty("--banner-h", $("#update-banner").offsetHeight + "px")).observe($("#update-banner"));
for (const el of [$("#side-edge"), $("#sidebar"), $("#side-open")]) {
  el.addEventListener("mouseenter", sidePeek);
  el.addEventListener("mouseleave", sideLeave);
}
// the drawer is a page of its own on a phone: opened by a tap it has a history entry, and Back closes it ("selection,
// hash, history" above); a row tapped in it only hides it, the navigation's own history step closes its entry
$("#side-open").addEventListener("click", () => {
  if (narrow()) { openDrawer(); return; }
  side.pin = !side.pin;
  clearTimeout(side.timer);
  // Pinning docks it (style.css: beside the page, the title bar and chat move right), closing takes it away at once; either way a
  // peek that was under way is over: after a dock the pointer is no longer on the button (it moved right with the title bar), so
  // a peek left standing would only wait for its leave timer, and after a close the pointer is on nothing yet
  side.peek = false;
  if (!side.pin) { const sb = $("#sidebar"); sb.style.transition = "none"; setTimeout(() => { sb.style.transition = ""; }, 60); }   // unpinning: it goes at once, not sliding out over the title bar that has just moved back
  sideApply();
});
$("#side-close").addEventListener("click", closeDrawer);
$("#scrim").addEventListener("click", closeDrawer);
window.matchMedia("(max-width: 760px)").addEventListener("change", (e) => {   // widened: the drawer is no page any more; the sidebar starts closed at either width
  if (!e.matches) closeDrawer();
  clearTimeout(side.timer);
  side.peek = side.pin = false;
  sideApply();
});
// the overview row closes the sliding sidebar as a session row does (also when the overview is already open)
for (const id of ["#side-ovw", "#side-new"]) $(id).addEventListener("click", (e) => { if (!(e.ctrlKey || e.metaKey || e.shiftKey || e.button !== 0)) setDrawer(false); });

/* ---------- the sidebar's search box ----------
   At the top of the sidebar on every page (the drawer's top on a phone). Enter opens the Search results page with the box's
   defaults (search.js boxHash) in a NEW TAB, so the page and the chat he was on stay as they are; the box has no filters, the page has them.
   Where replaceMode() holds (the installed app, a phone's width) the results open in place (search.js fromBox): a new window there lands
   in Chrome's in-app view, outside sala (see the link handler above). A browser that blocks the new tab (window.open answers null) gets
   the in-place search too, so Enter never does nothing. The new tab is the same page with the search address, which the page opens as a
   reload or a shared link does. The results page's own box and filters search again in place. Ctrl+K (or Cmd+K), anywhere, and "/" outside a text field
   and the composer put the cursor in it: on a wide screen a focused box holds the sidebar open (style.css, #sidebar:has(:focus-visible)),
   on a phone the drawer opens first. Escape leaves the box (and the global Escape then closes the drawer on a phone). */
const sideQ = $("#side-q");
function focusSearch() {
  if (narrow() && !drawerIsOpen()) openDrawer();
  sideQ.focus({ preventScroll: true });
  sideQ.select();
}
$("#side-search").addEventListener("submit", (e) => {
  e.preventDefault();
  const h = search.boxHash(sideQ.value);
  if (!h) return;
  if (!replaceMode()) {
    const w = window.open(location.href.split("#")[0] + h, "_blank");   // not the "noopener" feature: it always answers null, and null is how a block is told
    if (w) { w.opener = null; sideQ.blur(); return; }
  }
  setDrawer(false);   // hidden now; its history entry goes with the navigation (go)
  sideQ.blur();
  search.fromBox(sideQ.value);
});
sideQ.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && !e.isComposing) sideQ.blur();
});
document.addEventListener("keydown", (e) => {
  if (e.isComposing || e.defaultPrevented) return;
  const k = e.key.toLowerCase();
  if (k === "k" && (e.ctrlKey || e.metaKey) && !e.altKey && !e.shiftKey) { e.preventDefault(); focusSearch(); }
  else if (e.key === "/" && !e.ctrlKey && !e.metaKey && !e.altKey && !inTextField()) { e.preventDefault(); focusSearch(); }
});

// Install as an app: the service worker at the site root (sw.js, served by app.py) is there for the app's
// installability and intercepts nothing (it has no fetch handler); registered once the page has loaded, so it never competes with the first
// paint. A browser without service workers, or a refused registration (a plain http origin, a blocked script),
// changes nothing: the page works the same without it.
if ("serviceWorker" in navigator) {
  // its lifecycle is marked for the timing log: a worker taking over the page (controllerchange) or installing anew
  const watch = (w) => { if (w) w.addEventListener("statechange", () => perfMark("sw:statechange", { state: w.state })); };
  const register = () => {
    navigator.serviceWorker.register("sw.js").then((reg) => {
      perfMark("sw:registered", { controlled: !!navigator.serviceWorker.controller, installing: !!reg.installing, waiting: !!reg.waiting, active: !!reg.active });
      watch(reg.installing);
      reg.addEventListener("updatefound", () => { perfMark("sw:updatefound"); watch(reg.installing); });
    }).catch((e) => perfMark("sw:error", { msg: String(e && e.message || e).slice(0, 120) }));
  };
  navigator.serviceWorker.addEventListener("controllerchange", () => perfMark("sw:controllerchange"));
  if (document.readyState === "complete") register();
  else window.addEventListener("load", register, { once: true });
}

/* ---------- the shell drawer ----------
   A small console under the page (a bottom sheet over it on a phone): the Shell button at the right end of the title bar, on
   every page, opens it; Ctrl+` toggles it unless focus is in a text field. It is sala's ttyd on /tty/?arg=<shell session>, the
   same sign-in as the Terminal tab, attached to the tmux session sala names in SALA_SHELL_SESSION (api/config shellSession; a plain login bash on this machine, never a Claude
   pane). ttyd-tmux-attach attaches only to a session that exists, so each open first asks the server to make sure it does
   (POST api/shell/open: creates it when missing, touches it not at all otherwise); the frame is built the first time the
   drawer opens (lazily, never at page load) and kept while it is closed: closing hides the drawer and the shell keeps running.
   `created: true` in the answer means the old shell had ended (typed `exit`), so the frame is built again.
   Kept: whether it is open, per browser (localStorage: a phone and a desktop differ, and a sheet with a backdrop must not
   come up on the phone because the desktop left it open), and its height on a wide screen in api/prefs (shellHeight, like laneOrder:
   it follows the owner to every browser). The phone's key row sends keys the soft keyboard lacks through POST api/shell/keys (a
   fixed list of tmux key names, never text); Ctrl is sticky: the next key of the row, or the next letter typed into the terminal,
   goes as Ctrl+key. */
const SHELL_OPEN_KEY = "salaweb.shellOpen";
const SHELL_MIN_H = 120;
const shell = { open: false, ctrl: false, seq: 0, drag: null, noteTimer: 0, saveTimer: 0 };
const shellBtn = $("#shell-btn"), shellDrawer = $("#shell-drawer"), shellHost = $("#shell-term");

// the tallest it may be: three quarters of what is visible, so the page above it always keeps a bar and a composer
function shellMaxH() { const vh = (window.visualViewport && window.visualViewport.height) || window.innerHeight; return Math.max(SHELL_MIN_H, Math.floor(vh * 0.75)); }
function shellClampH(h) { return Math.min(shellMaxH(), Math.max(SHELL_MIN_H, Math.round(Number(h) || 300))); }
function applyShellHeight() { shellDrawer.style.setProperty("--shell-h", shellClampH(state.prefs.shellHeight) + "px"); }
window.addEventListener("resize", () => { if (shell.open && !shell.drag) applyShellHeight(); });

function shellNote(text) {
  const n = $("#shell-note");
  n.textContent = text;
  clearTimeout(shell.noteTimer);
  if (text) shell.noteTimer = setTimeout(() => { n.textContent = ""; }, 6000);
}

// the frame, as loadTerminal builds the Terminal tab's: same-origin ttyd, the clipboard allowed, OSC 52 hooked
async function ensureShellFrame() {
  const seq = ++shell.seq;
  let created = false, session = "";
  try {
    const r = await apiFetch("api/shell/open", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
    const d = await r.json().catch(() => ({}));
    if (!r.ok || !d.ok) throw new Error(d.error || r.statusText);
    created = !!d.created;
    session = d.session;   // the session the server made or found: the frame attaches to that one
    if (!session) throw new Error("the server did not name the shell session");
  } catch (e) {
    if (!shellHost.querySelector("iframe")) shellHost.replaceChildren(el("div", { class: "empty", text: "Could not start the shell: " + e.message }));
    else shellNote("Could not check the shell: " + e.message);
    return;
  }
  if (!shell.open || seq !== shell.seq) return;   // closed again (or opened again) while the server answered
  shellNote("");
  if (!created && shellHost.querySelector("iframe")) return;
  const frame = el("iframe", { src: state.terminalUrl + encodeURIComponent(session), title: "Shell" + (state.host ? " on " + state.host : ""), allow: "clipboard-read; clipboard-write" });
  shellHost.replaceChildren(frame);
  hookTerminalClipboard(frame);
  frame.addEventListener("load", () => hookShellCtrl(frame));
  // the frame takes the focus when it has loaded, unless the drawer was closed meanwhile or the focus went to the composer or another field
  if (!narrow()) frame.addEventListener("load", () => {
    if (!shell.open || inTextField()) return;
    try { frame.contentWindow.focus(); } catch { /* cross-origin */ }
  }, { once: true });
}

/* the names the server told (api/config: this machine's short hostname and sala's SALA_SHELL_SESSION) on the button, the chip and the
   full-size link; painted when the config arrives and again when the drawer opens */
function paintShellNames() {
  $("#shell-full").href = "terminal?arg=" + encodeURIComponent(state.shellSession);   // the full-size page (terminal.html), not ttyd's bare page: it carries the clipboard code
  $("#shell-chip").textContent = (state.host ? state.host + " \u00b7 " : "") + state.shellSession;
  shellBtn.title = "Shell" + (state.host ? " on " + state.host : "") + " (Ctrl+`)";
}

function setShell(open, remember = true) {
  shell.open = open;
  shellDrawer.hidden = !open;
  document.body.classList.toggle("shell-open", open);
  shellBtn.setAttribute("aria-expanded", String(open));
  if (remember) { try { localStorage.setItem(SHELL_OPEN_KEY, open ? "1" : "0"); } catch { /* storage unavailable */ } }
  if (open) {
    applyShellHeight();
    paintShellNames();
    ensureShellFrame();
  } else {
    shell.seq++;
    setShellCtrl(false);
    if (shellDrawer.contains(document.activeElement)) (shellBtn.closest("#top-tools") ? $("#top-menu-btn") : shellBtn).focus();   // folded into the ⋯ menu (closed by now): its button
  }
}
const toggleShell = () => setShell(!shell.open);

// Ctrl+` toggles, unless focus is in a text field (the composer is a contenteditable)
function inTextField() {
  const a = document.activeElement;
  if (!a || a === document.body) return false;
  return /^(INPUT|TEXTAREA|SELECT)$/.test(a.tagName) || a.isContentEditable;
}
// one handler wherever the button is: in the bar, or folded into the ⋯ menu as a row, where the tap also closes the menu
// A keyboard activation (detail 0) of the folded row puts the focus back on ⋯ (the menu closes under it); a wide screen's drawer then
// takes the focus into its terminal when the frame loads, and a phone's sheet leaves it on ⋯, where closing the sheet returns it too.
shellBtn.addEventListener("click", (e) => {
  if (shellBtn.closest("#top-tools")) { setTopMenu(false); if (e.detail === 0) $("#top-menu-btn").focus(); }
  toggleShell();
});
$("#shell-close").addEventListener("click", () => setShell(false));
$("#shell-scrim").addEventListener("click", () => setShell(false));
document.addEventListener("keydown", (e) => {
  if (e.isComposing) return;
  if (e.key === "`" && e.ctrlKey && !e.metaKey && !e.altKey && !e.shiftKey && !inTextField()) { e.preventDefault(); toggleShell(); }
  else if (e.key === "Escape" && shell.open && narrow()) setShell(false);   // a sheet over the page closes like one
});

// the height: dragged by the handle (a wide screen), or with the arrow keys on it; saved when the move ends
function saveShellHeight(h) { clearTimeout(shell.saveTimer); shell.saveTimer = setTimeout(() => savePrefs({ shellHeight: h }), 300); }
const shellHandle = $("#shell-handle");
shellHandle.addEventListener("pointerdown", (e) => {
  if (narrow() || e.button !== 0) return;
  e.preventDefault();
  try { shellHandle.setPointerCapture(e.pointerId); } catch { /* no capture: the body class still keeps the frame from taking the pointer */ }
  shell.drag = { y: e.clientY, h: shellDrawer.getBoundingClientRect().height, now: null };
  document.body.classList.add("shell-dragging");
});
shellHandle.addEventListener("pointermove", (e) => {
  if (!shell.drag) return;
  shell.drag.now = shellClampH(shell.drag.h + (shell.drag.y - e.clientY));
  shellDrawer.style.setProperty("--shell-h", shell.drag.now + "px");
});
function endShellDrag() {
  if (!shell.drag) return;
  const h = shell.drag.now;
  shell.drag = null;
  document.body.classList.remove("shell-dragging");
  if (h != null) { state.prefs.shellHeight = h; saveShellHeight(h); }
}
for (const t of ["pointerup", "pointercancel", "lostpointercapture"]) shellHandle.addEventListener(t, endShellDrag);
shellHandle.addEventListener("keydown", (e) => {
  if (narrow() || (e.key !== "ArrowUp" && e.key !== "ArrowDown")) return;
  e.preventDefault();
  const h = shellClampH(shellDrawer.getBoundingClientRect().height + (e.key === "ArrowUp" ? 24 : -24));
  state.prefs.shellHeight = h;
  shellDrawer.style.setProperty("--shell-h", h + "px");
  saveShellHeight(h);
});

// the key row (a phone): each button is one fixed key name for the server; Ctrl arms the next key
function setShellCtrl(on) {
  shell.ctrl = on;
  $("#shell-ctrl").setAttribute("aria-pressed", String(on));
}
async function sendShellKey(key) {
  try {
    const r = await apiFetch("api/shell/keys", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ key }) }, { tries: 1 });
    if (!r.ok) {
      const d = await r.json().catch(() => ({}));
      throw new Error(d.error || r.statusText);
    }
  } catch (e) {
    shellNote("Key not sent: " + e.message);
  }
}
// a tap on a key must not take the focus from the terminal (the soft keyboard would close): the press itself is cancelled, the click still fires
for (const ev of ["pointerdown", "mousedown"]) {
  $("#shell-keys").addEventListener(ev, (e) => { if (e.target.closest("button[data-key]")) e.preventDefault(); });
}
$("#shell-keys").addEventListener("click", (e) => {
  const b = e.target.closest("button[data-key]");
  if (!b) return;
  const key = b.dataset.key;
  if (key === "ctrl") { setShellCtrl(!shell.ctrl); return; }
  setShellCtrl(false);   // Ctrl lasts for one key; Ctrl+C is its own button, and Esc, Tab and the arrows have no Ctrl form here
  sendShellKey(key);
});
// a letter typed into the terminal while Ctrl is armed goes as Ctrl+letter (best effort: a soft keyboard that reports no key
// name, "Unidentified", is sent as typed and Ctrl stays armed for the row)
function hookShellCtrl(frame) {
  let doc = null;
  try { doc = frame.contentDocument; } catch { return; }
  if (!doc || doc.__shellCtrl) return;
  doc.__shellCtrl = true;
  doc.addEventListener("keydown", (e) => {
    if (!shell.ctrl || e.ctrlKey || e.metaKey || e.altKey || !/^[a-zA-Z]$/.test(e.key)) return;
    e.preventDefault();
    e.stopPropagation();
    setShellCtrl(false);
    sendShellKey("C-" + e.key.toLowerCase());
  }, true);
}

// on load: the same open/closed as this browser left it (the frame is built only then, still lazily)
function shellRestore() {
  let was = false;
  try { was = localStorage.getItem(SHELL_OPEN_KEY) === "1"; } catch { /* storage unavailable */ }
  applyShellHeight();
  if (was) setShell(true, false);
}

// the title bar's name: "salamander", then " : <suffix>" when the config (SALA_BRAND_SUFFIX, via api/config) has one; textContent only
function paintBrand(suffix) {
  const el = document.querySelector(".brand");
  if (el) el.textContent = suffix ? "salamander : " + suffix : "salamander";
}

(async function init() {
  perfMark("init", { controlled: !!(navigator.serviceWorker && navigator.serviceWorker.controller), hash: location.hash.slice(0, 40) });
  await Promise.all([
    (async () => {
      try {
        upd.lastCheck = Date.now();
        const c = await (await apiFetch("api/config", { cache: "no-store" })).json();
        if (c.terminalUrl) state.terminalUrl = c.terminalUrl;
        if (c.shellSession) state.shellSession = c.shellSession;
        if (typeof c.host === "string") state.host = c.host;
        if (Array.isArray(c.scopes)) ns.scopes = c.scopes.filter((x) => typeof x === "string");
        if (typeof c.defaultScope === "string") state.defaultScope = c.defaultScope;
        paintBrand(typeof c.brand === "string" ? c.brand : "");
        applyZone(c);
        paintShellNames();
        noteVersion(c.version);
      } catch { /* default */ }
    })(),
    loadPrefs(),
    Promise.race([loadLaneNames(), sleep(800)]),   // the lanes' display names (sala's): waited for briefly; a label says the lane code until they come, and the next poll draws them
  ]);
  // the toggle used to live in this browser's localStorage: carry it over once
  try {
    const legacy = localStorage.getItem("salaweb.showBack");
    if (legacy != null) {
      localStorage.removeItem("salaweb.showBack");
      if (JSON.parse(legacy) === true && !state.prefs.showAll) savePrefs({ showAll: true });
    }
  } catch { /* storage unavailable */ }
  $("#show-back").checked = !!state.prefs.showAll;
  applyShowTools();
  // the board items are read beside the sessions (the server answers both from its caches), for the New session page's
  // item picker alone; nothing of the first paint waits for them
  loadBoard();
  await loadSessions();
  const name = hashName();
  if (name) perfMark("restore", { session: name });
  if (replaceMode() && !name && !overviewFamily() && !newPageHash() && !searchHash()) {
    // a phone or the installed app launched with no view: the view it was last on (a session still live), else the Overview
    const last = rememberedView(), lastName = hashName(last);
    navWrite(nav.cur, lastName !== null && state.byName.has(lastName) ? last : "#sessions", false);
  } else if (!replaceMode() && name === null && !overviewFamily() && !newPageHash() && !searchHash()) {
    // a wide browser launched with no view: the Overview, not an empty "Select a session" page; the launch entry is
    // rewritten (replaceState), so Back is what it is for a #sessions deep link
    navWrite(nav.cur, "#sessions", false);
  }
  route();  // the overview or the session; the session's draft goes back into the composer (selectSession)
  if (nav.reload) { const n = nav.reload; nav.reload = 0; navBack(n); }  // layers the page had before a reload are left: Back then leaves
  refreshSendButton();
  shellRestore();
  setInterval(loadSessions, 10000);
  setInterval(checkVersion, 60000);
  setInterval(() => { if (!document.hidden) loadBoard(); }, BOARD_MS);
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) return;
    if (state.selected) { loadSessions(); }  // a reply that landed while the page was hidden is read now that it is in view
    if (Date.now() - board.lastAt > 5000) loadBoard();
  });
})();

