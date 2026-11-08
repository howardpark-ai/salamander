# Install

Requirements, the install command, the config file, the optional web UI and the tmux-resurrect setup.

Step-by-step guides: [docs/sala-guide.md](sala-guide.md) (for a person) and [docs/sala-guide-for-ai.md](sala-guide-for-ai.md) (for an AI assistant doing the install).
```
git clone https://github.com/howardpark-ai/salamander ~/salamander && ~/salamander/install.sh
```
Needs bash >= 4.4 (`bin/salamander` refuses to run on an older one; macOS ships 3.2: `brew install bash`), `tmux`, `python3` 3.11 or newer (the merge queue and machine-follow read TOML with `tomllib`; the web UI needs 3.12, which `uv` fetches), `claude` on PATH, and `gh` signed in (`gh auth login`) for the CI-run poller and `sala mq`. Linux (reads `/proc`; macOS is untested, and support is a TODO).
Config: `~/.config/salamander/config` ([all keys](../config.example)).
The web UI (`web/README.md`) is optional: `~/salamander/install.sh --web` copies its three systemd user units (the app, its socket and
ttyd for the Terminal tab) and prints the commands that start them. The web UI has no login of its own, so put HTTPS and a login in
front of it before it is reachable from anywhere else: [docs/web-proxy.md](web-proxy.md). Then, if you use
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
