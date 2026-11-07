#!/usr/bin/env bash
# SALA_PSET_TARGET (demo-main, Fri Oct 16th 2026; common.sh, pset_tell): a provision set's session/owner items go to
# the master; with NO master configured (SALA_MASTER unset) a configured SALA_PSET_TARGET, a front agent, takes the
# same text in its inbox with `[for Rowan]` on its first line. Checks, with two fake claudes in a private tmux server (the
# master and the target; what reaches each one's messaging socket is read from FAKE_SOCK_LOG) and Slack stubbed to a file
# (SALA_NOTIFY_CMD): the target set + no master → delivered, `[for Rowan]` first, the same body as the master gets, no Slack
# post, the items told; the target absent → the Slack post as before, the items told; the target unset → exactly the old
# behaviour (the Slack post with no master; pending with a master configured but not live); a live master wins over the
# target; a master configured but not live (mid-recycle) → pending with tellfail whether the target is live or not, the
# target never told, no post. State and the sets' log only: never the posts' wording. Isolated HOME, nothing real: no Slack, no real session.
# Usage: bash tests/pset-target.sh   (exit 0 = pass; ~20 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_SET SALA_PSET_WORKER SALA_MASTER SALA_CUE_TARGET SALA_PSET_TARGET
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
MLOG="$HOME/master-inbox.log"; TLOG="$HOME/target-inbox.log"; : > "$MLOG"; : > "$TLOG"
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

echo "== two fake claudes in a private tmux server: the master and the target"
$T new-session -d -s sala-test-master -c "$HOME" -e FAKE_SESSION_ID=00000000-0000-4000-8000-0000000000aa -e FAKE_NAME=master -e FAKE_SOCK_LOG="$MLOG"; $T send-keys -t sala-test-master 'claude' Enter
$T new-session -d -s sala-test-target -c "$HOME" -e FAKE_SESSION_ID=00000000-0000-4000-8000-0000000000bb -e FAKE_NAME=target -e FAKE_SOCK_LOG="$TLOG"; $T send-keys -t sala-test-target 'claude' Enter
fake_up master target || { echo "the fakes did not start"; exit 1; }
ok "both fakes are up"

echo "== SALA_PSET_TARGET unset, no master: the Slack post as before, the items told, nothing delivered"
reset; A=$(newset)
SALA_CUE_TARGET="" SALA_PSET_TARGET="" pset_tell "$A"
[ "$(nposts)" = 1 ] && ok "one Slack post" || bad "$(nposts) posts: $(<"$POSTS")"
[ "$(set_count "$A" tell)" = 0 ] && ok "the items count as told" || bad "tell left: $(set_vals "$A" tell)"
sleep 1; [ "$(nin "$MLOG")" = 0 ] && [ "$(nin "$TLOG")" = 0 ] && ok "nothing reached a session" || bad "master: $(<"$MLOG") target: $(<"$TLOG")"
grep -q 'posted to Slack instead' "$SALA_PSET_LOG" && ok "the sets' log says so" || bad "log: $(<"$SALA_PSET_LOG")"

echo "== target set, no master (SALA_MASTER unset), target live: it gets the text, [for Rowan] first; no Slack post"
reset; A=$(newset)
SALA_CUE_TARGET="" SALA_PSET_TARGET=sala-test-target pset_tell "$A"
waitfor '[ "$(nin "$TLOG")" -ge 1 ]' 20
[ "$(nin "$TLOG")" = 1 ] && ok "exactly one message to the target" || bad "$(nin "$TLOG") messages: $(<"$TLOG")"
M=$(<"$TLOG")
grep -qF '"content": "[for Rowan]\n[sala provision] Provision ' <<< "$M" && ok "its first line is [for Rowan], the master's text follows" || bad "message: $M"
grep -qF "(set $A)" <<< "$M" && grep -qF 'sala provision --settle '"$A"' t-host-a deny-rules ok' <<< "$M" && ok "same body: the set, the item, the exact settle command" || bad "body: $M"
[ "$(nposts)" = 0 ] && ok "no Slack post" || bad "a post: $(<"$POSTS")"
[ "$(set_count "$A" tell)" = 0 ] && ok "the items count as told" || bad "tell left: $(set_vals "$A" tell)"
[ "$(nin "$MLOG")" = 0 ] && ok "nothing to the (unconfigured) master" || bad "master got: $(<"$MLOG")"
grep -q 'told sala-test-target about 1 item' "$SALA_PSET_LOG" && ok "the sets' log names the target" || bad "log: $(<"$SALA_PSET_LOG")"
SALA_CUE_TARGET="" SALA_PSET_TARGET=sala-test-target pset_tell "$A"; sleep 1
[ "$(nin "$TLOG")" = 1 ] && ok "telling again sends nothing" || bad "a second message: $(<"$TLOG")"

echo "== target set but not live, no master: the Slack post, the items told, nothing delivered"
reset; A=$(newset)
SALA_CUE_TARGET="" SALA_PSET_TARGET=sala-test-nobody pset_tell "$A"
[ "$(nposts)" = 1 ] && ok "one Slack post" || bad "$(nposts) posts: $(<"$POSTS")"
[ "$(set_count "$A" tell)" = 0 ] && ok "the items count as told" || bad "tell left: $(set_vals "$A" tell)"
sleep 1; [ "$(nin "$TLOG")" = 0 ] && [ "$(nin "$MLOG")" = 0 ] && ok "nothing reached a session" || bad "target: $(<"$TLOG") master: $(<"$MLOG")"
grep -q 'sala-test-nobody (SALA_PSET_TARGET) could not be told' "$SALA_PSET_LOG" && ok "the log names the target that failed" || bad "log: $(<"$SALA_PSET_LOG")"

echo "== a live master wins over the target: only the master hears, with no [for Rowan] line"
reset; A=$(newset)
SALA_CUE_TARGET=sala-test-master SALA_PSET_TARGET=sala-test-target pset_tell "$A"
waitfor '[ "$(nin "$MLOG")" -ge 1 ]' 20
[ "$(nin "$MLOG")" = 1 ] && ok "the master got one message" || bad "$(nin "$MLOG") messages: $(<"$MLOG")"
grep -qF '"content": "[sala provision] Provision ' "$MLOG" && ! grep -qF 'for Rowan' "$MLOG" && ok "the master's text, unchanged (no [for Rowan])" || bad "master: $(<"$MLOG")"
sleep 1; [ "$(nin "$TLOG")" = 0 ] && [ "$(nposts)" = 0 ] && ok "the target heard nothing, no Slack post" || bad "target: $(<"$TLOG"); posts: $(<"$POSTS")"
[ "$(set_count "$A" tell)" = 0 ] && ok "the items count as told" || bad "tell left: $(set_vals "$A" tell)"

echo "== a master configured but not live, target unset: pending, as before (watch tries again)"
reset; A=$(newset)
SALA_CUE_TARGET=sala-test-gone SALA_PSET_TARGET="" pset_tell "$A"
[ "$(set_count "$A" tell)" = 1 ] && [ -n "$(set_val "$A" tellfail)" ] && ok "the item stays pending, the failure recorded" || bad "state: $(<"$SALA_SET_DIR/$A")"
[ "$(nposts)" = 0 ] && ok "no Slack post" || bad "a post: $(<"$POSTS")"
grep -q 'could not tell the master' "$SALA_PSET_LOG" && ok "logged once" || bad "log: $(<"$SALA_PSET_LOG")"

echo "== a master configured but not live (mid-recycle), target live: pending with tellfail, the target NOT told, no post"
reset; A=$(newset)
SALA_CUE_TARGET=sala-test-gone SALA_PSET_TARGET=sala-test-target pset_tell "$A"
sleep 1
[ "$(set_count "$A" tell)" = 1 ] && [ -n "$(set_val "$A" tellfail)" ] && ok "the item stays pending, the failure recorded" || bad "state: $(<"$SALA_SET_DIR/$A")"
[ "$(nin "$TLOG")" = 0 ] && [ "$(nin "$MLOG")" = 0 ] && ok "the target heard nothing" || bad "target: $(<"$TLOG") master: $(<"$MLOG")"
[ "$(nposts)" = 0 ] && ok "no Slack post" || bad "a post: $(<"$POSTS")"

echo "== a master configured but not live, target not live either: pending with tellfail, no post"
reset; A=$(newset)
SALA_CUE_TARGET=sala-test-gone SALA_PSET_TARGET=sala-test-nobody pset_tell "$A"
[ "$(set_count "$A" tell)" = 1 ] && [ -n "$(set_val "$A" tellfail)" ] && [ "$(nposts)" = 0 ] && ok "pending, nothing posted" || bad "state: $(<"$SALA_SET_DIR/$A"); posts: $(<"$POSTS")"

[ "$fail" = 0 ] && echo "PASS" || echo "FAILED"
exit "$fail"
