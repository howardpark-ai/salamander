"""A lane's details page has no Status card: the status is a pill in the page head (a whole card for the status was more than
it needs).

Held here, in a headless Chromium when one is installed (conftest.py: `browser`), else skipped, at 1280 and 390 px; nothing runs
the real sala (the stand-in of test_lane_details.py) or calls Anthropic:
- the Status section and its card are gone (no `#ld-status`, no "Status" heading) on every lane's page;
- the pill is the Overview card's own (`laneChip`: classes `sp-pill lane-chip lane-chip-<state>`, drawn in the lane label's box):
  "active" green, "dormant" grey, "not configured" plain grey words with no fill or outline, placed right after the lane's name ("ultra lane")
  and before "N live sessions";
- a dormant or not-configured lane has its note as one plain line under the head (no box, no border, no fill); an active lane has
  no line; when sala could not read its record there is no pill (it would say a state nobody told the page) and the
  "not available just now" line stays;
- the Usage card's head has no status pill of its own (the page head's is the one),
  no "Details ›" and no empty stand-in either, on every lane's page, dormant, not configured and unreadable ones included; the
  Overview cards keep theirs;
- Record and Usage sit side by side on a wide screen, one above the other on a phone, and the page does not scroll sideways.
"""

from __future__ import annotations

import pytest

from test_board_items_ui import wait_for
from test_lane_details import INDEX, SESSIONS_JS, open_lane, stub_sala  # noqa: F401  (fixture: the stand-in sala)
from test_lane_dormant import SINCE, page, record, world  # noqa: F401  (fixtures)

CHIP_STYLE = r"""(() => { const out = {};
  const ctx = document.createElement("canvas").getContext("2d");
  const rgba = (css) => { ctx.clearRect(0, 0, 1, 1); ctx.fillStyle = "#000"; ctx.fillStyle = css; ctx.fillRect(0, 0, 1, 1);
    const d = ctx.getImageData(0, 0, 1, 1).data; return [d[0], d[1], d[2], d[3] / 255]; };
  for (const [k, sel] of [["head", "#ld-title .lane-chip"], ["label", "#ld-title .sp-pill:not(.lane-chip)"], ["card", "#ld-usage .lane-chip"]]) {
    const el = document.querySelector(sel); if (!el) { out[k] = null; continue; }
    const s = getComputedStyle(el);
    out[k] = { size: s.fontSize, weight: s.fontWeight, family: s.fontFamily, h: s.height, radius: s.borderTopLeftRadius, bw: s.borderTopWidth,
               color: s.color, fill: s.backgroundColor, border: s.borderTopColor, text: el.textContent,
               ink: rgba(s.color), fillA: rgba(s.backgroundColor)[3] }; }
  const l = document.querySelector("#ld-line"), s = getComputedStyle(l);
  out.line = { border: s.borderTopWidth, fill: s.backgroundColor, size: s.fontSize, padding: s.paddingTop };
  return out; })()"""


def test_the_status_section_and_its_card_are_gone_from_the_page_and_its_code():
    assert 'id="ld-status"' not in INDEX and 'id="ld-h-status"' not in INDEX
    assert '<h2 id="ld-h-status"' not in INDEX and ">Status</h2>" not in INDEX
    assert "laneState" not in SESSIONS_JS and '"ld-status"' not in SESSIONS_JS and "ld-state-word" not in SESSIONS_JS
    assert INDEX.count('id="ld-line"') == 1


@pytest.mark.parametrize("width", [1280, 390])
def test_the_pill_sits_in_the_head_after_the_lane_name_and_before_the_session_count(stub_sala, world, page, browser, width):
    p = open_lane(browser, page(), "#lane=subscription-1", width=width)
    assert not p["statusCard"], p
    assert p["headOrder"] == ["label", "name", "chip"] and p["chip"] == "active" and p["title"] == "ultraultra lane", p
    r = p["headRects"]
    assert r["name"]["right"] <= r["chip"]["left"] + 0.5, ("the pill is not after the name", r)            # right after "ultra lane"
    assert r["chip"]["left"] - r["name"]["right"] <= 12, ("the pill is not next to the name", r)
    assert r["chip"]["right"] <= r["count"]["left"] + 0.5 or r["chip"]["bottom"] <= r["count"]["top"] + 0.5, ("the pill is not before the count", r)
    assert p["count"] == "2 live sessions"
    assert p["docScroll"] <= p["vw"] and p["paneScroll"] <= p["paneClient"], p                                 # no sideways scroll
    # the head's own parts: the pill is a child of the title, so it stays with the name when the head wraps
    assert abs((r["chip"]["top"] + r["chip"]["bottom"]) / 2 - (r["name"]["top"] + r["name"]["bottom"]) / 2) < 3, r


def test_the_pill_is_the_overview_cards_pill_style_active_green_dormant_grey_not_configured_plain_grey_words(stub_sala, world, page, browser):
    record(world["rec"], ("subscription-2", "dormant", "no seat", SINCE, "", "signal"))
    seen = {}
    for lane, state, ready in (("subscription-1", "active", "true"), ("subscription-2", "dormant", "document.querySelector('#ld-title .lane-chip-dormant')"),
                               ("bedrock", "not configured", "document.querySelector('#ld-title .lane-chip-unconfigured')")):
        p = open_lane(browser, page(), f"#lane={lane}", width=1280, ready=ready)
        assert p["chip"] == state and p["chipCls"].split()[:2] == ["sp-pill", "lane-chip"], p
        st = browser.evaluate(CHIP_STYLE)
        h, c = st["head"], st["label"]
        assert st["card"] is None, (lane, "the Usage card still wears a status pill", st)
        for k in ("size", "weight", "family", "h", "radius", "bw"):
            assert h[k] == c[k], (lane, k, "the head's pill is not drawn like the lane label", st)           # the label's own box
        seen[state] = h
    r, g, b, _ = seen["active"]["ink"]
    assert g > r + 20 and g > b + 20, seen["active"]
    for state in ("dormant", "not configured"):
        r, g, b, _ = seen[state]["ink"]
        assert max(r, g, b) - min(r, g, b) <= 24, (state, seen[state])
    assert seen["dormant"]["fillA"] > 0 and seen["not configured"]["fillA"] == 0 and seen["not configured"]["bw"] == "0px", seen   # the look draws no outlines: plain grey words, no fill


@pytest.mark.parametrize("width", [1280, 390])
def test_a_dormant_or_not_configured_lane_has_its_note_as_one_plain_line_under_the_head(stub_sala, world, page, browser, width):
    record(world["rec"], ("subscription-2", "dormant", "no seat", SINCE, "", "signal"))
    for lane, ready, line in (("subscription-2", "document.querySelector('#ld-title .lane-chip-dormant')",
                               "No usage check is made for it, and the New session form does not offer it."),
                              ("aws-platform", "document.querySelector('#ld-title .lane-chip-unconfigured')", "No session can be put on this lane yet.")):
        p = open_lane(browser, page(), f"#lane={lane}", width=width, ready=ready)
        r = p["headRects"]
        assert p["line"] == line and p["lineShown"], p
        assert r["line"]["top"] >= r["head"]["bottom"] - 0.5, ("the line is not under the head", r)
        assert p["cols"][0]["top"] >= r["line"]["bottom"], ("the line is not above the sections", p["cols"], r)
        st = browser.evaluate(CHIP_STYLE)["line"]
        assert st["border"] == "0px" and st["fill"] == "rgba(0, 0, 0, 0)" and st["size"] == "13px", st      # plain text, not a card
        assert p["docScroll"] <= p["vw"] and p["right"] <= p["vw"], p


def test_an_active_lane_has_no_line_and_the_unreadable_record_keeps_its_line_without_a_pill(stub_sala, world, page, browser):
    p = open_lane(browser, page(), "#lane=subscription-1", width=1280)
    assert p["line"] == "" and not p["lineShown"], p
    r = p["headRects"]
    assert p["cols"][0]["top"] - r["head"]["bottom"] <= 20, ("an empty line should take no room", p["cols"], r)     # nothing between head and sections but their margin
    stub_sala.mode("fail")
    p = open_lane(browser, page(), "#lane=subscription-1", width=1280, ready="document.querySelector('#ld-record .ld-none')")
    assert p["chip"] is None and p["headOrder"] == ["label", "name"], p                                           # no state known, no pill
    assert p["line"].startswith("Not available just now. sala's record of this lane could not be read") and p["lineShown"], p
    assert not p["statusCard"]


def test_an_unknown_lane_has_no_pill_and_says_so_in_its_line(stub_sala, world, page, browser):
    p = open_lane(browser, page(), "#lane=nope", width=1280, ready="document.querySelector('#ld-record .ld-none')")
    assert p["chip"] is None and p["line"] == "sala does not know this lane." and p["lineShown"], p


def test_record_and_usage_are_side_by_side_on_a_wide_screen_and_stacked_on_a_phone(stub_sala, world, page, browser):
    wide = open_lane(browser, page(), "#lane=subscription-1", width=1280)
    rec, use = wide["cols"]
    assert rec["right"] <= use["left"] and abs(rec["top"] - use["top"]) < 2, ("not side by side", wide["cols"])     # one row, two columns
    assert wide["docScroll"] <= wide["vw"] and wide["paneScroll"] <= wide["paneClient"] and wide["right"] <= wide["vw"], wide
    phone = open_lane(browser, page(), "#lane=subscription-1", width=390)
    rec, use = phone["cols"]
    assert rec["bottom"] <= use["top"] + 0.5 and abs(rec["left"] - use["left"]) < 2 and abs(rec["right"] - use["right"]) < 2, ("not stacked", phone["cols"])
    assert phone["docScroll"] <= phone["vw"] and phone["paneScroll"] <= phone["paneClient"] and phone["right"] <= phone["vw"], phone


@pytest.mark.parametrize("lane", ["api", "bedrock", "aws-platform"])
def test_the_spend_lanes_keep_their_usage_next_to_the_record_with_no_gap_where_the_status_was(stub_sala, world, page, browser, lane):
    p = open_lane(browser, page(), f"#lane={lane}", width=1280)
    rec, use = p["cols"]
    assert rec["right"] <= use["left"] and abs(rec["top"] - use["top"]) < 2, p["cols"]
    assert p["usage"]["cards"] == 1 and p["usage"]["details"] == 0 and not p["statusCard"], p["usage"]


@pytest.mark.parametrize("width", [1280, 390])
def test_the_usage_card_has_no_status_pill_the_page_head_has_one_and_the_overview_cards_keep_theirs(stub_sala, world, page, browser, width):
    """The Usage card's head repeated the state the page head
    already shows beside the lane's name; it is gone, the card's other head parts stay, and no empty element is left where
    it was. The Overview's cards are not touched."""
    record(world["rec"], ("subscription-2", "dormant", "no seat", SINCE, "", "signal"))
    for lane, ready in (("subscription-1", "true"), ("subscription-2", "document.querySelector('#ld-title .lane-chip-dormant')"),
                        ("api", "document.querySelector('#ld-usage .c-figs')"),
                        ("bedrock", "document.querySelector('#ld-title .lane-chip-unconfigured')"),
                        ("aws-platform", "document.querySelector('#ld-title .lane-chip-unconfigured')")):
        p = open_lane(browser, page(), f"#lane={lane}", width=width, ready=ready)
        u = p["usage"]
        assert p["headPills"] == 1 and p["headOrder"] == ["label", "name", "chip"], (lane, p)             # exactly one status pill in the page head
        assert u["chips"] == [] and u["headEnds"] == 0 and u["details"] == 0, (lane, u)                     # none in the card: no chip, no link, no right end
        assert u["emptyHeadKids"] == 0 and "!chip" not in " ".join(u["headKinds"]), (lane, u)               # no spare empty element in the head
        assert u["pills"], (lane, u)                                                                        # the lane's own label stays
        assert p["docScroll"] <= p["vw"] and p["right"] <= p["vw"], (lane, p)
        # the Overview's cards are still drawn with theirs, one each, and a "Details ›" link
        assert wait_for(browser, "document.querySelectorAll('#q-cards > .q-card').length >= 5 && !document.querySelector('#q-cards .q-pending')")
        ov = browser.evaluate("""[...document.querySelectorAll('#q-cards > .q-card')].map((c) => ({ chips: c.querySelectorAll('.q-head .lane-chip').length,
          details: c.querySelectorAll('.q-head .q-details').length }))""")
        assert len(ov) >= 5 and all(c == {"chips": 1, "details": 1} for c in ov), (lane, ov)
    # the lane that is not active keeps its one line under the page head, and an unreadable record its own
    p = open_lane(browser, page(), "#lane=subscription-2", width=width, ready="document.querySelector('#ld-title .lane-chip-dormant')")
    assert p["line"] == "No usage check is made for it, and the New session form does not offer it." and p["lineShown"], p
    stub_sala.mode("fail")
    p = open_lane(browser, page(), "#lane=subscription-1", width=width, ready="document.querySelector('#ld-record .ld-none')")
    assert p["headPills"] == 0 and p["usage"]["chips"] == [] and p["usage"]["emptyHeadKids"] == 0 and p["lineShown"], p
