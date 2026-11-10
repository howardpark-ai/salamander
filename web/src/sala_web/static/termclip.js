"use strict";
/* What the pages that show a ttyd terminal share (the main page's Terminal tab and Shell drawer, and terminal.html, the full-size
   page): the clipboard code for the terminal inside the frame. Loaded before app.js; app.js uses copyText for its copy buttons too.

   ttyd 1.7.7's own page copies nothing from tmux and pastes nothing on Ctrl+V, so a ttyd page that is not framed by one of these
   pages has none of it. ttyd's page is same-origin with ours and exposes its xterm.js as window.term; hookTerminalClipboard puts
   three things on it: the OSC 52 copy, the Copy button for a copy the browser refused, and Ctrl+V as a paste. */

async function copyText(text) {
  try {
    if (navigator.clipboard && window.isSecureContext) { await navigator.clipboard.writeText(text); return true; }
  } catch { /* framed or not focused: fall back */ }
  try {
    const ta = document.createElement("textarea");
    ta.readOnly = true;
    ta.style.cssText = "position:fixed;top:0;left:0;width:1px;height:1px;opacity:0";
    ta.value = text;
    document.body.append(ta);
    ta.select();
    const ok = document.execCommand("copy");
    ta.remove();
    return ok;
  } catch { return false; }
}

// Copy from a terminal: a one-time code selected with the mouse never reached the Windows clipboard.
// tmux (set-clipboard on) hands a selection to the terminal as OSC 52 ("ESC ] 52 ; <where> ; <base64> BEL"), but ttyd 1.7.7's
// page registers no handler for 52 and loads no clipboard addon, so the sequence was dropped. Register the missing handler on
// the frame's window.term and put the text on the clipboard with copyText. The page builds `term` a moment after the frame
// loads, so the hook polls (10 s at most); a reloaded frame has a new term and is hooked again, a term already hooked is left alone.
const osc52Hooked = new WeakSet();
// OSC 52's data is "<where>;<base64>" (where: c, p, s, 0-7 or empty); null for a query ("?"), empty or invalid base64
function osc52Text(data) {
  const i = String(data).indexOf(";");
  if (i < 0) return null;
  const b64 = String(data).slice(i + 1).trim();
  if (!b64 || b64 === "?") return null;
  try {
    const bin = atob(b64);
    const text = new TextDecoder("utf-8", { fatal: true }).decode(Uint8Array.from(bin, (c) => c.charCodeAt(0)));
    return text || null;
  } catch { return null; }
}

// Ctrl+V in a terminal pastes (Windows and Linux). xterm.js turns every Ctrl+<letter> keydown into the control character
// (Ctrl+V is 0x16) and cancels the event, so the browser never fires `paste`; Shift+Insert is left alone, which is why only that
// one pasted. ttyd 1.7.7 attaches no key handler of its own, so the app attaches one on the frame's term: for Ctrl+V (Shift may be
// held, so Ctrl+Shift+V pastes too; no Alt, which AltGr sets on some layouts, and no Meta) it returns false, xterm then does
// nothing with the key and does not cancel it, and the browser's own paste reaches xterm's textarea. Every other key, Ctrl+C
// included, still goes to the pane. Not preventDefault: the browser's default is the paste. On a Mac Cmd+V already pastes and
// Ctrl+V is left to xterm. The trade-off: a literal ^V (vim's block-visual mode, the shell's quoted-insert) can no longer be
// typed into the pane from the browser on Windows or Linux.
const macLike = () => /Mac|iPhone|iPad|iPod/.test(navigator.platform || navigator.userAgent || "");
function ctrlVPastes(ev) {
  return ev.type === "keydown" && ev.ctrlKey && !ev.altKey && !ev.metaKey
    && typeof ev.key === "string" && ev.key.toLowerCase() === "v" && !macLike();
}
// A selection that could not be put on the clipboard. Chrome lets a page write to the clipboard only within about 5 s of a
// click or key press, and a drag counts from its mouse-down, not its mouse-up: a drag that took longer (a long selection in the
// Shell drawer, where holding the mouse at the edge scrolls the pane) reaches the clipboard code after the window has closed, and
// both navigator.clipboard and execCommand refuse. The text is kept and a Copy button is offered over the terminal: its click
// is a fresh gesture, which is what the write needs, so nothing expires the offer. It goes away on its click, when a newer
// selection replaces it, when a key is typed in that terminal (keydown inside the frame), or when the frame loads another page.
function offerTerminalCopy(frame, text) {
  const host = frame.parentElement;
  if (!host || !frame.isConnected) return;
  host.querySelector(".term-copy-offer")?.remove();
  const note = document.createElement("span");
  note.textContent = tl("term.copyOffer");
  const btn = document.createElement("button");
  btn.type = "button";
  btn.textContent = tl("common.copy");
  const box = document.createElement("div");
  box.className = "term-copy-offer";
  box.setAttribute("role", "status");
  box.append(note, btn);
  let doc = null;
  try { doc = frame.contentDocument; } catch { /* cross-origin */ }
  const gone = () => {
    box.remove();
    frame.removeEventListener("load", gone);
    if (doc) doc.removeEventListener("keydown", gone, true);
    obs.disconnect();
  };
  const obs = new MutationObserver(() => { if (!box.isConnected) gone(); });   // replaced by a newer offer
  frame.addEventListener("load", gone);
  if (doc) doc.addEventListener("keydown", gone, true);
  btn.addEventListener("click", async () => {
    const ok = await copyText(text);
    note.textContent = tl(ok ? "term.copied" : "term.copyFailed");
    btn.remove();
    setTimeout(gone, 1600);
  });
  host.append(box);
  obs.observe(host, { childList: true });
}
function hookTerminalClipboard(frame) {
  let timer = null;
  const tryHook = (t0) => {
    timer = null;
    if (!frame.isConnected) return;
    let term = null;
    try { term = frame.contentWindow && frame.contentWindow.term; } catch { /* cross-origin (a ttyd elsewhere): nothing to hook */ return; }
    if (term && term.parser && typeof term.parser.registerOscHandler === "function") {
      if (osc52Hooked.has(term)) return;
      osc52Hooked.add(term);
      try {
        term.parser.registerOscHandler(52, (data) => {
          const text = osc52Text(data);
          if (text) copyText(text).then((ok) => { if (!ok) offerTerminalCopy(frame, text); }, () => {});
          return true;
        });
      } catch { /* the terminal works without it */ }
      try {
        if (typeof term.attachCustomKeyEventHandler === "function") term.attachCustomKeyEventHandler((ev) => !ctrlVPastes(ev));
      } catch { /* the terminal works without it */ }
      return;
    }
    if (Date.now() - t0 < 10000) timer = setTimeout(() => tryHook(t0), 250);
  };
  const start = () => { if (timer) clearTimeout(timer); tryHook(Date.now()); };
  frame.addEventListener("load", start);
  start();
}

