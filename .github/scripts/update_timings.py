#!/usr/bin/env python3
"""update_timings.py: rebuilds the two timings files that .github/scripts/deal.py balances CI's shards by, from CI's own logs.

  tests/timings.json       the shell suites:  {"tests/<suite>.sh": seconds}      read by tests/run.sh --shard
  web/tests/timings.json   the web test files: {"tests/test_<name>.py": seconds}  read by .github/scripts/web-shard.sh

Where the numbers come from (nothing in the workflow has to change to produce them):
  suites  the `════ tests/<suite>.sh (pass, <n>s)` line tests/run.sh prints for each suite that ended, in the log of a `suites`
          or `suites-shard (k)` job. A suite that failed prints another line and is not recorded.
  web     the log timestamps of pytest's progress lines (`tests/test_x.py ....s..   [ 12%]`). A progress line is written when the
          file's tests (or a line's worth of them) have run, so the time between two progress lines is the time of the file
          that ended on the later one; the first is counted from the "collected N items" line. A file runs serially in its
          shard, so these add up to the shard's pytest time.
Each number is the MEDIAN over the runs sampled (one outlier run, a runner having a bad hour, moves nothing). Suites count only from
a run that ran at least 20 of them (a pull request's selection runs few, and a suite among a few is faster than among eighty). A key the sampled
runs did not show (a pull request runs only the suites its change reaches) keeps its recorded number; a key whose file is gone
from this checkout is dropped. A suite or file that is new has no number until a run of it is sampled; until then the dealer
gives it the median (deal.py), so nothing breaks.

Usage (stdlib only; `gh` signed in for the first form), from the root of a checkout, run with `python3 -I`:
  .github/scripts/update_timings.py [--runs N] [--repo OWNER/REPO] [--dry-run]
      the logs of the last N (default 10) successful runs of tests.yml, one `gh run view --log` each
  .github/scripts/update_timings.py --from-logs FILE... [--dry-run]
      logs saved by hand (a whole run's `gh run view --log`, or one job's); no network
  --label TEXT  with --from-logs: what the logs are, recorded in the file's "source" (default "saved logs")
  --dry-run  prints what would change and the estimated worst shard for each family; writes nothing.
It always ends with those estimates, which are the numbers to quote in a pull request (CONTRIBUTING.md, *Timings*).
"""
import datetime
import json
import os
import re
import statistics
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deal  # noqa: E402  (the dealer, next to this file)

ROOT = os.getcwd()
FILES = {  # family → (timings file, where the keys' files are, the shard counts worth reporting)
    "suites": ("tests/timings.json", "", (1, 2)),
    "web": ("web/tests/timings.json", "web/", (4, 6)),
}

MIN_SUITES = 20   # a run that ran fewer suites (a pull request's selection) says little: a suite alone is faster than among eighty, and the deal is for the full set
ANSI = re.compile(r"\x1b\[[0-9;]*m")
LINE = re.compile(r"^(?:(?P<job>[^\t]*)\t(?P<step>[^\t]*)\t)?(?P<ts>\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z) ?(?P<text>.*)$")
SUITE = re.compile(r"^════ (tests/[A-Za-z0-9_.-]+\.sh) \(pass, (\d+)s\)")
PROGRESS = re.compile(r"^(?:(tests/test_[A-Za-z0-9_]+\.py) )?[.sFExXpP ]*\[\s*\d+%\]\s*$")
COLLECTED = re.compile(r"^collected \d+ items?")


def seconds(ts):
    """An Actions log timestamp (seven fractional digits) as seconds since the epoch."""
    ts = re.sub(r"(\.\d{6})\d*Z$", r"\1Z", ts)
    ts = ts if "." in ts else ts[:-1] + ".0Z"
    return datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=datetime.timezone.utc).timestamp()


def jobs_of(text):
    """{job name: [(epoch seconds, text)]} of a log; a log with no job column is one job named ''."""
    jobs = {}
    for raw in text.splitlines():
        m = LINE.match(ANSI.sub("", raw.rstrip("\r")))
        if m:
            jobs.setdefault(m.group("job") or "", []).append((seconds(m.group("ts")), m.group("text")))
    return jobs


def parse_suites(lines):
    return {m.group(1): float(m.group(2)) for _, t in lines for m in [SUITE.match(t)] if m}


def parse_web(lines):
    """{test file: seconds} from the timestamps of pytest's progress lines (see the header)."""
    out, prev, current = {}, None, None
    for ts, t in lines:
        if COLLECTED.match(t):
            prev = ts
            continue
        m = PROGRESS.match(t)
        if not m or prev is None:
            continue
        current = m.group(1) or current
        if current:
            out[current] = out.get(current, 0.0) + max(ts - prev, 0.0)
        prev = ts
    return out


def sample(text):
    """(suites, web): the times one log shows."""
    suites, web = {}, {}
    for _, lines in jobs_of(text).items():
        suites.update(parse_suites(lines))
        for k, v in parse_web(lines).items():
            web[k] = web.get(k, 0.0) + v
    return suites, web


def merge(old, samples, root_prefix):
    """The new {key: seconds}: the median of the samples' numbers, the old number for a key no sample shows, a key whose file is gone dropped."""
    seen = {}
    for s in samples:
        for k, v in s.items():
            seen.setdefault(k, []).append(v)
    new = dict(old)
    for k, v in seen.items():
        new[k] = round(statistics.median(v), 1)
    return {k: v for k, v in sorted(new.items()) if os.path.exists(os.path.join(ROOT, root_prefix + k))}


def write(path, timings, note):
    doc = {"version": 1, "unit": "seconds", "recorded": datetime.date.today().isoformat(), "source": note, "timings": timings}
    with open(os.path.join(ROOT, path), "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=1, ensure_ascii=True)
        f.write("\n")


def gh(*args):
    r = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=300)
    return r.returncode, r.stdout, r.stderr


def run_logs(repo, n):
    """[(run id, log text)] of the last n successful runs of tests.yml that have a log."""
    rc, out, err = gh("run", "list", "-R", repo, "--workflow", "tests.yml", "--status", "success", "--limit", str(n), "--json", "databaseId")
    if rc != 0:
        raise SystemExit(f"update_timings.py: gh run list failed: {err.strip()[:300]}")
    logs = []
    for r in json.loads(out):
        rc, text, err = gh("run", "view", "-R", repo, str(r["databaseId"]), "--log")
        if rc == 0 and text:
            logs.append((str(r["databaseId"]), text))
        else:
            print(f"update_timings.py: no log for run {r['databaseId']} ({err.strip()[:120]}): skipped", file=sys.stderr)
    return logs


def makespan(items, timings, slots):
    """Wall seconds of one runner starting `items` in the order given, `slots` at a time (tests/run.sh -j; a hosted runner has 4 CPUs: 8)."""
    free = [0.0] * slots
    for i in items:
        k = free.index(min(free))
        free[k] += timings[i]
    return max(free)


def estimates(family, timings):
    """One line: the worst shard of the deal at each shard count worth quoting. Suites: the work of the shard and its wall time at 8 at once."""
    path, prefix, counts = FILES[family]
    parts = []
    for n in counts:
        shards, load = deal.deal(list(timings), timings, n)
        worst = f"worst {max(load):.0f} s of work"
        if family == "suites":
            worst += f", about {max(makespan(s, timings, 8) for s in shards):.0f} s wall at 8 suites at once"
        parts.append(f"{n} shard{'s' if n > 1 else ''}: {worst}")
    return f"{family}: {len(timings)} entries, {sum(timings.values()):.0f} s in all; " + "; ".join(parts)


def main(argv):
    runs, repo, dry, logs, where = 10, None, False, None, None
    args = list(argv)
    try:
        while args:
            a = args.pop(0)
            if a == "--runs":
                runs = int(args.pop(0))
            elif a == "--repo":
                repo = args.pop(0)
            elif a == "--dry-run":
                dry = True
            elif a == "--label":
                where = args.pop(0)
            elif a == "--from-logs":
                logs = []
                while args and not args[0].startswith("--"):
                    p = args.pop(0)
                    with open(p, encoding="utf-8", errors="replace") as f:
                        logs.append((os.path.basename(p), f.read()))
            else:
                raise ValueError(f"unknown option {a}")
    except (IndexError, ValueError, OSError) as e:
        print(f"update_timings.py: bad argument ({e}); see the header of {os.path.basename(__file__)}", file=sys.stderr)
        return 2
    if logs is None:
        if repo is None:
            rc, out, err = gh("repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner")
            if rc != 0:
                print("update_timings.py: no --repo given and gh cannot tell which repository this is", file=sys.stderr)
                return 2
            repo = out.strip()
        logs = run_logs(repo, runs)
        where = f"the last {runs} successful runs of tests.yml"
    if not logs:
        print("update_timings.py: no log to read", file=sys.stderr)
        return 1
    per = {"suites": [], "web": []}
    for _, text in logs:
        s, w = sample(text)
        if len(s) >= MIN_SUITES:
            per["suites"].append(s)
        if w:
            per["web"].append(w)
    status = 0
    for family, (path, prefix, _) in FILES.items():
        try:
            old = deal.load_timings(os.path.join(ROOT, path))
        except ValueError as e:
            print(f"update_timings.py: {e}", file=sys.stderr)
            return 2
        new = merge(old, per[family], prefix)
        changed = sum(1 for k in new if old.get(k) != new[k]) + sum(1 for k in old if k not in new)
        print(f"{path}: {len(per[family])} of {len(logs)} logs showed {family}; {changed} entries changed ({len(old)} → {len(new)})")
        print("  " + estimates(family, new))
        if not per[family] and not old:
            status = 1
        if not dry and per[family]:
            write(path, new, f"median over {len(per[family])} CI logs ({where or 'saved logs'}), by .github/scripts/update_timings.py")
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
