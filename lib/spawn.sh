# lib/spawn.sh — start a named tmux session running Claude Code, visible to Remote Control.
#
#   spawn [NAME] [--mandate FILE|TEXT [--no-confirm]] [--cwd DIR] [--lane L] [--model M] [--effort E] [--fork UUID] [--master] [--dry-run]
#   spawn NAME --project <page key> --role front|back [--mandate FILE|TEXT] [--lane L] [--model M] [--effort E] [--cwd DIR] [--dry-run]
#   spawn --suggest-name --project <page key> --role front|back [--prefix P] [--new]
#   spawn NAME --side (--fork-of AGENT | --project <page key> --item board#N) [--item board#N] [--agents A,B] [--mandate FILE|TEXT] [--lane L] [--model M] [--effort E] [--cwd DIR] [--dry-run]
#   spawn --suggest-name --side (--fork-of AGENT | --project <page key>)
#   spawn --list
#
# No NAME → throwaway `<prefix>-<YYYYMMDD>-<word>` (date in SALA_TZ); with --project, the suggested agent name (below). Model/
# effort unset → the session follows ~/.claude/settings.json. The name is applied with `/rename` typed into the pane (the CLI's
# own name flags do not reliably stick), then verified against the registry.
#
# THE MANDATE (Thu Oct 15th 2026; --brief FILE and --prompt TEXT are its older names, kept as aliases with the same
# behaviour): a readable FILE is read by the session itself — the orientation line "Read FILE in full …" is typed, and the
# session waits for a confirmation unless --no-confirm (a background agent never waits: --role back implies it); anything
# else is TEXT typed as the first message. --brief takes a file only, --prompt text only, --mandate decides by what it is
# given (a file that exists wins). A relative path is made absolute: the pane's shell starts in --cwd, not where spawn ran.
# The orientation line and a TEXT are MESSAGES: tui_send types them with `<!-- sala -->` in front (Mon Oct 12th 2026,
# the board's quote-origin check; common.sh, THE MESSAGE MARKER), so a transcript reader can tell them from the owner's.
#
# A PROJECT AGENT (--project <page key> --role front|back; both or neither): a session of a project, registered by its line
# on the hub page's `agents:` map — a front agent (the ones the owner talks to) a top-level entry, a background one under
# `background:`. Before the tmux session is made (common.sh, THE PROJECT
# SPAWN'S CHECKS; never fail-open, unlike a plain spawn's agent_unlisted):
#   · the name: lowercase letters, digits and dashes, at most SALA_AGENT_NAME_MAX (48) characters (sala's rule; stackshot's
#     is only that the name is a key of the page's agents map, and that the front entry ending in -main is the project's
#     main agent). `--suggest-name` prints a SUGGESTION, not a check, and NEVER a name that is taken (a tmux session, a live
#     claude, or an agent on any project's map in stackshot's project record). `<prefix>-main` only for a front agent of a
#     project that has no agent yet: the fresh project record lists the project with none, or `--new` says the project has no
#     page yet (the web form's new project, which no record can know), and `<prefix>-main` fits SALA_AGENT_NAME_MAX. Every
#     other name, and every name when the record is missing, stale (SALA_PROJECT_RECORD_MAX_AGE) or does not list the project,
#     is `<prefix>-<word>`: a word picked AT RANDOM from the list below (not in any fixed order), tried again on a collision,
#     then a number, the prefix cut to fit and never left ending in a dash; rc 1 and a message when none is free. A real
#     spawn with no NAME keeps the older rule: a front is `<prefix>-main` (the spawn's own checks then say whether it is on the
#     page's agents map: exit 3 if not), a back agent a free word. The prefix is, in this order: --prefix P when given (the
#     web form's: the project's own, or stackshot's `<scope>-<slug>` for a new one); the project record's own (its -main agent's
#     name without `-main`, else what all its agents' names share); else the convention `<scope>-<slug>`, the scope being
#     SALA_SCOPES' word that is the page's directory (work/<slug> → work-<slug>), else a slug that already leads with another
#     scope is the prefix as it is (projects/work-ir → work-ir), else the default scope (SALA_DEFAULT_SCOPE, else the first of
#     SALA_SCOPES) in front of the slug (projects/ir → home-ir when home is the default);
#     with no SALA_SCOPES the slug alone. The answer for a page the record does not know.
#   · THE PROJECT RECORD FIRST (common.sh, THE PROJECT RECORD; docs/stackshot-contracts.md, interface 20):
#     stackshot's ~/.local/state/stackshot/projects.json lists each project's agents with `front` true/false. When it is fresh
#     and has the project, it answers both checks below: the name on the map and `front` agreeing with --role → listed (an
#     agent registered through `client.py post project-agent` with its page line still owed counts); the name absent → exit 3
#     as below; the other role → exit 1. Only when the record cannot answer (missing, stale, unreadable, no such project) do
#     the two pages.py checks below run, with their own "cannot tell" refusal.
#   · the page exists (`pages.py resolve`): missing → exit 4 with `NO-PAGE: <key>` on stdout — a new project's page is made
#     by a session with gbrain (the project's -main or the board's main session), never here (nothing in sala writes to gbrain);
#   · the name is on THAT page's agents map (`pages.py agent-listed`, its `listed on <key>:` line): not → exit 3, the
#     refusal on stderr naming the register command and, on stdout, the marker line `REGISTER: <key>` followed by that
#     command (stackshot's `client.py post project-agent <key> <name> --role <part of the name after the project's name>
#     --front|--back --mandate "<first line>"`; an agent registered there is on the project's map and a page edit to the
#     map reaches no reader once a project has a record, so the page is never the thing to edit), so the web form can show
#     "not listed on the project yet" with the command; and the page's keeper is asked once (spawn_ask_keeper): one stackshot message to the page key
#     (`client.py message <key> …`, SALA_SPAWN_ASK_CMD; the tests stub it), at most once per name per SALA_SPAWN_ASK_EVERY,
#     and never when SALA_SPAWN_REGISTER is configured (registration is the hook's then). Both "cannot tell" answers (no
#     brain here, no pages.py, a timeout) refuse with exit 1 and say so. THE ONE COMMAND THAT NEEDS STACKSHOT:
#     `spawn --project` answers only through stackshot's project record or its pages.py and
#     the brain mirror (SALA_BRAIN_DIR) behind it, and stays fail-closed without them (SALA_AGENT_CHECK=off is the only bypass, for
#     every spawn). There is no abstraction over the check on purpose; one is built only when a box without stackshot has to
#     make project spawns. A plain spawn, a rename and a side session need none of it.
#   · a back agent needs a mandate (it reads it at its first prompt and nobody briefs it); a front agent's is optional.
#   · THE START DIRECTORY: the CLI loads the CLAUDE.md of the directory a session starts in, so a back agent started
#     in $HOME read the FRONT rules and never a background brief kept elsewhere. SALA_BACK_CWD (default: unset) names the
#     directory whose CLAUDE.md is the background brief; with no --cwd a back agent starts there. Unset, it starts in $HOME, the same as a
#     front agent. Set but naming a directory this box does not have, the spawn is refused (a typo or an unmounted checkout
#     must not quietly start the agent under the front rules). An explicit --cwd wins for both; a side session and a plain spawn
#     are unchanged. The pane map's cwd column records the directory, so `sala restore` recreates the session there; the dry
#     run's "cwd …" shows it.
#   · a name already live (a tmux session, or a running claude registered under it) is refused as for any spawn.
# --dry-run runs every check and prints the plan ("[dry-run] would spawn …"), makes nothing, records nothing, calls no
# hook; the operation queue runs it as the verb's plan (lib/op.sh, `sala op spawn`, the one path a web request takes).
# THE REGISTER HOOK (SALA_SPAWN_REGISTER): once a project agent's session is up and mapped, the configured command runs
# with the name, page key, role and mandate file path as its four arguments and as SALA_SPAWN_NAME, SALA_SPAWN_PROJECT,
# SALA_SPAWN_ROLE, SALA_SPAWN_MANDATE_FILE (empty for a text mandate or none), plus SALA_SPAWN_MANDATE_LINE (the first
# line, ≤70 characters), SALA_SPAWN_UUID (the conversation) and SALA_SPAWN_LANE; its output goes to salamander-spawn.log. A
# hook that fails or hangs (60 s) is one ⚠ line: it never fails or undoes the spawn. Unset (the default) it is a no-op that
# logs `spawn-register: no hook configured`: the page's line, written by the keeper, is the registration.
#
# A SIDE SESSION (quick side conversations; docs/side-sessions.md; common.sh, THE SIDE SESSIONS): a short-lived session
# started in one step, on no page's agents map (no project/role checks, no agent_unlisted), for the owner to talk to. Two starts:
#   · FORK (--fork-of AGENT): forked from that agent's live conversation (`--resume <its current uuid> --fork-session`, the --fork below,
#     found for you), started in the agent's directory (the conversation is found by it) unless --cwd says otherwise; named
#     <agent>-side-<word><nn> (the agent's name cut at a previous -side-, the whole name at most SALA_AGENT_NAME_MAX characters);
#     its write-up summary goes to the agent.
#   · DISCUSS (--project KEY --item board#N): a fresh session scoped to the item's project page, named <the project's usual agent
#     prefix>-side-<word><nn> (its -main agent in stackshot's project record, else the suggestion of --suggest-name); the page must
#     exist (cannot tell: said, not refused). Its write-up summary goes to the project's -main.
# The name is generated (--suggest-name prints one; NAME given must contain -side- and be an agent name). THE MANDATE is written for it to
# $SALA_STATE_DIR/mandates/side-<name>.md at run time (the dry run only says so): what the conversation is, the item (board#N and its
# link), the project page's Current state and the item to read, the involved agents (--agents A,B: the item's owner, needs and sessions,
# passed in by the caller) and `sala sessions transcript` to find THEIR transcripts, of which it reads only the excerpts it needs, and
# the end: `sala side done` before it ends, retire only on the owner's word. A --mandate FILE|TEXT is appended as the owner's own instructions.
# The orientation is typed as for any mandate file, waiting for a confirmation unless --no-confirm. Once the session is up, spawn writes
# its record, $SALA_STATE_DIR/side/<name>.side (kind, origin, project, item, agents, summary_to, started, uuid), and copies side=1,
# side_origin, side_item and side_at to the registry row. No quiet watch, no auto-retire, no cap: lib/retire.sh refuses it until
# `sala side done` (lib/side.sh) wrote the marker.
#
# --fork UUID ELEVATES a conversation (typically one minted by the Remote Control server) into
# this pane: `--resume UUID --fork-session` copies the history into a NEW session id and
# transcript, so the original is never shared with a second writer; archive the original after.
# --lane L launches on that lane in place of the default and records the row (common.sh, lanes), so every later relaunch
# keeps it; without it the session follows the default lane and nothing is recorded, as before. One exception: a background agent
# (--project … --role back) spawned while the back agents' lane rule has them off their home lane (SALA_BACK_LANE_RULE=on) takes the rule's lane.
# THE SESSION REGISTRY'S ID (phase 2): before the pane's claude starts, spawn makes (or finds) the registry row and puts its
# id in the pane's environment as SALA_SESSION_ID, so the session's SessionStart hook can name its row; a spawn that does not come
# up takes the row back (see the comment at tmux new-session below). SALA_SESSIONS=off: no id, no export.
# A THROWAWAY'S SPAWNER: a spawn with no --project, --side or --master, run by a Claude session, writes the
# caller's tmux session name onto the row as spawned_by (common.sh spawn_caller; docs/session-registry.md). `sala op retire NAME --from YOU` takes
# no words for exactly that row (lib/op.sh, op_own_retire_ok); a spawn from a plain shell, a human's pane or the queue records none.
# THE THROWAWAY TAG: the same spawn, whoever runs it, also writes throwaway=1 onto the row; any live session may
# then retire that row with no words, between turns. A spawn with a project, a role or a side flag never writes it (lib/op.sh, op_own_target_ok).
# The pane map gets the session's row on the way out (an honored add; the map is a ledger, see
# common.sh), so a crash before the next autosave can still map the pane to its conversation.

[ -x "$SALA_CLAUDE" ] || die "claude not found at $SALA_CLAUDE"

if [ "${1:-}" = "--list" ]; then
    printf '%-24s %-10s %s\n' NAME VERSION BRIDGE
    _claude_pids_r _cps || :
    for pid in $_cps; do
        f="$SALA_REG_DIR/$pid.json"; [ -r "$f" ] || continue
        is_rc_child "$pid" && continue
        python3 -c "
import json
d=json.load(open('$f'))
if d.get('tmux'): print('%-24s %-10s %s%s' % (d.get('name','?'), d.get('version','?'), d.get('bridgeSessionId') or '—', '  ⚠ parked → bg fork %s' % d['parkedJobId'][:8] if d.get('parkedJobId') else ''))" 2>/dev/null
    done | sort
    # tmux sessions whose claude exited/crashed: show them with the sidecar's conversation id
    tmux list-panes -a -F '#{session_name} #{pane_current_command} #{pane_pid}' 2>/dev/null | while read -r sess cmd ppid; do
        case "$cmd" in claude|node) continue ;; esac
        pgrep -x claude -P "$ppid" >/dev/null 2>&1 && continue
        [ "$sess" = "$SALA_RC_SESSION" ] && continue
        is_shell_session "$sess" && continue   # the web UI's shell drawer
        [ "$sess" = "0" ] && continue
        uuid=$(awk -F'\t' -v s="$sess" '$1==s {print $2; exit}' "$SALA_SIDECAR" 2>/dev/null)
        printf '%-24s %-10s %s\n' "$sess" "(shell)" "claude exited — revive: salamander revive --only $sess${uuid:+   (sidecar ${uuid:0:8}…)}"
    done | sort
    exit 0
fi

: "${SALA_SPAWN_ASK_CMD=${SALA_STACKSHOT_DIR:+python3 $SALA_STACKSHOT_DIR/client.py message}}"    # the stackshot message that asks a page's keeper for an unlisted name's line (unset: this default, none without SALA_STACKSHOT_DIR; set empty: never asked)
: "${SALA_SPAWN_ASK_EVERY:=3600}"                                       # seconds before the same name's keeper is asked again
SPAWN_LOG="$SALA_LOG_DIR/salamander-spawn.log"
spawn_log() { mkdir -p "$SALA_LOG_DIR" 2>/dev/null; echo "[$(date -Is)] spawn ${NAME:-?}: $*" >> "$SPAWN_LOG" 2>/dev/null || true; }

WORDS=(fox lark wren moss ember flint slate quill cairn drift glade tide vane reed birch
       heron otter sable thorn vale amber crest fern gorse haven ivy juniper kelp larch
       mica nettle onyx pike quartz rowan sedge topaz umber willow yarrow)
gen_name() {
    local d w i; d=$(cs_date +%Y%m%d)
    for ((i=0; i<40; i++)); do
        w=${WORDS[RANDOM % ${#WORDS[@]}]}
        tmux has-session -t "=$SALA_SPAWN_PREFIX-$d-$w" 2>/dev/null || { printf '%s-%s-%s\n' "$SALA_SPAWN_PREFIX" "$d" "$w"; return 0; }
    done
    printf '%s-%s-%s\n' "$SALA_SPAWN_PREFIX" "$d" "$$"
}
suggest_prefix() {  # <page key> → the conventional agent-name prefix (the header: a suggestion, not a check): <scope>-<slug>, the scopes being SALA_SCOPES
    local dir="${1%%/*}" slug s scope; local -a scopes; slug="${1#*/}"; slug="${slug%%/*}"
    read -ra scopes <<< "$SALA_SCOPES"   # split on blanks only: a glob in the setting stays a word
    scope="$SALA_DEFAULT_SCOPE"; [ -n "$scope" ] || scope="${scopes[0]:-}"   # the default scope, else the first
    for s in "${scopes[@]}"; do [ "$s" = "$dir" ] && { echo "$dir-$slug"; return 0; }; done   # the page's directory is a scope: named in it
    for s in "${scopes[@]}"; do [ "$s" != "$scope" ] && [[ "$slug" == "$s"-* ]] && { echo "$slug"; return 0; }; done   # a slug that leads with another scope is the prefix as it is (the default scope is always put in front)
    if [ -n "$scope" ]; then echo "$scope-$slug"; else echo "$slug"; fi   # no scopes configured: the slug alone
}
project_record_naming() {  # <page key> → rc 0: line 1 the prefix the project's agents share (its -main agent's name without -main, else the leading dash-parts all its agents' names have; empty for none), line 2 how many agents it has · rc 1 the record cannot say (missing, stale, unreadable, no such project)
    [ -r "$SALA_PROJECT_RECORD" ] || return 1
    local out
    out=$(python3 -I - "$SALA_PROJECT_RECORD" "$SALA_PROJECT_RECORD_MAX_AGE" "$1" 2>/dev/null <<'PY'
import datetime, json, sys
path, max_age, key = sys.argv[1:4]
try:
    d = json.load(open(path, encoding="utf-8"))
    if not isinstance(d, dict) or d.get("schema") != 1: sys.exit(1)
    age = datetime.datetime.now(datetime.timezone.utc).timestamp() - datetime.datetime.fromisoformat(str(d["generated"]).replace("Z", "+00:00")).timestamp()
    if age > float(max_age) or age < -60: sys.exit(1)
    projects = d["projects"]
    pid = (d.get("by_key") or {}).get(key)
    p = projects.get(pid) if pid else None
    if p is None: p = next((v for v in projects.values() if isinstance(v, dict) and v.get("key") == key), None)
    if not isinstance(p, dict): sys.exit(1)
    ag = p.get("agents") if isinstance(p.get("agents"), dict) else {}
    names = sorted(n for n, a in ag.items() if isinstance(a, dict) and isinstance(n, str))
    mains = [n for n in names if ag[n].get("front") is True and n.endswith("-main")]
    if mains: prefix = mains[0][:-5]
    elif names:
        parts = [n.split("-") for n in names]
        common = []
        for segs in zip(*parts):
            if len(set(segs)) != 1: break
            common.append(segs[0])
        if len(names) == 1: common = common[:-1]   # one agent: its last part is its role, not the project's name
        prefix = "-".join(common)
    else: prefix = ""
    print(prefix); print(len(names))
except SystemExit: raise
except Exception: sys.exit(1)
PY
) || return 1
    printf '%s\n' "$out"
}
name_taken() {  # <name> → 0 when a tmux session or a live claude carries it, or any project's agents map in stackshot's record lists it
    side_name_taken "$1" && return 0
    project_record_agent "" "$1" >/dev/null 2>&1 && return 0
    return 1
}
suggest_name() {  # <page key> <role> [prefix] [new] [real] → see the header (A PROJECT AGENT, the name); rc 1 only when no free name was found
    local key="$1" role="$2" p="${3:-}" isnew="${4:-0}" real="${5:-0}" rec known=0 n=0 w i cand tail max="$SALA_AGENT_NAME_MAX"
    if rec=$(project_record_naming "$key"); then
        known=1
        [ -n "$p" ] || p=$(sed -n 1p <<< "$rec")
        n=$(sed -n 2p <<< "$rec")
    fi
    [ -n "$p" ] || p=$(suggest_prefix "$key")
    # a real spawn with no NAME keeps the old rule: a front is <prefix>-main (on the map or not: the spawn's own checks say), a back a word
    if [ "$real" = 1 ] && [ "$role" = front ]; then echo "$p-main"; return 0; fi
    # -main only for a front agent of a project that has no agent yet: the record says so, or the caller says the project is new (no page,
    # so no record can know it). A record that is missing, stale or does not list the project is no ground for -main: a word is
    if [ "$role" = front ] && [ $((${#p} + 5)) -le "$max" ] && { { [ "$known" = 1 ] && [ "${n:-0}" = 0 ]; } || { [ "$known" = 0 ] && [ "$isnew" = 1 ]; }; } && ! name_taken "$p-main"; then
        echo "$p-main"; return 0
    fi
    for ((i=0; i<40; i++)); do
        w=${WORDS[RANDOM % ${#WORDS[@]}]}; tail="-$w"; cand="$p$tail"
        if [ "${#cand}" -gt "$max" ]; then cand="${p:0:$((max - ${#tail}))}"; cand="${cand%-}$tail"; fi
        name_taken "$cand" || { echo "$cand"; return 0; }
    done
    for tail in "-$$" "-$RANDOM" "-$RANDOM"; do   # every word was taken: a number, cut to fit, with no dash left before it
        cand="${p:0:$((max - ${#tail}))}"; cand="${cand%-}$tail"
        name_taken "$cand" || { echo "$cand"; return 0; }
    done
    echo "no free agent name for $key (every word and number tried is taken)" >&2
    return 1
}

# THE SIDE SESSIONS' NAMES (the header): <prefix>-side-<word><nn>
side_prefix() {  # → the prefix: the agent forked from (cut at a previous -side-), else the project's usual agent prefix (its -main agent in stackshot's project record, else the suggestion)
    local rec main
    if [ -n "$FORK_OF" ]; then echo "${FORK_OF%%-side-*}"; return 0; fi
    rec=$(project_record_agent "$SIDE_PROJECT" "side-probe-nobody" 2>/dev/null)   # not on any map: rc 3, line 2 the project's -main agent
    main=$(sed -n 2p <<< "$rec")
    case "$main" in ?*-main) echo "${main%-main}"; return 0;; esac
    suggest_prefix "$SIDE_PROJECT"
}
side_summary_to() {  # → who the write-up summary goes to: the agent forked from, else the project's -main (the record's, else <prefix>-main)
    local rec main
    if [ -n "$FORK_OF" ]; then echo "$FORK_OF"; return 0; fi
    rec=$(project_record_agent "$SIDE_PROJECT" "side-probe-nobody" 2>/dev/null); main=$(sed -n 2p <<< "$rec")
    echo "${main:-$(suggest_prefix "$SIDE_PROJECT")-main}"
}
side_name_taken() {  # <name> → 0 when a tmux session or a live claude already carries it
    local pid
    tmux has-session -t "=$1" 2>/dev/null && return 0
    local _cps; _claude_pids_r _cps || :
    for pid in $_cps; do registry_field_r _rn "$pid" name; [ "$_rn" = "$1" ] && return 0; done
    return 1
}
side_suggest_name() {  # → <prefix>-side-<word><nn>, free, at most SALA_AGENT_NAME_MAX characters (the prefix is cut to fit)
    local p w d i tail n; p=$(side_prefix)
    for ((i=0; i<40; i++)); do
        w=${WORDS[RANDOM % ${#WORDS[@]}]}; d=$(printf '%02d' $((RANDOM % 100))); tail="-side-$w$d"
        n="$p$tail"
        if [ "${#n}" -gt "$SALA_AGENT_NAME_MAX" ]; then n="${p:0:$((SALA_AGENT_NAME_MAX - ${#tail}))}"; n="${n%-}$tail"; fi
        side_name_taken "$n" || { echo "$n"; return 0; }
    done
    echo "${p:0:$((SALA_AGENT_NAME_MAX - 16))}-side-$$"
}
side_origin() {  # <agent> → "<its current conversation>|<its directory>" of the live claude in that tmux session, or 1 (not live here)
    local pid u c
    tmux has-session -t "=$1" 2>/dev/null || return 1
    pid=$(claude_pid_under "$(tmux display -p -t "=$1:0" '#{pane_pid}' 2>/dev/null)" 2>/dev/null) || return 1
    u=$(registry_field "$pid" sessionId); [ -n "$u" ] || u=$(sidecar_uuid_for_session "$1")
    c=$(registry_field "$pid" cwd)
    [ -n "$u" ] || return 1
    echo "$u|$c"
}
# side_origin_project <agent> (the page key the agent's registry row carries) lives in common.sh, beside the rename that also reads it

GENERATED=0; NAME=""
case "${1:-}" in
    '') ;;
    --brief|--prompt|--mandate|--cwd|--fork|--model|--effort|--master|--no-confirm|--project|--role|--lane|--dry-run|--suggest-name|--side|--fork-of|--item|--agents|--prefix) ;;
    -*)  die "unknown first argument: $1" ;;
    *)   NAME="$1"; shift ;;
esac
case "$NAME" in *[.:\ ]*) die "invalid session name '$NAME' (no dots, colons, or spaces)";; esac
is_shell_session "$NAME" && die "'$NAME' is the web UI's shell session (SALA_SHELL_SESSION) — a Claude session cannot take its name; pick another name"

MANDATE=""; MKIND=""; CWD="$HOME"; MODEL=""; EFFORT=""; FORK=""; MASTER=0; GO=0; PROJECT=""; ROLE=""; LANE_OPT=""; DRY=0; SUGGEST=0; PREFIX_OPT=""; NEW_OPT=0
SIDE=0; FORK_OF=""; ITEM=""; AGENTS=""; CWD_GIVEN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --master) MASTER=1; shift;;                # designate the new session as the master afterwards (salamander master --set)
        --no-confirm) GO=1; shift;;                # with a mandate file: start on it after the orientation (an unattended agent)
        --dry-run) DRY=1; shift;;                  # every check, the plan, nothing made (the operation queue's plan)
        --suggest-name) SUGGEST=1; shift;;         # print the suggested name for --project/--role and exit
        --fork)   FORK="${2:-}";   shift 2 || die "--fork needs a session uuid";;
        --mandate|--brief|--prompt) MKIND="$1"; MANDATE="${2-}"; [ $# -ge 2 ] || die "$1 needs $([ "$1" = --brief ] && echo "a path" || { [ "$1" = --prompt ] && echo text || echo "a file or text"; })"; shift 2;;
        --cwd)    CWD="${2:-}"; CWD_GIVEN=1; shift 2 || die "--cwd needs a dir";;
        --side)   SIDE=1; shift;;                  # a side conversation (the header): no project/role, no agents-map check
        --fork-of) FORK_OF="${2:-}"; shift 2 || die "--fork-of needs an agent (a live session's name)";;
        --item)   ITEM="${2:-}";   shift 2 || die "--item needs board#N";;
        --agents) AGENTS="${2:-}"; shift 2 || die "--agents needs agent names joined by commas";;
        --prefix) PREFIX_OPT="${2:-}"; shift 2 || die "--prefix needs an agent-name prefix";;   # with --suggest-name: the suggested name's prefix (the web form gives a project's real one)
        --new)    NEW_OPT=1; shift;;               # with --suggest-name: the project has no page yet (a new one), so -main is right though the record cannot know it
        --model)  MODEL="${2:-}";  shift 2 || die "--model needs an alias";;
        --effort) EFFORT="${2:-}"; shift 2 || die "--effort needs a level";;
        --project) PROJECT="${2:-}"; shift 2 || die "--project needs a page key (<dir>/<slug>, e.g. projects/demo)";;
        --role)   ROLE="${2:-}";   shift 2 || die "--role needs front or back";;
        --lane)   LANE_OPT="${2:-}"; shift 2 || die "--lane needs a lane (one of: $(lane_choices))";;
        *) die "unknown arg: $1";;
    esac
done
case "$EFFORT" in ""|low|medium|high|xhigh|max) ;; *) die "invalid --effort '$EFFORT'";; esac
case "$MODEL" in *[!A-Za-z0-9._-]*) die "invalid --model '$MODEL'";; esac
# THE SIDE SESSION'S ARGUMENTS (the header): a fork of an agent, or a fresh session about a board item; --project here only scopes it
SIDE_PROJECT=""; SIDE_KIND=""; SIDE_TO=""
if [ "$SIDE" = 0 ]; then
    [ -z "$FORK_OF$ITEM$AGENTS" ] || die "--fork-of, --item and --agents go with --side (a side conversation)"
else
    [ -z "$ROLE" ] || die "--side takes no --role: a side session is on no page's agents map"
    [ -z "$FORK" ] || die "--side forks with --fork-of AGENT (its current conversation is found for you), not --fork UUID"
    [ "$MASTER" = 0 ] || die "--side and --master cannot go together"
    SIDE_PROJECT="$PROJECT"; PROJECT=""
    if [ -n "$FORK_OF" ]; then
        SIDE_KIND=fork
        [ -z "$SIDE_PROJECT" ] || die "--fork-of takes no --project: a fork continues one agent's conversation"
        [ -z "$AGENTS" ] || die "--agents is for a start about an item (--project --item), not for a fork"
        case "$FORK_OF" in *[!A-Za-z0-9._-]*|-*) die "--fork-of needs an agent's session name, not '$FORK_OF'";; esac
    else
        SIDE_KIND=discuss
        [ -n "$SIDE_PROJECT" ] || die "--side needs --fork-of AGENT (a fork of a running agent) or --project <page key> --item board#N (a fresh session about an item)"
        page_key_ok "$SIDE_PROJECT" || die "'$SIDE_PROJECT' is not a page key: <dir>/<slug> with the dir one of ${SALA_PAGE_DIRS// /, } and the slug lowercase letters, digits and dashes"
        [ -n "$ITEM" ] || [ "$SUGGEST" = 1 ] || die "a side session about a project needs --item board#N: the item it is about"
    fi
    [ -z "$ITEM" ] || item_id_ok "$ITEM" || die "--item takes a board item id as shown (board#N, sN, board-tmp-box#N), not '$ITEM'"
    [ -z "$AGENTS" ] || [[ "$AGENTS" =~ ^[a-z0-9-]+(,[a-z0-9-]+)*$ ]] || die "--agents takes agent names joined by commas (lowercase letters, digits, dashes), not '$AGENTS'"
fi
# THE PROJECT AGENT'S ARGUMENTS (the header): --project and --role go together; a back agent needs a mandate
if [ "$SIDE" = 0 ] && { [ -n "$PROJECT" ] || [ -n "$ROLE" ] || [ "$SUGGEST" = 1 ]; }; then
    [ -n "$PROJECT" ] || die "--role needs --project <page key> (<dir>/<slug>, e.g. projects/demo): a project agent is a session of a project page"
    [ -n "$ROLE" ] || die "--project needs --role front or --role back (front: a session ${SALA_OWNER_NAME} talks to, a top-level entry under agents:; back: a background agent, under background:)"
    case "$ROLE" in front|back) ;; *) die "--role takes front or back, not '$ROLE'";; esac
    page_key_ok "$PROJECT" || die "'$PROJECT' is not a page key: <dir>/<slug> with the dir one of ${SALA_PAGE_DIRS// /, } and the slug lowercase letters, digits and dashes (projects/site-redesign, projects/demo)"
fi
if [ "$NEW_OPT" = 1 ]; then
    [ "$SUGGEST" = 1 ] && [ "$SIDE" = 0 ] || die "--new goes with --suggest-name --project … --role … (the project has no page yet)"
fi
if [ -n "$PREFIX_OPT" ]; then
    [ "$SUGGEST" = 1 ] && [ "$SIDE" = 0 ] || die "--prefix goes with --suggest-name --project … --role … (it sets the prefix of the suggested name)"
    [[ "$PREFIX_OPT" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] && [ "${#PREFIX_OPT}" -le $((SALA_AGENT_NAME_MAX - 3)) ] || die "--prefix takes lowercase letters, digits and dashes, no dash at either end, at most $((SALA_AGENT_NAME_MAX - 3)) characters, not '$PREFIX_OPT'"
fi
if [ "$SUGGEST" = 1 ]; then if [ "$SIDE" = 1 ]; then side_suggest_name; else suggest_name "$PROJECT" "$ROLE" "$PREFIX_OPT" "$NEW_OPT" || exit 1; fi; exit 0; fi
if [ -z "$NAME" ]; then
    if [ "$SIDE" = 1 ]; then NAME=$(side_suggest_name)
    elif [ -n "$PROJECT" ]; then NAME=$(suggest_name "$PROJECT" "$ROLE" "" 0 1) || die "no free agent name for $PROJECT"; else NAME=$(gen_name); GENERATED=1; fi
fi
if [ "$SIDE" = 1 ]; then
    case "$NAME" in *-side-?*) ;; *) die "a side session's name contains -side- (<prefix>-side-<word><nn>): '$NAME' does not (salamander spawn --suggest-name --side … suggests one)";; esac
    agent_name_ok "$NAME" || die "'$NAME' is not an agent name: lowercase letters, digits and dashes only, no dash at either end, at most $SALA_AGENT_NAME_MAX characters"
    SIDE_TO=$(side_summary_to)
fi
if [ -n "$PROJECT" ]; then
    agent_name_ok "$NAME" || die "'$NAME' is not an agent name: lowercase letters, digits and dashes only, no dash at either end, at most $SALA_AGENT_NAME_MAX characters (the suggestion: salamander spawn --suggest-name --project $PROJECT --role $ROLE)"
    [ "$ROLE" = back ] && [ -z "$MANDATE" ] && die "a back agent needs --mandate FILE|TEXT: a background agent reads its mandate at its first prompt, and nobody briefs it"
    [ "$ROLE" = back ] && GO=1   # nobody waits to confirm a background agent's start
fi
[ -n "$MKIND" ] && [ -z "$MANDATE" ] && die "$MKIND needs $([ "$MKIND" = --brief ] && echo "a path" || { [ "$MKIND" = --prompt ] && echo text || echo "a file or text"; }), not an empty argument"
if [ "$SIDE_KIND" = fork ]; then   # the agent's current conversation, and (unless --cwd) its directory: the CLI finds a conversation by the directory it ran in
    orig=$(side_origin "$FORK_OF") || die "no live session '$FORK_OF' to fork: a fork continues the conversation of a running agent (salamander spawn --list)"
    FORK="${orig%%|*}"; ORIGIN_CWD="${orig#*|}"
    [ "$CWD_GIVEN" = 1 ] || [ -z "$ORIGIN_CWD" ] || [ ! -d "$ORIGIN_CWD" ] || CWD="$ORIGIN_CWD"
fi
if [ -n "$FORK" ]; then
    case "$FORK" in *[!0-9a-fA-F-]*) die "invalid --fork uuid '$FORK'";; esac
    [ -s "$(transcript_for_uuid "$FORK")" ] || die "no transcript for $FORK under $SALA_PROJECTS"
fi
if [ "$ROLE" = back ] && [ "$CWD_GIVEN" = 0 ] && [ -n "${SALA_BACK_CWD:-}" ]; then   # a background agent starts where the background brief is (the header); --cwd always wins
    BACK_DIR="${SALA_BACK_CWD/#\~/$HOME}"
    [ -d "$BACK_DIR" ] || die "a back agent starts in the background brief's directory, which does not exist here: $BACK_DIR (SALA_BACK_CWD names it; it loads the background brief from there, not the front rules from \$HOME). Create or clone the directory, fix SALA_BACK_CWD, or pass --cwd DIR"
    CWD="$BACK_DIR"
fi
[ -d "$CWD" ] || die "cwd does not exist: $CWD"
CWD=$(cd "$CWD" && pwd -P)   # the real path: it goes into the pane map's cwd column, which `sala restore` recreates the session in
# THE MANDATE'S KIND (the header): a file (absolute, so the pane's shell finds it from --cwd) or text
MFILE=""; MTEXT=""
if [ -n "$MANDATE" ]; then
    if [ -f "$MANDATE" ] && [ -r "$MANDATE" ] && [ "$MKIND" != --prompt ]; then MFILE="$(cd "$(dirname "$MANDATE")" && pwd -P)/$(basename "$MANDATE")"
    elif [ "$MKIND" = --brief ]; then die "brief not readable: $MANDATE"
    else MTEXT="$MANDATE"; fi
fi
mandate_line() {  # → the mandate's first non-blank line, one line, a heading's # stripped, at most 70 characters (stackshot's rule for the page's line); empty for none
    local s
    if [ -n "$MFILE" ]; then s=$(grep -m1 -v '^[[:space:]]*$' "$MFILE" 2>/dev/null); elif [ -n "$MTEXT" ]; then s=$(printf '%s\n' "$MTEXT" | grep -m1 -v '^[[:space:]]*$'); else return 0; fi
    s=$(printf '%s' "$s" | tr '\r\n\t' '   ' | sed 's/^ *#* *//; s/  */ /g; s/ $//')
    python3 -c 'import sys; print(sys.argv[1][:70])' "$s" 2>/dev/null || printf '%s\n' "${s:0:70}"   # characters, not bytes: a Korean line is cut whole
}
shell_dq() {  # <text> → the text double-quoted for a shell (backslash, ", $ and ` escaped)
    printf '"%s"' "$(printf '%s' "$1" | sed 's/[\\"$`]/\\&/g')"
}
register_cmd() {  # <page key> <front|back, or empty for either> <name> <mandate line> <the project's -main agent, or empty> → stackshot's register command (words only: sala never runs it)
    local key=$1 r=$2 name=$3 line=$4 pmain=${5:-} role='<role>' pre flag
    pre=${pmain%-main}   # the project's name is its -main agent's without -main; the role is the part of NAME after it
    if [ -n "$pmain" ] && [ "$pre" != "$pmain" ] && [ "${name#"$pre"-}" != "$name" ] && [ -n "${name#"$pre"-}" ]; then role=${name#"$pre"-}; fi
    case "$r" in front) flag=--front ;; back) flag=--back ;; *) flag='--front|--back' ;; esac
    printf 'python3 ~/stackshot/client.py post project-agent %s %s --role %s %s --mandate %s' "$key" "$name" "$role" "$flag" "$([ -n "$line" ] && shell_dq "$line" || echo '"<one line>"')"
}
spawn_ask_keeper() {  # <page key> <mandate line> <what pages.py said> <the register command> — one stackshot message to the page's keeper, detached; never when a register hook owns registration
    local stamp="$SALA_STATE_DIR/spawn-asked/$NAME" now last text role="${ROLE:-front}"
    if [ -n "${SALA_SPAWN_REGISTER:-}" ]; then spawn_log "ask: not sent for $1 — SALA_SPAWN_REGISTER is configured, so registration is the hook's"; return 0; fi
    [ -n "$SALA_SPAWN_ASK_CMD" ] || { spawn_log "ask: not sent for $1 — SALA_SPAWN_ASK_CMD is empty"; return 0; }
    now=$(date +%s); _mkparent "$stamp"; last=$(cat "$stamp" 2>/dev/null || echo 0)
    if [ $((now - ${last:-0})) -lt "$SALA_SPAWN_ASK_EVERY" ] 2>/dev/null; then
        spawn_log "ask: not sent again for $1 (asked at $(local_human "$last"), within $SALA_SPAWN_ASK_EVERY s)"
        echo "   (the page's keeper was asked to register it at $(local_human "$last") already; not again within $(( SALA_SPAWN_ASK_EVERY / 60 )) min)" >&2; return 0
    fi
    echo "$now" > "$stamp"
    text="[sala spawn] A new $role agent '$NAME' of $1 was asked for${SALA_OP_FROM:+ by $SALA_OP_FROM}${SALA_OP_WORDS:+ (\"$SALA_OP_WORDS\")}, but the name is not on the page's agents map yet ($3). Please register it with stackshot, then the spawn runs again (sala op spawn $NAME --project $1 --role $role${2:+ --mandate <the mandate>} --from <you> --words \"<${SALA_OWNER_NAME}'s words>\"):"$'\n'"$4"$'\n'"(Automatic salamander message from sala spawn; nothing to reply to.)"
    ( setsid timeout --kill-after=10 150 sh -c "$SALA_SPAWN_ASK_CMD \"\$@\"" spawn-ask "$1" "$text" --sender "sala spawn" </dev/null >> "$SPAWN_LOG" 2>&1 & )
    spawn_log "ask: the keeper of $1 asked to register it ($SALA_SPAWN_ASK_CMD, to $1)"
    echo "   the page's keeper was asked to register it in one stackshot message (to $1)" >&2
}
refuse_unlisted() {  # <page key> <role> <what pages.py said> [the project's -main agent] — the refusal (stderr), the marker and the register command (stdout), the keeper asked, exit 3
    local line cmd; line=$(mandate_line); cmd=$(register_cmd "$1" "$2" "$NAME" "$line" "${4:-}")
    echo "✗ '$NAME' is not on the agents map of $1 ($3): a project agent is registered with stackshot before its session is made. Register it, then spawn again: $cmd" >&2
    echo "REGISTER: $1"
    echo "$cmd"
    spawn_log "refused: not listed on $1 ($3)"
    spawn_ask_keeper "$1" "$line" "$3" "$cmd"
    exit 3
}
spawn_register() {  # the register hook (the header), once the session is up and mapped; never changes the exit status
    local line rc; line=$(mandate_line)
    if [ -z "${SALA_SPAWN_REGISTER:-}" ]; then
        spawn_log "spawn-register: no hook configured (SALA_SPAWN_REGISTER); $ROLE agent of $PROJECT${MFILE:+, mandate $MFILE}"
        echo "   register: no hook configured (SALA_SPAWN_REGISTER) — the line on $PROJECT is the record"; return 0
    fi
    SALA_SPAWN_NAME="$NAME" SALA_SPAWN_PROJECT="$PROJECT" SALA_SPAWN_ROLE="$ROLE" SALA_SPAWN_MANDATE_FILE="$MFILE" SALA_SPAWN_MANDATE_LINE="$line" \
        SALA_SPAWN_UUID="${ruuid:-}" SALA_SPAWN_LANE="$LANE" \
        timeout --kill-after=10 60 sh -c "$SALA_SPAWN_REGISTER" spawn-register "$NAME" "$PROJECT" "$ROLE" "$MFILE" </dev/null >> "$SPAWN_LOG" 2>&1 9>&-; rc=$?
    if [ "$rc" = 0 ]; then spawn_log "spawn-register: the hook ran ($ROLE agent of $PROJECT)"; echo "   register: the hook ran (SALA_SPAWN_REGISTER)"
    else spawn_log "spawn-register: the hook exited $rc ($ROLE agent of $PROJECT) — the session is up all the same"; echo "   ⚠ register: the hook exited $rc (SALA_SPAWN_REGISTER; its output: $SPAWN_LOG) — the session is up; register it by hand"; fi
    return 0
}

# THE LANE (Tue Oct 13th 2026; common.sh, lanes): a new session launches on the default lane (`sala lane default`),
# recorded nowhere — it follows the default until `sala lane <lane> NAME` gives it a lane of its own; --lane L launches on L
# and records the row at once. A lane that cannot launch (its key file or config directory gone) is refused
# here, before the tmux session is made and before any page is asked about the name (a refusal the box can give alone
# never costs a pages.py call or a message to a page's keeper).
# THE BACK AGENTS' LANE RULE (common.sh): a background agent spawned while the rule has the back agents off their home lane lands on the rule's lane
# (as --lane would: recorded, so every relaunch keeps it, and the rule's move home finds it). An explicit --lane wins; a front agent, a side session and
# a throwaway are not the rule's; a Fable model is left on the default when the rule's lane cannot run Fable; a rule lane that is dormant or not ready is skipped.
BACK_RULE_NOTE=""
if [ -z "$LANE_OPT" ] && [ -n "$PROJECT" ] && [ "$ROLE" = back ] && [ "$SIDE" = 0 ] && BL_SPAWN=$(back_lane_spawn_lane); then
    if [[ $MODEL == *fable* ]] && [[ " $SALA_FALLBACK_NO_FABLE " == *" $BL_SPAWN "* ]]; then
        BACK_RULE_NOTE="the back agents' lane rule has them on the $(lane_shown "$BL_SPAWN") lane, which cannot run $MODEL: this one takes the default lane"
    else LANE_OPT=$BL_SPAWN; BACK_RULE_NOTE="the back agents' lane rule has them on the $(lane_shown "$BL_SPAWN") lane: this one launches there (--lane overrides)"; fi
fi
if [ -n "$LANE_OPT" ]; then
    lane_known "$LANE_OPT" || die "'$LANE_OPT' is not a lane (one of: $(lane_choices))"
    _lane_norm_r LANE_OPT "$LANE_OPT"   # a renamed lane's old name (awsplatform, max, team) is accepted and recorded as the current one
    # a dormant lane (the dormant record, common.sh) is not offered: the list above leaves it out and a new session is refused on it
    if why=$(lane_dormant_refusal "$LANE_OPT"); then die "$why (pick one of: $(lane_choices))"; fi
    LANE=$(lane_effective "$LANE_OPT"); why=$(lane_check "$LANE") || die "the lane '$LANE' cannot launch: $why"
    [ "$LANE" = sdk ] && die "the sdk lane only resumes a conversation — spawn on another lane, then: salamander lane sdk $NAME"
else
    if why=$(lane_dormant_refusal "$(lane_default)"); then die "$why — the default lane is where a new session goes: spawn with --lane (one of: $(lane_choices)), or move the default: salamander lane default <lane>"; fi
    LANE=$(lane_default); why=$(lane_check "$LANE") || die "the default lane '$LANE' cannot launch: $why"
    # the sdk lane's pane program resumes a conversation; a new one is spawned on subscription-1, then moved (lib/sdk-pane.sh)
    [ "$LANE" = sdk ] && die "the default lane is sdk, which only resumes a conversation — spawn on another default (salamander lane default subscription-1), then: salamander lane sdk $NAME"
fi

[ "$DRY" = 1 ] || ledger_frozen_die spawn   # a recycle or reboot holds the pane map: nothing half-made; a dry run only looks
tmux has-session -t "=$NAME" 2>/dev/null && die "tmux session '$NAME' already exists"   # '=': exact, not a prefix (demo vs demo-extra)
_claude_pids_r _cps || :
for pid in $_cps; do   # a running claude elsewhere already carrying the name (e.g. a pane renamed by hand)
    registry_field_r _rn "$pid" name; [ "$_rn" = "$NAME" ] && die "'$NAME' is already the name of a live session (pid $pid) — pick another, or salamander rename it first"
done
LISTED=""
if [ "$SIDE" = 1 ]; then
    # a side session is on no agents map (the header): nothing to list; a discuss start only needs its project's page to exist, and a check that
    # cannot tell is said and let go (nothing here waits on a page's line, unlike a project agent)
    if [ "$SIDE_KIND" = discuss ] && [ "${SALA_AGENT_CHECK:-on}" != off ]; then
        why=$(page_exists "$SIDE_PROJECT"); rc=$?
        case "$rc" in
            0) ;;
            1) echo "✗ no page $SIDE_PROJECT: a side session about an item is scoped to its project's page — check the project of the item" >&2; echo "NO-PAGE: $SIDE_PROJECT"; spawn_log "refused: no page $SIDE_PROJECT (side session)"; exit 4 ;;
            *) echo "⚠ cannot tell whether the page $SIDE_PROJECT exists ($why); going on: a side session waits on no page's line" >&2 ;;
        esac
    fi
elif [ -n "$PROJECT" ]; then
    # THE PROJECT SPAWN'S CHECKS (common.sh): the page, then the name on its agents map; neither fails open
    if [ "${SALA_AGENT_CHECK:-on}" = off ]; then LISTED="not checked (SALA_AGENT_CHECK=off)"
    else
        # the first source: stackshot's project record (a file; common.sh, THE PROJECT RECORD). A project in it exists and its map
        # answers listed / not listed / the other role; a record that cannot answer (missing, stale, unreadable, no such project)
        # falls through to pages.py below, which can still refuse with "cannot tell"
        rec=$(project_record_agent "$PROJECT" "$NAME" "$ROLE"); rrc=$?
        case "$rrc" in
            0) LISTED=$(sed -n 1p <<< "$rec"); spawn_log "project record: '$NAME' is listed on $PROJECT ($ROLE)" ;;
            3) pmain=$(sed -n 2p <<< "$rec"); refuse_unlisted "$PROJECT" "$ROLE" "$(sed -n 1p <<< "$rec")${pmain:+; main agent: $pmain}" "$pmain" ;;
            5) spawn_log "refused: $rec"; die "$rec — a spawn takes the role the record gives: --role $([ "$ROLE" = front ] && echo back || echo front) (or change the page's line first)" ;;
            *) spawn_log "project record: no answer ($rec); asking pages.py"
               why=$(page_exists "$PROJECT"); rc=$?
               case "$rc" in
                   0) ;;
                   1) echo "✗ no page $PROJECT: a project's hub page comes first — ask a session with gbrain (the project's -main or the board's main session) to create the page first, then spawn again (nothing in sala writes to gbrain)" >&2
                      echo "NO-PAGE: $PROJECT"; spawn_log "refused: no page $PROJECT"; exit 4 ;;
                   *) die "cannot tell whether the page $PROJECT exists ($why; the project record: $rec) — a project spawn needs the answer; try again, or check stackshot's pages.py (SALA_STACKSHOT_DIR) on this box" ;;
               esac
               why=$(agent_listed_on "$NAME" "$PROJECT"); rc=$?
               case "$rc" in
                   0) LISTED="$why" ;;
                   3) refuse_unlisted "$PROJECT" "$ROLE" "$why" ;;
                   *) die "cannot tell whether '$NAME' is on the agents map of $PROJECT ($why; the project record: $rec) — a project spawn needs the answer; try again, or check stackshot's pages.py (SALA_STACKSHOT_DIR) on this box" ;;
               esac ;;
        esac
    fi
else
    if why=$(agent_unlisted "$NAME"); then   # an agent name its project page does not list yet (fail-open: pages.py's own mapping of the name, a plain spawn's rule)
        hub=$(printf '%s\n' "$why" | sed -n 's/.* on \([a-z0-9/-]*\) (\(the page\|steward\).*/\1/p' | head -1)
        echo "✗ $why" >&2
        if [ -n "$hub" ]; then   # the page pages.py named: the block as for a project spawn, the role unknown here
            line=$(mandate_line)
            echo "   (register it with stackshot first; the command below leaves the role open: --front for a front agent, --back for a background one; --project $hub --role front|back says which)" >&2
            echo "REGISTER: $hub"
            register_cmd "$hub" "" "$NAME" "$line" ""; echo
        fi
        spawn_log "refused: $why"
        exit 3
    fi
fi

registry_for_pane() {  # tmux session → "name|version|bridge|uuid" of the claude running IN that pane
    # by process, never by the registry's "tmux" field: claude writes that once at start, so a pane renamed since
    # (sala rename) still claims the old session name — a fresh spawn once read a renamed
    # session's row and told the operator to /rename it
    local pid f
    pid=$(claude_pid_under "$(tmux display -p -t "=$1:0" '#{pane_pid}' 2>/dev/null)" 2>/dev/null) || return 0
    f="$SALA_REG_DIR/$pid.json"; [ -r "$f" ] || return 0
    python3 -c "
import json
d=json.load(open('$f'))
print('|'.join([str(d.get('name','')), str(d.get('version','')), str(d.get('bridgeSessionId') or '—'), str(d.get('sessionId',''))]))" 2>/dev/null
}

SIDE_MFILE="$SALA_STATE_DIR/mandates/side-$NAME.md"   # where a side session's generated mandate is written (at run time; the dry run only says so)
if [ "$DRY" = 1 ]; then
    echo "[dry-run] would spawn '$NAME'${PROJECT:+ as a $ROLE agent of $PROJECT (on its agents map: $LISTED)}${SIDE_KIND:+ as a side session ($([ "$SIDE_KIND" = fork ] && echo "a fork of $FORK_OF" || echo "a fresh start about $ITEM of $SIDE_PROJECT")${ITEM:+, item $ITEM}; on no agents map; its write-up summary goes to $SIDE_TO)} on the $(lane_shown "$LANE") lane${LANE_OPT:+ (recorded)}, cwd $CWD, model ${MODEL:-global default} / effort ${EFFORT:-global default}${FORK:+, forked from $FORK}"
    if [ "$SIDE" = 1 ]; then echo "[dry-run] mandate: written to $SIDE_MFILE and read by the session ($([ "$GO" = 1 ] && echo "then it starts on it; nobody confirms" || echo "it waits for a confirmation"))${AGENTS:+, naming the agents $AGENTS}${MANDATE:+, with your ${MFILE:+file $MFILE}${MTEXT:+text} appended}"
    elif [ -n "$MFILE" ]; then echo "[dry-run] mandate: the file $MFILE, read by the session ($([ "$GO" = 1 ] && echo "then it starts on it; nobody confirms" || echo "it waits for a confirmation")): $(mandate_line)"
    elif [ -n "$MTEXT" ]; then echo "[dry-run] mandate: the text typed as the first message: $(mandate_line)"
    else echo "[dry-run] mandate: none"; fi
    [ -n "$PROJECT" ] && echo "[dry-run] register: $([ -n "${SALA_SPAWN_REGISTER:-}" ] && echo "the hook (SALA_SPAWN_REGISTER) would run after" || echo "no hook configured (SALA_SPAWN_REGISTER): the page's line is the record")"
    [ -z "$BACK_RULE_NOTE" ] || echo "[dry-run] lane: $BACK_RULE_NOTE"
    echo "[dry-run] nothing made, recorded or typed"
    exit 0
fi

# THE SIDE SESSION'S MANDATE (the header): written for it, read by it; a --mandate FILE|TEXT of the caller is appended as the owner's own words
side_write_mandate() {
    local n="${ITEM#board#}" kind_line link="(the id as the board shows it; read it with the stackshot connector)"
    case "$ITEM" in board#*) [ -n "${SALA_STACKSHOT_WEB:-}" ] && link="(${SALA_STACKSHOT_WEB%/}/items/$n)";; esac
    if [ "$SIDE_KIND" = fork ]; then kind_line="a fork of the conversation of \`$FORK_OF\` (you have its history up to now)"; else kind_line="a fresh session (not a fork) about $ITEM"; fi
    _mkparent "$SIDE_MFILE" || return 1
    {
        echo "# Side conversation: $NAME"
        echo
        echo "You are \`$NAME\`, a SIDE CONVERSATION with ${SALA_OWNER_NAME}: a short-lived session started in one step, $kind_line. You are on no page's agents map and you take over nobody's work. You talk with ${SALA_OWNER_NAME} here; ask what is wanted first."
        if [ -n "$ITEM" ]; then
            echo
            echo "It is about $ITEM $link${SIDE_PROJECT:+, project page \`$SIDE_PROJECT\`}."
        fi
        if [ "$SIDE_KIND" = discuss ]; then
            echo
            echo "## Start by reading"
            echo "1. The Current state of the project page \`$SIDE_PROJECT\` (gbrain), and $ITEM itself (the stackshot connector's \`get\`): its subject, description, next, needs and comments."
            echo "2. The agents involved in the item (its owner, the sessions in its needs, the sessions named on it)${AGENTS:+: \`${AGENTS//,/\`, \`}\`}. Find and read ONLY the transcript excerpts you need from them: \`sala sessions transcript <name> [--json]\` prints an agent's current and earlier transcript files (read-only); search those files for the item's id or the topic and read around the hits. Never read a whole transcript."
            echo "3. Then give a short orientation (what the item is, where it stands, what you found) and talk with ${SALA_OWNER_NAME}."
        else
            echo
            echo "## Start"
            echo "Give a short orientation (what you remember of \`$FORK_OF\`'s work, what you could be asked) and talk with ${SALA_OWNER_NAME}. \`$FORK_OF\` keeps running on its own; this conversation does not change its context. \`sala sessions transcript $FORK_OF\` (read-only) shows where its transcripts are, if you need to look at what it did since the fork."
        fi
        echo
        echo "## The end"
        echo "- Before this conversation ends you MUST run \`sala side done\`. It records the write-up and sends your summary to \`$SIDE_TO\`:"
        echo "      sala side done${ITEM:+ --item $ITEM} --summary \"<what was decided or found, written for $SIDE_TO>\""
        echo "  It succeeds only when (1) the board item${ITEM:+ $ITEM} changed since you started: record what was decided on it through the stackshot connector (if you read it there, pass its \`updated\` as \`--item-updated <epoch or ISO time>\`), (2) the project page${SIDE_PROJECT:+ \`$SIDE_PROJECT\`} has a timeline line with your name, \`$NAME\`, as its source, and (3) the summary is sent (\`sala side done\` sends it itself). It says what is missing; fix that and run it again."
        echo "- You retire only when ${SALA_OWNER_NAME} tells you to (the request goes through the queue: \`sala op retire $NAME\`). Never retire or exit yourself, and do not ask to be retired."
        if [ -n "$MFILE" ] || [ -n "$MTEXT" ]; then
            echo
            echo "## Instructions for this conversation"   # fixed heading: lib/common.sh (the rename's reason line) also accepts the older "## <name>'s instructions for this conversation"
            if [ -n "$MFILE" ]; then cat "$MFILE"; else printf '%s\n' "$MTEXT"; fi
        fi
    } > "$SIDE_MFILE" || return 1
    MFILE="$SIDE_MFILE"; MTEXT=""
}
side_record() {  # the session's record (common.sh, THE SIDE SESSIONS) and the registry row's copy
    local proj="$SIDE_PROJECT" at; at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    [ -n "$proj" ] || proj=$(side_origin_project "$FORK_OF")
    mkdir -p "$SALA_SIDE_DIR" 2>/dev/null || return 1
    rm -f "$(side_done_file "$NAME")"   # a name used before: its marker is not this session's
    { echo "name=$NAME"; echo "kind=$SIDE_KIND"; echo "origin=$FORK_OF"; echo "project=$proj"; echo "item=$ITEM"; echo "agents=$AGENTS"
      echo "summary_to=$SIDE_TO"; echo "started=$SIDE_T0"; echo "uuid=${ruuid:-}"; echo "origin_uuid=$FORK"; echo "mandate=$MFILE"; } > "$(side_file "$NAME").t.$$" \
        && mv -f "$(side_file "$NAME").t.$$" "$(side_file "$NAME")" || return 1
    [ -z "$MAPPED" ] || sessions_set "$NAME" "side=1" "side_origin=$FORK_OF" "side_item=$ITEM" "side_at=$at"
    return 0
}

PANE=$(tmux_win_t "$NAME" 0); SIDE_T0=$(date +%s)
[ "$SIDE" = 0 ] || side_write_mandate || die "could not write the side session's mandate to $SIDE_MFILE"
# THE SESSION'S ID (phase 2): the registry row is made BEFORE the pane's claude starts, and its id goes into the pane's
# environment as SALA_SESSION_ID (tmux new-session -e: the pane's shell, so every later claude typed there carries it, a recycle's
# resume included; and on the launch line, for a tmux without -e), so the session's own SessionStart hook (`salamander hook
# session-start`) can name its row. Nothing when SALA_SESSIONS=off or the registry fails: the hook then finds the row by the
# tmux session name. A spawn that does not come up takes the row back (the exit trap below); a kill leaves it for `sessions --check`.
SPAWN_SID=$(sessions_prepare "$NAME" "$NAME" "$CWD" 2>/dev/null); SPAWN_UP=""
trap '[ -z "$SPAWN_UP" ] && [ -n "$SPAWN_SID" ] && sessions_abandon "$SPAWN_SID"' EXIT
if [ -n "$SPAWN_SID" ]; then
    tmux new-session -d -s "$NAME" -c "$CWD" -e "SALA_SESSION_ID=$SPAWN_SID" 2>/dev/null || tmux new-session -d -s "$NAME" -c "$CWD" || die "tmux new-session failed"
else
    tmux new-session -d -s "$NAME" -c "$CWD" || die "tmux new-session failed"
fi
compact_tokens_r CMP "$NAME"   # the session's compact window, if compact.tsv has a row (common.sh)
# a fork is a resume: it restores the permissionMode its transcript recorded, so it gets the settings' defaultMode as a flag; a new session reads the settings itself
shell_send "$PANE" "${SPAWN_SID:+SALA_SESSION_ID=$SPAWN_SID }$(lane_env_prefix "$LANE")$(mod_env_prefix)$SALA_CLAUDE${FORK:+ --resume $FORK --fork-session}${MODEL:+ --model $MODEL}${EFFORT:+ --effort $EFFORT}${CMP:+ --autocompact $CMP}$(lane_args "$LANE")${FORK:+$(permission_mode_args "$LANE")}"   # into the pane's shell, not a composer (common.sh)
resume_wait "$PANE" "" 45; rc=$?   # live, not merely started: any registry row, the session id is new
[ "$rc" = 2 ] && die "claude started and died in $NAME:0 within 45s — the pane is back at a shell, the error above its prompt (tmux attach -t =$NAME)"
[ "$rc" = 0 ] || die "claude did not start in $NAME:0 within 45s"
SPAWN_UP=1   # live: the row stays (ledger_write add below puts its conversation on it)

sleep "$SALA_SPAWN_SETTLE"; submit "$PANE" "/rename $NAME"; sleep "$SALA_RENAME_SETTLE"
for _ in 1 2 3 4 5; do info=$(registry_for_pane "$NAME"); [ -n "$info" ] && break; sleep 2; done   # the registry file lands a moment after start
if [ "${info%%|*}" != "$NAME" ]; then sleep 4; submit "$PANE" "/rename $NAME"; sleep 5; info=$(registry_for_pane "$NAME"); fi

if [ -n "$MFILE" ]; then
    submit "$PANE" "Read $MFILE in full — that is your mandate for this session. Then give a short orientation: what this session is for, the current state, and what you would do first. $([ "$GO" = 1 ] && echo "Then start on it; nobody is waiting to confirm." || echo "Do not act on it until I confirm.")"
elif [ -n "$MTEXT" ]; then
    submit "$PANE" "$MTEXT"
fi

IFS='|' read -r rname rver rbridge ruuid <<< "${info:-|||}"
# THE PANE MAP ROW — an honored add (the map is a ledger, common.sh; the save below no longer adds
# rows). Without it a reboot or recycle could not bring the session back; the registry not landing in time leaves the
# session unmapped, which `sala watch` reports and `sala adopt` fixes.
MAPPED=""
if [ -n "${ruuid:-}" ]; then ledger_write add "$NAME" "$ruuid" "$NAME" "$CWD" && MAPPED=1; fi
LANE_ROW=""
if [ -n "$LANE_OPT" ]; then lane_write "$NAME" "$LANE_OPT" && LANE_ROW=1; fi   # the explicit lane is intent: every later relaunch keeps it
if [ -n "$PROJECT" ] && [ -n "$MAPPED" ]; then sessions_set "$NAME" "project=$PROJECT" "role=$ROLE"; fi   # the session registry's row (phase 1): never fails the spawn
if [ -z "$PROJECT" ] && [ "$SIDE" = 0 ] && [ "$MASTER" = 0 ] && [ -n "$MAPPED" ]; then   # a throwaway: its row carries the throwaway tag and records the Claude session that started it (common.sh, A THROWAWAY'S SPAWNER)
    SPAWNER=$(spawn_caller); sessions_set "$NAME" "throwaway=1" ${SPAWNER:+"spawned_by=$SPAWNER"}
fi
SIDE_REC=""; if [ "$SIDE" = 1 ]; then side_record && SIDE_REC=1; fi   # the side record (the retire gate) and the row's side fields

# Snapshot NOW: continuum's autosave only fires while a tmux client is attached, which on a
# Remote-Control-driven box can be days apart. A full resurrect save puts the new tmux session in
# the snapshot (its post-save hook observes the pane map); --save-map alone is the fallback.
# Under the snapshot lock (lib/snapshot.sh takes the same one around the same script), since spawns run side by side in the operation
# queue (lib/op.sh, THE PARALLEL RULE) and beside a retire's or rename's `snapshot --now`: two saves at once write one resurrect file.
if [ -x "$SALA_RESURRECT_SAVE" ]; then
    mkdir -p "$SALA_RESURRECT_DIR" 2>/dev/null
    if command -v flock >/dev/null 2>&1; then flock -w 60 "$SALA_RESURRECT_DIR/.snapshot.lock" "$SALA_RESURRECT_SAVE" >/dev/null 2>&1
    else "$SALA_RESURRECT_SAVE" >/dev/null 2>&1; fi
else "$SALA_BIN" revive --save-map >/dev/null 2>&1; fi

[ "$GENERATED" = 1 ] && echo "   (name auto-generated — throwaway)"
echo "✅ spawned '$NAME'"
[ -n "$PROJECT" ] && echo "   project : $PROJECT — $ROLE agent (on its agents map: $LISTED)"
if [ "$SIDE" = 1 ]; then
    echo "   side    : $SIDE_KIND${FORK_OF:+ of $FORK_OF}${ITEM:+, $ITEM}${SIDE_PROJECT:+ ($SIDE_PROJECT)} — on no agents map; summary to $SIDE_TO; retires only on ${SALA_OWNER_NAME}'s word, once \`sala side done\` ran"
    [ -n "$SIDE_REC" ] || echo "   ⚠ the side record could not be written under $SALA_SIDE_DIR: retire will not ask for the write-up marker, and sala side done cannot run"
fi
if [ -n "$MFILE" ]; then echo "   mandate : $MFILE ($([ "$GO" = 1 ] && echo "started on it; nobody confirms" || echo "waits for a confirmation"))"; elif [ -n "$MTEXT" ]; then echo "   mandate : typed as the first message"; fi
echo "   tmux    : $NAME:0   (cwd $CWD)"
echo "   claude  : ${rver:-?}   session name '${rname:-?}'"
echo "   model   : ${MODEL:-global default} / effort ${EFFORT:-global default}"
if [ -n "$LANE_OPT" ]; then echo "   lane    : $LANE ($([ -n "$LANE_ROW" ] && echo "recorded: every relaunch keeps it" || echo "⚠ the row could not be written: salamander lane $LANE_OPT $NAME records it"))"
else echo "   lane    : $LANE (the default; sala lane <lane> $NAME gives it one of its own)"; fi
[ -z "$BACK_RULE_NOTE" ] || echo "             $BACK_RULE_NOTE"
echo "   conv    : ${ruuid:-?}${FORK:+   (forked from $FORK — archive the original: salamander rc --archive <web id>)}"
if [ -n "${rbridge:-}" ] && [ "$rbridge" != "—" ]; then echo "   remote  : https://claude.ai/code/${rbridge}"
elif ! lane_rc "$LANE"; then echo "   remote  : none — no Remote Control on the $(lane_shown "$LANE") lane (no claude.ai login behind it)"
else echo "   remote  : no bridge yet — check /rc in the pane, or run /remote-control there"; fi
[ "${rname:-}" = "$NAME" ] || echo "   ⚠ session name is '${rname:-unset}', not '$NAME' — run /rename $NAME in the pane"
[ -n "$MAPPED" ] || echo "   ⚠ the pane map has no row for '$NAME' yet ($([ -n "${ruuid:-}" ] && echo "the write failed, see above" || echo "no registry entry yet")) — a reboot could not bring it back; once it is up, run: salamander adopt $NAME"
[ -n "$PROJECT" ] && spawn_register   # THE REGISTER HOOK (the header): after the session is up and mapped; a failure is one ⚠ line, never the exit status
if [ "$MASTER" = 1 ]; then "$SALA_BIN" master --set "$NAME" || exit 1; fi
exit 0   # the session is up and verified above; nothing after this line may decide the exit status (Why: a trailing `[ … ] &&` once returned 1 on every good spawn)
