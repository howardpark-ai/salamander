#!/usr/bin/env bash
# Sleeping sessions, stage 2 (lib/sleep.sh, lib/wake.sh, lib/op.sh): the verbs that put an idle session to sleep and wake it, and their way through the operation
# queue. `sala sleep NAME` ends the claude of a session that sleep_ready (lib/wrapup.sh) passes (idle, nothing in flight, never a front agent), keeps its tmux
# session and pane-map row and writes the marker; `sala wake NAME` takes the marker off and resumes the row's conversation by its uuid through revive. Nothing
# sleeps on its own here: the watch's tick is stage 5 (tests/sleeptick.sh). What is checked, on a private tmux server with the compiled fake claude:
#  - sleep refuses, with one line saying why and nothing changed (claude still running, no marker): a session not idle for SALA_SLEEP_AFTER, a front agent, the
#    session the command runs in, a session already asleep; --dry-run says the same as "[dry-run] would refuse: ..." and changes nothing;
#  - sleep of a ready session ends its claude, keeps the tmux session and the pane-map row byte for byte, writes the marker and `sleep --list` shows it;
#  - wake --dry-run changes nothing; wake takes the marker off and the fake starts again on the SAME conversation uuid (one more start line, no other uuid);
#    a name that is not asleep is a message and no action (no start); a sleeper whose claude already runs only loses its marker; a sleeper whose tmux session
#    is gone is recreated and resumed;
#  - the queue: `op sleep|wake --only NAME…` takes only --only, plans with the verb's --dry-run, and with no words needs a reason (--item or --why) and a caller
#    placed by process ancestry (a plain shell is refused), never the asker itself; a wake of a session that is not asleep queues nothing; the queued marker
#    carries the reason, one ownrow= per name and no words; the runner (op --run) puts the session to sleep although its own marker names it, and wakes it;
#  - a raw `sleep` or `wake` from a Claude session is refused with the `sala op` line, and its --dry-run passes;
#  - `sala op --help`, `sala sleep --help` and `sala wake --help` name the verbs.
# SAFETY: every kill is a `kill -9` of ONE pid whose /proc/<pid>/exe is this suite's own compiled fake and whose environment names this suite's temporary HOME
# (kill_fake_claude); the tmux server is a private socket (tmux -L sala-sleepverbs-<pid> -f /dev/null, SALA_TMUX_SOCKET pointing at it), HOME is a mktemp -d
# held with flock, the claude is tests/fake-claude.c; the "Claude session" that asks is a copy of bash named claude in the fake versions folder; no real pane,
# server, ~/.claude or claude process is read or touched. Posts go to a file.
# Usage: bash tests/sleepverbs.sh   (exit 0 = pass)
set -u
unset TMUX TMUX_PANE XDG_STATE_HOME SALA_MASTER SALA_SET SALA_SET_SELF SALA_RECYCLE SALA_RETRY_WORKER SALA_LOCK_WHO SALA_LOCK_WAIT SALA_RELAUNCH_KIND SALA_SLEEP_DIR \
      SALA_FLEET_HOSTS SALA_CGROUP_FILE SALA_OP_QUEUE SALA_NO_RELAUNCH SALA_BOOT_ID SALA_CONFIG SALA_BARE_REVIVE SALA_IDLE_WRAPUP SALA_SESSION_ID SALA_STACKSHOT_INBOX \
      SALA_STACKSHOT_DIR SALA_STACKSHOT_CLIENT SALA_AGENT_CHECK_SCRIPT SALA_PROJECT_RECORD SALA_OP_ID SALA_OP_FROM SALA_OP_REASON_FROM
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
SANDBOX=""; SOCK="sala-sleepverbs-$$"; T="tmux -L $SOCK -f /dev/null"
cleanup() {
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    [ -z "$SANDBOX" ] || { kill_fake_claude "$FAKEBIN"; exec 8<&-; rm -rf "$SANDBOX" 2>/dev/null; }
    true
}; trap cleanup EXIT   # set before the temp folder exists
SANDBOX=$(mktemp -d); export HOME=$SANDBOX SALA_TZ=Etc/UTC SALA_CONFIG=/dev/null
case "$HOME" in /tmp/*|"${TMPDIR:-/tmp}"/*) ;; *) echo "sleepverbs: HOME is not a temporary directory ($HOME) - refusing to run"; exit 1;; esac
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
export SALA_OP_STUCK=off SALA_OP_QUEUE=off   # a queued marker is written and nothing starts it
SALA="$ROOT/bin/salamander"
export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's
case "$SOCK" in sala-sleepverbs-*) ;; *) echo "sleepverbs: not a private socket - refusing to run"; exit 1;; esac
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux    # literal socket: the children run set -u
$T new-session -d -s sala-test-keep -x 200 -y 50 -c "$HOME"; $T set -g exit-empty off   # a server that outlives its last fake
. "$ROOT/lib/common.sh"; . "$ROOT/lib/wrapup.sh"
MAP="$SALA_SIDECAR"; OPS="$SALA_STATE_DIR/ops"; DONE="$OPS/done"
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
stoprec() { mkdir -p "$SALA_BUSY_DIR"; printf 'id=t%s\nepoch=%s\nseen=\nseen_status=idle\ntasks=0\ncrons=0\n' "$1" "$TURN" > "$SALA_BUSY_DIR/$(uuid "$1")"; }   # <uuid n>: the Stop hook's record of a finished turn
mval() { awk -F= -v k="$2" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "$1" 2>/dev/null; }   # <marker file> <key> → its first value
mvals() { awk -F= -v k="$2" '$1==k {sub(/^[^=]*=/, ""); print}' "$1" 2>/dev/null; }
opfiles() { ls "$OPS"/*.op 2>/dev/null; }
export SALA_SLEEP_DIR   # the children read the same directory (its default under SALA_STATE_DIR)

# THE CALLER (as tests/retire-own.sh): a "Claude session's call" is a command run as a CHILD of a process named claude that is the pane process of a window of the
# asking session. The driver is a copy of bash installed in the versions folder and started through a symlink named claude; it runs each command file it is
# handed as its own child. callin <command…> hands it one and waits.
cat > "$HOME/drv-claude" <<'EOF'
#!/bin/bash
d=$1
while :; do
    for f in "$d"/*.cmd; do
        [ -e "$f" ] || continue
        b=${f%.cmd}
        bash "$f" > "$b.out" 2>&1; echo $? > "$b.rc.tmp"; mv "$b.rc.tmp" "$b.rc"; rm -f "$f"
    done
    sleep 0.2
done
EOF
mkdir -p "$HOME/drv" "$HOME/drv-calls"; cp "$(command -v bash)" "$HOME/.local/share/claude/versions/drv-bash"; ln -sf "$HOME/.local/share/claude/versions/drv-bash" "$HOME/drv/claude"
$T new-session -d -s sala-test-asker "$HOME/drv/claude $HOME/drv-claude $HOME/drv-calls"
callin() {  # <argv…> → OUT, RC of that command run from inside the session sala-test-asker (a Claude session's call)
    local id f; id=$(date +%s%N)-$RANDOM; f="$HOME/drv-calls/$id"
    printf '%q ' "$@" > "$f.tmp"; echo >> "$f.tmp"; mv "$f.tmp" "$f.cmd"
    waitfor "[ -e '$f.rc' ]" 300 || { OUT="(the driver did not answer)"; RC=99; return; }
    OUT=$(<"$f.out"); RC=$(<"$f.rc"); rm -f "$f.out" "$f.rc"
}
RAW="env SALA_CGROUP_FILE=/dev/null"   # a call that is not the queue's runner: the unit's cgroup file of this suite names none

echo "== setup: private tmux server, isolated HOME, the compiled fake claude (s, s2, q, g: idle and ready · n: idle only a minute · x-main: a front agent · d: control)"
mk s 6 -e FAKE_IDLE_AGE=4000; mk s2 12 -e FAKE_IDLE_AGE=4000; mk q 16 -e FAKE_IDLE_AGE=4000; mk g 15 -e FAKE_IDLE_AGE=4000
mk n 13 -e FAKE_IDLE_AGE=60; mk x-main 14 -e FAKE_IDLE_AGE=4000; mk d 4 -e FAKE_IDLE_AGE=4000
fake_up sala-test-s sala-test-s2 sala-test-q sala-test-g sala-test-n sala-test-x-main sala-test-d || exit 1
for n in s s2 q g n x-main d; do "$SALA" adopt "sala-test-$n" >/dev/null 2>&1 || bad "adopt sala-test-$n failed"; done
for u in 6 12 16 15 14 4; do stoprec "$u"; done
[ "$($T display -p '#{socket_path}')" = "$SALA_TMUX_SOCKET" ] && ok "the tmux server is the suite's private socket ($SOCK)" || bad "socket: $($T display -p '#{socket_path}')"
callin bash -c 'echo up'; [ "$RC" = 0 ] && [ "$OUT" = up ] && ok "a call runs inside the asker's driver window" || { bad "driver: rc=$RC $OUT"; exit 1; }
US=$(uuid 6); US2=$(uuid 12); UQ=$(uuid 16); UG=$(uuid 15); UD=$(uuid 4)

echo "== sleep refuses, says why in one line, and changes nothing"
s0=$(n_starts 6)
run sleep sala-test-n
[ "$RC" = 1 ] && has "$OUT" "not put to sleep" && has "$OUT" "idle for" && hasclaude n && [ -z "$(ls -A "$SALA_SLEEP_DIR" 2>/dev/null)" ] && ok "n (idle a minute): refused, its claude still runs, no marker ($OUT)" || bad "sleep n: rc=$RC — $OUT"
run sleep sala-test-n --dry-run
[ "$RC" = 1 ] && has "$OUT" "[dry-run] would refuse: sala-test-n: idle for" && has "$OUT" "nothing was changed" && ok "n --dry-run: the same refusal as a dry-run line, exit 1" || bad "sleep n dry: rc=$RC — $OUT"
run sleep sala-test-x-main
[ "$RC" = 1 ] && has "$OUT" "front agent" && hasclaude x-main && [ ! -e "$SALA_SLEEP_DIR/$(uuid 14)" ] && ok "x-main: a front agent, refused in one line, claude still runs" || bad "sleep x-main: rc=$RC — $OUT"
run sleep sala-test-x-main --dry-run
[ "$RC" = 1 ] && has "$OUT" "would refuse" && has "$OUT" "front agent" && ok "x-main --dry-run: the same" || bad "sleep x-main dry: rc=$RC — $OUT"
OUT=$(SALA_OP_FROM=sala-test-s "$SALA" sleep sala-test-s 2>&1); RC=$?
[ "$RC" = 1 ] && has "$OUT" "the session this command runs in" && hasclaude s && [ ! -e "$SALA_SLEEP_DIR/$US" ] && ok "a session never sleeps itself: refused, nothing changed" || bad "sleep self: rc=$RC — $OUT"
run sleep
[ "$RC" != 0 ] && has "$OUT" "usage: salamander sleep" && ok "sleep with no name: the usage" || bad "sleep none: rc=$RC — $OUT"
run sleep sala-test-s --force
[ "$RC" != 0 ] && has "$OUT" "unknown option" && hasclaude s && ok "there is no --force: an unknown option, nothing changed" || bad "sleep --force: rc=$RC — $OUT"
run sleep sala-test-nosuch
[ "$RC" = 1 ] && has "$OUT" "no tmux session" && ok "no such session: refused" || bad "sleep nosuch: rc=$RC — $OUT"

echo "== sleep --dry-run of a ready session changes nothing"
run sleep sala-test-s --dry-run
[ "$RC" = 0 ] && has "$OUT" "[dry-run]" && has "$OUT" "would hold its stackshot inbox" && hasclaude s && [ ! -e "$SALA_SLEEP_DIR/$US" ] && [ "$(n_starts 6)" = "$s0" ] && ok "s --dry-run: says what it would do, exit 0, claude running, no marker" || bad "sleep s dry: rc=$RC — $OUT"

echo "== sleep: the claude ends, the tmux session and the pane-map row stay, the marker is written"
row0=$(row sala-test-s); [ -n "$row0" ] || bad "no pane-map row for s before the sleep"
run sleep sala-test-s
[ "$RC" = 0 ] && has "$OUT" "asleep" && ok "sleep s: exit 0, 'asleep' ($OUT)" || bad "sleep s: rc=$RC — $OUT"
! hasclaude s && ok "its claude has ended" || bad "s still has a claude"
$T has-session -t "=sala-test-s" 2>/dev/null && ok "its tmux session stays" || bad "tmux session of s is gone"
[ "$(row sala-test-s)" = "$row0" ] && ok "its pane-map row is byte for byte the same" || bad "row changed: '$row0' → '$(row sala-test-s)'"
[ -f "$SALA_SLEEP_DIR/$US" ] && [[ $(<"$SALA_SLEEP_DIR/$US") =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ sala-test-s$ ]] && ok "the marker is '<ISO-Z time> sala-test-s'" || bad "marker: $(<"$SALA_SLEEP_DIR/$US" 2>/dev/null)"
is_sleeping sala-test-s && ok "is_sleeping says so" || bad "is_sleeping s false"
case "$($T display -p -t =sala-test-s: '#{pane_current_command}')" in bash|sh|zsh|fish) ok "the pane is back at its shell" ;; *) bad "pane command: $($T display -p -t =sala-test-s: '#{pane_current_command}')" ;; esac
run sleep --list
[ "$RC" = 0 ] && has "$OUT" "sala-test-s" && has "$OUT" "asleep since" && has "$OUT" "$US" && ! has "$OUT" "sala-test-d" && ok "sleep --list shows s, when it went to sleep and its conversation" || bad "sleep --list: rc=$RC — $OUT"
run sleep sala-test-s
[ "$RC" = 1 ] && has "$OUT" "already asleep" && ok "asking again: 'already asleep', refused" || bad "sleep s again: rc=$RC — $OUT"
sleep 1; [ "$(n_starts 6)" = "$s0" ] && ! hasclaude s && ok "nothing revived it in the meantime" || bad "s started again? starts $(n_starts 6) vs $s0"

echo "== wake: --dry-run changes nothing; the real wake resumes the same conversation"
run wake sala-test-s --dry-run
[ "$RC" = 0 ] && has "$OUT" "[dry-run]" && has "$OUT" "revive --only sala-test-s resumes conversation $US" && [ -f "$SALA_SLEEP_DIR/$US" ] && ! hasclaude s && ok "wake s --dry-run: the plan, marker still there, no claude" || bad "wake s dry: rc=$RC — $OUT"
run wake sala-test-s
[ "$RC" = 0 ] && has "$OUT" "awake" && ok "wake s: exit 0, 'awake' ($OUT)" || bad "wake s: rc=$RC — $OUT"
[ ! -e "$SALA_SLEEP_DIR/$US" ] && ! is_sleeping sala-test-s && ok "the marker is off" || bad "marker still there"
waitfor 'hasclaude s' 40; hasclaude s && ok "a claude runs in the pane again" || bad "no claude after the wake"
[ "$(n_starts 6)" = "$((s0 + 1))" ] && ok "the fake started once more, on the same conversation uuid ($US)" || bad "starts of $US: $(n_starts 6), was $s0"
[ "$(row sala-test-s)" = "$row0" ] && ok "the pane-map row is still the same" || bad "row after wake: '$(row sala-test-s)'"
s1=$(n_starts 6)
run wake sala-test-s
[ "$RC" = 0 ] && has "$OUT" "not sleeping, nothing done" && [ "$(n_starts 6)" = "$s1" ] && ok "wake of a session that is not asleep: a message, exit 0, no action" || bad "wake s again: rc=$RC starts=$(n_starts 6) — $OUT"
run wake sala-test-nosuch
[ "$RC" = 0 ] && has "$OUT" "not sleeping" && ok "wake of a name nobody knows: the same message" || bad "wake nosuch: rc=$RC — $OUT"
run wake sala-test-s sala-test-nosuch --dry-run
[ "$RC" = 0 ] && has "$OUT" "would do nothing" && ok "wake --dry-run of non-sleepers: nothing to do, exit 0" || bad "wake dry non-sleepers: rc=$RC — $OUT"
run wake
[ "$RC" != 0 ] && has "$OUT" "usage: salamander wake" && ok "wake with no name: the usage" || bad "wake none: rc=$RC — $OUT"

echo "== wake of a sleeper whose claude already runs takes the marker off and starts nothing"
sleeping_mark "$UD" sala-test-d; d0=$(n_starts 4)
run wake sala-test-d
[ "$RC" = 0 ] && has "$OUT" "already running" && [ ! -e "$SALA_SLEEP_DIR/$UD" ] && [ "$(n_starts 4)" = "$d0" ] && ok "d: marker off, no second claude on the conversation" || bad "wake d: rc=$RC starts=$(n_starts 4)/$d0 — $OUT"

echo "== wake of a sleeper whose tmux session is gone recreates the session and resumes the conversation"
run sleep sala-test-g
[ "$RC" = 0 ] && ! hasclaude g && is_sleeping sala-test-g && ok "g is asleep" || bad "sleep g: rc=$RC — $OUT"
g0=$(n_starts 15); $T kill-session -t "=sala-test-g"
run wake sala-test-g --dry-run
[ "$RC" = 0 ] && has "$OUT" "its tmux session is gone" && has "$OUT" "recreate the session" && is_sleeping sala-test-g && ok "wake g --dry-run: would recreate the session, marker stays" || bad "wake g dry: rc=$RC — $OUT"
run wake sala-test-g
[ "$RC" = 0 ] && has "$OUT" "awake" && $T has-session -t "=sala-test-g" 2>/dev/null && ! is_sleeping sala-test-g && ok "wake g: the tmux session is back, the marker off" || bad "wake g: rc=$RC — $OUT"
waitfor 'hasclaude g' 40; [ "$(n_starts 15)" = "$((g0 + 1))" ] && hasclaude g && ok "the conversation $UG resumed in it (one more start)" || bad "g starts: $(n_starts 15) vs $g0"

echo "== a raw sleep or wake from a Claude session is refused with the sala op line; its dry run passes"
# (a target named sala-test-* passes the guard from any pane, ops_guard: so the raw calls name a plain one, which the guard refuses before it looks at anything)
callin $RAW "$SALA" sleep plain-nosuch
[ "$RC" != 0 ] && has "$OUT" "sleep is a fleet operation" && has "$OUT" "sala op sleep --only NAME" && has "$OUT" "--from sala-test-asker" && ok "raw sleep: refused, points to 'sala op sleep --only NAME …' with the asker's name" || bad "raw sleep: rc=$RC — $OUT"
callin $RAW "$SALA" sleep plain-nosuch --dry-run
[ "$RC" = 1 ] && has "$OUT" "[dry-run] would refuse" && ! has "$OUT" "fleet operation" && ok "raw sleep --dry-run passes the guard (and refuses on its own: no such session)" || bad "raw sleep dry: rc=$RC — $OUT"
callin $RAW "$SALA" wake plain-nosuch
[ "$RC" != 0 ] && has "$OUT" "wake is a fleet operation" && has "$OUT" "sala op wake --only NAME" && ok "raw wake: refused, points to 'sala op wake --only NAME …'" || bad "raw wake: rc=$RC — $OUT"
callin $RAW "$SALA" wake plain-nosuch --dry-run
[ "$RC" = 0 ] && has "$OUT" "[dry-run]" && ! has "$OUT" "fleet operation" && ok "raw wake --dry-run passes the guard" || bad "raw wake dry: rc=$RC — $OUT"
callin $RAW "$SALA" sleep --list
[ "$RC" = 0 ] && ok "sleep --list is read-only: it needs no queue" || bad "raw sleep --list: rc=$RC — $OUT"

echo "== the queue: shape, plan, and the words policy"
rm -rf "$OPS"; mkdir -p "$OPS"
run op --plan sleep --only sala-test-s2
[ "$RC" = 0 ] && has "$OUT" "plan: salamander sleep sala-test-s2" && has "$OUT" "[dry-run]" && has "$OUT" "plan only: nothing queued" && [ -z "$(opfiles)" ] && ok "op --plan sleep: the verb's dry run, nothing queued" || bad "op --plan sleep: rc=$RC — $OUT"
run op sleep --only sala-test-s2 --force --why "a reason of words" --from sala-test-asker
[ "$RC" != 0 ] && has "$OUT" "takes --only NAME only" && [ -z "$(opfiles)" ] && ok "op sleep takes --only and nothing else (--force refused)" || bad "op sleep --force: rc=$RC — $OUT"
run op sleep sala-test-s2 --why "a reason of words" --from sala-test-asker
[ "$RC" != 0 ] && has "$OUT" "takes --only NAME only" && ok "op sleep NAME (no --only): refused" || bad "op sleep NAME: rc=$RC — $OUT"
run op sleep --only sala-test-s2 --only sala-test-s2 --why "a reason of words" --from sala-test-asker
[ "$RC" != 0 ] && has "$OUT" "twice" && ok "a name twice: refused" || bad "op sleep twice: rc=$RC — $OUT"
run op sleep --only sala-test-s2 --from sala-test-asker
[ "$RC" != 0 ] && has "$OUT" "no --words" && has "$OUT" "op sleep --only NAME" && [ -z "$(opfiles)" ] && ok "no words and no reason: refused, the refusal names the sleep and wake door" || bad "op sleep no reason: rc=$RC — $OUT"
run op sleep --only sala-test-s2 --why "a reason of words" --from sala-test-asker
[ "$RC" != 0 ] && [ -z "$(opfiles)" ] && ok "a reason from a plain shell (no Claude session above the call): refused, nothing queued ($(printf '%s' "$OUT" | tail -1 | cut -c1-120))" || bad "op sleep from a shell: rc=$RC — $OUT"
run op sleep --only sala-test-s2 --why "two words" --from sala-test-asker
[ "$RC" != 0 ] && has "$OUT" "three words or more" && ok "--why of two words: refused" || bad "op sleep --why short: rc=$RC — $OUT"
run op wake --only sala-test-s2 --item board#abc --from sala-test-asker
[ "$RC" != 0 ] && has "$OUT" "not a board item id" && ok "--item must be board#N" || bad "op wake bad item: rc=$RC — $OUT"
run op rename sala-test-s2 sala-test-s9 --why "a reason of words" --from sala-test-asker
[ "$RC" != 0 ] && has "$OUT" "only with revive, restore, sleep and wake" && ok "--why is for revive, restore, sleep and wake only" || bad "op rename --why: rc=$RC — $OUT"
callin "$SALA" op sleep --only sala-test-asker --why "a reason of words" --from sala-test-asker
[ "$RC" != 0 ] && has "$OUT" "asking session itself" && [ -z "$(opfiles)" ] && ok "the asker itself is refused (a sleep of yourself would end the call)" || bad "op sleep self: rc=$RC — $OUT"
callin "$SALA" op sleep --only sala-test-x-main --why "a reason of words" --from sala-test-asker
[ "$RC" != 0 ] && has "$OUT" "front agent" && has "$OUT" "nothing queued" && [ -z "$(opfiles)" ] && ok "a front agent: the plan (sleep --dry-run) refuses before anything is queued" || bad "op sleep front: rc=$RC — $OUT"
callin "$SALA" op sleep --only sala-test-n --why "a reason of words" --from sala-test-asker
[ "$RC" != 0 ] && has "$OUT" "idle for" && [ -z "$(opfiles)" ] && ok "a session idle only a minute: refused by the plan, nothing queued" || bad "op sleep n: rc=$RC — $OUT"
callin "$SALA" op sleep --only sala-test-s2 --why "a reason of words" --from sala-test-other
[ "$RC" != 0 ] && [ -z "$(opfiles)" ] && ok "--from naming another session than the caller: refused" || bad "op sleep wrong from: rc=$RC — $OUT"
callin "$SALA" op wake --only sala-test-s2 --why "a reason of words" --from sala-test-asker
[ "$RC" = 0 ] && has "$OUT" "not sleeping, nothing to wake" && [ -z "$(opfiles)" ] && ok "op wake of a session that is not asleep: said, exit 0, nothing queued" || bad "op wake awake: rc=$RC — $OUT"
run op wake --only sala-test-s2 --words "wake it" --from sala-test-asker
[ "$RC" = 0 ] && has "$OUT" "not sleeping" && [ -z "$(opfiles)" ] && ok "the same with the owner's words: nothing queued" || bad "op wake words: rc=$RC — $OUT"

echo "== the queue: a no-words sleep through the reason door, and the runner"
callin "$SALA" op sleep --only sala-test-s2 --why "idle for the whole afternoon" --from sala-test-asker
if [ "$RC" = 0 ]; then ok "op sleep --only s2 --why … from the asker: queued ($(printf '%s' "$OUT" | grep -m1 '^queued' | cut -c1-100))"; else bad "op sleep s2: rc=$RC — $OUT"; fi
M=$(opfiles | head -1)
if [ -n "$M" ]; then
    [ "$(mval "$M" verb)" = sleep ] && [ "$(mvals "$M" arg | paste -sd, -)" = "--only,sala-test-s2" ] && ok "the marker: verb=sleep, arg=--only, arg=sala-test-s2" || bad "marker verb/args: $(cat "$M")"
    [ -z "$(mval "$M" words)" ] && [ "$(mval "$M" nowords)" = "words: none (reason: idle for the whole afternoon)" ] && [ "$(mval "$M" reason)" = "idle for the whole afternoon" ] && [ -z "$(mval "$M" item)" ] && ok "no words; nowords= and reason= carry the reason" || bad "marker words: $(cat "$M")"
    [ "$(mvals "$M" ownrow | grep -c .)" = 1 ] && [ "$(mval "$M" from)" = sala-test-asker ] && [ "$(mval "$M" state)" = queued ] && ok "one ownrow= (the registry row), from=sala-test-asker, state=queued" || bad "marker rows: $(cat "$M")"
    OPID=$(basename "$M" .op)
    SALA_OP_STUCK=off "$SALA" op --run "$OPID" >/dev/null 2>&1
    is_sleeping sala-test-s2 && ! hasclaude s2 && ok "the runner (op --run) put s2 to sleep although its own queued marker names it" || bad "runner: is_sleeping=$(is_sleeping sala-test-s2 && echo y || echo n) claude=$(hasclaude s2 && echo y || echo n) — $(tail -3 "$SALA_LOG_DIR/salamander-op-$OPID.log" 2>/dev/null)"
    [ -f "$DONE/$OPID.op" ] && [ "$(mval "$DONE/$OPID.op" state)" = done ] && ok "the operation ended done and was archived" || bad "after the run: $(cat "$M" "$DONE/$OPID.op" 2>/dev/null | tr '\n' ' ')"
    grep -q "put sala-test-s2 to sleep" "$POSTS" 2>/dev/null && ok "the post says it put s2 to sleep" || bad "post: $(tail -4 "$POSTS" | tr '\n' ' ')"
else bad "no marker was queued"; fi

ITEM="board#$((9100 + 1))"
echo "== the queue: a no-words wake (--item), the plan, and the runner"
run op --plan wake --only sala-test-s2
[ "$RC" = 0 ] && has "$OUT" "plan: salamander wake sala-test-s2" && has "$OUT" "resume" && has "$OUT" "plan only: nothing queued" && ok "op --plan wake: the plan" || bad "op --plan wake: rc=$RC — $OUT"
callin "$SALA" op wake --only sala-test-s2 --item $ITEM --from sala-test-asker
if [ "$RC" = 0 ]; then ok "op wake --only s2 --item $ITEM: queued"; else bad "op wake s2: rc=$RC — $OUT"; fi
M=$(opfiles | head -1)
if [ -n "$M" ]; then
    [ "$(mval "$M" verb)" = wake ] && [ "$(mval "$M" item)" = $ITEM ] && [ -z "$(mval "$M" words)" ] && [ "$(mval "$M" nowords)" = "words: none ($ITEM: wake of one session)" ] && ok "the marker: verb=wake, item=$ITEM, no words" || bad "wake marker: $(cat "$M")"
    [ "$(mval "$M" ownrow)" = "$US2" ] && ok "ownrow= is the sleeper's conversation id" || bad "wake ownrow: '$(mval "$M" ownrow)' vs $US2"
    OPID=$(basename "$M" .op); w0=$(n_starts 12)
    SALA_OP_STUCK=off "$SALA" op --run "$OPID" >/dev/null 2>&1
    waitfor 'hasclaude s2' 40
    ! is_sleeping sala-test-s2 && hasclaude s2 && [ "$(n_starts 12)" = "$((w0 + 1))" ] && ok "the runner woke s2: marker off, its claude resumed on $US2" || bad "wake runner: sleeping=$(is_sleeping sala-test-s2 && echo y || echo n) starts=$(n_starts 12)/$w0 — $(tail -3 "$SALA_LOG_DIR/salamander-op-$OPID.log" 2>/dev/null)"
    [ -f "$DONE/$OPID.op" ] && [ "$(mval "$DONE/$OPID.op" state)" = done ] && ok "the wake ended done and was archived" || bad "after the wake: $(cat "$M" "$DONE/$OPID.op" 2>/dev/null | tr '\n' ' ')"
else bad "no wake marker was queued"; fi

echo "== a reason-door marker is judged again by the runner: a changed row goes stuck with nothing done"
sleeping_mark "$UQ" sala-test-q; rm -f "$OPS"/*.op
callin "$SALA" op wake --only sala-test-q --why "wake it for the check" --from sala-test-asker
M=$(opfiles | head -1)
if [ "$RC" = 0 ] && [ -n "$M" ]; then
    OPID=$(basename "$M" .op); sed -i "s/^ownrow=.*/ownrow=not-the-conversation/" "$M"; q0=$(n_starts 16)
    SALA_OP_STUCK=off "$SALA" op --run "$OPID" >/dev/null 2>&1
    is_sleeping sala-test-q && [ "$(n_starts 16)" = "$q0" ] && grep -q "nothing was woken" "$DONE/$OPID.op" 2>/dev/null && ok "the row replaced since it was queued: stuck, nothing woken, q still asleep" || bad "stuck wake: sleeping=$(is_sleeping sala-test-q && echo y || echo n) $(cat "$DONE/$OPID.op" "$M" 2>/dev/null | tr '\n' ' ')"
else bad "op wake q: rc=$RC — $OUT"; fi
sleeping_clear "$UQ"

echo "== the teaching text names the verbs"
run op --help
has "$OUT" "op sleep --only NAME" && has "$OUT" "op wake --only NAME" && ok "sala op --help lists sleep and wake" || bad "op --help: $OUT"
run sleep --help
[ "$RC" = 0 ] && has "$OUT" "usage: salamander sleep" && ok "sleep --help" || bad "sleep --help: rc=$RC — $OUT"
run wake --help
[ "$RC" = 0 ] && has "$OUT" "usage: salamander wake" && ok "wake --help" || bad "wake --help: rc=$RC — $OUT"
run --help
has "$OUT" "salamander sleep NAME" && has "$OUT" "salamander wake NAME" && ok "the top-level help lists both verbs" || bad "--help lacks the verbs"

[ "$fail" = 0 ] && echo "sleepverbs: pass" || echo "sleepverbs: FAIL"
exit $fail
