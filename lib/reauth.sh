# lib/reauth.sh — re-sign-in a claude.ai connector for Claude Code.
#
# THE USAGE: `reauth --help` prints a blank line, then from its first `salamander reauth NAME` line through the `no master:` line, so keep it contiguous.
#   salamander reauth NAME                               print the sign-in link for "claude.ai NAME", for the calling
#                                                        session to hand to the owner in its final message; any session
#   salamander reauth NAME --done [--from ME] [--dry-run]   once the owner has signed in: check the connector, then cue the forced
#                                                        recycle through the master (--dry-run: print the cue, send nothing);
#                                                        no master: print the `sala op recycle --force` line to queue it, exit 0
#
# NO MASTER: the queue takes an operation only with the owner's words verbatim, and this verb's words are its own,
# so it queues nothing itself: it prints the exact `sala op recycle --force --from <you> --words "<the owner's words>"` line for
# the calling session to run with the owner's words, and exits 0 (its own work, the check, is done).
# NAME is the connector's display name with or without "claude.ai " (for example Stackshot;
# several words are joined). Why a recycle: a pane reads its connectors only at start, so a re-authorized connector reaches
# no running session until each one relaunches — and a relaunch of every pane is the master's to run (the recycle procedure). This verb never recycles anything itself.
#
# THE LOGIN, read from the 2.1.294 binary (Fri Oct 9th 2026): for a claude.ai connector `claude mcp login "claude.ai NAME"
# --no-browser` builds .../api/organizations/<org>/mcp/start-auth/<server id>?product_surface=<entrypoint> locally,
# prints it and "Once authorized on claude.ai, the connector will be available the next time you start Claude Code.",
# clears the CLI's own needs-auth cache entry for it and exits — it waits for nothing. The link carries no secret.
# THE CHECK: `claude mcp get "claude.ai NAME"` (a few seconds) prints "Status: ✔ Connected" once the sign-in took, and
# "! Needs authentication" before. It shows the sign-in took, not that a pane has the tools: that is the recycle's job.
# Exit: 0 link printed / cue handed over (or would be, --dry-run) / no master: the queue line printed · 1 no link, not
#       connected yet, or a usage error ·
#       the cue's own exit status when the hand-over fails.

DONE=0; DRY=0; FROM=""; NAME=""
while [ $# -gt 0 ]; do case "$1" in
    --done) DONE=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --from) FROM="${2:-}"; shift 2 || die "--from needs a name" ;;
    -h|--help) echo; awk '/^#   salamander reauth NAME /{p=1} p{print} p && /no master: print the `sala op recycle --force` line/{exit}' "$SALA_ROOT/lib/reauth.sh" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "usage: salamander reauth NAME [--done [--from ME] [--dry-run]]" ;;
    *) NAME="${NAME:+$NAME }$1"; shift ;;
esac; done
NAME="${NAME#claude.ai }"
[ -n "$NAME" ] || die "usage: salamander reauth NAME [--done [--from ME] [--dry-run]]   (NAME: the connector, e.g. Stackshot)"
SERVER="claude.ai $NAME"

if [ "$DONE" = 0 ]; then
    out=$(timeout 60 "$SALA_CLAUDE" mcp login "$SERVER" --no-browser </dev/null 2>&1); rc=$?
    url=$(printf '%s\n' "$out" | grep -oE 'https://[^[:space:]]+/mcp/start-auth/[^[:space:]]+' | head -1)
    if [ -z "$url" ]; then
        echo "no sign-in link for '$SERVER' (claude mcp login exit $rc):"
        printf '%s\n' "$out" | head -5 | sed -E 's/((token|code|secret)=)[^&[:space:]]+/\1…/gI; s/^/   /'
        exit 1
    fi
    echo "sign-in link for the $SERVER connector — put it in the turn's final message for ${SALA_OWNER_NAME} and end the turn there:"
    echo "$url"
    echo "once they have signed in: sala reauth $(printf '%q' "$NAME") --done   (checks it, then hands the forced recycle to the master, or with none prints the queue line)"
    exit 0
fi

st=$(timeout 60 "$SALA_CLAUDE" mcp get "$SERVER" </dev/null 2>&1 | awk '/^[[:space:]]*Status:/ {sub(/^[[:space:]]*Status:[[:space:]]*/, ""); print; exit}')
case "$st" in
    *"Needs authentication"*) echo "$SERVER still needs authentication — ${SALA_OWNER_NAME}'s sign-in has not landed yet; nothing was cued. A new link: sala reauth $(printf '%q' "$NAME")"; exit 1 ;;
    *Connected*) case "$st" in *"failed"*) echo "$SERVER: $st — nothing was cued; check again in a minute"; exit 1 ;; esac ;;
    "") echo "$SERVER: claude mcp get gave no status (no such connector?) — nothing was cued"; exit 1 ;;
    *) echo "$SERVER: $st — not connected, nothing was cued; check again in a minute"; exit 1 ;;
esac
if [ -z "${SALA_CUE_TARGET:-${SALA_MASTER:-}}" ]; then   # no master: the queue, with the owner's own words
    echo "$SERVER: $st — no master session is configured, so the forced recycle goes through the operation queue; nothing was queued here (the queue takes ${SALA_OWNER_NAME}'s words verbatim). Queue it with ${SALA_OWNER_NAME}'s words:"
    echo "   sala op recycle --force --from ${FROM:-<you>} --words \"<${SALA_OWNER_NAME}'s words>\""
    exit 0
fi
words="recycle claude: the $NAME connector was re-authorized, every pane must reload its connectors"
set -- cue; [ -n "$FROM" ] && set -- "$@" --from "$FROM"
if [ "$DRY" = 1 ]; then
    echo "$SERVER: $st"
    echo "[dry-run] would run: sala $* \"$words\""
    exit 0
fi
echo "$SERVER: $st — handing the forced recycle to the master"
exec "$SALA_BIN" "$@" "$words"
