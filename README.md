# salamander

**Claude Code sessions that stay alive, on every machine you run them on.**

salamander (`sala` for short) keeps named, long-lived Claude Code sessions running in tmux on a server.
After a reboot or a Claude Code update it brings each one back and resumes the same conversation, so you
can drive them from claude.ai on another machine and never lose a thread. It can also update Claude Code
on your other boxes over ssh, and it has an optional web UI.

## Quick start

You need `bash` 4.4 or newer, `tmux`, `python3` 3.11 or newer, and `claude` on your PATH. Add `gh`, signed
in, if you want the merge queue or the CI-run poller. Linux is the supported system (macOS is untested).

```
git clone https://github.com/howardpark-ai/salamander ~/salamander && ~/salamander/install.sh
```

Settings live in `~/.config/salamander/config`; [config.example](config.example) lists every key.
The full requirements, the optional web UI and the tmux-resurrect setup are in [docs/install.md](docs/install.md).

First commands:

```
sala spawn notes                     # start a named session called "notes"
sala spawn --list                    # every session, its version and its claude.ai link
sala revive                          # bring dead sessions back after a reboot or `claude update`
sala rc --status                     # the Remote Control server and what it serves
sala map                             # session name, claude.ai link and tmux session in one table
sala --help                          # every command
```

For a step-by-step install on your own machine, follow [docs/sala-guide.md](docs/sala-guide.md). If an AI
assistant is doing the install, give it [docs/sala-guide-for-ai.md](docs/sala-guide-for-ai.md).

## The main parts

- **Sessions**: `spawn`, `revive`, `retire`, `rename` and `map` start, resume, end and list named sessions. See [docs/subcommands.md](docs/subcommands.md).
- **Recycle**: one command relaunches every session, with a lock so two never run at once. See [docs/recycle.md](docs/recycle.md).
- **Lanes**: the account or key a session runs on, and what happens when one runs out. See [docs/lanes.md](docs/lanes.md).
- **Models**: choose and record the model and effort of each session. See [docs/models.md](docs/models.md).
- **Watchdog**: a timer that revives dead panes and runs queued operations (`watch`). See [docs/subcommands.md](docs/subcommands.md).
- **Fleet**: update Claude Code on your other machines and read their live sessions over ssh. See [docs/subcommands.md](docs/subcommands.md) and [docs/heartbeat-store.md](docs/heartbeat-store.md).
- **Notices and hooks**: tell every session something once, and run your own command after an update. See [docs/notices-and-hooks.md](docs/notices-and-hooks.md).
- **Merge queue**: `sala mq` for a repository that cannot use GitHub's own queue. See [docs/mq.md](docs/mq.md).
- **Web UI**: sessions in a browser, optional. See [web/README.md](web/README.md) and [docs/web-proxy.md](docs/web-proxy.md).
- **Board**: sala works without the stackshot board; see [docs/running-without-stackshot.md](docs/running-without-stackshot.md).

## Documentation

| Page | What it holds |
|---|---|
| [overview.md](docs/overview.md) | What sala is for, its two layers, what is out of scope, and a first look at the commands |
| [install.md](docs/install.md) | Requirements, the install command, the config file, the web UI and the tmux-resurrect setup |
| [sala-guide.md](docs/sala-guide.md) | Step-by-step install on your own Linux machine |
| [sala-guide-for-ai.md](docs/sala-guide-for-ai.md) | The same install as a procedure for an AI assistant |
| [subcommands.md](docs/subcommands.md) | Every command with its options |
| [design-notes.md](docs/design-notes.md) | The failure modes that shaped sala and what each design choice answers |
| [lanes.md](docs/lanes.md) | Lanes, lane fields, the dormant record, the lane fallback and the sdk lane |
| [models.md](docs/models.md) | Choosing, recording and changing the model and effort of a session |
| [recycle.md](docs/recycle.md) | The one-driver rule, the recycle flags and job, and panes sala never relaunches |
| [notices-and-hooks.md](docs/notices-and-hooks.md) | Telling every session something once, and the commands run after an update or recycle |
| [heartbeat-store.md](docs/heartbeat-store.md) | What the heartbeat writes and how to read it |
| [running-without-stackshot.md](docs/running-without-stackshot.md) | What needs the board and what does not |
| [setup-notes.md](docs/setup-notes.md) | Permissions, macOS, undocumented dependencies and status |
| [units.md](docs/units.md) | The systemd units sala ships and the lane each runs on |
| [web-proxy.md](docs/web-proxy.md) | The web UI with ttyd and an HTTPS proxy with a login in front |
| [side-sessions.md](docs/side-sessions.md) | Quick sessions: short side conversations |
| [session-registry.md](docs/session-registry.md) | The registry that gives each session an id of its own |
| [session-registry-contract-proposal.md](docs/session-registry-contract-proposal.md) | A proposal for the registry's contract with stackshot |
| [reboot-contract.md](docs/reboot-contract.md) | How `sala reboot` brings a box down and back in order |
| [permission-hook.md](docs/permission-hook.md) | Answering routine permission dialogs automatically |
| [stuck-question-recovery.md](docs/stuck-question-recovery.md) | What happens when a session waits on a question only a person can answer |
| [ci-runs.md](docs/ci-runs.md) | The CI-run poller and its files |
| [merge-queues.md](docs/merge-queues.md) | The three ways a PR reaches `main` |
| [mq.md](docs/mq.md) | `sala mq`, our own merge queue |
| [mockup.md](docs/mockup.md) | Showing a design as a numbered web page |
| [stackshot-contracts.md](docs/stackshot-contracts.md) | Every interface between sala and the stackshot board |
| [test-coverage.md](docs/test-coverage.md) | What each test suite covers and why |

## Contributing

How a change is made, tested and released is in [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).
