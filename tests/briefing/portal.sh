#!/usr/bin/env bash
# The digests can run on another login (BRIEFING_CLAUDE_CONFIG_DIR, a second seat) and read
# Gmail through the MCP Portal. Checks what run_claude hands claude (CLAUDE_CONFIG_DIR when set, the caller's own when
# not, never ANTHROPIC_API_KEY or ANTHROPIC_CUSTOM_HEADERS, the portal tools allowed) and that the guard counts a portal
# execute call only when its code calls a Workspace Gmail read (the connector word: demo). A fake `claude`; posting stubbed; offline.
set -u
export BRIEFING_GMAIL_CONNECTOR=demo   # a made-up connector word (config.example): the tools are mcp__claude_ai_Google_Workspace_demo__* and the portal's gdemo_*
ROOT=$(cd "$(dirname "$0")/../.." && pwd); D=$ROOT/contrib/briefing
fail=0; ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fail=1; }
export BRIEFING_BACKEND=cli   # the `claude -p` path under test; the Agent SDK window is tests/briefing/sdk.sh's
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export BRIEFING_LOGDIR="$T/logs"   # unset, lib.sh would migrate the real old ~/.cache directory
mkdir -p "$T/home" "$T/bin" "$T/logs"
cat > "$T/bin/claude" <<'FAKE'
#!/usr/bin/env bash
# fake claude: records its env and argv, prints the stream log in $FAKE_STREAM (if any) and a result line
env > "$FAKE_DIR/env"; printf '%s\n' "$@" > "$FAKE_DIR/argv"
[ -n "${FAKE_STREAM:-}" ] && cat "$FAKE_STREAM"
[ -n "${FAKE_GUARD_LOG:-}" ] && echo "fake: the read guard ran" >> "$FAKE_GUARD_LOG"   # the hook's line
printf '%s\n' '{"type":"result","result":"*digest*\n• a line"}'
FAKE
chmod +x "$T/bin/claude"

# run <stream file or ""> [VAR=value ...]: run_claude in a fresh bash with the given env; prints calls=N and deliver=S
run() {
    local stream=$1; shift
    env -u CLAUDE_CONFIG_DIR -u BRIEFING_CLAUDE_CONFIG_DIR HOME="$T/home" FAKE_DIR="$T" FAKE_STREAM="$stream" FAKE_GUARD_LOG="$T/logs/guard.log" "$@" bash -c '
        . "$1/lib.sh" 2>/dev/null
        LOGDIR=$2/logs CLAUDE_BIN=$2/bin/claude
        POSTS=$2/posts; post_slack() { printf "%s\n" "$1" > "$POSTS"; }
        run_claude portal "a prompt"; echo "calls=$GMAIL_CALLS"
        deliver portal "Morning Email Summary"; echo "deliver=$?"
    ' _ "$D" "$T"
}
KEYS=(ANTHROPIC_API_KEY=btp-dummy-not-a-key ANTHROPIC_CUSTOM_HEADERS=btp-dummy-header)

# the env claude gets
run "" BRIEFING_CLAUDE_CONFIG_DIR=/x/.claude-alt "${KEYS[@]}" >/dev/null
grep -qx 'CLAUDE_CONFIG_DIR=/x/.claude-alt' "$T/env" && ok "BRIEFING_CLAUDE_CONFIG_DIR set: claude gets CLAUDE_CONFIG_DIR" || bad "no CLAUDE_CONFIG_DIR=/x/.claude-alt in claude's env"
grep -q '^ANTHROPIC_API_KEY=\|^ANTHROPIC_CUSTOM_HEADERS=' "$T/env" && bad "claude got a key variable (config dir set)" || ok "config dir set: no ANTHROPIC_API_KEY / ANTHROPIC_CUSTOM_HEADERS"
grep -q 'mcp__mcp-portal__portal_codemode_execute' "$T/argv" && grep -q 'mcp__mcp-portal__portal_codemode_search' "$T/argv" \
    && grep -q 'mcp__claude_ai_Google_Workspace_demo__search_gmail_messages' "$T/argv" \
    && ok "allowedTools: the direct Gmail reads and the two portal tools" || bad "allowedTools: $(cat "$T/argv")"

run "" "${KEYS[@]}" >/dev/null
grep -q '^CLAUDE_CONFIG_DIR=' "$T/env" && bad "unset BRIEFING_CLAUDE_CONFIG_DIR still set CLAUDE_CONFIG_DIR" || ok "unset: no CLAUDE_CONFIG_DIR added"
grep -q '^ANTHROPIC_API_KEY=\|^ANTHROPIC_CUSTOM_HEADERS=' "$T/env" && bad "claude got a key variable (config dir unset)" || ok "unset: no ANTHROPIC_API_KEY / ANTHROPIC_CUSTOM_HEADERS"

run "" CLAUDE_CONFIG_DIR=/caller/own "${KEYS[@]}" >/dev/null
grep -qx 'CLAUDE_CONFIG_DIR=/caller/own' "$T/env" && ok "unset: the caller's own CLAUDE_CONFIG_DIR is kept (today's behaviour)" || bad "caller's CLAUDE_CONFIG_DIR lost"

# the guard on portal calls: stream logs of tool_use blocks
tu() { # tu <tool name> <code>: one assistant line with one tool_use
    python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":sys.argv[1],"input":{"code":sys.argv[2]}}]}},separators=(",",":")))' "$1" "$2"
}
EX=mcp__mcp-portal__portal_codemode_execute
{ tu "$EX" 'async () => await codemode.gdemo_search_gmail_messages({ query: "is:unread" })'
  tu "$EX" 'async () => Promise.all([codemode.gdemo_get_gmail_threads_content_batch({ thread_ids: ["a"] })])'
} > "$T/read.jsonl"
{ tu "$EX" 'async () => await codemode.gdemo_list_gmail_labels({})'
  tu "$EX" 'async () => await codemode.stackshot_brief({})'
  tu mcp__mcp-portal__portal_codemode_search 'async () => (await codemode.tools()).filter(t => t.name === "gdemo_search_gmail_messages")'
} > "$T/noread.jsonl"

rm -f "$T/posts"; out=$(run "$T/read.jsonl" BRIEFING_CLAUDE_CONFIG_DIR=/x)
printf '%s\n' "$out" | grep -qx 'calls=2' && ok "guard: two portal Gmail reads count 2" || bad "portal reads: $out"
printf '%s\n' "$out" | grep -qx 'deliver=0' && grep -q 'a line' "$T/posts" && ok "guard: the digest is posted" || bad "portal reads not posted: $out"

rm -f "$T/posts"; out=$(run "$T/noread.jsonl" BRIEFING_CLAUDE_CONFIG_DIR=/x)
printf '%s\n' "$out" | grep -qx 'calls=0' && ok "guard: portal calls without a Gmail read count 0 (labels, another server, a search)" || bad "portal non-reads: $out"
printf '%s\n' "$out" | grep -qx 'deliver=1' && grep -q 'held back' "$T/posts" && ok "guard: held back when Gmail was never read (the label call also trips the write check below)" || bad "portal non-reads not held back: $out / $(cat "$T/posts" 2>/dev/null)"

# the write check: any gdemo_ tool other than the five reads in an execute call holds the digest back with an alert
{ tu "$EX" 'async () => await codemode.gdemo_search_gmail_messages({ query: "is:unread" })'
  tu "$EX" 'async () => await codemode.gdemo_send_gmail_message({ to: "x@example.com", subject: "s", body: "b" })'
} > "$T/send.jsonl"
rm -f "$T/posts"; out=$(run "$T/send.jsonl" BRIEFING_CLAUDE_CONFIG_DIR=/x)
printf '%s\n' "$out" | grep -qx 'deliver=1' && grep -q 'can write: gdemo_send_gmail_message\.' "$T/posts" && ! grep -q 'a line' "$T/posts" \
    && ok "write check: gdemo_send_gmail_message held back with the alert naming it" || bad "send not held: $out / $(cat "$T/posts" 2>/dev/null)"
{ tu "$EX" 'async () => [await codemode.gdemo_get_gmail_thread_content({ thread_id: "a" }), await codemode.gdemo_create_drive_file({ name: "n" }), await codemode.gdemo_manage_gmail_label({})]'
} > "$T/drive.jsonl"
rm -f "$T/posts"; out=$(run "$T/drive.jsonl" BRIEFING_CLAUDE_CONFIG_DIR=/x)
printf '%s\n' "$out" | grep -qx 'deliver=1' && grep -q 'can write: gdemo_create_drive_file gdemo_manage_gmail_label\.' "$T/posts" \
    && ok "write check: a non-Gmail gdemo_ tool (Drive) and a label tool count too" || bad "drive/label not held: $out / $(cat "$T/posts" 2>/dev/null)"
rm -f "$T/posts"; out=$(run "$T/read.jsonl" BRIEFING_CLAUDE_CONFIG_DIR=/x)
printf '%s\n' "$out" | grep -qx 'deliver=0' && ! grep -q 'can write' "$T/posts" && grep -q 'a line' "$T/posts" \
    && ok "write check: the five reads only, the digest posts" || bad "reads only: $out / $(cat "$T/posts" 2>/dev/null)"
exit $fail
