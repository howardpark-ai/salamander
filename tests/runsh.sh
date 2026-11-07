#!/usr/bin/env bash
# tests/run.sh names scratch a suite left behind: after the suites, a bare `tmp.XXXXXXXXXX` that appeared in the temp folder during the
# run is listed with what is in it (which says whose it is), and nothing is removed or failed for it. Two fake suites in a copy of the
# runner: one that cleans up after itself (no note), one that leaves a folder (the note names the folder and its contents); the run's own
# folder is gone either way.
# Usage: bash tests/runsh.sh   (exit 0 = pass; a few seconds)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
fail=0; ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fail=1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/sala-runsh.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
exec 8< "$T"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
mkdir -p "$T/tests" "$T/scr"; cp "$ROOT/tests/run.sh" "$T/tests/run.sh"
cat > "$T/tests/clean.sh" <<'EOF'
#!/usr/bin/env bash
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT; : > "$d/f"; echo "  ok   clean"
EOF
cat > "$T/tests/leak.sh" <<'EOF'
#!/usr/bin/env bash
d=$(mktemp -d); : > "$d/fake.log"; : > "$d/.claude"; echo "  ok   leak"
EOF
run() { OUT=$(TMPDIR="$T/scr" bash "$T/tests/run.sh" "$@" 2>&1); RC=$?; }

echo "== a suite that removes its scratch: no note, nothing left"
run clean
[ "$RC" = 0 ] && grep -q 'all passed' <<< "$OUT" && ! grep -q 'scratch left' <<< "$OUT" && ok "a clean suite: all passed, no note" || bad "clean: rc=$RC — $OUT"
[ -z "$(ls -A "$T/scr")" ] && ok "the run's own folder is gone" || bad "left: $(ls -A "$T/scr" | tr '\n' ' ')"

echo "== a suite that leaves a bare tmp folder: named with its contents, not removed, not a failure"
run clean leak
left=$(ls -A "$T/scr" | tr '\n' ' ')
case "$left" in tmp.??????????\ ) ok "one folder is left in the temp folder: $left" ;; *) bad "unexpected: $left" ;; esac
d=$(ls -A "$T/scr" | head -1)
[ "$RC" = 0 ] && grep -q 'scratch left in' <<< "$OUT" && grep -qF "$T/scr/$d: " <<< "$OUT" && grep -q '\.claude' <<< "$OUT" && grep -q 'fake\.log' <<< "$OUT" \
    && ok "the note names the folder and what is in it; the run still passes" || bad "note: rc=$RC — $OUT"
rm -rf "$T/scr/$d"

echo "runsh: $([ "$fail" = 0 ] && echo pass || echo FAIL)"
exit $fail
