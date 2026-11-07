# lib/job.sh — `sala job`: a scheduled job on this box as a systemd service + timer kept in the owning repo's git, with a Description=
# an X-Model-Lane= line and an X-Project= line (docs/units.md), and the check for the ones that are not. Sourced by bin/salamander; the work is lib/unitjob.py
# (standard library, no model call). Settings and the repo table: ~/.config/salamander/unit-repos.tsv (else lib/unit-repos.tsv, which lists no repo); SALA_JOB_GITHUB.
job_usage() {
    cat <<'USAGE'
usage: sala job add NAME --repo REPO --script PATH --schedule SCHEDULE [--schedule SCHEDULE …] --description "…" --lane LANE
                    --project PROJECT [--note "…"] [--args "…"] [--scope user|system] [--checkout DIR]
       sala job list
       sala job set-project NAME PROJECT [--checkout DIR] [--quiet]
       sala job remove NAME [--checkout DIR]
       sala job relink NAME
       sala job check [--post] [--quiet]

  add     writes NAME.service and NAME.timer into REPO's unit folder (the repo table's user_dir, e.g. ops/NAME/systemd/; salamander: systemd/), with
          Description=, X-Model-Lane= and X-Project= in the service's [Unit]; links them into ~/.config/systemd/user, daemon-reload, enable --now.
          --scope system only writes the files and prints the root command (sala never uses sudo). It prints the git status and the
          exact commit steps and commits nothing: a repo with flow main commits straight to main; salamander (and any repo with flow pr) goes by branch
          and pull request, from a worktree given as --checkout. A repo with no unit folder (stackshot renders its units from templates)
          is refused with the reason. Refused too: a missing or invalid --description, --lane or --project, an unknown REPO, a --script that is
          not a file, a taken NAME. LANE: subscription-1 | bedrock | aws-platform | api | subscription-2 | sdk | none (max and team still work) (the model lane the script runs on;
          none = no model call). PROJECT: scope/project, written as the Agents table's Project column shows it (team/demo, team/web-app,
          alpha/site, team/docs); it is the job's category on the Overview's Schedules tab. SCHEDULE: an OnCalendar expression ("*-*-* 03:00:00 UTC", "daily") or OnBootSec=5min /
          OnUnitActiveSec=1h (repeat --schedule for several). --note: a few words shown beside the lane (X-Model-Note=).
  list    our timers (not a package's): name, repo, schedule, lane, project, whether the unit files are in git.
  set-project  writes X-Project=PROJECT into a job's service file in git (replaces the line, or adds it after X-Model-Lane=) and prints what to
          commit (--quiet: not that); a flow-pr repo (salamander) needs the worktree as --checkout. A system-scope job (its unit file in /etc/systemd/system links to the git file) is edited the same way, with no root. A unit rendered from a template (stackshot's) is refused: edit the template.
  remove  disable and stop the timer, unlink the files, delete them from the repo checkout; prints what to commit.
  relink  once a pull request that added a job is deployed, point its links at the production checkout.
  check   the gap watcher's pass: our timers with no Description=, no X-Model-Lane=, no X-Project= or not in git. --post opens each gap as one board
          item (client.py post job-gap open, once per timer and gap; its mover is the builder of the repo that owns the script)
          and closes the item when the gap is fixed (post job-gap clear); it also runs from the sala-unit-gaps.path unit and
          from the sala-watch tick.
USAGE
}
case "${1:-}" in
    ''|-h|--help|help) job_usage; [ -n "${1:-}" ] || exit 2; exit 0 ;;
    add|list|remove|relink|check|set-project)   # the stackshot client's place and the state folder go to python only when the config sets them (python defaults the same way)
        [ -n "${SALA_STACKSHOT_DIR+x}" ] && export SALA_STACKSHOT_DIR; [ -n "${SALA_STACKSHOT_CLIENT+x}" ] && export SALA_STACKSHOT_CLIENT; export SALA_STATE_DIR; [ -n "${SALA_JOB_GITHUB+x}" ] && export SALA_JOB_GITHUB; [ -n "${SALA_UNIT_PROJECT_MAP+x}" ] && export SALA_UNIT_PROJECT_MAP
        exec python3 -I -S "$SALA_ROOT/lib/unitjob.py" "$@" ;;
    *) echo "salamander job: unknown verb '$1'" >&2; job_usage >&2; exit 2 ;;
esac
