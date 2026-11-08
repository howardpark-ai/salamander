# Design notes

The failure modes that shaped sala, and what each design choice answers.

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
  (beside the pane map, [docs/session-registry.md](session-registry.md)) gives each session a uuid4 that outlives both:
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
