/* The question a session waits on, drawn as a card with buttons at the end of the conversation (the session view and the chat session's view alike).
   While the selected session's status is "waiting", the page asks api/s/<pid>/dialog every POLL_MS for what the pane shows (the server reads the
   screen: a question with choices, a permission dialog with its options, or nothing). A question that takes one answer is a button per option, one tap
   sends it. A question that takes several is a checkbox row per option and one Send (the button, and the hint that names it, read Next when the question is not the last one): the server sets the marks, moves to the row under the options (Submit, or Next) and presses it, and
   refuses when the screen does not read as asked. The free-text row of such a question has no button (a button cannot type). Cancel sends Escape.
   Every answer carries the words of the question it was made for, so a card that has gone stale answers nothing.
   NO SIDEWAYS SCROLL: every box shrinks and every run of text breaks anywhere (dialogcard.css). Words are set as text, never as HTML. */
(function () {
  const POLL_MS = 2000;
  const cur = { pid: null, timer: null, card: null, sig: "", node: null, picks: new Set(), busy: false, run: 0, read: false, told: "" };

  const kids = (n, ...c) => { for (const x of c) if (x != null) n.append(x); return n; };
  const mk = (tag, cls, text) => { const n = document.createElement(tag); if (cls) n.className = cls; if (text) n.textContent = text; return n; };

  async function post(body) {
    const r = await fetch(`api/s/${cur.pid}/dialog`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
    const d = await r.json().catch(() => ({}));
    return { ok: r.ok && d.ok, status: r.status, d };
  }

  async function answer(body) {
    if (cur.busy || !cur.card) return;
    cur.busy = true;
    cur.node.classList.add("q-busy");
    for (const b of cur.node.querySelectorAll("button, input")) b.disabled = true;
    let res;
    try { res = await post({ expect: cur.card.text, ...body }); } catch { res = { ok: false, d: { error: "no answer from the server" } }; }
    cur.busy = false;
    if (res.ok) setStatus(() => tl("app.st.cardSent"), "ok");
    else if (res.d && res.d.changed) setStatus(() => tl("app.st.cardChanged"), "error");
    else setStatus(() => tl("app.st.cardFail", { why: (res.d && res.d.error) || "" }), "error");
    cur.sig = "";   // drawn again from what the pane shows now
    poll();
    setTimeout(poll, 700);
  }

  function draw(card) {
    const multi = card.kind === "multi";
    const node = mk("div", "q-card" + (multi ? " q-multi" : ""));
    node.setAttribute("role", "group");
    if (card.title) {
      node.setAttribute("aria-label", card.title.split("\n")[0]);
      node.append(mk("div", "q-title", card.title));
    }
    const opts = mk("div", "q-opts");
    for (const o of card.options) {
      const words = [mk("span", "q-label", o.label), o.description ? mk("span", "q-desc", o.description) : null];
      if (multi) {
        const box = mk("input"); box.type = "checkbox"; box.checked = cur.picks.has(o.n);
        box.addEventListener("change", () => { if (box.checked) cur.picks.add(o.n); else cur.picks.delete(o.n); });
        opts.append(kids(mk("label", "q-opt"), box, kids(mk("span", "q-words"), ...words)));
      } else {
        const b = mk("button", "q-opt"); b.type = "button";
        b.addEventListener("click", () => answer({ key: String(o.n) }));
        opts.append(kids(b, kids(mk("span", "q-words"), ...words)));
      }
    }
    node.append(opts);
    const foot = mk("div", "q-foot");
    if (multi) {
      // "Next" when the pane's button is Next (a question that is not the last one): the picks go on to the next question. The hint names the same button
      const next = card.button === "Next";
      node.append(mk("div", "q-hint", tl(next ? "app.st.cardMultiNext" : "app.st.cardMulti")));
      const send = mk("button", "q-send", tl(next ? "app.st.cardNext" : "app.st.cardSend")); send.type = "button";
      send.addEventListener("click", () => answer({ picks: [...cur.picks].sort((a, b) => a - b) }));
      foot.append(send);
    }
    const esc = mk("button", "q-esc", tl("app.st.cardDismiss")); esc.type = "button";
    esc.addEventListener("click", () => answer({ key: "esc" }));
    foot.append(esc);
    node.append(foot);
    return node;
  }

  // What stands under the conversation, for the chat session's own layer (chatlayer.js), which draws no second copy of a question the card shows:
  // the card drawn; null when the server read no card on the pane; undefined while it has not said (no wait, no answer yet, a server with no such
  // route). The event "sala:question-card" on the document says that this changed
  const standing = () => (cur.read ? cur.card : undefined);
  function tell() {
    const c = standing(), sig = c === undefined ? "" : c === null ? "none" : c.kind + "\n" + c.text;
    if (sig === cur.told) return;
    cur.told = sig;
    document.dispatchEvent(new Event("sala:question-card"));
  }

  function show(card) {
    const chat = document.getElementById("chat");
    if (!card || !chat) { if (cur.node) { cur.node.remove(); cur.node = null; } cur.card = null; cur.sig = ""; return; }
    const sig = card.kind + "\n" + card.text;
    if (sig !== cur.sig || !cur.node) {
      cur.sig = sig; cur.card = card;
      cur.picks = new Set(card.options.filter((o) => o.checked).map((o) => o.n));
      const node = draw(card);
      if (cur.node) cur.node.replaceWith(node);
      cur.node = node;
    }
    if (chat.lastElementChild !== cur.node) chat.append(cur.node);   // under the newest message, however it got there
    if (chatScroll.pinned && state.tab === "chat") scrollToBottom();
  }

  async function poll() {
    const run = cur.run, pid = cur.pid;
    if (pid == null) return;
    let d = null;
    try {
      const r = await fetch(`api/s/${pid}/dialog`, { cache: "no-store" });
      if (r.ok) d = await r.json();
    } catch { /* the next poll tries again */ }
    if (run !== cur.run || cur.busy) return;   // another session was selected, or an answer is on its way
    if (!d) return;
    cur.read = true;
    show(d.card);
    tell();
  }

  function stop() {
    clearInterval(cur.timer); cur.timer = null; cur.pid = null; cur.run++; cur.read = false;
    show(null);
    tell();
  }

  // called with the selected session whenever its status or its chat may have changed: the card exists while it waits
  function sync(s) {
    if (!s || s.status !== "waiting") { if (cur.pid != null) stop(); return; }
    if (cur.pid === s.pid) {   // the chat was drawn again (a reconnect, a reset): the card goes back under it
      const chat = document.getElementById("chat");
      if (cur.node && chat && chat.lastElementChild !== cur.node) chat.append(cur.node);
      return;
    }
    stop();
    cur.pid = s.pid;
    cur.timer = setInterval(() => { if (!document.hidden) poll(); }, POLL_MS);
    poll();
  }

  window.SalaQuestionCard = { sync, poll, standing };
})();
