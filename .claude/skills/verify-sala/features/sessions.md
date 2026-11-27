# Start, list and adopt sessions

A user starts a Claude session in a tmux session of its own with one command, sees it in the list, and brings a session they
started by hand into sala's pane map, the record it brings sessions back from.

## Sub-features

- `spawn-dry` says what a spawn would do and makes nothing.
- `spawn` makes the tmux session, starts claude, names the conversation and records the pane-map row.
- `spawn-twice` refuses a name that is taken.
- `list` shows the live sessions.
- `adopt` records a session made by hand; an unknown name is refused.

## How to get to it (user POV)

- `sala spawn <name> --cwd <folder>`, with `--dry-run` to preview.
- `sala spawn --list`.
- `sala adopt <name>`.

## Driving it with verify.sh

Preconditions:

- No tmux session is named `vs-test-new`, `vs-test-hand` or `vs-test-nosuch`.
- Journey file: `journeys/sessions.sh`.

- **Preview.** `sala spawn vs-test-new --cwd "$HOME/work" --dry-run`. Exit 0, and `tmux has-session -t "=vs-test-new"` fails.
- **Start.** `next_spawn "$U" vs-test-new`, then `sala spawn vs-test-new --cwd "$HOME/work"`. Exit 0; the tmux session exists,
  `reg_live` finds the conversation, `typed "$U"` holds `/rename vs-test-new` and `map_row vs-test-new` holds the id.
- **List.** `sala spawn --list`. `OUT` names `vs-test-new`.
- **Start again.** The same spawn. Nonzero exit, and `starts "$U"` is still 1.
- **Adopt.** `start_session vs-test-hand "$H"` leaves `map_row vs-test-hand` empty; `sala adopt vs-test-hand` exits 0 and the
  row holds the id.
- **Adopt nothing.** `sala adopt vs-test-nosuch`. Nonzero exit and no row.

## Gotchas

- Call `next_spawn <uuid> <name>` before every spawn, with the name you spawn: spawn waits for the registry to show that name.
- The list also shows the sessions of earlier journeys. Check your own name, never a count.
- A live install gates `spawn` behind the operation queue and the project board. The instance runs it as the queue's runner
  does, with the board off, and uses a `-test-` name; neither gate is exercised.
