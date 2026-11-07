# lib/cipoll.sh — `salamander ci-poll` (the resident CI-run poller, run by sala-cipoll.service) and `salamander ci-runs` (its reader).
# The work is lib/cipoll.py (standard library + `gh api -i`, no model call); docs/ci-runs.md has the file's path and format. Sourced by bin/salamander ($sub is the verb).
ci_usage() {
    cat <<'USAGE'
usage: salamander ci-runs <owner/repo> [--sha SHA] [--max-age SECS] [--text]
       salamander ci-poll

  ci-runs  the GitHub Actions runs of <owner/repo> from the file the poller keeps (~/.local/state/salamander/ci-runs/<owner>__<repo>.json,
           format in docs/ci-runs.md): the file's JSON on stdout ({"repo","updated","updated_iso","runs":[…]}), the runs cut to those whose head
           commit starts with SHA (7 or more characters) when --sha is given (none: "runs":[], exit 0), or one tab-separated line a run with --text.
           No GitHub call is made. Exit 0 = the file is fresh; 3 = no file for that repo (the poller does not poll it, or has not run);
           4 = the file is older than --max-age seconds (default 120; 0 = no limit), the poller is not keeping it fresh; 5 = unreadable;
           2 = usage. On 3 and 4 nothing is printed on stdout and the reason on stderr: read GitHub yourself.
  ci-poll  the resident poller (sala-cipoll.service): every SALA_CIPOLL_INTERVAL s (60) one conditional read (ETag; a 304 is free) of
           repos/<repo>/actions/runs?per_page=30 for each repo in ~/.config/salamander/ci-repos (else lib/ci-repos, which lists none), one atomic file per repo.
           A GitHub error keeps the old file and backs off (doubling to SALA_CIPOLL_BACKOFF_MAX s, 600; a rate limit waits for its reset).
USAGE
}
case "${sub:-}" in
    ci-runs)
        case "${1:-}" in
            -h|--help) ci_usage; exit 0 ;;
            '') ci_usage >&2; exit 2 ;;
        esac
        exec python3 -I "$SALA_ROOT/lib/cipoll.py" runs "$@" ;;
    ci-poll)
        case "${1:-}" in -h|--help) ci_usage; exit 0 ;; esac
        exec python3 -I "$SALA_ROOT/lib/cipoll.py" poll ;;
esac
