# lib/wake.sh — wake sleeping sessions: take the sleeping marker off and resume the conversation in the session's pane, by its id.
#
#   salamander wake NAME… [--dry-run]     the named sessions (exact tmux session names)
#
# A session put to sleep (lib/sleep.sh, common.sh THE SLEEPING SESSIONS) has no claude and keeps its tmux session and pane-map row. A wake clears its
# marker, then resumes the row's conversation exactly as revive and restore do: `revive --only NAME` resumes by the conversation uuid on the session's
# lane, model and effort (the dedupe guard, the inbox hold and the Remote Control re-registration are revive's own). A session whose tmux session is gone
# (a reboot that did not bring it back) is recreated first at its row's directory, as restore does (common.sh restore_session).
# A conversation is never resumed twice: a sleeper whose conversation is live in another pane is left asleep and the refusal says where it runs; one
# whose own pane already runs its claude (started by hand) just loses its marker. A name that is not asleep gets one line and nothing is done (exit 0).
# The marker comes off before the resume: a resume that fails leaves an ordinary bare pane, which the next revive or the watch's heal brings back
# (retrying it is the system's own job, never a second ask) and the line says so.
# Fleet operation: queued like the others, `sala op wake --only NAME… (--item board#N | --why "<reason>") --from YOU` (lib/op.sh); the queue's runner, a
# sala-op-<id> unit, passes ops_guard. Run raw from a Claude session it is refused and points there.
# --dry-run: nothing is changed; the same refusals as the real run, as "[dry-run] would refuse: …" (exit 1), and for a sleeper what the run would do.
# Read-only, so it passes the guard from a Claude session like every verb's dry run.

usage="usage: salamander wake NAME… [--dry-run]
  resumes sleeping sessions by their conversation id; salamander sleep --list names them"
[ $# -gt 0 ] || die "$usage"
NAMES=(); DRY=0; DRYFLAG=""
for a in "$@"; do case "$a" in
    --dry-run) DRY=1; DRYFLAG=--dry-run ;; -h|--help) echo "$usage"; exit 0 ;;
    -*) die "unknown option: $a
$usage" ;;
    *) NAMES+=("$a") ;;
esac; done
[ ${#NAMES[@]} -gt 0 ] || die "$usage"
ops_guard wake "${NAMES[0]}" $DRYFLAG
dry() { echo "[dry-run] $*"; }

# wake_one <name> → 0 awake (or could be) · 3 not asleep: nothing done · 1 refused or failed; its lines on stdout
wake_one() {
    local n="$1" uuid live lpid lsess when t nm e row out why sess_re rc
    if ! is_sleeping "$n"; then
        if [ "$DRY" = 1 ]; then dry "$n: not sleeping, so a wake would do nothing"; else echo "ℹ $n: not sleeping, nothing done"; fi
        return 3
    fi
    sleeping_uuid_r uuid "$n" || uuid=""
    [ -n "$uuid" ] || { echo "✗ $n: its pane-map row has no conversation id"; return 1; }
    when=""; read -r t nm < "$SALA_SLEEP_DIR/$uuid" 2>/dev/null || t=""
    [ -n "$t" ] && when=" since $(e=$(date -u -d "$t" +%s 2>/dev/null) && local_human "$e" || echo "$t")"
    if live=$(live_pane_for_uuid "$uuid"); then
        lpid=${live%% *}; lsess=${live#* }; lsess=${lsess%%:*}
        if [ "$lsess" != "$n" ]; then
            if [ "$DRY" = 1 ]; then dry "would refuse: $n: its conversation is live already (pid $lpid in ${lsess:-another pane}); a conversation is never resumed twice"; else echo "✗ $n: left asleep — its conversation is live already (pid $lpid in ${lsess:-another pane}); a conversation is never resumed twice"; fi
            return 1
        fi
        if [ "$DRY" = 1 ]; then dry "$n: its claude (pid $lpid) already runs in the pane; a wake would only take the marker off"; return 0; fi
        sleeping_clear "$uuid"
        echo "✅ $n: awake — its claude (pid $lpid) was already running; the sleeping marker is off"; return 0
    fi
    if tmux has-session -t "=$n" 2>/dev/null; then
        if [ "$DRY" = 1 ]; then dry "$n: asleep$when; a wake would take its marker off, then revive --only $n resumes conversation $uuid in the pane"; return 0; fi
    else
        row=$(ledger_row "$n")
        if [ "$DRY" = 1 ]; then
            tmux_server_up || { dry "would refuse: $n: no tmux server running — start it first (systemctl --user start tmux.service)"; return 1; }
            [ -n "$row" ] || { dry "would refuse: $n: not in the pane map, nothing to recreate it from"; return 1; }
            dry "$n: asleep$when, its tmux session is gone; a wake would take its marker off, recreate the session at its row's directory and resume conversation $uuid"; return 0
        fi
        tmux_server_up || { echo "✗ $n: no tmux server running — start it first (systemctl --user start tmux.service); left asleep"; return 1; }
    fi
    sleeping_clear "$uuid"
    if ! tmux has-session -t "=$n" 2>/dev/null; then
        out=$(restore_session "$n"); rc=$?
        printf '%s\n' "$out" | sed '$d'
        if [ "$rc" = 0 ]; then echo "✅ $n: awake$when — $(printf '%s\n' "$out" | tail -1)"; return 0; fi
        echo "✗ $n: marker off, not resumed — $(printf '%s\n' "$out" | tail -1); the pane is an ordinary bare pane now, which revive or the watch's heal brings back"; return 1
    fi
    out=$(env -u SALA_RECYCLE -u SALA_SKIP_PANE "$SALA_BIN" revive --only "$n" 2>&1)
    re_escape_r sess_re "$n"; printf '%s\n' "$out" | grep -E "^ *$sess_re:[0-9]+: |^✗|^⚠" | sed 's/^ */      /'
    if printf '%s\n' "$out" | grep -qE "^ *$sess_re:[0-9]+: resumed $uuid"; then echo "✅ $n: awake$when — resumed conversation $uuid"; return 0; fi
    why=$(printf '%s\n' "$out" | grep -E "^ *$sess_re:[0-9]+: " | tail -1 | sed -E "s/^ *$sess_re:[0-9]+: //"); [ -n "$why" ] || why=$(printf '%s\n' "$out" | grep . | tail -1)
    echo "✗ $n: marker off, not resumed — ${why:-no verdict from revive}; the pane is an ordinary bare pane now, which revive or the watch's heal brings back"
    return 1
}
woke=0; none=0; bad=0
for n in "${NAMES[@]}"; do
    wake_one "$n"; rc=$?
    case "$rc" in 0) woke=$((woke + 1)) ;; 3) none=$((none + 1)) ;; *) bad=$((bad + 1)) ;; esac
done
[ "$DRY" = 1 ] && dry "nothing was changed"
[ ${#NAMES[@]} -gt 1 ] && echo "$woke of ${#NAMES[@]} awake$([ "$none" -gt 0 ] && echo ", $none not sleeping")"
[ "$bad" = 0 ]
