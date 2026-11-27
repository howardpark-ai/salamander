# Web session list and transcript

The web app lists the running sessions and shows the conversation of the one a user opens. A session that has ended leaves the
list.

## Sub-features

- `web-list` shows each running session once, with its name, process id and conversation.
- `web-transcript` gives a session's messages in order; an unknown id is 404.
- `web-page` serves the page.
- `web-ended` drops a session whose claude has ended.

## How to get to it (user POV)

- Open the web app: the page (`GET /`) reads `GET /api/sessions`.
- Open one session: `GET /api/s/<pid>/transcript`.

## Driving it with verify.sh

Preconditions:

- The journey file has `# needs: web`.
- No tmux session is named `vs-test-web`.
- Journey file: `journeys/web-sessions.sh`.

- **A running session.** `start_session vs-test-web "$W"` and write its transcript to
  `$HOME/.claude/projects/x/$W.jsonl`.
- **List.** `web GET /api/sessions`. 200, and `json` finds exactly one session named `vs-test-web` with that id and
  `claude_pid vs-test-web`.
- **Open it.** `web GET "/api/s/$PID/transcript"`. 200, with the question before the answer.
- **Unknown.** `web GET /api/s/999999999/transcript`. 404.
- **The page.** `web GET /`. 200 and HTML.
- **End it.** `tmux send-keys -t "=vs-test-web:" /exit Enter`, then `web GET /api/sessions`. No session named `vs-test-web`.

## Gotchas

- The fake claude writes no transcript. The journey writes the few fields the app reads, so a change in the CLI's transcript
  format is not caught.
- Only the routes are driven. What the page draws from them needs a browser check, which this skill does not have.
- The list holds the earlier journeys' sessions too. Filter by name.
