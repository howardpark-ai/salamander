---
name: verify-sala
description: Drive salamander's real `sala` CLI and sala-web routes on a throwaway instance and keep the evidence. Use to prove what a change does for a user (a pull request's "Done when" check), or to reproduce how a command or a web route behaves.
---

# verify-sala

One script, `verify.sh`, makes a throwaway instance (its own HOME, tmux socket, web socket and a fake `claude`), checks it,
runs journey files against it, keeps the evidence and removes the instance. The instance is built from the suites' own pieces
(`tests/lib.sh`, `tests/fake-claude.c`).

A pass says what the commands and routes did here. [Not covered](#not-covered) lists what it cannot say.

## Launch

From the checkout root, on the test host (the machine your own settings name for running `tests/run.sh`), never on a machine
that runs a live fleet:

    bash .claude/skills/verify-sala/verify.sh prove

Needed there: Linux, bash 4.4 or newer, `tmux`, `python3`, `cc`, `jq`, `curl`, `flock`, `git`, `tee`, and `uv` for a journey
that uses the web app (its first run may download the app's locked dependencies).

There is no server to keep running and nothing to tear down by hand: one call launches, drives and cleans up. The instance is
ready when every line under `== doctor` says `ok`. A whole `prove` takes under a minute.

## Doctor

The first part of every run, read only, before any journey. It requires:

- HOME is the run's scratch folder, and sala's state folder, its tmux socket and `claude` are inside it;
- `claude` is the compiled fake;
- tmux holds only the instance's own sessions, the registry is empty and `sala spawn --list` shows no Claude session;
- with the web app: `sala-web` answers on its socket and lists no session.

If one fails, nothing is driven and the run ends `verify-sala: NO VERDICT` with exit 2. Read the `FAIL  doctor:` lines in
`results.txt`, then `web.log` or `uv-sync.log`.

## Drive

    bash .claude/skills/verify-sala/verify.sh run <journey.sh>...

The skill's journeys are in `journeys/`, one for each file in [the feature map](features/README.md); read the map first. A
journey is a bash file, run in a subshell from the instance's `$HOME/work`:

```bash
# needs: web                                      (only when the journey calls `web`)
U=$(uuid 401)                                     # a conversation id: pick a number no other journey uses
start_session vs-test-mine "$U"                   # a fake claude in a pane of its own
sala adopt vs-test-mine
check "adopt exits 0" [ "$RC" = 0 ]
check "the pane map has its row" has "$(map_row vs-test-mine)" "$U"
```

| helper | does |
|---|---|
| `check <label> <command...>` | one result line: `ok` when the command succeeds, `FAIL` when it does not; `not <command...>` negates |
| `sala <argv...>` | runs the checkout's `sala`; sets `OUT` (stdout and stderr) and `RC` |
| `start_session <name> <uuid> [VAR=value...]` | a session started by hand; the variables are the fake claude's `FAKE_*` knobs (top of `tests/fake-claude.c`) |
| `next_spawn <uuid> <name>` | what the next claude that `sala spawn` starts registers as |
| `new_cli_version <version>` | points the `claude` launcher at another binary, so running sessions are behind it |
| `claude_pid <name>` · `screen <name>` · `map_row <name>` | the session's claude pid, its non-empty screen rows, its pane-map row |
| `typed <uuid>` | the lines that reached that conversation's composer |
| `web <METHOD> <path> [body [content type [Origin]]]` | one request to the instance's `sala-web`; sets `CODE` and `BODY` |
| `json [jq options] <filter>` | holds when the filter is true of `BODY` |
| `tmux`, `waitfor '<condition>' [half seconds]`, `reg_live`, `starts <uuid>`, `has <text> <needle>`, `uuid <n>` | the private tmux server, and the helpers of `tests/lib.sh` |

Rules for a journey:

- Drive what a user drives: the `sala` command line, the web routes, keys in a pane. Do not call a function in `lib/` or write
  sala's state by hand.
- After an action, check a second view of it (the pane map, the composer log, the screen, another route), not only the reply.
- Journeys of one run share one instance, in the order named: use your own session names (`vs-test-<topic>`) and ids, and put
  back what you change for everyone (the launcher).
- A journey fails on any `FAIL`, on a nonzero end status, and when it made no check. Never weaken a check to pass: when the
  instance cannot give a precondition, say so in that feature's `Gotchas` and report it as not verified.

### Proving a pull request

A change to a mapped behavior updates that journey and its feature file; anything else gets a journey of its own, passed by
path. The "Done when" line names the command and its verdict, for example: "`verify.sh run
.claude/skills/verify-sala/journeys/web-send.sh` exits 0 and ends `verify-sala: PASS`".

Show that the check can fail: run the same journey file with the base commit's `verify.sh` (a worktree of the base branch) and
read `verify-sala: FAIL` on the line the change is about. A check that passes on both proves nothing about the change.

## Evidence

Each run writes a new folder, `verify-evidence/<run>/` in the checkout (ignored by git), or under `$VERIFY_SALA_EVIDENCE`. Its
last output line names it.

| file | holds |
|---|---|
| `transcript.txt` | every action, its output and exit code, every check, the verdict |
| `results.txt` | one line per check and per journey, the cleanup line, the verdict |
| `web/<n>.body`, `web.log`, `uv-sync.log` | each reply of the web app, its log, its dependency install |
| `pane-map.tsv`, `typed.log`, `fake.log`, `screens.txt` | sala's map, what reached each composer, every claude start, the last screens |
| `salamander-revive.log`, `notify.txt`, `stubs.log` | sala's log, its notices (they go to this file, not to chat) and the calls to the stubbed commands |

A record the run never wrote is absent.

To report a proof, give the command, the journey lines, the `cleanup:` line and the verdict line. The files hold the test
host's name and paths: do not paste them into a pull request. A feature or an entry point that no journey drove is not verified.

## Cleanup

Automatic, whether the run passes, fails or is interrupted: the private tmux server is stopped, the processes this run started
(known by the run's scratch folder in their environment, never by name) are ended, and the scratch folder, locked while the run
lasts, is removed. The run fails if a process or the folder is left. The evidence folder is not touched; delete old ones by hand.

A run that was killed outright (`SIGKILL`) cleans nothing: its `vs.*` folder stays under `$TMPDIR` (or `/tmp`), and its
processes, named by that folder in their environment, may still run.

## Helpers

`verify.sh` is the only one.

| call | runs | exit |
|---|---|---|
| `verify.sh prove` | every journey in `journeys/` | 0 pass · 1 a check or journey failed, or something was left · 2 no verdict |
| `verify.sh run <journey.sh>...` | the files named | the same |
| `verify.sh --help` | prints its usage | 0 |

## Not covered

The instance stands in for a real install. None of this is verified until a run on a real one covers it:

- **The real CLI.** `claude` is the fake: no model turn, a screen of a few rows, an input box whose two rules the instance
  draws for it, a registry version that is always `9.9.9`, and transcripts that a journey writes by hand.
- **The machine around sala.** `systemd-run`, `systemctl`, `loginctl`, `ssh` and `gh` are stubs; guarded verbs run as the
  operation queue's runner would run them, so the queue and its refusals are not exercised; automatic update, automatic
  recycle, the agent check, the project board and stuck-operation alerts are off; waits are the suites' short ones.
- **Installing and serving.** No `install.sh`, units or deploy; `sala-web` is started by hand on a unix socket, with no
  terminal service, sign-in or proxy in front.
- **A browser.** Routes are called with `curl`; no script of the page runs.
- **Features with no journey:** retire, recycle and its posts, lanes and models, sleep and wake, restore, scheduled jobs.
- **Other systems.** Linux only.
