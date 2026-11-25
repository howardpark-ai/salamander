# lib/machines.sh — `sala machines [--json]` and `sala host ROLE [--field F | --set HOST]` (docs/subcommands.md).
# Sourced by bin/salamander. Both verbs are lib/machines.py: they read the owner's machine files (the fleet names file SALA_FLEET_NAMES and the files beside it,
# SALA_MACHINE_FOLLOW_MACHINES for the follow list) and need no running sala and no sala-web. `machines` only reads; `host` runs the holds script's `host`
# and, with --set, its `set-host` (the script takes its own lock and refuses a host it does not know), passing its output and exit code through unchanged.

machines_usage() {
    cat <<'USAGE'
usage: sala machines [--json]

  Lists the fleet's machines, one line each: name, board letter, hostname, ssh alias, the host roles it holds (sala-host, stackshot-host), whether it is
  retired, and which of the machine files name it. A machine one file names and another does not is still listed, with the missing parts shown as a dash.
  A last line "not read: ..." names a file that was looked for and could not be read.
  --json    one object instead: {"schema":1,"machines":[{name,hostname,letter,ssh,addresses,roles,retired,sources,online,last_seen,versions,checked}],"not_read":[...]}.
            The last four are readings, as the heartbeat posts them: online and last_seen from `tailscale status --json` (null = not read), versions (this
            machine's own claude and sala; {} = none read) and checked (epoch seconds).

  The files are the owner's: the fleet names file (SALA_FLEET_NAMES in sala's config) and, beside it, the tailnet candidates, the ssh fleet config, the
  host record and, for the follow list, SALA_MACHINE_FOLLOW_MACHINES. Read-only; it needs no running sala and no sala-web.
  Exit 0 listed · 2 usage, or no machine files are named.
USAGE
}

host_usage() {
    cat <<'USAGE'
usage: sala host ROLE [--field FIELD | --set HOST]

  ROLE is sala or stackshot: the machine that hosts it now, from the host record.
  sala host ROLE                 prints hostname|ipv4|ipv6|ssh alias, the way the holds script's `host ROLE` does.
  sala host ROLE --field FIELD   prints that one value: hostname, ipv4, ipv6 or ssh.
  sala host ROLE --set HOST      records HOST as the host (only a move of sala or stackshot does this, at the end). HOST must be a host the tailnet candidates list;
                                 the script refuses any other, writes nothing and says why. It prints "ROLE: old -> new".
  Both run the holds script (machine_holds.py, beside the other machine files under the folder of SALA_FLEET_NAMES) and pass its output and exit code through
  unchanged; the script does the locking and the checks. Needs no running sala and no sala-web.
  Exit: the script's own (0 done · 2 refused or unknown role or field), 2 here for a usage error or a missing script.
USAGE
}

machines_main() {
    case "${1:-}" in -h|--help) machines_usage; return 0 ;; esac
    command -v python3 >/dev/null 2>&1 || { echo "sala machines: python3 is not installed" >&2; return 2; }
    SALA_FLEET_NAMES="${SALA_FLEET_NAMES:-}" SALA_MACHINE_FOLLOW_MACHINES="${SALA_MACHINE_FOLLOW_MACHINES:-}" SALA_CLAUDE="${SALA_CLAUDE:-}" python3 "$SALA_ROOT/lib/machines.py" list "$@"
}

host_main() {
    case "${1:-}" in -h|--help) host_usage; return 0 ;; '') host_usage >&2; return 2 ;; esac
    command -v python3 >/dev/null 2>&1 || { echo "sala host: python3 is not installed" >&2; return 2; }
    SALA_FLEET_NAMES="${SALA_FLEET_NAMES:-}" SALA_MACHINE_FOLLOW_MACHINES="${SALA_MACHINE_FOLLOW_MACHINES:-}" python3 "$SALA_ROOT/lib/machines.py" host "$@"
}
