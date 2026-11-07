# The CI-run poller and its files

One resident process per machine polls GitHub Actions for the repos builders wait on, and every waiter reads its file instead of
asking GitHub. GitHub's REST budget (5,000 calls an hour) is the account's, shared by every tool and agent on the machine;
a builder or a release waiting on CI used to spend it with a read of its own every minute or less. Now the cost is fixed: one
conditional read a minute per repo in the list (a 304 answer to an
`If-None-Match` is not counted by GitHub).

| piece | where |
|---|---|
| the poller | `salamander ci-poll` (`lib/cipoll.sh`, `lib/cipoll.py`), run by `systemd/sala-cipoll.service` (resident, `Restart=always`, lane `none`) |
| the repo list | `~/.config/salamander/ci-repos` if the machine has one, else the tracked `lib/ci-repos`, which lists no repo, so a fresh install polls nothing and the poller's log says so (override: `SALA_CIPOLL_REPOS`); one `owner/name` a line, `#` comments; read every pass, so a repo added is polled from the next pass with no restart |
| the files | `$XDG_STATE_HOME/salamander/ci-runs/<owner>__<repo>.json` (`~/.local/state/salamander/ci-runs/…` when `XDG_STATE_HOME` is unset; override: `SALA_CIRUNS_DIR`) |
| the reader | `salamander ci-runs <owner/repo> [--sha SHA] [--max-age SECS] [--text]` (`lib/cipoll.py runs`) |

## The file

One JSON object, one line, written atomically (a tmp file in the same folder, `fsync`, `rename`): a reader sees the old file or the new one, never half of one.

```json
{"repo":"owner/name","updated":1790000000,"updated_iso":"2026-01-01T00:00:00Z","runs":[
  {"id":1234567890,"name":"tests","head_sha":"0123456789abcdef0123456789abcdef01234567","head_branch":"main","event":"push",
   "status":"completed","conclusion":"failure","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:07:00Z",
   "html_url":"https://github.com/owner/name/actions/runs/1234567890","run_attempt":1}]}
```

- `repo`: `owner/name`. `updated`: epoch seconds of the last SUCCESSFUL look at GitHub, set on every successful cycle, a `304 Not Modified` included
  (the data is as fresh as that look); `updated_iso`: the same in UTC. **A reader judges freshness by `updated`, never by the file's mtime.**
- `runs`: `GET repos/<repo>/actions/runs?per_page=30` (the 30 newest workflow runs of the repo, newest first, as GitHub orders them), each cut to
  `id, name, head_sha, head_branch, event, status, conclusion, created_at, updated_at, html_url, run_attempt`. `status` is `queued`, `in_progress` or
  `completed`; `conclusion` is `null` until completed, then `success`, `failure`, `cancelled`, `skipped`, `neutral`, `timed_out`, `action_required`…
  A re-run keeps the run's `id` and raises `run_attempt`.
- **It is a window, not a history.** Only the newest 30 runs of the repo are in it. A run of a commit that is NOT in the file may be a run that never
  existed or one that has scrolled out; the file cannot say which. It can say that a run is going, or has finished, when it lists it. Do not read an
  absence as "no workflow ran".
- **It is job-blind.** A workflow run, not its jobs or check runs: a check run of another GitHub App, or a job's own name, is not in it.

## When GitHub does not answer

On any error (a non-200/304 answer, no answer at all, a 200 that is not a run list) the poller **leaves the old file exactly as it was**, so its
`updated` ages and a reader sees it age, logs one line (`cipoll: <repo>: HTTP 500 …; file kept; backing off 0.2s (failure 1)`), and waits twice as long
before that repo's next look, doubling each failure up to `SALA_CIPOLL_BACKOFF_MAX` (600 s). A 403 or 429 that carries `Retry-After`, or `x-ratelimit-remaining: 0`
with an `x-ratelimit-reset`, waits for that (at most an hour) and reads **no repo** meanwhile, the budget being the account's. The first good look after
errors logs `reachable again`. A change in the runs is logged once; a look that found nothing new logs nothing. No token is ever logged (a token-shaped string
in `gh`'s error is replaced). The poller starts by removing a `*.tmp` file a killed one left.

## Reading it

```
salamander ci-runs example-org/demo-web --sha 0123456        # the file's JSON, runs cut to the commits starting with the sha (7+ characters)
salamander ci-runs example-org/demo-docs --text              # a header and one tab-separated line a run: id, status/conclusion, branch, sha, name, url
```

| exit | meaning | stdout |
|---|---|---|
| 0 | the file is fresh (default `--max-age 120` seconds; `0` = no limit). With `--sha` and no run of it: `"runs":[]`, still 0 | the JSON (or the text) |
| 2 | usage, a repo that is not `owner/name`, a `--sha` of under 7 characters | none |
| 3 | no file for that repo: the poller does not poll it (ask for it to be added to the list) or has not run | none |
| 4 | the file is older than `--max-age`: the poller is not keeping it fresh (stopped, or GitHub has been failing) | none |
| 5 | the file is unreadable or has no `updated` | none |

On 3, 4 and 5 stderr says why. **Fall back on those**: read GitHub yourself, as you did before (`gh api` with the url's ETag, at your usual interval). A
caller that cannot tell "the file says nothing" from "GitHub says nothing" must treat both as "ask GitHub".

`release.sh` is the first caller (below). A builder waiting on CI for its own PR reads the file the same way:

```
salamander ci-runs example-org/demo-web --sha "$(git rev-parse HEAD)" --text || gh run watch …   # the fallback is the rule's: one background watch, --interval 60
```

## What release.sh does with it

`release.sh` waits for a PR's checks by reading the commit's check runs every minute. Now, each look first asks `cipoll.py pending`: when the file
for the repo is fresh (`SALA_RELEASE_CIFILE_MAX_AGE`, 120 s; `0` = never use the file) **and lists a workflow run of that commit that has not completed**,
the look makes no check-runs call and the release goes on waiting (one log line: `… 1 of 1 run(s) of 0123456 not completed (file 18s old); waiting on the ci-runs file, no GitHub call`).
In every other case, which is: the run is listed as completed, no run of the commit is listed, the file is missing, stale or unreadable, or this checkout has no `lib/cipoll.py`,
the look is the check-runs read it always was, through `gh_read` with its ETag and its 60 s shared cache, and **that read alone decides pass or fail**. So the
file can only make a release wait, never pass or fail one, and no gate is weaker; what it saves is the wait's calls (the bulk of a release's cost: the 5 to 45
minutes a run takes).
Two consequences: a failing job is noticed when the file shows the workflow run completed (a minute or two after it fails, the run's other jobs having to finish
first), not at the moment the job fails as the check-runs read did; and a check run that belongs to no workflow run is read only once the workflow runs are done.

## Adding a repo

Add its line to `~/.config/salamander/ci-repos` (one `owner/name` a line; the poller reads the file every pass). The
poller costs one read a minute per repo whatever the number of waiters.

## Installing the unit (after the release that adds it deploys)

`sala job add` writes a service and a timer, so it does not fit a resident service; the unit follows `sala-follow.service` (docs/units.md): the file is in
`systemd/`, linked by hand into the user unit folder.

```
ln -sf ~/salamander/systemd/sala-cipoll.service ~/.config/systemd/user/ && systemctl --user daemon-reload && systemctl --user enable --now sala-cipoll.service
```
