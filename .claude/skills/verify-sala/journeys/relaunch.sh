# shellcheck shell=bash
# Journey for features/relaunch.md: `sala revive` brings a session back on its own conversation and leaves a typed draft alone.
D=$(uuid 201); S=$(uuid 202); K=$(uuid 203)

start_session vs-test-dead "$D"
sala adopt vs-test-dead
tmux send-keys -t "=vs-test-dead:" /exit Enter
check "its claude ended, a bare shell is left" waitfor "! reg_live '\"sessionId\":\"$D\"'" 40
sala revive --only vs-test-dead --dry-run
check "revive --dry-run exits 0" [ "$RC" = 0 ]
check "revive --dry-run starts nothing" [ "$(starts "$D")" = 1 ]
sala revive --only vs-test-dead
check "revive exits 0" [ "$RC" = 0 ]
check "a claude started again on the same conversation" waitfor "[ \"\$(starts $D)\" = 2 ] && reg_live '\"sessionId\":\"$D\"'" 40

start_session vs-test-stale "$S"
start_session vs-test-draft "$K"
sala adopt vs-test-stale
sala adopt vs-test-draft
new_cli_version 9.9.10
tmux send-keys -t "=vs-test-draft:" -l "half typed"
check "the draft is on the input line" waitfor 'has "$(screen vs-test-draft)" "half typed"' 20

sala revive --only vs-test-draft
check "revive names the unsubmitted draft" has "$OUT" "unsubmitted"
check "the draft's claude was not restarted" [ "$(starts "$K")" = 1 ]
check "the draft's claude is still running" reg_live "\"sessionId\":\"$K\""
check "nothing reached its composer" [ -z "$(typed "$K")" ]
check "the draft is still on the input line" has "$(screen vs-test-draft)" "half typed"

sala revive --only vs-test-stale
check "revive of an idle session behind the launcher exits 0" [ "$RC" = 0 ]
check "it was ended with /exit" has "$(typed "$S")" "/exit"
check "and resumed on the same conversation" waitfor "[ \"\$(starts $S)\" = 2 ] && reg_live '\"sessionId\":\"$S\"'" 40
new_cli_version 9.9.9   # the launcher as the other journeys expect it
