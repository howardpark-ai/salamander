# lib/dm.sh — `sala dm`: post a message into a Slack app's Direct Message with the owner, as that app, with the app's bot token.
# Sourced by bin/salamander, which then calls dm_main (the functions are defined here and nothing runs on source, so a test can call one).
#
#   salamander dm <app> [--thread <ts>] [TEXT|-]      post TEXT (an argument, or stdin when TEXT is `-` or absent) as <app>
#   salamander dm --set-token [<app> | --all]         store the app's bot token (hidden prompt, in the owner's own terminal); with no app, or
#                                                     --all, ask for each app in SALA_DM_APPS in turn
#   salamander dm --check <app>                       auth.test with the stored token: the bot user id and the team
#   salamander dm --help | -h
#
# Why it exists: the incoming webhooks `sala alert` posts through (contrib/briefing/post-stdin.sh) reach one channel each and cannot start
# a thread in a Direct Message. A Slack app's bot token (xoxb-…) can: conversations.open (the app's DM with the member) gives the channel,
# chat.postMessage posts into it, and the message appears in the app's Messages tab.
#
# Settings (config.example): SALA_DM_APPS (the app names allowed), SALA_DM_USER_ID (the member to message), SALA_DM_TOKEN_DIR (where the
# token files are), SALA_DM_API_BASE (the Slack API's base URL; a test points it at a local server).
#
# THE TOKEN: read from ${SALA_DM_TOKEN_DIR}/slack-bot-token-<app> (mode 600 or stricter, else refused), held in a shell variable and handed
# to curl through its config on stdin (`curl -K -`, written by the printf builtin), so it is in no process's argument list, in no log, and in
# no output. A Slack error prints Slack's error code only.
# THE MESSAGE: an argument is written to a file as it came, and the stdin form is the safe one for anything with quotes or backticks; the
# JSON body is built by python3 from that file, so no text is ever parsed as shell or spliced into a command.
# THE CHANNEL: conversations.open's answer is cached per app ($SALA_STATE_DIR/dm/<app>.channel) together with the member id and the API base it
# was opened for (`<user id> <api base> <channel>`, tab-separated): a changed SALA_DM_USER_ID or SALA_DM_API_BASE, or an old file that holds a
# channel id only, is no cache, and the DM is opened again. One Slack rejects as channel_not_found or is_archived is dropped and opened again, once.
# Exit: 0 posted (stdout: the message's ts, so a caller can thread under it) · 1 Slack said no · 2 usage · 3 setting or token problem ·
# 4 network (curl failed or Slack answered 5xx, after one retry). A 5xx or a timeout is tried once more, which can post a message twice
# when Slack took the first and the answer was lost; the retry is the price of not losing a message to one hiccup.
# Bounds: a message over 39000 characters (Slack's limit is about 40000) is refused, never cut; curl gets SALA_DM_TIMEOUT seconds (15).

DM_MAX_CHARS=39000
dm_usage() {
    cat <<'USAGE'
usage: sala dm <app> [--thread <ts>] [TEXT|-]
       sala dm --set-token [<app> | --all]
       sala dm --check <app>
       sala dm --help | -h

Post a message into the Direct Message between a Slack app and the owner, as that app (the app's Messages tab), with the app's bot token.
TEXT is the message, as one argument; with `-` or with no TEXT the message is read from stdin, which is the safe form for text with quotes,
backticks or $( ). --thread <ts> (or --thread=<ts>) replies in the thread of the message with that ts; options come before TEXT, and a TEXT that starts with -- is refused
unless it comes after a -- (sala dm <app> -- "--text"), or is sent on stdin.
A digit run between colons, as in a time like 04:00:, gets an invisible zero-width space before its closing colon so Slack shows it as typed rather than as an emoji code.
On success the posted message's ts is printed on stdout, so a caller can thread under it. A message over 39000 characters is refused.
<app> is one of the names in SALA_DM_APPS (letters, digits and dashes, not starting with a dash). Settings, in ~/.config/salamander/config:
  SALA_DM_APPS       the app names allowed, space-separated (no default: none is allowed until it is set)
  SALA_DM_USER_ID    the Slack member id the message goes to
  SALA_DM_TOKEN_DIR  where the token files are (default ~/.config/sala-briefing); the token of <app> is slack-bot-token-<app>, mode 600
  SALA_DM_API_BASE   the Slack API's base URL (default https://slack.com/api)
--set-token <app>  asks for the app's bot token (xoxb-…) with a hidden prompt and stores it (mode 600, directory 700); needs a terminal.
--set-token        with no app (or --all) asks for each app in SALA_DM_APPS in turn, one hidden prompt each, and stores each the same way. An empty
                   line skips that app and keeps its stored token; a value that is no bot token is refused for that app and the next is asked.
                   It ends with each app's outcome (stored, skipped or refused); exit 1 when any was refused, else 0.
--check <app>     calls auth.test with the stored token and prints the bot user id and the team, never the token.

exit: 0 posted · 1 Slack answered an error (its code is printed) · 2 usage · 3 a setting or the token file is missing or refused · 4 network
USAGE
}

dm_err() { echo "sala dm: $*" >&2; }

dm_apps_has() {   # <name> → 0 when SALA_DM_APPS lists it (read into an array: a name is never globbed)
    local list=() a
    read -ra list <<< "${SALA_DM_APPS:-}"
    for a in "${list[@]}"; do [ "$a" = "$1" ] && return 0; done
    return 1
}

dm_check_app() {   # <name> → 0 when it is a valid, listed app name; else the message and 2 (usage) or 3 (no list set)
    # (no leading dash: a name such as --all or -h would read as an option, so `--set-token --all` can only ever mean every app)
    if ! [[ ${1:-} =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]; then dm_err "the app name is letters, digits and dashes, and does not start with a dash, got '${1:-}'"; return 2; fi
    if [ -z "${SALA_DM_APPS//[[:space:]]/}" ]; then dm_err "no apps are allowed: set SALA_DM_APPS (space-separated names) in $SALA_CONFIG"; return 3; fi
    dm_apps_has "$1" || { dm_err "unknown app '$1' (SALA_DM_APPS lists: $SALA_DM_APPS)"; return 2; }
}

dm_token_dir() { printf '%s' "${SALA_DM_TOKEN_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/sala-briefing}"; }

# dm_read_token <app> → DM_TOKEN; returns 3 with a message (never the token) when the file is missing, empty, readable by group or other, or not a bot token
dm_read_token() {
    local f mode tok=""
    f="$(dm_token_dir)/slack-bot-token-$1"
    [ -f "$f" ] || { dm_err "no token file for $1: $f is missing (store it: sala dm --set-token $1)"; return 3; }
    mode=$(stat -c %a "$f" 2>/dev/null) || { dm_err "cannot read the mode of $f"; return 3; }
    if (( 8#$mode & 8#077 )); then dm_err "$f is mode $mode: it must be readable by its owner only (chmod 600 $f)"; return 3; fi
    { IFS= read -r tok < "$f"; } 2>/dev/null || :
    tok=${tok//[[:space:]]/}
    [ -n "$tok" ] || { dm_err "the token file $f is empty (store it: sala dm --set-token $1)"; return 3; }
    [[ $tok =~ ^xoxb-[A-Za-z0-9-]+$ ]] || { dm_err "the token file $f does not hold a bot token (xoxb-…)"; return 3; }
    DM_TOKEN=$tok
}

# dm_write_token <app> <value>: the token file, atomically: a temporary file beside it (umask 077, so never readable by others), mode 600, then mv.
# The directory is created 700 when it is new; an existing one is left as it is. The value goes through the printf builtin and a redirect only.
dm_write_token() {
    local app=$1 val=$2 dir tmp
    dir=$(dm_token_dir)
    if [ ! -d "$dir" ]; then ( umask 077; mkdir -p "$dir" ) || return 1; chmod 700 "$dir" || return 1; fi
    [ ! -d "$dir/slack-bot-token-$app" ] || return 1   # (mv would move the file into a folder of that name)
    tmp=$( umask 077; mktemp "$dir/.slack-bot-token-$app.XXXXXX" ) || return 1
    if ! { printf '%s\n' "$val" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$dir/slack-bot-token-$app"; }; then rm -f "$tmp"; return 1; fi
}

DM_T=""   # the scratch folder of one run (mode 700), removed by dm_main on every way out
dm_scratch() { [ -n "$DM_T" ] || DM_T=$( umask 077; mktemp -d "${TMPDIR:-/tmp}/sala-dm.XXXXXX" ) || return 1; }

# dm_http <api method> <body file>: one POST with the token in curl's config on stdin. The response body lands in $DM_T/resp, the status in
# DM_HTTP. Returns curl's exit status (0: an answer came, whatever it says).
# `-q` is curl's first argument, so its default config (~/.curlrc, which could turn on a trace or a verbose log file) is never read: with the
# token on stdin's config, a trace file would record it.
dm_api_base() { local b=${SALA_DM_API_BASE:-https://slack.com/api}; printf '%s' "${b%/}"; }
dm_http() {
    local rc base
    base=$(dm_api_base)
    DM_HTTP=$(printf 'header = "Authorization: Bearer %s"\n' "$DM_TOKEN" | curl -q -sS -K - --proto '=http,https' --max-time "${SALA_DM_TIMEOUT:-15}" \
        -H 'Content-Type: application/json; charset=utf-8' --data-binary @"$2" -o "$DM_T/resp" -w '%{http_code}' "$base/$1" 2>/dev/null)
    rc=$?
    [ "$rc" = 0 ] || DM_HTTP=0
    return "$rc"
}

# dm_api <method> <body file>: dm_http with one retry on a transport failure or a 5xx, then Slack's answer parsed into DM_CH, DM_TS, DM_UID,
# DM_USER, DM_TEAM, DM_TEAMID, or DM_ERR. Returns 0 ok:true · 1 ok:false (DM_ERR) · 4 network, a 5xx or an answer that is not Slack's.
dm_api() {
    local try rc line kind
    for try in 1 2; do
        dm_http "$1" "$2"; rc=$?
        if [ "$rc" = 0 ] && [ "${DM_HTTP:0:1}" != 5 ]; then break; fi
        [ "$try" = 1 ] && sleep "${SALA_DM_RETRY_WAIT:-1}"
    done
    if [ "$rc" != 0 ]; then
        if [ "$rc" = 28 ]; then dm_err "network: Slack did not answer within ${SALA_DM_TIMEOUT:-15} s"; else dm_err "network: could not reach Slack (curl exit $rc)"; fi
        return 4
    fi
    [ "${DM_HTTP:0:1}" != 5 ] || { dm_err "network: Slack answered HTTP $DM_HTTP"; return 4; }
    line=$(python3 -I -c '
import json, re, sys
def clean(v, n=80):
    return re.sub(r"[\x00-\x1f\x7f]", " ", v)[:n] if isinstance(v, str) and v else "-"
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    assert isinstance(d, dict)
except Exception:
    print("bad"); sys.exit(0)
if d.get("ok") is True:
    ch = d.get("channel")
    if isinstance(ch, dict): ch = ch.get("id")
    print("\t".join(["ok", clean(ch), clean(d.get("ts")), clean(d.get("user_id")), clean(d.get("user")), clean(d.get("team")), clean(d.get("team_id"))]))
else:
    e = d.get("error")
    print("err\t" + (e if isinstance(e, str) and re.fullmatch(r"[A-Za-z0-9_.-]{1,64}", e) else "unknown_error"))
' "$DM_T/resp" 2>/dev/null)
    IFS=$'\t' read -r kind DM_CH DM_TS DM_UID DM_USER DM_TEAM DM_TEAMID <<< "$line"
    case "$kind" in
        ok) return 0 ;;
        err) DM_ERR=$DM_CH; return 1 ;;
        *) dm_err "network: Slack's answer (HTTP $DM_HTTP) was not JSON"; return 4 ;;
    esac
}

dm_slack_err() { dm_err "slack error: $DM_ERR"; }

# the channel cache: $SALA_STATE_DIR/dm/<app>.channel holds one line, `<user id> <api base> <channel id>` (tab-separated), bound to the member
# and the API base it was opened for; any other shape (an old file with the channel id alone included) is no cache
dm_cache_file() { printf '%s' "$SALA_STATE_DIR/dm/$1.channel"; }
dm_cache_read() {   # <app> → DM_CHANNEL; 1 when there is none, it is not this member's and this API's, or it is not a channel id
    # only the first line counts (later lines are ignored); it is split on tabs by hand, never by `read`, whose IFS would take a run of tabs for one
    # separator and let an empty field shift the others: exactly three fields, or no cache
    # bash drops a NUL byte when it reads, so `D0ABC<NUL>JUNK` would pass for `D0ABCJUNK` or a NUL after the id for a clean line: a first line holding any NUL is no cache
    local f line="" tab=$'\t' re u b c; f=$(dm_cache_file "$1")
    [ "$(head -n 1 -- "$f" 2>/dev/null | tr -cd '\0' | wc -c)" = 0 ] || return 1
    { IFS= read -r line < "$f" || [ -n "$line" ]; } 2>/dev/null || return 1
    re="^([^$tab]*)$tab([^$tab]*)$tab([^$tab]*)\$"
    [[ $line =~ $re ]] || return 1
    u=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]} c=${BASH_REMATCH[3]}   # the next =~ resets BASH_REMATCH
    [ -n "$u" ] && [ "$u" = "${SALA_DM_USER_ID:-}" ] && [ "$b" = "$(dm_api_base)" ] || return 1
    [[ $c =~ ^[CDG][A-Z0-9]+$ ]] || return 1
    DM_CHANNEL=$c
}
dm_cache_write() {   # <app> <channel>: atomic, mode 600 in a 700 folder; a failure is not the post's failure
    local f tmp; f=$(dm_cache_file "$1")
    ( umask 077; mkdir -p "${f%/*}" ) 2>/dev/null || return 0
    tmp=$( umask 077; mktemp "${f%/*}/.$1.XXXXXX" 2>/dev/null ) || return 0
    { printf '%s\t%s\t%s\n' "${SALA_DM_USER_ID:-}" "$(dm_api_base)" "$2" > "$tmp" && mv -f "$tmp" "$f"; } 2>/dev/null || rm -f "$tmp"
    return 0
}

# dm_open <user id>: conversations.open → DM_CH (the channel id); returns dm_api's
dm_open() {
    local rc
    printf '{"users":"%s"}' "$1" > "$DM_T/open.json"
    dm_api conversations.open "$DM_T/open.json"; rc=$?
    [ "$rc" = 1 ] && dm_slack_err
    [ "$rc" = 0 ] || return "$rc"
    [[ $DM_CH =~ ^[CDG][A-Z0-9]+$ ]] || { dm_err "slack error: conversations.open returned no channel"; return 1; }
    return 0
}

# dm_body <text file> <channel> <thread ts or ""> → the JSON body in $DM_T/post.json. python3 does the quoting: the text is never parsed by a shell.
dm_body() {
    python3 -I -c '
import json, sys
text = open(sys.argv[1], "rb").read().decode("utf-8")
d = {"channel": sys.argv[2], "text": text}
if sys.argv[3]: d["thread_ts"] = sys.argv[3]
sys.stdout.buffer.write(json.dumps(d, ensure_ascii=False).encode("utf-8"))
' "$1" "$2" "$3" > "$DM_T/post.json"
}

dm_cmd_post() {   # <app> <thread ts or ""> <text file>
    local app=$1 thread=$2 tf=$3 ch="" cached=0 attempt rc
    if dm_cache_read "$app"; then ch=$DM_CHANNEL; cached=1; fi
    for attempt in 1 2; do
        if [ -z "$ch" ]; then
            dm_open "$SALA_DM_USER_ID"; rc=$?; [ "$rc" = 0 ] || return "$rc"
            ch=$DM_CH; cached=0; dm_cache_write "$app" "$ch"
        fi
        dm_body "$tf" "$ch" "$thread" || { dm_err "could not build the message"; return 2; }
        dm_api chat.postMessage "$DM_T/post.json"; rc=$?
        if [ "$rc" = 0 ]; then
            [[ $DM_TS =~ ^[0-9]+\.[0-9]+$ ]] || { dm_err "slack error: no message ts in the answer"; return 1; }
            printf '%s\n' "$DM_TS"; return 0
        fi
        if [ "$rc" = 1 ] && [ "$cached" = 1 ] && [ "$attempt" = 1 ] && { [ "$DM_ERR" = channel_not_found ] || [ "$DM_ERR" = is_archived ]; }; then
            rm -f "$(dm_cache_file "$app")"; ch=""; cached=0; continue   # the cached channel is stale: open the DM again, once
        fi
        [ "$rc" = 1 ] && dm_slack_err
        return "$rc"
    done
}

dm_cmd_check() {   # <app>
    local rc
    printf '{}' > "$DM_T/check.json"
    dm_api auth.test "$DM_T/check.json"; rc=$?
    [ "$rc" = 1 ] && dm_slack_err
    [ "$rc" = 0 ] || return "$rc"
    echo "ok: $1 is bot user $DM_UID in team $DM_TEAM ($DM_TEAMID)"
}

# dm_store_one <app> <value>: the one validation and the one write every --set-token path uses; 0 stored, 2 not a bot token, 3 could not write.
# The value is never printed.
dm_store_one() {
    local app=$1 val=${2//[[:space:]]/}
    [[ $val =~ ^xoxb-[A-Za-z0-9-]+$ ]] || { dm_err "that is not a bot token (it must start with xoxb-); nothing stored"; return 2; }
    dm_write_token "$app" "$val" || { dm_err "could not write $(dm_token_dir)/slack-bot-token-$app"; return 3; }
}

# dm_echo_off / dm_echo_on: keep the terminal's echo off for a whole --set-token run, not only while `read -s` is reading. `read -s` turns echo off
# only for the moment it reads, so a token pasted ahead (the owner pastes the next one before its prompt is up) would be printed in clear in
# the gap between two reads. With stdin not a terminal (a test, a pipe) nothing is done. dm_echo_off saves the settings (`stty -g`) and
# restores them on every way out (EXIT, INT, TERM, HUP); dm_echo_on restores them and clears the traps on a normal return. When stdin IS a
# terminal and echo cannot be turned off (`stty -g` or `stty -echo` fails), dm_echo_off puts back whatever it changed and returns 1: the callers
# refuse before any prompt, because a prompt with echo on would show a pasted token.
# dm_echo_on first throws away the input still queued in the terminal (lines pasted ahead and never read: after Ctrl-D, an abort, a surplus
# line). Left there, the invoking shell would read them once echo is back, print them and run them, and a token would end in its history or in
# a 'command not found' line. `read -rs -t 0.05 -n 4096` takes what is pending (it reads in non-canonical mode, so a half-typed line goes too)
# and times out at once when nothing is; the drain is bounded (about a second), so a flood cannot hold sala.
DM_STTY=""
dm_drain_input() {
    [ -t 0 ] || return 0
    local junk="" n=0 t0=${EPOCHREALTIME:-}
    while IFS= read -rs -t 0.05 -n 4096 junk; do
        n=$((n + 1))
        if [ -n "$t0" ]; then [ $(( ${EPOCHREALTIME/./} - ${t0/./} )) -lt 1000000 ] || break
        else [ "$n" -lt 20 ] || break; fi
    done
}
dm_echo_on() {
    if [ -n "$DM_STTY" ]; then
        dm_drain_input
        stty "$DM_STTY" 2>/dev/null
    fi
    DM_STTY=""; trap - EXIT INT TERM HUP
}
dm_echo_off() {
    [ -t 0 ] || return 0
    DM_STTY=$(stty -g 2>/dev/null) || { DM_STTY=""; return 1; }
    [ -n "$DM_STTY" ] || return 1
    # A signal only exits; the EXIT trap puts the settings back. (Restoring in the signal's own trap is too early: `read -s`, interrupted, then
    # puts back the settings it found, echo off, after the trap has run. The EXIT trap runs after that.)
    trap 'dm_echo_on' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    if ! stty -echo 2>/dev/null; then
        stty "$DM_STTY" 2>/dev/null   # whatever it half did is undone; nothing queued is dropped, nothing was asked yet
        DM_STTY=""; trap - EXIT INT TERM HUP
        return 1
    fi
}

dm_cmd_set_token() {   # <app>
    local app=$1 val="" rc
    if [ ! -t 0 ]; then dm_err "--set-token needs a terminal (the token is typed at a hidden prompt, never taken from a pipe or an argument)"; return 2; fi
    dm_echo_off || { dm_err "cannot turn terminal echo off; nothing was asked"; return 2; }
    printf 'Paste the bot token for %s (xoxb-…; nothing is shown as you paste), then Enter: ' "$app" >&2
    IFS= read -rs val; echo >&2
    dm_echo_on
    dm_store_one "$app" "$val"; rc=$?; val=""
    [ "$rc" = 0 ] || return "$rc"
    echo "stored token for $app"
}

# dm_cmd_set_token_all: --set-token with no app (or --all): the same store for each app in SALA_DM_APPS, in order, one hidden prompt each.
# An empty line skips the app (its stored token is kept); a value the single-app path refuses is refused for that app and the loop goes on;
# Ctrl-D skips the rest. The summary names each app's outcome; the exit is 1 when any app was refused, else 0. Nothing is sent over the network.
dm_cmd_set_token_all() {
    local list=() apps=() a val="" eof=0 i out=() bad=0
    read -ra list <<< "${SALA_DM_APPS:-}"
    for a in "${list[@]}"; do case " ${apps[*]:-} " in *" $a "*) ;; *) apps+=("$a") ;; esac; done   # a name listed twice is asked once
    if [ "${#apps[@]}" = 0 ]; then dm_err "no apps are configured: set SALA_DM_APPS (space-separated names) in $SALA_CONFIG, or name one: sala dm --set-token <app>"; return 2; fi
    if [ ! -t 0 ]; then dm_err "--set-token needs a terminal (the token is typed at a hidden prompt, never taken from a pipe or an argument)"; return 2; fi
    dm_echo_off || { dm_err "cannot turn terminal echo off; nothing was asked"; return 2; }   # once, before the first prompt, and back on after the last: a token pasted ahead is never echoed between two prompts
    echo "Storing the bot token of each app in SALA_DM_APPS (${#apps[@]}), one at a time. Nothing is shown as you paste; Enter alone skips an app and keeps its stored token; Ctrl-D skips the rest." >&2
    for a in "${apps[@]}"; do
        if [ "$eof" = 1 ]; then out+=("$a: skipped"); continue; fi
        if ! dm_check_app "$a"; then out+=("$a: refused"); bad=1; continue; fi
        printf 'token for %s (Bot User OAuth Token, xoxb-...): ' "$a" >&2
        if IFS= read -rs val; then :; else eof=1; val=""; fi
        echo >&2
        val=${val//[[:space:]]/}
        if [ -z "$val" ]; then
            echo "skipped $a: nothing entered, its stored token (if any) is kept"; out+=("$a: skipped")
        elif dm_store_one "$a" "$val"; then
            echo "stored token for $a"; out+=("$a: stored")
        else
            out+=("$a: refused"); bad=1
        fi
        val=""
    done
    dm_echo_on
    echo "summary:"
    for i in "${out[@]}"; do echo "  $i"; done
    return "$bad"
}

# dm_thread_check <value>: a --thread value is a message ts such as 1700000000.000100; 1 (with the usage line) when it is empty or not one
dm_thread_check() {
    [ -n "$1" ] || { dm_err "--thread needs a message ts, got an empty value"; return 1; }
    [[ $1 =~ ^[0-9]+\.[0-9]+$ ]] || { dm_err "--thread takes a message ts such as 1700000000.000100, got '$1'"; return 1; }
}

dm_main() {
    local app="" thread="" text="" have_text=0 mode=post rc tf sep=0
    case "${1:-}" in
        '') dm_usage >&2; return 2 ;;
        -h|--help|help) dm_usage; return 0 ;;
        --set-token) mode=set; shift ;;
        --check) mode=check; shift ;;
    esac
    if [ "$mode" = set ] && { [ $# = 0 ] || [ "$*" = --all ]; }; then dm_cmd_set_token_all; return $?; fi   # no app, or --all: every app in SALA_DM_APPS
    if [ "$mode" != post ]; then
        [ $# = 1 ] || { dm_err "usage: sala dm --$([ "$mode" = set ] && echo 'set-token [<app> | --all]' || echo 'check <app>')"; return 2; }
        dm_check_app "$1" || return $?
        app=$1
        if [ "$mode" = set ]; then dm_cmd_set_token "$app"; return $?; fi
        dm_read_token "$app" || return $?
        dm_scratch || { dm_err "no scratch folder"; return 3; }
        trap 'rm -rf "$DM_T"' EXIT
        dm_cmd_check "$app"; rc=$?; rm -rf "$DM_T"; DM_T=""; trap - EXIT; return "$rc"
    fi
    app=$1; shift
    while [ $# -gt 0 ]; do
        case "$1" in
            --thread)   # each value is checked where it is parsed, so a later valid --thread cannot overwrite a bad one
                [ $# -ge 2 ] || { dm_err "--thread needs a message ts"; return 2; }
                dm_thread_check "$2" || return 2
                thread=$2; shift 2 ;;
            --thread=*)
                dm_thread_check "${1#--thread=}" || return 2
                thread=${1#--thread=}; shift ;;
            --) sep=1; shift; break ;;
            *) break ;;
        esac
    done
    dm_check_app "$app" || return $?
    if [ $# -gt 1 ]; then dm_err "one TEXT only (quote it, or send it on stdin with -)"; return 2; fi
    # a lone argument that starts with -- and came with no -- before it is a misplaced option (sala dm <app> --check), never a message:
    # refused here, before the scratch folder, the token or any request
    if [ "$sep" = 0 ] && [ $# = 1 ] && [[ $1 == --* ]]; then
        dm_err "'$1' looks like an option, but options come before TEXT; to post text that starts with -- put -- before it, or send it on stdin"
        dm_usage >&2; return 2
    fi
    if [ $# = 1 ] && [ "$1" != - ]; then text=$1; have_text=1; fi
    dm_scratch || { dm_err "no scratch folder"; return 3; }
    trap 'rm -rf "$DM_T"' EXIT
    tf=$DM_T/text
    if [ "$have_text" = 1 ]; then printf '%s' "$text" > "$tf"
    else
        if [ -t 0 ] && [ $# = 0 ]; then dm_err "no TEXT and stdin is a terminal: give the message as TEXT or pipe it in"; rm -rf "$DM_T"; DM_T=""; trap - EXIT; return 2; fi
        head -c 400000 > "$tf"
        if [ "$(stat -c %s "$tf")" -ge 400000 ]; then dm_err "the message is over $DM_MAX_CHARS characters; nothing posted"; rm -rf "$DM_T"; DM_T=""; trap - EXIT; return 2; fi
    fi
    # the message: UTF-8, not empty, at most DM_MAX_CHARS characters (counted as characters, not bytes); trailing newlines are dropped
    python3 -I -c '
import re, sys
b = open(sys.argv[1], "rb").read()
try: t = b.decode("utf-8")
except UnicodeDecodeError: sys.exit(10)
t = t.rstrip("\n")
if not t.strip(): sys.exit(11)
# Slack reads :NN: as an emoji code, so "04:00: the weekly run" showed ":00:" as a gray box: put a zero-width space before the closing colon of a
# digit run that follows a digit, so a time is shown as typed (":100:", ":+1:", ":white_check_mark:", "04:00" and URLs are left alone).
# Done before the length check, so the limit counts what is posted.
t = re.sub(r"(?<=\d):(\d+)(?=:)", lambda m: ":" + m.group(1) + chr(0x200b), t)
if len(t) > int(sys.argv[2]): sys.exit(12)
open(sys.argv[1], "wb").write(t.encode("utf-8"))
' "$tf" "$DM_MAX_CHARS"; rc=$?
    case "$rc" in
        0) ;;
        10) dm_err "the message is not valid UTF-8; nothing posted" ;;
        11) dm_err "the message is empty; nothing posted" ;;
        12) dm_err "the message is over $DM_MAX_CHARS characters (Slack takes about 40000); nothing posted, nothing cut" ;;
        *) dm_err "could not read the message" ;;
    esac
    if [ "$rc" != 0 ]; then rm -rf "$DM_T"; DM_T=""; trap - EXIT; return 2; fi
    if [ -z "${SALA_DM_USER_ID:-}" ]; then dm_err "SALA_DM_USER_ID is not set: set it to the Slack member id the message goes to ($SALA_CONFIG)"; rc=3
    elif ! [[ $SALA_DM_USER_ID =~ ^[UW][A-Z0-9]+$ ]]; then dm_err "SALA_DM_USER_ID is not a Slack member id (U… or W…)"; rc=3
    else
        dm_read_token "$app"; rc=$?
        [ "$rc" = 0 ] && { dm_cmd_post "$app" "$thread" "$tf"; rc=$?; }
    fi
    rm -rf "$DM_T"; DM_T=""; trap - EXIT
    return "$rc"
}
