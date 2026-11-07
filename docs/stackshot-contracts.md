# sala ↔ stackshot: the interface contracts

contract-version: 40

Every interface between sala (this repo) and stackshot (`howardpark-ai/stackshot`), in both directions, and the scripts of a host config repo
that sit between them. One document, one version number. This is step 2 of the goal "sala runs, installs and is
documented without stackshot"; it describes, it changes nothing.

**The bump rule.** A change to any interface listed here (a path, a file's keys, a CLI's arguments or exit codes, an HTTP
route or its JSON, a marker string) bumps `contract-version` and adds a changelog line naming the interface and what changed.
Adding a new interface bumps it too. A change to this document's prose alone does not. The sala side tells
the stackshot maintainers before the bump lands, as the heartbeat header already says (`lib/heartbeat.sh:31-34`).

## Changelog

- **1** — Thu Oct 15th 2026. First listing: 17 interfaces as
  found in the main branches of both repos and in the owner's config repo. No interface was changed
  by this version; it records what exists.
- **2** — Thu Oct 22nd 2026. Interface 10 (the terminal app's board items): sala's web app now also
  reads `mover` {kind, who, via?}, `wait`, `expected_by`, `overdue` and `step` from each item of `GET /client/items` (stackshot's
  one rule for an item that waits) and serves them in `/api/board-items`; "waiting on the owner" is
  `mover.kind` `"owner"` (or its older spelling, read until stackshot's owner-role rename is live) when a mover is sent. All optional: without them the page falls back to `held`, as before.

- **3** — Thu Oct 22nd 2026. New interface 18: the parked-question seams. sala's
  `contrib/question-board.py` calls `client.py post question` and `client.py get answer` to file a
  background run's parked question as a `needs=decision` item and to read the owner's answer back. Nothing of stackshot changed.

- **4** — Thu Oct 22nd 2026. New interface 19: the session registry file
  `$SALA_HEARTBEAT_STATE_DIR/<letter>/session-registry.json`, written by the heartbeat next to `sessions.json` (schema 1: sala session
  id, name, aliases, project, role, lane, model, effort, pane, cwd, state live|retired, transcripts[]; `written` refreshed on every
  heartbeat; retired rows stay). Interface 1's `sessions.json` is unchanged. This adopts the sala-to-stackshot half of
  `docs/session-registry-contract-proposal.md`; the stackshot-to-sala half (`projects.json`) is still a proposal.

- **5** — Thu Oct 22nd 2026. New interface 20: the project record
  `~/.local/state/stackshot/projects.json` (stackshot `projects.py`, schema 1), which sala now reads. Interface 7 changes: the
  agents-map checks of `spawn --project` read the record first and fall back to `pages.py` only when the record cannot answer;
  `agent_unlisted` (plain spawn, rename) lets a name the record lists through without asking `pages.py`; a project spawn also
  refuses a `--role` that contradicts the record's `front` field. The "cannot tell" refusal and the exit codes (3, 4, 1) are
  unchanged. This adopts the stackshot-to-sala half of `docs/session-registry-contract-proposal.md`.

- **6** — Sat Oct 24th 2026. New interface 21: the New session form's project calls.
  sala's web app now calls stackshot's `GET /client/projects` and `POST /client/project`, `/client/project-list` and
  `/client/project-agent`, with the label `sala-web`, to pick a project by scope, make a new one with its
  knowledge-base page, list a hidden one again and add the new agent to the project before `sala op spawn` is queued. Nothing of
  stackshot changed. Interfaces 7 and 20 are unchanged: the spawn still reads the record, which these calls update.

- **7** — Sat Oct 24th 2026. Interface 21, `POST /client/project-agent`: stackshot
  now lets the sender `sala-web` add an agent to any listed project, one that has agents already included. 403 now means a
  retired or hidden project (it used to mean "not the keeper or a front agent"); 409 means the name is taken by another
  project's agent or pending from another sender. The terminal app drops its words for the old refusal and says the project is
  retired or hidden (403) or that the name is taken (409). Nothing else changed.

- **8** — Sat Oct 24th 2026. New interface 22: the For you calls. sala's web app now calls
  stackshot's `GET /client/for-you`, `POST /client/for-you/seen` and `POST /client/items/<key>/watch`, with the label
  `sala-web`, to show the For you list at the top of the items sheet, mark entries seen and set Watch or Mute for an item.
  All three are live; sala's side is one module and one fake, so a different shape
  changes those and nothing else.

- **9** — Sat Oct 24th 2026 New
  interface 23: the CLI update hook (`SALA_POST_UPDATE_CMD`, stackshot's `publish.py bump`; the same action as stackshot's
  `bump_versions` tool). Interface 12 changes in its words only: the done check is `lane` (stackshot renamed `sala_lane`;
  the old name is still accepted on stored items), and `lane-signin.state`, which stackshot reads beside
  `lanes.tsv` for a pilot re-send, is now named there as part of the interface. The index lists interface 19 once (a duplicate
  row of the same interface is gone; no number changed). No behaviour of either side changed.

- **10** — Interface 15 (the heartbeat's stackshot checkout pull on a second operating system) is retired: the fleet sweep has no
  PowerShell side any more and pulls nothing on any machine, so the `K:` line, its post
  and its `salamander-fleet-ssh.json` memory are gone. Interface 1: the optional `hub` field of `machine.json` (the sweep's
  config-repo fast-forward of a remote machine) is gone; no other key changed, and stackshot did not read it.
  Interface 6 (puller-lag) is untouched here; its removal is a later step.

- **11** — Mon Oct 26th 2026. Interface 6
  (puller-lag file and path unit) is retired, as 15 was in version 10: the machines it served are gone, so `watch --puller-lag`, the
  `auto_provision` step of the watch tick, `systemd/sala-puller-lag.path` and `.service`, `install.sh`'s enabling of them and the knobs
  `SALA_AUTO_PROVISION`, `SALA_PULLER_LAG_FILE` and `SALA_PULLER_LAG_CMD` are removed; sala no longer reads
  `~/.local/state/stackshot/clients/puller-lag`, and stackshot may stop writing it. The number stays. New knob `SALA_STACKSHOT_DIR`
  (unset: `~/stackshot`, every default as before; set empty: no stackshot, each default below empty): it is where the defaults of
  interface 7 (`pages.py`), 8 (`SALA_SPAWN_ASK_CMD`), 9 (`release.sh`'s client), 11 (the terminal app's roles command) and 18 (the board
  scripts' client) point, and of the side-session commands (`SALA_SIDE_*_CMD`, which have no entry here). Interface 7 drops the
  frozen-copy fallback (a copy of `pages.py` in a host config repo). Interface 12 gains its sala-side guard,
  `tests/stackshotshape.sh`, and becomes stable: a change to the shape of `lanes.tsv`, `lane-default` or `salamander-limit.json`
  fails that suite first. Interface 7 states, and the README says, that `spawn --project` is the one command that needs stackshot and
  a local mirror of the pages and stays fail-closed (no abstraction until a machine without stackshot needs project spawns). Prose only, no
  interface change: the readers of `machine.json` and the meaning of `url` in `sessions.json` are corrected in the heartbeat
  header and the README.

- **12** — Mon Oct 26th 2026 (the lane name `awsplatform` read badly). The lane
  `awsplatform` is now `aws-platform`: a lane NAME is data in four interfaces, and its value changes. Interface 12: a `lanes.tsv` row
  and the `lane-default` line for that lane say `aws-platform` from now on, and `salamander-limit.json`'s `panes[…].lane` too (sala's
  `proc_lane` prints the new name). Rows written before the rename keep the old word until the next write that carries them or
  `sala lane --migrate` (which sala's install.sh runs); so for a while the old word can still be read from the files. **stackshot should
  treat `awsplatform` and `aws-platform` as the same lane**: its `lane <session> <lane>` done check compares the recorded lane with the
  requested one, and an item asking for either must close on either (stackshot may stop accepting the old word after the migration has
  run on every machine that has the lane). Interface 19 (`session-registry.json`): the published `lane` is the new name whatever the row
  still holds. Interface 1 (`sessions.json`) carries no lane name. The shape of every file and the CLI's arguments and exit codes are
  unchanged; sala's own CLI, `sala op lane`/`spawn --lane` and the web payloads accept the old word as an alias. New: `sala lane
  --migrate [--dry-run]` (sala-internal, not an interface of stackshot). The config variables of the lane keep their names
  (`SALA_LANE_AWSPLATFORM_*`: a hyphen cannot be in a variable name). `tests/stackshotshape.sh` gains the check.

- **13** — Tue Oct 27th 2026. Interface 21 has a second caller and a second call: `sala rename OLD
  NEW` now runs stackshot's `client.py post project-agent-rename <hub page> OLD NEW --sender sala-rename` (CLI form, from the sala host, so
  the server's form_senders/form_machines rule for the label `sala-rename` applies; `SALA_RENAME_SENDER` overrides the label) when NEW
  is on no project page, instead of refusing. The server renames OLD's entry in place (it keeps its line, place in the map and front or
  background side), so sala sends no role, side or line and reads none from the project record. The hub page comes from `pages.py
  agent-listed NEW`'s refusal text (interface 7: "is not under `agents:` on <page> (the page whose `display-name:` line is <project
  name>)", or the older "(steward …" wording). Exit 0 with `result` "renamed" is done; "already renamed" (200) is done only for a rename
  sala itself started (sala keeps `rename-listed.tsv` in its state dir for 3 days); exit 1 with the reason on stderr (409 NEW already
  listed, 404 OLD not listed, 403 not the form, 400 prefix or ambiguous slug, 502, `[0]` not reached) refuses the rename and renames
  nothing. Interface 20's "sala never calls it" (`post project-agent`) still holds. The label `sala-rename` has to be in stackshot's
  `[project_agent] form_senders` for the call to pass (stackshot side; until then the call answers 403 and the rename is refused).
- **14** — Wed Oct 28th 2026. Interface 21 gains a third caller: `sala rename OLD NEW` of a
  SIDE SESSION (OLD has a record under `$SALA_STATE_DIR/side/`; NEW is not a `-side-` name and its project does not list it) now runs
  stackshot's `client.py post project-agent <hub page> NEW --role <NEW's part after the project's name> --front --mandate "<one line, 200
  characters at most>" --sender sala-web` (CLI form, from the sala host, so the existing `sala-web` form_senders/form_machines rule applies;
  `SALA_RENAME_LIST_SENDER` overrides the label), because a side session is on no page's agents map and has no entry for
  `project-agent-rename` to move. The hub page is the side record's `project`, else the one the origin agent's registry row carries; with
  neither, the rename is refused in its plan (`--dry-run`, `sala op --plan`). Stackshot records a PENDING front agent (`page_owed: true`,
  interface 20; the page's own line stays the page keeper's to add) and the rename goes on; a refusal (403 hidden or retired project, 409
  name taken or pending from another sender, 400 prefix, `[0]` not reached) refuses the rename with stackshot's reason and renames nothing.
  The call is made after the busy-pane wait, just before `/rename` is typed, and repeating it is harmless (same role and line: "already
  recorded … as it stands"). Interface 20's "sala never calls it" (`post project-agent`) no longer holds for this one path. A session with
  no side record keeps the `project-agent-rename` path of version 13; `--sync` still never calls stackshot.
- **15** — Wed Oct 28th 2026. New interface 24: the terminal-prompt "Your move" row. Where sala
  posts the "<session> is waiting for an answer in its terminal" notice (the Notification hook's instant alert and the stuck watch's
  90 s post, `lib/stuck.sh` / `lib/watch.sh`), it also runs `client.py post terminal-prompt open --session <name> --question=<one line,
  200 characters at most> --sender sala-stuck` (CLI form, from the sala host; `SALA_STUCK_SENDER` overrides the label), and
  `... terminal-prompt clear --session <name> --sender sala-stuck` when the pane stops waiting. stackshot's side was being built when
  this was written (unverified against a release); until it answers, each call fails and is logged, and the notice is unaffected.
- **16** — Wed Oct 28th 2026. New interface 25, the retire call: after a `sala retire <name>`
  has succeeded (`--busy` or `--skip-writeup` too; never in `--dry-run`), sala runs `client.py post project-agent-retire <project> <name> --sender
  sala-retire` (`SALA_RETIRE_SENDER` overrides the label; `timeout 45`, stdin closed) so that a retired session does not stay a pending
  agent (`page_owed`, interface 20) on its project. stackshot's side is live; its answers in this version: 200 the pending entry is dropped, 202 the agent is
  on the page's `agents:` map and the page keeper is told to remove the line (or was told already), 404 it is not listed, 409 no one to tell
  or a rename of the page is in progress (the client exits 0 on 200 and 202, 1 with the reason on the others); stackshot's answers and the
  timeout changed in version 25 (below). None of them changes the
  retire: a failure, a timeout or a missing `client.py` is one line in `~/.claude/salamander-retire.log` and one "ℹ" line in the retire's
  output, never a change to the retire's exit or result. The project is the session's registry row `project`, else a side record's project
  or its origin agent's; none known = no call. Numbering: version 15 and interface 24 belong to the terminal-prompt row, so this
  entry takes the next free pair, 16 and 25.
- **17** — Wed Oct 28th 2026. New interface 26, the unit-gap message: `sala job check --post`
  (`lib/unitjob.py`; the `sala-unit-gaps.path` unit and the watch tick) runs `client.py message <builder> - --sender sala-unit-gaps`
  with the gap text on stdin, once per timer and gap code, to the builder agent of the repo that holds the timer's script (the table `lib/unit-repos.tsv`). stackshot's client has no call that files an item for a named session or
  closes one, so a message is what exists; nothing is closed on the board when a gap is fixed. Numbering: the next free pair when this
  was written.
- **18** — Wed Oct 28th 2026. Interface 26 changes from a message to a keyed item call: `sala job check --post`
  now runs `client.py post job-gap open <timer> <code> --repo <owner/name> --detail <text> --sender sala-unit-gaps` for a new gap (one open
  board item per timer and code; a repeat open prints the same item id) and `client.py post job-gap clear <timer> <code> --sender
  sala-unit-gaps` when the gap is fixed (the item closes), instead of `client.py message <builder> -`. The `--repo` is the GitHub owner/name
  of the repo that holds the timer's script, a new last column of `lib/unit-repos.tsv`; the mover is the builder of that repo's project,
  set by stackshot. stackshot's side is live. Version 17's message form is gone; its
  `unit-gaps.tsv` records (no item id) are opened once more as items.

- **19** — Wed Oct 28th 2026. Interface 4 (post-recycle hook) changes its timing and adds one
  variable. Until now sala called the hook when a recycle's sweep ended and again for every pane a retry worker or `watch` brought
  back later (the same `SALA_RECYCLE_STARTED`, a shrinking `SALA_RECYCLE_SKIPPED`). Now it calls it ONCE PER CLEARED FLAG: a flag
  (a recycle, with the time it was set) clears when every live pane has relaunched at least once since that time. New:
  `SALA_RECYCLE_FLAG_AT=<epoch>`, the flag's time, always equal to `SALA_RECYCLE_STARTED` (kept for the existing reader).
  `SALA_RECYCLE_SKIPPED` is now the panes the flag did not get back: empty for a full clear (`SALA_RECYCLE_RESULT=ok`), the given-up
  panes for a partial one (`partial`): a pane held on the deferred list past `SALA_LATER_LIMIT` (3 h, default) no longer holds the
  flag open, the flag clears with that pane named. A flag still waiting for a busy pane fires nothing yet. The command line and
  the answer line are unchanged. stackshot's side (pending when this was written: `client.py recycled` has no `flag_at` yet) is to
  read it from the new variable (or `--flag-at`) and post `{kind, started, flag_at, result, skipped[]}`; until then the extra
  variable is ignored and `started` carries the same number.

- **20** — Wed Oct 28th 2026. New interface 27: the CI-run files. sala's `sala-cipoll.service` keeps one JSON
  file per repo in `~/.local/state/salamander/ci-runs/` (`<owner>__<repo>.json`: the 30 newest workflow runs and the epoch second of the last successful
  look), and `salamander ci-runs <owner/repo> [--sha SHA] [--max-age SECS]` reads it. stackshot's builders and its release script can wait on CI through
  it instead of each spending GitHub calls of their own. Nothing of stackshot changed. Format and exit codes: `docs/ci-runs.md`.

- **21** — Wed Oct 28th 2026. Interface 1 (`sessions.json`): the key of a pane whose conversation
  was moved into a background job ("← for agents"; the registry holds a second row, `kind` "bg", under the same name) is now the
  JOB's conversation uuid (the live one), not the uuid the pane's row kept from before the move, and the bridge in `url` is the
  job row's when the pane's is null. One entry per session, as before; the shape of the file is unchanged. Any other pane is keyed
  as it was. Interface 19 (`session-registry.json`) and the pane map's file format are unchanged (the map row of a parked pane now
  follows the job's conversation, as a row follows any switch). Same change: `sala revive`/`recycle` treat a parked pane by its
  job's state and resume the job's conversation (`lib/common.sh`, "a pane parked on a background job").
- **22** — Thu Oct 29th 2026. Interface 26 (unit-gap item): `<code>` gains `no-project`, a timer
  whose service unit has no `X-Project=<scope/project>` line (the job's project, which the Overview's Schedules tab shows as its
  Category). The command, its options and the one-item-per-(timer, code) rule are unchanged; stackshot already takes any code that
  matches `[a-z][a-z0-9-]*`, so it needs no change. Until `contrib/backfill-job-projects.sh` has set the project of the jobs that predate
  the line, a pass of `sala job check --post` opens up to its usual three `no-project` items.
- **23** — Fri Oct 30th 2026. Interface 3 (inbox hold): when sala writes the hold. It used to write one
  pane's keys inside that pane's close, right before its `/exit`, so a line stackshot's poll had handed out and the pane had acked a
  moment earlier was off the queue and the `/exit` killed the turn that was to act on it.
  Now a sweep writes the hold for every pane it is about to close when phase 2 starts, waits `SALA_HOLD_SETTLE` (3 s: about 80 ms
  from the poll taking a line to the CLI dequeueing it, the poll running once a second; measured on stackshot's side)
  for a line already in flight to land, and re-checks each pane just before its `/exit` from state the CLI itself keeps (registry
  status and idle stamp, the Stop hook's busy record, work children, scratch writes; not the transcript, which has no user message
  yet for a line dequeued but not yet logged); a pane no longer idle is deferred (a transient skip, retried later) and its hold is
  cleared. A hold that waits long (a long sweep, the `--self` worker's waits) has its ledger row written again, so the 10-minute
  stale drop never takes it from a pane still waiting; a sweep killed in phase 2 releases the holds of the panes not yet exited. The files, the key format, the lifetime (cleared after the resume, or on
  any skip or failure, or by `inbox_release_stale` at 10 min) are unchanged, so stackshot needs no change; its `inbox.take` simply
  sees every held key earlier, by the length of the sweep's phase 1 to phase 2 gap plus the settle.

- **24** — Sat Oct 31st 2026. Interface 25 (project agent retire) and interface 11's `get roles`: `sala retire` now also reads stackshot's roles list.
  Rows that `migrate` imported carry no `project`, so a retire of one logged "no project known" and never called `project-agent-retire`, and the
  retired agent stayed on its project's agents map. With no project on the registry row or a side record, sala takes the project the roles list gives
  the retired session's name (`client.py get roles`, else `~/.local/state/stackshot/roles.json`, the same `{"sessions": {name: {project, role}}}`
  shape) and makes the same call. No change on stackshot's side: it only sees the call it already answers, for agents it used not to be told about.

- **25** — Sat Oct 31st 2026. Interface 25 (project agent retire): stackshot's answers changed (live), and sala follows. stackshot now
  removes the retired agent's line from the project page's `agents:` map itself (and adds a timeline line to the page), where it used to leave a retire
  line for the page keeper. The answers are now: 200 with `result` `line removed` (the page's line is gone), `dropped` (the agent was only pending) or
  `not listed` (on no page, not pending: a repeat after a lost reply is this); 502 when the page could not be read or written, or the line is gone but the
  timeline line was not written (the reason says which: ask again if the line is still on the page; if only the timeline line is missing, add it by hand,
  since a repeat answers `not listed`); 422 the agents block cannot be edited in place; 409 only for "a rename or
  retire of the page is in progress"; 404 only for an unknown project; 400/403 a bad call. There is no 202 any more, and no 404 or 409 for "not listed" or
  "no one to tell". sala's call: `timeout 45` becomes `timeout 90` (the page is read, written, read back and given a timeline line; a timeout adds that an
  immediate retry may get a 409 "in progress" while stackshot finishes), the "ℹ" line says which of the three results it was in plain words, a 502 gets
  its own "ℹ" line with the reason, the command to ask again and the timeline-line hint, and a 422 or 409 is said as "stackshot refused (status): reason";
  a long answer is cut in the middle, so the end of a reason is kept; the retire itself is untouched by any answer, as before.

- **26** — Sun Nov 1st 2026. Interface 25 (project agent retire): `sala retire` now reads before it ends a session. `client.py get items <key>` (the call the side-session gate already makes) is asked first by the tmux name, then by the conversation id: an item whose `roles` has `mover` and that is not `held` makes the retire refuse, listing the ids, unless `--leave-items`; an answer that cannot be had (no client, a non-zero exit, a timeout of `SALA_RETIRE_ITEMS_TIMEOUT` (30 s), an answer that is not `{"items": [...]}`) also refuses, with the reason, and `--leave-items` overrides it. No new route, no change to the retire call itself; stackshot only sees one more reader of the items list. The same release splits `sala retire` into `retire` (a Claude session, by its exact tmux name or `--id`), `close-shell` and `forget-row` (neither calls stackshot) and removes `--force` (now `--busy` and `--skip-writeup`); the `project-agent-retire` call is unchanged.

- **27** — Sun Nov 1st 2026. New interface 28 (lane names: `salamander lane names [--json]` and `$SALA_STATE_DIR/lane-names.json`), and interface 12 changes: the subscription lanes are `subscription-1` and `subscription-2` now. The words sala writes into `lanes.tsv`, `lane-default`, the `lane` of each `panes` entry of `salamander-limit.json` and the keys of `lane-signin.state` (`subscription-1.seen`, `subscription-2.seen`, ...) are the new codes from this version on; files written before carry older lane words and are not rewritten by a read, so a reader sees both words for a while and reads an older word as the lane's current code through the `aliases` of `lane-names.json`. The display name of a lane (`Subscription 1` for `subscription-1`) is a sala setting and is read from the same table, never spelled by a reader.

- **28** — Mon Nov 2nd 2026. Interface 10 (the terminal app's board items): sala's web app no longer reads a legacy spelling of the owner. stackshot sends `mover.kind` `"owner"` and `needs` `"decision"` only, and its stored items were rewritten; "waiting on the owner" in `/api/board-items` is now `mover.kind` `"owner"` or a `needs` of `"decision"` or `"owner"`, and a legacy value counts as nobody's move. The shapes sala sends are unchanged.

- **29** — Mon Nov 2nd 2026. New interface 29: the fleet-op end event. At the end of every `sala op` (done or stuck), `lib/op.sh` (`op_event`)
  calls `client.py event --kind fleet_op --verb <verb> --machine <host> --sessions <N> --result ok|partial|failed --text "<one line>"` (stackshot's
  `event_waits.py`), so an item with an event wait on `fleet_op <verb|any|many>` is woken by the operation. Nothing of stackshot changed.

- **30** — Tue Nov 3rd 2026. Interfaces 5 and 13: the watchdog's two guards against a second recycle. Interface 5: the ids
  `recycle-wanted` prints may carry `~<ref>` (the change a flag waits for) after the `@<epoch>` sala already read; a flag is held
  while its change is not in the production checkout, and skipped when every pane started after it. Interface 13: the request marker
  has an optional 4th field and `sala recycle --when-idle` an optional `--change REF`. Nothing changed on stackshot's side: it still prints bare
  ids until it adds the suffixes (see 5).

- **31** — Wed Nov 4th 2026. Interface 10 (the terminal app's board items): a stackshot change (live) changes what `GET /client/items` sends for an item
  in state `doing`: `wait` is `"doing"` (it was `"expected"`), `expected_by` is `null` and `overdue` is `false`, so a doing item carries no expected
  time and is never past due. The other waits keep their `expected_by`. sala-web needed no change: it drops a wait kind it does not list (`"doing"`
  as it did `"expected"`) and a null date, and the item stays in Agents at work. Entry 2 above describes what version 2 read and is left as it was.

- **32** — Wed Nov 4th 2026. New interface 30 (sala-web's Machines tab reads stackshot's state files): the Overview's third tab reads `site/versions.json`,
  `runners-snapshot.json` and `clients/fleet/<letter>/machine.json` from stackshot's state folder, read-only. Nothing changed on stackshot's side; the listing records
  which keys of those files sala-web now depends on.

- **33** — Thu Nov 5th 2026. New interface 31 (the saved color combinations): sala's web app now calls stackshot's `GET /client/colors/combos`,
  `POST /client/colors/combos` and `POST /client/colors/combos/delete` (live), with the label `sala-web`, for the color tool's saved list: one list on the
  account that stackshot's page shares. Nothing of stackshot changed; it needs `sala-web` in `[project_agent] form_senders` and the machine in `form_machines`, as interface 21 does.

- **34** — Thu Nov 5th 2026. Interface 9 (release report): `release.sh` now also calls `client.py released --pr https://github.com/<owner>/<repo>/pull/<n> --sha <merge commit>`
  once per successful release, after the deploy and before the final `[release]` message, so stackshot settles the items whose step is `release PR #N` for this repo's pull
  requests, as it does for its own. stackshot refuses the call until its server accepts this repo; sala then only logs the refusal. The `message` call and its texts are unchanged.

- **35** — Thu Nov 5th 2026. Interface 12 (lanes and limit state): each entry of `salamander-limit.json`'s `panes` map gains a key, `rlane`, the lane the stopped pane
  RUNS on (`lane` stays the lane the stop is attributed to, which is always `api` for an API kind). Additive: `s`, `lane`, `lim`, `since`, `reset` and `e` are as before, and a reader
  that ignores unknown keys is unaffected. sala's own back agents' lane rule reads it.

- **36** — Sat Nov 7th 2026. Interface 30 (Machines tab files) no longer lists `runners-snapshot.json`: sala-web's `GET /api/machines` answer loses its `runners` key
  (it is `generated`, `tzLabel`, `updated`, `machines`), and the footer's `updated` comes from `site/versions.json`'s modification time. Nothing changed on stackshot's side.

- **37** — Sat Nov 7th 2026. New interface 32 (sala-web's Usage analysis, `GET /api/usage`): the Overview's fourth tab reads what this machine's Claude Code replies cost at list prices, by
  week, day, lane, model, project, agent and folder. The answer is `week`, `now`, `tz`, `tzLabel`, `resetKnown`, `anchor`, `generated`, `weeks`, `lanes`, `fields`, `rows`, `sameHours`, `unpriced`
  and `prices`; a request is `?week=0|1|2` (anything else is a 400) and optionally `?fresh=1`. sala reads the weekly reset from the quota answer it already serves and the lane table from
  `sala lane --json`; nothing is asked of stackshot, Anthropic or AWS. Listed because it is a route another page may read; nothing of stackshot changed.

- **38** — Sat Nov 7th 2026. Interface 32 (sala-web's Usage analysis) gains a second route, `GET /api/usage/digest?week=0|1|2` (optional `&fresh=1`): the same week as `GET /api/usage` in 1 to 7 plain sentences written by code
  (no model call), read from the same cached count. The answer is `week`, `now`, `generated`, `tz`, `tzLabel`, `resetKnown`, `scope`, `range` and `sentences`, with `pending`, `refreshing` and `error` as the first
  route has them. `GET /api/usage` is unchanged. Nothing is asked of stackshot, Anthropic or AWS.

- **39** — Sat Nov 7th 2026. Interface 32 (sala-web's Usage analysis) gains `GET /api/usage/replies`: the replies behind a selection (week, and any of day, lane, model, project, agent, folder), newest first, at most 200 with the number there are in all, each as time (KST), day, lane, model, project, agent, folder and dollars. Added for the Explorer view; the existing route is unchanged. Nothing of stackshot changed.

- **40** — Sat Nov 7th 2026. Interface 30 (Machines tab files): sala-web now also reads the `stackshot` key of `clients/fleet/<letter>/machine.json` (the commit the box's stackshot
  checkout is at) and a new file, `clients/advertised-commit` in stackshot's state folder (the commit the server tells the boxes to follow: 40 hex characters, one line), and a card judges
  a box's failed `stackshot checkout` attempt by where the box is: the attempt is dropped while the two commits are equal (except a `reload failed` attempt whose `to` is the first 12
  characters of the box's commit), so the card is red only while the box is elsewhere and clears itself when they match; with either commit unknown (key or file absent, unreadable or not
  one commit) the last attempt decides, as before. This follows stackshot's change to the same rule (its `machine_alerts(m, server)`). sala has no puller of its own, so the repository
  address the server now publishes in the poll's answer (`repo`) and the box-side moves are not sala's; nothing sala sends changed. Unknown keys are still ignored.

## How each entry reads

- **Direction**: `sala → stackshot` means sala writes or calls and stackshot reads or answers; `stackshot → sala` the
  reverse; a third party (a host config repo) is named where it also reads.
- **Mechanism**: the file path and its schema, or the CLI with its arguments and exit codes, or the HTTP route and its auth.
- **Owners**: `file:line` in both repos. Lines drift; the function or knob name is the durable key.
- **Absent or changed**: what sala does when stackshot is missing, unreachable or answers in another shape (fail-open or
  fail-closed), and the reverse where stackshot is the reader.
- **Test**: the sala suite that guards the shape (`tests/*.sh`, `web/tests/*.py`), or `none`; stackshot's own tests are
  named where known but are not sala's guard.
- **Stable / unstable**: *stable* = both sides treat it as a contract in their comments or docs; *unstable* = one side
  reads the other's internal state with no stated contract, or the piece is being retired.
- Shapes are quoted from the code as read when the document was written; anything not read is marked *unverified*.

## Index

| # | Interface | Direction | Stable | sala test |
|---|---|---|---|---|
| 1 | Heartbeat fleet store (`sessions.json`, `machine.json`) | sala → stackshot (+ a host config repo's link builder) | stable (the url + uuid key); machine.json unverified consumer | `tests/smoke.sh:69` |
| 2 | Message marker `<!-- sala -->` | sala → stackshot | stable | `tests/mod.sh:162` |
| 3 | Inbox hold files (`held-msg.txt`, `held-hub.txt`) | sala → stackshot | stable | `tests/phases.sh` |
| 4 | Post-recycle hook (`client.py recycled`) | sala → stackshot | stable | `tests/autorecycle.sh`, `tests/phases.sh`, `tests/sets.sh`, `tests/flags.sh` |
| 5 | Recycle-wanted (`client.py recycle-wanted`) | stackshot → sala (sala asks) | stable | `tests/autorecycle.sh` |
| 6 | Puller-lag file and path unit | stackshot → sala; sala → provision | retired in version 11 | none (the checks went with it) |
| 7 | Agents-map checks (`pages.py resolve`, `agent-listed`) | sala → stackshot | stable | `tests/spawn.sh` |
| 8 | Spawn keeper ask (`client.py message`) | sala → stackshot | stable | `tests/spawn.sh` |
| 9 | Release report (`release.sh` → `client.py message`, `client.py released`) | sala → stackshot | stable | `tests/release.sh` (the `released` call) |
| 10 | sala-web board items (`GET /client/items`) | sala web → stackshot | stable | `web/tests/test_board_items.py`, `test_board_items_ui.py` |
| 11 | sala-web roles (`client.py get roles`) | sala web → stackshot | stable | `web/tests/test_sessions.py` |
| 12 | Lanes and limit state read by stackshot | stackshot → sala | stable from version 11 | `tests/stackshotshape.sh` |
| 13 | stackshot's release asks for a recycle (`sala recycle --when-idle`) | stackshot → sala | stable | `tests/autorecycle.sh` |
| 14 | Reboot hooks (`docs/reboot-contract.md`) | sala → stackshot | stable (v1 contract) | none against a live hook |
| 15 | Heartbeat's stackshot checkout pull on a second operating system | sala → `~\stackshot` there | retired in version 10 | none (the checks went with it) |
| 16 | Fleet names TSV | host config repo → sala and stackshot | stable | `tests/smoke.sh` (fixture TSV) |
| 17 | Briefing link resolver (board-data, item URLs) | sala contrib → stackshot's store | stable | `tests/briefing/links.sh` |
| 18 | Parked-question seams (`client.py post question`, `client.py get answer`) | sala → stackshot | stable | `tests/boardseam.sh` (a fake client with the board's limits) |
| 19 | Session registry file (`session-registry.json`) | sala → stackshot | stable | `tests/sessions.sh` (phase 3 section) |
| 20 | Project record (`~/.local/state/stackshot/projects.json`) | stackshot → sala | stable | `tests/spawn.sh` (the project record section) |
| 21 | sala-web project calls (`GET /client/projects`, `POST /client/project`, `project-list`, `project-agent`) and, from `sala rename` (version 13), `POST /client/project-agent-rename`, and (version 14, a side session renamed to an agent) `project-agent` from the CLI | sala web, `sala rename` → stackshot | stable | `web/tests/test_new_session_projects.py`, `test_new_session_scope.py` (a fake stackshot); `tests/rename.sh` (a stub client.py) |
| 22 | sala-web For you calls (`GET /client/for-you`, `POST /client/for-you/seen`, `POST /client/items/<key>/watch`) | sala web → stackshot | stable | `web/tests/test_foryou.py` (a fake stackshot) |
| 23 | CLI update hook (`SALA_POST_UPDATE_CMD` → `publish.py bump`, stackshot's `bump_versions`) | sala → stackshot | stable | none (the suites blank the command) |
| 24 | Terminal-prompt "Your move" row (`client.py post terminal-prompt open` / `clear`) | sala → stackshot | stable from version 15 (stackshot side unreleased when written) | `tests/stuckpost.sh`, `tests/instantalert.sh` (a stub client.py) |
| 25 | Project agent retire (`client.py post project-agent-retire`, after a successful `sala retire`) | sala → stackshot | stable from version 16 (stackshot's side live); answers changed in version 25; items read before a retire added in version 26 | `tests/retire.sh` (a stub client.py) |
| 26 | Unit-gap item (`client.py post job-gap open` / `clear`, from `sala job check --post`) | sala → stackshot | stable from version 18 (a message in version 17) | `tests/jobs.sh` (a stub client.py) |
| 27 | CI-run files (`ci-runs/<owner>__<repo>.json`, `salamander ci-runs`) | sala → stackshot | stable from version 20 | `tests/cipoll.sh` |
| 28 | Lane names (`salamander lane names [--json]`, `$SALA_STATE_DIR/lane-names.json`) | sala → stackshot | stable from version 27 | `tests/lane-subscription-codes.sh` |
| 29 | Fleet-op end event (`client.py event --kind fleet_op`, from `op_finish`) | sala → stackshot | stable from version 29 | `tests/op.sh` (a fake client that logs the calls) |
| 30 | Machines tab files (`site/versions.json`, `clients/fleet/<letter>/machine.json`, `clients/advertised-commit` in stackshot's state folder) | stackshot → sala web | unstable (stackshot's own render inputs, no stated file contract on its side) | `web/tests/test_machines.py`, `test_machines_ui.py` (made-up files) |
| 31 | sala-web saved color combinations (`GET /client/colors/combos`, `POST /client/colors/combos`, `POST /client/colors/combos/delete`) | sala web → stackshot | stable from version 33 (permanent) | `web/tests/test_colors_combos.py`, `test_colortool_wiring.py` (a fake stackshot) |
| 32 | sala-web usage analysis (`GET /api/usage?week=0\|1\|2`, optional `&fresh=1`; the Digest's `GET /api/usage/digest` with the same query; Explorer's `GET /api/usage/replies`) | sala web → the page it serves (or any reader of the route) | unstable (the Report, Explorer and Digest views; `GET /api/usage/digest` added in 38, `GET /api/usage/replies` in 39) | `web/tests/test_usage.py`, `test_usage_ui.py`, `test_usage_explorer.py`, `test_usage_explorer_ui.py`, `test_usage_digest.py`, `test_usage_digest_ui.py` (fake transcripts) |

## 1. Heartbeat fleet store

- **Direction**: sala → stackshot.
- **Mechanism**: files. `SALA_HEARTBEAT_STATE_DIR` (default `~/.local/state/salamander/fleet`, `config.example:142`),
  one subdirectory per machine letter, two files:
  - `sessions.json`: `{"<transcript uuid>": {"name", "url", "seen", "machine"[, "previous_name", "renamed_at"]}}`.
    `url` is the session's link: on the writer's own rows the web link `SALA_SESSION_URL` gives (default empty, so the claude.ai address or `""`; a template such as
    `https://sala.example.com/#s={name}` with `{name}` percent-encoded as `encodeURIComponent` does,
    `lib/common.sh:107-112`), on a swept box's rows the claude.ai Remote Control address or `""` while the bridge is down.
    `previous_name` + `renamed_at` (ISO-8601 UTC) only on a row of the driving machine `salamander rename` renamed (`lib/heartbeat.sh:39-41`,
    written at `:311` from `salamander-renames.jsonl`, `lib/rename.sh:197`).
  - `machine.json`: `{"letter", "fleet", "claude", "checked", "master", "master_session", "fleet_ssh"}`;
    `checked` ISO-8601 UTC `Z` of the last change; `fleet_ssh = {"<fleet name>": {"letter", "ok", "since"}}` on the driving
    machine; `hub` (a swept remote machine's config-repo fast-forward) was removed in contract version 10.
- **Owners**: sala `lib/heartbeat.sh:18-45` (the header, which names the contract), `:250` `row()`, `:261` `publish()`;
  `lib/common.sh:95-119` (SESSION LINKS). stackshot `clients.py:62` `SESSION_LINKS_DEFAULT = "~/.local/state/salamander/fleet"`,
  `:410` `session_links()` (reads `<dir>/*/sessions.json`, keeps a row's `url` only when it starts with `http(s)`, keys
  lowercased, rereads on mtime change, logs a missing store once); `stackshot.example.toml:302` `session_links`. A host config repo's
  link builder reads `fleet/<letter>/sessions.json` too (name → url; `previous_name` never linked).
- **What stackshot reads today**: the `url` by transcript-uuid key, and nothing else from sala's store. stackshot's own
  fleet view (`clients.py:12-13`, `config.fleet_dir()` = `<state>/clients/fleet`) adds `online`, `source`, `setup`, `updates`
  and `status`/`gone` fields sala never writes; its reading of sala's `machine.json` was removed in a later release (comment in
  `clients.py`). *Unverified*: whether stackshot still reads `previous_name`/`renamed_at` from sala's file (its
  `clients.py:218` handles them from its own puller report).
- **Absent or changed**: stackshot without the store logs once and shows no session links (fail-open on its side). sala
  without stackshot writes the files all the same; nothing in sala depends on a reader. A change to the path, the `url`
  key or the uuid key breaks the links silently: the header says to tell the stackshot maintainers first.
- **Test**: `tests/smoke.sh:69-92` ("heartbeat: the files stackshot reads"). stackshot's side: `tests/contract_scenario.py`,
  `tests/links_scenario.py`.
- **Stable**: yes for `sessions.json` (`url`, the uuid key, the path). `machine.json`'s consumer is unverified.

## 2. Message marker

- **Direction**: sala → stackshot.
- **Mechanism**: a string in a typed message. Every message sala types into a pane (a brief, a `--prompt`, a cue) starts
  with `<!-- sala -->` and a space; a slash command is typed bare. `SALA_MSG_MARK='<!-- sala -->'`, "fixed, not a config
  knob: stackshot matches this exact string at the start of a recorded user message" (`lib/common.sh:2298`).
- **Owners**: sala `lib/common.sh:2286-2299` (the rule), `tui_send()` right after. stackshot `said.py:25`
  `MARKER = "<!-- sala -->"`, `:146` `injected()` (a message that starts with the marker, leading whitespace aside, is
  refused as a quote of the owner's); `stackshot.example.toml:284-286`.
- **Absent or changed**: no runtime coupling; a changed marker lets stackshot attribute sala's text to the owner (its
  quote-origin check misses). sala without stackshot: the marker is harmless.
- **Test**: `tests/mod.sh:162-182`; `docs/test-coverage.md:237-244`.
- **Stable**: yes.

## 3. Inbox hold

- **Direction**: sala → stackshot (files in stackshot's state dir).
- **Mechanism**: `SALA_INBOX_HOLD_DIR` (default a folder under stackshot's state directory, `lib/common.sh`). sala appends a
  pane's keys (its transcript uuid and its name, one per line) to `held-msg.txt` and `held-hub.txt` while it relaunches the
  pane, removes them after, and keeps its own ledger `salamander-inbox-holds.tsv` so `watch` drops a hold older than 10 min
  that a dead relaunch left (`inbox_release_stale`).
  **When** (contract 23): a sweep writes the keys of every pane it will close at the start of phase 2, before any pane is exited,
  then waits `SALA_HOLD_SETTLE` (3 s) so a line stackshot handed out just before the hold has reached the pane; each close then
  re-reads the pane (`is_idle_reason`: registry status `idle`, idle for `SALA_IDLE_SETTLE`, the Stop hook's busy record, no work
  child, no recent scratch write; it never reads the transcript) just before it types `/exit`, and a pane that is no longer idle is
  deferred with its hold cleared. The `--self` worker does the same for the master's pane (hold, settle, wait for idle, one last
  look, then the retry worker if it is still busy; its waits stack, up to three times `SALA_SELF_WAIT`, 15 min by default). A pane skipped in phase 1 is
  never held. The hold is cleared for a pane that is skipped, deferred or fails to exit, and after a successful resume.
- **Owners**: sala `lib/common.sh` `_hold_edit`, `inbox_hold`, `inbox_touch`, `inbox_release`, `inbox_release_stale`;
  callers `lib/revive.sh` (phase 2's hold loop and exit trap, `close_pane`'s re-check and releases, the `--self` worker). stackshot `inbox.py:30` `FLAGS`, its inbox state folder
  (`paused-<src>.json`, `held-<src>.txt`, `release-<src>.txt`), `:146` reads them; `inbox.take` skips held keys.
- **Absent or changed**: "A missing stackshot is no error: nothing is held" (the comment above `inbox_hold` in `lib/common.sh`): the helpers return 0
  when the directory does not exist. A renamed file or a key format stackshot stops matching means a line delivered during
  a relaunch is dropped, as before the hold existed (the defect it fixes).
- **Test**: `tests/phases.sh` (hold dir present, all holds written at least the settle before the first `/exit`, a pane that turns busy
  after its hold is deferred and queued for retry, a skipped pane's hold cleared, holds released after the sweep and after a TERM in
  the settle); `tests/sets-master.sh` (the `--self` worker: busy after the hold hands off to the retry worker, an abort releases
  the hold, both with an empty registry name).
- **Stable**: yes.

## 4. Post-recycle hook

- **Direction**: sala → stackshot (CLI).
- **Mechanism**: `SALA_POST_RECYCLE_CMD` (unset by default; a machine running stackshot sets `python3 ~/stackshot/client.py recycled`,
  `config.example:139-141`), run detached with `sh -c` ONCE PER CLEARED FLAG (version 19): a recycle's flag clears when every
  live pane has relaunched since the flag's time, or partly when a pane is held past `SALA_LATER_LIMIT`; a clean reboot calls it
  once. Environment it sees: `SALA_RECYCLE_KIND=recycle|reboot`, `SALA_RECYCLE_STARTED=<epoch>` and
  `SALA_RECYCLE_FLAG_AT=<epoch>` (the flag's time, the same number), `SALA_RECYCLE_RESULT=ok|partial` (ok iff nothing skipped),
  `SALA_RECYCLE_SKIPPED="<tmux sessions the flag did not get back, space-separated>"`. Example for a partial clear:
  `SALA_RECYCLE_KIND=recycle SALA_RECYCLE_STARTED=1790000000 SALA_RECYCLE_FLAG_AT=1790000000 SALA_RECYCLE_RESULT=partial
  SALA_RECYCLE_SKIPPED="scratch-1" python3 ~/stackshot/client.py recycled`. sala parses one output line,
  `… no longer wait for a recycle (<ids>)`, into `$SALA_STATE_DIR/recycle-cleared/<epoch>-<pid>.ids` when the command
  exits 0 and the watchdog holds served ids.
- **Owners**: sala `lib/common.sh:1526-1569` `post_recycle_hook`. stackshot `client.py:145` `recycled()` (reads the four
  variables, `POST /client/recycled` with `{kind, started, result, skipped[]}`, prints
  `stackshot: N item(s) no longer wait for a recycle (<ids>|none)[; N kept (…)]`, exits 0 always); `server.py:5291`
  `_client_post`, `:5158` `_recycled` → `{"cleared", "kept", "told"}`.
- **Absent or changed**: unset → `return 0`, nothing runs. A failing command logs
  `post-recycle: ⚠ SALA_POST_RECYCLE_CMD failed (rc N) — the recycle itself is unaffected`. A changed output line means the
  cleared ids are not learned and the watchdog may count the same item again (bounded by its 10-min cache). Fail-open.
- **Test**: `tests/autorecycle.sh:153-177` (a stub hook), `tests/phases.sh`, `tests/sets.sh`, `tests/flags.sh` (against
  `tests/fake-recycled-client.py`, a strict fake of `client.py recycled`). stackshot's side:
  `tests/recycle_scenario.py`.
- **Stable**: yes.

## 5. Recycle-wanted

- **Direction**: stackshot → sala (sala asks).
- **Mechanism**: `SALA_RECYCLE_WANTED_CMD` (unset by default; a machine running stackshot sets `python3 ~/stackshot/client.py recycle-wanted`,
  `config.example:77`), `sh -c`, 20 s timeout, cached 10 min in the watch state. Output: `<count> <id> <id> …` on one line;
  a non-numeric first token counts as 0. From version 30 each id may carry two optional suffixes, `<id>[@<epoch>][~<ref>]`
  (sala already reads `@<epoch>`: a changed epoch makes the same id a new flag): `@<epoch>` is the flag's time
  (the item's `recycle_at`, whole seconds) and `~<ref>` the change the flag waits for, a commit sha (7-40 hex) or `pr<N>`, written
  `<repo>:pr<N>` for a repository other than sala's (`stackshot:pr12`; the name must be one sala maps in `SALA_RECYCLE_REF_REPOS`, else
  the reference counts as live). With a ref, sala's watchdog holds the recycle while the change is not in the production checkout's HEAD
  (not merged, or merged and not deployed); with the epoch it also skips a flag that every live pane started after, and reports it served
  through the post-recycle command (interface 4) with that epoch as `SALA_RECYCLE_FLAG_AT`. A bare id still works: it is timed by when
  sala first saw it. **Not shipped on the stackshot side yet**: `_recycle_wanted` prints bare ids, so a board flag gets only the
  first-seen fallback of the second guard until stackshot prints `<id>@<recycle_at>` and, for an item anchored to a pull request,
  `~[<repo>:]pr<N>`.
- **Owners**: sala `lib/watch.sh:1269` `recycle_wanted()`. stackshot `client.py:260-265` → `GET /client/recycle-wanted`;
  `server.py:5134` `_recycle_wanted` (items on this machine that wait for a recycle, not held or held for the recycle alone).
- **Absent or changed**: unset → `0|`, the watchdog recycles only on `sala recycle --when-idle` requests. A failing or
  odd answer → 0. Fail-open.
- **Test**: `tests/autorecycle.sh` (a board stub).
- **Stable**: yes.

## 6. Puller-lag file and path unit (retired)

- **Retired in contract version 11.** The machines whose stackshot pullers
  this served are gone. Removed: `watch --puller-lag`, the `auto_provision` step and its state-file keys
  (`auto_provision_tried_<host>`), `systemd/sala-puller-lag.path` and `.service`, `install.sh` copying and enabling them, the
  knobs `SALA_AUTO_PROVISION`, `SALA_PULLER_LAG_FILE` and `SALA_PULLER_LAG_CMD`, and the suite section that tested them. sala
  reads nothing under `~/.local/state/stackshot/clients/` now. The number stays so the others keep theirs. The fixed unit
  `sala-auto-provision-sets` (the provision sets' relaunch of a machine that answers ssh again) and the state file
  `salamander-autoprovision.state` it shares are not part of this interface and stay.

## 7. Agents-map checks

- **Direction**: sala → stackshot (CLI, `pages.py` read from stackshot's checkout). **Since version 5 this is the fallback**:
  the project record (interface 20) is read first; the checks below run when the record cannot answer.
- **Mechanism**: `python3 <pages.py> resolve <key>` prints `<key> True|False|None`, exit 0 only for True;
  `python3 <pages.py> agent-listed <name>` exits 0 listed or nothing to check (with a `listed on <key>: <mandate>` line
  when listed), 3 not listed, 2 cannot tell ("cannot tell: no brain mirror on this machine"). The script:
  `SALA_AGENT_CHECK_SCRIPT`, else `$SALA_STACKSHOT_DIR/pages.py` (`~/stackshot/pages.py` when the knob is unset; none when it is
  empty). The frozen-copy fallback (a copy of `pages.py` in a host config repo) was dropped in version 11. Knobs `SALA_AGENT_CHECK=on|off`,
  `SALA_PAGE_DIRS` (default `projects`; mirrors stackshot.toml `[pages] dirs`).
- **Owners**: sala `lib/common.sh:592` `agent_unlisted` (plain spawn and rename: fail-open, only exit 3 refuses, 10 s
  timeout), `:611` `agent_check_script`, `:631` `page_exists` (15 s), `:640` `agent_listed_on` (15 s; only the
  `listed on <this key>: ` line counts); `lib/spawn.sh:245-275` (a project spawn: exit 4 `NO-PAGE: <key>`, exit 3
  `ADD-TO-PAGE` block, `die` on "cannot tell"). stackshot `pages.py:324` `agent_listed`, `:1359-1364` `main`
  (`agent-listed`, `resolve`).
- **Absent or changed**: a plain `spawn`/`rename` with no `pages.py` proceeds (fail-open). `spawn --project` with neither a
  usable project record nor `pages.py` (or `pages.py` without the brain mirror) **refuses** ("cannot tell") unless
  `SALA_AGENT_CHECK=off`: the one hard dependency in sala's CLI, now needed only when the record is
  missing, stale, unreadable or lacks the project. It is kept fail-closed on purpose: the README and the header of `lib/spawn.sh` name `spawn --project` as the one command that needs stackshot and the brain
  mirror, and no abstraction over the check is built until a box without stackshot has to make project spawns.
- **Test**: `tests/spawn.sh` (a stub `pages.py` through `SALA_AGENT_CHECK_SCRIPT`; the project record section for the order
  of the two sources).
- **Stable**: yes (the exit codes are stated on both sides).

## 8. Spawn keeper ask

- **Direction**: sala → stackshot (CLI message).
- **Mechanism**: `SALA_SPAWN_ASK_CMD` (unset → `python3 $SALA_STACKSHOT_DIR/client.py message`, `~/stackshot` when that is unset, none when it
  is empty; set empty → never asked),
  run as `<cmd> <page key> <text> --sender "sala spawn"`, detached, 150 s timeout, at most once per
  `SALA_SPAWN_ASK_EVERY` (3600 s) per name (stamp `$SALA_STATE_DIR/spawn-asked/<name>`). The text starts `[sala spawn] …`
  and carries the YAML block to add to the page.
- **Owners**: sala `lib/spawn.sh:83-84` (the knobs), `:188` `spawn_ask_keeper`. stackshot `client.py:138`
  `message(to, text, sender)` → `POST /client/message`, exit 0 delivered, 1 refused.
- **Absent or changed**: the command's failure is logged in `salamander-spawn.log` and changes nothing; the spawn is
  refused either way (its exit 3 comes from the check, not the message). Fail-open. With `SALA_SPAWN_REGISTER` set the
  ask is never sent.
- **Test**: `tests/spawn.sh` (stub command, lines ~79 and ~167).
- **Stable**: yes.

## 9. Release report

- **Direction**: sala → stackshot (CLI message).
- **Mechanism**: `release.sh` `CLIENT="${STACKSHOT_CLIENT:-$SALA_STACKSHOT_DIR/client.py}"` (`~/stackshot` when the knob is unset;
  empty: no client, the message is only logged; from the environment, the script reads no config), `tell()` runs
  `python3 "$CLIENT" message <project page key> "<text>" --sender release`; texts
  `[release] PR #N merged and deployed — <title> — main at <sha>; changed: …` and `[release] PR #N FAILED at <step>: …`.
  After a successful deploy and before that message, `report_live` runs
  `python3 "$CLIENT" released --pr https://github.com/<owner>/<repo>/pull/<n> --sha <merge commit>` (stackshot `client.py released`): the merge commit is main's
  for a PR that was already merged, else what `gh pr view --json mergeCommit` names after the merge, else the first-parent merge of that PR in the checkout.
  Its output lines are logged as `items of PR #N: …`. A failed release never calls it.
- **Owners**: sala `release.sh` (`tell`, `report_live`, `run`). stackshot `client.py` `message` and `released`; `routing.py` records the message under
  `<state>/routing/salamander.jsonl`.
- **Absent or changed**: `tell` never fails the run; a missing client logs `message not sent: <text>` in the release log. `report_live` never fails it either:
  no client logs `stackshot not configured: live release not reported`; a refusal (stackshot does not accept this repo yet) or an unreachable server logs
  `live release not reported to stackshot: <first 300 characters of the output>`; no merge commit found logs the reason and sends nothing. Fail-open.
- **Test**: `tests/release.sh` (the `released` call, against a fake client; the `message` call is not covered).
- **Stable**: yes.

## 10. sala-web board items

- **Direction**: sala's web app → stackshot (HTTP).
- **Mechanism**: `GET <url>/client/items?key=<session name>`, header `Authorization: Bearer <token>`, `User-Agent: sala-web`,
  15 s timeout. Token from `$XDG_CONFIG_HOME/stackshot/client.token`, URL from `client.url` (`STACKSHOT_URL` in the
  environment wins), web base `SALA_WEB_STACKSHOT_WEB`, else stackshot's `[instance] board_url`, else none (`SALA_WEB_STACKSHOT_*`, `web/src/sala_web/config.py:71-76`).
  Answer: `{"items": [{"gid", "shown", "subject", "needs": [], "held", "updated", …}]}`; sala-web keeps
  `shown|gid`, `subject`, `needs`, `held` and, when sent (contract 2; stackshot's `_wait_fields`), `mover` {kind
  session|owner|outside, who, via?}, `wait` (after|failed|hold|wake|recycle|due|check|needs|end|idle; `end` is a verifying item's end date), `expected_by` (epoch
  seconds, or `null`), `overdue`, `step`, and builds `/items/<id>` (`board#N` → `N`, `board-tmp-box#N` →
  `board-tmp-box-N`, `sN` → `sN`). Served at `/api/board-items` as
  `{"sessions": {<name>: {"items": [...], "waiting": n}}, "error"?, "partial"?}`; TTL 60 s, retry 30 s, 4 reads at a time;
  cache `state_dir/board-items.json` (text, never the token).
  **A doing item has no expected time** (live): an item in state `doing` is sent with `wait`
  `"doing"`, `expected_by` `null` and `overdue` `false`, and is never past due. `expected_by` stays for every wait that has a date
  (`after`, `failed`, `hold`, `wake`, `recycle`, `due`, `check`, `needs`, `end`, `idle`). Before that change a doing item carried `wait` `"expected"` and a
  date. sala-web keeps only the wait kinds listed above, so it drops `wait` `"doing"` (as it dropped `"expected"`) and the null
  date and passes `overdue` through; the item stays in Agents at work, as before.
- **Owners**: sala `web/src/sala_web/board.py` (whole file), `config.py:66-76`, `app.py:25-31, 275-276, 685`. stackshot
  `server.py:5405` `GET /client/{what}`, `:4923` `_client_machine` (Bearer, SHA-256 against `<secrets>/clients.json`, 401
  `unauthorized: a machine token is required`), `:4959` `_client_get` → `:4992` `_client_items(key)` (the JSON at `:5033-5035`).
- **Absent or changed**: no token file → `"No stackshot token on this machine."`; 401 → `"stackshot refused this machine's
  token (HTTP 401)"`; network → `"stackshot unreachable (…)"`; an answer without an `items` list → `"stackshot sent an
  unexpected answer"`. The page keeps the items it has; the rest of sala-web is unaffected. Fail-open.
- **Test**: `web/tests/test_board_items.py`, `web/tests/test_board_items_ui.py` (the page no longer shows the items; the picker reads them); `conftest.py:71-77` points token and URL
  at missing files so no test reaches the board.
- **Stable**: yes.

## 11. sala-web roles

- **Direction**: sala's web app → stackshot (CLI).
- **Mechanism**: `SALA_WEB_ROLES_CMD` (default `python3 $SALA_STACKSHOT_DIR/client.py get roles`: `~/stackshot` when `SALA_STACKSHOT_DIR` is
  unset in sala-web's environment, no command when it is empty, `config.py` `_roles_cmd`), every
  `roles_ttl` 30 s; expects JSON `{"sessions": {<name>: {"role", "project"}}}`.
- **Owners**: sala `web/src/sala_web/sessions.py:377` `RolesCache`. stackshot `client.py:107` `get("roles")` →
  `GET /client/roles` (503 `no roles yet` before the first roles file).
- **Absent or changed**: a failure keeps the last good answer and sets `rolesError`; the overview shows sessions without
  roles. An empty `SALA_STACKSHOT_DIR` runs nothing and sets `rolesError` to say so. Fail-open.
- **Test**: `web/tests/test_sessions.py`, `web/tests/test_roles_cmd.py` (the default and the knob).
- **Stable**: yes.

## 12. Lanes and limit state read by stackshot

- **Direction**: stackshot → sala (stackshot reads sala's state files).
- **Mechanism**: `stackshot.example.toml:310` `lanes_file = "~/.local/state/salamander/lanes.tsv"` (`<session>\t<lane>` rows;
  `lane-default` beside it; `subscription-1` when neither; a row written before version 27 may carry an older lane word, read as the lane's current code: interface 28) for its `lane <session> <lane>` done check (stackshot renamed it from
  `sala_lane`; the old name is still accepted on stored items); `:313`
  `limit_file = "~/.claude/salamander-limit.json"` whose `panes` map (transcript uuid → `{s, lane, lim, since, reset}`; version 35 adds `rlane`, the lane the pane runs on)
  tells it which panes sala's limit watch stopped. A third file is read from the same directory as `lanes_file`:
  `lane-signin.state`, below.
- **`lane-signin.state`**: `$SALA_STATE_DIR/lane-signin.state` (`SALA_SIGNIN_STATE`), beside `lanes.tsv`. sala's sign-in watch
  (`signin_tick` in `lib/watch.sh`, every `SALA_SIGNIN_EVERY` = 300 s, writer `sw_set`, its own flock) writes it; plain
  `key=value` lines, per lane (`subscription-1`, `subscription-2`, `api`; the sdk lane is judged by the `api` keys; before version 27 the first two keys used older lane words: sala reads the old keys when the new ones hold nothing and blanks an old key the moment it writes the new one, so a reader looks up the lane's current code first and may fall back to the old word from `lane-names.json`'s `aliases`) `<lane>.seen` = `ok: …` or
  `wrong: …` (the judge's verdict, then what was seen), `<lane>.since` (epoch of the change), `<lane>.alerted`,
  `<lane>.unknown`, plus bookkeeping keys (`login.checked`, `api.probed`, `<lane>.revived`). sala itself reads it in `lane_out` (`lib/common.sh`). stackshot reads
  only `<lane>.seen`, and treats a value starting `wrong: ` as "this lane's sign-in is wrong" (`server.py` `_lane_out`,
  the path being `lanes_file`'s directory plus the fixed name `lane-signin.state`): with the limit file it decides whether a
  pilot re-send waits (the pane's lane is out) and says why. The file is absent when `SALA_SIGNIN_ALERT=off` or before the
  first look; a missing, unreadable or `unknown` reading says nothing and the lane counts as able to run.
- **Owners**: stackshot `server.py:2501` `_lanes_file`, `:2509` `_lane_record`, `:2806` `_limit_file`, `:2815` `_lane_out`.
  sala `lib/common.sh:1654` (`SALA_LANES`, `SALA_LANE_DEFAULT_FILE`), `:1656` `SALA_LIMIT_STATE`, the limit watch in
  `lib/watch.sh:292-298` and the Python that writes `panes` (`:429-489`).
- **Absent or changed**: stackshot without the files: "no lanes.tsv at all is an error (a pass that cannot read never
  closes)"; a missing limit file "says nothing: the lane counts as able to run". sala is unaffected either way. A change to
  sala's row format or the `panes` keys breaks stackshot's `lane` check and its limit reading silently, and a change to
  `lane-signin.state`'s `<lane>.seen` key or its `wrong: ` prefix breaks the sign-in reading the same way.
- **Test**: `tests/stackshotshape.sh` (version 12): `lanes.tsv`, `lane-default` and `salamander-limit.json`, each written by sala's
  own writer (`lane_write`, `lane_set_default`, `lane_rename`, `lane_drop`; `watch --limit` against two fake panes) and read
  back by a copy of stackshot's reading rule (`_lane_record`, `_limit_file`/`_lane_out`): the row format and sort, the default
  line, the fall to the default and to `subscription-1`, the rename and retire, the `panes` map keyed by transcript uuid with `s`, `lane`,
  `lim`, `since` and `reset`, and a gone pane dropped. `lane-signin.state` is not in it: `tests/signin.sh` and
  `tests/lanedormant.sh` write and read it for sala's own side. stackshot's `tests/check_scenario.py` tests against its own fixture.
  `lane-home.tsv` (the lane fallback: session, home lane, when, model before) is sala's own and is not read by stackshot;
  a fallback move changes only `lanes.tsv` and `lane-default` in the rows and the default line stackshot already reads, in the
  same format; `tests/lanefallback.sh` covers it.
- **Stable**: yes from version 11. stackshot depends on sala's state files with no sala-side statement before version 1; this
  entry is that statement and `tests/stackshotshape.sh` its guard, so a change to `lanes.tsv`, `lane-default`, `lane-signin.state`'s
  `<lane>.seen` key or `salamander-limit.json`'s `panes` map bumps the version (and fails that suite first, for the three files it
  covers). No `sala lane --json` read was built (ruled out): stackshot keeps reading the files.

## 13. stackshot's release asks for a recycle

- **Direction**: stackshot → sala (CLI).
- **Mechanism**: stackshot's `release.sh:94` runs `sala recycle --when-idle --from release "stackshot PR #<n>: <title>"`
  when `sala` is on PATH. sala records one marker file `$SALA_STATE_DIR/recycle-requests/<epoch>-<pid>.req`
  (TSV `epoch\tfrom\treason[\tchange]`; from version 30 the optional 4th field is the change the request waits for, set by
  `--change REF`, a commit sha or `pr<N>` with an optional `<repo>:` prefix; a 3-field marker reads as before), expires it after 24 h,
  and `watch` serves it. With a change, `watch` holds it until the change is in the production checkout's HEAD, and drops it unserved
  when every live pane started after it was asked. stackshot's `release.sh` (interface 13) could pass `--change stackshot:pr<N>` so its own request waits for its own deploy.
- **Owners**: sala `lib/recycle-request.sh` (whole file; `rr_main`), `lib/watch.sh` AUTO-RECYCLE. stackshot `release.sh:94`.
- **Absent or changed**: stackshot checks `command -v sala` first and falls back; sala's usage line and exit codes are the
  interface (`recycle --when-idle --help`). Fail-open on both sides.
- **Test**: `tests/autorecycle.sh`.
- **Stable**: yes.

## 14. Reboot hooks

- **Direction**: sala → stackshot (executables stackshot ships).
- **Mechanism**: `docs/reboot-contract.md` v1: `SALA_REBOOT_HOOKS="name=path …"` in stop order; verbs `pause --at <ISO>`
  (30 s), `flush-stop` (300 s), `start` (120 s), `status` (15 s; exit 0 running, 3 stopped), `resume --since <ISO>
  --sessions <file of uuids>` (600 s); exit 0 = done, the last stdout line is the summary. A host's config names
  `queue=<path to a queue hook> stackshot=<path to stackshot's hook> store=<path to a store hook>`.
- **Owners**: sala `lib/reboot.sh:19, 50, 124, 145`, `docs/reboot-contract.md`. stackshot `reboot-hooks/stackshot-hook`
  and its queue hook (which writes `held-<source>.txt` in the same inbox folder as interface 3).
- **Absent or changed**: no hooks configured → `reboot` prints `no SALA_REBOOT_HOOKS configured` (status) or refuses
  (a real reboot), by design: a reboot with a participant missing is not a clean reboot. A hook that violates a budget or
  exit code fails the run (fail-closed, per the contract).
- **Test**: none against a live hook; the reboot suites use fakes.
- **Stable**: yes (a versioned contract of its own; a change to it bumps *that* document's version and this one's).

## 15. Heartbeat's stackshot checkout pull on a second operating system (retired)

- **Retired in contract version 10.** The fleet sweep's PowerShell side is gone, and with it the
  fast-forward of a remote machine's `~\stackshot` checkout, the `K:` line, the post on a flip and the entry in
  `salamander-fleet-ssh.json`. Nothing in stackshot read it. The number stays so the others keep theirs.

## 16. Fleet names TSV

- **Direction**: host config repo → sala and stackshot (both read the same file).
- **Mechanism**: `SALA_FLEET_NAMES` (a TSV kept in a host config repo), rows `<os hostname>\t<fleet
  name>\t<letter>`; the letter names the store's subdirectory (interface 1). stackshot reads the same file as `fleet_names`
  in its toml (its `tests/contract_scenario.py` rewrites that key).
- **Owners**: sala `lib/heartbeat.sh:58, 77`. stackshot `stackshot.example.toml` `fleet_names` (line not re-read; *unverified*).
- **Absent or changed**: sala falls back to `SALA_HEARTBEAT_LETTER`/`SALA_HEARTBEAT_NAME`; a letter that changes moves the
  machine's directory and stackshot's links with it.
- **Test**: `tests/smoke.sh` (a fixture TSV).
- **Stable**: yes.

## 17. Briefing link resolver

- **Direction**: sala's `contrib/briefing` → stackshot's items store and web.
- **Mechanism**: `BRIEFING_BOARD_DIR` (the git store of stackshot's items, e.g. a checkout of the board store; set in the environment or the sala config, empty by default) is
  scanned for an id's existence; a known id links to `<SALA_STACKSHOT_WEB>/items/<id>` (env or the sala config; empty: no board links); the repo regex
  (`lib.sh:126`) also resolves `stackshot#<n>` to GitHub.
- **Owners**: sala `contrib/briefing/lib.sh:93, 126, 133`; `contrib/briefing/release-watch.sh:41`. stackshot: its store
  layout (`<board-data>/<letter>/<n>.json`, *unverified*).
- **Absent or changed**: no board data → ids stay plain text. Fail-open.
- **Test**: `tests/briefing/links.sh:13`.
- **Stable**: yes.

## 18. Parked-question seams

- **Direction**: sala → stackshot (CLI), a file call and a read call.
- **Mechanism**: `SALA_QUESTION_FILE_CMD` / `SALA_QUESTION_ANSWER_CMD`, whose default (unset, and the client exists at
  `SALA_STACKSHOT_CLIENT`, default `$SALA_STACKSHOT_DIR/client.py`: `~/stackshot/client.py` when that is unset, none when it is empty) is `contrib/question-board-file.sh` / `-answer.sh`. File:
  `client.py post question --project <SALA_QUESTION_PROJECT, no default> --subject "[<scope>] <label>: <question>" (the scope: SALA_DEFAULT_SCOPE, else the first of SALA_SCOPES, else no bracket)
  --request-id <question id> --ask "Decide: … · Recommend: … · Stakes: … · By: …" [--option "<label>=<line>" …]
  [--recommended <label>] --sender <label>`, the question text on stdin (at most 5 lines and 8,000 characters; sala cuts it
  itself); the item id (`board#N`) is the stdout, exit 1 a refusal. Read: `client.py get answer board#N` →
  `kind<TAB>label<TAB>text<TAB>when`; sala resumes only on `kind == decision`.
- **Owners**: sala `contrib/question-board.py`, `lib/question.sh` `qs_seam`. stackshot `client.py` `question()` and `answer()`,
  `server.py` `_question`, `_answer_line`.
- **Absent or changed**: no client → the question goes out as a post through the notify command, as before. A refusal or an
  unreachable board leaves the question parked and unfiled; `sala question sweep` files it again, the request id making the
  repeat safe. A comment is never an answer.
- **Limits**: the subject is cut to 80 characters (the label in it to 30), the ask to 240; stackshot lowered the item title
  limit from 160 to 80, and `contrib/question-board.py` `SUBJECT_MAX` follows it. A longer subject is refused by the client.
- **Test**: `tests/boardseam.sh`.
- **Stable**: yes.

## 19. Session registry file

- **Direction**: sala → stackshot (a file the heartbeat writes; stackshot reads).
- **Mechanism**: `$SALA_HEARTBEAT_STATE_DIR/<letter>/session-registry.json` (the same live store as interface 1, the writer's own
  letter only), schema 1:
  `{"schema": 1, "machine": "<letter>", "written": "<ISO Z>", "sessions": {"<sala session id>": {"id", "name", "aliases": [],
  "project", "project_key", "role", "lane", "model", "effort", "pane", "cwd", "state": "live|retired", "created",
  "retired_at", "transcripts": [{"id": "<claude session id>", "machine", "at", "why"}]}}}`. `project` and `project_key` both
  hold the project page key until stackshot project ids exist; `role` is `front` or `back` or null; empty fields are null.
  Retired rows stay (grow-only), so an old id still resolves. Reading rule: a transcript id belongs to the row whose
  `transcripts[].id` lists it, the last entry being the row's current conversation; two rows listing one id is ambiguous.
  `written` is refreshed on every heartbeat run (every 5 minutes), whether or not a row changed: an old `written` means the
  heartbeat or the registry is down, not that the fleet is quiet. The write is atomic (temp file, replace).
- **Owners**: sala `lib/heartbeat.sh` `publish_registry()` (the header names the contract), `lib/sessions.py` `export_doc()`;
  `docs/session-registry.md` (phase 3). stackshot: not yet reading it (adoption is the stackshot maintainers').
- **Absent or changed**: `SALA_SESSIONS=off`, a missing or corrupt `sessions.json` (or no `SALA_HEARTBEAT_STATE_DIR`): nothing is
  published and the last good file stays, with one `sessions.log` line; its `written` ages. A box that is swept rather than driving
  has no file. Fail-open for stackshot: without the file it keeps its name-based behaviour.
- **Test**: `tests/sessions.sh` (phase 3 section): contents, atomicity, `written` refresh, the off flag, a corrupt registry.
- **Stable**: yes from version 4.

## 20. Project record

- **Direction**: stackshot → sala (a file stackshot rewrites; sala reads it). Adopted in version 5 from the phase 5 half of
  `docs/session-registry-contract-proposal.md`.
- **Mechanism**: `~/.local/state/stackshot/projects.json` (`SALA_PROJECT_RECORD` overrides the path), written atomically by
  stackshot's `projects.py` `sync()` whenever the records change and at least every 4 minutes. Schema 1:
  `{"schema": 1, "generated": "<ISO Z>", "projects": {"prj_<8 hex>": {"id", "key" (the project page key), "keeper",
  "agents": {"<name>": {"front": true|false, "role", "mandate_line", "page_owed"?: true}}}}, "by_key": {"<page key>": "<id>"}}`.
  `front` is true for a top-level entry of the page's `agents:` map and false for one under `background:`; `role` is the part
  of the name after the project's name (`alex-builder` → `builder`); the project's main agent is the front entry whose
  name ends in `-main`. `page_owed: true` marks an agent registered through `client.py post project-agent` whose page line is
  still owed (a claim by one session, not what the page says). Read by sala on the machine that drives only (a file, no token, no HTTP);
  `client.py get project <key>` returns the same record for other machines and is not used by sala.
- **Reading rule (sala)**: the record answers only when it is readable JSON of schema 1, `generated` is at most
  `SALA_PROJECT_RECORD_MAX_AGE` (600 s) old, and the project key is in it. Then, for `spawn --project K NAME --role R`: the
  name on the project's agents map and `front` agreeing with `R` is **listed** (an agent with `page_owed` counts as listed:
  its registration is the point; the dry run says the line is owed); the name absent is **not listed** (exit 3, the
  `ADD-TO-PAGE` block, the keeper asked as before, the project's main agent and the `post project-agent` register command
  named in the text only; a spawn never calls it, `sala rename` of a side session does, since version 14); the name present with the other `front` is refused with exit 1 and the
  record's role. For `agent_unlisted` (plain spawn, rename) only a listing matters: a name on any project's map is not
  unlisted and `pages.py` is not asked. Anything else the record cannot answer (file missing or unreadable, another schema,
  stale, no such project) falls back to interface 7 unchanged, with its exit codes and its "cannot tell" refusal.
- **Owners**: sala `lib/common.sh` `project_record_agent`, `lib/spawn.sh` (the check before `page_exists`),
  `agent_unlisted`. stackshot `projects.py` (`build`, `sync`, `_record`).
- **Absent or changed**: no file, an old file or another schema: pages.py answers (interface 7). A stackshot that adds fields is
  harmless (sala reads `front`, `mandate_line`, `page_owed` and the names only). A change of the three meanings above, or of
  the schema number, needs this document's bump and a sala change first. The record lags the page by up to its refresh
  interval: a line just added to a page may show as unlisted for a few minutes.
- **Test**: `tests/spawn.sh` (the project record section: listed, unlisted, front vs back, page_owed, the main agent, missing,
  stale, garbage, other schema, fallback, "cannot tell", `agent_unlisted`).
- **Stable**: yes from version 5.

## 21. sala-web project calls

- **Direction**: sala's web app → stackshot (HTTP), the same token, address and header as interface 10 (`Authorization:
  Bearer <token>`, `User-Agent: sala-web`). Adopted in version 6; the CLI forms are
  `client.py get projects`, `post project`, `post project-list` and `post project-agent`.
- **Mechanism**: `GET /client/projects?scope=<work|home|lab|all>[&q=<text>]` (20 s; `all` is every scope's projects
  together, each row with its own `scope`, which sala-web's *all* chip reads, with no change on stackshot's
  side; `all` is only ever a query, never the scope of `post project` or `post project-list`; a row that carries
  `retired: true` or `status: archived|retired`, or whose `type` is not `project`, is dropped by sala-web: a registered project is a
  page of that type) answers `{"scope", "q", "generated",
  "scopes", "projects": [{id, key, title, name, scope, listed, hidden, listed_by, type, hub, keeper, main, agents: {<name>:
  {front, role, mandate_line, page_owed?}}, items_30d}]}`: the listed projects of the scope by key, not filtered by `q`, then
  with `q` the scope's hidden matches (key, name or title holds it, case-insensitive) with `hidden: true`; sala-web reads
  `id, key, title, name, type, scope, listed, hidden, keeper, main` and each agent's `front`, `role`, `page_owed`.
  The sidebar's groups read the same field from the pages checkout (`type: project`; a sub-page's sessions join the nearest parent
  that is one), not from this route.
  `POST /client/project` `{key: "projects/<slug>"|"infra/<slug>", scope, title?, sender}` (305 s; the knowledge base can be slow; the
  page asks about it as a job) makes the project and its page: 200 `{project: {id, key, …}, created, page, page_yaml, note}`,
  409 the page exists (or, with "being made" in the error, another request is making that key right now: sala-web words
  it as a wait), 502 the knowledge base refused or did not answer, 400 a bad key, scope or title. `page_yaml` is entries only (no
  `agents:` / `background:` header) when the page has that map already, and the `note` says which; sala-web passes it on
  unread. `POST /client/project-list`
  `{key: <id|key|slug>, scope?, sender}` (30 s): 200 `{project, changed, note}`, 400 a sub-page or a `note` page, 404 unknown.
  `POST /client/project-agent` `{project, name, role, front: bool, mandate: one line ≤ 600, sender}` (30 s): 200 `{project,
  key, agent, page_owed, page_yaml, note}`; 403 a retired or hidden project (the sender `sala-web` may
  add an agent to any listed project, one with agents already included), 409 the name is taken (listed with another role or
  line, another project's agent, or pending from another sender), 400 a name that does not
  start with the project's name, 400 a mandate with a control character (checked here first). `sender` is always `sala-web` (the server sets it; the page cannot), `title` is one line of
  120 characters at most with no quotation marks or backslashes (checked here too).
- **Owners**: sala `web/src/sala_web/projpick.py` (the calls, the shapes, the job), `app.py` (`/api/spawn/projects`,
  `/api/spawn/project`, `/api/spawn/project/job`, `/api/spawn/project-list`, `/api/spawn/project-agent`), `static/app.js` (the
  form's steps). stackshot `server.py` `_projects_list`, `_new_project`, `_project_list`, `_project_agent`, `projects.py`.
- **Absent or changed**: no token or address file → the page says "No stackshot token on this machine."; 401 → "stackshot
  refused this machine's token (HTTP 401)"; unreachable → "stackshot unreachable (…)"; an answer that is not the list →
  "stackshot sent an answer that is not the project list". The box then says it could not read the list and still offers
  "+ New project"; a Create stops at the step that needed stackshot, in words, and queues nothing. An older stackshot without
  these routes answers 404 and the form cannot make or list a project. The agent's page line stays owed in stackshot's
  record (`page_owed`, interface 20); the form says it is recorded and shows nothing to copy.
- **Test**: `web/tests/test_new_session_projects.py` (the server side against a fake stackshot on 127.0.0.1) and
  `web/tests/test_new_session_scope.py` (the form in a browser against the same fake); `web/tests/fake_stackshot.py` holds the
  shapes above.
- **Stable**: yes from version 6.

## 22. sala-web For you calls

- **Direction**: sala's web app → stackshot (HTTP), the same token, address and header as interfaces 10 and 21 (`Authorization:
  Bearer <token>`, `User-Agent: sala-web`). Adopted in version 8.
- **Mechanism**: `GET /client/for-you` (20 s) answers `{generated, rows: [{id, kind, item, project, what, url, urgent, ts, when,
  slacked}], flags: {"board#N": "watch"|"mute"}}`, newest first; `kind` is one of closed, reopened, decision, check_failed,
  due, release_failed; `what` does not carry the item's id; `id` is the entry's number. `POST /client/for-you/seen`
  `{id: <int >= 1>|"all", sender}` (20 s): 200 `{ok, seen: [ids ascending], rows: [the entries still unseen]}` (`"all"` on an
  empty list is 200 with `seen: []`), 404 when the id is not on the list, **one already marked seen included**, 400 a bad id, 401 no or
  unknown token, 403 a sender that is not exactly `sala-web`. sala-web treats a 404 to Seen as "already gone": the row leaves its
  list, no error (a second tap, or the entry seen on another page). `POST /client/items/<key>/watch`
  `{state: "watch"|"mute"|"default" (case-sensitive), sender}` (20 s): 200 `{ok, item: "board#N", state, flags: {the whole
  map}}` (`default` removes the flag), 404 an unknown item, 400 a bad state, 401 and 403 as above; the key may be `board%23N` or the
  bare number, and sala puts the key in the path as `board%231` (`foryou.watch_path`, the
  one line to change if stackshot wants the bare number). `sender` is always `sala-web` (the server sets it; the page cannot).
  sala reads the answers loosely: no `rows` in a seen answer means the seen ids leave the list sala had; no `flags` in a
  watch answer means sala's map with that one item set (`default` clears it). A `url` that is not http(s), an `item` that is not
  `<word>#<number>` and a flag that is not watch or mute are dropped; rows and text are cut to sane lengths.
- **Owners**: sala `web/src/sala_web/foryou.py` (the shapes, the calls, `ForYouCache`), `app.py` (`/api/for-you`,
  `/api/for-you/seen`, `/api/items/<key>/watch`); no page reads them since the items sheet was removed. stackshot: the three routes in `server.py`, unread by sala beyond the shapes above.
- **Absent or changed**: no token or address file, a 401, an unreachable server and an answer that is not the list each give the
  route's answer a plain sentence ("No stackshot token on this machine.", "stackshot refused this machine's token (HTTP 401)",
  "stackshot unreachable (…)", "stackshot sent an answer that is not the For you list"); the last list stays in the cache. A 403,
  404 (a Watch / Mute of an unknown item) or 400 is a plain sentence in the route's answer and changes nothing; a 404 to
  Seen is not an error (above). An older stackshot
  without the routes answers 404: the route says it has no For you list.
- **Test**: `web/tests/test_foryou.py` (the shapes on their own, the server against a fake stackshot on 127.0.0.1);
  `web/tests/fake_stackshot.py` holds the shapes
  above, and is the one place to change with `foryou.py` when a route turns out different.
- **Stable**: yes from version 8.

## 23. CLI update hook

- **Direction**: sala → stackshot (a command sala runs; stackshot answers by refreshing its version lookups).
- **Mechanism**: `post_update_hook <what changed> [host…]` (`lib/common.sh`) runs the command in `SALA_POST_UPDATE_CMD` with
  `sh -c`, after **every** CLI update attempt, whether or not a version moved. Callers: `lib/update.sh` (`update --fleet` and
  hosts), `lib/provision.sh` (a remote provision that ran, not after `--only`), `lib/revive.sh` (`recycle --update` on this box,
  run detached under `setsid` so it does not hold the sweep). The call sala sends: no arguments and no stdin; the touched hosts
  go in the environment, `SALA_UPDATE_HOSTS` (space-separated) and `SALA_UPDATE_HOST` (set only when exactly one), and the
  command may use them to scope its own check. Before the command runs, sala runs the heartbeat once (when
  `SALA_HEARTBEAT_STATE_DIR` or `SALA_HEARTBEAT_REPO` is set and a host was touched) so that the installed versions are in the
  store (interface 1) before the lookup. A typical setting is `python3 ~/stackshot/publish.py bump` (host config in
  `~/.config/salamander/config`, not in this repo; `config.example` leaves it empty). sala does not call stackshot's MCP tool by
  that name: `publish.py bump [--host <fleet name>]` is the same action as the `bump_versions` tool (`bump()` →
  `publish(force_versions=True)`: refresh the latest-available versions of the claude-code npm package and other tracked releases,
  then re-render and publish the board). stackshot accepts `--host` and `host` and ignores them (installed
  versions come from the heartbeat store); the command's output is discarded and only its exit status is read.
- **Owners**: sala `lib/common.sh` `post_update_hook`, `SALA_POST_UPDATE_CMD` (and the older `SALA_FLEET_POST_CMD`); `README.md`
  "Hooks out". stackshot `publish.py` `bump()` and the CLI's `bump` verb, `server.py` `stackshot_bump_versions`
  (tool `bump_versions`).
- **Absent or changed**: `SALA_POST_UPDATE_CMD` unset: the hook does nothing beyond the heartbeat. The command failing
  (stackshot missing, `publish.py` absent, a non-zero exit): sala prints one warning line (`SALA_POST_UPDATE_CMD failed … the
  version tracker may lag until its next poll`) and carries on; the update itself and its exit status are unaffected. Fail-open.
  stackshot's side, if the heartbeat store is older than the update, shows the old installed version until the next heartbeat.
- **Test**: none. The suites that run an update path (`tests/psets.sh`, `tests/settingsapply.sh`) set the command to empty.
- **Stable**: yes from version 9 (the hook is sala's documented `Hooks out` knob; stackshot's README names the tool).
## 25. Project agent retire

- **Direction**: sala → stackshot (a CLI call sala runs from the machine that drives; stackshot answers over its own HTTP route). Added in version 16.
- **Mechanism**: `python3 <client.py> post project-agent-retire <project> <name> --sender sala-retire` (`retire_drop_agent`, `lib/common.sh`;
  called at the end of `lib/retire.sh`; the client is `stackshot_client`: `SALA_STACKSHOT_CLIENT`, else `SALA_STACKSHOT_DIR/client.py`). Run under
  `timeout 90` with stdin `/dev/null` (version 25; 45 before: stackshot now reads and writes the page, which takes longer than the one read it used to make), once per successful retire (not in `--dry-run`, which
  only says "would tell stackshot …"). `<project>` is the hub page key (`projects/<slug>`, `infra/<slug>`): the session's registry row `project`
  (`retire_project_of`, read before the retire marks the row retired), else a side session's record `project`, else its origin agent's, else the
  `project` that stackshot's roles list gives the name (from version 24: `timeout 20 python3 <client.py> get roles`, stdin closed, else the file
  `SALA_ROLES_FILE`, default `~/.local/state/stackshot/roles.json`; `{"sessions": {<name>: {"project": …}}}`, interface 11's shape). The source the
  project came from is one more line in the log (`its project <p> came from its registry row | its side record | stackshot's roles list (…)`). `<name>` is the
  retired tmux session's name, which is the agent's name. Answers (stackshot side, live; version 25): stackshot removes the agent's line (and the
  lines indented below it) from the project page's `agents:` map, adds a timeline line to the page and drops a pending entry of the name. 200 with
  `result` `line removed` (the page's line is gone), `dropped` (the agent was only pending: no page is written) or `not listed` (on no page and not
  pending: nothing to do, e.g. a repeat after a lost reply); 502 the knowledge base did not give the page, refused the write twice, a read back does not show the
  removal, or the line is gone but the timeline line was not written (the reason says which: ask again if the line is still on the page; if only the timeline line is missing, add it by hand, since a repeat answers `not listed`); 422 the agents block cannot be
  edited in place (remove the line by hand); 409 a rename or retire of the page is in progress; 404 unknown project; 400/403 a bad call or a caller
  that is not the form (503 the record unreadable). There is no 202, and no 404 or 409 for "not listed" or "no one to tell" (versions 16 to 24). `client.py` exits 0 on
  200 and prints stackshot's JSON, and exits 1 with `stackshot: agent not retired [<status>] <reason>` on stderr on every other answer.
  sala says the 200 in plain words (removed, dropped, not listed), a 502 as a line of its own with the reason, the command to ask again and the
  timeline-line hint, and a 422 or 409 as "stackshot refused (status): reason; the retire itself is done". A reason longer than 600 characters is cut in
  the middle (its first 100 and last 500 kept), never at the end.
  `--sender` is `sala-retire`.
- **Owners**: sala `lib/common.sh` `retire_project_of`, `retire_drop_agent`, `retire_log`; `lib/retire.sh`. stackshot: the `project-agent-retire`
  route (`_project_agent_retire`) and its CLI verb (`project_agent_retire` in `client.py`).
- **Absent or changed**: fail-soft in every case. No project known (the row, the side record and the roles list all give none; the roles list unreadable,
  a client failure or timeout, a missing file or bad JSON counts as none, never an error), a project that is not a hub page key, or no `client.py` on the box: no call,
  one line in `~/.claude/salamander-retire.log`. A non-zero exit: the same log line with the exit
  code and stackshot's last line, and the retire's exit status and result unchanged. The "ℹ" line in the retire's output is the 502 line, the "stackshot
  refused (422|409)" line, or "stackshot was not told …" for any other exit (a 404, 400, 403, 503, `[0]` not reached) and for the timeout (90 s, which
  adds that an immediate retry may get a 409 while stackshot finishes)
  (the session is gone either way). An older stackshot without the verb fails the call the same way. A session left listed that way stays a
  pending agent until stackshot's side drops it.
- **Items read (version 26)**: before anything is ended `lib/retire.sh` calls `retire_open_items` (`lib/common.sh`): `python3 <client.py> get items <tmux name>`, then `<conversation id>` (`SALA_RETIRE_ITEMS_CMD` replaces the command, as `SALA_SIDE_ITEMS_CMD` does for the side gate; `timeout $SALA_RETIRE_ITEMS_TIMEOUT`, 30 s, stdin closed), reading `{"items": [{"shown": "board#N", "roles": ["mover"|"then"|"needs"], "held": bool, …}]}`. It runs in `--dry-run` too. Tested by `tests/retire-verbs.sh` against a stub that answers items, none, a failure, a hang and garbage.
- **Test**: `tests/retire.sh` (the agent entry sections; a stub `client.py` that logs its arguments and answers line removed, dropped, not listed, a 502, a 409 (in progress) or exit 1, and answers `get roles` from a file; the project fallback: row project, roles from the client, roles from the file, and none of them; the refusals are exit 1 in the real client, as in the stub's fail mode).
- **Stable**: yes from version 16 (stackshot's `project-agent-retire` is live).

## 24. Terminal-prompt "Your move" row

- **Direction**: sala → stackshot (CLI, from the machine that drives, `python3 <client.py> post terminal-prompt …`; `client.py` is found by `stackshot_client`: `SALA_STACKSHOT_CLIENT`, else `SALA_STACKSHOT_DIR/client.py`).
- **Mechanism**: `post terminal-prompt open --session <name> --question=<text> --sender sala-stuck`: exit 0 prints the item id; exit 1 prints
  the reason on stderr; a second open for the same session updates the question. `<text>` is the post's own summary (`sq_read`, border lines
  dropped), whitespace folded to one line, at most 200 characters, passed as `--question=<text>` so a text starting with `-` is no option.
  `post terminal-prompt clear --session <name> --sender sala-stuck`: closes that session's open item; with none open it is a no-op, exit 0.
  Both run under `timeout` (`SALA_STUCK_ROW_TIMEOUT`, 10 s), stdin `/dev/null`, output to the sala log (`salamander-watch.log`). `open` runs after the
  notice is sent and only once per question (the notice's own dedup in `stuck.state`); `clear` runs when the watch tick finds the question gone or
  the session gone, or a PostToolUse / Stop hook runs in the pane after the dialog went. `stuck.state` keeps `row` (1 open; 2 to 4 failed clears),
  `pane` and `sess` per session; a clear that stays refused is dropped after four tries.
- **Owners**: sala `lib/stuck.sh` (`sq_row_run`, `sq_row_open`, `sq_settle`, `sq_row_hook`), `lib/watch.sh` (`sq_locked`), `lib/hook.sh` (`_row_check`),
  `docs/stuck-question-recovery.md`. stackshot: the `terminal-prompt` post kind (being built when this was written; unread by sala beyond the above).
- **Absent or changed**: no `client.py` on the box, a stackshot without the kind, a refusal or a timeout: logged, nothing else; the notice, its retry and
  its dedup are unaffected (fail-open). The label `sala-stuck` has to be one stackshot accepts for the call.
- **Test**: `tests/stuckpost.sh`, `tests/instantalert.sh`: a stub client.py that records each call and refuses on demand.
- **Stable**: from version 15, the stackshot side unverified until it is released.

## 26. Unit-gap item

- **Direction**: sala → stackshot (CLI, from the machine that drives, `client.py post job-gap`; `client.py` is found as for interface 18: `SALA_STACKSHOT_CLIENT`, else `SALA_STACKSHOT_DIR/client.py`, `~/stackshot/client.py` when that is unset).
- **Mechanism**: for a new gap, `client.py post job-gap open <timer> <code> --repo <owner/name> --detail "<one line, at most 600 characters>" --sender sala-unit-gaps`
  (two-argument options only: `--repo X`, never `--repo=X`); exit 0 prints the item id. `<code>` is one of `no-description`, `no-lane`, `bad-lane`, `no-project`, `not-git`,
  `git-differs`; `<timer>` is the unit's name (`x.timer`). `--repo` is the last column of the repo table (`~/.config/salamander/unit-repos.tsv`, else `lib/unit-repos.tsv`) for the repo that holds the timer's script
  (no known repo → the `*` row, else `SALA_JOB_GITHUB`; both empty → the gap is not posted);
  stackshot refuses a repo it does not list with a 400. `--detail` is the gap, the timer file, the script, the owner repo and the fix, cut to 600 characters
  (the head is cut and the fix kept). stackshot files ONE open item per (timer, code), moved by the builder of the project that owns the repo (the mover is stackshot's
  to set, not sala's), and a repeat open of an open gap prints the same id and changes nothing. When the gap is fixed, `client.py post job-gap clear <timer> <code> --sender
  sala-unit-gaps` closes the item (with none open it says so on stderr and exits 0). sala keeps one record per timer and code in `~/.local/state/salamander/unit-gaps.tsv`
  (key, builder, time, item id), opens at most three gaps and closes at most three per pass, and stops the pass at the first call that fails.
- **Owners**: sala `lib/unitjob.py` (`cmd_check`, `gap_detail`, `board_open`, `board_close`), `lib/watch.sh` (`unit_gaps_tick`), `systemd/sala-unit-gaps.path`. stackshot: `client.py`
  `job_gap`, the `job-gap` route.
- **Absent or changed**: no `client.py` on the box, a `client.py` that does not name `job-gap` (an old client), a refusal or a timeout: the pass logs one line and exits 0, the
  watch tick goes on. A failed open is not recorded and is tried at the next pass; a failed clear keeps the record and is tried at the next pass. A record without an item id (written
  by version 17's message form) is opened once as an item. A repo missing from stackshot's list is a 400 on every open: keep the table's last column current.
- **Test**: `tests/jobs.sh` (a stub client.py that parses its arguments as strictly as the client does).
- **Stable**: from version 18.

## 27. CI-run files

- **Direction**: sala → stackshot (a file, and the CLI that reads it; stackshot's agents and scripts read, sala's poller writes).
- **Mechanism**: `$XDG_STATE_HOME/salamander/ci-runs/<owner>__<repo>.json` (`~/.local/state/salamander/ci-runs/…` when `XDG_STATE_HOME` is unset), written atomically
  (tmp + rename) every `SALA_CIPOLL_INTERVAL` s (60) by `salamander ci-poll`: `{"repo","updated" (epoch seconds of the last successful look, a 304 included),"updated_iso",
  "runs":[{id,name,head_sha,head_branch,event,status,conclusion,created_at,updated_at,html_url,run_attempt}]}`, the 30 newest workflow runs. A GitHub error leaves the
  file untouched, so `updated` ages. The reader is `salamander ci-runs <owner/repo> [--sha SHA] [--max-age SECS (120)] [--text]`: exit 0 and the JSON when fresh,
  3 no file for that repo, 4 older than `--max-age`, 5 unreadable, 2 usage; a caller falls back to its own GitHub read on 3, 4 and 5. The repos are the lines of
  `~/.config/salamander/ci-repos` (the tracked `lib/ci-repos` lists none, so a fresh install polls nothing).
- **Owners**: sala `lib/cipoll.py` (`poll_one`, `publish`, `cmd_runs`), `lib/cipoll.sh`, `lib/ci-repos`, `systemd/sala-cipoll.service`, `release.sh` (`ci_file_pending`).
  stackshot: any reader (none yet in the repo at the time of writing).
- **Absent or changed**: no poller running or a repo not in the list → exit 3 or 4 and the reader reads GitHub itself; the file is a window of the newest 30 runs, never a
  history, and its absence of a commit proves nothing (`docs/ci-runs.md`).
- **Test**: `tests/cipoll.sh` (the poller against a fake `gh`, the reader's exit codes), `tests/release.sh` (release.sh's use of it).
- **Stable**: from version 20.

## 28. Lane names

- **Direction**: sala → stackshot (sala writes a file and answers a CLI; stackshot reads).
- **Mechanism**: `salamander lane names [--json] [--write]` (`lib/lane.sh`, `lane_names_text` / `lane_names_json` in `lib/common.sh`; read-only, exit 0). The text
  form is one line per known lane: `code<TAB>display name<TAB>aliases` (aliases space-separated, empty when none). `--json` prints exactly
  `{"lanes":[{"code":"subscription-1","display":"Subscription 1","aliases":[]},{"code":"api","display":"API","aliases":[]},{"code":"subscription-2","display":"Subscription 2","aliases":[]},{"code":"sdk","display":"API","aliases":[]},{"code":"bedrock","display":"Bedrock","aliases":[]},{"code":"aws-platform","display":"AWS platform","aliases":["awsplatform"]}]}`
  (every lane in `SALA_LANES_KNOWN`, in that order, `sdk` included; `aliases` are the old words of a renamed lane, `[]` when it has none). `display` is the lane's
  `label` field, one setting per lane (`SALA_LANE_<ID>_LABEL`, default `Subscription 1` for `subscription-1`): a reader shows it and never spells a display name itself.
  The same JSON is kept in `$SALA_STATE_DIR/lane-names.json` (`~/.local/state/salamander/lane-names.json`), written atomically (tmp file and rename) by
  `salamander lane names --write` (which also prints the table) and and by a `sala watch` tick that finds the file missing, the config file newer than it, or sala's `lib/common.sh` newer than it (so a release that changes a default name is picked up, and an ordinary tick does nothing), and only when the content differs; a check that finds the same content only touches the file to mark it checked, so a reader can rely on the content, not the mtime.
- **Owners**: sala `lib/lane.sh` (`names`), `lib/common.sh` (`lane_names_json`, `lane_names_write`, `lane_label`), `lib/watch.sh` (the tick), `lib/lanewords.py` (the Python reader sala-web uses).
  stackshot: the reader (not in the repo at the time of writing).
- **Absent or changed**: the file is absent before the first watch tick after an update and on a sala older than version 27: a reader then runs the command, and
  falls back to showing the code itself when neither answers. A new lane adds an object; a renamed lane adds the old word to `aliases`; the keys `code`, `display`, `aliases`
  do not change without a version bump.
- **Test**: `tests/lane-subscription-codes.sh` (the JSON shape, the atomic write, the write only on change, the setting honoured).
- **Stable**: from version 27.

## 29. Fleet-op end event

- **Direction**: sala → stackshot (sala calls the client; stackshot wakes the items whose event wait the report ends).
- **Mechanism**: `python3 <client.py> event --kind fleet_op --verb <verb> --machine <full hostname> --sessions <N> --result ok|partial|failed --text "<one line>"`,
  run by `op_event` (`lib/op.sh`) as the last act of `op_finish`, with `timeout $SALA_OP_EVENT_TIMEOUT` (30 s), stdin closed, no lock held. The client is
  `stackshot_client` (`SALA_STACKSHOT_CLIENT`, else `SALA_STACKSHOT_DIR/client.py`). `--verb` is the op's verb (recycle, update, revive, retire,
  close-shell, forget-row, rename, lane, model, provision, spawn, reboot). `--machine` is the box that ran the op, or the one host an `update` / `provision`
  names. `--sessions` is the sessions the op covered: those it names when more than one (a lane or model batch, `revive --only` several), else the relaunch
  set's total (a recycle, an update, a whole-fleet provision), else 1 for a verb on one session, else 0. `--result`: `ok` = done and nothing failed or
  skipped; `partial` = some failed or were skipped (a pane given up, a session `FAILED` or `NOT moved`), others went through; `failed` = stuck with nothing
  through. `--text` is the Slack post's gist on one line (verb, state, the result line; never the owner's words), at most 230 characters.
- **Owners**: sala `lib/op.sh` (`op_event`, called from `op_finish`). stackshot `client.py` (`event`), `event_waits.py` (`event_from_report`).
- **Absent or changed**: once per operation (the marker's `evposted`), also when it ends stuck; not for `--plan`, a cancelled or an absorbed operation. No client on
  the box, a non-zero exit or a timeout: one line in `salamander-op.log`, the operation's outcome, Slack post and inbox line unchanged. The recycle's own report
  (interface 4, `client.py recycled`) is separate and stays.
- **Test**: `tests/op.sh` (the "reported to stackshot" section: one session, a many-session partial, failed, a recycle's set, a failing and a hanging client, no
  client), against `tests/fake-stackshot-client.py`.
- **Stable**: from version 29.

## 30. Machines tab files

- **Direction**: stackshot → sala web (files stackshot writes; sala-web reads them, read-only, at each request of `GET /api/machines`).
- **Mechanism**: under stackshot's state folder (`SALA_WEB_STACKSHOT_STATE`, else `[paths] state` in `stackshot.toml`, else `$XDG_STATE_HOME/stackshot`):
  `site/versions.json` (`packages: [{name, installed, latest, state, machines: {<letter>: version}, machine_state: {<letter>: text}, hosts}]`, `ssh_hosts:
  [{name, reachable, checked, packages: {<package>: version}}]`) and `clients/fleet/<letter>/machine.json` (`setup: {ok, step, at, reason}`, `updates: [{what, ok, at, reason, from, to}]`, `stackshot`: the box's checkout commit, since version 40) and
  `clients/advertised-commit` (the commit the server tells the boxes to follow: one 40-hex line, since version 40). The card drops a failed `stackshot checkout` attempt while `stackshot` equals the
  advertised commit, unless the attempt's reason starts `reload failed` and its `to` is the first 12 characters of `stackshot`; with either commit missing the last attempt decides. Also read:
  the fleet names TSV (interface 16), `[fleet] publisher_letter` and `[machines_panel] ssh_hosts` in `stackshot.toml`, and a machines list (`machines.toml`) and
  per-host `<host>.json` (`at_epoch`) kept in a host config repo and under `$XDG_STATE_HOME`. A file over 4 MB is not read. sala-web reads no runner file (version 36).
- **Owners**: sala `web/src/sala_web/machines.py` (`collect`), `config.py`. stackshot `fleet.py`, `ui/render.py` (`fleet_card`, `machine_alerts`, `server_commit`), `clients.py` (`_advertise`, which writes `advertised-commit`), whose merge
  and alert rules `machines.py` reproduces.
- **Absent or changed**: a missing, unreadable or oversized `site/versions.json` makes the tab say "No reading yet" (never an error). A missing, unreadable or malformed `clients/advertised-commit` (or a view without `stackshot`)
  is "commit unknown": the card then shows the last attempt, as before version 40. A key
  that changes meaning is read wrongly until `machines.py` follows; unknown keys are ignored.
- **Test**: `web/tests/test_machines.py`, `test_machines_ui.py` (made-up files in a temporary folder).
- **Stable**: unstable. These are stackshot's own render inputs with no file contract on its side; the listing is the first record of them.

## 31. sala-web saved color combinations

- **Direction**: sala's web app → stackshot (HTTP), the same token, address and header as interfaces 10, 21 and 22 (`Authorization: Bearer <token>`,
  `User-Agent: sala-web`). Adopted in version 33. Permanent: it serves the saved list of the color tool (`web/src/sala_web/static/colortool-sala.js` wires stackshot's shared `colortool.js`, pinned in sala).
- **Mechanism**: `GET /client/colors/combos` (no body, 20 s); `POST /client/colors/combos` `{name, values, sender}` (a save: `name` 1 to 40 characters, NFC, no control or format
  character; `values` the 14 keys `bg card fg mut line ibd link solid onsolid labbg labfg labbd disbg disfg`, each `#rrggbb` lowercase; a name already in the list, case ignored, is
  replaced in place and keeps its id); `POST /client/colors/combos/delete` `{id, sender}` (an unknown id is a 200 with the list as it is). `sender` is always `sala-web` (the
  server sets it; the page cannot). Every route answers 200 `{combos: [{id, name, values: {14 keys}, saved: <epoch>, via}], max: 50}` with `Cache-Control: no-store`. Errors are
  `{error: <a plain sentence>, field: "name"|"values"|"id"|"sender"|<a key>|null}`: 400 a bad name, value or key set, 401 no or a bad token (plain text), 403 not allowed (the sender,
  or the machine), 409 the list is full (50), 413 over 4 KB, 415 not JSON, 503 the file cannot be read (a standby copy, for the writes). Stackshot runs no contrast gate. sala's own
  routes are `GET /api/colors/combos`, `POST /api/colors/combos` and `POST /api/colors/combos/delete`: the body is checked there first (name, the 14 keys, each a hex color), the
  list is never cached, and an error comes back as the same `{error, field}` (stackshot's own sentence for 400, 403, 409, 413 and 415; 502 for an unreachable stackshot, a refused
  token or an answer that is not the list; 503 for no token or address on the machine or an unreadable list at stackshot). The rows of an answer that are not rows are dropped.
- **Owners**: sala `web/src/sala_web/colors.py` (the shapes, the calls), `app.py` (the three routes), `static/colortool-sala.js` (the wiring: it hands the tool the address `api/colors/combos`) and the pinned `static/colortool.js` (the panel, stackshot's own). Stackshot: the routes in its `server.py`,
  the store in its state folder (`color-combos.json`); its own page reaches the same list through its sign-in.
- **Absent or changed**: the panel shows the reason beside the saved list and every other part of the color tool works. A machine that is not in `form_machines`, or a `sala-web` that
  is not in `form_senders`, gets 403 with field `sender` on the writes (a read needs the machine gate only). An older stackshot without the routes answers 404: a 502 here.
- **Test**: `web/tests/test_colors_combos.py` (validation, the sender set here, every status passed through, unreachable, no setup) and `test_colortool_wiring.py` (the panel's list, save,
  replace, delete and unavailable states), both against `web/tests/fake_stackshot.py`, which holds the shapes above.
- **Stable**: yes from version 33, permanent.

## 32. sala-web usage analysis

- **Direction**: sala web → the page it serves (the Overview's Usage analysis tab); any other reader of the route is the same. No stackshot, Anthropic or AWS call is made. Added in version 37.
- **Mechanism**: `GET /api/usage?week=<0|1|2>` (default 0; anything else is 400 `{error}`), `?fresh=1` makes the next count due now. JSON, `Cache-Control: no-store`. The answer: `week`, `now` (epoch
  seconds, the server's clock), `tz` and `tzLabel` (always Asia/Seoul, KST: the days are KST whatever the page's zone), `resetKnown` and `anchor` (the weekly reset the weeks hang on, epoch s), `generated`,
  `weeks` (all three: `id`, `start`, `end`, `startKst`, `endKst`, `days`, `current`, `total`, `billed`, `replies`), `lanes` (`code`, `label`, `billing` `subscription`|`usage`, `flat`, `known`, `quota`
  `{percent, resetsAt}` of the weekly limit or null), `fields` (the order of a row), `rows` (the rows of the week asked for, arrays: `day`, `lane`, `model`, `project`, `agent`, `folder`, `usd`, `replies`,
  `tokens` `[input, cache write 5m, cache write 1h, cache read, output]`), `sameHours` (week 0 only), `unpriced` (`[{model, replies}]`) and `prices` (`asOf`, `unit`, `models`). With no count yet the answer is
  `{pending: true, ...}` and the reader asks again; a failed count keeps the last answer and adds `error` in plain words. It carries names, counts and dollars: no prompt, reply or tool text.
- **The Digest route** (added in version 38): `GET /api/usage/digest?week=<0|1|2>` (default 0; anything else is 400 `{error}`; `?fresh=1` as above). JSON, `Cache-Control: no-store`. The answer: `week`, `now`, `generated`,
  `tz`, `tzLabel`, `resetKnown`, `scope` (the words that only this machine's sessions are counted), `range` (`startKst`, `endKst`, `end`, `current`, or null before the first count) and `sentences` (a list of 1 to 7 plain
  sentences of English, dollars only, dates like `Sat Nov 7th`, written by templates over the same rows: no model call). `pending: true` with no sentences before the first count; `refreshing` and `error` as the route above.
  The same words come from the pure function `usage_digest.digest(answer)` over one week's `GET /api/usage` answer, so a scheduled job can deliver them.
  `GET /api/usage/replies?week=<0|1|2>&limit=<1..200>&<dimension>=<value>…` (added in version 39; `day`, `lane`, `model`, `project`, `agent`, `folder` filter, a name repeated is a list of alternatives; a bad `week` or
  `limit` is a 400 `{error}`) lists the replies behind a selection, newest first: `week`, `generated`, `tz`, `tzLabel`, `fields` (`time` KST `YYYY-MM-DDTHH:MM:SS`, `day`, `lane`, `model`, `project`, `agent`, `folder`,
  `usd`), `total` and `usd` of all that matched, `shown`, `capped`, `cap` (200), `rows` (arrays in the order of `fields`). It is computed from the same cached count (nothing is read again), is
  `{pending: true}` until a count has run after a restart, and carries no text and no token count.
- **Owners**: sala `web/src/sala_web/usage.py`, `usage_digest.py` (the sentences), `spend.py` (the one price table and `PRICES_AS_OF`), `app.py` (the routes), `static/usage.js`, `static/usage-digest.js`, `static/usage-explorer.js`.
- **Absent or changed**: a key that is added is ignored by a reader that does not know it; `fields` says the row layout, so a reader should index by it. A change to a key or to a row's layout bumps the version.
- **Test**: `web/tests/test_usage.py` (the data layer and the route), `test_usage_ui.py` (the page over the route), `test_usage_digest.py` (the sentences and the Digest route), `test_usage_digest_ui.py` (the Digest in a browser), `test_usage_explorer.py` (the replies list and route), `test_usage_explorer_ui.py` (Explorer over both routes).
- **Stable**: unstable (first release).

## Not an interface, but a name

Places that name stackshot without coupling to it (no bump when they change): `lib/reauth.sh` (the connector display name
"Stackshot" as an example), `lib/cue.sh:16` and `mod/hooks/register.ts:91` (comments), `web/README.md` (prose),
`docs/test-coverage.md`, `config.example` comments, and the `web/tests` fixtures that carry board
URLs on placeholder hosts (`board.example.test` and the like) as sample text.
