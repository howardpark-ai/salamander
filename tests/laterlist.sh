#!/usr/bin/env bash
# The later-relaunch list's limit (Thu Oct 22nd 2026; lib/watch.sh `later_held`, lib/common.sh `later_commands`):
# a pane on the deferred list that stays held is told again and, past a limit, named in one post. The clock is a fake one: the
# row's `since` and `told_at` fields are written as hours ago, so no test waits an hour. Checked, against a fake pane whose
# registry says 'shell' (the turn is over, a background shell runs) and a fake master that watch needs:
#   - held under an hour: nothing told, nothing posted, no state beyond zeroes in the row;
#   - held an hour: told again once (the waiting flag raised, the recycle's line pushed to the session's messaging socket and
#     marked as told so the hook does not say it twice), the count 1 in the row; a second watch tick right after: not again;
#   - the next hour, and the next: told a second and a third time; the fourth is never sent (SALA_LATER_RETELL_MAX);
#   - held past SALA_LATER_LIMIT: one post naming the pane, claude's version, how long, and the stuck command from the Stop
#     hook's record (a secret in the command line scrubbed, the command cut); the next tick posts nothing more;
#   - SALA_LATER_LIMIT is tunable from the environment (a short limit posts for a pane held only minutes);
#   - nothing is relaunched while the shells run, and nothing is given up: the row stays;
#   - the shells end: watch relaunches the pane, the row and the waiting flag are gone (a relaunched pane starts clean);
#   - a row from before the change (six fields, an empty set id) is read, kept and rewritten without losing the set id's place.
# Slack stubbed to a file (SALA_NOTIFY_CMD). Isolated HOME, a private tmux socket, the compiled fake claude (tests/fake-claude.c).
# Usage: bash tests/laterlist.sh   (exit 0 = pass)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_SET SALA_SET_SELF SALA_POST_RECYCLE_CMD SALA_RECYCLE SALA_RETRY_WORKER SALA_LATER_LIMIT SALA_LATER_RETELL SALA_LATER_RETELL_MAX
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, tmux_socket_rm
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
as_op_unit
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$HOME/.local/share/claude/versions/9.9.9" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
ln -s "$HOME/.local/share/claude/versions/9.9.9" "$HOME/.local/bin/claude"
printf '#!/bin/sh\necho "$*" >> "%s/systemd-run.txt"\n' "$HOME" > "$HOME/.local/bin/systemd-run"; chmod +x "$HOME/.local/bin/systemd-run"   # watch launches nothing
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log" FAKE_SOCK_LOG="$HOME/sock.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="{ cat; echo '%%'; } >> $POSTS"   # one post per record, '%%' between them
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off
SALA="$ROOT/bin/salamander"; SOCK="sala-later-$$"; T="tmux -L $SOCK -f /dev/null"; WLOG="$HOME/.claude/salamander-watch.log"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"
cleanup() {
    local p; $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    for p in $(pgrep -x claude); do [ "$HOME/.local/share/claude/versions/9.9.9" -ef "/proc/$p/exe" ] && kill -9 "$p" 2>/dev/null; done
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux
. "$ROOT/lib/common.sh"
mk() { local n="$1" u="$2"; shift 2; $T new-session -d -s "sala-test-$n" -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="$n" -e FAKE_LOG="$FAKE_LOG" -e FAKE_SOCK_LOG="$FAKE_SOCK_LOG" "$@"; $T send-keys -t "sala-test-$n" 'claude' Enter; }
setstatus() { sed -i "s/\"status\":\"[a-z]*\"/\"status\":\"$2\"/" "$HOME/.claude/sessions/$(cpid "$1").json"; }   # <name> <status>
npost() { awk -v RS='%%\n' -v h="$1" 'index($0, h) {n++} END {print n+0}' "$POSTS" 2>/dev/null; }
nsock() { grep -c "^$1 .*waiting for this session" "$FAKE_SOCK_LOG" 2>/dev/null || true; }   # <uuid> → how many times the recycle's line reached it
watch_tick() { SALA_MASTER=sala-test-mm "$SALA" watch >/dev/null 2>&1; }
field() { awk -F'\t' -v s="$1" -v n="$2" '$1==s {print $n}' "$SALA_DEFERRED"; }     # <session> <column> of its row
fake_row() {  # <session> <held s> <told_at s ago or 0> <told_n> <posted 0|1> [set id] — a row as the clock would have left it
    local now; now=$(date +%s)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$((now - $2))" "said ready, but background shell(s) are still running (registry state 'shell')" "$(cpid "${1#sala-test-}")" 1 "${6:--}" \
        "$([ "$3" = 0 ] && echo 0 || echo $((now - $3)))" "$4" "$([ "$5" = 1 ] && echo "$now" || echo 0)" > "$SALA_DEFERRED"
}
mk lt "$(uuid 21)"; mk mm "$(uuid 22)"; fake_up lt mm
U=$(uuid 21); LP=$(cpid lt); setstatus lt shell
# the Stop hook's record for this idle stretch: one background shell with a command line holding a secret, as the hook writes it
mkdir -p "$SALA_BUSY_DIR"; STAMP=$(registry_field "$LP" statusUpdatedAt)
printf 'id=1-1\nepoch=%s\nseen=%s\nseen_status=idle\nflip=%s\ntasks=1\ncrons=0\ntask=shell running: until loop (until grep -q DONE /tmp/never-written; do sleep 3; done --token=s3cr3tvalue99)\n' "$(date +%s)" "$STAMP" "$STAMP" > "$SALA_BUSY_DIR/$U"
: > "$POSTS"; : > "$FAKE_SOCK_LOG"; rm -f "$SALA_DEFERRED"

echo "== held under an hour: nothing told, nothing posted"
fake_row sala-test-lt 600 0 0 0
watch_tick
[ "$(nsock "$U")" = 0 ] && [ ! -e "$SALA_WAITING_DIR/$U" ] && [ "$(npost 'not relaunched after')" = 0 ] && ok "10 min held: no tell, no flag, no post" || bad "told early: sock=$(<"$FAKE_SOCK_LOG") posts=$(<"$POSTS")"
[ "$(field sala-test-lt 8)" = 0 ] && [ "$(field sala-test-lt 9)" = 0 ] && [ "$(cpid lt)" = "$LP" ] && ok "the row stays with its counters at zero; the pane was not relaunched" || bad "row: $(<"$SALA_DEFERRED")"

echo "== held an hour: told again once, and not twice"
fake_row sala-test-lt 3700 0 0 0
watch_tick
waitfor '[ "$(nsock "$U")" = 1 ]' 20 && ok "the recycle's line reached the idle session's socket (a held session runs no tool call for the hook)" || bad "no push: $(<"$FAKE_SOCK_LOG"); $(grep deferred "$WLOG" | tail -3)"
[ -e "$SALA_WAITING_DIR/$U" ] && [ -e "$SALA_WAITING_DIR/$U.told" ] && ok "the waiting flag is raised and marked told (the hook will not say it a second time)" || bad "flag: $(ls "$SALA_WAITING_DIR" 2>&1)"
[ "$(field sala-test-lt 8)" = 1 ] && [ "$(field sala-test-lt 7)" -gt 0 ] && ok "the row counts one tell, with its time" || bad "row: $(<"$SALA_DEFERRED")"
watch_tick; sleep 1
[ "$(nsock "$U")" = 1 ] && [ "$(field sala-test-lt 8)" = 1 ] && ok "a second tick right after: not told again" || bad "told twice: sock=$(nsock "$U") row=$(<"$SALA_DEFERRED")"
[ "$(npost 'not relaunched after')" = 0 ] && ok "no post yet (an hour is not the limit)" || bad "posted early: $(<"$POSTS")"

echo "== the next hours: a second and a third tell, never a fourth"
fake_row sala-test-lt 7300 3700 1 0; watch_tick
waitfor '[ "$(nsock "$U")" = 2 ]' 20 && [ "$(field sala-test-lt 8)" = 2 ] && ok "an hour after the first: told a second time" || bad "second: sock=$(nsock "$U") row=$(<"$SALA_DEFERRED")"
fake_row sala-test-lt 10000 3700 2 0; watch_tick
waitfor '[ "$(nsock "$U")" = 3 ]' 20 && [ "$(field sala-test-lt 8)" = 3 ] && ok "and a third time" || bad "third: sock=$(nsock "$U") row=$(<"$SALA_DEFERRED")"
fake_row sala-test-lt 10200 3700 3 0; watch_tick; sleep 1
[ "$(nsock "$U")" = 3 ] && [ "$(field sala-test-lt 8)" = 3 ] && ok "the fourth is not sent (SALA_LATER_RETELL_MAX)" || bad "fourth: sock=$(nsock "$U") row=$(<"$SALA_DEFERRED")"
fake_row sala-test-lt 10000 1800 1 0; watch_tick; sleep 1
[ "$(nsock "$U")" = 3 ] && [ "$(field sala-test-lt 8)" = 1 ] && ok "told 30 min ago: not yet due again" || bad "early re-tell: sock=$(nsock "$U") row=$(<"$SALA_DEFERRED")"
[ "$(npost 'not relaunched after')" = 0 ] && ok "still no post below the limit (3 h)" || bad "posted early: $(<"$POSTS")"

echo "== held past the limit: one post, once only"
fake_row sala-test-lt 11000 3700 3 0; watch_tick
waitfor '[ "$(npost "not relaunched after")" = 1 ]' 20 && ok "one post" || bad "posts: $(npost 'not relaunched after'): $(<"$POSTS")"
P=$(post 'not relaunched after')
grep -q 'sala-test-lt' <<< "$P" && ok "it names the pane" || bad "no pane: $P"
grep -q '3 h 3 min' <<< "$P" && ok "it says how long (3 h 3 min)" || bad "no duration: $P"
grep -q 'claude 9.9.9' <<< "$P" && ok "it gives claude's version" || bad "no version: $P"
grep -q 'sala [0-9a-f]\{7,\}' <<< "$P" && ok "and sala's revision" || bad "no sala revision: $P"
grep -q 'until grep -q DONE /tmp/never-written' <<< "$P" && ok "it shows the command holding the pane" || bad "no command: $P"
grep -q 's3cr3tvalue99' <<< "$P" && bad "a secret in the command line was posted: $P" || ok "the secret in that command line is masked"
[ "$(field sala-test-lt 9)" != 0 ] && ok "the row remembers the post" || bad "row: $(<"$SALA_DEFERRED")"
watch_tick; sleep 1; watch_tick; sleep 1
[ "$(npost 'not relaunched after')" = 1 ] && ok "later ticks post nothing more" || bad "posted again: $(npost 'not relaunched after')"
[ "$(cpid lt)" = "$LP" ] && grep -q "^sala-test-lt	" "$SALA_DEFERRED" && ok "the pane is still there, on the list, not relaunched and not given up" || bad "moved: $(<"$SALA_DEFERRED")"

echo "== SALA_LATER_LIMIT: tunable"
: > "$POSTS"; fake_row sala-test-lt 300 0 0 0
SALA_LATER_LIMIT=120 watch_tick
[ "$(npost 'not relaunched after')" = 1 ] && post 'not relaunched after' | grep -q '5 min' && ok "a 2 min limit posts for a pane held 5 min" || bad "limit not honoured: $(<"$POSTS")"

echo "== a row from before the change (six fields, an empty set id) is read and rewritten"
: > "$POSTS"; printf '%s\t%s\t%s\t%s\t%s\t\n' sala-test-lt "$(( $(date +%s) - 3800 ))" "background work is running" "$LP" 1 > "$SALA_DEFERRED"
watch_tick
waitfor '[ "$(nsock "$U")" = 4 ]' 20 && [ "$(field sala-test-lt 8)" = 1 ] && [ "$(field sala-test-lt 6)" = - ] && ok "told once; the empty set id kept its place as \"-\"" || bad "old row: sock=$(nsock "$U") $(<"$SALA_DEFERRED")"

echo "== the shells end: relaunched, and the state is gone with the row"
setstatus lt idle
rm -f "$SALA_BUSY_DIR/$U"   # the Stop hook's record said a shell; the next turn's would say none
fake_row sala-test-lt 3800 0 1 0
watch_tick
grep -q 'deferred: sala-test-lt relaunched' "$WLOG" && [ "$(cpid lt)" != "$LP" ] && ok "watch relaunched the pane" || bad "not relaunched: $(grep deferred "$WLOG" | tail -3)"
[ ! -s "$SALA_DEFERRED" ] && ok "the row (with its counters) is gone" || bad "row left: $(<"$SALA_DEFERRED")"
[ ! -e "$SALA_WAITING_DIR/$U" ] && [ ! -e "$SALA_WAITING_DIR/$U.told" ] && ok "the waiting flag it was told by is down" || bad "flag left: $(ls "$SALA_WAITING_DIR")"
[ "$(npost 'not relaunched after')" = 0 ] && ok "no limit post for a pane that came back (only the usual \"relaunched\" one)" || bad "post: $(<"$POSTS")"
[ "$fail" = 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
