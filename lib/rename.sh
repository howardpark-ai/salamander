# lib/rename.sh — rename a live pane end to end, so every record that knows it by name follows.
#
#   salamander rename OLD NEW [--dry-run]
#   (a pane already /renamed to NEW by hand: nothing is typed, sala's records are brought in line)
#
# A bare /rename changes only the Claude session's own name: the tmux session (which sala finds the pane by), the
# pane→conversation map revive resumes from, and SALA_MASTER keep the old one, so the next revive brings the pane back
# under it. Renames are the master's (sala owns
# the whole rename, names inside gbrain and the board are stackshot's). In order:
#   0. NEW not on its project's page: sala has stackshot rename OLD's entry there in place (`post project-agent-rename`, label sala-rename), after the refusals of step 1
#      have passed. The entry keeps its line, place and side; the server decides. A refusal (NEW
#      already listed, OLD not listed, not the form, a bad prefix) stops the rename with stackshot's reason and nothing renamed. A pane
#      whose status cannot be read is unknown, not busy: it goes ahead.
#   0b. OLD a SIDE SESSION (a record in $SALA_STATE_DIR/side/; common.sh, THE SIDE SESSIONS) renamed to an agent name: it is on no page's agents
#      map, so there is no entry to rename. A NEW its project does not list is listed as a new front agent through `post project-agent` (label
#      sala-web, pending in stackshot's record; the page line stays its keeper's), the project being the record's, else its origin agent's; no
#      project = refused, in the plan (--dry-run) too. Called after the busy-pane wait of step 1, before /rename is typed; a refusal renames
#      nothing and keeps the record. After step 3 the side record ends (moved to side/retired/, the registry row's side fields cleared, the row
#      tagged project / front): no write-up (`side done`, the summary) is owed any more. --sync never does this.
#   1. refuse: NEW already live (a tmux session, or a running claude's name on another conversation), OLD not a live
#      Claude pane, OLD not in the pane map (adopt first; a spawn still landing its row is waited for, up to 60 s, and a side spawn its side record before step 0 / 0b decide which path), OLD the Remote Control server; a busy pane, a terminal-only
#      prompt or unsent text is waited out (60 s here, then a detached retry every 60 s for 2 h, which posts its outcome)
#   2. /rename NEW typed into the pane, verified against the registry (same conversation, same claude.ai link);
#      run directly inside OLD's own pane (TMUX_PANE names it) nothing is typed: a pane cannot type into itself, so only a hand `/rename NEW` there
#      sets the name. A queued `sala op rename OLD NEW` has no pane (the runner is a unit): it types /rename itself from outside, once the pane is idle,
#      trying again every minute for 2 h, also when OLD is the pane that asked; op's plan runs this dry run without TMUX_PANE for that reason
#   3. the tmux session renamed, the map row rewritten, SALA_MASTER moved when OLD was the master, open notes relabelled
#      (notes and the board follow the conversation id already; cues are delivered, never stored by name)
#   4. a record in salamander-renames.jsonl and an immediate heartbeat: the fleet state's row for this conversation
#      carries previous_name + renamed_at, which is how stackshot learns "uuid X was OLD, is now NEW"
# The registry's own "tmux" field keeps the old session name until that claude restarts (the CLI writes it at start);
# lookups that matter resolve through the pane id or the process tree, not that name.

usage="usage: salamander rename OLD NEW [--dry-run]   ·   salamander rename --sync"

# ── --sync: follow hand renames (closes a gap, and prevents it from
# reopening). A /rename typed in a pane or a rename on claude.ai reaches Claude Code only — sala cannot stop
# or intercept it — so sala follows it within seconds instead: `salamander follow` (lib/follow.py, sala-follow.service) runs this
# when a session's name actually changes; `salamander watch` runs it too, as the backstop. A pane whose user-set name
# differs from its tmux session gets the same alignment as `rename OLD NEW` (nothing typed: the name is already set),
# and the master hears one line. Left alone: a claude started under a minute ago (a `spawn --fork` carries the old
# name until spawn's own /rename), a pane a `rename` is already working on, and a name sala can't take (another live
# session has it, or characters tmux refuses) — that one is reported once per name. A name changed and changed back
# before this runs leaves nothing to do. Exit 3 = the master was renamed (the caller's SALA_MASTER is stale).
if [ "${1:-}" = --sync ]; then
    exec 8>"$SALA_LOG_DIR/salamander-rename-sync.lock"; flock -n 8 || exit 0
    recycle_locked && exit 0   # a recycle holds the panes right now (common.sh): names are in flux, follow them next time
    ledger_frozen && exit 0    # the pane map takes no rename while a recycle or reboot holds it: next pass
    AST="$SALA_LOG_DIR/salamander-rename-sync.state"; [ -e "$AST" ] || >> "$AST"
    # a hand rename is a registry row whose name the user set (nameSource "user"): with no such row there is nothing to follow, and the
    # tmux call and the python scan below are skipped (they were four processes on every watch run)
    cand=0; for f_ in "$SALA_REG_DIR"/*.json; do [ -e "$f_" ] || continue; c_=""; { IFS= read -r -d '' c_ < "$f_"; } 2>/dev/null || :; [[ $c_ =~ \"nameSource\"[[:space:]]*:[[:space:]]*\"user\" ]] && { cand=1; break; }; done
    tell() {  # <master name> <line> → the master's inbox, else the log
        local mp="" c sock
        case "$3" in sala-test-*) echo "[$(date -Is)] (test pane, not reported) $2" >> "$SALA_LOG_DIR/salamander-rename.log"; return ;; esac
        [ -n "$1" ] && mp=$(tmux list-panes -t "$(tmux_win_t "$1")" -F '#{pane_id}' 2>/dev/null | head -1)
        c=$([ -n "$mp" ] && claude_pid_under "$(tmux display -p -t "$mp" '#{pane_pid}')" 2>/dev/null)
        sock=$([ -n "$c" ] && session_socket "$c")
        { [ -n "$sock" ] && session_push "$sock" "[sala rename] $2"; } || echo "[$(date -Is)] master not reachable: $2" >> "$SALA_LOG_DIR/salamander-rename.log"
    }
    moved=0
    while IFS='|' read -r sess name uuid age; do
        [ "$age" -ge 60 ] || continue
        re_escape_r sess_re "$sess"; pgrep_mine "bin/(sala|salamander) rename $sess_re " >/dev/null && continue   # this instance's renames only (common.sh)
        [ "$(awk -F= -v k="$uuid" '$1==k {print substr($0, length(k)+2); exit}' "$AST")" = "$name" ] && continue
        unl=$(agent_unlisted "$name") || unl=""
        out=$(SALA_RENAME_SYNC=1 "$SALA_BIN" rename "$sess" "$name" 2>&1); rc=$?
        if [ "$rc" = 4 ]; then   # not in the pane map (below): a throwaway session renamed in its own pane is its own business
            { grep -v "^$uuid=" "$AST"; echo "$uuid=$name"; } > "$AST.tmp.$$" && mv -f "$AST.tmp.$$" "$AST"
            echo "[$(date -Is)] sync: '$sess' → '$name' (hand rename) left alone: not in the pane map" >> "$SALA_LOG_DIR/salamander-rename.log"
        elif [ "$rc" = 0 ]; then
            echo "[$(date -Is)] sync: '$sess' → '$name' (hand rename): $(echo "$out" | tail -1)" >> "$SALA_LOG_DIR/salamander-rename.log"
            extra=""; if [ -n "${SALA_MASTER:-}" ] && [ "$sess" = "$SALA_MASTER" ]; then moved=1; SALA_MASTER="$name"; extra=", SALA_MASTER"; fi
            tell "${SALA_MASTER:-}" "'$sess' was renamed to '$name' by hand; sala lined up its tmux session, revive map$extra and notes.${unl:+ Note: $unl}" "$sess"
        else
            { grep -v "^$uuid=" "$AST"; echo "$uuid=$name"; } > "$AST.tmp.$$" && mv -f "$AST.tmp.$$" "$AST"
            echo "[$(date -Is)] sync refused: '$sess' → '$name': $out" >> "$SALA_LOG_DIR/salamander-rename.log"
            tell "${SALA_MASTER:-}" "'$sess' was renamed to '$name' by hand, but sala can't follow: $(echo "$out" | tail -1 | sed 's/^✗ //'). Its tmux session stays '$sess'; a rename to a free name (sala rename) fixes it." "$sess"
        fi
    done < <([ "$cand" = 1 ] && tmux list-panes -a -F '#{pane_id}|#{session_name}|#{pane_pid}' 2>/dev/null | REG="$SALA_REG_DIR" RC="$SALA_RC_SESSION" python3 -c '
import json, glob, os, sys, time
panes, shells = {}, {}
for l in sys.stdin:
    p = l.rstrip("\n").split("|")
    if len(p) == 3: panes[p[0]], shells[p[0]] = p[1], p[2]
def under(pid, top):   # pid descends from top (the pane shell); /proc/<pid>/stat is readable for any process
    while pid not in ("", "0", "1"):
        if pid == top: return True
        try: st = open("/proc/%s/stat" % pid).read(); pid = st[st.rindex(")") + 2:].split()[1]
        except Exception: return False
    return False
for f in glob.glob(os.path.join(os.environ["REG"], "*.json")):
    try: d = json.load(open(f)); os.kill(int(os.path.basename(f)[:-5]), 0)
    except PermissionError: pass
    except Exception: continue
    t = d.get("tmux") or ""
    if "%" not in t: continue
    pid = "%" + t.rsplit("%", 1)[1]
    sess = panes.get(pid)   # the pane id is stable; the session name in "tmux" is the one at start
    # a pane id is per server (a probe on a private tmux socket, pane %1, was once taken for the fleet
    # %1, and the master was told of a rename that never happened): the claude must run in that fleet pane
    if sess and not under(os.path.basename(f)[:-5], shells.get(pid, "")): continue
    name, uuid = d.get("name") or "", d.get("sessionId") or ""
    if not sess or not name or not uuid or name == sess or sess == os.environ["RC"] or d.get("nameSource") != "user": continue
    age = int(time.time() - (d.get("startedAt") or 0) / 1000)
    print("%s|%s|%s|%d" % (sess, name, uuid, age))')
    exit $([ "$moved" = 1 ] && echo 3 || echo 0)
fi
OLD="${1:-}"; NEW="${2:-}"
case "$OLD$NEW" in '') die "$usage";; esac
case "$OLD" in -*|'') die "$usage";; esac
case "$NEW" in -*|'') die "$usage";; esac
shift 2; DRY=0; WORKER=0; DRYF=""
while [ $# -gt 0 ]; do case "$1" in --dry-run) DRY=1; DRYF=--dry-run ;; --retry-worker) WORKER=1 ;; *) die "unknown option: $1" ;; esac; shift; done
ops_guard rename "$OLD" $DRYF
[ "$DRY" = 1 ] || ledger_frozen_die rename   # a recycle or reboot holds the pane map: nothing typed, nothing renamed
case "$NEW" in *[!A-Za-z0-9_-]*) die "invalid name '$NEW' (letters, digits, '-' and '_' only)";; esac
[ "$OLD" != "$NEW" ] || die "'$OLD' already has that name"
[ "$NEW" = "$SALA_RC_SESSION" ] && die "'$NEW' is the Remote Control server's name"
is_shell_session "$NEW" && die "'$NEW' is the web UI's shell session (SALA_SHELL_SESSION) — a Claude session cannot take its name; pick another name"
[ "$OLD" = "$SALA_RC_SESSION" ] && die "'$OLD' is the Remote Control server — its name is SALA_RC_SESSION in the config"
tmux has-session -t "=$OLD" 2>/dev/null || die "no tmux session '$OLD'"
tmux has-session -t "=$NEW" 2>/dev/null && die "a tmux session '$NEW' already exists"
pane=$(tmux list-panes -t "$(tmux_win_t "$OLD")" -F '#{pane_id}' | head -1)
# THE SPAWN WINDOW (Tue Oct 27th 2026): a spawn writes the row on its way out, after the pane is up with a running
# claude, so a fresh session renaming itself at once found no row and was refused for good. A session that is a spawn in flight is
# waited for (SALA_RENAME_MAP_WAIT seconds, default 60, 0 = no wait; polled every 2 s): its row lands, or the same refusal follows. The
# window opens earlier too: the claude may not be running yet, and its registry entry (the sessionId) lands a moment after it starts
# (`sala op --plan rename X Y` right after a spawn once died on "no registry entry"), and a side spawn writes its side record
# (the .side file) later still, which the side-or-in-place decision below needs (the last wait, ahead of that decision). Those lookups and
# the row wait share one budget (spawn_wait), the waiting line naming what it waits for. In
# flight = a spawn operation for OLD that is queued, running or waiting (the marker under $SALA_STATE_DIR/ops, exact), or a tmux session
# created under SALA_RENAME_YOUNG seconds ago (default 120; a spawn run by hand has no marker). An older session, a hand-made throwaway
# included, is refused at once, as is --sync (SALA_RENAME_SYNC=1: it relies on the exit 4 being fast).
spawn_in_flight() {  # <session> <pane> → 0 when the session is a spawn still to land its row
    local f created
    for f in "$SALA_STATE_DIR"/ops/*.op; do
        [ -e "$f" ] || continue
        [ "$(_kv_first "$f" verb)" = spawn ] && [ "$(_kv_first "$f" arg)" = "$1" ] || continue
        case "$(_kv_first "$f" state)" in queued|running|waiting) return 0;; esac
    done
    created=$(tmux display -p -t "$2" '#{session_created}' 2>/dev/null || true)
    case "$created" in ''|*[!0-9]*) return 1;; esac
    [ $(( $(date +%s) - created )) -lt "${SALA_RENAME_YOUNG:-120}" ]
}
spawn_is_side() {  # <session> → 0 when the spawn is a side one: the in-flight spawn operation's own arguments when it has one (exact), else the name
    local f
    for f in "$SALA_STATE_DIR"/ops/*.op; do
        [ -e "$f" ] || continue
        [ "$(_kv_first "$f" verb)" = spawn ] && [ "$(_kv_first "$f" arg)" = "$1" ] || continue
        case "$(_kv_first "$f" state)" in queued|running|waiting) grep -qxF 'arg=--side' "$f"; return;; esac
    done
    [[ $1 == *-side-?* ]]
}
mapwait=${SALA_RENAME_MAP_WAIT:-60}; [ "${SALA_RENAME_SYNC:-}" != 1 ] || mapwait=0
case "$mapwait" in ''|*[!0-9]*) mapwait=60;; esac
waitleft=$mapwait
spawn_wait() {  # <what it waits for> <ready command…> → 0 once the command holds; waits (shared budget) only while a spawn of OLD is in flight
    local what="$1"; shift
    "$@" && return 0
    [ "$waitleft" -gt 0 ] && spawn_in_flight "$OLD" "$pane" || return 1
    echo "… waiting for the spawn of '$OLD' to land its $what (up to $waitleft s)"
    while [ "$waitleft" -gt 0 ]; do sleep 2; waitleft=$((waitleft - 2)); "$@" && return 0; done
    return 1
}
# THE SIDE RECORD OF A SPAWN IN FLIGHT (last race): spawn --side writes the .side file late in the spawn (side_record), so the
# decision just below (a side session listed on its project, or an entry renamed in place) is not taken before it lands: a side spawn in
# flight is waited for first, on the shared budget (the later waits use what is left). Not landed within it: today's behaviour. --sync: mapwait is 0.
side_is "$OLD" || ! spawn_is_side "$OLD" || spawn_wait "side record" side_is "$OLD" || true
# NEW is not on its project's page (a hand rename, --sync, is followed, not refused): stackshot renames OLD's entry there in place
# (project-agent-rename, common.sh), once the checks below have passed; stackshot's refusal stops the rename, with its reason
RL=0; SD=0; SDL=0
if [ "${SALA_RENAME_SYNC:-}" != 1 ]; then
    if side_is "$OLD" && [[ $NEW != *-side-* ]]; then
        # A SIDE SESSION becoming an agent: it is on no page's agents map, so there is no entry to rename in place. NEW unlisted:
        # sala lists NEW as a new front agent (stackshot's project-agent, pending in its record) and the side record ends; refused here, in the plan,
        # when the project cannot be named. NEW already listed (or the check could not tell): no call, the side record ends all the same.
        SD=1
        if why=$(agent_unlisted "$NEW"); then
            rename_side_plan "$OLD" "$NEW" || die "$RL_WHY"
            SDL=1
        fi
    elif why=$(agent_unlisted "$NEW"); then
        rename_list_plan "$why" || die "$why (sala could not rename the page entry either: $RL_WHY)"
        RL=1
    fi
fi

have_claude() { cpid=$(claude_pid_under "$(tmux display -p -t "$pane" '#{pane_pid}')" || true); [ -n "$cpid" ]; }
have_uuid() { have_claude && uuid=$(registry_field "$cpid" sessionId) && [ -n "$uuid" ]; }
have_row() { [ -n "$(ledger_row "$OLD")" ] || [ -n "$(ledger_uuid_rows "$uuid")" ]; }
spawn_wait "running claude" have_claude
[ -n "$cpid" ] || die "'$OLD' has no running claude — revive it first (salamander revive --only $OLD)"
uuid=""; spawn_wait "registry entry" have_uuid
bridge=$(registry_field "$cpid" bridgeSessionId); [ "$bridge" = null ] && bridge=""
[ -n "$uuid" ] || die "no registry entry for '$OLD' (pid $cpid)"
# NOT IN THE PANE MAP (renames of two hand-made throwaway sessions added a map row each,
# and the next recycle brought one back as a fleet session): a session the map has no row for, on a conversation no row
# carries, is not sala's to rename. Checked here, before anything is typed or renamed, like the freeze, so nothing is left
# half done; the ledger refuses it too (common.sh, _ledger_apply). Exit 4, so --sync (above) can tell it from a failure.
spawn_wait "pane-map row" have_row || true
if [ -z "$(ledger_row "$OLD")" ] && [ -z "$(ledger_uuid_rows "$uuid")" ]; then
    echo "✗ '$OLD' is not in the pane map (nor is its conversation ${uuid:0:8}…), so sala does not rename it: sala adopt $OLD first if it should come back after a relaunch, otherwise rename it with /rename in its own pane" >&2
    exit 4
fi
# a name is live when a running claude in another conversation carries it (a fresh spawn of a freed name is fine)
taken=$(REG="$SALA_REG_DIR" python3 - "$NEW" "$uuid" <<'PY'
import json, glob, os, sys
for f in glob.glob(os.path.join(os.environ["REG"], "*.json")):
    try: d = json.load(open(f)); os.kill(int(os.path.basename(f)[:-5]), 0)
    except PermissionError: pass
    except Exception: continue
    if d.get("name") == sys.argv[1] and d.get("sessionId") != sys.argv[2]: print(d.get("tmux", "").split(":")[0] or "?"); break
PY
)
[ -z "$taken" ] || die "'$NEW' is already the name of a live session (tmux '$taken')"
here=$(tmux display -p -t "${TMUX_PANE:-}" '#{session_name}' 2>/dev/null || true)
SELF=0; [ -n "${TMUX_PANE:-}" ] && [ "$here" = "$OLD" ] && [ "$WORKER" = 0 ] && SELF=1
cur=$(registry_field "$cpid" name)
status_known() { local st; registry_field_r st "$cpid" status; [ -n "$st" ]; }   # 1: the pane's registry row gives no status (below, step 1)

if [ "$DRY" = 1 ]; then
    echo "[dry-run] '$OLD' → '$NEW'  (conversation ${uuid:0:8}…, claude.ai ${bridge:-no bridge})"
    if [ "$SELF" = 1 ]; then echo "  a direct run inside this pane, which cannot type into itself: nothing typed; ${cur:+session name now '$cur'}${cur:+ — }/rename $NEW has to be typed in the pane by hand if it is not '$NEW' yet (a queued \`sala op rename $OLD $NEW\` types it from outside once the pane is idle)"
    else echo "  type /rename $NEW (pane now: ${cur:-unnamed}; $(if status_known; then why=$(is_idle_reason "$cpid"); echo "${why:-idle}"; else echo "status unknown, not busy: it would go ahead as for an idle pane"; fi))"; fi
    if [ "$RL" = 1 ]; then
        echo "  rename '$OLD' to '$NEW' on $RL_HUB's page, in place (stackshot: post project-agent-rename, label $SALA_RENAME_SENDER): the entry keeps its line, place and side; stackshot refuses if '$NEW' is listed or '$OLD' is not"
    fi
    if [ "$SDL" = 1 ]; then
        echo "  rename: lists '$NEW' on $RL_HUB (front, line: $RL_LINE) and ends the side record (stackshot: post project-agent, role $RL_ROLE, label $SALA_RENAME_LIST_SENDER: a pending agent in its record, the page's own line stays the page keeper's to add; stackshot refuses if the name is taken or does not start with the project's name)"
    fi
    if [ "$SD" = 1 ]; then
        sdtag=""; [ "$SDL" = 1 ] && sdtag=", the row tagged $RL_HUB / front"
        echo "  the side record of '$OLD' ends (moved to $SALA_SIDE_DIR/retired/, its registry row's side fields cleared$sdtag): '$NEW' is an ordinary session from then on, so the write-up (sala side done, the summary to $(side_val "$OLD" summary_to)) is no longer owed"
    fi
    echo "  tmux session, pane map${SALA_MASTER:+$([ "$OLD" = "$SALA_MASTER" ] && echo ", SALA_MASTER")}, open notes; then a heartbeat"
    exit 0
fi

# ── 0. NEW on its project's page: registered now that every refusal above has passed; it counts as listed from here on
if [ "$RL" = 1 ]; then
    rename_list_run "$OLD" "$NEW" || die "rename refused, nothing renamed: $RL_WHY"
    if [ "$RL_RESULT" = renamed ]; then echo "ℹ '$OLD' is now '$NEW' on $RL_HUB's page (stackshot, in place): $RL_DETAIL"
    else echo "ℹ '$NEW' was already listed on $RL_HUB's page in place of '$OLD' (stackshot: already renamed): taken as the retry of the rename sala started earlier ($RL_DETAIL)"; fi
fi

# ── 1. wait for a pane that can take a keystroke (not needed when the session is already called NEW)
# A status that cannot be read (no registry status for the pane) is UNKNOWN, not busy: the wait below used to run 2 h on
# it and give up. Unknown goes ahead as an idle pane would; the screen checks (a terminal-only prompt, unsent text) still hold, and a
# status that reads busy still waits as before.
blocked() {  # → reason, or nothing when the pane can take /rename now
    local why
    if status_known; then why=$(is_idle_reason "$cpid"); [ -n "$why" ] && { echo "$why"; return; }; fi
    pane_prompt "$pane" && { echo "a terminal-only prompt is showing"; return; }
    [ -n "$(pane_draft "$pane" "$cpid")" ] && { echo "unsent text is in its composer"; return; }
}
if [ "$SELF" = 0 ] && [ "$cur" != "$NEW" ]; then
    status_known || echo "ℹ '$OLD' reports no status (unknown, not busy): going ahead as for an idle pane; its screen is still checked for a prompt or unsent text"
    why=$(blocked); tries=0; limit=4; [ "$WORKER" = 1 ] && limit=120
    while [ -n "$why" ] && [ "$tries" -lt "$limit" ]; do sleep $([ "$WORKER" = 1 ] && echo 60 || echo 15); tries=$((tries+1)); why=$(blocked); done
    if [ -n "$why" ]; then
        if [ "$WORKER" = 1 ]; then
            sala_post "⚠️ *Rename of $OLD gave up*" "$OLD was never free to rename in 2 h: $why" "it keeps its name; ask again when it is idle"
            die "'$OLD' never became free in 2 h: $why"
        fi
        setsid "$SALA_BIN" rename "$OLD" "$NEW" --retry-worker </dev/null >>"$SALA_LOG_DIR/salamander-rename.log" 2>&1 &
        echo "⏳ '$OLD' can't take a rename now ($why); retrying every minute for 2 h in the background — the result is posted"
        exit 0
    fi
fi

# ── 1b. a side session becoming an agent: NEW listed on its project now, after every check and the wait above (a busy pane's
# retry worker runs this again, and stackshot answers the repeat "as it stands"); a refusal stops the rename here, nothing typed or renamed
if [ "$SDL" = 1 ]; then
    rename_side_run "$NEW" || die "rename refused, nothing renamed: $RL_WHY"
    echo "ℹ '$NEW' is listed on $RL_HUB as a front agent (role $RL_ROLE, line: $RL_LINE): pending in stackshot's project record; its line on the page is the page keeper's to add"
fi

# ── 2. the Claude session's name
if [ "$cur" != "$NEW" ]; then
    if [ "$SELF" = 1 ]; then
        echo "ℹ '$OLD' is this pane, and a direct run in it can't type into itself: /rename $NEW is not typed (a queued \`sala op rename $OLD $NEW\` types it from outside once the pane is idle); carrying on with sala's records"
    else
        tui_send "$pane" "/rename $NEW" || die "'$OLD' did not take /rename — nothing changed"
        for i in 1 2 3 4 5 6; do sleep 2; cur=$(registry_field "$cpid" name); [ "$cur" = "$NEW" ] && break; done
        if [ "$cur" != "$NEW" ]; then tui_send "$pane" "/rename $NEW" || true; sleep 5; cur=$(registry_field "$cpid" name); fi
        [ "$cur" = "$NEW" ] || die "'$OLD' still reports the name '${cur:-unset}' after /rename $NEW — nothing else changed"
    fi
fi

# ── 3. sala's records
tmux rename-session -t "=$OLD" "$NEW" || die "tmux would not rename '$OLD' (the session name is '$cur' now) — rename the tmux session by hand"
# the map row: an honored rename (the map is a ledger — common.sh); a session the map lacks was refused above
rcwd=$(registry_field "$cpid" cwd); [ -n "$rcwd" ] && [ "$rcwd" != null ] || rcwd=$(tmux display -p -t "$pane" '#{pane_current_path}')
ledger_write rename "$OLD" "$NEW" "$uuid" "$rcwd" || echo "⚠ the pane map did not take the rename (see above)"
lane_rename "$OLD" "$NEW" || echo "⚠ the lane table did not take the rename: '$NEW' launches on the default lane until \`sala lane <lane> $NEW\` (common.sh, lanes)"   # its lane row follows
model_rename "$OLD" "$NEW" || echo "⚠ the model table did not take the rename: '$NEW' relaunches on its transcript's model until \`sala model $NEW <model>\` (common.sh, models)"   # its model row follows
if [ "$SD" = 1 ]; then   # the side record ends (above): from here on the session is an ordinary one, and the write-up it owed is not owed
    rename_side_end "$OLD" "$NEW" "$([ "$SDL" = 1 ] && echo "$RL_HUB")" \
        && echo "ℹ '$OLD' is no longer a side session: its record moved to $SALA_SIDE_DIR/retired/, so 'sala side done' and the summary to the origin are no longer owed" \
        || echo "⚠ the side record of '$OLD' could not be moved to $SALA_SIDE_DIR/retired/: move it by hand (the session is renamed)"
fi
moved=""
if [ -n "${SALA_MASTER:-}" ] && [ "$OLD" = "$SALA_MASTER" ]; then "$SALA_BIN" master --set "$NEW" >/dev/null && moved=1; fi
NOTES="$SALA_LOG_DIR/salamander-notes.tsv"
if [ -s "$NOTES" ]; then
    ( flock -w 30 9 || exit 1
      tmp=$(mktemp "${TMPDIR:-/tmp}/sala-notes.XXXXXX") || exit 1; trap 'rm -f "$tmp"' EXIT   # the subshell's own trap: a failed awk or mv, or a stop, left a bare `tmp.XXXXXXXXXX`
      awk -F'\t' -v u="$uuid" -v n="$NEW" 'BEGIN{OFS="\t"} $3==u {$2=n} {print}' "$NOTES" > "$tmp" && mv -f "$tmp" "$NOTES"
    ) 9>"$NOTES.lock" || echo "⚠ the note store was locked; open notes keep the label '$OLD' (they still reach the conversation)"
fi
"$SALA_BIN" snapshot --now >/dev/null 2>&1 || true

# ── 4. the hand-off record + the fleet state now
python3 -c 'import json,sys,time; print(json.dumps({"uuid":sys.argv[1],"from":sys.argv[2],"to":sys.argv[3],"at":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime()),"bridge":sys.argv[4]}))' \
    "$uuid" "$OLD" "$NEW" "$bridge" >> "$SALA_LOG_DIR/salamander-renames.jsonl"
"$SALA_BIN" heartbeat >/dev/null 2>&1 || echo "⚠ the heartbeat failed; the next 5-minute sweep publishes the new name"

# ── verify
ok=1; nb=$(registry_field "$cpid" bridgeSessionId); [ "$nb" = null ] && nb=""
tmux has-session -t "=$NEW" 2>/dev/null || { ok=0; echo "⚠ no tmux session '$NEW' after the rename"; }
[ "$(sidecar_uuid_for_session "$NEW")" = "$uuid" ] || { ok=0; echo "⚠ the pane map does not bind '$NEW' to its conversation"; }
[ "$nb" = "$bridge" ] || echo "⚠ the claude.ai link changed (${bridge:-none} → ${nb:-none})"
fs=$(python3 -c 'import json,sys,glob,os
for f in glob.glob(os.path.join(os.path.expanduser(sys.argv[2]), "*", "sessions.json")):
    try: d=json.load(open(f))
    except Exception: continue
    if sys.argv[1] in d: print(d[sys.argv[1]].get("name","")); break' "$uuid" "${SALA_HEARTBEAT_STATE_DIR:-/nonexistent}" 2>/dev/null)
[ -z "$fs" ] || [ "$fs" = "$NEW" ] || [ "$cur" != "$NEW" ] || echo "⚠ the fleet state still shows '$fs'"
[ "$SELF" = 1 ] && [ "$cur" != "$NEW" ] && ok=0
# the session's link under its new name: session_url (common.sh, SESSION LINKS) gives the same link the heartbeat publishes for it, the sala-web link on the
# box sala-web runs on, the claude.ai one where no template is in force
url=$(session_url "$NEW" "$bridge")
msg="'$OLD' is now '$NEW'${moved:+ (still the master)}${url:+ · $url}"
if [ "$ok" = 1 ]; then echo "✅ $msg"
elif [ "$SELF" = 1 ] && [ "$cur" != "$NEW" ]; then echo "✅ sala's side done: $msg — the Claude session itself is still '${cur:-unset}' until /rename $NEW is typed in this pane"
else echo "⚠ $msg, with the warnings above"; fi
[ "$WORKER" = 1 ] && sala_post "✏️ *Renamed $OLD to $NEW*" "${moved:+still the master; }same conversation and claude.ai link"
exit 0
