# Background agents for front-only projects: `sala bg-agents`

A project that lists a front agent and no background agent gets one from this job, not from the owner each time. Stackshot records the want and serves it as
plain text (`client.py background-wanted`, one line `<project key> <name prefix> <front agent>`; empty when there is none or when its own switch is off).
`sala bg-agents`, run from a timer, takes at most one of them per run: it lists the agent `<name prefix>-engineer` on the project and starts its pane. Later messages
reach that agent through the project's normal routing; this job only creates it.

```
$ sala bg-agents --dry-run
2027-01-15T17:00:00+09:00 plan projects/example: would list example-engineer (engineer, background; label sala-web), then start its pane (sala spawn --project projects/example --role back); attempt 1 of 5; load 0.50 (dry run)
dry run: nothing was posted, started or written
```

## Commands

| | |
|---|---|
| `sala bg-agents` | one run (below). Off unless `SALA_BGAGENTS=on` in the config: off prints one line, exits 0 and reads, writes and starts nothing. |
| `sala bg-agents --dry-run` | the whole decision, said as one line; nothing is listed, started, written or logged to the file. The want list and the load are read. |
| `sala bg-agents --status` | the ledger, one line a project: agent, attempts, failures, next try (in `SALA_TZ`), state. Read-only; works with the switch off. |

Exit codes: 0 = the run finished (a skip or a failed project too), 1 = a retire is needed (below), 2 = a usage error or a bad setting.

## One run, in order

1. **The switch.** `SALA_BGAGENTS` is not `on`: one line, exit 0, nothing touched.
2. **The want list**, read with `SALA_BGAGENTS_LIST_CMD` (default: the stackshot client's `background-wanted`). A read that fails is one line and exit 0 with the ledger untouched: it
   is no project's failure. A line that is not three words with a valid project key and prefix is said and ignored.
3. **The ledger is brought up to date.** A project in it that is not on the list gets `absent_since`; a project back on the list loses it. An entry is cleared **only** after
   its project has been off the list for at least the cooldown (it is the only reset), unless this job listed an agent for it and has not started its pane yet.
4. **One project.** The list is walked in order. A project given up or in back-off is skipped with one line. The first project that is due is the run's one attempt.
5. **The load check**, before anything is listed: the 1-minute average from `/proc/loadavg` must be under `SALA_BGAGENTS_MAX_LOAD` (10). At or above it, or when the file cannot be read, the
   run says so in one line and stops. That is not a failure and takes nothing from the ledger.
6. **The listing.** `client.py post project-agent <project> <name> --role engineer --back --mandate "<line>" --sender sala-web`. The name is `<name prefix>-engineer`, the role is `engineer`,
   the agent is a background (back) one, and the mandate is one line from one place (`SALA_BGAGENTS_MANDATE`; the default names the owner from `SALA_OWNER_NAME`). The label is
   the one the New session form posts with, which the stackshot instance lists in its `[project_agent]` `form_senders`. When the stackshot project record already shows the name on
   the project, it is not listed again: the run goes to the start. Stackshot's "already listed, nothing changed" answer is no error either.
7. **The start.** `sala spawn NAME --project KEY --role back --mandate "<line>"`, then a bounded wait for the session to be live (`SALA_BGAGENTS_ALIVE_WAIT`). A start that exits 3 right after the
   listing means sala's copy of the project record lags (it is refreshed about every five minutes): that is waited out for `SALA_BGAGENTS_RECORD_GRACE` (900 s) without a failure, and finished from
   the ledger at a later run even when stackshot's list has already dropped the project (its agent is on the map now). It becomes a failure after the grace.
8. **The log.** One line a decision, on stdout (the unit's journal) and appended to `bgagents.log` beside the ledger: `<time in SALA_TZ> <action> <text>`. No token appears in a line.

## Failures, back-off, the cap

A failure raises the project's back-off: `SALA_BGAGENTS_COOLDOWN` seconds (600), doubled for every further failure, up to `SALA_BGAGENTS_COOLDOWN_MAX` (86400). `next_try` is kept
in the ledger and no call is made before it. At `SALA_BGAGENTS_MAX_ATTEMPTS` (5) attempts the project is left alone: one log line a run, no call, and `--status` says "given up".
Clearing it is the ledger's reset (the project off the list for the cooldown) or an edit of the file.

The failures:

| Failure | Why |
|---|---|
| the listing failed or timed out | an HTTP 409 (the name is taken or pending by another sender, or another project's longer prefix) and a 403 (a hidden or non-listed project: a `project-list` post is needed first) are in it; the reason is logged |
| the start failed | `sala spawn` exited non-zero, timed out, or reported the pane up but the session is not live |
| the project is listed again after this job created and retired its agent | the want came back; this is one more attempt on the books |
| the project is still listed after this job started its pane and the cooldown passed | a running agent is **never** retired for it, and no second start is made |

A load skip is not in the table: it takes nothing from the ledger.

## Retiring is a marked step, not done here

When an agent this job listed could not be started, it should come off the project again. Every path sala has for that takes the owner's words for an agent on a project's agents map
(`lib/op.sh`, the words policy: `retire` is for throwaway sessions only, `forget-row` is the owner's), and no door lets a job do it. The job does not invent one. It says
`retire needed: <name>`, exits 1 and keeps `retire_needed` in the ledger. The entry stays on the map, so the next attempt finds it there, does not list it twice and tries the start again;
a start that works clears the mark. The job never retires an agent it did not list, an agent after a 409, or a running agent.

## Ledger

`$SALA_STATE_DIR/bgagents.json` (default `~/.local/state/salamander/`; `SALA_BGAGENTS_LEDGER` moves it), mode 600, written atomically (a temporary file in the same folder, fsynced, renamed over the
ledger; one left by a crash is swept at the next save). It is read and written under a lock (`bgagents.json.lock`): a second run at the same time stands aside. Per project: `prefix`, `agent`,
`attempts`, `failures`, `next_try`, `created` (this job listed the agent), `posted_at`, `started_at`, `retired`, `retire_needed`, `awaiting_record`, `last` and `last_at`, `absent_since`. An attempt
is counted before anything is asked, so a death in the middle leaves it on the record.

## Settings

All are in `config.example`, commented, default off. They are read from the config file (the timer's service has only `PATH` in its environment) or the environment.

| Setting | Default | |
|---|---|---|
| `SALA_BGAGENTS` | `off` | `on` turns the job on |
| `SALA_BGAGENTS_COOLDOWN` | 600 | seconds after a failure, doubled each time; also the absence that resets an entry |
| `SALA_BGAGENTS_COOLDOWN_MAX` | 86400 | the longest wait between two tries |
| `SALA_BGAGENTS_MAX_ATTEMPTS` | 5 | attempts before a project is left alone |
| `SALA_BGAGENTS_MAX_LOAD` | 10 | 1-minute load average at or above which a run does nothing |
| `SALA_BGAGENTS_MANDATE` | the default line | the one line the agent is listed with and started on |
| `SALA_BGAGENTS_SENDER` | `sala-web` | the label of the listing call |
| `SALA_BGAGENTS_LEDGER` | `$SALA_STATE_DIR/bgagents.json` | the ledger path |
| `SALA_BGAGENTS_LOADAVG` | `/proc/loadavg` | where the load is read |
| `SALA_BGAGENTS_RECORD_GRACE`, `_ALIVE_WAIT`, `_POST_TIMEOUT`, `_SPAWN_TIMEOUT` | 900, 30, 120, 300 | seconds |
| `SALA_BGAGENTS_LIST_CMD`, `_POST_CMD`, `_SPAWN_CMD`, `_ALIVE_CMD` | the stackshot client and this sala | the four commands (the suites stub them) |

## Running it from a timer

No unit file ships with sala: a hand-linked unit is not installed by a deploy. Make the timer with `sala job add` (`docs/units.md`), which writes the unit and refuses a taken name,
for example every ten minutes; the job's script is `sala bg-agents`. The job does nothing while `SALA_BGAGENTS` is off, so the timer can be installed first and the switch turned on after.
