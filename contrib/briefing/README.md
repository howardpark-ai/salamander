# briefing: the morning posts to Slack

Three daily posts to a Slack briefing channel: two email digests written by a headless
`claude -p` turn, and a release watcher with no LLM in its probes. They live in `contrib/` because they are the wiring of one
deployment (its Gmail through a claude.ai "Google Workspace <word>" connector, `BRIEFING_GMAIL_CONNECTOR`, its webhook), not part of
sala. sala's core does not depend on them. The one link is the other way round: sala's `SALA_WATCH_NOTIFY_CMD` can
source `lib.sh` to post its notices through the same webhook.

## The scripts

| file | what it does |
|---|---|
| `sdk_run.py` | One turn through the Claude Agent SDK on the API credit while the key has credit (below). |
| `guard.py` | The read guard (below): a PreToolUse hook that refuses, before it runs, any portal call that is not plainly one of the five Gmail reads, and any other Workspace tool that can write. Loaded only by the digests' own runs, through `--settings`. |
| `lib.sh` | Shared helpers, sourced by the others. `post_slack <text>` posts to the incoming webhook (turning `**bold**` into Slack's `*bold*`, then linking session names (to sala's own session link (`SALA_SESSION_URL` from the sala config, with the name in place of `{name}`), for every live session in sala's registry, `sala sessions --json`, bridged or not; `sala spawn --list` with a 20 s cap only if the registry is empty or fails), board ids, `<repo>#N`, commits, knowledge-base page slugs (the last three only when `BRIEFING_GITHUB_BASE` names the GitHub account they link into; unset: they stay plain) and the digests' `[gmail:<threadId>]` markers; a linker failure sends the unlinked text; with `BRIEFING_NO_POST=1` it writes the text to `~/.local/state/sala-briefing/would-post.log` instead). `run_claude` runs one headless turn with only the Gmail read tools (and the portal's two code-mode tools) allowed, the read guard loaded, and keeps its stream-json log. `deliver` posts the result. Sourcing it only defines things and never exits the caller. |
| `summary.sh` + `summary.prompt.md` | Morning Email Summary. Also carries a "New holds (last 24 hours)" section when stackshot reports any (below). |
| `summary-lean.sh` + `summary-lean.prompt.md` + `gmail_fetch.py` + `lean-compare.sh` | The lean Morning Email Summary (below): code reads and trims the unread mail, one model call with no tools writes the text. Run with `--post` (the installed unit does) it posts the digest to the briefing channel; without it the script writes `lean/YYYYMMDD.txt` and posts nothing. |
| `holds.py` | The new holds of the last 24 hours, for `summary.sh`. Reads stackshot's `GET /client/brief` with the machine token, outside the model, and prints the new-hold lines framed as a data block (nothing when there are none). |
| `defunct.sh` + `defunct.prompt.md` | Forwarded Address Unsubscribe Queue: the unread mail under the Gmail label `BRIEFING_FORWARD_LABEL`, classified, read only. The job is label-driven and off by default: with no label set it writes one `cron.log` line and exits 0. |
| `release-alert.sh` | Runs `release-watch.sh` and posts what it prints, unless that is `NO_REPLY`. A failed probe gets a ⚠️ post. |
| `release-watch.sh` | Probes the Claude Code CLI and the Ubuntu LTS upgrade path. A release not announced before is printed once, and the session that owns the upgrade is pinged. The Claude Code CLI's owner is sala's master; with none it is `RELEASE_WATCH_CLI_OWNER` (the environment, else the sala config's line; unset: nobody is pinged; `release-watch.sh cli-owner` prints it). The Ubuntu LTS path goes to `RELEASE_WATCH_UBUNTU_SESSION` and names the plan's page `RELEASE_WATCH_UBUNTU_PAGE` (unset: posted only, no page named). `release-watch.sh defer <product> [tag]` keeps one release quiet until a newer one appears. |
| `reply.sh <thread_ts> [text]` | A reply in the thread of a message in the briefing channel (a fast-lane chat with the briefing session). The text is the argument, or stdin when it is omitted or `-`. It goes through `post_slack` with `BRIEFING_THREAD_TS` set, which adds `thread_ts` to the webhook payload. Prints Slack's answer (`ok`); a ts that is not digits.digits, or an empty text, is a one-line error and exit 2, and nothing is posted. |

**The read guard.** The model may only read mail. On the portal route the model writes
JavaScript for `portal_codemode_execute`, whose `codemode` object can call every tool of every connected server, and
`--allowedTools` cannot see inside that code: a prompt injection in an email could make a run send, draft, label or
touch Drive. So `run_claude` loads `guard.py` as a PreToolUse hook on every `mcp__*` tool, through `--settings` on the
`claude -p` call and through the SDK's `settings` option (the same flag), which is why no other session gets it. The
hook refuses a `portal_codemode_execute` before it runs unless its code is one `async () => ...` whose every use of
`codemode` is `codemode.<one of the five Gmail reads>(...)`: no other `codemode.` name, no computed access or alias, no
`eval`/`Function`/`import`, no reflective names, no escaped or non-ASCII identifiers, no free identifier that is not a
declared local or a safe global (the portal's `codemode` is a lexical binding, so an unknown name is treated as a reach
into that scope). `portal_codemode_search` stays allowed (it only lists tools); any other `mcp__*` tool whose name
carries a write verb is refused by name, belt and braces beside `--allowedTools`. The refusal reason goes back to the
model, which rewrites the call; the decision line goes to `~/.local/state/sala-briefing/guard.log` (never the code). The
header of `guard.py` has the rules and the limits: it is a second wall, ahead of the after-the-fact check below and
beside `--allowedTools`, not the only one.

A guard that did not load would fail silently, so `deliver` checks that it ran. `run_claude` counts `guard.log`'s lines
before the turn's first attempt (the claude -p rerun after a failed SDK run, and `run_claude_retry`'s retry, keep that
first count) and again after the turn. If the turn made one or more `portal_codemode_execute` calls and `guard.log`
gained no line, the digest is held back with a 🚨 "held back: the read guard did not load" notice naming the run and
its stream log. Any new line counts, allow or deny, since either shows the hook ran. A turn with no portal call (the
direct connector) is not checked.

**The delivery guard.** The shell decides what gets posted. `run_claude` counts the Workspace tool calls in the stream
log: calls of the claude.ai connector's tools, plus `portal_codemode_execute` calls whose code calls one of the portal's
five Gmail reads (`g<word>_search_gmail_messages`, `g<word>_get_gmail_message_content`,
`g<word>_get_gmail_messages_content_batch`, `g<word>_get_gmail_thread_content`,
`g<word>_get_gmail_threads_content_batch`) and that ran. A portal call without one of them does not count, nor does a
call the read guard refused (it never ran). A `portal_codemode_execute` whose code names any other `g<word>_` tool (a
send, draft, label, filter, modify, trash or delete tool, or any Drive, Calendar or Docs tool of that server) and that
ran holds the digest back with a 🚨 notice that names the tools and says to check the mailbox: the second line, for a
call that got past the read guard, detected after the fact. A call the read guard refused is not reported as a write;
it is named in `cron.log` and in a ⛔ line under the posted digest, so a refusal is seen. `deliver` posts the digest
only when the read count is above zero. Otherwise it posts a 🚨 "held back" notice in its place, because a digest
written without reading Gmail could be made up. A run that failed, produced no text,
or met the connector's re-authorization error gets a 🚨 notice too. The OAuth error is retried once after 45 s. So a
quiet channel always means the job did not run.

## Schedule

| timer | fires daily at | runs |
|---|---|---|
| `sala-briefing-summary-lean.timer` | 06:00 UTC | `summary-lean.sh --post`, which posts the digest to the briefing channel |
| `sala-briefing-defunct.timer` | 06:15 UTC | `defunct.sh` (off until `BRIEFING_FORWARD_LABEL` is set) |
| `sala-briefing-release.timer` | 06:30 UTC | `release-alert.sh` |

The times are neutral defaults, written in each unit's `OnCalendar` line with the zone after the time
(`*-*-* 06:00:00 UTC`), so the machine's own clock does not matter. Edit the line to move one, for example to
`*-*-* 07:30:00 Europe/Berlin`, then re-copy the unit and `systemctl --user daemon-reload`. The zone in `OnCalendar` is the
timer's own; the zone the posts show their times in is `BRIEFING_TZ` (below).
They also use `Persistent=true`: a post missed while the machine was off goes out late, after the next boot, instead of
being skipped.

## Briefing settings

These are read from the environment, else from the sala config (`~/.config/salamander/config`; `config.example` has the
other briefing lines), and nothing is sourced. Each is optional.

| setting | what it does | unset or empty |
|---|---|---|
| `BRIEFING_TZ` | The IANA zone name (for example `Europe/Paris`) the digests show their times in: the mail dates, the "As of" line, the clock in the posts. `lib.sh` exports it as `TZ`. | `UTC` (so is anything that is not a plain zone name) |
| `BRIEFING_WATCHLIST` | The companies and topics a Google Alert must be about to count in the mail summary, comma-separated (for example `Example Corp, drip irrigation`); fills `{{WATCHLIST}}` in the two summary prompts. | the prompts read `none configured` |
| `BRIEFING_LOW_PRIORITY_SENDERS` | Senders and kinds of mail that stay low-priority in the mail summary unless they are a security, billing or legal issue, comma-separated (for example `news@example.com, weekly newsletters`); fills `{{LOW_PRIORITY_SENDERS}}` in the two summary prompts. | `none configured` |
| `BRIEFING_FORWARD_LABEL` | The Gmail label of the defunct-address queue, one plain word (letters, digits, `.`, `_`, `-`, `/`); fills `{{FORWARD_LABEL}}` in the defunct prompt. | the defunct job is off (one `cron.log` line, exit 0) |

## Where secrets, logs and state live (outside the repo)

| what | path |
|---|---|
| Slack incoming-webhook URL (secret; mode 600, never in git) | `BRIEFING_WEBHOOK_FILE`, default `~/.config/sala-briefing/slack-webhook` |
| logs: each run's stream-json `<job>.<YYYYMMDD>.jsonl` and `.err`, `release-watch.err`, and `cron.log` (the timers' stdout and stderr, appended by the script itself under `BRIEFING_CRON_LOG=1`) | `BRIEFING_LOGDIR`, default `~/.local/state/sala-briefing/` |
| an older log directory, `BRIEFING_OLD_LOGDIR` (unset: none): `lib.sh`'s `migrate_old_logdir` carries its files over the first time a briefing script runs (plain files, `mv -n`, nothing overwritten; a name present in both stays in the old directory, named on one `cron.log` line; the old directory is removed once empty). `lib.sh` creates the log directory itself | |
| release watcher state: `notified/<product>` (last tag announced), `deferred/<product>` (a parked tag) | `~/.release-watch/` |

`lib.sh` keeps the caller's `HOME` (the passwd entry's home when unset), sets its own `PATH`, `TZ` (from `BRIEFING_TZ`, below) and the paths above. These scripts are one deployment's wiring: adapt them before you use them elsewhere. `SALA_BRIEFING_MODEL` picks the digest model (default `sonnet`). The posts name the
machine they ran on ("Details: <log> on <name>", "<name> runs <version>") by `SALA_HEARTBEAT_NAME` (the environment, else its
line in the sala config); unset or empty, by the hostname.

The three services run on the bedrock lane (their `ExecStart` goes through `salamander lane exec bedrock --`, below). The defunct
digest and the release relay try the API key first while it has credit (*While the API key has credit*, below) and fall back to
`claude -p` on that lane; the lean summary calls `claude -p` itself and never uses the key (its unit keeps
`Environment=BRIEFING_BACKEND=cli`). Each unit sets `Environment=BRIEFING_CLAUDE_CONFIG_DIR=` (empty) and
`UnsetEnvironment=ANTHROPIC_API_KEY ANTHROPIC_CUSTOM_HEADERS` (the key itself is read from its file by `sdk_run.py`, never from the
environment), so a drop-in is not needed for the lane.

**A scheduled job runs on the bedrock lane, not on a subscription lane, so the three services do:**
each `ExecStart` is `salamander lane exec bedrock -- <script>`, which starts the script with the lane's environment from sala's lane
config (AWS profile, region, the pinned model ids; `salamander lane env bedrock` shows the names and values, no secret) and without a
key, so the digests' `claude --model sonnet|haiku` resolves to the lane's pinned ids. The mail still comes through the MCP Portal
(`mcp-portal` is in `~/.claude.json`, its sign-in in `~/.claude/.credentials.json`). To put a service back on the subscription-1 lane, take the
`salamander lane exec bedrock --` words out of its `ExecStart` and set `X-Model-Lane=subscription-1` (older lane words are still read as aliases).

`BRIEFING_CLAUDE_CONFIG_DIR` picks another login for the digests: when set, their `claude` runs with `CLAUDE_CONFIG_DIR`
set to it. Empty (the units' default) or unset, it uses the caller's own config. Set it in a drop-in on the two digest
services for another login (a login with no claude.ai
"Google Workspace <word>" connector: the prompts tell the model to read the same mailbox through the MCP Portal
instead, `portal_codemode_execute` with `codemode.g<word>_<tool>`, and only with the five Gmail reads). Either way the
digests' `claude -p` never gets `ANTHROPIC_API_KEY` or `ANTHROPIC_CUSTOM_HEADERS`: with the key it would bill the key and
load no connector, so a briefing on this path always runs on a login (the SDK run below is the one exception).

## While the API key has credit: the Agent SDK on the API credit

The defunct digest, `summary.sh` and the release relay run through the
Claude Agent SDK on the key at `~/.config/anthropic/api-key` (with the header `anthropic-workspace-id` from
`~/.config/anthropic/workspace-id`) while the key has credit, and fall back to `claude -p` on a login (the unit's lane) when it
has none. The credit pays for direct API and Agent SDK calls. It refuses `claude -p` with the key ("credit balance is too low"),
so this is the SDK itself, never a CLI run made to look like one.

**How the choice is made.** The balance cannot be read, so the refusal is the signal, kept in one file shared with every other
job that may spend the key (the sdk lane and any other job that spends the same key): `${XDG_STATE_HOME:-~/.local/state}/api-credit/state.json`,
`{"refused_at": <epoch seconds>, "by": "<job>", "detail": "<first 200 characters of the refusal>"}`; no file = no known
refusal (`lib/api_credit.py` is the one writer, `lib/api-credit.sh` the shell reader). With a readable key file and no `refused_at`
in the last `API_CREDIT_RETRY_S` seconds (default 21600, 6 hours) the run uses the key; otherwise it goes straight to `claude -p`.
`sdk_run.py` writes the file when the key's call comes back with "credit balance" in the result, the SDK exception or the CLI's
stderr (the turn then reruns on `claude -p`, as before), and removes it when a call works. So a refusal costs one failed call, the
next six hours go straight to the login, and the first run after them tries the key again and finds a top-up by itself.
`BRIEFING_BACKEND=cli` still forces the login path.

- `sdk_run.py` runs one turn: `uv run --quiet --no-project --with claude-agent-sdk==0.2.165 python -I sdk_run.py`, the
  prompt on stdin, the same model, the same allowed tools and the same 600 s cap. It loads only the `mcp-portal` server
  from `~/.config/claude-lanes/api-mcp.json` (its OAuth token is in `~/.claude`), no settings files, hooks or CLAUDE.md;
  the one settings input is `--settings`, the read guard's JSON from `lib.sh`, handed to the CLI's own `--settings`
  flag through `ClaudeAgentOptions(settings=...)`. It prints `claude -p`-style stream-json lines, so the delivery guard
  reads them unchanged. It reads the key itself and puts it only into the env of the CLI process the SDK starts; the
  shell never exports it.
- The lean summary's unit sets `BRIEFING_BACKEND=cli` (it never goes through `run_claude`); the defunct and release units
  leave it unset.
- `run_claude` uses the SDK when the key file exists and the credit record holds no fresh refusal, unless
  `BRIEFING_BACKEND=cli`. If the SDK run fails, the same turn reruns with `claude -p` as before, and `cron.log` says why ("the API
  credit is used up" when its output says "credit balance", otherwise the exit and the last error line). The SDK log stays beside
  the other as `<job>.<date>.sdk.jsonl`, and a write it made still holds the digest back. The units run on the bedrock lane, whose
  routing (`CLAUDE_CODE_USE_BEDROCK`, `AWS_*`, the pinned model ids; `BRIEFING_SDK_UNSET`) is removed from the SDK run's
  environment, or its CLI would go to Bedrock and ignore the key; the rerun keeps it.
- `release-watch.sh`'s relay needs tools (SendMessage, ListAgents), so it uses `sdk_run.py` too (`--output text`), after
  `lib/api_credit.py check`. Any answer but `DONE` reruns the turn with `claude -p`.
- the rule that the run never sees the key is suspended for the SDK run only. The `claude -p` path still never gets it.

## Installing the timers

The units run the production checkout: `ExecStart=%h/salamander/contrib/briefing/<script>`. They name no log path: they set
`BRIEFING_CRON_LOG=1`, and `lib.sh` appends the script's own output to `cron.log` in the log directory (`BRIEFING_LOGDIR`,
default `~/.local/state/sala-briefing`), which it creates. The digests run only once `BRIEFING_GMAIL_CONNECTOR` is set
(config.example, the briefings).

A deploy (`deploy.sh`) does not install, copy or restart these units. Your provisioning does that: it copies the three unit pairs
(summary-lean, defunct, release) from `~/salamander/contrib/briefing/systemd/` into `~/.config/systemd/user/`,
reloads systemd once, enables the timers and creates the log directory. A sensible rule for each file:

- The defunct and release units are overwritten when they differ from the repo, so a change under `systemd/` here
  reaches the machine with the next provision.
- The lean pair (`sala-briefing-summary-lean.service` and `.timer`) is installed only when missing and a differing installed
  copy is reported and never overwritten, because switching the lean briefing to posting is a `sed` on the
  installed files (see "The lean summary" below).
- A missing `~/salamander` checkout (no `contrib/briefing/systemd/`) is skipped.

To install by hand instead, copy them; copying is the convention
sala's own units follow (`install.sh`):

```
mkdir -p ~/.config/systemd/user
cp ~/salamander/contrib/briefing/systemd/sala-briefing-*.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now sala-briefing-summary-lean.timer sala-briefing-defunct.timer sala-briefing-release.timer
systemctl --user list-timers 'sala-briefing-*'
```

If you copy them by hand, re-copy after a change under `systemd/` here. Symlinking them in instead (`ln -s` into
`~/.config/systemd/user/`) picks up a change at the next `daemon-reload`. A change to a script needs neither, because
the units run the checkout.

To run one now: `systemctl --user start sala-briefing-summary-lean.service`. Then check `~/.local/state/sala-briefing/cron.log` and
`journalctl --user -u sala-briefing-summary-lean`.

To have sala's notices use this webhook, set this in `~/.config/salamander/config`:

```
SALA_WATCH_NOTIFY_CMD='bash -c ". ~/salamander/contrib/briefing/lib.sh; post_slack \"$(cat)\" >/dev/null"'
```

## Dry run of the release watcher

```
RELEASE_WATCH_DRY=1 ~/salamander/contrib/briefing/release-watch.sh
```

This prints what would be announced. It pings no session and writes no `notified/` state. It still reads the upstream
releases and the installed versions, and posts nothing (only `release-alert.sh` posts).

## New holds in the morning summary

Stackshot reports the board items put on hold in the last 24 hours, with who set the hold, the wake date and what holds
it (`nothing holds it now` is the one to look at). The model is not asked for it: `guard.py` allows five Gmail reads and
stays that way. `summary.sh` calls `fetch_new_holds` (`lib.sh`) before the run, which runs `holds.py` under a 20 s cap
(its own cap is 15 s):

- `holds.py` reads `GET /client/brief` with the machine token, the way stackshot's `client.py` does: token in
  `~/.config/stackshot/client.token`, server from `$STACKSHOT_URL`, else `~/.config/stackshot/client.url`; neither set:
  the block is off (exit 0, nothing fetched), there is no built-in server. The token goes only into the Authorization header: never printed, logged or in argv.
  `BRIEFING_STACKSHOT_DIR` moves that directory (tests).
- It keeps only the new-hold lines. The brief has them as `new hold (24 h): board#N subject [owner] · set by … · wake … · held
  by …` (at most 8, then `… and N more new holds`); board.md's head has them as a `## New holds (last 24 hours)` section
  of `- ` bullets, and that shape parses too. The text is cleaned (control characters and angle brackets out, 400 characters
  a line, 12 lines) and framed between `<new-holds-data>` and `</new-holds-data>`; the prompt calls it data, not instructions.
- With holds, the block follows the prompt and the model adds a last `*⏸️ New holds (last 24 hours)*` section. With none,
  nothing is added and the digest says nothing about holds.
- A failed or timed-out fetch never fails the briefing: it runs as before with no block, and one line
  (`new holds not fetched (exit N: reason); the briefing ran without them`) is appended to that run's
  `~/.local/state/sala-briefing/summary.<YYYYMMDD>.jsonl.err`, after the run, since the run overwrites that file.
- `BRIEFING_HOLDS_CMD` swaps in another command for `holds.py`; `holds.py --parse` reads a brief on stdin without the network.

## A digest run that posts nothing

`BRIEFING_NO_POST=1 ~/salamander/contrib/briefing/summary.sh` runs the whole turn (the model reads Gmail, the guards
run) and writes what `post_slack` would have sent to `~/.local/state/sala-briefing/would-post.log` instead; the webhook is never
read. The stream log, `guard.log` and `cron.log` are written as in a real run. Use it to check the read guard live.

## The lean summary

`summary.sh` runs a full agent turn: the model finds and reads Gmail itself, through a connector or the portal's code
mode, with the read guard watching, and takes minutes and many turns for one text. `summary-lean.sh` splits the job. Code
reads and trims the unread mail (`gmail_fetch.py`); then ONE model call, with nothing to touch, writes the digest:

```
claude -p --tools "" --strict-mcp-config --setting-sources "" --disable-slash-commands \
       --system-prompt "<summary-lean.prompt.md>" --no-session-persistence --output-format json --model "$MODEL" < mail
```

The mail (and the new-holds block, fetched by `fetch_new_holds` exactly as `summary.sh` does) is on stdin. `--bare` is not
used: it fails "Not logged in" on a subscription login. The model is lib.sh's `MODEL` (`SALA_BRIEFING_MODEL`, default sonnet). Nothing in the
script is tied to one lane: it passes the caller's environment through, so a Bedrock lane (`CLAUDE_CODE_USE_BEDROCK`, `AWS_*`) on
the launch line or in a drop-in works unchanged; `BRIEFING_CLAUDE_CONFIG_DIR` picks another login as in the other
briefings. A model that can use no tool and read no setting needs no read guard; the guard is applied to the code's own
reads instead (below).

`summary-lean.prompt.md` is `summary.prompt.md` with the connector and portal paragraphs removed and a description of the
data block added. The count line is code's: the model writes `_As of @@ASOF@@ · @@UNREAD@@ unread · M actionable_`; code
fills the time and the unread count (`N`, or `N+` when the portal says there is a next page, which it cannot fetch), and
overwrites any other number the model wrote on that line. Only `M actionable` is the model's.

The prompts also take three slots filled from the briefing settings (see "Briefing settings" above; all empty by default, and an empty list is written as `none configured`):
`{{WATCHLIST}}` (`BRIEFING_WATCHLIST`: what an alert must match to be worth a line) and `{{LOW_PRIORITY_SENDERS}}` (`BRIEFING_LOW_PRIORITY_SENDERS`: senders whose mail is always clutter) in the two summary prompts, and `{{FORWARD_LABEL}}` (`BRIEFING_FORWARD_LABEL`: the Gmail
label the forwarded-address queue reads; with none set the defunct job does not run) in the defunct prompt. The three prompts name the owner through `{{OWNER}}` (the name `SALA_OWNER_NAME` holds, read as the other briefing settings are:
the environment, else the sala config line; "the owner" when unset) and the greeting through `{{GREETING}}` (`, <name>`, or
nothing when no name is set, so the digest opens "Good morning!"). `summary-lean.sh` checks the answer for that greeting before
it delivers.

### How code reads Gmail

Chosen route: **the MCP Portal's own endpoint, from Python, with the portal login Claude Code already holds.**

- `gmail_fetch.py` is an MCP streamable-HTTP client for the portal's `/mcp` address (`BRIEFING_LEAN_PORTAL_URL`, env or sala config, else the
  serverUrl of Claude Code's login entry, e.g. `https://mcp-portal.example.com/mcp`; neither: exit 4, nothing sent): `initialize`,
  `notifications/initialized`, then `tools/call` of the portal's one tool `portal_codemode_execute`, whose `code` is a fixed
  template, `async () => await codemode.g<word>_<read>(<json arguments>)`. The responses are server-sent events whose text is
  `{"result": "<the Workspace server's text>"}`.
- The token is the portal's OAuth access token in Claude Code's own store, `~/.claude/.credentials.json`, key `mcpOAuth`,
  entry `mcp-portal|…` (or `$BRIEFING_CLAUDE_CONFIG_DIR/.credentials.json`). The file is only read. The token goes into the
  `Authorization` header and nowhere else: not argv, not a log, not an error line (every message is scrubbed of it). The
  entry also holds a refresh token, which this code never touches: the portal rotates it on every use (a second client
  using it would break Claude Code's login), so only Claude Code renews the login.
- Only the five Gmail reads of `g<word>_` can go out. Every `code` string is passed through `guard.py`'s `decide()` before it
  is sent, so the allow-list that fences the model's runs fences this code too, and a tool outside `READS` is refused
  before any request. No send, draft, label, modify, trash, Drive or Calendar tool, no other account.
- Proof: a search with `page_size` 2 and the batch read of those two messages answered
  through this route; only counts were looked at. Shapes the parser relies on: search gives `Message ID:` / `Web Link:` /
  `Thread ID:` per message and, when there is more, `To get the next page … page_token='[masked secret]'` (the portal masks
  the token, so there is no second page: the fetch asks for 100 and reports `N+` when it may have missed some);
  `get_gmail_messages_content_batch` (at most 25 ids) gives `Message ID:` / headers / `--- BODY ---` / body per message and
  no thread id, which is why the thread id comes from the search.
- Two traps found on the way. (1) A portal's edge may refuse Python's default user agent; the fetch sends its own,
  `sala-briefing-lean/1` (`BRIEFING_LEAN_CLIENT_NAME`, with `/1`). (2) **The access token lives 15 minutes** and
  nothing renews it while no Claude session uses the portal. So `gmail_fetch.py` checks `expiresAt`; with less than 90 s left it runs
  `BRIEFING_LEAN_WARM_CMD` (default `claude mcp get mcp-portal`, a health check of that server, no model call) so that
  Claude Code itself renews the login, and reads the file again; if it is still stale, the run ends with exit 3 and the 🚨
  "didn't run" notice. Whether the warm command renews the login is worth checking once on your setup. Check: `claude mcp get mcp-portal` once while
  the stored token is stale, then read `expiresAt` of the portal entry (a number, not the token). If it does not move, the
  alternatives are a keep-warm timer that runs the same command every 10 minutes, or a different warm command
  (`claude mcp list`); the rest of the design does not change.

Rejected: reading a Workspace MCP server's own token store, or calling that server directly. Neither is a route without a
new credential, and both bypass the portal, the five-read wall and the account allow-list.

### What gets sent, and what the code trims

Per unread thread, the unread messages' new text only, in order: human mail first (newest first), then automated mail,
then alerts. Each item: `thread=` (the Gmail thread id, copied into the digest's `[gmail:THREAD_ID]` marker),
`kind=human|automated|alert`, `From:`, `Date:` (in the zone `BRIEFING_TZ` names, UTC by default, in the form `Mon Jan 5th 14:03`: weekday, month, day with st/nd/rd/th, 24-hour time; formatted by `fmt_local` in `gmail_fetch.py`, and the model copies it as given), `Subject:`, and a
cleaned `Body:`: HTML turned to text, `>` quotes and everything from `On … wrote:`, `-----Original Message-----`,
Outlook-style `From:` blocks and `-- ` signatures cut (the reply-header patterns are English only: the Hangul and French "wrote" and "from" headers an earlier version also cut were dropped, so a quoted reply in another language is kept), newsletter text after `unsubscribe` cut, links replaced by `[link]`,
a few hundred characters (900 human, 400 automated). An alert mail (a Google Alerts text mail) is read out instead: per article the real title, a
snippet and the destination URL taken out of the `google.com/url` redirect, repeats across alert mails passed once. The
whole block is capped at `BRIEFING_LEAN_MAX_CHARS` (30000): over that, every budget shrinks in steps, then the lowest-priority
items are dropped and counted as `omitted` in the header. Mail text cannot close or reopen the data block, and the system
prompt calls it data, not instructions; the model has no tool to be steered into anyway.

### The portal's 24000-character limit, and empty threads

The first lean run read Gmail many times and still told the model that every thread had
no sender, date, subject or body. Cause: the portal's Code Mode cuts any answer at about 24000 characters (invalid JSON, then
`--- TRUNCATED ---`), and 25 full messages are about 60000. Every batch of 25 came back cut, the parser found no
`Message ID:` line in it, and the reads still counted. Fix: the message contents are read 8 at a time through a fixed
JavaScript template (`BATCH_JS`, checked by `guard.py` like every read) that cuts each message to five headers and 3000 body
characters inside the portal; a batch still cut is split in halves; a cut answer is decoded up to the cut. And a read is no
longer proof that mail came back: `gmail_fetch.py` exits 4 with "Gmail came back with empty threads" when any of the first five
threads, or over a fifth of all, has neither subject nor sender, and its meta file counts them (`empty`). `summary-lean.sh`
checks that count too (more than a fifth, or no count at all, is the 🚨 "held back" notice).

### Delivery guard parity

A digest exists only if code actually read Gmail. `gmail_fetch.py` counts the successful reads in its meta file; the script
makes the model call only when that count is above zero. A refused login (exit 3) is the 🚨 "didn't run" notice; any other
failure to read (exit 4), a model run with no text, an answer of `NO_REPLY`, or an answer that is not a digest (no greeting) is
a 🚨 "failed" notice; a fetch that read nothing is the 🚨 "held back" notice. In `--post` mode they are posted, titled like
`summary.sh`'s. In the default mode they are written to the output file (titled "(lean)") and the script exits 1, so the
unit shows failed. A model call that fails is retried once. An empty mailbox still gets a digest (the prompt's "ALWAYS
deliver" rule), with the zero count.

### Side by side, then the switch

The installed unit runs `summary-lean.sh --post` and posts the digest to the briefing channel. The script's own
default (no flag) is the side-by-side mode: the digest goes to `~/.local/state/sala-briefing/lean/YYYYMMDD.txt`, a usage line (input and output tokens, with
the cache split, seconds, the mail size) to `lean/YYYYMMDD.usage`, and **nothing is posted** (the mode for a trial run, with the old digest still the one posted). `--post` (or `BRIEFING_LEAN_POST=1`) delivers like `summary.sh`: through `post_slack`, honouring
`BRIEFING_NO_POST`. The raw model answer is `summary-lean.<YYYYMMDD>.json` and the run's stderr `summary-lean.<YYYYMMDD>.err`
in `~/.local/state/sala-briefing/`.

```
# install the pair (your provisioning does this, or by hand)
cp ~/salamander/contrib/briefing/systemd/sala-briefing-summary-lean.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now sala-briefing-summary-lean.timer     # fires at the time set in the unit
# a run now (the unit posts to the briefing channel; for a run that posts nothing, run summary-lean.sh with no flag):  systemctl --user start sala-briefing-summary-lean.service
# compare a day (default today): ~/salamander/contrib/briefing/lean-compare.sh 20260105
```

`lean-compare.sh [YYYYMMDD]` prints the old text (the result in the day's `summary.<date>.jsonl`, with its turns, seconds
and tokens) and the new text with its usage line. The switch is done: the old summary service and timer are
retired and their files deleted from the repo, and the lean pair is the one morning digest. A machine that still has the
side-by-side copy of the lean pair (`--post` missing) can copy the pair again from the repo, or edit by hand:

```
#   sed -i 's#summary-lean.sh$#summary-lean.sh --post#' ~/.config/systemd/user/sala-briefing-summary-lean.service
systemctl --user daemon-reload && systemctl --user restart sala-briefing-summary-lean.timer
```

To stop posting, take `--post` out of the lean unit. The lean unit runs on the bedrock lane like the other two
(`salamander lane exec bedrock --`), so it needs no AWS variables of its own.
The `cp` in "Installing the timers" above copies the lean files too (`sala-briefing-*`); copying does not enable them.

## Tests

`bash tests/briefing.sh` runs offline in a temporary `HOME`. It checks the following:

- every script parses and is executable;
- the units are well-formed (`systemd-analyze verify` where systemd is present) and fire at the times set in the unit files;
- `lib.sh` sources from any directory and through symlinks without exiting;
- the delivery guard, a portal Gmail read counted and a portal call without one not;
- the read guard (`tests/briefing/readguard.sh`): the shapes of the portal's calls pass
  (string literals masked); a send, a draft, a label change, a Drive call, a Calendar call, `codemode[x](…)`, an alias,
  a mixed read+write, a comment-hidden write, a string-concatenated name, destructuring, a default parameter, `eval`,
  `Function`, `.constructor`, `import`, `globalThis`, a unicode-escaped identifier, a non-ASCII lookalike, optional
  chaining, a parameter on the arrow, a free identifier from the enclosing scope and the other evasions are each refused
  with a reason; `portal_codemode_search` allowed; Read/Write/Bash and the direct connector's reads untouched; a
  write-named tool refused by name; malformed input refuses; `--settings` with the hook on the `claude -p` call and on
  the SDK runner, none on a non-briefing `claude -p`; a refused call in the stream log counts no read, is no write, and
  is named in `cron.log` and under the digest; the load check (the fakes run the hook from `--settings` as the CLI
  does): portal calls with no new `guard.log` line held back, with one posted, a direct-connector run unchecked, the
  count kept from before the first attempt across the SDK fallback and the retry; `BRIEFING_NO_POST`;
- what the digests' `claude` is given: `CLAUDE_CONFIG_DIR` from `BRIEFING_CLAUDE_CONFIG_DIR` when set, never the key
  variables, the portal tools allowed;
- what `post_slack` sends: `slack_text`'s formatting and `slack_links`'s links, with a failing linker falling back to
  the unlinked text; the session links: a name from the registry (`sala sessions --json`; `sala spawn --list` is slower, so it is only the fallback, 20 s cap) links to sala's session link
  whether or not it has a claude.ai bridge, an unknown name stays plain, a name with regex characters is safe, and the
  url is `session_url`'s (the template from `SALA_SESSION_URL` when set, else the `SALA_SESSION_URL` line of the sala config,
  else none: a bridged session links to its claude.ai address and one without a bridge stays plain).
- the Agent SDK choice (`tests/briefing/sdk.sh`, with the clock injected through `BRIEFING_NOW`, a fake
  runner through `BRIEFING_SDK_CMD` and the credit record in a temporary `XDG_STATE_HOME`): the SDK with no refusal on record or one
  6 hours old, `claude -p` with a fresh one, with `BRIEFING_BACKEND=cli` or without a key file; the fallback on "credit balance" and
  on any other failure; what the runner is handed (no bedrock routing); the relay's SDK-first path; and the record itself
  (`tests/briefing/apicredit.sh`: both readers agree on every case, the atomic write, `sdk_run.py` against a stub SDK writing it
  on a refusal and clearing it on success);
- the new-holds block (`tests/briefing/holds.sh`, a local listener for stackshot): both shapes of the
  section parse and nothing else; a hostile line is cleaned and capped; the token is sent as a bearer header and printed
  nowhere; a refused, unreachable, hanging or tokenless fetch is one stderr line; `summary.sh` with a fake `claude` puts
  the block in the prompt, none when there are no holds, and a failed fetch adds one `.err` line and still posts;
- the lean summary (`tests/briefing/lean.sh`, against `lean_fake_portal.py`, a local listener that
  speaks the portal's MCP and answers with made-up mail in the portal's shapes; a fake `claude`; a counting webhook listener):
  the fetch sends the bearer token and its own user agent, calls only the five Gmail reads (each through `guard.py`), prints
  and logs no token, never touches the refresh token; trimming (quotes, signatures, footers, HTML, links, dates in the `BRIEFING_TZ` zone, one item
  per thread with the thread id, alerts as titles and URLs, repeats once, the cap, a hostile mail that cannot close
  the data block); an expired token runs the warm command once and ends as exit 3 when nothing renewed it; a refused login,
  an OAuth answer, a garbage answer, a JSON-RPC error and an unreachable portal are distinct exits; `summary-lean.sh`: the
  model call's exact flags and system prompt, the mail on stdin, `SALA_BRIEFING_MODEL`, a Bedrock lane's variables passing
  through, the count line from code, nothing posted by default, one post with `--post` / `BRIEFING_LEAN_POST=1`, a fetch
  error / auth error / run without a Gmail read as a loud notice with no digest and no model call, a failing or silent model
  as a failed notice, `lean-compare.sh`, the units (`--post`);
- `reply.sh`: `thread_ts` in the payload when given, the payload unchanged without it, a bad ts or an empty text refused
  before anything is posted, the text from stdin.

The guard test uses a fake `claude` and a posting stub, plus a local listener for `post_slack`. It
never reads the configured webhook.
