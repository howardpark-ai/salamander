# lib/spawn.sh — start a named tmux session running Claude Code, visible to Remote Control.
#
#   spawn [NAME] [--mandate FILE|TEXT [--no-confirm]] [--cwd DIR] [--lane L] [--model M] [--effort E] [--fork UUID] [--dry-run]
#   spawn NAME --role <role word> [--front|--back] --mandate FILE|TEXT [...]   (a plain spawn that registers its name with stackshot: THE SPAWN GATE, below)
#   spawn NAME --project <page key> --role front|back [--surface sala|slack] [--mandate FILE|TEXT] [--lane L] [--model M] [--effort E] [--cwd DIR] [--dry-run]
#   spawn --suggest-name --project <page key> --role front|back [--prefix P] [--new]
#   spawn NAME --side (--fork-of AGENT | --project <page key> --item board#N) [--item board#N] [--agents A,B] [--mandate FILE|TEXT] [--lane L] [--model M] [--effort E] [--cwd DIR] [--dry-run]
#   spawn --suggest-name --side (--fork-of AGENT | --project <page key>)
#   spawn --list
#
# No NAME → throwaway `<prefix>-<YYYYMMDD>-<word>` (date in SALA_TZ); with --project, the suggested agent name (below). Model/
# effort unset → the session follows ~/.claude/settings.json. The name is applied with `/rename` typed into the pane (the CLI's
# own name flags do not reliably stick), then verified against the registry.
#
# THE SPAWN GATE (common.sh, THE SPAWN GATE; docs/stackshot-contracts.md, interface 34): every agent session this creates is on stackshot's project record BEFORE
# its pane exists. The record decides first (listed = yes). A name that is not on it is registered through `client.py post project-agent … --sender sala-spawn` when the spawn
# carries --role <word> (a plain spawn; --project K --role front|back for a project agent) and --mandate (--front|--back picks the side, default back), right before the pane is made;
# the pane starts only on stackshot's 200 and the record is read back. Any other answer (or stackshot not reached) prints stackshot's reason and exits 6 with NO pane. With no
# --role/--mandate the spawn is refused (exit 3) with the reason and the register command. THE EXCEPTIONS are a closed list (common.sh agent_gate_exempt): sala's shell
# session, a side session, an auto-generated throwaway name, and scratch-*, *-check-*, *-test-*, *-probe-*. Revive, recycle, adopt and restore create no session and never come here.
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
# SPAWN'S CHECKS; never fail-open, unlike a plain spawn's check, which is the same record-only gate):
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
#   · THE PROJECT RECORD ALONE (common.sh, THE PROJECT RECORD; docs/stackshot-contracts.md, interface 20):
#     stackshot's project record lists each project's agents with `front` true/false. It is asked of stackshot first (its client, `get projects-record`; lib/stackshot_record.py);
#     only when stackshot cannot be reached is the file copy ~/.local/state/stackshot/projects.json read, and its age is said. When the answer is fresh
#     (the copy: SALA_PROJECT_RECORD_MAX_AGE, 600 s) and has the project, it answers the check: the name on the map and `front` agreeing with --role
#     → listed (an agent registered through `client.py post project-agent` counts); the name absent → registered with stackshot when the
#     spawn carries --role/--mandate (THE SPAWN GATE below), else exit 3 as below; the other role → exit 1. No page is asked and no
#     pages.py is run: the page's own `agents:` block is stale by design and is not read.
#     A record that CANNOT answer (stackshot not reached and the copy missing, stale, unreadable, or no such project) FAILS CLOSED for any name the closed exception list does not
#     cover (agent_gate_exempt): exit 6 and no pane, "stackshot's project record cannot answer (<why>): … retry when it is fresh, or
#     SALA_AGENT_CHECK=off to start it unchecked". A spawn WITH --role/--mandate registers through `post project-agent` all the same (it
#     needs no fresh record to register); only its read-back needs one, and a read-back that cannot be made says so and that the name IS
#     registered (run the same spawn again). The exit 3 refusal of a name the record lists nowhere is on stderr, naming the register command and, on stdout, the marker line `REGISTER: <key>` followed by that
#     command (stackshot's `client.py post project-agent <key> <name> --role <part of the name after the project's name>
#     --front|--back --mandate "<first line>"`), so the web form can show "not listed on the project yet" with the command; nobody is
#     messaged (the older keeper message is gone: the spawn registers the name itself when it can). THE ONE COMMAND THAT NEEDS STACKSHOT:
#     `spawn --project` answers only through stackshot's project record, and stays fail-closed without it (SALA_AGENT_CHECK=off is the
#     only bypass, for every spawn). A plain spawn on a box with no stackshot at all (no record, no client: docs/running-without-stackshot.md)
#     has nothing to ask and is not checked; a rename and a side session need none of it.
#   · a back agent needs a mandate (it reads it at its first prompt and nobody briefs it); a front agent's is optional.
#   · THE START DIRECTORY: the CLI loads the CLAUDE.md of the directory a session starts in, so a back agent started
#     in $HOME read the FRONT rules and never a background brief kept elsewhere. SALA_BACK_CWD (default: unset) names the
#     directory whose CLAUDE.md is the background brief; with no --cwd a back agent starts there. Unset, it starts in $HOME, the same as a
#     front agent. Set but naming a directory this box does not have, the spawn is refused (a typo or an unmounted checkout
#     must not quietly start the agent under the front rules). An explicit --cwd wins for both; a side session and a plain spawn
#     are unchanged. A later wake or relaunch of a back agent asks the setting again (common.sh, THE FOLDER OF A BACK AGENT).
#     The pane map's cwd column records the directory, so `sala restore` recreates the session there; the dry
#     run's "cwd …" shows it.
#   · THE SURFACE (--surface sala|slack): where a front agent talks with the owner. `sala` (the default; no flag) is a session the owner reads in
#     sala; `slack` is a front agent that answers his Slack app messages. Only valid with --role front (a back agent is refused), and
#     not with --side. A slack agent starts in the directory SALA_SLACK_CWD names (the CLI loads that directory's CLAUDE.md, the Slack
#     brief, not the sala-pane rules of $HOME) when --cwd is not given; SALA_SLACK_CWD unset, or naming a directory this box does not have, refuses the
#     spawn with a message naming the key: it never falls back to another directory. The surface is the flag's, or, with no flag, the one the
#     project record gives the name (the entry `sessions tag --auto` copies onto the row later), so a registered Slack agent spawned without
#     --surface starts in the Slack brief's directory too; a --surface that conflicts with the record's is refused, naming both, and so is an entry whose
#     surface sala cannot use (a value it does not know, a back agent called slack: `tag --auto` would refuse the row), with or without --surface or --cwd. A record
#     that is missing, stale or does not list the name is no refusal: the flag alone decides, and SALA_SESSIONS=off does not stop the read. The pane map's cwd column records the directory, so
#     revive and `sala restore` start it there again. Its registry row carries `surface: slack` (a sala agent's row has no such field);
#     `sessions tag --auto` keeps it in step with the project record's agent entry. The register command the refusal prints carries `--surface slack` for it.
#   · a name already live (a tmux session, or a running claude registered under it) is refused as for any spawn.
# --dry-run runs every check and prints the plan ("[dry-run] would spawn …"), makes nothing, records nothing, calls no
# hook; the operation queue runs it as the verb's plan (lib/op.sh, `sala op spawn`, the one path a web request takes).
# THE REGISTER HOOK (SALA_SPAWN_REGISTER): once a project agent's session is up and mapped, the configured command runs
# with the name, page key, role and mandate file path as its four arguments and as SALA_SPAWN_NAME, SALA_SPAWN_PROJECT,
# SALA_SPAWN_ROLE, SALA_SPAWN_MANDATE_FILE (empty for a text mandate or none), plus SALA_SPAWN_MANDATE_LINE (the first
# line, ≤70 characters), SALA_SPAWN_UUID (the conversation) and SALA_SPAWN_LANE; its output goes to salamander-spawn.log. A
# hook that fails or hangs (60 s) is one ⚠ line: it never fails or undoes the spawn. Unset (the default) it is a no-op that
# logs `spawn-register: no hook configured`: the registration is the spawn gate's own `post project-agent` (THE SPAWN GATE).
#
# A SIDE SESSION (quick side conversations; docs/side-sessions.md; common.sh, THE SIDE SESSIONS): a short-lived session
# started in one step, on no page's agents map (no project/role checks, no gate: agent_gate_exempt), for the owner to talk to. Two starts:
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
# (--project … --role back) spawned while the back agents' lane rule is on (SALA_BACK_LANE_RULE=on) takes the rule's lane (the home lane while they stand at home), and
# so does a front agent (--role front) spawned while the rule's front step is engaged (it fired in the current weekly window).
# THE SESSION REGISTRY'S ID (phase 2): before the pane's claude starts, spawn makes (or finds) the registry row and puts its
# id in the pane's environment as SALA_SESSION_ID, so the session's SessionStart hook can name its row (the hook records only for the
# claude in that row's own pane: any other claude that inherited the id from the pane's shell, such as a throwaway on a private tmux
# server, names no row; lib/hook.sh); a spawn that does not come
# up takes the row back (see the comment at tmux new-session below). SALA_SESSIONS=off: no id, no export.
# A THROWAWAY'S SPAWNER: a spawn with no --project or --side, run by a Claude session, writes the
# caller's tmux session name onto the row as spawned_by (common.sh spawn_caller; docs/session-registry.md). `sala op retire NAME --from YOU` takes
# no words for exactly that row (lib/op.sh, op_own_retire_ok); a spawn from a plain shell, a human's pane or the queue records none.
# THE THROWAWAY TAG: the same spawn, whoever runs it, also writes throwaway=1 onto the row; any live session may
# then retire that row with no words, between turns. A spawn with a project, a role or a side flag never writes it (lib/op.sh, op_own_target_ok).
# The pane map gets the session's row on the way out (an honored add; the map is a ledger, see
# common.sh), so a crash before the next autosave can still map the pane to its conversation.

[ -x "$SALA_CLAUDE" ] || die "claude not found at $SALA_CLAUDE"

if [ "${1:-}" = "--list" ]; then
    printf '%-24s %-10s %s\n' NAME VERSION BRIDGE
    SLACK_NAMES=""; sessions_on && SLACK_NAMES=$(sessions_py slack-names 2>/dev/null | paste -sd' ' -)   # the registry's slack rows: marked [slack] at the end of their line
    export SLACK_NAMES
    _claude_pids_r _cps || :
    for pid in $_cps; do
        f="$SALA_REG_DIR/$pid.json"; [ -r "$f" ] || continue
        is_rc_child "$pid" && continue
        python3 -c "
import json, os
d=json.load(open('$f'))
mark = '  [slack]' if d.get('name') in os.environ.get('SLACK_NAMES', '').split() else ''
if d.get('tmux'): print('%-24s %-10s %s%s%s' % (d.get('name','?'), d.get('version','?'), d.get('bridgeSessionId') or '—', '  ⚠ parked → bg fork %s' % d['parkedJobId'][:8] if d.get('parkedJobId') else '', mark))" 2>/dev/null
    done | sort
    # tmux sessions whose claude exited/crashed: show them with the sidecar's conversation id
    tmux list-panes -a -F '#{session_name} #{pane_current_command} #{pane_pid}' 2>/dev/null | while read -r sess cmd ppid; do
        case "$cmd" in claude|node) continue ;; esac
        pgrep -x claude -P "$ppid" >/dev/null 2>&1 && continue
        [ "$sess" = "$SALA_RC_SESSION" ] && continue
        is_shell_session "$sess" && continue   # the web UI's shell drawer
        [ "$sess" = "0" ] && continue
        uuid=$(awk -F'\t' -v s="$sess" '$1==s {print $2; exit}' "$SALA_SIDECAR" 2>/dev/null)
        if is_sleeping "$sess"; then   # display only: its claude ended on purpose, so no "revive" is offered
            printf '%-24s %-10s %s\n' "$sess" "(sleeping)" "sleeping — its claude ended on purpose; not revived${uuid:+   (sidecar ${uuid:0:8}…)}$(case " $SLACK_NAMES " in *" $sess "*) printf '  [slack]';; esac)"
            continue
        fi
        printf '%-24s %-10s %s\n' "$sess" "(shell)" "claude exited — revive: salamander revive --only $sess${uuid:+   (sidecar ${uuid:0:8}…)}$(case " $SLACK_NAMES " in *" $sess "*) printf '  [slack]';; esac)"
    done | sort
    exit 0
fi

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
    local rf out
    record_file_r rf projects || return 1
    out=$(python3 -I - "$rf" "$SALA_PROJECT_RECORD_MAX_AGE" "$1" 2>/dev/null <<'PY'
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
    # THE CANDIDATES, in the order they are preferred: -main only for a front agent of a project that has no agent yet (the record says so, or the caller says the project is new: no page,
    # so no record can know it; a record that is missing, stale or does not list the project is no ground for -main), then random words. Each is free by sala's own check (name_taken: a tmux
    # session, a live claude, any project's map); stackshot's name check (agent_name_check, common.sh) then picks the first it calls valid for the project, and when it is unavailable
    # (a 404, no client, a connection error, not JSON, a timeout) the first candidate is the answer, as it was before the check existed.
    local -a cands=(); local picked crc dup c2
    if [ "$role" = front ] && [ $((${#p} + 5)) -le "$max" ] && { { [ "$known" = 1 ] && [ "${n:-0}" = 0 ]; } || { [ "$known" = 0 ] && [ "$isnew" = 1 ]; }; } && ! name_taken "$p-main"; then
        cands+=("$p-main")
    fi
    for ((i=0; i<40 && ${#cands[@]}<10; i++)); do
        w=${WORDS[RANDOM % ${#WORDS[@]}]}; tail="-$w"; cand="$p$tail"
        if [ "${#cand}" -gt "$max" ]; then cand="${p:0:$((max - ${#tail}))}"; cand="${cand%-}$tail"; fi
        dup=0; for c2 in ${cands[@]+"${cands[@]}"}; do [ "$c2" = "$cand" ] && dup=1; done
        [ "$dup" = 1 ] || name_taken "$cand" || cands+=("$cand")
    done
    if [ ${#cands[@]} -gt 0 ]; then
        picked=$(agent_name_check "$key" "${cands[@]}"); crc=$?
        case "$crc" in
            0) echo "$picked"; return 0 ;;
            2|3) # stackshot ANSWERED and calls none valid (3: one of them is already listed, i.e. ours): a numbered name would be one it was never asked about, possibly unusable
                 # (a retired, hidden or hub project, a prefix it does not know), so none is returned: its reasons are printed and the exit is nonzero
                 { echo "stackshot answered and calls none of the names it was asked about valid for $key:"; printf '%s\n' "$picked" | sed 's/^/   /'; } >&2
                 return 1 ;;
            *) echo "${cands[0]}"; return 0 ;;         # unavailable: sala's own suggestion, as before
        esac
    fi
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
    --brief|--prompt|--mandate|--cwd|--fork|--model|--effort|--no-confirm|--project|--role|--front|--back|--surface|--lane|--dry-run|--suggest-name|--side|--fork-of|--item|--agents|--prefix) ;;
    -*)  die "unknown first argument: $1" ;;
    *)   NAME="$1"; shift ;;
esac
case "$NAME" in *[.:\ ]*) die "invalid session name '$NAME' (no dots, colons, or spaces)";; esac
is_shell_session "$NAME" && die "'$NAME' is the web UI's shell session (SALA_SHELL_SESSION) — a Claude session cannot take its name; pick another name"

MANDATE=""; MKIND=""; CWD="$HOME"; MODEL=""; EFFORT=""; FORK=""; GO=0; PROJECT=""; ROLE=""; SURFACE_OPT=""; SURFACE_GIVEN=0; LANE_OPT=""; DRY=0; SUGGEST=0; PREFIX_OPT=""; NEW_OPT=0
SIDE=0; FORK_OF=""; ITEM=""; AGENTS=""; CWD_GIVEN=0; REG_ROLE=""; REG_SIDE=""
while [ $# -gt 0 ]; do
    case "$1" in
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
        --role)   ROLE="${2:-}";   shift 2 || die "--role needs front or back (with --project), or a role word for stackshot (a plain spawn, below)";;
        --front)  REG_SIDE=front; shift;;          # a plain spawn that registers its name with stackshot (THE SPAWN GATE, the header): which side; --back (the default) is a background agent
        --back)   REG_SIDE=back; shift;;
        --surface) SURFACE_OPT="${2:-}"; SURFACE_GIVEN=1; shift 2 || die "--surface needs sala or slack";;   # where a front agent talks with the owner (the header, THE SURFACE)
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
    [ "$SURFACE_GIVEN" = 0 ] || die "--side takes no --surface: a side session is on no page's agents map"
    [ -z "$FORK" ] || die "--side forks with --fork-of AGENT (its current conversation is found for you), not --fork UUID"
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
# A PLAIN SPAWN'S REGISTRATION ARGUMENTS (the header, THE SPAWN GATE): with no --project, --role is the role WORD stackshot lists the agent under (engineer, tests: the part of the name after the project's name),
# --front/--back (default back) its side; they only matter when the name is not on the project record yet, and --mandate then gives the line it is listed with. front|back belong to --project.
if [ "$SIDE" = 0 ] && [ -z "$PROJECT" ] && [ -n "$ROLE" ]; then
    case "$ROLE" in front|back) die "--role needs --project <page key> when it is front or back (a project agent); a plain spawn's --role is the role word stackshot lists the agent under (engineer, tests), with --front or --back for its side" ;; esac
    [[ $ROLE =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]] || die "--role takes a role word of letters, digits, . _ - (at most 32 characters, no leading dash), not '$ROLE'"
    REG_ROLE=$ROLE; ROLE=""
fi
[ -z "$REG_SIDE" ] || [ -z "$PROJECT" ] || die "--front and --back go with a plain spawn's registration; with --project the side is --role front|back"
[ -z "$REG_SIDE" ] || [ "$SIDE" = 0 ] || die "--front and --back are for a spawn that registers its name with stackshot; a side session is on no project record"
[ -z "$REG_SIDE" ] || [ -n "$REG_ROLE" ] || die "--front and --back go with --role <word>: they say which side the agent is listed on"
# THE PROJECT AGENT'S ARGUMENTS (the header): --project and --role go together; a back agent needs a mandate
if [ "$SIDE" = 0 ] && { [ -n "$PROJECT" ] || [ -n "$ROLE" ] || [ "$SUGGEST" = 1 ]; }; then
    [ -n "$PROJECT" ] || die "--role needs --project <page key> (<dir>/<slug>, e.g. projects/demo): a project agent is a session of a project page"
    [ -n "$ROLE" ] || die "--project needs --role front or --role back (front: a session ${SALA_OWNER_NAME} talks to, a top-level entry under agents:; back: a background agent, under background:)"
    case "$ROLE" in front|back) ;; *) die "--role takes front or back, not '$ROLE'";; esac
    page_key_ok "$PROJECT" || die "'$PROJECT' is not a page key: <dir>/<slug> with the dir one of ${SALA_PAGE_DIRS// /, } and the slug lowercase letters, digits and dashes (projects/site-redesign, projects/demo)"
fi
SURFACE=""   # slack only: a sala agent carries no surface (absent means sala), like stackshot's project record
if [ "$SURFACE_GIVEN" = 1 ]; then
    case "$SURFACE_OPT" in sala|slack) ;; *) die "--surface takes sala or slack, not '$SURFACE_OPT'";; esac
    [ -n "$PROJECT" ] && [ -n "$ROLE" ] || die "--surface goes with --project <page key> --role front: it says where a project's front agent talks with ${SALA_OWNER_NAME}"
    if [ "$SURFACE_OPT" = slack ]; then
        [ "$ROLE" = front ] || die "a slack agent is a front agent: --surface slack goes with --role front, not --role $ROLE"
        SURFACE=slack
    fi
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
REC_SURFACE=""   # the surface the project record gives this name (slack, sala), the one `sessions tag --auto` copies onto the row later: the start directory follows it, not the flag alone
if [ "$SIDE" = 0 ]; then   # read-only on the record file, so SALA_SESSIONS=off (registry writes and the publish) does not matter here
    record_file_r REC_FILE projects || true   # stackshot's own answer; the file copy only when stackshot does not answer (record_file_r, common.sh)
    REC_SURFACE=$(sessions_py record-surface "$NAME" ${PROJECT:+--project "$PROJECT"} --record "$REC_FILE" --record-max-age "$SALA_PROJECT_RECORD_MAX_AGE" 2>&1); rsrc=$?
    if [ "$REC_SRC" = live ]; then REC_FILE_SAID="stackshot's own answer"; else REC_FILE_SAID=$SALA_PROJECT_RECORD; fi
    case "$rsrc" in
        0) ;;
        5) die "the project record ($REC_FILE_SAID) lists '$NAME' with a surface sala cannot use, so it is not spawned (sessions tag --auto would refuse its row): ${REC_SURFACE#sessions record-surface: }" ;;
        *) REC_SURFACE="" ;;   # not on a map (3), a missing, stale or unreadable record (4), or any other failure: the flag alone decides; a spawn does not depend on stackshot being reachable
    esac
fi
if [ -n "$REC_SURFACE" ]; then
    [ "$SURFACE_GIVEN" = 0 ] || [ "$SURFACE_OPT" = "$REC_SURFACE" ] || die "--surface $SURFACE_OPT conflicts with the project record, which lists '$NAME' with surface $REC_SURFACE (sessions tag --auto would put $REC_SURFACE back on its row): drop --surface, or change the agent's entry in the record first"
    if [ "$REC_SURFACE" = slack ]; then
        [ "$ROLE" != back ] || die "a slack agent is a front agent: the project record lists '$NAME' with surface slack, so --role back is refused"
        SURFACE=slack
    fi
fi
if [ "$ROLE" = back ] && [ "$CWD_GIVEN" = 0 ] && [ -n "${SALA_BACK_CWD:-}" ]; then   # a background agent starts where the background brief is (the header); --cwd always wins
    BACK_DIR="${SALA_BACK_CWD/#\~/$HOME}"
    [ -d "$BACK_DIR" ] || die "a back agent starts in the background brief's directory, which does not exist here: $BACK_DIR (SALA_BACK_CWD names it; it loads the background brief from there, not the front rules from \$HOME). Create or clone the directory, fix SALA_BACK_CWD, or pass --cwd DIR"
    CWD="$BACK_DIR"
fi
if [ "$SURFACE" = slack ] && [ "$CWD_GIVEN" = 0 ]; then   # a Slack agent starts where the Slack brief is (the header, THE SURFACE); --cwd always wins, and there is no other fallback
    [ -n "${SALA_SLACK_CWD:-}" ] || die "a Slack agent starts in the Slack brief's directory, and SALA_SLACK_CWD (the config key) is not set on this machine: set it to the directory whose CLAUDE.md is the Slack brief, or pass --cwd DIR. It does not start in \$HOME, which would load the sala-pane rules"
    SLACK_DIR="${SALA_SLACK_CWD/#\~/$HOME}"
    [ -d "$SLACK_DIR" ] || die "a Slack agent starts in the Slack brief's directory, which does not exist here: $SLACK_DIR (SALA_SLACK_CWD names it; it loads the Slack brief from there, not the sala-pane rules from \$HOME). Create or clone the directory, fix SALA_SLACK_CWD, or pass --cwd DIR"
    CWD="$SLACK_DIR"
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
mandate_line() {  # [width] → the mandate's first non-blank line, one line, a heading's # stripped, at most 70 characters (the register command's; a register call takes up to 600: register_line); empty for none
    local s
    if [ -n "$MFILE" ]; then s=$(grep -m1 -v '^[[:space:]]*$' "$MFILE" 2>/dev/null); elif [ -n "$MTEXT" ]; then s=$(printf '%s\n' "$MTEXT" | grep -m1 -v '^[[:space:]]*$'); else return 0; fi
    s=$(printf '%s' "$s" | tr '\r\n\t' '   ' | sed 's/^ *#* *//; s/  */ /g; s/ $//')
    python3 -c 'import sys; print(sys.argv[1][:int(sys.argv[2])])' "$s" "${1:-70}" 2>/dev/null || printf '%s\n' "${s:0:${1:-70}}"   # characters, not bytes: a Korean line is cut whole
}
register_line() {  # → the line the register call lists the agent with: the mandate's first line, at most 600 characters (stackshot's limit), no control character or backslash
    mandate_line 600 | tr -d '\000-\037\177' | tr '\\' '/'
}
shell_dq() {  # <text> → the text double-quoted for a shell (backslash, ", $ and ` escaped)
    printf '"%s"' "$(printf '%s' "$1" | sed 's/[\\"$`]/\\&/g')"
}
register_cmd() {  # <page key> <front|back, or empty for either> <name> <mandate line> <the project's -main agent, or empty> [slack] → stackshot's register command (words only: sala never runs it); a slack agent's carries --surface slack
    local key=$1 r=$2 name=$3 line=$4 pmain=${5:-} sf=${6:-} role='<role>' pre flag rel
    stackshot_rel_r rel "${SALA_STACKSHOT_DIR:-$HOME/stackshot}" client   # the client's path below the checkout, as this box has it (lib/stackshot-path.sh)
    pre=${pmain%-main}   # the project's name is its -main agent's without -main; the role is the part of NAME after it
    if [ -n "$pmain" ] && [ "$pre" != "$pmain" ] && [ "${name#"$pre"-}" != "$name" ] && [ -n "${name#"$pre"-}" ]; then role=${name#"$pre"-}; fi
    case "$r" in front) flag=--front ;; back) flag=--back ;; *) flag='--front|--back' ;; esac
    printf 'python3 ~/stackshot/%s post project-agent %s %s --role %s %s%s --mandate %s' "$rel" "$key" "$name" "$role" "$flag" "${sf:+ --surface $sf}" "$([ -n "$line" ] && shell_dq "$line" || echo '"<one line>"')"
}
refuse_unlisted() {  # <page key> <role> <what the record said> [the project's -main agent] — the refusal (stderr), the marker and the register command (stdout), exit 3; nobody is messaged
    local line cmd; line=$(mandate_line); cmd=$(register_cmd "$1" "$2" "$NAME" "$line" "${4:-}" "$SURFACE")
    echo "✗ '$NAME' is not on the agents map of $1 ($3): a project agent is registered with stackshot before its session is made. Register it, then spawn again: $cmd" >&2
    echo "REGISTER: $1"
    echo "$cmd"
    spawn_log "refused: not listed on $1 ($3)"
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

# THE SPAWN GATE (common.sh, THE SPAWN GATE; the header): the record decides first, stackshot's register call is the yes, the pane starts only on it.
GATE_NOTE=""   # what the gate said, for the plan and the result (empty for an exception and for a box without stackshot)
spawn_can_register() { [ -n "$MFILE$MTEXT" ] && stackshot_client >/dev/null 2>&1; }   # a mandate to list the agent with, and a client to ask
spawn_gate_refuse() {  # <exit code> <message> → the refusal on stderr, a log line, no pane
    echo "✗ $2" >&2; spawn_log "refused: $2"; exit "$1"
}
GATE_REG=""    # "<page key>|<role word>|<front|back>" when the name is not on the record and stackshot is to list it: decided with the other checks, done right before the pane is made (spawn_register_do)
spawn_register_plan() {  # <project> <role word> <front|back> → the decision only: nothing is asked yet (a dry run and every later check still come first)
    GATE_REG="$1|$2|$3"
    LISTED="not on the record yet: stackshot is asked to list it on $1 as a $3 agent (role $2; post project-agent, label $SALA_SPAWN_SENDER) right before the pane is made"; GATE_NOTE="$LISTED"
}
REGISTERED_KEY=""   # the project NAME was registered on (and read back) by THIS run
spawn_registered_note() {  # the exit trap: registered, but no session came up (the pane could not be made, claude did not start) → say so and how to go on; the retry is safe
    [ -n "$REGISTERED_KEY" ] && [ -z "${SPAWN_UP:-}" ] || return 0
    echo "⚠ '$NAME' is registered with stackshot on $REGISTERED_KEY, but no session came up: run the same spawn again (same --role, --front/--back and --mandate): a name the record lists just starts its pane, and nothing is registered twice" >&2
    spawn_log "registered '$NAME' on $REGISTERED_KEY, but no session came up: a repeat of the same spawn starts it"
}
spawn_register_do() {  # → stackshot lists NAME (the real yes) and the record shows it (read back), or the spawn stops with exit 6 and no pane made
    [ -n "$GATE_REG" ] || return 0
    local key=${GATE_REG%%|*} rest=${GATE_REG#*|} word side line; word=${rest%%|*}; side=${rest#*|}; line=$(register_line)
    agent_register "$key" "$NAME" "$word" "$side" "$line" "$SURFACE" || spawn_gate_refuse 6 "stackshot did not register '$NAME' on $key, so no session was made: $AR_WHY"
    if ! agent_record_read_back "$key" "$NAME" "" "$side"; then
        # the read-back could not be made because the PUBLISHED record cannot answer (stale, missing, unreadable) and stackshot's live answer was not there either: stackshot did say yes, so the
        # name IS registered. Say that, and what to do (the same spawn again once the record is fresh), instead of a record that "does not show it".
        if [[ $ARB_WHY != *"stackshot's live answer"* ]]; then
            rec=$(project_record_agent "$key" "$NAME" "$side"); rrc=$?
            [ "$rrc" != 1 ] || spawn_gate_refuse 6 "stackshot registered '$NAME' on $key (${AR_NOTE:-ok}), but sala cannot read it back because stackshot's project record cannot answer ($rec): the name IS registered, no session was made; run the same spawn again once the record is fresh (it is listed then, so the pane simply starts and nothing is registered twice)"
        fi
        spawn_gate_refuse 6 "stackshot answered the registration of '$NAME' on $key (${AR_NOTE:-ok}), but the record does not show it ($ARB_WHY): no session was made; run the same spawn again (stackshot answers a repeat with the same side and mandate with the same 200), or check it with: python3 $(stackshot_client) get project $key"
    fi
    REGISTERED_KEY=$key   # from here a spawn that ends without a pane says the name is registered (spawn_registered_note, the exit trap)
    LISTED="registered with stackshot just now on $key as a $side agent (role $word; read back)"; GATE_NOTE="$LISTED"
    spawn_log "registered '$NAME' on $key ($side, role $word, label $SALA_SPAWN_SENDER): ${AR_NOTE:-ok}"
    echo "   registered with stackshot on $key as a $side agent (role $word), read back from the record"
}
spawn_refuse_plain() {  # <why the record did not list it> → the refusal of a plain spawn of a name that is not on the record: the reason and the register command, exit 3 (REGISTER marker as for a project spawn when the project is known)
    local hub why=$1 line cmd note="" pmain; line=$(mandate_line)
    echo "✗ '$NAME' is not on stackshot's project record ($why): a session made for a project's work is registered with stackshot before its pane exists. Either spawn it with the registration (spawn $NAME --project <page key> --role front|back --mandate <one line>, or spawn $NAME --role <role word> [--front|--back] --mandate <one line>), or give it a throwaway's name (scratch-*, *-check-*, *-test-*, *-probe-*, or no name at all), or make it a side conversation (--side)." >&2
    if hub=$(project_for_name "$NAME"); then
        pmain=$(project_record_agent "$hub" "$NAME" 2>/dev/null | sed -n 2p)   # the project's -main agent: the role is the part of NAME after its name
        cmd=$(register_cmd "$hub" "" "$NAME" "$line" "$pmain")
        echo "   (register it with stackshot first; the command below leaves the side open: --front for a front agent, --back for a background one)" >&2
        echo "REGISTER: $hub"; echo "$cmd"
    else note=" (no project of the record owns the name: $hub)"; echo "   $note" >&2; fi
    spawn_log "refused: '$NAME' is not on the project record ($why)$note"
    exit 3
}

# THE LANE (Tue Oct 13th 2026; common.sh, lanes): a new session launches on the default lane (`sala lane default`),
# recorded nowhere — it follows the default until `sala lane <lane> NAME` gives it a lane of its own; --lane L launches on L
# and records the row at once. A lane that cannot launch (its key file or config directory gone) is refused
# here, before the tmux session is made and before stackshot is asked about the name (a refusal the box can give alone
# never costs a stackshot call).
# THE BACK AGENTS' LANE RULE (common.sh): a background agent spawned while the rule is on lands on the rule's lane (the home lane while the back agents stand at home)
# (as --lane would: recorded, so every relaunch keeps it, and the rule's move home finds it). An explicit --lane wins; a front agent, a side session and
# a throwaway are not the rule's; a Fable model is left on the default when the rule's lane cannot run Fable; a rule lane that is dormant or not ready is skipped.
# A FRONT agent (--role front, not --side) spawned while the rule's front step is engaged takes the rule's lane the same way (back_lane_front_spawn_lane); a Fable model
# that lane cannot run is launched on SALA_FALLBACK_FABLE_MODEL instead (the front step's swap, which cannot leave a front agent behind), and the note says so.
BACK_RULE_NOTE=""
if [ -z "$LANE_OPT" ] && [ -n "$PROJECT" ] && [ "$ROLE" = back ] && [ "$SIDE" = 0 ] && BL_SPAWN=$(back_lane_spawn_lane); then
    if model_is_fable "$MODEL" && ! lane_runs_fable "$BL_SPAWN"; then
        BACK_RULE_NOTE="the back agents' lane rule has them on the $(lane_shown "$BL_SPAWN") lane, which cannot run $MODEL: this one takes the default lane"
    else LANE_OPT=$BL_SPAWN; BACK_RULE_NOTE="the back agents' lane rule has them on the $(lane_shown "$BL_SPAWN") lane: this one launches there (--lane overrides)"; fi
fi
if [ -z "$LANE_OPT" ] && [ -n "$PROJECT" ] && [ "$ROLE" = front ] && [ "$SIDE" = 0 ] && BL_SPAWN=$(back_lane_front_spawn_lane); then
    LANE_OPT=$BL_SPAWN; BACK_RULE_NOTE="the lane rule's front step is engaged and has the front agents on the $(lane_shown "$BL_SPAWN") lane: this one launches there (--lane overrides)"
    if model_is_fable "$MODEL" && ! lane_runs_fable "$BL_SPAWN"; then
        MODEL=$SALA_FALLBACK_FABLE_MODEL; BACK_RULE_NOTE="$BACK_RULE_NOTE; the $(lane_shown "$BL_SPAWN") lane cannot run Fable, so it launches on $MODEL"
    fi
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
# THE FABLE RULE (common.sh, lane_runs_model): a Fable model launches only on the Ultra lane; a lane the rules above picked has already swapped it
lane_runs_model "$LANE" "$MODEL" || die "$(lane_fable_refusal "$LANE"): spawn with --lane ${SALA_FABLE_LANES%% *}, or another model (--model opus)"

[ "$DRY" = 1 ] || ledger_frozen_die spawn   # a recycle or reboot holds the pane map: nothing half-made; a dry run only looks
tmux has-session -t "=$NAME" 2>/dev/null && die "tmux session '$NAME' already exists"   # '=': exact, not a prefix (demo vs demo-extra)
_claude_pids_r _cps || :
for pid in $_cps; do   # a running claude elsewhere already carrying the name (e.g. a pane renamed by hand)
    registry_field_r _rn "$pid" name; [ "$_rn" = "$NAME" ] && die "'$NAME' is already the name of a live session (pid $pid) — pick another, or salamander rename it first"
done
LISTED=""
spawn_record_refuse() {  # <why the record cannot answer> <what it was asked> → exit 6, no pane: a name the exception list does not cover is never started on a guess
    spawn_gate_refuse 6 "stackshot's project record cannot answer ($1), so sala cannot tell $2 and starts no pane: retry when it is fresh (stackshot rewrites it every few minutes), or SALA_AGENT_CHECK=off to start it unchecked"
}
if [ "$SIDE" = 1 ]; then
    # a side session is on no agents map (the header): nothing to list and nothing to ask; a discuss start is scoped to its project, which the board item names
    :
elif [ -n "$PROJECT" ]; then
    # THE PROJECT SPAWN'S CHECKS (common.sh): stackshot's project record ALONE (THE SPAWN GATE: listed = yes; not listed with a mandate = stackshot is asked to list it, and the pane
    # starts only on its yes). A record that cannot answer (missing, stale, unreadable, no such project) is no answer: the spawn fails closed (exit 6, no pane) unless it carries
    # --role and --mandate, which register through stackshot without reading the record first. No page is asked.
    if [ "${SALA_AGENT_CHECK:-on}" = off ]; then LISTED="not checked (SALA_AGENT_CHECK=off)"
    elif exempt=$(agent_gate_exempt "$NAME" 0 "$GENERATED"); then
        LISTED="not checked ($exempt)"; spawn_log "gate: '$NAME' is exempt ($exempt)"
        # the exemption skips the REQUIREMENT to be on the record (no registration, no page check), never the role of a name the record DOES list: a *-test-* name that is
        # a back agent there is not started as a front agent (a record that cannot answer, or does not list the name, changes nothing)
        rec=$(project_record_agent "$PROJECT" "$NAME" "$ROLE"); rrc=$?
        case "$rrc" in
            0) LISTED=$(sed -n 1p <<< "$rec"); spawn_log "project record: exempt '$NAME' is listed on $PROJECT ($ROLE)" ;;
            5) spawn_log "refused: $rec"; die "$rec — a spawn takes the role the record gives: --role $([ "$ROLE" = front ] && echo back || echo front) (or change the page's line first); the exemption of a throwaway's name does not skip this" ;;
        esac
    else
        rec=$(project_record_agent "$PROJECT" "$NAME" "$ROLE"); rrc=$?
        case "$rrc" in
            0) LISTED=$(sed -n 1p <<< "$rec"); spawn_log "project record: '$NAME' is listed on $PROJECT ($ROLE)" ;;
            3) pmain=$(sed -n 2p <<< "$rec")
               if spawn_can_register; then spawn_register_plan "$PROJECT" "$(agent_role_word "$NAME" "$pmain")" "$ROLE"
               else refuse_unlisted "$PROJECT" "$ROLE" "$(sed -n 1p <<< "$rec")${pmain:+; main agent: $pmain}" "$pmain"; fi ;;
            5) spawn_log "refused: $rec"; die "$rec — a spawn takes the role the record gives: --role $([ "$ROLE" = front ] && echo back || echo front) (or change the page's line first)" ;;
            *) spawn_log "project record: no answer ($rec)"
               if spawn_can_register; then   # the record cannot say, stackshot can: it is asked to list the name (a repeat with the same side and mandate answers 200), and the read-back shows it
                   spawn_register_plan "$PROJECT" "$(agent_role_word "$NAME" "")" "$ROLE"
               else spawn_record_refuse "$rec" "whether '$NAME' is registered on $PROJECT"; fi ;;
        esac
    fi
else
    # A PLAIN SPAWN (THE SPAWN GATE): an exception (the closed list, common.sh agent_gate_exempt) skips the check; any other name is decided from the record alone.
    # Listed = yes. Not listed: spawned with --role <word> and --mandate it is registered (the project the one whose name the NAME starts with), else refused with the reason and the
    # register command. A record that cannot answer fails closed (exit 6, no pane), as a project spawn's does. A box with no stackshot at all (no record, no client) has nothing to ask.
    if exempt=$(agent_gate_exempt "$NAME" 0 "$GENERATED"); then spawn_log "gate: '$NAME' is exempt ($exempt)"
    elif [ "${SALA_AGENT_CHECK:-on}" != off ] && stackshot_present; then
        rec=$(project_record_agent "" "$NAME"); rrc=$?
        case "$rrc" in
            0) GATE_NOTE=$(sed -n 1p <<< "$rec"); spawn_log "project record: '$NAME' is $GATE_NOTE" ;;
            3) if [ -n "$REG_ROLE" ] && spawn_can_register; then
                   hub=$(project_for_name "$NAME") || spawn_gate_refuse 6 "'$NAME' is not on stackshot's project record and sala cannot tell which project to list it on ($hub): spawn it with --project <page key> --role front|back --mandate <one line>"
                   spawn_register_plan "$hub" "$REG_ROLE" "${REG_SIDE:-back}"
               else spawn_refuse_plain "$(sed -n 1p <<< "$rec")"; fi ;;
            *) spawn_log "project record: no answer ($rec)"
               if [ -n "$REG_ROLE" ] && spawn_can_register; then   # the record cannot say which project owns the name, so the caller must
                   spawn_gate_refuse 6 "'$NAME' cannot be registered: stackshot's project record cannot answer ($rec), so sala cannot tell which project to list it on; spawn it with --project <page key> --role front|back --mandate <one line>, or retry when the record is fresh"
               fi
               spawn_record_refuse "$rec" "whether '$NAME' is registered" ;;
        esac
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
    echo "[dry-run] would spawn '$NAME'${PROJECT:+ as a $ROLE agent${SURFACE:+ on the $SURFACE surface} of $PROJECT (on its agents map: $LISTED)}${SIDE_KIND:+ as a side session ($([ "$SIDE_KIND" = fork ] && echo "a fork of $FORK_OF" || echo "a fresh start about $ITEM of $SIDE_PROJECT")${ITEM:+, item $ITEM}; on no agents map; its write-up summary goes to $SIDE_TO)} on the $(lane_shown "$LANE") lane${LANE_OPT:+ (recorded)}, cwd $CWD, model ${MODEL:-global default} / effort ${EFFORT:-global default}${FORK:+, forked from $FORK}"
    if [ "$SIDE" = 1 ]; then echo "[dry-run] mandate: written to $SIDE_MFILE and read by the session ($([ "$GO" = 1 ] && echo "then it starts on it; nobody confirms" || echo "it waits for a confirmation"))${AGENTS:+, naming the agents $AGENTS}${MANDATE:+, with your ${MFILE:+file $MFILE}${MTEXT:+text} appended}"
    elif [ -n "$MFILE" ]; then echo "[dry-run] mandate: the file $MFILE, read by the session ($([ "$GO" = 1 ] && echo "then it starts on it; nobody confirms" || echo "it waits for a confirmation")): $(mandate_line)"
    elif [ -n "$MTEXT" ]; then echo "[dry-run] mandate: the text typed as the first message: $(mandate_line)"
    else echo "[dry-run] mandate: none"; fi
    [ -z "$GATE_NOTE" ] || [ -n "$PROJECT" ] || echo "[dry-run] gate: '$NAME' is $GATE_NOTE"
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
        echo "- Before this conversation ends you MUST run \`sala side done\`. It records the write-up and sends \`$SIDE_TO\` a one-line pointer: the FIRST line of your summary, with the item and page, in at most 200 characters. Put the gist in that first line; the rest of the summary does not travel, so the full detail belongs on the board item and the project page. (A summary sent to a project page key, \`--summary-to projects/<slug>\`, goes whole.)"
        echo "      sala side done${ITEM:+ --item $ITEM} --summary \"<the gist in one first line, then any detail; written for $SIDE_TO>\""
        echo "  It succeeds only when (1) the board item${ITEM:+ $ITEM} changed since you started: record what was decided on it through the stackshot connector (if you read it there, pass its \`updated\` as \`--item-updated <epoch or ISO time>\`), (2) the project page${SIDE_PROJECT:+ \`$SIDE_PROJECT\`} has a timeline line with your name, \`$NAME\`, as its source, and (3) the pointer is sent (\`sala side done\` sends it itself; if the receiver cannot take it you are told and the marker is still written). It says what is missing; fix that and run it again."
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

spawn_register_do   # THE SPAWN GATE: stackshot's yes comes BEFORE any pane or registry row exists (no pane to take back when it says no or the read-back fails)
PANE=$(tmux_win_t "$NAME" 0); SIDE_T0=$(date +%s)
[ "$SIDE" = 0 ] || side_write_mandate || die "could not write the side session's mandate to $SIDE_MFILE"
# THE SESSION'S ID (phase 2): the registry row is made BEFORE the pane's claude starts, and its id goes into the pane's
# environment as SALA_SESSION_ID (tmux new-session -e: the pane's shell, so every later claude typed there carries it, a recycle's
# resume included; and on the launch line, for a tmux without -e), so the session's own SessionStart hook (`salamander hook
# session-start`) can name its row. The hook acts on the id only for the claude that is in the row's own pane (a claude on another tmux
# server, in another session, pane or window or outside tmux inherits the id too and is refused; lib/hook.sh). Nothing when SALA_SESSIONS=off or the registry fails: the hook then finds the row by the
# tmux session name. A spawn that does not come up takes the row back (the exit trap below); a kill leaves it for `sessions --check`.
SPAWN_SID=$(sessions_prepare "$NAME" "$NAME" "$CWD" 2>/dev/null); SPAWN_UP=""
trap 'spawn_registered_note; [ -z "$SPAWN_UP" ] && [ -n "$SPAWN_SID" ] && sessions_abandon "$SPAWN_SID"' EXIT
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
if [ -n "$PROJECT" ] && [ -n "$MAPPED" ]; then sessions_set "$NAME" "project=$PROJECT" "role=$ROLE" ${SURFACE:+"surface=$SURFACE"}; fi   # the session registry's row (phase 1): never fails the spawn
if [ -z "$PROJECT" ] && [ "$SIDE" = 0 ] && [ -n "$MAPPED" ]; then
    # a bare spawn of a name a project lists (its agents map, through stackshot's project record) is that project's agent: its row takes the project and
    # role from the record (sessions.py tag --auto), so the back agents' lane rule and the published registry count it. Any other bare spawn is a
    # throwaway: its row carries the throwaway tag and records the Claude session that started it (common.sh, A THROWAWAY'S SPAWNER)
    if sessions_on && sessions_tag "$NAME" --auto >/dev/null 2>&1; then :
    else SPAWNER=$(spawn_caller); sessions_set "$NAME" "throwaway=1" ${SPAWNER:+"spawned_by=$SPAWNER"}; fi
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
[ -n "$PROJECT" ] && echo "   project : $PROJECT — $ROLE agent${SURFACE:+ ($SURFACE surface)} (on its agents map: $LISTED)"
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
# THE CLAUDE.AI TITLE: claude.ai names the bridge session once, when it is made, and a pane started with --name never renames it, so it can
# keep an auto-generated name. Set it to the pane's name now that the bridge id is known (rc --titles, lib/rc.sh). Best effort and bounded: no bridge
# id yet or no claude.ai login file = nothing; a failure is one warning line and never fails the spawn.
if [ -n "${rbridge:-}" ] && [ "$rbridge" != "—" ] && [ -r "$HOME/.claude/.credentials.json" ]; then
    tout=$(timeout --kill-after=2 8 "$SALA_BIN" rc --titles --apply --only "$NAME" 2>&1 </dev/null) \
        || echo "   ⚠ the claude.ai title was not set to '$NAME' ($(printf '%s\n' "$tout" | grep -v '^ok ' | head -1 | cut -c1-160)): sala rc --titles --apply --only $NAME retries it"
fi
if [ -n "${rbridge:-}" ] && [ "$rbridge" != "—" ]; then echo "   remote  : https://claude.ai/code/${rbridge}"
elif ! lane_rc "$LANE"; then echo "   remote  : none — no Remote Control on the $(lane_shown "$LANE") lane (no claude.ai login behind it)"
else echo "   remote  : no bridge yet — check /rc in the pane, or run /remote-control there"; fi
[ "${rname:-}" = "$NAME" ] || echo "   ⚠ session name is '${rname:-unset}', not '$NAME' — run /rename $NAME in the pane"
[ -n "$MAPPED" ] || echo "   ⚠ the pane map has no row for '$NAME' yet ($([ -n "${ruuid:-}" ] && echo "the write failed, see above" || echo "no registry entry yet")) — a reboot could not bring it back; once it is up, run: salamander adopt $NAME"
[ -n "$PROJECT" ] && spawn_register   # THE REGISTER HOOK (the header): after the session is up and mapped; a failure is one ⚠ line, never the exit status
exit 0   # the session is up and verified above; nothing after this line may decide the exit status (Why: a trailing `[ … ] &&` once returned 1 on every good spawn)
