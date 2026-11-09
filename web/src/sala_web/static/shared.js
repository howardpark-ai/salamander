"use strict";
/* Helpers app.js and sessions.js (the sessions overview) both use, and the pure text functions the tests run in node
   (linkTokens, splitFooter); loaded before either. */
// <lane-words> (the tests run what is between these two markers in node)
// Lanes that were renamed: awsplatform became aws-platform, max became subscription-1 and team subscription-2.
// An answer, a saved link (#lane=max), a saved view (the lane order in the prefs) or a pane that still carries the old word reads as the new one: the
// same table as web/src/sala_web/lanestate.py RENAMED, and the one place the page reads a lane word through. Nothing stored is rewritten; a write says the new code.
const LANE_RENAMED = { awsplatform: "aws-platform", max: "subscription-1", team: "subscription-2" };
const laneNorm = (l) => (typeof l === "string" && Object.hasOwn(LANE_RENAMED, l) && LANE_RENAMED[l]) || l;
// every lane label is lower case, and the aws-platform lane reads with its hyphen, as its name does; sala calls the API-key lane "api"; the owner calls it metered; aws-platform is Claude Platform on AWS. The other lanes' names are sala's (api/lane-names): laneLabel
const LANE_LABEL = { api: "metered", sdk: "sdk", "aws-platform": "aws-platform", bedrock: "bedrock" };
const laneNames = {};  // lane code -> the display name sala gives it (api/lane-names: `sala lane names --json`); empty until the first answer: the page holds no name of its own
// the label a lane's pill, card and sentence carry: LANE_LABEL's word, else sala's display name in lower case, else (before the names have come) the code itself
const laneLabelOr = (code, other) => {   // other: what a lane with no label yet says
  const c = laneNorm(code);
  return (typeof c === "string" && (Object.hasOwn(LANE_LABEL, c) && LANE_LABEL[c] || Object.hasOwn(laneNames, c) && laneNames[c].toLowerCase())) || other;
};
const laneLabel = (code) => laneLabelOr(code, laneNorm(code));
// the names table out of api/lane-names' answer; true when it changed what a label says (the caller then draws again)
function applyLaneNames(doc) {
  const rows = doc && Array.isArray(doc.lanes) ? doc.lanes : [];
  let changed = false;
  for (const r of rows) {
    if (!r || typeof r.code !== "string" || typeof r.display !== "string" || !r.display) continue;
    if (laneNames[r.code] !== r.display) { laneNames[r.code] = r.display; changed = true; }
  }
  return changed;
}
// </lane-words>
// <unread-words> (the tests run what is between these two markers in node)
// The unread reply count of one session as the side panel shows it: only a front agent has one (the server sends every other role 0), and
// the open session never does (opening it reads its replies). A server that sends `unread` but no count reads as 1.
const unreadOfSession = (s, selected) => (s && s.role === "front" && s.name !== selected ? (Number.isInteger(s.unread_count) ? s.unread_count : s.unread ? 1 : 0) : 0);
const unreadTotal = (sessions, selected) => sessions.reduce((t, s) => t + unreadOfSession(s, selected), 0);
// The "Unread only" filter: the sessions of one project it keeps. An agent with an unread reply stays; so does the open one, until the
// owner leaves it (its replies count as read the moment it opens, so without this the row would vanish under the pointer).
const unreadKept = (sessions, selected) => sessions.filter((s) => s.name === selected || unreadOfSession(s, selected) > 0);
// </unread-words>
// asked once at start and again with the Overview's usual refresh; a failed or unreadable answer leaves what the page has
async function loadLaneNames() {
  try {
    const r = await fetch("api/lane-names", { cache: "no-store" });
    return r.ok ? applyLaneNames(await r.json()) : false;
  } catch { return false; }
}

/* The zone every time on the page is shown in: sala's SALA_TZ, which the server tells in api/config (timezone: the zone's name,
   "" when unset = the viewer's own zone; tzLabel: the zone's abbreviation, "UTC"; tzOffsetMin: its UTC offset now). zoneFormat()
   is an Intl.DateTimeFormat that follows the setting (made on first use, again if the setting changes), so a formatter can sit
   at the top of a file before api/config has answered. */
const zone = { name: "", label: "", offsetMin: null };
function applyZone(c) {
  zone.name = c && typeof c.timezone === "string" ? c.timezone : "";
  zone.label = c && typeof c.tzLabel === "string" ? c.tzLabel : "";
  zone.offsetMin = c && typeof c.tzOffsetMin === "number" ? c.tzOffsetMin : null;
}
function zoneFormat(locale, opts) {
  let made = null, madeFor = null;
  const get = () => {
    if (!made || madeFor !== zone.name) {
      try { made = new Intl.DateTimeFormat(locale, zone.name ? { ...opts, timeZone: zone.name } : opts); }
      catch { made = new Intl.DateTimeFormat(locale, opts); }   // a name this browser does not know: the viewer's zone
      madeFor = zone.name;
    }
    return made;
  };
  return { format: (d) => get().format(d), formatToParts: (d) => get().formatToParts(d) };
}
// the zone's short name at a moment: the browser's own when it has one ("PDT"), else the server's label (en-US spells some zones "GMT+4")
const zoneNameFmt = zoneFormat("en-US", { timeZoneName: "short" });
function zoneLabel(d) {
  const own = (zoneNameFmt.formatToParts(d || new Date()).find((x) => x.type === "timeZoneName") || {}).value || "";
  return zone.name && zone.label && /^GMT[+-]/.test(own) ? zone.label : own;
}

// "5 min ago" for a time t (epoch ms): the chat's message stamps (app.js) and the Overview cards' last line (sessions.js updatedFoot)
function relTime(t) {
  const s = Math.max(0, Math.round((Date.now() - t) / 1000));
  if (s < 45) return "just now";
  const m = Math.round(s / 60); if (m < 60) return m + " min ago";
  const h = Math.round(m / 60); if (h < 24) return h + (h === 1 ? " hour ago" : " hours ago");
  const d = Math.round(h / 24); return d + (d === 1 ? " day ago" : " days ago");
}
// a card's last line: "updated 7 min ago"; "as of 3 hours ago" once the answer is older than staleMs (its refreshes are failing)
const agoLine = (t, staleMs) => (Date.now() - t > staleMs ? "as of " : "updated ") + relTime(t);

// whether the block of lines directly above line i (up to the previous blank or fence line) is plain prose: not a fence
// line itself, no indented line and no list item in it, so the line is not a sibling item of a list whose last item
// has a lazy line
function proseAbove(lines, kind, i) {
  if (i === 0 || !lines[i - 1].trim() || kind[i - 1]) return false;
  for (let j = i - 1; j >= 0 && lines[j].trim() && !kind[j]; j--) {  // a fence line ends the block above
    if (/^\s/.test(lines[j]) || /^([-*+]|\d{1,9}[.)])(\s|$)/.test(lines[j])) return false;
  }
  return true;
}
// The text md() hands to marked. CommonMark lets a list interrupt a paragraph only when it starts at 1, so a
// reply that wrote "Next steps:\n6. x\n7. y" or put a "11." line right under prose got that line as plain paragraph text
// (flush left, with breaks:true shown as lines) while the items after a blank line were a real, indented list. A line
// that opens a numbered item gets a blank line before it, so it starts a list as the writer meant, when ALL of these hold:
//  - it is outside a code fence, at most 3 spaces in, "N." or "N)" with N 2 to 999, then a space and text;
//  - the lines above it, back to the previous blank or fence line, are all prose (proseAbove): none a list item or
//    indented (a nested bullet or a continuation), and the line directly above is no fence line, so an existing list (a
//    lazy line in its last item included), its sub-bullets and a code block are left as they are;
//  - the item's text does not itself start with "N." (the date "16. 10. 2026." at a line's start), and N is at most three
//    digits (the date "2026. 10. 16."); and
//  - the reply has a neighbouring number as a line-start item outside fences (N-1 or N+1), so one stray "16. 2026 meeting"
//    line in a paragraph, which is no sequence, stays text.
// "1." needs nothing (marked already lets it interrupt), and a number in the middle of a line is never touched.
function mdPrep(text) {
  const src = String(text == null ? "" : text);
  const lines = src.split("\n");
  const ITEM = /^ {0,3}(\d{1,3})[.)] +(?!\d+[.)](?: |$))\S/;
  const FENCE = /^ {0,3}(`{3,}|~{3,})/;
  const kind = [];  // per line: "fence" (a fence line or inside one), or "" outside
  let open = null;
  for (const l of lines) {
    const m = FENCE.exec(l);
    if (open) {
      kind.push("fence");
      if (m && m[1][0] === open[0] && m[1].length >= open.length && !l.slice(m[0].length).trim()) open = null;
    } else if (m) { open = m[1]; kind.push("fence"); } else kind.push("");
  }
  const nums = new Set();
  lines.forEach((l, i) => { const m = !kind[i] && ITEM.exec(l); if (m) nums.add(+m[1]); });
  if (!nums.size) return src;
  const out = [];
  lines.forEach((l, i) => {
    const m = !kind[i] && ITEM.exec(l);
    if (m && +m[1] > 1 && (nums.has(+m[1] - 1) || nums.has(+m[1] + 1)) && proseAbove(lines, kind, i)) out.push("");
    out.push(l);
  });
  return out.join("\n");
}

// Strikethrough takes two tildes only. marked's GFM rule for <del> takes a single "~" too, so a reply that wrote
// "10~19% ... 12~46" in one paragraph struck out everything between the two tildes. The rule is
// /^(~~?)(?=[^\s~])([\s\S]*?[^\s~])\1(?=[^~]|$)/; a span that starts with "~~" can only match as a pair of double tildes
// (the single-tilde branch needs a non-tilde right after the first "~"), so marked's own tokenizer still handles those, byte
// for byte, in lists, tables and nested spans. Any other "~" is no strike: undefined makes the lexer take it as text. A "~"
// inside a code span or fence never reaches this rule (those are other tokens). app.js calls it once.
function noSingleTildeStrike(markedLib) {
  markedLib.use({ tokenizer: { del(src) { return src.startsWith("~~") ? false : undefined; } } });  // false = marked's own rule
}

// "Opus 5.5" from "claude-opus-5-5", and from the same model as a cloud provider names it: Bedrock's
// "global.anthropic.claude-opus-5-5" / "us.anthropic.claude-sonnet-4-5-20250929-v1:0" / "anthropic.claude-opus-5-5", an
// inference-profile ARN ("arn:aws:bedrock:…:inference-profile/global.anthropic.claude-…": what follows the last "/"), and
// Vertex's "claude-sonnet-4-5@20250929". The pattern is not anchored at the end, so a date, "-v1:0" or "@default" after the
// version needs no stripping; only the ARN path and the "<region>.anthropic." prefix come off. A bare alias ("opus", "sonnet[1m]": a --model with no version that the server
// could not resolve) is never shown as a plain family: "Opus (version unknown)". The caller adds " @ <effort>".
function modelLabel(id) {
  const plain = (id || "").replace(/^.*\//, "").replace(/^(?:[a-z][a-z-]*\.)?anthropic\./i, "");
  const m = /^claude-([a-z]+)-(\d+)(?:-(\d{1,2}))?(?!\d)/.exec(plain);
  if (!m) {
    const a = /^([a-z]+)(\[1m\])?$/i.exec(id || "");
    return a ? a[1][0].toUpperCase() + a[1].slice(1).toLowerCase() + (a[2] ? " (1M)" : "") + " (version unknown)" : id || "";
  }
  return m[1][0].toUpperCase() + m[1].slice(1) + " " + m[2] + (m[3] ? "." + m[3] : "") + (/\[1m\]/i.test(id) ? " (1M)" : "");
}

// Links in text shown verbatim (a prompt bubble, a message from another session, a tool result: never markdown-rendered,
// so a [label](https://…) or a bare URL sat there as plain text): [{text}] and [{href, text}] pieces in order. Only
// http(s) URLs, so nothing else can become a link; a markdown link whose URL is anything else stays text. A bare URL
// ends before whitespace, quotes and brackets and drops trailing punctuation and an unbalanced ")".
const LINK_RE = /\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\)|https?:\/\/[^\s<>"'\]]+/g;
function linkTokens(text) {
  const out = [];
  let last = 0;
  for (const m of String(text || "").matchAll(LINK_RE)) {
    let href = m[2] || m[0], label = m[1] || m[0], end = m.index + m[0].length;
    if (!m[2]) {  // bare: a sentence's "." or an enclosing ")" is not part of it
      const cut = href.replace(/[.,;:!?]+$/, "");
      const bal = (cut.match(/\(/g) || []).length - (cut.match(/\)/g) || []).length;
      href = bal < 0 && cut.endsWith(")") ? cut.slice(0, -1) : cut;
      label = href;
      end = m.index + href.length;
    }
    if (m.index > last) out.push({ text: text.slice(last, m.index) });
    out.push({ href, text: label });
    last = end;
  }
  if (last < String(text || "").length) out.push({ text: String(text).slice(last) });
  return out;
}

// A reply's footer: the notes a session leaves at the very end of a reply under the owner's standing rules (a "Write-up:"
// line, "Board …" and "Page …" lines, each with its "- " bullets), which app.js renders apart from
// the body: smaller, dimmed, under a thin rule (Thu Oct 15th 2026). The rule, over the reply's lines:
//  - a NOTE line starts a note: "Write-up:"; "Board" followed by ":" or an item ("Board board#N: …",
//    "Board [board#N](url): …", "Board sN: …"; "Board members met" is prose); "Page:" or
//    "Page <slug with a />:" ("Page projects/sala: changed"; a deck's "Page 1: …" is prose). An UNDER line belongs to
//    the note above it: a "- " or "* " bullet, an indented continuation, a blank line. Anything else is PROSE.
//    A bold lead reads as the plain one: "**Write-up:** none", "**Board** board#N: …", "**Page:** done".
//  - the footer is the trailing run of NOTE and UNDER lines, from its earliest NOTE line to the end: a note followed by
//    prose is body (only a run that reaches the end counts), and bullets above the earliest note are body too.
//  - a run of "Page" notes alone (no Write-up or Board line) counts only when it has two or more notes, starts the
//    reply, or follows a blank line, so a body paragraph that merely begins with "Page …" stays body.
//  - one closing paragraph may follow the footer (the ask the rulebook puts last: "Drop both items? Answer on …"): when
//    the reply ends in a paragraph of prose (its first line PROSE, no blank line inside, at most FOOTER_TAIL_MAX lines)
//    and the lines before it, past the blank line, end in a run with a Write-up or Board note, that run is the
//    footer and the paragraph its TAIL. Two paragraphs after a run, a run of Page notes alone before one, or a closing
//    paragraph that begins with a note line are not a footer (such replies showed with the old unstyled footer). The tail renders as body text, the footer dimmed above it.
//  - failing both, a run holding a Write-up AND a Board note is the footer wherever it sits (footerAnywhere below).
// Returns { body, footer, notes, tail }: footer is null when there is none (then body === text and tail "", so the
// body renders as before); otherwise body is the text before it ("" when the footer starts the reply), notes the
// footer's notes in order, each a NOTE line with its UNDER lines (blank lines between notes dropped), so the renderer
// gives each its own block (markdown alone lazily joins a "Write-up: …" line onto the bullet before it, and adjacent
// "Page …" lines into one paragraph), and tail the closing paragraph ("" when the footer ends the reply).
const FOOTER_NOTE_STRONG = /^(Write-up:|Board(:|\s+(\[|board#|board-tmp|[a-z]\d+\b)))/;
const FOOTER_NOTE_WEAK = /^Page(:|\s+\[?`?[\w.-]+\/)/;  // "Page projects/x:", "Page [projects/x](url):", "Page [`projects/x`](url):"
const FOOTER_TAIL_MAX = 8;  // lines in the closing paragraph; an ask is one to three
const unboldLead = (line) => line.replace(/^(\*\*|__)(.+?)\1/, "$2");
function footerLineKind(line) {
  if (!line.trim()) return "blank";
  const lead = unboldLead(line);
  if (FOOTER_NOTE_STRONG.test(lead)) return "strong";
  if (FOOTER_NOTE_WEAK.test(lead)) return "weak";
  if (/^([-*] |\s)/.test(line)) return "under";
  return "prose";
}
// the trailing run of NOTE and UNDER lines in lines[0, end): where it starts (-1: none), whether it has a strong note,
// how many notes
function footerRun(lines, end) {
  let start = -1, strong = false, count = 0;
  for (let i = end - 1; i >= 0; i--) {
    const k = footerLineKind(lines[i]);
    if (k === "prose") break;
    if (k === "strong" || k === "weak") { start = i; count++; strong = strong || k === "strong"; }
  }
  return { start, strong, count };
}
// the notes of lines[start, end) and the footer record splitFooter returns (tailStart: where the tail begins)
function footerResult(lines, start, end, tailStart) {
  const notes = [];
  for (const l of lines.slice(start, end)) {
    if (footerLineKind(l) === "blank" || footerLineKind(l) === "under") notes[notes.length - 1].push(l);
    else notes.push([l]);
  }
  return { body: lines.slice(0, start).join("\n").replace(/\s+$/, ""), footer: lines.slice(start, end).join("\n"),
           notes: notes.map((n) => n.join("\n").replace(/\s+$/, "")), tail: lines.slice(tailStart).join("\n").replace(/\s+$/, "") };
}
// the footer at the very end of the reply, or before one closing paragraph (the rules above); null when there is none
function footerAtEnd(lines) {
  let end = lines.length;
  while (end > 0 && !lines[end - 1].trim()) end--;  // trailing blank lines belong to nobody
  let run = footerRun(lines, end), tailStart = end;
  if (run.start < 0 || (!run.strong && run.count < 2 && run.start > 0 && lines[run.start - 1].trim())) {
    // no footer at the very end: one may sit before a closing paragraph
    let p = end;
    while (p > 0 && lines[p - 1].trim()) p--;  // the last paragraph is lines[p, end)
    if (p === 0 || end - p > FOOTER_TAIL_MAX || footerLineKind(lines[p]) !== "prose") return null;
    let fend = p;
    while (fend > 0 && !lines[fend - 1].trim()) fend--;  // the blank line(s) before it
    run = footerRun(lines, fend);
    if (run.start < 0 || !run.strong) return null;
    tailStart = p; end = fend;
  }
  return footerResult(lines, run.start, end, tailStart);
}
// A footer ANYWHERE in the reply (a reply put a "Your step" paragraph, a numbered list, a lead
// line and a fenced block after its Write-up and Board lines, so none of the rules above matched and the footer showed as
// body text). A contiguous run of NOTE and UNDER lines (outside fenced code blocks) that holds both a "Write-up:" line and a
// Board line is the footer wherever it sits, the LAST such run when there are several; everything after it, from the
// first line of prose, is the tail, which renders as markdown at full size. The prose after the run must follow a blank
// line: a prose line right under a note is that note's wrapped line, not a tail. Weaker runs (no Write-up with a Board
// line) are not found here, so a body mention of "Board:" stays body.
function footerAnywhere(lines) {
  const fenced = [];
  let open = false;
  for (const l of lines) {  // a fence line and every line inside a fenced block are never footer lines
    const isFence = /^\s*(```|~~~)/.test(l);
    fenced.push(open || isFence);
    if (isFence) open = !open;
  }
  let found = null, i = 0;
  while (i < lines.length) {
    if (fenced[i] || footerLineKind(lines[i]) === "prose") { i++; continue; }
    let j = i, first = -1, writeup = false, board = false;
    for (; j < lines.length && !fenced[j] && footerLineKind(lines[j]) !== "prose"; j++) {
      const k = footerLineKind(lines[j]);
      if (k !== "strong" && k !== "weak") continue;
      if (first < 0) first = j;
      const lead = unboldLead(lines[j]);
      if (lead.startsWith("Write-up:")) writeup = true;
      else if (/^Board/.test(lead)) board = true;
    }
    let end = j;
    while (end > i && !lines[end - 1].trim()) end--;
    if (first >= 0 && writeup && board && end < lines.length && end < j) {
      let t = j;
      while (t < lines.length && !lines[t].trim()) t++;
      found = { start: first, end, tailStart: t };
    }
    i = j + 1;
  }
  return found && footerResult(lines, found.start, found.end, found.tailStart);
}
function splitFooter(text) {
  const src = String(text || "");
  const lines = src.split("\n");
  return footerAtEnd(lines) || footerAnywhere(lines) || { body: src, footer: null, notes: [], tail: "" };
}

// ── following a queued session start to its end (the New session and Quick session forms, app.js) ────────────────
// The form said "not in the list after four minutes" for a session that was live: the start had sat
// four minutes behind retires in sala's queue (one operation at a time) and then took 25 s. The form follows the operation to
// its end, which the queue's marker says (done, or stuck / cancelled / absorbed), and gives up only at a very long cap whose
// words say the start is still going, never that the session is missing.
const NS_POLL_MS = 3000, NS_POLL_SLOW_MS = 10000, NS_SLOW_AFTER_MS = 300000;   // every 3 s, every 10 s once it has been five minutes
const NS_POLL_MAX_MS = 1800000;                                                // the last resort: 30 minutes
const NS_DONE_GRACE_MS = 30000;   // the operation is done and the name is still not in the sessions list: Ready anyway after this
const NS_FAILED_OPS = ["stuck", "cancelled", "absorbed"];   // the queue's ended states that are not done (lib/op.sh THE MARKER)
const nsPollDelay = (ageMs) => (ageMs > NS_SLOW_AFTER_MS ? NS_POLL_SLOW_MS : NS_POLL_MS);
// what the queue's state says: "failed" (ended without a session), "done" (the spawn ended well), "starting" (running or
// waiting) or "queued"
function nsOpPhase(opState) {
  if (NS_FAILED_OPS.includes(opState)) return "failed";
  if (opState === "done") return "done";
  return ["running", "waiting"].includes(opState) ? "starting" : "queued";
}
// the form's step after one look: opState is the marker's state, listed whether the name is in the sessions list, ageMs since
// Start, doneMs since the look that first saw the operation done (0 when it has not). Returns the form's state:
// queued · starting · ready · failed · late
function nsVerdict(opState, listed, ageMs, doneMs) {
  if (listed) return "ready";
  const phase = nsOpPhase(opState);
  if (phase === "failed") return "failed";
  if (phase === "done" && doneMs >= NS_DONE_GRACE_MS) return "ready";
  if (ageMs > NS_POLL_MAX_MS) return "late";
  return phase === "done" ? "starting" : phase;
}
// the line under the headline while the start waits (no reload advice: the form's state is lost on a reload, and the operation
// goes on whatever the page does)
function nsWaitText(opState, behindLine) {
  if (nsOpPhase(opState) === "queued") return behindLine || "sala has the request and starts it within a few seconds.";
  return "sala is starting the session. The Open button appears here when it is ready.";
}
// the 30-minute cap: the start is not missing, it is still going
function nsLateText(opState) {
  const what = nsOpPhase(opState) === "queued" ? "queued" : "running";
  return `The start is still ${what} in sala's queue after 30 minutes. This page has stopped asking; sala posts the result in Slack when it ends.`;
}
