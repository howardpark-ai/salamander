# The session registry (phases 1 to 3)

A session's name is how sala finds it today, and a name changes (`sala rename`) while the conversation under it can change
too (a `/clear`). The registry gives each session an **id of its own** that outlives both. Phases 1 and 2 only **record** it
beside the old tables, and the pane map stays the authority; phase 3 adds a published copy and a read-only resolver. Phase 1 wrote a row when the pane map did;
phase 2 (below) adds an explicit signal for a fresh start. The contract with
stackshot is a [proposal](session-registry-contract-proposal.md); its sala-to-stackshot half is in force since phase 3 (below).

## The file

`~/.local/state/salamander/sessions.json` (beside the pane map; `sessions.log` and `sessions-history/` next to it).

```json
{ "schema": 1, "written": "2026-01-05T11:00:00Z",
  "sessions": { "<id>": {
      "id": "<uuid4>", "name": "worker-1", "project": "projects/demo-docs", "role": "back",
      "lane": "subscription-1", "model": "opus", "effort": "high", "pane": "worker-1", "cwd": "/home/alex/…", "machine": "a",
      "created": "<ISO Z>", "state": "live", "retired_at": null,
      "aliases": ["worker-old"],
      "transcripts": [ {"id": "<claude session id>", "machine": "a", "at": "<ISO Z>", "why": "add"} ] } } }
```

- `id`: minted once, never reused. `name` and `pane` (the tmux session) are equal today. `aliases` are the names it had.
- `lane`, `model`, `effort` are the tables' recorded values (`lanes.tsv`, `models.tsv`), empty where nothing is recorded.
  `project` and `role` come from `spawn --project … --role …` (the page key as given, `front` or `back`), empty otherwise.
- `transcripts[0]` is the conversation the row was made with (`why`: `add`, `adopt`, or `import` from the migration; a row `spawn`
  made first has none until its claude is up). A later `add` of the same name with a new conversation appends one, and phase 2
  appends `clear`, `resume` and `start`. A `follow` records nothing: most of its lines were
  flip-flop noise (a resumed pane returning to its own id), which is why phase 2 uses an explicit signal instead.
- `state`: `live` or `retired`. **A retire never deletes the row**, so an old id (a board owner, say) still resolves.
  Re-adding a retired name makes a new row with a new id; one live row per name.

## What writes it

`ledger_write` (lib/common.sh), **after** its pane-map `mv` has succeeded and still under the pane map's lock:

| pane-map op | registry |
|---|---|
| `add`, `adopt` | reuse the live row with that name (update pane and cwd, append a new conversation) or mint one |
| `rename` | the same row: `name` and `pane` change, the old name goes to `aliases` |
| `retire` | `state=retired`, `retired_at` set |
| `follow` | nothing |

`lane_write`, `model_write` and `model_drop` copy their field in (after their own lock is released, then under the pane map's lock
for the copy alone), `spawn --project/--role` copies `project` and `role`. `sala sessions tag` sets the same two fields on a row that already exists (below). A field write for a mapped session that has no row
yet mints it from the map's row.

**A registry failure never fails or blocks the pane-map write**: the helper (`lib/sessions.py`) is run with its output captured,
its exit status ignored, and a failure is one line in `sessions.log`. A corrupt `sessions.json` is never overwritten. The
pane map's bytes are the same with the registry on, off or broken (`tests/sessions.sh`).

## Commands

- `sala sessions [--all] [--json]`: the listing, read-only (`--all` adds retired rows).
- `sala sessions record <id|name> --transcript <claude-session-id> --why clear|resume|start [--machine X]`: phase 2, below.
- `sala sessions tag <id|name> [--project <page key>] [--role front|back] [--project-key <page key>] [--dry-run]`: fills `project` and `role` of an existing live row, below.
- `sala sessions tag --auto [<id|name>] [--dry-run]`: fills `project` and `role` of every live row with none from stackshot's project record, below.
- `sala sessions --migrate [--dry-run]`: once, a row for every pane-map row that has none (lane, model, effort from the tables,
  aliases from `salamander-renames.jsonl`, `transcripts[0]` with `why: import`). Run `--dry-run` first and compare its
  `would mint` lines with the pane map; a name that already has a live row is skipped, so it is safe to repeat.
- `sala sessions --check [--dry-run]`: the registry against the pane map. A kill between `ledger_write`'s two writes leaves an
  add, a rename or a retire the registry never saw; `--check` repairs the **registry** (never the map) and says what it did,
  `--dry-run` only reports (exit 1 when there is drift). It also brings `lane`/`model`/`effort` back to the tables' values, and
  notes (only) a pane-map conversation the row does not list.

## Side sessions: four display fields and `sala sessions transcript`

A session made by `spawn --side` (docs/side-sessions.md) gets `side` (`"1"`), `side_origin` (the agent it was forked from, or empty),
`side_item` (the board item it is about) and `side_at` (ISO Z) on its row, through the same `set` call as `project` and `role`. They are
display copies: the gate that refuses its retire reads `$SALA_STATE_DIR/side/<name>.side`, so `SALA_SESSIONS=off` does not turn the gate off.
`sala sessions` shows `side` in the ROLE column of a row with no role. The four fields are **not** in `session-registry.json`
(`EXPORT_KEYS` is unchanged), so no contract version moves.

## A throwaway's tag: `throwaway`

Throwaways carry a tag set at spawn, and any session may retire a tagged one at any time between turns.
A bare `sala spawn` (no `--project`, `--role`, `--side` or `--master`) writes `throwaway` = `"1"` onto the new row through the same `set` call as
`spawned_by` below, **whoever runs it** (a Claude session, a plain shell, a person's pane: the tag does not need a spawner). A spawn with a project, a role or a side flag never
sets it. `lib/sessions.py` clears it when a row is given a project, a role or a side value (`set`, `tag --project/--role`, and with them the side-end rename, which goes through
`set`): a row that has become something else is no throwaway, whatever it was born as. The field is unpublished (`EXPORT_KEYS` is unchanged, so no contract version moves).
Its one reader is `sala op retire NAME --from YOU` with no `--words` (`op_own_target_ok`, `lib/op.sh`): **any live session may end a tagged row**, whatever its name and
whether or not its spawner is live (rule `tag`, note `words: none (throwaway tag set at spawn, retired by any session)`). The tag replaces the name-pattern
rule and the spawner-gone condition for a tagged row, and opens only the door: the asking session itself, the master, a row with a project, a role or a side mark (even
one that carries the tag), a row on a project's agents map (the check **fails closed**, as for the master's door below), the bypass flags, `--id` and `--keep-web` are refused as before. "Between turns" is retire's own idle check
(`is_idle_reason`: the registry's busy record written by the hooks, else the pane guesses), not a second one: a no-words retire never carries `--busy`, so the plan
(`retire NAME --dry-run`) refuses a target mid-turn ("is not idle") before anything is queued, and the runner's `salamander retire` refuses one that became busy since (the operation goes
stuck with nothing ended, no `claude -p` helper); the asker queues it again once the target is idle. **A row with no tag** (spawned before the tag, or by hand) keeps the rules of
the section below unchanged: its spawner, the master, or any session when the spawner is gone and the name is a throwaway's name. A pane with no row id (before row ids) is still bound by
its name alone, so even a tagged row there must carry a throwaway's name and a fresh agents-map answer: the conservative choice.

## A throwaway's spawner: `spawned_by`

A bare `sala spawn` (no `--project`, `--role`, `--side` or `--master`) run by a Claude session sets `spawned_by` on the new row, through the
same `set` call: the tmux session whose pane holds the spawn by process ancestry, with a Claude Code process on the way up (`spawn_caller` ->
`ancestry_session`, common.sh; never `TMUX_PANE`, which a caller can set to anything). A Claude Code process is one whose comm is `claude` AND whose
`/proc/<pid>/exe` is under the account's own `~/.local/share/claude/versions/` (`claude_exe_trusted`; a test's temporary `$HOME` also counts its own
folder), never the name alone: a symlink or copy of bash called `claude` is not one. A spawn from a plain shell, a detached job, a
human's pane or the queue's runner sets none. The field is unpublished (`EXPORT_KEYS` is unchanged, so no contract version moves) and has one
reader: `sala op retire NAME --from YOU` with no `--words` (lib/op.sh, `op_own_retire_ok`) is queued only when NAME is a **throwaway** (a row carrying the `throwaway` tag above is open to any session; the rest of this section is the rule for a row with no tag): the live row named
exactly NAME has no `project`, no `role` and no `side`, NAME is on no project's agents map (stackshot's project record, `project_record_agent`; for the master and any-session doors below this
check **fails closed**: a record that is missing, stale or unreadable falls back to `pages.py agent-listed` (the path `agent_unlisted` takes), and when that
cannot confirm the name is unlisted either, the retire is refused with "the project record could not confirm that NAME is unlisted"; the spawner door
goes on without an answer, its row is the proof), and NAME is neither the master nor YOU; and YOU may end it. **Who** (the session that started a throwaway may end it with no words; widened
so that retiring a throwaway never needs the owner): (a) its spawner, `spawned_by` = YOU; (b) the master session (`SALA_MASTER`), when NAME is a
throwaway's name or the master is the spawner (covered by (a)); (c) any live Claude session when the row has no `spawned_by`, or the spawner's tmux session is
not live (a spawner that was renamed counts as not live: its old name is gone), AND NAME is a throwaway's name (`scratch-*`, `*-check-*`,
`*-test-*`, `*-probe-*`; a bare `sala spawn` names `scratch-<date>-<word>`). The name alone is never enough: a project, role, side or agents-map entry
refuses whatever the name, and a name with another live spawner opens only (a) and (b). **No bypass flag (`--busy`, `--skip-writeup`, `--self`, `--leave-items`), no `--id` and no `--keep-web` with no words**: they are
retire's own bypasses, which only the owner's words allow, refused at queue time (`op_own_flags_ok`) and again by the runner. The marker's note says which rule allowed it (`retired by its
spawner`, `retired by the master`, `retired by any session: no live spawner`). YOU is checked against the caller placed by process ancestry
(the same walk), so `--from` and `TMUX_PANE` are only claims; and the target is bound to the row by its process, not by the tmux session name
alone: `spawn` gives the throwaway's pane and claude the row's id as `SALA_SESSION_ID`, and every process in every pane of the tmux session called NAME (each pane's process and all its descendants) must
carry that id in its environment, so a session renamed to a dead throwaway's name is refused. A pane from before row ids (an old row: no process in the
session carries an id) is bound by its name instead, and only when a Claude Code process (comm `claude`, trusted exe) is among them, NAME is a
throwaway's name and a fresh answer (the project record, else `pages.py`) says NAME is on no agents map, whichever door let YOU in: a plain program
under the name, a mix of processes with and without the id, or a pane with no id under a name that is no throwaway's, is refused.
With no tmux session of that name left the retire is refused at the plan, naming `sala forget-row NAME` (which clears the row and takes the owner's words), and nothing is queued. A rename of the spawner makes the field stale, and a stale or renamed spawner
counts as not live: a row with a throwaway's name is then retirable by any session (door (c), with the fail-closed agents-map check), while a row
whose name is no throwaway's is refused and takes the owner's words as before.

The marker of a no-words retire stores the row id it was queued for (`ownrow=`), and the runner (`op_run`) judges the retire again before it ends
anything: the same target checks (who may, no project, role, side or agents-map entry, the process binding above) and that the row under the name still has the
stored id. The session under the name may have been replaced between the two; on any mismatch the operation goes stuck with the reason and
nothing is ended: the runner records it directly (`op_finish`) and starts no `claude -p` helper (the helper's
tools include `salamander retire`, which would have run with none of these checks).

The Bash guard (`lib/guard.py`) reads the same field for the one stop it lets a session make itself (without it a session had to ask the owner to run
`kill <pid>` by hand for its own throwaway):
`kill <pid>` (any signal option) of the claude of a throwaway the calling session started. The caller is the tmux session of `TMUX_PANE` in
the hook's environment (the identity the master check uses; the hook gets the environment Claude was launched with, never the command text,
so a command cannot set it; no pane, no caller, no allowance). The pid is placed with `tmux list-panes -a` on the
caller's server (the pid or an ancestor is a pane's process); that session must not be the caller or the master, and `sessions.json`
(`$SALA_SESSIONS_FILE`, else beside `$SALA_SIDECAR`, else `$XDG_STATE_HOME/salamander`) must hold exactly one live row of that name with no
project, role or side and `spawned_by` = the caller, and the pid's own environment must carry the row's id as `SALA_SESSION_ID` (the pid is
bound to the row by the process, so a session renamed to a dead throwaway's name is denied). Any failed read denies, as before. **The guard's exemption is narrower on purpose than the queue's no-words retire**: it still allows only the
spawner (`spawned_by` = the caller), never the master or an unowned throwaway, since it ends a process by pid at once with no queue, no runner re-check and
no project-record look-up; the two paths differ, and the master's or any session's door is `sala op retire`, never `kill <pid>`. A command with another claude pid in it, a name
(`pkill`, `killall`), `kill -1` and a process group are denied as before; the deny text says which stop is allowed.

The guard also denies putting a process into another session's tmux, which would run it as that session: `tmux new-window`, `split-window`,
`respawn-pane`, `respawn-window`, `join-pane`, `move-pane`, `break-pane`, `swap-pane`, `swap-window`, `move-window`, `link-window`,
`rename-session` (and their aliases, and any unambiguous prefix such as `new-win`) and `new-session -t`, on the fleet's server, whose target
(`-t`, and `-s` for the commands that take a source) is a session other than the caller's own. A target with no colon (`victim`, `=victim`,
`new-session -t=victim`) is looked up both as given and as `<target>:`, so `=victim` and a window in the caller's own session that is named like
the victim cannot hide it; the options that take an argument are read off tmux 3.6's own usage (`split-window -p 50 -t victim:`, `-f`,
`-l`); a word that ends in `;` (`owner:\;`) ends a tmux command like a bare `\;`; and a `TMUX_PANE` assignment, `env -u TMUX_PANE` or
`env -i` in front of a placement command is denied, since tmux takes its default target from it. No `-t`, a target in the caller's own session,
a target that names nothing, and a private server (`-L`, `-S`) pass; `rename-session` of the caller's own session passes (sala's own rename
runs from its operation, not from a Claude session's command); the master's own pane is exempt. The deny text says to run it in your own
session, in a throwaway you start with a bare `sala spawn NAME`, or on a private test server. (`send-keys -t` is not covered: sala's cue uses it.)
Known limits, which only a same-user agent that goes out of its way can use: a placement carried by `if-shell`, `run-shell`, `pipe-pane`,
`source-file` or `bind-key` (the guard reads the command line, not tmux's own command language inside it), and a target given as `-t "$VAR"`
(the value is not known when the hook reads the command); a rule on those would deny sala's own cue and the web layer. The guard is a
safety net against a mistake, not a boundary against an agent that copies binaries or forges its own environment.

A no-words retire never reaches the `claude -p` helper: when the runner's re-check fails (session replaced, row changed, the
marker without its row id, a process of the target with another id) the operation is recorded `stuck` with the reason and `nothing was ended`,
and `op_stuck` starts no helper for any marker that carries `nowords=`, since the helper's tools include `salamander retire` and its brief
is told never to retire for such an operation. A process that exits (or is a zombie, whose environment reads empty) between the listing of the
target's panes and the read of its environment is skipped; a live process with another id, or none, still refuses.

`sala sessions transcript <ref> [--json]` is read-only, like `resolve`: where the conversations of a row are on disk. The current one
(the row's last `transcripts` entry) first, then the earlier ones, each with the file's path under the CLI's projects directory
(`SALA_PROJECTS`) or "(not on this box)". A live row wins over a retired one of the same name; several live rows: exit 2, nothing
picked; none: exit 1; nothing is written and nothing logged. `--json`: `{id, name, state, transcripts: [{id, path, current, machine,
at, why}]}`.

## A revive or restore with a reason instead of words: `op revive` / `op restore` with `--item` / `--why`

Added Tue Nov 3rd 2026. `lib/op.sh` decides per verb and arguments what the marker needs (`op_words_policy VERB ARGS…`; its header comment lists every verb with
the reason): `owner` (the owner's words, the default), `reason` (a recorded reason in place of words) or `throwaway` (the retire door above). Only `revive` and `restore` are `reason`, and
each in one shape: `sala op revive --only NAME [--only NAME]… [--force] (--item board#N | --why "<one line>") --from YOU`, with no `--words`; and
`sala op restore --only NAME [--only NAME]… (--item board#N | --why "<one line>") --from YOU` (no `--force`, no `--missing`), for a session whose tmux session is gone:
each NAME is a row of the pane map (not a live registry row) whose conversation is live nowhere, not the master, not the Remote Control session and not the asker, bound by the row's
conversation id in `ownrow=`. `op --plan restore …` is `restore --dry-run`: it refuses a live tmux session (use revive), a name with no row and a conversation live elsewhere. The runner passes
the guard by its `sala-op-<id>` unit (no flag or environment marker), and a raw `sala restore` from a Claude session stays refused. Who, the reason and the checks below are the same for both.

- **Who:** any live Claude session, placed by process ancestry (`op_caller_is`, the same placement retire's door uses; `TMUX_PANE` and `--from` are claims only).
  `SALA_OP_REASON_FROM` (empty by default = any session) is a space-separated allow list of session names that narrows it.
- **What:** every NAME is a live row of the registry, a Claude session, not the master and not the asker. The marker stores each row's id (`ownrow=`).
- **The reason:** `--item board#N` or `--why`, one of them, accepted only with revive. `--item` is a **format check only** (`board#` and digits): sala makes no lookup in
  stackshot, so a wrong id passes; the check makes the reason carry something a person can follow, it does not prove the item exists. `--why` is one line,
  at least 3 words, at most 200 characters. The marker keeps `item=` or `reason=` (not `why=`, which the stuck handler already uses), `op --list` shows it, and the result
  notice carries it.
- **Refused without words:** a sweep (no `--only`), `--rescue`, `--lane-default` and any other flag; `--item` and `--why` on any other verb.
- **The runner checks again** (`op_run` through `op_words_policy`): the shape, the reason, the allow list and that each row under its name still has the stored id.
  On any mismatch the operation is recorded stuck with nothing run, and no helper starts for it. A no-words marker's `claude -p` helper (if its run fails after the check)
  may run only `salamander revive [--force] --only` (a restore: `salamander restore`) the names in the marker.

Tests: `tests/retire-own.sh` (sections on the reason door and on restore), `tests/ledger.sh` (`restore --dry-run`).

## The flag and how to revert

`SALA_SESSIONS=off|write|read` in the config (default `write`). `off` writes nothing (`--migrate`/`--check` refuse to write, `record` and
the hook do nothing and exit 0, `spawn` makes no id and exports none);
`read` is reserved for a later phase and acts as `write` now. Phase 3: `off` also stops the heartbeat's publish of `session-registry.json`. To revert: set `SALA_SESSIONS=off`, or delete `sessions.json`
(the next writes start a new file; `sessions-history/` keeps the previous copies for 30 days). Nothing else reads the file (but `spawned_by`, for the no-words retire and the guard's pid stop: without it both
fall back to the owner's words and the queue), so neither step changes any other behaviour.

## The lock

The registry shares the pane map's lock (`pane-map.tsv.lock`, fd 6). `ledger_write` already holds it when it writes the registry.
`lane_write` and `model_write` take their own lock (fd 3) first, release it, and only then take fd 6 for the field copy (a 10 s
wait, then a log line), so the two are never held together. `--migrate` and `--check` take it for their whole run.

## Tagging a row: `sala sessions tag`

`project` and `role` used to be set only by `spawn --project --role`, at the session's birth. A row made any other way (adopted, restored,
imported by `--migrate`, a spawn without the flags) kept both `null`, and `resolve role:<project>/<role>` found nothing for it.

`sala sessions tag <id|name> [--project <page key>] [--role front|back] [--project-key <page key>] [--dry-run]`

- The session: a registry id, else the name of a live session, else a unique id prefix of 8 or more characters (`record`'s lookup). It must
  be **live**: a retired row is refused (`is retired`), and a retired session's name does not resolve at all.
- At least one field. **Only the given fields are written**; nothing else in the row changes (no transcript, no `lane`, no `aliases`).
  `--project` is the page key as `spawn --project` records it (no whitespace, for example `projects/demo-docs`).
  `--role` is `front` or `back`: the vocabulary of stackshot's interface 19, unchanged. Anything else is refused.
- **`--project-key`**: the row has no field of that name. `project_key` exists only in the published `session-registry.json`, where
  `export_doc` writes it as a copy of `project` (phase 3, above) until stackshot ids exist. So `--project-key P` is `--project P` under its
  published name; giving both with different values is an error.
- `--dry-run` prints `would tag …` and writes nothing (no file, no log line, no lock). Tagging what the row already has changes nothing
  and says so.
- Same write path as every other writer: the pane map's lock (`flock -w 10`, fd 6), the atomic temp-file-and-replace save with the previous
  file copied to `sessions-history/`, a corrupt file never overwritten, and one `tag` line in `sessions.log` (`project None -> projects/demo-docs; role None -> front`).
  An unknown session, a retired row, a bad role or no field: the reason on stderr, exit 1, nothing written. `SALA_SESSIONS=off`: exit 1
  and nothing written (a person asked for the write, so it is not silent as `record`'s hook calls are).
- A second live row with the same `project` and `role` is allowed, and `tag` says so (`note: … also fills role:…`): from then on
  `resolve role:<project>/<role>` is ambiguous (exit 2) until one of the two is retagged or retired. Nothing is picked or moved for you.
- Afterwards `sala sessions resolve role:projects/demo-docs/front`-style references work for the row, and the next heartbeat publishes the
  fields (`project`, `project_key`, `role`). No contract change: the file's keys and the role vocabulary are as they were.

### The roles filled from the project record: `sala sessions tag --auto`

`sala sessions tag --auto [<id|name>] [--dry-run]` fills `project` and `role` of a live row that has none, from the same source of truth
the spawn checks already read: stackshot's project record (interface 20, `SALA_PROJECT_RECORD`, no older than
`SALA_PROJECT_RECORD_MAX_AGE`). A name under a project's top-level agents is a front agent of that project, one under its `background:`
agents a back agent. No new source, no guessing from a name.

- **Without a name** it goes through every live row with no role and prints one line per row (`would tag` / `tagged`, or `left NAME (id8): <reason>`) and a
  summary. **With a name** it handles that row alone: exit 0 (tagged, or already has a role: nothing is changed), 3 (the record does not list it), 1 (a
  retired row or an unknown name).
- **A row is left, with its reason, when** it is a side session (a side session is on no agents map), it is on no project's map, it is on the maps of several
  projects, or its row already names another project than the record does. A retired project in the record is skipped.
- **A role already on a row is never overwritten**, and a row with a project but no role is given the role from the record only when the project agrees.
  A row given a project and a role loses its throwaway tag, as with `tag --project/--role`.
- **The record cannot answer** (missing, older than the max age, not JSON, another schema): exit 4 with the reason on stderr and nothing written.
- `--dry-run` writes nothing (no file, no log line). Same write path as `tag` (the pane map's lock, the atomic save, one `tag` line per row in `sessions.log`).
- Callers: the watchdog tick runs it for every row with no role (the quiet form, best effort), and a bare `sala spawn` runs it for the new name before it
  marks the row a throwaway, so a name the record lists becomes that project's agent. The registry reader `back-names` (`lib/sessions.py`, no command of its own) is the read-only list the back agents' lane
  rule counts from: the rows whose stored role is `back`, or with no stored role whose record role is `back` (a record that cannot answer leaves the stored roles alone).

## Phase 2: an explicit signal for a fresh start

Phase 1 left `follow` out because most of its lines were noise. Phase 2 records a fresh conversation when the session itself says
so, and nothing guesses. The contract with stackshot is **not** changed: no version bump, no new file for stackshot to read.

### What writes now

| writer | what it records |
|---|---|
| `sala spawn` | before the pane's claude starts, `sessions_prepare` makes the live row of the name (or finds it: one live row per name) and spawn gives the pane its id as **`SALA_SESSION_ID`**: `tmux new-session -e` (the pane's shell, so a claude typed into it later, a recycle's resume included, inherits it) and again on the launch line (a tmux without `-e`). The pane's first conversation then lands on that row through `ledger_write add`, as before. A spawn that does not come up (claude dies, never starts) takes the row back (`abandon`, only a row with no conversation); a spawn killed in between leaves a live row with no pane-map row, which `sala sessions --check` retires. Off or failed: no id, no export, and the hook below finds the row by the tmux session name. |
| `sala sessions record` | appends a conversation to a row (below) |
| `salamander hook session-start` | the SessionStart hook calls `record` for `clear`, `resume` and `startup` (below) |
| `sala unpark` | the resumed (fork) conversation goes through the same call, `--why resume`, just before its pane-map add; the add then finds it listed |
| `salamander watch` (`lib/continuedin.sh`) | a live pane that moved to a new transcript id (a `continued-in` record in the old transcript): the new id (every hop of a chain, in order) is recorded `--why resume`, which makes the old id a non-current transcript of the row; the pane map follows in the same step. Also `watch --continued`, which `lib/follow.py` runs when a registry row's sessionId changes |

### The verb

`sala sessions record <session-id-or-name> --transcript <claude-session-id> --why clear|resume|start [--machine X]`

- The session: a registry id, else the name of a live session, else a unique id prefix of 8 or more characters (the ones `sala sessions` lists). A retired session resolves by id only.
- Appends `{id, machine, at, why}` to the row's grow-only `transcripts`. **Idempotent**: a conversation the row already lists, under any `why`, changes nothing. (That is what makes a recycle's `resume` of the same conversation harmless, where `follow` was noise.) `--machine` defaults to this box's letter.
- An unknown session, a missing or bad `--transcript` or `--why`: the reason on stderr, exit 1, **nothing written**.
- Same lock as phase 1 (the pane map's, `flock -w 10`), the same corrupt-file rule (never overwritten), `sessions.log` records each append as a `record` line. `SALA_SESSIONS=off` writes nothing and exits 0. Callers that must not be disturbed (unpark) use `sessions_record_soft`, which captures the output, logs a failure and returns 0.

### The hook

`salamander hook session-start` reads the SessionStart hook JSON on stdin (`session_id`, `source`, `cwd`, as Claude Code sends them):

| `source` | `--why` |
|---|---|
| `clear` | `clear` |
| `resume` | `resume` |
| `startup` | `start` |
| `compact` (or anything else) | nothing: a compaction keeps the conversation |

The row: `$SALA_SESSION_ID`; if that is unset, the tmux session name of the pane (`$TMUX_PANE`, the fleet's tmux server only), which covers a pane `spawn` did not make (adopted, restored) and a registry that was off at its spawn. Neither: nothing done.

It **always exits 0 and prints nothing, with one exception**: a SessionStart hook's stdout is added to the model's context, so all other output goes to `/dev/null`, garbage or empty stdin is ignored, and a failed `record` is a line in `sessions.log` at most. The exception is `source` `clear` for a live row whose `role` is `back` (not a side session): sala (only with `SALA_IDLE_WRAPUP=on`; off by default) clears a background agent that has been idle for 50 to 58 minutes (`lib/wrapup.sh`; one idle longer is left alone, its prompt cache being cold), the cleared conversation has lost the message that sent it to its mandate, and the hook prints one `hookSpecificOutput` / `additionalContext` JSON object telling the agent its name, its project (the project's page) and where its mandate is. `SALA_CLEAR_CONTEXT=off` prints nothing. A front agent, a start, a resume and a compaction print nothing as before. It does nothing when `CLAUDE_CODE_ENTRYPOINT=sdk-cli` (a headless `claude -p`, which a session starts with the session's environment and so with its `SALA_SESSION_ID`: it is not the session). `cwd` is read by nobody yet.

Add one more entry to the `SessionStart` array in `~/.claude/settings.json`, beside the existing ones:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "~/.local/bin/salamander hook session-start",
            "timeout": 45
          }
        ]
      }
    ]
  }
}
```

(Spelled like the other `salamander hook …` entries. No entry means nothing is recorded: spawn still makes and exports the id, and the registry stays as phase 1 left it.)

### Not changed

`follow` still records nothing. No contract file, no `SALA_SPAWN_REGISTER` variable (`SALA_SPAWN_SESSION_ID` stays in the proposal for phase 3), no new config knob: `SALA_SESSIONS` governs all of it. Not covered by the tests: the hook's JSON shape (the fields and `source` values are the documented ones, the fake claude runs no hooks), and what `CLAUDE_CODE_ENTRYPOINT` a `claude -p` run carries inside an sdk-lane pane.

## Phase 3: the published file and the resolver

Phase 3 is the first time anything reads the registry, and the first part of the [contract proposal](session-registry-contract-proposal.md)
to go live (stackshot's interface 19 in [stackshot-contracts.md](stackshot-contracts.md), version 4). `sessions.json` itself is still
local and unchanged; stackshot gets a **copy** with the fields it needs, and sala gets one read verb.

### The published file: `session-registry.json`

The heartbeat (`lib/heartbeat.sh`, the 5-minute timer) writes `$SALA_HEARTBEAT_STATE_DIR/<letter>/session-registry.json` for **its own
box** (the writer's letter, beside `machine.json` and `sessions.json`). It is built from this box's `sessions.json` by
`export_doc()` in `lib/sessions.py`:

```json
{ "schema": 1, "machine": "a", "written": "2026-01-05T11:00:00Z",
  "sessions": { "<sala session id>": {
      "id": "…", "name": "worker-1", "aliases": ["worker-old"],
      "project": "projects/demo-docs", "project_key": "projects/demo-docs", "role": "back",
      "lane": "subscription-1", "model": "opus", "effort": "high", "pane": "worker-1", "cwd": "/home/alex/…",
      "state": "live", "created": "<ISO Z>", "retired_at": null,
      "transcripts": [ {"id": "<claude session id>", "machine": "a", "at": "<ISO Z>", "why": "add"} ] } } }
```

- `project` is the row's project value, the page key as `spawn --project` recorded it, because stackshot project ids do not exist
  yet; `project_key` is the same value. Once stackshot ids exist (phase 5) `project` becomes the id and `project_key` keeps the page key.
  `role` is `front` or `back`, `null` where nothing was recorded; `lane`, `model`, `effort`, `cwd`, `retired_at` are `null` when empty.
- **Retired rows stay** (`state: "retired"`), so an old id still resolves. Rows are ordered by `created`.
- **`written` is refreshed on every heartbeat run**, even when no row changed. A reader tells a dead heartbeat from a quiet fleet by
  `written` being old; a file whose `written` is more than a few heartbeat intervals (the timer is 5 minutes) old is stale. The write is
  atomic (temp file, then replace). The two older files still change only when a fact does; this one differs on purpose.
- **The reading rule for transcript ids**: to find the session of a conversation, scan `transcripts[].id` of every row; the **last**
  entry of a row is its current conversation. A transcript id can in principle sit on two rows (a fork, an import); a reader must treat
  that as ambiguous and prefer a live row only when it says so (`sala sessions resolve --live` does exactly that).
- **Not published, last good file kept**, with one line in `sessions.log` (`heartbeat` op; not repeated while the last line says the
  same): `SALA_SESSIONS=off`, a missing `sessions.json`, a corrupt one. A kept file shows its age in `written`. Off also stops the
  publish for good until it is switched back; the file already there is not deleted.
- Live store only (never the git store; it carries working directories). A swept box (`SALA_FLEET_HOSTS`) gets no registry file: its
  `sessions.json` is not reachable from the writer.
- `sessions.json` (the one stackshot's `session_links` reads, keyed by transcript) is **untouched**.

### The resolver

`sala sessions resolve <ref> [--live] [--json]` (read-only: it writes nothing, not even a `sessions.log` line; it works with
`SALA_SESSIONS=off`, reading whatever file is there). The same lookup is `resolve(rows, ref, live_only=False)` in `lib/sessions.py`
(raises `Unresolved` with `.kind` `none` or `ambiguous` and `.candidates`).

`<ref>` is tried in this order, and the first kind that matches anything decides:

1. a session id, exactly;
2. a transcript id (any row whose `transcripts` lists it);
3. a unique prefix of a session id, 8 or more hex characters;
4. a name or an alias (together: both are names the row had or has);
5. `role:<project>/<role>`, for example `role:projects/salamander/back`: the **live** rows with that `project` and `role`.

Output: `id`, `name`, `state` (a retired row says `retired` and when), `project`, `role`, `pane`; `--json` prints the whole row.

| exit | meaning |
|---|---|
| 0 | exactly one row |
| 1 | none (also: `sessions.json` unreadable; the reason on stderr) |
| 2 | **ambiguous**: more than one row matches. Stderr says `ambiguous:` and lists every candidate id (with `--json`, stdout has `{"error":"ambiguous","candidates":[…]}`). Nothing is picked. |

Ambiguity applies to every kind, not only `role:`. The case that matters: a retired row's old name (its `name` or an alias) reused by a
live row. Plain `resolve <name>` is ambiguous then; **`--live` drops the retired rows first** and is the only thing that narrows it. Several
live rows still match → still ambiguous. Without `--live`, retired rows resolve and are marked retired. A `role:` ref looks at live rows
only (a role is filled by a running session); `--live` changes nothing for it.

### Not changed

No writer changed. `SALA_SESSIONS` stays the only flag (`off` also stops the publish). `record`'s own lookup (live name, id, prefix) is
as phase 2 left it; the resolver is separate. `SALA_SPAWN_SESSION_ID` for the spawn-register hook is not part of this phase. Not
covered by the tests: the file as stackshot reads it (the tests use temporary state directories).
