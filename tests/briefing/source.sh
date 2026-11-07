#!/usr/bin/env bash
# lib.sh is sourced by the three scripts and by sala's SALA_WATCH_NOTIFY_CMD (`bash -c ". <dir>/lib.sh; post_slack …"`):
# it must source from any directory and through a symlink, find its own directory, and never exit the caller.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd); D=$ROOT/contrib/briefing
fail=0; ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fail=1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export BRIEFING_LOGDIR="$T/logs"   # unset, lib.sh would migrate the real old ~/.cache directory
mkdir -p "$T/home" "$T/elsewhere" "$T/links"
ln -s "$D/lib.sh" "$T/links/lib.sh"         # a symlink to the file
ln -s "$D" "$T/links/briefing"              # a symlinked directory (the old ~/bin/briefing shape)
probe() { # probe <path to lib.sh>: source it in a fresh bash from another directory, report BRIEFING_DIR, keep going
    (cd "$T/elsewhere" && HOME="$T/home" bash -c '. "$1"; echo "dir=$BRIEFING_DIR"; echo alive' _ "$1" 2>/dev/null)
}
for p in "$D/lib.sh" "$T/links/lib.sh" "$T/links/briefing/lib.sh"; do
    out=$(probe "$p"); rc=$?
    want=$(cd "$D" && pwd -P)
    [ $rc = 0 ] && printf '%s\n' "$out" | grep -qx alive && ok "sourced via ${p#$T/} without exiting the caller" || bad "sourcing ${p#$T/} rc=$rc: $out"
    printf '%s\n' "$out" | grep -qx "dir=$want" && ok "BRIEFING_DIR resolves to the checkout" || bad "BRIEFING_DIR from ${p#$T/}: $out"
done
# each script finds lib.sh beside itself: its own source line, run from elsewhere with $0 standing in for BASH_SOURCE
for s in summary.sh defunct.sh release-alert.sh summary-lean.sh lean-compare.sh; do
    line=$(grep -m1 '^\. ' "$D/$s")
    code="$(printf '%s\n' "$line" | sed 's#\${BASH_SOURCE\[0\]}#$0#')"$'\n''echo "$BRIEFING_DIR"'
    res=$(cd "$T/elsewhere" && HOME="$T/home" bash -c "$code" "$T/links/briefing/$s" 2>/dev/null)
    [ "$res" = "$(cd "$D" && pwd -P)" ] && ok "$s sources lib.sh from its own directory" || bad "$s source line resolved '$res'"
done
exit $fail
