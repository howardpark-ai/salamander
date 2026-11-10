"use strict";
/* The Overview's Machines tab (#machines): the machines with the versions each runs and how it stays current, as api/machines reports
   them (machines.py). It shows stackshot's LAST reading: nothing here asks GitHub or a machine, and the footer says how old the reading
   is ("updated 4 min ago"). The tab reads when it opens (app.js calls machines.start()) and when Reload is pressed, never by itself;
   the one timer only re-words the footer's age (no request). When the source is missing the tab says "No reading yet".
   `el` and `apiFetch` come from app.js (used at call time). Everything else stays in this closure. */
const machines = (() => {
const mc = { data: null, error: null, active: false, seq: 0, readAt: 0, timer: 0 };
const $in = (sel) => document.querySelector("#ov-machines " + sel);

/* how long ago, for the footer: at least 1 min, then hours, then days */
function agoText(s) {
  const m = Math.max(1, Math.floor(s / 60));
  return m < 60 ? tl("time.min", { n: m }) : m < 48 * 60 ? tl("mc.ago.hour", { n: Math.floor(m / 60) }) : tl("mc.ago.day", { n: Math.floor(m / 1440) });
}

/* ---------- the machine cards ---------- */
function versionRow(r) {
  return el("div", { class: "mc-vr" },
    el("span", { class: "mc-pk", text: r.package }),
    el("span", { class: "mc-vv", text: r.version }),
    el("span", { class: "mc-vs mc-vs-" + r.state, text: r.text }));
}
function failLine(a) {
  return el("div", { class: "mc-fail", title: a.tip || null },
    el("span", { class: "mc-failw", text: tl("mc.failed", { kind: a.kind }) }), " ", el("span", { text: a.detail }));
}
function machineCard(c) {
  const card = el("div", { class: "mc-card" + (c.alert ? " mc-bad" : ""), "data-machine": c.name },
    el("b", { class: "mc-name", text: c.name }),
    ...c.rows.map(versionRow),
    ...c.alerts.map(failLine),
    el("div", { class: "mc-fl", title: c.follow.tip || null, text: c.follow.text }));
  return card;
}

/* the error is kept as what failed, not as text, so it is worded again when the language changes: `status` is an HTTP status the page
   words itself, `detail` a text from the server or the browser, shown as it is */
const errText = (er) => (er ? tl("mc.err.read", { error: er.status ? tl("common.serverAnswered", { status: er.status }) : er.detail }) : "");

/* ---------- the footer ---------- */
function showAge() {
  const d = mc.data, f = $in("#mc-upd");
  if (!f) return;
  if (!d || d.updated == null) { f.textContent = ""; return; }
  const now = d.generated + (performance.now() - mc.readAt) / 1000;   // the server's clock moved on by the time since the answer: this page's own clock is not trusted
  f.textContent = tl("age.updated", { when: agoText(now - d.updated) });
}

function render() {
  const grid = $in("#mc-grid");
  if (!grid) return;
  const note = $in("#mc-note");
  note.textContent = errText(mc.error);
  note.classList.toggle("error", !!mc.error);
  const d = mc.data;
  if (!d) {
    grid.replaceChildren();
    $in("#mc-none").hidden = true;
    $in("#mc-upd").textContent = "";
    return;
  }
  const m = d.machines;
  document.getElementById("ov-n-machines").textContent = m.ok ? String(m.cards.length) : "";   // the tab's count
  const none = $in("#mc-none");
  none.hidden = m.ok;
  none.textContent = m.ok ? "" : tl("mc.noReading", { reason: m.reason });
  grid.replaceChildren(...(m.ok ? m.cards.map(machineCard) : []));
  showAge();
}

async function load() {
  const seq = ++mc.seq;
  try {
    const r = await apiFetch("api/machines", { cache: "no-store" }, { tries: 2 });
    if (!r.ok) throw Object.assign(new Error("the server answered " + r.status), { status: r.status });
    const d = await r.json();
    if (seq !== mc.seq) return;
    mc.data = d; mc.error = null; mc.readAt = performance.now();
  } catch (e) {
    if (seq !== mc.seq) return;
    mc.error = { status: e && e.status, detail: e && e.message ? e.message : String(e) };   // the last answer stays on screen
  }
  if (mc.active) render();
}
let bound = false;
function bind() {
  if (bound || !$in("#mc-grid")) return;
  bound = true;
  document.getElementById("mc-reload").addEventListener("click", () => { mc.error = null; load(); });
}
/* the tab opened: read once (no timer for the reading; Reload reads again), and re-word the footer's age twice a minute */
function start() {
  bind();
  mc.active = true;
  render();
  load();
  clearInterval(mc.timer);
  mc.timer = setInterval(showAge, 30000);
}
/* the language changed: the cards and the footer are worded again from the reading this page holds (no request) */
SalaI18n.onChange(() => { if (bound) render(); });
function stop() {
  mc.active = false;
  clearInterval(mc.timer);
  mc.timer = 0;
}
return { start, stop, agoText };
})();
