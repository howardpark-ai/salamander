"use strict";
/* The Overview's Usage analysis tab (#usage): what the Claude Code replies on this machine cost, at list prices, as api/usage reports them (usage.py).
   One data layer, three views: Report (this file), Explorer (usage-explorer.js, which registers itself here) and Digest (usage-digest.js: the week in a few plain sentences).
   Report: a week picker (a week runs from one weekly reset of the subscription lane to the next), the total, one card per lane, a Group by control, the
   filter chips, a stacked chart by day and a sortable table with share bars. A tap on a lane card, a table row, a legend name or a day filters everything
   to it. The page shows DOLLARS only; the server keeps tokens on each row and this file never reads them.
   The tab asks api/usage when it opens, on a change of week and on Reload. A visit never starts a count: the server answers at once from its last saved
   count (made by the daily job, or by a Reload), "noCount" when none was made yet (the tab says so; Reload makes one), "pending" or "refreshing" while a
   Reload's count runs (about a minute on a machine with a long history); the tab asks again a few seconds later in those two cases.
   `el` and `apiFetch` come from app.js and `modelLabel` from shared.js (used at call time). Everything else stays in this closure. */
const usage = (() => {
/* ---------- the words on the page, in one place ---------- */
const WORDS = {
  weeks: ["This week", "Previous week", "2 weeks ago"],
  views: [["report", "Report"], ["explorer", "Explorer"], ["digest", "Digest"]],
  group: "GROUP BY",
  dims: [["day", "Day"], ["lane", "Lane"], ["model", "Model"], ["project", "Project"], ["agent", "Agent"], ["folder", "Folder"]],
  total: (billed, n) => `at list prices · about ${usd(billed)} billed · ${n.toLocaleString("en-US")} replies`,
  flatLane: (pct) => "flat plan, not billed · at list prices" + (pct == null ? "" : ` · ${pct}% of weekly limit used`),
  billedLane: "billed per use (estimate)",
  machines: "Other machines are not counted: only this machine's sessions.",
  prices: "Prices are list prices per million tokens, copied from sala's price table.",
  howTo: "How to read this: every figure is what the replies would cost at list prices. Tap a lane card, a day, a name in the key or a table row to filter everything to it; tap again to clear. Group by changes the stack and the table.",
  resets: "resets in", closed: "closed", unknownReset: "the weekly reset time is not known: the last seven days",
  pending: "Counting the replies on this machine… the first count can take a minute.",
  noCount: "No count yet. The replies are counted once a day; Reload counts them now.",
  tapDay: "Tap a day to filter everything below to it.", clearDay: "Tap the bar again to clear.",
  nothing: "Nothing in this selection.", filtered: "filtered", allLanes: "all lanes",
  sameHours: "same hours of the previous week", weekBefore: "the week before",
  cols: { k: "", share: "Share", cost: "Cost", msgs: "Replies", per: "$ / reply" },
  costBy: "COST BY DAY", stackedBy: ", STACKED BY ", clearAll: "Clear all", other: "Other",
};
const F = { day: 0, lane: 1, model: 2, project: 3, agent: 4, folder: 5, usd: 6, replies: 7 };   // the row layout of api/usage (its "fields" says the same)
const MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"], WD = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const TOP = 6;          // the stack names this many groups and the rest is "Other"
const POLL_MS = 3000, POLL_MAX = 40;

const views = {};   // view id -> { show(), hide() }, registered by the file that builds that view
const uc = { data: {}, week: 0, group: "lane", f: {}, sort: "cost", dir: -1, view: "report", active: false, seq: 0, timer: 0, tries: 0, error: "", pending: false, noCount: false, ago: 0, resize: 0, bound: false };
const $u = (sel) => document.querySelector("#ov-usage " + sel);

/* ---------- formatting ---------- */
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const ord = (n) => n + (n % 100 >= 11 && n % 100 <= 13 ? "th" : ["th", "st", "nd", "rd"][n % 10] || "th");
function dparts(d) { const x = new Date(d + "T00:00:00Z"); return { wd: WD[x.getUTCDay()], mon: MON[x.getUTCMonth()], d: x.getUTCDate() }; }
const fmtDay = (d) => { const p = dparts(d); return `${p.wd} ${p.mon} ${ord(p.d)}`; };
const fmtDayShort = (d) => { const p = dparts(d); return `${p.wd} ${p.d}`; };
const usd = (v) => v >= 100 ? "$" + Math.round(v).toLocaleString("en-US") : "$" + v.toFixed(2);
const usdK = (v) => v >= 10000 ? "$" + (v / 1000).toFixed(0) + "k" : v >= 1000 ? "$" + (v / 1000).toFixed(1) + "k" : "$" + Math.round(v);
const pct = (v) => (v >= 10 ? v.toFixed(0) : v.toFixed(1)) + "%";
function untilText(sec) {
  const m = Math.max(0, Math.floor(sec / 60)), d = Math.floor(m / 1440), h = Math.floor((m % 1440) / 60);
  return d ? `${d}d ${h}h` : h ? `${h}h ${m % 60}m` : `${m}m`;
}
function agoText(s) {
  const m = Math.max(1, Math.floor(s / 60));
  return m < 60 ? m + " min ago" : m < 48 * 60 ? Math.floor(m / 60) + " h ago" : Math.floor(m / 1440) + " d ago";
}
const serverNow = (d) => (d.now || Date.now() / 1000) + (performance.now() - uc.ago) / 1000;   // the server's clock moved on by the time since the answer: this page's own clock is not trusted
const kstDay = (epoch) => new Date((epoch + 9 * 3600) * 1000).toISOString().slice(0, 10);   // the server's days are KST, a fixed +9 h

/* ---------- the data of the week on screen ---------- */
const D = () => uc.data[uc.week] || null;
const laneInfo = (code) => ((D() || {}).lanes || []).find((l) => l.code === code) || null;
const laneName = (code) => { const l = laneInfo(code); return l && l.label ? l.label : code; };
const flatLanes = () => new Set(((D() || {}).lanes || []).filter((l) => l.flat).map((l) => l.code));
function laneColor(code) { return code === "api" ? "var(--call)" : `var(--lane-${code}, var(--accent))`; }
const getters = {
  day: (r) => r[F.day], lane: (r) => r[F.lane], model: (r) => r[F.model], project: (r) => r[F.project], agent: (r) => r[F.agent], folder: (r) => r[F.folder],
};
function nameOf(dim, k) {
  return dim === "lane" ? laneName(k) : dim === "model" ? modelLabel(k) : dim === "day" ? fmtDay(k) : k;
}
function colorOf(dim, k, i) {
  if (k === WORDS.other) return "var(--us-sx)";
  if (dim === "lane") return laneColor(k);
  if (dim === "model") {
    const fam = /fable/.test(k) ? "fable" : /opus/.test(k) ? "opus" : /sonnet/.test(k) ? "sonnet" : /haiku/.test(k) ? "haiku" : null;
    if (fam) return `var(--us-fam-${fam})`;
  }
  if (dim === "day") return "var(--accent)";
  return `var(--us-s${i % 8})`;
}
function rowsFor(skipDim) {
  const d = D();
  if (!d) return [];
  return d.rows.filter((r) => WORDS.dims.every(([id]) => id === skipDim || !uc.f[id] || !uc.f[id].size || uc.f[id].has(getters[id](r))));
}
function agg(rs, dim) {
  const m = new Map(), g = getters[dim];
  for (const r of rs) {
    const k = g(r);
    let a = m.get(k);
    if (!a) m.set(k, a = { k, cost: 0, msgs: 0 });
    a.cost += r[F.usd]; a.msgs += r[F.replies];
  }
  return [...m.values()].sort((a, b) => b.cost - a.cost);
}
const total = (rs) => rs.reduce((s, r) => s + r[F.usd], 0);
const count = (rs) => rs.reduce((s, r) => s + r[F.replies], 0);
function toggleFilter(dim, k) {
  const s = uc.f[dim] || (uc.f[dim] = new Set());
  if (s.has(k)) s.delete(k); else s.add(k);
}
const activeFilters = () => WORDS.dims.flatMap(([id]) => [...(uc.f[id] || [])].map((k) => [id, k]));

/* the stack of the chart: the top groups and Other, per day */
function trend(rs, dim, n) {
  const days = D().weeks[uc.week].days;
  if (dim === "day") {
    const by = {};
    for (const r of rs) by[r[F.day]] = (by[r[F.day]] || 0) + r[F.usd];
    return { days, keys: ["Total"], val: (d) => ({ Total: by[d] || 0 }), cols: { Total: "var(--accent)" }, label: { Total: "Total" } };
  }
  const top = agg(rs, dim).map((a) => a.k), keys = top.slice(0, n), other = top.length > n, by = {};
  for (const r of rs) {
    const k = getters[dim](r), kk = keys.includes(k) ? k : WORDS.other;
    (by[r[F.day]] || (by[r[F.day]] = {}))[kk] = ((by[r[F.day]] || {})[kk] || 0) + r[F.usd];
  }
  const ks = other ? [...keys, WORDS.other] : keys, cols = {}, label = {};
  ks.forEach((k, i) => { cols[k] = colorOf(dim, k, i); label[k] = k === WORDS.other ? WORDS.other : nameOf(dim, k); });
  return { days, keys: ks, val: (d) => by[d] || {}, cols, label };
}
const niceMax = (v) => {
  if (v <= 0) return 1;
  const p = Math.pow(10, Math.floor(Math.log10(v))), f = v / p;
  return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 2.5 ? 2.5 : f <= 5 ? 5 : 10) * p;
};

/* ---------- the chart ---------- */
function tip(html, x, y) {
  const t = $u("#us-tip");
  if (!t) return;
  if (!html) { t.style.display = "none"; return; }
  t.innerHTML = html;
  t.style.display = "block";
  const w = t.offsetWidth;
  t.style.left = Math.max(6, Math.min(innerWidth - w - 6, x + 12)) + "px";
  t.style.top = Math.max(6, y - 12 - t.offsetHeight) + "px";
}
function dayTip(T, d) {
  const v = T.val(d), t = T.keys.reduce((s, k) => s + (v[k] || 0), 0);
  return `<b>${esc(fmtDay(d))}</b> · ${usd(t)}` + T.keys.filter((k) => v[k] > 0).sort((a, b) => v[b] - v[a]).slice(0, 8)
    .map((k) => `<div><span class="us-dot" style="background:${T.cols[k]}"></span> ${esc(T.label[k])} <span style="float:right;margin-left:12px">${usd(v[k])}</span></div>`).join("");
}
function drawTrend(host, T, opts) {
  const w = Math.max(260, host.clientWidth), h = w < 520 ? 180 : 232, L = 40, B = 24, Tp = 8, R = 8;
  const days = T.days, n = days.length;
  const series = days.map((d) => { const v = T.val(d), o = {}; for (const k of T.keys) o[k] = v[k] || 0; return o; });
  const tot = series.map((o) => T.keys.reduce((s, k) => s + o[k], 0));
  const mx = niceMax(Math.max(...tot, 0.01));
  const pw = w - L - R, ph = h - B - Tp, bw = pw / n, y = (v) => Tp + ph * (1 - v / mx);
  const today = kstDay(serverNow(D()));
  let s = `<svg viewBox="0 0 ${w} ${h}" width="${w}" height="${h}" role="img" aria-label="${esc(WORDS.costBy)}">`;
  for (let i = 0; i <= 4; i++) {
    const v = mx * i / 4, yy = y(v);
    s += `<line x1="${L}" x2="${w - R}" y1="${yy}" y2="${yy}" stroke="var(--border)" stroke-width="1"/><text x="${L - 6}" y="${yy + 4}" text-anchor="end" font-size="12" fill="var(--faint)">${usdK(v)}</text>`;
  }
  days.forEach((d, i) => {
    const x = L + i * bw, sel = opts.sel === d, fut = d > today, p = dparts(d);
    if (sel) s += `<rect x="${x}" y="${Tp}" width="${bw}" height="${ph}" fill="var(--text)" opacity=".07"/>`;
    s += `<text x="${x + bw / 2}" y="${h - 6}" text-anchor="middle" font-size="12" fill="${sel ? "var(--text)" : fut ? "var(--faint)" : "var(--muted)"}" opacity="${fut ? .6 : 1}">${bw < 46 ? p.wd.slice(0, 2) + " " + p.d : fmtDayShort(d)}</text>`;
    let acc = 0;
    const bx = x + bw * .16, bww = bw * .68;
    for (const k of T.keys) {
      const v = series[i][k];
      if (v <= 0) continue;
      const y1 = y(acc + v), hh = y(acc) - y1;
      s += `<rect x="${bx}" y="${y1}" width="${bww}" height="${Math.max(hh - .6, .5)}" rx="2" fill="${T.cols[k]}"/>`;
      acc += v;
    }
    s += `<rect data-d="${d}" x="${x}" y="${Tp}" width="${bw}" height="${ph + B}" fill="transparent"/>`;
  });
  host.innerHTML = s + "</svg>";
  for (const r of host.querySelectorAll("rect[data-d]")) {
    const d = r.dataset.d;
    r.addEventListener("pointermove", (e) => { if (e.pointerType === "mouse") tip(dayTip(T, d), e.clientX, e.clientY); });
    r.addEventListener("pointerleave", () => tip(null));
    r.addEventListener("click", () => { tip(null); opts.onPick(d === opts.sel ? null : d); });
  }
}
function drawLegend(host, T, onClick) {
  host.innerHTML = T.keys.map((k) => `<span data-k="${esc(k)}"><i class="us-dot" style="background:${T.cols[k]}"></i>${esc(T.label[k])}</span>`).join("");
  for (const sp of host.querySelectorAll("span")) sp.addEventListener("click", () => onClick(sp.dataset.k));
}

/* ---------- the pieces of the report ---------- */
function weekRange(w) {
  const f = (s) => `${fmtDay(s.slice(0, 10))} ${s.slice(11, 16)}`;
  return `${f(w.startKst)} – ${f(w.endKst)} ${D().tzLabel || "KST"}`;
}
function heroDelta(d, T0, filt) {
  if (filt) return "";
  const w = d.weeks[uc.week];
  let cmp = null;
  if (w.current) cmp = d.sameHours && d.sameHours.prevTotal ? [d.sameHours.prevTotal, WORDS.sameHours] : null;
  else if (uc.week === 1 && d.weeks[2]) cmp = [d.weeks[2].total, WORDS.weekBefore];
  if (!cmp || !cmp[0]) return "";
  const dl = (T0 / cmp[0] - 1) * 100;
  return `<span class="us-delta ${dl > 0 ? "up" : "down"}">${dl > 0 ? "+" : ""}${dl.toFixed(0)}%</span> <span class="us-faint" style="font-size:12px">vs ${esc(cmp[1])} (${usd(cmp[0])})</span>`;
}
function renderWeeks(d) {
  const box = $u("#us-weeks");
  box.innerHTML = WORDS.weeks.map((l, i) => `<button type="button" data-w="${i}" aria-pressed="${i === uc.week}">${esc(l)}</button>`).join("");
  const w = d && d.weeks[uc.week];
  let r = "";
  if (w) {
    r = weekRange(w);
    if (!d.resetKnown) r += ` · ${WORDS.unknownReset}`;
    else if (w.current) r += ` · ${WORDS.resets} ${untilText(w.end - serverNow(d))}`;
    else r += ` · ${WORDS.closed}`;
  }
  $u("#us-range").textContent = r;
}
function renderHero(d, rs) {
  const T0 = total(rs), filt = activeFilters().length > 0, flat = flatLanes();
  const billed = rs.reduce((s, r) => s + (flat.has(r[F.lane]) ? 0 : r[F.usd]), 0);
  $u("#us-hero").innerHTML = `<div><div class="us-big us-num">${usd(T0)}${filt ? `<span class="us-flt">${WORDS.filtered}</span>` : ""}</div>`
    + `<div class="us-sub">${esc(WORDS.total(billed, count(rs)))}</div></div><div>${heroDelta(d, T0, filt)}</div>`;
}
function renderLanes(d) {
  const lr = rowsFor("lane"), la = agg(lr, "lane"), lt = total(lr) || 1, cur = d.weeks[uc.week].current;
  $u("#us-lanes").innerHTML = la.map((a) => {
    const info = laneInfo(a.k) || {}, sel = !!(uc.f.lane && uc.f.lane.has(a.k)), q = cur && info.quota ? info.quota.percent : null;
    return `<button type="button" class="us-card us-lane" data-k="${esc(a.k)}" aria-pressed="${sel}" style="--lane:${laneColor(a.k)}">`
      + `<div class="us-top"><span class="us-pill">${esc(laneName(a.k))}</span><span class="us-pct">${pct(a.cost / lt * 100)}</span></div>`
      + `<div class="us-amt us-num">${usd(a.cost)}</div><div class="us-bar"><i style="width:${a.cost / lt * 100}%"></i></div>`
      + `<div class="us-sm">${info.flat ? esc(WORDS.flatLane(q)).replace(/(\d+)% of weekly/, "<b>$1%</b> of weekly") : esc(WORDS.billedLane)}</div></button>`;
  }).join("");
  for (const b of $u("#us-lanes").querySelectorAll(".us-lane")) b.addEventListener("click", () => { toggleFilter("lane", b.dataset.k); render(); });
}
function renderFilters() {
  const fl = activeFilters();
  $u("#us-filters").innerHTML = fl.map(([dm, k]) => `<button type="button" class="us-chip" data-d="${dm}" data-k="${esc(k)}"><span>${esc(WORDS.dims.find((x) => x[0] === dm)[1])}: <b>${esc(nameOf(dm, k))}</b></span><i aria-hidden="true">×</i></button>`).join("")
    + (fl.length > 1 ? `<button type="button" class="us-chip us-clear" data-all="1">${WORDS.clearAll}</button>` : "");
  for (const c of $u("#us-filters").querySelectorAll(".us-chip")) c.addEventListener("click", () => { if (c.dataset.all) uc.f = {}; else toggleFilter(c.dataset.d, c.dataset.k); render(); });
}
function renderChart(d) {
  const cr = rowsFor("day"), T = trend(cr, uc.group, TOP), selDay = uc.f.day && [...uc.f.day][0];
  const label = WORDS.dims.find((x) => x[0] === uc.group)[1];
  $u("#us-ctitle").textContent = WORDS.costBy + (uc.group === "day" ? "" : WORDS.stackedBy + label.toUpperCase());
  drawTrend($u("#us-plot"), T, { sel: selDay, onPick: (dy) => { uc.f.day = new Set(dy ? [dy] : []); render(); } });
  drawLegend($u("#us-legend"), T, (k) => { if (k !== WORDS.other && uc.group !== "day") { toggleFilter(uc.group, k); render(); } });
  const read = $u("#us-read");
  if (selDay) {
    const v = T.val(selDay), t = T.keys.reduce((s, k) => s + (v[k] || 0), 0);
    read.innerHTML = `<b>${esc(fmtDay(selDay))}</b>: ${usd(t)}. ${WORDS.clearDay}`;
  } else read.textContent = WORDS.tapDay;
}
function renderTable(rs) {
  const g = agg(rs, uc.group), T0 = total(rs);
  const cols = [["k", label(uc.group), ""], ["share", WORDS.cols.share, "us-hide-s"], ["cost", WORDS.cols.cost, "r"], ["msgs", WORDS.cols.msgs, "r us-hide-s"], ["per", WORDS.cols.per, "r us-hide-s"]];
  const val = { k: (a) => uc.group === "day" ? a.k : nameOf(uc.group, a.k).toLowerCase(), share: (a) => a.cost, cost: (a) => a.cost, msgs: (a) => a.msgs, per: (a) => a.cost / a.msgs };
  g.sort((a, b) => (val[uc.sort](a) > val[uc.sort](b) ? 1 : val[uc.sort](a) < val[uc.sort](b) ? -1 : 0) * uc.dir);
  $u("#us-thead").innerHTML = cols.map(([id, l, c]) => `<th class="${c}" aria-sort="${uc.sort === id ? (uc.dir < 0 ? "descending" : "ascending") : "none"}"><button type="button" data-s="${id}">${esc(l)}</button></th>`).join("");
  for (const b of $u("#us-thead").querySelectorAll("button")) {
    b.addEventListener("click", () => {
      const s = b.dataset.s;
      if (uc.sort === s) uc.dir *= -1; else { uc.sort = s; uc.dir = s === "k" ? 1 : -1; }
      render();
    });
  }
  const mx = Math.max(...g.map((a) => a.cost), 0.01);
  $u("#us-tbody").innerHTML = g.map((a, i) => {
    const on = !!(uc.f[uc.group] && uc.f[uc.group].has(a.k)), c = colorOf(uc.group, a.k, i);
    return `<tr class="us-pick${on ? " us-on" : ""}" data-k="${esc(a.k)}"><td class="us-nm"><span class="us-dot" style="background:${c}"></span>${esc(nameOf(uc.group, a.k))}</td>`
      + `<td class="us-hide-s"><div class="us-sharec"><div class="us-bar"><i style="width:${a.cost / mx * 100}%;--c:${c}"></i></div><span class="us-num">${pct(a.cost / (T0 || 1) * 100)}</span></div></td>`
      + `<td class="r us-num"><b>${usd(a.cost)}</b></td><td class="r us-num us-hide-s">${a.msgs.toLocaleString("en-US")}</td><td class="r us-num us-hide-s us-faint">${usd(a.msgs ? a.cost / a.msgs : 0)}</td></tr>`;
  }).join("") || `<tr><td colspan="5" class="us-empty">${WORDS.nothing}</td></tr>`;
  for (const tr of $u("#us-tbody").querySelectorAll("tr[data-k]")) tr.addEventListener("click", () => { toggleFilter(uc.group, tr.dataset.k); render(); });
}
const label = (dim) => WORDS.dims.find((x) => x[0] === dim)[1];
function renderNotes(d) {
  const p = d.prices || {}, models = Object.entries(p.models || {});
  const table = models.length
    ? `<details><summary>Price table</summary><div class="us-pw"><table class="us-prices"><thead><tr><th>Model</th><th>Input</th><th>Cache write 5m</th><th>Cache write 1h</th><th>Cache read</th><th>Output</th></tr></thead><tbody>`
      + models.map(([m, r]) => `<tr><td>${esc(modelLabel(m))}</td><td>${r.input}</td><td>${r.cacheWrite5m}</td><td>${r.cacheWrite1h}</td><td>${r.cacheRead}</td><td>${r.output}</td></tr>`).join("")
      + `</tbody></table></div></details>` : "";
  const un = (d.unpriced || []).length
    ? `<p>${d.unpriced.reduce((s, x) => s + x.replies, 0).toLocaleString("en-US")} replies on a model with no list price are counted as $0: ${esc(d.unpriced.map((x) => x.model).join(", "))}.</p>` : "";
  $u("#us-notes").innerHTML = `<p>${esc(WORDS.howTo)}</p><p>${esc(WORDS.machines)}</p>`
    + `<p>${esc(WORDS.prices)}${p.asOf ? ` As of ${esc(p.asOf)}.` : ""}</p>${un}${table}`;
}
function showAge() {
  const f = $u("#us-upd"), d = D();
  if (!f) return;
  f.textContent = d && d.generated ? "counted " + agoText(serverNow(d) - d.generated) : "";
}

/* what the Digest view (usage-digest.js) shares with the Report: the week, the words, the formatters and the note line */
function digestContext() {
  return {
    week: uc.week, words: WORDS, fmtDay, untilText, agoText,
    onWeek: (w) => { uc.week = w; uc.f = {}; uc.tries = 0; render(); load(); },   // one week for both views
    setNote: (text, isError) => { const n = $u("#us-note"); n.textContent = text; n.classList.toggle("error", !!isError); },
  };
}

/* ---------- the whole tab ---------- */
function renderViews() {
  const box = $u("#us-views");
  box.innerHTML = WORDS.views.map(([id, l]) => `<button type="button" role="tab" id="us-vt-${id}" data-v="${id}" aria-selected="${id === uc.view}" aria-controls="us-v-${id}"${id === uc.view ? "" : ' tabindex="-1"'}>${esc(l)}</button>`).join("");
  for (const [id] of WORDS.views) $u("#us-v-" + id).hidden = id !== uc.view;
}
function render() {
  const note = $u("#us-note");
  if (!note) return;
  const d = D();
  note.textContent = uc.error || (d && d.error) || (uc.pending && !d ? WORDS.pending : uc.noCount && !d ? WORDS.noCount : "");
  note.classList.toggle("error", !!(uc.error || (d && d.error)));
  renderViews();
  if (uc.view === "digest") usageDigest.show(digestContext()); else usageDigest.hide();   // usage-digest.js: the Digest view
  for (const [id, v] of Object.entries(views)) { if (id === uc.view) v.show(); else v.hide(); }   // a view built in its own file (usage-explorer.js): shown when it is the one on screen
  if (uc.view !== "report") return;
  renderWeeks(d);
  const body = $u("#us-body");
  body.hidden = !d;
  if (!d) return;
  const rs = rowsFor();
  renderHero(d, rs);
  renderLanes(d);
  renderFilters();
  for (const b of $u("#us-group").querySelectorAll("button")) b.setAttribute("aria-pressed", String(b.dataset.g === uc.group));
  renderChart(d);
  renderTable(rs);
  renderNotes(d);
  showAge();
}

/* ---------- reading ---------- */
async function load({ fresh = false } = {}) {
  const seq = ++uc.seq, week = uc.week;
  clearTimeout(uc.timer);
  try {
    const r = await apiFetch(`api/usage?week=${week}${fresh ? "&fresh=1" : ""}`, { cache: "no-store" }, { tries: 2 });
    if (!r.ok) throw new Error("the server answered " + r.status);
    const d = await r.json();
    if (seq !== uc.seq) return;
    uc.error = "";
    uc.pending = !!d.pending;
    uc.noCount = !!d.noCount;
    if (!d.pending && Array.isArray(d.weeks) && d.weeks.length) {
      if (fresh) uc.data = {};   // a new count: the other weeks cached from the old one are asked for again when they are opened
      uc.data[week] = d; uc.ago = performance.now();
    }
    if (d.pending || d.refreshing) {   // a count is running: ask again in a moment (a bounded number of times)
      if (uc.tries++ < POLL_MAX && uc.active) uc.timer = setTimeout(() => load(), POLL_MS);
    } else uc.tries = 0;
  } catch (e) {
    if (seq !== uc.seq) return;
    uc.error = "Could not read the usage: " + (e && e.message ? e.message : e);   // the last answer stays on screen
  }
  if (uc.active) render();
}
function bind() {
  if (uc.bound || !$u("#us-views")) return;
  uc.bound = true;
  $u("#us-glbl").textContent = WORDS.group;
  $u("#us-group").innerHTML = WORDS.dims.map(([id, l]) => `<button type="button" data-g="${id}" aria-pressed="${id === uc.group}">${esc(l)}</button>`).join("");
  $u("#us-group").addEventListener("click", (e) => {
    const b = e.target.closest("button");
    if (b) { uc.group = b.dataset.g; render(); }
  });
  $u("#us-weeks").addEventListener("click", (e) => {
    const b = e.target.closest("button");
    if (!b || +b.dataset.w === uc.week) return;
    uc.week = +b.dataset.w; uc.f = {}; uc.tries = 0;
    render();
    load();
  });
  $u("#us-views").addEventListener("click", (e) => {
    const b = e.target.closest("button");
    if (b) { uc.view = b.dataset.v; render(); }
  });
  $u("#us-views").addEventListener("keydown", (e) => {   // arrow keys move between the views, as a tab list does
    if (e.key !== "ArrowLeft" && e.key !== "ArrowRight") return;
    e.preventDefault();
    const ids = WORDS.views.map((v) => v[0]);
    uc.view = ids[(ids.indexOf(uc.view) + (e.key === "ArrowRight" ? 1 : ids.length - 1)) % ids.length];
    render();
    $u("#us-vt-" + uc.view).focus();
  });
  document.getElementById("us-reload").addEventListener("click", () => { uc.error = ""; uc.tries = 0; load({ fresh: true }); usageDigest.reload(); });
  window.addEventListener("resize", () => {
    if (!uc.active) return;
    clearTimeout(uc.resize);
    uc.resize = setTimeout(() => { if (uc.active && D()) render(); }, 150);
  });
}
/* the tab opened: show what was counted last time at once and ask for the current count (Reload asks for a fresh one) */
function start() {
  bind();
  uc.active = true;
  uc.tries = 0;
  render();
  load();
  clearInterval(uc.ageTimer);
  uc.ageTimer = setInterval(() => { showAge(); const d = D(); if (d && uc.view === "report") renderWeeks(d); }, 30000);
}
function stop() {
  uc.active = false;
  clearTimeout(uc.timer);
  clearInterval(uc.ageTimer);
  usageDigest.hide();
  tip(null);
  for (const v of Object.values(views)) v.hide();
}
/* what a view built in its own file shares with this one: the words (one place), the formatters and the lane colour */
const kit = { WORDS, MON, WD, esc, ord, fmtDay, fmtDayShort, usd, pct, agoText, untilText, laneColor };
return { start, stop, untilText, agoText, fmtDay, usd, kit, registerView: (id, v) => { views[id] = v; } };
})();
