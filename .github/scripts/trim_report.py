#!/usr/bin/env python3
"""trim_report.py - the weekly size report of salamander's test suites. Read-only, standard library only.

Run it from a checkout (or pass --root). It prints a short plain-text report, keeps the run as one JSON record in a state file, and
compares it with the previous run's record:

    python3 -I .github/scripts/trim_report.py [--root DIR] [--config FILE] [--state-dir DIR] [--dry-run] [--json] [--now ISO]

What it measures, per run, for two families that it reports separately and added together:
  * suites       the shell suites tests/<name>.sh that CI runs, which is every tests/*.sh except the four tools that tests/run.sh
                 skips (lib, run, count-procs, suitemap: `tests/run.sh --list` names the same set), PLUS the web test files
                 web/tests/test_*.py.
  * test lines   one count per line that is one check.
                 Shell suite: a line that calls the suites' own `ok` helper (tests/lib.sh) in command position with a message after it:
                 `ok "..."` at the start of the line (after indentation), or after `&&`, `||`, `;`, `then`, `else`, `do`, `{` or `(`.
                 The usual check is one line, `[ cond ] && ok "what" || bad "why"`, so the `ok` call is the line's one count (two `ok`
                 calls on a line count once). Not counted: a comment line, the definition `ok() {`, a line with only a `bad` call, and the
                 call of a helper that wraps `ok` (such a helper counts as the one `ok` line in its body). Counting only lines that begin
                 with `ok` would find a few dozen in the whole tree: nearly every check is written behind a test.
                 Web test file: a line that starts, after indentation, with `assert ` (a plain assert statement).
                 It is a size measure, not a coverage measure: stable between runs, cheap.
  * serial minutes, slowest   from the committed recorded seconds, tests/timings.json (keys `tests/<suite>.sh`) and
                 web/tests/timings.json (keys `tests/test_<name>.py`, relative to web/): the sum over the suites and files, and the
                 slowest 8. No network, no gh. A suite or file with no recorded time is counted as untimed (it is not guessed), and a
                 time that is negative, not a finite number or above a year (31,622,400 seconds) is ignored with a note naming the key.
                 A timings file that cannot be read leaves its family untimed, with a note; with neither readable the minutes are n/a
                 and the two minute thresholds are not checked.
  * since the previous run   suites and files added and deleted by name, test lines added and deleted (per suite, the rise or fall of
                 its count; a new suite adds all its lines, a deleted one deletes all).

Thresholds. Four keys, read from a small TOML file, `--config FILE` or `${XDG_CONFIG_HOME:-~/.config}/salamander/test-trim.toml`; keys at
the top of the file apply to every checkout, and a `[salamander]` table overrides them:

    max_suites            number of suites and web test files together
    max_serial_minutes    their recorded times added up
    max_suite_minutes     the slowest single suite or file
    max_test_line_growth  test lines gained since the previous run, scaled down to a week when the gap is longer than a week

A key the file names that is none of these four (a mistyped `max_suite`) is not used: a `warning: unknown key <name> in <file>` line
goes to stderr for each, and the exit status is unchanged. A value that is not a number from 0 to 10**12 (a boolean, a string, nan, inf, a
negative or a huge one), a file that is not UTF-8 text, a pipe or a terminal in place of a file (`--config /dev/stdin` too: a config
is a regular file) and one nested too deep are config problems, exit 2. A missing default file is no problem; a missing `--config` file is.

The defaults are placeholders that never trigger: set the real values from the measured numbers. When a value is above its limit the
report ends with one `TRIGGER: <which>` line per threshold (in the order above), the same lines are kept in the state file, and the
exit status is still 0: this tool opens nothing and cleans nothing up. A TRIGGER line is the only cue for a cleanup pass (a scan for
duplicate or obsolete suites), which is not part of this report and never runs on a calendar (CONTRIBUTING.md, *Keeping the suites trim*).

State file: `${XDG_STATE_HOME:-~/.local/state}/salamander/test-trim/state.json` (--state-dir replaces the folder), written
atomically (a temporary file in the same folder, then a rename). A previous record that cannot be used (not JSON, another format, a
missing or wrong-typed field, a time without a UTC offset, a count that is not a non-negative whole number) is started over from with
a one-line note, and this run's record replaces it. --dry-run prints the report and writes nothing (not even the state folder);
--json prints the record instead of the text. `--now ISO` sets the clock, for tests.

Exit status: 0 the report was made (triggers included), 1 the state folder or file cannot be written, 2 a usage, config or checkout
problem. SIGTERM ends the run cleanly (status 143)."""
from __future__ import annotations

import argparse
import datetime as dt
import errno
import glob
import json
import os
import re
import signal
import stat
import subprocess
import sys
import tempfile
import tomllib

FORMAT = 1
NAME = "salamander"
TOOLS = ("lib", "run", "count-procs", "suitemap")       # tests/*.sh that tests/run.sh does not run as suites
SH_LINE = re.compile(r"""(?:^|&&|\|\||;|\bthen\b|\belse\b|\bdo\b|\{|\()\s*ok(?=\s+["'$])""")
PY_LINE = re.compile(r"^\s*assert\s")
SLOWEST = 8
COUNT_MAX = 10 ** 12      # a count above this is not a test-line count; it would also overflow the float arithmetic
LIST_MAX = 20             # names listed per added/deleted line of the report
SECONDS_MAX = 366 * 86400     # a time above a year is no suite time; it would also run the minute sums towards infinity
THRESHOLD_MAX = COUNT_MAX     # a limit above this is no limit anyone set; it keeps the comparisons and the state file's numbers plain
# Placeholders that never trigger. They are replaced by the measured numbers in the config file, not by editing this table.
DEFAULTS = {"max_suites": 1_000_000, "max_serial_minutes": 1_000_000.0, "max_suite_minutes": 1_000_000.0, "max_test_line_growth": 1_000_000}
FOLLOW_UP = "Follow-up: a scan for duplicate or obsolete suites (not part of this report)."


class Fail(Exception):
    def __init__(self, msg: str, code: int = 2):
        super().__init__(msg)
        self.code = code


# ---------------------------------------------------------------- measuring
def count_sh(text: str) -> int:
    n = 0
    for line in text.splitlines():
        if line.lstrip().startswith("#") or re.match(r"\s*ok\s*\(\)", line):
            continue
        if SH_LINE.search(line):
            n += 1
    return n


def count_py(text: str) -> int:
    return sum(1 for line in text.splitlines() if PY_LINE.match(line))


def measure(root: str, pattern: str, counter, tools: tuple[str, ...] = ()) -> dict[str, int]:
    """{repo-relative path: test lines} for each file the pattern matches under root, but not a tool"""
    out: dict[str, int] = {}
    for path in sorted(glob.glob(os.path.join(glob.escape(root), pattern))):
        rel = os.path.relpath(path, root)
        if os.path.splitext(os.path.basename(path))[0] in tools:
            continue
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                out[rel] = counter(f.read())
        except OSError as e:
            raise Fail(f"cannot read {path}: {e.strerror or e}")
    return out


def read_timings(path: str) -> tuple[dict[str, float], list[str]]:
    """({key: seconds}, keys whose time is unusable) from a timings file; ValueError says what is wrong with it"""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except OSError as e:
        raise ValueError(f"cannot read {path}: {e.strerror or e}")
    except RecursionError:
        raise ValueError(f"{path} is nested too deeply to read")
    except ValueError as e:
        raise ValueError(f"{path} is not JSON: {e}")
    if not isinstance(data, dict) or not isinstance(data.get("timings"), dict):
        raise ValueError(f"{path} has no timings table")
    secs: dict[str, float] = {}
    bad: list[str] = []
    for key, v in data["timings"].items():
        if isinstance(v, (int, float)) and not isinstance(v, bool) and 0 <= v <= SECONDS_MAX:      # false for nan, inf and a negative
            secs[str(key)] = float(v)
        else:
            bad.append(str(key))
    return secs, sorted(bad)


# ---------------------------------------------------------------- config
def config_path(arg: str | None) -> str:
    if arg:
        return arg
    base = os.environ.get("XDG_CONFIG_HOME") or ""
    if not os.path.isabs(base):
        base = os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, NAME, "test-trim.toml")


def read_config(path: str) -> dict:
    """the TOML file's data. A config is a file: a pipe is refused (also one with a writer), and so is a terminal, a block device or a socket.
    The path is opened non-blocking so that a pipe with no writer cannot hold the open for ever, and the descriptor is looked at before anything
    is read and closed on every way out."""
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    f = None
    try:
        mode = os.fstat(fd).st_mode
        if stat.S_ISDIR(mode):
            raise IsADirectoryError(errno.EISDIR, os.strerror(errno.EISDIR), path)
        if stat.S_ISFIFO(mode):
            raise Fail(f"config file {path} is a pipe, not a file")
        if not (stat.S_ISREG(mode) or (stat.S_ISCHR(mode) and not os.isatty(fd))):      # a regular file, or a device like /dev/null
            raise Fail(f"config file {path} is not a regular file")
        f = os.fdopen(fd, "rb")                                                         # f owns the descriptor from here
        return tomllib.load(f)
    finally:
        if f is not None:
            f.close()
        else:
            os.close(fd)


def load_thresholds(path: str, explicit: bool) -> dict:
    """DEFAULTS, then the file's top-level keys, then its [salamander] table. A missing default file is no error; a bad value is."""
    t: dict = dict(DEFAULTS)
    try:
        data = read_config(path)
    except FileNotFoundError:
        if explicit:
            raise Fail(f"config file {path} does not exist")
        return t
    except OSError as e:
        raise Fail(f"cannot read config file {path}: {e.strerror or e}")
    except tomllib.TOMLDecodeError as e:
        raise Fail(f"config file {path} is not valid TOML: {e}")
    except UnicodeDecodeError:
        raise Fail(f"config file {path} is not UTF-8 text")
    except RecursionError:
        raise Fail(f"config file {path} is nested too deeply to read")
    except ValueError as e:                     # tomllib's own limit on a number with thousands of digits
        raise Fail(f"config file {path} cannot be read: {e}")
    for k, v in data.items():                   # a table is some checkout's; any other key must be one of the four
        if not isinstance(v, dict) and k not in DEFAULTS:
            print(f"warning: unknown key {k} in {path}", file=sys.stderr)
        if isinstance(v, dict) and k == NAME:
            for k2 in v:
                if k2 not in DEFAULTS:
                    print(f"warning: unknown key {k2} in {path} (table [{k}])", file=sys.stderr)
    own = data.get(NAME)
    for source in (data, own if isinstance(own, dict) else {}):
        for k, v in source.items():
            if k in DEFAULTS:
                if isinstance(v, bool) or not isinstance(v, (int, float)) or not 0 <= v <= THRESHOLD_MAX:   # false for nan, inf, a negative, a huge int
                    raise Fail(f"config file {path}: {k} must be a number from 0 to {THRESHOLD_MAX}, got {str(v)[:40]!r}")
                t[k] = v if v != 0 else type(v)(0)       # -0.0 is zero: it would otherwise print as a limit of -0
    return t


# ---------------------------------------------------------------- state
def default_state_dir() -> str:
    base = os.environ.get("XDG_STATE_HOME") or ""
    if not os.path.isabs(base):
        base = os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, NAME, "test-trim")


def check_state_dir(folder: str) -> None:
    """make the folder and prove a file can be made in it, so a run does not end with nothing kept"""
    try:
        os.makedirs(folder, exist_ok=True)
        fd, probe = tempfile.mkstemp(dir=folder, prefix=".probe-")
        os.close(fd)
        os.unlink(probe)
    except OSError as e:
        raise Fail(f"cannot write the state folder {folder}: {e.strerror or e}", 1)


def valid_count(v) -> bool:
    return isinstance(v, int) and not isinstance(v, bool) and 0 <= v <= COUNT_MAX


def record_problem(rec) -> str | None:
    """why a parsed previous record cannot be used (one line), or None when every field this tool reads is sound"""
    if not (isinstance(rec, dict) and type(rec.get("format")) is int and rec["format"] == FORMAT):
        return "is not of this tool's format"
    if not isinstance(rec.get("suites"), dict):
        return "is damaged (suites)"
    if not all(valid_count(v) for v in rec["suites"].values()):
        return "is damaged (a suite's test lines)"
    if not valid_count(rec.get("test_lines")):
        return "is damaged (test_lines)"
    g = rec.get("generated")
    if not isinstance(g, str):
        return "is damaged (generated)"
    try:
        when = dt.datetime.fromisoformat(g)
    except ValueError:
        return "is damaged (generated)"
    if when.tzinfo is None or when.utcoffset() is None:
        return "is damaged (generated has no UTC offset)"
    return None


def read_previous(path: str) -> tuple[dict | None, str | None]:
    """(previous record, note): no file is no note; a file that cannot be used is ignored with a one-line note"""
    try:
        with open(path, encoding="utf-8") as f:
            rec = json.load(f)
    except FileNotFoundError:
        return None, None
    except (OSError, ValueError, RecursionError) as e:
        return None, f"the previous record {path} cannot be read ({e.__class__.__name__}); starting over"
    try:
        why = record_problem(rec)
    except (ValueError, TypeError, OverflowError, KeyError, AttributeError):
        why = "is damaged"
    if why:
        return None, f"the previous record {path} {why}; starting over"
    return rec, None


def write_state(path: str, rec: dict) -> None:
    folder = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=folder, prefix="." + os.path.basename(path) + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(rec, f, sort_keys=True, separators=(",", ":"))
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# ---------------------------------------------------------------- the report
def compare(prev: dict | None, cur: dict[str, int]) -> dict:
    if prev is None:
        return {"added_suites": [], "deleted_suites": [], "tests_added": 0, "tests_deleted": 0, "per_suite_change": {}}
    old = prev["suites"]
    added = sorted(set(cur) - set(old))
    deleted = sorted(set(old) - set(cur))
    change = {n: cur.get(n, 0) - old.get(n, 0) for n in set(cur) | set(old) if cur.get(n, 0) != old.get(n, 0)}
    up = sum(d for d in change.values() if d > 0)
    down = -sum(d for d in change.values() if d < 0)
    return {"added_suites": added, "deleted_suites": deleted, "tests_added": up, "tests_deleted": down, "per_suite_change": dict(sorted(change.items()))}


def num(x: float) -> str:
    return f"{x:,.1f}".rstrip("0").rstrip(".")


def evaluate(th: dict, rec: dict, growth_per_week: float | None) -> list[dict]:
    out = []

    def hit(key: str, value, text: str) -> None:
        out.append({"key": key, "limit": th[key], "value": value, "line": f"TRIGGER: {key}: {text} > {num(th[key])}"})
    if rec["suite_count"] > th["max_suites"]:
        hit("max_suites", rec["suite_count"], f"{rec['suite_count']} suites and web test files")
    if rec["serial_minutes"] is not None and rec["serial_minutes"] > th["max_serial_minutes"]:
        hit("max_serial_minutes", rec["serial_minutes"], f"{rec['serial_minutes']:.1f} serial minutes")
    if rec["slowest"]:
        over = [s for s in rec["timed"] if s[1] > th["max_suite_minutes"]]
        if over:
            top = rec["slowest"][0]
            hit("max_suite_minutes", top[1], f"{top[0]} takes {top[1]:.1f} min ({len(over)} over)")
    if growth_per_week is not None and growth_per_week > th["max_test_line_growth"]:
        hit("max_test_line_growth", round(growth_per_week, 1), f"+{growth_per_week:,.0f} test lines per week")
    return out


def names_line(label: str, names: list[str]) -> str:
    shown = ", ".join(names[:LIST_MAX]) + (f", and {len(names) - LIST_MAX} more" if len(names) > LIST_MAX else "")
    return f"  {label}: {shown}"


def render(rec: dict, prev: dict | None, days: float | None, notes: list[str]) -> str:
    fam = rec["families"]
    L = [f"test-trim report: {NAME}",
         f"suites: {rec['suite_count']} (shell {fam['shell']['suites']}, web {fam['web']['suites']})",
         f"test lines: {rec['test_lines']:,} (shell {fam['shell']['test_lines']:,} ok lines, web {fam['web']['test_lines']:,} assert lines)"]
    if rec["serial_minutes"] is None:
        L.append("serial minutes: n/a")
        L.append("slowest suites: n/a")
    else:
        extra = f", {rec['untimed']} untimed" if rec["untimed"] else ""
        L.append(f"serial minutes: {rec['serial_minutes']:.1f} (shell {fam['shell']['minutes']:.1f}, web {fam['web']['minutes']:.1f}; "
                 f"{len(rec['timed'])} of {rec['suite_count']} timed{extra})")
        if rec["slowest"]:
            L.append(f"slowest {len(rec['slowest'])}:")
            L.extend(f"  {i}. {n}  {m:.1f} min" for i, (n, m) in enumerate(rec["slowest"], 1))
    if prev is None:
        L.append("since the previous run: none kept, this run is the baseline")
    else:
        net = rec["test_lines"] - prev["test_lines"]
        L.append(f"since the previous run ({days:.1f} days ago): {len(rec['added_suites'])} suites added, "
                 f"{len(rec['deleted_suites'])} deleted; {rec['tests_added']:,} test lines added, {rec['tests_deleted']:,} deleted (net {net:+,})")
        if rec["added_suites"]:
            L.append(names_line("added", rec["added_suites"]))
        if rec["deleted_suites"]:
            L.append(names_line("deleted", rec["deleted_suites"]))
    L.extend(f"note: {n}" for n in notes)
    if rec["triggers"]:
        L.extend(t["line"] for t in rec["triggers"])
        L.append(FOLLOW_UP)
    return "\n".join(L)


def head_commit(root: str) -> str | None:
    try:
        out = subprocess.run(["git", "-C", root, "rev-parse", "HEAD"], capture_output=True, text=True, timeout=20).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    return out if re.fullmatch(r"[0-9a-f]{40}", out) else None


def family_times(files: dict[str, int], path: str, prefix: str, label: str, notes: list[str]) -> dict[str, float] | None:
    """{file: seconds} for the files of one family with a usable recorded time, or None when the timings file cannot be read (noted).
    prefix turns a file's path into its key in the timings file."""
    try:
        secs, bad = read_timings(path)
    except ValueError as e:
        notes.append(f"no {label} times: {e}")
        return None
    keys = {n[len(prefix):] for n in files}
    bad = [k for k in bad if k in keys]
    if bad:
        notes.append(f"{label} times ignored (negative, not a finite number or above a year), counted as untimed: {', '.join(bad[:LIST_MAX])}"
                     + (f", and {len(bad) - LIST_MAX} more" if len(bad) > LIST_MAX else ""))
    return {n: secs[n[len(prefix):]] for n in files if n[len(prefix):] in secs}


def build(args, now: dt.datetime) -> tuple[str, dict, str]:
    root = os.path.abspath(args.root)
    shell = measure(root, os.path.join("tests", "*.sh"), count_sh, TOOLS)
    web = measure(root, os.path.join("web", "tests", "test_*.py"), count_py)
    if not shell:
        raise Fail(f"no tests/*.sh suite under {root}: run it from a checkout, or pass --root")
    th = load_thresholds(config_path(args.config), bool(args.config))
    state_dir = args.state_dir or default_state_dir()
    if not args.dry_run:
        check_state_dir(state_dir)
    state_file = os.path.join(state_dir, "state.json")
    prev, note = read_previous(state_file)
    notes = [note] if note else []

    t_shell = family_times(shell, os.path.join(root, "tests", "timings.json"), "", "shell suite", notes)
    t_web = family_times(web, os.path.join(root, "web", "tests", "timings.json"), "web/", "web test file", notes) if web else {}
    have_times = t_shell is not None or (t_web is not None and bool(web))
    timed_s = sorted(((n, round(s / 60, 2)) for n, s in (t_shell or {}).items()), key=lambda x: (-x[1], x[0]))
    timed_w = sorted(((n, round(s / 60, 2)) for n, s in (t_web or {}).items()), key=lambda x: (-x[1], x[0]))
    timed = sorted(timed_s + timed_w, key=lambda x: (-x[1], x[0]))
    suites = {**shell, **web}
    test_lines = sum(suites.values())
    rec = {"format": FORMAT, "generated": now.isoformat(timespec="seconds"), "suites": suites,
           "suite_count": len(suites), "test_lines": test_lines, "commit": head_commit(root),
           "families": {"shell": {"suites": len(shell), "test_lines": sum(shell.values()), "minutes": round(sum(m for _, m in timed_s), 2)},
                        "web": {"suites": len(web), "test_lines": sum(web.values()), "minutes": round(sum(m for _, m in timed_w), 2)}},
           "serial_minutes": round(sum(m for _, m in timed), 2) if have_times else None,
           "untimed": len(suites) - len(timed) if have_times else None,
           "timed": timed, "slowest": timed[:SLOWEST] if have_times else [], "thresholds": th}
    rec.update(compare(prev, suites))
    days = growth = None
    if prev is not None:
        days = max(0.0, (now - dt.datetime.fromisoformat(prev["generated"])).total_seconds() / 86400)
        net = test_lines - sum(prev["suites"].values())
        growth = net if days <= 7 else net * 7 / days
        rec["growth_per_week"] = round(growth, 1)
    rec["triggers"] = evaluate(th, rec, growth)
    text = render(rec, prev, days, notes)
    rec["notes"] = notes
    return text, rec, state_file


def on_sigterm(signum, _frame) -> None:
    raise SystemExit(128 + signum)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="trim_report.py", description="The weekly size report of salamander's test suites (read-only).")
    ap.add_argument("--root", default=".", help="the checkout to measure (default: the current folder)")
    ap.add_argument("--config", help="the thresholds file (default: ${XDG_CONFIG_HOME:-~/.config}/salamander/test-trim.toml)")
    ap.add_argument("--state-dir", help="the folder of the state file (default: ${XDG_STATE_HOME:-~/.local/state}/salamander/test-trim)")
    ap.add_argument("--dry-run", action="store_true", help="print the report and write no state")
    ap.add_argument("--json", action="store_true", help="print the record as JSON instead of the text")
    ap.add_argument("--now", help="the clock as an ISO time with an offset, for tests")
    args = ap.parse_args(argv)
    old_term = None
    try:
        old_term = signal.signal(signal.SIGTERM, on_sigterm)    # a stop ends the run through SystemExit, so the finally below runs
    except ValueError:                                           # not the main thread: the caller owns its signals
        pass
    try:
        try:
            now = dt.datetime.fromisoformat(args.now) if args.now else dt.datetime.now(dt.timezone.utc)
        except ValueError:
            raise Fail(f"--now {args.now!r} is not an ISO time")
        if now.tzinfo is None:
            raise Fail("--now needs an offset, like 2026-01-05T09:00:00+00:00")
        text, rec, state_file = build(args, now)
        if not args.dry_run:
            try:
                write_state(state_file, rec)
            except OSError as e:
                raise Fail(f"cannot write {state_file}: {e.strerror or e}", 1)
        print(json.dumps(rec, sort_keys=True) if args.json else text)
        return 0
    except Fail as e:
        print(f"trim_report: {e}", file=sys.stderr)
        return e.code
    finally:
        if old_term is not None:
            signal.signal(signal.SIGTERM, old_term)


if __name__ == "__main__":
    sys.exit(main())
