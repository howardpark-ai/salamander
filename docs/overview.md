# What sala is

What sala is for, its two layers, what it leaves out on purpose, and a first look at the commands.

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
[Design notes](design-notes.md).

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
