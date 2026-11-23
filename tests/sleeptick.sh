#!/usr/bin/env bash
# Sleeping sessions, stage 5 (lib/wrapup.sh sleep_tick, wake_tick, sleep_candidates; lib/sleep.sh --candidates; lib/wake.sh's wake stamp; lib/watch.sh's wiring):
# the watch's own sleep passes. sleep_tick is OFF BY DEFAULT (SALA_IDLE_SLEEP=on turns it on) and puts to sleep, through `sala sleep`, the sessions sleep_ready
# accepts, the longest idle first, at most SALA_SLEEP_PER_TICK per run; wake_tick is always on and wakes, through `sala wake`, a sleeper with a stackshot message
# line waiting. What is checked, on a private tmux server with the compiled fake claude:
#  - `sala config` prints SALA_IDLE_SLEEP (off unless set), SALA_SLEEP_AFTER and SALA_SLEEP_PER_TICK;
#  - off (the default): a full watch tick and `watch --sleep` put nothing to sleep, log nothing and write no marker, however idle the sessions are;
#  - the candidates: `sala sleep --candidates` and `watch --sleep --dry-run` print the same list, on or off (off says so), longest idle first, with the first
#    SALA_SLEEP_PER_TICK marked as the ones the next run would put to sleep; a front agent, a session idle only a minute, one with a scheduled job, one the pane map
#    does not know and one woken lately are not on it; nothing is changed;
#  - on: SALA_SLEEP_PER_TICK=0 sleeps nothing; a full tick puts exactly the first three of the list to sleep (marker, claude ended, tmux session and pane-map row
#    kept, one watch-log line each), the next run the other two, and what the candidates listed is exactly what slept; the skipped ones keep running;
#  - the wake stamp: a session woken lately is never put to sleep again inside SALA_SLEEP_AFTER, whatever its registry row says; with the stamp aged it is a
#    candidate again;
#  - the wake tick (SALA_IDLE_SLEEP off): a sleeper with a message line waiting in the stackshot inbox (a held key too) is woken, one without a line stays asleep, a
#    notice wakes nothing, a session that is not asleep is untouched, at most SALA_WAKE_PER_RUN per run (the rest on the next), one watch-log line per wake naming
#    the session and `inbox line waiting`, `watch --wake --dry-run` says whom it would wake and changes nothing, and the inbox files are byte for byte as before;
#  - the routing fields: a line for `<name>-extra`, or one whose text only mentions the name or the conversation id, wakes nobody; a line routed by `to`/`name` or by
#    `uuid` does;
#  - the retry backoff: with a cap of one the wake and the sleep previews skip a session in backoff and name the one the real run acts on, and the real run does the same;
#  - the wake re-checks the pane-map row: a candidate whose id is no longer the row's is skipped with no wake and no failure stamp.
# SAFETY: every kill is a `kill -9` of ONE pid whose /proc/<pid>/exe is this suite's own compiled fake and whose environment names this suite's temporary HOME
# (kill_fake_claude); the tmux server is a private socket (tmux -L sala-sleeptick-<pid> -f /dev/null, SALA_TMUX_SOCKET pointing at it), HOME is a mktemp -d
# held with flock, the claude is tests/fake-claude.c; no real pane, server, ~/.claude or claude process is read or touched. Posts go to a file.
# Usage: bash tests/sleeptick.sh   (exit 0 = pass)
set -u
unset TMUX TMUX_PANE XDG_STATE_HOME SALA_MASTER SALA_SET SALA_SET_SELF SALA_RECYCLE SALA_RETRY_WORKER SALA_LOCK_WHO SALA_LOCK_WAIT SALA_RELAUNCH_KIND SALA_SLEEP_DIR \
      SALA_FLEET_HOSTS SALA_CGROUP_FILE SALA_OP_QUEUE SALA_NO_RELAUNCH SALA_BOOT_ID SALA_CONFIG SALA_BARE_REVIVE SALA_IDLE_WRAPUP SALA_SESSION_ID SALA_STACKSHOT_INBOX \
      SALA_STACKSHOT_DIR SALA_STACKSHOT_CLIENT SALA_AGENT_CHECK_SCRIPT SALA_PROJECT_RECORD SALA_OP_ID SALA_OP_FROM SALA_OP_REASON_FROM \
      SALA_IDLE_SLEEP SALA_SLEEP_AFTER SALA_SLEEP_PER_TICK SALA_WAKE_PER_RUN SALA_SLEEP_RETRY SALA_WAKE_RETRY
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
SANDBOX=""; SOCK="sala-sleeptick-$$"; T="tmux -L $SOCK -f /dev/null"
cleanup() {
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    [ -z "$SANDBOX" ] || { kill_fake_claude "$FAKEBIN"; exec 8<&-; rm -rf "$SANDBOX" 2>/dev/null; }
    true
}; trap cleanup EXIT   # set before the temp folder exists
SANDBOX=$(mktemp -d); export HOME=$SANDBOX SALA_TZ=Etc/UTC SALA_CONFIG=/dev/null
case "$HOME" in /tmp/*|"${TMPDIR:-/tmp}"/*) ;; *) echo "sleeptick: HOME is not a temporary directory ($HOME) - refusing to run"; exit 1;; esac
exec 8< "$SANDBOX"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
as_op_unit   # the guarded verbs this suite runs itself stand for the queue's runner (tests/lib.sh, 5)
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$HOME/.claude-team" "$HOME/work"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
printf '{"fake":true}\n' > "$HOME/.claude-team/.credentials.json"
FAKEBIN="$HOME/.local/share/claude/versions/9.9.9"
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$FAKEBIN" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }
ln -s "$FAKEBIN" "$HOME/.local/bin/claude"
printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/systemd-run"
cat > "$HOME/.local/bin/systemctl" <<'EOF'
#!/bin/bash
case "$*" in *is-active*) exit 3 ;; *is-system-running*) echo running; exit 0 ;; *cat*tmux.service*) exit 1 ;; *) exit 0 ;; esac
EOF
chmod +x "$HOME/.local/bin/systemd-run" "$HOME/.local/bin/systemctl"
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log" FAKE_TYPED_LOG="$HOME/typed.log"
POSTS="$HOME/posts.txt"; : > "$POSTS"; export SALA_NOTIFY_CMD="{ cat; echo '%%'; } >> $POSTS"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off SALA_SNAPSHOT_CMD="touch $HOME/snap.done"
export SALA_LIMIT_ALERT=off SALA_LIMIT_RESUME=off SALA_STUCK_POST=off   # the other watches: not under test
export SALA_OP_STUCK=off SALA_OP_QUEUE=off SALA_BARE_REVIVE=off   # a queued marker is written and nothing starts it; no bare-pane heal runs beside the passes under test
SALA="$ROOT/bin/salamander"
export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's
case "$SOCK" in sala-sleeptick-*) ;; *) echo "sleeptick: not a private socket - refusing to run"; exit 1;; esac
WLOG="$HOME/.claude/salamander-watch.log"; : > "$WLOG"
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux    # literal socket: the children run set -u
$T new-session -d -s sala-test-keep -x 200 -y 50 -c "$HOME"; $T set -g exit-empty off   # a server that outlives its last fake
. "$ROOT/lib/common.sh"; . "$ROOT/lib/wrapup.sh"
MAP="$SALA_SIDECAR"
now0=$(date +%s); START=$((now0 - 10800)); TURN=$((now0 - 7200))   # the fakes' process started 3 h ago; their last turn ended 2 h ago
mk() {  # <suffix> <uuid n> [tmux -e options…] → a fake claude in sala-test-<suffix>
    local n="$1" u; u=$(uuid "$2"); shift 2
    $T new-session -d -s "sala-test-$n" -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="sala-test-$n" -e FAKE_LOG="$FAKE_LOG" -e FAKE_TYPED_LOG="$FAKE_TYPED_LOG" \
        -e FAKE_STARTED_AT="$START" -e FAKE_TURN_MS=1500 "$@"
    $T send-keys -t "sala-test-$n" 'claude' Enter
}
hasclaude() { local pp; pp=$($T list-panes -t "=sala-test-$1" -F '#{pane_pid}' 2>/dev/null | head -1); [ -n "$pp" ] && [ -n "$(claude_pid_under "$pp" 2>/dev/null)" ]; }   # <suffix>
n_starts() { starts "$(uuid "$1")"; }
row() { awk -F'\t' -v s="$1" '$1==s' "$MAP" 2>/dev/null; }
run() { OUT=$("$SALA" "$@" 2>&1); RC=$?; }   # → OUT, RC (stderr in OUT)
tick() { "$SALA" watch >/dev/null 2>&1; }
stoprec() { mkdir -p "$SALA_BUSY_DIR"; printf 'id=t%s\nepoch=%s\nseen=\nseen_status=idle\ntasks=0\ncrons=%s\n' "$1" "$TURN" "${2:-0}" > "$SALA_BUSY_DIR/$(uuid "$1")"; }   # <uuid n> [crons]: the Stop hook's record of a finished turn
wlogn() { grep -c -- "$1" "$WLOG" 2>/dev/null || true; }
names() { printf '%s\n' "$1" | awk -F': idle [0-9]+ min' 'NF > 1 {print $1}' | tr '\n' ' ' | sed 's/ $//'; }   # the session names of a candidates listing, in order
nmarkers() { ls "$SALA_SLEEP_DIR" 2>/dev/null | grep -c . || true; }
asleep() { [ -f "$SALA_SLEEP_DIR/$(uuid "$1")" ]; }   # <uuid n>
inboxsum() { find "$SALA_STACKSHOT_INBOX" -type f 2>/dev/null | sort | xargs -r cat | cksum; }
export SALA_SLEEP_DIR   # the children read the same directory (its default under SALA_STATE_DIR)

echo "== setup: private tmux server, isolated HOME, the compiled fake claude (r1..r5: idle and ready, r1 the longest idle · n: idle a minute · x-main: a front agent · c: a scheduled job · w: woken lately · u: no pane-map row)"
mk r1 21 -e FAKE_IDLE_AGE=4500; mk r2 22 -e FAKE_IDLE_AGE=4400; mk r3 23 -e FAKE_IDLE_AGE=4300; mk r4 24 -e FAKE_IDLE_AGE=4200; mk r5 25 -e FAKE_IDLE_AGE=4100
mk n 26 -e FAKE_IDLE_AGE=60; mk x-main 27 -e FAKE_IDLE_AGE=4000; mk c 28 -e FAKE_IDLE_AGE=4000; mk w 29 -e FAKE_IDLE_AGE=4000; mk u 30 -e FAKE_IDLE_AGE=4000
fake_up sala-test-r1 sala-test-r2 sala-test-r3 sala-test-r4 sala-test-r5 sala-test-n sala-test-x-main sala-test-c sala-test-w sala-test-u || exit 1
for n in r1 r2 r3 r4 r5 n x-main c w; do "$SALA" adopt "sala-test-$n" >/dev/null 2>&1 || bad "adopt sala-test-$n failed"; done   # u stays out of the pane map on purpose
for u in 21 22 23 24 25 26 27 29; do stoprec "$u"; done; stoprec 28 1
[ "$($T display -p '#{socket_path}')" = "$SALA_TMUX_SOCKET" ] && ok "the tmux server is the suite's private socket ($SOCK)" || bad "socket: $($T display -p '#{socket_path}')"
UW=$(uuid 29); mkdir -p "$SALA_SLEEP_DIR.woke"; printf '%s\n' "$(date +%s)" > "$SALA_SLEEP_DIR.woke/$UW"   # w was woken just now: a wake stamp (what `sala wake` writes)
rows0=$(for n in r1 r2 r3 r4 r5; do row "sala-test-$n"; done)

echo "== sala config prints the knobs; SALA_IDLE_SLEEP is off unless it is set"
run config
has "$OUT" "SALA_IDLE_SLEEP" && echo "$OUT" | grep -qE '^SALA_IDLE_SLEEP +off$' && echo "$OUT" | grep -qE '^SALA_SLEEP_PER_TICK +3$' && echo "$OUT" | grep -qE '^SALA_SLEEP_AFTER +3600$' && ok "config: SALA_IDLE_SLEEP off, SALA_SLEEP_PER_TICK 3, SALA_SLEEP_AFTER 3600" || bad "config: $(echo "$OUT" | grep SLEEP)"
OUT=$(SALA_IDLE_SLEEP=on SALA_SLEEP_PER_TICK=2 "$SALA" config 2>&1); echo "$OUT" | grep -qE '^SALA_IDLE_SLEEP +on$' && echo "$OUT" | grep -qE '^SALA_SLEEP_PER_TICK +2$' && ok "config: the values set in the environment or the config are the ones printed" || bad "config on: $(echo "$OUT" | grep SLEEP)"
grep -q '^#SALA_IDLE_SLEEP=off' "$ROOT/config.example" && ok "config.example documents SALA_IDLE_SLEEP, off" || bad "config.example lacks SALA_IDLE_SLEEP"

echo "== OFF (the default): a full tick and watch --sleep put nothing to sleep, however idle the sessions are"
tick; "$SALA" watch --sleep >/dev/null 2>&1; SALA_IDLE_SLEEP=maybe tick; SALA_IDLE_SLEEP=off "$SALA" watch --sleep >/dev/null 2>&1
[ "$(nmarkers)" = 0 ] && ok "no marker was written" || bad "markers: $(ls "$SALA_SLEEP_DIR")"
ALLUP=1; for n in r1 r2 r3 r4 r5 n x-main c w u; do hasclaude "$n" || { ALLUP=0; bad "$n lost its claude with the tick off"; }; done; [ "$ALLUP" = 1 ] && ok "every claude still runs (off, unset, garbage and =off alike)"
[ "$(wlogn 'sleep:')" = 0 ] && ok "the watch log has no 'sleep:' line" || bad "log: $(grep 'sleep:' "$WLOG")"

echo "== the candidates: the same list from sleep --candidates and watch --sleep --dry-run, on or off, nothing changed"
run sleep --candidates; CAND=$OUT; CRC=$RC
[ "$CRC" = 0 ] && has "$CAND" "SALA_IDLE_SLEEP is off" && ok "sleep --candidates: exit 0, says the tick is off" || bad "candidates: rc=$CRC — $CAND"
LIST=$(names "$CAND")
[ "$LIST" = "sala-test-r1 sala-test-r2 sala-test-r3 sala-test-r4 sala-test-r5" ] && ok "the list is r1..r5, the longest idle first; not n (idle a minute), x-main (a front agent), c (a scheduled job), w (woken lately) or u (not in the pane map)" || bad "list: '$LIST' — $CAND"
[ "$(grep -c 'would be put to sleep' <<< "$CAND")" = 3 ] && [ "$(grep -c 'waits for a later run' <<< "$CAND")" = 2 ] && has "$(grep sala-test-r3 <<< "$CAND")" "would be put to sleep" && has "$(grep sala-test-r4 <<< "$CAND")" "waits for a later run" && ok "the first three are marked as the next run's, the other two wait (at most 3 per run)" || bad "marks: $CAND"
DRY=$("$SALA" watch --sleep --dry-run 2>&1); [ "$(names "$DRY")" = "$LIST" ] && has "$DRY" "SALA_IDLE_SLEEP is off" && ok "watch --sleep --dry-run (off): the same list" || bad "watch --sleep --dry-run: $DRY"
DRYON=$(SALA_IDLE_SLEEP=on "$SALA" watch --sleep --dry-run 2>&1); [ "$(names "$DRYON")" = "$LIST" ] && ! has "$DRYON" "is off" && ok "watch --sleep --dry-run (on): the same list, no 'off' line" || bad "dry on: $DRYON"
OUT=$(SALA_SLEEP_PER_TICK=1 "$SALA" sleep --candidates 2>&1); [ "$(grep -c 'would be put to sleep' <<< "$OUT")" = 1 ] && [ "$(names "$OUT")" = "$LIST" ] && ok "the cap is the knob: with SALA_SLEEP_PER_TICK=1 one is marked, the list is the same" || bad "cap 1: $OUT"
run sleep --candidates sala-test-r1; [ "$RC" != 0 ] && has "$OUT" "takes nothing else" && ok "--candidates with a name: refused" || bad "candidates + name: rc=$RC — $OUT"
[ "$(nmarkers)" = 0 ] && [ "$(for n in r1 r2 r3 r4 r5; do row "sala-test-$n"; done)" = "$rows0" ] && ok "nothing changed: no marker, the pane map as before" || bad "state changed"

echo "== ON: SALA_SLEEP_PER_TICK=0 sleeps nothing; a full tick puts the first three to sleep"
SALA_IDLE_SLEEP=on SALA_SLEEP_PER_TICK=0 "$SALA" watch --sleep >/dev/null 2>&1
[ "$(nmarkers)" = 0 ] && ok "a cap of 0: nothing slept" || bad "cap 0 slept: $(ls "$SALA_SLEEP_DIR")"
SALA_IDLE_SLEEP=on tick
asleep 21 && asleep 22 && asleep 23 && [ "$(nmarkers)" = 3 ] && ok "r1, r2, r3 (the three longest idle) have a marker, and no other session has" || bad "markers: $(ls "$SALA_SLEEP_DIR")"
! hasclaude r1 && ! hasclaude r2 && ! hasclaude r3 && ok "their claude has ended" || bad "a claude still runs in r1, r2 or r3"
{ $T has-session -t "=sala-test-r1" && $T has-session -t "=sala-test-r2" && $T has-session -t "=sala-test-r3"; } 2>/dev/null && [ "$(for n in r1 r2 r3 r4 r5; do row "sala-test-$n"; done)" = "$rows0" ] && ok "their tmux sessions and the pane-map rows are kept, byte for byte" || bad "sessions or rows changed"
hasclaude r4 && hasclaude r5 && ok "r4 and r5 wait for the next run: still running" || bad "r4 or r5 lost its claude"
[ "$(wlogn 'sleep: put sala-test-r[123] to sleep')" = 3 ] && ok "one watch-log line per slept session ('sleep: put … to sleep (idle N min)')" || bad "log: $(grep 'sleep:' "$WLOG")"
hasclaude n && hasclaude x-main && hasclaude c && hasclaude w && hasclaude u && ok "n, x-main, c, w and u keep running" || bad "a skipped session lost its claude"
SLEPT=$(names "$("$SALA" sleep --candidates 2>&1)")
[ "$SLEPT" = "sala-test-r4 sala-test-r5" ] && ok "the candidates now list the two left" || bad "left: '$SLEPT'"
SALA_IDLE_SLEEP=on "$SALA" watch --sleep >/dev/null 2>&1
asleep 24 && asleep 25 && [ "$(nmarkers)" = 5 ] && ok "the next run puts r4 and r5 to sleep: five sleepers, exactly what the candidates listed" || bad "markers: $(ls "$SALA_SLEEP_DIR")"
OUT=$("$SALA" sleep --candidates 2>&1); has "$OUT" "no session is ready to sleep" && ok "the candidates are empty now" || bad "candidates after: $OUT"
[ "$(wlogn 'sleep: put ')" = 5 ] && [ "$(wlogn 'not put to sleep')" = 0 ] && ok "five 'put to sleep' lines and no failure line" || bad "log: $(grep 'sleep:' "$WLOG")"
hasclaude n && hasclaude x-main && hasclaude c && hasclaude w && hasclaude u && ok "after both runs the front agent, the busy, the minute-idle, the lately woken and the unmapped sessions still run" || bad "a skipped session lost its claude"

echo "== the wake stamp: a woken session is not put to sleep again inside SALA_SLEEP_AFTER, and is a candidate again with the stamp aged"
r1s=$(n_starts 21)
run wake sala-test-r1
[ "$RC" = 0 ] && has "$OUT" "awake" && ok "wake r1: awake" || bad "wake r1: rc=$RC — $OUT"
waitfor 'hasclaude r1' 40; hasclaude r1 && [ "$(n_starts 21)" = "$((r1s + 1))" ] && ok "r1 runs again on its own conversation" || bad "r1 after the wake: starts $(n_starts 21)/$r1s"
[ -f "$SALA_SLEEP_DIR.woke/$(uuid 21)" ] && [[ $(<"$SALA_SLEEP_DIR.woke/$(uuid 21)") =~ ^[0-9]{10}$ ]] && ok "the wake wrote a wake stamp (the epoch second) beside the marker folder, not in it" || bad "stamp: $(ls -A "$SALA_SLEEP_DIR.woke")"
[ -z "$(ls -A "$SALA_SLEEP_DIR" | grep -v "$(uuid 22)\|$(uuid 23)\|$(uuid 24)\|$(uuid 25)")" ] && ok "the marker folder holds markers only" || bad "marker folder: $(ls -A "$SALA_SLEEP_DIR")"
OUT=$("$SALA" sleep --candidates 2>&1); ! has "$OUT" "sala-test-r1" && ok "r1 (idle on its registry row, woken lately) is not a candidate" || bad "r1 listed: $OUT"
SALA_IDLE_SLEEP=on "$SALA" watch --sleep >/dev/null 2>&1; sleep 1
hasclaude r1 && ! asleep 21 && ok "a tick with the tick on leaves r1 awake" || bad "r1 was put to sleep again"
printf '%s\n' "$(( $(date +%s) - 4000 ))" > "$SALA_SLEEP_DIR.woke/$(uuid 21)"
OUT=$("$SALA" sleep --candidates 2>&1); [ "$(names "$OUT")" = "sala-test-r1" ] && ok "with the stamp aged past SALA_SLEEP_AFTER r1 is a candidate again (the stamp was what held it back)" || bad "r1 after aging: $OUT"
SALA_IDLE_SLEEP=on "$SALA" watch --sleep >/dev/null 2>&1
asleep 21 && ok "and the tick puts it to sleep" || bad "r1 not asleep after the stamp aged"

echo "== the wake tick (always on): a message line wakes a sleeper, a notice does not, the cap holds, the inbox is untouched"
export SALA_STACKSHOT_INBOX="$HOME/inbox"; mkdir -p "$SALA_STACKSHOT_INBOX/hub" "$SALA_STACKSHOT_INBOX/msg" "$SALA_INBOX_HOLD_DIR"
printf '{"to":"sala-test-r2","text":"hello r2"}\n' > "$SALA_STACKSHOT_INBOX/hub/m2.json"
printf '{"to":"sala-test-r3","text":"hello r3"}\n' > "$SALA_STACKSHOT_INBOX/msg/m3.json"
printf '{"to":"sala-test-r4","text":"hello r4"}\n' > "$SALA_STACKSHOT_INBOX/msg/m4.json"
printf '{"to":"sala-test-n","text":"hello n"}\n' > "$SALA_STACKSHOT_INBOX/hub/mn.json"   # n is awake: a line for it wakes nothing
inbox_hold "$(uuid 23)" sala-test-r3   # a held key: the line still waits, so it still wakes the session (the revive takes and releases its own hold)
"$SALA" notice add "a notice for everyone, not a message line" --from sleeptick >/dev/null 2>&1
SUM0=$(inboxsum); r2s=$(n_starts 22); r3s=$(n_starts 23); r4s=$(n_starts 24); r5s=$(n_starts 25); ns=$(n_starts 26)
export SALA_WAKE_PER_RUN=2
DRY=$("$SALA" watch --wake --dry-run 2>&1)
has "$(grep sala-test-r2 <<< "$DRY")" "would be woken" && has "$(grep sala-test-r3 <<< "$DRY")" "would be woken" && has "$(grep sala-test-r4 <<< "$DRY")" "waits for a later run" && ! has "$DRY" "sala-test-r5" && ! has "$DRY" "sala-test-n" && ok "watch --wake --dry-run: r2 and r3 would be woken, r4 waits (cap 2), r5 (no line) and n (awake) are not named" || bad "wake dry: $DRY"
asleep 22 && asleep 23 && [ "$(inboxsum)" = "$SUM0" ] && [ "$(wlogn 'wake:')" = 0 ] && ok "the dry run changed nothing: still asleep, inbox as before, nothing logged" || bad "dry run changed state"
[ "${SALA_IDLE_SLEEP:-off}" = off ] && ok "(the tick is off for these runs: SALA_IDLE_SLEEP is the default)" || bad "SALA_IDLE_SLEEP is $SALA_IDLE_SLEEP"
tick
waitfor 'hasclaude r2 && hasclaude r3' 60
hasclaude r2 && hasclaude r3 && ! asleep 22 && ! asleep 23 && [ "$(n_starts 22)" = "$((r2s + 1))" ] && [ "$(n_starts 23)" = "$((r3s + 1))" ] && ok "a full tick (the tick off) woke r2 and r3, each once, on their own conversations; r3's key was held and it woke all the same" || bad "r2/r3: starts $(n_starts 22)/$r2s $(n_starts 23)/$r3s; log: $(grep 'wake:' "$WLOG")"
asleep 24 && ! hasclaude r4 && ok "r4 (a line, but over the cap of 2) is still asleep" || bad "r4 woke past the cap"
[ "$(wlogn 'wake: woke sala-test-r2 — inbox line waiting')" = 1 ] && [ "$(wlogn 'wake: woke sala-test-r3 — inbox line waiting')" = 1 ] && [ "$(wlogn 'wake: woke ')" = 2 ] && ok "one watch-log line per wake, naming the session and 'inbox line waiting'" || bad "log: $(grep 'wake:' "$WLOG")"
asleep 25 && asleep 21 && ! hasclaude r5 && ! hasclaude r1 && [ "$(n_starts 25)" = "$r5s" ] && ok "r5 and r1 (no line, one notice for everyone) are still asleep: a notice wakes nothing" || bad "r5/r1 woke"
hasclaude n && [ "$(n_starts 26)" = "$ns" ] && ok "n (not asleep) is untouched" || bad "n: starts $(n_starts 26)/$ns"
[ "$(inboxsum)" = "$SUM0" ] && [ -f "$SALA_STACKSHOT_INBOX/hub/m2.json" ] && [ -f "$SALA_STACKSHOT_INBOX/msg/m3.json" ] && ok "the message lines are still in the inbox, byte for byte" || bad "the inbox changed"
tick
waitfor 'hasclaude r4' 60
hasclaude r4 && ! asleep 24 && [ "$(n_starts 24)" = "$((r4s + 1))" ] && [ "$(wlogn 'wake: woke ')" = 3 ] && ok "the next run wakes r4 (the cap is per run)" || bad "r4: starts $(n_starts 24)/$r4s; log: $(grep 'wake:' "$WLOG")"
tick; [ "$(wlogn 'wake: woke ')" = 3 ] && asleep 25 && asleep 21 && ok "a further tick wakes nobody more (r5 and r1 have no line)" || bad "extra wake: $(grep 'wake:' "$WLOG")"
SALA_IDLE_SLEEP=on tick; sleep 1
hasclaude r2 && hasclaude r3 && hasclaude r4 && ok "with the tick on, the three just woken are not put to sleep again" || bad "a woken session slept again"

echo "== the routing fields: a line for a longer name, or a text that only mentions the name, wakes nobody; a line routed by name or by conversation id does"
# r5 and r1 sleep. The lines below are shaped as stackshot writes them: id, ts, src, to, uuid, name, pid, text, from.
rm -f "$SALA_STACKSHOT_INBOX"/hub/*.json "$SALA_STACKSHOT_INBOX"/msg/*.json
printf '{"id":"a1","src":"msg","to":"sala-test-r5-extra","uuid":"","name":"sala-test-r5-extra","pid":"","text":"for the longer name","from":"x"}\n' > "$SALA_STACKSHOT_INBOX/msg/e1.json"
printf '{"id":"a2","src":"hub","to":"sala-test-n","uuid":"%s","name":"sala-test-n","pid":"","text":"please tell sala-test-r5 and sala-test-r1, also %s","from":"x"}\n' "$(uuid 26)" "$(uuid 21)" > "$SALA_STACKSHOT_INBOX/hub/e2.json"
SUM1=$(inboxsum); r5s=$(n_starts 25); r1s=$(n_starts 21)
DRY=$("$SALA" watch --wake --dry-run 2>&1)
! has "$DRY" "sala-test-r5" && ! has "$DRY" "sala-test-r1" && ok "watch --wake --dry-run: a line for sala-test-r5-extra and a text that only mentions r5, r1 and r1's id name neither" || bad "wake dry (negatives): $DRY"
tick; sleep 1
asleep 25 && asleep 21 && ! hasclaude r5 && ! hasclaude r1 && [ "$(n_starts 25)" = "$r5s" ] && [ "$(n_starts 21)" = "$r1s" ] && ok "a full tick woke neither r5 nor r1" || bad "a negative line woke a sleeper"
printf '{"id":"a3","src":"msg","to":"sala-test-r5","uuid":"%s","name":"sala-test-r5","pid":"","text":"for r5","from":"x"}\n' "$(uuid 25)" > "$SALA_STACKSHOT_INBOX/msg/e3.json"
DRY=$("$SALA" watch --wake --dry-run 2>&1)
has "$(grep sala-test-r5 <<< "$DRY")" "would be woken" && ! has "$DRY" "sala-test-r1" && ok "watch --wake --dry-run: a line routed to sala-test-r5 wakes it, and still not r1" || bad "wake dry (r5): $DRY"
printf '{"id":"a4","src":"hub","to":"somebody-else","uuid":"%s","name":"somebody-else","pid":"","text":"for the conversation of r1","from":"x"}\n' "$(uuid 21)" > "$SALA_STACKSHOT_INBOX/hub/e4.json"
DRY=$("$SALA" watch --wake --dry-run 2>&1)
has "$(grep sala-test-r1 <<< "$DRY")" "would be woken" && ok "watch --wake --dry-run: a line routed to r1's conversation id wakes r1 whatever name it carries" || bad "wake dry (r1): $DRY"
tick
waitfor 'hasclaude r5 && hasclaude r1' 60
hasclaude r5 && hasclaude r1 && [ "$(n_starts 25)" = "$((r5s + 1))" ] && [ "$(n_starts 21)" = "$((r1s + 1))" ] && ok "a full tick woke r5 (routed by name) and r1 (routed by conversation id), each once" || bad "r5/r1: starts $(n_starts 25)/$r5s $(n_starts 21)/$r1s; log: $(grep 'wake:' "$WLOG")"
[ -f "$SALA_STACKSHOT_INBOX/msg/e1.json" ] && [ -f "$SALA_STACKSHOT_INBOX/hub/e2.json" ] && ok "the lines that were not for them are still in the inbox" || bad "an inbox line is gone"

echo "== the retry backoff: the previews skip a session the real run skips, so with a cap of one they name the one the run acts on"
# every woken session (r1..r5) is awake again with a wake stamp; age the stamps, drop the lines that woke them (the fake pane never takes a line), put r1 and r5 to
# sleep again and give each a line. r1 comes before r5 in the marker folder (uuid 21 < 25), so it is the first wake candidate.
rm -f "$SALA_STACKSHOT_INBOX/msg/e3.json" "$SALA_STACKSHOT_INBOX/hub/e4.json"
for n in 21 22 23 24 25; do printf '%s\n' "$(( $(date +%s) - 4000 ))" > "$SALA_SLEEP_DIR.woke/$(uuid $n)"; done
"$SALA" sleep sala-test-r1 sala-test-r5 >/dev/null 2>&1
asleep 21 && asleep 25 && ok "r1 and r5 are asleep again" || bad "r1/r5 not asleep: $(ls "$SALA_SLEEP_DIR")"
printf '{"id":"b1","src":"msg","to":"sala-test-r1","uuid":"%s","name":"sala-test-r1","pid":"","text":"for r1","from":"x"}\n' "$(uuid 21)" > "$SALA_STACKSHOT_INBOX/msg/e5.json"
printf '{"id":"b2","src":"msg","to":"sala-test-r5","uuid":"%s","name":"sala-test-r5","pid":"","text":"for r5","from":"x"}\n' "$(uuid 25)" > "$SALA_STACKSHOT_INBOX/msg/e6.json"
WST="$SALA_LOG_DIR/salamander-watch.state"
printf 'wakefail.sala-test-r1=%s\n' "$(date +%s)" >> "$WST"      # a wake of r1 failed a moment ago
export SALA_WAKE_PER_RUN=1
DRY=$("$SALA" watch --wake --dry-run 2>&1)
has "$(grep sala-test-r5 <<< "$DRY")" "would be woken" && has "$(grep sala-test-r1 <<< "$DRY")" "skipped" && ! has "$(grep sala-test-r1 <<< "$DRY")" "would be woken" && ok "watch --wake --dry-run, cap 1: r1 (in backoff) is skipped and r5 is the one that would be woken" || bad "wake dry (backoff): $DRY"
tick
waitfor 'hasclaude r5' 60
hasclaude r5 && ! asleep 25 && asleep 21 && ! hasclaude r1 && ok "the real run woke r5, the one the preview named, and left r1 (in backoff) asleep" || bad "backoff run: r5 up=$(hasclaude r5 && echo y) r1 asleep=$(asleep 21 && echo y); log: $(grep 'wake:' "$WLOG")"
[ "$(wlogn 'wake: sala-test-r1 not woken')" = 0 ] && ok "r1 was not tried at all (no failure line)" || bad "r1 was tried: $(grep 'wake:' "$WLOG")"
sed -i '/^wakefail\.sala-test-r1=/d' "$WST"
# the sleep side: the awake sessions r2..r5 are candidates again (their stamps are aged, the lines that woke them are gone); the first in backoff, the cap one
rm -f "$SALA_STACKSHOT_INBOX/msg/e5.json" "$SALA_STACKSHOT_INBOX/msg/e6.json"
OUT=$(SALA_SLEEP_PER_TICK=1 "$SALA" sleep --candidates 2>&1); first=$(names "$OUT" | cut -d' ' -f1)
[ -n "$first" ] && ok "a candidate exists for the sleep preview ($first)" || bad "no sleep candidate: $OUT"
_key_r kf "$first"; printf 'sleepfail.%s=%s\n' "$kf" "$(date +%s)" >> "$WST"
OUT=$(SALA_SLEEP_PER_TICK=1 "$SALA" sleep --candidates 2>&1); DRYS=$(SALA_SLEEP_PER_TICK=1 "$SALA" watch --sleep --dry-run 2>&1)
second=$(grep 'would be put to sleep' <<< "$OUT" | cut -d: -f1); has "$(grep -F "$first:" <<< "$OUT")" "skipped" && [ -n "$second" ] && [ "$second" != "$first" ] && [ "$(grep -c 'would be put to sleep' <<< "$OUT")" = 1 ] && ok "sleep --candidates, cap 1: $first (in backoff) is skipped and $second is the one that would be put to sleep" || bad "sleep preview (backoff): $OUT"
[ "$(grep 'would be put to sleep' <<< "$DRYS" | cut -d: -f1)" = "$second" ] && ok "watch --sleep --dry-run names the same session" || bad "watch --sleep --dry-run: $DRYS"
p2=$(wlogn "sleep: put $second to sleep"); p1=$(wlogn "sleep: put $first to sleep")   # both were slept once earlier: count what this run adds
SALA_IDLE_SLEEP=on SALA_SLEEP_PER_TICK=1 "$SALA" watch --sleep >/dev/null 2>&1
[ "$(wlogn "sleep: put $second to sleep")" = "$((p2 + 1))" ] && [ "$(wlogn "sleep: put $first to sleep")" = "$p1" ] && [ "$(wlogn 'not put to sleep')" = 0 ] && ok "the real run, cap 1, put $second to sleep, the one the preview named, and did not try $first" || bad "sleep run: $(grep 'sleep:' "$WLOG")"

echo "== the wake re-checks the pane-map row: a candidate whose row no longer holds its conversation id is skipped, with no wake and no failure stamp"
# wake_candidates is replaced by a fixed line (a candidate picked before the row changed); wake_locked runs in a subshell with the watch's logging and state seams stubbed
STUB="$HOME/stub.log"; : > "$STUB"; r1s=$(n_starts 21)
asleep 21 && ok "(r1 is asleep)" || bad "r1 is not asleep before the re-check case"
( wake_candidates() { printf 'sala-test-r1\t%s\thub\n' "$(uuid 99)"; }; wlog() { echo "log $*" >> "$STUB"; }; st_set() { echo "set $*" >> "$STUB"; }; st_del() { :; }; sleepstate_prune() { :; }
  wake_locked )
asleep 21 && ! hasclaude r1 && [ "$(n_starts 21)" = "$r1s" ] && [ ! -s "$STUB" ] && ok "a candidate whose id is not the row's: r1 stays asleep, not woken, nothing logged, no failure stamp" || bad "stale candidate acted: starts $(n_starts 21)/$r1s; stub: $(cat "$STUB")"
( wake_candidates() { printf 'sala-test-r1\t%s\thub\n' "$(uuid 21)"; }; wlog() { echo "log $*" >> "$STUB"; }; st_set() { echo "set $*" >> "$STUB"; }; st_del() { :; }; sleepstate_prune() { :; }
  wake_locked )
waitfor 'hasclaude r1' 60
hasclaude r1 && ! asleep 21 && [ "$(n_starts 21)" = "$((r1s + 1))" ] && grep -q '^log wake: woke sala-test-r1' "$STUB" && ok "the same candidate with the row's own id is woken" || bad "control wake: starts $(n_starts 21)/$r1s; stub: $(cat "$STUB")"

[ "$fail" = 0 ] && echo "sleeptick: pass" || echo "sleeptick: FAIL"
exit $fail
