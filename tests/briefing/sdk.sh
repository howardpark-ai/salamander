#!/usr/bin/env bash
# The digests and release-watch's relay run through the Agent SDK on the API credit
# (contrib/briefing/sdk_run.py), then `claude -p`. There is no date: the key is used while the
# shared credit record (lib/api_credit.py, $XDG_STATE_HOME/api-credit/state.json) holds no refusal less than 6 h old; a refusal
# makes sdk_run.py write the record and the caller fall back; a working call removes it. Checks the backend choice (no record, a
# fresh refusal, an old one, the 6 h boundary, API_CREDIT_RETRY_S, BRIEFING_BACKEND=cli, no key file), what the runner is handed (no
# key variable, no CLAUDE_CONFIG_DIR, no Bedrock routing, the key file's path, the portal server, the same tools, the prompt on stdin,
# the job's name for the record), the fallback to `claude -p` on "credit balance" and on any other failure (logged to cron.log), a
# write in a failed SDK run still holding the digest back, sdk_run.py's stream-json lines read by the guard and its record writes
# (against a stub SDK), and the relay's SDK-first path. Fake runner and fake `claude`; posting stubbed; offline (no uv, no
# network, no real key); the record lives in a temporary XDG_STATE_HOME.
set -u
# A run on its own from a pane on the api, sdk or a bedrock lane inherits that lane's variables, and "credit rerun argv" below fails on any
# ANTHROPIC_* left in the rerun's environment. tests/briefing.sh unsets the same list for the whole suite; this keeps a direct run equal to it
# (the list is the same as there: keep the two in step). A check that wants one of them sets it itself.
unset ANTHROPIC_API_KEY ANTHROPIC_CUSTOM_HEADERS CLAUDE_CONFIG_DIR \
      ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_BEDROCK_REGION_PREFIX \
      AWS_PROFILE AWS_REGION CLAUDE_EFFORT ANTHROPIC_AUTH_TOKEN
export BRIEFING_GMAIL_CONNECTOR=demo   # a made-up connector word (config.example): the tools are mcp__claude_ai_Google_Workspace_demo__* and the portal's gdemo_*
export SALA_OWNER_NAME=Alex   # release-watch.sh names the owner in the front-agent marker from this setting (default "the owner")
ROOT=$(cd "$(dirname "$0")/../.." && pwd); D=$ROOT/contrib/briefing
fail=0; ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fail=1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
exec 8<"$T"; flock -n 8   # systemd-tmpfiles ageing honours a held flock on the folder's lock file
mkdir -p "$T/home" "$T/bin" "$T/logs" "$T/state"
export XDG_STATE_HOME="$T/xdg"   # the credit record: never the real one
REC=$XDG_STATE_HOME/api-credit/state.json
printf 'sk-test-not-a-key\n' > "$T/key"; printf 'wrkspc_EXAMPLE_test\n' > "$T/ws"
NOW=1800000000   # the tests' clock (BRIEFING_NOW)
rec_at() { mkdir -p "$XDG_STATE_HOME/api-credit"; printf '{"refused_at": %s, "by": "demo", "detail": "Credit balance is too low"}\n' "$1" > "$REC"; }   # a refusal at that epoch
rec_none() { rm -rf "$XDG_STATE_HOME"; }

tu() { # tu <tool name> <code>: one assistant line with one tool_use
    python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":sys.argv[1],"input":{"code":sys.argv[2]}}]}},separators=(",",":")))' "$1" "$2"
}
EX=mcp__mcp-portal__portal_codemode_execute
tu "$EX" 'async () => await codemode.gdemo_search_gmail_messages({ query: "is:unread" })' > "$T/read.jsonl"
tu "$EX" 'async () => await codemode.gdemo_send_gmail_message({ to: "x@example.com" })' > "$T/send.jsonl"

cat > "$T/bin/sdk" <<'FAKE'
#!/usr/bin/env bash
# fake sdk_run.py: records argv, env and stdin; FAKE_SDK picks ok | credit | boom | write | text:<line>
printf '%s\n' "$@" > "$FAKE_DIR/sdk-argv"; pwd > "$FAKE_DIR/sdk-pwd"; env > "$FAKE_DIR/sdk-env"; cat > "$FAKE_DIR/sdk-stdin"
case "$FAKE_SDK" in
  ok)     cat "$FAKE_DIR/read.jsonl"; echo "fake: the read guard ran" >> "$FAKE_DIR/logs/guard.log"; printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"*digest from sdk*"}' ;;
  credit) printf '%s\n' '{"type":"result","subtype":"success","is_error":true,"result":"Credit balance is too low"}'
          echo "sdk_run: error result (success): Credit balance is too low" >&2; exit 1 ;;
  boom)   echo "sdk_run: ProcessError: boom" >&2; exit 1 ;;
  write)  cat "$FAKE_DIR/send.jsonl"; echo "sdk_run: the turn ended without a result" >&2; exit 1 ;;
  text:*) echo "${FAKE_SDK#text:}" ;;
esac
FAKE
cat > "$T/bin/claude" <<'FAKE'
#!/usr/bin/env bash
# fake claude: records its argv; one Workspace connector read and a result; for the relay (-p only) prints FAKE_CLI_TEXT
printf '%s\n' "$@" > "$FAKE_DIR/claude-argv"; pwd > "$FAKE_DIR/claude-pwd"
if [ -n "${FAKE_CLI_TEXT:-}" ]; then echo "$FAKE_CLI_TEXT"; exit 0; fi
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"mcp__claude_ai_Google_Workspace_demo__search_gmail_messages","input":{}}]}}'
printf '%s\n' '{"type":"result","result":"*digest from claude*"}'
FAKE
chmod +x "$T/bin/sdk" "$T/bin/claude"

# run <now> <FAKE_SDK> [VAR=value ...]: run_claude + deliver in a fresh bash; prints backend=, rc=, calls=, deliver=
run() {
    local now=$1 mode=$2; shift 2
    rm -f "$T"/sdk-* "$T"/claude-argv "$T/posts" "$T/logs"/*
    env -u CLAUDE_CONFIG_DIR -u BRIEFING_BACKEND HOME="$T/home" FAKE_DIR="$T" FAKE_SDK="$mode" BRIEFING_NOW="$now" \
        BRIEFING_API_KEY_FILE="$T/key" BRIEFING_API_WORKSPACE_FILE="$T/ws" BRIEFING_SDK_CMD="$T/bin/sdk" \
        BRIEFING_SDK_MCP_CONFIG=/x/api-mcp.json BRIEFING_LOGDIR="$T/logs" \
        ANTHROPIC_API_KEY=dummy-not-a-key ANTHROPIC_CUSTOM_HEADERS=btp-dummy CLAUDE_CONFIG_DIR=/caller/cfg "$@" bash -c '
        . "$1/lib.sh" 2>/dev/null
        CLAUDE_BIN=$2/bin/claude POSTS=$2/posts
        post_slack() { printf "%s\n" "$1" > "$POSTS"; }
        run_claude job "the prompt"; echo "backend=$BACKEND_USED rc=$RC calls=$GMAIL_CALLS"
        deliver job "Morning Email Summary"; echo "deliver=$?"
    ' _ "$D" "$T"
}
has() { printf '%s\n' "$1" | grep -qx -- "$2"; }

# no refusal on record: the SDK, not claude
rec_none
out=$(run "$NOW" ok)
has "$out" 'backend=sdk rc=0 calls=1' && [ ! -e "$T/claude-argv" ] && ok "no refusal on record: the Agent SDK runs, claude does not" || bad "no record: $out"
has "$out" 'deliver=0' && grep -q 'digest from sdk' "$T/posts" && ok "no record: the SDK digest is posted (its portal read counted)" || bad "no record deliver: $out"
grep -q '^ANTHROPIC_API_KEY=\|^ANTHROPIC_CUSTOM_HEADERS=\|^CLAUDE_CONFIG_DIR=' "$T/sdk-env" \
    && bad "the runner inherited a key variable or CLAUDE_CONFIG_DIR" || ok "runner env: no ANTHROPIC_API_KEY / ANTHROPIC_CUSTOM_HEADERS / CLAUDE_CONFIG_DIR from the shell"
a=$(tr '\n' ' ' < "$T/sdk-argv")
case "$a" in *"--model sonnet "*"--allowed-tools mcp__claude_ai_Google_Workspace_demo__search_gmail_messages,"*"mcp__mcp-portal__portal_codemode_execute "*"--mcp-config /x/api-mcp.json --mcp-server mcp-portal --by briefing job --key-file $T/key --workspace-file $T/ws "*)
    ok "runner argv: model, the same tool list, the portal server, the job's name for the credit record, the key and workspace files by path" ;;
  *) bad "runner argv: $a" ;; esac
grep -q 'sk-test-not-a-key' "$T/sdk-argv" && bad "the key's value is on the runner's argv" || ok "runner argv: never the key's value"
[ "$(cat "$T/sdk-stdin")" = "the prompt" ] && ok "runner: the prompt on stdin" || bad "runner stdin: $(cat "$T/sdk-stdin")"

# the lane's routing is not the SDK's: a unit on the bedrock lane (lane exec bedrock) must not send the SDK's CLI to Bedrock
out=$(run "$NOW" ok CLAUDE_CODE_USE_BEDROCK=1 AWS_PROFILE=p AWS_REGION=r ANTHROPIC_BEDROCK_REGION_PREFIX=global ANTHROPIC_DEFAULT_SONNET_MODEL=global.x ANTHROPIC_DEFAULT_HAIKU_MODEL=global.y ANTHROPIC_DEFAULT_OPUS_MODEL=global.z)
has "$out" 'backend=sdk rc=0 calls=1' && ! grep -q '^CLAUDE_CODE_USE_BEDROCK=\|^AWS_PROFILE=\|^AWS_REGION=\|^ANTHROPIC_BEDROCK_REGION_PREFIX=\|^ANTHROPIC_DEFAULT_[A-Z]*_MODEL=' "$T/sdk-env" \
    && ok "runner env: none of the bedrock lane's routing variables (the key is used, not Bedrock)" || bad "runner env kept the lane's routing: $(grep -c '^AWS_\|BEDROCK\|ANTHROPIC_DEFAULT' "$T/sdk-env")"

# a refusal on record: fresh → claude -p without trying the key; old → the key again
rec_at $((NOW - 60))
out=$(run "$NOW" ok)
has "$out" 'backend=cli rc=0 calls=1' && [ ! -e "$T/sdk-argv" ] && [ -e "$T/claude-argv" ] && ok "a refusal 60 s old on record: claude -p, the runner never starts" || bad "fresh refusal: $out"
grep -q 'digest from claude' "$T/posts" && ok "fresh refusal: the claude digest is posted" || bad "fresh refusal posts: $(cat "$T/posts" 2>/dev/null)"
rec_at $((NOW - 21599))
out=$(run "$NOW" ok)
has "$out" 'backend=cli rc=0 calls=1' && [ ! -e "$T/sdk-argv" ] && ok "a refusal one second short of 6 h old: still claude -p" || bad "refusal at 6h-1s: $out"
rec_at $((NOW - 21600))
out=$(run "$NOW" ok)
has "$out" 'backend=sdk rc=0 calls=1' && ok "a refusal exactly 6 h old: the key is tried again" || bad "refusal at 6h: $out"
rec_at $((NOW - 7 * 3600))
out=$(run "$NOW" ok)
has "$out" 'backend=sdk rc=0 calls=1' && ok "a refusal 7 h old: the Agent SDK again" || bad "old refusal: $out"
rec_at $((NOW - 600))
out=$(run "$NOW" ok API_CREDIT_RETRY_S=300)
has "$out" 'backend=sdk rc=0 calls=1' && ok "API_CREDIT_RETRY_S=300: a refusal 10 min old no longer blocks the key" || bad "retry override: $out"
printf 'not json\n' > "$REC"
out=$(run "$NOW" ok)
has "$out" 'backend=sdk rc=0 calls=1' && ok "an unreadable record counts as no refusal" || bad "garbage record: $out"
rec_none
out=$(run "$NOW" ok BRIEFING_BACKEND=cli)
has "$out" 'backend=cli rc=0 calls=1' && [ ! -e "$T/sdk-argv" ] && ok "BRIEFING_BACKEND=cli: claude -p" || bad "forced cli: $out"
out=$(run "$NOW" ok BRIEFING_API_KEY_FILE="$T/no-such-key")
has "$out" 'backend=cli rc=0 calls=1' && [ ! -e "$T/sdk-argv" ] && ok "no key file: claude -p" || bad "no key: $out"

# fallbacks
out=$(run "$NOW" credit)
has "$out" 'backend=cli rc=0 calls=1' && [ -e "$T/sdk-argv" ] && [ -e "$T/claude-argv" ] && ok "\"credit balance\": the same turn reruns on claude -p" || bad "credit: $out"
grep -q 'job: Agent SDK run failed (the API credit is used up); rerunning' "$T/logs/cron.log" 2>/dev/null && ok "credit: cron.log says the credit is used up" || bad "credit log: $(cat "$T/logs/cron.log" 2>/dev/null)"
grep -q 'digest from claude' "$T/posts" && ls "$T/logs"/job.*.sdk.jsonl >/dev/null 2>&1 && ok "credit: claude's digest posted, the SDK log kept as job.<date>.sdk.jsonl" || bad "credit posts/log: $(ls "$T/logs")"
grep -q -- '-p' "$T/claude-argv" && ! grep -q '^ANTHROPIC' "$T/sdk-env" && ok "credit: the rerun is the plain claude -p call" || bad "credit rerun argv"
out=$(run "$NOW" boom)
has "$out" 'backend=cli rc=0 calls=1' && grep -q 'job: Agent SDK run failed (exit 1: sdk_run: ProcessError: boom); rerunning' "$T/logs/cron.log" 2>/dev/null \
    && ok "any other SDK failure: claude -p reruns it, cron.log names the exit and the error" || bad "boom: $out / $(cat "$T/logs/cron.log" 2>/dev/null)"
out=$(run "$NOW" write)
has "$out" 'deliver=1' && grep -q 'can write: gdemo_send_gmail_message\.' "$T/posts" && ! grep -q 'digest from claude' "$T/posts" \
    && ok "a write in the failed SDK run still holds the claude digest back" || bad "write carried over: $out / $(cat "$T/posts" 2>/dev/null)"

# no date gate is left in either file
grep -q 'SDK_UNTIL' "$D/lib.sh" "$D/release-watch.sh" 2>/dev/null && bad "a date gate (SDK_UNTIL) is still named in lib.sh or release-watch.sh" || ok "no SDK_UNTIL date gate in lib.sh or release-watch.sh"
p=$(sed -n 's/^SDK_PIN=\([^ ]*\).*/\1/p' "$D/lib.sh")
grep -q -- "--with $p " "$D/release-watch.sh" && ok "release-watch.sh runs the same SDK pin ($p)" || bad "SDK pin differs: lib.sh '$p'"

# sdk_run.py's records: an SDK message stream converted to stream-json lines the guard and RESULT parser read
python3 -I -B - "$D" > "$T/conv.jsonl" <<'PY' && ok "sdk_run.py record(): converts without the SDK installed" || bad "sdk_run.py record() failed"
import dataclasses, importlib.util, json, sys
spec = importlib.util.spec_from_file_location("sdk_run", sys.argv[1] + "/sdk_run.py"); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
@dataclasses.dataclass
class ToolUseBlock: id: str; name: str; input: dict
@dataclasses.dataclass
class TextBlock: text: str
@dataclasses.dataclass
class AssistantMessage: content: list; model: str = "m"; parent_tool_use_id: object = None; error: object = None; usage: object = None; message_id: object = None; stop_reason: object = None; session_id: object = None; uuid: object = None
@dataclasses.dataclass
class SystemMessage: subtype: str; data: dict
@dataclasses.dataclass
class ResultMessage: subtype: str; is_error: bool; result: str
code = 'async () => await codemode.gdemo_get_gmail_thread_content({ thread_id: "a" })'
for msg in [SystemMessage("init", {"type": "system", "subtype": "init", "tools": []}),
            AssistantMessage([TextBlock("hi"), ToolUseBlock("t1", "mcp__mcp-portal__portal_codemode_execute", {"code": code})]),
            ResultMessage("success", False, "*digest*\nOn host-a (x).\nline")]:
    print(json.dumps(m.record(msg), default=str))
PY
out=$(HOME="$T/home" BRIEFING_LOGDIR="$T/logs" bash -c '. "$1/lib.sh" 2>/dev/null; echo "calls=$(gmail_calls "$2")"' _ "$D" "$T/conv.jsonl")
has "$out" 'calls=1' && ok "sdk_run.py record(): its portal read counts in gmail_calls" || bad "converted stream: $out / $(cat "$T/conv.jsonl")"
python3 -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1])]; assert [x["type"] for x in r]==["system","assistant","result"] and r[2]["result"].startswith("*digest*"), r' "$T/conv.jsonl" \
    && ok "sdk_run.py record(): system / assistant / result types, the result text kept" || bad "converted types: $(cat "$T/conv.jsonl")"

# release-watch.sh relay: the SDK first while the key has credit, claude -p on anything but DONE, only claude -p with a fresh refusal on record
relay() { # relay <now> <FAKE_SDK> [VAR=value ...]: prints the status line
    local now=$1 mode=$2; shift 2
    rm -f "$T"/sdk-* "$T"/claude-argv "$T"/claude-pwd
    env -u BRIEFING_BACKEND HOME="$T/home" FAKE_DIR="$T" FAKE_SDK="$mode" BRIEFING_NOW="$now" FAKE_CLI_TEXT=DONE \
        BRIEFING_API_KEY_FILE="$T/key" BRIEFING_API_WORKSPACE_FILE="$T/ws" BRIEFING_SDK_CMD="$T/bin/sdk" \
        RELEASE_WATCH_STATE="$T/state" RELEASE_WATCH_RELAY_CWD="$T/home" RELEASE_WATCH_CLAUDE_BIN="$T/bin/claude" "$@" \
        sh "$D/release-watch.sh" relay some-session "a message" 2>"$T/relay.err"
}
rec_none
out=$(relay "$NOW" text:DONE)
[ "$out" = "some-session has been told and will report" ] && [ ! -e "$T/claude-argv" ] && ok "relay, no refusal on record: the SDK turn answers DONE, claude -p not run" || bad "relay sdk: $out"
a=$(tr '\n' ' ' < "$T/sdk-argv")
case "$a" in *"--model haiku --allowed-tools SendMessage,ListAgents --output text --by release-watch --key-file $T/key "*) ok "relay runner argv: haiku, SendMessage+ListAgents, text output, the job's name, the key file" ;; *) bad "relay argv: $a" ;; esac
grep -q 'local Claude session named "some-session"' "$T/sdk-stdin" && ok "relay: the prompt on the runner's stdin" || bad "relay stdin: $(cat "$T/sdk-stdin")"
out=$(relay "$NOW" text:ABSENT)
[ "$out" = "some-session has been told and will report" ] && [ -e "$T/claude-argv" ] && grep -q "answered 'ABSENT'" "$T/relay.err" \
    && ok "relay: an SDK answer other than DONE reruns on claude -p (and says so on stderr)" || bad "relay fallback: $out / $(cat "$T/relay.err")"
rec_at $((NOW - 60))
out=$(relay "$NOW" text:DONE)
[ "$out" = "some-session has been told and will report" ] && [ ! -e "$T/sdk-argv" ] && [ -e "$T/claude-argv" ] && ok "relay with a refusal 60 s old on record: only claude -p" || bad "relay fresh refusal: $out"
rec_at $((NOW - 7 * 3600))
out=$(relay "$NOW" text:DONE)
[ ! -e "$T/claude-argv" ] && [ -e "$T/sdk-argv" ] && ok "relay with a refusal 7 h old on record: the SDK turn again" || bad "relay old refusal: $out"
rec_none
out=$(relay "$NOW" text:DONE CLAUDE_CODE_USE_BEDROCK=1 AWS_PROFILE=p ANTHROPIC_DEFAULT_HAIKU_MODEL=global.y)
! grep -q '^CLAUDE_CODE_USE_BEDROCK=\|^AWS_PROFILE=\|^ANTHROPIC_DEFAULT_HAIKU_MODEL=' "$T/sdk-env" && ok "relay runner env: none of the bedrock lane's routing variables" || bad "relay runner env kept the lane's routing"
out=$(relay "$NOW" text:DONE BRIEFING_BACKEND=cli)
[ ! -e "$T/sdk-argv" ] && [ -e "$T/claude-argv" ] && ok "relay with BRIEFING_BACKEND=cli: only claude -p" || bad "relay forced cli: $out"
[ "$(cat "$T/claude-pwd" 2>/dev/null)" = "$T/home" ] && ok "relay: claude -p runs in the relay directory (RELEASE_WATCH_RELAY_CWD; $HOME in production)" || bad "relay cwd: '$(cat "$T/claude-pwd" 2>/dev/null)'"
out=$(relay "$NOW" text:DONE)
[ "$(cat "$T/sdk-pwd" 2>/dev/null)" = "$T/home" ] && ok "relay: the SDK turn runs in the same directory" || bad "relay sdk cwd: '$(cat "$T/sdk-pwd" 2>/dev/null)'"
grep -qF 'RELAY_CWD=${RELEASE_WATCH_RELAY_CWD:-$HOME}' "$D/release-watch.sh" && ok "relay directory defaults to \$HOME, as before" || bad "relay directory default changed"

# release-watch.sh relay to a front agent (*-main): its message must start with the line `[for Alex]`, or SendMessage logs it
# instead of delivering it; any other recipient gets the text unchanged
relay_to() { # relay_to <session> <message>: the SDK turn's prompt lands in $T/sdk-stdin
    rm -f "$T"/sdk-* "$T"/claude-argv
    env -u BRIEFING_BACKEND HOME="$T/home" FAKE_DIR="$T" FAKE_SDK=text:DONE BRIEFING_NOW="$NOW" \
        BRIEFING_API_KEY_FILE="$T/key" BRIEFING_API_WORKSPACE_FILE="$T/ws" BRIEFING_SDK_CMD="$T/bin/sdk" \
        RELEASE_WATCH_STATE="$T/state" RELEASE_WATCH_RELAY_CWD="$T/home" RELEASE_WATCH_CLAUDE_BIN="$T/bin/claude" \
        sh "$D/release-watch.sh" relay "$1" "$2" 2>/dev/null
}
relay_to ops-main "line one
line two" >/dev/null
python3 - "$T/sdk-stdin" <<'PY' && ok "relay to a *-main agent: the message starts with a line [for Alex], the text follows unchanged" || bad "relay -main prompt: $(cat "$T/sdk-stdin")"
import sys
t=open(sys.argv[1],encoding="utf-8").read()
m=t.split('Message: "',1)[1]
assert m.startswith('[for Alex]\nline one\nline two"'), repr(m)
assert 'named "ops-main"' in t
PY
relay_to some-session "line one" >/dev/null
grep -q 'Message: "line one"' "$T/sdk-stdin" && ! grep -q 'for Alex' "$T/sdk-stdin" && ok "relay to any other session: the message is unchanged, no [for Alex] line" || bad "relay non-main prompt: $(cat "$T/sdk-stdin")"
# the main loop: an announced Ubuntu LTS goes to the session RELEASE_WATCH_UBUNTU_SESSION names (a made-up one here), with
# [for Alex] first and the plan's page (RELEASE_WATCH_UBUNTU_PAGE) named; with neither set, the notice is posted and nobody is pinged
mkdir -p "$T/fakepath"
printf '#!/bin/sh\nprintf "Version: 99.04\\nSupported: 1\\n"\n' > "$T/fakepath/curl"
printf '#!/bin/sh\nexit 1\n' > "$T/fakepath/gh"
chmod +x "$T/fakepath/curl" "$T/fakepath/gh"
rwloop() { env -u BRIEFING_BACKEND -u RELEASE_WATCH_UBUNTU_SESSION -u RELEASE_WATCH_UBUNTU_PAGE -u RELEASE_WATCH_CLI_OWNER PATH="$T/fakepath:$PATH" HOME="$T/home" SALA_CONFIG="$T/no-config" FAKE_DIR="$T" FAKE_SDK=text:DONE BRIEFING_NOW="$NOW" \
    BRIEFING_API_KEY_FILE="$T/key" BRIEFING_API_WORKSPACE_FILE="$T/ws" BRIEFING_SDK_CMD="$T/bin/sdk" \
    RELEASE_WATCH_STATE="$T/state2" RELEASE_WATCH_RELAY_CWD="$T/home" RELEASE_WATCH_CLAUDE_BIN=/nonexistent RELEASE_WATCH_SALA=/nonexistent \
    "$@" sh "$D/release-watch.sh" 2>/dev/null; }
rm -rf "$T/state2"; rm -f "$T"/sdk-*
loopout=$(rwloop)
[ ! -e "$T/sdk-stdin" ] && case "$loopout" in *"Ubuntu 99.04 upgrade path is open"*) ! grep -q 'project page' <<< "$loopout";; *) false;; esac \
    && ok "main loop, no setting: the Ubuntu LTS notice is posted, nobody is pinged and no page is named" || bad "ubuntults with no setting: $(cat "$T/sdk-stdin" 2>/dev/null) / $loopout"
rm -rf "$T/state2"; rm -f "$T"/sdk-*
loopout=$(rwloop RELEASE_WATCH_UBUNTU_SESSION=demo-ops-main RELEASE_WATCH_UBUNTU_PAGE=projects/demo-upgrade)
python3 - "$T/sdk-stdin" <<'PY' && ok "main loop: the Ubuntu LTS notice reaches RELEASE_WATCH_UBUNTU_SESSION with [for Alex] on line 1 and the page named" || bad "main loop ubuntults prompt: $(cat "$T/sdk-stdin" 2>/dev/null) / $loopout"
import sys
t=open(sys.argv[1],encoding="utf-8").read()
assert 'named "demo-ops-main"' in t, t
assert 'project page projects/demo-upgrade' in t, t
m=t.split('Message: "',1)[1]
assert m.startswith('[for Alex]\nrelease watcher: new '), repr(m[:80])
PY
rm -rf "$T/state2"; rm -f "$T"/sdk-*
printf 'RELEASE_WATCH_UBUNTU_SESSION=demo-ops-main   # from the config\n' > "$T/rw.config"
rwloop SALA_CONFIG="$T/rw.config" >/dev/null
grep -q 'named "demo-ops-main"' "$T/sdk-stdin" 2>/dev/null && ok "main loop: RELEASE_WATCH_UBUNTU_SESSION from the sala config's line" || bad "ubuntults session from the config: $(cat "$T/sdk-stdin" 2>/dev/null)"

# release-watch.sh cli-owner: the Claude Code CLI's upgrade owner is sala's master; with none, RELEASE_WATCH_CLI_OWNER (the environment, else the
# sala config's line); with that unset too, nobody (empty)
printf '#!/bin/sh\ncase "$FAKE_MASTER" in\n  "") echo "no master: SALA_MASTER is not set in /x/config" ;;\n  *) echo "master      : $FAKE_MASTER"; echo "state       : live" ;;\nesac\n' > "$T/bin/sala"; chmod +x "$T/bin/sala"
owner() { env -u RELEASE_WATCH_CLI_OWNER HOME="$T/home" SALA_CONFIG="$T/no-config" RELEASE_WATCH_STATE="$T/state" RELEASE_WATCH_SALA="$T/bin/sala" "$@" sh "$D/release-watch.sh" cli-owner; }
[ "$(owner FAKE_MASTER=demo-master)" = demo-master ] && ok "cli-owner: the master when sala has one, as before" || bad "cli-owner with a master: $(owner FAKE_MASTER=demo-master)"
[ "$(owner FAKE_MASTER=)" = "" ] && ok "cli-owner: no master and no RELEASE_WATCH_CLI_OWNER → nobody" || bad "cli-owner with no master: '$(owner FAKE_MASTER=)'"
[ "$(owner FAKE_MASTER= RELEASE_WATCH_CLI_OWNER=other-owner)" = other-owner ] && ok "cli-owner: RELEASE_WATCH_CLI_OWNER names another owner" || bad "cli-owner override"
printf 'RELEASE_WATCH_CLI_OWNER=demo-main\n' > "$T/owner.config"
[ "$(owner FAKE_MASTER= SALA_CONFIG="$T/owner.config")" = demo-main ] && ok "cli-owner: RELEASE_WATCH_CLI_OWNER from the sala config's line" || bad "cli-owner from the config: '$(owner FAKE_MASTER= SALA_CONFIG="$T/owner.config")'"
exit $fail
