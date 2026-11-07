#!/usr/bin/env bash
# web-shard.sh — which of the web app's test files one shard of tests.yml's `web-shard` job runs. Usage:
#   .github/scripts/web-shard.sh <shard 1..N> <N>
# Prints that shard's files (paths relative to web/, one per line, ready for `pytest $(…)` run in web/). The files of
# web/tests/test_*.py are sorted by size, largest first, and dealt round-robin to the N shards, so each shard gets a
# similar mix of big and small files and a new test file is picked up by its name alone (the browser tests dominate the
# run time and follow file size well enough). The sort is by size, ties by name in the C locale, so every shard (a job on
# another runner) computes the same split. Exit 0 with the files; 2 for a bad argument; 1 when the shard has no file
# (more shards than test files), which fails the job rather than letting an empty `pytest` run every test.
set -euo pipefail
if [ $# -ne 2 ] || ! [[ $1 =~ ^[1-9][0-9]*$ && $2 =~ ^[1-9][0-9]*$ ]] || [ "$1" -gt "$2" ]; then
    echo "usage: web-shard.sh <shard 1..N> <N>" >&2; exit 2
fi
cd "$(dirname "$0")/../../web"
shopt -s nullglob
files=(tests/test_*.py)
[ "${#files[@]}" -gt 0 ] || { echo "web-shard.sh: no tests/test_*.py under web/" >&2; exit 1; }
out=$(LC_ALL=C ls -S -- "${files[@]}" | awk -v s="$1" -v n="$2" '(NR-1) % n == s-1')
[ -n "$out" ] || { echo "web-shard.sh: shard $1 of $2 has no test file" >&2; exit 1; }
echo "$out"
