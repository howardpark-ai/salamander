"use strict";
/* The language of the interface text (English by default, Korean on request) and the one place that turns a key into text.
   Only the interface switches: labels, buttons, titles, tooltips, placeholders, empty-state and status messages, dates and
   ages. What the person or a session wrote (the chat, the terminal, session and project names, file paths, commands) and
   what the server passes through (an API error text) is shown as it is.

   Three files make the table, loaded before every script that draws text:
     i18n-en.js   window.SALA_I18N_EN   key -> English text. A key's English is the source of truth; the static markup
                                         carries the same words, which tests/test_i18n.py holds equal.
     i18n-ko.js   window.SALA_I18N_KO   key -> Korean text, the only file with Korean in it (every character \u-escaped).
     i18n.js      this file             the lookup, the language, the applier for static markup, the date and number formats.

   tl(key, vars)  The text for a key in the active language. {name} in the text is replaced from vars. A key with a count
                  (vars.n, a number) has one entry per plural form, "<key>.one" and "<key>.other" in English; Korean has the
                  one form "<key>.other". A key the active language lacks falls back to English, then to the key itself.
   Static markup is translated in place from attributes: data-i18n (the element's text), data-i18n-title, data-i18n-placeholder
   data-i18n-aria-label and data-i18n-word (the data-word a style rule draws with content: attr(data-word)) (data-i18n-vars holds the {name} values as JSON; tx() writes the attributes for an element built in
   script). An element that holds other elements (an icon, a checkbox) wraps its words in a span of their own.
   Text built in script calls tl() when it is drawn and is drawn again on a language change: a module that keeps what it drew
   registers a function with SalaI18n.onChange(fn) that draws it again from what it already holds (no new request). */
const SalaI18n = (() => {
  const EN = window.SALA_I18N_EN || {}, KO = window.SALA_I18N_KO || {};
  const tables = { en: EN, ko: KO };
  const LOCALE = { en: "en-US", ko: "ko-KR" };
  const PLURAL = { en: (n) => (n === 1 ? "one" : "other"), ko: () => "other" };
  const norm = (l) => (l === "ko" ? "ko" : "en");
  const ATTRS = [["data-i18n-title", "title"], ["data-i18n-placeholder", "placeholder"], ["data-i18n-aria-label", "aria-label"], ["data-i18n-word", "data-word"]];
  let lang = norm(document.documentElement.getAttribute("lang"));   // the served page names the saved language: no flash of the other
  const listeners = [];

  const fill = (s, vars) => (vars ? s.replace(/\{(\w+)\}/g, (m, k) => (Object.hasOwn(vars, k) && vars[k] != null ? String(vars[k]) : m)) : s);
  function find(table, lng, key, n) {
    if (typeof n === "number") {
      const cat = PLURAL[lng](n);
      if (Object.hasOwn(table, key + "." + cat)) return table[key + "." + cat];
    }
    return Object.hasOwn(table, key) ? table[key] : undefined;
  }
  function t(key, vars) {
    const n = vars && typeof vars.n === "number" ? vars.n : undefined;
    let s = find(tables[lang], lang, key, n);
    if (s === undefined && lang !== "en") s = find(EN, "en", key, n);
    return fill(s === undefined ? key : s, vars);
  }

  /* the words of the static markup, in place; `root` is the document or a part of it that was just added. data-i18n-arg is the one
     value {arg} stands for in that element's texts (a name the server put in the page) */
  const argOf = (e) => {
    let v;
    if (e.hasAttribute("data-i18n-vars")) { try { v = JSON.parse(e.getAttribute("data-i18n-vars")); } catch { v = undefined; } }
    return e.hasAttribute("data-i18n-arg") ? { ...v, arg: e.getAttribute("data-i18n-arg") } : v;
  };
  /* attributes for an element drawn by script, so that a language change words it again in place with no redraw of its own:
     el("span", { ...tx("key", { n: 3 }) }), or tx("key", vars, "title") for the title ("aria-label" and "placeholder" likewise) */
  const KIND = { text: ["text", "data-i18n"], title: ["title", "data-i18n-title"], "aria-label": ["aria-label", "data-i18n-aria-label"], placeholder: ["placeholder", "data-i18n-placeholder"] };
  function attrs(key, vars, kind = "text") {
    const [target, mark] = KIND[kind];
    const a = { [target]: t(key, vars), [mark]: key };
    if (vars) a["data-i18n-vars"] = JSON.stringify(vars);
    return a;
  }
  function apply(root) {
    const r = root || document;
    const own = r.nodeType === 1 ? [r] : [];
    for (const e of [...own, ...r.querySelectorAll("[data-i18n]")]) if (e.hasAttribute("data-i18n")) e.textContent = t(e.getAttribute("data-i18n"), argOf(e));
    for (const [attr, target] of ATTRS) {
      for (const e of [...own, ...r.querySelectorAll("[" + attr + "]")]) if (e.hasAttribute(attr)) e.setAttribute(target, t(e.getAttribute(attr), argOf(e)));
    }
  }
  function paintToggle() {
    for (const b of document.querySelectorAll(".side-lang [data-lang]")) b.setAttribute("aria-pressed", String(b.dataset.lang === lang));
  }
  function setLang(next) {
    next = norm(next);
    if (next === lang) return false;
    lang = next;
    document.documentElement.setAttribute("lang", lang);
    apply(document);
    paintToggle();
    for (const fn of listeners.slice()) { try { fn(lang); } catch (e) { console.error("language change:", e); } }
    return true;
  }
  const onChange = (fn) => { listeners.push(fn); };

  /* the Intl locale for dates and numbers in the active language (the zone is shared.js's, applied by its zoneFormat) */
  const locale = () => LOCALE[lang];
  const number = (n, opts) => new Intl.NumberFormat(LOCALE[lang], opts).format(n);

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", () => { apply(document); paintToggle(); });
  else { apply(document); paintToggle(); }

  return { get lang() { return lang; }, t, attrs, apply, setLang, onChange, locale, number, norm, tables };
})();
const tl = SalaI18n.t, tx = SalaI18n.attrs;
