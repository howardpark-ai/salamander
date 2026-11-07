#!/usr/bin/env bash
# The PermissionRequest hook (lib/permissions.py, lib/hook.sh `permission-request`, docs/permission-hook.md).
# Auto-approve comes first and the dialog is the fallback. The hook approves a permission prompt at once (it prints the
# one allow line) and leaves the dialog alone (prints nothing, exit 0) for what must stay a person's. Payloads are fed to the real
# verb, `salamander hook permission-request`, as the CLI sends them (tool_name, tool_input, permission_mode, session_id, cwd).
#  1. APPROVED: Bash ls, Read, Edit of an ordinary repo file, WebFetch, an MCP tool, a Bash command that merely says "token" or
#     "hooks" in prose, a ~ inside the home that is no rule, an Edit whose CONTENT mentions CLAUDE.md (the content is the work).
#     Each prints one line that parses as JSON with decision.behavior allow, exit 0.
#  2. LEFT: AskUserQuestion, ExitPlanMode, a tool that asks (name), Edit of ~/.claude/settings.json, a repo's
#     .claude/settings.local.json, ~/.claude.json, Write of CLAUDE.md, .mcp.json, a hooks directory, a hook
#     script wired in the settings, `cat ~/.ssh/id_ed25519`, .aws, .env, a token file, `..` traversal into settings (a path and a
#     command), $HOME and a symlink to settings, quotes inside a path, an MCP input that mentions settings, plan mode, garbage
#     stdin, empty stdin, a payload with no tool_name, SALA_PERMISSION_APPROVE=off. Exit 0 and stdout empty every time.
#  3. THE LOG: one line per decision (allowed or left, tool, why, session, 80 chars of the input), a secret masked, trimmed past 512 KB.
# Isolated HOME. Usage: bash tests/permissions.sh   (exit 0 = pass; a few seconds)
set -u
unset SALA_PERMISSION_APPROVE SALA_PERMISSION_LOG SALA_SESSION_ID SALA_RC_NAME
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_LOG_DIR="$HOME/.claude"
mkdir -p "$HOME/.claude" "$HOME/repo/lib"
trap 'rm -rf "${HOME:?}" 2>/dev/null' EXIT
SALA="$ROOT/bin/salamander"; LOG="$HOME/.claude/salamander-permission.log"
CASES=0

# run <payload>: → OUT (stdout), RC; one more case for the log count
run() { OUT=$(printf '%s' "$1" | "$SALA" hook permission-request 2>/dev/null); RC=$?; CASES=$((CASES + 1)); }
# mk <tool> <input json> [mode] [extra json members] → a payload
mk() { printf '{"session_id":"abcdef12-0000-4000-8000-000000000001","cwd":"%s/repo","hook_event_name":"PermissionRequest","tool_name":"%s","tool_input":%s,"permission_mode":"%s"%s}' "$HOME" "$1" "$2" "${3:-default}" "${4:-}"; }
allowed() {  # <label> <payload>
    run "$2"
    if [ "$RC" = 0 ] && python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d=={"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}' "$OUT" 2>/dev/null
    then ok "approved: $1"; else bad "$1: wanted the allow line, got rc=$RC out='$OUT'"; fi
}
left() {  # <label> <payload> [reason text the log must hold]
    run "$2"
    if [ "$RC" = 0 ] && [ -z "$OUT" ]; then
        if [ -n "${3:-}" ] && ! has "$(slurp "$LOG" | tail -n 1)" "$3"; then bad "$1: left, but the log line lacks '$3': $(slurp "$LOG" | tail -n 1)"; else ok "left: $1"; fi
    else bad "$1: wanted silence and exit 0, got rc=$RC out='$OUT'"; fi
}

echo "== approved: everything not in the table"
allowed "Bash ls"                       "$(mk Bash '{"command":"ls -la","description":"list"}')"
allowed "Read"                          "$(mk Read '{"file_path":"/home/alex/salamander/lib/hook.sh"}')"
allowed "Edit of an ordinary repo file" "$(mk Edit "{\"file_path\":\"$HOME/repo/lib/foo.py\",\"old_string\":\"a\",\"new_string\":\"b\"}")"
allowed "relative path under the cwd"   "$(mk Write '{"file_path":"lib/new.py","content":"x"}')"
allowed "WebFetch"                      "$(mk WebFetch '{"url":"https://example.com/a","prompt":"summarise"}')"
allowed "an MCP tool"                   "$(mk mcp__notes__search '{"query":"sala permission hook","limit":5}')"
allowed "acceptEdits mode"              "$(mk Bash '{"command":"git status"}' acceptEdits)"
allowed "an Edit whose content names CLAUDE.md (the content is the work, the target is a plain file)" \
    "$(mk Edit "{\"file_path\":\"$HOME/repo/notes.txt\",\"old_string\":\"x\",\"new_string\":\"see CLAUDE.md and settings.json\"}")"
allowed "an Agent prompt that names a settings file (prose)" "$(mk Agent '{"prompt":"read ~/.claude/settings.json and report"}')"
allowed "Bash that says tokenizer or the word hook, no file"  "$(mk Bash '{"command":"python3 -m tokenizer --help; echo a hook is a hook"}')"
allowed "Grep for a word, a path in the repo"  "$(mk Grep '{"pattern":"token","path":"/home/alex/repo/lib"}')"
allowed "Bash: a hostname with .aws in it"     "$(mk Bash '{"command":"curl -s https://x.aws.example.com/ok"}')"

echo "== left: a question to a person"
left "AskUserQuestion"   "$(mk AskUserQuestion '{"questions":[{"question":"Which?","options":[{"label":"a"}]}]}')" "asks a person"
left "ExitPlanMode"      "$(mk ExitPlanMode '{"plan":"do things"}')" "asks a person"
left "a tool that asks (MCP, by name)" "$(mk mcp__x__ask_user '{"q":"ok?"}')" "asks a person"

echo "== left: the permission and instruction surface"
left "Edit of ~/.claude/settings.json"        "$(mk Edit "{\"file_path\":\"$HOME/.claude/settings.json\",\"old_string\":\"a\",\"new_string\":\"b\"}")" "surface"
left "Edit of ~ form of settings.json"        "$(mk Edit '{"file_path":"~/.claude/settings.json","old_string":"a","new_string":"b"}')" "surface"
left "Write of a repo .claude/settings.local.json" "$(mk Write "{\"file_path\":\"$HOME/repo/.claude/settings.local.json\",\"content\":\"{}\"}")" "surface"
left "Edit of ~/.claude.json"                 "$(mk Edit '{"file_path":"~/.claude.json","old_string":"a","new_string":"b"}')" "surface"
left "Write CLAUDE.md"                        "$(mk Write "{\"file_path\":\"$HOME/repo/CLAUDE.md\",\"content\":\"x\"}")" "CLAUDE.md"
left "Write .mcp.json"                        "$(mk Write "{\"file_path\":\"$HOME/repo/.mcp.json\",\"content\":\"{}\"}")" ".mcp.json"
left "Write into a hooks directory"           "$(mk Write "{\"file_path\":\"$HOME/.claude/hooks/new.sh\",\"content\":\"x\"}")" "hooks directory"
left "NotebookEdit of a CLAUDE.md-named path" "$(mk NotebookEdit "{\"notebook_path\":\"$HOME/repo/CLAUDE.md\",\"new_source\":\"x\"}")" "CLAUDE.md"
left "Bash: sed -i on settings.json"          "$(mk Bash '{"command":"sed -i s/a/b/ ~/.claude/settings.json"}')" "settings"
left "Bash: echo >> CLAUDE.md"                "$(mk Bash '{"command":"echo hi >> CLAUDE.md"}')" "CLAUDE.md"
left "Bash: managed-settings"                 "$(mk Bash '{"command":"cat /etc/claude-code/managed-settings.json"}')" "managed settings"
left "Bash: bare settings.json after cd"      "$(mk Bash '{"command":"cd ~/.claude && cat settings.json"}')" "settings"
left ".. traversal into settings (path)"      "$(mk Edit "{\"file_path\":\"$HOME/repo/lib/../../.claude/settings.json\",\"old_string\":\"a\",\"new_string\":\"b\"}")" "surface"
left ".. traversal, relative to the cwd"      "$(mk Write '{"file_path":"../.claude/settings.json","content":"{}"}')" "surface"
left ".. traversal in a command"              "$(mk Bash "{\"command\":\"cat $HOME/repo/lib/../../.claude/settings.json\"}")" "surface"
left "\$HOME form in a command"               "$(mk Bash '{"command":"cat $HOME/.claude/settings.json"}')" "surface"
left "quotes inside the path"                 "$(mk Bash '{"command":"cat ~/.claude/set\"tings\".json"}')" "surface"
left "an MCP input that mentions settings.json" "$(mk mcp__fs__write '{"target":"~/.claude/settings.json","text":"x"}')" "surface"
ln -s "$HOME/.claude/settings.json" "$HOME/repo/innocent.txt"
left "a symlink to settings.json (realpath)"  "$(mk Edit "{\"file_path\":\"$HOME/repo/innocent.txt\",\"old_string\":\"a\",\"new_string\":\"b\"}")" "surface"

echo "== left: a hook script wired in the settings"
cat > "$HOME/.claude/settings.json" <<EOF
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"python3 $HOME/scripts/gate.py --strict"}]}]}}
EOF
left "Edit of the wired script"               "$(mk Edit "{\"file_path\":\"$HOME/scripts/gate.py\",\"old_string\":\"a\",\"new_string\":\"b\"}")" "wired"
allowed "Edit of a script that is not wired"  "$(mk Edit "{\"file_path\":\"$HOME/scripts/other.py\",\"old_string\":\"a\",\"new_string\":\"b\"}")"
allowed "Read of the wired script (only a write is a change)" "$(mk Read "{\"file_path\":\"$HOME/scripts/gate.py\"}")"

echo "== left: credentials"
left "Bash: cat ~/.ssh/id_ed25519"            "$(mk Bash '{"command":"cat ~/.ssh/id_ed25519"}')" "credentials"
left "Read ~/.aws/credentials"                "$(mk Read '{"file_path":"~/.aws/credentials"}')" "credentials"
left "Read ~/.gnupg"                          "$(mk Read "{\"file_path\":\"$HOME/.gnupg/pubring.kbx\"}")" "credentials"
left "Read ~/.api-token"                      "$(mk Read '{"file_path":"~/.api-token"}')" "credentials"
left "Bash: source .env"                      "$(mk Bash '{"command":"set -a; . ./.env; set +a"}')" "credentials"
left "Write .env.local"                       "$(mk Write "{\"file_path\":\"$HOME/repo/.env.local\",\"content\":\"A=1\"}")" "credentials"
left "Read api-token.json"                    "$(mk Read '{"file_path":"/srv/app/api-token.json"}')" "credentials"
left "Read a .pem"                            "$(mk Read '{"file_path":"/srv/app/server.pem"}')" "credentials"
left "Bash: stackshot token file"             "$(mk Bash '{"command":"cat /home/alex/stackshot/stackshot-token.txt"}')" "credentials"
left "an MCP input naming ~/.ssh"             "$(mk mcp__fs__read '{"path":"~/.ssh/config"}')" "credentials"

echo "== left: the mode and the input"
left "plan mode"                              "$(mk Bash '{"command":"ls"}' plan)" "permission mode plan"
left "garbage stdin"                          "this is not json {" "not a JSON object"
left "a JSON list"                            "[1,2]" "not a JSON object"
left "empty stdin"                            "" "empty input"
left "no tool_name"                           '{"session_id":"abcdef12","tool_input":{"command":"ls"}}' "no tool_name"
left "tool_name not a string"                 '{"tool_name":7,"tool_input":{}}' "no tool_name"
SALA_PERMISSION_APPROVE=off; export SALA_PERMISSION_APPROVE
left "SALA_PERMISSION_APPROVE=off"            "$(mk Bash '{"command":"ls"}')" "SALA_PERMISSION_APPROVE=off"
for v in 0 no false OFF; do SALA_PERMISSION_APPROVE=$v; left "SALA_PERMISSION_APPROVE=$v" "$(mk Read '{"file_path":"/x"}')"; done
unset SALA_PERMISSION_APPROVE
allowed "back on once the switch is unset"    "$(mk Read '{"file_path":"/x"}')"
SALA_PERMISSION_APPROVE=on allowed "SALA_PERMISSION_APPROVE=on" "$(mk Read '{"file_path":"/x"}')"

echo "== the verb itself"
out=$("$SALA" hook permission-request < /dev/null 2>&1); rc=$?
[ "$rc" = 0 ] && ok "closed stdin (/dev/null): exit 0" || bad "closed stdin: rc=$rc out=$out"

echo "== the log"
n=0; while IFS= read -r _; do n=$((n + 1)); done < "$LOG"
# the 4 runs above that are not payload cases: /dev/null stdin (1) is logged as an empty input; SALA_PERMISSION_APPROVE=on case counts in CASES
[ "$n" = $((CASES + 1)) ] && ok "one line per decision ($n lines for $CASES payloads and the /dev/null run)" || bad "log has $n lines, wanted $((CASES + 1))"
L=$(slurp "$LOG")
hasl() { local l; while IFS= read -r l || [ -n "$l" ]; do [[ $l =~ $1 ]] && return 0; done <<< "$L"; return 1; }
hasl '^\[[0-9T:+-]+\] allowed tool=Bash why=no rule matched session=abcdef12 agent=- input=ls -la$' && ok "an allowed line: time, tool, why, the session's first 8 characters, the input" || bad "no allowed Bash line: $(echo "$L" | head -n 2)"
hasl '^\[[^]]+\] left tool=AskUserQuestion why=asks a person ' && ok "a left line names the tool and the reason" || bad "no AskUserQuestion line"
hasl 'left tool=- why=empty input ' && hasl 'left tool=- why=input is not a JSON object ' && ok "empty and garbage input are logged too" || bad "empty / garbage lines missing"
SALA_SESSION_ID=example-test; export SALA_SESSION_ID
run "$(mk Bash '{"command":"echo ok"}' default ',"agent_type":"worker-1"')"
L=$(slurp "$LOG"); [[ $L == *"agent=worker-1"* ]] && ok "the payload's agent_type names the agent" || bad "agent_type not logged"
run "$(mk Bash '{"command":"echo ok"}')"
L=$(slurp "$LOG"); [[ $L == *"agent=example-test"* ]] && ok "SALA_SESSION_ID names the agent when the payload has none" || bad "SALA_SESSION_ID not logged"
unset SALA_SESSION_ID
run "$(mk Bash '{"command":"curl -H \"Authorization: Bearer abcdefghijklmnop12345\" https://example.com/x?token=hunter2hunter2 --data '"$(printf 'y%.0s' $(seq 1 200))"'"}')"
L=$(slurp "$LOG"); last=${L##*$'\n'}; [ -n "$last" ] || { L=${L%$'\n'}; last=${L##*$'\n'}; }
[[ $last != *hunter2* ]] && [[ $last != *abcdefghijklmnop12345* ]] && ok "a token or bearer value in the command never reaches the log" || bad "secret in the log: $last"
inp=${last#*input=}; [ "${#inp}" -le 82 ] && ok "the input is cut to 80 characters (${#inp} with the ellipsis)" || bad "input is ${#inp} characters"
run "$(mk Read '{"file_path":"/a/b\nc"}')"
L=$(slurp "$LOG"); nl=0; while IFS= read -r _; do nl=$((nl + 1)); done <<< "${L%$'\n'}"; [ "$nl" = "$(( CASES + 1 ))" ] && ok "an input with a newline stays on one line" || bad "newline split a log line ($nl lines)"

echo "== the log is trimmed past 512 KB"
big=""; for i in $(seq 1 100); do big+="old line $i padding padding padding padding padding padding padding padding padding padding padding padding padding"$'\n'; done
: > "$LOG"; for i in $(seq 1 60); do printf '%s' "$big" >> "$LOG"; done
run "$(mk Read '{"file_path":"/x"}')"
sz=$(stat -c %s "$LOG"); nl=0; while IFS= read -r _; do nl=$((nl + 1)); done < "$LOG"
[ "$nl" -le 2000 ] && [ "$sz" -lt 524288 ] && [[ $(slurp "$LOG") == *"allowed tool=Read"* ]] && ok "cut to the last 2000 lines, the new line kept ($nl lines, $sz bytes)" || bad "not trimmed: $nl lines, $sz bytes"

echo "== no tty: the verb says what it reads, exit 2 (as the other hook verbs)"
if command -v script >/dev/null 2>&1; then
    t=$(script -qec "$SALA hook permission-request" /dev/null 2>&1 < /dev/null); rc=$?
    [ "$rc" = 2 ] && [[ $t == *"reads the PermissionRequest hook input on stdin"* ]] && ok "run from a terminal: usage on stderr, exit 2" || bad "tty run: rc=$rc out=$t"
else ok "(script not installed: the tty guard is not exercised here)"; fi

[ "$fail" = 0 ] && echo "permissions: pass" || echo "permissions: FAIL"
exit "$fail"
