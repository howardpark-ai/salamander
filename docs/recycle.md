# Recycling

How a recycle runs: the one driver rule and the recycle lock, the flags and the recycle job, and the panes sala never relaunches.

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
