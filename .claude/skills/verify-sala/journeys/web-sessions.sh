# shellcheck shell=bash
# needs: web
# Journey for features/web-sessions.md: the web app lists a running session and shows its conversation. Sourced by verify.sh.
W=$(uuid 301)

start_session vs-test-web "$W"
PID=$(claude_pid vs-test-web)
mkdir -p "$HOME/.claude/projects/x"
printf '%s\n' \
    '{"type":"user","uuid":"u-1","timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":[{"type":"text","text":"did the build pass?"}]}}' \
    '{"type":"assistant","uuid":"a-1","timestamp":"2026-01-01T00:00:05.000Z","message":{"role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"the build passed"}]}}' \
    > "$HOME/.claude/projects/x/$W.jsonl"

web GET /api/sessions
check "the session list answers 200" [ "$CODE" = 200 ]
check "it lists the session once, with its pid and conversation" json --arg w "$W" --argjson p "${PID:-0}" \
    '[.scopes[].groups[].sessions[] | select(.name == "vs-test-web" and .sessionId == $w and .pid == $p)] | length == 1'

web GET "/api/s/$PID/transcript"
check "its transcript answers 200" [ "$CODE" = 200 ]
check "with the question and the answer, in order" json \
    '(tostring | index("did the build pass?")) as $q | (tostring | index("the build passed")) as $a | $q != null and $a != null and $q < $a'

web GET /api/s/999999999/transcript
check "a pid with no session is 404" [ "$CODE" = 404 ]

web GET /
check "the page itself is served" [ "$CODE" = 200 -a "$(grep -ci '<html' <<< "$BODY")" != 0 ]

tmux send-keys -t "=vs-test-web:" /exit Enter
check "its claude ended" waitfor "! reg_live '\"sessionId\":\"$W\"'" 40
web GET /api/sessions
check "the ended session is no longer listed" json '[.scopes[].groups[].sessions[] | select(.name == "vs-test-web")] | length == 0'
