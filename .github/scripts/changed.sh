#!/usr/bin/env bash
# changed.sh — what a change touches, for the `changes` job of tests.yml: three lines in $GITHUB_OUTPUT's
# form, `sala=<true|false>` (a suite has to run), `web=<true|false>` (something under web/ changed, and web/pyproject.toml
# exists at <to>: the web app's tests run) and `suites=<all|names…|>` (which suites: below).
# A change under .github/ counts for both: the gate itself changed, and running everything is what catches a wrong gate.
# THE SUITES. `sala` used to be "something outside web/ changed", which ran all ~46 suites for a one-line docs fix.
# tests/suitemap.sh --select now answers from tests/suites.map (the tracked files each suite opens, measured): `all`, the names of
# the suites whose files the change touches, or nothing (a docs change, a file no suite opens). `sala` is true exactly when that
# answer is not empty. tests.yml runs the named suites on a pull request and EVERY suite in a merge-queue entry (changed.sh is given a range it cannot resolve), so a file the map
# does not know about is caught there, before the merge. A range it cannot resolve is `all`, as for the web tests below.
# Usage: changed.sh <from> <to>   two commits of the checkout it runs in. A <from> it cannot resolve (a new branch's zero
# sha, a shallow clone, `none`) counts as everything changed. The file list and the verdict go to stderr, for the log.
set -euo pipefail
from="${1:?usage: changed.sh <from> <to>}"; to="${2:?usage: changed.sh <from> <to>}"
has() { git cat-file -e "$1^{commit}" 2>/dev/null; }
sala=false; web=false; suites=
if has "$from" && has "$to"; then
    files="$(git diff --name-only --no-renames "$from" "$to")"   # --no-renames: a moved file is both names (a lib/ file moved into web/ is still a sala change)
    echo "changed: $(git rev-parse --short "$from")..$(git rev-parse --short "$to"), $(echo "$files" | grep -c . || true) file(s)" >&2
    [ -z "$files" ] || echo "$files" | sed 's/^/  /' >&2
    while IFS= read -r f; do
        case "$f" in '') ;; web/*|.github/*) web=true ;; esac
    done <<< "$files"
    # the tool reads this checkout (the one changed.sh runs in); any failure of it counts as everything, never as nothing
    suites="$(SUITEMAP_ROOT="$(git rev-parse --show-toplevel)" bash "$(dirname "$0")/../../tests/suitemap.sh" --select "$from" "$to")" \
        || { echo "changed: tests/suitemap.sh --select failed: every suite runs" >&2; suites=all; }
else
    echo "changed: no range $from..$to in this checkout: everything counts as changed" >&2
    suites=all; web=true
fi
[ -z "$suites" ] || sala=true
at="$(has "$to" && echo "$to" || echo HEAD)"
if [ "$web" = true ] && ! git cat-file -e "$at:web/pyproject.toml" 2>/dev/null; then
    echo "changed: no web/pyproject.toml at $at: no web tests to run" >&2; web=false
fi
echo "changed: sala=$sala web=$web suites=${suites:-<none>}" >&2
echo "sala=$sala"; echo "web=$web"; echo "suites=$suites"
