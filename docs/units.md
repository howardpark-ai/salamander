# sala's systemd units, and the model lane each runs on

The unit files of sala's scheduled jobs live in this repo; the scripts they run live in their own
repos. The Schedules tab of sala's Overview page (before that a page of its own) lists them all and reads these lines from each
service unit:

```
X-Model-Lane=<lane>      # subscription-1, bedrock, aws-platform, api, subscription-2, sdk or none (older lane words are still read as aliases)
X-Project=<scope/project> # the job's project, as the Agents tab's Project column shows it: projects/demo-docs, team/docs …
```

An optional `X-Model-Note=<text>` line in `[Unit]` (at most one) is the tooltip of the lane chip on the Schedules tab, for a call the lane
alone does not say (`sala-watch.service` uses it for the hourly api key check).

**The project.** `X-Project=` is the job's Category on the Schedules tab: the tab is one table, sorted by Category and then Job by
default, and the Category is this line, never a mapping kept in the web code. The value is stored as the label the Agents tab's Project column
shows (`<scope>/<project>`, lower case), so the two tabs name a project the same way. A job with no `X-Project=` shows "—" as its Category,
sorts last, and `sala job check` reports it as the gap `no-project`. Set it when the job is added (`sala job add --project`) or later with
`sala job set-project NAME PROJECT`.

**Showing a project under another name.** The units sala ships carry the neutral `X-Project=sala/salamander`, and they are copied byte for byte, so an
instance does not edit them. `SALA_UNIT_PROJECT_MAP` in the sala config (space-separated `from=to` pairs, for example `sala/salamander=lab/sala`) makes
`sala job list`, the gap check and the Schedules tab show a unit's `X-Project=` value `from` as `to`. A pair with no `=` or an empty side is ignored,
a `from` named twice takes the last, and unset or empty means no mapping. It changes what is shown and checked, never a file; `set-project` and `add`
still write the value they are given.

`X-` keys in `[Unit]` are ignored by systemd, so the lines are metadata only. `tests/units.sh` checks that every `.service` with an
`ExecStart` under `systemd/` and `contrib/*/systemd/` has exactly one, with a valid value (and, if it has an `X-Model-Note=`, one that is not empty), that it
has exactly one `X-Project=<scope/project>`, and that every `.timer` has its `.service`. The lanes are the ones in the README *Lanes* section (`sala lane --help`); `none` means the unit starts no model call.
The value is what the unit's script runs by default, read from the code; where a variable can move it, a
`# X-Model-Lane note:` comment in the unit names the variable. **Change the line in the same PR as the change that moves the lane.**

**Putting a job on a lane.** The line is a label; the lane is whatever environment the job's `claude` starts with. A unit
gets a lane's environment from sala, never by pasting values into the unit: `ExecStart=%h/.local/bin/salamander lane exec <lane> -- COMMAND…`
starts COMMAND with the variables that would pick another provider or login removed (`ANTHROPIC_API_KEY`, `ANTHROPIC_CUSTOM_HEADERS`,
`ANTHROPIC_AUTH_TOKEN`, `AWS_BEARER_TOKEN_BEDROCK`, the Bedrock, Claude-Platform-on-AWS and Foundry switches, `CLAUDE_CONFIG_DIR`) and every
variable any other lane sets (the profile, region, workspace id, the pinned `ANTHROPIC_DEFAULT_*_MODEL` ids, the cache switches: derived from the lanes' own
definitions, `lane_job_unset` in `lib/common.sh`), for every lane, `subscription-1` included: each is unset (`env -u`), never left present with an empty value,
because Claude Code reads a present-but-empty `CLAUDE_CODE_USE_ANTHROPIC_AWS` as set (a `lane exec subscription-1 -- claude --cloud …` from an aws-platform pane
was refused for it). Then the lane's own set (for bedrock: `AWS_PROFILE`, `CLAUDE_CODE_USE_BEDROCK=1`, `AWS_REGION`, `ANTHROPIC_BEDROCK_REGION_PREFIX` and the three pinned
model ids, the values `lane_env_prefix` puts on a session's launch line; not the 1-hour prompt cache switch, which only a pane's launch line carries (`ENABLE_PROMPT_CACHING_1H_BEDROCK=1` on bedrock, `ENABLE_PROMPT_CACHING_1H=1` on aws-platform and api): a one-shot job never reuses a cache entry and the 1-hour write costs more), and fails without running COMMAND when the lane is not ready.
`salamander lane env <lane>` prints the same pairs (never a secret; the AWS keys are the profile's); for `subscription-1`, which sets none, it prints nothing (one line on stderr when stdout is a terminal). Everything COMMAND starts inherits
them, so a script's `claude --model sonnet|haiku|opus` resolves to the lane's pinned ids; a script must not name a model id of its own
(a model may not run on every lane). Do not wrap a long-lived or fleet-managing process this way (`sala-watch` itself): what it starts, a
relaunched pane included, would inherit the lane; its own model calls take `SALA_JOB_LANE` through `job_env_args` instead.

## The units

| unit | where | timer | lane | what decides it |
|---|---|---|---|---|
| `sala-watch.service` | `systemd/` | every 2 min | `bedrock` | the tick makes no model call itself; the ones it can start run on the lane `SALA_JOB_LANE` names (default `subscription-1`; set `bedrock` or `api` to move them): the stuck-operation helper, one `claude -p` per stuck op (`SALA_OP_STUCK`, default on; `lib/op.sh` `op_helper`), and the parked-question sweep `claude -p --resume` (`lib/question.sh` `qs_claude`, started by `lib/watch.sh` `question_sweep_tick`). `job_env_args` (`lib/common.sh`) puts the lane's environment on that one `claude` only, never on the watch, so a pane it relaunches never inherits it; a lane that is not ready leaves the stuck operation stuck and the question parked, said in the log. Also, while a session's row or the default is `api` or `sdk`, the sign-in watch sends one `max_tokens` 1 Messages API request an hour with the api lane's key (`lib/watch.sh` `sw_api_probe`): a key check, not a session |
| `sala-heartbeat.service` | `systemd/` | every 5 min | `none` | `lib/heartbeat.sh` reads the registry, runs `claude --version`, ssh and git; no `claude -p`, no API call |
| `sala-follow.service` | `systemd/` | none (resident) | `none` | `lib/follow.py` watches `~/.claude/sessions` and runs `sala rename --sync` (a name changed) or `sala watch --continued` (a sessionId changed); no model call |
| `sala-cipoll.service` | `systemd/` | none (resident, `Restart=always`) | `none` | `lib/cipoll.py poll` (`salamander ci-poll`): one `gh api -i` read of `actions/runs` per repo of `~/.config/salamander/ci-repos` (else `lib/ci-repos`) every `SALA_CIPOLL_INTERVAL` s, with the url's ETag, one atomic JSON file per repo under `~/.local/state/salamander/ci-runs/` (`docs/ci-runs.md`); no model call. A resident service, so `sala job add` (service + timer) does not make it and `sala job check` (timers only) does not list it; it follows `sala-follow.service`: the file lives in `systemd/` and is linked by hand (`ln -sf ~/salamander/systemd/sala-cipoll.service ~/.config/systemd/user/`, `daemon-reload`, `enable --now`) |
| `sala-briefing-summary-lean.service` | `contrib/briefing/systemd/` | daily at 06:00 UTC (the unit's `OnCalendar` names its zone) | `bedrock` | `summary-lean.sh --post` calls `claude -p` directly; ExecStart is `salamander lane exec bedrock -- …`, `CLAUDE_CONFIG_DIR` only when `BRIEFING_CLAUDE_CONFIG_DIR` is set (it is empty) |
| `sala-briefing-defunct.service` | `contrib/briefing/systemd/` | daily at 06:15 UTC (the unit's `OnCalendar` names its zone) | `bedrock` | `defunct.sh` (off until `BRIEFING_FORWARD_LABEL` is set) → `run_claude_retry` (`lib.sh` `run_claude`: the Agent SDK on the API key while the key is accepted (the shared record: README "The sdk lane"), else `run_cli` runs `claude -p` on the lane) |
| `sala-briefing-release.service` | `contrib/briefing/systemd/` | daily at 06:30 UTC (the unit's `OnCalendar` names its zone) | `bedrock` | `release-alert.sh` → `release-watch.sh`: the probes call no model; the relay turn is the Agent SDK on the API key while the key is accepted, else `claude -p --model haiku` on the lane (`release-watch.sh` `relay`); ExecStart is `salamander lane exec bedrock -- …` |
| `sala-unit-gaps.service` | `systemd/` | none (started by `sala-unit-gaps.path`) | `none` | `sala job check --post` (`lib/unitjob.py`) reads the unit folders; its only calls are one stackshot `post job-gap open` per new gap and one `clear` per fixed gap; no model call |
| `sala-pr-watcher-cleanup.service` | `systemd/` | every 30 min (`OnCalendar=*:0/30`) | `none` | `lib/pr_watcher_cleanup.py` (run as `python3 -I`, stdlib only): deletes the finished one-time scheduled tasks that cloud sessions leave on the Claude account to watch a pull request (*PR-watcher cleanup*, below); calls the account's `/v1/code/triggers` and `/v1/code/sessions` endpoints with the CLI's sign-in, `gh api` for a pull request's state and stackshot's `client.py message` for the ask; no model call |
| `sala-mockup-clean.service` | `systemd/` | daily (`OnCalendar=*-*-* 04:00:00 UTC`) | `none` | `salamander mockup clean` (`lib/mockup.py`, stdlib only; [mockup.md](mockup.md)): deletes mockup pages over 7 days old that no open board item links (`SALA_MOCKUP_REFERENCES` says how to tell; unset = delete nothing and say why), then keeps the mockup folder under 1 GB (`SALA_MOCKUP_MAX_BYTES`), oldest first and linked pages last; no model call |
| `machine-follow.service` | `systemd/` | every 10 min (`machine-follow.timer`) and when `machine-follow.path` fires | `none` | `lib/machine-follow.py` (the dispatcher, no `--host`): fingerprints what the machines follow, starts `machine-follow@<hostname>.service` with `systemctl --user start --no-block` for each machine that is due and has no instance running, then exits (`TimeoutStartSec=5min`); no model call. The unit names have no `sala-` prefix on purpose (*machine-follow*, below); a unit linked by hand like `sala-cipoll.service` |
| `machine-follow@.service` | `systemd/` | none (a template, started by the dispatcher) | `none` | `lib/machine-follow.py --host %i`: one machine's follow, its step run with its own timeout (the data file); `TimeoutStartSec=3h`, above the largest step plus the settle wait; no `[Install]`, never enabled; no model call |
| `machine-follow.path` | `systemd/` | triggers `machine-follow.service` | `none` | `PathChanged=` on `~/stackshot/.git/refs/heads/main`, `~/salamander/.git/refs/heads/main`, `~/.bun/install/global/bun.lock` and `~/.local/bin/claude`: a deploy, a knowledge-base install or a CLI update on the driving machine |
| `machine-follow.timer` | `systemd/` | `OnBootSec=5min`, then every 10 min after the last start | `none` | the fallback for a missed path event and the refresh a machine with `catch_up_minutes` gets |

## PR-watcher cleanup

`sala-pr-watcher-cleanup.timer` (every 30 minutes) runs `lib/pr_watcher_cleanup.py`. A cloud session that wants a pull request checked later sets a
one-time scheduled task on the signed-in Claude account; when it fires, the account gets a "turned off" notice and a switched-off task stays behind. The
job lists the account's tasks and removes the finished watchers.

**What it looks at.** Only a PR watcher: a task with no cron expression whose prompt names a pull request (`owner/repo#N`, a github.com `/pull/N`
link, or `PR #N`). A recurring routine, a one-time task that names no pull request and a task another account created are never deleted.

**When a watcher is done.** It fired and is off (`ended_reason` `run_once_fired`); or, not yet fired, every pull request it names (each with its repo) is
merged or closed; or its session is archived or no longer exists. A watcher switched off without ever firing, or one whose pull request or session cannot be
read, is left alone and logged once.

**What happens to a done watcher.** The job reads the creating session (`persistent_session_id`, else the first session id in the task's config):
`GET /v1/code/sessions/<id>`.
- *No live creator* (the session is archived, not found, not connected, or the task names none): the task is deleted at once and the session is never woken.
  Live is only a session whose status is `active` and whose connection is `connected`; the API gives nothing finer, so anything else counts as not live. A
  wrong call here costs nothing, since the task is finished anyway.
- *A live creator*: the creator is sent one message through stackshot (`client.py message <session> - --sender pr-watcher-cleanup`) asking it to delete the
  task, and the job deletes it itself `SALA_PRWATCH_GRACE_S` (86400, 24 h) after the ask. The message is never sent twice for a task. If it cannot be sent
  (no `client.py` on the box, a refusal) the next pass tries again, and the deletion comes 24 h after the task was first seen done.

**Errors.** A failed call (the list, a session, GitHub, the delete itself) leaves that task as it was and the pass goes on to the next; the exit status is
1 when any call failed. An expired access token touches nothing and exits 0 (the CLI refreshes the token the next time a session on that login runs). The
sign-in is the one `lib/rc.sh` and `lib/revive.sh` use: the access token in `<claude config dir>/.credentials.json` as a bearer token, and the account's
organization uuid from `.claude.json`; it is never written to the log, the state or the output.

**Installing.** A deploy does not copy or link a unit (*What a deploy does*, CONTRIBUTING.md), and the files were not made by `sala job add`, so no link exists yet. After the deploy: `ln -sf ~/salamander/systemd/sala-pr-watcher-cleanup.service ~/salamander/systemd/sala-pr-watcher-cleanup.timer ~/.config/systemd/user/`, `systemctl --user daemon-reload`, `systemctl --user enable --now sala-pr-watcher-cleanup.timer`.

**Where it writes.** `~/.local/state/salamander/pr-watcher-cleanup/` (`SALA_PRWATCH_STATE_DIR`): `pr-watcher-cleanup.log` has one line per action, in the `SALA_TZ` zone (the machine's own zone when unset),
with the task id, session, pull requests and reason (`delete`, `ask`, `skip`, `error`; no notice goes to the owner), and `state.json` has what was asked
and when. `python3 -I lib/pr_watcher_cleanup.py --dry-run` prints what it would delete or ask and writes nothing; `--only TASK_ID` (repeatable) limits a pass to the named tasks, for a check by hand.

There is no separate `sala-release` timer: `release.sh` is run on demand by the maintainer, not by a timer, and the
release watcher above is the briefing `sala-briefing-release`. `sala-op-<id>` units are transient (`systemd-run`) and have no file.

## machine-follow

`lib/machine-follow.py` keeps the machines one driving machine looks after level with it. One dispatcher, one path unit, one timer and one template unit
(the four rows above): when something a machine follows changes on the driving machine (the `~/stackshot` or `~/salamander` commit, the Claude CLI
version, the installed knowledge-base build), the dispatcher starts `machine-follow@<hostname>.service` for each machine that is due, and that instance runs the
machine's step (a script or command of the owner's, with its own timeout) and records the follow. A slow machine never holds up a quick one: each runs as its
own instance, and an instance still running is left alone. A step exits 0 (followed; the state is written), 75 (the machine is stopped, unreachable or not
ready: nothing done, not a failure, tried again at the next dispatch or after the entry's `retry_minutes`) or anything else (a failure; the instance exits 1).
`machine-follow.py --dry-run` says which machines are due and why and changes nothing; `--host <hostname>` runs one machine's follow now, `--force` with it
treats the machine as due.

- **The unit names have no `sala-` prefix.** They are linked by hand like `sala-cipoll.service`: the file lives in `systemd/`, a deploy copies and links
  nothing.
- **The data file** (`machines.toml`: `run_on`, the host the script runs on, and one `[machines.<hostname>]` entry per machine with `follows`, `command`,
  `timeout_minutes` and the optional `before_command`, `reach`, `catch_up_minutes`, `retry_minutes`) is the owner's data and is not in this repository.
  Its path is the setting `SALA_MACHINE_FOLLOW_MACHINES` (`config.example`): from the process environment, else the line in `~/.config/salamander/config`
  (the units have no sala environment, so the script reads that file as text, the way sala-web does), else `~/.config/salamander/machine-follow.toml`. A missing
  file is one line on stderr and exit 2; a wrong entry is named in one line (exit 2); a host other than `run_on` is refused (exit 64). A `~/` in a step's
  command is the home folder.
- **The state** is `~/.local/state/machine-follow/<hostname>.json` (what was followed and when, written only when the step exits 0; the Machines tab of the web
  UI reads it), `<hostname>.attempt.json` (the last skip or failure, so `retry_minutes` can hold the next try back) and `<hostname>.lock` (one run per
  machine at a time).
- **Run on the `run_on` machine only.** The script refuses on any other host, and the units have no `ConditionHost=` (it would name a machine in this
  repository), so link the family only where it runs. `machine-follow@.service` has no `[Install]`: it is started by name, never enabled.
- **The lane is `none`** (no model call). `TimeoutStartSec=3h` of the template stays above the largest `timeout_minutes` of the data file plus the settle wait
  (a due follower of a tool install waits until the install has been still for 60 s, up to 10 minutes); `tests/machinefollow.sh` keeps the template's
  timeout above the largest step timeout plus the settle wait, and the owner checks the largest entry of the data file when it changes.
- **Installing:** after the deploy, `ln -sf ~/salamander/systemd/machine-follow.{path,timer,service} ~/salamander/systemd/machine-follow@.service ~/.config/systemd/user/`
  (it replaces an existing link in one step, so the unit is never missing), `systemctl --user daemon-reload`, and for a first install
  `systemctl --user enable --now machine-follow.path machine-follow.timer`. An existing install keeps its enabled `.path` and `.timer`: the reload is enough.
  Look: `systemctl --user list-timers machine-follow.timer`, `journalctl --user -u machine-follow -u 'machine-follow@*'`, `python3 ~/salamander/lib/machine-follow.py --dry-run`.

## Getting the units onto a box

The repo's convention is a copy: `install.sh` prints the `cp` line for the watch. `deploy.sh`
installs and restarts none of them. Linking instead of copying means a unit file changes the moment `deploy.sh` fast-forwards
`~/salamander`, and is read by systemd at the next `daemon-reload`.

To replace the loose files by links into the production checkout (run by hand, one go; nothing here restarts a unit):

```
U=~/.config/systemd/user; S=~/salamander
for f in sala-watch.service sala-watch.timer sala-heartbeat.service sala-heartbeat.timer sala-follow.service; do ln -sf "$S/systemd/$f" "$U/$f"; done
for f in sala-briefing-{defunct,release,summary-lean}.{service,timer}; do ln -sf "$S/contrib/briefing/systemd/$f" "$U/$f"; done
systemctl --user daemon-reload
systemctl --user list-timers 'sala-*'      # the timers are still enabled and scheduled
```

`ln -sf` replaces the regular file with the link in one step, so the unit is never missing. `sala-follow.service` is resident and keeps
the code it started with; the reload does not restart it.

## Every scheduled job is in git: `sala job` and the gap watcher

Every scheduled job is a systemd service + timer kept in git in the repo that owns the script, with a
`Description=`, an `X-Model-Lane=` and an `X-Project=` line in the service's `[Unit]`. `sala job` does it in one command, with no model call
(`lib/job.sh`, `lib/unitjob.py`), and a watcher finds the jobs that are not.

```
sala job add NAME --repo REPO --script PATH --schedule SCHEDULE [--schedule …] --description "…" --lane LANE --project SCOPE/PROJECT [--note "…"] [--args "…"] [--scope user|system] [--checkout DIR]
sala job list                       # our timers: name, repo, schedule, lane, project, in git yes/no
sala job set-project NAME PROJECT [--checkout DIR] [--quiet]   # write X-Project= into the job's git file; prints what to commit
sala job remove NAME [--checkout DIR]   # disable --now, unlink (what disable already removed is skipped), daemon-reload, reset-failed, delete the repo copies
sala job relink NAME                # after the pull request that added a job is deployed
sala job check [--post] [--quiet]   # the gap watcher's pass
```

- **Where the files go** is the repo table: `~/.config/salamander/unit-repos.tsv` when the box has one, else the tracked `lib/unit-repos.tsv`, which lists no repo (a new repo is one more line; `SALA_JOB_REPOS` names another file). Each repo's row says its unit folder (`user_dir` for user scope, `system_dir` for system scope, for example `units/{name}/systemd`); `salamander` gets `systemd/`. `stackshot` has no
  folder to write to: it renders its units from `units/*.in` with its `install.sh` and a fixed list, so a stackshot job is a stackshot
  pull request, and `sala job add --repo stackshot` refuses and says so. A repo that is not in the table is refused.
- **User scope** (the default): the two files are written into the repo's folder, linked into `~/.config/systemd/user`,
  `daemon-reload`, `enable --now <name>.timer`. **System scope** only writes the files and prints the `sudo install … && sudo systemctl
  enable --now` line for the owner: sala never uses sudo.
- **It commits nothing.** It prints the `git status` and the exact steps. A repo with `flow main` commits straight to main (`pull --rebase
  --autostash`, `push`). A repo with `flow pr` (salamander) goes by branch and pull request, and nobody edits its production checkout:
  `--checkout` is a worktree (`git worktree add`), the files are written there and linked from there, and once the release has deployed
  the pull request `sala job relink <name>` points the links at the production checkout. A new unit file under `systemd/` also needs
  `bash tests/suitemap.sh --measure units` (the map names the files a suite opens).
- **Refused, with the usage line and nothing written:** no or empty `--description`, no or unknown `--lane`, no `--project` or one that is not
  `scope/project`, an unknown `--repo`, a
  `--script` that is not a file (or is neither executable nor `.py`/`.sh`), a schedule `systemd-analyze` does not accept, a taken name, a
  repo with no unit folder, a `flow pr` repo without a worktree. A `.py` script runs through `uv run --script`.
- **Schedules** are `OnCalendar` expressions or `OnBootSec=`/`OnUnitActiveSec=` forms (`--schedule` repeats). `OnCalendar` takes a zone
  after the time, for example `Europe/Berlin`.
- **Tests never touch installed units:** `SALA_JOB_USER_DIR`, `SALA_JOB_SYSTEM_DIR`, `SALA_JOB_SYSTEMCTL`, `SALA_JOB_REPOS` point the verbs at
  a temporary tree (`tests/jobs.sh`).

**The gap watcher.** `sala job check` looks at our timers: the `.timer` files in `~/.config/systemd/user` and (read only) in
`/etc/systemd/system`, leaving out a unit whose file resolves under `/usr/` or `/lib/` (a package's). A gap is one of
`no-description` (no `Description=` in the service), `no-lane` (no `X-Model-Lane=`), `bad-lane` (none of the seven), `no-project` (no
`X-Project=`), `not-git` (a
unit file that is neither a symlink into a git repo, nor a stackshot-rendered file whose template exists, nor byte for byte a tracked
file of the same name in a repo of the table, or in the repo of the unit's script) or `git-differs` (a plain copy that differs from the git file of its name). It reads files; the only git call is for a regular file's tracked twin, and a hit is
remembered (`unit-gaps.twin` in the state folder). It mirrors `web/src/sala_web/schedules.py` (the Schedules tab flags the same).
`--post` opens each gap as **one board item**, `client.py post job-gap open <timer> <code> --repo <owner/name> --detail "<the gap, the
files and the fix, one line of at most 600 characters>" --sender sala-unit-gaps`, which prints the item's id (`docs/stackshot-contracts.md`, interface 26). `--repo` is the GitHub owner/name of the repo that owns the unit's script, the
table's last column (`github`; a script in no repo of the table
→ the `*` row, else the `SALA_JOB_GITHUB` setting; both empty = the gap is not posted, and `sala job check` says so; stackshot refuses a repo it does not list). **The mover is stackshot's to set**: the
builder of that repo's project (the table's `builder` column is what `sala job check` shows, not what is sent). A gap is opened once, deduped
by timer and gap code in `unit-gaps.tsv` (state folder, with the item id), so a repeat open never happens; at most three opens and three
clears a pass, and none more in a pass once the board does not answer. When the gap is fixed, `client.py post job-gap clear <timer> <code>
--sender sala-unit-gaps` closes the item and the record is dropped; a clear that fails keeps the record and is tried at the next pass, as is an
open that fails (nothing is recorded for it). A gap that comes back is opened again. With no `client.py` on the box, or one from before the
`job-gap` call, the pass logs a line and does nothing (exit 0).

**Backfilling the project of the jobs that predate `X-Project=`.** The first `sala job check --post` on a machine with jobs that predate `X-Project=` would open a
`no-project` item for every job that has none (at most three a pass, but every pass), so run the backfill first:

```
bash ~/salamander/contrib/backfill-job-projects.sh --dry-run    # lists each job, its project and the unit file it would edit; writes nothing
bash ~/salamander/contrib/backfill-job-projects.sh              # runs `sala job set-project NAME PROJECT --quiet` for each listed job
```

The list of jobs and projects is the box's map, the file `SALA_BACKFILL_MAP` names (config.example: `scope/project: job …` lines and an optional
`rendered: job …` line; unset, the script does nothing); a job that is not on it is left without a project, so
`sala job check` reports it. The units of a repo with flow main are edited in place on its main checkout and the script prints the commit steps (`pull
--rebase --autostash`, `add`, `commit`, `push`); the units of `salamander` are the repo's own and carry `X-Project=` already. A
unit the map lists on its `rendered:` line (a unit another repo renders from a template) is skipped and named: its `X-Project=` goes into the template (a pull
request). The exit status is 0 only when no job failed and no listed job is missing.

It runs from `sala-unit-gaps.path` (`PathChanged=` on both unit folders: a unit file added, removed or renamed; an in-place edit of a
file that is a symlink's target is seen by the tick) and from the `sala-watch` tick every 2 minutes (`unit_gaps_tick`, one python
process; `SALA_UNIT_GAPS=off` turns it off). A burst of unit writes is one run: the service waits 5 s (`ExecStartPre=/bin/sleep 5`) before it
checks, and the path unit's start limit is 20 starts in 60 s (`TriggerLimitIntervalSec=60s`, `TriggerLimitBurst=20`). A lower limit trips in a burst of unit writes: the path unit goes to `failed` (trigger-limit-hit) and stays dead until it is restarted; recover a failed one with `systemctl --user reset-failed sala-unit-gaps.path && systemctl --user restart sala-unit-gaps.path`. Install the path unit once, like the other units here:
`ln -sf ~/salamander/systemd/sala-unit-gaps.{path,service} ~/.config/systemd/user/ && systemctl --user daemon-reload &&
systemctl --user enable --now sala-unit-gaps.path`.
