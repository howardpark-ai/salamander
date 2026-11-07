# lib/note.sh — a session hands itself its next step across a relaunch.
#
#   salamander note "<what I do once I'm back>"   leave a note for this pane's conversation (prints its id)
#   salamander note --done <id>                    mark a note handled: archived, never delivered again
#   salamander note --done                         mark every note of this pane handled
#   salamander note --list [--archived]            unhandled notes (id, session, written, delivered) · or the archive
#   salamander note --deliver [--reboot]           (watch / the reboot boot half) hand back every due note
#
# A note belongs to the conversation that left it (its uuid) and records the claude pid it was last tied to. It is due
# the moment that conversation is live again on a DIFFERENT pid — i.e. after any relaunch: a clean reboot, a recycle,
# `revive --only`, a crash revive, a manual resume. `sala watch` (every 2 min) delivers due notes into the session's inbox
# as a turn, showing when the note was written so the session can judge whether it still holds. Delivery does not retire
# a note: the session marks it done itself (`--done <id>`) once handled, and until then it comes back at every relaunch,
# so a session that crashes before acting on it still gets it — nothing expires and nothing is dropped silently.
# While a clean reboot's boot half is pending, watch holds off and the boot half delivers once the services
# are resumed (`--reboot`, which also reports notes whose session is not back).
# `sala cue --after "<next>" "<words>"` leaves the note and relays the cue in one step (the hand-over form).
# A handled note is archived, never deleted: one JSON line per note in salamander-notes-archive.jsonl with
# its created, last-delivered and done times, times delivered, and the session that marked it.
# Store: $SALA_LOG_DIR/salamander-notes.tsv (id \t session \t uuid \t created \t pid \t delivered \t delivered_at \t text);
# event log salamander-notes.log.

NOTES="$SALA_LOG_DIR/salamander-notes.tsv"; NLOG="$SALA_LOG_DIR/salamander-notes.log"; NARCH="$SALA_LOG_DIR/salamander-notes-archive.jsonl"
[ -d "$SALA_LOG_DIR" ] || mkdir -p "$SALA_LOG_DIR"; [ -e "$NOTES" ] || >> "$NOTES"   # (mkdir and touch on every call: two processes)
nlog() { local _nt; _iso_now_r _nt; echo "[$_nt] $*" >> "$NLOG"; }
# The store lock covers only reads and rewrites of the TSV; --deliver scans panes and pushes outside it, so a
# `sala note` or `sala cue --after` never waits on a delivery (a long scan under the lock once refused cues).
lock() { exec 9>"$NOTES.lock"; flock -w 30 9 || die "the note store is locked"; }
unlock() { flock -u 9; exec 9>&-; }
[ "${1:-}" = --deliver ] || lock
USAGE='usage: salamander note "<next step>" | --done [<id>] | --list [--archived]'
archive() {  # <tsv line> <done_by> — append the note to the archive as one JSON object
    python3 - "$1" "$2" "$(date +%s)" >> "$NARCH" <<'PYA'
import json, sys
f = sys.argv[1].split('\t', 7); f += [''] * (8 - len(f))
print(json.dumps({"id": f[0], "session": f[1], "uuid": f[2], "created": int(f[3] or 0), "delivered": int(f[5] or 0),
                  "delivered_at": int(f[6] or 0) or None, "done_at": int(sys.argv[3]), "done_by": sys.argv[2], "text": f[7]},
                 ensure_ascii=False))
PYA
}
me() { [ -n "${TMUX_PANE:-}" ] && tmux display -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null || echo "$(hostname) shell"; }

here_pane() {  # → "session|pid|uuid" for the calling pane, or fail
    [ -n "${TMUX_PANE:-}" ] || { echo "a note belongs to a pane: run it from the session that should continue" >&2; return 1; }
    local sess cpid uuid
    sess=$(tmux display -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)
    cpid=$(claude_pid_under "$(tmux display -p -t "$TMUX_PANE" '#{pane_pid}')" 2>/dev/null)
    uuid=""; [ -n "$cpid" ] && uuid=$(registry_field "$cpid" sessionId 2>/dev/null); [ "$uuid" = null ] && uuid=""
    [ -n "$sess" ] && [ -n "$uuid" ] || { echo "no Claude session found in this pane" >&2; return 1; }
    echo "$sess|$cpid|$uuid"
}
ago() { local s=$(( $(date +%s) - $1 )); if [ "$s" -lt 3600 ]; then echo "$((s/60)) min ago"; elif [ "$s" -lt 172800 ]; then echo "$((s/3600)) h ago"; else echo "$((s/86400)) days ago"; fi; }

case "${1:-}" in
--list)
    if [ "${2:-}" = --archived ]; then
        [ -s "$NARCH" ] || { echo "no archived notes"; exit 0; }
        python3 - "$NARCH" <<'PYL' | while IFS=$'\t' read -r id sess c n d db t; do echo "$id  $sess — written $(local_human "$c"), delivered ${n}×, done $(local_human "$d") by $db: $t"; done
import json, sys
for l in open(sys.argv[1], encoding='utf-8'):
    o = json.loads(l); print('\t'.join(str(o[k]) for k in ('id', 'session', 'created', 'delivered', 'done_at', 'done_by', 'text')))
PYL
        exit 0
    fi
    [ -s "$NOTES" ] || { echo "no unhandled notes"; exit 0; }
    while IFS=$'\t' read -r id sess uuid at pid n dat text; do
        echo "$id  $sess — written $(local_human "$at") ($(ago "$at")), delivered ${n}×$( [ "${dat:-0}" != 0 ] && echo ", last $(local_human "$dat")"): $text"
    done < "$NOTES"; exit 0 ;;
--done|--clear)
    if [ -n "${2:-}" ]; then
        grep -q "^$2"$'\t' "$NOTES" || die "no note $2 (sala note --list)"
        line=$(grep "^$2"$'\t' "$NOTES"); archive "$line" "$(me)" || die "could not archive note $2 — left as it is"
        awk -F'\t' -v i="$2" '$1!=i' "$NOTES" > "$NOTES.tmp.$$" && mv -f "$NOTES.tmp.$$" "$NOTES"
        nlog "done: $(cut -f2 <<< "$line") $2 by $(me)"; echo "✓ note $2 marked handled (archived: sala note --list --archived)"
    else
        hp=$(here_pane) || exit 1; IFS='|' read -r _ _ uuid <<< "$hp"
        n=$(awk -F'\t' -v u="$uuid" '$3==u' "$NOTES" | wc -l); by=$(me)
        while IFS= read -r line; do archive "$line" "$by" || die "could not archive — nothing marked"; done < <(awk -F'\t' -v u="$uuid" '$3==u' "$NOTES")
        awk -F'\t' -v u="$uuid" '$3!=u' "$NOTES" > "$NOTES.tmp.$$" && mv -f "$NOTES.tmp.$$" "$NOTES"
        nlog "done: all $n of $uuid"; echo "✓ $n note(s) of this session marked handled"
    fi; exit 0 ;;
--deliver)
    REBOOT=0; [ "${2:-}" = --reboot ] && REBOOT=1
    rm_=$(_kv_first "$SALA_LOG_DIR/salamander-reboot.marker" boot_id)
    if [ "$REBOOT" = 0 ] && [ -n "$rm_" ] && [ "$rm_" != "$(boot_id)" ]; then exit 0; fi   # the boot half delivers
    [ -s "$NOTES" ] || exit 0
    exec 7>"$NOTES.deliver.lock"; flock -w 120 7 || exit 0   # one delivery at a time; the next reads the store after it, so nothing goes twice
    # uuid|claude-pid for every claude process under a tmux pane: one ps pass, ancestry walked in awk
    live=$({ tmux list-panes -a -F 'P #{pane_pid}' 2>/dev/null; ps -e -o pid=,ppid=,comm=; } | awk '
        $1=="P" {pane[$2]=1; next} {pp[$1]=$2; if ($3=="claude") c[$1]=1}
        END {for (p in c) {q=p; while (q!="" && q>1) {if (q in pane) {print p; break}; q=pp[q]}}}' \
        | while read -r c; do u=$(registry_field "$c" sessionId 2>/dev/null); [ -n "$u" ] && [ "$u" != null ] && echo "$u|$c"; done)
    lock; mapfile -t rows < "$NOTES"; unlock
    upd=(); sent=(); lost=()
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r id sess uuid at pid n dat text <<< "$row"
        [ -n "$id" ] || continue
        cpid=$(printf '%s\n' "$live" | awk -F'|' -v u="$uuid" '$1==u {print $2; exit}')
        if [ -n "$cpid" ] && [ "$cpid" != "$pid" ] && sock=$(session_socket "$cpid") && [ -n "$sock" ] \
           && session_push "$sock" "[sala note $id] This session was just relaunched (recycle, revive or reboot). At $(local_human "$at") ($(ago "$at")) it left itself this note: \"$text\" — judge whether it still holds and carry on with it; nobody needs to cue you. Once it is handled, run \`sala note --done $id\`; until then it comes back after every relaunch.$( [ "$n" -gt 0 ] && echo " (Delivered ${n}× before.)") (Automatic salamander message; the note is this session's own words, not ${SALA_OWNER_NAME}'s.)"; then
            n=$((n+1)); upd+=("$id"$'\t'"$cpid"$'\t'"$n"$'\t'"$(date +%s)"); nlog "delivered ($n×): $sess $id: $text"; sent+=("$sess")
        elif [ -z "$cpid" ] && [ "$REBOOT" = 1 ]; then lost+=("$sess: \"$text\"")
        fi
    done
    if [ ${#upd[@]} -gt 0 ]; then   # apply by id to the store as it is now: notes left or marked done meanwhile stay as they are
        lock
        awk -F'\t' -v OFS='\t' 'NR==FNR {p[$1]=$2; n[$1]=$3; d[$1]=$4; next} ($1 in p) {$5=p[$1]; $6=n[$1]; $7=d[$1]} {print}' \
            <(printf '%s\n' "${upd[@]}") "$NOTES" > "$NOTES.tmp.$$" && mv -f "$NOTES.tmp.$$" "$NOTES"
        unlock
    fi
    [ ${#sent[@]} -gt 0 ] && echo "  📌 notes delivered: ${sent[*]}"
    [ ${#lost[@]} -gt 0 ] && echo "  ✗ notes waiting, their session is not back (delivered when it is): $(printf '%s; ' "${lost[@]}")"
    exit 0 ;;
-*) die "$USAGE" ;;
esac

text=$(printf '%s' "$*" | tr '\t\r\n' '   ' | sed 's/  */ /g; s/^ //; s/ $//')
[ -n "$text" ] || die "$USAGE"
hp=$(here_pane) || exit 1; IFS='|' read -r sess cpid uuid <<< "$hp"
id=$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n'); while grep -q "^$id"$'\t' "$NOTES"; do id=$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n'); done
printf '%s\t%s\t%s\t%s\t%s\t0\t0\t%s\n' "$id" "$sess" "$uuid" "$(date +%s)" "$cpid" "$text" >> "$NOTES"
nlog "left: $sess $id: $text"
echo "📌 note $id left for '$sess': handed back to this conversation after every relaunch (reboot, recycle, revive) until you run \`sala note --done $id\`"
