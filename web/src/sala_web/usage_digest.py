"""The Digest view of the Overview's Usage analysis tab: the week in a few plain sentences, written by code from the rows usage.py counts.

`digest(answer)` is a pure function: it takes one week's answer of `UsageCache.get(week)` (the same dict `GET /api/usage?week=<n>` serves: `weeks`,
`lanes`, `rows`, `sameHours`, `resetKnown`) and returns a list of 1 to 7 sentences. Templates over the rows, no model call, no clock and no file
read, so a scheduled job can call it later to deliver the report at the weekly reset, and the same rows always give the same words. `answer(week_answer)` wraps
it for `GET /api/usage/digest?week=<0|1|2>`; the count underneath is the Report's own (one transcript scan, the last saved answer served at once;
saved by the daily count job or a Reload, "noCount" before the first count), so this module reads nothing.

What the sentences say, in order (a sentence with nothing to say is left out): the total at list prices and how much of it was billed; the busiest
day; the lane that took the largest share; the model; the project and the agent; how the week compares with the one before (the running week is
compared over the same hours); how much of a flat-plan lane's weekly limit is used (the running week only, and only when the quota answer has it).
Dollars only, never a token count. A flat-plan lane's dollars are "not billed" and the "billed" figure leaves them out, the words the Report's lane
cards use (static/usage.js, WORDS.flatLane, WORDS.billedLane, WORDS.machines; the tests check these constants against that file).
Dates read like "Sat Nov 7th", money like $12.40, days are KST. Only this machine's sessions are counted: `scope` says so.
"""

from __future__ import annotations

import re
from datetime import date, datetime, timedelta, timezone

KST = timezone(timedelta(hours=9))
UNNAMED = "(unnamed)"                                                    # usage.UNNAMED (not imported: this module reads no data layer)
FLAT = "flat plan, not billed"                                           # the Report's lane card words (usage.js WORDS.flatLane)
PER_USE = "billed per use (estimate)"                                    # usage.js WORDS.billedLane
SCOPE = "Other machines are not counted: only this machine's sessions."  # usage.js WORDS.machines
WEEK_WORDS = ["This week", "Last week", "Two weeks ago"]
SEVEN_DAYS = ["In the last seven days", "In the seven days before that", "In the seven days before those"]
MAX_SENTENCES = 7
SAME = 1.0     # a change under this many percent reads "about the same"
_FIELDS = ["day", "lane", "model", "project", "agent", "folder", "usd", "replies", "tokens"]


# ── the words ─────────────────────────────────────────────────────────────────
def ordinal(n: int) -> str:
    return f"{n}{'th' if 11 <= n % 100 <= 13 else {1: 'st', 2: 'nd', 3: 'rd'}.get(n % 10, 'th')}"


def day_text(iso: str) -> str:
    """'Sat Nov 7th' for a 'YYYY-MM-DD' day (an ISO day never appears in a sentence). Anything else is returned as it is."""
    try:
        d = date.fromisoformat(iso[:10])
    except (TypeError, ValueError):
        return str(iso)
    return f"{d.strftime('%a %b')} {ordinal(d.day)}"


def time_text(epoch: float) -> str:
    """'Wed Nov 11th at 2:00 PM KST' for an epoch second."""
    t = datetime.fromtimestamp(epoch, KST)
    h = t.hour % 12 or 12
    return f"{day_text(t.date().isoformat())} at {h}:{t.minute:02d} {'AM' if t.hour < 12 else 'PM'} KST"


def money(v: float) -> str:
    return f"${v:,.2f}"


def _is_all(part: float, whole: float) -> bool:
    """Whether `part` is the whole (to the cent): only then a sentence says "all of it"."""
    return part >= whole - 0.005


def percent(part: float, whole: float) -> str:
    p = part / whole * 100 if whole > 0 else 0.0
    if p < 0.5:
        return "under 1%"
    if p >= 99.5 and not _is_all(part, whole):
        return "over 99%"
    return f"{p:.0f}%" if p >= 9.95 else f"{p:.1f}%".replace(".0%", "%")


def quota_percent(v: float) -> str:
    return f"{v:.0f}%" if v >= 10 else f"{v:.1f}%".replace(".0%", "%")


def count(n: int, singular: str, plural: str) -> str:
    return f"{n:,} {singular if n == 1 else plural}"


def model_text(model: str) -> str:
    """'Opus 5' or 'Sonnet 4.5' for a model id (static/shared.js modelLabel's rule); another id as it is."""
    plain = re.sub(r"^(?:[a-z][a-z-]*\.)?anthropic\.", "", (model or "").rsplit("/", 1)[-1], flags=re.I)
    m = re.match(r"^claude-([a-z]+)-(\d+)(?:-(\d{1,2}))?(?!\d)", plain)
    if not m:
        return model or "an unknown model"
    return m.group(1).capitalize() + " " + m.group(2) + ("." + m.group(3) if m.group(3) else "") + (" (1M)" if "[1m]" in (model or "").lower() else "")


# ── the figures ───────────────────────────────────────────────────────────────
def _num(v) -> float:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) and v == v and abs(v) != float("inf") else 0.0


def _rows(answer: dict) -> list[dict]:
    """The week's rows as dicts by field name (a row too short or with a bad number is skipped, never a failed sentence)."""
    fields = answer.get("fields") if isinstance(answer.get("fields"), list) else _FIELDS
    ix = {f: fields.index(f) for f in ("day", "lane", "model", "project", "agent", "usd", "replies") if f in fields}
    out = []
    for r in answer.get("rows") or []:
        if not isinstance(r, (list, tuple)) or len(r) <= max(ix.values(), default=0) or len(ix) < 7:
            continue
        out.append({"day": str(r[ix["day"]]), "lane": str(r[ix["lane"]]), "model": str(r[ix["model"]]), "project": str(r[ix["project"]]),
                    "agent": str(r[ix["agent"]]), "usd": _num(r[ix["usd"]]), "replies": int(_num(r[ix["replies"]]))})
    return out


def _top(rows: list[dict], key: str) -> tuple[str, float] | None:
    """The value of `key` that took the most dollars, with its dollars (the first by name on a tie, so the answer never depends on row order)."""
    by: dict[str, float] = {}
    for r in rows:
        by[r[key]] = by.get(r[key], 0.0) + r["usd"]
    if not by:
        return None
    k = min(by, key=lambda x: (-by[x], x))
    return k, by[k]


def _share(part: float, whole: float) -> str:
    return f"{money(part)}, or {percent(part, whole)}"


def _period(answer: dict, w: dict | None) -> str:
    week = answer.get("week") if answer.get("week") in (0, 1, 2) else 0
    if not answer.get("resetKnown") or not w:
        return SEVEN_DAYS[week]
    start, end = day_text(str(w.get("startKst") or "")), day_text(str(w.get("endKst") or ""))
    if week == 0:
        return f"This week, since {start}"
    return f"{WEEK_WORDS[week]} ({start} to {end})"


def _lane_name(lanes: dict[str, dict], code: str) -> str:
    return str((lanes.get(code) or {}).get("label") or code)


def _compare(answer: dict, weeks: list, total: float) -> str | None:
    week = answer.get("week")
    if week == 0:
        sh = answer.get("sameHours") if isinstance(answer.get("sameHours"), dict) else {}
        before = _num(sh.get("prevTotal"))
        prev = weeks[1] if len(weeks) > 1 and isinstance(weeks[1], dict) else None
        had = bool(prev and _num(prev.get("replies")) > 0)
        what, whole = "the same hours of the week before", prev
    elif week == 1:
        prev = weeks[2] if len(weeks) > 2 and isinstance(weeks[2], dict) else None
        before = _num(prev.get("total")) if prev else 0.0
        had = bool(prev and _num(prev.get("replies")) > 0)
        what, whole = "the week before it", prev
    else:
        return "The count reaches back three weeks, so there is no earlier week to compare this one with."
    if not had:
        return "Nothing was counted in the week before, so there is nothing to compare this week with."
    if before <= 0:
        end = f", and it ended at {money(_num(whole.get('total')))}" if week == 0 and whole else ""
        return f"Nothing had been spent over {what}{end}, so there is no change to work out."
    change = (total - before) / before * 100
    if abs(change) < SAME:
        return f"That is about the same as {what} ({money(before)})."
    diff = money(abs(total - before))
    pct = f"{abs(change):.0f}%"
    return f"Compared with {what} ({money(before)}), that is {'up' if change > 0 else 'down'} {pct}, or {diff} {'more' if change > 0 else 'less'}."


def _limit(answer: dict, lanes: list) -> str | None:
    """How much of each flat-plan lane's weekly limit is used: the running week only (the quota answer is about the week now running)."""
    if answer.get("week") != 0:
        return None
    parts = []
    for ln in lanes:
        q = ln.get("quota") if isinstance(ln, dict) else None
        if not (isinstance(ln, dict) and ln.get("flat") and isinstance(q, dict) and isinstance(q.get("percent"), (int, float))):
            continue
        reset = q.get("resetsAt")
        tail = f", and it resets on {time_text(reset)}" if isinstance(reset, (int, float)) and not isinstance(reset, bool) else ""
        parts.append(f"{ln.get('label') or ln.get('code')}'s weekly limit is {quota_percent(float(q['percent']))} used so far{tail}")
    if not parts:
        return None
    text = "; ".join(parts[:3])
    return text[0].upper() + text[1:] + "."


def digest(answer: dict) -> list[str]:
    """The sentences for one week's answer (see the module docstring). Never raises on a missing or odd key: it says less."""
    if not isinstance(answer, dict) or not isinstance(answer.get("weeks"), list) or answer.get("week") not in (0, 1, 2):
        return []
    weeks = answer["weeks"]
    w = weeks[answer["week"]] if len(weeks) > answer["week"] and isinstance(weeks[answer["week"]], dict) else None
    rows = _rows(answer)
    lanes = {str(ln["code"]): ln for ln in answer.get("lanes") or [] if isinstance(ln, dict) and ln.get("code")}
    flat = {c for c, ln in lanes.items() if ln.get("flat")}
    replies = sum(r["replies"] for r in rows)
    total = sum(r["usd"] for r in rows)
    period = _period(answer, w)
    if replies == 0:
        return [f"{period}, no replies were counted on this machine."]
    if total <= 0:
        return [f"{period}, {count(replies, 'reply', 'replies')} on this machine cost $0.00, because no list price is known for the models used."]
    billed = sum(r["usd"] for r in rows if r["lane"] not in flat)
    not_billed = total - billed

    out = []
    # 1. the total and what was billed
    head = f"{period}, {count(replies, 'reply', 'replies')} on this machine cost {money(total)} at list prices"
    if billed < 0.005:
        out.append(f"{head}, and none of it was billed.")
    elif not_billed < 0.005:
        out.append(f"{head}, and all of it was billed.")
    else:
        out.append(f"{head}: {money(billed)} was billed, and the other {money(not_billed)} ran on a flat plan, so it was not billed.")
    # 2. the busiest day
    day = _top(rows, "day")
    if day:
        days = {r["day"] for r in rows if r["usd"] > 0}
        out.append(f"All of it was on {day_text(day[0])}." if len(days) == 1 else f"The busiest day was {day_text(day[0])}: {_share(day[1], total)} of the week.")
    # 3. the lane, 4. the model
    lane = _top(rows, "lane")
    if lane:
        kind = (FLAT if lane[0] in flat else PER_USE).replace(" (", ", ").replace(")", "")   # inside the sentence's own parentheses: "billed per use, estimate"
        name = _lane_name(lanes, lane[0])
        out.append(f"All of it ran on {name} ({kind})." if _is_all(lane[1], total)
                   else f"The largest share ran on {name} ({kind}): {_share(lane[1], total)} of the week.")
    model = _top(rows, "model")
    if model:
        out.append(f"All of it used {model_text(model[0])}." if _is_all(model[1], total)
                   else f"{model_text(model[0])} took the most among the models: {_share(model[1], total)} of the week.")
    # 5. the project and the agent
    proj, agent = _top(rows, "project"), _top(rows, "agent")
    if proj and agent:
        nobody = "sala does not know by name"
        if proj[0] == UNNAMED and agent[0] == UNNAMED:
            out.append(f"Sessions {nobody} took the most ({_share(proj[1], total)})." if not _is_all(proj[1], total) else f"All of it was sessions {nobody}.")
        else:
            first = (f"All of it was in the project {proj[0]}" if _is_all(proj[1], total)
                     else f"Sessions {nobody} took the most ({_share(proj[1], total)})" if proj[0] == UNNAMED
                     else f"The project that took the most was {proj[0]} ({_share(proj[1], total)})")
            second = f"the agent that took the most was {agent[0]} ({_share(agent[1], total)})" if agent[0] != UNNAMED \
                else f"the single session that took the most is one sala does not know by name ({_share(agent[1], total)})"
            out.append(f"{first}, and {second}.")
    # 6. against the week before, 7. the weekly limit
    for s in (_compare(answer, weeks, total), _limit(answer, answer.get("lanes") or [])):
        if s:
            out.append(s)
    return out[:MAX_SENTENCES]


def answer(week_answer: dict) -> dict:
    """The body of `GET /api/usage/digest?week=<n>`: the sentences for the week `UsageCache.get(n)` returned, with what the page needs around them.
    Before the first count there are no sentences and `noCount` is true (`pending` while a Reload's count runs: the page asks again); a count that failed keeps the last sentences and
    carries the `error` in plain words, as the Report's does."""
    a = week_answer if isinstance(week_answer, dict) else {}
    weeks = a.get("weeks") if isinstance(a.get("weeks"), list) else []
    week = a.get("week") if a.get("week") in (0, 1, 2) else 0
    w = weeks[week] if len(weeks) > week and isinstance(weeks[week], dict) else None
    out = {"week": week, "now": a.get("now"), "generated": a.get("generated"), "tz": a.get("tz"), "tzLabel": a.get("tzLabel"),
           "resetKnown": a.get("resetKnown"), "scope": SCOPE,
           "range": {"startKst": w.get("startKst"), "endKst": w.get("endKst"), "end": w.get("end"), "current": bool(w.get("current"))} if w else None,
           "sentences": [] if a.get("pending") or a.get("noCount") else digest(a)}
    for k in ("pending", "noCount", "refreshing", "error"):
        if a.get(k):
            out[k] = a[k]
    return out
