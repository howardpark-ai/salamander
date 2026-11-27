#!/usr/bin/env bash
# The end of a hold without a relaunch (lib/common.sh `hold_ended`), and which claude is the pane's own (`claude_pid_under`,
# `relaunched_from`). Checked:
#   - a claude that a claude started is never the pane's, whatever order the pids come in (pids wrap); two real processes named claude;
#   - "relaunched meanwhile" needs the old pid gone: a deferred row whose recorded claude still runs is kept, a dead one drops;
#   - hold_ended: the flag down and ONE note for the session that was told, handed over once; nothing for a session not told, for one
#     that was relaunched, or while another sala process holds the flag; the deferred wording says sala still relaunches it;
#   - the hooks remember who was told (the waiting line and a refused call);
#   - each ending says so once: watch's drops (no-relaunch, 8 days, already current), a try that did not go through, a flag whose owner
#     is gone, a sweep that leaves the pane, the retry window running out;
#   - silent: a relaunch that worked, and a newer recycle taking the pane over.
# Slack stubbed to a file (SALA_NOTIFY_CMD). Isolated HOME (locked while the suite runs), a private tmux socket, the compiled fake claude
# (tests/fake-claude.c); the nested-claude check uses copies of bash named claude. Only processes running one of those two binaries are
# ever killed.
# Usage: bash tests/holdend.sh   (exit 0 = pass)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_STATE_DIR SALA_LOG_DIR SALA_SET SALA_SET_SELF SALA_POST_RECYCLE_CMD SALA_RECYCLE SALA_RETRY_WORKER SALA_DEFERRED_TRY SALA_LATER_LIMIT SALA_LATER_RETELL SALA_LATER_RETELL_MAX SALA_NO_RELAUNCH SALA_DRAIN
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, tmux_socket_rm
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
exec {HOMELK}< "$HOME" && flock -n "$HOMELK"   # held while the suite runs: tmpfiles ageing leaves the folder alone
SOCK="sala-holdend-$$"; T="tmux -L $SOCK -f /dev/null"; FAKE="$HOME/.local/share/claude/versions/9.9.9"; NEST="$HOME/nest/claude"
cleanup() {
    local p; $T kill-server 2>/dev/null; tmux_socket_rm
    # a retry worker ends by itself once its panes are gone; wait for it before its HOME goes
    waitfor '! compgen -G "$HOME/.claude/salamander-retry*.pid" >/dev/null' 40
    for p in /proc/[0-9]*; do { [ "$FAKE" -ef "$p/exe" ] || [ "$NEST" -ef "$p/exe" ]; } && kill -9 "${p#/proc/}" 2>/dev/null; done
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
as_op_unit
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$HOME/.local/share/claude/versions" "$HOME/nest"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
cc -o "$FAKE" "$ROOT/tests/fake-claude.c" || exit 1
ln -s "$FAKE" "$HOME/.local/bin/claude"; cp "$(command -v bash)" "$NEST"
printf '#!/bin/sh\necho "$*" >> "%s/systemd-run.txt"\n' "$HOME" > "$HOME/.local/bin/systemd-run"; chmod +x "$HOME/.local/bin/systemd-run"   # watch launches nothing
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log" FAKE_SOCK_LOG="$HOME/sock.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="{ cat; echo '%%'; } >> $POSTS"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off SALA_PAUSE_AFTER=0
SALA="$ROOT/bin/salamander"; WLOG="$HOME/.claude/salamander-watch.log"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux
. "$ROOT/lib/common.sh"
NOTES="$SALA_LOG_DIR/salamander-notes.tsv"; NARCH="$SALA_LOG_DIR/salamander-notes-archive.jsonl"

echo "== the pane's own claude: one a claude started is never it, whatever its number"
mkfifo "$HOME/hang"
# outer claude → inner claude; both wait on a pipe nothing writes to (no other process under them)
"$NEST" -c '"$1" -c "echo \$\$ > \"\$1\"; read -r -t 600 _ <> \"\$2\"; :" _ "$2" "$3" & wait' _ "$NEST" "$HOME/inner.pid" "$HOME/hang" &
OUTER=$!
waitfor '[ -s "$HOME/inner.pid" ]' 40; INNER=$(<"$HOME/inner.pid")
claude_alive "$OUTER" && claude_alive "$INNER" && [ "$(proc_ppid "$INNER" | tr -d ' ')" = "$OUTER" ] && ok "two processes named claude, one under the other" || bad "setup: outer=$OUTER inner=$INNER"
[ "$(pids_under $$ "$INNER" "$OUTER" | head -1)" = "$INNER" ] && ok "(the first descendant in pid order would be the inner one)" || bad "setup: pids_under"
[ "$(_own_claude_under $$ "$INNER" "$OUTER")" = "$OUTER" ] && ok "the inner pid listed first (a lower number): the outer one is returned" || bad "inner first: $(_own_claude_under $$ "$INNER" "$OUTER")"
[ "$(_own_claude_under $$ "$OUTER" "$INNER")" = "$OUTER" ] && ok "the outer pid listed first: the same" || bad "outer first"
[ "$(_own_claude_under "$OUTER" "$INNER" "$OUTER")" = "$OUTER" ] && ok "the root itself being a claude: it is the one" || bad "root: $(_own_claude_under "$OUTER" "$INNER" "$OUTER")"
[ "$( _claude_pids_r() { printf -v "$1" '%s' "$INNER"$'\n'"$OUTER"; }; claude_pid_under $$ )" = "$OUTER" ] && ok "claude_pid_under with the inner pid lower: the outer one" || bad "claude_pid_under"
_own_claude_under "$INNER" "$OUTER" >/dev/null && bad "a claude above the root was returned" || ok "none under the root: status 1"
# nearest the root: a claude two steps down that started first loses to one a step down; two a step down: the one that started first
"$BASH" -c '"$1" -c "read -r -t 600 _ <> \"\$1\"; :" _ "$2" & echo "$!" > "$3"; wait' _ "$NEST" "$HOME/hang" "$HOME/deep.pid" 2>/dev/null &
WRAP=$!; waitfor '[ -s "$HOME/deep.pid" ] && claude_alive "$(<"$HOME/deep.pid")"' 40; DEEP=$(<"$HOME/deep.pid"); sleep 0.2
"$NEST" -c 'read -r -t 600 _ <> "$1"; :' _ "$HOME/hang" & FIRST=$!; sleep 0.2
"$NEST" -c 'read -r -t 600 _ <> "$1"; :' _ "$HOME/hang" & SECOND=$!
waitfor 'claude_alive "$FIRST" && claude_alive "$SECOND"' 40 || bad "setup: first=$FIRST second=$SECOND"
[ "$(_own_claude_under $$ "$DEEP" "$FIRST")" = "$FIRST" ] && [ "$(_own_claude_under $$ "$FIRST" "$DEEP")" = "$FIRST" ] && ok "the nearer one is returned, though the deeper one started first and is listed first" || bad "depth: deep=$DEEP first=$FIRST got $(_own_claude_under $$ "$DEEP" "$FIRST")"
[ "$(_own_claude_under $$ "$SECOND" "$FIRST")" = "$FIRST" ] && [ "$(_own_claude_under $$ "$FIRST" "$SECOND")" = "$FIRST" ] && ok "same depth: the one that started first, in either order" || bad "tie: first=$FIRST second=$SECOND got $(_own_claude_under $$ "$SECOND" "$FIRST")"
[ "$( _claude_pids_r() { printf -v "$1" '%s' "$SECOND"$'\n'"$DEEP"$'\n'"$FIRST"; }; claude_pid_under $$ )" = "$FIRST" ] && ok "claude_pid_under over all three: the nearest, earliest one" || bad "claude_pid_under, three"
for p in "$DEEP" "$FIRST" "$SECOND"; do [ "$NEST" -ef "/proc/$p/exe" ] && kill -9 "$p"; done; wait "$WRAP" "$FIRST" "$SECOND" 2>/dev/null

echo "== relaunched_from: only once the old process is gone"
relaunched_from "$OUTER" "$INNER" && bad "a second claude while the first runs counted as a relaunch" || ok "old pid alive, another pid: not a relaunch"
relaunched_from "$OUTER" "$OUTER" && bad "the same pid counted" || ok "the same pid: not a relaunch"
sleep 0 & GONE=$!; wait "$GONE"
relaunched_from "$GONE" "$OUTER" && ok "old pid gone, another claude in the pane: relaunched" || bad "a dead old pid not counted"
relaunched_from "$GONE" "" && bad "no claude at all counted as a relaunch" || ok "no claude now: not a relaunch"

echo "== the hooks remember who was told"
U9=$(uuid 9); waiting_raise "$U9" recycle set-9 $$
printf '{"session_id":"%s","tool_name":"Read","tool_input":{}}' "$U9" > "$HOME/post.json"
"$NEST" -c 'echo $$ > "$3"; echo "{}" > "$HOME/.claude/sessions/$$.json"; "$1" hook post-tool < "$2" > /dev/null; :' _ "$SALA" "$HOME/post.json" "$HOME/hookpid"
[ "$(_kv_first "$SALA_HELD_DIR/$U9" pid)" = "$(<"$HOME/hookpid")" ] && [ "$(_kv_first "$SALA_HELD_DIR/$U9" set)" = set-9 ] && ok "the waiting line told: the record holds that claude's pid and the set" || bad "post-tool record: $(cat "$SALA_HELD_DIR/$U9" 2>&1)"
rm -f "$SALA_HELD_DIR/$U9" "$HOME/.claude/sessions/$(<"$HOME/hookpid").json"
printf '{"session_id":"%s","tool_name":"Monitor","tool_input":{"command":"x"}}' "$U9" > "$HOME/pre.json"
out=$("$NEST" -c 'echo $$ > "$3"; echo "{}" > "$HOME/.claude/sessions/$$.json"; "$1" hook pre-tool < "$2"; :' _ "$SALA" "$HOME/pre.json" "$HOME/hookpid")
[[ $out == *'"deny"'* ]] && [ "$(_kv_first "$SALA_HELD_DIR/$U9" pid)" = "$(<"$HOME/hookpid")" ] && ok "a refused call: the same record" || bad "pre-tool: $out / $(cat "$SALA_HELD_DIR/$U9" 2>&1)"
hold_prune; [ ! -e "$SALA_HELD_DIR/$U9" ] && ok "the record of a process that is gone is pruned" || bad "not pruned"
waiting_clear_all; rm -f "$HOME/.claude/sessions/$(<"$HOME/hookpid").json"
for p in "$INNER" "$OUTER"; do [ "$NEST" -ef "/proc/$p/exe" ] && kill -9 "$p"; done; wait "$OUTER" 2>/dev/null

mk() { local n="$1" u="$2"; shift 2; $T new-session -d -s "sala-test-$n" -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="$n" -e FAKE_LOG="$FAKE_LOG" -e FAKE_SOCK_LOG="$FAKE_SOCK_LOG" "$@"; $T send-keys -t "sala-test-$n" 'claude' Enter; }
setstatus() { sed -i "s/\"status\":\"[a-z]*\"/\"status\":\"$2\"/" "$HOME/.claude/sessions/$(cpid "$1").json"; }   # <name> <status>
nhold() { local n=0 f; for f in "$NOTES" "$NARCH"; do [ -r "$f" ] && n=$((n + $(grep -F "$1" "$f" | grep -cF '[hold] '))); done; echo "$n"; }   # <uuid> → hold notes written, delivered or not
htext() { cat "$NOTES" "$NARCH" 2>/dev/null | grep -F "$1" | grep -F '[hold] '; }
nsock() { grep -c "^$1 .*\[sala note " "$FAKE_SOCK_LOG" 2>/dev/null || true; }
reset() { rm -rf "$SALA_WAITING_DIR" "$SALA_HELD_DIR" "$SALA_PAUSE_DIR"; rm -f "$SALA_DEFERRED" "$NOTES" "$NARCH"; : > "$FAKE_SOCK_LOG"; : > "$POSTS"; }
told() { waiting_raise "$2" recycle "${3:-set-t}" "${4:-$$}"; hold_told "$2" "$(cpid "$1")" "sala-test-$1"; }   # <name> <uuid> [set] [owner] — as a hook does it
watch_tick() { "$SALA" watch >/dev/null 2>&1; }
row() {  # <name> <held s> <force> [old pid] — a deferred row, told once already unless told_n is zeroed by the caller
    local now; now=$(date +%s)
    printf '%s\t%s\t%s\t%s\t%s\t-\t%s\t%s\t%s\n' "sala-test-$1" "$((now - $2))" "background work is running" "${4:-$(cpid "$1")}" "$3" "$now" 1 "$now" > "$SALA_DEFERRED"
}
A=$(uuid 31); B=$(uuid 32)
mk a "$A"; mk b "$B"; fake_up a b || exit 1

echo "== hold_ended: the flag down and one note, delivered once"
reset; AP=$(cpid a); told a "$A"
mkdir -p "$SALA_PAUSE_DIR"; echo "1 2" > "$SALA_PAUSE_DIR/$A.wait"; echo "1 2" > "$SALA_PAUSE_DIR/$A.failed"; printf 'at=%s\npid=%s\n' "$(date +%s)" "$AP" > "$SALA_PAUSE_DIR/$A.paused"
hold_ended "$A" ended "the test says so"
[ ! -e "$SALA_WAITING_DIR/$A" ] && [ ! -e "$SALA_HELD_DIR/$A" ] && ok "the flag and the record are gone" || bad "left: $(ls "$SALA_WAITING_DIR" "$SALA_HELD_DIR" 2>&1)"
[ ! -e "$SALA_PAUSE_DIR/$A.wait" ] && [ ! -e "$SALA_PAUSE_DIR/$A.failed" ] && [ ! -e "$SALA_PAUSE_DIR/$A.paused" ] && ok "the pause's clock, failed tries and marker are cleared" || bad "pause: $(ls "$SALA_PAUSE_DIR")"
[ "$(nhold "$A")" = 1 ] && htext "$A" | grep -q 'ended without relaunching it: the test says so. The hold is over: you may start background' && ok "one note: ended, why, free to start background work" || bad "note: $(htext "$A")"
hold_ended "$A" ended "again"; [ "$(nhold "$A")" = 1 ] && ok "a second ending writes nothing" || bad "twice: $(htext "$A")"
"$SALA" note --deliver >/dev/null 2>&1
waitfor '[ "$(nsock "$A")" = 1 ]' 20 && grep -q "^$A .*ended without relaunching it.*delivered once" "$FAKE_SOCK_LOG" && ok "delivered to the same process at once" || bad "not delivered: $(<"$FAKE_SOCK_LOG")"
"$SALA" note --deliver >/dev/null 2>&1; sleep 1
[ "$(nsock "$A")" = 1 ] && [ ! -s "$NOTES" ] && grep -q 'sala (delivered once)' "$NARCH" && ok "and retired: never again" || bad "again: sock=$(nsock "$A") store=$(<"$NOTES")"
grep -q 'a relaunch hold ended' "$SALA_LOG_DIR/salamander-notes.log" && ok "the note log says why it was left" || bad "log: $(<"$SALA_LOG_DIR/salamander-notes.log")"

echo "== who gets no note"
reset; waiting_raise "$A" recycle s $$; hold_ended "$A" ended x
[ ! -e "$SALA_WAITING_DIR/$A" ] && [ "$(nhold "$A")" = 0 ] && ok "a session never told: flag down, no note" || bad "untold: $(htext "$A")"
reset; told a "$A" s "$PPID"; hold_ended "$A" ended x
[ -e "$SALA_WAITING_DIR/$A" ] && [ -e "$SALA_HELD_DIR/$A" ] && [ "$(nhold "$A")" = 0 ] && ok "another sala process holds the flag: untouched, no note" || bad "other owner: $(ls "$SALA_WAITING_DIR") $(htext "$A")"
reset; waiting_raise "$A" recycle s $$; hold_told "$A" "$GONE" sala-test-a; hold_ended "$A" ended x
[ "$(nhold "$A")" = 0 ] && ok "the told process is gone (relaunched): no note" || bad "relaunched: $(htext "$A")"
reset; told a "$A"; hold_ended "$A" ended x; sed -i "s/\t$(cpid a)\t/\t$GONE\t/" "$NOTES"; "$SALA" note --deliver >/dev/null 2>&1; sleep 1
[ "$(nsock "$A")" = 0 ] && [ ! -s "$NOTES" ] && grep -q 'not delivered' "$NARCH" && ok "a note whose process is gone by delivery: retired, not delivered" || bad "stale: sock=$(nsock "$A") store=$(<"$NOTES")"

echo "== deferred or ended"
reset; told a "$A"; mkdir -p "$SALA_PAUSE_DIR"; echo "1 2" > "$SALA_PAUSE_DIR/$A.wait"; hold_ended "$A" deferred "it holds background work"
htext "$A" | grep -q 'is deferred: it holds background work. This session has not been relaunched. You may start background.*sala still relaunches this session later.*raised again' && ok "deferred: may start work now, relaunched later, a raised flag will say so" || bad "deferred: $(htext "$A")"
[ -e "$SALA_PAUSE_DIR/$A.wait" ] && ok "a deferred pane keeps its pause clock" || bad "clock gone"
reset; told a "$A"; row a 100 1; hold_ended "$A" ended x
htext "$A" | grep -q 'is deferred: x' && ok "ended, with the pane on the deferred list: worded as deferred" || bad "listed: $(htext "$A")"
reset; told a "$A"; row a 100 1; hold_ended "$A" dropped x
htext "$A" | grep -q 'ended without relaunching it: x' && ok "dropped from the list: worded as ended" || bad "dropped: $(htext "$A")"

echo "== a relauncher stops; a flag's owner is gone; a set ends"
reset; told a "$A" s; told b "$B" s "$PPID"; waiting_end_owner $$
[ "$(nhold "$A")" = 1 ] && [ "$(nhold "$B")" = 0 ] && [ -e "$SALA_WAITING_DIR/$B" ] && ok "waiting_end_owner: its own flags only" || bad "owner: a=$(nhold "$A") b=$(nhold "$B")"
reset; told a "$A" s "$GONE"; watch_tick
[ ! -e "$SALA_WAITING_DIR/$A" ] && [ "$(nhold "$A")" = 1 ] && htext "$A" | grep -q 'process that was waiting to relaunch it is gone' && ok "watch: a dead owner's flag comes down with one note" || bad "prune: $(htext "$A")"
reset; told a "$A" reboot-7; waiting_clear_owner $$; hold_end_set reboot-8 x; [ "$(nhold "$A")" = 0 ] || bad "another set's end spoke"
hold_end_set reboot-7 "the reboot was halted"; hold_end_set reboot-7 "the reboot was halted"
[ "$(nhold "$A")" = 1 ] && ok "hold_end_set: that set's told sessions, once, flag already down or not" || bad "set: $(nhold "$A")"

echo "== watch: a deferred row whose recorded claude still runs is not \"relaunched\""
reset; setstatus a shell; AP=$(cpid a); row a 100 1 "$(cpid b)"; : > "$WLOG"
watch_tick
grep -q '^sala-test-a	' "$SALA_DEFERRED" && ! grep -q 'relaunched meanwhile' "$WLOG" && [ "$(cpid a)" = "$AP" ] && ok "old pid alive: the row stays" || bad "dropped: $(grep deferred "$WLOG")"
row a 100 0 "$GONE"; setstatus a idle; : > "$WLOG"; watch_tick
grep -q 'sala-test-a relaunched meanwhile' "$WLOG" && [ ! -s "$SALA_DEFERRED" ] && ok "old pid gone: relaunched meanwhile, dropped" || bad "kept: $(grep deferred "$WLOG")"

echo "== the retry worker: a pane whose recorded claude still runs is not \"relaunched\""
O=$(uuid 34); mk o "$O"; fake_up o || exit 1
reset; setstatus a busy; AP=$(cpid a); OP=$(cpid o); WKL="$HOME/worker.log"; : > "$WKL"
SALA_RETRY_EVERY=1 SALA_RETRY_WINDOW=120 setsid "$SALA" revive --retry-worker --force -- "$(tmux display -p -t sala-test-a '#{pane_id}')|sala-test-a|sala-test-a:0|$OP" </dev/null >> "$WKL" 2>&1 &
waitfor 'grep -qE "sala-test-a:0: still skipped|already relaunched" "$WKL"' 80
grep -q 'sala-test-a:0: still skipped' "$WKL" && ! grep -q 'already relaunched' "$WKL" && ok "old pid alive: the worker keeps waiting for the pane" || bad "worker: $(<"$WKL")"
[ "$FAKE" -ef "/proc/$OP/exe" ] && kill -9 "$OP"
waitfor 'grep -q "already relaunched" "$WKL" && ! compgen -G "$SALA_LOG_DIR/salamander-retry*.pid" >/dev/null' 80
grep -qF "already relaunched (pid $OP → $AP)" "$WKL" && ok "old pid gone: relaunched meanwhile" || bad "worker, old gone: $(<"$WKL")"
$T kill-session -t sala-test-o; setstatus a idle

echo "== watch: each drop ends the hold with one note"
reset; setstatus a shell; told a "$A" s "$(cpid a)"; row a 100 1
SALA_NO_RELAUNCH=sala-test-a watch_tick
[ ! -e "$SALA_WAITING_DIR/$A" ] && [ "$(nhold "$A")" = 1 ] && htext "$A" | grep -q 'ended without relaunching it: sala is now set never to relaunch it' && ok "no-relaunch: flag down, one note" || bad "norelaunch: flag=$(ls "$SALA_WAITING_DIR") $(htext "$A")"
reset; told a "$A" s "$(cpid a)"; row a 700000 1; watch_tick
[ ! -e "$SALA_WAITING_DIR/$A" ] && [ "$(nhold "$A")" = 1 ] && htext "$A" | grep -q 'held for 8 days' && ok "8 days: flag down, one note" || bad "8 days: $(htext "$A")"
reset; setstatus a idle; told a "$A" s "$(cpid a)"; row a 100 0; watch_tick
[ ! -e "$SALA_WAITING_DIR/$A" ] && [ "$(nhold "$A")" = 1 ] && htext "$A" | grep -q 'already on the current version' && ok "already current: flag down, one note" || bad "current: $(htext "$A")"

echo "== watch: a relaunch that works is silent"
reset; AP=$(cpid a); told a "$A" s "$AP"; row a 100 1; watch_tick
waitfor '[ -n "$(cpid a)" ] && [ "$(cpid a)" != "$AP" ]' 40 && [ ! -s "$SALA_DEFERRED" ] && [ ! -e "$SALA_WAITING_DIR/$A" ] && [ "$(nhold "$A")" = 0 ] && ok "relaunched: row and flag gone, no note" || bad "success: $(grep deferred "$WLOG" | tail -3) $(htext "$A")"

echo "== watch: a try that does not go through says the pane is still deferred"
C=$(uuid 33); mk c "$C" -e FAKE_IGNORE_EXIT=1; fake_up c || exit 1
reset; CP=$(cpid c); told c "$C" s "$CP"; row c 100 1; SALA_EXIT_END=0 watch_tick
[ "$(cpid c)" = "$CP" ] && grep -q '^sala-test-c	' "$SALA_DEFERRED" && [ ! -e "$SALA_WAITING_DIR/$C" ] && [ "$(nhold "$C")" = 1 ] && htext "$C" | grep -q 'is deferred: a try to relaunch it did not go through' && ok "still there, on the list, told it is deferred" || bad "try: flag=$(ls "$SALA_WAITING_DIR") $(htext "$C") $(grep deferred "$WLOG" | tail -3)"
$T kill-session -t sala-test-c

echo "== a sweep that leaves a told pane says so"
reset; told a "$A" s "$GONE"
"$SALA" revive --only sala-test-a > "$HOME/sweep.out" 2>&1
[ ! -e "$SALA_WAITING_DIR/$A" ] && [ "$(nhold "$A")" = 1 ] && htext "$A" | grep -q 'already on the current version' && ok "revive --only on a current pane: one note" || bad "sweep: $(htext "$A") $(<"$HOME/sweep.out")"

echo "== the retry worker: a newer recycle is silent, the window running out is not"
reset; setstatus b busy
export SALA_RETRY_EVERY=1 SALA_RETRY_WINDOW=600
"$SALA" revive --only sala-test-b --force > "$HOME/sweep.out" 2>&1
waitfor '[ -e "$SALA_WAITING_DIR/$B" ]' 40 || bad "no worker flag: $(<"$HOME/sweep.out")"
W1=$(_kv_first "$SALA_WAITING_DIR/$B" owner); hold_told "$B" "$(cpid b)" sala-test-b
SALA_RETRY_WINDOW=15 SALA_RECYCLE=1 "$SALA" revive --force > "$HOME/recycle.out" 2>&1
waitfor 'o=$(_kv_first "$SALA_WAITING_DIR/$B" owner); [ -n "$o" ] && [ "$o" != "$W1" ]' 40
o=$(_kv_first "$SALA_WAITING_DIR/$B" owner)
[ -n "$o" ] && [ "$o" != "$W1" ] && ! kill -0 "$W1" 2>/dev/null && [ "$(nhold "$B")" = 0 ] && [ -e "$SALA_HELD_DIR/$B" ] && ok "the newer recycle stopped the old worker and raised the flag again: no note, still remembered" || bad "supersede: old=$W1 new=$o $(htext "$B") $(<"$HOME/recycle.out")"
waitfor '[ "$(nhold "$B")" -ge 1 ]' 80
[ "$(nhold "$B")" = 1 ] && htext "$B" | grep -q 'is deferred: the retry window ended with it still held' && [ ! -e "$SALA_WAITING_DIR/$B" ] && grep -q '^sala-test-b	' "$SALA_DEFERRED" && ok "window end: deferred, flag down, one note" || bad "window: $(htext "$B") $(tail -5 "$SALA_LOG_DIR/salamander-revive.log" 2>/dev/null)"
waitfor '! compgen -G "$SALA_LOG_DIR/salamander-retry*.pid" >/dev/null' 40; [ "$(nhold "$B")" = 1 ] && ok "the worker's exit adds nothing" || bad "exit: $(htext "$B")"
rm -f "$SALA_DEFERRED"
reset; BP=$(cpid b); setstatus b busy
SALA_RETRY_WINDOW=600 "$SALA" revive --only sala-test-b --force > "$HOME/sweep.out" 2>&1
waitfor '[ -e "$SALA_WAITING_DIR/$B" ]' 40; hold_told "$B" "$BP" sala-test-b; setstatus b idle
waitfor '[ -n "$(cpid b)" ] && [ "$(cpid b)" != "$BP" ] && ! compgen -G "$SALA_LOG_DIR/salamander-retry*.pid" >/dev/null' 80 && [ "$(nhold "$B")" = 0 ] && [ ! -e "$SALA_WAITING_DIR/$B" ] && ok "the worker relaunched it: no note" || bad "worker success: $(htext "$B") $(tail -5 "$SALA_LOG_DIR/salamander-revive.log" 2>/dev/null)"
unset SALA_RETRY_EVERY SALA_RETRY_WINDOW

[ "$fail" = 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
