"""static/attach.js on its own: the attachment part of the composer, usable by a page that has no app.js.

The page copies attach.js and attach.css and hands the module a config object (web/README.md, "The attachment module"). So the
module must name nothing of app.js (`el`, `$`, `state`, `tl`, `apiFetch`), and a page that loads only attach.js must be able to
create an instance, attach a file and clear it. The first part reads the files and always runs; the page part runs in a headless
Chromium when one is installed (conftest.py: `browser`), on a blank page that loads nothing but the module's source.
"""

from __future__ import annotations

import json
import re

from sala_web.app import STATIC

ATTACH_JS = (STATIC / "attach.js").read_text()
INDEX = (STATIC / "index.html").read_text()


def test_the_module_names_nothing_of_the_page_it_is_copied_from():
    code = re.sub(r"/\*.*?\*/", "", ATTACH_JS, flags=re.S)
    code = "\n".join(re.sub(r"(?<!:)//.*", "", line) for line in code.splitlines())
    for word in (r"\bstate\b", r"\$\(", r"\bel\(", r"\btl\(", r"\btx\(", r"\bapiFetch\b", r"\bsetStatus\b", r"\bSalaI18n\b", r"\bSalaSignin\b",
                 r"\bcm6Composer\b", r"\bgetText\b", r"getElementById"):
        assert not re.search(word, code), word
    assert ATTACH_JS.count("window.SalaAttach =") == 1


def test_the_page_loads_the_module_before_app_js_and_its_sheet_with_the_others():
    assert INDEX.index('src="static/attach.js') < INDEX.index('src="static/app.js')
    assert 'href="static/attach.css?v={{sv}}"' in INDEX
    css = (STATIC / "attach.css").read_text()
    for rule in (".attach-btn", ".attach-menu", ".chip.file", ".fc-bar", ".attach-chips"):
        assert rule in css, rule
    sheet = (STATIC / "style.css").read_text()
    assert ".attach-btn" not in sheet and ".chip.file" not in sheet   # one copy of the rules


PAGE = """(() => {
  document.body.innerHTML = '<div id="chipsHost"></div><div class="row" style="position:relative"><div id="ed"></div></div>';
  const calls = [], changes = [], statuses = [];
  window.__calls = calls; window.__changes = changes; window.__statuses = statuses;
  const host = document.querySelector(".row");
  const att = SalaAttach.create(host, {
    endpoint: "up", chipsEl: document.getElementById("chipsHost"),
    fetch: async (url, opts) => { calls.push([url, opts.method, opts.headers["Content-Type"]]);
      return { ok: true, statusText: "", json: async () => ({ ok: true, name: "ref-" + calls.length }) }; },
    limits: { perFile: 5, maxFiles: 2 },
    onChange: (u) => changes.push(u.length), onStatus: (m, k) => statuses.push([typeof m === "function" ? m() : m, k]),
    isBusy: () => false, dropTarget: window,
    renderSend: (slot) => { const b = document.createElement("button"); b.id = "mysend"; slot.append(b); },
  });
  window.__att = att;
  return { appGlobals: [typeof state, typeof el, typeof $, typeof tl, typeof apiFetch], limits: att.limits };
})()"""

WAIT = """new Promise((res) => { const t0 = Date.now(); (function poll() {
  const up = document.querySelectorAll(".chip.uploading");
  if (!up.length || Date.now() - t0 > 10000) res(null); else setTimeout(poll, 50); })(); })"""


def test_a_page_with_no_app_js_creates_an_instance_and_attaches(browser):
    browser.open("about:blank")
    browser.evaluate("(0, eval)(" + json.dumps(ATTACH_JS) + "); typeof SalaAttach.create")
    got = browser.evaluate(PAGE)
    assert got["appGlobals"] == ["undefined"] * 5, got
    assert got["limits"]["perFile"] == 5 and got["limits"]["perImageSource"] == 20 * 1024 * 1024, got   # the rest keep their defaults
    # the pieces the module put in its host, in order, with the page's send button in the slot at the end
    shape = browser.evaluate("""(() => { const row = document.querySelector(".row");
      return { kids: [...row.children].map((n) => n.id || n.className), send: document.querySelector(".attach-send > #mysend") !== null,
               label: document.getElementById("attach").getAttribute("aria-label"), menu: document.getElementById("attach-photos").textContent,
               chips: document.getElementById("chipsHost").className }; })()""")
    assert shape["kids"] == ["attach", "attach-menu", "file-input", "photo-input", "ed", "attach-send"], shape
    assert shape["send"] and shape["label"] == "Attach files" and shape["menu"] == "Photos and videos", shape   # English built in
    assert shape["chips"] == "attach-chips"
    # an image goes up through the page's fetch and shows as a chip; a second hits maxFiles; the third is a file over perFile
    browser.evaluate("""(async () => { const png = () => new File([new Uint8Array(4)], "a.png", { type: "image/png" });
      await __att.add([png()]); await __att.add([png()]); await __att.add([png()]); return 1; })()""", timeout_ms=30000)
    browser.evaluate(WAIT, timeout_ms=30000)
    got = browser.evaluate("""({ calls: __calls, names: __att.getUploads().map((u) => u.name), chips: document.querySelectorAll(".chip").length,
      statuses: __statuses, status: document.querySelector(".attach-status") })""")
    assert got["calls"] == [["up", "POST", "image/png"], ["up", "POST", "image/png"]], got
    assert got["names"] == ["ref-1", "ref-2"] and got["chips"] == 2, got
    assert got["statuses"] == [["Not attached: at most 2 files.", "error"]], got
    # a file over perFile is refused before any request, with the words and the chip's error
    browser.evaluate("__att.clear(); __att.limits.maxFiles = 9; __att.add([new File(['123456789'], 'big.txt', { type: 'text/plain' })]); 1")
    got = browser.evaluate("""({ meta: document.querySelector(".chip.file .fc-meta").textContent, failed: !!document.querySelector(".chip.file.failed"),
      uploading: __att.isUploading(), calls: __calls.length })""")
    assert got["meta"] == "Failed: too large (9 B; the limit is 5 B)" and got["failed"] and not got["uploading"] and got["calls"] == 2, got
    # clear() empties the chips and tells the page
    browser.evaluate("__att.clear(); 1")
    assert browser.evaluate("[document.querySelectorAll('.chip').length, __att.getUploads().length, __changes[__changes.length - 1]]") == [0, 0, 0]


def test_bind_paste_attaches_a_paste_once_on_a_plain_editable(browser):
    browser.open("about:blank")
    browser.evaluate("(0, eval)(" + json.dumps(ATTACH_JS) + "); 1")
    browser.evaluate(PAGE)
    got = browser.evaluate("""(async () => {
      const ta = document.createElement("textarea"); document.body.append(ta);
      __att.bindPaste(ta);
      const dt = new DataTransfer(); dt.items.add(new File([new Uint8Array(4)], "p.png", { type: "image/png" }));
      const ev = new ClipboardEvent("paste", { clipboardData: dt, bubbles: true, cancelable: true });
      ta.dispatchEvent(ev);
      // the same gesture's beforeinput carries the same bytes under another File: the earlier link keeps it from a second chip
      const dt2 = new DataTransfer(); dt2.items.add(new File([new Uint8Array(4)], "p.png", { type: "image/png" }));
      ta.dispatchEvent(new InputEvent("beforeinput", { inputType: "insertFromPaste", dataTransfer: dt2, bubbles: true, cancelable: true }));
      await new Promise((r) => setTimeout(r, 300));
      return { prevented: ev.defaultPrevented, chips: document.querySelectorAll(".chip").length }; })()""", timeout_ms=30000)
    assert got["prevented"] is True, got
    assert got["chips"] == 1, got
