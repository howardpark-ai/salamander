"""The lane chip, "Details ›" and the pill share one text baseline (they had not lined up).

The chip's words were 12px in a 20px box and "Details ›" 13px, so their baselines sat apart. They were made the same size; since
Now the chip is a pill in the lane label's own style (12px, lower-case words, no dot), so it must be the pill's size, weight
and family, and sit on the same baseline as the pill and "Details ›" (13px). The check is geometric, in a headless Chromium when one is installed (conftest.py: `browser`), else
skipped: at 390, 760, 1024, 1280 and 1600 px, for each chip state (active, dormant filled, not configured outlined, and
the invisible stand-in before the first answer), on the page's own cards (answers served through a stub of fetch, or none at all
for the stand-in) and on a lane's details page. A text's baseline is the bottom of a zero-size inline-block set in its line
(CSS puts such a box on the baseline); the words are wrapped for the measurement and put back in the same task. A range's top plus a
font's ascent is not used: Blink rounds the ascent, so it reads two texts of different sizes as aligned when they are not.
"""

from __future__ import annotations

import json

import pytest

from test_credit import wait_for  # noqa: F401
from test_lane_cards_nowrap import CREDITS, FULL, extreme_stub, viewport  # noqa: F401
from test_lane_dormant import open_overview, page, record, world  # noqa: F401  (fixtures)

WIDTHS = [390, 760, 1024, 1280, 1600]

# the baseline of a text: the text node's rect top + the ascent of its own font; the three texts of a head in one object
BASELINES = r"""(heads) => {
  // the baseline of a text is the bottom of a zero-size inline-block set in its line (CSS puts such a box on the baseline);
  // the words are wrapped in a span for the measurement and put back at once, in the same task, so nothing re-renders between
  const text = (el) => { const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT); let last = null;
    for (let n = w.nextNode(); n; n = w.nextNode()) if (n.textContent.trim()) last = n;   // the words, not the dot
    if (!last) return null;
    const cs = getComputedStyle(last.parentElement), r = document.createRange(); r.selectNodeContents(last);
    const rect = r.getBoundingClientRect(), parent = last.parentNode;
    const wrap = document.createElement("span"), probe = document.createElement("span");
    probe.style.cssText = "display:inline-block;width:0;height:0";
    parent.replaceChild(wrap, last); wrap.append(last, probe);
    const base = probe.getBoundingClientRect().bottom;
    parent.replaceChild(last, wrap);
    return { text: last.textContent.trim(), size: cs.fontSize, weight: cs.fontWeight, family: cs.fontFamily, base, top: rect.top, h: rect.height }; };
  return [...document.querySelectorAll(heads)].map((head) => {
    const o = { head: head.className, pill: null, chip: null, details: null };
    const pill = head.querySelector(".sp-pill"), chip = head.querySelector(".lane-chip"), d = head.querySelector(".q-details");
    if (pill) o.pill = text(pill);
    if (chip) o.chip = text(chip);
    if (d) o.details = text(d);
    const hr = head.getBoundingClientRect();
    o.headH = hr.height; o.headTop = hr.top;
    o.rows = new Set([...head.children].map((k) => Math.round((k.getBoundingClientRect().top + k.getBoundingClientRect().bottom) / 2))).size;
    return o; });
}"""

# the cards before their first answer: the page's own placeholders, with the invisible chip stand-in ("pending"); the fetches never answer
PENDING_STUB = r"""(() => { const real = window.fetch.bind(window);
  window.fetch = (url, opts) => /^api\/(quota|credit|spend)/.test(String(url)) ? new Promise(() => {}) : real(url, opts); })();"""


def baselines(browser, heads: str) -> list[dict]:
    return browser.evaluate(f"({BASELINES})({json.dumps(heads)})")


def assert_one_baseline(got: list[dict], where) -> None:
    assert got, (where, "no head was measured")
    for h in got:
        c, d = h["chip"], h["details"]
        assert c and d, (where, "a head without its chip or its Details link", h)
        assert (c["family"], c["weight"]) == (d["family"], d["weight"]), (where, "chip and Details differ in font", h)
        if h["pill"]:   # the chip is a pill of the lane label's own style: the same size, weight and family
            assert (c["size"], c["weight"], c["family"]) == (h["pill"]["size"], h["pill"]["weight"], h["pill"]["family"]), (where, "chip and lane label differ", h)
        assert abs(c["base"] - d["base"]) <= 0.5, (where, "chip and Details are not on one baseline", h)
        assert h["rows"] == 1, (where, "the head is on more than one row", h)
        assert h["headH"] <= 24, (where, "the head grew", h)
        if h["pill"]:   # the pill is a smaller word in its own shape: it must still sit on the same line
            assert abs(h["pill"]["base"] - d["base"]) <= 0.5, (where, "the pill is off the baseline", h)
    # a head keeps its baseline at the same place in every state: no state shifts the head
    assert len({round(h["details"]["base"] - h["headTop"], 1) for h in got}) == 1, (where, "the baseline moves with the state", got)


@pytest.mark.parametrize("width", WIDTHS)
def test_the_invisible_pending_chip_holds_the_same_baseline(world, page, browser, width):
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": PENDING_STUB})
    open_overview(browser, page(), width=width)
    viewport(browser, width)
    assert wait_for(browser, "document.querySelectorAll('#q-cards .q-pending .lane-chip-pending').length >= 2")
    assert browser.evaluate("[...document.querySelectorAll('#q-cards .lane-chip')].every((c) => getComputedStyle(c).visibility === 'hidden')")
    got = baselines(browser, "#q-cards .q-head")
    assert len(got) >= 2
    assert_one_baseline(got, (width, "pending"))


@pytest.mark.parametrize("width", WIDTHS)
def test_real_cards_keep_chip_and_details_on_one_baseline(world, page, browser, width):
    """active, dormant (filled) and not configured (outlined), with a stale 'as of' and the widest figures in the mix."""
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": extreme_stub(CREDITS["figures"])})
    open_overview(browser, page(), width=width)
    viewport(browser, width)
    assert wait_for(browser, "document.querySelectorAll('#q-cards .lane-chip:not(.lane-chip-pending)').length === 7")
    got = baselines(browser, "#q-cards .q-head")
    assert len(got) == 7
    assert {h["chip"]["text"] for h in got} == {"active", "dormant", "not configured"}   # all three visible states
    assert_one_baseline(got, (width, "overview"))


@pytest.mark.parametrize("lane", ["subscription-1", "api"])
@pytest.mark.parametrize("width", WIDTHS)
def test_a_details_page_card_head_has_the_pill_and_no_chip_on_one_line(world, page, browser, lane, width):
    """On the details page the card's head has neither the chip nor "Details ›" ("Drop the card's pill"): the lane's pill,
    the plan name and, for the API lane, the Billing link, on one line."""
    world["app"].state.quota.fetch = lambda token: FULL
    record(world["rec"])
    open_overview(browser, page(), width=width)
    viewport(browser, width)
    assert wait_for(browser, "document.querySelectorAll('#q-cards .lane-chip:not(.lane-chip-pending)').length >= 3 && !document.querySelector('#q-cards .q-pending')")
    browser.evaluate(f"location.hash = '#lane={lane}'")
    assert wait_for(browser, "document.body.classList.contains('lane-open') && !!document.querySelector('#ld-usage .q-card:not(.q-pending)')")
    assert browser.evaluate("document.querySelectorAll('#ld-usage .q-details, #ld-usage .lane-chip, #ld-usage .q-head-end').length") == 0
    h = baselines(browser, "#ld-usage .q-head")[0]
    assert h["chip"] is None and h["details"] is None and h["pill"], h
    assert h["rows"] == 1 and h["headH"] <= 24, h
