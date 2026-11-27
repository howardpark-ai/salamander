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

`sala notice add` takes the text as one quoted argument. `-h`, `--help` and `help` as the first word after `add` print the usage and exit 0
without posting anything, and a text that starts with `-` is refused (exit 2, nothing posted, one line saying the text looks like an
option): a mistyped `sala notice add --help` once posted a notice reading "--help" to every live session. A text such as `- a bullet` or
`-5 degrees` is refused too, by design: start it with another character. `--from` and `--until` are unchanged and may come before or after the text.

State is under `~/.local/state/salamander`: `notices.tsv` (id, created, sender, until, text; atomic writes under `notices.lock`),
`notices.seq` (the last id, so an id is never reused) and `notices-seen/<session id>` (the last notice id handled for that session).
A notice every live session has had or skipped is dropped after a day (the day covers a session that resumes an older conversation or
comes live late); otherwise it expires at `--until`, default 7 days. Pruning runs on `add`, `list`, `drop` and by `watch`; `notices.seq` is
never pruned. With none left, every `notices-seen` file goes, and the files of sessions that are
gone are pruned after a day. **Cost:** with no notice the hook is a glob test and one `-s` test, no process. With a notice up it reads
the first 512 bytes of the hook input with the shell's own `read` and compares `notices-seen/<session>` with `notices.tsv` by mtime
(`-nt`): still no process. Only a session that has not looked since the notices last changed starts one python (`lib/notice.py
deliver`), once. A notice is text any process of this user can write into every session's context, so it carries its sender and
`--from` is required; `tests/notice.sh` covers it.

## Drain mode: a waiting session starts nothing new
`salamander hook pre-tool` (PreToolUse, matcher `Bash|Agent|Task|Monitor`; `install.sh` says when the matcher is missing one) is the second half of the
relaunch-waiting line `post-tool` tells a session once (*Recycle*, `docs/recycle.md`, "Drain mode"). While the flag under `waiting/<session id>` stands, the
session's own turn may not start work that outlives the turn: a background subagent (Agent or Task, `run_in_background` true), a Monitor, a Bash call with
`run_in_background` true. The hook answers `permissionDecision: deny` with a reason naming the way out (finish the turn, leave `sala note "<next step>"`, `sala ready` as
the last call; the refusal ends when the relaunch is done), logs one line to `salamander-drain.log` (time, tool, session; never the command), and lets everything else
through. A call that carries `agent_id` belongs to a subagent and is never denied. It reads the tool name from the first bytes of its input and stats the flag before anything
else: with nothing waiting, a call of another tool costs the glob test and nothing more, and any failure or doubt allows. `SALA_DRAIN=off` in the config turns it
off (default on); `SALA_DRAIN_DENY_TEXT` words the reason. `tests/drain.sh` covers it.

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
