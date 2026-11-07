"""A lane's details page says its lane words in lower case, and "Details ›" is plain text (lower case like the status pill and the lane
labels; the "Details" link stays in the plain text colour, not the lane label's colour).

- the details page's title names the lane with the words the labels use (`LANE_LABEL`: "bedrock lane", "aws-platform lane"), not
  the lane table's own capitalised label ("Bedrock", "Claude Platform on AWS"); its status pill in the head says "active", "dormant" or
  "not configured" in lower case (no Status card any more); a proper name inside a sentence is not touched;
- "Details ›" on a lane card draws in the card's plain text colour (`--text`), which is not the lane label's colour, in the
  light and the dark theme; the hover underline and the focus ring stay (stylesheet rules).

Headless Chromium when one is installed (conftest.py: `browser`), else skipped; nothing here runs the real sala (the stand-in of
test_lane_details.py) or calls Anthropic.
"""

from __future__ import annotations

import pytest

from test_lane_cards_nowrap import CREDITS, extreme_stub, viewport
from test_lane_details import open_lane, stub_sala  # noqa: F401  (fixture: the stand-in sala)
from test_lane_dormant import SINCE, open_overview, page, record, world  # noqa: F401  (fixtures)
from test_lane_status_pill import READY, theme
from test_board_items_ui import wait_for
from sala_web.app import STATIC

CSS = (STATIC / "sessions.css").read_text()


def test_a_bedrock_page_names_its_lane_and_its_status_in_lower_case(stub_sala, world, page, browser):
    p = open_lane(browser, page(), "#lane=bedrock")
    assert p["title"] == "bedrock" + "bedrock lane" and p["name"] == "Lane bedrock" and p["docTitle"] == "Lane bedrock", p
    assert p["chip"] == "not configured" and p["line"] == "No session can be put on this lane yet.", p
    assert "Bedrock" not in p["title"] and "Not configured" not in p["chip"] + p["line"]


def test_an_aws_platform_page_uses_the_label_words_not_the_records_capitalised_label(stub_sala, world, page, browser):
    p = open_lane(browser, page(), "#lane=aws-platform")
    assert p["title"] == "aws-platform" + "aws-platform lane", p["title"]
    assert "Claude Platform on AWS" not in p["title"] and p["name"] == "Lane aws-platform" and p["docTitle"] == "Lane aws-platform", p
    assert p["chip"] == "not configured", p


def test_the_active_and_dormant_status_words_are_lower_case_too(stub_sala, world, page, browser):
    p = open_lane(browser, page(), "#lane=subscription-1")
    assert p["chip"] == "active" and p["title"] == "ultra" + "ultra lane", p
    record(world["rec"], ("subscription-2", "dormant", "no seat", SINCE, "", "signal"))
    p = open_lane(browser, page(), "#lane=subscription-2", ready="document.querySelector('#ld-title .lane-chip-dormant')")
    assert p["chip"] == "dormant" and p["title"] == "team" + "team lane", p


def test_the_aria_labels_of_the_details_links_use_the_lower_case_lane_words(world, page, browser):
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": extreme_stub(CREDITS["figures"])})
    open_overview(browser, page(), width=1280)
    viewport(browser, 1280)
    assert wait_for(browser, READY)
    labels = browser.evaluate("[...document.querySelectorAll('#q-cards .q-details')].map((a) => a.getAttribute('aria-label'))")
    assert "Details of the bedrock lane" in labels and "Details of the aws-platform lane" in labels, labels
    assert not any("Bedrock" in t or "Claude Platform" in t for t in labels), labels


DETAILS_COLOURS = r"""(() => [...document.querySelectorAll('#q-cards .q-card')].map((card) => {
  const a = card.querySelector('.q-details'), pill = card.querySelector('.sp-pill:not(.lane-chip)');
  return { lane: pill.textContent, link: getComputedStyle(a).color, card: getComputedStyle(card).color, label: getComputedStyle(pill).color,
           text: getComputedStyle(document.documentElement).getPropertyValue('--text').trim(), td: getComputedStyle(a).textDecorationLine }; }))()"""


@pytest.mark.parametrize("scheme", ["light", "dark"])
def test_the_details_link_is_the_cards_plain_text_colour_and_not_the_lane_labels(world, page, browser, scheme):
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": extreme_stub(CREDITS["figures"])})
    open_overview(browser, page(), width=1280)
    theme(browser, scheme)
    viewport(browser, 1280)
    assert wait_for(browser, READY)
    got = browser.evaluate(DETAILS_COLOURS)
    assert len(got) == 7, got
    for g in got:
        assert g["link"] == g["card"], (scheme, "Details is not the card's plain text colour", g)
        assert g["link"] != g["label"], (scheme, "Details matches the lane label's colour", g)
        assert g["td"] == "none", g
    # the plain colour is the theme's text colour, so the two themes differ
    assert len({g["link"] for g in got}) == 1
    assert got[0]["link"] == browser.evaluate("(() => { const e = document.createElement('i'); e.style.color = 'var(--text)'; document.body.append(e); const c = getComputedStyle(e).color; e.remove(); return c; })()")


def test_the_details_link_keeps_its_hover_underline_and_focus_ring():
    assert "#overview-pane .q-details:hover { text-decoration: underline; }" in CSS
    assert "#overview-pane .q-details:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }" in CSS
