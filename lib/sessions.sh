# lib/sessions.sh — the session registry (phases 1 and 2; docs/session-registry.md; the functions are in common.sh).
#
#   salamander sessions [--all] [--json]        the registry, read-only: one line per live session (--all: retired too; --json: the file's rows)
#   salamander sessions --check [--dry-run]     the registry against the pane map: a kill between ledger_write's two writes leaves a row missing,
#                                               a rename not recorded or a retire not recorded; --check repairs the REGISTRY (never the map) and
#                                               says what it did, --dry-run only reports. Exit 0 consistent or repaired, 1 drift left (or, with
#                                               --dry-run, found)
#   salamander sessions --migrate [--dry-run]   one-time: a row for every pane-map row that has none (transcripts[0] = the row's conversation, why
#                                               "import"; lane, model and effort from the tables; aliases from salamander-renames.jsonl). Run
#                                               --dry-run first and compare it with `salamander spawn --list`. Safe to repeat: a name that has a
#                                               live row is skipped
#
#   salamander sessions record <id|name> --transcript <claude session id> --why clear|resume|start [--machine X]
#                                               phase 2, the explicit signal for a fresh start: the conversation joins the row's grow-only list
#                                               (an id, a unique id prefix of 8+ characters, or the name of a live session). Idempotent: the same
#                                               conversation twice changes nothing. An unknown session, a bad --why or no --transcript: the reason on
#                                               stderr, exit 1, nothing written. SALA_SESSIONS=off: nothing written, exit 0. Called by the SessionStart
#                                               hook (`salamander hook session-start`) and by unpark
#
#   salamander sessions resolve <ref> [--live] [--json]
#                                               phase 3, read-only (writes nothing, not even a log line): the row <ref> names. <ref> is a session id (or a
#                                               unique prefix of 8+ characters), a transcript id, a name, an alias (a name it had) or
#                                               role:<project>/<role> (for example role:projects/salamander/back; live rows only). Prints id, name, state
#                                               (retired rows resolve, marked retired), project, role and pane; --json prints the row. Exit 0 found, 1 none
#                                               (or the file unreadable), 2 AMBIGUOUS: the candidates' ids are listed and nothing is picked (a name a retired
#                                               row and a live row both carry is ambiguous until --live drops the retired ones). Works with SALA_SESSIONS=off
#
#   salamander sessions tag <id|name> [--project <page key>] [--role front|back] [--project-key <page key>] [--dry-run]
#                                               fill project/role of an existing LIVE row (spawn --project --role is the only other way, and only at
#                                               birth): the session is an id, a unique id prefix of 8+ characters or the name of a live session; only the
#                                               given fields change. The row has one project value (the published project_key is derived from it), so
#                                               --project-key P is the same field under that name. A bad --role, a retired row, an unknown session or
#                                               no field: the reason on stderr, exit 1, nothing written. --dry-run reads only. SALA_SESSIONS=off: exit 1,
#                                               nothing written. One `tag` line in sessions.log. Afterwards `resolve role:<project>/<role>` finds the row
#   salamander sessions tag --auto [<id|name>] [--dry-run]
#                                               the backfill: every live row with NO role (or the one named) gets its project and role from stackshot's
#                                               project record (docs/stackshot-contracts.md, interface 20: a top-level entry of a project's agents map is
#                                               front, one under background: is back). A role already on a row is never overwritten; a row the record
#                                               does not list (a throwaway, a scratch or a side session) is left, with the reason; a row that was tagged
#                                               throwaway and is listed stops being one. Idempotent. --dry-run prints what it would write and writes
#                                               nothing. Exit 0 done (or nothing to do), 3 the one named session is on no agents map, 4 the record cannot
#                                               answer (missing, stale or unreadable: nothing written). The watch runs it on every tick, so no one has to
#
#   salamander sessions transcript <ref> [--json]
#                                               read-only: where a session's conversations are on disk. <ref> as for resolve (a live row
#                                               wins over a retired one of the same name). One line each, the current conversation first, then the earlier
#                                               ones: `current|earlier  <path>  <when>  <why>`; --json: {id, name, state, transcripts: [{id, path,
#                                               current, machine, at, why}]}, path null where the file is not under the CLI's projects directory on this
#                                               box. A side session reads other agents' transcripts through it (docs/side-sessions.md). Exit codes as resolve.
#
# Phases 1 and 2 record; phase 3 adds the resolver and the heartbeat's published session-registry.json (lib/heartbeat.sh). Nothing else in sala reads the
# registry (SALA_SESSIONS=off stops the writes and the publish; deleting sessions.json starts over).

if [ "${1:-}" = resolve ]; then
    shift; ref=""; flags=()
    for a in "$@"; do
        case "$a" in
            --live|--json) flags+=("$a") ;;
            -*) die "unknown option for sessions resolve: $a" ;;
            *) [ -z "$ref" ] || die "usage: salamander sessions resolve <id|prefix|transcript|name|alias|role:<project>/<role>> [--live] [--json]"; ref="$a" ;;
        esac
    done
    [ -n "$ref" ] || die "usage: salamander sessions resolve <id|prefix|transcript|name|alias|role:<project>/<role>> [--live] [--json]"
    sessions_py resolve "$ref" ${flags[@]+"${flags[@]}"}; exit $?
fi

if [ "${1:-}" = transcript ]; then
    shift; ref=""; flags=()
    for a in "$@"; do
        case "$a" in
            --json) flags+=("$a") ;;
            -*) die "unknown option for sessions transcript: $a" ;;
            *) [ -z "$ref" ] || die "usage: salamander sessions transcript <id|prefix|transcript|name|alias|role:<project>/<role>> [--json]"; ref="$a" ;;
        esac
    done
    [ -n "$ref" ] || die "usage: salamander sessions transcript <id|prefix|transcript|name|alias|role:<project>/<role>> [--json]"
    sessions_py transcript "$ref" --projects "$SALA_PROJECTS" ${flags[@]+"${flags[@]}"}; exit $?
fi

if [ "${1:-}" = record ]; then
    shift; target=""; tr_id=""; why=""; mach=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --transcript) tr_id="${2:-}"; shift 2 || die "--transcript needs a claude session id" ;;
            --why) why="${2:-}"; shift 2 || die "--why needs clear, resume or start" ;;
            --machine) mach="${2:-}"; shift 2 || die "--machine needs a machine letter" ;;
            -*) die "unknown option for sessions record: $1" ;;
            *) [ -z "$target" ] || die "usage: salamander sessions record <id|name> --transcript <claude session id> --why clear|resume|start [--machine X]"; target="$1"; shift ;;
        esac
    done
    [ -n "$target" ] || die "usage: salamander sessions record <id|name> --transcript <claude session id> --why clear|resume|start [--machine X]"
    [ -n "$tr_id" ] || die "sessions record needs --transcript <claude session id>"
    case "$why" in clear|resume|start) ;; *) die "sessions record needs --why clear|resume|start, not '${why}'" ;; esac
    case "$tr_id" in *[!0-9A-Za-z_-]*) die "'$tr_id' is not a claude session id" ;; esac
    sessions_on || exit 0   # SALA_SESSIONS=off: nothing written, and not an error for a hook that calls this on every start
    sessions_record "$target" "$tr_id" "$why" "$mach"; exit $?
fi
if [ "${1:-}" = tag ]; then
    shift; target=""; targs=(); tdry=0; tauto=0
    tusage="usage: salamander sessions tag <id|name> [--project <page key>] [--role front|back] [--project-key <page key>] [--dry-run] | tag --auto [<id|name>] [--dry-run]"
    while [ $# -gt 0 ]; do
        case "$1" in
            --project|--role|--project-key) [ $# -ge 2 ] || die "$1 needs a value"; targs+=("$1" "$2"); shift 2 ;;
            --dry-run) targs+=(--dry-run); tdry=1; shift ;;
            --auto) tauto=1; shift ;;
            -*) die "unknown option for sessions tag: $1" ;;
            *) [ -z "$target" ] || die "$tusage"; target="$1"; shift ;;
        esac
    done
    if [ "$tauto" = 1 ]; then   # the roles come from stackshot's project record: no field is typed, one session or every live row with no role
        [ "${#targs[@]}" -eq "$tdry" ] || die "sessions tag --auto takes no --project, --role or --project-key: the project record gives them"
        sessions_on || die "SALA_SESSIONS=off: the registry is not maintained here, nothing written (set SALA_SESSIONS=write in the config first)"
        sessions_tag ${target:+"$target"} --auto ${targs[@]+"${targs[@]}"}; exit $?   # the session first: sessions.py's positional list ends at the first option
    fi
    [ -n "$target" ] || die "$tusage"
    [ "${#targs[@]}" -gt "$tdry" ] || die "sessions tag needs --project, --role or --project-key"
    sessions_on || die "SALA_SESSIONS=off: the registry is not maintained here, nothing written (set SALA_SESSIONS=write in the config first)"
    sessions_tag "$target" "${targs[@]}"; exit $?
fi
MODE=list; DRY=0; ALL=""; JSON=""
for a in "$@"; do
    case "$a" in
        --check) MODE=check ;;
        --migrate) MODE=migrate ;;
        --dry-run) DRY=1 ;;
        --all) ALL=--all ;;
        --json) JSON=--json ;;
        *) die "usage: salamander sessions [--all] [--json] | --check [--dry-run] | --migrate [--dry-run] | transcript <ref> [--json] | record <id|name> --transcript T --why clear|resume|start | tag <id|name> [--project P] [--role front|back] | tag --auto [<id|name>] [--dry-run] | resolve <ref> [--live] [--json]" ;;
    esac
done
[ "$MODE" = list ] || [ -z "$ALL$JSON" ] || die "--all and --json are for the listing"
[ "$MODE" != list ] || [ "$DRY" = 0 ] || die "--dry-run goes with --check or --migrate"
[ "$MODE" = list ] || [ "$MODE" = migrate ] || [ "$MODE" = check ] || die "usage: salamander sessions"

if [ "$MODE" = list ]; then
    sessions_py list ${ALL:+$ALL} ${JSON:+$JSON}; exit $?
fi

# a dry run only reads; a repair or the migration writes the registry under the pane map's lock, on the fleet's tmux server only (the map is its)
args=(--map "$SALA_SIDECAR" --lanes "$SALA_LANES" --models "$SALA_MODELS")
[ "$MODE" = migrate ] && args+=(--renames "$SALA_LOG_DIR/salamander-renames.jsonl")
if [ "$DRY" = 1 ]; then sessions_py "$MODE" "${args[@]}" --dry-run; exit $?; fi
sessions_on || die "SALA_SESSIONS=off: the registry is not maintained here, nothing written (set SALA_SESSIONS=write in the config first)"
on_fleet_server || die "this is not the fleet's tmux server ($FLEET_SOCKET_SEEN) — the registry follows the fleet's pane map; nothing written"
_mkparent "$SALA_SIDECAR"
( if command -v flock >/dev/null 2>&1; then flock -w 30 6 || { echo "✗ the pane map's lock is held (another write hung?) — nothing written" >&2; exit 1; }; fi
  sessions_py "$MODE" "${args[@]}" ) 6>>"$SALA_SIDECAR.lock"
