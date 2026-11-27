/* Quote a reply's selected text into the composer. A button sits beside the end of the selection on a desktop; on a touch
   screen a chip sits by the end of the selection, clear of the bottom band where Chrome draws its Touch to Search bar.
   Only a selection inside one assistant reply counts. The page gives the insertion through init({ insert }) and keeps the
   composer; this file owns the selection, the placement, the text rules of a quote and the look of a user's quote. */
window.SalaQuote = (() => {
  const TOUCH = window.matchMedia("(pointer: coarse) and (hover: none)");
  const BAR_H = 78;                                     /* the bottom band of a phone screen the browser draws over */
  const CHIP = { w: 40, h: 28, hitW: 48, hitH: 44 };    /* the visible chip and its touch area */
  const GAP = 6;
  const QUOTE_LINE = /^ {0,3}>/;

  let label = () => "Quote";
  let insert = null;
  let last = null;       /* { range, text } of the reply selection now shown, or null */
  let captured = null;   /* the text when a press on the button began (the selection may drop before the click) */
  let desk = null, chip = null;

  const pane = () => document.getElementById("chat-pane") || document.body;

  function replyOf(node) {
    const el = node && node.nodeType === 1 ? node : node && node.parentElement;
    return el ? el.closest(".msg.assistant .md") : null;
  }

  /* only a selection that starts and ends inside one reply counts; one that runs on past the reply's end counts up to it */
  function onSelection() {
    const sel = window.getSelection();
    let ok = false, r = null;
    if (sel && sel.rangeCount && !sel.isCollapsed && sel.toString().trim()) {
      r = sel.getRangeAt(0).cloneRange();
      const a = replyOf(r.startContainer);
      if (a && replyOf(r.endContainer) !== a) {
        const past = document.createRange();
        past.setStart(a, a.childNodes.length);
        past.setEnd(r.endContainer, r.endOffset);
        if (!past.collapsed && !past.toString().trim()) r.setEnd(a, a.childNodes.length);
      }
      ok = !!a && replyOf(r.endContainer) === a;
    }
    last = ok ? { range: r, text: sel.toString() } : null;
    update();
  }

  /* the boxes of the text inside root, or inside range when one is given */
  function textRects(root, range) {
    const out = [], w = document.createTreeWalker(root.nodeType === 3 ? root.parentNode : root, NodeFilter.SHOW_TEXT);
    let n;
    while ((n = w.nextNode())) {
      if (!n.textContent.trim() || (range && !range.intersectsNode(n))) continue;
      const s = document.createRange();
      s.selectNodeContents(n);
      if (range) {
        if (n === range.startContainer) s.setStart(n, range.startOffset);
        if (n === range.endContainer) s.setEnd(n, range.endOffset);
        if (!s.toString().trim()) continue;
      }
      Array.prototype.forEach.call(s.getClientRects(), (q) => { if (q.width > 0.5 && q.height > 0.5) out.push(q); });
    }
    return out;
  }

  function box(l, t, w, h) { return { left: l, top: t, right: l + w, bottom: t + h }; }
  function area(a, b) {
    return Math.max(0, Math.min(a.right, b.right) - Math.max(a.left, b.left)) *
      Math.max(0, Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top));
  }
  function apart(a, b) {
    return Math.hypot(Math.max(b.left - a.right, a.left - b.right, 0), Math.max(b.top - a.bottom, a.top - b.bottom, 0));
  }
  function less(a, b) {
    for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return a[i] < b[i];
    return false;
  }

  /* the part of the screen the chat shows */
  function viewOf() {
    const p = pane().getBoundingClientRect();
    return { left: p.left, right: p.right, top: Math.max(p.top, 0), bottom: Math.min(p.bottom, window.innerHeight) };
  }

  function update() {
    if (desk) desk.hidden = true;
    if (chip) chip.hidden = true;
    if (!last) return;
    const rects = textRects(last.range.commonAncestorContainer, last.range);
    if (!rects.length) return;
    const btn = TOUCH.matches ? chip : desk;
    btn.querySelector("span").textContent = label();
    btn.setAttribute("aria-label", label());
    btn.title = label();
    if (TOUCH.matches) placeChip(rects, viewOf());
    else placeDesk(rects, viewOf());
  }

  /* a desktop: beside the end of the selection, on its last line; below or left of it only when the spot beside it is
     off the chat or covers more text. Ties keep that order */
  function placeDesk(rects, v) {
    const end = rects[rects.length - 1];
    if (end.bottom < v.top || end.top > v.bottom) return;
    const vw = document.documentElement.clientWidth;
    desk.hidden = false;
    const w = desk.offsetWidth, h = desk.offsetHeight;
    const texts = textRects(pane()).filter((t) => t.bottom > v.top && t.top < v.bottom);
    const mid = end.top + (end.height - h) / 2;
    const spots = [
      { x: end.right + GAP, y: mid },
      { x: end.right - w, y: end.bottom + 2 },
      { x: end.left - w - GAP, y: mid },
    ];
    let best = null;
    spots.forEach((s) => {
      const b = box(s.x, s.y, w, h);
      const inside = b.left >= v.left + 4 && b.right <= Math.min(v.right, vw) - 4 && b.top >= v.top + 2 && b.bottom <= v.bottom - 2;
      const score = [inside ? 0 : 1, texts.reduce((sum, t) => sum + area(b, t), 0)];
      if (!best || less(score, best.score)) best = { x: s.x, y: s.y, score };
    });
    desk.style.left = best.x + "px";
    desk.style.top = best.y + "px";
  }

  /* a touch chip: the touch area stays above the bottom band, clear of the end handle, and covers the least text, nearest
     first (within 40 px of the handle, then 96 px, then anywhere); a spot on the selected text only when none else exists */
  function placeChip(rects, v) {
    const bottom = Math.min(v.bottom, window.innerHeight - BAR_H);
    const end = rects[rects.length - 1];
    const seen = rects.filter((q) => q.bottom > v.top && q.top < bottom);
    if (!seen.length) return;
    const q = end.bottom > v.top && end.top < bottom ? end : seen[seen.length - 1];
    const ax = q.right, ay = Math.min(Math.max(q.bottom, v.top), bottom);
    const handle = box(ax - 12, ay - 4, 24, 28);   /* the end handle, drawn under the end of the selection */
    const texts = textRects(pane()).filter((t) => t.bottom > v.top && t.top < bottom)
      .map((t) => ({ left: t.left, right: t.right, top: t.top + 2, bottom: t.bottom - 2 }));
    const picked = rects.map((t) => ({ left: t.left, right: t.right, top: t.top + 1, bottom: t.bottom - 1 }));
    const vw = document.documentElement.clientWidth;
    const mx = (CHIP.hitW - CHIP.w) / 2, my = (CHIP.hitH - CHIP.h) / 2;
    const anchor = box(ax, ay, 0, 0);

    function search(reach, onText) {
      let best = null;
      const step = reach === Infinity ? 4 : 2;
      for (let ht = v.top; ht <= bottom - CHIP.hitH; ht += step) {
        for (let hl = 0; hl <= vw - CHIP.hitW; hl += step) {
          const hit = box(hl, ht, CHIP.hitW, CHIP.hitH), vis = box(hl + mx, ht + my, CHIP.w, CHIP.h);
          const d = apart(vis, anchor);
          if (d > reach || area(hit, handle) > 0) continue;
          const own = picked.reduce((sum, t) => sum + area(hit, t), 0);
          if (own > 0.5 && !onText) continue;
          const covered = texts.reduce((sum, t) => sum + area(vis, t), 0);
          const tie = d + (vis.left + CHIP.w / 2 < ax ? 6 : 0) + (vis.top + CHIP.h / 2 < ay ? 3 : 0);
          const score = [Math.round(covered / 25), tie];
          if (!best || less(score, best.score)) best = { hl, ht, score };
        }
      }
      return best;
    }

    const spot = search(40, false) || search(96, false) || search(Infinity, false) || search(Infinity, true);
    if (!spot) return;
    chip.hidden = false;
    chip.style.left = spot.hl + "px";
    chip.style.top = spot.ht + "px";
  }

  /* the press keeps the selection; the text is taken now, before a tap can drop it */
  function press(e) {
    e.preventDefault();
    captured = last ? last.text : null;
  }

  function onClick() {
    const text = captured !== null ? captured : last && last.text;
    captured = null;
    if (!text || !insert) return;
    window.getSelection().removeAllRanges();
    last = null;
    update();
    insert(quoteBlock(text));
  }

  function makeButton(cls) {
    const b = document.createElement("button");
    b.type = "button";
    b.className = cls;
    b.hidden = true;
    b.appendChild(document.createElement("span"));
    ["pointerdown", "mousedown"].forEach((t) => b.addEventListener(t, press));
    b.addEventListener("click", onClick);
    document.body.appendChild(b);
    return b;
  }

  /* the quote as text: "> " on each selected line, one newline after, so the caret is on the next line */
  function quoteBlock(t) {
    const lines = t.replace(/\r\n?/g, "\n").replace(/^\s*\n/, "").replace(/\s+$/, "").split("\n");
    return lines.map((l) => (l.trim() ? "> " + l.replace(/\s+$/, "") : ">")).join("\n") + "\n";
  }

  /* the composer's text with a quote added at its end: after typed text the quote starts on the next line; right after
     another quote one empty line keeps the two apart; empty lines at the draft's end are collapsed */
  function appendTo(cur, block) {
    if (!cur.trim()) return block;
    const head = cur.replace(/(\n[ \t]*)+$/, ""), tail = head.slice(head.lastIndexOf("\n") + 1);
    return head + (QUOTE_LINE.test(tail) ? "\n\n" : "\n") + block;
  }

  /* a user's message as nodes: runs of "> " lines become a blockquote, other lines stay outside it; a run of only empty
     lines (the gap between two quotes) is not drawn. linkNodes gives the inline nodes of a run (links kept) */
  function userParts(text, linkNodes) {
    const runs = [];
    text.split("\n").forEach((line) => {
      const q = QUOTE_LINE.test(line);
      let run = runs[runs.length - 1];
      if (!run || run.q !== q) runs.push(run = { q, lines: [] });
      run.lines.push(q ? line.replace(/^ {0,3}> ?/, "") : line);
    });
    if (!runs.some((r) => r.q)) return linkNodes(text);
    return runs.filter((r) => r.q || r.lines.join("").trim()).map((r) => {
      const node = document.createElement(r.q ? "blockquote" : "div");
      linkNodes(r.lines.join("\n")).forEach((n) => node.appendChild(n));
      return node;
    });
  }

  function init(opts) {
    label = opts.label || label;
    insert = opts.insert;
    desk = makeButton("quote-btn");
    chip = makeButton("quote-chip");
    document.addEventListener("selectionchange", onSelection);
    window.addEventListener("scroll", () => { if (last) update(); }, { capture: true, passive: true });
    window.addEventListener("resize", update);
    TOUCH.addEventListener("change", update);
  }

  return { init, quoteBlock, appendTo, userParts };
})();
