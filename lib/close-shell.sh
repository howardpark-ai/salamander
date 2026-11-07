# lib/close-shell.sh — close a tmux session whose panes run no Claude: the plain shell a finished job left behind.
#
#   salamander close-shell <tmux-session> [--busy] [--dry-run]
#
# One of the three verbs `retire` was split into (see lib/retire.sh): `retire <tmux-session>` ends a session with a Claude in it, `close-shell` a
# session with none, `forget-row` a pane-map row whose tmux session is gone. The name is the EXACT tmux session name (`tmux list-sessions`), nothing else.
#
# What it does: kills the tmux session, drops its row from the pane map when it has one (the only path that drops a row besides retire and forget-row), drops
# its lane and model rows, and takes a resurrect snapshot so a reboot does not bring the shell back. There is no /exit, no claude.ai session and no stackshot call:
# a session with no Claude has none of them.
#
# Refused, with a sentence that names the verb to use:
#   - a session with a Claude in any pane → `sala retire <name>`
#   - no tmux session by that name → `sala forget-row <name>` when the pane map still has a row, else a plain "no such session"
#   - the master session (the watchdog keeps it alive), the Remote Control session, and the session this command runs in (placed by process ancestry)
#   - a pane whose shell is still running something, unless --busy: the tmux session may hold a job someone is waiting on
# --dry-run: nothing is killed or written; every step is said as "[dry-run] would …", the refusals as "[dry-run] would refuse: …" (exit 1).

usage="usage: salamander close-shell <tmux-session> [--busy] [--dry-run]
  a session with a Claude in it: salamander retire <tmux-session>; a pane-map row whose tmux session is gone: salamander forget-row <name>"
name=""; BUSY=0; DRY=0; DRYFLAG=""; NOTMASTER=""
while [ $# -gt 0 ]; do case "$1" in
    --busy) BUSY=1 ;; --dry-run) DRY=1; DRYFLAG=--dry-run ;; --not-master) NOTMASTER=--not-master ;;
    --force) die "close-shell has no --force: pass --busy to close a shell that is still running something" ;;
    -*) die "unknown option: $1
$usage" ;;
    *) [ -z "$name" ] || die "close-shell takes one session: '$name' and '$1' were both given
$usage"; name="$1" ;;
esac; shift; done
[ -n "$name" ] || die "$usage"
dry() { echo "[dry-run] $*"; }
refuse() {  # <why> → the refusal as the dry run says it, or the real one's die
    if [ "$DRY" = 1 ]; then dry "would refuse: $1"; dry "nothing was changed"; exit 1; fi
    die "$1"
}
ops_guard close-shell "$name" $NOTMASTER $DRYFLAG
ledger_frozen_die close-shell   # a recycle or reboot holds the pane map

if ! tmux has-session -t "=$name" 2>/dev/null; then
    if [ -n "$(ledger_row "$name")" ]; then
        refuse "no tmux session '$name', but the pane map still holds a row for it (a leftover): drop it with: sala forget-row $name"
    fi
    refuse "no tmux session '$name' (close-shell takes the exact name \`tmux list-sessions\` shows, nothing else)"
fi
[ "$name" = "$SALA_RC_SESSION" ] && refuse "'$name' is the Remote Control server — use: salamander rc --stop"
if [ -n "${SALA_MASTER:-}" ] && [ "$name" = "$SALA_MASTER" ]; then
    if [ "$DRY" = 1 ] && [ "${SALA_OP_PLAN:-}" = 1 ]; then dry "'$name' is the master session the watchdog keeps alive: the queue would unset SALA_MASTER first (salamander master --unset), then close it as below"
    else refuse "'$name' is the master session the watchdog keeps alive — the queue does it in one operation (sala op close-shell $name --from <you> --words \"<${SALA_OWNER_NAME}'s words>\": unset SALA_MASTER, then close); by hand, salamander master --unset first if you really mean it"; fi
fi

# every pane of the session: a Claude in any of them is a retire's job; the shell's own children are what --busy is about
panes=0; kids=""; claude_in=""; own=0
while read -r pn pp; do
    [ -n "$pn" ] || continue
    panes=$((panes+1))
    c=$(claude_pid_under "$pp" || true)
    [ -z "$c" ] || claude_in="${claude_in:+$claude_in }$pn"
    is_under "$$" "$pp" && own=1
    k=$(pgrep -P "$pp" 2>/dev/null | head -3 | while read -r kp; do ps -o comm= -p "$kp"; done | paste -sd, -)
    [ -z "$k" ] || kids="${kids:+$kids; }$pn: $k"
done < <(tmux list-panes -s -t "$(tmux_win_t "$name")" -F '#{pane_id} #{pane_pid}')
[ -z "$claude_in" ] || refuse "'$name' runs a Claude session (pane $claude_in): close-shell is for sessions with none; to end it use: sala retire $name"
caller=$(ancestry_session 2>/dev/null || true)
if [ "$own" = 1 ] || { [ -n "$caller" ] && [ "$caller" = "$name" ]; }; then
    refuse "'$name' is the session this command runs in: closing it ends this very call"
fi
if [ -n "$kids" ] && [ "$BUSY" = 0 ]; then
    refuse "'$name' is a shell session still running: $kids — wait, or pass --busy to close it anyway"
fi

if [ "$DRY" = 1 ]; then
    echo "'$name': $panes pane(s), none with a Claude session${kids:+; still running: $kids (--busy)}"
    dry "would kill tmux session '$name'"
    orow=$(ledger_row "$name")
    if [ -n "$orow" ]; then dry "would remove its pane-map row from $SALA_SIDECAR (tab-separated): $(printf '%s' "$orow" | tr '\t' ' ')"
    else dry "no pane-map row to remove (the map does not know '$name')"; fi
    l=$(lane_row "$name"); m=$(model_row "$name")
    if [ -n "$l" ]; then dry "would drop its lane row ($name → $l) from $SALA_LANES"; else dry "no lane row to drop"; fi
    if [ -n "$m" ]; then dry "would drop its model row ($name → $(printf '%s' "$m" | tr '\t' /)) from $SALA_MODELS"; else dry "no model row to drop"; fi
    dry "would take a resurrect snapshot (salamander snapshot --now), so a reboot would not restore the shell"
    dry "nothing was changed"; exit 0
fi
[ -z "$kids" ] || echo "⚠ closing '$name' while it is still running: $kids (--busy)"
echo "'$name': a shell session, no Claude in it"
tmux kill-session -t "=$name" && echo "'$name': tmux session killed"
if [ -n "$(ledger_row "$name")" ]; then
    if ledger_write retire "$name"; then echo "'$name': pane map row removed"
    else echo "⚠ '$name': the pane map row could not be removed (see above) — until it is, a restore would bring the session back"; fi
fi
lane_drop "$name" || true
model_drop "$name" || true
"$SALA_BIN" snapshot --now && echo "'$name': resurrect snapshot taken (a reboot will not restore the shell)"
echo "closed '$name'"
