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
| `sala bg-agents --reset KEY` | clears one project's ledger entry (below). A ledger edit, not a run: it works with the switch off. `--dry-run` with it says what it would clear and writes nothing. |
| `sala bg-agents --status` | the ledger, one line a project: agent, attempts, failures, next try (in `SALA_TZ`), state. Read-only; works with the switch off. |

Exit codes: 0 = the run finished (a skip or a failed project too), 1 = a retire is needed or a board item is needed and could not be raised (below), or `--reset` named a key with no entry, 2 = a usage error or a bad setting.

## One run, in order

1. **The switch.** `SALA_BGAGENTS` is not `on`: one line, exit 0, nothing touched.
2. **The want list**, read with `SALA_BGAGENTS_LIST_CMD` (default: the stackshot client's `background-wanted`). A read that fails is one line and exit 0 with the ledger untouched: it
   is no project's failure. A line that is not three words with a valid project key and prefix is said and ignored.
3. **The ledger is brought up to date.** A project in it that is not on the list gets `absent_since`; a project back on the list loses it. An entry is cleared **only** after
   its project has been off the list for at least the cooldown, unless this job listed an agent for it and has not started its pane yet, **or a board item was raised for it** (or is being
   filed): a raised entry stays until a session resets it with `--reset`, whether its project is on the list or not, so a project that comes back never starts, or raises a second item, over
   the owner's earlier answer. `--status` shows it as raised and not on the want list.
4. **One project.** The list is walked in order. A project given up, in back-off or with a board item raised (below) is skipped with one line. The first project that is due is the run's one attempt.
5. **The load check**, before anything is listed: the 1-minute average from `/proc/loadavg` must be under `SALA_BGAGENTS_MAX_LOAD` (10). At or above it, or when the file cannot be read, the
   run says so in one line and stops. That is not a failure and takes nothing from the ledger.
6. **The listing.** `client.py post project-agent <project> <name> --role engineer --back --mandate "<line>" --sender sala-web`. The name is `<name prefix>-engineer`, the role is `engineer`,
   the agent is a background (back) one, and the mandate is one line from one place (`SALA_BGAGENTS_MANDATE`; the default names the owner from `SALA_OWNER_NAME`). The label is
   the one the New session form posts with, which the stackshot instance lists in its `[project_agent]` `form_senders`. When the stackshot project record already shows the name on
   the project, it is not listed again: the run goes to the start. Stackshot's "already listed, nothing changed" answer is no error either.
7. **The start.** `sala spawn NAME --project KEY --role back --mandate "<line>"`, then a bounded wait for the session to be live (`SALA_BGAGENTS_ALIVE_WAIT`). A start that exits 3 right after the
   listing means sala's copy of the project record lags (it is refreshed about every five minutes): that is waited out for `SALA_BGAGENTS_RECORD_GRACE` (900 s) without a failure, and finished from
   the ledger at a later run even when stackshot's list has already dropped the project (its agent is on the map now). It becomes a failure after the grace.
8. **The board item**, after the attempt: at most one a run (below).
9. **The log.** One line a decision, on stdout (the unit's journal) and appended to `bgagents.log` beside the ledger: `<time in SALA_TZ> <action> <text>`. No token appears in a line.

## Failures, back-off, the cap

A failure raises the project's back-off: `SALA_BGAGENTS_COOLDOWN` seconds (600), doubled for every further failure, up to `SALA_BGAGENTS_COOLDOWN_MAX` (86400). `next_try` is kept
in the ledger and no call is made before it. At `SALA_BGAGENTS_MAX_ATTEMPTS` (5) attempts the project is left alone: one log line a run, no call, and `--status` says "given up (board item raised)" or "given up (board item not raised yet)", and the owner is told once (next section).
Clearing it is the ledger's reset (the project off the list for the cooldown; never while a board item is raised) or `sala bg-agents --reset <project key>` (below, with the board item).

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
a start that works clears the mark. The board item below is raised for it in the same run, and from then on nothing is tried until a session resets the record (`--reset`). The job never retires an agent it did not list, an agent after a 409, or a running agent.

## A project it cannot start never stays silent: one board item for the owner

When a project reaches the attempt cap ("given up") **or** the ledger sets `retire_needed` (an agent this job listed whose pane did not start), the job raises ONE board item for the owner
through stackshot's client, `client.py post question`: a decision item filed under the project's own page (the want list's key), owned by the project's front agent, with a short ask, the
text below and three options. It is raised **once per project**: the ledger records `raised`, `raised_at` and `raised_item`, and a later run that finds the project still stuck raises nothing.
It is raised again only after a session reset the project's ledger entry (`--reset`) and the project gives up again; that is a new question (a new request id). The raised entry is never pruned
by the project's absence from the want list.

**Once raised, the project is left alone.** From the moment an item is raised for a project, the job makes no start attempt for it (it says `board item <id> raised; left alone until a
session resets the project's record`), whatever the ledger's attempt count and back-off say, until a session runs `sala bg-agents --reset <key>`. That is what "Keep trying later" is; the
owner's other two answers ("Leave it without one", "I will start it by hand") just leave the item raised, so nothing runs for the project.

What the owner reads, from a test (the subject opens with the bracket of the project's scope, below):

```
subject  [alpha] example wants a background agent and its start failed 5 times
ask      Decide: what to do about the background agent of example · Recommend: Keep trying later · Stakes: the project has no background agent until then · By: any time
text     - example wants a background agent (example-engineer), and starting it has failed 5 times.
         - The last problem: The agent's session could not be started.
         - The job has stopped trying, so the project stays without a background agent until you decide.
         - If you pick "Keep trying later", a session resets the project's record and the job tries again.
options  Keep trying later (recommended)  A session resets the project's record, and the job tries again from the first attempt.
         Leave it without one             The project goes on without a background agent.
         I will start it by hand          You start the agent yourself; the job leaves the project alone.
```

**"Keep trying later" is actionable.** A session that acts on that answer runs `sala bg-agents --reset <project key>`; the owner never runs it, which is why the item says only that a session resets the
project's record. `--reset` clears the project's ledger entry: attempts, failures, the back-off (so it is no longer given up), `retire_needed`, the board item (`raised`, `raised_at`, `raised_item`,
`raise_token`) and the last outcome (`last`, `last_at`, `last_plain`), so the job tries the project afresh at its next run and may raise a new item if it gets stuck again. The agent's entry on the
project's map is left as it is, and so is what the ledger knows of it (the agent, its listing, its start): the next run sees the agent already listed and goes to the start, as it does today.
It is a ledger edit, not a run: it works while `SALA_BGAGENTS` is off, takes the ledger's lock, writes atomically like every other write and prints one line saying what was cleared. A key with no
ledger entry is refused with one plain line and exit 1. `--dry-run` prints what it would clear and writes nothing.

The words are everyday ones: no exit code and no command is in the item. The last problem is the failure in one plain sentence, kept in the ledger as `last_plain` next to the technical
`last` (which stays in the log and in `--status`). When the agent is listed but its pane never started, a line says the agent is still on the project and that the job may not take it off
without the owner's word (the marked step above). One item covers both reasons.

The raise is not an attempt: it does not take the run's one attempt, it is no failure of the project, and it touches neither the attempt count nor the back-off. **Starts come first and
the raise is bounded.** It is made after the run's start attempt (so a project the attempt has just taken to the cap or to a retire step is raised in the same run), for **at most one**
project a run (the first that is due for a raise, in key order, the least recently checked first; any other outstanding project waits for the next run, and the run says how many wait). Each of its two calls (the instance's prefixes, the question) has its
own timeout, `SALA_BGAGENTS_RAISE_TIMEOUT` (30 s), not the listing's `SALA_BGAGENTS_POST_TIMEOUT`. The ledger lock is **not held across the network calls**: the run keeps the request id in the
ledger under the lock, gives the lock up for the calls, takes it again and writes the result to the entry as it is on disk then. So a slow or down stackshot delays no start and does not block
`--reset`; and a `--reset` that ran during the call wins: the entry it cleared is not written over, and the run says the record was reset while the item was filed (an item filed in that moment
stays on the board; the owner's answer is the same "keep trying").

**A project whose item is being filed is left alone.** Under the lock, before it is given up, the run marks the entry `raising_at` (with the request id, its token). Any other run that starts
meanwhile skips the entry, for the start and for the raise alike (`another run is filing its board item`; `--status`: "a board item is being filed"), until the mark is older than twice the raise
timeout and the wait for the lock (75 s with the default timeout): then the run that set it is taken as dead. When the first run returns, it writes the item only if the entry on disk still
carries ITS token and the project is still stuck: a start that worked meanwhile is not told to the owner as a failure (the run says the project is no longer stuck and the item is not recorded;
the item filed stays on the board). Only a project on the want list, or one whose listed agent has not been started, is asked about; a stuck project that has
left the list is not.

**An agent that is running is no start failure.** A project can reach the cap because it stays on the want list while its agent's session is live (the start failed late, or the pane was
started by hand). Before raising, the job asks the same liveness command the start uses (`SALA_BGAGENTS_ALIVE_CMD`, exit 0 live, 1 not). When the session is live, nothing is raised: the ledger
records `stale` and `last` = `agent running, want list stale`, the log line says so, `--status` shows it, and the project makes no new attempt while its pane is alive; once the pane is gone it is
looked at as any other project (stale cleared, raised if stuck). When the check cannot say (no command, a timeout, an ambiguous name, any exit but 0 and 1) a project that was not marked stale is raised for, saying only
what is known: its subject, text and stakes read "the start did not finish" instead of "failed N times" and "no background agent". **Only a confirmed exit 1 (not live) lets a running project back into the start
path:** a project that is stale, or whose pane was started, and whose check cannot say is left exactly as it is (stale stays set, no start attempt, nothing raised) and the log line says the check could not be told.

**The liveness checks are made without the ledger lock, and a few a run.** A check may take 30 s. The run collects the names it needs to check, saves the ledger, gives the lock up, asks, takes the lock again
and reads the ledger again from disk before it applies the answers, so a `--reset` or another run is never blocked by a check nor written over. At most `SALA_BGAGENTS_MAX_PROBES` (3) checks are made a run: the
start phase uses up to two, the raise the rest, the least recently checked project first (`probed_at`), so a few live projects never starve the others; a project whose check did not fit waits for the next run
(nothing is attempted or raised for it meanwhile, and the log line says so). A name checked in the start phase is not checked again for the raise.

**When the raise fails** (no stackshot client on the machine, the client refuses or does not answer in time), `raised` stays false, the run says `board item needed: <project> (could not be
raised: <reason>)` and exits 1, and the next run tries again with the same request id, so an item that was filed although the answer was lost is not filed twice. **A filing failure counts on its project** (`raise_failures`, `raise_next_try`,
shown by `--status`): the next filing waits out a back-off like a start's (the cooldown, doubled for every further failure), and the run's one raise goes to the first project that is DUE for one, so a key the
board keeps refusing never holds the others back; the run says `board item still needed: <project> (the last filing failed N times; next try <time>)` and exits 1 while only held-back projects are outstanding. A filing that works, or `--reset`, clears the count. The ledger keeps the token
before the call. The request id is `bgagents-<scope>-<slug>-<time>-<random>` (the full project key with `/` as `-`, so two projects with one slug in different scopes never share one, and a random part, so a project that is reset and stuck again in the same second does not reuse one); it is made once per escalation, kept in `raise_token`, reused by every retry of that escalation and made new after a reset. `--dry-run` raises nothing: it says `would raise one board item for the owner`.

**The subject's bracket.** Stackshot refuses a subject that starts with none of its prefixes and has no default, so the job picks one: `SALA_BGAGENTS_SUBJECT_PREFIX` when set (for example
`[hp]`, written as a bracket word); else the first of the project's own scope (stackshot's project record), `SALA_DEFAULT_SCOPE` and the first of `SALA_SCOPES` that the instance takes as a prefix
(`client.py get config`); else the instance's first prefix; the instance's prefixes unreadable, the first scope as it is; none at all, the raise fails with that reason (set the setting).

## Ledger

`$SALA_STATE_DIR/bgagents.json` (default `~/.local/state/salamander/`; `SALA_BGAGENTS_LEDGER` moves it), mode 600, written atomically (a temporary file in the same folder, fsynced, renamed over the
ledger; one left by a crash is swept at the next save). It is read and written under a lock (`bgagents.json.lock`): a second run at the same time stands aside. Per project: `prefix`, `agent`,
`attempts`, `failures`, `next_try`, `created` (this job listed the agent), `posted_at`, `started_at`, `retired`, `retire_needed`, `awaiting_record`, `last` and `last_at`, `last_plain`, `absent_since`, `stale` (agent running, want list stale), and for the board item `raised`, `raised_at`, `raised_item` and `raise_token` (the request id). An attempt
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
| `SALA_BGAGENTS_RAISE_TIMEOUT` | 30 | seconds each of the board item's two calls may take (the raise is one a run, after the start, without the ledger lock) |
| `SALA_BGAGENTS_MAX_PROBES` | 3 | the most liveness checks a run makes (at least 2; they are made without the ledger lock) |
| `SALA_BGAGENTS_ASK_CMD` | `client.py post question` | the board-item command; empty: no client, `board item needed` and exit 1 |
| `SALA_BGAGENTS_PREFIXES_CMD` | `client.py get config` | reads the instance's subject prefixes |
| `SALA_BGAGENTS_SUBJECT_PREFIX` | empty | the item's subject bracket, e.g. `[hp]`; empty: derived (above) |
| `SALA_BGAGENTS_LIST_CMD`, `_POST_CMD`, `_SPAWN_CMD`, `_ALIVE_CMD` | the stackshot client and this sala | the four other commands (the suites stub them) |

## Running it from a timer

The unit ships in `systemd/` as `sala-bg-agents.timer` (with `sala-bg-agents.service`): it runs `sala bg-agents` five minutes after boot and every ten minutes after its last run, on lane `none`. It was made with `sala job add` (`docs/units.md`), which writes the unit and refuses a taken name; a deploy does not link it, so after the deploy that lands it run `sala job relink sala-bg-agents`. The unit does nothing while `SALA_BGAGENTS` is off, so the timer can be installed first and the switch turned on after.

A timer made by hand earlier with `sala job add` under another name (`sala job list` shows it) would run beside the shipped one: remove it with `sala job remove NAME` (a job of this repo needs `--checkout DIR`, a worktree) before the shipped timer is linked, so two timers do not start two runs; one made under the name `sala-bg-agents` is the one `sala job relink sala-bg-agents` repoints, and is not removed. `sala job relink` only repoints links that exist and reloads; it does not enable a timer. Where there is no link, link both files from `systemd/` into `~/.config/systemd/user` and run `systemctl --user enable --now sala-bg-agents.timer`, as `docs/units.md` does for the other shipped timers. The first run is due at once: `OnBootSec=5min` has long passed on a machine that has been up longer, and a monotonic timer whose time has passed elapses as soon as it is started (`systemd.timer`), so starting the timer (`enable --now`, or the user manager's start at a first login) can start one run, and so one agent, right away when `SALA_BGAGENTS` is `on`.
