# Installing salamander on your own Linux machine (draft v0.2, Thu Nov 5th 2026)

Written for a technical reader who has never seen salamander, and for the Claude Code assistant that helps them.
Scope: salamander ("sala") as a second, independent instance: your machine, your settings, your own stackshot board.
Written against salamander `main` of Thu Nov 5th 2026. Steps 1 to 6 and 9 were run in full on a clean Linux user account with its own board. Since then every command this guide names was checked again against `main` by its help text or by a read-only form of it, and `docs/stackshot-contracts.md` is at contract-version 36. Lines marked `TODO(verify)` are things no such check reaches: a Claude login, a live systemd user manager, a public host name, root, another machine, or a clean-account run of the whole procedure at the newest commit.
The same procedure for an AI assistant is [sala-guide-for-ai.md](sala-guide-for-ai.md).
The board half is a separate install: [board-alone-guide.md](https://github.com/howardpark-ai/stackshot/blob/main/docs/board-alone-guide.md).

## 1. What salamander is

salamander is a command line tool (`sala`, also `salamander`) that keeps long-lived Claude Code sessions alive on one Linux machine.

- Each session is a named **tmux** session running `claude`. sala starts it, names it and remembers which conversation it holds.
- When the machine reboots, or Claude Code is updated, sala brings every session back and resumes the same conversation.
- A **watchdog** (a systemd user timer, every 2 minutes) revives a pane whose `claude` died, runs queued operations and updates Claude Code.
- A **lane** is the account a session runs on. The default lane is `subscription-1` (shown as Subscription 1; the older word `max` is still read as an alias): the sign-in you already use for `claude`. Other lanes (a second subscription, an API key, Amazon Bedrock) are optional.
- A **web UI** (called sala-web in the files) shows all sessions in a browser: an overview, each session's chat and terminal, and a shell. It is optional (step 10).
- sala works without a board. The board (stackshot) adds items, decisions and project pages. This guide leaves the board install to its own guide and only says how sala talks to it.

This guide installs a **neutral** sala. Nothing in it assumes another person's machines, repositories or chat tools. Every setting that names a person or a place starts empty, and you fill it in.

Everything runs as your own user. The core install (steps 1 to 9) needs no `sudo`. `sudo` appears only in the optional web UI (step 10 and [docs/web-proxy.md](web-proxy.md)): installing `ttyd` and `caddy` with apt, turning on lingering, stopping the system Caddy, and letting your user listen on port 443. The checklist marks each one.

## 2. What you need before starting

Tick each line before step 1.

- [ ] A Linux machine with systemd. You log in as an ordinary user. macOS is not tested.
- [ ] `bash` 4.4 or newer (check: `bash --version`), `git`, `tmux` and `python3` 3.11 or newer (check: `python3 --version`). The merge queue and machine-follow read TOML with `tomllib`, which starts at 3.11; the web UI needs 3.12, and `uv` fetches that itself.
- [ ] Optional, only for the CI-run poller and `sala mq` (section 5): the GitHub CLI `gh`, signed in (check: `gh auth status`).
- [ ] Claude Code installed and signed in on this machine (check: `claude --version`, then start `claude` once and finish the sign-in). sala uses this login as the `subscription-1` lane.
- [ ] `~/.local/bin` is on your `PATH` (check: `echo $PATH`). `install.sh` puts the `sala` command there.
- [ ] A box that can reach github.com over https. howardpark-ai/salamander and howardpark-ai/stackshot are public: they clone with no account and no credentials.
- [ ] A stackshot board for the board half, installed with its own guide (above). You can do this later. Without it, sala still runs, and one command (`spawn --project`) refuses, as step 4 explains.
- [ ] For the web UI only: `uv` and `ttyd`, and a way to put HTTPS and a login in front of it (Caddy is shown). On Debian and Ubuntu, `ttyd` and `caddy` come from `sudo apt install ttyd caddy`. Skip these if you do not want the web UI.
- [ ] For the web UI only, and optional: lingering for your user, so the units keep running after you log out (`sudo loginctl enable-linger <your user>`; `install.sh --web` prints the command without `sudo`).
- [ ] For the web UI only: the Caddy recipe in step 10 uses `sudo` twice more, to stop the system Caddy and to let your user listen on port 443. Skip it if you put the login in front another way.

Not needed: a database, a chat tool, Amazon Bedrock, an API key, or any other repository.

## 3. Install, step by step

Run each command on your machine, as your own user. Once the web UI is running (step 10), its Shell button opens a terminal on this machine in your browser; type any later command in this guide there.

### Step 1. Get the code

```bash
git clone https://github.com/howardpark-ai/salamander ~/salamander
```

Clone it to `~/salamander`. The web UI units and the examples below assume that path. Do not edit files inside this folder: the update script in section 6 refuses to run if tracked files changed.

Good result: `ls ~/salamander/install.sh` prints the path.

### Step 2. Run the installer

```bash
~/salamander/install.sh
```

It does five things, and it is safe to run again:

- links `~/salamander/bin/salamander` to `~/.local/bin/salamander` and `~/.local/bin/sala`;
- copies `config.example` to `~/.config/salamander/config` if you have no config yet (every line is commented out, so nothing is set);
- copies a template for sessions that need a compact window of their own to `~/.local/state/salamander/compact.tsv` (it lists no session; you add a row by hand if one needs it);
- renames the old lane name `awsplatform` to `aws-platform` in sala's files if it finds one (a fresh install finds nothing and prints nothing);
- prints warnings for what is missing, then prints the tmux hook lines and the watchdog line you will use in steps 7 and 8.

The warnings about `~/.claude/settings.json` are expected on a fresh machine. Step 3 fixes them.

Good result: the output has a line that starts with `✅ salamander → ...`, with the config file on the line under it, followed by the tmux and watchdog lines you will use in steps 7 and 8. `sala --help` prints a command list.

### Step 3. Tell Claude Code about sala

sala needs a few entries in `~/.claude/settings.json`. Add them to the file if it exists, or create it. Keep any entries you already have.

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

What each part is for:

- `feedbackDrafts` and `feedbackSurveyRate` keep Claude Code from opening a prompt that only a terminal can answer. A session nobody is watching would hang on it.
- `permissions.allow` lets sala commands run without a prompt each time. A Claude session cannot add these rules to its own settings, so you add them once yourself.
- The hooks tell sala when a turn ends, so its busy check is exact, and clean up after subagents. The `UserPromptSubmit` entry lets `sala notice` reach a session at its next prompt (it reaches it at the next tool call without it). The `SessionStart` entry saves the tmux layout.

Run `~/salamander/install.sh` again. Good result: no `settings.json` warning is left.

### Step 4. Set your settings

Open `~/.config/salamander/config` in an editor. It is a shell file. Remove the `#` in front of a line to set it. Quote any value with a space. The full list is in `config.example`; the ones below are the ones a new install should look at.

```bash
SALA_OWNER_NAME="Alex"
SALA_SCOPES="work home"
SALA_DEFAULT_SCOPE="work"
SALA_TZ="Europe/Berlin"
SALA_BRAND_SUFFIX="alex's box"
SALA_HELP_SESSION=""
SALA_SHELL_SESSION="sala-shell"
```

Use your own values. The table says what each setting does and what happens when you leave it alone.

| Setting | What it does | If you leave it unset |
|---|---|---|
| `SALA_OWNER_NAME` | What sala calls you in its text, and the name in the `[for <name>]` first line of a message to a session you talk to. Use your first name, at most 40 characters. | "the owner". If you run a board, use the same name as the board's `[instance] owner`, or leave both unset. |
| `SALA_SCOPES` | The areas you name sessions by, space-separated and quoted, for example `"work home"`. A session is named `<scope>-<project>-<word>`. The web UI groups its sidebar by scope. | No scopes. Sessions are named without them and the web UI has no scope groups beyond "other". If the board lists its own scopes, the web UI reads those instead. |
| `SALA_DEFAULT_SCOPE` | The scope a page outside every scope is named in. It also opens the subject of a question filed on the board: `[work] ...`. | The first word of `SALA_SCOPES`. **With neither set, filing a question on the board is refused** with a plain error that names this setting. |
| `SALA_TZ` | An IANA zone, for example `Europe/Berlin`. Used for spawn names, logs and every time the web UI shows. | Your machine's local time. The web UI then shows each viewer's own zone. |
| `SALA_BRAND_SUFFIX` | What follows "salamander" in the web UI's title bar: "salamander : alex's box". At most 40 characters. | "salamander" alone. |
| `SALA_HELP_SESSION` | The name of a session that the web UI's overview opens from its "Get Help" chip. | No chip. |
| `SALA_SHELL_SESSION` | The tmux session of the web UI's Shell drawer. It is a plain `bash -l`, not a Claude session. sala leaves it alone and refuses it as a session name. | `sala-shell`. |

Three of these must agree with your board, if you have one:

- Each scope is one of the board's **subject prefixes**, without the brackets. The prefixes `[work] ,[home] ` on the board match `SALA_SCOPES="work home"`. The board refuses a subject that starts with a prefix it does not list.
- `SALA_OWNER_NAME` is the board's `[instance] owner`.
- `SALA_TZ` is the board's `[instance] timezone`, if you want both to show the same times.

Two things need a restart: the web UI reads `SALA_SHELL_SESSION` once, when it starts, so run `systemctl --user restart sala-web.service` after you change it. The other six settings are read each time they are needed. Reload the page.

Good result: `sala config | grep -E 'SALA_(OWNER_NAME|SCOPES|DEFAULT_SCOPE|TZ|BRAND_SUFFIX|HELP_SESSION|SHELL_SESSION)'` prints your values.

### Step 5. Check the install

```bash
sala --help | head -3
sala config | head -5
sala lane --list
sala spawn first --cwd "$HOME" --dry-run
```

Good result:

- `sala lane --list` shows the lanes. `subscription-1` is `active`. The others show `inactive` or `not ready`, which is normal until you set them up.
- The dry run prints `[dry-run] would spawn 'first' on the Subscription 1 lane ...` and ends with `nothing made, recorded or typed`.

### Step 6. Start your first session

```bash
mkdir -p ~/code
sala spawn work-first --cwd ~/code --mandate "Say hello and wait."
sala spawn --list
```

`mkdir -p ~/code` makes the folder if you do not have one yet; use any folder you like. Use any name you like. A name that starts with one of your scopes (`work-...`) is grouped by the web UI. `--cwd` is the folder the session works in. A `--mandate` is the first instruction. If it is text, sala types it as the first message. If it is a file that exists, the session reads the file and waits for you to confirm; add `--no-confirm` to start without waiting. With no mandate, the session starts empty.

Good result: `sala spawn --list` shows `work-first` with a version and a bridge column. `tmux ls` shows a tmux session of that name. The install check ran this on a clean account: sala created the tmux session and started Claude in it. That account had no Claude login, so Claude stopped at its first-run screen. `TODO(verify)`: with a signed-in Claude, the version and bridge columns in `sala spawn --list` and the typed mandate were not seen. Sign in to Claude once, as you normally do, before this step.

To go into a session: `tmux attach -t work-first`. To leave it running, press your tmux prefix (Ctrl+b unless you changed it), then `d`.

To end a session for good: `sala retire work-first`. A tmux session with no Claude in it is closed with `sala close-shell NAME`; a leftover pane-map row whose session is gone is dropped with `sala forget-row NAME`. `retire` takes the exact tmux session name (`--id <conversation-id>` finds a session by its conversation), refuses the session the call runs in unless `--self`, and refuses a session that is the mover of an open board item unless `--leave-items`.

### Step 7. Start the watchdog (recommended)

The watchdog is what revives dead panes and runs queued operations. It is one oneshot service and one timer.

```bash
mkdir -p ~/.config/systemd/user
cp ~/salamander/systemd/sala-watch.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now sala-watch.timer
```

Good result: `systemctl --user list-timers sala-watch.timer` shows a next run within 2 minutes (the first run waits 3 minutes after boot). `sala watch --check` prints `healthy: no master session (SALA_MASTER unset) ...` and exits 0 while a tmux server runs. With no session started yet it prints `tmux server is down` and exits 1: that is expected until the first session of step 6 exists, not a fault.

The install check verified both unit files with `systemd-analyze verify --user` and ran `sala watch --check` (it printed `healthy: no master session`, as step 7 says). It did not enable the timer, because that needs a live systemd user manager. `TODO(verify)`: `enable --now` and the first timer run.

Know what it will do once it runs. Two things are on by default:

- **Automatic update.** When the npm registry lists a newer Claude Code (the watchdog asks at most every 10 minutes; the `npm` program itself is not needed), sala updates it, then relaunches this machine's panes that run an older version, each one only when it is idle. Set `SALA_AUTO_UPDATE=off` to stop that.
- **Automatic recycle.** When a board item waits for a recycle, or a session asks for one with `sala recycle --when-idle "<reason>"`, sala runs a full recycle (`recycle --update --force`: every pane, each one only when it is idle), at most once an hour. Without a board, only a session's own request starts it. Set `SALA_AUTO_RECYCLE=off` to stop that.

The watch posts alerts through a command you choose, `SALA_WATCH_NOTIFY_CMD` (for example a script that reads the message on stdin and sends it to a chat). It is empty by default, and then an alert is not sent anywhere: the watch still does its work, and you see it only by running `sala` commands. `SALA_NOTIFY_CMD` is the same setting under its other name.

The unit file says `X-Model-Lane=bedrock`. That line is a label for the unit list, and the watch tick itself makes no model call. The calls it can start (one helper for a stuck operation, one sweep of parked questions) run on `SALA_JOB_LANE`, which defaults to `subscription-1`. Nothing needs Bedrock.

### Step 8. Keep sessions across a reboot (optional)

sala restores panes with [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect). If you use it, add these lines to `~/.tmux.conf`:

```
set -g @resurrect-hook-post-save-all    'salamander revive --save-map'
set -g @resurrect-hook-post-restore-all 'salamander revive'
set-hook -g session-created 'run-shell -b "salamander snapshot"'
set-hook -g session-closed  'run-shell -b "salamander snapshot"'
set-hook -g session-renamed 'run-shell -b "salamander snapshot"'
```

Keep `claude` **out** of `@resurrect-processes`. If resurrect starts it, every pane in the same folder resumes the same conversation. sala resumes each pane by its own conversation id.

Good result: `tmux source-file ~/.tmux.conf` prints nothing. After a reboot, `sala spawn --list` shows your sessions again.

### Step 9. Connect sala to your board

Skip this step until the board is running. Follow the [board guide](https://github.com/howardpark-ai/stackshot/blob/main/docs/board-alone-guide.md) first. It puts the board in `~/stackshot`.

sala finds the board's tools through one setting, `SALA_STACKSHOT_DIR`. Its default is `~/stackshot`, so a board in that folder needs no setting. The tools sit at stackshot's package paths below it (`stackshot/fleet/client.py`); a board checkout from before that package keeps `client.py` in its root, and sala uses it there while it is the only one.

Then turn on the two board lines in `~/.config/salamander/config`:

```bash
SALA_RECYCLE_WANTED_CMD="python3 ~/stackshot/stackshot/fleet/client.py recycle-wanted"
SALA_POST_RECYCLE_CMD="python3 ~/stackshot/stackshot/fleet/client.py recycled"
SALA_QUESTION_PROJECT="projects/getting-started"
SALA_STACKSHOT_WEB="https://board.example.com"
```

- The first two let the board ask for a recycle and clear the request afterwards.
- `SALA_QUESTION_PROJECT` is the project page a filed question belongs to. It has no default: with it empty, a parked question is not filed on the board and the log names the setting. Name a page of your own.
- `SALA_STACKSHOT_WEB` is the board's public address. It makes the links in a session's brief and in the web UI.

The project page named in `SALA_QUESTION_PROJECT` must list at least one front agent under `agents:` in its frontmatter, for example `agents:` followed by an indented line `alex-main: talks to Alex about this project`. Without one, the board refuses a filed question with `lists no front agent`. The board reads the pages through a registry that it refreshes by itself after a write and at least every 10 minutes, so an edit takes effect within 10 minutes. To refresh it at once, run `STACKSHOT_CONFIG=~/.config/stackshot/stackshot.toml python3 ~/stackshot/stackshot/projects/pages.py registry`.

Good result: `python3 ~/stackshot/stackshot/fleet/client.py recycle-wanted` prints a number (`0` when nothing waits), `python3 ~/stackshot/stackshot/fleet/client.py recycled` prints that no item waits for a recycle, and `sala question file <id>` (for a question a session parked) creates an item on the board. The install check ran all three against a board on its own port.

**Without a board**, leave step 9 out and set `SALA_STACKSHOT_DIR=""` (empty). Every board command then stays empty at once. One command still refuses: `sala spawn NAME --project <page> --role front|back` checks the board's project record and refuses when it cannot. `SALA_AGENT_CHECK=off` turns that check off for every spawn. Plain `sala spawn` needs neither.

### Step 10. The web UI (optional)

The web UI shows the sessions in a browser. It has **no login of its own**, so you put HTTPS and a login in front of it before anyone else can reach it. Never expose it on a TCP port.

Install what it needs. `uv` is at https://docs.astral.sh/uv/. On Debian and Ubuntu, `sudo apt install ttyd caddy` gives the other two (the web UI was tested with ttyd 1.7.7). Then:

```bash
~/salamander/install.sh --web
cd ~/salamander/web && uv sync --frozen
```

`install.sh --web` writes three user units into `~/.config/systemd/user`: `sala-web.socket`, `sala-web.service` and `sala-web-ttyd.service`. It starts and enables nothing. It warns when `uv`, `ttyd` or `caddy` is missing.

The units:

- `sala-web.service` is the web app. It listens on the unix socket `$XDG_RUNTIME_DIR/sala-web/sala-web.sock`, and systemd starts it on the first request.
- `sala-web-ttyd.service` runs `ttyd`, which shows a tmux session in the browser for the Terminal tab and the Shell drawer. It listens on the unix socket `$XDG_RUNTIME_DIR/sala-web-ttyd/ttyd.sock`, under the path `/tty/`.

Start them:

```bash
systemctl --user daemon-reload
systemctl --user enable --now sala-web.socket sala-web.service sala-web-ttyd.service
sudo loginctl enable-linger "$USER"     # optional: keep them running after you log out
```

Good result: `systemctl --user status sala-web.service sala-web-ttyd.service` shows both `active`.

Now the login. [docs/web-proxy.md](web-proxy.md) has a Caddy recipe that was run and checked, and an outline for a Cloudflare tunnel with Cloudflare Access. In short, for Caddy:

1. Make a password hash: `caddy hash-password`. It asks for the password twice and prints the hash. Do not put the password in the command.
2. Write `~/.config/sala-web/Caddyfile` (mode 600) with a login (`basicauth`) and two `handle` blocks: `/tty` and `/tty/*` go to the ttyd socket, everything else goes to the sala-web socket. **Both need the login.** A login on one only leaves the other open. Keep `admin off` in the Caddyfile.
3. Stop the system Caddy that the package starts (`sudo systemctl disable --now caddy`), and run Caddy as your own user, as a user unit (`sala-web-proxy.service`; the recipe has it). It must run as you to open the sockets.
4. Give your user permission to listen on port 443. The recipe shows two ways: one `sysctl` line, or `setcap` on the Caddy binary.
5. Point a name at the machine (a DNS record) and open TCP ports 80 and 443 to it, so Caddy can get a certificate. On a machine reachable only through a VPN, use the VPN's own HTTPS certificates and skip this recipe.

Keep Caddy's `Host` header as it is: a proxy that rewrites it breaks the Terminal tab and every send. The full text of the Caddyfile and the unit is in [docs/web-proxy.md](web-proxy.md).

Check it, from the machine:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://your-name.example.com/        # 401 without credentials
curl -s -o /dev/null -w '%{http_code}\n' https://your-name.example.com/tty/    # 401 without credentials
ss -ltnp | grep -E 'sala-web|ttyd'                                              # prints nothing: no TCP port
```

Good result: both `curl` lines print `401`, and the `ss` line prints nothing.

The page settings (`SALA_BRAND_SUFFIX`, `SALA_HELP_SESSION`, `SALA_SHELL_SESSION`, `SALA_TZ`, `SALA_SCOPES`, `SALA_OWNER_NAME`) all reach the web UI from the same config file. The web UI's own variables (`SALA_WEB_*`) are listed in `web/README.md`. You rarely need them.

What you see once you are in (`web/README.md` has every detail):

- **Overview.** The lane cards, then four tabs: **Agents** (the sessions), **Schedules** (the scheduled jobs of this machine, read from systemd and cron), **Machines** (the tool versions of each machine, read from the board's files: without a board the tab says there is no reading yet) and **Usage analysis** (what this machine's Claude Code replies cost at list prices, by week, day, lane, model, project, agent and folder; the Report view first, then Explorer (compare any two things side by side and list the replies behind a row) and a Digest of the week in a few plain sentences, in dollars only; other machines are not counted). A **Get Help** chip appears when `SALA_HELP_SESSION` is set.
- **A session.** Its chat, with a box that types into the session, and a **Terminal** tab. The **Shell** button opens a plain terminal on this machine. The search box in the sidebar (Ctrl+K) searches the transcripts on this machine and opens its results in a new tab.
- **Unread.** The entry under Overview shows how many replies are waiting across your front agents. Tap it to list only the agents with an unread reply (the one you have open stays until you leave it, folded projects open while it is on, and an empty list says "Nothing unread"); tap again to see everything. The choice is kept for the phone and the desktop alike.
- **New session** is a form that queues a project session (`sala op spawn`) and asks the board for the project, so it needs the board (step 9).
- **Looks.** The page follows your browser's light or dark setting. The dark look is one orange (`#f0a06a`) on the neutral greys. Small labels (an unread count, the front-agent badge, the `max` effort tag) are that orange on a deep brown (`#3a2619`), and a disabled solid button (Send, Create session) is a flat grey (`#a3a29d` on `#2a2a2c`) at full opacity. The light look keeps its own orange and fades a disabled button.
- **Colors.** In the dark look only, a **Colors** button at the bottom of the sidebar opens a panel for trying other colors: presets (the first is what the page ships), saved combinations, and behind a **Fields** button the 14 color fields. A pick stays in this browser; **Reset** puts the shipped look back. The saved combinations are one list kept on the board: without a board the panel says the list is unavailable, and everything else in it works.
- **The board's look.** The page is drawn with the board's look: one type scale, two font weights, a 4 px grid, one orange, a monospace face for code, and a column of at most 920 px. `https://your-name.example.com/v2/`, where this look was first tried, redirects to `/` for a while (it will be dropped later), so an old bookmark still lands on the page.

## 4. Adding a project

A project is a page on the board with a name. sala names a session after it: `<scope>-<project>-<word>`, for example `work-budget-main`.

- Create the project page on the board first. [The board guide](https://github.com/howardpark-ai/stackshot/blob/main/docs/board-alone-guide.md) shows how (its section "Adding a project").
- Ask sala for a free name: `sala spawn --suggest-name --project projects/budget --role front`. It prints a name that is not taken, such as `work-budget-tide` (the default scope, the project, a word).
- Spawn the session with `sala spawn NAME --project projects/budget --role front`. The name must be registered with stackshot first. If it is not, sala exits with 3 and prints `REGISTER:` and the `post project-agent` command that registers it.

## 5. Lanes and other options

None of this is needed on day one.

- **Lanes.** The default lane is `subscription-1`, your own Claude Code sign-in (shown as Subscription 1; `sala lane names` prints every lane's code and display name). `sala lane --list` shows all of them: `subscription-1`, `subscription-2`, `api`, `bedrock`, `aws-platform`, and `sdk`, which is `api` run through the Agent SDK. Older lane words are still read as aliases. A lane that is not set up shows as not ready, and nothing uses it. To keep one session on its lane through every bulk move (`sala lane <lane> --all`, `sala lane default <lane>`, the lane fallback and the back agents' rule), pin it: `sala lane pin <session> <lane>` (`sala lane pins` lists them, `sala lane unpin <session>` lifts it). A bulk move lists what it skipped as `skipped (pinned to <lane>): <session>`; a move that names the session still moves it.
- **Amazon Bedrock.** It is ready only when `SALA_LANE_BEDROCK_PROFILE` names a profile in `~/.aws/credentials`. A profile with "admin" in its name is refused. It also needs `SALA_LANE_BEDROCK_REGION` (the AWS region where your Bedrock access is enabled); there is no default region, and with it unset the lane stays "not set up" and says so.
- **Lane fallback.** By default, when a lane is marked dormant, sala moves its sessions to the fallback lane, which is `bedrock` for most lanes. On an install without Bedrock nothing can move, and one alert line says why. Set `SALA_LANE_FALLBACK_AUTO=off` to stop the attempt. A lane stopped by a monthly usage cap (the provider's 429 says the account crossed its monthly usage threshold and when access returns) is handled the same way: the watch marks it dormant until that time, moves its sessions to the fallback (a session in the middle of a turn gets one Escape first, since it would never go idle on a lane that refuses every request), posts once, and brings the lane back by itself when the time passes. See `docs/lanes.md`.
- **Moving background agents off a lane near its weekly limit.** Off by default. A background agent is a session whose registry row says role `back` (`sala spawn NAME --project <page> --role back` makes one), or a session with no role on the row that stackshot's project record lists as a project's background agent (the watchdog writes the role onto such a row by itself; `sala sessions tag --auto --dry-run` shows what it would fill). With `SALA_BACK_LANE_RULE=on` the watchdog keeps these sessions, and no others (never a front agent, a side session or a job), off the home lane near its weekly limit, in three steps:
  1. The home lane's "This week" limit reaches `SALA_BACK_LANE_THRESHOLD` percent (90 by default): the background agents move to the second lane.
  2. A pane on the second lane stops on its cap: they move to the third lane.
  3. The home lane's weekly window resets: they all move home, wherever they are.

  `SALA_BACK_LANE_ORDER` names the three lanes (default `subscription-1 aws-platform bedrock`; two lanes make a rule with no step 2). Each move is a queued `sala op lane` from the watchdog, so a busy pane waits until it is idle, and each step fires once per weekly window. The rule reads the home lane's usage from the web UI's saved answer, so it needs the web UI (step 10): a reading that is missing, failed, incomplete or older than `SALA_BACK_LANE_MAX_AGE` seconds (1800) moves nobody, and when that reading is missing or old the watchdog first asks the local web UI for a fresh one. A target lane that is dormant or cannot launch is not moved onto: you get one notice, nothing moves, and a later pass tries again. A background agent spawned while the rule has them off home starts on the rule's lane. Try it first with `sala watch --back-lanes --dry-run`: it prints one line per outcome (for example `idle: the back agents stay on the Subscription 1 lane (Subscription 1 at 42%)`, or `would: step 1 …` with the `sala op lane` it would queue) and queues and writes nothing. With the rule off it says `idle: SALA_BACK_LANE_RULE is off: the rule is off`. `config.example` and the section "The back agents' lane rule" of [lanes.md](lanes.md) list every setting.
- **CI runs.** The poller that watches GitHub Actions needs `gh` signed in (`gh auth status`; it reads through `gh api -i`). `sala mq` and `sala mq doctor` need it too. The poller reads `~/.config/salamander/ci-repos`: one `owner/name` per line. The tracked default lists none, so a fresh install polls nothing. See [docs/ci-runs.md](ci-runs.md). To run it, link `systemd/sala-cipoll.service` into `~/.config/systemd/user` and enable it.
- **A merge queue.** `sala mq` queues the pull requests of a repository that has no GitHub merge queue, tests each one stacked on the PR ahead of it, all at once, and writes the verdict down. It does nothing until a host file `~/.config/mergequeue/<owner>__<repo>.toml` sets `mode`: `shadow` tests and writes the verdict down without merging, `on` merges, and no file or `off` does nothing. There is one way of queueing (the older group mode is gone: a `queue_mode = "group"` line blocks the queue until you delete it). The verbs are `mq add N…`, `status`, `drop N`, `pause`, `resume`, `wait N` and `doctor`; `sala mq doctor --repo <owner>/<repo>` checks the host file and the tools and changes nothing. See [docs/mq.md](mq.md).
- **Scheduled jobs.** `sala job add` makes a systemd timer with a description, a lane and a project. It reads the repos it may write to from `~/.config/salamander/unit-repos.tsv`; the tracked default lists none. See [docs/units.md](units.md).
- **Telling every session something.** `sala notice add "<text>" --from <you>` shows one line to every live session at its next tool call or prompt, once, with no relaunch (`sala notice list`, `sala notice drop <id>`). It needs the `UserPromptSubmit` hook of step 3 for the prompt half; the tool-call half rides the `post-tool` hook. See [notices-and-hooks.md](notices-and-hooks.md), *Telling every session something*.
- **Other machines.** `SALA_FLEET_HOSTS` lists ssh names that `sala update --fleet` also updates. Empty by default. A second feature, **machine-follow**, keeps the other machines level with the one that drives them (the sala and board commits, the Claude version) through four user units in `systemd/` and a data file you write, `~/.config/salamander/machine-follow.toml`. It runs on the driving machine only and nothing runs it unless you link the units. `python3 ~/salamander/lib/machine-follow.py --dry-run` says which machines are due and changes nothing; [docs/units.md](units.md) has the rest.
- **A master session.** `SALA_MASTER` names one tmux session the watchdog keeps alive. It is optional. `sala op <verb>` replaces it.
- **Fleet operations.** A recycle, a CLI update, a revive, a lane or model change, a provision or a retire that many sessions or people may ask for goes through a queue the watchdog runs: `sala op <verb> … --from <name> --words "<what you said>"`. `sala op --list` shows the queue, `sala op --plan <verb> …` shows what a verb would do, and `sala op --cancel <id>` drops a queued one. A reboot is not queued: you run `sala reboot --go` yourself (see `docs/reboot-contract.md`).

## 6. Updating

Type these in the web UI's Shell (without the web UI, in a shell on the machine).

```bash
~/salamander/deploy.sh --dry-run     # shows what an update would do; changes nothing in the checkout
~/salamander/deploy.sh               # brings the checkout to the newest main
```

`deploy.sh` refuses when the checkout has local changes to tracked files, is not on `main`, or has commits of its own. It runs `install.sh` again only if `install.sh` or `config.example` changed. It never restarts a session. If a file under `web/` changed, it runs `uv sync --frozen` there and restarts `sala-web.service`.

A changed unit file under `systemd/` is **reported, not installed**. Copy it again (step 7) and run `systemctl --user daemon-reload`.

`deploy.sh --check` is the lightest form: it compares the checkout with GitHub's `main` and changes nothing.

Updating Claude Code itself is a different job: `sala update` runs `claude update` and relaunches every session, each one when it is idle. With the watchdog running, `SALA_AUTO_UPDATE` does this for you.

## 7. Left out of this guide

- **The board.** It has its own guide (linked at the top).
- **Chat alerts.** `SALA_WATCH_NOTIFY_CMD` takes any command that reads a message on stdin. Slack is one example. None is assumed.
- **Briefings.** `contrib/briefing/` has a daily summary and a release watcher, as systemd timers. They are written for one person's setup and are not needed.
- **API key and SDK lanes, Bedrock and AWS.** See section 5 and [lanes.md](lanes.md).
- **macOS.** Not tested.
- **Cloudflare Access instead of Caddy.** Outlined in `docs/web-proxy.md`, not run.

## 8. If something goes wrong

Type the commands in the last column in the web UI's Shell (without the web UI, in a shell on the machine).

| What you see | Likely cause | Do this |
|---|---|---|
| `sala: command not found` | `~/.local/bin` is not on `PATH` | Add it in `~/.profile`, then open a new shell |
| `bin/salamander refuses to run` | bash older than 4.4 | Install a newer bash |
| `install.sh` says `missing: claude` | Claude Code is not installed for this user | Install it, then run `install.sh` again |
| `settings.json` warnings after step 3 | A hook is missing or the file is not valid JSON | Compare with step 3; check with `python3 -m json.tool ~/.claude/settings.json` |
| `sala spawn` says the lane is not ready | The lane you named has no credentials | Use the default `subscription-1`, or set the lane up (section 5) |
| A session ran `sala ready` and was not relaunched | A subagent it started is still running. sala never cuts a running subagent: `sala ready` names it, and the relaunch follows within minutes after it ends | Let the subagent finish, or stop it from that session. `sala watch` logs one line naming what holds the pane, not one per check |
| Filing a question fails and names `SALA_DEFAULT_SCOPE` | No scope is set | Set `SALA_SCOPES` or `SALA_DEFAULT_SCOPE` (step 4) |
| The board refuses a question's subject | The scope is not one of the board's subject prefixes | Make the two lists match (step 4) |
| Filing a question fails with `lists no front agent` | The project page has no `agents:` entry, or the board's registry has not refreshed yet | Add a front agent to the page's `agents:`, then wait up to 10 minutes or refresh the registry at once (step 9) |
| `spawn --project` says `cannot tell` or exits with `NO-PAGE:` | There is no board, or no such page | Install the board (step 9), or create the page, or set `SALA_AGENT_CHECK=off` |
| The web UI's Shell drawer shows the old session name | `SALA_SHELL_SESSION` is read once | `systemctl --user restart sala-web.service` |
| `systemd-analyze verify` says `sala-web` is "not executable" | `uv sync --frozen` was not run in `web/` | Run it (step 10) |
| `systemctl --user` cannot reach the user manager | The shell is not a login shell | `export XDG_RUNTIME_DIR=/run/user/$(id -u)` or log in again |
| The units stop when you log out | Lingering is off | `sudo loginctl enable-linger "$USER"` |
| A browser opens the web UI with no login | The proxy covers only one of `/` and `/tty/` | Put the login on both (step 10), then repeat the `curl` checks |
| The Terminal tab is blank, or a send is refused | The proxy changed the `Host` header, and the origin check fails | Keep `Host` as it is (the Caddy recipe does) |
| The back agents do not move although the home lane is near its limit | The rule is off, or the web UI cannot give a fresh usage reading | `sala watch --back-lanes --dry-run` says which: `SALA_BACK_LANE_RULE is off`, or `no usable <lane> reading` with the reason. Turn the rule on (section 5); start the web UI (step 10) |
| The Colors button is missing | The page is in the light look: the panel is for the dark look only | Switch the browser or the system to dark |
| Alerts never reach you | `SALA_WATCH_NOTIFY_CMD` is empty, so nothing is sent | Set it to a command that reads the message on stdin |
| A pane does not come back after a reboot | tmux-resurrect is not set up, or `claude` is in `@resurrect-processes` | Step 8 |
