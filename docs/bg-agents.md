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

Exit codes: 0 = the run finished (a skip or a failed project too), 1 = a retire is needed or a report (a board item, with `SALA_BGAGENTS_RAISE=ask`) is needed and could not be sent (below), or `--reset` named a key with no entry, 2 = a usage error or a bad setting.

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
   A start that exits 6 (stackshot's project record cannot answer, or stackshot would not register the name; no pane was made) is a failed start at once, with the record's reason in the log, the Slack post and the board item; it is not waited out as a lag. The job reads "is this name on the project" from the record alone, and a record that cannot answer counts the agent as NOT placed and says why.
   **A live session is not yet a start.** The job counts a start only when the session is also placed in its project, read three ways (`read_back` in `lib/bgagents.py`, one function with a plain
   interface: the session name, the project key and the role, `back` here; it answers 0 when all three agree, else 1 with a reason naming each link that does not):
   1. stackshot's project record (stackshot is asked first, through its client; the file copy `SALA_PROJECT_RECORD` is read only when stackshot cannot be reached) lists the name on the project's agents map as a back agent (`front` false);
   2. stackshot's roles list (asked first, through its client, `get roles`; the file copy `roles.json`, `SALA_ROLES_FILE`, `~/.local/state/stackshot/roles.json`, is read only when stackshot cannot be reached) has a live entry for the name that names the project (the page key or its bare slug) and carries the role `back`;
   3. sala's own registry row for the session (`sala sessions resolve NAME --live --json`) is the session's own row (that command also answers a renamed session's old name with the renamed session's row, which places nothing) and carries that project and the role `back`.

   The record and `roles.json` are rewritten about every five minutes and a fresh start is on neither at once, so the three are read again every `SALA_BGAGENTS_PLACE_POLL` (5 s) until
   `SALA_BGAGENTS_PLACE_WAIT` (360 s) is up, and the attempt fails only then. The registry command of each read gets only the time left to that deadline (at least 5 s for the first read and 1 s for a later one, never more than 30 s), so a slow last read does not run past it. A link that cannot answer (missing, stale, unreadable) is a miss, never a pass. A miss is a failed attempt: no start is
   counted, the back-off applies as for any failure, the pane is **left running** (nothing is retired), and the reason says which link disagrees in one plain sentence, for example
   `example-engineer started but the record does not list it on projects/example` (also `roles.json does not list it…`, `sala's row does not list it…`, or `the record could not be read (it is stale…), so it does not confirm it…`).
   It is told **once per attempt**, not once per read: one Slack post through sala's own alert path (`SALA_BGAGENTS_ALERT_CMD`, default `sala alert`; a failed post is one log line and changes nothing) and the
   board item below, raised after the attempt (the ledger's `unplaced` holds the reason, and a live pane does not hold the item back as "agent running, want list stale" would). The next attempt, after
   the back-off or a `--reset`, reads the three again and counts the start once they agree.
8. **The board item**, after the attempt: at most one a run (below).
9. **The log.** One line a decision, on stdout (the unit's journal) and appended to `bgagents.log` beside the ledger: `<time in SALA_TZ> <action> <text>`. No token appears in a line.

## Failures, back-off, the cap

A failure raises the project's back-off: `SALA_BGAGENTS_COOLDOWN` seconds (600), doubled for every further failure, up to `SALA_BGAGENTS_COOLDOWN_MAX` (86400). It counts from the moment of the failure, not from the start of the run: a listing that timed out, a start that ran long or the read-back's wait (up to 360 s) has used none of it. `next_try` is kept
in the ledger and no call is made before it. At `SALA_BGAGENTS_MAX_ATTEMPTS` (5) attempts the project is left alone: one log line a run, no call, and `--status` says "given up (board item raised)" or "given up (board item not raised yet)", and the owner is told once (next section).
Clearing it is the ledger's reset (the project off the list for the cooldown; never while a board item is raised) or `sala bg-agents --reset <project key>` (below, with the board item).

The failures:

| Failure | Why |
|---|---|
| the listing failed or timed out | an HTTP 409 (the name is taken or pending by another sender, or another project's longer prefix) and a 403 (a hidden or non-listed project: a `project-list` post is needed first) are in it; the reason is logged |
| the start failed | `sala spawn` exited non-zero, timed out, or reported the pane up but the session is not live |
| the session is live but not placed in its project | the project record, `roles.json` and sala's registry row do not all place it on the project as a back agent by the read-back's deadline (step 7); the pane is left running, the reason names the link, and the miss is told once by a Slack post and the board item |
| the project is listed again after this job created and retired its agent | the want came back; this is one more attempt on the books |
| the project is still listed after this job started its pane and the cooldown passed | a running agent is **never** retired for it, and no second start is made |

A load skip is not in the table: it takes nothing from the ledger.

## Retiring is a marked step, not done here

When an agent this job listed could not be started, it should come off the project again. Every path sala has for that takes the owner's words for an agent on a project's agents map
(`lib/op.sh`, the words policy: `retire` is for throwaway sessions only, `forget-row` is the owner's), and no door lets a job do it. The job does not invent one. It says
`retire needed: <name>`, exits 1 and keeps `retire_needed` in the ledger. The entry stays on the map, so the next attempt finds it there, does not list it twice and tries the start again;
a start that works clears the mark. The board item below is raised for it in the same run, and from then on nothing is tried until a session resets the record (`--reset`). The job never retires an agent it did not list, an agent after a 409, or a running agent.

## A project it cannot start never stays silent: a report to sala's builder session

A start that fails is a fault in the job or in its setup, not a decision of the owner, so the job does **not** put it to the owner. When a project reaches the attempt cap ("given up"), **or** the
ledger sets `retire_needed` (an agent this job listed whose pane did not start), **or** a started session is not placed on its project (`unplaced`, step 7), the job **reports** it, once per
project, to sala's builder session: one message through stackshot's client (`client.py message <session> - --sender sala-bg-agents`, the text on stdin). The session is `SALA_BGAGENTS_REPORT_TO`
(set it to the name of sala's builder session in the fleet: the repository names none, so unset the report cannot be sent and the run says `report needed`), the command `SALA_BGAGENTS_REPORT_CMD`. What it reads, from a test:

```
alpha-main-builder (the session named by SALA_BGAGENTS_REPORT_TO)
text     bg-agents could not give projects/example its background agent: its attempts reached the maximum and the job has stopped trying.
         Agent: example-engineer. Attempts: 5 of 5 (failures: 5).
         Last error: listing example-engineer failed: HTTP 403: refused: sender 'sala-web' is a name, and a name proves nothing. Send the asking session's id: ...
         This is a fault in the job or its setup, not a decision of the owner. Fix the cause, then run `sala bg-agents --reset projects/example` so the next run tries the project afresh; until then the job leaves it alone.
         Report id: bgagents-projects-example-1800000000-1a2b3c4d
```

**The last real error, never a guessed cause.** The text carries the words the failed step gave (the post's HTTP status and stackshot's own message, the start's exit and its last line, the read-back's
reason), kept in the ledger as `last_error`, on one line and cut to 300 characters; a ledger entry written before `last_error` existed gives its last outcome (`last`) instead. No sentence in the report
or in `last_plain` names a cause the job did not see. When the liveness check could not say whether the agent's session is up, the report says only that the start did not finish.

**Once per project.** The ledger records `raised` (that the report went out), `raised_at`, `raised_item` (the session it went to) and `raise_token` (the id a retry reuses, which the text carries as "Report id"),
and a later run that finds the project still stuck sends nothing; once reported, the job makes no start attempt for the project (`reported to <session>; left alone until a session resets the project's record`) until a
session runs `sala bg-agents --reset <key>`, which clears all of it (attempts, failures, back-off, the report, the last error) so the next run tries afresh, and a new give-up is reported again with a new id.
`--status` says "given up (report sent)" or "(report not sent yet)". A report that fails (no client, the client refuses or does not answer in time) says `report needed: <project> (could not be sent: <reason>)`,
exits 1, and is tried again after the project's own back-off with the same report id; the client's `message` verb has no request id of its own, so a report that was delivered although its answer was lost can arrive twice,
and the shared id shows it is the same report. `--dry-run` sends nothing: it says `would report to <session>`. No subject prefix is read and no question is filed.

### The old route: `SALA_BGAGENTS_RAISE=ask`

With `SALA_BGAGENTS_RAISE=ask` (the default is `report`) the job raises ONE board item for the owner instead, as before the report existed, and the rest of this section describes that route. Everything in it that
does not belong to the question itself (once per project, the request id, the lock, the liveness checks, the back-off of a failed filing, `--reset`) holds for the report too, which takes the item's place.

When a project reaches the attempt cap ("given up"), **or** the ledger sets `retire_needed` (an agent this job listed whose pane did not start), **or** a started session is not placed on its project (`unplaced`, step 7), the job raises ONE board item for the owner
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
         - The last problem: The agent's session could not be started. The error it gave: the start of example-engineer failed (exit 1: ...)
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

The words are everyday ones: no command is in the item. The last problem is the failure in one plain sentence (`last_plain`, which says what happened and never a guessed cause), followed by the
real error the attempts gave, cut to 160 characters (`last_error`; `last` stays in the log and in `--status`). When the agent is listed but its pane never started, a line says the agent is still on the project and that the job may not take it off
without the owner's word (the marked step above). One item covers both reasons.

The raise is not an attempt: it does not take the run's one attempt, it is no failure of the project, and it touches neither the attempt count nor the back-off. **Starts come first and
the raise is bounded.** It is made after the run's start attempt (so a project the attempt has just taken to the cap or to a retire step is raised in the same run), for **at most one**
project a run (the first that is due for a raise, in key order, the least recently checked first; any other outstanding project waits for the next run, and the run says how many wait). Each of its two calls (the instance's prefixes, the question) has its
own timeout, `SALA_BGAGENTS_RAISE_TIMEOUT` (30 s), not the listing's `SALA_BGAGENTS_POST_TIMEOUT`. The ledger lock is **not held across the network calls**: the run keeps the request id in the
ledger under the lock, gives the lock up for the calls, takes it again and writes the result to the entry as it is on disk then. So a slow or down stackshot delays no start and does not block
`--reset`; and a `--reset` that ran during the call wins: the entry it cleared is not written over, and the run says the record was reset while the item was filed (an item filed in that moment
stays on the board; the owner's answer is the same "keep trying").

**A project whose item is being filed is left alone.** Under the lock, before it is given up, the run marks the entry `raising_at` with the clock **when filing begins** (not the run's start: the liveness checks and the
start before it can take minutes, and a mark taken from the run's start would already be old) and `raising_by`, a token of this filing attempt. Any other run that starts
meanwhile skips the entry, for the start and for the raise alike (`another run is filing its board item`; `--status`: "a board item is being filed"), until the mark is older than twice the raise
timeout and the wait for the lock (75 s with the default timeout): then the run that set it is taken as dead. When the first run returns, it writes the item only if the entry on disk still
carries its request id, is still marked with ITS filing token and the project is still stuck (a retry, which reuses the request id so a repeat files nothing twice, takes the mark over with its own token:
the first run's late result, a success or a failure, is then set aside, so it neither clears the retry's mark nor changes its back-off; the board answers both with the same item): a start that worked meanwhile is not told to the owner as a failure (the run says the project is no longer stuck and records nothing: not the item, and not a failure either, so a filing that FAILED
for a project another run has started since counts no failure, sets no back-off and says no "board item needed"; an item the board did file stays on the board). Only a project on the want list, or one whose listed agent has not been started, or one whose started pane is not placed on its project (it was on the map already, so no listing was made; its filing and its next attempt go on after it left the list), is asked about; any other stuck project that has
left the list is not.

**An agent that is running is no start failure.** A project can reach the cap because it stays on the want list while its agent's session is live (the start failed late, or the pane was
started by hand). Before raising, the job asks the same liveness command the start uses (`SALA_BGAGENTS_ALIVE_CMD`, exit 0 live, 1 not). When the session is live, nothing is raised: the ledger
records `stale` and `last` = `agent running, want list stale`, the log line says so, `--status` shows it, and the project makes no new attempt while its pane is alive; once the pane is gone it is
looked at as any other project (stale cleared, raised if stuck). When the check cannot say (no command, a timeout, an ambiguous name, any exit but 0 and 1) a project that was not marked stale is raised for, saying only
what is known: its subject, text and stakes read "the start did not finish" instead of "failed N times" and "no background agent". **Only a confirmed exit 1 (not live) lets a running project back into the start
path:** a project that is stale, or whose pane was started (`started_at`, also when it is given up), and whose check cannot say is left exactly as it is (stale stays set, no start attempt, no board item) and the log line says the check could not be told.

**The liveness checks are made without the ledger lock, and a few a run.** A check may take 30 s. The run collects the names it needs to check, saves the ledger, gives the lock up, asks, takes the lock again
and reads the ledger again from disk before it applies the answers, so a `--reset` or another run is never blocked by a check nor written over. `SALA_BGAGENTS_MAX_PROBES` (3) caps the checks of the two probe windows, which are
the ones made without the lock: the start phase uses up to one less than the cap (two by default), the raise phase the rest, counting every answer the start phase took (also one dropped later, see below), so the
two windows never make more than the cap together; the least recently checked project goes first (`probed_at`), so a few live projects never starve the others; a project whose check did not fit waits for the next run
(nothing is attempted or raised for it meanwhile, and the log line says so). **Not counted against the cap:** the run's own check of the start it attempts (a run makes at most one attempt). It is made with the lock held,
as the attempt is: one check after a spawn that exited non-zero, and after a spawn that reported the pane up a check every two seconds or so until the session is live or `SALA_BGAGENTS_ALIVE_WAIT` (30 s) has passed. So a run that
attempts a start can make more liveness calls than the cap, never more than the cap outside the lock plus that one agent's own checks. A name checked in the start phase is not checked again for the raise, unless this run then attempted a start of that
agent: the answer given before the attempt is dropped (the pane may be up now even when the start reported a failure), so the raise phase asks again, or, with no check left in the cap, leaves the project for the next run.
An answer is only good for the entries it was given for: after the lock is taken again, an answer whose project changed meanwhile (another run started or retried it) is dropped, and the log line says the
project was overtaken by another run, so a cached "not live" never starts an agent another run has just started. With no liveness command nothing is asked (every answer is "cannot say"), but the names considered still
advance `probed_at`, so the first projects do not take the check slots every run and defer the board items of the later ones.

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
`attempts`, `failures`, `next_try`, `created` (this job listed the agent), `posted_at`, `started_at`, `retired`, `retire_needed`, `awaiting_record`, `last` and `last_at`, `last_plain`, `absent_since`, `stale` (agent running, want list stale), `unplaced` (the reason a live session was not counted as a start, empty otherwise), and for the board item `raised`, `raised_at`, `raised_item` and `raise_token` (the request id), and `last_error` (the last real error of the attempts, cleared by a start that works and by `--reset`). An attempt
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
| `SALA_BGAGENTS_PLACE_WAIT`, `_PLACE_POLL` | 360, 5 | seconds the read-back of a started session (step 7) keeps reading the project record, `roles.json` and the registry row before it fails the attempt, and the pause between two reads (the record is rewritten about every five minutes) |
| `SALA_ROLES_FILE`, `SALA_ROLES_FILE_MAX_AGE` | `~/.local/state/stackshot/roles.json`, 1800 | the file copy of the roles list, read only when stackshot cannot be reached, and the age in seconds after which that copy answers nothing (a copy's age is said in the reason and in `salamander-record.log`). `SALA_PROJECT_RECORD` and `SALA_PROJECT_RECORD_MAX_AGE` do the same for the project record; `SALA_RECORD_LIVE` (`off` reads the copies alone), `SALA_RECORD_LIVE_TTL` (20 s a stackshot answer is kept) and `SALA_RECORD_LIVE_TIMEOUT` (15 s an ask may take) set the ask |
| `SALA_BGAGENTS_ALERT_CMD` | `sala alert` | the Slack post of a started session that is not placed in its project, called with the headline and one line appended; empty: no post, one log line |
| `SALA_BGAGENTS_RAISE_TIMEOUT` | 30 | seconds each call of the report (of the board item's two calls, with `ask`) may take (one a run, after the start, without the ledger lock) |
| `SALA_BGAGENTS_MAX_PROBES` | 3 | the most liveness checks the two probe windows of a run make (at least 2; made without the ledger lock; the check of the run's own start attempt is not counted) |
| `SALA_BGAGENTS_RAISE` | `report` | what a project the job cannot start is reported as: `report` (a message to sala's builder session, the default) or `ask` (one decision item for the owner, the old route, below); anything else is refused (exit 2) |
| `SALA_BGAGENTS_REPORT_TO` | empty | the session the report goes to (a session's name: sala's builder session); empty: no report can be sent, `report needed` and exit 1 (tried again at the next run) |
| `SALA_BGAGENTS_REPORT_CMD` | `client.py message` | the sending command, called with `<session> - --sender sala-bg-agents` appended, the text on stdin; empty: no client, `report needed` and exit 1 |
| `SALA_BGAGENTS_ASK_CMD` | `client.py post question` | with `SALA_BGAGENTS_RAISE=ask`, the board-item command; empty: no client, `board item needed` and exit 1 |
| `SALA_BGAGENTS_PREFIXES_CMD` | `client.py get config` | reads the instance's subject prefixes |
| `SALA_BGAGENTS_SUBJECT_PREFIX` | empty | the item's subject bracket, e.g. `[hp]`; empty: derived (above) |
| `SALA_BGAGENTS_LIST_CMD`, `_POST_CMD`, `_SPAWN_CMD`, `_ALIVE_CMD` | the stackshot client and this sala | the four other commands (the suites stub them) |

## Running it from a timer

The unit ships in `systemd/` as `sala-bg-agents.timer` (with `sala-bg-agents.service`): it runs `sala bg-agents` five minutes after boot and every ten minutes after its last run, on lane `none`. It was made with `sala job add` (`docs/units.md`), which writes the unit and refuses a taken name; a deploy does not link it, so after the deploy that lands it run `sala job relink sala-bg-agents`. The unit does nothing while `SALA_BGAGENTS` is off, so the timer can be installed first and the switch turned on after.

A timer made by hand earlier with `sala job add` under another name (`sala job list` shows it) would run beside the shipped one: remove it with `sala job remove NAME` (a job of this repo needs `--checkout DIR`, a worktree) before the shipped timer is linked, so two timers do not start two runs; one made under the name `sala-bg-agents` is the one `sala job relink sala-bg-agents` repoints, and is not removed. `sala job relink` only repoints links that exist and reloads; it does not enable a timer. Where there is no link, link both files from `systemd/` into `~/.config/systemd/user` and run `systemctl --user enable --now sala-bg-agents.timer`, as `docs/units.md` does for the other shipped timers. The first run is due at once: `OnBootSec=5min` has long passed on a machine that has been up longer, and a monotonic timer whose time has passed elapses as soon as it is started (`systemd.timer`), so starting the timer (`enable --now`, or the user manager's start at a first login) can start one run, and so one agent, right away when `SALA_BGAGENTS` is `on`.
