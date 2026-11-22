#!/usr/bin/env bash
# SALA_PSET_TARGET (common.sh, pset_tell): a provision set's session/owner items go to the configured SALA_PSET_TARGET, a
# front agent, in its inbox with `[for Rowan]` on the first line of the text; with no target, or a target that is not
# live, they go out as one Slack post and count as told. A SALA_MASTER left in a config
# is not told anything. Checks, with two fake claudes in a private tmux server (the target, and a session that is still
# named SALA_MASTER; what reaches each one's messaging socket is read from FAKE_SOCK_LOG) and Slack stubbed to a file
# (SALA_NOTIFY_CMD): the target set and live → delivered, `[for Rowan]` first, no Slack post, the items told, told once; the
# target unset → the Slack post, the items told, nothing delivered; the target set but not live → the Slack post, the log
# naming the target; a live session named SALA_MASTER with no target hears nothing and the Slack post goes out; with both
# set only the target hears. State and the sets' log only: never the posts' wording. Isolated HOME, nothing real: no
# Slack, no real session.
# Usage: bash tests/pset-target.sh   (exit 0 = pass; ~15 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_SET SALA_PSET_WORKER SALA_PSET_TARGET
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
mkdir -p "$HOME/.claude/sessions" "$HOME/.local/bin" "$HOME/.local/share/claude/versions"
touch "$HOME/.claude/salamander-rc.stopped"
cc -o "$HOME/.local/share/claude/versions/9.9.9" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
ln -s "$HOME/.local/share/claude/versions/9.9.9" "$HOME/.local/bin/claude"
export PATH="$HOME/.local/bin:$PATH"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="{ cat; echo '%%'; } >> $POSTS"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AGENT_CHECK=off
SOCK="sala-psettarget-$$"; T="tmux -L $SOCK -f /dev/null"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"
MLOG="$HOME/leftover-inbox.log"; TLOG="$HOME/target-inbox.log"; : > "$MLOG"; : > "$TLOG"
cleanup() {
    local p; $T kill-server 2>/dev/null; tmux_socket_rm; sleep 0.5
    for p in $(pgrep -x claude); do [ "$HOME/.local/share/claude/versions/9.9.9" -ef "/proc/$p/exe" ] && kill -9 "$p" 2>/dev/null; done
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux
. "$ROOT/lib/common.sh"
nposts() { awk -v RS='%%\n' 'NF {n++} END {print n+0}' "$POSTS" 2>/dev/null; }
nin() { grep -c . "$1" 2>/dev/null || true; }                       # messages that reached a fake's socket (one line each)
echo 0 > "$HOME/last-id"
newset() {  # → a fresh provision set with one session item still to be told; its id on stdout
    local n id; n=$(( $(<"$HOME/last-id") + 1 )); echo "$n" > "$HOME/last-id"; id="$(date +%s)-$n"   # not a variable: this runs in $(…)
    set_create "$id" Provision t-host-a 1 0 1 1 "item=t-host-a|deny-rules|session|$(date +%s)|deny entries|missing" "tell=t-host-a|deny-rules"
    echo "$id"
}
reset() { : > "$POSTS"; : > "$MLOG"; : > "$TLOG"; : > "$SALA_PSET_LOG"; }

echo "== two fake claudes in a private tmux server: the target, and a session still named SALA_MASTER"
$T new-session -d -s sala-test-leftover -c "$HOME" -e FAKE_SESSION_ID=00000000-0000-4000-8000-0000000000aa -e FAKE_NAME=leftover -e FAKE_SOCK_LOG="$MLOG"; $T send-keys -t sala-test-leftover 'claude' Enter
$T new-session -d -s sala-test-target -c "$HOME" -e FAKE_SESSION_ID=00000000-0000-4000-8000-0000000000bb -e FAKE_NAME=target -e FAKE_SOCK_LOG="$TLOG"; $T send-keys -t sala-test-target 'claude' Enter
fake_up leftover target || { echo "the fakes did not start"; exit 1; }
ok "both fakes are up"

echo "== SALA_PSET_TARGET unset: the Slack post, the items told, nothing delivered"
reset; A=$(newset)
SALA_PSET_TARGET="" pset_tell "$A"
[ "$(nposts)" = 1 ] && ok "one Slack post" || bad "$(nposts) posts: $(<"$POSTS")"
[ "$(set_count "$A" tell)" = 0 ] && ok "the items count as told" || bad "tell left: $(set_vals "$A" tell)"
sleep 1; [ "$(nin "$MLOG")" = 0 ] && [ "$(nin "$TLOG")" = 0 ] && ok "nothing reached a session" || bad "leftover: $(<"$MLOG") target: $(<"$TLOG")"
grep -q 'posted to Slack instead' "$SALA_PSET_LOG" && ok "the sets' log says so" || bad "log: $(<"$SALA_PSET_LOG")"

echo "== target set and live: it gets the text, [for Rowan] first; no Slack post"
reset; A=$(newset)
SALA_PSET_TARGET=sala-test-target pset_tell "$A"
waitfor '[ "$(nin "$TLOG")" -ge 1 ]' 20
[ "$(nin "$TLOG")" = 1 ] && ok "exactly one message to the target" || bad "$(nin "$TLOG") messages: $(<"$TLOG")"
M=$(<"$TLOG")
grep -qF '"content": "[for Rowan]\n[sala provision] Provision ' <<< "$M" && ok "its first line is [for Rowan], the set's text follows" || bad "message: $M"
grep -qF "(set $A)" <<< "$M" && grep -qF 'sala provision --settle '"$A"' t-host-a deny-rules ok' <<< "$M" && ok "the body: the set, the item, the exact settle command" || bad "body: $M"
[ "$(nposts)" = 0 ] && ok "no Slack post" || bad "a post: $(<"$POSTS")"
[ "$(set_count "$A" tell)" = 0 ] && ok "the items count as told" || bad "tell left: $(set_vals "$A" tell)"
[ "$(nin "$MLOG")" = 0 ] && ok "nothing to the other session" || bad "it got: $(<"$MLOG")"
grep -q 'told sala-test-target about 1 item' "$SALA_PSET_LOG" && ok "the sets' log names the target" || bad "log: $(<"$SALA_PSET_LOG")"
SALA_PSET_TARGET=sala-test-target pset_tell "$A"; sleep 1
[ "$(nin "$TLOG")" = 1 ] && ok "telling again sends nothing" || bad "a second message: $(<"$TLOG")"

echo "== target set but not live: the Slack post, the items told, nothing delivered"
reset; A=$(newset)
SALA_PSET_TARGET=sala-test-nobody pset_tell "$A"
[ "$(nposts)" = 1 ] && ok "one Slack post" || bad "$(nposts) posts: $(<"$POSTS")"
[ "$(set_count "$A" tell)" = 0 ] && ok "the items count as told" || bad "tell left: $(set_vals "$A" tell)"
sleep 1; [ "$(nin "$TLOG")" = 0 ] && [ "$(nin "$MLOG")" = 0 ] && ok "nothing reached a session" || bad "target: $(<"$TLOG") leftover: $(<"$MLOG")"
grep -q 'sala-test-nobody (SALA_PSET_TARGET) could not be told' "$SALA_PSET_LOG" && ok "the log names the target that failed" || bad "log: $(<"$SALA_PSET_LOG")"

echo "== a live session still named SALA_MASTER, no target: it hears nothing, the Slack post goes out"
reset; A=$(newset)
SALA_MASTER=sala-test-leftover SALA_PSET_TARGET="" pset_tell "$A"
[ "$(nposts)" = 1 ] && [ "$(set_count "$A" tell)" = 0 ] && ok "one Slack post, the items told" || bad "posts $(nposts); tell left: $(set_vals "$A" tell)"
sleep 1; [ "$(nin "$MLOG")" = 0 ] && ok "the session named SALA_MASTER got nothing" || bad "it got: $(<"$MLOG")"

echo "== SALA_MASTER and a target both set: only the target hears"
reset; A=$(newset)
SALA_MASTER=sala-test-leftover SALA_PSET_TARGET=sala-test-target pset_tell "$A"
waitfor '[ "$(nin "$TLOG")" -ge 1 ]' 20
sleep 1; [ "$(nin "$TLOG")" = 1 ] && [ "$(nin "$MLOG")" = 0 ] && [ "$(nposts)" = 0 ] && ok "the target heard it, the session named SALA_MASTER did not, no post" || bad "target: $(<"$TLOG") leftover: $(<"$MLOG") posts: $(<"$POSTS")"

[ "$fail" = 0 ] && echo "PASS" || echo "FAILED"
exit "$fail"
