# lib/common.sh — configuration, Claude Code registry/transcript access, tmux helpers.
# Sourced by bin/salamander before the subcommand. Everything Claude-Code-internal that
# the tool depends on is pinned HERE, so a CLI change is a one-file fix:
#   - live registry  ~/.claude/sessions/<pid>.json   fields: pid sessionId name status
#                    statusUpdatedAt tmux bridgeSessionId version
#   - transcripts    ~/.claude/projects/<cwd-slug>/<sessionId>.jsonl   (slug: / and . → -)
#   - task scratch   /tmp/claude-<uid>/<cwd-slug>/<sessionId>/{tasks,subagents}
#   - feedback drafts ~/.claude/feedback/drafts/<id>.json  field status: queued|submitted|discarded|expired
#   - launcher       `claude` on PATH; `claude update` moves a symlink, live processes keep
#                    the old binary → compare the registry's `version` (or the exe's basename)
#                    with the launcher target's basename
# Process inspection goes through the proc_* helpers below (ps/lsof) — no /proc reads elsewhere,
# so the same code runs on Linux and macOS.

SALA_CONFIG="${SALA_CONFIG:-$HOME/.config/salamander/config}"
[ -r "$SALA_CONFIG" ] && . "$SALA_CONFIG"
# a last-good copy of the config: refreshed whenever a readable config names a master, so a lost or
# truncated file can be diffed and restored (`salamander master` and `watch` point at it)
SALA_CONFIG_LASTGOOD="$HOME/.claude/salamander-config.last-good"
if [ -r "$SALA_CONFIG" ] && [ -n "${SALA_MASTER:-}" ]; then   # (cmp -s, read by the shell: a process per salamander call; the config is text)
    _cfg_a=""; _cfg_b=$'\x01none'; { IFS= read -r -d '' _cfg_a < "$SALA_CONFIG"; } 2>/dev/null || :
    if [ -r "$SALA_CONFIG_LASTGOOD" ]; then _cfg_b=""; { IFS= read -r -d '' _cfg_b < "$SALA_CONFIG_LASTGOOD"; } 2>/dev/null || :; fi
    [ "$_cfg_a" = "$_cfg_b" ] || cp -f "$SALA_CONFIG" "$SALA_CONFIG_LASTGOOD" 2>/dev/null || true
    unset _cfg_a _cfg_b
fi
: "${SALA_RC_SESSION:=claude-rc}"                 # tmux session hosting `claude remote-control`
: "${SALA_SHELL_SESSION:=sala-shell}"             # tmux session of the web UI's shell drawer: a plain login bash, never a Claude pane;
                                                  # the web app reads this same setting from the config file and tells the page the name
: "${SALA_RC_NAME:=rc-scratch}"                   # the server's pre-created session title
: "${SALA_RC_CAPACITY:=32}"                       # served sessions (CLI default 32)
: "${SALA_RC_RESTART_DELAY:=30}"                  # seconds between server relaunches
: "${SALA_TZ:=}"                                  # timezone for names/logs and every time sala shows (an IANA name); empty = this machine's local time
: "${SALA_BACK_CWD:=}"                            # where `spawn --role back` starts without --cwd (the directory of the background brief); empty = $HOME
: "${SALA_SCOPES:=}"                              # the scopes sessions are named by (<scope>-<project>-…), space-separated; empty = none. The web UI takes them from this first, and from stackshot's own settings file only when this is empty or unset
: "${SALA_DEFAULT_SCOPE:=}"                       # the scope a page outside every scope's directory is named in; empty = the first of SALA_SCOPES
: "${SALA_HELP_SESSION:=}"                       # web UI only: the session the overview's Get Help chip opens; empty = no chip
: "${SALA_BRAND_SUFFIX:=}"                        # web UI only: what follows "salamander" in its title bar (salamander : <suffix>); empty = "salamander" alone
: "${SALA_OWNER_NAME:=the owner}"                # what runtime text calls the human running this machine ("the owner" reads naturally in "<name>'s words"); it is also the name in the `[for <name>]` line-1 marker, so it must equal stackshot's [instance] owner. The web app reads it the same way
# cleaned once, here: the name lands inside double-quoted strings, a remote shell's -p "..." and sed/awk programs, so only letters, digits, space . _ ' - stay
SALA_OWNER_NAME=$(printf '%s' "$SALA_OWNER_NAME" | tr -cd "[:alnum:] ._'-")
SALA_OWNER_NAME="${SALA_OWNER_NAME:0:40}"; [ -n "${SALA_OWNER_NAME//[[:space:]]/}" ] || SALA_OWNER_NAME="the owner"
export SALA_OWNER_NAME                            # python helpers (guard, question, permissions) read it from the environment
: "${SALA_LOG_DIR:=$HOME/.claude}"                # revive/rc logs + rc stop marker
: "${SALA_RESURRECT_DIR:=$HOME/.local/share/tmux/resurrect}"   # tmux-resurrect saves (the pane map lived here once; a symlink stays)
: "${SALA_RESURRECT_SAVE:=$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh}"   # full snapshot (spawn runs it)
: "${SALA_CLAUDE:=$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")}"
: "${SALA_SPAWN_PREFIX:=scratch}"                 # auto-generated name prefix
: "${SALA_SNAPSHOT_CMD:=}"                        # replaces the direct save.sh call in `snapshot` (e.g. a systemd user service)
: "${SALA_SNAPSHOT_DELAY:=4}"                     # seconds a `snapshot` waits to coalesce a burst of events
: "${SALA_FLEET_HOSTS:=}"                         # ssh aliases `update --fleet` also updates (CLI only, no panes)
: "${SALA_FLEET_POST_CMD:=}"                      # (older name; SALA_POST_UPDATE_CMD supersedes it)
: "${SALA_POST_UPDATE_CMD:=$SALA_FLEET_POST_CMD}"  # run after ANY CLI update attempt (local recycle --update, update --fleet, provision): e.g. bump a version dashboard
: "${SALA_POST_RECYCLE_CMD:=}"                    # run once at the end of every recycle and clean reboot of THIS box (see post_recycle_hook)
: "${SALA_MASTER:=}"                              # tmux session `watch` keeps alive and bridged (empty = watch does nothing)
: "${SALA_WATCH_COOLDOWN:=600}"                   # seconds before `watch` repeats the same heal
: "${SALA_WATCH_NOTIFY_CMD:=}"                    # `watch` pipes each heal/alert message into this (sh -c)
: "${SALA_NO_RELAUNCH:=}"                         # tmux sessions sala never relaunches or restores (space-separated; see no_relaunch)
: "${SALA_RETRY_EVERY:=300}"                      # recycle: seconds between retries of transiently skipped panes
: "${SALA_RETRY_WINDOW:=7200}"                     # recycle: how long the retry worker keeps trying
: "${SALA_LATER_RETELL:=3600}"                     # watch, deferred list: seconds a held pane waits before it is told again
: "${SALA_LATER_RETELL_MAX:=3}"                    # watch, deferred list: how many times it is told again, at most
: "${SALA_LATER_LIMIT:=10800}"                     # watch, deferred list: seconds held before one post names the pane and its stuck commands
# the flag, the job and the waits (Wed Oct 28th 2026; "recycle sets" below). 0 turns a wait off.
: "${SALA_RECYCLE_GATHER:=600}"                    # watch: a flag raised while a job is unfinished waits until this many seconds pass with no newer flag ...
: "${SALA_RECYCLE_GATHER_MAX:=1800}"               # ... and never longer than this after the first flag gathered, then the job resets ONCE (lib/watch.sh, recycle_job_gate)
: "${SALA_RECYCLE_REST:=1800}"                     # a pane relaunched less than this long ago is not relaunched again for a routine flag (recycle_rest_left)
: "${SALA_SELF_WAIT:=900}"                         # recycle: how long the self-worker waits for the invoking pane to go idle
: "${SALA_EXIT_WAIT:=30}"                          # relaunch: seconds to wait for a typed /exit to land (the pane back at its shell)
: "${SALA_RESUME_WAIT:=30}"                        # relaunch: seconds to wait for the resumed claude to come up in its pane
: "${SALA_IDLE_SETTLE:=10}"                        # is_idle: a registry row idle for less than this many seconds still counts as busy
: "${SALA_HOLD_SETTLE:=3}"                         # revive: seconds between the inbox holds (every pane of the sweep) and the first /exit: a line handed out just before the hold becomes a turn the idle re-check sees
: "${SALA_SPAWN_SETTLE:=3}"                        # spawn: seconds after claude starts before /rename is typed (the composer ready)
: "${SALA_RENAME_SETTLE:=5}"                       # spawn: seconds after /rename before the registry is read for the new name
: "${SALA_HEARTBEAT_REPO:=}"                      # `heartbeat` publishes into this git checkout (empty = off); see lib/heartbeat.sh
: "${SALA_HEARTBEAT_DIR:=}"                       # store path inside that repo
: "${SALA_FLEET_NAMES:=}"                         # TSV hostname → fleet name → letter (heartbeat)
SALA_REG_DIR="$HOME/.claude/sessions"
SALA_PROJECTS="$HOME/.claude/projects"
# sala's own state lives in the XDG state dir (convention): the pane map (a ledger, see below) with its log,
# freeze files and map-history/. It was $SALA_RESURRECT_DIR/claude-pane-map.tsv until then; ledger_migrate (the end of
# this file) moves it once and leaves a symlink there, so tmux-resurrect-era tooling still finds it.
SALA_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/salamander"
: "${SALA_SIDECAR:=$SALA_STATE_DIR/pane-map.tsv}"
SALA_SIDECAR_OLD="$SALA_RESURRECT_DIR/claude-pane-map.tsv"
SALA_DRAFTS_DIR="$HOME/.claude/feedback/drafts"
SALA_READY_DIR="$HOME/.claude/salamander-ready"     # `ready` markers, one per conversation uuid
: "${SALA_READY_TTL:=3600}"                          # a ready marker older than this is ignored
: "${SALA_READY_WAIT:=90}"                           # retry worker: how long to wait for a `ready` pane's turn to end
: "${SALA_BOOT_GRACE:=900}"                          # post-boot report: wait this long after boot for revive's summary …
: "${SALA_BOOT_DEADLINE:=1800}"                      # … and this long for an idle master, then deliver anyway (or notify)
: "${SALA_BOOT_AUDIT:=}"                             # what the master should check after a boot (appended to the report)
SALA_BOOT_REC="$SALA_LOG_DIR/salamander-boot-revive" # the first full revive of each boot: boot id, time, summary
# THE BUSY RECORD and THE WAITING FLAG (lib/hook.sh): two Claude Code
# settings hooks give the busy check an exact answer and give a session word of a relaunch waiting for it. Their state:
SALA_BUSY_DIR="$SALA_STATE_DIR/busy"         # busy/<uuid>: what the Stop hook found in flight when the session's last turn ended
SALA_WAITING_DIR="$SALA_STATE_DIR/waiting"   # waiting/<uuid>: a relaunch sala started waits for this pane (+ <uuid>.told once its hook said so)
# the line the PostToolUse hook adds to a waiting session's context, once per relaunch;
# <what> becomes the relaunch's kind in words (relaunch_what below). One place for the text: here, or the config's override.
[ -n "${SALA_RELAUNCH_WAITING_TEXT:-}" ] || SALA_RELAUNCH_WAITING_TEXT='[sala] A <what> is waiting for this session. Bring your work to a checkpoint. Stop your own background watches (TaskStop) and put what they were waiting for in a `sala note "<step>"` before `sala ready`. If a step must wait until after the relaunch, leave it with `sala note "<step>"` (or set the board item'\''s recycle flag), then run `sala ready` as the turn'\''s last call.'

cs_print_config() {
    for v in SALA_CONFIG SALA_RC_SESSION SALA_SHELL_SESSION SALA_RC_NAME SALA_RC_CAPACITY SALA_RC_RESTART_DELAY SALA_TZ SALA_BACK_CWD SALA_SCOPES SALA_DEFAULT_SCOPE SALA_BRAND_SUFFIX SALA_HELP_SESSION SALA_OWNER_NAME SALA_LOG_DIR \
             SALA_RESURRECT_DIR SALA_RESURRECT_SAVE SALA_CLAUDE SALA_SPAWN_PREFIX SALA_SNAPSHOT_CMD SALA_SNAPSHOT_DELAY SALA_FLEET_HOSTS SALA_POST_UPDATE_CMD SALA_POST_RECYCLE_CMD SALA_MASTER SALA_WATCH_COOLDOWN SALA_WATCH_NOTIFY_CMD SALA_RETRY_EVERY SALA_RETRY_WINDOW SALA_READY_TTL SALA_READY_WAIT SALA_RELAUNCH_WAITING_TEXT SALA_BOOT_GRACE SALA_BOOT_DEADLINE SALA_HEARTBEAT_REPO SALA_HEARTBEAT_DIR SALA_FLEET_NAMES SALA_REG_DIR SALA_PROJECTS SALA_STATE_DIR SALA_SIDECAR SALA_LEDGER_LOG SALA_SESSIONS SALA_SESSIONS_FILE SALA_MOD_DIR SALA_MOD_WAIT \
             SALA_LANES SALA_LANE_API_KEY_FILE SALA_LANE_API_WORKSPACE_FILE SALA_LANE_API_MCP_CONFIG SALA_LANE_TEAM_DIR SALA_LANE_SDK_PIN SALA_LANE_SDK_CMD \
             SALA_LANE_BEDROCK_PROFILE SALA_LANE_BEDROCK_CREDENTIALS_FILE SALA_LANE_BEDROCK_PREFIX SALA_LANE_BEDROCK_OPUS_MODEL SALA_LANE_BEDROCK_SONNET_MODEL SALA_LANE_BEDROCK_HAIKU_MODEL \
             SALA_LANE_AWSPLATFORM_PROFILE SALA_LANE_AWSPLATFORM_CREDENTIALS_FILE SALA_LANE_AWSPLATFORM_WORKSPACE_ID SALA_LANE_AWSPLATFORM_OPUS_MODEL SALA_LANE_AWSPLATFORM_SONNET_MODEL SALA_LANE_AWSPLATFORM_HAIKU_MODEL \
             SALA_LANE_MAX_SUBSCRIPTION SALA_LANE_MAX_ORG SALA_LANE_TEAM_SUBSCRIPTION SALA_LANE_TEAM_ORG SALA_MODELS SALA_JOB_LANE SALA_STACKSHOT_WEB; do
        printf '%-20s %s\n' "$v" "${!v}"
    done
    printf '%-20s %s\n' "lane default" "$(lane_default)"   # state, not config (sala lane default <lane>; lanes above)
    printf '%-20s %s\n' SALA_SESSION_URL "$(session_url_template)"   # the template in force (unset → a default; SESSION LINKS below)
}

# cs_date <fmt> [date-args…] — date in SALA_TZ (or local)
cs_date() { if [ -n "$SALA_TZ" ]; then TZ="$SALA_TZ" date "$@"; else date "$@"; fi; }
cs_tzlabel() { [ -n "$SALA_TZ" ] && cs_date '+%Z' || date '+%Z'; }

die() { echo "✗ $*" >&2; exit 1; }
# _hostname_r <var> → this box's hostname as `hostname` gives it (the kernel's, /proc/sys/kernel/hostname; the hostname process only without /proc).
# $HOSTNAME is not used: bash honours one exported into the environment, which can be stale. _SALA_HN holds it for the whole run.
_hostname_r() { local _hn_=""; { read -r _hn_ < /proc/sys/kernel/hostname; } 2>/dev/null || :; [ -n "$_hn_" ] || _hn_=$(hostname 2>/dev/null); printf -v "$1" '%s' "$_hn_"; }
_hostname_r _SALA_HN
# date: the two forms sala asks for 170 times in its code (`date +%s`, `date -Is`) answered by the shell's own clock, everything else by the real
# date (a process per call, thousands per test run). The output is the same, TZ= in front of the call included.
_iso_tz_r() { local _iz _it; TZ="$2" printf -v _it '%(%Y-%m-%dT%H:%M:%S)T' -1; TZ="$2" printf -v _iz '%(%z)T' -1; printf -v "$1" '%s%s:%s' "$_it" "${_iz%??}" "${_iz: -2}"; }   # <var> <zone> → `TZ=<zone> date -Is` in it
_iso_now_r() { local _iz _it; printf -v _it '%(%Y-%m-%dT%H:%M:%S)T' -1; printf -v _iz '%(%z)T' -1; printf -v "$1" '%s%s:%s' "$_it" "${_iz%??}" "${_iz: -2}"; }   # <var> → `date -Is` in it, no process
_DATE_FMT_RE='^\+[%A-Za-z0-9 :,._/-]+$'
# _epoch_utc_r <var> <YYYY-MM-DDTHH:MM:SSZ> → the epoch of that UTC instant, by days-from-civil arithmetic; 1 for any other form and for any
# value the real date would refuse or that is outside 1970..2999 (month 13, Feb 30, hour 24, second 60, a year beyond the range): the caller asks date then
_epoch_utc_r() {
    [[ $2 =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})Z$ ]] || return 1
    local y=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[2]})) d=$((10#${BASH_REMATCH[3]})) era doy yoe doe dim
    [ "$y" -ge 1970 ] && [ "$y" -le 2999 ] && [ "$m" -ge 1 ] && [ "$m" -le 12 ] && [ "$d" -ge 1 ] || return 1
    [ "$((10#${BASH_REMATCH[4]}))" -le 23 ] && [ "$((10#${BASH_REMATCH[5]}))" -le 59 ] && [ "$((10#${BASH_REMATCH[6]}))" -le 59 ] || return 1
    case $m in 1|3|5|7|8|10|12) dim=31 ;; 4|6|9|11) dim=30 ;; *) dim=28; (( y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) )) && dim=29 ;; esac
    [ "$d" -le "$dim" ] || return 1
    [ "$m" -le 2 ] && y=$((y - 1))
    era=$((y / 400)); yoe=$((y - era * 400))
    doy=$(( (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1 )); doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
    printf -v "$1" '%s' $(( (era * 146097 + doe - 719468) * 86400 + 10#${BASH_REMATCH[4]} * 3600 + 10#${BASH_REMATCH[5]} * 60 + 10#${BASH_REMATCH[6]} ))
}
# date: the forms sala asks for thousands of times a test run are answered by the shell: now as epoch or ISO, `+FORMAT` of now, of
# `-d @EPOCH` (with -u: in UTC) and the epoch of an ISO `…Z` instant. A format with GNU's own %N or %:z, and every other form, goes to the real date.
date() {
    local _e _f _u=""
    case "$*" in
        +%s) printf '%(%s)T\n' -1; return ;;
        -Is) local _i; _iso_now_r _i; printf '%s\n' "$_i"; return ;;
    esac
    if [ $# -eq 1 ] && [[ $1 =~ $_DATE_FMT_RE && $1 != *%N* && $1 != *%:* ]]; then printf "%(${1#+})T\n" -1; return; fi
    if [ "${1:-}" = -u ] && [ $# -ge 3 ]; then _u=1; shift; fi
    if [ $# -eq 3 ] && [ "$1" = -d ]; then
        _f=$3
        if [[ $2 =~ ^@[0-9]{1,11}$ ]] && [[ $_f =~ $_DATE_FMT_RE && $_f != *%N* && $_f != *%:* ]] && [ "$_WHEN_TZ" = 1 ]; then
            _e=$((10#${2#@}))   # base 10: printf would read @012 as octal
            if [ -n "$_u" ]; then TZ=UTC printf "%(${_f#+})T\n" "$_e"; else printf "%(${_f#+})T\n" "$_e"; fi; return
        fi
        if [ "$_f" = +%s ] && _epoch_utc_r _e "$2"; then printf '%s\n' "$_e"; return; fi
    fi
    if [ -n "$_u" ]; then command date -u "$@"; else command date "$@"; fi
}
# mkdir: `mkdir -p` of directories that exist is answered by the shell (1700 processes in a test run, one on nearly every state write);
# anything else, and every other form, goes to the real mkdir.
mkdir() {
    if [ "${1:-}" = -p ] && [ $# -gt 1 ]; then
        local _m _all=1
        for _m in "${@:2}"; do [ -d "$_m" ] || { _all=0; break; }; done
        [ "$_all" = 0 ] || return 0
    fi
    command mkdir "$@"
}
# _when_r <var> <epoch> [day] → "Mon Oct 12th 21:22" ("Mon Oct 12th" with `day`) in SALA_TZ (this machine's local time when unset), by the shell's own
# strftime (bash's printf '%(…)T' honours a TZ set for the one call): no `date` process. A word that is no epoch goes to the real date, as it always did.
# (a bash whose printf does not follow a TZ set for the one call, as some before 5.0, gets the date process: probed once, with a fixed POSIX zone one hour ahead)
_WHEN_TZ=0; TZ=UTC-1 printf -v _p '%(%H)T' 0 2>/dev/null && [ "$_p" = 01 ] && _WHEN_TZ=1; unset _p
_when_p() {  # <var> <strftime format> <epoch> → the shell's strftime in SALA_TZ; with none set, no TZ is given (TZ="" would be UTC), so the machine's own zone applies
    if [ -n "$SALA_TZ" ]; then TZ="$SALA_TZ" printf -v "$1" "%($2)T" "$3"; else printf -v "$1" "%($2)T" "$3"; fi
}
_when_d() {  # <var> <date format> <epoch> → the real date, the same way
    local _o
    if [ -n "$SALA_TZ" ]; then _o=$(TZ="$SALA_TZ" command date -d "@$3" "$2" 2>/dev/null || TZ="$SALA_TZ" command date -r "$3" "$2")
    else _o=$(command date -d "@$3" "$2" 2>/dev/null || command date -r "$3" "$2"); fi
    printf -v "$1" '%s' "$_o"
}
_when_r() {
    local d suf o="" e="${2:-}" fmt
    if [ "$_WHEN_TZ" = 1 ] && [[ $e =~ ^[0-9]+$ ]] && _when_p d '%-d' "$e" 2>/dev/null; then
        case "$d" in 1|21|31) suf=st;; 2|22) suf=nd;; 3|23) suf=rd;; *) suf=th;; esac
        fmt="%a %b $d$suf"; [ "${3:-}" = day ] || fmt="$fmt %H:%M"
        _when_p o "$fmt" "$e"
    else
        _when_d d '+%-d' "$e"
        case "$d" in 1|21|31) suf=st;; 2|22) suf=nd;; 3|23) suf=rd;; *) suf=th;; esac
        fmt="+%a %b $d$suf"; [ "${3:-}" = day ] || fmt="$fmt %H:%M"
        _when_d o "$fmt" "$e"
    fi
    printf -v "$1" '%s' "$o"
}

# _nap <seconds> → a sleep with no process (a sleep per poll): a read with a timeout on a pipe nothing writes to. Falls back to sleep
# where the shell cannot make that pipe (bash before 4.1).
_nap() {
    if [ -z "${_NAP_FD:-}" ]; then { exec {_NAP_FD}<> <(:); } 2>/dev/null || _NAP_FD=sleep; fi
    if [ "$_NAP_FD" = sleep ]; then sleep "$1"; else read -r -t "$1" -u "$_NAP_FD" _ 2>/dev/null || :; fi
}
_now_r() { printf -v "$1" '%(%s)T' -1; }   # <var> → the epoch second in <var>, no process (a $(date +%s) is a subshell even with the function above)
_stamp_age_r() {  # <var> <stamp> → seconds since the first 10 digits of a stamp (a registry statusUpdatedAt in ms), 0-based as `cut -c1-10 | grep -E '^[0-9]+$' || echo 0`
    local _s=${2:0:10} _n; [[ $_s =~ ^[0-9]+$ ]] || _s=0
    printf -v _n '%(%s)T' -1; printf -v "$1" '%s' "$(( _n - _s ))"
}
# The "key=value" state files (the watch's state, sets, operations, the sign-in record…) were read with an awk per lookup and rewritten with a
# grep (the biggest single source of processes in a `watch` run); the shell reads them itself. Same answers as
# awk -F= '$1==k {print substr($0, length(k)+2); exit}': the text after "key=" of the first line that starts so (a line that is the bare key: an empty value).
_kv_first() {  # <file> <key> → that value; nothing for a file that cannot be read
    local line
    { while IFS= read -r line || [ -n "$line" ]; do
          case $line in "$2="*) printf '%s\n' "${line#"$2="}"; return 0 ;; "$2") echo; return 0 ;; esac
      done < "$1"; } 2>/dev/null
    return 0
}
_kv_first_r() {  # <var> <file> <key> → that value in <var> (empty for a missing file, key or value); the shell's own, no subshell
    local _line; printf -v "$1" '%s' ""
    { while IFS= read -r _line || [ -n "$_line" ]; do
          case $_line in "$3="*) printf -v "$1" '%s' "${_line#"$3="}"; return 0 ;; "$3") return 0 ;; esac
      done < "$2"; } 2>/dev/null
    return 0
}
# (a write that changes nothing is skipped, so the file's mtime is the last REAL change: set_prune ages a set by that, not by the last time something re-wrote it —)
_kv_set() {  # <file> <key> <value> [temp tag] → the file's other lines, then "key=value" last, through a temp file and mv; no write at all when it already holds that key exactly once with that value
    local _line _n=0 _same=0 _t="$1.${4:-tmp}.${BASHPID:-$$}"
    { while IFS= read -r _line || [ -n "$_line" ]; do
          if [[ $_line == "$2="* ]]; then _n=$((_n + 1)); [ "${_line#"$2="}" = "$3" ] && _same=1; fi
      done < "$1"; } 2>/dev/null
    [ "$_n" = 1 ] && [ "$_same" = 1 ] && return 0
    { _kv_without "$1" "$2"; printf '%s=%s\n' "$2" "$3"; } > "$_t" && mv -f "$_t" "$1"
}
_key_r() {  # <var> <text> → the text with every byte but A-Za-z0-9_- turned to _ (tr -c 'A-Za-z0-9_-' '_'), for a state key
    local LC_ALL=C; printf -v "$1" '%s' "${2//[^A-Za-z0-9_-]/_}"
}
# _claude_panes_r <var> → "session|pane id|claude pid" for every claude under a tmux pane, one per line (one tmux call and one ps pass, walked here: unmapped_report's walk)
_claude_panes_r() {
    local p pp comm q rest id sess panes ptab d line o=""
    local -A pane=() par=(); local -a claudes=()
    panes=$(tmux list-panes -a -F '#{pane_pid} #{pane_id} #{session_name}' 2>/dev/null)
    while read -r p id sess; do [ -n "$p" ] && pane[$p]="$id|$sess"; done <<< "$panes"
    if [ -r /proc/self/stat ]; then   # the walk read from /proc by the shell: no ps
        _claude_pids_r ptab || ptab=""
        for p in $ptab; do
            q=$p; d=0
            while [ -n "$q" ] && [ "$q" -gt 1 ] 2>/dev/null && [ "$d" -lt 4096 ]; do
                if [ -n "${pane[$q]+x}" ]; then rest=${pane[$q]}; o+="${rest#*|}|${rest%%|*}|$p"$'\n'; break; fi
                line=""; { read -r line < "/proc/$q/stat"; } 2>/dev/null || break
                line=${line##*) }; q=""; read -r _ q _ <<< "$line"
                d=$((d + 1))
            done
        done
        printf -v "$1" '%s' "$o"; return 0
    fi
    ptab=$(ps -e -o pid=,ppid=,comm=)
    while read -r p pp comm; do [ -n "$p" ] || continue; par[$p]=$pp; [ "${comm%% *}" = claude ] && claudes+=("$p"); done <<< "$ptab"
    for p in ${claudes[@]+"${claudes[@]}"}; do
        q=$p
        while [ -n "$q" ] && [ "$q" -gt 1 ] 2>/dev/null; do
            if [ -n "${pane[$q]+x}" ]; then rest=${pane[$q]}; o+="${rest#*|}|${rest%%|*}|$p"$'\n'; break; fi
            q=${par[$q]:-}
        done
    done
    printf -v "$1" '%s' "$o"
}
# _panes_get_r <var> [id] → "session|claude pid" lines ("session|pane id|claude pid" with id); the watch tick's own table when it took one for its scans (_TICK_PANES_SET), else read now
_panes_get_r() {
    local _pgt="" _pgs _pgi _pgp _pgo=""
    if [ -n "${_TICK_PANES_SET:-}" ]; then _pgt=$_TICK_PANES; else _claude_panes_r _pgt; fi
    if [ "${2:-}" = id ]; then printf -v "$1" '%s' "$_pgt"; return 0; fi
    while IFS='|' read -r _pgs _pgi _pgp; do [ -n "$_pgs" ] && _pgo+="$_pgs|$_pgp"$'\n'; done <<< "$_pgt"
    printf -v "$1" '%s' "$_pgo"
}
_kv_all() {  # <file> <key> → the value of every such line
    local line
    { while IFS= read -r line || [ -n "$line" ]; do
          case $line in "$2="*) printf '%s\n' "${line#"$2="}" ;; "$2") echo ;; esac
      done < "$1"; } 2>/dev/null
    return 0
}
_kv_has() {  # <file> <key> → 0 when a line starts "key="
    local _l
    { while IFS= read -r _l || [ -n "$_l" ]; do [[ $_l == "$2="* ]] && return 0; done < "$1"; } 2>/dev/null
    return 1
}
_kv_without() {  # <file> <key> → the file's lines but those starting "key=" (grep -v "^key=")
    local line
    { while IFS= read -r line || [ -n "$line" ]; do
          [[ $line == "$2="* ]] || printf '%s\n' "$line"
      done < "$1"; } 2>/dev/null
    return 0
}
# The tab-separated tables (pane map, lanes.tsv, models.tsv): the first row whose first column is the key, read by the shell (what
# awk -F'\t' '$1==s {…; exit}' gave), into a variable so that a caller needs no subshell either.
_tsv_row_r() {  # <var> <file> <key> → the whole row in <var> (empty when there is none)
    local line t=$'\t'
    printf -v "$1" %s ""
    { while IFS= read -r line || [ -n "$line" ]; do
          [ "${line%%"$t"*}" = "$3" ] && { printf -v "$1" %s "$line"; return 0; }
      done < "$2"; } 2>/dev/null
    return 0
}
_tsv_col_r() {  # <var> <file> <key> <column> → that column of the row ("" for a missing column or row)
    local row k="$4" t=$'\t'
    _tsv_row_r row "$2" "$3"
    while [ "$k" -gt 1 ]; do [[ $row == *"$t"* ]] || { row=""; break; }; row=${row#*"$t"}; k=$((k - 1)); done
    printf -v "$1" %s "${row%%"$t"*}"
}
# _dir <path> <var> → dirname(path) in <var>, without a fork (every `salamander` call used to start seven dirnames while it loaded this file)
_dir() { local p=$1; while [[ $p == ?*/ ]]; do p=${p%/}; done; case $p in /) ;; */*) p=${p%/*}; while [[ $p == ?*/ ]]; do p=${p%/}; done; p=${p:-/} ;; *) p=. ;; esac; printf -v "$2" %s "$p"; }
# _step_lines <text> → its lines that start with STEP| (printf '%s\n' "$text" | grep '^STEP|', with no process); 1 when there is none
_step_lines() { local _l _n=1; while IFS= read -r _l || [ -n "$_l" ]; do [[ $_l == 'STEP|'* ]] && { printf '%s\n' "$_l" 2>/dev/null; _n=0; }; done <<< "$1"; return "$_n"; }
# _nlines <text> → how many of its lines are not empty (grep -c . over the text, which prints 0 and fails for none; this always succeeds), with no process
_nlines() { local _n=0 _l; while IFS= read -r _l || [ -n "$_l" ]; do [ -n "$_l" ] && _n=$((_n + 1)); done <<< "$1"; echo "$_n"; }
# claude_ver → the version the launcher symlink (SALA_CLAUDE) points at: basename "$(readlink -f …)", one process fewer
claude_ver() { local _p; _p=$(readlink -f "$SALA_CLAUDE" 2>/dev/null); printf '%s\n' "${_p##*/}"; }
# _lastline <text> → its last line (printf '%s\n' "$text" | tail -1 for a text out of $(…), which has no trailing newline), with no process
_lastline() { local _t=$1; printf '%s\n' "${_t##*$'\n'}"; }
# _mkparent <path> → the directory the path lives in exists afterwards (no fork when it already does); mkdir -p's status otherwise
_mkparent() { local d; _dir "$1" d; [ -d "$d" ] || mkdir -p "$d" 2>/dev/null; }
# SESSION LINKS (Tue Oct 13th 2026: term links replace the remote-control links, and the link comes from sala): sala's heartbeat is the one source of session links. The link for a
# session on THIS box — the url of the heartbeat's own rows (lib/heartbeat.sh) and the rename notice (lib/rename.sh) — is
# SALA_SESSION_URL with {name} replaced by the session's name, percent-encoded exactly as JavaScript's encodeURIComponent
# does: sala-web reads its link as #s=<encodeURIComponent(name)> and matches it against the registry name (the /rename label,
# which sala keeps equal to the tmux session name and the pane map's first column). sala-web reaches only the panes of the
# box it runs on, so the link is never given to another box's rows: the heartbeat's swept rows keep their claude.ai link.
#   unset         SALA_SESSION_URL_DEFAULT on the box that drives the fleet (SALA_FLEET_HOSTS set); that default is empty, so the
#                 claude.ai link; nothing on any other box (a standalone install keeps the claude.ai link)
#   set, empty    the claude.ai Remote Control link, as before
# A session with no name, under an empty template, gets the claude.ai link ("" while its bridge is down). The Python body
# is one definition for both callers: session_url below runs it, the heartbeat's Python execs it (HB_URL_PY).
#   The default names no web UI (empty): set SALA_SESSION_URL to your sala web UI's link, with {name} where the session's name goes (for
#   example 'https://sala.example.com/#s={name}'). The heartbeat rewrites a row whose url changed, so a change of this setting reaches the
#   fleet file at its next run: tell the board's engineer, as the contract in lib/heartbeat.sh says.
SALA_SESSION_URL_DEFAULT=''
# The board's web address, for the link a side conversation's mandate carries to its item (<this>/items/<n>). Empty (the default): the
# mandate says how to read the item with the stackshot connector instead. Example: https://board.example.com
: "${SALA_STACKSHOT_WEB:=}"
SALA_SESSION_URL_PY='def session_url(name, bridge, tpl):
    from urllib.parse import quote
    if tpl and name: return tpl.replace("{name}", quote(name, safe="-_.!~*\x27()"))   # encodeURIComponent'"'"'s unreserved set
    bridge = bridge or ""
    return ("https://claude.ai/code/session_" + bridge.split("_", 1)[1]) if "_" in bridge else ""'
session_url_template() {  # → the template in force on this box (see SESSION LINKS), or nothing
    if [ -n "${SALA_SESSION_URL+x}" ]; then printf '%s' "$SALA_SESSION_URL"
    elif [ -n "${SALA_FLEET_HOSTS:-}" ]; then printf '%s' "$SALA_SESSION_URL_DEFAULT"; fi
}
session_url() {  # <name> [bridgeSessionId] → the link for that session on this box, or nothing
    python3 -c "$SALA_SESSION_URL_PY"$'\nimport sys\nprint(session_url(sys.argv[1], sys.argv[2], sys.argv[3]))' "${1:-}" "${2:-}" "$(session_url_template)"
}
# inbox_hold <uuid> <name> / inbox_release <uuid> <name> [wait] — hold stackshot's inbox for a pane across its relaunch
# (the board's main session: a line the puller writes into a pane's socket while sala relaunches that pane is
# accepted and dropped, and nothing can tell). The keys go into stackshot's held-msg.txt and held-hub.txt (inbox.take
# skips held keys; the next poll after the release delivers them) and into a ledger of our own, so `watch` drops a hold
# a dead relaunch left behind (inbox_release_stale, after 10 min). release with "wait" first waits up to 30 s for the
# resumed conversation to be registered with its socket. A missing stackshot is no error: nothing is held.
# WHEN: a sweep holds EVERY pane it is about to close before it exits ANY of them
# (lib/revive.sh, phase 2), waits SALA_HOLD_SETTLE s, and re-checks each pane just before its /exit. Until then each pane was held
# alone, right before its own /exit: a notice the puller handed out and the pane acked in that second was off stackshot's queue,
# and the /exit typed by keys (no mod to refuse a running turn) killed the turn before the pane acted on it.
: "${SALA_INBOX_HOLD_DIR:=$HOME/.local/state/stackshot/anchor-hub}"
SALA_INBOX_LEDGER="$SALA_LOG_DIR/salamander-inbox-holds.tsv"
SALA_DEFERRED="$SALA_LOG_DIR/salamander-deferred.tsv"  # panes a relaunch left because they hold scheduled work:
                                                       # session \t since \t why \t claude pid then \t force (1: relaunch even if current)
                                                       # \t set id (the recycle set the pane counts in, see below; empty: none)
defer_add() {  # <tmux session> <why> [force] [set id] — `watch` relaunches it once its scheduled work is done (lib/watch.sh deferred_revive)
    # a pane already listed stays one row (one job, one list); the row's set id moves to the newest flag's set, so the
    # job that holds the pane now is the one watch settles it in (the older flags clear by the rule, set_sync)
    if grep -q "^$1"$'\t' "$SALA_DEFERRED" 2>/dev/null; then
        local _ns="${4:-${SALA_SET:-}}" _t="$SALA_DEFERRED.t.${BASHPID:-$$}"
        [ -n "$_ns" ] && awk -F'\t' -v OFS='\t' -v s="$1" -v n="$_ns" '$1 == s && NF >= 6 {$6 = n} {print}' "$SALA_DEFERRED" > "$_t" && mv -f "$_t" "$SALA_DEFERRED"
        rm -f "$_t"; return 0
    fi
    local pp c; pp=$(tmux list-panes -t "$(tmux_win_t "$1")" -F '#{pane_pid}' 2>/dev/null | head -1); c=$(claude_pid_under "$pp" 2>/dev/null)
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$(date +%s)" "$2" "${c:-0}" "${3:-0}" "${4:-${SALA_SET:-}}" >> "$SALA_DEFERRED"
}

# ── recycle sets ──────────────────────────────────────────────────────────────
# A SET is one recycle, or one `revive --only` / `revive --self` that left a pane to come back
# for (kind Revive). Every notice after its first post links back to it by its LABEL — its start, "2030-01-02 09:12 UTC",
# the same on every post — and carries a running count: n of the N panes it meant to relaunch (the master's own pane and
# deferred panes included). One bullet per pane, but panes held for the same reason are one line with a count once more than 5
# share it (post_group_bullets); every retry post the same shape (count in the headline,
# panes just back as bullets, the CLI version they came back on, and — while the set is open — one bullet per pane still out with
# its reason); the last one says "· set closed", or, when any pane was given up,
# "closed at n/N", once. The retry workers, the self-worker and watch's deferred relaunch all settle panes in ONE state file
# per set, under one flock, so two workers on a set count right. State, not log: under SALA_STATE_DIR (the XDG
# convention). File sets/<id>, id = <start epoch>-<pid>, key=value lines — id kind (Recycle|Revive) scope (recycle |
# only.<session> | worker.<pid>) t0 label ver total done reported (the first post is out) closed created took timing hook
# (the recycle driver has reported through this set: from then on its clear fires the post-recycle hook; below, set_recycled)
# hookfired (the hook has fired, once) src fscope (the flag, below), and
# repeated: out=<session> (outstanding) · skip=<bullet> (the first post's left-behind bullets) · gave=<bullet> (given up)
# · note=<text> (the first post's retry note) · back=<session> (settled before the first post; a guard, it is made at once).
# FLAGS AND THE JOB: a Recycle or Revive set is a FLAG, what called for a relaunch, with the
# time it was raised (t0), its source (src: recycle · op-recycle · update · auto · provision · reboot · revive · lane · model) and its
# scope (fscope: `all` for every live pane, or the one pane, or the --only list, of a revive, lane or model switch). A flag clears when
# EVERY live pane of its scope has relaunched at least once since t0, judged by the pane's own last relaunch: `startedAt` of its
# claude process in the CLI's registry (a relaunch is a new process, so revive, lane, model and the self-worker all refresh it; a
# pane spawned after the flag counts as relaunched). A retired or gone pane does not count (the set's N drops by one); a pane with no
# readable startedAt has not relaunched. `out=` stays the record of what a flag still waits for (the 🔄 post's bullets read it), but
# no one worker settles it alone any more: set_sync judges every open flag by the rule on any pane's relaunch and on every watch
# tick, so a pane two recycles skipped clears both flags when it finally comes back, one ✅ post each. The JOB is the relaunching
# itself: the driver's sweep, the ONE retry worker and the deferred list of the newest flag of its scope (sets/current.<scope> names
# it; a newer flag moves it and the older flag's worker stops, set_superseded). The relaunch counter (n/N) belongs to the job, judged
# against the newest flag: a flag raised at 30/40 reads 0/40 and the same job relaunches the panes again; only the job's flag posts
# 🔄 progress, an older open flag posts when it clears. The deferred list holds one row per pane, pointing at the newest flag's set
# (defer_add). A pane held past the later list's limit (SALA_LATER_LIMIT, lib/watch.sh) is given up in every flag still waiting for
# it, which then closes "at n/N" (set_giveup_pane). The post-recycle hook fires once per cleared flag (_set_cleared_hook).
# TAKEOVER: sets/current.<scope> names the newest set of a scope (the recycle driver writes current.recycle, a direct
# `revive --only X` current.only.X); a worker whose set an equal or newer one replaced stops (set_superseded). Never pid-file
# identity: the self-worker's retry worker once overwrote the driver's worker's pid file, and the driver's
# worker stopped at its next tick, dropping its panes' closures. Each worker has its own pid file now
# (salamander-retry.<pid>.pid), which `sala ready` still finds to wake it.
SALA_SET_DIR="$SALA_STATE_DIR/sets"
set_has() { [ -n "${1:-}" ] && [ -s "$SALA_SET_DIR/$1" ]; }
set_val() { _kv_first "$SALA_SET_DIR/$1" "$2"; }   # <id> <key> → the first value
set_vals() { _kv_all "$SALA_SET_DIR/$1" "$2"; }          # <id> <key> → every value
set_count() { local _v; _v=$(set_vals "$1" "$2"); _nlines "$_v"; }
_set_scope_file() { local _s=$1 LC_ALL=C; echo "$SALA_SET_DIR/current.${_s//[^A-Za-z0-9_.-]/_}"; }   # (tr -c 'A-Za-z0-9_.-' '_' without the process)
set_point() { mkdir -p "$SALA_SET_DIR" && echo "$2" > "$(_set_scope_file "$1")"; }   # <scope> <id> — the newest set of that scope
set_superseded() {  # <id> → 0 when another set of its scope, as new or newer, is current
    local p; p=$(cat "$(_set_scope_file "$(set_val "$1" scope)")" 2>/dev/null)
    [ -n "$p" ] && [ "$p" != "$1" ] && [ "${p%%-*}" -ge "${1%%-*}" ] 2>/dev/null
}
set_label() { cs_date -d "@$1" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || cs_date -r "$1" '+%Y-%m-%d %H:%M %Z'; }   # <epoch> → "2030-01-02 09:12 UTC"
set_after() { local t0 k; t0=$(set_val "$1" t0); [ -n "$t0" ] || return 0; k=$(set_val "$1" kind); echo "$(( ($(date +%s) - t0) / 60 )) min after the ${k,,}"; }
set_bullet() { sed -E 's/^([^: ]+):[0-9]+/\1/' <<< "$1"; }   # a sweep row "sess:0: why" → "sess: why"
dur_words() { if [ $(( $1 % 86400 )) -eq 0 ]; then plural $(( $1 / 86400 )) day; elif [ $(( $1 % 3600 )) -eq 0 ]; then echo "$(( $1 / 3600 )) h"; else echo "$(( $1 / 60 )) min"; fi; }
plural() { if [ "$1" = 1 ]; then echo "$1 $2"; else echo "$1 ${2}s"; fi; }   # <n> <noun>
# set_create <id> <kind> <scope> <total> <done> <ver> <reported> [key=value…] — written whole, before anyone is told its id
set_create() {
    set_has "$1" && return 0
    local id="$1" t0="${1%%-*}" kv f; mkdir -p "$SALA_SET_DIR"; f="$SALA_SET_DIR/$1"
    { printf 'id=%s\nkind=%s\nscope=%s\nt0=%s\nlabel=%s\nver=%s\ntotal=%s\ndone=%s\nreported=%s\nclosed=0\ncreated=%s\n' \
        "$id" "$2" "$3" "$t0" "$(set_label "$t0")" "$6" "$4" "$5" "$7" "$(date +%s)"
      shift 7; for kv in "$@"; do [ -n "$kv" ] && printf '%s\n' "$kv"; done; } > "$f.t.${BASHPID:-$$}" && mv -f "$f.t.${BASHPID:-$$}" "$f"
}
# one editor at a time: flock on fd 5 (6 is the map, 8 the inbox, 9 the recycle lock); unserialized where flock is missing
_set_locked() {
    mkdir -p "$SALA_SET_DIR"
    command -v flock >/dev/null 2>&1 || { "$@"; return; }
    ( flock -w 60 5 || true; "$@" ) 5>>"$SALA_SET_DIR/.lock"
}
_set_put() { _kv_set "$SALA_SET_DIR/$1" "$2" "$3" t; }   # (the shell's own rewrite, and none when the value stands)
_set_add() { printf '%s=%s\n' "$2" "$3" >> "$SALA_SET_DIR/$1"; }
_set_drop() { local f="$SALA_SET_DIR/$1" t="$SALA_SET_DIR/$1.t.${BASHPID:-$$}"; grep -vxF -- "$2=$3" "$f" > "$t"; mv -f "$t" "$f"; }
_set_out() { grep -qxF -- "out=$2" "$SALA_SET_DIR/$1" 2>/dev/null; }
# set_resolve <id> [ok|rule|gone|gave <session> <bullet>]… — settle panes of a set: ok = back (done+1), rule = back by the flag rule
# (set_sync: done+1 too), gone = retired or gone (N-1), gave = given up. A pane no longer outstanding is ignored (two workers, or a
# worker and watch, may see the same relaunch). Then, once the set's first post is out: one post for every settle of this call
# (🔄 "· n/N"; ✅ "· set closed" when that emptied the set and nothing was given up), and, the moment nothing is outstanding and
# something was given up, the "closed at n/N" post, once. Every public settle then judges the OTHER open flags by the rule (set_sync):
# the pane that just came back may be the last one they wait for too.
set_resolve() { local _rc=0; _set_locked _set_resolve "$@" || _rc=$?; set_sync >/dev/null 2>&1 || true; return $_rc; }
_set_resolve() {
    local id="$1"; shift; set_has "$id" && [ "$(set_val "$id" closed)" != 1 ] || return 0
    local oks=() how s b
    while [ $# -ge 3 ]; do
        how="$1" s="$2" b="$3"; shift 3
        _set_out "$id" "$s" || continue
        _set_drop "$id" out "$s"
        case "$how" in
            ok|rule) _set_put "$id" done $(( $(set_val "$id" done) + 1 )); oks+=("$b"); [ "$(set_val "$id" reported)" = 1 ] || _set_add "$id" back "$s";;
            gone) _set_put "$id" total $(( $(set_val "$id" total) - 1 )); oks+=("$b");;   # retired or gone: it no longer counts, in N too
            *) _set_add "$id" gave "$b"; [ "$(set_val "$id" reported)" = 1 ] || _set_add "$id" skip "$b";;   # before the first post: one of its bullets
        esac
    done
    [ "$(set_val "$id" reported)" = 1 ] || return 0   # before the first post: its count carries these (set_report)
    _set_close_posts "$id" ${oks[@]+"${oks[@]}"}
}
# THE BOARD AFTER A LATE RELAUNCH (Mon Oct 12th 2026; reshaped by Wed Oct 28th 2026): the post-recycle hook
# (below, post_recycle_hook) tells stackshot which panes a recycle left behind, so it keeps their owners' items flagged ("its owner
# was not relaunched") and clears the rest. It used to fire when the driver's sweep ended and again for every pane a
# worker or watch brought back later. Now it fires ONCE PER CLEARED FLAG (stackshot's answer): the flag's time as
# `started` and as `flag_at` (SALA_RECYCLE_STARTED, SALA_RECYCLE_FLAG_AT), and the panes the flag did not get back as `skipped` -
# none for a full clear, the given-up panes for a partial one (a pane held past SALA_LATER_LIMIT, or a pane gone). So a flag that
# stays open, because a busy pane has not relaunched, fires nothing yet. Only a recycle driver's set fires it (hook=1, set by
# set_recycled when the driver's sweep and self-worker are done): a Revive set (`revive --only`, `--self`) and a Provision set never
# report, as before. Without a set (a sweep that died before writing one) the driver's own skipped file stands in, as before.
# set_recycled <id> <log> <started> [skipped session…] — the recycle driver's end: from now on the set's clear fires the hook (at
# once when the set is closed already: a clean recycle, or one that gave everything up in its sweep)
set_recycled() {
    local id="$1" log="$2" started="$3"; shift 3
    if set_has "$id"; then _set_locked _set_recycled "$id" "$log"; else post_recycle_hook "$log" recycle "$started" "$@"; fi
}
_set_recycled() { _set_put "$1" hook 1; [ "$(set_val "$1" closed)" = 1 ] && _set_cleared_hook "$1" "${2:-}"; return 0; }
_set_cleared_hook() {   # <id> [log] — under the lock, once per flag: started = flag_at = the set's t0, skipped = the panes it gave up
    [ "$(set_val "$1" hook)" = 1 ] && [ "$(set_val "$1" hookfired)" != 1 ] || return 0
    _set_put "$1" hookfired 1
    [ "${_SET_QUIET:-0}" != 1 ] || return 0   # the one-time reconcile of old sets: they were reported by the old calls
    local sk=(); mapfile -t sk < <(set_vals "$1" gave | sed -E 's/^([^: ]*)[: ].*/\1/' | grep .)
    post_recycle_hook "${2:-$SALA_LOG_DIR/salamander-revive.log}" recycle "$(set_val "$1" t0)" ${sk[@]+"${sk[@]}"}
}
# post_group_bullets <"session: reason" bullet…> → the bullets on stdout, panes held for the SAME reason as one line with a count once
# more than 5 share it (5 or fewer keep one bullet each, the session named). The reason is compared with its per-pane numbers left
# out: a rest ("relaunched only 15 min ago (on 2.1.317) — resting until 10:59 UTC; …") by its version and rule, giving the range of
# minutes; a busy pane, or one held by background tasks, by the kind alone (the ages stay in a small group's bullets); any other
# reason by its text. A leading "still waiting, " or "given up, " is part of the key. The group's line stands where its first bullet
# stood; a bullet that is not "<session>: <reason>" passes through. "all N sessions" when the group is every bullet.
post_group_bullets() {
    [ $# -gt 0 ] || return 0
    printf '%s\n' "$@" | awk -v max=5 '
    { line[NR] = $0; why = $0; lead = ""
      if (why !~ /^[^: ]+: /) { key[NR] = ""; next }
      sub(/^[^: ]+: /, "", why)
      if (why ~ /^still waiting, /) { lead = "still waiting"; sub(/^still waiting, /, "", why) }
      else if (why ~ /^given up, /) { lead = "given up"; sub(/^given up, /, "", why) }
      if (why ~ /^relaunched only [0-9]+ min ago \(on [^)]*\) / && why ~ /resting until/ && why ~ /sala relaunches it then \(SALA_RECYCLE_REST [^)]*\)$/) {
        s = why; sub(/^relaunched only /, "", s); m = s + 0
        v = why; sub(/^[^(]*\(on /, "", v); sub(/\).*$/, "", v)
        r = why; sub(/.*\(SALA_RECYCLE_REST /, "", r); sub(/\)$/, "", r)
        k = "rest|" lead "|" v "|" r; ver[k] = v; rule[k] = r
        if (!(k in n) || m < lo[k]) lo[k] = m
        if (!(k in n) || m > hi[k]) hi[k] = m
      } else if (why ~ /^busy( for [^;]*)?; sala relaunches it once it is free$/) k = "busy|" lead
      else if (why ~ /^its [0-9]+ background tasks? ran for .*; sala relaunches it once they finish$/) k = "tasks|" lead
      else { k = "same|" lead "|" why; text[k] = why }
      key[NR] = k; led[k] = lead; n[k]++; tot++ }
    END {
      for (i = 1; i <= NR; i++) {
        k = key[i]
        if (k == "" || n[k] <= max) { print line[i]; continue }
        if (k in done) continue
        done[k] = 1; all = (n[k] == tot) ? "all " : ""; who = all n[k] " sessions" (led[k] != "" ? " " led[k] : "")
        if (k ~ /^rest\|/) {
          mins = (lo[k] == hi[k]) ? lo[k] : lo[k] "-" hi[k]
          body = "relaunched " mins " min ago on " ver[k] (led[k] != "" ? "; " : ": ") "each rests " rule[k] ", then sala relaunches it"
          print (led[k] != "" ? who ": " body : who " were " body)
        } else if (k ~ /^busy\|/) print (led[k] != "" ? who ": busy; " : all n[k] " sessions are busy; ") "sala relaunches each once it is free"
        else if (k ~ /^tasks\|/) print (led[k] != "" ? who ": " : all n[k] " sessions are held by ") "background tasks" (led[k] != "" ? " running" : "") "; sala relaunches each once they finish"
        else print who ": " text[k]
      }
    }'
}
# _set_pending_bullets <id> — a 🔄 post's tail (one bullet per pane): the panes the set still waits for,
# from the set's own record, no new state. Each outstanding pane (out=) carries the reason of the first post's left-behind
# bullet (skip=, "<session>: <why>") as "<session>: still waiting, <why>" ("not relaunched yet" when the first post named none: the
# master's pane), except a held pane's bullet (hold_bullet: "<session>: busy for 2 h; sala relaunches it once it is free"),
# which is the whole line, as the first post and the deferred post worded it; each given-up
# pane (gave=) as "<session>: given up, <why>". Nothing outstanding prints nothing (the closing posts carry the given-up
# panes themselves). Capped at SALA_SET_PENDING_MAX (12) bullets, then "…and N more"; a reason longer than 240 characters is
# cut, so a post stays well under Slack's size limit.
: "${SALA_SET_PENDING_MAX:=12}"
_set_pending_bullets() {
    local id="$1" s b why all=() n r
    [ "$(set_count "$id" out)" -gt 0 ] || return 0
    while IFS= read -r s; do
        [ -n "$s" ] || continue; why=""
        while IFS= read -r b; do case "$b" in "$s: "*) why="${b#"$s: "}";; esac; done < <(set_vals "$id" skip)   # the newest bullet of the pane (the deferred post adds a fresher one)
        case "$why" in   # a held pane's bullet (hold_bullet) is already the whole line, the same words as in the first post and the deferred post
            *"; sala relaunches it once it is free"|*"; sala relaunches it once they finish") all+=("$s: $why");;
            *) all+=("$s: still waiting, ${why:-not relaunched yet}");;
        esac
    done < <(set_vals "$id" out)
    while IFS= read -r b; do
        [ -n "$b" ] || continue
        if [[ $b =~ ^([^:\ ]+):\ (.*)$ ]]; then all+=("${BASH_REMATCH[1]}: given up, ${BASH_REMATCH[2]}"); else all+=("given up: $b"); fi
    done < <(set_vals "$id" gave)
    [ ${#all[@]} -eq 0 ] || mapfile -t all < <(post_group_bullets "${all[@]}")   # panes held for one reason: one line with a count (post_group_bullets)
    n=${#all[@]}
    for r in "${all[@]:0:SALA_SET_PENDING_MAX}"; do if [ ${#r} -le 240 ]; then printf '%s\n' "$r"; else printf '%s…\n' "${r:0:239}"; fi; done
    [ "$n" -le "$SALA_SET_PENDING_MAX" ] || printf '…and %s more\n' $(( n - SALA_SET_PENDING_MAX ))
}
# _set_close_posts <id> [ok bullet…] [-- other bullet…] — under the lock. A post that leaves the set open is 🔄, in progress;
# only the one that closes it ("· set closed") is ✅. The bullets after "--" (a Provision set: a box
# whose leftovers joined the set in this pass) go into the same post. A Provision set counts boxes OK ("n/N OK").
_set_post() { [ "${_SET_QUIET:-0}" = 1 ] && return 0; sala_post "$@"; }   # the one-time reconcile of old sets closes them without a post (set_sync)
_set_close_posts() {
    local id="$1"; shift; local hd n N left ng g=() it k ok="" a sep=0 oks=() ex=() pend=()
    for a in "$@"; do if [ "$sep" = 0 ] && [ "$a" = -- ]; then sep=1; elif [ "$sep" = 0 ]; then oks+=("$a"); else ex+=("$a"); fi; done
    k=$(set_val "$id" kind); hd="$k $(set_val "$id" label)"; n=$(set_val "$id" done); N=$(set_val "$id" total)
    [ "$k" = Provision ] && ok=" OK"
    left=$(set_count "$id" out); ng=$(set_count "$id" gave)
    if [ ${#oks[@]} -gt 0 ] || [ ${#ex[@]} -gt 0 ]; then
        if [ "$left" = 0 ] && [ "$ng" = 0 ]; then _set_post "✅ *$hd · $n/$N$ok · set closed*" ${oks[@]+"${oks[@]}"} ${ex[@]+"${ex[@]}"}
        elif [ "$k" != Provision ] && set_superseded "$id"; then :   # a newer flag took the job over: its 🔄 posts carry the count; this one posts when it clears
        else
            [ "$k" = Provision ] || mapfile -t pend < <(_set_pending_bullets "$id")   # one bullet per pane still out
            _set_post "🔄 *$hd · $n/$N$ok*" ${oks[@]+"${oks[@]}"} ${ex[@]+"${ex[@]}"} ${pend[@]+"${pend[@]}"}; fi
    fi
    [ "$left" = 0 ] || return 0
    _set_put "$id" closed 1
    [ "$k" = Provision ] || _set_cleared_hook "$id"   # once per cleared flag, the given-up panes as skipped
    [ "$ng" -gt 0 ] || return 0
    mapfile -t g < <(set_vals "$id" gave); it=$([ "$ng" = 1 ] && echo it || echo them)
    mapfile -t g < <(post_group_bullets ${g[@]+"${g[@]}"})
    if [ "$k" = Provision ]; then _set_post "⚠️ *$hd closed at $n/$N*" "${g[@]}"; return 0; fi
    _set_post "⚠️ *$hd closed at $n/$N*" "${g[@]}" "open $it on claude.ai and check $it" "Details: ~/.claude/salamander-revive.log"
}
# set_left <id> <bullet> [note] — a pane left behind before the set's first post: its bullet, and its retry note
set_left() { _set_locked _set_left "$@"; }
_set_left() { set_has "$1" && [ "$(set_val "$1" reported)" != 1 ] || return 0; _set_add "$1" skip "$2"; [ -n "${3:-}" ] && _set_add "$1" note "$3"; return 0; }
# set_deferred <id> <bullet>… — panes a retry worker put on the deferred list (revive.sh retry_worker): they stay
# outstanding in the set and watch settles them when it relaunches them, so nothing is given up. Their bullets say they are
# deferred and why: in a post of their own once the set's first post is out, else among the first post's left-behind bullets.
set_deferred() { _set_locked _set_deferred "$@"; }
_set_deferred() {
    local id="$1" b; shift; set_has "$id" && [ "$(set_val "$id" closed)" != 1 ] || return 0
    for b in "$@"; do _set_add "$id" skip "$b"; done   # kept as the pane's bullet: the 🔄 follow-ups name it with the same words
    [ "$(set_val "$id" reported)" != 1 ] && return 0
    local gb=(); mapfile -t gb < <(post_group_bullets "$@")   # the post groups panes held for one reason; the record above keeps each
    sala_post "⚠️ *$(set_val "$id" kind) $(set_val "$id" label) · $(set_val "$id" done)/$(set_val "$id" total) relaunched · $# deferred*" ${gb[@]+"${gb[@]}"}
}
# set_report <id> — the set's first post (the recycle's own: at the end of its sweep, or — the master's pane the only one
# outstanding — by the self-worker once that pane is settled), once: nothing left behind →
# "✅ *Recycle done*" as before; panes left behind → "⚠️ *Recycle <label> · n/N relaunched*": how many came back and on
# which version, one bullet per pane left behind (one outstanding with no bullet of its own — the master's pane, which the
# self-worker relaunches next — says "not relaunched yet"; a pane settled before the post drops out), then the retry and
# deferred notes; nothing left to wait for → that same post headed "closed at n/N", which closes the set.
set_report() { _set_locked _set_report "$1"; }
_set_report() {
    local id="$1"; set_has "$id" && [ "$(set_val "$id" reported)" != 1 ] || return 0
    _set_put "$id" reported 1
    local hd n N ver left ng b s bl=() bg=() nt=() it tot
    hd="$(set_val "$id" kind) $(set_val "$id" label)"; n=$(set_val "$id" done); N=$(set_val "$id" total); ver=$(set_val "$id" ver)
    left=$(set_count "$id" out); ng=$(set_count "$id" gave)
    while IFS= read -r b; do
        [ -n "$b" ] || continue; s="${b%%[: ]*}"
        grep -qxF -- "back=$s" "$SALA_SET_DIR/$id" || bl+=("$b")
    done < <(set_vals "$id" skip)
    while IFS= read -r s; do
        [ -n "$s" ] || continue; printf '%s\n' ${bl[@]+"${bl[@]}"} | grep -q "^$s[: ]" || bl+=("$s: not relaunched yet")
    done < <(set_vals "$id" out)
    if [ ${#bl[@]} -eq 0 ] && [ "$left" = 0 ]; then
        _set_put "$id" closed 1; _set_cleared_hook "$id"
        if [ "$n" -gt 0 ]; then tot=$(set_val "$id" took); tot=${tot:-0}
            sala_post "✅ *Recycle done* · $(plural "$n" pane) on $ver" "relaunched in $((tot/60))m $((tot%60))s" "$(set_val "$id" timing)"
        else sala_post "✅ *Recycle done* · nothing to relaunch" "every pane already on $ver"; fi
        return 0
    fi
    mapfile -t bg < <(post_group_bullets ${bl[@]+"${bl[@]}"})   # panes left behind for one reason: one line with a count (post_group_bullets)
    if [ "$left" = 0 ]; then
        _set_put "$id" closed 1; _set_cleared_hook "$id"; it=$([ ${#bl[@]} = 1 ] && echo it || echo them)
        sala_post "⚠️ *$hd closed at $n/$N*" "$([ "$n" -gt 0 ] && echo "$(plural "$n" pane) relaunched on $ver")" ${bg[@]+"${bg[@]}"} "open $it on claude.ai and check $it" "Details: ~/.claude/salamander-revive.log"
        return 0
    fi
    mapfile -t nt < <(set_vals "$id" note)
    sala_post "⚠️ *$hd · $n/$N relaunched*" "$([ "$n" -gt 0 ] && echo "$(plural "$n" pane) relaunched on $ver")" ${bg[@]+"${bg[@]}"} ${nt[@]+"${nt[@]}"}
}
# ── the flag rule: set_sync ────────────────────────────────────────
# _set_pane_read <session> → one line: `live <startedAt ms> <version>` (the pane's claude, with the start of that PROCESS from the
# CLI's registry row: a relaunch is a new process and a new row), `wait` (the session is there but there is nothing to read: no claude
# right now, as between /exit and the resume, a row without startedAt, or tmux itself not answering, as in a reboot), or `gone` (tmux
# answers and has no such session). The one place the rule reads a pane; a suite redefines it to stand a fleet of any size in.
_set_pane_read() {
    local pp c sa
    tmux list-sessions >/dev/null 2>&1 || { echo wait; return 0; }
    tmux has-session -t "=$1" 2>/dev/null || { echo gone; return 0; }
    pp=$(tmux list-panes -t "$(tmux_win_t "$1")" -F '#{pane_pid}' 2>/dev/null | head -1)
    c=$(claude_pid_under "$pp" 2>/dev/null) || { echo wait; return 0; }
    registry_field_r sa "$c" startedAt
    case "$sa" in ''|*[!0-9]*) echo wait; return 0;; esac
    echo "live $sa $(proc_version "$c")"
}
# pane_last_relaunch <session> → the epoch second its claude process started (its last relaunch), empty when it cannot be read: the
# per-pane read the rest wait (SALA_RECYCLE_REST, below) and the flag rule are built on
pane_last_relaunch() { local st sa; read -r st sa _ <<< "$(_set_pane_read "$1")"; [ "$st" = live ] && echo $(( sa / 1000 )); return 0; }
# THE REST: a pane whose claude started less than SALA_RECYCLE_REST seconds ago is not relaunched again for a ROUTINE flag
# (a board item, a --when-idle request, the CLI's auto-update, provision, a plain `sala recycle`); it is waited for (a transient skip,
# so the retry worker brings it back once its rest is over). Not for a flag from the owner's words (`sala op recycle`, src op-recycle) and
# not for an explicit one-pane relaunch (revive, lane, model, reboot), which keep their behaviour. A resting pane still counts as
# relaunched for a flag whose time is before its start; for an older flag it stays out until the rest ends and it is relaunched.
# recycle_rest_left <claude pid> → the seconds its rest has left, nothing when it is not resting (or the rest is off)
recycle_rest_left() {
    local sa left; [ "${SALA_RECYCLE_REST:-0}" -gt 0 ] 2>/dev/null || return 0
    registry_field_r sa "$1" startedAt; case "$sa" in ''|*[!0-9]*) return 0;; esac
    left=$(( SALA_RECYCLE_REST - ($(date +%s) - sa / 1000) ))
    [ "$left" -gt 0 ] && echo "$left"; return 0
}
# flag_src → the source word of the flag this run raises: recycle · op-recycle · update · auto · provision · reboot (a recycle's
# SALA_RELAUNCH_KIND, or SALA_FLAG_SRC when the starter names one: op sets op-recycle, lane and model set lane and model), else revive
flag_src() { if [ -n "${SALA_FLAG_SRC:-}" ]; then echo "$SALA_FLAG_SRC"; elif [ -n "${SALA_RECYCLE:-}" ]; then relaunch_kind; else echo revive; fi; }
local_clock() { cs_date -d "@$1" '+%H:%M %Z' 2>/dev/null || cs_date -r "$1" '+%H:%M %Z'; }   # <epoch> → "16:23 UTC"
# _set_retired <session> → 0 when the pane map is there and has no row for it: sala retire drops the row, so a session that is gone
# from tmux and from the map is retired; one that is gone from tmux but still mapped is lost, which the workers give up as before
_set_retired() { [ -s "$SALA_SIDECAR" ] && [ -z "$(ledger_row "$1")" ]; }
: "${SALA_SET_QUIET_AFTER:=172800}"   # the one-time reconcile closes a set older than this (48 h) without a post
_set_sync_log() { local _t; _iso_now_r _t; echo "[$_t] sets: $*" >> "$SALA_LOG_DIR/salamander-revive.log"; }
# set_sync [--dry-run] — every open, reported Recycle or Revive flag judged by the rule: each pane it still waits for (out=) that has
# relaunched since the flag's t0 is settled (`rule`), each that is retired or gone dropped (`gone`); a flag left with nothing out
# closes, with its post (✅, or ⚠️ when a pane was given up earlier), and its hook call. Called after every set_resolve and on each
# watch tick, so one pane's relaunch clears every flag it was the last wait of, one post per flag. It prints (and logs) one line per
# flag it touched; --dry-run prints what it would do and writes nothing. THE ONE-TIME RECONCILE: the first pass on a box that
# has no sets/.reconciled yet closes the old-format flags the same way; those older than SALA_SET_QUIET_AFTER close without a post
# or a hook call (they were reported long ago), the others post as any clear does. A pane it cannot read, and a pane that has
# not relaunched, keep their flag open: it never closes a flag with a live pane that has not relaunched.
set_sync() {
    [ -d "$SALA_SET_DIR" ] || return 0
    if [ "${1:-}" = --dry-run ]; then _set_sync 1; else _set_locked _set_sync 0; fi
}
_set_sync() {
    local dry="$1" f id k t0 s st sa ver now first=0 quiet n left args line
    local -A rd=()
    _now_r now; [ -e "$SALA_SET_DIR/.reconciled" ] || first=1
    for f in "$SALA_SET_DIR"/*; do
        id=${f##*/}; [[ $id =~ ^[0-9]+-[0-9]+$ ]] || continue
        k=$(set_val "$id" kind); case "$k" in Recycle|Revive) ;; *) continue;; esac
        [ "$(set_val "$id" closed)" != 1 ] && [ "$(set_val "$id" reported)" = 1 ] || continue
        t0=$(set_val "$id" t0); case "$t0" in ''|*[!0-9]*) continue;; esac
        args=(); n=0; left=0
        while IFS= read -r s; do
            [ -n "$s" ] || continue; left=$((left + 1))
            [ -n "${rd[$s]+x}" ] || rd[$s]=$(_set_pane_read "$s")
            read -r st sa ver <<< "${rd[$s]}"
            case "$st" in
                live) if [ "$sa" -ge $(( (t0 + 1) * 1000 )) ]; then   # after the flag's whole second: t0 has no fraction, and a pane that started a moment before the flag in that second has not relaunched for it
                 args+=(rule "$s" "$s relaunched on $ver, $(( (sa / 1000 - t0) / 60 )) min after the ${k,,}"); n=$((n + 1)); fi;;
                gone) if _set_retired "$s"; then args+=(gone "$s" "$s is retired or gone, so it no longer counts"); n=$((n + 1)); fi;;
            esac
        done < <(set_vals "$id" out)
        [ "$n" -gt 0 ] || continue
        quiet=0; [ "$first" = 1 ] && [ $((now - t0)) -ge "$SALA_SET_QUIET_AFTER" ] && quiet=1
        line="$k $(set_val "$id" label) ($id): $n of $left pane(s) judged by the rule$( [ "$n" = "$left" ] && echo ", the flag clears")$( [ "$quiet" = 1 ] && echo " (reconcile, no post)")"
        if [ "$dry" = 1 ]; then echo "would settle $line"; continue; fi
        echo "settled $line"; _set_sync_log "settled $line"
        _SET_QUIET=$quiet _set_resolve "$id" "${args[@]}"
    done
    [ "$dry" = 1 ] || [ "$first" = 0 ] || : > "$SALA_SET_DIR/.reconciled"
    return 0
}
# set_giveup_pane <session> <why> — watch's later-list limit (SALA_LATER_LIMIT): a pane held that long no longer holds a flag open.
# It is given up in every open Recycle or Revive flag still waiting for it; a flag with nothing else out closes "at n/N" (the
# given-up wording), and fires the post-recycle hook with the pane as skipped: the flag clears PARTLY. The pane stays on the
# deferred list; watch still relaunches it once it is free.
set_giveup_pane() { _set_locked _set_giveup_pane "$@"; }
_set_giveup_pane() {
    local s="$1" why="$2" f id k
    for f in "$SALA_SET_DIR"/*; do
        id=${f##*/}; [[ $id =~ ^[0-9]+-[0-9]+$ ]] || continue
        k=$(set_val "$id" kind); case "$k" in Recycle|Revive) ;; *) continue;; esac
        [ "$(set_val "$id" closed)" != 1 ] && _set_out "$id" "$s" || continue
        _set_sync_log "gave up $s in $k $(set_val "$id" label) ($id): $why"
        _set_resolve "$id" gave "$s" "$s: $why"
    done
    return 0
}
# THE JOB RECORD AND ITS GATE (Wed Oct 28th 2026): the job of a scope is its newest flag (sets/current.<scope>),
# its one retry worker and the deferred list; sets/job.recycle holds what the gate needs between two watch ticks: gather_first (when
# the first flag of this gathering came in), gather_last (the newest), gather_keys (the flags seen, by key) and gather_posted (the
# gathering the one short post went out for). recycle_job_gate is the ONE place where "start the job now, or later" is decided for the
# flags watch turns into a recycle (a board item, a --when-idle request, the CLI's auto-update). With no unfinished job a flag starts
# it at once. While the job is unfinished (its newest flag is still open) a new flag does not reset the counter at once: flags are
# GATHERED until SALA_RECYCLE_GATHER seconds pass with no newer flag (10 min), and never longer than SALA_RECYCLE_GATHER_MAX after
# the first flag gathered (30 min); then the job starts ONCE: the recycle's sweep opens one new flag, the counter reads 0/N against
# it, and the older flag's worker stops (one job). A flag from the owner's words (source op-recycle) waits for nothing, and a knob at 0
# turns the gathering off. What calls `sala recycle` directly (op recycle, provision, update, the master's cue) does not pass here: it
# starts at once, as before. The panes' own rest (SALA_RECYCLE_REST) is the sweep's: lib/revive.sh, rest_applies.
_job_file() { echo "$SALA_SET_DIR/job.${1:-recycle}"; }
_job_get() { _kv_first "$(_job_file recycle)" "$1"; }
_job_set() { mkdir -p "$SALA_SET_DIR"; _kv_set "$(_job_file recycle)" "$1" "$2" j; }
_job_del() { local f; f=$(_job_file recycle); [ -e "$f" ] || return 0; _kv_without "$f" "$1" > "$f.j.${BASHPID:-$$}" 2>/dev/null; mv -f "$f.j.${BASHPID:-$$}" "$f"; }
recycle_job_cur() {   # → the id of the job's newest flag while it is open, else nothing
    local p; p=$(cat "$(_set_scope_file recycle)" 2>/dev/null)
    if [ -n "$p" ] && set_has "$p" && [ "$(set_val "$p" closed)" != 1 ]; then echo "$p"; fi
    return 0
}
gather_clear() { local k; for k in gather_first gather_last gather_keys gather_posted; do _job_del "$k"; done; }
recycle_job_gate() {   # <source> <flag key…> → 0: start now · 1: later (one line on stdout says why and when)
    local src="$1"; shift
    [ "$src" = op-recycle ] && return 0
    { [ "${SALA_RECYCLE_GATHER:-0}" -gt 0 ] && [ "${SALA_RECYCLE_GATHER_MAX:-0}" -gt 0 ]; } 2>/dev/null || return 0
    local cur now first last known k new=0 due due2
    cur=$(recycle_job_cur)
    if [ -z "$cur" ]; then gather_clear; return 0; fi
    _now_r now; first=$(_job_get gather_first); known=" $(_job_get gather_keys) "
    if [ -z "$first" ]; then
        first=$now; last=$now; _job_set gather_first "$first"; _job_set gather_last "$last"; _job_set gather_keys "$*"
    else
        last=$(_job_get gather_last); : "${last:=$first}"
        for k in "$@"; do case "$known" in *" $k "*) ;; *) new=1; known="$known$k ";; esac; done
        if [ "$new" = 1 ]; then last=$now; _job_set gather_last "$last"; known=${known# }; _job_set gather_keys "${known% }"; fi
    fi
    due=$((last + SALA_RECYCLE_GATHER)); due2=$((first + SALA_RECYCLE_GATHER_MAX)); [ "$due2" -lt "$due" ] && due=$due2
    [ "$now" -ge "$due" ] && return 0
    echo "the job of $(set_val "$cur" kind) $(set_val "$cur" label) is unfinished: waiting for flags to settle, it resets at $(local_clock "$due") (later while more come, at the latest $(local_clock "$due2"))"
    return 1
}
gather_note() {   # <line> — the one short post of a gathering: the job's own 🔄 headline, the line as its bullet; not repeated until the next gathering
    local cur first; cur=$(recycle_job_cur); first=$(_job_get gather_first)
    [ -n "$cur" ] && [ -n "$first" ] && [ "$(_job_get gather_posted)" != "$first" ] || return 0
    _job_set gather_posted "$first"
    sala_post "🔄 *$(set_val "$cur" kind) $(set_val "$cur" label) · $(set_val "$cur" done)/$(set_val "$cur" total)*" "$1"
}
set_prune() {  # watch: closed sets after 3 days, any set after 9 (a deferred pane may wait 8), pointers after 3
    [ -d "$SALA_SET_DIR" ] || return 0
    local f
    find "$SALA_SET_DIR" -maxdepth 1 -type f ! -name .lock ! -name .reconciled ! -name 'job.*' -mmin +4320 2>/dev/null | while IFS= read -r f; do
        case "${f##*/}" in
            current.*|*.t.*) rm -f "$f";;
            *) if grep -qx 'closed=1' "$f" || [ -n "$(find "$f" -mmin +12960 2>/dev/null)" ]; then rm -f "$f"; fi;;
        esac
    done
}

# ── provision sets ────────────────────────────────────────────────────────────
# A PROVISION SET is one `sala provision` run that left something on a box: the recycle set's
# machinery above with kind Provision, scope provision, its boxes as the set's units (N = boxes in the run, n = boxes OK; a
# box is OK when it has nothing left) and the box's leftover ITEMS under it. A clean run (every box OK, nothing left) is
# no set: provision's single fleet post, as before. Items, one per step that reported `failed` or `manual`:
#   failed  → provision's retry worker re-runs `provision --no-recycle <host…>` every SALA_RETRY_EVERY for SALA_RETRY_WINDOW
#             (the recycle retry worker's settings); a step that comes back ok/fixed settles its item
#   session → a session can fix it: the master is told (one inbox message per batch, the settle command in it); it fixes
#             the item and settles it (`sala provision --settle`)
#   owner   → the owner decides: the master files a board item (needs: decision), records "<id> is waiting on your OK in
#             <session>" (`sala provision --waiting`; that text replaces the item's detail in later posts), runs the step
#             once the answer is in and settles it. sala itself never calls stackshot: the text is opaque to it.
# The kind is the step line's optional 5th field, STEP|manual|<name>|<detail>|<session|owner> (none = owner). A box OFFLINE at run
# time is outstanding with no item and no worker: `watch` provisions it once the heartbeat store says it answers ssh again, and any later named run of it settles it into
# the SAME open set (provision routes a box outstanding in an open set to that set instead of a new one). Give-up: a
# failed item at the end of the worker's window; any other item, and an offline box, SALA_PROVISION_SET_WINDOW (7 days)
# after it appeared — a board decision can take days, and set_prune drops any set after 9, so the "closed at n/N" post
# comes out before the state is gone. Posts: the first (⚠️ · n/N OK, one bullet per box with leftovers, its items as ◦
# sub-bullets; the OK boxes in one bullet); then one per pass that changes a box (🔄 · n/N OK, ✅ … · set closed when it
# empties the set); "⚠️ … closed at n/N" once, when nothing is outstanding and something was given up.
# State keys besides the recycle set's: item=<host>|<step>|<kind>|<since>|<word>|<detail> · wait=<host>|<step>|<text> ·
# fix=<host>|<note> (what settled an item, for the box's ✅ bullet) · okn=<host>|<steps OK> · offline=<host> ·
# tell=<host>|<step> (a session/owner item the master has not been told yet; `watch` redelivers).
: "${SALA_PSET_TARGET:=}"                         # a front agent that takes a provision set's items when there is no master (see pset_tell)
: "${SALA_PROVISION_SET_WINDOW:=604800}"
SALA_STEP_WORDS="${SALA_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/step-words.tsv"
# the box's own rows (a spec's own steps, same columns), read before the tracked table: a row there wins (config.example)
SALA_STEP_WORDS_MINE="${XDG_CONFIG_HOME:-$HOME/.config}/salamander/step-words.tsv"
SALA_PSET_LOG="$SALA_LOG_DIR/salamander-provision-sets.log"
pset_log() { local _t; [ -d "$SALA_LOG_DIR" ] || mkdir -p "$SALA_LOG_DIR"; _iso_now_r _t; echo "[$_t] $*" >> "$SALA_PSET_LOG"; }
step_word() { local w="" f fs=(); for f in "$SALA_STEP_WORDS_MINE" "$SALA_STEP_WORDS"; do [ -r "$f" ] && fs+=("$f"); done
    [ ${#fs[@]} -gt 0 ] && w=$(awk -F'\t' -v k="$1" '$1==k && !/^#/ {print $2; exit}' "${fs[@]}"); echo "${w:-$1}"; }
# pstep_parse <STEP line> → "<status>\t<name>\t<detail>\t<kind>"; the 5th field split off any line; kind: failed for a
# failed step, session|owner for a manual one (none given = owner), empty otherwise
_pstep_row_r() {  # <var> <STEP line> → the row pstep_parse prints, in <var> (no subshell and no tr)
    local l="${2#STEP|}" st name detail="" kind=""
    l=${l//[$'\t\r']/ }; st="${l%%|*}"; l="${l#*|}"; name="${l%%|*}"; [ "$l" != "$name" ] && detail="${l#*|}"
    case "$detail" in *'|session') kind=session; detail="${detail%|session}";; *'|owner') kind=owner; detail="${detail%|owner}";; esac
    case "$st" in failed) kind=failed;; manual) kind=${kind:-owner};; *) kind="";; esac
    printf -v "$1" '%s\t%s\t%s\t%s' "$st" "$name" "$detail" "$kind"
}
pstep_parse() { local _r; _pstep_row_r _r "$1"; printf '%s\n' "$_r"; }
pset_open() {  # (the two greps and the basename are the shell's own)
    local f l k=0 c=0; for f in "$SALA_SET_DIR"/[0-9]*; do
        [ -f "$f" ] || continue; case "$f" in *.t.*) continue;; esac
        k=0; c=0; { while IFS= read -r l || [ -n "$l" ]; do [ "$l" = kind=Provision ] && k=1; [ "$l" = closed=0 ] && c=1; done < "$f"; } 2>/dev/null
        [ "$k" = 1 ] && [ "$c" = 1 ] && printf '%s\n' "${f##*/}" 2>/dev/null   # (silent when the reader has left: a builtin's EPIPE message)
    done; return 0
}
pset_open_for() { local id; for id in $(pset_open); do grep -qxF "out=$1" "$SALA_SET_DIR/$id" && echo "$id"; done; return 0; }   # <host> → the open sets it is outstanding in
_pset_items() { set_vals "$1" item | awk -F'|' -v h="${2:-}" 'h == "" || $1 == h'; }   # <id> [host] → item values
_pset_item() { set_vals "$1" item | awk -F'|' -v h="$2" -v s="$3" '$1 == h && $2 == s {print; exit}'; }   # <id> <host> <step>
_pset_wait() { set_vals "$1" wait | awk -F'|' -v h="$2" -v s="$3" '$1 == h && $2 == s {print substr($0, length(h) + length(s) + 3); exit}'; }
_set_dropp() { local f="$SALA_SET_DIR/$1" t="$SALA_SET_DIR/$1.t.${BASHPID:-$$}"; awk -v p="$2=$3" 'index($0, p) != 1' "$f" > "$t"; mv -f "$t" "$f"; }   # <id> <key> <value prefix>
_pset_has_gave() { set_vals "$1" gave | grep -q "^$2[ :]"; }
pset_worker_live() { local f="$SALA_LOG_DIR/salamander-pretry.$1.pid"; [ -s "$f" ] && kill -0 "$(cat "$f")" 2>/dev/null; }
boxes() { if [ "$1" = 1 ]; then echo "1 box"; else echo "$1 boxes"; fi; }
# _pset_box <id> <host> → the box's bullet and its items as "◦ " sub-bullets, one per line
_pset_box() {
    local id="$1" h="$2" k okn it st w
    if grep -qxF "offline=$h" "$SALA_SET_DIR/$id"; then echo "$h: offline, sala provisions it when it's back"; return; fi
    k=$(_nlines "$(_pset_items "$id" "$h")"); okn=$(set_vals "$id" okn | awk -F'|' -v h="$h" '$1 == h {print $2; exit}')
    echo "$h: $([ "${okn:-0}" = 1 ] && echo "1 step OK" || echo "${okn:-0} steps OK"), $k left"
    _pset_items "$id" "$h" | while IFS='|' read -r _ st _ _ w it; do
        echo "◦ $w: $(_pset_wait "$id" "$h" "$st" | grep . || echo "$it")"
    done
}
_pset_drop_item() {  # <id> <host> <step> — the item and what hangs on it (wait, tell)
    local it; it=$(_pset_item "$1" "$2" "$3"); [ -n "$it" ] && _set_drop "$1" item "$it"
    _set_dropp "$1" wait "$2|$3|"; _set_drop "$1" tell "$2|$3"
}
_pset_box_ok() { _set_drop "$1" out "$2"; _set_put "$1" done $(( $(set_val "$1" done) + 1 )); }
# _pset_box_check <id> <host> [back] → prints the box's ✅ bullet when it just became OK (nothing left, nothing given up);
# a box with nothing left but something given up stops being outstanding, uncounted
_pset_box_check() {
    local id="$1" h="$2" notes okn
    _set_out "$id" "$h" || return 0
    grep -qxF "offline=$h" "$SALA_SET_DIR/$id" && return 0
    [ -z "$(_pset_items "$id" "$h")" ] || return 0
    if _pset_has_gave "$id" "$h"; then _set_drop "$id" out "$h"; return 0; fi
    notes=$(set_vals "$id" fix | awk -F'|' -v h="$h" '$1 == h {print substr($0, length(h) + 2)}' | paste -sd, - | sed 's/,/, /g')
    okn=$(set_vals "$id" okn | awk -F'|' -v h="$h" '$1 == h {print $2; exit}')
    [ -z "$notes" ] && [ "${3:-}" = back ] && notes="back online, ${okn:-0} steps OK"
    _pset_box_ok "$id" "$h"; echo "$h: ${notes:-provisioned}, $(set_after "$id")"
}
_pset_settle_item() {  # <id> <host> <step> ok|gave <note> — the item's end (under the lock); the box's ✅ bullet, if any, on stdout
    local id="$1" h="$2" s="$3" how="$4" note="$5" it w
    it=$(_pset_item "$id" "$h" "$s"); [ -n "$it" ] || return 0
    w=$(printf '%s' "$it" | cut -d'|' -f5)
    if [ "$how" = ok ]; then _set_add "$id" fix "$h|${note:-$w done}"; else _set_add "$id" gave "$h $w: ${note:-given up}"; fi
    _pset_drop_item "$id" "$h" "$s"
}
# pset_create <id> <result dir> <host…> — a run's new set (the run left something): written whole, then its first post
pset_create() {
    local id="$1" d="$2"; shift 2; local h N=$# nok=0 kv=() line st name detail kind okn left now b=() off=() bx
    now=$(date +%s)
    for h in "$@"; do
        if [ "$(cat "$d/$h.mark" 2>/dev/null)" = "⏭️" ]; then kv+=("out=$h" "offline=$h"); continue; fi
        okn=0; left=0
        [ -f "$d/$h.steps" ] || { kv+=("item=$h|run|failed|$now|$(step_word run)|no result, see the log"); left=1; }
        _stepf=$d/$h.steps; [ -f "$_stepf" ] || _stepf=/dev/null
        while IFS= read -r line; do
            [[ $line == 'STEP|'* ]] || continue
            _pstep_row_r _psr "$line"; IFS=$'\t' read -r st name detail kind <<< "$_psr"
            case "$st" in
                ok|fixed) okn=$((okn+1)) ;;
                failed|manual) left=$((left+1)); kv+=("item=$h|$name|$kind|$now|$(step_word "$name")|$detail"); [ "$kind" = failed ] || kv+=("tell=$h|$name") ;;
            esac
        done < "$_stepf"
        kv+=("okn=$h|$okn")
        if [ "$left" = 0 ]; then nok=$((nok+1)); else kv+=("out=$h"); fi
    done
    set_create "$id" Provision provision "$N" "$nok" - 1 "${kv[@]}"
    [ "$nok" -gt 0 ] && b+=("$(boxes "$nok") provisioned")
    for h in $(set_vals "$id" out); do
        mapfile -t bx < <(_pset_box "$id" "$h")
        if grep -qxF "offline=$h" "$SALA_SET_DIR/$id"; then off+=("${bx[@]}"); else b+=("${bx[@]}"); fi
    done
    pset_log "set $id: $nok/$N OK, $(set_count "$id" item) item(s), $(set_count "$id" offline) offline"
    sala_post "⚠️ *Provision $(set_val "$id" label) · $nok/$N OK*" ${b[@]+"${b[@]}"} ${off[@]+"${off[@]}"}
}
# _pset_apply <id> <result dir> <host…> — a later run of boxes outstanding in this set (a retry, watch's provision of a box
# back online, any named run): steps back ok/fixed settle their items; new leftovers join the set (a session/owner one
# to be told); one post for the pass when a box became OK or new leftovers joined (under the lock)
_pset_apply() {
    local id="$1" d="$2"; shift 2; local h oks=() ex=() now line st name detail kind okn back joined it b bx
    set_has "$id" && [ "$(set_val "$id" closed)" != 1 ] || return 0
    now=$(date +%s)
    for h in "$@"; do
        _set_out "$id" "$h" || continue
        [ "$(cat "$d/$h.mark" 2>/dev/null)" = "⏭️" ] && continue   # still asleep: nothing changes
        [ -f "$d/$h.steps" ] || continue
        back=""; grep -qxF "offline=$h" "$SALA_SET_DIR/$id" && { back=back; _set_drop "$id" offline "$h"; }
        okn=0; joined=0
        while IFS= read -r line; do
            [[ $line == 'STEP|'* ]] || continue
            _pstep_row_r _psr "$line"; IFS=$'\t' read -r st name detail kind <<< "$_psr"
            it=$(_pset_item "$id" "$h" "$name")
            case "$st" in
                ok|fixed) okn=$((okn+1)); [ -n "$it" ] && _pset_settle_item "$id" "$h" "$name" ok "$(step_word "$name") $([ "$st" = fixed ] && echo fixed || echo "OK now")" ;;
                failed|manual) [ -n "$it" ] && continue
                    _set_add "$id" item "$h|$name|$kind|$now|$(step_word "$name")|$detail"; [ "$kind" = failed ] || _set_add "$id" tell "$h|$name"; joined=1 ;;
            esac
        done < "$d/$h.steps"
        _set_dropp "$id" okn "$h|"; _set_add "$id" okn "$h|$okn"
        b=$(_pset_box_check "$id" "$h" "$back")
        if [ -n "$b" ]; then oks+=("$b")
        elif _set_out "$id" "$h" && { [ "$joined" = 1 ] || [ -n "$back" ]; }; then mapfile -t bx < <(_pset_box "$id" "$h"); ex+=("${bx[@]}"); fi
    done
    pset_log "set $id: a run of $* — $(set_val "$id" done)/$(set_val "$id" total) OK, $(set_count "$id" item) item(s) open"
    _set_close_posts "$id" ${oks[@]+"${oks[@]}"} -- ${ex[@]+"${ex[@]}"}
}
# _pset_settle <id> <host> <step> ok|gave [note] — `sala provision --settle` (under the lock)
_pset_settle() {
    local id="$1" h="$2" s="$3" how="$4" note="${5:-}" b
    set_has "$id" && [ "$(set_val "$id" kind)" = Provision ] || { echo "✗ no provision set $id (open ones: $(pset_open | tr '\n' ' '))"; return 1; }
    [ "$(set_val "$id" closed)" != 1 ] || { echo "✗ provision set $id is closed already"; return 1; }
    [ -n "$(_pset_item "$id" "$h" "$s")" ] || { echo "✗ set $id has no open item $s on $h (open: $(_pset_items "$id" | cut -d'|' -f1,2 | tr '\n' ' '))"; return 1; }
    _pset_settle_item "$id" "$h" "$s" "$how" "$note"
    b=$(_pset_box_check "$id" "$h")
    pset_log "set $id: $h $s settled $how${note:+ ($note)}"
    _set_close_posts "$id" ${b:+"$b"}
    echo "✓ $h $s settled ($how) in Provision $(set_val "$id" label): $(set_val "$id" done)/$(set_val "$id" total) OK, $(_nlines "$(_pset_items "$id")") item(s) still open$([ "$(set_val "$id" closed)" = 1 ] && echo ', set closed')"
}
# _pset_waiting <id> <host> <step> <text> — `sala provision --waiting`: the text stands in for the item's detail from now on
_pset_waiting() {
    local id="$1" h="$2" s="$3" t="$4"
    set_has "$id" && [ "$(set_val "$id" kind)" = Provision ] && [ "$(set_val "$id" closed)" != 1 ] || { echo "✗ no open provision set $id (open ones: $(pset_open | tr '\n' ' '))"; return 1; }
    [ -n "$(_pset_item "$id" "$h" "$s")" ] || { echo "✗ set $id has no open item $s on $h"; return 1; }
    _set_dropp "$id" wait "$h|$s|"; _set_add "$id" wait "$h|$s|$t"; pset_log "set $id: $h $s waiting — $t"
    echo "✓ $h $s in Provision $(set_val "$id" label): \"$t\" (later posts show it in place of the detail)"
}
# _pset_expire <id> [worker-end] — the give-ups (under the lock): a failed item once no worker is left and its window
# (SALA_RETRY_WINDOW) has passed, or at once at the worker's end; any other item and an offline box after
# SALA_PROVISION_SET_WINDOW. Then the "closed at n/N" post, once, if that left nothing outstanding.
_pset_expire() {
    local id="$1" end="${2:-}" now h s kind since w det wt gb live=0 touched=() t0
    set_has "$id" && [ "$(set_val "$id" closed)" != 1 ] || return 0
    now=$(date +%s); pset_worker_live "$id" && live=1
    while IFS='|' read -r h s kind since w det; do
        [ -n "$h" ] || continue
        if [ "$kind" = failed ]; then
            if [ "$end" != worker-end ]; then [ "$live" = 0 ] && [ "$now" -ge $(( since + SALA_RETRY_WINDOW + SALA_RETRY_EVERY )) ] || continue; fi
            gb="$h $w: still failing after $(dur_words "$SALA_RETRY_WINDOW") ($det)"
        else
            [ "$now" -ge $(( since + SALA_PROVISION_SET_WINDOW )) ] || continue
            wt=$(_pset_wait "$id" "$h" "$s")
            if [ -n "$wt" ]; then gb="$h $w: ${wt/ is waiting / is still waiting }"; else gb="$h $w: still open after $(dur_words "$SALA_PROVISION_SET_WINDOW") ($det)"; fi
        fi
        _set_add "$id" gave "$gb"; _pset_drop_item "$id" "$h" "$s"; touched+=("$h")
    done < <(_pset_items "$id")
    t0=$(set_val "$id" t0)
    if [ "$end" != worker-end ] && [ "$now" -ge $(( t0 + SALA_PROVISION_SET_WINDOW )) ]; then
        for h in $(set_vals "$id" offline); do _set_add "$id" gave "$h: still offline after $(dur_words "$SALA_PROVISION_SET_WINDOW")"; _set_drop "$id" offline "$h"; touched+=("$h"); done
    fi
    [ ${#touched[@]} -gt 0 ] || return 0
    pset_log "set $id: gave up on ${touched[*]}"
    for h in "${touched[@]}"; do _pset_box_check "$id" "$h" >/dev/null; done   # nothing left but something given up: no longer outstanding
    _set_close_posts "$id"
}
pset_expire() { _set_locked _pset_expire "$@"; }
_pset_tell_text() {  # <id> → the master's message for the items not told yet (empty: nothing to tell)
    local id="$1" e h s it w det kind ss="" hw="" n=0
    for e in $(set_vals "$id" tell); do
        h="${e%%|*}"; s="${e#*|}"; it=$(_pset_item "$id" "$h" "$s"); [ -n "$it" ] || continue
        kind=$(printf '%s' "$it" | cut -d'|' -f3); w=$(printf '%s' "$it" | cut -d'|' -f5); det=$(printf '%s' "$it" | cut -d'|' -f6-); n=$((n+1))
        if [ "$kind" = session ]; then
            ss="$ss"$'\n'"• $h · $s$([ "$w" != "$s" ] && echo " ($w)"): $det"$'\n'"  sala provision --settle $id $h $s ok \"<what was done, in plain words>\""
        else
            hw="$hw"$'\n'"• $h · $s$([ "$w" != "$s" ] && echo " ($w)"): $det"$'\n'"  sala provision --waiting $id $h $s \"<item id> is waiting on your OK in <your session>\""$'\n'"  sala provision --settle $id $h $s ok \"<what was done, in plain words>\""
        fi
    done
    [ "$n" -gt 0 ] || return 0
    printf '%s\n' "[sala provision] Provision $(set_val "$id" label) (set $id) left $n item(s) for you. Each command below is one plain call: run them one at a time."
    [ -n "$ss" ] && printf '\n%s%s\n' "A session can fix these: fix each (you, or hand it to the session that owns it), then settle it:" "$ss"
    [ -n "$hw" ] && printf '\n%s%s\n' "These need ${SALA_OWNER_NAME}: file a board item for each (needs: decision) and record it with --waiting; once the answer is in, run the step and settle it:" "$hw"
    printf '\n%s\n' "An item that cannot be done: sala provision --settle $id <host> <step> gave \"<why, in plain words>\". sala makes the set's Slack posts from these calls; post nothing yourself. Open items: sala provision --sets"
}
_pset_told() { local id="$1" e; shift; for e in "$@"; do _set_drop "$id" tell "$e"; done; _set_dropp "$id" tellfail ""; }
# _inbox_push <session> <text> → 0 delivered into that session's inbox as a turn (the delivery `sala cue` uses: the pane,
# its claude, its messaging socket); 2 not live, 4 no socket or the push failed
_inbox_push() {
    local target="$1" pane mpid="" sock
    pane=$(tmux list-panes -t "$(tmux_win_t "$target")" -F '#{pane_id}' 2>/dev/null | head -1)
    [ -n "$pane" ] && mpid=$(claude_pid_under "$(tmux display -p -t "$pane" '#{pane_pid}')" 2>/dev/null)
    [ -n "$mpid" ] || return 2
    sock=$(session_socket "$mpid"); [ -n "$sock" ] || return 4
    session_push "$sock" "$2" >/dev/null 2>&1 || return 4
}
# master_push <text> → 0 delivered into the master's inbox as a turn (`_inbox_push`); 1 no master configured, 2 not live,
# 4 no socket or the push failed
master_push() {
    local target="${SALA_CUE_TARGET:-${SALA_MASTER:-}}"
    [ -n "$target" ] || return 1
    _inbox_push "$target" "$1"
}
# pset_tell <id> — tell the master about the set's session/owner items not told yet; a failed delivery stays pending
# (`watch` tries again every tick) and is logged once until it goes through. NO MASTER: SALA_MASTER unset
# (master_push 1) → the items go out as one Slack post naming `sala provision --sets`, and count as told (nothing to retry
# against). SALA_PSET_TARGET (a session name, unset = none) is a front agent that takes the same text, `[for <owner>]` on its
# first line, only when NO master is configured (SALA_MASTER unset, master_push 1). A configured master wins whatever its
# state: live it hears the items; not live (2, e.g. mid-recycle) or a failed push (4) the items stay pending and `watch`
# retries, the target never told. A target that is not live or whose push fails changes nothing: the Slack post.
pset_tell() {
    local id="$1" txt tells rc=0 trc=0
    # the list first, then the text: an item added in between is sent and told again later, never marked told unsent
    mapfile -t tells < <(set_vals "$id" tell)
    txt=$(_set_locked _pset_tell_text "$id"); [ -n "$txt" ] || return 0
    master_push "$txt" || rc=$?
    if [ "$rc" = 1 ] && [ -n "${SALA_PSET_TARGET:-}" ]; then
        _inbox_push "$SALA_PSET_TARGET" "[for ${SALA_OWNER_NAME}]"$'\n'"$txt" || trc=$?
        if [ "$trc" = 0 ]; then
            _set_locked _pset_told "$id" "${tells[@]}"; pset_log "set $id: no master session — told $SALA_PSET_TARGET about ${#tells[@]} item(s)"; return 0
        fi
        pset_log "set $id: no master session and $SALA_PSET_TARGET (SALA_PSET_TARGET) could not be told (exit $trc)"
    fi
    if [ "$rc" = 1 ]; then
        sala_post "⚠️ *Provision $(set_val "$id" label) left $(plural "${#tells[@]}" item) with nobody to hand them to*" "no master session is configured, so they are posted here instead of a session's inbox" "the items and the commands that settle them: sala provision --sets (set $id)" "Details: $SALA_PSET_LOG"
        _set_locked _pset_told "$id" "${tells[@]}"; pset_log "set $id: no master session — ${#tells[@]} item(s) posted to Slack instead"; return 0
    fi
    if [ "$rc" = 0 ]; then _set_locked _pset_told "$id" "${tells[@]}"; pset_log "set $id: told the master about ${#tells[@]} item(s)"; return 0; fi
    [ -n "$(set_val "$id" tellfail)" ] && return 0
    _set_locked _set_put "$id" tellfail "$(date +%s)"; pset_log "set $id: could not tell the master (exit $rc) — watch tries again"
}
# pset_worker <id> — the set's retry worker for its failed items, detached, one per set
pset_worker() {
    pset_worker_live "$1" && return 0
    local detach=setsid; command -v setsid >/dev/null 2>&1 || detach=nohup
    $detach "$SALA_BIN" provision --retry-worker "$1" </dev/null >>"$SALA_PSET_LOG" 2>&1 9>&- &
}
_pset_failed_hosts() { _pset_items "$1" | awk -F'|' '$3 == "failed" {print $1}' | sort -u; }
pset_followup() { pset_tell "$1"; [ -n "$(_pset_failed_hosts "$1")" ] && [ "${SALA_PSET_WORKER:-}" != "$1" ] && pset_worker "$1"; return 0; }
# one writer at a time: a recycle holds and releases from parallel jobs since the first release, and the lists are edited by
# read-modify-write, so two unserialized holds would lose one key (a mkdir lock, portable; the section is milliseconds
# long, so a lock older than 10 s belongs to a dead holder and is taken over)
# one editor at a time, blocking: flock (kernel-released, never broken by a waiter) on fd 8 (fd 9 is the recycle lock);
# the mkdir lock only where flock is missing (macOS). Why: the old mkdir lock broke itself after 10 s under the
# three-phase recycle's many parallel releases, and two holds were left behind (one with no ledger row, so never freed).
_hold_lock() {
    if command -v flock >/dev/null 2>&1; then exec 8>"$SALA_INBOX_LEDGER.lock"; flock -w 60 8 || true; return 0; fi
    local d="$SALA_INBOX_LEDGER.lock.d" i; for ((i=0; i<200; i++)); do mkdir "$d" 2>/dev/null && return 0; sleep 0.05; done; rm -rf "$d"; mkdir "$d" 2>/dev/null || true
}
_hold_unlock() { if command -v flock >/dev/null 2>&1; then flock -u 8 2>/dev/null; exec 8>&-; else rmdir "$SALA_INBOX_LEDGER.lock.d" 2>/dev/null; fi; }
_hold_edit() {  # <add|del> <key…> — on both held lists, atomically per file, only the keys given
    local op="$1"; shift; local f k tmp
    [ -d "$SALA_INBOX_HOLD_DIR" ] || return 0
    for f in "$SALA_INBOX_HOLD_DIR/held-msg.txt" "$SALA_INBOX_HOLD_DIR/held-hub.txt"; do
        tmp="$f.sala.${BASHPID:-$$}.$RANDOM"; { [ -f "$f" ] && cat "$f"; } > "$tmp" 2>/dev/null
        for k in "$@"; do
            [ -n "$k" ] || continue
            if [ "$op" = add ]; then grep -qxF -- "$k" "$tmp" || printf '%s\n' "$k" >> "$tmp"
            else grep -vxF -- "$k" "$tmp" > "$tmp.2"; mv -f "$tmp.2" "$tmp"; fi
        done
        mv -f "$tmp" "$f"
    done
}
inbox_hold() {
    [ -d "$SALA_INBOX_HOLD_DIR" ] || return 0
    _hold_lock; _hold_edit add "$1" "$2"; printf '%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" >> "$SALA_INBOX_LEDGER"; _hold_unlock
}
inbox_touch() {  # <uuid> <name> — a hold still wanted is written again with the time now, so inbox_release_stale (10 min by the ledger row) does not drop it from under a pane that waits longer (a long sweep, the --self re-check wait)
    [ -d "$SALA_INBOX_HOLD_DIR" ] || return 0
    _hold_lock
    local lt="$SALA_INBOX_LEDGER.${BASHPID:-$$}.$RANDOM"
    [ -f "$SALA_INBOX_LEDGER" ] && { grep -vF -- "	$1	" "$SALA_INBOX_LEDGER" > "$lt"; mv -f "$lt" "$SALA_INBOX_LEDGER"; }
    _hold_edit add "$1" "$2"; printf '%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" >> "$SALA_INBOX_LEDGER"
    _hold_unlock; return 0
}
inbox_release() {
    [ -d "$SALA_INBOX_HOLD_DIR" ] || return 0
    if [ "${3:-}" = wait ]; then   # the new process must own a socket before lines may flow again
        local i lp; for i in $(seq 1 30); do lp=$(live_pane_for_uuid "$1" 2>/dev/null) && [ -n "$(session_socket "${lp%% *}")" ] && break; sleep 1; done
    fi
    _hold_lock; _hold_edit del "$1" "$2"
    local lt="$SALA_INBOX_LEDGER.${BASHPID:-$$}.$RANDOM"   # named once: in a redirect $BASHPID is the forked grep's pid
    [ -f "$SALA_INBOX_LEDGER" ] && { grep -vF -- "	$1	" "$SALA_INBOX_LEDGER" > "$lt"; mv -f "$lt" "$SALA_INBOX_LEDGER"; }
    _hold_unlock; return 0
}
inbox_release_stale() {  # holds a relaunch never released (it died): drop those older than 10 min
    [ -s "$SALA_INBOX_LEDGER" ] || return 0
    local now t u n; now=$(date +%s)
    while IFS=$'\t' read -r t u n; do [ $((now - ${t:-0})) -ge 600 ] && inbox_release "$u" "$n"; done < <(cat "$SALA_INBOX_LEDGER")
}

# agent_unlisted <name> → prints the refusal and returns 0 when <name> is an agent name its project page does not list yet
# (stackshot's `pages.py agent-listed`, exit 3; an agent's `agents:` line must exist before it is spawned
# or renamed into, so that it is guaranteed to be handled). Anything else — not an agent name, listed, the script missing, a
# python error, a timeout — returns 1: fail-open, a broken check never blocks a spawn. SALA_AGENT_CHECK=off skips it
# (tests); sala-test-* names are never checked.
agent_unlisted() {
    [ "${SALA_AGENT_CHECK:-on}" = off ] && return 1
    case "$1" in sala-test-*|*-side-*) return 1 ;; esac   # a side session (THE SIDE SESSIONS below) is on no page's agents map by design
    project_record_agent "" "$1" >/dev/null && return 1   # stackshot's project record lists the name (on any project): not unlisted, pages.py is not asked
    local py out rc; py=$(agent_check_script) || return 1
    out=$(timeout 10 python3 "$py" agent-listed "$1" 2>&1); rc=$?
    [ "$rc" = 3 ] || return 1
    _lastline "${out:-'$1' is an agent name its project page does not list yet}"
}
# THE RENAME RENAMES ITS ENTRY ON THE PROJECT'S PAGE (Tue Oct 27th 2026; lib/rename.sh): `rename OLD NEW` used to refuse a NEW its
# project's page does not list, so only the page's keeper could unblock it (each time a trip to the project's -main).
# Now the rename asks stackshot for the in-place rename of OLD's entry: `client.py post project-agent-rename <project> OLD NEW --sender
# sala-rename` (the New session form's gate: the label in stackshot's [project_agent] form_senders, honored from this box only, form_machines).
# The server keeps the entry's mandate, line, place in the map and front/background side, and writes the page through gbrain; sala keeps
# none of that and copies nothing. The project is the hub page pages.py's refusal names (both its wordings: "(the page whose `display-name:`
# …" and the older "(steward …"). Outcomes of the call: exit 0 with JSON `result` "renamed" (done) or "already renamed" (OLD gone, NEW listed:
# done only for a rename sala itself started, a retry after a lost reply; the server keeps no record of OLD, so a mistyped OLD with an existing
# NEW answers the same; sala remembers what it started in $SALA_RENAME_MARK and refuses an "already renamed" it cannot match to one); exit 1
# with the reason on stderr (409 NEW already listed or another project's, 404 OLD not listed, 403 not the form, 400 prefix / ambiguous slug /
# not a hub, 422, 502, [0] stackshot not reached) is a refusal: nothing renamed. SALA_RENAME_SENDER overrides the label.
: "${SALA_RENAME_SENDER:=sala-rename}"
: "${SALA_RENAME_MARK:=$SALA_STATE_DIR/rename-listed.tsv}"   # epoch TAB OLD TAB NEW: the renames sala started on a page (kept 3 days)
stackshot_client() {  # → the path of stackshot's client (SALA_STACKSHOT_CLIENT, else stackshot/fleet/client.py under SALA_STACKSHOT_DIR, or client.py there on an older checkout), or 1 with nothing
    local c="${SALA_STACKSHOT_CLIENT:-}"
    [ -n "$c" ] || stackshot_prog_r c "${SALA_STACKSHOT_DIR:-}" client
    [ -n "$c" ] && [ -f "$c" ] || return 1
    echo "$c"
}
rename_mark_has() {  # <OLD> <NEW> → rc 0 when sala started that rename on a page in the last 3 days
    [ -r "$SALA_RENAME_MARK" ] && awk -F'\t' -v o="$1" -v n="$2" -v min="$(( $(date +%s) - 259200 ))" '$1+0 >= min && $2 == o && $3 == n { f = 1 } END { exit !f }' "$SALA_RENAME_MARK"
}
rename_mark_add() {  # <OLD> <NEW> → remember that sala started this rename (older lines dropped)
    local t="$SALA_RENAME_MARK.$$"; mkdir -p "$(dirname "$SALA_RENAME_MARK")" 2>/dev/null
    { [ -r "$SALA_RENAME_MARK" ] && awk -F'\t' -v min="$(( $(date +%s) - 259200 ))" '$1+0 >= min' "$SALA_RENAME_MARK"; printf '%s\t%s\t%s\n' "$(date +%s)" "$1" "$2"; } > "$t" 2>/dev/null \
        && mv -f "$t" "$SALA_RENAME_MARK" 2>/dev/null || rm -f "$t"; true
}
# rename_list_plan <the refusal agent_unlisted printed> → rc 0: RL_HUB is the project (its hub page); rc 1: RL_WHY says why sala cannot name it
rename_list_plan() {
    local re='is not under `agents:` on ([^ ]+) \((the page|steward)'; RL_HUB="" RL_WHY=""
    [[ $1 =~ $re ]] || { RL_WHY="the check named no page to rename it on"; return 1; }
    RL_HUB=${BASH_REMATCH[1]}
}
# rename_list_run <OLD> <NEW> → rc 0: RL_RESULT ("renamed" | "already renamed") and RL_DETAIL (side, role and line the server answered) · rc 1: RL_WHY, nothing renamed
rename_list_run() {
    local old=$1 new=$2 c rc parsed; RL_RESULT="" RL_DETAIL="" RL_WHY=""
    c=$(stackshot_client) || { RL_WHY="no stackshot client.py on this box (SALA_STACKSHOT_CLIENT, SALA_STACKSHOT_DIR/stackshot/fleet/client.py)"; return 1; }
    RL_OUT=$(timeout 330 python3 "$c" post project-agent-rename "$RL_HUB" "$old" "$new" --sender "$SALA_RENAME_SENDER" 2>&1 </dev/null); rc=$?
    if [ "$rc" = 124 ]; then   # the outcome is unknown: remembered, so that running the rename again recognizes it
        rename_mark_add "$old" "$new"
        RL_WHY="stackshot did not answer within 330 s: the page may or may not be renamed; run the rename again (a retry of this one is recognized)"; return 1
    fi
    if [ "$rc" != 0 ]; then
        case "$RL_OUT" in *"[0]"*) rename_mark_add "$old" "$new" ;; esac   # not reached: the server may still have seen it
        RL_WHY="stackshot refused or did not answer (exit $rc): $(_lastline "$RL_OUT")"; return 1
    fi
    parsed=$(printf '%s\n' "$RL_OUT" | python3 -I -c '
import json, sys
try:
    d = json.loads([l for l in sys.stdin.read().splitlines() if l.strip()][-1])
    r = d["result"]
    if r not in ("renamed", "already renamed"): raise ValueError("result " + repr(r))
    print(r + "\t" + ("front" if d.get("front") else "background") + " agent, role " + str(d.get("role") or "?") + ", line: " + " ".join(str(d.get("mandate") or "").split())[:200])
except Exception as e:
    print("unreadable answer (%s)" % e); sys.exit(1)
' 2>&1) || { RL_WHY="stackshot answered exit 0 with $parsed"; return 1; }
    RL_RESULT=${parsed%%$'\t'*}; RL_DETAIL=${parsed#*$'\t'}
    if [ "$RL_RESULT" = renamed ]; then rename_mark_add "$old" "$new"; return 0; fi
    rename_mark_has "$old" "$new" && return 0
    RL_WHY="stackshot says '$old' is already gone from the page and '$new' is listed ($RL_DETAIL), but this machine did not start that rename: nothing was renamed here; if it is yours, the page's keeper confirms it"; return 1
}
# RETIRE DROPS THE AGENT ENTRY (Wed Oct 28th 2026; lib/retire.sh): a retired session must not stay a pending agent (page_owed) on its
# project, so once a retire has succeeded sala tells stackshot: `client.py post project-agent-retire <project> <name> --sender sala-retire`
# (SALA_RETIRE_SENDER overrides the label). Since Sat Oct 31st 2026 stackshot does the whole job itself: it removes the agent's line (and the lines
# below it) from the project page's `agents:` map, adds a timeline line, and drops a pending entry of the name. Answers: 200 with `result` "line removed"
# (the page's line is gone), "dropped" (the agent was only pending; no page written) or "not listed" (on no page, not pending: a repeat after a lost
# reply is this); refused, exit 1 with "[status] reason" on stderr: 502 gbrain did not give the page, refused the write twice, a read back does not show
# the removal, or the line is gone but the timeline line was not written (the reason says which: ask again if the line is still on the page; if only the timeline line is missing, add it by hand, since a repeat answers "not listed") · 422 the agents block cannot
# be edited in place (remove the line by hand) · 409 a rename or retire of the page is in progress · 404 unknown project · 400/403 a bad call. (client.py
# exits 0 on 200, 1 on the rest.) Nothing is an error for the retire, and neither is a failure or a timeout (90 s, stdin closed): the outcome is one
# line in $SALA_LOG_DIR/salamander-retire.log and one "ℹ" line in the retire's output, and the retire's exit and result are what they were; a 502 is
# said as its own line (ask again if the agent is still on the page; add the timeline line by hand if the reason says only that is missing), a 422 or 409 as "stackshot refused (status): reason", and a timeout adds that an immediate retry may get a 409 while stackshot finishes. The 90 s: stackshot reads the page, writes it back, reads it back and adds the
# timeline line, four gbrain calls in turn (more when a refused write is tried again); the old 45 s was sized for one read. The project is the registry row's
# `project` (read BEFORE the retire marks the row retired), else a side session's record project or its origin's, else the one stackshot's roles list
# gives the name (THE PROJECT FALLBACK, below); none known, or not a hub page key = no call, one log line. A dry run never calls.
: "${SALA_RETIRE_SENDER:=sala-retire}"
_row_project() {  # <session|id> → the `project` of its live registry row (stdout; empty when none)
    sessions_py resolve "$1" --live --json 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("project") or "")
except Exception: pass' 2>/dev/null
}
# THE PROJECT FALLBACK (rows `migrate` imported carry `project: None`, and half the retires logged "no project known"): with no project on the row or a
# side record, the project is the one stackshot's roles list gives the agent's name: `client.py get roles` ({"sessions": {name: {project, role}}}, under
# `timeout 20`, stdin closed), else the file stackshot's puller writes from the same list (SALA_ROLES_FILE, default ~/.local/state/stackshot/roles.json).
# A missing file, bad JSON, a client failure or a name the list lacks is "no project", never an error. The source is logged (retire_drop_agent).
: "${SALA_ROLES_FILE:=$HOME/.local/state/stackshot/roles.json}"
_roles_project() {  # <name> (roles JSON on stdin) → the project the roles list gives <name> (stdout; empty when none or unreadable)
    python3 -c 'import json,sys
try:
    p = json.load(sys.stdin)["sessions"][sys.argv[1]]["project"]
    print(p if isinstance(p, str) else "")
except Exception: pass' "$1" 2>/dev/null
}
RETIRE_PROJ="" RETIRE_PROJ_SRC=""
retire_project_of() {  # <session> [<conversation id>] → sets RETIRE_PROJ (the project page key its registry row, else side record, else the roles list gives; empty when none) and RETIRE_PROJ_SRC (where from); no stdout
    local n=$1 u=${2:-} p="" src="" origin c
    p=$(_row_project "$n")
    [ -n "$p" ] || [ -z "$u" ] || p=$(_row_project "$u")
    [ -z "$p" ] || src="its registry row"
    if [ -z "$p" ] && side_is "$n"; then
        p=$(side_val "$n" project); origin=$(side_val "$n" origin)
        [ -n "$p" ] || { [ -z "$origin" ] || p=$(side_origin_project "$origin"); }
        [ -z "$p" ] || src="its side record"
    fi
    if [ -z "$p" ] && c=$(stackshot_client); then
        p=$(timeout 20 python3 "$c" get roles 2>/dev/null </dev/null | _roles_project "$n")
        [ -z "$p" ] || src="stackshot's roles list (client.py get roles)"
    fi
    if [ -z "$p" ] && [ -r "$SALA_ROLES_FILE" ]; then
        p=$(_roles_project "$n" < "$SALA_ROLES_FILE")
        [ -z "$p" ] || src="stackshot's roles list (the file $SALA_ROLES_FILE)"
    fi
    RETIRE_PROJ=$p; RETIRE_PROJ_SRC=$src
}
retire_log() { local _t; _iso_now_r _t; echo "[$_t] $*" >> "$SALA_LOG_DIR/salamander-retire.log" 2>/dev/null; true; }
retire_drop_agent() {  # <session> <project> [<where the project came from>] → asks stackshot to take the agent off its project; ALWAYS 0: the outcome is a log line and an "ℹ" line, never an error
    local n=$1 proj=$2 src=${3:-} c out full rc said why status shown
    if [ -z "$proj" ]; then retire_log "$n: no project known for it, so stackshot was not asked to drop an agent entry"; return 0; fi
    [ -z "$src" ] || retire_log "$n: its project $proj came from $src"
    if ! page_key_ok "$proj"; then retire_log "$n: its project '$proj' is not a hub page key, so stackshot was not asked to drop an agent entry"; return 0; fi
    if ! c=$(stackshot_client); then retire_log "$n: no stackshot client.py on this box, so $proj was not asked to drop its agent entry"; return 0; fi
    # 90 s, not the 45 s of the old read-only call: stackshot now reads the page, writes it back, reads it back and adds a timeline line (RETIRE DROPS THE AGENT ENTRY, above)
    out=$(timeout 90 python3 "$c" post project-agent-retire "$proj" "$n" --sender "$SALA_RETIRE_SENDER" 2>&1 </dev/null); rc=$?
    if [ "$rc" = 124 ]; then out="stackshot did not answer within 90 s (the page may or may not be changed; an immediate retry may get a 409 \"in progress\" while stackshot finishes: ask again a little later)"; fi
    full=$out; out=$(_lastline "$out")
    # a long answer is cut in the MIDDLE, never at the end: a 502's reason ends with what is left to do (whether the timeline line was written)
    shown=$out; [ "${#shown}" -le 600 ] || shown="${out:0:100}…${out: -500}"
    status="" why=""
    if [[ $out =~ \[([0-9]{3})\]\ (.*)$ ]]; then status=${BASH_REMATCH[1]}; why=${BASH_REMATCH[2]}; [ "${#why}" -le 600 ] || why="${why:0:100}…${why: -500}"; fi
    retire_log "$n: project-agent-retire $proj (label $SALA_RETIRE_SENDER) → exit $rc${shown:+: $shown}"
    if [ "$rc" = 0 ]; then
        case $full in   # the client prints stackshot's JSON on one line: {"result": "line removed" | "dropped" | "not listed", ...}
            *'"result": "line removed"'*) said="stackshot removed '$n' from $proj's agents (its line is off the page; a timeline line says so)" ;;
            *'"result": "dropped"'*)      said="stackshot dropped '$n' from $proj (it was only pending: no page line to remove)" ;;
            *'"result": "not listed"'*)   said="'$n' is not on $proj's agents and not pending in stackshot: nothing to remove" ;;
            *)                            said="stackshot told to drop '$n' from $proj's agents${shown:+: $shown}" ;;
        esac
        echo "ℹ $said"
    elif [ "$rc" != 124 ] && [ "$status" = 502 ]; then   # gbrain did not give or take the page: the line may or may not be off it (the reason says which); the retire is done
        echo "ℹ stackshot could not finish taking '$n' off $proj's agents (502: $why): the retire itself is done; if the line is still on the page, ask again: python3 $c post project-agent-retire $proj $n --sender $SALA_RETIRE_SENDER; if the reason says the timeline line was not written, the line is gone (asking again then answers \"not listed\"): add the timeline line by hand"
    elif [ "$rc" != 124 ] && { [ "$status" = 422 ] || [ "$status" = 409 ]; }; then   # stackshot was told and refused (422 the agents block cannot be edited in place, 409 a rename or retire of the page is in progress)
        echo "ℹ stackshot refused ($status): $why; the retire itself is done"
    else echo "ℹ stackshot was not told to drop '$n' from $proj's agents (exit $rc${shown:+: $shown}; see $SALA_LOG_DIR/salamander-retire.log): the retire itself is done"; fi
    return 0
}
# RETIRE ASKS FOR OPEN ITEMS FIRST (lib/retire.sh): a Claude session that moves an open board item is not ended from under it. Before a retire acts,
# sala asks stackshot's client what the session moves: `client.py get items <session>` answers {"items": [{"shown": "board#N", "roles": ["mover"|"then"|"needs"], "held": bool, …}]},
# the open items the asking session has a part in. Those whose `roles` hold "mover" and that are not held (a held item waits for a wake or for another item and is nobody's
# move now) are the session's. The key is the tmux session's name, and the conversation id when the pane's claude is known (the server takes either, and a session answering to one of them
# is the same session). The command is SALA_RETIRE_ITEMS_CMD (a string word-split as side.sh's knobs are, the key appended; the tests stub it), else
# `python3 <stackshot_client> get items`. Result: 0 with RETIRE_ITEMS empty (none); 1 with RETIRE_ITEMS the ids, one line ("board#N, board#M"); 2 with RETIRE_ITEMS_WHY
# the reason stackshot could not be asked or its answer not read (no client.py, a failing client, a timeout, an answer that is not the items JSON): the retire is refused
# on that too, since it cannot tell, and --leave-items overrides both.
: "${SALA_RETIRE_ITEMS_CMD=}"
: "${SALA_RETIRE_ITEMS_TIMEOUT:=30}"
RETIRE_ITEMS="" RETIRE_ITEMS_WHY=""
retire_open_items() {  # <session> [<conversation id>] → 0 none · 1 some (RETIRE_ITEMS) · 2 cannot tell (RETIRE_ITEMS_WHY)
    local cmd="$SALA_RETIRE_ITEMS_CMD" c key out rc ids="" parsed
    RETIRE_ITEMS=""; RETIRE_ITEMS_WHY=""
    if [ -z "$cmd" ]; then
        c=$(stackshot_client) || { RETIRE_ITEMS_WHY="no stackshot client.py on this box (SALA_STACKSHOT_CLIENT, SALA_STACKSHOT_DIR/stackshot/fleet/client.py), so sala cannot ask what '$1' moves"; return 2; }
        cmd="python3 $c get items"
    fi
    for key in "$1" ${2:+"$2"}; do
        out=$(timeout --kill-after=5 "$SALA_RETIRE_ITEMS_TIMEOUT" sh -c "$cmd \"\$@\"" retire-items "$key" </dev/null 2>&1); rc=$?
        if [ "$rc" != 0 ]; then
            if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then RETIRE_ITEMS_WHY="stackshot did not answer within ${SALA_RETIRE_ITEMS_TIMEOUT} s when asked what '$key' moves"
            else RETIRE_ITEMS_WHY="stackshot's client failed (exit $rc) when asked what '$key' moves: $(_lastline "$out" | cut -c1-300)"; fi
            return 2
        fi
        parsed=$(python3 -c 'import json, sys
try:
    items = json.load(sys.stdin)["items"]
    assert isinstance(items, list)
except Exception:
    sys.exit(3)
print(",".join(str(i.get("shown") or i.get("gid")) for i in items if isinstance(i, dict) and "mover" in (i.get("roles") or []) and not i.get("held")))' <<< "$out" 2>/dev/null); rc=$?
        [ "$rc" = 0 ] || { RETIRE_ITEMS_WHY="stackshot's answer about '$key' is not the open-items list: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"; return 2; }
        [ -z "$parsed" ] || ids="${ids:+$ids,}$parsed"
    done
    [ -n "$ids" ] || return 0
    RETIRE_ITEMS=$(tr ',' '\n' <<< "$ids" | awk '!s[$0]++' | paste -sd, - | sed 's/,/, /g'); return 1
}
# A SIDE SESSION RENAMED TO AN AGENT NAME (Wed Oct 28th 2026; lib/rename.sh): a side session (THE SIDE SESSIONS, below) is on no
# page's agents map, so a rename to a real agent name its project does not list reached the refusal above, and a session must not go down a route
# that ends in a rename refusal. With a side record for OLD, the rename lists NEW as a new agent itself: `client.py post project-agent <hub> NEW --role R
# --front --mandate "<line>" --sender sala-web` (the New session form's label, honored from this box: form_senders/form_machines), which records a PENDING
# agent in stackshot's project record (page_owed; the page's own line stays the page keeper's to add: stackshot cannot write a page's frontmatter), then
# the rename goes on and the side record ends (rename_side_end): the session is an ordinary agent from then on. The project is the record's `project`,
# else the one its origin agent has; neither = a refusal, said in the plan. The call is idempotent (the same role and line again answers "already
# recorded … as it stands"), which a busy pane's retry worker relies on. SALA_RENAME_LIST_SENDER overrides the label.
: "${SALA_RENAME_LIST_SENDER:=sala-web}"
side_origin_project() {  # <agent> → the page key the agent's registry row carries (stdout; empty when none)
    sessions_py resolve "$1" --live --json 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("project") or "")
except Exception: pass' 2>/dev/null
}
# rename_side_plan <OLD> <NEW> → rc 0: RL_HUB (the project's hub page), RL_ROLE (NEW's part after the project's name: the server wants that suffix, letters, digits, . _ -, at most 32),
# RL_LINE (the mandate line, one line cut at 200 characters: the first line of the owner's own instructions for the session when its mandate file has them,
# else where the session came from) · rc 1: RL_WHY says why sala cannot list it
rename_side_plan() {
    local old=$1 new=$2 origin item mf main pre
    RL_HUB=$(side_val "$old" project); RL_ROLE="" RL_LINE="" RL_WHY=""
    origin=$(side_val "$old" origin); item=$(side_val "$old" item); mf=$(side_val "$old" mandate)
    [ -n "$RL_HUB" ] || { [ -z "$origin" ] || RL_HUB=$(side_origin_project "$origin"); }
    if [ -z "$RL_HUB" ]; then
        RL_WHY="'$old' is a side session with no project on its record${origin:+ (nor has its origin '$origin' one)}, so sala cannot tell which project would list '$new': ask that project's -main agent to list '$new' first, or tag the project (sala sessions tag)"; return 1
    fi
    page_key_ok "$RL_HUB" || { RL_WHY="'$old' is a side session whose project '$RL_HUB' is not a hub page key (<dir>/<slug>, the dir one of ${SALA_PAGE_DIRS// /, }), so sala cannot list '$new' there"; return 1; }
    main=$(project_record_agent "$RL_HUB" "side-probe-nobody" 2>/dev/null | sed -n 2p); pre=${main%-main}
    if [ -n "$main" ] && [[ $new == "$pre"-?* ]]; then RL_ROLE=${new#"$pre"-}; else RL_ROLE=${new##*-}; fi
    [[ $RL_ROLE =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]] || { RL_WHY="no role for '$new' on $RL_HUB (its part after the project's name is not letters, digits, . _ - of at most 32 characters)"; return 1; }
    if [ -n "$mf" ] && [ -r "$mf" ]; then RL_LINE=$(awk '/^## (.*[ ])?[Ii]nstructions for this conversation/ {f=1; next} f && NF {print; exit}' "$mf" 2>/dev/null); fi
    [ -n "$RL_LINE" ] || RL_LINE="was the side session $old${origin:+, a fork of $origin}${item:+, about $item}"
    RL_LINE=$(printf '%s' "$RL_LINE" | tr -d '\000-\010\013-\037\177' | tr -s ' \t' ' ' | sed 's/^ //; s/ $//'); RL_LINE=${RL_LINE:0:200}
    return 0
}
rename_side_run() {  # <NEW> → lists what rename_side_plan planned: rc 0 (RL_OUT: stackshot's note) · rc 1 (RL_WHY: why not; nothing renamed)
    local c rc; RL_OUT=""
    c=$(stackshot_client) || { RL_WHY="no stackshot client.py on this box (SALA_STACKSHOT_CLIENT, SALA_STACKSHOT_DIR/stackshot/fleet/client.py)"; return 1; }
    RL_OUT=$(timeout 45 python3 "$c" post project-agent "$RL_HUB" "$1" --role "$RL_ROLE" --front --mandate "$RL_LINE" --sender "$SALA_RENAME_LIST_SENDER" 2>&1 </dev/null); rc=$?
    [ "$rc" = 0 ] && return 0
    [ "$rc" != 124 ] || RL_OUT="stackshot did not answer within 45 s (the call is safe to repeat)"
    RL_WHY="stackshot's project-agent call failed (exit $rc): $(_lastline "$RL_OUT")"; return 1
}
# rename_side_end <OLD> <NEW> [<hub>] → OLD's side record ends, as a retire leaves a finished one: the record (and a write-up marker, if any) moves to
# side/retired/ (history, with renamed_to/renamed_at added), the registry row's side fields are cleared and, when <hub> is given, the row is tagged
# project=<hub> role=front like a project spawn's. Nothing is owed any more: no `side done`, no summary. rc 1: the record could not be moved.
rename_side_end() {
    local old=$1 new=$2 hub=${3:-} rc=0
    if side_is "$old"; then
        printf 'renamed_to=%s\nrenamed_at=%s\n' "$new" "$(date +%s)" >> "$(side_file "$old")" 2>/dev/null || :
        mkdir -p "$SALA_SIDE_DIR/retired" && mv -f "$(side_file "$old")" "$SALA_SIDE_DIR/retired/" || rc=1
        [ ! -f "$(side_done_file "$old")" ] || mv -f "$(side_done_file "$old")" "$SALA_SIDE_DIR/retired/" || rc=1
    fi
    sessions_set "$new" side= side_origin= side_item= side_at= ${hub:+"project=$hub" role=front}
    return $rc
}
# THE SIDE SESSIONS (quick side conversations; docs/side-sessions.md; lib/spawn.sh --side, lib/side.sh, lib/retire.sh).
# A side session is a short-lived session of the owner's, started in one step: forked from a running agent (`spawn --side --fork-of
# AGENT`, named <agent>-side-<word><nn>) or a fresh one about a board item (`spawn --side --project KEY --item board#N`, named
# <project prefix>-side-<word><nn>). It is on no page's agents map (agent_unlisted lets any *-side-* name pass), has no quiet watch,
# no auto-retire and no cap, and retires only on the owner's word, through `sala op retire`. Its record is one file under
# $SALA_STATE_DIR/side/: <name>.side (key=value, written by spawn once the session is up) and, once `sala side done` found the
# write-up in place, <name>.done (the marker retire asks for). The registry row carries side/side_origin/side_item/side_at too, for
# `sala sessions` (a copy for display; the file is the gate, so SALA_SESSIONS=off changes nothing here).
SALA_SIDE_DIR="$SALA_STATE_DIR/side"
side_file() { echo "$SALA_SIDE_DIR/$1.side"; }
side_done_file() { echo "$SALA_SIDE_DIR/$1.done"; }
side_val() {  # <session> <key> → the first value in its .side record (empty: no record or no key)
    awk -F= -v k="$2" '$1==k {print substr($0, length(k)+2); exit}' "$(side_file "$1")" 2>/dev/null
}
item_id_ok() {  # <id> → 0 for a board item id in the forms stackshot shows: board#N, a temporary board-tmp-box#N, an older sN / aN (the web's Discuss link carries any of them)
    [[ "$1" =~ ^board#[0-9]+$ || "$1" =~ ^board-tmp-[a-z0-9]+(-[a-z0-9]+)*#[0-9]+$ || "$1" =~ ^[a-z][0-9]+$ ]]
}
side_is() { [ -f "$(side_file "$1")" ]; }   # <session> → 0 when it is a side session (spawn --side made its record)
# THE PROJECT SPAWN'S CHECKS (Thu Oct 15th 2026; lib/spawn.sh, `spawn NAME --project <page key> --role front|back`).
# A project agent is registered by its line on its hub page's `agents:` map (a front agent a top-level entry, a background
# one under `background:`), and sala can read that map only through stackshot's pages.py:
# `resolve <key>` (does the page exist) and `agent-listed <name>` (is the name on a page). Unlike agent_unlisted these do
# NOT fail open: a project spawn that cannot be checked is refused ("cannot tell"), since the web form and the queue run
# it unattended and a session made before its line exists reads no mandate at its first prompt. Both skip nothing for a
# sala-test-* name (the suites give them a stub script, SALA_AGENT_CHECK_SCRIPT); SALA_AGENT_CHECK=off skips both.
: "${SALA_AGENT_NAME_MAX:=48}"       # an agent name's length cap (sala's rule: tmux's session name, the /rename typed, the heartbeat's rows and
                                     #   sala-web's sidebar carry it; stackshot asks only that it is a key of the page's agents map)
: "${SALA_PAGE_DIRS:=projects}"   # the page directories a --project key may start with (stackshot.toml [pages] dirs on this instance; config.example)
# SALA_STACKSHOT_DIR (contract version 11): where stackshot's checkout is, the one place sala's default stackshot commands
# come from (pages.py here; client.py in spawn.sh, side.sh, release.sh and the parked-question board scripts; sala-web's roles command).
# Unset: ~/stackshot, as every default was before. Set EMPTY: this box has no stackshot, and each of those defaults is empty at once
# (the fail-open paths take their "unset" branch; a project spawn says it cannot tell). An explicit knob (SALA_AGENT_CHECK_SCRIPT,
# SALA_SPAWN_ASK_CMD, SALA_SIDE_*_CMD, SALA_STACKSHOT_CLIENT, STACKSHOT_CLIENT, SALA_WEB_ROLES_CMD) still wins over the directory.
# Where a program is inside that directory is lib/stackshot-path.sh's one answer (stackshot's package path, else the old root path of a
# checkout from before the package); every default below and in spawn.sh, side.sh and release.sh asks it.
. "${BASH_SOURCE[0]%/*}/stackshot-path.sh"
: "${SALA_STACKSHOT_DIR=$HOME/stackshot}"
agent_check_script() {  # → the path of stackshot's pages.py (SALA_AGENT_CHECK_SCRIPT, else stackshot/projects/pages.py under SALA_STACKSHOT_DIR, or pages.py there on an older checkout), or 1 with nothing
    local py="${SALA_AGENT_CHECK_SCRIPT:-}"
    [ -n "$py" ] || stackshot_prog_r py "${SALA_STACKSHOT_DIR:-}" pages
    [ -n "$py" ] && [ -f "$py" ] || return 1
    echo "$py"
}
agent_name_ok() {  # <name> → 0 when it is an agent name by sala's rule: lowercase letters, digits and dashes, no dash at either end, at most SALA_AGENT_NAME_MAX
    local n="${1:-}"
    [ -n "$n" ] && [ "${#n}" -le "$SALA_AGENT_NAME_MAX" ] || return 1
    case "$n" in *[!a-z0-9-]*|-*|*-) return 1;; esac
    return 0
}
page_key_ok() {  # <key> → 0 when it has a hub page key's shape: <dir>/<slug>[/<sub>…], a SALA_PAGE_DIRS dir, lowercase letters, digits and dashes
    local k="${1:-}" d
    case "$k" in */*) ;; *) return 1;; esac
    case " $SALA_PAGE_DIRS " in *" ${k%%/*} "*) ;; *) return 1;; esac
    case "${k#*/}" in ''|*[!a-z0-9/-]*|-*|*-|*/|*//*|/*) return 1;; esac
    for d in ${k//\// }; do case "$d" in -*|*-) return 1;; esac; done
    return 0
}
page_exists() {  # <key> → 0 the page exists · 1 no such page · 2 cannot tell (no pages.py or brain here, a python error, a timeout), the why on stdout
    local py out rc; py=$(agent_check_script) || { echo "no pages.py on this box (SALA_AGENT_CHECK_SCRIPT, SALA_STACKSHOT_DIR/stackshot/projects/pages.py)"; return 2; }
    out=$(timeout 15 python3 "$py" resolve "$1" 2>&1); rc=$?   # prints "<key> True|False|None", exit 0 only for True
    case "$rc:${out##* }" in
        0:True) return 0 ;;
        1:False) echo "no page $1"; return 1 ;;
        *) echo "pages.py resolve $1 exited $rc: $(_lastline "$out")"; return 2 ;;
    esac
}
agent_listed_on() {  # <name> <page key> → 0 listed on that page (its mandate line on stdout) · 3 not listed there (what pages.py said) · 2 cannot tell (the why)
    # pages.py agent-listed maps the name to a page by itself and exits 0 for a listed name AND for one it has nothing to check
    # ("no project page for this name: nothing to check"; before Fri Oct 16th 2026 "no steward page …"), so only its `listed on <this key>: …`
    # line counts here; a name listed on another page, or one pages.py calls a project's own name, is not on this page either (the coordinator's note, Thu Oct 15th 2026)
    local py out rc line _l; py=$(agent_check_script) || { echo "no pages.py on this box (SALA_AGENT_CHECK_SCRIPT, SALA_STACKSHOT_DIR/stackshot/projects/pages.py)"; return 2; }
    out=$(timeout 15 python3 "$py" agent-listed "$1" 2>&1); rc=$?
    case "$rc" in
        0) line=""; while IFS= read -r _l; do [[ $_l == *"listed on $2: "* ]] && { line=$_l; break; }; done <<< "$out"   # grep -m1 -F
           if [ -n "$line" ]; then echo "${line#listed on $2: }"; return 0; fi
           _lastline "${out:-pages.py said nothing}"; return 3 ;;
        3) _lastline "${out:-not listed}"; return 3 ;;
        *) echo "pages.py agent-listed $1 exited $rc: $(_lastline "$out")"; return 2 ;;
    esac
}
# THE PROJECT RECORD (docs/stackshot-contracts.md, interface 20). stackshot publishes the project record at
# ~/.local/state/stackshot/projects.json (schema 1: {"schema": 1, "generated": "<ISO Z>", "projects": {<prj_xxxxxxxx>: {id, key,
# keeper, agents: {<name>: {front, role, mandate_line[, page_owed]}}}}, "by_key": {<page key>: <id>}}), rewritten every few minutes,
# so a spawn on the coordinator machine reads a file: no token, no HTTP. It is the FIRST source of the project spawn's agents-map check and of
# agent_unlisted (plain spawn, rename); pages.py (above) is the fallback when the record cannot answer (missing, unreadable,
# another schema, older than SALA_PROJECT_RECORD_MAX_AGE, no such project). An agent with `page_owed: true` was registered
# through `client.py post project-agent` and its page line is still owed: for a spawn that registration is the point, so it
# counts as listed (the note says the line is owed).
: "${SALA_PROJECT_RECORD:=$HOME/.local/state/stackshot/projects.json}"
: "${SALA_PROJECT_RECORD_MAX_AGE:=600}"    # seconds: the contract says a reader treats an older file as stale (stackshot rewrites it every 5 minutes)
project_record_agent() {  # <page key, or empty for any project> <name> [front|back to check] → rc 0 listed (stdout line 1: the mandate line, line 2: the project's -main agent or empty) · 3 the project is in the record and the name is not on its agents map, or (no page key given) the name is on no project of a fresh record (line 1 the why, line 2 the -main agent, empty for no key) · 5 listed with the other role (the why) · 1 the record cannot answer (the why)
    [ -r "$SALA_PROJECT_RECORD" ] || { echo "no project record at $SALA_PROJECT_RECORD"; return 1; }
    local out rc
    out=$(python3 -I - "$SALA_PROJECT_RECORD" "$SALA_PROJECT_RECORD_MAX_AGE" "$1" "$2" "${3:-}" 2>&1 <<'PY'
import datetime, json, sys
path, max_age, key, name, role = sys.argv[1:6]
def no(why): print(why); sys.exit(1)
try:
    d = json.load(open(path, encoding="utf-8"))
    if not isinstance(d, dict) or d.get("schema") != 1: no("the project record is not schema 1")
    age = datetime.datetime.now(datetime.timezone.utc).timestamp() - datetime.datetime.fromisoformat(str(d["generated"]).replace("Z", "+00:00")).timestamp()
    if age > float(max_age) or age < -60: no("the project record is stale (written %d s ago)" % age)
    projects = d["projects"]
    if not isinstance(projects, dict): no("the project record has no projects")
    def agents_of(p): return p["agents"] if isinstance(p, dict) and isinstance(p.get("agents"), dict) else {}
    def main_of(p):  # the front entry ending in -main
        return next(iter(sorted(n for n, a in agents_of(p).items() if isinstance(a, dict) and a.get("front") is True and n.endswith("-main"))), "")
    if not key:  # any project: is the name listed anywhere
        for k in sorted(projects):
            if isinstance(agents_of(projects[k]).get(name), dict): print("listed on %s" % projects[k].get("key", k)); print(""); sys.exit(0)
        print("the name is on no project of the record"); print(""); sys.exit(3)   # a fresh record that lists it nowhere is an answer: rc 3, not "cannot answer" (op_own_unlisted needs the difference)
    pid = (d.get("by_key") or {}).get(key)
    p = projects.get(pid) if pid else None
    if p is None: p = next((v for v in projects.values() if isinstance(v, dict) and v.get("key") == key), None)
    if p is None: no("the project record has no project %s" % key)
    a = agents_of(p).get(name)
    if not isinstance(a, dict):
        print("not on the agents map of %s in stackshot's project record (%s)" % (key, p.get("id", pid))); print(main_of(p)); sys.exit(3)
    front = a.get("front")
    if not isinstance(front, bool): no("the project record gives no front/back for %s" % name)
    if role and (role == "front") != front:
        print("the project record lists '%s' on %s as a %s agent (front: %s), not a %s agent" % (name, key, "front" if front else "back", str(front).lower(), role)); sys.exit(5)
    print(str(a.get("mandate_line") or "") + (" (the page's line is still owed: registered through client.py post project-agent)" if a.get("page_owed") else "")); print(main_of(p)); sys.exit(0)
except SystemExit: raise
except Exception as e: no("the project record is unreadable (%s)" % e)
PY
); rc=$?
    case "$rc" in 0|3|5) printf '%s\n' "$out"; return "$rc" ;; esac
    _lastline "$out"; return 1
}
# sala_notify <message> — out-of-band word to the human (Slack, etc). Every unattended failure uses
# it: a driver that only writes its log is a failure nobody sees.
# Every post leaves through sala_send_post: each bare board#N becomes a link to its item (lib/boardlinks.sh, the one
# implementation the briefings' post_slack runs too; SALA_STACKSHOT_WEB unset: the text goes as it is).
_bl=${BASH_SOURCE[0]}; [[ $_bl == */* ]] || _bl=./$_bl; . "${_bl%/*}/boardlinks.sh"; unset _bl   # beside this file, no process
sala_send_post() {   # <cmd>  — stdin, board ids linked, into the notify command; its exit code
    sala_board_links "${SALA_STACKSHOT_WEB:-}" | sh -c "$1"
}
sala_notify_raw() {   # the message exactly as given (a formatted post that must start with its own header)
    local cmd="${SALA_NOTIFY_CMD:-${SALA_WATCH_NOTIFY_CMD:-}}"
    [ -n "$cmd" ] || return 0
    printf '%s\n' "$*" | sala_send_post "$cmd" >/dev/null 2>&1 || true
}
# sala_post <headline> [bullet…] — every Slack notice in one shape: line 1
# an emoji and a bold headline that says what happened, then one "    • " bullet per host or item — problems and
# anything that needs the owner first (the caller orders them), plain words, no raw ids or keys, no "; "-joined lists — and
# a path only on a last "Details: …" bullet. No "salamander (host):" prefix.
# A bullet that starts with "◦ " is a sub-bullet of the bullet before it (a box's leftover items), indented under it.
sala_post() { sala_notify_raw "$(sala_post_text "$@")"; }
sala_post_text() {   # <headline> [bullet…] → the post's text (sala_post sends it; `sala alert` sends it and keeps the exit code)
    local out="$1" b; shift
    for b in "$@"; do
        [ -n "$b" ] || continue
        case "$b" in Details:*) out="$out"$'\n'"$b";; "◦ "*) out="$out"$'\n'"        $b";; *) out="$out"$'\n'"    • $b";; esac
    done
    printf '%s\n' "$out"
}
sala_notify() { sala_post "$*"; }   # a caller not yet in the shape: at least no prefix

# ── registry ──────────────────────────────────────────────────────────────────
# registry_field <pid> <field> → value or empty
# A row the CLI writes is one flat JSON object. Read by python3 each time it was a 20 ms process start per call, thousands per
# test run, so the shell reads it itself when it can answer exactly as json.load would: a row with exactly one
# object (one `{`), the field named once, its value a string with no escape, an integer, true, false or null. Anything else
# (a nested object, a repeated name, an escape, a float) goes to python3 as before.
registry_field_r() {  # <var> <pid> <key> → the field in <var> (no subshell on the fast path); 1 for a registry row that cannot be read
    local f="$SALA_REG_DIR/$2.json" c="" k="${3:-}" b e t v re
    printf -v "$1" '%s' ""
    [ -r "$f" ] || return 1
    { IFS= read -r -d '' c < "$f"; } 2>/dev/null || :
    b=${c//[^\{]/}; e=${c//[^\}]/}
    # the whole content must be one complete object: a truncated row, trailing text or a top-level array is not one, and python3 answers those (empty)
    if [ "${#b}" = 1 ] && [ "${#e}" = 1 ] && [[ $c =~ ^[[:space:]]*\{.*\}[[:space:]]*$ ]] && [[ $k =~ ^[A-Za-z0-9_]+$ ]]; then
        t=${c//\"$k\"/}
        case $(( (${#c} - ${#t}) / (${#k} + 2) )) in
            0) return 0 ;;
            1) re='"'"$k"'"[[:space:]]*:[[:space:]]*("[^"\\]*"|-?(0|[1-9][0-9]*)|true|false|null)[[:space:]]*[,}]'
               if [[ $c =~ $re ]]; then
                   v=${BASH_REMATCH[1]}
                   case $v in \"*) printf -v "$1" '%s' "${v:1:${#v}-2}" ;; -0) printf -v "$1" '%s' 0 ;; *) printf -v "$1" '%s' "$v" ;; esac
                   return 0
               fi ;;
        esac
    fi
    v=$(python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2],"")
    print(v if isinstance(v,str) else json.dumps(v))
except Exception: pass' "$f" "$3" 2>/dev/null)
    printf -v "$1" '%s' "$v"
    return 0
}
registry_field() { local _rf; registry_field_r _rf "$@" || return 1; printf '%s\n' "$_rf"; }
# live_pane_for_uuid <uuid> → "pid tmux" of a LIVE process hosting it, or empty
live_pane_for_uuid() {
    local f pid sid
    for f in "$SALA_REG_DIR"/*.json; do
        [ -r "$f" ] || continue
        pid=${f##*/}; pid=${pid%.json}; case "$pid" in ''|*[!0-9]*) continue;; esac
        kill -0 "$pid" 2>/dev/null || continue
        sid=$(registry_field "$pid" sessionId)
        [ "$sid" = "$1" ] && { echo "$pid $(registry_field "$pid" tmux)"; return 0; }
    done
    return 1
}
# ── a pane parked on a background job (Wed Oct 28th 2026) ─────────────────────────────────────────────────────
# The CLI's "← for agents" view moves a session's conversation into a background job. Two registry rows then carry one name
# (CLI 2.1.312, a builder):
#   the PANE'S row   kind interactive, tmux "<session>:@w.%p", status always "shell" (the viewer), sessionId = the conversation as
#                    it stood BEFORE the move, parkedJobId = the job's short id (8 characters; older CLIs: the fork's whole uuid)
#   the JOB'S row    kind bg, no tmux, jobId = that id, sessionId = the job's conversation (the live one), status idle/busy/waiting
# The pane map still holds the old uuid and the viewer never reads idle, so a recycle skipped the pane for ever and a revive would
# have resumed the conversation as it stood before the move. These readers resolve the pane to its job; every user of a pane's
# conversation or idleness goes through them. The web app folds the two rows the same way (web/src/sala_web/sessions.py job_row).
# parked_job_r <var> <claude-pid> → the pane's parkedJobId in <var>; 1 (and empty) when the pane is not parked
parked_job_r() {
    local _pjv; registry_field_r _pjv "$2" parkedJobId
    if [ -n "$_pjv" ] && [ "$_pjv" != null ]; then printf -v "$1" "%s" "$_pjv"; return 0; fi
    printf -v "$1" '%s' ""; return 1
}
# parked_job_pid_r <var> <claude-pid> → the pid of the live process holding the job the pane is parked on: the registry row whose
# jobId is the pane's parkedJobId, else the row whose sessionId is it or starts with it (a short id; the older CLIs' whole uuid).
# 1 (and empty) when the pane is not parked or the job's process is gone. Never the pane's own row.
parked_job_pid_r() {
    local _job _f _p _v _alt=""
    printf -v "$1" '%s' ""
    parked_job_r _job "$2" || return 1
    for _f in "$SALA_REG_DIR"/*.json; do
        [ -r "$_f" ] || continue
        _p=${_f##*/}; _p=${_p%.json}; case "$_p" in ''|*[!0-9]*) continue;; esac
        [ "$_p" = "$2" ] && continue; kill -0 "$_p" 2>/dev/null || continue
        registry_field_r _v "$_p" jobId; [ "$_v" = "$_job" ] && { printf -v "$1" '%s' "$_p"; return 0; }
        if [ -z "$_alt" ]; then
            registry_field_r _v "$_p" sessionId
            if [ -n "$_v" ] && { [ "$_v" = "$_job" ] || { [ "${#_job}" -ge 8 ] && [ "${_v:0:${#_job}}" = "$_job" ]; }; }; then _alt=$_p; fi
        fi
    done
    [ -n "$_alt" ] || return 1
    printf -v "$1" '%s' "$_alt"
}
# registry_conv_r <var> <claude-pid> → the conversation the pane is in: its row's sessionId, or, for a parked pane, the job's
# (the live row's sessionId; with the job's process gone, the one transcript on disk that carries the job's id). Empty for a row
# that cannot be read. This is what a relaunch resumes, the pane map follows and a ready marker or a waiting flag is keyed by.
registry_conv_r() {
    local _own _jp _pj _t _h _n _u
    registry_field_r _own "$2" sessionId
    if parked_job_pid_r _jp "$2"; then registry_field_r _u "$_jp" sessionId; [ -n "$_u" ] && [ "$_u" != null ] && _own=$_u
    elif parked_job_r _pj "$2"; then
        _u=""; _n=0   # the job's process is gone: its transcript is still the conversation (a short id matches one file, or none)
        for _t in "$SALA_PROJECTS"/*/"$_pj"*.jsonl; do [ -e "$_t" ] || continue; _h=${_t##*/}; _h=${_h%.jsonl}; [ "$_h" = "$_u" ] || { _u=$_h; _n=$((_n+1)); }; done
        [ "$_n" = 1 ] && _own=$_u
    fi
    printf -v "$1" '%s' "$_own"
}
# the job's wait for its own end, and the pause after the Esc that leaves the viewer's list view (parked_close)
: "${SALA_PARKED_EXIT_WAIT:=20}" "${SALA_PARKED_ESC_WAIT:=3}"
# parked_close <pane> <viewer-claude-pid> <job-pid> → 0 the job ended and the pane is back at its shell; 4 the job is not idle now
# (it started a turn after the idle check); 1 a step failed, the reason on stdout. THE CHOICE: relaunching a parked pane
# RESUMES THE JOB'S CONVERSATION IN THE PANE, as an ordinary session, the job ended first, never a second viewer (no CLI verb
# re-attaches a viewer to a job by id; and a transcript has one writer, so the job must be gone before anyone resumes it). It is
# the steps `sala unpark` takes, verified once on 2.1.282: SIGTERM the job's process and its bg-pty-host (a bg session ignores
# /exit; its transcript is flushed per turn, and the job is idle), Esc (the viewer notices the ended job and stays in its list
# view), then Ctrl-C twice (the list view's own quit) until the pane is a shell. Reversible: the conversation is whole in its
# transcript, and "← for agents" parks it again.
parked_close() {
    local pane="$1" jpid="$3" hpid i
    is_idle "$jpid" || return 4
    hpid=$(proc_ppid "$jpid")
    kill -TERM "$jpid" 2>/dev/null
    for ((i=0; i<SALA_PARKED_EXIT_WAIT*2; i++)); do proc_alive "$jpid" || break; _nap 0.5; done
    proc_alive "$jpid" && { echo "the background job (pid $jpid) did not end within ${SALA_PARKED_EXIT_WAIT}s — not forced"; return 1; }
    if [ -n "$hpid" ] && proc_args "$hpid" | grep -q -- '--bg-pty-host'; then kill -TERM "$hpid" 2>/dev/null; _nap 1; fi
    unmode "$pane"; tmux send-keys -t "$pane" Escape; _nap "$SALA_PARKED_ESC_WAIT"
    for ((i=0; i<3; i++)); do
        tmux send-keys -t "$pane" C-c; _nap 0.7; tmux send-keys -t "$pane" C-c
        wait_for "$pane" shell 10 && break
    done
    wait_for "$pane" shell 5 || { echo "the pane did not return to a shell after the job ended — screen: $(tmux capture-pane -p -t "$pane" 2>/dev/null | grep -v '^ *$' | tail -2 | tr '\n' ' ')"; return 1; }
    return 0
}
# _nul_read <file> → the NUL-separated fields of the file in the array _NUL (/proc/<pid>/cmdline and environ), read by the shell.
# mapfile -d is bash 4.4; older shells read the fields in a loop. Expand it as ${_NUL[@]+"${_NUL[@]}"} (empty, set -u).
if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
    _nul_read() { _NUL=(); { mapfile -d '' -t _NUL < "$1"; } 2>/dev/null || :; }
else
    _nul_read() { _NUL=(); local _x; { while IFS= read -r -d '' _x || [ -n "$_x" ]; do _NUL+=("$_x"); done < "$1"; } 2>/dev/null || :; }
fi
# is_rc_child <pid> — a Remote Control server child (`--print --sdk-url …`), not a pane
_args_has() {  # <pid> <text> → 0 when the process's command line holds the text (Linux: /proc/<pid>/cmdline read by the shell; elsewhere ps)
    if [ -r /proc/self/stat ]; then _nul_read "/proc/$1/cmdline"; [[ "${_NUL[*]-}" == *"$2"* ]]; return; fi
    proc_args "$1" | grep -q -- "$2"
}
is_rc_child() { _args_has "$1" '--sdk-url'; }
is_rc_server() { _args_has "$1" ' remote-control'; }

# rc_served → one TSV line per session the Remote Control server serves (registry rows on its tmux session, pid alive):
# sessionId \t status \t web id \t version \t first user message (60 chars). Served sessions are the server's
# `--print --sdk-url` children, not panes; the server re-dispatches them itself when it relaunches (same web id,
# its new binary) — revive verifies and reports them.
rc_served() {
    REG="$SALA_REG_DIR" PROJ="$SALA_PROJECTS" python3 - "$SALA_RC_SESSION" <<'PYRC'
import json, sys, os, glob
for f in glob.glob(os.path.join(os.environ["REG"], "*.json")):
    try: d = json.load(open(f))
    except Exception: continue
    pid = os.path.basename(f)[:-5]
    try: os.kill(int(pid), 0)
    except PermissionError: pass
    except Exception: continue
    if not str(d.get("tmux", "")).startswith(sys.argv[1] + ":"): continue
    sid = d.get("sessionId", ""); first = ""
    if not sid: continue
    try:
        hits = glob.glob(os.path.join(os.environ["PROJ"], "*", sid + ".jsonl"))
        for line in open(max(hits, key=os.path.getmtime)):
            r = json.loads(line)
            if r.get("type") == "user" and not r.get("isMeta"):
                c = r["message"]["content"]; first = c if isinstance(c, str) else next((x.get("text", "") for x in c if x.get("type") == "text"), "")
                break
    except Exception: pass
    first = " ".join(first.split())[:60]
    print("\t".join([sid, str(d.get("status") or "?"), str(d.get("bridgeSessionId") or ""), str(d.get("version") or "?"), first]))
PYRC
}
# rc_served_snapshot — remember the served set, so a boot can tell which ones came back
SALA_RC_SERVED="$SALA_LOG_DIR/salamander-rc-served.tsv"
rc_served_snapshot() { local out; out=$(rc_served 2>/dev/null) || return 0; [ -n "$out" ] || { tmux has-session -t "=$SALA_RC_SESSION" 2>/dev/null && : > "$SALA_RC_SERVED"; return 0; }; printf '%s\n' "$out" > "$SALA_RC_SERVED"; }

# ── transcripts ───────────────────────────────────────────────────────────────
# slug_for_cwd <dir> → Claude Code's project-dir slug
slug_for_cwd() { local _s=$1; printf '%s\n' "${_s//[\/.]/-}"; }
# transcript_for_uuid <uuid> → path of the transcript (newest if several slugs hold one)
transcript_for_uuid() { local f best=""; for f in "$SALA_PROJECTS"/*/"$1.jsonl"; do [ -e "$f" ] || continue; { [ -z "$best" ] || [ "$f" -nt "$best" ]; } && best=$f; done; [ -z "$best" ] || printf '%s\n' "$best"; }   # the newest by mtime, as ls -t | head -1 (two processes fewer)
# session_scratch_dirs <pid> <uuid> → dirs whose recent writes mean "background work in flight"
session_scratch_dirs() {
    local cwd slug; cwd=$(proc_cwd "$1") || return 0; [ -n "$cwd" ] || return 0
    slug=$(slug_for_cwd "$cwd")
    echo "/tmp/claude-$EUID/$slug/$2/tasks"
    echo "$SALA_PROJECTS/$slug/$2/subagents"
}

# effort_for_uuid <uuid> → the effort to pass on --resume, or empty.
# `claude --resume` restores the MODEL but NOT the effort (falls back to settings.json
# effortLevel; verified on a real CLI). A revived session must come back on what it was on, so
# read it off the transcript's per-turn `effort` field and pass --effort explicitly. Reads the
# tail only (files reach tens of MB); a format change degrades to "no --effort", never fails.
# A skill with its own model/effort pin runs ONE turn on that pair; if it is the last turn
# before a relaunch its effort must not become the session default — so take the
# last turn whose model is the session's prevailing model and which no skill attributed.
#
# model_family_for_uuid <uuid> → the conversation's model FAMILY to pass as --model on --resume (opus, sonnet, haiku,
# fable), or empty. Why (Tue Oct 13th 2026): `claude --resume` keeps a model the conversation pinned with /model as a full
# id (claude-opus-5), so a relaunch never moves a pane off an old version: several panes stayed on claude-opus-5 after the lane
# moves that day. The family rule: take message.model of the newest assistant record that
# is not "<synthetic>" (the CLI's own notices), not an API error (isApiErrorMessage) and not a skill's own pinned turn
# (attributionSkill, as for the effort above), and map it by prefix: claude-opus-* / opus* → opus, claude-sonnet-* →
# sonnet, claude-haiku-* → haiku, claude-fable-* → fable. The alias resolves to the family's latest version, so an old
# version pin moves up while a family picked on purpose stays (a sonnet pane stays sonnet). Unknown or unreadable → empty,
# and the line carries no --model (the line as before).
#
# _resume_flags_for_uuid <uuid> → "<effort>\t<family>", both from ONE bounded read of the transcript's tail.
_resume_flags_for_uuid() {
    local t; t=$(transcript_for_uuid "$1")
    [ -n "$t" ] && [ -r "$t" ] || { printf '\t\n'; return 0; }
    tail -c 2000000 "$t" 2>/dev/null | python3 -c '
import io,json,sys,collections
# tail -c can slice mid-UTF-8; strict decoding would drop --effort for any non-ASCII transcript
turns=[]; model=None
for line in io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8", errors="replace"):
    line=line.strip()
    if not line or "\"assistant\"" not in line: continue
    try: r=json.loads(line)
    except Exception: continue
    if not isinstance(r,dict) or r.get("type")!="assistant": continue
    m=(r.get("message") or {}).get("model")
    skill=bool(r.get("attributionSkill"))
    if isinstance(r.get("effort"),str):
        turns.append((m, r["effort"], skill))
    if isinstance(m,str) and m and m!="<synthetic>" and not r.get("isApiErrorMessage") and not skill:
        model=m
eff=""
if turns:
    main=collections.Counter(m for m,_,_ in turns[-60:] if m).most_common(1)
    main=main[0][0] if main else None
    for m,e,skill in reversed(turns):
        if (main is None or m==main) and not skill: eff=e; break
    if not eff: eff=turns[-1][1]
fam=""
if model:
    for pre,f in (("claude-opus-","opus"),("opus","opus"),("claude-sonnet-","sonnet"),("claude-haiku-","haiku"),("claude-fable-","fable")):
        if model.startswith(pre): fam=f; break
print(eff+"\t"+fam)' 2>/dev/null || printf '\t\n'
}
effort_for_uuid() { _resume_flags_for_uuid "$1" | cut -f1; }
model_family_for_uuid() { _resume_flags_for_uuid "$1" | cut -f2; }

# drafts_queued → 0 when at least one Claude-drafted feedback draft is queued on this machine (the queue
# is machine-wide, not per session). Lets `feedback drain` skip opening /feedback in the panes that have
# nothing to send — every open leaves a "/feedback" turn in that session's transcript.
drafts_queued() {  # [uuid] → 0 when a queued draft exists (for that conversation only, when given: drafts carry source_session_id)
    local f
    for f in "$SALA_DRAFTS_DIR"/*.json; do
        [ -r "$f" ] || continue
        grep -q '"status" *: *"queued"' "$f" 2>/dev/null || continue
        [ -z "${1:-}" ] && return 0
        grep -q "\"source_session_id\" *: *\"$1\"" "$f" 2>/dev/null && return 0
    done
    return 1
}
# bridge_for_uuid <uuid> → the claude.ai session id this conversation is bridged to: the registry field
# when set, else the last `remote_session_change` record in the transcript (the registry field is not
# rewritten when a relaunched pane RE-attaches its bridge, so it reads null exactly after a recycle).
bridge_for_uuid() {
    local t; t=$(transcript_for_uuid "$1"); [ -n "$t" ] || return 1
    # whole file, not a tail: the record is written when the bridge is (re)established, which can be megabytes
    # back in a long transcript (one session's last record once sat 5 MB+ before the end → guard blind)
    grep -o '"type":"remote_session_change","url":"https://claude.ai/code/[A-Za-z0-9_]*' "$t" 2>/dev/null | tail -1 | sed 's#.*/##'
}
# live_pane_for_bridge <session_…|cse_…> → "name tmux" of a LIVE pane bridged to that claude.ai session
live_pane_for_bridge() {
    local key="${1#*_}" f pid b sid
    for f in "$SALA_REG_DIR"/*.json; do
        [ -r "$f" ] || continue; pid=${f##*/}; pid=${pid%.json}; case "$pid" in ''|*[!0-9]*) continue;; esac
        kill -0 "$pid" 2>/dev/null || continue
        [ -n "$(registry_field "$pid" tmux)" ] || continue
        is_rc_child "$pid" && continue
        b=$(registry_field "$pid" bridgeSessionId); [ -n "$b" ] && [ "$b" != null ] || { sid=$(registry_field "$pid" sessionId); b=$(bridge_for_uuid "$sid"); }
        [ -n "$b" ] && [ "${b#*_}" = "$key" ] && { echo "$(registry_field "$pid" name) $(registry_field "$pid" tmux)"; return 0; }
    done
    return 1
}
# ── processes ─────────────────────────────────────────────────────────────────
# Portable process inspection (Linux + macOS). ps/lsof only; /proc is never read outside here.
proc_alive() { kill -0 "$1" 2>/dev/null; }
proc_ppid()  {
    [ -n "${1:-}" ] || return 0   # no pid: nothing (an empty one made /proc//stat = /proc/stat, the machine's cpu line, answer for it)
    if [ -r /proc/self/stat ]; then   # read from /proc by the shell; ps and tr where there is no /proc
        local line s p; { read -r line < "/proc/$1/stat"; } 2>/dev/null || return 0
        line=${line##*) }; read -r s p _ <<< "$line"; printf '%s\n' "$p"; return 0
    fi
    ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '
}
proc_args()  { ps -o args= -ww -p "$1" 2>/dev/null; }            # full command line, one line
proc_etime() {  # seconds since the process started ([[dd-]hh:]mm:ss → s)
    if [ -r /proc/self/stat ] && [ -r /proc/uptime ]; then   # the uptime less the start tick (stat field 22, 100 ticks a second), read by the shell
        local line up _u st; { read -r line < "/proc/$1/stat"; } 2>/dev/null || { echo 0; return; }
        read -r up _u < /proc/uptime; up=${up%%.*}
        line=${line##*) }; read -r -a st <<< "$line"
        [[ ${st[19]:-} =~ ^[0-9]+$ ]] && [[ $up =~ ^[0-9]+$ ]] || { echo 0; return; }
        echo $(( up > st[19] / 100 ? up - st[19] / 100 : 0 )); return
    fi
    local e; e=$(ps -o etime= -p "$1" 2>/dev/null | tr -d ' '); [ -n "$e" ] || { echo 0; return; }
    local d=0 h=0 m=0 sec=0
    case "$e" in *-*) d=${e%%-*}; e=${e#*-};; esac
    case "$e" in *:*:*) h=${e%%:*}; e=${e#*:};; esac
    m=${e%%:*}; sec=${e#*:}
    echo $(( (10#$d*24 + 10#$h)*3600 + 10#$m*60 + 10#$sec ))
}
proc_cwd() {  # working directory of a process (Linux: /proc; macOS: lsof)
    [ -n "${1:-}" ] || return 1   # no pid: lsof -p "" lists every process and the first line would answer (a pid whose readlink is denied lists "(readlink: Permission denied)")
    if [ -e "/proc/$1/cwd" ]; then readlink "/proc/$1/cwd" 2>/dev/null; return; fi
    command -v lsof >/dev/null 2>&1 || return 1
    lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1
}
proc_exe() {  # path of the running executable (Linux: /proc; macOS: lsof txt = the binary itself)
    [ -n "${1:-}" ] || return 1   # no pid: as proc_cwd
    if [ -e "/proc/$1/exe" ]; then readlink "/proc/$1/exe" 2>/dev/null; return; fi
    command -v lsof >/dev/null 2>&1 || return 1
    lsof -a -p "$1" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1
}
proc_table() { ps -axo pid=,ppid= 2>/dev/null; }                   # "pid ppid" for every process
# proc_version <claude-pid> → the CLI version that process runs: the registry says so for a pane
# session; otherwise the basename of the executable (versions live at …/claude/versions/<ver>)
proc_version() { local v; v=$(registry_field "$1" version); [ -n "$v" ] && [ "$v" != null ] && { echo "$v"; return; }; basename "$(proc_exe "$1")" 2>/dev/null; }
# stale_panes <version> → the name of every pane session (spawn --list) whose claude runs another version, one a line:
# what a relaunch without --force would move. update.sh counts them after its CLI update; watch's idle-gated relaunch
# (auto_relaunch) asks the same question of the installed CLI. A SALA_NO_RELAUNCH session is never one (below).
stale_panes() {
    local s; "$SALA_BIN" spawn --list 2>/dev/null | awk -v v="$1" 'NR>1 && $2 ~ /^[0-9]/ && $2 != v {print $1}' \
        | while IFS= read -r s; do no_relaunch "$s" || printf '%s\n' "$s"; done
}
# NOT RELAUNCHED (until the lane verb records each pane's lane): a tmux session named in
# SALA_NO_RELAUNCH is managed outside sala (a session launched by hand with its own API key; sala's own
# launch line would bring it back on the default login without that key). Every path that relaunches or restores panes leaves
# it alone and says so: the revive sweep (recycle, the boot hook, `revive --all`), `revive --only`/`--self`, the recycle
# driver's own pane, the retry workers, watch's deferred relaunch and auto-relaunch (stale_panes), compare-and-restore,
# `sala restore` and the reboot's boot-half check. Such a pane is excluded, not pending: never in a set's count, its
# outstanding panes, a skipped list or the post-recycle hook's `skipped`. retire, rename, map and list keep working on it.
# THE SHELL SESSION: the web UI's shell drawer runs a plain login bash in the tmux session SALA_SHELL_SESSION
# (default sala-shell). It is not a Claude pane and no sala verb brings it back: the web app makes it on demand. is_shell_session
# names it once; no_relaunch treats it as managed outside sala (so revive, restore, the lane move, watch's deferred relaunch
# and the reboot leave it alone), the revive sweep drops it without a summary row, `spawn --list` and the lane lists leave it
# out, and `adopt` refuses it.
is_shell_session() { [ -n "$1" ] && [ "$1" = "${SALA_SHELL_SESSION:-}" ]; }   # <tmux session>
no_relaunch() { [ -n "$1" ] || return 1; is_shell_session "$1" && return 0; case " ${SALA_NO_RELAUNCH//[$'\t\n']/ } " in *" $1 "*) return 0;; esac; return 1; }   # <tmux session>
# no_relaunch_fix <tmux session> <advice for a session in SALA_NO_RELAUNCH>: the closing words of a refusal. The shell session is not
# in SALA_NO_RELAUNCH (it is sala's own), so "take it out of SALA_NO_RELAUNCH" would send the reader to a list it is not on.
no_relaunch_fix() { if is_shell_session "$1"; then echo "it is sala's own shell session (SALA_SHELL_SESSION), not a Claude session"; else echo "$2"; fi; }   # <tmux session> <advice>
no_relaunch_line() { if is_shell_session "$1"; then echo "$1: not relaunched — the web UI's shell, not a Claude session"; else echo "$1: not relaunched — SALA_NO_RELAUNCH (managed outside sala)"; fi; }   # <tmux session>
# is_under <pid> <root-pid> → 0 when root is an ancestor of (or is) pid
is_under() {
    local q="$1"
    while [ -n "$q" ] && [ "$q" != 1 ] && [ "$q" != 0 ]; do
        [ "$q" = "$2" ] && return 0
        q=$(proc_ppid "$q")
    done
    return 1
}
# claude_pid_under <root-pid> → pid of a `claude` process under that root (direct or nested)
# pids_under <root-pid> <pid>… → those pids (in the order given) that root is an ancestor of (or is): is_under for many
# pids against ONE process-table snapshot. claude_pid_under used to walk each `pgrep -x claude` pid up with one `ps` per
# step; with many claude processes on a machine that was hundreds of ps calls, 5–20 s a lookup.
pids_under() {
    local root="$1"; shift; [ $# -gt 0 ] || return 1
    if [ -r /proc/self/stat ]; then
        # the same walk read from /proc by the shell (it was a ps and an awk per call, and this is asked for every pane of every sweep)
        local w q d line hit=1
        for w in "$@"; do
            q=$w; d=0
            while [ -n "$q" ] && [ "$q" != 1 ] && [ "$q" != 0 ] && [ "$d" -lt 4096 ]; do
                if [ "$q" = "$root" ]; then printf '%s\n' "$w" 2>/dev/null; hit=0; break; fi   # (silent when the reader — claude_pid_under's `read` — has left)
                line=""; { read -r line < "/proc/$q/stat"; } 2>/dev/null || break
                line=${line##*) }; q=""; read -r _ q _ <<< "$line"   # "<state> <ppid> …" after the command name
                d=$((d + 1))
            done
        done
        return $hit
    fi
    proc_table | awk -v root="$root" -v want="$*" '{ pp[$1] = $2 }
        END { n = split(want, w, " "); hit = 1
              for (i = 1; i <= n; i++) { q = w[i]; d = 0
                  while (q != "" && q != 1 && q != 0 && d < 4096) { if (q == root) { print w[i]; hit = 0; break }; q = pp[q]; d++ } }
              exit hit }'
}
# _claude_pids_r <var> → the pids of the processes named claude (pgrep -x claude), one per line, ascending, in <var>; 1 when there are none.
# Read from /proc by the shell where there is one (a pgrep per lookup, and the sweeps ask for every pane).
_claude_pids_r() {
    local _d _c _p _i _o="" _hit=1
    local -a _a=() _s=()
    if [ ! -r /proc/self/stat ]; then _o=$(pgrep -x claude 2>/dev/null) && _hit=0; printf -v "$1" '%s' "$_o"; return $_hit; fi
    for _d in /proc/[0-9]*; do _c=""; { read -r _c < "$_d/comm"; } 2>/dev/null || continue; [ "$_c" = claude ] && _a+=("${_d#/proc/}"); done
    for _p in ${_a[@]+"${_a[@]}"}; do
        _i=${#_s[@]}
        while [ "$_i" -gt 0 ] && [ "${_s[_i-1]}" -gt "$_p" ]; do _s[_i]=${_s[_i-1]}; _i=$((_i - 1)); done
        _s[_i]=$_p
    done
    for _p in ${_s[@]+"${_s[@]}"}; do _o+="$_p"$'\n'; _hit=0; done
    printf -v "$1" '%s' "${_o%$'\n'}"; return $_hit
}
claude_pid_under() {
    local pids; _claude_pids_r pids || return 1
    pids_under "$1" $pids | { local first=""; read -r first; [ -n "$first" ] && printf '%s\n' "$first"; }   # the first line, as head -1 | grep . (two fewer processes per call)
}
# rc_server_pid_under <root-pid> → pid of a `claude remote-control` process under that root.
# The server runs from a non-interactive bash loop, so the pane's #{pane_current_command}
# reads "bash" even while the server is up — never key the server pane on that.
rc_server_pid_under() {
    local pid
    local cp; _claude_pids_r cp || return 1
    for pid in $(pids_under "$1" $cp); do is_rc_server "$pid" && { echo "$pid"; return 0; }; done
    return 1
}
# re_escape_r <var> <text> → <text> as an ERE that matches exactly itself, in <var>. For a name, comm or command line that goes INTO
# a pattern (pgrep_mine, grep -E): a pid 1 can be named like `init(Distro-1.0)`, and its `(` unescaped is "Unmatched ( or \(" from
# [[ =~ ]] for every process scanned. Escapes only the ERE metacharacters (\ . [ ] ( ) { } * + ? | ^ $), never a character
# GNU regex reads as an operator behind a backslash (\< \> \b …).
re_escape_r() { local _s=$2; _s=${_s//\\/\\\\}; _s=${_s//[.\[\]\(\)\{\}*+?|^\$]/\\&}; printf -v "$1" '%s' "$_s"; }
# pgrep_mine <pattern> → `pgrep -af <pattern>`, kept to this sala instance: processes whose HOME (/proc/<pid>/environ,
# same user) is this $HOME; 0 when one matched. A machine-wide match made a sandboxed watch skip its whole run whenever
# any other sala on the box (the fleet's, another worktree's test suite) ran a revive (a flake of tests/ledger.sh).
# No /proc environ (macOS): machine-wide, as before.
pgrep_mine() {
    local out pid cmd hit=1 kv h d rx IFS=$' \t\n'
    if [ -r /proc/self/stat ]; then   # the scan pgrep does, by the shell (a pgrep process per call, three on every watch tick)
        { [[ "" =~ $1 ]]; } 2>/dev/null && rx=0 || rx=$?; [ "$rx" -ne 2 ] || { echo "pgrep_mine: not a regular expression: $1" >&2; return 2; }   # said once, not once per process; a literal name goes through re_escape_r
        for d in /proc/[0-9]*; do
            pid=${d#/proc/}; _nul_read "$d/cmdline"; [ ${#_NUL[@]} -gt 0 ] || continue
            cmd="${_NUL[*]}"; [[ $cmd =~ $1 ]] || continue
            h=""; _nul_read "$d/environ"
            for kv in ${_NUL[@]+"${_NUL[@]}"}; do [[ $kv == HOME=* ]] && { h=${kv#HOME=}; break; }; done
            [ "$h" = "$HOME" ] || continue
            printf '%s %s\n' "$pid" "$cmd" 2>/dev/null; hit=0   # (silent when the reader has left)
        done
        return $hit
    fi
    out=$(pgrep -af "$1" 2>/dev/null) || return 1
    [ -r "/proc/$$/environ" ] || { printf '%s\n' "$out"; return 0; }
    while read -r pid cmd; do
        h=""; _nul_read "/proc/$pid/environ"   # was tr | sed | head per process
        for kv in ${_NUL[@]+"${_NUL[@]}"}; do [[ $kv == HOME=* ]] && { h=${kv#HOME=}; break; }; done
        [ "$h" = "$HOME" ] || continue
        printf '%s %s\n' "$pid" "$cmd" 2>/dev/null; hit=0
    done <<< "$out"
    return $hit
}

# ready_for <uuid> → 0 when the session left a live `ready` marker (lib/ready.sh): its own word that
# background work may be cut, so the child/scratch checks below are waived for it.
ready_for() { local f="$SALA_READY_DIR/$1" t="" now; [ -r "$f" ] || return 1; { IFS= read -r -d '' t < "$f"; } 2>/dev/null || :; t=${t%%$'\n'*}; _now_r now; [ "$(( now - ${t:-0} ))" -le "$SALA_READY_TTL" ] || { rm -f "$f"; return 1; }; }
ready_clear() { rm -f "$SALA_READY_DIR/$1" 2>/dev/null; }
ready_wake() {  # → 0 when a pending relaunch's retry worker was woken (SIGUSR1; each worker has its own pid file, salamander-retry.<pid>.pid)
    local f rp woke=1
    for f in "$SALA_LOG_DIR"/salamander-retry*.pid; do rp=$(cat "$f" 2>/dev/null); [ -n "$rp" ] && kill -USR1 "$rp" 2>/dev/null && woke=0; done
    return $woke
}
# ready_shell_hold <claude-pid> → 0 when the session said `ready` and the registry still says 'shell': its turn is over and only
# background shells hold it (Thu Oct 22nd 2026: a builder said ready ~20 times in a recycle and sat
# at 'shell' behind two Bash loops, `gh pr checks` under a timeout and an until-loop on a file, until the window ended and it
# was given up). The shells do not end by themselves in minutes, so waiting for the registry to turn idle is no retry: the
# pane goes on the deferred list (defer_add) and watch relaunches it once they are done. Never a reason to relaunch it earlier.
ready_shell_hold() { local sid st; registry_field_r sid "$1" sessionId; [ -n "$sid" ] && ready_for "$sid" && { registry_field_r st "$1" status; [ "$st" = shell ]; }; }
# ── the Stop hook's busy record (lib/hook.sh) ───────────────────────────
# busy_state <claude-pid> <uuid> [statusUpdatedAt] → what the session's own Stop hook recorded in flight when its last turn
# ended (busy/<uuid>), when that record is for THIS idle stretch: its flip stamp is the registry row's statusUpdatedAt now.
# Returns 0 and prints the reason: work in flight → busy. Returns 1, prints nothing: nothing in flight → idle, no guessing.
# Returns 2: no record for this stretch (the hook not registered, a CLI without the field, the flip not stamped yet, or a turn
# ended since without the hook — an interrupted one) → the caller falls back to its guesses. A job started with `setsid nohup`
# has left claude's process tree and its task registry alike: neither the record nor the guesses see it.
busy_state() {
    local f st="${3:-}" n real w=0 tl="" l pr="" pw="" re="^task=monitor [^:]*: ${SALA_ARTIFACT_WATCH_DESC}( \\([^()]*\\))?\$"
    _busy_current_r f "$1" "$2" "$st" || return 2
    _kv_first_r n "$f" tasks; n=${n%%=*}; case "$n" in ''|*[!0-9]*) return 2;; esac
    [ "$n" -gt 0 ] || return 1
    # an artifact watch is not work in flight (THE ARTIFACT WATCH below): only the other tasks count. The record's task lines are
    # read here with _busy_split's own rule, in this shell (it was a subshell, a grep and an awk per call)
    while IFS= read -r l; do
        case "$l" in task=*) ;; *) continue;; esac
        if [[ $l =~ $re ]]; then w=$((w + 1)); else tl+="${tl:+; }${l#task=}"; fi
    done < "$f"
    real=$(( n - w ))
    [ "$real" -gt 0 ] || return 1
    if [ "$real" = 1 ]; then pr="1 task"; else pr="$real tasks"; fi
    if [ "$w" -gt 0 ]; then if [ "$w" = 1 ]; then pw=" (and 1 artifact watch, not counted)"; else pw=" (and $w artifact watchs, not counted)"; fi; fi
    echo "background work in flight when its last turn ended ($pr, by the Stop hook's record): $tl$pw"
}
_busy_current() {  # <claude-pid> <uuid> [statusUpdatedAt] → the record's path when it is for THIS idle stretch (busy_state), else 2
    local f="$SALA_BUSY_DIR/$2" st="${3:-}" flip
    [ -r "$f" ] || return 2
    [ -n "$st" ] || registry_field_r st "$1" statusUpdatedAt; [ -n "$st" ] || return 2
    _kv_first_r flip "$f" flip; flip=${flip%%=*}; [ -n "$flip" ] && [ "$flip" = "$st" ] || return 2
    echo "$f"
}
_busy_current_r() {  # <var> <claude-pid> <uuid> [statusUpdatedAt] → as _busy_current, the path in <var>, no subshell
    local _bf="$SALA_BUSY_DIR/$3" _bs="${4:-}" _bl
    printf -v "$1" '%s' ""
    [ -r "$_bf" ] || return 2
    [ -n "$_bs" ] || registry_field_r _bs "$2" statusUpdatedAt; [ -n "$_bs" ] || return 2
    _kv_first_r _bl "$_bf" flip; _bl=${_bl%%=*}; [ -n "$_bl" ] && [ "$_bl" = "$_bs" ] || return 2
    printf -v "$1" '%s' "$_bf"
}
# THE ARTIFACT WATCH. When a session
# publishes an artifact, Claude Code arms a watch for the artifact's new versions and comments by itself; a session also
# arms one when asked to watch an artifact. The Stop hook's background_tasks carries it as type "monitor" with this
# description, for example:
#     live updates for artifact https://claude.ai/artifact/EXAMPLEARTIFACTID (auto-armed on publish)
# where the label in brackets says how it was armed. Claude Code 2.1.296 (zjt) writes one of seven:
#     auto-armed on publish · attached via /artifacts · watch requested · resume requested · re-armed on session resume ·
#     presence while editing via MCP · watch requested; auto-replies since stopped
# The busy check read such a pane busy for as long as the watch ran (a recycle once skipped
# two project agents for it alone); with only "auto-armed on publish" exempt, a watch armed on
# request kept its pane busy for ever, and an auto-armed watch came back after the relaunch as "re-armed on session
# resume" and blocked the next recycle. No artifact watch is work in flight, whatever its label:
# busy_state leaves it out, the mod's exit check too (mod/hooks/register.ts, ARTIFACT_WATCH: the mod's own copy of this
# wording, in its own language), and the CLI's own exit dialog lists none (2.1.296: an ambient monitor_ws is skipped).
# The relaunch leaves the watch as it is: the CLI arms it again when the session comes back (`claude --resume`; 2.1.296,
# rearmArtifactLiveOnMount; its label is then "re-armed on session resume"), while a watch the session itself stopped
# comes back only on the owner's own message, so sala never asks a session to stop or re-arm one. Matched narrowly, on the
# exact wording, one of those labels and the type: any other monitor, another label, or this wording with anything more
# in the description, counts as before. SALA_ARTIFACT_WATCH_DESC is the description (ERE, group 1 the URL); a record
# line is "task=<type> <status>: <description>" plus " (<server/tool, command, agent or name>)" when the task has one
# (lib/hook.sh).
SALA_ARTIFACT_WATCH_DESC='live updates for artifact (https://claude\.ai/(code/)?artifact/[A-Za-z0-9_-]+) \((auto-armed on publish|attached via /artifacts|watch requested|resume requested|re-armed on session resume|presence while editing via MCP|watch requested; auto-replies since stopped)\)'
_busy_split() {  # <record> → one line per task line: "W<tab><url>" for an artifact watch, "T<tab><the task>" for any other
    local l re="^task=monitor [^:]*: ${SALA_ARTIFACT_WATCH_DESC}( \\([^()]*\\))?\$"
    while IFS= read -r l; do
        case "$l" in task=*) ;; *) continue;; esac
        if [[ $l =~ $re ]]; then printf 'W\t%s\n' "${BASH_REMATCH[1]}"; else printf 'T\t%s\n' "${l#task=}"; fi
    done < "$1"
}
# later_commands <claude-pid> <uuid> — the commands holding a deferred pane, one per line, at most 3, each cut and scrubbed
# The tasks the Stop hook's record lists for this idle stretch (a background shell with its command line; an
# artifact watch is not one), else the command lines of the claude's own work children. The text goes into a post, so
# scrub_text masks anything that looks like a secret.
later_commands() {
    local f k out=""
    if f=$(_busy_current "$1" "$2" 2>/dev/null); then out=$(_busy_split "$f" | awk -F'\t' '$1=="T" {print substr($0, 3)}'); fi
    if [ -z "$out" ]; then for k in $(work_children "$1"); do out+="$(tr '\0' ' ' < "/proc/$k/cmdline" 2>/dev/null | sed 's/ *$//')"$'\n'; done; fi
    printf '%s\n' "$out" | grep . | head -3 | cut -c1-240 | scrub_text
}
busy_watches() {  # <claude-pid> <uuid> [statusUpdatedAt] → the URLs of the artifact watches in this stretch's record, one per line
    local f; f=$(_busy_current "$@") || return 0
    _busy_split "$f" | awk -F'\t' '$1=="W" && !s[$2]++ {print $2}'
}
busy_hook_idle() { local rc=0; busy_state "$1" "$2" >/dev/null 2>&1 || rc=$?; [ "$rc" = 1 ]; }   # <claude-pid> <uuid> → 0 when the record says nothing is in flight
busy_stamp() {  # <uuid> <record id> <stamp> → add the idle flip that followed the turn to the record, if it is still that record
    local f="$SALA_BUSY_DIR/$1" t; [ -r "$f" ] && grep -qx "id=$2" "$f" 2>/dev/null || return 1
    t="$f.s.${BASHPID:-$$}"; { grep -v '^flip=' "$f"; echo "flip=$3"; } > "$t" && mv -f "$t" "$f"
}
busy_prune() { [ -d "$SALA_BUSY_DIR" ] && find "$SALA_BUSY_DIR" -maxdepth 1 -type f -mtime +3 -delete 2>/dev/null; return 0; }   # watch: records of sessions long gone
# ── the relaunch-waiting flag (the hook also covers every other relaunch scenario) ──
# Every relaunch sala starts and has to wait for a pane raises waiting/<uuid> for it: a recycle's retry worker (whatever
# started the recycle: the master's cue, `update`, `provision`, watch's auto-recycle or its relaunch onto a new CLI) and the
# reboot drain. The session's PostToolUse hook then tells it once (relaunch_text), and its Stop hook, ending a turn with
# nothing in flight, counts as `sala ready` (lib/hook.sh). A crash revive warns nobody: there is no relaunch to wait for.
# relaunch_kind [kind] → recycle · reboot · update · provision · auto, from the argument or SALA_RELAUNCH_KIND (the starter
# exports it; `update` update, `provision` provision, watch auto / update); anything else is a recycle.
relaunch_kind() { case "${1:-${SALA_RELAUNCH_KIND:-}}" in reboot|update|provision|auto) echo "${1:-$SALA_RELAUNCH_KIND}";; *) echo recycle;; esac; }
relaunch_what() {  # <kind> → the words the waiting line calls it
    case "$1" in reboot) echo "reboot of $(hostname)";; update) echo "CLI update relaunch";; provision) echo "provision relaunch";; auto) echo "automatic relaunch";; *) echo recycle;; esac
}
relaunch_text() {  # <what words> [claude-pid] → the line the hook gives the session; with the pid, the holders of the pane appended
    printf '%s\n' "${SALA_RELAUNCH_WAITING_TEXT//<what>/$1}" 2>/dev/null   # (silent when the reader has left)
    [ -n "${2:-}" ] && holders_block "$2" "Still running under this pane right now, <n> that the relaunch will cut or that hold it:" "$SALA_HOLDERS_HOWTO"
    [ -n "${2:-}" ] && subagents_block "$2"
    return 0
}
# subagents_block <claude-pid> → what a running subagent means for the relaunch, one line each; nothing when none run. A subagent is
# never cut by a relaunch that waits for it, and a shell or a task it started is no excuse to cut it: the exit is refused until it ends.
subagents_block() {
    local l n=0 out=""
    while IFS= read -r l; do [ -n "$l" ] && { out+="  $l"$'\n'; n=$((n + 1)); }; done < <(subagent_holders "$1")
    [ "$n" -gt 0 ] || return 0
    { printf 'Holding the relaunch: %s running in this session (sala never cuts a running subagent; the relaunch follows once it ends):\n%s' "$(plural "$n" subagent)" "$out"
      printf '%s\n' "End one you do not need from this session (TaskStop <its id> when the CLI lists it, or let it finish); a subagent no task list shows ends only with its work."; } 2>/dev/null
    return 0
}
waiting_raise() {  # <uuid> <kind> <set id> [owner pid] — raised again for the same set it keeps its "told"; a new set tells the session again
    [ -n "${1:-}" ] || return 0; local f="$SALA_WAITING_DIR/$1" t="$SALA_WAITING_DIR/$1.t.${BASHPID:-$$}"
    mkdir -p "$SALA_WAITING_DIR" 2>/dev/null || return 0
    [ "$(awk -F= '$1=="set" {print substr($0, 5); exit}' "$f" 2>/dev/null)" = "${3:-}" ] || rm -f "$f.told"
    printf 'kind=%s\nwhat=%s\nset=%s\nowner=%s\nboot=%s\nsince=%s\n' "$(relaunch_kind "$2")" "$(relaunch_what "$(relaunch_kind "$2")")" "${3:-}" "${4:-$$}" "$(boot_id 2>/dev/null)" "$(date +%s)" > "$t" && mv -f "$t" "$f"
}
waiting_for() { [ -n "${1:-}" ] && [ -e "$SALA_WAITING_DIR/$1" ]; }
waiting_what() { awk -F= '$1=="what" {print substr($0, 6); exit}' "$SALA_WAITING_DIR/$1" 2>/dev/null; }
waiting_told() { [ -n "${1:-}" ] || return 1; ( set -o noclobber; : > "$SALA_WAITING_DIR/$1.told" ) 2>/dev/null; }   # 0 for the first caller only
waiting_clear() { [ -n "${1:-}" ] || return 0; rm -f "$SALA_WAITING_DIR/$1" "$SALA_WAITING_DIR/$1.told" 2>/dev/null; return 0; }
waiting_clear_owner() {  # <pid> — every flag that owner raised (a worker at its end, the drain at its end)
    local f; for f in "$SALA_WAITING_DIR"/*; do [ -f "$f" ] || continue; case "$f" in *.told|*.t.*) continue;; esac
        [ "$(awk -F= '$1=="owner" {print substr($0, 7); exit}' "$f" 2>/dev/null)" = "$1" ] && waiting_clear "${f##*/}"; done; return 0
}
waiting_clear_all() { rm -f "$SALA_WAITING_DIR"/* 2>/dev/null; return 0; }   # a new recycle: its sweep covers every pane again
waiting_prune() {  # watch: a flag whose owner is gone (a killed worker, a reboot that happened), a .told with no flag, a temp
    local f u; for f in "$SALA_WAITING_DIR"/*; do [ -f "$f" ] || continue; u="${f##*/}"
        case "$u" in *.t.*) rm -f "$f"; continue;; *.told) [ -e "${f%.told}" ] || rm -f "$f"; continue;; esac
        if [ "$(awk -F= '$1=="boot" {print substr($0, 6); exit}' "$f")" != "$(boot_id 2>/dev/null)" ] || ! kill -0 "$(awk -F= '$1=="owner" {print substr($0, 7); exit}' "$f")" 2>/dev/null; then waiting_clear "$u"; fi
    done; return 0
}
# is_idle <claude-pid> → 0 idle · 1 busy · 2 unknown (used by revive, recycle, watch)
# is_idle_reason <claude-pid> → the reason it is not idle, or empty when it is. Callers report THIS
# instead of a catch-all "busy (…)" line, so a skip says which of the four cases it was.
# scheduled_jobs <claude-pid> <uuid> → one line per session-only scheduled job (CronCreate) the session still holds:
# id \t once|recurring \t epoch (a one-shot's fire time · a recurring job's 7-day expiry) \t cron. Reported only: a job does not
# hold a relaunch back (holding a job must not make a pane immune to recycle), because `claude --resume`
# re-arms the session's jobs itself, even after "Exit and stop tasks" (tested on 2.1.289: one job, back once). Read from the
# whole transcript: a job outlives a relaunch (a one-shot made late at night was still listed by the process resumed hours later), so its age says nothing. CronCreate results name the job id, CronDelete removes it, a one-shot is gone once its
# time has passed, a recurring one after 7 days. A job a person stopped at exit still counts until then: the safe side.
scheduled_jobs() {
    local tr; tr=$(transcript_for_uuid "$2"); [ -n "$tr" ] || return 0
    python3 - "$tr" 0 <<'PYSJ' 2>/dev/null
import json, re, sys, time
from datetime import datetime, timedelta
tr, up = sys.argv[1], int(sys.argv[2]); now = time.time()
def ts(o):
    try: return datetime.fromisoformat(o["timestamp"].replace("Z", "+00:00")).timestamp()
    except Exception: return 0
def field(f, lo, hi):
    out = set()
    for part in f.split(","):
        step = 1
        if "/" in part: part, st = part.split("/"); step = int(st)
        if part == "*": a, b = lo, hi
        elif "-" in part: a, b = map(int, part.split("-"))
        else: a = b = int(part)
        out.update(range(a, b + 1, step))
    return out
def next_fire(expr, after):
    m, h, dom, mon, dow = expr.split()
    M, H, D, MO, W = field(m, 0, 59), field(h, 0, 23), field(dom, 1, 31), field(mon, 1, 12), {d % 7 for d in field(dow, 0, 7)}
    t = datetime.fromtimestamp(after).replace(second=0, microsecond=0) + timedelta(minutes=1)
    for _ in range(366):
        dm = (dom == "*" or t.day in D); dw = (dow == "*" or (t.isoweekday() % 7) in W)
        dayok = t.month in MO and ((dm and dw) if (dom == "*" or dow == "*") else (dm or dw))
        if dayok:
            for hh in sorted(H):
                for mm in sorted(M):
                    c = t.replace(hour=hh, minute=mm)
                    if c >= t: return c.timestamp()
        t = (t + timedelta(days=1)).replace(hour=0, minute=0)
    return None
uses, jobs = {}, {}
for line in open(tr, encoding="utf-8"):
    if "Cron" not in line and "Scheduled" not in line: continue
    try: o = json.loads(line)
    except Exception: continue
    if ts(o) < up: continue
    c = (o.get("message") or {}).get("content")
    if not isinstance(c, list): continue
    for b in c:
        if b.get("type") == "tool_use" and b.get("name") == "CronCreate": uses[b["id"]] = (b.get("input") or {}, ts(o))
        elif b.get("type") == "tool_use" and b.get("name") == "CronDelete": jobs.pop(str((b.get("input") or {}).get("id", "")), None)
        elif b.get("type") == "tool_result" and b.get("tool_use_id") in uses:
            t = b.get("content"); t = t if isinstance(t, str) else json.dumps(t)
            mm = re.search(r"Scheduled (?:recurring |one-shot |one-time )?(?:job|task) ([0-9a-f]{6,})", t)
            if not mm or "Session-only" not in t: continue
            inp, at = uses[b["tool_use_id"]]
            cr = inp.get("cron", "* * * * *")
            if inp.get("recurring", True): jobs[mm.group(1)] = ("recurring", at + 7 * 86400, cr)
            else:
                f = next_fire(cr, at)
                if f: jobs[mm.group(1)] = ("once", f, cr)
for j, (k, e, cr) in jobs.items():
    if e > now: print(f"{j}\t{k}\t{int(e)}\t{cr}")
PYSJ
}
# work_children <claude-pid> → its child pids that may be work in flight, one per line. A plugin's MCP (or LSP) server is
# left out: claude starts it at launch and it runs for the session's life (a PDF server under every pane, for example), so the child-pid guess below read every pane without a Stop record busy for ever and a recycle
# skipped most panes, --force or not. Claude Code gives a plugin's processes CLAUDE_PLUGIN_ROOT in their environment
# and gives the Bash tool's shells (`bash -c source ~/.claude/shell-snapshots/…`) none; a Bash-tool shell always counts,
# whatever its environment. No stdio MCP server is configured outside a plugin on the fleet (~/.claude.json has none),
# so one would still read busy. An unreadable environ (another user's process) counts, as before.
# _children_r <var> <pid>  — the pids whose parent is <pid>, ascending, space-separated, in <var> (pgrep -P was a process per
# call, asked for every pane of every sweep). Where /proc has the per-thread children lists the shell reads them (a thread other than the
# main one may have forked the child, so every thread's list); elsewhere pgrep -P.
_children_r() {
    local f line out="" p q t
    local -a a b
    if [ -r "/proc/$2/task/$2/children" ]; then
        for f in /proc/"$2"/task/*/children; do line=""; { read -r line < "$f"; } 2>/dev/null || :; out+=" $line"; done
        a=($out); b=()
        for p in ${a[@]+"${a[@]}"}; do   # insertion sort, numeric: a handful of pids
            q=${#b[@]}; b[q]=$p
            while [ "$q" -gt 0 ] && [ "${b[q-1]}" -gt "${b[q]}" ]; do t=${b[q-1]}; b[q-1]=${b[q]}; b[q]=$t; q=$((q - 1)); done
        done
        printf -v "$1" '%s' "${b[*]-}"
    else
        out=$(pgrep -P "$2" 2>/dev/null || true); printf -v "$1" '%s' "${out//$'\n'/ }"
    fi
}
work_children() {
    local k kids kv plug
    _children_r kids "$1"
    for k in $kids; do
        # grep -qs shell-snapshots cmdline, and the environ test, read by the shell (three processes per child)
        _nul_read "/proc/$k/cmdline"
        if [[ "${_NUL[*]-}" != *shell-snapshots* ]]; then
            plug=0; _nul_read "/proc/$k/environ"
            for kv in ${_NUL[@]+"${_NUL[@]}"}; do [[ $kv == CLAUDE_PLUGIN_ROOT=* ]] && { plug=1; break; }; done
            [ "$plug" = 1 ] && continue
        fi
        echo "$k" 2>/dev/null   # (silent when the reader has left)
    done
}
# holders_run <claude-pid> [max] → lib/holders.py scan: the count on the first line, then one line per process that holds the
# pane (pid, how long it has run, its task id, the subagent that started it, its command cut to 120). Read-only, one
# python, the process table read from /proc (ps only where there is none). The process tree does the work, never the word
# "claude" (lib/holders.py has the rules). Prints "0" when it cannot tell.
holders_run() {
    SALA_REG_DIR="$SALA_REG_DIR" SALA_PROJECTS="$SALA_PROJECTS" SALA_SCRUB_PY="$SALA_SCRUB_PY" \
        python3 -I -S "$SALA_ROOT/lib/holders.py" scan "$1" --max "${2:-5}" 2>/dev/null || echo 0
}
# holders_inline <claude-pid> → the holders on one line for a skip reason ("pid 12, up 5 h: cmd · pid 15, …"), nothing when none
holders_inline() {
    local out l s=""; local -a a
    out=$(holders_run "$1" 3) || return 0
    mapfile -t a <<< "$out"
    [ "${a[0]:-0}" -gt 0 ] 2>/dev/null || return 0
    for l in "${a[@]:1}"; do s+="${s:+ · }$l"; done   # " · " between holders: a command has its own ; and |
    printf '%s\n' "$s" 2>/dev/null
}
# THE DEFERRED-PANE BULLET: a recycle's posts name a pane that is held, whether in the first
# post, the "n deferred" post or a 🔄 follow-up, with ONE short reason and the same text in all three:
#   <session>: busy for <age>; sala relaunches it once it is free                            (a turn or a dialog is running)
#   <session>: its <n> background tasks ran for <age>; sala relaunches it once they finish   (holders under a registry 'shell' state;
#                                                                                             "its 1 background task ran for …" for one)
# No pid, uptime, task id or command in a post: holders_inline's detail stays in the skip reason (is_idle_reason, what `sala ready`
# and the logs print) and in ~/.claude/salamander-revive.log, whose rlog lines keep it. hold_bullet only WORDS a post; what the code
# parses (transient_skip, the deferred rows' reason, "background work is running") still reads the raw reason, unchanged.
hold_age_words() {  # <seconds> → "35 min" · "2 h" · "3 days": short words, rounded down, never below 1 min
    local s=${1:-0}; [[ $s =~ ^[0-9]+$ ]] || s=0
    if [ "$s" -lt 3600 ]; then echo "$(( s < 60 ? 1 : s / 60 )) min"
    elif [ "$s" -lt 86400 ]; then echo "$(( s / 3600 )) h"
    else plural $(( s / 86400 )) day; fi
}
# holders_summary_r <var> <claude pid> → "<n> <seconds the oldest holder has run>" in <var> ("0 0" when nothing holds the pane or it cannot be read)
holders_summary_r() {
    local _o
    _o=$(SALA_REG_DIR="$SALA_REG_DIR" SALA_PROJECTS="$SALA_PROJECTS" SALA_SCRUB_PY="$SALA_SCRUB_PY" python3 -I -S "$SALA_ROOT/lib/holders.py" scan "$2" --summary 2>/dev/null) || _o=""
    [[ $_o =~ ^[0-9]+\ [0-9]+$ ]] || _o="0 0"
    printf -v "$1" '%s' "$_o"
}
# hold_bullet <session> <claude pid> <raw reason> → the bullet above on stdout; return 1 (nothing printed) for a reason that is neither
# kind (a draft, a prompt, a rest, a refusal…), which the caller words as before. The reason picks the kind: a registry 'shell' state or a
# background task / work / agent → "background tasks" when processes hold the pane now (the oldest one's run time is the age), else
# "busy"; a turn or a dialog (registry busy, "a turn is running") → "busy", its age the time since the registry's last status change.
# A pane that is idle in the registry and held by work no process shows has no age worth stating: "busy; sala relaunches it once it is free".
hold_bullet() {
    local sess="$1" pid="${2:-}" why="${3:-}" kind n=0 secs=0 st="" stamp="" age="" sm
    case "$why" in
        "parked in background job"*) return 1;;
        *"registry says 'shell'"*|*"a background task is running"*|*"background work in flight"*|*"background work is running"*|*"background agent or task wrote"*) kind=tasks;;
        *"registry says '"*|*"a turn is running"*|*"a subagent is running"*) kind=busy;;
        *) return 1;;
    esac
    if [ -n "$pid" ] && [ "$pid" != 0 ]; then
        if [ "$kind" = tasks ]; then holders_summary_r sm "$pid"; read -r n secs <<< "$sm"; fi
        if [ "${n:-0}" -ge 1 ]; then
            printf '%s: its %s ran for %s; sala relaunches it once they finish\n' "$sess" "$(plural "$n" "background task")" "$(hold_age_words "$secs")"; return 0
        fi
        registry_field_r st "$pid" status; registry_field_r stamp "$pid" statusUpdatedAt
        if [ -n "$st" ] && [ "$st" != idle ] && [ -n "$stamp" ]; then _stamp_age_r age "$stamp"; fi
    fi
    printf '%s: busy%s; sala relaunches it once it is free\n' "$sess" "${age:+ for $(hold_age_words "$age")}"
}
# hold_bullet_sess <session> <raw reason> → hold_bullet for the claude now in that tmux session (the sweep's rows carry no pid)
hold_bullet_sess() {
    local pp c; pp=$(tmux list-panes -t "$(tmux_win_t "$1")" -F '#{pane_pid}' 2>/dev/null | head -1); c=$(claude_pid_under "$pp" 2>/dev/null)
    hold_bullet "$1" "${c:-0}" "$2"
}
# holders_block <claude-pid> <lead line> <tail line> → the lead (<n> becomes "N background process(es)"), the holders one a
# line indented, the tail; nothing when none. The one place the wording of a holder list lives: `sala ready` and the relaunch
# notice both print it. (Builtin printf, silent when the reader has left.)
holders_block() {
    local out n l; local -a a
    out=$(holders_run "$1" 5); mapfile -t a <<< "$out"; n=${a[0]:-0}
    [ "$n" -gt 0 ] 2>/dev/null || return 0
    { printf '%s\n' "${2//<n>/$n background process(es)}"; for l in "${a[@]:1}"; do printf '  %s\n' "$l"; done; printf '%s\n' "$3"; } 2>/dev/null
    return 0
}
SALA_HOLDERS_HOWTO='Stop them first if they are not needed: TaskStop <task id> for a background task (a subagent'\''s shell is in no task list of yours, TaskStop still takes its id), or `kill <pid>`.'
# own_claude_pid → the claude process the running shell sits under, via the registry (a Bash tool call, a hook)
own_claude_pid() {
    local p=$$ line s
    while [ -n "$p" ] && [ "$p" != 0 ] && [ "$p" != 1 ]; do
        [ -r "$SALA_REG_DIR/$p.json" ] && { echo "$p"; return 0; }
        if [ -r /proc/self/stat ]; then   # the parent read from /proc by the shell, as proc_ppid does, without its subshell
            line=""; { read -r line < "/proc/$p/stat"; } 2>/dev/null || return 1
            line=${line##*) }; read -r s p _ <<< "$line"
        else p=$(proc_ppid "$p"); fi
    done; return 1
}
_ancestor_pids() {  # → this shell and every process above it, one pid per line (the way up from a call to its claude)
    local p=$$ np
    while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
        echo "$p"; np=""; { read -r _a _b _c np _ < "/proc/$p/stat"; } 2>/dev/null || :; p=$np
    done
}
# THE SUBAGENTS THE IDLE CHECK COULD NOT SEE. A subagent is no child process of the claude and may write nothing for many
# minutes (it waits on a long tool call), so the registry, the children and the 2-minute scratch test all read the pane as
# idle while the session's in-session mod (mod/hooks/register.ts) refuses the /exit for it. The transcript of every subagent
# the CLI starts is a file, <projects>/<slug>/<uuid>/subagents/agent-<id>.jsonl, with an <id>.meta.json beside it whose
# "finished" field is written when it ends. One that is not finished, was written since this claude started (an older one belonged
# to a process that is gone: a resume leaves its files behind) and for less than SALA_SUBAGENT_STALE s (default 6 h; a subagent
# that crashed never writes "finished") is running. Same definition as the mod's, so the two cannot disagree for long.
: "${SALA_SUBAGENT_STALE:=21600}"
# subagent_holders <claude-pid> [uuid] → one line per running subagent ("<type>: <description> (quiet <n> min)"), nothing when none
subagent_holders() {
    local sid="${2:-}" cwd d f m body age lim et mt type desc
    [ -n "$sid" ] || registry_field_r sid "$1" sessionId; [ -n "$sid" ] || return 0
    cwd=$(proc_cwd "$1") || return 0; [ -n "$cwd" ] || return 0
    d="$SALA_PROJECTS/$(slug_for_cwd "$cwd")/$sid/subagents"; [ -d "$d" ] || return 0
    # how long this claude has run: the registry row's startedAt (ms), else the process's own age
    lim=$SALA_SUBAGENT_STALE; registry_field_r et "$1" startedAt; _now_r age
    if [[ $et =~ ^[0-9]+$ ]]; then et=$(( age - et / 1000 )); else et=$(proc_etime "$1" 2>/dev/null || echo 0); fi
    [ "$et" -gt 0 ] 2>/dev/null && [ "$et" -lt "$lim" ] && lim=$et
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        m=${f%.jsonl}.meta.json; [ -r "$m" ] || continue   # no meta: not one the CLI registered; the 2-minute scratch test sees a fresh one
        body=$(<"$m"); [[ $body =~ \"finished\"[[:space:]]*:[[:space:]]*true ]] && continue
        type=""; desc=""
        [[ $body =~ \"agentType\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]] && type=${BASH_REMATCH[1]}
        [[ $body =~ \"description\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]] && desc=${BASH_REMATCH[1]}
        age="over 6 h"
        for mt in 1 5 15 60 180 360; do [ -n "$(find "$f" -mmin -"$mt" -print -quit 2>/dev/null)" ] && { age="under $mt min"; break; }; done
        printf 'subagent %s%s (last wrote %s ago)\n' "${type:-?}" "${desc:+: ${desc:0:80}}" "$age"
    done < <(find "$d" -maxdepth 1 -name 'agent-*.jsonl' -mmin -"$(( lim / 60 + 1 ))" -print 2>/dev/null | sort)
}
# subagents_why <claude-pid> [uuid] → "a subagent is running: <one>; <two>" when subagent_holders finds any, else nothing
subagents_why() { local l s=""; while IFS= read -r l; do [ -n "$l" ] && s+="${s:+; }$l"; done < <(subagent_holders "$@"); [ -z "$s" ] || echo "a subagent is running: $s"; }
is_idle_reason() {
    local st stamp age sid d hs hl jp jwhy
    registry_field_r st "$1" status; [ -n "$st" ] || { echo "no registry status for pid $1 — cannot confirm idle"; return; }
    # a PARKED pane ("a pane parked on a background job" above): its own status is always 'shell', so the job's state
    # is the session's — idle when the job is idle, the job's reason otherwise
    if parked_job_pid_r jp "$1"; then
        jwhy=$(is_idle_reason "$jp"); parked_job_r hl "$1"
        [ -z "$jwhy" ] || echo "parked in background job ${hl:0:8}: $jwhy"
        return 0
    fi
    if [ "$st" = shell ]; then   # the turn is over and background shell(s) hold the pane: name them
        hl=$(holders_inline "$1"); echo "registry says 'shell' (background shells or tasks hold the pane)${hl:+; running under it: $hl}"; return
    fi
    # THE CALLER'S OWN TURN (SALA_IDLE_OWN_TURN=1, set by `retire --self` when the target is the session the command runs in): the registry's "busy" is then
    # the very turn that made this call, so it is not a reason. Only that: a dialog ("waiting"), a background shell, a child process and the rest still are, except
    # that the processes on this call's own way up to the claude (the Bash call itself) are not counted as children, and the scratch-folder check is left out
    # (the call's own tool output is what it would find). The settle time and the session's ready word describe an idle stretch and are not read for a turn.
    local own_turn=0; [ "${SALA_IDLE_OWN_TURN:-0}" = 1 ] && [ "$st" = busy ] && own_turn=1
    [ "$st" = "idle" ] || [ "$own_turn" = 1 ] || { echo "registry says '$st' (a turn or a dialog is running)"; return; }
    registry_field_r stamp "$1" statusUpdatedAt
    if [ "$own_turn" = 0 ]; then
        _stamp_age_r age "$stamp"
        [ "$age" -ge "$SALA_IDLE_SETTLE" ] || { echo "idle for only ${age}s (a just-queued turn may not have flipped the registry yet)"; return; }
        # the session said ready: its call, for shells and tasks. A running subagent is not its to cut: the in-session mod refuses the exit for it
        # (subagent_holders), so it is named here, the pane is held, and the retry that follows is not a loop that cannot end
        registry_field_r sid "$1" sessionId; [ -n "$sid" ] && ready_for "$sid" && { subagents_why "$1" "$sid"; return 0; }
    else registry_field_r sid "$1" sessionId; fi
    local kids; _children_r kids "$1"
    if [ -n "$kids" ]; then
        # 2.1.28x: "← for agents" parks the conversation into a background fork under the CLI's own daemon (a child
        # of this process, registry parkedJobId = the fork's uuid, the bridge id moves to the fork's row). It reads
        # as a busy child forever; name it, the operator has to return/close it from the pane
        local parked; registry_field_r parked "$1" parkedJobId; [ "$parked" = null ] && parked=""
        if [ -n "$parked" ]; then echo "conversation parked to a background fork ($parked) — the CLI daemon under this pane holds its bridge; open the pane's background view (← for agents) and return or end the fork"; return; fi
    fi
    # THE STOP HOOK'S RECORD (lib/hook.sh): for the idle stretch the registry is in now, the session's own list of what
    # its last turn left in flight — exact where the two guesses below are not: a long-lived child reads busy for ever (a pane
    # skipped by every recycle), a background job quiet for 2 min reads idle (its work cut at /exit). No record for this
    # stretch (busy_state 2: hook not registered, flip not stamped, a turn ended since without it) → the guesses, as before.
    # Neither sees a job started with `setsid nohup`: it has left claude's process tree and its task registry alike.
    # THE RESCUE (lib/revive.sh --rescue, SALA_RESCUE=1): the record is the Stop hook's copy of the CLI's task
    # registry, and that registry keeps a row for a shell stopped by hand or a subagent long gone (stale rows,
    # no child process, a session stuck on a dead lane). Under --rescue, and
    # only then, a record that lists work while NO child process runs under the claude is read as stale and passed over;
    # the live readings below (a child, a scratch file written in the last 2 min) still hold. A relaunch without the flag
    # trusts the record as before.
    if [ -n "$sid" ]; then   # as lists, never a bare call: a caller under `set -e` (tests/smoke.sh) must survive busy_state's 2
        hs=$(busy_state "$1" "$sid" "$stamp") && { if [ "${SALA_RESCUE:-0}" = 1 ] && [ -z "$(work_children "$1")" ]; then hs=""; else echo "$hs"; return 0; fi; } || case $? in 1) [ "$own_turn" = 1 ] || subagents_why "$1" "$sid"; return 0;; esac   # a record with nothing in flight lists no subagent
    fi
    if [ "$own_turn" = 1 ]; then kids=$(work_children "$1" | { grep -vxF -f <(_ancestor_pids) || :; } | tr '\n' ' ')   # the call's own way up is not work in flight
    else kids=$(work_children "$1" | tr '\n' ' '); fi   # a plugin's MCP server is not work in flight (work_children)
    if [ -n "$kids" ]; then hl=$(holders_inline "$1"); echo "a background task is running (child pids: ${kids% })${hl:+; running under it: $hl}"; return; fi
    if [ -n "$sid" ] && [ "$own_turn" = 0 ]; then
        while IFS= read -r d; do
            [ -d "$d" ] && [ -n "$(find "$d" -type f -mmin -2 -print -quit 2>/dev/null)" ] && { echo "a background agent or task wrote to $(basename "$d") in the last 2 min"; return 0; }
        done < <(session_scratch_dirs "$1" "$sid")
        subagents_why "$1" "$sid"   # a subagent that is quiet for longer than that (the transcript's own record, subagent_holders)
    fi
    return 0   # idle: the status is 0 on every path, so a caller under `set -e` may capture the reason
}
is_idle() {  # <claude-pid> → 0 idle · 1 busy · 2 unknown. Unknown is NEVER idle.
    local st stamp age sid d kids jp
    registry_field_r st "$1" status; [ -n "$st" ] || return 2
    if parked_job_pid_r jp "$1"; then is_idle "$jp"; return; fi   # a parked pane is idle when its job is
    [ "$st" = "idle" ] || return 1
    # registry "idle" = main turn not running; background Bash/Monitor/Agent work leaves it idle
    # while the session is mid-flight, and /exit would kill that work → the Stop hook's record, else three extra checks:
    registry_field_r stamp "$1" statusUpdatedAt
    _stamp_age_r age "$stamp"
    [ "$age" -ge "$SALA_IDLE_SETTLE" ] || return 1
    registry_field_r sid "$1" sessionId; [ -n "$sid" ] && ready_for "$sid" && { [ -z "$(subagent_holders "$1" "$sid")" ]; return; }
    _children_r kids "$1"   # (never a failing status: a caller under `set -e`, tests/smoke.sh, must survive "no children")
    if [ -n "$kids" ]; then local parked; registry_field_r parked "$1" parkedJobId; [ -n "$parked" ] && [ "$parked" != null ] && return 1; fi   # parked: as in is_idle_reason
    if [ -n "$sid" ]; then busy_state "$1" "$sid" "$stamp" >/dev/null && return 1 || case $? in 1) [ -z "$(subagent_holders "$1" "$sid")" ]; return;; esac; fi
    [ -z "$(work_children "$1")" ] || return 1   # a plugin's MCP server is not work in flight (work_children)
    if [ -n "$sid" ]; then
        while IFS= read -r d; do
            [ -d "$d" ] && [ -n "$(find "$d" -type f -mmin -2 -print -quit 2>/dev/null)" ] && return 1
        done < <(session_scratch_dirs "$1" "$sid")
        [ -z "$(subagent_holders "$1" "$sid")" ] || return 1
    fi
    return 0
}
# sidecar_uuid_for_session <tmux-session> → the conversation last bound to that session
sidecar_uuid_for_session() { local _u; [ -r "$SALA_SIDECAR" ] || return 1; _tsv_col_r _u "$SALA_SIDECAR" "$1" 2; printf '%s\n' "$_u"; }

# ── pane-map ledger ───────────────────────────────────────────────────────────
# THE MAP IS A LEDGER (after a reboot once brought back only some of the sessions: a resurrect save
# during the shutdown kept a few and became `last`, then the first post-boot `revive --save-map` rebuilt the map from what
# was alive and dropped the other rows for good). Only honored paths change it, and ABSENCE NEVER REMOVES A ROW: a
# crash, a force-quit, a dead claude or a missing tmux session leaves its row in place, so the session can be brought
# back (`sala restore`). Rows: tmux_session \t uuid \t name \t cwd — the 4th column is new, so a session
# can be recreated in its own directory; the first three keep their order, so every reader of the old 3-column map
# (sidecar_uuid_for_session, spawn --list, revive's ordered_panes and shell branch, watch, rename, retire) reads on. The
# file is $SALA_SIDECAR (the XDG state dir; see SALA_STATE_DIR above and ledger_migrate at the end of this file).
# The honored paths and their ops:
#   add     `spawn`, `unpark`, watch's re-add of the master row      adopt   `sala adopt NAME` (a session made by hand)
#   rename  `sala rename` (a row the map has; never adds one)          retire  `sala retire`, `sala close-shell` and `sala forget-row` — the only paths that drop a row
#   follow  the ONE change an observation may make: the live claude in a mapped session reports a different conversation
#           than the row (a /clear, a hand --resume); write_sidecar (revive --save-map) applies it from the live registry,
#           unless another row carries that conversation (refused: one conversation, one row)
# and only on the fleet's tmux server (see THE FLEET'S TMUX SERVER below).
# Every write goes through ledger_write: flock on the map's .lock (fd 6; 8 is the inbox lock, 9 the recycle lock), a temp
# file next to the map (same filesystem, so the mv is atomic, and no /tmp quota), a failed write aborts without touching
# the map, an empty result never replaces a non-empty map (only a retire of the last row may empty it), the previous map
# goes to map-history/ (kept as long as resurrect keeps its snapshots), and one line per change goes to the ledger log:
# time, op, session, old → new, caller. A write that changes nothing writes nothing.
SALA_LEDGER_LOG="${SALA_SIDECAR%.tsv}.log"
_dir "$SALA_SIDECAR" _SALA_STATE_PARENT; SALA_LEDGER_HISTORY="$_SALA_STATE_PARENT/map-history"
ledger_row() { local _r; [ -r "$SALA_SIDECAR" ] || return 0; _tsv_row_r _r "$SALA_SIDECAR" "$1"; [ -n "$_r" ] && printf '%s\n' "$_r"; return 0; }   # <session> → its row, or nothing
ledger_uuid_rows() { [ -n "${1:-}" ] && [ -r "$SALA_SIDECAR" ] || return 0; awk -F'\t' -v u="$1" -v s="${2:-}" '$2==u && $1!=s {print $1}' "$SALA_SIDECAR" | paste -sd, -; }   # <uuid> [but session] → the sessions whose row carries it, comma-separated
ledger_desc() { [ -n "$1" ] || { echo "—"; return; }; local s u n c; IFS=$'\t' read -r s u n c <<< "$1"; echo "$u (${n:-?}, ${c:-?})"; }   # <row> → "uuid (name, cwd)"
ledger_log() {  # <op> <session> <old → new> — one line per change
    local who; who="${SALA_LEDGER_CALLER:-$(lock_who 2>/dev/null)}"; [ -n "${sub:-}" ] && who="$who, sala $sub"
    _mkparent "$SALA_LEDGER_LOG"
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date -Is)" "$1" "$2" "$3" "$who" >> "$SALA_LEDGER_LOG" 2>/dev/null || true
}
# EXACT TMUX SESSION TARGETS: a session NAME is never handed to tmux as a plain `-t NAME`. tmux reads a plain target
# loosely: a name that is a number is a WINDOW INDEX of the caller's own session (a stray session `0` was read as the
# caller's window 0: `sala retire 0 --dry-run` named the caller's own pane, and a retire with the old --force would have ended it), a name
# can match a window NAME in the caller's session, and a name with no exact session prefix-matches another one (`work`
# → `work-a`). A leading `=` makes the match exact, but a window or pane target (list-panes, display, send-keys,
# capture-pane) reads a bare `=0` as a window again; only the session-qualified `=0:` is exact there. So a session-type
# target (has-session, kill-session, rename-session, attach) is `=NAME` and a window or pane type one is `=NAME:`
# (`=NAME:0` for its window 0). A target that is already a pane id (%N) or the caller's own $TMUX_PANE needs neither.
# tests/syntax.sh fails on a tmux call that targets a session variable bare; tests/tmux-exact.sh runs the cases.
# An EMPTY name prints a bare `=`, which tmux refuses: `=:` alone would read as the caller's own session.
tmux_sess_t() { printf '=%s' "$1"; }                                                    # <session> → `=session`
tmux_win_t() { if [ -n "${1:-}" ]; then printf '=%s:%s' "$1" "${2:-}"; else printf '='; fi; }   # <session> [window] → `=session:` (its active window and pane) or `=session:window`
# THE FLEET'S TMUX SERVER: a probe tmux server started WITH ~/.tmux.conf had tmux-continuum
# restore the fleet's layout into it, and the config's hooks (post-restore-all `sala revive`, post-save-all `sala revive
# --save-map`, session-created/closed/renamed `sala snapshot`) ran sala against that server: tmux gives a hook's job
# TMUX=<that server's socket>, so every tmux call sala made read the probe's panes, and many follows written into the
# shared map in seconds scrambled conversation ids across the fleet (one stayed wrong for hours). The map
# and the resurrect restore point belong to ONE server, the fleet's: the default socket, ${TMUX_TMPDIR:-/tmp}/tmux-<uid>/
# default, or SALA_TMUX_SOCKET (the config or the environment: the suites' private sockets, a nonstandard setup). revive
# and snapshot (lib/revive.sh, lib/snapshot.sh: the hooks' entry points, recycle included) leave quietly on any other
# server (fleet_only), and ledger_write refuses every map write there. The server is asked first (what sala's own tmux
# calls reach, even through a wrapper), then $TMUX; no server at all is the fleet's: plain tmux would start that one.
fleet_socket() { echo "${SALA_TMUX_SOCKET:-${TMUX_TMPDIR:-/tmp}/tmux-$EUID/default}"; }
tmux_socket() { local s; s=$(tmux display -p '#{socket_path}' 2>/dev/null) || s=""; [ -n "$s" ] || { s=${TMUX:-}; s=${s%%,*}; }; echo "$s"; }   # the server sala's tmux calls reach, or nothing
on_fleet_server() {  # → 0 when sala's tmux calls reach the fleet's server (or no server at all); the socket seen in FLEET_SOCKET_SEEN
    local f r; FLEET_SOCKET_SEEN=$(tmux_socket); [ -n "$FLEET_SOCKET_SEEN" ] || return 0; f=$(fleet_socket)
    [ "$FLEET_SOCKET_SEEN" = "$f" ] && return 0
    r=$(readlink -f "$f" 2>/dev/null) && [ -n "$r" ] && [ "$(readlink -f "$FLEET_SOCKET_SEEN" 2>/dev/null)" = "$r" ]   # /tmp → /private/tmp (macOS)
}
fleet_only() {  # <what> — an entry point's guard: on another server, one ledger-log line (and one on a terminal), exit 0
    on_fleet_server && return 0
    ledger_log "skipped($1)" - "not the fleet's tmux server: $FLEET_SOCKET_SEEN (the fleet's is $(fleet_socket))"
    [ -t 2 ] && echo "sala $1: not the fleet's tmux server ($FLEET_SOCKET_SEEN, the fleet's is $(fleet_socket)) — nothing done" >&2
    exit 0
}
ledger_write() {  # <add|adopt|rename|follow|retire> <session> [args…] → 0 written (or nothing to change) · 1 failed · 2 refused
    #   add|adopt SESSION UUID [NAME] [CWD]   rename OLD NEW [UUID] [CWD]   follow SESSION UUID [CWD]   retire SESSION
    case "${1:-}" in add|adopt|rename|follow|retire) ;; *) echo "ledger_write: unknown op '${1:-}'" >&2; return 1;; esac
    if ! on_fleet_server; then   # the map is the fleet server's (above): a write seen from another server is refused
        ledger_log "refused($1)" "${2:-}" "not the fleet's tmux server: $FLEET_SOCKET_SEEN (the fleet's is $(fleet_socket))"
        echo "pane map not written: this is not the fleet's tmux server ($FLEET_SOCKET_SEEN) — $1 of '${2:-}' refused" >&2; return 2
    fi
    _mkparent "$SALA_SIDECAR"
    command -v flock >/dev/null 2>&1 || { if ledger_frozen; then _ledger_frozen_gate "$@"; else _ledger_apply "$@"; fi; return; }   # macOS base system: unserialized, like the inbox holds
    ( flock -w 30 6 || { echo "pane map not written: its lock is held (another write hung?)" >&2; exit 1; }
      if ledger_frozen; then _ledger_frozen_gate "$@"; exit; fi   # 0: a follow, deferred · 2: refused
      _ledger_apply "$@" ) 6>>"$SALA_SIDECAR.lock"
}
# THE FREEZE: a recycle (the detached driver, before its sweep) and `sala reboot` (at the pause step)
# freeze the map — a copy of its rows next to it, the roster that run must bring back, plus the owner pid, boot id,
# reason and time. While the freeze stands every write is refused with a logged line, except a follow, which is
# deferred and applied at the unfreeze: the end of the recycle driver (after its self-worker), the reboot's boot half
# after its comparison (or the dry run's end, or a halt). The roster is what the end of a recycle sweep and the boot
# half compare tmux against (ledger_compare_restore). A stale freeze — its owner dead on this boot, a recycle's from an
# earlier boot, or older than SALA_FREEZE_MAX — is cleared by `sala watch`, with a report. spawn, rename, retire, unpark
# and adopt check the freeze up front (ledger_frozen_die), so nothing is left half done.
SALA_LEDGER_FREEZE="${SALA_SIDECAR%.tsv}.freeze"; SALA_LEDGER_FROZEN="${SALA_SIDECAR%.tsv}.frozen.tsv"; SALA_LEDGER_DEFERRED="${SALA_SIDECAR%.tsv}.deferred.tsv"
: "${SALA_FREEZE_MAX:=10800}"
ledger_frozen() { [ -s "$SALA_LEDGER_FREEZE" ]; }
ledger_freeze_field() { _kv_first "$SALA_LEDGER_FREEZE" "$1"; }
ledger_freeze_line() { ledger_frozen || { echo "not frozen"; return; }; echo "frozen for a $(ledger_freeze_field reason) since $(local_human "$(ledger_freeze_field time)") (pid $(ledger_freeze_field owner_pid), by $(ledger_freeze_field by))"; }
ledger_freeze_stale() {  # → 0 when the freeze file names an owner dead on this boot, a recycle's freeze from another boot, or one older than SALA_FREEZE_MAX
    ledger_frozen || return 1
    local pid bid t; pid=$(ledger_freeze_field owner_pid); bid=$(ledger_freeze_field boot_id); t=$(ledger_freeze_field time)
    if [ "$bid" = "$(boot_id)" ]; then [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null && return 0
    elif [ "$(ledger_freeze_field reason)" != reboot ]; then return 0; fi   # only a reboot's freeze is meant to cross a boot
    [ $(( $(date +%s) - ${t:-0} )) -ge "$SALA_FREEZE_MAX" ]
}
ledger_frozen_die() { ledger_frozen || return 0; die "the pane map is $(ledger_freeze_line) — $1 would change it; try again once that run is done (a freeze whose owner is gone is cleared by sala watch within minutes)"; }   # <verb>
_ledger_frozen_gate() {  # <op> <session> [args…] — a write while frozen, under the lock: a follow is deferred (0), anything else refused (2)
    if [ "$1" = follow ]; then
        printf '%s\t%s\t%s\n' "$2" "${3:-}" "${4:-}" >> "$SALA_LEDGER_DEFERRED" || { echo "pane map: could not defer the follow of '$2'" >&2; return 1; }
        ledger_log "deferred(follow)" "$2" "$(cut -f2 <<< "$(ledger_row "$2")") → ${3:-} (applied at the unfreeze)"; return 0
    fi
    ledger_log "refused($1)" "$2" "$(ledger_freeze_line)"; echo "pane map $(ledger_freeze_line) — $1 of '$2' refused" >&2; return 2
}
ledger_freeze() {  # <reason> <owner pid> → 0 frozen (roster written); 1 when a live freeze already holds
    local reason="$1" owner="$2" who; who="${SALA_LEDGER_CALLER:-$(lock_who 2>/dev/null)}"
    _mkparent "$SALA_SIDECAR"
    ( if command -v flock >/dev/null 2>&1; then flock -w 30 6 || { echo "pane map not frozen: its lock is held" >&2; exit 1; }; fi
      if ledger_frozen; then
          if ledger_freeze_stale; then _ledger_unfreeze_locked "stale, replaced by a new $reason freeze"
          else echo "pane map already $(ledger_freeze_line)" >&2; exit 1; fi
      fi
      { [ -r "$SALA_SIDECAR" ] && cat "$SALA_SIDECAR"; } > "$SALA_LEDGER_FROZEN" 2>/dev/null || { echo "pane map not frozen: cannot write the roster copy" >&2; exit 1; }
      printf 'owner_pid=%s\nboot_id=%s\nreason=%s\ntime=%s\nby=%s\n' "$owner" "$(boot_id)" "$reason" "$(date +%s)" "$who" > "$SALA_LEDGER_FREEZE.tmp" && mv -f "$SALA_LEDGER_FREEZE.tmp" "$SALA_LEDGER_FREEZE" || { rm -f "$SALA_LEDGER_FREEZE.tmp"; echo "pane map not frozen: cannot write the freeze file" >&2; exit 1; }
      ledger_log freeze - "open → $reason (pid $owner, $(wc -l < "$SALA_LEDGER_FROZEN" | tr -d ' ') rows frozen)"
    ) 6>>"$SALA_SIDECAR.lock"
}
ledger_unfreeze() {  # [why] → lifts the freeze and applies the follows deferred under it; nothing to do when not frozen
    ( if command -v flock >/dev/null 2>&1; then flock -w 30 6 || { echo "pane map not unfrozen: its lock is held" >&2; exit 1; }; fi
      _ledger_unfreeze_locked "${1:-}" ) 6>>"$SALA_SIDECAR.lock"
}
_ledger_unfreeze_locked() {  # <why> — under the lock
    local why="$1" fl n=0 sess uuid cwd
    [ -e "$SALA_LEDGER_FREEZE" ] || [ -e "$SALA_LEDGER_DEFERRED" ] || return 0
    fl=$(ledger_freeze_line)
    rm -f "$SALA_LEDGER_FREEZE"; [ -e "$SALA_LEDGER_FROZEN" ] && mv -f "$SALA_LEDGER_FROZEN" "$SALA_LEDGER_FROZEN.last"
    if [ -s "$SALA_LEDGER_DEFERRED" ]; then   # the last deferred follow per session wins
        while IFS=$'\t' read -r sess uuid cwd; do
            [ -n "$sess" ] && [ -n "$uuid" ] || continue
            _ledger_apply follow "$sess" "$uuid" "$cwd" && n=$((n+1))
        done < <(awk -F'\t' '{last[$1]=$0} END {for (s in last) print last[s]}' "$SALA_LEDGER_DEFERRED")
    fi
    rm -f "$SALA_LEDGER_DEFERRED"
    ledger_log unfreeze - "$fl → open${why:+ ($why)}; $n deferred follow(s) applied"
    return 0
}
# COMPARE AND RESTORE (a missing session is recreated on its own, then reported). A row whose tmux session does not exist is
# recreated: the session detached at a shell in the row's cwd, then `revive --only NAME` resumes the row's conversation
# by uuid through revive's shell-pane branch (the dedupe guard, the effort re-pass, the inbox hold). A row whose session
# exists but whose claude is not back is revive's existing business. The dedupe guard holds here too: a conversation
# live anywhere is never resumed again — such a row is left alone and said so. `sala restore` is the hand-run form; the
# end of a recycle sweep and the reboot's boot half run ledger_compare_restore over the frozen roster on their own.
ledger_missing() {  # → the map's rows whose tmux session does not exist (the Remote Control server's never counts)
    [ -r "$SALA_SIDECAR" ] || return 0
    local line s
    while IFS= read -r line; do
        s=${line%%$'\t'*}; [ -n "$s" ] && [ "$s" != "$SALA_RC_SESSION" ] || continue
        no_relaunch "$s" && continue   # managed outside sala: never recreated, so never missing (no_relaunch)
        tmux has-session -t "=$s" 2>/dev/null || printf '%s\n' "$line"
    done < "$SALA_SIDECAR"
}
restore_session() {  # <session> [row] → 0 recreated and resumed · 3 left alone (its conversation is live elsewhere) · 1 failed; one line on stdout
    local sess="$1" row="${2:-}" uuid name cwd live out why note="" sess_re
    no_relaunch "$sess" && { echo "$(no_relaunch_line "$sess"); sala does not recreate it"; return 1; }
    [ -n "$row" ] || row=$(ledger_row "$sess")
    [ -n "$row" ] || { echo "$sess: not in the pane map, nothing to recreate it from (salamander spawn makes a new session, adopt registers a live one)"; return 1; }
    IFS=$'\t' read -r _ uuid name cwd <<< "$row"
    [ -n "$uuid" ] || { echo "$sess: its pane-map row has no conversation id"; return 1; }
    tmux has-session -t "=$sess" 2>/dev/null && { echo "$sess: its tmux session exists — revive brings its claude back (salamander revive --only $sess)"; return 1; }
    if live=$(live_pane_for_uuid "$uuid"); then echo "$sess: left alone — its conversation is live already (pid ${live%% *} in ${live#* }); a conversation is never resumed twice"; return 3; fi
    [ -n "$cwd" ] && [ -d "$cwd" ] || { note=" (its directory '${cwd:-?}' is gone, so in $HOME)"; cwd="$HOME"; }
    tmux new-session -d -s "$sess" -c "$cwd" || { echo "$sess: tmux new-session failed"; return 1; }
    # not the recycle's own sweep (SALA_RECYCLE would re-post and stop retry workers); the guard was this caller's to pass
    out=$(env -u SALA_RECYCLE -u SALA_SKIP_PANE "$SALA_BIN" revive --only "$sess" --not-master 2>&1)
    re_escape_r sess_re "$sess"; printf '%s\n' "$out" | grep -E "^ *$sess_re:0: |^✗|^⚠" | sed 's/^ */      /'
    if printf '%s\n' "$out" | grep -q "^ *$sess:0: resumed $uuid"; then echo "$sess: back in $cwd$note, on its conversation"; return 0; fi
    why=$(printf '%s\n' "$out" | grep -F "$sess:0: " | tail -1 | sed "s/^ *$sess:0: //"); [ -n "$why" ] || why=$(printf '%s\n' "$out" | grep . | tail -1)
    echo "$sess: recreated in $cwd$note, but not resumed — ${why:-no verdict from revive}"; return 1
}
ledger_compare_restore() {  # <Recycle|Reboot> [roster] — the frozen roster against tmux: every session of it that is gone is recreated; one post
    local what="$1" roster="${2:-$SALA_LEDGER_FROZEN}" line s rc out n back=() left=() failed=() log
    case "$what" in Reboot) log="~/.claude/salamander-reboot.log";; *) log="~/.claude/salamander-revive.log";; esac
    [ -s "$roster" ] || { echo "$what: no frozen roster to compare against — nothing recreated"; return 0; }
    while IFS= read -r line; do
        s=${line%%$'\t'*}; [ -n "$s" ] && [ "$s" != "$SALA_RC_SESSION" ] || continue
        tmux has-session -t "=$s" 2>/dev/null && continue
        no_relaunch "$s" && { echo "  $(no_relaunch_line "$s"); not recreated, not counted"; continue; }
        out=$(restore_session "$s" "$line"); rc=$?
        printf '%s\n' "$out" | sed 's/^/  /'; out=$(printf '%s\n' "$out" | tail -1)
        case "$rc" in 0) back+=("$out");; 3) left+=("$out");; *) failed+=("$out");; esac
    done < "$roster"
    n=$(( ${#back[@]} + ${#left[@]} + ${#failed[@]} ))
    [ "$n" -gt 0 ] || { echo "$what: every session of the frozen roster ($(grep -c . "$roster")) exists — nothing to recreate"; return 0; }
    echo "$what: $n of the roster's sessions were gone — ${#back[@]} recreated, ${#left[@]} left alone, ${#failed[@]} could not be"
    if [ ${#failed[@]} -gt 0 ]; then
        sala_post "🚨 *$what: ${#failed[@]} of $n missing session$([ "$n" -gt 1 ] && echo s) could not be recreated*" "${failed[@]}" ${left[@]+"${left[@]}"} ${back[@]+"${back[@]}"} "Details: $log"
    else
        sala_post "✅ *$what: ${#back[@]} session$([ ${#back[@]} -ne 1 ] && echo s) recreated*" ${back[@]+"${back[@]}"} ${left[@]+"${left[@]}"}
    fi
    return 0
}
_ledger_apply() {  # the write itself; only ledger_write calls it (under the lock)
    local op="$1" sess="$2"; shift 2
    local f="$SALA_SIDECAR" tmp old="" from new="" note="" wok=1 uuid name cwd to dup keep ts hist
    [ -e "$f" ] || >> "$f" || { echo "pane map not written: cannot create $f" >&2; return 1; }
    tmp=$(mktemp "$f.XXXXXX") || { echo "pane map not written: cannot create a temp file next to $f" >&2; return 1; }
    old=$(ledger_row "$sess"); from=$(ledger_desc "$old")
    case "$op" in
        add|adopt)
            uuid="${1:-}"; name="${2:-$sess}"; cwd="${3:-$HOME}"
            [ -n "$uuid" ] || { rm -f "$tmp"; echo "pane map not written: $op of '$sess' without a conversation id" >&2; return 1; }
            dup=$(awk -F'\t' -v s="$sess" -v u="$uuid" '$1!=s && $2==u {print $1}' "$f" | paste -sd, -)
            [ -n "$dup" ] && note=" (dropped the row of $dup, which carried the same conversation)"
            { awk -F'\t' -v s="$sess" -v u="$uuid" '$1!=s && $2!=u' "$f" && printf '%s\t%s\t%s\t%s\n' "$sess" "$uuid" "$name" "$cwd"; } > "$tmp" || wok=0
            new="$uuid ($name, $cwd)" ;;
        rename)
            to="${1:-}"; uuid="${2:-}"; cwd="${3:-$HOME}"
            [ -n "$to" ] || { rm -f "$tmp"; echo "pane map not written: rename of '$sess' to nothing" >&2; return 1; }
            if [ -n "$old" ]; then
                from="$sess"
                awk -F'\t' -v OFS='\t' -v s="$sess" -v n="$to" -v u="$uuid" '$1==s {$1=n; $3=n; if ($2=="" && u!="") $2=u} {print}' "$f" > "$tmp" || wok=0
            elif [ -n "$uuid" ] && old=$(awk -F'\t' -v u="$uuid" '$2==u {print; exit}' "$f") && [ -n "$old" ]; then
                from=${old%%$'\t'*}; note=" (the conversation's row was under '$from', not '$sess')"
                awk -F'\t' -v OFS='\t' -v u="$uuid" -v n="$to" '$2==u {$1=n; $3=n} {print}' "$f" > "$tmp" || wok=0
            elif [ -n "$uuid" ]; then
                # NOT IN THE MAP (`sala rename` of two hand-made throwaway sessions added a row each here, and a
                # later recycle brought one of them back as a fleet session). A rename moves a row; it never makes one: adopt is the honored path in. lib/rename.sh
                # refuses this up front, before anything is typed; this is the ledger's own guard.
                rm -f "$tmp"; ledger_log "refused(rename)" "$sess" "→ $to: neither '$sess' nor conversation $uuid is in the pane map (sala adopt first)"
                echo "pane map not written: '$sess' is not in the pane map — rename of '$sess' refused (sala adopt $sess first)" >&2; return 2
            else rm -f "$tmp"; return 0; fi
            new="$to" ;;
        follow)
            uuid="${1:-}"; cwd="${2:-}"
            [ -n "$old" ] && [ -n "$uuid" ] || { rm -f "$tmp"; return 0; }
            # ONE CONVERSATION, ONE ROW (a probe server's revive once followed many rows onto each
            # other's conversations, and the run that reversed it left one row on another session's; add and
            # adopt drop the other row, follow never looked). A follow onto a conversation another row carries is refused
            # and logged (once per session and target, so a save-map every few minutes does not repeat it); the deferred
            # follows of an unfreeze come through here too. The trade-off: two rows that really swap conversations in one
            # pass (each pane --resumed into the other's) are applied one by one, so both follows are refused and both
            # rows keep their old conversation until one of them moves on (a /clear, a relaunch) or adopt sets it. A map
            # that holds one conversation twice is worse: retire, restore and revive would act on the wrong session.
            dup=$(ledger_uuid_rows "$uuid" "$sess")
            if [ -n "$dup" ]; then
                rm -f "$tmp"; to="$(cut -f2 <<< "$old") → $uuid: that conversation is already the row of $dup"
                [ "$(tail -n 300 "$SALA_LEDGER_LOG" 2>/dev/null | awk -F'\t' -v s="$sess" '$2=="refused(follow)" && $3==s {d=$4} END {print d}')" = "$to" ] || ledger_log "refused(follow)" "$sess" "$to"
                echo "pane map not written: follow of '$sess' refused — conversation $uuid is already the row of $dup" >&2; return 2
            fi
            awk -F'\t' -v OFS='\t' -v s="$sess" -v u="$uuid" -v c="$cwd" '$1==s {$2=u; if (c!="") $4=c} {print}' "$f" > "$tmp" || wok=0
            from=$(cut -f2 <<< "$old"); new="$uuid"; [ -n "$cwd" ] && [ "$cwd" != "$(cut -f4 <<< "$old")" ] && note=" (cwd $(cut -f4 <<< "$old") → $cwd)" ;;
        retire)
            [ -n "$old" ] || { rm -f "$tmp"; return 0; }
            awk -F'\t' -v s="$sess" '$1!=s' "$f" > "$tmp" || wok=0
            new="—" ;;
    esac
    LC_ALL=C sort -o "$tmp" "$tmp" || wok=0
    if [ "$wok" = 0 ]; then rm -f "$tmp"; echo "pane map not written: a write failed (disk full or over quota?) — the map is kept as it was" >&2; return 1; fi
    if [ ! -s "$tmp" ] && [ -s "$f" ] && [ "$op" != retire ]; then rm -f "$tmp"; echo "pane map not written: the result came out empty — the map is kept as it was" >&2; return 1; fi
    if cmp -s "$tmp" "$f"; then rm -f "$tmp"; return 0; fi
    # HISTORY: the previous map, rotated on change, for the window tmux-resurrect keeps its snapshots (default 30 d), so
    # any layout resurrect can restore has its map (`revive --map-history` reads them back)
    keep=$(tmux show-option -gqv @resurrect-delete-backup-after 2>/dev/null); _ledger_history_copy "${keep:-30}"
    mv -f "$tmp" "$f" || { rm -f "$tmp"; echo "pane map not written: could not replace $f" >&2; return 1; }
    ledger_log "$op" "$sess" "$from → $new$note"
    # THE SESSION REGISTRY (phase 1): dual-written only now that the map is, and never allowed to fail this write (sessions_dual_write)
    case "$op" in
        add|adopt) sessions_dual_write "$op" "$sess" "$uuid" "$name" "$cwd" ;;
        rename) sessions_dual_write rename "$from" "$to" "$uuid" "$to" "$cwd" ;;
        retire) sessions_dual_write retire "$sess" "$(cut -f3 <<< "$old")" ;;
    esac
    return 0
}
_ledger_history_copy() {  # the current map → map-history/pane-map.<ts>.tsv, before it is replaced; [keep-days] prunes older copies
    local keep="${1:-}" ts hist
    [ -s "$SALA_SIDECAR" ] || return 0
    mkdir -p "$SALA_LEDGER_HISTORY" 2>/dev/null; ts=$(date +%Y%m%dT%H%M%S); hist="$SALA_LEDGER_HISTORY/pane-map.$ts.tsv"
    [ -e "$hist" ] && hist="$SALA_LEDGER_HISTORY/pane-map.$ts.${BASHPID:-$$}.tsv"
    cp -p "$SALA_SIDECAR" "$hist" 2>/dev/null || true
    [ -n "$keep" ] && find "$SALA_LEDGER_HISTORY" -name '*pane-map.*.tsv' -type f -mtime "+$keep" -delete 2>/dev/null
    return 0
}
# THE SESSION REGISTRY (phase 1; docs/session-registry.md). A session gets an id of its own (uuid4) that
# outlives a rename and a fresh conversation: $SALA_STATE_DIR/sessions.json, one row per session, retired rows kept for
# good. Phase 1 only RECORDS it, beside the old tables; nothing reads it, and the pane map stays the authority (the
# registry is dual-written after the pane-map write has succeeded: add/adopt mint or reuse a row by name, rename edits the
# name and keeps the old one as an alias, retire marks the row retired, follow changes nothing; lane_write, model_write and
# `spawn --project/--role` copy their field in). THE RULE FOR EVERY CALLER: a registry failure NEVER fails or blocks the
# write it follows. It is one line in sessions.log (or the line of sessions_note below), and `sala sessions --check` finds
# and repairs the drift (a kill between the two writes). Its file operations are lib/sessions.py (standard library only).
# THE LOCK: the registry shares the pane map's lock (fd 6, $SALA_SIDECAR.lock). ledger_write already holds it when it calls
# in; lane_write/model_write call after their own lock (fd 3) is released and take fd 6 for the field copy alone, with a
# wait of 10 s, never both at once, so no lock order exists to invert. SALA_SESSIONS=off|write|read: off writes nothing
# (revert = off or delete the file); write is the default; read is reserved for a later phase and acts as write here.
: "${SALA_SESSIONS:=write}"
SALA_SESSIONS_FILE="$_SALA_STATE_PARENT/sessions.json"; SALA_SESSIONS_LOG="$_SALA_STATE_PARENT/sessions.log"
SALA_SESSIONS_HISTORY="$_SALA_STATE_PARENT/sessions-history"
if [ -n "${SALA_ROOT:-}" ]; then SALA_SESSIONS_PY="$SALA_ROOT/lib/sessions.py"; else SALA_SESSIONS_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sessions.py"; fi
: "${SALA_SESSIONS_KEEP_DAYS:=30}"
sessions_on() { [ "${SALA_SESSIONS:-write}" != off ]; }
sessions_machine() {  # → this box's letter in the fleet store (the heartbeat's), else its short hostname
    local h l="${SALA_HEARTBEAT_LETTER:-}" f="${SALA_FLEET_NAMES:-}"
    if [ -z "$l" ] && [ -n "$f" ] && [ -r "${f/#\~/$HOME}" ]; then   # (the hostname, the tr and the awk are the shell's own)
        h=${_SALA_HN,,}; local ln a r r2
        { while IFS= read -r ln || [ -n "$ln" ]; do
              [[ $ln == \#* ]] && continue
              a=${ln%%$'\t'*}; [ "${a,,}" = "$h" ] || continue
              r=${ln#*$'\t'}; l=""
              if [ "$r" != "$ln" ]; then r2=${r#*$'\t'}; [ "$r2" = "$r" ] || l=${r2%%$'\t'*}; fi
              break
          done < "${f/#\~/$HOME}"; } 2>/dev/null
    fi
    [ -n "$l" ] || { l=${_SALA_HN,,}; l=${l%%.*}; }
    echo "${l:-unknown}"
}
sessions_note() {  # <what> — a registry failure outside python: one line in sessions.log (the pane map's write is never touched)
    _mkparent "$SALA_SESSIONS_LOG"
    printf '%s\terror\t-\t-\t%s\t%s\n' "$(date -Is)" "$1" "${SALA_LEDGER_CALLER:-$(lock_who 2>/dev/null)}" >> "$SALA_SESSIONS_LOG" 2>/dev/null || true
}
sessions_py() {  # <command> [args…] → sessions.py's exit status; stdout and stderr pass through. The caller holds the lock where it writes.
    command -v python3 >/dev/null 2>&1 || { echo "sessions registry: python3 is not installed" >&2; return 1; }
    local t=(); command -v timeout >/dev/null 2>&1 && t=(timeout 20)
    ${t[@]+"${t[@]}"} python3 "$SALA_SESSIONS_PY" --file "$SALA_SESSIONS_FILE" --log "$SALA_SESSIONS_LOG" --history "$SALA_SESSIONS_HISTORY" \
        --keep "$SALA_SESSIONS_KEEP_DAYS" --caller "${SALA_LEDGER_CALLER:-$(lock_who 2>/dev/null)}" --machine "$(sessions_machine)" "$@"
}
sessions_dual_write() {  # <add|adopt|rename|retire> args… — from _ledger_apply, under the map's lock, after its mv; ALWAYS returns 0
    sessions_on || return 0
    local out op="$1" lane="" mr="" model="" effort="" n=""
    case "$op" in add|adopt) n="${2:-}";; rename) n="${3:-}";; esac
    if [ -n "$n" ]; then   # the tables' values for a row that has to be minted
        lane=$(lane_row "$n" 2>/dev/null); mr=$(model_row "$n" 2>/dev/null)
        if [ -n "$mr" ]; then model=${mr%%$'\t'*}; effort=${mr#*$'\t'}; [ "$effort" = "-" ] && effort=""; fi
    fi
    out=$(sessions_py dual "$@" ${lane:+--lane "$lane"} ${model:+--model "$model"} ${effort:+--effort "$effort"} 2>&1) \
        || sessions_note "$op ${2:-} failed: $(printf '%s' "$out" | tr '\n\t' '  ' | cut -c1-300)"
    return 0
}
sessions_set() {  # <session> key=value… — copy fields into the session's live row (lane_write, model_write, spawn); ALWAYS returns 0
    sessions_on || return 0
    local sess="$1" out
    out=$( ( if command -v flock >/dev/null 2>&1; then flock -w 10 6 || { echo "the pane map's lock is held"; exit 1; }; fi
             row=$(ledger_row "$sess"); mint=()
             if [ -n "$row" ]; then IFS=$'\t' read -r s u n c <<< "$row"; mint=(--mint "$u,${n:-$s},$c,$s"); fi
             sessions_py set "$@" ${mint[@]+"${mint[@]}"} ) 6>>"$SALA_SIDECAR.lock" 2>&1 ) \
        || sessions_note "set $* failed: $(printf '%s' "$out" | tr '\n\t' '  ' | cut -c1-300)"
    return 0
}
# A THROWAWAY'S SPAWNER (the session that started a throwaway may end it with no
# words): `sala spawn` run raw by a Claude session, with no --project, --role or --side, makes a throwaway, and the registry row records who
# started it (spawned_by, lib/sessions.py). The caller's identity is the tmux session whose pane holds this call by PROCESS ANCESTRY
# (ancestry_session below, with a Claude Code process whose exe is a real install's, not a process that merely wears the name), never TMUX_PANE or --from, which a caller can set to anything; a spawn from a plain shell, a detached process, a
# human's pane or the queue's runner records none (the row is then an untagged-style row without a spawner: see the throwaway tag, which any
# bare spawn writes whoever runs it, and which lets any live session retire the row with no words; lib/op.sh).
claude_install_roots() {  # → the folders a real Claude Code binary lives in (stdout, one per line): <account home>/.local/share/claude/versions
    # The account's home is the passwd entry's, not $HOME, which a caller can set. Only when $HOME is NOT the account's home (a test's
    # temporary HOME, never a fleet pane) is the HOME's own folder trusted as well, so a suite installs its fake claude there; production
    # runs with HOME = the account's home and trusts the one folder.
    local ah=""
    command -v getent >/dev/null 2>&1 && ah=$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)
    [ -n "$ah" ] || ah=$HOME
    printf '%s\n' "$ah/.local/share/claude/versions"
    [ "$HOME" = "$ah" ] || printf '%s\n' "$HOME/.local/share/claude/versions"
}
proc_tree() {  # <pid> → that pid and every process below it, one pid per line (stdout)
    proc_table | awk -v root="$1" '{ kid[$2] = kid[$2] " " $1 }
        END { n = 1; q[1] = root; for (i = 1; i <= n; i++) { print q[i]; m = split(kid[q[i]], c, " "); for (j = 1; j <= m; j++) q[++n] = c[j] } }'
}
claude_exe_trusted() {  # <pid> → 0 when /proc/<pid>/exe is a file inside a Claude Code install folder (claude_install_roots)
    # The name of a process (comm) is whatever its launcher called it, so `ln -s /bin/bash /tmp/x/claude` makes a "claude" out of a shell.
    # The binary the process runs is what counts: its /proc exe, resolved, a file under …/claude/versions/ in the account's own home
    # (a binary replaced by an update reads "<path> (deleted)": still the install). Anything that cannot be read is not trusted.
    local e r
    e=$(readlink "/proc/$1/exe" 2>/dev/null) || return 1
    e=${e% (deleted)}
    while read -r r; do
        [ -n "$r" ] && case $e in "$r"/*) return 0 ;; esac
    done < <(claude_install_roots)
    return 1
}
ancestry_session() {  # → the tmux session name of the pane whose process tree holds this call, with a claude process on the way up (stdout); 1 otherwise
    # The walk is guard.py's session_of_pid: this shell's parents up /proc/<pid>/stat (field 4) until one is a pane's process in
    # `tmux list-panes -a -F '#{pane_pid} #{session_name}'`. A claude must be on the walk at or below that pane process (a pane that
    # exec'd claude counts), so a human's shell in a pane is not a Claude session. "A claude" is a process named claude (comm) whose
    # executable (/proc exe) is a Claude Code install (claude_exe_trusted), never the name alone: a symlink named claude to a shell is not
    # one. A call with no pane above it (a plain shell, a double-forked or setsid job, which init or a user manager adopts) is nobody's,
    # and a tmux server other than the fleet's is not asked.
    local panes p c np _a _b _c pp sn seen=0 d=0
    on_fleet_server || return 1
    panes=$(tmux list-panes -a -F '#{pane_pid} #{session_name}' 2>/dev/null) || return 1
    [ -n "$panes" ] || return 1
    p=$$
    while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null && [ "$d" -lt 4096 ]; do
        c=""; { read -r c < "/proc/$p/comm"; } 2>/dev/null || :; [ "$c" = claude ] && claude_exe_trusted "$p" && seen=1
        while read -r pp sn; do
            if [ "$pp" = "$p" ]; then [ "$seen" = 1 ] && [ -n "$sn" ] && { printf '%s\n' "$sn"; return 0; }; return 1; fi
        done <<< "$panes"
        np=""; { read -r _a _b _c np _ < "/proc/$p/stat"; } 2>/dev/null || :; p=$np
        d=$((d + 1))
    done
    return 1
}
proc_env_val() {  # <pid> <VAR> → the value of VAR in /proc/<pid>/environ (stdout), 1 when unset or unreadable
    local kv; { while IFS= read -r -d '' kv; do case $kv in "$2="*) printf '%s\n' "${kv#*=}"; return 0 ;; esac; done < "/proc/$1/environ"; } 2>/dev/null
    return 1
}
proc_gone() {  # <pid> → 0 when the process no longer exists or is a zombie (its /proc/<pid>/environ reads empty, or not at all): a read of it proves nothing
    local st; { st=$(<"/proc/$1/stat"); } 2>/dev/null || return 0
    st=${st##*) }; [ "${st%% *}" = Z ] || [ "${st%% *}" = X ]
}
spawn_caller() {  # → the tmux session name of the Claude session making this call (stdout); nothing otherwise
    ancestry_session 2>/dev/null || :
}
# PHASE 2: an explicit signal replaces the noisy `follow`. spawn mints the row's id BEFORE the pane's claude starts and
# gives it to the pane as SALA_SESSION_ID (sessions_prepare); the SessionStart hook (`salamander hook session-start`) and unpark
# append a fresh conversation to the row (sessions_record). Same rules as above: SALA_SESSIONS=off does nothing, the fd-6 lock is
# the pane map's (10 s), and a failure is one line in sessions.log: prepare, abandon and record_soft ALWAYS return 0.
sessions_prepare() {  # <name> <pane> <cwd> → the live row's id on stdout (made now, without a conversation, if there is none); nothing when off or failed
    sessions_on || return 0
    local name="$1" pane="$2" cwd="$3" out lane mr model="" effort=""
    _mkparent "$SALA_SIDECAR"   # the lock file lives beside the pane map: on a box that has never written one, nothing made the directory yet
    lane=$(lane_row "$name" 2>/dev/null); mr=$(model_row "$name" 2>/dev/null)
    if [ -n "$mr" ]; then model=${mr%%$'\t'*}; effort=${mr#*$'\t'}; [ "$effort" = "-" ] && effort=""; fi
    out=$( ( if command -v flock >/dev/null 2>&1; then flock -w 10 6 || { echo "the pane map's lock is held"; exit 1; }; fi
             sessions_py prepare "$name" "$pane" "$cwd" ${lane:+--lane "$lane"} ${model:+--model "$model"} ${effort:+--effort "$effort"} ) 6>>"$SALA_SIDECAR.lock" 2>&1 ) \
        || { sessions_note "prepare $name failed: $(printf '%s' "$out" | tr '\n\t' '  ' | cut -c1-300)"; return 0; }
    case "$out" in [0-9a-f]???????-????-????-????-????????????) printf '%s\n' "$out" ;; *) sessions_note "prepare $name: unexpected output: $(printf '%s' "$out" | tr '\n\t' '  ' | cut -c1-200)" ;; esac
    return 0
}
sessions_abandon() {  # <id> — spawn failed before its claude was up: the row sessions_prepare made goes if it never had a conversation
    sessions_on || return 0
    local out
    out=$( ( if command -v flock >/dev/null 2>&1; then flock -w 10 6 || { echo "the pane map's lock is held"; exit 1; }; fi
             sessions_py abandon "$1" ) 6>>"$SALA_SIDECAR.lock" 2>&1 ) \
        || sessions_note "abandon $1 failed: $(printf '%s' "$out" | tr '\n\t' '  ' | cut -c1-300)"
    return 0
}
sessions_record() {  # <id|name> <claude session id> <clear|resume|start> [machine] — append a conversation to the row (a repeat is a no-op); sessions_py's status
    sessions_on || return 0
    ( if command -v flock >/dev/null 2>&1; then flock -w 10 6 || { echo "the pane map's lock is held (another write hung?) - nothing recorded" >&2; exit 1; }; fi
      sessions_py record "$1" --transcript "$2" --why "$3" ${4:+--tmachine "$4"} ) 6>>"$SALA_SIDECAR.lock"
}
sessions_tag() {  # <id|name> [--project P] [--role R] [--project-key P] [--dry-run] | --auto [<id|name>] [--dry-run] — fill project/role of a live row; sessions_py's status. A dry run only reads: no lock
    local ra=(); case " $* " in *" --auto "*) ra=(--record "$SALA_PROJECT_RECORD" --record-max-age "$SALA_PROJECT_RECORD_MAX_AGE");; esac   # --auto: the roles come from stackshot's project record
    case " $* " in *" --dry-run "*) sessions_py tag "$@" ${ra[@]+"${ra[@]}"}; return $? ;; esac
    ( if command -v flock >/dev/null 2>&1; then flock -w 10 6 || { echo "the pane map's lock is held (another write hung?) - nothing written" >&2; exit 1; }; fi
      sessions_py tag "$@" ${ra[@]+"${ra[@]}"} ) 6>>"$SALA_SIDECAR.lock"
}
# sessions_fill_roles: every live row with no role gets its project and role from stackshot's project record (the agents map; lib/sessions.py
# `tag --auto`), so a session that no `spawn --project --role` made (the one-time import, an adopted pane, a bare spawn of a listed name)
# still counts for what reads roles (the back agents' lane rule, the published registry). A role already on a row is never touched. The
# watch runs it every tick. A record that cannot answer (rc 4: missing, stale, unreadable) writes nothing and says nothing; any other
# failure is one line in sessions.log. ALWAYS returns 0: a tick never stops on it.
sessions_fill_roles() {
    sessions_on || return 0
    [ -r "$SALA_SESSIONS_FILE" ] && [ -r "$SALA_PROJECT_RECORD" ] || return 0
    local out rc=0
    out=$(sessions_tag --auto 2>&1) || rc=$?
    case "$rc" in 0|4) ;; *) sessions_note "tag --auto failed (exit $rc): $(printf '%s' "$out" | tr '\n\t' '  ' | cut -c1-300)";; esac
    return 0
}
sessions_record_soft() {  # sessions_record for a caller that must not be disturbed (unpark): its output captured, a failure one line in sessions.log, ALWAYS 0
    local out
    out=$(sessions_record "$@" 2>&1) || sessions_note "record $1 failed: $(printf '%s' "$out" | tr '\n\t' '  ' | cut -c1-300)"
    return 0
}
# THE MOVE (convention: a tool's own state lives under XDG_STATE_HOME, and the map is sala's, not
# tmux-resurrect's): until today the map was $SALA_RESURRECT_DIR/claude-pane-map.tsv, with three columns. The end of this
# file calls ledger_migrate, so the first `sala` after the change does it once: the file (its log and map-history/ with
# it) moves to the state dir and a symlink stays at the old path, so tmux-resurrect-era tooling still finds it; then every
# row without a cwd gets one — the live registry's for a conversation that is live right now (its process's cwd when the
# registry row has none), else $HOME. Cheap once done (a stat and one awk), and it never calls tmux: callers may still be
# setting theirs up when they source this file.
ledger_migrate() {
    local old="$SALA_SIDECAR_OLD" new="$SALA_SIDECAR" oldhist="$SALA_RESURRECT_DIR/map-history" hist=""
    if [ "$old" != "$new" ] && [ ! -e "$new" ] && [ -f "$old" ] && [ ! -L "$old" ]; then
        _mkparent "$new" && mv "$old" "$new" 2>/dev/null || { echo "⚠ the pane map could not be moved to $new — it stays at $old" >&2; return 0; }
        ln -s "$new" "$old" 2>/dev/null || echo "⚠ the pane map moved to $new, but no symlink could be left at $old" >&2
        [ -f "${old%.tsv}.log" ] && [ ! -e "$SALA_LEDGER_LOG" ] && mv "${old%.tsv}.log" "$SALA_LEDGER_LOG" 2>/dev/null
        if [ -d "$oldhist" ] && [ ! -L "$oldhist" ] && [ ! -e "$SALA_LEDGER_HISTORY" ]; then
            mv "$oldhist" "$SALA_LEDGER_HISTORY" 2>/dev/null && hist=", map-history/ with it"
        fi
        ledger_log migrate - "$old → $new ($(grep -c . "$new") rows, a symlink left at the old path$hist)"
    fi
    [ -s "$new" ] && _ledger_has_nocwd "$new" || return 0
    if command -v flock >/dev/null 2>&1; then ( flock -w 30 6 || exit 0; _ledger_fill_cwd ) 6>>"$new.lock"
    else _ledger_fill_cwd; fi
    return 0
}
_ledger_has_nocwd() {  # <map> → 0 when the first row with fewer than 4 columns or an empty 4th is not a blank line (awk -F'\t' 'NF<4 || $4=="" {print; exit}', in the shell)
    local l t f
    { while IFS= read -r l || [ -n "$l" ]; do
          t=${l//[^$'\t']/}
          if [ "${#t}" -lt 3 ]; then [ -n "$l" ]; return; fi
          f=${l#*$'\t'*$'\t'*$'\t'}; f=${f%%$'\t'*}
          if [ -z "$f" ]; then [ -n "$l" ]; return; fi
      done < "$1"; } 2>/dev/null
    return 1
}
_ledger_fill_cwd() {  # under the lock: every row without a cwd gets one (see ledger_migrate)
    local f="$SALA_SIDECAR" tmp counts
    tmp=$(mktemp "$f.XXXXXX") || return 0
    counts=$(python3 - "$f" "$SALA_REG_DIR" "$HOME" 2>&1 >"$tmp" <<'PY'
import json, os, sys
f, reg, home = sys.argv[1:4]
live = {}   # sessionId → cwd, for every claude that is alive: the registry's cwd, else the process's (Linux /proc)
for e in (os.listdir(reg) if os.path.isdir(reg) else []):
    if not e.endswith('.json') or not e[:-5].isdigit(): continue
    pid = int(e[:-5])
    try: os.kill(pid, 0)
    except ProcessLookupError: continue
    except PermissionError: pass
    except OSError: continue
    try: d = json.load(open(os.path.join(reg, e)))
    except Exception: continue
    sid, cwd = d.get('sessionId'), d.get('cwd')
    if not isinstance(sid, str) or not sid: continue
    if not (isinstance(cwd, str) and cwd):
        try: cwd = os.readlink('/proc/%d/cwd' % pid)
        except OSError: cwd = ''
    if cwd: live[sid] = cwd
from_live = from_home = 0
for line in open(f):
    line = line.rstrip('\n')
    if not line: continue
    c = line.split('\t')
    if len(c) >= 4 and c[3]: print(line); continue
    c = (c + ['', ''])[:3]
    cwd = live.get(c[1], '')
    if cwd: from_live += 1
    else: cwd, from_home = home, from_home + 1
    print('\t'.join(c + [cwd]))
sys.stderr.write('%d %d' % (from_live, from_home))
PY
    ) || { rm -f "$tmp"; echo "⚠ the pane map's cwd column was not filled in: $counts" >&2; return 0; }
    LC_ALL=C sort -o "$tmp" "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
    if [ "$(grep -c . "$tmp")" != "$(grep -c . "$f")" ] || cmp -s "$tmp" "$f"; then rm -f "$tmp"; return 0; fi   # a row lost: keep the map as it was
    _ledger_history_copy
    mv -f "$tmp" "$f" || { rm -f "$tmp"; return 0; }
    ledger_log migrate - "$(( ${counts% *} + ${counts#* } )) row(s) without a cwd → filled in: ${counts% *} from a live session, ${counts#* } with $HOME"
    return 0
}

# post_update_hook <what changed> — tell whoever tracks versions that a CLI update step just ran.
# Fires after EVERY attempt (also "already current"): the tracker may be stale for reasons sala did
# not cause (an out-of-band update, a box that was asleep at the last poll), and the consumer is
# expected to be cheap and debounced. sala knows nothing about the dashboard; the command is config.
# post_update_hook <what changed> [host…] — the hosts whose CLI was touched are exported as
# SALA_UPDATE_HOSTS (space-separated) and, when exactly one, SALA_UPDATE_HOST, so the command can
# scope its own check: e.g.  … bump-versions ${SALA_UPDATE_HOST:+--host $SALA_UPDATE_HOST}
# Before the command runs, the heartbeat runs once here (one writer): its fleet sweep
# reads every touched box's INSTALLED version over ssh, so the tracker reads the new value from the store instead
# of probing boxes itself.
post_update_hook() {
    local what="$1"; shift; local out
    # the store is the state dir; the repo alone no longer gates it
    if [ -n "${SALA_HEARTBEAT_STATE_DIR:-}${SALA_HEARTBEAT_REPO:-}" ] && [ $# -gt 0 ]; then out=$("$SALA_BIN" heartbeat 2>&1 | tail -1); echo "  heartbeat: $out"; fi
    [ -n "${SALA_POST_UPDATE_CMD:-}" ] || return 0
    export SALA_UPDATE_HOSTS="$*"; export SALA_UPDATE_HOST=""; [ $# -eq 1 ] && SALA_UPDATE_HOST="$1"
    if sh -c "$SALA_POST_UPDATE_CMD" >/dev/null 2>&1; then echo "  version tracker refreshed ($what)"
    else echo "  ⚠ SALA_POST_UPDATE_CMD failed ($what) — the version tracker may lag until its next poll"; fi
}

# post_recycle_hook <log> <kind> <started epoch> [skipped session…] — tell whoever waits on a recycle that its flag is cleared
# (stackshot clears an item's waits-for-recycle field). Fired ONCE PER CLEARED FLAG (Wed Oct 28th 2026;
# _set_cleared_hook above): when a recycle's set closes, with every pane back (skipped empty) or with the given-up panes named
# (a partial clear: a pane held past SALA_LATER_LIMIT, or one that is gone); also the reboot's boot half and `reboot --resume` standing
# in for it (a reboot is its own flag, its pause the time). `started` is the flag's time, and the same epoch goes out as
# SALA_RECYCLE_FLAG_AT, the name stackshot reads it by once its side ships (either side may ship first). Never for a `revive --only`
# of its own, a dry run, or a flag still waiting for a pane. Like SALA_POST_UPDATE_CMD the command is config and run with `sh -c`;
# unlike it, it runs DETACHED (setsid, holding none of sala's locks: the set's fd 5, which it fires under, the
# map's 6, the inbox's 8 and the recycle lock 9 are closed), its output goes to <log> with a `post-recycle:` prefix, and
# nothing it does changes the caller's exit or result. The command sees:
#   SALA_RECYCLE_KIND=recycle|reboot  SALA_RECYCLE_STARTED=<the flag's time, epoch>  SALA_RECYCLE_FLAG_AT=<the same epoch>
#   SALA_RECYCLE_RESULT=ok|partial (partial: a pane was skipped or failed)  SALA_RECYCLE_SKIPPED=<tmux sessions, space-separated>
# This box only: sala relaunches no panes on SALA_FLEET_HOSTS (update.sh: remotes are CLI-only), so no remote recycle ends here.
# THE BOARD'S CLEARED IDS: a line of the command's output that says items `no longer wait
# for a recycle (<ids>)` (stackshot's `stackshot: 2 item(s) no longer wait for a recycle (id1 id2)`) names items whose flag
# the board cleared. When the command exits 0 and the watchdog holds served ids (watch.sh, AUTO-RECYCLE), those ids go to
# one file in SALA_RECYCLE_CLEARED_DIR (written whole: tmp, then mv), which the watchdog's next run reads and removes, so
# a later flag on the same item counts again. The hook never writes the watch state itself: watch has no lock on it.
SALA_RECYCLE_CLEARED_DIR="$SALA_STATE_DIR/recycle-cleared"
post_recycle_hook() {
    [ -n "${SALA_POST_RECYCLE_CMD:-}" ] || return 0
    local log="$1" kind="$2" started="$3" skipped result=ok; shift 3
    skipped=$(printf '%s\n' "$@" | grep -v '^[[:space:]]*$' | awk '!seen[$0]++' | paste -sd' ' -)
    [ -n "$skipped" ] && result=partial
    _mkparent "$log"
    local detach=setsid; command -v setsid >/dev/null 2>&1 || detach=nohup   # macOS base system has no setsid(1)
    SALA_RECYCLE_KIND="$kind" SALA_RECYCLE_STARTED="$started" SALA_RECYCLE_FLAG_AT="$started" SALA_RECYCLE_RESULT="$result" SALA_RECYCLE_SKIPPED="$skipped" \
    "$detach" bash -c 'export SALA_RECYCLE_KIND SALA_RECYCLE_STARTED SALA_RECYCLE_FLAG_AT SALA_RECYCLE_RESULT SALA_RECYCLE_SKIPPED
        echo "[$(date -Is)] post-recycle: $SALA_RECYCLE_KIND flag_at=$SALA_RECYCLE_FLAG_AT $SALA_RECYCLE_RESULT${SALA_RECYCLE_SKIPPED:+ (skipped: $SALA_RECYCLE_SKIPPED)} → SALA_POST_RECYCLE_CMD"
        cl=""
        { sh -c "$1" 2>&1; echo "__sala_rc=$?"; } | while IFS= read -r l; do
            case "$l" in
                __sala_rc=0) [ -n "${cl// /}" ] && grep -q "^auto_recycle_served_ids=." "$3" 2>/dev/null && mkdir -p "$2" \
                    && printf "%s\n" "$cl" > "$2/.$$.tmp" && mv -f "$2/.$$.tmp" "$2/$(date +%s)-$$.ids" ;;
                __sala_rc=*) echo "[$(date -Is)] post-recycle: ⚠ SALA_POST_RECYCLE_CMD failed (rc ${l#__sala_rc=}) — the recycle itself is unaffected";;
                *) echo "[$(date -Is)] post-recycle: $l"
                   case "$l" in *"no longer wait for a recycle ("*")"*) x=${l##*no longer wait for a recycle (}; cl="$cl ${x%%)*}";; esac ;;
            esac
        done' _ "$SALA_POST_RECYCLE_CMD" "$SALA_RECYCLE_CLEARED_DIR" "$SALA_LOG_DIR/salamander-watch.state" </dev/null >>"$log" 2>&1 5>&- 6>&- 8>&- 9>&- &
    disown 2>/dev/null || true
    return 0
}
# not_back_sessions <"sess: reason" row…> — the sessions among the boot half's `bad` rows that are not back on their
# conversation (reboot.sh); a session back on it under a new claude.ai id was relaunched, so it is not skipped.
not_back_sessions() { local b; for b in "$@"; do case "$b" in *": not back on its conversation") echo "${b%%:*}";; esac; done; }

# ── session inbox ─────────────────────────────────────────────────────────────
# session_socket <claude-pid> → the session's messaging socket (registry messagingSocketPath), or empty
session_socket() { local s; s=$(registry_field "$1" messagingSocketPath); [ "$s" = null ] && s=""; [ -S "$s" ] && echo "$s"; }
# session_push <socket> <text> → 0 when delivered. Wire (Claude Code 2.1.28x, undocumented, pinned here): one JSON
# line {"type":"user","message":{"role":"user","content":TEXT}} on the session's unix socket; it arrives as a turn.
session_push() {
    python3 - "$1" "$2" <<'PY2'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(10)
try:
    s.connect(sys.argv[1])
    s.sendall((json.dumps({"type": "user", "message": {"role": "user", "content": sys.argv[2]}}) + "\n").encode())
except Exception as e:
    print(f"push failed: {e}", file=sys.stderr); sys.exit(1)
finally:
    s.close()
PY2
}

# ── panes stopped on a network error ──────────────────────────────────────────
# THE NETWORK STOP: after a reboot with DNS down, panes can end
# their first turn on "API Error: Can't reach the API server — check your internet or DNS (EAI_AGAIN)". A turn that ends on
# that error is over: nothing retries it, so the panes stay stopped after DNS comes back, while the revive post
# reads as a success. net_scan reads the stop from the pane's transcript, the way the usage-limit watch reads its errors; the
# wake is the watch's (lib/watch.sh, NETWORK-STOP WAKE) and the count in the revive post is revive's, both through this.
#  - THE RECORD (Claude Code 2.1.289-2.1.306, read from real transcripts, structure only): an assistant
#    record with isApiErrorMessage true, error "server_error", no apiError, no apiErrorStatus, model "<synthetic>", one text
#    block "API Error: Can't reach the API server — check your internet or DNS (EAI_AGAIN)". The text is the family
#    matched (any of "can't reach the api server", "eai_again", "check your internet or dns", case-folded): an ordinary
#    answer that merely quotes it has no isApiErrorMessage and never counts.
#  - STOPPED means the pane's NEWEST assistant record is such an error. The EPISODE is the unbroken run of them at the end of
#    the tail: it starts at the first, and ends with any other assistant record (an answer, another kind of API error), so a
#    pane that works again and stops again later is a new episode, and a woken turn that fails again on the same error stays
#    in the same one. An error older than SALA_NET_LOOKBACK is no stop.
# net_scan reads "<session>|<claude pid>[|…]" lines on stdin (lw_panes' shape) and prints, for each pane stopped on it:
#   net <session> <pid> <conversation> <first error epoch> <last error epoch>
: "${SALA_NET_LOOKBACK:=259200}"
IFS= read -r -d '' NET_PY <<'PYN' || :   # (a read, not $(cat <<…): that ran a cat each time this file was loaded)
import glob, json, os, re, sys, time
from datetime import datetime
SP, RD, LB = os.environ["SP"], os.environ["RD"], int(os.environ.get("LB") or 259200)
now = int(time.time()); TAIL = 524288
FAM = re.compile(r"can['’]?t reach the api server|eai_again|check your internet or dns", re.I)
def ep(ts):
    try: return int(datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp())
    except Exception: return 0
def kind(o):  # → None (not an assistant record of the main thread) | "net" | "other"
    if o.get("type") != "assistant" or o.get("isSidechain"): return None
    if not o.get("isApiErrorMessage"): return "other"
    msg = o.get("message") or {}
    text = " ".join(str(c.get("text", "")) for c in (msg.get("content") or []) if isinstance(c, dict))
    return "net" if FAM.search(text) else "other"
def run(p):  # the unbroken run of network errors at the end of the transcript's tail → (first epoch, last epoch), or None
    try:
        with open(p, "rb") as f:
            f.seek(0, 2); size = f.tell(); f.seek(max(0, size - TAIL)); data = f.read()
        lines = data.decode("utf-8", "replace").split("\n")
        if size > TAIL: lines = lines[1:]
    except OSError: return None
    ks = []
    for l in lines:
        if '"assistant"' not in l: continue
        try: o = json.loads(l)
        except Exception: continue
        k = kind(o) if isinstance(o, dict) else None
        if k: ks.append((k, ep(o.get("timestamp") or "")))
    n = 0
    while n < len(ks) and ks[-1 - n][0] == "net": n += 1
    return (ks[-n][1], ks[-1][1]) if n else None
seen = set()
for line in sys.stdin:
    parts = line.rstrip("\n").split("|")
    if len(parts) < 2 or not parts[0] or " " in parts[0] or not parts[1].isdigit(): continue
    s, pid = parts[0], parts[1]
    try: reg = json.load(open(os.path.join(RD, pid + ".json")))
    except Exception: continue
    u = str(reg.get("sessionId") or "")
    if not u or u in seen: continue
    c = glob.glob(os.path.join(glob.escape(SP), "*", glob.escape(u) + ".jsonl"))
    if not c: continue
    p = max(c, key=os.path.getmtime)
    if os.path.getmtime(p) < now - LB: continue
    r = run(p)
    if r and r[1] >= now - LB: seen.add(u); print("net %s %s %s %d %d" % (s, pid, u, r[0], r[1]))
PYN
NET_PY=${NET_PY%$'\n'}
net_scan() { SP="$SALA_PROJECTS" RD="$SALA_REG_DIR" LB="$SALA_NET_LOOKBACK" python3 -c "$NET_PY"; }
# net_stopped_sessions <tmux session…> → the net_scan rows of those sessions' claudes that are stopped on a network error
net_stopped_sessions() {
    local s pane pid
    for s in "$@"; do
        pane=$(tmux list-panes -t "$(tmux_win_t "$s")" -F '#{pane_pid}' 2>/dev/null | head -1); [ -n "$pane" ] || continue
        pid=$(claude_pid_under "$pane" 2>/dev/null); [ -n "$pid" ] && echo "$s|$pid"
    done | net_scan
}

# ── the mod ───────────────────────────────────────────────────────────────────
# THE MOD: mod/ in this repo, a Claude Code plugin loaded into every pane sala launches or resumes
# (CLAUDE_CODE_PLUGIN_DIRS, put on the launch line by mod_env_prefix: resume_cmd below, spawn). It answers three requests
# from inside the session, so sala need not type keys or read the screen for them: exit (refused over a draft or while
# background work runs — the CLI's "Background work is running" dialog would hold a typed /exit), rename, and draft (the
# prompt box's text). A request is one marked line through session_push; the mod consumes it, so it never reaches the
# transcript. The mod's files live in one directory both sides compute the same way (mod_run_dirs; the mod: runDir):
#   <sessionId>.json                presence stamp {present, version, sessionId, at (ms)}, written at the session's start
#   <sessionId>.<reqid>.reply.json  one reply per request {reqid, ok, reason?, text?}; read and removed here
# A session with no stamp, a stamp older than its process (a pane resumed without the mod after one with it), no socket,
# a failed push or no reply within SALA_MOD_WAIT seconds: the caller falls back to the keys, exactly as before the mod.
# Every request is one line in salamander-mod.log, the path it took (mod or keys) and why, so the fallback rate shows.
# SALA_MOD_DIR (default: this checkout's mod/, the production checkout under ~/salamander) empty = panes launch without it.
SALA_MOD_DIR="${SALA_MOD_DIR-${SALA_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/mod}"
: "${SALA_MOD_WAIT:=3}"                              # seconds a request waits for the mod's reply
SALA_MOD_VERSION=1                                   # the oldest mod protocol this sala speaks
SALA_MOD_LOG="$SALA_LOG_DIR/salamander-mod.log"
SALA_MOD_MARK='[sala-mod]'
mod_log() { mkdir -p "$SALA_LOG_DIR" 2>/dev/null; echo "[$(date -Is)] $*" >> "$SALA_MOD_LOG"; }   # <verb> <who> via mod|keys (<why>)
# mod_run_dirs → the directories the mod writes in, most likely first: $XDG_RUNTIME_DIR/sala/mod as the pane's claude sees
# it, else the state dir's mod/ (the mod's own fallback when XDG_RUNTIME_DIR is unset). Both are looked in, so a pane
# and a sala run with different environments (a systemd timer, an ssh shell) still meet.
mod_run_dirs() { [ -n "${XDG_RUNTIME_DIR:-}" ] && echo "$XDG_RUNTIME_DIR/sala/mod"; echo "$SALA_STATE_DIR/mod"; }
# mod_env_prefix → "CLAUDE_CODE_PLUGIN_DIRS=… " for a claude launch line typed into a pane's shell: the mod's folder
# appended to whatever the pane's shell already has (POSIX ${…:+…}: bash, zsh, sh — not fish). Empty when the mod is
# switched off (SALA_MOD_DIR empty), not there, or its path needs quoting (never typed half-quoted into a shell).
mod_env_prefix() {
    [ -n "$SALA_MOD_DIR" ] && [ -f "$SALA_MOD_DIR/.claude-plugin/plugin.json" ] || return 0
    case "$SALA_MOD_DIR" in *[!A-Za-z0-9/._~+-]*) return 0;; esac
    printf 'CLAUDE_CODE_PLUGIN_DIRS="${CLAUDE_CODE_PLUGIN_DIRS:+$CLAUDE_CODE_PLUGIN_DIRS:}%s" ' "$SALA_MOD_DIR"
}
# ── lanes ─────────────────────────────────────────────────────────────────────
# THE LANE: which
# account or key a pane's claude runs on. Four lanes, each one env prefix on the launch line, nothing else:
#   subscription-1  (displayed Ultra; was `max`) the claude.ai login in ~/.claude (a subscription plan): the line as it always was, no env — the lane of every session nothing
#         was recorded for (today's behaviour)
#   api   the Anthropic API key (prepaid credit): ANTHROPIC_API_KEY from SALA_LANE_API_KEY_FILE and, when
#         SALA_LANE_API_WORKSPACE_FILE exists, ANTHROPIC_CUSTOM_HEADERS="anthropic-workspace-id: …" (an identity-linked
#         key bills to that workspace). Both are `$(cat <file>)`, run by the PANE'S shell when it runs the line: the key is
#         in that claude's environment and nowhere else — not in the typed text, tmux's buffer, sala's logs or any argv.
#         No claude.ai login behind it: no Remote Control (lane_rc; watch's bridge heal and the reboot's bridge check skip
#         such a pane) and no claude.ai connectors (SALA_LANE_API_MCP_CONFIG, a --mcp-config file, stands in when it exists).
#         A pane's line also carries ENABLE_PROMPT_CACHING_1H=1 (the 1-hour prompt cache; an API-key lane gets the 5-minute one without it)
#   bedrock  Claude on Amazon Bedrock through the AWS profile SALA_LANE_BEDROCK_PROFILE: no key file, no claude.ai login.
#         The launch line carries AWS_PROFILE, CLAUDE_CODE_USE_BEDROCK=1, AWS_REGION, ANTHROPIC_BEDROCK_REGION_PREFIX and the three
#         pinned model ids (ANTHROPIC_DEFAULT_OPUS/SONNET/HAIKU_MODEL) — names and ids only, no secret: the AWS keys stay in
#         ~/.aws/credentials, which the CLI's own credential chain reads and sala never opens beyond testing for the profile's
#         `[section]` header line. Set on that pane's launch line only: never exported, never in settings. As api: no Remote
#         Control, and --mcp-config SALA_LANE_API_MCP_CONFIG stands in for the claude.ai connectors. A pane's line also carries
#         ENABLE_PROMPT_CACHING_1H_BEDROCK=1 (the 1-hour prompt cache, as on subscription-1); a scheduled job's environment (lane_job_env) does not.
#   aws-platform  Claude Platform on AWS: the Anthropic-operated Claude API, signed with SigV4 through the AWS profile
#         SALA_LANE_AWSPLATFORM_PROFILE and billed through AWS Marketplace — a lane of its own beside bedrock (Amazon Bedrock is another
#         service: other endpoint, other model ids, other routing flag). The launch line carries AWS_PROFILE, CLAUDE_CODE_USE_ANTHROPIC_AWS=1,
#         ANTHROPIC_AWS_WORKSPACE_ID, AWS_REGION and the three pinned model ids (the plain API ids), and starts with `env -u` for the variables
#         that would change the routing or the signing (CLAUDE_CODE_USE_BEDROCK and CLAUDE_CODE_USE_FOUNDRY, which take precedence over this
#         provider; ANTHROPIC_AWS_API_KEY, which takes precedence over SigV4) — names and ids only, no secret. Set on that pane's launch line only:
#         never exported, never in settings. As api and bedrock: no Remote Control, and --mcp-config SALA_LANE_API_MCP_CONFIG stands in for the
#         claude.ai connectors. Not launchable until the workspace id (SALA_LANE_AWSPLATFORM_WORKSPACE_ID, wrkspc_…) is set: lane_check refuses.
#         A pane's line also ends with ENABLE_PROMPT_CACHING_1H=1, not the _BEDROCK variant: the CLI's provider here is "anthropicAws"
#         (CLAUDE_CODE_USE_ANTHROPIC_AWS), and it honours the _BEDROCK switch only when the provider is bedrock.
#   subscription-2  (displayed Team; was `team`) a second claude.ai login (a seat-based plan) in a config directory of its own: CLAUDE_CONFIG_DIR=SALA_LANE_TEAM_DIR
#   sdk   (an ALIAS of api since api's key with client claude-agent-sdk, see "THE LANE FIELDS" below) the same key, through the Agent SDK (an API credit may pay for SDK calls
#         and refuse anything sent as Claude Code — the api lane's `claude` included). The lane is open
#         while the key has credit and closes itself when a call is refused: lib/api_credit.py's record (below). Not a prefix on a `claude` line: the pane runs `salamander sdk-pane
#         <uuid> <session>` (lib/sdk-pane.sh), which starts contrib/sdk-pane/driver.py under `uv run --with
#         claude-agent-sdk==<SALA_LANE_SDK_PIN>`; the driver reads the key and the workspace id from the api lane's files
#         itself and hands them only to the CLI process the SDK spawns (the CLI, with CLAUDE_CODE_ENTRYPOINT=sdk-py set by
#         the SDK, never by hand), resumes the conversation, loads the user settings (hooks, plugins), the api lane's
#         --mcp-config, and draws a ❯ box the pane's readers know. The CLI registers as every pane's does, so idle checks,
#         /exit and the resume work as on any lane. While the record holds a refusal less than API_CREDIT_RETRY_S (6 h) old a row of sdk launches on subscription-1 (lane_for_session;
#         the wrapper checks the record itself too), and a turn the credit refuses writes the record and puts the pane back on subscription-1 at once (the
#         wrapper, exit 3 from the driver: row rewritten, one post, resumed on the subscription-1 line). No Remote Control (as api).
# The CLI picks its auth when the process starts (ANTHROPIC_API_KEY before the stored login; a config directory keeps its
# own login), and the login in ~/.claude is untouched by a per-process key, so a switch is a relaunch with another env and
# never a re-auth. STATE, in the XDG state dir like the map: lanes.tsv, one "<tmux session>\t<lane>" row per session with
# a lane of its own; lane-default, the lane of every session without a row. Every launch path puts the session's lane on
# its line — spawn (the default lane), the sweep's resume (recycle, revive, the boot hook, restore, the retry workers,
# watch's deferred relaunch), the self-worker and unpark through resume_cmd — so a recycle brings an api-lane pane back on
# the api lane, which until today only SALA_NO_RELAUNCH could prevent (no_relaunch above). `sala lane` (lib/lane.sh) is
# the verb: it records and relaunches; nothing here relaunches by itself.
SALA_LANES="$SALA_STATE_DIR/lanes.tsv"; SALA_LANE_DEFAULT_FILE="$SALA_STATE_DIR/lane-default"; SALA_LANE_LOG="$SALA_STATE_DIR/lanes.log"
# the two watches' state, read here by lane_out (the rescue) and kept by lib/watch.sh (limit_tick, signin_tick)
SALA_LIMIT_STATE="${SALA_LIMIT_STATE:-$SALA_LOG_DIR/salamander-limit.json}"; SALA_SIGNIN_STATE="$SALA_STATE_DIR/lane-signin.state"
: "${SALA_LANE_API_KEY_FILE:=$HOME/.config/anthropic/api-key}"              # api: the key, 0600, read by the pane's shell at launch
: "${SALA_LANE_API_WORKSPACE_FILE:=$HOME/.config/anthropic/workspace-id}"   # api: the workspace id header's value; optional (a classic key needs none)
: "${SALA_LANE_API_MCP_CONFIG:=$HOME/.config/claude-lanes/api-mcp.json}"   # api: `--mcp-config` this file when it exists (the portal, GitHub: what the claude.ai connectors gave)
: "${SALA_LANE_BEDROCK_PROFILE:=}"                                          # bedrock: the AWS profile (its own key; the admin profile is never the lane's, lane_check refuses it); empty = unset, and lane_check says so
: "${SALA_LANE_BEDROCK_CREDENTIALS_FILE:=$HOME/.aws/credentials}"          # bedrock: where lane_check looks for the profile's [header] line (presence only; no value is read or shown)
: "${SALA_LANE_BEDROCK_PREFIX:=global}"                                    # bedrock: ANTHROPIC_BEDROCK_REGION_PREFIX (us eu apac jp au global)
# bedrock: the pinned models, Bedrock inference-profile ids in the GLOBAL form. Sources:
#   Opus 5.5   global.anthropic.claude-opus-5-5     CONFIRMED: Claude Code's Bedrock page (code.claude.com/docs/en/amazon-bedrock) gives it as what
#              ANTHROPIC_BEDROCK_REGION_PREFIX=global resolves the built-in Opus 5.5 default to, in a us-* region
#   Sonnet 5.5 global.anthropic.claude-sonnet-5-5   BY PATTERN: the base id anthropic.claude-sonnet-5-5 and the global endpoint for it are in
#   Haiku 5.5  global.anthropic.claude-haiku-5-5    Anthropic's Models overview and "Claude in Amazon Bedrock" pages, and the Claude Code page says the
#              prefix goes onto the built-in id; no primary doc prints these two global. strings. Unverified until a first launch: if Bedrock
#              refuses one, set SALA_LANE_BEDROCK_SONNET_MODEL / _HAIKU_MODEL in the sala config (the lane then runs as the ids say, nothing else changes)
: "${SALA_LANE_BEDROCK_OPUS_MODEL:=global.anthropic.claude-opus-5-5}"
: "${SALA_LANE_BEDROCK_SONNET_MODEL:=global.anthropic.claude-sonnet-5-5}"
: "${SALA_LANE_BEDROCK_HAIKU_MODEL:=global.anthropic.claude-haiku-5-5}"
: "${SALA_JOB_LANE:=subscription-1}"   # the lane of sala's OWN scheduled model calls, the ones sala-watch starts (the stuck-operation helper, the parked-question sweep); a unit that makes model calls says its own lane in its ExecStart (`salamander lane exec <lane> --`). Default subscription-1 (the login on this box; max, its old word, works); set bedrock or api to move them
: "${SALA_LANE_AWSPLATFORM_PROFILE:=}"                                    # aws-platform: the AWS profile (may be the same IAM user as bedrock's; the admin profile is never the lane's, lane_check refuses it); empty = unset, and lane_check says so
: "${SALA_LANE_AWSPLATFORM_CREDENTIALS_FILE:=$HOME/.aws/credentials}"      # aws-platform: where lane_check looks for the profile's [header] line (presence only; no value is read or shown)
: "${SALA_LANE_AWSPLATFORM_WORKSPACE_ID:=}"                                # aws-platform: the workspace id (wrkspc_…; not a secret, and not known yet: empty, so lane_check refuses until it is set)
# aws-platform: the pinned models, the PLAIN Claude API ids (the doc: "Claude Platform on AWS uses the same model IDs as the direct Claude API").
# Sources: code.claude.com/docs/en/claude-platform-on-aws prints only the pin EXAMPLES claude-fable-5, claude-opus-4-8, claude-sonnet-5,
# claude-haiku-4-5 and says the opus alias resolves to Opus 5.5 without a pin, with no id string for it. So:
#   Opus 5.5   claude-opus-5-5     CONFIRMED by the installed CLI, whose built-in model table gives claude-opus-5-5 for this provider, and by the doc's "Opus 5.5"
#   Sonnet 5.5 claude-sonnet-5-5   BY PATTERN (the first-party default in the same table; the doc names no 5.5 id) — NOT the CLI's built-in for this provider, which is claude-sonnet-4-6
#   Haiku 5.5  claude-haiku-5-5    BY PATTERN (as Sonnet) — the CLI's built-in for this provider is claude-haiku-4-5
#              Unverified until a first launch: if the workspace refuses one, set SALA_LANE_AWSPLATFORM_SONNET_MODEL / _HAIKU_MODEL in the sala config
: "${SALA_LANE_AWSPLATFORM_OPUS_MODEL:=claude-opus-5-5}"
: "${SALA_LANE_AWSPLATFORM_SONNET_MODEL:=claude-sonnet-5-5}"
: "${SALA_LANE_AWSPLATFORM_HAIKU_MODEL:=claude-haiku-5-5}"
: "${SALA_LANE_TEAM_DIR:=$HOME/.claude-team}"                               # subscription-2 (team): its CLAUDE_CONFIG_DIR
: "${SALA_LANE_SDK_PIN:=claude-agent-sdk==0.2.165}"                         # sdk: the SDK `uv run --with` fetches (the version smoke-tested)
: "${SALA_LANE_SDK_CMD:=}"      # sdk: the driver's interpreter, in place of `uv run --quiet --no-project --with <pin> python -I` (tests: a stub SDK)
: "${SALA_LANE_SDK_NOW:=}"      # sdk: the clock the credit record is read against (epoch seconds; tests), else now
# THE ACCOUNT BEHIND EACH LOGIN LANE (the sign-in watch, lib/watch.sh "SIGN-IN WATCH"): a config
# directory holds ONE login, so a /login typed in one pane re-signs its whole lane, and a lane can sit on another account
# unnoticed. This table says what `claude auth status --json` must report for each login lane's directory — its
# subscriptionType, and for the seat-based lane its orgName — and the watch alerts when a lane reports otherwise. Config, never
# learned from a run: a lane found on another account is a change, on the first look as on any later one.
: "${SALA_LANE_MAX_SUBSCRIPTION:=max}"     # subscription-1: the login in ~/.claude is the max subscription (Anthropic's own plan name)
: "${SALA_LANE_MAX_ORG:=}"                 # subscription-1: its orgName; empty = any (a personal login's organization is named after its email)
: "${SALA_LANE_TEAM_SUBSCRIPTION:=team}"   # subscription-2: the login in SALA_LANE_TEAM_DIR is the team seat …
: "${SALA_LANE_TEAM_ORG:=}"                # … of this organization (its orgName); empty = any (the sign-in watch then checks the subscription only)
lane_expect() {  # <lane> → "<subscriptionType>|<orgName or empty>" the lane's login must report (subscription-1, subscription-2: Anthropic's own plan names are the config's values); nothing for a key lane
    local _n; _lane_norm_r _n "${1:-}"
    case "$_n" in
        subscription-1) echo "$SALA_LANE_MAX_SUBSCRIPTION|$SALA_LANE_MAX_ORG" ;;
        subscription-2) echo "$SALA_LANE_TEAM_SUBSCRIPTION|$SALA_LANE_TEAM_ORG" ;;
    esac
}
SALA_LANES_KNOWN="subscription-1 api subscription-2 sdk bedrock aws-platform"
# THE RENAMED LANE (`awsplatform` became `aws-platform`). `awsplatform` was the lane's
# earlier name and stays a WORD for it: lane_norm turns it into the current name, and everything that reads a lane
# name from outside this code does it first — a typed argument (`sala lane awsplatform X`, `spawn --lane`, `op lane`), a row of
# lanes.tsv / lane-default / lane-state.tsv / the registry written before the rename. Writers always write the current name, and a
# write rewrites the old name in the rows it carries along; `sala lane --migrate` does the whole table once. The hyphen is a legal
# character in every place a lane name is a token (case patterns, awk fields, JSON values, CSS class names, file names) except a
# shell VARIABLE NAME: SALA_LANE_<ID>_<FIELD> is made by lane_varid, which drops the hyphen, so the config names of this lane stay
# SALA_LANE_AWSPLATFORM_* (an operator's config file keeps working).
# THE SUBSCRIPTION LANES' CODES: the lane `max` is `subscription-1` and the lane `team` is
# `subscription-2`; the first's display name is Ultra, set in ONE place (its label field: lane_label, SALA_LANE_SUBSCRIPTION1_LABEL;
# "THE LANE FIELDS" below) and read from there by everything sala shows. The old codes stay WORDS for the lanes exactly as awsplatform
# does: lane_norm turns them into the current code wherever one is read (typed arguments, lanes.tsv, lane-default, lane-state.tsv,
# lane-home.tsv, models.tsv, job and unit definitions, marker files, SALA_JOB_LANE, SALA_LANE_FALLBACK), nothing stored is rewritten
# by a read, and a NEW write records the new code (a write rewrites only the row it writes: no file is carried along in a new spelling,
# and `sala lane --migrate` still moves only awsplatform). Not renamed: the config variables (SALA_LANE_MAX_*, SALA_LANE_TEAM_*; the field
# overrides also take SALA_LANE_SUBSCRIPTION1_* and SALA_LANE_SUBSCRIPTION2_*), and Anthropic's own plan names (a login's subscriptionType
# `max` / `team`, the plans max_5x, max_20x, team_standard, team_premium). The one table of old words and their lanes:
SALA_LANE_RENAMED="awsplatform=aws-platform max=subscription-1 team=subscription-2"
_lane_norm_r() { case "${2:-}" in awsplatform) printf -v "$1" %s aws-platform;; max) printf -v "$1" %s subscription-1;; team) printf -v "$1" %s subscription-2;; *) printf -v "$1" %s "${2:-}";; esac; }   # <var> <word> → the lane's current name in <var> (awsplatform → aws-platform, max → subscription-1, team → subscription-2); any other word as it came. No fork: the lane tables are read thousands of times in a run
lane_norm() { local _n; _lane_norm_r _n "${1:-}"; printf '%s\n' "$_n"; }   # <word> → the same on stdout
_lane_varid_r() { local _v=${2:-}; _v=${_v//-/}; printf -v "$1" %s "${_v^^}"; }   # <var> <lane> → the lane's part of a SALA_LANE_<ID>_<FIELD> variable name (aws-platform → AWSPLATFORM, subscription-1 → SUBSCRIPTION1: a hyphen cannot be in a variable name)
_lane_varid_old_r() { case "${2:-}" in subscription-1) printf -v "$1" %s MAX;; subscription-2) printf -v "$1" %s TEAM;; *) printf -v "$1" %s "";; esac; }   # <var> <lane> → the part the config used before the rename (MAX, TEAM: SALA_LANE_MAX_ACCOUNT keeps working); empty for a lane that was never renamed
lane_varid() { local _id; _lane_varid_r _id "${1:-}"; printf '%s' "$_id"; }
lane_known() { local w; _lane_norm_r w "${1:-}"; case " $SALA_LANES_KNOWN " in *" $w "*) return 0;; esac; return 1; }   # <word> → 0 when it names a lane (the old name of a renamed lane included)
# THE LANE FIELDS. What a lane IS, apart from how it launches: one row per lane, the same fields for every provider, so a
# Codex or Gemini lane later is another row and no new vocabulary. FIELDS ONLY: nothing here launches or changes anything;
# `sala lane --list` / `--json` print the rows, lane_fields_problems checks them.
#   id          what commands take (subscription-1, subscription-2, api, bedrock, aws-platform)   label   how it is shown, THE display name (Ultra, Team, API, Bedrock, Claude Platform on AWS)
#   provider    ids after the Vercel AI SDK: anthropic openai google google-vertex amazon-bedrock azure
#   client      what runs the model: claude-code claude-agent-sdk codex gemini-cli
#   org         the paying organization; project (optional) its division: an Anthropic workspace id, an OpenAI project, a Google Cloud project
#   billing     subscription | usage; for usage, payment: prepaid | postpaid; plan (subscriptions only): max_5x max_20x team_standard
#               team_premium chatgpt_plus chatgpt_pro chatgpt_business google_ai_pro google_ai_ultra
#   account     the sign-in email; credential (optional) how it signs in: login, key file, AWS or Google Cloud profile; region (optional)
#   status      active | inactive | not set up
# The defaults are the table below; any field is overridden by config as SALA_LANE_<ID>_<FIELD> (SALA_LANE_API_ORG=…,
# SALA_LANE_BEDROCK_STATUS=active; id cannot be; the subscription lanes' <ID> is SUBSCRIPTION1 / SUBSCRIPTION2, and the names they had before the
# rename, MAX and TEAM, still work). The display name of a lane is its `label` field and nowhere else: SALA_LANE_SUBSCRIPTION1_LABEL=Ultra. `sdk` is no lane of its own: the old sdk lane is the api lane with client
# claude-agent-sdk, so the word stays accepted everywhere it was (lanes.tsv rows, `sala lane sdk <session>`) as an ALIAS —
# lane_canonical sdk = api, lane_field sdk client = claude-agent-sdk — and keeps its launch (the pane program, the credit
# credit record (api_credit_ok), the pin SALA_LANE_SDK_PIN, the command SALA_LANE_SDK_CMD): those settings belong to the api lane's
# claude-agent-sdk client. `client` is a description: which client a pane launches is still decided by the lane word (api →
# claude, sdk → the pane program). bedrock launches
# (lane_check bedrock below); its status is DERIVED: active while lane_check passes, "not set up" while it does not (a config
# SALA_LANE_BEDROCK_STATUS still wins), and its region is the AWS region the pane launches with (SALA_LANE_BEDROCK_REGION, no default: unset = not set up). aws-platform
# is the same: status derived from lane_check, region the launch's AWS_REGION (SALA_LANE_AWSPLATFORM_REGION), and its project
# field is the workspace id.
SALA_LANES_DEFINED="subscription-1 subscription-2 api bedrock aws-platform"
SALA_LANE_FIELDS="id label provider client org project billing payment plan account credential region status"
lane_canonical() { case "${1:-}" in sdk) echo api;; *) lane_norm "${1:-}";; esac; }   # <word> → the lane it is a word for (sdk → api; awsplatform → aws-platform)
_lane_tilde_r() { case "$1" in "$HOME"/*) printf -v "$2" '~/%s' "${1#"$HOME"/}";; *) printf -v "$2" %s "$1";; esac; }   # <path> <var>
_lane_tilde() { local t; _lane_tilde_r "$1" t; printf '%s' "$t"; }
_lane_field_default_r() {  # <lane> <field> → _LFV, the table's value (empty for a field the lane leaves out); the lane fields are read thousands of times in a run, so no fork here
    local t1 t2 _ln
    _LFV=""; _lane_norm_r _ln "$1"
    case "$_ln:$2" in
        *:id) _LFV=$_ln ;;
        subscription-1:label) _LFV=Ultra ;; subscription-2:label) _LFV=Team ;; api:label) _LFV=API ;; bedrock:label) _LFV=Bedrock ;; aws-platform:label) _LFV="Claude Platform on AWS" ;;
        bedrock:provider) _LFV=amazon-bedrock ;; *:provider) _LFV=anthropic ;;
        *:client) _LFV=claude-code ;;
        subscription-1:org) t1=${SALA_LANE_SUBSCRIPTION1_ACCOUNT:-${SALA_LANE_MAX_ACCOUNT:-}}; if [ -n "$t1" ]; then _LFV="$t1's Organization"; else _LFV=unconfirmed; fi ;;   # a personal login's organization is named after its email
        subscription-2:org|api:org) _LFV=unconfirmed ;;   # SALA_LANE_<ID>_ORG names it
        bedrock:org) _LFV="AWS account" ;;
        aws-platform:org) _LFV="AWS-linked Anthropic organization" ;;   # AWS Marketplace provisions an organization of its own (not the Console one api uses)
        aws-platform:project) _LFV=$SALA_LANE_AWSPLATFORM_WORKSPACE_ID ;;   # the workspace id (not a secret)
        subscription-1:billing|subscription-2:billing) _LFV=subscription ;; api:billing|bedrock:billing|aws-platform:billing) _LFV=usage ;;
        api:payment) _LFV=prepaid ;; bedrock:payment|aws-platform:payment) _LFV=postpaid ;;
        *:plan) ;;   # NO default: a plan is the account's own, so the config sets it (SALA_LANE_<ID>_PLAN); empty = not stated
        *:account) _LFV=unconfirmed ;;   # SALA_LANE_<ID>_ACCOUNT names it
        subscription-1:credential|subscription-2:credential) _LFV=login ;;
        api:credential) _lane_tilde_r "$SALA_LANE_API_KEY_FILE" t1; _lane_tilde_r "$SALA_LANE_API_WORKSPACE_FILE" t2; _LFV="key file $t1 + workspace id file $t2" ;;
        bedrock:credential|aws-platform:credential) _LFV="AWS profile" ;;   # the wording only: the profile's name and the credentials file's path stay out of the fields
        bedrock:region|aws-platform:region) ;;   # NO default: a region names a place, so the config sets it (SALA_LANE_BEDROCK_REGION, SALA_LANE_AWSPLATFORM_REGION); empty = the lane is not set up
        subscription-1:status) _LFV=active ;; subscription-2:status|api:status) _LFV=inactive ;; bedrock:status|aws-platform:status) if lane_check "$_ln" >/dev/null 2>&1; then _LFV=active; else _LFV="not set up"; fi ;;   # api: no credit; bedrock: derived
    esac
    return 0
}
_lane_field_default() { _lane_field_default_r "$@"; [ -n "$_LFV" ] && printf '%s\n' "$_LFV"; return 0; }   # <lane> <field> → the table's value, empty for a field the lane leaves out
_lane_field_r() {  # <var> <lane|sdk> <field> → the value in <var> (the config override SALA_LANE_<ID>_<FIELD> when set and non-empty, else the table's; empty for a field the lane leaves out); 1 for a word that is no lane. No fork.
    local l f="${3:-}" u
    if [ "${2:-}" = sdk ] && [ "$f" = client ]; then printf -v "$1" %s claude-agent-sdk; return 0; fi
    l=${2:-}; [ "$l" = sdk ] && l=api; _lane_norm_r l "$l"
    lane_known "$l" || return 1
    case " $SALA_LANE_FIELDS " in *" $f "*) ;; *) return 1;; esac
    if [ "$f" != id ]; then
        _lane_varid_r u "$l"; u="SALA_LANE_${u}_${f^^}"
        if [ -n "${!u:-}" ]; then printf -v "$1" %s "${!u}"; return 0; fi
        _lane_varid_old_r u "$l"   # a config written before the rename (SALA_LANE_MAX_ACCOUNT, SALA_LANE_TEAM_ORG) still counts
        if [ -n "$u" ]; then u="SALA_LANE_${u}_${f^^}"; if [ -n "${!u:-}" ]; then printf -v "$1" %s "${!u}"; return 0; fi; fi
    fi
    _lane_field_default_r "$l" "$f"; printf -v "$1" %s "$_LFV"
}
lane_field() {  # <lane|sdk> <field> → the value: the config override SALA_LANE_<ID>_<FIELD> when set and non-empty, else the table's
    local _lf_v=""
    _lane_field_r _lf_v "$@" || return 1
    [ -n "$_lf_v" ] && printf '%s\n' "$_lf_v"
    return 0
}
lane_fields_tsv() {  # → one tab-separated row per defined lane, in SALA_LANE_FIELDS order (an empty field stays empty)
    local l f row v t=$'\t'
    for l in $SALA_LANES_DEFINED; do
        row=""; for f in $SALA_LANE_FIELDS; do v=""; _lane_field_r v "$l" "$f"; row="$row$v$t"; done
        printf '%s\n' "${row%"$t"}"
    done
}
lane_field_valid() {  # <field> <value> → 0 when the value is one the spec allows (a free-text field: always)
    local allowed=""
    case "$1" in
        provider) allowed="anthropic openai google google-vertex amazon-bedrock azure" ;;
        client) allowed="claude-code claude-agent-sdk codex gemini-cli" ;;
        billing) allowed="subscription usage" ;;
        payment) allowed="prepaid postpaid" ;;
        plan) allowed="max_5x max_20x team_standard team_premium chatgpt_plus chatgpt_pro chatgpt_business google_ai_pro google_ai_ultra" ;;
        status) case "$2" in active|inactive|"not set up") return 0;; esac; return 1 ;;
        *) return 0 ;;
    esac
    case " $allowed " in *" $2 "*) return 0;; esac
    return 1
}
lane_fields_problems() {  # <lane> → one line per field that breaks the spec (a value outside its list, usage with a plan, subscription with a payment, no account); nothing when it holds
    local l="$1" f v u bill pay plan
    for f in provider client billing payment plan status; do
        v=""; _lane_field_r v "$l" "$f"; [ -z "$v" ] && case "$f" in payment|plan) continue;; esac
        _lane_varid_r u "$l"
        lane_field_valid "$f" "$v" || echo "$l lane: $f '$v' is not one the lane fields allow (SALA_LANE_${u}_${f^^})"
    done
    bill=""; _lane_field_r bill "$l" billing
    case "$bill" in
        usage) pay=""; _lane_field_r pay "$l" payment; [ -z "$pay" ] && echo "$(lane_shown "$l") lane: usage billing needs a payment (prepaid or postpaid)"
               plan=""; _lane_field_r plan "$l" plan; [ -n "$plan" ] && echo "$(lane_shown "$l") lane: a plan belongs to a subscription, not usage billing" ;;
        subscription) pay=""; _lane_field_r pay "$l" payment; [ -n "$pay" ] && echo "$(lane_shown "$l") lane: a payment (prepaid, postpaid) belongs to usage billing, not a subscription" ;;
    esac
    v=""; _lane_field_r v "$l" account; [ -n "$v" ] || echo "$l lane: no account"
    return 0
}
# THE CREDIT RECORD (lib/api_credit.py has the rule and the format, lib/api-credit.sh the shell side):
# the API key's credit cannot be read, so the refusal is the signal. sdk_window_open → 0 while the key may be used: no refusal on
# record in the last API_CREDIT_RETRY_S seconds (default 6 h). A refusal (the driver's exit 3, a briefing's "credit balance") writes
# the record, and every sdk row launches on subscription-1 until the retry time passes; the first launch after it tries the key
# again, and a call that works removes the record. SALA_LANE_SDK_NOW is the tests' clock. There is no date gate (an earlier version had
# SALA_LANE_SDK_UNTIL); a setting by that name in an old config is ignored.
. "${BASH_SOURCE[0]%/*}/api-credit.sh"
sdk_window_open() { api_credit_ok "${SALA_LANE_SDK_NOW:-}"; }
sdk_closed_why() { local w; w=$(api_credit_when_local); printf 'the API credit refused a call%s' "${w:+ ($w)}"; }   # why the sdk lane is closed, for a message
# lane_effective <lane> → the lane a launch really goes on: sdk after its window → subscription-1 (the credit is gone, the
# key alone bills the workspace and the CLI on the key is the api lane; the launch goes back to the subscription-1 lane after the window expires)
lane_effective() { case "${1:-subscription-1}" in sdk) sdk_window_open && echo sdk || echo subscription-1;; *) lane_norm "${1:-subscription-1}";; esac; }
_lane_effective_r() { local _e; _lane_norm_r _e "${2:-subscription-1}"; if [ "$_e" = sdk ]; then sdk_window_open && _e=sdk || _e=subscription-1; fi; printf -v "$1" %s "$_e"; }   # <var> <lane>: lane_effective in a variable
_lane_default_r() { local _l=""; { IFS= read -r _l < "$SALA_LANE_DEFAULT_FILE"; } 2>/dev/null; _l=${_l//[$' \t\r']/}; _lane_norm_r _l "$_l"; lane_known "$_l" || _l=subscription-1; _lane_effective_r "$1" "$_l"; }
lane_default() { local l; _lane_default_r l; printf '%s\n' "$l"; }
_lane_row_raw_r() { printf -v "$1" %s ""; [ -n "${2:-}" ] && [ -r "$SALA_LANES" ] && _tsv_col_r "$1" "$SALA_LANES" "$2" 2; return 0; }   # <var> <session> → the word in its row as the file holds it (an old name stays old)
_lane_row_r() { _lane_row_raw_r "$1" "${2:-}"; _lane_norm_r "$1" "${!1}"; return 0; }   # <var> <session> → its own lane in <var> (the current name of a renamed lane; a row written before the rename still says awsplatform)
lane_row() { local _l; _lane_row_r _l "${1:-}"; [ -n "$_l" ] && printf '%s\n' "$_l"; return 0; }   # <session> → its own lane, or nothing
_lane_for_session_r() { local _fl; _lane_row_r _fl "${2:-}"; lane_known "$_fl" || _lane_pin_lane_r _fl "${2:-}"; if lane_known "$_fl"; then _lane_effective_r "$1" "$_fl"; else _lane_default_r "$1"; fi; }   # <var> <session>: its row, else its pin's lane (THE PINNED SESSIONS), else the default
lane_for_session() { local l; _lane_for_session_r l "${1:-}"; printf '%s\n' "$l"; }   # <session> → the lane it launches on (its row, else its pin's lane, else the default; no session → the default; an sdk row after the window → subscription-1)
lane_dir() { local _n; _lane_norm_r _n "${1:-}"; case "$_n" in subscription-2) echo "$SALA_LANE_TEAM_DIR";; esac; }   # <lane> → its config directory (subscription-2's: SALA_LANE_TEAM_DIR keeps its name)
lane_rc() { local _n; _lane_norm_r _n "${1:-subscription-1}"; case "$_n" in api|sdk|bedrock|aws-platform) return 1;; esac; return 0; }   # <lane> → 0 when a claude on it can have a Remote Control bridge (a claude.ai login behind it)
lane_plain_path() { case "$1" in ''|*[!A-Za-z0-9/._~+-]*) return 1;; esac; return 0; }   # typed into a shell unquoted: mod_env_prefix's test
lane_plain_word() { case "$1" in ''|*[!A-Za-z0-9._:+-]*) return 1;; esac; return 0; }   # a value typed unquoted after VAR= (a profile name, a region, a model id)
# lane_bedrock_has_profile → 0 when SALA_LANE_BEDROCK_CREDENTIALS_FILE holds a line that is exactly `[<profile>]`. Presence of the
# header only: awk prints nothing and the file's other lines (the key values) are neither kept nor shown.
lane_aws_profile_in() {  # <credentials file> <profile> → 0 when the file holds that header line (the one reader of the file, for both AWS lanes)
    [ -r "$1" ] || return 1
    awk -v h="[$2]" '{ sub(/[ \t\r]+$/, "") } $0 == h { f = 1; exit } END { exit !f }' "$1" 2>/dev/null
}
lane_bedrock_has_profile() { lane_aws_profile_in "$SALA_LANE_BEDROCK_CREDENTIALS_FILE" "$SALA_LANE_BEDROCK_PROFILE"; }
lane_aws_platform_has_profile() { lane_aws_profile_in "$SALA_LANE_AWSPLATFORM_CREDENTIALS_FILE" "$SALA_LANE_AWSPLATFORM_PROFILE"; }
# lane_workspace_id_ok <id> → 0 when it is `wrkspc_` followed by letters, digits or underscores (the shape of the doc's example: wrkspc_ and a run of letters and digits)
lane_workspace_id_ok() { case "${1:-}" in wrkspc_?*) case "${1#wrkspc_}" in *[!A-Za-z0-9_]*) return 1;; esac; return 0;; esac; return 1; }
# lane_check <lane> → 0 when its prerequisites are there; else why not on stdout, 1. Asked before anything is recorded or
# relaunched (lib/lane.sh), and by spawn for the default lane: a pane relaunched onto a lane that cannot launch would sit at
# a login screen or die at its shell, forty times over.
lane_check() {
    local d v _ln
    _lane_norm_r _ln "${1:-}"
    case "$_ln" in
        subscription-1) return 0 ;;
        api) [ -r "$SALA_LANE_API_KEY_FILE" ] || { echo "api lane: the key file $SALA_LANE_API_KEY_FILE is missing or unreadable (SALA_LANE_API_KEY_FILE)"; return 1; }
             [ -s "$SALA_LANE_API_KEY_FILE" ] || { echo "api lane: the key file $SALA_LANE_API_KEY_FILE is empty"; return 1; }
             lane_plain_path "$SALA_LANE_API_KEY_FILE" || { echo "api lane: the key file's path needs shell quoting, which a typed launch line cannot carry: $SALA_LANE_API_KEY_FILE"; return 1; }
             if [ -e "$SALA_LANE_API_WORKSPACE_FILE" ]; then
                 [ -r "$SALA_LANE_API_WORKSPACE_FILE" ] && [ -s "$SALA_LANE_API_WORKSPACE_FILE" ] || { echo "api lane: the workspace-id file $SALA_LANE_API_WORKSPACE_FILE exists but is empty or unreadable (SALA_LANE_API_WORKSPACE_FILE; remove it for a key that needs no header)"; return 1; }
                 lane_plain_path "$SALA_LANE_API_WORKSPACE_FILE" || { echo "api lane: the workspace-id file's path needs shell quoting: $SALA_LANE_API_WORKSPACE_FILE"; return 1; }
             fi
             if [ -n "$SALA_LANE_API_MCP_CONFIG" ] && [ -e "$SALA_LANE_API_MCP_CONFIG" ]; then
                 [ -r "$SALA_LANE_API_MCP_CONFIG" ] && lane_plain_path "$SALA_LANE_API_MCP_CONFIG" || { echo "api lane: the --mcp-config file $SALA_LANE_API_MCP_CONFIG is unreadable or its path needs quoting (SALA_LANE_API_MCP_CONFIG)"; return 1; }
             fi
             return 0 ;;
        subscription-2)
             d=$(lane_dir "$_ln"); v=SALA_LANE_TEAM_DIR   # the config's name for the directory, as before the rename
             [ -n "$d" ] && [ -d "$d" ] || { echo "$(lane_shown "$_ln") lane: not configured — no config directory at ${d:-?} ($v; make one with: CLAUDE_CONFIG_DIR=${d:-<dir>} claude, and log in there once)"; return 1; }
             [ -s "$d/.credentials.json" ] || { echo "$(lane_shown "$_ln") lane: $d is not signed in (no .credentials.json there) — log in once with: CLAUDE_CONFIG_DIR=$d claude"; return 1; }
             lane_plain_path "$d" || { echo "$_ln lane: the config directory's path needs shell quoting, which a typed launch line cannot carry: $d"; return 1; }
             return 0 ;;
        sdk) # the key and the workspace id as api's (read by the driver, not a shell), then what the pane program needs
             sdk_window_open || { echo "sdk lane: $(sdk_closed_why) — a session recorded on sdk launches on subscription-1 until then (API_CREDIT_RETRY_S)"; return 1; }
             [ -r "$SALA_LANE_API_KEY_FILE" ] || { echo "sdk lane: the key file $SALA_LANE_API_KEY_FILE is missing or unreadable (SALA_LANE_API_KEY_FILE)"; return 1; }
             [ -s "$SALA_LANE_API_KEY_FILE" ] || { echo "sdk lane: the key file $SALA_LANE_API_KEY_FILE is empty"; return 1; }
             if [ -e "$SALA_LANE_API_WORKSPACE_FILE" ]; then
                 [ -r "$SALA_LANE_API_WORKSPACE_FILE" ] && [ -s "$SALA_LANE_API_WORKSPACE_FILE" ] || { echo "sdk lane: the workspace-id file $SALA_LANE_API_WORKSPACE_FILE exists but is empty or unreadable (SALA_LANE_API_WORKSPACE_FILE; remove it for a key that needs no header)"; return 1; }
             fi
             [ -n "$SALA_LANE_API_MCP_CONFIG" ] && [ -r "$SALA_LANE_API_MCP_CONFIG" ] || { echo "sdk lane: the --mcp-config file ${SALA_LANE_API_MCP_CONFIG:-(unset)} is missing or unreadable (SALA_LANE_API_MCP_CONFIG) — an SDK session has no claude.ai connector, the file names their stand-ins"; return 1; }
             if [ -n "$SALA_LANE_SDK_CMD" ]; then d=${SALA_LANE_SDK_CMD%% *}; else d=uv; fi
             command -v "$d" >/dev/null 2>&1 || { echo "sdk lane: '$d' is not on PATH (the driver runs under it: uv run --with $SALA_LANE_SDK_PIN, or SALA_LANE_SDK_CMD)"; return 1; }
             [ -r "$SALA_ROOT/contrib/sdk-pane/driver.py" ] || { echo "sdk lane: the driver $SALA_ROOT/contrib/sdk-pane/driver.py is missing"; return 1; }
             lane_plain_path "$SALA_BIN" || { echo "sdk lane: salamander's own path needs shell quoting, which a typed launch line cannot carry: $SALA_BIN"; return 1; }
             [ -x "$SALA_CLAUDE" ] || { echo "sdk lane: no claude launcher at $SALA_CLAUDE (SALA_CLAUDE) — the SDK is pointed at sala's own CLI"; return 1; }
             return 0 ;;
        bedrock) # the AWS profile's own key, the --mcp-config file as api's, sala's launcher; nothing here reads a value
             [ -n "$SALA_LANE_BEDROCK_PROFILE" ] || { echo "bedrock lane: the AWS profile is not set — put SALA_LANE_BEDROCK_PROFILE=<profile name> in the sala config (the profile's key lives in $SALA_LANE_BEDROCK_CREDENTIALS_FILE)"; return 1; }
             lane_plain_word "$SALA_LANE_BEDROCK_PROFILE" || { echo "bedrock lane: the profile name '$SALA_LANE_BEDROCK_PROFILE' is empty or has characters a typed launch line cannot carry (SALA_LANE_BEDROCK_PROFILE)"; return 1; }
             case "${SALA_LANE_BEDROCK_PROFILE,,}" in *admin*) echo "bedrock lane: the profile must be the lane's own key, not an administrator profile (SALA_LANE_BEDROCK_PROFILE)"; return 1;; esac
             lane_bedrock_has_profile || { echo "bedrock lane: no [$SALA_LANE_BEDROCK_PROFILE] profile in $SALA_LANE_BEDROCK_CREDENTIALS_FILE — run the key-entry script to add it"; return 1; }
             v=""; _lane_field_r v bedrock region
             [ -n "$v" ] || { echo "bedrock lane: the AWS region is not set — put SALA_LANE_BEDROCK_REGION=<region> in the sala config (for example us-east-1; the region where your Bedrock access is enabled)"; return 1; }
             for d in "$v" "$SALA_LANE_BEDROCK_OPUS_MODEL" "$SALA_LANE_BEDROCK_SONNET_MODEL" "$SALA_LANE_BEDROCK_HAIKU_MODEL"; do
                 lane_plain_word "$d" || { echo "bedrock lane: the region or a model id is empty or has characters a typed launch line cannot carry (SALA_LANE_BEDROCK_REGION, SALA_LANE_BEDROCK_OPUS_MODEL, _SONNET_MODEL, _HAIKU_MODEL)"; return 1; }
             done
             case "$SALA_LANE_BEDROCK_PREFIX" in us|eu|apac|jp|au|global) ;; *) echo "bedrock lane: the region prefix '$SALA_LANE_BEDROCK_PREFIX' is not one of us eu apac jp au global (SALA_LANE_BEDROCK_PREFIX)"; return 1;; esac
             if [ -n "$SALA_LANE_API_MCP_CONFIG" ] && [ -e "$SALA_LANE_API_MCP_CONFIG" ]; then
                 [ -r "$SALA_LANE_API_MCP_CONFIG" ] && lane_plain_path "$SALA_LANE_API_MCP_CONFIG" || { echo "bedrock lane: the --mcp-config file $SALA_LANE_API_MCP_CONFIG is unreadable or its path needs quoting (SALA_LANE_API_MCP_CONFIG)"; return 1; }
             fi
             [ -x "$SALA_CLAUDE" ] || { echo "bedrock lane: no claude launcher at $SALA_CLAUDE (SALA_CLAUDE)"; return 1; }
             return 0 ;;
        aws-platform) # Claude Platform on AWS: the profile's own key as bedrock's, a workspace id, the --mcp-config file, sala's launcher; nothing here reads a value
             [ -n "$SALA_LANE_AWSPLATFORM_PROFILE" ] || { echo "aws-platform lane: the AWS profile is not set — put SALA_LANE_AWSPLATFORM_PROFILE=<profile name> in the sala config (the profile's key lives in $SALA_LANE_AWSPLATFORM_CREDENTIALS_FILE)"; return 1; }
             lane_plain_word "$SALA_LANE_AWSPLATFORM_PROFILE" || { echo "aws-platform lane: the profile name '$SALA_LANE_AWSPLATFORM_PROFILE' is empty or has characters a typed launch line cannot carry (SALA_LANE_AWSPLATFORM_PROFILE)"; return 1; }
             case "${SALA_LANE_AWSPLATFORM_PROFILE,,}" in *admin*) echo "aws-platform lane: the profile must be the lane's own key, not an administrator profile (SALA_LANE_AWSPLATFORM_PROFILE)"; return 1;; esac
             [ -n "$SALA_LANE_AWSPLATFORM_WORKSPACE_ID" ] || { echo "aws-platform lane: no workspace id yet — set SALA_LANE_AWSPLATFORM_WORKSPACE_ID to the wrkspc_… id of the Claude Platform on AWS workspace (not a secret; the lane cannot launch without it)"; return 1; }
             lane_workspace_id_ok "$SALA_LANE_AWSPLATFORM_WORKSPACE_ID" || { echo "aws-platform lane: SALA_LANE_AWSPLATFORM_WORKSPACE_ID is not a workspace id (wrkspc_ followed by letters, digits or underscores)"; return 1; }
             lane_aws_platform_has_profile || { echo "aws-platform lane: no [$SALA_LANE_AWSPLATFORM_PROFILE] profile in $SALA_LANE_AWSPLATFORM_CREDENTIALS_FILE — run the key-entry script to add it"; return 1; }
             v=""; _lane_field_r v aws-platform region
             [ -n "$v" ] || { echo "aws-platform lane: the AWS region is not set — put SALA_LANE_AWSPLATFORM_REGION=<region> in the sala config (the region of your Claude Platform on AWS workspace; the endpoint is aws-external-anthropic.<region>.api.aws)"; return 1; }
             for d in "$v" "$SALA_LANE_AWSPLATFORM_OPUS_MODEL" "$SALA_LANE_AWSPLATFORM_SONNET_MODEL" "$SALA_LANE_AWSPLATFORM_HAIKU_MODEL"; do
                 lane_plain_word "$d" || { echo "aws-platform lane: the region or a model id is empty or has characters a typed launch line cannot carry (SALA_LANE_AWSPLATFORM_REGION, SALA_LANE_AWSPLATFORM_OPUS_MODEL, _SONNET_MODEL, _HAIKU_MODEL)"; return 1; }
             done
             if [ -n "$SALA_LANE_API_MCP_CONFIG" ] && [ -e "$SALA_LANE_API_MCP_CONFIG" ]; then
                 [ -r "$SALA_LANE_API_MCP_CONFIG" ] && lane_plain_path "$SALA_LANE_API_MCP_CONFIG" || { echo "aws-platform lane: the --mcp-config file $SALA_LANE_API_MCP_CONFIG is unreadable or its path needs quoting (SALA_LANE_API_MCP_CONFIG)"; return 1; }
             fi
             [ -x "$SALA_CLAUDE" ] || { echo "aws-platform lane: no claude launcher at $SALA_CLAUDE (SALA_CLAUDE)"; return 1; }
             return 0 ;;
        *) echo "unknown lane '${1:-}' (one of: $SALA_LANES_KNOWN)"; return 1 ;;
    esac
}
# lane_env_names <lane> → the environment variables the lane puts on the launch line, space-separated (what `sala lane
# --dry-run` shows: names, never values); nothing for subscription-1
lane_env_names() {
    local _ln; _lane_norm_r _ln "${1:-subscription-1}"
    case "$_ln" in
        api) printf 'ANTHROPIC_API_KEY'; [ -r "$SALA_LANE_API_WORKSPACE_FILE" ] && printf ' ANTHROPIC_CUSTOM_HEADERS'; echo ' ENABLE_PROMPT_CACHING_1H' ;;   # the last: a long-lived pane's line only, never a job (lane_env_prefix)
        sdk) printf 'ANTHROPIC_API_KEY'; [ -r "$SALA_LANE_API_WORKSPACE_FILE" ] && printf ' ANTHROPIC_CUSTOM_HEADERS'; echo ;;   # handed to the CLI by the driver, nothing on the typed line (no cache switch: the driver's own call)
        subscription-2) echo CLAUDE_CONFIG_DIR ;;
        bedrock) echo AWS_PROFILE CLAUDE_CODE_USE_BEDROCK AWS_REGION ANTHROPIC_BEDROCK_REGION_PREFIX ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ENABLE_PROMPT_CACHING_1H_BEDROCK ;;   # no secret among them: the AWS keys are the profile's, read by the CLI; the last is for a long-lived pane only, never a job (lane_env_prefix)
        aws-platform) echo AWS_PROFILE CLAUDE_CODE_USE_ANTHROPIC_AWS ANTHROPIC_AWS_WORKSPACE_ID AWS_REGION ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ENABLE_PROMPT_CACHING_1H ;;   # no secret among them: the AWS keys are the profile's, read by the CLI; the last is for a long-lived pane only, never a job (lane_env_prefix)
    esac
}
# lane_unset_names <lane> → the variables a lane's launch line unsets first (`env -u`), the ones that would change its routing or signing.
# aws-platform: Bedrock and Foundry take precedence over Claude Platform on AWS (the doc), and a workspace API key takes precedence over SigV4.
lane_unset_names() { local _n; _lane_norm_r _n "${1:-}"; case "$_n" in aws-platform) echo CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_FOUNDRY ANTHROPIC_AWS_API_KEY ;; esac; }
lane_unset_args() { local n o="" names; names=$(lane_unset_names "${1:-}"); for n in $names; do o="$o -u $n"; done; echo "${o# }"; }   # → "-u A -u B"
# lane_env_prefix <lane> [job] → "VAR=… " for a claude launch line typed into a pane's shell (spawn, resume_cmd); nothing for subscription-1.
# bedrock, a pane only: ENABLE_PROMPT_CACHING_1H_BEDROCK=1 (the CLI writes the 1-hour prompt cache there, as on the subscription-1 lane; without it a
# long-lived pane on Bedrock writes the 5-minute one and a wake after five idle minutes rewrites its whole context). The second argument
# `job` (lane_job_env) leaves it off: a one-shot `claude -p` never reuses a cache entry past five minutes, and the 1-hour write costs more.
# api and aws-platform, a pane only: ENABLE_PROMPT_CACHING_1H=1 (Claude Code 2.1.312: "5 minutes unless ENABLE_PROMPT_CACHING_1H=1" for an API key
# or any provider but a Claude subscription; the _BEDROCK variant is read only when the provider is bedrock, and aws-platform's is anthropicAws).
# subscription-1 and subscription-2 are subscriptions (billing=subscription) and get the 1 hour on their own; sdk's line is no `claude` line. Same `job` rule.
# POSIX shells (bash, zsh, sh): `$(cat <path>)` inside double quotes is run by the pane's shell, so the value never appears
# in what sala types or logs; the paths are absolute and unquoted (lane_check refused any that would need quoting).
lane_env_prefix() {
    local _ln; _lane_norm_r _ln "${1:-subscription-1}"
    case "$_ln" in
        api)  printf 'ANTHROPIC_API_KEY="$(cat %s)" ' "$SALA_LANE_API_KEY_FILE"
              [ -r "$SALA_LANE_API_WORKSPACE_FILE" ] && printf 'ANTHROPIC_CUSTOM_HEADERS="anthropic-workspace-id: $(cat %s)" ' "$SALA_LANE_API_WORKSPACE_FILE"
              [ "${2:-}" = job ] || printf 'ENABLE_PROMPT_CACHING_1H=1 ' ;;
        subscription-2) printf 'CLAUDE_CONFIG_DIR=%s ' "$SALA_LANE_TEAM_DIR" ;;   # lane_dir subscription-2, without the subshell
        bedrock) local _reg; _lane_field_r _reg bedrock region; printf 'AWS_PROFILE=%s CLAUDE_CODE_USE_BEDROCK=1 AWS_REGION=%s ANTHROPIC_BEDROCK_REGION_PREFIX=%s ANTHROPIC_DEFAULT_OPUS_MODEL=%s ANTHROPIC_DEFAULT_SONNET_MODEL=%s ANTHROPIC_DEFAULT_HAIKU_MODEL=%s ' \
                 "$SALA_LANE_BEDROCK_PROFILE" "$_reg" "$SALA_LANE_BEDROCK_PREFIX" "$SALA_LANE_BEDROCK_OPUS_MODEL" "$SALA_LANE_BEDROCK_SONNET_MODEL" "$SALA_LANE_BEDROCK_HAIKU_MODEL"
                 [ "${2:-}" = job ] || printf 'ENABLE_PROMPT_CACHING_1H_BEDROCK=1 ' ;;   # names and ids: lane_check refused any that needs quoting
        aws-platform) local _rap _ru; _lane_field_r _rap aws-platform region; _ru=$(lane_unset_args aws-platform); printf 'env %s AWS_PROFILE=%s CLAUDE_CODE_USE_ANTHROPIC_AWS=1 ANTHROPIC_AWS_WORKSPACE_ID=%s AWS_REGION=%s ANTHROPIC_DEFAULT_OPUS_MODEL=%s ANTHROPIC_DEFAULT_SONNET_MODEL=%s ANTHROPIC_DEFAULT_HAIKU_MODEL=%s ' "$_ru" \
                 "$SALA_LANE_AWSPLATFORM_PROFILE" "$SALA_LANE_AWSPLATFORM_WORKSPACE_ID" "$_rap" "$SALA_LANE_AWSPLATFORM_OPUS_MODEL" "$SALA_LANE_AWSPLATFORM_SONNET_MODEL" "$SALA_LANE_AWSPLATFORM_HAIKU_MODEL"
                 [ "${2:-}" = job ] || printf 'ENABLE_PROMPT_CACHING_1H=1 ' ;;   # `env -u …` first: Bedrock and Foundry win the routing and an API key wins over SigV4, so the line makes sure none is there; names and ids otherwise, lane_check refused any that needs quoting
    esac
    return 0
}
# lane_args <lane> → the arguments the lane adds after the command (" --mcp-config <file>" on api when the file is there, as
# the hand-made lane-relaunch.sh did: the claude.ai connectors are gone under a key, that file names their stand-ins)
lane_args() {
    local _ln; _lane_norm_r _ln "${1:-subscription-1}"
    case "$_ln" in api|bedrock|aws-platform) [ -n "$SALA_LANE_API_MCP_CONFIG" ] && [ -r "$SALA_LANE_API_MCP_CONFIG" ] && printf ' --mcp-config %s' "$SALA_LANE_API_MCP_CONFIG" ;; esac
    return 0
}
# permission_mode_args [<lane>] → " --permission-mode <mode>" when the settings.json the relaunched claude will read sets
# `permissions.defaultMode`, else nothing (Thu Oct 29th 2026). Why: `claude --resume <uuid>` restores the permissionMode its
# transcript recorded and ignores the settings' defaultMode, so a pane last in auto mode came back in auto mode after the settings changed to
# another default mode. A flag on the launch line wins over the transcript. Every line that relaunches an interactive claude appends it:
# resume_cmd (revive, recycle, unpark, the watchdog's retries; the sdk lane's pane program is no claude line) and spawn --fork.
# The file: the lane's config directory (subscription-2: SALA_LANE_TEAM_DIR, the CLAUDE_CONFIG_DIR its launch line sets), else $CLAUDE_CONFIG_DIR,
# else ~/.claude. Only that user-level file is read (not a project's .claude/settings*.json, not managed settings).
# The value must be a mode `claude --permission-mode` takes (CLI 2.1.312: acceptEdits auto bypassPermissions manual dontAsk plan, and
# `default`, which it accepts as well); anything else is skipped with a note on stderr, so no unchecked text reaches a typed line.
# A missing or unparseable file, or no defaultMode: nothing, as before.
SALA_PERMISSION_MODES="default acceptEdits plan auto bypassPermissions dontAsk manual"
permission_mode_args() {
    local _ln _d _f _m
    _lane_norm_r _ln "${1:-subscription-1}"
    _d=$(lane_dir "$_ln"); [ -n "$_d" ] || _d="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    _f="$_d/settings.json"; [ -r "$_f" ] || return 0
    _m=$(python3 -I -c 'import json,sys
try:
    v=json.load(open(sys.argv[1])).get("permissions",{}).get("defaultMode","")
except Exception:
    v=""
print(v if isinstance(v,str) else "?")' "$_f" 2>/dev/null) || return 0
    [ -n "$_m" ] || return 0
    case " $SALA_PERMISSION_MODES " in
        *" $_m "*) printf ' --permission-mode %s' "$_m" ;;
        *) echo "sala: $_f sets permissions.defaultMode to an unknown mode; the relaunch passes no --permission-mode (known: $SALA_PERMISSION_MODES)" >&2 ;;
    esac
    return 0
}
# THE LANE FOR A JOB (scheduled jobs that call a model can run on a lane of their own, bedrock for one). A systemd unit has no launch
# line to type a prefix on, so `salamander lane env <lane>` and `salamander lane exec <lane> -- CMD…` hand a job the same environment
# lane_env_prefix builds: ONE source (the lane's own fields: profile, region, prefix, the pinned model ids), nothing pasted into the units.
# lane_job_env <lane> → NAME=value lines on stdout, one per variable the lane sets (nothing for subscription-1); returns 1, saying why on stdout, for an
# unknown lane, a lane with no environment to hand (api and sdk read a key file in a shell) or one lane_check refuses. Words only:
# lane_check refused any value a typed line could not carry, so none needs quoting; no secret is among them (the AWS keys are the profile's).
lane_job_env() {
    local _ln w skip=0 prefix why; _lane_norm_r _ln "${1:-}"
    lane_known "$_ln" || { echo "unknown lane '${1:-}' (one of: $SALA_LANES_KNOWN)"; return 1; }
    case "$_ln" in api|sdk) echo "the $_ln lane reads its key from a file in a shell and has no environment to hand a job"; return 1;; esac
    why=$(lane_check "$_ln") || { echo "$why"; return 1; }
    prefix=$(lane_env_prefix "$_ln" job)   # job: without the pane-only 1-hour cache switch
    for w in $prefix; do   # unquoted on purpose: words only, no glob characters (lane_plain_word)
        if [ "$skip" = 1 ]; then skip=0; continue; fi
        case "$w" in env) ;; -u) skip=1 ;; *=*) printf '%s\n' "$w" ;; esac
    done
    return 0
}
# lane_job_unset → the variables a job starts without when it runs on a lane, whichever lane (max included): whatever would change which
# provider or login signs the call (a key, a bearer token, a switch, a stray config directory), held by the unit manager, a script or the pane
# the job was started from. The first words are fixed; the rest is DERIVED from the lanes' own definitions (lane_env_names and lane_unset_names
# of every lane in SALA_LANES_KNOWN: profile, region, workspace id, the pinned ANTHROPIC_DEFAULT_*_MODEL ids, the cache switches), so a name a
# lane starts to set is unset for the others with no list to keep (tests/aws-platform-lane.sh fails when one escapes). One list for every
# target lane: the target's own pairs follow the -u words in job_env_args and set again what they unset.
lane_job_unset() {
    local _l _n _out=" "
    for _n in ANTHROPIC_API_KEY ANTHROPIC_CUSTOM_HEADERS ANTHROPIC_AUTH_TOKEN AWS_BEARER_TOKEN_BEDROCK CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_ANTHROPIC_AWS CLAUDE_CODE_USE_FOUNDRY CLAUDE_CONFIG_DIR \
              $(for _l in $SALA_LANES_KNOWN; do lane_env_names "$_l"; lane_unset_names "$_l"; done); do
        case "$_out" in *" $_n "*) ;; *) _out="$_out$_n " ;; esac
    done
    _out=${_out# }; echo "${_out% }"
}
# job_env_args <lane> → JOB_ENV (an array: `env`'s own arguments, -u for each lane_job_unset name, then the lane's NAME=value pairs) for
# `env "${JOB_ENV[@]}" CMD…`; returns 1 with JOB_ENV_WHY when the lane cannot be handed to a job. subscription-1 too: it sets nothing, so its array is
# the -u words alone (a job on subscription-1 starts clean of the variables another lane's pane passes down to what it starts).
job_env_args() {
    local _ln w l; JOB_ENV=(); JOB_ENV_WHY=""; _lane_norm_r _ln "${1:-}"
    w=$(lane_job_env "$_ln") || { JOB_ENV_WHY=$w; return 1; }
    for l in $(lane_job_unset); do JOB_ENV+=(-u "$l"); done
    while IFS= read -r l; do [ -n "$l" ] && JOB_ENV+=("$l"); done <<< "$w"
    return 0
}
lane_note() { local l; l=$(lane_for_session "${1:-}"); [ "$l" = subscription-1 ] || printf ' (lane %s)' "$(lane_shown "$l")"; }   # <session> → " (lane api)" for a summary row (a subscription lane by its display name, the others by code), nothing on subscription-1
# proc_lane <claude-pid> → the lane a live claude RUNS on, from its environment (Linux: /proc/<pid>/environ, the one place
# sala reads a process's env besides pgrep_mine and work_children); "?" where it cannot be read (macOS, another user). The
# key's presence is tested, never its value; CLAUDE_CONFIG_DIR is a path. A CLI the Agent SDK spawned carries
# CLAUDE_CODE_ENTRYPOINT=sdk-py (set by the SDK itself) beside the key: the sdk lane, asked first.
_proc_lane_r() {  # <var> <claude-pid> → the lane in <var>, no subshell (watch asks for every pane on every tick)
    local e="/proc/${2:-0}/environ" d t kv sdk=0 bed=0 aws=0 key=0 dir="" gotdir=0 td
    [ -r "$e" ] || { printf -v "$1" %s "?"; return 0; }
    # one read of the NUL-separated environment (it was four greps, a tr, a sed and a head per call); the checks and their order are the same
    _nul_read "$e"
    for kv in ${_NUL[@]+"${_NUL[@]}"}; do
        case "$kv" in
            CLAUDE_CODE_ENTRYPOINT=sdk-*) sdk=1 ;;
            CLAUDE_CODE_USE_BEDROCK=1) bed=1 ;;
            CLAUDE_CODE_USE_ANTHROPIC_AWS=1) aws=1 ;;
            ANTHROPIC_API_KEY=?*) key=1 ;;
            CLAUDE_CONFIG_DIR=*) [ "$gotdir" = 1 ] || { dir=${kv#CLAUDE_CONFIG_DIR=}; gotdir=1; } ;;
        esac
    done
    [ "$sdk" = 1 ] && { printf -v "$1" %s sdk; return 0; }
    [ "$bed" = 1 ] && { printf -v "$1" %s bedrock; return 0; }   # the flag alone (no key in this lane's environment)
    [ "$aws" = 1 ] && { printf -v "$1" %s aws-platform; return 0; }   # after bedrock (Bedrock wins the CLI's routing too); the flag alone
    [ "$key" = 1 ] && { printf -v "$1" %s api; return 0; }
    d=${dir%%$'\n'*}
    [ -n "$d" ] || { printf -v "$1" %s subscription-1; return 0; }
    for t in subscription-2; do
        td=$SALA_LANE_TEAM_DIR   # lane_dir subscription-2, without the subshell
        [ "$d" = "$td" ] && { printf -v "$1" %s "$t"; return 0; }
        [ "$(readlink -f "$d" 2>/dev/null)" = "$(readlink -f "$td" 2>/dev/null)" ] && [ -n "$(readlink -f "$d" 2>/dev/null)" ] && { printf -v "$1" %s "$t"; return 0; }
    done
    printf -v "$1" %s other   # a config directory sala does not know: launched by hand
    return 0
}
proc_lane() { local _pl; _proc_lane_r _pl "${1:-0}"; printf '%s\n' "$_pl"; }
_lane_running_r() { _proc_lane_r "$1" "${2:-0}"; [ "${!1}" = "?" ] && _lane_for_session_r "$1" "${3:-}"; return 0; }   # <var> <claude-pid> <session>: lane_running without the subshells
lane_running() { local l; _lane_running_r l "${1:-0}" "${2:-}"; echo "$l"; }   # <claude-pid> <session> → what it runs on, the recorded lane where the env is unreadable
# the writes: one editor at a time (flock on fd 3; 4 the CLI update, 5 sets, 6 the map, 7 resume, 8 inbox, 9 recycle),
# a temp file next to the table, one line per change in lanes.log (time, op, session, old → new, who)
lane_log() { mkdir -p "$SALA_STATE_DIR" 2>/dev/null; printf '%s\t%s\t%s\t%s\t%s\n' "$(date -Is)" "$1" "$2" "$3" "${SALA_LEDGER_CALLER:-$(lock_who 2>/dev/null)}" >> "$SALA_LANE_LOG" 2>/dev/null || true; }
_lane_locked() {
    mkdir -p "$SALA_STATE_DIR" 2>/dev/null
    command -v flock >/dev/null 2>&1 || { "$@"; return; }
    ( flock -w 30 3 || { echo "lanes: the table's lock is held — not written" >&2; exit 1; }; "$@" ) 3>>"$SALA_LANES.lock"
}
_lane_put() {  # <session> <lane>
    local f="$SALA_LANES" t="$SALA_LANES.t.${BASHPID:-$$}" old raw new; _lane_row_raw_r raw "$1"; _lane_norm_r old "$raw"; _lane_norm_r new "$2"
    [ "$raw" = "$new" ] && return 0   # the file already says exactly this (an old name in the row is not "already": it is rewritten below)
    { [ -r "$f" ] && awk -F'\t' -v OFS='\t' -v s="$1" '$1!=s { if ($2 == "awsplatform") $2 = "aws-platform"; print }' "$f"; printf '%s\t%s\n' "$1" "$new"; } | LC_ALL=C sort > "$t" && mv -f "$t" "$f" || { rm -f "$t"; echo "lanes: could not write $f" >&2; return 1; }
    [ "$old" = "$new" ] || lane_log set "$1" "${old:-(default)} → $new"
}
_lane_del() {  # <session>
    local t="$SALA_LANES.t.${BASHPID:-$$}" old; old=$(lane_row "$1"); [ -n "$old" ] || return 0
    awk -F'\t' -v OFS='\t' -v s="$1" '$1!=s { if ($2 == "awsplatform") $2 = "aws-platform"; print }' "$SALA_LANES" > "$t" && mv -f "$t" "$SALA_LANES" || { rm -f "$t"; return 1; }
    lane_log drop "$1" "$old → (default)"
}
_lane_mv() { local l; l=$(lane_row "$1"); [ -n "$l" ] || return 0; _lane_del "$1" && _lane_put "$2" "$l"; }   # <old> <new>
lane_write() { local l; lane_known "${2:-}" || return 1; _lane_norm_r l "$2"; _lane_locked _lane_put "$1" "$l" || return $?; sessions_set "$1" "lane=$l"; }   # <session> <lane> (the registry row copies it once the table's lock is released)
lane_drop() { lane_home_clear "$1"; [ -r "$SALA_LANES" ] || return 0; _lane_locked _lane_del "$1"; }         # <session> — retire (its lane fallback home record goes too)
lane_rename() { lane_home_rename "$1" "$2"; lane_pin_rename "$1" "$2"; [ -r "$SALA_LANES" ] || return 0; _lane_locked _lane_mv "$1" "$2"; }   # <old> <new> — rename (the home record with it)
lane_set_default() {  # <lane>
    lane_known "${1:-}" || return 1; local new old raw t="$SALA_LANE_DEFAULT_FILE.t.$$"; _lane_norm_r new "$1"; old=$(lane_default)
    raw=""; { IFS= read -r raw < "$SALA_LANE_DEFAULT_FILE"; } 2>/dev/null; raw=${raw//[$' \t\r']/}; [ "$old" = "$new" ] && [ "$raw" = "$new" ] && return 0   # an old name in the file is rewritten, not "already"
    mkdir -p "$SALA_STATE_DIR" 2>/dev/null; printf '%s\n' "$new" > "$t" && mv -f "$t" "$SALA_LANE_DEFAULT_FILE" || { rm -f "$t"; return 1; }
    [ "$old" = "$new" ] || lane_log default - "$old → $new"
}
# THE PINNED SESSIONS. A pinned session is held out of every BULK lane move: it stays on its lane unless a move NAMES it
# (`salamander lane <lane> <session>`). The list is a plain TSV, one "<session>\t<lane>" row per pinned session, in the state dir
# beside lanes.tsv (SALA_LANE_PINS overrides the path); a line starting with # is a comment. It ships absent, so nothing is pinned
# until the operator pins one (`salamander lane pin <session> <lane>`, `lane unpin <session>`, `lane pins`, or by editing the file).
# The lane in a row is the lane the session is held on: a session with no row of its own in lanes.tsv launches there, not on the
# default, so a change of the default never re-homes it. A row in lanes.tsv (an explicit move) still wins over the pin.
#
# FOR A MOVER THAT PICKS SESSIONS ITSELF (the switch's --all, `lane default`, `lane fallback`, the back agents' rule; and any automatic
# mover added later, such as a fallback onto another lane when a lane runs out): call these, never re-implement the test.
#   lane_is_pinned <session>          rc 0 when the session is pinned
#   lane_pin_of <session>             the lane it is pinned to (stdout; nothing when it is not pinned)
#   pinned_skip_note <session>        "skipped (pinned to <lane>): <session>" on stdout, rc 0; rc 1 and nothing for an unpinned session
#   lane_pins_split <session>…        sets PIN_MOVE (the unpinned ones, in order) and PIN_SKIP (the pinned ones); the mover moves PIN_MOVE
#                                     and prints pinned_skip_note for each of PIN_SKIP, in its dry run too
# A move that names the session (`lane <lane> <session>`) does not call these to skip it; it says pinned_moving_note once and moves.
: "${SALA_LANE_PINS:=$SALA_STATE_DIR/lane-pins.tsv}"
_lane_pin_row_r() { printf -v "$1" %s ""; case "${2:-}" in ""|"#"*) return 0;; esac; [ -r "$SALA_LANE_PINS" ] && _tsv_row_r "$1" "$SALA_LANE_PINS" "$2"; return 0; }   # <var> <session> → its row, or nothing
_lane_pin_raw_r() { local _row; printf -v "$1" %s ""; _lane_pin_row_r _row "${2:-}"; [ -n "$_row" ] || return 0; if [[ $_row == *$'\t'* ]]; then _row=${_row#*$'\t'}; else _row=""; fi; _row=${_row%%$'\t'*}; _row=${_row//[$' \r']/}; _lane_norm_r _row "$_row"; printf -v "$1" %s "${_row:-?}"; }   # <var> <session> → the pinned lane ("?" for a row naming none), nothing when not pinned
_lane_pin_lane_r() { local _p; printf -v "$1" %s ""; _lane_pin_raw_r _p "${2:-}"; if lane_known "$_p"; then printf -v "$1" %s "$_p"; fi; return 0; }   # <var> <session> → the pinned lane when it is a lane sala knows (the one a launch may use), else nothing
lane_pin_of() { local _p; _lane_pin_raw_r _p "${1:-}"; [ -z "$_p" ] || printf '%s\n' "$_p"; return 0; }
lane_is_pinned() { local _p; _lane_pin_raw_r _p "${1:-}"; [ -n "$_p" ]; }
pinned_skip_note() { local p; p=$(lane_pin_of "${1:-}"); [ -n "$p" ] || return 1; printf 'skipped (pinned to %s): %s\n' "$p" "$1"; }
pinned_moving_note() { local p; p=$(lane_pin_of "${1:-}"); [ -n "$p" ] || return 1; printf 'pinned to %s, moving as asked: %s\n' "$p" "$1"; }
PIN_MOVE=(); PIN_SKIP=()
lane_pins_split() { PIN_MOVE=(); PIN_SKIP=(); local s; for s in "$@"; do if lane_is_pinned "$s"; then PIN_SKIP+=("$s"); else PIN_MOVE+=("$s"); fi; done; return 0; }
_lane_pin_locked() {
    mkdir -p "$(dirname -- "$SALA_LANE_PINS")" 2>/dev/null
    command -v flock >/dev/null 2>&1 || { "$@"; return; }
    ( flock -w 30 3 || { echo "lanes: the pin list's lock is held — not written" >&2; exit 1; }; "$@" ) 3>>"$SALA_LANE_PINS.lock"
}
_lane_pin_put() {  # <session> <lane>: replace the session's row (comments and other rows kept)
    local f="$SALA_LANE_PINS" t="$SALA_LANE_PINS.t.${BASHPID:-$$}"
    { [ -r "$f" ] && awk -F'\t' -v s="$1" '$1!=s' "$f"; printf '%s\t%s\n' "$1" "$2"; } > "$t" && mv -f "$t" "$f" || { rm -f "$t"; echo "lanes: could not write $f" >&2; return 1; }
    lane_log pin "$1" "pinned to $2"
}
_lane_pin_del() {  # <session>
    local f="$SALA_LANE_PINS" t="$SALA_LANE_PINS.t.${BASHPID:-$$}"; lane_is_pinned "$1" || return 0
    awk -F'\t' -v s="$1" '$1!=s' "$f" > "$t" && mv -f "$t" "$f" || { rm -f "$t"; return 1; }
    lane_log unpin "$1" "pin removed"
}
_lane_pin_mv() { local l; l=$(lane_pin_of "$1"); [ -n "$l" ] || return 0; _lane_pin_del "$1" && _lane_pin_put "$2" "$l"; }   # <old> <new>
lane_pin_set() { lane_known "${2:-}" || return 1; local l; _lane_norm_r l "$2"; _lane_pin_locked _lane_pin_put "$1" "$l"; }   # <session> <lane>
lane_pin_clear() { [ -r "$SALA_LANE_PINS" ] || return 0; _lane_pin_locked _lane_pin_del "$1"; }   # <session>
lane_pin_rename() { [ -r "$SALA_LANE_PINS" ] || return 0; _lane_pin_locked _lane_pin_mv "$1" "$2"; }   # <old> <new> — a renamed session stays pinned
# THE AUTOMATIC LANE FALLBACK. A dead lane needs a mechanism that moves its sessions to a live fallback lane
# on its own; they stay there until the operator or a session moves them back. The dormant record (lane-state.tsv, "THE DORMANT RECORD" above) says a lane is dead; this block
# says where its sessions, its default and its jobs go, and keeps where they came from.
#   SALA_LANE_FALLBACK        "<lane>=<fallback> …", one hop only: subscription-1, subscription-2, aws-platform, api and sdk fall back to bedrock, bedrock to subscription-1 (a config that still says max or team works: both are read as the lanes' words).
#                             A lane with no entry, or `none`, has no fallback. The fallback is used ONLY if it is itself active and ready
#                             (lane_fallback_pick: not dormant, lane_check passes, lane_out sees nothing wrong); else nothing moves and the
#                             reason is one alert line.
#   SALA_LANE_FALLBACK_AUTO   on (default) · off: the AUTOMATIC part — the watch's own detection and `lane dormant` queue the move, and
#                             a job whose lane is dormant runs on the fallback. `salamander lane fallback <lane>` (a person's form) works either way.
#   SALA_FALLBACK_NO_FABLE    the lanes a Fable session cannot run on (bedrock: 400 "data retention mode", the trap in memory); a session on
#                             Fable that moves onto one of them is recorded on SALA_FALLBACK_FABLE_MODEL (opus: Opus 5.5 there).
# The record of where a session came from is lane-home.tsv (STATE, beside lanes.tsv): "<session>\t<home lane>\t<when, ISO>\t<model it
# had, or ->". `salamander lane` shows it as the HOME column while the session sits elsewhere. NOTHING moves a session back when its
# lane is active again ("stay"): `salamander lane <home> <session>` does, and the switch clears the row. Moving back restores no model.
: "${SALA_LANE_FALLBACK:=subscription-1=bedrock subscription-2=bedrock aws-platform=bedrock api=bedrock sdk=bedrock bedrock=subscription-1}"
: "${SALA_LANE_FALLBACK_AUTO:=on}"
: "${SALA_FALLBACK_NO_FABLE:=bedrock}"
: "${SALA_FALLBACK_FABLE_MODEL:=opus}"
SALA_LANE_HOME="$SALA_STATE_DIR/lane-home.tsv"
_fw_default="${SALA_OWNER_NAME}'s standing pick \"Move automatically, stay\": \"Move them to the fallback on their own; they stay there until ${SALA_OWNER_NAME} or a session moves them back.\""
: "${SALA_FALLBACK_WORDS:=$_fw_default}"; unset _fw_default   # a default the config may override
lane_fallback_of() {  # <lane> → the lane the map names as its fallback (one hop); fails with nothing when there is none
    local l kv k v; l=$(lane_state_id "${1:-}") || return 1
    for kv in $SALA_LANE_FALLBACK; do
        k=${kv%%=*}; v=${kv#*=}; [ "$k" != "$kv" ] || continue
        k=$(lane_state_id "$k") || continue; [ "$k" = "$l" ] || continue
        case "$v" in ''|none) return 1;; esac
        v=$(lane_state_id "$v") || return 1; [ "$v" != "$l" ] || return 1
        printf '%s\n' "$v"; return 0
    done
    return 1
}
lane_fallback_pick() {  # <lane> → the fallback lane on stdout, 0; or why there is none (plain words), 1. The fallback must be active and ready
    local l f out; l=$(lane_state_id "${1:-}") || { echo "'${1:-}' is not a lane"; return 1; }
    f=$(lane_fallback_of "$l") || { echo "the $(lane_label "$l") lane has no fallback set (SALA_LANE_FALLBACK)"; return 1; }
    if lane_dormant "$f"; then echo "the $(lane_label "$l") lane's fallback, $(lane_label "$f"), is dormant too ($(lane_dormant_since_words "$f"))"; return 1; fi
    if out=$(lane_out "$f"); then echo "the $(lane_label "$l") lane's fallback, $(lane_label "$f"), is not ready: $(paste -sd';' - <<< "$out" | sed 's/;/; /g')"; return 1; fi
    printf '%s\n' "$f"
}
_lane_home_locked() {
    mkdir -p "$SALA_STATE_DIR" 2>/dev/null
    command -v flock >/dev/null 2>&1 || { "$@"; return; }
    ( flock -w 30 3 || { echo "lanes: the home record's lock is held — not written" >&2; exit 1; }; "$@" ) 3>>"$SALA_LANE_HOME.lock"
}
lane_home() { local _h=""; [ -n "${1:-}" ] && [ -r "$SALA_LANE_HOME" ] && _tsv_col_r _h "$SALA_LANE_HOME" "$1" 2; _lane_norm_r _h "$_h"; printf '%s\n' "$_h"; }   # <session> → the lane a fallback moved it off, or nothing
lane_home_model() { local _m=""; [ -n "${1:-}" ] && [ -r "$SALA_LANE_HOME" ] && _tsv_col_r _m "$SALA_LANE_HOME" "$1" 4; [ "$_m" = - ] && _m=""; printf '%s\n' "$_m"; }   # <session> → the model it had before the fallback changed it
_lane_home_put() {  # <session> <home> <model or -> — the FIRST home stays (a second move does not make the fallback its home)
    local f="$SALA_LANE_HOME" t="$SALA_LANE_HOME.t.${BASHPID:-$$}"
    [ -z "$(lane_home "$1")" ] || return 0
    { [ -r "$f" ] && cat "$f"; printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$(lane_iso "$(date +%s)")" "${3:--}"; } | LC_ALL=C sort > "$t" && mv -f "$t" "$f" || { rm -f "$t"; echo "lanes: could not write $f" >&2; return 1; }
    lane_log home "$1" "home $2 (moved by the lane fallback)"
}
_lane_home_del() {  # <session>
    local t="$SALA_LANE_HOME.t.${BASHPID:-$$}" old; old=$(lane_home "$1"); [ -n "$old" ] || return 0
    awk -F'\t' -v s="$1" '$1!=s' "$SALA_LANE_HOME" > "$t" && mv -f "$t" "$SALA_LANE_HOME" || { rm -f "$t"; return 1; }
    lane_log home "$1" "home $old cleared"
}
_lane_home_mv() { local h m; h=$(lane_home "$1"); [ -n "$h" ] || return 0; m=$(lane_home_model "$1"); _lane_home_del "$1" && _lane_home_put "$2" "$h" "${m:--}"; }   # <old> <new>
lane_home_set() { lane_known "${2:-}" || return 1; local h; _lane_norm_r h "$2"; _lane_home_locked _lane_home_put "$1" "$h" "${3:--}"; }   # <session> <home lane> [model it had]
lane_home_clear() { [ -r "$SALA_LANE_HOME" ] || return 0; _lane_home_locked _lane_home_del "$1"; }   # <session> — moved home, retired
lane_home_rename() { [ -r "$SALA_LANE_HOME" ] || return 0; _lane_home_locked _lane_home_mv "$1" "$2"; }   # <old> <new>
session_on_fable() {  # <session> → 0 when its model is a Fable: the recorded one (models.tsv), else the conversation's (its transcript)
    local rec m u; rec=$(model_row "${1:-}")
    if [ -n "$rec" ]; then m=${rec%%$'\t'*}; case "$m" in fable|claude-fable-*) return 0;; esac; return 1; fi
    u=$(sidecar_uuid_for_session "$1" 2>/dev/null) || return 1; [ -n "$u" ] || return 1
    [ "$(model_family_for_uuid "$u")" = fable ]
}
lane_fallback_model_change() {  # <session> <target lane> → "fable<TAB>opus" when the session must change model to run on the lane, else nothing
    case " $SALA_FALLBACK_NO_FABLE " in *" $(lane_state_id "${2:-}") "*) session_on_fable "$1" && printf 'fable\t%s\n' "$SALA_FALLBACK_FABLE_MODEL";; esac
    return 0
}
# lane_fallback_auto <lane> <signal|hand> → queues the move of everything on a lane that just went dormant. 0 queued (the op's id on
# stdout), 1 no usable fallback or not queued (why on stdout: the caller's one alert line), 2 nothing on the lane to move, 3 switched off.
# The queue is the normal path for a fleet operation (`sala op lane fallback`, lib/op.sh): the move runs in a transient sala-op unit
# (no Claude ancestry: both guards admit it), under the recycle lock, one operation at a time, and ends with ONE Slack post.
lane_fallback_auto() {
    local l fb out id; [ "${SALA_LANE_FALLBACK_AUTO:-on}" = off ] && return 3
    l=$(lane_state_id "${1:-}") || return 1
    fb=$(lane_fallback_pick "$l") || { printf '%s\n' "$fb"; return 1; }
    if [ -z "$(lane_sessions_on "$l")" ] && [ "$(lane_default)" != "$l" ]; then return 2; fi
    out=$("$SALA_BIN" op lane fallback "$l" --from sala-watch --words "$SALA_FALLBACK_WORDS" 2>&1) || { printf 'the move onto %s was not queued: %s\n' "$(lane_label "$fb")" "$(printf '%s' "$out" | tail -3 | paste -sd' ' -)"; return 1; }
    id=$(printf '%s\n' "$out" | sed -n 's/^queued op \([0-9-]*\):.*/\1/p' | head -1); printf '%s\n' "${id:-queued}"
    lane_log fallback "$l" "dormant → queued the move onto $fb (op ${id:-?}, ${2:-hand})"
}
# THE BACK AGENTS' LANE RULE (lib/watch.sh `back_lane_tick`, lib/spawn.sh, `sala watch --back-lanes`).
# A standing rule for the BACKGROUND agents (registry rows with role back, or with no role that stackshot's project record lists on a
# project's background: map (lib/sessions.py `back-names`; the watch writes that role onto the row each tick, `sessions tag --auto`); never a
# side session) that keeps them off a login lane
# near its weekly limit, in three steps over an ordered list of lanes (SALA_BACK_LANE_ORDER, first = home):
#   1. the home lane's "This week" limit reaches SALA_BACK_LANE_THRESHOLD percent       → the back agents move to the second lane;
#   2. a pane running on the second lane is stopped on its cap (the limit watch's state) → they move to the third;
#   3. the home lane's weekly limit resets (a fresh reading in a new window, under the threshold) → all of them move home.
# Front agents, jobs (`lane exec`, `sala job`), SALA_LANE_FALLBACK and the dormant record are not part of it. OFF by default.
# A PINNED session (THE PINNED SESSIONS above) is never moved by it: back_lane_movers puts it in BL_PINNED and every outcome line that moves
# (or would move) agents ends with back_lane_pinned_note, "; skipped (pinned to <lane>): <session>", in the dry run too.
#   SALA_BACK_LANE_RULE       off (default) · on
#   SALA_BACK_LANE_ORDER      "<home> <second> <third>" lane ids (an old word works); two lanes make a rule with no step 2
#   SALA_BACK_LANE_THRESHOLD  percent of the home lane's "This week" limit (kind weekly_all), default 90; the model-scoped weekly
#                             limits ("Fable this week") are never read
#   SALA_BACK_LANE_MAX_AGE    seconds: the home lane's reading (sala-web's quota-<lane>.json in SALA_WEB_STATE_DIR, written by web/src/sala_web/quota.py)
#                             older than this, failed (errorKind), without a "This week" percent, or whose window is over moves nobody (default 1800)
#   SALA_BACK_LANE_WORDS      the words the queued operations carry (the owner's standing rule, quoted); the public default describes the rule
#   SALA_BACK_LANE_STATE      the rule's state file (key=value): the lane the back agents stand on by the rule, the window it left home in and,
#                             per step, the window it fired in: a step fires once per weekly window. Default $SALA_STATE_DIR/back-lane.state
#   SALA_BACK_LANE_REFRESH_URL / _EVERY / _WAIT   a reading missing or older than half SALA_BACK_LANE_MAX_AGE is asked for first: a plain GET of sala-web's
#                             /api/quota (a unix socket path, default sala-web's own socket; or an http(s) base URL; or `off`), at most every _EVERY (120) s,
#                             then up to _WAIT (10) s for the file to refresh. sala-web holds the token; a failed call leaves the reading stale and nobody moves
# THE MOVE is `sala op lane <lane> <session>… --from sala-watch --words "$SALA_BACK_LANE_WORDS"`: the queue, the ordinary switch, a busy
# pane deferred and retried, ONE Slack post by the operation. Who moves: the live back agents (a tmux session; not SALA_NO_RELAUNCH, not the
# master) whose lane is in the order and on the wrong side of the target (a step forward moves those before it; the way home those off home);
# a back agent on another lane (api, subscription-2) is left where it is, as is a Fable session when the target is in SALA_FALLBACK_NO_FABLE
# (it would fail there; one notice says so). The target must be active and ready; else nothing moves and one notice says why, once per window.
# A back agent SPAWNED while the rule has them off home lands on the rule's lane (spawn.sh, back_lane_spawn_lane). A failed, missing, stale or
# expired reading, or a dormant home lane, moves nobody. THE CATCH-UP (`back_lane_catchup`): a step fires once per window, so while the rule
# has the agents off home a pass that finds one still on the wrong side (it had no role, or no pane, when the step fired) moves it to the rule's
# lane, once per step (state key `queued`: <lane>|<window>|<names>).
: "${SALA_BACK_LANE_RULE:=off}"
: "${SALA_BACK_LANE_ORDER:=subscription-1 aws-platform bedrock}"
: "${SALA_BACK_LANE_THRESHOLD:=90}"
: "${SALA_BACK_LANE_MAX_AGE:=1800}"
: "${SALA_BACK_LANE_STATE:=$SALA_STATE_DIR/back-lane.state}"
: "${SALA_BACK_LANE_REFRESH_URL:=}"      # where the watch asks for a fresh reading: empty = sala-web's socket (SALA_WEB_SOCKET, else $XDG_RUNTIME_DIR/sala-web/sala-web.sock); a socket path, an http(s) base URL, or off
: "${SALA_BACK_LANE_REFRESH_EVERY:=120}" # seconds between two asks
: "${SALA_BACK_LANE_REFRESH_WAIT:=10}"   # seconds to wait for the refreshed file after the GET (sala-web refreshes in the background)
_bl_words="${SALA_OWNER_NAME}'s standing rule for the background agents: off the home lane near its weekly limit, back when it resets"
: "${SALA_BACK_LANE_WORDS:=$_bl_words}"; unset _bl_words   # a default the config overrides with the owner's own words, quoted
back_lane_on() { case "${SALA_BACK_LANE_RULE:-off}" in on|1|yes|true) return 0;; esac; return 1; }
BL_ORDER=()
back_lane_order() {  # → BL_ORDER (lane ids, the config's words normalised, an unknown word or a repeat dropped); rc 1 with fewer than two lanes
    local w l x; BL_ORDER=()
    for w in $SALA_BACK_LANE_ORDER; do
        l=$(lane_state_id "$w") || continue
        for x in ${BL_ORDER[@]+"${BL_ORDER[@]}"}; do [ "$x" = "$l" ] && continue 2; done
        BL_ORDER+=("$l")
    done
    [ "${#BL_ORDER[@]}" -ge 2 ]
}
back_lane_idx() {  # <lane> → its place in BL_ORDER (0 = home), nothing for a lane outside the order
    local l i; l=$(lane_state_id "${1:-}") || return 1
    for i in "${!BL_ORDER[@]}"; do [ "${BL_ORDER[$i]}" = "$l" ] && { echo "$i"; return 0; }; done
    return 1
}
back_lane_get() { _kv_first "$SALA_BACK_LANE_STATE" "$1"; }
back_lane_put() { mkdir -p "$(dirname -- "$SALA_BACK_LANE_STATE")" 2>/dev/null; [ -e "$SALA_BACK_LANE_STATE" ] || : >> "$SALA_BACK_LANE_STATE"; _kv_set "$SALA_BACK_LANE_STATE" "$1" "$2" bl; }
back_lane_when() { local _o; _when_r _o "$1"; printf '%s' "$_o"; }
back_lane_current() {  # → the lane the rule has the back agents on: the state's, if it is in the order, else home
    back_lane_order || return 1
    local c; c=$(back_lane_get lane)
    if [ -n "$c" ] && c=$(lane_state_id "$c") && back_lane_idx "$c" >/dev/null; then echo "$c"; return 0; fi
    echo "${BL_ORDER[0]}"
}
# back_lane_reading <lane> → "ok<TAB>percent<TAB>window<TAB>reset epoch" (percent rounded down; window = the reset rounded to the minute, a key that
# survives the fractions of a second the endpoint adds), else "bad<TAB>why"; rc 0 / 1. Reads the lane's saved quota answer, nothing else (no call is made).
back_lane_reading() {
    local f="$SALA_WEB_STATE_DIR/quota-$1.json" out
    out=$(python3 -I -S -c '
import json, os, sys, time
from datetime import datetime, timezone
f, maxage = sys.argv[1], float(sys.argv[2])
def bad(w): print("bad\t" + w); sys.exit(1)
try: d = json.load(open(f))
except FileNotFoundError: bad("no saved quota answer (" + os.path.basename(f) + ")")
except Exception: bad("the saved quota answer cannot be read")
if not isinstance(d, dict): bad("the saved quota answer is not an object")
if d.get("errorKind"): bad("the last usage check failed (" + str(d.get("errorKind")) + ")")
if d.get("dormant"): bad("the lane is dormant")
now = time.time()
try: t = float(d["fetchedAt"]) / 1000.0 if d.get("fetchedAt") else os.path.getmtime(f)
except Exception: bad("the saved answer has no usable time")
if now - t > maxage: bad("the reading is %d minutes old (more than %d)" % ((now - t) // 60, maxage // 60))
if t - now > 300: bad("the reading is dated in the future")
lim = next((x for x in (d.get("limits") or []) if isinstance(x, dict) and x.get("label") == "This week"), None)
if lim is None: bad("no \"This week\" limit in the answer")
pct = lim.get("percent")
if isinstance(pct, bool) or not isinstance(pct, (int, float)): bad("the \"This week\" limit has no percent")
try:
    r = datetime.fromisoformat(str(lim.get("resetsAt")).replace("Z", "+00:00"))
    if r.tzinfo is None: r = r.replace(tzinfo=timezone.utc)
    r = r.timestamp()
except Exception: bad("the \"This week\" limit has no reset time")
if r <= now: bad("the reading\x27s window is over (it reset at the time it names)")
print("ok\t%d\t%d\t%d" % (int(pct), int(round(r / 60.0)) * 60, int(r)))' "$f" "$SALA_BACK_LANE_MAX_AGE" 2>/dev/null) || { [ -n "$out" ] || out=$'bad\tthe reading could not be read'; printf '%s\n' "$out"; return 1; }
    printf '%s\n' "$out"
}
# back_lane_age <lane> → the saved quota answer's age in seconds (its fetchedAt, else the file's time), "none" when there is no readable answer
back_lane_age() {
    python3 -I -S -c '
import json, os, sys, time
f = sys.argv[1]
try:
    d = json.load(open(f))
    t = float(d["fetchedAt"]) / 1000.0 if isinstance(d, dict) and d.get("fetchedAt") else os.path.getmtime(f)
    print(max(0, int(time.time() - t)))
except Exception: print("none")' "$SALA_WEB_STATE_DIR/quota-$1.json" 2>/dev/null || echo none
}
# THE READING'S REFRESH. sala-web refreshes quota-<lane>.json only when something asks its /api/quota (a page, or this): it serves the saved answer at once and
# starts the refresh in the background once the answer is 5 minutes old. With nobody on the page the file would age past SALA_BACK_LANE_MAX_AGE and the rule
# could never act on its own, so a pass that finds the home lane's answer missing or older than half the max age asks the local sala-web with a plain GET and
# reads the file again. The token stays in the web app: this makes no call to Anthropic and handles no credential. A failed, slow or refused call changes
# nothing (the answer stays stale and nobody moves). Asked at most every SALA_BACK_LANE_REFRESH_EVERY seconds.
# back_lane_refresh_args → BL_CURL, curl's arguments for the GET, rc 1 when the refresh is off or cannot be made (no curl, no socket)
BL_CURL=()
back_lane_refresh_args() {
    local v=${SALA_BACK_LANE_REFRESH_URL:-}; BL_CURL=()
    case "$v" in off|none|0) return 1;; esac
    command -v curl >/dev/null 2>&1 || return 1
    [ -n "$v" ] || v="${SALA_WEB_SOCKET:-${XDG_RUNTIME_DIR:-/run/user/$EUID}/sala-web/sala-web.sock}"
    case "$v" in "~/"*) v="$HOME/${v#"~/"}";; esac
    case "$v" in
        /*) [ -S "$v" ] || return 1; BL_CURL=(--unix-socket "$v" "http://localhost/api/quota") ;;
        http://*|https://*) BL_CURL=("${v%/}/api/quota") ;;
        *) return 1 ;;
    esac
}
# back_lane_refresh <lane> [--dry-run] → rc 0 with one "refresh:" line when the answer was due and a fresh one was asked for (a dry run: would be); rc 1 otherwise
back_lane_refresh() {
    local lane=$1 age half now last i
    back_lane_refresh_args || return 1
    age=$(back_lane_age "$lane"); half=$(( SALA_BACK_LANE_MAX_AGE / 2 ))
    [ "$age" = none ] || [ "$age" -gt "$half" ] || return 1
    if [ "${2:-}" = --dry-run ]; then
        echo "refresh: the saved $(lane_shown "$lane") reading is $([ "$age" = none ] && echo missing || echo "$age s old (more than $half)"): would ask the local sala-web for a fresh one (GET ${BL_CURL[*]})"
        return 0
    fi
    _now_r now; last=$(back_lane_get refresh_at)
    if [ -n "$last" ] && [ "$now" -ge "$last" ] && [ $(( now - last )) -lt "$SALA_BACK_LANE_REFRESH_EVERY" ]; then return 1; fi
    back_lane_put refresh_at "$now"
    curl -fsS -o /dev/null --max-time 5 "${BL_CURL[@]}" >/dev/null 2>&1 || return 1
    for (( i = 0; i <= SALA_BACK_LANE_REFRESH_WAIT; i++ )); do
        age=$(back_lane_age "$lane")
        if [ "$age" != none ] && [ "$age" -le "$half" ]; then echo "refresh: asked the local sala-web for a fresh $(lane_shown "$lane") reading; it is $age s old now"; return 0; fi
        [ "$i" -lt "$SALA_BACK_LANE_REFRESH_WAIT" ] && sleep 1
    done
    return 1
}
# back_lane_stopped <lane> <after epoch> → 0 with the stop's "since" on stdout when a pane running on <lane> sits stopped on its cap (the limit watch's
# state: kind workspace, "You have reached your specified workspace API usage limits", or credit, billing_error), the stop beginning after <after>
back_lane_stopped() {
    [ -r "$SALA_LIMIT_STATE" ] || return 1
    local rows s since rl want best=""; want=$(lane_state_id "$1") || return 1
    rows=$(python3 -I -S -c '
import json, sys
try: panes = json.load(open(sys.argv[1])).get("panes") or {}
except Exception: sys.exit()
for p in panes.values():
    if isinstance(p, dict) and p.get("lim") in ("workspace", "credit"):
        print("%s\t%s\t%s" % (p.get("s") or "-", int(p.get("since") or 0), p.get("rlane") or "-"))' "$SALA_LIMIT_STATE" 2>/dev/null)
    while IFS=$'\t' read -r s since rl; do
        [ -n "$since" ] || continue
        [ "$since" -gt "${2:-0}" ] 2>/dev/null || continue
        if [ "$rl" != - ]; then rl=$(lane_state_id "$rl") || continue; else [ "$s" != - ] && rl=$(lane_for_session "$s") || continue; fi   # a state from before the pane's running lane was kept: the lane it launches on
        [ "$rl" = "$want" ] || continue
        if [ -z "$best" ] || [ "$since" -lt "$best" ]; then best=$since; fi
    done <<< "$rows"
    [ -n "$best" ] && { echo "$best"; return 0; }
    return 1
}
back_lane_names() {  # → the live back agents, one per line: a registry row with role back and no side, whose tmux session exists; a row with no role counts by what the project record's agents map says of it (lib/sessions.py back-names)
    sessions_on && [ -r "$SALA_SESSIONS_FILE" ] || return 0
    local s names
    names=$(sessions_py back-names --record "$SALA_PROJECT_RECORD" --record-max-age "$SALA_PROJECT_RECORD_MAX_AGE" 2>/dev/null)
    while IFS= read -r s; do [ -n "$s" ] && tmux has-session -t "=$s" 2>/dev/null && echo "$s"; done <<< "$names"
    return 0
}
# back_lane_movers <target lane> → BL_MOVE (who goes), BL_STAY (a Fable session the target cannot run) and BL_PINNED (a pinned session the
# move would otherwise have taken: held out, THE PINNED SESSIONS above); the rule above says who counts
BL_MOVE=(); BL_STAY=(); BL_PINNED=()
back_lane_pinned_note() {  # → "; skipped (pinned to <lane>): <session>; …" for BL_PINNED, nothing when none
    local s o=""; for s in ${BL_PINNED[@]+"${BL_PINNED[@]}"}; do o="$o; $(pinned_skip_note "$s")"; done; printf '%s' "$o"
}
back_lane_movers() {
    BL_MOVE=(); BL_STAY=(); BL_PINNED=(); local t ti s e ei; back_lane_order || return 1; t=$(lane_state_id "$1") || return 1; ti=$(back_lane_idx "$t") || return 1
    while IFS= read -r s; do
        [ -n "$s" ] || continue; no_relaunch "$s" && continue; [ "$s" = "${SALA_MASTER:-}" ] && continue
        e=$(lane_for_session "$s"); ei=$(back_lane_idx "$e") || continue            # a lane outside the order is not the rule's
        if [ "$ti" -eq 0 ]; then [ "$ei" -gt 0 ] || continue; else [ "$ei" -lt "$ti" ] || continue; fi
        if lane_is_pinned "$s"; then BL_PINNED+=("$s"); continue; fi                 # held out of a bulk move (THE PINNED SESSIONS)
        case " $SALA_FALLBACK_NO_FABLE " in *" $t "*) if session_on_fable "$s"; then BL_STAY+=("$s"); continue; fi;; esac
        BL_MOVE+=("$s")
    done < <(back_lane_names)
    return 0
}
# back_lane_same_window <key> <recorded> → 0 when the two window keys name the same weekly window (the endpoint's reset time moves by fractions of a second)
back_lane_same_window() { [ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt $(( $2 + 3600 )) ] && [ "$1" -gt $(( $2 - 3600 )) ]; }
back_lane_commit() {  # <step> <target> <window key> <target's place> [<the names queued, space-separated>] — the rule's state after a step; a step home clears the way out
    back_lane_put lane "$2"; back_lane_put moved_at "$(printf '%(%s)T' -1)"; back_lane_put "f$4" "$3"; back_lane_put blocked ""
    if [ "$1" = 3 ]; then back_lane_put window ""; back_lane_put queued ""; else
        [ "$1" != 1 ] || back_lane_put window "$3"
        local nm=${5:-}; back_lane_put queued "$2|$3|${nm// /,}"   # who the rule has queued onto this lane in this window: the catch-up below never queues a name twice
    fi
}
# THE CATCH-UP: a back agent that is on the wrong side of the rule's lane while the rule holds the back agents off home (one the step found no role for,
# a pane spawned or tagged since, a name that was not live when the step fired) is queued onto the rule's lane at the next pass, once per window: the
# state's `queued` (<lane>|<window key>|<names>) keeps the names already queued in this window, so a pane the move could not close yet (a busy one,
# retried by the operation itself) is not queued again. A state with no `queued` (written before the catch-up) queues every back agent still home once.
# back_lane_catchup <cur> <dry 0|1> → prints a `moved:` / `would:` line when it queues (or would), nothing otherwise
back_lane_catchup() {
    local cur=$1 dry=$2 q ql qw qn w0 n out id late=()
    w0=$(back_lane_get window); [ -n "$w0" ] || return 0
    q=$(back_lane_get queued); ql=${q%%|*}; qw=${q#*|}; qn=${qw#*|}; qw=${qw%%|*}
    [ "$q" = "$ql" ] && { qw=""; qn=""; }   # no `queued` yet, or one with no separator
    { [ "$ql" = "$cur" ] && back_lane_same_window "$qw" "$w0"; } || qn=""
    back_lane_movers "$cur" || return 0
    for n in ${BL_MOVE[@]+"${BL_MOVE[@]}"}; do case ",$qn," in *",$n,"*) ;; *) late+=("$n");; esac; done
    [ "${#late[@]}" -gt 0 ] || return 0
    if [ "$dry" = 1 ]; then echo "would: catch-up: sala op lane $cur ${late[*]} --from sala-watch --words \"…\" (the back agent(s) the rule's move has not queued yet; a dry run writes and queues nothing)$(back_lane_pinned_note)"; return 0; fi
    out=$("$SALA_BIN" op lane "$cur" "${late[@]}" --from sala-watch --words "$SALA_BACK_LANE_WORDS" 2>&1) || { echo "blocked: catch-up not queued: $(printf '%s' "$out" | tail -1)"; return 0; }
    id=$(printf '%s\n' "$out" | sed -n 's/^queued op \([0-9-]*\):.*/\1/p' | head -1)
    back_lane_put queued "$cur|$w0|${qn:+$qn,}$(IFS=,; echo "${late[*]}")"
    lane_log backlane "$cur" "catch-up: ${#late[@]} back agent(s) queued onto $cur (op ${id:-?})"
    echo "moved: catch-up: ${#late[@]} back agent(s) the rule had not moved (${late[*]}) to the $(lane_shown "$cur") lane, op ${id:-?} queued$(back_lane_pinned_note)"
}
# back_lane_tick [--dry-run] → one pass of the rule; prints one line per outcome, "<tag>: <text>" (the watch logs them; `notice:` lines are posted):
#   idle (nothing to do, with why when a reading was refused) · moved (the operation queued) · advanced (state moved, nobody to move) ·
#   blocked / notice (the step cannot be taken now) · would (a dry run: what it would queue and write; nothing is queued or written)
back_lane_tick() {
    back_lane_on || return 0
    local dry=0 now cur ci home ti target why stp rd st pct win rst moved_at w0 key out id f stp2; [ "${1:-}" = --dry-run ] && dry=1
    back_lane_order || { echo "idle: SALA_BACK_LANE_ORDER names fewer than two lanes ($SALA_BACK_LANE_ORDER)"; return 0; }
    case "$SALA_BACK_LANE_THRESHOLD" in ''|*[!0-9]*) echo "idle: SALA_BACK_LANE_THRESHOLD is not a whole number ($SALA_BACK_LANE_THRESHOLD)"; return 0;; esac
    _now_r now; home=${BL_ORDER[0]}; cur=$(back_lane_current); ci=$(back_lane_idx "$cur")
    target=""; why=""; stp=""; key=""; rd=""; pct=""
    if ! lane_dormant "$home"; then   # a due reading is asked for first (the steps read the file)
        out=$(back_lane_refresh "$home" "$([ "$dry" = 1 ] && echo --dry-run)"); [ -z "$out" ] || echo "$out"
    fi
    if [ "$ci" -gt 0 ]; then
        w0=$(back_lane_get window); : "${w0:=0}"; moved_at=$(back_lane_get moved_at); : "${moved_at:=0}"
        # STEP 3: the home lane's window rolled over: a fresh reading in a window later than the one it left, under the threshold
        if ! lane_dormant "$home" && rd=$(back_lane_reading "$home"); then
            IFS=$'\t' read -r st pct win rst <<< "$rd"
            if [ "$win" -gt $(( w0 + 3600 )) ] && [ "$pct" -lt "$SALA_BACK_LANE_THRESHOLD" ]; then
                target=$home; stp=3; key=$win; why="the $(lane_shown "$home") lane's weekly limit has reset (now $pct%, next reset $(back_lane_when "$rst"))"
            fi
        fi
        # STEP 2: a pane running on the current lane is stopped on its cap, after the move onto it
        if [ -z "$target" ] && [ $((ci + 1)) -lt "${#BL_ORDER[@]}" ] && stp2=$(back_lane_stopped "$cur" "$moved_at"); then
            target=${BL_ORDER[$((ci + 1))]}; stp=2; key=$w0; why="a pane on the $(lane_shown "$cur") lane is stopped on its cap (since $(back_lane_when "$stp2"))"
        fi
    else
        # STEP 1: the home lane's "This week" limit at the threshold, from a fresh reading, the lane not dormant
        if lane_dormant "$home"; then echo "idle: the $(lane_shown "$home") lane is dormant: nobody moves by the rule"; return 0; fi
        if ! rd=$(back_lane_reading "$home"); then echo "idle: no usable $(lane_shown "$home") reading: ${rd#bad$'\t'}"; return 0; fi
        IFS=$'\t' read -r st pct win rst <<< "$rd"
        if [ "$pct" -ge "$SALA_BACK_LANE_THRESHOLD" ]; then
            target=${BL_ORDER[1]}; stp=1; key=$win; why="the $(lane_shown "$home") lane's weekly limit is at $pct% (threshold $SALA_BACK_LANE_THRESHOLD%, it resets $(back_lane_when "$rst"))"
        fi
    fi
    [ -n "$target" ] || { echo "idle: the back agents stay on the $(lane_shown "$cur") lane${pct:+ ($(lane_shown "$home") at $pct%)}"; [ "$ci" -gt 0 ] && back_lane_catchup "$cur" "$dry"; return 0; }
    # once per window: the step's own record (f<place of the target>) holds the window it fired for
    ti=$(back_lane_idx "$target"); f=$(back_lane_get "f$ti")
    if back_lane_same_window "$key" "$f"; then echo "idle: step $stp already fired in this weekly window"; [ "$ci" -gt 0 ] && back_lane_catchup "$cur" "$dry"; return 0; fi
    # the target must work: active and ready; else one notice per window and step, no move, the state unchanged
    if lane_dormant "$target" || ! out=$(lane_check "$target"); then
        out=${out:-the lane is dormant}
        if [ "$(back_lane_get blocked)" != "$stp@$key" ]; then
            [ "$dry" = 1 ] || back_lane_put blocked "$stp@$key"
            echo "notice: the back agents should move to the $(lane_shown "$target") lane ($why) but it cannot take them: $out"
        else echo "blocked: step $stp waits: the $(lane_shown "$target") lane cannot take them: $out"; fi
        return 0
    fi
    back_lane_movers "$target"
    if [ "${#BL_MOVE[@]}" -eq 0 ]; then
        if [ "$dry" = 1 ]; then echo "would: step $stp ($why): the rule's lane becomes the $(lane_shown "$target") lane; no back agent to move$(back_lane_pinned_note)"; return 0; fi
        back_lane_commit "$stp" "$target" "$key" "$ti" ""
        echo "advanced: step $stp ($why): the rule's lane is now the $(lane_shown "$target") lane; no back agent needed moving${BL_STAY[*]:+; Fable stays: ${BL_STAY[*]}}$(back_lane_pinned_note)"
        return 0
    fi
    if [ "$dry" = 1 ]; then
        echo "would: step $stp ($why): sala op lane $target ${BL_MOVE[*]} --from sala-watch --words \"…\"; then the rule's lane is the $(lane_shown "$target") lane (a dry run writes and queues nothing)${BL_STAY[*]:+; Fable stays (the $(lane_shown "$target") lane cannot run it): ${BL_STAY[*]}}$(back_lane_pinned_note)"
        return 0
    fi
    out=$("$SALA_BIN" op lane "$target" "${BL_MOVE[@]}" --from sala-watch --words "$SALA_BACK_LANE_WORDS" 2>&1) || {
        if [ "$(back_lane_get blocked)" != "$stp@$key" ]; then
            back_lane_put blocked "$stp@$key"; echo "notice: the back agents should move to the $(lane_shown "$target") lane ($why) but the move was not queued: $(printf '%s' "$out" | tail -3 | paste -sd' ' -)"
        else echo "blocked: step $stp not queued: $(printf '%s' "$out" | tail -1)"; fi
        return 0; }
    id=$(printf '%s\n' "$out" | sed -n 's/^queued op \([0-9-]*\):.*/\1/p' | head -1)
    back_lane_commit "$stp" "$target" "$key" "$ti" "${BL_MOVE[*]}"
    lane_log backlane "$target" "step $stp: ${#BL_MOVE[@]} back agent(s) queued onto $target (op ${id:-?}): $why"
    echo "moved: step $stp ($why): ${#BL_MOVE[@]} back agent(s) to the $(lane_shown "$target") lane, op ${id:-?} queued (the operation posts once when it is done)$(back_lane_pinned_note)"
    [ "${#BL_STAY[@]}" -eq 0 ] || echo "notice: ${#BL_STAY[@]} Fable back agent(s) did not move to the $(lane_shown "$target") lane (it cannot run Fable): ${BL_STAY[*]}"
    return 0
}
# back_lane_spawn_lane → the lane a NEW back agent spawns on while the rule has the back agents off home (stdout, rc 0); rc 1 when the rule is
# off, the back agents stand at home, or the rule's lane cannot take it (dormant, not ready)
back_lane_spawn_lane() {
    back_lane_on || return 1; back_lane_order || return 1
    local c; c=$(back_lane_current); [ "$c" != "${BL_ORDER[0]}" ] || return 1
    lane_dormant "$c" && return 1; lane_check "$c" >/dev/null 2>&1 || return 1
    echo "$c"
}
# THE RENAME'S MIGRATION (`sala lane --migrate [--dry-run]`; install.sh runs it too): the one-shot that rewrites the old name of the renamed
# lane (awsplatform) in what sala keeps — lanes.tsv (column 2), lane-default, lane-state.tsv (column 1) and the session registry's rows. It
# is not needed for anything to work (every reader reads the old name as the new one, every write rewrites it); it only brings the files
# to rest. Idempotent: a second run finds nothing and writes nothing. Atomic: a temp file next to each file, mv over it, under the
# file's own lock. A backup of each file it changes is kept beside it (<file>.pre-aws-platform-<time>) first. lanes.log is history and is
# left as it is (readers read the old name in it as the new one); the migration adds one `migrate` line to it.
_lane_old_count_r() {  # <var> <file> <column> → in <var>, how many lines carry the old name in that column (read with the shell's own builtins)
    local _n=0 _line _rest _k _t=$'\t'
    if [ -r "$2" ]; then
        while IFS= read -r _line || [ -n "$_line" ]; do
            _rest=$_line; _k=$3
            while [ "$_k" -gt 1 ]; do [[ $_rest == *"$_t"* ]] || { _rest=""; break; }; _rest=${_rest#*"$_t"}; _k=$((_k - 1)); done
            [ "${_rest%%"$_t"*}" = awsplatform ] && _n=$((_n + 1))
        done < "$2"
    fi
    printf -v "$1" %s "$_n"
}
_lane_migrate_file() {  # <file> <column> <stamp> → backs the file up, then rewrites the old name in that column (called under the file's lock)
    local f="$1" c="$2" t="$1.t.${BASHPID:-$$}"
    awk -F'\t' -v OFS='\t' -v c="$c" '{ if ($c == "awsplatform") $c = "aws-platform"; print }' "$f" > "$t" \
        && cp -p "$f" "$f.pre-aws-platform-$3" \
        && { chmod --reference="$f" "$t" 2>/dev/null; mv -f "$t" "$f"; } || { rm -f "$t"; echo "lanes: could not rewrite $f" >&2; return 1; }
}
lane_migrate() {  # [--dry-run] → 0; prints what it found and did
    local dry=0 stamp n total=0 rn
    [ "${1:-}" = --dry-run ] && dry=1
    printf -v stamp '%(%Y%m%dT%H%M%S)T' -1
    _lane_old_count_r n "$SALA_LANES" 2
    if [ "$n" -gt 0 ]; then total=$((total + n))
        if [ "$dry" = 1 ]; then echo "[dry-run] would rewrite $n row(s) of $SALA_LANES (awsplatform → aws-platform), keeping $SALA_LANES.pre-aws-platform-<time>"
        else _lane_locked _lane_migrate_file "$SALA_LANES" 2 "$stamp" || return 1; echo "rewrote $n row(s) of $SALA_LANES (backup: $SALA_LANES.pre-aws-platform-$stamp)"; fi
    fi
    _lane_old_count_r n "$SALA_LANE_DEFAULT_FILE" 1
    if [ "$n" -gt 0 ]; then total=$((total + n))
        if [ "$dry" = 1 ]; then echo "[dry-run] would rewrite the default lane in $SALA_LANE_DEFAULT_FILE (awsplatform → aws-platform), keeping a backup"
        else _lane_migrate_file "$SALA_LANE_DEFAULT_FILE" 1 "$stamp" || return 1; echo "rewrote the default lane in $SALA_LANE_DEFAULT_FILE (backup: $SALA_LANE_DEFAULT_FILE.pre-aws-platform-$stamp)"; fi
    fi
    _lane_old_count_r n "$SALA_LANE_STATE" 1
    if [ "$n" -gt 0 ]; then total=$((total + n))
        if [ "$dry" = 1 ]; then echo "[dry-run] would rewrite $n row(s) of $SALA_LANE_STATE (awsplatform → aws-platform), keeping a backup"
        else _lane_state_locked _lane_migrate_file "$SALA_LANE_STATE" 1 "$stamp" || return 1; echo "rewrote $n row(s) of $SALA_LANE_STATE (backup: $SALA_LANE_STATE.pre-aws-platform-$stamp)"; fi
    fi
    if sessions_on && [ -r "$SALA_SESSIONS_FILE" ]; then   # the registry: its rows copy the lane (a row nobody wrote since the rename still says the old name)
        rn=$( ( if command -v flock >/dev/null 2>&1; then flock -w 10 6 || { echo "the pane map's lock is held"; exit 1; }; fi
                sessions_py relane $([ "$dry" = 1 ] && echo --dry-run) ) 6>>"$SALA_SIDECAR.lock" 2>&1 ) \
            || { echo "⚠ the session registry's rows could not be rewritten (${rn//$'\n'/ }); every reader reads the old name as the new one meanwhile" >&2; rn=""; }
        [ -z "$rn" ] || { echo "session registry: $rn"; case "$rn" in 0\ *) ;; *) total=$((total + ${rn%% *}));; esac; }
    fi
    if [ "$total" -eq 0 ]; then echo "nothing to migrate: no file of sala's carries the old lane name awsplatform"; return 0; fi
    [ "$dry" = 1 ] || lane_log migrate - "awsplatform → aws-platform: $total record(s) rewritten"
    return 0
}
# THE DORMANT RECORD: one record per lane — active or dormant, with the reason and
# since when — so every part of sala that touches a lane reads one answer instead of finding out again. A lane is DORMANT
# when nothing can be run on it for now: the seat is gone, the login no longer reports its subscription, the API credit is used
# up. It is plain shell and python3, no Claude turn; sala's watch KEEPS it (lib/watch.sh, "THE DORMANT RECORD'S SIGNALS") and
# everything below READS it. File: lane-state.tsv beside lanes.tsv, one row per lane that ever changed state, keyed by the
# lane's id from the lane table (a new lane, bedrock later, needs nothing here; sdk is api's alias, lane_canonical):
#   lane TAB state (active|dormant) TAB reason TAB since (ISO, UTC) TAB posted (ISO of the one post this dormant episode
#   made, empty until then) TAB by (signal: kept by the watch, revived by it; hand: set with `sala lane dormant`, held until
#   `sala lane active`) TAB until (ISO, UTC: when the provider says access returns, set by a monthly usage cap; empty for every
#   other reason; a row written before the column existed has six fields and reads as empty)
# An absent row, or a missing file, is ACTIVE. Written as lanes.tsv is: one editor at a time (flock on fd 3, its own lock
# file), a temp file next to the table, mv over it; a change is one line in lanes.log (op dormant | active). While a lane is
# dormant: the web Overview card is one line and makes no usage check; spawn's picker (the CLI's list, the web form) hides
# it; `sala lane <lane> <session>` and `sala lane default <lane>` refuse to move onto it; the sessions still on it are posted
# ONCE (the watch; "posted" is that memory) and stay where they are — nothing here relaunches or moves a pane. The login
# lanes (subscription-1, subscription-2) come back by themselves (the watch's daily look at the free sign-in check); the API lane (api, sdk)
# comes back only on `sala lane active api`: no test call is ever made to find out.
SALA_LANE_STATE="$SALA_STATE_DIR/lane-state.tsv"
: "${SALA_WEB_STATE_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/sala-web}"   # sala-web's state (its saved usage answers, quota-<lane>.json), read by the watch
: "${SALA_LANE_REVIVE_EVERY:=86400}"                                       # a dormant login lane is looked at again this often
lane_state_id() { local l=${1:-}; [ "$l" = sdk ] && l=api; _lane_norm_r l "$l"; lane_known "$l" || return 1; echo "$l"; }   # <word> → the lane id the record is keyed by (sdk → api); fails for a word that is no lane
_lane_state_field_r() {  # <var> <lane> <n> → that column of the lane's row in <var> (2 state, 3 reason, 4 since, 5 posted, 6 by); empty when there is none. No fork: the first row whose key is the lane, split by parameter expansion (an empty column stays a column)
    local l=${2:-} n=$3 line rest k t=$'\t'
    printf -v "$1" %s ""
    [ "$l" = sdk ] && l=api; _lane_norm_r l "$l"; lane_known "$l" || return 0; [ -r "$SALA_LANE_STATE" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        k=${line%%"$t"*}; _lane_norm_r k "$k"   # a row keyed by a renamed lane's old word (awsplatform, max, team) is its row
        [ "$k" = "$l" ] || continue
        rest=$line; k=1
        while [ "$k" -lt "$n" ]; do [[ $rest == *"$t"* ]] || { rest=""; break; }; rest=${rest#*"$t"}; k=$((k + 1)); done
        printf -v "$1" %s "${rest%%"$t"*}"; return 0
    done < "$SALA_LANE_STATE"
    return 0
}
lane_state_field() {  # <lane> <n> → that column of the lane's row (2 state, 3 reason, 4 since, 5 posted, 6 by); nothing when there is none
    local _ls_v; _lane_state_field_r _ls_v "${1:-}" "$2"; printf '%s\n' "$_ls_v"
}
lane_dormant() { local _ld_v; _lane_state_field_r _ld_v "${1:-}" 2; [ "$_ld_v" = dormant ]; }   # <lane> → 0 when it is dormant (sdk is asked as api)
lane_iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ'; }   # <epoch> → ISO, UTC
lane_iso_epoch() { date -u -d "$1" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || echo 0; }   # <iso> → epoch
lane_day() {  # <iso> → "Wed Jan 7th", the day in SALA_TZ (this machine's local time when unset)
    local e w; e=$(lane_iso_epoch "$1"); _when_r w "$e" day; printf '%s\n' "$w"
}
lane_label() { local v; v=$(lane_field "${1:-}" label 2>/dev/null); echo "${v:-${1:-}}"; }   # <lane|alias> → its display name: "Ultra", "Team" (the lane's label field: SALA_LANE_<ID>_LABEL, defaults in the table above; the ONE place a display name is written)
lane_shown() { local _n; _lane_norm_r _n "${1:-}"; case "$_n" in subscription-1|subscription-2) lane_label "$_n";; *) printf '%s\n' "${1:-}";; esac; }   # <lane|alias|word> → how a post or a summary names the lane: the display name for a subscription lane (Ultra, Team), any other word as it came
# THE LANE NAMES (stackshot reads them; docs/stackshot-contracts.md "Lane names"): `salamander lane names [--json] [--write]`, and the
# file $SALA_STATE_DIR/lane-names.json that sala-watch's tick (and --write) keeps current. One entry per known lane: its code, its display
# name (lane_label) and its aliases (the old words SALA_LANE_RENAMED maps onto it; none → empty).
lane_aliases() {  # <code> → the old words that mean this lane, one per line
    local _p; for _p in $SALA_LANE_RENAMED; do [ "${_p#*=}" = "${1:-}" ] && echo "${_p%%=*}"; done; return 0
}
_json_str() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }   # a JSON string: backslash and quote escaped (a display name is config text)
lane_names_text() {  # → "<code> TAB <display> TAB <alias,alias>", one line per known lane (the aliases column empty when none)
    local _c _a; for _c in $SALA_LANES_KNOWN; do _a=$(lane_aliases "$_c" | paste -sd, -); printf '%s\t%s\t%s\n' "$_c" "$(lane_label "$_c")" "$_a"; done
}
lane_names_json() {  # → {"lanes":[{"code":…,"display":…,"aliases":[…]},…]} on one line
    local _c _a _al _sep="" out='{"lanes":['
    for _c in $SALA_LANES_KNOWN; do
        _al=""; for _a in $(lane_aliases "$_c"); do _al+="${_al:+,}$(_json_str "$_a")"; done
        out+="$_sep{\"code\":$(_json_str "$_c"),\"display\":$(_json_str "$(lane_label "$_c")"),\"aliases\":[$_al]}"; _sep=,
    done
    printf '%s]}\n' "$out"
}
lane_names_write() {  # → writes $SALA_STATE_DIR/lane-names.json atomically (a temp file in the same folder, then mv), only when it differs; says "written" or "unchanged"
    local _f="$SALA_STATE_DIR/lane-names.json" _t; mkdir -p "$SALA_STATE_DIR" 2>/dev/null || return 1
    _t=$(mktemp "$SALA_STATE_DIR/.lane-names.XXXXXX") || return 1
    lane_names_json > "$_t" || { rm -f -- "$_t"; return 1; }
    if [ -r "$_f" ] && cmp -s "$_t" "$_f"; then rm -f -- "$_t"; echo unchanged; return 0; fi
    chmod 644 "$_t" 2>/dev/null; mv -f -- "$_t" "$_f" || { rm -f -- "$_t"; return 1; }; echo written
}
lane_dormant_until() {  # <lane> → the epoch the dormant record says access returns (its until column), nothing when it names none
    local u; u=$(lane_state_field "$1" 7); [ -n "$u" ] || return 0
    u=$(lane_iso_epoch "$u"); [ "${u:-0}" -gt 0 ] 2>/dev/null && echo "$u"
    return 0
}
lane_dormant_capped() {  # <lane> → 0 when it is dormant with a regain time still ahead (a monthly usage cap: nothing can work on it before then)
    local u; lane_dormant "$1" || return 1; u=$(lane_dormant_until "$1"); [ -n "$u" ] && [ "$u" -gt "$(date +%s)" ]
}
lane_dormant_since_words() {  # <lane> → "no seat since Wed Jan 7th" (the reason, then the day; just "since …" with no reason); with a regain time: "…, access returns Tue Dec 1st 09:00"
    local r s u w=""; r=$(lane_state_field "$1" 3); s=$(lane_state_field "$1" 4); u=$(lane_dormant_until "$1")
    if [ -n "$u" ]; then _when_r w "$u"; w=", access returns $w"; fi
    echo "${r:+$r }since $(lane_day "${s:-1970-01-01T00:00:00Z}")$w"
}
lane_dormant_words() { echo "$(lane_label "$(lane_state_id "$1")"): dormant, $(lane_dormant_since_words "$1")"; }   # <lane> → "Team: dormant, no seat since Wed Jan 7th"
# lane_dormant_refusal <lane> → 0 with the plain refusal on stdout when the lane is dormant (a move onto it is refused); 1 when it is not
lane_dormant_refusal() {
    lane_dormant "${1:-}" || return 1
    local l how; l=$(lane_state_id "$1")
    case "$(lane_state_field "$l" 6)" in signal) how="sala's watch sees it so";; *) how="set by hand";; esac
    echo "the $(lane_label "$l") lane is dormant ($(lane_dormant_since_words "$l"); $how): nothing is moved onto it. When it works again: salamander lane active $l"
    return 0
}
lane_choices() {  # → the lanes a new session or a move may pick, space-separated: SALA_LANES_KNOWN without the dormant ones
    local l o=""; for l in $SALA_LANES_KNOWN; do lane_dormant "$l" || o="$o$l "; done; echo "${o% }"
}
lane_sessions_on() {  # <lane> → the sessions recorded on it (lanes.tsv and the pane map; the default lane for those without a row), one per line
    local l s f line rc="${SALA_RC_SESSION:-}" ln sh="${SALA_SHELL_SESSION:-}"
    local -A seen=(); local -a list=()
    l=$(lane_state_id "${1:-}") || return 0
    # the union of the two files' first columns, once each, the Remote Control server's session left out; read here, not by cut | awk
    for f in "$SALA_SIDECAR" "$SALA_LANES"; do
        [ -r "$f" ] || continue
        while IFS= read -r line || [ -n "$line" ]; do
            line=${line%%$'\t'*}
            [[ $line == *[![:space:]]* ]] || continue
            [ "$line" = "$rc" ] && continue
            [ -n "$sh" ] && [ "$line" = "$sh" ] && continue   # the web UI's shell drawer
            [ -n "${seen[$line]:-}" ] && continue
            seen[$line]=1; list+=("$line")
        done < "$f" 2>/dev/null
    done
    [ ${#list[@]} -gt 0 ] || return 0
    printf '%s\n' "${list[@]}" | LC_ALL=C sort | while IFS= read -r s; do
        _lane_for_session_r ln "$s"; [ "$(lane_canonical "$ln")" = "$l" ] && echo "$s"
    done
    return 0
}
_lane_state_locked() {
    mkdir -p "$SALA_STATE_DIR" 2>/dev/null
    command -v flock >/dev/null 2>&1 || { "$@"; return; }
    ( flock -w 30 3 || { echo "lanes: the dormant record's lock is held — not written" >&2; exit 1; }; "$@" ) 3>>"$SALA_LANE_STATE.lock"
}
_lane_state_put() {  # <lane> <state> <reason> <since iso> <posted iso> <by> [until iso]: replace the lane's row (the until column is written only when given)
    local f="$SALA_LANE_STATE" t="$SALA_LANE_STATE.t.${BASHPID:-$$}"
    { [ -r "$f" ] && awk -F'\t' -v OFS='\t' -v l="$1" '{ if ($1 == "awsplatform") $1 = "aws-platform"; else if ($1 == "max") $1 = "subscription-1"; else if ($1 == "team") $1 = "subscription-2" } $1!=l' "$f"; printf '%s\t%s\t%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4" "$5" "$6"; [ -z "${7:-}" ] || printf '\t%s' "$7"; printf '\n'; } | LC_ALL=C sort > "$t" \
        && mv -f "$t" "$f" || { rm -f "$t"; echo "lanes: could not write $f" >&2; return 1; }
}
_lane_state_clean() { printf '%s' "$1" | tr '\t\r\n' '   ' | sed 's/  */ /g; s/^ //; s/ $//'; }
_lane_dormant_set() {  # <lane> <reason> <by> <since epoch> [until epoch] → 0 set now, 3 it was dormant already (nothing changes), 1 not written
    lane_dormant "$1" && return 3
    local u=""; [ "${5:-0}" -gt 0 ] 2>/dev/null && u=$(lane_iso "$5")
    _lane_state_put "$1" dormant "$(_lane_state_clean "$2")" "$(lane_iso "$4")" "" "$3" "$u" || return 1
    lane_log dormant "$1" "active → dormant: $(_lane_state_clean "$2") (by $3${u:+, until $u})"
}
# lane_dormant_set <lane> <reason> <signal|hand> [since epoch] [until epoch] → 0 when this call made it dormant, 3 when it already was.
# <until epoch> is when the provider says access returns (a monthly usage cap, THE MONTHLY CAP in lib/watch.sh): kept in the record's
# until column, said wherever the lane's dormancy is said, and read by the watch to bring the lane back at that time
lane_dormant_set() {
    local l; l=$(lane_state_id "${1:-}") || return 1
    _lane_state_locked _lane_dormant_set "$l" "${2:-}" "${3:-hand}" "${4:-$(date +%s)}" "${5:-0}"
}
_lane_dormant_clear() {  # <lane> <why> → 0 cleared, 3 it was not dormant
    lane_dormant "$1" || return 3
    local r; r=$(lane_state_field "$1" 3)
    _lane_state_put "$1" active "" "$(lane_iso "$(date +%s)")" "" "" || return 1
    lane_log active "$1" "dormant → active: $(_lane_state_clean "$2") (was: ${r:-no reason})"
}
lane_dormant_clear() { local l; l=$(lane_state_id "${1:-}") || return 1; _lane_state_locked _lane_dormant_clear "$l" "${2:-set by hand}"; }   # <lane> [why] → 0 cleared, 3 it was not dormant
_lane_dormant_claim() {  # <lane> → 0 when this call claimed the dormant episode's one post, 3 when it was posted already (or the lane is not dormant)
    lane_dormant "$1" || return 3
    [ -z "$(lane_state_field "$1" 5)" ] || return 3
    _lane_state_put "$1" dormant "$(lane_state_field "$1" 3)" "$(lane_state_field "$1" 4)" "$(lane_iso "$(date +%s)")" "$(lane_state_field "$1" 6)" "$(lane_state_field "$1" 7)"
}
lane_dormant_claim_post() { local l; l=$(lane_state_id "${1:-}") || return 1; _lane_state_locked _lane_dormant_claim "$l"; }   # <lane>
# THE LIMITS' NAMES (the limit watch, lib/watch.sh; here since the rescue reads them too), one phrase per sentence a limit
# appears in ("stopped by the API credit used up" did not read). The lane/kind pairing is
# structural, as in the watch's scan (its API_KINDS is the same list): an API kind (rate, credit, workspace: the api lane's
# own) is always "API …", whatever lane is named — a login lane has no credit, so "Ultra credit" cannot be printed; a login
# kind (the weekly and 5-hour limits) carries the login of its lane (subscription-1 → its display name, Ultra; subscription-2 → Team) and no login on
# the api lane, on the unnamed login lane ("login") or with no lane (a headless run): "weekly limit".
# lw_limit <lane> <limit> → the name: "Ultra weekly limit", "Team 5-hour limit", "Ultra Opus weekly limit", "API rate limit",
# "API credit ran out", "API workspace spending limit" (the stop headline's list, and the watch's frames)
lw_limit() {
    local who what m
    case "$2" in rate|credit|workspace|monthly) who=API;; *) case "$(lane_norm "$1")" in subscription-1|subscription-2) who=$(lane_label "$1");; ''|-|api|sdk|login) who="";; *) who=$(lane_norm "$1");; esac;; esac
    case "$2" in
        rate) what="rate limit";; credit) what="credit ran out";; workspace) what="workspace spending limit";; monthly) what="monthly usage cap";;
        seven_day) what="weekly limit";; five_hour) what="5-hour limit";;
        seven_day_*|five_hour_*) m=${2#*_*_}; _u0=${m:0:1}; m="${_u0^^}${m:1}"
            case "$2" in seven_day_*) what="$m weekly limit";; *) what="$m 5-hour limit";; esac ;;
        *) what="$(printf '%s' "$2" | tr _ ' ') limit";;
    esac
    echo "${who:+$who }$what"
}
# IS A LANE OUT? (the rescue.) The master runs on a lane; when that lane's usage is out or its
# account is dead the master cannot act, and another session moves it (`sala lane --rescue <lane>`, lib/lane.sh). That
# verb refuses while the lane looks fine, so "out" needs a test, and sala has three cheap, honest readings of its own: it
# asks no model and makes no request.
#   1. lane_check: the lane cannot launch at all (no key file, a directory not signed in) — out.
#   2. the sign-in watch's state (SALA_SIGNIN_STATE, lib/watch.sh "SIGN-IN WATCH"): the lane's last look was WRONG (not
#      signed in, another account, the key refused) — out. The sdk lane is the api key's: judged by the api line.
#   3. the limit watch's state (SALA_LIMIT_STATE, lib/watch.sh): a pane stopped on this lane by a limit. The master's own
#      pane stopped on it is decisive, whatever the limit; another pane's stop is decisive only for a lane-wide limit
#      (weekly, 5-hour, credit, workspace, rate), since one model's limit (seven_day_opus) stops only that model's panes.
# lane_out <lane> [<session>] → 0 with the reasons on stdout (one per line) when any reading says the lane is out; 1 and
# nothing when none does (the lane looks fine to sala: `--force` is the override). A watch that has not looked, or whose
# state is unreadable, says nothing — an absent reading is not "fine", it is nothing, and the caller's words say so.
_signin_get() {  # <lane> <field> → the sign-in state's value for "<lane>.<field>", else the one under the lane's old word (max.seen, team.since: a state written before the rename); nothing when neither is there
    local _v _o; _v=$(awk -F= -v k="$1.$2" '$1==k {print substr($0, length(k)+2); exit}' "$SALA_SIGNIN_STATE" 2>/dev/null)
    if [ -z "$_v" ]; then _lane_varid_old_r _o "$1"; [ -z "$_o" ] || _v=$(awk -F= -v k="${_o,,}.$2" '$1==k {print substr($0, length(k)+2); exit}' "$SALA_SIGNIN_STATE" 2>/dev/null); fi
    printf '%s' "$_v"
}
lane_out() {
    local lane sess="${2:-}" key seen since why out=1; lane=$(lane_norm "${1:-}")
    why=$(lane_check "$lane") || { echo "$why"; out=0; }
    if lane_dormant "$lane"; then echo "the $(lane_label "$(lane_state_id "$lane")") lane is dormant: $(lane_dormant_since_words "$lane")"; out=0; fi   # the dormant record
    key=$lane; [ "$lane" = sdk ] && key=api
    seen=$(_signin_get "$key" seen)
    case "$seen" in "wrong: "*)
        since=$(_signin_get "$key" since)
        echo "the sign-in watch sees the $(lane_shown "$lane") lane ${seen#wrong: }$([ -n "$since" ] && echo " since $(local_human "$since")")"; out=0;; esac
    if [ -r "$SALA_LIMIT_STATE" ]; then
        while IFS=$'\t' read -r n names lim since reset; do
            [ -n "$n" ] || continue
            if [ "$names" = "$sess" ] && [ -n "$sess" ]; then echo "the limit watch has $sess stopped on it: $(lw_limit "$lane" "$lim") since $(local_human "$since")$([ "${reset:-0}" -gt 0 ] 2>/dev/null && echo ", it says it resets $(local_human "$reset")")"
            else echo "the limit watch has $(plural "$n" pane) stopped on it ($names): $(lw_limit "$lane" "$lim") since $(local_human "$since")$([ "${reset:-0}" -gt 0 ] 2>/dev/null && echo ", it says it resets $(local_human "$reset")")"; fi
            out=0
        done < <(LANE="$key" SESS="$sess" python3 -c '
import json, os, sys
try: panes = json.load(open(sys.argv[1])).get("panes") or {}
except Exception: sys.exit()
lane, sess = os.environ["LANE"], os.environ["SESS"]
ren = {"awsplatform": "aws-platform", "max": "subscription-1", "team": "subscription-2"}   # a stop recorded before a lane was renamed names the old word
mine = [p for p in panes.values() if isinstance(p, dict) and ren.get(p.get("lane"), p.get("lane")) == lane]
own = [p for p in mine if sess and p.get("s") == sess]
wide = [p for p in mine if not str(p.get("lim", "")).startswith(("seven_day_", "five_hour_"))]   # a lane-wide limit, not one model'"'"'s
for group in (own, wide):
    if not group: continue
    first = min(group, key=lambda p: int(p.get("since") or 0))
    names = sess if group is own else ", ".join(sorted(str(p.get("s") or "?") for p in group)[:5]) + (" …" if len(group) > 5 else "")
    print("%d\t%s\t%s\t%d\t%d" % (len(group), names, first.get("lim") or "usage", int(first.get("since") or 0), int(first.get("reset") or 0)))
    break' "$SALA_LIMIT_STATE" 2>/dev/null)
    fi
    return $out
}
lanes_working() { local l w=""; for l in $SALA_LANES_KNOWN; do lane_out "$l" >/dev/null 2>&1 || w="$w$l "; done; echo "${w% }"; }   # → the lanes sala sees nothing wrong with, space-separated

# ── models ────────────────────────────────────────────────────────────────────
# A session's MODEL and EFFORT, recorded (Wed Oct 14th 2026, asked by the project's coordinator session: move the master session to sonnet at
# medium effort, and have every relaunch keep it). Until now a relaunch took both from the conversation's own transcript
# (_resume_flags_for_uuid above: the newest real turn's family, the prevailing effort), so a pane could be moved only by
# typing /model into it, and a skill's or a hand's /model decided what the next relaunch came back on. The record wins
# over the transcript; a session without one is relaunched as before. STATE, beside the lanes and shaped like them:
# models.tsv, one "<tmux session>\t<model>\t<effort or ->" row per session with a model of its own ("-": no effort of its
# own, the transcript's is kept), and models.log, one line per change (time, op, session, old → new, who). The model is
# a family alias or a full model id (model_valid), passed to `claude --model` as it is; the effort is one of the levels
# `claude --effort` takes (SALA_EFFORTS_KNOWN; `claude --help`, and spawn's own check). `sala model` (lib/model.sh) is the
# verb: it records and relaunches; rename moves the row, retire drops it; nothing here relaunches by itself.
SALA_MODELS="$SALA_STATE_DIR/models.tsv"; SALA_MODEL_LOG="$SALA_STATE_DIR/models.log"
SALA_MODEL_FAMILIES="opus sonnet haiku fable"
SALA_EFFORTS_KNOWN="low medium high xhigh max"
effort_known() { case " $SALA_EFFORTS_KNOWN " in *" ${1:-} "*) return 0;; esac; return 1; }   # <word> → 0 when claude --effort takes it
# model_valid <word> → 0 for a family alias (opus · sonnet · haiku · fable) or a full model id (claude-…, lowercase letters,
# digits, dots and dashes). The id is typed unquoted onto a shell launch line, so nothing a shell would read otherwise gets
# in: a suffix such as "[1m]" is a glob to the pane's shell and is refused (spawn's --model check is the same character set).
model_valid() {
    case " $SALA_MODEL_FAMILIES " in *" ${1:-} "*) [ -n "${1:-}" ] && return 0;; esac
    case "${1:-}" in claude-*) case "${1#claude-}" in ''|*[!a-z0-9.-]*) return 1;; esac; return 0;; esac
    return 1
}
# model_batch_shape <args…> → 0 when the arguments (flags already taken out) are the BATCH shape `<model> <session>…` (
# a batch of model changes wakes the asking agent once, not once per session), 1 when they are the single-session shape
# `<session> <model>` or `<session> --clear` that is older. THE RULE: the first word is a model (model_valid: opus, sonnet,
# haiku, fable, or claude-…) → batch. Two cases keep the old shape: the second word is --clear (`opus --clear` is a session
# named opus), and a first word that is a claude-… id naming a LIVE tmux session while the second word is a model too (a session
# called claude-foo, asked `claude-foo opus`; a family alias is never read as a session name, so a session literally named
# opus, sonnet, haiku or fable is addressed only by `--clear` or inside a batch).
model_batch_shape() {
    model_valid "${1:-}" || return 1
    [ "${2:-}" = --clear ] && return 1
    case " $SALA_MODEL_FAMILIES " in *" $1 "*) return 0;; esac
    if model_valid "${2:-}" && tmux has-session -t "=$1" 2>/dev/null; then return 1; fi
    return 0
}
model_row() { local _m _e; [ -n "${1:-}" ] && [ -r "$SALA_MODELS" ] || return 0; _tsv_row_r _m "$SALA_MODELS" "$1"; [ -n "$_m" ] || return 0; _tsv_col_r _e "$SALA_MODELS" "$1" 3; _tsv_col_r _m "$SALA_MODELS" "$1" 2; printf '%s\t%s\n' "$_m" "$_e"; }   # <session> → "<model>\t<effort or ->", or nothing
model_log() { mkdir -p "$SALA_STATE_DIR" 2>/dev/null; printf '%s\t%s\t%s\t%s\t%s\n' "$(date -Is)" "$1" "$2" "$3" "${SALA_LEDGER_CALLER:-$(lock_who 2>/dev/null)}" >> "$SALA_MODEL_LOG" 2>/dev/null || true; }
# the writes as the lanes' (one editor at a time on fd 3, a temp file next to the table, mv): a lock file of its own
_model_locked() {
    mkdir -p "$SALA_STATE_DIR" 2>/dev/null
    command -v flock >/dev/null 2>&1 || { "$@"; return; }
    ( flock -w 30 3 || { echo "models: the table's lock is held — not written" >&2; exit 1; }; "$@" ) 3>>"$SALA_MODELS.lock"
}
_model_put() {  # <session> <model> <effort or ->
    local f="$SALA_MODELS" t="$SALA_MODELS.t.${BASHPID:-$$}" old new; old=$(model_row "$1"); new=$(printf '%s\t%s' "$2" "$3")
    [ "$old" = "$new" ] && return 0
    { [ -r "$f" ] && awk -F'\t' -v s="$1" '$1!=s' "$f"; printf '%s\t%s\t%s\n' "$1" "$2" "$3"; } | LC_ALL=C sort > "$t" && mv -f "$t" "$f" || { rm -f "$t"; echo "models: could not write $f" >&2; return 1; }
    model_log set "$1" "$(printf '%s' "${old:-(transcript)}" | tr '\t' /) → $2/$3"
}
_model_del() {  # <session>
    local t="$SALA_MODELS.t.${BASHPID:-$$}" old; old=$(model_row "$1"); [ -n "$old" ] || return 0
    awk -F'\t' -v s="$1" '$1!=s' "$SALA_MODELS" > "$t" && mv -f "$t" "$SALA_MODELS" || { rm -f "$t"; return 1; }
    model_log drop "$1" "$(printf '%s' "$old" | tr '\t' /) → (transcript)"
}
_model_mv() { local r; r=$(model_row "$1"); [ -n "$r" ] || return 0; _model_del "$1" && _model_put "$2" "$(cut -f1 <<< "$r")" "$(cut -f2 <<< "$r")"; }   # <old> <new>
model_write() {  # <session> <model> [effort] → the row (no effort, or "-": the transcript's effort is kept)
    local e="${3:--}"; model_valid "${2:-}" || return 1; [ "$e" = - ] || effort_known "$e" || return 1
    _model_locked _model_put "$1" "$2" "$e" || return $?
    sessions_set "$1" "model=$2" "effort=$([ "$e" = - ] || echo "$e")"
}
model_drop() { [ -r "$SALA_MODELS" ] || return 0; _model_locked _model_del "$1" || return $?; sessions_set "$1" model= effort=; }         # <session> — retire, sala model --clear
model_rename() { [ -r "$SALA_MODELS" ] || return 0; _model_locked _model_mv "$1" "$2"; }   # <old> <new> — rename

# COMPACT WINDOW (a different size for different types of agent, depending on their
# nature of work). Background agents compact at 200k tokens through the project settings of a shared role directory; the
# maintenance agents that share that directory compact earlier, and a shared settings file cannot say it per session, so it
# comes from here: compact.tsv, one "<tmux session>\t<tokens>" row per session with a window of its own (STATE, beside
# models.tsv; install.sh seeds it from contrib/compact.tsv when absent, then it is edited by hand), put on the pane's launch
# line as `claude --autocompact <tokens>`. CLI 2.1.312 takes "auto, or 100k-1M tokens" and refuses anything else at start, so
# a bad value must never be typed (it would leave the pane at a shell). No row, or a row that is not a whole number from
# 100000 to 1000000 (hand-edited), is no flag: the project setting applies, as models.tsv ignores a bad value. Only a pane's
# launch line carries it (resume_cmd, spawn): not the sdk lane's pane program, not a one-shot `claude -p`.
SALA_COMPACT="$SALA_STATE_DIR/compact.tsv"
compact_valid() { [[ ${1:-} =~ ^[1-9][0-9]{5,6}$ ]] && [ "$1" -ge 100000 ] && [ "$1" -le 1000000 ]; }   # <tokens> → 0 when `claude --autocompact` takes it
compact_tokens_r() {  # <var> <session> → the session's window in <var>, or "" (no row, a bad one, no file)
    printf -v "$1" %s ""; [ -n "${2:-}" ] && [ -r "$SALA_COMPACT" ] || return 0
    local _c; _tsv_col_r _c "$SALA_COMPACT" "$2" 2; compact_valid "$_c" && printf -v "$1" %s "$_c"; return 0
}

# THE IN-PLACE SWITCH (lib/model.sh): an idle pane with an empty input box is
# moved onto a recorded model and effort by typing `/model <value>` and `/effort <level>` into its composer, so its
# conversation process keeps running; a relaunch is the fallback. Claude Code saves every such command as the lane's DEFAULT
# (settings.json: the top-level `model`, `modelSettings.<model id>.effortLevel`), which would move every later session onto
# it, so the keys are snapshotted before the first keystroke and put back after (model_settings_snapshot / _restore).
# SALA_MODEL_INPLACE=off turns the whole thing off (the switch relaunches, as before the change; tests/lib.sh sets it for
# every suite but tests/modelinplace.sh). SALA_MODEL_INPLACE_WAIT: seconds a typed command may take to show its "Set …" line.
# SALA_MODEL_INPLACE_SETTLE: seconds the CLI is given to finish its own settings write before the keys are put back (and
# again before they are checked a second time). SALA_MODEL_INPLACE_ASKER_WAIT: seconds the queue's runner waits for the ASKING
# session to end the turn that queued the switch, before it relaunches that pane instead. model-inplace.tsv remembers what a live claude was switched to, since its
# command line (--model, --effort) no longer says: "<pid>\t<conversation id>\t<model>\t<effort or ->".
: "${SALA_MODEL_INPLACE:=on}" "${SALA_MODEL_INPLACE_WAIT:=20}" "${SALA_MODEL_INPLACE_SETTLE:=1}" "${SALA_MODEL_INPLACE_ASKER_WAIT:=90}"
SALA_MODEL_INPLACE_STATE="$SALA_STATE_DIR/model-inplace.tsv"
inplace_get() {  # <claude-pid> → "<model>\t<effort or ->" the live process was switched to in place, or nothing (a row of another conversation under a reused pid is no row)
    [ -n "${1:-}" ] && [ -r "$SALA_MODEL_INPLACE_STATE" ] || return 0
    local sid line r t=$'\t'; registry_field_r sid "$1" sessionId 2>/dev/null || sid=""
    { while IFS= read -r line || [ -n "$line" ]; do   # the awk of old, by expansion (a tab IFS would swallow an empty uuid field)
          [ "${line%%"$t"*}" = "$1" ] || continue
          [[ $line == *"$t"* ]] && r=${line#*"$t"} || r=""
          [ "${r%%"$t"*}" = "$sid" ] || continue
          [[ $r == *"$t"* ]] && r=${r#*"$t"} || r=""
          line=${r%%"$t"*}; [[ $r == *"$t"* ]] && r=${r#*"$t"} || r=""
          printf '%s\t%s\n' "$line" "${r%%"$t"*}"; return 0
      done < "$SALA_MODEL_INPLACE_STATE"; } 2>/dev/null
    return 0
}
inplace_put() {  # <claude-pid> <model> <effort or -> — one row per live pid; rows of dead processes dropped (called under the recycle lock)
    local f="$SALA_MODEL_INPLACE_STATE" t="$SALA_MODEL_INPLACE_STATE.t.$$" sid p u m e
    sid=$(registry_field "$1" sessionId 2>/dev/null); mkdir -p "$SALA_STATE_DIR" 2>/dev/null
    { [ -r "$f" ] && while IFS=$'\t' read -r p u m e; do [ "$p" != "$1" ] && kill -0 "$p" 2>/dev/null && printf '%s\t%s\t%s\t%s\n' "$p" "$u" "$m" "$e"; done < "$f"
      printf '%s\t%s\t%s\t%s\n' "$1" "$sid" "$2" "$3"; } > "$t" && mv -f "$t" "$f" || { rm -f "$t"; return 1; }
}
model_config_dir() {  # <claude-pid> <session> → the config directory that claude reads settings.json from: its own CLAUDE_CONFIG_DIR, else its lane's (subscription-2), else ~/.claude
    local e="/proc/${1:-0}/environ" d=""
    if [ -r "$e" ]; then local w; _nul_read "$e"; for w in ${_NUL[@]+"${_NUL[@]}"}; do [[ $w == CLAUDE_CONFIG_DIR=* ]] && { d=${w#CLAUDE_CONFIG_DIR=}; break; }; done; fi
    if [ -z "$d" ]; then
        if [ -r "$e" ]; then d="$HOME/.claude"
        else case "$(lane_for_session "${2:-}")" in subscription-2) d=$(lane_dir subscription-2);; *) d="$HOME/.claude";; esac; fi
    fi
    printf '%s\n' "$d"
}
# model_settings_snapshot <settings.json> <snapshot file> → 0 written; 3 the file exists but is not a JSON object (nothing may be
# restored into it: refuse to switch in place). The snapshot: whether the file existed, the top-level `model` (present?, value),
# and every `modelSettings.<id>.effortLevel` (and which ids the object held at all). A file that does not exist is a snapshot of nothing.
# model_settings_restore <settings.json> <snapshot file> → compare-and-restore: puts `model` and each `effortLevel` back to the
# snapshot ONLY where the file's current value differs, re-reading the file now so a key somebody else changed meanwhile is kept
# as it is; nothing differs → no write at all ("unchanged"). The write is atomic (a temp file in the same directory, fsync, the
# original's mode, rename over the real path), keeps the file's indentation and trailing newline, and never touches another key.
# Exit 0 (one line on stdout: "unchanged" · "restored: …" · "removed: …" · "file gone"), 3 unreadable file, 4 write failed (the file untouched).
model_settings_snapshot() { _model_settings_py snap "$1" "$2"; }
model_settings_restore()  { _model_settings_py restore "$1" "$2"; }
_model_settings_py() {
    python3 - "$@" <<'PYSET'
import json, os, stat, sys, tempfile
mode, path, snapf = sys.argv[1:4]
MISSING = object()
def load(p):
    try:
        with open(p, encoding="utf-8") as f: raw = f.read()
    except FileNotFoundError:
        return None, ""
    obj = json.loads(raw)
    if not isinstance(obj, dict): raise ValueError("not an object")
    return obj, raw
def efforts(d):
    ms = d.get("modelSettings"); out = {}
    if isinstance(ms, dict):
        for k, v in ms.items():
            if isinstance(v, dict) and "effortLevel" in v: out[k] = v["effortLevel"]
    return out
def ms_ids(d):
    ms = d.get("modelSettings"); return sorted(ms) if isinstance(ms, dict) else []
try:
    cur, raw = load(path)
except Exception as e:
    print("unreadable: %s" % e); sys.exit(3)
if mode == "snap":
    d = cur or {}
    snap = {"exists": cur is not None, "has_model": "model" in d, "model": d.get("model"), "has_ms": "modelSettings" in d,
            "ids": ms_ids(d), "efforts": efforts(d)}
    with open(snapf, "w", encoding="utf-8") as f: json.dump(snap, f)
    sys.exit(0)
snap = json.load(open(snapf, encoding="utf-8"))
if cur is None:
    print("file gone"); sys.exit(0)
changed = []
if ("model" in cur) != snap["has_model"] or (snap["has_model"] and cur.get("model") != snap["model"]):
    if snap["has_model"]: cur["model"] = snap["model"]
    else: cur.pop("model", None)
    changed.append("model")
now = efforts(cur)
for k in sorted(set(now) | set(snap["efforts"])):
    want, have = snap["efforts"].get(k, MISSING), now.get(k, MISSING)
    if want == have: continue
    if want is MISSING:
        ms = cur["modelSettings"]; ms[k].pop("effortLevel", None)
        if not ms[k] and k not in snap["ids"]: del ms[k]
        if not ms and not snap["has_ms"]: del cur["modelSettings"]
    else:
        ms = cur.get("modelSettings")
        if not isinstance(ms, dict): ms = cur["modelSettings"] = {}
        if not isinstance(ms.get(k), dict): ms[k] = {}
        ms[k]["effortLevel"] = want
    changed.append("effort(%s)" % k)
if not changed:
    print("unchanged"); sys.exit(0)
real = os.path.realpath(path)
try:
    if not snap["exists"] and not cur:
        os.remove(real); print("removed: " + ", ".join(changed)); sys.exit(0)
    ind = None
    for line in raw.split("\n")[1:]:
        s = line.lstrip(" \t")
        if s and s != line:
            ind = "\t" if line[0] == "\t" else len(line) - len(s); break
    text = json.dumps(cur, indent=ind, ensure_ascii=False) + ("\n" if raw.endswith("\n") or not raw else "")
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(real), prefix=".settings.json.sala-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text); f.flush(); os.fsync(f.fileno())
        if os.path.exists(real): os.chmod(tmp, stat.S_IMODE(os.stat(real).st_mode))
        os.replace(tmp, real)
    except BaseException:
        try: os.remove(tmp)
        except OSError: pass
        raise
except Exception as e:
    print("write failed: %s" % e); sys.exit(4)
print("restored: " + ", ".join(changed))
PYSET
}

# resume_cmd <uuid> [tmux session] → the line that resumes a conversation in a pane's shell: on the session's lane
# (lane_env_prefix, lane_args; no session → the default lane), with the mod, and with the effort it ran on
# (revive, the self-worker, unpark — here, where unpark can reach it), and with its model family as --model
# (model_family_for_uuid: panes once stayed on a pinned claude-opus-5 across a relaunch). The line is
# built fresh on every call, so a relaunch never stacks a second --mcp-config onto an old one (tests/lanes.sh counts it).
# The settings' defaultMode goes on as --permission-mode (permission_mode_args: a resume otherwise restores the mode its transcript recorded). spawn --fork takes --model from its own flag and does not come through here. A model or effort recorded for the session
# (models above, `sala model`) wins over the transcript's: the model always, the effort when the row has one ("-": the
# transcript's effort, as before).
# A third argument "parked" (close_pane, a pane parked on a background job) adds `--name <session>`: the job's
# conversation carries the job's own title (it renamed itself, "background-4a"), and a resume without --name takes that title
# as the pane's name in the registry, where sala-web and the overview match by name. Probed on CLI 2.1.312: `--resume <uuid>
# --name X` registers the row as name X, nameSource "user", over the transcript's stored title. The same marker, "named",
# comes from close_pane for an ordinary revive whose pane's current row has a name other than the tmux session's and a nameSource
# other than "user" (a conversation that stored a job's title, "background-4a", would take it again; a hand rename, nameSource
# "user", stays: lib/rename.sh follows it). Any other revive passes no --name (its transcript already carries the session's
# name, and a /rename made in the pane since then stays); the sdk lane's pane program takes none (the driver starts the SDK's
# CLI). A name outside [a-z0-9-] is not typed.
resume_cmd() {
    local flags eff fam lane rec rmod reff cmp nm=""; flags=$(_resume_flags_for_uuid "$1")
    [ "${3:-}" = parked -o "${3:-}" = named ] && [[ ${2:-} =~ ^[a-z0-9][a-z0-9-]*$ ]] && nm=" --name $2"
    eff=${flags%%$'\t'*}; fam=""; [[ $flags == *$'\t'* ]] && fam=${flags#*$'\t'}; fam=${fam%%$'\t'*}   # cut -f1, cut -f2 -s
    rec=$(model_row "${2:-}")
    if [ -n "$rec" ]; then
        rmod=${rec%%$'\t'*}; reff=""; [[ $rec == *$'\t'* ]] && reff=${rec#*$'\t'}; reff=${reff%%$'\t'*}
        model_valid "$rmod" && fam="$rmod"                                   # a row hand-edited into a bad value is ignored, never typed
        [ "$reff" != - ] && effort_known "$reff" && eff="$reff"
    fi
    lane=$(lane_for_session "${2:-}")
    # an sdk row after the credit's window launches on subscription-1 (lane_effective): said once per relaunch, here, in lanes.log
    [ "$lane" = subscription-1 ] && [ "$(lane_row "${2:-}")" = sdk ] && lane_log fallback "${2:-}" "sdk → subscription-1 ($(sdk_closed_why); the row stays: salamander lane subscription-1 ${2:-<session>} to clear it)"
    # the sdk lane's pane program in place of claude (lib/sdk-pane.sh): the model and effort go to it, the key never does
    # (the wrapper reads the lane's files itself); no mod prefix — the SDK's CLI loads the user settings, whose env names the mod
    [ "$lane" = sdk ] && { echo "$SALA_BIN sdk-pane $1 ${2:--}${fam:+ --model $fam}${eff:+ --effort $eff}"; return; }
    compact_tokens_r cmp "${2:-}"   # the session's compact window (compact.tsv); none: the project setting applies
    echo "$(lane_env_prefix "$lane")$(mod_env_prefix)claude --resume $1$nm${fam:+ --model $fam}${eff:+ --effort $eff}${cmp:+ --autocompact $cmp}$(lane_args "$lane")$(permission_mode_args "$lane")"
}
# mod_reply_field <reply json> <key> → that field as text (empty when absent; true/false for ok)
mod_reply_field() {
    # a flat reply object ({"ok":true} · {"ok":false,"reason":"…"}: strings without escapes, true/false/null, whole numbers) is read here;
    # anything else (a nested value, an escape, a fraction) goes to python as before (a python start per reply field)
    local _j=$1 _k=$2 _re_obj _re_key
    _re_obj='^[[:space:]]*\{([[:space:]]*"[A-Za-z0-9_]+"[[:space:]]*:[[:space:]]*("[^"\\]*"|true|false|null|-?[0-9]+)[[:space:]]*,?)*[[:space:]]*\}[[:space:]]*$'
    if [[ $_k =~ ^[A-Za-z0-9_]+$ ]] && [[ $_j =~ $_re_obj ]]; then
        _re_key='"'$_k'"[[:space:]]*:[[:space:]]*("([^"\\]*)"|true|false|null|-?[0-9]+)'
        if [[ $_j =~ $_re_key ]]; then
            case ${BASH_REMATCH[1]} in \"*) printf '%s\n' "${BASH_REMATCH[2]}" ;; null) echo ;; *) printf '%s\n' "${BASH_REMATCH[1]}" ;; esac
        else echo; fi
        return 0
    fi
    python3 -c 'import json,sys
try: v=json.loads(sys.argv[1]).get(sys.argv[2])
except Exception: v=None
print("" if v is None else (str(v).lower() if isinstance(v,bool) else v if isinstance(v,str) else json.dumps(v)))' "$1" "$2" 2>/dev/null
}
# _mod_target_py <registry row> <start> <version> <dir>… → the lookup below in python (the form the stamp or the row has when the shell cannot read it)
_mod_target_py() {
    python3 - "$@" <<'PYMOD' 2>/dev/null
import json, os, stat, sys
reg, start, want, dirs = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4:]
try: row = json.load(open(reg))
except Exception: print("-\tno registry row"); sys.exit()
sid, sock = row.get("sessionId") or "", row.get("messagingSocketPath") or ""
if not sid or "/" in sid: print("-\tno session id"); sys.exit()
try: ok = stat.S_ISSOCK(os.stat(sock).st_mode)
except Exception: ok = False
if not ok: print("-\tno messaging socket"); sys.exit()
why = "no stamp"
for d in dirs:
    try: s = json.load(open(os.path.join(d, sid + ".json")))
    except FileNotFoundError: continue
    except Exception: why = "unreadable stamp"; continue
    if s.get("present") is not True or s.get("sessionId") != sid: why = "a stamp for another session"; continue
    if int(s.get("version") or 0) < want: why = "mod version %s" % s.get("version"); continue
    # written before this process started: a pane resumed without the mod after a run with it (2 s: ps counts whole seconds)
    if float(s.get("at") or 0) / 1000 < start - 2: why = "a stamp older than the process"; continue
    print("%s\t%s\t%s" % (sid, sock, d)); sys.exit()
print("-\t" + why)
PYMOD
}
# _mod_target_r <var> <pid> <start> → in <var>: "<sid>\t<socket>\t<dir>" for a pane whose mod answers, or "-\t<why>". The registry row and the stamp
# are read by the shell when they are the flat one-line objects the CLI and the mod write (a python start per request);
# any other shape goes to the python above, so the answers and their words stay the same.
_mod_target_r() {
    local _tv=$1 _pid=$2 _start=$3 _reg="$SALA_REG_DIR/$2.json" _sid _sock _why="no stamp" _d _sf _c _ver _at _ssid _re_flat
    local -a _dirs=()
    _re_flat='^[[:space:]]*\{([[:space:]]*"[A-Za-z0-9_]+"[[:space:]]*:[[:space:]]*("[^"\\]*"|true|false|null|-?[0-9]+)[[:space:]]*,?)*[[:space:]]*\}[[:space:]]*$'
    while IFS= read -r _d; do [ -n "$_d" ] && _dirs+=("$_d"); done <<< "$(mod_run_dirs)"
    [ -r "$_reg" ] || { printf -v "$_tv" '%s' $'-\tno registry row'; return 0; }
    registry_field_r _sid "$_pid" sessionId; registry_field_r _sock "$_pid" messagingSocketPath
    if [ -z "$_sid" ]; then printf -v "$_tv" '%s' "$(_mod_target_py "$_reg" "$_start" "$SALA_MOD_VERSION" ${_dirs[@]+"${_dirs[@]}"})"; return 0; fi
    [ "${_sid#*/}" = "$_sid" ] || { printf -v "$_tv" '%s' $'-\tno session id'; return 0; }
    [ -S "$_sock" ] || { printf -v "$_tv" '%s' $'-\tno messaging socket'; return 0; }
    for _d in ${_dirs[@]+"${_dirs[@]}"}; do
        _sf="$_d/$_sid.json"; [ -e "$_sf" ] || continue
        _c=""; { IFS= read -r -d '' _c < "$_sf"; } 2>/dev/null || :
        if [ -z "$_c" ] || ! [[ $_c =~ $_re_flat ]]; then   # unreadable, or not a flat object: python judges it
            printf -v "$_tv" '%s' "$(_mod_target_py "$_reg" "$_start" "$SALA_MOD_VERSION" ${_dirs[@]+"${_dirs[@]}"})"; return 0
        fi
        if ! [[ $_c =~ \"present\"[[:space:]]*:[[:space:]]*true ]]; then _why="a stamp for another session"; continue; fi
        _ssid=""; [[ $_c =~ \"sessionId\"[[:space:]]*:[[:space:]]*\"([^\"\\]*)\" ]] && _ssid=${BASH_REMATCH[1]}
        [ "$_ssid" = "$_sid" ] || { _why="a stamp for another session"; continue; }
        _ver=""; [[ $_c =~ \"version\"[[:space:]]*:[[:space:]]*(-?[0-9]+) ]] && _ver=${BASH_REMATCH[1]}
        if [ "${_ver:-0}" -lt "$SALA_MOD_VERSION" ]; then _why="mod version ${_ver:-None}"; continue; fi
        _at=0; [[ $_c =~ \"at\"[[:space:]]*:[[:space:]]*(-?[0-9]+) ]] && _at=${BASH_REMATCH[1]}
        if [ "$_at" -lt $(( (_start - 2) * 1000 )) ]; then _why="a stamp older than the process"; continue; fi
        printf -v "$_tv" '%s' "$_sid"$'\t'"$_sock"$'\t'"$_d"; return 0
    done
    printf -v "$_tv" '%s' $'-\t'"$_why"
}
# mod_request <claude-pid> <verb> [arg] → 0 replied ok · 1 replied with a refusal (its reason in the reply) · 3 no mod to
# ask (no stamp, a stamp from before this process, no socket, the push failed) · 4 asked, no reply within SALA_MOD_WAIT s.
# Sets MOD_REPLY (the reply, one JSON line) and MOD_WHY (a few words for the log line: "ok", "no stamp", "no reply in 3s",
# "refused: draft"), so call it directly, not in $(…). On 3 and 4 the caller takes the keys path; the mod_log line is its.
mod_request() {
    local pid="$1" verb="$2" arg="${3:-}" target sid sock dir req f out="" i n start
    MOD_WHY=""; MOD_REPLY=""
    [ -n "$pid" ] && proc_alive "$pid" || { MOD_WHY="no claude process"; return 3; }
    _now_r start; start=$(( start - $(proc_etime "$pid" 2>/dev/null || echo 0) ))
    _mod_target_r target "$pid" "$start"   # "<sid>\t<socket>\t<dir>", or "-\t<why>"
    case "$target" in "-	"*|"") MOD_WHY="${target#-	}"; MOD_WHY="${MOD_WHY:-no stamp}"; return 3;; esac
    IFS=$'\t' read -r sid sock dir <<< "$target"
    _now_r req; req="$req-${BASHPID:-$$}-$RANDOM"; f="$dir/$sid.$req.reply.json"
    find "$dir" -maxdepth 1 -name '*.reply.json*' -mmin +10 -delete 2>/dev/null   # replies nobody waited for any more
    # the second line is for the model, should the mod ever fail to take the line: it then arrives as a turn
    session_push "$sock" "$SALA_MOD_MARK $verb $req${arg:+ $arg}"$'\n'"(An automatic control line from salamander for its in-session mod. If you can read this, the mod is not loaded: ignore it and do nothing.)" >/dev/null 2>&1 \
        || { MOD_WHY="the push failed"; return 3; }
    case "$SALA_MOD_WAIT" in ''|*[!0-9]*) n=$(awk -v w="$SALA_MOD_WAIT" 'BEGIN { print int(w * 10) }') ;; *) n=$(( 10#$SALA_MOD_WAIT * 10 )) ;; esac
    for ((i=0; i<n; i++)); do
        [ -s "$f" ] && { out=""; { IFS= read -r -d '' out < "$f"; } 2>/dev/null || :; while [[ $out == *$'\n' ]]; do out=${out%$'\n'}; done; rm -f "$f"; break; }
        _nap 0.1
    done
    [ -n "$out" ] || { MOD_WHY="no reply in ${SALA_MOD_WAIT}s"; return 4; }
    MOD_REPLY="$out"
    if [ "$(mod_reply_field "$out" ok)" = true ]; then MOD_WHY="ok"; return 0; fi
    MOD_WHY="refused: $(mod_reply_field "$out" reason)"; return 1
}
_mod_who() { local n; n=$(tmux display -p -t "$1" '#{session_name}' 2>/dev/null); echo "${n:-$1}"; }   # <pane> → its session name
# pane_exit <pane> <claude-pid> → 0 /exit is on its way (the mod took it, or it was typed) · 2 refused: background work is
# running · 3 refused: a draft is in the composer (its text on stdout) · 4 refused: a turn is running (an /exit run then
# reaches the model as a prompt; what holds it on stdout, when the mod names it) · 1 the keys did not take it. Process death is the caller's to verify, as it always was
# (exit_wait).
# THE SDK LANE'S PANE (lib/sdk-pane.sh, contrib/sdk-pane/driver.py): the mod is asked as for any pane, and its
# gates hold (a draft in the box, a turn, work in flight), but the /exit it runs on "ok" ends nothing in a CLI the Agent
# SDK drives — there is no interactive session to leave: the process stays, registered and idle, its stamp in place
# (a lane move took the ok, waited 30 s for a shell and skipped it; the
# pane sat at the driver's empty box). That pane leaves through the box: /exit typed there makes the driver disconnect,
# which ends the CLI, then the driver and the wrapper, and the pane is back at its shell.
pane_exit() {
    local out rc reason scr h
    # the screen first: a draft it shows counts even when the mod's prompt box is empty (see pane_draft)
    scr=$(pane_draft_screen "$1"); [ -n "$scr" ] && ! printf '%s' "$scr" | grep -Eq "$SALA_OWN_RESIDUE" && { mod_log "exit $(_mod_who "$1") not sent (the screen shows a draft)"; printf '%s\n' "$scr"; return 3; }
    mod_request "$2" exit; rc=$?; out="$MOD_REPLY"
    if [ "$rc" = 0 ]; then
        if [ "$(proc_lane "$2")" = sdk ]; then
            # the mod's ok is its gates passed; should its /exit have ended the CLI after all (a later CLI), the pane is at its
            # shell already and nothing is typed into it
            case "$(tmux display -p -t "$1" '#{pane_current_command}' 2>/dev/null)" in bash|sh|zsh|fish) mod_log "exit $(_mod_who "$1") via mod (ok; the SDK's CLI ended on it)"; return 0;; esac
            mod_log "exit $(_mod_who "$1") via mod (ok) then keys (an SDK-driven CLI: /exit typed into the sdk pane's box)"
            tui_send "$1" "/exit"; return
        fi
        mod_log "exit $(_mod_who "$1") via mod (ok)"; return 0
    fi
    if [ "$rc" = 1 ]; then
        reason=$(mod_reply_field "$out" reason)
        case "$reason" in
            background)
                # an older mod (it is read at the process's start) still refuses for an artifact watch,
                # and one loaded before its follow-up for any label but "auto-armed on publish": when
                # its refusal names monitors only and this stretch's busy record says those are all such
                # watches, the exit goes by keys, which the CLI's exit dialog does not hold for one (it lists none)
                if mod_refused_watch_only "$out" "$2"; then MOD_WHY="the mod refused for the artifact watch alone (a mod loaded before the fix)"
                # THE RESCUE (lib/revive.sh --rescue): the mod's list is the Stop hook's copy of the CLI's task
                # registry, stale for a shell stopped by hand; with no child process under the claude the refusal is a
                # stale row's, and the exit goes by keys — the CLI's own dialog then lists the same rows, and exit_wait
                # confirms it under the same flag and the same test. A live child keeps the refusal.
                elif [ "${SALA_RESCUE:-0}" = 1 ] && [ -z "$(work_children "$2")" ]; then MOD_WHY="rescue: the mod refused for background work ($(mod_reply_field "$out" tasks)), but no child process runs under the claude — a stale task row"
                else mod_log "exit $(_mod_who "$1") via mod (refused: background work)"; return 2; fi ;;
            turn)
                # the mod names what holds it (a mod from this release on; an older one sends no "holders"): printed for the caller, who puts it in its
                # skip line. An older mod's list is the one that can hold a turn that ended unseen; after SALA_STALE_TURN_AFTER refusals (close_pane
                # sets SALA_STALE_TURN_OK) with nothing named, and while sala's own check (the registry, the Stop record, the children, the
                # subagents' transcripts) still reads the pane as idle, the exit goes by keys: the CLI's exit dialog guards what runs
                h=$(mod_reply_field "$out" holders)
                if [ -z "$h" ] && [ "${SALA_STALE_TURN_OK:-0}" = 1 ] && [ -z "$(is_idle_reason "$2")" ]; then
                    MOD_WHY="the mod refused for a turn it could not name, ${SALA_STALE_TURN_N:-several} times, while the registry, the Stop record, the child processes and the subagent transcripts all read the pane as idle (a mod loaded before its turn list was reconciled)"
                else mod_log "exit $(_mod_who "$1") via mod (refused: a turn is running${h:+; held by $h})"; printf '%s\n' "$h"; return 4; fi ;;
            draft) scr=$(mod_reply_field "$out" text | tr '\n' ' ' | sed 's/[[:space:]]*$//')
                   # a command sala itself left in the box is no one's draft: the keys path clears it and types /exit
                   if ! printf '%s' "$scr" | grep -Eq "$SALA_OWN_RESIDUE"; then mod_log "exit $(_mod_who "$1") via mod (refused: a draft)"; printf '%s\n' "$scr"; return 3; fi
                   MOD_WHY="sala's own leftover command in the box" ;;
        esac
    fi
    # a claude already gone has nothing to /exit: typed into the shell it would run as a command
    proc_alive "$2" || { mod_log "exit $(_mod_who "$1") not sent (the claude is gone)"; return 0; }
    mod_log "exit $(_mod_who "$1") via keys ($MOD_WHY)"
    tui_send "$1" "/exit"
}
# THE REFUSAL MEMORY. An exit the mod refused for a turn used to leave no trace: the retry worker, then the deferred list, tried again
# and said the same thing at every tick. refused/<uuid> is one line, "<count>\t<first at>\t<last at>\t<why>", written by close_pane
# (lib/revive.sh) each time the exit is refused for a turn, read by it, by watch's deferred list and by `sala ready`, and removed when
# the pane relaunches. It is how many times the same refusal came, since when, and for what.
SALA_REFUSED_DIR="$SALA_STATE_DIR/refused"
: "${SALA_STALE_TURN_AFTER:=3}"   # refusals for a turn the mod cannot name before the exit goes by keys while sala's own check reads the pane as idle
# refusal_note <uuid> <why> → the count after this one, on stdout
refusal_note() {
    local f="$SALA_REFUSED_DIR/$1" n=0 first last now; _now_r now; first=$now
    [ -n "${1:-}" ] || { echo 0; return 0; }
    mkdir -p "$SALA_REFUSED_DIR" 2>/dev/null
    [ -r "$f" ] && IFS=$'\t' read -r n first last _ < "$f"
    case "$n" in ''|*[!0-9]*) n=0; first=$now;; esac
    n=$((n + 1)); printf '%s\t%s\t%s\t%s\n' "$n" "${first:-$now}" "$now" "${2//$'\t'/ }" > "$f.t.${BASHPID:-$$}" && mv -f "$f.t.${BASHPID:-$$}" "$f"
    echo "$n"
}
# refusal_get <var> <uuid> → "<count>\t<first>\t<last>\t<why>" in <var>, empty when none
refusal_get() { local _r=""; [ -n "${2:-}" ] && [ -r "$SALA_REFUSED_DIR/$2" ] && { IFS= read -r _r < "$SALA_REFUSED_DIR/$2"; } 2>/dev/null; printf -v "$1" '%s' "$_r"; }
refusal_clear() { [ -n "${1:-}" ] && rm -f "$SALA_REFUSED_DIR/$1" "$SALA_REFUSED_DIR/$1.said" 2>/dev/null; return 0; }
refusal_prune() { [ -d "$SALA_REFUSED_DIR" ] && find "$SALA_REFUSED_DIR" -maxdepth 1 -type f -mtime +9 -delete 2>/dev/null; return 0; }   # watch: the memory of sessions long gone
# deferred_row_for <claude-pid> → the deferred list's row for the pane this claude runs in (matched by the pid the row was written
# with, else by the tmux session the pane belongs to), nothing when the pane is not on the list. The list is a recycle's own
# waiting: a pane on it is waited for whatever its sets say (a set gives a pane up after SALA_LATER_LIMIT; the row does not).
deferred_row_for() {
    local row="" s
    [ -s "$SALA_DEFERRED" ] || return 0
    row=$(awk -F'\t' -v p="${1:-x}" '$4 == p && p != 0 {print; exit}' "$SALA_DEFERRED")
    if [ -z "$row" ] && [ -n "${TMUX_PANE:-}" ]; then
        s=$(tmux display -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)
        [ -n "$s" ] && row=$(awk -F'\t' -v s="$s" '$1 == s {print; exit}' "$SALA_DEFERRED")
    fi
    printf '%s\n' "$row" | grep .
    return 0
}
# mod_hold <claude-pid> → 0 and one line on stdout ("a turn is running: <what holds it>") when the in-session mod says a turn is running
# and names it (the `busy` probe: the gates of an exit, nothing run); 1 for every other answer: free, no mod, a mod that does not know the
# probe, or one that names no holder. What a sweep and the deferred list ask before they try an exit that would be refused.
mod_hold() {
    local rc=0 h; mod_request "$1" busy || rc=$?
    [ "$rc" = 1 ] && [ "$(mod_reply_field "$MOD_REPLY" reason)" = turn ] || return 1
    h=$(mod_reply_field "$MOD_REPLY" holders); [ -n "$h" ] || return 1
    printf 'a turn is running: %s\n' "$h"
}
# mod_refused_watch_only <reply json> <claude-pid> → 0 when a background refusal lists only monitors, as many as this stretch's
# busy record has artifact watches, and the record has nothing else in flight (busy_state 1)
mod_refused_watch_only() {
    local sid tasks w rc=0
    sid=$(registry_field "$2" sessionId 2>/dev/null); [ -n "$sid" ] || return 1
    busy_state "$2" "$sid" >/dev/null 2>&1 || rc=$?; [ "$rc" = 1 ] || return 1
    w=$(_nlines "$(busy_watches "$2" "$sid")"); [ "$w" -gt 0 ] || return 1
    tasks=$(python3 -c 'import json,sys
try: t=json.loads(sys.argv[1]).get("tasks")
except Exception: t=None
if not isinstance(t, list) or not all(isinstance(x, str) and x.split(" ")[0] == "monitor" for x in t): sys.exit(1)
print(len(t))' "$1" 2>/dev/null) || return 1
    [ "$tasks" -gt 0 ] && [ "$tasks" -le "$w" ]
}
# pane_rename <pane> <claude-pid> <name> → 0 renamed through the mod or typed. The mod needs no empty composer; the keys
# still refuse over a draft (tui_send).
pane_rename() {
    mod_request "$2" rename "$3" && { mod_log "rename $(_mod_who "$1") via mod (ok)"; return 0; }
    mod_log "rename $(_mod_who "$1") via keys ($MOD_WHY)"
    tui_send "$1" "/rename $3"
}
# boot_id → an id that changes on every boot (Linux: the kernel's boot_id; macOS: kern.boottime seconds)
boot_id() { [ -n "${SALA_BOOT_ID:-}" ] && { echo "$SALA_BOOT_ID"; return; }; local _b=""; { read -r _b < /proc/sys/kernel/random/boot_id; } 2>/dev/null && [ -n "$_b" ] && { echo "$_b"; return; }; sysctl -n kern.boottime 2>/dev/null | sed -E 's/.*sec = ([0-9]+).*/\1/'; }
# shutting_down → 0 between `sala reboot`'s marker and the reboot itself (the marker names this boot): no snapshot or map save then
shutting_down() {   # also during ANY shutdown (systemd says "stopping"), however it was started
    [ "$(systemctl is-system-running 2>/dev/null)" = stopping ] && return 0
    local b cur; _kv_first_r b "$SALA_LOG_DIR/salamander-reboot.marker" boot_id; b=${b%%=*}; [ -n "$b" ] || return 1; cur=$(boot_id); [ "$b" = "$cur" ]; }
# boot_epoch → when this boot started (epoch seconds)
boot_epoch() {
    if [ -r /proc/uptime ]; then local _up _now; read -r _up _ < /proc/uptime; _now_r _now; echo $(( _now - ${_up%%.*} ))
    else sysctl -n kern.boottime 2>/dev/null | sed -E 's/.*sec = ([0-9]+).*/\1/'; fi
}
# local_human [epoch] → "21:05 UTC Sun Sep 28th" in SALA_TZ (this machine's local time when unset; the label is the zone's own), the display form
local_human() {
    local e="${1:-}" d suf o
    [ -n "$e" ] || _now_r e
    if [ "$_WHEN_TZ" = 1 ] && [[ $e =~ ^[0-9]+$ ]]; then   # the shell's own strftime (the real date for anything but an epoch, as before)
        if [ -n "$SALA_TZ" ]; then TZ="$SALA_TZ" printf -v d '%(%-d)T' "$e"; TZ="$SALA_TZ" printf -v o '%(%H:%M %Z %a %b)T' "$e"
        else printf -v d '%(%-d)T' "$e"; printf -v o '%(%H:%M %Z %a %b)T' "$e"; fi
    else
        d=$(cs_date -d "@$e" '+%-d' 2>/dev/null || cs_date -r "$e" '+%-d')
        o=$(cs_date -d "@$e" '+%H:%M %Z %a %b' 2>/dev/null || cs_date -r "$e" '+%H:%M %Z %a %b')
    fi
    case "$d" in 1|21|31) suf=st;; 2|22) suf=nd;; 3|23) suf=rd;; *) suf=th;; esac
    echo "$o ${d}${suf}"
}

# ── one driver ────────────────────────────────────────────────────────────────
# master_guard <verb> [args…] → 0 when this invocation may drive a recycle of this box, else dies.
# A recycle relaunches every pane, the invoking one included; two drivers race the same panes. So a
# recycle is driven from the MASTER pane (SALA_MASTER) — any other pane hands the cue to it (the
# recycle procedure does that). Allowed regardless: not inside tmux (a human shell, systemd, cron);
# --dry-run / --check (read-only); --not-master (explicit override); and a master that is not live
# (the box must never become unrecyclable — said out loud).
# NO MASTER ("No master session", Thu Oct 15th 2026): with SALA_MASTER unset the operation queue (lib/op.sh) is
# the one driver, so a Claude session (claude_caller) is REFUSED and pointed to `sala op <verb> … --from NAME --words
# "<the owner's words>"` (a reboot is not queued: pointed to the owner running `sala reboot --go` directly); a human's pane shell, a plain shell, systemd (the watch and its units, cron) and the resurrect boot
# hook pass as before. Until Thu Oct 15th a missing master let any pane run the verb, with a notice: the master's
# absence then meant "nobody holds the one-driver rule", now it means "the queue holds it".
# SIDE SESSIONS add no guarded verb: `spawn --side` is as free as any spawn (not a fleet operation, never guarded here; a session starts
# one through the queue, `sala op spawn NAME --side …`, with the owner's words), `sala side done` writes only the caller's own record and `sala sessions
# transcript` only reads. A side session's retire is the ordinary `retire` verb, gated by lib/retire.sh on the write-up marker (--skip-writeup the one bypass).
# ops_guard <verb> <target> [args…] — fleet operations (retire, revive) belong to the master session (the sala builder builds and
# tests; it does not run them). Applied only when a Claude session is the caller (a
# `claude` process among our ancestors): the resurrect boot hook, `sala watch` and a human shell pass untouched. A
# throwaway target named sala-test-* passes from any pane, so the sala builder can test on its own panes.
# THE OPERATION QUEUE (lib/op.sh): a verb run inside a sala-op-<id> transient unit is the queue's runner, which
# takes the recycle lock and runs one operation at a time in place of the master's pane — both guards admit it by the
# unit's name in the caller's cgroup (op_unit_caller), read from /proc/self/cgroup (SALA_CGROUP_FILE: the tests). The Bash
# guard hook (lib/guard.py) keeps its logic: a session typing the raw command is denied as before, pointed to `sala op`.
op_unit_caller() { local _cg=""; { IFS= read -r -d '' _cg < "${SALA_CGROUP_FILE:-/proc/self/cgroup}"; } 2>/dev/null || :; [[ $_cg =~ /sala-op-[0-9]+-[0-9]+\.service ]]; }   # (a grep -qE, read by the shell)
# claude_caller → 0 when a Claude session makes this call: a `claude` process among our ancestors (the walk stops at a tmux
# ancestor — launched by tmux itself, as the resurrect boot hook is, or a human's pane shell), or a pane that still names
# itself (TMUX_PANE) and runs a claude — a detached launch (setsid/nohup … &) reparented to systemd is a Claude session's
# call all the same (a detached `sala provision` from its pane once slipped past the ancestry walk)
claude_caller() {
    local p=$$ c np _a _b _c
    while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
        c=""; { read -r c < "/proc/$p/comm"; } 2>/dev/null || :   # (a cat and an awk per ancestor, read by the shell)
        [ "$c" = claude ] && return 0
        case "$c" in tmux*) return 1;; esac
        np=""; { read -r _a _b _c np _ < "/proc/$p/stat"; } 2>/dev/null || :; p=$np
    done
    [ -n "${TMUX_PANE:-}" ] && claude_pid_under "$(tmux display -p -t "$TMUX_PANE" '#{pane_pid}' 2>/dev/null)" >/dev/null 2>&1
}
ops_guard() {
    local verb="$1" target="$2"; shift 2
    op_unit_caller && return 0
    case "$target" in sala-test-*) return 0;; esac
    claude_caller || return 0
    master_guard "$verb" "$@"
}
master_guard() {
    local verb="$1"; shift; local a here mpane
    op_unit_caller && return 0   # the operation queue's runner (lib/op.sh) drives it in place of the master's pane
    for a in "$@"; do case "$a" in --dry-run|--check|--not-master) return 0;; esac; done
    if [ -z "${SALA_MASTER:-}" ]; then
        claude_caller || return 0   # a human's shell, systemd, cron, the boot hook: no one-driver rule to hold against them
        here=""; [ -n "${TMUX_PANE:-}" ] && here=$(tmux display -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)
        # the verbs the queue takes (lib/op.sh, THE VERBS); adopt and restore have no queue shape yet; a reboot is not
        # queued (SALA_OP_REBOOT off by default, unsupported until a confirmation path is built): the owner runs it directly
        case "$verb" in
            reboot)
                die "reboot is not queued: ${SALA_OWNER_NAME} runs \`sala reboot --go\` in the web UI's Shell; a session shows \`sala reboot --status\` and waits for the word" ;;
            recycle|update|revive|retire|close-shell|forget-row|rename|lane|model|provision)
                die "$verb is a fleet operation, and a session never runs one itself: the operation queue does (no master session is configured). Queue it — sala op $verb … --from ${here:-<you>} --words \"<${SALA_OWNER_NAME}'s words>\" — and sala's watch runs it, one operation at a time; sala op --plan $verb … shows the plan first (the recycle procedure does exactly that). Override only if you know why: --not-master" ;;
            *)  die "$verb is a fleet operation, and a session never runs one itself (no master session is configured, and the operation queue has no '$verb' verb yet: lib/op.sh, THE VERBS). From a plain shell it runs; from a session only on ${SALA_OWNER_NAME}'s word, with --not-master" ;;
        esac
    fi
    [ -n "${TMUX_PANE:-}" ] || return 0
    here=$(tmux display -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null) || return 0
    [ "$here" = "$SALA_MASTER" ] && return 0
    mpane=$(tmux list-panes -t "$(tmux_win_t "$SALA_MASTER")" -F '#{pane_id}' 2>/dev/null | head -1)
    if [ -z "$mpane" ] || ! claude_pid_under "$(tmux display -p -t "$mpane" '#{pane_pid}')" >/dev/null 2>&1; then
        echo "⚠ master session '$SALA_MASTER' is not live — allowing '$verb' from '$here' (salamander watch normally revives the master first)" >&2
        sala_post "⚠️ *$verb ran from $here*" "the master $SALA_MASTER was not live, so the guard let it through"; return 0
    fi
    die "$verb is driven from the master session ('$SALA_MASTER'), not from '$here': hand it the cue with \`sala cue --from <you> \"<${SALA_OWNER_NAME}'s words>\"\` (the recycle procedure does exactly that), so two drivers never race the same panes. Override only if you know why: --not-master"
}

# ── recycle lock ──────────────────────────────────────────────────────────────
# One relaunch driver at a time: until now only the master's judgement and watch's
# pgrep kept two recycles apart, and two drivers would /exit and resume the same panes. The lock is flock(2) on
# $SALA_LOG_DIR/salamander-recycle.lock, taken on fd 9 by the command that starts a relaunch and held for its whole life
# AND its children's: the fd is inherited, so the detached driver (the sweep, then the self-worker) keeps it until both
# are done, and the kernel drops it the moment the last holder dies — no stale lock, ever. A child that must not hold it
# closes the fd (9>&-): the retry worker a recycle leaves behind (a new recycle kills it anyway) and the post-update hook.
# Takers: recycle, update's local leg (before `claude update`), a direct revive (--only and --self too), the resurrect
# post-restore revive — which waits up to 10 min for it, as does update --auto; never --dry-run, --check, --save-map,
# --map-history or the retry worker's own re-runs. A refused caller sees one line (since when, started by whom, the log)
# and exits 75 (EX_TEMPFAIL: try again later). The file carries the holder: pid of the driver, start epoch, who, log.
# Without flock(1) (the macOS base system) nothing is locked and the taker says so once.
# SHARED: the operation queue's parallel-safe operations (spawn, retire, rename; lib/op.sh, THE
# PARALLEL RULE) take it with recycle_lock_shared, several at once; the exclusive takers above wait for them all, as they did
# for the one operation that held it alone.
SALA_RECYCLE_LOCK="$SALA_LOG_DIR/salamander-recycle.lock"
recycle_lock() {  # <who> [wait-secs] → 0 holding it on fd 9 (or no flock here); 1 when someone else still holds it after the wait
    local who="$1" wait="${2:-0}" i
    command -v flock >/dev/null 2>&1 || { echo "⚠ no flock(1) on this system — relaunches are not serialized (the recycle lock needs it)" >&2; return 0; }
    mkdir -p "$SALA_LOG_DIR"; exec 9>>"$SALA_RECYCLE_LOCK"
    for ((i=0; ; i+=5)); do
        flock -n 9 && { recycle_lock_note "$who" "$$"; return 0; }
        [ "$i" -lt "$wait" ] || { exec 9>&-; return 1; }
        [ "$i" = 0 ] && echo "$(recycle_holder_line) — waiting for it (up to $((wait/60)) min)" >&2
        sleep 5
    done
}
recycle_lock_shared() {  # <who> [wait-secs] → 0 holding it SHARED on fd 9 (or no flock here); 1 when a relaunch driver still holds it exclusively after the wait
    # The queue's parallel-safe operations (lib/op.sh, THE PARALLEL RULE: spawn, retire, rename) hold the lock together: any number
    # of shared holders, never beside an exclusive one. Every relaunch driver takes it exclusively (recycle_lock: `flock -n`), so it
    # is refused while any of them runs, exactly as it was while one operation held it alone, and recycle_locked (a try for the
    # exclusive lock) still reads "locked" for every watch step that stands aside for a relaunch.
    local who="$1" wait="${2:-0}" i
    command -v flock >/dev/null 2>&1 || { echo "⚠ no flock(1) on this system — relaunches are not serialized (the recycle lock needs it)" >&2; return 0; }
    mkdir -p "$SALA_LOG_DIR"; exec 9>>"$SALA_RECYCLE_LOCK"
    for ((i=0; ; i+=5)); do
        flock -s -n 9 && { recycle_lock_note "$who" "$$"; return 0; }
        [ "$i" -lt "$wait" ] || { exec 9>&-; return 1; }
        [ "$i" = 0 ] && echo "$(recycle_holder_line) — waiting for it (up to $((wait/60)) min)" >&2
        sleep 5
    done
}
recycle_lock_note() { command -v flock >/dev/null 2>&1 || return 0; printf '%s\t%s\t%s\t%s\n' "$2" "$(date +%s)" "$1" "$SALA_LOG_DIR/salamander-revive.log" > "$SALA_RECYCLE_LOCK"; }   # <who> <pid>
recycle_lock_repid() {  # <pid> — the detached driver's pid into the holder line (the command that took the lock exits right after the detach)
    command -v flock >/dev/null 2>&1 || return 0
    local hpid hstart hwho hlog; IFS=$'\t' read -r hpid hstart hwho hlog < "$SALA_RECYCLE_LOCK" 2>/dev/null
    printf '%s\t%s\t%s\t%s\n' "$1" "${hstart:-$(date +%s)}" "${hwho:-?}" "${hlog:-$SALA_LOG_DIR/salamander-revive.log}" > "$SALA_RECYCLE_LOCK"
}
# cli_update — `claude update` under its own short lock (fd 4), so the watchdog's at-once update (`update --no-recycle`,
# which takes no recycle lock) and a recycle's own `--update` never run two updaters at once; the second waits up to
# 5 min, then runs anyway. Prints the updater's output; its exit status is the updater's.
cli_update() {
    command -v flock >/dev/null 2>&1 || { "$SALA_CLAUDE" update 2>&1 9>&-; return; }
    ( flock -w 300 4 || true; "$SALA_CLAUDE" update 2>&1 9>&- 4>&- ) 4>>"$SALA_LOG_DIR/salamander-cli-update.lock"
}
recycle_locked() { [ -e "$SALA_RECYCLE_LOCK" ] && command -v flock >/dev/null 2>&1 && ! { flock -n 9; } 9< "$SALA_RECYCLE_LOCK" 2>/dev/null; }   # → 0 while someone holds it
recycle_holder_line() {
    local hpid hstart hwho hlog; IFS=$'\t' read -r hpid hstart hwho hlog < "$SALA_RECYCLE_LOCK" 2>/dev/null
    echo "a recycle is already running since $(local_human "${hstart:-0}") (started by ${hwho:-?}, pid ${hpid:-?}) — log: ${hlog:-$SALA_LOG_DIR/salamander-revive.log}"
}
recycle_refuse() { echo "✗ $(recycle_holder_line)" >&2; exit 75; }
# invoked_by_hook → 0 when tmux itself ran this command (the resurrect post-restore hook): no tty, no pane, a tmux ancestor and no claude one
invoked_by_hook() {
    { [ -t 0 ] || [ -t 1 ]; } && return 1
    [ -z "${TMUX_PANE:-}" ] || return 1
    local p=$$ q c _a _b _c
    while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
        c=""; { read -r c < "/proc/$p/comm"; } 2>/dev/null; [ "$c" = claude ] && return 1
        case "$c" in tmux*) return 0;; esac
        q=$p; p=""; { read -r _a _b _c p _ < "/proc/$q/stat"; } 2>/dev/null || p=""   # field 4 of stat, as awk '{print $4}' read it
    done
    return 1
}
# _uname_r <var> → the name of the effective user: the first /etc/passwd line with this uid (getpwuid's answer for a local user), else `id -un`
_uname_r() {
    local _n _x _u _f
    { while IFS=: read -r _n _x _u _f; do [ "$_u" = "$EUID" ] && { printf -v "$1" '%s' "$_n"; return 0; }; done < /etc/passwd; } 2>/dev/null
    printf -v "$1" '%s' "$(id -un 2>/dev/null)"
}
lock_who() {  # who is relaunching, for the holder line: SALA_LOCK_WHO (watch sets it; update --auto says auto-update), the pane's session name, the boot hook, a shell
    [ -n "${SALA_LOCK_WHO:-}" ] && { echo "$SALA_LOCK_WHO"; return; }
    [ -n "${TMUX_PANE:-}" ] && tmux display -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null && return
    invoked_by_hook && { echo "the tmux-resurrect post-restore hook"; return; }
    local _un; _uname_r _un; echo "a shell ($_un)"
}

: "${SALA_FLEET_TIMEOUT:=8}"
SALA_SSH=(ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
# fleet_hosts [HOST…] → the given hosts, else SALA_FLEET_HOSTS, minus this machine
fleet_hosts() { local h; for h in ${@:-$SALA_FLEET_HOSTS}; do [ "$h" = "$_SALA_HN" ] || echo "$h" 2>/dev/null; done; }
# fleet_shell <host> → posix (the host answers ssh, a POSIX shell), or fails when it does not answer (asleep = offline, not an
# error). The fleet is Linux and macOS, so the probe is liveness alone.
fleet_shell() {
    timeout "$SALA_FLEET_TIMEOUT" "${SALA_SSH[@]}" "$1" true >/dev/null 2>&1 || return 1
    echo posix
}

# one remote round-trip; prints "SHELL|BEFORE|AFTER|ERR" (versions = first word of `claude --version`)
remote_update() {
    local host="$1" mode="$2" shellkind out
    shellkind=$(fleet_shell "$host") || { echo "offline|||"; return; }
    out=$(timeout 180 "${SALA_SSH[@]}" "$host" 'c=$(command -v claude || echo "$HOME/.local/bin/claude"); [ -x "$c" ] || { echo "ERR|claude not found"; exit; }
            b=$("$c" --version 2>/dev/null | head -1)
            if [ "'"$mode"'" = update ]; then u=$("$c" update 2>&1) || echo "ERR|$(printf %s "$u" | tail -1)"; fi
            a=$("$c" --version 2>/dev/null | head -1); echo "V|$b|$a"' 2>&1)
    local err v b a
    err=$(printf '%s\n' "$out" | tr -d '\r' | sed -n 's/^ERR|//p' | tail -1)
    v=$(printf '%s\n' "$out" | tr -d '\r' | grep '^V|' | tail -1)
    b=$(printf '%s' "$v" | cut -d'|' -f2 | awk '{print $1}'); a=$(printf '%s' "$v" | cut -d'|' -f3 | awk '{print $1}')
    [ -n "$v" ] || err=${err:-"no answer from the update step: $(printf '%s' "$out" | tr -d '\r' | tail -1)"}
    echo "$shellkind|$b|$a|$err"
}

# ── tmux ──────────────────────────────────────────────────────────────────────
unmode() {  # $1 = pane. copy-/view-mode swallows send-keys entirely; leave it first.
    [ "$(tmux display -p -t "$1" '#{pane_in_mode}' 2>/dev/null)" = 1 ] || return 0
    tmux send-keys -X -t "$1" cancel 2>/dev/null || tmux copy-mode -q -t "$1" 2>/dev/null
}
# leave_shell_mode <pane> → 0 when the pane's input box is a ❯ box (it was, or an Escape took it out of shell mode); 1, one line on
# stderr, when it is still in shell mode or must not be touched. Claude Code's shell mode (a "!" typed at an empty box) runs what is
# typed after it as a bash command, so "/exit", "/clear" or a message typed there would run as a shell command instead of reaching the
# session; and since the draft check reads an empty "!" box as empty (Fri Oct 30th 2026), nothing else stops it. Escape on an EMPTY
# shell-mode box returns it to an empty ❯ box (measured on 2.1.312, private socket: the "!" box, placeholder and all, is a ❯ box a
# moment later). One Escape only, then a poll of up to 3 s: a second one on a ❯ box can open the CLI's rewind menu. But an Escape
# is a key like any other, so it is sent only to a pane that is IDLE with a live shell box at the bottom of the screen:
#   - busy ("esc to interrupt" showing): Escape would interrupt the turn;
#   - a dialog or panel showing (pane_prompt), or no box in the last few rows (a dialog hides the box, and a stale "───" / "! text"
#     pair above it must not be read as one): Escape would deny or dismiss it;
#   - text in the "!" box, now or by the time the box is a ❯ box again: it is someone's, and /exit typed onto it would be sent with it.
# Each of these returns 1 and sends nothing (retire --busy types into non-idle panes on purpose; for a shell box there, failing is
# right). tui_send is the one caller; the mod's exit and rename run as commands inside the CLI and type nothing; the other send-keys
# in lib/ go to a shell (rc, resume_send, shell_send) or to a panel already open (feedback).
box_is_shell() { _box_from_capture "$(tmux capture-pane -pe -t "$1" 2>/dev/null)"; [ "$_BOX_GLYPH" = "!" ]; }   # <pane> → 0 when its input box is in shell mode
leave_shell_mode() {
    local i cap plain d
    cap=$(tmux capture-pane -pe -t "$1" 2>/dev/null); _box_from_capture "$cap"
    [ "$_BOX_GLYPH" = "!" ] || return 0
    if [ "$(( _BOX_N - 1 - _BOX_AT ))" -gt 6 ]; then
        echo "leave_shell_mode: '$1' shows no live input box at the bottom of the screen (a dialog?); no Escape sent" >&2; return 1; fi
    plain=$(printf '%s\n' "$cap" | tail -30 | sed 's/\x1b\[[0-9;]*m//g')
    if printf '%s\n' "$plain" | grep -q 'esc to interrupt'; then
        echo "leave_shell_mode: '$1' is busy (esc to interrupt); no Escape sent" >&2; return 1; fi
    if pane_prompt "$1"; then echo "leave_shell_mode: '$1' shows a dialog or panel; no Escape sent" >&2; return 1; fi
    d=$(printf '%s\n' "$cap" | draft_from_capture)
    if [ -n "$d" ]; then echo "leave_shell_mode: '$1' has text in its shell box (\"$d\"); no Escape sent" >&2; return 1; fi
    tmux send-keys -t "$1" Escape
    for ((i=0; i<10; i++)); do
        sleep 0.3
        cap=$(tmux capture-pane -pe -t "$1" 2>/dev/null); _box_from_capture "$cap"
        [ "$_BOX_GLYPH" = "❯" ] || continue   # still a shell box, or no box found (a dialog, a redraw): not success, poll on
        d=$(printf '%s\n' "$cap" | draft_from_capture)
        if [ -n "$d" ]; then echo "leave_shell_mode: '$1' has text (\"$d\") after the Escape; nothing typed into it" >&2; return 1; fi
        return 0
    done
    echo "leave_shell_mode: '$1' is still in shell mode (or shows no ❯ box) after an Escape; nothing typed into it" >&2
    return 1
}
# tui_send <pane> <text> — type a command or a message into a Claude Code COMPOSER and make sure it was taken.
# Every path that types into a Claude pane goes through here (revive/recycle /exit, feedback's
# /feedback, watch's /remote-control, retire's /exit, spawn's /rename and its brief line). Three rules, each from an
# incident:
#   - text and Enter are SEPARATE sends: in one send-keys call the TUI can drop the Enter and the
#     text stays in the composer (four panes held a stale "/feedback", and
#     the next command typed into them became "/feedback/model …" and vanished without an error);
#   - never type onto someone's unsubmitted line (it would be appended and sent as one message) —
#     EXCEPT a line that is exactly a command sala itself left behind, which is cleared first;
#   - never type into a box in shell mode (an empty "!" box): leave_shell_mode sends an Escape first, and fails, typing nothing, if it stays;
#   - verify the composer is empty afterwards; one extra Enter if not; else fail loudly.
# THE MESSAGE MARKER (Mon Oct 12th 2026; asked for by the board for its quote-origin check). Every MESSAGE sala
# types — text the session reads as a user turn: spawn's brief line, its --prompt — goes in with `<!-- sala -->` and a
# space in front, so the transcript's line reads `<!-- sala --> Read … in full …`. The CLI records a typed message with
# origin.kind "human", the same as the owner's own, and stackshot refuses a quote attributed to the owner from a message that
# carries the marker. The rule is here, not at the call sites, so a future caller gets it without knowing of it: text
# that starts with "/" is a slash command and is typed as it is (a marker would break it, and a command is not quotable
# prose); anything else is a message. A line for a pane's SHELL (spawn's launch line) goes through shell_send, never
# here. The marker shares the message's line instead of having one of its own: a newline typed into the composer
# submits, and the two ways round that (a backslash before Enter, bracketed paste) both record `<!-- sala -->\n…` but
# leave the screen's ❯ line reading the marker alone, so the checks below could not tell a taken message from a stuck
# one (measured on 2.1.296: the backslash-Enter two-liner needed a second Enter, the one-liner went on the first). A
# marked line left in a composer is sala's own (SALA_OWN_RESIDUE): cleared and typed over, as a leftover /exit is.
SALA_MSG_MARK='<!-- sala -->'   # fixed, not a config knob: stackshot matches this exact string at the start of a recorded user message
SALA_OWN_RESIDUE="^($SALA_MSG_MARK|/(feedback|exit|remote-control|clear|rename( .*)?)$)"
tui_send() {
    local pane="$1" text="$2" d
    case "$text" in /*) ;; *) text="$SALA_MSG_MARK $text" ;; esac
    unmode "$pane"
    d=$(pane_draft "$pane")
    if [ -n "$d" ]; then
        # sala's own leftover in a ❯ box is cleared with C-u; in a shell box it is not (C-u there is no clear we vouch for): refused like any text
        if printf '%s' "$d" | grep -Eq "$SALA_OWN_RESIDUE" && ! box_is_shell "$pane"; then tmux send-keys -t "$pane" C-u; sleep 0.3
        else echo "tui_send: '$pane' has unsubmitted text (\"$d\"); not typing \"$text\" onto it" >&2; return 1; fi
    fi
    leave_shell_mode "$pane" || return 1   # an empty "!" box reads as no draft above, and would run the text as a bash command
    tmux send-keys -t "$pane" -l "$text"; sleep 0.8; tmux send-keys -t "$pane" Enter; sleep 1
    d=$(pane_draft_screen "$pane")   # did the keys land: the screen's question (the mod may be exiting with the pane)
    if [ "$d" = "$text" ]; then tmux send-keys -t "$pane" Enter; sleep 1; d=$(pane_draft_screen "$pane"); fi
    if [ "$d" = "$text" ]; then
        tmux send-keys -t "$pane" C-u
        echo "tui_send: '$pane' did not take \"$text\" (still in the composer after two Enters); cleared it" >&2; return 1
    fi
    return 0
}
submit() { tui_send "$@"; }   # older name, kept for callers
# shell_send <pane> <line> — type a line into a pane whose foreground program is a SHELL (spawn's launch line; the resume
# line has resume_send, with its lock). Not a composer: no marker, no draft check. Text and Enter separate, as above.
# THE STUCK LINE: an interactive bash with ble.sh, whose Enter inserts a newline instead of running the
# line when it thinks more input is queued behind it (its accept_line_threshold: the Enter looks like part of a paste) or the
# line looks incomplete, and then shows "-- MULTILINE --" under the typed line, which waits for C-j. One spawn's claude never started
# that way (the line sat there for 45 s: "claude did not start"). Not reproduced on a private tmux socket with the real ble.sh
# (24 fresh shells at once, a long line, the box loaded), so the cause is a reading of ble.sh's source, not a measurement. After
# the Enter, a settle (SALA_SHELL_SETTLE), and if the pane is still at a shell with that banner among the last lines of its screen,
# C-j is sent once (ble.sh's accept-line runs the line as it is, newline or not); a second look says whether it took. A pane
# without ble.sh never shows the banner, so nothing more is sent.
shell_stuck() {  # <pane> → 0 when the pane's foreground program is a shell and its screen's last lines carry the multiline banner
    case "$(tmux display -p -t "$1" '#{pane_current_command}' 2>/dev/null)" in bash|sh|zsh|fish) ;; *) return 1;; esac
    tmux capture-pane -p -t "$1" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n 6 | grep -qF -- '-- MULTILINE --'
}
shell_send() {
    tmux send-keys -t "$1" -l "$2"; sleep 0.3; tmux send-keys -t "$1" Enter
    sleep "${SALA_SHELL_SETTLE:-1}"
    shell_stuck "$1" || return 0
    tmux send-keys -t "$1" C-j
    sleep "${SALA_SHELL_SETTLE:-1}"
    if shell_stuck "$1"; then echo "shell_send: '$1' still shows the multiline banner after C-j; the line may not have run" >&2; fi
    return 0
}
# pane_prompt <pane> → 0 when a terminal-only prompt/modal is visible (feedback-draft review, survey,
# permission or question dialog). Keys typed into such a pane are QUEUED as a message that fires when
# the prompt clears — once that turned a recycle's /exit into an unattended exit with no resume.
# Never type while one is showing. The pattern is SALA_PROMPT_RE, one place: the stuck-question watch
# (lib/watch.sh) reads the same last 30 lines with it, so what it posts is exactly what every relaunch waits out.
SALA_PROMPT_RE='Switch model|Send feedback|Draft preview|Turn off Claude-drafted|Send without reviewing|Any key to continue|Do you want to|\(esc to|Press Enter|❯ 1\.|Yes, and|No, and|quality survey|drafted: |unsent feedback draft|Feedback drafts'
pane_prompt() {
    tmux capture-pane -p -t "$1" 2>/dev/null | tail -30 | grep -qE "$SALA_PROMPT_RE"
}
# scrub_text (stdin → stdout) — text bound for a post or a log with anything that looks like a secret masked as "…": a
# `token=`, `key:` or `password=` value (reauth.sh's masking of a failed login's output, widened), the known key and token
# shapes (sk-ant-…, sk-…, xox?-…, gh?_…, github_pat_…, AKIA…, a JWT, a Slack webhook url) and any long opaque run (32+ hex
# digits, 40+ base64-ish characters with no "/": a path is never one). The stuck-question watch passes a dialog's text
# through it before hashing, logging or posting it: a permission dialog shows the command as typed, secrets included.
SALA_SCRUB_PY='import re
def scrub(t):
    t = re.sub(r"(?i)((?:api[_-]?key|access[_-]?key|secret|token|password|passwd|pwd|credential|authorization|code)s?)(\s*[=:]\s*)(?:bearer\s+)?\S+", r"\1\2…", t)
    t = re.sub(r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{8,}", "bearer …", t)
    t = re.sub(r"https://hooks\.slack\.com/\S+", "https://hooks.slack.com/…", t)
    t = re.sub(r"\b(?:sk-ant-[A-Za-z0-9_-]{8,}|sk-[A-Za-z0-9_-]{16,}|xox[abeoprs]-[A-Za-z0-9-]{8,}|gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,}|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,})", "…", t)
    t = re.sub(r"\b[A-Fa-f0-9]{32,}\b", "…", t)
    t = re.sub(r"(?<![A-Za-z0-9+=_/.-])(?=[A-Za-z0-9+=_-]*\d)(?=[A-Za-z0-9+=_-]*[A-Za-z])[A-Za-z0-9+=_-]{40,}(?![A-Za-z0-9+=_/.-])", "…", t)
    return t'
_has_nonascii() { local LC_ALL=C; [[ $1 == *[!$'\001'-$'\177']* ]]; }   # any byte above 0x7f (python's (?i) folds ſ onto s and ı onto i, which the fast path's ASCII words would miss)
scrub_text() {   # text that holds none of the words or shapes the patterns need goes through as it is, with no python start
    local t; IFS= read -r -d '' t || :
    if [[ ${t,,} =~ api|access|secret|token|passw|pwd|credential|authorization|code|bearer|hooks\.slack|sk-|xox|gh[pousr]_|github_pat_|akia|eyj ]] \
        || [[ $t =~ [A-Za-z0-9+=_-]{32} ]] || [[ $t == *$'\r'* ]] || _has_nonascii "$t"; then
        printf '%s' "$t" | python3 -c "$SALA_SCRUB_PY"$'\nimport sys\nsys.stdout.write(scrub(sys.stdin.read()))'
    else printf '%s' "$t"; fi
}
# send_feedback_drafts <pane> [uuid] — drain queued Claude-drafted feedback through the /feedback panel;
# fails when that conversation still has a queued draft afterwards (its /exit would stop at the drafts gate)
# (transcript = no) BEFORE /exit; see lib/feedback.sh. Drafts are sent, never left as a prompt.
send_feedback_drafts() { "$SALA_BIN" feedback drain "$1" ${2:+"$2"}; }
# prompt_clears <pane> [secs] → 0 once no terminal-only prompt is visible (polls; the /feedback panel
# the drain just closed, or a modal the user is dismissing, needs a moment). Never a single snapshot.
# pane_draft <pane> → prints text the user has TYPED BUT NOT SUBMITTED in the composer, if any.
# Typing /exit into such a pane appends to that line and submits the lot as a message, losing what
# they wrote (a builder once sat with a cue unsent). Never type into a
# pane that has one; report it and move on — clearing it would discard their words.
# The mod is asked too (its prompt.read sees the prompt box itself, no screen involved), and the screen is still
# read: the composer counts as holding a draft when EITHER says so — a draft typed on claude.ai and not sent has not been
# seen in prompt.read yet, and losing the owner's words is the worst outcome. The mod's text is printed when it has one.
# The pane's claude: the caller's pid when it has one, else claude_pid_under the pane. Not found: the screen alone, as before.
# Logged only when a mod that has a stamp gave no answer: drafts are polled (the self-worker asks every second), and the
# mod-or-keys rate shows in the exit and rename lines.
pane_draft() {  # <pane> [claude-pid]
    local mod="" cpid="${2:-}" rc
    [ -n "$cpid" ] || cpid=$(claude_pid_under "$(tmux display -p -t "$1" '#{pane_pid}' 2>/dev/null)" 2>/dev/null)
    if [ -n "$cpid" ]; then
        mod_request "$cpid" draft; rc=$?
        if [ "$rc" = 0 ]; then mod=$(mod_reply_field "$MOD_REPLY" text | tr '\n' ' ' | sed 's/[[:space:]]*$//')
        elif [ "$rc" = 4 ]; then mod_log "draft $(_mod_who "$1") via screen only ($MOD_WHY)"; fi
    fi
    if [ -n "$mod" ]; then printf '%s\n' "$mod"; else pane_draft_screen "$1"; fi
}
pane_draft_screen() { tmux capture-pane -pe -t "$1" 2>/dev/null | draft_from_capture; }   # <pane> → the screen's reading alone
# draft_from_capture (stdin: `capture-pane -e` output) → the user's unsubmitted text, or empty.
# Claude Code shows a SUGGESTED next prompt in the empty composer, rendered dim (SGR 2 … SGR 0/22);
# plain `capture-pane -p` strips the attribute, so a suggestion looked exactly like typed input and
# panes were refused for "drafts" nobody wrote. Dim text is dropped here;
# only non-dim text on the input line counts. Typing over a suggestion replaces it, so it is safe.
_sgr_strip_r() {  # <var> <text> → the text without its SGR sequences (ESC [ digits ; m)
    local _s=$2
    while [[ $_s == *$'\e['* ]]; do
        if [[ $_s =~ $'\e'\[[0-9\;]*m ]]; then _s=${_s/"${BASH_REMATCH[0]}"/}; else break; fi
    done
    printf -v "$1" '%s' "$_s"
}
_lstrip_r() {  # <var> → the variable without its leading white space (a no-break space counts)
    local _v="${!1}"
    while [[ $_v == [[:space:]]* || $_v == $'\xc2\xa0'* ]]; do
        if [[ $_v == $'\xc2\xa0'* ]]; then _v=${_v#$'\xc2\xa0'}; else _v=${_v#?}; fi
    done
    printf -v "$1" '%s' "$_v"
}
# _box_from_capture <capture-pane -e text> → sets _BOX_GLYPH (❯ or !, empty when there is no input line), _BOX_LINE (that screen line,
# raw), _BOX_AT (its index in the capture) and _BOX_N (the capture's line count). The input line is found by the box it sits in (Claude
# Code draws it between two horizontal rules): the line right under one of the LAST TWO rules on the screen (the box's top rule, and
# the bottom rule with the footer under it; older rules are scrollback and never looked at, a stale "───" / "! warning" pair above a
# dialog among them), bottom-up, and the first that forms a box wins: a line starting with the prompt mark ❯, or with the shell-mode
# mark ! (any text may follow, "!ls" too). Under the BOTTOM-MOST rule a ! line counts only when the line after it is a rule or the
# capture ends there, and it is not under the CLOSING rule of the box above: the bottom-most rule is that when the rule before it has a
# ❯ or ! line under it (blank rows between them, a paragraph break in the draft, included). The line under a closing rule on the last
# row is a notice ("! Auto-update failed", "! for shortcuts"), not a box. Under the rule before it (the box's top rule) a ! line is the
# box whatever follows, so a wrapped or multi-row ! draft counts, and no rule above is looked at, so a stale ❯ or ! line under an
# older rule hides nothing. The footer hint "! for shell mode" (or
# "bash mode") is skipped by its words. A capture with no rule at all (the fake claude's bare "❯ ", a test's one-line input), or none
# of the last two with a mark under it, keeps the old reading: the last screen line that starts with ❯ (a ! box is not looked for
# there, and neither is the # memory-mode box, if the CLI has one: that box falls back to the old reading too, and nothing here is
# built for it). Assumption (2.1.312): nothing draws a rule below the footer, so the box is always within the last two rules. A box
# whose bottom rule is off the screen, with an older ❯ or ! line under the rule before it, would read that rule as closing: not
# seen (the footer is always drawn under the bottom rule).
# Fri Oct 30th 2026: a pane in shell mode with nothing typed ("!" and a no-break space) has no ❯ in its box, so the old reading took
# the last ❯ line ABOVE the box, a prompt already submitted, as typed text, and revive skipped the pane for 135 minutes.
_box_from_capture() {
    local line plain i j n first p last="" at=-1 glyph="" lo cnt closing re='^![[:space:]]+for[[:space:]]+(shell|bash)[[:space:]]+mode'
    local -a raw=() pl=() rules=()
    while IFS= read -r line || [ -n "$line" ]; do
        _sgr_strip_r plain "$line"; _lstrip_r plain
        raw+=("$line"); pl+=("$plain")
        [[ $plain == '───'* ]] && rules+=("$(( ${#pl[@]} - 1 ))")
        [[ $plain == '❯'* ]] && { last=$line; glyph="❯"; at=$(( ${#pl[@]} - 1 )); }
    done <<< "$1"
    n=${#pl[@]}; cnt=${#rules[@]}; lo=$(( cnt - 2 )); [ "$lo" -ge 0 ] || lo=0
    for ((i=cnt-1; i>=lo; i--)); do   # the bottom-most box wins; older rules are scrollback
        first=$(( rules[i] + 1 )); [ "$first" -lt "$n" ] || continue
        plain=${pl[first]}
        if [[ $plain == '❯'* ]]; then last=${raw[first]}; glyph="❯"; at=$first; break; fi
        [[ $plain == '!'* ]] || continue
        [[ $plain =~ $re ]] && continue
        # Only the bottom-most rule can have a notice under it (the last row, where the footer sits). The top rule of the pair
        # is a box's own: its ! line is the box whatever follows (a wrapped or multi-row draft), and no rule above it is looked at.
        closing=0
        if [ "$i" -eq "$((cnt-1))" ]; then
            if [ "$((first + 1))" -lt "$n" ] && [[ ${pl[first+1]} != '───'* ]]; then continue; fi   # something else follows: a notice, not a box
            if [ "$i" -gt 0 ]; then   # does this rule close the box under the previous rule? Then the line under it is a notice
                p=$(( rules[i-1] + 1 ))
                if [[ ${pl[p]} == '❯'* ]]; then closing=1   # a ❯ box under the previous rule: this is its bottom rule, however many blank rows (a paragraph break in the draft) lie between
                elif [[ ${pl[p]} == '!'* ]] && ! [[ ${pl[p]} =~ $re ]]; then closing=1   # a ! box likewise (a multi-paragraph shell draft)
                fi
            fi
        fi
        [ "$closing" = 0 ] || continue
        last=${raw[first]}; glyph="!"; at=$first; break
    done
    _BOX_GLYPH=$glyph; _BOX_LINE=$last; _BOX_AT=$at; _BOX_N=$n
}
draft_from_capture() {
    # the python it was (a start per call, 500 in a test run), in the shell. The input line is _box_from_capture's; its dim
    # spans (the suggestion) and its attributes are removed, its mark dropped.
    local l out rem post t rest best bt p last glyph cap
    cap=$(cat); _box_from_capture "$cap"
    [ -n "$_BOX_LINE" ] || return 0
    last=$_BOX_LINE; glyph=$_BOX_GLYPH
    l=$last; out=""; rem=$l
    while [[ $rem == *$'\e[2m'* ]]; do   # dim span = suggestion, up to the next reset or the end of the line
        out+=${rem%%$'\e[2m'*}; post=${rem#*$'\e[2m'}; best=-1; bt=""
        for t in $'\e[0m' $'\e[22m' $'\e[m'; do
            if [[ $post == *"$t"* ]]; then rest=${post%%"$t"*}; p=${#rest}; if [ "$best" -lt 0 ] || [ "$p" -lt "$best" ]; then best=$p; bt=$t; fi; fi
        done
        if [ "$best" -ge 0 ]; then rem=${post:best+${#bt}}; else rem=""; fi
    done
    l=$out$rem
    _sgr_strip_r l "$l"                                             # remaining attributes
    l=${l//$'\xc2\xa0'/ }; _lstrip_r l
    [[ $l == "$glyph"* ]] && l=${l#"$glyph"}
    _lstrip_r l
    while [[ $l == *[[:space:]] ]]; do l=${l%?}; done
    printf '%s\n' "$l"
}
prompt_clears() { local i; for ((i=0; i<${2:-10}; i++)); do pane_prompt "$1" || return 0; sleep 1; done; return 1; }
# resume_wait <pane> <uuid> <secs> → the resumed claude is LIVE in its pane, not merely started (revive, unpark and spawn;
# here, out of revive.sh). Until a later release the check
# was `wait_for … claude` alone, which returns the moment the pane's foreground command reads `claude`: a resume that comes
# up and dies (a refused --resume, a CLI broken by its update) reads so until it exits, and the self-worker posted
# "✅ Recycle done" over a pane sitting at its shell (tests/sets-master.sh, twice: the fake's FAKE_RESUME_FAIL
# dies within milliseconds, and a 1 s poll landed inside them). Polled every second, as wait_for. 0 once a claude under
# the pane carries <uuid> in its registry row (the CLI writes it 1–14 s into its start on a loaded machine) and is still
# there a poll later, RESUMED_PID naming it; also 0 when <secs> run out with a claude alive under the pane, row or no row
# (slow to register is not dead, and inbox_release waits for the row as before: a slow start is never called a failure).
# <uuid> may be empty (spawn: a fresh session or a fork gets a new id): then any registry row of that process counts.
# 1 when none came up within <secs>. 2 when one came up and was gone again, the pane back at its shell, before it had
# registered and stayed: the resume died, its error above the pane's prompt.
resume_wait() {
    local pane="$1" uuid="$2" secs="$3" i npid="" seen=0 reg=0 cmd
    RESUMED_PID=""
    for ((i=0; ; i++)); do
        npid=$(claude_pid_under "$(tmux display -p -t "$pane" '#{pane_pid}' 2>/dev/null)" 2>/dev/null)
        if [ -n "$npid" ]; then
            seen=1
            [ "$reg" = 1 ] && { RESUMED_PID=$npid; return 0; }   # registered a poll ago and still here
            if [ -n "$uuid" ]; then grep -qsE "\"sessionId\" *: *\"$uuid\"" "$SALA_REG_DIR/$npid.json" && reg=1
            else [ -s "$SALA_REG_DIR/$npid.json" ] && reg=1; fi
        else
            reg=0; cmd=$(tmux display -p -t "$pane" '#{pane_current_command}' 2>/dev/null)
            case "$cmd" in bash|sh|zsh|fish) [ "$seen" = 1 ] && return 2 ;; esac
        fi
        [ "$i" -lt "$secs" ] || break
        sleep 1
    done
    [ -n "$npid" ] && { RESUMED_PID=$npid; return 0; }   # the window out with a claude alive: started, slow to register
    return 1
}
wait_for() {  # $1=pane $2=want ("claude"|"shell"|<cmd>) $3=timeout-secs
    local i cmd
    for ((i=0; i<$3; i++)); do
        cmd=$(tmux display -p -t "$1" '#{pane_current_command}' 2>/dev/null)
        case "$2" in
            shell) case "$cmd" in bash|sh|zsh|fish) return 0;; esac ;;
            *)     [ "$cmd" = "$2" ] && return 0 ;;
        esac
        sleep 1
    done
    return 1
}

# resume_send <pane> <uuid> <command> → 0 the resume line typed into the pane's shell; 1 not typed, the reason on stdout.
# Checked at the last moment, under one lock for every sala run: the conversation is not live anywhere and the pane's
# foreground program is a shell. Two retry workers that woke together both closed and resumed
# one session; the second line landed in the first one's claude as a draft and blocked every later relaunch.
# The lock is held until the typed line has started a program (up to 5 s), so the next run sees it.
resume_send() {
    local d="$SALA_STATE_DIR" i
    mkdir -p "$d" 2>/dev/null
    (
        flock -w 30 7 || { echo "another sala run held the resume lock for 30 s — resume not typed"; exit 1; }
        if live=$(live_pane_for_uuid "$2"); then echo "conversation $2 is already live (pid ${live%% *}), another sala run resumed it — resume not typed"; exit 1; fi
        cmd=$(tmux display -p -t "$1" '#{pane_current_command}' 2>/dev/null)
        case "$cmd" in bash|sh|zsh|fish) ;; *) echo "the pane is running '${cmd:-nothing}', not a shell — resume not typed (it would land in that program's input)"; exit 1;; esac
        tmux send-keys -t "$1" "$3" Enter
        for ((i=0; i<25; i++)); do
            case "$(tmux display -p -t "$1" '#{pane_current_command}' 2>/dev/null)" in bash|sh|zsh|fish) _nap 0.2;; *) break;; esac
        done
        exit 0
    ) 7>"$d/resume.lock"
}

# the one-time move of the map to the state dir and the cwd fill of a 3-column map (see ledger_migrate): last, once every
# helper above is defined, in whatever sources this file first after the change
ledger_migrate
