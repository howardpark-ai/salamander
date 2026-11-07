#!/usr/bin/env bash
# Bare panes (lib/barepane.sh, called by lib/watch.sh): after a mass SIGKILL of every claude on
# the coordinator machine, tmux and its panes stay up as bare shells and nothing revived them. Watch now revives ANY
# mapped pane that stays at a shell with no claude for SALA_BARE_GRACE, with `revive --only`. What is checked, with no master
# configured (the only pane check such a box has):
#  - the control: panes with a claude, and one tick over bare panes before the grace, revive nothing and post nothing;
#  - after the grace the bare panes are revived on their own conversations (the fake claude's start log counts them), the
#    longest-bare first, at most SALA_BARE_MAX per tick (a cap of 2 for three bare panes: the third waits for the next tick),
#    and ONE post per tick names them ("watch: revived 2 panes whose claude had died: …");
#  - left alone, however long they stay bare: a session whose registry row says retired, a side session that wrote its
#    `side done` marker, a pane running a command (a child of its shell), a session in SALA_NO_RELAUNCH, a pane that has a claude;
#  - a recycle lock held: nothing is revived and the clocks restart, so the grace counts from the first bare tick after it;
#  - a pane revive cannot bring back (FAKE_RESUME_FAIL): tried SALA_BARE_TRIES times, one "could not revive" post, then left;
#  - SALA_BARE_REVIVE=off revives nothing.
# SAFETY: every kill in this suite is a `kill -9` of ONE pid, taken only after /proc/<pid>/exe is the suite's own compiled fake
# claude and /proc/<pid>/environ names this suite's temporary HOME (killfake, cleanup). The tmux server is a private socket
# (tmux -L sala-barepane-<pid> -f /dev/null, SALA_TMUX_SOCKET pointing at it), HOME is a mktemp -d, the claude is tests/fake-claude.c;
# no real pane, server, ~/.claude or claude process is read or touched, and the suite refuses to start if any of that is not so.
# Posts go to a file. Usage: bash tests/barepane.sh   (exit 0 = pass; ~90 s)
set -u
unset TMUX TMUX_PANE XDG_STATE_HOME SALA_MASTER SALA_SET SALA_SET_SELF SALA_RECYCLE SALA_RETRY_WORKER SALA_LOCK_WHO SALA_LOCK_WAIT SALA_RELAUNCH_KIND \
      SALA_FLEET_HOSTS SALA_CGROUP_FILE SALA_OP_QUEUE SALA_NO_RELAUNCH SALA_BOOT_ID SALA_CONFIG SALA_BARE_REVIVE
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
export HOME=$(mktemp -d); export SALA_TZ=Etc/UTC SALA_CONFIG=/dev/null
case "$HOME" in /tmp/*|"${TMPDIR:-/tmp}"/*) ;; *) echo "barepane: HOME is not a temporary directory ($HOME) - refusing to run"; exit 1;; esac
as_op_unit   # the guarded verbs this suite runs itself (adopt) stand for the queue's runner (tests/lib.sh, 5)
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
FAKEBIN="$HOME/.local/share/claude/versions/9.9.9"
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$FAKEBIN" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
ln -s "$FAKEBIN" "$HOME/.local/bin/claude"
printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/systemd-run"
cat > "$HOME/.local/bin/systemctl" <<'EOF'
#!/bin/bash
case "$*" in *is-active*) exit 3 ;; *is-system-running*) echo running; exit 0 ;; *cat*tmux.service*) exit 1 ;; *) exit 0 ;; esac
EOF
chmod +x "$HOME/.local/bin/systemd-run" "$HOME/.local/bin/systemctl"
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log" FAKE_TYPED_LOG="$HOME/typed.log"
POSTS="$HOME/posts.txt"; : > "$POSTS"; export SALA_NOTIFY_CMD="{ cat; echo '%%'; } >> $POSTS"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off
export SALA_LIMIT_ALERT=off SALA_LIMIT_RESUME=off SALA_STUCK_POST=off   # the other watches: not under test
SALA="$ROOT/bin/salamander"; SOCK="sala-barepane-$$"; T="tmux -L $SOCK -f /dev/null"
export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's
case "$SOCK" in sala-barepane-*) ;; *) echo "barepane: not a private socket - refusing to run"; exit 1;; esac
LOCK="$HOME/.claude/salamander-recycle.lock"; WLOG="$HOME/.claude/salamander-watch.log"; ST="$HOME/.claude/salamander-watch.state"
LOCKPID=""; : > "$WLOG"
# killfake <tmux session> → SIGKILL the suite's fake claude under that session's pane, and only it: the pid must be a child of the pane's
# shell on THIS suite's private server, /proc/<pid>/exe the compiled fake, and its environment this suite's HOME
killfake() {
    local pp p
    pp=$($T list-panes -t "=$1" -F '#{pane_pid}' 2>/dev/null | head -1); [ -n "$pp" ] || return 1
    for p in $(pgrep -P "$pp" -x claude); do
        [ "$FAKEBIN" -ef "/proc/$p/exe" ] && grep -qz "^HOME=$HOME\$" "/proc/$p/environ" 2>/dev/null && kill -9 "$p"
    done
    return 0
}
cleanup() {
    local p
    [ -n "$LOCKPID" ] && kill "$LOCKPID" 2>/dev/null
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    for p in $(pgrep -x claude); do [ "$FAKEBIN" -ef "/proc/$p/exe" ] && grep -qz "^HOME=$HOME\$" "/proc/$p/environ" 2>/dev/null && kill -9 "$p" 2>/dev/null; done
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux    # literal socket: the children run set -u
. "$ROOT/lib/common.sh"
mk() { local n="$1" u="$2"; shift 2; $T new-session -d -s "sala-test-$n" -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="sala-test-$n" -e FAKE_LOG="$FAKE_LOG" "$@"; $T send-keys -t "sala-test-$n" 'claude' Enter; }
hasclaude() { local pp; pp=$($T list-panes -t "=sala-test-$1" -F '#{pane_pid}' 2>/dev/null | head -1); [ -n "$pp" ] && [ -n "$(claude_pid_under "$pp" 2>/dev/null)" ]; }   # <suffix>
tick() { "$SALA" watch >/dev/null 2>&1; }
wlogn() { grep -c -- "$1" "$WLOG" 2>/dev/null || true; }
n_starts() { starts "$(uuid "$1")"; }   # <n> → starts of fake session n

echo "== setup: private tmux server, isolated HOME, the compiled fake claude (sala-test-a..h)"
mk a "$(uuid 1)"; mk b "$(uuid 2)"; mk c "$(uuid 3)"; mk d "$(uuid 4)"; mk e "$(uuid 5)"; mk f "$(uuid 6)"; mk g "$(uuid 7)"
mk h "$(uuid 8)" -e FAKE_RESUME_FAIL=1
fake_up sala-test-a sala-test-b sala-test-c sala-test-d sala-test-e sala-test-f sala-test-g sala-test-h || exit 1
for n in a b c d e f g h; do "$SALA" adopt "sala-test-$n" >/dev/null 2>&1 || bad "adopt sala-test-$n failed"; done
[ "$($T display -p '#{socket_path}')" = "$SALA_TMUX_SOCKET" ] && ok "the tmux server is the suite's private socket ($SOCK)" || bad "socket: $($T display -p '#{socket_path}')"
export SALA_BARE_GRACE=4 SALA_BARE_MAX=2 SALA_BARE_RETRY=1 SALA_BARE_TRIES=2

echo "== control: every pane has its claude - a tick revives nothing, posts nothing"
tick
[ "$(wlogn 'bare panes: reviving')" = 0 ] && [ "$(nposts 'whose claude had died')" = 0 ] && ok "nothing revived, nothing posted" || bad "log: $(tail -5 "$WLOG")"
a0=$(n_starts 1); b0=$(n_starts 2); c0=$(n_starts 3); d0=$(n_starts 4); e0=$(n_starts 5); f0=$(n_starts 6); g0=$(n_starts 7); h0=$(n_starts 8)

echo "== a mass SIGKILL: a, b, c (to be healed), d (retired in the registry), e (side done), g (a command runs in its shell) lose their claude; f keeps it"
mkdir -p "$SALA_SIDE_DIR"; printf '%s by sala-test-e: item none\n' "$(date +%s)" > "$(side_done_file sala-test-e)"
sessions_py dual retire sala-test-d >/dev/null 2>&1 || bad "could not mark sala-test-d retired in the registry"
for n in a b c d e g; do killfake "sala-test-$n"; done
waitfor '! hasclaude a && ! hasclaude b && ! hasclaude c && ! hasclaude d && ! hasclaude e && ! hasclaude g' 40 || bad "the fakes did not die"
$T send-keys -t "=sala-test-g:" 'sleep 600' Enter; waitfor '[ "$($T list-panes -t =sala-test-g -F "#{pane_current_command}" | head -1)" = sleep ]' 40 || bad "g's shell did not start its command"
hasclaude f && ok "f still has its claude; the others are bare shells (exit 137)" || bad "f lost its claude?"
tick
[ "$(n_starts 1)" = "$a0" ] && [ "$(n_starts 2)" = "$b0" ] && [ "$(n_starts 3)" = "$c0" ] && ! hasclaude a && ok "first tick: seen, not revived (the grace has not passed)" || bad "starts a=$(n_starts 1)/$a0 b=$(n_starts 2)/$b0 c=$(n_starts 3)/$c0; $(tail -5 "$WLOG")"
[ "$(wlogn "'sala-test-a' is at a shell with no claude (first seen)")" = 1 ] && grep -q "^bare.sala-test-a=" "$ST" && ok "logged, and its clock started in the watch state" || bad "log/state: $(tail -5 "$WLOG") / $(grep bare "$ST")"
! grep -q "^bare.sala-test-g=\|^bare.sala-test-e=" "$ST" && ok "g (busy shell) and e (side done) have no clock" || bad "state: $(grep bare "$ST")"

echo "== after the grace: the longest-bare two are revived (cap 2), one post; c waits for the next tick"
sleep 5
tick
waitfor 'hasclaude a && hasclaude b' 40 && ok "a and b have a claude again" || bad "a/b not back: $(tail -8 "$WLOG")"
[ "$(n_starts 1)" = "$((a0 + 1))" ] && [ "$(n_starts 2)" = "$((b0 + 1))" ] && ok "each resumed once, on its own conversation (the fake's start log)" || bad "starts a=$(n_starts 1) b=$(n_starts 2)"
! hasclaude c && [ "$(n_starts 3)" = "$c0" ] && grep -q 'cap of 2 per tick — 1 more wait for a later tick: sala-test-c' "$WLOG" && ok "c not yet: the cap held, said in the log" || bad "c: $(tail -6 "$WLOG")"
P=$(post "whose claude had died"); [ "$(nposts 'whose claude had died')" = 1 ] && has "$P" "watch: revived 2 panes whose claude had died: sala-test-a, sala-test-b" && ok "one post: watch: revived 2 panes whose claude had died: sala-test-a, sala-test-b" || bad "post: $(<"$POSTS")"
has "$P" "1 more wait for the next tick" && ok "the post says one more waits" || bad "post: $P"
tick
waitfor 'hasclaude c' 40 && [ "$(n_starts 3)" = "$((c0 + 1))" ] && [ "$(n_starts 1)" = "$((a0 + 1))" ] && ok "next tick: c revived; a and b not touched again" || bad "starts a=$(n_starts 1) c=$(n_starts 3); $(tail -6 "$WLOG")"
[ "$(nposts 'whose claude had died')" = 2 ] && has "$(post 'revived 1 pane')" "revived 1 pane whose claude had died: sala-test-c" && ok "second post names c" || bad "posts: $(<"$POSTS")"

echo "== left alone: retired (d), side done (e), a command in the shell (g), however long they stay bare"
sleep 5; tick; tick
! hasclaude d && ! hasclaude e && [ "$(n_starts 4)" = "$d0" ] && [ "$(n_starts 5)" = "$e0" ] && [ "$(n_starts 7)" = "$g0" ] && ok "d, e and g were not revived" || bad "starts d=$(n_starts 4) e=$(n_starts 5) g=$(n_starts 7)"
grep -q "'sala-test-d' is retired in the session registry — left alone" "$WLOG" && ok "d: logged as retired in the registry" || bad "log: $(grep -c . "$WLOG") lines; $(grep sala-test-d "$WLOG" | tail -3)"
[ "$(n_starts 6)" = "$f0" ] && [ "$(nposts 'whose claude had died')" = 2 ] && ok "f (with its claude) untouched; no further post" || bad "f=$(n_starts 6), posts: $(<"$POSTS")"

echo "== SALA_NO_RELAUNCH: a session managed outside sala is not revived"
killfake sala-test-f; waitfor '! hasclaude f' 40
export SALA_NO_RELAUNCH=sala-test-f; tick; sleep 5; tick; unset SALA_NO_RELAUNCH
! hasclaude f && [ "$(n_starts 6)" = "$f0" ] && ok "f stays bare while it is listed" || bad "f: starts $(n_starts 6)"

echo "== a recycle lock held: nothing is revived and the clocks start over"
( flock 9; sleep 24 ) 9>>"$LOCK" & LOCKPID=$!
waitfor 'recycle_locked' 40 || bad "the lock was not taken"
tick; sleep 5; tick
! hasclaude f && [ "$(n_starts 6)" = "$f0" ] && grep -q 'skip: a resurrect restore or a salamander revive is running' "$WLOG" && ! grep -q '^bare\.' "$ST" && ok "f untouched past the grace, watch's busy skip in the log, no clock kept" || bad "f starts $(n_starts 6); $(tail -4 "$WLOG"); state $(grep bare "$ST")"
wait "$LOCKPID" 2>/dev/null; LOCKPID=""
tick
! hasclaude f && [ "$(n_starts 6)" = "$f0" ] && grep -q "^bare.sala-test-f=" "$ST" && ok "the lock gone: a fresh clock, not revived on the first tick" || bad "after the lock: f starts $(n_starts 6); $(tail -3 "$WLOG")"
sleep 5; tick
waitfor 'hasclaude f' 40 && [ "$(n_starts 6)" = "$((f0 + 1))" ] && ok "revived once the grace passed after the lock" || bad "f: $(tail -6 "$WLOG")"

echo "== a pane revive cannot bring back (its resume dies): SALA_BARE_TRIES tries, one 'could not revive' post, then left"
killfake sala-test-h; waitfor '! hasclaude h' 40
tick; sleep 5; tick; sleep 2; tick; sleep 2; tick; sleep 2; tick
[ "$(n_starts 8)" -le "$((h0 + 2))" ] && [ "$(wlogn "bare panes: reviving 1 — sala-test-h")" = 2 ] && ok "tried exactly twice" || bad "h starts $(n_starts 8) (was $h0); revive lines $(wlogn "bare panes: reviving 1 — sala-test-h"); $(tail -8 "$WLOG")"
[ "$(nposts 'could not revive')" = 1 ] && has "$(post 'could not revive')" "sala-test-h" && ok "one 'could not revive' post naming h" || bad "posts: $(<"$POSTS")"
! hasclaude h && ok "h is left bare" || bad "h has a claude?"

echo "== SALA_BARE_REVIVE=off revives nothing"
killfake sala-test-b; waitfor '! hasclaude b' 40
b1=$(n_starts 2); export SALA_BARE_REVIVE=off; tick; sleep 5; tick; unset SALA_BARE_REVIVE
! hasclaude b && [ "$(n_starts 2)" = "$b1" ] && ok "b stays bare with the switch off" || bad "b: $(n_starts 2) vs $b1"
tick; sleep 5; tick
waitfor 'hasclaude b' 40 && ok "and is revived with it back on (the clock restarted)" || bad "b: $(tail -5 "$WLOG")"

[ "$fail" = 0 ] && echo "barepane: pass" || echo "barepane: FAIL"
exit $fail
