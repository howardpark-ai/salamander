#!/usr/bin/env bash
# The aws-platform lane (lib/common.sh "lanes" and lane_check, lib/lane.sh): Claude Platform on AWS,
# the Anthropic-operated API signed with the AWS profile example-bedrock, launchable like the bedrock lane beside it (
# tests/bedrocklane.sh). What is checked guards the workspace id, the profile and the launch line: lane_check aws-platform refusing in
# plain words for each missing thing (an EMPTY workspace id first, then one not shaped wrkspc_ plus letters, digits and underscores,
# no credentials file, no `[example-bedrock]` header line (a look at the header alone: a comment, a longer name, a [default]
# section do not count), an unreadable --mcp-config file, no claude launcher, a malformed region/model) and passing with a
# temporary HOME whose credentials file holds only the header and dummy values; an administrator profile named in config refused
# whatever the file holds, without the refusal naming it; the status DERIVED from lane_check (active / not set up, a config
# override winning) and the project field being the workspace id; the env on the launch line exactly as the brief states it
# (AWS_PROFILE, CLAUDE_CODE_USE_ANTHROPIC_AWS=1, ANTHROPIC_AWS_WORKSPACE_ID, AWS_REGION=us-east-1, the three pinned plain API
# model ids), settable by config, with `env -u` in front for CLAUDE_CODE_USE_BEDROCK, CLAUDE_CODE_USE_FOUNDRY and
# ANTHROPIC_AWS_API_KEY — those three never reach the claude even when the pane's shell holds them (a poisoned pane) — and
# `--mcp-config` as the api and bedrock lanes' (once, only with the file) and no key, header or value of the credentials file
# anywhere; the env on that pane's launch line ONLY (nothing exported into the shell, no settings file written, the other pane
# untouched); `sala lane aws-platform <session>` end to end through the direct sweep (recorded, relaunched, proc_lane aws-platform,
# the table, a recycle and a spawn keeping it, a switch back to subscription-1 clearing it); `--dry-run` naming the variables and no value;
# no Remote Control on the lane; the refusal once the workspace id or the profile is gone. The credentials file holds DUMMY
# values, counted and never printed. Posts stubbed to a file; isolated HOME, a private tmux socket, the compiled fake claude
# (tests/fake-claude.c, FAKE_AWSP_LOG). Usage: bash tests/aws-platform-lane.sh   (exit 0 = pass; ~60 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_SET SALA_SET_SELF SALA_POST_RECYCLE_CMD SALA_RECYCLE SALA_RETRY_WORKER SALA_NO_RELAUNCH SALA_MASTER
unset ANTHROPIC_API_KEY ANTHROPIC_CUSTOM_HEADERS CLAUDE_CONFIG_DIR SALA_LANE_API_KEY_FILE SALA_LANE_API_WORKSPACE_FILE SALA_LANE_API_MCP_CONFIG SALA_LANE_TEAM_DIR
unset AWS_PROFILE AWS_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_BEARER_TOKEN_BEDROCK CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_ANTHROPIC_AWS
unset ANTHROPIC_AWS_WORKSPACE_ID ANTHROPIC_AWS_API_KEY ANTHROPIC_AWS_BASE_URL ANTHROPIC_BEDROCK_REGION_PREFIX ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL
unset SALA_LANE_AWSPLATFORM_PROFILE SALA_LANE_AWSPLATFORM_CREDENTIALS_FILE SALA_LANE_AWSPLATFORM_WORKSPACE_ID SALA_LANE_AWSPLATFORM_REGION SALA_LANE_AWSPLATFORM_STATUS SALA_LANE_AWSPLATFORM_PROJECT
unset SALA_LANE_AWSPLATFORM_OPUS_MODEL SALA_LANE_AWSPLATFORM_SONNET_MODEL SALA_LANE_AWSPLATFORM_HAIKU_MODEL SALA_LANE_BEDROCK_PROFILE SALA_LANE_BEDROCK_CREDENTIALS_FILE SALA_LANE_BEDROCK_REGION SALA_LANE_BEDROCK_STATUS
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, tmux_socket_rm
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
as_op_unit   # no master: the guarded verbs this suite runs itself stand for the queue's runner (tests/lib.sh, 5)
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$HOME/.aws"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$HOME/.local/share/claude/versions/9.9.9" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
ln -s "$HOME/.local/share/claude/versions/9.9.9" "$HOME/.local/bin/claude"
printf '#!/bin/sh\necho "$*" >> "%s/systemd-run.txt"\n' "$HOME" > "$HOME/.local/bin/systemd-run"; chmod +x "$HOME/.local/bin/systemd-run"
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log" FAKE_LANE_LOG="$HOME/fake-lane.log" FAKE_TYPED_LOG="$HOME/typed.log" FAKE_AWSP_LOG="$HOME/fake-awsp.log" FAKE_CACHE_LOG="$HOME/fake-cache.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="{ cat; echo '%%'; } >> $POSTS"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off
SALA="$ROOT/bin/salamander"; SOCK="sala-awsp-$$"; T="tmux -L $SOCK -f /dev/null"; RLOG="$HOME/.claude/salamander-revive.log"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's (common.sh, on_fleet_server)
CRED="$HOME/.aws/credentials"; DUMMYID="AKIADUMMYNOTREAL$$"; DUMMYSECRET="dummy-secret-NOT-REAL-$$"
cleanup() {
    local f p; for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    for p in $(pgrep -x claude); do [ "$HOME/.local/share/claude/versions/9.9.9" -ef "/proc/$p/exe" ] && kill -9 "$p" 2>/dev/null; done
    chmod -R u+rwx "$HOME" 2>/dev/null; rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux
. "$ROOT/lib/common.sh"
wait_lock() { lock_wait "$HOME/.claude/salamander-recycle.lock" 80; }
mk() { local n="$1" u="$2"; shift 2; $T new-session -d -s "sala-test-$n" -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="sala-test-$n" -e FAKE_LOG="$FAKE_LOG" -e FAKE_LANE_LOG="$FAKE_LANE_LOG" -e FAKE_TYPED_LOG="$FAKE_TYPED_LOG" -e FAKE_AWSP_LOG="$FAKE_AWSP_LOG" -e FAKE_CACHE_LOG="$FAKE_CACHE_LOG" "$@"; $T send-keys -t "sala-test-$n" 'claude' Enter; }
cachelog() { grep "^$1 " "$FAKE_CACHE_LOG" 2>/dev/null | tail -1 | cut -d' ' -f2-; }   # <uuid> → "cache1h=<plain switch> cache1h_bedrock=<bedrock switch>" of its latest start ("-" unset)
awsplog() { grep "^$1 " "$FAKE_AWSP_LOG" 2>/dev/null | tail -1 | cut -d' ' -f2-; }   # <uuid> → "profile=… use=… ws=… …" of its latest start
U1=$(uuid 1); U2=$(uuid 2); U3=$(uuid 3); U4=$(uuid 4)
WS=wrkspc_01EXAMPLE; OPUS=claude-opus-5-5; SONNET=claude-sonnet-5-5; HAIKU=claude-haiku-5-5
WANT="profile=example-bedrock use=1 ws=$WS region=us-east-1 opus=$OPUS sonnet=$SONNET haiku=$HAIKU bedrock=- foundry=- apikey=n awskey=n"
NONE="profile=- use=- ws=- region=- opus=- sonnet=- haiku=- bedrock=- foundry=- apikey=n awskey=n"
leaks() { grep -qF -e "$DUMMYID" -e "$DUMMYSECRET"; }   # stdin → 0 when a dummy value is in it
printf '[example-bedrock]\naws_access_key_id = %s\naws_secret_access_key = %s\n' "$DUMMYID" "$DUMMYSECRET" > "$CRED"   # the profile is there; the workspace id is not (yet)

echo "== lane_check aws-platform: the workspace id first, in a plain sentence"
why=$(lane_check aws-platform); rc=$?
[ "$rc" = 1 ] && grep -q 'aws-platform lane: no workspace id yet' <<< "$why" && grep -q 'SALA_LANE_AWSPLATFORM_WORKSPACE_ID' <<< "$why" && grep -q 'wrkspc_' <<< "$why" && ok "an empty workspace id: refused, the knob and the shape named, though the profile is there" || bad "empty workspace id ($rc): $why"
for w in abc wrkspc_ wrkspc_EXAMPLE-b WRKSPC_01 'wrkspc_01EXAMPLE 02' 'wrkspc_01EXAMPLE;x' 'wrkspc_$(id)' wrkspc_01EXAMPLE.2 xwrkspc_01EXAMPLE ' wrkspc_01EXAMPLE'; do
    why=$(SALA_LANE_AWSPLATFORM_WORKSPACE_ID="$w" lane_check aws-platform); rc=$?
    { [ "$rc" = 1 ] && grep -q 'is not a workspace id' <<< "$why"; } || bad "workspace id '$w' ($rc): $why"
done; ok "a value not shaped wrkspc_ plus word characters (ten shapes tried): refused in a plain sentence"
why=$(SALA_LANE_AWSPLATFORM_WORKSPACE_ID='wrkspc_01EXAMPLE;touch-x' lane_check aws-platform); ! grep -qF 'touch-x' <<< "$why" && ok "and the refusal does not repeat the value" || bad "the refusal repeats the value: $why"
SALA_LANE_AWSPLATFORM_WORKSPACE_ID=wrkspc_01EXAMPLE_def lane_check aws-platform >/dev/null && ok "wrkspc_ followed by letters, digits and an underscore: accepted" || bad "a good shape refused: $(SALA_LANE_AWSPLATFORM_WORKSPACE_ID=wrkspc_01EXAMPLE_def lane_check aws-platform)"
[ "$(lane_field aws-platform status)" = "not set up" ] && [ -z "$(lane_field aws-platform project)" ] && ok "with no workspace id: the status is not set up and the project field is empty" || bad "status/project: $(lane_field aws-platform status) / $(lane_field aws-platform project)"
out=$("$SALA" lane 2>&1); grep -q 'aws-platform not ready' <<< "$out" && grep -q 'aws-platform: aws-platform lane: no workspace id yet' <<< "$out" && ok "the no-argument table: aws-platform not ready, the reason under it" || bad "table: $out"
out=$("$SALA" lane aws-platform sala-test-x --dry-run 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'no workspace id yet' <<< "$out" && ok "sala lane aws-platform <session>: refused with the same words before anything is recorded" || bad "refusal ($rc): $out"
export SALA_LANE_AWSPLATFORM_WORKSPACE_ID=$WS   # from here on the workspace exists (sala's children read it from the environment, as they would from the config)

echo "== lane_check aws-platform: each other missing thing is named"
rm -f "$CRED"
why=$(lane_check aws-platform); rc=$?
[ "$rc" = 1 ] && grep -q 'aws-platform lane: no \[example-bedrock\] profile in' <<< "$why" && grep -q 'key-entry script' <<< "$why" && ok "no credentials file: refused, the profile and the key-entry script named" || bad "no file ($rc): $why"
printf '[default]\naws_access_key_id = %s\naws_secret_access_key = %s\n' "$DUMMYID" "$DUMMYSECRET" > "$CRED"
why=$(lane_check aws-platform); rc=$?
[ "$rc" = 1 ] && grep -q 'no \[example-bedrock\] profile' <<< "$why" && ok "a file with only [default]: refused" || bad "only [default] ($rc): $why"
printf '# [example-bedrock]\n[example-bedrock-old]\n  [example-bedrock]x\nexample-bedrock\n' >> "$CRED"
lane_check aws-platform >/dev/null 2>&1 && bad "a comment, a longer name and a bare word passed as the header" || ok "a commented header, a longer profile name and the bare word do not count"
printf '[example-bedrock]\naws_access_key_id = %s\naws_secret_access_key = %s\n' "$DUMMYID" "$DUMMYSECRET" >> "$CRED"
lane_check aws-platform >/dev/null && ok "the header line among other sections (dummy values below it): ready" || bad "lane_check aws-platform: $(lane_check aws-platform)"
printf '[default]\n[example-bedrock]   \r\naws_access_key_id = x\n' > "$CRED"; lane_check aws-platform >/dev/null && ok "trailing blanks and a CR after the header: still the header" || bad "trailing blanks: $(lane_check aws-platform)"
printf '[example-bedrock]\naws_access_key_id = %s\naws_secret_access_key = %s\n' "$DUMMYID" "$DUMMYSECRET" > "$CRED"   # only the header and dummy values
out="$(lane_check aws-platform; SALA_LANE_AWSPLATFORM_PROFILE=other lane_check aws-platform; "$SALA" lane 2>&1; "$SALA" lane --list 2>&1; "$SALA" lane --json 2>&1)"
leaks <<< "$out" && bad "a dummy credential value appeared in lane_check, the table, --list or --json" || ok "no credential value in lane_check's output or the table (the file is only tested for the header)"
SALA_LANE_AWSPLATFORM_PROFILE=other lane_check aws-platform | grep -q 'no \[other\] profile' && ok "SALA_LANE_AWSPLATFORM_PROFILE names another profile: that header is what is looked for" || bad "profile override: $(SALA_LANE_AWSPLATFORM_PROFILE=other lane_check aws-platform)"
why=$(SALA_LANE_AWSPLATFORM_PROFILE='bad name' lane_check aws-platform); [ $? = 1 ] && grep -q 'profile name' <<< "$why" && ok "a profile name a typed line cannot carry: refused" || bad "bad profile name: $why"
SALA_LANE_AWSPLATFORM_CREDENTIALS_FILE="$CRED.elsewhere" lane_check aws-platform >/dev/null && bad "another credentials file passed with no file there" || ok "SALA_LANE_AWSPLATFORM_CREDENTIALS_FILE points elsewhere: that file is what is looked at"
mkdir -p "$HOME/.config/claude-lanes"; echo '{"mcpServers":{}}' > "$HOME/.config/claude-lanes/api-mcp.json"; chmod 000 "$HOME/.config/claude-lanes/api-mcp.json"
why=$(lane_check aws-platform); rc=$?
[ "$rc" = 1 ] && grep -q 'aws-platform lane: the --mcp-config file' <<< "$why" && grep -q 'SALA_LANE_API_MCP_CONFIG' <<< "$why" && ok "an --mcp-config file that exists but is unreadable: refused, as the api lane refuses it" || bad "unreadable mcp ($rc): $why"
chmod 600 "$HOME/.config/claude-lanes/api-mcp.json"; lane_check aws-platform >/dev/null && ok "readable again: ready" || bad "mcp readable: $(lane_check aws-platform)"
rm -f "$HOME/.config/claude-lanes/api-mcp.json"; lane_check aws-platform >/dev/null && ok "no --mcp-config file at all: ready (optional, as on the api lane)" || bad "no mcp: $(lane_check aws-platform)"
why=$(SALA_CLAUDE="$HOME/nowhere/claude" lane_check aws-platform); [ $? = 1 ] && grep -q 'no claude launcher' <<< "$why" && ok "no claude launcher: refused, named" || bad "no launcher: $why"
why=$(SALA_LANE_AWSPLATFORM_SONNET_MODEL='a b' lane_check aws-platform); [ $? = 1 ] && grep -q 'model id' <<< "$why" && ok "a model id a typed line cannot carry: refused" || bad "model: $why"
why=$(SALA_LANE_AWSPLATFORM_HAIKU_MODEL='' lane_check aws-platform); [ $? = 1 ] && grep -q 'model id' <<< "$why" && ok "an empty model id: refused" || bad "empty model: $why"
why=$(SALA_LANE_AWSPLATFORM_REGION='ap northeast' lane_check aws-platform); [ $? = 1 ] && ok "a region with a space: refused" || bad "region: $why"

echo "== the administrator profile is never the lane's: refused whatever the credentials file holds"
printf '[example-admin]\naws_access_key_id = %s\n[example-bedrock]\naws_access_key_id = %s\n' "$DUMMYID" "$DUMMYID" > "$CRED"
why=$(SALA_LANE_AWSPLATFORM_PROFILE=example-admin lane_check aws-platform); rc=$?
[ "$rc" = 1 ] && grep -q 'not an administrator profile' <<< "$why" && ok "a config naming the administrator profile: refused, though its section is in the file" || bad "admin profile ($rc): $why"
! grep -q 'example-admin' <<< "$why" && ok "and the refusal does not repeat the profile's name" || bad "the refusal names the admin profile: $why"
SALA_LANE_AWSPLATFORM_PROFILE=Prod-ADMIN lane_check aws-platform >/dev/null && bad "an uppercase admin profile passed" || ok "any profile whose name says admin, in any case: refused"
[ "$(SALA_LANE_AWSPLATFORM_PROFILE=example-admin lane_field aws-platform status)" = "not set up" ] && ok "and its status stays not set up" || bad "admin status"
printf '[example-bedrock]\naws_access_key_id = %s\naws_secret_access_key = %s\n' "$DUMMYID" "$DUMMYSECRET" > "$CRED"

echo "== the status is derived from lane_check; the region is the launch's; the project is the workspace"
[ "$(lane_field aws-platform status)" = active ] && ok "workspace id and profile present: aws-platform's status is active" || bad "status: $(lane_field aws-platform status)"
[ "$(SALA_LANE_AWSPLATFORM_STATUS=inactive lane_field aws-platform status)" = inactive ] && ok "a config SALA_LANE_AWSPLATFORM_STATUS still wins" || bad "status override"
[ "$(lane_field aws-platform region)" = us-east-1 ] && [ "$(SALA_LANE_AWSPLATFORM_REGION=us-west-2 lane_field aws-platform region)" = us-west-2 ] && ok "region from SALA_LANE_AWSPLATFORM_REGION (the fixture us-east-1), another value overriding it" || bad "region"
why=$(SALA_LANE_AWSPLATFORM_REGION= lane_check aws-platform); [ $? = 1 ] && grep -q 'AWS region is not set' <<< "$why" && grep -q SALA_LANE_AWSPLATFORM_REGION <<< "$why" && [ "$(SALA_LANE_AWSPLATFORM_REGION= lane_field aws-platform status)" = "not set up" ] && ok "no region set: refused in a plain sentence naming the setting, status not set up" || bad "unset region: $why"
[ "$(lane_field aws-platform project)" = "$WS" ] && ok "the project field is the workspace id (not a secret)" || bad "project: $(lane_field aws-platform project)"
[ "$(lane_field aws-platform credential)" = "AWS profile" ] && ! lane_field aws-platform credential | grep -qF -e "$CRED" -e example-bedrock && ok "the credential field says 'AWS profile': no path, no profile name" || bad "credential field: $(lane_field aws-platform credential)"
[ "$(lane_field aws-platform label)" = "Claude Platform on AWS" ] && [ "$(lane_field aws-platform provider)" = anthropic ] && [ "$(lane_field aws-platform billing)" = usage ] && [ "$(lane_field aws-platform payment)" = postpaid ] && [ "$(lane_field aws-platform client)" = claude-code ] && ok "label, provider anthropic, usage billing, postpaid, client claude-code" || bad "fields"
lane_fields_problems aws-platform | grep -q . && bad "the lane's fields break the spec: $(lane_fields_problems aws-platform)" || ok "lane_fields_problems: none"
out=$("$SALA" lane --list 2>&1); grep -E '^aws-platform ' <<< "$out" | grep -q ' active$' && ok "lane --list: aws-platform active" || bad "--list: $out"
python3 -c 'import json,sys; d=json.load(sys.stdin); b=[l for l in d["lanes"] if l["id"]=="aws-platform"][0]; assert b["status"]=="active" and b["region"]=="us-east-1" and b["credential"]=="AWS profile" and b["project"]=="'"$WS"'" and b["provider"]=="anthropic", b' <<< "$("$SALA" lane --json 2>&1)" && ok "lane --json: status active, region us-east-1, credential 'AWS profile', project the workspace id" || bad "--json: $("$SALA" lane --json 2>&1)"
grep -q 'aws-platform ready' <<< "$("$SALA" lane 2>&1)" && ok "the no-argument table: aws-platform ready" || bad "table: $("$SALA" lane 2>&1)"
mv "$CRED" "$CRED.away"; [ "$(lane_field aws-platform status)" = "not set up" ] && ok "the credentials file gone: back to not set up" || bad "status after removal"; mv "$CRED.away" "$CRED"
[ "$(SALA_LANE_AWSPLATFORM_WORKSPACE_ID= lane_field aws-platform status)" = "not set up" ] && ok "the workspace id gone: back to not set up" || bad "status without workspace"
[ "$(lane_field bedrock status)" = active ] && lane_check bedrock >/dev/null && ok "and the bedrock lane beside it is untouched (still ready on the same profile)" || bad "bedrock: $(lane_check bedrock)"

echo "== the launch line: names and ids, nothing secret; Bedrock, Foundry and a workspace key unset; config settles each one"
[ "$(lane_env_names aws-platform)" = "AWS_PROFILE CLAUDE_CODE_USE_ANTHROPIC_AWS ANTHROPIC_AWS_WORKSPACE_ID AWS_REGION ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ENABLE_PROMPT_CACHING_1H" ] && ok "lane_env_names aws-platform: the eight names a dry run shows (the seven and the pane's 1-hour cache switch)" || bad "names: $(lane_env_names aws-platform)"
! lane_env_names aws-platform | grep -qw CLAUDE_CODE_USE_BEDROCK && ok "and CLAUDE_CODE_USE_BEDROCK is not among them" || bad "bedrock flag among the names"
[ "$(lane_unset_names aws-platform)" = "CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_FOUNDRY ANTHROPIC_AWS_API_KEY" ] && [ -z "$(lane_unset_names bedrock)$(lane_unset_names api)$(lane_unset_names subscription-1)" ] && ok "lane_unset_names: the three on this lane, none on the others" || bad "unset names: $(lane_unset_names aws-platform)"
p=$(lane_env_prefix aws-platform)
[ "$p" = "env -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_FOUNDRY -u ANTHROPIC_AWS_API_KEY AWS_PROFILE=example-bedrock CLAUDE_CODE_USE_ANTHROPIC_AWS=1 ANTHROPIC_AWS_WORKSPACE_ID=$WS AWS_REGION=us-east-1 ANTHROPIC_DEFAULT_OPUS_MODEL=$OPUS ANTHROPIC_DEFAULT_SONNET_MODEL=$SONNET ANTHROPIC_DEFAULT_HAIKU_MODEL=$HAIKU ENABLE_PROMPT_CACHING_1H=1 " ] && ok "the prefix: env -u the three, then profile, use flag, workspace, region, the three pinned plain ids, the 1-hour cache switch" || bad "prefix: '$p'"
! grep -q 'CLAUDE_CODE_USE_BEDROCK=' <<< "$p" && ! grep -q 'CLAUDE_CODE_USE_FOUNDRY=' <<< "$p" && ! grep -q 'global\.' <<< "$p" && ! leaks <<< "$p" && ! grep -q 'cat ' <<< "$p" && ok "the line never sets the Bedrock or Foundry flag, carries no Bedrock-style id, no credential value and no \$(cat …)" || bad "the prefix sets a flag it must not: $p"
p2=$(SALA_LANE_AWSPLATFORM_PROFILE=p2 SALA_LANE_AWSPLATFORM_REGION=us-east-2 SALA_LANE_AWSPLATFORM_WORKSPACE_ID=wrkspc_EXAMPLE9 SALA_LANE_AWSPLATFORM_OPUS_MODEL=o1 SALA_LANE_AWSPLATFORM_SONNET_MODEL=s1 SALA_LANE_AWSPLATFORM_HAIKU_MODEL=h1:0 lane_env_prefix aws-platform)
[ "$p2" = "env -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_FOUNDRY -u ANTHROPIC_AWS_API_KEY AWS_PROFILE=p2 CLAUDE_CODE_USE_ANTHROPIC_AWS=1 ANTHROPIC_AWS_WORKSPACE_ID=wrkspc_EXAMPLE9 AWS_REGION=us-east-2 ANTHROPIC_DEFAULT_OPUS_MODEL=o1 ANTHROPIC_DEFAULT_SONNET_MODEL=s1 ANTHROPIC_DEFAULT_HAIKU_MODEL=h1:0 ENABLE_PROMPT_CACHING_1H=1 " ] && ok "profile, region, workspace and the three models are each settable in sala config" || bad "overrides: '$p2'"
# run by a shell that holds the three poisoned variables: the process the line starts gets the seven and none of the three
n=$( ( export CLAUDE_CODE_USE_BEDROCK=1 CLAUDE_CODE_USE_FOUNDRY=1 ANTHROPIC_AWS_API_KEY="$DUMMYSECRET"; eval "${p}env" ) | grep -cE "^(AWS_PROFILE=example-bedrock|CLAUDE_CODE_USE_ANTHROPIC_AWS=1|ANTHROPIC_AWS_WORKSPACE_ID=$WS|AWS_REGION=us-east-1|ANTHROPIC_DEFAULT_OPUS_MODEL=$OPUS|ANTHROPIC_DEFAULT_SONNET_MODEL=$SONNET|ANTHROPIC_DEFAULT_HAIKU_MODEL=$HAIKU)\$")
[ "$n" = 7 ] && ok "run by a shell, the line hands that process all seven (counted)" || bad "evaluated prefix: $n of 7"
[ "$(eval "${p}env" | grep -c '^ENABLE_PROMPT_CACHING_1H=1$')" = 1 ] && ! grep -q 'ENABLE_PROMPT_CACHING_1H_BEDROCK' <<< "$p" && ok "and ENABLE_PROMPT_CACHING_1H=1 once: the plain switch, not bedrock's (the CLI reads that one only for the bedrock provider; this lane's is anthropicAws)" || bad "evaluated prefix: cache switch"
pj=$(lane_env_prefix aws-platform job)
[ "$pj" = "${p%ENABLE_PROMPT_CACHING_1H=1 }" ] && ! grep -q ENABLE_PROMPT_CACHING <<< "$pj" && ok "lane_env_prefix aws-platform job: the same env -u and seven pairs and no cache switch (a one-shot job never reuses a 1-hour write)" || bad "job prefix: '$pj'"
n=$( ( export CLAUDE_CODE_USE_BEDROCK=1 CLAUDE_CODE_USE_FOUNDRY=1 ANTHROPIC_AWS_API_KEY="$DUMMYSECRET"; eval "${p}env" ) | grep -cE "^(CLAUDE_CODE_USE_BEDROCK|CLAUDE_CODE_USE_FOUNDRY|ANTHROPIC_AWS_API_KEY)=")
[ "$n" = 0 ] && ok "and a shell that held CLAUDE_CODE_USE_BEDROCK, CLAUDE_CODE_USE_FOUNDRY and ANTHROPIC_AWS_API_KEY passes none of them on (env -u)" || bad "$n of the three poisoned variables reached the process"
[ -z "${AWS_PROFILE:-}${CLAUDE_CODE_USE_ANTHROPIC_AWS:-}${ANTHROPIC_AWS_WORKSPACE_ID:-}${AWS_REGION:-}" ] && ! env | grep -qE '^(AWS_PROFILE|CLAUDE_CODE_USE_ANTHROPIC_AWS|CLAUDE_CODE_USE_BEDROCK|ANTHROPIC_AWS_WORKSPACE_ID|AWS_REGION|ANTHROPIC_DEFAULT_OPUS_MODEL)=' && ok "this shell exports none of them: the env is on the line only" || bad "the env leaked into the shell"
[ -z "$(lane_args subscription-1)$(lane_args subscription-2)" ] && ok "subscription-1 and subscription-2 add no argument" || bad "args: $(lane_args subscription-1)$(lane_args subscription-2)"
[ -z "$(lane_args aws-platform)" ] && ok "aws-platform: no --mcp-config without the file" || bad "mcp without file: $(lane_args aws-platform)"
echo '{"mcpServers":{}}' > "$HOME/.config/claude-lanes/api-mcp.json"
[ "$(lane_args aws-platform)" = " --mcp-config $HOME/.config/claude-lanes/api-mcp.json" ] && [ "$(lane_args aws-platform)" = "$(lane_args api)" ] && [ "$(lane_args aws-platform)" = "$(lane_args bedrock)" ] && ok "with the file: --mcp-config <SALA_LANE_API_MCP_CONFIG>, the api and bedrock lanes' own" || bad "mcp: $(lane_args aws-platform)"
lane_rc aws-platform && bad "aws-platform claims a Remote Control bridge" || ok "lane_rc aws-platform: no Remote Control (no claude.ai login behind it)"
lane_write sala-test-x aws-platform; r=$(resume_cmd "$U3" sala-test-x)
[ "$r" = "$p$(mod_env_prefix)claude --resume $U3 --mcp-config $HOME/.config/claude-lanes/api-mcp.json" ] && ok "resume_cmd for a session on aws-platform: env -u …, the env, claude --resume, then --mcp-config" || bad "resume_cmd: $r"
[ "$(grep -o -- '--mcp-config' <<< "$r" | wc -l)" = 1 ] && ! leaks <<< "$r" && ok "--mcp-config once; no credential value on the resume line" || bad "resume line: $r"
lane_drop sala-test-x
lane_out aws-platform >/dev/null; [ $? = 1 ] && ok "lane_out aws-platform: nothing wrong (the rescue may move a pane to it)" || bad "lane_out aws-platform: $(lane_out aws-platform)"
SALA_LANE_AWSPLATFORM_WORKSPACE_ID= lane_out aws-platform | head -1 | grep -q 'aws-platform lane: no workspace id yet' && ok "lane_out aws-platform without a workspace id: out, by lane_check" || bad "lane_out without workspace: $(SALA_LANE_AWSPLATFORM_WORKSPACE_ID= lane_out aws-platform)"

echo "== a scheduled job on the lane: no cache switch (lane env, lane exec, job_env_args)"
out=$("$SALA" lane env aws-platform 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(grep -c '^[A-Z_]*=' <<< "$out")" = 7 ] && grep -q '^CLAUDE_CODE_USE_ANTHROPIC_AWS=1$' <<< "$out" && ! grep -q ENABLE_PROMPT_CACHING <<< "$out" && ok "lane env aws-platform: the seven NAME=value lines of the launch line and no ENABLE_PROMPT_CACHING_1H (pane-only)" || bad "lane env aws-platform ($rc): $out"
out=$("$SALA" lane exec aws-platform -- env 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q '^CLAUDE_CODE_USE_ANTHROPIC_AWS=1$' <<< "$out" && ! grep -q '^ENABLE_PROMPT_CACHING' <<< "$out" && ok "lane exec aws-platform -- env: the lane's variables and no cache switch" || bad "lane exec aws-platform ($rc)"
job_env_args aws-platform; [ $? = 0 ] && printf '%s\n' "${JOB_ENV[@]}" | grep -q '^CLAUDE_CODE_USE_ANTHROPIC_AWS=1$' && ! printf '%s\n' "${JOB_ENV[@]}" | grep -q '^ENABLE_PROMPT_CACHING[A-Z_0-9]*=' && ok "job_env_args aws-platform: the lane's pairs and no cache switch pair (it is only unset)" || bad "job_env_args aws-platform: ${JOB_ENV[*]}"

echo "== lane exec starts every lane clean of the other lanes' variables, subscription-1 included: unset, never blanked"
# a pane on the aws-platform lane passes its names down; some arrive present-but-empty, which Claude Code reads as set
# (`lane exec subscription-1 -- claude --cloud …` was refused for CLAUDE_CODE_USE_ANTHROPIC_AWS= alone)
awsp_env() { env CLAUDE_CODE_USE_ANTHROPIC_AWS= ANTHROPIC_AWS_WORKSPACE_ID=wrkspc_EXAMPLE_stale AWS_PROFILE= AWS_REGION=us-stale ANTHROPIC_DEFAULT_OPUS_MODEL= ANTHROPIC_DEFAULT_SONNET_MODEL=stale-s ANTHROPIC_DEFAULT_HAIKU_MODEL= \
    ENABLE_PROMPT_CACHING_1H=1 ANTHROPIC_AWS_API_KEY= CLAUDE_CODE_USE_BEDROCK= ANTHROPIC_BEDROCK_REGION_PREFIX=stale ENABLE_PROMPT_CACHING_1H_BEDROCK=1 "$@"; }
alljob=$(lane_job_unset); alljob_re=$(tr ' ' '|' <<< "$alljob")
out=$(awsp_env "$SALA" lane exec subscription-1 -- env 2>&1); rc=$?
[ "$rc" = 0 ] && grep -qE '^HOME=' <<< "$out" && [ "$(grep -cE "^($alljob_re)(=|$)" <<< "$out")" = 0 ] && ok "lane exec subscription-1 -- env: none of the other lanes' names, not even an empty one (present-but-empty counts)" || bad "lane exec subscription-1 kept a name ($rc): $(grep -oE "^($alljob_re)=" <<< "$out" | tr '\n' ' ')"
out=$(awsp_env "$SALA" lane exec subscription-1 -- sh -c 'echo ran-on-subscription-1; exit 5' 2>&1); rc=$?
[ "$rc" = 5 ] && [ "$out" = ran-on-subscription-1 ] && ok "lane exec subscription-1 still runs the command and passes its exit status through" || bad "lane exec subscription-1 -- sh ($rc): $out"
out=$(awsp_env "$SALA" lane exec aws-platform -- env 2>&1); rc=$?
[ "$rc" = 0 ] && grep -qxF 'CLAUDE_CODE_USE_ANTHROPIC_AWS=1' <<< "$out" && grep -qxF "ANTHROPIC_AWS_WORKSPACE_ID=$WS" <<< "$out" && grep -qxF 'AWS_PROFILE=example-bedrock' <<< "$out" && grep -qxF "ANTHROPIC_DEFAULT_OPUS_MODEL=$OPUS" <<< "$out" \
    && ! grep -qE '^(ANTHROPIC_AWS_API_KEY|CLAUDE_CODE_USE_BEDROCK|ANTHROPIC_BEDROCK_REGION_PREFIX|ENABLE_PROMPT_CACHING_1H|ENABLE_PROMPT_CACHING_1H_BEDROCK)(=|$)' <<< "$out" && [ "$(grep -cE "^($alljob_re)=" <<< "$out")" = 7 ] \
    && ok "lane exec aws-platform -- env: its own seven names with its own values and no other lane's (bedrock's, the cache switches, a workspace API key)" || bad "lane exec aws-platform ($rc): $(grep -oE "^($alljob_re)=" <<< "$out" | tr '\n' ' ')"
out=$(awsp_env "$SALA" lane exec bedrock -- env 2>&1); rc=$?
[ "$rc" = 0 ] && grep -qxF 'CLAUDE_CODE_USE_BEDROCK=1' <<< "$out" && grep -qxF 'ANTHROPIC_BEDROCK_REGION_PREFIX=global' <<< "$out" && [ "$(grep -cE "^($alljob_re)=" <<< "$out")" = 7 ] \
    && ! grep -qE '^(CLAUDE_CODE_USE_ANTHROPIC_AWS|ANTHROPIC_AWS_WORKSPACE_ID|ANTHROPIC_AWS_API_KEY|ENABLE_PROMPT_CACHING_1H|ENABLE_PROMPT_CACHING_1H_BEDROCK)(=|$)' <<< "$out" && ok "lane exec bedrock from the aws-platform names: bedrock's seven, and none of aws-platform's" || bad "lane exec bedrock ($rc): $(grep -oE "^($alljob_re)=" <<< "$out" | tr '\n' ' ')"
job_env_args subscription-1; [ $? = 0 ] && [ "${#JOB_ENV[@]}" -gt 0 ] && ! printf '%s\n' "${JOB_ENV[@]}" | grep -q '=' && [ "$(( ${#JOB_ENV[@]} / 2 ))" = "$(wc -w <<< "$alljob")" ] && ok "job_env_args subscription-1 (sala's own jobs, SALA_JOB_LANE=subscription-1): -u for every name in lane_job_unset and no pair" || bad "job_env_args subscription-1: ${JOB_ENV[*]}"
# the list is derived, and this is what holds it to it: every name a lane's launch line sets or unsets is in lane_job_unset
miss=""; for l in $SALA_LANES_KNOWN; do
    for w in $(lane_env_prefix "$l" | grep -oE '(^| )[A-Z][A-Z0-9_]*=' | tr -d ' =') $(lane_env_names "$l") $(lane_unset_names "$l"); do
        case " $alljob " in *" $w "*) ;; *) miss="$miss $l:$w" ;; esac
    done
done
[ -z "$miss" ] && ok "lane_job_unset covers every name any lane's launch line sets or unsets ($(wc -w <<< "$alljob") names, derived from the lanes)" || bad "a lane sets a name lane_job_unset lacks:$miss"
[ "$("$SALA" lane env subscription-1 2>&1 </dev/null | wc -c)" = 0 ] && ok "lane env subscription-1: nothing on stdout and nothing on stderr when neither is a terminal" || bad "lane env subscription-1 piped printed something"
if command -v script >/dev/null 2>&1; then
    out=$(script -qec "$SALA lane env subscription-1" /dev/null </dev/null 2>&1 | tr -d '\r'); rc=$?
    grep -qF "lane env subscription-1: this lane sets no variables (lane exec subscription-1 unsets the other lanes' ones)" <<< "$out" && ok "lane env subscription-1 on a terminal: the one line saying subscription-1 sets nothing and lane exec unsets the others'" || bad "lane env subscription-1 on a terminal ($rc): $out"
fi

echo "== proc_lane: the AWS flags, the two lanes told apart (a process that is not a pane is read straight from /proc)"
for spec in "CLAUDE_CODE_USE_BEDROCK=1:bedrock" "CLAUDE_CODE_USE_ANTHROPIC_AWS=1:aws-platform" "CLAUDE_CODE_USE_BEDROCK=1 CLAUDE_CODE_USE_ANTHROPIC_AWS=1:bedrock" "CLAUDE_CODE_USE_ANTHROPIC_AWS=1 ANTHROPIC_API_KEY=x:aws-platform" "CLAUDE_CODE_USE_ANTHROPIC_AWS=0:subscription-1" "CLAUDE_CODE_USE_ANTHROPIC_AWS=10:subscription-1" "CLAUDE_CODE_USE_ANTHROPIC_AWS=1 CLAUDE_CODE_ENTRYPOINT=sdk-py:sdk" "X=1:subscription-1"; do
    vars=${spec%:*}; want=${spec##*:}
    env -i PATH="$PATH" $vars sleep 30 & sp=$!
    waitfor "tr '\\0' '\\n' < /proc/$sp/environ 2>/dev/null | grep -q '^${vars%%=*}='" 20   # until the process has exec'd sleep with the env (a fixed 0.3 s lost the race on a busy box)
    got=$(proc_lane "$sp"); kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
    [ "$got" = "$want" ] && ok "proc_lane [$vars] = $want" || bad "proc_lane [$vars] = $got, wanted $want"
done

echo "== --dry-run: the variables' names, no value, nothing recorded"
mk a "$U1"; mk b "$U2"; fake_up sala-test-a sala-test-b
out=$("$SALA" lane aws-platform sala-test-a --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'AWS_PROFILE CLAUDE_CODE_USE_ANTHROPIC_AWS ANTHROPIC_AWS_WORKSPACE_ID AWS_REGION ANTHROPIC_DEFAULT_OPUS_MODEL' <<< "$out" && grep -q 'ENABLE_PROMPT_CACHING_1H' <<< "$out" && ok "dry run: the env names, the 1-hour cache switch among them" || bad "dry run ($rc): $out"
grep -q 'after unsetting CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_FOUNDRY ANTHROPIC_AWS_API_KEY' <<< "$out" && ok "and the variables the line unsets first" || bad "no unset words: $out"
! leaks <<< "$out" && ! grep -q 'AWS_PROFILE=' <<< "$out" && ! grep -qF "$OPUS" <<< "$out" && ! grep -qF "$WS" <<< "$out" && ok "no credential value, no workspace id and no VAR=value pair in the dry run" || bad "dry run shows a value: $out"
grep -q 'no Remote Control' <<< "$out" && ok "and it says there is no Remote Control on this lane" || bad "no RC line: $out"
[ -z "$(lane_row sala-test-a)" ] && [ "$(starts "$U1")" = 1 ] && ok "nothing recorded, nothing relaunched" || bad "after dry run: row '$(lane_row sala-test-a)' starts $(starts "$U1")"

echo "== sala lane aws-platform <session>: recorded, relaunched through the direct sweep"
[ "$(awsplog "$U1")" = "$NONE" ] && ok "before: the pane's claude has none of the lane's variables" || bad "before: $(awsplog "$U1")"
out=$("$SALA" lane aws-platform sala-test-a 2>&1); rc=$?
[ "$rc" = 0 ] && ok "exit 0" || bad "sala lane aws-platform sala-test-a ($rc): $out"
waitfor '[ "$(starts "$U1")" = 2 ]' 40 && ok "sala-test-a relaunched" || bad "no relaunch: $(<"$FAKE_LOG") $(tail -5 "$RLOG")"
fake_up sala-test-a
[ "$(awsplog "$U1")" = "$WANT" ] && ok "its claude started with exactly the lane's environment (profile, use flag, workspace, region, the three models), no Bedrock or Foundry flag, no key" || bad "aws-platform env: $(awsplog "$U1")"
[ "$(cachelog "$U1")" = "cache1h=1 cache1h_bedrock=-" ] && ok "and with ENABLE_PROMPT_CACHING_1H=1 (the 1-hour prompt cache), not bedrock's variant" || bad "cache switch after the lane move: $(cachelog "$U1")"
[ "$(lane_row sala-test-a)" = aws-platform ] && ok "recorded: sala-test-a → aws-platform" || bad "row: '$(lane_row sala-test-a)'"
[ "$(proc_lane "$(cpid a)")" = aws-platform ] && ok "proc_lane reads aws-platform from the process's environment" || bad "proc_lane: $(proc_lane "$(cpid a)")"
grep -qE '^sala-test-a +aws-platform +aws-platform' <<< "$("$SALA" lane)" && ok "the table: recorded aws-platform, running aws-platform" || bad "table: $("$SALA" lane)"
[ "$(cachelog "$U2")" = "cache1h=- cache1h_bedrock=-" ] && [ "$(awsplog "$U2")" = "$NONE" ] && [ "$(starts "$U2")" = 1 ] && [ -z "$(lane_row sala-test-b)" ] && ok "sala-test-b untouched: no variable, no row" || bad "b: $(awsplog "$U2") starts $(starts "$U2")"
pp=$(tmux display -p -t sala-test-a '#{pane_pid}')
! tr '\0' '\n' < "/proc/$pp/environ" 2>/dev/null | grep -qE '^(AWS_|CLAUDE_CODE_USE_|ANTHROPIC_AWS_|ANTHROPIC_DEFAULT_)' && ok "the pane's shell never held the variables: the env is on the launch line only" || bad "the pane's shell environment carries the lane's variables"
[ ! -e "$HOME/.claude/settings.json" ] && [ ! -e "$HOME/.claude/settings.local.json" ] && ok "no settings file written (nothing in settings)" || bad "a settings file appeared"
! leaks <<< "$out" && ! $T capture-pane -p -S - -t sala-test-a | leaks && ! cat "$RLOG" "$SALA_LANE_LOG" 2>/dev/null | leaks && ! tr '\0' ' ' < "/proc/$(cpid a)/cmdline" | leaks \
    && ok "no credential value in the command's output, the pane's scrollback, the logs or the process's argv" || bad "a credential value leaked"
grep -q 'AWS_PROFILE' <<< "$out" && ok "the output names the variables" || bad "output: $out"

echo "== a recycle keeps the lane; a spawn on it; a switch back to subscription-1 clears it"
"$SALA" recycle --force >/dev/null 2>&1 || bad "recycle --force did not start"
waitfor '[ "$(starts "$U1")" = 3 ] && [ "$(starts "$U2")" = 2 ]' 60 && ok "both relaunched by the recycle" || bad "starts after recycle: a=$(starts "$U1") b=$(starts "$U2") $(tail -20 "$RLOG")"
wait_lock; fake_up sala-test-a sala-test-b
[ "$(awsplog "$U1")" = "$WANT" ] && ok "sala-test-a is back on aws-platform, the same environment" || bad "a after recycle: $(awsplog "$U1")"
[ "$(cachelog "$U1")" = "cache1h=1 cache1h_bedrock=-" ] && [ "$(cachelog "$U2")" = "cache1h=- cache1h_bedrock=-" ] && ok "after the recycle the aws-platform pane's relaunch line (resume_cmd) still carries ENABLE_PROMPT_CACHING_1H=1, the subscription-1 pane's does not" || bad "cache switch after recycle: a $(cachelog "$U1") b $(cachelog "$U2")"
grep -q 'sala-test-a:0: 9.9.9 → 9.9.9 (lane aws-platform)' "$RLOG" && ok "the summary row names the lane" || bad "no lane in the summary: $(grep 'sala-test-a:0' "$RLOG" | tail -3)"
[ "$(awsplog "$U2")" = "$NONE" ] && ok "sala-test-b is back on subscription-1" || bad "b after recycle: $(awsplog "$U2")"
$T set-environment -g FAKE_SESSION_ID "$U3"; $T set-environment -g FAKE_NAME sala-test-c; $T set-environment -g FAKE_AWSP_LOG "$FAKE_AWSP_LOG"; $T set-environment -g FAKE_CACHE_LOG "$FAKE_CACHE_LOG"
out=$("$SALA" spawn sala-test-c --lane aws-platform --cwd "$HOME" 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(awsplog "$U3")" = "$WANT" ] && [ "$(cachelog "$U3")" = "cache1h=1 cache1h_bedrock=-" ] && ok "spawn --lane aws-platform: claude started with the lane's environment and ENABLE_PROMPT_CACHING_1H=1" || bad "spawn ($rc): $(awsplog "$U3") / $out"
grep -q 'lane    : aws-platform' <<< "$out" && ok "spawn's report names the lane" || bad "spawn report: $out"
out=$("$SALA" lane default aws-platform --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'would set the default lane: aws-platform' <<< "$out" && [ ! -e "$SALA_LANE_DEFAULT_FILE" ] && ok "lane default aws-platform --dry-run: accepted now, nothing written" || bad "default dry run ($rc): $out"
out=$("$SALA" lane subscription-1 sala-test-a 2>&1); rc=$?
[ "$rc" = 0 ] && waitfor '[ "$(starts "$U1")" = 4 ]' 40 && ok "sala lane subscription-1 sala-test-a: relaunched" || bad "switch back ($rc): $out"
fake_up sala-test-a
[ "$(cachelog "$U1")" = "cache1h=- cache1h_bedrock=-" ] && [ "$(awsplog "$U1")" = "$NONE" ] && [ "$(proc_lane "$(cpid a)")" = subscription-1 ] && ok "back on subscription-1: none of the lane's variables and no cache switch, proc_lane subscription-1" || bad "after the switch back: $(awsplog "$U1") $(proc_lane "$(cpid a)")"

echo "== a pane whose shell holds CLAUDE_CODE_USE_BEDROCK, CLAUDE_CODE_USE_FOUNDRY and a workspace key: the relaunched claude holds none"
mk d "$U4" -e CLAUDE_CODE_USE_BEDROCK=1 -e CLAUDE_CODE_USE_FOUNDRY=1 -e ANTHROPIC_AWS_API_KEY="$DUMMYSECRET"; fake_up sala-test-d
dp=$(tmux display -p -t sala-test-d '#{pane_pid}')
[ "$(tr '\0' '\n' < "/proc/$dp/environ" | grep -cE '^(CLAUDE_CODE_USE_BEDROCK|CLAUDE_CODE_USE_FOUNDRY|ANTHROPIC_AWS_API_KEY)=')" = 3 ] && [ "$(proc_lane "$(cpid d)")" = bedrock ] && ok "before: the pane's shell holds the three (its claude reads as bedrock)" || bad "poisoned pane: $(proc_lane "$(cpid d)")"
out=$("$SALA" lane aws-platform sala-test-d 2>&1); rc=$?
[ "$rc" = 0 ] && waitfor '[ "$(starts "$U4")" = 2 ]' 40 && ok "sala lane aws-platform sala-test-d: relaunched" || bad "poisoned relaunch ($rc): $out $(tail -5 "$RLOG")"
fake_up sala-test-d
[ "$(awsplog "$U4")" = "$WANT" ] && ok "its claude has the lane's environment, bedrock=- foundry=- apikey=n: none of the three came through" || bad "poisoned env: $(awsplog "$U4")"
[ "$(proc_lane "$(cpid d)")" = aws-platform ] && ok "and proc_lane reads aws-platform, not bedrock" || bad "poisoned proc_lane: $(proc_lane "$(cpid d)")"
! tr '\0' '\n' < "/proc/$(cpid d)/environ" | grep -qE '^(CLAUDE_CODE_USE_BEDROCK|CLAUDE_CODE_USE_FOUNDRY|ANTHROPIC_AWS_API_KEY)=' && ok "straight from the process's environment: the three are not there" || bad "a poisoned variable reached the claude"
! $T capture-pane -p -S - -t sala-test-d | leaks && ! cat "$RLOG" "$SALA_LANE_LOG" 2>/dev/null | leaks && ok "and the dummy key is in no scrollback or log" || bad "the dummy workspace key leaked"

echo "== the lane is refused again once the workspace id or the profile is gone: before anything is recorded"
out=$(SALA_LANE_AWSPLATFORM_WORKSPACE_ID= "$SALA" lane aws-platform sala-test-b 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'no workspace id yet' <<< "$out" && [ -z "$(lane_row sala-test-b)" ] && [ "$(starts "$U2")" = 2 ] && ok "no workspace id: refused, the knob named; nothing recorded, nothing relaunched" || bad "refusal ($rc): $out / row '$(lane_row sala-test-b)'"
mv "$CRED" "$CRED.away"
out=$("$SALA" lane aws-platform sala-test-b 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'no \[example-bedrock\] profile' <<< "$out" && [ -z "$(lane_row sala-test-b)" ] && [ "$(starts "$U2")" = 2 ] && ok "no profile: refused, naming it; nothing recorded, nothing relaunched" || bad "refusal ($rc): $out / row '$(lane_row sala-test-b)'"
out=$("$SALA" spawn sala-test-e --lane aws-platform --cwd "$HOME" 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q "the lane 'aws-platform' cannot launch" <<< "$out" && ok "spawn --lane aws-platform: refused the same way" || bad "spawn refusal ($rc): $out"
mv "$CRED.away" "$CRED"

echo "== the old name (awsplatform): typed, and in a row written before the rename"
wait_lock
out=$("$SALA" lane awsplatform sala-test-a 2>&1); rc=$?
[ "$rc" = 0 ] && waitfor '[ "$(starts "$U1")" = 5 ]' 40 && grep -q 'awsplatform is the old name of the aws-platform lane' <<< "$out" && ok "sala lane awsplatform sala-test-a: accepted, said to be the old name, relaunched" || bad "typed old name ($rc): $out"
fake_up sala-test-a
[ "$(awsplog "$U1")" = "$WANT" ] && [ "$(proc_lane "$(cpid a)")" = aws-platform ] && ok "its claude has the lane's environment and proc_lane prints the new name" || bad "old name typed: $(awsplog "$U1") / $(proc_lane "$(cpid a)")"
grep -qP '^sala-test-a\taws-platform$' "$SALA_LANES" && ! grep -q awsplatform "$SALA_LANES" && ok "recorded as aws-platform: the old word is never written" || bad "lanes.tsv: $(<"$SALA_LANES")"
printf 'sala-test-b\tawsplatform\n' >> "$SALA_LANES"; sum0=$(md5sum < "$SALA_LANES")
[ "$(lane_row sala-test-b)" = aws-platform ] && [ "$(lane_for_session sala-test-b)" = aws-platform ] && ok "a row written before the rename reads as aws-platform" || bad "old row: $(lane_row sala-test-b) / $(lane_for_session sala-test-b)"
grep -qE '^sala-test-b +aws-platform +subscription-1' <<< "$("$SALA" lane 2>&1)" && ok "the table shows it as aws-platform (recorded) beside subscription-1 (running), no 'not a lane' flag" || bad "table: $("$SALA" lane 2>&1 | grep sala-test-b)"
[ "$(md5sum < "$SALA_LANES")" = "$sum0" ] && ok "reading it rewrote nothing (the migration and the next write do)" || bad "a read changed lanes.tsv"
"$SALA" revive --force --only sala-test-b >/dev/null 2>&1; waitfor '[ "$(starts "$U2")" = 3 ]' 40
wait_lock; fake_up sala-test-b
[ "$(awsplog "$U2")" = "$WANT" ] && [ "$(proc_lane "$(cpid b)")" = aws-platform ] && ok "a relaunch from that old row puts the pane on the lane: the environment is the lane's" || bad "relaunch from the old row: $(awsplog "$U2") starts $(starts "$U2")"
out=$("$SALA" lane --migrate 2>&1); rc=$?
[ "$rc" = 0 ] && grep -qP '^sala-test-b\taws-platform$' "$SALA_LANES" && ! grep -q awsplatform "$SALA_LANES" && ok "lane --migrate rewrites the old row" || bad "migrate ($rc): $out / $(<"$SALA_LANES")"

[ "$fail" = 0 ] && echo "aws-platform-lane: pass" || echo "aws-platform-lane: FAIL"
exit $fail
