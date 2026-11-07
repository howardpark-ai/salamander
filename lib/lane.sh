# lib/lane.sh — which account or key each pane's claude runs on: the lanes (Tue Oct 13th 2026; common.sh, "lanes").
#
#   salamander lane                                                 the table: the default lane, the lane fields, then every session — the
#                                                                   lane recorded for it and the one its claude runs on now
#   salamander lane --list | --json                                 the lane fields alone: per lane its provider, client, org,
#                                                                   billing, plan, account, credential, region and status — aligned, or as JSON
#   salamander lane <lane> <session>… [--dry-run] [--not-master]    record the lane for those sessions, then relaunch them on it (resumed,
#                                                                   same conversation); one already running on it is left alone
#   salamander lane <lane> --all      [--dry-run] [--not-master]    every session sala relaunches, and the default for new ones: one recycle
#   salamander lane default <lane>    [--dry-run] [--not-master]    the default alone: sessions without a lane of their own take it at their
#                                                                   next relaunch; nothing relaunched now
#   salamander lane dormant <lane> [--reason TEXT] [--dry-run] [--no-fallback]   THE DORMANT RECORD: mark a lane dormant by hand (nothing can run on it for
#                                                                   now); the record is common.sh's, the watch keeps it. Held until `lane active`. With the lane fallback on
#                                                                   (SALA_LANE_FALLBACK_AUTO) the sessions on it are also queued onto its fallback (below); --no-fallback records only
#   salamander lane fallback <lane> [--dry-run]                     THE LANE FALLBACK: move everything on a DORMANT lane — its sessions (the master by the rescue
#                                                                   route), the default if it was the default, and the jobs from then on — to the lane SALA_LANE_FALLBACK names for it,
#                                                                   when that lane is active and ready; --dry-run prints the moves. Exit 4: no usable fallback
#   salamander lane active <lane>   [--dry-run]                     mark it active again (the only way back for the API lane, api and sdk)
#   salamander lane --migrate         [--dry-run]                   THE RENAME'S MIGRATION: rewrite the old name of a renamed lane (awsplatform → aws-platform) in lanes.tsv,
#                                                                   lane-default, lane-state.tsv and the session registry, once (idempotent, atomic, a backup beside each file;
#                                                                   common.sh lane_migrate). Nothing needs it to work: every reader reads the old name as the new one
#   salamander lane --rescue <lane>   [--dry-run] [--force]         THE RESCUE: another session moves the MASTER (SALA_MASTER) to
#                                                                   <lane> when the master's own lane is out; refused while that lane looks
#                                                                   fine to sala (--force overrides, said in the log)
#   salamander lane <lane> <session>… --rescue                      the switch, with a stale background-task row not holding the pane
#                                                                   (lib/revive.sh, THE RESCUE)
#
# Lanes: subscription-1 (displayed Ultra; the old word max still works: the login in ~/.claude, nothing on the launch line), api (the key, read by the pane's own shell from
# SALA_LANE_API_KEY_FILE), subscription-2 (displayed Team; the old word team still works: a second login, in its own CLAUDE_CONFIG_DIR), sdk (an alias of api with client
# claude-agent-sdk: the same key through the Agent SDK, the pane runs `salamander sdk-pane` instead of
# `claude`, while the API credit lasts: the shared record, lib/api_credit.py), bedrock (Claude on Amazon Bedrock through the AWS profile SALA_LANE_BEDROCK_PROFILE; its
# env on the pane's launch line only, no secret in it; as api, no Remote Control and --mcp-config instead of the claude.ai
# connectors), aws-platform (Claude Platform on AWS, the Anthropic-operated API signed with the same kind of AWS profile,
# SALA_LANE_AWSPLATFORM_PROFILE, and a workspace id; `env -u` first for the variables that would change its routing; as bedrock, no
# Remote Control and --mcp-config).
# The lane fields (common.sh, "THE LANE FIELDS") are what --list and --json print. A switch is a relaunch — the CLI
# picks its auth when it starts — and never a re-auth: the login in ~/.claude is untouched by a per-process key, and a
# config directory keeps its own. This replaces the hand-made ~/api-session/lane-relaunch.sh (`sala lane api <session>`)
# and master-to-team.sh (`sala lane subscription-2 <master>`; `team` is read as its old word).
#
# HOW IT RELAUNCHES — through the machinery every relaunch uses, with that machinery's guards (a busy pane deferred and
# retried, SALA_NO_RELAUNCH left alone, the invoking pane last, one driver at a time), nothing of its own:
#   --all        `recycle --force`: the detached driver — the sweep of every other pane, then the invoking pane by the
#                self-worker once it is idle; the freeze, the set and its posts, the post-recycle hook. A relaunch of every
#                pane IS a recycle, so the board hears of it as one.
#   <session>…   `revive --force --only A --only B`: the direct sweep of just those panes (its retry worker for the transient
#                skips, the deferred list for background work), then `revive --self` when the invoking pane is among them —
#                the master, or whoever runs this, goes last. No post-recycle hook: the board is not told a recycle happened.
# THE RECORD COMES FIRST: the lane goes into lanes.tsv (and, with --all, lane-default) under the recycle lock, before any
# pane is touched, so the relaunch that follows and every later one (a recycle, the boot hook, a retry worker, watch's
# deferred relaunch, restore) launch on it. A relaunch that cannot start now leaves the record in place and says so.
# A lane whose prerequisites are missing is refused before anything is recorded (lane_check): forty panes relaunched onto
# it would sit at a login screen or die at their shells. --dry-run prints what would be recorded and relaunched, and the
# NAMES of the variables the lane puts on the launch line — never a value: the key is read by the pane's shell from its
# file when the line runs, and is in that claude's environment and nowhere else.
# THE DORMANT RECORD (common.sh): a lane with nothing to run on — the Team seat gone, the subscription-1 login no longer on its plan, the API
# credit used up — is dormant, with its reason and since. A switch (`lane <lane> <session>…`, `--all`), `lane default <lane>` and the
# rescue REFUSE to move onto a dormant lane, with a plain message; the table shows it with its reason and since; sessions already on
# it stay put (nothing relaunches them). `lane dormant` / `lane active` set it by hand and write only the record (no relaunch, so no
# queue: --dry-run says what would be written and writes nothing).
# THE LANE FALLBACK (Sat Oct 31st 2026; common.sh, "THE AUTOMATIC LANE FALLBACK"): a dead lane has an automatic mechanism that moves
# its sessions to a fallback live one, and they stay there. When a lane goes dormant (the watch's detection,
# or `lane dormant` by hand) the move is QUEUED, as every fleet operation is — `sala op lane fallback <lane> --from sala-watch --words
# "<the standing words>"` — and runs in a transient sala-op unit under the recycle lock, with ONE Slack post for the batch (the lane, the fallback,
# each session, each model change, the default). `lane fallback` itself does the move: every session whose running lane is the dead
# one (recorded on it, or on "(default)" while the default is that lane) is recorded on the fallback — its home (the lane it left)
# in lane-home.tsv — and relaunched through the ordinary switch (`lane <fallback> <session>…`: a busy pane is deferred to the retry
# worker and relaunched when idle, never interrupted), the master last by the rescue route (`lane --rescue <fallback>`); a Fable
# session moving onto bedrock is recorded on Opus (models.tsv) in the same move; the default lane follows. "Stay": nothing moves a
# session back when the lane is active again; `salamander lane <home> <session>` does and clears its home. A job (`lane exec`) whose
# lane is dormant runs on the fallback for as long as it is, with one line on stderr. One hop; no usable fallback → nothing moves
# (exit 4) and the reason is one alert line.
# THE BACK AGENTS' LANE RULE (common.sh; off unless SALA_BACK_LANE_RULE=on): the watch moves the background agents off the home lane near its
# weekly limit and home when it resets, by queueing the ordinary `sala op lane <lane> <session>… --from sala-watch` (the switch below); a
# back agent spawned meanwhile launches on the rule's lane. `salamander watch --back-lanes --dry-run` shows a pass. It is not a `lane` verb.
# THE RESCUE (Wed Oct 14th 2026; asked by the project's coordinator session). The master runs on a lane (subscription-2 today); when
# that lane's usage is out or its account is dead, the master cannot act, and the session that could move it is not the
# master: `sala lane <lane> <master>` from there needed --not-master, and the master's own background rows held the
# relaunch. `salamander lane --rescue <lane>` is that move, sanctioned: it moves ONLY the master (SALA_MASTER), from a
# session that is not the master (the master's own pane is sent to the ordinary switch, which the self-worker runs once
# that pane is idle — the route that exists). It refuses while the master's current lane looks fine to sala (lane_out,
# common.sh: lane_check, the sign-in watch's state, the limit watch's state — no model asked, no request made), and
# `--force` overrides that with the override in the log; it refuses a target lane that cannot launch (lane_check) or that
# sala sees out as well. Then the switch's own steps: the recycle lock, the record (lanes.tsv) and one `rescue` line in
# lanes.log (when, who, from → to, why), the direct sweep (`revive --force --only <master> --not-master --rescue`: the
# sweep from another pane, the guard overridden on purpose, a stale background-task row not holding the master —
# lib/revive.sh, THE RESCUE). --dry-run writes and relaunches nothing. The table (no argument) warns under its rows when
# the master sits on a lane that is out, naming the fix and the lanes that work.

usage() {
    echo "usage: salamander lane                                         the table (default lane; the lane fields; each session: recorded lane, running lane)"
    echo "       salamander lane --list | --json                           the lane fields alone: provider, client, org, billing, plan, account, credential, region, status"
    echo "       salamander lane names [--json] [--write]                  each lane's code, display name and old words (one line each: code TAB display TAB aliases; --json for stackshot; --write keeps \$SALA_STATE_DIR/lane-names.json current)"
    echo "       salamander lane env <lane>                                the NAME=value lines a session on the lane gets, bar the pane-only cache switch (no secret), for a job; subscription-1 sets none: nothing is printed"
    echo "       salamander lane exec <lane> -- COMMAND [ARG…]             run COMMAND on the lane (a unit's ExecStart): the lane's environment; every other lane's variables are unset, subscription-1 too (never blanked)"
    echo "       salamander lane <lane> <session>… [--dry-run] [--not-master] [--rescue]   record + relaunch those sessions on the lane (one already on it: left alone)"
    echo "       salamander lane <lane> --all      [--dry-run] [--not-master]   every session and the default: one recycle --force"
    echo "       salamander lane default <lane>    [--dry-run] [--not-master]   the default alone (applied at each session's next relaunch)"
    echo "       salamander lane dormant <lane> [--reason TEXT] [--dry-run] [--no-fallback]   mark a lane dormant by hand (nothing is moved onto it); its sessions, default and jobs are queued onto its fallback unless --no-fallback or SALA_LANE_FALLBACK_AUTO=off"
    echo "       salamander lane fallback <lane>   [--dry-run]                  move the sessions, the default and (from then on) the jobs of a DORMANT lane to its fallback ($SALA_LANE_FALLBACK); --dry-run prints the moves; exit 4: no usable fallback"
    echo "       salamander lane active <lane>     [--dry-run]                  mark a lane active again (the only way back for api and sdk)"
    echo "       salamander lane --migrate         [--dry-run]                  rewrite the old name of a renamed lane (awsplatform → aws-platform) in sala's files, once (backups kept)"
    echo "       salamander lane --rescue <lane>   [--dry-run] [--force]        move the master (SALA_MASTER) off a lane that is out, from another session"
    echo "  the background agents' lane rule (SALA_BACK_LANE_RULE=on) moves them by this switch; see: salamander watch --back-lanes --dry-run"
    echo "  lanes: $(lane_choices)$(d=$(for l in $SALA_LANES_KNOWN; do lane_dormant "$l" && echo "$l"; done | paste -sd' ' -); [ -n "$d" ] && echo "; dormant: $d")  (subscription-1, shown as $(lane_label subscription-1): the login in ~/.claude · api: the key file · subscription-2, shown as $(lane_label subscription-2): a second login in its own config directory · sdk: api's key through the Agent SDK (client claude-agent-sdk), while the key has credit (a refusal switches it off for 6 hours) · bedrock: Claude on Amazon Bedrock through the AWS profile ${SALA_LANE_BEDROCK_PROFILE:-(none named: SALA_LANE_BEDROCK_PROFILE)}$(lane_check bedrock >/dev/null 2>&1 || echo ", not set up yet") · aws-platform: Claude Platform on AWS through the AWS profile ${SALA_LANE_AWSPLATFORM_PROFILE:-(none named: SALA_LANE_AWSPLATFORM_PROFILE)} and a workspace id$(lane_check aws-platform >/dev/null 2>&1 || echo ", not set up yet"))"
    echo "  --rescue on a switch: a stale background-task row (the exit dialog, the Stop hook's record, the mod) no longer holds a pane with no child process under its claude"
}

# THE LANE FOR A JOB: `lane env <lane>` and `lane exec <lane> -- CMD…` hand a scheduled job the environment a session on the lane
# gets (common.sh lane_job_env, the same fields as lane_env_prefix), so a unit never pastes a profile, region or model id. Read-only: they
# record nothing, relaunch nothing and take no lock. `exec` starts CMD without the variables that would pick another provider or login
# or belong to another lane (lane_job_unset: unset, never blanked, for subscription-1 too), then with the lane's own, and fails, running nothing,
# where the lane is not ready; no value of a secret passes here. `env subscription-1` prints nothing (stdout stays machine-readable); a terminal gets one stderr line.
case "${1:-}" in
    names) shift; NJ=0; NW=0
           for a in "$@"; do case "$a" in --json) NJ=1;; --write) NW=1;; *) die "usage: salamander lane names [--json] [--write]   (each lane's code, display name and old words; --write also keeps $SALA_STATE_DIR/lane-names.json current)";; esac; done
           [ "$NW" = 0 ] || lane_names_write >/dev/null || die "lane names: cannot write $SALA_STATE_DIR/lane-names.json"
           if [ "$NJ" = 1 ]; then lane_names_json; else lane_names_text; fi; exit 0 ;;
    env) shift; [ $# -eq 1 ] || die "usage: salamander lane env <lane>   (prints NAME=value lines, one per variable the lane sets; no secret among them)"
         jw=$(lane_job_env "$1") || { printf '%s\n' "$jw"; exit 1; }
         if [ -n "$jw" ]; then printf '%s\n' "$jw"   # stdout stays the NAME=value lines alone; subscription-1 sets none, and says so on a terminal only
         elif [ -t 1 ]; then echo "lane env $1: this lane sets no variables (lane exec $1 unsets the other lanes' ones)" >&2; fi
         exit 0 ;;
    exec) shift; [ $# -ge 3 ] && [ "$2" = -- ] || die "usage: salamander lane exec <lane> -- COMMAND [ARG…]   (runs COMMAND with the lane's environment)"
          jl="$1"; shift 2
          # THE LANE FALLBACK for a job: resolved here, at run time, so no unit file changes — a job whose lane is dormant runs
          # on the lane's fallback for as long as it is (when that is active and ready), with one line in the unit's journal
          if [ "${SALA_LANE_FALLBACK_AUTO:-on}" != off ] && lane_dormant "$jl"; then
              if jfb=$(lane_fallback_pick "$jl"); then
                  echo "lane exec: the $(lane_label "$(lane_state_id "$jl")") lane is dormant ($(lane_dormant_since_words "$jl")): $(basename -- "$1") runs on its fallback, the $(lane_label "$jfb") lane" >&2; jl=$jfb
              else echo "lane exec: the $(lane_label "$(lane_state_id "$jl")") lane is dormant and has no usable fallback ($jfb): $(basename -- "$1") runs on it as it is" >&2; fi
          fi
          job_env_args "$jl" || { echo "lane exec $jl: $JOB_ENV_WHY" >&2; exit 1; }
          exec env ${JOB_ENV[@]+"${JOB_ENV[@]}"} "$@" ;;
esac

export SALA_FLAG_SRC=lane   # the flag a relaunch here raises: one pane or a named few, explicit (common.sh, flag_src)
DRY=0; NOTMASTER=""; ALL=0; LANE=""; SESS=(); MODE=show; args=(); RESCUE=0; FORCE=0; LIST=0; JSON=0; REASON=""; HAVE_REASON=0; MIGRATE=0; NOFB=0
while [ $# -gt 0 ]; do
    a="$1"; shift
    case "$a" in
        --dry-run) DRY=1 ;; --not-master) NOTMASTER=--not-master ;; --all) ALL=1 ;; --rescue) RESCUE=1 ;; --force) FORCE=1 ;; --list) LIST=1 ;; --json) JSON=1 ;; --migrate) MIGRATE=1 ;; --no-fallback) NOFB=1 ;;
        --reason) [ $# -gt 0 ] || die "--reason needs the words: salamander lane dormant <lane> --reason \"...\""; REASON="$1"; HAVE_REASON=1; shift ;;
        --reason=*) REASON="${a#--reason=}"; HAVE_REASON=1 ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option: $a (see: salamander lane --help)" ;;
        *) args+=("$a") ;;
    esac
done
set -- ${args[@]+"${args[@]}"}
if [ "$MIGRATE" = 1 ]; then   # the rename's migration (common.sh lane_migrate): takes nothing but --dry-run
    [ $# -eq 0 ] && [ "$ALL" = 0 ] && [ "$RESCUE" = 0 ] && [ "$FORCE" = 0 ] && [ "$LIST" = 0 ] && [ "$JSON" = 0 ] && [ -z "$NOTMASTER" ] && [ "$HAVE_REASON" = 0 ] || die "--migrate takes only --dry-run: salamander lane --migrate [--dry-run]"
    lane_migrate $([ "$DRY" = 1 ] && echo --dry-run); exit $?
fi
if [ "$LIST" = 1 ] || [ "$JSON" = 1 ]; then   # the lane fields alone: read-only, takes nothing else
    [ $# -eq 0 ] && [ "$ALL" = 0 ] && [ "$RESCUE" = 0 ] && [ "$FORCE" = 0 ] && [ "$DRY" = 0 ] && [ -z "$NOTMASTER" ] || die "--list and --json take nothing else: salamander lane --list [--json]"
fi
case "${1:-}" in
    '') [ "$ALL" = 0 ] || die "--all needs a lane: salamander lane <lane> --all"; [ "$RESCUE" = 0 ] || die "--rescue needs a lane: salamander lane --rescue <lane>"; MODE=show
        if [ "$LIST" = 1 ] || [ "$JSON" = 1 ]; then MODE=list; fi ;;
    default) MODE=default; LANE="${2:-}"; [ -n "$LANE" ] || die "usage: salamander lane default <lane>   (one of: $SALA_LANES_KNOWN)"
             [ $# -le 2 ] || die "lane default takes one lane, nothing else"; [ "$ALL" = 0 ] || die "lane default takes no --all"; [ "$RESCUE" = 0 ] || die "lane default takes no --rescue" ;;
    fallback) MODE=fallback; LANE="${2:-}"; [ -n "$LANE" ] || die "usage: salamander lane fallback <lane> [--dry-run]   (the dormant lane whose sessions, default and jobs move to its fallback; one of: $SALA_LANES_KNOWN)"
             [ $# -le 2 ] || die "lane fallback takes one lane, nothing else"
             [ "$ALL" = 0 ] && [ "$RESCUE" = 0 ] && [ "$FORCE" = 0 ] && [ -z "$NOTMASTER" ] && [ "$HAVE_REASON" = 0 ] || die "lane fallback takes only --dry-run" ;;
    dormant|active) MODE=state; STATE_TO="$1"; LANE="${2:-}"; [ -n "$LANE" ] || die "usage: salamander lane $1 <lane>$([ "$1" = dormant ] && echo " [--reason TEXT]")   (one of: $SALA_LANES_KNOWN)"
             [ $# -le 2 ] || die "lane $1 takes one lane, nothing else"
             [ "$ALL" = 0 ] && [ "$RESCUE" = 0 ] && [ "$FORCE" = 0 ] && [ -z "$NOTMASTER" ] || die "lane $1 takes only --dry-run$([ "$1" = dormant ] && echo " and --reason")"
             [ "$STATE_TO" = dormant ] || [ "$HAVE_REASON" = 0 ] || die "--reason belongs to lane dormant" ;;
    *) MODE=switch; LANE="$1"; shift; SESS=("$@")
       [ "$RESCUE" = 1 ] && [ $# -eq 0 ] && [ "$ALL" = 0 ] && MODE=rescue ;;   # `lane --rescue <lane>`: the master's rescue
esac
[ "$HAVE_REASON" = 0 ] || [ "$MODE" = state ] || die "--reason belongs to lane dormant: salamander lane dormant <lane> --reason \"...\""
[ "$NOFB" = 0 ] || { [ "$MODE" = state ] && [ "$STATE_TO" = dormant ]; } || die "--no-fallback belongs to lane dormant: salamander lane dormant <lane> --no-fallback"
if [ "$FORCE" = 1 ] && [ "$MODE" != rescue ]; then die "--force belongs to the rescue: salamander lane --rescue <lane> --force"; fi
if [ "$RESCUE" = 1 ] && [ "$ALL" = 1 ]; then die "--rescue is for the master (salamander lane --rescue <lane>) or named sessions, never --all"; fi

# lane_sessions → every session sala relaunches: the pane map's rows and the live claude panes, minus the Remote Control
# server's; sorted, once each (the sweep sees the same panes: a map row brings a shell pane back, a live claude is relaunched)
lane_sessions() {
    { [ -r "$SALA_SIDECAR" ] && cut -f1 "$SALA_SIDECAR"
      tmux list-panes -a -F '#{session_name}|#{pane_pid}' 2>/dev/null | while IFS='|' read -r s pp; do claude_pid_under "$pp" >/dev/null 2>&1 && echo "$s"; done
    } | awk -v rc="$SALA_RC_SESSION" -v sh="$SALA_SHELL_SESSION" 'NF && $0 != rc && $0 != sh && !seen[$0]++' | LC_ALL=C sort
}
session_cpid() { local pp; tmux has-session -t "=$1" 2>/dev/null || return 1; pp=$(tmux list-panes -t "$(tmux_win_t "$1")" -F '#{pane_pid}' 2>/dev/null); claude_pid_under "${pp%%$'\n'*}"; }   # <session> → the claude in its first pane
# running_lane <session> → the lane its claude runs on (proc_lane): subscription-1 · api · subscription-2 · sdk · other (a config directory sala
# does not know) · ? (unreadable); "-" when no claude runs there (a shell pane, or no tmux session)
running_lane() { local c; c=$(session_cpid "$1") || { echo "-"; return; }; proc_lane "$c"; }

# ── the lane fields (common.sh "THE LANE FIELDS") ──────────────────
# lane_list_table → the rows of lane_fields_tsv under a header, columns aligned; an empty field is "-", billing carries its payment
lane_list_table() {
    { printf 'ID\tLABEL\tPROVIDER\tCLIENT\tORG\tPROJECT\tBILLING\tPAYMENT\tPLAN\tACCOUNT\tCREDENTIAL\tREGION\tSTATUS\n'; lane_fields_tsv; } | awk -F'\t' '
        NR > 1 && $8 != "" { $7 = $7 " (" $8 ")" }   # billing "usage (prepaid)"
        { k = 0; for (i = 1; i <= 13; i++) { if (i == 8) continue; k++; v = ($i == "" ? "-" : $i); cell[NR, k] = v; if (length(v) > w[k]) w[k] = length(v) } nc = k }
        END { for (r = 1; r <= NR; r++) { line = ""; for (k = 1; k <= nc; k++) line = line sprintf("%-" w[k] "s", cell[r, k]) (k < nc ? "  " : ""); sub(/ +$/, "", line); print line } }'
}
# lane_list_json → {"default", "lanes": [{id, label, provider, client, org, project, billing, payment, plan, account, credential, region, status}…], "aliases": {"sdk": …}}; an empty optional field is null
lane_list_json() {
    DEFAULT="$(lane_default)" FIELDS="$SALA_LANE_FIELDS" python3 -c '
import json, os, sys
names = os.environ["FIELDS"].split()
required = ("id", "label", "provider", "client", "org", "billing", "account", "status")
lanes = []
for line in sys.stdin.read().split("\n"):
    if not line: continue
    cells = line.split("\t")
    row = {n: (cells[i] if i < len(cells) and cells[i] != "" else None) for i, n in enumerate(names)}
    for n in required:
        if row[n] is None: row[n] = ""
    lanes.append(row)
doc = {"default": os.environ["DEFAULT"], "lanes": lanes,
       "aliases": {"sdk": {"lane": "api", "client": "claude-agent-sdk"}}}
json.dump(doc, sys.stdout, indent=2, ensure_ascii=False); print()' < <(lane_fields_tsv)
}
# lane_list_text → the aligned table, the alias line, then each line that breaks the spec (an override outside its list)
lane_list_text() {
    local l p
    lane_list_table
    echo "alias: sdk = api with client claude-agent-sdk (the key through the Agent SDK while it has credit)"
    for l in $SALA_LANES_DEFINED; do p=$(lane_fields_problems "$l"); [ -n "$p" ] && sed 's/^/⚠ /' <<< "$p"; done
    return 0
}
if [ "$MODE" = list ]; then
    if [ "$JSON" = 1 ]; then lane_list_json; else lane_list_text; fi
    exit 0
fi

# ── the table ─────────────────────────────────────────────────────────────────
if [ "$MODE" = show ]; then
    d=$(lane_default)
    dh=$(lane_home "(default)")
    echo "default lane: $d — new sessions, and every session without a lane of its own (salamander lane default <lane>)$([ -n "$dh" ] && [ "$dh" != "$d" ] && echo "; the lane fallback moved it off $dh (back: salamander lane default $dh)")"
    lane_list_text
    # the dormant record: each dormant lane, its reason and since, who set it and how many sessions are still on it
    if [ -r "$SALA_LANE_STATE" ]; then
        while IFS= read -r l; do
            [ -n "$l" ] || continue
            _lane_norm_r l "$l"   # a row written before a rename still says the old word
            echo "dormant: $(lane_dormant_words "$l") ($([ "$(lane_state_field "$l" 6)" = signal ] && echo "seen by sala's watch" || echo "set by hand"); $(plural "$(lane_sessions_on "$l" | grep -c .)" session) still on it$([ "$l" = api ] && echo "; back only with: salamander lane active api" || echo "; the watch looks again once a day$([ "$(lane_state_field "$l" 6)" = hand ] && echo ", but this one is held by hand: salamander lane active $l")"))"
        done < <(awk -F'\t' '$2=="dormant" {print $1}' "$SALA_LANE_STATE")
    fi
    ready=""; notready=()
    for l in $SALA_LANES_KNOWN; do
        if why=$(lane_check "$l"); then ready="$ready$l ready"; else ready="$ready$l not ready"; notready+=("$l: $why"); fi
        lane_dormant "$l" && ready="$ready (dormant)"; ready="$ready · "
    done
    echo "lanes: ${ready% · }"; for l in ${notready[@]+"${notready[@]}"}; do echo "  $l"; done
    rows=$( { lane_sessions; [ -r "$SALA_LANES" ] && cut -f1 "$SALA_LANES"; } | awk 'NF && !seen[$0]++' | LC_ALL=C sort)
    [ -n "$rows" ] || { echo "(no session: nothing in the pane map, no live claude pane, no lane recorded)"; exit 0; }
    T_S=(); T_REC=(); T_RUN=(); T_HM=(); T_NOTE=(); anyhome=0   # buffered: the HOME column is there only while some session sits off its home
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        rec=$(lane_row "$s"); eff=$(lane_for_session "$s"); run=$(running_lane "$s"); note=""   # eff: the row, else the default; an sdk row after its window → subscription-1
        if no_relaunch "$s"; then note="$(no_relaunch_fix "$s" "managed outside sala (SALA_NO_RELAUNCH): sala never relaunches it")"
        elif ! tmux has-session -t "=$s" 2>/dev/null; then note="no tmux session (a restore brings it back on $eff)"
        elif [ "$run" = "?" ]; then note="its environment cannot be read"
        elif [ "$run" = "-" ]; then note="no claude running (a revive resumes it on $eff)"
        elif [ "$run" != "$eff" ]; then note="← runs on $run; a relaunch puts it on $eff (salamander lane $eff $s, or the next recycle)"
        fi
        lane_dormant "$eff" && note="${note:+$note; }the $(lane_label "$(lane_state_id "$eff")") lane is dormant ($(lane_dormant_since_words "$eff")): it stays where it is, moving it is your call"
        [ "$rec" = sdk ] && ! sdk_window_open && note="${note:+$note; }$(sdk_closed_why): an sdk row launches on subscription-1 until then (salamander lane subscription-1 $s clears the row)"
        [ -n "$rec" ] && ! lane_known "$rec" && note="${note:+$note; }⚠ the recorded lane '$rec' is not a lane: a relaunch uses the default, $eff; the row is left as it is (salamander lane <lane> $s replaces it)"
        hm=$(lane_home "$s"); [ "$hm" = "$(lane_state_id "$eff")" ] || [ "$hm" = "$eff" ] && hm=""   # the home shows only while the session sits elsewhere (the lane fallback moved it; nothing moves it back by itself)
        [ -n "$hm" ] && note="${note:+$note; }moved off $hm by the lane fallback — back: salamander lane $hm $s"
        [ -n "$hm" ] && anyhome=1
        T_S+=("$s"); T_REC+=("${rec:-(default)}"); T_RUN+=("$run"); T_HM+=("${hm:--}"); T_NOTE+=("$note")
    done <<< "$rows"
    if [ "$anyhome" = 1 ]; then
        printf '%-30s %-10s %-8s %-10s %s\n' SESSION RECORDED RUNNING HOME ''
        for i in "${!T_S[@]}"; do printf '%-30s %-10s %-8s %-10s %s\n' "${T_S[$i]}" "${T_REC[$i]}" "${T_RUN[$i]}" "${T_HM[$i]}" "${T_NOTE[$i]}"; done
    else
        printf '%-30s %-10s %-8s %s\n' SESSION RECORDED RUNNING ''
        for i in "${!T_S[@]}"; do printf '%-30s %-10s %-8s %s\n' "${T_S[$i]}" "${T_REC[$i]}" "${T_RUN[$i]}" "${T_NOTE[$i]}"; done
    fi
    # THE WARNING (the header): the master on a lane sala sees out, and the way off it from another session
    if [ -n "${SALA_MASTER:-}" ] && tmux has-session -t "=$SALA_MASTER" 2>/dev/null; then
        run=$(running_lane "$SALA_MASTER"); case "$run" in -|"?") cur=$(lane_for_session "$SALA_MASTER");; *) cur=$run;; esac
        if out=$(lane_out "$cur" "$SALA_MASTER"); then
            w=$(lanes_working); w=${w// /, }
            echo "⚠ the master $SALA_MASTER sits on the $(lane_shown "$cur") lane, which is out: $(paste -sd';' - <<< "$out" | sed 's/;/; /g') — from another session: salamander lane --rescue <lane> ($([ -n "$w" ] && echo "lanes that work: $w" || echo "no lane works right now: sala sees every one out"))"
        fi
    fi
    exit 0
fi

lane_known "$LANE" || die "unknown lane '$LANE' (one of: $SALA_LANES_KNOWN)"
TYPED="$LANE"; _lane_norm_r LANE "$LANE"
[ "$TYPED" = "$LANE" ] || echo "($TYPED is the old name of the $LANE lane: using $LANE)" >&2   # awsplatform, renamed Mon Oct 26th 2026; accepted everywhere a lane is typed

# ── the dormant record by hand (the header, THE DORMANT RECORD): `lane dormant <lane> [--reason …]`, `lane active <lane>` ──
# Only the record is written: no pane is touched, nothing is relaunched, so this is no fleet operation and takes no queue.
if [ "$MODE" = state ]; then
    L=$(lane_state_id "$LANE"); [ "$L" = "$LANE" ] || echo "($LANE is an alias of $L: the record is the $L lane's)"
    if [ "$STATE_TO" = dormant ]; then
        R="${REASON:-set by hand}"
        if lane_dormant "$L"; then echo "$(lane_dormant_words "$L") — already dormant, nothing written"; exit 0; fi
        n=$(_nlines "$(lane_sessions_on "$L")")
        if [ "$DRY" = 1 ]; then
            if [ "$NOFB" = 0 ] && [ "${SALA_LANE_FALLBACK_AUTO:-on}" != off ]; then
                if fbd=$(lane_fallback_of "$L"); then echo "[dry-run] would mark the $(lane_label "$L") lane dormant ($R), by hand — $n session(s) are on it; then queue their move onto the $(lane_label "$fbd") lane (what that moves: salamander lane fallback $L --dry-run, once it is dormant); nothing written"
                else echo "[dry-run] would mark the $(lane_label "$L") lane dormant ($R), by hand — $n session(s) are on it and stay where they are (the $(lane_label "$L") lane has no fallback set); nothing written"; fi
            else echo "[dry-run] would mark the $(lane_label "$L") lane dormant ($R), by hand — $n session(s) are on it and stay where they are; nothing written"; fi
            exit 0
        fi
        lane_dormant_set "$L" "$R" hand || die "could not write the dormant record ($SALA_LANE_STATE)"
        echo "$(lane_dormant_words "$L") (set by hand: it stays dormant until: salamander lane active $L)"
        if [ "$NOFB" = 1 ]; then echo "  $n session(s) are on it and stay where they are (--no-fallback); the watch posts that once. Moving one: salamander lane <lane> <session>"
        elif fbr=$(lane_fallback_auto "$L" hand); then
            lane_dormant_claim_post "$L" >/dev/null 2>&1 || true   # the move's own post says it (names the lane, the fallback, every session); no second "your call" post
            echo "  $n session(s) are on it: their move onto $(lane_label "$(lane_fallback_of "$L")") is queued (op $fbr) — one post when it is done; they stay there until you move them back: salamander lane $L <session>"
        else
            fbrc=$?
            case "$fbrc" in
                3) echo "  $n session(s) are on it and stay where they are (SALA_LANE_FALLBACK_AUTO is off); the watch posts that once. Moving them: salamander lane fallback $L, or salamander lane <lane> <session>" ;;
                2) echo "  nothing is on it and it is not the default: nothing to move" ;;
                *) echo "  $n session(s) are on it and stay where they are — no fallback: $fbr. The watch posts that once. Moving one: salamander lane <lane> <session>" ;;
            esac
        fi
    else
        if ! lane_dormant "$L"; then echo "the $(lane_label "$L") lane is active already — nothing written"; exit 0; fi
        if [ "$DRY" = 1 ]; then echo "[dry-run] would mark the $(lane_label "$L") lane active again (it is: $(lane_dormant_words "$L")); nothing written"; exit 0; fi
        lane_dormant_clear "$L" "set by hand" || die "could not write the dormant record ($SALA_LANE_STATE)"
        echo "the $(lane_label "$L") lane is active again; new sessions and moves may pick it"
    fi
    exit 0
fi
# ── the fallback: everything on a dormant lane → its fallback (the header, THE LANE FALLBACK) ──
# Records, per session, where it came from (lane-home.tsv) and the model change the fallback needs, switches the default when it was
# the dead lane, then moves the sessions through the ordinary switch below (`lane <fallback> <sessions>`: lane_write, then the
# idle-aware revive) and the master through the rescue (`lane --rescue <fallback>`). One RESULT line per move: the queue
# (lib/op.sh) turns them into the bullets of its one post. Nothing moves back by itself (the "stay" half of the automatic fallback).
if [ "$MODE" = fallback ]; then
    L=$(lane_state_id "$LANE")
    lane_dormant "$L" || die "the $(lane_label "$L") lane is not dormant: the fallback moves what sits on a dormant lane — salamander lane dormant $L first (it queues this move itself), or move a session by hand: salamander lane <lane> <session>"
    if ! fb=$(lane_fallback_pick "$L"); then echo "no fallback move: $fb — nothing moved, nothing recorded" >&2; exit 4; fi
    FBN=$(lane_label "$fb")
    M="${SALA_MASTER:-}"
    MV_LIVE=(); MV_DEAD=(); MV_MASTER=""; STAYS=(); PLAN_ON=(); declare -A CHG=() PREV=()
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        if no_relaunch "$s"; then STAYS+=("$s"); continue; fi
        PLAN_ON+=("$s"); CHG[$s]=$(lane_fallback_model_change "$s" "$fb")   # read now: once the override is written the session no longer reads as Fable
        if [ -n "${CHG[$s]}" ]; then PREV[$s]=$(model_row "$s"); PREV[$s]=${PREV[$s]%%$'\t'*}; fi
        if [ -n "$M" ] && [ "$s" = "$M" ] && tmux has-session -t "=$s" 2>/dev/null; then MV_MASTER="$s"
        elif tmux has-session -t "=$s" 2>/dev/null; then MV_LIVE+=("$s")
        else MV_DEAD+=("$s"); fi
    done < <(lane_sessions_on "$L")
    DFLT=0; [ "$(lane_state_id "$(lane_default)")" = "$L" ] && DFLT=1
    echo "lane fallback: the $(lane_label "$L") lane is dormant ($(lane_dormant_since_words "$L")) → its sessions$([ "$DFLT" = 1 ] && echo " and the default") move to the $(lane_shown "$FBN") lane (one hop; they stay there until moved back: salamander lane $L <session>)$([ "$DRY" = 1 ] && echo " — DRY RUN: nothing recorded, nothing relaunched")"
    for s in ${PLAN_ON[@]+"${PLAN_ON[@]}"}; do
        chg=${CHG[$s]}
        echo "  $s: $L → $fb$([ -n "$chg" ] && echo ", model ${chg%%$'\t'*} → ${chg#*$'\t'} (${FBN} cannot run ${chg%%$'\t'*})")$([ "$s" = "$MV_MASTER" ] && echo " — the master: by the rescue, last")$(case " ${MV_DEAD[*]-} " in *" $s "*) echo " — no tmux session: recorded only, a restore brings it back on $fb";; esac)"
    done
    for s in ${STAYS[@]+"${STAYS[@]}"}; do echo "  $(no_relaunch_line "$s") — stays where it is"; done
    [ "$DFLT" = 1 ] && echo "  default lane: $L → $fb (was $L; new sessions and every session without a lane of its own)"
    echo "  jobs: a sala job whose lane is $L runs on $fb while $L is dormant (salamander lane exec resolves it at run time; no unit file is rewritten)"
    if [ "${#PLAN_ON[@]}" -eq 0 ] && [ "$DFLT" = 0 ]; then echo "nothing is on the $(lane_label "$L") lane and it is not the default: nothing to move"; exit 0; fi
    if [ "$DRY" = 1 ]; then echo "[dry-run] would record each one's home ($L) and model change, switch the default if it was $L, then: salamander lane $fb <sessions>…$([ -n "$MV_MASTER" ] && echo "; salamander lane --rescue $fb (the master $MV_MASTER)"); nothing written"; exit 0; fi
    ops_guard lane "$L" $NOTMASTER
    if recycle_locked; then recycle_refuse; fi   # the nested switch takes the lock itself: stand aside now rather than half-way
    # the records first: where each came from, the model the fallback needs, the default
    for s in ${PLAN_ON[@]+"${PLAN_ON[@]}"}; do
        chg=${CHG[$s]}
        lane_home_set "$s" "$L" "${PREV[$s]:-${chg:+fable}}" || echo "⚠ could not record $s's home lane ($SALA_LANE_HOME): it moves, but the table will not show where it came from" >&2
        [ -z "$chg" ] || model_write "$s" "${chg#*$'\t'}" || echo "⚠ could not record the model change for $s ($SALA_MODELS): it may relaunch on a model $FBN cannot run" >&2
    done
    if [ "$DFLT" = 1 ]; then
        lane_home_set "(default)" "$L" || true
        lane_set_default "$fb" || die "could not write the default lane ($SALA_LANE_DEFAULT_FILE) — nothing moved"
    fi
    rc=0
    for s in ${MV_DEAD[@]+"${MV_DEAD[@]}"}; do lane_write "$s" "$fb" || { echo "⚠ could not record the lane for $s" >&2; rc=1; }; done
    if [ ${#MV_LIVE[@]} -gt 0 ]; then "$SALA_BIN" lane "$fb" "${MV_LIVE[@]}" $NOTMASTER || rc=$?; fi
    if [ -n "$MV_MASTER" ]; then
        # the sessions' relaunch runs on as a detached driver that holds the recycle lock; the master's rescue takes it next, so wait for it to be freed
        for ((i=0; i<${SALA_LANE_FALLBACK_WAIT:-1800}; i+=5)); do recycle_locked || break; sleep 5; done
        "$SALA_BIN" lane --rescue "$fb" $NOTMASTER || { echo "⚠ the master $MV_MASTER did not move (the rescue, above): it stays on $L until: salamander lane --rescue $fb, from another session" >&2; rc=1; }; fi
    for s in ${PLAN_ON[@]+"${PLAN_ON[@]}"}; do
        chg=${CHG[$s]}; got=$(lane_row "$s")
        echo "RESULT $s: $L → $fb$([ -n "$chg" ] && echo ", model ${chg%%$'\t'*} → ${chg#*$'\t'}")$([ "$got" = "$fb" ] || echo " (NOT moved: still recorded on ${got:-the default})")"
    done
    [ "$DFLT" = 1 ] && echo "RESULT default lane: $L → $fb"
    for s in ${STAYS[@]+"${STAYS[@]}"}; do echo "RESULT $s: stays on $L (managed outside sala)"; done
    lane_log fallback "$L" "moved ${#PLAN_ON[@]} session(s)$([ "$DFLT" = 1 ] && echo " and the default") to $fb (rc $rc)"
    # the last line is the operation's result (lib/op.sh keeps the RESULT lines above as the notice's bullets)
    echo "the $(lane_label "$L") lane is dormant: $(plural "${#PLAN_ON[@]}" session)$([ "$DFLT" = 1 ] && echo " and the default") moved to the $FBN lane; they stay there until moved back (salamander lane $L <session>)"
    exit "$rc"
fi
# a dormant lane is not moved onto (the header): refused before anything is recorded or relaunched — the rescue and the default included
if why=$(lane_dormant_refusal "$LANE"); then die "$why"; fi

# ── the rescue: the master off a lane that is out, from another session (the header, THE RESCUE) ──
if [ "$MODE" = rescue ]; then
    M="${SALA_MASTER:-}"; [ -n "$M" ] || die "no master session is configured (SALA_MASTER): the rescue moves the master, and there is none to move"
    why=$(lane_check "$LANE") || die "$why — nothing recorded, nothing relaunched"   # the target must launch (the header)
    tmux has-session -t "=$M" 2>/dev/null || die "the master '$M' has no tmux session — salamander watch brings it back (on $(lane_for_session "$M")); to change its lane first: salamander lane $LANE $M --not-master"
    no_relaunch "$M" && die "$(no_relaunch_line "$M") — $(no_relaunch_fix "$M" "the master is launched by hand with an environment of its own; take it out of SALA_NO_RELAUNCH to move it")"
    ME=""; [ -n "${TMUX_PANE:-}" ] && ME=$(tmux display -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)
    [ "$ME" = "$M" ] && die "this is the master's own pane: the rescue is another session's move. From here the ordinary switch does it — salamander lane $LANE $M — through the self-worker, once this pane is idle (the route that exists)"
    run=$(running_lane "$M"); case "$run" in -|"?") cur=$(lane_for_session "$M");; *) cur=$run;; esac   # what it runs on, else what a relaunch would put it on
    [ "$cur" = "$LANE" ] && die "the master $M runs on the $(lane_shown "$LANE") lane already$([ "$run" = "-" ] && echo " (no claude running: a relaunch resumes it there)") — a rescue moves it to another lane$( w=$(lanes_working); w=${w// /, }; [ -n "$w" ] && echo " (lanes that work: $w)")"
    if out=$(lane_out "$cur" "$M"); then why="$cur is out: $(paste -sd';' - <<< "$out" | sed 's/;/; /g')"
    elif [ "$FORCE" = 1 ]; then why="--force: the $(lane_shown "$cur") lane looked fine to sala (lane_check passes, the sign-in watch sees it right or has not looked, the limit watch has nothing stopped on it)"
    else die "the master $M sits on the $(lane_shown "$cur") lane, which looks fine to sala: lane_check passes, the sign-in watch sees it right (or has not looked), the limit watch has nothing stopped on it — nothing to rescue it from. If you know better (an error sala has not seen yet): salamander lane --rescue $LANE --force, which says so in the log; to move it on an ordinary day: salamander lane $LANE $M --not-master"; fi
    if tout=$(lane_out "$LANE"); then
        [ "$FORCE" = 1 ] || die "the $(lane_shown "$LANE") lane is out as well: $(paste -sd';' - <<< "$tout" | sed 's/;/; /g') — pick one that works$( w=$(lanes_working); w=${w// /, }; [ -n "$w" ] && echo ": $w" || echo " (sala sees every lane out right now)"); --force moves it there anyway"
        why="$why; onto $LANE, which sala sees out too ($(paste -sd';' - <<< "$tout" | sed 's/;/; /g')) — --force"
    fi
    echo "rescue: the master $M, $cur → $LANE$([ "$DRY" = 1 ] && echo " — DRY RUN: nothing recorded, nothing relaunched, nothing logged")"
    echo "  why: $why"
    echo "  from ${ME:-a shell}: the direct sweep of the master's pane, the guard overridden on purpose (--not-master), a stale background-task row not holding it (--rescue)"
    if [ "$DRY" = 1 ]; then
        echo "[dry-run] would record $M on the $(lane_shown "$LANE") lane, log one 'rescue' line in $SALA_LANE_LOG, then: salamander revive --force --only $M --not-master --rescue (the relaunch verdict)"
        "$SALA_BIN" revive --dry-run --force --only "$M" --not-master --rescue 2>&1 | sed 's/^/    /'
        exit 0
    fi
    recycle_lock "$(lock_who)" 0 || recycle_refuse   # one relaunch driver at a time (common.sh); the sweep inherits fd 9
    export SALA_RECYCLE_LOCKED=1
    lane_write "$M" "$LANE" || die "could not record the lane for '$M' (see above) — nothing relaunched"
    [ "$(lane_home "$M")" != "$LANE" ] || lane_home_clear "$M"
    lane_log rescue "$M" "$cur → $LANE: $why"
    echo "recorded: $M on the $(lane_shown "$LANE") lane ($SALA_LANES); logged: rescue ($SALA_LANE_LOG)"
    "$SALA_BIN" revive --force --only "$M" --not-master --rescue || { rc=$?
        echo "⚠ the lane is recorded, but the relaunch did not run through (exit $rc, above): the master comes onto $LANE at its next relaunch — salamander revive --force --only $M --not-master --rescue, or salamander watch when its claude is gone" >&2; exit "$rc"; }
    exit 0
fi

# ── the default alone ─────────────────────────────────────────────────────────
if [ "$MODE" = default ]; then
    ops_guard lane default $NOTMASTER $([ "$DRY" = 1 ] && echo --dry-run)   # a fleet operation: the master's, when a Claude session asks (common.sh)
    why=$(lane_check "$LANE") || die "$why"
    old=$(lane_default)
    [ "$old" = "$LANE" ] && { echo "default lane: $LANE (already)"; exit 0; }
    n=0; for s in $(lane_sessions); do [ -z "$(lane_row "$s")" ] && n=$((n+1)); done
    # --dry-run writes nothing (Wed Oct 14th 2026, the master session: `sala lane default api --dry-run` wrote the default
    # lane — this block never looked at DRY and went straight to lane_set_default)
    if [ "$DRY" = 1 ]; then
        echo "[dry-run] would set the default lane: $LANE (was $old) — $n session(s) without a lane of their own would take it at their next relaunch; nothing recorded"
        exit 0
    fi
    lane_set_default "$LANE" || die "could not write the default lane ($SALA_LANE_DEFAULT_FILE)"
    [ "$(lane_home "(default)")" != "$LANE" ] || lane_home_clear "(default)"   # back on the lane the fallback moved it off
    echo "default lane: $LANE (was $old) — $n session(s) without a lane of their own take it at their next relaunch; nothing relaunched now"
    echo "  to relaunch them onto it now: salamander lane $LANE <session>…, or salamander lane $LANE --all"
    exit 0
fi

# ── the switch ────────────────────────────────────────────────────────────────
[ "$ALL" = 1 ] && [ ${#SESS[@]} -gt 0 ] && die "either --all or session names, not both"
[ "$ALL" = 1 ] || [ ${#SESS[@]} -gt 0 ] || die "which sessions? salamander lane $LANE <session>…, or salamander lane $LANE --all"
why=$(lane_check "$LANE") || die "$why — nothing recorded, nothing relaunched"   # before anything is touched (the header above)
OUTSIDE=()
if [ "$ALL" = 1 ]; then
    all=(); while IFS= read -r s; do [ -n "$s" ] && all+=("$s"); done < <(lane_sessions)
    for s in ${all[@]+"${all[@]}"}; do if no_relaunch "$s"; then OUTSIDE+=("$s"); else SESS+=("$s"); fi; done
else
    seen=(); for s in "${SESS[@]}"; do
        case "$s" in ''|-*|*[[:space:]:]*) die "invalid session name '$s'";; esac
        case " ${seen[*]-} " in *" $s "*) continue;; esac; seen+=("$s")
        tmux has-session -t "=$s" 2>/dev/null || die "no tmux session '$s'"
        [ "$s" = "$SALA_RC_SESSION" ] && die "'$s' is the Remote Control server's session — it has no lane (salamander rc)"
        no_relaunch "$s" && die "$(no_relaunch_line "$s") — $(no_relaunch_fix "$s" "it is launched by hand with an environment of its own; take it out of SALA_NO_RELAUNCH to give it a lane")"
    done
    SESS=(${seen[@]+"${seen[@]}"})
fi
ops_guard lane "${SESS[0]:-all}" $NOTMASTER $([ "$DRY" = 1 ] && echo --dry-run)   # a fleet operation (common.sh): the master's, when a Claude session asks
ME=""; [ -n "${TMUX_PANE:-}" ] && ME=$(tmux display -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)
RESCUEFLAG=""; [ "$RESCUE" = 1 ] && RESCUEFLAG=--rescue   # onto the sweep and the self-worker (lib/revive.sh, THE RESCUE)

# the plan: who moves (recorded on the lane and running on it already → left alone), the env's names, the own pane
TODO=(); SAME=(); SELF=0
for s in ${SESS[@]+"${SESS[@]}"}; do
    rec=$(lane_row "$s"); run=$(running_lane "$s")
    if [ "$rec" = "$LANE" ] && [ "$run" = "$LANE" ]; then SAME+=("$s"); continue; fi
    if [ -n "$ME" ] && [ "$s" = "$ME" ]; then SELF=1; else TODO+=("$s"); fi
done
echo "lane $LANE: ${#SESS[@]} session(s)$([ "$ALL" = 1 ] && echo ", and the default for new ones")$([ "$RESCUE" = 1 ] && echo " — --rescue: a stale background-task row will not hold a pane with no child process under its claude")$([ "$DRY" = 1 ] && echo " — DRY RUN: nothing recorded, nothing relaunched")"
case "$LANE" in
    subscription-1) echo "  on the launch line: nothing — the login in ~/.claude" ;;
    api) echo "  on the launch line: $(lane_env_names api) — each read by the pane's own shell from $SALA_LANE_API_KEY_FILE$([ -r "$SALA_LANE_API_WORKSPACE_FILE" ] && echo " and $SALA_LANE_API_WORKSPACE_FILE") when the line runs (the value is in that claude's environment and nowhere else)$(lane_args api | sed 's/^ / · /')"
         echo "  no Remote Control and no claude.ai connectors on this lane (watch's bridge heal and the reboot's bridge check stand down)" ;;
    subscription-2) echo "  on the launch line: $(lane_env_names "$LANE")=$(lane_dir "$LANE") — that directory's own login" ;;
    bedrock) echo "  on the launch line (names only): $(lane_env_names bedrock) — the profile $SALA_LANE_BEDROCK_PROFILE's keys are read by the CLI from $SALA_LANE_BEDROCK_CREDENTIALS_FILE, never by sala$(lane_args bedrock | sed 's/^ / · /')"
         echo "  no Remote Control and no claude.ai connectors on this lane (watch's bridge heal and the reboot's bridge check stand down)" ;;
    aws-platform) echo "  on the launch line (names only): $(lane_env_names aws-platform), after unsetting $(lane_unset_names aws-platform) (they would change the routing or the signing) — the profile $SALA_LANE_AWSPLATFORM_PROFILE's keys are read by the CLI from $SALA_LANE_AWSPLATFORM_CREDENTIALS_FILE, never by sala$(lane_args aws-platform | sed 's/^ / · /')"
         echo "  no Remote Control and no claude.ai connectors on this lane (watch's bridge heal and the reboot's bridge check stand down)" ;;
    sdk) echo "  on the launch line: salamander sdk-pane <uuid> <session> — the pane program (lib/sdk-pane.sh) runs the Agent SDK ($SALA_LANE_SDK_PIN) and hands $(lane_env_names sdk) to the CLI it spawns, read from $SALA_LANE_API_KEY_FILE$([ -r "$SALA_LANE_API_WORKSPACE_FILE" ] && echo " and $SALA_LANE_API_WORKSPACE_FILE") (the value is in that process's environment and nowhere else) · --mcp-config $SALA_LANE_API_MCP_CONFIG"
         echo "  while the key has credit: a turn the credit refuses writes the shared record ($(api_credit_state_file)) and puts the pane back on subscription-1 at once (one post); a session recorded on sdk is relaunched on subscription-1 for API_CREDIT_RETRY_S seconds (6 hours by default) after a refusal, then the key is tried again"
         echo "  no Remote Control and no claude.ai connectors on this lane (watch's bridge heal and the reboot's bridge check stand down)" ;;
esac
for s in ${SESS[@]+"${SESS[@]}"}; do
    rec=$(lane_row "$s"); run=$(running_lane "$s")
    case " ${SAME[*]-} " in *" $s "*) echo "  $s: $LANE, running on it — left alone"; continue;; esac
    echo "  $s: ${rec:-$(lane_default) (the default)} → $LANE$( [ "$run" != "$LANE" ] && [ "$run" != "-" ] && echo " (runs on $run now)")$( [ "$s" = "$ME" ] && echo " — this command's own pane: relaunched last, once it is idle")"
done
for s in ${OUTSIDE[@]+"${OUTSIDE[@]}"}; do echo "  $(no_relaunch_line "$s") — no lane recorded"; done
if [ "$DRY" = 1 ]; then
    if [ $((${#TODO[@]} + SELF)) -eq 0 ]; then echo "[dry-run] every session already runs on the $(lane_shown "$LANE") lane — nothing would be relaunched"; exit 0; fi
    if [ "$ALL" = 1 ]; then echo "[dry-run] would record the lane for ${#SESS[@]} session(s) and the default, then: salamander recycle --force (the relaunch verdicts, pane by pane)"; sweep=()
    else echo "[dry-run] would record the lane for ${#SESS[@]} session(s), then: salamander revive --force$(printf -- ' --only %s' ${TODO[@]+"${TODO[@]}"})${RESCUEFLAG:+ $RESCUEFLAG}$([ "$SELF" = 1 ] && echo "; salamander revive --self${RESCUEFLAG:+ $RESCUEFLAG}") (the relaunch verdicts, pane by pane)"
         sweep=(); for s in ${TODO[@]+"${TODO[@]}"}; do sweep+=(--only "$s"); done; fi
    [ "$ALL" = 1 ] || [ ${#TODO[@]} -gt 0 ] && "$SALA_BIN" revive --dry-run --force ${sweep[@]+"${sweep[@]}"} $RESCUEFLAG 2>&1 | sed 's/^/    /'
    [ "$SELF" = 1 ] && echo "    $ME: this command's own pane — the self-worker relaunches it once it is idle"
    exit 0
fi

# THE LOCK, then the record, then the relaunch (the header): one relaunch driver at a time (common.sh, "recycle lock"); the
# children (recycle's driver, the direct sweep, the self-worker) inherit fd 9 and keep it until they are done
recycle_lock "$(lock_who)" 0 || recycle_refuse
export SALA_RECYCLE_LOCKED=1
for s in ${SESS[@]+"${SESS[@]}"}; do lane_write "$s" "$LANE" || die "could not record the lane for '$s' (see above) — nothing relaunched"; [ "$(lane_home "$s")" != "$LANE" ] || lane_home_clear "$s"; done   # back on the lane the fallback moved it off: the home row goes
[ "$ALL" = 1 ] && { lane_set_default "$LANE" || die "the sessions are recorded but the default lane could not be written ($SALA_LANE_DEFAULT_FILE) — nothing relaunched"; }
echo "recorded: ${#SESS[@]} session(s) on the $(lane_shown "$LANE") lane ($SALA_LANES)$([ "$ALL" = 1 ] && echo "; default lane: $LANE")"
if [ $((${#TODO[@]} + SELF)) -eq 0 ]; then echo "every one of them already runs on the $(lane_shown "$LANE") lane — nothing relaunched"; exit 0; fi
rc=0
if [ "$ALL" = 1 ]; then
    "$SALA_BIN" recycle --force $NOTMASTER || rc=$?
else
    if [ ${#TODO[@]} -gt 0 ]; then
        sweep=(); for s in "${TODO[@]}"; do sweep+=(--only "$s"); done
        "$SALA_BIN" revive --force "${sweep[@]}" $NOTMASTER $RESCUEFLAG || rc=$?
    fi
    [ "$SELF" = 1 ] && { "$SALA_BIN" revive --self $NOTMASTER $RESCUEFLAG || rc=$?; }
fi
if [ "$rc" != 0 ]; then
    echo "⚠ the lane is recorded, but the relaunch did not run through (exit $rc, above): each pane still on its old lane comes onto $LANE at its next relaunch — salamander revive --force --only <session>, or the next recycle" >&2
    exit "$rc"
fi
exit 0
