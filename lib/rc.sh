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
#   rc --titles [--dry-run | --apply (--only NAME (repeatable) | --all)]
#                      claude.ai shows each pane's Remote Control session under a title written once, when the
#                      bridge session is made, and changed afterwards only by a rename inside the CLI: a pane started
#                      with --name never renames, so its title can stay an auto-generated name while its sala name is
#                      right everywhere else. Bare: a read-only table of the live bridged panes whose claude.ai title
#                      differs from the pane's name (exit 0 either way; a pane whose session is past the first 100
#                      is counted as "not listed", never guessed). --apply --only NAME (repeatable) sets just those panes' titles
#                      to their names (PUT /v1/code/sessions/<id> {"title": NAME}, the same UNOFFICIAL endpoint family
#                      as --archive), then re-reads and says ok or FAILED per pane; --apply alone is refused, --all
#                      applies to every differing pane (a pane not in the first 100 is FAILED, exit 1). Only a name in
#                      [a-z0-9-] with nameSource user; idempotent. --dry-run is the bare form spelled out; with --apply
#                      it is refused. A name two live panes carry is refused before any PUT.
#                      SALA_ANTHROPIC_API (default https://api.anthropic.com) moves the API for a test.
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
--titles)
    shift; tapply=0; tall=0; tdry=0; tonly=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --apply) tapply=1; shift ;;
            --all) tall=1; shift ;;
            --dry-run) tdry=1; shift ;;
            --only) [ $# -ge 2 ] && [ -n "$2" ] || rcdie "--only needs a pane name"; tonly+="$2"$'\n'; shift 2 ;;
            --only=?*) tonly+="${1#--only=}"$'\n'; shift ;;
            *) rcdie "--titles: unknown argument '$1' (see: salamander rc --help)" ;;
        esac
    done
    [ "$tdry" = 0 ] || [ "$tapply" = 0 ] || rcdie "--titles: --dry-run and --apply contradict each other (--dry-run is the read-only list); use one. Nothing was changed"
    [ "$tapply" = 0 ] || [ "$tall" = 1 ] || [ -n "$tonly" ] || rcdie "--titles --apply needs --only NAME (repeatable: --only a --only b) to name the panes; a bulk apply to every differing pane needs --all"
    [ "$tapply" = 1 ] || [ "$tall" = 0 ] || rcdie "--titles --all needs --apply (the bare form is the read-only list)"
    [ "$tall" = 0 ] || [ -z "$tonly" ] || rcdie "--titles: --all and --only are two ways to choose the panes; use one"
    # the live bridged panes (as live_pane_for_bridge: a registry row with a tmux session, pid alive, not an RC child; the bridge id from the
    # row, else the transcript's last remote_session_change): name TAB bridge id TAB nameSource. With --only, only those names are looked at.
    panes=""
    for f in "$SALA_REG_DIR"/*.json; do
        [ -r "$f" ] || continue; pid=${f##*/}; pid=${pid%.json}; case "$pid" in ''|*[!0-9]*) continue;; esac
        kill -0 "$pid" 2>/dev/null || continue
        registry_field_r tn "$pid" tmux; [ -n "$tn" ] || continue
        is_rc_child "$pid" && continue
        registry_field_r pname "$pid" name
        if [ -n "$tonly" ]; then case $'\n'"$tonly" in *$'\n'"$pname"$'\n'*) ;; *) continue ;; esac; fi
        registry_field_r psrc "$pid" nameSource; registry_field_r pb "$pid" bridgeSessionId
        if [ -z "$pb" ] || [ "$pb" = null ]; then registry_field_r psid "$pid" sessionId; pb=$(bridge_for_uuid "$psid" 2>/dev/null); fi
        [ -n "$pb" ] && [ "$pb" != null ] || continue
        panes+="$pname"$'\t'"$pb"$'\t'"$psrc"$'\n'
    done
    TITLES_PANES="$panes" TITLES_ONLY="$tonly" TITLES_ALL="$tall" TITLES_APPLY="$tapply" python3 - <<'PY'
import json, sys, os, re, urllib.request, urllib.error
base = os.environ.get('SALA_ANTHROPIC_API', 'https://api.anthropic.com').rstrip('/')
apply_ = os.environ['TITLES_APPLY'] == '1'
only = [x for x in os.environ['TITLES_ONLY'].split('\n') if x]
try: tok = json.load(open(os.path.expanduser('~/.claude/.credentials.json')))['claudeAiOauth']['accessToken']
except Exception: print('rc --titles: no claude.ai login found in ~/.claude/.credentials.json'); sys.exit(1)
H = {'Authorization': f'Bearer {tok}', 'Content-Type': 'application/json', 'anthropic-version': '2023-06-01', 'anthropic-client-platform': 'cli'}
def safe(x): return str(x).replace(tok, '<token>') if tok else str(x)
def call(method, path, body=None):  # (status, text); a network failure is status 0 and its reason, never a traceback
    req = urllib.request.Request(base + path, data=None if body is None else json.dumps(body).encode(), headers=H, method=method)
    try:
        with urllib.request.urlopen(req, timeout=20) as r: return r.status, r.read().decode('utf-8', 'replace')
    except urllib.error.HTTPError as e: return e.code, e.read().decode('utf-8', 'replace')
    except Exception as e: return 0, f'{type(e).__name__}: {e}'
def cloud():  # claude.ai id without its prefix -> the session row; None when the list cannot be read (the reason printed)
    st, txt = call('GET', '/v1/code/sessions?limit=100')
    if st != 200: print(f'rc --titles: cannot list claude.ai sessions: HTTP {st} {safe(txt)[:200]}'); return None
    try: d = json.loads(txt)
    except Exception: print('rc --titles: the session list is not JSON'); return None
    rows = (d.get('data') or d.get('items') or []) if isinstance(d, dict) else []
    return {x['id'].split('_', 1)[1]: x for x in rows if isinstance(x, dict) and '_' in str(x.get('id', ''))}
def clean(t): return '(none)' if t is None else str(t).replace('\n', ' ')
cl = cloud()
if cl is None: sys.exit(1)
panes = {}; order = []; amb = {}
for line in os.environ['TITLES_PANES'].split('\n'):
    f = line.split('\t')
    if len(f) != 3: continue
    if f[0] not in panes: panes[f[0]] = f; order.append(f[0])
    elif f[1] != panes[f[0]][1]:  # two live panes with one name and different claude.ai sessions: which one the name means is not guessed
        amb.setdefault(f[0], [panes[f[0]][1]]); amb[f[0]] += [] if f[1] in amb[f[0]] else [f[1]]
listed, notlisted = [], []
for n in order:
    b = panes[n][1]; row = cl.get(b.split('_', 1)[1]) if '_' in b else None
    (listed if row else notlisted).append((n, row))
def eligible(n):
    if not re.fullmatch(r'[a-z0-9-]+', n): return 'its name is not in [a-z0-9-]'
    if panes[n][2] != 'user': return f'its nameSource is {panes[n][2] or "unset"}, not user'
    return ''
if not apply_:
    diff = [(n, r) for n, r in listed if r.get('title') != n]
    if diff:
        w = max(len(n) for n, _ in diff)
        print(f"{'NAME':<{w}}  {'CLAUDE.AI TITLE':<40}  STATUS")
        for n, r in diff:
            why = eligible(n)
            print(f"{n:<{w}}  {clean(r.get('title'))[:40]:<40}  {r.get('status', '?')}/{r.get('connection_status', '?')}{'  (cannot be set: ' + why + ')' if why else ''}")
        print(f'{len(diff)} of {len(listed)} bridged panes carry another title: salamander rc --titles --apply --only NAME [--only NAME]… (or --all)')
    else: print(f'all {len(listed)} bridged panes carry their sala name')
    if amb: print(f"ambiguous ({len(amb)}): {', '.join(sorted(amb))}  (more than one live pane carries the name; --apply refuses it)")
    if notlisted: print(f"not listed ({len(notlisted)}): {', '.join(n for n, _ in notlisted)}  (their claude.ai session is not in the first 100 sessions)")
    sys.exit(0)
rc = 0; todo = []; lrow = dict(listed)
names = only if only else [n for n, r in listed if r.get('title') != n]
clash = [n for n in dict.fromkeys(only if only else order) if n in amb]
if clash:  # before any PUT: a name two live panes carry cannot say which of them it renames
    for n in clash: print(f"FAILED  {n}  ambiguous: {len(amb[n])} live panes carry this name (claude.ai sessions {', '.join(amb[n])}); nothing was changed")
    sys.exit(1)
for n in names:
    if n not in panes: print(f'FAILED  {n}  no live bridged pane of that name'); rc = 1; continue
    row = lrow.get(n)
    if row is None: print(f'FAILED  {n}  not listed: its claude.ai session is not in the first 100 sessions'); rc = 1; continue
    why = eligible(n)
    if why:  # named by --only: a refusal; picked by --all: a pane it cannot set is left out, said, and not a failure
        if only: print(f'FAILED  {n}  refused: {why}'); rc = 1
        else: print(f'skip    {n}  {why}')
        continue
    if row.get('title') == n: print(f'ok      {n}  already carries its name'); continue
    st, txt = call('PUT', '/v1/code/sessions/cse_' + panes[n][1].split('_', 1)[1], {'title': n})
    if st != 200: print(f'FAILED  {n}  HTTP {st} {safe(txt)[:200]}'); rc = 1; continue
    todo.append(n)
if not only:  # --all: a pane whose session is past the API's first page cannot be checked: said per pane, and the exit is not 0
    for n, _ in notlisted: print(f'FAILED  {n}  not listed: its claude.ai session is not in the first 100 sessions'); rc = 1
if todo:
    after = cloud()
    for n in todo:
        r = (after or {}).get(panes[n][1].split('_', 1)[1])
        if r and r.get('title') == n: print(f'ok      {n}  title set')
        elif r: print(f"FAILED  {n}  set, but the re-read shows {clean(r.get('title'))!r}"); rc = 1
        else: print(f'FAILED  {n}  set, but the re-read could not find the session'); rc = 1
if not names: print(f'all {len(listed)} bridged panes carry their sala name' if not notlisted else f'all {len(listed)} listed bridged panes carry their sala name; {len(notlisted)} could not be checked')
sys.exit(rc)
PY
    ;;
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
