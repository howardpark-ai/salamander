# lib/alert.sh — post an alert to the owner the way sala's own alerts go, for a check that runs without Claude.
#
#   salamander alert [--channel <name>] "<headline>" ["<line>"…]
#   salamander alert --help | -h          print the usage and exit 0: nothing is posted or logged, no notify command is needed
#   salamander alert [--channel <name>] -- "<headline>" …    `--` ends option handling, so a headline may start with `-`
#
# Options are read only before the headline: `--channel <name>` (or `--channel=<name>`) and `--`. `--help` and `-h` are options only
# as the FIRST argument; any other word that is not one of these (a headline that starts with `-` included, such as "-h failed" or
# "--helpful") is the headline and posts as before.
# A CHANNEL is a short name matching [a-z0-9-]+ (anything else is a usage error, exit 2, and nothing is posted). It reaches the
# notify command as SALA_NOTIFY_CHANNEL=<name> in the command's environment for this one call; without --channel the variable is
# unset. What a channel means is the notify command's business: contrib/briefing/post-stdin.sh sends the post to the Slack webhook
# the config names for it (BRIEFING_WEBHOOK_FILE_<NAME>) and to the default webhook when there is none.
#
# ALERTS THAT NEED NO CLAUDE TURN: a usage limit can stop every API call, and then no alert reaches
# the owner, because every alert path went through a Claude session blocked the same way. sala's posts do not (sala_post →
# SALA_NOTIFY_CMD / SALA_WATCH_NOTIFY_CMD, a plain command), and this verb lends that path to other no-Claude checks. It works from a systemd user unit: the config is read from ~/.config/salamander/config as for
# every verb, and nothing here needs tmux, a pane or a session.
# The post has sala_post's shape: the headline in bold behind ⚠️ (a headline that already holds a `*` is sent as it is), then
# one bullet per line, a line "Details: …" last and unbulleted. Plain words; times in the configured zone.
# A URL in the headline stays OUTSIDE the bold (stackshot's urgent headlines end with an item URL, and Slack took the
# closing `*` into the link). Each URL (http:// or https://, up to a space, `*`, `<`, `>` or `|`) is taken out of the text and the
# URLs follow the bold in order, each behind " → ": "gbrain is late https://x/items/38" posts as "⚠️ *gbrain is late* → https://x/items/38"
# (a separator that ended the text before the URL, such as " —" or ":", goes with it; a headline of URLs only posts as "⚠️ <url> → …").
# A headline that already holds a `*` is still sent as it is, unless a URL touches a `*` ("*text URL*", "*text*URL"): its URLs are then
# moved out the same way ("*text URL*" → "*text* → URL"). Without a URL nothing changes.
# Exit: 0 posted · 1 the notify command failed · 2 usage · 3 no notify command configured. One line per call in
# salamander-alert.log (headline and exit code).
ALOG="$SALA_LOG_DIR/salamander-alert.log"
alert_usage() {
    cat <<'USAGE'
usage: salamander alert [--channel <name>] "<headline>" ["<line>"…]
       salamander alert --help | -h
       salamander alert [--channel <name>] -- "<headline>" ["<line>"…]

Post an alert the way sala's own alerts go (SALA_NOTIFY_CMD / SALA_WATCH_NOTIFY_CMD), for a check that runs without
Claude, such as a systemd user unit. The headline is posted in bold behind a warning sign, then one bullet per line.
A URL in the headline stays outside the bold: "⚠️ *text* → URL".
--channel <name> (also --channel=<name>) names a channel, [a-z0-9-]+ (for example reports): the notify command gets it as
SALA_NOTIFY_CHANNEL=<name> in its environment, and the text is the same. Without it the variable is unset. Options are
read only before the headline.
--help and -h (as the first argument) print this text and exit 0, posting and logging nothing. `--` ends option handling:
the next argument is the headline, even if it starts with `-`.

exit: 0 posted · 1 the notify command failed · 2 usage (a channel name that is not [a-z0-9-]+ included) · 3 no notify command configured
USAGE
}
case "${1:-}" in
    --help|-h) alert_usage; exit 0 ;;
esac
chan=""; chan_given=0
while [ $# -gt 0 ]; do
    case "$1" in
        --channel) [ $# -ge 2 ] || { echo "salamander alert: --channel needs a name" >&2; exit 2; }; chan="$2"; chan_given=1; shift 2 ;;
        --channel=*) chan="${1#--channel=}"; chan_given=1; shift ;;
        --) shift; break ;;
        *) break ;;
    esac
done
if [ "$chan_given" = 1 ] && ! [[ $chan =~ ^[a-z0-9-]+$ ]]; then
    echo "salamander alert: the channel name is lowercase letters, digits and dashes ([a-z0-9-]+), got '$chan'" >&2; exit 2
fi
[ -n "${1:-}" ] || { echo 'usage: salamander alert [--channel <name>] "<headline>" ["<line>"…]' >&2; exit 2; }
head="$1"; shift
# alert_headline <headline> → the headline as posted, in $head (the rules are in the header). Suffixes are matched whole, never
# with ${x%?}: a unit may run in the C locale, where ? is one byte of a multibyte dash.
alert_headline() {
    local raw="$1" re='https?://[^[:space:]*<>|]+' work="$1" u before after urls="" glued=0 text prev
    while [[ $work =~ $re ]]; do
        u="${BASH_REMATCH[0]}"
        while [[ $u == *[.,\;:\!\?\)] ]]; do u="${u%[.,\;:\!\?\)]}"; done   # sentence punctuation after a URL is not part of it
        before="${work%%"$u"*}"; after="${work#*"$u"}"
        case "$before" in *'*') glued=1;; esac
        case "$after" in '*'*) glued=1;; esac
        before="${before%"${before##*[![:space:]]}"}"                       # the space before the URL goes with it
        urls="$urls → $u"; work="$before$after"
    done
    if [ -z "$urls" ]; then
        case "$raw" in *'*'*) head="$raw";; *) head="⚠️ *$raw*";; esac; return
    fi
    case "$raw" in *'*'*) [ "$glued" = 1 ] || { head="$raw"; return; };; esac
    text="$work"; prev=x
    while [ "$text" != "$prev" ]; do                                         # the separator that led to the URL goes with it
        prev="$text"; text="${text%"${text##*[![:space:]]}"}"
        text="${text%—}"; text="${text%–}"; text="${text%→}"; text="${text%[:,;.|>-]}"
    done
    case "$raw" in
        *'*'*) head="$text$urls";;
        *) if [ -n "$text" ]; then head="⚠️ *$text*$urls"; else head="⚠️ ${urls# → }"; fi;;
    esac
}
alert_headline "$head"
cmd="${SALA_NOTIFY_CMD:-${SALA_WATCH_NOTIFY_CMD:-}}"
mkdir -p "$SALA_LOG_DIR"
if [ -z "$cmd" ]; then
    echo "[$(date -Is)] not posted (no SALA_NOTIFY_CMD / SALA_WATCH_NOTIFY_CMD): $head" >> "$ALOG"
    echo "salamander alert: no notify command configured (SALA_WATCH_NOTIFY_CMD in $SALA_CONFIG)" >&2; exit 3
fi
sala_post_text "$head" "$@" | sala_send_post "$cmd" "$chan" >/dev/null 2>&1; rc=$?
echo "[$(date -Is)] exit $rc${chan:+ (channel $chan)}: $head" >> "$ALOG"
[ "$rc" = 0 ] || { echo "salamander alert: the notify command failed (exit $rc)" >&2; exit 1; }
exit 0
