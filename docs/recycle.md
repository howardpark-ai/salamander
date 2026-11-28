# Recycling

How a recycle runs: the one driver rule and the recycle lock, the flags and the recycle job, and the panes sala never relaunches.

## One driver
`recycle`, and `update` whenever it would recycle this box, run only through the queue: a recycle
relaunches every pane including the invoking one, and two drivers race the same panes. No pane is exempt, whatever a config
says. **The queue holds the rule** (Thu Oct 15th 2026): a call from a
Claude session — a `claude` process among the caller's ancestors, or a pane that still names itself (`TMUX_PANE`) and runs
one (`claude_caller`) — is refused and pointed to `sala op <verb> … --from NAME --words "<the owner's words>"` (a verb the
queue has no shape for yet — `model`, `adopt`, `restore` — is refused with that said); a human's pane shell, a plain
shell, systemd (the watch and its units), cron and the resurrect boot hook (launched by tmux) pass as before, as do
`sala-test-*` targets, `--dry-run` and `--check`. The **operation queue**'s runner (`sala op`) is admitted: both
guards pass a caller whose cgroup names a `sala-op-<id>` unit (`op_unit_caller`), which is what the queue's one-at-a-time
runner is — the Bash guard hook (`lib/guard.py`) keeps its logic, so a session typing the raw command is denied as before (one
exception: `kill <pid>` of the claude of a throwaway that session started itself, found by the registry's `spawned_by`; it also denies `tmux new-window`, `split-window`, `respawn-pane`, `join-pane`, `move-pane`, `break-pane`, `swap-pane`, `swap-window`, `move-window`, `link-window`, `rename-session` and `new-session -t` aimed at another session on the fleet's server, a `TMUX_PANE` assignment in front of one, and a `=name` target with no colon; `docs/session-registry.md` lists what it does not read),
every deny now pointing to the queue's verb (`sala op update`, `sala op retire <session>`) — except a reboot, which is not
queued: its deny says the owner runs `sala reboot --go` and the session shows them `sala reboot --status` and waits for
their word (`fleet_guard` says the same to a session running `sala reboot`) — with no pane exempt; the queue's own `claude -p` (the stuck handler, in a `sala-op-<id>-stuck` unit) is not
admitted by it.

Underneath the guard, a **recycle lock** (`flock` on `~/.claude/salamander-recycle.lock`) makes one driver a fact: whatever
relaunches panes — `recycle`, `update`'s local leg (before `claude update`), a direct `revive` (`--only`, `--self`), the
resurrect post-restore `revive` — takes it and holds it for the life of the driver it starts (the detached sweep plus the
invoker's self-worker; the fd is inherited, the kernel releases it when the last holder dies, so a lock never goes stale).
A second taker is refused with one line — since when, started by whom, the log — and exit code 75; `--dry-run`, `--check`,
`--save-map`, `--map-history` and the retry worker's re-runs never take it. `watch` skips a run while it is held (its
auto-update too; an auto-update already launched waits for it, up to 10 min, as does the boot hook's revive), `rename --sync`
waits for the next pass. Without `flock(1)` (macOS base system) nothing is locked and the taker says so once.

## Recycle flags and the recycle job
Wed Oct 28th 2026. A **flag** is what calls for a recycle, with the time it was set; the **job** is the run
that relaunches panes. They used to be one record (a set), counted by whichever worker relaunched a pane, so a pane skipped by two
recycles was counted back in only one and the other set stayed open. Now:

- **A flag is a set file** (`$SALA_STATE_DIR/sets/<epoch>-<pid>`): `t0` (the flag's time, the sweep's start), `src` (who raised it:
  `recycle`, `auto`, `update`, `op-recycle`, `revive`, `lane`, `model`, `provision`), `fscope` (`all`, or the one session of a
  `revive --only`, a lane or a model change), the panes it still waits for (`out=`), `hook` and `hookfired`. A flag clears when
  EVERY live pane in its scope has relaunched at least once since `t0`, judged by the pane's `startedAt` in the CLI registry
  (`~/.claude/sessions/<pid>.json`, epoch ms, the process start; a relaunch is a new process). A pane retired or gone does not count
  (N drops); one gone but still in the pane map does; a pane spawned after the flag counts as relaunched; a pane whose start cannot
  be read keeps the flag open and never crashes. The rule runs on every pane relaunch (`set_resolve` → `set_sync`) and on the `watch`
  tick (`sets_tick`), over every open Recycle and Revive set; Provision sets are untouched. Posts keep their shapes: 🔄 progress
  (only for the job's newest flag), ✅ the flag cleared, ⚠️ closed at n/N (a partial clear).
  A post names each pane held back on a line of its own, except that panes held for the same reason are one line with a count once more than
  5 share it (`all N sessions were relaunched 4-16 min ago on <version>: each rests 30 min, then sala relaunches it`); 5 or fewer keep their names.
- **The job is the newest flag's run**: `sets/current.recycle` names it, one retry worker serves it, the deferred list keeps one
  row per pane (repointed at the newest flag). A flag raised while the job is at 30/40 reads 0/40 against the new flag (the 30
  relaunch again), the same job carries on, and the older flag clears by its own condition.
- **The post-recycle hook fires once per cleared flag** (`docs/stackshot-contracts.md`, interface 4): `SALA_RECYCLE_STARTED` and
  `SALA_RECYCLE_FLAG_AT` are both the flag's `t0`; `SALA_RECYCLE_SKIPPED` names the panes the flag did not get back (none for a
  full clear). A pane that never goes idle cannot hold a flag forever: past `SALA_LATER_LIMIT` (3 h) on the deferred list the flag
  is cleared partly and the hook fires with that pane in skipped.
- **A routine flag closes one pane short** (`set_resolve` and `set_report` → `_set_short_pane`, `_set_short_close`). One pane that
  never goes idle (a builder that keeps starting background work) used to hold the whole flag open for hours: its result post,
  the next flag and the panes' rest waited on it. A ROUTINE flag with exactly one pane outstanding, N (its scope's live panes) of at
  least 3 and nothing given up, so N-1 of N relaunched, now closes at once: `✅ *Recycle <label> · 4/5 relaunched · set closed*`,
  with a line `<session> still holds, <why>; sala relaunches it once it is free`. The straggler moves from `out=` to `short=` in the
  set, goes onto the deferred list (the row the retry window's end writes for a pane that stays busy; a row that names it already
  is left as it is), and the hook fires with it as skipped. The retry worker stops trying it (`the flag closed one short` in the
  log), and `watch` relaunches it once it is free and tells it again as for any deferred pane. ROUTINE is `src auto` (the watchdog's
  auto-recycle) and a CLI update the watchdog raised (`routine=1` in the set, from `SALA_FLAG_ROUTINE=1`, which `watch`'s
  auto-relaunch and `update --auto` set). Never one short: a recycle or update from the owner's words (`op-recycle`, `sala op
  update`), a plain `recycle`, revive, lane, model, provision, reboot (they close only when every pane is done); N below 3; a flag
  that has given a pane up (its "closed at n/N" rule is as before, and so is the 3 h limit for a pane on the list); the invoking pane
  (its self-worker relaunches it next); a pane that is only resting after a relaunch (the deferred list applies no rest, the retry
  worker does, so the flag stays open until the rest ends). A pane the retry window already deferred stays as it is: its row is not
  rewritten, and if it is the last one outstanding the flag closes one short at the next settle or `watch` tick.
- **One idea of busy** (the recycle's idle check, the in-session mod and `watch` agree on what holds a pane). The mod refuses an exit
  while a turn runs, and a subagent is one: it is no child process of the claude, no task list of the session may show it, and it can
  write nothing for many minutes. So the idle check also reads the subagents' own transcripts
  (`<projects>/<slug>/<uuid>/subagents/agent-<id>.jsonl`, with a `.meta.json` that says `"finished"` once the subagent ends): one that is
  not finished, was written since this claude started and not longer ago than `SALA_SUBAGENT_STALE` (6 h) **and** that either wrote within the
  last `SALA_SUBAGENT_QUIET` (30 min) or has a process under the pane that it started (a background shell it waits for; `lib/holders.py`
  names the subagent that started a process) is **live**, and a live subagent is running. One that is quiet for longer with no such process stopped without saying so (a subagent
  that crashed or was cut by an interrupt never writes `finished`, and its transcript stays), so it holds nothing: a subagent that last wrote
  four hours before its session's turn ended no longer holds the recycle for the six hours the old rule gave it. A subagent known to have ended
  holds nothing however recently it wrote: the session's own transcript carries a `<task-notification>` for it whose status is `completed`,
  `killed`, `failed` or `stopped` (a killed one never gets `finished`), or its own transcript's last line is an assistant answer that ended its turn.
  The quiet time is the backstop for a subagent with neither sign. Where this reads a live
  subagent as stopped, the in-session mod, which reads the CLI's own task list, still refuses the exit for it: the cost is one refused try. A live subagent holds the pane,
  also one that said `sala ready` (a ready word covers shells and tasks, not a running subagent; what stops one is under *When the pause stops a subagent*, below), and the skip line, the
  relaunch notice and `sala ready` name it and say it ends with its work. The mod's `busy` probe (the gates of an exit with nothing run)
  is asked before an exit is tried, so a turn it names, or the background work it lists, is said once with its holder, and the pane's inbox is not held and released for an
  exit that would be refused. `watch` does the same for the deferred list: one log line when the holder changes, never one per tick, and
  a try that is skipped again starts no retry worker of its own (the list is the retry): a pane the mod holds for background work is not called "free now" and not tried again until the probe says free.
  The skip line names its cause, never only "busy": `registry says 'busy' (a turn is running for 12 min; in flight when its last turn ended: 4 subagents, 6 monitors and 1 shell)`
  (counted from the Stop hook's record, else the subagents the transcripts show), `registry says 'waiting' (a dialog is open: the pane waits for an answer)`,
  `background work is running: 4 subagents, 6 monitors and 1 shell are in flight` (the mod's own list); the retry worker's round lines carry the same text.
- **The drain's own send is not activity**: a sweep sends a pane's queued feedback drafts just before it re-checks and types `/exit`, and the
  `/feedback` panel moves the row's idle stamp. For a pane that was idle before the send and is idle under a new stamp after it, the settle
  (`SALA_IDLE_SETTLE`) is waited out, the Stop hook's record of that idle stretch moves to the new stamp, the terminal-prompt check is made
  again, and the usual idle check decides. The pane is held and retried, its record not moved, when its row turns busy or is stamped again,
  a turn's Stop hook wrote a new record, or something shows work since the send began: a work child process that was not there, a file
  written in the session's task or subagent folders, or a model answer added to the transcript (a turn can end with no Stop hook: an
  interrupt, an API error). This hold applies also to a session that said `ready` and to a paused one.
- **A refusal the mod cannot explain** (a mod loaded before its turn list was reconciled names no holder and does not know the probe): every
  refusal for a turn is counted per session (`refused/<uuid>` under the state directory). After `SALA_STALE_TURN_AFTER` (3) of them, while the
  registry, the Stop hook's record, the child processes and the subagents' transcripts all read the pane as idle, the next try goes by
  keys, logged as such; the CLI's own exit dialog still guards what it lists. Tries after that thin out to one in 10 min, then one in
  30 min, and a session's own `sala ready` is tried at once. The memory goes with the relaunch.
- **A pane on the deferred list is waiting**, whatever its sets say: a set gives a pane up after `SALA_LATER_LIMIT`, the deferred row does
  not, and `sala ready` reads the row (not only a retry worker) when it says whether a relaunch is waiting.
- **Gathering and rest**: a flag raised from the board, a `--when-idle` request or the CLI's auto-update
  while the job is unfinished does not reset it at once. Flags gather until `SALA_RECYCLE_GATHER` (10 min) pass with no new one,
  never more than `SALA_RECYCLE_GATHER_MAX` (30 min) after the first, then the job resets ONCE (one short 🔄 post says it is
  waiting and when it resets). A pane relaunched less than `SALA_RECYCLE_REST` (30 min) ago is not relaunched again for a routine
  flag until its rest ends. `sala op recycle` (the owner's words) skips both waits; revive, lane and model flags are not gated. A
  knob at `0` turns that wait off.
- **Drain mode** (a pane a relaunch waits for starts nothing new): a builder that starts a background subagent or a monitor every few minutes
  never reaches a turn end with nothing in flight, and a recycle waited on it for hours. While a relaunch waits for a session (its flag
  under `waiting/`, the file the waiting line is raised from), the session's **own** turn may not start work that outlives the turn: a
  background subagent (the Agent or Task tool with `run_in_background` true), a Monitor, a Bash call with `run_in_background` true. The PreToolUse hook (`salamander hook pre-tool`, matcher
  `Bash|Agent|Task|Monitor`) **denies** them (never asks) with a reason that says what to do: finish this turn without starting it, leave
  `sala note "<next step>"` for anything that must continue after the relaunch, run `sala ready` as the turn's last call, and that the refusal ends with the
  relaunch, or when the wait ends without one (*The end of a hold*, below), and that the hold itself ends 30 min after the wait began at the latest, even if the relaunch is still to come (*The cap*, below). Everything else stays allowed: foreground work, `sala note`, `sala ready`, TaskStop, Bash without `run_in_background`, a foreground
  subagent. A call made inside a subagent (its hook input carries `agent_id`) is the subagent's own and is never denied. The check allows on any doubt (an
  unreadable input, a session id that is not an id, a failing helper). The waiting line the session is told once (`SALA_RELAUNCH_WAITING_TEXT`) says that a new
  background subagent, monitor or background shell is refused until the relaunch, or until sala tells the session the wait ended without one, and that the
  hold ends 30 min after the wait began at the latest (the words follow `SALA_HOLD_MAX`: `<cap>` in either text, empty with the cap off or for a reboot). `SALA_DRAIN=off` in the config turns it off with no code change (the waiting line
  then asks again instead of saying it is refused); `SALA_DRAIN_DENY_TEXT` is the reason's wording. Each refusal is one line in `~/.claude/salamander-drain.log`: the time, the tool,
  the session and the relaunch's kind, never the call's text. It needs the PreToolUse entry in `settings.json` (`install.sh` says when it is missing); the
  cost with nothing waiting is one glob test. A background subagent whose definition itself says it runs in the background, with no `run_in_background` in the call, is not seen by it.
- **The end of a hold** (a session told to wait is told when the wait is over without a relaunch). A session counts as told once the waiting
  line reached it (the `post-tool` hook, or watch's message to an idle one) or a call of its was refused; `held/<uuid>` under the state
  directory remembers the process. Every ending without a relaunch goes through one function (`hold_ended`, `lib/common.sh`): the flag comes
  down, the pause's clock and marker are cleared (a deferred pane keeps its clock), and that process gets **one** note, handed to its
  messaging socket by `sala note --deliver` (watch, within a tick) and retired at once. A deferred pane's note says new background work is
  allowed now, that sala still relaunches it later, and (except past the cap, where the flag is still up) that a raised flag will say so again; any other ending says the wait ended without a
  relaunch and why. The endings: the retry worker defers the pane, gives it up, finds nothing to relaunch, runs out of its window or stops; a
  sweep leaves the pane with no worker to come back for it; the invoking pane's relaunch fails; a try from the deferred list does not go
  through; watch drops the row (sleeping, `SALA_NO_RELAUNCH`, already current, 8 days); the flag's owner is gone. **No note** while a relaunch is still coming (a newer recycle taking the pane over, a retry worker or watch about to try again
  under a flag that stands) and none after a relaunch that worked. A flag watch raises again for a pane
  still held on the deferred list stands until that row ends; it holds the session only within the cap.
- **The cap** (a hold lasts 30 min at most). `SALA_HOLD_MAX` (**default 1800 s**; `0` or `off` = no cap) counts from the **first** time a
  relaunch raised the session's waiting flag (`holdcap/<uuid>` under the state directory: the flag's own `since` is written again at every
  raise). Past it the refusal is lifted, the session that was told gets the deferred note (new background work is allowed, the relaunch is
  still coming), and **no pause is tried for that relaunch any more**, so no pause stops what the session starts after being told; a running
  pause clock is cleared and the inbox it held comes free. The relaunch itself goes on as before: the flag stays (a turn that ends idle
  still wakes the relauncher), and the retry worker or watch relaunches the pane once it is free. An earlier `sala ready` is cleared (one run
  after the lift counts). The cap applies whoever owns the flag, and to a
  pane that is never paused (a front agent, `SALA_NO_PAUSE`) too. A flag watch raises again for the same relaunch refuses nothing and the
  line it pushes says so; with the default `SALA_LATER_RETELL` (1 h) that is every one of those lines. A **newer** relaunch (a newer
  recycle set) starts a new clock. The pre-tool hook lifts the hold at the first call it would refuse past the cap (that call goes through),
  watch at its next tick; the note is delivered by watch (`sala note --deliver`). While a relaunch of the pane is running (its sweep is about
  to type `/exit`, or its turn was just paused) the hold is not lifted under it, and calls are still refused: that attempt ends the hold
  itself, or the next look lifts it. A reboot's drain is not capped. While the flag is a reboot's, or a reboot or shutdown is under way,
  the cap lifts nothing and watch raises no flag again; a reboot that ends without rebooting leaves a recycle's clock in place.
- **The lane note** (a session that moved lanes is told to start new subagents). A subagent keeps the model id it was started with, so one
  started on one lane and resumed on another falls back to an older model. The SessionStart hook compares
  the lane of the claude it runs under with the lane the conversation last ran on (`lane-ran/<conversation id>` under the state directory)
  and, where they differ, adds one line to the session's context: it moved from one lane to the other, so it starts new subagents and
  resumes none started before. The line carries the time of the start that says it: the CLI adds no `SessionStart` context whose text the
  conversation already holds, so without the time a move made a second time would not be told. sala starts no turn for it: the line goes out with the session's next turn, whatever starts it (a typed
  prompt, a message, a finished background task), and the CLI waits for the hook before that turn's first request. It covers every way a
  conversation comes back (a recycle, a revive, a retry after a resume that failed, the sdk lane's fallback, an unpark, a wake, a resume by
  hand). The record moves once a turn has run (`hook prompt` at its start, `hook stop` at its end); a session closed with no turn kept
  nothing of the line and hears it at the next start, from the lane it last ran on to the one it is then on, and nothing when that is the
  same lane. A `/compact` before that turn hears it again: the compaction's own start says the waiting line, with its own time, because a
  conversation with one earlier turn kept the first one only in the compaction request. A conversation with no record yet gets one from the relaunch that is about to close its claude. All three hooks must be
  registered; a process whose environment cannot be read (macOS) and a headless `claude -p` are told nothing.
- **The pane's claude, and "relaunched".** The pane's claude is the one nearest the pane's own process (that process itself, or the fewest
  parent steps below it), so a claude it started (a nested `claude -p`, a fork before its exec) is never taken for it, whatever its pid (pids
  wrap, so the younger one can be the lower number). Two at the same depth: the one whose process started first, then the lower pid (the only
  tie rule on a system with no `/proc`). Every lookup of a pane's claude reads it this way (`claude_pid_under`). The retry worker and the
  deferred list call a pane relaunched only when the pid they recorded no longer runs.
- **The pause** (a relaunch does not wait for ever for a busy pane;): drain mode cannot help a turn that is already running, and a
  builder whose turn ran 28 minutes with a subagent waiting on a release held a recycle for three hours. A relaunch (a recycle, a revive, a
  lane or model move, a CLI-update recycle: every path through `revive`) takes a busy pane down one way (the decided way, Sat Nov 28th 2026):
  (1) **a stop notice**: the first pass that finds the pane held and pausable writes it ONE one-time note, text `[stop] …` (`pause_stop_notice`,
  handed to its live pid at once by `sala note --deliver`, archived when delivered, retired undelivered once that process is gone), which tells it
  to stop, leave `sala note "<next step>"` and end its turn with `sala ready` as its last call (`SALA_STOP_NOTICE=off` drops the notice only); a session that does so is relaunched at once by the
  ready path, as before; (2) **a wait** of `SALA_PAUSE_AFTER` seconds (**default 60**; `0` or `off` keeps the old wait, unbounded) counted from
  that notice; (3) **the stop**, and **pauses** it: ONE Escape takes the pane out of its turn, and the subagents and background shells that still
  hold the row are stopped by the exit that follows (the CLI's "Exit and stop tasks", confirmed by `exit_wait`; a claude that ignores the `/exit`
  is ended by its own pid, never by name); (4) **the hold**: its stackshot inbox is held from the first pass (below), and `sala note --deliver`
  hands nothing to a paused pid, so a message or notice cannot turn the stopped pane busy again; (5) **the restart**: the relaunch goes on through the ordinary path (drafts drained, `/exit`, resume by the conversation's id; an Escape sent to a busy pane is no longer the only way down: a pane with no turn of its own, a subagent alone keeping the row busy, is paused with no Escape, its marker saying `tasks=1`, and the exit stops the subagent; if a turn has started again by the exit, nothing is typed, the marker goes and the next pass pauses it again), and **a note written for
  the session by the relaunch** (`sala note`'s store; delivered at once after the resume, else at watch's next tick) says what it was doing: the
  time, the last line it was working from, the descriptions of the subagents and tool calls in flight (`lib/pauseinfo.py` reads descriptions
  only, never a command or a tool result; a token is masked), how many processes had run under the pane, and the messages held for it
  (sender and first line). The wait is a clock per conversation (`pause/<id>.wait`): started by the first pass that finds the pane held,
  refreshed by every pass, stopped by a pass that finds it free; a pane last seen held more than `SALA_PAUSE_GAP` (30 min) ago starts again,
  so a pane that is busy on and off is not paused. The recycle's first sweep only starts it; the retry worker wakes for the deadline
  (instead of its next `SALA_RETRY_EVERY` tick) and watch's deferred list does the same for a pane deferred for background work.
  - *Who may be paused* (`SALA_PAUSE_SCOPE`, **default `all`**: every session, front agents included; `background`: only the back agents (the
    registry's role), a front agent keeps waiting for its turn to end; `off`: nobody). *Who never is*: the pane the recycle runs from (and the pane
    that asked for a relaunch, once its worker has it), a pane running a `sala op` of its own, a pane with unsent text or a dialog showing,
    a pane with a client attached that was active in the last `SALA_PAUSE_QUIET` (120 s), and the sessions in `SALA_NO_PAUSE` (work that
    cannot be redone), and every pane whose relaunch has waited past `SALA_HOLD_MAX`. Each waits for idle as before, and the output says why
    it was not paused.
  - *When the pause stops a subagent.* A relaunch always waits for a running subagent to end; only a pause can stop one, and the text `sala` gives
    a session (the relaunch notice, `sala ready`: `subagents_block` in `lib/common.sh`, the one place that works it out) says so only when a pause
    is to come for that pane and relaunch. None comes when `SALA_PAUSE_AFTER` is `0`/`off` or `SALA_PAUSE_SCOPE=off`, when `SALA_PAUSE_AFTER` is at or
    above `SALA_HOLD_MAX`, when the session is outside `SALA_PAUSE_SCOPE`, when the relaunch has waited past `SALA_HOLD_MAX`, or when the session is
    in `SALA_NO_PAUSE`. The callers of the text cannot tell which pane ran the recycle or asked for the relaunch, and the pane's state at that
    moment decides the rest (a person attached within `SALA_PAUSE_QUIET`, unsent text, a dialog open), so it says the pause stops the subagent unless this is the pane the recycle runs from or the pane that asked for the relaunch, a person is at the pane, or the pane holds unsent
    text or a dialog is open (a pane running a `sala op` of its own is not named). With `SALA_STOP_NOTICE=off` a pause still comes, counted from the start of the wait and with no notice.
  - *The interrupt* is one Escape, sent only to a pane whose registry row says busy, that shows no dialog (a second Escape on an idle
    box can open the CLI's rewind menu) and whose own turn is seen running: the CLI's "esc to interrupt" hint below the input box, or,
    for a pane too narrow to show it, the in-session mod naming the main loop. **A busy row alone is no running turn**: it stays busy
    while only a background subagent runs, and an Escape does not stop one. Such a pane gets no Escape; it is paused all the same (marker
    `tasks=1`), and the exit that follows stops the subagent (it is not waited for: one running subagent used to make the relaunch skip the
    pane, a `--force` one included). A turn the Escape ended with subagents still running is handled the same way. Otherwise the pane must be idle in the registry within
    `SALA_PAUSE_IDLE_WAIT` (20 s); if it is not, nothing more is sent, no `/exit` is typed into a pane that is still busy, and the pane
    is waited for as before. **A pause that did not take is
    tried again** (the same when the pane was not idle once interrupted): the clock keeps running, so a turn that ends and starts again
    (a subagent's result starts the next one) does not put the next try a full `SALA_PAUSE_AFTER` away, and `pause/<id>.failed` records the
    failed tries. The next try is `SALA_PAUSE_RETRY` (120 s) after a failed one, for the first `SALA_PAUSE_TRIES` (5) failed tries, then
    `SALA_PAUSE_AFTER` apart; each one is one Escape under the same rule and one log line that says which try it was and when the next
    comes. The tries stop at the cap (*The cap*, above; with the default timings a relaunch has one pause at 1 min and its retries to
    30 min); within it nothing is given up: the pane is tried until it is free, paused or relaunched. **A try whose Escape went in and did not take** (the turn
    still running, or the pane not idle once interrupted: the note says which; a turn the Escape ended with background work still holding the pane is a successful pause, not a failed try) leaves the session ONE note, text `[escape] …`, handed to its live pid at once by watch (not at a
    relaunch, not behind the inbox hold) and archived when delivered, so it is one-time: it says sala sent the Escape, that a tool call
    rejected or shown "interrupted by user" from that moment was sala's and nobody refused it, and that the call may be run again. A later
    try replaces an undelivered one; a pause that takes with an Escape of its own drops it (its `[paused]` note covers the same). **With no
    Escape sent, nothing about one is written**: a failed try leaves no note, and the `[paused]` note of a pane that was already out of its
    turn has no sentence about sala's Escape (an earlier try's undelivered `[escape]` note then stays, and is delivered once the pane is no
    longer paused). Subagents and shells the Escape left in a pane that
    is then out of its turn are stopped the one way a recycle stops them (below: the exit dialog's "Exit and stop tasks"); sala has no
    other way to stop a subagent, and sends nothing to a pane that stays busy beyond the one Escape of each try. Background
    work does not hold a paused pane for `SALA_PAUSE_TTL` (15 min): subagents and background shells end with the relaunch (the CLI's
    "Exit and stop tasks" is confirmed, and the note says so); a release that runs in its own systemd unit goes on. **A paused pane is exited
    by keys**: after the Escape the CLI sits in its interrupted-tool state ("Interrupted · What should Claude do instead?"), where the mod's
    `/exit` is answered ok and then does nothing (the claude stayed up until the 30 s wait ended it by its pid), so the relaunch types `/exit`
    into the box at once and does not ask the mod (the draft check before it still runs; the mod log says "via keys (paused: …)"). Any other
    pane still goes through the mod.
  - *While it waits* (before the deadline) the pane's stackshot inbox is **held** (the hold a sweep takes right before an `/exit`, refreshed by
    every pass), so a new message queues instead of starting a turn; the relaunch releases it, and watch's 10-minute stale drop frees it if
    the relaunch never comes. A pane that is never paused is not held.
  - *Where it shows*: the recycle's row for the pane ends "paused at 13:12, resumes on relaunch"; the closure line of a retried pane says it
    too; `sala op`'s Slack post and the line the asking session hears name each paused session on a line of its own (never counted as a
    failure); `sala recycle --dry-run` says "would wait N min (after a stop notice, unless `SALA_STOP_NOTICE=off`), then stop its turn (one Escape) and its subagents" or why it would not (a `SALA_PAUSE_AFTER` at or
    above `SALA_HOLD_MAX` is one reason: no pause comes before the cap, and no bullet predicts one). **A later relaunch
    never reports an earlier pause**: only the relaunch that paused the pane says so (its row, closure line and posts); a relaunch of the same
    pane within the next 30 minutes that did not pause it (the pane idle and unpaused) says nothing and clears the earlier relaunch's
    `pause/<id>.resumed` marker. `tests/pause.sh` covers it.
  - *The deferred-pane bullet* (a recycle's first post, its "n deferred" post, its 🔄 follow-ups and `sala op`'s result) is made again from the
    pane every time it is posted, so its age is the one of that post (a 🔄 follow-up used to repeat the first post's "busy for 33 min" while the
    log read 39, 46, 57). The age of a busy pane is how long it has **held the relaunch**: the longer of the time since its registry row last
    changed and the pause's clock, which a turn that restarts does not reset. A pane that may be paused says when: `busy for 6 min (sala
    pauses it at 1 min held); sala relaunches it once it is free`, and once that time has passed `(past the 1 min pause point, sala is
    retrying the pause)`. A front agent (scope `background`) is never paused, and no pane is once its hold is past the cap (`SALA_HOLD_MAX`), so
    its bullet says nothing of it; a pane the pause refuses for its own reason (a person at it, a dialog) is not told apart in the bullet; its
    log line says why.
- **Two guards** (the watchdog's auto-recycle, for a board flag and a `--when-idle` request alike; each skip is one line in
  `salamander-watch.log`, `auto-recycle: skipped …`). *The change is not live*: a flag that names its change (`--change REF` on a
  request, `~REF` after a board flag's id) is not served while that change is missing from the production checkout's HEAD, whether
  not merged or merged and not yet deployed. A pull request counts as in when HEAD's history holds its merge commit
  (`Merge pull request #N from …`) or a squash commit ending `(#N)`; a sha, when it is an ancestor of HEAD. `SALA_RECYCLE_REF_REPOS`
  (`name=path` pairs) names the checkouts for `<repo>:REF`; a reference sala cannot check counts as live, and no flag is held
  longer than `SALA_RECYCLE_REF_WAIT` (24 h). *Every pane is newer than the flag*: when every live Claude pane started after the flag was
  raised (and after its change landed, `SALA_RECYCLE_REF_SLACK` for the deploy), a recycle has nothing left to do: a request is dropped,
  a board flag is reported served to the board and nothing is launched. A board flag whose time the board does not give is timed by
  when watch first saw it listed, an upper bound, so a flag is never judged served that was not. Why: a flag raised before the
  change it needed was merged recycled every session, and the recycle after the deploy relaunched them all again.
- **Reconcile**: `sala watch --sets [--dry-run]` applies the rule to the open sets once now (the tick does the same); the first
  pass closes the old-format sets the rule can close, a set older than `SALA_SET_QUIET_AFTER` (48 h) without a post. It never closes
  a flag with a live pane that has not relaunched, and logs what it closed (`sets: …` in `salamander-revive.log`). `--dry-run`
  prints and changes nothing.

## Panes sala never relaunches
`SALA_NO_RELAUNCH="<tmux session> …"` (default empty) names sessions managed outside sala, such as a pane launched by
hand with an environment sala does not know, which sala's launch line would bring back without it (a lane sala knows
is recorded and kept instead: *Lanes* above; `sala lane` refuses such a session by name and leaves it out of `--all`). Every path
that relaunches or restores panes leaves such a session alone and says so (`<session>: not relaunched — SALA_NO_RELAUNCH
(managed outside sala)`): the revive sweep in every mode (recycle, the boot hook, `revive --force`), the recycle driver's
own pane, retry workers, `watch`'s deferred relaunch and auto-relaunch (it is never a stale pane), compare-and-restore at
the end of a recycle or reboot, `restore` and the reboot's boot-half check. `revive --only` and `revive --self` on it
refuse. It is excluded, not pending: never counted in a recycle set, its outstanding panes or the post-recycle hook's
`SALA_RECYCLE_SKIPPED`. `retire`, `rename`, `map` and `spawn --list` keep working on it. Began as a stopgap (
Tue Oct 13th 2026) before lanes were recorded; stays for a pane whose environment is not one of the lanes.

**The web UI's shell session** (`SALA_SHELL_SESSION`, default `sala-shell`; the web app reads the same line from the config file and tells the page the name) is treated the same way without being listed in
`SALA_NO_RELAUNCH`: it is the plain login bash behind the shell drawer in sala-web, which sala-web makes on demand, so it is no Claude
session and no sala verb brings it back. `no_relaunch` is true for it, so revive, restore, the lane move, `watch`'s deferred relaunch
and the reboot leave it alone; the revive sweep drops it without a summary row; `spawn --list`, and the lane lists leave it
out; `adopt` refuses it; and `spawn` and `rename` refuse its name, so a Claude session can never take it (the drawer's keys would
type into it). A refusal that names it says it is sala's own shell session, not that it should come out of `SALA_NO_RELAUNCH`.
sala-web reads the same variable from its own environment (`web/src/sala_web/config.py`), not from sala's config file: if the name is ever changed, set it in both.
sala-web reads `SALA_SHELL_SESSION` once, when it starts, so it must be restarted (`systemctl --user restart sala-web.service`) after that setting changes; it reads `SALA_TZ` on each call (cached by the config file's modification time), so a change there shows without a restart.

**Scopes and the title bar's name** (`SALA_SCOPES`, `SALA_DEFAULT_SCOPE`, `SALA_BRAND_SUFFIX`; none is built in, all are empty by default).
A fleet names its sessions `<scope>-<project>-…`; the scopes are a setting, not a list in the code. `SALA_SCOPES` is
space-separated (`work home`), `SALA_DEFAULT_SCOPE` the scope a page outside every scope's directory is named in (empty: the
first of `SALA_SCOPES`). `spawn --suggest-name` (and the side-session names) build the prefix from them when the project record
does not know the page: `<scope>-<slug>`. The page's directory is tried first (a directory that is one of the scopes gives that
scope), then a slug that already leads with `<scope>-` for a scope other than the default (kept as it is), and otherwise the
default scope goes in front, even of a slug that leads with it; with no scopes set the prefix is the slug alone. sala-web takes
its scopes from `SALA_SCOPES` (and `SALA_DEFAULT_SCOPE`) when that is set and not empty, whatever stackshot says, so a fleet's
sidebar order is its own; only when `SALA_SCOPES` is empty or unset does it read stackshot's own settings file on the box
(`$XDG_CONFIG_HOME/stackshot/stackshot.toml`, `[project_scopes]` `order` and `default`: local data, no request); with neither, the sidebar shows no scope group beyond
"other" and the New session form accepts any scope-shaped name (stackshot is the one that checks it). `/api/config` tells the
page the list (`scopes`, `defaultScope`). `SALA_BRAND_SUFFIX` is what follows "salamander" in the page's title bar
(`salamander : <suffix>`, served as `brand` by `/api/config`; at most 40 characters); empty shows "salamander" alone.
`SALA_HELP_SESSION` names the session the overview's Get Help chip opens (empty: no chip). The web
manifest, the page title and the shipped unit descriptions name no owner, host or domain. sala-web reads `SALA_BRAND_SUFFIX`
on each page load and each `/api/config` call (not cached), and the scopes from `SALA_SCOPES` or the settings files again when
the environment or either file's modification time changes, so a change shows without a restart; the title bar's text is in
the served page itself, so a reload shows no flash of the bare name.

**The owner's name in runtime text** (`SALA_OWNER_NAME`; default `the owner`). The text sala sends to sessions and shows on the
page names the person running the machine: "retired only on the owner's word", `--words "<the owner's words>"`, the
note a side session starts with, the deny a guard prints, the web form's words on a queued spawn. That name is a setting, so a
config line names the owner (`SALA_OWNER_NAME=Name`) and the default reads naturally without one. The setting is exported by `lib/common.sh` to the Python helpers, and sala-web reads it the way it reads
the others (environment first, then the config file as text). The `[for <name>]` line that opens a message to a front agent
carries it too: stackshot builds that marker from its own `[instance] owner` (default `the owner`), so the two settings must be
the same value, or both unset. The text `--help` prints is static and says "the owner". Left literal on purpose: the lowercase
`owner` data tags (the kind tag in provision step lines, and the stackshot mover kind the board client returns; sala no longer reads the
older spelling of either), and the host names inside a few messages.
