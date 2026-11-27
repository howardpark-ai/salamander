# shellcheck shell=bash
# Journey for features/sessions.md: start a session, list it, adopt one started by hand. Sourced by verify.sh.
U=$(uuid 101); H=$(uuid 102)

sala spawn vs-test-new --cwd "$HOME/work" --dry-run
check "spawn --dry-run exits 0" [ "$RC" = 0 ]
check "spawn --dry-run starts no session" not tmux has-session -t "=vs-test-new"

next_spawn "$U" vs-test-new
sala spawn vs-test-new --cwd "$HOME/work"
check "spawn exits 0" [ "$RC" = 0 ]
check "the tmux session exists" tmux has-session -t "=vs-test-new"
check "a claude registered on the new conversation" reg_live "\"sessionId\":\"$U\""
check "/rename with the session's name reached its composer" has "$(typed "$U")" "/rename vs-test-new"
check "the pane map has its row" has "$(map_row vs-test-new)" "$U"
sala spawn --list
check "spawn --list shows it" has "$OUT" vs-test-new

sala spawn vs-test-new --cwd "$HOME/work"
check "a second spawn of the same name is refused" [ "$RC" != 0 ]
check "and started no second claude" [ "$(starts "$U")" = 1 ]

start_session vs-test-hand "$H"
check "a session started by hand has no pane-map row" [ -z "$(map_row vs-test-hand)" ]
sala adopt vs-test-hand
check "adopt exits 0" [ "$RC" = 0 ]
check "adopt wrote its row on its conversation" has "$(map_row vs-test-hand)" "$H"
sala adopt vs-test-nosuch
check "adopt of a name with no session is refused" [ "$RC" != 0 ]
check "and wrote no row" [ -z "$(map_row vs-test-nosuch)" ]
