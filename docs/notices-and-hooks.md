# Notices and hooks

How sala tells every session something once (notices), and the commands it runs after an update or a recycle.

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
