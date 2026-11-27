# Web send

A message a user sends from the web app is typed into the session's pane. The app refuses a request from another site or of the
wrong type, the same message twice at once, and any message while the pane's input box holds unsent text.

## Sub-features

- `send` delivers one message to the composer.
- `send-guard` refuses a cross-origin post (403) and a content type that is not JSON (415).
- `send-twice` refuses the same message again at once (409, `duplicate`).
- `send-draft` refuses to type over unsent text (409, `boxText`) and keeps it.
- `send-unknown` answers 404 for a process id with no session.

## How to get to it (user POV)

- The message box of an open session: `POST /api/s/<pid>/send` with `{"text": ...}`.

## Driving it with verify.sh

Preconditions:

- The journey file has `# needs: web`.
- No tmux session is named `vs-test-send`.
- Journey file: `journeys/web-send.sh`.

- **Another site.** `web POST "/api/s/$PID/send" '{"text":"..."}' application/json http://elsewhere.example`. 403.
- **Wrong type.** The same body with `text/plain` as the content type. 415. `typed "$M"` is still empty.
- **Send.** `web POST "/api/s/$PID/send" '{"text":"hello from verify"}'`. `json '.ok == true'`, and `typed "$M"` holds the
  message.
- **Send again.** The same call. `json '.duplicate == true'`, and `typed "$M"` is exactly the one message.
- **Over a draft.** `tmux send-keys -t "=vs-test-send:" -l "half typed"`, then post another message. 409, `.boxText` holds the
  draft, nothing more reaches the composer and `screen vs-test-send` still shows it.
- **No session.** `web POST /api/s/999999999/send '{"text":"nobody"}'`. 404.

## Gotchas

- The app types only into an input box it can read: a prompt row between two rules. The instance has the fake claude draw the
  rules through `FAKE_FOOTER`; a session started with its own `FAKE_FOOTER` loses them and every send is 409. The real CLI's
  input box is not exercised.
- A draft stays in its pane, so every later send to that session is refused. Use another session, or clear it.
- `web` sends no `Origin` unless you pass one, and sends JSON unless you pass another type.
- Attachments, send-now and the page's own composer are not driven.
