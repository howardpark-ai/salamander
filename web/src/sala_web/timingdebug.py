"""The timing log (temporary): where a page load's milliseconds went, as the page measured them.

Why: after the update banner's Reload following a deploy, a page could show an empty
session list for minutes and then a session's history that took a minute or two, while the server answered every
request in milliseconds. The page, when its
flag is on (?debug=timing once; static/timing-debug.js, loaded by the block at the top of app.js; README "Timing"),
posts to POST /api/debug/timing, batched: the performance.mark()s app.js leaves at each step (app.js start, the session
list requested, rendered and painted, a session restored, the stream opened, its reset received, the history rendered
and painted, a reload and its cause, the service worker's lifecycle), the browser's navigation and resource timings,
its long tasks (over 50 ms), visibility changes and errors; each record carries the page load's id, the client's id
and the ms offset from the navigation's start. The log is <state_dir>/timing-debug.log (debuglog.py: one JSON object
a line, "ts" the server's UTC time, capped and rotated); GET /api/debug/timing gives its tail as one readable line a
record (summary below), ?raw=1 the JSON lines. Remove with the rest of the timing debug when the slow load is
understood.
"""

from __future__ import annotations

import json
from datetime import datetime

from . import tz

LOG_NAME = "timing-debug.log"


def header() -> str:
    """The log's first line; the zone it names is the setting's (SALA_TZ), local time when unset."""
    return f"# sala timing (temporary): time {tz.label()} | load | client | +ms from navigation start | record | details\n"


# the columns of the line; whatever else a record carries follows as key=value
COLUMNS = ("ts", "load", "client", "t", "name")
SKIP = frozenset(COLUMNS) | {"seq"}


def _when(ts: object) -> str:
    """The server's UTC "ts" as a clock time in the SALA_TZ zone (local when unset) with the date when it is not today's."""
    try:
        d = datetime.fromisoformat(str(ts).replace("Z", "+00:00")).astimezone(tz.zone())
    except (TypeError, ValueError):
        return str(ts or "-")[:23]
    today = tz.now().date()
    return d.strftime("%H:%M:%S.%f")[:-3] if d.date() == today else d.strftime("%b %d %H:%M:%S")


def _value(v: object) -> str:
    if isinstance(v, bool):
        return "yes" if v else "no"
    if isinstance(v, float):
        return f"{v:.1f}".rstrip("0").rstrip(".")
    if isinstance(v, (int, type(None))):
        return str(v)
    if isinstance(v, str):
        return v if v and " " not in v and "=" not in v and "\n" not in v else json.dumps(v, ensure_ascii=False)
    return json.dumps(v, ensure_ascii=False, separators=(",", ":"))


def summary(text: str) -> str:
    """The JSON lines as one readable line each: the time (in the SALA_TZ zone), the page load's id, the client's id, the offset in
    ms from the navigation's start, the record's name, then the rest as key=value. A line that is not JSON is kept as
    it is, marked; "" stays ""."""
    lines = []
    for ln in text.splitlines():
        if not ln.strip():
            continue
        try:
            d = json.loads(ln)
            if not isinstance(d, dict):
                raise ValueError
        except ValueError:
            lines.append(f"? {ln[:200]}")
            continue
        t = d.get("t")
        off = f"{'-':>9}"
        if isinstance(t, (int, float)) and not isinstance(t, bool):
            s = f"{t:+.1f}"
            off = f"{s[:-2] if s.endswith('.0') else s:>9}"  # +1391, +6331.7
        rest = " ".join(f"{k}={_value(v)}" for k, v in d.items() if k not in SKIP)
        lines.append(f"{_when(d.get('ts'))} {str(d.get('load') or '-'):6s} {str(d.get('client') or '-'):6s} {off} {d.get('name') or d.get('type') or '?'}"
                     + (f" {rest}" if rest else ""))
    return header() + "\n".join(lines) + "\n" if lines else ""
