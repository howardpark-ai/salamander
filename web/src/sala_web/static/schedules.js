"use strict";
/* The Overview's Schedules tab (#schedules; one table in a tab): every scheduled
   job of ours on this machine (the package-shipped timers are left out by the API) as api/schedules reports it (the server's last
   reading of systemd and cron, at most about 30 s old when the tab opens and read again behind it; nothing stored on disk). It is ONE table, Job | Category | What it does | When | Lane. When holds three
   lines (the schedule in plain words, "next …", "last …") and sorts by the next run; the phone's sort menu also offers "Last run".
   A heading sorts by its column and a second click reverses it; the default is Category, then Job A-Z. Ties always fall back to
   the category order, then the job's name, whichever way the sort runs, and a row with nothing in the sorted column (no category, no
   next run) comes last in both directions. The Category is the job's own project, the `project` the API reads from its unit file
   (X-Project=, set by `sala job add --project`): this file holds no table that places a job, and a job with no project shows "—" and
   is flagged "no project". There is no standing timer: the tab asks when it opens (app.js calls schedules.start()) and when Reload is
   pressed; the server answers with its last reading at once and reads again behind it, so the page asks again a few times while the
   answer says `refreshing` (load, below) and draws the new reading when it lands. On a phone the rows are cards (schedules.css) and a sort menu above them does the heading's work.
   `el`, `apiFetch` and `laneLabel` come from app.js and shared.js (used at call time). Everything else stays in this closure. */
const schedules = (() => {
/* the flag chips' words: a code the page does not know shows as the code itself */
const FLAG_KEYS = { failed: "app.ns.sw.failed", "no-service": "sch.flag.noService", "not-git": "sch.flag.notGit", "git-differs": "sch.flag.gitDiffers", "no-lane": "sch.flag.noLane", "bad-lane": "sch.flag.badLane", "no-project": "sch.flag.noProject", cron: "sch.flag.cron" };
const flagWord = (code) => (Object.hasOwn(FLAG_KEYS, code) ? tl(FLAG_KEYS[code]) : code);
const COLUMN_COUNT = 5;   // Job | Category | What it does | When | Lane (the headings are the page's static markup)
const SORT_OPTIONS = [["name", "ui.sc.job"], ["category", "ui.sc.category"], ["desc", "ui.sc.whatItDoes"], ["next", "sch.sort.next"], ["last", "sch.sort.last"], ["lane", "common.lane"]];   // the phone's sort menu
const DEFAULT_KEY = "category";
const sc = { data: null, error: null, flaggedOnly: false, active: false, seq: 0, key: DEFAULT_KEY, dir: 1, timer: 0, tries: 0 };
const $in = (sel) => document.querySelector("#ov-schedules " + sel);
/* an error is kept as its key and values, not as text, so it is worded again when the language changes; `status` is an HTTP status the
   page words itself, `error` a text from the server or the browser, shown as it is */
const errOf = (key, vars) => ({ key, vars: vars || {} });
const errText = (er) => (er ? tl(er.key, er.vars.status ? { ...er.vars, error: tl("common.serverAnswered", { status: er.vars.status }) } : er.vars) : "");
const sameErr = (a, b) => JSON.stringify(a) === JSON.stringify(b);

/* one chip a code (a job whose two unit files are both loose gets one "not in git", not two); the reasons are the tooltip */
function chips(flags) {
  const byCode = new Map();
  for (const f of flags) byCode.set(f.code, [...(byCode.get(f.code) || []), f.text]);
  return [...byCode].map(([code, texts]) => el("span", { class: "sc-chip sc-" + code, title: texts.join("\n"), text: flagWord(code) }));
}

/* a run time for a row, as the API writes it in the SALA_TZ zone with the day counted there ("today 08:45", "tomorrow 08:45",
   "yesterday 08:45", else "Sun Nov 8th 05:17"; no zone label, the header names the zone); the iso string (+04:00) is the tooltip */
function runTime(t) {
  return el("span", { title: t.iso, text: t.when || String(t.text).replace(/ \S+$/, "") });
}

/* a job's name: it breaks only at its hyphens, never inside a word (a <wbr> after each hyphen; the CSS keeps every word whole) */
function nameParts(name) {
  const segs = name.split("-");
  return segs.flatMap((seg, i) => (i === segs.length - 1 ? [seg] : [seg + "-", document.createElement("wbr")]));
}

/* the When cell: the schedule in plain words, then the next and the last run, each under a muted label. A failed or running result
   stays under "last"; a job that never ran says so there. The raw On… lines are the plain words' tooltip. */
function whenCell(t) {
  const raw = (t.schedule || []).join("\n");
  const r = t.result || {};
  const line = (cls, label, ...kids) => el("div", { class: "sc-when-" + cls }, el("span", { class: "sc-when-k", text: label }), " ", ...kids);
  const last = [t.last ? runTime(t.last) : el("span", { class: "sc-res-never", text: (r.state === "never" && r.text) || tl("sch.when.never") })];
  if (r.state === "failed" || r.state === "running") last.push(el("div", { class: "sc-res-" + r.state, text: r.text || r.state }));
  return [el("div", { class: "sc-when-plain sc-plain", title: raw || null, text: t.plain || raw || tl("sch.when.noSchedule") }),
          line("next", tl("app.ns.pr.next"), t.next ? runTime(t.next) : el("span", { class: "sc-muted", text: tl("ov.common.none") })),
          line("last", tl("sch.when.last"), ...last)];
}

/* the value `none` (X-Model-Lane=none: the job makes no model call) is an outlined chip; a unit with no X-Model-Lane at all reads
   "not set" in muted italics and is never a chip, so the two cannot be mistaken for each other */
function laneChip(t) {
  const note = t.lane_note || null;
  if (t.lane && !t.flags.some((f) => f.code === "bad-lane")) {
    const label = laneLabel(t.lane);
    return el("span", { class: "sc-lane lane-" + t.lane, text: label, title: [t.lane === "none" ? tl("sch.lane.noModelCall", { lane: label }) : label, note].filter(Boolean).join("\n") });
  }
  return t.lane ? el("span", { class: "sc-lane", text: t.lane, title: t.lane }) : el("span", { class: "sc-muted sc-unset", text: tl("ov.row.notSet") });
}

/* ---------- sorting ---------- */
const jobName = (t) => t.name.replace(/\.timer$/, "");
/* what each column sorts by: text lower-cased, a run time by its epoch; null or "" is "nothing here" and sorts last */
const SORT_VALUE = {
  name: (t) => jobName(t).toLowerCase(),
  category: (t) => t.project || "",
  desc: (t) => (t.summary || t.description || "").toLowerCase(),
  next: (t) => (t.next && typeof t.next.epoch === "number" ? t.next.epoch : null),
  last: (t) => (t.last && typeof t.last.epoch === "number" ? t.last.epoch : null),
  lane: (t) => t.lane || "",
};
const isEmpty = (v) => v === null || v === "";
const cmp = (x, y) => (x < y ? -1 : x > y ? 1 : 0);
/* the category order: the projects A-Z, a job with none after them all. It is read off the jobs themselves, never listed here. */
const categoryCmp = (a, b) => {
  const x = SORT_VALUE.category(a), y = SORT_VALUE.category(b);
  return isEmpty(x) !== isEmpty(y) ? (isEmpty(x) ? 1 : -1) : cmp(x, y);
};
/* the jobs sorted by a column, ascending (dir 1) or descending (dir -1): empty values last either way; ties by category order, then name */
function sortJobs(list, key = DEFAULT_KEY, dir = 1) {
  const value = SORT_VALUE[key] || SORT_VALUE[DEFAULT_KEY];
  return [...list].sort((a, b) => {
    const x = value(a), y = value(b);
    if (isEmpty(x) !== isEmpty(y)) return isEmpty(x) ? 1 : -1;
    const c = isEmpty(x) ? 0 : cmp(x, y) * (dir < 0 ? -1 : 1);
    return c || categoryCmp(a, b) || cmp(SORT_VALUE.name(a), SORT_VALUE.name(b));
  });
}
function pick(key) {   // a heading's click: the same column reverses, another starts ascending
  if (sc.key === key) sc.dir = -sc.dir; else { sc.key = key; sc.dir = 1; }
  render();
}

/* ---------- rows ---------- */
const cell = (cls, label, ...kids) => el("td", { class: "sc-c sc-c-" + cls, "data-label": label || null }, ...kids);
function jobRow(t) {
  const path = (t.runs && (t.runs.script || t.runs.line)) || "";   // the script is only a tooltip
  const flagged = t.flags.length > 0;
  const desc = t.summary || t.description || "";
  const tr = el("tr", { class: "sc-row" + (flagged ? " sc-flagged" : ""), "data-job": t.name });
  tr.append(
    cell("name", "", el("div", { class: "sc-name", title: path || null }, ...nameParts(jobName(t)))),
    cell("cat", "", t.project ? el("span", { class: "sc-cat", title: "X-Project=" + t.project, text: t.project }) : el("span", { class: "sc-muted sc-nocat", title: tl("sch.cat.noneTip"), text: "—" })),
    cell("desc", "", desc ? el("div", { class: "sc-desctext", text: desc }) : null, flagged ? el("div", { class: "sc-chips" }, ...chips(t.flags)) : null),
    cell("when", tl("ui.sc.when"), ...whenCell(t)),
    cell("lane", "", laneChip(t)));
  return tr;
}
function cronRow(c) {
  const tr = el("tr", { class: "sc-flagged" });
  tr.append(el("td", { "data-label": tl("ui.sc.schedule") }, el("span", { class: "sc-sched", text: c.schedule })),
            el("td", { "data-label": tl("ui.sc.command") }, el("span", { class: "sc-cmd", text: c.command })),
            el("td", { "data-label": tl("ui.sc.flags") }, el("div", { class: "sc-chips" }, ...chips(c.flags))));
  return tr;
}

/* the headings' arrows and the phone's sort menu follow the sort */
function showSort() {
  for (const th of document.querySelectorAll("#sc-table th")) {   // the When heading is the sorted one for "last" too (the phone's menu)
    th.setAttribute("aria-sort", th.dataset.key === (sc.key === "last" ? "next" : sc.key) ? (sc.dir > 0 ? "ascending" : "descending") : "none");
  }
  const sel = $in("#sc-sortsel"), dir = $in("#sc-sortdir");
  sel.value = sc.key;
  dir.textContent = sc.dir > 0 ? "▲" : "▼";
  dir.setAttribute("aria-label", tl(sc.dir > 0 ? "sch.sort.asc" : "sch.sort.desc"));
}

function render() {
  const body = $in("#sc-body");
  if (!body) return;
  showSort();
  const d = sc.data;
  const note = $in("#sc-note");
  note.textContent = errText(sc.error);
  note.classList.toggle("error", !!sc.error);
  if (!d) {
    $in("#sc-count").textContent = sc.error ? "" : tl("ui.sc.reading");
    body.replaceChildren();
    $in("#sc-cron").replaceChildren();
    $in("#sc-cron-sec").hidden = true;
    return;
  }
  const c = d.counts;
  document.getElementById("ov-n-schedules").textContent = String(c.timers);   // the tab's count
  const list = sortJobs(d.timers.filter((t) => !sc.flaggedOnly || t.flags.length), sc.key, sc.dir);
  const parts = [tl("sch.count.jobs", { n: c.timers }), tl("sch.count.cron", { n: c.cron }), tl("sch.count.flagged", { n: c.flagged })];
  const why = Object.entries(c.byReason).map(([k, n]) => tl("sch.count.reason", { n, reason: flagWord(k) }));
  $in("#sc-count").textContent = parts.join(" · ") + (why.length ? " (" + why.join(", ") + ")" : "") + (d.generated ? " · " + tl("sch.count.read", { when: d.generated.text }) : "")
    + " · " + tl("sch.count.hint");
  const notes = [];
  if (c.packaged) notes.push(tl("sch.note.packaged", { n: c.packaged }));
  if (d.scopes && d.scopes.system === false) notes.push(tl("sch.note.system"));
  $in("#sc-scope-note").textContent = notes.join(" ");
  body.replaceChildren(...list.map(jobRow));
  if (!list.length) {
    const tr = el("tr"), td = el("td", { class: "sc-empty", text: tl(sc.flaggedOnly ? "sch.empty.flagged" : "sch.empty.none") });
    td.colSpan = COLUMN_COUNT;
    tr.append(td);
    body.append(tr);
  }
  $in("#sc-cron-sec").hidden = false;
  $in("#sc-cron").replaceChildren(...d.cron.map(cronRow));
  $in("#sc-cron-none").hidden = d.cron.length > 0;
  $in("#sc-cron-table").hidden = d.cron.length === 0;
}

/* The server answers at once with its last reading (swr.py) and reads again behind it when that is 30 s old: `refreshing` on the
   answer means a newer one is on its way, `pending` that there is no reading yet (the placeholder stays). The page asks again every
   FOLLOW_MS (FOLLOW_MAX times at most, like the lane cards) and draws a reading only when it is a new one (its fetchedAt), so the
   table is replaced in one step and nothing else moves: the sort, the Flagged-only box and the scroll position are not touched.
   fresh (the Reload button) asks the server to read again now. */
const FOLLOW_MS = 1500;
const FOLLOW_MAX = 40;
async function load(fresh = false, follow = false) {
  const seq = ++sc.seq;
  clearTimeout(sc.timer);
  if (!follow) sc.tries = 0;
  let again = false, redraw = true;
  try {
    const r = await apiFetch("api/schedules" + (fresh ? "?fresh=1" : ""), { cache: "no-store" }, { tries: 2 });
    if (!r.ok) throw Object.assign(new Error("the server answered " + r.status), { status: r.status });
    const d = await r.json();
    if (seq !== sc.seq) return;
    again = !!d.refreshing;
    const have = !d.pending;   // else the server has no reading yet: the placeholder stays
    const failed = d.error ? (have ? (d.generated ? errOf("sch.err.stale", { when: d.generated.text }) : errOf("sch.err.staleNoTime"))
                                   : errOf("sch.err.read", { error: d.error })) : null;
    redraw = (have && (!sc.data || !d.fetchedAt || sc.data.fetchedAt !== d.fetchedAt)) || !sameErr(failed, sc.error);
    if (have) sc.data = d;
    sc.error = failed;
  } catch (e) {
    if (seq !== sc.seq) return;
    sc.error = e && e.status ? errOf("sch.err.read", { status: e.status }) : errOf("sch.err.read", { error: e && e.message ? e.message : String(e) });   // the last answer stays on screen
  }
  if (sc.active && redraw) render();
  if (again && sc.active && sc.tries++ < FOLLOW_MAX) sc.timer = setTimeout(() => load(false, true), FOLLOW_MS);
}
let bound = false;
function fillSortOptions() {
  const sel = $in("#sc-sortsel");
  sel.replaceChildren(...SORT_OPTIONS.map(([k, key]) => el("option", { value: k, text: tl(key) })));
  sel.value = sc.key;
}
function bind() {
  if (bound || !$in("#sc-body")) return;
  bound = true;
  $in("#sc-flagged").addEventListener("change", (e) => { sc.flaggedOnly = e.target.checked; render(); });
  document.getElementById("sc-reload").addEventListener("click", () => { sc.error = null; load(true); });
  for (const th of document.querySelectorAll("#sc-table th")) th.querySelector("button").addEventListener("click", () => pick(th.dataset.key));
  const sel = $in("#sc-sortsel");
  fillSortOptions();
  sel.addEventListener("change", () => { sc.key = sel.value; sc.dir = 1; render(); });
  $in("#sc-sortdir").addEventListener("click", () => { sc.dir = -sc.dir; render(); });
}
/* the tab opened: the last reading is drawn at once (the one this page already holds, else the server's); a newer one replaces it
   when it arrives. Nothing polls beyond that: Reload reads again. */
function start() {
  bind();
  sc.active = true;
  render();
  load();
}
function stop() {
  sc.active = false;
  clearTimeout(sc.timer);
}
/* the language changed: the options and the table are drawn again from the reading this page holds (no request) */
SalaI18n.onChange(() => { if (bound) { fillSortOptions(); render(); } });
return { start, stop, sortJobs };
})();
