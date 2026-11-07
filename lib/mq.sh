# lib/mq.sh — `salamander mq`, our own merge queue (shadow mode tests and merges nothing; mode on merges; off is the default and the instant fallback). The work is lib/mq/ (Python standard library, git and gh);
# docs/mq.md has the design, the files and the call budget. Sourced by bin/salamander ($sub is the verb).
mq_usage() {
    cat <<'USAGE'
usage: salamander mq add N… [--flag recycle] [--repo OWNER/NAME]
       salamander mq status [--json] [--repo OWNER/NAME]
       salamander mq drop N [--repo OWNER/NAME]
       salamander mq pause [--reason TEXT] [--repo OWNER/NAME]
       salamander mq resume [--repo OWNER/NAME]
       salamander mq wait N [--timeout SECS] [--repo OWNER/NAME]
       salamander mq doctor [--repo OWNER/NAME]
       salamander mq drive --repo OWNER/NAME        (internal: the driver, started for you)

A queue for the pull requests of a repo that has no GitHub merge queue. It works as GitHub's does: one entry per PR, each stacked on the entry ahead of it (main + PRs 1..k) and
pushed as queue/main/g<seq>, all tested at once (up to inflight_max, six when the rules do not say) by the required check (default `suites`), merged strictly in line order. An entry that
fails is failed alone and the entries behind it are rebuilt on the one ahead of it (`status` shows "(on gN)" for a stacked entry). A PR whose own checks failed (`pr_required`, default
every check on its head) or that conflicts with main is refused when it joins and again before its verdict counts: "refused: a check failed: <name>=fail" / "refused: conflicts with main",
the wait exit 1. A repo's release script uses it the same way: `mq add N`, then `mq wait N`. The rules keys of the removed group mode are retired: `group_max` and `bisect` are ignored with a
warning (delete the line), `queue_mode = "group"` blocks the queue until the line is deleted; `queue_mode = "chain"` is accepted. --repo defaults to the
GitHub origin of the current folder. State: $XDG_STATE_HOME/mergequeue/<owner>__<repo>/ (queue.json, groups/g<seq>.json, events.log).

  Modes (host file $XDG_CONFIG_HOME/mergequeue/<owner>__<repo>.toml, `mode = "off" | "shadow" | "on"`; absent = off). SHADOW builds and tests entries and writes the verdict
  down, with what it WOULD have merged in the journal (`would_merge`); it merges nothing, sets no status and comments on nothing.
  `on` merges (a passed entry goes to main as a fast-forward, never forced; a commit status and one comment on a failure) and is open: `mode = "on"` in the host file makes the driver merge. `off` stays the default and the instant fallback.
  Rules of the repo: .github/mergequeue.toml, read from origin/main (base, required, pr_required, queue_prefix, inflight_max, suites, on_conflict, …).

  add     put PRs in the line, in order (a PR already in it is left where it is); starts the driver, a transient user unit mq-<owner>__<repo>
          (mq-<owner>__<repo>-<run>-<case> with a replay file; systemd-run --user), when none is running. The driver exits when the line is empty and nothing is in flight.
  status  the line, the entries in flight (phase, branch, head, members) and the PRs that finished lately; --json is the same as one object.
          A "REPLAY:" line says a replay file is in use.
  drop    take a PR out of the line (a PR whose entry is in flight stays in that entry's tree until the driver ends the entry, which is never merged with it; the entries behind it are rebuilt without it).
  wait    block until PR N is settled, reading the state file (no GitHub call). Exit 0 = merged, 1 = ejected, failed or dropped (the reason on
          stderr), 2 = gave up (--timeout), not in the line, or the queue is blocked, 3 = tested in shadow mode: its entry passed, nothing was merged,
          4 = replay with ci = "skip": the entry was built, nothing was pushed or tested (never read it as a pass).
  pause   no entry starts and nothing is pushed to main; entries in flight finish testing and wait. resume goes on (and starts the driver).
  doctor  checks the host file, the tools, the state files, the driver and its lock, the repo config as last fetched, queue branches and worktrees
          that no live entry owns (one git ls-remote, of the queue's own queue_prefix only). Exit 0 = all ok, 1 = a problem, each named with the fix.

  Replay (stackshot's `mq replay`, on practice branches of the same repo). The host key `replay = "/abs/path/replay.json"` makes the queue take its RULES (the keys of
  .github/mergequeue.toml, same checks) and the facts of each PR (state, draft, head sha, branch, owner, checks) from that file instead of origin/main and GitHub, so a PR that
  is already merged can join; no GraphQL call. Each head is fetched by its sha. SHADOW ONLY: `mode = "on"` is refused, nothing is merged, set as a status or commented, and no push
  goes outside queue/practice/. rules.base must start with practice/ and rules.queue_prefix with queue/practice/, else the queue is blocked. The file: {"version": 1, "run": R, "case": C,
  "ci": "real" | "skip", "rules": {...}, "prs": {"<N>": {"state", "draft", "head", "branch", "owner", "checks": {name: pass|fail|pending|cancel}}}}; an unknown key or a bad value is refused
  with the message. ci "skip" ends an entry after it is built (no push, no CI): the PRs are "tested (CI not run)", `mq wait` exit 4. docs/mq.md has the schema.

Every GitHub call an entry makes is counted in its record (gh_calls, salamander_calls) and journaled; in the normal case an entry costs one GraphQL
read for the build, one for the recheck before its verdict counts, and the check-runs reads of its head, none while the CI-run poller's file shows the run going. Git over the remote is not a GitHub API call.
USAGE
}
case "${1:-}" in
    -h|--help|help) mq_usage; exit 0 ;;
    '') mq_usage >&2; exit 2 ;;
esac
exec python3 -I "$SALA_ROOT/lib/mq/main.py" "$@"
