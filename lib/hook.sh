# lib/hook.sh — Claude Code settings hooks that give sala's busy check an exact answer, and a waiting session word of the
# relaunch.
#
# THE USAGE: `hook` with no or an unknown verb prints from its `salamander hook stop` line through the `hook stamp` line, so keep it contiguous.
#   salamander hook stop        Stop hook (settings.json "Stop", matcher "*"): record what the turn that just ended left in
#                               flight — the hook input's background_tasks (shell, subagent, monitor, workflow, MCP task) and
#                               session_crons — as $SALA_BUSY_DIR/<session id>; is_idle_reason reads it in place of its guesses
#   salamander hook post-tool   PostToolUse hook (matcher "*"): when a relaunch sala started waits for this session (a flag
#                               under $SALA_WAITING_DIR, raised by a recycle's retry worker or the reboot drain), tell it
#                               once, as hookSpecificOutput.additionalContext — the relaunch_text line (common.sh); and the sala
#                               notices not shown to this session yet (`sala notice`, lib/notice.sh), in the same block
#   salamander hook prompt      UserPromptSubmit hook (matcher none; "Telling every session something" in the README): the notices
#                               not shown to this session yet, as additionalContext, at its next prompt; nothing else
#   salamander hook pre-tool    PreToolUse hook (matcher "Bash"): deny a command that would relaunch or update the fleet
#                               outside sala — reboot, a CLI update, tmux kill-* on the fleet's server or a window/pane put into another session, kill/pkill of a claude
#                               process — with the fix (`sala cue`) in the reason; the master's pane is exempt (lib/guard.py)
#   salamander hook notify [--dry-run]   Notification hook (matcher "permission_prompt|elicitation_dialog|elicitation_url_dialog"):
#                               the instant alert for a pane stopped on a dialog, through the stuck watch's path and
#                               state, so its 90 s post does not repeat it (lib/stuck.sh sq_instant)
#   salamander hook ask         PreToolUse hook (matcher "AskUserQuestion", for background `claude -p` runs with SALA_DEFER_QUESTIONS=1):
#                               defer the call, park the question, answer it on resume (lib/question.sh, lib/question.py)
#   salamander hook session-start   SessionStart hook (matcher "*", docs/session-registry.md): record a fresh start of
#                               this pane's session in the registry: source clear → why clear, resume → resume, startup → start,
#                               compact → nothing. The row is SALA_SESSION_ID (spawn puts it in the pane), else the pane's tmux
#                               session name. Exit 0 always, prints nothing (a SessionStart hook's stdout is read as context) — except
#                               for ONE case: source clear in a live BACK-role row prints one additionalContext line that
#                               names the agent and its project and sends it to its mandate (below); SALA_CLEAR_CONTEXT=off prints nothing
#   salamander hook subagent-stop   SubagentStop hook (matcher "*"): once a subagent has handed back, SIGTERM the background
#                               shells it started and left running under the pane's claude and every process those shells started
#                               (children in groups and sessions of their own too), then any process of the user whose stdout / stderr is that
#                               very task output file, even one whose parent died (SIGKILL for what outlives 0.3 s), each logged (lib/holders.py);
#                               exit 0 always, prints nothing; SALA_SUBAGENT_CLEANUP=off disables it
#   salamander hook permission-request   PermissionRequest hook (matcher "*"): approve a permission prompt at once, and print
#                               nothing (the dialog stays, so a person sees it and the instant alert D fires) for a question to a person
#                               (AskUserQuestion, ExitPlanMode), the permission and instruction surface (settings, CLAUDE.md, the rulebook,
#                               hooks, .mcp.json), credentials, plan mode, and input that is not understood (lib/permissions.py holds the
#                               table, docs/permission-hook.md the reasons); exit 0 always; SALA_PERMISSION_APPROVE=off leaves every prompt
#   salamander hook stamp …     internal: the detached waiter `stop` leaves behind, which stamps the record with the idle flip
#
# THE INPUT (verified against https://code.claude.com/docs/en/hooks and the CLI binary): Stop carries
# `background_tasks`, one object per task the CLI's task registry has in flight (running or pending, backgrounded):
# {id, type: shell | subagent | monitor | workflow | … (a friendly label, else the raw kind), status, description, and by
# type: command (shell), agent_type (subagent), server + tool (monitor, MCP task), name (workflow)}; and `session_crons`
# ({id, schedule, recurring, prompt}: CronCreate, ScheduleWakeup, /loop). Both are present when the registry is reachable
# and EMPTY when nothing is in flight. A payload without `background_tasks` (an older CLI, a renamed field) gets NO record,
# because no record is the one safe answer (the guesses apply). Every task counts as in flight — the CLI filtered already —
# and a cron does not: a job never holds a relaunch back (`claude --resume` re-arms it). Recorded anyway.
# One task does not either: an artifact watch, the one Claude Code arms by itself on publish or one armed on request,
# whatever its label. It is recorded as it comes; busy_state leaves it out when it reads the record (common.sh, THE
# ARTIFACT WATCH, which holds the wording and the labels).
#
# THE FLIP, measured on 2.1.294 with a throwaway `claude -p`: the hook runs BEFORE the registry row flips to idle. At hook
# time the row still says busy, stamped at the turn's start; it flips once every Stop hook has returned (0.2 s later with one
# fast hook, up to a minute behind the slowest). So `stop` writes the record with the stamp it saw and leaves a detached
# `stamp` waiter polling the row (every 0.25 s, 2 min at most) that adds flip=<the idle row's statusUpdatedAt>.
# is_idle_reason trusts a record only while that flip IS the row's current stamp (busy_state, common.sh): a turn that ended
# since without this hook (an interrupted one) moves the stamp, and the record falls back to the guesses — never a stale
# "idle". A row already idle at hook time (a CLI that flips first) is stamped at once.
#
# READY AT ONCE: a record with nothing in flight, for a pane a relaunch waits for (the flag), is the session saying
# `sala ready`: the waiter wakes the retry worker the moment the flip is stamped (ready_wake, SIGUSR1), so the relaunch
# follows after the 10 s settle instead of at the worker's next tick. The reboot drain polls every 10 s and needs no wake.
#
# COST: `post-tool` runs on every tool call of every session, so until a flag is up it is bash, one glob test and one `-s` test
# (notices.tsv), exit — no common.sh, no stdin read, no fork beyond the dispatcher's readlink. While a notice is up it reads the first
# 512 bytes of stdin (the shell's own read) for the session id and compares the session's notices-seen file with notices.tsv by mtime
# (`-nt`): still no process; only a session that has not looked since the notices last changed starts one python (lib/notice.py deliver). `stop` runs at every turn end: one python for the JSON
# and one detached waiter; it never blocks or fails the turn (exit 0 always, nothing on stdout). Linux and macOS alike:
# bash and python3; setsid where it exists, nohup alone where it does not.
#
# THE YOUR MOVE ROW: `post-tool` and `stop` are also the first thing a session does after a terminal question is
# answered, so each calls _row_check: when stuck.state holds a "Your move" row for THIS pane (a `.pane=<TMUX_PANE>` line, read by
# the shell's own `read`: no fork for any other pane), a detached subshell closes it once the pane shows no question any more
# (lib/stuck.sh sq_row_hook). A session with no row pays one `-s` test and one read of a file of a few lines.
_row_check() {
    [ -n "${TMUX_PANE:-}" ] || return 0
    local _f="${XDG_STATE_HOME:-$HOME/.local/state}/salamander/stuck.state" _st=""
    [ -s "$_f" ] || return 0
    IFS= read -r -d '' _st < "$_f" 2>/dev/null || :
    [[ $_st == *".pane=$TMUX_PANE"$'\n'* ]] || return 0
    ( . "$SALA_ROOT/lib/common.sh" && . "$SALA_ROOT/lib/stuck.sh" && ( flock -w 10 8 || exit 0; sq_row_hook "$TMUX_PANE" ) 8>>"$SQ_STATE.lock" ) >/dev/null 2>&1 </dev/null &
    disown 2>/dev/null || :
    return 0
}

case "${1:-}" in
    pre-tool)
        # runs before every Bash call of every session: a command naming none of the guarded words costs one cat and a
        # regex, no python. On a word, guard.py decides (lib/guard.py has the rules); any failure there allows (fail open).
        [ -t 0 ] && { echo "salamander hook pre-tool reads the PreToolUse hook input on stdin (a settings.json hook)" >&2; exit 2; }
        _in=$(cat) || exit 0
        _re='reboot|shutdown|kexec|kill|telinit|init[^[:alnum:]_]|update|upgrade|install|claude-code|tmux'
        [[ $_in =~ $_re ]] || exit 0
        _cfg="${SALA_CONFIG:-$HOME/.config/salamander/config}"
        _out=$( SALA_MASTER=""; [ -r "$_cfg" ] && . "$_cfg" >/dev/null 2>&1; [ -n "${SALA_TMUX_SOCKET:-}" ] && export SALA_TMUX_SOCKET; SALA_OWNER_NAME=$(printf '%s' "${SALA_OWNER_NAME:-}" | tr -cd "[:alnum:] ._'-"); [ -n "$SALA_OWNER_NAME" ] && export SALA_OWNER_NAME   # guard.py names the owner in its denies (same cleaning as common.sh; empty = its default)
                printf '%s' "$_in" | python3 -I -S "$SALA_ROOT/lib/guard.py" "${SALA_MASTER:-}" 2>/dev/null ) || exit 0
        [ "${_out:0:1}" = "{" ] && printf '%s\n' "$_out"
        exit 0 ;;
    notify)
        # the Notification hook (Thu Oct 22nd 2026): Claude Code raises permission_prompt (and the elicitation
        # types) once a dialog has waited about 6 s with no keystroke. sala alerts at once, once per question, through the stuck
        # watch's own path and state (lib/stuck.sh sq_instant): the 90 s post then finds the question posted and stays silent.
        # Never blocks, never fails the turn: exit 0 whatever happens, nothing on stdout (but --dry-run's print).
        [ -t 0 ] && { echo "salamander hook notify reads the Notification hook input on stdin (a settings.json hook)" >&2; exit 2; }
        _in=$(cat) || exit 0
        _dry=""; [ "${2:-}" = --dry-run ] && _dry=1
        _re='"notification_type"[[:space:]]*:[[:space:]]*"([^"]+)"'; _ty=""; [[ $_in =~ $_re ]] && _ty="${BASH_REMATCH[1]}"
        _re='"message"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'; _msg=""; [[ $_in =~ $_re ]] && _msg="${BASH_REMATCH[1]}"
        [ -n "$_ty" ] || case "$_msg" in *ermission*) _ty=permission_prompt;; esac   # a CLI that sends no type: its permission words
        [ -n "${TMUX_PANE:-}" ] || exit 0                               # a claude with no pane (claude -p, a unit) shows no dialog
        . "$SALA_ROOT/lib/common.sh"
        case "${SALA_STUCK_INSTANT:-on}" in 0|off|no|false) exit 0;; esac
        case " ${SALA_STUCK_INSTANT_TYPES:-permission_prompt elicitation_dialog elicitation_url_dialog} " in *" $_ty "*) ;; *) exit 0;; esac
        . "$SALA_ROOT/lib/stuck.sh"
        sq_on || exit 0
        _row=$(sq_panes | awk -F'|' -v p="$TMUX_PANE" '$2==p {print; exit}'); [ -n "$_row" ] || exit 0
        IFS='|' read -r _sess _pane _pid <<< "$_row"
        [ -n "$_sess" ] && [ "$_sess" != "${SALA_RC_SESSION:-}" ] || exit 0
        mkdir -p "$SALA_STATE_DIR" 2>/dev/null; touch "$SQ_STATE" 2>/dev/null
        SQ_SEND_TIMEOUT="${SALA_STUCK_INSTANT_TIMEOUT:-15}"
        ( flock -w 10 8 || exit 0; sq_instant "$_sess" "$_pane" "$_pid" "$_ty" "$_msg" "$_dry" ) 8>>"$SQ_STATE.lock" || true
        exit 0 ;;
    ask)
        # PreToolUse for a BACKGROUND `claude -p` run (lib/question.sh): park an AskUserQuestion instead of
        # leaving the run to hang or guess. A run without SALA_DEFER_QUESTIONS=1 is untouched: one test, exit.
        [ "${SALA_DEFER_QUESTIONS:-}" = 1 ] || exit 0
        [ -t 0 ] && { echo "salamander hook ask reads the PreToolUse hook input on stdin (a settings.json hook)" >&2; exit 2; }
        . "$SALA_ROOT/lib/common.sh"
        SALA_STATE_DIR="$SALA_STATE_DIR" SALA_DEFER_TOOLS="${SALA_DEFER_TOOLS:-AskUserQuestion}" python3 -I -S "$SALA_ROOT/lib/question.py" hook 2>/dev/null || true
        exit 0 ;;
    post-tool|prompt)
        # post-tool (PostToolUse, every tool call of every session) and prompt (UserPromptSubmit) carry two things to a session: the line a
        # waiting relaunch asks for (post-tool only; flag files under waiting/) and the sala notices nobody has shown it yet (`sala notice`,
        # lib/notice.sh). Both are flags in the state folder, so the common case is bash builtins only: a glob test and one `-s` test, exit.
        _ev=PostToolUse; _wait=""
        if [ "$1" = prompt ]; then _ev=UserPromptSubmit; else _row_check; fi
        _sd="${XDG_STATE_HOME:-$HOME/.local/state}/salamander"; _wd="$_sd/waiting"; _nf="$_sd/notices.tsv"
        if [ "$_ev" = PostToolUse ]; then set -- "$_wd"/*; [ -e "$1" ] && _wait=1; fi
        [ -n "$_wait" ] || [ -s "$_nf" ] || exit 0                      # nothing waits for anyone, no notice is up: the common case, done
        [ -t 0 ] && { echo "salamander hook $([ "$_ev" = PostToolUse ] && echo post-tool || echo prompt) reads the $_ev hook input on stdin (a settings.json hook)" >&2; exit 2; }
        IFS= read -r -N 512 _in || true                                # session_id leads the JSON; tool_response can run to megabytes: never read past what is needed
        _re='"session_id"[[:space:]]*:[[:space:]]*"([^"]+)"'
        if ! [[ $_in =~ $_re ]]; then IFS= read -r -N 3584 _more || true; _in="$_in$_more"; [[ $_in =~ $_re ]] || exit 0; fi
        _sid="${BASH_REMATCH[1]}"
        _wtext=""
        if [ -n "$_wait" ] && [ -e "$_wd/$_sid" ] && [ ! -e "$_wd/$_sid.told" ]; then   # a relaunch waits for this session and has not told it yet
            . "$SALA_ROOT/lib/common.sh"
            if waiting_told "$_sid"; then                              # two tool calls at once: the first tells
                _what=$(waiting_what "$_sid"); [ -n "$_what" ] || _what=recycle
                _wtext=$(relaunch_text "$_what" "$(own_claude_pid 2>/dev/null)")
            fi
        fi
        _due=""; _skip=""
        _re='^[0-9A-Za-z_-]{8,64}$'
        if [ -s "$_nf" ] && [[ $_sid =~ $_re ]] && [ "$_nf" -nt "$_sd/notices-seen/$_sid" ]; then   # notices changed since this session last looked: once per session per change
            _due=1
            if [ "$_ev" = PostToolUse ]; then                          # a tool call inside a subagent carries agent_id: the notice goes to the session's own turn, not into the subagent
                IFS= read -r -N 8192 _more || true
                _re='"agent_id"[[:space:]]*:'
                [[ $_in$_more =~ $_re ]] && { _due=""; _skip=1; }
            fi
        fi
        [ -n "$_due" ] || [ -n "$_wtext" ] || exit 0
        _t=(); command -v timeout >/dev/null 2>&1 && _t=(timeout 10)
        SALA_STATE_DIR="$_sd" SALA_NOTICE_PRE="$_wtext" SALA_NOTICE_SKIP="$_skip" ${_t[@]+"${_t[@]}"} python3 -I -S "$SALA_ROOT/lib/notice.py" deliver "$_sid" "$_ev" 2>/dev/null || true
        exit 0 ;;
    session-start)
        # SessionStart (phase 2): the explicit signal that a pane's session began a conversation. The hook input carries
        # session_id (the conversation, a claude session id), source (startup | resume | clear | compact) and cwd. It must never fail
        # a start and never print: a SessionStart hook's stdout is added to the model's context, so all of it goes to /dev/null and
        # the exit status is 0 on every path. Nothing runs for compact (the conversation is the same) or for a headless `claude -p`
        # (CLAUDE_CODE_ENTRYPOINT=sdk-cli: a run a session starts inherits SALA_SESSION_ID, and is not the session).
        [ -t 0 ] && { echo "salamander hook session-start reads the SessionStart hook input on stdin (a settings.json hook)" >&2; exit 0; }
        exec 3>&1 >/dev/null 2>&1                 # fd 3 is the hook's real stdout: only the cleared background agent's context line goes there (below)
        [ "${CLAUDE_CODE_ENTRYPOINT:-}" = sdk-cli ] && exit 0
        _in=$(cat) || exit 0
        IFS= read -r -d '' _py <<'PY' || true   # the program in a variable: python's stdin stays the hook's payload
import json, re, sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
if not isinstance(d, dict): sys.exit(0)
s, src = d.get("session_id"), d.get("source")
if isinstance(s, str) and isinstance(src, str) and re.fullmatch(r"[0-9A-Za-z_-]{8,64}", s): print(s + "\t" + src)
PY
        _out=$(printf '%s' "$_in" | python3 -I -S -c "$_py" 2>/dev/null) || exit 0
        IFS=$'\t' read -r _sid _src <<< "$_out"
        case "${_src:-}" in clear) _why=clear ;; resume) _why=resume ;; startup) _why=start ;; *) exit 0 ;; esac
        [ -n "${_sid:-}" ] || exit 0
        _target="${SALA_SESSION_ID:-}"
        if [ -z "$_target" ]; then            # a pane spawn did not make (adopted, restored) or a registry that was off at its spawn: the row of its tmux session name
            [ -n "${TMUX_PANE:-}" ] || exit 0
            . "$SALA_ROOT/lib/common.sh"
            on_fleet_server || exit 0
            _target=$(tmux display -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null) || exit 0
            [ -n "$_target" ] && [ "$_target" != "${SALA_RC_SESSION:-}" ] || exit 0
        fi
        _t=(); command -v timeout >/dev/null 2>&1 && _t=(timeout 30)
        ${_t[@]+"${_t[@]}"} "$SALA_BIN" sessions record "$_target" --transcript "$_sid" --why "$_why" </dev/null 3>&- || true
        # A CLEARED BACKGROUND AGENT (lib/wrapup.sh clears an idle one when SALA_IDLE_WRAPUP=on; off by default): the conversation it was started with, whose first
        # message sent it to its mandate, is gone. The CLAUDE.md of its directory (the background brief) and the keeper hook's Current
        # state still reach it, but nothing tells it WHO it is or where its mandate is written. One line of context does: its name, its
        # project's page, and where the mandate lives (the agents map of that page, under `background:`). Only for source clear and a
        # live row whose role is back; every other start prints nothing, as before.
        if [ "${_src:-}" = clear ] && [ "${SALA_CLEAR_CONTEXT:-on}" != off ]; then
            IFS= read -r -d '' _py <<'PY' || true
import json, sys
try: r = json.load(sys.stdin)
except Exception: sys.exit(0)
if not isinstance(r, dict) or r.get("role") != "back" or r.get("side") or r.get("state") != "live": sys.exit(0)
name, proj = r.get("name") or "", r.get("project") or ""
if not name: sys.exit(0)
page = ("the gbrain page %s" % proj) if proj else "its project's gbrain page"
text = ("[sala] Your conversation was just cleared (sala clears a background agent that has been idle for about an hour, after asking it to write down "
        "what only it knew), so nothing of the earlier conversation is here. You are %s, a background agent of %s. Your mandate is your line "
        "under `background:` in the agents map of that page; your rules are the background brief in your CLAUDE.md; the project's Current state "
        "(shown to you above when you keep a page) and the board items you move are the rest. Read them before you take a job." % (name, page))
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": text}}, ensure_ascii=False))
PY
            _row=$(${_t[@]+"${_t[@]}"} "$SALA_BIN" sessions resolve "$_target" --live --json </dev/null 3>&- 2>/dev/null) || _row=""
            [ -n "$_row" ] && printf '%s' "$_row" | python3 -I -S -c "$_py" >&3
        fi
        exit 0 ;;
    stop)
        [ -t 0 ] && { echo "salamander hook stop reads the Stop hook input on stdin (a settings.json hook)" >&2; exit 2; }
        _row_check
        . "$SALA_ROOT/lib/common.sh"
        IFS= read -r -d '' _py <<'PY' || true   # the program in a variable: python's stdin stays the hook's payload
import json, os, sys, glob, time, random
bd, rd = sys.argv[1], sys.argv[2]
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
if not isinstance(d, dict): sys.exit(0)
sid = d.get("session_id")
if not isinstance(sid, str) or not sid or "/" in sid or sid.startswith("."): sys.exit(0)
tasks = d.get("background_tasks")
if not isinstance(tasks, list): sys.exit(0)          # no field (an older CLI, a renamed one): no record — the safe answer
crons = d.get("session_crons"); crons = crons if isinstance(crons, list) else []
seen = status = regf = ""                            # the registry row now: stamped at the turn's start; the flip comes after the hooks
for f in glob.glob(os.path.join(rd, "*.json")):
    try:
        with open(f) as fh: r = json.load(fh)
    except Exception: continue
    if isinstance(r, dict) and r.get("sessionId") == sid:
        regf, seen, status = f, str(r.get("statusUpdatedAt") or ""), str(r.get("status") or ""); break
def one(s, n=200):
    s = " ".join(str(s).split()); return s if len(s) <= n else s[:n] + "…"
lines = []
for t in tasks:
    if not isinstance(t, dict): t = {"description": t}
    extra = t.get("command") or t.get("agent_type") or (t.get("server") and "%s/%s" % (t.get("server"), t.get("tool"))) or t.get("name") or ""
    lines.append("task=%s %s: %s%s" % (one(t.get("type", "?"), 30), one(t.get("status", "?"), 20), one(t.get("description", "")), " (%s)" % one(extra, 120) if extra else ""))
for c in crons:
    if isinstance(c, dict): lines.append("cron=%s %s: %s" % (one(c.get("schedule", "?"), 40), "recurring" if c.get("recurring") else "once", one(c.get("prompt", ""))))
ident = "%d-%d" % (os.getpid(), random.randrange(1 << 30))
flip = seen if status == "idle" and seen else ""
body = ["id=%s" % ident, "epoch=%d" % int(time.time()), "seen=%s" % seen, "seen_status=%s" % status] + (["flip=%s" % flip] if flip else []) \
     + ["tasks=%d" % len(tasks), "crons=%d" % len(crons)] + lines
os.makedirs(bd, exist_ok=True)
tmp = os.path.join(bd, ".%s.%s" % (sid, ident))
with open(tmp, "w") as fh: fh.write("\n".join(body) + "\n")
os.replace(tmp, os.path.join(bd, sid))
print("\t".join([sid, str(len(tasks)), flip or "-", regf or "-", ident]))   # "-" for an empty field: `read` folds adjacent tabs
PY
        _out=$(python3 -c "$_py" "$SALA_BUSY_DIR" "$SALA_REG_DIR" 2>/dev/null) || exit 0
        [ -n "$_out" ] || exit 0
        IFS=$'\t' read -r _sid _n _flip _regf _id <<< "$_out"; [ "$_flip" != - ] || _flip=""; [ "$_regf" != - ] || _regf=""
        if [ -n "$_flip" ]; then                                        # the row was idle already: the record is complete
            [ "$_n" = 0 ] && waiting_for "$_sid" && ready_wake
        elif [ -n "$_regf" ]; then                                      # the flip follows the hooks: a detached waiter stamps it
            # stdio closed: the CLI waits on the hook's pipes, and a waiter holding them would hold the turn (as feedback stop)
            if command -v setsid >/dev/null 2>&1; then setsid nohup "$SALA_BIN" hook stamp "$_sid" "$_id" "$_regf" "$_n" >/dev/null 2>&1 </dev/null &
            else nohup "$SALA_BIN" hook stamp "$_sid" "$_id" "$_regf" "$_n" >/dev/null 2>&1 </dev/null & fi
        fi
        exit 0 ;;
    subagent-stop)
        # SubagentStop: a subagent that has handed back and left a background shell running keeps
        # its parent's pane held (registry 'shell') for as long as the shell runs, and the shell is in no task list of the
        # parent's own: an until-loop once held a session's relaunch for hours. The hook stops the shells THAT
        # subagent started, and the processes those shells started (lib/holders.py has the proof and the rules), logs each to $SALA_LOG_DIR/salamander-subagent.log, and
        # never blocks, prints or fails: exit 0 on every path. SALA_SUBAGENT_CLEANUP=off turns it off.
        [ -t 0 ] && { echo "salamander hook subagent-stop reads the SubagentStop hook input on stdin (a settings.json hook)" >&2; exit 2; }
        case "${SALA_SUBAGENT_CLEANUP:-on}" in 0|off|no|false) exit 0;; esac
        _in=""; IFS= read -r -d '' _in || :                              # all of stdin, by the shell (no cat; a NUL byte ends it, the input is JSON text)
        _re='"type"[[:space:]]*:[[:space:]]*"shell"'
        [[ $_in =~ $_re ]] || exit 0                                    # no shell in the parent's task list: nothing to stop, the common case
        . "$SALA_ROOT/lib/common.sh"
        _t=(); command -v timeout >/dev/null 2>&1 && _t=(timeout 15)
        printf '%s' "$_in" 2>/dev/null | SALA_REG_DIR="$SALA_REG_DIR" SALA_SCRUB_PY="$SALA_SCRUB_PY" SALA_SUBAGENT_LOG="$SALA_LOG_DIR/salamander-subagent.log" \
            ${_t[@]+"${_t[@]}"} python3 -I -S "$SALA_ROOT/lib/holders.py" subagent-stop >/dev/null 2>&1 || true
        exit 0 ;;
    permission-request)
        # PermissionRequest (auto-approve comes first, the dialog is the fallback): fires at once when a
        # dialog is about to show. An approval is the one line lib/permissions.py prints; everything it leaves (and every error) prints
        # nothing and exits 0, so the normal dialog shows and `hook notify` (D) alerts it. One python start, only on a prompt.
        [ -t 0 ] && { echo "salamander hook permission-request reads the PermissionRequest hook input on stdin (a settings.json hook)" >&2; exit 2; }
        . "$SALA_ROOT/lib/common.sh" >/dev/null 2>&1 || true
        SALA_PERMISSION_LOG="${SALA_LOG_DIR:-$HOME/.claude}/salamander-permission.log" SALA_SCRUB_PY="${SALA_SCRUB_PY:-}" \
            python3 -I -S "$SALA_ROOT/lib/permissions.py" 2>/dev/null || true
        exit 0 ;;
    stamp)
        . "$SALA_ROOT/lib/common.sh"
        _sid="${2:-}"; _id="${3:-}"; _regf="${4:-}"; _n="${5:-1}"
        [ -n "$_sid" ] && [ -n "$_id" ] && [ -n "$_regf" ] || exit 0
        _re_idle='"status"[[:space:]]*:[[:space:]]*"idle"'; _re_stamp='"statusUpdatedAt"[[:space:]]*:[[:space:]]*([0-9]+)'
        for ((_i = 0; _i < 480; _i++)); do
            [ -r "$_regf" ] || exit 0                                   # the process is gone (an /exit right after the turn)
            _row=""; { IFS= read -r -d '' _row < "$_regf"; } 2>/dev/null || :   # (the shell's own read, and _nap: no cat and sleep per poll)
            if [[ $_row =~ $_re_idle ]] && [[ $_row =~ $_re_stamp ]]; then
                busy_stamp "$_sid" "$_id" "${BASH_REMATCH[1]}" || exit 0   # a newer record replaced ours: its own waiter stamps it
                [ "$_n" = 0 ] && waiting_for "$_sid" && ready_wake
                exit 0
            fi
            _nap 0.25
        done
        exit 0 ;;
    *) awk '/^#   salamander hook stop /{p=1} p{print} /^#   salamander hook stamp /{exit}' "$SALA_ROOT/lib/hook.sh" | sed 's/^# \{0,1\}//'; exit 2 ;;   # by pattern, not a line range
esac
