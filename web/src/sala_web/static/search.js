"use strict";
/* Search: the sidebar's search box (#side-search, on every page) and the Search results page (#search-pane, a page of its own at
   #search?q=…). Enter in the box opens the page, in a new tab where the browser allows it (app.js), with the box's defaults: the last 6 hours, front agents only, messages only. The page
   is the results list under its own query box (#se-query) and the When / Agents / Content filters; Enter in that box runs the search again
   with the filters as they are, and an empty query does nothing, as in the sidebar's box. The query and every filter are in the
   address (the same parameters api/search takes), so a reload, Back and a shared link open the same search; changing a filter runs
   the search again and rewrites the address in place (no new history entry: Back still leaves the page). The search runs ON THE
   SERVER (api/search, search.py), which sends back only the matches as short snippets, never a transcript. The query is plain words
   (every word must be in the same entry; "quoted words" are one phrase).
   Boxes: Agents (front, background, their subagents, and "role unknown": an agent whose role nobody knows is shown, never dropped) and
   Content (messages, tool calls, tool output and thinking). The number beside a box is what it adds to the answer (the server counts
   every box whatever is ticked), so a box says what it hides before it is ticked.
   Results are the server's: newest first, at most its cap, each with the agent's CURRENT name (the server keys them on the agent's
   permanent id, so a rename or a /clear never splits one). A result of an agent that is running opens its chat at that entry however
   far back it is (app.js openAt: the server's `pos` is the entry's line in the transcript, and the chat loads the page around it);
   a subagent's opens its agent's chat at the Agent/Task call that started the subagent (the server's `target` and `pos`). Every text
   is set as a text node (the snippet comes in parts: [text, 1] is a matched word, marked), never as HTML. The last search's results
   stay in memory, so Back from a result's chat (the same address) shows them again without asking the server. Opening a result is
   a history entry at every width (go's push option: on a phone the other moves replace the entry, this one does not), so Back from
   the chat returns to the results page, with the query and filters read from its address.
   `el`, `apiFetch`, `state`, `openAt`, `zone`, `go` and `replaceHash` come from app.js and shared.js (used at call time). Everything
   else stays in this closure. */
const search = (() => {
const PAGE = 25;                      // results shown at first, and each "Show more"
const BOXES = ["front", "back", "sub", "unknown", "messages", "tools", "output", "thinking"];
const DEFAULT_ON = new Set(["front", "messages"]);   // a search started from the box: front agents' messages
const DEFAULT_HOURS = "6";                           // ... of the last 6 hours (an address that names its hours keeps them)
const HOURS = ["1", "6", "24", "72", "168"];
const ROLE_WORD = { front: "srch.role.front", back: "srch.role.back", unknown: "srch.role.unknown" };
const KIND_WORD = { messages: "srch.kind.messages", tools: "srch.kind.tools", output: "srch.kind.output", thinking: "srch.kind.thinking" };
const PRESET_WORD = { 1: "ui.se.h1", 6: "ui.se.h6", 24: "ui.se.h24", 72: "ui.se.d3", 168: "ui.se.d7" };
/* error: what failed, as { status, detail } (an HTTP status the page words itself, or a text from the server or the browser, shown as it is);
   msg: the page's own line while there is no answer ({ key, cls }). Both are worded when drawn, so a language change words them again. */
const se = { hours: DEFAULT_HOURS, ran: null, hash: "", data: null, shown: PAGE, seq: 0, ctl: null, error: null, msg: null };
const $in = (sel) => document.querySelector("#search-pane " + sel);
const num = (n) => SalaI18n.number(Number(n));
const errText = (er) => tl("srch.err.failed", { error: er.status ? tl("common.serverAnswered", { status: er.status }) : er.detail });

/* ---------- the address: #search?<the api/search parameters> ---------- */
function params(f) {
  const p = new URLSearchParams();
  p.set("q", f.q);
  if (f.hours === "dates") {
    p.set("from", f.from);
    if (f.to) p.set("to", f.to);
  } else p.set("hours", f.hours);
  for (const b of BOXES) p.set(b, f.boxes[b] ? "1" : "0");
  return p;
}
const hashOf = (f) => "#search?" + params(f);
// a search the box starts: its defaults
function fresh(q) {
  const boxes = {};
  for (const b of BOXES) boxes[b] = DEFAULT_ON.has(b);
  return { q, hours: DEFAULT_HOURS, from: "", to: "", boxes };
}
// the search an address describes; what it leaves out is the box's default
function parse(h) {
  const i = h.indexOf("?"), p = new URLSearchParams(i < 0 ? "" : h.slice(i + 1));
  const f = fresh((p.get("q") || "").trim().slice(0, 200));
  if (p.get("from")) { f.hours = "dates"; f.from = p.get("from"); f.to = p.get("to") || ""; }
  else if (HOURS.includes(p.get("hours"))) f.hours = p.get("hours");
  for (const b of BOXES) if (p.has(b)) f.boxes[b] = p.get(b) === "1";
  return f;
}
function readForm() {
  const boxes = {};
  for (const b of BOXES) boxes[b] = $in("#se-" + b).checked;
  return { q: se.ran ? se.ran.q : "", hours: se.hours, from: $in("#se-from").value, to: $in("#se-to").value, boxes };
}
function fillForm(f) {
  for (const b of BOXES) $in("#se-" + b).checked = f.boxes[b];
  $in("#se-from").value = f.from;
  $in("#se-to").value = f.to;
  setRange(f.hours);
  for (const box of [$in("#se-query"), document.getElementById("side-q")]) if (box && document.activeElement !== box) box.value = f.q;
}

/* run the search f describes; a newer one cancels the one still running */
async function run(f) {
  se.ran = f;
  se.hash = hashOf(f);
  if (se.ctl) { se.ctl.abort(); se.ctl = null; }
  const seq = ++se.seq;
  se.data = null; se.error = null;
  if (!f.q) { se.msg = { key: "srch.msg.type", cls: "error" }; render(); return; }
  if (f.hours === "dates" && !f.from) { se.msg = { key: "srch.msg.pickFrom", cls: "error" }; render(); return; }
  const ctl = se.ctl = new AbortController();
  se.msg = { key: "srch.msg.searching", cls: "" };
  render();
  try {
    const r = await apiFetch("api/search?" + params(f), { cache: "no-store", signal: ctl.signal }, { tries: 1 });
    const d = await r.json().catch(() => ({}));
    if (seq !== se.seq) return;
    if (!r.ok) throw d.error ? new Error(d.error) : Object.assign(new Error("the server answered " + r.status), { status: r.status });
    se.data = d; se.shown = PAGE; se.msg = null;
  } catch (e) {
    if (seq !== se.seq || (e && e.name === "AbortError")) return;
    se.error = { status: e && e.status, detail: e && e.message ? e.message : String(e) };
    se.msg = null;
  }
  se.ctl = null;
  render();
}

/* a filter changed on the page: the address follows (in place) and the search runs again */
function rerun() {
  const f = readForm();
  if (f.hours === "dates" && !f.from) return;      // no From yet: nothing to search, the address keeps the last search
  replaceHash(hashOf(f));
  run(f);
}

/* Enter in the page's own box: the query changes, the filters stay; the address follows in place, as for a filter. Empty: nothing, as in the sidebar's box */
function rerunQuery() {
  const q = $in("#se-query").value.trim().slice(0, 200);
  if (!q) return;
  $in("#se-query").value = q;   // trimmed, as the address will have it
  const f = { ...readForm(), q };
  if (f.hours === "dates" && !f.from) return;
  replaceHash(hashOf(f));
  const side = document.getElementById("side-q");
  if (side && document.activeElement !== side) side.value = q;   // the sidebar's box follows
  run(f);
}

/* ---------- drawing ---------- */
function say(text, cls) {
  const s = $in("#se-summary");
  s.className = "se-summary" + (cls ? " " + cls : "");
  s.textContent = text;
}

/* a snippet's parts as text nodes, the matched words in <mark> */
function snippetNodes(parts) {
  return parts.map(([text, hit]) => (hit ? el("mark", { text }) : document.createTextNode(text)));
}

function hitRow(h) {
  const live = state.byName.has(h.name);
  const kind = (h.kind === "tools" && h.tool ? tl(KIND_WORD.tools) + " · " + h.tool : KIND_WORD[h.kind] ? tl(KIND_WORD[h.kind]) : h.kind);
  const meta = el("div", { class: "se-meta" },
    el("span", { class: "se-t", title: h.at || null, text: h.when || "" }),
    el("span", { class: "se-name", text: h.name }),
    el("span", { class: "se-role " + h.role, text: ROLE_WORD[h.role] ? tl(ROLE_WORD[h.role]) : h.role }),
    h.sub ? el("span", { class: "se-sub", text: tl("srch.hit.sub") }) : null,
    live ? null : el("span", { class: "se-gone", text: tl("srch.hit.gone") }),
    el("span", { class: "se-kind", text: kind }));
  const body = el("div", { class: "se-x" + (h.kind === "tools" ? " code" : "") }, ...snippetNodes(h.snippet));
  const li = el("li", { class: "se-hit" + (live ? " open" : ""), "data-agent": h.agent });
  if (!live) { li.append(meta, body); return li; }
  const a = el("a", { class: "se-link", href: "#s=" + encodeURIComponent(h.name), title: tl("srch.hit.open", { name: h.name }) }, meta, body);
  a.addEventListener("click", (e) => {
    if (e.button !== 0 || e.ctrlKey || e.metaKey || e.shiftKey || e.altKey) return;
    e.preventDefault();
    // the server says where in the agent's chat the entry is (pos, target): its own line, or for a subagent's entry the Agent/Task call
    // that started the subagent; an older server sends neither, and a subagent's entry then opens the chat at its end
    const target = h.target !== undefined ? h.target : (h.sub ? "" : h.uuid);
    openAt(h.name, target, { pos: Number.isInteger(h.pos) ? h.pos : null, session: h.session, push: true });
  });
  li.append(a);
  return li;
}

/* the number beside each box: what it adds (the server counts every box whatever is ticked) */
function drawCounts() {
  const c = se.data && se.data.counts;
  for (const b of BOXES) {
    const n = c ? (c.agents[b] !== undefined ? c.agents[b] : c.content[b]) : undefined;
    $in("#se-" + b).parentElement.querySelector("small").textContent = n === undefined ? "" : "(" + num(n) + ")";
  }
}

function summaryLine(d) {
  const from = se.ran.hours === "dates" ? d.fromText : PRESET_WORD[se.ran.hours] ? tl(PRESET_WORD[se.ran.hours]) : tl("srch.preset.hours", { n: se.ran.hours });
  const range = tl("srch.range", { from, to: d.toText });
  const secs = d.elapsedMs < 950 ? (d.elapsedMs / 1000).toFixed(1) : String(Math.round(d.elapsedMs / 100) / 10);
  const n = d.matches;
  return tl("srch.summary", { n, count: num(n), q: se.ran.q, range, secs });
}

/* what a search that found nothing can say: which unticked box has matches */
function emptyHint(d) {
  const off = [];
  const names = { front: tl("ui.se.front"), back: tl("ui.se.back"), sub: tl("ui.se.sub"), unknown: tl("ui.se.unknown"),
                  messages: tl("ui.se.messages"), tools: tl("ui.se.tools"), output: tl("ui.se.output"), thinking: tl("ui.se.thinking") };
  for (const b of BOXES) {
    const n = b in d.counts.agents ? d.counts.agents[b] : d.counts.content[b];
    if (!se.ran.boxes[b] && n > 0) off.push(`${names[b]} (${num(n)})`);
  }
  return off.length ? " " + tl("srch.hint.more", { list: off.join(", ") }) : "";
}

function render() {
  const sum = $in("#se-summary"), list = $in("#se-hits"), more = $in("#se-more");
  drawCounts();
  $in("#se-think-note").hidden = !$in("#se-thinking").checked;
  const d = se.data;
  if (!d) {
    list.replaceChildren(); more.hidden = true;
    if (se.error) say(errText(se.error), "error");
    else if (se.msg) say(tl(se.msg.key), se.msg.cls);
    return;
  }
  sum.className = "se-summary";
  sum.replaceChildren(summaryLine(d));
  if (!d.matches) sum.append(" " + tl("srch.none") + emptyHint(d));
  if (d.capped) sum.append(el("div", { class: "se-warn", text: tl("srch.capped", { shown: num(d.shown), matches: num(d.matches) }) }));
  if (d.timedOut) sum.append(el("div", { class: "se-warn", text: tl("srch.timedOut", { secs: num(d.deadlineS) }) }));
  const rows = d.results.slice(0, se.shown).map(hitRow);
  list.replaceChildren(...rows);
  const left = d.results.length - rows.length;
  more.hidden = left <= 0;
  if (left > 0) more.textContent = tl("srch.more", { n: Math.min(PAGE, left) });
}

/* ---------- the filters ---------- */
function setRange(h) {
  se.hours = h;
  for (const c of document.querySelectorAll("#search-pane #se-range .se-chip")) c.setAttribute("aria-pressed", String(c.dataset.hours === h));
  $in("#se-dates").hidden = h !== "dates";
  if (h === "dates") $in("#se-zone").textContent = zone.label ? tl("srch.inZone", { zone: zone.label }) : "";
}

let bound = false;
function bind() {
  if (bound) return;
  bound = true;
  $in("#se-form").addEventListener("submit", (e) => e.preventDefault());
  $in("#se-query").addEventListener("keydown", (e) => {
    if (e.key !== "Enter" || e.isComposing) return;
    e.preventDefault();
    rerunQuery();
  });
  for (const c of document.querySelectorAll("#search-pane #se-range .se-chip")) {
    c.addEventListener("click", () => { setRange(c.dataset.hours); rerun(); });
  }
  for (const id of ["#se-from", "#se-to"]) $in(id).addEventListener("change", () => { if (se.hours === "dates") rerun(); });
  for (const b of BOXES) $in("#se-" + b).addEventListener("change", () => { $in("#se-think-note").hidden = !$in("#se-thinking").checked; rerun(); });
  $in("#se-more").addEventListener("click", () => { se.shown += PAGE; render(); });
}

/* the page is shown for the address h: the same search as the last one is drawn from memory (Back from a result's chat), any other runs */
function show(h) {
  bind();
  const f = parse(h);
  fillForm(f);
  if (hashOf(f) === se.hash && (se.data || se.error || se.ctl)) { render(); return; }
  run(f);
}
/* the language changed: the page is worded again from the answer it holds (no new search); the typed query and filters are not touched */
SalaI18n.onChange(() => { if (bound) { setRange(se.hours); render(); } });
function hide() {
  if (se.ctl) { se.ctl.abort(); se.ctl = null; se.hash = ""; }   // a search cut short is not kept: the page asks again when it comes back
}
/* Enter in the sidebar's box: the address of the results page with the box's defaults ("" for a blank box) */
function boxHash(q) {
  q = q.trim().slice(0, 200);
  return q ? hashOf(fresh(q)) : "";
}
/* ... and that page opened in this tab (app.js opens it in a new tab where it can, and falls back to this) */
function fromBox(q) {
  const h = boxHash(q);
  if (!h) return false;
  go(h);
  return true;
}
return { show, hide, boxHash, fromBox };
})();
