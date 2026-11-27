"use strict";
/* Answering an item that waits on the owner from the chat session's page: the board's own frame, in the strip's row of the item (opened by a tap) and
   under the reply that marks it (a line `[card: <id>]`, see markers()). The page draws the item's id, title and link; the frame draws the question, its choices and Send, and sends them
   to the board itself. Nothing here writes anything. The server puts this file and chatanswer.css in the page with the chat session's layer
   (SALA_CHAT_LAYER). app.js calls strip() in place of drawing the first list's rows itself; chatlayer.js asks thread() what stands under each reply, and
   hands it the redraw to call when the known items change. Neither part needs the other: with one of them absent the other works as it does.

   WHICH ITEMS. A row of the first list with an id and the address of a board item's page (.../items/<n>). Its frame is <that page>/answer-frame, and its
   messages are taken from that address's origin alone. The list does not say whether an item has anything to pick: the frame does (`closed`), and the row
   or card is then the plain title link.

   A FRAME IS NEVER MOVED OR MADE AGAIN BY A REDRAW (a browser reloads a frame whose element is moved in the page). A row that holds one stays where it is
   in the document: the others are put around it, and the style `order` gives what is seen. A card stands after its message as an element of its own. A strip
   row's frame is made at the row's first opening and then kept, hidden while the row is closed.

   CARDS ARE ASKED FOR. A card stands only where an assistant reply has a marker line of its own, `[card: <id>]` or `[card: [<label>](<item url>)]`,
   outside code and quotes (markers()); the marker lines are then taken out of the reply's text (hideMarks()). Several markers give several cards in the
   order written.

   ONE CARD AN ITEM. An item has one card in the whole thread, under the newest reply that marks it. An earlier card goes, with its frame, as soon as the
   newer one is made. A frame in the middle of sending is never cut: its card is kept, not shown, until the frame says something else. A card is only for an
   item on the first list. An item that leaves the list takes its card away, with its frame, except a card whose own frame reported `sending` in this page
   session (the owner sent the answer from it): that one stays, as his receipt, and is the item's one card. No card is ever made for an item that is not on
   the list.

   MESSAGES are taken only from the window of a frame made here (held in `frames`, never looked up by a selector a reply's markup could answer) and from
   that frame's origin, and only in the board's own shape (read()). Every message to a frame names its origin.

   WITH THE KEYBOARD UP (the composer has the focus and the visible height is short, or a strip frame says a person types in it) and a row open, the list
   takes the pane but THREAD px, which the thread keeps (chatanswer.css, body.ans-kbd). */
window.SalaAnswerFrame = (() => {
  const timing = { silent: 8000, again: 10000 };   // ms: no message by then shows the plain link; the least time between two reloads for a changed question
  const FIRST = 160, LOW = 40, HIGH = 2000;        // a frame's height before it says one, and the range a said one is held to
  const THREAD = 72;                               // about three lines
  const STATES = new Set(["open", "sending", "answered", "changed", "closed", "signed_out"]);
  const ASKS = new Set(["open", "sending", "changed"]);   // the states of a frame that has shown a question
  const LINES = { answered: "chat.answer.answered", sending: "chat.answer.sending", changed: "chat.answer.changed" };

  /* ---------- pure parts (held by web/tests/test_chat_answer.py in node) ---------- */
  // the frame of an item: from the address of its page on a web server (.../items/<n>); null for any other address
  function address(url) {
    let u;
    try { u = new URL(String(url || "")); } catch { return null; }
    const m = /^(.*\/items\/([^/]+))\/*$/.exec(u.pathname);
    if (!m || (u.protocol !== "https:" && u.protocol !== "http:")) return null;
    let item = m[2];
    try { item = decodeURIComponent(item); } catch { /* as written */ }
    return { origin: u.origin, item, page: u.origin + m[1] };
  }
  // the marker lines of a reply, in order: {i: the line's index, id} or {i, url}. A marker is a line of its own (up to three spaces in), outside a fenced
  // block; a line in a quote, a list or an inline code span, or a marker with a letter missing, is not one. A line that is still being written is not one either
  const FENCE = /^ {0,3}(`{3,}|~{3,})(.*)$/, MARK = /^ {0,3}\[card: (?:\[[^\]\n]*\]\((https?:\/\/[^\s)]+)\)|([^\s[\]()`]+))\]\s*$/;
  function markers(text) {
    const out = [];
    let fence = null;
    String(text || "").split("\n").forEach((line, i) => {
      const f = FENCE.exec(line);
      if (fence) { if (f && f[1][0] === fence[0] && f[1].length >= fence.length && !f[2].trim()) fence = null; return; }
      if (f) { fence = f[1]; return; }
      const m = MARK.exec(line);
      if (m) out.push({ i, url: m[1] || null, id: m[2] || null });
    });
    return out;
  }
  // the reply's text with its marker lines taken out (what the page shows; the stored text keeps them)
  function hideMarks(text) {
    const gone = new Set(markers(text).map((k) => k.i));
    return String(text || "").split("\n").filter((_, i) => !gone.has(i)).join("\n");
  }
  // what a message from the frame of `item` says, or null when it is not one
  function read(d, item) {
    if (!d || typeof d !== "object" || d.source !== "stackshot" || d.kind !== "answer-frame" || d.v !== 1 || d.item !== item || !STATES.has(d.state)) return null;
    const height = Number.isFinite(d.height) && d.height > 0 ? Math.min(HIGH, Math.max(LOW, Math.ceil(d.height))) : null;
    return { state: d.state, height, typing: d.typing === true };
  }

  /* ---------- state ---------- */
  const items = new Map();    // id -> {id, subject, url, at, listed, state, row}
  const cards = new Map();    // "<message uuid>\n<id>" -> a card under a reply: {it, node, title, line, slot, newest, box, seq, sent}; sent: its frame once said "sending"
  const frames = new Map();   // iframe element -> its box: the only frames that are listened to
  let openId = null, made = 0, redraw = null, ui = null;

  const theme = () => {
    const t = document.documentElement.getAttribute("data-theme");
    return (t ? t === "light" : matchMedia("(prefers-color-scheme: light)").matches) ? "light" : "dark";
  };
  const source = (it) => it.at.page + "/answer-frame?lang=" + SalaI18n.lang + "&theme=" + theme();

  /* ---------- frames ---------- */
  function make(it) {
    // no scrollbar inside the frame: the frame is as tall as its page says. A scrollbar there would take room from the page, whose words then wrap into a
    // taller page; given that height the bar goes, the page is short again, and where the bar comes back the two heights take turns with no end
    const frame = el("iframe", { class: "ans-frame", scrolling: "no", ...tx("chat.answer.frame", { id: it.id }, "title") });
    frame.style.height = FIRST + "px";
    frame.setAttribute("src", source(it));
    frame.style.visibility = "hidden";   // until its first report: the board's own content (an old answer, say) is not seen; the frame still loads and runs
    const box = { it, frame, origin: it.at.origin, item: it.at.item, theme: theme(), reported: false, silent: false, typing: false,
      timer: 0, reloaded: false, reloadedAt: 0, state: "", asked: false, quiet: false };   // state: its last word; asked: it has shown a question; quiet: that word is an answer it never asked
    frames.set(frame, box);
    arm(box);
    return box;
  }
  function arm(box) {
    clearTimeout(box.timer);
    box.timer = setTimeout(() => {
      if (frames.get(box.frame) !== box || box.reported) return;
      box.silent = true;
      repaint(box.it);
    }, timing.silent);
  }
  function drop(box) {
    if (!box) return;
    clearTimeout(box.timer);
    frames.delete(box.frame);
    box.frame.remove();
  }
  // only to a frame that has spoken: before that its window may hold no page of the board's yet, and a page that loads reads the address's own words
  function post(box, words) {
    if (box.reported && box.frame.contentWindow) box.frame.contentWindow.postMessage({ source: "sala", kind: "answer-frame", v: 1, ...words }, box.origin);
  }
  const boxesOf = (it) => [...frames.values()].filter((b) => b.it === it);
  const refresh = (it) => { for (const b of boxesOf(it)) post(b, { do: "refresh" }); };
  function retheme() {
    const t = theme();
    for (const b of frames.values()) if (b.reported && b.theme !== t) { b.theme = t; post(b, { do: "theme", theme: t }); }
  }
  // the same frame element loads the new question; replace() adds nothing to the page's history
  function reload(box) {
    Object.assign(box, { reloaded: true, reloadedAt: Date.now(), reported: false, typing: false, theme: theme() });
    arm(box);
    box.frame.contentWindow.location.replace(source(box.it));
  }
  function onMessage(e) {
    if (!e.source) return;
    const box = [...frames.values()].find((b) => b.frame.contentWindow === e.source);
    if (!box || e.origin !== box.origin) return;
    const m = read(e.data, box.item);
    if (!m) return;
    clearTimeout(box.timer);
    Object.assign(box, { reported: true, silent: false, typing: m.typing, state: m.state });
    box.frame.style.visibility = "";
    // a frame that never showed a question does not make its answer the item's: an answer to an old question is not one to show. Its card and row are plain
    if (ASKS.has(m.state)) box.asked = true;
    box.quiet = m.state === "answered" && !box.asked;
    // the owner sent the answer from a card: that card stays when its item leaves the list
    if (m.state === "sending") { const card = [...cards.values()].find((c) => c.box === box); if (card) card.sent = true; }
    if (!box.quiet) box.it.state = m.state;
    // a quiet answer shows the item plain where nothing has been asked: the rows too. An item that has an answer or a question keeps it
    else if (["", "closed", "signed_out"].includes(box.it.state)) box.it.state = "closed";
    repaint(box.it);
    if (!frames.has(box.frame)) return;   // an earlier card whose send is over: it went in the repaint, with this frame
    if (m.height) keepPlace(box.frame, () => {
      box.frame.style.height = m.height + "px";
      box.frame.setAttribute("scrolling", e.data.height > HIGH ? "auto" : "no");   // a page taller than a frame is held to scrolls inside it
    });
    retheme();
    // a changed question is read again once: not again until the frame has said something else, and never twice in a short time
    if (m.state !== "changed") box.reloaded = false;
    else if (!box.reloaded && Date.now() - box.reloadedAt >= timing.again) reload(box);
  }

  /* ---------- drawing ---------- */
  // the pane keeps its place while something in it grows or shrinks: at the thread's end it stays there, and what is above the reader moves nothing
  function keepPlace(node, change) {
    if (state.tab !== "chat" || !pane().contains(node)) { change(); return; }
    const pinned = chatScroll.pinned;
    const at = !pinned && $("#chat").contains(node) && node.getBoundingClientRect().bottom <= pane().getBoundingClientRect().top ? scrollAnchor() : null;
    change();
    if (pinned) scrollToBottom(); else if (at) restoreAnchor(at);
    updateJump();
  }
  // every place of an item shows the last state any of its frames said (a shut row's frame need not say it again); silence is each frame's own
  // nothing to pick, or no frame to show (`box`, this place's own, is silent or quiet): the title link, as with no frame at all
  const plain = (it, box) => it.state === "closed" || !!(box && (box.silent || box.quiet));
  function say(node, key) {
    node.hidden = !key;
    if (key) node.setAttribute("data-i18n", key); else node.removeAttribute("data-i18n");
    node.textContent = key ? tl(key) : "";
  }
  const link = (cls, url, extra) => el("a", { class: cls, href: url, target: "_blank", rel: "noopener noreferrer", ...extra });

  function paintRow(it) {
    const r = it.row;
    if (!r) return;
    const s = it.state, off = plain(it, r.box), open = openId === it.id && !off;
    r.li.classList.toggle("ans-plain", off);
    r.li.classList.toggle("ans-open", open);
    r.li.classList.toggle("ans-done", s === "answered" && !(r.box && r.box.quiet));
    r.head.setAttribute("aria-expanded", String(open));
    r.body.hidden = openId !== it.id;
    say(r.line, off ? null : s === "changed" || !open ? LINES[s] : null);   // an open row's frame says the rest itself
    r.line.classList.toggle("ans-ok", s === "answered");
  }
  const cardsOf = (it) => [...cards.values()].filter((c) => c.it === it);
  const newestOf = (it) => cardsOf(it).find((c) => c.newest);
  const sending = (c) => !!(c.box && c.box.state === "sending");
  function removeCard(key, c) {
    drop(c.box);
    c.node.remove();
    cards.delete(key);
  }
  function paintCard(c) {
    const it = c.it, s = it.state, off = plain(it, c.box);
    c.node.classList.toggle("ans-newest", c.newest);   // a card without it is an earlier one still sending: not shown (chatanswer.css)
    c.node.classList.toggle("ans-plain", off);
    c.node.classList.toggle("ans-done", s === "answered" && !(c.box && c.box.quiet));
    const words = it.id + "\n" + it.subject + "\n" + it.url;
    if (c.words !== words) {
      c.words = words;
      c.title.replaceChildren(...(it.subject ? [el("span", { class: "wait-id", text: it.id })] : []), link("wait-link", it.url, { text: it.subject || it.id }));
    }
    say(c.line, !off && s === "changed" ? LINES.changed : null);
  }
  // an earlier card is here only while its frame is sending (thread()): once that is over it goes
  function settle(it) {
    if (!newestOf(it)) return;   // the thread is about to be drawn again, which says which card is the item's
    for (const [key, c] of cards) if (c.it === it && !c.newest && !sending(c)) removeCard(key, c);
  }
  // something about the item changed: every place of it is painted
  function repaint(it) {
    settle(it);
    if (it.row) keepPlace(it.row.li, () => paintRow(it));
    for (const c of cardsOf(it)) keepPlace(c.node, () => paintCard(c));
    layoutSoon();
  }

  /* ---------- the strip's rows ---------- */
  function buildRow(it, li) {
    const name = el("span", { class: "ans-name" });
    const head = el("button", { type: "button", class: "ans-head", "aria-expanded": "false" }, name, el("span", { class: "chev", "aria-hidden": "true" }));
    const line = el("p", { class: "ans-line", hidden: true }), slot = el("div", { class: "ans-slot" });
    const board = link("ans-board", it.url, tx("chat.answer.open"));
    const body = el("div", { class: "ans-body", hidden: true }, slot, el("p", { class: "ans-more" }, board));
    li.classList.add("ans");
    li.append(el("div", { class: "ans-card" }, head, line, body));
    head.addEventListener("click", () => toggle(it));
    return { li, head, name, line, slot, board, body, box: null, words: null };
  }
  // the row's words, from a row app.js just drew: its plain form (shown when there is nothing to pick) and the same words in the button, with no link
  function fillRow(it, fresh, words) {
    const r = it.row, subject = fresh.querySelector(":scope > .wait-subj");
    r.name.replaceChildren(...[...subject.childNodes].map((n) => (n.nodeName === "A" ? el("span", { class: "wait-title", text: n.textContent }) : n.cloneNode(true))));
    if (fresh !== r.li) r.li.querySelector(":scope > .wait-subj").replaceWith(subject);
    r.board.setAttribute("href", it.url);
    r.words = words;
  }
  function reveal(li) {
    const box = li.closest(".wait");
    if (!box) return;
    const over = li.getBoundingClientRect().top - box.getBoundingClientRect().top;
    if (over < 0 || li.getBoundingClientRect().bottom > box.getBoundingClientRect().bottom) box.scrollTop += over;
  }
  // one row is open at a time; closing one hides its frame and keeps it
  function toggle(it) {
    openId = openId === it.id ? null : it.id;
    const r = it.row;
    if (openId === it.id && !r.box) { r.box = make(it); r.slot.append(r.box.frame); }
    for (const o of items.values()) {
      if (!o.row) continue;
      if (o.id !== openId && o.row.box) o.row.box.typing = false;
      keepPlace(o.row.li, () => paintRow(o));
    }
    if (openId === it.id) reveal(r.li);
    layoutSoon();
  }
  function dropRow(it) {
    if (!it.row) return;
    drop(it.row.box);
    it.row.li.remove();
    it.row = null;
    if (openId === it.id) openId = null;
  }
  function forget(it) {
    dropRow(it);
    for (const [key, c] of cards) if (c.it === it) removeCard(key, c);
    items.delete(it.id);
  }
  // the items of a list read; true when a reply may stand differently (an item new here, back, or worded anew)
  function learn(waiting) {
    let news = false;
    const listed = new Set();
    for (const w of waiting) {
      const at = w.id ? address(w.url) : null;
      if (!at) continue;
      listed.add(w.id);
      let it = items.get(w.id);
      if (it && it.at.page !== at.page) { forget(it); it = null; }   // another page of the board: nothing of the old frame holds for it
      if (!it) {
        items.set(w.id, { id: w.id, subject: w.subject || "", url: w.url, at, listed: true, state: "", row: null });
        news = true;
      } else if (!it.listed || it.subject !== (w.subject || "") || it.url !== w.url) {
        Object.assign(it, { subject: w.subject || "", url: w.url, listed: true });
        news = true;
        refresh(it);
      }
    }
    // an item that left the list: its row goes, as every row does, and its cards go with their frames, except one the owner sent from in this page session (his
    // receipt), whose frame is told to read the item again
    for (const it of items.values()) if (it.listed && !listed.has(it.id)) {
      it.listed = false;
      dropRow(it);
      for (const [key, c] of cards) if (c.it === it && !c.sent) removeCard(key, c);
      refresh(it);
      news = true;
    }
    return news;
  }
  /* app.js hands over the first list (`list`) with what the last read holds (`waiting`) and its own row maker. A row that cannot be answered is that row. */
  function strip(list, waiting, makeRow) {
    wire();
    const news = learn(waiting), want = [];
    for (const w of waiting) {
      const fresh = makeRow(w), it = w.id && address(w.url) ? items.get(w.id) : null;
      if (!it) { want.push(fresh); continue; }
      const words = fresh.innerHTML;
      if (!it.row) it.row = buildRow(it, fresh);
      if (it.row.words !== words) fillRow(it, fresh, words);
      if (!want.includes(it.row.li)) want.push(it.row.li);
    }
    const keep = new Set(want), held = new Set([...items.values()].filter((it) => it.row && it.row.box).map((it) => it.row.li));
    for (const n of [...list.children]) if (!keep.has(n)) n.remove();
    // from the end: every row but one that holds a frame is put before the row that follows it. A list with no row to answer is left as app.js would draw it
    const answers = want.some((n) => n.classList.contains("ans"));
    for (let i = want.length - 1, next = null; i >= 0; next = want[i], i--) {
      const n = want[i];
      if (n.parentNode !== list || (!held.has(n) && n.nextElementSibling !== next)) list.insertBefore(n, next);
      if (answers) n.style.order = String(i);
    }
    list.classList.toggle("ans-list", answers);
    for (const it of items.values()) repaint(it);
    if (news && redraw) redraw();
  }

  /* ---------- under the replies ---------- */
  /* chatlayer.js draws these messages: for each reply that has a card, the elements that stand after it (uuid -> [element]). An item's card is under the
     newest reply that marks it; no other reply has anything of it, but for a card still sending, kept unseen where it was. */
  // a marker names its item by the id, or by the address of the item's page (an id need not be the last part of that address)
  const markedItem = (k) => {
    if (!k.url) return items.get(k.id) || null;
    const at = address(k.url), same = at ? [...items.values()].filter((it) => it.at.page === at.page) : [];
    return same.find((it) => it.listed) || same[0] || null;
  };
  function thread(messages, again) {
    redraw = again;
    for (const [key, c] of cards) if (!c.node.isConnected) removeCard(key, c);   // the thread was taken down (another session, another conversation)
    const found = [], newest = new Map();
    for (const m of items.size ? messages : []) {
      if (m.role !== "assistant") continue;
      const text = m.blocks.filter((b) => b.kind === "text").map((b) => b.text).join("\n"), done = new Set();
      for (const k of markers(text)) {
        const it = markedItem(k), c = it && cards.get(m.uuid + "\n" + it.id);
        if (!it || done.has(it) || (!it.listed && !(c && c.sent))) continue;   // only an item on the first list; one that left it keeps only the card the owner sent from
        done.add(it);
        found.push([m.uuid, it]);
        newest.set(it, m.uuid);
      }
    }
    const here = new Map(), used = new Set();
    for (const [uuid, it] of found) {
      const key = uuid + "\n" + it.id, top = newest.get(it) === uuid;
      let c = cards.get(key);
      if (!top && !(c && sending(c))) continue;   // one card an item; an earlier one is kept only while its frame is sending
      used.add(key);
      if (!c) {
        const title = el("p", { class: "ans-head" }), line = el("p", { class: "ans-line", hidden: true }), slot = el("div", { class: "ans-slot" });
        c = { it, node: el("div", { class: "ans-under" }, el("div", { class: "ans-card" }, title, line, slot)), title, line, slot, newest: false, box: null, seq: ++made, sent: false };
        cards.set(key, c);
      }
      c.newest = top;
      if (top && !c.box && it.listed) { c.box = make(it); c.slot.append(c.box.frame); }   // no frame is made for an item off the list
      if (!here.has(uuid)) here.set(uuid, []);
      here.get(uuid).push(c);
    }
    for (const [key, c] of cards) if (!used.has(key)) removeCard(key, c);
    for (const c of cards.values()) paintCard(c);
    // cards under one reply keep the order they came in: a card that is already there never changes places
    return new Map([...here].map(([uuid, list]) => [uuid, list.sort((a, b) => a.seq - b.seq).map((c) => c.node)]));
  }

  /* ---------- the keyboard ---------- */
  const composing = () => {
    const a = document.activeElement;
    return !!(a && a.closest("#composer") && (a.isContentEditable || a.matches("textarea, input")));
  };
  // the visible height is short: sala's own mark (a layout viewport the keyboard leaves at full height), or, on a touch screen, a viewport well under the
  // tallest seen at this width (a keyboard that resizes both viewports)
  function short() {
    const vv = window.visualViewport;
    if (!vv || vv.scale > 1.01) return false;
    return document.documentElement.classList.contains("kbd-up") || (ui.coarse.matches && (ui.tall.get(Math.round(vv.width)) || 0) - vv.height > KBD_MIN);
  }
  function measure() {
    const vv = window.visualViewport;
    if (vv && vv.scale <= 1.01) { const w = Math.round(vv.width); ui.tall.set(w, Math.max(ui.tall.get(w) || 0, vv.height)); }
    layoutSoon();
  }
  function layoutSoon() {
    if (ui && !ui.raf) ui.raf = requestAnimationFrame(layout);
  }
  function layout() {
    ui.raf = 0;
    const it = openId === null ? null : items.get(openId), row = it && it.row, seen = !!(row && row.li.getClientRects().length);
    if (!seen && row && row.box) row.box.typing = false;   // nothing hidden is typed in, whatever the frame said last
    const typing = !!(row && row.box && row.box.reported && row.box.typing);
    const on = !!(seen && !row.li.classList.contains("ans-plain") && (typing || (composing() && short())));
    const box = $("#chat-strip-wait"), was = document.body.classList.contains("ans-kbd"), had = box.style.getPropertyValue("--ans-max");
    const h = pane().clientHeight, max = on ? Math.max(Math.min(h, 120), h - THREAD) + "px" : "";
    if (on === was && max === had) return;
    const pinned = chatScroll.pinned && state.tab === "chat";
    if (on) box.style.setProperty("--ans-max", max); else box.style.removeProperty("--ans-max");
    document.body.classList.toggle("ans-kbd", on);
    if (pinned) scrollToBottom();
    if (on && !was) reveal(row.li);
  }
  function wire() {
    if (ui) return;
    ui = { coarse: matchMedia("(pointer: coarse)"), tall: new Map(), raf: 0 };
    window.addEventListener("message", onMessage);
    new MutationObserver(retheme).observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
    matchMedia("(prefers-color-scheme: light)").addEventListener("change", retheme);
    // what moves the keyboard layout: the focus, the viewport, sala's keyboard mark, the pane's height, and the strip's list opening or closing
    document.addEventListener("focusin", layoutSoon);
    document.addEventListener("focusout", layoutSoon);
    window.addEventListener("resize", measure);
    if (window.visualViewport) window.visualViewport.addEventListener("resize", measure);
    new MutationObserver(layoutSoon).observe(document.documentElement, { attributes: true, attributeFilter: ["class"] });
    new MutationObserver(layoutSoon).observe($("#chat-strip-wait"), { attributes: true, attributeFilter: ["hidden"], subtree: true });
    new ResizeObserver(layoutSoon).observe(pane());
    measure();
  }

  return { strip, thread, timing, address, markers, hideMarks, read };
})();
