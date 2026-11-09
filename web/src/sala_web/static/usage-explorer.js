"use strict";
/* The Usage analysis tab's Explorer view (#usage, the second view next to Report; usage.js has the tab and registers this view): any two things side by side,
   down to a single reply. It reads the same data layer as the Report (api/usage, usage.py) and one more route, api/usage/replies, for the replies behind a figure.
   COMPARE picks a dimension (Week, Day, Lane, Model, Project, Agent or Folder) and two of its values, A and B; BREAK DOWN BY splits both by another dimension; WHERE
   narrows both by any other dimension (a select each, the week one of them). The result is two cards side by side (the total at list prices, how much was billed,
   B against A), then one table: a row per value of the break-down, A and B beside each other with their change. A tap on a row opens the replies behind it for A or
   for B: the newest 200 with time, model, lane and dollars, and how many there are in all. The page shows DOLLARS only; the rows carry tokens and this file never reads them.
   The words that the Report also says (the total line, the flat-plan and per-use lane lines, the notes) are the Report's own, from usage.js's WORDS (usage.kit);
   the words below are only this view's. The view reads when it opens, when a week it needs is not loaded yet and on the tab's Reload.
   `el` and `apiFetch` come from app.js and `modelLabel` from shared.js (used at call time). Everything else stays in this closure. */
const usageExplorer = (() => {
const K = usage.kit, W = K.WORDS, esc = K.esc, usd = K.usd, fmtDay = K.fmtDay;
/* ---------- the words that are this view's own ---------- */
const X = {
  compare: "COMPARE", breakdown: "BREAK DOWN BY", where: "WHERE", none: "none", any: (l) => "Any " + l.toLowerCase(), clear: "Clear filters",
  notBilled: "not billed", vs: "vs", change: "Change", replies: "REPLIES", side: { a: "A", b: "B" },
  nothingSide: "Nothing to compare: pick a value.", noReplies: "No replies in this selection.", loadingReplies: "Reading the replies…",
  showing: (n, all) => `the newest ${n.toLocaleString("en-US")} of ${all.toLocaleString("en-US")}`, tapRow: "Tap a row to see the replies behind it.",
  howTo: "How to read this: pick what to compare (two lanes, two models, two days, two weeks…) and A and B; break both down by another dimension; narrow both with Where. "
    + "A tap on a row lists the replies behind it, newest first. Every figure is what the replies would cost at list prices.",
  cols: { k: "", a: "A", b: "B", d: "Change", ra: "A replies", rb: "B replies" },
  rep: { time: "Time", model: "Model", lane: "Lane", cost: "Cost", agent: "Agent" },
};
const DIMS = [["week", "Week"], ...W.dims];             // the dimensions a figure can be split, filtered or compared by
const TXT = (d) => DIMS.find((x) => x[0] === d)[1];
const FILTER_DIMS = W.dims.map((d) => d[0]);              // what the replies route filters on (the week goes in its own parameter)
const COLUMN = { week: 0, day: 1, lane: 2, model: 3, project: 4, agent: 5, folder: 6, usd: 7, replies: 8 };   // a row here: [week, ...api/usage's row without its tokens]
const BY_DEFAULTS = ["model", "lane", "project", "agent", "day", "folder"];
const POLL_MS = 3000, POLL_MAX = 40;
const SIDE_COLOR = { a: "var(--us-s0)", b: "var(--us-s1)" };

const ex = { active: false, bound: false, seq: 0, timer: 0, tries: 0, ago: 0, error: "", pending: false, noCount: false, data: {}, rows: [],
  cmp: "lane", a: undefined, b: undefined, by: "model", f: { week: "0" }, sort: "t", dir: -1, pick: null, side: "a", focus: "",
  rep: { seq: 0, status: "", data: null, tries: 0, timer: 0 }, ageTimer: 0 };
const $x = (sel) => document.querySelector("#us-v-explorer " + sel);

/* ---------- the data on hand ---------- */
const firstData = () => Object.values(ex.data)[0] || null;
const laneInfo = (code) => (((firstData() || {}).lanes) || []).find((l) => l.code === code) || null;
const laneName = (code) => { const l = laneInfo(code); return l && l.label ? l.label : code; };
const flatSet = () => new Set((((firstData() || {}).lanes) || []).filter((l) => l.flat).map((l) => l.code));
const get = (dim, r) => String(r[COLUMN[dim]]);
function nameOf(dim, k) {
  return dim === "week" ? W.weeks[+k] : dim === "lane" ? laneName(k) : dim === "model" ? modelLabel(k) : dim === "day" ? fmtDay(k) : k;
}
const serverNow = (d) => (d.now || Date.now() / 1000) + (performance.now() - ex.ago) / 1000;   // this page's own clock is not trusted
function needWeeks() {
  const ws = ex.cmp === "week" ? [ex.a, ex.b].filter((v) => v !== undefined && v !== "") : [ex.f.week];
  return [...new Set(ws.length ? ws : ["0"])].map(Number);
}
function rebuildRows() {
  ex.rows = [];
  for (const [w, d] of Object.entries(ex.data)) for (const r of d.rows || []) ex.rows.push([+w, r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7]]);   // the tokens (r[8]) stay behind
}
/* the rows every filter lets through, except the one of dimension `skip`; the week is a filter too unless it is what is compared */
function scope(skip) {
  return ex.rows.filter((r) => {
    for (const d of DIMS.map((x) => x[0])) {
      if (d === skip || d === ex.cmp) continue;
      const v = ex.f[d];
      if (v !== undefined && v !== "" && get(d, r) !== v) return false;
    }
    return true;
  });
}
const sideRows = (rs, v) => (v === undefined || v === "" ? [] : rs.filter((r) => get(ex.cmp, r) === v));
function agg(rs, dim) {
  const m = new Map();
  for (const r of rs) {
    const k = get(dim, r);
    let a = m.get(k);
    if (!a) m.set(k, a = { k, cost: 0, msgs: 0 });
    a.cost += r[COLUMN.usd]; a.msgs += r[COLUMN.replies];
  }
  return [...m.values()];
}
const total = (rs) => rs.reduce((s, r) => s + r[COLUMN.usd], 0);
const count = (rs) => rs.reduce((s, r) => s + r[COLUMN.replies], 0);
function billedOf(rs) { const flat = flatSet(); return rs.reduce((s, r) => s + (flat.has(r[COLUMN.lane]) ? 0 : r[COLUMN.usd]), 0); }
/* the values of a dimension in the rows on hand, most costly first (days: newest first) */
function valuesOf(dim, rs) {
  const g = agg(rs, dim);
  return dim === "day" ? g.sort((x, y) => (x.k < y.k ? 1 : -1)) : g.sort((x, y) => y.cost - x.cost);
}
function defaults() {
  if (ex.by === ex.cmp) ex.by = BY_DEFAULTS.find((d) => d !== ex.cmp);
  if (ex.cmp === "week") {
    if (ex.a === undefined) ex.a = "0";
    if (ex.b === undefined) ex.b = "1";
    return;
  }
  if (ex.a !== undefined && ex.b !== undefined) return;
  const vs = valuesOf(ex.cmp, scope(ex.cmp)).map((a) => a.k);
  if (!vs.length) return;
  if (ex.a === undefined) ex.a = vs[0];
  if (ex.b === undefined) ex.b = vs.find((v) => v !== ex.a) || "";
}

/* ---------- formatting ---------- */
const usdR = (v) => (v >= 1 ? usd(v) : "$" + v.toFixed(3));   // one reply is often a few cents: three decimals under a dollar
const signed = (v) => (v > 0.005 ? "+" : v < -0.005 ? "−" : "") + usd(Math.abs(v));
function weekRange(d, w) {
  const f = (s) => `${fmtDay(s.slice(0, 10))} ${s.slice(11, 16)}`;
  return `${f(w.startKst)} – ${f(w.endKst)} ${d.tzLabel || "KST"}`;
}

/* ---------- the controls ---------- */
const seg = (id, label, items, on, attr) => `<div id="${id}" class="us-seg ex-wrap" role="group" aria-label="${esc(label)}">`
  + items.map(([v, l]) => `<button type="button" data-fid="${id}-${esc(v)}" data-${attr}="${esc(v)}" aria-pressed="${v === on}">${esc(l)}</button>`).join("") + "</div>";
function optionList(dim, rs, cur) {
  let vs = dim === "week" ? [0, 1, 2].map((i) => ({ k: String(i), cost: total(rs.filter((r) => r[0] === i)), have: !!ex.data[i] })) : valuesOf(dim, rs).map((a) => ({ ...a, have: true }));
  if (cur && !vs.some((v) => v.k === cur)) vs = [...vs, { k: cur, cost: 0, have: true }];
  const flat = flatSet();
  return vs.map((v) => `<option value="${esc(v.k)}"${v.k === cur ? " selected" : ""}>${esc(nameOf(dim, v.k))}${v.have ? " · " + usd(v.cost) : ""}`
    + `${dim === "lane" && flat.has(v.k) ? " · " + X.notBilled : ""}</option>`).join("");
}
function renderControls(d) {
  const rs = scope(ex.cmp), picker = (side) => {
    const cur = ex[side];
    return `<label class="ex-pick"><span class="ex-badge" style="--sc:${SIDE_COLOR[side]}">${X.side[side]}</span><select id="ex-s${side}" data-fid="ex-s${side}" data-s="${side}" aria-label="${esc(X.side[side] + ": " + TXT(ex.cmp))}">`
      + `<option value=""${cur === "" ? " selected" : ""}>— ${X.none}</option>${optionList(ex.cmp, rs, cur)}</select></label>`;
  };
  const dims = DIMS.filter(([id]) => id !== ex.cmp);
  const sel = (dim) => {
    const cur = ex.f[dim] === undefined ? "" : ex.f[dim];
    const any = dim === "week" ? "" : `<option value=""${cur === "" ? " selected" : ""}>${esc(X.any(TXT(dim)))}</option>`;
    return `<label class="ex-f"><span class="us-lbl">${esc(TXT(dim).toUpperCase())}</span><select id="ex-f-${dim}" data-fid="ex-f-${dim}" data-f="${dim}">${any}${optionList(dim, scope(dim), cur)}</select></label>`;
  };
  const filtering = DIMS.some(([id]) => id !== "week" && id !== ex.cmp && ex.f[id]);
  let range = "";
  if (d && ex.cmp !== "week") {
    const wk = (ex.data[+ex.f.week] || d).weeks[+ex.f.week];
    if (wk) range = weekRange(d, wk) + (!d.resetKnown ? ` · ${W.unknownReset}` : wk.current ? ` · ${W.resets} ${K.untilText(wk.end - serverNow(d))}` : ` · ${W.closed}`);
  }
  $x("#ex-ctl").innerHTML = `<div class="ex-row"><span class="us-lbl">${X.compare}</span>${seg("ex-cmp", X.compare, DIMS, ex.cmp, "c")}</div>`
    + `<div class="ex-ab">${picker("a")}${picker("b")}</div>`
    + `<div class="ex-row"><span class="us-lbl">${X.breakdown}</span>${seg("ex-by", X.breakdown, W.dims.filter(([id]) => id !== ex.cmp), ex.by, "b")}</div>`
    + `<div class="ex-row ex-wh"><span class="us-lbl">${X.where}</span>${filtering ? `<button type="button" class="us-chip us-clear" data-fid="ex-clear" data-clear="1">${X.clear}</button>` : ""}</div>`
    + `<div class="ex-fgrid">${dims.map(([id]) => sel(id)).join("")}</div>`
    + (range ? `<div class="us-range ex-range">${esc(range)}</div>` : "");
}

/* ---------- the two sides ---------- */
function sideCard(side, rs, other) {
  const v = ex[side], color = SIDE_COLOR[side];
  if (v === undefined || v === "") return `<div class="us-card ex-side" style="--sc:${color}"><div class="ex-sh"><span class="ex-badge" style="--sc:${color}">${X.side[side]}</span></div><div class="us-sub">${esc(X.nothingSide)}</div></div>`;
  const t = total(rs), info = ex.cmp === "lane" ? laneInfo(v) : null;
  let delta = "";
  if (side === "b" && other && other.n) {
    const dl = other.t ? (t / other.t - 1) * 100 : null;
    delta = `<div class="ex-delta">${dl === null ? "" : `<span class="us-delta ${dl > 0 ? "up" : "down"}">${dl > 0 ? "+" : ""}${dl.toFixed(0)}%</span> `}<span class="us-faint">${X.vs} ${X.side.a} (${esc(signed(t - other.t))})</span></div>`;
  }
  return `<div class="us-card ex-side" style="--sc:${color}" data-side="${side}"><div class="ex-sh"><span class="ex-badge" style="--sc:${color}">${X.side[side]}</span>`
    + `<span class="ex-sn" title="${esc(nameOf(ex.cmp, v))}">${esc(nameOf(ex.cmp, v))}</span></div>`
    + `<div class="ex-amt us-num">${usd(t)}</div><div class="us-sub">${esc(W.total(billedOf(rs), count(rs)))}</div>`
    + (info ? `<div class="us-sm ex-lane">${esc(info.flat ? W.flatLane(null) : W.billedLane)}</div>` : "") + delta + "</div>";
}
function renderSides(rsA, rsB) {
  $x("#ex-sides").innerHTML = sideCard("a", rsA) + sideCard("b", rsB, { t: total(rsA), n: rsA.length });
}

/* ---------- the table ---------- */
function renderTable(rsA, rsB) {
  const ga = new Map(agg(rsA, ex.by).map((a) => [a.k, a])), gb = new Map(agg(rsB, ex.by).map((a) => [a.k, a]));
  const rows = [...new Set([...ga.keys(), ...gb.keys()])].map((k) => {
    const a = ga.get(k) || { cost: 0, msgs: 0 }, b = gb.get(k) || { cost: 0, msgs: 0 };
    return { k, a, b, d: b.cost - a.cost, t: a.cost + b.cost };
  });
  const val = { k: (r) => (ex.by === "day" ? r.k : nameOf(ex.by, r.k).toLowerCase()), a: (r) => r.a.cost, b: (r) => r.b.cost, d: (r) => r.d, t: (r) => r.t };
  rows.sort((x, y) => (val[ex.sort](x) > val[ex.sort](y) ? 1 : val[ex.sort](x) < val[ex.sort](y) ? -1 : 0) * ex.dir);
  const cols = [["k", TXT(ex.by), ""], ["a", X.cols.a, "r"], ["b", X.cols.b, "r"], ["d", X.cols.d, "r"]];
  $x("#ex-thead").innerHTML = cols.map(([id, l, c]) => `<th class="${c}" aria-sort="${ex.sort === id ? (ex.dir < 0 ? "descending" : "ascending") : "none"}"><button type="button" data-fid="ex-h-${id}" data-sort="${id}">`
    + `${id === "a" || id === "b" ? `<i class="ex-badge ex-sm" style="--sc:${SIDE_COLOR[id]}">${l}</i>` : esc(l)}</button></th>`).join("");
  const mx = Math.max(...rows.map((r) => Math.max(r.a.cost, r.b.cost)), 0.01), flat = flatSet();
  $x("#ex-tbody").innerHTML = rows.map((r) => {
    const on = ex.pick === r.k, pct = r.a.cost ? (r.b.cost / r.a.cost - 1) * 100 : null;
    return `<tr class="us-pick ex-pick-row${on ? " us-on" : ""}" data-k="${esc(r.k)}" tabindex="0"><td class="us-nm"><span class="ex-nm">${esc(nameOf(ex.by, r.k))}</span>`
      + `${ex.by === "lane" && flat.has(r.k) ? ` <span class="ex-nb">${X.notBilled}</span>` : ""}`
      + `<div class="ex-pair"><i class="ex-ba" style="width:${r.a.cost / mx * 100}%"></i><i class="ex-bb" style="width:${r.b.cost / mx * 100}%"></i></div></td>`
      + `<td class="r us-num"><b>${usd(r.a.cost)}</b><div class="ex-m us-hide-s">${r.a.msgs.toLocaleString("en-US")}</div></td>`
      + `<td class="r us-num"><b>${usd(r.b.cost)}</b><div class="ex-m us-hide-s">${r.b.msgs.toLocaleString("en-US")}</div></td>`
      + `<td class="r us-num ex-d ${r.d > 0.005 ? "up" : r.d < -0.005 ? "down" : ""}">${esc(signed(r.d))}<div class="ex-m us-hide-s">${pct === null ? "" : (pct > 0 ? "+" : "") + pct.toFixed(0) + "%"}</div></td></tr>`;
  }).join("") || `<tr><td colspan="4" class="us-empty">${W.nothing}</td></tr>`;
}

/* ---------- the replies behind a row ---------- */
function replyParams() {
  const v = ex[ex.side], week = ex.cmp === "week" ? +v : +ex.f.week, p = new URLSearchParams({ week: String(week) });
  for (const d of FILTER_DIMS) {
    const val = d === ex.cmp ? v : d === ex.by ? ex.pick : ex.f[d];   // a row's own value is the narrower one
    if (val !== undefined && val !== "") p.set(d, val);
  }
  return p;
}
async function loadReplies() {
  const R = ex.rep, seq = ++R.seq;
  clearTimeout(R.timer);
  if (ex.pick === null || ex[ex.side] === undefined || ex[ex.side] === "") { R.status = ""; R.data = null; renderReplies(); return; }
  if (!R.data || R.status === "error") R.status = "loading";
  renderReplies();
  try {
    const r = await apiFetch("api/usage/replies?" + replyParams(), { cache: "no-store" }, { tries: 2 });
    if (!r.ok) throw new Error("the server answered " + r.status);
    const d = await r.json();
    if (seq !== R.seq) return;
    if (d.pending) {   // the count behind the replies is not ready (a fresh server): ask again in a moment, a bounded number of times
      R.status = "loading";
      if (R.tries++ < POLL_MAX && ex.active) R.timer = setTimeout(() => loadReplies(), POLL_MS);
    } else if (d.noCount) {   // no count has been made yet (the replies come from a count's saved records): say so, Reload makes one
      R.tries = 0; R.data = { error: W.noCount }; R.status = "error";
    } else {
      R.tries = 0; R.data = d; R.status = d.error ? "error" : "ok";
    }
  } catch (e) {
    if (seq !== R.seq) return;
    R.status = "error"; R.data = { error: "Could not read the replies: " + (e && e.message ? e.message : e) };
  }
  if (ex.active) renderReplies();
}
function renderReplies() {
  const box = $x("#ex-replies"), R = ex.rep;
  box.hidden = ex.pick === null;
  if (ex.pick === null) { box.innerHTML = ""; return; }
  const sideBtn = (s) => {
    const v = ex[s], nm = v === undefined || v === "" ? "—" : nameOf(ex.cmp, v);
    return `<button type="button" data-fid="ex-rs-${s}" data-rside="${s}" aria-pressed="${ex.side === s}"><i class="ex-badge ex-sm" style="--sc:${SIDE_COLOR[s]}">${X.side[s]}</i><span class="ex-rn">${esc(nm)}</span></button>`;
  };
  let body = "";
  if (R.status === "loading" && !R.data) body = `<p class="ex-rmsg">${X.loadingReplies}</p>`;
  else if (R.status === "error" || (R.data && R.data.error)) body = `<p class="ex-rmsg error">${esc((R.data && R.data.error) || "Could not read the replies.")}</p>`;
  else if (R.data) {
    const d = R.data, flat = flatSet();
    const head = `<div class="ex-rsum"><b class="us-num">${d.total.toLocaleString("en-US")}</b> replies · <b class="us-num">${usd(d.usd)}</b>${d.capped ? ` · ${esc(X.showing(d.shown, d.total))}` : ""}</div>`;
    const rows = d.rows.map((r) => {
      const [time, day, lane, model, , agent] = r;
      return `<tr><td class="ex-t1"><span class="ex-tfull">${esc(fmtDay(day))}</span><span class="ex-tshort">${esc(K.fmtDayShort(day))}</span> ${esc(time.slice(11))}</td>`
        + `<td>${esc(modelLabel(model))}</td><td>${esc(laneName(lane))}${flat.has(lane) ? ` <span class="ex-nb">${X.notBilled}</span>` : ""}</td>`
        + `<td class="us-hide-s ex-ag">${esc(agent)}</td><td class="r us-num">${usdR(r[7])}</td></tr>`;
    }).join("");
    body = head + (d.rows.length ? `<div class="us-tw"><table class="us-t ex-rt"><thead><tr><th>${X.rep.time}</th><th>${X.rep.model}</th><th>${X.rep.lane}</th><th class="us-hide-s">${X.rep.agent}</th><th class="r">${X.rep.cost}</th></tr></thead><tbody>${rows}</tbody></table></div>`
      : `<p class="ex-rmsg">${X.noReplies}</p>`);
  }
  box.innerHTML = `<div class="ex-rh"><span class="us-lbl">${X.replies} · ${esc(TXT(ex.by).toUpperCase())}: <b>${esc(nameOf(ex.by, ex.pick))}</b></span>`
    + `<div class="us-seg ex-wrap" role="group" aria-label="Replies of">${sideBtn("a")}${sideBtn("b")}</div></div>${body}`;
}

/* ---------- the whole view ---------- */
function renderNotes(d) {
  const p = d.prices || {};
  const un = (d.unpriced || []).length ? `<p>${d.unpriced.reduce((s, x) => s + x.replies, 0).toLocaleString("en-US")} replies on a model with no list price are counted as $0: ${esc(d.unpriced.map((x) => x.model).join(", "))}.</p>` : "";
  $x("#ex-notes").innerHTML = `<p>${esc(X.howTo)}</p><p>${esc(W.machines)}</p><p>${esc(W.prices)}${p.asOf ? ` As of ${esc(p.asOf)}.` : ""}</p>${un}`;
}
function showAge() {
  const f = $x("#ex-upd"), d = firstData();
  if (f) f.textContent = d && d.generated ? "counted " + K.agoText(serverNow(d) - d.generated) : "";
}
function render() {
  if (!ex.active) return;
  const note = $x("#ex-note"), d = firstData();
  const msg = ex.error || (d && d.error) || (ex.pending && !d ? W.pending : ex.noCount && !d ? W.noCount : "");
  note.textContent = msg;
  note.classList.toggle("error", !!(ex.error || (d && d.error)));
  if (d) defaults();
  renderControls(d);
  const body = $x("#ex-body");
  body.hidden = !d;
  if (d) {
    const rs = scope(ex.cmp), rsA = sideRows(rs, ex.a), rsB = sideRows(rs, ex.b);
    renderSides(rsA, rsB);
    renderTable(rsA, rsB);
    renderReplies();
    renderNotes(d);
    showAge();
  }
  if (ex.focus) { const n = $x(`[data-fid="${ex.focus}"]`); if (n) n.focus({ preventScroll: true }); ex.focus = ""; }
}

/* ---------- reading ---------- */
async function load({ fresh = false } = {}) {
  const seq = ++ex.seq;
  clearTimeout(ex.timer);
  const weeks = needWeeks();
  try {
    const got = await Promise.all(weeks.map(async (w, i) => {
      const r = await apiFetch(`api/usage?week=${w}${fresh && i === 0 ? "&fresh=1" : ""}`, { cache: "no-store" }, { tries: 2 });
      if (!r.ok) throw new Error("the server answered " + r.status);
      return [w, await r.json()];
    }));
    if (seq !== ex.seq) return;
    ex.error = "";
    ex.pending = got.some(([, d]) => d.pending);
    ex.noCount = got.some(([, d]) => d.noCount);
    if (fresh) ex.data = {};   // a new count: the weeks cached from the old one are asked for again when they are needed
    for (const [w, d] of got) if (!d.pending && Array.isArray(d.weeks) && d.weeks.length) { ex.data[w] = d; ex.ago = performance.now(); }
    rebuildRows();
    if (got.some(([, d]) => d.pending || d.refreshing)) {   // a count is running: ask again in a moment (a bounded number of times)
      if (ex.tries++ < POLL_MAX && ex.active) ex.timer = setTimeout(() => load(), POLL_MS);
    } else ex.tries = 0;
  } catch (e) {
    if (seq !== ex.seq) return;
    ex.error = "Could not read the usage: " + (e && e.message ? e.message : e);   // the last figures stay on screen
  }
  render();
}
const ensureLoaded = () => { if (needWeeks().some((w) => !ex.data[w])) { ex.tries = 0; load(); } };

/* ---------- what the controls do ---------- */
function resetPick() { ex.pick = null; ex.rep.seq++; clearTimeout(ex.rep.timer); ex.rep.status = ""; ex.rep.data = null; }
function onClick(e) {
  const b = e.target.closest("button, tr[data-k]");
  if (!b || !b.closest("#us-v-explorer")) return;
  if (b.dataset.fid) ex.focus = b.dataset.fid;
  let again = false;   // the replies on show are read again
  if (b.dataset.c !== undefined) {
    if (b.dataset.c === ex.cmp) return;
    ex.cmp = b.dataset.c; ex.a = ex.b = undefined; delete ex.f[ex.cmp];   // another dimension to compare: A and B start again, and its own filter goes
    if (ex.cmp !== "week" && ex.f.week === undefined) ex.f.week = "0";
    resetPick();
    defaults();
    ensureLoaded();
  } else if (b.dataset.b !== undefined) { ex.by = b.dataset.b; resetPick(); }
  else if (b.dataset.clear) { ex.f = { week: ex.f.week }; resetPick(); }
  else if (b.dataset.sort !== undefined) {
    const s = b.dataset.sort;
    if (ex.sort === s) ex.dir *= -1; else { ex.sort = s; ex.dir = s === "k" ? 1 : -1; }
  } else if (b.dataset.rside !== undefined) { ex.side = b.dataset.rside; again = true; }
  else if (b.dataset.k !== undefined) {
    if (ex.pick === b.dataset.k) resetPick(); else { ex.pick = b.dataset.k; again = true; }
  } else return;
  if (again) { ex.rep.data = null; ex.rep.tries = 0; }
  render();
  if (again) {
    loadReplies();
    const bx = $x("#ex-replies");
    if (b.dataset.k !== undefined && bx && bx.scrollIntoView) bx.scrollIntoView({ block: "nearest" });
  }
}
function onChange(e) {
  const s = e.target.closest("select");
  if (!s || !s.closest("#us-v-explorer")) return;
  ex.focus = s.dataset.fid || "";
  if (s.dataset.s) ex[s.dataset.s] = s.value;
  else if (s.dataset.f) { if (s.value === "") delete ex.f[s.dataset.f]; else ex.f[s.dataset.f] = s.value; }
  ensureLoaded();
  render();
  if (ex.pick !== null) { ex.rep.data = null; ex.rep.tries = 0; loadReplies(); }
}
function onKey(e) {
  const tr = e.target.closest && e.target.closest("tr[data-k]");
  if (tr && (e.key === "Enter" || e.key === " ") && tr.closest("#us-v-explorer")) { e.preventDefault(); tr.click(); }
}
function bind() {
  if (ex.bound || !$x("#ex-ctl")) return;
  ex.bound = true;
  const root = document.querySelector("#us-v-explorer");
  root.addEventListener("click", onClick);
  root.addEventListener("change", onChange);
  root.addEventListener("keydown", onKey);
  document.getElementById("us-reload").addEventListener("click", () => {   // the tab's Reload: a fresh count, for whichever view is on screen
    if (!ex.active) return;
    ex.error = ""; ex.tries = 0; load({ fresh: true }).then(() => { if (ex.pick !== null) { ex.rep.data = null; loadReplies(); } });
  });
}
/* the view is on screen: show what was counted last time at once and ask for the current count */
function show() {
  if (ex.active) return;
  bind();
  ex.active = true;
  ex.tries = 0;
  render();
  load().then(() => { if (ex.pick !== null) loadReplies(); });
  clearInterval(ex.ageTimer);
  ex.ageTimer = setInterval(() => { showAge(); }, 30000);
}
function hide() {
  if (!ex.active) return;
  ex.active = false;
  clearTimeout(ex.timer);
  clearTimeout(ex.rep.timer);
  clearInterval(ex.ageTimer);
}
usage.registerView("explorer", { show, hide });
return { show, hide };
})();
