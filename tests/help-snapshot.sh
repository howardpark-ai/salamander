#!/usr/bin/env bash
# tests/help-snapshot.sh — check 1 of the help-text gates: a sala release
# must not ship with out-of-date help. The text sala prints about itself is kept as a tracked snapshot,
# tests/help-snapshot.txt, and this suite regenerates it and diffs: a change to a command's shape, words or output that
# touches the help shows up as a diff in the PR, and one that should have touched it but did not is caught by the
# model review (.github/scripts/help-review.sh) reading the same diff.
#
# What the snapshot holds (sala's help is one comment block at the top of bin/salamander, so there is one top-level text,
# and only some verbs answer `--help` or a wrong call with a usage of their own):
#   - `sala --help`, the whole usage;
#   - for each verb in the PROBES list below, the output of its documented help call (`sala <verb> --help`) with its exit code;
#   - the verbs the top-level text names that are NOT probed, listed (a verb with no safe help path is listed, never failed).
# A probe is a call that prints text and does nothing else: each runs in a clean environment (`env -i`, a throwaway HOME,
# no tmux, no network, stdin closed, 30 s). `env -i` drops TMUX, TMUX_PANE and every SALA_* / lane variable, and TMUX_TMPDIR
# points at an empty directory, so a tmux server running on the box (the fleet's default socket) is not reachable either:
# the snapshot is the same inside tmux, outside it and on a runner with no tmux installed (a probe that read $TMUX unset
# under set -u printed a shell error on the runner only). A verb whose `--help` would run the verb (spawn, watch, update, ...) is not in
# PROBES. Adding `--help` to a verb means adding its line to PROBES; the snapshot then holds its usage.
# Deterministic: the checkout's path and the throwaway HOME are replaced by <ROOT> and <HOME>; no dates, hosts or pids.
#
# Usage: bash tests/help-snapshot.sh              the suite: regenerate, diff against the snapshot (exit 1 on drift)
#        bash tests/help-snapshot.sh --update     rewrite the snapshot (then commit it: its diff is the release note's what-changed line)
#        bash tests/help-snapshot.sh --generate   print the regenerated text (what help-review.sh and skills-flags.sh read)
# Env:   HELP_SNAPSHOT_ROOT  the checkout whose bin/salamander is run (default: this one; the drift tests use a copy)
#        HELP_SNAPSHOT_FILE  the snapshot (default: tests/help-snapshot.txt of this checkout)
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
R=${HELP_SNAPSHOT_ROOT:-$HERE}
GEN_T=""; new=""; tmp=""   # the scratch dir generate() makes and the two scratch files below: one EXIT trap removes whatever exists
trap 'rm -rf "${GEN_T:-}"; rm -f "${new:-}" "${tmp:-}"' EXIT
SNAP=${HELP_SNAPSHOT_FILE:-$HERE/tests/help-snapshot.txt}

# the verbs whose help call is safe (prints text, does nothing else), each as the words before --help
PROBES=("lane" "model" "reauth" "question" "resume-answer" "recycle" "recycle --when-idle" "revive" "op" "restore"
        "note" "notice" "sdk-pane" "rc" "settings-apply" "side" "sessions" "job" "ci-runs" "mq")

generate() {
    local t home out rc probe verb v seen="" unprobed="" bash_dir
    t=$(mktemp -d) || return 1; GEN_T=$t
    home=$t/home; mkdir -p "$home" "$t/tmux"
    bash_dir=$(dirname "$(command -v bash)")
    run() {  # <args…> → sala's output (stdout + stderr) in $out, its exit code in $rc, paths normalised
        out=$(cd "$t" && timeout 30 env -i HOME="$home" PATH="$bash_dir:/usr/bin:/bin" LC_ALL=C TERM=dumb TMUX_TMPDIR="$t/tmux" \
              bash "$R/bin/salamander" "$@" </dev/null 2>&1); rc=$?
        out=${out//"$R"/<ROOT>}; out=${out//"$home"/<HOME>}; out=${out//"$t"/<TMP>}
    }
    run --help
    printf '### sala --help (exit %s)\n%s\n' "$rc" "$out"
    local top=$out
    for probe in "${PROBES[@]}"; do
        # shellcheck disable=SC2086
        run $probe --help
        printf '\n### sala %s --help (exit %s)\n%s\n' "$probe" "$rc" "$out"
        seen="$seen ${probe%% *} "
    done
    # the verbs the top-level text names (a line "  salamander <verb> …"), minus the probed ones
    while IFS= read -r v; do
        case "$seen" in *" $v "*) ;; *) unprobed="$unprobed $v" ;; esac
    done < <(printf '%s\n' "$top" | awk '/^  salamander [a-z]/ { print $2 }' | sort -u)
    printf '\n### verbs with no help path of their own (listed, not probed; their usage is the sala --help text above):%s\n' "$unprobed"
    rm -rf "$t"
}

case "${1:-}" in
    --generate) generate; exit $? ;;
    --update)
        tmp=$(mktemp) && generate > "$tmp" && mv -f "$tmp" "$SNAP" || { echo "help-snapshot: could not write $SNAP" >&2; rm -f "$tmp"; exit 1; }
        echo "help-snapshot: wrote $SNAP ($(wc -l < "$SNAP") lines). Commit it: its diff is the release note's what-changed line."
        exit 0 ;;
    -h|--help) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    '') ;;
    *) echo "help-snapshot: unknown argument $1 (see --help)" >&2; exit 2 ;;
esac

fail=0
[ -f "$SNAP" ] || { echo "  FAIL no snapshot at $SNAP — create it: bash tests/help-snapshot.sh --update"; echo "help-snapshot: FAIL"; exit 1; }
new=$(mktemp) && generate > "$new" || { echo "  FAIL could not regenerate the help text"; rm -f "$new"; exit 1; }
if cmp -s "$SNAP" "$new"; then
    echo "  ok   sala's help text matches the snapshot ($(grep -c '^### ' "$new") sections, $(wc -l < "$new") lines)"
else
    echo "  FAIL sala's help text drifted from the snapshot:"
    diff -u --label "tests/help-snapshot.txt (committed)" --label "regenerated from this checkout" "$SNAP" "$new" | sed 's/^/    /'
    echo "  FIX  if the change is intended: bash tests/help-snapshot.sh --update, then commit tests/help-snapshot.txt."
    echo "       Its diff is the release note's what-changed line. A change to a command's shape, words or output also"
    echo "       carries the matching skills change in the same release (CONTRIBUTING.md, 'Help and skills text')."
    fail=1
fi
[ "$fail" = 0 ] && echo "help-snapshot: pass" || echo "help-snapshot: FAIL"
exit $fail
