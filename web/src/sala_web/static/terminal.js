"use strict";
/* The full-size terminal page (terminal.html): one ttyd frame filling the window, hooked by termclip.js. The session is the
   page's ?arg=<tmux session>, as on ttyd's own URL; the ttyd address and the Shell session's name are the ones the main page uses
   (api/config terminalUrl, shellSession). When the session is the Shell's, the page first asks the app to make it (POST api/shell/open,
   the call the drawer makes): ttyd's attach command only attaches to a session that is there, and a bookmark, a restored tab or an
   old link comes here without the drawer ever opening. It waits for the answer at most SHELL_OPEN_WAIT_MS and loads the frame
   whatever the answer, so the page is never left blank. */
const SHELL_OPEN_WAIT_MS = 8000;
async function openShellSession() {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), SHELL_OPEN_WAIT_MS);
  try {
    await fetch("api/shell/open", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}", signal: ctl.signal });
  } catch { /* the frame loads anyway: ttyd's own "No tmux session named ..." says what is missing */ }
  finally { clearTimeout(timer); }
}
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
  if (arg && arg === shellSession) await openShellSession();   // any other session is attached as it is, never made here
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
