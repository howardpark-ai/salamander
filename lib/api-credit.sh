# lib/api-credit.sh — the shell side of the shared API-credit record (the rule and the file's format are in
# lib/api_credit.py's docstring). Sourced by lib/common.sh (the sdk lane's start-up check) and by contrib/briefing/lib.sh (the
# briefings' backend choice); defines functions only, never exits.
#
#   api_credit_ok [<epoch>]        0 = use the key (no record, or the refusal is older than API_CREDIT_RETRY_S, default 21600 s);
#                                  1 = a refusal is fresh: go straight to the subscription lane. Pure bash, no fork: the sdk
#                                  lane asks it for every session of a listing. <epoch> is the tests' clock.
#   api_credit_refuse <by> [<detail>]   record a refusal now (a job that saw "credit balance" in the key's answer)
#   api_credit_clear               remove the record (a key call worked)
#   api_credit_state_file          the record's path: ${XDG_STATE_HOME:-~/.local/state}/api-credit/state.json
#   api_credit_when_local            the refusal's time and its retry time the way the owner reads them, for a message
# The writes go through lib/api_credit.py (the one writer: atomic rename, mode 700 directory), run with the system python3.
_API_CREDIT_PY=${BASH_SOURCE[0]%/*}/api_credit.py
api_credit_state_file() { printf '%s\n' "${XDG_STATE_HOME:-${HOME:-~}/.local/state}/api-credit/state.json"; }
_api_credit_at_r() {  # <var> → the record's refused_at in <var>; status 1 and <var> empty when there is none (absent, unreadable, no number)
    local _f _s; _f=${XDG_STATE_HOME:-${HOME:-~}/.local/state}/api-credit/state.json
    printf -v "$1" %s ""
    [ -r "$_f" ] || return 1
    { _s=$(<"$_f"); } 2>/dev/null || return 1
    [[ $_s =~ \"refused_at\"[[:space:]]*:[[:space:]]*(-?[0-9]+) ]] || return 1
    printf -v "$1" %s "${BASH_REMATCH[1]}"
}
api_credit_ok() {
    local now=${1:-} at retry=${API_CREDIT_RETRY_S:-21600} d
    [[ $retry =~ ^[0-9]+$ ]] && [ "$retry" -gt 0 ] || retry=21600
    _api_credit_at_r at || return 0
    [ -n "$now" ] || printf -v now '%(%s)T' -1
    d=$(( now - at )); [ "$d" -lt 0 ] && d=$(( -d ))
    [ "$d" -ge "$retry" ]
}
api_credit_refuse() { python3 -I "$_API_CREDIT_PY" refuse "${1:-?}" "${2:-}" 2>/dev/null; }
api_credit_clear() { python3 -I "$_API_CREDIT_PY" clear 2>/dev/null; }
api_credit_when_local() {  # → "refused at <local time> by <job>; the key is tried again after <local time>"; nothing when there is no record
    local at by="" retry=${API_CREDIT_RETRY_S:-21600} f
    _api_credit_at_r at || return 0
    [[ $retry =~ ^[0-9]+$ ]] && [ "$retry" -gt 0 ] || retry=21600
    f=$(api_credit_state_file)
    [[ $(<"$f") =~ \"by\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]] && by=${BASH_REMATCH[1]}
    printf 'refused at %s%s; the key is tried again after %s' "$(_api_credit_local "$at")" "${by:+ by $by}" "$(_api_credit_local "$(( at + retry ))")"
}
_api_credit_local() {  # <epoch> → the owner's date form where sala's local_human is loaded (common.sh), else a plain stamp
    if declare -F local_human >/dev/null 2>&1; then local_human "$1"
    else date -d "@$1" '+%a %b %-d %H:%M %Z' 2>/dev/null || date -r "$1" '+%a %b %-d %H:%M %Z'; fi
}
