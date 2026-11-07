# lib/alert.sh — post an alert to the owner the way sala's own alerts go, for a check that runs without Claude.
#
#   salamander alert "<headline>" ["<line>"…]
#   salamander alert --help | -h          print the usage and exit 0: nothing is posted or logged, no notify command is needed
#   salamander alert -- "<headline>" …    `--` as the first argument ends option handling, so a headline may start with `-`
#
# Only the exact words `--help` and `-h`, as the FIRST argument, are options; any other first argument (a headline that starts
# with `-` included, such as "-h failed" or "--helpful") is the headline and posts as before.
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
usage: salamander alert "<headline>" ["<line>"…]
       salamander alert --help | -h
       salamander alert -- "<headline>" ["<line>"…]

Post an alert the way sala's own alerts go (SALA_NOTIFY_CMD / SALA_WATCH_NOTIFY_CMD), for a check that runs without
Claude, such as a systemd user unit. The headline is posted in bold behind a warning sign, then one bullet per line.
A URL in the headline stays outside the bold: "⚠️ *text* → URL".
--help and -h (as the first argument) print this text and exit 0, posting and logging nothing. `--` as the first
argument ends option handling: the next argument is the headline, even if it starts with `-`.

exit: 0 posted · 1 the notify command failed · 2 usage · 3 no notify command configured
USAGE
}
case "${1:-}" in
    --help|-h) alert_usage; exit 0 ;;
    --) shift ;;
esac
[ -n "${1:-}" ] || { echo 'usage: salamander alert "<headline>" ["<line>"…]' >&2; exit 2; }
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
sala_post_text "$head" "$@" | sala_send_post "$cmd" >/dev/null 2>&1; rc=$?
echo "[$(date -Is)] exit $rc: $head" >> "$ALOG"
[ "$rc" = 0 ] || { echo "salamander alert: the notify command failed (exit $rc)" >&2; exit 1; }
exit 0
