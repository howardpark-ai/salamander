# A question nobody answers: the instant alert and the parked background run

Two ways a session ends up waiting on a question that only
a person can answer, and what sala does about each:

| case | what already existed | what this adds |
|---|---|---|
| an interactive pane stops on a dialog (a permission prompt, AskUserQuestion's menu) | the watch posts to Slack once the dialog has been up for 90 s (`stuck_tick`) | **D**: Claude Code's Notification hook alerts at once, about 6 s after the dialog shows, through the same post path and state, so the 90 s post does not repeat it |
| a background `claude -p` run asks a question (AskUserQuestion) | nothing: the run is not offered the tool, or hangs, or guesses | **C**: the run parks, the question is filed, and the run resumes with the owner's answer when it arrives; nothing is granted before |

## Step 1: what was checked, and how

Claude Code 2.1.307, haiku. The interactive probe ran only in a private tmux server
(`tmux -L sala-probe-ss1 -f /dev/null`, killed afterwards) in a scratch project directory whose `.claude/settings.json` hooks
appended their stdin to a file. The headless probe used `claude -p --setting-sources project` in the same directory. Each cost
a fraction of a cent. The end-to-end runs of the finished scripts used the installed CLI the same way.

**Verified on the CLI**

| # | finding |
|---|---|
| 1 | Interactive AskUserQuestion fires three hooks, in this order: `PreToolUse` (tool_name `AskUserQuestion`, `tool_input.questions`, `tool_use_id`), `PermissionRequest` at once (tool_name and tool_input again, plus `permission_mode`), and `Notification` about 6 s later with no keystroke. This holds in auto mode too: the question still prompts. |
| 2 | The Notification payload is `{session_id, transcript_path, cwd, hook_event_name: "Notification", message: "Claude needs your permission", notification_type: "permission_prompt"}`. It names no tool and carries no question text. A plain Bash permission dialog (manual mode) fires `PermissionRequest` (with the command and `permission_suggestions`) and then the same `permission_prompt` Notification. So the text of the question has to come from the pane, which is what `sq_read` already does. |
| 3 | `claude -p` is **not offered AskUserQuestion** unless the run has a permission host. With no host, even `--tools default,AskUserQuestion`, the model answers that the tool is not available. With `--mcp-config <a stub MCP server> --permission-prompt-tool mcp__<server>__<tool>` the tool is offered. (Doc: "offers them only when the run has a permission host to receive the prompt".) |
| 4 | A PreToolUse hook returning `{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "defer"}}` ends the turn: exit 0, `terminal_reason: "tool_deferred"` and `deferred_tool_use: {id, name, input}` in the JSON result. The host is never consulted. **The result has no `stop_reason` key**, so keying on it would make `qs_report` print "the run failed:" and exit 1 for a question that was parked and filed. `qpy result` calls a run parked when the result carries `deferred_tool_use` and the hook has recorded that call for that session, whichever reason key is present (a key that names another ending, or a deferral with no record, is not parked). The fake in `tests/fake-claude-p.py` emits this shape by default and the old one with `FAKE_SHAPE=legacy`. |
| 5 | `claude -p --resume <session_id>` with **empty stdin** and the hook returning `allow` with `updatedInput: {questions, answers: {"<question text>": "<option label>"}}` runs the call: the model's next turn said it had been told "Blue". The resume needs the same permission host. |
| 6 | The finished scripts, end to end on the CLI: D alerted from a Notification (the pane's question read, once) and C parked, refused no answer and a wrong answer without starting claude, then resumed with `--answer 2` and the model reported "Blue was picked." |

**Documentation only (not run here)**: `defer` works only when the turn makes a single tool call (with several it is ignored and
the call goes through the normal permission flow, where the stub host denies it); a resume with no answer ready may defer again;
`tool_deferred_unavailable` when the deferred tool is gone; `idle_prompt` and the elicitation types as Notification matchers;
a Notification hook cannot block; `PermissionRequest` can only allow or deny, never defer; deferred sessions stay on disk until
the 30-day `cleanupPeriodDays` sweep.

**Found while building** (both fixed in `lib/stuck.sh`, which the watch shares): on a fresh pane the dialog sits in the upper half
of the screen with blank rows under it, so the watch's `tail -30` of the capture missed it; it now takes the last 30 lines up to
the last non-blank one. AskUserQuestion puts one blank row between its question and its options, which cut the summary down to
"❯ 1. Red"; the walk up from the options now crosses one blank row.

## D: the instant alert

`salamander hook notify` (lib/hook.sh), a Notification hook. For `permission_prompt`, `elicitation_dialog` and
`elicitation_url_dialog` (`SALA_STUCK_INSTANT_TYPES`) in a pane under tmux, it reads the pane's dialog exactly as the watch
does and posts at once.

- **Post path:** `sq_send`, the watch's own: `SALA_NOTIFY_CMD`, else `SALA_WATCH_NOTIFY_CMD`. The wording is the watch's
  (`sq_compose`), so one question reads the same whichever sent it; the question text is built once, in `sq_read`, which drops
  border lines (only box-drawing characters, dashes, `=`, `_`, `·` and spaces, as in "╌╌╌╌" or "- - - -") before the
  200-character cut, so neither post starts with the prompt box's border.
- **No duplicate:** it writes the watch's keys in `stuck.state` (`hash`, `since`, `posted`, `tries`, and its own `instant`),
  under the watch's lock. The watch's later tick finds the question posted. If the watch posted first, the hook finds
  `posted` and does nothing. Once per question either way.
- **A screen the watch cannot read** (a dialog `SALA_PROMPT_RE` does not know, an elicitation form) is still alerted, on the
  notification's own words, under a hash of its own.
- **A failed post** leaves `posted` empty and `tries` at 1, so the watch's retry sends it at its next tick.
- **The Your move row**: wherever a notice is posted, the instant alert's or the watch's 90 s post, sala also runs
  stackshot's `client.py post terminal-prompt open --session <name> --question=<the post's summary, one line, 200 characters
  at most> --sender sala-stuck` (`sq_row_open`), which opens a "Your move" row for the owner (a second open for the same session
  updates the question), and records `row=1` (with `pane` and `sess`) in `stuck.state`. It runs after the post, under
  `timeout` (`SALA_STUCK_ROW_TIMEOUT`, 10 s), with stdin from `/dev/null` and its answer in the sala log, never in the notice;
  a failure, or a stackshot that does not have the call yet, is logged and changes nothing about the post, its retry or its
  dedup (the row is not retried for the same question). `... terminal-prompt clear --session <name> --sender sala-stuck` closes
  it (`sq_settle`) at the earliest of: the watch tick that finds the question gone (or the session gone), and a PostToolUse or
  Stop hook run in that pane (`hook.sh` `_row_check`, only when `stuck.state` holds a `pane=` line for it; the hook clears in
  the background, and only if the pane shows no question, so another tool finishing under a still-open dialog leaves the row).
  A refused clear keeps `row` (2 to 4 counts the failures) for the next tick, four tries at most. The Slack post is unchanged.
- Never blocks or fails a turn: exit 0 always, 15 s bound on the post (`SALA_STUCK_INSTANT_TIMEOUT`), nothing on stdout (but
  `--dry-run`, which prints the post and writes nothing). `SALA_STUCK_INSTANT=off` or `SALA_STUCK_POST=off` turns it off.

## C: the parked background run

`salamander question run` starts `claude -p` with `SALA_DEFER_QUESTIONS=1`, `--permission-prompt-tool mcp__salahost__approve`
(`lib/permission-host.py`, a stdlib MCP server whose one tool denies everything, so the host grants nothing), and `--settings`
with a PreToolUse hook (matcher `SALA_DEFER_TOOLS`, default `AskUserQuestion`; command `salamander hook ask`). So a run started
this way needs **no entry in settings.json**; the hook is inline. Only a run started elsewhere (a unit that calls
`claude -p` itself) needs the hook entry and the env var by hand.

1. The hook defers the call, writes a record under `~/.local/state/salamander/questions/<qid>/record.json` (0600 in a 0700
   directory; it holds the call's input, which the resume echoes), and files the question.
2. `salamander resume-answer <qid> --answer "<label or number>"` checks the words against the options, stores the decision and
   runs `claude -p --resume <session>` in the run's folder (with the run's permission mode, which a resume does not restore).
   The same call fires the hook again, which returns `allow` with `updatedInput {questions, answers}`.
3. **Nothing is granted unless the answer arrives.** A parked call with no answer is deferred again; `resume-answer` with no
   answer (and none from the answer seam) exits 3 without starting claude; an answer that is not an option exits 4 with the
   options and leaves the call parked; `--free-text` takes the owner's words as they are; `--decline [why]` denies the call.
4. Two questions: one line each (`1: S` / `Top: Egg`). A multi-select: labels or numbers, comma separated. A second question after
   the answer parks the run again (exit 10, a new id).
5. A tool other than AskUserQuestion can be listed in `SALA_DEFER_TOOLS` (for example `"AskUserQuestion Bash"`). PreToolUse fires
   **before** the permission check, so it cannot tell a call that would prompt from one that would not: every call of a listed
   tool parks, and the answer is yes (allow this exact call) or no (deny it). This is how "a permission need" is covered; the
   `PermissionRequest` hook cannot defer, so it is not used.

### The two seams, and the board scripts that fill them

Filing the question and reading the owner's answer are two seams, each one command the operator may set. Where stackshot's
`client.py` has the verbs that file an item and read an answer, the seams have a default:

| setting | does | unset |
|---|---|---|
| `SALA_QUESTION_FILE_CMD` | files the question. The text (secrets masked) is on stdin; `SALA_QUESTION_ID`, `SALA_QUESTION_SESSION`, `SALA_QUESTION_LABEL`, `SALA_QUESTION_RESUME` and `SALA_STATE_DIR` are in the environment; the first word of its first stdout line is kept as the item id; non-zero = not filed | `contrib/question-board-file.sh` when stackshot's client exists (`SALA_STACKSHOT_CLIENT`, default `~/stackshot/client.py`); with no client, a post through the notify command (the watch's path), `filed: post` |
| `SALA_QUESTION_ANSWER_CMD` | reads the owner's answer; `SALA_QUESTION_ID`, `SALA_QUESTION_ITEM`, `SALA_QUESTION_SESSION`, `SALA_STATE_DIR` in the environment; the answer on stdout, empty or non-zero = not yet | `contrib/question-board-answer.sh` when the client exists; otherwise only `resume-answer --answer` supplies it |

An explicit setting wins; `off` turns a seam off (the post path / no board read) even where the client exists.

**The file script** (`contrib/question-board.py file`, via `question-board-file.sh`) calls
`client.py post question --project $SALA_QUESTION_PROJECT (set in config; empty by default) --subject "[<scope>] <label>: <first question>" (the scope: SALA_DEFAULT_SCOPE, else the first of SALA_SCOPES, else no bracket)
--request-id <question id> --sender <the run's label> --ask "Decide: <question> · Recommend: none, your call · Stakes: a background
run is parked until you answer · By: any time"`, one `--option "<label>=<description>"` per option and `--recommended`, the question
on stdin. It prints the item id (`board#N`).

- **Idempotent:** the request id is the question id, the sender the run's label, both stable, so filing again (the hook's
  filing timed out, `sala question file`, the sweep) gets the same item and files nothing new.
- **It meets the board's limits itself,** so the client never refuses for shape: the text is cut to a head of at most 5 lines
  and 8,000 characters ending with `(cut; see sala question show <id>)`; the ask stays within 240 characters; a `;`, a ` · ` or
  a `Decide:` inside the question is made safe (the server reads them as several decisions); `done:` / `resolved:` in the text
  is defused (the description gate forbids them); the subject stays within 80 characters.
- **Buttons:** one question that is not a multi-select, with 2 to 6 labels of at most 40 characters and no `=`, gets one button
  per option, the label the owner picks being what `resume-answer` takes. The server insists on exactly one recommended option: it is
  the one whose label says `(Recommended)`, else the first, though the ask still says `Recommend: none, your call`. A listed Bash
  call gets Yes / No with No flagged. Several questions, a multi-select or labels the board cannot take: no buttons, and the item
  says to answer in words.
- **Masked:** the ask and the subject are built from the text sala has already masked, never from the record.

**The answer script** (`question-board-answer.sh`) runs `client.py get answer <item>` and prints the answer **only when its kind is
`decision`**: a comment is never an answer, and the client already returns the owner's newest decision over any later comment. It prints
the option label picked, else the owner's words, and only if `lib/question.py answer --check` says sala would take them for that call
(for two questions the board's ` / ` line joins are turned back into lines). Words that do not fit are not used and are written
to `salamander-question.log`; the question stays parked until the owner decides again or someone runs
`sala resume-answer QID --answer … [--free-text]`. Free text is not taken through the seam: that is sala's own `--free-text`
rule, and a seam cannot pass the flag.

If the board refuses a filing (the client exits 1) or cannot be reached, the seam fails, `filed` stays empty, the run stays
parked, and `sala question sweep` files it again (the request id makes that safe). The failure is in `salamander-question.log`.
A refusal that repeats (a question the server's gates will never take) leaves the question unfiled: it shows in
`sala question list` with `-` as its item. It is not left unannounced: after `SALA_QUESTION_FILE_TRIES` failed filings in a row
(3; the hook's own try counts as the first, a timeout as a failure) sala sends ONE post through the notify command, the one used with no
file seam, saying the board did not take it, the reason the script gave, the question and the `resume-answer` command. The sweep keeps
trying to file it, and a later success clears the count and posts nothing more.

**The sweep runs by itself.** Every `sala watch` run calls `question_sweep_tick` (`lib/watch.sh`; `sala watch --questions` runs it
alone). With no questions directory, or no record that is parked or answered, it does nothing: no client call, no unit. Otherwise,
at most once per `SALA_QUESTION_SWEEP_EVERY` seconds (60; `0` or `off` disables), it starts `sala question sweep` as its own
transient unit `sala-auto-qsweep` (the way the settings-apply tick starts its run: systemd refuses a second while one runs, and
`RuntimeMaxSec=SALA_QUESTION_SWEEP_TIMEOUT`, 1800, bounds it), so a resume that takes minutes never holds the tick. A launch
that cannot start is logged and never fails the tick.

**Not proven end to end against a live board.** The tests (`tests/boardseam.sh`) use a fake client that enforces the board's
limits as read from stackshot's `client.py` and `server.py`, so a script that would be refused there is refused in the test.
A live run needs the owner's answer on the item (a button, or their words), then up to a minute for the watch tick's sweep (or
`sala question sweep`, `sala resume-answer QID`) to see the run resume. The unit launch (`sala-auto-qsweep`) is tested with a stub `systemd-run`.

## Settings entries needed

One `Notification` entry (D) and, only for runs not started by `question run`, one `PreToolUse` entry (C).

## Design rules

- The instant alert is the Slack post itself (one message, not a second one beside it): it goes ahead of the 90 s post,
  through the same path, so there is no duplicate.
- C needs no settings entry: the hook is injected with `--settings` on the run.
- A permission need is covered by listing the tool in `SALA_DEFER_TOOLS`, not by `PermissionRequest` (cannot defer).
- Answers must be an option's label or number; free text only with `--free-text`.
- `question sweep` runs from the existing watch tick (no new timer), as its own unit, at most once a minute and only while a question is open. The board filing and answer reading are the default seams, used only when the client exists.
