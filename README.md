# salamander

**The operator for Claude Code across your machines — and sessions that never die.**

Two layers:

- **Fleet** — every machine: which Claude Code version each box runs (`update HOST…`, `update --fleet`), which
  sessions live where and who the master is (`heartbeat`, `master`), handing operator cues to the master (`cue`),
  and starting `/provision` on another box (`provision HOST…`). The other boxes need only ssh: the
  heartbeat sweeps them from the driving box.
- **Sessions** — the box that hosts them: named, long-lived Claude Code sessions in tmux, resumed by transcript
  UUID (never `--continue`), reachable from Remote Control, kept alive through reboots and CLI updates (`spawn`,
  `revive`, `recycle`, `watch`, `retire`, `close-shell`, `forget-row`, `rename`, `follow`, `unpark`, `ready`, `rc`, `snapshot`, `feedback`, `map`).

Out of scope on purpose: what a machine should look like. That is configuration management — a spec and the
agent that applies it (`/provision`); salamander only starts it on another box and runs the recycle it ends with.

Built for a headless server that runs many Claude Code sessions at once, each a standing conversation
about one project, driven from claude.ai on another machine. The failure modes that shaped it are in
[Design notes](#design-notes).

```
salamander spawn  demo-docs --mandate ~/mandates/docs.md # named session, mandate read on start (--brief is its older name)
salamander spawn  demo-docs-main --project projects/demo-docs --role front --mandate ~/mandates/docs.md
                                                       # a project agent: the name on the page's agents map first
salamander spawn                                       # throwaway: scratch-20260101-oak
salamander spawn  --list                               # every session, version, claude.ai URL
salamander revive                                      # after a reboot or `claude update`
salamander revive --self                               # …and the one you are typing this in
salamander rc     --status                             # the Remote Control server + what it serves
salamander spawn  notes --fork <uuid>               # elevate a phone-minted session into a pane
salamander map                                         # sidebar label ↔ real name ↔ tmux
```

## Install
Step-by-step guides: [docs/sala-guide.md](docs/sala-guide.md) (for a person) and [docs/sala-guide-for-ai.md](docs/sala-guide-for-ai.md) (for an AI assistant doing the install).
```
git clone https://github.com/howardpark-ai/salamander ~/salamander && ~/salamander/install.sh
```
Needs bash >= 4.4 (`bin/salamander` refuses to run on an older one; macOS ships 3.2: `brew install bash`), `tmux`, `python3` 3.11 or newer (the merge queue and machine-follow read TOML with `tomllib`; the web UI needs 3.12, which `uv` fetches), `claude` on PATH, and `gh` signed in (`gh auth login`) for the CI-run poller and `sala mq`. Linux (reads `/proc`; macOS is untested, and support is a TODO).
Config: `~/.config/salamander/config` ([all keys](config.example)).
The web UI (`web/README.md`) is optional: `~/salamander/install.sh --web` copies its three systemd user units (the app, its socket and
ttyd for the Terminal tab) and prints the commands that start them. The web UI has no login of its own, so put HTTPS and a login in
front of it before it is reachable from anywhere else: [docs/web-proxy.md](docs/web-proxy.md). Then, if you use
[tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) (recommended — it is what brings the panes
back after a reboot):
```
set -g @resurrect-hook-post-save-all    'salamander revive --save-map'
set -g @resurrect-hook-post-restore-all 'salamander revive'
set-hook -g session-created 'run-shell -b "salamander snapshot"'
set-hook -g session-closed  'run-shell -b "salamander snapshot"'
set-hook -g session-renamed 'run-shell -b "salamander snapshot"'
```
Keep `claude` **out** of `@resurrect-processes`: resurrect would restart it with `--continue`, and every pane
sharing a cwd would grab the same conversation.

## Subcommands
| | |
|---|---|
| `spawn [NAME] [--mandate F\|T [--no-confirm]] [--cwd D] [--lane L] [--model M] [--effort E] [--fork UUID] [--dry-run]` | new tmux session running `claude`, named with `/rename`, verified in the registry. **The mandate** (Thu Oct 15th 2026): a readable file is read by the session itself — the orientation line `Read <absolute path> in full — that is your mandate for this session …` is typed and the session waits for a confirmation unless `--no-confirm`; anything else is text typed as the first message. `--brief F` (a file only) and `--prompt T` (text only) are its older names, kept as aliases. The orientation line and a text are typed with `<!-- sala -->` in front, as every message sala types is (see Design notes). `--lane L` launches on that lane and records the row (`sala lane` would otherwise); `--dry-run` runs every check and prints the plan, makes nothing; `--fork` elevates an existing conversation into its own transcript. **A throwaway's spawner** (Thu Oct 29th 2026): a bare spawn (no `--project`, `--role`, `--side` or `--master`) run by a Claude session writes that session's tmux name onto the new registry row as `spawned_by` (unpublished, like the `side*` fields; `docs/session-registry.md`); that is what lets the same session end the throwaway with `sala op retire NAME --from YOU` and no words. A spawn from a plain shell or a human's pane records none. **The throwaway tag** (Fri Oct 30th 2026): the same bare spawn, from any caller, also writes `throwaway` = `1` onto the row (unpublished); a spawn with a project, role or side flag never does, and a later `sessions set`/`sessions tag` that gives the row a project, role or side mark clears it. Any live session may then retire a tagged row with no words (see `retire`) |
| `spawn NAME --project <page key> --role front\|back [--mandate F\|T] [--lane L] …` | **a project agent's session** (`lib/spawn.sh`, the one path `sala op spawn` and the web form take). A project agent is registered by its line on its hub page's `agents:` map — a front agent (the ones the owner talks to) a top-level entry, a background one under `background:`. Before the tmux session is made, never fail-open: the name (lowercase letters, digits and dashes, at most `SALA_AGENT_NAME_MAX` = 48 characters; a suggestion, not a check: `--suggest-name` prints `<prefix>-main` only for a front agent of a project that has no agent yet (a fresh stackshot record lists it with none, or `--new` says the project has no page yet), else `<prefix>-<random word>` (a word picked at random from sala's list, not in a fixed order), and never a name that is taken (a tmux session, a running claude, an agent on any project's map in stackshot's record); a missing, stale or silent record is no ground for `-main`, so it answers a word; a real spawn with no NAME keeps the older rule, a front is `<prefix>-main`; the prefix is the project's real one from that record, its `-main` agent's name without `-main` (`demo-docs` for projects/demo-docs), else the page-name convention (`<scope>-<slug>`); `--prefix P` sets it for a caller that knows it (the web form does)), the page exists (`pages.py resolve`; missing → exit 4 and `NO-PAGE: <key>` on stdout — a session with the knowledge base makes the page, nothing in sala writes to it), the name is on THAT project's map — read from stackshot's project record first (`~/.local/state/stackshot/projects.json`, `SALA_PROJECT_RECORD`, no older than `SALA_PROJECT_RECORD_MAX_AGE` = 600 s: name listed, `front` agreeing with `--role` or the spawn is refused with exit 1; an agent registered through stackshot's `post project-agent` whose page line is still owed counts as listed), then, only when the record cannot answer (missing, stale, unreadable, no such project), `pages.py resolve` / `agent-listed` (its `listed on <key>:` line); not listed → exit 3, the refusal on stderr and, on stdout, `ADD-TO-PAGE: <key>` followed by the exact YAML to add, the mandate's first line cut to 70 characters; the page's keeper is asked once by one stackshot message to the page key, `SALA_SPAWN_ASK_CMD`, not again within `SALA_SPAWN_ASK_EVERY`, and never when `SALA_SPAWN_REGISTER` is configured), a "cannot tell" (no usable record and no pages.py or brain here) refuses with exit 1; a back agent needs a mandate and starts on it (nobody confirms a background agent), in the directory `SALA_BACK_CWD` names when `--cwd` is not given (unset by default, so `$HOME`; set it to the directory whose `CLAUDE.md` is the background brief, so the agent loads that brief and not the front rules of `$HOME`). A `SALA_BACK_CWD` this machine does not have refuses the spawn (unset is the only way to start in `$HOME`; `--cwd` always wins), and the pane map's cwd column records the directory it started in, so `sala restore` recreates the session there; a name already live is refused as for any spawn. Once the session is up and mapped, `SALA_SPAWN_REGISTER` (unset by default: a no-op that logs `spawn-register: no hook configured`; the page's line is the registration) runs with the name, page key, role and mandate file as arguments and `SALA_SPAWN_*` in its environment; a hook that fails is one ⚠ line, never the exit status. A plain spawn (no `--project`) keeps the older fail-open check (`agent_unlisted`) |
| `spawn NAME --side (--fork-of AGENT \| --project <page key> --item ID) [--agents A,B] [--mandate F\|T] …` · `spawn --suggest-name --side …` | **a side conversation** (called a Quick session on the web page; [docs/side-sessions.md](docs/side-sessions.md)): a short-lived session started in one step to talk something over, on no page's agents map and with no role. Two starts: a **fork** of a running agent's conversation (`--fork-of`, named `<agent>-side-<word><nn>`, its summary to the agent), or a **fresh** session about a board item scoped to its project page (`--project` + `--item`, `--agents` the item's involved agents, named from the project's main agent, its summary to that agent). Its mandate file says to read the page's Current state and the item, to read only the transcript excerpts it needs from the involved agents (`sessions transcript`), to run `side done` before it ends, and to retire only on the owner's word. No quiet watch, no auto-retire, no cap. Through the queue: `sala op spawn NAME --side …` (checked at queue time, planned with `--dry-run`). |
| `side done [--name NAME] [--item ID] [--item-updated EPOCH\|ISO] [--summary F\|T\|-] [--summary-to NAME\|projects/SLUG] [--dry-run]` | **the write-up gate of a side session**, run by the session itself: writes `$SALA_STATE_DIR/side/<name>.done` only when the board item changed since it started, the project page has a timeline line from it, and the summary was sent (sala sends it itself, once, `[for <owner>]` to a `-main`, and to another front agent only when stackshot refuses the message without it). Every failed check is said. `retire` of a side session is refused until the marker is there (the queue's plan too); `--skip-writeup` is the only bypass. [docs/side-sessions.md](docs/side-sessions.md) |
| `spawn --list` | live sessions (name, version, claude.ai URL) + tmux sessions whose claude has exited, with the resume hint |
| `revive [--dry-run] [--force] [--only NAME] [--lane-default] [--rescue]` | resume dead panes; `/exit` + resume stale-binary panes when idle; restart the RC server on a version change. Every pane's plan says `lane: <the lane its claude runs on now> → <the lane the resume line puts it on>`; a pane with no lane row whose claude runs on another lane than the default is refused (that pane only, in the skipped rows and the recycle's post) with the fix — `salamander lane <lane> <session>` records it, `--lane-default` accepts the default; a row wins as the recorded intent (see *Lanes*). `--dry-run` prints the verdicts and relaunches, schedules and writes nothing. `--rescue` (with `--only`, never a recycle): a stale background-task row no longer holds the pane — the CLI's exit dialog, the Stop hook's record and the mod all list a shell stopped by hand or a subagent long gone; when no child process runs under the pane's claude, the dialog is confirmed ("Exit and stop tasks") and the record and the mod's refusal are read as stale, each said in the output; a live child keeps every refusal (see *The rescue* under *Lanes*) |
| `revive --save-map` | observe the pane map against the live registry (wire to resurrect's post-save hook): a mapped session whose live claude runs a different conversation than its row has the row follow; nothing is added or dropped — the map is a ledger (see *Design notes*) |
| `recycle [--update] [--force] [--lane-default] [--dry-run]` | `--update` runs `claude update` first (a live process keeps the binary it launched with, so updating and relaunching are one operation); then one detached driver: sweeps every other pane now, relaunches the pane you ran it from once it goes idle; `--force` relaunches every idle pane, not only stale-binary ones (a relaunch is also how a pane re-reads `CLAUDE.md`, skills and settings). `--dry-run` is a dry-run driver: the sweep's verdicts and the self-worker's plan for your pane in the log, and nothing else — no `claude update`, no freeze of the pane map, no relaunch, no set, no post. Panes skipped for a transient reason (a turn running, idle < 10 s, a background child or agent, an unsubmitted draft) are retried by a detached worker every `SALA_RETRY_EVERY` s for `SALA_RETRY_WINDOW` s with the same gates. A pane that said `sala ready` but is held only by background shells (registry state `shell`) goes on the deferred list at once, and a pane still pending when the window ends is deferred too, not given up: both stay outstanding in the recycle's set, the report names each as deferred with its reason, and `watch` relaunches them once they are free (only the 8-day drop of the deferred list gives one up). A pane that stays on that list is not left silent: `watch` tells it again an hour after it was set aside (`SALA_LATER_RETELL`; the recycle's line, through the waiting flag and pushed into the idle session), at most `SALA_LATER_RETELL_MAX` (3) times, and once it has been held `SALA_LATER_LIMIT` s (default 3 h) posts once to the usual notify path with the pane, claude's and sala's versions, how long, and the commands holding it; a pane that relaunches leaves the list and clears all of it. A pane given up for good (its pane gone) or one that needs a human (a terminal prompt, an unmappable pane) is reported, not retried. The sweep runs in three phases: every pane's gates checked in parallel, the eligible panes closed (`/exit`) in parallel (first the stackshot inbox of every eligible pane is held, the sweep waits `SALA_HOLD_SETTLE` s, default 3, for a line stackshot handed out just before the hold to become a turn, and each pane is checked once more just before its `/exit`: a pane that is busy by then is left alone and retried, never exited over its turn), then the resumes typed one by one, least-recently-active first, `SALA_RESUME_GAP` s apart (default 1; at most `SALA_SWEEP_JOBS` parallel jobs, default 12) — the log carries a timing line per phase |
| `revive --map-history` | older pane→conversation maps and the bindings each had that the current one lacks |
| `recycle --when-idle [--from NAME] [--change REF] "<reason>"` | any session (no master needed): ask for a recycle; `watch` cues it at its next run and each busy pane is relaunched once it is idle. It only records the request (a marker under `~/.local/state/salamander/recycle-requests`: the time, who, why); `watch` runs the recycle. `--list` shows the open requests, `--cancel [ID]` drops one or all; a request expires after 24 h. `--change REF` names the change the request is for (a commit sha, or `pr<N>`; `<repo>:REF` for a repository listed in `SALA_RECYCLE_REF_REPOS`): `watch` serves the request only once that change is in the production checkout's HEAD (merged and deployed), so no recycle runs before the code it is for is live; see *Two guards* below |
| `revive --self [--dry-run] [--rescue]` | the invoker-only half of `recycle`: a detached self-worker relaunches the pane you run it in once it is idle — the one way to relaunch your own pane (a sweep never relaunches the pane it runs in: `revive --force --only <own session>` says so and points here). Refused like any pane when its lane line is a mismatch with no row. `--dry-run` prints what the self-worker would do and starts none; the worker waits up to `SALA_SELF_WAIT` s (default 900) for the pane to go idle, holds its stackshot inbox, waits `SALA_HOLD_SETTLE` s and looks again (a pane busy then is released and handed to the retry worker), and the waits stack to at most three times `SALA_SELF_WAIT`; `--rescue` reaches the self-worker (a stale task row of your own pane) |
| `rc [--ensure\|--start\|--status\|--restart\|--stop]` | the `claude remote-control` server loop in its own tmux session |
| `rc --archive ID…` / `--unarchive ID…` | archive (or restore) claude.ai sessions by web id, the unofficial endpoint the CLI itself uses; archive is refused for a session a live pane is bridged to — archiving one drops that pane's Remote Control bridge, and `--unarchive` restores the record but not the bridge (type `/remote-control` in the pane) |
| `update [HOST… \| --fleet] [--check]` | CLI update: here it is `recycle --update --force`; `HOST…` runs `claude update` over ssh on just those `SALA_FLEET_HOSTS` names (this machine only if named); `--fleet` does every host and then this machine, reporting updated / already current / offline-skipped / failed; `--check` changes nothing. Remote sessions keep their old binary until restarted by hand; package managers are never touched |
| `provision [--check] [HOST…]` | headless `/provision` on each other machine over ssh (`claude --dangerously-skip-permissions -p "/provision"`), one at a time; offline hosts skipped; per-host log. It lives in sala so that one permission rule for `sala` pre-approves it for every host — see *Permissions*. A run that leaves session/owner items on a box makes a provision set, and the master is told about them in its inbox. **With no master configured** (`SALA_MASTER` unset), `SALA_PSET_TARGET` (config, a session name, unset by default) takes that same text in its inbox instead, `[for <owner>]` on its first line so a front agent's pane takes it; a configured master always wins, even one that is briefly down (its items stay pending and `watch` tries again; the target is never told). A target that is not live or whose push fails changes nothing: the items go to Slack as one post (`sala provision --sets` lists them) and count as told |
| `retire NAME\|--id ID [--keep-web] [--busy] [--skip-writeup] [--self] [--leave-items] [--dry-run]` | end a Claude session for good (a tmux session with no Claude in it is `close-shell`, a leftover pane-map row is `forget-row`): `/exit`, kill the tmux session, drop its pane-map row (the only path that does), snapshot, archive its claude.ai session. Without this a session that exits **comes back** at the next revive — that is revive's job. The transcript survives (`claude --resume <uuid>`). `NAME` is the **exact** tmux session name, never a registry name or a prefix of one: a name that is no tmux session is refused (with a pane-map row it names `sala forget-row NAME`, without one it says to use `--id`), and a tmux session with no claude in it is refused naming `sala close-shell NAME`. `--id ID` (a full conversation uuid or an 8+-character prefix of it; not together with NAME) is the other way in: the CLI's session registry (`~/.claude/sessions/`) resolves it to the tmux session and pane, and the choice is said before anything is done (id → registry row → tmux session, pane). Two live rows answering to the id, a prefix on several, or a resolved tmux session that holds another live claude stop it with the candidates listed and nothing touched (retire guesses none); a row whose process is gone, that records no tmux pane, or whose pane is another server's is said and not acted on. **Guardrails**, each with its own flag (the old `--force` did two unrelated things and is refused with a sentence naming both): `--busy` retires a pane that is not idle; `--skip-writeup` retires a side session before `sala side done`; `--self` lets a session retire the one the call runs in (found by process ancestry, never `TMUX_PANE` alone; no /exit is typed into its own pane, the output goes to `~/.claude/salamander-retire.log` and the call ignores HUP and PIPE while its pane closes), refused without it, and when the session is mid-turn (the call is part of that turn) its own running turn is not counted as busy: a dialog, a background shell or a child process still is and needs `--busy`. The queue is the usual way in, `sala op retire NAME --self --from NAME --words "…"`: refused at queue time without `--self` when the call runs in NAME's own pane, and for `--id`, which names its session only when the op runs, refused at run time when the session found is the one that queued it (the op's own record, `SALA_OP_FROM`; the runner is not in the pane's process tree); with `--self` the runner, started while that session's turn still runs, waits up to `SALA_RETIRE_SELF_WAIT` (300 s) for the turn to end and then applies the usual idle check; `--leave-items` retires a session that is the mover of an open board item: without it stackshot is asked (by tmux name, then conversation id) and the retire is refused with the item ids, and when stackshot cannot be asked it is refused with the reason (`SALA_RETIRE_ITEMS_CMD` replaces the command, `SALA_RETIRE_ITEMS_TIMEOUT` the 30 s limit). The items check runs under `--dry-run` too. `--dry-run` types, kills, writes, snapshots and archives nothing and names each action it would take (the pane, the pane-map, lane and model rows, the snapshot, the claude.ai session) or the refusal it would give. Once a retire has succeeded, sala tells stackshot to take the session off its project (`project-agent-retire`, `timeout 90`): stackshot removes the agent's line from the project page's `agents:` map itself, with a timeline line on the page (or drops a pending entry), and sala says which in one "ℹ" line; a page write that failed (502) is said as its own line with the reason, the command to ask again if the line is still on the page, and a hint to add the timeline line by hand if only that was not written; a 422 or 409 is said as "stackshot refused (status): reason"; the retire is done either way. The project is the registry row's, else a side record's, else the one stackshot's roles list gives the name (`client.py get roles`, else `~/.local/state/stackshot/roles.json`), which covers rows `migrate` imported without one; with none known nothing is asked and `~/.claude/salamander-retire.log` says so, with the source of the project otherwise. Through the queue (`sala op retire`) it takes the owner's words, with **one exception** (Thu Oct 29th 2026): `sala op retire NAME --from YOU` with no `--words` is queued when NAME is a throwaway — a live registry row of exactly that name with no project, no role and no side flag, on no project's agents map, and neither the master nor YOU — and YOU may end it. **A row carrying the throwaway tag** (`throwaway` = `1`, written at spawn by a bare `sala spawn`, Fri Oct 30th 2026) may be ended by any live session, whatever its name and whether or not its spawner is live; "between turns" is retire's own idle check (`is_idle_reason`, the registry's busy record), met twice because a no-words retire never carries `--busy`: the plan (`retire NAME --dry-run`) refuses a target mid-turn before anything is queued ("is not idle"), and the runner's `retire` refuses one that became busy since (stuck, nothing ended); the asker queues it again once the target is idle. A tag never overrides a project, a role, a side mark, the master, an agents-map entry or the asking session itself. **A row with no tag** (made before the tag) keeps the older rules: NAME's spawner (`spawned_by` = YOU); the master, when NAME is a throwaway's name (`scratch-*`, `*-check-*`, `*-test-*`, `*-probe-*`) or the master started it; or any session when NAME has no live spawner (none on its row, or that session is gone or renamed) and a throwaway's name (widened Fri Oct 30th 2026, so that retiring a throwaway never needs the owner). The agents-map check **fails closed** for the master and any-session doors: the project record (fresh within `SALA_PROJECT_RECORD_MAX_AGE`), else `pages.py agent-listed`, must say NAME is on no agents map, and with no answer the retire is refused (the spawner door goes on without one: its row is the proof). **No bypass flag (`--busy`, `--skip-writeup`, `--self`, `--leave-items`), no `--keep-web` and no `--id` is taken with no words**, at queue time or by the runner: add `--words` or drop the flag. The caller is placed by its **process ancestry**, never by `TMUX_PANE` or `--from` (any caller can set both): the tmux session whose pane holds the call, with a Claude Code process on the way up (`ancestry_session`, `lib/common.sh`: comm `claude` and an exe under the account's `~/.local/share/claude/versions/`, never the name alone), must be YOU, so a call from a plain shell, a detached or orphaned job, a person's pane with no claude above it, or a symlink to bash named claude is refused (a human passes `--words`). The target is bound to the row by its process too: every process in every pane of the tmux session called NAME must carry the row's id as `SALA_SESSION_ID` (or none does and one is a Claude Code process: a pane from before row ids, bound by its name alone, so it passes only when NAME is a throwaway's name and a fresh project record or `pages.py` answer says NAME is on no agents map, whichever door let YOU in), so a session renamed to a dead throwaway's name is refused. The queue's runner checks the target again, against the row id stored in the marker, before it ends anything: a session replaced since the op was queued goes stuck with nothing ended, and that stuck state never starts the `claude -p` helper (it could run `salamander retire` with none of these checks); a process of the target that exits between the listing and the read is skipped. The marker, the log, the Slack post and the session's line then say `words: none (throwaway, retired by its spawner)`, `… retired by the master)`, `words: none (throwaway tag set at spawn, retired by any session)` or `words: none (throwaway with no tag, retired by any session: no live spawner)`, by the door that let it in. Every other retire without words is refused, and the refusal says why |
| `close-shell NAME [--busy] [--dry-run]` | end a tmux session that has **no Claude session** in it (a plain shell): kill it, drop its pane-map, lane and model rows, take the snapshot. `NAME` is the exact tmux session name. Refused, naming the right verb, for a session with a Claude pane (`sala retire`), a name with no tmux session but a pane-map row (`sala forget-row`), the RC session, the master (a plain call; through the queue it unsets `SALA_MASTER` first), the session the call runs in, and a shell with a running child process unless `--busy` (the child is named). `--dry-run` says each action it would take or the refusal it would give and changes nothing. Through the queue (`sala op close-shell NAME [--busy] --from YOU --words …`) it takes the owner's words, always |
| `forget-row NAME [--dry-run]` | drop the pane-map row (and the lane and model rows) of a session whose tmux session no longer exists, which nothing else cleans up: nothing is killed and nothing typed. `NAME` is the exact name. Refused when a tmux session of that name is live (naming `sala retire` or `sala close-shell`), for the RC session, the master, and a name with no row. `--dry-run` as for the others. Through the queue (`sala op forget-row NAME --from YOU --words …`) it takes the owner's words, always |
| `adopt NAME` | put a live tmux session that was made by hand (outside `spawn`) into the pane map: its claude's conversation, name and cwd become the row. Until then `watch` reports it once (a reboot or recycle could not bring it back) and never adds it on its own. Master only when a Claude session calls it, like `rename` and `retire` |
| `sessions [--all] [--json]` · `sessions --check [--dry-run]` · `sessions --migrate [--dry-run]` · `sessions record <id\|name> --transcript T --why clear\|resume\|start` · `sessions transcript <name> [--json]` (read-only: where a session's conversations are on disk) · `sessions tag <id\|name> [--project P] [--role front\|back] [--project-key P] [--dry-run]` · `sessions resolve <ref> [--live] [--json]` | **the session registry** (phases 1 to 3; [docs/session-registry.md](docs/session-registry.md)): `sessions.json` beside the pane map, one row per session with an id of its own that survives a rename and a retire; dual-written after the pane-map write and read by nothing yet. The listing is read-only; `--check` repairs the registry after a kill between the two writes; `--migrate` makes the rows of the current pane map once (`--dry-run` first); `record` (phase 2) appends a fresh conversation to a row once, fed by `spawn` (which makes the row first and exports its id as `SALA_SESSION_ID`), `unpark` and the SessionStart hook. `tag` fills `project` and `role` of an existing live row (which only `spawn --project --role` set before), so `resolve role:<project>/<role>` finds it; `resolve` (phase 3, read-only) names the one row a session id (or 8+ character prefix), transcript id, name, alias or `role:<project>/<role>` points to: exit 0 found, 1 none, 2 ambiguous (every candidate listed, nothing picked; `--live` drops retired rows). The heartbeat also publishes the registry as `session-registry.json` in the fleet live store (below, `heartbeat`). `SALA_SESSIONS=off` stops the writes and the publish |
| `restore NAME… \| --missing` | recreate a session from its pane-map row: the tmux session detached at a shell in the row's cwd, then `revive --only NAME` resumes its conversation by uuid (dedupe guard, effort re-pass). `--missing` does it for every row whose tmux session is gone — after an unclean boot, say. Refuses a name the map does not know, a session that exists (`revive --only` is for that) and a conversation that is live elsewhere. The end of a recycle sweep and the reboot's boot half do the same on their own (below). Master only when a Claude session calls it |
| `rename OLD NEW [--dry-run]` | rename a live pane end to end (master only): `/rename` typed and verified, the tmux session and the revive map renamed, `SALA_MASTER` moved when it was the master, open notes relabelled, then an immediate heartbeat whose row carries `previous_name` + `renamed_at` (the hand-off to the board). Refuses a name that is already live; a busy pane is retried in the background for 2 h, while a pane whose status cannot be read counts as unknown, not busy, and goes ahead like an idle one. A session the pane map has no row for is refused (exit 4), except a spawn still landing its registry entry or row, and for a side spawn its side record (a spawn operation in flight, or a tmux session under `SALA_RENAME_YOUNG` = 120 s old), which is waited for, one budget for the whole wait, up to `SALA_RENAME_MAP_WAIT` = 60 s (0 = no wait; `--sync` never waits). A NEW its project's page does not list is handled by the rename itself: stackshot renames OLD's entry on the page in place through `client.py post project-agent-rename <project> OLD NEW --sender sala-rename` (the entry keeps its line, place and front or background side; `SALA_RENAME_SENDER` overrides the label). Its answer `renamed` goes on; `already renamed` goes on only for a rename sala itself started earlier (sala keeps a 3-day record, `rename-listed.tsv`, of the ones it started or could not tell the outcome of); any refusal (NEW already listed, OLD not listed, not the form's label or machine, a name without the project's prefix, stackshot not reached) stops the rename with stackshot's reason and nothing renamed. A side session (it has a record under `side/`; it is on no page, so there is no entry to rename) renamed to an agent name its project does not list is listed as a new front agent through `client.py post project-agent <project> NEW --role <NEW's part after the project's name> --front --mandate <one line> --sender sala-web` (a pending entry in stackshot's project record; the page's own line stays its keeper's; `SALA_RENAME_LIST_SENDER` overrides the label) before `/rename` is typed, then its side record ends (moved to `side/retired/`, the row's side fields cleared, the row tagged project / front) and the write-up is no longer owed; the project is the record's, else its origin agent's, and with neither the rename is refused in its plan (`--dry-run`, `sala op --plan`). Run directly inside OLD's own pane (a hand run) nothing is typed, since a pane cannot type into itself; a queued `sala op rename OLD NEW` has no pane of its own, so it types `/rename NEW` from outside once the pane is idle, also when OLD is the pane that asked (right after its turn ends; a busy pane is tried again every minute for 2 h), and leaves nothing for the owner to type. `rename --sync` follows a hand `/rename` (pane or claude.ai): `follow` runs it when a name actually changes, `watch` as the backstop |
| `lane [<lane> <session>… \| <lane> --all \| default <lane>] [--dry-run] [--rescue]` | which account or key each pane's claude runs on: `subscription-1` (the login in `~/.claude`; the launch line as it always was; the older word `max` is still read), `api` (the key, read by the pane's own shell from `SALA_LANE_API_KEY_FILE` when the line runs — never in what sala types or logs), `subscription-2` (a second login in its own `CLAUDE_CONFIG_DIR`; the older word `team` is still read), `bedrock` (Claude on Amazon Bedrock through the AWS profile `SALA_LANE_BEDROCK_PROFILE` names: the profile's env on the pane's launch line, no claude.ai login; refused until the profile is in `~/.aws/credentials`), `aws-platform` (Claude Platform on AWS: the Anthropic-operated API signed with that same kind of AWS profile, plus a workspace id; refused until `SALA_LANE_AWSPLATFORM_WORKSPACE_ID` is set and the profile is there), `sdk` (an alias of `api` with client `claude-agent-sdk`: the same key through the Agent SDK, which the API credit pays for: the pane runs `salamander sdk-pane` in place of `claude`; see *The sdk lane*). `lane --list` / `lane --json`: the lane fields alone (provider, client, org, billing, plan, account, credential, region, status; see *Lane fields*). No argument: the table — the default lane, the lane fields, and each session's recorded lane beside the one its claude runs on, and under it a warning when the master sits on a lane sala sees out, with the way off it. `<lane> <session>…` records the lane and relaunches those panes on it through `revive --force --only` (the invoking pane last, by the self-worker; one already on it is left alone; `--rescue` on it: a stale background-task row does not hold a pane with no child process under its claude); `<lane> --all` records every session and the default, then one `recycle --force`; `default <lane>` sets the default alone. A switch is a relaunch, never a re-auth; every later relaunch (recycle, the boot hook, a retry worker, `restore`, `unpark`) keeps the lane. Refused before anything is recorded when the lane cannot launch (no key file, a directory not signed in). See *Lanes* |
| `lane dormant <lane> [--reason TEXT] [--dry-run]` · `lane active <lane> [--dry-run]` | **the dormant record** (*The dormant record* below): mark a lane dormant (nothing can run on it for now) or active by hand. Only the record is written: no pane is touched or relaunched. A switch, `lane default` and the rescue refuse to move onto a dormant lane |
| `lane fallback <lane> [--dry-run]` · `lane dormant <lane> --no-fallback` | **the lane fallback** (*The lane fallback* below): move a dormant lane's sessions, the default lane and (at run time) its jobs to the lane's fallback (`SALA_LANE_FALLBACK`: subscription-1, subscription-2, aws-platform, api and sdk fall back to bedrock, bedrock to subscription-1; one hop, used only if it is itself active and ready). `lane dormant <lane>` and the watch's own detection queue it by themselves (`sala op lane fallback <lane> --from sala-watch`); `--no-fallback` marks the lane dormant and moves nothing. `--dry-run` prints the moves and writes nothing. Nothing moves back by itself |
| `watch --back-lanes [--dry-run]` | **the back agents' lane rule** (*The back agents' lane rule* below; `SALA_BACK_LANE_RULE=on`, off by default): one pass of the rule that moves the background agents off the home lane near its weekly limit and home when it resets. `--dry-run` prints what it would queue and writes nothing |
| `lane --migrate [--dry-run]` | **the rename's migration** (Mon Oct 26th 2026): the lane `aws-platform` was called `awsplatform` until then. The old name is still a word for it everywhere a lane is typed (`sala lane awsplatform <session>`, `spawn --lane`, `sala op lane`, a web payload) and every file that still says it (`lanes.tsv`, `lane-default`, `lane-state.tsv`, the session registry, `lanes.log`, the limit watch's state, the web app's caches) is read as the new name; every write records the new one. `--migrate` rewrites the old name in `lanes.tsv`, `lane-default`, `lane-state.tsv` and the registry once (idempotent, atomic, a `<file>.pre-aws-platform-<time>` backup beside each file it changes; `lanes.log` is history and stays; `install.sh` runs it too). The config variables keep their names, `SALA_LANE_AWSPLATFORM_*` (a hyphen cannot be in a variable name; `lane_varid`) |
| `lane --rescue <lane> [--dry-run] [--force]` | **the rescue**: another session moves the master (`SALA_MASTER`) to `<lane>` when the master's own lane is out — its usage gone or its account dead, by sala's own readings (`lane_check`, the sign-in watch's state, the limit watch's state). Refused while the master's lane looks fine to sala (`--force` overrides, said in the log), from the master's own pane (the ordinary switch does that, through the self-worker), onto a lane that cannot launch or is out as well. Takes the recycle lock, records the lane, writes one `rescue` line in `lanes.log` (when, who, from → to, why) and relaunches the master through the direct sweep with `--not-master --rescue`. `--dry-run` writes, logs and relaunches nothing. See *The rescue* under *Lanes* |
| `model [<session> <model> [--effort <level>] [--record-only] \| <session> --clear \| <model> [--effort <level>] [--record-only] <session>… \| --clear <session>…] [--dry-run] [--not-master]` | the model and effort a session is relaunched on, ahead of what its transcript says. `<model>` is a family alias (`opus`, `sonnet`, `haiku`, `fable`) or a full model id (`claude-…`), `--effort` one of `low` `medium` `high` `xhigh` `max`; both go on the resume line as `--model` and `--effort`. Setting them records the row, then switches the session in place when its pane is idle with an empty input box (`/model` and `/effort` typed into it, the lane's saved default in `settings.json` put back, the conversation process kept), else relaunches it resumed on the same conversation through `revive --force --only` (its own pane by the self-worker, once idle; one already running them is left alone); `--record-only` writes the row without a relaunch (it holds at the next one); `--clear` drops the row, and the transcript decides again at the next relaunch. No argument: the table — each recorded session, what its claude was launched with, and its transcript's last turn. A Claude session does not run the switch itself (no master session: it is refused and pointed to the queue); it queues `sala op model <model> [--effort <level>] <session>… --from NAME --words "…"` (several sessions, one operation, one result notice; or the single-session `<session> <model> [--effort <level>]` / `<session> --clear`). A first word that is a model (`opus`, `sonnet`, `haiku`, `fable`, `claude-…`) means several sessions at once. See *Models* |
| `follow` | resident watcher of the session registry (Linux inotify; `systemd/sala-follow.service`): keeps each session's last state in memory and runs a handler only when a field it watches changes — a turn's status flip costs one small read. Handlers: `rename` (name changed → `rename --sync`) and `continued` (sessionId changed → `watch --continued`: a pane that moved to a new transcript id keeps its pane map row and session registry row within seconds; live after `sala-follow.service` restarts). Bursts are coalesced (2 s), each handler is capped at 5 runs a minute and a run is killed after 60 s (`SALA_FOLLOW_TIMEOUT`); log `salamander-follow.log` |
| `unpark NAME [--dry-run]` | Claude Code 2.1.28x's "← for agents" key parks a pane's conversation into a background fork under the CLI's daemon; the fork takes the Remote Control bridge and every claude.ai turn from then on, while the pane's own conversation goes stale (`spawn --list` flags "⚠ parked"). The registry then holds two rows under the one name (the pane's viewer, status always `shell`, `parkedJobId`; the job's, `kind` bg, `jobId`), and sala reads them as ONE session: the idle guard, a recycle or revive, the pane map's follow (`revive --save-map`), `map` and the heartbeat take the job's state and the job's conversation for the pane, so a recycle relaunches a parked pane when its job is idle (waits while the job works), ending the job and resuming the job's conversation in the pane as an ordinary session (the same steps as `unpark`, no second viewer: a transcript has one writer). `unpark` ends the idle fork, quits the stale process from the CLI's list view, resumes the fork's conversation in the pane (bridge reattaches, name restored) and moves the pane-map row to the fork; verifies one holder of the bridge |
| `master [--name \| --json \| --set NAME \| --unset]` | the master session (`SALA_MASTER`, the one `watch` keeps alive — **optional** since the operation queue) and whether it is live: name, pid, conversation, bridge, idle. `--set` designates an existing session (writes `SALA_MASTER` into the config); `spawn NAME --master` creates and designates in one go. `--unset` ends it (Thu Oct 15th 2026): the config line commented out, the file checked to parse and to name no master, the watchdog's records of it dropped (its name, conversation, bridge, directory — nothing heals, recreates or bridges it from then on; the post-boot report goes to Slack), `master_unset` recorded in the watch state so `watch` and `master` read "unset on purpose" rather than "config lost", and the last-good copy refreshed to the unset config (a restore from it never brings the master back); idempotent. With a master it is the operator for cues like "recycle claude": the session that hears the cue resolves the master here and hands the cue over, never runs it itself; with none every path that needed one points to the queue (`sala op`), and `sala op retire <the master>` unsets and retires as one operation (see `op`). `heartbeat` publishes the same name ("" when unset) and conversation id in `machine.json` for callers that cannot read the config |
| `cue [--from NAME] [--dry-run] "<words>"` | hand an operator cue — "recycle claude", "update the CLI", "update claude on box1" — to the master: resolves `SALA_MASTER`, confirms its claude is live, and delivers the words verbatim, with who heard them and when, into the master's inbox socket (the registry's `messagingSocketPath`), where they arrive as a turn. The master maps the words to the command. No master → prints the pointer to the queue (`sala op <verb> … --from NAME --words "<the owner's words>"`, the verb table, one example), delivers nothing and exits 1 (`reauth --done` with no master prints the exact `sala op recycle --force --from <you> --words "<the owner's words>"` line instead, queues nothing and exits 0); the master itself → "run it here" |
| `op <verb> [args…] --from NAME --words "<the owner's words>"` | **the operation queue** (Wed Oct 14th 2026; `lib/op.sh`): the way a fleet operation runs with no master session and no model in the loop — any session that hears the owner queues it, `watch` runs it. The verbs, each a fixed shape checked against a table (never a shell string): `recycle [--update] [--force]`, `update [HOST…\|--fleet]`, `revive [--only NAME]… [--force]`, `retire NAME\|--id ID [--keep-web] [--busy] [--skip-writeup] [--self] [--leave-items]`, `close-shell NAME [--busy]`, `forget-row NAME`, `rename OLD NEW`, `lane <lane> <session>…\|<lane> --all\|default <lane>\|fallback <lane>` (`fallback`: the dormant lane's sessions, default and jobs move to its fallback lane, one notice; the watch and `lane dormant` queue it themselves as `--from sala-watch`, *The lane fallback*), `model <model> [--effort <level>] <session>…\|--clear <session>…\|<session> <model> [--effort <level>]\|<session> --clear` (Sun Oct 25th 2026: a session changes its own or another's model and effort through the queue, Thu Oct 29th 2026: several sessions in one operation with ONE result notice, *Models* below), `provision [--only STEPS] [HOST…]`, `spawn NAME --project <page key> --role front\|back [--mandate FILE\|TEXT] [--lane L] [--model M] [--effort E] [--cwd DIR] [--no-confirm]` (a project agent's session, *spawn* above; a TEXT mandate is written at queue time to `~/.local/state/salamander/mandates/<id>-NAME.md` and the marker carries that path — an `arg=` line holds one line, the file holds the bytes — and the file stays for the session to read after the operation has ended; a refused or cancelled operation's file is removed; the plan is `spawn … --dry-run`, and a name not on the page refuses the operation with the verb's own exit 3 and the `ADD-TO-PAGE:` block printed once more unindented, exit 4 and `NO-PAGE:` for a page that does not exist, so the web layer can show the line to add; a second spawn of a name already queued is refused as naming the same session; at run time a spawn that exits 3 or 4 is stuck with no `claude -p`, since only the page's keeper can add the line). A reboot is not queued: the owner runs `sala reboot --go` from a plain shell, and a session shows them `sala reboot --status` and waits for their word; `op reboot` (= `reboot --go`) is refused while `SALA_OP_REBOOT` is off, its default, and that switch is unsupported until a confirmation path is built. The marker (`~/.local/state/salamander/ops/<id>.op`) carries who heard the owner, the owner's words verbatim (`--words`, or `--stdin` from another box; a marker with none is refused, `--auto` only for one sala writes itself and never under a Claude process), the verb and each argument as its own field. **The plan comes first**: the verb's own dry run (`retire --dry-run`, `rename --dry-run`, `lane --dry-run`, `revive --dry-run` for a recycle's sweep) is run and shown, and its refusal — no such session, an ambiguous name, a pane that is not idle — refuses the operation before anything is queued; `update` and `provision` check their hosts against `SALA_FLEET_HOSTS` by name (no ssh at this point); `reboot` (only with the unsupported `SALA_OP_REBOOT=on`) shows `reboot --status`. Then `sala-watch.service` is started at once (a tick already running gets a one-off `watch --ops` 10 s on). `watch` starts the oldest queued first, each as its own unit `sala-op-<id>` (KillMode=process: a relaunch's detached driver outlives it), and runs several side by side only where the verbs themselves declare it safe (*Parallel operations* below); when an operation ends in any state (or its runner exits) and another is still queued, one `watch --ops` follows `SALA_OP_KICK_END` (5) s later as the unit `sala-op-kick-end` (none while the queue is empty, never two pending), so a burst runs back to back instead of one operation per 2-min tick; a recycle about to start absorbs every queued recycle and this box's queued updates (their flags fold in, their markers end as `absorbed`, their hearers are told). **The end of every operation is also reported to stackshot** (`lib/op.sh`, `op_event`, the last act of `op_finish` beside the Slack post): `client.py event --kind fleet_op --verb <verb> --machine <host> --sessions <N> --result ok|partial|failed --text "<one line>"`, so an item waiting on `fleet_op <verb|any|many>` is woken by the operation and not by its backstop day. `--sessions` is the sessions the operation names (more than one), else the relaunch set's total (a recycle, an update, a whole-fleet provision), else 1 for a verb on one session, else 0; `ok` is done with nothing failed or skipped, `partial` some failed or were skipped (the counts of the post: "3/5 succeeded"), `failed` stuck with nothing through. Once per operation, also when it ends stuck; not for a plan, a cancelled or an absorbed operation. A client that fails, answers late (`SALA_OP_EVENT_TIMEOUT`, 30 s) or is missing never changes the operation: the outcome is one line in `salamander-op.log`. The recycle's own `client.py recycled` report is unchanged. **Parallel operations** (`lib/op.sh`, header and `op_shape`): each verb declares in its own `op_shape` branch what it touches (`OP_PAR=par` and `OP_KEYS`, the session names) or that it runs alone (`solo`, the default for a verb that says nothing and for a marker the table cannot parse), and `op_tick` applies the declarations, in queue order, starting as many as the rules allow in one pass (the tick and the end-of-op kick). Parallel-safe: `spawn`, `retire` of a live tmux session, `close-shell` and `forget-row` of a live tmux session or a pane-map row, `rename` (not the master's). Solo: `recycle`, `revive`, `update`, `provision`, `lane` (every form), `model` (every form), `reboot`, a `retire --id` (the session is found only when it runs), and the master's `retire`, `close-shell` and `rename` (they relaunch panes under the exclusive recycle lock or write the config). Two operations run side by side only if both are parallel-safe and their name sets do not overlap (a name in any role, spawn's `--fork-of` source included, means serial, oldest first); a solo one starts only when nothing runs and blocks the younger ones while it waits, so it is not starved; at most `SALA_OP_PARALLEL` (3; `1` = one at a time, as before) run at once. The marker gets `par=` and `keys=` at the start (a running marker without them counts as solo). A parallel operation takes the recycle lock SHARED (`recycle_lock_shared`), a relaunch driver EXCLUSIVE, so they never run together and `recycle_locked` still reads locked for the watch steps that stand aside; the shared state they all write is guarded in code (pane map under its own flock, `lanes.tsv` and `models.tsv` under theirs, the sessions registry under the pane-map lock, spawn's resurrect save under `$SALA_RESURRECT_DIR/.snapshot.lock`) and held to it by `tests/opparallel.sh`. The runner takes the recycle lock before any verb (holder `op-<id>`; it waits up to `SALA_OP_LOCK_WAIT` for a relaunch already running), holds it through a verb that takes none itself and hands it back at once to one that does; `master_guard` and `ops_guard` admit it by its unit's name in its cgroup (see *One driver*). A relaunch verb's end is the lock freed, then its set (*recycle sets*): closed with nothing given up → done; a pane given up → stuck; panes still outstanding (a retry worker, the deferred list) → `waiting`, and a detached waiter judges the set once it closes (up to the retry window plus 15 min); the queue goes on meanwhile. Every result is one Slack post (✅ done · 🚨 stuck, with the exact failure) and one line into the hearing session's inbox (when that pane is not live, to the same project's `<name>-main` front agent with `[for <owner>]` first, and the op log says so; when neither is live, the op log says that, and the post stands), then the marker moves to `ops/done/`. **Stuck** (a no-words retire whose run-time re-check fails is recorded stuck at once and never gets the helper; a verb that exited non-zero, a set that gave a pane up, a conflict between two queued operations naming one session, a runner that ended without a result, the waiter's deadline): at most one `claude -p` per operation (`SALA_OP_STUCK`), on the subscription-1 lane (the api key, custom headers, entrypoint and config dir stripped), default permission mode — no bypass flag, so a prompt it meets ends it — `--allowedTools` limited to sala's verbs and read-only looks (`SALA_OP_HELPER_TOOLS`), `--max-turns` and a wall clock (`SALA_OP_STUCK_TURNS`, `SALA_OP_STUCK_TIME`), with the operation, the owner's words, the log tails and what was already tried in its brief; it ends with `SALA-OP: done …` or `SALA-OP: stuck …`, a `done` checked where sala can (the retired session gone, the renamed one live, the default lane set) and trusted otherwise. Not finished → stuck, posted once with the exact failure, told to the hearing session, archived; nothing retries it by another route. `op --plan <verb> …` shows the plan alone; `--list`, `--status <id>`, `--cancel <id>` (a queued one only). **The master's own retire** (Thu Oct 15th 2026) is one operation: a plain `sala retire <the master>` refuses outside the queue (its dry run too), `op --plan retire <the master>` says "would unset SALA_MASTER, then retire", and the runner unsets `SALA_MASTER` first (`salamander master --unset`, its output in the operation's log), then retires; a retire that fails after the unset is stuck with `SALA_MASTER` unset and the post saying so (`master --set` puts it back if the retire is not to happen), an unset that fails leaves everything untouched and the retire never starts. With a master configured, `sala cue` and the master path work beside the queue; with none ("No master session": the master is retired once the queue works) the queue is the one door and the guards say so (*One driver*). A marker needs the owner's words, except two doors, each a row of the policy table `op_words_policy` in `lib/op.sh` (`owner`, `reason` or `throwaway` per verb and arguments; every verb not named below is `owner`): `sala op retire NAME --from YOU` for a throwaway (a tagged row: any session; an untagged one: its spawner, the master, or any session for a throwaway's name; see `retire`), and (Tue Nov 3rd 2026) **`sala op revive --only NAME [--only NAME]… [--force] (--item board#N \| --why "<one line>") --from YOU`** with no `--words`, for a session found unable to work: any live Claude session may queue it (placed by process ancestry as retire's door is; `SALA_OP_REASON_FROM` empty = any, else a space-separated allow list of session names), each NAME a live registry Claude session, not the master and not the asker; the reason is `--item board#N` (a format check only: there is no board lookup) or `--why` (one line, at least 3 words, at most 200 chars), kept in the marker as `item=` / `reason=` and shown by `op --list` and in the result notice. A sweep (no `--only`), `--rescue`, `--lane-default` and any other flag still take the owner's words. The runner (`op_run`) checks all of it again, and a mismatch (a row replaced, a flag added) ends the operation stuck with nothing run and no `claude -p` helper; for a no-words marker the helper, if one is ever started, may run only `salamander revive [--force] --only` the marker's own names |
| `map [--write PATH]` | markdown table: session name · claude.ai URL · tmux session |
| `watch [--check]` | the watchdog, from a systemd user timer (`systemd/sala-watch.timer`). With a **master** session designated (`SALA_MASTER`; optional) it keeps it alive and bridged to Remote Control: restarts the tmux server, recreates the session, resumes its last conversation, types `/remote-control` when the bridge is down — one heal per run, cooldown, never on a busy pane or a prompt; a changed bridge id is reported, not fixed. After every boot (planned or not) it hands the master one **post-boot report** in its inbox — boot time, kernel, the boot revive's summary, `SALA_BOOT_AUDIT` — once revive has finished and the master is idle; a master still not live by `SALA_BOOT_DEADLINE` → the notify command gets the report instead. **With no master** (Thu Oct 15th 2026; `salamander master --unset`) those checks are off — nothing recreates, resumes or bridges a master, no bare tmux session is made for one (a tmux server that is down is started through `tmux.service`, else reported) — everything below runs as before, the post-boot report goes to Slack as one post per boot, at once, once revive has finished, and `--check` says "healthy: no master session"; a watch state that still remembers a master with no `--unset` record is a lost config: said out loud once a day, `--check` fails, the tick ends there. **Bare panes** (`lib/barepane.sh`, with or without a master): every pane of the pane map whose tmux session is up but whose claude is gone (a shell is the foreground command, no claude under it, no child process) is revived with `revive --only` once it has stayed bare for `SALA_BARE_GRACE` (180 s, three ticks) — at most `SALA_BARE_MAX` (6) per tick, the longest bare first, so a mass death is healed over several ticks; a failed pane is tried `SALA_BARE_TRIES` (3) times, `SALA_BARE_RETRY` (600 s) apart, then posted once and left; one post per tick ("watch: revived N panes whose claude had died: …"). Never during a recycle, revive, restore or queued operation, for a retired session, a finished side session, `SALA_NO_RELAUNCH`, a pane running a command, or a conversation live in another pane; `SALA_BARE_REVIVE=off` turns it off. **Idle wrap-up and clear of background agents** (Thu Oct 29th 2026; **off by default since Fri Oct 30th 2026: the CLI's own compaction is the only limit on a background agent's conversation; everything below applies only with `SALA_IDLE_WRAPUP=on`**; `lib/wrapup.sh`; `watch --wrapup` runs it alone, `--wrapup --dry-run` prints what it would do): a background agent (role `back` in the session registry; never a front agent, a side session, the master or an sdk-lane pane) whose last turn ended `SALA_IDLE_WRAPUP_MIN` (50) minutes ago, and not more than `SALA_IDLE_WRAPUP_MAX_AGE` (58) minutes ago (past it the prompt cache is cold and a wrap-up turn would reload the whole conversation uncached: the pane is left alone, no wrap-up and no clear, one log line; `0` or `off` lifts the bound), is sent one marked message, `sala: you have been idle 50 minutes; your conversation is cleared after this turn. Write anything only you know to your items and pages (board update, page Current state or timeline line), then reply done.`; when that turn is over (the registry row idle again with a stamp newer than the message, the input box empty, no dialog, nothing running) sala types `/clear`. The point is the prompt cache: after an hour a wake reloads the whole conversation at the uncached price, and a cleared agent starts from its mandate, its rules and the board instead. `/clear` keeps the registry row, the pid and the name and gives the row a new `sessionId`; sala follows it in the pane map (`ledger write follow`) and the session registry (`clear`), and the SessionStart hook (`hook session-start`, source `clear`) prints one line telling the cleared agent who it is and where its mandate is (`SALA_CLEAR_CONTEXT=off` silences it). A pane is skipped, and tried again next tick, while it is mid-turn, has text in its input box, a dialog, a background command, task, subagent or scheduled job, or is parked on a background job; one relaunched or cleared with no turn since is never wrapped up again (it needs a turn of its own first); a wrap-up that produced no turn is dropped for `SALA_WRAPUP_RETRY` (1800 s); a `/clear` the CLI does not take is tried `SALA_CLEAR_TRIES` (3) times, then the pane is recorded as failed and is not wrapped up again until its conversation has a new turn. At most `SALA_IDLE_WRAPUP_MAX` (3) panes are acted on per tick; each wrap-up and each clear is one line in the watch log and nothing is posted. It is off unless `SALA_IDLE_WRAPUP=on` (`SALA_IDLE_WRAPUP_MIN=0` also turns it off). A mass SIGKILL of every claude leaves tmux and every pane up as bare shells; watch heals it. It also runs the **CLI auto-update** (`SALA_AUTO_UPDATE`): when npm has a newer Claude Code, every box behind it is updated at once (this box's CLI only; running panes keep their version meanwhile; one try per box per release, but a box the update unit finds offline, although the heartbeat saw it awake a minute earlier, gets its try back and is tried again once the heartbeat sees it awake; a retry run posts nothing of a box that stays offline), and cues the **automatic relaunches** as soon as they are due, with no wait for the whole box to go quiet (the recycle's own guard skips a busy pane and its retry worker relaunches that pane once it is idle): the **relaunch onto the installed CLI** (`recycle` of the panes on an older version, once per installed version) and the **auto-recycle** (`SALA_AUTO_RECYCLE`, default on) — when board items wait for a recycle (`SALA_RECYCLE_WANTED_CMD` prints their count) or a session ran `recycle --when-idle`, it starts the recycle the master's "recycle claude" would (`recycle --update --force`) as its own unit, clears the requests it served and posts what triggered it. Never during a recycle, revive, reboot or a pane-map freeze; at most one an hour. And the **usage-limit watch** (Tue Oct 13th 2026; `SALA_LIMIT_ALERT`, `SALA_LIMIT_RESUME`, both default on; `watch --limit` runs it alone), which takes no Claude turn and makes no API call: from the tails of recent transcripts it judges each pane on its own, on the lane it runs on (`lane_running`, read from the process; the lane an error was hit on is kept with it): a pane whose newest record has been a limit error for `SALA_LIMIT_CONFIRM` (10 min) is stopped, counted from its first error of this episode (after its own last success and the lane's last success before the error), and the panes stopped in one run get one post — a line per lane, limit and reset, the limit named from the record and the lane's login ("subscription-1 lane: weekly limit since …, it says it resets …": weekly, 5-hour, one model's weekly; the api lane's own kinds, from records in the CLI's shape: "api lane: out of API credit since …" (error `billing_error`), "API workspace spending limit" with its reset the "regain access on … UTC", and from the API's documented shape a 429 "API rate limit"). The lane of an error is the error's, never the lane running when the watch first sees it: a credit or workspace record is the api lane's whoever runs the pane now, a weekly or 5-hour record a login lane's, so a pane relaunched onto another lane with an old error still in its tail is never booked stopped there — it lifts as "moved to the subscription-1 lane" and is told to go on; a pane lifts, with its reason in the post, when it has a normal record after its error, runs on another lane than the error's ("moved to the api lane"), or its lane has a success newer than the error ("the weekly limit reset at …" once the reset has passed, else "the weekly limit lifted early"; "API credit was added", "the API rate limit lifted"); each lifted pane still on the error is told once, through its messaging socket, why and to handle its last incoming message (a busy one once it is idle, for `SALA_LIMIT_RESUME_FOR`), and when the last stopped pane lifts, each of sala's own oneshot units (`sala-*`, `salamander-*`) that failed during the stop is reset and started; a `claude -p` run with no pane (a headless job) that ends on a limit error is named by what started it (the user unit whose WorkingDirectory is its cwd, or sala's own oneshot whose last run or journal lines are at that time; else plain words with the folder), its runs on one line once per starter per episode, and dropped when that starter later succeeded (the unit re-run by sala, or a later normal record). And the **network-stop wake** (Thu Oct 22nd 2026; `SALA_NET_WAKE`, default on; `watch --net` runs it alone): a pane whose newest assistant record is `API Error: Can't reach the API server — check your internet or DNS (EAI_AGAIN)` (DNS was down; nothing retries such a turn, so the pane stays stopped after the network is back) is sent ONE message through its messaging socket, `[sala] Your last turn ended on a network error (API unreachable). The network is back; continue what you were doing.`, once `api.anthropic.com` resolves (`getent hosts`, `SALA_NET_DNS_WAIT`) and the pane is idle; nothing is typed into the pane and no Enter is sent. Once per episode (the unbroken run of such errors; a pane that works again and stops again later is a new one); a pane with no claude or no socket is skipped quietly; the state is `~/.claude/salamander-net.state`, the trace a line in the watch log. The revive summary counts the resumed panes that ended on it ("N resumed, M of them stopped on a network error; woken once the network is back") and the post-boot report names the panes stopped when it is made. And the **lane sign-in watch** (Wed Oct 14th 2026; `SALA_SIGNIN_ALERT`, default on; `watch --signin` runs it alone): each login lane asked what it is signed in to and the api lane's key whether the API accepts it, against the table in `lib/common.sh`, one post per change and one when it is right again (see *The sign-in watch* under *Lanes*). And the **stuck-question watch** (Wed Oct 14th 2026; `SALA_STUCK_POST`, default on; `watch --stuck` runs it alone, `--stuck --dry-run` prints what it would post): a pane stopped on a terminal-only question (a permission dialog, the read-outside-the-working-folder prompt, a numbered menu: what `pane_prompt` reads as a prompt, the same pattern every relaunch waits out) hangs unattended, so once it has shown the question for `SALA_STUCK_CONFIRM` (90 s) it is posted once — the session, the dialog's text (its title, body and question, anything that looks like a secret masked, ~200 chars) and the session's sala-web link — and not again while it shows that question; another question is posted, and a pane whose prompt went drops its record, so a later episode posts again. A post the notify command refused is tried again on the next `SALA_STUCK_RETRIES` (2) ticks, then given up for that question; the state is `~/.local/state/salamander/stuck.state`. With the Notification hook installed (`hook notify`, below) the same post goes out about 6 s after the dialog shows, and this tick finds the question posted. And **the operation queue** (`SALA_OP_QUEUE`, default on; `watch --ops` runs it alone, and `sala op` kicks the service or that step the moment an operation is queued): the oldest queued operation started as its own `sala-op-<id>` unit, one at a time, master or no master — see `op` above; a runner that ended without a result is handed to the stuck handler, a unit of its own (never inside the tick: a oneshot's leftover processes die with it); **continued-in follow** (`lib/continuedin.sh`, also `watch --continued`, run by `follow` when a registry row's sessionId changes): a live pane that Claude Code moved to a new transcript id (a `continued-in` record in the old transcript, same pid) gets its pane map row and session registry row moved to the new id (chains followed; evidence needed: the pid's registry row names the new id, or the new transcript exists and the record is newer than the process; the record is read from the last 64 KiB of the old transcript, never the whole file); one watch log line, `SALA_CONTINUED_IN=off` stops it |
| `settings-apply [--check \| --run] [HOST…]` | **the settings-apply service** (Wed Oct 14th 2026; `lib/settings-apply.sh`, a step of `watch`): every Claude Code settings change that lands in the machine spec (the machine spec in the config repo: the spec files and the provision step scripts, one fingerprint over them) is applied by sala, on this box and over ssh on every `SALA_FLEET_HOSTS` box the heartbeat store says answers, never by a session (the auto-mode classifier refuses a session that edits its own settings). The tick launches one `settings-apply --run <boxes behind>` as the transient unit `sala-auto-settings`; the run is `provision --quiet --check --only <SALA_SETTINGS_STEPS>`, then the apply on the boxes whose check found a settings step drifting (never for `repo` alone), `~/.claude/settings.json` backed up beside itself first (`settings.json.bak-sala-settings-<stamp>`), the key-by-key diff logged after (`~/.claude/salamander-settings-apply.log`), a settings.json that no longer parses put back from the backup. No CLI update, no recycle, no relaunch: panes take the settings at their next relaunch. A box's first look is dry ("would apply", recorded; applied from the next spec change on), so switching it on changes nothing by itself. Slack only for a failure (once per box and fingerprint, the step's own words) or a box still behind after `SALA_SETTINGS_STALE`. No flag: the state; `--check`: what it would apply, nothing recorded; `--run`: the unit's entry, also by hand from a shell. See *The settings-apply service* below |
| `heartbeat [--no-push \| --dry-run \| --check]` | publish every box's CLI version and live sessions (`{uuid: {name, url, seen, machine}}`, keyed by transcript UUID) as two JSON files per box under `SALA_HEARTBEAT_REPO/SALA_HEARTBEAT_DIR/<letter>/`: this box's from its registry, the others' (`SALA_FLEET_HOSTS`) from one ssh round-trip each, which is also their liveness (`fleet_ssh`). Files change only when a fact does, so a quiet run commits nothing; commit, then fetch + rebase + push only those. A third file in the live store, `session-registry.json` (this box's session registry, `docs/session-registry.md`), is the exception: its `written` stamp is refreshed on every run so a reader can tell a stale file from a quiet fleet; it is never committed to git. Timers (every 5 min) in `systemd/` and `launchd/` |
| `ready [--clear \| --list]` | run from inside a session as the last call of a turn: "I am at a checkpoint, whatever is still running may be cut". The registry's idle is an observation from outside and cannot say whether a background child or a subagent matters, so recycle refuses such panes; a ready marker is the session's own word, so the idle guard then needs only registry-idle ≥ 10 s, and the call wakes a pending recycle's retry worker, which relaunches the pane as soon as that turn ends. No recycle pending: the marker holds for an hour. Consumed by the relaunch. A turn that ends with nothing in flight says the same for the session without anyone typing it: the Stop hook's record (`hook stop`, below) wakes the worker just as `ready` does When processes still run under the pane, the output names them first: "ready: … — but N background process(es) still run under this pane and will be cut at the relaunch, or hold it:" and one line each (pid, how long it has run, the CLI's task id, the subagent that started it when one did, the command cut to 120 characters), then how to stop them (`TaskStop <task id>` or `kill <pid>`). They are found by the process tree under the pane's claude, not by a name; a plugin's MCP server is left out, as in the busy check. The relaunch notice (`SALA_RELAUNCH_WAITING_TEXT`) and the skip and deferral reasons carry the same list. Nothing is added when nothing runs |
| `snapshot [--now]` | debounced tmux-resurrect save; wire to tmux's `session-created/closed/renamed` hooks and Claude Code's SessionStart hook |
| `feedback mark \| stop \| drain PANE` | auto-send Claude-drafted feedback, transcript off — `mark`/`stop` are hooks, `drain` drives the `/feedback` panel; `recycle` drains before `/exit` |
| `hook stop \| post-tool` | Claude Code settings hooks (both with matcher `*`, registered by the machine spec, not by `install.sh`, which only says when they are missing). `stop` records at each turn's end what the session left in flight — the Stop input's `background_tasks` (shell, subagent, monitor, workflow) and `session_crons` — as `~/.local/state/salamander/busy/<session id>`, stamped with the registry's idle flip that follows; the idle guard reads it in place of its guesses (*Design notes*), and for a pane a relaunch waits for an empty record counts as `sala ready`. `post-tool` gives a session a relaunch waits for one line of context, once per relaunch (`SALA_RELAUNCH_WAITING_TEXT`; it names the relaunch: a recycle, a reboot of the host, a CLI update relaunch, a provision relaunch, an automatic relaunch), from a flag under `~/.local/state/salamander/waiting/` that a recycle's retry worker or the reboot drain raises and takes down; with nothing waiting it is one file test and an exit |
| `hook prompt` | the UserPromptSubmit hook (settings.json `UserPromptSubmit`, no matcher: that event takes none; registered by the machine spec, which `install.sh` only reminds of): at a session's next prompt, prints the `sala notice` lines it has not been shown yet as `hookSpecificOutput.additionalContext` (hookEventName `UserPromptSubmit`), and nothing else; the same delivery `hook post-tool` makes after a tool call, so a session is told at whichever comes first and never twice. Exit 0 always. See *Telling every session something* |
| `notice add "<text>" --from <sender> [--until <when>]`<br>`notice list [--json]` · `notice drop <id>` | **a one-time line every live session sees at its next turn, with no relaunch** (`lib/notice.sh`, `lib/notice.py`). `add` stores one line (at most 400 characters, no newline or tab; `--from` your session name, required; `--until` an epoch, a span like `12h` or `7d`, or an ISO 8601 time, default 7 days) and prints its id and how many live sessions it reaches; `list` shows each active notice with how many sessions had it and how many are still due; `drop` withdraws one for the sessions not yet reached. See *Telling every session something* |
| `hook subagent-stop` | the SubagentStop hook (Mon Oct 26th 2026; settings.json `SubagentStop`, matcher `*`, registered by the machine spec). A subagent that has handed back (its transcript holds the `SubagentHandback` call) and left a background shell running keeps its parent's pane held (registry state `shell`) as long as the shell runs, and the shell is in no task list of the parent's: an until-loop held a relaunch for as long as it ran. The hook stops the shells that subagent started: the shell's task id (`/proc/<pid>/fd/1` is `<scratch>/tasks/<id>.output`) must be one the subagent's own transcript received as "Command running in background with ID: …", listed as running in the hook input's `background_tasks`, the process must sit under the pane's claude and carry the command text of that call. SIGTERM to the shell's process group, one line per stop in `~/.claude/salamander-subagent.log` (pid, task, command). The main thread's own background tasks and anything outside the claude's tree (`setsid nohup`) are never touched. A subagent that has not handed back may be waiting for its command: nothing is stopped, a line says so. Stopping the shell wakes the subagent once more (a second SubagentStop with nothing left). Exit 0 always, prints nothing; `SALA_SUBAGENT_CLEANUP=off` disables it |
| `hook permission-request` | the PermissionRequest hook (Mon Oct 26th 2026; settings.json `PermissionRequest`, matcher `*`, registered by the machine spec). Auto-approve comes first; asking a person is the fallback. A permission prompt is approved at once (the hook prints the one `allow` line); the dialog is left alone, so a person sees it and the instant alert D (`hook notify`) still fires, for a question to a person (AskUserQuestion, ExitPlanMode), a call that touches the permission and instruction surface (settings, `~/.claude.json`, CLAUDE.md, the rulebook, hooks, `.mcp.json`, managed settings), credentials (`~/.ssh`, `.aws`, `.env`, token files …), plan mode and input it cannot read. Exit 0 always; one line per decision in `~/.claude/salamander-permission.log`; `SALA_PERMISSION_APPROVE=off` leaves every prompt. The table is at the top of `lib/permissions.py`; the reasons are in `docs/permission-hook.md`. |
| `hook session-start` | the SessionStart hook for the session registry (phase 2; settings.json `SessionStart`, matcher `*`; [docs/session-registry.md](docs/session-registry.md)): reads the hook JSON, takes the row from `SALA_SESSION_ID` (else the pane's tmux session name) and calls `sessions record` with why `clear`, `resume` or `start` for source `clear`, `resume`, `startup` (`compact`: nothing). Exit 0 always, prints nothing (stdout would reach the model's context); a headless `claude -p` (`CLAUDE_CODE_ENTRYPOINT=sdk-cli`) is ignored |
| `hook notify [--dry-run]` | the Notification hook (Thu Oct 22nd 2026; settings.json `Notification`, matcher `permission_prompt\|elicitation_dialog\|elicitation_url_dialog`; `docs/stuck-question-recovery.md`): Claude Code raises `permission_prompt` about 6 s after a dialog shows with no keystroke, and this posts at once, once per question — the stuck-question watch's post (session, the dialog read off the pane with secrets masked, the session's link) through the watch's own path (`SALA_NOTIFY_CMD`) and state (`stuck.state`: it writes the watch's `hash`, `since`, `posted`, `tries` under the watch's lock), so the watch's 90 s post finds the question posted and stays silent. A pane it cannot read is alerted on the notification's own words; a post the notify command refused is left to the watch's retry. Never blocks or fails a turn (exit 0, the post bounded by `SALA_STUCK_INSTANT_TIMEOUT`); `SALA_STUCK_INSTANT=off` or `SALA_STUCK_POST=off` = nothing; `--dry-run` prints the post and writes nothing |
| `question run [--cwd DIR] [--label TEXT] [--model M] [--json] PROMPT… [-- claude args…]`<br>`resume-answer QID [--answer TEXT \| --answer-file FILE\|- \| --decline [WHY]] [--free-text] [--dry-run]`<br>`question list \| show QID \| sweep \| file QID`<br>`hook ask` | **a background `claude -p` run that asks the owner a question parks until the owner's answer arrives** (`lib/question.sh`, `lib/question.py`, `lib/permission-host.py`; `docs/stuck-question-recovery.md`, which has the findings). `question run` starts `claude -p` with `SALA_DEFER_QUESTIONS=1`, a permission host (`--permission-prompt-tool mcp__salahost__approve`: a `-p` run is offered AskUserQuestion only when it has one, and this host denies everything) and an inline PreToolUse hook (`hook ask`, matcher `SALA_DEFER_TOOLS`, default `AskUserQuestion`), so it needs no settings.json entry. The hook defers the call (the turn ends with `stop_reason: tool_deferred`; exit 10 and the question's id), records it under `~/.local/state/salamander/questions/<qid>/` and files it. `resume-answer` checks the owner's words against the options (a label or its number; `--free-text` takes anything; two questions need a line each; `--decline` denies), then resumes the session in the run's folder, the hook returning `allow` with `updatedInput {questions, answers}`. **Nothing is granted unless the owner's answer arrives**: no answer (or none yet from `SALA_QUESTION_ANSWER_CMD`) is exit 3 and claude is not started; words that are no option are exit 4 and the call stays parked; a parked call the hook sees again is deferred again. A tool listed in `SALA_DEFER_TOOLS` besides AskUserQuestion parks every call, answered yes or no. Filing and reading the answer are two seams (`SALA_QUESTION_FILE_CMD`, `SALA_QUESTION_ANSWER_CMD`). **Unset, and stackshot's client exists** (`SALA_STACKSHOT_CLIENT`, default `~/stackshot/client.py`), they are `contrib/question-board-file.sh` and `-answer.sh`: the first files the question as a `needs=decision` board item with `client.py post question` (project `SALA_QUESTION_PROJECT`, no default: empty, the filer refuses and names the setting; subject `[<scope>] <label>: <question>` (the scope word from `SALA_DEFAULT_SCOPE`); the question id as request id, so a retry files nothing twice; one button per option; a text over the board's 5 lines / 8,000 characters is cut by the script with a pointer to `sala question show`), the second reads `client.py get answer` and passes on the owner's **decision** only (never a comment) when it fits the call. A seam set explicitly wins and `off` disables it; with neither a setting nor a client the question goes out as a post through the notify command and `resume-answer --answer` is the way in. `question sweep` resumes every parked question that has an answer (and files again one whose filing failed); **the watch tick runs it** (`question_sweep_tick`, `watch --questions` alone) as its own unit `sala-auto-qsweep`, at most once per `SALA_QUESTION_SWEEP_EVERY` seconds (60; 0/off disables) and only while a question is open (no client call otherwise). A filing that fails `SALA_QUESTION_FILE_TRIES` times in a row (3) is announced once as a post through the notify command, with the board's reason, and still retried at each sweep |
| `alert "<headline>" ["<line>"…]` \| `alert --help` / `-h` | post an alert the way sala's own go (`SALA_NOTIFY_CMD` / `SALA_WATCH_NOTIFY_CMD`, sala_post's shape), for a check that runs without Claude, e.g. from a systemd user unit (a missed-slot check); exit 0 posted, 1 the notify command failed, 2 usage, 3 none configured; `--help` / `-h` (first argument only) print the usage, exit 0 and post nothing; `--` first lets a headline start with `-`; a URL in the headline stays outside the bold: `⚠️ *text* → URL` |
| `job add NAME --repo REPO --script PATH --schedule S… --description "…" --lane LANE --project SCOPE/PROJECT [--note "…"] [--args "…"] [--scope user\|system] [--checkout DIR]`<br>`job list` · `job set-project NAME PROJECT [--checkout DIR] [--quiet]` · `job remove NAME [--checkout DIR]` · `job relink NAME` · `job check [--post] [--quiet]` | **a scheduled job as a systemd service + timer kept in git** (`lib/job.sh`, `lib/unitjob.py`, the table `lib/unit-repos.tsv`; [docs/units.md](docs/units.md); no model call). `add` writes `NAME.service` and `NAME.timer` into the owning repo's unit folder with a `Description=`, an `X-Model-Lane=` and an `X-Project=` line (the job's project, written as the Overview's Agents tab shows it: `projects/demo-docs`; it is the job's Category on the Schedules tab), links them into `~/.config/systemd/user`, `daemon-reload`, `enable --now`, and prints the `git status` and the exact commit steps (the config repo: straight to main; salamander: a branch and pull request from a worktree given as `--checkout`; `relink` once it is deployed); it commits nothing, `--scope system` prints the `sudo` line for the owner, and a missing or invalid description, lane or project, an unknown repo, a missing script, a taken name or a repo with no unit folder (stackshot) is refused with the usage and nothing written. `list` shows our timers (name, repo, schedule, lane, project, in git). `set-project` writes (or replaces) `X-Project=` in an existing job's git file and prints what to commit (`contrib/backfill-job-projects.sh` runs it once for the jobs that predate the line). `check` is the gap watcher's pass: a timer of ours with no `Description=`, no `X-Model-Lane=`, no `X-Project=` or not in git; `--post` opens each gap once as a board item (`client.py post job-gap open`; its mover is the builder of the repo that owns the script) and closes it when the gap is fixed (`sala-unit-gaps.path` when a unit file changes, and `watch`'s tick, `watch --unit-gaps`, `SALA_UNIT_GAPS=off` to stop it) |
| `config` | effective configuration |

## Design notes
- **At most one master session, watched by a timer — optional since the operation queue.** With one, everything
  else is healed *from* a Claude session; the master is the one session a machine guarantees you can reach from claude.ai.
  Its identity is the tmux session name, so `/clear` or a resume inside it is not a fault. Keep it a dedicated operator
  session, not one you develop in. With none (`salamander master --unset`), the queue
  is the one driver, the watch keeps no master alive (it still revives any pane whose claude died) and the post-boot report goes to Slack.
- **`/feedback` is opened only when a draft is queued.** The CLI keeps drafts as files (`~/.claude/feedback/drafts/*.json`,
  `status: queued`); the drain checks the disk first, so a recycle leaves no `/feedback` turn in the panes that had nothing
  to send. `/exit` itself is unavoidable: it is the only clean shutdown.
- **Snapshots are event-driven, not periodic.** tmux-continuum's autosave rides the status-line refresh, which
  only ticks while a tmux client is attached; on a box driven through Remote Control it silently stops, and a
  reboot restores a days-old layout with every newer pane missing. `snapshot` (tmux hooks + the Claude Code
  SessionStart hook; `spawn` saves on its own) lands every change within seconds; keep a timer only as a net.
- **Resume by UUID, never `--continue`.** Panes share a cwd; "most recent conversation here" is ambiguous.
  Pane → conversation is resolved in order: live registry (`~/.claude/sessions/<pid>.json`) → the pane map
  (the ledger below) → pane title grep as a last resort.
- **The pane map is a ledger.** `~/.local/state/salamander/pane-map.tsv` (`tmux_session \t uuid \t name \t cwd`;
  `SALA_SIDECAR`) is sala's record of which conversation lives in which tmux session, and the only thing a reboot can
  resume dead panes from. It lived in tmux-resurrect's directory as `claude-pane-map.tsv`, with three columns, in
  older versions; the first `sala` after that moves it (log and `map-history/` with it), leaves a symlink at the old path
  and fills in the cwd column from the live registry, `$HOME` where nothing is live. Older
  versions rebuilt it on every save from what was alive, so the first save after a boot that brought back only part of the
  sessions dropped the other rows for good. Now only honored paths change it: `spawn`, `unpark`, `adopt` and
  `watch`'s re-add of the master row **add**; `rename` **renames**; `retire`, `close-shell` and `forget-row` are the only paths that **drop** a row.
  Absence never removes one: a crash, a force-quit, a dead claude or a missing tmux session leaves the row in place.
  The one change an observation may make is the **follow**: the live claude in a mapped session reports a different
  conversation than its row (a `/clear`, a hand `--resume`), and the row follows — `revive --save-map`, wired to
  resurrect's post-save hook, does only that. Every write goes through one function (`ledger_write`): a lock, a temp
  file next to the map, no empty map over a non-empty one, the previous map in `map-history/`, and one line per change
  in the ledger log (`pane-map.log` beside it: time, op, session, old → new, caller). A live session the map does not know
  is reported by `watch`, once, never added silently.
- **Sessions have an id of their own (phase 1).** A name changes and a conversation changes (`/clear`), so `sessions.json`
  (beside the pane map, [docs/session-registry.md](docs/session-registry.md)) gives each session a uuid4 that outlives both:
  name, aliases, lane, model, project, role and a list of the conversations it has had. `ledger_write` writes it after its own
  pane-map write has succeeded, under the same lock, and a failure there is a log line, never a failed map write; the pane map stays
  the authority; the heartbeat publishes a copy for stackshot and `sala sessions resolve` looks a row up (phase 3). Revert: `SALA_SESSIONS=off` or delete the file.
- **A recycle or reboot freezes the map.** The recycle driver (before its sweep) and `sala reboot` (at the pause step)
  write a frozen copy of the map next to it, with the owner pid, boot id, reason and time: the roster that run must
  bring back. While it stands, `spawn`, `rename`, `retire`, `close-shell`, `forget-row`, `unpark` and `adopt` refuse up front, and a follow observed
  meanwhile waits and is applied at the unfreeze — the end of the recycle driver (after its self-worker), the reboot's
  boot half, a dry run's end or a halt. A stale freeze (owner dead on this boot, a recycle's from an earlier boot, or
  older than 3 h) is cleared by `watch`, with a report.
- **Compare and restore.** At the end of a recycle sweep, and in the reboot's boot half after resurrect's restore and
  revive, the frozen roster is held against tmux: every session of it that is gone is recreated in its directory and
  resumed by uuid (`restore` under the hood; a conversation live anywhere is never resumed twice), and one post says
  "Recycle/Reboot: N sessions recreated", or 🚨 for any that could not be. A session that exists but runs no claude is
  revive's business as before. After a boot that was not a clean `sala reboot`, the post-boot report names the rows
  with no tmux session and `sala restore --missing` brings them back.
- **Dedupe guard.** A conversation live anywhere is never resumed a second time — two writers on one transcript
  corrupt it. Remote-Control-served sessions are the trap: they write no reconnection record, so a plain
  `--resume` of one silently forks a twin. `spawn --fork` copies the history into a new transcript instead.
- **Idle guard.** `/exit` is typed only when the registry says idle for ≥10 s and the session has nothing in flight —
  a `run_in_background` job, a Monitor or a background subagent leaves the main loop idle while work is in flight. What is in
  flight comes from the session's own Stop hook record (`hook stop`: the CLI's `background_tasks` at the end of its last turn),
  trusted only while the registry has not flipped since; it is exact where the two older checks guess (a long-lived child reads
  busy for ever, a job quiet for 2 min reads idle). Without a record for the current idle stretch (hook not registered, a turn
  interrupted since) those checks stand in: no child process, no task/subagent output written in the last 2 min. A job started
  with `setsid nohup` is seen by neither. A ready marker (`ready`) waives all of it: the session's own word. It does not waive the registry's own state: a ready pane whose turn is over but whose registry state is `shell` (background Bash loops still run) is not relaunched, it is deferred (*recycle*, above). A turn that
  starts after these checks (a message arriving) is caught by the mod, which refuses the exit while a turn runs: an /exit
  run mid-turn reaches the model as a queued prompt instead of closing the session. The pane is retried like any busy one.
  One task never counts: an artifact watch, the one Claude Code arms by itself when a session publishes an artifact
  ("live updates for artifact <url> (auto-armed on publish)") or one armed on request, whatever label the CLI gives it
  (2.1.296: auto-armed on publish, attached via /artifacts, watch requested, resume requested, re-armed on session resume,
  presence while editing via MCP, watch requested; auto-replies since stopped); neither the record nor the mod's exit check
  counts it. The relaunch leaves it as it is: `claude --resume` arms it again (labelled "re-armed on session resume" from
  then on), while a watch the session itself stopped comes back only on the owner's own message, so sala never asks a session
  to stop or re-arm one.
- **Effort re-pass.** `claude --resume` restores the model but not the effort; it is read off the transcript's
  last assistant turn and passed as `--effort`. A format change degrades to "no --effort", never to a failed resume.
- **Permission-mode re-pass.** `claude --resume` restores the permission mode its transcript recorded, not the
  settings' `permissions.defaultMode`. Every relaunch (recycle, revive, unpark, restore, the retry workers, and `spawn --fork`) passes that
  `defaultMode` as `--permission-mode` (`permission_mode_args` in `lib/common.sh`, appended by `resume_cmd`); read from the lane's
  config directory (subscription-2) or `$CLAUDE_CONFIG_DIR`, else `~/.claude/settings.json`. Unset, a missing or unparseable file, or a value
  `claude --permission-mode` does not take: no flag, as before (an unknown value is said on stderr). `claude -p` question resumes
  (`lib/question.sh`) choose their own mode and are left alone; the sdk lane's pane program is not a `claude` line.
- **No terminal-only prompts.** Nobody is watching a headless pane. Keys typed into a pane showing a modal
  (feedback-draft review, survey, permission dialog) are queued and fire when it clears — a queued `/exit`
  with no resume behind it. So drafts are sent at turn end by two hooks (`feedback mark`/`stop`) driving the `/feedback` panel
  with the transcript off; `recycle` drains any leftover before `/exit`, skips a pane still showing a prompt, and
  keeps waiting for its own pane's `/exit` rather than abandoning it. Keep `feedbackDrafts: quiet` and
  `feedbackSurveyRate: 0` in settings (`install.sh` checks both, and the hooks).
- **copy-mode swallows `send-keys`.** Every keystroke into a pane is preceded by leaving copy/view mode; text
  and Enter are separate sends.
- **Every message sala types is marked.** A message typed into a composer (spawn's orientation line for a mandate file, a text mandate) goes in as
  `<!-- sala --> …`, the marker at the start of the message's one line (a newline typed into the composer would submit):
  the CLI records a typed message with the same origin as the owner's own typing, and stackshot's quote-origin check refuses
  a quote attributed to the owner from a message that carries the marker (Mon Oct 12th 2026). Slash commands are typed bare (a
  marker would break them). A note or a cue arrives over the session socket and is recorded as a peer message, the hook's
  relaunch line as hook context: neither reads as the owner's.
- **Least-recently-active first.** `revive` orders panes by transcript mtime so the session you are most likely
  to return to is disturbed last. A recycle checks and closes panes in parallel but types the resumes in that order, a fixed gap apart: claude.ai sorts
  sessions by last event and a resume is one, so the list comes back stacked as it was.

## Telling every session something
`sala notice add "<text>" --from <you>` is for a line every Claude session on this box should see once and soon (a renamed lane, a
changed rule), without waiting for the next relaunch to load the new text. It is delivered by two hooks Claude Code runs anyway:

- **`salamander hook post-tool`** (PostToolUse, already registered on every machine) after the session's next tool call, and
- **`salamander hook prompt`** (UserPromptSubmit) at its next prompt.

Whichever comes first delivers the notice as additional context, `[sala notice <id> from <sender>] <text>`, several due at once in one
block, oldest first; the session is then marked as having had it, so it gets each notice exactly once. A tool call made inside a subagent
(its hook input carries `agent_id`) delivers nothing and uses nothing up: the notice waits for the session's own next call or prompt.
A session whose conversation started **after** the notice was created is marked as having had it without being shown it (it loaded the
current rules and memory at its start): its start is the later of the CLI's registry row for the process (`startedAt`) and sala's
session registry's first record of the conversation; a session whose start is unknown gets the notice. A hook never blocks or fails a
tool call: any error prints nothing and exits 0.

`hook prompt` needs this entry in `~/.claude/settings.json` (the machine spec registers it; `install.sh` says when it is missing; the
event takes no matcher):

```json
"UserPromptSubmit": [{"hooks": [{"type": "command", "command": "~/.local/bin/salamander hook prompt"}]}]
```

Without it a notice still arrives, at the next tool call, which is the more frequent of the two.

State is under `~/.local/state/salamander`: `notices.tsv` (id, created, sender, until, text; atomic writes under `notices.lock`),
`notices.seq` (the last id, so an id is never reused) and `notices-seen/<session id>` (the last notice id handled for that session).
Expired notices are pruned on `add` and by `watch`; with none left every `notices-seen` file goes, and the files of sessions that are
gone are pruned after a day. **Cost:** with no notice the hook is a glob test and one `-s` test, no process. With a notice up it reads
the first 512 bytes of the hook input with the shell's own `read` and compares `notices-seen/<session>` with `notices.tsv` by mtime
(`-nt`): still no process. Only a session that has not looked since the notices last changed starts one python (`lib/notice.py
deliver`), once. A notice is text any process of this user can write into every session's context, so it carries its sender and
`--from` is required; `tests/notice.sh` covers it.

## Hooks out
- **`SALA_POST_UPDATE_CMD`** runs after every CLI update attempt — `recycle --update`, `update --fleet`, `provision` —
  whether or not a version moved. sala exports the touched hosts as `SALA_UPDATE_HOSTS` (and `SALA_UPDATE_HOST` when
  it is exactly one) so the command can scope its own check; point it at whatever tracks versions (a dashboard's
  refresh-and-publish) — sala itself knows nothing about it. `SALA_WATCH_NOTIFY_CMD` / `SALA_NOTIFY_CMD` carry human-facing notices (Slack).
- **`SALA_POST_RECYCLE_CMD`** runs at the end of every recycle and clean reboot of this box, and again, with the same
  `SALA_RECYCLE_STARTED`, each time a retry worker or `watch` later relaunches a pane that recycle had skipped (not for a
  `revive --only` of its own or a dry run), detached, with `SALA_RECYCLE_KIND` (recycle|reboot), `SALA_RECYCLE_STARTED` (epoch),
  `SALA_RECYCLE_RESULT` (ok|partial) and `SALA_RECYCLE_SKIPPED` (tmux sessions still not relaunched); its output goes to the
  recycle (or reboot) log and never changes the result.

## One driver
`recycle`, and `update` whenever it would recycle this box, run only from the **master** pane (`SALA_MASTER`): a recycle
relaunches every pane including the invoking one, and two drivers race the same panes. From any other tmux pane the
command refuses and says to hand the cue to the master. Not enforced when not
inside tmux (a shell, systemd, cron), for `--dry-run` / `--check`, with `--not-master`, or when the master itself is not
live — that last case is allowed and announced, so a dead master never makes the box unrecyclable (`watch` normally
revives it first). **With no master configured** (Thu Oct 15th 2026) the queue holds the rule: a call from a
Claude session — a `claude` process among the caller's ancestors, or a pane that still names itself (`TMUX_PANE`) and runs
one (`claude_caller`) — is refused and pointed to `sala op <verb> … --from NAME --words "<the owner's words>"` (a verb the
queue has no shape for yet — `model`, `adopt`, `restore` — is refused with that said); a human's pane shell, a plain
shell, systemd (the watch and its units), cron and the resurrect boot hook (launched by tmux) pass as before, as do
`sala-test-*` targets, `--dry-run`, `--check` and `--not-master`. Until then a missing master let any pane run the verb
with a notice. The **operation queue**'s runner (`sala op`) is admitted in the master's place, master or no master: both
guards pass a caller whose cgroup names a `sala-op-<id>` unit (`op_unit_caller`), which is what the queue's one-at-a-time
runner is — the Bash guard hook (`lib/guard.py`) keeps its logic, so a session typing the raw command is denied as before (one
exception: `kill <pid>` of the claude of a throwaway that session started itself, found by the registry's `spawned_by`; it also denies `tmux new-window`, `split-window`, `respawn-pane`, `join-pane`, `move-pane`, `break-pane`, `swap-pane`, `swap-window`, `move-window`, `link-window`, `rename-session` and `new-session -t` aimed at another session on the fleet's server, a `TMUX_PANE` assignment in front of one, and a `=name` target with no colon; `docs/session-registry.md` lists what it does not read),
every deny now pointing to the queue's verb (`sala op update`, `sala op retire <session>`) — except a reboot, which is not
queued: its deny says the owner runs `sala reboot --go` and the session shows them `sala reboot --status` and waits for
their word (`master_guard` says the same to a session running `sala reboot` with no master) — with no pane exempt once there
is no master; the queue's own `claude -p` (the stuck handler, in a `sala-op-<id>-stuck` unit) is not
admitted by it.

Underneath the guard, a **recycle lock** (`flock` on `~/.claude/salamander-recycle.lock`) makes one driver a fact: whatever
relaunches panes — `recycle`, `update`'s local leg (before `claude update`), a direct `revive` (`--only`, `--self`), the
resurrect post-restore `revive` — takes it and holds it for the life of the driver it starts (the detached sweep plus the
invoker's self-worker; the fd is inherited, the kernel releases it when the last holder dies, so a lock never goes stale).
A second taker is refused with one line — since when, started by whom, the log — and exit code 75; `--dry-run`, `--check`,
`--save-map`, `--map-history` and the retry worker's re-runs never take it. `watch` skips a run while it is held (its
auto-update too; an auto-update already launched waits for it, up to 10 min, as does the boot hook's revive), `rename --sync`
waits for the next pass. Without `flock(1)` (macOS base system) nothing is locked and the taker says so once.

## Lanes
A **lane** is the account or key a pane's claude runs on (Tue Oct 13th 2026; `lib/common.sh` "lanes",
`lib/lane.sh`). Five of them are one env prefix on the launch line and nothing else; `sdk` (an
alias of `api` with client `claude-agent-sdk`) is a pane program in place of `claude`. Older lane words (`max`, `team`) are still read as `subscription-1` and `subscription-2` everywhere a lane is read (see *Display names and old words*):

| lane | on the launch line | needs |
|---|---|---|
| `subscription-1` | nothing — the claude.ai login in `~/.claude` (the line as it always was; the lane of every session nothing was recorded for) | — |
| `api` | `ANTHROPIC_API_KEY="$(cat <SALA_LANE_API_KEY_FILE>)"` and, when `SALA_LANE_API_WORKSPACE_FILE` exists, `ANTHROPIC_CUSTOM_HEADERS="anthropic-workspace-id: $(cat <file>)"` and `ENABLE_PROMPT_CACHING_1H=1` (the 1-hour prompt cache a long-lived pane gets on subscription-1; Claude Code writes the 5-minute one on an API key without it, so a wake after five idle minutes rewrites the whole context; a pane's line only, a one-shot job gets none); `--mcp-config <SALA_LANE_API_MCP_CONFIG>` when that file exists (stand-ins for the claude.ai connectors, which a key has no login for) | the key file, readable and non-empty, on a path that needs no shell quoting |
| `subscription-2` | `CLAUDE_CONFIG_DIR=<SALA_LANE_TEAM_DIR>` — a second claude.ai login in a directory of its own | the directory, signed in once by hand (`CLAUDE_CONFIG_DIR=<dir> claude`) |
| `bedrock` | `AWS_PROFILE=<SALA_LANE_BEDROCK_PROFILE, no default: empty = the lane is not set up>` `CLAUDE_CODE_USE_BEDROCK=1` `AWS_REGION=<SALA_LANE_BEDROCK_REGION, no default: empty = the lane is not set up>` `ANTHROPIC_BEDROCK_REGION_PREFIX=<global>` and the three pinned models `ANTHROPIC_DEFAULT_OPUS_MODEL` / `_SONNET_MODEL` / `_HAIKU_MODEL` (Bedrock global inference-profile ids, `SALA_LANE_BEDROCK_OPUS_MODEL` / `_SONNET_MODEL` / `_HAIKU_MODEL`) and `ENABLE_PROMPT_CACHING_1H_BEDROCK=1` (the 1-hour prompt cache a long-lived pane gets on subscription-1; Claude Code writes the 5-minute one on Bedrock without it, so a wake after five idle minutes rewrote the whole context; a pane's line only, `sala lane env` and `lane exec` leave it off, as a one-shot `claude -p` never reuses a cache entry and the 1-hour write costs more); `--mcp-config <SALA_LANE_API_MCP_CONFIG>` when that file exists, as `api`. Names and ids only: no secret is on the line (the profile's keys are read by the CLI from `~/.aws/credentials`, which sala only tests for the `[<profile>]` header line and never reads or prints). Set on that pane's launch line, never exported, never in settings. No Remote Control, as `api` | a `[<profile>]` header line in `~/.aws/credentials` (add it with your key-entry script), a profile that is not an administrator one (any name containing `admin` is refused), the `--mcp-config` file readable if it exists, the claude launcher |
| `aws-platform` | `env -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_FOUNDRY -u ANTHROPIC_AWS_API_KEY` first (Bedrock and Foundry win the CLI's routing over this provider, and a workspace API key wins over SigV4, so the line makes sure none is there), then `AWS_PROFILE=<SALA_LANE_AWSPLATFORM_PROFILE, no default: empty = the lane is not set up>` `CLAUDE_CODE_USE_ANTHROPIC_AWS=1` `ANTHROPIC_AWS_WORKSPACE_ID=<SALA_LANE_AWSPLATFORM_WORKSPACE_ID>` `AWS_REGION=<SALA_LANE_AWSPLATFORM_REGION, no default: empty = the lane is not set up>` and the three pinned models `ANTHROPIC_DEFAULT_OPUS_MODEL` / `_SONNET_MODEL` / `_HAIKU_MODEL` (the plain Claude API ids, `SALA_LANE_AWSPLATFORM_OPUS_MODEL` / `_SONNET_MODEL` / `_HAIKU_MODEL`) and `ENABLE_PROMPT_CACHING_1H=1` (the 1-hour prompt cache a long-lived pane gets on subscription-1; Claude Code writes the 5-minute one on this provider without it. It is the plain switch, not bedrock's `ENABLE_PROMPT_CACHING_1H_BEDROCK`, which the CLI reads only for the bedrock provider; a pane's line only, `sala lane env` and `lane exec` leave it off); `--mcp-config <SALA_LANE_API_MCP_CONFIG>` when that file exists, as `api`. Claude Platform on AWS is the Anthropic-operated API with AWS authentication and AWS billing, a service of its own beside Bedrock: another endpoint, the API's model ids, `CLAUDE_CODE_USE_ANTHROPIC_AWS` in place of `CLAUDE_CODE_USE_BEDROCK`. Names and ids only: no secret is on the line (the workspace id is not one). Set on that pane's launch line, never exported, never in settings. No Remote Control, as `api` | a workspace id of the form `wrkspc_` plus letters, digits or underscores in `SALA_LANE_AWSPLATFORM_WORKSPACE_ID` (empty until the workspace exists: the lane is refused with that said), a `[<profile>]` header line in `~/.aws/credentials`, a profile that is not an administrator one, the `--mcp-config` file readable if it exists, the claude launcher |
| `sdk` | `salamander sdk-pane <uuid> <session> [--model M] [--effort E]` — the api lane's key through the Agent SDK (`claude-agent-sdk`, `SALA_LANE_SDK_PIN`), which the API credit pays for while Claude Code on the same key is refused; the driver hands the key to the CLI the SDK spawns, nothing is on the typed line | the api lane's files, the `--mcp-config` file (required), `uv` on PATH, no refusal less than `API_CREDIT_RETRY_S` (6 h) old on the shared credit record (*The sdk lane*) |

The `$(cat <file>)` is run by the **pane's own shell** when it runs the line: the key is in that claude's environment and
nowhere else — not in what sala types, tmux's buffer, sala's logs, or any argv. The CLI picks its auth when the process
starts (a key before the stored login; a config directory keeps its own login) and the login in `~/.claude` is untouched
by a per-process key, so a switch is a relaunch with another env and never a re-auth.

**State, not config** (`~/.local/state/salamander/`): `lanes.tsv`, one `<tmux session>\t<lane>` row per session with a lane
of its own (`rename` moves the row, `retire` drops it), and `lane-default`, the lane of every session without a row
(`subscription-1` when the file is absent). Every launch path reads them: `spawn` (the default lane), the sweep's resume (recycle,
`revive`, the boot hook, `restore`, the retry workers, `watch`'s deferred relaunch), the self-worker and `unpark` — all
through `resume_cmd` — so a recycle brings an api-lane pane back on the api lane. The knobs (`SALA_LANE_*`) are in
`config.example`.

`sala lane` is the only thing that writes the state, and it relaunches through the machinery every relaunch uses, with
its guards (a busy pane deferred and retried, `SALA_NO_RELAUNCH` left alone, the invoking pane last, one driver at a time,
the master's pane when a Claude session asks): `sala lane <lane> <session>…` records, then `revive --force --only …` and
`revive --self` for the invoking pane; `sala lane <lane> --all` records every session and the default, then `recycle
--force` (a relaunch of every pane is a recycle, and the board hears of it as one); `sala lane default <lane>` only sets
the default. A lane whose prerequisites are missing is refused before anything is recorded. `--dry-run` prints what would
be recorded and relaunched and the *names* of the variables, never a value. On the api lane there is no Remote Control:
`watch` skips the bridge check and heal for a master running on it (one log line), and the reboot's boot half counts
such a pane as back once it is on its conversation.

**The lane line** (Wed Oct 14th 2026: a `revive --force --only` put a pane on the api default — it had no row, and only
its environment knew it ran on subscription-2). Every relaunch plan — the sweep's per-pane rows (recycle, `revive`, the boot hook,
the retry workers), `revive --self` and the recycle driver's self-worker — says `lane: <the lane the claude runs on now,
from its environment> → <the lane the resume line puts it on: its row, else the default>`, in the dry run and the real
run alike. When the two differ and **no row** records the intent, that pane is refused, not the sweep: a `not relaunched`
row naming both lanes and the fix (`salamander lane <running lane> <session>`, which records and relaunches it; or
`--lane-default` on `revive` / `recycle`, which accepts the default for every such pane in that run), given up at once in
the recycle's set (so it is in the post, never silently skipped) and not retried. A row wins as before: `lane: subscription-2 →
api` with a row of api is relaunched on api. A shell pane (after a reboot) runs on no lane (`lane: none → …`) and is
never refused; a claude whose environment cannot be read (`?`) neither; one in a config directory sala does not know
(`other`) is refused with `SALA_NO_RELAUNCH` as the fix. Until every by-hand pane has its row, a plain `recycle` leaves
those panes behind and says so: the `sala lane` table shows which ones (`RUNNING` differs from `RECORDED`/the default).

**The sign-in watch** (Wed Oct 14th 2026; a step of `watch`, `SALA_SIGNIN_ALERT`, default on; `watch --signin`
runs it alone). A lane's login lives in its config directory, and that directory holds one login: `/login` typed in one pane
(or `claude auth login` in a shell without `CLAUDE_CONFIG_DIR`) re-signs the whole lane, and a lane can sit on another
account unnoticed. Every `SALA_SIGNIN_EVERY` (5 min) the watch asks each login lane what it is signed in to (`claude auth
status --json` in the lane's directory — `subscription-1` in `~/.claude`, `subscription-2` in its own — with no API key in its
environment) and compares the answer with the table in `lib/common.sh` (`lane_expect`; config, never learned from a run:
`SALA_LANE_MAX_SUBSCRIPTION` and `SALA_LANE_TEAM_SUBSCRIPTION` (the expected plan name as the provider spells it; the variables keep the older lane names; empty means unconfirmed) with `SALA_LANE_TEAM_ORG=<your organization>`; the org is empty, meaning any, by default). The api lane's key must be on disk (looked at every tick) and, every
`SALA_SIGNIN_API_EVERY` (an hour), be accepted by the Messages API: one request of `max_tokens` 1 to the newest haiku the
API lists (one tiny `GET /v1/models` before it with the same key; a pinned `claude-haiku-5-5` only as the fallback when that
listing fails, and a 401/403 from the listing is the key refused; `SALA_SIGNIN_API_MODEL` set names the model instead), the
key and the workspace id read from the lane's files by the request itself, never on a command line; a 400 (the credit used up) is a key the API accepted, 401/403 a refused one, 429, 5xx and no network decide
nothing. A lane found on another account, not signed in, or with a refused or missing key gets one post — the lane, what was
expected and what was seen since when, and the fix: `CLAUDE_CONFIG_DIR=<its directory> claude auth login --claudeai` in the
web UI's Shell (open the link it prints, then paste the code back), never `/login` in a pane; to put one pane on another account, `sala lane <lane> <session>` — posted again only when
what is seen changes to another wrong state or after the lane was right in between, and "signed in correctly again" once
when it is. An unreadable look (no JSON, a CLI that hangs) neither alerts nor clears. `subscription-2` is watched whenever its
directory exists, `api` while its key file exists or a session's row or the default
is `api`/`sdk`. No email or id in a post.
State: `lane-signin.state` beside `lanes.tsv`.

**The settings-apply service** (Wed Oct 14th 2026; `lib/settings-apply.sh`; a step of
`watch`, `SALA_SETTINGS_APPLY`, default off (set `on` in the config to enable the tick); `watch --settings` runs it alone; `sala settings-apply` shows the state). A
Claude Code settings change used to wait for the owner's own shell or the next fleet provision, because the auto-mode
classifier refuses a session that edits the settings it runs under. Every tick fingerprints the spec (`SALA_SETTINGS_INPUTS`
under `SALA_SETTINGS_SPEC_DIR`: the spec files and the provision step scripts, read from this box's checkout of the spec's repo (`SALA_SETTINGS_SPEC_DIR`, `SALA_SETTINGS_INPUTS` and `SALA_SETTINGS_STEPS` are empty by default: no spec, nothing to apply),
which its own sync keeps current) and, when it changed, launches one `settings-apply --run <boxes>` as the transient unit
`sala-auto-settings` for this box and every `SALA_FLEET_HOSTS` box behind it that the heartbeat store says answers ssh (a
box that failed is tried again every `SALA_SETTINGS_RETRY`, an asleep one once the store says it answers). The run is
`provision --quiet --check --only <SALA_SETTINGS_STEPS>` — the settings-class steps the config lists (none by default; `config.example` shows the shape): steps that merge settings or tighten them (a settings merge, deny entries, hooks), never a step that loosens a permission: the allow rules and the like stay the owner's — then the apply on the boxes
whose check found a settings step drifting (`repo` alone is not drift), with `~/.claude/settings.json` backed up beside
itself first (`settings.json.bak-sala-settings-<stamp>`; the steps keep their own `.bak-provision-*` where they make one)
and the key-by-key diff logged after (`~/.claude/salamander-settings-apply.log`: one line per box and run with the spec
fingerprint and the config-repo commit, the steps' own words, then `path: old → new` per key, a list item as `+`/`-`,
secret-named keys masked); a settings.json that no longer parses is put back from the backup and the box is a failure.
No CLI update, no recycle, no relaunch: panes take the settings at their next relaunch, as before. A box's first look is
dry ("would apply …", recorded; applied from the next spec change on), so switching the service on, or adding a host,
changes nothing by itself. A failed box is posted once per fingerprint in the step's own words; a box still behind
`SALA_SETTINGS_STALE` after the change is posted once; a quiet apply is log-only. `provision --quiet` (with `--only` or
`--check`) is the run's provision with no fleet post, and `SALA_PROVISION_RESULT_DIR` keeps provision's per-box STEP
lines for it. State: `settings-apply.state` in sala's state directory; a second `--run` while one runs exits 75.

**The rescue** (Wed Oct 14th 2026; `lib/lane.sh` "THE RESCUE", `lib/revive.sh` "THE RESCUE"). The master runs on
a lane. When that lane's usage is out or its account is dead the master cannot act, and the session that
could move it is not the master: `sala lane <lane> <master>` from there needed `--not-master`, and the master's own
background-task rows held the relaunch. `salamander lane --rescue <lane>` is that move, sanctioned. It moves only the
master (`SALA_MASTER`), from a session that is not the master (from the master's own pane it points at the ordinary
switch, which the self-worker runs once that pane is idle). It refuses while the master's current lane *looks fine to
sala*, by three readings sala already has and nothing else (no model asked, no request made; `lane_out` in
`lib/common.sh`): `lane_check` (the lane cannot launch at all), the sign-in watch's last look (`lane-signin.state`: not
signed in, another account, the key refused), and the limit watch's state (`salamander-limit.json`: the master's own pane
stopped on the lane is decisive whatever the limit; another pane's stop counts only for a lane-wide limit — weekly,
5-hour, credit, workspace, rate — since one model's limit stops only that model's panes). An error sala has not seen yet
(the watch confirms a stop after `SALA_LIMIT_CONFIRM`) is what `--force` is for: it moves the master anyway and the log
says so. The target lane must launch (`lane_check`) and must not be out by the same readings (`--force` overrides that
too). Then the switch's own steps: the recycle lock, the row in `lanes.tsv`, one `rescue` line in `lanes.log` (when, who,
from → to, why), and the direct sweep of the master's pane — `revive --force --only <master> --not-master --rescue` — so a
stale background-task row does not hold it. `--dry-run` prints the plan and the sweep's verdict and writes, logs and
relaunches nothing. The `sala lane` table warns under its rows when the master sits on a lane that is out, naming the
lane, why, the rescue and the lanes sala sees nothing wrong with.

*A stale background-task row* (`--rescue` on `revive --only`, `revive --self` and `sala lane <lane> <session>…`). The
CLI's task registry keeps a row for a background shell stopped by hand or a subagent long gone, so its `/exit` opens the
"Background work is running" dialog over nothing; the Stop hook's record (`busy_state`) and the mod's exit check are
copies of the same registry. Without the flag every relaunch keeps its gates: the dialog is cancelled with Esc (unless
every row is a scheduled task), the record skips the pane, the mod refuses. With `--rescue`, when **no child process runs
under the pane's claude** (`work_children`, the one live reading sala has), the dialog is confirmed — Enter on its
selected "1. Exit and stop tasks", the key the scheduled-task case already presses, after the dialog's text is read off the
screen — and the record and the mod's refusal are read as stale by the same test; each pass-over is said in the sweep's
output and the mod log. A live child keeps every refusal; a scratch file written in the last 2 min too; a turn running,
a draft, a terminal prompt as before. Never for a recycle (`recycle --rescue` is refused): a whole fleet confirmed blind
is not a rescue. The limit of the test: a background subagent runs in the CLI's own process and shows no child, so a
rescue confirms its row too; that is the operator's call behind the flag, and the reason it is one.

### Lane fields
What a lane *is*, apart from how it launches (Thu Oct 22nd 2026; the lanes page,
"Lane fields"). `sala lane --list` prints one aligned row per lane, `sala lane --json` the same as JSON (and the no-argument
table opens with it). Fields only: nothing here launches a pane or changes a lane. The same fields serve any provider, so a
Codex or Gemini lane later is one more row.

| field | holds |
|---|---|
| `id` · `label` | what commands take (`subscription-1`, `subscription-2`, `api`, `bedrock`, `aws-platform`; `max` and `team` are read as the first two) · how it is shown, **the display name**, one setting per lane and the only place it is spelled (Subscription 1, Subscription 2, API, Bedrock, Claude Platform on AWS; *Display names and old words*) |
| `provider` | ids after the Vercel AI SDK: `anthropic` `openai` `google` `google-vertex` `amazon-bedrock` `azure` |
| `client` | `claude-code` `claude-agent-sdk` `codex` `gemini-cli` |
| `org` · `project` | the paying organization · its division (optional: an Anthropic workspace id, an OpenAI project, a Google Cloud project) |
| `billing` · `payment` · `plan` | `subscription` or `usage`; for usage `prepaid` or `postpaid`; a subscription's plan (a plan id such as `chatgpt_plus` or `google_ai_pro`; empty until the config names it) |
| `account` · `credential` · `region` | the sign-in email · login, key file, AWS or Google Cloud profile (optional) · region (optional) |
| `status` | `active` · `inactive` · `not set up` |

Defaults (the account and org fields read `unconfirmed` until the config names them with `SALA_LANE_<ID>_ACCOUNT` / `_ORG`): `subscription-1` (anthropic, claude-code, subscription, plan `unconfirmed`, active), `subscription-2` (anthropic, claude-code, subscription, no plan, inactive),
`api` (anthropic, usage, prepaid, org `unconfirmed`, inactive), `bedrock` (amazon-bedrock, usage, postpaid, org `AWS account`, region empty until `SALA_LANE_BEDROCK_REGION` is set, status derived: active while `lane_check bedrock` passes, else not set up), `aws-platform` (anthropic, usage, postpaid, the AWS-linked Anthropic organization, region empty until `SALA_LANE_AWSPLATFORM_REGION` is set, the workspace id as its project, status derived as bedrock's). The table is in
`lib/common.sh` ("THE LANE FIELDS"); every field is overridden by config as `SALA_LANE_<ID>_<FIELD>` (`config.example`), and a
value outside its list is flagged under `--list`. The fields describe; the lane word still decides how a pane launches.
`sdk` is the old sdk lane folded into `api`: the word stays accepted wherever it was (rows in `lanes.tsv`, `sala lane sdk
<session>`) as an alias, with client `claude-agent-sdk`, and `SALA_LANE_SDK_PIN` and
`SALA_LANE_SDK_CMD` are that client's settings (`SALA_LANE_SDK_UNTIL`, its date gate, is gone). `lanes.tsv` keeps its format (`<session>\t<lane>`); no row is rewritten by
any of this. A row that names a lane sala does not know (an unknown word) is shown with a warning under `sala lane` and launches on
the default.

### Display names and old words
The two login lanes' codes are `subscription-1` and `subscription-2`; the older words `max` and `team` are still read as aliases.
Two things follow, and each has one home.

- **The display name is one setting per lane, and nothing else spells it.** It is the lane's `label` field: `SALA_LANE_<ID>_LABEL`
  in the config (`SALA_LANE_SUBSCRIPTION1_LABEL`, default `Subscription 1`; `SALA_LANE_SUBSCRIPTION2_LABEL`, default `Subscription 2`; the others
  default to API, Bedrock and Claude Platform on AWS; `config.example`). Bash reads it with `lane_label <code|old word>`
  (`lib/common.sh`), Python with `lanewords.lane_label` (`lib/lanewords.py`, which asks sala), and everything sala shows goes
  through one of the two: its messages, `--help` and usage text, sala-web (pane titles, status lines, the details page), the
  briefing and the Slack posts. A login's own plan names are not lane names and stay as the provider spells them: a login's
  `subscriptionType`, and the plan ids of the plan field.
- **The old codes are words for the new lanes.** `max` is read as `subscription-1` and `team` as `subscription-2`, as
  `awsplatform` is read as `aws-platform`, wherever a lane word is read: a typed argument, `lanes.tsv`, `lane-default`,
  `lane-state.tsv`, `lane-home.tsv`, a job or unit definition (`X-Model-Lane=`), the registry, `SALA_JOB_LANE`,
  `SALA_LANE_FALLBACK`, a queued `sala op` marker, the sign-in and limit state. A read changes no file; a new write records the
  new code (write-on-touch: a file is never rewritten just to change a word). `sala lane --migrate` still moves
  only `awsplatform`. The config variables keep their names (`SALA_LANE_TEAM_DIR`, `SALA_LANE_MAX_SUBSCRIPTION`, ...); the
  field overrides also take `SALA_LANE_SUBSCRIPTION1_*` and `SALA_LANE_SUBSCRIPTION2_*`.

`sala lane names [--json] [--write]` prints the table for anything that has to show a lane: one line per lane, `code`, display
name and old words, tab-separated; `--json` prints `{"lanes":[{"code":"subscription-1","display":"Subscription 1","aliases":["max"]}, ...]}`
(every known lane, `aliases` empty when it has none). `--write` keeps the same JSON in `$SALA_STATE_DIR/lane-names.json`, and so does `sala watch`, but only on a tick that finds the file
missing, the config file newer than it or `lib/common.sh` newer than it (three bash tests, no process); it is written atomically and only when it changed, so stackshot reads the file instead of running
the command. The interface is in `docs/stackshot-contracts.md`.

### The dormant record
One record per lane, active or dormant, with a reason and since: plain shell, no
Claude turn. `lane-state.tsv` in the state directory beside `lanes.tsv`: `lane`, `state` (`active`|`dormant`), `reason`, `since`
(ISO, UTC), `posted` (when the episode's one post went out), `by` (`signal` or `hand`); keyed by the lane id from the lane table
(`sdk` is `api`'s word), so a new lane needs nothing here. No row, or no file, is active. Written under its own `flock`, a temp
file and `mv` (as `lanes.tsv` is), one `lanes.log` line per change (`dormant`, `active`). The watch keeps it, from detections it
already makes (no new network call, never a test call to find out whether a lane works):

| lane | goes dormant when | comes back |
|---|---|---|
| `subscription-2` | the sign-in watch's verdict is wrong (not signed in, no subscription, another subscription or organization: "no seat"), or sala-web's saved usage answer says `refused` (HTTP 403, newer than the lane's last change) | by itself, at the daily look (`SALA_LANE_REVIVE_EVERY`, 86400 s): the sign-in check the watch makes anyway is right again; a line in the watch log |
| `subscription-1` | the same verdict is wrong: the login no longer reports the subscription it expects (the configured plan) | the same |
| `api` (and `sdk`) | the limit watch has a pane stopped on "Credit balance is too low" (the record it already reads); since = that stop's first error | only `sala lane active api` |

A lane set by hand (`sala lane dormant <lane> [--reason …]`) is held until `sala lane active <lane>`. While a lane is dormant:
the web Overview card keeps its head (the lane pill and plan name) with one line under it (`No seat since <date>`, with a Dormant chip beside `Details ›`) and asks nothing; spawn's picker (the CLI's
list of lanes, the web form) leaves it out and `spawn --lane <lane>` is refused, as is a spawn whose default lane is dormant;
`sala lane <lane> <session>`, `lane <lane> --all`, `lane default <lane>` and the rescue refuse to move onto it in plain words;
`sala lane` shows it with its reason and since; `lane_out` counts it out. The sessions still on it are posted once per dormant
episode (`ld_post_tick` in the watch; "Subscription 2: no seat since …, N sessions are still on it; moving them is your call") and stay
where they are when the lane has no usable fallback (or `SALA_LANE_FALLBACK_AUTO` is off); otherwise the lane fallback moves them
(*The lane fallback* below) and its own notice replaces that post. The record itself relaunches, moves and stops nothing. **Not verified:** what the live `claude auth status --json` prints for
a subscription-2 directory whose seat was removed (every shape other than loggedIn + the expected subscriptionType + the configured org counts as wrong), and whether the
usage endpoint answers 403 rather than 401 to a seatless login (a 401 stays "sign-in expired").

### The lane fallback
Sat Oct 31st 2026. A lane that goes dormant is moved to a live fallback automatically: its sessions move to the fallback on their own
and stay there until the owner or a session moves them back. Code: `lib/common.sh` ("THE AUTOMATIC LANE FALLBACK"), `lib/lane.sh` (`lane fallback`, `lane dormant`, `lane exec`),
`lib/op.sh` (the verb), `lib/watch.sh` (`ld_fallback`); test `tests/lanefallback.sh`.

- **The map.** `SALA_LANE_FALLBACK="subscription-1=bedrock subscription-2=bedrock aws-platform=bedrock api=bedrock sdk=bedrock bedrock=subscription-1"`
  (config; `<lane>=none` or no pair: no fallback). One hop: a fallback that is itself dormant is not followed to its own.
  The fallback is used only if it is active and ready (not dormant, `lane_check` passes, nothing out); if not, nothing moves
  and one line says why: on the watch's one dormant post ("not moved automatically: …") and from `lane dormant` by hand.
  `SALA_LANE_FALLBACK_AUTO=off` turns the automatic parts off (the move on dormancy and the jobs below); `lane fallback`
  by hand keeps working.
- **The trigger.** A lane turning dormant, by the watch's own detection or by `sala lane dormant <lane>` by hand (not with
  `--no-fallback`), queues ONE operation: `sala op lane fallback <lane> --from sala-watch --words "<the standing words of the fallback>"`. The queue is the normal path for a guarded fleet verb (the runner is a `sala-op-<id>` unit with no Claude
  above it, so the guards pass), it runs the plan at queue time and refuses what has no usable fallback, and it gives one
  result notice. A lane that was already dormant before this shipped is not moved on its own: `sala lane fallback <lane>`.
- **The move.** Every session whose running lane is the dead one (recorded on it, or on "(default)" while the default is
  that lane) is recorded on the fallback and relaunched at its next idle moment through the ordinary switch
  (`lane <fallback> <sessions…>`: `revive --force --only`, never a pane mid-turn). The master (`SALA_MASTER`) moves last, by
  the rescue (`lane --rescue`), once the first sweep has let go of the recycle lock. If the default lane is the dead one,
  it switches too. A session of any other lane is left alone.
- **The model.** A session on a Fable model moved onto bedrock runs `opus` (Opus 5.5) there, because Fable fails on bedrock
  (`SALA_FALLBACK_NO_FABLE`, `SALA_FALLBACK_FABLE_MODEL`). The override goes in `models.tsv` like any `sala model`; moving back
  restores nothing.
- **Stay.** Nothing moves a session back when the lane is active again. `lane-home.tsv` (state directory: session, home lane,
  when, the model it had before or `-`; the key `(default)` is the default lane's) keeps where each came from, the first home
  standing; `sala lane` shows a HOME column for a session off its home (and the default line says so) with the way back:
  `sala lane <home> <session>` (a switch onto the home clears the row), `sala lane default <home>`. A retire drops the row;
  a rename carries it.
- **Jobs.** A sala job (a systemd user timer that runs `sala lane exec <lane> -- …`) whose lane is dormant runs on the
  fallback while the lane is dormant: decided at run time in `lane exec`, one stderr line when it does (or when there is no
  usable fallback and the job runs on the lane as it is). No unit file is rewritten.
  `lane exec <lane>` (`subscription-1` too) always starts the job with every other lane's variables unset, never blanked (docs/units.md).
- **One notice.** The operation posts ONE Slack notice for the batch: the dead lane, the fallback, each session moved and
  any model change (and a session that could not be moved, named). Nobody is told in an inbox: `from=sala-watch` is no session.
- **Dry run and by hand.** `sala lane fallback <lane> --dry-run` prints the plan (the sessions, a Fable session's model change,
  the master last, the default, the jobs) and writes, queues and relaunches nothing. `sala lane fallback <lane>` is the real form
  for a person (it needs the lane to be dormant; exit 4: no usable fallback, nothing recorded).

### The back agents' lane rule
Thu Nov 5th 2026. A standing rule for the background agents that keeps them off a login lane near its weekly limit, and brings them
home when the limit resets. **Off by default** (`SALA_BACK_LANE_RULE=off`: nothing is read or moved). Code: `lib/common.sh` ("THE BACK AGENTS'
LANE RULE", `back_lane_tick`), `lib/watch.sh` (`back_lane_run`, `watch --back-lanes`), `lib/spawn.sh`; test `tests/backlane.sh`.

- **Who.** The live background agents: registry rows with role `back` and no side session, with a tmux session, not the master and
  not `SALA_NO_RELAUNCH`. A front agent, a side session, a job (`lane exec`, `sala job`) and the default lane are never touched, and a
  background agent on a lane outside the order (api, subscription-2) is left where it is.
- **The order.** `SALA_BACK_LANE_ORDER="subscription-1 aws-platform bedrock"`: home, second, third.
- **Step 1, off home.** The home lane's "This week" limit (sala-web's saved usage answer, `quota-<lane>.json`; the model-scoped weekly
  limits, "Fable this week", are never read) reaches `SALA_BACK_LANE_THRESHOLD` (90) percent: the background agents move to the second lane.
- **Step 2, on to the third.** A pane running on the second lane is stopped on its cap (the limit watch's record: a workspace or billing stop,
  after the move): they move to the third lane.
- **Step 3, home.** The home lane's weekly window resets (a fresh reading in a later window, under the threshold): every background agent in
  the order moves home, wherever it stands.
- **The move** is the ordinary one: `sala op lane <lane> <sessions…> --from sala-watch --words "$SALA_BACK_LANE_WORDS"` (the words are the
  owner's rule, quoted, from the config), so a busy pane is deferred and retried, and the operation posts ONE notice when it is done.
- **Once per weekly window.** The state file (`SALA_BACK_LANE_STATE`, default `back-lane.state` in the state directory) holds the lane the
  rule has them on and, per step, the window it fired in; a second tick in the same window queues nothing.
- **A reading that cannot be trusted moves nobody:** missing, failed (`errorKind`), older than `SALA_BACK_LANE_MAX_AGE` (1800 s), without a
  "This week" percent or reset time, or already over. A dormant home lane moves nobody. sala-web refreshes that file only when something
  asks its `/api/quota`, so a pass that finds the home lane's reading missing or older than half the max age first asks the local sala-web
  with a plain GET (curl, 5 s timeout, over sala-web's unix socket by default; `SALA_BACK_LANE_REFRESH_URL` sets a socket path or an http(s)
  base URL, or `off`; at most every `SALA_BACK_LANE_REFRESH_EVERY` s, waiting up to `SALA_BACK_LANE_REFRESH_WAIT` s for the file) and reads
  it again. The token stays in the web app: sala makes no call to Anthropic and handles no credential; a failed or slow call leaves the
  reading stale and nobody moves. `--dry-run` says when it would refresh and asks nobody. A target lane that is dormant or cannot launch is not moved onto: one notice per window and step, the state unchanged, a later
  tick moves.
- **Fable.** A Fable background agent is not moved onto a lane in `SALA_FALLBACK_NO_FABLE` (bedrock): it stays where it is and the
  notice names it. The rule does not change a model.
- **Spawn.** A background agent spawned while the rule has them off home launches on the rule's lane (recorded like `--lane`; `--lane`
  wins; a front agent and a side session are not the rule's).
- **Dry run.** `sala watch --back-lanes --dry-run` prints what a pass would do (every outcome, idle ones too) and queues and writes nothing.
  To stage a step without live state, point it at fixtures: `SALA_WEB_STATE_DIR` (a folder with a `quota-subscription-1.json`),
  `SALA_BACK_LANE_STATE` (a file) and `SALA_LIMIT_STATE` (a limit-watch state with a stopped pane), with `SALA_BACK_LANE_RULE=on`.

### The sdk lane
Wed Oct 14th 2026: the API credit on the key pays for Agent SDK
calls on the key and refuses anything sent as Claude Code — the api lane's
`claude` with the key gets "credit balance is too low" — so the only way a pane spends it is the real SDK. The `sdk` lane
does that without pretending: `resume_cmd` types `salamander sdk-pane <uuid> <session>` into the pane (`lib/sdk-pane.sh`),
which runs `contrib/sdk-pane/driver.py` under `uv run --quiet --no-project --with claude-agent-sdk==<pin> python -I`.
The driver starts the CLI through `ClaudeSDKClient` on the conversation (`--resume`), with sala's own claude launcher as
the CLI (so its version is the fleet's), the user settings (`setting_sources`: hooks → sala's busy record; plugins → the
mod; the auto permission mode), the api lane's `--mcp-config` (an SDK session has no claude.ai connector) and Claude Code's
own system prompt. The key and the workspace id are read from the api lane's files by the driver and go only into that
CLI's environment; `CLAUDE_CODE_ENTRYPOINT=sdk-py` is set by the SDK, never by sala (a CLI dressed up as the SDK would
misreport its usage). The CLI registers in `~/.claude/sessions` as every pane's claude does and takes inbox lines (cues,
stackshot, SendMessage) as turns by itself; the driver is the screen: the turn's messages above, a ❯ box at the bottom
(a rule, `❯ <typed text>`, a rule — what sala-web's input box and sala's draft check read), Enter sends, `/exit` leaves.

To sala the pane is a claude pane: the wrapper renames itself `sala-sdk` (never a shell's name, which the sweep,
`exit_wait` and `resume_send` treat as "a shell sits here"), `proc_lane` reads `sdk` from the CLI's environment,
`check_pane` sweeps it with the same gates (the registry's idle, the Stop hook's record, a draft on the ❯ line), `/exit`
is typed into the box, and the resume is the sdk-pane line again. The mod is asked first, as for any pane, and its gates
hold (a draft, a turn, work in flight), but the `/exit` it runs on "ok" ends nothing in a CLI the SDK drives (no
interactive session to leave), so `pane_exit` types `/exit` into the box after the ok: the driver disconnects, the CLI, the
driver and the wrapper end, and the pane is at its shell. No Remote Control, as on api. `sala lane sdk <session>`
moves a session onto it like any lane (the dry run names the files and the variables, never a value); `spawn` on a default
of `sdk` is refused (spawn on another lane, then `sala lane sdk NAME`). **The credit record** (Sun Nov 1st 2026; replaces a
date gate): there is no way to read the key's credit balance, so the refusal is the signal, kept in one
file every job that may spend the key shares (sala's briefings, the sdk lane, other tools on the box):
`${XDG_STATE_HOME:-~/.local/state}/api-credit/state.json`, `{"refused_at": <epoch seconds>, "by": "<job>", "detail": "<first 200
characters of the refusal>"}` (directory mode 700; written by `lib/api_credit.py` with a temp file and a rename; no file = no known
refusal). The key is used while the file holds no `refused_at` within the last `API_CREDIT_RETRY_S` seconds (default 21600, 6 hours); a
refusal with "credit balance" in it (any case) writes the file and the run falls back to the subscription lane
(`subscription-1`); a call that works removes it. So the key is tried again six hours after a refusal, and a top-up is found without
anyone telling sala. `salamander lane` shows the lane as not ready while a refusal is fresh, and says when and by what job. **On the
sdk lane**: `lane_check sdk` refuses while a refusal is fresh; a row of `sdk` then launches on `subscription-1` (`lane_for_session`; one
`fallback` line per relaunch in `lanes.log`; the row stays until `sala lane subscription-1 <session>` clears it, and the table says so),
and the wrapper checks the record itself too, so a pane program typed during that time runs the subscription-1 line in its place. A
turn the credit refuses (an assistant message with error `billing_error`, or "credit balance" in an error result or the CLI's
stderr): the driver writes the record and exits 3, the wrapper rewrites the row to `subscription-1`, posts once in plain words (the
session is back on the subscription-1 login, why, and `salamander lane sdk <session>` to come back) and runs the
subscription-1 line in the pane at once; the last message may need to be sent again. A turn that ends without an error removes the
record. A CLI that dies leaves the pane at its shell with a line; the next revive resumes it as any shell pane.
Knobs: `API_CREDIT_RETRY_S`, `SALA_LANE_SDK_PIN`, `SALA_LANE_SDK_CMD` (tests), `SALA_LANE_SDK_NOW` (tests' clock for the record).

## Models
A session's **model and effort** can be recorded (Wed Oct 14th 2026; `lib/common.sh` "models",
`lib/model.sh`). Without a record every relaunch takes both from the conversation's own transcript (the newest real turn's
model family as `--model`, the prevailing effort as `--effort`; `resume_cmd`), so a pane could be moved only by typing
`/model` into it, and the next relaunch followed whatever the transcript last said. A record wins over the transcript at
every relaunch: the model always, the effort when one is recorded (`-` keeps the transcript's).

**State, not config** (`~/.local/state/salamander/`): `models.tsv`, one `<tmux session>\t<model>\t<effort or ->` row per
session with a model of its own (`rename` moves the row, `retire` drops it), written atomically under its own lock, and
`models.log`, one line per change, and `model-inplace.tsv`, what a live claude was switched to in place (below). `sala
model` is the only thing that writes them, and moves the pane the way `sala lane <lane> <session>` does: the row under the
recycle lock first, then either the in-place switch below or `revive --force --only <session>` (or `revive --self` for the
invoking pane), with the same guards (a busy pane deferred and retried, `SALA_NO_RELAUNCH` refused, the master's pane when
a Claude session asks). `--dry-run` writes nothing and relaunches nothing: it prints the row it would record and the path
that applies (*would switch in place* or *would relaunch*, with the reason, then the sweep's verdict). A model id is typed unquoted onto the launch line, so only lowercase letters, digits, dots and
dashes after `claude-` are taken (a `[1m]` suffix would be a glob to the pane's shell).

**Through the operation queue** (Sun Oct 25th 2026; a verb to change an agent's model and effort, self-modification included): `sala op model <session> <model> [--effort <level>] --from NAME --words "<the owner's
words>"`, or `sala op model <session> --clear …`; since Thu Oct 29th 2026 (so that a batch of model changes does
not wake a front agent once per session) also `sala op model <model> [--effort <level>] <session>… --from NAME --words "…"`
for several sessions as ONE operation (and `sala op model --clear <session>…`). **Which shape:** a first word that is a model
(`opus`, `sonnet`, `haiku`, `fable`, or `claude-…`, `model_batch_shape`) is the many-session form; any other first word is the
session of the single-session form, which is unchanged. The two corner cases: `<session> --clear` is always the single form
(a session literally named `opus` is cleared that way), and a `claude-…` first word that names a live tmux session followed by
a model is read as that session; a family alias is never read as a session name. All the sessions are checked before anything
is queued (an unknown one refuses the whole operation, naming it; the plan is each session's `model … --dry-run`). When it
runs, each session goes through the single switch in turn under ONE recycle lock (in place when idle with an empty input box,
else recorded for the relaunch), the asking session last, and the panes that need a relaunch are relaunched TOGETHER by one
`revive --force --only A --only B …` sweep, as `lane <lane> <session>…` does. The result is ONE notice for the batch: one
Slack post and one line into the asker's inbox, a line per session under the summary (`RESULT` lines printed by `lib/model.sh`,
kept as `detail=` lines on the marker). A failed session does not stop the others; the operation then ends 🚨 stuck, the
summary naming the failures, without the one-off `claude -p`. For example (three sessions, in place on one, relaunch on two):
```
[sala op 1761750000-4242] salamander model haiku --effort high sala-a sala-b sala-c — done: Revive …: 2/2 relaunched.
  - sala-a: switched in place to haiku/high
  - sala-b: relaunch started on haiku/high (a busy pane is retried until it is idle)
  - sala-c: relaunch started on haiku/high (a busy pane is retried until it is idle)
```
A Claude session's raw `sala model <session> …` is refused by the guard
(`master_guard`) with the pointer to the queue; the table form, `sala model` with no argument, is read-only and stays open.
The shape is checked at queue time with the same functions `sala model` uses (`model_valid`, `effort_known`), and the plan is
`model … --dry-run` (an unknown session refuses it before anything is queued); `--record-only`, `--not-master` and `--dry-run`
are not queue arguments. The runner takes the recycle lock itself, like `lane`, and a second operation of another verb
naming the same session is refused. The asking session may name itself: the queue's unit has no pane, so it moves the
session like any other (in place once it is idle, else `revive --force --only`; a busy pane is handed to the retry worker and
relaunched once idle), and `op` prints "this pane will have its model switched once it is idle" when the target is the
asking session. The
result (✅ done or 🚨 stuck, one Slack post and one line to the asking session's inbox, which arrives after its relaunch)
follows the other relaunch verbs; `--clear` relaunches nothing.

**In place first.** A pane that is idle with an empty input box keeps its
conversation process: `sala model` types `/model <model>` (and `/effort <level>`) into its composer through `tui_send`,
the record already written, and no relaunch follows. The gate (`model_inplace_gate`, lib/model.sh): `SALA_MODEL_INPLACE`
on (default), a claude running in the pane, not the command's own pane (that one is mid-turn), not the sdk lane (no
composer), `is_idle` says idle (unknown is never idle), no dialog on the screen, the input box empty. Anything else, and
any failure after the first keystroke, is the relaunch above, with the reason printed. `/model` opens a *Switch model?*
dialog when the model differs from the last turn's: Enter is sent only while the screen shows exactly that, once; any other
dialog gets an Escape and counts as a failure. The switch is verified by a new *Set model to* line (and *Set effort level
to* for `/effort`) on the pane. Each of those commands saves the lane's **default** in its `settings.json` (the top-level
`model`, `modelSettings.<id>.effortLevel`), which would move every session started later, so those keys are snapshotted
before the first keystroke and put back afterwards, on the failure path too: compare-and-restore, re-reading the file so a
key somebody else changed meanwhile is kept, an atomic write (temp file beside it, fsync, its mode, rename), the file's
other keys and layout untouched, no write at all when nothing differs. The file is the pane's own: the `CLAUDE_CONFIG_DIR`
of its claude (the subscription-2 lane's directory), else `~/.claude`. All of it runs under the recycle lock the record is written
under. `model-inplace.tsv` remembers what a live claude was switched to (its command line no longer says), so the same
request again is left alone and the table marks the pair with a star. The asking session, from the queue's runner, is
waited for (`SALA_MODEL_INPLACE_ASKER_WAIT`, 90 s) to end the turn that queued the switch, then switched like any idle pane.
`SALA_MODEL_INPLACE=off` brings back the relaunch alone. Knobs: `SALA_MODEL_INPLACE_WAIT` (20 s a typed command has to
show its line), `SALA_MODEL_INPLACE_SETTLE` (1 s the CLI is given to finish its own settings write before they are put back,
and again before the check). Tested against a fake claude (`tests/modelinplace.sh`) shaped by a probe of 2.1.310.

**`--record-only`** writes the row and relaunches nothing (no `revive`, no self-worker): the session comes onto the
record at its next relaunch, whatever starts it (a recycle, a lane move, the boot hook, a restore). Meant for the panes
of a per-pane model plan that are not to be relaunched now, which would otherwise come back on whatever their
transcript last ran. Same checks, guard and recycle lock as a switch; `--dry-run` prints the row and writes nothing;
with `--clear` it is an error (a clear never relaunches anyway). It takes a session with no tmux session right now
when sala knows the name: a tmux session, a pane-map row, or a model row of its own. A name it has never seen is
refused.

**The compact window** (Thu Oct 29th 2026; a window that differs by type of agent, depending on the nature of its work). Background agents compact at 200k tokens, set by the config repo's project settings for
background agents. A shared settings file cannot say a window per session, so a session that needs a different one gets
it from sala: `compact.tsv` in the state directory (`~/.local/state/salamander/`, beside `models.tsv`), one
`<tmux session>\t<tokens>` row per session with a window of its own, added by hand to the live file. No row ships by default. `claude --autocompact <tokens>` (CLI 2.1.312:
"auto, or 100k–1M tokens"; it overrides the project setting and refuses anything else at start) is put on the pane's launch
line: `resume_cmd` (every revive, recycle relaunch, lane move, `sala model` relaunch, unpark) and `spawn`. No row, a
`#` comment line or a row whose value is not a whole number from 100000 to 1000000 is no flag, and the project setting
applies (a bad value would leave the pane at a shell, so it is ignored the way a bad `models.tsv` row is). The sdk lane's
pane program and a one-shot `claude -p` carry no flag. No verb writes the file: `install.sh` seeds it from
`contrib/compact.tsv` (a header comment and no rows) when it is absent, and it is edited by hand after that; a pane takes a
changed value at its next relaunch. `rename` and `retire` do not move the row. Tested in `tests/models.sh`.

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
- **Gathering and rest**: a flag raised from the board, a `--when-idle` request or the CLI's auto-update
  while the job is unfinished does not reset it at once. Flags gather until `SALA_RECYCLE_GATHER` (10 min) pass with no new one,
  never more than `SALA_RECYCLE_GATHER_MAX` (30 min) after the first, then the job resets ONCE (one short 🔄 post says it is
  waiting and when it resets). A pane relaunched less than `SALA_RECYCLE_REST` (30 min) ago is not relaunched again for a routine
  flag until its rest ends. `sala op recycle` (the owner's words) skips both waits; revive, lane and model flags are not gated. A
  knob at `0` turns that wait off.
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

## Heartbeat store
`heartbeat` is the only verb that writes outside the machine, and one box writes the whole store. The live store is a
local directory (`SALA_HEARTBEAT_STATE_DIR`) the consumer reads; git (`SALA_HEARTBEAT_REPO`) is optional and, with
`SALA_HEARTBEAT_GIT=master`, carries only the master record — live state is not history. The writer: the driving box
(`SALA_FLEET_HOSTS` set) sweeps the others over ssh — version and live sessions (a registry file whose pid runs) — so
they run nothing for it; a box that does not answer ssh is offline and keeps its last files. It knows nothing about the consumer: the store is a
directory in a git checkout (`SALA_HEARTBEAT_REPO`, `SALA_HEARTBEAT_DIR`), the machine's subdirectory is a letter from
`SALA_FLEET_NAMES` (a TSV of `hostname → fleet name → letter`) or `SALA_HEARTBEAT_LETTER`, and the two files follow a
fixed contract: `machine.json` = `{letter, fleet, claude, checked, master, master_session, fleet_ssh}` (`fleet_ssh` on the driving box:
`{fleet name: {letter, ok, since}}`); `sessions.json` = one entry per live pane keyed by
its transcript UUID, `{name, url, seen, machine}`, where `url` is the session's link: on the writer's own rows the sala-web link
`SALA_SESSION_URL` gives (Tue Oct 13th 2026), bridged or not; on a swept box's rows the Remote Control address, empty
while the bridge is down. Session
identity is the UUID on purpose — it survives resumes, renames and bridge breaks, so a consumer that stores the UUID as
an owner resolves the current name and URL at render time. `checked` and `seen` are the times of the last change, not
of the last run: a run that finds nothing new leaves the files, and the repo, untouched.

## Running without stackshot
sala installs and runs without stackshot (the owner's board). Every integration is a knob that is unset by default, a file
that is written whether or not anyone reads it, or a call that fails open with one log line: the heartbeat store, the
message marker, the inbox hold, the post-recycle hook, recycle-wanted, the spawn keeper ask, the release report, and
sala-web's board items and roles. With stackshot on the box, two lines in the config turn the board half on
(`SALA_POST_RECYCLE_CMD`, `SALA_RECYCLE_WANTED_CMD`, `config.example`). Where stackshot's checkout is comes from one knob,
`SALA_STACKSHOT_DIR` (unset: `~/stackshot`, as every default was before; set empty on a box with no stackshot, and each default
command that names `pages.py` or `client.py` is empty at once; the explicit knobs still win; `config.example`). What needs
stackshot today: `spawn --project` is **the one command that needs stackshot and a local mirror of the pages**: its page and agents-map checks
read stackshot's project record, then `pages.py` (with the local mirror of the pages behind it) when the record cannot answer, and the spawn is
refused when neither can. That refusal is by design and stays fail-closed (the web form and the queue run it unattended, and a
session made before its agents line exists reads no mandate); `SALA_AGENT_CHECK=off` is the only bypass, for every spawn. There is
no abstraction over the check: one is built only when a box without stackshot has to make project spawns. The other is `sala reboot` on a box whose `SALA_REBOOT_HOOKS` names stackshot's hooks.

**Contracts.** Every interface between the two, in both directions, is listed in
[`docs/stackshot-contracts.md`](docs/stackshot-contracts.md) (**contract-version 11**, Mon Oct 26th 2026): the path or
command, its exact shape, who owns each side, what happens when the other side is missing, and the suite that guards it.
A change to any of them bumps that version.

## Permissions
sala is an operator tool: in auto mode, pre-approve it once per machine instead of per command, so a
recycle or a fleet provision is never stopped by the classifier halfway —
```json
"permissions": { "allow": ["Bash(sala:*)", "Bash(salamander:*)", "Bash(~/.local/bin/sala:*)", "Bash(~/.local/bin/salamander:*)"] }
```
Its own guards still apply (busy panes, terminal prompts, unsubmitted text, live claude.ai sessions). A
Claude session cannot add these rules to its own settings — the classifier refuses self-modification —
so a person applies them once.

## macOS
All process inspection goes through `proc_*` helpers in `lib/common.sh` (`ps`, `lsof`; `/proc` is used only when it
exists), and a pane's CLI version is read from the registry rather than the executable path, so the code paths are the
same on both OSes. Timer and login-start equivalents are in [`launchd/`](launchd/). **Status:** the helpers and the read-only commands pass
[`tests/smoke.sh`](tests/smoke.sh) (and the sweep's three phases [`tests/phases.sh`](tests/phases.sh), against six fake panes) on `macos-latest` (Darwin arm64, tmux 3.7c; that leg now runs on demand) and on Linux (GitHub's hosted `ubuntu-latest`) via
[GitHub Actions](.github/workflows/smoke.yml), against real tmux and a compiled fake `claude`; on Linux they also match
the previous `/proc` implementation on a live box. Not yet run against the real CLI on a Mac (no host) — the launchd
agents in particular are untested.

## What this depends on that is not documented
The registry file layout, transcript paths (`~/.claude/projects/<cwd-slug>/<uuid>.jsonl`), the `tmux` field
being cached at launch, the feedback-draft store (`~/.claude/feedback/drafts/*.json`, `status`), `remote-control`'s exit-after-offline behaviour, and the session-archive endpoint. All
pinned in [`lib/common.sh`](lib/common.sh) so a CLI change is a one-file fix. Tested against Claude Code 2.1.x.

## Status
The other boxes need only ssh and a POSIX shell (Linux or macOS); everything that runs locally needs tmux.

MIT.
