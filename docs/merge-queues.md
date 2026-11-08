# Merge queues: GitHub's and `sala mq`

A PR reaches `main` one of three ways. The repository carries what all three need, so switching between them is a change of
GitHub settings and a host file, not a change of code.

| way | who tests the merge | who merges | on when |
|---|---|---|---|
| direct | nobody: the PR's own checks only | `release.sh` (`gh pr merge --merge --admin`) | `main` has no merge queue and the host file is `off` (today's default) |
| GitHub's merge queue | GitHub, on `gh-readonly-queue/main/pr-N-<sha>`, a `merge_group` run | GitHub | the ruleset *main merge queue* is `active` |
| `sala mq` | the driver, on `queue/main/g<seq>`, a push run (`docs/mq.md`) | the driver (`mode = "on"`) | the host file says `mode = "on"` (or `"shadow"`: tests, never merges) |

Use one queue at a time. With GitHub's queue active, keep the host file at `off`: both would build and merge the same PRs.

## What the repository carries

- **`.github/workflows/tests.yml`** runs for an entry of either queue: `on: merge_group` (types `checks_requested`) and `on: push` to `main` and `queue/**`.
  The `changes` job picks the same suites as for a PR; the base it compares against is `merge_group.base_sha` for GitHub's entry and the merge base with `main` for a `queue/**` push.
  `tested.sh` (the "this tree already passed on `main`" shortcut) reads and writes only on `main`, so a queue run always runs what its change needs.
- **`gate`**, a job at the end of `tests.yml` (needs `changes`, `suites`, `web`; `if: always()`): it fails unless each of them is `success` or `skipped`.
  `sala mq` reads a check that completed without `success` as failed, and `suites` and `web` are skipped on some changes, so it cannot require them; it requires `gate`.
- **`.github/mergequeue.toml`**, the sala queue's rules, read from `origin/main`: `base = "main"`, `queue_mode = "chain"`, `queue_prefix = "queue/main/"`, `required = ["gate"]`, `suites = "select"`.
  It takes effect once it is on `main`.
- **`release.sh`** asks GitHub whether `main` has a merge queue (`repository.mergeQueue(branch: "main")`). With one it enqueues the PR pinned to the head commit
  (the GraphQL mutation `enqueuePullRequest`; `gh pr merge` cannot be used, it asks for auto-merge, which is off here), waits until the PR reads MERGED (a removal is read from the PR's timeline and fails the release with GitHub's reason),
  then deploys from the merge commit as for a direct merge. Without one it merges directly, as before. `SALA_RELEASE_MERGE=auto|direct|queue` (default `auto`) overrides the question:
  `direct` never asks and merges at once (the way back that needs no API call), `queue` fails when `main` has no queue. `SALA_RELEASE_QUEUE_WAIT` (default 7200 s) is how long it waits for the merge.
  After a `sala mq` merge, `release.sh --merged <pr>` deploys.

## What stays outside the repository

Two rulesets and a host file. Ruleset ids are those of `howardpark-ai/salamander`.

**The queue ruleset** (created `disabled`; `bypass_actors` is empty on purpose: nobody, administrators included, merges around the queue). Required checks are the three that branch protection requires:

```
gh api repos/howardpark-ai/salamander/rulesets -X POST --input - <<'JSON'
{
  "name": "main merge queue",
  "target": "branch",
  "enforcement": "disabled",
  "bypass_actors": [],
  "conditions": {"ref_name": {"include": ["refs/heads/main"], "exclude": []}},
  "rules": [
    {"type": "merge_queue", "parameters": {
      "merge_method": "MERGE",
      "grouping_strategy": "ALLGREEN",
      "max_entries_to_build": 6,
      "min_entries_to_merge": 1,
      "max_entries_to_merge": 4,
      "min_entries_to_merge_wait_minutes": 0,
      "check_response_timeout_minutes": 60}},
    {"type": "required_status_checks", "parameters": {
      "strict_required_status_checks_policy": false,
      "do_not_enforce_on_create": false,
      "required_status_checks": [
        {"context": "changes", "integration_id": 15368},
        {"context": "suites", "integration_id": 15368},
        {"context": "web", "integration_id": 15368}]}}
  ]
}
JSON
```

**`bot-only-pushes`** (id 26763160, branches, active; creation, update and deletion limited to three integrations) must let the queue's own writes through. GitHub's queue creates its
`gh-readonly-queue/…` branches and fast-forwards `main` as itself, which no bypass list names, so those two refs are excluded (the pattern has two stars because the branch name has two slashes after the prefix):

```
gh api repos/howardpark-ai/salamander/rulesets/26763160 -X PUT --input - <<'JSON'
{
  "name": "bot-only-pushes",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [
    {"actor_id": 1236702, "actor_type": "Integration", "bypass_mode": "always"},
    {"actor_id": 2853652, "actor_type": "Integration", "bypass_mode": "always"},
    {"actor_id": 5598690, "actor_type": "Integration", "bypass_mode": "always"}],
  "conditions": {"ref_name": {
    "include": ["~ALL"],
    "exclude": ["refs/heads/main", "refs/heads/gh-readonly-queue/**/*"]}},
  "rules": [{"type": "creation"}, {"type": "update"}, {"type": "deletion"}]
}
JSON
```

While the queue ruleset is active, its `merge_queue` rule is what keeps everyone from pushing to `main`, so excluding `main` here opens nothing. If the queue ruleset is ever disabled, put `refs/heads/main` back out of `exclude` first.

**The sala queue's host file**, `~/.config/mergequeue/howardpark-ai__salamander.toml` on the machine that runs it. No file means `off`. To run a shadow pass:

```
mode = "shadow"
remote = "https://github.com/howardpark-ai/salamander.git"
git_name = "salamander contributors"
git_email = "noreply@example.invalid"
```

`remote` is an https URL because the queue branches are pushed with the machine's GitHub App credential, which bypasses `bot-only-pushes`; an SSH remote would push as a person and be refused.

## Switching to GitHub's queue

Order matters: a required check that never reports stalls the queue.

1. The PR that adds the workflow trigger, `gate`, the rules file and `release.sh` support merges first, the direct way (`release.sh <pr>`).
2. Create the queue ruleset `disabled` (above). Read it back: `gh api repos/howardpark-ai/salamander/rulesets`.
3. Edit `bot-only-pushes` (above). Read it back.
4. Enable: `gh api repos/howardpark-ai/salamander/rulesets/<queue ruleset id> -X PUT -F enforcement=active`.
5. Prove it (below). From then on `release.sh <pr>` enqueues by itself.

Administration permission on the repository is needed for steps 2 to 4. `gh pr merge --admin` cannot merge while the queue ruleset is active (there is no bypass), which is why `release.sh` has the queue path.

## Switching back

Either of these is enough, the first is instant and local:

- `SALA_RELEASE_MERGE=direct release.sh <pr>`: merges directly. It works only while the queue ruleset is `disabled`; with it active GitHub refuses a direct merge.
- Disable the queue ruleset (`-X PUT -F enforcement=disabled`), take `refs/heads/main` out of `bot-only-pushes`'s `exclude` again, then `release.sh <pr>` finds no queue and merges directly.

For `sala mq`: set `mode = "on"` in the host file with GitHub's queue disabled (and `shadow` first, below). `mode = "off"` is the instant fallback.

## Proofs

**GitHub's queue.** A throwaway docs-only PR (so `suites` and `web` are skipped and `gate` passes at once): `release.sh <pr>`. Expected: a `merge_group` run on a `gh-readonly-queue/main/pr-<n>-<sha>` branch,
its `changes`, `suites`, `web` and `gate` checks, the PR MERGED, the head branch deleted, `deploy.sh` run, one `[release]` message saying it merged "through GitHub's merge queue".
`gh api repos/howardpark-ai/salamander/rulesets` and `gh run list --event merge_group` show the state.

**`sala mq` in shadow.** With the host file at `mode = "shadow"` and GitHub's queue disabled:

```
salamander mq doctor --repo howardpark-ai/salamander      # exit 0
salamander mq add <pr> --repo howardpark-ai/salamander
salamander mq wait <pr> --timeout 1800 --repo howardpark-ai/salamander   # exit 3: tested in shadow, nothing merged
```

Then set the mode back to `off`. Exit codes of `mq wait`: 0 merged, 1 failed, 2 gave up, 3 tested in shadow, 4 replay skip.

## Things to know

- A lone PR is tested twice: its own run and the queue entry's. A change under `.github/` runs every suite both times (about 16 to 25 minutes each); the queue's response timeout is 60 minutes.
- A PR merged through the queue is a merge commit GitHub made on a tested ref, so `main`'s push run finds no earlier green tree and runs the full set again when `main` moved between; a lone PR on an unchanged `main` still skips.
- Branch protection on `main` stays (`changes`, `suites`, `web`, administrators included), so the required checks apply to the queue's ref and to `main` both.
- `merge_group.base_sha` is `main`'s head for an entry at the front of the queue; for an entry stacked on another it may be the entry ahead. Either only changes which suites are selected, never whether a required check reports.
- Only GitHub's queue and `sala mq` write `gh-readonly-queue/…` and `queue/…` branches; neither is a branch to work on.
- GitHub's merge queue was proven on Sun Nov 8th 2026: a lone PR went through `release.sh` and merged through the queue (board#1057).
- The merge queue proof on Nov 8th 2026 also ran `sala mq` in shadow mode (board#1057).
