#!/usr/bin/env bash
# contrib/backfill-job-projects.sh — the one-time backfill of `X-Project=<scope/project>` for the jobs that exist today (docs/units.md).
#
# Each job stores its own project (the category on the Overview's Schedules tab, written as the Agents table's Project column shows it) in the
# [Unit] section of its service file. A new job gets it from `sala job add --project`; this script gives the existing ones theirs by running
# `sala job set-project NAME PROJECT --quiet` for each, from the box's map (SALA_BACKFILL_MAP, below). A job that is not in the map is left
# alone, so `sala job check` reports it as `no-project` and the owner decides. The mapping lives in that file and nowhere in the code.
#
# Run it ONCE, right after the release that brings `--project`/`set-project` is deployed (until it has run, `sala job check --post` opens up to
# three `no-project` board items per pass for the jobs in the map): the units of salamander already carry X-Project= from that release (reported
# "already"), the units in other repos are edited in place (a repo with flow main: its working tree, nothing committed here), and the script ends
# by printing the commit steps. It is safe to run again: a job that already has its project is "already", never rewritten.
#
# Usage: bash contrib/backfill-job-projects.sh [--dry-run]     (exit 0 = every listed job is set or was set, or there is no map; 1 = a job failed
#   or is missing; 2 = a bad argument or a bad map)
#   --dry-run   changes nothing: says per job what would be done
# THE MAP: the file SALA_BACKFILL_MAP names (the environment, else its line in the sala config, ~/.config/salamander/config or $SALA_CONFIG;
# a leading ~ is the home directory). One line per project, `scope/project: job job …` (lower case, as the Agents table shows it), and an optional
# `rendered: job …` line for the units another repo's installer renders from a template (set-project refuses them, so they are reported
# `skipped`). `#` starts a comment line. A job named twice is refused before anything is done. Unset or empty: no map, nothing to do (exit 0).
# Environment (the tests point these at a temporary tree): SALA_BACKFILL_SALAMANDER (the salamander command, default bin/salamander beside this
# folder), SALA_JOB_USER_DIR (~/.config/systemd/user), SALA_JOB_SYSTEM_DIR (/etc/systemd/system) — the same variables `sala job` reads.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
SALA=${SALA_BACKFILL_SALAMANDER:-$HERE/bin/salamander}
USER_DIR=${SALA_JOB_USER_DIR:-$HOME/.config/systemd/user}
SYS_DIR=${SALA_JOB_SYSTEM_DIR:-/etc/systemd/system}
DRY=0
case "${1:-}" in
    "") ;;
    --dry-run) DRY=1 ;;
    *) echo "usage: bash contrib/backfill-job-projects.sh [--dry-run]" >&2; exit 2 ;;
esac

# the map file: SALA_BACKFILL_MAP from the environment when set, else the last `SALA_BACKFILL_MAP=` line of the sala config (read, never sourced)
MAPFILE=${SALA_BACKFILL_MAP-}
if [ -z "${SALA_BACKFILL_MAP+x}" ]; then
    cfg=${SALA_CONFIG:-$HOME/.config/salamander/config}
    [ -r "$cfg" ] && MAPFILE=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}SALA_BACKFILL_MAP=//p' "$cfg" | tail -1 | sed 's/[[:space:]]\{1,\}#.*$//; s/^"\(.*\)"$/\1/; s/^'"'"'\(.*\)'"'"'$/\1/')
fi
case "$MAPFILE" in "~"|"~/"*) MAPFILE=$HOME${MAPFILE#\~};; '$HOME'|'$HOME/'*) MAPFILE=$HOME${MAPFILE#\$HOME};; esac
if [ -z "$MAPFILE" ]; then echo "backfill: no map (SALA_BACKFILL_MAP is not set): nothing to do"; exit 0; fi
[ -r "$MAPFILE" ] || { echo "backfill: the map $MAPFILE (SALA_BACKFILL_MAP) is not readable" >&2; exit 2; }
# project: the jobs in it; the rendered: line apart
MAP=$(grep -v '^[[:space:]]*\(#\|$\)' "$MAPFILE" | grep -v '^rendered:')
RENDERED=" $(sed -n 's/^rendered:[[:space:]]*//p' "$MAPFILE" | tr '\n' ' ')"
while IFS= read -r line; do
    [ -n "$line" ] || continue
    [[ $line =~ ^[a-z][a-z0-9-]*/[a-z0-9][a-z0-9._-]*:\  ]] || { echo "backfill: not a 'scope/project: job …' line in $MAPFILE: $line" >&2; exit 2; }
done <<< "$MAP"
dups=$(sed 's/^[^:]*://' <<< "$MAP" | tr ' ' '\n' | grep . | sort | uniq -d | tr '\n' ' ')
[ -z "$dups" ] || { echo "backfill: a job is named twice in $MAPFILE: ${dups% }" >&2; exit 2; }

set_n=0; already=0; failed=0; missing=0; skipped=0; changed=()
while IFS= read -r line; do
    [ -n "$line" ] || continue
    project=${line%%:*}
    for name in ${line#*: }; do
        svc=$USER_DIR/$name.service
        [ -e "$svc" ] || svc=$SYS_DIR/$name.service
        if [ ! -e "$svc" ]; then
            echo "  missing   $name: no $name.service on this box (nothing to do)"; missing=$((missing + 1)); continue
        fi
        if grep -qx "X-Project=$project" "$svc"; then
            echo "  already   $name: X-Project=$project"; already=$((already + 1)); continue
        fi
        if [[ $RENDERED == *" $name "* ]]; then
            echo "  skipped   $name: its unit is rendered from a template; add X-Project=$project to [Unit] of the template in its repo (e.g. units/$name.service.in), then re-run its install"
            skipped=$((skipped + 1)); continue
        fi
        if [ "$DRY" = 1 ]; then
            echo "  would set $name: X-Project=$project"; set_n=$((set_n + 1)); continue
        fi
        out=$("$SALA" job set-project "$name" "$project" --quiet 2>&1); rc=$?
        if [ "$rc" = 0 ]; then
            echo "  set       $name: X-Project=$project"; set_n=$((set_n + 1))
            p=$(printf '%s\n' "$out" | sed -n 's/^.* in \(.*\.service\)$/\1/p' | head -1); changed+=("${p/#\~/$HOME}")
        else
            echo "  FAILED    $name: $(printf '%s' "$out" | tr '\n' ' ')"; failed=$((failed + 1))
        fi
    done
done <<< "$MAP"

echo "backfill: $set_n $([ "$DRY" = 1 ] && echo 'would be set' || echo set), $already already set, $skipped skipped, $missing missing, $failed failed"
if [ "$DRY" = 0 ] && [ "${#changed[@]}" -gt 0 ]; then
    # one set of commit steps per repo that was edited (set-project prints none with --quiet)
    declare -A by_root=()
    for f in "${changed[@]}"; do
        [ -n "$f" ] || continue
        root=$(git -C "$(dirname "$f")" rev-parse --show-toplevel 2>/dev/null) || continue
        by_root[$root]+="${f#"$root"/} "
    done
    for root in "${!by_root[@]}"; do
        echo "to commit in $root (nothing is committed or pushed here):"
        echo "  git -C $root add -- ${by_root[$root]% }"
        echo "  git -C $root commit -m 'units: X-Project= for the existing jobs (backfill)'"
        echo "  git -C $root pull --rebase --autostash && git -C $root push"
    done
fi
[ "$failed" = 0 ] && [ "$missing" = 0 ]
