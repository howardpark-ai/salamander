"use strict";
/* The chat session's own layer: what draws that session's thread when sala's setting SALA_CHAT_LAYER is on (config.py chat_layer; the server puts this
   file and chatlayer.css in the page only then). It copies nothing of the session view. The header, the composer with its pending bubbles and its send,
   the drawing of a message (renderMessage, so replyNodes and linkCard), the scroll behaviour, the pinned "your move" strip and the sidebar entry are
   app.js's, as for every session, and so is the live block of a running "!" command (applyLive). app.js hands over in four places: chatSync (sync here) and the open stream's reset, append and status events.
   Answering a waiting item under a reply is chatanswer.js's: render() asks it what stands under each message.

   WHAT IS DRAWN is GET api/chat/thread?replies=1 (chatthread.py states the rule: the owner's messages and the replies to them, with a reply's sent files,
   asked questions and their answers, API error, interrupt and command output) and the page's own pending bubbles. No line of the stream is drawn as a
   message here. The session view has no drawing of a question, its answer or a sent file that is no image, so they are drawn here (OWN).

   A WAITING QUESTION is answered on the shared card under the thread (dialogcard.js). What the card carries of the open question is not drawn here a
   second time (fitAsks, onCard); the thread's own drawing, with a line that says how to answer, stands where no card does or the card cannot answer.

   STAYING LIVE needs no stream of its own: the session's stream already says when the transcript or the status changed. Each reset, append and status
   event asks for the newest page again (one read at a time, MIN_GAP_MS apart) and merges it by uuid into what is shown. The newest page is read, and not
   `after` a cursor: `after` gives the turns that START at or after its cursor, so a reply of a turn that was open at the last read would never come.
   A newest page that does not reach what is held (a long time away) is followed back with `before` until it does.

   THE WORKING MARK shows while the thread says `busy`. Beside its spinner is the first line of what the open turn wrote last (from the stream's appends),
   only when that line is in the language of the owner's last message (langOf); otherwise the spinner is alone.

   NO SIDEWAYS SCROLL: chatlayer.css wraps what can wrap, and a table that still does not fit its column is drawn row by row (fitTables).

   This file loads before app.js and needs nothing of app.js while it loads: every name of app.js is used inside a function app.js has called. */
window.SalaThreadLayer = (() => {
  const MIN_GAP_MS = 700, RETRY_MS = 2000, RETRY_MAX_MS = 30000, READ_TIMEOUT_MS = 30000;
  const LIVE_N = 40;        // messages a live read asks for: what changed is at the end
  const GAP_PAGES = 10;     // older pages followed to reach what is held, before what is held is let go
  const FOCUS_PAGES = 40;   // older pages read to reach the entry a Search result names
  const TURN_MAX = 200;
  const IN = "data-cl-in";  // on #chat while the thread is in, or its read failed: chatlayer.css shows the strip's rows only then
  const LOADING = '.empty[data-i18n="app.loadingTranscript"]';

  /* ---------- pure parts (held by web/tests/test_chat_layer.py in node) ---------- */
  const CODE_BLOCK = /```[\s\S]*?(```|$)/g;
  // "ko", "latin" or null, by words. Code and addresses say nothing about a language. Korean when three words in ten or more hold Hangul (Korean prose
  // keeps its English names); Latin when seven in ten or more are Latin ones; else (no letters, another script) null, which matches nothing
  function langOf(text) {
    const words = String(text || "").replace(CODE_BLOCK, " ").replace(/`[^`]*`/g, " ").replace(/\b[a-z][a-z0-9+.-]*:\/\/\S+/gi, " ")
      .split(/\s+/).filter((w) => /\p{L}/u.test(w));
    if (!words.length) return null;
    const hangul = words.filter((w) => /\p{Script=Hangul}/u.test(w)).length;
    if (hangul * 10 >= words.length * 3) return "ko";
    const latin = words.filter((w) => /\p{Script=Latin}/u.test(w) && !/\p{Script=Hangul}/u.test(w)).length;
    return latin * 10 >= words.length * 7 ? "latin" : null;
  }
  // the first line of a reply's markdown that says something, as plain words on one line
  function firstLine(text) {
    for (const raw of String(text || "").replace(CODE_BLOCK, "\n").split("\n")) {
      const line = raw.replace(/^\s*(?:#{1,6}|>|[-*+]|\d+\.)\s+/, "").replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1").replace(/\*\*|__|`/g, "")
        .replace(/\s+/g, " ").trim();
      if (/[\p{L}\p{N}]/u.test(line)) return [...line].slice(0, TURN_MAX).join("");
    }
    return "";
  }
  // `held` ({items, before, start}) joined with the newest messages (`page`, the same shape), by uuid. `before` and `start` are those of the oldest
  // message kept
  function mergePage(held, page) {
    const next = page.messages, whole = { items: next, before: page.before, start: page.start };
    const at = new Map(held.items.map((m, i) => [m.uuid, i]));
    const k = next.findIndex((m) => at.has(m.uuid));
    if (k < 0) {
      // a page with no message and more before it says nothing about what is held
      if (!next.length && !page.start && held.before !== null) return held;
      return whole;
    }
    const i = at.get(next[k].uuid);
    if (i < k || (i === k && page.start)) return whole;   // the page reaches as far back as what is held, or further
    return { items: held.items.slice(0, i - k).concat(next), before: held.before, start: held.start };
  }

  /* ---------- state ---------- */
  // one object per opened thread: a read that comes back for another one (`mine !== st`) is dropped
  const fresh = () => ({ name: null, gone: false, sid: null, items: [], before: null, start: false, loaded: false, busy: false, turn: null, ending: null,
    reading: false, again: false, soon: 0, retry: 0, delay: RETRY_MS, readAt: 0, failed: false,
    olderBusy: false, olderFailed: false, olderAt: 0, focusing: false, nodes: new Map() });
  let st = fresh();
  let ui = null;     // the layer's own elements and observers, made once
  // the selected session and its chat flag at the last sync. A copy of this file asked for again after its first request failed (index.html's first
  // script) runs after app.js: a thread open by then is drawn without the layer, so it counts as unflagged and the first sync opens it again
  let seen = typeof state !== "undefined" && state.selected ? { name: state.selected, chat: false } : null;

  const takes = (s) => !!s && s.chat === true && !isSleeping(s);   // a sleeping one is shown as sala shows every sleeper

  function clear() {
    clearTimeout(st.soon); clearTimeout(st.retry);
    if (ui) { ui.olderObs.disconnect(); for (const n of [ui.older, ui.fail, ui.mark]) n.remove(); }
    st = fresh();
    markIn(false);
  }
  // true when the mark changed: the strip's rows came or went
  function markIn(on) {
    const chat = $("#chat");
    if (chat.hasAttribute(IN) === on) return false;
    chat.toggleAttribute(IN, on);
    return true;
  }
  // called from chatSync: the selection or the list of sessions may have changed
  function sync() {
    const s = state.selected ? state.byName.get(state.selected) : null;
    if (!s && st.name !== null && st.name === state.selected) {
      // the open session left the list: sala keeps its thread on screen then, so it stays here too, under the layer's rules, and nothing more is read for it
      const { name } = st, marked = $("#chat").hasAttribute(IN);
      clear();
      st.name = name; st.gone = true;
      markIn(marked);
      return;
    }
    const flipped = !!(s && seen && seen.name === s.name && seen.chat !== (s.chat === true));
    seen = s ? { name: s.name, chat: s.chat === true } : null;
    const on = takes(s);
    document.body.classList.toggle("chat-layer", on);
    if (st.name !== null && (!on || st.name !== s.name)) clear();
    // the setting named this session, or stopped naming it, while it was open: opened again, so one view draws its thread from the start
    if (flipped && state.es) queueMicrotask(() => selectSession(s.name, { force: true }));
  }

  /* ---------- the stream's events, handed over by app.js ---------- */
  function reset(s, d, resumed) {
    const sid = d.session ? d.session.sessionId : null;
    if (!resumed || st.gone || st.name !== s.name || st.sid !== sid) {   // a fresh open, or another transcript (/clear); a reconnect keeps what is shown and the place
      clear();
      st.name = s.name; st.sid = sid;
      chatScroll.pinned = true; chatScroll.unseen = false;
    }
    wire();
    applyLive(null);    // a reset takes the live block with it, as in the session view: the stream sends it again while the command runs
    olderReset(null);   // the session view's paging of the whole transcript stays off here
    noteModel(d.messages);
    st.turn = null;
    track(d.messages);
    render();
    refresh();
  }
  function append(s, d) {
    if (st.name !== s.name) return;
    noteModel(d.messages);
    track(d.messages);
    // the output of a "!" command: its live block, named here by its title, goes when the output box is drawn (refresh)
    const block = $("#live-bang");
    if (block && d.messages.some(hasOutputBox)) st.ending = block.title;
    paintMark();
    soon();
  }
  const hasOutputBox = (m) => m.blocks.some((b) => b.kind === "bang_output");
  function status(s) {
    if (st.name === s.name) soon();
  }
  // the open turn's last written text: a message of the owner's, or a kept line (a turn something else started), ends it
  const NO_WORDS = ["tool_result", "notice", "bang_output"];   // a line of these alone is a call's or a command's output, not a message
  function track(msgs) {
    for (const m of msgs) {
      if (m.role === "kept" || (m.role === "user" && m.blocks.some((b) => !NO_WORDS.includes(b.kind)))) st.turn = null;
      else if (m.role === "assistant") {
        const text = m.blocks.filter((b) => b.kind === "text").map((b) => b.text).join("\n").trim();
        if (text) st.turn = { uuid: m.uuid, text };
      }
    }
  }

  /* ---------- reading the thread ---------- */
  async function read(name, query) {
    const url = "api/chat/thread" + query + (query ? "&" : "?") + "replies=1";
    const r = await fetch(url, { cache: "no-store", signal: AbortSignal.timeout(READ_TIMEOUT_MS) });
    if (!r.ok) throw new Error("HTTP " + r.status);
    const d = await r.json();
    if (!d || d.session !== name || !Array.isArray(d.messages)) throw new Error("not this session's thread");
    return { ...d, messages: d.messages.map((m) => (d.cards && d.cards[m.uuid] ? { ...m, cards: d.cards[m.uuid] } : m)) };
  }
  function soon() {
    if (st.reading) { st.again = true; return; }
    if (st.soon) return;
    const mine = st;
    mine.soon = setTimeout(() => { mine.soon = 0; if (mine === st) refresh(); }, Math.max(100, mine.readAt + MIN_GAP_MS - Date.now()));
  }
  async function refresh() {
    const mine = st;
    if (mine.name === null || mine.gone) return;
    if (mine.reading) { mine.again = true; return; }
    clearTimeout(mine.soon); mine.soon = 0; clearTimeout(mine.retry);
    mine.reading = true; mine.again = false; mine.readAt = Date.now();
    try {
      const page = await read(mine.name, mine.items.length ? "?n=" + LIVE_N : "");
      if (mine !== st) return;
      let messages = page.messages, back = page;
      const held = new Set(mine.items.map((m) => m.uuid));
      for (let i = 0; held.size && messages.length && !messages.some((m) => held.has(m.uuid)) && !back.start && i < GAP_PAGES; i++) {
        back = await read(mine.name, "?before=" + back.before);
        if (mine !== st) return;
        messages = back.messages.concat(messages);
      }
      const had = new Set(mine.items.map((m) => m.uuid)), first = !mine.loaded, last = mine.items.length ? mine.items[mine.items.length - 1].uuid : null;
      // an answer with no transcript behind it (the session just left sala's list) says nothing about what is held
      if (messages.length || page.offset || !mine.items.length) Object.assign(mine, mergePage(mine, { messages, before: back.before, start: !!back.start }));
      mine.busy = !!page.busy; mine.loaded = true; mine.failed = false; mine.delay = RETRY_MS;
      // the transcript's copy of a message takes its pending bubble's place
      for (const m of mine.items) if (ownWords(m) && !had.has(m.uuid)) { const p = matchPending(m, !first); if (p) dropPending(p); }
      const end = mine.items.length ? mine.items[mine.items.length - 1].uuid : null;
      if (!first && end !== last && !chatScroll.pinned) chatScroll.unseen = true;
      render();
      // the output box takes the live block's place, as in the session view; a block the next command has since taken stays
      const block = $("#live-bang");
      if (mine.ending !== null && mine.items.some((m) => !had.has(m.uuid) && hasOutputBox(m))) {
        if (block && block.title === mine.ending) applyLive(null);
        mine.ending = null;
      }
    } catch {
      if (mine !== st) return;
      mine.failed = true;
      render();
      mine.retry = setTimeout(() => { if (mine === st) refresh(); }, mine.delay);
      mine.delay = Math.min(mine.delay * 2, RETRY_MAX_MS);
    } finally {
      mine.reading = false;
    }
    if (mine !== st || mine.failed) return;
    if (mine.again) soon();
    settleFocus();
  }
  // the page before the oldest message held; false when none was added
  async function loadOlderThread() {
    const mine = st, asked = mine.before;
    if (mine.name === null || mine.gone || mine.olderBusy || mine.start || asked === null || state.tab !== "chat" || !pane().clientHeight) return false;
    mine.olderBusy = true; mine.olderFailed = false; mine.olderAt = Date.now();
    paintOlder();
    let page = null;
    try { page = await read(mine.name, "?before=" + asked); } catch { /* shown below */ }
    if (mine !== st) return false;
    mine.olderBusy = false;
    if (!page || !Number.isInteger(page.before)) { mine.olderFailed = true; paintOlder(); return false; }
    if (mine.before !== asked) { paintOlder(); return false; }   // a read of the newest page replaced what is held meanwhile
    const have = new Set(mine.items.map((m) => m.uuid));
    mine.items = page.messages.filter((m) => !have.has(m.uuid)).concat(mine.items);
    mine.before = page.before; mine.start = !!page.start || page.before === 0;
    render();
    return true;
  }
  const olderInReach = () => !!ui && ui.older.isConnected && state.tab === "chat" && !!pane().clientHeight
    && ui.older.getBoundingClientRect().bottom > pane().getBoundingClientRect().top - OLDER_MARGIN;
  // a Search result opened this chat at an entry (app.js openAt): older pages until it is here, then the view's own scroll and light
  async function settleFocus() {
    const mine = st, f = state.focusAt;
    if (!f || f.name !== mine.name || !mine.loaded || mine.focusing) return;
    mine.focusing = true;
    const here = () => mine.items.some((m) => m.uuid === f.uuid);
    for (let i = 0; i < FOCUS_PAGES && !here() && f.session === mine.sid && Number.isInteger(f.pos) && !mine.start && mine.before > f.pos; i++) {
      const added = await loadOlderThread();
      if (mine !== st) return;
      if (!added) break;
    }
    mine.focusing = false;
    state.focusAt = f;
    focusEntry($("#chat"));
  }

  /* ---------- drawing ---------- */
  // a question of an AskUserQuestion call, its options numbered as the session's dialog numbers them; words as written, links tappable
  function askedNode(q) {
    const part = (tag, cls, text) => (text ? el(tag, { class: cls }, ...linkNodes(text)) : null);
    return el("div", { class: "cl-ask" }, part("div", "cl-ask-head", q.header), part("div", "cl-ask-q", q.question),
      q.multiSelect ? el("div", { class: "cl-ask-multi", ...tx("chat.ask.multi") }) : null,
      el("ol", { class: "cl-ask-opts" }, ...q.options.map((o) => el("li", {}, part("div", "cl-ask-label", o.label),
        part("div", "cl-ask-desc", o.description), part("pre", "cl-ask-preview", o.preview)))));
  }
  // what a question was answered with, each after its question, as a message on the owner's side
  function answeredNode(b) {
    return el("div", { class: "bubble cl-answer" }, ...b.answers.map((a) => el("div", { class: "cl-answer-one" },
      el("div", { class: "cl-answer-q" }, ...linkNodes(a.question)), el("div", {}, ...linkNodes(a.answer)))));
  }
  // a file a reply sent that is no image: its name and the caption written with it (no route serves the file itself)
  function fileNode(b) {
    return el("div", { class: "cl-file" }, el("div", { class: "sent-file" }, fileIcon(), el("span", { class: "sf-name", text: b.name })),
      b.caption ? el("div", { class: "cl-file-cap" }, ...linkNodes(b.caption)) : null);
  }
  const OWN = { question: askedNode, answer: answeredNode, file_sent: fileNode };   // the blocks renderMessage draws nothing for
  // a message's node, drawn by the session view's own renderMessage and kept while the message is unchanged
  function nodeOf(m) {
    const sig = JSON.stringify(m), have = st.nodes.get(m.uuid);
    if (have && have.sig === sig) return have.node;
    const frag = document.createDocumentFragment();
    renderMessage(m, { into: frag, older: true });
    let node = frag.firstElementChild;
    const own = m.blocks.filter((b) => OWN[b.kind]);
    if (own.length) {
      if (!node) node = el("div", { class: "msg " + m.role, "data-uuid": m.uuid });   // renderMessage draws nothing for these alone
      node.append(...own.map((b) => OWN[b.kind](b)));
      const questions = own.filter((b) => b.kind === "question");
      if (questions.length) {
        // how to answer: chatlayer.css shows it while no message of the thread follows the question; fitAsks words it
        const how = el("div", { class: "cl-ask-how", ...tx(howKey(questions)) });
        node.clAsks = { questions, nodes: [...node.querySelectorAll(":scope > .cl-ask")], how };
        node.append(how);
      }
    }
    st.nodes.set(m.uuid, { sig, node });
    return node;
  }
  /* ---------- the open question and the card that answers it ---------- */
  // words alone: the pane breaks its lines anywhere and shows markdown's marks as styles
  const bare = (t) => String(t || "").replace(/[\s*`]+/g, "");
  // true when the shared card (dialogcard.js) shows this question and its buttons can answer it. Every other case keeps the thread's own drawing, so
  // nothing the owner needs for an answer goes out of sight
  function onCard(q, card) {
    if (!card || !bare(q.question) || !bare(card.title).includes(bare(q.question))) return false;
    const opts = card.options;
    // the review that ends a call of several questions: it lists each answered question, and its two buttons send or cancel them
    if (card.kind === "choice" && opts.length === 2 && opts[0].label === "Submit answers") return true;
    // the card draws no preview, and in the pane's dialog that shows previews a number only moves the focus
    if (q.options.some((o) => o.preview)) return false;
    // a question of several answers that is not its call's last is read as one of a single answer, with no button that moves past it
    if (card.kind !== (q.multiSelect ? "multi" : "choice")) return false;
    return q.options.every((o, i) => {
      if (!opts[i]) return false;
      const shown = bare(opts[i].label + opts[i].description);
      return shown.startsWith(bare(o.label)) && shown.includes(bare(o.description));
    });
  }
  // the how-to line while the card has said nothing: a number sent from the composer picks an option, except where one number is no answer
  const howKey = (questions) => (questions.some((q) => q.multiSelect || q.options.some((o) => o.preview)) ? "chat.ask.howMulti" : "chat.ask.how");
  // The open question (no message of the thread follows it): what the card carries of it is not drawn a second time, and a message with nothing else to
  // show is hidden whole. Its how-to line shows only while the card carries none of its questions; once the server has said what the pane shows and
  // that is not this question, the line names the Terminal tab alone. True when anything changed
  function fitAsks() {
    const card = window.SalaQuestionCard ? SalaQuestionCard.standing() : undefined;
    const all = [...$("#chat").querySelectorAll(":scope > .msg:not(.local)")], open = all[all.length - 1];
    let changed = false;
    const hide = (n, on) => { if (n.hidden !== on) { n.hidden = on; changed = true; } };
    for (const n of all) {
      if (!n.clAsks) continue;
      const { questions, nodes, how } = n.clAsks;
      const carried = questions.map((q) => n === open && onCard(q, card));
      nodes.forEach((node, i) => hide(node, carried[i]));
      const key = n === open && card !== undefined ? "chat.ask.howTerm" : howKey(questions);
      if (how.dataset.i18n !== key) { how.dataset.i18n = key; how.textContent = tl(key); changed = true; }
      hide(how, carried.includes(true));
      hide(n, carried.every(Boolean) && [...n.children].every((c) => c === how || nodes.includes(c)));
    }
    return changed;
  }
  // the card came, went or changed: the open question is fitted to it, the view's place kept
  function cardChanged() {
    if (st.name === null || !ui) return;
    const keep = !chatScroll.pinned && state.tab === "chat" ? scrollAnchor() : null;
    if (!fitAsks()) return;
    if (chatScroll.pinned) { if (state.tab === "chat") scrollToBottom(); }
    else if (keep) restoreAnchor(keep);
    updateJump();
  }

  // #chat holds `want`, in order; only what differs is touched. The session view's own spinner (hidden by chatlayer.css) and its live block of a running
  // "!" command stay, under what is drawn. True when anything moved
  function place(chat, want) {
    const keep = new Set(want);
    let changed = false;
    for (const n of [...chat.children]) if (!keep.has(n) && !n.matches(".inflight, .live-bang, .q-card")) { n.remove(); changed = true; }
    let at = chat.firstElementChild;
    for (const n of want) {
      if (n === at) { at = at.nextElementSibling; continue; }
      chat.insertBefore(n, at);
      changed = true;
    }
    return changed;
  }
  function emptyLine(key) {
    if (!ui.empty.has(key)) ui.empty.set(key, el("div", { class: "empty", ...tx(key) }));
    return ui.empty.get(key);
  }
  function render() {
    if (st.name === null || !ui) return;
    const chat = $("#chat"), pinned = chatScroll.pinned;
    const keep = !pinned && state.tab === "chat" ? scrollAnchor() : null;
    const pending = state.pending.filter((p) => p.session === st.name && p.node).map((p) => p.node);
    const drawn = st.items.map((m) => [m, nodeOf(m)]).filter(([, node]) => node);
    // what the answer frames' part (chatanswer.js) puts under a reply that names a waiting item: elements of their own, after the message's
    const under = window.SalaAnswerFrame ? SalaAnswerFrame.thread(drawn.map(([m]) => m), redraw) : null;
    const messages = drawn.flatMap(([m, node]) => [node, ...((under && under.get(m.uuid)) || [])]);
    const paged = st.loaded && st.before !== null && (messages.length > 0 || !st.start);
    const want = [...(paged ? [ui.older] : []), ...messages];
    if (!messages.length && !pending.length && !st.failed) {
      if (!st.loaded) want.push(emptyLine("app.loadingTranscript"));
      else if (st.start) want.push(emptyLine("app.noMessages"));
    }
    if (st.failed) want.push(ui.fail);
    want.push(...pending);
    if (st.busy) want.push(ui.mark);
    const marked = markIn(st.loaded || st.failed);   // before the scroll below, which then counts the strip's height
    paintOlder();
    paintMark();
    const moved = place(chat, want), fitted = fitAsks();
    if (moved || fitted || marked) {
      if (pinned) { if (state.tab === "chat") scrollToBottom(); }
      else if (keep) restoreAnchor(keep);
    }
    fitTables();
    updateJump();
    ui.olderObs.disconnect();
    if (paged && !st.start && !st.olderFailed) {
      ui.olderObs.observe(ui.older);
      const mine = st;
      requestAnimationFrame(() => { if (mine === st && !mine.olderFailed && olderInReach()) loadOlderThread(); });   // a short page: the next one too
    }
  }
  // the answer frames' part is handed this, and calls it when the items it knows change: the thread drawn again, once it is in and while app.js has no loading line there
  function redraw() {
    const chat = $("#chat");
    if (st.loaded && !st.gone && chat.hasAttribute(IN) && !chat.querySelector(":scope > " + LOADING)) render();
  }
  function paintOlder() {
    if (!ui) return;
    ui.older.textContent = st.olderBusy ? tl("app.older.loading") : st.start ? tl("app.older.start") : st.olderFailed ? tl("app.older.failed") : "";
    ui.older.classList.toggle("at-start", st.start && !st.olderBusy);
  }
  // a message the owner wrote: the interrupt line, a command's output and a question's answer stand on their side of the thread and are none
  const ownWords = (m) => m.role === "user" && !m.interrupt && !m.output && !m.answer;
  // the owner's last message: the one still on its way, else the newest in the thread
  function ownerLast() {
    const sent = state.pending.filter((p) => p.session === st.name && p.status !== "failed" && p.status !== "held");
    if (sent.length) return sent[sent.length - 1].text;
    for (let i = st.items.length - 1; i >= 0; i--) {
      if (ownWords(st.items[i])) return st.items[i].blocks.filter((b) => b.kind === "text").map((b) => b.text).join("\n");
    }
    return "";
  }
  function turnLine() {
    const t = st.turn;
    if (!st.busy || !t || st.items.some((m) => m.uuid === t.uuid)) return "";   // a reply that is in the thread is read there
    const line = firstLine(t.text), lang = langOf(line);
    return lang && lang === langOf(ownerLast()) ? line : "";
  }
  function paintMark() {
    if (!ui) return;
    const line = turnLine();
    if (ui.turn.textContent !== line) ui.turn.textContent = line;
    ui.turn.hidden = !line;
  }
  // a table that does not fit its column is drawn row by row, each cell after its column's heading
  function fitTables() {
    const tables = [...$("#chat").querySelectorAll(".md table")];
    for (const t of tables) {
      const room = t.parentElement.clientWidth;
      if (!room || t.clRoom === room) continue;   // hidden (measured when it shows), or measured at this width
      t.clRoom = room;
      t.classList.remove("cl-stacked", "cl-labelled");
      if (t.getBoundingClientRect().width <= room + 0.5) continue;
      const head = t.tHead && t.tHead.rows[0] ? [...t.tHead.rows[0].cells].map((c) => c.textContent.trim()) : [];
      const rows = [...t.tBodies].flatMap((b) => [...b.rows]);
      for (const r of rows) [...r.cells].forEach((c, i) => { if (head[i]) c.dataset.label = head[i]; });
      t.classList.add("cl-stacked");
      t.classList.toggle("cl-labelled", head.length > 0 && rows.length > 0);
    }
  }
  function fitSoon() {
    if (ui.fitting || st.name === null) return;
    ui.fitting = true;
    requestAnimationFrame(() => { ui.fitting = false; if (st.name !== null) fitTables(); });
  }
  function remeasure(tables) {
    for (const t of tables) t.clRoom = 0;
    fitSoon();
  }

  function wire() {
    if (ui) return;
    const chat = $("#chat");
    ui = {
      older: el("div", { class: "cl-older", role: "status", "aria-live": "polite" }),
      fail: el("div", { class: "cl-fail", role: "status" }, el("span", tx("app.newer.failed")),
        el("button", { type: "button", ...tx("app.pend.retry"), onclick: () => refresh() })),
      turn: el("span", { class: "cl-turn", hidden: true }),
      empty: new Map(),
      fitting: false,
      olderObs: new IntersectionObserver((es) => { if (es.some((e) => e.isIntersecting) && !st.olderFailed) loadOlderThread(); },
        { root: pane(), rootMargin: `${OLDER_MARGIN}px 0px 0px 0px` }),
    };
    ui.mark = el("div", { class: "cl-mark", role: "status", ...tx("app.working", null, "title"), ...tx("app.working", null, "aria-label") },
      el("span", { class: "spinner" }), ui.turn);
    // a bubble the composer's send adds goes above the working mark, and may change the language the mark is held against
    new MutationObserver((records) => {
      if (st.name === null) return;
      // app.js putting its loading line here (the open session opened once more): not in again, also when a message sent right then takes the line away
      if (records.some((r) => [...r.addedNodes].some((n) => n.nodeType === 1 && n.matches(LOADING)))) markIn(false);
      if (ui.mark.parentNode !== chat) return;
      for (let n = ui.mark.nextElementSibling; n; n = n.nextElementSibling) {
        if (n.classList.contains("msg")) { chat.append(ui.mark); break; }
      }
      paintMark();
    }).observe(chat, { childList: true });
    new ResizeObserver(fitSoon).observe(chat);
    document.addEventListener("sala:question-card", cardChanged);
    chat.addEventListener("load", (e) => { const t = e.target.closest && e.target.closest(".md table"); if (t) remeasure([t]); }, true);   // an image in a cell
    if (document.fonts) document.fonts.addEventListener("loadingdone", () => remeasure(chat.querySelectorAll(".md table")));
    // the words of a failed read ask for a scroll: up for older messages, down for newer ones
    pane().addEventListener("scroll", () => {
      if (st.name === null) return;
      if (st.olderFailed && olderInReach() && Date.now() - st.olderAt > RETRY_MS) loadOlderThread();
      else if (st.failed && distFromBottom() < NEAR_BOTTOM && Date.now() - st.readAt > RETRY_MS) refresh();
    }, { passive: true });
    SalaI18n.onChange(paintOlder);   // every other word of the layer is rewritten by its data-i18n attribute
  }

  return { takes, sync, reset, append, status, refresh, langOf, firstLine, mergePage, onCard };
})();
