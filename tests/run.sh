#!/usr/bin/env bash
# tests/run.sh — runs the suites side by side. Each suite already runs in its own temporary HOME on its own private
# tmux socket (sala-<suite>-$$) with its own compiled fake claude, so they share nothing and run concurrently.
# Usage: bash tests/run.sh [-j N] [--shard K/N] [--list] [suite…]
#   no suite named: every tests/*.sh except lib.sh, run.sh, count-procs.sh and suitemap.sh (a new suite is picked up by its file alone;
#   the tools are listed in the `case` below, in count-procs.sh and in suitemap.sh's TOOLS: the three lists must agree)
#   -j N: at most N suites at once (default: all of them)
#   --shard K/N: run only runner K's share (1..N) of the suites named (or of every suite), dealt by their recorded times
#   (tests/timings.json, .github/scripts/deal.py: greedy longest-first bin packing, the way CI's `suites-shard` jobs split the work).
#   A suite with no recorded time weighs the median, so a new suite is dealt with no line to add; a share with no suite (a pull
#   request that runs few) says so and exits 0.
#   --list: print the suites this run would start (after --shard), in start order, on one line, and run none (CI asks whether its
#   share is empty before it installs anything).
#   The suites START longest first (the recorded times, shard or not): the slowest set the wall time, and a long one started last
#   runs alone at the end. With no python3 or no dealer, the order given, as before (--shard then exits 2).
# Prints each suite's output as one block when it ends, then a per-suite time and pass/fail table; exit 1 when any failed.
# SERIAL lists the suites that must run alone, after the parallel ones (none today; a suite goes there only with a reason
# written next to it).
# A suite that runs longer than SALA_SUITE_TIMEOUT seconds (default 1200; the slowest takes ~2 min) is stopped and fails with exit
# 124 (where `timeout` exists), so one hang costs a red suite and its output, not the CI job's 90 minutes (the CI box, Oct 27th).
# A cancelled job (SIGINT, then SIGTERM, to this script; Oct 28th): the suites run in the background, where bash ignores SIGINT, and
# were left running as orphans that the runner's end-of-job sweep killed with SIGKILL, so their temporary HOME stayed in /tmp
# (36 /tmp/tmp.XXXXXXXXXX on the CI box). This script now forwards the stop to every suite (SIGTERM, which runs the suite's EXIT
# trap: its cleanup) and waits for them to finish cleaning up before it exits 143.

# --help prints the comment block above (from line 2 to its first non-comment line), so keep that block contiguous.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SERIAL=()
JOBS=0
SHARD=""
LIST=""
while [ $# -gt 0 ]; do
    case "$1" in
        -j) JOBS="${2:?-j needs a number}"; shift 2 ;;
        -j*) JOBS="${1#-j}"; shift ;;
        --shard) SHARD="${2:?--shard needs K/N}"; shift 2 ;;
        --list) LIST=1; shift ;;
        -h|--help) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --) shift; break ;;
        -*) echo "run.sh: unknown option $1" >&2; exit 2 ;;
        *) break ;;
    esac
done
case "$JOBS" in ''|*[!0-9]*) echo "run.sh: -j takes a number" >&2; exit 2 ;; esac
if [ -n "$SHARD" ]; then
    [[ $SHARD =~ ^([1-9][0-9]*)/([1-9][0-9]*)$ ]] && [ "${BASH_REMATCH[1]}" -le "${BASH_REMATCH[2]}" ] \
        || { echo "run.sh: --shard takes K/N with 1 <= K <= N" >&2; exit 2; }
    SHARD_K=${BASH_REMATCH[1]}; SHARD_N=${BASH_REMATCH[2]}
fi
if [ $# -gt 0 ]; then suites=("$@")
else suites=(); for f in "$ROOT"/tests/*.sh; do n=$(basename "$f" .sh); case "$n" in lib|run|count-procs|suitemap) ;; *) suites+=("$n") ;; esac; done; fi
for s in "${suites[@]}"; do [ -f "$ROOT/tests/$s.sh" ] || { echo "run.sh: no suite tests/$s.sh" >&2; exit 2; }; done
# Order (the longest recorded time first) and, with --shard, deal: .github/scripts/deal.py reads tests/timings.json. Without --shard a
# dealer that fails (a timings file that is not valid) leaves the list as given; the dealer says why on stderr.
DEAL="$ROOT/.github/scripts/deal.py"
if [ -f "$DEAL" ] && command -v python3 >/dev/null 2>&1; then
    rc=0
    dealt=$(for s in "${suites[@]}"; do echo "tests/$s.sh"; done | python3 -I "$DEAL" --timings "$ROOT/tests/timings.json" \
        --of "${SHARD_N:-1}" --shard "${SHARD_K:-1}" --allow-empty ${SHARD:+--report} -) || rc=$?
    if [ "$rc" = 0 ]; then
        suites=(); [ -z "$dealt" ] || mapfile -t suites <<< "$dealt"
        suites=("${suites[@]#tests/}"); suites=("${suites[@]%.sh}")
    elif [ -n "$SHARD" ]; then echo "run.sh: the dealer failed (exit $rc), so --shard $SHARD cannot be made" >&2; exit 2; fi
elif [ -n "$SHARD" ]; then echo "run.sh: --shard needs python3 and .github/scripts/deal.py" >&2; exit 2; fi
if [ -n "$LIST" ]; then echo "${suites[*]-}"; exit 0; fi   # --list: the suites this run would start, in start order, and nothing is run
if [ "${#suites[@]}" -eq 0 ]; then echo "run.sh: shard ${SHARD:-1/1} has no suite to run: nothing to do"; exit 0; fi
par=(); ser=()
for s in "${suites[@]}"; do case " ${SERIAL[*]-} " in *" $s "*) ser+=("$s") ;; *) par+=("$s") ;; esac; done

OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT
: > "$OUT/.t0"   # the run's start: scratch newer than this, left in the temp folder at the end, is named below
SPIDS=()   # the background subshell of each suite started, for cancel
cancel() {  # INT, TERM or HUP: stop the suites the way their own timeout would (SIGTERM to the timeout, which hands it on), wait for their cleanup
    trap '' INT TERM HUP
    local p; for p in ${SPIDS[@]+"${SPIDS[@]}"}; do pkill -TERM -P "$p" 2>/dev/null; done
    wait
    exit 143
}
trap cancel INT TERM HUP
T0=$(date +%s)
TO=(); command -v timeout >/dev/null 2>&1 && TO=(timeout -k 10 "${SALA_SUITE_TIMEOUT:-1200}")
start() {  # <suite>: in the background; its output, exit code and seconds land in $OUT
    local s="$1"
    ( t=$(date +%s); ${TO[@]+"${TO[@]}"} bash "$ROOT/tests/$s.sh" > "$OUT/$s.out" 2>&1; rc=$?
      [ "$rc" = 124 ] && echo "tests/run.sh: $s stopped after ${SALA_SUITE_TIMEOUT:-1200} s (SALA_SUITE_TIMEOUT); the output above is all it printed" >> "$OUT/$s.out"
      echo "$rc $(( $(date +%s) - t ))" > "$OUT/$s.rc" ) </dev/null &
    SPIDS+=("$!")
}
report() {  # <suite>: its block, once it has ended
    local s="$1" rc secs; read -r rc secs < "$OUT/$s.rc"
    echo "════ tests/$s.sh ($( [ "$rc" = 0 ] && echo pass || echo "FAIL, exit $rc" ), ${secs}s)"
    cat "$OUT/$s.out"; echo
}
shown=()
show_done() {  # print the blocks of the suites that have ended since the last call
    local s; for s in "${suites[@]}"; do
        [ -e "$OUT/$s.rc" ] || continue; case " ${shown[*]-} " in *" $s "*) continue ;; esac
        report "$s"; shown+=("$s")
    done
}
running() { local s n=0; for s in ${started[@]+"${started[@]}"}; do [ -e "$OUT/$s.rc" ] || n=$((n+1)); done; echo "$n"; }
started=()
for s in ${par[@]+"${par[@]}"}; do
    while [ "$JOBS" -gt 0 ] && [ "$(running)" -ge "$JOBS" ]; do wait -n 2>/dev/null || sleep 0.5; show_done; done   # wait -n (bash 4.3; older shells poll): a suite ending wakes this loop (it was a sleep 0.5 and a $(running) subshell per half second)
    start "$s"; started+=("$s")
done
while [ "$(running)" -gt 0 ]; do wait -n 2>/dev/null || sleep 0.5; show_done; done
for s in ${ser[@]+"${ser[@]}"}; do start "$s"; started+=("$s"); wait; show_done; done
wait; show_done

fail=0
echo "════ summary ($( [ "${#ser[@]}" -gt 0 ] && echo "${#par[@]} parallel, ${#ser[@]} serial" || echo "${#par[@]} in parallel"), wall $(( $(date +%s) - T0 ))s)"
for s in "${suites[@]}"; do
    read -r rc secs < "$OUT/$s.rc"
    if [ "$rc" = 0 ]; then printf '  pass  %-12s %4ss\n' "$s" "$secs"; else printf '  FAIL  %-12s %4ss  (exit %s)\n' "$s" "$secs" "$rc"; fail=1; fi
done
# A suite removes its scratch on every exit (an EXIT trap); one that still leaves a bare `tmp.XXXXXXXXXX` in the temp folder is named here,
# with what is in it (which says whose it is), instead of being found later by a job's leftover check. Not a failure: the folder may also be
# another process's, running at the same time. Nothing is removed here.
left=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'tmp.??????????' ! -path "$OUT" -newer "$OUT/.t0" 2>/dev/null | sort)
if [ -n "$left" ]; then
    echo "  note  scratch left in ${TMPDIR:-/tmp} since this run began (a suite of this run, or anything else running meanwhile):"
    while IFS= read -r d; do echo "        $d: $(ls -A "$d" 2>/dev/null | head -8 | tr '\n' ' ')"; done <<< "$left"
fi
[ "$fail" = 0 ] && echo "all passed" || echo "FAILED"
exit $fail
