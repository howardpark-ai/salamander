"""Every scheduled job on this machine (the Overview's Schedules tab, GET /api/schedules).

No database and no file of its own: systemd and cron are asked what they hold right now, but not by a request. `SchedulesCache`
serves the last reading at once and has a fresh one read in the background once it is TTL old (swr.py: the lane cards' way), so
the tab draws without waiting on the ~1 s of systemctl calls; the reading carries `fetchedAt` (epoch ms) and, while a refresh
runs, `refreshing`. It is kept in memory only (its words "today 08:45" are counted from the moment it was read): after a restart
the first answer is {"pending": true} and the page asks again until the first reading lands.

  systemctl --user list-timers --all --output=json     the user timers (the system ones too, when `systemctl list-timers`
                                                         answers without sudo)
  systemctl [--user] show <units> -p …                 per unit: the service's ExecStart, Result, ExecMainStatus, ActiveState,
                                                         its last start, the unit file's path
  systemctl [--user] cat <units>                        the unit files as written (ONE call per scope for all the units, split
                                                         per unit by the `# <FragmentPath>` header each starts with; a unit
                                                         the batch does not return is asked alone, as before): the timer's On… lines, and the service's
                                                         `X-Model-Lane=` key in [Unit] (systemd ignores X- keys), its
                                                         `X-Project=` (the job's category: the project, written as the Agents
                                                         table's Project column shows it) and its optional `X-Model-Note=`
                                                         (shown beside the lane; never a flag)
  crontab -l                                            the user's crontab lines (all of them are flagged: move to a timer)
  git -C <dir> rev-parse / remote get-url / symbolic-ref   where a unit file or script lives, to build its GitHub link

Times are explicit: this box runs Etc/UTC, so every time in the answer is converted here to the SALA_TZ zone (this machine's local time when unset),
as an ISO string with the zone's offset (+05:30 for Asia/Kolkata), a human string ending in the zone's label (`text`) and the tab's own label-free form (`when`: "today 08:45", "Sun Nov 8th 05:17"; the day counted in that zone). Nothing is written anywhere. Commands that carry a secret on their line (NAME=value where the name
says token, key, secret or password) are shown with the value starred.

A unit file that is a regular file is not flagged when its first line says it was rendered from a template ("# Rendered by
install.sh from units/example-job.service.in — …", stackshot's install.sh): the row says "rendered from <template>" and
links the template, looked up under ~/stackshot and the repo of the unit's script.

A unit file that is a regular file and a byte-identical COPY of a tracked file of the same name in a known repo (a provision
script may install a repo's units that way) counts as in git and links that file; a copy that differs from its git file is flagged
`git-differs`; only a file with no git source is `not-git`. The known repos: ~/salamander, ~/stackshot, the checkouts of sala's
unit-repo table (`sala job`'s, ~/.config/salamander/unit-repos.tsv or SALA_JOB_REPOS), the render roots and the repo of the unit's script.

Only jobs that are ours are listed: a unit a package ships (a file under /usr/ or /lib/, either scope) is left out of the list
and the counts and only counted as `counts.packaged`. Each timer also carries `plain`: its schedule in plain words (a pure
function of the raw On… lines, `plain_schedule`), the raw lines staying in `schedule`.

Each timer also carries `project` (its `X-Project=`, the category the tab shows and sorts by; None when the service has none, which is
flagged `no-project`: the UI holds no table that places a job) and `summary` (its description with a leading "<job name> — " trimmed).

`collect(run=…)` takes the command runner as an argument so a test hands it recorded output; the default runs the real command.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import subprocess
from datetime import datetime, timezone, tzinfo
from pathlib import Path
from typing import Callable
from urllib.parse import quote
from zoneinfo import ZoneInfo

from . import lanestate as LS
from . import swr as SWR
from . import tz as TZ

TIMEOUT = 10.0
TTL = 30.0           # seconds: a reading older than this is read again in the background by the next request (the page follows it up)
ERROR_RETRY = 30.0   # a failed read is tried again this long after
LANES = ("subscription-1", "bedrock", "aws-platform", "api", "subscription-2", "sdk", "none")   # the values of X-Model-Lane; a unit on disk may still say max or team, which model_lane reads as the new codes (lanestate.RENAMED)
LANE_KEY = "X-Model-Lane"
PROJECT_KEY = "X-Project"   # the job's project: scope/project, as the Agents table's Project column shows it
NOTE_KEY = "X-Model-Note"   # optional, beside the lane
NOTE_MAX = 300
CRON_FLAG = "cron: move to a timer"
SHOW_PROPS = "Id,LoadState,ActiveState,SubState,Result,ExecMainStatus,ExecMainStartTimestamp,ExecMainExitTimestamp,ExecStart,FragmentPath,Description"
TIMER_PROPS = "Id,LoadState,FragmentPath,Unit,Description,TimersCalendar,TimersMonotonic,LastTriggerUSec"
SYSTEM_PACKAGE_DIRS = ("/usr/", "/lib/")   # a unit (system or user scope) shipped by a package: not ours, left out of the list
KNOWN_REPOS = ("salamander", "stackshot")   # under $HOME: where a unit file's git source is looked for (then the unit-repo table's checkouts)
NEVER_TEXT = "not yet run since boot"   # a timer with no last run on record: neutral, never a failure
_SECRET = re.compile(r"(?i)(\b[\w.-]*(?:token|secret|passw(?:or)?d|api[_-]?key|apikey|credential)[\w.-]*=)(\S+)")

Runner = Callable[[list[str]], "tuple[int, str]"]


def run_cmd(argv: list[str]) -> tuple[int, str]:
    """Run a command, stdout as text; (127, "") when it is not there, (124, "") when it takes too long."""
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=TIMEOUT, stdin=subprocess.DEVNULL, check=False,
                           env={**os.environ, "LC_ALL": "C", "GIT_TERMINAL_PROMPT": "0"})
    except FileNotFoundError:
        return 127, ""
    except subprocess.TimeoutExpired:
        return 124, ""
    return p.returncode, p.stdout


# ---- times ------------------------------------------------------------------------------------------------------------

def ordinal(n: int) -> str:
    return f"{n}{'th' if 10 <= n % 100 <= 20 else {1: 'st', 2: 'nd', 3: 'rd'}.get(n % 10, 'th')}"


def when_text(epoch_s: float, now_s: float | None = None) -> str:
    """A time as the Schedules tab's When column writes it, in the SALA_TZ zone (local time when unset), the day counted in that zone
    and not in the browser's or the box's: "today 08:45", "tomorrow 08:45", "yesterday 08:45", any other day "Sun Nov 8th 05:17".
    No zone label: the tab's header names the zone. `now_s` is the moment "today" is read at (default: now)."""
    z = TZ.zone()
    d = datetime.fromtimestamp(epoch_s, tz=timezone.utc).astimezone(z)
    n = datetime.fromtimestamp(now_s if now_s is not None else datetime.now(timezone.utc).timestamp(), tz=timezone.utc).astimezone(z)
    hm = d.strftime("%H:%M")
    day = {0: "today", 1: "tomorrow", -1: "yesterday"}.get((d.date() - n.date()).days)
    return f"{day} {hm}" if day else f"{d.strftime('%a %b')} {ordinal(d.day)} {hm}"


def zone_time(epoch_s: float | None, now_s: float | None = None) -> dict | None:
    """An epoch (seconds, UTC) as {"epoch", "iso" (with the zone's offset, +05:30 for IST), "text" ("Wed Oct 28th 14:07 IST"), "when"
    (`when_text`: "today 14:07", no label)} in the SALA_TZ zone (local time when unset), the label the zone's own; None for no time.
    `now_s` is the moment "today" in `when` is read at (default: now)."""
    if not epoch_s or epoch_s <= 0:
        return None
    d = datetime.fromtimestamp(epoch_s, tz=timezone.utc).astimezone(TZ.zone())
    return {"epoch": int(epoch_s), "iso": d.isoformat(timespec="seconds"),
            "text": f"{d.strftime('%a %b')} {ordinal(d.day)} {d.strftime('%H:%M')} {d.tzname()}", "when": when_text(epoch_s, now_s)}


def epoch_of_show(value: str) -> float | None:
    """A `systemctl show --timestamp=unix` value ("@1793162220"), or None for empty / n/a / 0."""
    v = (value or "").strip().lstrip("@")
    try:
        n = float(v)
    except ValueError:
        return None
    return n if n > 0 else None


# ---- systemd text -----------------------------------------------------------------------------------------------------

def parse_list_timers(text: str) -> list[dict]:
    """The rows of `list-timers --output=json` as {"unit", "activates", "next" (epoch s or None), "last" (epoch s or None)};
    the JSON's times are microseconds, 0 or null for none. [] for text that is no such list."""
    try:
        rows = json.loads(text)
    except ValueError:
        return []
    out = []
    for r in rows if isinstance(rows, list) else []:
        if not isinstance(r, dict) or not isinstance(r.get("unit"), str):
            continue

        def sec(v):
            return v / 1_000_000 if isinstance(v, (int, float)) and v > 0 else None
        out.append({"unit": r["unit"], "activates": r.get("activates") if isinstance(r.get("activates"), str) else "",
                    "next": sec(r.get("next")), "last": sec(r.get("last"))})
    return out


def parse_show(text: str) -> dict[str, dict[str, str]]:
    """`systemctl show a b …` output (blocks of Key=Value, a blank line between units) as {unit id: {key: value}}."""
    out: dict[str, dict[str, str]] = {}
    for block in re.split(r"\n\s*\n", text.strip("\n")):
        props: dict[str, str] = {}
        for line in block.splitlines():
            k, sep, v = line.partition("=")
            if sep:
                props.setdefault(k, v)   # the first of a repeated key (ExecStart of a unit with several)
        if props.get("Id"):
            out[props["Id"]] = props
    return out


def unit_sections(text: str) -> dict[str, list[tuple[str, str]]]:
    """A unit file's text (`systemctl cat`) as {section: [(key, value)]}; comments and the `# /path` headers of the file and its
    drop-ins are skipped, a section name that comes twice is merged."""
    sections: dict[str, list[tuple[str, str]]] = {}
    cur = None
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line[0] in "#;":
            continue
        m = re.match(r"^\[([^\]]+)\]$", line)
        if m:
            cur = m.group(1)
            sections.setdefault(cur, [])
        elif cur is not None and "=" in line:
            k, _, v = line.partition("=")
            sections[cur].append((k.strip(), v.strip()))
    return sections


def model_lane(cat_text: str) -> str | None:
    """The value of `X-Model-Lane=` in the [Unit] section (the last one wins, as a drop-in would), lower-cased, an old lane name (max,
    team, awsplatform) read as the lane's new code and the unit on disk left as it is; None if absent."""
    found = None
    for k, v in unit_sections(cat_text).get("Unit", []):
        if k == LANE_KEY:
            found = v.strip().lower()
    return LS.renamed(found) if found else None


def model_note(cat_text: str) -> str | None:
    """The value of the optional `X-Model-Note=` in the [Unit] section (a few words beside the lane, such as "+ api key check when an
    api/sdk session runs"; the last one wins), at most NOTE_MAX characters; None if absent or empty. Never a reason to flag."""
    found = None
    for k, v in unit_sections(cat_text).get("Unit", []):
        if k == NOTE_KEY:
            found = v.strip()
    return found[:NOTE_MAX] if found else None


def model_project(cat_text: str) -> str | None:
    """The value of `X-Project=` in the [Unit] section (the last one wins, as a drop-in would): the job's project as the Agents table's
    Project column writes it ("projects/demo"); None if absent or empty."""
    found = None
    for k, v in unit_sections(cat_text).get("Unit", []):
        if k == PROJECT_KEY:
            found = v.strip()
    return found if found else None


def project_map() -> dict[str, str]:
    """SALA_UNIT_PROJECT_MAP (the process environment, else sala's config line): space-separated `from=to` pairs. A unit's X-Project= value
    that equals a `from` is shown as its `to`, so an instance can file the shipped units' jobs under its own category without editing the
    units (they are copied byte for byte). A pair with no `=`, or an empty side, is ignored; a `from` named twice takes the last. Unset or
    empty: no mapping. lib/unitjob.py `project_map` reads it the same way."""
    from .config import sala_setting
    out: dict[str, str] = {}
    for pair in sala_setting("SALA_UNIT_PROJECT_MAP").split():
        a, eq, b = pair.partition("=")
        if eq and a and b:
            out[a] = b
    return out


def timer_schedule(cat_text: str, show: dict[str, str]) -> list[str]:
    """The timer's On… lines as written ("OnCalendar=*-*-* *:07/30:00"), else the ones `show` lists."""
    lines = [f"{k}={v}" for k, v in unit_sections(cat_text).get("Timer", []) if re.fullmatch(r"On\w+", k) and v]
    if lines:
        return lines
    return [f"{k}={v.strip()}" for k, v in re.findall(r"\{ (On\w+)=(.*?) ;", show.get("TimersCalendar", "") + " " + show.get("TimersMonotonic", ""))]


def parse_execstart(value: str) -> list[str]:
    """The argv of a `show -p ExecStart` value ("{ path=… ; argv[]=/usr/bin/python3 /x/check.py ; ignore_errors=no ; … }")."""
    m = re.search(r"argv\[\]=(.*?) ; ignore_errors=", value or "")
    return m.group(1).split() if m and m.group(1).strip() else []


def redact(text: str) -> str:
    return _SECRET.sub(lambda m: m.group(1) + "***", text)


def summary_of(description: str, name: str) -> str:
    """A unit's description without its leading "<job name> — " (also "-", "–" or ":" after the name, the name with or without .timer or
    .service); the description as it is when nothing is left or the name is not the start."""
    base = re.sub(r"\.(?:timer|service)$", "", name)
    trimmed = re.sub(r"^\s*" + re.escape(base) + r"(?:\.(?:timer|service))?\s*(?:[—–:]|-{1,2})\s*", "", description or "", count=1, flags=re.I)
    return trimmed.strip() or (description or "").strip()


# ---- a schedule in plain words ------------------------------------------------------------------------------------------

_UNIT_SECONDS = {"us": 1e-6, "usec": 1e-6, "ms": 1e-3, "msec": 1e-3, "": 1, "s": 1, "sec": 1, "second": 1, "seconds": 1,
                 "m": 60, "min": 60, "minute": 60, "minutes": 60, "h": 3600, "hr": 3600, "hour": 3600, "hours": 3600,
                 "d": 86400, "day": 86400, "days": 86400, "w": 604800, "week": 604800, "weeks": 604800}
_DAYS = ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")
_DAY_KEYS = {d[:3].lower(): i for i, d in enumerate(_DAYS)} | {d.lower(): i for i, d in enumerate(_DAYS)}
_SHORTCUTS = {"minutely": "*-*-* *:*:00", "hourly": "*-*-* *:00:00", "daily": "*-*-* 00:00:00", "midnight": "*-*-* 00:00:00",
              "weekly": "Mon *-*-* 00:00:00", "monthly": "*-*-01 00:00:00"}


def parse_span(text: str) -> float | None:
    """A systemd time span ("5min", "1h 30min", "90", "2 weeks") in seconds; None for text that is none or is zero."""
    t = text.strip()
    if not t or not re.fullmatch(r"(?:\s*\d+(?:\.\d+)?\s*[a-zA-Zµ]*)+", t):
        return None
    total = 0.0
    for num, unit in re.findall(r"(\d+(?:\.\d+)?)\s*([a-zA-Zµ]*)", t):
        if unit.lower() not in _UNIT_SECONDS:
            return None
        total += float(num) * _UNIT_SECONDS[unit.lower()]
    return total or None


def _span_words(sec: float, every: bool) -> str:
    """A span as "5 min" (every=False) or "every 5 min" / "every hour" / "every 2 hours" / "every day" (every=True)."""
    sec = max(1, int(round(sec)))
    for size, unit in ((86400, "day"), (3600, "hour"), (60, "min"), (1, "sec")):
        if sec % size == 0:
            n = sec // size
            break
    plural = "" if unit in ("min", "sec") or n == 1 else "s"
    if not every:
        return f"{n} {unit}{plural}"
    return f"every {({'min': 'minute', 'sec': 'second'}.get(unit, unit))}" if n == 1 else f"every {n} {unit}{plural}"


def _field(spec: str, lo: int, hi: int) -> tuple[list[int], str] | None:
    """A calendar field ("*", "30", "0,30", "*/10", "0/10", "9..17") as (sorted values, kind), kind "all", "step" (the whole field
    is one step: */N or a/N) or "list"; None when it is none of these."""
    if spec == "*":
        return list(range(lo, hi + 1)), "all"
    vals: set[int] = set()
    kind = "list"
    for part in spec.split(","):
        m = re.fullmatch(r"(\*|\d+)/(\d+)", part)
        if m:
            start = lo if m.group(1) == "*" else int(m.group(1))
            if int(m.group(2)) < 1 or not lo <= start <= hi:
                return None
            vals.update(range(start, hi + 1, int(m.group(2))))
            kind = "step" if spec == part else "list"
            continue
        m = re.fullmatch(r"(\d+)(?:\.\.(\d+))?", part)
        if not m:
            return None
        a, b = int(m.group(1)), int(m.group(2) or m.group(1))
        if not lo <= a <= b <= hi:
            return None
        vals.update(range(a, b + 1))
    return sorted(vals), kind


def _join(items: list[str]) -> str:
    return items[0] if len(items) == 1 else ", ".join(items[:-1]) + " and " + items[-1]


def _days_words(days: list[int]) -> str:
    if days == list(range(7)):
        return "every day"
    if len(days) == 1:
        return f"every {_DAYS[days[0]]}"
    if days == [0, 1, 2, 3, 4]:
        return "every weekday"
    if days == [5, 6]:
        return "every Saturday and Sunday"
    return "every " + _join([_DAYS[d][:3] for d in days])


def _seconds_words(sv: list[int], kind: str) -> str:
    """The seconds field of a job that runs every minute of the day, when it is not :00: "*" every second; "07" every minute, at :07;
    "*/20" or "0/20" every 20 sec; "7/30" every 30 sec, at :07 and :37; "5,10" every minute, at :05 and :10."""
    if len(sv) == 60:
        return "every second"
    at = "at " + _join([f":{x:02d}" for x in sv])
    if len(sv) > 1:
        step = sv[1] - sv[0]
        if 60 % step == 0 and sv == list(range(sv[0], 60, step)) and sv[0] < step:
            return f"every {step} sec" if kind == "step" and sv[0] == 0 else f"every {step} sec, {at}"
    return f"every minute, {at}"


def _calendar_words(expr: str, src: tzinfo, ref: datetime) -> str | None:
    """One OnCalendar expression in plain words with its clock times converted from `src` to the SALA_TZ zone (local when unset); None for a shape not handled."""
    parts = expr.split()
    if len(parts) > 1 and re.fullmatch(r"[A-Za-z][A-Za-z_]*(?:/[A-Za-z_+-]+)+|UTC|GMT", parts[-1]):   # a trailing zone name
        try:
            src = ZoneInfo(parts[-1])
        except Exception:
            return None
        parts = parts[:-1]
    if len(parts) == 1 and parts[0].lower() in _SHORTCUTS:
        parts = _SHORTCUTS[parts[0].lower()].split()
    days = list(range(7))
    if parts and re.fullmatch(r"[A-Za-z]+(?:(?:\.\.|,)[A-Za-z]+)*", parts[0]):
        got: set[int] = set()
        for piece in parts[0].lower().split(","):
            a, _, b = piece.partition("..")
            if a not in _DAY_KEYS or (b and b not in _DAY_KEYS) or _DAY_KEYS[a] > _DAY_KEYS[b or a]:
                return None
            got.update(range(_DAY_KEYS[a], _DAY_KEYS[b or a] + 1))
        days, parts = sorted(got), parts[1:]
    if len(parts) == 2:
        date_s, time_s = parts
    elif len(parts) == 1 and ":" in parts[0]:
        date_s, time_s = "*-*-*", parts[0]
    else:
        return None
    mday = None
    if date_s != "*-*-*":
        m = re.fullmatch(r"\*-\*-(\d{1,2})", date_s)
        if not m or not 1 <= int(m.group(1)) <= 28 or days != list(range(7)):
            return None
        mday = int(m.group(1))
    t = time_s.split(":")
    if len(t) == 2:
        t.append("0")
    if len(t) != 3:
        return None
    hours, minutes, secs = _field(t[0], 0, 23), _field(t[1], 0, 59), _field(t[2], 0, 59)
    if not (hours and minutes and secs):
        return None
    (hv, hk), (mv, mk) = hours, minutes
    (sv, sk) = secs
    on_the_minute = sv == [0]
    shift_min = int((ref.astimezone(TZ.zone()).utcoffset() - ref.astimezone(src).utcoffset()).total_seconds() // 60)
    if hk == "all" and mday is None and days == list(range(7)):   # every hour or more often
        if shift_min % 60:
            return None
        if not on_the_minute:   # a seconds field ("*-*-* *:*:07"): only for a job that runs every minute of the day
            return _seconds_words(sv, sk) if mk == "all" else None
        if mk == "all":
            return "every minute"
        if mv == [0]:
            return "every hour"
        if len(mv) == 1:
            return f"every hour at :{mv[0]:02d}"
        step = mv[1] - mv[0]
        even = 60 % step == 0 and mv == list(range(mv[0], 60, step)) and mv[0] < step
        at = "at " + _join([f":{x:02d}" for x in mv])
        if even and mk == "step" and mv[0] == 0:
            return f"every {step} min"
        return f"every {step} min, {at}" if even else f"every hour, {at}"
    if hk == "all" or len(mv) != 1 or (not on_the_minute and len(sv) != 1):
        return None
    if on_the_minute and hk == "step" and len(hv) > 1 and 24 % (hv[1] - hv[0]) == 0 and hv == list(range(0, 24, hv[1] - hv[0])) and mday is None and days == list(range(7)):
        return f"every {hv[1] - hv[0]} hours" + (f" at :{mv[0]:02d}" if mv[0] else "")
    clock, shifts = [], set()
    for h in hv:
        d = datetime(ref.year, ref.month, ref.day, h, mv[0], tzinfo=src)
        k = d.astimezone(TZ.zone())
        clock.append(f"{k.hour:02d}:{k.minute:02d}" + ("" if on_the_minute else f":{sv[0]:02d}"))
        shifts.add((k.date() - d.date()).days)
    if len(shifts) != 1:
        return None
    shift = shifts.pop()
    times = _join(clock)
    if mday is not None:
        if not 1 <= mday + shift <= 28:
            return None
        return f"on the {ordinal(mday + shift)} of every month at {times}"
    return f"{_days_words(sorted((x + shift) % 7 for x in days))} at {times}"


def plain_schedule(lines: list[str], tz: tzinfo | None = None, now: float | None = None) -> str:
    """A timer's On… lines in plain words: ["OnUnitActiveSec=5min"] "every 5 min"; ["OnCalendar=*:0/10"] "every 10 min";
    "*-*-* *:00,30:00" "every 30 min, at :00 and :30"; hourly "every hour"; daily "every day at 09:00"; weekly "every Monday at
    09:00"; ["OnBootSec=1min"] "once, 1 min after boot"; OnBootSec with OnUnitActiveSec "every 5 min, first 1 min after boot".
    The clock times of an OnCalendar line are read in `tz` (default: this box's zone, Etc/UTC here) and shown in the SALA_TZ zone (UTC in the examples; local time when unset)
    with no zone label (the tab's header names the zone), with the day moved when the zone change crosses midnight. Anything not recognized gives the raw lines joined with "; "."""
    raw = "; ".join(lines)
    props: dict[str, list[str]] = {}
    for ln in lines:
        k, _, v = ln.partition("=")
        props.setdefault(k.strip(), []).append(v.strip())
    ref = datetime.fromtimestamp(now if now is not None else datetime.now(timezone.utc).timestamp(), tz=timezone.utc)
    src = tz or datetime.now().astimezone().tzinfo or timezone.utc
    try:
        if set(props) == {"OnCalendar"}:
            words = [_calendar_words(v, src, ref) for v in props["OnCalendar"]]
            return "; ".join(words) if all(words) else raw
        if not props or set(props) - {"OnBootSec", "OnUnitActiveSec", "OnUnitInactiveSec"} or any(len(v) != 1 for v in props.values()) \
                or ("OnUnitActiveSec" in props and "OnUnitInactiveSec" in props):
            return raw
        boot = parse_span(props["OnBootSec"][0]) if "OnBootSec" in props else None
        key = "OnUnitActiveSec" if "OnUnitActiveSec" in props else "OnUnitInactiveSec"
        every = parse_span(props[key][0]) if key in props else None
        if ("OnBootSec" in props and boot is None) or (key in props and every is None):
            return raw
        first = f", first {_span_words(boot, False)} after boot" if boot is not None else ""
        if every is not None and key == "OnUnitActiveSec":
            return _span_words(every, True) + first
        if every is not None:   # OnUnitInactiveSec: counted from the moment the last run ended
            return f"{_span_words(every, False)} after each run ends" + first
        return f"once, {_span_words(boot, False)} after boot"
    except (ValueError, OverflowError):
        return raw


# ---- where a file lives: git and GitHub -----------------------------------------------------------------------------

_REMOTE = re.compile(r"^(?:https?://(?:[^@/]+@)?github\.com/|ssh://git@github\.com/|git@github\.com[-\w.]*:)([^/\s]+)/([^/\s]+?)(?:\.git)?/?$")


def github_repo(remote_url: str) -> tuple[str, str] | None:
    """(owner, repo) of a GitHub remote URL (https, ssh://, scp form, a token or an ssh host alias in it dropped); None for any other."""
    m = _REMOTE.match((remote_url or "").strip())
    return (m.group(1), m.group(2)) if m else None


class Repos:
    """git facts about paths, asked through `run` and remembered for one collect (a directory's repo is asked once)."""

    def __init__(self, run: Runner):
        self.run = run
        self._root: dict[str, str | None] = {}
        self._info: dict[str, dict | None] = {}
        self._tracked: dict[str, dict[str, list[str]]] = {}

    def tracked(self, root: str) -> dict[str, list[str]]:
        """{basename: [path relative to root]} of the files git tracks at root (`git ls-files`), asked once per collect."""
        if root not in self._tracked:
            rc, out = self.run(["git", "-C", root, "ls-files", "-z"])
            names: dict[str, list[str]] = {}
            for rel in (out.split("\0") if rc == 0 else []):
                if rel:
                    names.setdefault(os.path.basename(rel), []).append(rel)
            self._tracked[root] = names
        return self._tracked[root]

    def git_source(self, path: str, roots: list[str]) -> tuple[str, bool] | None:
        """The git file a plain file is a copy of: (absolute path of a tracked file of the same name in one of the repos at
        `roots`, True when its bytes are identical to `path`'s), preferring an identical one; None when no repo tracks that name."""
        try:
            with open(path, "rb") as f:
                mine = f.read()
        except OSError:
            return None
        differing = None
        for root in roots:
            for rel in self.tracked(root).get(os.path.basename(path), []):
                cand = os.path.join(root, rel)
                try:
                    with open(cand, "rb") as f:
                        same = f.read() == mine
                except OSError:
                    continue
                if same:
                    return os.path.realpath(cand), True
                differing = differing or (os.path.realpath(cand), False)
        return differing

    def root_of(self, path: str) -> str | None:
        d = path if os.path.isdir(path) else os.path.dirname(path)
        if d not in self._root:
            rc, out = self.run(["git", "-C", d, "rev-parse", "--show-toplevel"])
            self._root[d] = os.path.realpath(out.strip()) if rc == 0 and out.strip() else None
        return self._root[d]

    def info(self, root: str) -> dict | None:
        """{"owner", "repo", "branch"} of the repo at root when its origin is on GitHub, else None."""
        if root not in self._info:
            rc, url = self.run(["git", "-C", root, "remote", "get-url", "origin"])
            gh = github_repo(url) if rc == 0 else None
            self._info[root] = {"owner": gh[0], "repo": gh[1], "branch": self._branch(root)} if gh else None
        return self._info[root]

    def _branch(self, root: str) -> str:
        """The branch a link points at: origin's default, else main or master if origin has it, else the checked-out one."""
        rc, out = self.run(["git", "-C", root, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"])
        if rc == 0 and out.strip().startswith("origin/"):
            return out.strip()[len("origin/"):]
        for b in ("main", "master"):
            if self.run(["git", "-C", root, "rev-parse", "--verify", "-q", f"refs/remotes/origin/{b}"])[0] == 0:
                return b
        rc, out = self.run(["git", "-C", root, "rev-parse", "--abbrev-ref", "HEAD"])
        return out.strip() if rc == 0 and out.strip() and out.strip() != "HEAD" else "main"

    def link(self, real_path: str) -> str | None:
        """https://github.com/<owner>/<repo>/blob/<branch>/<path> for a file inside a GitHub-backed repo, else None."""
        root = self.root_of(real_path)
        info = self.info(root) if root else None
        if not root or not info:
            return None
        rel = os.path.relpath(real_path, root)
        if rel.startswith(".."):
            return None
        return f"https://github.com/{info['owner']}/{info['repo']}/blob/{quote(info['branch'], safe='/')}/{quote(rel, safe='/')}"


def tilde(path: str) -> str:
    home = str(Path.home())
    return "~" + path[len(home):] if path == home or path.startswith(home + "/") else path


RENDERED = re.compile(r"^#\s*Rendered by\s+\S+\s+from\s+(\S+\.in)\b")   # line 1 of a unit stackshot's install.sh rendered from a template in its repo


def rendered_from(frag: str) -> str | None:
    """The template path ("units/example-job.service.in") named by a unit file's first line when it carries the
    "# Rendered by install.sh from <template>.in" marker, else None."""
    try:
        with open(frag, encoding="utf-8", errors="replace") as f:
            first = f.readline().lstrip("﻿")
    except OSError:
        return None
    m = RENDERED.match(first)
    return m.group(1) if m else None


def template_file(template: str, roots: list[str]) -> str | None:
    """The template's real path: a relative one looked up under each root (the stackshot checkout, the repo of the unit's script)."""
    if os.path.isabs(template):
        return os.path.realpath(template) if os.path.isfile(template) else None
    for r in roots:
        p = os.path.join(r, template)
        if os.path.isfile(p):
            return os.path.realpath(p)
    return None


def table_checkouts() -> list[str]:
    """The checkouts of sala's unit-repo table, the one `sala job` reads (lib/unitjob.py repos_path): SALA_JOB_REPOS, else
    ~/.config/salamander/unit-repos.tsv; the tracked lib/unit-repos.tsv lists none, so no table is no checkout. Column 2, ~ expanded."""
    from .config import sala_setting
    p = sala_setting("SALA_JOB_REPOS") or os.path.join(os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config"),
                                                       "salamander", "unit-repos.tsv")
    out: list[str] = []
    try:
        with open(os.path.expanduser(p), encoding="utf-8") as f:
            for line in f:
                cols = line.rstrip("\n").split("\t")
                if line.lstrip().startswith("#") or len(cols) < 2 or cols[0] == "*" or not cols[1].strip():
                    continue
                out.append(os.path.expanduser(cols[1].strip()))
    except (OSError, UnicodeDecodeError):
        return []
    return out


def known_roots(repos: Repos, extra: list[str]) -> list[str]:
    """The repos a copied unit file is looked up in: ~/salamander, ~/stackshot, the unit-repo table's checkouts, then `extra`
    (the render roots and the repo of the unit's script); each is a git toplevel that exists, once."""
    home = Path.home()
    out: list[str] = []
    for d in [*(str(home / n) for n in KNOWN_REPOS), *table_checkouts(), *extra]:
        if d and os.path.isdir(d):
            top = repos.root_of(os.path.realpath(d))
            if top and top not in out:
                out.append(top)
    return out


def unit_file_state(frag: str, repos: Repos, roots: list[str] | None = None, git_roots: list[str] | None = None) -> dict:
    """Where a unit file lives: {"path" (as systemd has it), "real" (readlink -f), "symlink", "in_git", "link" (GitHub),
    "copy_of" (the tracked file a byte-identical plain copy was made from, else None), "rendered" ({"template", "link"} for a
    plain file whose first line names the template it was rendered from), "problem" (a sentence when it is neither a symlink
    into a git repo, nor rendered from a template, nor an identical copy of a git file, else None), "problem_code"
    ("not-git" | "git-differs")}. git_roots: the repos a plain file's git source is looked up in."""
    if not frag:
        return {"path": "", "real": "", "symlink": False, "in_git": False, "link": None, "copy_of": None, "rendered": None,
                "problem": "no unit file found", "problem_code": "not-git"}
    real = os.path.realpath(frag)
    symlink = os.path.islink(frag)
    in_git = repos.root_of(real) is not None
    link = repos.link(real) if in_git else None
    rendered = None
    copy_of = None
    problem = None
    code = "not-git"
    if not symlink:
        template = rendered_from(real)
        if template:
            tfile = template_file(template, roots or [])
            rendered = {"template": template, "link": repos.link(tfile) if tfile else None}
        else:
            src = repos.git_source(real, git_roots or []) if not in_git else None
            if src and src[1]:
                copy_of, in_git, link = src[0], True, repos.link(src[0])
            elif src:
                code, link = "git-differs", repos.link(src[0])
                problem = f"{os.path.basename(frag)} ({tilde(os.path.dirname(frag))}) is a copy that differs from {tilde(src[0])} in git"
            else:
                problem = f"{os.path.basename(frag)} is a plain file ({tilde(os.path.dirname(frag))}), not a symlink into a git repo"
    elif not in_git:
        problem = f"{os.path.basename(frag)} links to {tilde(real)}, which is not in a git repo"
    return {"path": frag, "real": real, "symlink": symlink, "in_git": in_git, "link": link, "copy_of": copy_of, "rendered": rendered,
            "problem": problem, "problem_code": code}


_SYSTEM_PREFIXES = ("/usr/", "/bin/", "/sbin/", "/lib/", "/etc/", "/opt/", "/snap/", "/proc/", "/dev/")


def pick_script(argv: list[str], repos: Repos) -> str | None:
    """The script a command runs: its first argument (argv[0] included) that is an existing absolute file inside a git repo, else
    the first existing file outside the system directories, else None (a `bash -c '…'` or a binary on the PATH)."""
    files = []
    for a in argv:
        a = os.path.expanduser(a) if a.startswith("~/") else a
        if a.startswith("/") and os.path.isfile(a):
            files.append(os.path.realpath(a))
    for f in files:
        if repos.root_of(f):
            return f
    return next((f for f in files if not f.startswith(_SYSTEM_PREFIXES)), None)


# ---- the collector ----------------------------------------------------------------------------------------------------

def _flag(code: str, text: str) -> dict:
    return {"code": code, "text": text}


def journal_last(scope: str, run: Runner, service: str) -> float | None:
    """The time of the newest journal entry of a service (epoch s), or None: the last run of a job whose systemd timestamps a boot
    cleared (a weekly or monthly timer), when the journal outlives the boot."""
    if not service:
        return None
    rc, out = run(["journalctl", *(["--user"] if scope == "user" else []), "-u", service, "-n", "1", "-o", "json",
                   "--output-fields=MESSAGE", "--no-pager", "-q"])
    if rc != 0:
        return None
    try:
        usec = float(json.loads(out.strip().splitlines()[-1]).get("__REALTIME_TIMESTAMP", 0))
    except (ValueError, IndexError, AttributeError):
        return None
    return usec / 1_000_000 if usec > 0 else None


def _result(svc: dict[str, str], last: float | None = None) -> dict:
    """The service's last result: {"state": ok | failed | running | never | unknown, "text"}. never: no last run on record
    anywhere (the service's own start time, the timer's last trigger, the journal), which is not a failure."""
    active = svc.get("ActiveState", "")
    result = svc.get("Result", "")
    status = svc.get("ExecMainStatus", "")
    if active == "failed" or (result and result != "success"):
        why = result or "failed"
        return {"state": "failed", "text": f"failed: {why}" + (f", exit status {status}" if status not in ("", "0") else "")}
    if active in ("active", "activating", "reloading") and svc.get("SubState") != "exited":
        return {"state": "running", "text": "running now"}
    if not (epoch_of_show(svc.get("ExecMainStartTimestamp", "")) or last):
        return {"state": "never", "text": NEVER_TEXT}
    return {"state": "ok", "text": "success"}


def split_cat(text: str, order: list[tuple[str, str]]) -> dict[str, str]:
    """One `systemctl cat a b c` output cut into {unit: its text}. Each unit's text starts at the `# <FragmentPath>` line (or `# <FragmentPath> -> <target>`
    for a symlink) of its
    unit file (its drop-ins' `# …` lines come after it, so a drop-in never starts a unit) and runs to the next unit's; the blank line
    systemctl puts between units is not part of either. `order` is (unit, FragmentPath) in the order the units were asked for. A unit
    whose header is not in the output (not found: systemctl skips it, says so on stderr and exits 1) is left out of the answer."""
    lines = text.splitlines(keepends=True)
    starts: list[tuple[int, str]] = []
    pos = 0
    for unit, frag in order:
        want = f"# {frag}"   # a symlinked unit file is headed "# <FragmentPath> -> <target>"
        i = next((k for k in range(pos, len(lines)) if lines[k].rstrip("\r\n") == want or lines[k].startswith(want + " -> ")), None)
        if i is not None:
            starts.append((i, unit))
            pos = i + 1
    out: dict[str, str] = {}
    for n, (i, unit) in enumerate(starts):
        block = lines[i:starts[n + 1][0] if n + 1 < len(starts) else len(lines)]
        if n + 1 < len(starts) and block and not block[-1].strip():
            block.pop()   # the separator before the next unit
        out[unit] = "".join(block)
    return out


def cat_units(ctl: list[str], wanted: list[tuple[str, str]], run: Runner) -> dict[str, str]:
    """{unit: `systemctl cat` text} for the units in `wanted` ((unit, FragmentPath) pairs, FragmentPath "" when show had none): one call
    for all that have a unit file of their own, instead of one call per unit. A unit the batch does not give back (not found, a file
    two units share, an output that does not split) is asked alone, which is what each unit used to cost; "" when that fails too."""
    seen: dict[str, str] = {}
    for unit, frag in wanted:
        seen.setdefault(unit, frag)
    batch, frags = [], set()
    for unit, frag in seen.items():
        if frag and frag not in frags:
            frags.add(frag)
            batch.append((unit, frag))
    got: dict[str, str] = {}
    if len(batch) > 1:
        _rc, out = run([*ctl, "cat", "--no-pager", *(u for u, _ in batch)])
        got = split_cat(out, batch)
    result = {}
    for unit in seen:
        if unit in got:
            result[unit] = got[unit]
        else:
            _rc, text = run([*ctl, "cat", "--no-pager", unit])
            result[unit] = text
    return result


def _scope_args(scope: str) -> list[str]:
    return ["systemctl", "--user"] if scope == "user" else ["systemctl"]


def collect_scope(scope: str, run: Runner, repos: Repos, roots: list[str], repo_roots: list[str] | None = None, now: float | None = None) -> tuple[list[dict], int] | None:
    """(the scope's timers that are ours, as rows; how many packaged ones were left out); None when the scope's timers cannot be
    listed (no systemd, or not readable without sudo). repo_roots: extra repos a copied unit file's source is looked up in
    (besides ~/salamander, ~/stackshot, the unit-repo table's checkouts and the repo of the unit's script). now: the moment "today" in a time's `when` is read at (default: now)."""
    ctl = _scope_args(scope)
    rc, out = run([*ctl, "list-timers", "--all", "--output=json", "--no-pager"])
    if rc != 0:
        return None
    listed = parse_list_timers(out)
    if not listed:
        return [], 0
    timer_ids = [t["unit"] for t in listed]
    service_ids = sorted({t["activates"] for t in listed if t["activates"]})
    _rc, tshow_text = run([*ctl, "show", "--no-pager", "--timestamp=unix", "-p", TIMER_PROPS, *timer_ids])
    _rc, sshow_text = run([*ctl, "show", "--no-pager", "--timestamp=unix", "-p", SHOW_PROPS, *service_ids])
    tshow, sshow = parse_show(tshow_text), parse_show(sshow_text)
    visible = []
    hidden = 0
    for t in listed:   # a unit shipped by a package (apt-daily, fstrim, certbot…) is not ours: not listed, its files not read
        tprops = tshow.get(t["unit"], {})
        frag = sshow.get(t["activates"] or tprops.get("Unit", ""), {}).get("FragmentPath", "") or tprops.get("FragmentPath", "")
        if frag.startswith(SYSTEM_PACKAGE_DIRS):
            hidden += 1
        else:
            visible.append(t)
    wanted = []
    for t in visible:
        tprops = tshow.get(t["unit"], {})
        sname = t["activates"] or tprops.get("Unit", "")
        wanted.append((t["unit"], tprops.get("FragmentPath", "")))
        if sname:
            wanted.append((sname, sshow.get(sname, {}).get("FragmentPath", "")))
    cats = cat_units(ctl, wanted, run)
    rows = []
    for t in visible:
        tprops = tshow.get(t["unit"], {})
        sname = t["activates"] or tprops.get("Unit", "")
        svc = sshow.get(sname, {})
        tcat = cats.get(t["unit"], "")
        scat = cats.get(sname, "") if sname else ""
        argv = parse_execstart(svc.get("ExecStart", ""))
        script = pick_script(argv, repos)
        script_root = repos.root_of(script) if script else None
        uroots = [*roots, *([script_root] if script_root else [])]
        groots = known_roots(repos, [*(repo_roots or []), *uroots])
        sfile = unit_file_state(svc.get("FragmentPath", ""), repos, uroots, groots)
        tfile = unit_file_state(tprops.get("FragmentPath", ""), repos, uroots, groots)
        lane = model_lane(scat)
        project = model_project(scat)
        project = project_map().get(project, project) if project else project   # SALA_UNIT_PROJECT_MAP
        loaded = svc.get("LoadState") == "loaded"
        # the last run: the service's own start time, else the timer's last trigger, else the journal (a boot clears the first two)
        last = epoch_of_show(svc.get("ExecMainStartTimestamp", "")) or epoch_of_show(tprops.get("LastTriggerUSec", "")) or t["last"]
        if not last and loaded:
            last = journal_last(scope, run, sname)
        result = _result(svc, last) if loaded else {"state": "unknown", "text": f"service unit {sname or '(none)'} not loaded"}
        flags = []
        if result["state"] == "failed":
            flags.append(_flag("failed", f"last run {result['text']}"))
        if result["state"] == "unknown":
            flags.append(_flag("no-service", result["text"]))
        for what, f in (("service", sfile), ("timer", tfile)):
            if f["problem"]:
                flags.append(_flag(f["problem_code"], f"{what} unit: {f['problem']}"))
        if lane is None:
            flags.append(_flag("no-lane", f"no {LANE_KEY}= in the service unit's [Unit] section"))
        elif lane not in LANES:
            flags.append(_flag("bad-lane", f"{LANE_KEY}={lane} is none of {', '.join(LANES)}"))
        if project is None:
            flags.append(_flag("no-project", f"no {PROJECT_KEY}= in the service unit's [Unit] section (sala job set-project {sname.removesuffix('.service') or t['unit'].removesuffix('.timer')} <scope/project>)"))
        runs = redact(" ".join(argv)) if argv else ""
        sched = timer_schedule(tcat, tprops)
        rows.append({
            "scope": scope, "name": t["unit"], "service": sname, "description": (desc := svc.get("Description") or tprops.get("Description", "")),
            "summary": summary_of(desc, t["unit"]), "project": project,
            "runs": {"command": os.path.basename(argv[0]) if argv else "", "script": tilde(script) if script else "",
                     "line": tilde(runs) if runs else ""},
            "schedule": sched, "plain": plain_schedule(sched),
            "next": zone_time(t["next"], now), "last": zone_time(last, now), "result": result, "lane": lane,
            "lane_note": model_note(scat),
            "links": {"script": repos.link(script) if script else None, "service": sfile["link"], "timer": tfile["link"]},
            "rendered": {k: f["rendered"] for k, f in (("service", sfile), ("timer", tfile)) if f["rendered"]},
            "unit_files": {"service": tilde(sfile["path"]), "timer": tilde(tfile["path"])},
            "flags": flags,
        })
    return rows, hidden


def parse_crontab(text: str) -> list[dict]:
    """The jobs in `crontab -l` output: {"schedule", "command", "line", "flags"}; comments, blank lines and NAME=value
    environment lines are skipped."""
    jobs = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or re.match(r"^[A-Za-z_][A-Za-z0-9_]*\s*=", line):
            continue
        if line.startswith("@"):
            parts = line.split(None, 1)
            sched, cmd = parts[0], parts[1] if len(parts) > 1 else ""
        else:
            parts = line.split(None, 5)
            if len(parts) < 6:
                continue
            sched, cmd = " ".join(parts[:5]), parts[5]
        jobs.append({"schedule": sched, "command": redact(cmd), "flags": [_flag("cron", CRON_FLAG)]})
    return jobs


def collect(run: Runner = run_cmd, now: float | None = None, render_roots: list[str] | None = None) -> dict:
    """{"generated", "timers": [...], "cron": [...], "counts", "scopes"}: the user timers, the system timers when they are readable
    without sudo (ours only: packaged ones are counted in counts.packaged, not listed), and the user's crontab. render_roots: where a "units/x.in" template is looked up (default ~/stackshot)."""
    repos = Repos(run)
    roots = [str(Path.home() / "stackshot")] if render_roots is None else list(render_roots)
    timers, scopes, packaged = [], {}, 0
    for scope in ("user", "system"):
        got = collect_scope(scope, run, repos, roots, now=now)
        scopes[scope] = got is not None
        timers += got[0] if got else []
        packaged += got[1] if got else 0
    _rc, cron_text = run(["crontab", "-l"])   # no crontab is a non-zero exit with a message on stderr: stdout is empty then
    cron = parse_crontab(cron_text if _rc == 0 else "")
    by_reason: dict[str, int] = {}
    for item in [*timers, *cron]:
        for code in {f["code"] for f in item["flags"]}:
            by_reason[code] = by_reason.get(code, 0) + 1
    counts = {"timers": len(timers), "cron": len(cron), "packaged": packaged,
              "flagged": sum(1 for x in [*timers, *cron] if x["flags"]), "byReason": dict(sorted(by_reason.items()))}
    return {"generated": zone_time(now if now is not None else datetime.now(timezone.utc).timestamp()), "timezone": TZ.setting(), "tzLabel": TZ.label(),
            "timers": timers, "cron": cron, "counts": counts, "scopes": scopes}


class SchedulesCache:
    """The reading, served at once from the last good one and read again in the background once it is TTL old (swr.py): the page
    never waits on systemd. In memory only. `get(fresh=True)` (the Reload button) makes the reading due now: the answer still comes
    at once, with the old reading and `refreshing`, and the page asks again for the new one. With no reading yet the answer is
    {"pending": true, ...} and the first read runs. A read that fails keeps the last reading and puts "error" on it."""

    def __init__(self, collector: Callable[[], dict] | None = None):
        self._collector = collector
        self._swr = SWR.Revalidating(None, TTL, ERROR_RETRY, {"generated": None, "timezone": "", "tzLabel": "", "timers": [], "cron": [],
                                                              "counts": {"timers": 0, "cron": 0, "packaged": 0, "flagged": 0, "byReason": {}},
                                                              "scopes": {}})

    def get(self, fresh: bool = False) -> dict:
        if fresh and not self._swr.running:
            self._swr.expire()
        return self._swr.serve(self._refresh)

    async def _refresh(self) -> dict:
        return await asyncio.to_thread(self._collector or collect)
