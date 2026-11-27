# shellcheck shell=bash
# needs: web
# Journey for features/web-send.md: a message posted to the web app reaches the session's pane, and the refusals type nothing.
M=$(uuid 302)

start_session vs-test-send "$M"
PID=$(claude_pid vs-test-send)

web POST "/api/s/$PID/send" '{"text":"from another site"}' application/json http://elsewhere.example
check "a cross-origin post is 403" [ "$CODE" = 403 ]
web POST "/api/s/$PID/send" '{"text":"not json by type"}' text/plain
check "a post that is not application/json is 415" [ "$CODE" = 415 ]
check "neither reached the composer" [ -z "$(typed "$M")" ]

web POST "/api/s/$PID/send" '{"text":"hello from verify"}'
check "a message is 200 and ok" json '.ok == true'
check "it reached the composer" waitfor 'has "$(typed '"$M"')" "hello from verify"' 20
web POST "/api/s/$PID/send" '{"text":"hello from verify"}'
check "the same message again at once is 409, a duplicate" json '.duplicate == true'
check "the composer got it once, and nothing else" [ "$(typed "$M")" = "hello from verify" ]

tmux send-keys -t "=vs-test-send:" -l "half typed"
check "a draft is on the input line" waitfor 'has "$(screen vs-test-send)" "half typed"' 20
web POST "/api/s/$PID/send" '{"text":"second message"}'
check "a post over a draft is 409" [ "$CODE" = 409 ]
check "the answer carries the draft's text" json '.boxText | contains("half typed")'
check "the composer got nothing more" [ "$(typed "$M")" = "hello from verify" ]
check "the draft is still on the input line" has "$(screen vs-test-send)" "half typed"

web POST /api/s/999999999/send '{"text":"nobody"}'
check "a pid with no session is 404" [ "$CODE" = 404 ]
