# mq: our own merge queue for repos without GitHub's

`salamander mq` is a merge queue for a repository that cannot use GitHub's own merge queue. It works as GitHub's merge queue does: **one entry per PR, each stacked on the entry ahead of it, all tested at once**, merged into `main` in line order. There is one mode; a failing
entry is failed alone and the entries behind it are rebuilt on the one ahead (*The chain*). (An older group mode, which tested waiting PRs together as one group and bisected a failed group, was removed; the repo keys
`group_max`, `bisect` and `queue_mode = "group"` went with it: *Configuration*.)

This page is the design and what is built of it. The queue builds, pushes and tests entries and, in mode `on`, pushes the tested head to `main`, posts a commit status per PR and one comment on a
failure. **Mode `on` is open**: `mode = "on"` in the host file makes the driver merge (`ON_OPEN` in `lib/mq/mq_config.py` is `True`; Migration, 5). `off` stays the default and the instant
fallback. In mode `shadow` the queue still merges nothing, posts no status and writes no comment; it journals what it
would have merged. Everything marked *later* is a following step and is not in the code yet. A host key `replay` runs the same queue on a practice branch from a file of
rules and PR facts, for stackshot's replay of past PRs: see *Replay*. To put another repository on the queue, see *Using the queue for another repo*.

## What problem

Without a queue every PR is released alone. A PR that is behind `main` is brought up to date (a GitHub write), then waits for its own retest,
for several rounds when `main` moves again, so a burst of N PRs takes N times one test run while the runners sit idle. A queue tests the
waiting PRs once, each on the PR ahead of it, all side by side across the runners, and moves `main` once per PR.

The queue is meant to be easy to delete: GitHub's own merge queue does the same job where a repository can have it, and the swap is one workflow
trigger and this one command. Hence the names follow GitHub's wherever the idea is the same.

## Against GitHub's merge queue

| GitHub merge queue | mq | |
|---|---|---|
| an entry in line | an entry of `queue.json` (PR, flags, state); the head is pinned when its entry is read | same; added by `mq add`, not by a button |
| a temporary branch `gh-readonly-queue/main/pr-N-<sha>` | `queue/main/g<seq>`: the entry ahead (or `main`) plus this PR, built with `git merge --no-ff` | same idea, own prefix (GitHub reserves its prefix and it would clash the day the real queue is on); `g<seq>` is a name kept from the first version, one branch per entry |
| the `merge_group` event runs the workflows | a `push` to `queue/**` runs them | different, forced: `merge_group` fires only when the real queue is on. The workflow keeps one expression for "this is a queue run", so the swap is one line |
| required checks must pass on the entry's ref | `required = ["suites"]`, read from the check runs of the entry's head: completed and `success` | same rule, enforced by mq itself because the repository cannot enforce it |
| speculative: entry N is built on entry N-1's ref | an entry is built on the head of the entry ahead of it (*The chain*) | same |
| GitHub fast-forwards `main` to the tested ref | `git push origin <entry head>:main`, never forced | same result, different actor |
| wait time, concurrent builds | `inflight_max` entries in flight (default 6) | same knob |
| on failure the PR is removed and the rest rebuilt | the failing entry is failed alone and the entries behind it are rebuilt on the one ahead | same |

## What is built, and what comes later

| | built | later |
|---|---|---|
| state, locks, `queue.json`, `groups/`, `events.log` | yes | |
| `mq add / status / drop / wait / doctor`, the driver | yes | |
| `mq pause` / `mq resume` | yes | |
| build an entry (`git merge --no-ff`, the snapshot conflict hook, ejecting a conflicting PR) | yes | |
| refuse a PR whose own checks failed, or that conflicts with main, when it joins and again before its verdict counts | yes (*Which PRs join and stay*) | |
| push `queue/main/g<seq>`, read the verdict of the required check, record it, delete the branch | yes | |
| a PR per entry, each stacked on the entry ahead, tested side by side, `inflight_max` from config | yes (*The chain*) | |
| one rerun after an infrastructure failure, the `flaky` list | no | yes |
| commit status on each PR, the one comment | yes, in mode `on` only | |
| the merge push (`main` becomes the tested head), the PR check before it, a moved `main` (the entry is stale and rebuilt) | yes, in mode `on` only; shadow journals `would_merge` | |
| the repo's deploy lock around the merge push | yes (`deploy_lock`); `deploy_hook` is read and checked only | the hook, with the release script |
| sweep of stale `queue/**` branches | `mq doctor` names them | the driver removes them |
| a second poller file for push runs | no | yes |

`mode = "on"` in the host file makes the driver merge, and `mq add` accepts it (`ON_OPEN` is `True`; with `False` it refuses `on`, and the tests set it `False` to reach that refusal). `off` stays the default
and the instant fallback: `mq add` then refuses new PRs at once. Switching a host file from `shadow` to `on` merges the PRs already waiting.

A lone PR keeps its own path: the repo's release script merges one waiting PR itself, with no run of the queue, when nothing could differ (*Using the queue for another repo*, 4). That shortcut is the script's, not mq's, and is kept on purpose.

## The chain

**What it does.** Each waiting PR becomes its own entry (a record with one member), stacked on the entry ahead of it: entry k is `main` plus PRs 1..k in line order, built by `git merge --no-ff`
of the PR's pinned head onto the head of entry k-1 (the record names it: `stack_on`, the entry; `stack_base`, its head; `ahead`, the PRs under it). Every entry is pushed as its own `queue/main/g<seq>`
branch and tested by the repository's own workflow, **all at once**, up to `inflight_max` entries (default **6**; 1 to 16). Entries are merged to `main` strictly in line order,
each a fast-forward of `main` to the entry's head, as the entry ahead of it merges.

- **A pass waits for the entry ahead.** An entry whose check passed is held (`mq status` shows `tested, waiting for g2`) until the entry ahead of it is merged (shadow: tested), then goes to `merging`. The merge step
  also refuses to run while the entry ahead is unmerged.
- **A failure is the PR's own once the entry ahead has passed.** Entry k's tree holds PRs 1..k-1, so a failure is only attributed to PR k when entry k-1 has a passing verdict (or is merged): until then entry k waits
  with its verdict. When that holds, PR k is **failed alone**, with the usual failure status and one comment.
- **The entries behind it are rebuilt.** Their trees hold the failed PR. Each one is **restacked**: its branch is deleted, the PR goes back to `waiting` at its place in the line ("back in the line: PR #N ahead of it
  left the line"), and a new entry is built for it on the entry ahead of the failed one (or on `main` when nothing is ahead), then tested again. A restack is not a rebuild in the sense of `MQ_MAX_REBUILDS`: it does not count, because it is
  caused by an entry ahead leaving, which happens once per entry. A new entry is not started while any entry in flight is failing or being restacked, so new entries always stack on a sound tail.
- **The same restack happens** when the entry ahead is ejected (a conflict at the build or at the merge step, a failed check on the PR's head), dropped with `mq drop` (a dropped PR's entry ends at once), goes stale because `main` moved from outside the chain
  (that entry is rebuilt, counting against `MQ_MAX_REBUILDS`; the entries behind it restack), or is built again with another head.
- **A conflict** with the PR ahead is found when the entry is built: `refused: conflicts with main or with PR #M ahead of it`, and the PR is ejected; the entries behind it are built on the entry ahead of that one.
- **`inflight_max`** counts entries that are not done: tested, or passed and waiting for the entry ahead to merge. The next entry is claimed one pass after the previous one is built.
- **Shadow mode** runs the same chain and merges nothing: an entry counts as settled when it is `tested`, and the entries behind it follow. Statuses and comments are mode `on` only, as always.
- **Costs.** Two GraphQL reads per PR (its build, the read before the merge) and one check-runs read per poll of each entry in flight. The chain trades more CI runs (one per PR, and a rebuild per
  PR behind a failure) for a failure that names its PR with no split and for runs that all start at once.

**For a repository's release script** (the count rule stays the caller's: a lone PR keeps its own path or shortcut; two or more waiting PRs go through the queue):

```sh
salamander mq add 41 42 43 --repo owner/name     # queued in this order; starts the driver if none runs
salamander mq wait 42 --timeout 5400 --repo owner/name
case $? in
  0) echo "merged" ;;                              # the line printed: PR 42 merged: merged in group g2 at abc1234 [g2]
  1) echo "ejected, failed or dropped" ;;          # the reason is on stderr
  2) echo "gave up, not in the line, or the queue is blocked" ;;
  3) echo "tested in shadow mode: nothing was merged" ;;
esac
```

A PR is `add`ed once and `wait`ed once; a restack changes nothing for the caller (the PR is `waiting` again, so `wait` goes on, and its result line names the entry that merged it). `wait` on PR k can
return `merged` before PR k+1 is, never after. The rules (optionally `inflight_max`) are in the repository's `.github/mergequeue.toml`; the host file (`mode`, `remote`, `deploy_lock`) is separate.
`mq status` shows an entry stacked on another as `(on g2)`.

**Names kept from the first version.** The queue's records are still called groups on disk and on the wire, because other tools read them: `groups/g<seq>.json`, the branches `queue/main/g<seq>`, `mq status --json` (its `groups` and `queue`
keys, the entry states `waiting` and `grouped`), the status text `testing in group g3 with #3 on top of #1 #2`, the result line `merged in group g2 at abc1234 [g2]`, and the reason `left the group before the merge`. A group is an entry of one PR.

**Records an older version left.** A record with more than one PR, or the parent or a half of a bisect, is not run. The driver retires it at its next step: the record ends as `restack` / `stale` ("group mode was removed: the queue tests one PR an entry, and this record was not run"),
`legacy_group_retired` is journaled with its PRs, its PRs go back to `waiting` with no rebuild counted, and its branch and worktree are cleaned like any entry's. One exception keeps a merge whole: a tested record in `merging` whose head is
already in `main` (the old driver died after its push) is `merged` as it always was (`legacy_group_merged`, no second push). No new entry is stacked while a retired record is still live. Finished records in `groups/` are left as they are and aged out like any other.

## Where entries are built

In an mq-owned clone under the state folder (`work/`, plus one worktree per entry under `worktrees/g<seq>`, removed when the entry ends), never in
a production checkout. An entry is built by git only, no REST call: fetch `main` and the PR's `refs/pull/N/head` (which works for forks too), then
`git merge --no-ff` the pinned head onto the head of the entry ahead (or onto `main`), with the message `Merge pull request #N from <owner>/<branch>` that `gh pr merge --merge` writes.
The branch is pushed so the runners can fetch the combined tree, and deleted at the end of the entry.

A merge that conflicts: if every conflicted path is in `conflict_paths` (default `tests/tool_text.snapshot.json`) and the repo config has an
`on_conflict` command, mq runs it in the worktree (`MQ_PR`, `MQ_CONFLICT_FILES` and `MQ_WORKTREE` in its environment); exit 0 means it wrote the
resolved files, which mq adds and commits. Any other conflict, or a failing hook, ejects that PR (`conflicts with main or with PR #M ahead of it`)
and the entries behind it go on. A PR whose head is already in the tree is ejected too, with nothing to merge. PR branches are never touched. The hook is a command
read from `main`, so it is as trusted as the repository's own scripts; a PR cannot change it.

Before building, ONE GraphQL read tells whether the PR is open, a draft, its base branch, head sha and head branch, and the checks
reported on that head. A closed, merged, draft or missing PR, one that targets another branch, or one with a failed check (next section), is ejected with the
reason; the head is pinned. After fetching, a PR whose
`refs/pull/N/head` is not the pinned sha (the author pushed in between) is ejected: `head moved since it was read`.

## Which PRs join and stay

An entry's run tests the merged tree by the repo's `required` checks (`suites`), which is not everything a PR is held to: a check that runs only on the PR itself
(the old release path reads them all with `gh pr checks`) may not show in a queue run at all. So a PR is also judged by the checks reported on its own head, and by whether
it still merges into the base branch, at two moments: when it joins (the build's GraphQL read, and the build's merge) and before its entry's verdict counts
(the same GraphQL read once more, in mode on at the merge step, in shadow before the PR is marked `tested`). The words are parallel to the release script's FAILED
line, so a shadow comparison can read both the same way:

| | ejected with the reason |
|---|---|
| a check on the PR head failed, was cancelled or timed out (`failure`, `timed_out`, `startup_failure`, `action_required`, a failed or errored commit status) | `refused: a check failed: <name>=fail, <name>=cancel` (names sorted) |
| the PR does not merge into the base branch (the build's merge, or, in shadow, a merge of its head into the base branch's tip once the base moved) | `refused: conflicts with main (<files>)`, or `refused: conflicts with main or with PR #M ahead of it (<files>)` when other PRs are in the tree |

- **What counts as a check.** `pr_required` in the repo file: `"all"` (the default) is every check reported on the head, which is what the release script reads, or a list
  of check names, for a repo that wants only those. A check that is pending, skipped or neutral is not a failure (the entry's own run tests the tree), and neither is one
  that failed once and passed on its re-run (the newest run of a name wins). The queue's own commit status (`merge queue`) is left out, so a refusal it posted never refuses the PR again.
- **A conflict on the files `conflict_paths` names**, with an `on_conflict` hook, is mended, not refused, as in the build.
- **Mode on.** A PR that was told (a failure status on its head and ONE comment) is taken out of the line. At the merge step a refused PR makes its entry stale, as a moved head
  does: the entries behind it are rebuilt without it. A moved base branch already makes the entry stale, and the rebuild meets the conflict.
- **Shadow.** The entry is not rebuilt (nothing is merged, so no rebuild would be needed to get a verdict): a refused PR is ejected, the others stay `tested`, and the journal says
  `recheck_ejected`. The conflict check is `git merge-tree` of the PR's pinned head with the base branch's tip, done only when the base branch moved since the entry was built.
  A check that git cannot make is journaled (`conflict_check_failed`) and holds nothing against the PR.
- A failed check is named before a head that moved: a PR whose own checks failed does not merge on any head.

## The verdict

The entry's head is tested by the repository's own workflow on the `queue/**` push. mq reads the verdict of the checks named in `required` on that
head:

1. `salamander ci-runs <repo> --sha <head>` (the CI-run poller's file, `docs/ci-runs.md`; no GitHub call). If it is fresh and lists a workflow run of
   the head that has not completed, mq waits and asks GitHub nothing. It can only say "still going", never pass or fail an entry.
2. Otherwise one read of `repos/<repo>/commits/<head>/check-runs` through `gh api -i` with the last ETag as `If-None-Match` (a 304 is free at GitHub and
   is counted on its own). A check is judged by its newest run (a re-run supersedes an older one). Every required check completed with `success` is a
   `pass`; one completed without `success` is a `fail`; anything else is pending.
3. No verdict `MQ_WAIT_CAP_SECS` (100 minutes) after the push is a `timeout`, recorded as a failure.

The verdict, with the detail per check, the run link and the call counts, goes into the entry's record and the journal. Then (the next section) the entry is merged or ended;
the branch is deleted and the worktree removed, and the PR is marked `tested` (shadow), `merged`, `failed` or sent back to `waiting`.

## What happens after the verdict

Phases, in order: `building`, `built`, `pushed`, `testing`, `verdict`, then by the verdict `merging` (mode on, a pass), `cleaning`, `done`. An entry also has a `state` word for people and for `mq status`:
`building`, `testing`, `passed`, `failed`, `merging`, `merged`, `stale`, `tested` (shadow), and `timeout` / `error`. Each is written before the step it names, and re-entered after a crash.

**A pass.** Shadow: the PR is `tested` and the journal has `would_merge` (entry, PR, head, base). Mode on: phase `merging`.

- The merge waits while the queue is paused, and until the entry ahead is merged.
- It takes the repo's deploy lock if the host file names one (`deploy_lock`: a file, `flock`ed for the push only; busy means try again next tick, journaled once).
- It fetches `main`. A tested head already in `main`'s history (the driver died after the push) is `merged` with no second push.
- **Absorbing a moved `main`.** If `main` is neither the entry's base nor an ancestor of its head, the tested tree is not what `main` would get: the entry is
  **stale**. Its PR goes back to `waiting`, in its place in the line, and is built again on the new `main` (one more run; `MQ_MAX_REBUILDS`, 3, then the PR fails with that
  said); the entries behind it restack. This is the smallest sound rule: it never merges a tree that was not tested. Cheaper rules (merge when the files `main` gained touch nothing the entry did) are *later*.
- It reads the PR once more (one GraphQL call): a PR that is closed, a draft, has another base or has a new head is ejected and the entry is stale. A PR dropped with `mq drop`
  after the entry was built is treated the same.
- Then `git push origin <head>:refs/heads/main`: a fast-forward by construction, with no force and no lease, so a `main` that moved in between makes the remote refuse; mq reads `main`
  again, and if it moved the entry is stale, otherwise the push is retried like any step. After `MQ_MAX_FAILS` failures the queue **pauses** (`by: driver`) with the reason and the entry keeps
  waiting in `merging`; it is not failed, it was tested. `mq resume` goes on.
- GitHub marks each PR merged by itself, because `main` now contains its head. mq does not delete PR branches.

**A failure.** The PR is `failed` alone (reason: which check, which entry: `group g2 failed suites`), once the entry ahead has passed (*The chain*); the entries behind it are restacked. A timeout, an error or an empty entry (every PR ejected) fails or
ends the entry with the reason and nothing is split.

**What a PR sees (mode on only).** A commit status on its head, context `merge queue`: `pending` ("testing in group g3 with #3 on top of #1 #2", and "back in the line: ..." for a stale entry), `success`
("merged in group g3 at abc1234"), `failure` (the reason). And ONE comment when it is taken out of the line by a failed check or a conflict (not for a closed, draft or moved PR, which the author did
themselves): the reason, the entry and the run link. Both are best effort: a write that fails is journaled (`status_failed`, `comment_failed`) and counted, and the queue goes on.

**Pause.** `mq pause [--reason TEXT]` stops the start of entries and every push to `main`; entries in flight finish testing and wait in `merging`. `mq resume` clears it and starts the driver.
The driver pauses the queue itself only when the merge push keeps failing.

## The call budget of an entry

Every call to GitHub goes through one place (`lib/mq/mq_gh.py`) and is counted, in the entry's record (`gh_calls`, `salamander_calls`) and as one
line each in `events.log`. Git over the remote (clone, fetch, ls-remote, push) is not a REST call and is counted apart (`git_remote`). The tests
assert these numbers from the fakes' logs and from the record:

| one PR, passing | GitHub calls | poller reads |
|---|---|---|
| the poller's file shows the run going twice, then finished | 3 (2 GraphQL, 1 check-runs) | 3 |
| no poller file; the run is pending twice | 5 (2 GraphQL, 2 check-runs, 1 of them answered 304) | 3 |
| a failing GitHub | 1 GraphQL per attempt; an attempt that fails is counted | |

An entry costs two GraphQL reads: one to build it, one before its verdict counts (the merge step in mode on, the recheck in shadow). The base branch is fetched once more
for the recheck, which is git, not an API call. Waiting costs nothing while the poller's file shows the run going; without the file, at most
one conditional read per poll (`MQ_POLL_SECS`, default 60). In mode on an entry adds two status writes for its PR (pending, then its end) and a comment on a failure.

## Files, locks, the driver

State of a repo: `$XDG_STATE_HOME/mergequeue/<owner>__<repo>/` (`~/.local/state/…` when unset):

| file | what |
|---|---|
| `queue.json` | the line: entries in order (`pr`, `state`, `flags`, `group`, `reason`, `added`, `ended`, `rebuilds`), `next_seq`, `blocked`, `paused` |
| `groups/g<seq>.json` | one entry's record: base, `stack_on` / `stack_base` / `ahead`, the member with its pinned head, branch, `phase`, `state`, `head`, `verdict`, `outcome`, `merged_sha`, `gh_calls`, `salamander_calls`, `git_remote`, `config` as read (a record an older version wrote may also carry `parent` / `children` / `siblings`) |
| `events.log` | JSON lines: the journal and the audit trail (phases, ejections, every GitHub call, the verdict, driver start and exit, `code_changed`) |
| `work/`, `worktrees/g<seq>` | the clone and the entry worktrees |
| `queue.lock`, `driver.lock`, `driver.json` | the locks, and the live driver's pid for people to read |

Every JSON file is written whole: a temp file in the same folder, `fsync`, rename, `fsync` of the folder.

A PR's state in the line is `waiting`, `grouped` (it has an entry), or ended: `tested` (shadow), `merged`, `failed`, `ejected`, `dropped`. A stale entry's PR goes from `grouped` back to `waiting`
(`rebuilds` counts it). Ended entries are kept a day so `mq wait` and `mq status` can still say what happened.

Locks (`flock` on an open descriptor, so a dead process frees it):

- `queue.lock` for a read-modify-write of `queue.json`: held for milliseconds and never across a git or gh call. It is the innermost lock.
- `driver.lock`, held by the one driver per repo for its life. Liveness is the lock, not a pid. A second driver finds it held and leaves
  (`driver_busy` in the journal).
- the repo's deploy lock (host `deploy_lock`), taken for the merge push only, never waited on: busy means try again next tick. Order: driver, then deploy lock; `queue.lock` only innermost.

The driver is `mq drive`, a transient user unit `mq-<owner>__<repo>` (with a replay file `mq-<owner>__<repo>-<run>-<case>`, one function names it for every start, check and message) started by `mq add`, `mq wait` or `mq resume` with `systemd-run --user`, with no resident
service. It exits when the line is empty and nothing is in flight (it gives up the lock, looks once more, and takes it back if work arrived in
between). **Crash safety:** all progress is in the files, each phase is written to the entry's record before the step it names is left and is re-entered
after a crash: `building`, `built`, `pushed`, `testing`, `verdict`, `cleaning`, `done`. Any CLI call that finds work and no live driver starts
one, so no timer is needed. Two calls in the same second both try to start the unit, and the second `systemd-run` fails because the unit exists:
when it fails, the caller looks at the driver lock (waiting up to 2 s for it when the unit exists or is active, since a unit that is coming up may not hold the
lock yet), and a driver that is alive is answered as "driver running" (`driver_start_raced` in the journal, once per call); only when no driver is alive
after the failure does the message say "driver NOT started" with the `systemd-run` error (`driver_start_failed`). The exit code is the same either way, and `mq wait`
and `mq resume` take the same path. A step that fails (git or GitHub unreachable) is retried with a growing pause; after `MQ_MAX_FAILS` (5) failures in one
phase the entry is given up: its PR is `failed` with the reason and the branch is deleted.

**A release reaches a running driver.** The driver is long-lived, and a release that changes `lib/mq/*.py` does not touch the modules a process already holds in
memory. So at the top of each loop (between passes, after every phase of the last pass is saved to its record, never inside a phase) it compares the
`(name, mtime_ns, size)` of every `*.py` in its own folder with what it started with (a stat per file, no hashing). A change that has stayed the same for
`MQ_CODE_SETTLE_SECS` (2; a checkout replaces files one by one) is journaled as `code_changed` (the files that differ) and the driver re-executes itself,
`os.execv` of the same interpreter with the same arguments (`-I` kept): the PID stays, so the transient unit sees no restart, and the next pass runs the new
code. The in-memory pacing (retry counts, poll times) starts over, as after a crash; the records do not. **The lock is handed over, not released:** an `flock` belongs to the open file
description, which survives an exec once the descriptor is inheritable, so the driver marks `driver.lock`'s descriptor inheritable and names it in `MQ_LOCK_FD`
(`fd:device:inode`); the new image checks it is `driver.lock`, takes it over (and makes it close-on-exec again) and journals `driver_start` with `reexec`. Releasing
and re-taking would leave a gap in which `mq add` could see no driver. If the new code does not import (a release caught half-written), the process dies, the lock
goes with it, the unit ends failed, and the next `mq add`, `wait` or `resume` starts a driver that takes the entry from its record. There is no loop of execs: the
new image fingerprints what it loaded.

`mq drop N` ends the PR's line entry at once. A PR dropped before its entry is built is left out of the build. A PR whose entry is already built stays in that entry's tree until the driver ends the entry at its next step (it is never marked
`tested`, and in mode on it is not merged); the entries behind it are rebuilt without it.

An invalid repo config **blocks** the queue: `queue.json` carries `blocked` with the reason, the PRs stay `waiting`, the driver leaves, and
`mq status`, `mq wait` and `mq doctor` say why. The next driver (any `mq add` or `mq wait`) tries again.

## The commands

| command | |
|---|---|
| `mq add N… [--flag recycle]` | put PRs in the line, in order, and start the driver if none is alive. A PR already in the line is left where it is. Refuses with exit 1 when the mode is `off` (or `on` while `ON_OPEN` is false, which is not the shipped value) |
| `mq pause [--reason TEXT]` / `mq resume` | stop / go on: no entry starts and nothing is pushed to `main` while paused; `resume` starts the driver |
| `mq status [--json]` | the line, the entries in flight, what finished lately; `--json` is the same as one object |
| `mq drop N` | take a PR out of the line (exit 1 when it is not in it) |
| `mq wait N [--timeout S]` | block until the PR is settled, reading the state file (no GitHub call). Prints the PR's state, the reason and its entry (`PR 7 merged: merged in group g3 at abc1234 [g3]`: what a release log can quote). Exit 0 merged, 1 ejected, failed or dropped (reason on stderr), 2 gave up, not in the line, or the queue is blocked, 3 tested in shadow mode (its entry passed and nothing was merged), 4 replay with `ci = "skip"` (the entry was built, nothing was pushed or tested: a distinct code so it is never read as the 3 of a pass; the line says `tested (CI not run)`). A stale PR is waiting again, so `wait` goes on |
| `mq doctor` | host file (and the replay file, one line), tools, state files, the driver and its lock, the repo config as last fetched (a replay's rules come from its file), queue branches **of the rules' own `queue_prefix`** and worktrees no live entry owns: another queue's branches (a replay's `queue/practice/…`) are not this queue's to warn about. Exit 0 all ok, 1 a problem |
| `mq drive --repo R` | internal: the driver |

All take `--repo owner/name`, by default the GitHub origin of the current folder. The exit code 3 of `wait` is the one place shadow differs from the
design's three codes: a caller must never read "tested in shadow" as "merged".

## Configuration

**Host file** `$XDG_CONFIG_HOME/mergequeue/<owner>__<repo>.toml`, this machine's settings:

| key | meaning |
|---|---|
| `mode` | `off` (default; also when there is no file), `shadow`, `on` (the driver merges; open since `ON_OPEN` became `True`) |
| `remote` | where the clone fetches from and pushes to (default `git@github.com:<owner>/<repo>.git`; the push needs a key that may create `queue/**` branches) |
| `clone` | the work clone (default `<state>/work`) |
| `git_name`, `git_email` | the identity of the merge commits. A key left unset is read from the work clone (`git -C <clone> config --get user.name` / `user.email`: the clone's own config, or an `includeIf` rule that gives it the repo's identity), never from the global git config of the user the queue runs as. The queue **refuses to start** when the name or the email comes out empty, or when a value that came from the clone equals the global one, which is a person's own (*Merge commit identity*). There is no `mergequeue` fallback |
| `deploy_lock` | a lock file the merge push `flock`s (the same file the repo's release script takes for a deploy) |
| `deploy_hook` | read and checked; the release script's step uses it (*later*) |
| `replay` | an absolute path to a replay file (*Replay*): the rules and the PR facts come from it; shadow only |

**Repo file** `.github/mergequeue.toml`, read from `origin/main`'s tip at the start of each entry (a PR cannot change its own rules; no file is the
defaults):

| key | default | meaning |
|---|---|---|
| `base` | `main` | the branch PRs target and entries are built on |
| `required` | `["suites"]` | check names that must complete with `success` on the entry's head |
| `pr_required` | `"all"` | the checks of a PR's own head that must not have failed for it to join or stay in the line: `"all"` (every check reported on the head) or a list of names (*Which PRs join and stay*) |
| `queue_prefix` | `queue/main/` | the branch prefix; must start with `queue/` (the workflow triggers on `queue/**`) and end with `/` |
| `queue_mode` | `chain` | the only mode: one entry per PR, stacked on the entry ahead, tested side by side, merged in order (*The chain*). Naming it is allowed and changes nothing; the key can be left out |
| `inflight_max` | 6 | entries in flight, stacked on each other (1 to 16) |
| `suites` | `all` | what a queue run tests; the repository chooses with `suites = "all"` or `"select"`: `all` runs every suite, `select` runs what a PR runs (mq only passes the value on to the workflow) |
| `on_conflict` | none | the command for a snapshot-only conflict |
| `conflict_paths` | `["tests/tool_text.snapshot.json"]` | the files that command may resolve |
| `flaky`, `fast_allow` | | read and checked, used by later steps |

An unknown key is a warning (journaled, shown by `mq doctor`), a bad value is an error and blocks. (In a replay file's `rules` an unknown key is an error too.)

**Retired keys.** Group mode is gone, and a file that still carries its keys is handled so that an old rules file never stops the queue by surprise and never hides that it is out of date:

| in the repo file | what happens |
|---|---|
| `queue_mode = "chain"` | accepted, no warning (stackshot's file names it) |
| `group_max`, `bisect` (any value) | read and ignored; a warning per key, journaled as `repo_config_warning` and shown by `mq doctor` (exit 1): `retired key 'group_max' (ignored): group mode was removed and the queue is a chain, one PR per entry; delete the line`. The queue keeps working |
| `queue_mode = "group"` | an **error that blocks the queue** (`mq status`, `mq wait` and `mq doctor` say why): `queue_mode = "group" is not supported: group mode was removed and the queue is a chain, one PR per entry; delete the line or set queue_mode = "chain"`. A PR cannot change the file, so the fix reaches `main` by the repo's other path (*Using the queue for another repo*, 6) |

The default of `inflight_max` was 2 when no `queue_mode` was named (group mode) and was already 6 in a chain: a file that named neither now gets 6. In a replay file's `rules` the two retired keys are accepted without an error, so replay files written
before the removal still run.

**Merge commit identity.** The queue's merge commits carry the host file's `git_name` and `git_email`. A key left unset is read from the work clone with `git -C <clone> config --get user.name` (or `user.email`), so a clone that has its own identity (a local config, or an `includeIf` rule of the user's global file that matches the clone's folder) commits as that identity. The queue never reads the identity from the folder it runs in and never falls back to a made-up one: a push to a public repo carries the commit's name and email for good, and the global git config of the user the queue runs as is a person's own. The queue therefore **refuses to start** when

- the name or the email comes out empty (the host file leaves the key unset and the work clone has none of its own), or
- a value that came from the work clone equals the global `user.name` / `user.email` (`git config --global`): either one matching a non-empty global value is enough. A value set in the host file is never compared, because writing it there is a choice.

Public or private is not asked: telling them apart takes a network call of its own, so the refusal applies to every remote. The refusal blocks the queue, as an invalid repo file does: the driver ends, `mq status` and `mq wait` show it, `mq doctor` prints it as a `FAIL` line, and nothing is built or committed. Its text is

```
refusing to make merge commits: <why>. Set git_name and git_email in the host file ($XDG_CONFIG_HOME/mergequeue/<owner>__<repo>.toml) to an identity made for the queue (docs/mq.md, Configuration)
```

where `<why>` is `user.name is not set (the host file's git_name is unset and the work clone has none of its own)`, the same for `user.email` and `git_email`, or `the work clone's user.name is the global git user.name of the user the queue runs as, not one made for the queue` (and the same for `user.email`). The fix is the two host keys; the next `mq add` or `mq resume` looks again. Commands that write no commit (fetch, push, ls-remote, show, `mq doctor`'s reads) need no identity.

## Replay

stackshot replays a set of past PRs through the queue (`mq replay`), on a practice branch of the same repo, to see whether the queue gives the verdict the old path gave. Three things
make that impossible without a change: the rules are read from `origin/main`, the PR facts from GitHub (a merged PR is `MERGED`, so the queue ejects it), and a replay's driver would share
the live driver's unit name. One host key fixes all three, and nothing it does can write to GitHub.

Each case runs as its own queue instance (its own `XDG_STATE_HOME` and `XDG_CONFIG_HOME`, so its own `queue.json`, locks and clone) with a host file like

```toml
mode = "shadow"                        # may be left out (shadow is the default with replay); "on" is an error
replay = "/abs/path/replay.json"       # an absolute path
```

**The replay file**, JSON, `version` 1; `run` and `case` are `[A-Za-z0-9._-]+`, `ci` is `"real"` or `"skip"`. Every key below is checked; an unknown key or a bad value in the file, in `rules` or in a PR is refused with the message (`mq add` exits 1, `mq status`
shows it under `host config:`, a running driver does nothing until it is fixed), as for a bad host file:

```json
{
  "version": 1,
  "run": "r1",
  "case": "c01",
  "ci": "real",
  "rules": { "base": "practice/r1/c01", "queue_prefix": "queue/practice/r1/c01/", "required": ["suites"], "inflight_max": 4 },
  "prs": { "544": { "state": "OPEN", "draft": false, "head": "<40 hex>", "branch": "pr-544", "owner": "howardpark-ai", "checks": { "suites": "pass" } } }
}
```

- `rules` holds the keys of `.github/mergequeue.toml` (`base`, `queue_prefix`, `required`, `pr_required`, `queue_mode`, `inflight_max`, `suites`, `on_conflict`, `conflict_paths`, `flaky`,
  `fast_allow`; the retired `group_max` and `bisect` are accepted and ignored) and is checked by **the same code** as that file (`mq_config.check_repo_config`); a key left out is the default; an unknown key is an error here, not a warning. The rules come
  from the file and `origin/main`'s `.github/mergequeue.toml` is not read at all. **The guard:** `base` must start with `practice/` and `queue_prefix` with `queue/practice/`, else the queue is
  blocked (`mq status`, `mq wait`, `mq doctor` say why) before anything is fetched.
- `prs` gives, per PR number, what GraphQL would: `state` (`OPEN`, `MERGED`, `CLOSED`; default `OPEN`), `draft` (default `false`), the full `head` sha, `branch`, `owner`, and `checks` (name to
  `pass` | `fail` | `pending` | `cancel`, default none). The `base` of every PR is `rules.base`. The one function `mq_replay.pr_facts` serves the build and the recheck before the verdict, so they agree; there is
  no GraphQL call (`gh_calls` has none, the journal has `replay_facts`). A PR number the file lacks is "pull request not found", as for a missing PR; a recorded `MERGED`, a draft or a failed
  check eject as they would on GitHub.
- **Content by sha.** A PR's head is fetched with `git fetch origin <sha>` into `refs/mq/pull/N`, not from `refs/pull/N/head`, so a commit no branch holds is enough (GitHub serves any commit it still has). A
  sha origin cannot give ejects that PR: `head <sha7> cannot be fetched from origin`.
- **Shadow only.** `mode = "on"` with `replay` is an error; with no `mode` key the mode is `shadow`. The driver never merges, sets no status and posts no comment (`merging()` is false), and `mq_git` refuses any
  push or delete of a branch outside `queue/practice/`, so `main`, PR branches and the practice base cannot be written. The entry branches `queue/practice/…/g<seq>` are pushed and deleted as usual (for `ci = "real"`).
- **`ci`.** `real` is today's behavior: the entry is pushed and the repository's workflow tests it (the workflow triggers on `queue/**`, which covers `queue/practice/**`). `skip` ends an entry after phase
  `built`: no push, no CI call of any kind; the verdict is `skipped`, the PR is `tested` with the reason `tested (CI not run): …` and the marker `ci: "skipped"` in `queue.json`, and `mq wait N` prints
  `PR N tested (CI not run) (replay ci = skip: …; this is not a pass)` and **exits 4**. Exit 3 ("its entry passed") is never returned for a skipped entry. A caller can still read the built tree
  from the entry record's `head` in the case's clone.
- **The unit.** `mq-<owner>__<repo>-<run>-<case>`, so a replay's driver never collides with the live driver of the repo; `mq add`, `mq wait`, `mq resume` and the race check all use that one name.
- **`mq doctor` and `mq status`** each say in one line that a replay file is in use (`REPLAY:` in `status`, `replay file …` in `doctor`, which also reads the rules from it), and `doctor` lists only
  the remote branches of the rules' own `queue_prefix`, so a replay's `queue/practice/…` branches no longer make the real queue's doctor warn and exit 1.

Who uses it: stackshot's `mq replay` (a replay driver that writes the file and a practice branch per case, runs the case as a queue instance, compares the verdict with the old path and cleans up with
`git push origin --delete`); nobody else should set the key.

## How CI sees an entry

The repository's workflow runs on `push` to `queue/**` and reports the same job name as on a PR, `suites`, so what mq reads is the check the repository
already requires. The repository chooses what a queue run tests with `suites = "all"` or `"select"`. `select` runs what a PR runs; the risk is a selection that misses a
suite, which a full run on `main` after the merge catches. `all` runs every suite (the shards run in parallel anyway). mq only passes the value on to the
workflow. A queue run keeps the main-only steps for `main`, and uses the entry's ref as its concurrency group without cancelling. Those workflow edits belong to the repository that
adopts mq, not to this command. The design assumes three things to prove on a scratch repository before the merge step relies on them: a push to
`main` at a commit that contains a PR's head marks that PR merged with no API call; a push by the owner's SSH key to a `queue/**` branch starts the
push-triggered workflow (a push with the Actions token would not); a commit status on a PR head appears in the PR's checks list.

All three were seen on a scratch repository, with this version in mode `on` against `gh` and git: three PRs, one of them failing the
check; the failing PR was named, the other two were pushed to `main` as a fast-forward and GitHub showed both PRs merged with no API call from
mq, the failing PR got a failure status and one comment, and every `queue/main/g<n>` branch was deleted afterwards.

## Using the queue for another repo

(A repository can also carry both queues at once, GitHub's and this one, and switch between them with the host file and one ruleset: `docs/merge-queues.md`.)

A repository goes on `mq` with two small files, a few lines in its workflow and a hand-over in its release script; nothing in `lib/mq/` changes (Migration, 7). The worked example is stackshot, which runs with mode `on`.

**1. The host file**, on the machine that runs the queue: `$XDG_CONFIG_HOME/mergequeue/<owner>__<repo>.toml` (`~/.config/mergequeue/…` when unset), one per repository, never in the repo. No file is mode `off`. A key that is not in the table of *Configuration* (host file), or a `mode` that is not `off`, `shadow` or `on`, is an error and the queue does nothing until it is fixed. stackshot's, `howardpark-ai__stackshot.toml`:

```toml
mode = "on"                                   # off | shadow | on
deploy_lock = "/path/to/state/releases/deploy.lock"   # the file the repo's release script takes for a deploy
# remote = "git@github.com:howardpark-ai/stackshot.git"    # the default, built from the repo name; left out here
```

- `remote` is where the queue's own clone (under the state folder, never a production checkout) fetches from and pushes to. The default is the SSH url of `<owner>/<repo>`, and its key must be allowed to create `queue/**` branches and to push `main`. `clone`, `git_name` and `git_email` have defaults and a new repo needs none of them.
- `deploy_lock` is the lock file the merge push `flock`s, without waiting (busy means try again next tick). It must be **the same file the repo's release script locks around its own merge and deploy**, so a push and a deploy never overlap. Give it as an absolute path: the string is opened as written (no `~` expansion). A repo with no deploy to exclude leaves it out. stackshot's `release.sh` goes further: in mode `on` it refuses to run (`FAILED at mq mode`) unless the host file's `deploy_lock` is the lock it takes itself.

**2. The repo rules file**, `.github/mergequeue.toml`, on `main`. It is read from `origin/main`'s tip at the start of each entry, never from a PR, so **a PR cannot change its own rules**: a change to the file takes effect only once it is merged. No file means the defaults of *Configuration* (repo file), which are enough for a repo whose job is called `suites` and whose branch is `main`. The keys a new repo decides, with stackshot's values:

```toml
base = "main"                  # the branch PRs target and entries are built on
queue_mode = "chain"           # the only mode; may be left out
required = ["suites"]          # the check names that must complete with success on an entry's head
queue_prefix = "queue/main/"   # starts with queue/ (the workflow triggers on queue/**) and ends with /
suites = "select"              # only passed on to the workflow: "all" | "select"
# inflight_max = 6             # the default (1 to 16), left out
on_conflict = "sh -c 'git checkout HEAD -- tests/tool_text.snapshot.json && python3 tools/tool_text.py update && python3 tools/tool_text.py check'"
conflict_paths = ["tests/tool_text.snapshot.json"]
```

- `required` is the contract with the workflow: the name must be a job that runs on a `queue/**` push (3). `suites` is not interpreted by mq; the workflow decides what `all` or `select` runs.
- `on_conflict` and `conflict_paths` are for a **generated file** that two PRs both change (stackshot's tool-text snapshot): when every conflicted path is in `conflict_paths`, mq runs the command in the worktree and, on exit 0, commits what it wrote; any other conflict ejects the PR. A repo with no such file leaves both out. The command is split with `shlex` and run with no shell (so a pipeline or `&&` needs a wrapper, as stackshot's `sh -c '…'`), in the worktree, with `MQ_PR`, `MQ_CONFLICT_FILES` and `MQ_WORKTREE` in its environment and a 300 second timeout; mq `git add`s only the conflicted files. `conflict_paths` defaults to stackshot's `tests/tool_text.snapshot.json`, so **set it whenever `on_conflict` is set**. The command is read from `main`, so it is as trusted as the repo's own scripts.
- `pr_required` defaults to `"all"`, the checks reported on the PR's own head, which is what a release script reading `gh pr checks` already holds a PR to. A bad value blocks the queue; an unknown key is a warning. `mq doctor` shows both. A file written for the removed group mode is told apart in *Configuration* (*Retired keys*): `group_max` and `bisect` are warned about and ignored, `queue_mode = "group"` blocks until the line is deleted.

**3. What the workflow must provide.** The queue pushes each entry as a branch under `queue_prefix` and reads the result from the check runs of that branch's head, so the repo's workflow must:

- trigger on `push` to `queue/**` (stackshot: `branches: [main, 'queue/**']` in `tests.yml`), so a push to `queue/main/g<n>` runs it. The push must come from the host's SSH key: a push with the Actions token does not start workflows (see *How CI sees an entry* for what was checked on a scratch repository);
- report the job named in `required` on that run, (mq only needs the check name to equal an entry of `required`; the same name as on a PR is a convention, so that the check mq reads is the one the repo already requires, as stackshot's `suites` is);
- keep main-only steps (publishing, a measured full run, anything that writes `main`'s state) off a queue branch, with a condition such as `github.ref == 'refs/heads/main'`;
- not cancel a queue run: use a `concurrency` group on the ref and `cancel-in-progress` only for `pull_request` events (stackshot's `cancel-in-progress: ${{ github.event_name == 'pull_request' }}`). Every entry has its own ref, so entries never cancel one another.

The workflow change merges before the queue is switched on (Migration, 1). A repo with the CI-run poller (`docs/ci-runs.md`) adds its `owner/name` to `~/.config/salamander/ci-repos`, so a waiting queue asks GitHub nothing while a run is going; without it mq falls back to one conditional check-runs read per poll.

**4. How the repo's release script hands PRs over.** mq merges and tests; it does not deploy. The repo's own release script keeps the deploy and calls `salamander mq` for the merge. stackshot's `release.sh` (the block *THE MERGE QUEUE, ON*, `run_group`) is the example:

- **The count rule stays the script's.** One PR waiting is released alone by the old path, with no `salamander mq` call at all (and its own shortcuts); two or more go to the queue together. A lone PR that nothing could make differ from `main` merges without a run: that shortcut is the script's, and it is kept on purpose. The size of a hand-over is the script's too (stackshot's hands over at most 4 PRs at a time); the rest stay in the script's own queue for the next hand-off.
- **One `mq add`, then one `mq wait` per PR.** `salamander mq add N1 N2 … --repo owner/name` once for all of them (stackshot gives it 60 seconds), then `salamander mq wait N --repo owner/name --timeout S` for each PR in order, in slices of 5 minutes (`RELEASE_MQ_SLICE`) up to 5 hours in all (`RELEASE_MQ_WAIT_CAP`). Between slices the script looks at `mq status --json` for a paused or blocked queue. Exit codes of `wait` are in *The commands*: 0 merged, 1 ejected, failed or dropped (the reason is on stderr), 2 gave up or the queue is blocked, 3 tested in shadow, 4 replay with `ci = skip`. The merged line (`PR 42 merged: merged in group g2 at abc1234 [g2]`) names the commit; when it does not, the script asks GitHub for the PR's merge commit.
- **One deploy after the last PR settles.** The queue merges one PR a push, in line order, and a push contains the ones before it, so the script waits for every PR to settle and deploys once, from the last merge, under its deploy lock. A PR the queue ejected or failed is reported as a failed release of that PR with the queue's reason; the others still go out.
- **A PR is never in both paths.** The script writes a marker per PR (`<state>/releases/mq-on/pr-N`) before `mq add` and removes it once the queue no longer holds the PR; its lone path refuses a PR with a marker, at its start and again under the deploy lock just before its merge. A failure of the queue itself (an `mq` error, a wait past the cap, a paused or blocked queue) drops the PRs still open from the queue (`mq drop`) and pauses the script's own queue; a PR whose GitHub state cannot be read is not dropped and keeps its marker (it may be merged), to be checked by hand; the script never falls back to merging a PR the queue may hold.
- **The deploy lock** is the file of the host key `deploy_lock`: the queue's merge push takes it without waiting, and the script holds it from its own merge to the end of its deploy, so the queue never merges while a lone release is mid-merge or deploying.

**5. The staged rollout**, each step reversible and decided in the host file alone:

1. **Prepare.** Merge the workflow change (3) and `.github/mergequeue.toml` (2) to `main`. With no host file the mode is `off` and nothing runs.
2. **`mode = "shadow"`.** Run `salamander mq doctor --repo owner/name`: it checks the host file, `git`, `gh` and `systemd-run`, the driver, the state files, the rules at `origin/main` (valid, or "defaults, no .github/mergequeue.toml"; the rules are only read once the first entry has made the clone) and queue branches that no live entry owns. Exit 0 is all ok. The queue then tests what `mq add` gives it and journals what it would merge; it merges nothing, posts no status and no comment. stackshot's `release.sh` adds each PR in shadow (a 20 second timeout) and logs one `agree`, `DISAGREE` or `no comparison` line per release against what its old path did.
3. **The replay**, before or beside shadow: past PRs whose outcome the old path decided are run through the real queue on practice branches (*Replay*). A repo needs a driver that writes the replay file and the practice branches; stackshot's is `tools/mq_replay.py` (`build-cases`, `run`, `report`, `clean`), built from its own release logs, so its cases are stackshot's and a new repo writes its own. `mq doctor` says in one line that a replay file is in use.
4. **`mode = "on"`**, once shadow agrees and the replay matches. The release script's own checks apply (stackshot: the `deploy_lock` line above). Run `mq doctor` again; the first real hand-over is two or more PRs.
5. **The instant fallback is `mode = "off"`** for new work: `mq add` refuses new PRs at once and no new entry starts. It does not stop a merge already under way: mode `on` is checked only when a passed entry enters `merging`, and an entry already in `merging` still completes its push to `main` (it waits only for `paused`, a busy deploy lock, or the entry ahead). **To hold such an entry, run `salamander mq pause` first**, then set `off`. An entry still testing when the mode goes to `off` ends as `tested` (the shadow outcome) and `mq wait` returns 3. stackshot's `release.sh` treats 3 as not usable: a release already in flight aborts, drops its PRs and pauses its own queue, so it does not go back to the old path; the next release does, because the script reads the host file each time. The old path stays in the script for as long as the fallback is wanted (Migration, 5).

**6. The limits that bite.**

- **A PR cannot change its own rules.** `.github/mergequeue.toml` (and the `on_conflict` command in it) is read from `origin/main`, so the PR that adds or edits the file is queued under the rules `main` had before it. A repo's first rules file (needed only when it differs from the defaults), or a fix to a broken one (a file that still says `queue_mode = "group"` is one), therefore reaches `main` by the repo's old path (or with the host mode `off`). An invalid file blocks the queue (`mq status`, `mq wait`, `mq doctor` say why) until `main` has a valid one.
- **The practice guard.** A replay's rules must put `base` under `practice/` and `queue_prefix` under `queue/practice/`, else the queue is blocked before anything is fetched; the replay is shadow only (`mode = "on"` with `replay` is an error), and `mq_git` refuses a push or delete of any branch outside `queue/practice/`, so `main` and PR branches cannot be written by a replay.
- **GitHub's API budget is shared** by every tool on the machine (5,000 calls an hour). An entry costs two GraphQL reads (its build, and the read before its merge) and one check-runs read per poll while it is in flight (`MQ_POLL_SECS`, 60 by default; a 304 answer is free, and nothing is asked while the poller's file shows the run going). Statuses and comments add two status writes and at most one comment per PR in mode `on`. See *The call budget of an entry*. The chain trades more CI runs (one per PR, a rerun for each PR behind a failure) for a failure that names its PR with no split.
- **Runner time, not API calls, is the larger cost**: the queue starts up to `inflight_max` runs at once, and the workflow's runners must take them. A run that never reports its `required` job ends as a `timeout` after 100 minutes (`MQ_WAIT_CAP_SECS`) and fails the PR.

## Tests

`tests/mq.sh` runs `tests/mq_scenario.py`: a temp folder locked with `flock` and removed in a `finally`, real git against a local bare repository as
origin, a fake `gh`, a fake `salamander` and a fake `systemd-run` on a fake PATH that answer from files and log every call. The fake CI is a function of
the pushed tree (`BAD_*` fails an entry, `RERUN` reports an older failed run beside a newer pass). Crash injection is an
environment variable, never a kill: `MQ_CRASH_AT=<phase>` makes the driver exit with 75 right after it writes that phase. The timings are environment
variables too (`MQ_TICK_SECS`, `MQ_POLL_SECS`, `MQ_WAIT_CAP_SECS`, `MQ_MAX_FAILS`, `MQ_BACKOFF_SECS`, `MQ_KEEP_SECS`, `MQ_MAX_REBUILDS`, `MQ_CODE_SETTLE_SECS`, `MQ_WAIT_SLEEP`). A file `ci.never` in the fake `gh`'s folder
keeps every entry's check running until it is removed: how the chain scenarios (`sc_chain_*`) get "all entries testing at once" as a state to wait for. The replay scenarios (`sc_replay_*`) add a practice branch on the bare origin, heads that no branch holds, and a `pre-receive` hook
on the origin that logs every ref a push touches: they assert that nothing but `queue/practice/` entry branches is ever pushed or deleted, and that no status, comment or GraphQL call is made. The removal of group mode is covered by
`sc_chain_config` and `sc_retired_keys` (the retired keys, `queue_mode = "group"`) and `sc_legacy_group_state` (records an older version left on disk: a two-PR group in testing, a bisect with its halves, a merge whose push had happened, a finished group).

`sc_identity` covers the merge commit identity (*Configuration*): in a throwaway `HOME` whose global git config holds a fake person, the commits of an entry carry the work clone's own identity (given by an `includeIf` rule) or the host file's, never the global one, and a queue with only the global identity, or none, to use is blocked with the refusal, in the journal, in `mq wait` and as a `FAIL` line of `mq doctor`. The other scenarios give the work clone an identity through `GIT_CONFIG_COUNT` in the environment.

## Migration, in small steps, each reversible

1. The repository's workflow: a `queue/**` push trigger, the main-only gates, the shard matrix for a queue run, a small result artifact.
2. `salamander mq` core in shadow mode.
3. **Statuses, the merge push, pause and resume, absorbing a moved `main` by rebuilding, and speculative entries (an entry stacked on the head of the entry ahead, so more than one is in flight in mode on): this page.** Group mode (PRs tested together, a failed group bisected) was
   part of this step and was removed; the chain is the only mode. Left for a later step: the rerun of a flaky check, cheaper absorb rules, the poller file for push runs, the sweep of stale queue branches.
4. A repository's `.github/mergequeue.toml` and its release script behind the host `mode = off | shadow | on`; shadow runs the queue next to the old
   path and logs where they disagree.
5. **Flipped: `on` is open (`ON_OPEN` is `True`).** The old path is kept for a while behind `mode = off` as the instant fallback.
6. Delete the old catch-up code and keep one path.
7. Other repositories adopt mq: their `required` list and workflow edits are the only new things.
8. Where a repository gets GitHub's queue: add the `merge_group` trigger (keep the `queue/**` push trigger, so either queue works), set `mode = off` while GitHub's queue is the one in use, keep mq for repositories that cannot have it.
   salamander does this: `docs/merge-queues.md` has the switch, the switch back and the proofs.
