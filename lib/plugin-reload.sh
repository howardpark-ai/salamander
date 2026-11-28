# NEW HOOKS AND SKILL TEXT REACH A RUNNING BACKGROUND AGENT (sourced by lib/watch.sh; `sala watch --plugins`).
# A marketplace plugin's deploy changes files; a running Claude Code keeps the version it started with until /reload-plugins runs
# in it. sala reads the plugin install record and asks the pane's sala mod to run that command (mod verb `reload`,
# mod/hooks/register.ts). No key is typed into a pane, --force is never added, and a pane whose mod cannot be asked is left alone:
# it loads the new version at its next start.
# WHO IS ASKED: only a pane of a BACKGROUND AGENT, a session nobody reads (the session registry's role back: back_lane_names back,
# the test the back agents' lane rule uses). Every other pane (a front agent, a side session, a throwaway, a pane with no role,
# the Remote Control session) is left alone and loads the new version at its next start. A background agent is skipped while it
# is asleep, in SALA_NO_RELAUNCH, on the sdk lane, or exiting or being relaunched (paused for it, a waiting flag, the deferred
# list, an open recycle set, a queued, running or waiting operation that names it). The whole pass stands aside while bare_busy does.
# STALE: the newest `lastUpdated` of a plugin named in SALA_PLUGIN_RELOAD_IDS, in <the pane's config directory>/plugins/
# installed_plugins.json, is later than both the start of the pane's claude and its last confirmed reload, and the installed
# versions (each named entry's version and commit) are not the ones that reload was asked for: one confirmed reload per
# plugin version, and a record that is only rewritten asks nobody again.
# THE ASK: no idle gate (the command waits behind a running turn or an open dialog and leaves a typed draft alone). The mod answers
# "accepted" at once and writes <sessionId>.reload.json {begun, ok, text} once the command has run; ok only for an answer that
# starts "Reloaded:" (a reload that replaced the mod itself is answered ok by the mod's new copy). Not confirmed after SALA_PLUGIN_RELOAD_RETRY s (1800): asked again. Another answer: logged, asked again
# after that long, at most SALA_PLUGIN_RELOAD_TRIES (3) such answers per plugin version. At most SALA_PLUGIN_RELOAD_MAX (10) panes are
# asked per pass.
# KNOBS: SALA_PLUGIN_RELOAD is OFF by default; SALA_PLUGIN_RELOAD_IDS ("<plugin>@<marketplace> …", spaces or commas) is empty by
# default, so no pane is stale until the config names a plugin. `--only <session>` asks that one background agent now, on or off
# and stale or not (a trial), under the same exclusions, and waits up to SALA_PLUGIN_RELOAD_WAIT s (20) for the answer.
# State: $SALA_STATE_DIR/plugin-reload.tsv, one row per claude process. Log: the "plugins: …" lines of salamander-watch.log.

: "${SALA_PLUGIN_RELOAD:=off}" "${SALA_PLUGIN_RELOAD_IDS:=}" "${SALA_PLUGIN_RELOAD_MAX:=10}" "${SALA_PLUGIN_RELOAD_RETRY:=1800}" "${SALA_PLUGIN_RELOAD_TRIES:=3}" "${SALA_PLUGIN_RELOAD_WAIT:=20}"
SALA_PLUGIN_STATE="$SALA_STATE_DIR/plugin-reload.tsv"
RELOAD_DRY=0; RELOAD_ONLY=""; RELOAD_GOT=""

reload_on() { case "${SALA_PLUGIN_RELOAD:-off}" in on|1|yes|true) return 0;; esac; return 1; }   # off by default; only an explicit on turns it on
_reload_shown() { [ "$RELOAD_DRY" = 1 ] || [ -n "$RELOAD_ONLY" ]; }   # a dry run and --only print their lines

# THE FUNCTIONS BELOW read and write the caller's row (r_ask r_stamp r_sid r_done r_tries r_try r_why r_ver r_donev): the last
# request's epoch second, the install stamp (ms) and session id it was for, the begun (ms) of the last confirmed reload, the
# refusals counted and the versions they count for, the skip reason last logged, the versions last asked for and the versions
# of the last confirmed reload ("versions": the hash _reload_stamp_r gives; "-" for none).

# _reload_say <session> <reason key> <words> — why a pane is not asked: printed by a dry run and --only, logged when the reason changes
_reload_say() {
    if _reload_shown; then echo "$1: $3"; fi
    [ "$RELOAD_DRY" = 1 ] && return 0
    [ "$r_why" = "$2" ] && return 0
    r_why=$2; wlog "plugins: $1: $3"
}
# _reload_event <session> <words> — a request or an answer: always logged (a dry run only prints it)
_reload_event() {
    if _reload_shown; then echo "$1: $2"; fi
    [ "$RELOAD_DRY" = 1 ] || wlog "plugins: $1: $2"
}

_reload_alive() {  # <pid>:<start ticks> → 0 while that very process lives
    local p=${1%%:*} t
    kill -0 "$p" 2>/dev/null || return 1
    t=$(proc_start_ticks "$p" 2>/dev/null) || t=0
    [ "$t" = "${1#*:}" ]
}
# the state file, through the caller's RL[<pid>:<ticks>]; a save drops the rows of processes that are gone, and a dry run writes nothing
_reload_load() {
    local k rest
    [ -r "$SALA_PLUGIN_STATE" ] || return 0
    while IFS=$'\t' read -r k rest; do [ -n "$k" ] && RL[$k]=$rest; done < "$SALA_PLUGIN_STATE"
}
_reload_save() {
    [ "$RELOAD_DRY" = 1 ] && return 0
    local k t="$SALA_PLUGIN_STATE.tmp.$$"
    mkdir -p "$SALA_STATE_DIR" 2>/dev/null
    { if [ "${#RL[@]}" -gt 0 ]; then for k in "${!RL[@]}"; do if _reload_alive "$k"; then printf '%s\t%s\n' "$k" "${RL[$k]}"; fi; done; fi; } > "$t" && mv -f "$t" "$SALA_PLUGIN_STATE"
}
_reload_row_get() {  # <key>
    local row=${RL[$1]:-}
    [ -n "$row" ] || row=$'0\t0\t-\t0\t0\t-\t-\t-\t-'
    IFS=$'\t' read -r r_ask r_stamp r_sid r_done r_tries r_try r_why r_ver r_donev <<< "$row"
}
_reload_row_put() {  # <key> — saved at once, only when the row changed
    local row="$r_ask"$'\t'"$r_stamp"$'\t'"$r_sid"$'\t'"$r_done"$'\t'"$r_tries"$'\t'"$r_try"$'\t'"$r_why"$'\t'"$r_ver"$'\t'"$r_donev"
    [ "${RL[$1]:-}" = "$row" ] && return 0
    RL[$1]=$row; _reload_save
}

# _reload_stamp_r <var> <config dir> → "<epoch ms> <versions> <plugin id> <version>": the newest install or update of a watched plugin
# there, and one hash over every watched entry's name, version and commit (the update time stands in for an entry that records
# neither). Every scope's entry counts. Empty when the record is not there, cannot be read or names none of them
_reload_stamp_r() {
    local _f="$2/plugins/installed_plugins.json" _o=""
    if [ -r "$_f" ]; then
        _o=$(python3 -I -S -c 'import datetime, hashlib, json, sys
try: plugins = json.load(open(sys.argv[1], encoding="utf-8"))["plugins"]
except Exception: sys.exit(0)
best, have = None, set()
for name in sys.argv[2:]:
    entries = plugins.get(name) if isinstance(plugins, dict) else None
    for e in entries if isinstance(entries, list) else []:
        try: t = datetime.datetime.fromisoformat(e["lastUpdated"].replace("Z", "+00:00"))
        except Exception: continue
        if t.tzinfo is None: t = t.replace(tzinfo=datetime.timezone.utc)
        ms = int(t.timestamp() * 1000)
        v = "".join(c for c in str(e.get("version") or "") if c.isprintable() and not c.isspace())[:40]
        c = str(e.get("gitCommitSha") or "")
        have.add(json.dumps([name, v, c] if c or v not in ("", "unknown") else [name, ms]))
        if best is None or ms > best[0]: best = (ms, name, v or "?")
if best: print(best[0], hashlib.sha256("\n".join(sorted(have)).encode()).hexdigest()[:16], *best[1:])' "$_f" ${idv[@]+"${idv[@]}"} 2>/dev/null)
    fi
    printf -v "$1" %s "$_o"
}

# _reload_collect <session> <current session id> <process start, ms> — reads the answer the mod left (<sid>.reload.json, under the id
# the request went to, or the current one) into the row, and removes it (a dry run leaves it). An answer begun before this process
# started is an earlier one's. RELOAD_GOT: ok | refused for an answer to the last request, empty otherwise
_reload_collect() {
    local sess=$1 cur=$2 startms=$3 sid d f c ok begun text seen=" "
    RELOAD_GOT=""
    for sid in "$r_sid" "$cur"; do
        case "$sid" in -|""|null|*/*) continue;; esac
        case "$seen" in *" $sid "*) continue;; esac; seen="$seen$sid "
        while IFS= read -r d; do
            f="$d/$sid.reload.json"; [ -n "$d" ] && [ -s "$f" ] || continue
            c=""; { IFS= read -r -d '' c < "$f"; } 2>/dev/null || :
            [ "$RELOAD_DRY" = 1 ] || rm -f "$f"
            ok=$(mod_reply_field "$c" ok); begun=$(mod_reply_field "$c" begun)
            [[ $begun =~ ^[0-9]+$ ]] && [ "$begun" -ge "$startms" ] || continue
            text=$(mod_reply_field "$c" text); text=${text//[$'\t\r\n']/ }; text=${text:0:200}
            if [ "$ok" = true ]; then
                [ "$begun" -le "$r_done" ] || r_done=$begun
                [ "$begun" -lt "$r_stamp" ] || r_donev=$r_ver
                r_tries=0; r_why=-
                _reload_event "$sess" "the reload ran: $text"
            else
                # counted against the install it was asked for; an answer from before that install says nothing about it
                if [ "$begun" -ge "$r_stamp" ]; then
                    [ "$r_try" = "$r_ver" ] || { r_try=$r_ver; r_tries=0; }
                    r_tries=$((r_tries + 1))
                    _reload_event "$sess" "the reload did not run (answer $r_tries of $SALA_PLUGIN_RELOAD_TRIES for this version): ${text:-no words}"
                    [ "$r_tries" -lt "$SALA_PLUGIN_RELOAD_TRIES" ] || _reload_event "$sess" "not asked again for this version; it loads it at its next start, or is asked after the next one"
                else
                    _reload_event "$sess" "an earlier reload did not run: ${text:-no words}"
                fi
            fi
            if [ "$begun" -ge $(( r_ask * 1000 )) ]; then if [ "$ok" = true ]; then RELOAD_GOT=ok; else RELOAD_GOT=refused; fi; fi
        done <<< "$(mod_run_dirs)"
    done
}

# _reload_skip_r <var> <session> <claude-pid> → in <var> why this background agent's pane is not to be asked now; empty when it may be
_reload_skip_r() {
    local _v=$1 s=$2 p=$3 lane="" conv="" uuid="" f st id
    printf -v "$_v" %s ""
    [ "$s" != "${SALA_RC_SESSION:-}" ] || { printf -v "$_v" %s "the Remote Control session"; return 0; }
    is_sleeping "$s" && { printf -v "$_v" %s "asleep"; return 0; }
    no_relaunch "$s" && { printf -v "$_v" %s "managed outside sala (SALA_NO_RELAUNCH or the web UI's shell)"; return 0; }
    is_rc_child "$p" && { printf -v "$_v" %s "a Remote Control served session"; return 0; }
    _lane_running_r lane "$p" "$s"
    [ "$lane" != sdk ] || { printf -v "$_v" %s "on the sdk lane"; return 0; }
    # exiting, or being relaunched
    pause_active "$p" && { printf -v "$_v" %s "paused for a relaunch"; return 0; }
    registry_conv_r conv "$p"; sleeping_uuid_r uuid "$s" || uuid=""
    { waiting_for "$conv" || waiting_for "$uuid"; } && { printf -v "$_v" %s "a relaunch waits for it (waiting flag)"; return 0; }
    if [ -s "$SALA_DEFERRED" ] && awk -F'\t' -v s="$s" '$1 == s {f = 1} END {exit !f}' "$SALA_DEFERRED" 2>/dev/null; then printf -v "$_v" %s "a relaunch waits for it (deferred list)"; return 0; fi
    for f in "$SALA_SET_DIR"/*; do
        id=${f##*/}; [[ $id =~ ^[0-9]+-[0-9]+$ ]] || continue
        [ "$(set_val "$id" closed)" != 1 ] || continue
        if _set_out "$id" "$s"; then printf -v "$_v" %s "an open relaunch set ($id) waits for it"; return 0; fi
    done
    for f in "${SALA_OP_DIR:-$SALA_STATE_DIR/ops}"/*.op; do
        [ -f "$f" ] || continue
        _kv_first_r st "$f" state
        case "$st" in queued|running|waiting) ;; *) continue;; esac
        if grep -qxF -- "arg=$s" "$f" 2>/dev/null; then id=${f##*/}; printf -v "$_v" %s "operation ${id%.op} ($st) names it"; return 0; fi
    done
    return 0
}

# _reload_ask <session> <claude-pid> <session id> <install stamp ms> <versions> <words> → 0 a request went out and was accepted (or, in a dry run,
# would be sent), 4 sent with no reply yet, 1 sent and refused, 3 no mod to ask (nothing sent)
_reload_ask() {
    local sess=$1 pid=$2 sid=$3 ms=$4 vers=$5 words=$6 now start target rc reason
    _now_r now
    if [ "$RELOAD_DRY" = 1 ]; then
        start=$(( now - $(proc_etime "$pid" 2>/dev/null || echo 0) ))
        _mod_target_r target "$pid" "$start"
        case "$target" in "-"$'\t'*|"") _reload_say "$sess" nomod "no sala mod to ask (${target#*$'\t'}): it loads the new version at its next start"; return 3;; esac
        echo "$sess: would be asked to reload ($words)"; return 0
    fi
    mod_request "$pid" reload; rc=$?
    [ "$rc" = 3 ] && { _reload_say "$sess" nomod "no sala mod to ask ($MOD_WHY): it loads the new version at its next start"; return 3; }
    mod_log "reload $sess via mod ($MOD_WHY)"
    r_ask=$now; r_stamp=$ms; r_sid=${sid:--}; r_ver=$vers
    case "$rc" in
        0) r_why=-; _reload_event "$sess" "asked to reload ($words)";;
        4) r_why=-; _reload_event "$sess" "asked to reload ($words), $MOD_WHY: its answer is read at a later pass";;
        *) reason=$(mod_reply_field "$MOD_REPLY" reason)
           if [ "$reason" = unknown ]; then _reload_say "$sess" oldmod "its sala mod does not know reload (older than this sala): it loads the new version at its next start"
           else _reload_say "$sess" "mod:$reason" "its sala mod refused the request (${reason:-no reason})"; fi;;
    esac
    return "$rc"
}

# one background agent's pane in a pass: <session> <claude-pid>. Uses the caller's RL, stampc, idv and acts
_reload_pane() {
    local sess=$1 pid=$2 ticks key sid="" cfg stamp="" ms=0 vers=- plug="" ver="" now start why rc words i dirs
    local r_ask r_stamp r_sid r_done r_tries r_try r_why r_ver r_donev
    ticks=$(proc_start_ticks "$pid" 2>/dev/null) || ticks=0
    key="$pid:$ticks"; _reload_row_get "$key"
    registry_field_r sid "$pid" sessionId; [ "$sid" != null ] || sid=""
    _now_r now; start=$(( now - $(proc_etime "$pid" 2>/dev/null || echo 0) ))
    cfg=$(model_config_dir "$pid" "$sess")
    if [ "${#idv[@]}" -gt 0 ]; then
        if [ -z "${stampc[$cfg]+x}" ]; then _reload_stamp_r stamp "$cfg"; stampc[$cfg]=$stamp; fi
        stamp=${stampc[$cfg]}
        [ -z "$stamp" ] || read -r ms vers plug ver <<< "$stamp"
    fi
    _reload_collect "$sess" "$sid" $(( (start - 2) * 1000 ))
    _reload_skip_r why "$sess" "$pid"
    if [ -n "$why" ]; then
        _reload_say "$sess" "skip:${why// /_}" "skipped: $why"
        _reload_row_put "$key"; [ -z "$RELOAD_ONLY" ]; return
    fi
    if [ -n "$RELOAD_ONLY" ]; then
        words="asked for by --only"; [ "$ms" = 0 ] || words="$words; $plug $ver, updated $(local_human $(( ms / 1000 )))"
        _reload_ask "$sess" "$pid" "$sid" "$ms" "$vers" "$words"; rc=$?
        _reload_row_put "$key"
        [ "$RELOAD_DRY" = 1 ] && { [ "$rc" = 0 ]; return; }
        case "$rc" in 0|4) ;; *) return 1;; esac
        RELOAD_GOT=""
        for ((i = 0; i <= SALA_PLUGIN_RELOAD_WAIT * 5; i++)); do
            _reload_collect "$sess" "$sid" $(( (start - 2) * 1000 ))
            [ -n "$RELOAD_GOT" ] && break
            [ "$i" -lt $(( SALA_PLUGIN_RELOAD_WAIT * 5 )) ] && _nap 0.2
        done
        _reload_row_put "$key"
        case "$RELOAD_GOT" in ok) return 0;; refused) return 1;; esac
        dirs=$(mod_run_dirs | head -1)
        echo "$sess: no answer after ${SALA_PLUGIN_RELOAD_WAIT}s (it waits behind a running turn or an open dialog); it will be $dirs/$sid.reload.json, and \`salamander watch --plugins --only $sess --dry-run\` reads it"
        return 4
    fi
    if [ -z "$stamp" ]; then
        _reload_say "$sess" nostamp "no watched plugin in $cfg/plugins/installed_plugins.json"
    elif [ "$ms" -le $(( start * 1000 )) ] || [ "$ms" -le "$r_done" ] || [ "$vers" = "$r_donev" ]; then
        if [ "$RELOAD_DRY" = 1 ]; then echo "$sess: current ($plug $ver was there at its start or at its last reload)"; else r_why=-; fi
    elif [ "$r_try" = "$vers" ] && [ "$r_tries" -ge "$SALA_PLUGIN_RELOAD_TRIES" ]; then
        _reload_say "$sess" "gaveup:$vers" "$plug $ver: not asked again after $r_tries answers that were no reload; it loads at its next start or after the next update"
    elif [ "$r_ask" -gt 0 ] && [ "$r_ver" = "$vers" ] && [ $(( now - r_ask )) -lt "$SALA_PLUGIN_RELOAD_RETRY" ]; then
        [ "$RELOAD_DRY" = 1 ] && echo "$sess: asked $(( (now - r_ask) / 60 )) min ago, no reload confirmed: asked again after $(( SALA_PLUGIN_RELOAD_RETRY / 60 )) min"
    elif [ "$acts" -ge "$SALA_PLUGIN_RELOAD_MAX" ]; then
        _reload_say "$sess" cap "waits for a later pass: $SALA_PLUGIN_RELOAD_MAX panes are asked per pass"
    else
        words="$plug $ver, updated $(local_human $(( ms / 1000 )))"
        [ "$r_ask" -gt 0 ] && [ "$r_ver" = "$vers" ] && words="$words; again, $(( (now - r_ask) / 60 )) min after the last request"
        _reload_ask "$sess" "$pid" "$sid" "$ms" "$vers" "$words"; rc=$?
        [ "$rc" = 3 ] || acts=$((acts + 1))
    fi
    _reload_row_put "$key"
    return 0
}

_reload_locked() {
    local tbl sess pid ppid line seen=" " acts=0 rc=0
    local -A RL=() isback=() stampc=()
    local -a idv=() targets=()
    read -r -d '' -a idv <<< "${SALA_PLUGIN_RELOAD_IDS//,/ }" || :
    if [ "$RELOAD_DRY" = 1 ]; then
        echo "only panes of background agents are asked to reload; every other pane is left alone and loads the new version at its next start"
        reload_on || echo "SALA_PLUGIN_RELOAD is ${SALA_PLUGIN_RELOAD:-off}: a pass of the watch asks nothing"
    fi
    if [ "${#idv[@]}" = 0 ]; then
        _reload_shown && echo "SALA_PLUGIN_RELOAD_IDS names no plugin: no pane can be found stale"
        if ! _reload_shown; then
            [ "$(st_get pluginwhy)" = noids ] || { st_set pluginwhy noids; wlog "plugins: SALA_PLUGIN_RELOAD is on and SALA_PLUGIN_RELOAD_IDS names no plugin: nothing to do"; }
            return 0
        fi
    else
        _reload_shown || [ -z "$(st_get pluginwhy)" ] || st_del pluginwhy
    fi
    _reload_load
    sessions_on || { _reload_shown && echo "the session registry is off (SALA_SESSIONS=off): no pane is known as a background agent"; }
    while IFS= read -r line; do [ -n "$line" ] && isback[$line]=1; done < <(back_lane_names back)
    if [ -n "$RELOAD_ONLY" ]; then
        tmux has-session -t "=$RELOAD_ONLY" 2>/dev/null || { echo "$RELOAD_ONLY: no tmux session of that name"; return 1; }
        targets=("$RELOAD_ONLY")
    else
        _claude_panes_r tbl
        while IFS='|' read -r sess _ _; do
            [ -n "$sess" ] || continue
            case "$seen" in *" $sess "*) continue;; esac; seen="$seen$sess "
            targets+=("$sess")
        done <<< "$tbl"
    fi
    for sess in ${targets[@]+"${targets[@]}"}; do
        if [ -z "${isback[$sess]+x}" ]; then
            _reload_shown && echo "$sess: left alone, not a background agent: it loads the new version at its next start"
            [ -z "$RELOAD_ONLY" ] || rc=1
            continue
        fi
        ppid=$(tmux list-panes -t "$(tmux_win_t "$sess")" -F '#{pane_pid}' 2>/dev/null | head -1)
        pid=""; [ -z "$ppid" ] || pid=$(claude_pid_under "$ppid" 2>/dev/null)
        if [ -z "$pid" ]; then
            if _reload_shown; then if is_sleeping "$sess"; then echo "$sess: skipped: asleep"; else echo "$sess: skipped: no claude in its pane"; fi; fi
            [ -z "$RELOAD_ONLY" ] || rc=1
            continue
        fi
        _reload_pane "$sess" "$pid" || rc=$?
    done
    [ "$RELOAD_DRY" = 1 ] || while IFS= read -r line; do [ -d "$line" ] && find "$line" -maxdepth 1 -name '*.reload.json*' -mtime +0 -delete 2>/dev/null; done <<< "$(mod_run_dirs)"   # answers nobody read in a day
    [ -n "$RELOAD_ONLY" ] || rc=0
    return "$rc"
}

# reload_tick [--dry-run] [--only <session>] → 0; with --only: 0 the reload ran (dry run: it would be asked), 1 not asked or the
# command did not run, 4 asked with no answer yet; 2 a wrong argument. Without --only and without --dry-run it does nothing unless SALA_PLUGIN_RELOAD=on.
reload_tick() {
    local usage="usage: salamander watch --plugins [--dry-run] [--only <session>]"
    RELOAD_DRY=0; RELOAD_ONLY=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) RELOAD_DRY=1;;
            --only) [ -n "${2:-}" ] && [ "${2#-}" = "$2" ] || { echo "✗ --only needs a session name; $usage" >&2; return 2; }; RELOAD_ONLY=$2; shift;;
            *) echo "✗ unknown argument '$1'; $usage" >&2; return 2;;
        esac
        shift
    done
    if ! _reload_shown && ! reload_on; then return 0; fi
    on_fleet_server || { _reload_shown && echo "not the fleet's tmux server: nothing is asked"; [ -z "$RELOAD_ONLY" ]; return; }
    tmux_server_up || { _reload_shown && echo "no tmux server is running: nothing is asked"; [ -z "$RELOAD_ONLY" ]; return; }
    if bare_busy; then _reload_shown && echo "standing aside: $BARE_BUSY_WHY"; [ -z "$RELOAD_ONLY" ]; return; fi
    [ -d "$SALA_LOG_DIR" ] || mkdir -p "$SALA_LOG_DIR"
    (
        flock -n 8 || { _reload_shown && echo "another plugin pass is running: nothing is asked"; [ -z "$RELOAD_ONLY" ]; exit; }
        _reload_locked
    ) 8>>"$SALA_LOG_DIR/salamander-plugin-reload.lock"
}
