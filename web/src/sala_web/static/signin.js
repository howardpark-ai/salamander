"use strict";
/* A sign-in proxy in front of sala (docs/web-proxy.md). Once the session there has ended, a page load is sent to the sign-in page and every other
   request (a fetch, the event stream, a frame, a websocket upgrade) is answered 401. The server itself answers no request with 401, so such an
   answer came from the proxy, and the way back in is to load the page again, once. With no such proxy nothing here ever acts.

   - Every fetch of api/... is watched (window.fetch is wrapped; the caller gets the same answer). A 401 is confirmed with a read of api/config,
     and only a 401 there too reloads. A stream or an upload that failed asks for the same read (SalaSignin.check()).
   - A terminal frame (ttyd, on this origin): ttyd reads /tty/token before each reconnect, so the frame's own fetches are watched too, and a
     frame that came up without a terminal asks for the read.
   - No loop: after a reload nothing reloads again until api/config has answered 2xx since, and REARM_MS has passed. Where that cannot be
     remembered (no storage), nothing reloads.
   - Kept first: the text typed into the page's fields and what app.js hands over (SalaSignin.keeps). The composer's saved draft is app.js's own.
   - The view is in the address's path (address.js), so the reload and the proxy's way back keep it. Only a link of before (/#s=<name>) opened
     while already signed out depends on the proxy's sign-in page to carry the part after "#", which no server sees.

   Loaded in the head, so that it watches the page's fetches from the first one. */
(function () {
  if (window.SalaSignin) return;   // a second copy: index.html asks again for a file that did not load
  const RELOADED = "salaweb.signin.reload", KEPT = "salaweb.signin.kept";
  const REARM_MS = 60000, FRAME_MS = 3000, PROBE_MS = 10000;
  const FIELDS = "input:not([type]), input[type=text], input[type=search], input[type=date], textarea";
  // `store` is "sessionStorage" or "localStorage"; naming either may throw where storage is blocked
  const read = (store, key) => { try { return JSON.parse(window[store].getItem(key)); } catch { return null; } };
  const write = (store, key, value) => { try { window[store].setItem(key, JSON.stringify(value)); return true; } catch { return false; } };
  const drop = (store, key) => { try { window[store].removeItem(key); } catch { /* storage unavailable */ } };

  const typed = new Set();   // the ids of the fields typed into since this load
  document.addEventListener("input", (e) => { const f = e.target; if (f && f.id && f.matches(FIELDS)) typed.add(f.id); }, true);

  let hooks = null, signedIn = false, restored = false, leaving = false, probing = false;

  // once a load, when the page is drawn and the server has answered: what the last sign-in reload kept goes back
  function restore() {
    if (restored || !hooks || !signedIn) return;
    restored = true;
    const kept = read("localStorage", KEPT);
    if (!kept) return;
    drop("localStorage", KEPT);
    for (const [id, value] of Object.entries(kept.fields || {})) {
      const f = document.getElementById(id);
      if (!f || typed.has(id) || !f.matches(FIELDS)) continue;
      f.value = value;
      f.dispatchEvent(new Event("input", { bubbles: true }));   // the page hears it as typed
    }
    for (const k of kept.app || []) {
      try { hooks.restore(k); } catch (e) { console.error("signin: not put back", e); }   // never stops the page's start
    }
  }
  // false when there is something to keep and it cannot be stored: the page then stays as it is
  function keep() {
    const fields = {};
    for (const id of typed) { const f = document.getElementById(id); if (f && f.value) fields[id] = f.value; }
    const mine = hooks && hooks.save();
    if (!mine && !Object.keys(fields).length) return true;
    const old = read("localStorage", KEPT) || {};   // another tab's, not yet taken back
    return write("localStorage", KEPT, { fields: { ...old.fields, ...fields }, app: [...(old.app || []), ...(mine ? [mine] : [])] });
  }

  function confirmed() {   // api/config answered 2xx: signed in, or there is no sign-in at all
    if (leaving) return;
    const last = read("sessionStorage", RELOADED);
    if (last && !last.back) write("sessionStorage", RELOADED, { at: last.at, back: true });
    signedIn = true;
    restore();
  }
  function mayReload() {
    const last = read("sessionStorage", RELOADED);
    return !leaving && (!last || (last.back === true && Date.now() - last.at >= REARM_MS));
  }
  function reload() {
    if (!mayReload() || !keep() || !write("sessionStorage", RELOADED, { at: Date.now(), back: false })) return;
    leaving = true;
    for (const frame of document.querySelectorAll("iframe")) frame.remove();   // ttyd asks "leave this page?" while its socket is open
    try { window.top.location.reload(); } catch { location.reload(); }
  }

  const realFetch = window.fetch.bind(window);
  // has the sign-in ended? One read at a time, and none while a reload would not be allowed anyway
  function check() {
    if (probing || !mayReload()) return;
    probing = true;
    const ctl = new AbortController(), timer = setTimeout(() => ctl.abort(), PROBE_MS);
    realFetch("api/config", { cache: "no-store", signal: ctl.signal })
      .then((r) => { if (r.status === 401) reload(); else if (r.ok) confirmed(); })
      .catch(() => {})   // no answer: that is the connection, not the sign-in
      .finally(() => { clearTimeout(timer); probing = false; });
  }
  function seen(input, response) {
    const at = new URL(input && input.url !== undefined ? input.url : input, document.baseURI), api = new URL("api/", document.baseURI);
    if (at.origin !== api.origin || !at.pathname.startsWith(api.pathname)) return;
    if (response.status === 401) check();
    else if (response.ok && at.pathname === api.pathname + "config") confirmed();
  }
  window.fetch = (input, init) => realFetch(input, init).then((response) => {
    try { seen(input, response); } catch { /* the caller gets its answer whatever happens here */ }
    return response;
  });

  // every frame of these pages is a terminal; a frame's load does not bubble, so it is heard on the way down
  document.addEventListener("load", (e) => {
    const frame = e.target;
    if (!(frame instanceof HTMLIFrameElement)) return;
    try {
      const win = frame.contentWindow, own = win.fetch;
      win.fetch = (...args) => own.apply(win, args).then((r) => { if (r.status === 401) check(); return r; });
    } catch { return; }   // a ttyd on another origin: nothing to see
    setTimeout(() => { try { if (frame.isConnected && !frame.contentWindow.term) check(); } catch { /* it went to another origin */ } }, FRAME_MS);
  }, true);

  window.SalaSignin = {
    check,
    // app.js, once its page is drawn: save() gives what a reload would lose (or null), restore(it) puts that back after the sign-in
    keeps(h) { hooks = h; restore(); },
  };
})();
