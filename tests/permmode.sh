#!/usr/bin/env bash
# The relaunch permission mode (Thu Oct 29th 2026; lib/common.sh `permission_mode_args`, `resume_cmd`, lib/spawn.sh): a
# `claude --resume <uuid>` restores the permissionMode its transcript recorded and ignores the settings' `permissions.defaultMode`, so
# every line sala types to relaunch an interactive claude carries the settings' defaultMode as `--permission-mode <mode>`.
# Checked here: the helper on a table of settings files (a mode set, `default`, no defaultMode, no file, a file that does not parse, a
# garbage value naming nothing the CLI takes, a value that is not a string; the file under $CLAUDE_CONFIG_DIR; the subscription-2 lane reading its
# own directory); resume_cmd's line with and without the flag, and with the lane's own
# arguments before it; the real thing, argv of the relaunched fake claude read from /proc/<pid>/cmdline after `recycle --force`
# (revive's path) and after `spawn --fork` (a fork is a resume; a plain new spawn reads the settings itself and gets no flag).
# Isolated HOME, a private tmux socket, the compiled fake claude. Usage: bash tests/permmode.sh   (exit 0 = pass; ~30 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_SET SALA_SET_SELF SALA_POST_RECYCLE_CMD SALA_RECYCLE SALA_RETRY_WORKER SALA_NO_RELAUNCH SALA_MASTER
unset ANTHROPIC_API_KEY ANTHROPIC_CUSTOM_HEADERS CLAUDE_CONFIG_DIR SALA_LANE_API_KEY_FILE SALA_LANE_API_WORKSPACE_FILE SALA_LANE_API_MCP_CONFIG SALA_LANE_TEAM_DIR
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, fake_up, uuid, kill_fake_claude, tmux_socket_rm
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
as_op_unit   # no master: the guarded verbs this suite runs itself stand for the queue's runner (tests/lib.sh, 5)
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
FAKEBIN="$HOME/.local/share/claude/versions/9.9.9"
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$FAKEBIN" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
ln -s "$FAKEBIN" "$HOME/.local/bin/claude"   # as the CLI installs it: the launcher target's name is the version
printf '#!/bin/sh\necho "$*" >> "%s/systemd-run.txt"\n' "$HOME" > "$HOME/.local/bin/systemd-run"; chmod +x "$HOME/.local/bin/systemd-run"   # watch launches nothing
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="{ cat; echo '%%'; } >> $POSTS"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off
SALA="$ROOT/bin/salamander"; SOCK="sala-permmode-$$"; T="tmux -L $SOCK -f /dev/null"; RLOG="$HOME/.claude/salamander-revive.log"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's (common.sh, on_fleet_server)
fail=0
cleanup() {
    local f; for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    kill_fake_claude "$FAKEBIN"   # only a process whose /proc exe is this suite's fake and whose environment names this HOME
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux    # literal socket: the children run set -u
. "$ROOT/lib/common.sh"
wait_lock() { lock_wait "$HOME/.claude/salamander-recycle.lock" 80; }
SET="$HOME/.claude/settings.json"
setmode() { printf '{"model":"opus","permissions":{"allow":["Bash(ls)"],"defaultMode":"%s"}}\n' "$1" > "$SET"; }   # <mode> → the user settings with that defaultMode
argv_of() { [ -n "${1:-}" ] && tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null; }                                                      # <pid> → its argv, space-separated
U1=$(uuid 1); U2=$(uuid 2); UF=$(uuid 7)

echo "== permission_mode_args: the settings file read, the value checked"
rm -f "$SET"
[ -z "$(permission_mode_args subscription-1)" ] && ok "no settings file: nothing" || bad "no file: '$(permission_mode_args subscription-1)'"
printf '{"model":"opus"}\n' > "$SET"
[ -z "$(permission_mode_args subscription-1)" ] && ok "a file with no permissions block: nothing" || bad "no block: '$(permission_mode_args subscription-1)'"
printf '{"permissions":{"allow":[]}}\n' > "$SET"
[ -z "$(permission_mode_args subscription-1)" ] && ok "permissions without defaultMode: nothing" || bad "no defaultMode: '$(permission_mode_args subscription-1)'"
setmode bypassPermissions
[ "$(permission_mode_args subscription-1)" = " --permission-mode bypassPermissions" ] && ok "defaultMode bypassPermissions: ' --permission-mode bypassPermissions'" || bad "bypass: '$(permission_mode_args subscription-1)'"
for m in default acceptEdits plan auto dontAsk manual; do
    setmode "$m"; [ "$(permission_mode_args subscription-1)" = " --permission-mode $m" ] && ok "defaultMode $m passes" || bad "$m: '$(permission_mode_args subscription-1)'"
done
setmode 'rm -rf /; x'
out=$(permission_mode_args subscription-1 2>"$HOME/err.txt"); err=$(slurp "$HOME/err.txt")
[ -z "$out" ] && has "$err" "unknown mode" && ok "a garbage value: nothing typed, a note on stderr" || bad "garbage: out='$out' err='$err'"
setmode 'BypassPermissions'
[ -z "$(permission_mode_args subscription-1 2>/dev/null)" ] && ok "the wrong case is not a mode: nothing" || bad "case: '$(permission_mode_args subscription-1 2>/dev/null)'"
printf '{"permissions":{"defaultMode":7}}\n' > "$SET"
[ -z "$(permission_mode_args subscription-1 2>/dev/null)" ] && ok "a value that is not a string: nothing" || bad "number: '$(permission_mode_args subscription-1 2>/dev/null)'"
printf '{"permissions": {"defaultMode": "plan"' > "$SET"
[ -z "$(permission_mode_args subscription-1 2>/dev/null)" ] && ok "a file that does not parse: nothing" || bad "unparseable: '$(permission_mode_args subscription-1 2>/dev/null)'"
printf '["bypassPermissions"]\n' > "$SET"
[ -z "$(permission_mode_args subscription-1 2>/dev/null)" ] && ok "a file that is not an object: nothing" || bad "not an object: '$(permission_mode_args subscription-1 2>/dev/null)'"
setmode plan; mkdir -p "$HOME/cfg"; printf '{"permissions":{"defaultMode":"acceptEdits"}}\n' > "$HOME/cfg/settings.json"
[ "$(CLAUDE_CONFIG_DIR=$HOME/cfg permission_mode_args subscription-1)" = " --permission-mode acceptEdits" ] && ok "CLAUDE_CONFIG_DIR is honored over ~/.claude" || bad "config dir: '$(CLAUDE_CONFIG_DIR=$HOME/cfg permission_mode_args subscription-1)'"
mkdir -p "$HOME/.claude-team"; printf '{"permissions":{"defaultMode":"dontAsk"}}\n' > "$HOME/.claude-team/settings.json"; SALA_LANE_TEAM_DIR="$HOME/.claude-team"
[ "$(permission_mode_args subscription-2)" = " --permission-mode dontAsk" ] && [ "$(permission_mode_args subscription-1)" = " --permission-mode plan" ] && ok "the subscription-2 lane reads its own directory (dontAsk), subscription-1 reads ~/.claude (plan)" || bad "subscription-2: '$(permission_mode_args subscription-2)' subscription-1: '$(permission_mode_args subscription-1)'"

echo "== resume_cmd: the flag last, the lane's own arguments before it"
rm -f "$SET"
[ "$(resume_cmd "$U1")" = "$(mod_env_prefix)claude --resume $U1" ] && ok "no defaultMode: the line as before" || bad "plain: $(resume_cmd "$U1")"
setmode bypassPermissions
[ "$(resume_cmd "$U1")" = "$(mod_env_prefix)claude --resume $U1 --permission-mode bypassPermissions" ] && ok "defaultMode set: --permission-mode bypassPermissions ends the line" || bad "bypass line: $(resume_cmd "$U1")"
[ "$(resume_cmd "$U1" "" named | grep -c -- '--permission-mode')" = 1 ] && ok "the flag appears once" || bad "count: $(resume_cmd "$U1")"
mkdir -p "$HOME/.config/claude-lanes"; : > "$HOME/.config/claude-lanes/api-mcp.json"; export SALA_LANE_API_MCP_CONFIG="$HOME/.config/claude-lanes/api-mcp.json"
r=$(lane_args bedrock)$(permission_mode_args bedrock)
[ "$r" = " --mcp-config $SALA_LANE_API_MCP_CONFIG --permission-mode bypassPermissions" ] && ok "after the lane's --mcp-config" || bad "lane args then mode: '$r'"
unset SALA_LANE_API_MCP_CONFIG
setmode 'nonsense'
[ "$(resume_cmd "$U1" 2>/dev/null)" = "$(mod_env_prefix)claude --resume $U1" ] && ok "a garbage defaultMode: the line as before" || bad "garbage line: $(resume_cmd "$U1" 2>/dev/null)"

echo "== a recycle (revive's path) brings the pane back with the flag; with no defaultMode, without it"
mk() { local n="$1" u="$2"; shift 2; $T new-session -d -s "sala-test-$n" -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="sala-test-$n" -e FAKE_LOG="$FAKE_LOG" "$@"; $T send-keys -t "sala-test-$n" 'claude' Enter; }
mk a "$U1"; fake_up sala-test-a || bad "the fake under sala-test-a did not come up"
a0=$(argv_of "$(cpid a)")
has "$a0" "--permission-mode" && bad "the by-hand launch already had the flag: $a0" || ok "the first launch (by hand) carries no flag: $a0"
setmode bypassPermissions
"$SALA" recycle --force >/dev/null 2>&1 || bad "recycle --force did not start"
waitfor '[ "$(starts "$U1")" = 2 ]' 60 && ok "relaunched by the recycle" || bad "starts after recycle: $(starts "$U1") $(tail -20 "$RLOG")"
wait_lock; fake_up sala-test-a
a1=$(argv_of "$(cpid a)")
has "$a1" "--resume $U1" && has "$a1" "--permission-mode bypassPermissions" && ok "the relaunched claude's argv: $a1" || bad "argv after recycle: $a1"
rm -f "$SET"
"$SALA" recycle --force >/dev/null 2>&1 || bad "second recycle --force did not start"
waitfor '[ "$(starts "$U1")" = 3 ]' 60 && ok "relaunched again" || bad "starts after second recycle: $(starts "$U1") $(tail -20 "$RLOG")"
wait_lock; fake_up sala-test-a
a2=$(argv_of "$(cpid a)")
has "$a2" "--resume $U1" && ! has "$a2" "--permission-mode" && ok "defaultMode unset: the relaunch has no flag: $a2" || bad "argv after unset: $a2"
printf '{"permissions":{"defaultMode":"x y"}}\n' > "$SET"
"$SALA" recycle --force >/dev/null 2>&1 || bad "third recycle --force did not start"
waitfor '[ "$(starts "$U1")" = 4 ]' 60 && ok "relaunched a third time" || bad "starts after third recycle: $(starts "$U1") $(tail -20 "$RLOG")"
wait_lock; fake_up sala-test-a
a3=$(argv_of "$(cpid a)")
has "$a3" "--resume $U1" && ! has "$a3" "--permission-mode" && ok "a garbage defaultMode: the relaunch has no flag: $a3" || bad "argv after garbage: $a3"

echo "== spawn --fork (a resume) carries the flag; a new spawn does not"
echo '{"type":"user"}' > "$HOME/.claude/projects/x/$UF.jsonl"   # spawn --fork wants the conversation's transcript
setmode bypassPermissions
$T set-environment -g FAKE_SESSION_ID "$U2"; $T set-environment -g FAKE_NAME sala-test-f
out=$("$SALA" spawn sala-test-f --cwd "$HOME" --fork "$UF" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "spawn --fork started" || bad "spawn --fork ($rc): $out"
fake_up sala-test-f
f1=$(argv_of "$(cpid f)")
has "$f1" "--resume $UF --fork-session" && has "$f1" "--permission-mode bypassPermissions" && ok "the fork's argv: $f1" || bad "fork argv: $f1"
rm -f "$SET"
$T set-environment -g FAKE_SESSION_ID "$(uuid 8)"; $T set-environment -g FAKE_NAME sala-test-g
out=$("$SALA" spawn sala-test-g --cwd "$HOME" --fork "$UF" 2>&1); rc=$?
fake_up sala-test-g
f2=$(argv_of "$(cpid g)")
[ "$rc" = 0 ] && has "$f2" "--fork-session" && ! has "$f2" "--permission-mode" && ok "a fork with no defaultMode: no flag: $f2" || bad "fork argv unset ($rc): $f2 / $out"
setmode bypassPermissions
$T set-environment -g FAKE_SESSION_ID "$(uuid 9)"; $T set-environment -g FAKE_NAME sala-test-h
out=$("$SALA" spawn sala-test-h --cwd "$HOME" 2>&1); rc=$?
fake_up sala-test-h
f3=$(argv_of "$(cpid h)")
[ "$rc" = 0 ] && ! has "$f3" "--permission-mode" && ! has "$f3" "--resume" && ok "a new (non-fork) spawn reads the settings itself: no flag: $f3" || bad "plain spawn argv ($rc): $f3 / $out"

[ "$fail" = 0 ] && echo "permmode: pass" || echo "permmode: FAIL"
exit $fail
