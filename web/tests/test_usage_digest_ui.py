"""The Usage analysis tab's Digest view in a browser (static/usage-digest.js, usage-digest.css, the panel in index.html, the hook in usage.js), at a phone's
width (390) and a desktop's (1280), in the dark and the light theme, over the same made-up transcripts as the Report's tests (the page reads the real
api/usage/digest, which counts fake transcripts and a fake registry in the test's temporary folder; nothing reaches Anthropic or AWS and no real
transcript of this box is read: conftest.py points the second login's folders at none).

What a wrong answer costs: a Digest that shows the old "coming next" note, sentences that differ from what the server wrote or markup built from a name in
them (an agent named `<img onerror=…>` must stay text), a week picker that shows a week the sentences are not about or leaves the Report on another week,
a read on a tab or view that is not on screen (the Digest asks only when it is open, on a change of week and on Reload), a failed read that blanks the
last sentences, a token count on a page of dollars, a phone that scrolls sideways or has a control too small to hit, an error in the page's console.

The page runs in a headless Chromium when one is installed (conftest.py: `served`, `browser`), else skipped. Set SALA_USAGE_SHOTS to a folder to leave a
screenshot of each width and theme there.
"""

from __future__ import annotations

import json
import time

import pytest

from test_usage_ui import DESKTOP, PHONE, COUNT, EVIL, C, click, errors, fake_replies, screenshot, wait, warm, world_of, reply

DIGEST_COUNT = """(() => { const real = window.fetch.bind(window); window.__dgUrls = [];
  window.fetch = (url, opts) => { if (String(url).startsWith("api/usage/digest")) window.__dgUrls.push(String(url)); return real(url, opts); }; })();"""
FIRST = ("In the last seven days, 3 replies on this machine cost $20.00 at list prices: $5.00 was billed, "
         "and the other $15.00 ran on a flat plan, so it was not billed.")


def open_digest(served, browser, size: dict, dark: bool = True, view: bool = True) -> None:
    """The Usage analysis tab on its Report (counted), then the Digest view opened (unless view=False)."""
    fake_replies(served)
    warm(served)
    browser.send("Page.enable")
    browser.send("Runtime.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": COUNT})
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": DIGEST_COUNT})
    if not dark:
        browser.send("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-color-scheme", "value": "light"}]})
    browser.open(f"{served['url']}/#usage", dark=dark)
    browser.send("Emulation.setDeviceMetricsOverride", size)
    wait(browser, 'document.querySelectorAll("#us-tbody tr[data-k]").length > 0', "the Report's table")
    if view:
        click(browser, '#us-views [data-v="digest"]')
        wait(browser, 'document.querySelectorAll("#us-dg-text p").length > 0', "the Digest's sentences")


def digest(browser) -> dict:
    return browser.evaluate("""(() => { const t = (n) => n.textContent.replace(/\\s+/g, " ").trim(), q = (s) => document.querySelector(s);
      return {
        sentences: [...document.querySelectorAll("#us-dg-text p")].map(t), bold: [...document.querySelectorAll("#us-dg-text b")].map(t),
        weeks: [...document.querySelectorAll("#us-dg-weeks button")].map((b) => [t(b), b.getAttribute("aria-pressed")]),
        range: t(q("#us-dg-range")), title: t(q("#us-dg-title")), scope: t(q("#us-dg-scope")), upd: t(q("#us-dg-upd")), note: t(q("#us-note")),
        noteError: q("#us-note").classList.contains("error"), bodyHidden: q("#us-dg-body").hidden,
        views: [...document.querySelectorAll("#us-views button")].map((b) => [t(b), b.getAttribute("aria-selected")]),
        panel: t(q("#us-v-digest")), urls: window.__dgUrls,
      }; })()""")


def test_the_markup_has_the_digest_panel_and_both_files_with_the_cache_busting_version():
    from sala_web.app import STATIC
    html = (STATIC / "index.html").read_text()
    assert 'href="static/usage-digest.css?v={{v}}"' in html and 'src="static/usage-digest.js?v={{v}}"' in html
    assert html.index("static/usage.js?v") < html.index("static/usage-digest.js?v") < html.index("static/app.js?v")   # usage.js calls it, app.js starts the tab
    for ident in ("us-dg-weeks", "us-dg-range", "us-dg-body", "us-dg-text", "us-dg-scope", "us-dg-upd"):
        assert f'id="{ident}"' in html
    assert "us-soon" not in html[html.index('id="us-v-digest"'):html.index('id="us-v-digest"') + 900]


def test_the_digest_shows_the_weeks_sentences_in_dollars_with_the_week_picker_and_the_machines_note(served, browser):
    open_digest(served, browser, DESKTOP)
    m = digest(browser)
    assert m["views"] == [["Report", "false"], ["Explorer", "false"], ["Digest", "true"]]
    assert m["sentences"][0] == FIRST, m["sentences"]
    assert m["sentences"][1].startswith("The busiest day was ") and "$" in m["sentences"][1]
    assert any(s.startswith("The largest share ran on subscription-1 (flat plan, not billed): $15.00, or 75% of the week.") for s in m["sentences"]), m["sentences"]
    assert any(s.startswith("Compared with the same hours of the week before ($3.00), that is up 567%, or $17.00 more.") for s in m["sentences"]), m["sentences"]
    assert 4 <= len(m["sentences"]) <= 7
    assert "$20.00" in m["bold"] and all(b.startswith("$") for b in m["bold"]), m["bold"]                     # the amounts are bold, nothing else is
    assert m["weeks"] == [["This week", "true"], ["Previous week", "false"], ["2 weeks ago", "false"]]
    assert "the last seven days" in m["range"] and m["scope"] == "Other machines are not counted: only this machine's sessions."
    assert m["upd"].startswith("counted ") and m["note"] == "" and not m["bodyHidden"]
    assert "coming next" not in m["panel"] and "token" not in m["panel"].lower() and "undefined" not in m["panel"] and "NaN" not in m["panel"]
    assert errors(browser) == []


def test_the_digest_asks_only_when_it_is_open_on_a_change_of_week_and_on_reload_and_the_week_is_one_for_both_views(served, browser):
    open_digest(served, browser, DESKTOP, view=False)
    browser.evaluate("new Promise((r) => setTimeout(r, 600))")
    assert browser.evaluate("window.__dgUrls") == []                                          # the Report is on screen: the Digest is not read
    click(browser, '#us-views [data-v="digest"]')
    wait(browser, 'document.querySelectorAll("#us-dg-text p").length > 0', "the sentences")
    assert browser.evaluate("window.__dgUrls") == ["api/usage/digest?week=0"]
    click(browser, '#us-dg-weeks [data-w="1"]')
    wait(browser, '[...document.querySelectorAll("#us-dg-text p")].some((p) => p.textContent.startsWith("In the seven days before that, 1 reply"))', "last week's sentences")
    m = digest(browser)
    assert m["weeks"] == [["This week", "false"], ["Previous week", "true"], ["2 weeks ago", "false"]] and m["urls"][-1] == "api/usage/digest?week=1"
    assert m["sentences"][0].startswith("In the seven days before that, 1 reply on this machine cost $3.00 at list prices")
    assert not any("weekly limit" in s for s in m["sentences"])
    click(browser, "#us-reload")
    wait(browser, 'window.__dgUrls.length === 3', "Reload reads the Digest again")
    assert browser.evaluate("window.__dgUrls")[-1] == "api/usage/digest?week=1&fresh=1"
    click(browser, '#us-views [data-v="report"]')                                             # the same week on the Report
    wait(browser, 'document.querySelector("#us-weeks [aria-pressed=true]").textContent === "Previous week"', "the Report on the same week")
    assert browser.evaluate("window.__dgUrls.length") == 3                                    # leaving the Digest reads nothing
    browser.evaluate("new Promise((r) => setTimeout(r, 600))")
    assert browser.evaluate("window.__dgUrls.length") == 3
    click(browser, '#us-views [data-v="digest"]')
    wait(browser, "window.__dgUrls.length === 4", "the Digest read again when it is opened again")
    assert errors(browser) == []


def test_a_name_in_a_sentence_is_text_never_markup(served, browser):
    open_digest(served, browser, DESKTOP)
    now = time.time()
    world_of(served).transcript(C, reply("c1", "claude-sonnet-5-5", now - 600, out=5_000_000), mtime=now)
    click(browser, "#us-reload")
    wait(browser, '[...document.querySelectorAll("#us-dg-text p")].some((p) => p.textContent.includes("onerror"))', "the markup-like name in a sentence")
    m = browser.evaluate('({ pwned: window.__pwned || 0, imgs: document.querySelectorAll("#ov-usage img").length, text: document.querySelector("#us-dg-text").textContent })')
    assert m["pwned"] == 0 and m["imgs"] == 0 and EVIL in m["text"], m


def test_a_failed_read_keeps_the_last_sentences_and_says_so(served, browser):
    open_digest(served, browser, DESKTOP)
    browser.evaluate("""(() => { const real = window.fetch.bind(window);
      window.fetch = (url, opts) => String(url).startsWith("api/usage/digest") ? Promise.resolve(new Response("nope", { status: 500 })) : real(url, opts); })(); ''""")
    click(browser, "#us-reload")
    wait(browser, 'document.querySelector("#us-note").textContent.startsWith("Could not read the digest")', "the note")
    m = digest(browser)
    assert m["sentences"][0] == FIRST and "the server answered 500" in m["note"] and m["noteError"], m
    assert errors(browser) == []


@pytest.mark.parametrize("dark", [True, False], ids=["dark", "light"])
@pytest.mark.parametrize("size,name", [(DESKTOP, "desktop"), (PHONE, "phone")])
def test_the_layout_never_scrolls_sideways_a_phone_has_44px_targets_and_both_themes_read(served, browser, size, name, dark):
    open_digest(served, browser, size, dark=dark)
    m = browser.evaluate("""(() => { const vw = document.documentElement.clientWidth, r = (n) => n.getBoundingClientRect();
      const over = [...document.querySelectorAll("#us-v-digest *")].filter((n) => r(n).right > vw + 0.5 && n.getClientRects().length && !n.closest(".us-seg")).map((n) => n.className || n.tagName);
      const small = [...document.querySelectorAll("#us-v-digest button, #us-views button, #us-reload")].filter((n) => n.getClientRects().length && r(n).height < 43.5).map((n) => (n.id || n.className || n.tagName) + ":" + Math.round(r(n).height));
      const p = document.querySelector("#us-dg-text p"), cs = getComputedStyle(p), card = r(document.querySelector(".us-dg-card"));
      const lum = (c) => { const m = c.match(/[\\d.]+/g).map(Number); return (0.2126 * m[0] + 0.7152 * m[1] + 0.0722 * m[2]) / 255; };
      return { vw, doc: document.documentElement.scrollWidth, body: document.body.scrollWidth, pane: document.querySelector("#overview-pane").scrollWidth,
               paneClient: document.querySelector("#overview-pane").clientWidth, over, small, font: cs.fontSize, cardLeft: Math.round(card.left), cardRight: Math.round(card.right),
               text: lum(cs.color), page: lum(getComputedStyle(document.querySelector(".us-dg-card")).backgroundColor), dark: matchMedia("(prefers-color-scheme: dark)").matches }; })()""")
    assert m["doc"] <= m["vw"] and m["body"] <= m["vw"] + 1 and m["pane"] <= m["paneClient"], m      # no sideways scroll
    assert m["over"] == [], m["over"]
    assert m["font"] == "16px" and m["cardLeft"] >= 0 and m["cardRight"] <= m["vw"], m
    assert m["dark"] is dark and abs(m["text"] - m["page"]) > 0.4, m                                 # the text stands out of its card in both themes
    if name == "phone":
        assert m["small"] == [], m["small"]                                                         # every control a comfortable target
        assert m["cardLeft"] >= 8 and m["cardRight"] <= m["vw"] - 8, m                              # the card keeps its gutters
    assert errors(browser) == []
    screenshot(browser, f"usage-digest-{size['width']}-{'dark' if dark else 'light'}.png", 1400)
