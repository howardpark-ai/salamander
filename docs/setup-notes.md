# Setup notes

Permissions to pre-approve, macOS support, what sala depends on that Claude Code does not document, and status.

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
same on both OSes. Timer and login-start equivalents are in [`launchd/`](../launchd/). **Status:** the helpers and the read-only commands pass
[`tests/smoke.sh`](../tests/smoke.sh) (and the sweep's three phases [`tests/phases.sh`](../tests/phases.sh), against six fake panes) on `macos-latest` (Darwin arm64, tmux 3.7c; that leg now runs on demand) and on Linux (GitHub's hosted `ubuntu-latest`) via
[GitHub Actions](../.github/workflows/smoke.yml), against real tmux and a compiled fake `claude`; on Linux they also match
the previous `/proc` implementation on a live box. Not yet run against the real CLI on a Mac (no host) — the launchd
agents in particular are untested.

## What this depends on that is not documented
The registry file layout, transcript paths (`~/.claude/projects/<cwd-slug>/<uuid>.jsonl`), the `tmux` field
being cached at launch, the feedback-draft store (`~/.claude/feedback/drafts/*.json`, `status`), `remote-control`'s exit-after-offline behaviour, and the session-archive endpoint. All
pinned in [`lib/common.sh`](../lib/common.sh) so a CLI change is a one-file fix. Tested against Claude Code 2.1.x.

## A host-wide out-of-memory stop and the panes' systemd scopes
tmux (3.4 and later, with a systemd user manager) starts each pane's process in its own transient scope, `tmux-spawn-<uuid>.scope`, and
sets nothing on it, so every scope takes the user manager's `DefaultOOMPolicy`, which is `stop`. When the kernel's out-of-memory killer
ends ONE process of a scope, even a small child of the pane's shell, systemd stops the whole scope: the claude goes with it, the tmux
session closes, and the tmux server stays up. Several panes were lost this way in one minute.

The setting is not in this repository: sala does not create these scopes (tmux does), and there is no unit or tmux option that names one
scope's policy. It belongs to the machine's provisioning, as a drop-in for the user manager:

```
# ~/.config/systemd/user.conf.d/oom-policy.conf   (or /etc/systemd/user.conf.d/ for every user)
[Manager]
DefaultOOMPolicy=continue
```

It applies to scopes created after the user manager has read it (`systemctl --user daemon-reexec`, or the next time the manager starts);
check one with `systemctl --user show tmux-spawn-<uuid>.scope -p OOMPolicy`. With `continue` the killed process is the only loss: a pane whose
claude itself was the one killed is left at a bare shell, which `watch` revives (`SALA_BARE_REVIVE`, *Bare panes*); a session that is gone
altogether is posted once by `watch` (*Gone sessions*, `SALA_MISSING_CHECK`) and brought back with `sala restore --missing`.

## Status
The other boxes need only ssh and a POSIX shell (Linux or macOS); everything that runs locally needs tmux.

MIT.
