"use strict";
/* The full-size terminal page (terminal.html): one ttyd frame filling the window, hooked by termclip.js. The session is the
   page's ?arg=<tmux session>, as on ttyd's own URL; the ttyd address and the Shell session's name are the ones the main page uses
   (api/config terminalUrl, shellSession). */
(async function () {
  const arg = new URLSearchParams(location.search).get("arg") || "";
  let base = "/tty/?arg=", shellSession = "";
  try {
    const r = await fetch("api/config", { cache: "no-store" });
    const c = r.ok ? await r.json() : {};
    if (c && typeof c.terminalUrl === "string" && c.terminalUrl) base = c.terminalUrl;
    if (c && typeof c.shellSession === "string") shellSession = c.shellSession;
  } catch { /* the default address */ }
  if (arg) document.title = arg;
  const frame = document.createElement("iframe");
  frame.src = base + encodeURIComponent(arg);
  frame.title = arg ? tl("term.frameTitleFor", { name: arg }) : tl("ui.hdr.terminal");
  frame.allow = "clipboard-read; clipboard-write";
  document.getElementById("term-full").append(frame);
  hookTerminalClipboard(frame);
  hookTerminalFont(frame);   // D2Coding 14px for any session
  if (arg && arg === shellSession) hookShellTerminal(frame);   // the key log is the Shell session's alone
  frame.addEventListener("load", () => { try { frame.contentWindow.focus(); } catch { /* cross-origin */ } }, { once: true });
})();
