"""The Overview's Schedules tab data (schedules.py, GET /api/schedules): every timer and cron line on the machine, read live
from systemd and cron, with the model lane and the project (X-Project=, the Category) of each, the GitHub link of its script and
unit file, and a flag (with its reason) on a job that failed, has no lane, has no project, or is not a symlink into a git repo.

What a wrong answer costs: a job that failed or has no model lane shown as healthy (the page exists to find those), a unit
that stackshot rendered from a template flagged as loose (a flag nobody can clear), a time shown in the box's UTC where the owner
reads the configured zone, a link to a file that is not in the repo, or a secret on a crontab line printed on the page.

Nothing here needs systemd, cron or the network: the collector takes the command runner as an argument, and the tests hand it
recorded output (list-timers JSON, `systemctl show` and `systemctl cat` text, crontab text). The git calls are real, against
repositories made in tmp_path with an `origin` remote that is only a URL.

The tab itself (one sortable table, the Category from the job's own project, no timer) is checked in a headless Chromium
when one is installed (conftest.py: `served`, `browser`), else skipped; api/schedules is answered by a stub installed before the
page loads.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import time
from datetime import datetime, timedelta, timezone

from zoneinfo import ZoneInfo

import pytest
from starlette.testclient import TestClient

from sala_web import schedules as SCH
from sala_web.app import create_app
from sala_web.config import Settings

NEXT = datetime(2026, 10, 28, 0, 0, tzinfo=timezone.utc).timestamp()    # 04:00 +04 the same day
LAST = datetime(2026, 10, 27, 20, 30, tzinfo=timezone.utc).timestamp()  # 00:30 +04 the next day: the date changes
MARKER = "# Rendered by install.sh from units/stackshot-x.service.in — edit the template, not this file.\n"


def git_repo(path, remote):
    path.mkdir(parents=True)
    subprocess.run(["git", "init", "-q", "-b", "main", str(path)], check=True)
    subprocess.run(["git", "-C", str(path), "remote", "add", "origin", remote], check=True)
    return path


def service_text(lane: str | None, comment: bool = True, note: str | None = None, project: str | None = None) -> str:
    head = "[Unit]\nDescription=x\n"
    if project is not None:
        head += f"X-Project={project}\n"
    if lane is not None:
        head += ("# which model lane this job bills to\n" if comment else "") + f"X-Model-Lane={lane}\n"
    if note is not None:
        head += f"X-Model-Note={note}\n"
    return head + "\n[Service]\nType=oneshot\nExecStart=/bin/true\n"


def timer_text(sched: str = "OnCalendar=*-*-* 09:00:00") -> str:
    return f"[Unit]\nDescription=t\n\n[Timer]\n# a comment\n{sched}\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n"


class Box:
    """A fake machine: units laid out in tmp_path, and a runner that answers systemctl and crontab from them."""

    def __init__(self, tmp_path):
        self.tmp = tmp_path
        self.user = tmp_path / "config" / "systemd" / "user"
        self.user.mkdir(parents=True)
        self.repo = git_repo(tmp_path / "config-repo", "git@github.com:example-org/config-repo.git")
        (self.repo / "units").mkdir()
        (self.repo / "bin").mkdir()
        self.timers: list[dict] = []
        self.cron = ""
        self.system: str | None = None   # list-timers JSON for the system scope; None = not readable without sudo
        self.calls: list[list[str]] = []
        self.trigger: dict[str, float] = {}   # timer name -> LastTriggerUSec (epoch s) the timer reports
        self.journal: dict[str, float] = {}   # service name -> time of its newest journal entry (epoch s)
        self.missing: set[str] = set()        # units `systemctl cat` does not find (it skips them and exits 1)
        self.dropin: dict[str, str] = {}      # unit -> the text of a drop-in file, printed after the unit

    def script(self, name="job.sh") -> str:
        p = self.repo / "bin" / name
        p.write_text("#!/bin/bash\ntrue\n")
        return str(p)

    def add(self, name, *, lane="subscription-1", link=True, rendered=None, result="success", active="inactive", status="0",
            script=None, nxt=NEXT, last=LAST, sched="OnCalendar=*-*-* 09:00:00", description="a job", started=True, note=None, project="projects/demo"):
        """One timer + service pair. link: both unit files are symlinks into the repo; else plain files. rendered: the plain
        files' first line names this template."""
        script = script or self.script(f"{name}.sh")
        svc, tmr = f"{name}.service", f"{name}.timer"
        s_txt, t_txt = service_text(lane, note=note, project=project), timer_text(sched)
        if link:
            for fn, txt in ((svc, s_txt), (tmr, t_txt)):
                (self.repo / "units" / fn).write_text(txt)
                (self.user / fn).symlink_to(self.repo / "units" / fn)
        else:
            first = rendered or ""
            (self.user / svc).write_text(first + s_txt)
            (self.user / tmr).write_text(first + t_txt)
        self.timers.append({"name": name, "svc": svc, "tmr": tmr, "s_txt": s_txt, "t_txt": t_txt, "script": script, "result": result,
                            "active": active, "status": status, "next": nxt, "last": last, "description": description,
                            "started": started, "first": rendered or ""})

    def listing(self, scope="user") -> str:
        rows = [{"next": int(t["next"] * 1e6) if t["next"] else 0, "left": 1, "last": int(t["last"] * 1e6) if t["last"] else 0,
                 "passed": 1, "unit": t["tmr"], "activates": t["svc"]} for t in self.timers]
        return json.dumps(rows)

    def show(self, argv: list[str]) -> str:
        props = argv[argv.index("-p") + 1]
        blocks = []
        for u in argv[argv.index("-p") + 2:]:
            t = next(x for x in self.timers if u in (x["svc"], x["tmr"]))
            if u.endswith(".timer"):
                blocks.append(f"Id={u}\nLoadState=loaded\nFragmentPath={self.user / u}\nUnit={t['svc']}\nDescription={t['description']}\n"
                              f"TimersCalendar={{ OnCalendar=*-*-* 09:00:00 ; next_elapse=x }}\n"
                              + (f"LastTriggerUSec=@{int(self.trigger[u])}\n" if u in self.trigger else "LastTriggerUSec=\n"))
            else:
                ts = f"@{int(t['last'])}" if t["started"] else ""
                blocks.append(f"Id={u}\nLoadState=loaded\nActiveState={t['active']}\nSubState=dead\nResult={t['result']}\n"
                              f"ExecMainStatus={t['status']}\nExecMainStartTimestamp={ts}\nExecMainExitTimestamp={ts}\n"
                              f"FragmentPath={self.user / u}\nDescription={t['description']}\n"
                              f"ExecStart={{ path=/bin/bash ; argv[]=/bin/bash {t['script']} --flag ; ignore_errors=no ; start_time=[n/a] }}\n")
        assert props.startswith("Id,")
        return "\n".join(blocks)

    def cat(self, unit: str) -> str:
        """One unit as `systemctl cat` prints it: the `# <file>` header (`# <file> -> <target>` for a symlink), the text, then the
        drop-in `dropin[unit]` under its own header when there is one."""
        t = next(x for x in self.timers if unit in (x["svc"], x["tmr"]))
        path = self.user / unit
        head = f"# {path} -> {path.resolve()}\n" if path.is_symlink() else f"# {path}\n"
        text = head + (t["first"] + (t["s_txt"] if unit.endswith(".service") else t["t_txt"]))
        if unit in self.dropin:
            text += f"\n# {path}.d/10-extra.conf\n{self.dropin[unit]}"
        return text

    def cat_many(self, units: list[str]) -> tuple[int, str]:
        """`systemctl cat a b c`: the units one after another with a blank line between; one that is not found is skipped (the message
        goes to stderr) and the exit status is 1; a unit named twice is printed twice."""
        known = [u for u in units if u not in self.missing and any(u in (x["svc"], x["tmr"]) for x in self.timers)]
        return (0 if len(known) == len(units) else 1), "\n".join(self.cat(u) for u in known)

    def __call__(self, argv: list[str]):
        self.calls.append(argv)
        if argv[0] == "git":
            return SCH.run_cmd(argv)
        if argv[0] == "crontab":
            return (0, self.cron) if self.cron else (1, "")
        if argv[0] == "journalctl":
            when = self.journal.get(argv[argv.index("-u") + 1])
            return 0, (json.dumps({"MESSAGE": "x", "__REALTIME_TIMESTAMP": str(int(when * 1e6))}) + "\n" if when else "")
        assert argv[0] == "systemctl"
        user = "--user" in argv
        verb = next(a for a in argv[1:] if not a.startswith("-"))
        if verb == "list-timers":
            if user:
                return 0, self.listing()
            return (0, self.system) if self.system is not None else (1, "")
        if verb == "show":
            return 0, self.show(argv)
        if verb == "cat":
            return self.cat_many([a for a in argv[argv.index("cat") + 1:] if not a.startswith("-")])
        raise AssertionError(argv)


@pytest.fixture
def box(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))   # nothing of the real home is read
    # ~/config-repo is a known repo through sala's unit-repo table (SALA_JOB_REPOS), as a box that lists its repos there has it
    (tmp_path / "unit-repos.tsv").write_text("# made-up table\nconfig-repo\t~/config-repo\tunits/{name}\t-\tmain\tteam/demo\tdemo-builder\t-\texample-org/config-repo\n")
    monkeypatch.setenv("SALA_JOB_REPOS", str(tmp_path / "unit-repos.tsv"))
    return Box(tmp_path)


def track(box, name, same=True):
    """Put a unit file of `name` into the Box's repo as a tracked file, byte-identical to the installed copy (or different)."""
    for fn in (f"{name}.service", f"{name}.timer"):
        text = (box.user / fn).read_text()
        (box.repo / "units" / fn).write_text(text if same else text + "# edited in git\n")
    subprocess.run(["git", "-C", str(box.repo), "add", "units"], check=True)


def by_name(data, name):
    return next(t for t in data["timers"] if t["name"] == name)


def codes(t):
    return sorted(f["code"] for f in t["flags"])


# ---- the pieces -------------------------------------------------------------------------------------------------------

def test_list_timers_json_is_microseconds_and_zero_is_none():
    rows = SCH.parse_list_timers(json.dumps([
        {"next": 1793145600000000, "left": 5, "last": 0, "passed": 0, "unit": "a.timer", "activates": "a.service"},
        {"next": None, "unit": "b.timer", "activates": "b.service"}, {"nope": 1}]))
    assert rows == [{"unit": "a.timer", "activates": "a.service", "next": 1793145600.0, "last": None},
                    {"unit": "b.timer", "activates": "b.service", "next": None, "last": None}]
    assert SCH.parse_list_timers("not json") == []


def test_zone_conversion_of_a_utc_timestamp():
    t = SCH.zone_time(NEXT)   # 2026-10-28 00:00 UTC
    assert t["iso"] == "2026-10-28T04:00:00+04:00"
    assert t["text"] == "Wed Oct 28th 04:00 +04"
    # the date changes across the zone: 20:30 UTC on the 27th is 00:30 on the 28th in Dubai
    assert SCH.zone_time(LAST)["iso"] == "2026-10-28T00:30:00+04:00"
    assert SCH.zone_time(LAST)["text"].startswith("Wed Oct 28th 00:30")
    assert SCH.zone_time(0) is None and SCH.zone_time(None) is None
    assert SCH.zone_time(NEXT, now_s=NEXT)["when"] == "today 04:00" and "+04" not in SCH.zone_time(NEXT)["when"]
    assert [SCH.ordinal(n) for n in (1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 31)] == ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "23rd", "31st"]


def _ts(y, mo, d, h, mi, tz=timezone.utc) -> float:
    return datetime(y, mo, d, h, mi, tzinfo=tz).timestamp()


DXB = ZoneInfo("Asia/Dubai")
NOW_DXB = _ts(2026, 11, 1, 12, 0, DXB)   # Sun Nov 1st 2026 12:00 in Dubai


@pytest.mark.parametrize("when_local, words", [
    ((2026, 11, 1, 8, 45), "today 08:45"),
    ((2026, 11, 1, 23, 59), "today 23:59"),
    ((2026, 11, 1, 0, 0), "today 00:00"),
    ((2026, 11, 2, 8, 45), "tomorrow 08:45"),
    ((2026, 11, 2, 23, 59), "tomorrow 23:59"),
    ((2026, 10, 31, 15, 30), "yesterday 15:30"),
    ((2026, 10, 31, 0, 0), "yesterday 00:00"),
    ((2026, 11, 3, 8, 45), "Tue Nov 3rd 08:45"),            # two days on is a date, not "tomorrow"
    ((2026, 10, 30, 8, 45), "Fri Oct 30th 08:45"),           # two days back too
    ((2026, 11, 8, 5, 17), "Sun Nov 8th 05:17"),
    ((2026, 12, 25, 18, 5), "Fri Dec 25th 18:05"),
])
def test_when_text_names_today_tomorrow_yesterday_and_dates_otherwise(when_local, words):
    assert SCH.when_text(_ts(*when_local, DXB), NOW_DXB) == words


@pytest.mark.parametrize("day, suffix", [(1, "st"), (2, "nd"), (3, "rd"), (4, "th"), (10, "th"), (11, "th"), (12, "th"), (13, "th"),
                                         (14, "th"), (20, "th"), (21, "st"), (22, "nd"), (23, "rd"), (24, "th"), (30, "th"), (31, "st")])
def test_when_text_ordinals_including_the_teens(day, suffix):
    # every day of a 31-day month, a fortnight or more from "today": always a date
    now = _ts(2026, 12, 15, 12, 0, DXB)
    target = _ts(2027, 1, day, 9, 30, DXB)
    want_day = datetime(2027, 1, day).strftime("%a")
    assert SCH.when_text(target, now) == f"{want_day} Jan {day}{suffix} 09:30"


def test_when_text_counts_the_day_in_the_SALA_TZ_zone_not_the_boxs_or_the_browsers(monkeypatch):
    # 2026-11-01 20:10 UTC is 00:10 on Mon Nov 2nd in Dubai; the box's (UTC) date is still Nov 1st
    now = _ts(2026, 11, 1, 20, 10)
    monkeypatch.setenv("SALA_TZ", "Asia/Dubai")
    assert SCH.when_text(_ts(2026, 11, 1, 19, 50), now) == "yesterday 23:50"      # 19:50 UTC: the same UTC day as now, the day before in Dubai
    assert SCH.when_text(_ts(2026, 11, 1, 20, 30), now) == "today 00:30"
    assert SCH.when_text(_ts(2026, 11, 2, 19, 59), now) == "today 23:59"          # 19:59 UTC on the 2nd is still the 2nd in Dubai ...
    assert SCH.when_text(_ts(2026, 11, 2, 20, 0), now) == "tomorrow 00:00"        # ... and 20:00 UTC is the 3rd there
    # the same instants in a zone behind UTC: 03:00 UTC on Nov 2nd is 19:00 on Sun Nov 1st in Los Angeles (PST)
    monkeypatch.setenv("SALA_TZ", "America/Los_Angeles")
    now = _ts(2026, 11, 2, 3, 0)
    assert SCH.when_text(_ts(2026, 11, 2, 8, 0), now) == "tomorrow 00:00"         # 08:00 UTC is Nov 2nd 00:00 in LA; "today" is the 1st there
    assert SCH.when_text(_ts(2026, 11, 2, 7, 59), now) == "today 23:59"
    assert SCH.when_text(_ts(2026, 11, 1, 6, 59), now) == "yesterday 23:59"       # 06:59 UTC on Nov 1st is Oct 31st 23:59 in LA (PDT)
    # a zone that is a day ahead of Los Angeles gives the other day for the very same instants
    monkeypatch.setenv("SALA_TZ", "Pacific/Auckland")
    assert SCH.when_text(_ts(2026, 11, 2, 8, 0), now) == "today 21:00"            # NZDT, UTC+13: Nov 2nd 21:00, and "now" is Nov 2nd 16:00 there


def test_when_text_has_no_zone_label_whatever_the_zone(monkeypatch):
    for zone in ("Asia/Dubai", "Europe/Berlin", "America/New_York", "Etc/UTC"):
        monkeypatch.setenv("SALA_TZ", zone)
        for ts in (_ts(2026, 11, 1, 3, 0), _ts(2026, 11, 8, 3, 0)):
            words = SCH.when_text(ts, _ts(2026, 11, 1, 3, 0))
            assert re.fullmatch(r"(today|tomorrow|yesterday) \d\d:\d\d|[A-Z][a-z]{2} [A-Z][a-z]{2} \d{1,2}(st|nd|rd|th) \d\d:\d\d", words), words


def test_the_lane_is_read_from_the_unit_section_only():
    assert SCH.model_lane(service_text("subscription-1")) == "subscription-1"
    assert SCH.model_lane(service_text("Bedrock", comment=False)) == "bedrock"
    assert SCH.model_lane(service_text("none")) == "none"
    assert SCH.model_lane(service_text(None)) is None
    # an X- key in another section is not the lane; a drop-in's later value wins
    assert SCH.model_lane("[Unit]\nDescription=x\n[Service]\nX-Model-Lane=max\n") is None
    assert SCH.model_lane("[Unit]\nX-Model-Lane=max\n\n# /etc/x.service.d/o.conf\n[Unit]\nX-Model-Lane=api\n") == "api"


def test_github_remote_forms():
    for url in ("git@github.com:example-org/stackshot.git", "https://github.com/example-org/stackshot",
                "https://x-access-token@github.com/example-org/stackshot.git", "ssh://git@github.com/example-org/stackshot.git",
                "git@github.com-work:example-org/stackshot.git"):
        assert SCH.github_repo(url) == ("example-org", "stackshot"), url
    assert SCH.github_repo("git@gitlab.invalid:a/b.git") is None and SCH.github_repo("") is None


def test_the_schedule_is_shown_as_written():
    assert SCH.timer_schedule(timer_text("OnBootSec=2min"), {}) == ["OnBootSec=2min"]
    assert SCH.timer_schedule("[Timer]\nOnBootSec=5min\nOnUnitActiveSec=1h\n", {}) == ["OnBootSec=5min", "OnUnitActiveSec=1h"]
    # a unit file that cannot be read: what `show` lists
    assert SCH.timer_schedule("", {"TimersCalendar": "{ OnCalendar=*-*-* 09:00:00 ; next_elapse=x }"}) == ["OnCalendar=*-*-* 09:00:00"]


def test_execstart_argv():
    v = "{ path=/usr/bin/python3 ; argv[]=/usr/bin/python3 /x/check.py -v ; ignore_errors=no ; start_time=[n/a] }"
    assert SCH.parse_execstart(v) == ["/usr/bin/python3", "/x/check.py", "-v"]
    assert SCH.parse_execstart("") == []


# ---- a schedule in plain words ----------------------------------------------------------------------------------------

UTC = ZoneInfo("Etc/UTC")
DXB_ZONE = ZoneInfo("Asia/Dubai")


@pytest.mark.parametrize("lines, words", [
    (["OnUnitActiveSec=5min"], "every 5 min"),
    (["OnUnitActiveSec=1h"], "every hour"),
    (["OnUnitActiveSec=2h"], "every 2 hours"),
    (["OnUnitActiveSec=90min"], "every 90 min"),
    (["OnUnitActiveSec=1d"], "every day"),
    (["OnUnitActiveSec=30s"], "every 30 sec"),
    (["OnUnitActiveSec=1h 30min"], "every 90 min"),
    (["OnCalendar=*:0/10"], "every 10 min"),
    (["OnCalendar=*-*-* *:0/15:00"], "every 15 min"),
    (["OnCalendar=*-*-* *:00,30:00"], "every 30 min, at :00 and :30"),
    (["OnCalendar=*-*-* *:07/30:00"], "every 30 min, at :07 and :37"),
    (["OnCalendar=*-*-* *:00,20:00"], "every hour, at :00 and :20"),
    (["OnCalendar=*-*-* *:15:00"], "every hour at :15"),
    (["OnCalendar=minutely"], "every minute"),
    (["OnCalendar=hourly"], "every hour"),
    (["OnCalendar=daily"], "every day at 04:00"),            # 00:00 in the box's UTC is 04:00 in Dubai
    (["OnCalendar=*-*-* 20:30:00"], "every day at 00:30"),
    (["OnCalendar=*-*-* 03,06:00:00"], "every day at 07:00 and 10:00"),
    (["OnCalendar=*-*-* 0/6:00:00"], "every 6 hours"),
    (["OnCalendar=weekly"], "every Monday at 04:00"),
    (["OnCalendar=Sun *-*-* 22:00:00"], "every Monday at 02:00"),   # the weekday moves with the clock across midnight
    (["OnCalendar=Mon..Fri *-*-* 03:30:00"], "every weekday at 07:30"),
    (["OnCalendar=Mon,Wed *-*-* 21:00"], "every Tue and Thu at 01:00"),
    (["OnCalendar=monthly"], "on the 1st of every month at 04:00"),
    (["OnCalendar=*-*-15 21:00:00"], "on the 16th of every month at 01:00"),
    (["OnCalendar=*-*-* 09:00:00 Asia/Dubai"], "every day at 09:00"),
    # a seconds field (wind-probe's `*-*-* *:*:07` read "OnCalendar=*-*-* *:*:07" on the page)
    (["OnCalendar=*-*-* *:*:07"], "every minute, at :07"),
    (["OnCalendar=*:*:07"], "every minute, at :07"),
    (["OnCalendar=*-*-* *:*:00"], "every minute"),
    (["OnCalendar=*-*-* *:*:0/20"], "every 20 sec"),
    (["OnCalendar=*-*-* *:*:*/30"], "every 30 sec"),
    (["OnCalendar=*-*-* *:*:07/30"], "every 30 sec, at :07 and :37"),
    (["OnCalendar=*-*-* *:*:05,10"], "every minute, at :05 and :10"),
    (["OnCalendar=*-*-* *:*:*"], "every second"),
    (["OnCalendar=*-*-* 20:30:45"], "every day at 00:30:45"),
    (["OnBootSec=5min"], "once, 5 min after boot"),
    (["OnBootSec=1min", "OnUnitActiveSec=5min"], "every 5 min, first 1 min after boot"),
    (["OnBootSec=2h", "OnUnitActiveSec=1d"], "every day, first 2 hours after boot"),
    (["OnBootSec=1min", "OnUnitInactiveSec=30s"], "30 sec after each run ends, first 1 min after boot"),
])
def test_a_schedule_in_plain_words(lines, words):
    assert SCH.plain_schedule(lines, tz=UTC, now=NEXT) == words


@pytest.mark.parametrize("lines", [
    ["OnCalendar=*-*-* *:15:07"],             # a seconds field next to a fixed minute: not a shape handled
    ["OnCalendar=*-*-* 09..17:*:07"],         # ... or next to an hour range
    ["OnCalendar=*-*-* 15:30:10,20"],          # a fixed time with more than one second
    ["OnCalendar=quarterly"],
    ["OnCalendar=2026-12-25 10:00:00"],
    ["OnCalendar=*-*-31 10:00"],
    ["OnCalendar=*-*-* 03,20:00:00"],         # one time crosses midnight in Dubai and the other does not
    ["OnCalendar=Mon *-*-* 03:00", "OnBootSec=5min"],
    ["OnStartupSec=1h"],
    ["OnBootSec=soon"],
    ["OnUnitActiveSec=5min", "OnUnitInactiveSec=5min"],
    ["OnCalendar=not a calendar"],
    ["OnCalendar=*-*-* 09:00:00 Nowhere/Land"],
])
def test_anything_not_recognized_falls_back_to_the_raw_lines(lines):
    assert SCH.plain_schedule(lines, tz=UTC, now=NEXT) == "; ".join(lines)


def test_calendar_times_follow_the_zone_they_are_written_in():
    # the box runs UTC; a unit that names its own zone is read in that zone; both end up in the configured zone
    assert SCH.plain_schedule(["OnCalendar=*-*-* 00:00:00"], tz=UTC, now=NEXT) == "every day at 04:00"
    assert SCH.plain_schedule(["OnCalendar=*-*-* 00:00:00"], tz=DXB_ZONE, now=NEXT) == "every day at 00:00"
    assert SCH.plain_schedule(["OnCalendar=*-*-* 00:00:00 America/New_York"], tz=UTC, now=NEXT) == "every day at 08:00"
    assert SCH.plain_schedule([], tz=UTC, now=NEXT) == ""


def test_the_api_row_carries_the_plain_words_and_keeps_the_raw_lines(box):
    box.add("t", sched="OnCalendar=*-*-* 09:00:00")
    t = by_name(SCH.collect(box, now=NEXT), "t.timer")
    assert t["schedule"] == ["OnCalendar=*-*-* 09:00:00"] and t["plain"].startswith("every day at ") and t["plain"][-5:-3].isdigit()
    assert "+04" not in t["plain"]   # no zone label: the tab's header names the zone


# ---- the category: the job's own project ---------------------------------------------------------------------------------

def test_the_project_is_read_from_the_service_units_unit_section_only():
    assert SCH.model_project("[Unit]\nDescription=x\nX-Project=projects/lamp\n\n[Service]\nExecStart=/bin/true\n") == "projects/lamp"
    assert SCH.model_project("[Unit]\nDescription=x\n\n[Service]\nX-Project=projects/lamp\n") is None   # not in [Unit]: not the job's
    assert SCH.model_project("[Unit]\n# X-Project=projects/lamp\nDescription=x\n") is None                  # a comment is not a setting
    assert SCH.model_project("[Unit]\nX-Project=\n") is None                                                # empty: no project


def test_the_api_carries_each_timers_own_project(box):
    box.add("dusk-run", project="projects/lamp")
    box.add("beta-feed-watch", project="beta/docs")
    box.add("brand-new", project=None)
    data = SCH.collect(box, now=NEXT)
    assert [by_name(data, n)["project"] for n in ("dusk-run.timer", "beta-feed-watch.timer", "brand-new.timer")] == ["projects/lamp", "beta/docs", None]
    assert "groups" not in data and "group" not in by_name(data, "dusk-run.timer")   # no fixed list of groups: the category is the job's own


def test_the_project_map_shows_a_units_project_as_another_and_unset_changes_nothing(box, monkeypatch):
    box.add("mapped", project="sala/salamander")
    box.add("other", project="projects/lamp")
    box.add("none", project=None)
    monkeypatch.delenv("SALA_UNIT_PROJECT_MAP", raising=False)
    data = SCH.collect(box, now=NEXT)
    assert [by_name(data, n)["project"] for n in ("mapped.timer", "other.timer", "none.timer")] == ["sala/salamander", "projects/lamp", None]
    monkeypatch.setenv("SALA_UNIT_PROJECT_MAP", "sala/salamander=team/demo")
    data = SCH.collect(box, now=NEXT)
    assert [by_name(data, n)["project"] for n in ("mapped.timer", "other.timer", "none.timer")] == ["team/demo", "projects/lamp", None]
    assert "no-project" not in codes(by_name(data, "mapped.timer")) and "no-project" in codes(by_name(data, "none.timer"))   # the gap flag still follows the unit


def test_a_malformed_project_map_is_ignored_without_error(box, monkeypatch):
    box.add("mapped", project="sala/salamander")
    for bad in ("", "   ", "sala/salamander", "sala/salamander=", "=team/demo", "x==y"):
        monkeypatch.setenv("SALA_UNIT_PROJECT_MAP", bad)
        assert by_name(SCH.collect(box, now=NEXT), "mapped.timer")["project"] == "sala/salamander", bad
    monkeypatch.setenv("SALA_UNIT_PROJECT_MAP", "junk sala/salamander=team/demo =z")   # a good pair among bad ones still applies
    assert by_name(SCH.collect(box, now=NEXT), "mapped.timer")["project"] == "team/demo"
    assert SCH.project_map() == {"sala/salamander": "team/demo"}


def test_a_job_with_no_project_is_flagged_with_the_command_that_sets_it(box):
    box.add("brand-new", project=None)
    row = by_name(SCH.collect(box, now=NEXT), "brand-new.timer")
    assert codes(row) == ["no-project"]
    assert "X-Project=" in row["flags"][0]["text"] and "sala job set-project brand-new" in row["flags"][0]["text"]


def test_a_job_with_a_project_is_not_flagged_for_it(box):
    box.add("dusk-run", project="projects/lamp")
    assert "no-project" not in codes(by_name(SCH.collect(box, now=NEXT), "dusk-run.timer"))


def test_the_code_holds_no_table_that_places_a_job():
    import inspect
    src = inspect.getsource(SCH)
    assert "GROUP_RULES" not in src and "group_of" not in src and "fnmatch" not in src


@pytest.mark.parametrize("desc, name, want", [
    ("wind-probe — One probe of the test link", "wind-probe.timer", "One probe of the test link"),
    ("wind-probe - One probe", "wind-probe.timer", "One probe"),
    ("Wind-Probe: One probe", "wind-probe.service", "One probe"),
    ("Relay cache: board items", "relay-cache.timer", "Relay cache: board items"),   # not the job's name: left alone
    ("wind-probe", "wind-probe.timer", "wind-probe"),                                                   # nothing left: as it is
    ("", "x.timer", ""),
])
def test_the_description_loses_its_name_prefix(desc, name, want):
    assert SCH.summary_of(desc, name) == want


def test_the_api_row_carries_the_trimmed_description(box):
    box.add("t", description="t — Does a thing")
    row = by_name(SCH.collect(box, now=NEXT), "t.timer")
    assert row["summary"] == "Does a thing" and row["description"] == "t — Does a thing"


# ---- the collector ----------------------------------------------------------------------------------------------------

def test_a_linked_unit_with_a_lane_is_clean_and_links_to_github(box):
    box.add("good", lane="subscription-1")
    data = SCH.collect(box, now=NEXT)
    t = by_name(data, "good.timer")
    assert t["lane"] == "subscription-1" and t["flags"] == []
    assert t["runs"]["command"] == "bash" and t["runs"]["script"].endswith("/config-repo/bin/good.sh")
    assert t["links"]["script"] == "https://github.com/example-org/config-repo/blob/main/bin/good.sh"
    assert t["links"]["service"] == "https://github.com/example-org/config-repo/blob/main/units/good.service"
    assert t["links"]["timer"] == "https://github.com/example-org/config-repo/blob/main/units/good.timer"
    assert t["schedule"] == ["OnCalendar=*-*-* 09:00:00"]
    assert t["scope"] == "user" and t["result"] == {"state": "ok", "text": "success"}


def test_times_are_in_the_configured_zone_in_the_answer(box):
    box.add("t")
    data = SCH.collect(box, now=NEXT)
    t = by_name(data, "t.timer")
    assert t["next"]["iso"] == "2026-10-28T04:00:00+04:00" and t["next"]["text"] == "Wed Oct 28th 04:00 +04"
    assert t["last"]["iso"] == "2026-10-28T00:30:00+04:00"
    assert t["next"]["when"] == "today 04:00" and t["last"]["when"] == "today 00:30"   # the day counted at `now`, in the zone; no label
    assert data["generated"]["iso"] == "2026-10-28T04:00:00+04:00" and data["timezone"] == "Asia/Dubai"


def test_a_missing_lane_is_flagged_with_its_reason(box):
    box.add("nolane", lane=None)
    t = by_name(SCH.collect(box), "nolane.timer")
    assert codes(t) == ["no-lane"] and t["lane"] is None
    assert "X-Model-Lane" in t["flags"][0]["text"]


def test_the_lane_note_is_read_and_never_flagged(box):
    box.add("noted", lane="subscription-1", note="+ api key check when an api/sdk session runs")
    box.add("plain", lane="subscription-1")
    box.add("only-note", lane=None, note="why there is no lane")
    data = SCH.collect(box)
    assert by_name(data, "noted.timer")["lane_note"] == "+ api key check when an api/sdk session runs"
    assert by_name(data, "noted.timer")["flags"] == []
    assert by_name(data, "plain.timer")["lane_note"] is None
    assert codes(by_name(data, "only-note.timer")) == ["no-lane"]   # a note does not stand in for the lane
    assert SCH.model_note(service_text("subscription-1", note="  ")) is None
    assert SCH.model_note("[Service]\nX-Model-Note=elsewhere\n") is None
    assert len(SCH.model_note(service_text("subscription-1", note="x" * 1000))) == SCH.NOTE_MAX


def test_an_unknown_lane_is_flagged(box):
    box.add("odd", lane="opus")
    t = by_name(SCH.collect(box), "odd.timer")
    assert codes(t) == ["bad-lane"] and "opus" in t["flags"][0]["text"]


def test_a_plain_file_is_flagged_not_a_symlink_into_git(box):
    box.add("loose", link=False)
    t = by_name(SCH.collect(box), "loose.timer")
    assert codes(t) == ["not-git", "not-git"]   # the service unit and the timer unit
    assert all("not a symlink into a git repo" in f["text"] for f in t["flags"])


def test_a_copy_identical_to_a_tracked_file_counts_as_in_git_and_links_it(box):
    # a provision script installs a table repo's unit files as byte-identical copies, not symlinks
    box.add("copied", link=False)
    track(box, "copied")
    t = by_name(SCH.collect(box), "copied.timer")
    assert t["flags"] == []
    assert t["links"]["service"] == "https://github.com/example-org/config-repo/blob/main/units/copied.service"
    assert t["links"]["timer"] == "https://github.com/example-org/config-repo/blob/main/units/copied.timer"


def test_a_repo_in_no_unit_repo_table_is_not_a_known_repo(box, monkeypatch):
    # no table (SALA_JOB_REPOS unset, no ~/.config/salamander/unit-repos.tsv): only ~/salamander and ~/stackshot are known,
    # so the same byte-identical copy (its script outside the repo) has no git source
    monkeypatch.delenv("SALA_JOB_REPOS")
    monkeypatch.setenv("XDG_CONFIG_HOME", str(box.tmp / "config"))
    (box.tmp / "elsewhere.sh").write_text("#!/bin/sh\n")
    box.add("copied", link=False, script=str(box.tmp / "elsewhere.sh"))
    track(box, "copied")
    t = by_name(SCH.collect(box), "copied.timer")
    assert codes(t) == ["not-git", "not-git"]


def test_a_copy_that_differs_from_its_git_file_is_flagged_differs_from_git(box):
    box.add("drifted", link=False)
    track(box, "drifted", same=False)
    t = by_name(SCH.collect(box), "drifted.timer")
    assert codes(t) == ["git-differs", "git-differs"]   # the service unit and the timer unit
    assert all("differs from" in f["text"] and "units/drifted." in f["text"] for f in t["flags"])
    assert t["links"]["service"].endswith("/units/drifted.service")   # the row still links the file it was copied from
    assert SCH.collect(box)["counts"]["byReason"] == {"git-differs": 1}


def test_one_identical_source_among_several_same_named_files_is_enough(box):
    other = git_repo(box.tmp / "salamander", "git@github.com:example-org/salamander.git")
    box.add("twice", link=False)
    track(box, "twice")
    (other / "twice.timer").write_text("[Timer]\nOnBootSec=1\n")   # another repo has a different file of that name
    subprocess.run(["git", "-C", str(other), "add", "."], check=True)
    assert by_name(SCH.collect(box), "twice.timer")["flags"] == []


def test_a_copy_is_looked_up_in_the_repo_of_the_units_script_too(box):
    other = git_repo(box.tmp / "elsewhere-repo", "git@github.com:example-org/other.git")
    (other / "bin").mkdir()
    script = other / "bin" / "o.sh"
    script.write_text("#!/bin/bash\ntrue\n")
    box.add("scripted", link=False, script=str(script))
    for fn in ("scripted.service", "scripted.timer"):
        (other / fn).write_text((box.user / fn).read_text())
    subprocess.run(["git", "-C", str(other), "add", "."], check=True)
    t = by_name(SCH.collect(box), "scripted.timer")
    assert t["flags"] == [] and t["links"]["timer"] == "https://github.com/example-org/other/blob/main/scripted.timer"


def test_a_plain_file_with_no_git_source_keeps_not_in_git(box):
    box.add("orphan", link=False)
    (box.repo / "units" / "unrelated.service").write_text("x")   # a tracked file of another name is no source
    subprocess.run(["git", "-C", str(box.repo), "add", "units"], check=True)
    assert codes(by_name(SCH.collect(box), "orphan.timer")) == ["not-git", "not-git"]


def test_a_symlink_to_a_file_outside_git_is_flagged(box):
    target = box.tmp / "elsewhere"
    target.mkdir()
    (target / "o.service").write_text(service_text("subscription-1"))
    (target / "o.timer").write_text(timer_text())
    for n in ("o.service", "o.timer"):
        (box.user / n).symlink_to(target / n)
    box.timers.append({"name": "o", "svc": "o.service", "tmr": "o.timer", "s_txt": service_text("subscription-1", project="projects/demo"), "t_txt": timer_text(), "script": box.script("o.sh"),
                       "result": "success", "active": "inactive", "status": "0", "next": NEXT, "last": LAST, "description": "", "started": True, "first": ""})
    t = by_name(SCH.collect(box), "o.timer")
    assert codes(t) == ["not-git", "not-git"] and "not in a git repo" in t["flags"][0]["text"]


def test_a_unit_rendered_from_a_template_is_not_loose(box):
    # stackshot's install.sh writes the unit and says so on line 1; the template lives in the stackshot checkout
    ss = git_repo(box.tmp / "stackshot", "git@github.com:example-org/stackshot.git")
    (ss / "units").mkdir()
    (ss / "units" / "stackshot-x.service.in").write_text("tmpl")
    box.add("stackshot-x", link=False, rendered=MARKER, lane="subscription-1")
    t = by_name(SCH.collect(box, render_roots=[str(ss)]), "stackshot-x.timer")
    assert t["flags"] == []
    assert t["rendered"]["service"] == {"template": "units/stackshot-x.service.in",
                                        "link": "https://github.com/example-org/stackshot/blob/main/units/stackshot-x.service.in"}


def test_a_rendered_marker_with_no_template_found_is_still_not_loose(box):
    box.add("stackshot-y", link=False, rendered=MARKER.replace("x.service", "y.service"))
    t = by_name(SCH.collect(box, render_roots=[str(box.tmp / "nowhere")]), "stackshot-y.timer")
    assert "not-git" not in codes(t)
    assert t["rendered"]["service"] == {"template": "units/stackshot-y.service.in", "link": None}


def test_only_the_first_line_counts_as_the_marker(box):
    box.add("fake", link=False, rendered="# just a comment\n" + MARKER)
    assert codes(by_name(SCH.collect(box), "fake.timer")) == ["not-git", "not-git"]


def test_a_failed_last_run_is_flagged(box):
    box.add("bad", result="exit-code", status="2", active="failed")
    t = by_name(SCH.collect(box), "bad.timer")
    assert codes(t) == ["failed"]
    assert t["result"]["state"] == "failed" and "exit-code" in t["flags"][0]["text"] and "2" in t["flags"][0]["text"]


def test_a_service_that_never_ran_or_runs_now_is_not_failed(box):
    box.add("fresh", started=False, last=0)
    box.add("busy", active="activating")
    data = SCH.collect(box)
    assert by_name(data, "fresh.timer")["result"]["state"] == "never" and by_name(data, "fresh.timer")["flags"] == []
    assert by_name(data, "fresh.timer")["last"] is None
    assert by_name(data, "busy.timer")["result"]["state"] == "running"


def test_a_timer_with_no_last_run_on_record_is_never_failed_and_says_so(box):
    box.add("weekly", started=False, last=0)
    t = by_name(SCH.collect(box), "weekly.timer")
    assert t["result"] == {"state": "never", "text": "not yet run since boot"}
    assert t["last"] is None and t["flags"] == []   # never a failed flag, never counted as failed
    assert SCH.NEVER_TEXT == "not yet run since boot"


def test_the_last_run_of_a_timer_a_boot_cleared_comes_from_its_last_trigger_or_the_journal(box):
    box.add("persistent", started=False, last=0)
    box.add("journaled", started=False, last=0)
    box.add("neither", started=False, last=0)
    box.trigger["persistent.timer"] = LAST
    box.journal["journaled.service"] = LAST - 3600
    data = SCH.collect(box)
    p, j, n = (by_name(data, f"{x}.timer") for x in ("persistent", "journaled", "neither"))
    assert p["last"]["epoch"] == int(LAST) and p["result"]["state"] == "ok" and p["flags"] == []
    assert j["last"]["epoch"] == int(LAST - 3600) and j["result"] == {"state": "ok", "text": "success"} and j["flags"] == []
    assert n["last"] is None and n["result"]["state"] == "never"
    asked = [c for c in box.calls if c[0] == "journalctl"]
    assert {c[c.index("-u") + 1] for c in asked} == {"journaled.service", "neither.service"}   # the journal only for a job with no other time
    assert all("--user" in c for c in asked)


def test_a_service_that_ran_since_boot_does_not_ask_the_journal(box):
    box.add("fresh")
    SCH.collect(box)
    assert not [c for c in box.calls if c[0] == "journalctl"]


def test_a_failed_timer_stays_failed_whatever_its_last_run(box):
    box.add("bad", result="exit-code", status="1", active="failed", started=False, last=0)
    box.trigger["bad.timer"] = LAST
    t = by_name(SCH.collect(box), "bad.timer")
    assert t["result"]["state"] == "failed" and codes(t) == ["failed"]


def test_journal_last_reads_the_newest_entry_time():
    def ok(argv):
        return 0, '{"MESSAGE":"x","__REALTIME_TIMESTAMP":"1793131204432065"}\n'
    assert SCH.journal_last("system", ok, "a.service") == 1793131204.432065
    assert SCH.journal_last("system", lambda argv: (0, ""), "a.service") is None
    assert SCH.journal_last("system", lambda argv: (1, ""), "a.service") is None
    assert SCH.journal_last("system", lambda argv: (0, "not json"), "a.service") is None
    assert SCH.journal_last("system", ok, "") is None
    seen = []
    SCH.journal_last("user", lambda argv: seen.append(argv) or (0, ""), "a.service")
    SCH.journal_last("system", lambda argv: seen.append(argv) or (0, ""), "a.service")
    assert "--user" in seen[0] and "--user" not in seen[1]


def test_packaged_units_in_either_scope_are_left_out_and_counted(box):
    # two of ours with no lane (one per scope: the system one lives in /etc, which no package ships) and one package unit per scope
    for n in ("ours", "pkg-user", "ours-sys", "pkg-sys"):
        box.add(n, lane=None)
    box.system = box.listing()

    def run(argv):
        rc, out = box(argv)
        user = "--user" in argv
        if "list-timers" in argv and rc == 0:
            keep = {"ours.timer", "pkg-user.timer"} if user else {"ours-sys.timer", "pkg-sys.timer"}
            return rc, json.dumps([r for r in json.loads(out) if r["unit"] in keep])
        if "show" in argv:
            out = (out.replace(f"{box.user}/pkg-user", "/usr/lib/systemd/user/pkg-user")
                      .replace(f"{box.user}/pkg-sys", "/lib/systemd/system/pkg-sys")
                      .replace(f"{box.user}/ours-sys", "/etc/systemd/system/ours-sys"))
        return rc, out
    data = SCH.collect(run)
    assert sorted((t["scope"], t["name"]) for t in data["timers"]) == [("system", "ours-sys.timer"), ("user", "ours.timer")]
    assert all("no-lane" in codes(t) for t in data["timers"]) and not any("packaged" in t for t in data["timers"])
    assert data["counts"]["packaged"] == 2   # the page says "2 packaged system timers hidden"
    assert data["counts"]["timers"] == 2 and data["counts"]["flagged"] == 2 and data["counts"]["byReason"]["no-lane"] == 2   # only our own jobs are counted
    assert not [c for c in box.calls if c[0] == "systemctl" and "cat" in c and any(u.startswith("pkg-") for u in c)]   # a hidden unit is not read further


def test_counts_by_reason(box):
    box.add("ok1")
    box.add("nolane", lane=None)
    box.add("bad", result="signal", active="failed", status="9")
    box.add("loose", link=False)
    box.cron = "0 5 * * * /usr/bin/true\n"
    c = SCH.collect(box)["counts"]
    assert c["timers"] == 4 and c["cron"] == 1 and c["flagged"] == 4
    assert c["byReason"] == {"cron": 1, "failed": 1, "no-lane": 1, "not-git": 1}   # a timer counts once per reason, though loose has two loose unit files


def test_unreadable_system_scope_is_left_out_and_said(box):
    box.add("u")
    data = SCH.collect(box)
    assert data["scopes"] == {"user": True, "system": False}
    assert all(t["scope"] == "user" for t in data["timers"])


def test_system_timers_are_read_when_readable_and_a_packaged_one_is_left_out(box):
    box.add("u")
    box.add("pkg")
    box.add("ours-sys")
    box.system = box.listing()

    def run(argv):
        rc, out = box(argv)
        user = "--user" in argv
        if "list-timers" in argv and rc == 0:
            keep = {"u.timer"} if user else {"pkg.timer", "ours-sys.timer"}
            return rc, json.dumps([r for r in json.loads(out) if r["unit"] in keep])
        if "show" in argv and not user:   # the system scope's pkg is a package file, ours-sys lives in /etc
            out = out.replace(f"{box.user}/pkg", "/usr/lib/systemd/system/pkg").replace(f"{box.user}/ours-sys", "/etc/systemd/system/ours-sys")
        return rc, out
    data = SCH.collect(run)
    assert data["scopes"]["system"] is True
    assert [(t["scope"], t["name"]) for t in data["timers"]] == [("user", "u.timer"), ("system", "ours-sys.timer")]
    assert data["counts"]["packaged"] == 1 and data["counts"]["timers"] == 2
    assert next(c for c in box.calls if c[:2] == ["systemctl", "list-timers"] and "--user" not in c)   # asked without --user


# ---- cron -------------------------------------------------------------------------------------------------------------

def test_cron_lines_are_flagged_and_environment_lines_skipped():
    text = ("# a comment\nMAILTO=\n\nPATH=/usr/bin\n* * * * * GIT_SSH_COMMAND='ssh -o BatchMode=yes' /usr/bin/git -C /x fetch\n"
            "@reboot /home/alex/boot.sh\n7 3 * * 1  /bin/echo hi  # c\n")
    jobs = SCH.parse_crontab(text)
    assert [j["schedule"] for j in jobs] == ["* * * * *", "@reboot", "7 3 * * 1"]
    assert jobs[0]["command"].startswith("GIT_SSH_COMMAND=")
    assert all(j["flags"] == [{"code": "cron", "text": "cron: move to a timer"}] for j in jobs)


def test_a_secret_on_a_cron_line_is_starred():
    jobs = SCH.parse_crontab("0 * * * * GH_TOKEN=ghp_abc123 API_KEY=sk-live-1 /usr/bin/job --user me\n")
    assert "ghp_abc123" not in jobs[0]["command"] and "sk-live-1" not in jobs[0]["command"]
    assert "GH_TOKEN=***" in jobs[0]["command"] and "/usr/bin/job --user me" in jobs[0]["command"]


def test_no_crontab_is_an_empty_list(box):
    box.add("u")
    data = SCH.collect(box)
    assert data["cron"] == []


def test_the_crontab_is_part_of_the_collection(box):
    box.cron = "# c\n*/5 * * * * /usr/bin/true\n"
    data = SCH.collect(box)
    assert len(data["cron"]) == 1 and data["cron"][0]["flags"][0]["code"] == "cron"
    assert data["counts"]["byReason"] == {"cron": 1}


# ---- the route and the page -------------------------------------------------------------------------------------------

@pytest.fixture
def client(tmp_path):
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    (claude / "projects").mkdir()
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                        tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"])
    return TestClient(create_app(settings))


def wait_reading(client, path="/api/schedules"):
    """The answer once no background read is running (swr.py serves the last reading at once and reads behind it)."""
    for _ in range(250):
        got = client.get(path).json()
        if not got.get("refreshing"):
            return got
        time.sleep(0.02)
    raise AssertionError("the read never landed")


def test_the_api_returns_what_the_collector_returns(client, monkeypatch):
    answer = {"generated": SCH.zone_time(NEXT), "timezone": "Asia/Dubai", "timers": [], "cron": [],
              "counts": {"timers": 0, "cron": 0, "flagged": 0, "byReason": {}}, "scopes": {"user": True, "system": False}}
    monkeypatch.setattr(SCH, "collect", lambda *a, **k: answer)
    with client:
        r = client.get("/api/schedules")
        assert r.status_code == 200 and r.headers["cache-control"] == "no-store"
        got = wait_reading(client)
    assert {k: v for k, v in got.items() if k != "fetchedAt"} == answer and isinstance(got["fetchedAt"], int)   # the reading carries its age
    assert set(got) >= {"generated", "timers", "cron", "counts"}


# ---- one `systemctl cat` for all the units --------------------------------------------------------------------------------

def cat_calls(box):
    return [c for c in box.calls if c[0] == "systemctl" and "cat" in c]


def solo(box):
    """A runner that answers a `cat` of several units with a failure, so that every unit is asked alone (what the collector did before)."""
    def run(argv):
        if argv[0] == "systemctl" and "cat" in argv and len([a for a in argv[argv.index("cat") + 1:] if not a.startswith("-")]) > 1:
            return 1, ""
        return box(argv)
    return run


def test_the_unit_files_are_read_with_one_cat_per_scope_not_one_per_unit(box):
    for n in ("a", "b", "c", "d"):
        box.add(n)
    data = SCH.collect(box, now=NEXT)
    asked = cat_calls(box)
    assert len(data["timers"]) == 4 and len(asked) == 1, asked   # eight unit files, one call
    assert asked[0][:4] == ["systemctl", "--user", "cat", "--no-pager"] and sorted(asked[0][4:]) == \
        ["a.service", "a.timer", "b.service", "b.timer", "c.service", "c.timer", "d.service", "d.timer"]


@pytest.fixture
def pinned_zone():
    """The box's own zone is Etc/UTC and the shown zone is Asia/Dubai, whatever the machine running the test is set to: a timer's
    OnCalendar time is read in the box's zone (plain_schedule asks libc, which TZ steers after tzset) and shown in SALA_TZ's."""
    with pytest.MonkeyPatch.context() as mp:
        mp.setenv("SALA_TZ", "Asia/Dubai")
        mp.setenv("TZ", "Etc/UTC")
        time.tzset()
        try:
            yield
        finally:
            mp.undo()
            time.tzset()


def test_a_batched_cat_gives_the_same_rows_as_one_cat_per_unit(box, pinned_zone):
    box.add("lane-a", lane="bedrock", note="a note", project="projects/x", sched="OnCalendar=Mon *-*-* 04:40:00")
    box.add("lane-b", lane="none", sched="OnUnitActiveSec=5min")
    box.add("loose", link=False, lane=None, project=None)
    box.add("rendered", link=False, rendered=MARKER)
    box.dropin["lane-a.service"] = "[Service]\nEnvironment=X=1\n"
    box.dropin["loose.timer"] = "[Timer]\nOnCalendar=*-*-* 11:11:11\n"
    batched = SCH.collect(box, now=NEXT)
    box.calls.clear()
    alone = SCH.collect(solo(box), now=NEXT)
    assert batched == alone and len(batched["timers"]) == 4
    assert len(cat_calls(box)) == 8   # each unit alone (the batch was refused before it reached the box): what ran before
    assert by_name(batched, "lane-a.timer")["lane"] == "bedrock" and by_name(batched, "lane-a.timer")["lane_note"] == "a note"
    assert by_name(batched, "lane-b.timer")["plain"] == "every 5 min" and by_name(batched, "loose.timer")["lane"] is None
    assert by_name(batched, "lane-a.timer")["plain"] == "every Monday at 08:40"   # 04:40 UTC in the pinned zone


def test_a_unit_the_batch_does_not_return_is_asked_alone_and_the_others_keep_their_text(box):
    for n in ("a", "b", "c"):
        box.add(n, lane="bedrock", project=f"projects/{n}")
    box.missing = {"b.service"}   # systemctl skips it, exits 1, and prints the others
    data = SCH.collect(box, now=NEXT)
    asked = cat_calls(box)
    assert [len(c) - 4 for c in asked] == [6, 1] and asked[1][-1] == "b.service", asked   # the batch of six, then the one missing
    assert [by_name(data, f"{n}.timer")["lane"] for n in "abc"] == ["bedrock", None, "bedrock"]
    assert [by_name(data, f"{n}.timer")["project"] for n in "abc"] == ["projects/a", None, "projects/c"]
    assert "no-lane" in codes(by_name(data, "b.timer")) and "no-lane" not in codes(by_name(data, "a.timer"))


def test_split_cat_cuts_the_output_at_each_units_own_header():
    out = ("# /u/a.service\n[Unit]\nX-Model-Lane=api\n\n[Service]\nExecStart=/bin/a\n"
           "\n# /u/a.service.d/10-x.conf\n[Service]\nEnvironment=A=1\n"                    # a drop-in's header is not a new unit
           "\n# /u/b.timer -> /repo/b.timer\n[Timer]\nOnCalendar=daily\n"                  # a symlink's header says where it goes
           "\n# /u/c.service\n[Unit]\n# /u/b.timer\nX-Model-Lane=none\n")                 # a comment in a unit that looks like another header
    got = SCH.split_cat(out, [("a.service", "/u/a.service"), ("b.timer", "/u/b.timer"), ("c.service", "/u/c.service")])
    assert list(got) == ["a.service", "b.timer", "c.service"]
    assert got["a.service"] == "# /u/a.service\n[Unit]\nX-Model-Lane=api\n\n[Service]\nExecStart=/bin/a\n\n# /u/a.service.d/10-x.conf\n[Service]\nEnvironment=A=1\n"
    assert got["b.timer"] == "# /u/b.timer -> /repo/b.timer\n[Timer]\nOnCalendar=daily\n"
    assert got["c.service"] == "# /u/c.service\n[Unit]\n# /u/b.timer\nX-Model-Lane=none\n"
    assert SCH.model_lane(got["a.service"]) == "api" and SCH.timer_schedule(got["b.timer"], {}) == ["OnCalendar=daily"]
    assert SCH.model_lane(got["c.service"]) == "none"


def test_split_cat_leaves_out_a_unit_with_no_header():
    out = "# /u/a.service\n[Unit]\nX-Model-Lane=api\n\n# /u/c.service\n[Unit]\nX-Model-Lane=none\n"
    got = SCH.split_cat(out, [("a.service", "/u/a.service"), ("b.service", "/u/b.service"), ("c.service", "/u/c.service")])
    assert sorted(got) == ["a.service", "c.service"] and "b.service" not in got
    assert SCH.split_cat("", [("a.service", "/u/a.service")]) == {}


def test_cat_units_asks_alone_for_a_unit_without_a_file_or_sharing_one():
    calls = []

    def run(argv):
        calls.append(argv)
        names = argv[argv.index("cat") + 2:]
        if len(names) > 1:
            return 0, "\n".join(f"# /u/{n}\n[Unit]\nDescription={n}\n" for n in names)
        return 0, f"text of {names[0]}"
    wanted = [("a.service", "/u/a.service"), ("b.service", "/u/a.service"), ("c.service", ""), ("d.service", "/u/d.service"), ("a.service", "/u/a.service")]
    got = SCH.cat_units(["systemctl"], wanted, run)
    assert got == {"a.service": "# /u/a.service\n[Unit]\nDescription=a.service\n", "d.service": "# /u/d.service\n[Unit]\nDescription=d.service\n",
                   "b.service": "text of b.service", "c.service": "text of c.service"}
    # one batch for the units that have a file of their own (a unit named twice once); b shares a's file and c has none: alone
    assert calls == [["systemctl", "cat", "--no-pager", "a.service", "d.service"], ["systemctl", "cat", "--no-pager", "b.service"],
                     ["systemctl", "cat", "--no-pager", "c.service"]]


def test_a_box_without_systemd_or_cron_gives_empty_lists():
    data = SCH.collect(lambda argv: (127, ""))
    assert data["timers"] == [] and data["cron"] == [] and data["scopes"] == {"user": False, "system": False}
    assert data["counts"] == {"timers": 0, "cron": 0, "packaged": 0, "flagged": 0, "byReason": {}}


def test_the_page_has_the_tabs_and_no_sidebar_entry(client):
    html = client.get("/").text
    # the sidebar's Schedules entry and the page of its own are gone; the Overview holds the two tabs, as links (an old #schedules link lands on the second)
    assert 'id="side-sched"' not in html and 'id="schedules-pane"' not in html
    assert not re.search(r'<a [^>]*class="[^"]*side[^"]*"[^>]*href="#schedules"', html)
    assert re.search(r'<a id="ov-tab-sessions"[^>]*href="#sessions"[^>]*aria-selected="true"', html)       # Agents is the default tab
    assert re.search(r'<a id="ov-tab-schedules"[^>]*href="#schedules"[^>]*aria-selected="false"', html)
    assert 'id="ov-agents"' in html and 'id="ov-schedules"' in html and "static/schedules.js" in html and "static/schedules.css" in html
    for f in ("schedules.js", "schedules.css"):
        assert client.get(f"/static/{f}").status_code == 200
    js = client.get("/static/app.js").text
    assert "schedulesHash" in js and "setOverviewTab" in js and "schedules.start()" in js and "schedules.stop()" in js
    assert "showSchedulesPage" not in js and "side-sched" not in js and "schedules-open" not in js


def test_the_table_has_the_five_columns_in_order_and_no_groups():
    from sala_web.app import STATIC
    html = (STATIC / "index.html").read_text()
    table = html[html.index('<table id="sc-table"'):html.index("</table>", html.index('<table id="sc-table"'))]
    heads = re.findall(r'<th data-key="(\w+)" aria-sort="none"><button type="button"(?: title="[^"]*")?>([^<]+)</button></th>', table)
    assert heads == [("name", "Job"), ("category", "Category"), ("desc", "What it does"), ("next", "When"), ("lane", "Lane")], heads   # When sorts by the next run
    assert "sc-group" not in html and "sc-fold" not in html


def test_the_page_has_no_timer_no_groups_and_no_table_that_places_a_job():
    from sala_web.app import STATIC
    js = (STATIC / "schedules.js").read_text()
    css = (STATIC / "schedules.css").read_text()
    # no standing timer: the tab asks when it opens (start) and when Reload is pressed; the only timeout is the follow-up while the
    # server says it is reading again (`refreshing`), and it is cleared when the tab closes
    assert "setInterval" not in js and "REFRESH_MS" not in js and js.count("setTimeout(") == 1 and "clearTimeout(sc.timer)" in js
    assert len(re.findall(r"\bload\(\);", js)) == 1 and js.count("load(true)") == 1   # the calls: start() and the Reload button
    # the unit links, the script path as a link and the "via" line are gone; the script survives as a tooltip only
    assert "service unit" not in js and "timer unit" not in js and "rendered from" not in js and '"via ' not in js and '"a"' not in js
    assert "title: path || null" in js
    # the Category is the job's own project: this file names no project and no group, and keeps no fold or order in the prefs
    assert "t.project" in js and not re.search(r"\b(infra|beta|gamma)/", js)
    assert "GROUPS" not in js and "scheduleFolded" not in js and "scheduleOrder" not in js and "savePrefs(" not in js and "drag" not in js
    assert ".sc-toggle { margin: 0; padding: 0; border-top: 0; }" in css   # style.css's .toggle is the sidebar's footer row
    assert "#schedules-pane" not in css and "sc-group" not in css


def test_the_missing_lane_is_never_shown_as_the_value_none():
    from sala_web.app import STATIC
    js = (STATIC / "schedules.js").read_text()
    css = (STATIC / "schedules.css").read_text()
    assert '"not set"' in js and "sc-muted sc-unset" in js
    assert "(declared: no model call)" in js
    assert ".sc-unset { font-style: italic;" in css


def test_the_prefs_no_longer_know_the_schedule_keys(client):
    got = client.get("/api/prefs").json()
    assert "scheduleOrder" not in got and "scheduleFolded" not in got   # the table is sorted by heading; nothing of it is saved
    assert client.put("/api/prefs", json={"scheduleOrder": ["sala"]}).status_code == 400


# ---- the tab in a browser -----------------------------------------------------------------------------------------------

DXB_NOW = datetime.now(DXB_ZONE)
TODAY = DXB_NOW.date()


def _at(day_offset: int, hh: int, mm: int) -> dict:
    d = datetime(TODAY.year, TODAY.month, TODAY.day, hh, mm, tzinfo=DXB_ZONE) + timedelta(days=day_offset)
    return SCH.zone_time(d.timestamp())


def _job(name, project, *, lane="none", desc="", plain="every day at 09:00", nxt=None, last=None, flags=(), state="ok", rtext="success"):
    return {"scope": "user", "name": name + ".timer", "service": name + ".service", "description": name + " — " + desc,
            "summary": desc, "project": project,
            "runs": {"command": "bash", "script": f"~/config-repo/bin/{name}.sh", "line": f"bash ~/config-repo/bin/{name}.sh"},
            "schedule": ["OnCalendar=*-*-* 00:00:00"], "plain": plain, "next": nxt or _at(0, 23, 30), "last": last,
            "result": {"state": state, "text": rtext}, "lane": lane, "lane_note": None,
            "links": {"script": "https://github.com/a/b/blob/main/x.sh", "service": "https://github.com/a/b/blob/main/y.service",
                      "timer": "https://github.com/a/b/blob/main/y.timer"},
            "rendered": {}, "unit_files": {"service": "", "timer": ""}, "flags": [{"code": c, "text": f"{c} because"} for c in flags]}


# the seven jobs, given in no particular order; the projects are the Agents tab's Project labels
FAKE = {
    "generated": SCH.zone_time(DXB_NOW.timestamp()), "timezone": "Asia/Dubai", "cron": [], "scopes": {"user": True, "system": True},
    "timers": [
        _job("sala-watch", "projects/demo", lane="subscription-1", desc="Keep the master Claude Code session alive and bridged", plain="every 2 min", last=_at(-1, 8, 15)),
        _job("relay-cache", "projects/misc", lane="none", desc="Relay cache: board items and session links", plain="every 5 min", nxt=_at(1, 8, 15), last=_at(0, 0, 5), state="running", rtext="running now"),
        _job("dusk-run", "projects/shed", lane="api", desc="Nightly cleanup cycle", flags=("not-git",)),
        _job("mint-filters", "projects/misc", desc="Encrypted copy of the state folder", plain="every Sunday at 04:40", state="never", rtext="not yet run since boot"),
        _job("wind-probe", "projects/misc", desc="One probe of the test link and name lookup", plain="every minute, at :07", last=_at(0, 0, 1), state="failed", rtext="failed: exit status 1"),
        _job("alpha-feed-watch", "beta/docs", lane="api", desc="Watch the demo feed"),
        _job("mystery", None, lane=None, desc="A job with no project", flags=("no-lane", "no-project"), last=_at(-9, 5, 17)),
    ],
}
FAKE["counts"] = {"timers": len(FAKE["timers"]), "cron": 0, "packaged": 20, "flagged": 2, "byReason": {"no-lane": 1, "not-git": 1, "no-project": 1}}

DEFAULT_ORDER = ["alpha-feed-watch", "sala-watch", "mint-filters", "relay-cache", "wind-probe", "dusk-run", "mystery"]

STUB = """(() => {
  const d = %s, real = window.fetch.bind(window);
  window.__scFetches = 0;
  window.fetch = (url, opts) => String(url).startsWith("api/schedules")
    ? (window.__scFetches++, Promise.resolve(new Response(JSON.stringify(d), { headers: { "Content-Type": "application/json" } })))
    : real(url, opts);
})();""" % json.dumps(FAKE)

ORDER_JS = """[...document.querySelectorAll("#sc-body .sc-row .sc-name")].map((n) => n.textContent)"""
def pick_sort(browser, key: str) -> None:
    """The phone's sort menu does the headings' work: it is the only way to sort by the last run (the When heading sorts by the next)."""
    browser.evaluate(f"""(() => {{ const s = document.querySelector("#sc-sortsel"); s.value = "{key}"; s.dispatchEvent(new Event("change")); }})(); ''""")


SORT_JS = """Object.fromEntries([...document.querySelectorAll("#sc-table th")].map((t) => [t.dataset.key, t.getAttribute("aria-sort")]))"""
WAIT_ROWS = """new Promise((res) => { const t0 = Date.now(); (function poll() {
  const n = document.querySelectorAll("#sc-body .sc-row").length;
  if (n === %d || Date.now() - t0 > 15000) res(n); else setTimeout(poll, 100);
})(); })""" % len(FAKE["timers"])
WAIT_TAB = """new Promise((res) => { const t0 = Date.now(); (function poll() {
  const p = document.querySelector("#overview-pane"), t = p && p.dataset.tab;   // the page may not have loaded yet
  if (t === "%s" || Date.now() - t0 > 20000) res(t); else setTimeout(poll, 50);
})(); })"""
WIDE = {"width": 1280, "height": 1600, "deviceScaleFactor": 1, "mobile": False}


def open_page(served, browser, hash_: str, wide: bool = False, tag: str = "") -> None:
    browser.send("Page.enable")
    if not getattr(browser, "_sc_stub", False):
        browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": STUB})
        browser._sc_stub = True
    browser.open(f"{served['url']}/?t={tag}{hash_}", dark=True)
    if wide:
        browser.send("Emulation.setDeviceMetricsOverride", WIDE)


def open_schedules(served, browser, wide: bool = False, tag: str = "") -> None:
    open_page(served, browser, "#schedules", wide=wide, tag=tag)
    assert browser.evaluate(WAIT_ROWS) == len(FAKE["timers"])


def click_heading(browser, key: str) -> None:
    browser.evaluate(f"""document.querySelector('#sc-table th[data-key="{key}"] button').click(); ''""")


def test_a_schedules_link_opens_the_overview_on_the_schedules_tab(served, browser):
    open_schedules(served, browser, wide=True)
    m = browser.evaluate("""(() => { const vis = (s) => getComputedStyle(document.querySelector(s)).display !== "none";
      return { overview: document.body.classList.contains("overview-open"), tab: document.querySelector("#overview-pane").dataset.tab,
               sel: [...document.querySelectorAll(".ov-tab")].map((t) => [t.id, t.getAttribute("aria-selected")]),
               schedules: vis("#ov-schedules"), agents: vis("#ov-agents"), side: document.querySelectorAll("#side-sched").length,
               cards: vis("#q-cards") }; })()""")
    assert m["overview"] and m["tab"] == "schedules" and m["schedules"] and not m["agents"] and m["side"] == 0, m
    assert m["sel"] == [["ov-tab-sessions", "false"], ["ov-tab-schedules", "true"], ["ov-tab-machines", "false"]] and m["cards"], m   # the lane cards stay on top of every tab
    assert browser.evaluate("location.hash") == "#schedules"
    # the Agents tab is the other link; its panel comes back and the Schedules one goes
    browser.evaluate("document.querySelector('#ov-tab-sessions').click(); ''")
    m = browser.evaluate("""({ tab: document.querySelector("#overview-pane").dataset.tab, hash: location.hash,
      schedules: getComputedStyle(document.querySelector("#ov-schedules")).display, agents: getComputedStyle(document.querySelector("#ov-agents")).display })""")
    assert m == {"tab": "sessions", "hash": "#sessions", "schedules": "none", "agents": "block"}, m


def test_the_agents_tab_is_the_default_and_schedules_is_not_read_until_its_tab_opens(served, browser):
    open_page(served, browser, "#sessions", wide=True)
    # the app sets the pane's tab when its start-up has read the config, the preferences and the sessions and routed to the hash (a
    # slow runner takes longer than any fixed wait); only then is "the Schedules tab was not read" a statement about the tab
    assert browser.evaluate(WAIT_TAB % "sessions") == "sessions"
    m = browser.evaluate("""({ tab: document.querySelector("#overview-pane").dataset.tab, fetches: window.__scFetches,
      schedules: getComputedStyle(document.querySelector("#ov-schedules")).display, first: document.querySelector("#sp-table th button").textContent })""")
    assert m == {"tab": "sessions", "fetches": 0, "schedules": "none", "first": "Agent"}, m   # the first column is Agent, not Session
    browser.evaluate("document.querySelector('#ov-tab-schedules').click(); ''")
    assert browser.evaluate(WAIT_ROWS) == len(FAKE["timers"]) and browser.evaluate("window.__scFetches") == 1


def test_the_default_sort_is_category_then_job_a_to_z(served, browser):
    open_schedules(served, browser, wide=True)
    # the projects A-Z (beta/docs, projects/demo, projects/misc, projects/shed), a job with none after them all; inside a category A-Z
    assert browser.evaluate(ORDER_JS) == DEFAULT_ORDER
    assert browser.evaluate(SORT_JS) == {"name": "none", "category": "ascending", "desc": "none", "next": "none", "lane": "none"}
    head = browser.evaluate("document.querySelector('#sc-count').textContent")
    assert head.startswith("7 jobs · 0 cron lines · 2 flagged") and "1 no project" in head and "read " in head, head
    assert "20 packaged system timers hidden" in browser.evaluate("document.querySelector('#sc-scope-note').textContent")
    assert browser.evaluate("document.querySelector('#ov-n-schedules').textContent") == "7"


def test_the_category_is_the_jobs_own_project(served, browser):
    open_schedules(served, browser, wide=True)
    cats = browser.evaluate("""Object.fromEntries([...document.querySelectorAll("#sc-body .sc-row")].map((r) => [r.querySelector(".sc-name").textContent, r.querySelector(".sc-c-cat").textContent]))""")
    assert cats == {"sala-watch": "projects/demo", "relay-cache": "projects/misc", "dusk-run": "projects/shed", "mint-filters": "projects/misc",
                    "wind-probe": "projects/misc", "alpha-feed-watch": "beta/docs", "mystery": "\u2014"}, cats   # none: a dash, and the "no project" flag chip
    chips = browser.evaluate("""[...document.querySelectorAll('[data-job="mystery.timer"] .sc-chip')].map((c) => [c.textContent, c.title])""")
    assert chips == [["no lane", "no-lane because"], ["no project", "no-project because"]]


def test_a_heading_sorts_and_a_second_click_reverses(served, browser):
    open_schedules(served, browser, wide=True)
    click_heading(browser, "category")   # the active heading: reverses; a job with no category stays last, ties by name
    assert browser.evaluate(ORDER_JS) == ["dusk-run", "mint-filters", "relay-cache", "wind-probe", "sala-watch", "alpha-feed-watch", "mystery"]
    assert browser.evaluate(SORT_JS)["category"] == "descending"
    click_heading(browser, "category")   # and back
    assert browser.evaluate(ORDER_JS) == DEFAULT_ORDER and browser.evaluate(SORT_JS)["category"] == "ascending"
    click_heading(browser, "name")       # another heading starts ascending
    assert browser.evaluate(ORDER_JS) == sorted(DEFAULT_ORDER)
    assert browser.evaluate(SORT_JS) == {"name": "ascending", "category": "none", "desc": "none", "next": "none", "lane": "none"}
    click_heading(browser, "name")
    assert browser.evaluate(ORDER_JS) == sorted(DEFAULT_ORDER, reverse=True)
    click_heading(browser, "lane")       # the lane's own name A-Z (api, none, subscription-1), ties by category then name, the unset lane last
    assert browser.evaluate(ORDER_JS) == ["alpha-feed-watch", "dusk-run", "mint-filters", "relay-cache", "wind-probe", "sala-watch", "mystery"]


def test_ties_fall_back_to_category_then_name_whichever_way_it_sorts(served, browser):
    open_schedules(served, browser, wide=True)
    click_heading(browser, "next")   # six jobs share today's 23:30 and relay-cache runs tomorrow
    tied = ["alpha-feed-watch", "sala-watch", "mint-filters", "wind-probe", "dusk-run", "mystery"]   # by category order, then name
    assert browser.evaluate(ORDER_JS) == [*tied, "relay-cache"]
    click_heading(browser, "next")   # reversed: tomorrow first; the ties keep the category order and the names A-Z, they are not turned round
    assert browser.evaluate(ORDER_JS) == ["relay-cache", *tied]
    pick_sort(browser, "last")   # last runs (the phone's menu): a job that never ran has nothing to sort by and comes last in both directions
    never = ["alpha-feed-watch", "mint-filters", "dusk-run"]   # no last run on record, in category order then name
    assert browser.evaluate(ORDER_JS) == ["mystery", "sala-watch", "wind-probe", "relay-cache", *never]   # nine days back, yesterday 08:15, 00:01, 00:05
    browser.evaluate("document.querySelector('#sc-sortdir').click(); ''")
    assert browser.evaluate(ORDER_JS) == ["relay-cache", "wind-probe", "sala-watch", "mystery", *never]


def test_the_page_reads_on_open_and_on_reload_only(served, browser):
    import time
    open_schedules(served, browser, wide=True)
    assert browser.evaluate("window.__scFetches") == 1
    time.sleep(1.5)
    assert browser.evaluate("window.__scFetches") == 1
    click_heading(browser, "name")   # sorting works on what was read; it does not read again
    assert browser.evaluate("window.__scFetches") == 1
    browser.evaluate("document.querySelector('#sc-reload').click(); ''")
    time.sleep(0.5)
    assert browser.evaluate("window.__scFetches") == 2
    # the other tab and back is the tab opening again: one more read
    browser.evaluate("document.querySelector('#ov-tab-sessions').click(); ''")
    browser.evaluate("document.querySelector('#ov-tab-schedules').click(); ''")
    time.sleep(0.5)
    assert browser.evaluate("window.__scFetches") == 3


def test_flagged_only_keeps_the_flagged_jobs_in_the_sort(served, browser):
    open_schedules(served, browser, wide=True)
    browser.evaluate("document.querySelector('#sc-flagged').click(); ''")
    assert browser.evaluate(ORDER_JS) == ["dusk-run", "mystery"]


def test_a_row_has_its_columns_and_no_links(served, browser):
    open_schedules(served, browser, wide=True)
    row = browser.evaluate("""(() => { const r = document.querySelector('[data-job="relay-cache.timer"]');
      return { cells: [...r.querySelectorAll("td")].map((c) => c.innerText), links: r.querySelectorAll("a").length,
               title: r.querySelector(".sc-name").title, text: r.textContent }; })()""")
    # one When cell holds the schedule, the next and the last run on three lines (a running job's result stays under "last")
    assert row["cells"] == ["relay-cache", "projects/misc", "Relay cache: board items and session links",
                            "every 5 min\nnext tomorrow 08:15\nlast today 00:05\nrunning now", "none"], row["cells"]
    assert row["links"] == 0 and "via " not in row["text"] and row["title"].endswith("relay-cache.sh")   # the script path is the hover title
    # a job that never ran says so in neutral words; flags stay as chips under the description
    assert browser.evaluate("""document.querySelector('[data-job="mint-filters.timer"] .sc-when-last').innerText""") == "last not yet run since boot"
    assert browser.evaluate("""document.querySelector('[data-job="sala-watch.timer"] .sc-when-next').innerText""") == "next today 23:30"
    chips = browser.evaluate("""[...document.querySelectorAll('[data-job="dusk-run.timer"] .sc-chip')].map((c) => [c.textContent, c.title])""")
    assert chips == [["not in git", "not-git because"]]
    assert browser.evaluate("""document.querySelector('[data-job="mystery.timer"] .sc-c-lane').textContent""") == "not set"


TIME_WORDS = re.compile(r"^(today|tomorrow|yesterday) \d\d:\d\d$|^(Mon|Tue|Wed|Thu|Fri|Sat|Sun) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \d{1,2}(st|nd|rd|th) \d\d:\d\d$")
SHOTS = os.environ.get("SALA_SCHEDULES_SHOTS")   # a folder: the tests below leave a screenshot there (none by default)


def screenshot(browser, name: str) -> None:
    if SHOTS:
        import base64
        os.makedirs(SHOTS, exist_ok=True)
        shot = browser.send("Page.captureScreenshot", {"format": "png"})["data"]
        with open(os.path.join(SHOTS, name), "wb") as f:
            f.write(base64.b64decode(shot))


WHEN_JS = """Object.fromEntries([...document.querySelectorAll("#sc-body .sc-row")].map((r) => [r.dataset.job.replace(/\\.timer$/, ""), (() => {
  const c = r.querySelector(".sc-c-when"), lines = [...c.children].map((d) => d.innerText);
  return { lines, classes: [...c.children].map((d) => d.className), titles: [...c.querySelectorAll("[title]")].map((x) => x.title) }; })()]))"""


def test_the_when_column_holds_the_schedule_the_next_and_the_last_run_on_three_lines(served, browser):
    open_schedules(served, browser, wide=True)
    when = browser.evaluate(WHEN_JS)
    sala = when["sala-watch"]
    assert sala["lines"] == ["every 2 min", "next today 23:30", "last yesterday 08:15"], sala
    assert [c.split()[0] for c in sala["classes"]] == ["sc-when-plain", "sc-when-next", "sc-when-last"], sala
    # the raw On… lines and the ISO times stay as tooltips
    assert sala["titles"][0] == "OnCalendar=*-*-* 00:00:00" and sala["titles"][1] == _at(0, 23, 30)["iso"] and sala["titles"][2] == _at(-1, 8, 15)["iso"], sala
    assert when["mint-filters"]["lines"] == ["every Sunday at 04:40", "next today 23:30", "last not yet run since boot"]
    assert when["wind-probe"]["lines"][2].startswith("last today 00:01") and when["wind-probe"]["lines"][2].endswith("failed: exit status 1")   # the result under "last"
    assert when["relay-cache"]["lines"][2] == "last today 00:05\nrunning now"
    # one time format in the column, and no zone label anywhere in it
    for job, w in when.items():
        for line in w["lines"][1:3]:
            first = line.split("\n")[0]
            word = first.split(" ", 1)[1]
            assert first.split(" ")[0] in ("next", "last") and (TIME_WORDS.match(word) or word == "not yet run since boot"), (job, line)
        assert "+04" not in " ".join(w["lines"]), (job, w)
    far = _at(-9, 5, 17)["when"]
    assert when["mystery"]["lines"][2] == f"last {far}" and not far.startswith(("today", "yesterday", "tomorrow")) and TIME_WORDS.match(far), far   # "Fri Oct 23rd 05:17" style
    m = browser.evaluate("""(() => { const r = document.querySelector('[data-job="sala-watch.timer"]'), k = r.querySelector(".sc-when-k"), p = r.querySelector(".sc-when-plain");
      const tops = [...r.querySelector(".sc-c-when").children].map((d) => d.getBoundingClientRect().top);
      return { kcolor: getComputedStyle(k).color, pcolor: getComputedStyle(p).color, tops, doc: document.documentElement.scrollWidth,
               heads: [...document.querySelectorAll("#sc-table th")].map((t) => t.textContent) }; })()""")
    assert m["kcolor"] != m["pcolor"], m   # the "next" and "last" labels are muted
    assert m["tops"] == sorted(m["tops"]) and len(set(m["tops"])) == 3, m   # three lines, one under the other
    assert m["heads"] == ["Job", "Category", "What it does", "When", "Lane"] and m["doc"] <= 1280, m
    screenshot(browser, "schedules-1280.png")


def test_the_when_heading_sorts_by_the_next_run_and_the_menu_by_the_last_too(served, browser):
    open_schedules(served, browser, wide=True)
    click_heading(browser, "next")
    assert browser.evaluate(SORT_JS) == {"name": "none", "category": "none", "desc": "none", "next": "ascending", "lane": "none"}
    tied = ["alpha-feed-watch", "sala-watch", "mint-filters", "wind-probe", "dusk-run", "mystery"]
    assert browser.evaluate(ORDER_JS) == [*tied, "relay-cache"]   # today 23:30 (six jobs), then tomorrow 08:15
    click_heading(browser, "next")
    assert browser.evaluate(SORT_JS)["next"] == "descending" and browser.evaluate(ORDER_JS) == ["relay-cache", *tied]
    pick_sort(browser, "last")   # sorting by the last run keeps the When heading marked: it is the column that holds it
    assert browser.evaluate(SORT_JS) == {"name": "none", "category": "none", "desc": "none", "next": "ascending", "lane": "none"}
    assert browser.evaluate(ORDER_JS)[:4] == ["mystery", "sala-watch", "wind-probe", "relay-cache"]
    click_heading(browser, "next")   # the heading itself sorts by the next run again, ascending
    assert browser.evaluate("document.querySelector('#sc-sortsel').value") == "next" and browser.evaluate(ORDER_JS)[-1] == "relay-cache"


# one rule for both widths: a name's line breaks fall after a hyphen and nowhere else, and no hyphen starts a line
NAMES_JS = """[...document.querySelectorAll("#sc-body .sc-name")].map((n) => {
  const text = n.textContent, node = [...n.childNodes].filter((c) => c.nodeType === 3), tops = [], r = document.createRange();
  let i = 0;
  for (const t of node) for (let k = 0; k < t.length; k++, i++) { r.setStart(t, k); r.setEnd(t, k + 1); const q = r.getClientRects()[0]; tops.push(q ? Math.round(q.top) : null); }
  const bad = [];
  for (let k = 1; k < text.length; k++) if (tops[k] !== null && tops[k - 1] !== null && tops[k] !== tops[k - 1] && text[k - 1] !== "-") bad.push(text.slice(0, k) + "|" + text.slice(k));
  return { text, lines: new Set(tops.filter((x) => x !== null)).size, bad, hyphenFirst: tops.some((t, k) => text[k] === "-" && k > 0 && t !== tops[k - 1]),
           cell: n.closest("td").getBoundingClientRect().width, wrapsAnywhere: getComputedStyle(n).overflowWrap }; })"""


def check_names_never_break_mid_word(browser) -> list:
    names = browser.evaluate(NAMES_JS)
    assert len(names) == len(FAKE["timers"]), names
    for n in names:
        assert n["bad"] == [] and not n["hyphenFirst"] and n["wrapsAnywhere"] == "normal", n
    return names


def test_a_job_name_breaks_at_its_hyphens_only_on_a_wide_screen(served, browser):
    open_schedules(served, browser, wide=True)
    names = {n["text"]: n for n in check_names_never_break_mid_word(browser)}
    assert names["alpha-feed-watch"]["lines"] <= 3 and names["mint-filters"]["lines"] <= 2, names   # never "mail / - / filters"
    assert names["mint-filters"]["cell"] >= 90, names["mint-filters"]   # the column is as wide as the longest segment of the longest name, not 70px


def test_a_job_name_breaks_at_its_hyphens_only_on_a_phone(served, browser):
    open_schedules(served, browser)
    check_names_never_break_mid_word(browser)


def test_a_name_that_is_too_long_for_its_column_still_never_breaks_inside_a_word(served, browser):
    open_schedules(served, browser, wide=True)
    # a narrow window forces the longest names to break: every break is still after a hyphen
    browser.send("Emulation.setDeviceMetricsOverride", {"width": 800, "height": 1600, "deviceScaleFactor": 1, "mobile": False})
    check_names_never_break_mid_word(browser)


def test_on_a_phone_the_when_card_has_one_label_and_the_three_lines(served, browser):
    open_schedules(served, browser)
    m = browser.evaluate("""(() => { const r = document.querySelector('[data-job="sala-watch.timer"]'), c = r.querySelector(".sc-c-when");
      return { labels: [...r.querySelectorAll("td")].map((t) => getComputedStyle(t, "::before").content).filter((x) => x && x !== "none" && x !== "normal"),
               lines: [...c.children].map((d) => d.innerText), tops: [...c.children].map((d) => Math.round(d.getBoundingClientRect().top)),
               before: getComputedStyle(c, "::before").content, beforeDisplay: getComputedStyle(c, "::before").display, doc: document.documentElement.scrollWidth,
               nextCells: r.querySelectorAll(".sc-c-next, .sc-c-last, .sc-c-plain").length }; })()""")
    assert m["lines"] == ["every 2 min", "next today 23:30", "last yesterday 08:15"], m
    assert m["before"] == '"When"' and m["beforeDisplay"] == "block" and m["nextCells"] == 0, m   # one "When" label; no "next:" / "last:" labels of their own
    assert m["tops"] == sorted(m["tops"]) and len(set(m["tops"])) == 3 and m["doc"] <= 390, m
    assert '"next: "' not in m["labels"] and '"last: "' not in m["labels"], m
    screenshot(browser, "schedules-390.png")


def test_a_wide_screen_shows_the_lane_cards_and_no_chip_strip(served, browser):
    open_schedules(served, browser, wide=True)
    m = browser.evaluate("""({ strip: getComputedStyle(document.querySelector("#q-strip")).display, cards: getComputedStyle(document.querySelector("#q-cards")).display,
      sortmenu: getComputedStyle(document.querySelector(".sc-sortmenu")).display, thead: getComputedStyle(document.querySelector("#sc-table thead")).display,
      doc: document.documentElement.scrollWidth })""")
    assert m["strip"] == "none" and m["cards"] == "grid" and m["sortmenu"] == "none" and m["thead"] != "none" and m["doc"] <= 1280, m


def test_on_a_phone_the_lane_cards_fold_into_a_strip_that_opens_on_a_tap(served, browser):
    open_schedules(served, browser)
    m = browser.evaluate("""({ strip: getComputedStyle(document.querySelector("#q-strip")).display, cards: getComputedStyle(document.querySelector("#q-cards")).display,
      expanded: document.querySelector("#q-strip").getAttribute("aria-expanded") })""")
    assert m == {"strip": "flex", "cards": "none", "expanded": "false"}, m
    browser.evaluate("document.querySelector('#q-strip').click(); ''")
    m = browser.evaluate("""({ cards: getComputedStyle(document.querySelector("#q-cards")).display, expanded: document.querySelector("#q-strip").getAttribute("aria-expanded"),
      open: document.querySelector("#quota").classList.contains("q-open") })""")
    assert m == {"cards": "grid", "expanded": "true", "open": True}, m
    browser.evaluate("document.querySelector('#q-strip').click(); ''")
    assert browser.evaluate("""getComputedStyle(document.querySelector("#q-cards")).display""") == "none"


def test_on_a_phone_the_jobs_are_cards_with_a_category_chip_and_a_sort_menu(served, browser):
    open_schedules(served, browser)
    m = browser.evaluate("""(() => { const r = document.querySelector('[data-job="sala-watch.timer"]'), b = (s) => { const q = r.querySelector(s).getBoundingClientRect(); return { top: q.top, bottom: q.bottom, left: q.left, width: q.width }; };
      return { vw: document.documentElement.clientWidth, doc: document.documentElement.scrollWidth,
               thead: getComputedStyle(document.querySelector("#sc-table thead")).display, menu: getComputedStyle(document.querySelector(".sc-sortmenu")).display,
               name: b(".sc-c-name"), cat: b(".sc-c-cat"), desc: b(".sc-c-desc"), chip: r.querySelector(".sc-c-cat .sc-cat").textContent,
               sel: document.querySelector("#sc-sortsel").value, opts: [...document.querySelectorAll("#sc-sortsel option")].map((o) => o.textContent) }; })()""")
    assert m["vw"] == 390 and m["doc"] <= 390 and m["thead"] == "none" and m["menu"] == "flex", m
    assert m["chip"] == "projects/demo" and m["sel"] == "category", m
    assert m["opts"] == ["Job", "Category", "What it does", "Next run", "Last run", "Lane"], m   # the menu keeps Next run and Last run
    assert m["name"]["bottom"] <= m["cat"]["top"] + 1 and m["cat"]["bottom"] <= m["desc"]["top"] + 1 and abs(m["name"]["left"] - m["desc"]["left"]) < 1, m   # stacked
    # the menu does the headings' work: a column, then the arrow reverses
    browser.evaluate("""(() => { const s = document.querySelector("#sc-sortsel"); s.value = "name"; s.dispatchEvent(new Event("change")); })(); ''""")
    assert browser.evaluate(ORDER_JS) == sorted(DEFAULT_ORDER)
    browser.evaluate("document.querySelector('#sc-sortdir').click(); ''")
    assert browser.evaluate(ORDER_JS) == sorted(DEFAULT_ORDER, reverse=True)
    assert browser.evaluate("document.querySelector('#sc-sortdir').textContent") == "\u25BC"


def test_times_are_in_the_zone_of_SALA_TZ_and_in_local_time_when_it_is_unset(monkeypatch):
    """No zone is built in. conftest sets Asia/Dubai; another zone gives its own times and label; with none set the machine's own zone
    (TZ here) is used and the label is that zone's."""
    monkeypatch.setenv("SALA_TZ", "Europe/Berlin")
    t = SCH.zone_time(NEXT)   # 2026-10-28 00:00 UTC
    assert t["iso"] == "2026-10-28T01:00:00+01:00" and t["text"] == "Wed Oct 28th 01:00 CET"
    assert SCH.plain_schedule(["OnCalendar=*-*-* 00:00:00"], tz=UTC, now=NEXT) == "every day at 01:00"
    monkeypatch.delenv("SALA_TZ")
    monkeypatch.setenv("TZ", "America/New_York")
    t = SCH.zone_time(NEXT)
    assert t["iso"] == "2026-10-27T20:00:00-04:00" and t["text"] == "Tue Oct 27th 20:00 EDT"
    assert SCH.plain_schedule(["OnCalendar=*-*-* 00:00:00"], tz=UTC, now=NEXT) == "every day at 20:00"
    assert "+04" not in json.dumps(t)


# ---- the tab draws from the server's stored reading and is replaced when a newer one lands -----------------------------------

def reading_a(**extra) -> dict:
    """The stored reading: FAKE as the server last read it, with the age swr.py puts on it (`refreshing` while a newer one is read)."""
    return {**FAKE, "fetchedAt": 1_000, **extra}


def reading_b(**extra) -> dict:
    """The newer reading: `mystery` is gone and `new-job` (flagged) is there."""
    timers = [t for t in FAKE["timers"] if t["name"] != "mystery.timer"] + [_job("new-job", "projects/new", lane=None, flags=("no-lane",))]
    return {**FAKE, "timers": timers, "fetchedAt": 2_000,
            "counts": {**FAKE["counts"], "timers": len(timers), "flagged": 2, "byReason": {"not-git": 1, "no-lane": 1}}, **extra}


def open_with_answers(served, browser, answers, wide=True, hash_="#schedules"):
    """The page with api/schedules answered from `answers` in turn (the last one repeats); window.__scUrls lists the addresses asked."""
    stub = """(() => { const a = %s, real = window.fetch.bind(window); let i = 0; window.__scUrls = [];
      window.fetch = (url, opts) => String(url).startsWith("api/schedules")
        ? (window.__scUrls.push(String(url)), Promise.resolve(new Response(JSON.stringify(a[Math.min(i++, a.length - 1)]), { headers: { "Content-Type": "application/json" } })))
        : real(url, opts); })();""" % json.dumps(answers)
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": stub})
    browser.open(f"{served['url']}/{hash_}", dark=True)
    if wide:
        browser.send("Emulation.setDeviceMetricsOverride", {"width": 1280, "height": 420, "deviceScaleFactor": 1, "mobile": False})


def wait_for(browser, expr: str, ms: int = 15000):
    """True once the JS expression is truthy (polled), else False."""
    return browser.evaluate("""new Promise((res) => { const t0 = Date.now(); (function poll() {
      let v = false; try { v = (%s); } catch (e) {}
      if (v || Date.now() - t0 > %d) res(!!v); else setTimeout(poll, 50);
    })(); })""" % (expr, ms))


JOBS_JS = """[...document.querySelectorAll("#sc-body .sc-row")].map((r) => r.dataset.job.replace(/\\.timer$/, ""))"""
ASKED_JS = "window.__scUrls.length"
SEVEN = "document.querySelectorAll('#sc-body .sc-row').length === 7"
NEW_JOB = "document.querySelector('[data-job=\"new-job.timer\"]')"


def test_the_tab_draws_the_stored_reading_at_once_and_replaces_it_when_the_new_one_lands(served, browser):
    open_with_answers(served, browser, [reading_a(refreshing=True), reading_b()])
    assert wait_for(browser, SEVEN)
    assert browser.evaluate(ASKED_JS) == 1 and "mystery" in browser.evaluate(JOBS_JS)   # drawn from the first answer, before any wait
    assert wait_for(browser, NEW_JOB)   # the follow-up asks again; the new reading replaces the table
    jobs = browser.evaluate(JOBS_JS)
    assert "mystery" not in jobs and "new-job" in jobs and len(jobs) == 7
    assert browser.evaluate("document.querySelector('#sc-count').textContent").startswith("7 jobs · 0 cron lines · 2 flagged")
    time.sleep(2.2)
    assert browser.evaluate(ASKED_JS) == 2, browser.evaluate("window.__scUrls")   # the answer no longer says refreshing: it stopped asking


def test_a_first_start_shows_the_placeholder_until_the_server_has_a_reading(served, browser):
    pending = {"pending": True, "refreshing": True, "fetchedAt": None, "timers": [], "cron": [], "generated": None,
               "counts": {"timers": 0, "cron": 0, "packaged": 0, "flagged": 0, "byReason": {}}, "scopes": {}}
    open_with_answers(served, browser, [pending, reading_a()])
    assert wait_for(browser, "window.__scUrls.length >= 1 && document.querySelector('#sc-count').textContent === 'Reading the timers…'")
    assert browser.evaluate("document.querySelectorAll('#sc-body .sc-row').length") == 0
    assert wait_for(browser, SEVEN)
    assert browser.evaluate(ASKED_JS) == 2


def test_a_new_reading_keeps_the_sort_and_the_filter(served, browser):
    open_with_answers(served, browser, [reading_a(refreshing=True), reading_b()])
    assert wait_for(browser, SEVEN)
    pick_sort(browser, "name")
    browser.evaluate("""document.querySelector('#sc-flagged').click(); ''""")   # Flagged only: dusk-run and mystery
    assert browser.evaluate(JOBS_JS) == ["dusk-run", "mystery"]
    assert wait_for(browser, NEW_JOB)
    m = browser.evaluate("""({ jobs: [...document.querySelectorAll("#sc-body .sc-row")].map((r) => r.dataset.job.replace(/\\.timer$/, "")),
      box: document.querySelector('#sc-flagged').checked, sort: document.querySelector('#sc-sortsel').value })""")
    assert m == {"jobs": ["dusk-run", "new-job"], "box": True, "sort": "name"}, m   # still filtered and sorted; the rows are the new reading's


def test_a_new_reading_leaves_the_scroll_position_where_it_was(served, browser):
    open_with_answers(served, browser, [reading_a(refreshing=True), reading_b()])
    assert wait_for(browser, SEVEN)
    top = browser.evaluate("""(() => { let e = document.querySelector("#sc-body");
      while (e && e !== document.documentElement) { const o = getComputedStyle(e).overflowY; if ((o === "auto" || o === "scroll") && e.scrollHeight > e.clientHeight + 5) break; e = e.parentElement; }
      window.__scScroller = e && e !== document.documentElement ? e : document.scrollingElement; window.__scScroller.scrollTop = 90; return window.__scScroller.scrollTop; })()""")
    assert top > 0, "the page does not scroll in this window, so nothing is checked"
    assert wait_for(browser, NEW_JOB)
    assert browser.evaluate("window.__scScroller.scrollTop") == top


def test_a_repeated_reading_is_not_drawn_again(served, browser):
    open_with_answers(served, browser, [reading_a(refreshing=True), reading_a(refreshing=True), reading_a()])
    assert wait_for(browser, SEVEN)
    browser.evaluate("""window.__row = document.querySelector('[data-job="mystery.timer"]'); window.__row.dataset.mark = "kept"; ''""")
    assert wait_for(browser, "window.__scUrls.length === 3")
    time.sleep(0.3)
    assert browser.evaluate("""document.querySelector('[data-job="mystery.timer"]') === window.__row && window.__row.dataset.mark""") == "kept"   # the same nodes: no flicker


def test_reload_asks_for_a_fresh_reading_and_shows_it(served, browser):
    open_with_answers(served, browser, [reading_a(), reading_a(refreshing=True), reading_b()])
    assert wait_for(browser, SEVEN)
    browser.evaluate("document.querySelector('#sc-reload').click(); ''")
    assert wait_for(browser, NEW_JOB)
    assert browser.evaluate("window.__scUrls") == ["api/schedules", "api/schedules?fresh=1", "api/schedules"]


def test_a_failed_refresh_keeps_the_table_and_says_so(served, browser):
    open_with_answers(served, browser, [reading_a(error="could not be read (OSError)", errorKind="failed")])
    assert wait_for(browser, SEVEN)
    note = browser.evaluate("document.querySelector('#sc-note').textContent")
    assert note.startswith("Could not read the schedules just now; showing the reading from ") and "OSError" not in note, note
    assert browser.evaluate("document.querySelector('#sc-note').classList.contains('error')")


def test_leaving_the_tab_stops_the_follow_up(served, browser):
    open_with_answers(served, browser, [reading_a(refreshing=True)])   # always says a newer reading is on its way
    assert wait_for(browser, "window.__scUrls.length >= 2")
    browser.evaluate("document.querySelector('#ov-tab-sessions').click(); ''")
    n = browser.evaluate(ASKED_JS)
    time.sleep(2.2)
    assert browser.evaluate(ASKED_JS) == n
