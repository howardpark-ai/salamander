/* The first paint of the chat session's address.

   The served markup is the page with no session: the header says "Select a session" and #chat says "Pick a session on the left.", until app.js has read its lists and
   opened the session of the address. On the chat session's address that is another view shown first. So on a load of that one address this script hides those two until
   the page has drawn the chat: visibility only, so nothing is drawn in their place and no box moves, and app.js's own loading line shows as soon as app.js writes it.
   The header's name stays hidden until api/chat has answered too, so the session's real name does not show ahead of its label.

   It reads the page (a MutationObserver) and writes one attribute on <html> and one <style> of its own; no other script knows of it. index.html names it only when a
   chat session is configured (app.py _page), and on every other address it does nothing. It never holds the page back: it lets go as soon as the page draws anything
   else (not running, asleep, another view), on an uncaught error, and after a time limit. */
(function () {
  // <chat-boot-words> (the tests run what is between these two markers in node)
  // the session an address names, as app.js's hashName reads "#s=<name>"; null for any other address
  const bootSession = (hash) => {
    const m = /^#s=([^&]*)/.exec(hash);
    if (!m) return null;
    try { return decodeURIComponent(m[1]); } catch { return m[1]; }
  };
  // is this load on its way to the chat session? By its own address; or with no address at all, where app.js opens the last view again (`reopens`: a phone's width, the
  // installed app) and that view was the chat
  const chatBootWanted = (session, hash, reopens, last) => bootSession(hash || (reopens ? last : "")) === session;
  // keep hiding, given what the page shows now: yes while app.js has drawn nothing; after that only while the chat session is open under its bare name, ahead of
  // api/chat's answer (the sidebar's entry comes with the answer, and the header's label with it)
  const chatBootHolds = (session, page) => !page.drawn || (!page.elsewhere && !page.asleep && !page.answered && page.name === session);
  // </chat-boot-words>

  // after the document has been read, and from the start of the load: the longest the page is held when nothing above lets it go (a read that hangs or failed)
  const AFTER_READ_MS = 10000, AT_MOST_MS = 30000;
  const self = document.currentScript;
  const session = self && self.getAttribute("data-chat-session");
  // only ahead of the first paint (in the head, no body yet). A copy asked for again after a failed load (the script at the top of index.html) carries no session
  if (!session || document.body) return;
  // the two queries are app.js's replaceMode and the key its LAST_VIEW (a test holds the files together)
  const media = (q) => window.matchMedia(q).matches;
  let last = "";
  try { last = localStorage.getItem("salaweb.lastView") || ""; } catch { /* storage unavailable */ }
  if (!chatBootWanted(session, location.hash, media("(max-width: 760px)") || media("(display-mode: standalone)"), last)) return;

  const root = document.documentElement, style = document.createElement("style");
  style.textContent = 'html[data-chat-boot] #title .name, html[data-chat-boot] #chat > [data-i18n="ui.chat.pick"] { visibility: hidden; }';
  const find = (selector) => document.querySelector(selector);
  const watch = new MutationObserver(() => {
    const first = find("#chat > :first-child"), name = find("#title .name"), entry = find("#side-chat");
    if (!chatBootHolds(session, {
      drawn: !!first && first.getAttribute("data-i18n") !== "ui.chat.pick",   // the markup's own placeholder is gone
      elsewhere: !!find("body.overview-open, body.new-open, body.search-open"),
      asleep: !!find("#title .dot.sleeping"),
      answered: !!entry && !entry.hidden,
      name: name ? name.textContent : "",
    })) done();
  });
  function done() {
    watch.disconnect();
    root.removeAttribute("data-chat-boot");
    style.remove();
    removeEventListener("error", failed);
    removeEventListener("unhandledrejection", failed);
  }
  // an uncaught error or a refused promise may have stopped the page half-way: it is shown as it is. A file that failed to load is no such error (it carries no `error`)
  function failed(e) { if (e.type === "unhandledrejection" || e.error) done(); }
  addEventListener("error", failed);
  addEventListener("unhandledrejection", failed);
  setTimeout(done, AT_MOST_MS);
  addEventListener("DOMContentLoaded", () => setTimeout(done, AFTER_READ_MS), { once: true });
  root.setAttribute("data-chat-boot", "");
  self.after(style);
  watch.observe(root, { subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ["class", "hidden"] });
})();
