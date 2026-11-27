"""The reply rules in the page (static/shared.js MD_PURIFY, mdAttr, mdStyle and mdFitStyle; app.js mdSanitize, mdEdges and
mdFit; style.css .md; test_md_rules.py runs the rules in node). The real DOMPurify and the real layout in a headless Chromium (conftest.py:
`served`, `browser`; skipped without one).

A reply that tries each way out of its box changes nothing outside it: no pixel, no place or size, no computed style, nothing
in the top layer, and a stand-in for a frame drawn on the chat page is what a tap on it finds. A reply draws no control of the
page's, answers to none of its names and moves none of its drawings. What a session writes (markdown, drawings, video, audio,
formulas, its own colours) lays out where it did without the containment. No reply box scrolls sideways: what is wide
comes down to it or wraps, and what still does not fit is cut at its edge. A video's controls still offer full screen and
picture in picture.
"""

from __future__ import annotations

import json

from conftest import CHAT_READY, NAME, transcript_file, transcript_line
from test_md_rules import CORPUS

RED = "background:rgb(255,0,0)"
# each a way for what a reply draws to reach past its box; the words above give the box a height of its own
ESCAPES = {
    "fixed": f'<div style="position:fixed;inset:0;z-index:2147483647;{RED}">a</div>',
    "absolute": f'<div style="position:absolute;top:-3000px;left:-3000px;width:9000px;height:9000px;z-index:2147483647;{RED}">a</div>',
    "margin": f'<div style="position:relative;z-index:2147483647;margin:-600px -600px 0 -600px;height:900px;{RED}">a</div>',
    "transform": f'<div style="position:relative;z-index:2147483647;transform:scale(60);width:60px;height:24px;{RED}">a</div>',
    "shadow": '<div style="position:relative;z-index:2147483647;height:20px;box-shadow:0 0 0 2000px rgb(255,0,0);outline:900px solid rgb(255,0,0)">a</div>',
    "filter": f'<div style="height:20px;{RED};filter:drop-shadow(0 200px 0 rgb(255,0,0)) drop-shadow(0 -200px 0 rgb(255,0,0))">a</div>',
    "sticky": f'<div style="position:sticky;top:-500px;margin-top:-500px;height:900px;z-index:2147483647;{RED}">a</div>',
    "glyph": '<div style="position:relative;z-index:2147483647;font-size:900px;line-height:20px;height:20px;color:rgb(255,0,0)">&#9608;&#9608;</div>',
    "svg": ('<svg width="40" height="20" style="overflow:visible;position:relative;z-index:2147483647">'
            '<rect x="-2000" y="-2000" width="5000" height="5000" fill="rgb(255,0,0)"/></svg>'),
    "animation": ('<svg width="40" height="20" style="overflow:visible"><rect width="10" height="10" fill="rgb(255,0,0)">'
                  '<animateTransform attributeName="transform" type="scale" values="1;900" dur="0.05s" fill="freeze"/></rect></svg>'),
}
# the ways that reach outside without the containment: the check below sees each of them when it is switched off
SEEN_WITHOUT = ("fixed", "absolute", "margin", "transform", "shadow", "svg", "animation")

# each a way for a reply to act, restyle, open over the page or answer to one of its names
ACTS = """Words of the reply.

<style>body, #chat, #sidebar, .msg, iframe { display: none !important; background: rgb(255, 0, 0) !important }</style>

<svg width="20" height="20"><style>body { background: rgb(255, 0, 0) !important } iframe { visibility: hidden }</style><rect width="9" height="9"/></svg>

<link rel="stylesheet" href="/nowhere.css"><meta http-equiv="refresh" content="0;url=/nowhere"><base href="https://example.invalid/">

<form id="composer" action="/nowhere"><label for="input">name</label><input type="text" name="who"><input type="submit" value="Yes">
<textarea>typed</textarea><select><option>first</option></select><button type="submit">Approve</button></form>

<div popover id="pop">popover words</div> <div popover="manual">more</div> <span commandfor="pop" command="show-popover" interestfor="pop">opener</span>

<dialog open style="position:fixed;inset:0">open words</dialog><dialog>closed words</dialog>

<div id="chat" class="msg assistant md footer sess-more tab brand" data-uuid="a-md" data-i18n="app.copied" data-t="0" data-tool-id="toolu_probe" accesskey="k" contenteditable="true" autofocus tabindex="7" style="cursor:url(/nowhere.png),auto;-webkit-user-modify:read-write;anchor-name:--a;view-transition-name:v;overlay:auto">named words</div>

<input type="checkbox" disabled checked name="ns-role" id="input"> <input type="radio" name="ns-role" checked>

<svg width="40" height="20" cursor="url(/nowhere.png), pointer"><a href="https://example.com/in-svg"><text y="15">go</text></a></svg>

<img src="https://example.invalid/m.png" usemap="#nav" alt="map" width="40" height="20"><map name="nav"><area shape="rect" coords="0,0,10,10" href="#sessions"></map>

<math><mrow href="https://example.invalid/m"><mi>x</mi></mrow></math>

<video controls autopictureinpicture width="120" height="60"></video>

<template shadowrootmode="open"><style>:host { position: fixed }</style></template>

<a href="#sessions">in-app link</a> [markdown link](https://example.com/md)

After.
"""

# a page for the checks: filler to scroll in, a frame under the reply and one over the page, a drawing of the page's own
SETUP = r"""(() => {
  const calm = document.createElement("style");   // the page's own motion off, so two looks at it can be compared
  calm.textContent = "*, *::before, *::after { animation: none !important; transition: none !important; caret-color: transparent !important }" +
    "#jump { display: none !important }";   // the page's jump-to-latest button comes and goes with the scroll
  document.head.append(calm);
  const chat = document.getElementById("chat");
  const block = (h, id) => { const d = document.createElement("div"); d.id = id; d.style.height = h + "px"; return d; };
  const frame = (id, css) => { const f = document.createElement("iframe"); f.id = id; f.srcdoc = "<button>Yes</button> <button>No</button>";
    f.style.cssText = "display:block;border:0;background:white;" + css; return f; };
  const mine = document.createElementNS("http://www.w3.org/2000/svg", "svg"); mine.id = "t-svg"; mine.setAttribute("width", "20"); mine.setAttribute("height", "20");
  mine.innerHTML = '<rect id="t-rect" width="10" height="10" fill="blue"/>';
  const before = block(500, "t-before"), under = frame("t-under", "width:100%;height:70px"), after = block(600, "t-after");
  chat.append(before, under, mine, after);
  document.body.append(frame("t-top", "position:fixed;left:0;top:0;width:390px;height:60px;z-index:1000"));
  const raf = () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  const PROPS = ["display", "visibility", "position", "color", "backgroundColor", "opacity", "transform", "filter", "cursor", "zIndex",
                 "pointerEvents", "fontFamily", "fontSize", "borderTopColor", "overflowX"];
  const outside = () => [...document.querySelectorAll("html, body, body *")].filter((e) => !e.closest(".t-msg"));
  const looks = (list) => list.map((e) => { const s = getComputedStyle(e); return PROPS.map((p) => s[p]).join("|"); });
  const inside = (x, y, r) => x >= Math.floor(r.left) && x < Math.ceil(r.right) && y >= Math.floor(r.top) && y < Math.ceil(r.bottom);
  const T = window.T = { msg: null, was: null };
  T.put = async (text, last = false) => {
    T.msg?.remove(); T.msg = null;
    under.scrollIntoView({ block: "end" }); await raf(); await new Promise((r) => setTimeout(r, 100));   // as scrolled as after
    const list = outside(); T.was = { list, looks: looks(list), sheets: document.styleSheets.length, focus: document.activeElement, hash: location.hash,
      composer: document.getElementById("composer"), role: document.querySelector('input[name="ns-role"]:checked')?.value ?? null };
    const m = T.msg = el("div", { class: "msg assistant t-msg" });
    m.append(...replyNodes(text, last));
    chat.insertBefore(m, under);
    await new Promise((r) => setTimeout(r, 300));
    under.scrollIntoView({ block: "end" }); await raf();
    return boxes();
  };
  const boxes = () => [...T.msg.querySelectorAll(":scope > .md")].map((d) => d.getBoundingClientRect().toJSON());
  // red pixels of a screenshot, inside the reply's boxes and outside them
  T.red = async (png) => {
    const bytes = Uint8Array.from(atob(png), (c) => c.charCodeAt(0));
    const img = await createImageBitmap(new Blob([bytes], { type: "image/png" }));
    const c = new OffscreenCanvas(img.width, img.height), g = c.getContext("2d"); g.drawImage(img, 0, 0);
    const px = g.getImageData(0, 0, img.width, img.height).data, out = { inside: 0, outside: 0, first: null, size: [img.width, img.height] };
    const held = boxes();
    for (let y = 0; y < img.height; y++) for (let x = 0; x < img.width; x++) {
      const i = (y * img.width + x) * 4;
      if (px[i] < 240 || px[i + 1] > 20 || px[i + 2] > 20) continue;
      if (held.some((r) => inside(x, y, r))) out.inside++; else { out.outside++; out.first ||= [x, y]; }
    }
    return out;
  };
  // what a tap finds outside the reply's boxes, and on the two frames
  T.hits = () => {
    const strays = [], frames = {}, held = boxes(), pane = document.getElementById("chat-pane").getBoundingClientRect();
    for (let y = 3; y < innerHeight; y += 9) for (let x = 3; x < innerWidth; x += 9) {
      if (held.some((r) => inside(x, y, r))) continue;
      const e = document.elementFromPoint(x, y);
      if (e && T.msg.contains(e) && e.closest(".md")) strays.push([x, y, e.localName]);
    }
    for (const id of ["t-top", "t-under"]) {
      const r = document.getElementById(id).getBoundingClientRect(), pts = [];
      for (const fx of [.05, .5, .95]) for (const fy of [.1, .5, .9]) {
        const x = r.left + r.width * fx, y = r.top + r.height * fy;
        if (id === "t-under" && !inside(x, y, pane)) continue;   // the frame in the chat shows only inside the pane
        const e = document.elementFromPoint(x, y);
        pts.push(e && T.msg.contains(e) ? "reply " + e.localName : e?.id ?? null);
      }
      frames[id] = pts;
    }
    return { strays: strays.slice(0, 5), frames };
  };
  // the page around the reply against the same page with each box emptied and held at its size
  T.outside = async () => {
    const pane = document.getElementById("chat-pane");
    const read = () => ({ rects: outside().map((e) => { const r = e.getBoundingClientRect(); return [e.id || e.localName, r.x, r.y, r.width, r.height].join(" "); }),
      scroll: [pane.scrollWidth, pane.scrollHeight, pane.scrollTop, pane.clientWidth, document.documentElement.scrollWidth, document.documentElement.scrollHeight] });
    const now = looks(T.was.list);
    const restyled = T.was.list.map((e, i) => (e.isConnected && now[i] !== T.was.looks[i] ? [e.id || e.localName, T.was.looks[i], now[i]] : null))
      .filter(Boolean).slice(0, 5);
    const full = read(), kept = [...T.msg.querySelectorAll(":scope > .md")].map((d) => [d, [...d.childNodes], d.getBoundingClientRect().height]);
    for (const [d, , h] of kept) { d.replaceChildren(); d.style.height = h + "px"; }
    await raf();
    const empty = read();
    for (const [d, nodes] of kept) { d.style.removeProperty("height"); d.append(...nodes); }   // the reply as it was, for more checks
    return { restyled, sheets: [T.was.sheets, document.styleSheets.length], moved: full.rects.filter((r, i) => r !== empty.rects[i]).slice(0, 5),
             count: [full.rects.length, empty.rects.length], scroll: [full.scroll, empty.scroll] };
  };
  return "ready";
})()"""


def write_reply(served, text: str):
    transcript_file(served).write_text(transcript_line("assistant", [{"type": "text", "text": text}], "a-md",
                                                       model="claude-opus-5-5"))


def open_session(browser, served, text: str = "hello"):
    write_reply(served, text)
    browser.open(f"{served['url']}/#s={NAME}")
    browser.wait_ready(CHAT_READY)


def staged(browser, served):
    open_session(browser, served)
    browser.settle("document.getElementById('chat')")
    assert browser.evaluate(SETUP) == "ready"


def put(browser, text: str, last: bool = False) -> list[dict]:
    return browser.evaluate(f"T.put({json.dumps(text)}, {json.dumps(last)})")


def red(browser) -> dict:
    png = browser.send("Page.captureScreenshot", {"format": "png"})["data"]
    return browser.evaluate(f"T.red({json.dumps(png)})")


def holds(browser, name: str):
    """Nothing outside the boxes of the reply now on the page has changed."""
    seen = red(browser)
    assert seen["size"] == [390, 844] and seen["outside"] == 0, (name, "painted outside the box", seen)
    hits = browser.evaluate("T.hits()")
    assert hits["strays"] == [], (name, "a tap outside the box finds the reply", hits)
    for frame, found in hits["frames"].items():
        assert frame in found and not [f for f in found if str(f).startswith("reply")], (name, "the reply lies over a frame", frame, found)
    layer = browser.evaluate("""({ open: document.querySelectorAll(":popover-open, :modal").length, full: !!document.fullscreenElement,
      overlay: [...T.msg.querySelectorAll("*")].filter((e) => (getComputedStyle(e).overlay || "none") !== "none").length })""")
    assert layer == {"open": 0, "full": False, "overlay": 0}, (name, layer)
    got = browser.evaluate("T.outside()")
    assert got["restyled"] == [] and got["sheets"][0] == got["sheets"][1], (name, "the page is restyled", got)
    assert got["count"][0] == got["count"][1] and got["moved"] == [], (name, "the page around the box moved", got)
    assert got["scroll"][0] == got["scroll"][1], (name, "the reply stretches what scrolls", got)


def test_nothing_a_reply_draws_leaves_its_box(served, browser):
    staged(browser, served)
    for name, html in ESCAPES.items():
        boxes = put(browser, f"Case {name}, words of the reply.\n\nMore words.\n\n{html}\n")
        assert len(boxes) == 1 and boxes[0]["height"] > 20 and 60 < boxes[0]["top"] and boxes[0]["bottom"] < 844, (name, boxes)
        assert red(browser)["inside"] > 0, (name, "the case drew nothing: it proves nothing")
        holds(browser, name)


def test_the_check_sees_each_way_out_when_the_box_holds_nothing(served, browser):
    """The same cases with the containment switched off paint outside the box, so the test above can fail."""
    staged(browser, served)
    for name in SEEN_WITHOUT:
        put(browser, f"Case {name}, words of the reply.\n\nMore words.\n\n{ESCAPES[name]}\n")
        browser.evaluate("""new Promise((r) => { for (const d of T.msg.querySelectorAll(".md")) { d.style.contain = "none"; d.style.overflow = "visible"; }
          requestAnimationFrame(() => requestAnimationFrame(() => r(""))); })""")
        assert red(browser)["outside"] > 0, name


def test_a_reply_neither_acts_on_the_page_nor_answers_to_its_names(served, browser):
    staged(browser, served)
    put(browser, ACTS)
    holds(browser, "acts")
    got = browser.evaluate("""(() => { const m = T.msg, all = [...m.querySelectorAll("*")], q = (s) => [...m.querySelectorAll(s)];
      for (const e of all) { try { e.showPopover?.(); } catch {} try { e.showModal?.(); } catch {} }
      return {
        text: m.textContent,
        tags: q("style, link, meta, base, form, select, textarea, dialog, iframe, object, embed, button:not(.code-copy)").map((e) => e.localName),
        inputs: q("input").map((i) => [i.type, i.disabled]),
        named: q("[id], [name]").map((e) => e.getAttribute("id") ?? e.getAttribute("name")).filter((v) => !/^md\\d+-/.test(v)),
        classes: q(".md [class]").map((e) => e.getAttribute("class")).filter((c) => !/^(md-start|md-end| )+$/.test(c)),
        attrs: [...new Set(all.flatMap((e) => e.getAttributeNames()))].filter((n) => /^(data-|on)|^(popover|command|commandfor|interestfor|autofocus|accesskey|contenteditable|for|autopictureinpicture)$/.test(n)),
        open: document.querySelectorAll(":popover-open, :modal").length,
        editable: all.filter((e) => e.isContentEditable || ![undefined, "read-only"].includes(getComputedStyle(e).webkitUserModify)).length,
        pictures: all.filter((e) => getComputedStyle(e).cursor.includes("url(")).length,
        focus: document.activeElement === T.was.focus, ahead: q("[tabindex]").filter((e) => e.tabIndex > 0).length,
        composer: document.getElementById("composer") === T.was.composer && !!T.was.composer,
        chat: document.querySelectorAll("#chat").length,
        role: (document.querySelector('input[name="ns-role"]:checked')?.value ?? null) === T.was.role,
        links: q("a, area").map((a) => [a.localName, a.getAttribute("target"), a.getAttribute("rel")]),
        math: q("math [href], math[href]").length,
        usemap: [m.querySelector("img").getAttribute("usemap"), "#" + m.querySelector("map").getAttribute("name")],
        video: m.querySelector("video").getAttributeNames().sort(),
        sheets: document.styleSheets.length - T.was.sheets, moved: location.hash !== T.was.hash,
      }; })()""")
    assert got["tags"] == [] and got["inputs"] == [["checkbox", True]] and got["named"] == [] and got["classes"] == [] and got["attrs"] == [], got
    assert got["open"] == 0 and got["editable"] == 0 and got["pictures"] == 0 and got["focus"] and got["ahead"] == 0, got
    assert got["composer"] and got["chat"] == 1 and got["role"] and got["sheets"] == 0 and not got["moved"], got
    assert len(got["links"]) >= 4 and all(link[1:] == ["_blank", "noopener noreferrer"] for link in got["links"]), got["links"]
    assert got["math"] == 0 and got["usemap"][0] == got["usemap"][1] and got["video"] == ["controls", "height", "width"], got
    # what a dropped element said is still there to read; what was never on screen still is not
    for words in ("popover words", "open words", "named words", "typed", "first", "Approve", "opener", "After."):
        assert words in got["text"], words
    assert "closed words" not in got["text"] and "rgb(255, 0, 0)" not in got["text"], got["text"]
    assert browser.evaluate("""[...T.msg.querySelectorAll("*")].filter((e) => e.textContent === "popover words")
      .map((e) => getComputedStyle(e).display)""") == ["none"]


def test_a_reply_s_animation_moves_nothing_of_the_page_s(served, browser):
    staged(browser, served)
    where = """new Promise((r) => setTimeout(() => { const t = document.getElementById("t-rect").getBoundingClientRect(),
      s = document.getElementById("t-svg").getBoundingClientRect(); r([t.x - s.x, t.y - s.y, t.width, t.height]); }, 400))"""
    animation = ('<svg width="40" height="20"><animateTransform {href} attributeName="transform" type="scale" values="1;5" dur="0.05s" fill="freeze"/>'
                 '<animateMotion {href} path="M0 0 L50 50" dur="0.05s" fill="freeze"/></svg>')
    full = browser.evaluate("location.origin + location.pathname") + "#t-rect"
    still = browser.evaluate(where)
    for href in ('href="#t-rect"', 'xlink:href="#t-rect"', f'href="{full}"', f'xlink:href="{full}"'):
        put(browser, "Words.\n\n" + animation.format(href=href))
        got = browser.evaluate(where)
        assert got == still, (href, still, got)
        assert browser.evaluate("document.getElementById('t-rect').transform.animVal.numberOfItems") == 0, href
    # the same markup written into the page as it is does move the page's drawing, so the check above can fail
    moved = browser.evaluate(f"""new Promise((r) => {{ const d = document.createElement("div"); d.innerHTML = {json.dumps(animation.format(href='href="#t-rect"'))};
      document.getElementById("chat").append(d);
      setTimeout(() => r(document.getElementById("t-rect").transform.animVal.numberOfItems), 400); }})""")
    assert moved > 0


def test_a_reply_s_video_keeps_full_screen_and_picture_in_picture(served, browser):
    """Its controls offer both, as those of a video the page makes itself do: neither is switched off on the element, and full
    screen, asked for with the reader's tap, opens, covers the window and stays."""
    staged(browser, served)
    put(browser, "Words.\n\n<video controls width=\"120\" height=\"60\"></video>")
    ask = """(async (v) => { let asked = "ok"; try { await v.requestFullscreen(); } catch (e) { asked = e.name; }
      await new Promise((r) => setTimeout(r, 1500));
      const full = document.fullscreenElement === v, r = v.getBoundingClientRect();
      const covers = r.left <= 0 && r.top <= 0 && r.right >= innerWidth - 1 && r.bottom >= innerHeight - 1;
      if (document.fullscreenElement) await document.exitFullscreen();
      return { asked, full, covers, offered: [v.controls, v.controlsList.contains("nofullscreen"), v.disablePictureInPicture,
        v.hasAttribute("playsinline")] }; })"""

    def tapped(video: str) -> dict:
        r = browser.send("Runtime.evaluate", {"awaitPromise": True, "returnByValue": True, "userGesture": True,
                                              "expression": f"{ask}({video})"})
        return r["result"]["value"]

    got = tapped('T.msg.querySelector("video")')
    own = tapped('(() => { const v = document.createElement("video"); v.controls = true; v.width = 120; v.height = 60;'
                 ' document.getElementById("chat").append(v); return v; })()')
    assert own == {"asked": "ok", "full": True, "covers": True, "offered": [True, False, False, False]}, own
    assert got == own, (got, own)


# each wider than a phone's box in its own way; what is titled "fit" has to come down to the box or wrap, the rest is cut
LONG = "abcdefgh" * 120
WIDE = {
    "a width": '<div title="fit" style="width:3000px;text-align:right">far end</div>',
    "a width among other style": '<div title="fit" style="color: teal; width: 3000px; text-align:right">far end</div>',
    "a least width": '<div title="fit" style="min-width:3000px;text-align:right">far end</div>',
    "a drawing": '<svg title="fit" width="3000" height="200"><rect width="3000" height="200"/></svg>',
    "a drawing sized by style": '<svg title="fit" style="width:3000px" viewBox="0 0 300 20"><rect width="300" height="20"/></svg>',
    "a video": '<video title="fit" controls width="3000" height="1000"></video>',
    "a rule": '<hr title="fit" width="3000">',
    "a string": LONG,
    "a string in an element": f'<p title="fit">{LONG} <code>{LONG}</code></p>',
    "a link": "https://example.com/" + LONG,
    "a line held by style": f'<div title="fit" style="white-space:nowrap">{"word " * 120}</div>',
    "a line held by its tag": f'<nobr title="fit">{"word " * 120}</nobr>',
    "preformatted by style": f'<div title="fit" style="white-space:pre">{LONG}</div>',
    "a scroll box of its own": '<div style="overflow:auto;max-height:60px"><div style="position:relative;left:3000px">far</div></div>',
    "a scroll box up and down": '<div style="overflow-y:auto;max-height:60px"><div style="margin-left:3000px">far</div></div>',
    "a margin": '<div style="margin-left:3000px">far</div>',
    "placed out of the flow": f'<div style="position:absolute;left:0;width:3000px;white-space:nowrap">{LONG}</div>&nbsp;',
}
SIDEWAYS = r"""(() => {
  const boxes = [...T.msg.querySelectorAll(".md")], pane = document.getElementById("chat-pane");
  const moves = (e) => { e.scrollLeft = 1e6; const got = e.scrollLeft; e.scrollLeft = 0; return got; };
  return { overflow: boxes.map((d) => getComputedStyle(d).overflowX), moved: boxes.map(moves),
    // nothing in a reply, a table and a code block aside, is a box the reader can scroll sideways
    inner: boxes.flatMap((d) => [...d.querySelectorAll("*")]).filter((e) => !e.closest("table, pre") &&
      ["auto", "scroll"].includes(getComputedStyle(e).overflowX) && e.scrollWidth > e.clientWidth).map((e) => e.localName),
    fit: boxes.flatMap((d) => [...d.querySelectorAll('[title="fit"]')]).length,
    past: boxes.flatMap((d) => { const edge = d.getBoundingClientRect().right + 1;
      return [...d.querySelectorAll('[title="fit"]')].filter((e) => { const words = document.createRange(); words.selectNodeContents(e);
        return [e.getBoundingClientRect(), ...words.getClientRects()].some((r) => r.right > edge); }).map((e) => e.localName); }),
    page: [pane.scrollWidth <= pane.clientWidth, document.documentElement.scrollWidth <= innerWidth] };
})()"""


def test_no_reply_box_scrolls_sideways(served, browser):
    """At a phone's width, whatever a reply draws wide, in its body or its footer."""
    staged(browser, served)
    assert browser.evaluate("innerWidth") == 390
    cases = [(name, f"Words.\n\n{html}\n", False) for name, html in WIDE.items()]
    footer = f'Done.\n\nBoard:\n- {WIDE["a width"]}\n- {WIDE["a drawing"]}\n\nWrite-up: {LONG}'
    assert len(put(browser, footer, True)) == 2   # the body and the footer, each a box
    cases.append(("all in a footer", footer, True))
    off = {}
    for name, text, last in cases:
        put(browser, text, last)
        got = browser.evaluate(SIDEWAYS)
        assert got["overflow"] and got["fit"] == text.count('title="fit"'), (name, "a case lost its mark: it proves nothing", got)
        if set(got["overflow"]) != {"clip"} or any(got["moved"]) or got["inner"] or got["past"] or got["page"] != [True, True]:
            off[name] = got
    assert off == {}, off


def test_a_wide_drawing_and_video_shrink_whole_and_ones_that_fit_keep_their_size(served, browser):
    staged(browser, served)
    sizes = """[...T.msg.querySelectorAll("svg, video, rect")].map((e) => { const r = e.getBoundingClientRect(); return [r.width, r.height]; })"""
    drawn = '<svg width="{w}" height="{h}"><rect width="{w}" height="{h}"/></svg>\n\n<video controls width="{w}" height="{h}"></video>'
    put(browser, "Words.\n\n" + drawn.format(w=260, h=130))
    assert browser.evaluate(sizes) == [[260, 130]] * 3
    box = put(browser, "Words.\n\n" + drawn.format(w=3000, h=1500))[0]["width"]
    got = browser.evaluate(sizes)
    assert len(got) == 3 and all(abs(w - box) <= 1 and abs(h - box / 2) <= 1 for w, h in got), (box, got)


def test_a_wide_formula_is_drawn_smaller_to_show_whole(served, browser):
    """One that fits keeps its size, one a little too wide comes down to the box, and one several times the box's width is
    drawn at half size, where the box cuts it: none makes the box scroll."""
    staged(browser, served)
    formula = '<math{how}><mrow><mi>a</mi><mspace width="{w}px"></mspace><mi>b</mi></mrow></math>'
    shown = """[...T.msg.querySelectorAll("math")].map((m) => { const box = m.closest(".md").getBoundingClientRect();
      const parts = [...m.querySelectorAll("mi")].map((e) => e.getBoundingClientRect());
      return [Number(m.style.zoom || 1), Math.min(...parts.map((r) => r.left)) >= box.left - 1 && Math.max(...parts.map((r) => r.right)) <= box.right + 1]; })"""
    for how in ("", ' display="block"'):
        put(browser, "Words.\n\n" + formula.format(how=how, w=100))
        assert browser.evaluate(shown) == [[1, True]], how
        put(browser, "Words.\n\n" + formula.format(how=how, w=440))
        [[zoom, whole]] = browser.evaluate(shown)
        assert 0.5 < zoom < 1 and whole, (how, zoom, whole)
        put(browser, "Words.\n\n" + formula.format(how=how, w=3000))
        assert browser.evaluate(shown) == [[0.5, False]], how
        got = browser.evaluate(SIDEWAYS)
        assert got["overflow"] == ["clip"] and got["moved"] == [0] and got["page"] == [True, True], (how, got)


# what a session writes: markdown, with the nestings that put a margin at a box's edge, and the formatting a reply keeps
LOOKS = {
    **{k: v for k, v in CORPUS.items() if k != "html"},
    "loose list last": "Intro.\n\n- one\n\n- two\n\n  more of two",
    "loose list only": "- one\n\n- two",
    "nested list": "- a\n  - b\n    - c",
    "quote last": "Intro.\n\n> quoted\n>\n> its last paragraph",
    "list in quote": "> - x\n> - y",
    "quote in list": "- a\n\n  > b",
    "heading in quote": "> # Heading\n>\n> body",
    "small heading in quote": "> ###### Small\n\n> ## Second\n>\n> text",
    "heading in list": "- # Heading\n- b",
    "table in quote": "> | a | b |\n> |---|---|\n> | 1 | 2 |",
    "rule in quote": "> a\n>\n> ---",
    "code only": "```js\nlet a = 1;\n```",
    "code last": "Run it:\n\n```sh\nsala ls\n```",
    "code in list": "- item\n\n  ```js\n  code\n  ```",
    "code in quote": "> ```\n> code\n> ```",
    "colours": 'Words <span style="color: rgb(1, 2, 3); background: rgb(250, 250, 0)">coloured</span> and <font color="#08c">font</font>.',
    "drawing": ('Chart:\n\n<svg width="200" height="80" viewBox="0 0 200 80"><defs><linearGradient id="g"><stop offset="0" stop-color="#08c"/>'
                '<stop offset="1" stop-color="#0c8"/></linearGradient></defs><rect width="200" height="60" fill="url(#g)"/>'
                '<text x="4" y="76" font-size="12" style="fill: rgb(1, 2, 3)">label</text></svg>'),
    "media": '<video controls width="200" height="100"></video>\n\n<audio controls></audio>',
    "formula": 'The ratio <math><mfrac><mi>a</mi><mi>b</mi></mfrac></math> and\n\n<math display="block"><msqrt><mn>2</mn></msqrt></math>',
}
FOOTERS = {
    "footer": "Merged.\n\nBoard:\n- [item](https://example.com/1): in review\n\nWrite-up: none, the PR holds it.",
    "footer only": "Board item: no change.\nWrite-up: none.",
    "footer and ask": "Both are stale.\n\n- one\n\n- two\n\nBoard item: stale.\n\nDrop both? Answer here.",
}
PLACES = r"""(async (kind, text) => {
  const chat = document.getElementById("chat"), raf = () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  chat.querySelectorAll(".t-look").forEach((e) => e.remove());
  const near = (cls, words) => { const m = el("div", { class: "msg assistant t-look " + cls }); m.append(md(words)); return m; };
  const m = el("div", { class: "msg assistant t-look" });
  if (kind === "thinking") { const f = fold("thinking", [el("span", { text: "thinking" })], [md(text)]); f.open = true; m.append(f); }
  else m.append(...replyNodes(text, kind === "last"));
  const after = near("t-after", "after");
  chat.append(near("t-before", "before"), m, after);
  await Promise.all([...m.querySelectorAll("img")].map((i) => i.complete || new Promise((r) => { i.onload = i.onerror = r; setTimeout(r, 3000); })));
  await new Promise((r) => setTimeout(r, 200));
  await document.fonts.ready; await raf();
  const read = () => { const top = chat.querySelector(".t-before").getBoundingClientRect().top;
    return [after, m, ...m.querySelectorAll("*")].map((e) => { const r = e.getBoundingClientRect();
      return [e.localName, Math.round(r.x * 10) / 10, Math.round((r.y - top) * 10) / 10, Math.round(r.width * 10) / 10, Math.round(r.height * 10) / 10]; }); };
  const now = read();
  const cut = [...m.querySelectorAll(".md")].flatMap((d) => { const b = d.getBoundingClientRect();
    return [...d.querySelectorAll("*")].filter((e) => { const r = e.getBoundingClientRect();
      return r.width && (r.left < b.left - 1 || r.right > b.right + 1 || r.top < b.top - 1 || r.bottom > b.bottom + 1) && !e.closest("table, math, svg"); })
      .map((e) => e.localName); });
  const scrolls = [...m.querySelectorAll(".md")].filter((d) => d.scrollWidth > d.clientWidth ||
    d.scrollHeight > d.clientHeight + (d.classList.contains("footer") ? 3 : 1)).map((d) => [d.scrollWidth, d.clientWidth, d.scrollHeight, d.clientHeight]);
  // the same nodes with the containment and the edge margins taken off: the layout without them
  const off = document.createElement("style");
  off.textContent = ".t-look .md { contain: none !important; overflow: visible !important }";
  document.head.append(off);
  for (const d of chat.querySelectorAll(".t-look .md")) { d.style.removeProperty("--md-start"); d.style.removeProperty("--md-end");
    for (const e of d.querySelectorAll(".md-start, .md-end")) e.classList.remove("md-start", "md-end"); }
  await raf();
  const was = read(); off.remove();
  return { now, was, cut, scrolls };
})"""


def test_what_a_session_writes_lays_out_as_it_did(served, browser):
    open_session(browser, served)
    browser.settle("document.getElementById('chat')")
    cases = [("plain", k, v) for k, v in LOOKS.items()] + [("last", k, v) for k, v in FOOTERS.items()]
    cases += [("thinking", f"thinking {k}", LOOKS[k]) for k in ("loose list last", "quote last", "code last", "heading in quote")]
    off = {}
    for kind, name, text in cases:
        got = browser.evaluate(f"{PLACES}({json.dumps(kind)}, {json.dumps(text)})")
        assert len(got["now"]) > 2, name
        differ = [(a, b) for a, b in zip(got["now"], got["was"]) if a[0] != b[0] or any(abs(x - y) > 0.5 for x, y in zip(a[1:], b[1:]))]
        if differ or got["cut"] or got["scrolls"] or len(got["now"]) != len(got["was"]):
            off[name] = {"differ": differ[:4], "cut": got["cut"][:4], "scrolls": got["scrolls"]}
    assert off == {}, off


# what reaches furthest to a box's edges
WHOLE = {
    "a year": "2026. kickoff\n2027. launch",
    "a short date": "261126. notes of the day",
    "up to a hundred": "98. a\n99. b\n100. c",
    "in a quote": "> 2026. quoted",
    "in a footer": "Done.\n\nWrite-up: none.\n- note\n\n2026. is the year?",
    "formulas": LOOKS["formula"],
    "a formula first": '<math display="block"><mfrac><mi>a</mi><msqrt><mi>b</mi></msqrt></mfrac></math>\n\nafter',
}
# the reply alone on a fixed stage, so that two looks at it are at the same place whatever the page scrolls meanwhile
SHOT = r"""(async (text, how) => {
  const raf = () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  if (!document.getElementById("t-calm")) { const c = document.createElement("style"); c.id = "t-calm";
    c.textContent = "*, *::before, *::after { animation: none !important; transition: none !important; caret-color: transparent !important }"; document.head.append(c); }
  document.getElementById("t-off")?.remove(); document.getElementById("t-stage")?.remove();
  const m = el("div", { class: "msg assistant" }); m.append(...replyNodes(text, true));
  const stage = el("div", { id: "t-stage", style: "position:fixed;left:0;top:100px;width:100%;height:600px;box-sizing:border-box;" +
    "padding:8px 16px;z-index:2147483647;background:var(--bg)" });
  stage.append(m); document.body.append(stage);
  // "unclipped": the same formatting contexts with nothing clipping them; "whole": no containment at all
  const contain = how.includes("unclipped") ? "layout" : how.includes("whole") ? "none" : "";
  if (contain) { const off = document.createElement("style"); off.id = "t-off";
    off.textContent = `#t-stage .md { contain: ${contain} !important; overflow: visible !important }`; document.head.append(off); }
  if (how.includes("bare")) for (const l of m.querySelectorAll("ol")) l.classList.remove("md-hang");
  m.getBoundingClientRect(); await document.fonts.ready; await raf(); await new Promise((r) => setTimeout(r, 200));
  const b = m.getBoundingClientRect(), tenth = (v) => Math.round(v * 10) / 10;
  const boxes = [...m.querySelectorAll(".md, ol, ul")].map((e) => { const r = e.getBoundingClientRect();
    return [e.className || e.localName, tenth(r.x), tenth(r.y), tenth(r.width), tenth(r.height), e.scrollWidth, e.clientWidth, e.scrollHeight, e.clientHeight]; });
  return { rows: [Math.floor(b.top) - 6, Math.ceil(b.bottom) + 6], boxes }; })"""
# how many pixels of two shots differ in those rows. Each run of drawn rows (rows either shot draws on, bare background
# above and below) is compared as it is and one pixel up or down, and the closest counts: a clipped box can draw a line one
# pixel from where the unclipped one draws it (the same pixels, a row apart), while what a box cuts off is missing at every
# one of the three. When any differ, the rectangle that holds them and a picture of it from both shots, the first above the
# second, for the failure to show
DIFF = r"""(async (a, b, top, bottom) => {
  const read = async (png) => { const img = await createImageBitmap(new Blob([Uint8Array.from(atob(png), (c) => c.charCodeAt(0))], { type: "image/png" }));
    const c = new OffscreenCanvas(img.width, img.height), g = c.getContext("2d"); g.drawImage(img, 0, 0); return [c, g.getImageData(0, top, img.width, bottom - top)]; };
  const [first, x] = await read(a), [second, y] = await read(b), w = x.width, h = x.data.length / 4 / w;
  const pixel = (img, col, row) => img.data.subarray((row * w + col) * 4, (row * w + col) * 4 + 3);
  const ground = pixel(x, 0, 0);   // the corner shows the stage's background
  const far = (p, q) => Math.abs(p[0] - q[0]) + Math.abs(p[1] - q[1]) + Math.abs(p[2] - q[2]) > 60;
  const drawn = (row) => { for (let col = 0; col < w; col++) if (far(pixel(x, col, row), ground) || far(pixel(y, col, row), ground)) return true; return false; };
  let n = 0, at = null;
  for (let s = 0; s < h; s++) {
    if (!drawn(s)) continue;
    let e = s; while (e + 1 < h && drawn(e + 1)) e++;
    const of = (img, col, row) => (row < s || row > e ? ground : pixel(img, col, row));   // this run's rows alone
    let off = null;
    for (const dy of [0, -1, 1]) {
      const here = [];
      for (let row = s - 1; row <= e + 1; row++) for (let col = 0; col < w; col++) if (far(of(x, col, row), of(y, col, row + dy))) here.push([col, top + row]);
      if (!off || here.length < off.length) off = here;
    }
    for (const [col, row] of off) at = at ? [Math.min(at[0], col), Math.min(at[1], row), Math.max(at[2], col), Math.max(at[3], row)] : [col, row, col, row];
    n += off.length; s = e;
  }
  if (n <= 4) return { n };
  const left = Math.max(0, at[0] - 24), up = Math.max(0, at[1] - 12), wide = Math.min(240, at[2] - left + 24), high = Math.min(60, at[3] - up + 12);
  const both = new OffscreenCanvas(wide, high * 2 + 2), g = both.getContext("2d"); g.fillStyle = "red"; g.fillRect(0, 0, wide, high * 2 + 2);
  g.drawImage(first, left, up, wide, high, 0, 0, wide, high); g.drawImage(second, left, up, wide, high, 0, high + 2, wide, high);
  const bytes = new Uint8Array(await (await both.convertToBlob({ type: "image/png" })).arrayBuffer());
  return { n, at, crop: btoa(Array.from(bytes, (c) => String.fromCharCode(c)).join("")) }; })"""


def test_long_list_numbers_and_formulas_show_whole(served, browser):
    """The pixels of such a reply are those of the same layout with nothing cutting it, a line at most one pixel up or down
    (DIFF); without mdHang's indent they are not."""
    open_session(browser, served)
    browser.settle("document.getElementById('chat')")

    def shot(text: str, how: str) -> dict:
        got = browser.evaluate(f"{SHOT}({json.dumps(text)}, {json.dumps(how)})")
        return {**got, "png": browser.send("Page.captureScreenshot", {"format": "png"})["data"]}

    def differ(a: dict, b: dict) -> dict:
        assert a["rows"] == b["rows"], (a["boxes"], b["boxes"])
        return browser.evaluate(f"{DIFF}({json.dumps(a['png'])}, {json.dumps(b['png'])}, {a['rows'][0]}, {a['rows'][1]})")

    off = {}
    for name, text in WHOLE.items():
        held = shot(text, "held")
        for how in ("held", "unclipped", "whole"):
            other = shot(text, how)
            got = differ(held, other)
            if got["n"] > 4:
                off[f"{name}, against {how}"] = {**got, "boxes": held["boxes"], "other boxes": other["boxes"]}
    assert not off, json.dumps(off)
    assert differ(shot(WHOLE["a short date"], "bare"), shot(WHOLE["a short date"], "bare unclipped"))["n"] > 20


def test_drawings_media_formulas_and_colours_are_kept_as_written(served, browser):
    open_session(browser, served)
    text = "\n\n".join(LOOKS[k] for k in ("colours", "drawing", "media", "formula"))
    got = browser.evaluate(f"""(() => {{ const html = marked.parse(mdPrep({json.dumps(text)}), {{ gfm: true, breaks: true }});
      const tree = (n) => [...n.querySelectorAll("*")].map((e) => [e.localName, [...e.attributes]
        .map((a) => a.name + "=" + a.value.replace(/md\\d+-/g, "")).sort().join(";")]);
      const defaults = document.createElement("div"); defaults.append(DOMPurify.sanitize(html, {{ RETURN_DOM_FRAGMENT: true }}));
      const ours = document.createElement("div"); ours.append(mdSanitize(html));
      const d = md({json.dumps(text)}); const m = el("div", {{ class: "msg assistant" }}); m.append(d); document.getElementById("chat").append(m);
      const rect = d.querySelector("svg rect"), fill = getComputedStyle(rect).fill, id = fill.match(/#([^"')]+)/)?.[1];
      return {{ ours: tree(ours), defaults: tree(defaults),
        fill: !!id && d.querySelector("linearGradient").id === id && document.getElementById(id) === d.querySelector("linearGradient"),
        colour: getComputedStyle(d.querySelector("span")).color, label: getComputedStyle(d.querySelector("svg text")).fill,
        sizes: ["svg", "video", "audio", "math"].map((s) => d.querySelector(s).getBoundingClientRect().height > 10) }}; }})()""")
    assert got["ours"] == got["defaults"], got
    assert got["fill"] and got["colour"] == "rgb(1, 2, 3)" and got["label"] == "rgb(1, 2, 3)" and got["sizes"] == [True] * 4, got


def test_every_markdown_feature_comes_out_as_marked_wrote_it(served, browser):
    open_session(browser, served)
    got = browser.evaluate(f"""(() => {{ const out = {{}};
      for (const [k, text] of Object.entries({json.dumps(CORPUS)})) {{
        const html = marked.parse(mdPrep(text), {{ gfm: true, breaks: true }});
        const was = document.createElement("template"); was.innerHTML = html;
        for (const a of was.content.querySelectorAll("a")) {{ a.setAttribute("target", "_blank"); a.setAttribute("rel", "noopener noreferrer"); }}
        const a = document.createElement("div"), b = document.createElement("div");
        a.append(mdSanitize(html)); b.append(was.content); a.normalize(); b.normalize();
        out[k] = a.isEqualNode(b) ? true : [a.innerHTML, b.innerHTML];
      }}
      return out; }})()""")
    assert got == {k: True for k in CORPUS}, {k: v for k, v in got.items() if v is not True}


def test_code_tables_tasks_and_images_still_work_in_a_reply(served, browser):
    text = "\n\n".join([CORPUS["code"], CORPUS["table"], CORPUS["tasks"], CORPUS["links"], "![local one](/nowhere/a.png)"])
    open_session(browser, served, text)
    got = browser.evaluate("""(() => { const m = document.querySelector("#chat .msg.assistant .md");
      return { pres: m.querySelectorAll("pre").length, boxed: m.querySelectorAll(".codebox > pre + button.code-copy").length,
        langs: [...m.querySelectorAll("pre code[class]")].map((c) => c.className),
        align: [...m.querySelectorAll("thead th")].map((c) => getComputedStyle(c).textAlign.replace("-webkit-", "")),
        boxes: [...m.querySelectorAll("input")].map((i) => [i.type, i.disabled, i.checked]),
        links: [...m.querySelectorAll("a[href]")].filter((a) => !a.closest(".md-local"))
          .every((a) => a.target === "_blank" && a.rel === "noopener noreferrer"),
        local: m.querySelector(".md-local .md-local-cap")?.textContent,
        wide: document.documentElement.scrollWidth - innerWidth }; })()""")
    assert got["pres"] == 5 and got["boxed"] == 5, got
    assert got["langs"] == ["language-js", "language-c++", "language-sh"], got
    assert got["align"][1:3] == ["center", "right"], got
    assert got["boxes"] == [["checkbox", True, False], ["checkbox", True, True], ["checkbox", True, False],
                            ["checkbox", True, True]], got
    assert got["links"] and got["local"] == "local one" and got["wide"] <= 0, got   # the image's box, loaded or refused


def test_a_reply_read_from_the_transcript_leaves_the_page_as_it_was(served, browser):
    """The same through the page's own path: the replies in the transcript, read on a reload."""
    open_session(browser, served)
    look = """({ bg: getComputedStyle(document.body).backgroundColor, side: getComputedStyle(document.getElementById("sidebar")).display,
      sheets: document.styleSheets.length })"""
    before = browser.evaluate(look)
    write_reply(served, ACTS.replace("After.", "\n\n".join(ESCAPES.values()) + "\n\nAfter."))
    browser.reload(CHAT_READY + " && document.querySelector('#chat .md') && document.querySelector('#chat .md').textContent.includes('After.')")
    assert browser.evaluate(look) == before
    got = browser.evaluate("""(() => { const d = document.querySelector("#chat .msg.assistant .md"), s = getComputedStyle(d), b = d.getBoundingClientRect();
      return { contain: s.contain, scroll: [s.overflowX, s.overflowY], wide: document.documentElement.scrollWidth - innerWidth,
        top: document.elementFromPoint(innerWidth / 2, 10)?.closest(".md") ? "reply" : "page",
        side: b.width <= innerWidth, tall: b.height < 20000 }; })()""")
    assert got == {"contain": "content", "scroll": ["clip", "clip"], "wide": 0, "top": "page", "side": True, "tall": True}, got


def test_a_tool_result_goes_to_the_page_s_own_tool_card(served, browser):
    """A result that arrives after its call is looked up by the card's class and data attribute: only sala's card has them."""
    open_session(browser, served)
    reply = '<details class="tool" data-tool-id="toolu_probe"><summary>mine</summary><div class="result-slot">untouched</div></details>'
    got = browser.evaluate(f"""(() => {{
      renderMessage({{ role: "assistant", uuid: "p-1", blocks: [{{ kind: "text", text: {json.dumps(reply)} }}] }}, {{ live: true }});
      renderMessage({{ role: "assistant", uuid: "p-2", blocks: [{{ kind: "tool_use", id: "toolu_probe", name: "Bash", summary: "ls", input: "ls" }}] }}, {{ live: true }});
      renderMessage({{ role: "user", uuid: "p-3", blocks: [{{ kind: "tool_result", toolUseId: "toolu_probe", text: "the real result" }}] }}, {{ live: true }});
      const slot = (uuid) => document.querySelector('#chat .msg[data-uuid="' + uuid + '"] .result-slot');
      return {{ own: slot("p-2").textContent, other: document.querySelector('#chat .msg[data-uuid="p-1"] .md').textContent }}; }})()""")
    assert "the real result" in got["own"], got
    assert "untouched" in got["other"] and "the real result" not in got["other"], got
