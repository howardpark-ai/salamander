# Models

Choosing, recording and changing the model and effort of a session.

A session's **model and effort** can be recorded (Wed Oct 14th 2026; `lib/common.sh` "models",
`lib/model.sh`). Without a record every relaunch takes both from the conversation's own transcript (the newest real turn's
model family as `--model`, the prevailing effort as `--effort`; `resume_cmd`), so a pane could be moved only by typing
`/model` into it, and the next relaunch followed whatever the transcript last said. A record wins over the transcript at
every relaunch: the model always, the effort when one is recorded (`-` keeps the transcript's).

**State, not config** (`~/.local/state/salamander/`): `models.tsv`, one `<tmux session>\t<model>\t<effort or ->` row per
session with a model of its own (`rename` moves the row, `retire` drops it), written atomically under its own lock, and
`models.log`, one line per change, and `model-inplace.tsv`, what a live claude was switched to in place (below). `sala
model` is the only thing that writes them, and moves the pane the way `sala lane <lane> <session>` does: the row under the
recycle lock first, then either the in-place switch below or `revive --force --only <session>` (or `revive --self` for the
invoking pane), with the same guards (a busy pane deferred and retried, `SALA_NO_RELAUNCH` refused, the master's pane when
a Claude session asks). `--dry-run` writes nothing and relaunches nothing: it prints the row it would record and the path
that applies (*would switch in place* or *would relaunch*, with the reason, then the sweep's verdict). A model id is typed unquoted onto the launch line, so only lowercase letters, digits, dots and
dashes after `claude-` are taken (a `[1m]` suffix would be a glob to the pane's shell).

**Through the operation queue** (Sun Oct 25th 2026; a verb to change an agent's model and effort, self-modification included): `sala op model <session> <model> [--effort <level>] --from NAME --words "<the owner's
words>"`, or `sala op model <session> --clear …`; since Thu Oct 29th 2026 (so that a batch of model changes does
not wake a front agent once per session) also `sala op model <model> [--effort <level>] <session>… --from NAME --words "…"`
for several sessions as ONE operation (and `sala op model --clear <session>…`). **Which shape:** a first word that is a model
(`opus`, `sonnet`, `haiku`, `fable`, or `claude-…`, `model_batch_shape`) is the many-session form; any other first word is the
session of the single-session form, which is unchanged. The two corner cases: `<session> --clear` is always the single form
(a session literally named `opus` is cleared that way), and a `claude-…` first word that names a live tmux session followed by
a model is read as that session; a family alias is never read as a session name. All the sessions are checked before anything
is queued (an unknown one refuses the whole operation, naming it; the plan is each session's `model … --dry-run`). When it
runs, each session goes through the single switch in turn under ONE recycle lock (in place when idle with an empty input box,
else recorded for the relaunch), the asking session last, and the panes that need a relaunch are relaunched TOGETHER by one
`revive --force --only A --only B …` sweep, as `lane <lane> <session>…` does. The result is ONE notice for the batch: one
Slack post and one line into the asker's inbox, a line per session under the summary (`RESULT` lines printed by `lib/model.sh`,
kept as `detail=` lines on the marker). A failed session does not stop the others; the operation then ends 🚨 stuck, the
summary naming the failures, without the one-off `claude -p`. For example (three sessions, in place on one, relaunch on two):
```
[sala op 1761750000-4242] salamander model haiku --effort high sala-a sala-b sala-c — done: Revive …: 2/2 relaunched.
  - sala-a: switched in place to haiku/high
  - sala-b: relaunch started on haiku/high (a busy pane is retried until it is idle)
  - sala-c: relaunch started on haiku/high (a busy pane is retried until it is idle)
```
A Claude session's raw `sala model <session> …` is refused by the guard
(`master_guard`) with the pointer to the queue; the table form, `sala model` with no argument, is read-only and stays open.
The shape is checked at queue time with the same functions `sala model` uses (`model_valid`, `effort_known`), and the plan is
`model … --dry-run` (an unknown session refuses it before anything is queued); `--record-only`, `--not-master` and `--dry-run`
are not queue arguments. The runner takes the recycle lock itself, like `lane`, and a second operation of another verb
naming the same session is refused. The asking session may name itself: the queue's unit has no pane, so it moves the
session like any other (in place once it is idle, else `revive --force --only`; a busy pane is handed to the retry worker and
relaunched once idle), and `op` prints "this pane will have its model switched once it is idle" when the target is the
asking session. The
result (✅ done or 🚨 stuck, one Slack post and one line to the asking session's inbox, which arrives after its relaunch)
follows the other relaunch verbs; `--clear` relaunches nothing.

**In place first.** A pane that is idle with an empty input box keeps its
conversation process: `sala model` types `/model <model>` (and `/effort <level>`) into its composer through `tui_send`,
the record already written, and no relaunch follows. The gate (`model_inplace_gate`, lib/model.sh): `SALA_MODEL_INPLACE`
on (default), a claude running in the pane, not the command's own pane (that one is mid-turn), not the sdk lane (no
composer), `is_idle` says idle (unknown is never idle), no dialog on the screen, the input box empty. Anything else, and
any failure after the first keystroke, is the relaunch above, with the reason printed. `/model` opens a *Switch model?*
dialog when the model differs from the last turn's: Enter is sent only while the screen shows exactly that, once; any other
dialog gets an Escape and counts as a failure. The switch is verified by a new *Set model to* line (and *Set effort level
to* for `/effort`) on the pane. Each of those commands saves the lane's **default** in its `settings.json` (the top-level
`model`, `modelSettings.<id>.effortLevel`), which would move every session started later, so those keys are snapshotted
before the first keystroke and put back afterwards, on the failure path too: compare-and-restore, re-reading the file so a
key somebody else changed meanwhile is kept, an atomic write (temp file beside it, fsync, its mode, rename), the file's
other keys and layout untouched, no write at all when nothing differs. The file is the pane's own: the `CLAUDE_CONFIG_DIR`
of its claude (the subscription-2 lane's directory), else `~/.claude`. All of it runs under the recycle lock the record is written
under. `model-inplace.tsv` remembers what a live claude was switched to (its command line no longer says), so the same
request again is left alone and the table marks the pair with a star. The asking session, from the queue's runner, is
waited for (`SALA_MODEL_INPLACE_ASKER_WAIT`, 90 s) to end the turn that queued the switch, then switched like any idle pane.
`SALA_MODEL_INPLACE=off` brings back the relaunch alone. Knobs: `SALA_MODEL_INPLACE_WAIT` (20 s a typed command has to
show its line), `SALA_MODEL_INPLACE_SETTLE` (1 s the CLI is given to finish its own settings write before they are put back,
and again before the check). Tested against a fake claude (`tests/modelinplace.sh`) shaped by a probe of 2.1.310.

**`--record-only`** writes the row and relaunches nothing (no `revive`, no self-worker): the session comes onto the
record at its next relaunch, whatever starts it (a recycle, a lane move, the boot hook, a restore). Meant for the panes
of a per-pane model plan that are not to be relaunched now, which would otherwise come back on whatever their
transcript last ran. Same checks, guard and recycle lock as a switch; `--dry-run` prints the row and writes nothing;
with `--clear` it is an error (a clear never relaunches anyway). It takes a session with no tmux session right now
when sala knows the name: a tmux session, a pane-map row, or a model row of its own. A name it has never seen is
refused.

**The compact window** (Thu Oct 29th 2026; a window that differs by type of agent, depending on the nature of its work). Background agents compact at 200k tokens, set by the config repo's project settings for
background agents. A shared settings file cannot say a window per session, so a session that needs a different one gets
it from sala: `compact.tsv` in the state directory (`~/.local/state/salamander/`, beside `models.tsv`), one
`<tmux session>\t<tokens>` row per session with a window of its own, added by hand to the live file. No row ships by default. `claude --autocompact <tokens>` (CLI 2.1.312:
"auto, or 100k–1M tokens"; it overrides the project setting and refuses anything else at start) is put on the pane's launch
line: `resume_cmd` (every revive, recycle relaunch, lane move, `sala model` relaunch, unpark) and `spawn`. No row, a
`#` comment line or a row whose value is not a whole number from 100000 to 1000000 is no flag, and the project setting
applies (a bad value would leave the pane at a shell, so it is ignored the way a bad `models.tsv` row is). The sdk lane's
pane program and a one-shot `claude -p` carry no flag. No verb writes the file: `install.sh` seeds it from
`contrib/compact.tsv` (a header comment and no rows) when it is absent, and it is edited by hand after that; a pane takes a
changed value at its next relaunch. `rename` and `retire` do not move the row. Tested in `tests/models.sh`.
