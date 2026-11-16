# lib/codex-review.sh -- `salamander codex-review <owner/repo> <pr>`: Codex CLI reviews a PR read-only and the review is posted on it.
# The work is lib/codex-review.py (standard library, child processes for codex, gh and the public scan); docs/codex-review.md has the
# settings, the log and the trial. Sourced by bin/salamander ($sub is the verb); no tmux, no model call of sala's own.
cr_usage() {
    cat <<'USAGE'
usage: salamander codex-review <owner/repo> <pr>

  Has OpenAI's Codex CLI review the head of pull request <pr> of <owner/repo> (read-only: the diff only) and posts the review as a comment
  on the PR. A trial and a second opinion: it never blocks, delays or fails a merge or a release, so for a valid call it ALWAYS exits 0
  and prints one short line; a start from a script is detached and never waited for. Only howardpark-ai/salamander and howardpark-ai/stackshot
  are reviewed; any other repo is logged and left alone. One review per head sha. Exit 2 = a wrong call (this text on stderr).
  Log: <state>/codex-review/<owner>__<repo>-pr-<n>.log (~/.local/state/salamander/...), times in UTC. docs/codex-review.md.
  Settings (config file or environment): SALA_CODEX_REVIEW=off turns it off; SALA_CODEX_BIN (default ~/.local/bin/codex);
  SALA_CODEX_HOME (default ~/.config/codex, never ~/.codex); SALA_CODEX_MAX_DIFF bytes (300000), over it the PR is skipped;
  SALA_CODEX_TIMEOUT seconds (900); SALA_CODEX_PUBLIC_SCAN, the command of the privacy check a review passes before it is posted on a
  public repo (unset: the review is withheld, never posted unchecked).
USAGE
}
case "${1:-}" in -h|--help) cr_usage; exit 0 ;; esac
if [ $# -ne 2 ] || ! [[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || ! [[ "$2" =~ ^[0-9]+$ ]]; then cr_usage >&2; exit 2; fi
# the config file is sourced, not exported: hand the settings it (or the caller) set on to the python side
for _cr_v in SALA_CODEX_REVIEW SALA_CODEX_BIN SALA_CODEX_HOME SALA_CODEX_MAX_DIFF SALA_CODEX_TIMEOUT SALA_CODEX_PUBLIC_SCAN SALA_CODEX_SCAN_TIMEOUT; do
    [ -n "${!_cr_v+x}" ] && export "$_cr_v"
done
export SALA_STATE_DIR
# never fails a caller: whatever the python side ends with (a stop included), the exit status is 0
python3 -I "$SALA_ROOT/lib/codex-review.py" "$@" || true
exit 0
