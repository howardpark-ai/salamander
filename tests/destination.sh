#!/usr/bin/env bash
# Where a result or alert goes is named from the config, never from a literal (sala's alert destination, BRIEFING_BOT_APP_<NAME> and
# BRIEFING_BOT_CHANNEL_<NAME>). Two halves.
# 1. The words `sala op` prints. sala_post_destination (lib/common.sh) asks bot_destination (contrib/briefing/lib.sh), which reads the same
#    mapping _bot_post posts with (_bot_resolve): with the sala-admin app mapped it says "Slack: the <app> app's DM" for that app, with a
#    channel's own app mapped and BRIEFING_CHANNEL set it says that app, with nothing mapped (or no notify command) "Slack: not configured",
#    with a notify command of the owner's own a plain line naming SALA_NOTIFY_CMD; a config that changes changes the words; the queue line and the
#    inbox line of lib/op.sh print the resolved words and no channel name.
# 2. A scan of the shipped docs, help text, config.example and lib/bin/contrib files: none names a Slack channel as `#some-name` (a hash and
#    a hyphenated lowercase name), none says "briefing channel", and no "the <name> app" / "<name>-app" names an app that the shipped
#    config.example does not itself name (its examples) beyond a tiny generic list. A name that was real once and is gone fails here.
# A temporary HOME and config; nothing outside them is touched, nothing is sent.
# Usage: bash tests/destination.sh   (exit 0 = pass; a few seconds)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
export HOME=$(mktemp -d)
trap 'rm -rf "$HOME"' EXIT
unset BRIEFING_CHANNEL SALA_NOTIFY_CHANNEL BRIEFING_BOT_APP_SALA_ADMIN BRIEFING_BOT_APP_REPORTS SALA_NOTIFY_CMD SALA_WATCH_NOTIFY_CMD
export SALA_CONFIG=$HOME/config

dest() {  # <notify command> → what sala_post_destination says, in a clean shell that sources lib/common.sh
    ( export SALA_ROOT="$ROOT" SALA_NOTIFY_CMD="$1"; . "$ROOT/lib/common.sh" >/dev/null 2>&1; sala_post_destination )
}
POST="sh $ROOT/contrib/briefing/post-stdin.sh"

: > "$SALA_CONFIG"
got=$(dest "$POST"); [ "$got" = "Slack: not configured" ] && ok "post path set, no app mapped: $got" || bad "unmapped: [$got]"
got=$(dest ""); [ "$got" = "Slack: not configured" ] && ok "no notify command: $got" || bad "no cmd: [$got]"
got=$(dest "cat > /dev/null"); [ "$got" = "Slack: posted by the notify command (SALA_NOTIFY_CMD)" ] && ok "a command of the owner's own: a plain line" || bad "own cmd: [$got]"

printf 'BRIEFING_BOT_APP_SALA_ADMIN=alerts-app\nBRIEFING_BOT_CHANNEL_SALA_ADMIN=D0000000001\n' > "$SALA_CONFIG"
got=$(dest "$POST"); [ "$got" = "Slack: the alerts-app app's DM" ] && ok "sala-admin app mapped: $got" || bad "mapped: [$got]"

printf 'BRIEFING_BOT_APP_SALA_ADMIN=other-app\n' > "$SALA_CONFIG"
got=$(dest "$POST"); [ "$got" = "Slack: the other-app app's DM" ] && ok "the config changes, the words change: $got" || bad "changed: [$got]"

printf 'BRIEFING_BOT_APP_SALA_ADMIN=alerts-app\nBRIEFING_BOT_APP_REPORTS=reports-app\n' > "$SALA_CONFIG"
got=$( BRIEFING_CHANNEL=reports dest "$POST" ); [ "$got" = "Slack: the reports-app app's DM" ] && ok "a channel with its own app: that app, as _bot_post would use" || bad "channel app: [$got]"
got=$( BRIEFING_CHANNEL=nomap dest "$POST" ); [ "$got" = "Slack: the alerts-app app's DM" ] && ok "a channel with no app: the sala-admin app (the fallback _bot_post uses)" || bad "fallback: [$got]"
got=$( SALA_NOTIFY_CHANNEL=reports dest "$POST" ); [ "$got" = "Slack: the alerts-app app's DM" ] && ok "sala's own posts carry no channel: SALA_NOTIFY_CHANNEL is not read" || bad "own post: [$got]"

printf 'BRIEFING_BOT_APP_SALA_ADMIN=bad.name\n' > "$SALA_CONFIG"
got=$(dest "$POST"); [ "$got" = "Slack: not configured" ] && ok "a value that is no app name: not configured" || bad "bad name: [$got]"

# the two lines of lib/op.sh print the resolved words and no literal
q=$(grep -c 'one post (\$(sala_post_destination))' "$ROOT/lib/op.sh"); [ "$q" = 1 ] && ok "op's queue line prints sala_post_destination" || bad "queue line: $q"
q=$(grep -c 'the result is also posted: \$(sala_post_destination)' "$ROOT/lib/op.sh"); [ "$q" = 1 ] && ok "op's inbox line prints sala_post_destination" || bad "inbox line: $q"

# ── the scan ──
cd "$ROOT" || exit 1
files=$( { git ls-files docs bin lib contrib README.md CONTRIBUTING.md config.example tests/help-snapshot.txt 2>/dev/null \
    || find docs bin lib contrib -type f; } | grep -v -E '^docs/test-coverage\.md$|\.(png|svg|ico|woff2?)$' | sort -u)
[ -n "$files" ] && ok "scan: $(echo "$files" | wc -l) files" || bad "scan: no files"

# apps the shipped config.example itself names, plus a tiny generic list
named=$(grep -o -E '[a-z0-9]+(-[a-z0-9]+)*-app\b|sala-admin' config.example | sort -u)
generic='slack same next'

CHANNEL_RE='(?<![A-Za-z0-9&_/"\x27$\\#(\[{<=:.-])#[a-z][a-z0-9]*(-[a-z0-9]+)+\b'
printf '%s\n' 'the result goes to #stale-name now' 'a ${1#prefix-x} and (#anchor-x) and <repo>#12' | grep -c -P "$CHANNEL_RE" | grep -qx 1 && ok "the channel pattern catches a literal and passes an expansion, an anchor, an issue number" || bad "channel pattern"
hits=$(echo "$files" | xargs grep -n -P "$CHANNEL_RE" 2>/dev/null | grep -v -E '^\S+:[0-9]+:#!' || true)
[ -z "$hits" ] && ok "no file names a Slack channel as #some-name" || bad "a channel literal:"$'\n'"$(echo "$hits" | cut -c1-200 | head -20)"

hits=$(echo "$files" | xargs grep -n -i -E 'briefing channel|sala-briefing channel' 2>/dev/null || true)
[ -z "$hits" ] && ok "no file says 'briefing channel'" || bad "a stale channel name:"$'\n'"$(echo "$hits" | cut -c1-200 | head -20)"

bad_apps=""
while IFS=: read -r f n name; do
    [ -n "$name" ] || continue
    case " $generic " in *" $name "*) continue;; esac
    echo "$named" | grep -qx -- "$name" && continue
    bad_apps+="$f:$n: app \"$name\""$'\n'
done < <(echo "$files" | xargs grep -n -E 'Slack|BRIEFING_BOT|alert destination|direct message|\bDM\b' 2>/dev/null \
    | grep -o -E '^[^:]+:[0-9]+:|\bthe [a-z][a-z0-9]*(-[a-z0-9]+)* app\b|\b[a-z0-9]+(-[a-z0-9]+)*-app\b' \
    | awk -F: 'NF==3 && $3=="" {loc=$1":"$2; next} {print loc":"$0}' \
    | sed -E 's/^([^:]+:[0-9]+):(the )?/\1:/; s/ app$//' | sed -E 's/^([^:]+):([0-9]+):/\1:\2:/')
[ -z "$bad_apps" ] && ok "every app a file names is one config.example names" || bad "an app name config.example does not carry:"$'\n'"$bad_apps"
exit $fail
