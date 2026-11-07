#!/usr/bin/env bash
# The sdk lane (lib/common.sh "lanes", lib/sdk-pane.sh, contrib/sdk-pane/driver.py): the API
# credit through the Agent SDK, with every relaunch path treating the pane as a claude pane. Against a STUB SDK
# (tests/sdk-stub/claude_agent_sdk, on PYTHONPATH; SALA_LANE_SDK_CMD="python3 -B" in place of uv) that spawns the compiled fake
# claude the way the SDK spawns the CLI (its env: CLAUDE_CODE_ENTRYPOINT=sdk-py plus the key from options.env). What is
# checked guards the relaunch paths and the key: lane_check sdk naming what is missing (the key file, the --mcp-config, the
# interpreter, the credit record holding a fresh refusal) and the clock injected (SALA_LANE_SDK_NOW; the lane is open
# while the shared credit record, lib/api_credit.py, holds no refusal less than 6 h old; the tests stamp one at a fixed epoch in the
# far future, which the real clock reads as old and SALA_LANE_SDK_NOW=<60 s after it> as fresh); resume_cmd's line for an sdk row (`salamander
# sdk-pane <uuid> <session>`, the model and effort, never the key or a $(cat)), and the max line once the window is closed,
# logged once; the default lane sdk after the window reading subscription-1; `sala lane sdk <session>` end to end through the direct
# sweep (recorded, relaunched, the pane's program `sala-sdk`, the fake's environment carrying the key by the SDK's own route,
# proc_lane sdk, the driver handed the files' paths and the launcher, the key value in none of the output, the scrollback,
# the logs, the argv); the screen's ❯ box (a rule, the ❯ line, a rule; the dim hint no draft; typed text read as a draft
# and refusing a relaunch; Enter reaching the SDK as a query; sala's marked message; nothing on it a terminal prompt);
# a later `revive --force --only` relaunching the sdk pane (/exit typed into the box, the lane line `sdk → sdk`, the
# summary `(lane sdk)`), with a recorded model and effort on the SDK's line; the credit fallback (a refused turn → the row
# subscription-1, one post in plain words, the pane resumed on the subscription-1 line at once, the table subscription-1/subscription-1); a CLI that dies leaving the
# pane at its shell with a line, resumed by the next revive on sdk; the wrapper's own credit gate running the subscription-1 line; the
# switch refused once the window is closed; spawn refused on a default of sdk. Posts stubbed to a file; isolated HOME, a
# private tmux socket. Usage: bash tests/sdklane.sh   (exit 0 = pass; ~50 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_SET SALA_SET_SELF SALA_POST_RECYCLE_CMD SALA_RECYCLE SALA_RETRY_WORKER SALA_NO_RELAUNCH SALA_MASTER
unset ANTHROPIC_API_KEY ANTHROPIC_CUSTOM_HEADERS CLAUDE_CONFIG_DIR SALA_LANE_API_KEY_FILE SALA_LANE_API_WORKSPACE_FILE SALA_LANE_API_MCP_CONFIG SALA_LANE_TEAM_DIR
unset SALA_LANE_SDK_PIN SALA_LANE_SDK_CMD SALA_LANE_SDK_NOW FAKE_SDK API_CREDIT_RETRY_S
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, fake_up, tmux_socket_rm
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC XDG_RUNTIME_DIR="$HOME/run"   # the mod's stamps and replies stay in this HOME
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$HOME/.config/anthropic" "$HOME/.config/claude-lanes" "$XDG_RUNTIME_DIR"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$HOME/.local/share/claude/versions/9.9.9" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
ln -s "$HOME/.local/share/claude/versions/9.9.9" "$HOME/.local/bin/claude"   # the launcher, as the CLI installs it: the SDK is pointed at it
printf '#!/bin/sh\necho "$*" >> "%s/systemd-run.txt"\n' "$HOME" > "$HOME/.local/bin/systemd-run"; chmod +x "$HOME/.local/bin/systemd-run"
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log" FAKE_LANE_LOG="$HOME/fake-lane.log" FAKE_TYPED_LOG="$HOME/typed.log"
export FAKE_SDK_LOG="$HOME/sdk.log" FAKE_QUERY_LOG="$HOME/query.log" PYTHONPATH="$ROOT/tests/sdk-stub" SALA_LANE_SDK_CMD="python3 -B"   # the stub SDK, no uv
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="{ cat; echo '%%'; } >> $POSTS"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off
SALA="$ROOT/bin/salamander"; SOCK="sala-sdklane-$$"; T="tmux -L $SOCK -f /dev/null"; RLOG="$HOME/.claude/salamander-revive.log"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's (common.sh, on_fleet_server)
KEYF="$HOME/.config/anthropic/api-key"; WSF="$HOME/.config/anthropic/workspace-id"; MCPF="$HOME/.config/claude-lanes/api-mcp.json"
DUMMY="dummy-key-NOT-REAL-$$"; WSID="wsid_dummy_$$"
(umask 077; printf '%s\n' "$DUMMY" > "$KEYF"); printf '%s\n' "$WSID" > "$WSF"; echo '{"mcpServers":{}}' > "$MCPF"
cleanup() {
    local f p; for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done
    [ -n "${FAKEMOD:-}" ] && kill "$FAKEMOD" 2>/dev/null
    pkill -9 -f "sdk-pane/driver.py .*--key-file $KEYF" 2>/dev/null   # this suite's drivers alone (the key file is under this HOME)
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    for p in $(pgrep -x claude); do [ "$HOME/.local/share/claude/versions/9.9.9" -ef "/proc/$p/exe" ] && kill -9 "$p" 2>/dev/null; done
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux    # literal socket: the children run set -u
. "$ROOT/lib/common.sh"
wait_lock() { lock_wait "$HOME/.claude/salamander-recycle.lock" 80; }
mk() { local n="$1" u="$2"; shift 2; $T new-session -d -s "sala-test-$n" -c "$HOME" -x 110 -y 30 -e FAKE_SESSION_ID="$u" -e FAKE_NAME="sala-test-$n" -e FAKE_LOG="$FAKE_LOG" -e FAKE_LANE_LOG="$FAKE_LANE_LOG" -e FAKE_TYPED_LOG="$FAKE_TYPED_LOG" "$@"; $T send-keys -t "sala-test-$n" 'claude' Enter; }
panepid() { tmux display -p -t "sala-test-$1" '#{pane_pid}'; }
cpid() { claude_pid_under "$(panepid "$1")"; }
pcmd() { tmux display -p -t "sala-test-$1" '#{pane_current_command}'; }
lanelog() { grep "^$1 " "$FAKE_LANE_LOG" 2>/dev/null | tail -1 | cut -d' ' -f2-; }   # <uuid> → "key=… hdr=… cfg=…" of its latest start
screen() { $T capture-pane -p -t "sala-test-$1" | grep -v '^[[:space:]]*$'; }     # <n> → the pane's non-blank lines
sdk_argv() { tail -1 "$FAKE_SDK_LOG" 2>/dev/null | python3 -c 'import json,sys; print(" ".join(json.loads(sys.stdin.read())["argv"]))'; }   # the CLI's argv the stub built last
driver_pid() { pids_under "$(panepid "$1")" $(pgrep -f 'contrib/sdk-pane/driver.py') 2>/dev/null | head -1; }
# box <n> → 0 when the pane's last three non-blank lines are a rule of ─, a ❯ line and a rule (what sala-web's input_box and
# sala's pane_draft read); prints why not otherwise
box() {
    screen "$1" | tail -3 | python3 -c '
import sys
l = [x.rstrip() for x in sys.stdin.read().split("\n") if x.strip()]
def rule(s): return len(s) >= 10 and s.count("─") >= 0.6 * len(s)
if len(l) != 3: print("not three lines: %r" % l); sys.exit(1)
if not rule(l[0]): print("no rule above: %r" % l[0]); sys.exit(1)
if not l[1].lstrip().startswith("❯"): print("no ❯ line: %r" % l[1]); sys.exit(1)
if not rule(l[2]): print("no rule below: %r" % l[2]); sys.exit(1)'
}
U1=$(uuid 1); U2=$(uuid 2); U7=$(uuid 7); UX=$(uuid 9)
# no date gate. A refusal on the credit record stamped at REFAT (a fixed epoch in the far future): the real clock reads it
# as old (the key may be used), SALA_LANE_SDK_NOW=$UNTIL (60 s after it) as fresh (closed), SALA_LANE_SDK_NOW=$BEFORE (exactly 6 h after) as old.
REFAT=4000000000; UNTIL=$((REFAT + 60)); BEFORE=$((REFAT + 21600))
CREC=$HOME/.local/state/api-credit/state.json
rec_at() { mkdir -p "${CREC%/*}"; printf '{"refused_at": %s, "by": "test job", "detail": "Credit balance is too low"}\n' "$1" > "$CREC"; }
rec_at $REFAT

echo "== lane_check sdk: what is missing is named; the clock is the knob"
lane_check sdk >/dev/null && ok "the key, the workspace id, the --mcp-config file, the interpreter: ready" || bad "lane_check sdk: $(lane_check sdk)"
sdk_window_open && ok "no date gate: with the record far from now (stamped far ahead) the lane is open on the real clock" || bad "sdk_window_open on the real clock"
why=$(SALA_LANE_SDK_NOW=$UNTIL lane_check sdk); [ $? = 1 ] && grep -q 'the API credit refused a call' <<< "$why" && grep -q 'refused at .* by test job; the key is tried again after ' <<< "$why" && ok "60 s after a refusal on record: refused, when and by whom said (and when the key is tried again)" || bad "lane_check sdk with a fresh refusal: $why"
SALA_LANE_SDK_NOW=$BEFORE lane_check sdk >/dev/null && ok "exactly 6 h after it: ready (the key is tried again)" || bad "lane_check sdk 6 h after the refusal: $(SALA_LANE_SDK_NOW=$BEFORE lane_check sdk)"
mv "$MCPF" "$MCPF.away"; why=$(lane_check sdk); [ $? = 1 ] && grep -qF "$MCPF" <<< "$why" && grep -q 'SALA_LANE_API_MCP_CONFIG' <<< "$why" && ok "no --mcp-config file: refused, naming it (an SDK session has no claude.ai connector)" || bad "no mcp config: $why"; mv "$MCPF.away" "$MCPF"
mv "$KEYF" "$KEYF.away"; why=$(lane_check sdk); [ $? = 1 ] && grep -qF "$KEYF" <<< "$why" && ok "no key file: refused, naming it" || bad "no key file: $why"; mv "$KEYF.away" "$KEYF"
why=$(SALA_LANE_SDK_CMD=no-such-interpreter lane_check sdk); [ $? = 1 ] && grep -q "'no-such-interpreter' is not on PATH" <<< "$why" && ok "the interpreter missing: refused, naming it" || bad "interpreter: $why"
mkdir -p "$HOME/nouv"; for t in date tr head cut awk grep sed basename dirname readlink python3; do ln -s "$(command -v $t)" "$HOME/nouv/$t"; done   # a PATH with the tools and no uv
why=$(SALA_LANE_SDK_CMD= PATH="$HOME/nouv" lane_check sdk); [ $? = 1 ] && grep -q "'uv' is not on PATH" <<< "$why" && grep -q 'claude-agent-sdk==' <<< "$why" && ok "without SALA_LANE_SDK_CMD it is uv that must be there, with the pin named" || bad "uv missing: $why"
lane_rc sdk && bad "lane_rc sdk said a bridge is possible" || ok "lane_rc sdk: no Remote Control (as api)"
[ "$(lane_env_names sdk)" = "ANTHROPIC_API_KEY ANTHROPIC_CUSTOM_HEADERS" ] && ok "lane_env_names sdk: the names the driver hands the CLI (a dry run shows them)" || bad "lane_env_names sdk: $(lane_env_names sdk)"
[ -z "$(lane_env_prefix sdk)" ] && [ -z "$(lane_args sdk)" ] && ok "nothing of the lane on a claude line: the pane program carries it" || bad "sdk prefix '$(lane_env_prefix sdk)' args '$(lane_args sdk)'"

echo "== resume_cmd: the pane program's line for an sdk row; the subscription-1 line once the window is closed, said once in lanes.log"
lane_write sala-test-x sdk && [ "$(lane_for_session sala-test-x)" = sdk ] && ok "lane_write sdk: the row is read back" || bad "row: $(slurp "$SALA_LANES")"
r=$(resume_cmd "$UX" sala-test-x)
[ "$r" = "$SALA_BIN sdk-pane $UX sala-test-x" ] && ok "an sdk row: salamander sdk-pane <uuid> <session> — no claude, no env prefix, no --mcp-config" || bad "resume_cmd on sdk: $r"
! grep -qF "$DUMMY" <<< "$r" && ! grep -q 'cat ' <<< "$r" && ok "the line carries neither the key value nor a \$(cat …): the wrapper reads the lane's files itself" || bad "the line carries the key: $r"
model_write sala-test-x opus xhigh
[ "$(resume_cmd "$UX" sala-test-x)" = "$SALA_BIN sdk-pane $UX sala-test-x --model opus --effort xhigh" ] && ok "a model row: --model and --effort go to the pane program" || bad "with a model row: $(resume_cmd "$UX" sala-test-x)"
model_drop sala-test-x
n0=$(grep -c . "$SALA_LANE_LOG" 2>/dev/null)
r=$(SALA_LANE_SDK_NOW=$UNTIL resume_cmd "$UX" sala-test-x)
[ "$r" = "$(mod_env_prefix)claude --resume $UX" ] && ok "the window closed, the row still sdk: the subscription-1 line (no key, no config directory)" || bad "after the window: $r"
grep -q $'\tfallback\tsala-test-x\tsdk → subscription-1 (the API credit refused a call' "$SALA_LANE_LOG" && [ "$(grep -c . "$SALA_LANE_LOG")" = $((n0 + 1)) ] && ok "and one fallback line in lanes.log naming the session and the fix" || bad "lanes.log: $(tail -3 "$SALA_LANE_LOG")"
[ "$(SALA_LANE_SDK_NOW=$UNTIL lane_for_session sala-test-x)" = subscription-1 ] && [ "$(SALA_LANE_SDK_NOW=$BEFORE lane_for_session sala-test-x)" = sdk ] && ok "lane_for_session: sdk 6 h after a refusal, subscription-1 within them" || bad "lane_for_session around the end: $(SALA_LANE_SDK_NOW=$UNTIL lane_for_session sala-test-x) / $(SALA_LANE_SDK_NOW=$BEFORE lane_for_session sala-test-x)"
[ "$(lane_row sala-test-x)" = sdk ] && ok "the row itself is untouched (salamander lane subscription-1 <session> clears it)" || bad "row after the fallback: $(lane_row sala-test-x)"
lane_set_default sdk; [ "$(lane_default)" = sdk ] && [ "$(SALA_LANE_SDK_NOW=$UNTIL lane_default)" = subscription-1 ] && ok "a default of sdk reads subscription-1 while a refusal is fresh" || bad "default around the end: $(lane_default) / $(SALA_LANE_SDK_NOW=$UNTIL lane_default)"
out=$("$SALA" spawn sala-test-z --cwd "$HOME" 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'default lane is sdk' <<< "$out" && grep -q 'salamander lane sdk sala-test-z' <<< "$out" && ! tmux has-session -t =sala-test-z 2>/dev/null && ok "spawn on a default of sdk: refused before any tmux session, the way said (spawn on subscription-1, then sala lane sdk NAME)" || bad "spawn on default sdk ($rc): $out"
lane_set_default subscription-1; lane_drop sala-test-x
out=$("$SALA" lane 2>&1); grep -q 'sdk ready' <<< "$out" && ok "the table: sdk ready" || bad "table: $out"
out=$(SALA_LANE_SDK_NOW=$UNTIL "$SALA" lane 2>&1); grep -q 'sdk not ready' <<< "$out" && grep -q 'the API credit refused a call' <<< "$out" && ok "the table with a fresh refusal: sdk not ready, the refusal named" || bad "table at the end: $out"

echo "== two panes on the fake claude by hand (subscription-1); sala lane sdk <session>: recorded, relaunched through the direct sweep onto the pane program"
mk a "$U1"; mk b "$U2" -e FAKE_SDK=credit; fake_up sala-test-a sala-test-b   # b's SDK will refuse every turn, once it is on sdk
[ "$(lanelog "$U1")" = "key=n hdr=n cfg=-" ] && [ "$(proc_lane "$(cpid a)")" = subscription-1 ] && ok "a runs on subscription-1, no key" || bad "a: $(lanelog "$U1") $(proc_lane "$(cpid a)")"
out=$(SALA_LANE_SDK_NOW=$UNTIL "$SALA" lane sdk sala-test-a 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'the API credit refused a call' <<< "$out" && [ -z "$(lane_row sala-test-a)" ] && [ "$(starts "$U1")" = 1 ] && ok "the switch while a refusal is fresh: refused, nothing recorded, nothing relaunched" || bad "lane sdk at the end ($rc): $out / row '$(lane_row sala-test-a)'"
out=$("$SALA" lane sdk sala-test-a --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'salamander sdk-pane <uuid> <session>' <<< "$out" && grep -q 'ANTHROPIC_API_KEY' <<< "$out" && grep -qF "$KEYF" <<< "$out" && ! grep -qF "$DUMMY" <<< "$out" && grep -q 'would /exit' <<< "$out" && [ -z "$(lane_row sala-test-a)" ] \
    && ok "--dry-run: the pane program named, the variables' names and the files, never the value; the sweep's verdict; nothing recorded" || bad "dry run ($rc): $out"
out=$("$SALA" lane sdk sala-test-a 2>&1); rc=$?
[ "$rc" = 0 ] && ok "sala lane sdk sala-test-a: exit 0" || bad "lane sdk ($rc): $out"
waitfor '[ "$(starts "$U1")" = 2 ]' 40 && fake_up sala-test-a && ok "a relaunched: the fake came up under the SDK stub" || bad "no relaunch: $(<"$FAKE_LOG") $(tail -5 "$RLOG")"
[ "$(lane_row sala-test-a)" = sdk ] && ok "recorded: sala-test-a → sdk" || bad "row: '$(lane_row sala-test-a)'"
waitfor '[ "$(pcmd a)" = sala-sdk ]' 10 && ok "the pane's program reads sala-sdk (never a shell's name, never claude)" || bad "pane_current_command: $(pcmd a)"
[ "$(lanelog "$U1")" = "key=y hdr=y cfg=-" ] && ok "its CLI started with the key and the header in its environment, by the SDK's route" || bad "lane log: $(lanelog "$U1")"
[ "$(proc_lane "$(cpid a)")" = sdk ] && ok "proc_lane: sdk (CLAUDE_CODE_ENTRYPOINT=sdk-py beside the key)" || bad "proc_lane: $(proc_lane "$(cpid a)")"
grep -qE '^sala-test-a +sdk +sdk' <<< "$("$SALA" lane)" && ok "the table: recorded sdk, running sdk" || bad "table: $("$SALA" lane)"
argv=$(sdk_argv)
case "$argv" in "$HOME/.local/bin/claude --output-format stream-json --verbose --resume $U1 --mcp-config $MCPF --setting-sources=user,project,local --name sala-test-a") ok "the SDK spawned sala's own launcher: --resume <uuid>, the api lane's --mcp-config, the user settings (hooks, the mod), --name <session>" ;; *) bad "the CLI's argv: $argv" ;; esac
tail -1 "$FAKE_SDK_LOG" | grep -q '"env_names": \["ANTHROPIC_API_KEY", "ANTHROPIC_CUSTOM_HEADERS"\]' && grep -q '"can_use_tool": true' "$FAKE_SDK_LOG" && grep -q '"preset": "claude_code"' "$FAKE_SDK_LOG" && ok "the driver handed the SDK the key and the header (names counted), a permission callback and Claude Code's own system prompt" || bad "sdk log: $(tail -1 "$FAKE_SDK_LOG")"
dp=$(driver_pid a); dargs=$(tr '\0' ' ' < "/proc/$dp/cmdline" 2>/dev/null)
grep -q -- "--key-file $KEYF" <<< "$dargs" && grep -q -- "--workspace-file $WSF" <<< "$dargs" && grep -q -- "--cli $HOME/.local/bin/claude" <<< "$dargs" && ! grep -qF "$DUMMY" <<< "$dargs" && ok "the driver's argv: the files' paths and the launcher, never the key" || bad "driver argv: $dargs"
[ "$(tr '\0' '\n' < "/proc/$(cpid a)/environ" | grep -c "^ANTHROPIC_API_KEY=$DUMMY\$")" = 1 ] && ok "the key is in the CLI's environment (counted, never printed)" || bad "the CLI's environment lacks the key"
! grep -qF "$DUMMY" <<< "$out" && ! $T capture-pane -p -S - -t sala-test-a | grep -qF "$DUMMY" && ! grep -qsF "$DUMMY" "$RLOG" "$SALA_LANE_LOG" "$FAKE_SDK_LOG" && ! proc_args "$(cpid a)" | grep -qF "$DUMMY" \
    && ok "the key value is in none of: the command's output, the pane's scrollback, the logs, the CLI's argv" || bad "the key value leaked"
grep -qF "sala-test-a:0: 9.9.9 → 9.9.9 (lane sdk)" <<< "$out" && grep -qF "lane: subscription-1 → sdk" <<< "$out" && ok "the summary row names the lane; the lane line read subscription-1 → sdk" || bad "the switch's output: $out"

echo "== the screen: a ❯ box the pane's readers know, no draft on an empty box, typed text a draft, Enter a query"
why=$(box a) && ok "the last three lines: a rule of ─, the ❯ line, a rule" || bad "box: $why — $(screen a | tail -4)"
[ -z "$(pane_draft_screen sala-test-a)" ] && ok "pane_draft_screen: nothing (the hint is dim, a placeholder)" || bad "draft on an empty box: '$(pane_draft_screen sala-test-a)'"
pane_prompt sala-test-a && bad "pane_prompt sees a terminal prompt on the sdk screen" || ok "nothing on the screen reads as a terminal prompt (pane_prompt)"
screen a | grep -q "connected: Claude Code 9.9.9 under the Agent SDK" && ok "the init line says what connected" || bad "screen: $(screen a)"
$T send-keys -t sala-test-a -l 'unsent 日本語 words'; sleep 0.5
[ "$(pane_draft_screen sala-test-a)" = "unsent 日本語 words" ] && ok "typed text shows on the ❯ line and reads as a draft (wide characters too)" || bad "draft: '$(pane_draft_screen sala-test-a)'"
out=$("$SALA" revive --force --only sala-test-a --dry-run 2>&1)
grep -q 'unsubmitted text at the prompt ("unsent 日本語 words")' <<< "$out" && ok "a relaunch over a draft is refused, the draft quoted (the dry run's verdict)" || bad "dry run over a draft: $out"
$T send-keys -t sala-test-a C-u; sleep 0.3; [ -z "$(pane_draft_screen sala-test-a)" ] && ok "Ctrl-U clears it (what tui_send types over sala's own leftovers)" || bad "after C-u: '$(pane_draft_screen sala-test-a)'"
$T send-keys -t sala-test-a -l 'hello there'; $T send-keys -t sala-test-a Enter
waitfor "grep -qF '$U1 hello there' '$FAKE_QUERY_LOG'" 20 && ok "Enter sends the line to the SDK as a query" || bad "query log: $(slurp "$FAKE_QUERY_LOG")"
sleep 0.5; [ -z "$(pane_draft_screen sala-test-a)" ] && screen a | grep -q 'echo: hello there' && ok "the box empties, the reply is printed above it" || bad "after Enter: draft '$(pane_draft_screen sala-test-a)' screen $(screen a | tail -5)"
tui_send sala-test-a "a line from sala" 2>/dev/null && waitfor "grep -qF '$U1 <!-- sala --> a line from sala' '$FAKE_QUERY_LOG'" 20 && ok "tui_send: sala's marked message reaches the SDK as typed" || bad "tui_send: $(tail -2 "$FAKE_QUERY_LOG")"
$T send-keys -t sala-test-a -l '/remote-control'; $T send-keys -t sala-test-a Enter; sleep 0.5
screen a | grep -q 'no Remote Control on the sdk lane' && ! grep -q '/remote-control' "$FAKE_QUERY_LOG" && ok "/remote-control is answered in the pane, never sent as a prompt" || bad "/remote-control: $(screen a | tail -3) / $(grep remote "$FAKE_QUERY_LOG")"
why=$(box a) && ok "the box is back in shape after output" || bad "box after output: $why"
[ -z "$(is_idle_reason "$(cpid a)")" ] && ok "is_idle_reason: idle (the registry row the SDK's CLI keeps)" || bad "is_idle_reason: $(is_idle_reason "$(cpid a)")"

echo "== a later revive relaunches the sdk pane: /exit typed into the box, resumed through the pane program, a model row on its line"
model_write sala-test-a sonnet high
out=$("$SALA" revive --force --only sala-test-a 2>&1); rc=$?
grep -qF "sala-test-a:0: /exit (9.9.9) → resume $U1 · lane: sdk → sdk" <<< "$out" && ok "the lane line: sdk → sdk" || bad "revive ($rc): $out"
waitfor '[ "$(starts "$U1")" = 3 ]' 40 && fake_up sala-test-a && ok "relaunched" || bad "no relaunch: starts $(starts "$U1") $(tail -5 "$RLOG")"
grep -qF "sala-test-a:0: 9.9.9 → 9.9.9 (lane sdk)" <<< "$out" && [ "$(pcmd a)" = sala-sdk ] && [ "$(lanelog "$U1")" = "key=y hdr=y cfg=-" ] && ok "back on sdk: the program sala-sdk, the key in the CLI's environment" || bad "after revive: $(pcmd a) $(lanelog "$U1")"
case "$(sdk_argv)" in *" --resume $U1 --model sonnet --effort high "*) ok "the model row's --model and --effort on the SDK's line" ;; *) bad "argv: $(sdk_argv)" ;; esac
grep -qF "$U1 /exit" "$FAKE_TYPED_LOG" && ok "the stub's disconnect left the old fake by /exit (its row and socket gone with it)" || bad "typed log: $(<"$FAKE_TYPED_LOG")"
model_drop sala-test-a

echo "== the credit fallback: a refused turn puts the pane back on subscription-1 at once — the row, one post, the subscription-1 line in the pane"
"$SALA" lane sdk sala-test-b >/dev/null 2>&1; waitfor '[ "$(starts "$U2")" = 2 ]' 40 && fake_up sala-test-b && [ "$(pcmd b)" = sala-sdk ] && ok "b on sdk (its SDK refuses every turn: FAKE_SDK=credit)" || bad "b: starts $(starts "$U2") $(pcmd b)"
posts0=$(grep -c '^%%$' "$POSTS" 2>/dev/null)
$T send-keys -t sala-test-b -l 'spend a little'; $T send-keys -t sala-test-b Enter
waitfor '[ "$(starts "$U2")" = 3 ]' 40 && fake_up sala-test-b && ok "the pane relaunched by itself after the refusal" || bad "b after the refusal: starts $(starts "$U2") $(screen b | tail -6)"
[ "$(lane_row sala-test-b)" = subscription-1 ] && ok "the row rewritten: sala-test-b → subscription-1" || bad "row: '$(lane_row sala-test-b)'"
waitfor '[ "$(pcmd b)" = claude ]' 10 && [ "$(lanelog "$U2")" = "key=n hdr=n cfg=-" ] && [ "$(proc_lane "$(cpid b)")" = subscription-1 ] && ok "the pane's program is claude on the subscription-1 line, no key" || bad "b after: $(pcmd b) $(lanelog "$U2") $(proc_lane "$(cpid b)")"
waitfor "[ \"\$(grep -c '^%%$' '$POSTS' 2>/dev/null)\" = $((posts0 + 1)) ]" 10 && grep -q 'sala-test-b is back on the Ultra login' "$POSTS" && grep -q 'The API credit refused its turn' "$POSTS" && grep -q 'salamander lane sdk sala-test-b' "$POSTS" \
    && ok "one post, in plain words: back on the Ultra login, why, and the way back" || bad "posts: $(tail -c 800 "$POSTS")"
grep -q $'\tfallback\tsala-test-b\tsdk → subscription-1 (the credit refused a turn)' "$SALA_LANE_LOG" && ok "lanes.log: the fallback line" || bad "lanes.log: $(tail -3 "$SALA_LANE_LOG")"
# the driver wrote the shared credit record when it left with the refusal (real clock, by the session); put the fixed stamp back
python3 -I -c 'import json,sys,time; d=json.load(open(sys.argv[1])); assert d["by"]=="sdk-pane sala-test-b" and abs(d["refused_at"]-time.time())<600 and ("billing_error" in d["detail"].lower() or "credit balance" in d["detail"].lower()), d' "$CREC" \
    && ok "the credit record: written by the driver (by sdk-pane sala-test-b, now, the refusal as detail)" || bad "credit record after the refusal: $(cat "$CREC" 2>/dev/null)"
rec_at $REFAT
grep -qE '^sala-test-b +subscription-1 +subscription-1' <<< "$("$SALA" lane)" && ok "the table: recorded subscription-1, running subscription-1" || bad "table: $("$SALA" lane)"
screen b | grep -q 'the API refused the turn (billing_error)' || $T capture-pane -p -S - -t sala-test-b | grep -q 'the API refused the turn (billing_error)' && ok "the refusal was printed in the pane before the switch" || bad "scrollback: $($T capture-pane -p -S - -t sala-test-b | tail -12)"

echo "== the CLI dying: the pane at its shell with a line; the next revive resumes it on sdk (a shell pane with a map row)"
"$SALA" adopt sala-test-a >/dev/null 2>&1 && [ "$(ledger_row sala-test-a | cut -f2)" = "$U1" ] && ok "a adopted into the pane map (its row, from the SDK CLI's registry row)" || bad "adopt: $("$SALA" adopt sala-test-a 2>&1)"
kill -9 "$(cpid a)"
waitfor '[ "$(pcmd a)" = bash ]' 20 && ok "the CLI killed: the driver and the wrapper ended, the pane is at its shell" || bad "pane after the kill: $(pcmd a)"
screen a | grep -q 'sala-sdk: the CLI died (exit' && screen a | grep -q 'the driver ended (exit 1)' && ok "the pane says what happened and that a revive resumes it" || bad "screen: $(screen a | tail -4)"
out=$("$SALA" revive --force --only sala-test-a 2>&1); rc=$?
waitfor '[ "$(starts "$U1")" = 4 ]' 40 && fake_up sala-test-a && [ "$(pcmd a)" = sala-sdk ] && [ "$(lanelog "$U1")" = "key=y hdr=y cfg=-" ] && ok "revive on the shell pane: resumed through the pane program, on sdk" || bad "revive after the kill ($rc): $out / starts $(starts "$U1") $(pcmd a)"
grep -qF "lane: none → sdk" <<< "$out" && ok "the lane line for a shell pane: none → sdk" || bad "revive: $out"

echo "== the wrapper's own credit gate: typed with a fresh refusal on record, it runs the subscription-1 line in the pane"
$T new-session -d -s sala-test-g -c "$HOME" -x 110 -y 30 -e FAKE_NAME=sala-test-g -e FAKE_LOG="$FAKE_LOG" -e FAKE_LANE_LOG="$FAKE_LANE_LOG" -e FAKE_TYPED_LOG="$FAKE_TYPED_LOG" -e SALA_LANE_SDK_NOW=$UNTIL
lane_write sala-test-g sdk
$T send-keys -t sala-test-g "$SALA_BIN sdk-pane $U7 sala-test-g" Enter
waitfor '[ "$(starts "$U7")" = 1 ]' 40 && fake_up sala-test-g && ok "a claude came up in g" || bad "g: $(screen g | tail -5)"
waitfor '[ "$(pcmd g)" = claude ]' 10 && [ "$(lanelog "$U7")" = "key=n hdr=n cfg=-" ] && [ "$(proc_lane "$(cpid g)")" = subscription-1 ] && ok "on the subscription-1 line: the program claude, no key" || bad "g: $(pcmd g) $(lanelog "$U7") $(proc_lane "$(cpid g)")"
$T capture-pane -p -S - -t sala-test-g | grep -q 'sala-sdk: the API credit refused a call' && ok "the pane says the credit refused and that it resumed on subscription-1" || bad "g scrollback: $($T capture-pane -p -S - -t sala-test-g | grep sala-sdk)"
[ "$(lane_row sala-test-g)" = sdk ] && [ "$(SALA_LANE_SDK_NOW=$UNTIL "$SALA" lane 2>&1 | grep -c 'sala-test-g .*the API credit refused a call')" = 1 ] && ok "the row stays sdk; the table with a fresh refusal says it launches on subscription-1 until cleared" || bad "g row $(lane_row sala-test-g) / $(SALA_LANE_SDK_NOW=$UNTIL "$SALA" lane 2>&1 | grep sala-test-g)"
grep -qE '^sala-test-g +sdk +subscription-1 +← runs on subscription-1' <<< "$("$SALA" lane)" && ok "the table now (the refusal old): runs on subscription-1, a relaunch puts it on sdk" || bad "table: $("$SALA" lane | grep sala-test-g)"

echo "== the pane program's own refusals"
out=$("$SALA" sdk-pane 2>&1); [ $? = 2 ] && grep -q '^usage: salamander sdk-pane' <<< "$out" && ok "no uuid: usage, exit 2" || bad "sdk-pane without args: $out"
out=$("$SALA" sdk-pane not-a-uuid sala-test-a 2>&1); [ $? = 2 ] && grep -q 'not a conversation id' <<< "$out" && ok "a bad uuid: refused" || bad "bad uuid: $out"
out=$("$SALA" sdk-pane "$UX" sala-test-a --model 'opus[1m]' 2>&1); [ $? = 2 ] && grep -q 'bad model' <<< "$out" && ok "a model that could not be typed: refused" || bad "bad model: $out"

echo "== the mod in the SDK's CLI: its ok ends nothing there — sala lane subscription-1 ends the pane through its box and relaunches on subscription-1"
# The real SDK's CLI loads the mod from the user settings, and the mod's exit request answers ok and runs /exit, which ends
# nothing in a CLI the SDK drives (a board session sat at the driver's box, "claude didn't exit within 30s"). Here a's
# SDK CLI "has the mod": a fresh stamp for its conversation and a fake mod on its messaging socket that answers draft with an
# empty box and exit with ok — and runs nothing on it, as the SDK's CLI does. Each request it heard is one line in $HEARD.
RUN="$XDG_RUNTIME_DIR/sala/mod"; MSOCK="$HOME/fakemod.sock"; HEARD="$HOME/fakemod.heard"
stamp() { mkdir -p "$RUN"; printf '{"present":true,"version":1,"sessionId":"%s","at":%s000}\n' "$1" "$(date +%s)" > "$RUN/$1.json"; }   # <uuid> — written now, as the mod stamps at the CLI's start
point_socket() { python3 -c 'import json,sys; f=sys.argv[1]; d=json.load(open(f)); d["messagingSocketPath"]=sys.argv[2]; json.dump(d,open(f,"w"),separators=(",",":"))' "$HOME/.claude/sessions/$1.json" "$MSOCK"; }   # <pid> — its registry row's socket → the fake mod's (compact, as the CLI writes it: reg_live greps it)
cat > "$HOME/fakemod.py" <<'PY'
import json, os, socket, sys, threading
sock, run, heard, sidf = sys.argv[1:5]
try: os.unlink(sock)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX); s.bind(sock); s.listen(8)
def serve(c):
    data = b""
    while not data.endswith(b"\n"):
        b = c.recv(65536)
        if not b: break
        data += b
    c.close()
    try: text = json.loads(data)["message"]["content"]
    except Exception: return
    if not text.startswith("[sala-mod] "): return
    verb, req, *rest = text[len("[sala-mod] "):].split("\n")[0].split(" ")
    open(heard, "a").write(verb + " " + req + "\n")
    out = {"reqid": req, "ok": True}
    if verb == "draft": out["text"] = ""
    sid = open(sidf).read().strip(); os.makedirs(run, exist_ok=True)
    tmp = os.path.join(run, "%s.%s.reply.json.tmp" % (sid, req)); open(tmp, "w").write(json.dumps(out) + "\n"); os.replace(tmp, tmp[:-4])
while True:
    c, _ = s.accept(); threading.Thread(target=serve, args=(c,), daemon=True).start()
PY
echo "$U1" > "$HOME/fakemod.sid"; python3 "$HOME/fakemod.py" "$MSOCK" "$RUN" "$HEARD" "$HOME/fakemod.sid" & FAKEMOD=$!
waitfor '[ -S "$MSOCK" ]' 20 || bad "the fake mod did not start"
heard() { grep -c "^$1 " "$HEARD" 2>/dev/null || echo 0; }   # <verb> → how many requests of it the fake mod answered
[ "$(pcmd a)" = sala-sdk ] && [ "$(lane_row sala-test-a)" = sdk ] && ok "a is on sdk (its program sala-sdk)" || bad "a: $(pcmd a) row '$(lane_row sala-test-a)'"
old=$(cpid a); stamp "$U1"; point_socket "$old"; : > "$SALA_MOD_LOG"; typed0=$(grep -cF "$U1 /exit" "$FAKE_TYPED_LOG")
mod_request "$old" exit; rc=$?; sleep 1
[ "$rc" = 0 ] && [ "$(heard exit)" = 1 ] && fake_up sala-test-a && [ "$(pcmd a)" = sala-sdk ] && [ -e "$HOME/.claude/sessions/$old.json" ] && ok "the mod answers exit with ok and the SDK's CLI goes on as before: registered, the pane at the driver's box" || bad "mod_request exit: rc=$rc why='$MOD_WHY' heard $(heard exit) pcmd $(pcmd a)"
out=$("$SALA" lane subscription-1 sala-test-a 2>&1); rc=$?
[ "$rc" = 0 ] && grep -qF "sala-test-a:0: /exit (9.9.9) → resume $U1 · lane: sdk → subscription-1" <<< "$out" && ok "sala lane subscription-1 sala-test-a: exit 0, the lane line sdk → subscription-1" || bad "lane subscription-1 ($rc): $out"
waitfor '[ "$(starts "$U1")" = 5 ]' 40 && fake_up sala-test-a && ok "relaunched within the sweep: the fake came up again" || bad "no relaunch: starts $(starts "$U1") / $(screen a | tail -4) / $(tail -3 "$RLOG")"
waitfor '[ "$(pcmd a)" = claude ]' 10 && [ "$(lanelog "$U1")" = "key=n hdr=n cfg=-" ] && [ "$(proc_lane "$(cpid a)")" = subscription-1 ] && ok "the pane's program is claude on the subscription-1 line, no key" || bad "a after: $(pcmd a) $(lanelog "$U1") $(proc_lane "$(cpid a)")"
! kill -0 "$old" 2>/dev/null && [ ! -e "$HOME/.claude/sessions/$old.json" ] && ok "the SDK's CLI is gone, its registry row with it" || bad "old CLI $old: alive=$(kill -0 "$old" 2>/dev/null && echo y || echo n) row=$([ -e "$HOME/.claude/sessions/$old.json" ] && echo y || echo n)"
[ "$(heard exit)" = 2 ] && grep -q "exit sala-test-a via mod (ok) then keys (an SDK-driven CLI" "$SALA_MOD_LOG" && [ "$(grep -cF "$U1 /exit" "$FAKE_TYPED_LOG")" = $((typed0 + 1)) ] \
    && ok "the sweep asked the mod (its gates), took the ok, and typed /exit into the box: the driver's disconnect left the CLI by /exit" || bad "heard $(heard exit) / mod log: $(<"$SALA_MOD_LOG") / typed: $(grep -cF "$U1 /exit" "$FAKE_TYPED_LOG") vs $typed0"
grep -qF "sala-test-a:0: 9.9.9 → 9.9.9" <<< "$out" && grep -qE '^sala-test-a +subscription-1 +subscription-1' <<< "$("$SALA" lane)" && ok "the summary row; the table: recorded subscription-1, running subscription-1" || bad "summary/table: $out / $("$SALA" lane)"

echo "== pane_exit's own keys on an sdk pane with the mod: refused over a draft (the gate kept), else /exit typed into the box; the pane at its shell, the CLI gone"
"$SALA" lane sdk sala-test-a >/dev/null 2>&1; waitfor '[ "$(starts "$U1")" = 6 ]' 40 && fake_up sala-test-a && waitfor '[ "$(pcmd a)" = sala-sdk ]' 10 && ok "a back on sdk" || bad "a back on sdk: starts $(starts "$U1") $(pcmd a)"
old=$(cpid a); stamp "$U1"; point_socket "$old"; pane=$(tmux display -p -t sala-test-a '#{pane_id}'); : > "$SALA_MOD_LOG"; e0=$(heard exit); typed0=$(grep -cF "$U1 /exit" "$FAKE_TYPED_LOG")
$T send-keys -t sala-test-a -l 'not sent yet'; sleep 0.5
d=$(pane_exit "$pane" "$old"); rc=$?
[ "$rc" = 3 ] && [ "$d" = "not sent yet" ] && [ "$(heard exit)" = "$e0" ] && [ "$(pcmd a)" = sala-sdk ] && [ "$(pane_draft_screen sala-test-a)" = "not sent yet" ] && ok "a draft in the box: refused (3) with its text, the mod not asked, nothing typed, the draft still there" || bad "pane_exit over a draft: rc=$rc d='$d' heard $(heard exit) vs $e0 pcmd $(pcmd a) box '$(pane_draft_screen sala-test-a)'"
$T send-keys -t sala-test-a C-u; sleep 0.3
d=$(pane_exit "$pane" "$old"); rc=$?
[ "$rc" = 0 ] && [ "$(heard exit)" = $((e0 + 1)) ] && grep -q "exit sala-test-a via mod (ok) then keys" "$SALA_MOD_LOG" && ok "an empty box: the mod asked and ok, /exit typed by pane_exit's keys (rc 0)" || bad "pane_exit: rc=$rc d='$d' heard $(heard exit) vs $e0 / $(<"$SALA_MOD_LOG")"
waitfor '[ "$(pcmd a)" = bash ]' $((SALA_EXIT_WAIT * 2)) && ok "the pane is back at its shell within the exit_wait window (${SALA_EXIT_WAIT}s)" || bad "pane after pane_exit: $(pcmd a) / $(screen a | tail -4)"
! kill -0 "$old" 2>/dev/null && [ ! -e "$HOME/.claude/sessions/$old.json" ] && [ "$(grep -cF "$U1 /exit" "$FAKE_TYPED_LOG")" = $((typed0 + 1)) ] && ok "the SDK's CLI left by /exit (the driver's disconnect), its registry row gone; the driver and the wrapper ended" || bad "old CLI $old: alive=$(kill -0 "$old" 2>/dev/null && echo y || echo n) row=$([ -e "$HOME/.claude/sessions/$old.json" ] && echo y || echo n) typed $(grep -cF "$U1 /exit" "$FAKE_TYPED_LOG") vs $typed0"
[ -z "$(pgrep -f "sdk-pane/driver.py --resume $U1 --key-file $KEYF" 2>/dev/null)" ] && ok "no driver left on the conversation" || bad "a driver still runs: $(pgrep -af "sdk-pane/driver.py --resume $U1 --key-file $KEYF")"

echo "== the pane's tmux server dies under an sdk pane (a reboot, kill-server): the driver and its CLI are gone, no orphan on the conversation"
# The pane's pty goes with the server, and every write to it fails from then on. The driver's finish() used to print its
# line before setting done, so the SIGHUP's leave raised on the dead pty and the driver waited for ever (orphans on
# a test host from this suite's own runs); a real CLI left alive under one would block every resume as "already
# live". The suite's cleanup kills what this check would have left.
"$SALA" lane sdk sala-test-a >/dev/null 2>&1; waitfor '[ "$(starts "$U1")" = 7 ]' 40 && fake_up sala-test-a && waitfor '[ "$(pcmd a)" = sala-sdk ]' 10 && ok "a on sdk once more" || bad "a on sdk: starts $(starts "$U1") $(pcmd a)"
old=$(cpid a); dp=$(driver_pid a); [ -n "$dp" ] && ok "its driver runs (pid $dp)" || bad "no driver found under a"
$T kill-server 2>/dev/null; tmux_socket_rm
waitfor '! kill -0 "$dp" 2>/dev/null' 10 && ok "the server gone: the driver ended within 5 s" || bad "the driver $dp outlives its pty ($(ps -o stat=,wchan= -p "$dp" 2>/dev/null))"
waitfor '! kill -0 "$old" 2>/dev/null' 10 && ok "and the SDK's CLI with it: nothing live on the conversation" || bad "the CLI $old still runs"

[ "$fail" = 0 ] && echo "sdklane: pass" || echo "sdklane: FAIL"
exit $fail
