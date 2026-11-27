# Relaunch a session

`sala revive` brings a session back on its own conversation: one whose claude has ended, or an idle one still running an older
CLI than the launcher now points at. A session with unsent text at its prompt is left alone, so the text is not lost.

## Sub-features

- `revive-dry` shows the plan and starts nothing.
- `revive-ended` resumes an ended session's conversation in its pane.
- `revive-stale` types `/exit` into an idle session behind the launcher and resumes it.
- `revive-draft` skips a session with unsent text, says why and types nothing.

## How to get to it (user POV)

- `sala revive --only <name>`, with `--dry-run` to preview.
- `sala revive`, which sweeps every pane.

## Driving it with verify.sh

Preconditions:

- No tmux session is named `vs-test-dead`, `vs-test-stale` or `vs-test-draft`.
- The `claude` launcher points at `9.9.9`.
- Journey file: `journeys/relaunch.sh`.

- **End a session.** `start_session vs-test-dead "$D"`, `sala adopt vs-test-dead`, then
  `tmux send-keys -t "=vs-test-dead:" /exit Enter`. `reg_live` stops finding the conversation.
- **Preview.** `sala revive --only vs-test-dead --dry-run`. Exit 0 and `starts "$D"` is still 1.
- **Bring it back.** `sala revive --only vs-test-dead`. Exit 0; `starts "$D"` becomes 2 and `reg_live` finds the same id.
- **Fall behind.** Start and adopt `vs-test-stale` and `vs-test-draft`, then `new_cli_version 9.9.10` and
  `tmux send-keys -t "=vs-test-draft:" -l "half typed"`.
- **Leave a draft.** `sala revive --only vs-test-draft`. `OUT` says `unsubmitted`; `starts "$K"` is 1, `typed "$K"` is empty and
  `screen vs-test-draft` still shows `half typed`.
- **Relaunch an idle one.** `sala revive --only vs-test-stale`. Exit 0; `typed "$S"` holds `/exit` and `starts "$S"` becomes 2.
- **Restore.** `new_cli_version 9.9.9`.

## Gotchas

- Always pass `--only <name>`: a bare `sala revive` also sweeps the other journeys' sessions.
- Revive finds an ended session through its pane-map row, so adopt (or spawn) it first.
- The fake claude registers `9.9.9` whichever binary started it, so the report reads `9.9.9 → 9.9.9`. The new version is not
  verified; check the `/exit` and the second start.
- A skipped pane gets a retry worker (here every 2 s, for 6 s) that writes its own notice to `notify.txt`. Once the launcher is
  restored the worker may report that pane as current.
- The bare form (the sweep) is not driven by this journey.
