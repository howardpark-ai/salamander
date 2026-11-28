# lib/wake.sh — wake sleeping sessions: take the sleeping marker off and resume the conversation in the session's pane, by its id.
#
#   salamander wake NAME… [--dry-run]                    the named sessions (exact tmux session names)
#   salamander wake --only NAME --cwd DIR [--dry-run]    one sleeper, moved: resumed in DIR, and DIR written into its pane-map row
# --cwd (common.sh, THE FOLDER OF A RELAUNCH): `revive --only NAME --cwd DIR` makes the relaunch (a tmux session that is gone is created in DIR) and writes
# the row once the claude is up. It takes exactly one --only and no other name. A target that is not relaunched writes nothing, says so and exits 1: a name
# that is not asleep, one whose claude already runs in its pane (the marker comes off), a resume that fails. Without --cwd no wake writes a folder.
#
# A session put to sleep (lib/sleep.sh, common.sh THE SLEEPING SESSIONS) has no claude and keeps its tmux session and pane-map row. A wake clears its
# marker, then resumes the row's conversation exactly as revive and restore do: `revive --only NAME` resumes by the conversation uuid on the session's
# lane, model and effort (the dedupe guard, the inbox hold and the Remote Control re-registration are revive's own). A session whose tmux session is gone
# (a reboot that did not bring it back) is recreated first at its row's directory, as restore does (common.sh restore_session).
# A conversation is never resumed twice: a sleeper whose conversation is live in another pane is left asleep and the refusal says where it runs; one
# whose own pane already runs its claude (started by hand) just loses its marker. A name that is not asleep gets one line and nothing is done (exit 0).
# The wake also writes the wake stamp (common.sh, THE WAKE STAMP): the idle sleep tick never puts the session back to sleep inside SALA_SLEEP_AFTER.
# The marker comes off before the resume: a resume that fails leaves an ordinary bare pane, which the next revive or the watch's heal brings back
# (retrying it is the system's own job, never a second ask) and the line says so.
# Fleet operation: queued like the others, `sala op wake --only NAME… (--item board#N | --why "<reason>") --from YOU` (lib/op.sh; --cwd only with
# --words, never with a reason); the queue's runner, a sala-op-<id> unit, passes ops_guard. Run raw from a Claude session it is refused and points there.
# --dry-run: nothing is changed; the same refusals as the real run, as "[dry-run] would refuse: …" (exit 1), and for a sleeper what the run would do.
# Read-only, so it passes the guard from a Claude session like every verb's dry run.

usage="usage: salamander wake NAME… [--dry-run]
       salamander wake --only NAME --cwd DIR [--dry-run]
  resumes sleeping sessions by their conversation id; salamander sleep --list names them
  --cwd DIR (exactly one --only NAME; an absolute, existing, readable directory): resumed in DIR, and DIR written into the pane-map row, so a later restore starts there"
[ $# -gt 0 ] || die "$usage"
NAMES=(); DRY=0; DRYFLAG=""; CWD=""; ncwd=0; nonly=0; npos=0
while [ $# -gt 0 ]; do case "$1" in
    --dry-run) DRY=1; DRYFLAG=--dry-run ;; -h|--help) echo "$usage"; exit 0 ;;
    --only) [ -n "${2:-}" ] || die "--only needs a tmux session name"; NAMES+=("$2"); nonly=$((nonly + 1)); shift ;;
    --cwd) ncwd=$((ncwd + 1)); CWD=${2:-}; [ $# -lt 2 ] || shift ;;
    -*) die "unknown option: $1
$usage" ;;
    *) NAMES+=("$1"); npos=$((npos + 1)) ;;
esac; shift; done
if [ "$ncwd" -gt 0 ]; then
    [ "$ncwd" = 1 ] || die "--cwd is given once"
    { [ "$nonly" = 1 ] && [ "$npos" = 0 ]; } || die "--cwd moves one session: it needs exactly one --only NAME and no other name"
    relaunch_dir_ok "$CWD" || die "$RD_WHY"
elif [ "$nonly" -gt 0 ]; then die "unknown option: --only (it goes with --cwd; names are given bare)
$usage"
fi
[ ${#NAMES[@]} -gt 0 ] || die "$usage"
ops_guard wake "${NAMES[0]}" $DRYFLAG
dry() { echo "[dry-run] $*"; }

# wake_one <name> → 0 awake (or could be) · 3 not asleep: nothing done · 1 refused or failed; its lines on stdout
wake_one() {
    local n="$1" uuid live lpid lsess when t nm e row out why sess_re rc move="" plan="" cwdarg=()
    if [ -n "$CWD" ]; then cwdarg=(--cwd "$CWD"); move="salamander revive --force --only $n --cwd $(cwd_quote "$CWD")"; fi
    if ! is_sleeping "$n"; then
        if [ -n "$CWD" ]; then
            if [ "$DRY" = 1 ]; then dry "would refuse: $n: not sleeping, so a wake would not relaunch it and the pane map would stay as it is (a running session is moved with: $move)"; else echo "✗ $n: not sleeping, so nothing was relaunched and the pane-map folder is unchanged (a running session is moved with: $move)"; fi
            return 1
        fi
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
            if [ "$DRY" = 1 ]; then dry "would refuse: $n: its conversation is live already (pid $lpid in ${lsess:-another pane}); a conversation is never resumed twice"; else echo "✗ $n: left asleep — its conversation is live already (pid $lpid in ${lsess:-another pane}); a conversation is never resumed twice${CWD:+; pane-map folder unchanged}"; fi
            return 1
        fi
        if [ "$DRY" = 1 ]; then
            [ -z "$CWD" ] || { dry "would refuse: $n: its claude (pid $lpid) already runs in the pane, so a wake would only take the marker off: not relaunched, and the pane map would stay as it is (it is moved with: $move)"; return 1; }
            dry "$n: its claude (pid $lpid) already runs in the pane; a wake would only take the marker off"; return 0
        fi
        sleeping_clear "$uuid"; sleeping_woke_mark "$uuid"
        [ -z "$CWD" ] || { echo "✗ $n: awake — its claude (pid $lpid) was already running and the sleeping marker is off, but it was not relaunched, so the pane-map folder is unchanged (it is moved with: $move)"; return 1; }
        echo "✅ $n: awake — its claude (pid $lpid) was already running; the sleeping marker is off"; return 0
    fi
    if [ -n "$CWD" ]; then   # the row that takes the folder; refused with the marker still on
        row=$(ledger_row "$n")
        [ -n "$row" ] || { echo "$([ "$DRY" = 1 ] && echo "[dry-run] would refuse:" || echo "✗") $n: not in the pane map, so no row can carry the folder; nothing done"; return 1; }
        row=$(cut -f4 <<< "$row"); plan=" · in $CWD · pane-map folder ${row:-none} → $CWD"
    fi
    if tmux has-session -t "=$n" 2>/dev/null; then
        if [ "$DRY" = 1 ]; then dry "$n: asleep$when; a wake would take its marker off, then revive --only $n resumes conversation $uuid in the pane$plan"; return 0; fi
    else
        row=$(ledger_row "$n")
        if [ "$DRY" = 1 ]; then
            tmux_server_up || { dry "would refuse: $n: no tmux server running — start it first (systemctl --user start tmux.service)"; return 1; }
            [ -n "$row" ] || { dry "would refuse: $n: not in the pane map, nothing to recreate it from"; return 1; }
            dry "$n: asleep$when, its tmux session is gone; a wake would take its marker off, recreate the session $([ -n "$CWD" ] && echo "in the new folder" || echo "at its row's directory") and resume conversation $uuid$plan"; return 0
        fi
        tmux_server_up || { echo "✗ $n: no tmux server running — start it first (systemctl --user start tmux.service); left asleep"; return 1; }
    fi
    sleeping_clear "$uuid"; sleeping_woke_mark "$uuid"   # the stamp keeps the idle sleep tick off it for SALA_SLEEP_AFTER (common.sh, THE WAKE STAMP)
    if [ -z "$CWD" ] && ! tmux has-session -t "=$n" 2>/dev/null; then   # with --cwd, revive creates it in that folder
        out=$(restore_session "$n"); rc=$?
        printf '%s\n' "$out" | sed '$d'
        if [ "$rc" = 0 ]; then echo "✅ $n: awake$when — $(printf '%s\n' "$out" | tail -1)"; return 0; fi
        echo "✗ $n: marker off, not resumed — $(printf '%s\n' "$out" | tail -1); the pane is an ordinary bare pane now, which revive or the watch's heal brings back"; return 1
    fi
    out=$(env -u SALA_RECYCLE -u SALA_SKIP_PANE "$SALA_BIN" revive --only "$n" ${cwdarg[@]+"${cwdarg[@]}"} 2>&1); rc=$?
    re_escape_r sess_re "$n"; printf '%s\n' "$out" | grep -E "^ *$sess_re:[0-9]+: |^✗|^⚠" | sed 's/^ */      /'
    if printf '%s\n' "$out" | grep -qE "^ *$sess_re:[0-9]+: resumed $uuid"; then
        if [ -n "$CWD" ] && [ "$rc" != 0 ]; then echo "✗ $n: awake$when — resumed conversation $uuid, but the pane-map folder was not written (the lines above say why)"; return 1; fi
        echo "✅ $n: awake$when — resumed conversation $uuid${CWD:+ in $CWD}"; return 0
    fi
    why=$(printf '%s\n' "$out" | grep -E "^ *$sess_re:[0-9]+: " | tail -1 | sed -E "s/^ *$sess_re:[0-9]+: //"); [ -n "$why" ] || why=$(printf '%s\n' "$out" | grep . | tail -1)
    if [ -n "$CWD" ]; then   # revive or the watch's heal would bring it back with no folder: only the same flag moves it
        echo "✗ $n: marker off, not resumed — ${why:-no verdict from revive}; the pane-map folder is unchanged: once that is fixed, salamander revive --only $n --cwd $(cwd_quote "$CWD")"
        return 1
    fi
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
