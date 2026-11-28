# lib/forget-row.sh — drop a pane-map row whose tmux session no longer exists.
#
#   salamander forget-row <name> [--dry-run]
#
# One of the three verbs `retire` was split into (see lib/retire.sh). It is what `retire` used to do for a leftover row (a
# throwaway session long gone kept its row, and the retire died at "no tmux session"): with no tmux session there is nothing to /exit, kill or snapshot, and
# the row's conversation id is only the map's word (it can be another row's), so nothing is archived on claude.ai either. The row goes, with its lane and
# model rows, and stackshot is told to drop the agent entry (common.sh, RETIRE DROPS THE AGENT ENTRY: fails soft).
#
# Refused: a name with a live tmux session by that exact name (the message names `retire`, or `close-shell` when the session runs no Claude: forgetting the
# row would leave the live session out of the map), a name with no row and the Remote Control session.
# --dry-run: nothing is written; "[dry-run] would …" lines, refusals as "[dry-run] would refuse: …" (exit 1).

usage="usage: salamander forget-row <name> [--dry-run]
  a live session with a Claude in it: salamander retire <tmux-session>; a live session with none: salamander close-shell <tmux-session>"
name=""; DRY=0; DRYFLAG=""
while [ $# -gt 0 ]; do case "$1" in
    --dry-run) DRY=1; DRYFLAG=--dry-run ;;
    --force) die "forget-row has no --force: it refuses only a name whose tmux session is live" ;;
    -*) die "unknown option: $1
$usage" ;;
    *) [ -z "$name" ] || die "forget-row takes one name: '$name' and '$1' were both given
$usage"; name="$1" ;;
esac; shift; done
[ -n "$name" ] || die "$usage"
dry() { echo "[dry-run] $*"; }
refuse() {
    if [ "$DRY" = 1 ]; then dry "would refuse: $1"; dry "nothing was changed"; exit 1; fi
    die "$1"
}
ops_guard forget-row "$name" $DRYFLAG
ledger_frozen_die forget-row

if tmux has-session -t "=$name" 2>/dev/null; then
    hascl=""
    while read -r pp; do
        [ -n "$pp" ] || continue
        [ -z "$(claude_pid_under "$pp" || true)" ] || { hascl=1; break; }
    done < <(tmux list-panes -s -t "$(tmux_win_t "$name")" -F '#{pane_pid}')
    if [ -n "$hascl" ]; then refuse "tmux session '$name' is live and runs a Claude session: forget-row is only for a row whose session is gone; to end it use: sala retire $name"
    else refuse "tmux session '$name' is live (a shell, no Claude): forget-row is only for a row whose session is gone; to close it use: sala close-shell $name"; fi
fi
[ "$name" = "$SALA_RC_SESSION" ] && refuse "'$name' is the Remote Control server's name — use: salamander rc --stop"
orow=$(ledger_row "$name")
[ -n "$orow" ] || refuse "no pane-map row for '$name' (and no tmux session): nothing to forget"
ouuid=$(cut -f2 <<< "$orow"); retire_project_of "$name" "$ouuid"; proj=$RETIRE_PROJ; psrc=$RETIRE_PROJ_SRC
if [ "$DRY" = 1 ]; then
    dry "'$name': no tmux session — would remove its pane-map row from $SALA_SIDECAR (tab-separated): $(printf '%s' "$orow" | tr '\t' ' ')"
    l=$(lane_row "$name"); m=$(model_row "$name")
    if [ -n "$l" ]; then dry "would drop its lane row ($name → $l) from $SALA_LANES"; else dry "no lane row to drop"; fi
    if [ -n "$m" ]; then dry "would drop its model row ($name → $(printf '%s' "$m" | tr '\t' /)) from $SALA_MODELS"; else dry "no model row to drop"; fi
    if [ -n "$proj" ]; then dry "would tell stackshot to drop '$name' from $proj's agents (client.py post project-agent-retire, label $SALA_RETIRE_SENDER); a failure there changes nothing"
    elif [ -n "${RETIRE_PROJ_BLIND:-}" ] && ! agent_gate_exempt "$name" 0 0 "$(_row_no_role "$name")" >/dev/null; then dry "would WARN, not refuse: stackshot cannot be asked to take '$name' off a project (no project is known for it and $RETIRE_PROJ_BLIND)"; fi
    is_sleeping "$name" && dry "'$name' is sleeping: its marker would be cleared with the row"
    dry "nothing to kill, no /exit, no snapshot, nothing archived on claude.ai (the id is only the map's word)"
    dry "the transcript would stay${ouuid:+: claude --resume $ouuid}"
    dry "nothing was changed"; exit 0
fi
nrole=$(_row_no_role "$name")   # read before the row goes: a retired row no longer answers
ledger_write retire "$name" || die "'$name': no tmux session, and its pane-map row could not be removed (see above)"
[ -z "$ouuid" ] || sleeping_clear "$ouuid"   # a sleeping session's marker goes with its row (common.sh, THE SLEEPING SESSIONS); no marker: nothing to do
lane_drop "$name" || true
model_drop "$name" || true
echo "'$name': no tmux session — its pane-map row removed (nothing killed, no /exit, nothing archived on claude.ai)"
echo "forgot '$name'${ouuid:+; the transcript stays — bring the conversation back with: claude --resume $ouuid}"
retire_drop_agent "$name" "$proj" "${psrc:-}"
if [ -z "$proj" ] && [ -n "${RETIRE_PROJ_BLIND:-}" ] && ! agent_gate_exempt "$name" 0 0 "$nrole" >/dev/null; then   # no project is known AND the record could not answer: say so, as a retire does
    retire_log "$name: WARNING: forgotten although stackshot's project record could not say whether '$name' is on a project ($RETIRE_PROJ_BLIND); its entry, if any, stays on the record"
    echo "⚠ stackshot was NOT asked to take '$name' off a project: no project is known for it and $RETIRE_PROJ_BLIND; if it is a project agent its entry stays on the record until it is taken off (python3 $(stackshot_client 2>/dev/null || echo '<stackshot client.py>') post project-agent-retire <project page key> $name --sender $SALA_RETIRE_SENDER)"
fi
