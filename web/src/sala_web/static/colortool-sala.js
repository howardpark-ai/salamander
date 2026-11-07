/* sala's wiring of the shared color tool. colortool.js (loaded just before this file) is stackshot's, pinned here byte for byte and never edited
   (web/tools/pin-colortool pins a newer copy); everything that is sala's own is this file: the settings the tool is given (`cfg`), and the one
   call that applies the stored look in the head, before the first paint. The button is started at the end of index.html's body
   (SalaColors.init) and sits at the bottom of the side panel (#side-colors). The terminal page loads both scripts but never starts the button:
   the stored look applies there, and the page stays black.

   What the look is: 14 colors (bg card line fg mut link ibd solid onsolid labbg labfg labbd disbg disfg) set as inline custom properties on
   <html>, kept in this browser's localStorage under "sala-colortry" (a flat {key: "#rrggbb"} map; the key keeps its old name so a look
   chosen before keeps loading). Dark theme only: in the light theme nothing is applied and no button is drawn. The gate is "warn": nothing
   is ever refused, a low ratio is a note beside the field. The saved list is this server's own api/colors/combos (colors.py), which holds
   the token; the browser sends and sees neither the token nor the sender label.

   What each field sets is `vars` below; the four surfaces that follow the card color and the disabled pair's opacity are `onApply`. The
   stylesheets read every one of these names with a fallback, so without the tool nothing changes. */
(function () {
  "use strict";
  var root = document.documentElement;
  var CT = window.ColorTool;
  if (!CT) return;            /* colortool.js did not load: the page is as shipped */

  /* where the shipped value of a field is read: the stylesheets' own custom property */
  var SOURCE = { bg: "--bg", card: "--panel", fg: "--text", mut: "--muted", line: "--border", ibd: "--faint", link: "--link", solid: "--accent", onsolid: "--accent-text" };
  /* a page with no palette of its own (the terminal page) falls back to the dark theme's values, as termclip.css does */
  var FALLBACK = { "--bg": "#161617", "--panel": "#1f1f21", "--text": "#ececea", "--muted": "#a3a29d", "--border": "#2c2c2e", "--faint": "#929190",
                   "--link": "#f0a06a", "--accent": "#f0a06a", "--accent-text": "#1f1f21",
                   "--label-bg": "#3a2619", "--label-fg": "#f0a06a", "--label-bd": "#3a2619", "--dis-bg": "#2a2a2c", "--dis-fg": "#a3a29d" };
  /* surfaces that follow the card color by the step it moved from its shipped value */
  var SHIFTED = ["--code-bg", "--hover", "--selected", "--user-bubble"];
  var FADE = 45;              /* the shipped disabled look: the solid button at this percent over the card */
  var HEX = /^#[0-9a-f]{6}$/;

  function rgb(h) { return [1, 3, 5].map(function (i) { return parseInt(h.slice(i, i + 2), 16); }); }
  function hex(c) { return "#" + c.map(function (x) { return ("0" + Math.max(0, Math.min(255, Math.round(x))).toString(16)).slice(-2); }).join(""); }
  function mix(a, b, pct) { var x = rgb(a), y = rgb(b); return hex(x.map(function (v, i) { return v * pct / 100 + y[i] * (100 - pct) / 100; })); }
  /* any CSS color a stylesheet may write, as #rrggbb (null when it is not one) */
  function toHex(v) {
    v = (v || "").trim().toLowerCase();
    if (HEX.test(v)) return v;
    if (/^#[0-9a-f]{3}$/.test(v)) return "#" + v.slice(1).split("").map(function (c) { return c + c; }).join("");
    if (!v) return null;
    var p = document.createElement("span");
    p.style.color = v;
    if (!p.style.color) return null;
    root.appendChild(p);
    var m = getComputedStyle(p).color.match(/\d+(\.\d+)?/g);
    root.removeChild(p);
    return m && m.length >= 3 ? hex(m.slice(0, 3).map(Number)) : null;
  }
  function shippedOf(name) { return toHex(getComputedStyle(root).getPropertyValue(name)) || FALLBACK[name] || null; }

  /* the terminal page has no palette of its own (it is black whatever the system says); the main page and /v2/ follow sala's rule: light when
     data-theme="light", or, with no data-theme, when the system prefers light */
  function isDark() {
    var t = root.getAttribute("data-theme");
    if (t) return t !== "light";
    if (getComputedStyle(root).getPropertyValue("--bg").trim() === "") return true;
    return !(window.matchMedia && matchMedia("(prefers-color-scheme: light)").matches);
  }

  /* a page with a palette whose small-label and disabled tokens are not set (the light theme) has no such shipped look: the labels and the faded button
     are worked out from the solid fill as the stylesheets' fallbacks draw them, and only the dark theme's six tokens (style.css) are read */
  function hasPalette() { return getComputedStyle(root).getPropertyValue("--bg").trim() !== ""; }
  function token(name, derive) {
    var v = toHex(getComputedStyle(root).getPropertyValue(name));
    if (v) return v;
    return hasPalette() ? derive() : FALLBACK[name];
  }

  var surfaces = {};          /* the shipped value of each shifted surface, read in the same pass as `shipped` */
  /* the 14 values in use with nothing set; the tool calls this on every apply, after it took its own inline properties off */
  function shipped() {
    var s = {};
    Object.keys(SOURCE).forEach(function (k) { s[k] = shippedOf(SOURCE[k]); });
    /* the dark theme ships the small labels and the disabled pair as tokens of their own (see style.css); with no
       token (the light theme) they are what the stylesheets' fallbacks draw: the solid fill and its text, an outline of the fill, the solid at 45% over the card */
    s.labbg = token("--label-bg", function () { return s.solid; });
    s.labfg = token("--label-fg", function () { return s.onsolid; });
    s.labbd = token("--label-bd", function () { return s.labbg; });
    s.disbg = token("--dis-bg", function () { return mix(s.solid, s.card, FADE); });
    s.disfg = token("--dis-fg", function () { return mix(s.onsolid, s.card, FADE); });
    s.ifill = s.bg;           /* the input fill of the new-session form is the page background */
    surfaces = {};
    SHIFTED.forEach(function (n) { surfaces[n] = shippedOf(n); });
    return s;
  }

  /* the dark theme-color meta follows the page background; the shipped content is kept on the meta, so Reset and the light theme put it back */
  function metas() { return Array.prototype.slice.call(document.querySelectorAll('meta[name="theme-color"]')); }
  function setMeta(bg) {
    metas().forEach(function (m) {
      if (m.media && m.media.indexOf("dark") < 0) return;
      if (m.dataset.ctOrig == null) m.dataset.ctOrig = m.content;
      m.content = bg || m.dataset.ctOrig;
    });
  }

  /* what a variable map cannot do. The tool runs this on every apply, the light theme included, where `r` and `s` are {}: nothing is applied
     there, so the look stays as shipped and the status-bar color goes back to the one the page carries. */
  function onApply(r, s, set, addClass, engine) {
    if (!r || !r.card || !isDark()) { setMeta(null); return; }
    var base = engine.ship().card;
    if (base && r.card !== base) {          /* the card moved (set, or following a set page background): the raised surfaces move by the same step */
      var d = rgb(r.card).map(function (x, i) { return x - rgb(base)[i]; });
      SHIFTED.forEach(function (n) { if (surfaces[n]) set(n, hex(rgb(surfaces[n]).map(function (x, i) { return x + d[i]; }))); });
    }
    if (s.disbg || s.disfg) {               /* the pair goes together, and the fade comes off: the button is exactly these two colors */
      set("--dis-bg", r.disbg);
      set("--dis-fg", r.disfg);
      set("--dis-op", "1");
    }
    setMeta(s.bg);
  }

  /* the panel reads the tokens --bg --card --line --fg --mut --ibd --ifill; sala names its own differently, so they are aliases (and follow an
     inline override of the token they point at). The .ct-prev rules below give the preview strip the three looks sala scopes to a page region
     (the title bar's badge, the overview's effort tag): the same declarations as style.css and sessions.css, held equal by the wiring test. */
  var CSS = [
    ":root{--card:var(--panel);--line:var(--border);--fg:var(--text);--mut:var(--muted);--ibd:var(--faint);--ifill:var(--bg)}",
    ".ct-prev .pill{display:inline-flex;align-items:center;height:22px;padding:0 9px;border-radius:999px;border:1px solid color-mix(in srgb, var(--text) 30%, transparent);background:var(--hover);color:var(--text);font-weight:500;white-space:nowrap}",
    ".ct-prev .pill.role-front{color:var(--label-fg, var(--role-front-text));border-color:var(--label-bd, color-mix(in srgb, var(--accent-solid, var(--call)) 70%, transparent));background:var(--label-bg, color-mix(in srgb, var(--accent-solid, var(--call)) 12%, var(--bg)));font-weight:600}",
    ".ct-prev{--eff-max-bg:var(--label-bg, var(--accent-solid, var(--accent)));--eff-max-text:var(--label-fg, var(--accent-on-solid, var(--accent-text)))}",
    ".ct-prev .sp-tag{display:inline-flex;align-items:center;height:20px;padding:0 7px;border-radius:5px;font-size:12px;font-weight:500;line-height:1}",
    ".ct-prev .sp-eff.eff-max{color:var(--eff-max-text);background:var(--eff-max-bg);box-shadow:inset 0 0 0 1px var(--label-bd, transparent)}"
  ].join("\n");

  /* sala's real buttons and labels, drawn with its real classes: the update banner and its main button, the send button (enabled and
     disabled), the secondary Shell button, the unread count, the front badge, the "max" effort tag and a link. Trusted, inert markup. */
  var SEND = '<svg viewBox="0 0 20 20" width="16" height="16" aria-hidden="true"><path d="M10 16V4M5 9l5-5 5 5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  var PREVIEW = [
    '<div class="banner"><span>sala was updated.</span><button type="button">Reload</button></div>',
    '<button type="button" class="send-btn" aria-label="Send">' + SEND + '</button>',
    '<button type="button" class="send-btn" aria-label="Send (disabled)" disabled>' + SEND + '</button>',
    '<button type="button" class="shell-btn">Shell</button>',
    '<span class="ucount">3</span>',
    '<span class="pill role-front">front</span>',
    '<span class="sp-tag sp-eff eff-max">max</span>',
    '<span class="md"><a href="#sessions">a link</a></span>'
  ].join("");

  var cfg = {
    storageKey: "sala-colortry",
    gate: "warn",
    isDark: isDark,
    shipped: shipped,
    vars: {
      bg: ["--bg", "--side-bg"], card: ["--panel"], fg: ["--text"], mut: ["--muted"], line: ["--border"], ibd: ["--faint"],
      link: ["--link", "--call", "--accent", "--role-front-text", "--acc"], solid: ["--accent-solid"], onsolid: ["--accent-on-solid"],
      labbg: ["--label-bg"], labfg: ["--label-fg"], labbd: ["--label-bd"], disbg: ["--dis-bg"], disfg: ["--dis-fg"]
    },
    onApply: onApply,
    css: CSS,
    text: {
      note: "Dark theme only. The look you apply is kept in this browser; saved combinations are kept by this server.",
      example: "#f0a06a"            /* sala's own accent, the example in the 'six digits' hint */
    },
    mount: "#side-colors",
    preview: PREVIEW,
    api: "api/colors/combos"
  };

  /* index.html calls SalaColors.init() at the end of its body; terminal.html never does */
  window.SalaColors = { cfg: cfg, init: function () { CT.init(cfg); } };
  CT.applyStored(cfg);
})();
