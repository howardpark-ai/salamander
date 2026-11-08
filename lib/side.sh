# lib/side.sh — a side session's write-up gate (quick side conversations; docs/side-sessions.md).
#
#   salamander side done [--name NAME] [--item board#N] [--item-updated EPOCH|ISO] [--summary FILE|TEXT|-] [--summary-to NAME|projects/SLUG] [--dry-run]
#
# Run by the side session itself (spawn --side made it; common.sh, THE SIDE SESSIONS), before its conversation ends. It records a marker,
# $SALA_STATE_DIR/side/<name>.done, ONLY when the write-up is in place, and `retire` of a side session is refused without it
# (lib/retire.sh; --skip-writeup the one bypass). All of these must hold; every check is run and every failure said, so one call tells what is missing:
#   1. THE ITEM CHANGED since the session started. A script cannot read an arbitrary item from stackshot: its client lists an item only under
#      the sessions that own it or are named in its needs, with `updated` (epoch). So the item is looked for under the agents the session was
#      started with (--agents, the origin, the summary's receiver), and its `updated` must be later than the session's start. When none of
#      them lists it (the session is not named on the item), the session reads the item through its stackshot connector and confirms with
#      --item-updated <the `updated` it saw, epoch or ISO time>; that confirmation is taken as the item's word. No item on the record (a fork
#      without --item): the check is skipped, and said so.
#   2. THE PROJECT PAGE has a timeline line from the session: `- **YYYY-MM-DD** | <name> — …`, dated on or after the day it started, in
#      the brain mirror ($SALA_BRAIN_DIR; the coordinator commits every put to it at once, so a put shows there). Where the
#      mirror is not on this box (or SALA_BRAIN_DIR is not set), the page's last-change time from stackshot's client (`get page-ts`) after the start counts, said as the
#      weaker proof it is. No project on the record (a fork of an agent with none): skipped, and said so.
#   3. THE SUMMARY reached the origin agent (a fork) or the project's -main (a start about an item): sala sends it from --summary (a file,
#      text, or - for stdin) through stackshot's client message, once all the other checks hold, and records that it did, so a repeat of
#      `side done` never sends it again. A receiver ending in -main gets `[for <owner>]` on the first line (a front agent takes a message only
#      then). --summary-to NAME sends it to another agent: first without the mark (a background agent must not get it), and once more
#      with it only when stackshot refuses with its front-agent text ("is a front agent … [for <owner>]"; a user-facing agent not named
#      *-main); any other failure ends there. --summary-to projects/SLUG (or a key in another page dir) sends it to the project (the router rules it), never marked. Without a summary and none sent before: this check fails.
# --dry-run runs the checks and sends and writes nothing. A marker already there: said, exit 0. Exit 0 the marker is there, 1 something is missing.
# The commands (stackshot's client, one per knob, so the tests stub them): SALA_SIDE_ITEMS_CMD <agent> · SALA_SIDE_PAGE_TS_CMD <page key> ·
# SALA_SIDE_MSG_CMD <to> - --sender <name> (the text on stdin); empty = the check or the send is not possible and fails with that said.

stackshot_prog_r _SIDE_CLIENT "${SALA_STACKSHOT_DIR-}" client   # the client under the stackshot checkout: its package path, else the root path of an older checkout (lib/stackshot-path.sh)
: "${SALA_SIDE_ITEMS_CMD=${SALA_STACKSHOT_DIR:+python3 $_SIDE_CLIENT get items}}"        # → the agent's open items as JSON ({"items": [{"shown": "board#N", "updated": epoch, …}]})
: "${SALA_SIDE_PAGE_TS_CMD=${SALA_STACKSHOT_DIR:+python3 $_SIDE_CLIENT get page-ts}}"    # → {"key": …, "ts": epoch} (the fallback when the brain mirror is not here)
: "${SALA_SIDE_MSG_CMD=${SALA_STACKSHOT_DIR:+python3 $_SIDE_CLIENT message}}"            # → delivers the message; exit 0 delivered
: "${SALA_BRAIN_DIR:=}"                                                      # the brain mirror (read only here); empty (the default) = none on this box
: "${SALA_SIDE_TIMEOUT:=30}"                                                  # seconds for each of those commands but the message's
: "${SALA_SIDE_MSG_TIMEOUT:=150}"                                             # the message is delivered before the server answers (client.py: up to 130 s)

usage="usage: salamander side done [--name NAME] [--item board#N] [--item-updated EPOCH|ISO] [--summary FILE|TEXT|-] [--summary-to NAME|projects/SLUG] [--dry-run]"
sub="${1:-}"; [ -n "$sub" ] || die "$usage"
[ "$sub" = done ] || die "unknown side command '$sub' — $usage"
shift
NAME=""; ITEM=""; ITEM_UPDATED=""; SUMMARY=""; SUMMARY_SET=0; SUMMARY_TO=""; DRY=0
while [ $# -gt 0 ]; do case "$1" in
    --name) NAME="${2:-}"; shift 2 || die "--name needs the side session's name" ;;
    --item) ITEM="${2:-}"; shift 2 || die "--item needs board#N" ;;
    --item-updated) ITEM_UPDATED="${2:-}"; shift 2 || die "--item-updated needs an epoch or an ISO time" ;;
    --summary) SUMMARY="${2-}"; SUMMARY_SET=1; shift 2 || die "--summary needs a file, text, or - for stdin" ;;
    --summary-to) SUMMARY_TO="${2:-}"; shift 2 || die "--summary-to needs an agent's session name or projects/<slug>" ;;
    --dry-run) DRY=1; shift ;;
    *) die "unknown option: $1 — $usage" ;;
esac; done

if [ -z "$NAME" ]; then   # the caller's own session: the tmux session of its pane
    [ -n "${TMUX_PANE:-}" ] && NAME=$(tmux display -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)
    [ -n "$NAME" ] || die "which session? run it from the side session's own pane, or pass --name NAME"
fi
side_is "$NAME" || die "'$NAME' is not a side session: no record at $(side_file "$NAME") (spawn --side writes it)"
[ -z "$ITEM" ] || item_id_ok "$ITEM" || die "--item takes a board item id as shown (board#N, sN, board-tmp-box#N), not '$ITEM'"
case "$SUMMARY_TO" in   # a session name, or a project's key (<dir>/<slug>, e.g. projects/demo): /-separated parts of letters, digits . _ -
    *[!A-Za-z0-9._/-]*|-*|/*|*/|*//*|*..*) die "--summary-to needs an agent's session name or a project key (<dir>/<slug>, e.g. projects/demo), not '$SUMMARY_TO'";;
esac
if [ -f "$(side_done_file "$NAME")" ]; then
    echo "✅ '$NAME': the write-up marker is there already ($(head -1 "$(side_done_file "$NAME")")); retire it when ${SALA_OWNER_NAME} says: sala op retire $NAME --from <you> --words \"<${SALA_OWNER_NAME}'s words>\""
    exit 0
fi

STARTED=$(side_val "$NAME" started); STARTED="${STARTED:-0}"
[ -n "$ITEM" ] || ITEM=$(side_val "$NAME" item)
PROJECT=$(side_val "$NAME" project); ORIGIN=$(side_val "$NAME" origin); AGENTS=$(side_val "$NAME" agents)
[ -n "$SUMMARY_TO" ] || SUMMARY_TO=$(side_val "$NAME" summary_to)
SENT_TO=$(side_val "$NAME" summary_sent_to)
run_cmd() {  # <seconds> <command string> <args…> → the command's stdout, its status (the string word-split as the spawn's ask command is)
    local t="$1" c="$2"; shift 2
    timeout --kill-after=5 "$t" sh -c "$c \"\$@\"" side-cmd "$@" </dev/null 2>/dev/null
}

# a time as epoch seconds: a number, or an ISO 8601 time (a trailing Z or an offset; no zone = UTC)
to_epoch() {
    python3 - "$1" <<'PY' 2>/dev/null
import datetime, sys
v = sys.argv[1].strip()
try:
    print(int(float(v)))
except ValueError:
    d = datetime.datetime.fromisoformat(v.replace("Z", "+00:00"))
    if d.tzinfo is None: d = d.replace(tzinfo=datetime.timezone.utc)
    print(int(d.timestamp()))
PY
}
item_updated() {  # <item> → 0 with ITEM_UPD its `updated` (epoch): --item-updated, else the first agent whose open items list it; 1 with ITEM_WHY
    local a ep out seen=" " list
    ITEM_UPD=""; ITEM_WHY=""
    if [ -n "$ITEM_UPDATED" ]; then
        ep=$(to_epoch "$ITEM_UPDATED") && [ -n "$ep" ] || { ITEM_WHY="--item-updated '$ITEM_UPDATED' is neither an epoch nor an ISO time"; return 1; }
        ITEM_UPD="$ep"; return 0
    fi
    [ -n "$SALA_SIDE_ITEMS_CMD" ] || { ITEM_WHY="SALA_SIDE_ITEMS_CMD is empty: no way to read $1 from a script; pass --item-updated"; return 1; }
    list="$(tr ',' ' ' <<< "$AGENTS") $ORIGIN $SUMMARY_TO"
    for a in $list; do
        case "$seen" in *" $a "*) continue;; esac; seen="$seen$a "
        out=$(run_cmd "$SALA_SIDE_TIMEOUT" "$SALA_SIDE_ITEMS_CMD" "$a") || continue
        ep=$(python3 -c 'import json, sys
try:
    items = json.load(sys.stdin)["items"]
except Exception:
    sys.exit(1)
for it in items:
    if isinstance(it, dict) and it.get("shown") == sys.argv[1] and it.get("updated"):
        print(int(float(it["updated"]))); sys.exit(0)
sys.exit(1)' "$1" <<< "$out" 2>/dev/null) && [ -n "$ep" ] && { ITEM_UPD="$ep"; return 0; }
    done
    ITEM_WHY="stackshot's client lists an item only under its owner and the sessions named in its needs, and none of $(tr -s ' ' <<< "$list" | sed 's/^ //; s/ $//; s/ /, /g') lists $1 (it may be closed): read $1 with the stackshot connector and pass the time it shows as --item-updated <epoch or ISO time>"
    return 1
}
page_line() {  # <page key> → 0 when a timeline line from this session is on the page (stdout: the proof); 1 with the why
    local f="" since ts out mirror
    [ -n "$SALA_BRAIN_DIR" ] && f="$SALA_BRAIN_DIR/$1.md"
    mirror="the brain mirror ${SALA_BRAIN_DIR:-(SALA_BRAIN_DIR, not set)}"
    since=$(cs_date -d "@$STARTED" +%Y-%m-%d)
    if [ -n "$f" ] && [ -r "$f" ]; then
        out=$(python3 - "$f" "$NAME" "$since" <<'PY' 2>/dev/null
import re, sys
path, name, since = sys.argv[1:4]
timeline = False
for line in open(path, encoding="utf-8", errors="replace"):
    if re.match(r"^#{1,6}\s+Timeline\s*$", line):
        timeline = True; continue
    if timeline and re.match(r"^#{1,6}\s", line):
        timeline = False
    m = re.match(r"^- \*\*(\d{4}-\d{2}-\d{2})\*\*\s*\|\s*(.*)$", line) if timeline else None
    if not m or m.group(1) < since: continue
    head = m.group(2).split(" — ", 1)[0]
    if name in re.split(r"[\s|,/]+", head):
        print("a timeline line of %s on %s" % (m.group(1), path)); sys.exit(0)
sys.exit(1)
PY
        ) && { echo "$out"; return 0; }
        echo "no timeline line from $NAME dated $since or later in $1 (a line \`- **YYYY-MM-DD** | $NAME — what happened\`: add_timeline_entry with source $NAME)"; return 1
    fi
    [ -n "$SALA_SIDE_PAGE_TS_CMD" ] || { echo "$mirror is not here and SALA_SIDE_PAGE_TS_CMD is empty: the page cannot be looked at"; return 1; }
    out=$(run_cmd "$SALA_SIDE_TIMEOUT" "$SALA_SIDE_PAGE_TS_CMD" "$1") \
        && ts=$(python3 -c 'import json,sys; print(int(json.loads(sys.stdin.read()).get("ts") or 0))' <<< "$out" 2>/dev/null) \
        || { echo "$mirror is not here and stackshot's client could not give the page's last change"; return 1; }
    if [ "${ts:-0}" -gt "$STARTED" ]; then echo "$1 changed at $(local_human "$ts") (the brain mirror is not on this box: the page's last change from stackshot is the weaker proof of a timeline line)"; return 0; fi
    echo "$1 has not changed since the session started ($(local_human "$STARTED")): add a timeline line with source $NAME"; return 1
}

MISSING=0; LINES=()
chk() { LINES+=("   $1 $2"); }
# 1. the item
if [ -z "$ITEM" ]; then chk "–" "item: none on this session's record (a fork started without --item): not checked"
else
    if item_updated "$ITEM"; then
        if [ "$ITEM_UPD" -gt "$STARTED" ]; then chk "✓" "item: $ITEM changed at $(local_human "$ITEM_UPD"), after the session started ($(local_human "$STARTED"))"
        else chk "✗" "item: $ITEM last changed at $(local_human "$ITEM_UPD"), not after the session started ($(local_human "$STARTED")): record what was decided on it (next, description or a comment) through the stackshot connector"; MISSING=1; fi
    else chk "✗" "item: $ITEM_WHY"; MISSING=1; fi
fi
# 2. the project page
if [ -z "$PROJECT" ]; then chk "–" "page: no project on this session's record: not checked"
else
    if why=$(page_line "$PROJECT"); then chk "✓" "page: $why"; else chk "✗" "page: $why"; MISSING=1; fi
fi
# 3. the summary: sent before, or given now
TEXT=""
if [ -n "$SENT_TO" ]; then chk "✓" "summary: sent to $SENT_TO at $(local_human "$(side_val "$NAME" summary_sent_at)") already"
elif [ "$SUMMARY_SET" = 1 ]; then
    if [ "$SUMMARY" = "-" ]; then TEXT=$(cat)
    elif [ -f "$SUMMARY" ] && [ -r "$SUMMARY" ]; then TEXT=$(cat "$SUMMARY")
    else TEXT="$SUMMARY"; fi
    if [ -z "${TEXT//[[:space:]]/}" ]; then chk "✗" "summary: --summary is empty"; MISSING=1
    else chk "✓" "summary: ${#TEXT} characters, to $SUMMARY_TO once the other checks hold"; fi
else chk "✗" "summary: none sent and none given — --summary FILE|TEXT|- (written for $SUMMARY_TO)"; MISSING=1; fi

echo "side done '$NAME'$([ "$DRY" = 1 ] && echo " (dry run)"):"
printf '%s\n' "${LINES[@]}"
if [ "$MISSING" = 1 ]; then
    echo "✗ no marker written: the write-up is not complete (fix what is marked ✗ and run salamander side done again; retire is refused until then)" >&2
    exit 1
fi
if [ "$DRY" = 1 ]; then echo "dry run: nothing sent, no marker written"; exit 0; fi

# send the summary (once), then the marker
if [ -z "$SENT_TO" ]; then
    [ -n "$SALA_SIDE_MSG_CMD" ] || die "SALA_SIDE_MSG_CMD is empty: the summary cannot be sent, so no marker is written"
    if [ -n "$ORIGIN" ]; then what="a side conversation forked from $ORIGIN${ITEM:+ (about $ITEM)}"; else what="a side conversation about ${ITEM:-its project}${PROJECT:+ ($PROJECT)}"; fi
    body="[side done] $NAME, $what, has finished its conversation with ${SALA_OWNER_NAME}. Its summary:

$TEXT

(Automatic salamander message from sala side done; nothing to reply to. The session stays until ${SALA_OWNER_NAME} has it retired.)"
    mark="[for ${SALA_OWNER_NAME}]
"
    send_try() {  # <header> → 0 delivered; this attempt's output is in $ATTEMPT_OUT and appended to the log
        local rc
        ATTEMPT_OUT=$(mktemp "${TMPDIR:-/tmp}/sala-side-msg.XXXXXX") || die "could not make a temp file for the message output"
        printf '%s' "$1$body" | timeout --kill-after=10 "$SALA_SIDE_MSG_TIMEOUT" sh -c "$SALA_SIDE_MSG_CMD \"\$@\"" side-msg "$SUMMARY_TO" - --sender "$NAME" > "$ATTEMPT_OUT" 2>&1; rc=$?
        cat "$ATTEMPT_OUT" >> "$SALA_LOG_DIR/salamander-side.log"
        return $rc
    }
    # A front agent that is not a *-main (a user-facing agent with another suffix) takes a message only with [for <owner>] on line 1; a background
    # agent must not get that mark. So a -main gets it at once; any other agent first without it, and once with it only on stackshot's own refusal.
    # A page-key target (<dir>/<slug>) goes to the router, which rules it: never marked.
    case "$SUMMARY_TO" in
        */*) HOW=plain ;;
        *-main) HOW=marked ;;
        *) HOW=try ;;
    esac
    ATTEMPT_OUT=""; DELIVERED=""
    # the attempt's output file goes on ANY exit, a stop included (a SIGTERM from a `timeout` or a cancelled CI job runs an EXIT trap, not a plain `rm` below)
    trap 'rm -f "${ATTEMPT_OUT:-}"' EXIT
    if [ "$HOW" = marked ]; then send_try "$mark" && DELIVERED="with [for ${SALA_OWNER_NAME}]"
    else
        send_try "" && DELIVERED="without [for ${SALA_OWNER_NAME}]"
        if [ -z "$DELIVERED" ] && [ "$HOW" = try ] && grep -qF -e "front agent" -e "[for ${SALA_OWNER_NAME}]" "$ATTEMPT_OUT"; then
            echo "[$(date '+%F %T')] side done $NAME: $SUMMARY_TO refused the message without [for ${SALA_OWNER_NAME}] (a front agent); retrying once with it" >> "$SALA_LOG_DIR/salamander-side.log"
            rm -f "$ATTEMPT_OUT"
            send_try "$mark" && DELIVERED="with [for ${SALA_OWNER_NAME}], on the second attempt"
        fi
    fi
    rm -f "$ATTEMPT_OUT"
    [ -n "$DELIVERED" ] || die "the summary could not be sent to $SUMMARY_TO ($SALA_SIDE_MSG_CMD; its output is in $SALA_LOG_DIR/salamander-side.log): no marker written; run side done again"
    echo "[$(date '+%F %T')] side done $NAME: summary delivered to $SUMMARY_TO $DELIVERED" >> "$SALA_LOG_DIR/salamander-side.log"
    printf 'summary_sent_to=%s\nsummary_sent_at=%s\n' "$SUMMARY_TO" "$(date +%s)" >> "$(side_file "$NAME")"
    echo "   the summary was sent to $SUMMARY_TO"
fi
mkdir -p "$SALA_SIDE_DIR"
printf '%s by %s: item %s, page %s, summary to %s\n' "$(date +%s)" "$NAME" "${ITEM:-none}" "${PROJECT:-none}" "${SUMMARY_TO:-$SENT_TO}" > "$(side_done_file "$NAME").t.$$" && mv -f "$(side_done_file "$NAME").t.$$" "$(side_done_file "$NAME")" \
    || die "could not write the marker $(side_done_file "$NAME")"
echo "✅ the write-up marker is written. The session retires when ${SALA_OWNER_NAME} says: sala op retire $NAME --from <you> --words \"<${SALA_OWNER_NAME}'s words>\""
