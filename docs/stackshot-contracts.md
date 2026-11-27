# sala ↔ stackshot: the interface contracts

contract-version: 65

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

- **41** — Sat Nov 7th 2026. Interfaces 7 and 20 (the agent check and the project record): the exit-3 refusal of `spawn --project` (a name not on the project's agents map) no longer
  tells anyone to add a line to the page's `agents:` map, which reaches no reader once a project has a record. Its stdout is now the marker `REGISTER: <key>` and under it stackshot's
  `client.py post project-agent <key> <name> --role <part of the name after the project's name> --front|--back --mandate "<one line>"` command (the `ADD-TO-PAGE: <key>` marker and its YAML are gone), and the
  keeper's message carries the same command. The exit codes (3 not listed, 4 `NO-PAGE:`, 1 cannot tell) and what a spawn of a listed name does are unchanged. sala-web's `block` field of its
  `not-listed` answer follows the new marker. Nothing stackshot reads or sends changed; sala still never runs the command.

- **42** — Sat Nov 7th 2026. New interface 33: sala's mockup pages. `sala mockup add FILE` stores an HTML page under the next number in sala's state folder and `GET /mockup/<n>` on sala-web serves it
  (inside the site's existing sign-in, in a sandbox), so a session without the Artifact tool hands a reader a link; a daily pass (`sala mockup clean`, `sala-mockup-clean.timer`) deletes pages over 7 days old
  and keeps the folder under 1 GB. The pass asks the host, through the command named in `SALA_MOCKUP_REFERENCES`, which pages an open board item links; no stackshot route or client call is added, and
  with the setting unset the pass deletes nothing. Nothing of stackshot changed.

- **43** — Mon Nov 9th 2026. Every interface that names a stackshot program by path (the post-recycle hook, recycle-wanted, the agents-map checks, the spawn keeper ask, the release report, sala-web roles, the parked-question seams, the CLI update hook, project agent retire, the terminal-prompt row, the unit-gap item, the fleet-op end event, the side-session commands): stackshot moved its programs from the root of its checkout into a package,
  and leaves a forwarder at each old root path until Sun Nov 22nd 2026. sala's defaults follow: the client is `stackshot/fleet/client.py` under `SALA_STACKSHOT_DIR` (was `client.py`), the agents-map script
  `stackshot/projects/pages.py` (was `pages.py`), the update hook's example `stackshot/web/publish.py bump` (was `publish.py`), and the mockup pass's example `stackshot/tools/open_item_text.py` (was
  `tools/open_item_text.py`). One helper per language finds them (`lib/stackshot-path.sh`; a small function in each Python module that needs it): the package path when that file exists, else the old
  root path when only that one does (a checkout from before the package), else the package path. A setting that names the file or the command itself (`SALA_STACKSHOT_CLIENT`, `STACKSHOT_CLIENT`,
  `SALA_AGENT_CHECK_SCRIPT`, `SALA_SPAWN_ASK_CMD`, `SALA_SIDE_*_CMD`, `SALA_POST_UPDATE_CMD`, `SALA_POST_RECYCLE_CMD`, `SALA_RECYCLE_WANTED_CMD`, `SALA_MOCKUP_REFERENCES`, `SALA_WEB_ROLES_CMD`) is used as written and
  never probed, so a config line naming an old root path works until its forwarder goes. The register command that `spawn --project` prints names the client's path as this box has it. Nothing
  stackshot reads or sends changed.
- **44** — Mon Nov 9th 2026. Interface 32 (sala-web's Usage analysis, `GET /api/usage`, `/api/usage/digest`, `/api/usage/replies`): a visit no longer starts a count. The count is a job of its own once a day
  (`web/contrib/sala-web-usage-count`) plus the tab's `?fresh=1` (Reload), and the routes serve the last saved count whatever its age. A new value of the answer: with no count made yet it is `{noCount: true, ...}`
  (it was `{pending: true, ...}`, which now means a Reload's count is running). The drill-down's records are saved with every count (`usage-replies.json` in sala-web's state directory), so `/api/usage/replies`
  answers at once after a restart. Nothing stackshot reads or sends changed.

- **45** — Mon Nov 9th 2026. Interface 12 (lanes and limit state): the `lim` of a `panes` entry of `salamander-limit.json` gains a value, `monthly`, for a pane stopped on a monthly usage cap
  (a 429 whose text says the account crossed its monthly usage threshold and when access returns); its `reset` is that time. `lane` is the lane the pane runs on, as for the login lanes' kinds. Additive: a reader
  that treats `lim` as an opaque word is unaffected. sala also marks such a lane dormant until that time (the seventh `until` column of its own `lane-state.tsv`, which stackshot does not read) and moves its sessions to the lane's fallback.

- **46** — Wed Nov 18th 2026. Interfaces 8, 11 and 20 (the keeper of a project): stackshot makes a project's keeper a mark on one agent instead of a separate name. In the roles file
  (`roles.json`, `SALA_ROLES_FILE`, the lane rule's second source) a session's entry may carry `"keeper": true` beside its `role` (`front` or `back`); the keeper is never a third role, and an entry
  whose `role` is the old `keeper` stays accepted until stackshot removes that form. sala counts a flagged entry with its own role (a marked builder as back, a marked -main or other non-builder as front),
  does not count a flagged entry that is retired, and still does not count an entry whose `role` is `keeper`, flagged or not; an entry without the flag reads exactly as before. In the project record
  (interface 20) each project may carry two more fields, `keeper_agent` (the agent that keeps the project) and `keeper_source` (`mark`, `derived`, `legacy` or `empty`), and an agent's entry may carry
  `"keeper": true`; `keeper` stays an agent name. All additive and optional: sala reads none of them and requires none, so a record without them reads as before. The spawn keeper ask (interface 8) is
  addressed to the project's keeper, the mark on one agent (the builder, else the -main agent, when nothing is marked); its command, text and exit codes are unchanged.
- **47** — Fri Nov 20th 2026. Interfaces 19, 20 and 11 (the surface of a front agent): a front agent may answer the owner on Slack instead of in sala. In the project record (interface 20) an agent's entry may carry `"surface": "slack"`; absent means `sala`, the only other value, and anything else is refused by sala wherever it reads or writes one. `sala sessions tag --auto` copies it onto the session's registry row (and clears a stale `slack` from a row whose entry has none), and `sala spawn --surface slack` writes it at birth. The registry's session rows (interface 19, `session-registry.json`) carry `"surface": "slack"` only for a slack row, so every other row's shape is as before. In the roles file (interface 11) a session's entry may carry `"surface": "slack"` the same way (only when slack), which sala-web reads for its session list; without it the row's own surface is used. All additive and optional: a reader that ignores the key reads exactly as before.
- **48** — Sun Nov 22nd 2026. New interface 34 (the spawn gate) and interfaces 21 and 25: every agent session sala creates is on stackshot's project record before its pane exists. `sala spawn` decides from the record first (listed: yes); a name not on it, spawned with `--role` and `--mandate`, is registered through `client.py post project-agent <project> <name> --role <word> --front|--back --mandate <line> --sender sala-spawn` and the pane starts only on the 200; any other answer (or stackshot unreachable) stops the spawn with stackshot's reason and no pane. `sala retire` asks `post project-agent-retire` (`sala-retire`) BEFORE it closes the pane of a session that is on the record: "not listed" goes on, any other refusal stops the retire and leaves the pane alone (it was asked after the fact before). A rename and a registration are read back from the record. `agent_name_check` wraps `GET /client/agent-name` (live since stackshot c554182a; any answer that is not its JSON falls back to sala's own suggestion). Stale wording corrected: stackshot writes the record directly and answers `page_owed: false`, and with `copy_project_lines=false` a retire writes no page block and no timeline line. Nothing stackshot reads or sends changed in shape.
- **49** — Sun Nov 22nd 2026. Interfaces 7, 8, 20, 21, 25 and 34 (the spawn gate, second half): sala's checks read stackshot's project record alone and stop asking `pages.py`. Interface 7 (`pages.py resolve`, `agent-listed`) is retired: sala no longer runs it, so `SALA_AGENT_CHECK_SCRIPT`, the page-exists check and the `NO-PAGE: <key>` answer (exit 4) are gone, and the stackshot side owes nothing to sala's `pages.py` readers any more. Interface 8 (the spawn keeper ask, `client.py message`) is retired too: nobody is messaged when a spawn is refused, and `SALA_SPAWN_ASK_CMD` and `SALA_SPAWN_ASK_EVERY` are gone. A record that cannot answer (missing, stale, unreadable, another schema, no such project) now **refuses a spawn of a name the exceptions list does not cover** with exit 6 and no pane, where it used to fall back to `pages.py` (project spawn) or go on (plain spawn); a box with no stackshot at all (no record file, no client) is still not checked. A retire whose project cannot be found because the record cannot answer goes on and says so (a warning line and the retire log), and a retire's re-check after stackshot's answer also leaves the pane alone when another pane of the session now runs a claude or the registry row's conversation can no longer be read. Nothing stackshot reads or sends changed in shape; the exit codes of `sala spawn` change (4 is gone, 6 is new for this case).
- **50** — Mon Nov 23rd 2026. Interface 3 (inbox hold files): `watch` now also frees a key that is in `held-msg.txt` or `held-hub.txt` and that no row of sala's ledger names (neither as uuid nor as session name), once sala has seen it unaccounted for 10 minutes (`SALA_INBOX_ORPHAN_SECS`); the held files carry no times, so sala keeps the first time it saw each such key in `~/.local/state/salamander/inbox-held-unaccounted.tsv` (sala's own file, stackshot never reads it). A key with a ledger row is freed as before, by its row, never by this path. The files are edited under the same lock as every other hold, through the same rewrite (`_hold_edit del`), and the line is logged in the watch log. Until now such a key (left by a host move, a restore from backup or a half-failed release) held its session's queue until someone edited the file. For stackshot nothing changes in shape: it sees a key leave the file, and its next poll delivers what it kept. The file split agreed with stackshot (live on its side): stackshot's reboot resume (`reboot-hooks/reboot-queue.py`) writes only `held-resume-msg.txt` and `held-resume-hub.txt` in the same folder, rewriting each whole (a held key of a retired session is dropped when it writes); sala keeps writing `held-msg.txt` and `held-hub.txt` and its ledger, and the reboot resume never touches them. `inbox.take`, `inbox.blocked` and `push.paused` read the union of the two files per source (`held-msg.txt` with `held-resume-msg.txt`, `held-hub.txt` with `held-resume-hub.txt`), a missing file counting as empty. sala never reads, writes or frees `held-resume-*`: a key the resume holds has no expiry on sala's side, and the 10-minute path above never sees it. Before this split the resume rewrote `held-msg.txt` and `held-hub.txt` themselves, and the keys it left for sessions that did not come back were freed after 10 minutes; they now stay held until stackshot's next resume writes the file.
- **51** — Mon Nov 23rd 2026. New interface 35 (sleeping sessions), and interfaces 1 and 19 gain one optional key. A session sala has put to sleep (its claude ended on purpose; its tmux session, pane and pane-map row stay) is a session that is present. What stackshot may read: (1) the marker `$SALA_STATE_DIR/sleeping/<conversation uuid>` (default `~/.local/state/salamander/sleeping/`; one line, `<ISO-Z time> <name>`), whose existence is the whole fact; (2) the heartbeat's `sessions.json` (interface 1): a sleeping session has a row keyed by its conversation uuid, with the usual `name`, `url`, `seen`, `machine` and one more key, `sleeping` (the ISO-Z time it went to sleep), present only on a sleeper; before this version such a session had no row at all, because the row is made from a live claude; (3) `session-registry.json` (interface 19): the session's row keeps `state: live` and carries `sleeping` the same way; (4) `sala sessions --json`: the same `sleeping` key on the row. Wake is `sala op wake --only NAME (--item board#N | --why "<reason, three words or more>") --from YOU`; a name that is not asleep queues nothing. A wake keeps the session's conversation uuid, so its `sessions.json` key does not change; the row loses `sleeping`. Nothing puts a session to sleep on its own yet, so until the idle tick (a later stage) no row carries the key unless someone ran `sala sleep`. All additive and optional: a reader that ignores `sleeping` reads exactly as before, with one difference it will see: a sleeper now has a row in `sessions.json` where it had none.
- **52** — Mon Nov 23rd 2026. Interface 35 (sleeping sessions): sala's watch wakes a sleeping session when a stackshot message line waits for it. For each session with a marker, the watch (`wake_tick`, `lib/wrapup.sh`, run every tick, always on) looks in the inbox's `hub/` and `msg/` folders for a line that names the session or its conversation uuid (the predicate `sleep_ready` already used to refuse a sleep for a waiting message; a held key does not hide the line) and runs `sala wake NAME` for it, at most 5 sleepers per run, with one watch-log line per wake (`wake: woke NAME — inbox line waiting …`). The inbox files are never touched: the line stays queued until the resumed pane takes it, nothing is dropped or reordered. A notice (`sala notice`) does not wake. For stackshot nothing changes in shape: it writes the message as it does today and never runs a sala verb to wake a session; the key `sleeping`, the marker and the `sala op wake` command are as in 51. Also new on sala's side, with no change to any file or command stackshot reads: the watch's idle sleep tick (`SALA_IDLE_SLEEP`, off by default, at most 3 sessions per run) puts idle sessions to sleep with `sala sleep`, so a row may now carry `sleeping` without anyone having run `sala sleep` by hand once the owner turns it on; `sala sleep --candidates` lists what it would sleep. A woken session also gets a wake stamp, `$SALA_SLEEP_DIR.woke/<conversation uuid>` (sala's own, a folder beside the marker folder; stackshot never reads it).
- **53** — Mon Nov 23rd 2026. New interface 36 (failed scheduled runs): a job's `OnFailure=` starts `sala-job-failed@<unit>.service`, which runs `sala job alert failed <unit>` and makes one call, `client.py job-failed <unit> <host> <ISO-Z time of the failing run> <project>`; the job's `ExecStopPost=` runs `sala job alert ok <unit>` after every run and, only for a success that finds the marker the failure dropped, makes one call, `client.py job-ok <unit> <host> <ISO-Z time>`. stackshot's verbs are not built when this was written (sala's side fails soft: one log line).
- **54** — Mon Nov 23rd 2026. Interface 3 (inbox hold) gains a second way to hold, and interface 35 follows it: on a box that is not the stackshot server's, sala holds a session's inbox and asks whether a line waits for it through four calls of stackshot's client instead of files (stackshot's `docs/inbox-holds.md`). `client.py post inbox-hold KEY… [--kind msg|hub] [--minutes N]` (answer `{held:{msg:[..],hub:[..]}, expires}`; N is above 0 and at most 1440, sala never sends 0), `client.py post inbox-release KEY… [--kind K]` (answer `{released:{kind:[keys]}, held_elsewhere?:[keys]}`: it lifts only holds the call made, and names a key another tool's file still holds), `client.py get inbox-holds [KEY]` (answer `{holds:[{kind,key,origin api|file|resume,since,expires}], now}`) and `client.py get inbox-waiting NAME[,UUID]` (answer `{keys,hub,msg,waiting,held:{hub,msg}}`). Where it is held follows the client's own setting, `[client] push_mode` (`local` files, `server` server, `auto` server when the client's URL names another machine, stackshot's `push.py` rule); `SALA_INBOX_MODE=files|server` overrides it for sala alone, default `auto` = the client's setting; in files mode nothing changes. Fail-safe: a call that gets no answer in `SALA_INBOX_TIMEOUT` (5) s, or a status other than the unknown-verb ones (404, 405, 501; a 400 is the server's refusal), or an answer not of the shape above, is NO ANSWER, never "nothing waits" and never "held": the waiting check then says a line waits (`sleep_ready` refuses, the wake pass neither wakes nor counts a failed wake), `sala sleep` is refused when its hold fails, and a relaunch whose hold failed goes on only through its idle re-check. A client exit code 4 (a retriable delivery error) is asked once more, then no answer without the pause that follows other no answers. An unknown verb, or a client that prints its usage, means the server does not have the call: sala falls back to the hold files when the box has the hold folder, and has no answer when it has not. The orphan sweep in server mode frees only `inbox-holds` rows of origin `api` with no expiry, never a `file` or `resume` row. A server with none of these calls is read as one that is not up to date, never as one that holds nothing.

- **55** — Mon Nov 23rd 2026. Interface 20 (project record), with the roles list of interfaces 11, 24 and 25: sala asks stackshot by its address first and reads the file copy only when stackshot cannot be reached. A copy written by the puller can be many hours old while the truth has not moved, so a reader that opened the file first read an old record as fresh enough. Now one reader (`lib/stackshot_record.py`, `record_file_r` on the shell side) runs `client.py get state-files` (its `projects` key is the whole record, schema 1) for the project record and `client.py get roles` for the roles list, each under `timeout` (`SALA_RECORD_LIVE_TIMEOUT`, 15 s) with stdin closed; an answer that is not JSON, has no record or is not schema 1 counts as no answer. The answer is kept for `SALA_RECORD_LIVE_TTL` seconds (20), a failed ask as long. When stackshot did not answer, the copy at `SALA_PROJECT_RECORD` / `SALA_ROLES_FILE` is read with its age said (the refusal text, the source line, and one line in `salamander-record.log` at most every five minutes); `SALA_PROJECT_RECORD_MAX_AGE` and `SALA_ROLES_FILE_MAX_AGE` now limit only the copy. `SALA_RECORD_LIVE=off` reads the copy alone. No change on stackshot's side: it answers two verbs it already has. What each reader does when neither answers is as before (a spawn fails closed, a rename refuses, a retire says so and goes on). Smaller verb for stackshot to consider (not asked for): the client has no verb that returns only the project record, so each ask carries the whole `state-files` answer (about 700 KB); a `get projects-record` verb, or a `--only projects` option on `get state-files`, would cut that to the record itself.
- **56** — Mon Nov 23rd 2026. Interface 20 (project record): sala reads stackshot's project record with `client.py get projects-record` (stackshot's record-only read, `GET /client/projects-record`, which returns exactly the value `get state-files` carries under `projects`, 503 when the file does not read) instead of `get state-files`, so an ask no longer carries the other files that read bundles (about 700 KB). The answer is the record itself, with no `projects` key to unwrap; the roles list (`get roles`) is unchanged. A stackshot that predates the verb answers 404 `no such read`: sala then asks `get state-files` once and unwraps its `projects` key as before, and says so in one line of `salamander-record.log` (never an error), so an older stackshot still works. Settings, the file copy and what each reader does when nothing answers are unchanged.

- **57** — Mon Nov 23rd 2026. New interface 37 (a caller's own key), and a second credential on five existing calls. sala makes and keeps an Ed25519 key (`sala stackshot-key init|enroll|status`), enrolls its public half once (`POST /keys/enroll`, approved by the owner on a board item) and trades a signed claim for a 10-minute pass (`POST /keys/pass`, `ssp_...`). The pass goes, as `Authorization: Bearer <pass>` (`STACKSHOT_CLIENT_PASS` for `client.py`), on exactly the New session form's calls: `post project-agent` (interfaces 21 and 34), `post project-agent-rename` (21), `post project-agent-retire` (25), the For you list's two writes (22: `POST /client/for-you/seen`, `POST /client/items/<key>/watch`) and the color combos writes (31: `POST /client/colors/combos`, `POST /client/colors/combos/delete`). Every other call keeps the machine token. With no key, a key still waiting, a server that is not reached or one that says no, the call goes with the machine token as before, so nothing needs a pass yet. Version 56 is the project-record read (pull request 207); this entry is numbered after it.

- **58** — Tue Nov 24th 2026. New interface 38 (agent state). The heartbeat writes `agent-state.json` beside `session-registry.json` in the live store (this box's own letter, never into the store repo): one entry for each live or sleeping agent of the session registry, with whether it is busy, idle or unknown and its running subagents, taken from stackshot's own `running()` (`audit/subagent_tie.py`, imported from stackshot's checkout, never copied). Every run rewrites it, then hands it to stackshot with `POST /client/agent-state` (stackshot's route is being built, so a 404 or any failure is one log line per five minutes and never a failed heartbeat). Interfaces 1 and 19 are unchanged.

- **59** — Wed Nov 25th 2026. Interface 30 (Machines tab files): which machines the tab lists, with their names and letters, now comes from sala's own machine list (`machine_list()` in `lib/machines.py`, also printed by the new `sala machines [--json]`, and `sala host sala|stackshot` reads or sets the host record through the owner's holds script) instead of the web app reading the fleet names TSV (interface 16) on its own. The list reads the fleet names TSV and, beside it, the tailnet candidates, the ssh fleet config, the `[[hosts]]` records and the follow list, read-only. Nothing visible changes: the tab shows the same cards in the same order, and the versions, failures and follow lines still come from the files named in the interface. stackshot's side is unchanged, and the new commands are not interfaces yet (a later version lists them).
- **60** — Wed Nov 25th 2026. New interface 39 (machines). The heartbeat writes `machines.json` beside `agent-state.json` in the live store (this box's own letter, never into the store repo): sala's machine list (`machine_list()` in `lib/machines.py`, the one reader of the owner's machine files, the same list `sala machines --json` prints) with the machine files that were named and could not be read. Every run rewrites it, then hands it to stackshot with `POST /client/machines` when the list changed since the last good post and otherwise every 10 minutes, so stackshot can show the list's age (stackshot's route is stackshot's to build in a later stage, so a 404 or any failure is one log line per five minutes and never a failed heartbeat). Interfaces 1, 30 and 38 are unchanged.
- **61** — Wed Nov 25th 2026. New interface 40 (the owner's whole Your move list). The chat page's Waiting on you strip reads stackshot's `GET /client/your-move` (every item of the board home page's Your move group, no cap, in the page's own order) instead of taking the owner's moves from the per-session board feed of interface 10, which lists only the moves some session of this box is tied to. The feed stays as the fallback. Interface 10 is unchanged.
- **62** — Wed Nov 25th 2026. Interface 39 (machines): each row of `machines` gains four optional keys, `online`, `last_seen`, `versions` and `checked` (the tailnet's view of the machine, the versions sala read on the posting box itself, and when the row was read). Schema stays 1 and a receiver that ignores unknown keys is unaffected; absent or null means unknown. The fingerprint that decides when the list is posted leaves `checked` out, so the post still goes on a change or every 10 minutes. Interfaces 1, 30 and 38 are unchanged.
- **63** — Thu Nov 26th 2026. Interface 40 (the owner's whole Your move list): sala-web now also reads the answer's `group`, `{"en", "ko"}`, stackshot's own name for the group, and draws it in the chat strip's words (the pinned line, its titles, the drawer chip) in place of its own copy, which stays only as the fallback. Optional: an older stackshot with no `group`, or one that is malformed, leaves the strip on sala's own words. `items` is read as before.
- **64** — Thu Nov 26th 2026. New interface 41 (the open items the chat session is the contact of or an observer on): sala-web reads `GET /client/involved?key=<the configured chat session name>` for a second tab, On it, of the chat page's pinned strip. An item the strip's first list shows is left out of that tab. Optional: while the read is unavailable (a server without it answers 404) the strip is as before. Interfaces 10 and 40 are unchanged.
- **65** — Thu Nov 26th 2026. Interface 41 (the open items the chat session is the contact of or an observer on) is retired: sala-web no longer calls `GET /client/involved`. The chat page's second tab, On it, lists what the chat session has promised to report back (its own `sala motion` lines, read from sala's state directory), which no other repository writes or reads. `GET /api/chat` drops `onIt`. Interfaces 10 and 40 are unchanged, and nothing on stackshot's side has to change.

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
| 3 | Inbox hold files (`held-msg.txt`, `held-hub.txt`; stackshot's own `held-resume-msg.txt`, `held-resume-hub.txt`, which sala leaves alone) and, from version 54 on a box that is not the server's, the client calls `post inbox-hold`, `post inbox-release`, `get inbox-holds`, `get inbox-waiting` | sala → stackshot | stable | `tests/phases.sh`, `tests/inboxorphans.sh`, `tests/inboxserver.sh` |
| 4 | Post-recycle hook (`client.py recycled`) | sala → stackshot | stable | `tests/autorecycle.sh`, `tests/phases.sh`, `tests/sets.sh`, `tests/flags.sh` |
| 5 | Recycle-wanted (`client.py recycle-wanted`) | stackshot → sala (sala asks) | stable | `tests/autorecycle.sh` |
| 6 | Puller-lag file and path unit | stackshot → sala; sala → provision | retired in version 11 | none (the checks went with it) |
| 7 | Agents-map checks (`pages.py resolve`, `agent-listed`) | sala → stackshot | retired in version 49 (the project record, interface 20, decides alone) | `tests/spawn.sh` (a `pages.py` tripwire that must never run) |
| 8 | Spawn keeper ask (`client.py message`) | sala → stackshot | retired in version 49 | none (the ask went with it) |
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
| 30 | Machines tab files (`site/versions.json`, `clients/fleet/<letter>/machine.json`, `clients/advertised-commit` in stackshot's state folder) | stackshot → sala web | unstable (stackshot's own render inputs, no stated file contract on its side) | `web/tests/test_machines.py`, `test_machines_ui.py`, `test_machines_registry.py` (made-up files), `tests/machines.sh` |
| 31 | sala-web saved color combinations (`GET /client/colors/combos`, `POST /client/colors/combos`, `POST /client/colors/combos/delete`) | sala web → stackshot | stable from version 33 (permanent) | `web/tests/test_colors_combos.py`, `test_colortool_wiring.py` (a fake stackshot) |
| 32 | sala-web usage analysis (`GET /api/usage?week=0\|1\|2`, optional `&fresh=1`; the Digest's `GET /api/usage/digest` with the same query; Explorer's `GET /api/usage/replies`) | sala web → the page it serves (or any reader of the route) | unstable (the Report, Explorer and Digest views; `GET /api/usage/digest` added in 38, `GET /api/usage/replies` in 39) | `web/tests/test_usage.py`, `test_usage_ui.py`, `test_usage_explorer.py`, `test_usage_explorer_ui.py`, `test_usage_digest.py`, `test_usage_digest_ui.py` (fake transcripts) |
| 33 | sala mockup pages (`sala mockup add\|update\|history\|undo\|list\|remove\|clean`, `GET /mockup/<n>`, the `SALA_MOCKUP_REFERENCES` command) | sala → the host's board reader (a command the host names) | unstable (first release) | `tests/mockup.sh`, `web/tests/test_mockup.py` (a stub reader, a real headless browser) |
| 35 | Sleeping sessions (marker file, `sleeping` in `sessions.json` and `session-registry.json`, `sala sessions --json`, `sala op wake`) | sala → stackshot (the wake: stackshot's side runs sala's CLI) | stable from version 51 (first release); the wake on a message line from version 52 | `tests/sleepshow.sh`, `tests/sleeping.sh`, `tests/sleepverbs.sh`, `tests/sleeptick.sh` |
| 34 | Spawn gate (`client.py post project-agent … --sender sala-spawn` before a pane exists; `post project-agent-retire` before a pane is closed; `GET /client/agent-name`) | sala → stackshot | stable from version 48 | `tests/spawn.sh`, `tests/retire.sh`, `tests/rename.sh` (a stub `client.py`) |
| 36 | Failed scheduled runs (`client.py job-failed`, `client.py job-ok`, from `sala job alert`, run by a job's `OnFailure=` and `ExecStopPost=`) | sala → stackshot | unstable (first release; stackshot's side not built) | `tests/jobalert.sh` (a stub client.py) |
| 37 | A caller's own key (`sala stackshot-key`, `POST /keys/enroll`, `POST /keys/pass`; the pass on the New session form's calls) | sala → stackshot | unstable (first release; stackshot's routes are the contract it is written against) | `tests/stackshotkey.sh` (a stub server that checks the claim as the contract says), `web/tests/test_formpass.py` |
| 38 | Agent state (`agent-state.json` in the live store, `POST /client/agent-state`; `SALA_AGENT_STATE_POST_CMD`) | sala → stackshot | unstable (first release; stackshot's route is being built) | `tests/agentstate.sh` (a stub stackshot checkout and a stub post command; the parity section needs the real checkout) |
| 39 | Machines (`machines.json` in the live store, `POST /client/machines`; `SALA_MACHINES_POST_CMD`) | sala → stackshot | unstable (first release; stackshot's route is not built yet, a 404 is expected) | `tests/machinespost.sh` (a made-up fleet folder, a stub post command) |
| 40 | sala-web's Your move list (`GET /client/your-move`) | sala web → stackshot | stable (the route is live) | `web/tests/test_yourmove.py`, `test_chatpage.py` (a fake stackshot) |
| 41 | sala-web's On it list (`GET /client/involved`) | sala web → stackshot | retired in version 65 | none (the read went with it) |

## 1. Heartbeat fleet store

- **Direction**: sala → stackshot.
- **Mechanism**: files. `SALA_HEARTBEAT_STATE_DIR` (default `~/.local/state/salamander/fleet`, `config.example:142`),
  one subdirectory per machine letter, two files:
  - `sessions.json`: `{"<transcript uuid>": {"name", "url", "seen", "machine"[, "previous_name", "renamed_at"]}}`.
    `url` is the session's link: on the writer's own rows the web link `SALA_SESSION_URL` gives (default empty, so the claude.ai address or `""`; a template such as
    `https://sala.example.com/s/{name}` with `{name}` percent-encoded as `encodeURIComponent` does,
    `lib/common.sh:107-112`), on a swept box's rows the claude.ai Remote Control address or `""` while the bridge is down.
    `previous_name` + `renamed_at` (ISO-8601 UTC) only on a row of the driving machine `salamander rename` renamed (`lib/heartbeat.sh:39-41`,
    written at `:311` from `salamander-renames.jsonl`, `lib/rename.sh:197`). `sleeping` (ISO-Z; version 51) only on the row of a sleeping session, which the heartbeat makes from its marker (interface 35).
  - `machine.json`: `{"letter", "fleet", "claude", "checked", "master", "master_session", "fleet_ssh"}` (`master` and `master_session` are empty strings since the master path was retired; the keys stay and no consumer reads them, so no version bump);
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

- **Direction**: sala → stackshot (files in stackshot's state dir; on a box that is not the server's, the four client calls below, from version 54).
- **Mechanism**: **where it is held (version 54): the stackshot client's own setting, `[client] push_mode` (`$ANCHOR_PUSH_MODE` for one process): `local` is files, `server` is server, `auto` is server when the client's URL names another machine.** `SALA_INBOX_MODE=files|server` overrides it for sala alone (the default `auto` means "ask the client's setting"); with no client to ask, the config file's `[client] push_mode`, else the URL rule alone. `files` is everything below this paragraph. `server` replaces it, on a box
  whose stackshot state directory is not the server's, with four calls of stackshot's client (`lib/inboxhold.py` runs them, each with a `SALA_INBOX_TIMEOUT` (5) s timeout; the final contract is stackshot's `docs/inbox-holds.md`):
  `client.py post inbox-hold KEY… [--kind msg|hub] [--minutes N]` → `{"held": {"msg": [..], "hub": [..]}, "expires": epoch|null}` (holding again refreshes the time; sala holds both
  sources for `SALA_INBOX_HOLD_MINUTES`, 10, and counts the hold as made only when every key is listed in both; **never `--minutes 0`**: the server refuses it because a hold made by the call always ends, so sala sends 1440, the longest, for a setting of 0, 10 for a negative or non-numeric one, and never more than 1440; at most 20 keys a call and 500 keys a source; the server takes its own hold out when its time is up);
  `client.py post inbox-release KEY… [--kind K]` → `{"released": {"<kind>": [keys]}, "held_elsewhere"?: [keys]}` (lifts only the holds the call made: a key that a file of another tool (`held-<source>.txt`) or a reboot's resume still holds is named in `held_elsewhere`, present only when there is one, and is left for the tool that wrote it: sala says so and counts its own hold as released);
  `client.py get inbox-holds [KEY]` → `{"holds": [{"kind", "key", "origin": "api"|"file"|"resume", "since", "expires"}], "now": epoch}`;
  `client.py get inbox-waiting NAME[,UUID]` → `{"keys", "hub": n, "msg": n, "waiting": bool, "held": {"hub": bool, "msg": bool}}` (what `inbox_line_waiting` asks instead of reading the message folders; a line counts held or not).
  The `auto` rule is stackshot's own (`push.py`): `server` when the client's URL (`STACKSHOT_URL`, else the client's own resolution, else `[client] url`) names a host that is not this box (not loopback or unspecified, not `localhost`, not this box's host name or fully qualified name, nor a bare name that is the first label of either), `files` otherwise or with no URL.
  **Fail-safe (version 54):** a call that is not answered within the timeout, answers 400, 401, 403 or 5xx, or answers a body not of the shape above is *no answer*: never "nothing waits",
  never "held". The waiting check then reads as *a line waits*; the watch's wake pass does not wake on it and does not count a failed wake; `sala sleep` is refused (nothing ended, nothing held) when its hold gets no answer; a relaunch whose
  hold failed goes on only through the idle re-check every relaunch already makes; a release that got no answer keeps its ledger row, so `inbox_release_stale` asks again. After a no answer sala does not ask again for `SALA_INBOX_BREAKER` (30) s.
  A client that ends with its code 4, the retriable delivery error (stackshot's `push.py` uses it; the inbox calls end 0 or 1, so this is defensive), is asked once more at once; a second 4 is no answer that does not start the breaker (the next turn asks again).
  A 404, 405 or 501, or a client that prints its usage, is an *unknown verb* (a stackshot without the calls): sala falls back to the files when the box has the hold folder, and has no answer when it has not. A 400 is the server's refusal of a bad key, kind or time, or its 500-key cap, never an unknown verb.
  In server mode `inbox_release_orphans` reads `inbox-holds` and frees a key of origin `api` with no expiry that no ledger row names, after the same 10 minutes (a hold with an expiry is the server's to drop, a `file` row is another tool's and the release would only name it in `held_elsewhere`, a `resume` row is never freed, a failed list changes nothing).
  **Files mode:** `SALA_INBOX_HOLD_DIR` (default a folder under stackshot's state directory, `lib/common.sh`). sala appends a
  pane's keys (its transcript uuid and its name, one per line) to `held-msg.txt` and `held-hub.txt` while it relaunches the
  pane, removes them after, and keeps its own ledger `salamander-inbox-holds.tsv` so `watch` drops a hold older than 10 min
  that a dead relaunch left (`inbox_release_stale`). A key in those two files that no ledger row names (the ledger and the held
  files live in different folders) is freed once sala has seen it unaccounted for 10 min (`inbox_release_orphans`, contract 50;
  first-seen times in sala's `inbox-held-unaccounted.tsv`). Stackshot's reboot resume holds its keys in its own
  `held-resume-msg.txt` and `held-resume-hub.txt` (rewritten whole, never touching sala's two files); stackshot reads the union of the
  two files per source, a missing file counting as empty, and sala never reads, writes or frees `held-resume-*` (a resume hold
  has no expiry on sala's side).
  **When** (contract 23): a sweep writes the keys of every pane it will close at the start of phase 2, before any pane is exited,
  then waits `SALA_HOLD_SETTLE` (3 s) so a line stackshot handed out just before the hold has reached the pane; each close then
  re-reads the pane (`is_idle_reason`: registry status `idle`, idle for `SALA_IDLE_SETTLE`, the Stop hook's busy record, no work
  child, no recent scratch write; it never reads the transcript) just before it types `/exit`, and a pane that is no longer idle is
  deferred with its hold cleared. The `--self` worker does the same for the master's pane (hold, settle, wait for idle, one last
  look, then the retry worker if it is still busy; its waits stack, up to three times `SALA_SELF_WAIT`, 15 min by default). A pane skipped in phase 1 is
  never held. The hold is cleared for a pane that is skipped, deferred or fails to exit, and after a successful resume.
- **Owners**: sala `lib/common.sh` `_hold_edit`, `inbox_hold`, `inbox_touch`, `inbox_release`, `inbox_release_stale`, `inbox_release_orphans`, and for version 54 `inbox_mode_r`, `_inbox_call`, `_inbox_edit` and `lib/inboxhold.py` (the four calls); `lib/wrapup.sh` `inbox_line_waiting` (the check, either way), `sleep_ready`, `wake_candidates`; `lib/sleep.sh` (the refusal);
  callers `lib/revive.sh` (phase 2's hold loop and exit trap, `close_pane`'s re-check and releases, the `--self` worker). stackshot `inbox.py:30` `FLAGS`, its inbox state folder
  (`paused-<src>.json`, `held-<src>.txt`, `release-<src>.txt`), `:146` reads them; `inbox.take` skips held keys.
- **Absent or changed**: server mode (version 54): see the fail-safe above; the server's missing calls are the unknown-verb fallback, never a silent "nothing waits". Files mode: "A missing stackshot is no error: nothing is held" (the comment above `inbox_hold` in `lib/common.sh`): the helpers return 0
  when the directory does not exist. A renamed file or a key format stackshot stops matching means a line delivered during
  a relaunch is dropped, as before the hold existed (the defect it fixes).
- **Test**: `tests/inboxserver.sh` with `tests/fake-inbox-client.py` (the four calls' shapes, mode resolution, the time never 0, `held_elsewhere`, exit code 4, each failure, the unknown-verb fallback, the waiting check, the orphan sweep in server mode; server-mode cases also in `tests/sleeping.sh` and `tests/sleepverbs.sh`), `tests/inboxorphans.sh` (the keys no row names), `tests/nomaster.sh` (the watch's log line); `tests/phases.sh` (hold dir present, all holds written at least the settle before the first `/exit`, a pane that turns busy
  after its hold is deferred and queued for retry, a skipped pane's hold cleared, holds released after the sweep and after a TERM in
  the settle); `tests/sets-self.sh` (the `--self` worker: busy after the hold hands off to the retry worker, an abort releases
  the hold, both with an empty registry name).
- **Stable**: yes.

## 4. Post-recycle hook

- **Direction**: sala → stackshot (CLI).
- **Mechanism**: `SALA_POST_RECYCLE_CMD` (unset by default; a machine running stackshot sets `python3 ~/stackshot/stackshot/fleet/client.py recycled`,
  `config.example:139-141`), run detached with `sh -c` ONCE PER CLEARED FLAG (version 19): a recycle's flag clears when every
  live pane has relaunched since the flag's time, or partly when a pane is held past `SALA_LATER_LIMIT`; a clean reboot calls it
  once. Environment it sees: `SALA_RECYCLE_KIND=recycle|reboot`, `SALA_RECYCLE_STARTED=<epoch>` and
  `SALA_RECYCLE_FLAG_AT=<epoch>` (the flag's time, the same number), `SALA_RECYCLE_RESULT=ok|partial` (ok iff nothing skipped),
  `SALA_RECYCLE_SKIPPED="<tmux sessions the flag did not get back, space-separated>"`. Example for a partial clear:
  `SALA_RECYCLE_KIND=recycle SALA_RECYCLE_STARTED=1790000000 SALA_RECYCLE_FLAG_AT=1790000000 SALA_RECYCLE_RESULT=partial
  SALA_RECYCLE_SKIPPED="scratch-1" python3 ~/stackshot/stackshot/fleet/client.py recycled`. sala parses one output line,
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
- **Mechanism**: `SALA_RECYCLE_WANTED_CMD` (unset by default; a machine running stackshot sets `python3 ~/stackshot/stackshot/fleet/client.py recycle-wanted`,
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

## 7. Agents-map checks (retired in version 49)

- **Retired**: sala no longer asks `pages.py` anything. Until version 48 the project record (interface 20) was read first and `python3 <pages.py> resolve <key>` /
  `agent-listed <name>` answered when the record could not; version 49 removes that fallback and everything that went with it (`agent_unlisted`, `agent_check_script`,
  `page_exists`, `agent_listed_on`, the `SALA_AGENT_CHECK_SCRIPT` knob, the `NO-PAGE: <key>` answer and exit 4 of `spawn`). `SALA_AGENT_CHECK=on|off` stays: `off` is the only bypass of the spawn gate.
- **Now**: the record decides alone (interface 20, *Reading rule*). A record that cannot answer for a name the exceptions list (`agent_gate_exempt`, interface 34) does not cover
  refuses the spawn with exit 6 and no pane, "stackshot's project record cannot answer (<why>): … retry when it is fresh, or `SALA_AGENT_CHECK=off` to start it unchecked"; the in-place entry
  rename of `sala rename` refuses the same way; a retire (interface 25) goes on and says it did not ask. A box with no stackshot at all (no record file readable, no client) is not checked.
- **Test**: `tests/spawn.sh` (the record cannot answer: missing, stale, unreadable, another schema, no such project; the exempt names; `SALA_AGENT_CHECK=off`; a box with no stackshot), and
  a `pages.py` tripwire in `tests/side.sh`, `tests/opparallel.sh` and `tests/retire-own.sh` (a stub that fails the suite if anything runs it).
- **Stable**: retired.

## 8. Spawn keeper ask (retired in version 49)

- **Retired**: `sala spawn` used to message the project's keeper (`client.py message <page key> <text> --sender "sala spawn"`, at most once per `SALA_SPAWN_ASK_EVERY`) with the command that
  registers an unlisted name. Version 49 removes it with `SALA_SPAWN_ASK_CMD`, `SALA_SPAWN_ASK_EVERY` and `spawn_ask_keeper`: a refused spawn prints the register command (`REGISTER: <key>` and the
  `post project-agent` line, exit 3) for the caller to run, and a spawn with `--role` and `--mandate` registers the name itself (interface 34). Nobody is messaged.
- **Stable**: retired.

## 9. Release report

- **Direction**: sala → stackshot (CLI message).
- **Mechanism**: `release.sh` `CLIENT="${STACKSHOT_CLIENT:-$SALA_STACKSHOT_DIR/stackshot/fleet/client.py}"` (`~/stackshot` when the knob is unset;
  empty: no client, the message is only logged; from the environment, the script reads no config), `tell()` runs
  `python3 "$CLIENT" message <project page key> "<text>" --sender release`; texts
  `[release] PR #N merged and deployed — <title> — main at <sha>; changed: …` and `[release] PR #N FAILED at <step>: …`.
  A release that queued the PR a second time (`docs/merge-queues.md`, *The one retry*) says so in free text after those starts: appended to the green one
  after what changed (`· queued twice: …`), inside the red one's reason; both name the failed run and still end `· log <path>`.
  After a successful deploy and before that message, `report_live` runs
  `python3 "$CLIENT" released --pr https://github.com/<owner>/<repo>/pull/<n> --sha <merge commit>` (stackshot `client.py released`): the merge commit is main's
  for a PR that was already merged, else what `gh pr view --json mergeCommit` names after the merge, else the first-parent merge of that PR in the checkout.
  Its output lines are logged as `items of PR #N: …`. A failed release never calls it.
- **Owners**: sala `release.sh` (`tell`, `report_live`, `run`). stackshot `client.py` `message` and `released`; `routing.py` records the message under
  `<state>/routing/salamander.jsonl`.
- **Absent or changed**: a deploy that changed nothing (`deploy.sh` printed `changed: nothing`) sends no message, only the log line `no message: the deploy changed nothing …`. `tell` never fails the run; a missing client logs `message not sent: <text>` in the release log. `report_live` never fails it either:
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
- **Mechanism**: `SALA_WEB_ROLES_CMD` (default `python3 $SALA_STACKSHOT_DIR/stackshot/fleet/client.py get roles`: `~/stackshot` when `SALA_STACKSHOT_DIR` is
  unset in sala-web's environment, no command when it is empty, `config.py` `_roles_cmd`), every
  `roles_ttl` 30 s; expects JSON `{"sessions": {<name>: {"role", "project"}}}` (an entry may also carry `"keeper": true`, the mark of a project's keeper from version 46: sala-web ignores it, and `role` is still `front` or `back`, or the old `keeper`; from version 47 an entry may also carry `"surface": "slack"`, only when slack, which sala-web puts on the session's JSON).
- **Owners**: sala `web/src/sala_web/sessions.py:377` `RolesCache`. stackshot `client.py:107` `get("roles")` →
  `GET /client/roles` (503 `no roles yet` before the first roles file).
- **Absent or changed**: a failure keeps the last good answer and sets `rolesError`; the overview shows sessions without
  roles. An empty `SALA_STACKSHOT_DIR` runs nothing and sets `rolesError` to say so. Fail-open.
- **Test**: `web/tests/test_sessions.py` (the surface only when slack included), `web/tests/test_roles_cmd.py` (the default and the knob).
- **Stable**: yes.

## 12. Lanes and limit state read by stackshot

- **Direction**: stackshot → sala (stackshot reads sala's state files).
- **Mechanism**: `stackshot.example.toml:310` `lanes_file = "~/.local/state/salamander/lanes.tsv"` (`<session>\t<lane>` rows;
  `lane-default` beside it; `subscription-1` when neither; a row written before version 27 may carry an older lane word, read as the lane's current code: interface 28) for its `lane <session> <lane>` done check (stackshot renamed it from
  `sala_lane`; the old name is still accepted on stored items); `:313`
  `limit_file = "~/.claude/salamander-limit.json"` whose `panes` map (transcript uuid → `{s, lane, lim, since, reset}`; version 35 adds `rlane`, the lane the pane runs on; version 45 adds the `lim` value `monthly`)
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
  `SALA_STACKSHOT_CLIENT`, default `$SALA_STACKSHOT_DIR/stackshot/fleet/client.py`: `~/stackshot/stackshot/fleet/client.py` when that is unset, none when it is empty) is `contrib/question-board-file.sh` / `-answer.sh`. File:
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
  "retired_at", "transcripts": [{"id": "<claude session id>", "machine", "at", "why"}]}}}`. A row of a slack front agent carries one more key, `"surface": "slack"` (version 47; no other row has the key, `sala` being the default). The row of a sleeping session carries `"sleeping": "<ISO-Z>"` (version 51; interface 35) and keeps `"state": "live"`.
  `project` and `project_key` both
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
- **Test**: `tests/sessions.sh` (phase 3 section): contents, atomicity, `written` refresh, the off flag, a corrupt registry, the surface only on a slack row.
- **Stable**: yes from version 4.

## 20. Project record

- **Direction**: stackshot → sala (sala asks stackshot's client; a file stackshot rewrites is the copy sala reads when stackshot cannot be reached). Adopted in version 5 from the phase 5 half of
  `docs/session-registry-contract-proposal.md`; version 55 makes stackshot's own answer the first source and the file the fallback.
- **Where sala reads it from (version 55; the record-only verb since 56)**: stackshot is asked first, by its address, through its client, and the file copy is read ONLY when stackshot cannot be reached. One reader does it for both the shell
  and the Python side (`lib/stackshot_record.py`, used through `record_file_r` in `lib/common.sh` and by `lib/bgagents.py`). The ask is `client.py get projects-record` (its answer is the whole record below, schema 1, and nothing else; version 56, before it the ask was `client.py get state-files`, whose `projects` key is the same record
  among about 700 KB of other files; `get project <key>` returns one project, which the readers cannot use), run under `timeout` (`SALA_RECORD_LIVE_TIMEOUT`, 15 s) with stdin closed. A stackshot that predates the verb answers 404 `no such read` (the client prints `[404] no such read: …` and exits 1): the reader then asks `client.py get state-files` once instead and takes its `projects` key, and says so in one line of `salamander-record.log`, not as an error; a failed ask that is not a 404 is never asked again with the older read. An answer that is not JSON, has no
  record, or is not schema 1 counts as no answer. stackshot's answer is written whole and atomically under sala's state folder (`record-live/projects.json`) and read as the file always was, so the reading rule below
  runs on it unchanged. It is kept for `SALA_RECORD_LIVE_TTL` seconds (20), a failed ask as long, so one command or one tick of the watch asks once however many readers it has. When stackshot did not answer, the copy is read and
  its age is said: in the refusal or the source line the reader prints, and in one line of `salamander-record.log` in `SALA_LOG_DIR` (at most one per five minutes). `SALA_RECORD_LIVE=off` (a box with no stackshot to ask) reads the copy alone, and a box
  with no client does the same without saying that anything failed. Each reader keeps what it did when no record could be read: a spawn of a non-exempt name fails closed (exit 6), a rename refuses, a retire says so and goes on.
- **Mechanism (the copy)**: `~/.local/state/stackshot/projects.json` (`SALA_PROJECT_RECORD` overrides the path), written atomically by
  stackshot's `projects.py` `sync()` whenever the records change and at least every 4 minutes. Schema 1:
  `{"schema": 1, "generated": "<ISO Z>", "projects": {"prj_<8 hex>": {"id", "key" (the project page key), "keeper",
  "keeper_agent"?, "keeper_source"?, "agents": {"<name>": {"front": true|false, "role", "mandate_line", "page_owed"?: true, "keeper"?: true, "surface"?: "slack"}}}}, "by_key": {"<page key>": "<id>"}}`.
  The keeper is a mark on one agent (version 46): `keeper` stays an agent name, `keeper_agent` is the agent that keeps the project and `keeper_source` says where it came
  from (`mark`: a mark names it; `derived`: no mark, so the builder, else the -main agent; `legacy`: the page's old fields name it; `empty`: nothing keeps it), and the marked agent's
  entry carries `"keeper": true`. `keeper_agent`, `keeper_source` and the entry's `keeper` are optional additive fields that sala does not read and does not require.
  `surface` (version 47) is the entry's other optional field and sala does read it: absent means `sala` (only an absent field: an explicit empty string or `null` is no value and is refused like any other), `slack` is a front agent that answers the owner on Slack, and any other value is refused
  (`tag --auto` leaves the whole row as it is, no project and no role written, and says why, for a row with a role as well as one without; a back agent named `slack` is left too, and a row whose role is back is never made slack; `spawn` reads the same entry before it chooses the start directory, so a registered Slack agent spawned without `--surface` starts in the Slack brief's directory, a `--surface` that conflicts with the entry is refused, and an entry whose surface sala cannot use (an empty one included) refuses the spawn too, with the reason and the project record named; that lookup, `sessions record-surface`, reads only the project record and never the session registry, so a registry that is missing, corrupt or unreadable changes nothing; a record that is missing, stale or does not list the name refuses nothing, the flag alone decides, and `SALA_SESSIONS=off` does not stop the read). `sala sessions tag --auto` copies it onto the session's row, a record without it clears a stale `slack`.
  `front` is true for a top-level entry of the page's `agents:` map and false for one under `background:`; `role` is the part
  of the name after the project's name (`alex-builder` → `builder`); the project's main agent is the front entry whose
  name ends in `-main`. `page_owed` is optional: stackshot writes the record directly and answers `page_owed: false` for an agent registered now, so a true value only survives in an older record
  (there it marked an agent whose page line was still owed; sala treats such an agent as listed, as before). Before version 55 sala read the file alone (no client call); now the file is the copy for when stackshot cannot be reached.
  `client.py get project <key>` returns one project's live record; only `sala sessions`' read-back after a registration uses it (interface 21), before it falls back to the copy.
- **Reading rule (sala)**: the record answers only when it is readable JSON of schema 1, `generated` is at most
  `SALA_PROJECT_RECORD_MAX_AGE` (600 s) old, and the project key is in it. Then, for `spawn --project K NAME --role R`: the
  name on the project's agents map and `front` agreeing with `R` is **listed** (an agent with `page_owed` counts as listed:
  its registration is the point; the dry run says the line is owed); the name absent is **not listed** (exit 3, the
  `REGISTER: <key>` line and, under it, the `post project-agent` register command with the project, the name, the role (the
  part of the name after the project's name, from the project's main agent; `<role>` when the record gives none),
  `--front` or `--back` and the mandate's first line (`"<one line>"` when the spawn had none); no instruction to edit the
  page's agents map, which reaches no reader once a project has a record; nobody is messaged (version 49); a spawn never calls it, `sala rename` of a side session does, since version 14); the name present with the other `front` is refused with exit 1 and the
  record's role. For a plain spawn only a listing matters: a name on any project's map is listed. Anything else the record cannot answer (file missing or unreadable, another schema,
  stale, no such project) **refuses** a spawn of a name the exceptions list does not cover: exit 6, no pane (version 49: it fell back to `pages.py`, interface 7, before). A box with no stackshot at all (no record file, no client) is not checked.
  The in-place entry rename of `sala rename OLD NEW` is the exception: the record decides alone, read once (one copy of the file for both names), no `pages.py` fallback (its answer "no project page for this name", exit 0, was once read as "listed" and a rename of a listed agent
  changed only the pane). OLD on a project's agents map (`listed on <key>`) and NEW on none of a fresh record: the entry is renamed through interface 21 on that project's key;
  NEW already listed, or OLD on no map (a scratch pane): no call, not an error; a record that cannot answer (stale, missing, unreadable, behind a directory that denies traversal, or readable but not copyable for the one snapshot) refuses the rename with its reason and renames nothing;
  so does an OLD on the agents maps of two or more projects, with a reason naming their keys (the record gives no one project as its entry's). `rename --sync`, a hand rename that is followed, goes on and says the reason on stderr; a box whose record is
  absent (stat says no such file or directory, not any other error) and with no stackshot client has nothing to ask and goes on.
  A side session renamed to an agent name keeps its own path (version 14) and reads the same record (`record_name_unlisted`): a record that cannot answer refuses the rename in its plan.
  `sala watch` reads the record a second time to notice an agent pane that is live here and on no project's map (no interface change and no version bump: one more reader of the same file under the same reading rule): `project_record_agent "" NAME` per live agent pane that the spawn gate's exceptions list (`agent_gate_exempt`) does not skip; rc 3 (a fresh record that lists the name nowhere) is "unregistered", rc 0, 4 and 5 are fine, and rc 1 (missing, stale, unreadable) posts one "could not check" line and never a per-pane one (`lib/watch.sh`, `unregistered_tick`; `docs/subcommands.md`, `watch`).
  The same reading rule gives a live session with no role its role (`sala sessions tag --auto`, `back-names`; the
  back agents' lane rule counts from it): a name on exactly one non-retired project's map is that project's agent, `front`
  true a front agent and false a back agent; a name on no map or on several is left alone. The same single-project reading gives the row its `surface`, for a row with a role as well as one without.
- **Owners**: sala `lib/stackshot_record.py` (`resolve`, the one reader), `lib/common.sh` `record_file_r`, `project_record_agent`, `record_name_unlisted`, `lib/spawn.sh` (the record check and `spawn_record_refuse`), `lib/sessions.py` `load_record` / `derive_role` / `derive_surface` (the role and surface fill). stackshot `projects.py` (`build`, `sync`, `_record`).
- **Absent or changed**: stackshot not reached and no usable copy, or a copy that is old or of another schema: the record cannot answer (a spawn of a non-exempt name exits 6, see above; no `pages.py` is asked). A stackshot that adds fields is
  harmless (sala reads `front`, `mandate_line`, `page_owed` and the names only). A change of the three meanings above, or of
  the schema number, needs this document's bump and a sala change first. The record lags the page by up to its refresh
  interval: a line just added to a page may show as unlisted for a few minutes.
- **Test**: `tests/recordlive.sh` (the live-first read with a stub client: stackshot answering, down, hanging, not JSON, no record; the copy's age said; a stale copy refused; the keeping time; the rename's one answer; the roles list; the Python side; `SALA_RECORD_LIVE=off`). `tests/unregistered.sh` (the watch's read: missing, listed, exempt, stale, missing file, garbage). `tests/spawn.sh` (the project record section: listed, unlisted, front vs back, page_owed, the main agent, missing,
  stale, garbage, other schema, "the record cannot answer", the exempt names). `tests/sessions.sh` (the `tag --auto` section: the surface copied, cleared, left on a bad value).
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
  record directly and answers `page_owed: false` (interface 20): nothing is owed on the page and the form shows nothing to copy.
  `POST /client/project-agent-retire` (`post project-agent-retire`, interface 25) with `copy_project_lines=false` on the project writes NO page block and NO timeline line:
  the record alone changes (`line removed`, `dropped` or `not listed`), so nothing is left for a page keeper to do.
- **Credential (version 57)**: `project-agent` goes with sala's own pass when sala has one (interface 37; the shell calls through `lib/stackshot_form.py`, the web app's `add_agent` through `formpass.py`), the machine token otherwise; `project-agent-rename` the same; everything else here keeps the machine token.
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
- **Credential (version 57)**: the two writes (`POST /client/for-you/seen`, `POST /client/items/<key>/watch`) go with sala's own pass when sala has one (interface 37), the machine token otherwise; the read keeps the machine token.
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
  store (interface 1) before the lookup. A typical setting is `python3 ~/stackshot/stackshot/web/publish.py bump` (host config in
  `~/.config/salamander/config`, not in this repo; `config.example` leaves it empty). sala does not call stackshot's MCP tool by
  that name: `publish.py bump [--host <fleet name>]` is the same action as the `bump_versions` tool (`bump()` →
  `publish(force_versions=True)`: refresh the latest-available versions of the claude-code npm package and other tracked releases,
  then re-render and publish the board). stackshot accepts `--host` and `host` and ignores them (installed
  versions come from the heartbeat store); the command's output is discarded and only its exit status is read.
- **Owners**: sala `lib/common.sh` `post_update_hook`, `SALA_POST_UPDATE_CMD` (and the older `SALA_FLEET_POST_CMD`); `docs/notices-and-hooks.md`
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
- **Mechanism**: `python3 <client.py> post project-agent-retire <project> <name> --sender sala-retire` (`_retire_call`, `lib/common.sh`; since version 48 asked FIRST by `retire_ask_first`, before `lib/retire.sh` types `/exit` or kills the pane, a session on the closed exceptions list excepted (interface 34); `retire_drop_agent` keeps the after-the-fact call for `forget-row`, whose pane is already gone; the client is `stackshot_client`: `SALA_STACKSHOT_CLIENT`, else `SALA_STACKSHOT_DIR/stackshot/fleet/client.py`). Run under
  `timeout 90` with stdin `/dev/null` (version 25; 45 before: stackshot now reads and writes the page, which takes longer than the one read it used to make), once per successful retire (not in `--dry-run`, which
  only says "would tell stackshot …"). `<project>` is the hub page key (`projects/<slug>`, `infra/<slug>`): the session's registry row `project`
  (`retire_project_of`, read before the retire marks the row retired), else a side session's record `project`, else its origin agent's, else the
  `project` that stackshot's roles list gives the name (from version 24: `timeout 20 python3 <client.py> get roles`, stdin closed, else the file
  `SALA_ROLES_FILE`, default `~/.local/state/stackshot/roles.json`; `{"sessions": {<name>: {"project": …}}}`, interface 11's shape; from version 55 it is the shared reader of interface 20, `lib/stackshot_record.py`, with a 15 s ask, a copy's age said in the log line, and the copy used only when stackshot did not answer). The source the
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
  (the session is gone either way). An older stackshot without the verb fails the call the same way. Since version 48 this fail-soft reading holds only for what is not a refusal: asked first, a retire of a session that is on the record is refused when stackshot refuses or cannot be reached
  (409, 403, 400, 422, 502, a timeout, `[0]`), with stackshot's reason and the pane left alone; `not listed`, a 404 (no such project) and no project or no client to ask go on. Asking again is the way out of any refusal (the call is idempotent). With `copy_project_lines=false` a retire writes no page block and no timeline line (interface 21).
- **Items read (version 26)**: before anything is ended `lib/retire.sh` calls `retire_open_items` (`lib/common.sh`): `python3 <client.py> get items <tmux name>`, then `<conversation id>` (`SALA_RETIRE_ITEMS_CMD` replaces the command, as `SALA_SIDE_ITEMS_CMD` does for the side gate; `timeout $SALA_RETIRE_ITEMS_TIMEOUT`, 30 s, stdin closed), reading `{"items": [{"shown": "board#N", "roles": ["mover"|"then"|"needs"], "held": bool, …}]}`. It runs in `--dry-run` too. Tested by `tests/retire-verbs.sh` against a stub that answers items, none, a failure, a hang and garbage.
- **Credential (version 57)**: `post project-agent-retire` goes with sala's own pass when sala has one (interface 37, through `lib/stackshot_form.py`), the machine token otherwise.
- **Test**: `tests/retire.sh` (the agent entry sections; a stub `client.py` that logs its arguments and answers line removed, dropped, not listed, a 502, a 409 (in progress) or exit 1, and answers `get roles` from a file; the project fallback: row project, roles from the client, roles from the file, and none of them; the refusals are exit 1 in the real client, as in the stub's fail mode).
- **Stable**: yes from version 16 (stackshot's `project-agent-retire` is live).

## 24. Terminal-prompt "Your move" row

- **Direction**: sala → stackshot (CLI, from the machine that drives, `python3 <client.py> post terminal-prompt …`; `client.py` is found by `stackshot_client`: `SALA_STACKSHOT_CLIENT`, else `SALA_STACKSHOT_DIR/stackshot/fleet/client.py`).
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

- **Direction**: sala → stackshot (CLI, from the machine that drives, `client.py post job-gap`; `client.py` is found as for interface 18: `SALA_STACKSHOT_CLIENT`, else `SALA_STACKSHOT_DIR/stackshot/fleet/client.py`, `~/stackshot/stackshot/fleet/client.py` when that is unset).
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
  `stackshot_client` (`SALA_STACKSHOT_CLIENT`, else `SALA_STACKSHOT_DIR/stackshot/fleet/client.py`). `--verb` is the op's verb (recycle, update, revive, retire,
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
  `[fleet] publisher_letter` and `[machines_panel] ssh_hosts` in `stackshot.toml`, and a machines list (`machines.toml`) and
  per-host `<host>.json` (`at_epoch`) kept in a host config repo and under `$XDG_STATE_HOME`. WHICH machines exist, with their names and letters (from version 59), is sala's machine list,
  `machine_list()` in `lib/machines.py`: the fleet names TSV (interface 16) and, in the places beside it, the tailnet candidates, the ssh fleet config, the host record (`machine-holds.toml`) and
  the follow list, all read-only; a machine one file names and another does not is listed with the missing parts empty. A letter the names file reserves for a machine that is gone (a `# <letter> = <name>, retired` comment)
  is no card of its own, and a machine with no letter is a card only through the fleet state's letter or `ssh_hosts`, as before. A file over 4 MB is not read. sala-web reads no runner file (version 36).
- **Owners**: sala `web/src/sala_web/machines.py` (`collect`), `config.py`, `lib/machines.py` (`machine_list`). stackshot `fleet.py`, `ui/render.py` (`fleet_card`, `machine_alerts`, `server_commit`), `clients.py` (`_advertise`, which writes `advertised-commit`), whose merge
  and alert rules `machines.py` reproduces.
- **Absent or changed**: a missing, unreadable or oversized `site/versions.json` makes the tab say "No reading yet" (never an error). A missing, unreadable or malformed `clients/advertised-commit` (or a view without `stackshot`)
  is "commit unknown": the card then shows the last attempt, as before version 40. A key
  that changes meaning is read wrongly until `machines.py` follows; unknown keys are ignored.
- **Test**: `web/tests/test_machines.py`, `test_machines_ui.py`, `test_machines_registry.py` (made-up files in a temporary folder), and `tests/machines.sh` for the list itself.
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
- **Credential (version 57)**: the two writes (`POST /client/colors/combos`, `POST /client/colors/combos/delete`) go with sala's own pass when sala has one (interface 37), the machine token otherwise; the read keeps the machine token.
- **Test**: `web/tests/test_colors_combos.py` (validation, the sender set here, every status passed through, unreachable, no setup) and `test_colortool_wiring.py` (the panel's list, save,
  replace, delete and unavailable states), both against `web/tests/fake_stackshot.py`, which holds the shapes above.
- **Stable**: yes from version 33, permanent.

## 32. sala-web usage analysis

- **Direction**: sala web → the page it serves (the Overview's Usage analysis tab); any other reader of the route is the same. No stackshot, Anthropic or AWS call is made. Added in version 37.
- **Mechanism**: `GET /api/usage?week=<0|1|2>` (default 0; anything else is 400 `{error}`), `?fresh=1` (the tab's Reload) starts a count; nothing else does (the count is a daily job's, version 44). JSON, `Cache-Control: no-store`. The answer: `week`, `now` (epoch
  seconds, the server's clock), `tz` and `tzLabel` (always Asia/Seoul, KST: the days are KST whatever the page's zone), `resetKnown` and `anchor` (the weekly reset the weeks hang on, epoch s), `generated`,
  `weeks` (all three: `id`, `start`, `end`, `startKst`, `endKst`, `days`, `current`, `total`, `billed`, `replies`), `lanes` (`code`, `label`, `billing` `subscription`|`usage`, `flat`, `known`, `quota`
  `{percent, resetsAt}` of the weekly limit or null), `fields` (the order of a row), `rows` (the rows of the week asked for, arrays: `day`, `lane`, `model`, `project`, `agent`, `folder`, `usd`, `replies`,
  `tokens` `[input, cache write 5m, cache write 1h, cache read, output]`), `sameHours` (week 0 only), `unpriced` (`[{model, replies}]`) and `prices` (`asOf`, `unit`, `models`). With no count made yet the answer is
  `{noCount: true, ...}` (version 44; `{pending: true, ...}` while a Reload's count runs, and the reader asks again); a failed count keeps the last answer and adds `error` in plain words. It carries names, counts and dollars: no prompt, reply or tool text.
- **The Digest route** (added in version 38): `GET /api/usage/digest?week=<0|1|2>` (default 0; anything else is 400 `{error}`; `?fresh=1` as above). JSON, `Cache-Control: no-store`. The answer: `week`, `now`, `generated`,
  `tz`, `tzLabel`, `resetKnown`, `scope` (the words that only this machine's sessions are counted), `range` (`startKst`, `endKst`, `end`, `current`, or null before the first count) and `sentences` (a list of 1 to 7 plain
  sentences of English, dollars only, dates like `Sat Nov 7th`, written by templates over the same rows: no model call). `noCount: true` with no sentences before the first count; `pending`, `refreshing` and `error` as the route above.
  The same words come from the pure function `usage_digest.digest(answer)` over one week's `GET /api/usage` answer, so a scheduled job can deliver them.
  `GET /api/usage/replies?week=<0|1|2>&limit=<1..200>&<dimension>=<value>…` (added in version 39; `day`, `lane`, `model`, `project`, `agent`, `folder` filter, a name repeated is a list of alternatives; a bad `week` or
  `limit` is a 400 `{error}`) lists the replies behind a selection, newest first: `week`, `generated`, `tz`, `tzLabel`, `fields` (`time` KST `YYYY-MM-DDTHH:MM:SS`, `day`, `lane`, `model`, `project`, `agent`, `folder`,
  `usd`), `total` and `usd` of all that matched, `shown`, `capped`, `cap` (200), `rows` (arrays in the order of `fields`). It is computed from the same saved count (the records every count saves; nothing is read again), is
  `{noCount: true}` until a count has saved them, `{pending: true}` while a Reload's count runs, and carries no text and no token count.
- **Owners**: sala `web/src/sala_web/usage.py`, `usage_digest.py` (the sentences), `spend.py` (the one price table and `PRICES_AS_OF`), `app.py` (the routes), `static/usage.js`, `static/usage-digest.js`, `static/usage-explorer.js`.
- **Absent or changed**: a key that is added is ignored by a reader that does not know it; `fields` says the row layout, so a reader should index by it. A change to a key or to a row's layout bumps the version.
- **Test**: `web/tests/test_usage.py` (the data layer and the route), `test_usage_ui.py` (the page over the route), `test_usage_digest.py` (the sentences and the Digest route), `test_usage_digest_ui.py` (the Digest in a browser), `test_usage_explorer.py` (the replies list and route), `test_usage_explorer_ui.py` (Explorer over both routes).
- **Stable**: unstable (first release).

## 33. sala mockup pages

- **Direction**: sala → the host's board reader. `sala mockup clean` runs the command named in `SALA_MOCKUP_REFERENCES` (no shell, 60 s) and reads its output. Nothing is sent to stackshot and no stackshot route or client verb is used by sala itself. Added in version 42.
- **Mechanism**: pages are files, `<state>/mockups/<n>.html` (mode 600, folder 700) plus `counter`, written only by the CLI (`sala mockup add`, and `update` and `undo` on an existing number) and read by sala-web's `GET /mockup/<n>`; the versions saved by `update` and `undo` live under `versions/<n>/` and are served only read-only, through the page's history (`/mockup/<n>/versions/<id>`). The cleanup pass deletes a page older than 7 days
  (`SALA_MOCKUP_KEEP_DAYS`) unless an open board item links it (a revision is `sala mockup update N` on the same number; its saved versions under `versions/<n>/` go with the page), then, if the folder holds more than 1 GB (`SALA_MOCKUP_MAX_BYTES`, 1073741824), deletes the oldest pages first, linked pages last. "Linked" is
  every `/mockup/<n>` in the output of the reference command (exit 0 needed); `none` means nothing is linked; unset or empty means the pass keeps every page and says why (exit 0); a command that fails keeps every page (exit 1).
  No supported read of the board gives a script the text of an item's description without a model call (the brief lists subjects, `get items` has no description, the item facts hold status only),
  so the host supplies the command; the contract asks stackshot for nothing.
- **Owners**: sala `lib/mockup.py`, `lib/mockup.sh`, `web/src/sala_web/mockup.py`, `app.py` (the route), `systemd/sala-mockup-clean.{service,timer}`.
- **Absent or changed**: with no reference command nothing is deleted; a change to the reference line's form, the folder layout or the route's headers bumps the version.
- **Test**: `tests/mockup.sh` (numbering, refusals, `update` with its saved versions, `history`, `undo`, both cleanup rules with a stub reader and fake sizes and ages), `web/tests/test_mockup.py` (the route, its headers and a real headless browser).
- **Stable**: unstable (first release).

## 34. Spawn gate

- **Direction**: sala → stackshot (CLI calls from the machine that drives; stackshot answers over its own HTTP routes). Added in version 48.
- **Mechanism**: a session sala creates is on the project record before its pane exists. `lib/spawn.sh` reads the record first (`project_record_agent`, interface 20): listed means yes. Not listed, with
  `--role <word>` (a plain spawn; `--project K --role front|back` for a project spawn) and `--mandate`, `--front|--back` optional (default back): `agent_register` (`lib/common.sh`) runs
  `python3 <client.py> post project-agent <project> <name> --role <word> --front|--back [--surface slack] --mandate <one line, 600 at most> --sender sala-spawn` (`SALA_SPAWN_SENDER`; `timeout 90`, stdin closed) right
  before the pane is made (after every check and the dry run); 200 starts the pane, any other answer prints stackshot's `[status] reason` and exits 6 with no pane (400 a bad field or a name without the project's prefix, 403 a hub or retired
  page or a sender not allowed, 409 the name taken or on the other side, `[0]` stackshot not reached). Then `agent_record_read_back` reads the record back (`client.py get project <key>`, else the published file, up to
  `SALA_READBACK_WAIT` = 30 s): the name must be listed on the side asked; if not, the spawn stops with exit 6 and no pane. Not listed and no `--role`/`--mandate`: refused (exit 3), with the reason and the register command (`REGISTER: <key>` on stdout when the
  project can be told from the name). The closed exceptions list, kept in one function (`agent_gate_exempt`): sala's own shell session (`SALA_SHELL_SESSION`), a side session (`spawn --side`, or a `-side-` name), a spawn's
  auto-generated throwaway name, and the names `scratch-*`, `*-check-*`, `*-test-*`, `*-probe-*`. Revive, recycle, adopt, restore and the relaunch paths create no session and never come here. A rename is read back the same way after
  `post project-agent-rename` (NEW listed, OLD gone) and after a side session's listing (NEW listed as a front agent). `sala retire` asks `post project-agent-retire` (interface 25) before the pane is closed.
  `spawn --suggest-name` asks `agent_name_check`: `GET /client/agent-name?key=<project page key>&names=a,b,c` (live since stackshot c554182a; machine-token bearer auth like the other client reads; CLI `client.py get agent-name <project> <name> [<name> ...]`, 20 names at most, `SALA_AGENT_NAME_CMD` replaces it) answering `{"results": [{name, valid, code, reason}], "first_free", "prefixes"}`; `code` is prefix, format, listed, pending, retired, hidden, hub or limit. It takes no lock and registers nothing, and exits 0 whenever it answers, even when every name is invalid: sala reads `valid`, never the exit code. A name already `listed` reads `valid: false` even where the register would answer 200 "nothing changed": that is "already ours", not a refusal, so the gate decides "listed" from the project record first and the check only suggests names (the wrapper answers rc 3 when none is valid and one is listed). A name `pending` for any sender reads pending, sala's own sender included; a bad-shape name on a hub, hidden or retired project reads hub, hidden or retired; for a project whose id is not in the id file the read may write that id (as `get project` does). `valid: true` means the register will not refuse the name now; a name can be taken between the read and the register, so the register's refusal is still handled and the register call stays the real yes. A 404, no client, a connection error, a timeout or a non-JSON answer is "unavailable" and the suggestion is sala's own (a free tmux name, a free word); stackshot's check does not see tmux, live sessions or retired names of other machines, so sala's own check stays.
- **Owners**: sala `lib/spawn.sh` (the gate, `spawn_register_plan`, `spawn_register_do`), `lib/common.sh` (`agent_gate_exempt`, `agent_register`, `agent_record_read_back`, `agent_name_check`, `retire_ask_first`), `lib/retire.sh`, `lib/rename.sh`. stackshot: the `project-agent` and `project-agent-retire` routes; the `agent-name` route.
- **Absent or changed**: stackshot unreachable or refusing stops a spawn that needs the registration (fail-closed: no pane); a record that cannot answer (missing, stale, unreadable, another schema, no such project) stops the spawn of a name the exceptions list does not cover with exit 6 and no pane (`spawn_record_refuse`; version 49), where a project spawn once fell back to `pages.py` and a plain spawn went on; a box with no stackshot at all (no record file readable, no client) is not checked. When the registration was made and only the read-back could not be (a record that is not fresh), the message says the name IS registered and to run the same spawn again. The `pages.py` fallbacks are gone (version 49).
- **Credential (version 57)**: the registration (`post project-agent`, sender `sala-spawn`), the rename's calls and the retire's ask go with sala's own pass when sala has one (interface 37), the machine token otherwise; the gate's answers and exit codes are unchanged.
- **Test**: `tests/spawn.sh` (the spawn gate section), `tests/retire.sh` (retire asks first), `tests/rename.sh` (the read-back), each with a stub `client.py` and a private tmux socket.
- **Stable**: from version 48 (the name check read is live in stackshot since c554182a).

## 35. Sleeping sessions

- **Direction**: sala → stackshot (files the writer's machine keeps and the heartbeat publishes); the wake is stackshot's side running sala's CLI. Added in version 51.
- **Mechanism**: a session is put to sleep by `sala sleep` (`lib/sleep.sh`; a Claude session queues it with `sala op sleep --only NAME (--item board#N | --why "<reason>") --from YOU`): its claude is ended with `/exit`, its tmux session, its pane and its
  pane-map row stay, and its conversation is kept. It is asleep for exactly as long as its marker exists. The facts stackshot may read:
  - **The marker**: `$SALA_STATE_DIR/sleeping/<conversation uuid>` (`SALA_SLEEP_DIR` moves it; default `~/.local/state/salamander/sleeping/`). One line, `<ISO-Z time> <name>`: when it went to sleep, and the session's name (it follows a rename). The file name is the
    conversation uuid, the same id that keys `sessions.json`. The marker is written before the claude ends and taken off by the wake (`sala wake`), by a retire, and by a sleep that failed; sala writes and removes it, stackshot only reads it.
  - **`sessions.json`** (interface 1): a sleeping session has a row keyed by its conversation uuid, with `name`, `url`, `seen`, `machine` as every row and one more key, `"sleeping": "<ISO-Z>"` (the marker's time), present only while it sleeps. The row exists because
    the marker does: the heartbeat adds a sleeper's row on the box that holds it (a marker whose uuid is on no pane-map row of that box makes none). A woken session keeps its key (the same conversation) and its row loses `sleeping`.
  - **`session-registry.json`** (interface 19): the session's row keeps `"state": "live"` and carries `"sleeping": "<ISO-Z>"`, the same key and value. No other row has the key.
  - **`sala sessions --json`**: the same `"sleeping"` key on the row; the text listing shows `sleeping` in the STATE column.
  - **Wake**: `sala op wake --only NAME (--item board#N | --why "<one line, three words or more>") --from YOU` queues a wake (the queue runs `sala wake NAME` in its own unit: the marker comes off, then the conversation is resumed in its pane by its uuid, with its lane,
    model and effort). A NAME that is not asleep queues nothing and says so. The reason door admits a call made from a Claude session (the asker is placed by process ancestry; a plain shell or a daemon is not one, and passes `--words` instead, as every other queued verb does);
    **Server mode (version 54)**: on a box that is not stackshot's server, "a line waits for it" is `client.py get inbox-waiting NAME,UUID` (interface 3), not a read of the message folders; a call that gets no answer reads as *a line waits*, so `sleep_ready` refuses with "could not be asked" and the wake pass neither wakes nor counts a failed wake, and `sala sleep` is refused when its hold call gets no answer.
    **Wake on a message (version 52)**: sala's watch wakes a sleeping session when a message line waits for it (a line in the inbox's `hub/` or `msg/` folder that names the session or its conversation, held or not), so stackshot only writes the message, as it does today, and never runs a sala verb to wake a session. The watch runs `sala wake NAME` itself, at most 5 sleepers per run, one watch-log line per wake, and leaves the inbox files untouched: the line stays queued until the resumed pane takes it. A notice (`sala notice`) does not wake. This is always on, whether or not the idle sleep tick is (`SALA_IDLE_SLEEP`, off by default).
  - What a sleeper is not: not dead, not crashed, not "idle". It is asleep because sala ended its claude on purpose; nothing in sala relaunches, revives or counts it as missing while the marker stands (`no_relaunch` is true for it).
- **Owners**: sala `lib/common.sh` ("THE SLEEPING SESSIONS": `sleeping_mark`, `sleeping_clear`, `sleeping_list`, `is_sleeping`), `lib/sleep.sh`, `lib/wake.sh`, `lib/op.sh` (the verbs' door), `lib/heartbeat.sh` (the rows), `lib/sessions.py`
  (`row_sleeping_since`, `export_doc`, the listing). stackshot: nothing reads the key yet; the stage that treats a sleeper as present is stackshot's own (waking it on a message is sala's, in the Wake bullet).
- **Absent or changed**: without the marker directory nothing sleeps and no row carries the key (fail-open: every reader that does not know the key reads as before). A reader that counts sessions by the rows of `sessions.json` now counts a sleeper where it counted none.
  A change to the marker's path or line, the key's name or value, or the wake command's arguments bumps the version.
- **Test**: `tests/sleepshow.sh` (the key in `sala sessions --json`, `sessions.json` and `session-registry.json`, a non-sleeper unchanged, the text of this entry and the version), `tests/sleeping.sh`, `tests/sleepverbs.sh`, `tests/sleeptick.sh` (the watch's idle sleep tick and the wake on a message line).
- **Stable**: from version 51 (first release; stackshot does not read it yet); the wake on a message line from version 52.

## 36. Failed scheduled runs

- **Direction**: sala → stackshot (CLI, on the machine the job runs on; `client.py` is found as for interface 26: `SALA_STACKSHOT_CLIENT`, else `SALA_STACKSHOT_DIR/stackshot/fleet/client.py`, `~/stackshot/stackshot/fleet/client.py` when that is unset; the client holds the box's token, sala never reads it). Added in version 53.
- **Mechanism**: no polling, only systemd. Every job's service file has `OnFailure=sala-job-failed@%n.service` (starting `systemd/sala-job-failed@.service` for that unit) and `ExecStopPost=-%h/salamander/bin/salamander job alert ok %n`.
  - **A failed run** (any result but success): the template runs `sala job alert failed <unit>`, which writes the marker `$SALA_STATE_DIR/failed/<unit>` (one line, `<ISO-Z time><TAB><project>`) and runs ONE call:
    `client.py job-failed <unit> <host> <ISO-Z time of the failing run> <project>`. `<unit>` is the unit's name as systemd gives it (`nightly.service`), `<host>` the box's hostname, the time the unit's `ExecMainExitTimestamp` (else `StateChangeTimestamp`, else now) as `2026-11-23T01:58:38Z`,
    and `<project>` the unit's `X-Project=` as the Schedules tab shows it (`scope/project`, `SALA_UNIT_PROJECT_MAP` applied), or a single `-` for a unit with none or an invalid one (stackshot files that under the general builder). A job that fails again posts again: one call per failing run, so stackshot dedups by unit.
  - **A success**: `sala job alert ok <unit>` does nothing unless `$SERVICE_RESULT` is `success` and the marker exists (a green run with no marker posts nothing and starts no python). With the marker it runs `client.py job-ok <unit> <host> <ISO-Z time of the success>` and removes the marker.
    A `job-ok` that did not go keeps the marker, so the next success tries again.
  - The calls are positional only (four words after the verb for `job-failed`, three for `job-ok`), no options. The verbs are named once in sala, `CLIENT_VERBS` in `lib/jobalert.py`.
- **Owners**: sala `lib/jobalert.py` (`alert_failed`, `alert_ok`, `client_call`), `lib/job.sh`, `systemd/sala-job-failed@.service`, `lib/unitjob.py` (`add` writes the two lines), `sala job set-alert`. stackshot: `client.py` `job-failed` and `job-ok` (not built when this was written).
- **Absent or changed**: no `client.py` on the box (no marker is written, one log line), a `client.py` without the verbs, a refusal or a timeout: one line on stderr (the unit's journal) and exit 0, so a failed post never fails the job or the template unit. A refused `job-failed` still leaves its marker.
- **Test**: `tests/jobalert.sh` (a stub client.py that takes exactly the two shapes and refuses on demand; systemd played from the shipped unit lines).
- **Stable**: unstable until stackshot's side exists; the shapes above are the ones agreed with it.

## 37. A caller's own key

- **Direction**: sala → stackshot (HTTP, from the machine sala runs on). Added in version 57. stackshot can trust a caller by a key the caller makes and keeps instead of by the name of the machine it runs on; this is sala's side of that.
- **Mechanism**:
  - **The key.** `sala stackshot-key init` (`lib/stackshot-key.sh`, `lib/stackshot_key.py`; standard library plus the `cryptography` package) makes an Ed25519 key pair once. The private half is 32 raw bytes in base64url without
    padding in `${XDG_STATE_HOME:-~/.local/state}/salamander/stackshot-key/key` (folder 0700, file 0600), made with a private temporary file and a link so it is never overwritten, and never printed, logged, put in an argv,
    an environment variable or an error text. A key file other people can read is refused. The fingerprint is the SHA-256 (hex) of the 32 public bytes; sala shows its first 16 characters.
  - **Enroll.** `sala stackshot-key enroll` (init first) runs `POST /keys/enroll` with `{"public_key": <43 characters base64url>, "label": "sala", "sender": "sala"}` (`sender` `sala` covers the `sala-*` senders sala's calls carry). The answer is
    `state` `pending` or `approved`, the `fingerprint`, its `short` form and, while pending, the board `item` on which the owner approves it. The same key again answers its state and changes nothing. sala does this once per machine, never on its own.
  - **A claim.** A compact JWS: header `{"alg":"EdDSA"}`, payload `iss` (the full fingerprint), `aud` (the server address, no trailing slash: `STACKSHOT_URL`, else `<secrets>/client.url`, else `[client] url`), `iat`, `exp` (`iat` + 55 s) and
    `jti` (at least 32 characters, never reused), at most 2048 characters, signed over `<header>.<payload>`.
  - **A pass.** `POST /keys/pass` with `{"claim": <the JWS>}` answers `{"pass": "ssp_...", "expires_in": 600, ...}`. A 403 whose `state` is `pending` means the key waits for the owner; a 403 `unknown` means the server does not know or refuses it; a 401 is a fault in the claim.
    sala keeps the pass in `${XDG_RUNTIME_DIR:-/tmp}/salamander/stackshot-pass` (folder 0700, file 0600, written atomically, under a lock) and reuses it until 60 s before it ends, so one command that makes several form calls trades once.
  - **Where the pass goes.** `lib/stackshot_form.py run <client.py> <args...>` sets `STACKSHOT_CLIENT_PASS` for that one child (and removes any value it was given) and `exec`s `python3 <client.py> <args...>`: output and exit code are the client's own.
    The shell call sites use it: `agent_register` and `rename_side_run` (`post project-agent`), `rename_list_run` (`post project-agent-rename`), `_retire_call` (`post project-agent-retire`) in `lib/common.sh`, and the default of `SALA_BGAGENTS_POST_CMD` in `lib/bgagents.sh`
    (an explicit setting is used as written). sala's web app makes its own HTTP calls: `web/src/sala_web/formpass.py` asks `lib/stackshot_key.py form-pass` for the pass (the web app's environment has no `cryptography`) for `Stackshot.add_agent` (`projpick.py`),
    the For you list's two writes (`foryou.py`) and the color combos writes (`colors.py`); a 401 or 403 on such a call drops the cached pass and repeats the call once with the machine token. Reads, `post project` and `post project-list` keep the machine token.
  - **Settings.** `SALA_STACKSHOT_PASS=off` skips the pass step (the machine token, as before); `SALA_STACKSHOT_KEY_DIR` and `SALA_STACKSHOT_PASS_DIR` move the two folders; `SALA_STACKSHOT_PASS_BACKOFF` (default 30 s) is how long a failed trade is not tried again.
- **Owners**: sala `lib/stackshot_key.py`, `lib/stackshot_form.py`, `lib/stackshot-key.sh`, `lib/common.sh` (`SALA_FORM_PY`), `lib/bgagents.sh`, `web/src/sala_web/formpass.py`, `projpick.py`, `foryou.py`, `colors.py`. stackshot: `POST /keys/enroll`, `POST /keys/pass`, and the routes that accept a pass.
- **Absent or changed**: never blocking. No key, a key still pending, `cryptography` missing, a key file open to others, no server address, a server that is not reached, or one that answers 401, 403, 429 or 5xx: no pass is used and the call goes with the machine token, as before version 57; one line per five
  minutes in `$SALA_LOG_DIR/salamander-stackshot-key.log` (default `~/.claude`) says why, never a secret. A failed trade is not tried again for 30 s. A stackshot that does not know the routes answers 404 and sala goes on with the machine token.
- **Test**: `tests/stackshotkey.sh` (a stub server on 127.0.0.1 that checks the claim as above: init, enroll, the claim's fields, the cache, the wrapper byte for byte, every fallback, the verb, the call sites, and that no key or pass is in any output, argument list or log), `web/tests/test_formpass.py` (the web app's calls against a stand-in server and key script).
- **Stable**: unstable (first release); nothing depends on a pass yet, since every call falls back to the machine token.

## 38. Agent state

- **Direction**: sala → stackshot (a file the heartbeat writes on this box, then an HTTP post from this box; stackshot's board server runs elsewhere, has no ssh to this box and no notion of which machine an agent is on). Added in version 58. sala decides whether each registered agent is busy or idle and what its running subagents are; stackshot only reads.
- **Mechanism**:
  - **The file.** `$SALA_HEARTBEAT_STATE_DIR/<letter>/agent-state.json` (the live store of interface 1, the writer's own letter only; never in the store repo, since a subagent's brief is free text). Rewritten on EVERY heartbeat run (temp file, replace), `written` moving each time. Body, schema 1 (the keys of an entry are named once in the code, `ENTRY_KEYS` in `lib/agentstate.py`):
    `{"schema": 1, "written": <epoch s>, "agents": {"<agent name>": {"state": "busy|idle|unknown", "since": <epoch s>, "why": "<one line>", "pane": "turn|idle|shell|sleeping|unknown", "read": true|false, "subagents": [{"id", "description", "brief", "at": <epoch s>, "quiet": true?, "unreadable": true?, "meta_at": <epoch s>?}]}}}`
    A sample: `{"schema":1,"written":1795470000,"agents":{"demo-main":{"state":"busy","since":1795469700,"why":"in a turn; 1 subagent running","pane":"turn","read":true,"subagents":[{"id":"a1b2c3","description":"Build part D","brief":"Build part D of the plan ...","at":1795469990}]},"demo-docs":{"state":"idle","since":1795462000,"why":"no turn, no subagents","pane":"idle","read":true,"subagents":[]},"demo-lost":{"state":"unknown","since":1795469700,"why":"transcript not readable on this box","pane":"idle","read":false,"subagents":[]}}}`
  - **Who is an agent.** Every live row of this box's session registry (interface 19), a sleeping one too (interface 35); a retired row is none. The key is the row's `name`. Two live rows of one name are one entry, `unknown`.
  - **The pane.** From the CLI's own registry of live processes on this box (the row of an interactive pane whose conversation is the agent's, else whose name is): status `busy` is `turn`, `idle` is `idle`, `shell` is `shell` (the turn is over, a background task runs); a parked pane (its conversation moved into a background job) takes the job's status. A session asleep has no claude: `sleeping`. Any other status (a dialog open), no live pane and no marker, or a registry that cannot be read: `unknown`.
  - **The subagents.** Exactly the list stackshot's `running(session, roots, now)` returns (`stackshot/audit/subagent_tie.py`), `session` being the pane's own conversation (the registry's last conversation for a sleeper) and `roots` the transcript roots of this box (`SALA_AGENT_STATE_TRANSCRIPTS`, default `~/.claude/projects` and the second lane's `projects`). sala imports that module from stackshot's production checkout (`SALA_STACKSHOT_CHECKOUT`, default `SALA_STACKSHOT_DIR`, else `~/stackshot`), read only, writing no bytecode and running no git there, and never copies its rules. The redundant `text` key is dropped; `brief` is cut to its first 2048 bytes at a character boundary. For a pane not in a turn (idle, shell, sleeping) only the filter of stackshot's own audit is applied, copied from `_mover_subagents` (`service/audit_ticks.py`) with its source named in the code: a `quiet` entry is dropped, and so is an `unreadable` one whose `meta_at` is older than `RUNNING_S` (90 minutes); a pane in a turn keeps every entry. When `running()` raises `Unreadable` (or anything else) `read` is false and `subagents` is `[]`.
  - **The state.** `busy` when the pane is `turn` or any subagent applies; `idle` when the pane is idle, shell or sleeping, no subagent applies and `read` is true; `unknown` when `read` is false or the pane is `unknown`. `since` is when the state last changed: the previous file's `since` while the state is the same, else the pane's own status stamp when it changed after the previous file was written, else `written`.
  - **The size.** stackshot refuses a body over 1 MB. If the body would exceed `SALA_AGENT_STATE_MAX_BODY` (900000 bytes), `brief` fields are shortened longest first to 512 bytes and then, if it still does not fit, to none; no agent, state or subagent is dropped; one log line says so.
  - **The post.** After the file is written, in a heartbeat run that is not `--no-push` or `--dry-run`: `POST /client/agent-state` with the file's JSON as the body, the same Authorization as sala's other client calls. `SALA_AGENT_STATE_POST_CMD` is the command that gets the file's path as its last argument; the default is `env -u STACKSHOT_CLIENT_PASS python3 <client.py> post agent-state --file <path>`: the machine token, never a pass (not the call shape of `SALA_BGAGENTS_POST_CMD`: a pass of interface 37 opens only the New session form's calls, `project-agent`, `project-agent-rename` and `project-agent-retire`, and stackshot answers 403 to it on any other, `agent-state` included, so the command goes through no `lib/stackshot_form.py` and unsets any pass the heartbeat inherited), the client found through `SALA_STACKSHOT_CLIENT` / `SALA_STACKSHOT_DIR`; an empty setting or no client on the box posts nothing. The answer is `200 {"ok", "agents"}`; anything else (an exit status other than 0, an answer that is JSON with `ok` not true, a 400 for a body over 1 MB or a wrong schema, a 404) is a failure. The command is stopped (its process group) after `SALA_AGENT_STATE_TIMEOUT` (30 s).
  - **Settings.** `SALA_AGENT_STATE=off` skips the file and the post; `SALA_AGENT_STATE_POST_CMD`, `SALA_AGENT_STATE_TIMEOUT`, `SALA_STACKSHOT_CHECKOUT`, `SALA_AGENT_STATE_TRANSCRIPTS`, `SALA_AGENT_STATE_MAX_BODY`.
  - **What the reader does** (the staleness rule stackshot applies): a snapshot written more than 15 minutes ago (the heartbeat runs every 5), an agent with `read` false, an agent with state `unknown`, or an agent that is not in the file all read as unknown, never as idle.
- **Owners**: sala `lib/agentstate.py` (`build`, `applies`, `fit`, `post`, `publish`), `lib/heartbeat.sh` (the header entry, the settings, `publish_agent_state`). stackshot: the route `POST /client/agent-state` and its client verb `post agent-state --file` (being built when this was written), `audit/subagent_tie.py` `running()` and `Unreadable`, which sala imports.
- **Absent or changed**: `SALA_AGENT_STATE=off`: nothing is written or posted. stackshot's checkout missing, or its module failing to import: no new file (the last good one stays, its `written` ages into the reader's stale rule) and one line. A post that fails (an unknown verb of the client, a 404 while the route is not live, no network, a timeout): one line per five minutes in `$SALA_LOG_DIR/salamander-agent-state.log` (default `~/.claude`), the file still written, and the heartbeat neither fails nor waits longer than the timeout. A session registry that is off or unreadable (`SALA_SESSIONS=off`) writes no file.
- **Test**: `tests/agentstate.sh` (a stub stackshot checkout and a stub post command: every rule of the decision, `since`, the cut brief, the body limit, an import failure, the log and its five-minute limit, the timeout, the default command, off, never in the store repo's commit; and, where stackshot's checkout and virtualenv are on the machine, a parity section that runs the same fixtures through stackshot's `_mover_subagents` and fails on any difference).
- **Stable**: unstable (first release; stackshot's route is being built against this shape).

## 39. Machines

- **Direction**: sala → stackshot (a file the heartbeat writes on this box, then an HTTP post from this box; stackshot's board server runs elsewhere and reads none of the owner's machine files). Added in version 60. sala decides what the machine list is; stackshot only shows it.
- **Mechanism**:
  - **The file.** `$SALA_HEARTBEAT_STATE_DIR/<letter>/machines.json` (the live store of interface 1, the writer's own letter only; never in the store repo), beside `agent-state.json`. Rewritten on EVERY heartbeat run (temp file, replace), `written` moving each time. Body, schema 1:
    `{"schema": 1, "written": <epoch s>, "machines": [{"name", "hostname", "letter", "ssh", "addresses": [ipv4, ipv6] | [], "roles": ["sala-host"?, "stackshot-host"?], "retired": true|false, "sources": ["fleet-names.tsv"?, "candidates.conf"?, "fleet.conf"?, "machine-holds.toml"?, "machines.toml"?], "online": true|false|null, "last_seen": <epoch s>|null, "versions": {"<text>": "<text>"} (at most 16 entries), "checked": <epoch s>}], "not_read": ["<file name>"]}`
    The first eight keys of an entry are exactly what `machine_list()` returns, keys and order as `KEYS` in `lib/machines.py` names them (the one place); `not_read` is the files of that list's reader that were named and could not be read (`fleet-names.tsv`, `candidates.conf`, `fleet.conf`, `machine-holds.toml`, `machines.toml`), `[]` when all were. The last four keys (`READING_KEYS`, added in version 62, all optional: a receiver treats a missing key like null, and ignores keys it does not know) are what `read_with_readings` in `lib/machines.py` adds, in this order:
    - `online`: `true`, `false` or `null`. Whether the tailnet shows the machine connected at the reading. It comes from `tailscale status --json` run on the posting box (no ssh and no network of its own beyond the tailnet client): a peer's `Online`, matched to the row by the row's fleet name, hostname or ssh alias against the peer's `HostName` or the first label of its `DNSName` (case does not matter; never by address, as some rows have none); the posting box's own row is `true` (the tailnet's `Self`, whenever the reading worked). `null` means no reading: `tailscale` is missing, fails, takes over 10 s, or no peer matches the row. Nothing is guessed.
    - `last_seen`: epoch seconds of the last moment the tailnet knew the machine online (the peer's `LastSeen`), or `null`. It is `null` while the machine is online, when the tailnet never saw it and when `online` is `null`.
    - `versions`: an object of text to text, at most 16 entries, what sala read on the machine itself. Only the posting box's own row has any: `{"claude": "<the claude CLI version the heartbeat reads>", "sala": "<the short commit of the sala production checkout>"}` (a key whose value could not be read is left out). Every other row has `{}`. An empty `versions` means sala read nothing for that machine; it is never read over ssh.
    - `checked`: epoch seconds the row was read (the same second as `written` on a heartbeat's post). A row whose `checked` is older than the post's own time is stale; stackshot draws it as stale after 900 s.
    Absent or null means unknown, never "no" or "off". `checked` and `written` say when the list was read, so neither takes part in deciding whether the list changed. A sample: `{"schema":1,"written":1795470000,"machines":[{"name":"demo-a","hostname":"demo-a-os","letter":"a","ssh":"demo-a","addresses":["192.0.2.1","2001:db8::1"],"roles":["sala-host"],"retired":false,"sources":["fleet-names.tsv","candidates.conf","fleet.conf","machine-holds.toml"],"online":true,"last_seen":null,"versions":{"claude":"2.1.332","sala":"18dbc07"},"checked":1795470000},{"name":"demo-b","hostname":"demo-b-os","letter":"b","ssh":"","addresses":[],"roles":[],"retired":false,"sources":["fleet-names.tsv"],"online":false,"last_seen":1795466400,"versions":{},"checked":1795470000},{"name":"demo-d","hostname":"","letter":"d","ssh":"","addresses":[],"roles":[],"retired":true,"sources":["fleet-names.tsv"],"online":null,"last_seen":null,"versions":{},"checked":1795470000}],"not_read":["machines.toml"]}`
  - **The list.** Built from `lib/machines.py` (`read_with_readings`, which calls `read_list`, the reader `machine_list()` calls, and adds the four readings; the web Machines tab and `sala host` still use `machine_list()`, which runs no program); `lib/machinespost.py` holds no second reader. The files are read from where `SALA_FLEET_NAMES` and `SALA_MACHINE_FOLLOW_MACHINES` name them, as `sala machines` reads them. A box with neither setting writes and posts nothing. A list with no machine in it (no file could be read) is neither written nor posted, one line says so: it would blank stackshot's view, and the last good file stays.
  - **When it is posted.** After the file is written, in a heartbeat run that is not `--no-push` or `--dry-run`: when the machines (each row without its `checked`) or `not_read` differ from what stackshot was last given, at once (a machine going on or off the tailnet is such a change); when they do not, again after 10 minutes, so stackshot can show the list's age by `written`. The check allows a minute of slack (a heartbeat on its five-minute timer runs a few seconds off its beat and posts on every second run, never every third). The memory of the last good post (the list's fingerprint and the time) is `salamander-machines-post.json` in `$SALA_LOG_DIR` (default `~/.claude`), written only after a post that was answered cleanly; so a failed post is tried again on the next run. A body over `SALA_MACHINES_POST_MAX_BODY` (900000 bytes; stackshot refuses over 1 MB) is written and not posted, one log line says so.
  - **The post.** `POST /client/machines` with the file's JSON as the body, the same Authorization as sala's other client calls, by the mechanism of interface 38 (`post` in `lib/agentstate.py`). `SALA_MACHINES_POST_CMD` is the command that gets the file's path as its last argument; the default is `env -u STACKSHOT_CLIENT_PASS python3 <client.py> post machines --file <path>`: the machine token, never a pass (stackshot answers 403 to a pass on any call but the New session form's), the client found through `SALA_STACKSHOT_CLIENT` / `SALA_STACKSHOT_DIR`; an empty setting or no client on the box posts nothing. The answer is expected as `200 {"ok", "machines"}`; anything else (an exit status other than 0, an answer that is JSON with `ok` not true, a 400, a 404, an unknown verb of the client) is a failure. The command is stopped (its process group) after `SALA_MACHINES_POST_TIMEOUT` (30 s). No secret is in the file, the command line or the log.
  - **Settings.** `SALA_MACHINES_POST=off` skips the file and the post; `SALA_MACHINES_POST_CMD`, `SALA_MACHINES_POST_TIMEOUT`, `SALA_MACHINES_POST_MAX_BODY`.
  - **What stackshot builds.** The route `POST /client/machines` (the body above, stored as the last list, replacing the one before) and the client verb `post machines --file <path>` are stackshot's to build in a later stage; until they are live the post gets a 404 (or an unknown verb) and that is expected, not a fault.
- **Owners**: sala `lib/machinespost.py` (`build`, `fingerprint`, `due`, `publish`), `lib/machines.py` (`read_with_readings`, `add_readings`, `tailnet_status`, `read_list`, `machine_list`, `KEYS`, `READING_KEYS`), `lib/agentstate.py` (`post`, `note`, `write_atomic`, shared with interface 38), `lib/heartbeat.sh` (the header entry, the settings, `publish_machines`). stackshot: the route and the client verb, not built when this was written.
- **Absent or changed**: no `tailscale` on the box, or one that fails or takes over 10 s: every row's `online` and `last_seen` are `null` and the post goes as usual. `SALA_MACHINES_POST=off`: nothing is written or posted. A failure to build, write or post (no machine file readable, an unwritable store, a failing command, a 404 while the route is not live, a timeout): one line per five minutes in `$SALA_LOG_DIR/salamander-machines.log`, the heartbeat neither fails nor waits longer than the timeout, and the last good file stays where no new one could be written.
- **Test**: `tests/machinespost.sh` (a made-up fleet folder and a stub post command: the body's keys and shape against `machine_list()`, the atomic file, a changed list posted at once and an unchanged one not again inside 10 minutes but after, a failing or 404 command and a command that does not exist logged once per five minutes without failing the heartbeat, a slow one stopped, off, `--dry-run` and `--no-push`, an empty list not written or posted, a body over the limit, the default command and that no pass or secret reaches the command, the file or the log); `tests/machines.sh` (the four reading keys against a `tailscale` stand-in on the PATH: an online peer, an offline peer with its last seen time, a row no peer matches, no tailscale, a failing or hanging one, the posting box's row with its versions, the 16-entry cap, `sala machines --json`).
- **Stable**: unstable (first release; stackshot's route is not built yet). The four reading keys (version 62) are new and optional.

## 40. sala-web's Your move list

- **Direction**: sala's web app → stackshot (HTTP). Added in version 61.
- **Mechanism**: `GET <url>/client/your-move`, header `Authorization: Bearer <token>`, `User-Agent: sala-web`, 3 s timeout, no key and no query. Token and address as interface 10 reads them (`$XDG_CONFIG_HOME/stackshot/client.token`, `client.url`, `STACKSHOT_URL` first). Answer: `{"items": [{"shown", "subject", "url", "ask", "updated"}]}`: every open item the owner moves now, the group the board home page draws under Your move, with no cap, in the page's own order (the owner's longest wait first; not newest first). `shown` is the id as a person reads it, `url` the item's page, `ask` the open ask line or `""`, `updated` epoch seconds. An empty group is `{"items": []}`. sala-web keeps `shown` (as `id`), `subject` and `url`, in the order sent, each id once, and passes none of the others on (the strip shows nothing else). The chat page's Waiting on you strip is that list, with no re-sort and no cap; an empty list is an empty strip. The answer also carries `"group": {"en", "ko"}` (added in version 63), the group's own name: the instance's English text and its Korean catalog label, `ko` equal to `en` when it has no Korean catalog. sala-web takes it only when it is a dict with a string `en` and a string `ko`, each 1 to 40 characters once stripped, with no control character and no markup, and passes it to the page as `group` of `GET /api/chat` (null otherwise); the strip's words and the drawer chip use it, and sala's own words stand only when there is none (a Korean page with `ko` equal to `en` uses sala's own Korean).
- **Cache**: read in the background at most once per 30 s however many pages poll (a page view never makes a request of its own); the last good list is kept under `state_dir/your-move.json` as text (id, subject, url; never the token) so a restart has it. A failed read keeps the last good list for 10 minutes and says nothing is wrong; with no good list younger than that (never read yet, or the reads have failed for longer), the strip falls back to the board feed of interface 10, so it is never emptier than before this read.
- **Owners**: sala `web/src/sala_web/yourmove.py` (whole file), `chatpage.py` (`waiting`), `app.py` (`api_chat`). stackshot `docs/client-contract.md`, *The owner's whole Your move group*.
- **Absent or changed**: no token file, a 401, an unreachable server, a non-JSON answer or an answer without an `items` list: the cached list while it is under 10 minutes old, else the board feed. A stackshot that predates the route answers 404 and the strip stays on the feed; one that predates `group`, or sends a bad one, leaves the strip's words as sala's own. The rest of sala-web is unaffected. Fail-open.
- **Test**: `web/tests/test_yourmove.py` (the parse, the cache and its bounds, the read against a stand-in on a real socket, `GET /api/chat` end to end), `web/tests/test_chatpage.py` (`waiting`); `conftest.py` points token and URL at missing files so no test reaches the board.
- **Stable**: yes (the route is live).

## 41. sala-web's On it list (retired in version 65)

- **Retired**: until version 65 sala-web read `GET <url>/client/involved?key=<the chat session's configured name>` for the second tab of the chat page's pinned strip. The read, its cache file
  (`state_dir/involved.json`, which may be left on a machine and is read by nothing), `web/src/sala_web/involved.py` and the `onIt` key of `GET /api/chat` are removed.
- **Now**: the tab lists the chat session's own `sala motion` lines (`web/README.md`, *The chat session*). sala calls nothing of stackshot's for it; the route is stackshot's to keep or drop.
- **Test**: none (the read went with it).
- **Stable**: retired.

## Not an interface, but a name

Places that name stackshot without coupling to it (no bump when they change): `lib/reauth.sh` (the connector display name
"Stackshot" as an example), `mod/hooks/register.ts:91` (a comment; `lib/cue.sh:16` held another until the cue was retired), `web/README.md` (prose),
`docs/test-coverage.md`, `config.example` comments, and the `web/tests` fixtures that carry board
URLs on placeholder hosts (`board.example.test` and the like) as sample text.
