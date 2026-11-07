# lib/retire.sh — end a Claude session for good: the one verb that makes a pane STAY gone.
#
#   salamander retire <tmux-session> [--keep-web] [--busy] [--skip-writeup] [--self] [--leave-items] [--dry-run]
#   salamander retire --id <conversation-id> [the same flags]
#
# THE THREE VERBS (Sun Nov 1st 2026): `retire` once ended anything a name pointed at: a Claude session, a plain shell, a leftover pane-map
# row, a registry name or a conversation id, and a wrong guess ended the wrong thing. It is now three verbs, each with its own refusals that name
# the other two:
#   retire <tmux-session>      a session with a Claude in it (this file). The positional is an EXACT tmux session name, nothing else: no
#                              registry name, no prefix. A session known only by its conversation is named with --id.
#   close-shell <tmux-session> a session whose panes run no Claude (lib/close-shell.sh)
#   forget-row <name>          a pane-map row whose tmux session is gone (lib/forget-row.sh)
# retire refuses a session with no Claude in it (it names close-shell) and a name with no tmux session (it names forget-row when the pane map
# still holds a row, else --id).
#
# A session that simply exits comes BACK at the next revive: the sidecar still names it, the
# resurrect snapshot still holds its pane, and revive's job is precisely to resume what it finds
# (one session signed off, was resurrected, and looked like a stale snapshot).
# Retiring is therefore ordered steps, which this does in one:
#   1. /exit the claude in the pane (unless already gone; --busy skips the idle wait)
#   2. kill the tmux session
#   3. drop its row from the pane map — the only path that does (the map is a ledger; the history copy keeps the old map)
#   4. take a resurrect snapshot, so a reboot cannot restore the pane either
#   5. archive its claude.ai session, so it leaves the app's list too (--keep-web to skip); not when its conversation id
#      came from the map and another row carries it too (a warning instead: it may be that session's)
# The transcript is never deleted: `claude --resume <uuid>` still brings the conversation back by
# hand, and `spawn --fork` can branch from it.
#
# THE GUARDRAILS (each bypass is its own flag, and `--force`, which was several of them at once, is gone: it is refused with a sentence naming them):
#   --busy            retire a session that is not idle (a turn running, a child, a dialog); without it the retire stops at the idle check
#   --skip-writeup    retire a side session before `sala side done` wrote its marker (below)
#   --self            retire the session this very command runs in (the caller placed by process ancestry, common.sh ancestry_session, never TMUX_PANE
#                     alone): refused without it, since the retire ends the call that made it; with it the /exit is not typed into this pane, the output goes
#                     to the retire log, and the tail of the retire (snapshot, archive, the stackshot call) goes on after the pane is gone
#   --leave-items     retire a session that moves open board items. Before anything is done sala asks stackshot's client (common.sh,
#                     RETIRE ASKS FOR OPEN ITEMS FIRST): a session that is the mover of an open item is refused with the item ids listed, and when stackshot
#                     cannot be asked (no client.py, a failing client, an answer that is not the list) the retire is refused with that reason; this flag overrides both
#   --keep-web        leave the claude.ai session as it is
# The checks run in --dry-run too, said as "[dry-run] would refuse: …".
#
# --id (was THE NAME, for a session living in a hand-launched tmux session with no pane-map row): a conversation id
# (a full uuid, or 8+ hex characters, the first group of one) is looked up in the CLI's session registry (~/.claude/sessions/<pid>.json: name,
# sessionId, tmux = "session:@window.%pane"). The row's pane id is read back to its CURRENT tmux session name (the registry's `tmux` is written once at
# start and ignores a rename-session), and the claude must descend from that pane's shell on this server (a pane id is per server).
# The choice is said before anything is done — id → registry row → tmux session, pane — and the retire then runs on that tmux session, its pane, as if it had
# been named. Nothing is guessed: two live rows answering to the id (a prefix on several), or a resolved tmux session that also holds another live claude
# (retire kills the whole session), stop here with the candidates listed and nothing touched; a row whose process is gone, that records no tmux pane
# (a `claude -p`, the app's own run), or whose pane is not on this server is said and not acted on.
#
# A SIDE SESSION (common.sh, THE SIDE SESSIONS; lib/side.sh) is retired only on the owner's word, and only after its write-up: a
# session spawn --side made is refused here, in the dry run (the queue's plan) and for real, until `sala side done` wrote its marker
# ($SALA_STATE_DIR/side/<name>.done: the board item changed, the project page has the session's timeline line, the summary was sent).
# The refusal says what is missing and points at `side done`; --skip-writeup is the only bypass (said when used). A session with no side
# record is untouched. After a retire the record and the marker move to side/retired/.
#
# THE AGENT ENTRY (Wed Oct 28th 2026): once a retire has succeeded (--busy and the other bypasses too) sala tells stackshot to take the session off its project, so
# a retired session does not stay on the project's agents map or as a pending agent: `client.py post project-agent-retire <project> <name> --sender sala-retire`,
# under `timeout 90`. stackshot does the work: it removes the agent's line from the project page's `agents:` map (and adds a timeline line), or drops a
# pending entry; the answer is 200 (line removed, dropped or not listed) or a refusal, and a 502 means the page write failed (the line may still be on the
# page, or only the timeline line is missing: the reason says which). The project is the registry row's (else a side record's, else the one stackshot's roles list gives the name: `client.py get
# roles`, else roles.json). It fails soft: no project, no client.py, an error, a 502 or a timeout is one line in ~/.claude/salamander-retire.log and one
# "ℹ" line in the output, and the retire's exit and result are untouched (common.sh, RETIRE DROPS THE AGENT ENTRY). A dry run never calls.
#
# --dry-run (the same day): nothing typed, killed, written, snapshotted or archived; every action above printed as
# "[dry-run] would …" with what it would touch (the pane, the pane-map row, the lane and model rows, the snapshot, the
# claude.ai session), the refusals as "[dry-run] would refuse: …" (exit 1, as the real run would). The resolution runs
# before it, so `--dry-run --id` shows the choice too. The master guard lets a dry run through from any
# pane, as for every other verb.

usage="usage: salamander retire <tmux-session> | --id <conversation-id>  [--keep-web] [--busy] [--skip-writeup] [--self] [--leave-items] [--dry-run]
  a session with no Claude in it: salamander close-shell <tmux-session>; a pane-map row whose tmux session is gone: salamander forget-row <name>"
name=""; IDARG=""; KEEP_WEB=0; BUSY=0; SKIPW=0; SELF=0; LEAVE=0; DRY=0; DRYFLAG=""
NOTMASTER=""
while [ $# -gt 0 ]; do case "$1" in
    --keep-web) KEEP_WEB=1 ;; --busy) BUSY=1 ;; --skip-writeup) SKIPW=1 ;; --self) SELF=1 ;; --leave-items) LEAVE=1 ;;
    --dry-run) DRY=1; DRYFLAG=--dry-run ;; --not-master) NOTMASTER=--not-master ;;
    --force) die "--force is gone: it was two different bypasses. Use --busy to retire a session that is not idle (do not wait for it), or --skip-writeup to retire a side session before \`sala side done\` wrote its marker" ;;
    --id) [ $# -ge 2 ] || die "--id needs a conversation id"; IDARG="$2"; shift ;;
    --id=*) IDARG="${1#--id=}" ;;
    -*) die "unknown option: $1
$usage" ;;
    *) [ -z "$name" ] || die "retire takes one session: '$name' and '$1' were both given
$usage"; name="$1" ;;
esac; shift; done
[ -z "$name" ] || [ -z "$IDARG" ] || die "name the session either by its tmux session name or by --id, not both
$usage"
[ -n "$name" ] || [ -n "$IDARG" ] || die "$usage"
dry() { echo "[dry-run] $*"; }
refuse() {  # <why> → the refusal as the dry run says it, or the real one's die
    if [ "$DRY" = 1 ]; then dry "would refuse: $1"; dry "nothing was changed"; exit 1; fi
    die "$1"
}

# ── --id: the registry ────────────────────────────────────────────────────────────────────────────────────────────────
registry_scan() {  # → one line per registry file: pid \t name \t sessionId \t tmux (a field missing or not a string: empty)
    python3 - "$SALA_REG_DIR" <<'PY'
import json, os, sys
d = sys.argv[1]
try: names = sorted(os.listdir(d))
except OSError: sys.exit(0)
for fn in names:
    if not fn.endswith('.json') or not fn[:-5].isdigit(): continue
    try:
        with open(os.path.join(d, fn)) as f: r = json.load(f)
    except Exception: continue
    if not isinstance(r, dict): continue
    def s(k):
        v = r.get(k, '')
        return v.replace('\t', ' ').replace('\n', ' ') if isinstance(v, str) else ''
    print('\t'.join([fn[:-5], s('name'), s('sessionId'), s('tmux')]))
PY
}
registry_resolve() {  # <conversation id> — sets name and RESOLVED_PANE to the one tmux session the registry answers with, or dies with the candidates
    local want="$1" lw pid rname sid tm pane sess ppid state line others
    local -a act=() out=()   # actionable rows ("pid|name|sid|sess|pane"), the rest with why ("pid|name|sid|why")
    lw=${want,,}
    case "$lw" in ''|*[!0-9a-f-]*) die "--id takes a conversation id (a full uuid, or its first 8 or more hex characters), not '$want'; a tmux session is named without --id: sala retire <tmux-session>";; esac
    [ "${#lw}" -ge 8 ] || die "--id '$want' is too short: a conversation id is a full uuid, or its first 8 or more hex characters"
    while IFS=$'\t' read -r pid rname sid tm; do
        [ -n "$pid" ] || continue
        if [ "$sid" = "$lw" ]; then :
        elif [ -n "$sid" ] && [ "${sid#"$lw"}" != "$sid" ]; then :
        else continue; fi
        state=""; sess=""; pane=""
        if ! kill -0 "$pid" 2>/dev/null; then state="its process (pid $pid) is gone"
        elif [ -z "$tm" ]; then state="no tmux pane recorded for it (a \`claude -p\` or the app's own run, not a pane)"
        elif is_rc_child "$pid"; then state="a Remote Control child, not a pane"
        else
            pane=${tm##*.}
            if ! sess=$(tmux display -p -t "$pane" '#{session_name}' 2>/dev/null) || [ -z "$sess" ]; then state="its pane $pane is not on this tmux server (or is gone)"
            elif ! is_under "$pid" "$(tmux display -p -t "$pane" '#{pane_pid}' 2>/dev/null)"; then state="pane $pane on this server is not its pane (the row is another tmux server's)"
            fi
        fi
        if [ -z "$state" ]; then act+=("$pid|$rname|$sid|$sess|$pane"); else out+=("$pid|$rname|$sid|$state"); fi
    done < <(registry_scan)
    cand_line() {  # pid|name|sid|sess|pane → one bullet
        local p n s se pa; IFS='|' read -r p n s se pa <<< "$1"; echo "  - name '$n' (pid $p, conversation $s) → tmux session '$se', pane $pa"; }
    out_line() {   # pid|name|sid|why → one bullet, with the pane-map row that carries its conversation, if any (and the verb that takes that row)
        local p n s w rows hint=""; IFS='|' read -r p n s w <<< "$1"; rows=$(ledger_uuid_rows "$s")
        if [ -n "$rows" ] && [[ $rows != *,* ]]; then
            if tmux has-session -t "=$rows" 2>/dev/null; then hint=" (sala retire $rows)"; else hint=" (its tmux session is gone: sala forget-row $rows)"; fi
        fi
        echo "  - name '$n' (pid $p, conversation $s): $w${rows:+ — the pane map carries that conversation as row '$rows'$hint}"; }
    if [ "${#act[@]}" = 0 ]; then
        [ "${#out[@]}" = 0 ] && die "no live session has conversation id '$want' (no CLI registry row carries it)"
        die "no live session has conversation id '$want'; the CLI registry names it, but nothing there can be acted on:
$(for line in "${out[@]}"; do out_line "$line"; done)"
    fi
    if [ "${#act[@]}" -gt 1 ]; then
        die "'$want' is ambiguous — ${#act[@]} live sessions answer to it, and retire guesses none; name the tmux session (sala retire <session>), or give more of the id:
$(for line in "${act[@]}"; do cand_line "$line"; done)$(for line in ${out[@]+"${out[@]}"}; do echo; out_line "$line"; done)"
    fi
    IFS='|' read -r pid rname sid sess pane <<< "${act[0]}"
    # the resolved tmux session holding another live claude (another registry row's pane in it): retire kills the whole session
    others=""
    while IFS=$'\t' read -r opid orname osid otm; do
        [ -n "$opid" ] && [ "$opid" != "$pid" ] && [ -n "$otm" ] && kill -0 "$opid" 2>/dev/null || continue
        [ "$(tmux display -p -t "${otm##*.}" '#{session_name}' 2>/dev/null)" = "$sess" ] || continue
        is_under "$opid" "$(tmux display -p -t "${otm##*.}" '#{pane_pid}' 2>/dev/null)" || continue
        others="$others
  - name '$orname' (pid $opid, conversation $osid) in pane ${otm##*.}"
    done < <(registry_scan)
    [ -z "$others" ] || die "'$want' is in tmux session '$sess' (pane $pane, pid $pid), which also holds another live session — retire kills the whole tmux session, so it stops here; /exit or move the other first:$others"
    for line in ${out[@]+"${out[@]}"}; do echo "ℹ not this one: $(out_line "$line" | sed 's/^  - //')"; done
    echo "'$want' → CLI registry (name '$rname', pid $pid, conversation $sid) → tmux session '$sess', pane $pane"
    name="$sess"; RESOLVED_PANE="$pane"
}
given="${name:-$IDARG}"; RESOLVED_PANE=""
[ -z "$IDARG" ] || registry_resolve "$IDARG"
ops_guard retire "$name" $NOTMASTER $DRYFLAG
ledger_frozen_die retire   # a recycle or reboot holds the pane map: a retire whose row could not go would come back

# ── the name is a live tmux session, exactly ──────────────────────────────────────────────────────────────────────────
if ! tmux has-session -t "=$name" 2>/dev/null; then
    if [ -n "$(ledger_row "$name")" ]; then
        die "no tmux session '$name', but the pane map still holds a row for it (a leftover): drop it with: sala forget-row $name"
    fi
    die "no tmux session '$name' (retire takes the exact name \`tmux list-sessions\` shows, nothing else); if the session is known by its conversation, use: sala retire --id <conversation-id>"
fi
# the guards below read the name the retire runs on: the tmux session, given or resolved
[ "$name" = "$SALA_RC_SESSION" ] && die "'$name' is the Remote Control server — use: salamander rc --stop"
# THE MASTER (Thu Oct 15th 2026): retiring the session the watchdog keeps alive is refused here as ever, from
# the queue included — the queue's runner unsets SALA_MASTER first (salamander master --unset) and only then runs this,
# as one operation (lib/op.sh, op_run), so by the time it runs the name is no master. Its plan is this dry run, which the
# queue runs before the unset: with SALA_OP_PLAN=1 (set by `sala op` for the plan alone) the dry run says what the queue
# would do and goes on; a dry run outside the queue refuses, as the real run does.
if [ -n "${SALA_MASTER:-}" ] && [ "$name" = "$SALA_MASTER" ]; then
    if [ "$DRY" = 1 ] && [ "${SALA_OP_PLAN:-}" = 1 ]; then dry "'$name' is the master session the watchdog keeps alive: the queue would unset SALA_MASTER first (salamander master --unset), then retire it as below"
    else die "'$name' is the master session the watchdog keeps alive — the queue does it in one operation (sala op retire $name --from <you> --words \"<${SALA_OWNER_NAME}'s words>\": unset SALA_MASTER, then retire); by hand, salamander master --unset first if you really mean it"; fi
fi
lane_dry_line() {  # <session> → what the lane and model rows are, for the dry run
    local l m; l=$(lane_row "$1"); m=$(model_row "$1")
    if [ -n "$l" ]; then dry "would drop its lane row ($1 → $l) from $SALA_LANES"; else dry "no lane row to drop (a later session of the name starts on the default lane)"; fi
    if [ -n "$m" ]; then dry "would drop its model row ($1 → $(printf '%s' "$m" | tr '\t' /)) from $SALA_MODELS"; else dry "no model row to drop"; fi
}
agent_dry_line() {  # the stackshot call a real retire makes at its end (RETIRE DROPS THE AGENT ENTRY, common.sh), for the dry run: said, never made
    [ -z "${proj:-}" ] || dry "would tell stackshot to drop '$name' from $proj's agents once retired (client.py post project-agent-retire, label $SALA_RETIRE_SENDER); a failure there changes nothing"
}
proj=""

# ── a Claude in the session: the pane to act on ───────────────────────────────────────────────────────────────────────
# the session's own pane, by an exact target (a plain `-t 0` was the CALLER's window 0: common.sh EXACT TMUX SESSION TARGETS); the first pane of the
# session that runs a claude (any window), the resolved one when --id named it
pane=""; panepid=""; cpid=""
if [ -n "$RESOLVED_PANE" ]; then pane=$RESOLVED_PANE; panepid=$(tmux display -p -t "$pane" '#{pane_pid}'); cpid=$(claude_pid_under "$panepid" || true)
else
    while read -r pn pp; do
        [ -n "$pn" ] || continue
        c=$(claude_pid_under "$pp" || true)
        if [ -n "$c" ]; then pane=$pn; panepid=$pp; cpid=$c; break; fi
    done < <(tmux list-panes -s -t "$(tmux_win_t "$name")" -F '#{pane_id} #{pane_pid}')
fi
if [ -z "$cpid" ]; then
    refuse "'$name' runs no Claude session (none of its panes holds a claude process): to close a plain shell session use: sala close-shell $name"
fi

# the caller's own session: placed by process ancestry (common.sh ancestry_session: a claude on the way up from a pane's process), never by TMUX_PANE
# alone, which any caller can set to anything. The retire would end the very call that made it. The queue's runner is not in that pane's process tree, so
# there it is the op's own record that says whose retire this is (SALA_OP_FROM, set only by `sala op`): a name the asker is, unless --self was typed. `sala op`
# checks the same at queue time (op.sh op_self_retire_ok) for a named retire; this is the check for --id, which names its session only here.
caller=$(ancestry_session 2>/dev/null || true)
own=0; [ -n "$caller" ] && [ "$caller" = "$name" ] && own=1
OWN_TURN=0; [ "$own" = 1 ] && [ "$SELF" = 1 ] && OWN_TURN=1   # --self from the target's own pane: its running turn is not a reason against (common.sh is_idle_reason)
asker=0; [ "$own" = 0 ] && [ -n "${SALA_OP_FROM:-}" ] && [ "$SALA_OP_FROM" = "$name" ] && asker=1
if [ "$own" = 1 ] || [ "$asker" = 1 ]; then
    if [ "$SELF" = 1 ] && [ "$own" = 1 ]; then
        if [ "$DRY" = 1 ]; then dry "--self: '$name' is the session this command runs in; it would retire itself (no /exit typed into this pane, the output going to $SALA_LOG_DIR/salamander-retire.log once the pane is gone)"
        else echo "⚠ retiring '$name', the session this command runs in (--self): the rest of this output goes to $SALA_LOG_DIR/salamander-retire.log"; fi
    elif [ "$SELF" = 1 ]; then
        if [ "$DRY" = 1 ]; then dry "--self: '$name' queued this retire itself; the queue's runner ends it once its turn is over"
        else echo "ℹ --self: '$name' queued this retire itself; the queue's runner ends it"; fi
    else
        who="the session this command runs in"; [ "$asker" = 1 ] && who="the session that queued this retire"
        refuse "'$name' is $who: retiring it ends this very call (and the turn that made it). To do it anyway pass --self; the usual way is to queue it: sala op retire $name --self --from $name --words \"<${SALA_OWNER_NAME}'s words>\""
    fi
fi
if [ "$SELF" = 1 ] && [ "$own" = 0 ] && [ "$asker" = 0 ]; then
    [ "$DRY" = 1 ] && dry "--self given, but '$name' is not the session this command runs in${caller:+ ('$caller' is)}: it changes nothing" || echo "ℹ --self given, but '$name' is not the session this command runs in${caller:+ ('$caller' is)}: it changes nothing"
fi

if side_is "$name" && [ ! -f "$(side_done_file "$name")" ]; then
    sidewhy="'$name' is a side session and its write-up is not done: no marker at $(side_done_file "$name"). The session writes it by running \`salamander side done --name $name --summary \"…\"\`, which needs the board item $(side_val "$name" item) changed since it started, a timeline line from it on the page $(side_val "$name" project), and its summary sent to $(side_val "$name" summary_to) (\`salamander side done --name $name --dry-run\` shows which is missing). Retire it without the write-up only with --skip-writeup"
    if [ "$SKIPW" = 1 ]; then echo "⚠ retiring the side session '$name' without its write-up marker (--skip-writeup)"
    else refuse "$sidewhy"; fi
fi

uuid=""; bridge=""; shared=""
registry_conv_r uuid "$cpid"
bridge=$(registry_field "$cpid" bridgeSessionId); [ "$bridge" = null ] && bridge=""
# a conversation id known only from the map that another row carries too (a scrambled follow left
# one session on another's) may be that other session's: its claude.ai session is not archived from here
if [ -z "$uuid" ]; then uuid=$(sidecar_uuid_for_session "$name"); [ -n "$uuid" ] && shared=$(ledger_uuid_rows "$uuid" "$name"); fi
[ -n "$bridge" ] && [ -n "$uuid" ] || { [ -n "$uuid" ] && [ -z "$shared" ] && bridge=$(bridge_for_uuid "$uuid"); }
retire_project_of "$name" "$uuid"; proj=$RETIRE_PROJ; psrc=$RETIRE_PROJ_SRC   # read now: the retire marks the registry row retired, and a retired row is not looked up live

# OPEN BOARD ITEMS (common.sh, RETIRE ASKS FOR OPEN ITEMS FIRST): a session that moves one is not ended from under it
if [ "$LEAVE" = 1 ]; then
    if [ "$DRY" = 1 ]; then dry "--leave-items: would not ask stackshot whether '$name' moves open board items"; else echo "⚠ retiring '$name' without asking whether it moves open board items (--leave-items)"; fi
else
    retire_open_items "$name" "$uuid"; irc=$?
    case "$irc" in
        1) refuse "'$name' is the mover of open board items: $RETIRE_ITEMS. Hand them over or finish them first (they would be left with no one moving them); to retire it with them left as they are, pass --leave-items" ;;
        2) refuse "stackshot could not be asked whether '$name' moves open board items, so the retire stops here: $RETIRE_ITEMS_WHY. To retire it without that check, pass --leave-items" ;;
    esac
fi
if [ "$DRY" = 1 ]; then   # the live path, read only: every step below as a would-line, in its order
    echo "'$name': claude pid $cpid in pane $pane${uuid:+, conversation $uuid}${bridge:+, claude.ai session $bridge}"
    why=$(SALA_IDLE_OWN_TURN=$OWN_TURN is_idle_reason "$cpid")
    if [ -n "$why" ] && [ "$BUSY" = 0 ]; then dry "would refuse: '$name' is not idle: $why — wait, or pass --busy to retire it anyway"; dry "nothing was changed"; exit 1; fi
    [ -n "$why" ] && dry "would retire '$name' while it is not idle ($why) — --busy"
    if [ "$SELF" = 1 ] && [ "$caller" = "$name" ]; then dry "this is the session itself: no /exit would be typed into pane $pane"
    elif [ -z "$(pane_draft "$pane")" ] && ! pane_prompt "$pane"; then
        if drafts_queued "$uuid"; then dry "would send the queued feedback draft(s) of $uuid first (sala feedback drain), then type /exit into pane $pane and wait up to 30s for the shell"
        else dry "would type /exit into pane $pane and wait up to 30s for the shell"; fi
    else dry "a prompt or unsubmitted text is showing in pane $pane: would kill the tmux session without a clean /exit"; fi
    dry "would kill tmux session '$name' (pane $pane, shell pid $panepid)"
    orow=$(ledger_row "$name")
    if [ -n "$orow" ]; then dry "would remove its pane-map row from $SALA_SIDECAR (tab-separated): $(printf '%s' "$orow" | tr '\t' ' ') — revive would not resume it again"
    else dry "no pane-map row to remove (the map does not know '$name')"; fi
    lane_dry_line "$name"
    dry "would take a resurrect snapshot (salamander snapshot --now), so a reboot would not restore the pane"
    if [ "$KEEP_WEB" = 1 ]; then dry "--keep-web: would leave the claude.ai session${bridge:+ $bridge} as it is"
    elif [ -n "$shared" ]; then dry "would NOT archive on claude.ai: conversation $uuid (from the pane map) is also the row of $shared, so its claude.ai session may be theirs"
    elif [ -n "$bridge" ]; then dry "would archive its claude.ai session $bridge (salamander rc --archive $bridge)"
    else dry "no claude.ai session id found — nothing to archive from here (by hand if it is still listed)"
    fi
    agent_dry_line
    dry "the transcript would stay${uuid:+: claude --resume $uuid}"
    dry "nothing was changed"; exit 0
fi

if [ "$asker" = 1 ] && [ "$SELF" = 1 ] && [ "$BUSY" = 0 ]; then
    # the queue starts its runner at once, while the asker's turn (the one that queued this) is still running: wait for that turn to end, then the usual idle
    # check below; a pane still busy after SALA_RETIRE_SELF_WAIT seconds (a dialog, a background task) is refused as any busy pane is
    w=0; wmax=${SALA_RETIRE_SELF_WAIT:-300}
    while [ -n "$(is_idle_reason "$cpid")" ] && [ "$w" -lt "$wmax" ]; do
        [ "$w" = 0 ] && echo "ℹ '$name' queued this retire itself and is mid-turn: waiting up to ${wmax}s for its turn to end"
        sleep 2; w=$((w + 2))
    done
fi
why=$(SALA_IDLE_OWN_TURN=$OWN_TURN is_idle_reason "$cpid")
if [ -n "$why" ] && [ "$BUSY" = 0 ]; then die "'$name' is not idle: $why — wait, or pass --busy to retire it anyway"; fi
[ -n "$why" ] && echo "⚠ retiring '$name' while it is not idle ($why)"
if [ "$SELF" = 1 ] && [ "$caller" = "$name" ]; then
    # the tmux kill below ends this very process tree: ignore the hangup and a closed pty, and write what is left to the retire log, so the tail (snapshot, archive, stackshot) is done
    trap '' HUP PIPE; mkdir -p "$SALA_LOG_DIR"; exec >> "$SALA_LOG_DIR/salamander-retire.log" 2>&1
    echo "[$(date '+%F %T')] retire --self '$name': no /exit typed into its own pane, the tmux session is killed next"
elif [ -z "$(pane_draft "$pane")" ] && ! pane_prompt "$pane"; then
    echo "'$name': /exit ..."; unmode "$pane"; send_feedback_drafts "$pane" "$uuid" || echo "⚠ feedback draft(s) still queued — /exit will stop at the drafts gate; retire kills the tmux session anyway (drafts stay on disk)"
    tui_send "$pane" "/exit"; wait_for "$pane" shell 30 || echo "⚠ claude did not exit within 30s; killing the tmux session anyway"
else
    echo "⚠ a prompt or unsubmitted text is showing; killing the tmux session without a clean /exit"
fi

tmux kill-session -t "=$name" && echo "'$name': tmux session killed"
# the one path that drops a row (the map is a ledger — common.sh): a missing tmux session alone never does
if [ -n "$(ledger_row "$name")" ]; then
    if ledger_write retire "$name"; then echo "'$name': pane map row removed (revive will not resume it again)"
    else echo "⚠ '$name': the pane map row could not be removed (see above) — until it is, a restore would bring the session back"; fi
fi
lane_drop "$name" || true   # its lane row with it (common.sh, lanes): a later session of the same name starts on the default
model_drop "$name" || true  # its model row too (common.sh, models): a later session of the same name takes its transcript's
"$SALA_BIN" snapshot --now && echo "'$name': resurrect snapshot taken (a reboot will not restore the pane)"
if [ "$KEEP_WEB" = 0 ] && [ -n "$shared" ]; then
    echo "⚠ not archiving on claude.ai: conversation $uuid (from the pane map) is also the row of $shared, so its claude.ai session may be theirs — archive it by hand if it is really this session's"
elif [ "$KEEP_WEB" = 0 ] && [ -n "$bridge" ]; then
    "$SALA_BIN" rc --archive "$bridge" || echo "⚠ archive it on claude.ai by hand: $bridge"
elif [ "$KEEP_WEB" = 0 ] && [ -n "$cpid$uuid" ]; then
    echo "⚠ no claude.ai session id found — archive it by hand if it is still listed"
fi
as=""; [ "$given" != "$name" ] && as=" (named as '$given')"
echo "retired '$name'$as${uuid:+; the transcript stays — bring the conversation back with: claude --resume $uuid}"
retire_drop_agent "$name" "$proj" "${psrc:-}"   # the retire is done: tell stackshot to drop the agent entry (always 0; a failure is a log line, never the retire's result)
if side_is "$name"; then mkdir -p "$SALA_SIDE_DIR/retired" && mv -f "$(side_file "$name")" "$SALA_SIDE_DIR/retired/" && { [ ! -f "$(side_done_file "$name")" ] || mv -f "$(side_done_file "$name")" "$SALA_SIDE_DIR/retired/"; }; fi   # the side record is history now
