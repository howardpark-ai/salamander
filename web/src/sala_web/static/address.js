"use strict";
/* The page's addresses. Each view has a path of its own under the app's root, and the page's code names a view by a short "#..." form:

     view form                  address
     #sessions                  overview
     #schedules, #machines,     schedules, machines,
     #usage, #new               usage, new
     #s=<name>                  s/<name>
     #lane=<id>                 lane/<id>
     #search?<query>            search?<query>
     #side=<payload>            side?<payload>      (a "#" inside the payload, as in a board item's id, is %23)
     ""                         the root itself: no view

   Every path is relative, so the app may sit under a proxy's path prefix. The server puts <base href> in the page ("./", or "../" for the
   two-segment paths s/<name> and lane/<id>; app.py _page); this script fixes it to the root's full address before the page's address
   changes, so "api/…", "static/…" and the links keep resolving against the root whatever view is shown.

   An address of before, with the view after "#" (/#s=<name>, /#sessions, …: saved and shared links use them), is read as that view, and is
   rewritten to the view's path in place: here at a load, by app.js when it arrives in an open page. The server never sees a fragment.

   Loaded in the head, before signin.js, chatboot.js and app.js read the address. */
(function () {
  const base = document.querySelector("base[href]");
  if (base) base.href = base.href;

  const PLAIN = new Map([["#sessions", "overview"], ["#schedules", "schedules"], ["#machines", "machines"], ["#usage", "usage"], ["#new", "new"]]);
  const root = () => new URL("./", document.baseURI);
  const decode = (t) => { try { return decodeURIComponent(t); } catch { return t; } };
  const hasPayload = (view) => /^#(search|side=)/.test(view);   // a view whose address has a query of its own

  // a view form -> its path under the root; null for what names no view
  function path(view) {
    if (view === "") return "";
    if (PLAIN.has(view)) return PLAIN.get(view);
    const own = (t) => t.replace(/#/g, "%23");
    if (view === "#search" || view.startsWith("#search?")) return "search" + own(view.slice("#search".length));
    if (view.startsWith("#side=")) { const q = own(view.slice("#side=".length)); return q ? "side?" + q : "side"; }
    const lane = /^#lane=([^&]+)$/.exec(view);
    if (lane) return "lane/" + encodeURIComponent(decode(lane[1]));
    const name = view.startsWith("#") && /(?:^|&)s=([^&]+)/.exec(view.slice(1));
    return name ? "s/" + encodeURIComponent(decode(name[1])) : null;
  }

  // the view a path names (rest: the path under the root); "" the root, null a path that is no view
  function ofPath(rest, at) {
    if (rest === "") return "";
    for (const [view, p] of PLAIN) if (rest === p) return view;
    if (rest === "search") return "#search" + at.search;
    // typed with a bare "#" in the item's id (side?item#38), the rest of the payload is in the fragment
    if (rest === "side") return "#side=" + at.search.slice(1) + at.hash;
    let m = /^s\/(.+)$/.exec(rest);
    if (m) return "#s=" + encodeURIComponent(decode(m[1]));
    m = /^lane\/([^/]+)$/.exec(rest);
    return m ? "#lane=" + encodeURIComponent(decode(m[1])) : null;
  }

  /* The view of an address (location, or a link: pathname, search, hash): its form, "" for the root, null for an address that is not one of
     this page's views (another path, or another query than the page's own on a view that has none). A view written after "#" wins. */
  function read(at) {
    const top = root().pathname;
    if (!at.pathname.startsWith(top)) return null;
    const own = ofPath(at.pathname.slice(top.length), at);
    if (own === null) return null;
    const view = at.hash && path(at.hash) !== null ? at.hash : own;
    return !hasPayload(view) && at.search && at.search !== location.search ? null : view;
  }

  const here = () => read(location) || "";

  // the full address of a view; the page's own query (?debug=…) goes along, never another view's
  function url(view) {
    const to = new URL(path(view) || "", root());
    if (!hasPayload(view) && !hasPayload(here())) to.search = location.search;
    return to.href;
  }

  window.SalaAddress = { path, read, here, url };

  if (location.hash && path(location.hash) !== null && read(location) !== null) history.replaceState(history.state, "", url(location.hash));
})();
