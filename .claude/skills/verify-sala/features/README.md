# sala verification map

This folder is the maintained source for verifying what a user of `sala` and its web app sees. Read this index before driving,
then use the matching feature file as the recipe.

## Baseline preconditions

- An instance made by `verify.sh` for this run, with every `== doctor` line `ok`. Never drive any other instance.
- No Claude session in it before the first journey.
- A journey that calls the web app has the line `# needs: web` in its file.

## Driving conventions

- Every command in a feature file is a line of a journey file, run with `verify.sh run <journey.sh>`. Keep names and flags as
  written.
- Use session names of the form `vs-test-<topic>` and conversation ids from `uuid <n>`; each feature has its own hundred
  (`uuid 101`, `uuid 201`, ...).
- Reach a session by its exact tmux name (`-t "=vs-test-x:"`) and a web session by its process id (`claude_pid`).
- Journeys of one run share the instance. Restore what changes for all of them.

## Proof and skip reporting

- Capture the action and the state after it: the command with its output and exit code, then a second view.
- For something refused or left alone, check that nothing happened: no new start, nothing in the composer, the draft still there.
- Report an entry point that could not be driven, with the command tried and the missing precondition. Do not report it as
  verified because another entry point passed.
- The evidence folder is the proof; cleanup keeps it.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph of what the user sees. It then has exactly four H2 sections in this
order.

1. `Sub-features`: short ids, one line each.
2. `How to get to it (user POV)`: every user entry point.
3. `Driving it with verify.sh`: starts with `Preconditions:`, then labeled bullets that pair a user action with its exact
   command and the result to observe.
4. `Gotchas`: what can waste or invalidate a run.

## Features

- [Start, list and adopt sessions](./sessions.md): `spawn`, `spawn --list`, `adopt`.
- [Relaunch a session](./relaunch.md): `revive` on an ended claude, on an idle one behind the launcher, and on a typed draft.
- [Web session list and transcript](./web-sessions.md): the running sessions and one conversation in the web app.
- [Web send](./web-send.md): a message from the web app into a session, and what it refuses.
