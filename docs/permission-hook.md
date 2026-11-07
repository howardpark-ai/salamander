# The permission hook: approve first, leave a person's prompts alone

Auto-approve comes first; asking a person is the fallback. A pane that stops on a permission dialog waits for
a person, so sala answers the routine ones itself, at once, and keeps its alert for the ones that are a person's.

## What it does

`salamander hook permission-request` is a Claude Code `PermissionRequest` hook (lib/hook.sh; the logic is lib/permissions.py, stdlib
python, one start per prompt). The CLI runs it the moment a dialog is about to show, with the tool and its input on stdin.

- **Approve:** it prints `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}` and exits 0. The
  dialog never shows.
- **Leave:** it prints nothing and exits 0. The CLI shows its normal dialog. A PermissionRequest hook can only allow or deny, never defer
  (docs/stuck-question-recovery.md), and a deny would answer for the person, so silence is the only "not mine".
- **A left prompt is picked up by the existing instant alert D.** About 6 s after the dialog shows, the Notification hook
  (`salamander hook notify`, lib/stuck.sh `sq_instant`) posts it to Slack once, and the stuck watch's 90 s post stays the fallback. Nothing in
  this hook posts anything. A prompt it leaves is exactly a prompt that would have waited before.
- **Never an error to the turn:** exit 0 on every path, nothing on stdout but the approval line, an error is a leave.
- **Off switch:** `SALA_PERMISSION_APPROVE=off` (also `0`, `no`, `false`) leaves every prompt. Removing the hook from settings.json has the
  same effect.
- **Log:** one line per decision in `~/.claude/salamander-permission.log` (`$SALA_LOG_DIR`): time, `allowed` or `left`, tool, reason, the
  session's first 8 characters, the agent (the payload's `agent_type`, else `SALA_SESSION_ID`), and the first 80 characters of the input
  with anything that looks like a secret masked (the same scrub as the stuck watch's posts). Cut to its last 2000 lines past 512 KB.

## What is never approved

The table is at the top of `lib/permissions.py`, one regex and one comment per rule, so a rule is changed in one place. Paths are
resolved before matching (`~`, `$HOME`, `/./`, `x/../`, a path relative to the payload's cwd, and the real path behind a symlink), and a
command is also matched with its quotes and backslashes taken out.

| # | case | what it matches | why |
|---|---|---|---|
| 1 | a question to a person | tool `AskUserQuestion`, `ExitPlanMode`, `EnterPlanMode`; a tool name with `ask_user`, `elicit`, `request_input`, `request_approval`, `human_input`; an MCP `confirm` | The answer is the user's. Approving the call would answer it for them. |
| 2 | the permission and instruction surface | `.claude/settings*.json`, `settings.json`, `settings.local.json`, `~/.claude.json`, `CLAUDE.md`, `.mcp.json`, `managed-settings`, `/etc/claude-code`, a `hooks/` directory; for Edit, Write, MultiEdit and NotebookEdit also a hook script that the settings wire | What decides what a session may do and what it is told. A session that could change these through an auto-approved call could grant itself anything. |
| 3 | credentials | `~/.ssh`, `.aws`, `.gnupg`, `.env` files, token files of the owner's tools, `id_rsa` and its kin, `.pem` / `.p12` / `.key`, file names with token / secret / credential / password and a data extension, dotfiles with token / secret / credential, `.netrc`, `.npmrc`, `~/.config/gh`, `.kube/config`, `/etc/shadow` | A call that reads or writes them is for a person to see. |
| 4 | plan mode | `permission_mode` = `plan` | A person reads a plan before anything runs. |
| 5 | input it cannot read | stdin that is empty, not JSON, not an object, or has no string `tool_name` | Without the tool there is nothing to judge: a leave. |
| 6 | the switch | `SALA_PERMISSION_APPROVE=off` | The owner or an operator turning it off. |

**What is scanned, per tool:** a file tool (Read, Edit, Write, MultiEdit, NotebookEdit, Glob, Grep, LS) its path fields only, because the
content of an Edit is the work and not the target (an Edit that writes the word CLAUDE.md into a notes file is approved); a shell tool
(Bash) the command text; an Agent, WebFetch, WebSearch, Skill or similar tool nothing, its input is a prompt or a query; any other tool, an
MCP server's included, every string in its input.

## What it does not do

- It is a net for the prompts that mean something to a person, not a sandbox. A command text is matched as text: a path built by a
  variable, a glob, a computed string, or a script that is not named in the command is not seen. Everything not in the table is approved,
  `rm -rf`, `sudo`, a force-push and a command with `dangerouslyDisableSandbox` included. Those are the tools' own permission rules'
  business (settings.json), and an operator's call whether the table should grow.
- The over-matches are on purpose: a command that mentions CLAUDE.md, a jq `.token`, a `process.env` or a file called `tokenizer_config.json`
  is left to the dialog. The cost is an alert for a harmless prompt; the other side of the error is worse.
- A hook script that the settings wire is protected from Edit and Write only under the path the settings spell. An edit of the file
  behind a symlink (`~/.local/bin/salamander` is one, into the repo) by its real path is not matched; sala's own hook code is therefore
  reviewed in a PR, not guarded here.

## Install

The hook has to be in the settings of the pane's CLI, next to the others (the machine's provisioning registers them, not
`install.sh`):

```json
"PermissionRequest": [{"matcher": "*", "hooks": [{"type": "command", "command": "~/.local/bin/salamander hook permission-request"}]}]
```

Tests: `bash tests/permissions.sh` (docs/test-coverage.md).
