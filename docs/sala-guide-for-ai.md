# Installing salamander (neutral second instance): procedure for an AI agent (draft v0.2, Thu Nov 5th 2026)

Audience: a Claude Code assistant that installs salamander ("sala") on the user's own Linux machine.
Written against salamander `main` of Thu Nov 5th 2026. Steps 1 to 6 and 9 were run in full on a clean Linux user account with its own board. Since then every command named here was checked again against `main` by its help text or a read-only form, and `docs/stackshot-contracts.md` is at contract-version 36. Lines marked `TODO(verify)` are things no such check reaches: a Claude login, a live systemd user manager, a public host name, root, another machine, or a clean-account run of the whole procedure at the newest commit.
The same procedure for the person is [sala-guide.md](sala-guide.md). The board is a separate install with its own pair of guides:
[board-alone-guide.md](https://github.com/howardpark-ai/stackshot/blob/main/docs/board-alone-guide.md) and
[board-alone-guide-for-ai.md](https://github.com/howardpark-ai/stackshot/blob/main/docs/board-alone-guide-for-ai.md). Link to them. Do not repeat them.

## 0. Goal and done-condition

Goal: a working, neutral sala on this machine. Neutral means no other person's repositories, machines, chat tools or names. Every setting that names a person or place is empty until the user gives a value.

Done when all of these hold:

1. `~/salamander` is a clone of `github.com/howardpark-ai/salamander`, and `command -v sala` prints `~/.local/bin/sala`.
2. `~/.claude/settings.json` has the keys and hooks of step 3, and `install.sh` prints no `settings.json` warning.
3. `~/.config/salamander/config` has the user's values for the seven settings of step 4, and `sala config` shows them.
4. `sala lane --list` shows the lane `subscription-1` as `active`, and `sala spawn <name> --cwd "$HOME" --dry-run` ends with `nothing made, recorded or typed`.
5. The user's first session shows in `sala spawn --list` (step 6).
6. If the user wants the watchdog: `systemctl --user list-timers sala-watch.timer` shows a next run (step 7).
7. If the user wants the web UI: both `curl` checks of step 11 print `401`, and `ss` shows no TCP listener (step 11).
8. If the user has a board: step 9 is done, and `python3 ~/stackshot/stackshot/fleet/client.py recycle-wanted` prints a number.

Steps 7 to 11 are optional. Ask the user which ones they want before you start (hand-off H0).

## 1. Rules for you

- **Never print a secret.** This covers the Caddy password and its hash, API keys, tokens and `~/.aws/credentials`. Count matches instead of printing lines. Never put a secret literal in a command. A password goes through `caddy hash-password` typed by the user, or through an editor.
- **Do not edit files inside `~/salamander`.** `deploy.sh` refuses a checkout with local changes. Your files are `~/.config/salamander/config`, `~/.claude/settings.json`, `~/.config/systemd/user/*` and `~/.tmux.conf`.
- **Never kill a Claude process by name.** No `pkill claude`, `killall claude`, `pgrep -x claude`. Retire a Claude session with `sala retire NAME` (the exact tmux session name; a shell with no Claude is `sala close-shell NAME`, a leftover row `sala forget-row NAME`).
- **Use `systemctl --user` only.** Never `sudo systemctl`, except the one `disable --now caddy` of step 11, and only after the user agrees.
- **Run each `sala` step as one plain command.** Do not chain a `sala` command with others in one shell line.
- **Use `uv`, never `pip install`,** for any Python.
- **Do not guess a value that names the user** (name, zone, scopes, host name). Ask. The questions are in H0.
- **Check after every step.** If the result differs from "Expected", stop and read section 6.
- **Do not turn on a unit the user did not ask for.** The watchdog (step 7) updates Claude Code and relaunches panes by itself; say so first.
- **Do not open the web UI to a network without a login.** If the login is not ready, do not start the proxy.

## 2. Facts

| Fact | Value | Source |
|---|---|---|
| What sala is | a bash CLI that keeps named Claude Code sessions in tmux, revives them after a reboot or an update, and has an optional web UI | `README.md` |
| Needs | bash >= 4.4, tmux, python3 >= 3.11 (`tomllib`: `lib/mq/*.py`, `lib/machine-follow.py`), `claude` on PATH, Linux (macOS untested). `gh` signed in only for the CI-run poller (`lib/cipoll.py`, `gh api -i`) and `sala mq` | `docs/install.md`, `install.sh` |
| Clone path | `~/salamander` (the web units and all examples assume it; `install.sh --web` rewrites the unit paths for another path under `$HOME`) | `install.sh` |
| Clone URL | `https://github.com/howardpark-ai/salamander` | `docs/install.md` |
| `install.sh` | links `bin/salamander` to `~/.local/bin/salamander` and `~/.local/bin/sala`; copies `config.example` to `~/.config/salamander/config` if absent (every line commented out); seeds `~/.local/state/salamander/compact.tsv`; runs `lane --migrate`; prints warnings and hook lines. Idempotent. Starts and enables nothing | `install.sh` |
| `install.sh --web` | also writes `sala-web.socket`, `sala-web.service`, `sala-web-ttyd.service` to `${XDG_CONFIG_HOME:-~/.config}/systemd/user` with this checkout's path. Starts and enables nothing. Refuses a path with unusual characters | `install.sh` |
| Config file | `~/.config/salamander/config`. A bash file that sala sources. The web app reads the same file as text (never sources it) | `lib/common.sh`, `web/src/sala_web/config.py` |
| Default lane | `subscription-1` (shown as Subscription 1 unless `SALA_LANE_SUBSCRIPTION1_LABEL` says otherwise; the older word `max` is still read as an alias): the `claude` login in `~/.claude`. Other lanes: `subscription-2`, `api`, `bedrock`, `aws-platform`, `sdk`. `sala lane names` prints each lane's code, display name and old words | `docs/lanes.md` |
| Watchdog | `systemd/sala-watch.service` (oneshot, `salamander watch`) and `.timer` (first run 3 min after boot, then every 2 min). Copied by hand, not by `install.sh` | `systemd/` |
| Web UI | sala-web: a Python app on the unix socket `$XDG_RUNTIME_DIR/sala-web/sala-web.sock`; ttyd on `$XDG_RUNTIME_DIR/sala-web-ttyd/ttyd.sock` under `/tty/`. **No login of its own, no TCP port.** Needs `uv`, `ttyd`, and an HTTPS proxy with a login covering `/` and `/tty/`. Pages: the Overview with four tabs (Agents, Schedules, Machines, Usage analysis: the Report, Explorer and Digest views of what Claude Code replies cost, in dollars, with `GET /api/usage`, `GET /api/usage/replies` and `GET /api/usage/digest`), a session's Chat and Terminal, the Shell drawer, search, New session (needs the board), the board's look throughout (`/v2/`, where that look was first tried, redirects to `/` for a while). Details: `web/README.md` | `docs/web-proxy.md`, `web/contrib/`, `web/README.md` |
| Python for the web app | 3.12 or newer, fetched by `uv sync --frozen` | `web/pyproject.toml` |
| Board | stackshot, installed on its own. sala finds its tools through `SALA_STACKSHOT_DIR` (default `~/stackshot`) | `config.example` |
| What needs the board | `spawn --project`. With no board it refuses ("cannot tell"). `SALA_AGENT_CHECK=off` is the only bypass | `docs/running-without-stackshot.md` |
| Notifications | `SALA_NOTIFY_CMD`, else `SALA_WATCH_NOTIFY_CMD`: a command that reads the message on stdin. Empty = the message is sent nowhere | `lib/common.sh` |
| Updating | `~/salamander/deploy.sh`: refuses a dirty checkout; fast-forwards `main`; runs `install.sh` only if it or `config.example` changed; runs `uv sync --frozen` and restarts `sala-web.service` if `web/` changed; never restarts a session; does not copy changed units | `deploy.sh` |
| Contracts with the board | listed, with a version (`contract-version: 36` at this writing), in `docs/stackshot-contracts.md` | the file |
| Merge queue | `sala mq`: for a repository with no GitHub merge queue; one entry per PR, each stacked on the entry ahead, all tested at once, merged in line order. Nothing happens until the host file `~/.config/mergequeue/<owner>__<repo>.toml` sets `mode = "shadow"` (tests, merges nothing) or `"on"` (merges); no file or `off` is the default. Group mode is retired: `queue_mode = "group"` blocks the queue until the line is deleted. Verbs: `add N…`, `status [--json]`, `drop N`, `pause`, `resume`, `wait N`, `doctor`; `--repo OWNER/NAME` defaults to the current folder's GitHub origin | `docs/mq.md`, `sala mq --help` |
| Mockup pages | `sala mockup add FILE\|-` stores an HTML file as the next numbered page and prints `https://<sala's address>/mockup/<n>` (the scheme and host of `SALA_SESSION_URL`); sala-web serves it behind its sign-in in a sandbox (scripts and styles run, no cookies, no sala API, no network), so a session without the Artifact tool can hand a reader a link. UTF-8, at most 5 MiB, `<meta name="viewport" content="width=device-width, initial-scale=1">` for phones. The daily pass `sala mockup clean` deletes pages over 7 days old that no open board item links, then keeps the folder under 1 GB (oldest first, linked last); with `SALA_MOCKUP_REFERENCES` unset it deletes nothing | `docs/mockup.md`, `sala mockup --help` |
| Fleet queue | `sala op <verb> … --from NAME --words "…"` queues recycle, update, revive, retire, close-shell, forget-row, rename, lane, model, provision and spawn for the watchdog to run with no model. `sala op --list`, `--plan <verb> …` (what it would do) and `--cancel <id>` are the read and drop forms. A reboot is not queued (`sala reboot --go`, the user's own call; `SALA_OP_REBOOT` is off) | `lib/op.sh`, `sala --help` |
| Back agents' lane rule | optional, off by default; settings below; docs/lanes.md section "The back agents' lane rule"; `sala watch --back-lanes [--dry-run]` | `docs/lanes.md`, `lib/common.sh` |
| machine-follow | optional, for another machine only: keeps machines level with the one that drives them; four units in `systemd/` (`machine-follow.service`, `.path`, `.timer`, `machine-follow@.service`), linked by hand on the driving machine, plus a data file the user writes (`SALA_MACHINE_FOLLOW_MACHINES`, default `~/.config/salamander/machine-follow.toml`). `python3 -I ~/salamander/lib/machine-follow.py --dry-run` names the machines that are due and changes nothing | `docs/units.md`, `lib/machine-follow.py` |

## 3. Settings

All of these go in `~/.config/salamander/config`. Defaults are in `config.example`, which is a full copy with every line commented out.

### Set with the user (ask, then write)

| Key | Value | Default if unset | Read when |
|---|---|---|---|
| `SALA_OWNER_NAME` | the user's first name, at most 40 characters | `the owner` | each call. Also the name in the `[for <name>]` first line of a message to a front agent. Must equal the board's `[instance] owner`, or both unset |
| `SALA_SCOPES` | space-separated, quoted: `"work home"`. Each is one of the board's subject prefixes without brackets | empty: no scopes | each call (the web UI notices a changed file) |
| `SALA_DEFAULT_SCOPE` | one of the scopes | the first of `SALA_SCOPES`. With neither, `sala question file` and the parked-question filing refuse with a plain error naming this setting | each call |
| `SALA_TZ` | an IANA zone, e.g. `Europe/Berlin` | the machine's local time; the web UI shows the viewer's zone | each call (cached by the file's modification time) |
| `SALA_BRAND_SUFFIX` | text after "salamander" in the web title bar, at most 40 characters, quoted if it has a space | empty: "salamander" alone | each page load |
| `SALA_HELP_SESSION` | a session name (`[A-Za-z0-9][A-Za-z0-9._-]{0,63}`) the "Get Help" chip opens | empty: no chip; an invalid name is the same as empty | each call |
| `SALA_SHELL_SESSION` | the tmux session of the web UI's Shell drawer. A plain `bash -l`, not a Claude session. `spawn` and `rename` refuse the name | `sala-shell` | **once, when `sala-web.service` starts: restart it after a change** |

Match the board when there is one:

- `SALA_SCOPES` words = the board's `[subject] prefixes`, e.g. `"[work] ,[home] "` on the board for `"work home"` here. The board's default prefix is `[todo] `, which is the scope `todo`.
- `SALA_OWNER_NAME` = `[instance] owner`. `SALA_TZ` = `[instance] timezone` if the user wants the same times.

### Set when the board is installed (step 9)

| Key | Value |
|---|---|
| `SALA_RECYCLE_WANTED_CMD` | `python3 ~/stackshot/stackshot/fleet/client.py recycle-wanted` |
| `SALA_POST_RECYCLE_CMD` | `python3 ~/stackshot/stackshot/fleet/client.py recycled` |
| `SALA_QUESTION_PROJECT` | a project page that exists on the board, e.g. `projects/getting-started`. It has no default: empty, the filer refuses and the log names `SALA_QUESTION_PROJECT` |
| `SALA_STACKSHOT_WEB` | the board's public HTTPS address, no trailing slash |

### Leave at the defaults, and know what they do

| Key | Default | What it means on a neutral install |
|---|---|---|
| `SALA_STACKSHOT_DIR` | `~/stackshot` | Set EMPTY on a box with no board: every default board command is empty at once. The web app reads it from the environment, not this file |
| `SALA_AGENT_CHECK` | `on` | `spawn --project` needs the board. `off` skips the check for every spawn |
| `SALA_AUTO_UPDATE` | `on` | Once the watchdog runs and the npm registry lists a newer Claude Code (asked at most every 10 minutes; the `npm` program itself is not needed), sala updates it, then relaunches this machine's panes on an older version, each only when idle |
| `SALA_AUTO_RECYCLE` | `on` | A full recycle (`recycle --update --force`, each pane only when idle), at most once an hour, when a board item waits for one (`SALA_RECYCLE_WANTED_CMD`) or a session ran `sala recycle --when-idle "<reason>"`. With no board, only the session's request starts it |
| `SALA_SUBAGENT_STALE` | `21600` | How long, in seconds, a subagent whose transcript is not marked finished still counts as running. A running subagent holds a pane's relaunch and is never cut; one that crashed stops counting after this |
| `SALA_STALE_TURN_AFTER` | `3` | How many times the in-session mod may refuse an exit for a turn it cannot name, while every other check reads the pane as idle, before the exit goes by keys (the tries then thin out to one every 10 minutes, then every 30) |
| `SALA_JOB_LANE` | `subscription-1` | The lane of the calls the watch can start (a stuck-operation helper, the parked-question sweep) and of `sala job` jobs that name none |
| `SALA_LANE_FALLBACK` / `SALA_LANE_FALLBACK_AUTO` | `subscription-1=bedrock subscription-2=bedrock ...` / `on` | When a lane is marked dormant, sala tries to move its sessions to the fallback. With no Bedrock, nothing moves and one alert line says why. `SALA_LANE_FALLBACK_AUTO=off` stops the attempt. A monthly usage cap (a 429 naming the day access returns) marks its lane dormant until that day, which starts this move; a busy pane is interrupted with one Escape (`SALA_CUT_WAIT`, 40 s) so it can be relaunched; no "lane working again" post while it is held |
| `SALA_BACK_LANE_RULE` | `off` | The back agents' lane rule. `on`: the watch moves the background agents (a row with role `back`, or with no role that stackshot's project record lists as a project's background agent; never front agents, side sessions or jobs) off the home lane when its "This week" limit reaches the threshold, on to the third lane when a pane on the second is stopped on its cap, and home when the weekly window resets. Off: nothing is read or moved. `sala watch --back-lanes --dry-run` shows a pass without queueing |
| `SALA_BACK_LANE_ORDER` / `SALA_BACK_LANE_THRESHOLD` / `SALA_BACK_LANE_MAX_AGE` | `subscription-1 aws-platform bedrock` / `90` / `1800` | The lanes (home, second, third), the percent of the home lane's "This week" limit that starts step 1, and how old (seconds) the saved usage answer may be: an older, failed or incomplete reading moves nobody |
| `SALA_BACK_LANE_REFRESH_URL` / `SALA_BACK_LANE_REFRESH_EVERY` / `SALA_BACK_LANE_REFRESH_WAIT` | empty (sala-web's socket) / `120` / `10` | sala-web refreshes the saved usage answer only when something asks its `/api/quota`. When the rule is on and the home lane's answer is missing or older than half the max age, the watch asks the local sala-web with a plain GET (a socket path or an http(s) base URL; `off` = never) and reads the file again. No token is handled by sala; a failed call leaves the reading stale and nobody moves |
| `SALA_BACK_LANE_WORDS` / `SALA_BACK_LANE_STATE` | a sentence that states the rule / `back-lane.state` in the state directory | The words every queued move carries (the user's own sentence, quoted, if they want one) and the file that makes each step fire once per weekly window |
| `SALA_LANE_BEDROCK_PROFILE` | empty | Bedrock is ready only when this names a profile found in `~/.aws/credentials`. A profile name with "admin" in it is refused. Also needs `SALA_LANE_BEDROCK_REGION`: there is no default region, and with it unset the lane stays "not set up" and `sala lane` says which setting is missing |
| `SALA_WATCH_NOTIFY_CMD` | empty | No alert is sent anywhere. Optional: a command that reads the message on stdin |
| `SALA_MASTER` | empty | No master session. Optional |
| `SALA_FLEET_HOSTS` | empty | No other machines |
| `SALA_SETTINGS_APPLY` | `off` | Nothing is applied to Claude Code settings by sala |
| `SALA_OP_REBOOT` | see `config.example` | A reboot is not queued by default |
| `SALA_MACHINE_FOLLOW_MACHINES` | empty (`~/.config/salamander/machine-follow.toml`) | The data file of machine-follow. A missing file is one line and exit 2; nothing runs it until its units are linked |
| `~/.config/salamander/ci-repos` | absent; the tracked `lib/ci-repos` lists none | The CI poller polls nothing. It reads through `gh api -i`, so it also needs `gh` signed in (`gh auth status`); `sala mq doctor` needs `gh` on the PATH and signed in |
| `~/.config/salamander/unit-repos.tsv` | absent; the tracked `lib/unit-repos.tsv` lists none | `sala job add` refuses every repo until the user adds one |

## 4. Procedure

### Step 0. Preconditions and hand-off H0

Run each check. Expected output is on the right.

```bash
bash --version | head -1          # GNU bash, version 4.4 or newer
command -v git tmux python3       # three paths
python3 -c 'import sys; print(sys.version_info >= (3, 11))'   # True (3.11 or newer: tomllib)
command -v gh && gh auth status   # optional: only for the CI-run poller and sala mq
command -v claude && claude --version
echo "$PATH" | tr ':' '\n' | grep -c "$HOME/.local/bin"   # 1 or more
systemctl --user status >/dev/null 2>&1; echo $?           # 0 (a user manager runs)
```

A box that can reach github.com over https. howardpark-ai/salamander and howardpark-ai/stackshot are public: they clone with no account and no credentials.

If `claude` is missing or not signed in: STOP. Tell the user to install Claude Code and sign in (`claude`, then finish the login). You cannot do the login for them.

**H0. Questions for the user.** Ask all of these in one message, then wait:

1. Your first name (for `SALA_OWNER_NAME`)?
2. Your time zone, as an IANA name (for `SALA_TZ`)? Or use this machine's local time?
3. Scope names for your sessions, such as `work` and `home` (for `SALA_SCOPES`), and which one is the default?
4. A short text for the web UI's title bar, or none (for `SALA_BRAND_SUFFIX`)?
5. Do you want: the watchdog (step 7)? tmux-resurrect lines (step 8)? A board link (step 9)? The web UI (steps 10 and 11)?
6. If the board exists: where it is, its public address, and its subject prefixes.

### Step 1. Clone

```bash
git clone https://github.com/howardpark-ai/salamander ~/salamander
```

Check: `git -C ~/salamander log --oneline -1` prints a commit. Expected: the clone worked. If the clone fails, check `git ls-remote https://github.com/howardpark-ai/salamander`; a failure there is the box's network or proxy: STOP and tell the user.

### Step 2. Run the installer

```bash
~/salamander/install.sh
```

Check: the output has a line `✅ salamander → ... (alias: sala)`, followed by the config line and the hook lines. `command -v sala` prints `~/.local/bin/sala`. Expected: warnings about `~/.claude/settings.json` are fine for now. A line `⚠ missing: <dep>` for `tmux`, `python3` or `claude` is not: install it first.

### Step 3. Claude Code settings

Edit `~/.claude/settings.json`. Read it first. Keep every existing key. Add these. If the file does not exist, create it. Do not remove an existing hook of another tool.

```json
{
  "feedbackDrafts": "quiet",
  "feedbackSurveyRate": 0,
  "permissions": {
    "allow": ["Bash(sala:*)", "Bash(salamander:*)", "Bash(~/.local/bin/sala:*)", "Bash(~/.local/bin/salamander:*)"]
  },
  "hooks": {
    "PostToolUse": [
      {"matcher": "SendFeedback", "hooks": [{"type": "command", "command": "salamander feedback mark"}]},
      {"matcher": "*", "hooks": [{"type": "command", "command": "~/.local/bin/salamander hook post-tool"}]}
    ],
    "Stop": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "salamander feedback stop"}]},
      {"matcher": "*", "hooks": [{"type": "command", "command": "~/.local/bin/salamander hook stop"}]}
    ],
    "UserPromptSubmit": [
      {"hooks": [{"type": "command", "command": "~/.local/bin/salamander hook prompt"}]}
    ],
    "SubagentStop": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "~/.local/bin/salamander hook subagent-stop"}]}
    ],
    "SessionStart": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "salamander snapshot"}]}
    ]
  }
}
```

Merge with the existing `hooks` arrays: add to an event's array, do not replace it. Claude Code cannot add the `permissions.allow` rules to its own settings in auto mode (its classifier refuses self-modification). If the edit is refused, STOP and give the user the JSON to apply (hand-off H1).

Check:

```bash
python3 -m json.tool ~/.claude/settings.json >/dev/null && echo valid     # valid
~/salamander/install.sh 2>&1 | grep -c '⚠ .*settings'                      # 0
```

Expected: `valid` and `0`. The count looks for the `settings.json` warnings only. A `⚠ missing:` line is a different warning.

**H1. Self-modification refused.** Say exactly: "Claude Code does not let me change my own permission rules. Please paste this block into `~/.claude/settings.json`, then tell me when it is done." Give the block. Wait.

### Step 4. Write the settings

Use the answers from H0. Append to `~/.config/salamander/config` (a later assignment wins in bash; the web app also takes the last one). Do not edit the commented lines above it. Example, with the user's values:

```bash
cat >> ~/.config/salamander/config <<'EOF'
SALA_OWNER_NAME="Alex"
SALA_SCOPES="work home"
SALA_DEFAULT_SCOPE="work"
SALA_TZ="Europe/Berlin"
SALA_BRAND_SUFFIX="alex's box"
EOF
```

Leave out a line the user did not choose. An empty `SALA_BRAND_SUFFIX` is the same as unset. Do not write `SALA_HELP_SESSION` until a session exists to name (step 6). Do not write `SALA_SHELL_SESSION` unless the user wants a different name.

Check:

```bash
sala config | grep -E 'SALA_(OWNER_NAME|SCOPES|DEFAULT_SCOPE|TZ|BRAND_SUFFIX|HELP_SESSION|SHELL_SESSION) '
```

Expected: your values for the ones you set; `the owner` for `SALA_OWNER_NAME` if unset; `sala-shell` for `SALA_SHELL_SESSION`; empty for the others.

### Step 5. Check the install

```bash
sala --help | head -3
sala lane --list
sala spawn first --cwd "$HOME" --dry-run
```

Expected: a command list; a lane table in which `subscription-1` is `active` and the others are `inactive` or `not ready`; a dry run whose first line starts `[dry-run] would spawn 'first' on the Subscription 1 lane` and whose last line is `[dry-run] nothing made, recorded or typed`. A lane that shows `not ready` is not an error.

### Step 6. First session

```bash
mkdir -p ~/code
sala spawn work-first --cwd ~/code --mandate "Say hello and wait."
sala spawn --list
```

Use a name that starts with one of the user's scopes. Expected: the list shows `work-first` with a version. `tmux has-session -t work-first; echo $?` prints `0`.
A mandate that is a file waits for a confirmation in the pane unless `--no-confirm` is given. A text mandate is typed as the first message.
Checked on a clean account: the tmux session exists and Claude starts in it. That account had no Claude login, so Claude stopped at its first-run screen and the list showed no version. Never run `/login` for the user and do not copy credentials: if Claude is not signed in, tell the user to sign in once and run the spawn again. `TODO(verify)`: with a signed-in Claude, the version and bridge columns and the typed mandate were not seen.

If the user wants the Get Help chip, set `SALA_HELP_SESSION` to a session name now (step 4's rule).

To end a session: `sala retire NAME` (the exact tmux session name, or `--id <conversation-id>`), `sala close-shell NAME` for a tmux session with no Claude, `sala forget-row NAME` for a row whose session is gone. `--force` is gone: `--busy` retires a pane that is not idle, `--skip-writeup` a side session before `side done`, `--self` the session you run in (queue it with `sala op retire NAME --self --from NAME --words …`; your own running turn is not counted busy, a dialog or a child process still needs `--busy`), `--leave-items` one that is the mover of an open board item. Never kill it by name.

### Step 7. The watchdog (optional)

Say first: "Once this runs, sala updates Claude Code by itself when the npm registry lists a newer version, and relaunches panes that run an older one, each when idle; it also runs a full recycle when a session or a board item asks for one, at most once an hour. Set `SALA_AUTO_UPDATE=off` and `SALA_AUTO_RECYCLE=off` in the config if you do not want that." Wait for the user's yes.

```bash
mkdir -p ~/.config/systemd/user
cp ~/salamander/systemd/sala-watch.service ~/salamander/systemd/sala-watch.timer ~/.config/systemd/user/
systemd-analyze verify --user ~/.config/systemd/user/sala-watch.service ~/.config/systemd/user/sala-watch.timer
systemctl --user daemon-reload
systemctl --user enable --now sala-watch.timer
```

Check: `systemctl --user list-timers sala-watch.timer --no-pager` shows a NEXT time. Expected: within about 3 minutes after the first start. `sala watch --check` prints `healthy: no master session (SALA_MASTER unset) ...` and exits 0 while a tmux server runs. With no session started yet it prints `tmux server is down` and exits 1: that is expected until the first session of step 6 exists, not a fault.

Checked on a clean account: `systemd-analyze verify --user` on both files (exit 0) and `sala watch --check` (exit 0, the `healthy: no master session` line). `TODO(verify)`: `daemon-reload`, `enable --now` and the first timer run were not done, because the check used no systemd user manager.

Note: the service file carries `X-Model-Lane=bedrock`. That is a label, not a lane the tick uses. Do not change it and do not set up Bedrock for it.

Optional, only if the user asks for it: the back agents' lane rule (`SALA_BACK_LANE_RULE=on`, off by default). Say first: "The watchdog will move your background agents off the home lane when its weekly limit reaches 90 percent, and home again when the window resets. It reads the limit from the web UI, so the web UI (steps 10 and 11) must run." Check before and after turning it on: `sala watch --back-lanes --dry-run` prints one line per outcome and queues and writes nothing. Expected with the rule off: `idle: SALA_BACK_LANE_RULE is off: the rule is off`. Expected with it on and the home lane well under the threshold: `idle: the back agents stay on the <lane> lane (<lane> at N%)`. `idle: no usable <lane> reading: <reason>` means the web UI gave no fresh reading (not running, no sign-in, or older than `SALA_BACK_LANE_MAX_AGE`): nobody moves, and that is not a fault of the rule. A `would:` line names the `sala op lane` it would queue. The rule moves only sessions whose registry row has role `back` (`sala spawn NAME --project <page> --role back`); with none, it has nothing to move. Checked by running the dry run on a live instance with the rule on (the `idle: the back agents stay` line); the off line and the `no usable … reading` line were read from `lib/watch.sh` and `lib/common.sh`, not run. `TODO(verify)`: an actual move (steps 1 to 3, with a limit near its cap) needs a live limit and was not staged.

### Step 8. tmux-resurrect (optional)

Only if the user uses tmux-resurrect. Append to `~/.tmux.conf`:

```
set -g @resurrect-hook-post-save-all    'salamander revive --save-map'
set -g @resurrect-hook-post-restore-all 'salamander revive'
set-hook -g session-created 'run-shell -b "salamander snapshot"'
set-hook -g session-closed  'run-shell -b "salamander snapshot"'
set-hook -g session-renamed 'run-shell -b "salamander snapshot"'
```

Check that `claude` is not in `@resurrect-processes`: `grep -n resurrect-processes ~/.tmux.conf`. If it is, remove `claude` from that list: resurrect would start it with `--continue`, and panes in one folder would grab the same conversation.
Expected: no line names `claude`. Do not run `tmux source-file` while the user is attached without telling them.

### Step 9. Link the board (optional, needs a running board)

Precondition: the board runs and `~/stackshot/stackshot/fleet/client.py` exists (a board checkout from before stackshot's package has `~/stackshot/client.py` instead: use that path in the lines below). If not, STOP and point the user at the board guides (top of this file); do this step when they are done. Then:

```bash
test -f ~/stackshot/stackshot/fleet/client.py && echo present
cat >> ~/.config/salamander/config <<'EOF'
SALA_RECYCLE_WANTED_CMD="python3 ~/stackshot/stackshot/fleet/client.py recycle-wanted"
SALA_POST_RECYCLE_CMD="python3 ~/stackshot/stackshot/fleet/client.py recycled"
SALA_QUESTION_PROJECT="projects/getting-started"
SALA_STACKSHOT_WEB="https://board.example.com"
EOF
python3 ~/stackshot/stackshot/fleet/client.py recycle-wanted
```

Use the user's own project page and address. Check that the page exists on the board and that its frontmatter has an `agents:` map with at least one entry (the first is the front agent), for example `agents:` then an indented `alex-main: talks to Alex about this project`; `sala question file` is refused with a 409 `lists no front agent` otherwise (T27). The board reads a registry built from the pages. It refreshes by itself after a write and at least every 10 minutes, so an edit takes effect within 10 minutes. To refresh it at once, run `STACKSHOT_CONFIG=~/.config/stackshot/stackshot.toml python3 ~/stackshot/stackshot/projects/pages.py registry`. Expected: `present`, then a number (`0` is fine).
Also run `python3 ~/stackshot/stackshot/fleet/client.py recycled`. Expected: a line saying that no item waits for a recycle, exit 0. Checked on a clean account against a board on its own port: `present`, `0`, the `recycled` line, and a parked question filed with `sala question file <id>` (the record then shows its board item).
Check the scopes against the board's prefixes (step 4). Expected: every scope has a matching prefix.

No board: write `SALA_STACKSHOT_DIR=""` instead, and skip the four lines. Tell the user that `spawn --project` will refuse.

### Step 10. Web UI: units (optional)

Ask the user (H2) before you start: the web UI shows and types into every session, so it must sit behind a login. If they cannot do step 11 now, do not enable the units.

```bash
command -v uv ttyd                 # two paths. Install missing ones first (ttyd: the distribution package)
~/salamander/install.sh --web
cd ~/salamander/web && uv sync --frozen
systemd-analyze verify --user ~/.config/systemd/user/sala-web.service ~/.config/systemd/user/sala-web-ttyd.service ~/.config/systemd/user/sala-web.socket
```

Expected: three unit files in `~/.config/systemd/user`, with `ExecStart` lines that name `%h/salamander/web/...`; `uv sync` ends without an error; `verify` prints nothing. (A "Command ... is not executable" line for `sala-web` means `uv sync` did not run.)

Then:

```bash
systemctl --user daemon-reload
systemctl --user enable --now sala-web.socket sala-web.service sala-web-ttyd.service
systemctl --user is-active sala-web.socket sala-web.service sala-web-ttyd.service
curl --unix-socket "$XDG_RUNTIME_DIR/sala-web/sala-web.sock" -s http://x/api/config | head -c 300
```

Expected: three lines `active`; the JSON has the keys `brand`, `commit`, `defaultScope`, `host`, `scopes`, `shellSession`, `terminalUrl`, `timezone`, `tzLabel`, `tzOffsetMin` and `version`, with the values of the settings you wrote. Three more read-only checks over the same socket, each printing `200`: `curl --unix-socket "$XDG_RUNTIME_DIR/sala-web/sala-web.sock" -s -o /dev/null -w '%{http_code}\n' http://x/` (the page), and the same with `http://x/api/machines` (the Machines tab's data: with no board its two sections say there is no reading yet) and `http://x/api/colors/combos` (the Colors panel's saved list, which the board holds: that one prints `200` only on a box with a board; without one the README says it answers 503 and the panel says the list is unavailable while the rest of the panel works). The Colors panel and the dark look need no setting.
`TODO(verify)`: the units were checked with `systemd-analyze verify` and the key names were read from the code (`web/src/sala_web/app.py`), but they were not started in the install check, which used a throwaway user account without a systemd user manager.
For lingering ask the user to run `sudo loginctl enable-linger "$USER"` (hand-off H3). Do not run `sudo` yourself.

What the page looks like, if the user asks (`web/README.md`, *The palette* and *The color tool*): it follows the browser's light or dark setting. The dark look ships one saved combination: the one orange `#f0a06a` for links, accents and solid fills; small labels (unread count, front-agent badge, the `max` effort tag) `#f0a06a` on `#3a2619` (6.76:1); a disabled solid button (Send, Create session) `#a3a29d` on `#2a2a2c` at full opacity (5.60:1). The light look keeps `#ad4608` and fades a disabled button. A **Colors** button at the bottom of the sidebar, in the dark look only, opens the pinned color panel: presets (the first is what ships, and **Reset** puts it back), saved combinations (one list the board holds) and, behind a **Fields** button, 14 color fields. A pick is kept in that browser only (`localStorage`). Nothing in the panel is a sala setting.

**H2. Login first.** Say: "The web UI has no login of its own. I will start it only on a socket that nobody else can reach, and I will not publish it until the login in front of it works." Continue only on a yes.

### Step 11. Web UI: HTTPS and a login (optional)

The recipe, with the Caddyfile and the unit, is in [docs/web-proxy.md](web-proxy.md). Follow it. The rules, in short:

1. **The login covers `/` and `/tty/`.** A login on one leaves a shell or the session list open on the other.
2. **HTTPS only. No TCP port** for sala-web or ttyd. Never change the units to listen on one, not even on `127.0.0.1`.
3. **Keep the `Host` header** as the client sent it.
4. **Caddy runs as the user**, with `admin off` in its global block. The package's own `caddy.service` must be stopped (`sudo systemctl disable --now caddy`: hand-off H3).
5. **Port 443** needs one system change for the user: a `sysctl` line or `setcap` on the Caddy binary (hand-off H3).
6. **A name and a certificate.** A DNS name for the machine with ports 80 and 443 open, or the HTTPS certificates of a VPN.

**H3. Commands that need root, and the password.** Give the user the exact lines, one at a time, and wait:

- `sudo loginctl enable-linger "$USER"`
- `sudo systemctl disable --now caddy`
- the port line from `docs/web-proxy.md` (`sysctl` or `setcap`)
- `caddy hash-password` typed by the user in their own shell. They paste the printed hash (not the password) into the Caddyfile through an editor. You never see the password and you do not print the hash.

Write `~/.config/sala-web/Caddyfile` with the user's name and hash, `chmod 600` it, write `sala-web-proxy.service`, then:

```bash
caddy validate --config ~/.config/sala-web/Caddyfile --adapter caddyfile
systemctl --user daemon-reload && systemctl --user enable --now sala-web-proxy.service
```

Check, from the machine (use your own name):

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://NAME/            # 401
curl -s -o /dev/null -w '%{http_code}\n' https://NAME/tty/        # 401
ss -ltnp | grep -E 'sala-web|ttyd' | wc -l                          # 0
```

Expected: `401`, `401`, `0`. Any other first or second line means a route is open: stop the proxy (`systemctl --user stop sala-web-proxy.service`) and fix it before anything else. Ask the user to open the page in a browser, sign in, and see the sessions. `TODO(verify)`: the proxy was not run in the install check: it needs a public DNS name and root, which a check on a private account does not have; the units, the socket and the Caddyfile text were checked by `systemd-analyze verify` and by reading `docs/web-proxy.md`.

## 5. Hand-offs (summary)

| ID | Where | What only the user can do |
|---|---|---|
| H0 | before step 1 | Answer the questions: name, zone, scopes, title text, which optional steps, board facts |
| H1 | step 3 | Apply the `permissions.allow` rules and hooks to `~/.claude/settings.json` if Claude Code refuses to |
| H2 | step 10 | Agree that the web UI stays unpublished until its login works |
| H3 | steps 10 and 11 | Run the `sudo` lines; type the password for `caddy hash-password`; own the DNS name and open ports |

## 6. Troubleshooting

| ID | What you see | Cause | Do this |
|---|---|---|---|
| T1 | `sala: command not found` | `~/.local/bin` is not on `PATH` | Add it in `~/.profile`; use `~/.local/bin/sala` meanwhile |
| T2 | `bin/salamander` exits at once with a bash message | bash older than 4.4 | Install a newer bash |
| T3 | `install.sh` prints `⚠ missing: claude` | Claude Code is not on `PATH` for this user | Install it; open a new shell |
| T4 | `settings.json` warnings remain after step 3 | A hook is missing, or the JSON is invalid | `python3 -m json.tool ~/.claude/settings.json`; compare with step 3 |
| T5 | `sala config` shows `SALA_OWNER_NAME the owner` after you set it | The line is still commented out, or a later line unsets it | Check for a duplicate line below: the last one wins |
| T6 | A value with a space is cut at the space | It is not quoted | Quote it: `SALA_BRAND_SUFFIX="alex's box"` |
| T7 | `sala question file` or a filed question fails and names `SALA_DEFAULT_SCOPE` | Neither `SALA_DEFAULT_SCOPE` nor `SALA_SCOPES` is set | Set one (step 4). The filing is refused before anything is sent |
| T8 | The board refuses a question's subject | The scope is not one of the board's `[subject] prefixes` | Make the two lists equal (step 4) |
| T9 | `sala spawn` says a lane is not ready | The lane has no credentials | Use `subscription-1`, or set the lane up. Do not set up Bedrock just to silence this |
| T10 | `spawn --project` says `cannot tell`, exits 3 (`REGISTER:`) or 4 (`NO-PAGE:`) | No board, no such page, or the name is not registered with stackshot | Install the board; create the page; run the `post project-agent` command that exit 3 prints. `SALA_AGENT_CHECK=off` is the only bypass |
| T11 | `spawn` refuses a name | It is the shell session's name (`SALA_SHELL_SESSION`) or invalid | Pick another name |
| T12 | The lane fallback alert says "not moved automatically" | The fallback lane is `bedrock` and it is not ready | Expected on a neutral install. `SALA_LANE_FALLBACK_AUTO=off` stops the attempt |
| T13 | `sala watch --check` is not healthy | See its line. `tmux server is down` just means no session has been started yet | Read it; it names the cause. Start the first session (step 6) |
| T14 | The timer does not appear in `list-timers` | Not copied, or no `daemon-reload` | Redo step 7 |
| T15 | Panes do not return after a reboot | tmux-resurrect is not set, or `claude` is in `@resurrect-processes` | Step 8 |
| T16 | `systemd-analyze verify` says `sala-web` is "not executable" | `uv sync --frozen` was not run in `web/` | Run it (step 10) |
| T17 | `install.sh --web` refuses with a character message | The checkout path has an unusual character | Move the clone to a plain path such as `~/salamander` |
| T18 | `sala-web-ttyd.service` fails | `ttyd` is missing or is not at `/usr/bin/ttyd` | `command -v ttyd`; use a drop-in with an empty `ExecStart=` line, then the full line |
| T19 | The Shell drawer keeps the old session name | `SALA_SHELL_SESSION` is read once | `systemctl --user restart sala-web.service` |
| T20 | `systemctl --user` cannot reach the user manager | A shell that is not a login shell | `export XDG_RUNTIME_DIR=/run/user/$(id -u)` or log in again |
| T21 | The units stop at logout | Lingering is off | H3: `sudo loginctl enable-linger "$USER"` |
| T22 | The Terminal tab is blank, or a send is refused | The proxy changed `Host`, so the origin check fails | Keep `Host` as it is |
| T23 | `curl` to the HTTPS name prints `200` without credentials | The login does not cover that path | Stop the proxy. Put the login on both paths. Repeat the checks |
| T24 | Caddy cannot bind port 443 | The user may not bind low ports, or the system Caddy holds the port | H3: the `sysctl` or `setcap` line; stop the system Caddy |
| T25 | `deploy.sh` refuses: "local changes" or "not on main" | The checkout was edited or switched | Undo the edit (`git -C ~/salamander status`); do not stash another person's work without asking |
| T26 | A changed unit is not picked up after an update | Units are copied by hand | Copy the file again, then `systemctl --user daemon-reload` |
| T27 | `sala question file` exits 1 and the board says `lists no front agent` (409) | The project page in `SALA_QUESTION_PROJECT` has no `agents:` map, or the board's registry has not refreshed yet | Add `agents:` with a front agent to the page; wait up to 10 minutes or refresh the registry at once (step 9) |
| T28 | `sala watch --back-lanes --dry-run` prints `idle: SALA_BACK_LANE_RULE is off: the rule is off` | The rule is off, which is the default | Nothing is wrong. Set `SALA_BACK_LANE_RULE=on` only if the user asks (step 7) |
| T29 | The same command prints `idle: no usable <lane> reading: …` | The web UI is not running, cannot read the lane's usage, or its saved answer is older than `SALA_BACK_LANE_MAX_AGE` | Start the web UI (step 10); nobody moves meanwhile, by design |
| T30 | `sala mq doctor` names a problem, or `sala mq add` refuses | No host file (mode `off`), a `queue_mode = "group"` line, or a missing tool | Read the line `doctor` prints: it names the fix. A host file with `mode = "shadow"` is the safe start |
| T31 | `sala watch --back-lanes --dry-run` leaves a background agent out, or `sala sessions` shows a live session with no role | The row has no role and the project record did not place it (not listed, listed on two projects, or the record is stale or missing) | `sala sessions tag --auto --dry-run` says per row why it is left; a stored role is never overwritten. Fix the project's agents map, or set the role by hand with `sala sessions tag NAME --project P --role back` |

## 7. Using sala afterwards

Commands the user will use. Each is read-only unless it says otherwise.

```bash
sala spawn --list                      # live sessions, their versions, and tmux sessions whose claude has exited
sala spawn NAME --cwd DIR [--mandate TEXT|FILE] [--lane L] [--model M] [--effort E]    # start a session (writes)
sala spawn --suggest-name --project projects/X --role front                             # a free name for a project agent
sala retire NAME                       # end a Claude session for good (writes); close-shell NAME: a shell; forget-row NAME: a leftover row
sala revive --dry-run                  # what a revive would do
sala recycle --dry-run                 # what a recycle would do; without --dry-run it relaunches every pane when idle
sala lane --list                       # the lanes and their state; sala lane names: each lane's code and display name
sala lane pins                         # sessions pinned to a lane (held out of every bulk lane move); pin <session> <lane> / unpin <session> change the list
sala watch --back-lanes --dry-run      # what the back agents' lane rule would do now; queues and writes nothing
sala config                            # the effective settings
sala job list                          # scheduled jobs of ours
sala notice list                       # one-time lines waiting for live sessions; sala notice add "<text>" --from NAME shows one to every live session at its next turn (writes)
sala ci-runs OWNER/REPO                # the CI poller's file for a repo, if the poller runs
sala mq status --repo OWNER/REPO      # our merge queue's line, entries and driver (modes shadow, which tests and merges nothing, and on, which merges; off is the default; group mode is retired; docs/mq.md); mq add N… / wait N / drop N / pause / resume / doctor
```

Fleet operations that change many sessions at once (`recycle`, `update`, `provision`, lane and model moves, `revive`, `retire`, `rename`) go through the queue when more than one person or session may act (`sala op --list`, `--plan <verb> …`, `--cancel <id>`; a reboot is not queued, the user runs `sala reboot --go`): `sala op <verb> ... --from <your name> --words "<what the user said>"`. Quote the user's own words. Two cases take no words: ending a throwaway you started (`sala op retire NAME --from <you>`), and bringing back a session that cannot work, with a reason instead: `sala op revive --only NAME [--force] (--item board#N | --why "<one line, at least 3 words>") --from <you>` (a live Claude session only, never a sweep, never the master or yourself; the reason is for the record, `--item` is checked for its shape only). Everything else, a revive of the whole fleet included, still needs the user's words.

Where things are: sessions' registry in `~/.claude/sessions`, sala's state in `~/.local/state/salamander`, its log in `~/.claude`.

## 8. Updating

```bash
~/salamander/deploy.sh --check         # the drift check alone: report, change nothing, no fetch
~/salamander/deploy.sh --dry-run       # what an update would do; the checkout is not touched
~/salamander/deploy.sh                 # fast-forward to the newest main
```

Expected: one `changed:` line with the range and files, and `note:` lines. Then act on the notes:

- A changed file under `systemd/`: copy it again into `~/.config/systemd/user`, then `systemctl --user daemon-reload`. A resident unit (`sala-follow.service`, `sala-cipoll.service`) keeps its old code until you restart it. The machine-follow units are linked, not copied (`docs/units.md`): a changed file there needs only `daemon-reload`.
- A changed file under `web/`: `deploy.sh` already ran `uv sync --frozen` and restarted `sala-web.service`. If that step failed: `~/salamander/deploy.sh --web`.
- A changed `config.example`: read the diff for new settings; the user's config is never overwritten.

Claude Code itself updates by `sala update` (relaunches every session, each when idle), or by itself when the watchdog runs and `SALA_AUTO_UPDATE` is on.

## 9. Report to the user when done

Write, in plain words:

1. What is installed: the clone path and its commit (`git -C ~/salamander rev-parse --short HEAD`), the `sala` command, and which of the optional steps (7 to 11) are done.
2. The settings you wrote, with their values. Do not print any password or hash.
3. What runs on its own now: the watchdog (and that it updates Claude Code and relaunches panes), the web UI units, the proxy. Say what each does and how to stop it (`systemctl --user disable --now <unit>`).
4. What you could not check: every `TODO(verify)` line above that applied.
5. What is left for them: a board link (step 9) if the board is not running yet, lingering, a DNS name, and any hand-off they have not finished.
6. How to update (section 8) and where the guides are (`docs/sala-guide.md`, `docs/sala-guide-for-ai.md`).
