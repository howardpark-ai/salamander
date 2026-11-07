"""A lane's status is a pill in the lane label's own style (like the lane labels max, team,
metered, sdk and bedrock: active green, dormant grey, and all labels of this type lower case).

Held here, in a headless Chromium at 1280 and 390 px, in the light and the dark theme, on the Overview's seven cards (the
extreme answers of test_lane_cards_nowrap.py: every chip state, the bedrock and aws-platform lanes) and on a lane's details page:
- the chip carries the lane label's own class family (`sp-pill`) and draws like it: the same size, weight, family, height,
  radius and border width as the label beside it;
- every lane label and every chip says its words in lower case ("bedrock", "aws-platform", "active", "dormant", "not configured");
- "active" is green, "dormant" a tinted grey, "not configured" a grey outline with no fill, and each holds WCAG AA (4.5:1)
  against what is under it in both themes;
- the head stays on one row and the chip sits left of "Details ›" at both widths (the baseline itself: test_lane_chip_baseline.py).
"""

from __future__ import annotations

import json

import pytest

from test_credit import wait_for  # noqa: F401
from test_lane_cards_nowrap import CREDITS, extreme_stub, viewport  # noqa: F401
from test_lane_dormant import open_overview, page, record, world  # noqa: F401  (fixtures)

READY = "document.querySelectorAll('#q-cards .lane-chip:not(.lane-chip-pending)').length === 7"

# each head's label pill and status chip: the drawn style, the colours composited over what is under them, the row
MEASURE = r"""(sel) => {
  const ctx = document.createElement("canvas").getContext("2d");
  const rgba = (css) => { ctx.clearRect(0, 0, 1, 1); ctx.fillStyle = "#000"; ctx.fillStyle = css; ctx.fillRect(0, 0, 1, 1);
    const d = ctx.getImageData(0, 0, 1, 1).data; return [d[0], d[1], d[2], d[3] / 255]; };
  // the colour under an element: the first ancestor with a visible background
  const under = (el) => { for (let e = el.parentElement; e; e = e.parentElement) { const c = rgba(getComputedStyle(e).backgroundColor); if (c[3] > 0.99) return c; }
    return rgba(getComputedStyle(document.body).backgroundColor); };
  const over = (top, bottom) => top.slice(0, 3).map((v, i) => Math.round(v * top[3] + bottom[i] * (1 - top[3])));
  const lum = (c) => { const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }; return 0.2126 * f(c[0]) + 0.7152 * f(c[1]) + 0.0722 * f(c[2]); };
  const contrast = (a, b) => { const x = lum(a), y = lum(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); };
  const style = (el) => { const s = getComputedStyle(el); return { size: s.fontSize, weight: s.fontWeight, family: s.fontFamily, h: s.height, radius: s.borderTopLeftRadius,
    bw: s.borderTopWidth, bstyle: s.borderTopStyle, text: el.textContent }; };
  return [...document.querySelectorAll(sel)].map((head) => {
    const label = head.querySelector(".sp-pill:not(.lane-chip)"), chip = head.querySelector(".lane-chip"), d = head.querySelector(".q-details");
    const o = { cls: chip.className, labelCls: label.className, label: style(label), chip: style(chip), visible: getComputedStyle(chip).visibility };
    const bg = under(chip), fill = rgba(getComputedStyle(chip).backgroundColor), ink = rgba(getComputedStyle(chip).color);
    o.fill = fill; o.ink = ink; o.contrast = contrast(ink.slice(0, 3), over(fill, bg));
    const kids = [...head.children].map((k) => k.getBoundingClientRect());
    o.oneRow = kids.every((k) => Math.abs((k.top + k.bottom) / 2 - (kids[0].top + kids[0].bottom) / 2) < 3);
    o.chipLeftOfDetails = !d || chip.getBoundingClientRect().right <= d.getBoundingClientRect().left;
    o.headH = head.getBoundingClientRect().height;
    return o; });
}"""


def heads(browser, sel="#q-cards .q-head"):
    return browser.evaluate(f"({MEASURE})({json.dumps(sel)})")


def theme(browser, scheme: str) -> None:
    browser.send("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-color-scheme", "value": scheme}]})


def check_heads(got, where):
    assert len(got) >= 3, where
    states = set()
    for h in got:
        state = next(c[len("lane-chip-"):] for c in h["cls"].split() if c.startswith("lane-chip-"))
        states.add(state)
        assert "sp-pill" in h["cls"].split() and "lane-chip" in h["cls"].split() and "sp-pill" in h["labelCls"].split(), (where, h)   # the label's class family
        for k in ("size", "weight", "family", "h", "radius", "bw", "bstyle"):
            assert h["chip"][k] == h["label"][k], (where, k, h)                                                   # drawn like the label
        assert h["chip"]["text"] == h["chip"]["text"].lower() and h["label"]["text"] == h["label"]["text"].lower(), (where, h)
        assert h["chip"]["text"] == {"active": "active", "dormant": "dormant", "unconfigured": "not configured"}[state], (where, h)
        assert h["oneRow"] and h["chipLeftOfDetails"] and h["headH"] <= 24, (where, "the head is not one line", h)
        assert h["contrast"] >= 4.5, (where, state, "the chip's words are hard to read", h)
        r, g, b, a = h["ink"]
        if state == "active":
            assert g > r + 20 and g > b + 20 and h["fill"][3] > 0, (where, "active is not green", h)
        elif state == "dormant":
            assert max(r, g, b) - min(r, g, b) <= 24 and h["fill"][3] > 0, (where, "dormant is not a tinted grey", h)
        else:
            assert max(r, g, b) - min(r, g, b) <= 24 and h["fill"][3] == 0 and h["chip"]["bw"] == "1px", (where, "not configured is not a grey outline", h)
    assert states == {"active", "dormant", "unconfigured"}, (where, states)


@pytest.mark.parametrize("scheme", ["light", "dark"])
@pytest.mark.parametrize("width", [1280, 390])
def test_the_status_is_a_pill_in_the_lane_labels_style_lower_case_and_coloured(world, page, browser, width, scheme):
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": extreme_stub(CREDITS["figures"])})
    open_overview(browser, page(), width=width)
    theme(browser, scheme)
    viewport(browser, width)
    assert wait_for(browser, READY)
    got = heads(browser)
    assert len(got) == 7
    check_heads(got, (width, scheme))
    labels = browser.evaluate("[...document.querySelectorAll('#q-cards .sp-pill:not(.lane-chip)')].map((x) => x.textContent)")
    assert "bedrock" in labels and "aws-platform" in labels and all(t == t.lower() for t in labels), labels


@pytest.mark.parametrize("width", [1280, 390])
def test_a_lane_page_and_the_session_views_say_the_labels_in_lower_case(world, page, browser, width):
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": extreme_stub(CREDITS["figures"])})
    open_overview(browser, page(), width=width)
    viewport(browser, width)
    assert wait_for(browser, READY)
    browser.evaluate("location.hash = '#lane=bedrock'")
    assert wait_for(browser, "document.querySelector('#ld-title .sp-pill') && document.querySelector('#ld-title .sp-pill').textContent === 'bedrock'")
    assert wait_for(browser, "!!document.querySelector('#ld-usage .q-card:not(.q-pending)')")
    # the Usage card's head has no status pill (the page head's is the one, and needs sala's lane table, which this page has no stand-in for)
    assert browser.evaluate("document.querySelectorAll('#ld-usage .lane-chip').length") == 0
    assert browser.evaluate("[...document.querySelectorAll('#ld-usage .q-head .sp-pill')].map((p) => p.textContent)") == ["bedrock"]
    assert browser.evaluate("document.title") == "Lane bedrock"
