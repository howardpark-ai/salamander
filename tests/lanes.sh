#!/usr/bin/env bash
# Lanes (lib/common.sh "lanes", lib/lane.sh): which account or key a pane's claude runs on, and
# that every relaunch keeps it. What is checked guards the relaunch paths and the key: the launch-line prefix per lane and
# that it carries the key file's PATH, never its value (a dummy key in the temporary HOME; the value is counted in the
# process's environment, never printed); `sala lane` recording a session's lane and relaunching it on it through the
# direct sweep, a recycle bringing each pane back on its own lane, `--all` setting the default and recycling, a new spawn
# landing on the default, the invoking pane relaunched last by the self-worker; a lane whose key file is missing refused
# before anything is recorded or relaunched; `--dry-run` recording and relaunching nothing and naming the variables, not
# the value; a SALA_NO_RELAUNCH session refused by name and left out of `--all`; `watch` on the api lane typing no
# /remote-control into the master (and typing it on a claude.ai lane: the positive control); rename and retire carrying
# or dropping the row. Revive's lane line and the dry runs (lib/revive.sh, THE LANE LINE) are
# tests/lanes-revive.sh, split out so the two run side by side. Posts stubbed to a file; isolated HOME, a private
# tmux socket, the compiled fake claude (tests/fake-claude.c, FAKE_LANE_LOG). Usage: bash tests/lanes.sh   (exit 0 = pass; ~60 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_SET SALA_SET_SELF SALA_POST_RECYCLE_CMD SALA_RECYCLE SALA_RETRY_WORKER SALA_NO_RELAUNCH SALA_MASTER
unset ANTHROPIC_API_KEY ANTHROPIC_CUSTOM_HEADERS CLAUDE_CONFIG_DIR SALA_LANE_API_KEY_FILE SALA_LANE_API_WORKSPACE_FILE SALA_LANE_API_MCP_CONFIG SALA_LANE_TEAM_DIR ENABLE_PROMPT_CACHING_1H ENABLE_PROMPT_CACHING_1H_BEDROCK
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, tmux_socket_rm
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
as_op_unit   # no master: the guarded verbs this suite runs itself stand for the queue's runner (tests/lib.sh, 5)
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$HOME/.local/share/claude/versions/9.9.9" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
ln -s "$HOME/.local/share/claude/versions/9.9.9" "$HOME/.local/bin/claude"   # as the CLI installs it: the launcher target's name is the version
printf '#!/bin/sh\necho "$*" >> "%s/systemd-run.txt"\n' "$HOME" > "$HOME/.local/bin/systemd-run"; chmod +x "$HOME/.local/bin/systemd-run"   # watch launches nothing
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log" FAKE_LANE_LOG="$HOME/fake-lane.log" FAKE_TYPED_LOG="$HOME/typed.log" FAKE_CACHE_LOG="$HOME/fake-cache.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="{ cat; echo '%%'; } >> $POSTS"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off
SALA="$ROOT/bin/salamander"; SOCK="sala-lanes-$$"; T="tmux -L $SOCK -f /dev/null"; RLOG="$HOME/.claude/salamander-revive.log"; WLOG="$HOME/.claude/salamander-watch.log"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's (common.sh, on_fleet_server)
# the lanes' files: a DUMMY key (never a real one), a workspace id, a subscription-2 directory signed in; no second login besides subscription-2
KEYF="$HOME/.config/anthropic/api-key"; WSF="$HOME/.config/anthropic/workspace-id"; DUMMY="dummy-key-NOT-REAL-$$"; WSID="wsid_dummy_$$"
mkdir -p "$HOME/.config/anthropic" "$HOME/.claude-team"; (umask 077; printf '%s\n' "$DUMMY" > "$KEYF"); printf '%s\n' "$WSID" > "$WSF"
printf '{"fake":true}\n' > "$HOME/.claude-team/.credentials.json"
cleanup() {
    local f p; for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    for p in $(pgrep -x claude); do [ "$HOME/.local/share/claude/versions/9.9.9" -ef "/proc/$p/exe" ] && kill -9 "$p" 2>/dev/null; done
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux    # literal socket: the children run set -u
. "$ROOT/lib/common.sh"
wait_lock() { lock_wait "$HOME/.claude/salamander-recycle.lock" 80; }
mk() { local n="$1" u="$2"; shift 2; $T new-session -d -s "sala-test-$n" -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="sala-test-$n" -e FAKE_LOG="$FAKE_LOG" -e FAKE_LANE_LOG="$FAKE_LANE_LOG" -e FAKE_TYPED_LOG="$FAKE_TYPED_LOG" -e FAKE_CACHE_LOG="$FAKE_CACHE_LOG" "$@"; $T send-keys -t "sala-test-$n" 'claude' Enter; }
lanelog() { grep "^$1 " "$FAKE_LANE_LOG" 2>/dev/null | tail -1 | cut -d' ' -f2-; }   # <uuid> → "key=… hdr=… cfg=…" of its latest start
cachelog() { grep "^$1 " "$FAKE_CACHE_LOG" 2>/dev/null | tail -1 | cut -d' ' -f2-; }   # <uuid> → "cache1h=<plain switch> cache1h_bedrock=<bedrock switch>" of its latest start ("-" unset)
default_file() { head -1 "$SALA_LANE_DEFAULT_FILE" 2>/dev/null; }
U1=$(uuid 1); U2=$(uuid 2); U3=$(uuid 3); UX=$(uuid 9)

echo "== the launch-line prefix per lane: the key file's path, never its value"
[ -z "$(lane_env_prefix subscription-1)" ] && ok "subscription-1: nothing on the line" || bad "subscription-1 prefix: '$(lane_env_prefix subscription-1)'"
p=$(lane_env_prefix api)
case "$p" in *"ANTHROPIC_API_KEY=\"\$(cat $KEYF)\" "*"ANTHROPIC_CUSTOM_HEADERS=\"anthropic-workspace-id: \$(cat $WSF)\" "*) ok "api: ANTHROPIC_API_KEY and the workspace header, each \$(cat <file>) for the pane's shell" ;; *) bad "api prefix: '$p'" ;; esac
! grep -qF "$DUMMY" <<< "$p" && ! grep -qF "$WSID" <<< "$p" && ok "api: neither value is in the typed text" || bad "a value leaked into the prefix"
[ "$(lane_env_names api)" = "ANTHROPIC_API_KEY ANTHROPIC_CUSTOM_HEADERS ENABLE_PROMPT_CACHING_1H" ] && ok "api: the names a dry run shows (the key, the header and the pane's 1-hour cache switch)" || bad "lane_env_names api: $(lane_env_names api)"
[ "$(lane_env_prefix team)" = "CLAUDE_CONFIG_DIR=$HOME/.claude-team " ] && ok "team: CLAUDE_CONFIG_DIR=<its directory>" || bad "team prefix: '$(lane_env_prefix team)'"
n=$(eval "$(lane_env_prefix api)env" | grep -c "^ANTHROPIC_API_KEY=$DUMMY\$"); h=$(eval "$(lane_env_prefix api)env" | grep -c "^ANTHROPIC_CUSTOM_HEADERS=anthropic-workspace-id: $WSID\$")
[ "$n" = 1 ] && [ "$h" = 1 ] && ok "run by a shell, the line hands the process the key and the header from the files (counted, not printed)" || bad "evaluated prefix: key=$n header=$h"
case "$p" in *"ENABLE_PROMPT_CACHING_1H=1 ") ok "api: the line ends with ENABLE_PROMPT_CACHING_1H=1 (the 1-hour prompt cache, which an API key does not get on its own)" ;; *) bad "api prefix lacks the 1-hour cache switch: '$p'" ;; esac
[ "$(eval "${p}env" | grep -c '^ENABLE_PROMPT_CACHING_1H=1$')" = 1 ] && ! grep -q BEDROCK <<< "$p" && ok "run by a shell, the process gets ENABLE_PROMPT_CACHING_1H=1 once, and not bedrock's variant" || bad "evaluated prefix: cache switch"
pj=$(lane_env_prefix api job)
[ "$pj" = "${p%ENABLE_PROMPT_CACHING_1H=1 }" ] && ! grep -q ENABLE_PROMPT_CACHING <<< "$pj" && ok "lane_env_prefix api job: the same key and header and no cache switch (a one-shot job never reuses a 1-hour write)" || bad "api job prefix: '$pj'"
[ -z "$(lane_env_prefix sdk)" ] && ! grep -q ENABLE_PROMPT_CACHING <<< "$(lane_env_prefix subscription-1; lane_env_prefix subscription-2)" && ok "subscription-1, subscription-2 and sdk carry no cache switch (the subscriptions get the 1 hour on their own; sdk's line is no claude line)" || bad "subscription-1/subscription-2/sdk carry a cache switch"
lane_check api >/dev/null && ok "lane_check api: the files are there" || bad "lane_check api: $(lane_check api)"
lane_check subscription-2 >/dev/null && ok "lane_check subscription-2: the directory is signed in" || bad "lane_check subscription-2: $(lane_check subscription-2)"
why=$(lane_check bogus); [ $? = 1 ] && grep -q 'unknown lane' <<< "$why" && ok "an unknown word is no lane, and the refusal says so" || bad "lane_check bogus: $why"
why=$(lane_check bedrock); [ $? = 1 ] && grep -q 'no \[example-bedrock\] profile' <<< "$why" && ok "bedrock: refused while the profile is not in the credentials file (its own suite: tests/bedrocklane.sh)" || bad "lane_check bedrock: $why"
lane_check bogus >/dev/null 2>&1 && bad "an unknown lane passed" || ok "an unknown lane is refused"
: > "$HOME/.claude-team/.credentials.json"; lane_check team >/dev/null && bad "team passed with no login in its directory" || ok "team with an empty .credentials.json: refused (a login, not just a directory)"
printf '{"fake":true}\n' > "$HOME/.claude-team/.credentials.json"

echo "== resume_cmd: the session's lane on the resume line (every relaunch path builds it here)"
[ "$(resume_cmd "$UX")" = "$(mod_env_prefix)claude --resume $UX" ] && ok "no session, nothing recorded: the line as before (subscription-1)" || bad "resume_cmd: $(resume_cmd "$UX")"
lane_write sala-test-x api && [ "$(lane_for_session sala-test-x)" = api ] && ok "lane_write: the row is read back" || bad "lane_write/lane_for_session: $(slurp "$SALA_LANES")"
r=$(resume_cmd "$UX" sala-test-x)
case "$r" in "ANTHROPIC_API_KEY=\"\$(cat $KEYF)\" "*"claude --resume $UX") ok "a session on api: the key prefix, then the resume" ;; *) bad "resume_cmd on api: $r" ;; esac
! grep -qF "$DUMMY" <<< "$r" && ok "the resume line carries no key value" || bad "the key value is on the resume line"
mkdir -p "$HOME/.config/claude-lanes"; echo '{"mcpServers":{}}' > "$HOME/.config/claude-lanes/api-mcp.json"
case "$(resume_cmd "$UX" sala-test-x)" in *" --mcp-config $HOME/.config/claude-lanes/api-mcp.json") ok "api with the mcp-config file present: --mcp-config <file> appended" ;; *) bad "no --mcp-config: $(resume_cmd "$UX" sala-test-x)" ;; esac
n=$(resume_cmd "$UX" sala-test-x | grep -o -- '--mcp-config' | wc -l)
[ "$n" = 1 ] && ok "api: --mcp-config exactly once (the line is built fresh, never appended to an old one)" || bad "--mcp-config $n times: $(resume_cmd "$UX" sala-test-x)"
rm -f "$HOME/.config/claude-lanes/api-mcp.json"
case "$(resume_cmd "$UX" sala-test-x)" in *"--mcp-config"*) bad "--mcp-config without the file" ;; *) ok "without the file: no --mcp-config" ;; esac

echo "== resume_cmd: --model <family> from the conversation's own transcript (a /model pin outlived a relaunch)"
UM=$(uuid 7); TM="$HOME/.claude/projects/x/$UM.jsonl"
arec() {  # <model> [extra json fields] → one assistant record
    printf '{"type":"assistant","isSidechain":false,"message":{"model":"%s","role":"assistant","content":[{"type":"text","text":"x"}]}%s,"sessionId":"%s"}\n' "$1" "${2:-}" "$UM"
}
{ arec claude-sonnet-5 ',"effort":"medium"'; arec claude-opus-5 ',"effort":"high"'; arec claude-opus-5 ',"effort":"high"'; } > "$TM"
[ "$(resume_cmd "$UM")" = "$(mod_env_prefix)claude --resume $UM --model opus --effort high" ] && ok "an opus version pin (claude-opus-5): --model opus, the effort kept" || bad "opus pin: $(resume_cmd "$UM")"
arec claude-sonnet-5-5 ',"effort":"medium"' >> "$TM"
case "$(resume_cmd "$UM")" in *" --model sonnet "*) ok "the newest turn on sonnet: --model sonnet (a family picked on purpose stays)" ;; *) bad "sonnet: $(resume_cmd "$UM")" ;; esac
{ arec claude-fable-5-1; arec claude-haiku-4-5-20251001; } >> "$TM"
case "$(resume_cmd "$UM")" in *" --model haiku "*|*" --model haiku") ok "claude-haiku-*: --model haiku" ;; *) bad "haiku: $(resume_cmd "$UM")" ;; esac
arec claude-fable-5 >> "$TM"; [ "$(model_family_for_uuid "$UM")" = fable ] && ok "claude-fable-*: fable" || bad "fable: $(model_family_for_uuid "$UM")"
arec opus >> "$TM"; [ "$(model_family_for_uuid "$UM")" = opus ] && ok "a bare opus alias: opus" || bad "bare opus: $(model_family_for_uuid "$UM")"
arec claude-sonnet-5 >> "$TM"
arec '<synthetic>' ',"error":"rate_limit","isApiErrorMessage":true' >> "$TM"
arec claude-opus-5 ',"isApiErrorMessage":true,"apiErrorStatus":529' >> "$TM"
arec '<synthetic>' >> "$TM"
[ "$(model_family_for_uuid "$UM")" = sonnet ] && ok "newer <synthetic> and API-error records skipped: the last real turn's family (sonnet)" || bad "synthetic/API error not skipped: $(model_family_for_uuid "$UM")"
arec claude-opus-5 ',"attributionSkill":"some-skill"' >> "$TM"
[ "$(model_family_for_uuid "$UM")" = sonnet ] && ok "a skill's own pinned turn is not the conversation's family" || bad "skill turn taken: $(model_family_for_uuid "$UM")"
{ arec '<synthetic>'; arec gpt-unknown-1; } > "$TM"
r=$(resume_cmd "$UM"); case "$r" in *--model*) bad "an unknown model gave a --model: $r" ;; *) ok "only <synthetic> and an unknown model: no --model" ;; esac
printf '{"type":"user","message":{"role":"user","content":"hi"}}\nnot json\n' > "$TM"
[ "$(resume_cmd "$UM")" = "$(mod_env_prefix)claude --resume $UM" ] && ok "no assistant record: the line as before" || bad "no model: $(resume_cmd "$UM")"
chmod 000 "$TM"; [ "$(resume_cmd "$UM")" = "$(mod_env_prefix)claude --resume $UM" ] && ok "unreadable transcript: the line as before" || bad "unreadable: $(resume_cmd "$UM")"
chmod 600 "$TM"; arec claude-opus-5 ',"effort":"xhigh"' > "$TM"
mkdir -p "$HOME/.config/claude-lanes"; echo '{"mcpServers":{}}' > "$HOME/.config/claude-lanes/api-mcp.json"
r=$(resume_cmd "$UM" sala-test-x)
case "$r" in "ANTHROPIC_API_KEY=\"\$(cat $KEYF)\" "*"claude --resume $UM --model opus --effort xhigh --mcp-config $HOME/.config/claude-lanes/api-mcp.json") ok "api lane with a transcript: --model, --effort, then one --mcp-config" ;; *) bad "api + model: $r" ;; esac
[ "$(grep -o -- '--mcp-config' <<< "$r" | wc -l)" = 1 ] && ok "and --mcp-config still once" || bad "--mcp-config count: $r"
rm -f "$HOME/.config/claude-lanes/api-mcp.json" "$TM"
lane_rename sala-test-x sala-test-y; [ -z "$(lane_row sala-test-x)" ] && [ "$(lane_row sala-test-y)" = api ] && ok "lane_rename moves the row (sala rename)" || bad "after rename: $(<"$SALA_LANES")"
lane_drop sala-test-y; [ -z "$(lane_row sala-test-y)" ] && [ "$(lane_for_session sala-test-y)" = subscription-1 ] && ok "lane_drop: the row is gone, the session is back on the default (sala retire)" || bad "after drop: $(<"$SALA_LANES")"
lane_set_default subscription-2; [ "$(lane_default)" = subscription-2 ] && [ "$(lane_for_session nobody)" = subscription-2 ] && ok "lane_set_default: a session without a row follows the default" || bad "default: $(lane_default)"
lane_set_default subscription-1

echo "== the verb: the table and the default"
out=$("$SALA" lane 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q '^default lane: subscription-1' <<< "$out" && grep -q 'bedrock not ready' <<< "$out" && grep -q 'aws-platform not ready' <<< "$out" && ! grep -qE 'bogus (not )?ready' <<< "$out" && ok "sala lane: the default and which lanes are ready" || bad "sala lane ($rc): $out"
"$SALA" lane default subscription-2 >/dev/null 2>&1 && [ "$(default_file)" = subscription-2 ] && ok "sala lane default subscription-2: recorded" || bad "lane default subscription-2: $(default_file)"
grep -q '^default lane: subscription-2' <<< "$("$SALA" lane)" && ok "the table shows it" || bad "table after default subscription-2: $("$SALA" lane)"
"$SALA" lane default subscription-1 >/dev/null 2>&1 && [ "$(default_file)" = subscription-1 ] && ok "and back to subscription-1" || bad "lane default subscription-1: $(default_file)"
# --dry-run writes nothing (`sala lane default api --dry-run` wrote the default lane)
rm -f "$SALA_LANE_DEFAULT_FILE"
out=$("$SALA" lane default api --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && [ ! -e "$SALA_LANE_DEFAULT_FILE" ] && ok "lane default api --dry-run with no default file: exit 0, the file still absent" || bad "lane default --dry-run, no file ($rc): $out / $(default_file)"
grep -qF '[dry-run] would set the default lane: api (was subscription-1)' <<< "$out" && grep -q 'nothing recorded' <<< "$out" && ok "and it prints the dry-run line" || bad "dry-run line: $out"
"$SALA" lane default subscription-2 >/dev/null 2>&1; before=$(slurp "$SALA_LANE_DEFAULT_FILE")
out=$("$SALA" lane default api --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$before" = subscription-2 ] && [ "$(slurp "$SALA_LANE_DEFAULT_FILE")" = subscription-2 ] && grep -qF '(was subscription-2)' <<< "$out" && ok "lane default api --dry-run over subscription-2: the file unchanged" || bad "lane default --dry-run over subscription-2 ($rc): $out / $(default_file)"
"$SALA" lane default subscription-1 >/dev/null 2>&1; [ "$(default_file)" = subscription-1 ] || bad "default not back to subscription-1: $(default_file)"
out=$("$SALA" lane default bogus 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'unknown lane' <<< "$out" && [ "$(default_file)" = subscription-1 ] && ok "sala lane default bogus: refused, the default untouched" || bad "lane default bogus ($rc): $out / $(default_file)"
"$SALA" lane api >/dev/null 2>&1; [ $? = 1 ] && ok "a lane with no session and no --all: refused" || bad "sala lane api (no sessions) did not refuse"
"$SALA" lane bogus sala-test-a >/dev/null 2>&1; [ $? = 1 ] && ok "an unknown lane: refused" || bad "sala lane bogus did not refuse"

echo "== two panes on the fake claude, launched by hand (the subscription-1 lane)"
mk a "$U1"; mk b "$U2"; fake_up sala-test-a sala-test-b
[ "$(lanelog "$U1")" = "key=n hdr=n cfg=-" ] && [ "$(lanelog "$U2")" = "key=n hdr=n cfg=-" ] && ok "both started with no key and no config directory" || bad "lane log: $(<"$FAKE_LANE_LOG")"
mv "$KEYF" "$KEYF.away"
out=$("$SALA" lane api sala-test-a 2>&1); rc=$?
[ "$rc" = 1 ] && grep -qF "$KEYF" <<< "$out" && ok "key file missing: refused, naming the file" || bad "lane api with no key file ($rc): $out"
[ -z "$(lane_row sala-test-a)" ] && [ "$(starts "$U1")" = 1 ] && ok "nothing recorded, nothing relaunched" || bad "recorded '$(lane_row sala-test-a)', starts $(starts "$U1")"
mv "$KEYF.away" "$KEYF"

echo "== sala lane api <session>: recorded, relaunched on it through the direct sweep"
out=$("$SALA" lane api sala-test-a 2>&1); rc=$?
[ "$rc" = 0 ] && ok "exit 0" || bad "sala lane api sala-test-a ($rc): $out"
waitfor '[ "$(starts "$U1")" = 2 ]' 40 && ok "sala-test-a relaunched" || bad "no relaunch: $(<"$FAKE_LOG")"
fake_up sala-test-a
[ "$(lanelog "$U1")" = "key=y hdr=y cfg=-" ] && ok "its claude started with the key and the header in its environment" || bad "lane log for a: $(lanelog "$U1")"
[ "$(cachelog "$U1")" = "cache1h=1 cache1h_bedrock=-" ] && ok "and with ENABLE_PROMPT_CACHING_1H=1 (the api pane's 1-hour cache), not bedrock's variant" || bad "cache switch of the api pane: $(cachelog "$U1")"
[ "$(lane_row sala-test-a)" = api ] && ok "recorded: sala-test-a → api" || bad "row: '$(lane_row sala-test-a)'"
[ "$(starts "$U2")" = 1 ] && [ -z "$(lane_row sala-test-b)" ] && ok "sala-test-b untouched, unrecorded" || bad "b: starts $(starts "$U2"), row '$(lane_row sala-test-b)'"
grep -qE '^sala-test-a +api +api' <<< "$("$SALA" lane)" && ok "the table: recorded api, running api (read from its environment)" || bad "table: $("$SALA" lane)"
! grep -qF "$DUMMY" <<< "$out" && ! $T capture-pane -p -S - -t sala-test-a | grep -qF "$DUMMY" && ! grep -qsF "$DUMMY" "$RLOG" "$SALA_LANE_LOG" && ! proc_args "$(cpid a)" | grep -qF "$DUMMY" \
    && ok "the key value is in none of: the command's output, the pane's scrollback, the logs, the process's argv" || bad "the key value leaked"
grep -q 'ANTHROPIC_API_KEY' <<< "$out" && ok "the output names the variable" || bad "output: $out"

echo "== a recycle brings each pane back on its own lane"
"$SALA" recycle --force >/dev/null 2>&1 || bad "recycle --force did not start"
waitfor '[ "$(starts "$U1")" = 3 ] && [ "$(starts "$U2")" = 2 ]' 60 && ok "both relaunched by the recycle" || bad "starts after recycle: a=$(starts "$U1") b=$(starts "$U2") $(tail -20 "$RLOG")"
wait_lock; fake_up sala-test-a sala-test-b
[ "$(lanelog "$U1")" = "key=y hdr=y cfg=-" ] && ok "sala-test-a is back on api" || bad "a after recycle: $(lanelog "$U1")"
[ "$(cachelog "$U1")" = "cache1h=1 cache1h_bedrock=-" ] && ok "after the recycle the api pane's relaunch line (resume_cmd) still carries ENABLE_PROMPT_CACHING_1H=1" || bad "cache switch after recycle: $(cachelog "$U1")"
[ "$(cachelog "$U2")" = "cache1h=- cache1h_bedrock=-" ] && ok "and the subscription-1 pane's does not" || bad "subscription-1 pane after recycle: $(cachelog "$U2")"
[ "$(lanelog "$U2")" = "key=n hdr=n cfg=-" ] && ok "sala-test-b is back on subscription-1" || bad "b after recycle: $(lanelog "$U2")"
grep -q 'sala-test-a:0: 9.9.9 → 9.9.9 (lane api)' "$RLOG" && ok "the summary row names the lane" || bad "no lane in the summary: $(grep 'sala-test-a:0' "$RLOG" | tail -3)"

echo "== --dry-run: names, verdicts, nothing recorded or relaunched"
tsv_before=$(slurp "$SALA_LANES")
out=$("$SALA" lane subscription-2 sala-test-b --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'CLAUDE_CONFIG_DIR' <<< "$out" && grep -q 'would /exit' <<< "$out" && ok "subscription-2 dry run: CLAUDE_CONFIG_DIR named, the sweep's verdict shown" || bad "dry run ($rc): $out"
[ -z "$(lane_row sala-test-b)" ] && [ "$(starts "$U2")" = 2 ] && [ "$(default_file)" = subscription-1 ] && ok "nothing recorded, nothing relaunched" || bad "after dry run: row '$(lane_row sala-test-b)', starts $(starts "$U2")"
out=$("$SALA" lane api sala-test-b --dry-run 2>&1)
grep -q 'ANTHROPIC_API_KEY ANTHROPIC_CUSTOM_HEADERS' <<< "$out" && ! grep -qF "$DUMMY" <<< "$out" && ! grep -qF "$WSID" <<< "$out" && ok "api dry run: the variables' names, no value" || bad "api dry run: $out"
out=$("$SALA" lane api sala-test-a --dry-run 2>&1)
grep -q 'nothing would be relaunched' <<< "$out" && ok "a session already on the lane: left alone" || bad "dry run on the same lane: $out"
out=$("$SALA" lane subscription-2 --all --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'DRY RUN: nothing recorded' <<< "$out" && [ "$(default_file)" = subscription-1 ] && ok "--all --dry-run: exit 0, the default untouched" || bad "--all dry run ($rc): $out / $(default_file)"
[ -n "$tsv_before" ] && [ "$(slurp "$SALA_LANES")" = "$tsv_before" ] && ok "the switch with --dry-run (sessions, then --all): lanes.tsv unchanged" || bad "lanes.tsv changed under --dry-run: '$tsv_before' → '$(slurp "$SALA_LANES")'"

echo "== watch on the api lane: no bridge check, nothing typed; on a claude.ai lane /remote-control is typed (the control)"
wait_lock
$T send-keys -t sala-test-a -l 'run /remote-control to reconnect'; $T send-keys -t sala-test-a Enter
waitfor "grep -q '^$U1 run /remote-control to reconnect' '$FAKE_TYPED_LOG'" 20 || bad "the fake did not take the typed line"
SALA_MASTER=sala-test-a "$SALA" watch >/dev/null 2>&1
! grep -q "^$U1 /remote-control\$" "$FAKE_TYPED_LOG" && ok "master on api, screen says disconnected: watch types no /remote-control" || bad "watch typed /remote-control into an api-lane master: $(<"$FAKE_TYPED_LOG")"
[ "$(grep -c 'no Remote Control' "$WLOG")" = 1 ] && ok "and says so in its log" || bad "watch log: $(<"$WLOG")"
SALA_MASTER=sala-test-a "$SALA" watch >/dev/null 2>&1
[ "$(grep -c 'no Remote Control' "$WLOG")" = 1 ] && ok "once, not on every tick" || bad "watch log after a second tick: $(grep -c 'no Remote Control' "$WLOG") lines"
out=$(SALA_MASTER=sala-test-a "$SALA" watch --check 2>&1); grep -q 'no Remote Control (the api lane)' <<< "$out" && ok "watch --check: healthy, no Remote Control on the api lane" || bad "watch --check: $out"
$T send-keys -t sala-test-b -l 'run /remote-control to reconnect'; $T send-keys -t sala-test-b Enter
waitfor "grep -q '^$U2 run /remote-control to reconnect' '$FAKE_TYPED_LOG'" 20 || bad "the fake did not take the typed line (b)"
SALA_MASTER=sala-test-b "$SALA" watch >/dev/null 2>&1   # ~20 s: the reconnect's wait for the bridge
grep -q "^$U2 /remote-control\$" "$FAKE_TYPED_LOG" && ok "master on subscription-1, the same screen: /remote-control typed (the heal still works where it belongs)" || bad "no /remote-control for b: $(<"$FAKE_TYPED_LOG") $(tail -5 "$WLOG")"

echo "== SALA_NO_RELAUNCH: refused by name, left out of --all"
out=$(SALA_NO_RELAUNCH=sala-test-b "$SALA" lane api sala-test-b 2>&1); rc=$?
[ "$rc" = 1 ] && [ -z "$(lane_row sala-test-b)" ] && [ "$(starts "$U2")" = 2 ] && ok "a session managed outside sala: refused, nothing recorded" || bad "lane api on a no-relaunch session ($rc): $out"
out=$(SALA_NO_RELAUNCH=sala-test-b "$SALA" lane subscription-2 --all 2>&1); rc=$?
[ "$rc" = 0 ] && ok "sala lane subscription-2 --all: started" || bad "lane subscription-2 --all ($rc): $out"
[ "$(lane_row sala-test-a)" = subscription-2 ] && [ -z "$(lane_row sala-test-b)" ] && [ "$(default_file)" = subscription-2 ] && ok "recorded: a → subscription-2, no row for b, the default subscription-2" || bad "rows: $(<"$SALA_LANES"); default $(default_file)"
waitfor '[ "$(starts "$U1")" = 4 ]' 60 && ok "the recycle relaunched sala-test-a" || bad "a not relaunched by --all: $(tail -20 "$RLOG")"
wait_lock; fake_up sala-test-a
[ "$(lanelog "$U1")" = "key=n hdr=n cfg=$HOME/.claude-team" ] && ok "on the team lane: CLAUDE_CONFIG_DIR, no key" || bad "a after --all: $(lanelog "$U1")"
[ "$(cachelog "$U1")" = "cache1h=- cache1h_bedrock=-" ] && ok "and no cache switch (subscription-2 is a subscription: the 1 hour comes with it)" || bad "cache switch on subscription-2: $(cachelog "$U1")"
[ "$(starts "$U2")" = 2 ] && ok "sala-test-b left alone" || bad "b relaunched by --all"

echo "== a new spawn lands on the default lane"
$T set-environment -g FAKE_SESSION_ID "$U3"; $T set-environment -g FAKE_NAME sala-test-c
out=$("$SALA" spawn sala-test-c --cwd "$HOME" 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(lanelog "$U3")" = "key=n hdr=n cfg=$HOME/.claude-team" ] && ok "spawn: claude started on team (the default)" || bad "spawn ($rc): $(lanelog "$U3") / $out"
grep -q 'lane    : subscription-2' <<< "$out" && ok "spawn's report names the lane" || bad "spawn report: $out"
grep -qE '^sala-test-c +\(default\) +subscription-2' <<< "$("$SALA" lane)" && ok "the table: (default), running subscription-2" || bad "table: $("$SALA" lane)"
"$SALA" lane default subscription-1 >/dev/null 2>&1   # the default back: c keeps running on subscription-2 until relaunched
grep -qE '^sala-test-c +\(default\) +subscription-2 +← runs on subscription-2' <<< "$("$SALA" lane)" && ok "the default changed under it: the table says a relaunch would move it" || bad "table: $("$SALA" lane)"

echo "== from a pane: the others swept first, the invoking pane last by the self-worker"
AP=$(tmux display -p -t sala-test-a '#{pane_id}')
out=$(TMUX_PANE="$AP" "$SALA" lane api sala-test-a sala-test-b 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'self-relaunch scheduled' <<< "$out" && ok "sala lane from sala-test-a's pane: the sweep for b, the self-worker for a" || bad "from a pane ($rc): $out"
waitfor '[ "$(starts "$U1")" = 5 ] && [ "$(starts "$U2")" = 3 ]' 80 && ok "both relaunched" || bad "starts: a=$(starts "$U1") b=$(starts "$U2") $(tail -20 "$RLOG")"
wait_lock; fake_up sala-test-a sala-test-b
[ "$(awk '/^start/ {print $2}' "$FAKE_LOG" | tail -2 | paste -sd' ' -)" = "$U2 $U1" ] && ok "b before a: the invoking pane went last" || bad "order: $(awk '/^start/ {print $2}' "$FAKE_LOG" | tail -2 | paste -sd' ' -)"
[ "$(lanelog "$U1")" = "key=y hdr=y cfg=-" ] && [ "$(lanelog "$U2")" = "key=y hdr=y cfg=-" ] && ok "both on api" || bad "a: $(lanelog "$U1") b: $(lanelog "$U2")"
[ "$(cachelog "$U1")" = "cache1h=1 cache1h_bedrock=-" ] && [ "$(cachelog "$U2")" = "cache1h=1 cache1h_bedrock=-" ] && ok "both started with ENABLE_PROMPT_CACHING_1H=1 (the sweep and the self-worker alike)" || bad "cache switch: a $(cachelog "$U1") b $(cachelog "$U2")"
[ "$(lane_row sala-test-a)" = api ] && [ "$(lane_row sala-test-b)" = api ] && ok "both recorded" || bad "rows: $(<"$SALA_LANES")"

echo "== retire drops the row"
lane_write sala-test-c api
"$SALA" retire sala-test-c --keep-web --busy >/dev/null 2>&1; [ -z "$(lane_row sala-test-c)" ] && ok "retired: its lane row is gone" || bad "row after retire: '$(lane_row sala-test-c)'"

[ "$fail" = 0 ] && echo "lanes: pass" || echo "lanes: FAIL"
exit $fail
