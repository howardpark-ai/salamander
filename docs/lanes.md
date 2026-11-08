# Lanes

The accounts and keys a session can run on, how to switch them, and what happens when one is dormant or runs out.

A **lane** is the account or key a pane's claude runs on (Tue Oct 13th 2026; `lib/common.sh` "lanes",
`lib/lane.sh`). Five of them are one env prefix on the launch line and nothing else; `sdk` (an
alias of `api` with client `claude-agent-sdk`) is a pane program in place of `claude`. Older lane words (`max`, `team`) are still read as `subscription-1` and `subscription-2` everywhere a lane is read (see *Display names and old words*):

| lane | on the launch line | needs |
|---|---|---|
| `subscription-1` | nothing — the claude.ai login in `~/.claude` (the line as it always was; the lane of every session nothing was recorded for) | — |
| `api` | `ANTHROPIC_API_KEY="$(cat <SALA_LANE_API_KEY_FILE>)"` and, when `SALA_LANE_API_WORKSPACE_FILE` exists, `ANTHROPIC_CUSTOM_HEADERS="anthropic-workspace-id: $(cat <file>)"` and `ENABLE_PROMPT_CACHING_1H=1` (the 1-hour prompt cache a long-lived pane gets on subscription-1; Claude Code writes the 5-minute one on an API key without it, so a wake after five idle minutes rewrites the whole context; a pane's line only, a one-shot job gets none); `--mcp-config <SALA_LANE_API_MCP_CONFIG>` when that file exists (stand-ins for the claude.ai connectors, which a key has no login for) | the key file, readable and non-empty, on a path that needs no shell quoting |
| `subscription-2` | `CLAUDE_CONFIG_DIR=<SALA_LANE_TEAM_DIR>` — a second claude.ai login in a directory of its own | the directory, signed in once by hand (`CLAUDE_CONFIG_DIR=<dir> claude`) |
| `bedrock` | `AWS_PROFILE=<SALA_LANE_BEDROCK_PROFILE, no default: empty = the lane is not set up>` `CLAUDE_CODE_USE_BEDROCK=1` `AWS_REGION=<SALA_LANE_BEDROCK_REGION, no default: empty = the lane is not set up>` `ANTHROPIC_BEDROCK_REGION_PREFIX=<global>` and the three pinned models `ANTHROPIC_DEFAULT_OPUS_MODEL` / `_SONNET_MODEL` / `_HAIKU_MODEL` (Bedrock global inference-profile ids, `SALA_LANE_BEDROCK_OPUS_MODEL` / `_SONNET_MODEL` / `_HAIKU_MODEL`) and `ENABLE_PROMPT_CACHING_1H_BEDROCK=1` (the 1-hour prompt cache a long-lived pane gets on subscription-1; Claude Code writes the 5-minute one on Bedrock without it, so a wake after five idle minutes rewrote the whole context; a pane's line only, `sala lane env` and `lane exec` leave it off, as a one-shot `claude -p` never reuses a cache entry and the 1-hour write costs more); `--mcp-config <SALA_LANE_API_MCP_CONFIG>` when that file exists, as `api`. Names and ids only: no secret is on the line (the profile's keys are read by the CLI from `~/.aws/credentials`, which sala only tests for the `[<profile>]` header line and never reads or prints). Set on that pane's launch line, never exported, never in settings. No Remote Control, as `api` | a `[<profile>]` header line in `~/.aws/credentials` (add it with your key-entry script), a profile that is not an administrator one (any name containing `admin` is refused), the `--mcp-config` file readable if it exists, the claude launcher |
| `aws-platform` | `env -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_FOUNDRY -u ANTHROPIC_AWS_API_KEY` first (Bedrock and Foundry win the CLI's routing over this provider, and a workspace API key wins over SigV4, so the line makes sure none is there), then `AWS_PROFILE=<SALA_LANE_AWSPLATFORM_PROFILE, no default: empty = the lane is not set up>` `CLAUDE_CODE_USE_ANTHROPIC_AWS=1` `ANTHROPIC_AWS_WORKSPACE_ID=<SALA_LANE_AWSPLATFORM_WORKSPACE_ID>` `AWS_REGION=<SALA_LANE_AWSPLATFORM_REGION, no default: empty = the lane is not set up>` and the three pinned models `ANTHROPIC_DEFAULT_OPUS_MODEL` / `_SONNET_MODEL` / `_HAIKU_MODEL` (the plain Claude API ids, `SALA_LANE_AWSPLATFORM_OPUS_MODEL` / `_SONNET_MODEL` / `_HAIKU_MODEL`) and `ENABLE_PROMPT_CACHING_1H=1` (the 1-hour prompt cache a long-lived pane gets on subscription-1; Claude Code writes the 5-minute one on this provider without it. It is the plain switch, not bedrock's `ENABLE_PROMPT_CACHING_1H_BEDROCK`, which the CLI reads only for the bedrock provider; a pane's line only, `sala lane env` and `lane exec` leave it off); `--mcp-config <SALA_LANE_API_MCP_CONFIG>` when that file exists, as `api`. Claude Platform on AWS is the Anthropic-operated API with AWS authentication and AWS billing, a service of its own beside Bedrock: another endpoint, the API's model ids, `CLAUDE_CODE_USE_ANTHROPIC_AWS` in place of `CLAUDE_CODE_USE_BEDROCK`. Names and ids only: no secret is on the line (the workspace id is not one). Set on that pane's launch line, never exported, never in settings. No Remote Control, as `api` | a workspace id of the form `wrkspc_` plus letters, digits or underscores in `SALA_LANE_AWSPLATFORM_WORKSPACE_ID` (empty until the workspace exists: the lane is refused with that said), a `[<profile>]` header line in `~/.aws/credentials`, a profile that is not an administrator one, the `--mcp-config` file readable if it exists, the claude launcher |
| `sdk` | `salamander sdk-pane <uuid> <session> [--model M] [--effort E]` — the api lane's key through the Agent SDK (`claude-agent-sdk`, `SALA_LANE_SDK_PIN`), which the API credit pays for while Claude Code on the same key is refused; the driver hands the key to the CLI the SDK spawns, nothing is on the typed line | the api lane's files, the `--mcp-config` file (required), `uv` on PATH, no refusal less than `API_CREDIT_RETRY_S` (6 h) old on the shared credit record (*The sdk lane*) |

The `$(cat <file>)` is run by the **pane's own shell** when it runs the line: the key is in that claude's environment and
nowhere else — not in what sala types, tmux's buffer, sala's logs, or any argv. The CLI picks its auth when the process
starts (a key before the stored login; a config directory keeps its own login) and the login in `~/.claude` is untouched
by a per-process key, so a switch is a relaunch with another env and never a re-auth.

**State, not config** (`~/.local/state/salamander/`): `lanes.tsv`, one `<tmux session>\t<lane>` row per session with a lane
of its own (`rename` moves the row, `retire` drops it), and `lane-default`, the lane of every session without a row
(`subscription-1` when the file is absent). Every launch path reads them: `spawn` (the default lane), the sweep's resume (recycle,
`revive`, the boot hook, `restore`, the retry workers, `watch`'s deferred relaunch), the self-worker and `unpark` — all
through `resume_cmd` — so a recycle brings an api-lane pane back on the api lane. The knobs (`SALA_LANE_*`) are in
`config.example`.

`sala lane` is the only thing that writes the state, and it relaunches through the machinery every relaunch uses, with
its guards (a busy pane deferred and retried, a running subagent never cut (it holds the move until it ends and is named in the skip line and in `watch`'s one log line; docs/recycle.md, "One idea of busy"), `SALA_NO_RELAUNCH` left alone, the invoking pane last, one driver at a time,
the master's pane when a Claude session asks): `sala lane <lane> <session>…` records, then `revive --force --only …` and
`revive --self` for the invoking pane; `sala lane <lane> --all` records every session and the default, then `recycle
--force` (a relaunch of every pane is a recycle, and the board hears of it as one); `sala lane default <lane>` only sets
the default. A lane whose prerequisites are missing is refused before anything is recorded. `--dry-run` prints what would
be recorded and relaunched and the *names* of the variables, never a value. On the api lane there is no Remote Control:
`watch` skips the bridge check and heal for a master running on it (one log line), and the reboot's boot half counts
such a pane as back once it is on its conversation.

**The lane line** (Wed Oct 14th 2026: a `revive --force --only` put a pane on the api default — it had no row, and only
its environment knew it ran on subscription-2). Every relaunch plan — the sweep's per-pane rows (recycle, `revive`, the boot hook,
the retry workers), `revive --self` and the recycle driver's self-worker — says `lane: <the lane the claude runs on now,
from its environment> → <the lane the resume line puts it on: its row, else the default>`, in the dry run and the real
run alike. When the two differ and **no row** records the intent, that pane is refused, not the sweep: a `not relaunched`
row naming both lanes and the fix (`salamander lane <running lane> <session>`, which records and relaunches it; or
`--lane-default` on `revive` / `recycle`, which accepts the default for every such pane in that run), given up at once in
the recycle's set (so it is in the post, never silently skipped) and not retried. A row wins as before: `lane: subscription-2 →
api` with a row of api is relaunched on api. A shell pane (after a reboot) runs on no lane (`lane: none → …`) and is
never refused; a claude whose environment cannot be read (`?`) neither; one in a config directory sala does not know
(`other`) is refused with `SALA_NO_RELAUNCH` as the fix. Until every by-hand pane has its row, a plain `recycle` leaves
those panes behind and says so: the `sala lane` table shows which ones (`RUNNING` differs from `RECORDED`/the default).

**The sign-in watch** (Wed Oct 14th 2026; a step of `watch`, `SALA_SIGNIN_ALERT`, default on; `watch --signin`
runs it alone). A lane's login lives in its config directory, and that directory holds one login: `/login` typed in one pane
(or `claude auth login` in a shell without `CLAUDE_CONFIG_DIR`) re-signs the whole lane, and a lane can sit on another
account unnoticed. Every `SALA_SIGNIN_EVERY` (5 min) the watch asks each login lane what it is signed in to (`claude auth
status --json` in the lane's directory — `subscription-1` in `~/.claude`, `subscription-2` in its own — with no API key in its
environment) and compares the answer with the table in `lib/common.sh` (`lane_expect`; config, never learned from a run:
`SALA_LANE_MAX_SUBSCRIPTION` and `SALA_LANE_TEAM_SUBSCRIPTION` (the expected plan name as the provider spells it; the variables keep the older lane names; empty means unconfirmed) with `SALA_LANE_TEAM_ORG=<your organization>`; the org is empty, meaning any, by default). The api lane's key must be on disk (looked at every tick) and, every
`SALA_SIGNIN_API_EVERY` (an hour), be accepted by the Messages API: one request of `max_tokens` 1 to the newest haiku the
API lists (one tiny `GET /v1/models` before it with the same key; a pinned `claude-haiku-5-5` only as the fallback when that
listing fails, and a 401/403 from the listing is the key refused; `SALA_SIGNIN_API_MODEL` set names the model instead), the
key and the workspace id read from the lane's files by the request itself, never on a command line; a 400 (the credit used up) is a key the API accepted, 401/403 a refused one, 429, 5xx and no network decide
nothing. A lane found on another account, not signed in, or with a refused or missing key gets one post — the lane, what was
expected and what was seen since when, and the fix: `CLAUDE_CONFIG_DIR=<its directory> claude auth login --claudeai` in the
web UI's Shell (open the link it prints, then paste the code back), never `/login` in a pane; to put one pane on another account, `sala lane <lane> <session>` — posted again only when
what is seen changes to another wrong state or after the lane was right in between, and "signed in correctly again" once
when it is. An unreadable look (no JSON, a CLI that hangs) neither alerts nor clears. `subscription-2` is watched whenever its
directory exists, `api` while its key file exists or a session's row or the default
is `api`/`sdk`. No email or id in a post.
State: `lane-signin.state` beside `lanes.tsv`.

**The settings-apply service** (Wed Oct 14th 2026; `lib/settings-apply.sh`; a step of
`watch`, `SALA_SETTINGS_APPLY`, default off (set `on` in the config to enable the tick); `watch --settings` runs it alone; `sala settings-apply` shows the state). A
Claude Code settings change used to wait for the owner's own shell or the next fleet provision, because the auto-mode
classifier refuses a session that edits the settings it runs under. Every tick fingerprints the spec (`SALA_SETTINGS_INPUTS`
under `SALA_SETTINGS_SPEC_DIR`: the spec files and the provision step scripts, read from this box's checkout of the spec's repo (`SALA_SETTINGS_SPEC_DIR`, `SALA_SETTINGS_INPUTS` and `SALA_SETTINGS_STEPS` are empty by default: no spec, nothing to apply),
which its own sync keeps current) and, when it changed, launches one `settings-apply --run <boxes>` as the transient unit
`sala-auto-settings` for this box and every `SALA_FLEET_HOSTS` box behind it that the heartbeat store says answers ssh (a
box that failed is tried again every `SALA_SETTINGS_RETRY`, an asleep one once the store says it answers). The run is
`provision --quiet --check --only <SALA_SETTINGS_STEPS>` — the settings-class steps the config lists (none by default; `config.example` shows the shape): steps that merge settings or tighten them (a settings merge, deny entries, hooks), never a step that loosens a permission: the allow rules and the like stay the owner's — then the apply on the boxes
whose check found a settings step drifting (`repo` alone is not drift), with `~/.claude/settings.json` backed up beside
itself first (`settings.json.bak-sala-settings-<stamp>`; the steps keep their own `.bak-provision-*` where they make one)
and the key-by-key diff logged after (`~/.claude/salamander-settings-apply.log`: one line per box and run with the spec
fingerprint and the config-repo commit, the steps' own words, then `path: old → new` per key, a list item as `+`/`-`,
secret-named keys masked); a settings.json that no longer parses is put back from the backup and the box is a failure.
No CLI update, no recycle, no relaunch: panes take the settings at their next relaunch, as before. A box's first look is
dry ("would apply …", recorded; applied from the next spec change on), so switching the service on, or adding a host,
changes nothing by itself. A failed box is posted once per fingerprint in the step's own words; a box still behind
`SALA_SETTINGS_STALE` after the change is posted once; a quiet apply is log-only. `provision --quiet` (with `--only` or
`--check`) is the run's provision with no fleet post, and `SALA_PROVISION_RESULT_DIR` keeps provision's per-box STEP
lines for it. State: `settings-apply.state` in sala's state directory; a second `--run` while one runs exits 75.

**The rescue** (Wed Oct 14th 2026; `lib/lane.sh` "THE RESCUE", `lib/revive.sh` "THE RESCUE"). The master runs on
a lane. When that lane's usage is out or its account is dead the master cannot act, and the session that
could move it is not the master: `sala lane <lane> <master>` from there needed `--not-master`, and the master's own
background-task rows held the relaunch. `salamander lane --rescue <lane>` is that move, sanctioned. It moves only the
master (`SALA_MASTER`), from a session that is not the master (from the master's own pane it points at the ordinary
switch, which the self-worker runs once that pane is idle). It refuses while the master's current lane *looks fine to
sala*, by three readings sala already has and nothing else (no model asked, no request made; `lane_out` in
`lib/common.sh`): `lane_check` (the lane cannot launch at all), the sign-in watch's last look (`lane-signin.state`: not
signed in, another account, the key refused), and the limit watch's state (`salamander-limit.json`: the master's own pane
stopped on the lane is decisive whatever the limit; another pane's stop counts only for a lane-wide limit — weekly,
5-hour, credit, workspace, rate — since one model's limit stops only that model's panes). An error sala has not seen yet
(the watch confirms a stop after `SALA_LIMIT_CONFIRM`) is what `--force` is for: it moves the master anyway and the log
says so. The target lane must launch (`lane_check`) and must not be out by the same readings (`--force` overrides that
too). Then the switch's own steps: the recycle lock, the row in `lanes.tsv`, one `rescue` line in `lanes.log` (when, who,
from → to, why), and the direct sweep of the master's pane — `revive --force --only <master> --not-master --rescue` — so a
stale background-task row does not hold it. `--dry-run` prints the plan and the sweep's verdict and writes, logs and
relaunches nothing. The `sala lane` table warns under its rows when the master sits on a lane that is out, naming the
lane, why, the rescue and the lanes sala sees nothing wrong with.

*A stale background-task row* (`--rescue` on `revive --only`, `revive --self` and `sala lane <lane> <session>…`). The
CLI's task registry keeps a row for a background shell stopped by hand or a subagent long gone, so its `/exit` opens the
"Background work is running" dialog over nothing; the Stop hook's record (`busy_state`) and the mod's exit check are
copies of the same registry. Without the flag every relaunch keeps its gates: the dialog is cancelled with Esc (unless
every row is a scheduled task), the record skips the pane, the mod refuses. With `--rescue`, when **no child process runs
under the pane's claude** (`work_children`, the one live reading sala has), the dialog is confirmed — Enter on its
selected "1. Exit and stop tasks", the key the scheduled-task case already presses, after the dialog's text is read off the
screen — and the record and the mod's refusal are read as stale by the same test; each pass-over is said in the sweep's
output and the mod log. A live child keeps every refusal; a scratch file written in the last 2 min too; a turn running,
a draft, a terminal prompt as before. Never for a recycle (`recycle --rescue` is refused): a whole fleet confirmed blind
is not a rescue. The limit of the test: a background subagent runs in the CLI's own process and shows no child, so a
rescue confirms its row too; that is the operator's call behind the flag, and the reason it is one.

## Lane fields
What a lane *is*, apart from how it launches (Thu Oct 22nd 2026; the lanes page,
"Lane fields"). `sala lane --list` prints one aligned row per lane, `sala lane --json` the same as JSON (and the no-argument
table opens with it). Fields only: nothing here launches a pane or changes a lane. The same fields serve any provider, so a
Codex or Gemini lane later is one more row.

| field | holds |
|---|---|
| `id` · `label` | what commands take (`subscription-1`, `subscription-2`, `api`, `bedrock`, `aws-platform`; `max` and `team` are read as the first two) · how it is shown, **the display name**, one setting per lane and the only place it is spelled (Subscription 1, Subscription 2, API, Bedrock, Claude Platform on AWS; *Display names and old words*) |
| `provider` | ids after the Vercel AI SDK: `anthropic` `openai` `google` `google-vertex` `amazon-bedrock` `azure` |
| `client` | `claude-code` `claude-agent-sdk` `codex` `gemini-cli` |
| `org` · `project` | the paying organization · its division (optional: an Anthropic workspace id, an OpenAI project, a Google Cloud project) |
| `billing` · `payment` · `plan` | `subscription` or `usage`; for usage `prepaid` or `postpaid`; a subscription's plan (a plan id such as `chatgpt_plus` or `google_ai_pro`; empty until the config names it) |
| `account` · `credential` · `region` | the sign-in email · login, key file, AWS or Google Cloud profile (optional) · region (optional) |
| `status` | `active` · `inactive` · `not set up` |

Defaults (the account and org fields read `unconfirmed` until the config names them with `SALA_LANE_<ID>_ACCOUNT` / `_ORG`): `subscription-1` (anthropic, claude-code, subscription, plan `unconfirmed`, active), `subscription-2` (anthropic, claude-code, subscription, no plan, inactive),
`api` (anthropic, usage, prepaid, org `unconfirmed`, inactive), `bedrock` (amazon-bedrock, usage, postpaid, org `AWS account`, region empty until `SALA_LANE_BEDROCK_REGION` is set, status derived: active while `lane_check bedrock` passes, else not set up), `aws-platform` (anthropic, usage, postpaid, the AWS-linked Anthropic organization, region empty until `SALA_LANE_AWSPLATFORM_REGION` is set, the workspace id as its project, status derived as bedrock's). The table is in
`lib/common.sh` ("THE LANE FIELDS"); every field is overridden by config as `SALA_LANE_<ID>_<FIELD>` (`config.example`), and a
value outside its list is flagged under `--list`. The fields describe; the lane word still decides how a pane launches.
`sdk` is the old sdk lane folded into `api`: the word stays accepted wherever it was (rows in `lanes.tsv`, `sala lane sdk
<session>`) as an alias, with client `claude-agent-sdk`, and `SALA_LANE_SDK_PIN` and
`SALA_LANE_SDK_CMD` are that client's settings (`SALA_LANE_SDK_UNTIL`, its date gate, is gone). `lanes.tsv` keeps its format (`<session>\t<lane>`); no row is rewritten by
any of this. A row that names a lane sala does not know (an unknown word) is shown with a warning under `sala lane` and launches on
the default.

## Display names and old words
The two login lanes' codes are `subscription-1` and `subscription-2`; the older words `max` and `team` are still read as aliases.
Two things follow, and each has one home.

- **The display name is one setting per lane, and nothing else spells it.** It is the lane's `label` field: `SALA_LANE_<ID>_LABEL`
  in the config (`SALA_LANE_SUBSCRIPTION1_LABEL`, default `Subscription 1`; `SALA_LANE_SUBSCRIPTION2_LABEL`, default `Subscription 2`; the others
  default to API, Bedrock and Claude Platform on AWS; `config.example`). Bash reads it with `lane_label <code|old word>`
  (`lib/common.sh`), Python with `lanewords.lane_label` (`lib/lanewords.py`, which asks sala), and everything sala shows goes
  through one of the two: its messages, `--help` and usage text, sala-web (pane titles, status lines, the details page), the
  briefing and the Slack posts. A login's own plan names are not lane names and stay as the provider spells them: a login's
  `subscriptionType`, and the plan ids of the plan field.
- **The old codes are words for the new lanes.** `max` is read as `subscription-1` and `team` as `subscription-2`, as
  `awsplatform` is read as `aws-platform`, wherever a lane word is read: a typed argument, `lanes.tsv`, `lane-default`,
  `lane-state.tsv`, `lane-home.tsv`, a job or unit definition (`X-Model-Lane=`), the registry, `SALA_JOB_LANE`,
  `SALA_LANE_FALLBACK`, a queued `sala op` marker, the sign-in and limit state. A read changes no file; a new write records the
  new code (write-on-touch: a file is never rewritten just to change a word). `sala lane --migrate` still moves
  only `awsplatform`. The config variables keep their names (`SALA_LANE_TEAM_DIR`, `SALA_LANE_MAX_SUBSCRIPTION`, ...); the
  field overrides also take `SALA_LANE_SUBSCRIPTION1_*` and `SALA_LANE_SUBSCRIPTION2_*`.

`sala lane names [--json] [--write]` prints the table for anything that has to show a lane: one line per lane, `code`, display
name and old words, tab-separated; `--json` prints `{"lanes":[{"code":"subscription-1","display":"Subscription 1","aliases":["max"]}, ...]}`
(every known lane, `aliases` empty when it has none). `--write` keeps the same JSON in `$SALA_STATE_DIR/lane-names.json`, and so does `sala watch`, but only on a tick that finds the file
missing, the config file newer than it or `lib/common.sh` newer than it (three bash tests, no process); it is written atomically and only when it changed, so stackshot reads the file instead of running
the command. The interface is in `docs/stackshot-contracts.md`.

## The dormant record
One record per lane, active or dormant, with a reason and since: plain shell, no
Claude turn. `lane-state.tsv` in the state directory beside `lanes.tsv`: `lane`, `state` (`active`|`dormant`), `reason`, `since`
(ISO, UTC), `posted` (when the episode's one post went out), `by` (`signal` or `hand`); keyed by the lane id from the lane table
(`sdk` is `api`'s word), so a new lane needs nothing here. No row, or no file, is active. Written under its own `flock`, a temp
file and `mv` (as `lanes.tsv` is), one `lanes.log` line per change (`dormant`, `active`). The watch keeps it, from detections it
already makes (no new network call, never a test call to find out whether a lane works):

| lane | goes dormant when | comes back |
|---|---|---|
| `subscription-2` | the sign-in watch's verdict is wrong (not signed in, no subscription, another subscription or organization: "no seat"), or sala-web's saved usage answer says `refused` (HTTP 403, newer than the lane's last change) | by itself, at the daily look (`SALA_LANE_REVIVE_EVERY`, 86400 s): the sign-in check the watch makes anyway is right again; a line in the watch log |
| `subscription-1` | the same verdict is wrong: the login no longer reports the subscription it expects (the configured plan) | the same |
| `api` (and `sdk`) | the limit watch has a pane stopped on "Credit balance is too low" (the record it already reads); since = that stop's first error | only `sala lane active api` |

A lane set by hand (`sala lane dormant <lane> [--reason …]`) is held until `sala lane active <lane>`. While a lane is dormant:
the web Overview card keeps its head (the lane pill and plan name) with one line under it (`No seat since <date>`, with a Dormant chip beside `Details ›`) and asks nothing; spawn's picker (the CLI's
list of lanes, the web form) leaves it out and `spawn --lane <lane>` is refused, as is a spawn whose default lane is dormant;
`sala lane <lane> <session>`, `lane <lane> --all`, `lane default <lane>` and the rescue refuse to move onto it in plain words;
`sala lane` shows it with its reason and since; `lane_out` counts it out. The sessions still on it are posted once per dormant
episode (`ld_post_tick` in the watch; "Subscription 2: no seat since …, N sessions are still on it; moving them is your call") and stay
where they are when the lane has no usable fallback (or `SALA_LANE_FALLBACK_AUTO` is off); otherwise the lane fallback moves them
(*The lane fallback* below) and its own notice replaces that post. The record itself relaunches, moves and stops nothing. **Not verified:** what the live `claude auth status --json` prints for
a subscription-2 directory whose seat was removed (every shape other than loggedIn + the expected subscriptionType + the configured org counts as wrong), and whether the
usage endpoint answers 403 rather than 401 to a seatless login (a 401 stays "sign-in expired").

## The lane fallback
Sat Oct 31st 2026. A lane that goes dormant is moved to a live fallback automatically: its sessions move to the fallback on their own
and stay there until the owner or a session moves them back. Code: `lib/common.sh` ("THE AUTOMATIC LANE FALLBACK"), `lib/lane.sh` (`lane fallback`, `lane dormant`, `lane exec`),
`lib/op.sh` (the verb), `lib/watch.sh` (`ld_fallback`); test `tests/lanefallback.sh`.

- **The map.** `SALA_LANE_FALLBACK="subscription-1=bedrock subscription-2=bedrock aws-platform=bedrock api=bedrock sdk=bedrock bedrock=subscription-1"`
  (config; `<lane>=none` or no pair: no fallback). One hop: a fallback that is itself dormant is not followed to its own.
  The fallback is used only if it is active and ready (not dormant, `lane_check` passes, nothing out); if not, nothing moves
  and one line says why: on the watch's one dormant post ("not moved automatically: …") and from `lane dormant` by hand.
  `SALA_LANE_FALLBACK_AUTO=off` turns the automatic parts off (the move on dormancy and the jobs below); `lane fallback`
  by hand keeps working.
- **The trigger.** A lane turning dormant, by the watch's own detection or by `sala lane dormant <lane>` by hand (not with
  `--no-fallback`), queues ONE operation: `sala op lane fallback <lane> --from sala-watch --words "<the standing words of the fallback>"`. The queue is the normal path for a guarded fleet verb (the runner is a `sala-op-<id>` unit with no Claude
  above it, so the guards pass), it runs the plan at queue time and refuses what has no usable fallback, and it gives one
  result notice. A lane that was already dormant before this shipped is not moved on its own: `sala lane fallback <lane>`.
- **The move.** Every session whose running lane is the dead one (recorded on it, or on "(default)" while the default is
  that lane) is recorded on the fallback and relaunched at its next idle moment through the ordinary switch
  (`lane <fallback> <sessions…>`: `revive --force --only`, never a pane mid-turn). The master (`SALA_MASTER`) moves last, by
  the rescue (`lane --rescue`), once the first sweep has let go of the recycle lock. If the default lane is the dead one,
  it switches too. A session of any other lane is left alone.
- **The model.** A session on a Fable model moved onto bedrock runs `opus` (Opus 5.5) there, because Fable fails on bedrock
  (`SALA_FALLBACK_NO_FABLE`, `SALA_FALLBACK_FABLE_MODEL`). The override goes in `models.tsv` like any `sala model`; moving back
  restores nothing.
- **Stay.** Nothing moves a session back when the lane is active again. `lane-home.tsv` (state directory: session, home lane,
  when, the model it had before or `-`; the key `(default)` is the default lane's) keeps where each came from, the first home
  standing; `sala lane` shows a HOME column for a session off its home (and the default line says so) with the way back:
  `sala lane <home> <session>` (a switch onto the home clears the row), `sala lane default <home>`. A retire drops the row;
  a rename carries it.
- **Jobs.** A sala job (a systemd user timer that runs `sala lane exec <lane> -- …`) whose lane is dormant runs on the
  fallback while the lane is dormant: decided at run time in `lane exec`, one stderr line when it does (or when there is no
  usable fallback and the job runs on the lane as it is). No unit file is rewritten.
  `lane exec <lane>` (`subscription-1` too) always starts the job with every other lane's variables unset, never blanked (docs/units.md).
- **One notice.** The operation posts ONE Slack notice for the batch: the dead lane, the fallback, each session moved and
  any model change (and a session that could not be moved, named). Nobody is told in an inbox: `from=sala-watch` is no session.
- **Dry run and by hand.** `sala lane fallback <lane> --dry-run` prints the plan (the sessions, a Fable session's model change,
  the master last, the default, the jobs) and writes, queues and relaunches nothing. `sala lane fallback <lane>` is the real form
  for a person (it needs the lane to be dormant; exit 4: no usable fallback, nothing recorded).

## The back agents' lane rule
Thu Nov 5th 2026. A standing rule for the background agents that keeps them off a login lane near its weekly limit, and brings them
home when the limit resets. **Off by default** (`SALA_BACK_LANE_RULE=off`: nothing is read or moved). Code: `lib/common.sh` ("THE BACK AGENTS'
LANE RULE", `back_lane_tick`), `lib/watch.sh` (`back_lane_run`, `watch --back-lanes`), `lib/spawn.sh`; test `tests/backlane.sh`.

- **Who.** The live background agents: registry rows with role `back` and no side session, with a tmux session, not the master and
  not `SALA_NO_RELAUNCH`. A front agent, a side session, a job (`lane exec`, `sala job`) and the default lane are never touched, and a
  background agent on a lane outside the order (api, subscription-2) is left where it is.
- **A row with no role** (an imported or adopted one, a bare spawn) counts by stackshot's project record, the source `spawn --project`
  already checks (interface 20: a name under a project's `background:` agents is a background agent, a top-level one a front agent):
  the rule reads it at every pass (the registry reader `back-names`), and the watchdog writes it onto the row at every tick (`sessions tag --auto`),
  as a bare spawn does for a name the record lists. A name on no map, on two maps, or whose row names another project is left as it is,
  and a stale or missing record changes nothing: the rows with a stored role are still counted. A role already on a row is never
  overwritten. To fill the registry at once: `sala sessions tag --auto --dry-run` (what it would do), then `sala sessions tag --auto`.
- **The catch-up.** A step fires once per weekly window, so an agent the earlier pass did not take (it had no role then, or its pane
  was not up) would stay on the home lane until the next window. While the rule has the agents off home, every pass that finds one
  of them still on a lane it should have left moves it with the rule's lane (a plain `sala op lane`, like the step) and notes the
  names in the state file (`queued`), so a name is asked once per step.
- **The order.** `SALA_BACK_LANE_ORDER="subscription-1 aws-platform bedrock"`: home, second, third.
- **Step 1, off home.** The home lane's "This week" limit (sala-web's saved usage answer, `quota-<lane>.json`; the model-scoped weekly
  limits, "Fable this week", are never read) reaches `SALA_BACK_LANE_THRESHOLD` (90) percent: the background agents move to the second lane.
- **Step 2, on to the third.** A pane running on the second lane is stopped on its cap (the limit watch's record: a workspace or billing stop,
  after the move): they move to the third lane.
- **Step 3, home.** The home lane's weekly window resets (a fresh reading in a later window, under the threshold): every background agent in
  the order moves home, wherever it stands.
- **The move** is the ordinary one: `sala op lane <lane> <sessions…> --from sala-watch --words "$SALA_BACK_LANE_WORDS"` (the words are the
  owner's rule, quoted, from the config), so a busy pane is deferred and retried, and the operation posts ONE notice when it is done.
- **Once per weekly window.** The state file (`SALA_BACK_LANE_STATE`, default `back-lane.state` in the state directory) holds the lane the
  rule has them on and, per step, the window it fired in; a second tick in the same window queues nothing.
- **A reading that cannot be trusted moves nobody:** missing, failed (`errorKind`), older than `SALA_BACK_LANE_MAX_AGE` (1800 s), without a
  "This week" percent or reset time, or already over. A dormant home lane moves nobody. sala-web refreshes that file only when something
  asks its `/api/quota`, so a pass that finds the home lane's reading missing or older than half the max age first asks the local sala-web
  with a plain GET (curl, 5 s timeout, over sala-web's unix socket by default; `SALA_BACK_LANE_REFRESH_URL` sets a socket path or an http(s)
  base URL, or `off`; at most every `SALA_BACK_LANE_REFRESH_EVERY` s, waiting up to `SALA_BACK_LANE_REFRESH_WAIT` s for the file) and reads
  it again. The token stays in the web app: sala makes no call to Anthropic and handles no credential; a failed or slow call leaves the
  reading stale and nobody moves. `--dry-run` says when it would refresh and asks nobody. A target lane that is dormant or cannot launch is not moved onto: one notice per window and step, the state unchanged, a later
  tick moves.
- **Fable.** A Fable background agent is not moved onto a lane in `SALA_FALLBACK_NO_FABLE` (bedrock): it stays where it is and the
  notice names it. The rule does not change a model.
- **Spawn.** A background agent spawned while the rule has them off home launches on the rule's lane (recorded like `--lane`; `--lane`
  wins; a front agent and a side session are not the rule's).
- **Dry run.** `sala watch --back-lanes --dry-run` prints what a pass would do (every outcome, idle ones too) and queues and writes nothing.
  To stage a step without live state, point it at fixtures: `SALA_WEB_STATE_DIR` (a folder with a `quota-subscription-1.json`),
  `SALA_BACK_LANE_STATE` (a file) and `SALA_LIMIT_STATE` (a limit-watch state with a stopped pane), with `SALA_BACK_LANE_RULE=on`.

## The sdk lane
Wed Oct 14th 2026: the API credit on the key pays for Agent SDK
calls on the key and refuses anything sent as Claude Code — the api lane's
`claude` with the key gets "credit balance is too low" — so the only way a pane spends it is the real SDK. The `sdk` lane
does that without pretending: `resume_cmd` types `salamander sdk-pane <uuid> <session>` into the pane (`lib/sdk-pane.sh`),
which runs `contrib/sdk-pane/driver.py` under `uv run --quiet --no-project --with claude-agent-sdk==<pin> python -I`.
The driver starts the CLI through `ClaudeSDKClient` on the conversation (`--resume`), with sala's own claude launcher as
the CLI (so its version is the fleet's), the user settings (`setting_sources`: hooks → sala's busy record; plugins → the
mod; the auto permission mode), the api lane's `--mcp-config` (an SDK session has no claude.ai connector) and Claude Code's
own system prompt. The key and the workspace id are read from the api lane's files by the driver and go only into that
CLI's environment; `CLAUDE_CODE_ENTRYPOINT=sdk-py` is set by the SDK, never by sala (a CLI dressed up as the SDK would
misreport its usage). The CLI registers in `~/.claude/sessions` as every pane's claude does and takes inbox lines (cues,
stackshot, SendMessage) as turns by itself; the driver is the screen: the turn's messages above, a ❯ box at the bottom
(a rule, `❯ <typed text>`, a rule — what sala-web's input box and sala's draft check read), Enter sends, `/exit` leaves.

To sala the pane is a claude pane: the wrapper renames itself `sala-sdk` (never a shell's name, which the sweep,
`exit_wait` and `resume_send` treat as "a shell sits here"), `proc_lane` reads `sdk` from the CLI's environment,
`check_pane` sweeps it with the same gates (the registry's idle, the Stop hook's record, a draft on the ❯ line), `/exit`
is typed into the box, and the resume is the sdk-pane line again. The mod is asked first, as for any pane, and its gates
hold (a draft, a turn, work in flight), but the `/exit` it runs on "ok" ends nothing in a CLI the SDK drives (no
interactive session to leave), so `pane_exit` types `/exit` into the box after the ok: the driver disconnects, the CLI, the
driver and the wrapper end, and the pane is at its shell. No Remote Control, as on api. `sala lane sdk <session>`
moves a session onto it like any lane (the dry run names the files and the variables, never a value); `spawn` on a default
of `sdk` is refused (spawn on another lane, then `sala lane sdk NAME`). **The credit record** (Sun Nov 1st 2026; replaces a
date gate): there is no way to read the key's credit balance, so the refusal is the signal, kept in one
file every job that may spend the key shares (sala's briefings, the sdk lane, other tools on the box):
`${XDG_STATE_HOME:-~/.local/state}/api-credit/state.json`, `{"refused_at": <epoch seconds>, "by": "<job>", "detail": "<first 200
characters of the refusal>"}` (directory mode 700; written by `lib/api_credit.py` with a temp file and a rename; no file = no known
refusal). The key is used while the file holds no `refused_at` within the last `API_CREDIT_RETRY_S` seconds (default 21600, 6 hours); a
refusal with "credit balance" in it (any case) writes the file and the run falls back to the subscription lane
(`subscription-1`); a call that works removes it. So the key is tried again six hours after a refusal, and a top-up is found without
anyone telling sala. `salamander lane` shows the lane as not ready while a refusal is fresh, and says when and by what job. **On the
sdk lane**: `lane_check sdk` refuses while a refusal is fresh; a row of `sdk` then launches on `subscription-1` (`lane_for_session`; one
`fallback` line per relaunch in `lanes.log`; the row stays until `sala lane subscription-1 <session>` clears it, and the table says so),
and the wrapper checks the record itself too, so a pane program typed during that time runs the subscription-1 line in its place. A
turn the credit refuses (an assistant message with error `billing_error`, or "credit balance" in an error result or the CLI's
stderr): the driver writes the record and exits 3, the wrapper rewrites the row to `subscription-1`, posts once in plain words (the
session is back on the subscription-1 login, why, and `salamander lane sdk <session>` to come back) and runs the
subscription-1 line in the pane at once; the last message may need to be sent again. A turn that ends without an error removes the
record. A CLI that dies leaves the pane at its shell with a line; the next revive resumes it as any shell pane.
Knobs: `API_CREDIT_RETRY_S`, `SALA_LANE_SDK_PIN`, `SALA_LANE_SDK_CMD` (tests), `SALA_LANE_SDK_NOW` (tests' clock for the record).
