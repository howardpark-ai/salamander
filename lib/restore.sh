# lib/restore.sh — recreate a tmux session from its pane-map row and resume its conversation.
#
#   salamander restore NAME… [--dry-run]        the named sessions
#   salamander restore --missing [--dry-run]    every pane-map row whose tmux session does not exist
#
# The pane map is a ledger that keeps a row across a crash, a force-quit, or a reboot that did not
# bring the session back (common.sh, "pane-map ledger"); this verb turns such a row back into a session: the tmux
# session detached at a shell in the row's cwd, then `revive --only NAME`, which resumes the row's conversation by uuid
# (dedupe guard, effort re-pass, inbox hold) — common.sh restore_session. The end of a recycle sweep and the reboot's boot
# half do the same on their own for every frozen row whose session is gone; this is the hand-run form, for an unclean
# boot or a single session. Refused: a name the map does not know (spawn makes a new session, adopt registers a live
# one), a session that exists (revive --only brings its claude back), a conversation that is live elsewhere (never
# resumed twice). Fleet operation: the master's when a Claude session calls it (ops_guard), like revive and retire. A session
# queues it instead: `sala op restore --only NAME --why "<reason>" --from YOU` (lib/op.sh); the queue's runner, a sala-op-<id>
# unit, passes ops_guard like every queued verb, and the queue's plan is this verb's --dry-run.
# --dry-run: nothing is changed; the same refusals as the real run, as "[dry-run] would refuse: …" (exit 1), and for a session
# that can be recreated what the run would do: the tmux session and directory, the conversation, the lane, model and effort the
# revive after it keeps. Read-only, so it passes the guard from a Claude session like every verb's dry run.

usage="usage: salamander restore (NAME… | --missing) [--dry-run]"
[ $# -gt 0 ] || die "$usage"
NAMES=(); MISSING=0; DRY=0; DRYFLAG=""
for a in "$@"; do case "$a" in --missing) MISSING=1;; --dry-run) DRY=1; DRYFLAG=--dry-run;; -h|--help) echo "$usage"; exit 0;; -*) die "unknown option: $a ($usage)";; *) NAMES+=("$a");; esac; done
[ "$MISSING" = 1 ] && [ ${#NAMES[@]} -gt 0 ] && die "--missing takes no names ($usage)"
ops_guard restore "${NAMES[0]:-missing}" $DRYFLAG
no_server="no tmux server running — start it first (systemctl --user start tmux.service; its resurrect restore and revive may bring the sessions back by themselves), then restore what is still missing"
if [ "$DRY" = 1 ]; then
    [ "$MISSING" = 1 ] || [ ${#NAMES[@]} -gt 0 ] || die "$usage"
    tmux has-session 2>/dev/null || { echo "[dry-run] would refuse: $no_server"; echo "[dry-run] nothing was changed"; exit 1; }
    if [ "$MISSING" = 1 ]; then
        mapfile -t NAMES < <(ledger_missing | cut -f1)
        [ ${#NAMES[@]} -gt 0 ] || { echo "[dry-run] nothing missing: every session in the pane map has its tmux session"; exit 0; }
    fi
    refused=0
    for n in "${NAMES[@]}"; do
        restore_check "$n"; rc=$?
        if [ "$rc" != 0 ]; then echo "[dry-run] would refuse: $RS_MSG"; refused=$((refused+1)); continue; fi
        lm=$(model_row "$n"); IFS=$'\t' read -r mdl eff <<< "$lm"
        echo "[dry-run] $n: would create the tmux session '$n' detached in $RS_CWD$RS_NOTE, then revive --only $n resumes conversation $RS_UUID"
        echo "[dry-run] $n: lane $(lane_shown "$(lane_for_session "$n")") · model ${mdl:-from its transcript} · effort ${eff:--}$([ -n "$mdl" ] || echo " (no model row: the transcript decides)")"
    done
    echo "[dry-run] nothing was changed"
    [ "$refused" = 0 ]; exit
fi
tmux has-session 2>/dev/null || die "$no_server"
if [ "$MISSING" = 1 ]; then
    mapfile -t NAMES < <(ledger_missing | cut -f1)
    [ ${#NAMES[@]} -gt 0 ] || { echo "nothing missing: every session in the pane map has its tmux session"; exit 0; }
    echo "${#NAMES[@]} session(s) in the pane map have no tmux session: ${NAMES[*]}"
fi
back=0; fails=0
for n in "${NAMES[@]}"; do
    out=$(restore_session "$n"); rc=$?
    printf '%s\n' "$out" | sed '$d'   # revive's own lines for the pane, if any
    case "$rc" in 0) echo "✅ $(printf '%s\n' "$out" | tail -1)"; back=$((back+1));; 3) echo "ℹ $(printf '%s\n' "$out" | tail -1)";; *) echo "✗ $(printf '%s\n' "$out" | tail -1)"; fails=$((fails+1));; esac
done
[ ${#NAMES[@]} -gt 1 ] && echo "restored $back of ${#NAMES[@]}"
[ "$fails" = 0 ]
