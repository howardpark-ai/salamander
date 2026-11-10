"""The lane cards never break a line (card line breaks looked bad once the status chip shipped). A screenshot at about 1400 px showed three cramped cards per row: "Current session" and "Fable this
week" wrapped, "Resets Wed 2:0…" was cut, and the API card's chip and "Details ›" fell to a second line. Now a card is at
least 312 px wide (three per row on a desktop, two on a tablet, one on a phone), the head is one line at any width, and a quota row keeps its
label at its own width.

What a wrong answer costs is the Overview the owner reads every day looking ragged. The checks are geometric, in a headless
Chromium when one is installed (conftest.py: `browser`), else skipped: at each width from a phone to a wide screen, on the
Overview and on each lane's details page, no label wraps (every client rect of its text on one line), none is cut
(scrollWidth <= clientWidth), the head's children share one row, and the page does not scroll sideways. The cards are the
real ones, from the real answers, plus cards the page's own functions draw from extreme answers (a stale "as of", a
"Not configured" chip, the widest reset text, a hand-set reason). The dormant line's reason (a trailing "(who, day)" that
a hand-set reason carries is not said twice) is held in node and in the page.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
from datetime import datetime, timedelta, timezone

import pytest

from sala_web.app import STATIC
from i18n_node import prelude
from test_credit import wait_for  # noqa: F401
from test_lane_dormant import FRI, SINCE, TOKEN, open_overview, page, record, world  # noqa: F401  (fixtures)

NODE = shutil.which("node")
WIDTHS = [390, 760, 1024, 1280, 1400, 1600, 1920]
JS = (STATIC / "sessions.js").read_text()
SHARED = (STATIC / "shared.js").read_text()
# shared.js's zone helpers (the SALA_TZ zone the page formats in, told by api/config), set to the zone these cases were written in
ZONE_JS = SHARED[SHARED.index("const zone = {"):SHARED.index('// "5 min ago" for a time t (epoch ms)')] + 'zone.name = "Asia/Dubai";\n'


def reset(days: float, hour_utc: int = 8, minute: int = 58) -> str:
    """An ISO time `days` from now at hour_utc:minute UTC (12:58 PM +04 at 08:58: the widest "Resets …" text)."""
    d = (datetime.now(timezone.utc) + timedelta(days=days)).replace(hour=hour_utc, minute=minute, second=0, microsecond=0)
    return d.strftime("%Y-%m-%dT%H:%M:%SZ")


# The widest reset text the page can say, pinned: a reset more than a week out reads "Resets <weekday> <month> <day> <time>", and
# the widest of each part, measured in the headless browser's face (DejaVu Sans, the widest fallback seen here), is Wed, May, 30
# and 10:44 AM: 161.3 px at 12 px, which the label column (sessions.css, .q-row: 164px) is sized to fit. The date is a fixed one
# (Wed May 30th 2035, 10:44 AM +04), far enough out to take the date form on any day this test runs before May 23rd 2035, so the
# text does not move with today's date (it was "now + 8 days", which read a different date every week).
WIDEST_RESET = "2035-05-30T06:44:00Z"
WIDEST_TEXT = "Resets Wed May 30 10:44 AM"

# the three limits of a Max login, the widest reset texts ("Resets Wed 12:58 PM", and past a week the pinned WIDEST_TEXT)
FULL = {"limits": [
    {"kind": "session", "percent": 100, "severity": "bad", "resets_at": reset(0.2)},
    {"kind": "weekly_all", "percent": 64.5, "severity": "warning", "resets_at": reset(3)},
    {"kind": "weekly_scoped", "percent": 30, "severity": "normal", "resets_at": WIDEST_RESET,
     "scope": {"model": {"display_name": "Fable"}}},
    {"kind": "weekly_scoped", "percent": 5, "severity": "normal", "resets_at": reset(5),
     "scope": {"model": {"display_name": "Sonnet"}}},
]}

# one measurement of a card: every text the card shows, on one line and not cut; the head on one row
MEASURE = r"""(sel) => {
  // a text is on one line when every client rect of its text nodes (not of boxes around them) has the same top
  const oneLine = (el) => { const rects = []; const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    for (let n = w.nextNode(); n; n = w.nextNode()) { if (!n.textContent.trim()) continue; const r = document.createRange(); r.selectNodeContents(n);
      rects.push(...[...r.getClientRects()].filter((x) => x.width > 0)); }
    return rects.length === 0 || rects.every((x) => Math.abs(x.top - rects[0].top) < 3); };
  const out = [];
  for (const card of document.querySelectorAll(sel)) {
    const cr = card.getBoundingClientRect(), bad = [], name = (card.querySelector(".sp-pill") || card).textContent.trim();
    const check = (el, what) => {
      if (!oneLine(el)) bad.push(what + " wraps: " + el.textContent.trim());
      // an element that clips (ellipsis) must not be clipping anything
      if (getComputedStyle(el).overflow !== "visible" && el.scrollWidth > el.clientWidth + 1) bad.push(what + " is cut: " + el.textContent.trim());
      const r = el.getBoundingClientRect();
      if (r.right > cr.right - 0.5 || r.left < cr.left - 0.5) bad.push(what + " leaves the card: " + el.textContent.trim());
    };
    for (const el of card.querySelectorAll(".q-head > :not(.q-head-end), .lane-chip, .q-details, .c-bill, .c-updated, .q-name, .q-reset, .q-pct, .c-k, .c-v")) {
      if (el.matches(".q-plan")) { if (!oneLine(el)) bad.push(el.className + " wraps"); continue; }   // the plan name may give way with an ellipsis
      check(el, el.className.split(" ")[0]);
    }
    // every card ends with its "updated 7 min ago" line: one line, uncut, the card's last child
    if (!card.lastElementChild || !card.lastElementChild.matches(".c-updated")) bad.push("the card does not end with its updated line");
    const head = card.querySelector(".q-head");
    if (head) {
      const hr = head.getBoundingClientRect(), kids = [...head.children].map((k) => k.getBoundingClientRect());
      if (!kids.every((k) => Math.abs((k.top + k.bottom) / 2 - (kids[0].top + kids[0].bottom) / 2) < 3)) bad.push("the head is on more than one row");
      if (kids.some((k) => k.right > hr.right + 1 || k.left < hr.left - 1)) bad.push("a head child leaves the head");
      if (hr.height > 24) bad.push("the head is " + hr.height + "px high");
    }
    for (const row of card.querySelectorAll(".q-row")) {
      const rr = row.getBoundingClientRect();
      for (const k of row.querySelectorAll(".q-name, .q-reset, .q-pct, .q-bar")) if (k.getBoundingClientRect().right > rr.right + 1) bad.push("a row overflows");
      if (row.querySelector(".q-bar").getBoundingClientRect().width < 40) bad.push("the bar is narrower than 40px");
    }
    const plan = card.querySelector(".q-plan");
    out.push({ name, w: Math.round(cr.width), right: Math.round(cr.right), top: Math.round(cr.top), bad,
               planCut: !!plan && plan.scrollWidth > plan.clientWidth + 1 });
  }
  return { cards: out, docScroll: document.documentElement.scrollWidth, vw: document.documentElement.clientWidth };
}"""


def viewport(browser, width: int) -> None:
    browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 900, "deviceScaleFactor": 1, "mobile": False})
    assert wait_for(browser, f"document.documentElement.clientWidth === {width}")


def unfold(browser, width: int) -> None:
    """A phone folds the Overview's lane cards into one chip strip; a tap on it opens the grid these checks measure."""
    if width <= 760:
        assert wait_for(browser, "document.readyState !== 'loading' && !!document.getElementById('q-strip') && getComputedStyle(document.getElementById('q-strip')).display !== 'none'")
        browser.evaluate("if (!document.getElementById('quota').classList.contains('q-open')) document.getElementById('q-strip').click(); ''")
        assert wait_for(browser, "document.getElementById('quota').classList.contains('q-open')")


def measure(browser, sel: str) -> dict:
    return browser.evaluate(f"({MEASURE})({json.dumps(sel)})")


def report(got: dict, width: int) -> None:
    assert got["cards"], "no card was measured"
    assert got["docScroll"] <= got["vw"], (width, "the page scrolls sideways", got)
    for c in got["cards"]:
        assert not c["bad"], (width, c)
        assert c["right"] <= width, (width, c)


# answers that stretch every part of a card, served in place of api/quota and api/credit by a stub of fetch installed before
# the page loads: a stale answer ("as of 5 hours ago" as the last line), a saved answer with a failed check, a lane with no sign-in (the Not
# configured chip), a dormant lane with a hand-set reason, and a spend card with an estimate, "as of" and the widest figures
def extreme_stub(credit: dict) -> str:
    def iso(days):
        return int((datetime.now(timezone.utc) + timedelta(days=days)).timestamp() * 1000)

    old = int((datetime.now(timezone.utc) - timedelta(hours=5)).timestamp() * 1000)
    lim = lambda label, pct, d, sev="normal": {"label": label, "percent": pct, "severity": sev,  # noqa: E731
                                              "resetsAt": d if isinstance(d, str) else
                                              datetime.fromtimestamp(iso(d) / 1000, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
    limits = [lim("Current session", 100, 0.2, "bad"), lim("This week", 64.5, 3, "warning"), lim("Fable this week", 30, WIDEST_RESET), lim("Sonnet this week", 7, 5)]
    quota = {"lanes": [
        {"lane": "subscription-1", "plan": "Max (20x)", "limits": limits, "fetchedAt": old},
        {"lane": "subscription-2", "plan": "Team", "limits": limits[:2], "error": "x", "errorKind": "rate_limited", "fetchedAt": old},
        {"lane": "bedrock", "plan": "Enterprise (20x)", "error": "no sign-in on this lane"},
        {"lane": "aws-platform", "plan": "Enterprise (20x)", "dormant": {"reason": "Usage check refused (Alex, Tue Jan 6th)", "since": FRI}},
    ]}
    return """(() => { const real = window.fetch.bind(window);
      const answer = (o) => Promise.resolve(new Response(JSON.stringify(o), { headers: { "Content-Type": "application/json" } }));
      window.fetch = (url, opts) => String(url).startsWith("api/quota") ? answer(%s) : String(url).startsWith("api/credit") ? answer(%s) : real(url, opts);
    })();""" % (json.dumps(quota), json.dumps(credit))


CREDITS = {
    "figures": {"lane": "api", "todayUsd": 1234.56, "monthUsd": 98765.43, "estimatedFrom": "2026-10-23T01:00:00Z", "monthEstimatedUsd": 12,
                "usageThrough": "2026-10-23T05:00:00Z", "unpriced": [], "fetchedAt": int(datetime.now().timestamp() * 1000) - 2 * 3600 * 1000},
    "dormant": {"lane": "api", "dormant": {"reason": "No credit on the API key (Alex, Tue Jan 6th)", "since": FRI}},
}


@pytest.mark.parametrize("credit", list(CREDITS))
@pytest.mark.parametrize("width", WIDTHS)
def test_cards_drawn_from_extreme_answers_keep_every_label_on_one_line(world, page, browser, width, credit):
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": extreme_stub(CREDITS[credit])})
    open_overview(browser, page(), width=width)
    viewport(browser, width)
    unfold(browser, width)
    assert wait_for(browser, "document.querySelectorAll('#q-cards .lane-chip:not(.lane-chip-pending)').length === 7")
    got = measure(browser, "#q-cards > .q-card")
    assert len(got["cards"]) == 7
    report(got, width)
    # the stale answers (5 h old) end in "as of 5 hours ago"; the lane that never answered says "updated unknown"
    foots = browser.evaluate("[...document.querySelectorAll('#q-cards .c-updated')].map((f) => f.textContent)")
    assert foots.count("as of 5 hours ago") == 2 and "updated unknown" in foots, foots
    assert WIDEST_TEXT in browser.evaluate("[...document.querySelectorAll('#q-cards .q-reset')].map((r) => r.textContent)")   # the widest text was drawn
    lines = browser.evaluate("[...document.querySelectorAll('#q-cards .q-dormant-line')].map((l) => l.textContent)")
    # the dormant lines say the reason once and the day once (a hand-set reason's "(who, day)" is dropped)
    assert lines == ["Usage check refused since Tue Jan 6th"] + (["No credit on the API key since Tue Jan 6th"] if credit == "dormant" else []), lines


@pytest.mark.parametrize("width", WIDTHS)
def test_the_overview_cards_keep_every_label_on_one_line_at_any_width(world, page, browser, width):
    world["app"].state.quota.fetch = lambda token: FULL
    record(world["rec"])
    open_overview(browser, page(), width=width)
    viewport(browser, width)
    unfold(browser, width)
    assert wait_for(browser, "document.querySelectorAll('#q-cards .lane-chip:not(.lane-chip-pending)').length >= 3 && !document.querySelector('#q-cards .q-pending')")
    got = measure(browser, "#q-cards > .q-card")
    assert len(got["cards"]) == 5
    report(got, width)
    assert WIDEST_TEXT in browser.evaluate("[...document.querySelectorAll('#q-cards .q-reset')].map((r) => r.textContent)")   # the widest text was drawn
    first_row = [c for c in got["cards"] if c["top"] == got["cards"][0]["top"]]
    # Decision: three to a row on a desktop, two on a tablet, one on a phone
    if width >= 1024:
        assert len(first_row) == 3, (width, got)
    elif width >= 760:
        assert len(first_row) == 2, (width, got)
    else:
        assert len(first_row) == 1, (width, got)
    # the plan name is not on the Overview, so a head is the pill(s), the chip and "Details ›" and nothing to cut
    assert not any(c["planCut"] for c in got["cards"]), (width, got)
    assert browser.evaluate("document.querySelectorAll('#q-cards .q-plan').length") == 0


@pytest.mark.parametrize("dormant", [False, True])
def test_the_plan_name_is_on_the_details_page_and_not_on_the_overview(world, page, browser, dormant):
    """"Max (20x)", "Team" and "API (metered)" beside the pill are the lane details page's; the data keeps them."""
    if dormant:
        record(world["rec"], ("subscription-1", "dormant", "login no longer reports Max", FRI, "", "signal"), ("subscription-2", "dormant", "no seat", FRI, "", "signal"),
               ("api", "dormant", "credit used up", FRI, "", "signal"))
    else:
        record(world["rec"])
    open_overview(browser, page(), width=1280)
    ready = "document.querySelectorAll('#q-cards .lane-chip:not(.lane-chip-pending)').length >= 3 && !document.querySelector('#q-cards .q-pending')"
    assert wait_for(browser, ready)
    assert browser.evaluate("document.querySelectorAll('#q-cards .q-plan').length") == 0
    assert "Max (20x)" not in browser.evaluate("document.getElementById('q-cards').textContent")
    for lane, plan in (("subscription-1", "Max (20x)"), ("subscription-2", "Team"), ("api", "API (metered)")):
        browser.evaluate(f"location.hash = '#lane={lane}'")
        assert wait_for(browser, f"document.body.classList.contains('lane-open') && !!document.querySelector('#ld-usage .lane-{lane}:not(.q-pending)')")
        assert browser.evaluate("[...document.querySelectorAll('#ld-usage .q-head .q-plan')].map((p) => p.textContent)") == [plan], lane
        browser.evaluate("location.hash = '#sessions'")
        assert wait_for(browser, "!document.body.classList.contains('lane-open')")


@pytest.mark.parametrize("lane", ["subscription-1", "subscription-2", "api"])
@pytest.mark.parametrize("width", WIDTHS)
def test_a_lane_details_page_keeps_every_label_on_one_line(world, page, browser, lane, width):
    world["app"].state.quota.fetch = lambda token: FULL
    record(world["rec"])
    open_overview(browser, page(), width=width)
    viewport(browser, width)
    assert wait_for(browser, "document.querySelectorAll('#q-cards .lane-chip:not(.lane-chip-pending)').length >= 3 && !document.querySelector('#q-cards .q-pending')")
    browser.evaluate(f"location.hash = '#lane={lane}'")
    assert wait_for(browser, "document.body.classList.contains('lane-open') && !!document.querySelector('#ld-usage .q-card:not(.q-pending)')")
    got = measure(browser, "#ld-usage .q-card")
    report(got, width)
    if lane == "subscription-1":
        assert WIDEST_TEXT in browser.evaluate("[...document.querySelectorAll('#ld-usage .q-reset')].map((r) => r.textContent)")
    assert browser.evaluate("document.querySelectorAll('#ld-usage .lane-chip').length") == 0              # none in the card
    # the title above it holds too
    assert browser.evaluate("(() => { const t = document.getElementById('ld-title'); const r = document.createRange(); r.selectNodeContents(t);"
                            " const rs = [...r.getClientRects()].filter((x) => x.width > 0); return rs.every((x) => Math.abs((x.top + x.bottom) / 2 - (rs[0].top + rs[0].bottom) / 2) < 3); })()")   # one row: the centres line up (the pill is 20 px in a taller line)


def test_the_details_page_card_with_a_dormant_api_lane_stays_one_line_too(world, page, browser):
    record(world["rec"], ("api", "dormant", "no credit on the API key (Alex, Tue Jan 6th)", FRI, "", "hand"))
    open_overview(browser, page(), width=390)
    assert wait_for(browser, "document.querySelectorAll('#q-cards .lane-chip:not(.lane-chip-pending)').length >= 3")
    browser.evaluate("location.hash = '#lane=api'")
    assert wait_for(browser, "document.body.classList.contains('lane-open') && !!document.querySelector('#ld-usage .q-dormant-line')")
    report(measure(browser, "#ld-usage .q-card"), 390)
    assert browser.evaluate("document.querySelector('#ld-usage .q-dormant-line').textContent") == "No credit on the API key since Tue Jan 6th"


# ── the dormant line's reason ────────────────────────────────────────────────
REASONS = [
    ("credit used up", "No credit on the API key"),
    ("no credit on the API key (Alex, Tue Jan 6th)", "No credit on the API key"),     # set by hand, as sala's record has it
    ("No credit on the API key (Alex, Tue Jan 6th)", "No credit on the API key"),
    ("Credit used up (watch)", "No credit on the API key"),
    ("usage check refused", "Usage check refused"),
    ("Usage check refused (Alex, Tue Jan 6th)", "Usage check refused"),
    ("login no longer reports Max (hand) ", "Login no longer reports Max"),
    ("no seat", "No seat"),
    ("set by hand", "Set by hand"),
    ("seat (gone) for good", "Seat (gone) for good"),                                   # a parenthesis inside the sentence stays
    ("moved (to team) (Alex, Tue Jan 6th)", "Moved (to team)"),                      # only the last one goes
    ("(Alex, Tue Jan 6th)", ""),
    ("   ", ""),
    ("", ""),
    (None, ""),
]


@pytest.mark.skipif(not NODE, reason="node is not installed")
def test_reason_text_says_the_reason_once_without_its_who_and_day():
    start = JS.index("const REASON_WORDS")
    end = JS.index("function dormantLine")
    cap = re.search(r"^const capFirst = .*$", JS, re.M).group(0)
    script = prelude("en") + cap + "\n" + JS[start:end] + f"\nconsole.log(JSON.stringify({json.dumps([r for r, _ in REASONS])}.map(reasonText)));"
    out = json.loads(subprocess.run([NODE, "-e", script], capture_output=True, text=True, check=True, timeout=30).stdout)
    assert out == [want for _, want in REASONS]


@pytest.mark.skipif(not NODE, reason="node is not installed")
def test_dormant_line_joins_the_reason_and_the_day():
    start = JS.index("const REASON_WORDS")
    end = JS.index("function dormantLine")
    end2 = JS.index("function dormantCard")
    dayw = JS[JS.index("const zoneDayParts"):JS.index("// \"Details ›\" at the right end")]
    cap = re.search(r"^const capFirst = .*$", JS, re.M).group(0)
    cases = [{"reason": "No credit on the API key (Alex, Tue Jan 6th)", "since": FRI}, {"reason": "credit used up", "since": FRI},
             {"reason": "", "since": FRI}, {"reason": "usage check refused (hand)", "since": ""}, {"reason": "", "since": ""}]
    script = (prelude("en") + ZONE_JS + cap + "\n" + dayw + "\n" + JS[start:end2] +
              f"\nconsole.log(JSON.stringify({json.dumps(cases)}.map(dormantLine)));")
    out = json.loads(subprocess.run([NODE, "-e", script], capture_output=True, text=True, check=True, timeout=30).stdout)
    assert out == ["No credit on the API key since Tue Jan 6th", "No credit on the API key since Tue Jan 6th",
                   "Since Tue Jan 6th", "Usage check refused", ""]


def test_a_hand_set_reason_with_its_who_and_day_reads_once_on_the_overview_card(world, page, browser):
    record(world["rec"], ("api", "dormant", "no credit on the API key (Alex, Tue Jan 6th)", FRI, "", "hand"),
           ("subscription-2", "dormant", "Usage check refused (Alex, Tue Jan 6th)", SINCE, "", "hand"))
    open_overview(browser, page(), width=390)
    assert wait_for(browser, "document.querySelectorAll('#q-cards .q-dormant-line').length === 2")
    lines = browser.evaluate("[...document.querySelectorAll('#q-cards .q-dormant-line')].map((l) => l.textContent)")
    assert sorted(lines) == ["No credit on the API key since Tue Jan 6th", "Usage check refused since Mon Jan 5th"], lines
