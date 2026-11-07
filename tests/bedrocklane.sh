#!/usr/bin/env bash
# The bedrock lane (lib/common.sh "lanes" and lane_check, lib/lane.sh): Claude on Amazon Bedrock
# through the AWS profile example-bedrock, launchable like the api lane. What is checked guards the profile and the launch line:
# lane_check bedrock refusing in plain words for each missing thing (no credentials file, no `[example-bedrock]` header line
# (a look at the header alone: a comment, a longer name, a [default] section do not count), an unreadable --mcp-config file, no
# claude launcher, a malformed region/prefix/model) and passing with a temporary HOME whose credentials file holds only the header
# and dummy values; an administrator profile named in config refused whatever the file holds, without the refusal naming it;
# the status DERIVED from lane_check (active / not set up, a config override winning); the env on the launch line exactly as the
# brief states it (AWS_PROFILE, CLAUDE_CODE_USE_BEDROCK=1, AWS_REGION=us-east-1, ANTHROPIC_BEDROCK_REGION_PREFIX=global, the
# three pinned global models), settable by config, with `--mcp-config` as the api lane's (once, only with the file) and no key,
# header or value of the credentials file anywhere; the env on that pane's launch line ONLY (a shell that runs the line keeps
# nothing, no settings file written, the other pane untouched); `sala lane bedrock <session>` end to end through the direct
# sweep (recorded, relaunched, proc_lane bedrock, the table, a recycle and a spawn keeping it, a switch back to subscription-1 clearing it);
# `--dry-run` naming the variables and no value; no Remote Control on the lane. The credentials file holds DUMMY values, counted
# and never printed. Posts stubbed to a file; isolated HOME, a private tmux socket, the compiled fake claude
# (tests/fake-claude.c, FAKE_BEDROCK_LOG). Usage: bash tests/bedrocklane.sh   (exit 0 = pass; ~45 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_SET SALA_SET_SELF SALA_POST_RECYCLE_CMD SALA_RECYCLE SALA_RETRY_WORKER SALA_NO_RELAUNCH SALA_MASTER
unset ANTHROPIC_API_KEY ANTHROPIC_CUSTOM_HEADERS CLAUDE_CONFIG_DIR SALA_LANE_API_KEY_FILE SALA_LANE_API_WORKSPACE_FILE SALA_LANE_API_MCP_CONFIG SALA_LANE_TEAM_DIR
unset AWS_PROFILE AWS_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_BEARER_TOKEN_BEDROCK CLAUDE_CODE_USE_BEDROCK ANTHROPIC_BEDROCK_REGION_PREFIX
unset ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL SALA_LANE_BEDROCK_PROFILE SALA_LANE_BEDROCK_CREDENTIALS_FILE SALA_LANE_BEDROCK_PREFIX
unset SALA_LANE_BEDROCK_OPUS_MODEL SALA_LANE_BEDROCK_SONNET_MODEL SALA_LANE_BEDROCK_HAIKU_MODEL SALA_LANE_BEDROCK_REGION SALA_LANE_BEDROCK_STATUS
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, tmux_socket_rm
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
as_op_unit   # no master: the guarded verbs this suite runs itself stand for the queue's runner (tests/lib.sh, 5)
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$HOME/.aws"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$HOME/.local/share/claude/versions/9.9.9" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
ln -s "$HOME/.local/share/claude/versions/9.9.9" "$HOME/.local/bin/claude"
printf '#!/bin/sh\necho "$*" >> "%s/systemd-run.txt"\n' "$HOME" > "$HOME/.local/bin/systemd-run"; chmod +x "$HOME/.local/bin/systemd-run"
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log" FAKE_LANE_LOG="$HOME/fake-lane.log" FAKE_TYPED_LOG="$HOME/typed.log" FAKE_BEDROCK_LOG="$HOME/fake-bedrock.log" FAKE_CACHE_LOG="$HOME/fake-cache.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="{ cat; echo '%%'; } >> $POSTS"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off
SALA="$ROOT/bin/salamander"; SOCK="sala-bedrock-$$"; T="tmux -L $SOCK -f /dev/null"; RLOG="$HOME/.claude/salamander-revive.log"
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
mk() { local n="$1" u="$2"; shift 2; $T new-session -d -s "sala-test-$n" -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="sala-test-$n" -e FAKE_LOG="$FAKE_LOG" -e FAKE_LANE_LOG="$FAKE_LANE_LOG" -e FAKE_TYPED_LOG="$FAKE_TYPED_LOG" -e FAKE_BEDROCK_LOG="$FAKE_BEDROCK_LOG" -e FAKE_CACHE_LOG="$FAKE_CACHE_LOG" "$@"; $T send-keys -t "sala-test-$n" 'claude' Enter; }
bedlog() { grep "^$1 " "$FAKE_BEDROCK_LOG" 2>/dev/null | tail -1 | cut -d' ' -f2-; }   # <uuid> → "profile=… use=… …" of its latest start
cachelog() { grep "^$1 " "$FAKE_CACHE_LOG" 2>/dev/null | tail -1 | cut -d' ' -f2-; }   # <uuid> → "cache1h=<plain switch> cache1h_bedrock=<bedrock switch>" of its latest start ("-" for unset)
U1=$(uuid 1); U2=$(uuid 2); U3=$(uuid 3)
OPUS=global.anthropic.claude-opus-5-5; SONNET=global.anthropic.claude-sonnet-5-5; HAIKU=global.anthropic.claude-haiku-5-5
WANT="profile=example-bedrock use=1 region=us-east-1 prefix=global opus=$OPUS sonnet=$SONNET haiku=$HAIKU awskey=n"
leaks() { grep -qF -e "$DUMMYID" -e "$DUMMYSECRET"; }   # stdin → 0 when a dummy value is in it

echo "== lane_check bedrock: each missing thing is named, in a plain sentence"
rm -f "$CRED"
why=$(lane_check bedrock); rc=$?
[ "$rc" = 1 ] && grep -q 'bedrock lane: no \[example-bedrock\] profile in' <<< "$why" && grep -q 'key-entry script' <<< "$why" && ok "no credentials file: refused, the profile and the key-entry script named" || bad "no file ($rc): $why"
printf '[default]\naws_access_key_id = %s\naws_secret_access_key = %s\n' "$DUMMYID" "$DUMMYSECRET" > "$CRED"
why=$(lane_check bedrock); rc=$?
[ "$rc" = 1 ] && grep -q 'no \[example-bedrock\] profile' <<< "$why" && ok "a file with only [default]: refused" || bad "only [default] ($rc): $why"
printf '# [example-bedrock]\n[example-bedrock-old]\n  [example-bedrock]x\nexample-bedrock\n' >> "$CRED"
lane_check bedrock >/dev/null 2>&1 && bad "a comment, a longer name and a bare word passed as the header" || ok "a commented header, a longer profile name and the bare word do not count"
printf '[example-bedrock]\naws_access_key_id = %s\naws_secret_access_key = %s\n' "$DUMMYID" "$DUMMYSECRET" >> "$CRED"
lane_check bedrock >/dev/null && ok "the header line among other sections (dummy values below it): ready" || bad "lane_check bedrock: $(lane_check bedrock)"
printf '[default]\n[example-bedrock]   \r\naws_access_key_id = x\n' > "$CRED"; lane_check bedrock >/dev/null && ok "trailing blanks and a CR after the header: still the header" || bad "trailing blanks: $(lane_check bedrock)"
printf '[example-bedrock]\naws_access_key_id = %s\naws_secret_access_key = %s\n' "$DUMMYID" "$DUMMYSECRET" > "$CRED"   # only the header and dummy values, as the brief tests it
out="$(lane_check bedrock; SALA_LANE_BEDROCK_PROFILE=other lane_check bedrock; "$SALA" lane 2>&1)"
leaks <<< "$out" && bad "a dummy credential value appeared in lane_check or the table" || ok "no credential value in lane_check's output or the table (the file is only tested for the header)"
SALA_LANE_BEDROCK_PROFILE=other lane_check bedrock | grep -q 'no \[other\] profile' && ok "SALA_LANE_BEDROCK_PROFILE names another profile: that header is what is looked for" || bad "profile override: $(SALA_LANE_BEDROCK_PROFILE=other lane_check bedrock)"
why=$(SALA_LANE_BEDROCK_PROFILE='bad name' lane_check bedrock); [ $? = 1 ] && grep -q 'profile name' <<< "$why" && ok "a profile name a typed line cannot carry: refused" || bad "bad profile name: $why"
mkdir -p "$HOME/.config/claude-lanes"; echo '{"mcpServers":{}}' > "$HOME/.config/claude-lanes/api-mcp.json"; chmod 000 "$HOME/.config/claude-lanes/api-mcp.json"
why=$(lane_check bedrock); rc=$?
[ "$rc" = 1 ] && grep -q 'bedrock lane: the --mcp-config file' <<< "$why" && grep -q 'SALA_LANE_API_MCP_CONFIG' <<< "$why" && ok "an --mcp-config file that exists but is unreadable: refused, as the api lane refuses it" || bad "unreadable mcp ($rc): $why"
chmod 600 "$HOME/.config/claude-lanes/api-mcp.json"; lane_check bedrock >/dev/null && ok "readable again: ready" || bad "mcp readable: $(lane_check bedrock)"
rm -f "$HOME/.config/claude-lanes/api-mcp.json"; lane_check bedrock >/dev/null && ok "no --mcp-config file at all: ready (optional, as on the api lane)" || bad "no mcp: $(lane_check bedrock)"
why=$(SALA_CLAUDE="$HOME/nowhere/claude" lane_check bedrock); [ $? = 1 ] && grep -q 'no claude launcher' <<< "$why" && ok "no claude launcher: refused, named" || bad "no launcher: $why"
why=$(SALA_LANE_BEDROCK_PREFIX=mars lane_check bedrock); [ $? = 1 ] && grep -q 'region prefix' <<< "$why" && ok "a region prefix outside the documented six: refused" || bad "prefix: $why"
why=$(SALA_LANE_BEDROCK_SONNET_MODEL='a b' lane_check bedrock); [ $? = 1 ] && grep -q 'model id' <<< "$why" && ok "a model id a typed line cannot carry: refused" || bad "model: $why"
why=$(SALA_LANE_BEDROCK_REGION='ap northeast' lane_check bedrock); [ $? = 1 ] && ok "a region with a space: refused" || bad "region: $why"

echo "== the administrator profile is never the lane's: refused whatever the credentials file holds"
printf '[example-admin]\naws_access_key_id = %s\n[example-bedrock]\naws_access_key_id = %s\n' "$DUMMYID" "$DUMMYID" > "$CRED"
why=$(SALA_LANE_BEDROCK_PROFILE=example-admin lane_check bedrock); rc=$?
[ "$rc" = 1 ] && grep -q 'not an administrator profile' <<< "$why" && ok "a config naming the administrator profile: refused, though its section is in the file" || bad "admin profile ($rc): $why"
! grep -q 'example-admin' <<< "$why" && ok "and the refusal does not repeat the profile's name" || bad "the refusal names the admin profile: $why"
SALA_LANE_BEDROCK_PROFILE=Prod-ADMIN lane_check bedrock >/dev/null && bad "an uppercase admin profile passed" || ok "any profile whose name says admin, in any case: refused"
[ "$(SALA_LANE_BEDROCK_PROFILE=example-admin lane_field bedrock status)" = "not set up" ] && ok "and its status stays not set up" || bad "admin status"
printf '[example-bedrock]\naws_access_key_id = %s\naws_secret_access_key = %s\n' "$DUMMYID" "$DUMMYSECRET" > "$CRED"

echo "== the status is derived from lane_check; the region is the launch's"
[ "$(lane_field bedrock status)" = active ] && ok "profile present: bedrock's status is active" || bad "status: $(lane_field bedrock status)"
[ "$(SALA_LANE_BEDROCK_STATUS=inactive lane_field bedrock status)" = inactive ] && ok "a config SALA_LANE_BEDROCK_STATUS still wins" || bad "status override"
[ "$(lane_field bedrock region)" = us-east-1 ] && [ "$(SALA_LANE_BEDROCK_REGION=us-west-2 lane_field bedrock region)" = us-west-2 ] && ok "region from SALA_LANE_BEDROCK_REGION (the fixture us-east-1), another value overriding it" || bad "region"
why=$(SALA_LANE_BEDROCK_REGION= lane_check bedrock); [ $? = 1 ] && grep -q 'AWS region is not set' <<< "$why" && grep -q SALA_LANE_BEDROCK_REGION <<< "$why" && [ "$(SALA_LANE_BEDROCK_REGION= lane_field bedrock status)" = "not set up" ] && ok "no region set: refused in a plain sentence naming the setting, status not set up" || bad "unset region: $why"
[ "$(lane_field bedrock credential)" = "AWS profile" ] && ! lane_field bedrock credential | grep -qF -e "$CRED" -e example-bedrock && ok "the credential field says 'AWS profile': no path, no profile name" || bad "credential field: $(lane_field bedrock credential)"
out=$("$SALA" lane --list 2>&1); grep -E '^bedrock ' <<< "$out" | grep -q ' active$' && ok "lane --list: bedrock active" || bad "--list: $out"
python3 -c 'import json,sys; d=json.load(sys.stdin); b=[l for l in d["lanes"] if l["id"]=="bedrock"][0]; assert b["status"]=="active" and b["region"]=="us-east-1" and b["credential"]=="AWS profile", b' <<< "$("$SALA" lane --json 2>&1)" && ok "lane --json: status active, region us-east-1, credential 'AWS profile'" || bad "--json: $("$SALA" lane --json 2>&1)"
grep -q 'bedrock ready' <<< "$("$SALA" lane 2>&1)" && ok "the no-argument table: bedrock ready" || bad "table: $("$SALA" lane 2>&1)"
mv "$CRED" "$CRED.away"; [ "$(lane_field bedrock status)" = "not set up" ] && ok "the credentials file gone: back to not set up" || bad "status after removal"; mv "$CRED.away" "$CRED"

echo "== the launch line: names and ids, nothing secret; config settles each one"
[ "$(lane_env_names bedrock)" = "AWS_PROFILE CLAUDE_CODE_USE_BEDROCK AWS_REGION ANTHROPIC_BEDROCK_REGION_PREFIX ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ENABLE_PROMPT_CACHING_1H_BEDROCK" ] && ok "lane_env_names bedrock: the eight names a dry run shows (the seven and the pane's 1-hour cache switch)" || bad "names: $(lane_env_names bedrock)"
p=$(lane_env_prefix bedrock)
[ "$p" = "AWS_PROFILE=example-bedrock CLAUDE_CODE_USE_BEDROCK=1 AWS_REGION=us-east-1 ANTHROPIC_BEDROCK_REGION_PREFIX=global ANTHROPIC_DEFAULT_OPUS_MODEL=$OPUS ANTHROPIC_DEFAULT_SONNET_MODEL=$SONNET ANTHROPIC_DEFAULT_HAIKU_MODEL=$HAIKU ENABLE_PROMPT_CACHING_1H_BEDROCK=1 " ] && ok "the prefix: profile, use flag, region, prefix global, the three pinned global models, the 1-hour cache switch" || bad "prefix: '$p'"
! leaks <<< "$p" && ! grep -q 'cat ' <<< "$p" && ok "no credential value and no \$(cat …) on the line" || bad "a value or a cat on the line"
p2=$(SALA_LANE_BEDROCK_PROFILE=p2 SALA_LANE_BEDROCK_REGION=us-east-2 SALA_LANE_BEDROCK_PREFIX=us SALA_LANE_BEDROCK_OPUS_MODEL=o1 SALA_LANE_BEDROCK_SONNET_MODEL=s1 SALA_LANE_BEDROCK_HAIKU_MODEL=h1:0 lane_env_prefix bedrock)
[ "$p2" = "AWS_PROFILE=p2 CLAUDE_CODE_USE_BEDROCK=1 AWS_REGION=us-east-2 ANTHROPIC_BEDROCK_REGION_PREFIX=us ANTHROPIC_DEFAULT_OPUS_MODEL=o1 ANTHROPIC_DEFAULT_SONNET_MODEL=s1 ANTHROPIC_DEFAULT_HAIKU_MODEL=h1:0 ENABLE_PROMPT_CACHING_1H_BEDROCK=1 " ] && ok "profile, region, prefix and the three models are each settable in sala config" || bad "overrides: '$p2'"
pj=$(lane_env_prefix bedrock job)
[ "$pj" = "${p% ENABLE_PROMPT_CACHING_1H_BEDROCK=1 } " ] && ! grep -q 'ENABLE_PROMPT_CACHING' <<< "$pj" && ok "lane_env_prefix bedrock job: the same seven pairs and no ENABLE_PROMPT_CACHING_1H_BEDROCK (a one-shot job never reuses a 1-hour write)" || bad "job prefix: '$pj'"
[ -z "$(lane_env_prefix subscription-1)" ] && ! grep -q 'ENABLE_PROMPT_CACHING' <<< "$(lane_env_prefix subscription-2)" && ! grep -q 'ENABLE_PROMPT_CACHING_1H_BEDROCK' <<< "$(lane_env_prefix aws-platform; lane_env_prefix api)" && ok "subscription-1, subscription-2, api and aws-platform carry no ENABLE_PROMPT_CACHING_1H_BEDROCK (api and aws-platform carry the plain ENABLE_PROMPT_CACHING_1H instead, see their suites)" || bad "another lane carries the bedrock cache switch"
n=$(eval "${p}env" | grep -cE "^(AWS_PROFILE=example-bedrock|CLAUDE_CODE_USE_BEDROCK=1|AWS_REGION=us-east-1|ANTHROPIC_BEDROCK_REGION_PREFIX=global|ANTHROPIC_DEFAULT_(OPUS|SONNET|HAIKU)_MODEL=global\.anthropic\.claude-(opus|sonnet|haiku)-5-5)\$")
[ "$n" = 7 ] && [ "$(eval "${p}env" | grep -c '^ENABLE_PROMPT_CACHING_1H_BEDROCK=1$')" = 1 ] && ok "run by a shell, the line hands that process all seven and the cache switch (counted)" || bad "evaluated prefix: $n of 7"
[ -z "${AWS_PROFILE:-}${CLAUDE_CODE_USE_BEDROCK:-}${AWS_REGION:-}" ] && ! env | grep -qE '^(AWS_PROFILE|CLAUDE_CODE_USE_BEDROCK|AWS_REGION|ANTHROPIC_DEFAULT_OPUS_MODEL)=' && ok "and this shell exports none of them: the env is on the line only" || bad "the env leaked into the shell"
[ -z "$(lane_args subscription-1)$(lane_args subscription-2)" ] && ok "subscription-1 and subscription-2 add no argument" || bad "args: $(lane_args subscription-1)$(lane_args subscription-2)"
[ -z "$(lane_args bedrock)" ] && ok "bedrock: no --mcp-config without the file" || bad "mcp without file: $(lane_args bedrock)"
echo '{"mcpServers":{}}' > "$HOME/.config/claude-lanes/api-mcp.json"
[ "$(lane_args bedrock)" = " --mcp-config $HOME/.config/claude-lanes/api-mcp.json" ] && [ "$(lane_args bedrock)" = "$(lane_args api)" ] && ok "with the file: --mcp-config <SALA_LANE_API_MCP_CONFIG>, the api lane's own" || bad "mcp: $(lane_args bedrock)"
lane_rc bedrock && bad "bedrock claims a Remote Control bridge" || ok "lane_rc bedrock: no Remote Control (no claude.ai login behind it)"
lane_write sala-test-x bedrock; r=$(resume_cmd "$U3" sala-test-x)
[ "$r" = "$p$(mod_env_prefix)claude --resume $U3 --mcp-config $HOME/.config/claude-lanes/api-mcp.json" ] && ok "resume_cmd for a session on bedrock: the env, claude --resume, then --mcp-config" || bad "resume_cmd: $r"
[ "$(grep -o -- '--mcp-config' <<< "$r" | wc -l)" = 1 ] && ! leaks <<< "$r" && ok "--mcp-config once; no credential value on the resume line" || bad "resume line: $r"
lane_drop sala-test-x
lane_out bedrock >/dev/null; [ $? = 1 ] && ok "lane_out bedrock: nothing wrong (the rescue may move a pane to it)" || bad "lane_out bedrock: $(lane_out bedrock)"

echo "== a scheduled job on the lane: lane env, lane exec, job_env_args, and sala's own job calls"
n=$("$SALA" lane env bedrock | grep -cE "^(AWS_PROFILE=example-bedrock|CLAUDE_CODE_USE_BEDROCK=1|AWS_REGION=us-east-1|ANTHROPIC_BEDROCK_REGION_PREFIX=global|ANTHROPIC_DEFAULT_(OPUS|SONNET|HAIKU)_MODEL=global\.anthropic\.claude-(opus|sonnet|haiku)-5-5)\$")
[ "$n" = 7 ] && [ "$("$SALA" lane env bedrock | wc -l)" = 7 ] && ! "$SALA" lane env bedrock | grep -q ENABLE_PROMPT_CACHING && ok "lane env bedrock: exactly the seven NAME=value lines of the launch line, without the pane-only ENABLE_PROMPT_CACHING_1H_BEDROCK (one source: lane_env_prefix)" || bad "lane env bedrock: $n of 7"
! leaks <<< "$("$SALA" lane env bedrock 2>&1)" && ok "and no credential value among them" || bad "lane env shows a credential value"
[ -z "$("$SALA" lane env subscription-1)" ] && "$SALA" lane env subscription-1 >/dev/null && ok "lane env subscription-1: nothing, exit 0" || bad "lane env subscription-1"
out=$("$SALA" lane env api 2>&1); rc=$?; [ "$rc" = 1 ] && grep -q 'reads its key from a file' <<< "$out" && ok "lane env api: refused, with the reason (a key file read by a shell is no environment to hand a job)" || bad "lane env api ($rc): $out"
out=$("$SALA" lane env nonsense 2>&1); rc=$?; [ "$rc" = 1 ] && grep -q "unknown lane 'nonsense'" <<< "$out" && ok "lane env <unknown>: refused" || bad "lane env nonsense ($rc): $out"
out=$("$SALA" lane env 2>&1); rc=$?; [ "$rc" != 0 ] && grep -q 'usage: salamander lane env' <<< "$out" && ok "lane env with no lane: the usage line" || bad "lane env usage ($rc): $out"
out=$("$SALA" lane exec bedrock 2>&1); rc=$?; [ "$rc" != 0 ] && grep -q 'usage: salamander lane exec' <<< "$out" && ok "lane exec without -- COMMAND: the usage line, nothing run" || bad "lane exec usage ($rc): $out"
POISON=$(env ANTHROPIC_API_KEY="[masked secret]$$" ANTHROPIC_CUSTOM_HEADERS=x ANTHROPIC_AUTH_TOKEN=x AWS_BEARER_TOKEN_BEDROCK=x CLAUDE_CODE_USE_ANTHROPIC_AWS=1 CLAUDE_CODE_USE_FOUNDRY=1 CLAUDE_CONFIG_DIR="$HOME/.claude-other" CLAUDE_CODE_USE_BEDROCK=0 AWS_PROFILE=elsewhere \
    "$SALA" lane exec bedrock -- env 2>&1)
n=$(grep -cE "^(AWS_PROFILE=example-bedrock|CLAUDE_CODE_USE_BEDROCK=1|AWS_REGION=us-east-1|ANTHROPIC_BEDROCK_REGION_PREFIX=global|ANTHROPIC_DEFAULT_(OPUS|SONNET|HAIKU)_MODEL=global\.anthropic\.claude-(opus|sonnet|haiku)-5-5)\$" <<< "$POISON")
[ "$n" = 7 ] && ! grep -q '^ENABLE_PROMPT_CACHING' <<< "$POISON" && ok "lane exec bedrock -- env: the command got the lane's seven variables (no 1-hour cache switch), the lane's profile and use flag replacing the poisoned ones" || bad "lane exec env: $n of 7"
! grep -qE '^(ANTHROPIC_API_KEY|ANTHROPIC_CUSTOM_HEADERS|ANTHROPIC_AUTH_TOKEN|AWS_BEARER_TOKEN_BEDROCK|CLAUDE_CODE_USE_ANTHROPIC_AWS|CLAUDE_CODE_USE_FOUNDRY|CLAUDE_CONFIG_DIR)=' <<< "$POISON" && ok "and none of the key, headers, token, bearer token, aws-platform or Foundry switch or config directory it started with (counted, never printed)" || bad "a poisoned variable survived lane exec"
"$SALA" lane exec bedrock -- sh -c 'exit 7'; [ $? = 7 ] && ok "lane exec passes the command's exit status through" || bad "lane exec exit status"
rm -f "$HOME/ran"; mv "$CRED" "$CRED.away"
out=$("$SALA" lane exec bedrock -- touch "$HOME/ran" 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'no \[example-bedrock\] profile' <<< "$out" && [ ! -e "$HOME/ran" ] && ok "lane exec on a lane that is not ready: exit 1, the reason, the command never ran" || bad "lane exec not ready ($rc): $out"
job_env_args bedrock; [ $? = 1 ] && grep -q 'no \[example-bedrock\] profile' <<< "$JOB_ENV_WHY" && [ "${#JOB_ENV[@]}" = 0 ] && ok "job_env_args: the same refusal, an empty array" || bad "job_env_args refusal: $JOB_ENV_WHY"
mv "$CRED.away" "$CRED"
job_env_args bedrock; [ $? = 0 ] && [ "${#JOB_ENV[@]}" = "$(( 2 * $(lane_job_unset | wc -w) + 7 ))" ] && [ "${JOB_ENV[0]}" = -u ] && printf '%s\n' "${JOB_ENV[@]}" | grep -q '^CLAUDE_CODE_USE_BEDROCK=1$' && ! printf '%s\n' "${JOB_ENV[@]}" | grep -q '^ENABLE_PROMPT_CACHING[A-Z_0-9]*=' && ok "job_env_args bedrock: -u for each name in lane_job_unset (every lane's, see tests/aws-platform-lane.sh), then the lane's seven pairs" || bad "job_env_args: ${#JOB_ENV[@]} words"
job_env_args subscription-1; [ $? = 0 ] && [ "${#JOB_ENV[@]}" = "$(( 2 * $(lane_job_unset | wc -w) ))" ] && ! printf '%s\n' "${JOB_ENV[@]}" | grep -q '=' && ok "job_env_args subscription-1: the -u words alone (subscription-1 sets nothing; it starts clean of the other lanes' variables)" || bad "job_env_args subscription-1: ${JOB_ENV[*]}"
# the stuck-operation helper (lib/op.sh) puts the SALA_JOB_LANE lane on its one claude -p; the stub records names only
cat > "$HOME/job-stub" <<'EOF'
#!/bin/bash
{ for v in AWS_PROFILE CLAUDE_CODE_USE_BEDROCK AWS_REGION ANTHROPIC_BEDROCK_REGION_PREFIX ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL; do [ -n "${!v:-}" ] && echo "has $v"; done
  for v in ANTHROPIC_API_KEY ANTHROPIC_CUSTOM_HEADERS CLAUDE_CONFIG_DIR AWS_BEARER_TOKEN_BEDROCK CLAUDE_CODE_USE_ANTHROPIC_AWS; do [ -n "${!v:-}" ] && echo "leak $v"; done; } > "$HOME/job-stub.out"
echo "SALA-OP: done stub"
EOF
chmod +x "$HOME/job-stub"
helper_run() { ( . "$ROOT/lib/op.sh"; op_brief() { echo brief; }; export SALA_OP_CLAUDE="$HOME/job-stub" SALA_OP_HELPER_CWD="$HOME" SALA_OP_STUCK_TIME=20 SALA_OP_STUCK_TURNS=2; op_helper jobtest "a failure" 2>"$HOME/job-helper.err" ); }
rm -f "$HOME/job-stub.out"
out=$(SALA_JOB_LANE=bedrock ANTHROPIC_API_KEY="[masked secret]$$" CLAUDE_CONFIG_DIR="$HOME/.claude-other" helper_run); rc=$?
[ "$rc" = 0 ] && [ "$(grep -c '^has ' "$HOME/job-stub.out")" = 7 ] && ! grep -q '^leak ' "$HOME/job-stub.out" && grep -q 'on the bedrock lane' "$HOME/job-helper.err" && ok "op_helper with SALA_JOB_LANE=bedrock: the stub claude -p got the seven lane variables and no key or config dir; the op log says bedrock" || bad "op_helper bedrock ($rc): $(<"$HOME/job-stub.out") / $out"
rm -f "$HOME/job-stub.out"; mv "$CRED" "$CRED.away"
out=$(SALA_JOB_LANE=bedrock helper_run); rc=$?
[ "$rc" = 1 ] && [ ! -e "$HOME/job-stub.out" ] && grep -q 'bedrock lane (SALA_JOB_LANE) is not ready' <<< "$out" && ok "op_helper with the lane not ready: no claude -p, the reason returned (the operation stays stuck, said in its log)" || bad "op_helper not ready ($rc): $out"
mv "$CRED.away" "$CRED"
out=$(SALA_JOB_LANE=subscription-1 helper_run); rc=$?
[ "$rc" = 0 ] && [ ! -s "$HOME/job-stub.out" ] && ok "SALA_JOB_LANE=subscription-1: the old behaviour, no lane variable on the claude -p" || bad "op_helper subscription-1 ($rc): $(<"$HOME/job-stub.out")"
rm -f "$HOME/job-stub" "$HOME/job-stub.out" "$HOME/job-helper.err" "$HOME/ran"

echo "== --dry-run: the variables' names, no value, nothing recorded"
mk a "$U1"; mk b "$U2"; fake_up sala-test-a sala-test-b
out=$("$SALA" lane bedrock sala-test-a --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'AWS_PROFILE CLAUDE_CODE_USE_BEDROCK AWS_REGION ANTHROPIC_BEDROCK_REGION_PREFIX ANTHROPIC_DEFAULT_OPUS_MODEL' <<< "$out" && grep -q 'ENABLE_PROMPT_CACHING_1H_BEDROCK' <<< "$out" && ok "dry run: the env names, the 1-hour cache switch among them" || bad "dry run ($rc): $out"
! leaks <<< "$out" && ! grep -q 'AWS_PROFILE=' <<< "$out" && ! grep -qF "$OPUS" <<< "$out" && ok "no credential value, and no VAR=value pair, in the dry run" || bad "dry run shows a value: $out"
grep -q 'no Remote Control' <<< "$out" && ok "and it says there is no Remote Control on this lane" || bad "no RC line: $out"
[ -z "$(lane_row sala-test-a)" ] && [ "$(starts "$U1")" = 1 ] && ok "nothing recorded, nothing relaunched" || bad "after dry run: row '$(lane_row sala-test-a)' starts $(starts "$U1")"

echo "== sala lane bedrock <session>: recorded, relaunched through the direct sweep"
[ "$(bedlog "$U1")" = "profile=- use=- region=- prefix=- opus=- sonnet=- haiku=- awskey=n" ] && ok "before: the pane's claude has none of the lane's variables" || bad "before: $(bedlog "$U1")"
out=$("$SALA" lane bedrock sala-test-a 2>&1); rc=$?
[ "$rc" = 0 ] && ok "exit 0" || bad "sala lane bedrock sala-test-a ($rc): $out"
waitfor '[ "$(starts "$U1")" = 2 ]' 40 && ok "sala-test-a relaunched" || bad "no relaunch: $(<"$FAKE_LOG") $(tail -5 "$RLOG")"
fake_up sala-test-a
[ "$(cachelog "$U1")" = "cache1h=- cache1h_bedrock=1" ] && ok "a bedrock pane's claude (sala lane relaunch) started with ENABLE_PROMPT_CACHING_1H_BEDROCK=1" || bad "cache switch after the lane move: $(cachelog "$U1")"
[ "$(bedlog "$U1")" = "$WANT" ] && ok "its claude started with exactly the lane's environment (profile, use flag, region, prefix, the three models) and no AWS key in it" || bad "bedrock env: $(bedlog "$U1")"
[ "$(lane_row sala-test-a)" = bedrock ] && ok "recorded: sala-test-a → bedrock" || bad "row: '$(lane_row sala-test-a)'"
[ "$(proc_lane "$(cpid a)")" = bedrock ] && ok "proc_lane reads bedrock from the process's environment" || bad "proc_lane: $(proc_lane "$(cpid a)")"
grep -qE '^sala-test-a +bedrock +bedrock' <<< "$("$SALA" lane)" && ok "the table: recorded bedrock, running bedrock" || bad "table: $("$SALA" lane)"
[ "$(cachelog "$U2")" = "cache1h=- cache1h_bedrock=-" ] && [ "$(bedlog "$U2")" = "profile=- use=- region=- prefix=- opus=- sonnet=- haiku=- awskey=n" ] && [ "$(starts "$U2")" = 1 ] && [ -z "$(lane_row sala-test-b)" ] && ok "sala-test-b untouched: no variable, no row" || bad "b: $(bedlog "$U2") starts $(starts "$U2")"
pp=$(tmux display -p -t sala-test-a '#{pane_pid}')
! tr '\0' '\n' < "/proc/$pp/environ" 2>/dev/null | grep -qE '^(AWS_|CLAUDE_CODE_USE_BEDROCK|ANTHROPIC_DEFAULT_)' && ok "the pane's shell never held the variables: the env is on the launch line only" || bad "the pane's shell environment carries the lane's variables"
[ ! -e "$HOME/.claude/settings.json" ] && [ ! -e "$HOME/.claude/settings.local.json" ] && ok "no settings file written (nothing in settings)" || bad "a settings file appeared"
! leaks <<< "$out" && ! $T capture-pane -p -S - -t sala-test-a | leaks && ! cat "$RLOG" "$SALA_LANE_LOG" 2>/dev/null | leaks && ! tr '\0' ' ' < "/proc/$(cpid a)/cmdline" | leaks \
    && ok "no credential value in the command's output, the pane's scrollback, the logs or the process's argv" || bad "a credential value leaked"
grep -q 'AWS_PROFILE' <<< "$out" && ok "the output names the variables" || bad "output: $out"

echo "== a recycle keeps the lane; a spawn on it; a switch back to subscription-1 clears it"
"$SALA" recycle --force >/dev/null 2>&1 || bad "recycle --force did not start"
waitfor '[ "$(starts "$U1")" = 3 ] && [ "$(starts "$U2")" = 2 ]' 60 && ok "both relaunched by the recycle" || bad "starts after recycle: a=$(starts "$U1") b=$(starts "$U2") $(tail -20 "$RLOG")"
wait_lock; fake_up sala-test-a sala-test-b
[ "$(cachelog "$U1")" = "cache1h=- cache1h_bedrock=1" ] && ok "after the recycle the bedrock pane's relaunch line still carries ENABLE_PROMPT_CACHING_1H_BEDROCK=1 (resume_cmd)" || bad "cache switch after recycle: $(cachelog "$U1")"
[ "$(cachelog "$U2")" = "cache1h=- cache1h_bedrock=-" ] && ok "and the subscription-1 pane's does not" || bad "subscription-1 pane after recycle: $(cachelog "$U2")"
[ "$(bedlog "$U1")" = "$WANT" ] && ok "sala-test-a is back on bedrock, the same environment" || bad "a after recycle: $(bedlog "$U1")"
grep -q 'sala-test-a:0: 9.9.9 → 9.9.9 (lane bedrock)' "$RLOG" && ok "the summary row names the lane" || bad "no lane in the summary: $(grep 'sala-test-a:0' "$RLOG" | tail -3)"
[ "$(bedlog "$U2")" = "profile=- use=- region=- prefix=- opus=- sonnet=- haiku=- awskey=n" ] && ok "sala-test-b is back on subscription-1" || bad "b after recycle: $(bedlog "$U2")"
$T set-environment -g FAKE_SESSION_ID "$U3"; $T set-environment -g FAKE_NAME sala-test-c; $T set-environment -g FAKE_BEDROCK_LOG "$FAKE_BEDROCK_LOG"; $T set-environment -g FAKE_CACHE_LOG "$FAKE_CACHE_LOG"
out=$("$SALA" spawn sala-test-c --lane bedrock --cwd "$HOME" 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(bedlog "$U3")" = "$WANT" ] && [ "$(cachelog "$U3")" = "cache1h=- cache1h_bedrock=1" ] && ok "spawn --lane bedrock: claude started with the lane's environment and ENABLE_PROMPT_CACHING_1H_BEDROCK=1" || bad "spawn ($rc): $(bedlog "$U3") / $out"
grep -q 'lane    : bedrock' <<< "$out" && ok "spawn's report names the lane" || bad "spawn report: $out"
out=$("$SALA" lane default bedrock --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'would set the default lane: bedrock' <<< "$out" && [ ! -e "$SALA_LANE_DEFAULT_FILE" ] && ok "lane default bedrock --dry-run: accepted now, nothing written" || bad "default dry run ($rc): $out"
out=$("$SALA" lane subscription-1 sala-test-a 2>&1); rc=$?
[ "$rc" = 0 ] && waitfor '[ "$(starts "$U1")" = 4 ]' 40 && ok "sala lane subscription-1 sala-test-a: relaunched" || bad "switch back ($rc): $out"
fake_up sala-test-a
[ "$(cachelog "$U1")" = "cache1h=- cache1h_bedrock=-" ] && [ "$(bedlog "$U1")" = "profile=- use=- region=- prefix=- opus=- sonnet=- haiku=- awskey=n" ] && [ "$(proc_lane "$(cpid a)")" = subscription-1 ] && ok "back on subscription-1: none of the lane's variables and no cache switch, proc_lane subscription-1" || bad "after the switch back: $(bedlog "$U1") $(proc_lane "$(cpid a)")"

echo "== the lane is refused again once the profile is gone: before anything is recorded"
mv "$CRED" "$CRED.away"
out=$("$SALA" lane bedrock sala-test-b 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'no \[example-bedrock\] profile' <<< "$out" && [ -z "$(lane_row sala-test-b)" ] && [ "$(starts "$U2")" = 2 ] && ok "refused, naming the profile; nothing recorded, nothing relaunched" || bad "refusal ($rc): $out / row '$(lane_row sala-test-b)'"
out=$("$SALA" spawn sala-test-d --lane bedrock --cwd "$HOME" 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q "the lane 'bedrock' cannot launch" <<< "$out" && ok "spawn --lane bedrock: refused the same way" || bad "spawn refusal ($rc): $out"
mv "$CRED.away" "$CRED"

[ "$fail" = 0 ] && echo "bedrocklane: pass" || echo "bedrocklane: FAIL"
exit $fail
