# lib/restore.sh — recreate a tmux session from its pane-map row and resume its conversation.
#
#   salamander restore NAME…        the named sessions
#   salamander restore --missing    every pane-map row whose tmux session does not exist
#
# The pane map is a ledger that keeps a row across a crash, a force-quit, or a reboot that did not
# bring the session back (common.sh, "pane-map ledger"); this verb turns such a row back into a session: the tmux
# session detached at a shell in the row's cwd, then `revive --only NAME`, which resumes the row's conversation by uuid
# (dedupe guard, effort re-pass, inbox hold) — common.sh restore_session. The end of a recycle sweep and the reboot's boot
# half do the same on their own for every frozen row whose session is gone; this is the hand-run form, for an unclean
# boot or a single session. Refused: a name the map does not know (spawn makes a new session, adopt registers a live
# one), a session that exists (revive --only brings its claude back), a conversation that is live elsewhere (never
# resumed twice). Fleet operation: the master's when a Claude session calls it (ops_guard), like revive and retire.

usage="usage: salamander restore NAME… | --missing"
[ $# -gt 0 ] || die "$usage"
NAMES=(); MISSING=0
for a in "$@"; do case "$a" in --missing) MISSING=1;; -h|--help) echo "$usage"; exit 0;; -*) die "unknown option: $a ($usage)";; *) NAMES+=("$a");; esac; done
[ "$MISSING" = 1 ] && [ ${#NAMES[@]} -gt 0 ] && die "--missing takes no names ($usage)"
ops_guard restore "${NAMES[0]:-missing}"
tmux has-session 2>/dev/null || die "no tmux server running — start it first (systemctl --user start tmux.service; its resurrect restore and revive may bring the sessions back by themselves), then restore what is still missing"
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
