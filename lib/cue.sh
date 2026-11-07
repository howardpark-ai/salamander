# lib/cue.sh — hand an operator cue ("recycle claude", "update the CLI", "update claude on box1", "reboot the box", "rename X to Y") to the master.
#
#   salamander cue [--from NAME] [--dry-run] "<the owner's exact words>"
#   salamander cue --after "<what I do once I'm back>" "<words>"   the handing pane leaves itself a note (`sala note`) and
#       relays the cue in one step; the note comes back to this conversation after the relaunch the cue causes
#   salamander cue [--from NAME] --stdin <<'CUE' … CUE     the words on stdin — the form a pane on ANOTHER machine uses,
#       over the fleet ssh mesh: ssh <coordinator> ~/.local/bin/sala cue --from <me> --stdin <<'CUE' (ssh re-parses
#       arguments in the remote shell, so words with quotes or apostrophes survive only on stdin)
#
# The session that HEARS such a cue never runs it: a recycle relaunches every pane on the box, the hearing
# one included, and only one driver may hold it (the one-driver guard in `recycle`/`update` enforces it).
# `cue` does the whole relay: resolve the master (SALA_MASTER), confirm its claude is live, and deliver
# the words verbatim — with who heard them and when — straight into the master's inbox socket, where
# they arrive as a turn. The master maps the words to the command itself; `cue` never translates them.
# A pane on another machine runs this same verb over ssh (above). Only cloud and Cowork sessions, which cannot ssh,
# reach the master through the Stackshot message tool; the recycle procedure covers all three.
# NO MASTER (Thu Oct 15th 2026): with SALA_MASTER unset there is nobody to hand the words to — the operation
# queue (lib/op.sh) runs them: this prints the pointer (`sala op <verb> … --from NAME --words "…"`, the verb table, one
# example), delivers nothing to any inbox and exits 1, so a script that cues (reauth --done) notices. With a master
# configured it behaves as it always did.
# Exit: 0 delivered (or: this IS the master — run it here) · 1 no master configured · 2 master not live ·
#       4 delivery failed. Log: $SALA_LOG_DIR/salamander-cue.log.

FROM=""; DRY=0; WORDS=""; STDIN=0; AFTER=""
while [ $# -gt 0 ]; do case "$1" in
    --from) FROM="${2:-}"; shift 2 || die "--from needs a name" ;;
    --dry-run) DRY=1; shift ;;
    --after) AFTER="${2:-}"; shift 2 || die "--after needs the note" ;;
    --stdin) STDIN=1; shift ;;
    -*) die "usage: salamander cue [--from NAME] [--after \"<my next step>\"] [--dry-run] \"<${SALA_OWNER_NAME}'s words>\"" ;;
    *) WORDS="${WORDS:+$WORDS }$1"; shift ;;
esac; done
[ "$STDIN" = 1 ] && WORDS=$(cat | tr '\r\n' '  ' | sed 's/  */ /g; s/^ //; s/ $//')
[ -n "$WORDS" ] || die "usage: salamander cue [--from NAME] [--after \"<my next step>\"] [--dry-run] \"<${SALA_OWNER_NAME}'s words>\""
target="${SALA_CUE_TARGET:-${SALA_MASTER:-}}"      # SALA_CUE_TARGET: tests only
here=""; [ -n "${TMUX_PANE:-}" ] && here=$(tmux display -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)
: "${FROM:=${here:-$(hostname) shell}}"
if [ -z "$target" ]; then
    . "$SALA_ROOT/lib/op.sh"   # the verb table (op_shapes); nothing of the queue runs here
    echo "no master session is configured: a cue has nobody to go to — nothing was delivered, nothing was run."
    echo "fleet operations go through the operation queue, which sala's watch runs with no model (lib/op.sh): map the words to the verb yourself, then"
    echo "   sala op <verb> [args…] --from $FROM --words \"<${SALA_OWNER_NAME}'s words>\"        (the plan is shown first; sala op --plan <verb> … shows it alone)"
    echo "verbs:"; op_shapes
    echo "e.g.   sala op recycle --update --force --from $FROM --words \"$WORDS\""
    exit 1
fi
if [ -z "${SALA_CUE_TARGET:-}" ] && [ -n "$here" ] && [ "$here" = "$target" ]; then
    echo "this session IS the master ('$target'): run the cue here — nothing relayed"; exit 0
fi
pane=$(tmux list-panes -t "$(tmux_win_t "$target")" -F '#{pane_id}' 2>/dev/null | head -1)
mpid=""; [ -n "$pane" ] && mpid=$(claude_pid_under "$(tmux display -p -t "$pane" '#{pane_pid}')" 2>/dev/null)
[ -n "$mpid" ] || { echo "the master '$target' is not live (no claude in its pane) — nothing was run; salamander watch heals it within 2 minutes, then say the cue again"; exit 2; }
sock=$(session_socket "$mpid")
[ -n "$sock" ] || { echo "the master '$target' (pid $mpid) has no messaging socket in the registry — cannot deliver; tell ${SALA_OWNER_NAME}, nothing was run"; exit 4; }
when=$(local_human)
msg="[sala cue] from ${SALA_OWNER_NAME} — \"$WORDS\" — said at $when in $FROM.
Relayed by \`salamander cue\` as an operator cue: this is ${SALA_OWNER_NAME}'s instruction, relayed verbatim. Map the words to the command yourself (recycle claude → salamander recycle --update --force · update the CLI → salamander update --fleet · update claude on <box> → salamander update <host> · reboot the box this master runs on → salamander reboot --go, the clean reboot protocol: you oversee every step, halt on any failure, and the reboot is your last act · retire <session> → salamander retire <session> · bring back <session> → salamander revive --only <session> · provision <host…> → salamander provision <host…> · rename <old> to <new> → salamander rename <old> <new>), run it, and report in your own pane. Nothing to reply to $FROM."
[ -n "$AFTER" ] && [ "$DRY" = 0 ] && { "$SALA_BIN" note "$AFTER" || die "the note could not be left — nothing was relayed"; }
if [ "$DRY" = 1 ]; then echo "[dry-run] would deliver to '$target' (pid $mpid, $sock):"; echo "$msg"; exit 0; fi
# prov_names_hosts <lowercased cue> → 0 when "provision" is followed by host names rather than a whole-fleet run: a single word,
# or a first word that is one of SALA_FLEET_HOSTS or this box's hostname. With SALA_FLEET_HOSTS unset only the single word counts.
prov_names_hosts() {
    local rest=${1#*provision} w h
    printf '%s' "$rest" | grep -qE '^ +[a-z0-9][a-z0-9._-]* *$' && return 0
    read -r w _ <<< "$rest"
    [ -n "$w" ] || return 1
    for h in $SALA_FLEET_HOSTS "$_SALA_HN"; do [ "$w" = "${h,,}" ] && return 0; done
    return 1
}
mkdir -p "$SALA_LOG_DIR"
if session_push "$sock" "$msg"; then
    echo "[$(date -Is)] cue delivered → $target (pid $mpid) from $FROM: $WORDS" >> "$SALA_LOG_DIR/salamander-cue.log"
    bridge=$(registry_field "$mpid" bridgeSessionId); [ "$bridge" = null ] && bridge=""
    echo "✅ cue handed to the master '$target'${bridge:+ (https://claude.ai/code/$bridge)} — it runs it and reports in its own pane"
    lw=${WORDS,,}; lw=$(printf '%s' "$lw" | sed -E 's/(no|without|skips?( the)?) recycle//g')   # "no recycle" is not a recycle
    lw="${lw%% — *}"   # only the cue itself, not the context after " — " (a context line that mentioned a recycle once warned a retire)
    case "$lw" in   # only what relaunches panes warns the handing pane; a rename, retire or revive of another pane does not
        *"update claude on "*|*"update the cli on "*) ;;   # one remote box: nothing here relaunches
        *recycle*|*reboot*|*"update the cli"*|*"update claude"*) relaunch=1 ;;
        *provision*) prov_names_hosts "$lw" || relaunch=1 ;;   # "provision <host…>" touches no pane on this box
    esac
    [ "${relaunch:-0}" = 1 ] && [ -n "$here" ] && echo "   this pane ('$here') will be relaunched once it is idle — finish or hand off anything half-done now"
    case "$lw" in
        *rename*) echo "   a rename relaunches nothing: the master types /rename in that pane when it is idle and updates sala's records" ;;
    esac
    exit 0
fi
echo "[$(date -Is)] cue FAILED → $target from $FROM: $WORDS" >> "$SALA_LOG_DIR/salamander-cue.log"
echo "delivery to the master '$target' failed — nothing was run; tell ${SALA_OWNER_NAME}"; exit 4
