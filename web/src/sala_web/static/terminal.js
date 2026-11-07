"use strict";
/* The full-size terminal page (terminal.html): one ttyd frame filling the window, hooked by termclip.js. The session is the
   page's ?arg=<tmux session>, as on ttyd's own URL; the ttyd address is the one the main page uses (api/config terminalUrl). */
(async function () {
  const arg = new URLSearchParams(location.search).get("arg") || "";
  let base = "/tty/?arg=";
  try {
    const r = await fetch("api/config", { cache: "no-store" });
    const c = r.ok ? await r.json() : {};
    if (c && typeof c.terminalUrl === "string" && c.terminalUrl) base = c.terminalUrl;
  } catch { /* the default address */ }
  if (arg) document.title = arg;
  const frame = document.createElement("iframe");
  frame.src = base + encodeURIComponent(arg);
  frame.title = arg ? "Terminal for " + arg : "Terminal";
  frame.allow = "clipboard-read; clipboard-write";
  document.getElementById("term-full").append(frame);
  hookTerminalClipboard(frame);
  frame.addEventListener("load", () => { try { frame.contentWindow.focus(); } catch { /* cross-origin */ } }, { once: true });
})();
