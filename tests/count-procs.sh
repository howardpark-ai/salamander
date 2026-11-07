#!/usr/bin/env bash
# tests/count-procs.sh — how many processes a suite starts: the repeatable before/after for "the suites cost the
# box too much CPU". It runs each named suite ONE AT A TIME under `strace -f` and counts two things: EXEC = successful execve
# calls (every external command, every tmux/fake-claude process the suite starts) and FORK = processes created (clone/fork
# without CLONE_THREAD: the above plus every `$(…)` and `( … )` subshell and pipeline stage that ran a builtin only). Then it
# prints a table ranked by FORK, a total, and with -t the commands that account for most of the execs.
# Usage: bash tests/count-procs.sh [-t] [-T secs] [suite…]     no suite named: every suite (as tests/run.sh would run)
#   -t       also print the 12 most-exec'd commands over all the suites run
#   -T secs  `timeout` per suite (default 600)
# Needs strace; ptrace of one's own children is enough (no root). The traced run is slower than a plain one, and a suite's
# own timing checks may fail under it: the count is what matters here, not the suite's verdict (shown as rc).
# Output lines: "<fork> <exec>  <suite>  rc=<exit>  <seconds>s". The strace logs are kept under $COUNT_PROCS_DIR (default: a temp dir, removed).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TOP=0; LIMIT=600
while [ $# -gt 0 ]; do
    case "$1" in
        -t) TOP=1; shift ;;
        -T) LIMIT="${2:?-T needs seconds}"; shift 2 ;;
        -h|--help) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "count-procs.sh: unknown option $1" >&2; exit 2 ;;
        *) break ;;
    esac
done
command -v strace >/dev/null || { echo "count-procs.sh: strace is not installed" >&2; exit 2; }
# the tools, not suites: this list, run.sh's and suitemap.sh's TOOLS must agree
if [ $# -gt 0 ]; then suites=("$@")
else suites=(); for f in "$ROOT"/tests/*.sh; do n=$(basename "$f" .sh); case "$n" in lib|run|count-procs|suitemap) ;; *) suites+=("$n") ;; esac; done; fi
D=${COUNT_PROCS_DIR:-}; if [ -z "$D" ]; then D=$(mktemp -d); trap 'rm -rf "$D"' EXIT; else mkdir -p "$D"; fi
total=0; ftotal=0; rows=()
for s in "${suites[@]}"; do
    [ -f "$ROOT/tests/$s.sh" ] || { echo "count-procs.sh: no suite tests/$s.sh" >&2; exit 2; }
    t=$(date +%s)
    timeout -k 5 "$LIMIT" strace -f --seccomp-bpf -qq -s 300 -e trace=execve,clone,clone3,fork,vfork -o "$D/$s.trace" bash "$ROOT/tests/$s.sh" > "$D/$s.out" 2>&1 < /dev/null
    rc=$?
    read -r f n < <(awk '/execve\(.*= 0$/ {e++} /(clone3?|fork|vfork)\(/ && !/CLONE_THREAD/ && (/<unfinished/ || /= [0-9]+$/) {f++} END {print f+0, e+0}' "$D/$s.trace")
    secs=$(( $(date +%s) - t )); total=$((total + n)); ftotal=$((ftotal + f)); rows+=("$f $n $s rc=$rc ${secs}s")
    printf '%7d %7d  %-16s rc=%s %ss\n' "$f" "$n" "$s" "$rc" "$secs" >&2
done
echo "── processes per suite, most first:   FORK    EXEC"
printf '%s\n' "${rows[@]}" | sort -rn | while read -r f n s rc secs; do printf '%7d %7d  %-16s %s %s\n' "$f" "$n" "$s" "$rc" "$secs"; done
printf '%7d %7d  total (%d suites)\n' "$ftotal" "$total" "${#suites[@]}"
if [ "$TOP" = 1 ]; then
    echo "── most exec'd commands"
    cat "$D"/*.trace | grep 'execve(.*= 0$' | sed -E 's/^[0-9]+ +//; s/^execve\("([^"]*)".*/\1/' | sed -E 's|.*/||' | sort | uniq -c | sort -rn | head -12
fi
