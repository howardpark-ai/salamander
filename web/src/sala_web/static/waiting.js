/* A message that waits to be read, and the server's outbox behind it (outbox.py).

   A message the composer sends goes to api/outbox/<name> (a "!" command, and a slash command with nothing waiting ahead of it, still go to
   api/s/<pid>/send: app.js). The server keeps it: HELD while the pane can not take it (a question is open, the session sleeps, ...), then
   typed into the pane, where it waits in Claude Code's queue until Claude reads it. The page draws every such message as one waiting state,
   a dashed bubble with "Waiting" under it, no time, and Edit and Cancel. What is under the bubble is read from the server's list, which the
   stream sends ("outbox") and api/outbox/<name> answers, so a reload draws the waiting messages again.

   A bubble goes when the transcript shows its message (app.js matchPending), when the list says it was delivered (after MERGE_MS, for the
   transcript's copy to come first), or when it was taken back. Cancel and Edit ask the server to take the message back; for one already in
   the pane that pulls the whole queue and types the others again, which the bubbles say while it is asked. Claude may have read it first:
   the status line says so then.

   Words from app.js and the tables are looked up when a function runs, never at load. */
(function () {
  const MERGE_MS = 3000;
  const done = new Set();    // ids and cids of messages this page is finished with: no list brings their bubble back
  const lines = new Set();   // uuids of the transcript messages already offered to the bubbles: a copy read again (a reconnect) takes no second one
  const ICON = '<svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>';

  const url = (name, rest = "") => `api/outbox/${encodeURIComponent(name)}${rest}`;
  const mine = (name) => state.pending.filter((p) => p.ob && p.session === name);
  const isSlash = (text) => /^\s*\//.test(String(text || ""));
  const inPane = (p) => p.state === "queued" || p.state === "typing";
  const newCid = () => Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 10);

  // a message that waits to be read: any bubble of this page but a failed one and a "!" command's (which nothing reads as a message)
  const waits = (p) => p.status !== "failed" && !isBang(p.text);
  // whether something this page sent through the outbox still waits for `name`: a slash command then goes behind it, not past it
  const active = (name) => mine(name).some((p) => p.status === "waiting" && p.state !== "delivered");

  // Claude asks something (a question or a permission): the one thing a waiting bubble gives a reason for
  function asking(name) {
    const s = state.current && state.current.name === name ? state.current : state.byName.get(name);
    return !!s && s.status === "waiting";
  }
  // a dialog or a menu is open in the pane (Claude's, or one the owner opened): the server takes nothing out of the pane then
  const dialogOpen = (name) => asking(name) || mine(name).some((p) => p.status === "waiting" && p.state === "held" && p.reason === "dialog");

  // what is under a waiting bubble: the words, the reason, and the buttons as [words, what it does]
  function view(p) {
    const out = { words: tl(p.back === "back" ? "app.wait.back" : p.back === "again" ? "app.wait.again" : "app.wait.state"), reason: "", buttons: [] };
    if (p.back || p.taken) return out;   // being asked about; or the server said Claude has read it, and its line is on the way
    if (asking(p.session)) out.reason = tl("app.wait.dialog");
    if (!p.ob || !p.mid || !p.state || p.state === "delivered") return out;   // the server has not answered yet, or Claude has read it
    // a message in the pane (the terminal's queue) is sent now, unless a dialog is open (the line above says why); the server refuses
    // what it can not send safely and says why, so an upload or a slash command in the way does not hide it
    if (inPane(p) && !dialogOpen(p.session)) out.buttons.push([tl("app.sendnow.button"), (ev) => sendNow(p.session, ev.currentTarget), "send-now"]);
    // one in the pane is taken back by pulling the pane's whole queue: not under a dialog, nor with an upload or a slash command in the way
    if (inPane(p) && (dialogOpen(p.session) || isSlash(p.text) || mine(p.session).some((x) => inPane(x) && x.images.length))) return out;
    if (p.state === "held" && isSleeping(state.byName.get(p.session))) {
      const w = waking.get(p.session);
      if (!w || w.state === "failed") out.buttons.push([tl(w ? "app.sleeping.retry" : "app.sleeping.wake"), () => wakeSleeper(p.session)]);
    }
    out.buttons.push([tl("app.pend.edit"), () => takeBack(p, true)], [tl("app.wait.cancel"), () => takeBack(p, false)]);
    return out;
  }
  const signature = (p) => {
    if (p.status !== "waiting") return JSON.stringify([p.status, p.error || ""]);
    const v = view(p);
    return JSON.stringify([p.status, v.words, v.reason, v.buttons.map((b) => b[0])]);
  };

  // the line under a waiting bubble (app.js pendingNode)
  function line(p) {
    const v = view(p);
    p.sig = signature(p);
    const st = el("span", { class: "st" });
    st.append(svgNode(ICON), el("span", {}, el("b", { text: v.words }), v.reason ? " · " + v.reason : ""));
    return el("div", { class: "waiting-line" }, st,
      v.buttons.length ? el("div", { class: "note-actions" }, ...v.buttons.map(([text, onclick, cls]) => el("button", { type: "button", class: cls, text, onclick }))) : null);
  }

  // each bubble of `name` drawn again if what it says changed (a button under the owner's finger is not replaced for nothing)
  function repaint(name) {
    for (const p of mine(name)) if (p.sig !== signature(p)) redraw(p);
  }
  function redraw(p) {
    redrawPending(p);
    p.sig = signature(p);
  }
  // a bubble the page did not have is put into its chat on its side of the working mark
  function place(p) {
    if (state.selected !== p.session || ahead.active) return;
    const chat = $("#chat");
    const empty = chat.querySelector(":scope > .empty:not(.sleeping-note)");
    if (empty) empty.remove();
    placeBubble(p.node);
    if (chatScroll.pinned && state.tab === "chat") scrollToBottom();
  }

  function fromServer(name, m) {
    const p = { id: ++pendingSeq, session: name, ob: true, restored: true, mid: m.id, cid: m.cid, text: m.text, status: "waiting", state: m.state, sentAt: m.created,
                images: (m.uploads || []).map((n) => ({ name: n, url: null, file: { name: n, size: 0 } })) };
    state.pending.push(p);
    apply(p, m);
    redraw(p);
    place(p);
    return p;
  }
  function apply(p, m) {
    Object.assign(p, { mid: m.id, state: m.state, reason: m.reason, updated: m.updated, sentAt: m.created });
    if (m.state === "failed") { p.status = "failed"; p.error = m.error || tl("app.pend.unknown"); delete p.back; }
    else p.status = "waiting";
  }
  // the list says Claude has the message: its bubble waits a moment for the transcript's copy, which takes its place
  function delivered(p, m) {
    Object.assign(p, { mid: m.id, state: "delivered", updated: m.updated, status: "waiting" });
    delete p.back;
    if (p.restored || p.session !== state.selected) dropPending(p);
    else if (!p.timer) p.timer = setTimeout(() => { if (!p.merged) dropPending(p); }, MERGE_MS);
  }

  // the server's list for `name`. `whole`: the answer to a GET asked for it, so a bubble whose message is not in it has left the list
  function sync(name, list, whole = false) {
    if (!Array.isArray(list)) return;
    const gone = new Set(mine(name).filter((p) => p.mid));
    for (const m of list) {
      const p = mine(name).find((x) => x.mid === m.id || (!x.mid && m.cid && x.cid === m.cid));
      if (p) gone.delete(p);
      if (done.has(m.id)) continue;
      if (m.cid && done.has(m.cid)) { done.add(m.id); continue; }
      if (p && (p.acting || m.updated < p.updated)) continue;   // being asked about, or an older answer than the one held
      if (m.state === "withdrawn") { if (p) dropPending(p); }
      else if (m.state === "delivered") { if (p) delivered(p, m); }
      else if (p) apply(p, m);
      else fromServer(name, m);
    }
    const left = [...gone].filter((p) => !p.acting);
    if (whole) for (const p of left) dropPending(p);
    else if (left.length) refresh(name);   // a list from before the message was added, or one it has left: asked again
    repaint(name);
  }
  async function read(name) {
    try {
      const r = await fetch(url(name), { cache: "no-store" });
      const d = r.ok ? await r.json() : null;
      return d && Array.isArray(d.messages) ? d.messages : null;
    } catch { return null; }
  }
  async function refresh(name) {
    const list = await read(name);
    if (list) sync(name, list, true);
  }
  // every poll of the sessions list: a sleeping session has no stream, so its list is asked for
  function tick() {
    if (state.sleepView) refresh(state.sleepView);
    if (state.selected) repaint(state.selected);
  }
  // whether the server still has a message of `name` to type
  async function unsent(name) {
    const list = await read(name);
    return !!list && list.some((m) => m.state === "held" || m.state === "typing");
  }

  // dropPending: whatever took the bubble (the transcript, a cancel, an edit), no later list brings it back
  function forget(p) {
    if (p.mid) done.add(p.mid);
    if (p.cid) done.add(p.cid);
  }
  // whether the transcript message `uuid` is offered to the bubbles for the first time
  function firstSeen(uuid) {
    if (!uuid) return true;
    if (lines.has(uuid)) return false;
    lines.add(uuid);
    return true;
  }

  async function post(p) {
    state.sending = true; refreshSendButton();
    try {
      const r = await fetch(url(p.session), { method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ text: p.text, uploads: p.images.map((im) => im.name), cid: p.cid }) });
      const d = await r.json().catch(() => ({}));
      if (r.ok && d.ok && d.dialogAnswer) {   // a key that answered a dialog: it never shows in the transcript, so no bubble waits for it
        dropPending(p);
        setStatus(() => (d.dialogAnswer === "Escape" ? tl("app.st.dialogEsc") : tl("app.st.dialogKey", { key: d.dialogAnswer })), "ok");
        return;
      }
      if (!r.ok || !d.ok || !d.message) throw new Error(d.error || tl("app.pend.noReason", { status: `${r.status} ${r.statusText}`.trim() }));
      if (p.merged) { done.add(d.message.id); return; }
      if (d.message.state === "delivered") delivered(p, d.message); else apply(p, d.message);
      if (!p.merged) redraw(p);
      sync(p.session, d.messages);
      if (p.state === "held" && isSleeping(state.byName.get(p.session))) holdForWake(p);
    } catch (e) {
      if (p.merged) return;
      // a request that never got an answer (fetch throws a TypeError) is told in words; the server may have it, so Retry keeps its cid
      p.status = "failed"; p.error = e instanceof TypeError ? tl("app.pend.noNet") : e.message || tl("app.pend.unknown"); redraw(p);
    } finally {
      state.sending = false; refreshSendButton();
    }
  }

  const cancel = (p) => nsPost(url(p.session, `/${encodeURIComponent(p.mid)}/cancel`), {});
  const tooLate = (out, edit) => (out.status === 409 && out.d.tooLate ? (edit ? "app.st.lateEdit" : "app.st.lateCancel") : "app.st.takeBusy");

  // Cancel and Edit under a waiting bubble
  async function takeBack(p, edit) {
    if (p.acting || p.merged) return;
    p.acting = true; p.back = "back";
    const others = inPane(p) ? mine(p.session).filter((x) => x !== p && x.status === "waiting" && inPane(x) && !x.back) : [];
    for (const x of others) x.back = "again";
    repaint(p.session);
    const out = await cancel(p);
    p.acting = false;
    delete p.back;
    for (const x of others) delete x.back;
    if (out.status === 200 && out.d.ok) {
      dropPending(p, { keepImages: edit });
      if (edit) toComposer(p);
      setStatus(() => tl(edit ? "app.st.tookBack" : "app.st.cancelled"), "ok");
    } else {
      if (out.status === 409 && out.d.tooLate) p.taken = true;
      setStatus(() => tl(tooLate(out, edit)), "error");
    }
    if (out.d.messages) sync(p.session, out.d.messages);
    else await refresh(p.session);
    repaint(p.session);
  }

  // a failed message the server holds is withdrawn before it is sent or edited again, so it can not go in twice
  async function withdraw(p, edit) {
    p.acting = true;
    const out = await cancel(p);
    p.acting = false;
    if ((out.status === 200 && out.d.ok) || out.status === 404) { done.add(p.mid); return true; }
    setStatus(() => tl(tooLate(out, edit)), "error");
    await refresh(p.session);
    return false;
  }
  // a failed bubble's Retry
  async function retry(p) {
    if (state.sending || p.acting) return;
    if (p.mid) {
      if (!(await withdraw(p, false))) return;
      delete p.mid; p.cid = newCid();
    }
    Object.assign(p, { status: "sending", sentAt: Date.now(), restored: false });
    delete p.state; delete p.updated;
    redraw(p);
    placeBubble(p.node);   // it joins at the end of the line
    pinToBottom();
    post(p);
  }
  // a failed bubble's Edit
  async function edit(p) {
    if (p.acting || p.merged) return;
    let known = true;
    if (!p.mid) {   // the request got no answer: the server may hold it all the same
      p.acting = true;
      const list = await read(p.session);
      p.acting = false;
      known = !!list;
      const m = list && list.find((x) => x.cid === p.cid && x.state !== "withdrawn");
      if (m) p.mid = m.id;
    }
    if (p.mid && !(await withdraw(p, true))) return;
    dropPending(p, { keepImages: true });
    if (!known) done.delete(p.cid);   // not asked: should the server have it, its bubble comes back and can be cancelled
    toComposer(p);
  }

  window.SalaWaiting = { newCid, isSlash, waits, active, line, repaint, sync, refresh, tick, unsent, forget, firstSeen, post, retry, edit };
})();
