#!/usr/bin/env bash
# web-shard.sh — which of the web app's test files one shard of tests.yml's `web-shard` job runs. Usage:
#   .github/scripts/web-shard.sh <shard 1..N> <N>
# Prints that shard's files (paths relative to web/, one per line, ready for `pytest $(…)` run in web/), the longest first. The
# files of web/tests/test_*.py are dealt by .github/scripts/deal.py: balanced by their RECORDED run times in web/tests/timings.json,
# greedy longest-first bin packing (the pytest-split `least_duration` way), so the worst shard, which sets the wall time, is as
# light as the files allow. The old split dealt them by size round-robin, and size follows time badly (the browser tests dominate
# the run time, and the three heaviest files by time were 11% of it). A new test file is picked up by its name alone: it has no
# recorded time yet and weighs the median of the recorded ones; a recorded file that is gone is ignored; refresh the record with
# .github/scripts/update_timings.py (CONTRIBUTING.md, *Timings*). Every shard (a job on another runner) computes the whole deal
# itself and the deal is deterministic. Exit 0 with the files; 2 for a bad argument or a timings file that is not valid; 1 when the
# shard has no file (more shards than test files), which fails the job rather than letting an empty `pytest` run every test.
set -euo pipefail
if [ $# -ne 2 ] || ! [[ $1 =~ ^[1-9][0-9]*$ && $2 =~ ^[1-9][0-9]*$ ]] || [ "$1" -gt "$2" ]; then
    echo "usage: web-shard.sh <shard 1..N> <N>" >&2; exit 2
fi
here=$(cd "$(dirname "$0")" && pwd)
cd "$here/../../web"
shopt -s nullglob
files=(tests/test_*.py)
[ "${#files[@]}" -gt 0 ] || { echo "web-shard.sh: no tests/test_*.py under web/" >&2; exit 1; }
rc=0
out=$(printf '%s\n' "${files[@]}" | python3 -I "$here/deal.py" --timings tests/timings.json --shard "$1" --of "$2" --report -) || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 1 ] || exit "$rc"
[ -n "$out" ] || { echo "web-shard.sh: shard $1 of $2 has no test file" >&2; exit 1; }
echo "$out"
