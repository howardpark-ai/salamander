# lib/rc.sh — keep a Claude Code Remote Control SERVER alive in its own tmux session, so new
# sessions can be minted on this box from claude.ai / the mobile app without an SSH hop.
#
# Every pane already registers its own Remote Control session, but a pane can only be created
# FROM the box. `claude remote-control` lists the box on claude.ai under Remote Control ("alpha / box-a, N of 32
# sessions"; the API calls it an environment) so the app can mint
# sessions into. Those are headless children of the server (`claude --print --sdk-url …`), not
# panes, and differ in three ways this file absorbs:
#   - not covered by tmux-resurrect / `revive`;
#   - no reconnection record in their transcript, so a plain `claude --resume` of one forks a
#     TWIN on the same transcript (two writers, one file) — elevate with `spawn --fork` instead;
#   - the server exits after ~10 min without network; its sessions come back only within ~4 h
#     of a stop — hence the restart loop (--run).
#
#   rc [--ensure]      start the loop if not running (idempotent; honours the --stop marker)
#   rc --start         clear the marker, then --ensure
#   rc --status        server state + served sessions
#   rc --restart       SIGINT the server; the loop relaunches on the CURRENT binary (what
#                      `revive` does after a CLI update)
#   rc --stop          stop loop + tmux session, leave a marker so revive sweeps skip it
#   rc --archive ID…   archive claude.ai sessions by web id (session_… / cse_…) via the endpoint
#                      (refused for a session a live pane is bridged to); --unarchive ID… undoes it
#                      the CLI itself uses (POST /v1/code/sessions/<id>/archive, OAuth bearer from
#                      ~/.claude/.credentials.json — never printed). UNOFFICIAL: non-200 → do it on claude.ai.
#   rc --run           (internal) the loop, inside the pane
#
# Env pins (emergency only; leave unset so served sessions follow settings.json like every pane):
#   RC_MODEL → ANTHROPIC_MODEL   RC_EFFORT → CLAUDE_CODE_EFFORT_LEVEL (hard override, also blocks
#   the effort control on claude.ai for that session)   RC_CAPACITY / RC_NAME / RC_RESTART_DELAY

set -o pipefail
SESSION="$SALA_RC_SESSION"; PANE=$(tmux_win_t "$SESSION" 0)
CAP="${RC_CAPACITY:-$SALA_RC_CAPACITY}"; NAME="${RC_NAME:-$SALA_RC_NAME}"; DELAY="${RC_RESTART_DELAY:-$SALA_RC_RESTART_DELAY}"
LOG="$SALA_LOG_DIR/salamander-rc.log"; STOP_MARKER="$SALA_LOG_DIR/salamander-rc.stopped"
mkdir -p "$SALA_LOG_DIR"

log() { printf '[%s] %s\n' "$(cs_date '+%F %T %Z')" "$*" >> "$LOG"; }
rcdie() { echo "$SESSION: $*" >&2; exit 1; }
server_pid() { local root; root=$(tmux display -p -t "$PANE" '#{pane_pid}' 2>/dev/null) || return 1; rc_server_pid_under "$root"; }
loop_alive() {  # the --run loop under the pane (true also during its sleep window)
    local root pid q
    root=$(tmux display -p -t "$PANE" '#{pane_pid}' 2>/dev/null) || return 1
    for pid in $(pgrep -f -- 'salamander rc --run'); do
        [ "$pid" = "$$" ] && continue
        is_under "$pid" "$root" && return 0
    done
    return 1
}
wait_server() { local i; for ((i=0; i<$1; i++)); do server_pid >/dev/null && return 0; sleep 1; done; return 1; }

cmd="${1:---ensure}"
case "$cmd" in
--run)
    export PATH="$(dirname "$SALA_CLAUDE"):$PATH"
    [ -n "${RC_MODEL:-}" ] && export ANTHROPIC_MODEL="$RC_MODEL"
    [ -n "${RC_EFFORT:-}" ] && export CLAUDE_CODE_EFFORT_LEVEL="$RC_EFFORT"
    log "loop start (capacity $CAP, name '$NAME', delay ${DELAY}s, model ${RC_MODEL:-from settings}, effort ${RC_EFFORT:-from settings})"
    trap 'log "loop ending (signal)"; exit 0' TERM HUP
    while :; do
        log "launching: $(readlink -f "$SALA_CLAUDE")"
        tmux select-pane -t "$PANE" -T "$SESSION" 2>/dev/null   # pane title = session name (resurrect restores titles, a stale one would survive every restore)
        "$SALA_CLAUDE" remote-control --name "$NAME" --capacity "$CAP"; rc=$?
        [ -e "$STOP_MARKER" ] && { log "server exited rc=$rc; stop marker present — loop ending"; exit 0; }
        log "server exited rc=$rc; relaunch in ${DELAY}s"; sleep "$DELAY"
    done ;;
--ensure|--start)
    [ "$cmd" = --start ] && rm -f "$STOP_MARKER"
    [ -e "$STOP_MARKER" ] && { echo "$SESSION: stopped by --stop ($(cs_date -r "$STOP_MARKER" '+%F %H:%M %Z')); use --start"; exit 0; }
    [ -x "$SALA_CLAUDE" ] || rcdie "claude not found at $SALA_CLAUDE"
    if ! tmux has-session -t "$(tmux_sess_t "$SESSION")" 2>/dev/null; then
        tmux new-session -d -s "$SESSION" -c "$HOME" "'$SALA_BIN' rc --run" || rcdie "tmux new-session failed"
        tmux select-pane -t "$PANE" -T "$SESSION" 2>/dev/null
        log "tmux session $SESSION created"
    elif loop_alive; then :
    else  # bare shell (e.g. restored by tmux-resurrect after a reboot)
        tmux send-keys -X -t "$PANE" cancel 2>/dev/null
        tmux send-keys -t "$PANE" "exec '$SALA_BIN' rc --run" Enter
        log "loop started in existing bare-shell pane"
    fi
    if wait_server 60; then pid=$(server_pid); echo "$SESSION: running (pid $pid, $(proc_version "$pid"), capacity $CAP)"
    else rcdie "loop is up but no server process appeared within 60s — check $LOG and: tmux attach -t =$SESSION"; fi ;;
--restart)
    old=$(server_pid) || rcdie "no server running — use --ensure"
    log "--restart: SIGINT to server pid $old ($(proc_version "$old"))"
    kill -INT "$old"; for ((i=0; i<30; i++)); do kill -0 "$old" 2>/dev/null || break; sleep 1; done
    kill -0 "$old" 2>/dev/null && { kill -TERM "$old"; sleep 3; }
    if wait_server $((DELAY + 60)); then pid=$(server_pid); echo "$SESSION: restarted (pid $old → $pid, now $(proc_version "$pid"))"
    else rcdie "server did not come back within $((DELAY + 60))s — check $LOG and: tmux attach -t =$SESSION"; fi ;;
--stop)
    touch "$STOP_MARKER"
    if pid=$(server_pid); then kill -INT "$pid"; for ((i=0; i<30; i++)); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done; fi
    tmux kill-session -t "$(tmux_sess_t "$SESSION")" 2>/dev/null && log "--stop: tmux session $SESSION killed"
    echo "$SESSION: stopped (marker $STOP_MARKER — revive sweeps will not restart it; --start to resume)" ;;
--status)
    tmux has-session -t "$(tmux_sess_t "$SESSION")" 2>/dev/null || { echo "$SESSION: tmux session absent$( [ -e "$STOP_MARKER" ] && echo ' (stopped by --stop)')"; exit 1; }
    if pid=$(server_pid); then echo "$SESSION: pid $pid  $(proc_version "$pid")  up $(ps -o etime= -p "$pid" | tr -d ' ')"
    else echo "$SESSION: no server process (loop $(loop_alive && echo 'alive — relaunching' || echo 'DEAD'))"; fi
    if [ -n "${pid:-}" ]; then
        args=$(proc_args "$pid" | tr ' ' '\n')
        nserved=$(rc_served 2>/dev/null | grep -c .)
        echo "  on claude.ai: Remote Control → $(hostname), $nserved of $(printf '%s\n' "$args" | grep -A1 -x -- '--capacity' | tail -1) sessions  ·  '$(printf '%s\n' "$args" | grep -A1 -x -- '--name' | tail -1)' is only the pre-created session's name"
        senv=$({ tr '\0' '\n' < "/proc/$pid/environ"; } 2>/dev/null)   # Linux only; elsewhere the pins fall back to settings
        smodel=$(printf '%s\n' "$senv" | sed -n 's/^ANTHROPIC_MODEL=//p'); seff=$(printf '%s\n' "$senv" | sed -n 's/^CLAUDE_CODE_EFFORT_LEVEL=//p')
        cfg=$(python3 -c 'import json,os;d=json.load(open(os.path.expanduser("~/.claude/settings.json")));print(d.get("model"),d.get("effortLevel"))' 2>/dev/null)
        echo "  served sessions start on: model ${smodel:-<settings: ${cfg%% *}>}  ·  effort ${seff:-<settings effortLevel: ${cfg##* }>}"
    fi
    tmux capture-pane -p -J -S - -t "$PANE" | grep -E 'Connected|Disconnected|Reconnected|error' | tail -1 | sed 's/^/  last: /'
    echo "  served sessions (registry rows on this pane):"; found=0
    for f in "$SALA_REG_DIR"/*.json; do
        [ -r "$f" ] || continue
        p=${f##*/}; p=${p%.json}; kill -0 "$p" 2>/dev/null || continue
        PROJ="$SALA_PROJECTS" python3 - "$f" "$SESSION" <<'PY' && found=1
import json, sys, os, glob
d = json.load(open(sys.argv[1]))
if not str(d.get('tmux', '')).startswith(sys.argv[2] + ':'): sys.exit(1)
sid = d.get('sessionId', ''); first = ''
try:
    hits = glob.glob(os.path.join(os.environ["PROJ"], "*", sid + ".jsonl"))
    for line in open(max(hits, key=os.path.getmtime)):
        r = json.loads(line)
        if r.get('type') == 'user' and not r.get('isMeta'):
            c = r['message']['content']; first = c if isinstance(c, str) else next((x.get('text','') for x in c if x.get('type')=='text'), '')
            break
except Exception: pass
print(f"    {sid}  status={d.get('status')}  web={d.get('bridgeSessionId')}  first-msg={first[:50]!r}")
PY
    done
    [ "$found" = 1 ] || echo "    (none)" ;;
--archive|--unarchive)
    action=${cmd#--}; shift; [ $# -gt 0 ] || rcdie "--$action needs one or more web session ids (session_… or cse_…)"
    # REFUSE to archive a session that a LIVE pane on this box is bridged to: that hides the session the user is
    # looking at on claude.ai (a grep once picked the invoking session's own id). Served RC sessions are
    # not panes and are exactly what --archive is for.
    if [ "$action" = archive ]; then
        for raw in "$@"; do
            if hit=$(live_pane_for_bridge "$raw"); then
                rcdie "refusing to archive $raw: it is the claude.ai session of LIVE pane '${hit%% *}' (${hit#* }) — /exit that pane first, or archive it on claude.ai"
            fi
        done
    fi
    ACTION="$action" python3 - "$@" <<'PY'
import json, sys, os, urllib.request, urllib.error
act = os.environ['ACTION']
tok = json.load(open(os.path.expanduser('~/.claude/.credentials.json')))['claudeAiOauth']['accessToken']
H = {'Authorization': f'Bearer {tok}', 'Content-Type': 'application/json', 'anthropic-version': '2023-06-01', 'anthropic-client-platform': 'cli'}
rc = 0
for raw in sys.argv[1:]:
    sid = 'cse_' + raw.split('_', 1)[1] if raw.startswith(('session_', 'cse_')) else raw
    req = urllib.request.Request(f'https://api.anthropic.com/v1/code/sessions/{sid}/{act}', data=b'{}', headers=H, method='POST')
    try:
        with urllib.request.urlopen(req, timeout=20) as r: print(f"{act}d  {sid}  ({json.load(r).get('session', {}).get('title', '?')})")
    except urllib.error.HTTPError as e: rc = 1; print(f'FAILED    {sid}  HTTP {e.code} — do it on claude.ai instead')
sys.exit(rc)
PY
    ;;
# --help prints the whole leading comment block after its title line (to the first non-comment line), then the blank line
# that closes it; anchored on the block's end, not a fixed line range, and no note in the header (it would print too)
-h|--help) awk 'NR==1{next} /^#/{print; next} {exit}' "$SALA_ROOT/lib/rc.sh" | sed 's/^# \{0,1\}//'; echo ;;
*) rcdie "unknown option '$cmd' (see: salamander rc --help)" ;;
esac
