#!/usr/bin/env bash
# The sweep's three phases against fake panes (tests/fake-claude.c) in an isolated HOME on a private tmux socket: the panes
# are closed in parallel, resumed in ordered_panes' order a fixed gap apart, every failure path releases its inbox hold,
# and --only runs the same phases for one pane. Usage: bash tests/phases.sh   (exit 0 = pass; mostly the two timeouts
# the failure panes run into, SALA_EXIT_WAIT and SALA_RESUME_WAIT, short in tests/lib.sh)
set -eu
unset TMUX_PANE XDG_STATE_HOME   # a pane of the real server the test may run from: never a pane of this one; sala state under the sandbox HOME
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, tmux_socket_rm
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null
as_op_unit   # no master: the guarded verbs this suite runs itself stand for the queue's runner (tests/lib.sh, 5)
HOLD="$HOME/.local/state/stackshot/anchor-hub"   # the default SALA_INBOX_HOLD_DIR: present, so holds are taken and released
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$HOLD"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
cc -o "$HOME/.local/bin/claude" "$ROOT/tests/fake-claude.c"
export PATH="$HOME/.local/bin:$PATH"; FAKE_LOG="$HOME/fake.log"
SOCK="sala-phases-$$"; T="tmux -L $SOCK -f /dev/null"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's (common.sh, on_fleet_server)
cleanup() {  # the hold watcher, a recycle driver (its session) and the retry worker it may have left, the tmux server, the HOME
    kill "${WATCH:-}" "${HW:-}" "${GW:-}" 2>/dev/null || true
    [ -n "${DRIVER:-}" ] && kill -TERM -- -"$DRIVER" 2>/dev/null || true
    for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done; true
    $T kill-server 2>/dev/null || true; tmux_socket_rm; sleep 1; rm -rf "$HOME" 2>/dev/null || true; }; trap cleanup EXIT
UA=aaaaaaaa-0000-4000-8000-000000000001 UB=bbbbbbbb-0000-4000-8000-000000000002 UC=cccccccc-0000-4000-8000-000000000003
UD=dddddddd-0000-4000-8000-000000000004 UE=eeeeeeee-0000-4000-8000-000000000005 UF=ffffffff-0000-4000-8000-000000000006
UG=99999999-0000-4000-8000-000000000007
# a b c relaunch cleanly · d has unsubmitted text (phase 1 skip: never held) · e never leaves on /exit (phase 2 timeout) · g gets
# a turn once its inbox is held (the re-check before the /exit defers it; Fri Oct 30th 2026) · f's resume
# comes up and dies 10 s in (phase 3: a skip, never an UPDATED row; until Oct 9th a 1 s poll that landed while it was up
# counted it as relaunched, lib/revive.sh resume_wait). The fake lives 10 s, not 3, and the sweep waits 20 s, not 5 (FW below):
# resume_wait sees it only if one poll (tmux display, claude_pid_under, sleep 1) lands inside its life, and on a loaded runner a
# poll outlasts 3 s (seen in CI with 47 suites at once, "FAIL f: no 'started and died'
# row", phases took 149 s). A fake living past the wait would read as slow to register (verdict 0), so only this sweep, the one
# command that resumes f, gets the longer wait; nothing later in this file resumes f.
# Transcript mtimes are the order key (no claude.ai here): c oldest,
# then a, then b.
# (g's turn, FAKE_TURN_MS, must still be running when the sweep re-checks g, which a loaded box reaches later: 15 s times the load factor; the
# hold clock's and wait_pr's deadlines below are scaled the same way, so a slow box does not run them out before the thing they wait for happens)
mk() { local n="$1" u="$2"; shift 2; $T new-session -d -s "sala-test-$n" -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="$n" -e FAKE_LOG="$FAKE_LOG" "$@"; $T send-keys -t "sala-test-$n" 'claude' Enter; }
mk a $UA; mk b $UB; mk c $UC; mk d $UD; mk e $UE -e FAKE_IGNORE_EXIT=1; mk f $UF -e FAKE_RESUME_FAIL=1 -e FAKE_RESUME_DELAY=10000; mk g $UG -e FAKE_TURN_MS=$(( $(scale 15) * 1000 ))
python3 - "$HOME/.claude/projects/x" "$UC:300" "$UA:200" "$UB:100" "$UD:50" "$UE:40" "$UF:30" "$UG:20" <<'PY'
import os, sys, time
d = sys.argv[1]; now = time.time()
for a in sys.argv[2:]:
    u, age = a.split(":"); p = os.path.join(d, u + ".jsonl"); open(p, "w").close(); os.utime(p, (now - int(age), now - int(age)))
PY
fake_up a b c d e f g; $T send-keys -t sala-test-d -l 'half a thought'          # typed, never submitted
waitfor "$T capture-pane -p -t sala-test-d | grep -q 'half a thought'" 20
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux    # literal socket: the children run set -u
[ "$(grep -c '^start' "$FAKE_LOG")" = 7 ] || { echo "the seven fake panes did not all start: $(<"$FAKE_LOG")"; exit 1; }
# the most keys held at once: a, b, c, e, f, g are all held during phase 2, so a lost update (unserialized hold edits) shows here
( mx=0; while :; do n=$(grep -c . "$HOLD/held-msg.txt" 2>/dev/null || true); [ "${n:-0}" -gt "$mx" ] && { mx=$n; echo "$mx" > "$HOME/held.max"; }; sleep 0.2; done ) & WATCH=$!
# THE HOLDS COME FIRST (Fri Oct 30th 2026): a clock on the hold file, read every 5 ms, says when the last of the six keys landed (to be
# compared with the first /exit the fakes log) and whether d's, skipped in phase 1, was ever held. A second watcher plays the puller's
# late line: the moment g is held, a message reaches g's composer, a turn (FAKE_TURN_MS) that the re-check before the /exit must see.
cat > "$HOME/holdclock.py" <<'PY'
import sys, time
path, keys, never = sys.argv[1], sys.argv[2].split(","), sys.argv[3]
out = open(sys.argv[4], "w", buffering=1); done = False; end = time.time() + float(sys.argv[5])
while time.time() < end:
    try: have = set(open(path).read().split())
    except OSError: have = set()
    if never in have: out.write("never-held-was-held\n")
    if not done and all(k in have for k in keys): out.write("all-held %.6f\n" % time.time()); done = True
    time.sleep(0.005)
PY
python3 "$HOME/holdclock.py" "$HOLD/held-msg.txt" "$UA,$UB,$UC,$UE,$UF,$UG" "$UD" "$HOME/holdclock.out" "$(scale 120)" & HW=$!
( while ! grep -qxF "$UG" "$HOLD/held-msg.txt" 2>/dev/null; do sleep 0.02; done
  $T send-keys -t sala-test-g -l 'a notice arrives'; $T send-keys -t sala-test-g Enter ) & GW=$!
echo "== dry run (phase 1 only)"
out=$("$ROOT/bin/salamander" revive --dry-run 2>&1) || true; echo "$out" | sed 's/^/    /'
echo "$out" | grep -q 'phase [23]' && bad "dry run ran phase 2 or 3" || ok "dry run: no phase 2/3 (nothing closed or resumed)"
echo "== the sweep (SALA_RESUME_GAP=2)"
# The load factor is read before and after the sweep (tests/lib.sh load_factor: 1 on a quiet box, +1 per whole multiple of the cores in the
# 1-minute load, at most 6) and the larger of the two scales the parallel-close bound below. FW, the resume wait, is scaled the same way: it
# only has to stay above the fake's 10 s life (a longer one costs nothing, the wait ends when the resume dies).
load_factor; LF0=$LOAD_FACTOR; FW=$(scale 20); out=$(SALA_HOLD_SETTLE=3 SALA_RESUME_GAP=2 SALA_RESUME_WAIT=$FW "$ROOT/bin/salamander" revive 2>&1) || true; echo "$out" | sed 's/^/    /'
kill "$WATCH" "$HW" "$GW" 2>/dev/null || true; WATCH=""; HW=""; GW=""
load_factor; LF1=$LOAD_FACTOR; LFM=$(( LF0 > LF1 ? LF0 : LF1 )); PB=$(( 6 * LFM ))   # PB: the parallel-close bound in seconds (6 s on a quiet box)
for n in a b c; do echo "$out" | grep -q "sala-test-$n:0: 9.9.9 → 9.9.9" && ok "$n relaunched (UPDATED row)" || bad "$n: no UPDATED row"; done
echo "$out" | grep -q 'sala-test-d:0: unsubmitted text at the prompt ("half a thought")' && ok "d skipped in phase 1 (draft)" || bad "d not skipped for its draft"
echo "$out" | grep -q "sala-test-e:0: claude didn't exit within ${SALA_EXIT_WAIT}s" && ok "e skipped in phase 2 (/exit never landed)" || bad "e: no 'didn't exit' row"
echo "$out" | grep -q "sala-test-f:0: 9.9.9 → " && bad "f counted as relaunched (an UPDATED row) although its resume died" || ok "f: no UPDATED row (its resume came up and died)"
echo "$out" | grep -q "sala-test-f:0: the resume started and died within ${FW}s" && ok "f skipped in phase 3 (the resume started, then died)" || bad "f: no 'started and died' row"
# THE PARALLEL-CLOSE BOUND (seen on main in CI: "exits spread 8.6s over 4 panes" on a box at load ~30 with 8 cores):
# the 4 /exit lines of a parallel close land within a moment of each other on a quiet box, but every pane's close_pane (its drain, idle
# re-check, pane_exit) is a process or ten that a loaded box schedules late, so the lines spread by the load, not by the sweep. The bound is
# 6 s times the load factor (PB, above): all is relative to the box, as the suites' other waits are (scale, waitfor). What it tells apart:
# a SEQUENTIAL close (SALA_SWEEP_JOBS=1) types the 4th pane's /exit only after the others are back at a shell AND after e, the pane that
# ignores /exit, has run its whole SALA_EXIT_WAIT loop (wait_for shell 2, three rounds of two 1 s sleeps: 6 s of sleeps that no load
# shortens), so its spread is at least 6 s plus one close per earlier pane: measured 14.9 s with SALA_SWEEP_JOBS=1 at load 10 on 8 cores
# (factor 2, bound 12 s: told apart; a parallel close spreads 0.1-0.5 s on a quiet or loaded box, against at least 6 s sequentially). The bound is not a proof at a high factor: from factor 3 on
# (18 s and more) a sequential spread, which the load stretches too, can stay under it, and there the check only catches a close that is
# slower than the load explains. The resume gap below and the hold-before-first-/exit check after it are lower bounds: load makes them
# larger, never fail them, so they are not scaled.
python3 - "$FAKE_LOG" "$PB" "$UC" "$UA" "$UB" <<'PY' && ok "resumes in order c a b, ≥1.5 s apart; the 4 exits within ${PB} s of each other (6 s × load factor $LFM; parallel close)" || bad "order/timing (see above)"
import sys
ev = [l.split() for l in open(sys.argv[1]) if l.strip()]
exits = sorted(float(t) for e, u, t in ev if e == "exit")
first_exit = exits[0]
resumes = [(float(t), u) for e, u, t in ev if e == "start" and float(t) > first_exit]
resumes.sort()
order = [u for _, u in resumes]
bound = float(sys.argv[2]); want = sys.argv[3:]
print("    exits spread %.1fs (bound %.0fs) over %d panes; resume order %s; gaps %s" % (exits[-1] - exits[0], bound, len(exits), [u[:1] for u in order], ["%.1f" % (b[0] - a[0]) for a, b in zip(resumes, resumes[1:])]))
assert len(exits) == 4, exits                       # a b c f left on /exit (e ignored it)
assert exits[-1] - exits[0] < bound, "exits were not parallel (spread over the load-scaled bound)"
assert order == want, order                  # least-recent first: c (300 s), a (200 s), b (100 s); f never started
assert all(b[0] - a[0] >= 1.5 for a, b in zip(resumes, resumes[1:])), "resume gap below SALA_RESUME_GAP"
PY
m=$(cat "$HOME/held.max" 2>/dev/null || echo 0); [ "$m" -ge 12 ] && ok "inbox: 6 panes held at once, a uuid and a name each (no hold lost to a parallel edit)" || bad "inbox: at most $m key(s) held at once, expected 12"
echo "$out" | grep -q 'phase 2 (hold): inbox held for 6 claude pane(s) before the first /exit' && ok "the sweep says it held the six eligible panes before the first /exit" || bad "no 'phase 2 (hold)' line for six panes"
# the gap, not only the order: written pane by pane right before each pane's own /exit, the last hold can still beat the first /exit
# by a race (0.87 s in a review); the settle between the last hold and the first /exit is what the fix adds (SALA_HOLD_SETTLE=3 above,
# 0.5 s of tolerance for the clock reads)
python3 - "$FAKE_LOG" "$HOME/holdclock.out" 2.5 <<'PY' && ok "inbox: all six holds landed at least the settle (3 s, minus 0.5 s) before the first /exit of any pane (the hold is not written pane by pane right before its own /exit)" || bad "a hold landed too close to, or after, a pane's /exit (see above)"
import sys
ev = [l.split() for l in open(sys.argv[1]) if l.strip()]
exits = sorted(float(t) for e, u, t in ev if e == "exit")
held = [l.split() for l in open(sys.argv[2]) if l.strip()]
all_held = [float(l[1]) for l in held if l[0] == "all-held"]
print("    all six held at %s; first /exit at %.6f%s" % (all_held, exits[0], "; margin %.3fs" % (exits[0] - all_held[0]) if all_held else ""))
assert all_held, "the six keys were never all in the hold file at once"
assert all_held[0] < exits[0], "a pane was exited before every hold was written"
assert exits[0] - all_held[0] >= float(sys.argv[3]), "the first /exit came %.3fs after the last hold, under the settle" % (exits[0] - all_held[0])
PY
grep -q never-held-was-held "$HOME/holdclock.out" && bad "inbox: d was held although phase 1 skipped it (a skipped pane is never held)" || ok "inbox: d, skipped in phase 1 (a draft), was never held"
echo "$out" | grep -q "sala-test-g:0: registry says 'busy'.*it was not idle once its inbox was held, /exit not sent" && ok "g deferred: a turn started after the hold, the re-check before the /exit saw it (a transient skip: retried later)" || bad "g: no 'not idle once its inbox was held' row"
# queued for retry, not only skipped: skip() puts a row on the retry list when transient_skip matches its text, and a recycle's or --only's sweep
# starts the retry worker for that list. The row printed above is the real one; the function is the real one, cut out of lib/revive.sh.
eval "$(grep '^transient_skip()' "$ROOT/lib/revive.sh")"
grow=$(echo "$out" | grep "sala-test-g:0: registry says 'busy'.*it was not idle once its inbox was held" | head -1)
[ -n "$grow" ] && transient_skip "$grow" && ok "g's skip row is transient, so g goes on the retry list (and a recycle starts its retry worker): the pane is not left behind for good" || bad "g's skip row is not transient: '$grow'"
grep -q "^exit $UG " "$FAKE_LOG" && bad "g got an /exit although a turn had started (it would have been killed)" || ok "g was not exited (/exit never typed over its turn)"
for u in $UA $UB $UC $UE $UF $UG; do grep -q "$u" "$HOLD/held-msg.txt" "$HOLD/held-hub.txt" 2>/dev/null && bad "inbox: $u still held after the sweep"; done
! grep -qE "$UE|$UG" "$HOLD/held-msg.txt" "$HOLD/held-hub.txt" 2>/dev/null && ok "inbox: the skipped panes' holds are cleared (e: its /exit never landed; g: not idle at the re-check), not left held for the 10-minute ledger sweep" || bad "inbox: e or g still held after the sweep"
[ -s "$HOME/.claude/salamander-inbox-holds.tsv" ] && bad "inbox ledger not empty: $(<"$HOME/.claude/salamander-inbox-holds.tsv")" || ok "inbox: every hold released (success paths and both failure paths), ledger empty"
[ -d "$HOME/.claude/salamander-inbox-holds.tsv.lock" ] && bad "inbox lock left behind" || ok "inbox lock released"
echo "== --only (one pane through the same phases)"
out=$(SALA_RECYCLE=1 SALA_NOTIFY_CMD=true "$ROOT/bin/salamander" revive --only sala-test-a 2>&1) || true   # as recycle's own sweep; echo "$out" | grep -E 'sala-test|phase' | sed 's/^/    /'
echo "$out" | grep -q 'sala-test-a:0: 9.9.9 → 9.9.9' && ok "--only relaunched a" || bad "--only: $out"
echo "$out" | grep -q 'sala-test-[b-f]' && bad "--only touched another pane" || ok "--only left the other panes alone"
echo "== a sweep killed in its hold settle releases the holds it took (no pane has exited yet: nothing to wait for the 10-minute ledger sweep to free)"
SALA_HOLD_SETTLE=30 "$ROOT/bin/salamander" revive >/dev/null 2>&1 & KP=$!
if waitfor 'grep -qxF "$UA" "$HOLD/held-msg.txt" 2>/dev/null' 30; then
    kill -TERM "$KP" 2>/dev/null; wait "$KP" 2>/dev/null || true
    ! grep -qE "$UA|$UB|$UC" "$HOLD/held-msg.txt" "$HOLD/held-hub.txt" 2>/dev/null && [ ! -s "$HOME/.claude/salamander-inbox-holds.tsv" ] && ok "TERM during the settle: the exit trap released every hold of the panes not yet exited (held lists and ledger empty)" || bad "holds left after TERM: $(cat "$HOLD/held-msg.txt" "$HOME/.claude/salamander-inbox-holds.tsv" 2>/dev/null)"
else kill -TERM "$KP" 2>/dev/null; wait "$KP" 2>/dev/null || true; bad "the second sweep never held a pane"; fi
echo "== SALA_POST_RECYCLE_CMD: fired once at the end of a recycle's driver, detached, with KIND/STARTED/RESULT/SKIPPED"
if command -v setsid >/dev/null 2>&1; then   # the recycle driver is a `setsid bash -c` (no setsid(1) on macOS: no driver there)
PR="$HOME/post-recycle.txt"
export SALA_POST_RECYCLE_CMD="printf '%s|%s|%s|%s\n' \"\$SALA_RECYCLE_KIND\" \"\$SALA_RECYCLE_STARTED\" \"\$SALA_RECYCLE_RESULT\" \"\$SALA_RECYCLE_SKIPPED\" >> $PR; echo stub-ran"
wait_pr() { local i=0 lim; lim=$(( $(scale 60) * 2 )); while [ "$(grep -c . "$PR" 2>/dev/null || echo 0)" -lt "$1" ] && [ "$i" -lt "$lim" ]; do sleep 0.5; i=$((i+1)); done; }
wait_lock() { lock_wait "$HOME/.claude/salamander-recycle.lock" 30; }
S=$(date +%s); out=$("$ROOT/bin/salamander" recycle --force --only sala-test-a 2>&1) || bad "recycle (a) did not start: $out"
wait_pr 1; wait_lock
IFS='|' read -r k st r sk <<< "$(sed -n 1p "$PR" 2>/dev/null)"
[ "$k" = recycle ] && ok "clean recycle: KIND=recycle" || bad "clean recycle: KIND='$k' ($(slurp "$PR"))"
case "$st" in ''|*[!0-9]*) bad "STARTED not numeric: '$st'";; *) [ "$st" -ge "$S" ] && [ "$st" -le "$(date +%s)" ] && ok "STARTED=$st (epoch, within the run)" || bad "STARTED=$st outside the run (from $S)";; esac
[ "$r" = ok ] && [ -z "$sk" ] && ok "clean recycle: RESULT=ok, SKIPPED empty" || bad "clean recycle: RESULT='$r' SKIPPED='$sk'"
out=$("$ROOT/bin/salamander" recycle --force --only sala-test-d 2>&1) || bad "recycle (d) did not start: $out"
sleep 4; wait_lock
[ "$(grep -c . "$PR")" = 1 ] && ok "a skipped pane: its flag stays open, so no second call (one call per CLEARED flag; tests/flags.sh covers the partial clear)" || bad "skipped pane fired a call while its flag is open: $(slurp "$PR")"
for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done   # d's retry worker: not this test's business
out=$("$ROOT/bin/salamander" recycle --force --dry-run --only sala-test-a 2>&1) || true; sleep 3; wait_lock
[ "$(grep -c . "$PR")" = 1 ] && ok "a dry-run recycle does not fire it" || bad "dry run fired it: $(<"$PR")"
SALA_RECYCLE=1 "$ROOT/bin/salamander" revive --only sala-test-a >/dev/null 2>&1 || true; sleep 2
[ "$(grep -c . "$PR")" = 1 ] && ok "a sweep outside the driver (revive --only) does not fire it" || bad "revive --only fired it: $(<"$PR")"
unset SALA_POST_RECYCLE_CMD
else
    echo "  skip no setsid(1) here — the recycle driver cannot start on this system"
fi
echo "== recycle lock (flock): a second driver is refused with the holder line; the lock dies with the driver"
LOCK="$HOME/.claude/salamander-recycle.lock"
if command -v flock >/dev/null 2>&1; then
    # recycle detaches a driver and exits at once; the lock must outlive the invoker (fd 9 is the driver's now)
    out=$(SALA_LOCK_WHO=test-driver "$ROOT/bin/salamander" recycle --force 2>&1) || bad "recycle did not start: $out"
    echo "$out" | grep -q 'recycle started as a detached driver' && ok "recycle #1 detached" || bad "recycle #1: $out"
    sleep 1; DRIVER=$(cut -f1 "$LOCK" 2>/dev/null || echo "")
    kill -0 "$DRIVER" 2>/dev/null && ok "holder line names the detached driver (pid $DRIVER, alive)" || bad "holder pid '$DRIVER' is not a live process"
    set +e; out=$(SALA_LOCK_WHO=second "$ROOT/bin/salamander" recycle --force 2>&1); rc=$?; set -e
    [ "$rc" = 75 ] && ok "recycle #2 refused with exit 75" || bad "recycle #2: rc=$rc: $out"
    set +e; out=$("$ROOT/bin/salamander" revive --only sala-test-a 2>&1); rc=$?; set -e
    [ "$rc" = 75 ] && echo "$out" | grep -q 'already running' && ok "a direct revive is refused too" || bad "direct revive while locked: rc=$rc: $out"
    set +e; out=$("$ROOT/bin/salamander" revive --save-map 2>&1); rc=$?; set -e
    [ "$rc" = 0 ] && ok "--save-map never takes the lock" || bad "--save-map while locked: rc=$rc: $out"
    kill -TERM -- -"$DRIVER" 2>/dev/null || true
    # the kernel frees the lock once the killed session is gone; on a loaded box that takes longer than a fixed sleep, so poll (up to ~10 s)
    freed=""; for _ in $(seq 100); do if flock -n "$LOCK" true; then freed=1; break; fi; sleep 0.1; done
    if [ -n "$freed" ]; then ok "lock free right after the driver's session was killed (kernel-released, no stale lock)"; else bad "lock still held after killing the driver"; fi
    DRIVER=""
    set +e; out=$("$ROOT/bin/salamander" revive --dry-run 2>&1); rc=$?; set -e
    [ "$rc" = 0 ] && ok "and a new run goes through" || bad "after the kill: rc=$rc: $out"
else
    echo "  skip no flock(1) here — the lock is not built on this system (the taker warns once)"
fi
[ "$fail" = 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
