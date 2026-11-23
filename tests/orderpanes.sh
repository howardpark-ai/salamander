#!/usr/bin/env bash
# The order revive sweeps the panes in (lib/revive.sh ordered_panes): least recently active first, by claude.ai's last_event_at for the
# pane's bridge id, else by the transcript's mtime. The bridge id is the last `remote_session_change` record of the transcript. It used
# to be found by reading each pane's whole transcript into one string, on every revive: one conversation of ~850 MB took ~6 GB, and
# with a few other big processes a host-wide out-of-memory stop followed. It is now read from the END of the transcript, one 4 MiB piece
# at a time, and only as far as SALA_BRIDGE_SCAN_MAX bytes (64 MiB). What is checked:
#  - the order itself: panes with a bridge id go by the sessions API's time (a stand-in file, SALA_CLOUD_SESSIONS_FILE), a pane with none by its
#    transcript's mtime, and the two kinds interleave by that one number;
#  - the LAST bridge record wins over an older one earlier in the same transcript, and a record cut by a piece boundary is found whole;
#  - a transcript of 600 MB (sparse) is read under a memory ceiling (ulimit -v) a whole-file read cannot stay under, and still yields its
#    bridge id (a read that failed on memory read as "no bridge" and silently changed the order);
#  - past SALA_BRIDGE_SCAN_MAX from the end a record is not looked for: the pane falls back to its mtime.
# The function is taken out of lib/revive.sh as it ships (sed on its first and last line); tmux is a stub that lists the panes, the process
# tree is the registry's own pid per pane (no process runs). No tmux, no claude, no network, no token. Isolated HOME.
# Usage: bash tests/orderpanes.sh   (exit 0 = pass; ~5 s)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
export HOME; HOME=$(mktemp -d "${TMPDIR:-/tmp}/sala-orderpanes.XXXXXX")
case "$HOME" in /tmp/*|"${TMPDIR:-/tmp}"/*) ;; *) echo "orderpanes: HOME is not a temporary directory ($HOME) - refusing to run"; exit 1;; esac
exec {HOME_LOCK}< "$HOME"; flock -n "$HOME_LOCK" 2>/dev/null   # the temp folder is locked while the suite runs (systemd-tmpfiles ageing honors it)
cleanup() { rm -rf "$HOME" 2>/dev/null; true; }; trap cleanup EXIT
export SALA_REG_DIR="$HOME/reg" SALA_SIDECAR="$HOME/pane-map.tsv" SALA_PROJECTS="$HOME/projects" SALA_CLOUD_SESSIONS_FILE="$HOME/cloud.json"
mkdir -p "$SALA_REG_DIR" "$SALA_PROJECTS/p"; : > "$SALA_SIDECAR"
unset SALA_BRIDGE_SCAN_MAX
eval "$(sed -n '/^ordered_panes() {/,/^}/p' "$ROOT/lib/revive.sh")"
declare -F ordered_panes >/dev/null || { echo "orderpanes: ordered_panes not found in lib/revive.sh"; exit 1; }
PANES=""
tmux() { printf '%s' "$PANES"; }   # the one call ordered_panes makes: list-panes -a
uuid() { printf '%08x-0000-4000-8000-%012x' "$1" "$1"; }   # <n> → the n-th conversation id
tfile() { echo "$SALA_PROJECTS/p/$(uuid "$1").jsonl"; }    # <n> → its transcript
# pane <n> <session> → a registry row (pid 900000+n stands in for the pane's shell and its claude) and the pane's line
pane() {
    printf '{"pid": %d, "tmux": "x", "sessionId": "%s"}\n' "$((900000 + $1))" "$(uuid "$1")" > "$SALA_REG_DIR/$((900000 + $1)).json"
    PANES="$PANES%$1|$2|0|t|claude|$((900000 + $1))|/x"$'\n'
}
# transcript <n> <mtime as a date> [<id> …]: the conversation's file with those bridge records one after the other
transcript() {
    local n=$1 when=$2 id; shift 2; : > "$(tfile "$n")"
    for id in "$@"; do printf '{"type":"remote_session_change","url":"https://claude.ai/code/session_%s"}\n' "$id" >> "$(tfile "$n")"; done
    touch -d "$when" "$(tfile "$n")"
}
# sparse <n> <MiB> <mtime> <offset>:<id> …: a transcript of that size with one bridge record at each offset (negative: that many bytes
# before the end; 0: the start) and a newline at the end
sparse() {
    local n=$1 mib=$2 when=$3; shift 3
    python3 -I - "$(tfile "$n")" "$mib" "$@" <<'PY'
import sys
path, mib = sys.argv[1], int(sys.argv[2])
with open(path, "wb") as f:
    for spec in sys.argv[3:]:
        off, rid = spec.split(":")
        off = int(off)
        r = ('{"type":"remote_session_change","url":"https://claude.ai/code/session_%s"}\n' % rid).encode()
        f.seek(off if off >= 0 else (mib << 20) + off - len(r)); f.write(r)
    f.seek((mib << 20) - 1); f.write(b"\n")
PY
    touch -d "$when" "$(tfile "$n")"
}
# cloud <id> <time> … → the sessions API's answer
cloud() {
    local out='{"data": [' sep=""
    while [ $# -ge 2 ]; do out="$out$sep{\"id\": \"session_$1\", \"last_event_at\": \"$2\"}"; sep=", "; shift 2; done
    printf '%s]}\n' "$out" > "$SALA_CLOUD_SESSIONS_FILE"
}
order() { ordered_panes | cut -d'|' -f2 | paste -sd' ' -; }   # → the sessions, in sweep order
reset() { PANES=""; rm -f "$SALA_REG_DIR"/*.json "$SALA_PROJECTS"/p/*.jsonl; }

echo "== the order: the sessions API's time for a pane with a bridge id, the transcript's mtime for one without"
pane 1 s1; pane 2 s2; pane 3 s3; pane 4 s4
transcript 1 "2025-01-01 00:00:00 UTC" AAA        # oldest file, newest in the API
transcript 2 "2025-02-01 00:00:00 UTC" BBB
transcript 3 "2025-03-01 00:00:00 UTC"            # no bridge: its mtime, March 2025
transcript 4 "2025-04-01 00:00:00 UTC" OLD CCC    # two records: the LAST (CCC) counts
cloud AAA 2026-03-01T00:00:00Z BBB 2026-02-01T00:00:00Z CCC 2026-01-01T00:00:00Z OLD 2026-12-01T00:00:00Z
[ "$(order)" = "s3 s4 s2 s1" ] && ok "s3 (mtime), s4 (its last record's time), s2, s1: oldest first, the two kinds on one scale" || bad "order: $(order)"
cloud
[ "$(order)" = "s1 s2 s3 s4" ] && ok "an API that lists none of them: every pane by its mtime" || bad "order: $(order)"

echo "== a record cut by a piece boundary, an older record far from the end"
reset; pane 5 s5; pane 6 s6; pane 7 s7
# s5: 12 MiB; the pieces end at 8 MiB and 4 MiB from the start; its newest record starts 20 bytes before the 8 MiB mark and is cut by it
sparse 5 12 "2025-05-01 00:00:00 UTC" 0:OLD $(( (8 << 20) - 20 )):NEW
sparse 6 8 "2025-06-01 00:00:00 UTC" 0:OLD -100:NEW6           # s6: its record ends 100 bytes before the end
transcript 7 "2025-07-01 00:00:00 UTC"                         # s7: no bridge, mtime July 2025
cloud NEW 2026-02-01T00:00:00Z NEW6 2026-01-01T00:00:00Z OLD 2027-01-01T00:00:00Z
[ "$(order)" = "s7 s6 s5" ] && ok "s5's record, cut by a boundary, is found whole (NEW, not the OLD one at the start); s6's is in the last bytes; s7 by mtime" || bad "order: $(order)"

echo "== a transcript of 600 MB under a memory ceiling a whole-file read cannot stay under"
reset; pane 8 s8; pane 9 s9
sparse 8 600 "2025-08-01 00:00:00 UTC" 0:OLD -1:NEW8
transcript 9 "2025-09-01 00:00:00 UTC"
cloud NEW8 2026-06-01T00:00:00Z
out=$( ulimit -v 900000; order )
[ "$out" = "s9 s8" ] && ok "s8 (600 MB, its bridge record read from the end) sorts by the API's time, after s9's mtime, the process capped at 900 MB of address space" || bad "order under the ceiling: [$out]"
out=$( ulimit -v 900000; python3 -I -c 'import sys
try: open(sys.argv[1], encoding="utf-8", errors="replace").read(); print("read")
except MemoryError: print("memory")' "$(tfile 8)" )
[ "$out" = memory ] && ok "(control: the old whole-file read does not fit under that ceiling)" || bad "control: the whole-file read fitted ($out): the ceiling proves nothing"
rm -f "$(tfile 8)"

echo "== past SALA_BRIDGE_SCAN_MAX from the end a record is not looked for"
reset; pane 10 s10; pane 11 s11
sparse 10 8 "2025-10-01 00:00:00 UTC" 0:FAR                    # its only record is 8 MiB from the end
transcript 11 "2025-11-01 00:00:00 UTC"
cloud FAR 2026-06-01T00:00:00Z
[ "$(order)" = "s11 s10" ] && ok "default (64 MiB): the record 8 MiB from the end is found, s10 sorts by the API's time" || bad "order: $(order)"
out=$(SALA_BRIDGE_SCAN_MAX=1048576 order)
[ "$out" = "s10 s11" ] && ok "SALA_BRIDGE_SCAN_MAX=1 MiB: not found, s10 falls back to its mtime (before s11's)" || bad "order with a 1 MiB reach: [$out]"

[ "$fail" = 0 ] && echo "orderpanes: pass" || echo "orderpanes: FAIL"
exit $fail
