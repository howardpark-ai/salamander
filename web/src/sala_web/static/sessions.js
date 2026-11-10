"use strict";
/* The sessions overview, a view of index.html's main area (#sessions): every live session's project, role, status,
   model and lane, from api/overview every 10 s; above it, each account lane's usage limits from api/quota every 60 s,
   and the API key's spend (metered and sdk lanes) from api/credit every 15 minutes, the server's cache age, and the
   AWS lanes' month-to-date spend (an estimate at list prices) from api/spend every 60 s. It polls
   only while shown: app.js calls overview.start() when the view opens and overview.stop() when it leaves. laneLabel
   and modelLabel come from shared.js. Everything else stays inside this closure, so nothing clashes with app.js's names. */
const overview = (() => {
const REFRESH_MS = 10000;
const QUOTA_MS = 60000;
const CREDIT_MS = 900000;  // the server asks the Admin API at most this often, so polling faster gains nothing
const QUOTA_STALE_MS = 600000;    // an answer older than this shows "as of": its refreshes have been failing
const CREDIT_STALE_MS = 1200000;
const FOLLOW_MS = 1500;           // while the server refreshes in the background, ask again this soon,
const FOLLOW_MAX = 40;            // for about a minute at most
const PLACEHOLDER_LANES = ["subscription-1", "subscription-2"];  // the lanes with a quota (app.py), drawn before the first answer
const SPEND_LANES = ["aws-platform", "bedrock"];  // the lanes whose month-to-date spend api/spend counts (spend.py), in their cards' order
const SPEND_TOP = 5;                             // sessions listed on an Overview card; the lane's details page lists all
const SPEND_BRIEF_LANES = ["aws-platform", "bedrock"];       // lanes whose Overview card leaves out By model, Sessions and the "no sessions" line; the details page keeps both
const CARD_RANK = { active: 0, pending: 0, dormant: 1, unconfigured: 2 };  // the Overview's card order by the chip's state
const SPEND_STALE_MS = 900000;                   // an answer older than this shows "as of": the server counts every 5 minutes
const PLACEHOLDER_ROWS = 3;                 // a lane's usual limits: session, week, one model's week
const ROLE_RANK = { front: 1, back: 2 };  // any other role (an old registry row) ranks after back
const STATUS_DOT = { working: "busy", idle: "idle", shell: "shell", "needs input": "waiting" };
const STATUS_KEY = { working: "ov.status.working", idle: "ov.status.idle", shell: "ov.status.shell", "needs input": "ov.status.needsInput" };
const statusText = (s) => (s && Object.hasOwn(STATUS_KEY, s) ? tl(STATUS_KEY[s]) : s || "");   // a status this page does not know shows as the server sent it

const sp = { laneDrag: false, laneRedraw: false, rows: [], key: null, dir: 1, timer: null, qtimer: null, ctimer: null, follow: null, tries: 0,
  qcards: [], ccard: null, scards: [], active: false,  // key null: the server's order (the sidebar's)
  loaded: false, note: null, qerr: null,    // loaded: sp.rows is an answer; note: the sessions line's key and vars; qerr: the cards' load error, so a language change draws them again
  quota: null, credit: null, spend: null,  // the last answers of api/quota (its lanes), api/credit and api/spend, the details page draws its card from them
  lane: null };                            // the lane whose details page is open: {id, record, state, error, loaded}
// the project with its scope, as the sidebar groups them: "example/wiki"
const projectLabel = (r) => (r.projectTitle ? r.scope + "/" + r.projectTitle : "");

const cellText = {
  name: (r) => r.name,
  project: (r) => projectLabel(r),
  role: (r) => r.role || "",
  status: (r) => r.status || "",
  model: (r) => (r.model ? modelLabel(r.model) : ""),
  effort: (r) => r.effort || "",
  lane: (r) => (r.lane ? laneLabel(r.lane) : ""),
};

// the model cell's tooltip: the exact id, and for a --model alias where its version came from
const ALIAS_FROM = { launch: "ov.model.from.launch", record: "ov.model.from.record", default: "ov.model.from.default" };
// a model nothing on the pane names (no launch flag, no record, no reply: a session sala's idle wrap-up cleared) is the CLI's
// default, read from the default lane's settings.json; the effort is that file's too, shown only for the default
// model's family. A pane with its own settings file gets neither.
function modelTitle(r) {
  const a = r.modelAlias;
  if (!a) return r.modelSource === "default" ? r.model + "\n" + tl("ov.model.defaultNote") : r.model;
  const via = {
    reply: tl("ov.model.via.reply"),
    env: tl("ov.model.via.env", { env: "ANTHROPIC_DEFAULT_" + a.name.replace(/\[1m\]$/i, "").toUpperCase() + "_MODEL" }),
    catalog: tl("ov.model.via.catalog", { binary: a.binary || tl("ov.model.itsBinary") }),
  }[a.via] || tl("ov.model.via.unknown");
  const from = Object.hasOwn(ALIAS_FROM, a.from) ? tl(ALIAS_FROM[a.from]) : a.from;
  return r.model + "\n" + tl("ov.model.aliasLine", { alias: a.name, from, via })
    + (r.modelSource === "default" ? "\n" + tl("ov.model.defaultNote") : "");
}

function td(...kids) {
  const n = document.createElement("td");
  n.append(...kids);
  return n;
}
function span(cls, text, title) {
  const n = document.createElement("span");
  n.className = cls;
  n.textContent = text;
  if (title) n.title = title;
  return n;
}

// The model as a family label and a version: one colour per family, the same across its versions; any
// family other than these four is plain grey. The family's rank is the sort order (then the version).
const FAMILIES = ["fable", "opus", "sonnet", "haiku"];
function modelParts(id) {
  const label = modelLabel(id);
  const unknown = / \(version unknown\)$/.test(label);
  const fam = (/^claude-([a-z]+)-\d/.exec(id || "") || /^([a-z]+)(?:\[1m\])?$/i.exec(id || "") || [])[1];
  const family = fam && FAMILIES.includes(fam.toLowerCase()) ? fam.toLowerCase() : "other";
  const v = /^claude-[a-z]+-(\d+)(?:-(\d{1,2}))?(?!\d)/.exec(id || "");
  return { label: unknown ? label.replace(/ \(version unknown\)$/, "") : label, unknown, family,
           version: v ? [+v[1], v[2] ? +v[2] : 0] : null, wide: /\[1m\]/i.test(id || "") };
}
// effort levels from lightest to strongest; a level not in this list is shown neutral and sorts after max
const EFFORTS = ["low", "medium", "high", "xhigh", "max"];

// a column's sort value: a string, a number, or an array compared element by element; "" is a blank, last either way
const sortVal = {
  role: (r) => (r.role in ROLE_RANK ? ROLE_RANK[r.role] : 9),
  // the family (in FAMILIES' order, others after), then the version; a version unknown after the known ones
  model: (r) => {
    if (!r.model) return "";
    const m = modelParts(r.model), f = FAMILIES.indexOf(m.family);
    return [f < 0 ? FAMILIES.length : f, m.family === "other" ? m.label.toLowerCase() : "",
            m.version ? 0 : 1, ...(m.version || [0, 0]), m.wide ? 1 : 0];
  },
  // by level, never alphabetically: low < medium < high < xhigh < max < an unknown level; none set: blank
  effort: (r) => {
    if (!r.effort) return "";
    const i = EFFORTS.indexOf(r.effort.toLowerCase());
    return [i < 0 ? EFFORTS.length : i, i < 0 ? r.effort.toLowerCase() : ""];
  },
};
function compare(va, vb) {
  if (Array.isArray(va)) {
    for (let k = 0; k < va.length; k++) {
      const c = compare(va[k], vb[k]);
      if (c) return c;
    }
    return 0;
  }
  return typeof va === "number" ? va - vb : va.localeCompare(vb, undefined, { numeric: true, sensitivity: "base" });
}

function sorted() {
  const rows = sp.rows.map((r, i) => ({ r, i }));  // i: the server's order, the tie-break for every column
  if (!sp.key) return rows.map((x) => x.r);
  const val = sortVal[sp.key] || cellText[sp.key];
  rows.sort((a, b) => {
    const va = val(a.r), vb = val(b.r);
    // blanks last in either direction
    if ((va === "") !== (vb === "")) return va === "" ? 1 : -1;
    const c = va === "" ? 0 : compare(va, vb);
    return c ? c * sp.dir : a.i - b.i;
  });
  return rows.map((x) => x.r);
}

// the model cell: a tinted label in the family's colour, "version unknown" beside it when no version could be read
function modelCell(r) {
  if (!r.model) return span("sp-muted", tl("ov.row.noReply"));
  const m = modelParts(r.model);
  const n = span("sp-model", "", modelTitle(r));
  n.append(span("sp-tag fam-" + m.family, m.label));
  if (m.unknown) n.append(" ", span("sp-warn sp-vu", tl("ov.row.versionUnknown")));  // the space: for a screen reader
  if (r.modelSource === "default") n.append(" ", span("sp-muted sp-def", tl("ov.row.default")));
  return n;
}
// the effort cell: the level in a shade of one colour, lightest for low, strongest for max, "(default)" beside it when it is
// the CLI's default; "not set" when none
function effortCell(r) {
  if (!r.effort) return span("sp-muted", tl("ov.row.notSet"));
  const lvl = r.effort.toLowerCase();
  const tag = span("sp-tag sp-eff eff-" + (EFFORTS.includes(lvl) ? lvl : "other"), r.effort);
  if (r.effortSource !== "default") return tag;
  const n = span("", "", tl("ov.model.defaultEffortNote"));
  n.append(tag, " ", span("sp-muted sp-def", tl("ov.row.default")));
  return n;
}

// one session's row, the same in the overview's table and in a lane's details page
function sessionRow(r) {
  const tr = document.createElement("tr");
  const link = document.createElement("a");
  link.href = "#s=" + encodeURIComponent(r.name);  // opens it in this page: the hash change leaves the overview
  link.textContent = r.name;
  const st = span("sp-status " + ({ busy: "working", waiting: "waiting" }[STATUS_DOT[r.status]] || ""), "");
  st.append(span("dot " + (STATUS_DOT[r.status] || ""), ""), statusText(r.status));
  // a conversation moved into a background job: one row, the job's status above, and where it runs
  if (r.parkedJob) st.append(span("sp-muted", tl("ov.row.inJob", { job: r.parkedJob }), tl("ov.row.jobTitle")));
  tr.append(
    td(link),
    td(r.projectTitle ? span("", projectLabel(r), r.project) : span("sp-muted", tl("ov.row.unregistered"))),
    td(r.role ? r.role : span("sp-muted", tl("ov.common.none"))),
    td(st),
    td(modelCell(r)),
    td(effortCell(r)),
    td(r.lane ? span("sp-pill lane-" + laneNorm(r.lane), cellText.lane(r)) : span("sp-muted", tl("ov.common.unknown"))),
  );
  return tr;
}
function emptyRow(text) {
  const tr = document.createElement("tr");
  const c = td(text);
  c.colSpan = 7;
  c.className = "sp-empty";
  tr.append(c);
  return tr;
}

function render() {
  const body = document.querySelector("#sp-table tbody");
  const rows = sorted();
  body.replaceChildren(...rows.map(sessionRow));
  if (!rows.length) body.append(emptyRow(tl("ov.row.noSessions")));
  for (const th of document.querySelectorAll("#sp-table th")) {
    th.setAttribute("aria-sort", th.dataset.key === sp.key ? (sp.dir > 0 ? "ascending" : "descending") : "none");
  }
  const working = sp.rows.filter((r) => r.status === "working").length;
  document.getElementById("sp-count").textContent = tl("ov.row.count", { total: sp.rows.length, working });
  document.getElementById("ov-n-agents").textContent = String(sp.rows.length);   // the Agents tab's count
}

// the line above the table: what the last load said, kept as a key with its values so a language change words it again
function renderNote() {
  const note = document.getElementById("sp-note");
  note.className = "sp-note" + (sp.note && sp.note.bad ? " error" : "");
  note.textContent = sp.note ? tl(sp.note.key, sp.note.vars) : "";
}
async function load() {
  try {
    const r = await fetch("api/overview", { cache: "no-store" });
    if (!r.ok) throw new Error("HTTP " + r.status);
    const data = await r.json();
    sp.rows = data.sessions || [];
    sp.loaded = true;
    sp.note = data.rolesError ? { key: "ov.err.roles", vars: { error: data.rolesError } } : null;
    renderNote();
    render();
    laneRender();
  } catch (e) {
    sp.note = { key: "ov.err.sessions", vars: { msg: e.message }, bad: true };
    renderNote();
  }
}

// a header click sorts by that column, a second reverses it, a third goes back to the sidebar's order
for (const th of document.querySelectorAll("#sp-table th")) {
  th.querySelector("button").addEventListener("click", () => {
    const k = th.dataset.key;
    if (sp.key !== k) { sp.key = k; sp.dir = 1; }
    else if (sp.dir > 0) sp.dir = -1;
    else sp.key = null;
    render();
  });
}

// "Resets 7:10 PM" today, "Resets Wed 2:00 PM" within 7 days (a weekly limit), with the date further out; in the SALA_TZ zone (shared.js zoneFormat)
const zoneDay = zoneFormat("en-CA", { year: "numeric", month: "2-digit", day: "2-digit" });
const zoneTime = zoneFormat(SalaI18n.locale, { hour: "numeric", minute: "2-digit" });
const zoneWeekday = zoneFormat(SalaI18n.locale, { weekday: "short" });
const zoneDate = zoneFormat(SalaI18n.locale, { month: "short", day: "numeric" });
const zoneDayParts = zoneFormat(SalaI18n.locale, { weekday: "short", month: "short", day: "numeric" });
// the weekday with the date: "Wed Jan 14"; in Korean the formatter's own order (month, day, weekday)
const zoneWeekdayLong = zoneFormat(SalaI18n.locale, { weekday: "long" });
const weekdayOnly = (d) => (SalaI18n.lang === "ko" ? zoneWeekdayLong.format(d) : zoneWeekday.format(d));   // a bare "Mon" reads well in English; in Korean the short form is one syllable, the full name is clear
const weekdayDate = (d) => (SalaI18n.lang === "ko" ? zoneDayParts.format(d) : zoneWeekday.format(d) + " " + zoneDate.format(d));
function resetsText(iso) {
  // to the nearest minute: the endpoint gives 04:59:59.6 for a 05:00 reset, which would read "1:59 PM"
  const d = new Date(Math.round(Date.parse(iso) / 60000) * 60000);
  if (!iso || isNaN(d)) return "";
  const now = new Date();
  if (zoneDay.format(d) === zoneDay.format(now)) return tl("ov.resets", { when: zoneTime.format(d) });
  const lead = d - now < 7 * 86400000 ? weekdayOnly(d) : weekdayDate(d);
  return tl("ov.resets", { when: lead + " " + zoneTime.format(d) });
}

function div(cls, text) {
  const n = document.createElement("div");
  n.className = cls;
  if (text != null) n.textContent = text;
  return n;
}

// a check that failed, under the head. With a saved answer it is a quiet line in the muted colour: the
// numbers stay, so it says what happened in plain words, their time and the next try; red only when there is nothing
// to show. What happened comes from errorKind, never from the server's own words for a failed check (they name the
// endpoint and its status; those are the line's tooltip). A sign-in problem is already said in plain words, as is.
function quotaError(q) {
  const saved = !!q.fetchedAt;
  const kind = q.errorKind || "failed";
  const line = div("q-err" + (saved ? " q-soft" : ""));
  let text = kind === "rate_limited" ? tl("ov.q.limiting") : kind === "sign_in" ? q.error : kind === "refused" ? tl("ov.q.refused") : tl("ov.q.failed");
  if (saved) text = tl(kind === "sign_in" ? "ov.q.asOfDot" : "ov.q.asOfSemi", { text, when: whenText(new Date(q.fetchedAt).toISOString()) });
  if (kind !== "sign_in" && q.nextTry) text = tl("ov.q.nextTry", { text, when: whenText(new Date(q.nextTry).toISOString()) });
  line.textContent = text;
  if (kind === "failed") line.title = q.error;
  return line;
}

// A DORMANT LANE (sala's lane-state.tsv, read by the server): the card keeps the head an active card has (the
// lane's pill; its plan name is on the details page) with one muted line under it, "No seat since Mon Jan 5th" and a "dormant" chip in the head (laneChip); the server asks
// Anthropic nothing for it. The day is in the SALA_TZ zone, the way every date here is read. (A per-use lane, api or aws-platform or bedrock, is not this
// card: it keeps its spend figures and the same line, see dormantNote.)
function dayWords(iso) {  // "Mon Jan 5th"; in Korean the month, day and weekday
  const d = new Date(Date.parse(iso));
  if (!iso || isNaN(d)) return "";
  if (SalaI18n.lang === "ko") return zoneDayParts.format(d);
  const p = Object.fromEntries(zoneDayParts.formatToParts(d).map((x) => [x.type, x.value]));
  const n = Number(p.day), tens = n % 100;
  const suf = tens >= 11 && tens <= 13 ? "th" : { 1: "st", 2: "nd", 3: "rd" }[n % 10] || "th";
  return p.weekday + " " + p.month + " " + n + suf;
}
// "Details ›" at the right end of a card's head: the lane's details page, #lane=<id>; app.js follows it
function detailsLink(lane) {
  const a = document.createElement("a");
  a.className = "q-details";
  a.href = "#lane=" + encodeURIComponent(lane);
  a.textContent = tl("ov.details");
  a.setAttribute("aria-label", tl("ov.detailsOf", { lane: laneLabel(lane) }));
  return a;
}
// The lane's status chip, left of "Details ›" in a card's head: a pill in the same style as the lane's
// label (sp-pill), its words lower case like the labels: "active" (green), "dormant" (grey), "not configured" (grey outline). Derived from what the card already holds, no state of its own: dormant is sala's
// record (lane-state.tsv, the answer's `dormant`); not configured is a lane with no sign-in file (the usage answer) or no
// Admin API key (the spend answer); anything else that answers is active. NOT_CONFIGURED_WORDS are the server's own words
// for those two (quota.py NO_SIGN_IN, credit.py NO_KEY; a test holds them together). While the first answer is still on its
// way the chip is an invisible stand-in of the same size ("pending"), so a card never says active before it knows and the
// head does not change height when the answer lands.
const NOT_CONFIGURED_WORDS = ["no sign-in on this lane", "No Admin API key on this machine."];
const CHIP_WORDS = { active: "ov.chip.active", dormant: "ov.chip.dormant", unconfigured: "ov.chip.unconfigured", pending: "ov.chip.active" };
function laneChip(state) {
  if (!CHIP_WORDS[state]) return null;
  const chip = span("sp-pill lane-chip lane-chip-" + state, tl(CHIP_WORDS[state]));   // a pill in the lane label's own style
  if (state === "pending") chip.setAttribute("aria-hidden", "true");
  return chip;
}
// the chip and "Details ›" travel together at the head's right end: when a narrow card wraps its head, the pair wraps as one
// and keeps the right end, the link never left alone on a second row
// On the lane's details page (page = true) the head has no right end at all: the lane's
// state is the pill beside the lane's name in the page head, and the link to the page itself has nothing to open. No chip, no
// link, no empty stand-in: headEnd returns null, and a caller appends it only when there is one (headWith).
function headEnd(lane, state, page) {
  if (page) return null;
  const end = span("q-head-end", "");
  const chip = laneChip(state);
  if (chip) end.append(chip);
  end.append(detailsLink(lane));
  return end;
}
function headWith(head, lane, state, page) {   // append the head's right end, if the card has one
  const end = headEnd(lane, state, page);
  if (end) head.append(end);
}
function chipState(a, known) {  // a: the card's answer (quota or credit); known: the lane's state from its details page, if loaded
  if (a.dormant || (known && known.state === "dormant")) return "dormant";
  if ((a.error && NOT_CONFIGURED_WORDS.includes(a.error)) || a.configured === false || (known && known.state === "not set up")) return "unconfigured";
  if (a.pending && !a.fetchedAt && !a.error) return "pending";   // the first answer is still on its way
  return "active";
}
// the line under a dormant head: the reason as a sentence, then the day since, "Usage check refused since Tue Jan 6th"
const REASON_WORDS = { "credit used up": "ov.reason.creditUsedUp" };   // sala's reason (watch.sh ld_limit_tick) as a sentence, by lower-case key
// A reason set by hand can end in its own "(who, day)" (sala lane dormant api --reason "… (Alex, Tue Jan 6th)"); the card
// says the day itself, so that last parenthesised part goes, once: "Usage check refused (…)" reads "Usage check refused".
function reasonText(reason) {
  const r = String(reason || "").replace(/\s*\([^()]*\)\s*$/, "").trim();
  return r ? (Object.hasOwn(REASON_WORDS, r.toLowerCase()) ? tl(REASON_WORDS[r.toLowerCase()]) : capFirst(r)) : "";
}
function dormantLine(d) {
  const r = reasonText(d.reason);
  const when = dayWords(d.since);
  return r ? (when ? tl("ov.dormant.since", { reason: r, when }) : r) : when ? tl("ov.dormant.sinceOnly", { when }) : "";
}
// A PER-USE LANE (api, aws-platform, bedrock) KEEPS ITS FIGURES WHEN DORMANT: the card is the active card (its
// "This month" figure and its estimate or updated line) with the chip "dormant" and the dormant line, the reason and the day,
// under the head. A subscription lane's card (limits, not spend) stays the head and one line (dormantCard).
function dormantNote(d) {
  return div("q-dormant-line", dormantLine(d));
}
// EVERY CARD ENDS WITH ONE LINE, "updated 7 min ago": the time of the card's last GOOD reading, never of a try
// that failed. A card's note (the dormant reason, an error or soft note, a "not counted" warning) is the line directly above it,
// under the figures. The time is the answer's own fetchedAt (the server's swr.py cache: when the figures were last read); an
// answer that carries none (a lane that never answered) says "updated unknown", never a time of ours. The words come from
// agoLine (shared.js: "as of" instead of "updated" past staleMs, when the refreshes are failing); app.js ages them on its
// 30-second tick (data-t, data-stale); the exact time (with the zone's label) is the tooltip.
function updatedFoot(t, staleMs) {
  const f = div("c-line c-foot c-updated");
  if (typeof t === "number" && isFinite(t) && t > 0) {
    f.dataset.t = String(t);
    f.dataset.stale = String(staleMs);
    f.textContent = agoLine(t, staleMs);
    const d = new Date(t);
    f.title = dayWords(d.toISOString()) + " " + zoneTime.format(d) + " " + zoneLabel(d);
  } else {
    f.textContent = tl("ov.foot.unknown");
    f.title = tl("ov.foot.unknownTitle");
  }
  return f;
}
// the same line, empty, for a card still waiting for its first answer: the answer lands without moving the cards below
const pendingFoot = () => div("c-line c-foot c-updated", " ");
// The card's closing lines (the "not counted" warnings, the notes, the updated line) sit at the bottom of the card: the cards of a
// row share one height, so the first of those lines takes the free room above it (q-end, sessions.css) and the closing lines of
// neighbouring cards sit on one level, the note right above the time.
const END_KINDS = ".c-warn, .q-dormant-line, .q-err, .c-updated";
function pinEnd(card) {
  const kids = [...card.children];
  let i = kids.length;
  while (i > 0 && kids[i - 1].matches(END_KINDS)) i--;
  if (i < kids.length) kids[i].classList.add("q-end");
  return card;
}
const quotaCard = (...args) => pinEnd(quotaCardBody(...args));
const creditCard = (...args) => pinEnd(creditCardBody(...args));
const spendCard = (...args) => pinEnd(spendCardBody(...args));
function dormantCard(lane, d, headKids, page, fetchedAt) {  // headKids: the head's spans, as the active card builds them; page: on the details page; fetchedAt: the last good reading, if the server kept one
  const card = div("q-card q-dormant lane-" + lane);
  const head = div("q-head");
  head.append(...headKids);
  headWith(head, lane, "dormant", page);
  card.append(head, div("q-dormant-line", dormantLine(d)), updatedFoot(fetchedAt, QUOTA_STALE_MS));
  return card;
}

// The plan name ("Max (20x)", "Team", "API (metered)") beside the lane's pill is the details page's (opts.plan): the
// Overview's head is the pill, the chip and "Details ›", which are the same on every card and never wrap.
function quotaCardBody(q, known, opts = {}) {
  if (q && q.lane !== laneNorm(q.lane)) q = { ...q, lane: laneNorm(q.lane) };
  if (q.dormant) return dormantCard(q.lane, q.dormant, [span("sp-pill lane-" + q.lane, laneLabel(q.lane)), ...(opts.plan && q.plan ? [span("q-plan", q.plan)] : [])], opts.page, q.fetchedAt);
  const card = div("q-card lane-" + q.lane);
  const head = div("q-head");
  head.append(span("sp-pill lane-" + q.lane, laneLabel(q.lane)));
  if (opts.plan && q.plan) head.append(span("q-plan", q.plan));
  headWith(head, q.lane, chipState(q, known), opts.page);
  card.append(head);
  // no answer yet (a first start): the rows a lane usually has, drawn quietly, so the grid keeps its size
  if (q.pending && !q.error) {
    card.classList.add("q-pending");
    for (let i = 0; i < PLACEHOLDER_ROWS; i++) {
      const row = div("q-row");
      const name = div("");
      name.append(div("q-name", "\u00a0"), div("q-reset", "\u00a0"));
      const bar = div("q-bar");
      bar.append(div("q-fill"));
      row.append(name, bar, div("q-pct", "\u2014"));
      card.append(row);
    }
    card.append(pendingFoot());
    return card;
  }
  for (const l of q.limits || []) {
    const pct = typeof l.percent === "number" ? Math.max(0, Math.min(100, l.percent)) : null;
    const sev = !l.severity || l.severity === "normal" ? "" : l.severity === "warning" ? " warning" : " bad";
    const row = div("q-row" + sev);
    const name = div("");
    name.append(div("q-name", l.label), div("q-reset", resetsText(l.resetsAt)));
    const bar = div("q-bar");
    const fill = div("q-fill");
    fill.style.width = (pct ?? 0) + "%";
    bar.append(fill);
    bar.setAttribute("role", "progressbar");
    bar.setAttribute("aria-label", l.label);
    if (pct != null) bar.setAttribute("aria-valuenow", String(Math.round(pct)));
    row.append(name, bar, div("q-pct", pct == null ? tl("ov.common.unknown") : tl("ov.q.used", { pct: Math.round(pct) })));
    if (pct != null) row.lastChild.dataset.short = Math.round(pct) + "%";   // the phone's chip strip shows the figure alone
    card.append(row);
  }
  if (!q.error && !(q.limits || []).length) card.append(div("q-reset", tl("ov.q.noLimits")));
  if (q.error) card.append(quotaError(q));   // the note sits under the rows, directly above the last line
  card.append(updatedFoot(q.fetchedAt, QUOTA_STALE_MS));
  return card;
}

// the API key's spend (metered and sdk lanes bill the same key; the Admin API cannot tell them apart): today and this
// month in the SALA_TZ zone. Complete UTC days come exact from the cost report; the latest hours, which it does not have yet, are
// estimated from the hourly usage report, and the card says so.
const compact = { format: (n) => SalaI18n.number(n, { notation: "compact", maximumFractionDigits: 1 }) };
const TOKEN_TYPE = {
  uncached_input_tokens: "ov.tok.input", output_tokens: "ov.tok.output", cache_read_input_tokens: "ov.tok.cacheRead",
  "cache_creation.ephemeral_5m_input_tokens": "ov.tok.cacheWrite5m",
  "cache_creation.ephemeral_1h_input_tokens": "ov.tok.cacheWrite1h", web_search_requests: "ov.tok.search",
};
// a failed request's note is kept as a key with its text, so a language change words it again; a server answer's own error stays as it came
const errText = (x) => (x.local ? tl(x.local.key, { msg: x.local.msg }) : x.error);
const usd = (n) => "$" + Math.abs(n).toFixed(2);
// "6:13 PM" today, "Wed 6:13 PM" within a week either way, "Wed Jan 14 6:13 PM" further; in the SALA_TZ zone
function whenText(iso) {
  const d = new Date(Date.parse(iso));
  if (!iso || isNaN(d)) return "";
  const now = new Date();
  if (zoneDay.format(d) === zoneDay.format(now)) return zoneTime.format(d);
  const day = Math.abs(d - now) < 7 * 86400000 ? weekdayOnly(d) : weekdayDate(d);
  return day + " " + zoneTime.format(d);
}

function creditCardBody(c, opts = {}) {  // opts.known: the lane's state from its details page, when that page draws the card; opts.plan: the plan name beside the pills (the details page's)
  // the Billing link belongs to the lane's details page (opts.billing), not to the Overview card
  // dormant: the same card, with the dormant line under the head and the figures the Admin API gives, as when active
  const plan = opts.plan ? [span("q-plan", "API (metered)")] : [];
  const card = div("q-card c-card lane-api" + (c.dormant ? " q-dormant" : ""));
  const head = div("q-head");
  head.append(span("sp-pill lane-api", LANE_LABEL.api), span("sp-pill lane-sdk", LANE_LABEL.sdk), ...plan);
  headWith(head, "api", chipState(c, opts.known), opts.page);
  if (opts.billing) {
    // the billing page is always linked on the details page, also when the figures could not be read
    const bill = document.createElement("a");
    bill.className = "c-bill";
    bill.href = c.consoleUrl || "https://platform.claude.com/settings/billing";
    bill.target = "_blank";
    bill.rel = "noopener";
    bill.textContent = tl("ov.c.billing");
    head.append(bill);
  }
  card.append(head);
  const has = typeof c.todayUsd === "number" && typeof c.monthUsd === "number";
  // the notes come under the figures, directly above the last line: the dormant reason, then the error
  const notes = () => [...(c.dormant ? [dormantNote(c.dormant)] : []), ...(c.error ? [div("q-err", has ? tl("ov.c.refreshFailed", { error: errText(c) }) : errText(c))] : [])];
  if (!has && !(c.pending && !c.error)) {
    card.append(...notes());
    if (c.dormant) card.append(div("c-line", tl("ov.c.usageUnavailable")));   // the figures cannot be had: said beside the reason, not left blank
    card.append(updatedFoot(c.fetchedAt, CREDIT_STALE_MS));
    return card;
  }
  if (!has) card.classList.add("q-pending");  // no answer yet: the same rows, quietly, until the first refresh lands

  const figs = div("c-figs");
  for (const [k, v, cls] of [[tl("ov.c.spentToday"), c.todayUsd, "c-today"], [tl("ov.c.thisMonth"), c.monthUsd, "c-month"]]) {
    const f = div("c-fig " + cls);
    f.append(span("c-k", k), span("c-v", has ? usd(v) : "\u2014"));
    figs.append(f);
  }
  card.append(figs);

  // the latest hours are priced from usage until the cost report has their day: labelled, with the hours they cover
  const foot = div("c-line c-foot c-estline");
  const parts = has ? [] : [tl("ov.c.notYet")];
  if (has && c.estimatedFrom && c.monthEstimatedUsd > 0) {
    const est = span("c-est", tl("ov.c.estimated", { usd: usd(c.monthEstimatedUsd), range: whenText(c.estimatedFrom) +
      (c.usageThrough ? "–" + whenText(c.usageThrough) : "") }));
    parts.push(est);
  }
  parts.forEach((p, i) => foot.append(...(i ? [" · ", p] : [p])));
  foot.title = foot.textContent;  // one line, cut with an ellipsis on a phone: the whole of it on hover
  if (parts.length) card.append(foot);
  const unpriced = (c.unpriced || []).map((u) => tl(u.model ? "ov.c.unpricedOn" : "ov.c.unpriced", {
    count: compact.format(u.count), type: Object.hasOwn(TOKEN_TYPE, u.type) ? tl(TOKEN_TYPE[u.type]) : u.type, model: u.model ? modelLabel(u.model) : "" }));
  if (unpriced.length) card.append(div("c-line c-warn", tl("ov.c.notCountedRate", { list: unpriced.join(" · ") })));
  card.append(...notes());
  card.append(has ? updatedFoot(c.fetchedAt, CREDIT_STALE_MS) : pendingFoot());
  return card;
}

// THE AWS LANES' SPEND: the aws-platform and bedrock lanes have no usage or cost API we can read, so the server
// counts the month's spend from this machine's own transcripts (spend.py) and the card says what it is: an ESTIMATE AT LIST
// PRICES, the UTC month from the day shown. The real bill can differ. One card per lane: the figure, the models (name, $,
// share), the sessions on the lane (name linked while it runs, $, share; the top few on the Overview, all on the details
// page), what could not be counted in plain words, and when it was counted. A lane that cannot be counted says so in the card.
const usdEst = (n) => (n > 0 && n < 0.005 ? "<$0.01" : usd(n));
const shareText = (x) => (typeof x !== "number" ? "" : x > 0 && x < 0.005 ? "<1%" : Math.round(x * 100) + "%");
function spendRow(nameNode, amount, share, title) {
  const row = div("s-row");
  const name = div("s-name");
  name.append(nameNode);
  row.append(name, span("s-usd", usdEst(amount), title), span("s-share", shareText(share)));
  return row;
}
// a: this lane's entry of api/spend with the answer's own fields (since, fetchedAt, pending, error); opts.all: every session
// (the details page); opts.known: the lane's state from its details page
function spendCardBody(lane, a, opts = {}) {
  const pill = span("sp-pill lane-" + lane, laneLabel(lane));
  const card = div("q-card c-card s-card lane-" + lane + (a.dormant ? " q-dormant" : ""));   // dormant: the active card with the dormant line under the head
  const head = div("q-head");
  head.append(pill);
  headWith(head, lane, chipState(a, opts.known), opts.page);
  card.append(head);
  const brief = !opts.all && SPEND_BRIEF_LANES.includes(lane);   // the owner does not need the models, the sessions or the "no sessions" line on this Overview card
  const has = typeof a.monthUsd === "number";
  // the notes come under the figures, directly above the last line: the dormant reason, then the error
  const notes = () => [...(a.dormant ? [dormantNote(a.dormant)] : []), ...(a.error ? [div("q-err", has ? tl("ov.c.refreshFailed", { error: errText(a) }) : errText(a))] : [])];
  const foot = () => updatedFoot(a.fetchedAt, SPEND_STALE_MS);
  if (!has && !(a.pending && !a.error)) {   // the plain-words error is all the card has to say
    card.append(...notes());
    if (a.dormant) card.append(div("c-line", tl("ov.c.usageUnavailable")));
    card.append(foot());
    return card;
  }
  if (!has) card.classList.add("q-pending");           // no answer yet: the same lines, quietly, until the first count lands
  if (has && !a.dormant && (a.configured === false || (opts.known && opts.known.state === "not set up")) && !(a.monthUsd > 0)) {
    card.append(div("q-dormant-line", tl("ov.s.notSetUp")), foot());
    return card;
  }
  const figs = div("c-figs");
  const f = div("c-fig c-month");
  f.append(span("c-k", tl("ov.c.thisMonth")), span("c-v", has ? usdEst(a.monthUsd) : "—"));
  figs.append(f);
  card.append(figs);
  const since = a.since ? dayWords(a.since) : "";
  const est = div("c-line c-foot s-est", has ? (since ? tl("ov.s.estimateSince", { since }) : tl("ov.s.estimate")) : tl("ov.c.notYet"));
  est.title = since ? tl("ov.s.estTitleSince", { since }) : tl("ov.s.estTitle");
  card.append(est);
  if (!has) {
    // the lines a card with figures has (a sentence, the notes, the "updated" foot), blank, so the answer lands without moving the
    // cards below; a brief Overview card has no sentence line, so its blank is the notes and the foot only
    if (!brief) card.append(div("c-line", " "));
    card.append(...notes(), pendingFoot());
    return card;
  }
  if (opts.all) card.append(div("c-line", tl("ov.s.counted")));
  if (!brief && !(a.calls > 0) && !(a.unpriced || []).length) card.append(div("c-line", tl("ov.s.noSessionsUsed")));
  const total = a.monthUsd || 0;
  if (!brief && (a.models || []).length) {
    const list = div("s-list");
    list.append(div("s-h", tl("ov.s.byModel")));
    for (const m of a.models) list.append(spendRow(document.createTextNode(modelLabel(m.model)), m.usd, total > 0 ? m.usd / total : null, m.model));
    card.append(list);
  }
  const sess = brief ? [] : a.sessions || [];
  if (sess.length) {
    const list = div("s-list");
    list.append(div("s-h", tl("ov.s.sessions")));
    const shown = opts.all ? sess : sess.slice(0, SPEND_TOP);
    for (const s of shown) {
      let node;
      if (s.live) {
        node = document.createElement("a");
        node.href = "#s=" + encodeURIComponent(s.name);
        node.textContent = s.name;
      } else {
        node = span("sp-muted", s.name, tl("ov.s.notRunning"));
      }
      list.append(spendRow(node, s.usd, s.share, s.name));
    }
    if (shown.length < sess.length) {
      const more = document.createElement("a");
      more.className = "s-more";
      more.href = "#lane=" + encodeURIComponent(lane);
      more.textContent = tl("ov.s.more", { n: sess.length - shown.length });
      list.append(more);
    }
    card.append(list);
  }
  const unpriced = (a.unpriced || []).map((u) => tl("ov.s.unpriced", { n: u.calls, count: compact.format(u.calls), model: modelLabel(u.model) }));
  if (unpriced.length) card.append(div("c-line c-warn", tl("ov.s.notCountedPrice", { list: unpriced.join(" · ") })));
  const lost = a.unmatched || [];
  if (lost.length) card.append(div("c-line c-warn", tl("ov.s.lost", { n: lost.length, names: lost.join(", ") })));
  card.append(...notes(), foot());
  return card;
}
// this lane's entry of the api/spend answer joined with the answer's own fields: what spendCard draws
function spendOf(lane, answer) {
  const ans = answer || { pending: true };
  const entry = (ans.lanes || []).find((x) => laneNorm(x.lane) === lane) || {};
  const own = { ...ans };
  delete own.lanes;
  return { ...own, ...entry, lane };
}

// The quota cards and the spend card render together, in one pass: both answers are gathered first (the server answers
// both at once from its last good answer, never waiting on Anthropic), so no card lands late and pushes the grid
// about. Before the first answer the grid holds placeholders of the same size. While the server says a background
// refresh runs, the part it concerns is asked again shortly, and its cards are replaced in their slots.
const getJson = (url) => fetch(url, { cache: "no-store" }).then((r) => { if (!r.ok) throw new Error("HTTP " + r.status); return r.json(); });
// active lanes first, then dormant, then not configured, each group in the order the cards are drawn; the state is
// the chip's own word, so the order can never disagree with what the cards say (Array.sort is stable)
function cardRank(card) {
  const m = /\blane-chip-(\w+)/.exec((card.querySelector(".lane-chip") || {}).className || "");
  return m && m[1] in CARD_RANK ? CARD_RANK[m[1]] : 0;
}
/* THE CARDS' ORDER. With nothing saved the cards keep the order
   above (cardRank). Once the owner has dragged one, his order (api/prefs laneOrder, a flat list of lane ids, as the Schedules page keeps
   its groups) rules whatever a lane's state is, so a lane that goes dormant stays where he put it. A lane not in the list (a new
   one) follows the listed ones, in the default order; an id with no card now is ignored (and kept in the list, in case the lane
   comes back). A card moves by its handle (a mouse, a finger or a pen) or by the arrow keys on the handle, and the order is saved when
   the drag is let go. The details page's card has no handle: only the grid below draws one. inOrder, mergeOrder, saveList and state
   come from app.js (used at call time). */
const cardLane = (card) => { const m = /\blane-([\w-]+)/.exec(card.className); return m ? m[1] : ""; };
// the saved order is read through laneNorm (a view saved before the rename says max and team) and is never rewritten for it: the next drag saves the new codes
const laneOrderPref = () => (typeof state !== "undefined" && state.prefs && Array.isArray(state.prefs.laneOrder) ? [...new Set(state.prefs.laneOrder.map(laneNorm))] : []);
function saveLaneOrder() {
  const shown = [...document.querySelectorAll("#q-cards > .q-card")].map(cardLane);
  saveList("laneOrder", (cur) => mergeOrder(shown, shown, [...new Set(cur.map(laneNorm))], 20));
}
// a drag by the handle: the card follows the pointer by taking the place of the card under it (the cards sit in a grid, so the
// place is found by the card the pointer is over, not by a line); a cancelled pointer puts everything back
function laneDragStart(e, card) {
  if (e.button) return;
  e.preventDefault();
  const grip = e.currentTarget, box = card.parentElement, id = e.pointerId;
  const before0 = card.nextElementSibling;
  try { grip.setPointerCapture(id); } catch { /* released */ }
  card.classList.add("q-dragging");
  sp.laneDrag = true;
  const move = (ev) => {
    if (ev.pointerId !== id) return;
    const over = [...box.children].find((x) => {
      if (x === card) return false;
      const r = x.getBoundingClientRect();
      return ev.clientX >= r.left && ev.clientX <= r.right && ev.clientY >= r.top && ev.clientY <= r.bottom;
    });
    if (!over) return;
    const kids = [...box.children];
    box.insertBefore(card, kids.indexOf(card) > kids.indexOf(over) ? over : over.nextElementSibling);   // before the one it passes going back, after it going on
  };
  const done = (ok) => {   // on the window, not the handle: the move is followed wherever the pointer goes, captured or not
    window.removeEventListener("pointermove", move);
    window.removeEventListener("pointerup", up);
    window.removeEventListener("pointercancel", cancel);
    card.classList.remove("q-dragging");
    try { grip.releasePointerCapture(id); } catch { /* released */ }
    sp.laneDrag = false;
    if (ok && card.nextElementSibling !== before0) saveLaneOrder();
    else if (!ok) box.insertBefore(card, before0);
    if (sp.laneRedraw) { sp.laneRedraw = false; drawCards(); }   // an answer landed during the drag: draw it now
  };
  const up = (ev) => { if (ev.pointerId === id) done(true); }, cancel = (ev) => { if (ev.pointerId === id) done(false); };
  window.addEventListener("pointermove", move);
  window.addEventListener("pointerup", up);
  window.addEventListener("pointercancel", cancel);
}
// the keyboard (and a screen reader): left and up on the handle move the card one place earlier, right and down one later
function laneGripKey(e, card) {
  const back = e.key === "ArrowLeft" || e.key === "ArrowUp", fwd = e.key === "ArrowRight" || e.key === "ArrowDown";
  if (!back && !fwd) return;
  e.preventDefault();
  const other = back ? card.previousElementSibling : card.nextElementSibling;
  if (!other) return;
  card.parentElement.insertBefore(card, back ? other : other.nextElementSibling);
  saveLaneOrder();
  e.currentTarget.focus();
}
function laneGrip(card) {
  const lane = cardLane(card), name = laneLabel(lane);
  const grip = document.createElement("button");
  grip.type = "button";
  grip.className = "q-grip";
  grip.title = tl("ov.grip.title");
  grip.setAttribute("aria-label", tl("ov.grip.label", { name }));
  grip.textContent = "⋮⋮";
  grip.addEventListener("pointerdown", (e) => laneDragStart(e, card));
  grip.addEventListener("keydown", (e) => laneGripKey(e, card));
  return grip;
}
/* The phone's chip strip: the lane cards folded into one line of chips, "<lane label> 40% · 10%", "bedrock $12", "1 dormant", read
   off the cards just drawn (so it can never disagree with them); a tap on the strip opens the cards (sessions.css shows the strip
   on a phone only, and the cards below it only while #quota has q-open). */
function stripChips(cards) {
  const chips = [];
  let dormant = 0;
  for (const card of cards) {
    if (card.querySelector(".lane-chip-dormant")) { dormant++; continue; }
    if (card.classList.contains("q-pending")) continue;
    const label = (card.querySelector(".q-head .sp-pill") || {}).textContent;
    if (!label) continue;
    const figs = [...card.querySelectorAll(".q-pct")].map((n) => n.dataset.short || n.textContent.replace(/ used$/, "")).filter((t) => /\d/.test(t)).slice(0, 2);
    const money = card.querySelector(".c-v");
    const rest = figs.length ? figs.join(" \u00b7 ") : money ? money.textContent : "";
    chips.push(rest ? `${label} ${rest}` : label);
  }
  if (dormant) chips.push(tl("ov.strip.dormant", { n: dormant }));
  return chips;
}
function stripRender(cards) {
  const box = document.getElementById("q-chips");
  box.replaceChildren(...stripChips(cards).map((t) => span("q-chip", t)));
}
document.getElementById("q-strip").addEventListener("click", () => {
  const q = document.getElementById("quota"), open = !q.classList.contains("q-open");
  q.classList.toggle("q-open", open);
  document.getElementById("q-strip").setAttribute("aria-expanded", String(open));
  stripTitle();
});
function stripTitle() {
  const b = document.getElementById("q-strip");
  b.title = tl(b.getAttribute("aria-expanded") === "true" ? "ov.strip.hide" : "ov.strip.show");
}
function drawCards() {
  if (sp.laneDrag) { sp.laneRedraw = true; return; }   // never swap the cards under a finger that is dragging one
  const ranked = [...sp.qcards, ...(sp.ccard ? [sp.ccard] : []), ...sp.scards].sort((a, b) => cardRank(a) - cardRank(b));
  const saved = laneOrderPref();
  const cards = saved.length ? inOrder(ranked, saved, cardLane) : ranked;
  for (const c of cards) {
    const head = c.querySelector(".q-head");
    if (head && !head.querySelector(".q-grip")) head.prepend(laneGrip(c));
  }
  document.getElementById("q-cards").replaceChildren(...cards);
  stripRender(cards);
  laneRender();
}
// every card from the answers held (none yet: the placeholders), so a language change words them again without a request
function buildCards() {
  sp.qcards = sp.quota ? sp.quota.map((q) => quotaCard(q)) : PLACEHOLDER_LANES.map((lane) => quotaCard({ lane, pending: true }));
  sp.ccard = creditCard(sp.credit || { pending: true });
  sp.scards = SPEND_LANES.map((lane) => spendCard(lane, spendOf(lane, sp.spend)));
}
function placeholders() {
  buildCards();
  drawCards();
}
function renderQNote() {
  const note = document.getElementById("q-note");
  note.className = "q-note" + (sp.qerr ? " error" : "");
  note.textContent = sp.qerr ? tl("ov.err.quota", { msg: sp.qerr }) : "";   // the line is only for an error (the loose "metered and sdk: billed per use" text is gone)
}
async function loadCards(which = { quota: true, credit: true, spend: true }, follow = false) {
  if (!follow) sp.tries = 0;
  const [q, c, w] = await Promise.all([
    which.quota ? getJson("api/quota").then((ok) => ({ ok }), (err) => ({ err })) : null,
    which.credit ? getJson("api/credit").catch((e) => ({ error: tl("ov.err.apiSpend", { msg: e.message }), local: { key: "ov.err.apiSpend", msg: e.message } })) : null,
    which.spend ? getJson("api/spend").catch((e) => ({ error: tl("ov.err.awsSpend", { msg: e.message }), local: { key: "ov.err.awsSpend", msg: e.message }, failed: true })) : null,
  ]);
  if (q && q.ok) {
    sp.quota = q.ok.lanes || [];
    sp.qcards = sp.quota.map((q) => quotaCard(q));
    sp.qerr = null;
    renderQNote();
  } else if (q) {
    sp.qerr = q.err.message;
    renderQNote();
  }
  if (c) { sp.credit = c; sp.ccard = creditCard(c); }
  if (w) {
    // a request that failed keeps the last counted figures and says so; the server's own answer (it may carry an error of its own) replaces them
    sp.spend = w.failed ? (sp.spend ? { ...sp.spend, error: w.error, local: w.local } : { pending: true, error: w.error, local: w.local }) : w;
    sp.scards = SPEND_LANES.map((lane) => spendCard(lane, spendOf(lane, sp.spend)));
  }
  drawCards();
  const again = { quota: !!(q && q.ok && (q.ok.lanes || []).some((l) => l.refreshing)), credit: !!(c && c.refreshing), spend: !!(w && w.refreshing) };
  if ((again.quota || again.credit || again.spend) && sp.active && sp.tries++ < FOLLOW_MAX) {
    clearTimeout(sp.follow);
    sp.follow = setTimeout(() => loadCards(again, true), FOLLOW_MS);
  }
}

/* A LANE'S DETAILS PAGE (#lane=<id>, a view of the same pane as the overview, so it polls what the overview polls
   and draws its usage and its sessions from the same answers with the same helpers). Its own part is the lane's record
   and state, from api/lanes/<id> (sala's lane table; the server takes every file path out of it), asked when the page
   opens and with the quota check after that. It shows: the state (a pill in the head, and a line under it unless the lane is active), the record, the
   usage as the lane's card shows it (limits for the subscription lanes, spend and the billing link for the API lane), and the
   sessions on the lane, each linked. */
const RECORD_ROWS = [["provider", "ov.rec.provider"], ["client", "ov.rec.client"], ["org", "ov.rec.org"], ["project", "ov.rec.project"],
  ["billing", "ov.rec.billing"], ["payment", "ov.rec.payment"], ["plan", "ov.rec.plan"], ["account", "ov.rec.account"], ["credential", "ov.rec.credential"],
  ["region", "ov.rec.region"]];
const PLAN_WORDS = { max_5x: "Max 5x", max_20x: "Max 20x", team_standard: "Team Standard", team_premium: "Team Premium",
  chatgpt_plus: "ChatGPT Plus", chatgpt_pro: "ChatGPT Pro", chatgpt_business: "ChatGPT Business", google_ai_pro: "Google AI Pro",
  google_ai_ultra: "Google AI Ultra" };
const capFirst = (s) => s.charAt(0).toUpperCase() + s.slice(1);
function recordValue(key, v) {
  if (key === "plan") return PLAN_WORDS[v] || capFirst(v.replace(/_/g, " "));
  if (["billing", "payment", "credential"].includes(key)) return capFirst(v);
  return v;
}
// the lane's name in the details page's title: the lane word the labels use (LANE_LABEL, lower case: "bedrock", "aws-platform"), never the
// record's own capitalised label ("Bedrock", "Claude Platform on AWS"); a lane LANE_LABEL does not know falls back to its record's label in lower case
const laneName = (id, rec) => laneLabelOr(id, ((rec && rec.label) || id).toLowerCase());
// the sessions that run on this lane: the api lane's page also lists the sdk ones (one lane, two clients)
const onLane = (r, id) => laneNorm(r.lane) === id || (id === "api" && r.lane === "sdk");

// the lane's state in the page head: the status pill the Overview card wears (laneChip: active
// green, dormant grey, not configured a grey outline) right after the lane's name, and, for a lane that is not active, one plain
// line under the head saying what that means. An active lane has no line. While the record is loading, or sala could not read it, there
// is no pill: it would say a state nobody has told the page.
function laneHead(l) {
  const s = l.state;
  if (!l.loaded) return { chip: null, line: "" };
  if (l.notFound) return { chip: null, line: tl("ov.lane.unknown") };
  if (!s || s.state === "unknown") return { chip: null, line: tl("ov.lane.unavailable") };
  // the reason and the day are on the card's line under its head, just below: not said twice
  // a per-use lane (api, aws-platform, bedrock) keeps its spend while dormant: only the account lanes are asked nothing
  if (s.state === "dormant") return { chip: laneChip("dormant"), line: tl(l.id === "api" || SPEND_LANES.includes(l.id) ? "ov.lane.dormantPerUse" : "ov.lane.dormantAccount") };
  if (s.state === "not set up") return { chip: laneChip("unconfigured"), line: tl("ov.lane.notSetUp") };
  return { chip: laneChip("active"), line: "" };
}

function laneRecord(l) {
  const rec = l.record;
  if (!rec) {
    return div("ld-none", !l.loaded ? tl("common.loading") : l.notFound ? tl("ov.lane.recNone", { id: l.id }) : tl("ov.lane.recUnavailable"));
  }
  const dl = document.createElement("dl");
  dl.className = "ld-dl";
  for (const [key, label] of RECORD_ROWS) {
    if (!rec[key]) continue;
    const dt = document.createElement("dt"), dd = document.createElement("dd");
    dt.textContent = tl(label);
    dd.textContent = recordValue(key, rec[key]);
    dl.append(dt, dd);
  }
  return dl;
}

// the lane's usage, drawn by the card's own helpers from the card's own answers
function laneUsage(l) {
  const id = l.id;
  if (id === "api") return creditCard(sp.credit || { pending: true }, { billing: true, known: l.state, plan: true, page: true });
  if (SPEND_LANES.includes(id)) return spendCard(id, spendOf(id, sp.spend), { all: true, known: l.state, page: true });
  if (PLACEHOLDER_LANES.includes(id)) {
    const q = sp.quota && sp.quota.find((x) => laneNorm(x.lane) === id);
    if (q) return quotaCard(q, l.state, { plan: true, page: true });
    return sp.quota ? div("ld-none", tl("ov.lane.noFigures")) : quotaCard({ lane: id, pending: true }, null, { plan: true, page: true });
  }
  return div("ld-none", tl("ov.lane.noCheck"));
}

function laneRender() {
  const l = sp.lane;
  if (!l) return;
  const rec = l.record;
  const pill = span("sp-pill lane-" + l.id, laneLabel(l.id));
  const head = laneHead(l);
  document.getElementById("ld-title").replaceChildren(pill, span("ld-name", tl("ov.lane.title", { name: laneName(l.id, rec) })), ...(head.chip ? [head.chip] : []));
  document.getElementById("ld-line").textContent = head.line;
  const note = document.getElementById("ld-note");
  note.textContent = l.error ? tl("ov.err.laneRecord", { error: l.error }) : "";
  document.getElementById("ld-record").replaceChildren(laneRecord(l));
  const usage = laneUsage(l);
  document.getElementById("ld-usage").replaceChildren(usage);
  const rows = sp.rows.filter((r) => onLane(r, l.id));
  const body = document.querySelector("#ld-table tbody");
  body.replaceChildren(...rows.map(sessionRow));
  if (!rows.length) body.append(emptyRow(tl("ov.lane.noSessions")));
  document.getElementById("ld-count").textContent = tl("ov.lane.count", { n: rows.length });
}

async function laneLoad() {
  const l = sp.lane;
  if (!l) return;
  try {
    const r = await fetch("api/lanes/" + encodeURIComponent(l.id), { cache: "no-store" });
    if (sp.lane !== l) return;   // another lane's page (or none) was opened meanwhile
    if (r.status === 404) { l.record = null; l.notFound = true; l.error = null; l.state = null; }
    else if (!r.ok) throw new Error("HTTP " + r.status);
    else {
      const d = await r.json();
      if (sp.lane !== l) return;
      l.record = d.record || null; l.state = d.state || null; l.error = d.error || null; l.notFound = false;
    }
  } catch (e) {
    if (sp.lane !== l) return;
    l.error = e.message;
  }
  l.loaded = true;
  laneRender();
}

// the details page of a lane opens (id), or closes (null); app.js calls it when the hash is #lane=<id> or anything else
function showLane(id) {
  id = laneNorm(id);   // #lane=awsplatform, a link saved before the rename, opens the aws-platform page
  document.body.classList.toggle("lane-open", id != null);
  if (id == null) { sp.lane = null; return; }
  if (!sp.lane || sp.lane.id !== id) sp.lane = { id, record: null, state: null, error: null, notFound: false, loaded: false };
  laneRender();
  laneLoad();
}
const laneId = () => (sp.lane ? sp.lane.id : null);

function schedule() {
  clearInterval(sp.timer);
  clearInterval(sp.qtimer);
  clearInterval(sp.ctimer);
  sp.timer = setInterval(() => { if (!document.hidden) load(); }, REFRESH_MS);
  sp.qtimer = setInterval(() => { if (!document.hidden) { loadCards({ quota: true, spend: true }); laneLoad(); } }, QUOTA_MS);
  sp.ctimer = setInterval(() => { if (!document.hidden) loadCards({ credit: true }); }, CREDIT_MS);
}
// the lane names (sala's, api/lane-names) are asked again with every refresh; a label that changes (sala renamed a lane) is drawn at once from the answers the cards already hold
function refreshAll() { load(); loadCards(); laneLoad(); schedule(); loadLaneNames().then((changed) => { if (changed && sp.active) { load(); loadCards(); laneLoad(); } }); }
document.addEventListener("visibilitychange", () => { if (sp.active && !document.hidden) refreshAll(); });

// a language change words again what the page drew: the table and its count, the line above it, the cards from the answers held, the lane page
SalaI18n.onChange(() => {
  stripTitle();
  renderNote();
  renderQNote();
  if (sp.loaded) render();
  if (sp.ccard) { buildCards(); drawCards(); }   // drawCards draws the lane page too
  else laneRender();
});

// the view opens: read everything now, then poll; it leaves: stop polling (what it showed stays for the next open)
function start() {
  if (sp.active) return;
  sp.active = true;
  if (!sp.ccard) placeholders();  // the first open: the cards' slots are in the first paint
  refreshAll();
}
function stop() {
  sp.active = false;
  showLane(null);
  clearInterval(sp.timer);
  clearInterval(sp.qtimer);
  clearInterval(sp.ctimer);
  clearTimeout(sp.follow);
}
return { start, stop, showLane, laneId };
})();
