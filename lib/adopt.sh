# lib/adopt.sh — register a live tmux session that was started by hand, outside `spawn`, in the pane map.
#
#   salamander adopt NAME
#
# The pane map is a ledger only honored paths change (common.sh, "pane-map ledger"): a claude
# someone started in a tmux session of their own has no row, so a reboot or recycle could not bring it back, and
# `sala watch` reports it once instead of adding it on its own. adopt is the honored path: the session's live claude
# (its registry row: sessionId, name, cwd) becomes the row, under the tmux session's name. Any other row carrying the
# same conversation (a session renamed by hand with tmux rename-session) is dropped — one conversation lives in one
# pane. Fleet operation: the master's when a Claude session calls it (ops_guard), like rename and retire.

name="${1:-}"; case "$name" in ''|-*) die "usage: salamander adopt NAME";; esac
[ $# -eq 1 ] || die "usage: salamander adopt NAME"
ops_guard adopt "$name"
ledger_frozen_die adopt   # a recycle or reboot holds the pane map
[ "$name" = "$SALA_RC_SESSION" ] && die "'$name' is the Remote Control server — it is never in the pane map"
is_shell_session "$name" && die "'$name' is the web UI's shell, a plain bash and not a Claude session — it is never in the pane map"
tmux has-session -t "=$name" 2>/dev/null || die "no tmux session '$name'"
pane=$(tmux list-panes -t "$(tmux_win_t "$name")" -F '#{pane_id}' | head -1)
cpid=$(claude_pid_under "$(tmux display -p -t "$pane" '#{pane_pid}')") || die "'$name' runs no claude — adopt registers a live session; a session the map has a row for comes back with: salamander restore $name"
is_rc_child "$cpid" && die "'$name' runs a Remote Control served session (--sdk-url), not a pane session"
uuid=$(registry_field "$cpid" sessionId); [ -n "$uuid" ] && [ "$uuid" != null ] || die "no registry entry for '$name' (pid $cpid) — the claude may still be starting; try again in a moment"
label=$(registry_field "$cpid" name); [ -n "$label" ] && [ "$label" != null ] || label="$name"
cwd=$(registry_field "$cpid" cwd); [ -n "$cwd" ] && [ "$cwd" != null ] || cwd=$(proc_cwd "$cpid" 2>/dev/null) || cwd=""
[ -n "$cwd" ] || cwd=$(tmux display -p -t "$pane" '#{pane_current_path}')
have=$(sidecar_uuid_for_session "$name")
if [ "$have" = "$uuid" ]; then echo "'$name' is already in the pane map on conversation $uuid (cwd $(ledger_row "$name" | cut -f4))"; exit 0; fi
ledger_write adopt "$name" "$uuid" "$label" "$cwd" || die "the pane map did not take '$name' (see above)"
echo "✅ adopted '$name': conversation $uuid, session name '$label', cwd $cwd${have:+ (its row named $have before)}"
exit 0
