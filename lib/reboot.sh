# lib/reboot.sh — take this box down cleanly and bring it back in order (built before the 26.04
# upgrade; the clean-reboot protocol brief in the ops repo; participant contract docs/reboot-contract.md).
#
#   salamander reboot --dry-run       steps 1–4, then start + resume everything (the acceptance test; no reboot)
#   salamander reboot --go            steps 1–4, then the reboot as the master's last act — only on the owner's word
#   salamander reboot --status        every hook's status
#   salamander reboot --resume        un-stick a half-done run: start + resume every hook from the recorded pause time
#   salamander reboot --after-boot    (internal) the boot half, launched by `watch` when a reboot marker is present
#
# The sequence: 1 pause inbound (hooks' `pause --at T`) · 2 drain every pane but the master and this one, snapshot,
# record each pane's conversation + claude.ai id · 3/4 flush-stop each hook in SALA_REBOOT_HOOKS order and verify it is
# stopped, final heartbeat · 5 dry run: start + resume; real: marker, then reboot. Any failure halts with no reboot and
# rolls back (start + resume what was stopped/paused).
# At boot: revive done → the pane map's frozen roster against tmux (every session not back is recreated and resumed),
# the freeze lifted → each pane's claude.ai id checked against the snapshot (re-bridged with /remote-control
# where needed) → every hook polled together, each resumed (--since T --sessions <verified>) the moment it is up → the
# result lines go into the one post-boot report `watch` hands the master; a hook not up by then is reported and kept on watch.

: "${SALA_REBOOT_HOOKS:=}"            # name=path … in stop order (see docs/reboot-contract.md)
: "${SALA_REBOOT_DRAIN_WAIT:=900}"    # seconds to wait for the other panes to go idle before halting
: "${SALA_REBOOT_BOOT_WAIT:=300}"     # seconds after boot before a hook that is not up is reported to the master
: "${SALA_REBOOT_BOOT_GIVEUP:=1800}"  # seconds after boot the boot half keeps watching a reported hook, to resume it itself
: "${SALA_REBOOT_SHELL_GRACE:=120}"   # a pane idle but for a background shell counts as drained after this long
CUT=(); DRAFTS_SEEN=()
RSTATE="$SALA_LOG_DIR/salamander-reboot.state"; RMARK="$SALA_LOG_DIR/salamander-reboot.marker"
RPANES="$SALA_LOG_DIR/salamander-reboot-panes.tsv"; RLOG="$SALA_LOG_DIR/salamander-reboot.log"
RRESULT="$SALA_LOG_DIR/salamander-reboot.result"
mkdir -p "$SALA_LOG_DIR"
# hooks get the user's tool dirs whatever launched us: the boot half runs as a systemd --user unit with systemd's bare
# PATH, where a `#!/usr/bin/env bun` hook died with "env: 'bun': No such file or directory" (one boot: a
# writer looked unhealthy for minutes, while the same hook passed from every pane)
for d in "$HOME/.bun/bin" "$HOME/.cargo/bin" "$HOME/bin" "$HOME/.local/bin"; do
    [ -d "$d" ] && case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH";; esac
done; export PATH
rlog() { echo "[$(date -Is)] $*" >> "$RLOG"; }
say() { echo "$*"; rlog "$*"; REPORT+=("$*"); }
REPORT=()
# tell_master <headline> [bullet…] — straight into the master's inbox (the post-boot report's path); Slack when that
# fails, in the shared notice shape (sala_post)
tell_master() {
    local mp cpid sock text="[sala reboot] $1" b; shift
    for b in "$@"; do [ -n "$b" ] && text="$text"$'\n'"- $b"; done
    mp=$(tmux list-panes -t "$(tmux_win_t "${SALA_MASTER:-}")" -F '#{pane_id}' 2>/dev/null | head -1)
    [ -n "$mp" ] && cpid=$(claude_pid_under "$(tmux display -p -t "$mp" '#{pane_pid}')" 2>/dev/null) && sock=$(session_socket "$cpid") \
        && session_push "$sock" "$text" && { rlog "told the master: ${text%%$'\n'*}"; return 0; }
    sala_post "$(printf '%s' "$text" | head -1 | sed 's/^\[sala reboot\] //')" "$@"; rlog "master unreachable — sent to Slack: ${text%%$'\n'*}"
}

NAMES=(); PATHS=()
for e in $SALA_REBOOT_HOOKS; do NAMES+=("${e%%=*}"); PATHS+=("${e#*=}"); done
hook() {  # <index> <verb> <budget> [args…] → rc; HOOK_LINE = last stdout line
    local i="$1" verb="$2" budget="$3"; shift 3
    local p="${PATHS[$i]/#\~/$HOME}" out rc
    out=$(timeout "$budget" "$p" "$verb" "$@" 2>&1); rc=$?
    { echo "--- ${NAMES[$i]} $verb $* (rc $rc)"; printf '%s\n' "$out"; } >> "$RLOG"
    HOOK_LINE=$(printf '%s\n' "$out" | grep -v '^\s*$' | tail -1 | cut -c1-160)
    [ "$rc" = 124 ] && HOOK_LINE="timed out after ${budget}s"
    return "$rc"
}
st_put() { _kv_set "$RSTATE" "$1" "$2"; }
st_val() { _kv_first "$RSTATE" "$1"; }

# claude panes → "pane|session|pid|uuid|bridge" (uuid with --uuid or --bridge; bridge only with --bridge: it scans
# transcripts, too slow for a poll loop)
claude_panes() {
    local pane sess ppid cpid uuid br want="${1:-}"
    tmux list-panes -a -F '#{pane_id}|#{session_name}|#{pane_pid}' 2>/dev/null | while IFS='|' read -r pane sess ppid; do
        [ "$sess" = "$SALA_RC_SESSION" ] && continue
        cpid=$(claude_pid_under "$ppid" 2>/dev/null) || continue
        uuid=""; br=""
        [ -n "$want" ] && registry_conv_r uuid "$cpid"
        if [ "$want" = --bridge ]; then
            br=$(registry_field "$cpid" bridgeSessionId 2>/dev/null); [ "$br" = null ] && br=""
            [ -n "$br" ] || br=$(bridge_for_uuid "$uuid" 2>/dev/null)
        fi
        echo "$pane|$sess|$cpid|$uuid|$br"
    done
}
live_sessions_file() {  # every live conversation (panes + Remote Control served) → a file of uuids
    local f="$SALA_LOG_DIR/salamander-reboot-live.txt"
    { claude_panes --uuid | cut -d'|' -f4; rc_served 2>/dev/null | cut -f1; } | grep -v '^$' | sort -u > "$f"; echo "$f"
}

start_and_resume() {  # <since> <sessions file> <indices…> — rollback / dry-run completion, in start (reverse) order
    local since="$1" sf="$2"; shift 2; local idx=("$@") k i
    for ((k=${#idx[@]}-1; k>=0; k--)); do i=${idx[$k]}
        hook "$i" status 15; local rc=$?
        if [ "$rc" != 0 ]; then
            if hook "$i" start 120 && hook "$i" status 15; then say "  ↑ ${NAMES[$i]} started — $HOOK_LINE"; else say "  ✗ ${NAMES[$i]} did not start — $HOOK_LINE"; fi
        fi
    done
    for ((k=${#idx[@]}-1; k>=0; k--)); do i=${idx[$k]}
        if hook "$i" resume 600 --since "$since" --sessions "$sf"; then say "  ▶ ${NAMES[$i]} resumed — $HOOK_LINE"; else say "  ✗ ${NAMES[$i]} resume failed — $HOOK_LINE"; fi
    done
}
all_idx() { local i; for ((i=0; i<${#NAMES[@]}; i++)); do echo "$i"; done; }

# deliver_notes — hand back every due session note (lib/note.sh); the boot half holds watch off until the services are up
deliver_notes() {
    local out l
    out=$("$SALA_BIN" note --deliver --reboot 2>&1)
    while IFS= read -r l; do [ -n "$l" ] && say "$l"; done <<< "$out"
    printf '%s\n' "$out" | grep -q '✗ notes waiting' && tell_master "⚠️ *Reboot: session notes not delivered yet*" "$(printf '%s\n' "$out" | grep '✗ notes waiting' | sed 's/.*(delivered when it is): //')" "their sessions are not back; \`sala revive --only NAME\` brings one back and its note follows"
    return 0
}
# fire_post_recycle <paused_at ISO> [skipped session…] — SALA_POST_RECYCLE_CMD at the end of the boot half (or `--resume`
# standing in for it; common.sh, post_recycle_hook). Started = the pause (the marker's paused_epoch; older markers: parsed
# from paused_at). Skipped = the sessions given (not back on their conversation) plus those this boot's revive skipped.
fire_post_recycle() {
    local since="$1" started; shift
    started=$(awk -F= '$1=="paused_epoch"{print $2}' "$RMARK" 2>/dev/null)
    [ -n "$started" ] || started=$(date -u -d "$since" +%s 2>/dev/null || date -j -u -f %Y-%m-%dT%H:%M:%SZ "$since" +%s 2>/dev/null || date +%s)
    local boot_skipped=()
    if [ "$(head -1 "$SALA_BOOT_REC" 2>/dev/null)" = "$(boot_id)" ]; then
        while IFS= read -r l; do [ -n "$l" ] && boot_skipped+=("$l"); done < <(sed -n 's/^skipped: \([^:]*\):.*/\1/p' "$SALA_BOOT_REC")
    fi
    post_recycle_hook "$RLOG" reboot "$started" "$@" ${boot_skipped[@]+"${boot_skipped[@]}"}
}
notes_line() { local n; n=$("$SALA_BIN" note --list 2>/dev/null | grep -v '^no unhandled' | awk '{print $2}' | sort -u | paste -sd' '); [ -n "$n" ] && echo "session notes pending: $n"; }

MODE="${1:-}"
case "$MODE" in
--status)
    [ ${#NAMES[@]} -gt 0 ] || { echo "no SALA_REBOOT_HOOKS configured"; exit 0; }
    for i in $(all_idx); do hook "$i" status 15; rc=$?; case "$rc" in 0) s=running;; 3) s=stopped;; *) s="BROKEN (rc $rc)";; esac; echo "${NAMES[$i]}: $s — $HOOK_LINE"; done
    [ -s "$RSTATE" ] && echo "last run: $(st_val mode) · paused at $(st_val paused_at) · step $(st_val step)"
    notes_line; exit 0 ;;
--resume)
    since=$(st_val paused_at); [ -n "$since" ] || since=$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
    say "sala reboot --resume (paused at $since)"
    start_and_resume "$since" "$(live_sessions_file)" $(all_idx); st_put step resumed
    # a marker from the previous boot means this --resume stands in for the boot half: record its result so the
    # post-boot report goes out, and retire the marker
    if [ -s "$RMARK" ] && [ "$(_kv_first "$RMARK" boot_id)" != "$(boot_id)" ]; then
        if [ -s "$SALA_LEDGER_FROZEN" ]; then while IFS= read -r l; do say "  $l"; done < <(ledger_compare_restore Reboot); fi   # as the boot half would
        ledger_unfreeze "boot half finished by hand" && say "  pane map unfrozen"
        deliver_notes
        { echo "$(boot_id)"; echo "clean reboot: boot half finished by hand (sala reboot --resume)"; printf '%s\n' "${REPORT[@]}"; } > "$RRESULT"
        fire_post_recycle "$since"
        mv -f "$RMARK" "$RMARK.done-$(date +%Y%m%dT%H%M%S)"
    fi
    exit 0 ;;
--after-boot) ;;   # below
--dry-run|--go)
    [ ${#NAMES[@]} -gt 0 ] || die "no SALA_REBOOT_HOOKS configured — nothing to pause or flush (see docs/reboot-contract.md)"
    for i in $(all_idx); do [ -x "${PATHS[$i]/#\~/$HOME}" ] || die "hook ${NAMES[$i]}: ${PATHS[$i]} is not executable"; done
    master_guard reboot "${@:2}" ;;   # the dry run pauses and stops services too: master-only like the real one
*) die "usage: salamander reboot --dry-run | --go | --status | --resume" ;;
esac

# ─────────────────────────────── boot half ───────────────────────────────
if [ "$MODE" = --after-boot ]; then
    [ -s "$RMARK" ] || exit 0
    since=$(_kv_first "$RMARK" paused_at); mboot=$(_kv_first "$RMARK" boot_id)
    [ "$mboot" != "$(boot_id)" ] || exit 0          # still the boot that wrote it: nothing to do
    t0=$(date +%s); say "clean reboot (marker from $(local_human "$(awk -F= '$1=="written"{print $2}' "$RMARK")"), paused at $since"
    # 1. revive done (its boot record), then every snapshot pane back on its conversation and claude.ai id — this needs no
    # hook, so it runs first and the hooks' resume never waits on the slowest one
    w=0; until [ "$(head -1 "$SALA_BOOT_REC" 2>/dev/null)" = "$(boot_id)" ] || [ "$w" -ge 900 ]; do sleep 10; w=$((w+10)); done
    # COMPARE AND RESTORE: the roster frozen at the pause against tmux — every session resurrect and
    # revive did not bring back is recreated in its directory and resumed by uuid (common.sh, ledger_compare_restore), one
    # post says what came back; then the freeze is lifted and the follows deferred under it apply
    if [ -s "$SALA_LEDGER_FROZEN" ]; then while IFS= read -r l; do say "  $l"; done < <(ledger_compare_restore Reboot); fi
    ledger_unfreeze "boot half" && say "  pane map unfrozen"
    live=$(claude_panes --bridge); ok=(); bad=(); excl=(); norc=(); vf="$SALA_LOG_DIR/salamander-reboot-verified.txt"; : > "$vf"
    while IFS=$'\t' read -r sess uuid br; do
        [ -n "$sess" ] || continue
        # managed outside sala (Tue Oct 13th 2026; common.sh, no_relaunch): revive left it alone, so it is
        # neither checked nor "not back" (bad feeds the post-recycle hook's skipped list), and nothing is typed into it
        no_relaunch "$sess" && { excl+=("$sess"); continue; }
        row=$(printf '%s\n' "$live" | awk -F'|' -v s="$sess" '$2==s' | head -1)
        IFS='|' read -r pane _ cpid luuid lbr <<< "$row"
        if [ -z "$row" ] || [ "$luuid" != "$uuid" ]; then bad+=("$sess: not back on its conversation"); continue; fi
        # THE API LANE (Tue Oct 13th 2026; common.sh, lanes): no claude.ai login behind it, so no claude.ai id to be
        # back on — back on its conversation is back, and no /remote-control is typed into it
        if ! lane_rc "$(lane_running "$cpid" "$sess")"; then norc+=("$sess"); ok+=("$sess"); echo "$uuid" >> "$vf"; continue; fi
        if [ -n "$br" ] && [ "$lbr" != "$br" ]; then
            if [ -z "$(is_idle_reason "$cpid")" ] && ! pane_prompt "$pane"; then
                submit "$pane" "/remote-control"; sleep 20
                lbr=$(registry_field "$cpid" bridgeSessionId 2>/dev/null); [ "$lbr" = null ] && lbr=""; [ -n "$lbr" ] || lbr=$(bridge_for_uuid "$uuid")
            fi
            [ "$lbr" = "$br" ] || { bad+=("$sess: claude.ai id ${lbr:-none}, expected $br"); echo "$uuid" >> "$vf"; continue; }
        fi
        ok+=("$sess"); echo "$uuid" >> "$vf"
    done < "$RPANES"
    rc_served 2>/dev/null | cut -f1 >> "$vf"
    say "  panes: ${#ok[@]} back on their conversation and claude.ai id${norc:+ (${#norc[@]} on the api lane: no claude.ai id there)}${bad:+; ${#bad[@]} not: $(printf '%s; ' "${bad[@]}")}"
    for s in ${excl[@]+"${excl[@]}"}; do say "  $(no_relaunch_line "$s")"; done
    # 2. every hook polled together, in start order each round; each one is resumed the moment its status is 0, so a slow
    # hook holds nobody else (one writer once took minutes on a first boot, and a serial wait held
    # the others paused behind it). A hook still not up after SALA_REBOOT_BOOT_WAIT is reported once —
    # "still coming up" (status neither 0 nor 3) or "down" (3 and a start failed) — and kept on watch until
    # SALA_REBOOT_BOOT_GIVEUP; it is resumed on its own if it comes up, and the master is told either way.
    pending=(); for ((k=${#NAMES[@]}-1; k>=0; k--)); do pending+=("$k"); done
    declare -A told=() tried=(); RESUMED=()
    resume_one() {  # <k> <how it came up>
        local k="$1"
        if hook "$k" resume 600 --since "$since" --sessions "$vf"; then say "  ▶ ${NAMES[$k]} $2, resumed — $HOOK_LINE"; RESUMED+=("${NAMES[$k]}"); return 0; fi
        say "  ✗ ${NAMES[$k]} $2, but resume failed — $HOOK_LINE"
        tell_master "🚨 *Reboot: ${NAMES[$k]} is up but did not resume*" "status: $HOOK_LINE" "\`sala reboot --resume\` retries" "Details: ~/.claude/salamander-reboot.log"
    }
    watch_hooks() {  # <deadline seconds since t0> — poll until nothing is pending or the deadline passes
        local dl="$1" k rc el left
        while [ ${#pending[@]} -gt 0 ]; do
            left=()
            for k in "${pending[@]}"; do
                hook "$k" status 15; rc=$?; el=$(( $(date +%s) - t0 ))
                if [ "$rc" = 0 ]; then
                    resume_one "$k" "up after ${el}s"
                    [ -n "${told[$k]:-}" ] && tell_master "✅ *Reboot: ${NAMES[$k]} came up after ${el}s*" "resumed — nothing to do"
                    continue
                fi
                if [ "$rc" = 3 ] && [ -z "${tried[$k]:-}" ] && [ "$el" -ge "$SALA_REBOOT_BOOT_WAIT" ]; then  # still stopped: start it once
                    tried[$k]=1
                    if hook "$k" start 120 && hook "$k" status 15; then resume_one "$k" "was down, started"; continue; fi
                fi
                if [ "$el" -ge "$SALA_REBOOT_BOOT_WAIT" ] && [ -z "${told[$k]:-}" ]; then
                    told[$k]=1
                    if [ "$rc" = 3 ]; then state="is down (stopped, and a start did not bring it up)"; else state="is still coming up"; fi
                    say "  ⏳ ${NAMES[$k]} $state ${el}s after boot — $HOOK_LINE"
                    tell_master "⏳ *Reboot: ${NAMES[$k]} $state ${el}s after boot*" "status: $HOOK_LINE" "resumed so far: $(echo "${RESUMED[*]:-none}" | sed 's/ /, /g')" "sala keeps checking it for up to $((SALA_REBOOT_BOOT_GIVEUP/60)) min after boot, resumes it the moment it is up, and says so either way" "Details: ~/.claude/salamander-reboot.log"
                fi
                left+=("$k")
            done
            pending=(${left[@]+"${left[@]}"})
            [ ${#pending[@]} -eq 0 ] && break
            [ $(( $(date +%s) - t0 )) -ge "$dl" ] && return 1
            sleep 10
        done
        return 0
    }
    # the report goes out once every hook is resumed or reported; a reported one stays on watch after it
    first=$(( SALA_REBOOT_BOOT_WAIT + 30 )); watch_hooks "$first"
    deliver_notes
    [ ${#pending[@]} -gt 0 ] && say "  … still on watch: $(for k in "${pending[@]}"; do printf '%s ' "${NAMES[$k]}"; done)(resumed on their own when up)"
    say "  boot half done in $(( $(date +%s) - t0 ))s"
    { echo "$(boot_id)"; printf '%s\n' "${REPORT[@]}"; } > "$RRESULT"
    fire_post_recycle "$since" $(not_back_sessions ${bad[@]+"${bad[@]}"})
    if [ ${#pending[@]} -gt 0 ] && ! watch_hooks "$SALA_REBOOT_BOOT_GIVEUP"; then
        for k in "${pending[@]}"; do
            rlog "  ✗ ${NAMES[$k]} never came up — gave up after $((SALA_REBOOT_BOOT_GIVEUP/60)) min"
            tell_master "🚨 *Reboot: ${NAMES[$k]} never came up*" "still not up $((SALA_REBOOT_BOOT_GIVEUP/60)) min after boot; sala stopped watching it and its inbound stays paused" "fix ${NAMES[$k]}, then \`sala reboot --resume\` resumes it" "Details: ~/.claude/salamander-reboot.log"
        done
        exit 0   # marker kept: --status shows the run unfinished, --resume finishes it
    fi
    mv -f "$RMARK" "$RMARK.done-$(date +%Y%m%dT%H%M%S)"
    exit 0
fi

# ─────────────────────────────── shutdown half ───────────────────────────────
# THE FREEZE: from the pause on, the pane map is the roster this reboot must bring back — frozen here
# (common.sh, ledger_freeze), compared against tmux and lifted in the boot half; a dry run lifts it at its end, a halt in
# its rollback. Already frozen → a recycle is still running: no reboot under it, and nothing has been paused yet.
ledger_frozen && die "the pane map is already $(ledger_freeze_line) — a recycle still running? no reboot under it (a freeze whose owner is gone is cleared by sala watch within minutes)"
ledger_freeze reboot $$ || die "could not freeze the pane map — no reboot without its roster"
T=$(date -u +%Y-%m-%dT%H:%M:%SZ); t0=$(date +%s)
: > "$RSTATE"; st_put mode "$MODE"; st_put paused_at "$T"; st_put step pause
say "sala reboot $MODE — paused at $(local_human "$(date +%s)") ($T); pane map frozen ($(wc -l < "$SALA_LEDGER_FROZEN" | tr -d ' ') rows)"
halt() {  # <why> <stopped indices…> — no reboot; bring everything back
    local why="$1"; shift
    say "✗ HALTED: $why — no reboot; rolling back"
    waiting_clear_owner $$   # the drain's relaunch-waiting flags: no reboot is waiting any more
    start_and_resume "$T" "$(live_sessions_file)" $(all_idx)
    ledger_unfreeze "reboot halted"
    st_put step halted; sala_post "🚨 *$([ "$MODE" = --dry-run ] && echo "Reboot dry run halted" || echo "Reboot halted — $(hostname) was not rebooted")*" "$why" "everything already stopped was started and resumed again" "Details: ~/.claude/salamander-reboot.log"; exit 1
}

# 1. pause inbound
for i in $(all_idx); do
    if hook "$i" pause 30 --at "$T"; then say "  ⏸ ${NAMES[$i]} — $HOOK_LINE"; else halt "${NAMES[$i]} did not pause ($HOOK_LINE)"; fi
done

# 2. drain: every claude pane but the master and this one idle (no prompt, no draft), served sessions idle
st_put step drain
mpane=""; [ -n "${SALA_MASTER:-}" ] && mpane=$(tmux list-panes -t "$(tmux_win_t "$SALA_MASTER")" -F '#{pane_id}' 2>/dev/null | head -1)
dl=$(( $(date +%s) + SALA_REBOOT_DRAIN_WAIT )); nextlog=0
while :; do
    holders=()
    while IFS='|' read -r pane sess cpid uuid br; do
        [ -n "$pane" ] || continue; [ "$pane" = "$mpane" ] && continue; [ "$pane" = "${TMUX_PANE:-}" ] && continue
        why=$(is_idle_reason "$cpid")
        # a background shell with no turn running: the reboot cuts it anyway — held for SALA_REBOOT_SHELL_GRACE, then
        # counted as drained and named in the report (a leftover watcher held the first dry run)
        if [[ "$why" == *"registry says 'shell'"* ]]; then
            k="shell_since_${pane//%/}"; [ -n "${!k:-}" ] || printf -v "$k" '%s' "$(date +%s)"
            if [ $(( $(date +%s) - ${!k} )) -ge "$SALA_REBOOT_SHELL_GRACE" ]; then
                case " ${CUT[*]:-} " in *" $sess "*) ;; *) CUT+=("$sess"); say "  ⚠ $sess: a background shell is still running — the reboot will cut it";; esac
                why=""
            fi
        fi
        [ -z "$why" ] && pane_prompt "$pane" && why="a terminal prompt is showing"
        # unsent text never blocks (a resume does not restore the composer): it goes into the report instead
        if [ -z "$why" ] && d=$(pane_draft "$pane") && [ -n "$d" ]; then
            case " ${DRAFTS_SEEN[*]:-} " in *" $sess "*) ;; *) DRAFTS_SEEN+=("$sess"); say "  ✎ $sess had unsent text at its prompt (not restored after a reboot): \"$d\"";; esac
        fi
        # a holder is told, once, that a reboot waits for it (its PostToolUse hook, common.sh "the relaunch-waiting flag");
        # its `sala ready`, or a turn ending with nothing in flight (its Stop hook's record), is seen by the next poll below
        [ -n "$why" ] && { holders+=("$sess ($why)"); waiting_raise "$uuid" reboot "reboot-$t0" $$; }
    done <<< "$(claude_panes)"
    while IFS=$'\t' read -r sid st _ _ first; do [ -n "$sid" ] && [ "$st" != idle ] && holders+=("served \"$first\" ($st)"); done <<< "$(rc_served 2>/dev/null)"
    [ ${#holders[@]} -eq 0 ] && { waiting_clear_owner $$; break; }   # drained: the flags come down before the box goes down
    [ "$(date +%s)" -ge "$dl" ] && halt "still busy after $((SALA_REBOOT_DRAIN_WAIT/60)) min: $(printf '%s; ' "${holders[@]}")"
    if [ "$(date +%s)" -ge "$nextlog" ]; then say "  … waiting for ${#holders[@]} busy pane(s): $(printf '%s; ' "${holders[@]}" | cut -c1-300)"; nextlog=$(( $(date +%s) + 120 )); fi
    sleep 10
done
while IFS='|' read -r pane sess cpid uuid br; do
        [ -n "$pane" ] || continue; [ "$pane" = "$mpane" ] && continue; [ "$pane" = "${TMUX_PANE:-}" ] && continue
        send_feedback_drafts "$pane" "$(registry_field "$cpid" sessionId)" >/dev/null 2>&1 || rlog "feedback drafts still queued for $sess"
done <<< "$(claude_panes)"
"$SALA_BIN" snapshot --now >/dev/null 2>&1
claude_panes --bridge | awk -F'|' '{print $2"\t"$4"\t"$5}' > "$RPANES"
say "  ⏳ drained in $(( $(date +%s) - t0 ))s: $(wc -l < "$RPANES") panes recorded (conversation + claude.ai id), snapshot taken"

# 3/4. flush and stop, in order, each verified stopped
st_put step flush
for i in $(all_idx); do
    hook "$i" flush-stop 300 || halt "${NAMES[$i]} flush-stop failed ($HOOK_LINE)"
    line="$HOOK_LINE"; hook "$i" status 15; rc=$?
    [ "$rc" = 3 ] || halt "${NAMES[$i]} not stopped after flush-stop (status rc $rc: $HOOK_LINE)"
    say "  ■ ${NAMES[$i]} flushed and stopped — $line"
done
"$SALA_BIN" heartbeat >/dev/null 2>&1 && say "  ♥ final heartbeat"
n=$(notes_line) && say "  📌 $n (handed back to them after the boot)"

if [ "$MODE" = --dry-run ]; then
    st_put step dry-resume
    say "  dry run: steps 1–4 passed in $(( $(date +%s) - t0 ))s — starting and resuming everything"
    start_and_resume "$T" "$(live_sessions_file)" $(all_idx)
    ledger_unfreeze "dry run complete"
    st_put step done; say "✅ dry run complete in $(( $(date +%s) - t0 ))s (no reboot)"
    exit 0
fi

# 5. the real one: marker, then the reboot as this process's last act
{ echo "boot_id=$(boot_id)"; echo "written=$(date +%s)"; echo "paused_at=$T"; echo "paused_epoch=$t0"; echo "panes=$RPANES"; } > "$RMARK"
st_put step rebooting; say "  ⏻ reboot marker written; rebooting now ($(( $(date +%s) - t0 ))s after the pause)"
sync
sudo -n systemctl reboot 2>/dev/null || sudo -n shutdown -r now 2>/dev/null || { rm -f "$RMARK"; halt "the reboot command was refused (sudo)"; }
