// sala-web's service worker. It exists so that the page counts as an installable app and for nothing else: it keeps no
// cache and has NO fetch handler, on purpose. A worker with a fetch handler sits in front of every request of the
// site, and the pass-through handler an earlier version had (`event.respondWith(fetch(req))`) broke once sala also
// resolved to the tailnet address: Chrome's private-network rules block a fetch made from a worker installed while the
// host resolved to a public IP, so the installed app window showed ERR_FAILED (a hard reload, which skips the worker,
// worked). Current Chrome no longer asks for a fetch handler before it offers "Install app", so the worker must not
// intercept anything: the browser fetches as if no worker were here. Do not add one back.
//
// /mockup/<n> (a page `sala mockup add` stored, served in a sandbox, mockup.py) is left alone for the same reason: with no fetch handler the
// worker never sees that request, and a sandboxed page has an opaque origin, which no worker controls. If a fetch handler is ever added it must
// return at once for a path that starts with /mockup/ (no respondWith, no cache, no navigation fallback); tests/test_mockup.py holds the worker to both.
//
// install and activate stay: skipWaiting and clients.claim make this worker take over every open client at once, so a
// device that still holds the old pass-through worker drops it at its next /sw.js check (the bytes differ, so the
// browser reinstalls). It is served at the site root (/sw.js, app.py), so its scope is the whole site; app.js
// registers it.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));
