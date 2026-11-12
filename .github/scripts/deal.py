#!/usr/bin/env python3
"""deal.py: deals a list of tests (web test files, shell suites) to N shards, balanced by their RECORDED run times.

The way large open-source projects split a slow test run (pytest-split's `least_duration`, CircleCI's split-by-timings): a
committed file records how long each test took, and the dealer is greedy longest-first bin packing (LPT): the tests, longest
first, each go to the shard whose total is smallest so far. The worst shard sets the wall time, and LPT keeps it within a third
of the best possible one, where the old split by file size followed time badly (the three heaviest web files were 11% of its
time). The record is refreshed from CI's own logs by .github/scripts/update_timings.py (CONTRIBUTING.md, *Timings*).

Usage (stdlib only; run it with `python3 -I`):
  deal.py --timings FILE --of N [--shard K] [--allow-empty] [--report] ITEM...     the items as arguments
  deal.py --timings FILE --of N [--shard K] [--allow-empty] [--report] -           the items from stdin, one per line
  Prints the items of shard K (1..N) on stdout, one per line, the longest first (so a runner that starts them in order starts
  the heavy ones first). Without --shard it prints every shard's items as `<shard><TAB><item>`.
  --report  one line per shard on stderr: how many items and the estimated seconds, the shape of the whole deal.
  --allow-empty  a shard with no item exits 0 and prints nothing (a pull request that runs few suites); without it, exit 1: a
                 shard that runs nothing is read as a mistake (an empty `pytest` would run every test).
Exit status: 0 ok; 1 the shard has no item (see --allow-empty) or there are no items; 2 a bad argument or a timings file that
is present but not valid (a broken committed record is mended, not guessed around).

The timings file is JSON: {"version": 1, "unit": "seconds", "timings": {"<item>": <seconds>, ...}, ...}; the other keys say where
the numbers came from and are not read. THE FALLBACKS, so a new or a gone test never breaks the deal:
  - an item that is not in the file weighs the MEDIAN of the recorded times (a new test is neither free nor the heaviest);
  - a key in the file that is not among the items is ignored;
  - no file at all, or one with no timings: every item weighs the same, one note on stderr (a deal is still made).
THE DEAL IS DETERMINISTIC: every shard is a separate job on another runner and computes the whole deal itself, so the order is
total: weight descending, ties by name (byte order), and a tie between shards goes to the lower number. Every item goes to
exactly one shard.
"""
import json
import os
import statistics
import sys


def load_timings(path):
    """{item: seconds} from the file, {} when there is no file; ValueError when the file is there but not valid."""
    if path is None or not os.path.exists(path):
        return {}
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError) as e:
        raise ValueError(f"{path}: not readable JSON ({e})")
    t = doc.get("timings") if isinstance(doc, dict) else None
    if not isinstance(t, dict):
        raise ValueError(f"{path}: no \"timings\" object")
    out = {}
    for k, v in t.items():
        if isinstance(v, bool) or not isinstance(v, (int, float)) or v != v or v < 0 or v == float("inf"):
            raise ValueError(f"{path}: the time of {k!r} is not a number of seconds >= 0")
        out[k] = float(v)
    return out


def weights(items, timings):
    """{item: weight}: the recorded time, else the median of the recorded times, else 1 (no record at all)."""
    fallback = statistics.median(timings.values()) if timings else 1.0
    return {i: timings.get(i, fallback) for i in items}


def deal(items, timings, n):
    """The items dealt to n shards (a list of n lists, each longest first): greedy longest-first bin packing."""
    items = sorted(set(items))
    w = weights(items, timings)
    order = sorted(items, key=lambda i: (-w[i], i.encode("utf-8")))
    shards = [[] for _ in range(n)]
    load = [0.0] * n
    for i in order:
        k = min(range(n), key=lambda s: (load[s], s))
        shards[k].append(i)
        load[k] += w[i]
    return shards, load


def main(argv):
    timings_path = None
    n = shard = None
    allow_empty = report = False
    items = []
    args = list(argv)
    try:
        while args:
            a = args.pop(0)
            if a == "--timings":
                timings_path = args.pop(0)
            elif a == "--of":
                n = int(args.pop(0))
            elif a == "--shard":
                shard = int(args.pop(0))
            elif a == "--allow-empty":
                allow_empty = True
            elif a == "--report":
                report = True
            elif a == "-":
                items += [l for l in sys.stdin.read().split("\n") if l]
            elif a.startswith("-"):
                raise ValueError(f"unknown option {a}")
            else:
                items.append(a)
    except (IndexError, ValueError) as e:
        print(f"deal.py: bad argument ({e}); see the header of {os.path.basename(__file__)}", file=sys.stderr)
        return 2
    if n is None or n < 1 or (shard is not None and not 1 <= shard <= n):
        print("usage: deal.py --timings FILE --of N [--shard K (1..N)] [--allow-empty] [--report] ITEM... | -", file=sys.stderr)
        return 2
    try:
        timings = load_timings(timings_path)
    except ValueError as e:
        print(f"deal.py: {e}", file=sys.stderr)
        return 2
    if not timings:
        print(f"deal.py: no recorded times in {timings_path or '(no file given)'}: every item weighs the same", file=sys.stderr)
    if not items:
        print("deal.py: no items to deal", file=sys.stderr)
        return 1
    shards, load = deal(items, timings, n)
    if report:
        known = sum(1 for i in set(items) if i in timings)
        print(f"deal.py: {len(set(items))} items to {n} shards, {known} with a recorded time, the rest at the median", file=sys.stderr)
        for k in range(n):
            print(f"deal.py: shard {k + 1} of {n}: {len(shards[k])} items, about {load[k]:.0f} s", file=sys.stderr)
    if shard is None:
        for k in range(n):
            for i in shards[k]:
                print(f"{k + 1}\t{i}")
        return 0
    mine = shards[shard - 1]
    if not mine and not allow_empty:
        print(f"deal.py: shard {shard} of {n} has no item", file=sys.stderr)
        return 1
    for i in mine:
        print(i)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
