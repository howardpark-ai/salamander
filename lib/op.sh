# lib/op.sh — the operation queue: fleet operations run by sala's watch with no model, and a one-off `claude -p` only
# when one of them is stuck (the queue needs no master session). Built beside the master path; since Thu Oct 15th
# the master is optional: while SALA_MASTER names one, `sala cue` still hands words to it and it still runs the verbs
# itself; with none, `sala cue` points here, the guards (common.sh, master_guard) send a Claude session here, and `watch`
# keeps no master alive (it still revives any mapped pane whose claude died, lib/barepane.sh). RETIRING THE MASTER is one operation of this queue: `sala op retire <the master>` — its plan says
# "would unset SALA_MASTER, then retire", and the runner (op_run) runs `salamander master --unset` first and the retire
# after it, so the watchdog never heals the pane the retire takes down; a retire that fails after the unset leaves
# SALA_MASTER unset (said on the marker, in the post and in the hearer's line) and the operation stuck.
#
# THE USAGE: `op --help` (op_usage) prints from its first `salamander op` line through the `watch --ops` line, so keep it contiguous.
#   salamander op <verb> [args…] --from NAME --words "<the owner's words>" queue one operation (the verbs below)
#   salamander op <verb> [args…] --from NAME --stdin                      the words on stdin (a pane on another box, over ssh)
#   salamander op retire NAME --from YOU                                  NO words: only for a throwaway (tagged at spawn: any session; untagged: its spawner, the master or anyone, a throwaway's name; never a bypass flag, --keep-web or --id)
#   salamander op revive --only NAME… --item board#N --from YOU           NO words: a reason on the record instead (--why "<one line>" for --item; --force allowed): one or more live Claude sessions, never the master or YOU, never a sweep, --rescue or --lane-default
#   salamander op --plan <verb> [args…]                                   the plan alone: the verb's dry run, nothing queued
#   salamander op --list                                                  the queue (and what it is doing)
#   salamander op --status <id>                                           one operation's record, queued or archived
#   salamander op --cancel <id>                                           drop a queued one (a running one cannot be dropped)
#   salamander op --run <id> · --settle <id> <set> · --stuck <id>         (internal) the unit's runner; the waiter for a set; the stuck handler
#   salamander watch --ops                                                (lib/watch.sh) the queue alone, what `op` kicks
#
# THE VERBS, each a fixed shape (never a shell string), checked against this table before anything is written:
#   recycle [--update] [--force]              "recycle claude" = recycle --update --force
#   update [HOST…|--fleet]                    this box (= recycle --update --force), named fleet hosts, or the fleet then this box
#   revive [--only NAME]… [--force] [--item board#N | --why TEXT]    bring a session back (--only), or every pane on an older CLI; with --only NAME… and a reason (--item or --why) it needs no words (THE WORDS POLICY)
#   retire NAME|--id ID [--keep-web] [--busy] [--skip-writeup] [--self] [--leave-items]
#   close-shell NAME [--busy]
#   forget-row NAME
#   rename OLD NEW                            the asking session may name itself: the runner is outside every pane (no TMUX_PANE), so it types /rename NEW
#                                             into OLD once the pane is idle, right after the asker's turn ends (a busy one: tried again every minute for 2 h)
#   lane <lane> <session>… | <lane> --all | default <lane> | fallback <lane>
#                                             fallback <lane> (the automatic lane fallback): the dormant <lane>'s sessions, its default and (at run time) its jobs
#                                             move to its fallback lane, ONE operation and ONE notice with a line per session (RESULT lines of lib/lane.sh, kept as
#                                             `detail=` lines like the model batch); queued by the watch itself the moment a lane turns dormant (`--from sala-watch`, the
#                                             words the standing words of the fallback), or by a person. Nothing moves back (lib/lane.sh, THE LANE FALLBACK)
#   model <model> [--effort <level>] <session>… | --clear <session>… | <session> <model> [--effort <level>] | <session> --clear
#                                             THE BATCH (a batch of model changes should not wake a
#                                             front agent once per session): `model <model> [--effort <level>] <session>…` is ONE
#                                             operation for all the sessions named, and it ends in ONE result notice with a line per
#                                             session (RESULT lines of lib/model.sh, THE BATCH: op_run keeps them as `detail=` lines on
#                                             the marker; the notice and the Slack post count the sessions that went through and name
#                                             only the failed or skipped ones, with their reason: op_finish, THE MANY-SESSION POST).
#                                             Which shape: a first word that is a model (opus · sonnet · haiku · fable · claude-…) is
#                                             the batch; any other first word is the session of the single-session shape below, which
#                                             is unchanged (model_batch_shape, common.sh, has the two corner cases). All the sessions
#                                             are checked before anything is queued (the plan is `model … --dry-run` for the lot): one
#                                             unknown session refuses the whole operation. `--clear <session>…` drops several records.
#                                             A batch with a failed session ends `stuck` (the summary names them, the others stand done),
#                                             without the one-off claude -p: each failure is already one session's own, named in the notice.
#                                             The single-session shape, as it was:
#                                             the model and effort a session is relaunched on (lib/model.sh: a verb to change the model / effort of an agent, its
#                                             own session included). <model>: a family alias (opus · sonnet · haiku · fable) or a
#                                             `claude-…` id, checked here with model.sh's own model_valid and effort_known; the session
#                                             must exist (the plan is `model … --dry-run`). --clear drops the record (the transcript
#                                             decides again at the next relaunch; nothing relaunched). model.sh's --record-only,
#                                             --not-master and --dry-run are not queue arguments. Switched in place first:
#                                             a pane that is idle with an empty input box is switched IN PLACE (/model and
#                                             /effort typed into it, the saved defaults in the lane's settings.json put back), its
#                                             conversation process kept; any other pane, and any failure, is relaunched. The asking
#                                             session may name itself: the runner is the sala-op unit, outside every pane (no TMUX_PANE),
#                                             so once the asker's turn has ended it is switched in place like any idle pane, else
#                                             model.sh relaunches it through `revive --force --only` (a busy one is handed to the retry
#                                             worker and relaunched once idle); `op` tells the hearer so when it is the target.
#   provision [--only STEP[,STEP…]] [HOST…]
#   spawn NAME --project <page key> --role front|back [--mandate FILE|TEXT] [--lane L] [--model M] [--effort E] [--cwd DIR] [--no-confirm]
#                                             a project agent's session (lib/spawn.sh): the one path a web request
#                                             takes. Checked here before anything is written: the name (sala's rule: lowercase,
#                                             digits, dashes, ≤48), the page key's shape, the role, a mandate for a back agent, the
#                                             lane; the plan is `spawn … --dry-run`, which asks stackshot's pages.py whether the
#                                             page exists and lists the name — a name not on the page refuses the operation with
#                                             exit 3 and the `ADD-TO-PAGE:` block printed unindented after the refusal (exit 4 and
#                                             `NO-PAGE:` for a page that does not exist), so the web layer can show the line to add.
#                                             THE MANDATE'S TRANSPORT: a TEXT mandate (--mandate or --prompt) is written at queue
#                                             time to $SALA_STATE_DIR/mandates/<id>-<name>.md and the marker carries that path as
#                                             the argument (an arg= line holds one line; a mandate's newlines, quotes, non-ASCII text
#                                             and a leading dash all survive as bytes in the file); a readable FILE given is
#                                             passed as it is. The file is never moved with the marker: the session reads it at
#                                             its first prompt, after the operation has ended. A refused or cancelled operation's
#                                             file is removed. At run time a spawn that exits 3 or 4 is stuck with no claude -p
#                                             (only the page's keeper can add the line).
#   spawn NAME --side (--fork-of AGENT | --project <page key> --item board#N) [--item board#N] [--agents A,B] [--mandate FILE|TEXT] [--lane L] [--model M] [--effort E] [--cwd DIR] [--no-confirm]
#                                             a side conversation (lib/spawn.sh A SIDE SESSION, docs/side-sessions.md): a
#                                             short-lived session on no page's agents map, a fork of a running agent's conversation
#                                             (--fork-of) or a fresh one about a board item (--project --item, --agents the item's
#                                             involved agents, passed in by the caller). Checked here before anything is written: the
#                                             name (an agent name containing -side-), exactly one of --fork-of and --project, the item's
#                                             shape (board#N), the agents' shape, no --role; the plan is `spawn … --dry-run`, which
#                                             finds the agent to fork and the project's page. No quiet watch, no auto-retire, no cap: it
#                                             retires only on the owner's word, through `retire`, which refuses it until `sala side done`
#                                             wrote its marker (--skip-writeup the one bypass; lib/retire.sh).
#   reboot                                    not queued: the owner runs `sala reboot --go` directly, in the web UI's Shell. The verb's
#                                             shape and code path stay, behind SALA_OP_REBOOT (off by default, and unsupported
#                                             until a confirmation path is built); while it is off, `op reboot` is refused.
#
# THE MARKER: one file per operation under $SALA_STATE_DIR/ops/<id>.op (<id> = <epoch>-<pid>), key=value lines: id, time, from
# (who heard the owner), words (the owner's words verbatim, one line), verb, one `arg=` line per argument in order, state (queued ·
# running · waiting · done · stuck · absorbed · cancelled); the tick adds unit, started, boot, par and keys when it starts one; the runner adds pid, set, waiter, helper,
# absorbed (one per operation folded in), ended, result. An ended marker moves to ops/done/ and is never deleted here.
# A marker with no words is refused, except one sala writes itself (--auto, refused under a Claude process): a session
# queues only what the owner said, with the owner's words on the marker, and a relayed message is never the owner's words. Which verbs may go without them is THE WORDS POLICY (below, op_words_policy); the two doors are THE THROWAWAY DOOR here and THE REASON DOOR there. THE THROWAWAY DOOR
# (a session ends its own: the session that started a throwaway may end it with no words, and retiring a throwaway must
# never need the owner): `retire NAME --from YOU` with no words is queued when NAME is a THROWAWAY (op_own_target_ok:
# a live registry row of exactly that name, no project, no role, not a side session, not named on a project's agents map, not the master, not YOU)
# and YOU may end it: its spawner (spawned_by = YOU); the master session, when NAME is a throwaway's name (scratch-*, *-check-*, *-test-*, *-probe-*)
# or the master started it; or any session when NAME has no spawner on its row or the spawner is no longer a live session (a renamed spawner counts
# as not live), AND NAME is a throwaway's name (the name alone is never enough, it only opens that door).
# THE THROWAWAY TAG (a throwaway carries a tag set at spawn, and any session may retire a tagged one at any time between
# turns): a bare `sala spawn` writes throwaway=1 onto the row (lib/spawn.sh; lib/sessions.py clears it when the row gets a project, role or side
# mark), and ANY live session (not the row's own, not the master) may then end that row with no words, whoever started it, whether or not the spawner
# is live, whatever the name; the name pattern and the spawner-gone condition no longer apply to a tagged row. Between turns is retire's own idle
# check (is_idle_reason: the registry's busy record, else the pane guesses): the plan (`retire NAME --dry-run`) refuses a pane mid-turn before anything is
# queued, and the runner's `salamander retire` refuses one that became busy since; a no-words retire carries no --busy, so a busy tagged throwaway ends
# stuck with nothing ended, and the asker queues it again once idle. A tag opens only the door: the project,
# role, side, master, self and agents-map refusals all still apply to a tagged row. A row WITHOUT the tag (made before it) keeps the earlier rules
# above, spawner / master / any session with no live spawner and a throwaway's name, so nothing live loses the path it has. The agents-map check
# FAILS CLOSED for the tag, master and any-session doors: the project record (stackshot's projects.json, fresh within SALA_PROJECT_RECORD_MAX_AGE) must say NAME is on no project's
# agents map, else pages.py agent-listed is asked, and when neither can answer the retire is refused (only the spawner door goes on without an answer:
# its row is the proof). NO bypass flag (--busy, --skip-writeup, --self, --leave-items, the old --force), NO --keep-web and NO --id with no words (they are retire's bypasses, and a bypass takes the owner's words): refused at queue time and again by the
# runner. The CALLER is placed by process ancestry, not by TMUX_PANE or --from, which a caller can set to anything: the tmux session whose
# pane holds this call, with a Claude Code process on the way up (comm claude AND an exe under the account's Claude install folder, never the
# name alone), must be YOU, and a call with no such pane (a plain shell, a detached or orphaned job, a symlink to bash named claude) is refused,
# a human in a plain shell passing --words. The target is bound to its row by the process: EVERY process in every pane of NAME must carry the row's
# id as SALA_SESSION_ID, or ALL carry none (a pane from before ids, or a row with no id) and a trusted Claude Code process is among them, AND then
# the name must be a throwaway's and a fresh answer must say it is on no agents map, whichever door let YOU in (nothing but the name binds such a pane,
# so a session renamed onto a dead throwaway's name is not it); the marker stores the row id (ownrow=) and op_run checks all of it again before it
# ends anything, going stuck on a mismatch, at once and with no claude -p helper: the helper's tools include salamander retire, which has none
# of these checks; a process that exits between the listing and the read of its environment is skipped). The marker then carries nowords=words: none
# (throwaway, <rule>) in place of the words, and the log, the Slack post and the hearer's line say so. Every other case keeps the refusal. A second operation
# of ANOTHER verb naming a session already queued, running or waiting is refused (two drivers on one pane); two of one verb
# are not (two recycles fold, a second retire finds the first's result) — except two spawns of one name, refused too, since
# the first makes the session and the second can only fail on it (op_conflict_with).
#
# THE WORDS POLICY (op_words_policy VERB ARGS… → OP_POLICY, the one place that says what a marker with NO words needs; op_main asks it when the call carries no --words,
# and op_run asks it again before it runs a marker that has none). THE PRINCIPLE: words only where the call is truly the owner's, i.e. it loses work, costs money or changes
# what the owner sees; a step that restores or retries is the system's own and needs only a reason on the record. Three policies:
#   owner       the owner's words, verbatim, on the marker; with none the call is refused (the generic "no --words" refusal). Every verb but the two below.
#   throwaway   retire: the door above (op_own_retire_ok): a throwaway ends with no words, nothing else does.
#   reason      revive: THE REASON DOOR below.
#   verb         policy      why
#   recycle      owner       relaunches every pane (interrupts every session's turn; --update also changes the CLI the owner sees)
#   update       owner       changes the CLI on boxes (what the owner sees), then relaunches the panes
#   revive       reason      with --only NAME…: it restores or retries a session, and revive's own idle guard (/exit only after 10 s idle, no child process, no recent task
#                            output) cannot lose a working pane; with no --only (a sweep of every pane) it is a recycle's relaunch: owner
#   retire       throwaway   ends a session for good: a throwaway holds nothing of the owner's; any other session may hold work, so it takes the owner's words
#   close-shell  owner       ends a tmux shell that may be running a command of the owner's
#   forget-row   owner       drops a pane-map row (a record the owner may still want)
#   rename       owner       changes the names the owner sees (board, links, Slack)
#   lane         owner       moves sessions between plans (limits and cost)
#   model        owner       changes what a session costs and how it works
#   provision    owner       changes a machine's configuration
#   spawn        owner       starts a session (cost, and a new name the owner sees)
#   reboot       owner       not queued at all (the owner runs `sala reboot --go` directly)
# A new verb is `owner` until a line here says otherwise; a verb moves to `reason` or `throwaway` only with the principle above and its own re-check in op_run.
# THE REASON DOOR (a session revives sessions with no words): `revive --only NAME [--only NAME]… [--force] (--item board#N | --why "<reason>") --from YOU`, queued when ALL hold:
#   1. the arguments are one or more `--only NAME` and at most `--force`, nothing else: no sweep (no --only), no --rescue, no --lane-default, no other flag (--force is allowed:
#      without it revive skips a pane already on the current CLI, and a session alive but not working needs it);
#   2. the reason is `--item board#N` (the format only: stackshot has no item lookup the client could ask, so whether the item exists or names this session is NOT checked; a
#      deliberate limit) or `--why "<text>"` (one line, three words or more, at most 200 characters), one of the two, never both, never with a verb other than revive;
#   3. YOU (--from) is the session whose pane holds this call by PROCESS ANCESTRY (op_caller_is, the helper retire's door uses: a Claude Code exe under the account's
#      install folder on the way up to a pane, never TMUX_PANE or --from), and, while SALA_OP_REASON_FROM names sessions, one of them (empty, the default: any live Claude session);
#      a plain shell, a detached job and --auto are refused (a human in a plain shell passes --words);
#   4. every NAME is a live Claude session of the registry under exactly that name, not the master and not YOU (a session's own revive and the master's stay the owner's).
# The marker then carries `item=` or `reason=` (not why=: that key is the stuck handler's), one `ownrow=` per NAME (the registry row ids, in the order of the --only), and
# `nowords=words: none (board#N: revive of one session)` / `words: none (reason: …)`; the log, the Slack post, the hearer's line and `op --list`/`--status` show it. With --words,
# --item/--why are only recorded. op_run asks again before it relaunches anything (op_reason_run_ok): the marker's reason, only --only and --force, a row id per name, the sender still
# allowed, every row still the live one it was queued for, neither master nor sender; a mismatch is stuck at once with nothing run and no claude -p helper (as for retire).
#
# THE PLAN comes first: `op` runs the verb's own dry run (retire --dry-run, rename --dry-run, lane --dry-run, revive --dry-run
# for a recycle's sweep and a revive) and prints it to the hearer; a dry run that refuses — no such session, an ambiguous
# name (retire's rule), a pane that is not idle — refuses the operation before anything is queued. update and provision
# check their hosts against SALA_FLEET_HOSTS and this box (no ssh at this point: a sleeping laptop is not a wrong target);
# reboot prints `reboot --status` (its --dry-run is the full acceptance test, which pauses and drains). Then the marker,
# then sala-watch.service is started (`systemctl --user start --no-block`), so the operation begins within seconds and not
# at the timer's next tick; a tick already running gets a one-off `watch --ops` 10 s later (systemd-run --on-active).
# When an operation ends (op_finish, or its runner's exit, whatever state it leaves) and another is still queued, one
# `watch --ops` follows SALA_OP_KICK_END (5) s later as the unit sala-op-kick-end (a second request while it is pending is
# refused by systemd; an empty queue schedules nothing), so a burst runs back to back and not one operation per 2-min tick.
#
# THE DRIVER AND THE PARALLEL RULE: `watch` (op_tick, under the
# queue's own flock) starts each operation as its own transient unit sala-op-<id> (KillMode=process: the relaunch's detached
# driver outlives the unit's main process, as AUTO-RECYCLE's does), the oldest queued first. WHAT RUNS BESIDE WHAT is declared by
# each verb in its own branch of op_shape, never by a check beside it: OP_PAR=solo (the default: a verb that says nothing, and
# any marker the table cannot parse, runs ALONE) or OP_PAR=par with OP_KEYS, the session names the verb touches (OP_TARGETS when
# it sets none). Today par are spawn, retire and rename, and only where every name is a tmux session name the tick can compare
# as it stands: a retire by --id (the conversation id is resolved at run time), a retire of the master (SALA_MASTER
# is unset first: a config write) and a rename of the master are solo. recycle, update, revive, provision, lane (any form),
# model (any form) and reboot are solo: they relaunch panes under the exclusive recycle lock, or write the config. The tick
# (op_tick_locked) applies the declarations in one pass, in queue order: it starts a par operation when fewer than
# SALA_OP_PARALLEL (3; 1 = one at a time, as before) are running, no solo one is running, and none of its names is held by
# a running or waiting operation or by an older queued one that could not start (a name's operations keep their order); it
# starts a solo operation only when nothing is running, and a solo one that must wait for running operations stops the pass,
# so nothing younger starts behind it and it is not starved. The class and names are put on the marker at the start (par=,
# keys=): a running marker without them (an upgrade mid-run) counts as solo. A recycle about to start absorbs every queued
# recycle and every queued update of this box alone: their flags fold into it, their markers end as `absorbed` with
# `into=<id>`, their hearers are told. Inside the unit the runner takes the recycle lock (fd 9, common.sh) before any verb:
# EXCLUSIVE for a solo operation, held through one that takes none itself (retire of the master, lane default, a provision
# of named boxes, reboot) and given back at once to one that does (recycle, revive, update's local leg, a lane switch, a
# model switch, a whole-fleet provision, with SALA_LOCK_WHO=op-<id> and a 10-min wait for a relaunch already running);
# SHARED (flock -s, recycle_lock_shared) for a par one, so several run side by side while a relaunch driver, which
# takes it exclusively, still waits for them all and they for it. What the par verbs share, and what protects it, is named in
# tests/opparallel.sh (the pane map, the lane and model tables, the sessions registry: flock + temp file and mv in common.sh;
# the resurrect save: the snapshot lock, taken by spawn too). master_guard and ops_guard admit a caller inside a sala-op-<id>
# unit (op_unit_caller, common.sh) in place of the master's pane — a guard against accidents, as now; the Bash guard hook
# still denies the raw commands.
#
# THE RESULT: a verb that exits non-zero is stuck. A relaunch verb's end is the lock freed (the sweep and, from a pane, the
# self-worker done); its set (common.sh, "recycle sets") then says: closed with nothing given up → done; closed with a pane
# given up → stuck; panes still outstanding (a retry worker, the deferred list) → `waiting`, and a detached waiter judges
# the set once it closes (up to the retry window and 15 min). The queue goes on meanwhile: a later operation waits only for
# the lock. Every result is one Slack post (✅ done · 🚨 stuck with the exact failure) and one line into the hearing
# session's inbox (its messaging socket, as `sala note` delivers; when it is not live, the line goes to <name>-main with
# `[for <owner>]` first and the op log says `reply: … sent to …`; when neither is live, the op log says `reply FAILED` and the post stands), then the archive. The same end is reported once to stackshot (`client.py event --kind fleet_op`, op_event,
# THE OP-END EVENT above op_finish): a failure of that report is a line in the op log and nothing else.
#
# A runner that ended without a result (its unit gone, no pid alive, the marker still `running`) is found by the next tick
# and handed to the stuck handler as a unit of its own (sala-op-<id>-stuck; never inside the tick: sala-watch.service is a
# oneshot whose leftover processes die with it); a reboot's runner gone with the boot id changed is the box back: done.
#
# STUCK: at most one `claude -p` per operation (SALA_OP_STUCK=on), started by the runner on the SALA_JOB_LANE lane (subscription-1 is env -u
# ANTHROPIC_API_KEY -u ANTHROPIC_CUSTOM_HEADERS -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CONFIG_DIR), default permission mode (no
# bypass flag: a prompt it meets ends it), --allowedTools limited to sala's verbs and read-only inspection, --max-turns and a
# wall clock (SALA_OP_STUCK_TURNS, SALA_OP_STUCK_TIME), with a brief of the operation, the log tails and what was already
# tried. It ends with one line, `SALA-OP: done <what>` or `SALA-OP: stuck <why>`; a `done` is checked where sala can (the
# retired session gone, the renamed one live, the default lane set) and trusted otherwise. If it does not finish the
# operation, the operation is stuck: posted once with the exact failure, told to the hearing session, archived; nothing
# retries it by another route. The tests stub the command (SALA_OP_CLAUDE), so no suite ever calls the API.
#
# Sourced by bin/salamander (op_main) and by lib/watch.sh (op_tick).

: "${SALA_OP_REASON_FROM:=}"                                   # who may use the reason door (a revive with no words and a reason): empty = any live Claude session, else a space-separated allow list of session names (THE WORDS POLICY, the header)
: "${SALA_OP_QUEUE:=on}"                                   # watch: run the queue (off: markers wait, nothing starts)
: "${SALA_OP_REBOOT:=off}"                                 # reboot is not queued (the owner runs `sala reboot --go`); on is unsupported until a confirmation path is built
: "${SALA_OP_LOCK_WAIT:=600}"                              # seconds the runner waits for a relaunch that holds the recycle lock
: "${SALA_OP_SWEEP_WAIT:=1800}"                            # seconds the runner gives a relaunch's sweep (the lock to free)
: "${SALA_OP_SETTLE_WAIT:=$((SALA_RETRY_WINDOW + 900))}"   # seconds the waiter gives a set with panes outstanding
: "${SALA_OP_KICK_END:=5}"                                 # seconds after an operation ends before the next queued one is looked for (op_kick_end); the timer's 2 min is the backstop
: "${SALA_OP_EVENT_TIMEOUT:=30}"                           # seconds the end-of-op report to stackshot (client.py event) is given; a slow one is logged and dropped
: "${SALA_OP_PARALLEL:=3}"                                 # operations running at once, at most, and only parallel-safe ones side by side (the header); 1 = one at a time
: "${SALA_OP_POLL:=5}"                                   # seconds between the runner's looks at the lock, the waiter's at the set
: "${SALA_OP_STUCK:=on}"                                   # a stuck operation gets one claude -p
: "${SALA_OP_CLAUDE:=}"                                    # the command that claude -p runs as (the tests: a stub); empty = SALA_CLAUDE
: "${SALA_OP_STUCK_TURNS:=25}"                             # its --max-turns
: "${SALA_OP_STUCK_TIME:=1200}"                            # its wall clock, seconds
: "${SALA_OP_HELPER_CWD:=$HOME}"                           # where it runs
: "${SALA_OP_HELPER_TOOLS:=Bash(sala:*),Bash(salamander:*),Bash(tmux list-panes:*),Bash(tmux list-sessions:*),Bash(tmux display:*),Bash(tmux capture-pane:*),Bash(tail:*),Bash(cat:*),Bash(ls:*),Bash(ps:*),Bash(grep:*),Read,Grep,Glob}"
SALA_OP_DIR="$SALA_STATE_DIR/ops"; SALA_OP_DONE="$SALA_OP_DIR/done"; SALA_OP_LOG="$SALA_LOG_DIR/salamander-op.log"
SALA_MANDATE_DIR="$SALA_STATE_DIR/mandates"   # a queued spawn's TEXT mandate, as a file the session reads (THE MANDATE'S TRANSPORT, the header)
SALA_OP_VERBS="recycle update revive retire close-shell forget-row rename lane model provision spawn reboot"

op_log() { local _t; [ -d "$SALA_LOG_DIR" ] || mkdir -p "$SALA_LOG_DIR"; _iso_now_r _t; echo "[$_t] $*" >> "$SALA_OP_LOG"; }   # (no mkdir and date process on every line)
op_dur() { if [ "$1" -lt 60 ]; then echo "$1 s"; else dur_words "$1"; fi; }   # <seconds> → words (the suites run the waits in seconds)
op_say() { local _t; _iso_now_r _t; echo "[$_t] op $1: ${*:2}" >&2; }   # the operation's own log (the unit's stderr and stdout both land there; stderr, so a $(…) never captures it)
op_oplog() { echo "$SALA_LOG_DIR/salamander-op-$1.log"; }
op_out() { echo "$SALA_LOG_DIR/salamander-op-$1.out"; }   # the verb's own output, a copy (the log has it too, between the runner's lines)
op_files() { local f; for f in "$SALA_OP_DIR"/*.op; do [ -e "$f" ] && printf '%s\n' "$f" 2>/dev/null; done; return 0; }   # oldest first: the name starts with the epoch (a glob comes sorted; no ls and sort)
_op_file_r() { if [ -f "$SALA_OP_DIR/$2.op" ]; then printf -v "$1" %s "$SALA_OP_DIR/$2.op"; else printf -v "$1" %s "$SALA_OP_DONE/$2.op"; fi; }   # <var> <id> → the marker's path, no subshell
op_file() { local _of; _op_file_r _of "$1"; echo "$_of"; }
op_val() { local _ovf; _op_file_r _ovf "$1"; _kv_first "$_ovf" "$2"; }    # <id> <key> → the first value
op_vals() { local _ovf; _op_file_r _ovf "$1"; _kv_all "$_ovf" "$2"; }          # <id> <key> → every value
op_put() { local _opf; _op_file_r _opf "$1"; [ -f "$_opf" ] || return 1; _kv_set "$_opf" "$2" "$3" t; }   # (the shell's own rewrite, none when the value stands)
op_add() { printf '%s=%s\n' "$2" "$3" >> "$(op_file "$1")"; }
op_archive() { mkdir -p "$SALA_OP_DONE"; [ -f "$SALA_OP_DIR/$1.op" ] && mv -f "$SALA_OP_DIR/$1.op" "$SALA_OP_DONE/$1.op"; return 0; }   # a spawn's mandate file stays where the session reads it
op_mandate_files() { ls "$SALA_MANDATE_DIR/$1"-*.md 2>/dev/null; }   # <id> → the mandate file(s) a queued spawn wrote (one, or none)
op_line() {  # <id> → "verb args" (the marker read once by the shell, it was a paste, two subshells and four processes)
    local _lf _ll _la="" _lv="" _lseen="" _ln=0
    _op_file_r _lf "$1"
    { while IFS= read -r _ll || [ -n "$_ll" ]; do
          case $_ll in
              arg=*) if [ "$_ln" = 0 ]; then _la=${_ll#arg=}; else _la+=" ${_ll#arg=}"; fi; _ln=1 ;;
              arg) if [ "$_ln" = 0 ]; then _la=""; else _la+=" "; fi; _ln=1 ;;
              verb=*) [ -n "$_lseen" ] || { _lv=${_ll#verb=}; _lseen=1; } ;;
              verb) [ -n "$_lseen" ] || { _lv=""; _lseen=1; } ;;
          esac
      done < "$_lf"; } 2>/dev/null
    echo "$_lv${_la:+ $_la}"
}
op_one_line() { local _s="$*"; _s=${_s//[$'\r\n\t']/ }; while [[ $_s == *"  "* ]]; do _s=${_s//  / }; done; _s=${_s# }; _s=${_s% }; printf '%s\n' "$_s"; }   # (tr and sed, in the shell)
op_hearer() {  # the session that runs this: its tmux session name, else a plain shell
    local s; [ -n "${TMUX_PANE:-}" ] && s=$(tmux display -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null) && [ -n "$s" ] && { echo "$s"; return; }
    echo "$_SALA_HN shell"
}
op_from_claude() {  # → 0 when a claude process is among the ancestors (a Claude session's call; ops_guard's walk)
    local p=$$ c np _a _b _c
    while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
        c=""; { read -r c < "/proc/$p/comm"; } 2>/dev/null || :; [ "$c" = claude ] && return 0
        np=""; { read -r _a _b _c np _ < "/proc/$p/stat"; } 2>/dev/null || :; p=$np   # field 4 of the stat line, as the awk took it
    done
    return 1
}
op_throwaway_name() {  # <name> → 0 when the name is one a throwaway carries by habit: scratch-* (a bare `sala spawn`), *-check-*, *-test-*, *-probe-*
    case "$1" in scratch-*|*-check-*|*-test-*|*-probe-*) return 0 ;; esac
    return 1
}
op_caller_is() {  # <from> → 0 when this call runs inside <from>'s own Claude session, placed by PROCESS ANCESTRY (common.sh ancestry_session, never TMUX_PANE or --from); else 1, the reason in OP_CALLER_WHY
    # The one placement of the caller that every no-words door uses (retire's throwaway door, the item revive): a pane's process in tmux list-panes -a with a trusted Claude Code process on the way up.
    local f=$1 h; OP_CALLER_WHY=""
    h=$(ancestry_session) || h=""
    if [ -z "$h" ]; then OP_CALLER_WHY="sala cannot place this call in a Claude session's pane by its process ancestry (a plain shell, a detached or orphaned process, or no claude above the call): pass --words in a plain shell"; return 1; fi
    if [ "$h" != "$f" ]; then OP_CALLER_WHY="--from is '$f' but this call runs in session '$h': --from is your own session name"; return 1; fi
    return 0
}
op_own_retire_ok() {  # <name> <from> → 0 when <from> may queue `retire <name>` with no words (widened Fri Oct 30th 2026); else 1, the reason in OP_OWN_WHY, the rule in OP_OWN_RULE
    # The session that started a throwaway may end it with no words, and retiring a throwaway must never need the owner, whoever started it and whatever its row records. A THROWAWAY is a live registry row under exactly that name
    # with no project, no role, not a side session, not on a project's agents map (op_own_target_ok), and not the master.
    # WHO MAY END ONE WITH NO WORDS: any live session when the row carries the throwaway tag (set at spawn, see op_own_target_ok); on a row
    # WITHOUT the tag (made before it), the earlier rules: its spawner (the row's spawned_by); the master session (SALA_MASTER) when the name is a throwaway's (op_throwaway_name)
    # or the master is the spawner; any live Claude session when the row has no spawner, or its spawner is no longer a live tmux session (a renamed
    # spawner is not live), AND the name is a throwaway's. The master and any-session doors FAIL CLOSED on the agents-map check (op_own_confirm_unlisted:
    # the project record, else pages.py agent-listed, else a refusal), and a retire with no words never carries a bypass flag, --keep-web or --id. A session never retires
    # itself. <from> is only a claim, and TMUX_PANE is an environment variable any caller can set, so the caller is placed by PROCESS ANCESTRY
    # (common.sh ancestry_session: this shell's parents up /proc until one is a pane's process in tmux list-panes -a, a Claude Code process on the
    # way: comm claude and an exe under the account's install folder, not the name alone): that session must be <from>. No pane found (a plain
    # shell, a detached or orphaned job, a symlink to bash named claude) → refused here, and a human in a plain shell passes --words instead. The
    # target is bound to the row by the process too, not by the tmux session name alone (op_own_target_ok). Every other case keeps the refusal.
    local n=$1 f=$2
    OP_OWN_WHY=""; OP_OWN_ROWID=""; OP_OWN_RULE=""
    if [ -z "$n" ] || [ -z "$f" ]; then OP_OWN_WHY="no session name or no --from"; return 1; fi
    op_caller_is "$f" || { OP_OWN_WHY=$OP_CALLER_WHY; return 1; }
    op_own_target_ok "$n" "$f" ""
}
op_self_retire_ok() {  # <name> <retire's flags…> → 0 unless <name> is the session this call runs in and --self is not among the flags; else 1, the reason in OP_SELF_WHY
    # A retire of the asker's own session ends the very call that queued it. retire's own dry run (the plan) refuses it too, when it runs in that pane; this
    # is the same rule asked first and in one plain sentence. The caller is placed by process ancestry (common.sh ancestry_session), as op_own_retire_ok does,
    # never by --from, which is only a claim. The queue's runner is not in the pane's process tree, so a run-time check cannot be made from here: a retire
    # --id names its session only at run time and retire.sh holds it there (SALA_OP_FROM), and a named one was settled at queue time.
    local n=$1 a h; shift; OP_SELF_WHY=""
    for a in "$@"; do [ "$a" = --self ] && return 0; done
    h=$(ancestry_session 2>/dev/null) || h=""
    [ -n "$h" ] && [ "$h" = "$n" ] || return 0
    OP_SELF_WHY="'$n' is the asking session itself, the session this call runs in: retiring it ends this very call and the turn that made it. To do it, queue it with --self: sala op retire $n --self --from $n --words \"<${SALA_OWNER_NAME}'s words>\" (it is then retired once its turn is over)"
    return 1
}
op_own_flags_ok() {  # <retire's argv, the name and its flags in any order> → 0 when a no-words retire carries no bypass flag and no --id; else 1, the reason in OP_OWN_WHY
    # --busy, --skip-writeup, --self, --leave-items and --keep-web are retire's ways past its own guards (a busy pane, an unfinished write-up, its own session, an open
    # board item, a web session kept or dropped), --force is the old spelling of two of them, and --id names a session by something other than its tmux name: the
    # owner's word, never a throwaway's. Asked at queue time (op_main) and again by the runner (op_run) on the stored arguments.
    local a; OP_OWN_WHY=""
    for a in "$@"; do case "$a" in --force|--busy|--skip-writeup|--self|--leave-items|--keep-web|--id|--id=*) OP_OWN_WHY="a retire with no words takes no bypass flag and no --id ('$a' is ${SALA_OWNER_NAME}'s call): add --words \"…\" with ${SALA_OWNER_NAME}'s words, or drop '$a'"; return 1 ;; esac; done
    return 0
}
op_own_list_record() {  # <name> → OP_OWN_LIST (listed · unlisted · unknown) and OP_OWN_LISTWHY, from stackshot's project record alone (project_record_agent)
    local rec rrc; rec=$(project_record_agent "" "$1" 2>/dev/null); rrc=$?
    OP_OWN_LISTWHY=""
    case "$rrc" in
        0) OP_OWN_LIST=listed; OP_OWN_LISTWHY="${rec%%$'\n'*}" ;;
        3) OP_OWN_LIST=unlisted ;;   # a fresh record that lists the name on no project
        *) OP_OWN_LIST=unknown; OP_OWN_LISTWHY=$(_lastline "$rec") ;;   # missing, unreadable, another schema, older than SALA_PROJECT_RECORD_MAX_AGE
    esac
}
op_own_list_pages() {  # <name> → when the record could not answer: OP_OWN_LIST from pages.py agent-listed, the path agent_unlisted takes (but SALA_AGENT_CHECK=off and the sala-test-*/*-side-* skips of agent_unlisted do not apply: a gate that cannot answer refuses)
    local py out rc last; py=$(agent_check_script) || { OP_OWN_LISTWHY="${OP_OWN_LISTWHY:+$OP_OWN_LISTWHY; }no pages.py on this box to ask instead"; return 0; }
    out=$(timeout 15 python3 "$py" agent-listed "$1" 2>&1); rc=$?; last=$(_lastline "$out")
    case "$rc" in
        3) OP_OWN_LIST=unlisted ;;   # an agent-shaped name its project page does not list
        0) if [ "$last" = "no project page for this name: nothing to check" ]; then OP_OWN_LIST=unlisted   # no project of that prefix: not an agent's name
           else OP_OWN_LIST=listed; OP_OWN_LISTWHY=$last; fi ;;   # "listed on <page>: …", or the name of a project itself
        *) OP_OWN_LISTWHY="${OP_OWN_LISTWHY:+$OP_OWN_LISTWHY; }pages.py agent-listed exited $rc: $last" ;;
    esac
}
op_own_confirm_unlisted() {  # <name> → 0 when a FRESH answer (the record, else pages.py) says <name> is on no project's agents map; else 1, the reason in OP_OWN_WHY. FAIL CLOSED: no answer is a refusal.
    local n=$1
    [ -n "${OP_OWN_LIST:-}" ] || op_own_list_record "$n"
    [ "$OP_OWN_LIST" != unknown ] || [ -n "${OP_OWN_TRIED:-}" ] || { OP_OWN_TRIED=1; op_own_list_pages "$n"; }   # pages.py once per check
    case "$OP_OWN_LIST" in
        unlisted) return 0 ;;
        listed) OP_OWN_WHY="'$n' is on a project's agents map (${OP_OWN_LISTWHY:-listed}), not a throwaway" ;;
        *) OP_OWN_WHY="the project record could not confirm that '$n' is unlisted (on no project's agents map): ${OP_OWN_LISTWHY:-no answer}; with no words this is refused, so retry once the record is fresh or pass --words" ;;
    esac
    return 1
}
op_own_target_ok() {  # <name> <caller> <row id, or "" to take the row's own> → 0 when <caller> may end <name> with no words; else 1, the reason in OP_OWN_WHY; the row's id in OP_OWN_ROWID, the rule in OP_OWN_RULE (spawner|tag|master|any)
    # The target half of op_own_retire_ok, asked twice: when the operation is queued, and again by the runner before it ends anything
    # (op_run), with the row id the marker stored. Between the two the session under the name can be closed and another named the same.
    local n=$1 f=$2 want=$3 row rn sb pj rl sd rid tw pp q sid rec nsame=0 nnone=0 nclaude=0 splive=0 t
    OP_OWN_WHY=""; OP_OWN_ROWID=""; OP_OWN_RULE=""
    if [ "$n" = "$f" ]; then OP_OWN_WHY="'$n' is the asking session itself"; return 1; fi
    if [ -n "${SALA_MASTER:-}" ] && [ "$n" = "$SALA_MASTER" ]; then OP_OWN_WHY="'$n' is the master session"; return 1; fi
    row=$(sessions_py resolve "$n" --live --json 2>/dev/null | python3 -c 'import json,sys
try: r=json.load(sys.stdin)
except Exception: sys.exit(0)
print("\t".join(str(r.get(k) or "-").replace("\t", " ") for k in ("name", "spawned_by", "project", "role", "side", "id", "throwaway")))' 2>/dev/null)
    if [ -z "$row" ]; then OP_OWN_WHY="'$n' has no live registry row under that exact name"; return 1; fi
    IFS=$'\t' read -r rn sb pj rl sd rid tw <<< "$row"
    if [ "$rn" = "-" ]; then OP_OWN_WHY="'$n' has no live registry row under that exact name"; return 1; fi
    if [ "$rn" != "$n" ]; then OP_OWN_WHY="'$n' is not the registry row's own name ('$rn')"; return 1; fi
    if [ "$pj" != "-" ] || [ "$rl" != "-" ]; then OP_OWN_WHY="'$n' is a project agent, not a throwaway"; return 1; fi
    if [ "$sd" != "-" ] || side_is "$n"; then OP_OWN_WHY="'$n' is a side session, retired only on ${SALA_OWNER_NAME}'s word"; return 1; fi
    # A name on a project's agents map is an agent whatever its row says (stackshot's project record, a file read: common.sh project_record_agent).
    # Asked here for every rule; a listing refuses. What the record cannot say (missing, stale, unreadable) is left "unknown" for now: the spawner
    # rule goes on as before (its row is the proof), while the master and any-session rules, and a pane with no row id (below), FAIL CLOSED:
    # they ask pages.py agent-listed and refuse when that cannot confirm the name is unlisted either (op_own_confirm_unlisted).
    OP_OWN_LIST=""; OP_OWN_LISTWHY=""; OP_OWN_TRIED=""
    op_own_list_record "$n"
    if [ "$OP_OWN_LIST" = listed ]; then OP_OWN_WHY="'$n' is on a project's agents map ($OP_OWN_LISTWHY), not a throwaway"; return 1; fi
    # WHO: the spawner; any session when the row carries the throwaway tag; on an UNTAGGED row (made before the tag), the master (a throwaway's
    # name, unless it started it) and any session when nobody live owns it and the name is a throwaway's (the earlier rules, unchanged). The tag counts only
    # here, after the project/role/side/agents-map refusals above: a tag on a row that has since become an agent opens nothing.
    if [ "$sb" != "-" ] && [ "$sb" != "$n" ] && tmux has-session -t "=$sb" 2>/dev/null; then splive=1; fi
    if [ "$sb" != "-" ] && [ "$sb" = "$f" ]; then OP_OWN_RULE=spawner
    elif [ "$tw" = 1 ]; then OP_OWN_RULE=tag
    elif [ -n "${SALA_MASTER:-}" ] && [ "$f" = "$SALA_MASTER" ]; then
        op_throwaway_name "$n" || { OP_OWN_WHY="'$n' was not started by the master and its name is not a throwaway's (scratch-*, *-check-*, *-test-*, *-probe-*): the master ends a throwaway with no words only when it started it or the name is one"; return 1; }
        OP_OWN_RULE=master
    elif [ "$splive" = 0 ] && op_throwaway_name "$n"; then OP_OWN_RULE=any
    elif [ "$splive" = 1 ]; then OP_OWN_WHY="'$n' was started by '$sb', who is still live: only '$sb' or the master ends it with no words"; return 1
    elif [ "$sb" = "-" ]; then OP_OWN_WHY="'$n' has no spawner on its registry row and its name is not a throwaway's (scratch-*, *-check-*, *-test-*, *-probe-*)"; return 1
    else OP_OWN_WHY="'$n' was started by '$sb', who is no longer live, but its name is not a throwaway's (scratch-*, *-check-*, *-test-*, *-probe-*)"; return 1; fi
    if [ "$OP_OWN_RULE" != spawner ]; then op_own_confirm_unlisted "$n" || return 1; fi
    # THE PROCESS BINDING: the row's id is what spawn gave the throwaway's pane and claude as SALA_SESSION_ID (and what every child of
    # theirs inherits). EVERY process in the tree of EVERY pane now under the tmux session called <n> is read: one that carries ANOTHER id is a
    # session renamed to <n> (refused); the processes must all carry the row's id, or ALL carry none, which is a pane that predates the id
    # (an old row, or a row with no id): then the pane has to be a Claude Code process (comm claude and a trusted exe, as for a caller),
    # so a plain program under the name is no throwaway. A mix (some with the id, some without) is refused. A process that has exited
    # between the listing and the read is skipped. No tmux session of that name: nothing there to hit, the retire only clears the row.
    if [ -n "$want" ] && [ "$rid" != "$want" ]; then OP_OWN_WHY="the registry row under '$n' now is not the one the operation was queued for (row id $rid, queued for $want)"; return 1; fi
    OP_OWN_ROWID=$rid; [ "$rid" != "-" ] || rid=""
    if tmux has-session -t "=$n" 2>/dev/null; then
        while read -r pp; do
            [ -n "$pp" ] || continue
            while read -r q; do
                [ -n "$q" ] || continue
                [ -d "/proc/$q" ] || continue
                sid=$(proc_env_val "$q" SALA_SESSION_ID) || sid=""
                if [ -n "$sid" ] && [ "$sid" = "$rid" ]; then nsame=$((nsame + 1))
                elif [ -n "$sid" ]; then
                    proc_gone "$q" && continue
                    OP_OWN_WHY="the tmux session '$n' now is not the throwaway on that registry row (process $q in it carries another row's id): renamed or relaunched since"; return 1
                else
                    proc_gone "$q" && continue   # it exited (or is a zombie, whose environment reads empty) between the listing and the read
                    nnone=$((nnone + 1))
                fi
                t=""; { read -r t < "/proc/$q/comm"; } 2>/dev/null || :
                if [ "$t" = claude ] && claude_exe_trusted "$q"; then nclaude=$((nclaude + 1)); fi
            done < <(proc_tree "$pp")
        done < <(tmux list-panes -s -t "$(tmux_win_t "$n")" -F '#{pane_pid}' 2>/dev/null)
        if [ "$nnone" -gt 0 ] && [ "$nsame" -gt 0 ]; then OP_OWN_WHY="the tmux session '$n' now is not the throwaway on that registry row (a process in it does not carry the row's id): renamed or relaunched since"; return 1; fi
        if [ "$nnone" -gt 0 ] && [ "$nclaude" = 0 ]; then OP_OWN_WHY="the tmux session '$n' carries no row id on any process (a pane from before ids) and none of its processes is a Claude Code process: not a throwaway sala started"; return 1; fi
        if [ "$nnone" -gt 0 ]; then
            # A pane with no id anywhere is bound by its NAME alone, so the name has to be a throwaway's and a fresh answer has to say it is unlisted, whichever rule let the caller in
            op_throwaway_name "$n" || { OP_OWN_WHY="the tmux session '$n' carries no row id on any process (a pane from before ids) and its name is not a throwaway's (scratch-*, *-check-*, *-test-*, *-probe-*): nothing but the name binds it to the row"; return 1; }
            op_own_confirm_unlisted "$n" || return 1
        fi
    fi
    return 0
}
op_own_note() {  # → the note a no-words retire carries, by the rule that allowed it (OP_OWN_RULE)
    case "$OP_OWN_RULE" in
        spawner) echo "words: none (throwaway, retired by its spawner)" ;;
        tag) echo "words: none (throwaway tag set at spawn, retired by any session)" ;;
        master) echo "words: none (throwaway, retired by the master)" ;;
        *) echo "words: none (throwaway with no tag, retired by any session: no live spawner)" ;;
    esac
}
op_item_ok() {  # <item> → 0 when it is a board item id, board#N and nothing else (a FORMAT check only: stackshot is not asked whether the item exists, THE WORDS POLICY, the header)
    local re='^board#[0-9]+$'; [[ $1 =~ $re ]]
}
op_why_ok() {  # <text> → 0 when it is a usable --why: one line with no control character, three words or more, at most 200 characters; else 1, the reason in OP_REASON_WHY
    local t=$1 w; OP_REASON_WHY=""
    if [ -z "$t" ]; then OP_REASON_WHY="--why needs a reason in words"; return 1; fi
    if [[ $t == *[[:cntrl:]]* ]]; then OP_REASON_WHY="--why is one line (no line break, tab or control character)"; return 1; fi
    t=$(op_one_line "$t"); read -ra w <<< "$t"
    if [ "${#w[@]}" -lt 3 ]; then OP_REASON_WHY="--why is a reason of three words or more, not '$t'"; return 1; fi
    if [ "${#t}" -gt 200 ]; then OP_REASON_WHY="--why is at most 200 characters (this one is ${#t})"; return 1; fi
    return 0
}
op_reason_from_ok() {  # <from> → 0 when <from> may use the reason door: any session while SALA_OP_REASON_FROM is empty, else one of the names it lists
    local x; [ -n "$SALA_OP_REASON_FROM" ] || return 0
    for x in $SALA_OP_REASON_FROM; do [ "$x" = "$1" ] && return 0; done
    return 1
}
op_reason_args_ok() {  # <revive's args…> → 0 when they are one or more `--only NAME` and at most `--force`, nothing else; the names in OP_REASON_NAMES; else 1, the reason in OP_REASON_WHY
    OP_REASON_NAMES=(); OP_REASON_WHY=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --only) { [ $# -ge 2 ] && [ -n "$2" ]; } || { OP_REASON_WHY="--only needs a session name"; return 1; }; OP_REASON_NAMES+=("$2"); shift ;;
            --force) ;;
            *) OP_REASON_WHY="a revive with no words takes --only NAME (one or more) and --force, nothing else ('$1' is ${SALA_OWNER_NAME}'s call: add --words \"…\")"; return 1 ;;
        esac; shift
    done
    [ ${#OP_REASON_NAMES[@]} -ge 1 ] || { OP_REASON_WHY="a revive with no words names its sessions with --only NAME: a sweep of every pane is ${SALA_OWNER_NAME}'s call (add --words \"…\")"; return 1; }
    return 0
}
op_reason_target_ok() {  # <name> <from> <row id, or "" to take the row's own> → 0 when <from> may revive <name> with no words; else 1, the reason in OP_REASON_WHY; the row's id in OP_REASON_ROWID
    # The target half of the reason revive, asked twice: when the operation is queued, and again by the runner (op_run) with the row id the marker stored. <name> is a live
    # Claude session of the registry under exactly that name (a row, not just a tmux session), not the master (the master's revive needs the owner's words: it is the
    # session sala keeps alive) and not the asker itself (a revive of the asking session itself needs the owner's words: the plan already says what it would do).
    local n=$1 f=$2 want=$3 row rn rid
    OP_REASON_WHY=""; OP_REASON_ROWID=""
    if [ "$n" = "$f" ]; then OP_REASON_WHY="'$n' is the asking session itself: a revive of yourself needs ${SALA_OWNER_NAME}'s words (--words \"…\")"; return 1; fi
    if [ -n "${SALA_MASTER:-}" ] && [ "$n" = "$SALA_MASTER" ]; then OP_REASON_WHY="'$n' is the master session: reviving it needs ${SALA_OWNER_NAME}'s words (--words \"…\")"; return 1; fi
    row=$(sessions_py resolve "$n" --live --json 2>/dev/null | python3 -c 'import json,sys
try: r=json.load(sys.stdin)
except Exception: sys.exit(0)
print("\t".join(str(r.get(k) or "-").replace("\t", " ") for k in ("name", "id")))' 2>/dev/null)
    IFS=$'\t' read -r rn rid <<< "$row"
    if [ -z "${rn:-}" ] || [ "$rn" = "-" ]; then OP_REASON_WHY="'$n' has no live registry row under that exact name (a Claude session the registry knows)"; return 1; fi
    if [ "$rn" != "$n" ]; then OP_REASON_WHY="'$n' is not the registry row's own name ('$rn')"; return 1; fi
    if [ -n "$want" ] && [ "$rid" != "$want" ]; then OP_REASON_WHY="the registry row under '$n' now is not the one the operation was queued for (row id $rid, queued for $want)"; return 1; fi
    if [ "$rid" = "-" ] || [ -z "$rid" ]; then OP_REASON_WHY="'$n' has no row id in the registry: a no-words revive is bound to the row"; return 1; fi
    OP_REASON_ROWID=$rid
    return 0
}
op_reason_revive_ok() {  # <from> <item or ""> <why or ""> <revive's args…> → 0 when <from> may queue `revive <args>` with no words; else 1, the reason in OP_REASON_WHY; the row ids (one per --only, in order) in OP_REASON_ROWIDS
    # THE REASON DOOR (the header): one or more `--only NAME` and at most `--force`; a reason, `--item board#N` (format only) or `--why "<text>"`; <from> any session while SALA_OP_REASON_FROM is empty
    # AND the session this call runs in by process ancestry (op_caller_is: a plain shell, a detached job or --auto never passes); every NAME a live registry row, not the master, not <from>.
    local f=$1 it=$2 wy=$3 n; shift 3
    OP_REASON_WHY=""; OP_REASON_ROWIDS=()
    if [ -z "$it" ] && [ -z "$wy" ]; then OP_REASON_WHY="a revive with no words needs a reason: --item board#N (the board item that found the session unable to work) or --why \"<one line, three words or more>\"; without one ${SALA_OWNER_NAME}'s words are needed: add --words \"…\""; return 1; fi
    op_reason_args_ok "$@" || return 1
    if ! op_reason_from_ok "$f"; then OP_REASON_WHY="--from '$f' may not revive with no words: only ${SALA_OP_REASON_FROM} (SALA_OP_REASON_FROM) may; anyone else needs ${SALA_OWNER_NAME}'s words (--words \"…\")"; return 1; fi
    op_caller_is "$f" || { OP_REASON_WHY=$OP_CALLER_WHY; return 1; }
    for n in "${OP_REASON_NAMES[@]}"; do op_reason_target_ok "$n" "$f" "" || return 1; OP_REASON_ROWIDS+=("$OP_REASON_ROWID"); done
    return 0
}
op_reason_note() {  # <item> <why> <count> → the note a no-words revive carries
    if [ -n "$1" ]; then
        if [ "$3" = 1 ]; then echo "words: none ($1: revive of one session)"; else echo "words: none ($1: revive of $3 sessions)"; fi
    else echo "words: none (reason: $2)"; fi
}
op_reason_run_ok() {  # <id> → 0 when the marker of a no-words revive still passes every check (op_run); else 1, the reason in OP_REASON_WHY. The caller's ancestry cannot be asked here (the runner is outside every pane): the queue-time check stands for it.
    local id=$1 it wy i from rows=(); it=$(op_val "$id" item); wy=$(op_val "$id" reason); from=$(op_val "$id" from)
    OP_REASON_WHY=""
    [ "$(op_val "$id" verb)" = revive ] || { OP_REASON_WHY="the marker says no words but is not a revive"; return 1; }
    if [ -n "$it" ] && [ -n "$wy" ]; then OP_REASON_WHY="the marker carries both an item and a reason"; return 1; fi
    if [ -z "$it" ] && [ -z "$wy" ]; then OP_REASON_WHY="the marker says no words but carries no reason (item= or reason=)"; return 1; fi
    if [ -n "$it" ]; then op_item_ok "$it" || { OP_REASON_WHY="the marker's item '$it' is not a board item id"; return 1; }
    else op_why_ok "$wy" || return 1; fi
    op_reason_args_ok ${OP_ARGS[@]+"${OP_ARGS[@]}"} || return 1
    mapfile -t rows < <(op_vals "$id" ownrow)
    [ "${#rows[@]}" = "${#OP_REASON_NAMES[@]}" ] || { OP_REASON_WHY="the marker carries ${#rows[@]} registry row id(s) (ownrow=) for ${#OP_REASON_NAMES[@]} session(s)"; return 1; }
    op_reason_from_ok "$from" || { OP_REASON_WHY="'$from' may no longer revive with no words (SALA_OP_REASON_FROM: ${SALA_OP_REASON_FROM:-any})"; return 1; }
    for ((i=0; i<${#OP_REASON_NAMES[@]}; i++)); do op_reason_target_ok "${OP_REASON_NAMES[i]}" "$from" "${rows[i]}" || return 1; done
    return 0
}
op_words_policy() {  # <verb> <args…> → OP_POLICY: what a marker with NO words needs (THE WORDS POLICY, the header): owner · reason · throwaway
    local v=${1:-} only=0; shift || true; OP_POLICY=owner
    case "$v" in
        retire) OP_POLICY=throwaway ;;   # the throwaway door (op_own_retire_ok) decides which retire: the policy only says it has a door
        revive)
            while [ $# -gt 0 ]; do
                case "$1" in
                    --only) [ $# -ge 2 ] || return 0; only=$((only + 1)); shift ;;
                    --force) ;;
                    *) return 0 ;;
                esac; shift
            done
            [ "$only" -ge 1 ] && OP_POLICY=reason ;;   # a sweep (no --only) and any other flag stay the owner's
    esac
    return 0
}
op_words_of() {  # <id> → the owner's words quoted, else the note a no-words retire carries, else nothing
    local w; w=$(op_val "$1" words)
    if [ -n "$w" ]; then printf '"%s"\n' "$w"; else op_val "$1" nowords; fi
}

# ── the verb table ───────────────────────────────────────────────────────────
op_shapes() {
    local _t; IFS= read -r -d '' _t <<'EOF' || :   # (a read, not a cat process)
  recycle [--update] [--force]              "recycle claude" = recycle --update --force
  update [HOST…|--fleet]                    this box (= recycle --update --force), named fleet hosts, or the fleet then this box
  revive [--only NAME]… [--force]           bring a session back (--only), or every pane on an older CLI. Needs the owner's words, EXCEPT
                                            `revive --only NAME [--only NAME]… [--force] --item board#N --from YOU` (or --why "<one line, three words or more>" in place of --item): no --words, accepted only when
                                            every NAME is a live Claude session of the registry that is neither the master nor YOU, and YOU is the session whose pane holds the call by process ancestry
                                            (not TMUX_PANE; a Claude Code exe, not a name; SALA_OP_REASON_FROM, empty = any session, limits who); never a sweep (no --only), --rescue, --lane-default or any other flag.
                                            --item is a format check only (board#N): sala does not ask the board whether the item exists. The runner checks it all again before it relaunches anything
  retire NAME|--id ID [--keep-web] [--busy] [--skip-writeup] [--self] [--leave-items]
                                            ends a Claude session for good: NAME is the exact tmux session name, --id names it by conversation id; a side session only after `side done` (--skip-writeup the bypass); --busy retires a pane that is not idle; --self the session this call runs in; --leave-items a session that moves open board items (asked of stackshot first); --force is refused. Needs the owner's words, EXCEPT
                                            a throwaway: `retire NAME --from YOU` with no --words, accepted only when NAME's registry row has no project, no role,
                                            no side flag, NAME is on no project's agents map and is neither the master nor YOU, and the row carries the throwaway tag (a bare
                                            `sala spawn` writes it): then any session may end it, between turns (a pane mid-turn is refused: retire's own idle check, never --busy).
                                            A row without the tag (made before it) keeps the older rule: YOU is NAME's spawner, or the master (NAME a throwaway's name:
                                            scratch-*, *-check-*, *-test-*, *-probe-*), or any session when NAME has no live spawner and a throwaway's name;
                                            never with a bypass flag, --keep-web or --id (add --words for those); for every door but the spawner's the project record (else pages.py agent-listed)
                                            must confirm NAME is on no agents map, and with no answer the retire is refused;
                                            YOU is the session whose pane holds the call by process ancestry (not TMUX_PANE; a Claude Code exe, not a name), and every process in NAME's panes carries the row's id (or none does, one is Claude Code, NAME is a throwaway's name and a fresh answer says it is unlisted); the runner checks it again before it ends anything
  close-shell NAME [--busy]                 ends a tmux session whose panes run no Claude (exact name; refused for the master's own run outside the queue, the RC session and the caller's own session; --busy for a shell still running something). Needs the owner's words
  forget-row NAME                           drops a pane-map row (and its lane and model rows) whose tmux session is gone. Needs the owner's words
  rename OLD NEW
  lane <lane> <session>… | <lane> --all | default <lane> | fallback <lane>
                                            fallback <lane>: the dormant lane's sessions, default and jobs move to its fallback lane (SALA_LANE_FALLBACK), ONE notice with a line per session and any model change; the watch queues it by itself the moment a lane turns dormant; nothing moves back unless a person says so
  model <model> [--effort <level>] <session>… | --clear <session>… | <session> <model> [--effort <level>] | <session> --clear
                                            the model (opus|sonnet|haiku|fable|claude-…) and effort (low|medium|high|xhigh|max) the sessions run on from now: each switched in place when idle with an empty input box, else relaunched (the relaunches together, in one sweep); ONE result notice for the lot, a line per session; a first word that is a model = the many-session form, else the session comes first (one session); --clear drops the records
  provision [--only STEP[,STEP…]] [HOST…]
  spawn NAME --project <page key> --role front|back [--mandate FILE|TEXT] [--lane L] [--model M] [--effort E] [--cwd DIR] [--no-confirm]
                                            a project agent's session; the name must be on the page's agents map (the plan checks; exit 3 + ADD-TO-PAGE: when not); a back agent starts in the background brief's directory unless --cwd
  spawn NAME --side (--fork-of AGENT | --project <page key> --item board#N) [--item board#N] [--agents A,B] [--mandate FILE|TEXT] [--lane L] [--model M] [--effort E] [--cwd DIR] [--no-confirm]
                                            a side conversation (NAME contains -side-; sala spawn --suggest-name --side … suggests one): a fork of AGENT, or a fresh session about the item; on no agents map
  reboot                                    not queued: the owner runs `sala reboot --go` in the web UI's Shell (SALA_OP_REBOOT: off by default, unsupported until a confirmation path is built)
EOF
    printf '%s' "$_t"
}
op_bad() { OP_BAD="$*"; echo "✗ $*" >&2; }
op_host_ok() {  # <host> → 0 when it is this box or a SALA_FLEET_HOSTS name
    case "$1" in ''|-*|*[!A-Za-z0-9._-]*) op_bad "'$1' is not a host name"; return 1;; esac
    [ "$1" = "$_SALA_HN" ] && return 0
    case " $SALA_FLEET_HOSTS " in *" $1 "*) return 0;; esac
    op_bad "'$1' is not a fleet host (SALA_FLEET_HOSTS: ${SALA_FLEET_HOSTS:-none}; this box: $_SALA_HN)"; return 1
}
op_session_ok() { case "$1" in ''|-*|*[[:space:]:]*) op_bad "'${1:-}' is not a session name"; return 1;; esac; return 0; }
# op_shape <verb> [args…] → 0 with OP_RUN (the verb's argv), OP_PLAN (its dry run's argv, or none), OP_PLAN_NOTE, OP_LOCK
# (own: the verb takes the recycle lock itself · hold: the runner keeps it), OP_SET (a relaunch's set follows), OP_KIND
# (SALA_RELAUNCH_KIND for the waiting line), OP_TARGETS (the sessions it names, for conflicts) and OP_UNSET_MASTER (the
# target is the master: `salamander master --unset` comes first, the header); 1 with OP_BAD said. THE PARALLEL RULE'S
# DECLARATION (the header) is made by the verb's own branch: OP_PAR=par says it may run beside others, OP_KEYS the names it
# touches (OP_TARGETS when it names none of its own). The default is solo, and the end of this function turns a par verb back
# into solo when it touches no name, or is the master's retire (a config write), and gives a par verb OP_LOCK=share.
op_shape() {
    local verb="${1:-}"; shift || true; local a s flags=() hosts=() only=() sess=() lane="" name="" steps="" me
    OP_RUN=(); OP_PLAN=(); OP_PLAN_NOTE=""; OP_LOCK=hold; OP_SET=""; OP_KIND=""; OP_TARGETS=""; OP_BAD=""; OP_UNSET_MASTER=""; OP_PAR=solo; OP_KEYS=""; me=$_SALA_HN
    case "$verb" in
    recycle)
        for a in "$@"; do case "$a" in --update|--force) case " ${flags[*]-} " in *" $a "*) ;; *) flags+=("$a");; esac;; *) op_bad "recycle takes --update and --force only, not '$a'"; return 1;; esac; done
        OP_RUN=(recycle ${flags[@]+"${flags[@]}"}); OP_LOCK=own; OP_SET=1
        case " ${flags[*]-} " in *" --force "*) OP_PLAN=(revive --dry-run --force);; *) OP_PLAN=(revive --dry-run);; esac   # the sweep's verdicts, in line (recycle --dry-run detaches and prints one line)
        case " ${flags[*]-} " in *" --update "*) OP_PLAN_NOTE="would update the CLI first: $(claude_ver) → the latest release (claude update), then the sweep below";; esac ;;
    update)
        for a in "$@"; do case "$a" in --fleet) flags=(--fleet);; -*) op_bad "update takes host names or --fleet, not '$a'"; return 1;; *) op_host_ok "$a" || return 1; hosts+=("$a");; esac; done
        [ ${#flags[@]} -gt 0 ] && [ ${#hosts[@]} -gt 0 ] && { op_bad "update takes either --fleet or host names, not both"; return 1; }
        OP_RUN=(update ${hosts[@]+"${hosts[@]}"} ${flags[@]+"${flags[@]}"}); OP_KIND=update
        if [ ${#hosts[@]} -eq 0 ] || [[ " ${hosts[*]} " == *" $me "* ]]; then OP_LOCK=own; OP_SET=1; fi   # this box's leg is a recycle
        if [ ${#hosts[@]} -eq 0 ] && [ ${#flags[@]} -eq 0 ]; then OP_PLAN_NOTE="this box: claude update ($(claude_ver) → the latest release), then every pane relaunched (= recycle --update --force)"
        elif [ ${#flags[@]} -gt 0 ]; then OP_PLAN_NOTE="every fleet host (${SALA_FLEET_HOSTS:-none configured}), then this box ($me): hosts checked by name here, not over ssh (a sleeping one is skipped, not failed)"
        else OP_PLAN_NOTE="hosts: ${hosts[*]} — checked by name against the fleet list, not over ssh (a sleeping one is skipped, not failed)"; fi ;;
    revive)
        while [ $# -gt 0 ]; do case "$1" in
            --only) op_session_ok "${2:-}" || return 1; only+=("$2"); shift ;;
            --force) flags=(--force) ;;
            *) op_bad "revive takes --only NAME and --force only, not '$1'"; return 1 ;;
        esac; shift; done
        for s in ${only[@]+"${only[@]}"}; do OP_RUN+=(--only "$s"); done
        OP_RUN=(revive ${OP_RUN[@]+"${OP_RUN[@]}"} ${flags[@]+"${flags[@]}"}); OP_PLAN=("${OP_RUN[@]}" --dry-run); OP_LOCK=own; OP_SET=1; OP_TARGETS="${only[*]-}" ;;
    retire)
        local byid=""
        [ $# -ge 1 ] || { op_bad "retire needs a session name (or --id <conversation-id>)"; return 1; }
        if [ "$1" = --id ]; then
            [ $# -ge 2 ] || { op_bad "retire --id needs a conversation id"; return 1; }
            byid="$2"; shift 2
        else op_session_ok "$1" || return 1; name="$1"; shift; fi
        while [ $# -gt 0 ]; do case "$1" in
            --keep-web|--busy|--skip-writeup|--self|--leave-items) flags+=("$1") ;;
            --force) op_bad "retire has no --force any more: use --busy (retire a session that is not idle) or --skip-writeup (retire a side session before \`sala side done\`)"; return 1 ;;
            *) op_bad "retire takes --keep-web, --busy, --skip-writeup, --self and --leave-items only, not '$1'"; return 1 ;;
        esac; shift; done
        if [ -n "$byid" ]; then
            # the session is resolved from the conversation id only at run time (retire's registry_resolve), so what it touches is not known here: solo, no target named
            case "$byid" in ''|-*|*[[:space:]]*) op_bad "'$byid' is not a conversation id"; return 1 ;; esac
            OP_RUN=(retire --id "$byid" ${flags[@]+"${flags[@]}"}); OP_PLAN=("${OP_RUN[@]}" --dry-run); OP_TARGETS=""
        else
            OP_RUN=(retire "$name" ${flags[@]+"${flags[@]}"}); OP_PLAN=("${OP_RUN[@]}" --dry-run); OP_TARGETS="$name"
            # PARALLEL: yes, when the name is a live tmux session, which is all retire acts on
            tmux has-session -t "=$name" 2>/dev/null && OP_PAR=par
            if [ -n "${SALA_MASTER:-}" ] && [ "$name" = "$SALA_MASTER" ]; then   # the master itself (the header): unset, then retire
                OP_UNSET_MASTER="$name"
                OP_PLAN_NOTE="would unset SALA_MASTER, then retire: '$name' is the master session the watchdog keeps alive (salamander master --unset first, so nothing heals, recreates or bridges it again; the post-boot report goes to Slack, \`sala cue\` points to this queue, and a Claude session's raw fleet verb is refused with the same pointer)"
            fi
        fi ;;
    close-shell|forget-row)
        [ $# -ge 1 ] || { op_bad "$verb needs a session name"; return 1; }
        op_session_ok "$1" || return 1; name="$1"; shift
        while [ $# -gt 0 ]; do case "$1" in
            --busy) [ "$verb" = close-shell ] || { op_bad "forget-row takes no flags, not '$1'"; return 1; }; flags+=("$1") ;;
            *) op_bad "$verb takes $([ "$verb" = close-shell ] && echo '--busy only' || echo 'no flags'), not '$1'"; return 1 ;;
        esac; shift; done
        OP_RUN=("$verb" "$name" ${flags[@]+"${flags[@]}"}); OP_PLAN=("${OP_RUN[@]}" --dry-run); OP_TARGETS="$name"
        # PARALLEL: yes, the name is a tmux session name or a pane-map row as it stands
        { tmux has-session -t "=$name" 2>/dev/null || [ -n "$(ledger_row "$name")" ]; } && OP_PAR=par
        if [ -n "${SALA_MASTER:-}" ] && [ "$name" = "$SALA_MASTER" ]; then
            OP_UNSET_MASTER="$name"
            OP_PLAN_NOTE="would unset SALA_MASTER, then $verb: '$name' is the master session the watchdog keeps alive (salamander master --unset first)"
        fi ;;
    rename)
        [ $# -eq 2 ] || { op_bad "rename takes exactly OLD NEW"; return 1; }
        op_session_ok "$1" && op_session_ok "$2" || return 1
        OP_RUN=(rename "$1" "$2"); OP_PLAN=("${OP_RUN[@]}" --dry-run); OP_TARGETS="$1 $2"
        # PARALLEL: yes, both names are tmux session names (rename takes no other); the master's rename rewrites the config (master --set): solo
        if [ -z "${SALA_MASTER:-}" ] || { [ "$1" != "$SALA_MASTER" ] && [ "$2" != "$SALA_MASTER" ]; }; then OP_PAR=par; fi ;;
    lane)
        [ $# -ge 2 ] || { op_bad "lane takes <lane> <session>…, <lane> --all, default <lane>, or fallback <lane>"; return 1; }
        if [ "$1" = fallback ]; then
            # the dormant lane's whole population to its fallback (lib/lane.sh, THE LANE FALLBACK): who moves is read at run time, so no target is named
            [ $# -eq 2 ] || { op_bad "lane fallback takes one lane, nothing else"; return 1; }
            lane_known "$2" || { op_bad "'$2' is not a lane (one of: $SALA_LANES_KNOWN)"; return 1; }
            _lane_norm_r lane "$2"; OP_RUN=(lane fallback "$lane"); OP_LOCK=own; OP_SET=1
        elif [ "$1" = default ]; then
            lane_known "$2" || { op_bad "'$2' is not a lane (one of: $SALA_LANES_KNOWN)"; return 1; }
            [ $# -eq 2 ] || { op_bad "lane default takes one lane, nothing else"; return 1; }
            _lane_norm_r lane "$2"; OP_RUN=(lane default "$lane")
        else
            lane_known "$1" || { op_bad "'$1' is not a lane (one of: $SALA_LANES_KNOWN)"; return 1; }
            _lane_norm_r lane "$1"; shift   # a renamed lane's old name is accepted and queued under the current one
            if [ "$1" = --all ]; then [ $# -eq 1 ] || { op_bad "lane <lane> --all takes nothing else"; return 1; }; OP_RUN=(lane "$lane" --all); OP_LOCK=own; OP_SET=1
            else for s in "$@"; do op_session_ok "$s" || return 1; sess+=("$s"); done
                 OP_RUN=(lane "$lane" "${sess[@]}"); OP_LOCK=own; OP_SET=1; OP_TARGETS="${sess[*]}"; fi
        fi
        OP_PLAN=("${OP_RUN[@]}" --dry-run) ;;
    model)
        # the model and effort the sessions are relaunched on (the header; lib/model.sh): recorded, then each session switched
        # or relaunched on them. The checks are model.sh's own (model_valid, effort_known, model_batch_shape); the sessions
        # themselves are checked by the plan (model … --dry-run refuses an unknown one, and with it the whole operation).
        # --record-only, --not-master and --dry-run are not queue arguments.
        local model="" effort=""
        [ $# -ge 2 ] || { op_bad "model takes <model> [--effort <level>] <session>… (several sessions, one notice), <session> <model> [--effort <level>], <session> --clear, or --clear <session>…"; return 1; }
        if [ "$1" = --clear ]; then   # the batch clear: --clear <session>…
            shift
            for s in "$@"; do op_session_ok "$s" || return 1; case " ${sess[*]-} " in *" $s "*) ;; *) sess+=("$s");; esac; done
            OP_RUN=(model --clear "${sess[@]}"); OP_TARGETS="${sess[*]}"   # drops rows: no relaunch, so the runner keeps the lock and no set follows
            OP_PLAN_NOTE="would drop the model record of ${sess[*]}: the next relaunch of each takes its transcript's model and effort again (nothing is relaunched now); one result for all"
        elif model_batch_shape "$@"; then   # the batch: <model> [--effort <level>] <session>…
            model="$1"; shift
            while [ $# -gt 0 ]; do case "$1" in
                --effort) [ -z "$effort" ] || { op_bad "model takes --effort once"; return 1; }
                          effort_known "${2:-}" || { op_bad "'${2:-}' is not an effort (one of: $SALA_EFFORTS_KNOWN)"; return 1; }
                          effort="$2"; shift ;;
                -*) op_bad "model takes <model> [--effort <level>] <session>…, not '$1'"; return 1 ;;
                *) op_session_ok "$1" || return 1; case " ${sess[*]-} " in *" $1 "*) ;; *) sess+=("$1");; esac ;;
            esac; shift; done
            [ ${#sess[@]} -gt 0 ] || { op_bad "model $model needs at least one session: model <model> [--effort <level>] <session>…"; return 1; }
            OP_RUN=(model "$model"); [ -n "$effort" ] && OP_RUN+=(--effort "$effort"); OP_RUN+=("${sess[@]}")
            OP_LOCK=own; OP_SET=1; OP_TARGETS="${sess[*]}"
            OP_PLAN_NOTE="would record the model for ${#sess[@]} session(s), then switch each pane in place when it is idle with an empty input box (its saved defaults put back), else relaunch it; the relaunches go together, in one sweep, and the result is one notice with a line per session; the plan below says which path each takes"
        else   # the single-session shape, as it was: <session> <model> [--effort <level>] | <session> --clear
            op_session_ok "$1" || return 1; name="$1"; shift
            if [ "$1" = --clear ]; then
                [ $# -eq 1 ] || { op_bad "model <session> --clear takes nothing else"; return 1; }
                OP_RUN=(model "$name" --clear); OP_TARGETS="$name"   # drops a row: no relaunch, so the runner keeps the lock and no set follows
                OP_PLAN_NOTE="would drop the model record of '$name': its next relaunch takes its transcript's model and effort again (nothing is relaunched now)"
            else
                case "$1" in -*) op_bad "model takes a model (one of: $SALA_MODEL_FAMILIES, or a full id claude-…), not '$1'"; return 1;; esac
                model_valid "$1" || { op_bad "'$1' is not a model (one of: $SALA_MODEL_FAMILIES, or a full model id: claude- then lowercase letters, digits, dots, dashes)"; return 1; }
                model="$1"; shift
                while [ $# -gt 0 ]; do case "$1" in
                    --effort) [ -z "$effort" ] || { op_bad "model takes --effort once"; return 1; }
                              effort_known "${2:-}" || { op_bad "'${2:-}' is not an effort (one of: $SALA_EFFORTS_KNOWN)"; return 1; }
                              effort="$2"; shift ;;
                    *) op_bad "model takes <model> [--effort <level>] <session>… or <session> <model> [--effort <level>] or <session> --clear, not '$1'"; return 1 ;;
                esac; shift; done
                OP_RUN=(model "$name" "$model"); [ -n "$effort" ] && OP_RUN+=(--effort "$effort")
                OP_LOCK=own; OP_SET=1; OP_TARGETS="$name"
                OP_PLAN_NOTE="would record the model, then switch the pane in place when it is idle with an empty input box (its saved defaults put back), else relaunch it; the plan below says which"
            fi
        fi
        OP_PLAN=("${OP_RUN[@]}" --dry-run) ;;
    provision)
        while [ $# -gt 0 ]; do case "$1" in
            --only) [[ "${2:-}" =~ ^[A-Za-z0-9_-]+(,[A-Za-z0-9_-]+)*$ ]] || { op_bad "provision --only takes step names joined by commas, e.g. --only settings,deploy"; return 1; }; steps="$2"; shift ;;
            -*) op_bad "provision takes --only STEP[,STEP…] and host names only, not '$1'"; return 1 ;;
            *) op_host_ok "$1" || return 1; hosts+=("$1") ;;
        esac; shift; done
        OP_RUN=(provision ${steps:+--only "$steps"} ${hosts[@]+"${hosts[@]}"}); OP_KIND=provision
        [ ${#hosts[@]} -eq 0 ] && { OP_LOCK=own; OP_SET=1; }   # the whole fleet: its last act is a recycle of this box
        OP_PLAN_NOTE="$([ ${#hosts[@]} -eq 0 ] && echo "every fleet host (${SALA_FLEET_HOSTS:-none configured}), then this box ($me), then recycle --update --force" || echo "hosts: ${hosts[*]} (no recycle)")${steps:+ · steps: $steps} — hosts checked by name against the fleet list, not over ssh" ;;
    spawn)
        # a project agent's session (the header): the cheap checks here, the page checks in the plan (spawn --dry-run)
        local project="" role="" mandate="" mkind="" slane="" model="" effort="" cwd="" go="" side="" forkof="" item="" agents=""
        [ $# -ge 1 ] || { op_bad "spawn needs a session name first: spawn NAME --project <page key> --role front|back [--mandate FILE|TEXT] … (or spawn NAME --side …)"; return 1; }
        case "$1" in -*) op_bad "spawn needs a session name first, not '$1'"; return 1;; esac
        name="$1"; shift
        agent_name_ok "$name" || { op_bad "'$name' is not an agent name: lowercase letters, digits and dashes only, no dash at either end, at most $SALA_AGENT_NAME_MAX characters (salamander spawn --suggest-name --project <key> --role <role>, or --side …, suggests one)"; return 1; }
        while [ $# -gt 0 ]; do case "$1" in
            --project) project="${2:-}"; shift ;;
            --role) role="${2:-}"; shift ;;
            --mandate|--brief|--prompt) mkind="$1"; mandate="${2-}"; shift ;;
            --lane) slane="${2:-}"; shift ;;
            --model) model="${2:-}"; shift ;;
            --effort) effort="${2:-}"; shift ;;
            --cwd) cwd="${2:-}"; shift ;;
            --no-confirm) go=1 ;;
            --side) side=1 ;;
            --fork-of) forkof="${2:-}"; shift ;;
            --item) item="${2:-}"; shift ;;
            --agents) agents="${2:-}"; shift ;;
            *) op_bad "spawn takes --project, --role, --mandate (or --brief, --prompt), --lane, --model, --effort, --cwd and --no-confirm (a side conversation: --side, --fork-of, --item, --agents), not '$1'"; return 1 ;;
        esac; shift 2>/dev/null || break; done
        if [ -n "$side" ]; then   # a side conversation (the header): no page, no role, no mandate required; exactly one of a fork and a project
            [ -z "$role" ] || { op_bad "a side conversation takes no --role: it is on no page's agents map"; return 1; }
            case "$name" in *-side-?*) ;; *) op_bad "a side session's name contains -side- (<prefix>-side-<word><nn>), not '$name' (salamander spawn --suggest-name --side --fork-of AGENT | --project KEY suggests one)"; return 1;; esac
            if [ -n "$forkof" ]; then
                [ -z "$project" ] && [ -z "$agents" ] || { op_bad "--fork-of takes no --project and no --agents: a fork continues one agent's conversation"; return 1; }
                op_session_ok "$forkof" || return 1
            else
                page_key_ok "$project" || { op_bad "a side conversation needs --fork-of AGENT, or --project <page key> --item board#N — <dir>/<slug> with the dir one of ${SALA_PAGE_DIRS// /, } — not '${project:-nothing}'"; return 1; }
                [ -n "$item" ] || { op_bad "a side conversation about a project needs --item board#N: the item it is about"; return 1; }
            fi
            [ -z "$item" ] || item_id_ok "$item" || { op_bad "--item takes a board item id as shown (board#N, sN, board-tmp-box#N), not '$item'"; return 1; }
            [ -z "$agents" ] || [[ "$agents" =~ ^[a-z0-9-]+(,[a-z0-9-]+)*$ ]] || { op_bad "--agents takes agent names joined by commas (lowercase letters, digits, dashes), not '$agents'"; return 1; }
        else
            [ -z "$forkof$item$agents" ] || { op_bad "--fork-of, --item and --agents go with --side"; return 1; }
            page_key_ok "$project" || { op_bad "spawn needs --project <page key> — <dir>/<slug> with the dir one of ${SALA_PAGE_DIRS// /, }, lowercase letters, digits and dashes (projects/site-redesign, projects/demo) — not '${project:-nothing}'"; return 1; }
            case "$role" in front|back) ;; *) op_bad "spawn needs --role front or --role back, not '${role:-nothing}'"; return 1;; esac
        fi
        [ -z "$mkind" ] || [ -n "$mandate" ] || { op_bad "$mkind needs a file or text, not an empty argument"; return 1; }
        [ "$role" = back ] && [ -z "$mandate" ] && { op_bad "a back agent needs --mandate FILE|TEXT (a background agent reads its mandate at its first prompt, and nobody briefs it)"; return 1; }
        [ "$mkind" = --brief ] && { [ -f "$mandate" ] && [ -r "$mandate" ] || { op_bad "--brief needs a readable file, not '$mandate' (text goes with --mandate or --prompt)"; return 1; }; }
        [ -z "$slane" ] || lane_known "$slane" || { op_bad "'$slane' is not a lane (one of: $SALA_LANES_KNOWN)"; return 1; }
        case "$effort" in ""|low|medium|high|xhigh|max) ;; *) op_bad "invalid --effort '$effort'"; return 1;; esac
        case "$model" in *[!A-Za-z0-9._-]*) op_bad "invalid --model '$model'"; return 1;; esac
        [ -z "$cwd" ] || [ -d "$cwd" ] || { op_bad "--cwd '$cwd' is not a directory"; return 1; }
        if [ -n "$side" ]; then
            OP_RUN=(spawn "$name" --side)
            if [ -n "$forkof" ]; then OP_RUN+=(--fork-of "$forkof"); else OP_RUN+=(--project "$project"); fi
            [ -n "$item" ] && OP_RUN+=(--item "$item"); [ -n "$agents" ] && OP_RUN+=(--agents "$agents")
        else OP_RUN=(spawn "$name" --project "$project" --role "$role"); fi
        [ -n "$mandate" ] && OP_RUN+=("$mkind" "$mandate")
        [ -n "$slane" ] && { _lane_norm_r slane "$slane"; OP_RUN+=(--lane "$slane"); }; [ -n "$model" ] && OP_RUN+=(--model "$model"); [ -n "$effort" ] && OP_RUN+=(--effort "$effort")
        [ -n "$cwd" ] && OP_RUN+=(--cwd "$cwd"); [ -n "$go" ] && OP_RUN+=(--no-confirm)
        OP_PLAN=("${OP_RUN[@]}" --dry-run); OP_TARGETS="$name"
        # PARALLEL: yes. It makes the one session $name; a fork also reads the conversation of the agent it forks, so that name is
        # held too (a retire or rename of the source waits for the fork to start, and the conflict check at queue time is unchanged)
        OP_PAR=par; OP_KEYS="$name${forkof:+ $forkof}"
        if [ -n "$side" ]; then
            OP_PLAN_NOTE="a side conversation, on no agents map ($([ -n "$forkof" ] && echo "a fork of $forkof's live conversation" || echo "a fresh session about $item of $project")): the dry run finds the agent to fork or the project's page, and checks the name is not live and the lane can launch; the session is made at run time and retires only on ${SALA_OWNER_NAME}'s word, once it ran \`sala side done\`"
        else
        OP_PLAN_NOTE="a new $role agent of $project: the dry run checks that the page exists and lists the name (a name not on the page refuses the operation: exit 3 and the ADD-TO-PAGE: block), that the name is not live and that the lane can launch; the session is made at run time"
        fi ;;
    reboot)
        [ $# -eq 0 ] || { op_bad "reboot takes no argument (it is reboot --go, the clean reboot protocol)"; return 1; }
        OP_RUN=(reboot --go); OP_PLAN=(reboot --status); OP_KIND=reboot
        OP_PLAN_NOTE="the clean reboot protocol (docs/reboot-contract.md): pause inbound, drain every pane, flush and stop the hooks, reboot; the box comes back on its own and its boot half resumes everything" ;;
    *) op_bad "unknown verb '${verb:-}' (one of: $SALA_OP_VERBS)"; return 1 ;;
    esac
    # the declaration, checked once for every verb (THE PARALLEL RULE, the header): a par verb that names nothing, or that holds the
    # runner's lock for a master change, is solo; one that stays par takes the recycle lock SHARED
    if [ "$OP_PAR" = par ]; then
        [ -n "$OP_KEYS" ] || OP_KEYS="$OP_TARGETS"
        if [ -z "${OP_KEYS// /}" ] || [ -n "$OP_UNSET_MASTER" ] || [ "$OP_LOCK" != hold ]; then OP_PAR=solo; OP_KEYS=""; else OP_LOCK=share; fi
    fi
    return 0
}
op_targets_of() { ( op_shape "$@" >/dev/null 2>&1; echo "$OP_TARGETS" ); }   # <verb> [args…] → the sessions it names (in a subshell: the OP_* of the caller stay)
op_targets() { local a; mapfile -t a < <(op_vals "$1" arg); op_targets_of "$(op_val "$1" verb)" ${a[@]+"${a[@]}"}; }   # <id> → the same
op_conflict_with() {  # <verb> <targets> [id to skip] → the id of a queued, running or waiting operation of another verb (or of a spawn) naming one of the sessions; 1 when none
    local verb="$1" mine="$2" skip="${3:-}" t o ot f
    [ -n "$mine" ] || return 1
    for f in $(op_files); do
        o=${f##*/}; o=${o%.op}; [ "$o" != "$skip" ] || continue
        case "$(op_val "$o" state)" in queued|running|waiting) ;; *) continue;; esac
        # two of one verb are no conflict (two recycles fold, a second retire finds the first's result) — except two spawns of
        # one name: the first makes the session and the second can only fail on it, so it is refused as naming the same session
        [ "$(op_val "$o" verb)" != "$verb" ] || [ "$verb" = spawn ] || continue
        ot=$(op_targets "$o"); for t in $mine; do case " $ot " in *" $t "*) echo "$o"; return 0;; esac; done
    done
    return 1
}
op_conflict() { op_conflict_with "$(op_val "$1" verb)" "$(op_targets "$1")" "$1"; }   # <id> → as above, for a marker

# ── the hearer's side: queue, plan, list, status, cancel ─────────────────────
# the header's usage block, anchored on its first and last lines (a fixed line range drifts when the header grows)
op_usage() {
    awk '/^#   salamander op /{p=1} p{print} /^#   salamander watch --ops/{exit}' "$SALA_ROOT/lib/op.sh" | sed 's/^# \{0,1\}//'
    echo "verbs:"; op_shapes
}
op_kick() {  # <id> — the watch runs the queue within seconds: the service started now, or a one-off `watch --ops` after a tick already running
    command -v systemctl >/dev/null 2>&1 || { echo "   no systemctl here: the next \`salamander watch\` run starts it"; return 0; }
    local st; st=$(systemctl --user is-active sala-watch.service 2>/dev/null)
    case "$st" in
        active|activating|reloading)
            if command -v systemd-run >/dev/null 2>&1 && systemd-run --user --quiet --collect --on-active=10 --unit="sala-op-kick-$1" "$SALA_BIN" watch --ops 2>/dev/null; then
                echo "   a watch tick is running now: a \`watch --ops\` follows in 10 s (unit sala-op-kick-$1)"
            else echo "   a watch tick is running now and no follow-up could be scheduled: the timer's next tick (2 min) starts it"; fi ;;
        *) if systemctl --user start --no-block sala-watch.service 2>/dev/null; then echo "   sala-watch.service started: the queue runs within seconds"
           else echo "   ⚠ sala-watch.service could not be started: the timer's next tick (2 min) runs the queue"; fi ;;
    esac
    return 0
}
op_kick_end() {  # the end of an operation: another is still queued → one `watch --ops` in SALA_OP_KICK_END s (unit sala-op-kick-end: a pending one is not stacked)
    [ -z "${OP_KICK_SENT:-}" ] || return 0   # once per process: op_finish and the runner's exit both ask
    [ "$SALA_OP_QUEUE" = on ] || return 0
    command -v systemd-run >/dev/null 2>&1 || return 0   # no systemd (macOS): the watch's own interval
    local f id
    for f in $(op_files); do
        id=${f##*/}; id=${id%.op}; [ "$(op_val "$id" state)" = queued ] || continue
        OP_KICK_SENT=1
        systemd-run --user --quiet --collect --on-active="$SALA_OP_KICK_END" --unit="sala-op-kick-end" "$SALA_BIN" watch --ops 2>/dev/null \
            && op_log "op queue: op $id is queued behind an operation that ended — a watch --ops follows in $SALA_OP_KICK_END s (unit sala-op-kick-end)"
        return 0
    done
    return 0
}
op_list() {
    local f id n=0
    for f in $(op_files); do
        id=${f##*/}; id=${id%.op}; n=$((n+1))
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$(op_val "$id" state)" "$(op_line "$id")" "$(op_val "$id" from)" "$(local_human "$(op_val "$id" time)")" "$(op_words_of "$id")"
    done
    [ "$n" -gt 0 ] || echo "no operations queued (archive: $SALA_OP_DONE)"
}
op_status() {
    [ -n "${1:-}" ] || die "usage: salamander op --status <id>"
    local f; f=$(op_file "$1"); [ -f "$f" ] || die "no operation '$1' (salamander op --list; archive: $SALA_OP_DONE)"
    sed 's/=/: /' "$f"; [ -f "$(op_oplog "$1")" ] && echo "log: $(op_oplog "$1")"; return 0
}
op_cancel() {
    [ -n "${1:-}" ] || die "usage: salamander op --cancel <id>"
    [ -f "$SALA_OP_DIR/$1.op" ] || die "no queued operation '$1' (salamander op --list)"
    local st; st=$(op_val "$1" state)
    [ "$st" = queued ] || die "op $1 is $st (unit $(op_val "$1" unit)), not queued — it cannot be dropped from here; its result will say what it did"
    op_put "$1" state cancelled; op_put "$1" ended "$(date +%s)"; op_put "$1" result "cancelled by $(op_hearer)"
    op_log "op $1 cancelled by $(op_hearer): $(op_line "$1")"; op_archive "$1"; echo "dropped op $1 ($(op_line "$1")); its marker is archived under $SALA_OP_DONE"
    local m; for m in $(op_mandate_files "$1"); do rm -f "$m"; done   # a spawn's mandate nobody will read
}
op_mandate_to_file() {  # <id> <name> — THE MANDATE'S TRANSPORT (the header): a spawn's TEXT mandate in args[] → a file, the path in its place
    local i f
    for ((i=0; i<${#args[@]}; i++)); do
        case "${args[i]}" in --mandate|--prompt) ;; *) continue;; esac
        f="${args[i+1]-}"; [ -n "$f" ] || return 0
        [ "${args[i]}" = --mandate ] && [ -f "$f" ] && [ -r "$f" ] && return 0   # a file given: passed as it is
        mkdir -p "$SALA_MANDATE_DIR" 2>/dev/null || { echo "✗ could not make $SALA_MANDATE_DIR" >&2; return 1; }
        OP_MANDATE_FILE="$SALA_MANDATE_DIR/$1-$2.md"
        printf '%s\n' "$f" > "$OP_MANDATE_FILE" || { echo "✗ could not write $OP_MANDATE_FILE" >&2; return 1; }
        args[i]=--mandate; args[i+1]="$OP_MANDATE_FILE"
        return 0
    done
    return 0
}
op_main() {
    local verb="" args=() from="" words="" nowords="" ownrow="" item="" why="" stdin=0 auto=0 mode=add id f ep out rc c _na _i _r
    OP_REASON_WHY=""; OP_OWN_WHY=""
    [ $# -gt 0 ] || { op_usage >&2; return 2; }
    case "$1" in
        --list) op_list; return ;; --status) op_status "${2:-}"; return ;; --cancel) op_cancel "${2:-}"; return ;;
        --run) trap op_kick_end EXIT; op_run "${2:-}"; return ;; --settle) trap op_kick_end EXIT; op_settle "${2:-}" "${3:-}"; return ;; --stuck) trap op_kick_end EXIT; op_stuck_main "${2:-}"; return ;;
        --plan) mode=plan; shift ;;
        -h|--help) op_usage; return 0 ;;
    esac
    while [ $# -gt 0 ]; do case "$1" in
        --from) from="${2:-}"; [ -n "$from" ] || die "--from needs a session name"; shift ;;
        --words) words="${2-}"; shift ;;
        --stdin) stdin=1 ;;
        --auto) auto=1 ;;
        *) if [ -z "$verb" ]; then verb="$1"; else args+=("$1"); fi ;;
    esac; shift; done
    [ -n "$verb" ] || { op_usage >&2; return 2; }
    if [ "$verb" != spawn ]; then   # --item and --why: the reason a no-words revive carries (THE WORDS POLICY, the header). spawn --side has its own --item (a board item, passed through to the verb)
        _na=()
        for ((_i=0; _i<${#args[@]}; _i++)); do
            case "${args[_i]}" in
                --item) [ -z "$item" ] || { op_bad "--item given twice"; return 2; }
                        item="${args[_i+1]-}"; _i=$((_i+1))
                        [ -n "$item" ] || { op_bad "--item needs a board item id (board#N)"; return 2; } ;;
                --why)  [ -z "$why" ] || { op_bad "--why given twice"; return 2; }
                        why="${args[_i+1]-}"; _i=$((_i+1))
                        [ -n "$why" ] || { op_bad "--why needs a reason in words (one line, three words or more)"; return 2; } ;;
                *) _na+=("${args[_i]}") ;;
            esac
        done
        args=(${_na[@]+"${_na[@]}"})
    fi
    if [ -n "$item" ] || [ -n "$why" ]; then
        [ "$verb" = revive ] || { op_bad "--item and --why are accepted only with revive (\`op revive --only NAME --item board#N\`, or --why \"<reason>\"), not with $verb: every other verb needs ${SALA_OWNER_NAME}'s words (--words \"…\")"; return 2; }
        { [ -z "$item" ] || [ -z "$why" ]; } || { op_bad "give the reason as --item board#N or --why \"…\", not both"; return 2; }
        if [ -n "$item" ]; then op_item_ok "$item" || { op_bad "'$item' is not a board item id (board#N, digits only)"; return 2; }
        else op_why_ok "$why" || { op_bad "$OP_REASON_WHY"; return 2; }; why=$(op_one_line "$why"); fi
    fi
    ep=$(date +%s); id="$ep-$$"; OP_MANDATE_FILE=""
    if [ "$verb" = spawn ] && [ "$mode" = add ] && [ ${#args[@]} -gt 0 ]; then   # the TEXT mandate into its file before the shape check, so the marker carries the path
        case "${args[0]}" in -*) ;; *) op_mandate_to_file "$id" "${args[0]}" || return 2 ;; esac
    fi
    op_shape "$verb" ${args[@]+"${args[@]}"} || { echo "the shapes:" >&2; op_shapes >&2; [ -n "$OP_MANDATE_FILE" ] && rm -f "$OP_MANDATE_FILE"; return 2; }
    if [ "$verb" = reboot ] && [ "$SALA_OP_REBOOT" != on ]; then
        die "reboot is not queued: ${SALA_OWNER_NAME} runs \`sala reboot --go\` in the web UI's Shell; a session shows \`sala reboot --status\` and waits for the word (SALA_OP_REBOOT is off by default and unsupported until a confirmation path is built)"
    fi
    if [ "$mode" = add ]; then
        [ "$stdin" = 1 ] && words=$(cat)
        words=$(op_one_line "$words")
        [ -n "$from" ] || from=$(op_hearer); from=$(op_one_line "$from")
        if [ -z "$words" ]; then
            if [ "$auto" = 1 ]; then
                op_from_claude && die "--auto is for markers sala writes itself; a Claude session passes ${SALA_OWNER_NAME}'s words: --words \"…\""
                [ -z "$item$why" ] || die "--auto is for markers sala writes itself and carries no --item or --why: a session's no-words revive is \`op revive --only NAME --item board#N --from YOU\`, without --auto"
            else
                # THE WORDS POLICY (op_words_policy, the header): what a marker with no words needs, by verb and arguments
                op_words_policy "$verb" ${args[@]+"${args[@]}"}
                case "$OP_POLICY" in
                    throwaway)   # the one operation a session queues with none, first door: it ends a throwaway
                        if op_own_flags_ok "${args[@]}" && op_own_retire_ok "$OP_TARGETS" "$from"; then nowords=$(op_own_note); ownrow=$OP_OWN_ROWID; fi ;;
                    reason)      # the other: it revives sessions, with a reason on the record
                        if op_reason_revive_ok "$from" "$item" "$why" ${args[@]+"${args[@]}"}; then
                            nowords=$(op_reason_note "$item" "$why" "${#OP_REASON_ROWIDS[@]}"); ownrow=$(printf '%s\n' "${OP_REASON_ROWIDS[@]}"); fi ;;
                esac
                [ -n "$nowords" ] || die "no --words: the queue takes an operation only with ${SALA_OWNER_NAME}'s words on it, verbatim (--words \"…\", or --stdin); a marker with none is refused. The one exception: \`op retire NAME --from YOU\` with no words, for a throwaway (no project, role or side, on no agents map): any session may end one whose row carries the throwaway tag (a bare \`sala spawn\` sets it), between turns; for a row without the tag YOU may end the one YOU started, the master one whose name is scratch-*, *-check-*, *-test-* or *-probe-*, and any session one with no live spawner and such a name; never with a bypass flag, --keep-web or --id, and only when the project record confirms the name is on no agents map. The one other: \`op revive --only NAME [--only NAME]… [--force] --from YOU\` with --item board#N or --why \"<one line>\" and no words, for live sessions that are not the master and not YOU (never a sweep)${OP_OWN_WHY:+; refused here: $OP_OWN_WHY}${OP_REASON_WHY:+; refused here: $OP_REASON_WHY}"
            fi
        fi
    fi
    # a retire of the asker's own session needs --self (a no-words retire of it was refused above, with its own sentence)
    if [ "$verb" = retire ] && [ -n "$OP_TARGETS" ]; then op_self_retire_ok "$OP_TARGETS" ${args[@]+"${args[@]}"} || die "refused: $OP_SELF_WHY"; fi
    # a rename of the asker's own pane (this very pane's session, or the --from it was queued as): the queued run has no pane of its own
    # to be refused, so it types /rename itself once the asker's turn is over; the note says so, as the dry run below shows the runner's path
    OP_RENAME_SELF=0
    if [ "$verb" = rename ] && { [ "${OP_RUN[1]}" = "$from" ] || { [ -n "${TMUX_PANE:-}" ] && [ "${OP_RUN[1]}" = "$(op_hearer)" ]; }; }; then
        OP_RENAME_SELF=1
        OP_PLAN_NOTE="'${OP_RUN[1]}' is the pane asking. The queued operation runs outside every pane, so it types /rename ${OP_RUN[2]} into it itself once the pane is idle (right after this turn ends), trying again every minute for up to 2 hours, and posts the result. Nothing is left for ${SALA_OWNER_NAME} to type."
    fi
    echo "plan: salamander ${OP_RUN[*]}"
    [ -n "$OP_PLAN_NOTE" ] && echo "   $OP_PLAN_NOTE"
    if [ ${#OP_PLAN[@]} -gt 0 ]; then
        # SALA_OP_PLAN=1: the dry run of the master's own retire says "would unset first" and goes on (lib/retire.sh), as
        # the runner will; every other dry run ignores it
        # the hearer and the owner's words reach the dry run too (SALA_OP_FROM, SALA_OP_WORDS): spawn's message to a page's keeper names them
        # a model switch's and a rename's plan run without TMUX_PANE: the runner's unit has none, so a switch of the asker's own
        # session is relaunched there by `revive --force --only`, and a rename of it is typed from outside once the pane is idle;
        # the plan shows that verdict, not the direct run's path (model.sh's `revive --self`, rename.sh's "nothing typed")
        out=$(case "$verb" in model|rename) unset TMUX_PANE;; esac; SALA_OP_PLAN=1 SALA_OP_FROM="$from" SALA_OP_WORDS="$words" "$SALA_BIN" "${OP_PLAN[@]}" 2>&1 9>&-); rc=$?
        printf '%s\n' "$out" | sed 's/^/   /'
        if [ "$rc" != 0 ]; then
            [ -n "$OP_MANDATE_FILE" ] && rm -f "$OP_MANDATE_FILE"
            echo "✗ refused: the plan (salamander ${OP_PLAN[*]}) did not pass (exit $rc) — nothing queued" >&2
            case "$verb:$rc" in spawn:3|spawn:4)   # the web layer reads the marker block (lib/spawn.sh): once more, unindented, and the verb's own exit code
                printf '%s\n' "$out" | sed -n '/^\(ADD-TO-PAGE\|NO-PAGE\): /,$p'; return "$rc" ;; esac
            return 1
        fi
    fi
    [ "$mode" = plan ] && { echo "plan only: nothing queued"; return 0; }
    mkdir -p "$SALA_OP_DIR"
    if c=$(op_conflict_with "$verb" "$OP_TARGETS"); then
        [ -n "$OP_MANDATE_FILE" ] && rm -f "$OP_MANDATE_FILE"
        die "refused: op $c ($(op_line "$c"), from $(op_val "$c" from), $(op_val "$c" state)) names the same session; say the words again once it is done (salamander op --list), or drop it (salamander op --cancel $c)"
    fi
    f="$SALA_OP_DIR/$id.op"
    { printf 'id=%s\ntime=%s\nfrom=%s\nwords=%s\nverb=%s\n' "$id" "$ep" "$from" "$words" "$verb"
      for c in ${args[@]+"${args[@]}"}; do printf 'arg=%s\n' "$c"; done
      [ "$auto" = 1 ] && printf 'auto=1\n'; [ -n "$nowords" ] && printf 'nowords=%s\n' "$nowords"; [ -n "$ownrow" ] && while IFS= read -r _r; do printf 'ownrow=%s\n' "$_r"; done <<< "$ownrow"   # one per row id (a no-words revive of several sessions: in the order of its --only)
      [ -n "$item" ] && printf 'item=%s\n' "$item"; [ -n "$why" ] && printf 'reason=%s\n' "$why"   # (reason=, not why=: the runner's own why= is the stuck handler's)
      printf 'state=queued\n'; } > "$f.tmp" && mv -f "$f.tmp" "$f" || die "could not write $f"
    op_log "op $id queued by $from: $(op_line "$id")${words:+ — \"$words\"${item:+ [$item]}${why:+ [reason: $why]}}${nowords:+ — $nowords}"
    echo "queued op $id: salamander ${OP_RUN[*]} — from $from${words:+, \"$words\"${item:+ [$item]}${why:+ [reason: $why]}}${nowords:+, $nowords}"
    if [ "$SALA_OP_QUEUE" = on ]; then op_kick "$id"; else echo "   ⚠ SALA_OP_QUEUE is off in $SALA_CONFIG: nothing starts it until it is on"; fi
    echo "   the result comes as one Slack post and one line into $from's inbox; salamander op --status $id shows its record"
    case "$verb" in recycle|update|provision) [ -n "${TMUX_PANE:-}" ] && echo "   this pane ('$from') will be relaunched once it is idle — finish or hand off anything half-done now" ;;
        rename) [ "$OP_RENAME_SELF" = 1 ] && echo "   this pane ('${OP_RUN[1]}') will have /rename ${OP_RUN[2]} typed into it once it is idle, right after this turn ends — nothing for ${SALA_OWNER_NAME} to type" ;;
        model) # the asking session names itself (this very pane's session, or the --from it was queued as): a switch relaunches it; --clear relaunches nothing
            # the single shape names it first, the batch anywhere after the model (and its --effort); --clear in either form relaunches nothing
            local _me="" _x; for _x in "${OP_RUN[@]:1}"; do [ "$_x" = "$from" ] && _me="$_x"; [ -n "${TMUX_PANE:-}" ] && [ "$_x" = "$(op_hearer)" ] && _me="$_x"; done
            case " ${OP_RUN[*]} " in *" --clear "*) _me="";; esac
            if [ -n "$_me" ]; then
                echo "   this pane ('$_me') will have its model switched once it is idle (in place when its input box is empty, else relaunched) — finish or hand off anything half-done now"; fi ;; esac
    return 0
}
# ── the watch's side: the queue runner (op_tick, lib/watch.sh) ───────────────
op_unit_live() {  # <id> → 0 while its unit is active, or the runner's recorded pid lives (the tests' stand-in for a unit)
    systemctl --user is-active --quiet "sala-op-$1" 2>/dev/null && return 0
    local p; p=$(op_val "$1" pid); [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}
op_launch() {  # <id> [--stuck] — the operation as its own transient unit sala-op-<id> (--stuck: the stuck handler, unit sala-op-<id>-stuck); without systemd-run (macOS), detached
    local id="$1" what="${2:-}" log unit; log=$(op_oplog "$id"); mkdir -p "$SALA_LOG_DIR"; unit="sala-op-$id${what:+-stuck}"
    if command -v systemd-run >/dev/null 2>&1; then
        systemd-run --user --quiet --collect -p KillMode=process --unit="$unit" bash -c "exec '$SALA_BIN' op ${what:---run} '$id' >> '$log' 2>&1"
    else setsid "$SALA_BIN" op "${what:---run}" "$id" </dev/null >> "$log" 2>&1 3>&- 9>&- & fi   # (3>&-: the tick's queue lock stays the tick's, not the runner's)
}
op_absorb() {  # <id of the recycle about to start> — every queued recycle, and every queued update of this box alone, folds into it
    local id="$1" f o v a flags=() more=() me av anyother x_; me=$_SALA_HN
    mapfile -t flags < <(op_vals "$id" arg)
    for f in $(op_files); do
        o=${f##*/}; o=${o%.op}; [ "$o" != "$id" ] && [ "$(op_val "$o" state)" = queued ] || continue
        v=$(op_val "$o" verb)
        case "$v" in
            recycle) for a in $(op_vals "$o" arg); do case " ${flags[*]-} " in *" $a "*) ;; *) flags+=("$a");; esac; done ;;
            update) av=$(op_vals "$o" arg); anyother=0   # (a grep -qvx: some value is not this box)
                    if [ -n "$av" ]; then while IFS= read -r x_; do [ "$x_" = "$me" ] || { anyother=1; break; }; done <<< "$av"; fi
                    [ "$anyother" = 0 ] || continue   # --fleet or a remote host: an operation of its own
                    case " ${flags[*]-} " in *" --update "*) ;; *) flags+=(--update);; esac ;;
            *) continue ;;
        esac
        more+=("$o")
    done
    [ ${#more[@]} -gt 0 ] || return 0
    _op_file_r f "$id"; { _kv_without "$f" arg; for a in --update --force; do case " ${flags[*]-} " in *" $a "*) echo "arg=$a";; esac; done; } > "$f.t.$$" && mv -f "$f.t.$$" "$f"
    for o in "${more[@]}"; do
        op_add "$id" absorbed "op $o ($(op_line "$o")) from $(op_val "$o" from)"
        op_put "$o" state absorbed; op_put "$o" into "$id"; op_put "$o" ended "$(date +%s)"; op_put "$o" result "folded into op $id ($(op_line "$id"))"
        op_log "op $o absorbed into op $id: $(op_line "$o") (from $(op_val "$o" from))"
        op_tell "$(op_val "$o" from)" "[sala op $o] $(op_line "$o") was folded into op $id ($(op_line "$id")), which runs now and covers it; the result comes as op $id's. (Automatic salamander message from the operation queue; nothing to reply to.)"
        op_archive "$o"
    done
}
op_par_of() {  # <id> → OP_P_CLASS (par · solo) and OP_P_KEYS (the names a par one touches): the verb's own declaration (op_shape); a marker that fits no shape is solo
    local v a o; v=$(op_val "$1" verb); mapfile -t a < <(op_vals "$1" arg)
    o=$( if op_shape "$v" ${a[@]+"${a[@]}"} >/dev/null 2>&1; then echo "$OP_PAR|$OP_KEYS"; else echo "solo|"; fi )
    OP_P_CLASS=${o%%|*}; OP_P_KEYS=${o#*|}
}
op_start() {  # <id> [par|solo] [names] — under the tick lock; the class and names the tick decided on go on the marker (the runner takes its lock by them)
    local id="$1" verb; verb=$(op_val "$id" verb)
    [ "$verb" = recycle ] && op_absorb "$id"
    op_put "$id" state running; op_put "$id" started "$(date +%s)"; op_put "$id" unit "sala-op-$id"; op_put "$id" boot "$(boot_id)"
    op_put "$id" par "${2:-solo}"; op_put "$id" keys "${3:-}"
    if op_launch "$id"; then op_log "op $id started as unit sala-op-$id: $(op_line "$id") (from $(op_val "$id" from))"; : > "$SALA_OP_DIR/.launched.$$"
    else op_log "op $id: systemd-run refused to launch unit sala-op-$id"; op_finish "$id" stuck "systemd-run refused to launch its unit sala-op-$id"; fi
}
op_tick() {  # the watch's step: start what the parallel rule allows, oldest first; a runner gone without a result is settled here. OP_LAUNCHED=1 when one started
    OP_LAUNCHED=0
    [ "$SALA_OP_QUEUE" = on ] || return 0
    [ -d "$SALA_OP_DIR" ] || return 0
    rm -f "$SALA_OP_DIR/.launched.$$"
    if command -v flock >/dev/null 2>&1; then
        ( flock -w 30 3 || { op_log "tick: the queue lock was held for 30 s — the next tick looks again"; exit 0; }; op_tick_locked ) 3>>"$SALA_OP_DIR/.lock"
    else op_tick_locked; fi
    [ -e "$SALA_OP_DIR/.launched.$$" ] && { OP_LAUNCHED=1; rm -f "$SALA_OP_DIR/.launched.$$"; }
    return 0
}
# THE TICK, in two passes over the markers, oldest first (the header, THE DRIVER AND THE PARALLEL RULE). The first settles a runner
# that ended without a result and a waiter that died, and counts what is still running (RUNNING operations, SOLO_LIVE when one is
# a solo operation or an older marker with no class) and which names are held (HELD: running, waiting, and, in the second pass,
# older queued operations that could not start). The second starts, in order, every queued operation the rule allows:
#   · a par operation when RUNNING < the cap, no solo one runs and none of its names is in HELD (else its names join HELD, so a
#     younger operation on the same session does not jump ahead of it); the pass goes on to the next;
#   · a solo operation only when nothing runs; when something does, the pass ends: nothing younger starts behind it, which is
#     what keeps it from starving; started, the pass ends too (nothing runs beside a solo operation).
op_tick_locked() {
    local f id st p cap running=0 solo_live=0 held=" " k n
    cap=$SALA_OP_PARALLEL; case "$cap" in ''|*[!0-9]*|0) cap=3;; esac
    for f in $(op_files); do
        id=${f##*/}; id=${id%.op}; st=$(op_val "$id" state)
        case "$st" in
            running) if op_unit_live "$id"; then
                         running=$((running+1)); [ "$(op_val "$id" par)" = par ] || solo_live=1
                         held+="$(op_val "$id" keys) "
                         continue
                     fi
                     # the unit is gone: the marker is read AGAIN, after that. A runner that ends well wrote its result and archived the marker
                     # before it exited, and the state read at the top of the loop may be from before; ticks come more often now (each operation
                     # started or ended asks for one), and a marker taken for a dead runner's would get a stuck handler and a second post
                     [ "$(op_val "$id" state)" = running ] || continue
                     if [ "$(op_val "$id" verb)" = reboot ] && [ -n "$(op_val "$id" boot)" ] && [ "$(op_val "$id" boot)" != "$(boot_id)" ]; then
                         op_finish "$id" done "$_SALA_HN rebooted and is back (its boot half resumes the hooks and panes; the post-boot report says how)"
                     else
                         # the stuck handler runs as a unit of its own, never inside this tick: sala-watch.service is a oneshot whose
                         # leftover processes die with the tick, and a claude -p may take up to SALA_OP_STUCK_TIME
                         op_put "$id" state waiting; op_put "$id" why "its runner (unit sala-op-$id) ended without a result: see its log"
                         if op_launch "$id" --stuck; then op_log "op $id: its runner ended without a result — the stuck handler started as unit sala-op-$id-stuck"
                         else op_finish "$id" stuck "its runner (unit sala-op-$id) ended without a result, and the stuck handler could not be launched"; fi
                     fi
                     [ -f "$SALA_OP_DIR/$id.op" ] && held+="$(op_val "$id" keys) " ;;
            waiting) p=$(op_val "$id" waiter)   # a waiter judges its set, or the stuck handler runs: this tick only notices one that died
                     if [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null && ! systemctl --user is-active --quiet "sala-op-$id-stuck" 2>/dev/null \
                        && [ "$(op_val "$id" state)" = waiting ]; then   # (read again once the waiter is gone, as for a runner above)
                         op_finish "$id" stuck "its waiter (pid $p) ended without a result: see its log"
                     fi
                     [ -f "$SALA_OP_DIR/$id.op" ] && held+="$(op_val "$id" keys) $(op_targets "$id") " ;;
        esac
    done
    [ "$solo_live" = 0 ] || return 0   # nothing starts beside a solo operation
    for f in $(op_files); do
        id=${f##*/}; id=${id%.op}; [ "$(op_val "$id" state)" = queued ] || continue
        [ "$running" -lt "$cap" ] || return 0
        op_par_of "$id"
        if [ "$OP_P_CLASS" = par ]; then
            n=0; for k in $OP_P_KEYS; do case "$held" in *" $k "*) n=1; break;; esac; done
            if [ "$n" = 1 ]; then held+="$OP_P_KEYS "; continue; fi   # a name is busy: it waits, and holds its names against younger ones
            op_start "$id" par "$OP_P_KEYS"; running=$((running+1)); held+="$OP_P_KEYS "
        else
            [ "$running" = 0 ] || return 0   # a solo operation waits for what runs, and nothing younger starts behind it
            op_start "$id" solo "$OP_P_KEYS"; return 0
        fi
    done
    return 0
}

# ── inside the unit: the runner, the waiter, the result ──────────────────────
op_out_tail() {  # <id> [lines] → the verb's own output's last lines, one line, secrets masked
    local n="${2:-3}" t; t=$(grep -v '^[[:space:]]*$' "$(op_out "$1")" 2>/dev/null | tail -n "$n" | sed -E 's/^\[[^]]*\] //' | paste -sd'·' - | sed 's/·/ · /g' | cut -c1-400)
    if command -v scrub_text >/dev/null 2>&1; then printf '%s' "$t" | scrub_text; else printf '%s' "$t"; fi
}
op_wait_lock() {  # [secs] → 0 once no relaunch holds the recycle lock (fd 9 closed here first)
    local i; for ((i=0; i<${1:-1800}; i+=SALA_OP_POLL)); do recycle_locked || return 0; sleep "$SALA_OP_POLL"; done; ! recycle_locked
}
op_find_set() {  # <epoch> → the newest Recycle or Revive set created since then (common.sh, "recycle sets"), or nothing
    local f id c best="" bc=0
    for f in "$SALA_SET_DIR"/[0-9]*; do
        [ -f "$f" ] || continue; case "$f" in *.t.*) continue;; esac; id=$(basename "$f")
        grep -qxE 'kind=(Recycle|Revive)' "$f" || continue
        c=$(set_val "$id" created); [ "${c:-0}" -ge "$1" ] || continue
        [ "$c" -ge "$bc" ] && { bc=$c; best="$id"; }
    done
    echo "$best"
}
op_set_words() { echo "$(set_val "$1" kind) $(set_val "$1" label): $(set_val "$1" done)/$(set_val "$1" total) relaunched"; }   # <set>
op_judge_set() {  # <id> <set> — done · stuck · waiting (the waiter detached)
    local id="$1" set="$2" left ng
    op_put "$id" set "$set"   # op_finish names the panes it gave up (THE MANY-SESSION POST)
    left=$(set_count "$set" out); ng=$(set_count "$set" gave)
    if [ "$(set_val "$set" closed)" = 1 ] || [ "$left" = 0 ]; then
        if [ "$ng" = 0 ]; then op_done "$id" "$(op_set_words "$set")"
        else op_stuck "$id" "$(op_set_words "$set"), $(plural "$ng" pane) given up: $(set_vals "$set" gave | paste -sd';' - | sed 's/;/; /g')"; fi
        return 0
    fi
    [ "$(op_val "$id" state)" = waiting ] && return 0   # the waiter runs already (a tick that found it so)
    op_put "$id" state waiting; op_put "$id" set "$set"
    op_say "$id" "$(plural "$left" pane) of set $set outstanding ($(set_vals "$set" out | paste -sd, - | sed 's/,/, /g')): a retry worker or the deferred list has them — waiting for the set to close (up to $(op_dur "$SALA_OP_SETTLE_WAIT"))"
    setsid "$SALA_BIN" op --settle "$id" "$set" </dev/null >> "$(op_oplog "$id")" 2>&1 9>&- &
}
op_settle() {  # <id> <set> — the waiter: the set closed → judged; superseded → done (a newer relaunch has its panes); the window out → stuck
    local id="$1" set="$2" deadline
    [ -n "$id" ] && [ -n "$set" ] || die "usage: salamander op --settle <id> <set>"
    [ -f "$(op_file "$id")" ] || exit 0
    op_put "$id" waiter "$$"; op_put "$id" state waiting; deadline=$(( $(date +%s) + SALA_OP_SETTLE_WAIT ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        set_has "$set" || { op_stuck "$id" "its set $set is gone before it closed"; return 0; }
        [ "$(set_val "$set" closed)" = 1 ] && { op_judge_set "$id" "$set"; return 0; }
        if set_superseded "$set"; then op_done "$id" "$(op_set_words "$set"); a newer relaunch took over the $(plural "$(set_count "$set" out)" pane) still outstanding ($(set_vals "$set" out | paste -sd, - | sed 's/,/, /g'))"; return 0; fi
        sleep "$SALA_OP_POLL"
    done
    op_stuck "$id" "$(op_set_words "$set"); $(plural "$(set_count "$set" out)" pane) still outstanding after $(op_dur "$SALA_OP_SETTLE_WAIT"): $(set_vals "$set" out | paste -sd, - | sed 's/,/, /g')"
}
op_run() {  # <id> — the unit's main process
    local id="$1" verb rc t0 set c w lk
    [ -n "$id" ] && [ -f "$(op_file "$id")" ] || die "no operation '$id'"
    verb=$(op_val "$id" verb); mapfile -t OP_ARGS < <(op_vals "$id" arg); w=$(op_val "$id" words)
    op_put "$id" pid "$$"
    op_say "$id" "$(op_line "$id") — asked by $(op_val "$id" from) (queued at $(local_human "$(op_val "$id" time)"))${w:+: \"$w\"}$(op_val "$id" nowords | sed 's/^./: &/') (unit sala-op-$id)"
    op_shape "$verb" ${OP_ARGS[@]+"${OP_ARGS[@]}"} 2>/dev/null || { op_stuck "$id" "its marker does not fit the verb's shape: $OP_BAD"; return 0; }
    if c=$(op_conflict "$id"); then
        op_stuck "$id" "it conflicts with queued op $c ($(op_line "$c"), from $(op_val "$c" from)): both name the same session, and the queue runs neither on a guess"; return 0
    fi
    shutting_down && { op_stuck "$id" "a reboot is under way"; return 0; }
    if [ -n "$(op_val "$id" nowords)" ]; then
        # A retire queued with no words is judged again here, before it ends anything: the session under that name may have been
        # replaced since it was queued. The same checks as at queue time, and the registry row id the marker carries.
        # A revive queued with no words (the reason door, THE WORDS POLICY in the header) is judged the same way before it relaunches anything, by the verb's policy
        # (op_words_policy): the marker's reason (item= or reason=), only --only NAMEs and --force, one registry row id per name, the sender still allowed, and every row
        # still the live one it was queued for, not the master, not the asker. A mismatch is stuck with nothing run, at once and with no claude -p helper (op_finish, not op_stuck).
        op_words_policy "$verb" ${OP_ARGS[@]+"${OP_ARGS[@]}"}
        if [ "$OP_POLICY" = reason ]; then
            op_reason_run_ok "$id" || { op_say "$id" "stuck — $OP_REASON_WHY"; op_finish "$id" stuck "$OP_REASON_WHY; nothing was revived"; return 0; }
        else
            if [ "$OP_POLICY" != throwaway ] || [ -z "$(op_val "$id" ownrow)" ]; then
                op_say "$id" "stuck — no words, but not a throwaway retire that still passes its checks with its row id"
                op_finish "$id" stuck "the marker says no words but is not a throwaway retire that still passes its checks with its row id, so nothing was ended"; return 0
            fi
            op_own_flags_ok "${OP_ARGS[@]}" || { op_say "$id" "stuck — $OP_OWN_WHY"; op_finish "$id" stuck "$OP_OWN_WHY; nothing was ended"; return 0; }   # a hand-edited marker: --force / --keep-web never ride on no words
            op_own_target_ok "${OP_ARGS[0]}" "$(op_val "$id" from)" "$(op_val "$id" ownrow)" || { op_say "$id" "stuck — $OP_OWN_WHY"; op_finish "$id" stuck "$OP_OWN_WHY; nothing was ended"; return 0; }   # never op_stuck: its claude -p helper can run salamander retire with none of these checks
        fi
    fi
    export SALA_LOCK_WHO="op-$id" SALA_LOCK_WAIT="$SALA_OP_LOCK_WAIT"; [ -n "$OP_KIND" ] && export SALA_RELAUNCH_KIND="$OP_KIND"
    [ "$verb" = recycle ] && export SALA_FLAG_SRC=op-recycle   # a recycle from the owner's words: its flag waits for nothing (gather, rest)
    # THE LOCK (the header): taken before any verb; held through one that takes none itself, given back at once to one that does.
    # SHARED for a par operation, and only when the tick started it as one (the marker's par=): the class it was started under
    # decides, so a verb the tick started alone is never run beside others. EXCLUSIVE for every other.
    [ "$OP_LOCK" != share ] || [ "$(op_val "$id" par)" = par ] || OP_LOCK=hold
    if [ "$OP_LOCK" = share ]; then lk=recycle_lock_shared; else lk=recycle_lock; fi
    if ! $lk "op-$id" "$SALA_OP_LOCK_WAIT"; then op_stuck "$id" "$(recycle_holder_line) — still held after $(op_dur "$SALA_OP_LOCK_WAIT"), so the operation did not start"; return 0; fi
    [ "$OP_LOCK" = own ] && exec 9>&-
    t0=$(date +%s)
    if [ -n "$OP_UNSET_MASTER" ]; then
        # THE MASTER'S OWN RETIRE (the header): SALA_MASTER unset first, under the lock, so no watch tick heals the pane
        # the retire takes down; the unset is on the marker before the verb runs, and stays whatever the verb does
        op_say "$id" "'$OP_UNSET_MASTER' is the master session: unsetting SALA_MASTER first (salamander master --unset)"
        "$SALA_BIN" master --unset 9>&- </dev/null 2>&1 | tee -a "$(op_out "$id")"; rc=${PIPESTATUS[0]}
        [ "$rc" = 0 ] || { op_stuck "$id" "salamander master --unset exited $rc, so the retire of the master '$OP_UNSET_MASTER' did not start (SALA_MASTER stays): $(op_out_tail "$id" 2)"; return 0; }
        op_put "$id" unset_master "$OP_UNSET_MASTER"; SALA_MASTER=""; export SALA_MASTER   # the verb below reads the config afresh; the empty export outranks a stale one in this environment
    fi
    op_say "$id" "running: salamander ${OP_RUN[*]}"
    export SALA_OP_ID="$id" SALA_OP_FROM="$(op_val "$id" from)" SALA_OP_WORDS="$w"   # who asked and the owner's words, for a verb that says so (spawn's message to a page's keeper)
    # 9>&-: a worker the verb detaches must not hold the lock the runner holds; the output streams into the log and into its own copy
    "$SALA_BIN" "${OP_RUN[@]}" 9>&- </dev/null 2>&1 | tee -a "$(op_out "$id")"; rc=${PIPESTATUS[0]}
    op_say "$id" "salamander $verb exited $rc after $(( $(date +%s) - t0 )) s"
    local lfb=0; [ "$verb" = lane ] && [ "${OP_ARGS[0]:-}" = fallback ] && lfb=1   # the lane fallback (lib/lane.sh): RESULT lines per session, like the model batch
    if [ "$lfb" = 1 ] && [ "$rc" = 4 ]; then   # no usable fallback (the lane is not dormant, or the fallback is dormant or not ready): a person's call, no claude -p
        op_finish "$id" stuck "$(op_run_words) exited 4: $(op_out_tail "$id" 3) (no claude -p: moving the sessions by hand is salamander lane <lane> <session>)"; return 0
    fi
    if { [ "$verb" = model ] || [ "$lfb" = 1 ]; } && grep -q '^RESULT ' "$(op_out "$id")" 2>/dev/null; then
        # a many-session model operation (lib/model.sh, THE BATCH): its line per session goes on the marker, and the one notice carries them all
        local rl; while IFS= read -r rl; do op_add "$id" detail "$(op_one_line "${rl#RESULT }")"; done < <(grep '^RESULT ' "$(op_out "$id")" | cut -c1-400)
        if [ "$rc" != 0 ]; then   # some session failed: stuck, named in the summary and the lines; no claude -p (each failure is one session's own, and the others stand)
            op_finish "$id" stuck "$(op_out_tail "$id" 1)"; return 0
        fi
    fi
    if [ "$verb" = spawn ] && { [ "$rc" = 3 ] || [ "$rc" = 4 ]; }; then   # not on the page (3) or no page (4): only the page's keeper can change that, no claude -p
        op_finish "$id" stuck "salamander ${OP_RUN[*]} exited $rc: $(op_out_tail "$id" 4) (no claude -p: only the page's keeper can add the line; once it is there, say the words again)"; return 0
    fi
    [ "$rc" = 0 ] || { op_stuck "$id" "$(op_run_words) exited $rc: $(op_out_tail "$id" 3)"; return 0; }
    if [ "$OP_LOCK" = own ]; then
        # a relaunch runs on as a detached driver holding the lock (the sweep, the self-worker): its end is the lock freed
        op_wait_lock "$SALA_OP_SWEEP_WAIT" || { op_stuck "$id" "the relaunch still held the recycle lock after $(op_dur "$SALA_OP_SWEEP_WAIT") ($(recycle_holder_line))"; return 0; }
        set=$(op_find_set "$t0")
        [ -n "$set" ] || { op_done "$id" "$(op_out_tail "$id" 1)"; return 0; }
        op_judge_set "$id" "$set"; return 0
    fi
    op_done "$id" "$(op_out_tail "$id" 1)"
}
op_done() { op_finish "$1" done "$2"; }
op_stuck_main() {  # <id> — the stuck handler's unit (sala-op-<id>-stuck), for a runner that ended without a result: the why is on the marker
    local id="$1"; [ -n "$id" ] && [ -f "$(op_file "$id")" ] || die "no operation '$id'"
    op_put "$id" waiter "$$"; op_stuck "$id" "$(op_val "$id" why)"
}
op_stuck() {  # <id> <failure> — the one claude -p, then the result
    local id="$1" why="$2" verdict
    op_say "$id" "stuck — $why"
    # A no-words retire is never handed to the helper: it runs salamander retire with none of the throwaway checks.
    if [ "$SALA_OP_STUCK" = on ] && [ -z "$(op_val "$id" helper)" ] && [ -z "$(op_val "$id" nowords)" ]; then
        op_put "$id" helper "$(date +%s)"
        if verdict=$(op_helper "$id" "$why"); then op_finish "$id" done "$verdict (the one-off claude -p finished it; the first try: $why)"; return 0; fi
        why="$why — $verdict"
    fi
    op_finish "$id" stuck "$why"
}
op_brief() {  # <id> <failure> → the helper's prompt
    local id="$1" why="$2" set asked
    set=$(op_val "$id" set)
    if [ -n "$(op_val "$id" nowords)" ]; then asked="queued by $(op_val "$id" from) at $(local_human "$(op_val "$id" time)") with no words ($(op_val "$id" nowords)): $([ "$(op_val "$id" verb)" = revive ] && echo "that session revives the sessions named, for the reason in the note" || echo "that session ends a throwaway (the rule is in the note)")."
    else asked="with ${SALA_OWNER_NAME}'s words (quoted by $(op_val "$id" from); queued at $(local_human "$(op_val "$id" time)")): \"$(op_val "$id" words)\"."; fi
    cat <<EOF
You are sala's stuck-operation helper: a one-off \`claude -p\` started by salamander's operation queue (lib/op.sh) on $_SALA_HN, inside the unit sala-op-$id. Nobody watches this run; your outputs are the sala commands you run and your last line.

The operation: op $id, \`salamander $(op_line "$id")\`, $asked
What happened: $why
Already tried: the queue ran \`salamander $(op_line "$id")\` once, started $(local_human "$(op_val "$id" started)")${set:+; its set $set ($(op_set_words "$set"); given up: $(set_vals "$set" gave | paste -sd';' - | sed 's/;/; /g'); outstanding: $(set_vals "$set" out | paste -sd, - | sed 's/,/, /g'))}.

The operation's log, its last 40 lines ($(op_oplog "$id")):
$(tail -n 40 "$(op_oplog "$id")" 2>/dev/null)

The relaunch log's last 20 lines ($SALA_LOG_DIR/salamander-revive.log):
$(tail -n 20 "$SALA_LOG_DIR/salamander-revive.log" 2>/dev/null)

Rules. NEVER run \`salamander retire\` (or any verb that ends a session) for an operation queued with no words ("with no words" above): its throwaway checks failed or it already ran, and a retire here would have none of them; end with a SALA-OP: stuck line instead. For a no-words revive (a reason in the note, not a retire), only \`salamander revive [--force] --only <those NAMEs>\`, the sessions its arguments name and nothing else (no sweep, no other session, no --rescue). Finish the operation with sala's own verbs only (salamander recycle, revive, retire, close-shell, forget-row, rename, lane, model, update, provision, spawn; \`salamander revive --only <session> --force --rescue\` when a stale background-task row holds a pane and no child process runs under its claude), with read-only looks (tmux list-panes, tmux capture-pane, tail, cat, ls, ps, grep, Read). Never --not-master, never stop a process, never tmux kill-*, never reboot, never a wider path than the words asked for (no --force the words did not imply). If it needs a decision only ${SALA_OWNER_NAME} can make, or a pane is held by work that must not be interrupted, stop and say so. A permission prompt you cannot answer means stop. Do not post to Slack or message a session: the queue does that from your last line.
End with exactly one line: \`SALA-OP: done <what you did, one line>\` or \`SALA-OP: stuck <why, one line>\`.
EOF
}
op_verify() {  # <id> → 0 when the operation's effect can be seen (or cannot be checked); 1 with OP_VERIFY_WHY
    local verb a; verb=$(op_val "$1" verb); mapfile -t a < <(op_vals "$1" arg); OP_VERIFY_WHY=""
    case "$verb" in
        retire) [ "${a[0]:-}" = --id ] || { if tmux has-session -t "=${a[0]:-}" 2>/dev/null; then OP_VERIFY_WHY="'${a[0]}' is still a tmux session"; return 1; fi; } ;;
        close-shell) if tmux has-session -t "=${a[0]:-}" 2>/dev/null; then OP_VERIFY_WHY="'${a[0]}' is still a tmux session"; return 1; fi ;;
        forget-row) if [ -n "$(ledger_row "${a[0]:-}")" ]; then OP_VERIFY_WHY="the pane map still holds a row for '${a[0]}'"; return 1; fi ;;
        rename) tmux has-session -t "=${a[1]:-}" 2>/dev/null || { OP_VERIFY_WHY="no tmux session '${a[1]:-}'"; return 1; }
                tmux has-session -t "=${a[0]:-}" 2>/dev/null && { OP_VERIFY_WHY="'${a[0]}' is still a tmux session"; return 1; } ;;
        lane) local _vl; _lane_norm_r _vl "${a[1]:-}"; [ "${a[0]:-}" = default ] && [ "$(lane_default)" != "$_vl" ] && { OP_VERIFY_WHY="the default lane is $(lane_default), not $_vl"; return 1; } ;;
        model) local _vm _vs _vi _vx
               if [ "${a[0]:-}" = --clear ]; then for _vs in "${a[@]:1}"; do [ -z "$(model_row "$_vs")" ] || { OP_VERIFY_WHY="a model record for '$_vs' is still there"; return 1; }; done
               elif [ "${a[1]:-}" = --clear ]; then [ -z "$(model_row "${a[0]:-}")" ] || { OP_VERIFY_WHY="a model record for '${a[0]:-}' is still there"; return 1; }
               elif model_batch_shape "${a[@]}"; then   # <model> [--effort <level>] <session>…: every session is recorded on the model
                   _vm="${a[0]}"; for ((_vi=1; _vi<${#a[@]}; _vi++)); do _vx="${a[_vi]}"; [ "$_vx" = --effort ] && { _vi=$((_vi+1)); continue; }
                       [ "$(cut -f1 <<< "$(model_row "$_vx")")" = "$_vm" ] || { OP_VERIFY_WHY="'$_vx' is not recorded on $_vm"; return 1; }; done
               else [ "$(cut -f1 <<< "$(model_row "${a[0]:-}")")" = "${a[1]:-}" ] || { OP_VERIFY_WHY="'${a[0]:-}' is not recorded on ${a[1]:-}"; return 1; }; fi ;;
        spawn) tmux has-session -t "=${a[0]:-}" 2>/dev/null || { OP_VERIFY_WHY="no tmux session '${a[0]:-}'"; return 1; } ;;
    esac
    return 0
}
op_helper() {  # <id> <failure> → prints the verdict; 0 = done (checked), 1 = stuck
    local id="$1" why="$2" cmd hl rc line
    cmd="${SALA_OP_CLAUDE:-$SALA_CLAUDE}"; hl="$SALA_LOG_DIR/salamander-op-$id.helper.log"
    job_env_args "$SALA_JOB_LANE" || { echo "the one-off claude -p could not start: the $(lane_shown "$SALA_JOB_LANE") lane (SALA_JOB_LANE) is not ready: $JOB_ENV_WHY"; op_say "$id" "no claude -p: the $SALA_JOB_LANE lane is not ready: $JOB_ENV_WHY"; return 1; }
    op_say "$id" "one claude -p on the $(lane_shown "$SALA_JOB_LANE") lane for the stuck operation (at most $SALA_OP_STUCK_TURNS turns, $(op_dur "$SALA_OP_STUCK_TIME"); its output: $hl)"
    ( cd "$SALA_OP_HELPER_CWD" 2>/dev/null || cd "$HOME"
      exec timeout --kill-after=30 "$SALA_OP_STUCK_TIME" env -u ANTHROPIC_API_KEY -u ANTHROPIC_CUSTOM_HEADERS -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CONFIG_DIR ${JOB_ENV[@]+"${JOB_ENV[@]}"} \
        "$cmd" -p "$(op_brief "$id" "$why")" --max-turns "$SALA_OP_STUCK_TURNS" --allowedTools "$SALA_OP_HELPER_TOOLS" --output-format text ) > "$hl" 2>&1 </dev/null 9>&-; rc=$?
    line=$(grep -E '^SALA-OP: (done|stuck)' "$hl" 2>/dev/null | tail -1 | tr -d '\r')
    case "$line" in
        "SALA-OP: done"*)
            if op_verify "$id"; then echo "$(op_one_line "${line#SALA-OP: done}")"; op_say "$id" "the claude -p says done: ${line#SALA-OP: }"; return 0; fi
            echo "the one-off claude -p said done (\"$(op_one_line "${line#SALA-OP: done}")\"), but the check says otherwise: $OP_VERIFY_WHY"; op_say "$id" "the claude -p said done, but: $OP_VERIFY_WHY"; return 1 ;;
        "SALA-OP: stuck"*) echo "the one-off claude -p could not finish it: $(op_one_line "${line#SALA-OP: stuck}")"; op_say "$id" "the claude -p says stuck: ${line#SALA-OP: }"; return 1 ;;
        *) if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then echo "the one-off claude -p ran out of time ($(op_dur "$SALA_OP_STUCK_TIME")) without a verdict"
           else echo "the one-off claude -p ended (exit $rc) without a SALA-OP verdict line"; fi
           op_say "$id" "the claude -p gave no verdict (exit $rc)"; return 1 ;;
    esac
}
op_push() {  # <tmux session> <text> → 0 pushed into that session's inbox · 1 not live here (no pane, no claude under it, no socket) · 2 live, but the push failed
    local s="$1" pane cpid sock
    # "=$s:" (with the colon): list-panes reads a bare "=name" as a window/pane target and falls through to a PREFIX match, so the
    # retired "demo" would have found the live "demo-main" and delivered without its [for <owner>] line (tmux 3.6)
    pane=$(tmux list-panes -t "=$s:" -F '#{pane_id}' 2>/dev/null | head -1)
    if [ -n "$pane" ] && cpid=$(claude_pid_under "$(tmux display -p -t "$pane" '#{pane_pid}' 2>/dev/null)" 2>/dev/null) && [ -n "$cpid" ] \
       && sock=$(session_socket "$cpid") && [ -n "$sock" ]; then
        if session_push "$sock" "$2" 2>/dev/null; then op_log "told $s (pid $cpid): ${2:0:120}"; return 0; fi
        return 2
    fi
    return 1
}
op_tell() {  # <tmux session> <text> → into that session's inbox when it is live here. A project-name pane that retired
    # is no longer live, so the reply goes to the same project's front agent, <session>-main, with the line [for <owner>] first (a front
    # agent takes a message only then); neither live → one failure line in the op log (the Slack post stands). Always returns 0.
    local s="$1" t="$2" rc m=""
    op_push "$s" "$t"; rc=$?
    [ "$rc" = 0 ] && return 0
    if [ "$rc" = 1 ]; then
        case "$s" in
            *-main) ;;   # already a front agent: no further name to try
            *) m="$s-main"
               op_push "$m" "[for ${SALA_OWNER_NAME}]
$t" && { op_log "reply: $s has no live pane; sent to $m"; return 0; } ;;
        esac
        op_log "reply FAILED: $s has no live pane${m:+ and $m has none either}; nobody was told, the Slack post stands — ${t:0:120}"; return 0
    fi
    op_log "reply FAILED: $s is live but the push to its messaging socket failed; nobody was told, the Slack post stands — ${t:0:120}"; return 0
}
# THE MANY-SESSION POST (Mon Nov 2nd 2026): an operation given several sessions (lane <lane> <session>…, model <model> <session>…,
# model --clear <session>…, revive --only A --only B…, lane fallback <lane>) names none of them in its title or its inbox line: the
# title carries the verb and its other arguments and a count, the way the recycle's own post does ("✅ *Recycle done* · 12 panes",
# "⚠️ *Recycle … · n/N relaunched*"): every session through → "· done* · N sessions"; one failed or skipped → "· n/N succeeded*",
# a bullet per failed or skipped session with its reason (a FAILED / NOT moved / stays-on RESULT line; when stuck, a pane its set
# gave up or deferred and never got back, or one still outstanding); stuck with nothing per session to go on → "· N sessions, none
# confirmed". The sessions that went through are counted, never listed (the marker keeps their lines). One session: as before.
op_sessions_of() {  # <verb> [args…] → the sessions a many-session shape names, one per line (none for any other verb or shape)
    local verb="${1:-}" a e=""; shift || true
    case "$verb" in
    revive) while [ $# -gt 0 ]; do [ "$1" = --only ] && [ -n "${2:-}" ] && { echo "$2"; shift; }; shift; done ;;
    lane) case "${1:-}" in ''|fallback|default) return 0;; esac; [ "${2:-}" = --all ] && return 0; shift; [ $# -gt 0 ] && printf '%s\n' "$@" ;;
    model)
        if [ "${1:-}" = --clear ]; then shift; [ $# -gt 0 ] && printf '%s\n' "$@"
        elif [ "${2:-}" != --clear ] && model_batch_shape "$@"; then
            shift; for a in "$@"; do if [ "$e" = 1 ]; then e=""; elif [ "$a" = --effort ]; then e=1; else case "$a" in -*) ;; *) echo "$a";; esac; fi; done
        fi ;;
    esac
    return 0
}
op_short_argv() {  # <sessions, one per line> <verb> [args…] → the argv with those sessions (and an --only before one) left out
    local ss="$1" out=() a; shift
    while [ $# -gt 0 ]; do
        a="$1"
        if [ "$a" = --only ] && [ -n "${2:-}" ] && grep -qxF -- "$2" <<< "$ss"; then shift 2; continue; fi
        grep -qxF -- "$a" <<< "$ss" || out+=("$a"); shift
    done
    echo "${out[*]-}"
}
op_run_words() {  # → "salamander <OP_RUN>", the sessions left out and counted when it names several (for a result line)
    local ss n; ss=$(op_sessions_of "${OP_RUN[@]}"); n=$(grep -c . <<< "$ss")
    if [ "$n" -gt 1 ]; then echo "salamander $(op_short_argv "$ss" "${OP_RUN[@]}") ($n sessions)"; else echo "salamander ${OP_RUN[*]}"; fi
}
# THE OP-END EVENT (to stackshot): the last act of op_finish, beside the Slack post and the hearer's line, reports the operation's end with
# stackshot's client (`client.py event --kind fleet_op --verb <verb> --machine <host> --sessions <N> --result ok|partial|failed --text "<one line>"`,
# stackshot's event_waits.py), so an item waiting on "fleet_op <verb|any|many>" is woken by the op, not by its backstop day. It reuses the
# counts the many-session post already has (op_finish: n sessions named, nf of them failed or skipped), and the recycle set's own for a
# relaunch (set total; the panes it gave up, left out or never got back).
#   --sessions  the sessions the op covered: the ones it names (n, when more than one); else the relaunch set's total (recycle, update,
#               provision of the whole fleet, revive with no --only); else 1 for a verb on one session (retire, close-shell, forget-row,
#               rename, spawn, model of one); else 0 (an op over hosts or a lane default, which moves no session).
#   --result    ok = done and nothing failed or skipped · partial = some failed or were skipped, others went through · failed = the
#               operation is stuck with nothing through (one session, none confirmed, or every named one failed).
#   --machine   this box (the one that ran the op); the one host named, when `update` or `provision` names exactly one other box.
# Once per operation (evposted on the marker), at its end whatever state it ends in; never for a plan (--plan queues nothing and ends nothing),
# a cancelled operation or one folded into a recycle (they never reach op_finish). A failed or slow post changes nothing: SALA_OP_EVENT_TIMEOUT
# (30) s, stderr and stdout kept, the outcome in the op log; no client on the box → one line in the op log and nothing else. The recycle's own
# `client.py recycled` report (common.sh, post_recycle_hook) is separate and stays.
op_event() {  # <id> <done|stuck> <n named> <nf failed or skipped among them> <line> <result> — reports the end to stackshot; always returns 0
    local id="$1" st="$2" n="$3" nf="$4" line="$5" res="$6" verb set total=0 fails=0 result txt machine="$_SALA_HN" c out rc a skip="" host="" nh=0 s
    [ -z "$(op_val "$id" evposted)" ] || return 0
    op_put "$id" evposted 1
    verb=$(op_val "$id" verb); set=$(op_val "$id" set)
    if [ "$n" -ge 1 ]; then total=$n; fails=$nf
    elif set_has "$set"; then
        total=$(set_val "$set" total); [[ $total =~ ^[0-9]+$ ]] || total=0
        if [ "$st" = stuck ]; then   # the panes the set gave up, deferred and never got back, or left outstanding (the Slack post's own list)
            while IFS= read -r s; do
                [ -n "$s" ] && ! grep -qxF -- "back=$s" "$SALA_SET_DIR/$set" && fails=$((fails + 1))
            done < <({ set_vals "$set" gave; set_vals "$set" skip; set_vals "$set" out; } | sed -E 's/^([^: ]*)[: ].*/\1/' | sort -u)
        fi
    else case "$verb" in retire|close-shell|forget-row|rename|spawn|model) total=1;; esac; fi
    [ "$fails" -le "$total" ] || fails=$total
    if [ "$st" = done ]; then if [ "$fails" -gt 0 ]; then result=partial; else result=ok; fi
    elif [ "$total" -gt 1 ] && [ "$fails" -gt 0 ] && [ "$fails" -lt "$total" ]; then result=partial
    else result=failed; fi
    if [ "$verb" = update ] || [ "$verb" = provision ]; then   # hosts named: one other box is the machine the op ran for
        mapfile -t a < <(op_vals "$id" arg)
        for s in ${a[@]+"${a[@]}"}; do
            if [ -n "$skip" ]; then skip=""; continue; fi
            case "$s" in --only) skip=1;; -*) ;; *) host=$s; nh=$((nh + 1));; esac
        done
        [ "$nh" = 1 ] && machine=$host
    fi
    txt="sala op $line: $st — $res"; txt=$(op_one_line "$txt"); command -v scrub_text >/dev/null 2>&1 && txt=$(printf '%s' "$txt" | scrub_text); txt=${txt:0:230}
    c=$(stackshot_client) || { op_log "op $id: no stackshot client.py on this box (SALA_STACKSHOT_CLIENT, SALA_STACKSHOT_DIR/client.py), so the end of the $verb operation was not reported"; return 0; }
    out=$(timeout --kill-after=5 "$SALA_OP_EVENT_TIMEOUT" python3 "$c" event --kind fleet_op --verb "$verb" --machine "$machine" --sessions "$total" --result "$result" --text "$txt" 9>&- </dev/null 2>&1); rc=$?
    out=$(op_one_line "$out"); out=${out:0:300}
    if [ "$rc" = 0 ]; then op_log "op $id: reported to stackshot: fleet_op $verb on $machine, $total sessions, $result${out:+ ($out)}"
    elif [ "$rc" = 124 ] || [ "$rc" = 137 ]; then op_log "op $id: ⚠ the fleet_op event was not reported: stackshot's client did not answer within ${SALA_OP_EVENT_TIMEOUT} s (the operation is unaffected)"
    else op_log "op $id: ⚠ the fleet_op event was not reported (client exit $rc${out:+: $out}); the operation is unaffected"; fi
    return 0
}
op_finish() {  # <id> done|stuck <result> — the record, one Slack post, the hearing session's line, the archive
    local id="$1" st="$2" res="$3" line from words nowords when hd bul=() x asked verb args=() ss="" n=0 nf=0 cnt="" fb=() ot=() y s set
    [ -f "$(op_file "$id")" ] || return 0
    line=$(op_line "$id"); from=$(op_val "$id" from); words=$(op_val "$id" words); nowords=$(op_val "$id" nowords); when=$(local_human "$(op_val "$id" time)")
    res=$(op_one_line "$res")
    op_put "$id" state "$st"; op_put "$id" result "$res"; op_put "$id" ended "$(date +%s)"
    op_say "$id" "$st — $res"; op_log "op $id $st: $line — $res"
    verb=$(op_val "$id" verb); mapfile -t args < <(op_vals "$id" arg)
    ss=$(op_sessions_of "$verb" ${args[@]+"${args[@]}"})
    if [ "$verb" = lane ] && [ "${args[0]:-}" = fallback ]; then   # who moved is read at run time: the sessions are its RESULT lines' (not "default lane")
        ss=$(op_vals "$id" detail | sed -n 's/^\([^ :][^ :]*\): .*/\1/p')
    fi
    [ -n "$ss" ] && n=$(grep -c . <<< "$ss")
    local nl=$'\n' dl=""
    if [ "$n" -gt 1 ]; then
        # many sessions: the failed and skipped ones named with their reason, the rest counted (THE MANY-SESSION POST, above)
        while IFS= read -r y; do
            [ -n "$y" ] || continue; s=${y%%: *}
            if grep -qxF -- "$s" <<< "$ss"; then
                case "${y#*: }" in FAILED*|*"(NOT moved"*|*skipped*|"stays on "*) fb+=("$y");; esac
            else ot+=("$y"); fi   # a line about no session (the lane fallback's default lane): kept as it was
        done < <(op_vals "$id" detail)
        set=$(op_val "$id" set)
        if [ "$st" = stuck ] && set_has "$set"; then   # a relaunch's set: the panes it gave up or deferred and never got back, then the ones still outstanding
            while IFS= read -r y; do
                [ -n "$y" ] || continue; s="${y%%[: ]*}"
                grep -qxF -- "$s" <<< "$ss" || continue
                grep -qxF -- "back=$s" "$SALA_SET_DIR/$set" && continue
                printf '%s\n' ${fb[@]+"${fb[@]}"} | grep -q "^$s[: ]" || fb+=("$y")
            done < <(set_vals "$set" gave; set_vals "$set" skip)
            while IFS= read -r s; do
                [ -n "$s" ] && grep -qxF -- "$s" <<< "$ss" || continue
                printf '%s\n' ${fb[@]+"${fb[@]}"} | grep -q "^$s[: ]" || fb+=("$s: not relaunched yet")
            done < <(set_vals "$set" out)
        fi
        nf=${#fb[@]}
        line=$(op_short_argv "$ss" "$verb" ${args[@]+"${args[@]}"})
        if [ "$nf" -gt 0 ]; then cnt="$((n - nf))/$n succeeded"
        elif [ "$st" = done ]; then cnt=$(plural "$n" session)
        else cnt="$(plural "$n" session), none confirmed"; fi
        bul=("$res" ${fb[@]+"${fb[@]}"} ${ot[@]+"${ot[@]}"})
        for y in ${fb[@]+"${fb[@]}"} ${ot[@]+"${ot[@]}"}; do dl+="$nl  - $y"; done
    else
        while IFS= read -r y; do [ -n "$y" ] && { dl+="$nl  - $y"; }; done < <(op_vals "$id" detail)   # a many-session operation's line per session (op_run)
        bul=("$res")
        while IFS= read -r y; do [ -n "$y" ] && bul+=("$y"); done < <(op_vals "$id" detail)   # a many-session operation: a line per session, under the result
    fi
    if [ "$st" = done ]; then hd="✅ *sala op: $line · done*"
    else hd="🚨 *sala op: $line · stuck*"; bul+=("nothing retries it: once the cause is clear, finish it by hand or say the words again"); fi
    if [ -n "$cnt" ]; then if [ "$nf" -gt 0 ]; then hd="${hd%\*} · $cnt*"; else hd+=" · $cnt"; fi; fi
    bul+=("asked by $from (queued at $when)${words:+: \"$words\"}${nowords:+: $nowords}")
    x=$(op_val "$id" item); [ -n "$x" ] && [ -n "$words" ] && bul+=("board item: $x"); x=$(op_val "$id" reason); [ -n "$x" ] && [ -n "$words" ] && bul+=("reason: $x")   # (with no words the note already says it)
    x=$(op_val "$id" unset_master); [ -n "$x" ] && bul+=("SALA_MASTER was unset first: '$x' is no longer the session the watchdog keeps alive$([ "$st" = done ] || echo " (salamander master --set $x makes it so again, if the retire is not to happen)")")
    while IFS= read -r x; do [ -n "$x" ] && bul+=("folded in: $x"); done < <(op_vals "$id" absorbed)
    [ -n "$(op_val "$id" helper)" ] && bul+=("a one-off claude -p looked at it (its output: ~/.claude/salamander-op-$id.helper.log)")
    bul+=("Details: ~/.claude/salamander-op-$id.log")
    sala_post "$hd" "${bul[@]}"
    op_event "$id" "$st" "$n" "$nf" "$line" "$res"   # stackshot hears the end too (THE OP-END EVENT, above); never changes the outcome
    x=$(op_val "$id" unset_master)
    if [ -n "$nowords" ]; then asked="Queued by $from at $when with no words ($nowords): $([ "$verb" = revive ] && echo "the session revived the sessions named, for the reason in the note" || echo "the session ended a throwaway (the rule is in the note)")."
    else asked="Words from ${SALA_OWNER_NAME} (quoted by $from; queued at $when): \"$words\"."; fi
    if [ "$from" = sala-watch ]; then op_log "no reply sent: $id was queued by the watch itself (no session waits on it); the Slack post stands"; op_archive "$id"; op_kick_end; return 0; fi
    op_tell "$from" "[sala op $id] salamander $line — $st${cnt:+ ($cnt)}: $res.${dl:+$dl$nl}${x:+ SALA_MASTER was unset first: '$x' is no longer the session the watchdog keeps alive.} $asked (Automatic salamander message from the operation queue; the result is posted in Slack too; nothing to reply to.)"
    op_archive "$id"
    op_kick_end   # the marker is archived: the next queued operation need not wait for the timer's tick
}
