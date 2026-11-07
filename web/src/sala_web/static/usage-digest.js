"use strict";
/* The Digest view of the Overview's Usage analysis tab (#us-v-digest): the week in a few plain sentences. The sentences are written by code on the server
   (usage_digest.py, GET api/usage/digest?week=<n>, from the same cached count as the Report: no model call, no second scan); this file only asks for them
   and shows them under the same week picker the Report has. It shows dollars as the server wrote them and never reads a token count.
   usage.js mounts it: it calls show(ctx) whenever the Digest view is the one on screen (every render, so it must be cheap and must only ask the server when
   the week changed or the view was just opened), hide() when another view or tab takes over, and reload() from the Reload button. `ctx` carries what
   the Report already has so the wording lives in one place: `week`, `onWeek(n)`, `setNote(text, isError)`, `words` (usage.js's WORDS: the week names, the
   machines note, the pending note, "resets in"), `fmtDay`, `untilText`, `agoText`. `el` and `apiFetch` come from app.js (used at call time). */
const usageDigest = (() => {
const POLL_MS = 3000, POLL_MAX = 40;
const WORDS = { title: "THE WEEK IN A FEW SENTENCES", none: "No digest could be written for this week yet.", counted: "counted" };
const ud = { week: 0, data: {}, seq: 0, timer: 0, tries: 0, error: "", pending: false, ago: 0, shown: false, bound: false, ctx: null, ageTimer: 0 };
const $d = (sel) => document.querySelector("#ov-usage #us-v-digest " + sel);
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const serverNow = (d) => (d.now || Date.now() / 1000) + (performance.now() - ud.ago) / 1000;   // the server's clock moved on by the time since the answer
const D = () => ud.data[ud.week] || null;

/* a sentence is text from the server: escaped first, then the dollar amounts in it are made bold */
const sentence = (s) => `<p>${esc(s).replace(/\$[\d,]+\.\d\d/g, "<b>$&</b>")}</p>`;

function rangeText(d) {
  const r = d.range, w = ud.ctx.words;
  if (!r) return "";
  const f = (s) => `${ud.ctx.fmtDay(s.slice(0, 10))} ${s.slice(11, 16)}`;
  let t = `${f(r.startKst)} – ${f(r.endKst)} ${d.tzLabel || "KST"}`;
  if (!d.resetKnown) t += ` · ${w.unknownReset}`;
  else if (r.current) t += ` · ${w.resets} ${ud.ctx.untilText(r.end - serverNow(d))}`;
  else t += ` · ${w.closed}`;
  return t;
}
function showAge() {
  const f = $d("#us-dg-upd"), d = D();
  if (f) f.textContent = d && d.generated ? `${WORDS.counted} ${ud.ctx.agoText(serverNow(d) - d.generated)}` : "";
}
function render() {
  if (!ud.ctx || !$d("#us-dg-weeks")) return;
  const d = D(), w = ud.ctx.words;
  $d("#us-dg-weeks").innerHTML = w.weeks.map((l, i) => `<button type="button" data-w="${i}" aria-pressed="${i === ud.week}">${esc(l)}</button>`).join("");
  $d("#us-dg-range").textContent = d ? rangeText(d) : "";
  const err = ud.error || (d && d.error) || "";
  ud.ctx.setNote(err || (ud.pending && !d ? w.pending : ""), !!err);
  const body = $d("#us-dg-body");
  body.hidden = !d;
  if (!d) return;
  $d("#us-dg-title").textContent = WORDS.title;
  $d("#us-dg-text").innerHTML = d.sentences && d.sentences.length ? d.sentences.map(sentence).join("") : `<p class="us-faint">${esc(WORDS.none)}</p>`;
  $d("#us-dg-scope").textContent = w.machines;
  showAge();
}

async function load({ fresh = false } = {}) {
  const seq = ++ud.seq, week = ud.week;
  clearTimeout(ud.timer);
  try {
    const r = await apiFetch(`api/usage/digest?week=${week}${fresh ? "&fresh=1" : ""}`, { cache: "no-store" }, { tries: 2 });
    if (!r.ok) throw new Error("the server answered " + r.status);
    const d = await r.json();
    if (seq !== ud.seq) return;
    ud.error = "";
    ud.pending = !!d.pending;
    if (!d.pending && Array.isArray(d.sentences)) { ud.data[week] = d; ud.ago = performance.now(); }
    if (d.pending || d.refreshing) {   // a count is running: ask again in a moment (a bounded number of times)
      if (ud.tries++ < POLL_MAX && ud.shown) ud.timer = setTimeout(() => load(), POLL_MS);
    } else ud.tries = 0;
  } catch (e) {
    if (seq !== ud.seq) return;
    ud.error = "Could not read the digest: " + (e && e.message ? e.message : e);   // the last sentences stay on screen
  }
  if (ud.shown) render();
}
function bind() {
  if (ud.bound || !$d("#us-dg-weeks")) return;
  ud.bound = true;
  $d("#us-dg-weeks").addEventListener("click", (e) => {
    const b = e.target.closest("button");
    if (b && +b.dataset.w !== ud.week) ud.ctx.onWeek(+b.dataset.w);   // usage.js sets the week for both views and renders: show() then asks for it
  });
}
/* the Digest view is on screen */
function show(ctx) {
  ud.ctx = ctx;
  bind();
  const first = !ud.shown || ctx.week !== ud.week;
  ud.week = ctx.week;
  if (!ud.shown) {
    ud.shown = true;
    clearInterval(ud.ageTimer);
    ud.ageTimer = setInterval(() => { if (ud.shown) { showAge(); const d = D(); if (d) $d("#us-dg-range").textContent = rangeText(d); } }, 30000);
  }
  if (first) { ud.tries = 0; ud.error = ""; }
  render();
  if (first) load();
}
function hide() {
  ud.shown = false;
  clearTimeout(ud.timer);
  clearInterval(ud.ageTimer);
  ud.seq++;   // an answer on its way is not wanted any more
}
function reload() {
  if (!ud.shown) return;
  ud.error = ""; ud.tries = 0;
  load({ fresh: true });
}
return { show, hide, reload };
})();
