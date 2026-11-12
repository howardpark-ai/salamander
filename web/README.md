# sala (web/)

**The app is called sala**, at
whatever address it is served on, e.g. https://sala.example.com (*Hosts* below). Only what a user
sees carries the name: the directory `web/`, the package `sala_web`, the command `sala-web`, the units
`sala-web.service` and `sala-web.socket` and the socket path are named sala-web (*Renamed units* below), the settings are named `SALA_WEB_*`, and this document says sala-web wherever it
means one of those.

The sidebar's header, above the New session row, is the app's icon (`static/icons/icon-192.png`, an `<img>` with `alt=""`
and a fixed 20 x 20 size, so nothing shifts while it loads) and the words **salamander** (or **salamander : <suffix>** when `SALA_BRAND_SUFFIX` is set; written into the page by the server so a reload shows no flash, and served by `api/config` as `brand` for `app.js` to repaint) on one line, in the
drawer on a phone and, on a wide screen, in the one fixed block at the top left. The page `<title>`, the manifest and the update banner still say "sala".

**The owner's name.** The page's own text that names the person running the machine (the New session form's "a session <name> talks
to" hint) and the `--words` the form queues ("<name>, via the sala web form: new ...") take the name from sala's `SALA_OWNER_NAME`
(`config.owner_name()`: the environment, else the config file as text, else `the owner`; one line of at most 40 characters). The hint is
filled into the served page (`{{owner}}`, escaped), like the title bar's name, so a reload shows no flash. Nothing in the script needs the name.

**The toggle and the header are one fixed block (as in Notion's and Claude desktop's):** on a
wide screen the sidebar's toggle button and the header (icon and "salamander", with the suffix when one is set) are `position: fixed` at the top
left, above the title bar and the sidebar, and sit at the same place, size and text whether the sidebar is closed, peeking
(hover) or pinned. There is one toggle (`#side-open`) and one header (`.side-head`, inside `#sidebar`); the older "sala" text was
only the header, nothing in the code draws it now. The block's row is kept free: the sidebar's `padding-top`
leaves it empty, and while the sidebar is not docked the title bar's `padding-left` (296 px, where a docked bar's content starts
too) keeps its content out from under the block and from under a peek. The header is transparent and lets the pointer through, so
it takes the sidebar's colour or the title bar's from what is under it, and only the toggle peeks and pins. Because a transformed
sidebar would carry its fixed header away with it, the sidebar closes by `left` (-280px to 0), not by a transform. The update banner
pushes the title bar down, so the block follows it (`--banner-h`, set by `app.js`). The peek is the pinned sidebar (same width, rows,
scroll and border) drawn over the page with a light shadow; a pinned one still docks beside the page and a peek may cover the title
bar. A phone keeps its drawer: the toggle in the title bar, the header with the close button at the drawer's top, none of it fixed.
The toggle's tooltip says "Show sidebar" (closed) or "Hide sidebar".

A claude.ai-like web UI for the Claude Code sessions running in tmux on this machine: a session list grouped by
project, each session's transcript rendered as a chat, its tmux pane in a Terminal tab (the existing ttyd at
<sala's address>/tty/), and a composer that types a message (with pasted images and files) into the session's pane.

It lives under `web/` of the salamander repo (`~/salamander/web` on the machine) and is changed and deployed the way
sala is, *Deploying* below.

## What it can and cannot do

- **It creates sessions only through the New session form, and only via sala's queue (`sala op spawn`, *New
  session* below; the form also asks stackshot to make a project and its page, or to list one again, and to add the
  agent to the project, before it queues the session); it never kills, renames or restarts a tmux session, window or pane, or a Claude session, and it
  never starts one itself.** The only write to tmux is a paste plus Enter into the selected session's own pane
  (`tmux load-buffer`, `tmux paste-buffer -p`, `tmux send-keys Enter`), or one keypress answering a dialog open
  there (below). Everything else is read-only (`display-message`, `capture-pane`). **The one exception is the shell
  drawer's own session, `SALA_SHELL_SESSION` (default `sala-shell`; *The shell drawer*):** the app makes that one tmux session itself
  (`tmux new-session -d -s <SALA_SHELL_SESSION> bash -l`, only when it does not exist) and sends fixed key names to it
  (`tmux send-keys`, an allowlist, never free text). It is a plain bash, never a Claude pane, and nothing here reads or
  sends to any other session through it.
- Before pasting, it checks that:
  1. the pane on record (`%N` from the session's `tmux` field) exists and its process is the session's pid or an
     ancestor of it, because a `%N` alone does not say which tmux server it is on (a probe on a private server
     records `%0` too);
  2. the pane shows Claude Code's input box (a `❯` line between two horizontal rules). A rule is a line that is
     mostly `─`, or one that starts and ends with a run of `─` (3 or more each) around a short label, since Claude
     Code draws the session name in the rule above the box and in a 50-column pane that is only about half `─`. In
     shell mode (after `!` is typed) the box's first glyph is `!`, not `❯`, and a command sent then loses its own
     leading `!` so the box does not get a second one. A permission dialog or menu
     has no such box, so nothing is pasted into it. If the pane shows a numbered selection dialog instead (a focused
     `❯ 1. Yes` line and the options `2.`, `3.`... below the last rule above it), a message that is exactly one of
     the option numbers is sent as that one digit (`tmux send-keys <digit>`, no Enter: Claude Code's selection
     dialogs pick an option on its number key), and `esc` is sent as Escape (cancel). Anything else, a number not
     offered, or an image, is refused with the options listed ("a dialog is open in the pane: answer with one of 1,
     2, 3, or esc; nothing sent"). The page drops the message bubble of an answer and says what it sent;
  3. the input box is empty. Dim text is the placeholder suggestion and counts as empty. If the owner (or anything
     else) left text there, the send is refused with "pane input box is not empty". sala-web never clears it.
- **Older messages load as the chat is scrolled to its top.** A session's chat opens with the last 200 messages of its
  transcript (`TAIL_N`, `transcript.read_tail_page`); the stream's `reset` also carries `before`, a cursor (the byte offset
  in the transcript where those messages begin), and `start` (the file's start is already in). A line at the top of the
  chat is watched (an `IntersectionObserver` on the chat pane, 300 px ahead of the view, so a touch scroll on a phone
  triggers it as well as a wheel): when it comes into reach the page fetches `GET /api/s/<pid>/transcript?before=<cursor>`,
  the 200 messages that end before it and the next cursor (`transcript.read_before`: it reads the file backwards from the
  offset in 1 MB chunks, never whole, with read_tail's parsing), and puts them above the oldest one shown with the
  message in view kept where it was on the screen. One fetch at a time, the line reads *Loading older messages…* while it
  runs, and *Start of this conversation* once the file's start is reached, after which nothing more is fetched. The
  cursor is checked on the server (an integer, within the file's complete lines, at a line's start; else 400), and the
  file is always the session's own: no path comes from the page. A reconnect's reset shows the last 200 again. Not
  loaded: an earlier conversation before a `/clear` (another transcript file). A chat opened at a Search result far back
  (*Search*) also has a line at its bottom: `GET /api/s/<pid>/transcript?around=<cursor>` gave the page around the entry with
  `before` and `after` (`transcript.read_around`), and `?after=<cursor>` brings the next newer page (`transcript.read_after`,
  forwards in 1 MB chunks) until `end`, the live end, is reached; the cursors are checked as `before`'s is.
- **A running `!` command.** Claude Code writes a `!` command's output to the transcript
  only when the command ends or times out (a `gh auth refresh` shows nothing while it waits, and its one-time code is only in the
  terminal view), and the chat reads only the transcript. So while a command runs, the stream also watches the pane:
  - *Running* is read from the pane (Claude Code 2.1.312, a pane check: the transcript gets no `<bash-input>` record while
    the command runs, `bash-` lines come only when it ends, and the pane **keeps its input box**, so the two gates of an earlier version, a
    transcript record and a pane with no input box, never held). The pane shows a running `!` command when (1) above the input
    box the nearest line that starts a turn at column 0 is the command's echo `! <command>` (a reply `●`, a tool call `⏺` or a
    prompt `❯` nearer than the echo means something else), (2) under the echo is the `(ctrl+b ctrl+b (twice) to run in
    background)` hint or an elapsed-time line (`+N lines (Ns)`, a bare `(Ns)` after short output, `Running… (Ns)` for a quiet command), and (3) `esc to interrupt` is on the screen under the echo
    (`tmuxio.bang_pane`). A reply, or a model's own Bash call, shows `esc to interrupt` and the same hint but no `! ` echo as its
    nearest turn, so it is not taken for one; a finished command shows neither the hint nor a counter (its fold ends in
    `(ctrl+o to expand)`), and a stopped one is back in a shell-mode box with no `esc to interrupt`. The stream makes one
    `capture-pane` about every 2 s while it is open and nothing is seen running (a `!` command leaves nothing in the transcript
    to say it started), about every 0.75 s while one is. The transcript is a fallback only: if its latest `!` record is a
    `<bash-input>` with no `<bash-stdout>` / `<bash-stderr>` after it (`transcript.bang_running`, kept up to date by `bang_scan`)
    and the pane shows no input box at all, that is a running command too (the screen as `tmuxio.live_text` cuts it), and
    the record's uuid goes into the event; a stale record (three looks that find nothing) costs no more than the 2 s look.
  - The stream sends `event: live` with `{"running": true, "command", "uuid", "text"}` whenever the text changes: `command` from
    the pane's echo, `text` the output lines between the echo and the input box as plain text (`tmuxio.plain`), the last 40
    lines, without the rules, the input box, the footer, the hint and the elapsed-time line (which ticks every second and would
    make every capture a change). When the pane no longer shows it (the output record landed, or the prompt is back) it sends
    `{"running": false}`. A stream that opens or reconnects during a command sends the block right after its `reset`, so a
    refresh shows it again.
  - The page shows it as a block at the bottom of the chat, under the command's line, with a **Stop** button; the
    command's output box (next bullet) replaces it when the command ends: the output record removes the live block in the
    same tick that draws the box, so no frame has both, and the box lands where the live block was, under the command's
    line. Their heights differ (the live block shows up to 40 lines in a scrolling area, the box 12 lines), but both sit at
    the end of the chat, so nothing above them moves.
  - **The output of a finished `!` command shows open.** `transcript.py` turns a
    `<bash-stdout>` / `<bash-stderr>` record into a block of its own kind, `bang_output` (`text`: the stdout, then the stderr,
    clipped at `TEXT_LIMIT`; `truncated`; the page counts the lines). The record holds both tags; the match is greedy and
    anchored on the other stream's tag, so output that contains the closing tag as text is not cut short, and a record with
    an unmatched tag shows its text without the tags. The page draws it under the command's `! <cmd>` line in a box headed
    "Output · N lines" with a **Fold output** button (a `<button>` element, `aria-expanded` carries the state, `aria-controls`
    its body; the label stays the same and an arrow shows the state) that closes and opens it. Up to 12 lines show all of
    it; over 12, the first 12 show and a "Show all N lines" button opens the rest in place (focus moves to the Fold button
    as that button goes). The text is a keyboard-scrollable region (`tabindex="0"`). A clipped output keeps its
    "(truncated)" note; a command that printed nothing shows "(no output)". Everything else that was a "command output" or machine notice stays a closed fold: a slash command's
    output (`<local-command-stdout>`), a message from another session, a task notification.
  - **Stop** posts to `/api/s/<pid>/stop`: Escape into the session's own pane (same pane and ownership check as a send,
    under the same per-pane lock), and if the command still runs a second later, Ctrl-C. Refused with 409 and nothing sent
    when no `!` command runs (the same pane check; a model turn showing `esc to interrupt` is not one: 409
    "no ! command is running in this session; nothing sent"). One Ctrl-C at most per click: Claude Code asks for a second Ctrl-C to exit when its input box is idle.
  - There is no answer box: a running command cannot be answered from the page yet (a send is still refused with "no input
    box in the pane"), and the terminal tab is the way to type to it.
- Sending is allowed while the session is busy: Claude Code queues the prompt.
- Images and files: pasted into the composer, dropped on the page, or picked with the attach button beside it (a file chooser
  for any file; on a phone it offers the camera, the gallery and files, since a paste or a drop does
  not reach the composer there). A paste takes its images from `clipboardData.files`, and reads `.items` only when
  files is empty: Chromium makes a new `File` for every `getAsFile()` call (`image.png`, `lastModified` = now), so
  reading both attached two chips for one paste. One gesture is one chip whichever
  events deliver it: the paste event, `beforeinput` and the `<img>` the browser inserts are the links of one chain, and
  a later link skips the bytes an earlier one attached within the second (size and type; two pastes in a row are two
  chips). All three feed the same path: uploaded to `$XDG_STATE_HOME/sala-web/uploads/`
  (default `~/.local/state/sala-web/uploads/`) under a random name, then their paths are pasted with **bracketed paste**. Claude Code turns a bracketed-pasted image
  path into an `[Image #N]` chip; the same path typed with `send-keys -l` stays raw text (tested on Claude Code
  2.1.296). Uploads older than 30 days are deleted at startup.
- **Any file, not only images.** The attach button's chooser takes everything, a drop takes
  every file, and a paste takes every `File` on the clipboard (`clipboardFiles`; `clipboardImages` is its image subset);
  a png, jpeg, gif or webp keeps the image path above (thumbnail, flat random name, 20 MB). **An on-screen keyboard's
  image** (its clipboard, image suggestions, stickers, GIFs):
  the keyboard hands the editable a `File` of no type or no name, or only in `clipboardData.items`. A file with no name
  is named `pasted-<time>.<ext>` from its type (`.bin` when the type says nothing); a file of no type that is a png,
  jpeg, gif or webp by its first bytes goes up as an image; and a `beforeinput` whose `File` has no bytes, or no type
  and no real file extension, is left to the browser, whose own `<img>` insertion `liftImage` attaches (a paste event takes every file: the editor cancels a text-less paste itself, so no `<img>` would follow).
  Any other file shows as a
  chip with a generic file icon, its name and its size (the bar and "Uploading 42% of 640 MB" while it goes up, from an
  `XMLHttpRequest`'s progress; "Failed: <reason>" on the chip when it does not), with the same remove button (which
  also stops an upload still going). It goes up as the raw body of `POST /api/upload?name=<its name>` and is
  **streamed to disk** in 1 MB pieces, never held whole in memory: at most **500 MB** (`max_file_upload_bytes`; the
  page refuses a bigger file before sending it), refused with 413 the moment the running size passes the limit, and
  with 507 when it would leave under **2 GB** free (`min_free_bytes`, checked up front and every 64 MB); the folder
  of a refused or broken upload is removed. Stored as `uploads/<32 hex>/<safe name>`: the folder is random per upload
  (names never collide and a name cannot leave its folder), mode 0700, the file 0600, written as `.partial` and
  renamed when whole. The pane gets the file's full path, like an image's (no chip is drawn for it, so send does not wait
  for one: the reply has `imagesPasted` for images and `filesPasted` for the rest). **The safe name** (`safe_upload_name`):
  Unicode NFC; only the part after the last `/` or `\`; control characters dropped; whitespace and every character that
  is not a letter (any script), digit, `.`, `-` or `_` becomes `_`; runs of `_` become one, runs of dots one dot; no
  leading dot; at most 120 characters and 240 bytes, cut from the stem so the extension (up to 20 characters) stays;
  nothing left means `file`. So `a b(c).pdf` is `a_b_c_.pdf` and the path needs no quoting in the pane. `send` takes the
  reference `<hex>/<name>` back only when `valid_file_ref` accepts it (32 lowercase hex, one `/`, a name
  `safe_upload_name` would have made, no `..`) and the resolved path lies inside `uploads/` and is a file. Nothing is
  served back: there is no route that reads `uploads/`. Not verified: behind an access proxy (the *Hosts* setup) a request body may also be capped by the proxy's own plan, so a file over that size is refused at the edge before it reaches the app, whatever `max_file_upload_bytes` says. The folders are deleted after 30 days (their own mtime), a
  half-written one (holding `.partial`) after one day, by the same prune at startup.
- **Images a session sends show inline in its reply.** A session delivers a file to the owner with the `SendUserFile` tool: the transcript holds
  the paths as the call's input (`files`, `caption`), the file stays on disk. The parser gives an assistant `SendUserFile`
  call one `file_image` block for each png, jpeg, gif or webp among its files (the other files stay in the tool call; the
  caption goes with the first image), and the page draws it under the call, visible with the tool folds hidden: lazy
  loaded, at most 480 px wide and 60% of the screen high, a tap opens the full image in a new tab, the caption under it;
  a file that cannot be served shows "Image not available: <name>". The image comes from `GET
  /api/file-image/<sessionId>/<uuid>/<i>/<k>`: the URL names a place in the transcript (the line, the content block, the
  k-th file of the call) and the server reads the path from there, so a request never carries a path and cannot ask for
  a file the session did not send. What it serves (`sentimages.py`, the uploads route's guard turned around): only
  png, jpeg, gif and webp, by extension and by the file's first bytes (the type sent is the sniffed one; svg and
  everything else is refused); at most 15 MB, a regular file; the real path (links resolved) and the path as written
  both inside an allowed root, the home directory or `/tmp/claude-<uid>` (Claude Code's scratch directory, where the
  sessions write most of what they send; `SALA_WEB_IMAGE_ROOTS` replaces the list, colon-separated), with no component
  below the root that starts with a dot (`~/.ssh`, `~/.config`, `~/.claude`, `~/.local/state`) or that names a token,
  secret, credential, password, key or certificate; every refusal is a plain 404. The answer carries
  `X-Content-Type-Options: nosniff` and a sandboxing `Content-Security-Policy`, `Cache-Control: private, max-age=300`.
  Not shown as an image: a path a reply merely mentions in its text (only the markdown form below draws), the files
  of other kinds a session sends, and an image a tool returns (a screenshot, a Read of an image file): that one is the
  tool result's thumbnail inside the call's fold, as before.
- **A markdown image of a file on this machine shows inline in the reply.** An agent shows the owner an image by writing
  it in its reply text as a markdown image whose destination is an absolute path on this machine, or `~/…`:
  `![a short caption](/home/alex/work/mockup.png)` (`<…>` around the path when it holds a space). The page draws the
  image at that spot in the reply, lazy loaded, at most 480 px wide and 60% of the screen high and never wider than the
  column (no sideways scroll at 390 px), a tap opens the full image in a new tab, the caption (the text in the
  brackets) under it. Only that form draws: a bare path, a relative path (`shots/a.png`), a link (`[x](/p.png)`),
  and an image in a code block or code span stay text; `http(s)` and `data:` images load from their URL as before; an
  image inside a tool call stays in the call, hidden with the tool calls. The parser gives each local image of an
  assistant text block a URL, `GET /api/md-image/<sessionId>/<uuid>/<i>/<n>` (the line, the text block, the n-th local
  image of that text, counted by `sentimages.md_image_paths`); the server reads the reply's text from the transcript,
  takes the n-th path from it, and serves it with the rules of a sent file above (png, jpeg, gif and webp by extension
  and first bytes, never svg; 15 MB; inside the home directory or `/tmp/claude-<uid>`; nothing under a dot-folder or a
  secret-named one; links resolved before the check). A request carries no path, so a crafted URL reaches no file a
  reply did not name in an image of its own text; a user's text and a narration line name none. When the server
  refuses the file or cannot find it (a 404 whose `error` says why: "file not found", "inside a hidden or secret-named
  folder", "outside the folders that can be shown", "not a png, jpeg, gif or webp image", "file too large"), the reply
  shows one muted line, "image not shown: <reason>", where the image would be, with the caption under it; there is no
  broken-image icon. The refusal text is for this route only; `/api/file-image` still answers a plain 404.

## The composer

The composer is CodeMirror 6, configured as a plain-text box with
drawn list markers. `index.html` holds only its mount (`#composer-editor`); `app.js` (the composer section) makes the editor
there from `static/vendor/cm6-composer.min.js`, a bundle built from `web/vendor-src/cm6-composer` (*The bundle* below); its
editable, CodeMirror's `.cm-content`, carries the id `#input`. What the keys do and how a list looks is `entry.js` in that
directory; `app.js` wires the editor to the page (the send, the draft, the placeholder, the images). `getText`, `setText`,
`selectionOf`, `selectOffsets` and `focusEnd` are the textarea's value and selection API for the rest of `app.js`; **the
document is the text that is sent, byte for byte** (`getText()` is `state.doc.toString()`): the dot and the indent of a list
are drawn, never typed, so `- item` is sent as `- item` and `1. item` as `1. item`.

The editable is a `contenteditable="true"`, not a textarea, and not `plaintext-only`. Why: a phone keyboard offers its image
insertion (a keyboard's clipboard chips and GIFs go through Android's `InputConnection.commitContent`) only to an editor that
declares image MIME types, and Chrome on Android declares them for a contenteditable, not for a textarea; with the textarea,
a phone pasted text from the keyboard but no image. Two things keep that as it was with CodeMirror:
the bundle sets `EditorView.EDIT_CONTEXT = false` (on Android CodeMirror 6.43 would otherwise hand the keyboard to the browser's
EditContext API in place of the contenteditable), and `style.css` sets `-webkit-user-modify: read-write` on `#input` (CodeMirror
styles its editable `read-write-plaintext-only`, which Chrome treats as not richly editable, and refuses an `<img>` in). The
wrapped lines are CodeMirror's (`white-space: break-spaces`, `overflow-wrap: anywhere`), 22 px a line with 4 px above and below,
growing to 40vh and scrolling past it, in the app's colour variables (light and dark follow the app).

- **Lists**. A line is a list line when it is optional leading spaces, then `- `, `* ` or digits
  and `. ` (`LIST_RE`). The marker, indent included, is drawn as a widget in place of those characters: a round dot for
  `- ` and `* ` (it is a disc the theme draws in the
  muted colour, half the text's size across and centred on the lowercase letters, not a font's `•`, which came out about
  4 px at 15 px; the `•` stays in the widget as unpainted text), the number (`1.`, styled apart from the text, digits
  aligned) for `1. `, a slight indent for the dot, two spaces of indent one level deeper, and the item's wrapped lines
  hanging under its text, not under the dot. The marker is an atomic range: the arrow keys skip it whole, a tap on it puts
  the caret at the item's text, a selection may not end inside it. **The caret never rests before the marker or in it**
  (`- ` still becomes
  a bullet): a caret (an empty selection) at a list line's start, or anywhere in its marker, indent included, is put at
  the marker's end, the item's text. A transaction filter does it for every way a caret gets there: a tap or click at,
  before or on the dot, Home, ArrowUp and ArrowDown onto the line, ArrowRight from the end of the line above, a
  programmatic selection, an edit that makes the marker around the caret. ArrowLeft (and Ctrl+Left) with the caret at the
  item's text goes on to the end of the line above, as from any line's start, since the text's start is the line's start
  for the caret; Ctrl+Up from there goes to the line above too. **A selection never takes
  a bullet with its ends** (Shift+Home used to select the bullet): a
  range's start at a list line's start, or in its marker, is put at the item's text (Shift+Home, Shift+Left, Shift+Up, a
  drag that begins on the dot), and its end inside a marker is put at the line's start, before the dot (Shift+Down, a drag
  that ends on the dot); Shift+Left with the head at the item's text goes on to the end of the line above. Select All
  (anchor at the start, head at the end) is the one range that keeps the first `- `. The document is
  not touched by any of it: `- item` is sent as `- item`. **Backspace** with the caret at the start of an item's text (right after the marker) takes the marker and
  its indent away and leaves the text, plain: the line is visibly out of the list (no dot, no hanging indent, the text at the
  left edge); anywhere else Backspace is the editor's own, so the next one deletes a character. Typing `- ` at a line's start
  makes the dot at once.
- **Tab and Shift+Tab** (Tab indents rather than moving the focus on, to the send button for
  one). Tab puts two spaces at the caret, in place of a selection. On a list line, or with a selection across lines, it
  indents the line(s) instead: two spaces at the start of every line the selection touches (a selection ending at a line's
  start leaves that line out), the caret and the selection staying on their text (a range end at the start of a list line stays
  before its marker, since the indent is drawn with the marker); Shift+Tab takes up to two leading spaces off those lines,
  and with none to take nothing happens, the key still taken. The key that makes a new line (Shift+Enter; Enter itself in
  touch mode) on a list line continues it: the same indent and the next marker (`- ` and `* ` as they are, a number counting
  up, the items below not renumbered), the text after the caret moved behind it, a selection within the line replaced; on an
  empty item it ends the list, the marker and its indent gone and the line left empty; a selection across lines, or a range from
  the line's start, is a plain break. Escape then Tab leaves the box (CodeMirror's tab-focus mode, armed for two seconds by
  Escape; the next Tab is the browser's, the focus moving on); any other key, or the focus coming back, arms the editor's Tab
  again. Ctrl+Left/Right cross a line break instead of stopping at it (otherwise the editor's word moves), Ctrl+Up/Down jump a
  line; Shift extends. Every edit is one dispatch (one undo step, `userEvent` set); Ctrl+Z and Ctrl+Y are the editor's.
- **Text in**: a paste or a drop of text is the editor's own, plain text only (it reads `text/plain`, never the HTML flavour), in
  one undo step; formatting commands (`beforeinput` of the `format*` kinds, `insertLink`) are refused. A line break that arrives as
  an insertion with no Enter key before it (`insertLineBreak` or `insertParagraph` from a script, or an IME that commits `"\n"` as
  text) is the new-line command's on a desktop browser: the browser's own break would be read back as two lines. On Android and
  iOS it is left to CodeMirror, which turns the keyboard's Enter into the key press itself.
- **Images in**, all feeding `addImage` like the attach button, through `EditorView.domEventHandlers` that run ahead of the
  editor's own (and, returning true, cancel them; without that an image-only paste would replace the selection with nothing, and
  a dropped file would be read as text): files in a `paste` event; files in a `beforeinput` (`insertFromPaste`, `insertFromDrop`,
  `insertReplacementText` with a `DataTransfer`), for an insertion that comes without a paste event; files in a `drop` on the
  editor (the window's drop handler attaches them); and an `<img>` the browser put into the editable itself (its own paste of a
  bitmap, a keyboard's insertion), which a mutation observer lifts out (`fetch` of its `src` to a file) and removes, with the
  `<div>` it came in. That observer is made, and watches `#composer-editor`, before the editor exists: observers are called in
  the order they were made, so it removes the node before CodeMirror's own observer reads it as a new line of text.
  CodeMirror's own `<img class="cm-widgetBuffer">` beside a widget is not an image. The links are the links of one chain
  (Chromium runs them in that order for one paste, and the link that takes the files cancels the rest), so a later link skips the
  bytes an earlier one attached within the second: one gesture, one chip. A paste takes its images from `clipboardData.files`
  and reads `.items` only when files is empty (*What it can and cannot do*).
- **Enter**: on a desktop Enter sends and Shift+Enter is a new line. In touch mode, a phone or a tablet typing on its on-screen
  keyboard (the media query `(pointer: coarse) and (hover: none)`, read at each key), Enter is a new line and only the Send
  button or Ctrl/Cmd+Enter sends, as in the Claude app: an on-screen keyboard has no Shift to hold with Enter. On Chrome on Android CodeMirror holds an Enter or Backspace key event
  back for a moment and then runs its key bindings with it (or with the DOM change it caused), which is how the touch-mode Enter
  reaches the new-line command there. A keyboard attached to a tablet keeps Shift+Enter and Ctrl/Cmd+Enter. Android in desktop
  mode (desktop windowing) reports a fine pointer with hover and gets the desktop rule; a phone or tablet with a mouse or
  keyboard attached stays in touch mode, since Chromium keeps the touchscreen its primary pointer there
  (`ui/base/pointer/pointer_device_android.cc`). The placeholder (the bundle's own, not CodeMirror's `placeholder()` widget; *The placeholder* below;
  changed with the media queries through a compartment, and `aria-placeholder` with it) says which: "Enter sends, Shift+Enter for a new line" on a desktop, "Enter adds a
  line, tap Send" on a wide touch screen, the short "Message the session" on a phone.
- **Never during an IME composition**: a key with `keyCode` 229 (the legacy code of a key an IME is processing; Chrome on Android
  wraps every composition in such a key) or `isComposing`, or any key between `compositionstart` and `compositionend`, runs none of
  the composer's commands, and none of CodeMirror's own standard ones either (all of the keymap is behind the same guard): the
  browser commits the composed text and breaks the line itself, once, and CodeMirror reads the result. A composition inside a list
  item keeps its marker drawn, and Backspace of the IME at the item's start does not leave the list. The draft per session in
  `localStorage` (*Back*) is the document. `setText` replaces the editor's state (`setState`): no change event (callers refresh
  the send button themselves, as before), the caret at the end, and the undo history starts over, so Ctrl+Z after a send or a
  switch cannot bring back a sent message or another session's text.

What the headless tests cannot show is the phone itself: whether Chrome on the phone advertises image types for this editable
and how its keyboard delivers the image (a paste event, a `beforeinput`, or an `<img>`: all three are handled, each exercised
here with a synthetic event or DOM insertion), whether CodeMirror's Enter and Backspace handling on Chrome on Android (without
EditContext) and its composition handling for a CJK IME behave as they do under DevTools' `Input.imeSetComposition`, and
whether the keyboard finishes a composition before an Enter. `tests/test_composer_editable.py` holds the editable to the
textarea's behaviour (the send payload byte for byte, the placeholder, the draft across a reload, a composition, Ctrl+arrows, each
image path, the contenteditable and its read-write modify); `tests/test_composer_lists.py` holds Tab, Shift+Tab and the list
continuation to the rules above (the text and the caret after each key, the focus, Escape then Tab, the payload with its indents
and markers, undo, the draft, the modifier and composition guards), on a desktop and in touch mode; `tests/test_composer_touch.py`
holds Enter in both modes and the placeholder; `tests/test_composer_caret.py` holds the empty composer's caret and the
placeholder's place (*The placeholder* below); `tests/test_composer_cm6.py` holds the bundle (vendored, pinned, loaded before
`app.js`, nothing else loaded), the drawn markers (the bullet's disc measured from a screenshot: size against the text and
against the old glyph, centred on the letters, both themes), the caret rules (at, before and in the marker; Home, the arrows,
Ctrl+arrows, a tap, a programmatic move), Backspace, a composition in a list item (also from the line's start), an image
paste and a file drop on the editor, the history after a send, and the look at 320, 390 and 1280 px in both themes.

### The placeholder

The empty composer's placeholder is a `<div class="cm-placeholder">` of the bundle's own (`placeholderPlugin` in `entry.js`),
a child of the editor's box beside the scroller and **not inside the contenteditable**, drawn over the empty line (absolutely
placed, one line, an ellipsis for a text longer than the row, no pointer events), and in the DOM only while the document is
empty and no composition is under way (it goes at `compositionstart`, comes back at `compositionend`). It replaces CodeMirror's
`placeholder()` extension, whose widget is a non-editable `<span>` inside the empty line: the line then has three places for the
caret (before the span, after it, before the `<br>`), a tap past the text's middle puts the browser's own caret after the span,
CodeMirror leaves it there since all three are document offset 0, and the caret and Android's handle are drawn at the end of
"Message the session". With the placeholder out of the line, the empty line is a lone `<br>` and the caret has one place, the
line's start. (Measured in headless Chromium: the caret of a DOM selection after the span was painted 140 px along; taking the
span out of the flow with CSS was no cure, since Chromium then paints no caret at all beside a non-editable span.) The phone's
own tap and handle cannot be driven here; `tests/test_composer_caret.py` finds the caret in a screenshot for each place the
selection can be, and checks the placeholder's place, its ellipsis at 360 px and its going with a composition.

### The bundle

`static/vendor/cm6-composer.min.js` is CodeMirror 6 (`@codemirror/state` 6.7.6, `view` 6.43.13, `commands` 6.11.1, with
`@codemirror/language` and the lezer packages that `commands` pulls in) and `entry.js`, as one classic script with the global
`cm6Composer` (`createEditor`, `resetDoc`, `setPlaceholder`, `EditorView`, `EditorState`, `EditorSelection`, `LIST_RE`,
`versions`). The repo has no npm build, so it is built in a scratch directory and the output committed, the way `marked.min.js`
and `purify.min.js` are vendored, with no CDN at runtime. The recipe, the pinned versions, the lockfile, the license and how to
rebuild are in `web/vendor-src/cm6-composer/README.md`; a change to `entry.js` or to a version is a rebuild and a commit of the
bundle with it. It is MIT; CodeMirror needs no other file at runtime (its styles are injected by the script).

### Timing

Temporary: a load that is slow on a phone while the server answers every request in milliseconds needs to be seen from the
page. So `app.js` leaves a `performance.mark()` at each step of a load (`perfMark`, first thing in
the file): `app.js start`, `init`, `sessions:request`, `sessions:response`, `sessions:rendered`, `sessions:painted`,
`restore`, `select`, `stream:open`, `stream:opened`, `stream:first-event`, `stream:reset` (count, bytes),
`history:rendered` (count, bytes, ms), `history:painted`, `stream:append`, `version` (the server's and the page's),
`reload` with its cause (`auto`, `banner`, `menu`, `overview`), `sessions:error`, `fetch:retry`, `fetch:error`,
`stream:error`, `sw:registered`, `sw:statechange`, `sw:updatefound`, `sw:controllerchange`. A mark costs microseconds,
stays in the page, and nothing reads it unless the flag is on.

- **Enable** by opening `https://sala.example.com/?debug=timing` (your sala address) once in the browser (on the phone: in Chrome, then
  the installed app keeps it: the flag is `localStorage` `sala.debug.timing`); `?debug=off` clears it. With the flag the
  block at the top of `app.js` loads `static/timing-debug.js`, which posts to `POST /api/debug/timing`: the marks with
  their details; a `hello` (the browser, short; standalone or not; whether the worker controls the page; the build; the
  navigation timing: type `navigate`, `reload` or `back_forward`, redirects, response start, DOMContentLoaded, load);
  the resource timing of the page's own files and API calls (duration, time to first byte, bytes transferred, 0 for
  the cache, the status, how long the worker took before the request went out); long tasks (over 50 ms);
  visibility changes, `pageshow` (from the back/forward cache or not), `pagehide`, online/offline; errors thrown
  (message and place); the viewports (`viewport`, for the composer cut off under the screen's edge, see *The screen's
  height*: the visual viewport's height, offset and scale, `innerHeight`, `clientHeight`, a measured `100dvh`, `#app`'s
  height and the `--app-h` set, the composer's box with its row's and the model line's bottoms, its bottom padding,
  whether the composer has the focus; at start, on a resize of the visual viewport or the window, a scroll of the
  visual viewport, the composer's focus or blur, and once settled; only when a value changed). Every record carries the
  page load's id (new each load), the client's id (kept in
  `localStorage`) and the ms offset from the navigation's start. Batched for 300 ms, sent with `fetch keepalive`,
  with `sendBeacon` at `pagehide`; at most 1000 records a load; never a message's text or anything typed.
- **Read** over the socket:
  `curl --unix-socket "$XDG_RUNTIME_DIR/sala-web/sala-web.sock" 'http://x/api/debug/timing?n=500'` gives one line a
  record, `HH:MM:SS.mmm load client +ms name k=v …` (the time in the `SALA_TZ` zone, the server's; `+ms` the page's offset), the last
  200 by default, up to 2000; `?raw=1` the JSON lines. The log is `$XDG_STATE_HOME/sala-web/timing-debug.log`
  (`debuglog.py`: mode 0600, rotates past 2 MB to `.1`).
- **What it shows next time:** where a load's time went, as gaps between one load's marks (navigation start →
  `app.js start`: the files; `sessions:request` → `response`: the API; `response` → `sessions:painted`: the sidebar;
  `stream:open` → `stream:reset`: the history's download; `reset` → `history:rendered` → `history:painted`: the render,
  with its `longtask` lines); every reload with its cause (`reload cause=banner`, the update banner's button; `auto`, a
  hidden tab's; `menu`; `overview`), so a loop or a tap storm reads from the log; `hello nav.type` and `redirects`
  and a `resource … status=` other than 200 (a proxy redirect or a 5xx on the phone's path); `sessions:error` and
  `fetch:retry` (a request that failed or was retried); the `sw:*` lines (whether the worker held the load).
- **Measure** without a phone: `uv run --frozen python tools/measure_load.py` (in `web/`) serves a fleet of fake
  sessions and a 200-message transcript of a few hundred KB (`tests/bigfixture.py`) to a headless Chromium with 6x CPU
  throttling and a slow-4G network (`--cpu`, `--rtt`, `--down`, `--messages`, `--bytes`, `--runs`, `--json`), once
  cold and once reloaded under the worker, and prints the marks, the resources, the long tasks and the CPU profile.
  A trace put the render's time in style and layout of the thousands of nodes
  the messages make (forced by the scroll to the bottom), in a second layout of everything when the web fonts arrive,
  and in building the nodes (markdown, sanitizing, one `innerHTML` parse per copy button, a rescan of the chat for
  each message's place). The render builds a reset's messages in a fragment and swaps them in at once, pairs a
  result with its call through the fragment's own map, clones the copy icon and appends the sanitized markdown as
  nodes (the same tree as a one-shot parse: `tests/test_timing_debug.py` checks it on the long transcript).
- **Remove** when the slow load is understood: the block at the top of `app.js` and its `perfMark(` calls
  (`reloadPage(cause)` can keep its argument), `static/timing-debug.js`, `timingdebug.py` with its entry in `app.py`'s
  `debug_logs`, `tests/test_timing_debug.py` (the render checks in it are worth keeping), this section and the row
  under *API*; `tests/bigfixture.py` and `tools/measure_load.py` stay as the render's fixture and tool;
  `debuglog.py`, the `/api/debug/<kind>` routes and `debug_logs` go too when this is the last debug log; the log file goes with `~/.local/state/sala-web/timing-debug.log*`.

## Sidebar

Sessions are grouped in two levels. A **scope** is the prefix of a session's name before its first `-` (the fleet names
sessions `<scope>-<project>...`; any other prefix is `other`). The scopes and their order are not built in: they are
`SALA_SCOPES` (space-separated, in the order shown) when it is set and not empty, else the `[project_scopes] order` of stackshot's own file
(`$XDG_CONFIG_HOME/stackshot/stackshot.toml`), else there are none and every session is `other`; `SALA_DEFAULT_SCOPE` (or the
file's `default` when the list came from the file) is the scope the new-session form opens on, else the first. A **project** is a page whose frontmatter `type` is
`project`, and only such a page is a group (the one field every list of projects reads). A session's stackshot project (the
page whose `agents:` map lists it) is its group when that page is a project; when it is a sub-page or a note page
(`projects/demo-docs/notes`, `type` not `project`) the session joins the group of its nearest parent by slug prefix that is one
(`projects/demo-docs`); one with no project page on the way sits in `Unregistered`, whatever its map says. The type is read from the
pages checkout (`spawn.page_types`, the files the New session form's list reads, cached 30 s; a new project shows as a group once
its page is in the checkout); where there is no checkout to read, the groups are the projects stackshot's roles name, unfiltered.
A group's scope is the scope most of its sessions carry, a tie going to the first in role order (the front's). A project's title is its slug without the folder (`projects/`, `infra/`) and without its scope's
prefix (`projects/work-docs` under work shows as `docs`); the full slug is the tooltip. Sessions with no project sit
in `Unregistered`, last and not split by scope. **A quick (side) session is grouped by its side record**: it is on no project's agents map, so stackshot's roles give it no project, and sala-web reads sala's record
of it (`$SALA_STATE_DIR/side/<name>.side`, `side_records` in `sessions.py`, under `SALA_WEB_SALA_STATE`). A fork sits in the group its
origin has now (the origin's own project; for a fork of a fork, up the chain; else the project the record kept), a discuss session in
the project of its item, and both after the project's agents, with no role. No record, or one that leads to no project (the origin is
on no page, a loop): `Unregistered` as before. The sessions payload and the overview carry the grouped `project`; a side session's
entry also carries `side` (`kind`, `origin`, `item`). Both levels fold on a click (a folded header shows a busy dot when a
session inside is busy, and the open session stays visible) and reorder by dragging their header. **Sessions reorder by
dragging their row, inside their own project only** (the order is the user's own; the page sorts nothing by itself, a
`-main` is not put first): the same pointer-event mechanism as the headers (a mouse or a pen; a touch is the link), a line marks
where the row will land, a drop over another project's rows ends at the end of its own, and a drag does not open the session. The
order, the folds and the sessions' order are saved in the prefs.

A row has a **⋯** at its end, left of the unread count, which stays at the far right whether the ⋯ shows or not (shown on hover or focus, and on the open session's row; on a touch screen only on the open one)
whose menu holds **Fork**: a link to `#side=from:<name>` that opens the Quick session form with the fork of that session filled
in (*Quick sessions* below). It is in the row's menu and not in the session header, whose fold is measured to the pixel. It is
offered for a session with a tmux pane (`tmuxSession`) and not on the sdk lane (no pane to take a conversation from); a quick
session can be forked too, as `lib/spawn.sh` allows.

The row carries no board count, and neither do the session header and the Overview (*Board items* below).

**The unread reply count**: a front
agent's row carries a filled accent (orange) count of the replies it has written since the owner last opened it, at the
row's far right (after the ⋯ when that shows). Each turn that ends in a reply adds one; a turn still running does not count
yet. Above 9 it reads **9+**. A folded project or scope header carries the total of the sessions inside it (9+ above 9
there too). The open session never has one, and background agents never get one, nor does a session with no project or a
quick session (only stackshot's role `front` counts). The pill is 18 px tall, at least 20 px wide, 11 px type at weight
600, `--accent-text` on `--accent` (white on the light orange, the dark panel colour on the dark one, 5.7:1 and 6.5:1); its `aria-label` reads "3 unread replies in <session>" ("More than 9 unread replies in ..."
above 9). The server decides, so the phone and the desktop agree (`unread.py`): `unread_count` is the number of replies in
the session's transcript newer than its read marker. A reply is the text of a turn that ended (`transcript._ends_turn`): a
main-thread assistant line with text whose message is not followed by a tool call (`stop_reason` is not `tool_use`), so the
narration a turn writes between tool calls is not one. While the session is not `idle` (`busy`, or waiting on an answer,
`waiting`) only a line that says it ended counts, so the text being written at this moment is left out and the replies
of turns that already ended stay counted; an idle session counts a line with no `stop_reason` too (older transcripts). The
scan reads the transcript from its tail, newest first, and stops at the first reply that is not newer than the marker, so a
current reader costs one 256 KB read; it widens the window 4x at a time (up to 16 MB) only while every reply seen is still
newer, and **stops at 10** (`transcript.REPLY_COUNT_MAX`): `unread_count` is at most 10, meaning "10 or more", and the page
shows 9+ for it. The count is a floor, never an exact number, for a reader so far behind that 10 replies lie past 16 MB of tool
output. The markers are `{"<session name>": {"read": <epoch ms>, "seen": <epoch ms>}}` in
`$XDG_STATE_HOME/sala-web/read-state.json` (`Settings.state_dir/read-state.json`, written atomically like the prefs; an entry
not seen for 30 days is dropped). A session with no marker yet is on first sight and counts as read, so a deploy floods
nothing. Opening a session, and any reply that lands while it is open and the page is in view, sends `POST /api/read`
`{"name"}`: the server moves the marker up to the session's latest reply (any text line of the main thread), taking the time
from the transcript and never moving it down, so the count clears when the session is opened and a reply arriving while it is
open never counts. The polled list (10 s) carries `unread_count` (an integer) and `unread` (`unread_count > 0`) on every
session, so a count on a session you are not in can take up to 10 s to appear, and one that another device just cleared
goes away on this device at its next poll, or when the page comes back into view. Opening or leaving a session posts even
when the page's last poll showed it read, since a reply may have landed since. `tests/test_unread_count.py`

**The Unread entry** sits under Overview (`#side-unread`, a button: a filter icon, "Unread" and the count pill). The pill is the total of the counts the
rows show (the same `unread_count`, so the open session's replies and every background agent's are not in it; above 9 it reads 9+; none at zero).
A tap turns **Unread only** on and the entry reads "Unread only" and takes the selected look (`aria-pressed` carries the state); a second tap turns it off. The
drawer stays open on a phone: the entry opens no page. While it is on, the list holds only the agents with an unread reply, under their project
and scope headings, and these rules apply:

- **The open agent stays** in the list until the owner leaves it, though opening it read its replies (without that its row would vanish under the pointer). It shows no count.
- **Headings read as open**: a folded project or scope is drawn open so an unread reply is never behind a fold. The saved folds (`collapsed`) are not changed (a tap
  on a heading does nothing while the filter is on), so each one comes back when the filter is turned off.
- **Background agents never show**, even with "Show all sessions" on, because they never have a count (an open one stays, like any open agent).
- **Nothing unread** reads "Nothing unread" in the list (under the open agent's row, when one is open).

The on/off is the pref `unreadOnly` (*Preferences*, below), kept on the server like "Show all sessions", so the phone and the desktop agree and a reload keeps it. The rules are
pure functions in `shared.js` (`unreadOfSession`, `unreadTotal`, `unreadKept`, between the `<unread-words>` markers) that `app.js` calls and
`tests/test_unread_filter.py` runs in node; the same file drives a headless Chromium over `/`, at a phone's and a desktop's width.

Above the list, **Overview** opens in the main area in place of a session (`#sessions`; a session is
`#s=<name>`; what Back, Forward and a reload do with them is under *Back*): every live session's project, role, status, model and lane
in a sortable table, each account lane's usage limits and one **API (metered)** card above it: what the API key
spent today and this month in the `SALA_TZ` zone (the metered and sdk lanes bill the same key, so one figure for both), the latest
hours labelled as estimated (the Billing link is on the API lane's details page, not on the card). The cards are drawn in one pass from `api/quota` and `api/credit`
together, with same-size placeholders before the first answer, so none lands late; both endpoints answer at once
from their last good answer and refresh in the background (see below). A lane whose check fails keeps its numbers:
the card says so in a quiet line under its figures (the muted colour, not red) with the numbers' time and the next try,
in plain words ("Anthropic is limiting usage checks; numbers as of 1:18 PM · next try 2:05 PM"; "Usage check failed;
…"; a sign-in problem as the server words it), and the server backs off per lane instead of asking again every minute
(`/api/quota` in the table below). The line is red only when there is nothing saved to show. A lane that sala's dormant record lists (`lane-state.tsv` in sala's state directory, read-only here) keeps its card head (the lane pill, the API card its two pills; the plan name, read from the lane's sign-in file, or `API (metered)`, is on the lane's details page only) with **one line** under it instead of the bars, `No seat since Mon Jan 5th` (the reason as a sentence and the day, no "Dormant" in the line), and a status pill left of `Details ›` on every lane card, drawn in the lane label's own style with its words in lower case: `active` (green), `dormant` (grey), `not configured` (grey outline, restyled), and nothing is asked for it; the New session form leaves it out. **That is the account lanes (subscription-1, subscription-2).** A per-use lane (the API card, aws-platform, bedrock) keeps its figures when it is dormant: its card is the active one (Spent today and This month for the API key, This month and the estimate line for aws-platform and bedrock, `$0.00` when nothing was spent), with the `dormant` pill and the reason line (`No credit on the API key since Mon Jan 5th`) under the head. The aws-platform and bedrock figures are counted from this machine's own transcripts and need no call; the API figure is the same Admin API cost-report read as when active (the admin key, which is not the inference key that has no credit), kept at one read per 15 minutes. If that read fails and nothing is saved, the card says the reason, the error in plain words and `Usage unavailable`, never a blank; a usage check that Anthropic answers with 403 is saved as `errorKind: refused`, which sala's watch reads as the subscription-2 signal. It polls `api/overview`, `api/quota` and
`api/credit` (every 15 minutes, its cache age) only while it is shown; a session name in the table opens that session,
and the same red count as the sidebar's sits after the name of a session with an item waiting on the owner (only that
case: the table is for finding what needs the owner). The header's Reload and ⋯ menu are hidden there, so the overview's head carries two chips of its own: **Reload** (the
same reload as the header's icon, which keeps the composer's draft) and **Get Help**, which opens the session named by `SALA_HELP_SESSION`
(the session that looks after the web UI; with none set the chip is not shown).
`/sessions`, where the overview used to be its own page, redirects to `/#sessions`.

**The lane cards drag into the order the owner wants.** Each card on the Overview has a
handle (`⋮⋮`) at the left end of its head. Drag it with a mouse, a finger or a pen and the card takes the place of the card under the pointer; or
focus the handle and press the arrow keys (left or up one place earlier, right or down one later; the handle keeps the focus). The order is saved
when the drag is let go, in `api/prefs` as **`laneOrder`** (lane ids: `subscription-1`, `subscription-2`, `api`, `aws-platform`, `bedrock`; the API card is `api`), so it
follows the owner across browsers like the sidebar's order. The cards of a draw are never swapped under a drag (an answer that
lands meanwhile is drawn when the card is let go), a cancelled drag puts the card back, and a drag does not open anything: only the handle starts it,
and the card's own links (`Details ›`, a session name, `and 3 more ›`) work as before. With nothing saved the order is the default one (active lanes,
then dormant, then not configured; inside a group subscription-1, subscription-2, api, aws-platform, bedrock). **Once an order is saved it rules, whatever
a lane's state is**: a lane that goes dormant stays where the owner put it (its chip says dormant). A lane that is not in the saved order (a new one)
comes after the listed ones, in the default order; an id in it with no card now is ignored (it stays in the list in case the lane returns, at most
20 of them). The lane's details page has no handle. `tests/test_overview_card_drag.py`.

There is no standing line under the cards. The `#q-note` line is empty and hidden, and says something only when the account usage cannot be loaded ("Could not load the account usage (…); retrying.").
The API card still says what it is: its figures are spend, and a lane with no quota has no bars.

**Every card ends with its updated line.**
A card is its head, its figures or bars (the API and AWS cards' estimate line included), then its notes, then **one muted line, `updated 7 min ago`**, the card's last child
(`c-updated`; `updatedFoot` in `sessions.js`). The notes are every loose line the card has: the "not counted" warnings, the dormant reason (`No credit on the API key since
Mon Jan 5th`), an error or the soft "numbers as of … · next try …" line. They sit under the figures, not under the head, and
the cards of a row share one height, so the closing lines sit at the bottom of each card on one level (`pinEnd`, the `q-end` class: the first of them
takes the free room above it). The head, the status pill and `Details ›` are as before. The time is the answer's own **`fetchedAt`**, the moment of the card's
last **good** reading (the swr cache stamps it on a good refresh and keeps it while refreshes fail, so a failing check shows the last good
time, never the time of the failed try): subscription-1 and subscription-2 from `api/quota`, the API card from `api/credit`, the AWS cards from `api/spend`. A dormant
subscription-1 or subscription-2 lane is asked nothing, so its answer carries the `fetchedAt` of its saved answer (`state_dir/quota-<lane>.json`, kept across restarts) beside the dormant record; a lane that
never answered has none, and its card says **`updated unknown`**, never a time of the page's own. The words are relative (`just now`, `7 min ago`, `3 hours ago`, `2 days ago`;
`relTime` in `shared.js`, which the chat's message stamps also use), turn to **`as of 3 hours ago`** when the answer is older than its card's stale mark
(10 minutes for subscription-1 and subscription-2, 20 for the API card, 15 for the AWS cards: its refreshes are failing), and the exact time in the `SALA_TZ` zone is the line's tooltip. They are
rewritten by the same 30-second tick that ages the chat's stamps (`app.js`), so a card left open never reads `7 min ago` an hour later. A card still waiting for its first answer holds the
line's place, empty. The line also ends the cards on a lane's details page. Tests: `test_card_updated_line.py`.

**The AWS lanes' spend cards.** After the API card come two more, **aws
platform** (Claude Platform on AWS, the `aws-platform` lane) and **bedrock** (every lane label is lower case, like subscription-1, subscription-2 and sdk). Each shows this month's spend as **an
estimate at list prices** (the card says so under the figure: "Estimate at list prices since Thu Jan 1st"; the real bill, the AWS
Console with about two hours' lag or the invoice, can differ), the models (name, dollars, share of the lane),
the sessions on the lane (name linked while it runs, dollars, share; the top five, then "and K more ›" to the lane's page,
which lists all) and when it was counted. The head is the label, the status pill and "Details ›", like the others. There is **no AWS
usage or cost API we can read** for them (the Platform org's Admin API usage and cost endpoints are not available to it;
Cost Explorer has a day's lag and needs a permission of its own), so the figure is **our own count**
(`spend.py`): the usage each assistant reply records in the Claude Code transcripts (`message.usage`: input, output, cache
reads, and the 5-minute and 1-hour cache writes apart) times the model's list price, the same rates and the same rules as the
fleet spend report (a script of a separate repo; the price table is copied, with a pointer): each
message id counted once with the largest value of each field (a streamed reply is several lines; a fork copies history),
subagent transcripts counted with their session, the **UTC calendar month** (the Console resets on the 1st, UTC), a model
without a list price listed on the card as not counted, never as $0. Model ids are normalised (`global.anthropic.claude-opus-5-5-v1:0`
is `claude-opus-5-5`). Only transcripts under `claude_dir/projects` are read, and only the sessions that are or were on an AWS
lane, from files modified since the month began, each read from where the last read stopped (a cache of offsets and the
month's messages in `state_dir/spend-scan.json`); nothing but ids, times, model names and token counts is kept or sent, no prompt, no reply, no tool input.
**Which lane a message was on** is not in the transcript or its folder (both AWS lanes run with the default config directory), so it is worked
out from sala's records: `lanes.log` (the lane a session was put on and when, a rename followed through its aliases,
`(default)` read as the default lane then), the lane of each live claude process this page sees (its environment, from the
time it started; remembered in `state_dir/spend-lanes.json`), and for a session with no record the lane it is on now.
**Known inaccuracies**: a change in `lanes.log` is when the lane was recorded and the session moves at its next relaunch, so the messages in between
(usually minutes) land on the new lane; a session launched by hand on an AWS lane that sala never recorded has all its earlier messages
counted on its current lane; a session `lanes.log` names whose transcript cannot be matched (no registry row, not running) is not counted
and the card says how many; web search and fast-mode surcharges are not priced. A lane that is not set up (the lane table's `status`)
reads "Not configured" and "Not set up on this machine."; a dormant lane keeps its figures, with the `dormant` pill and its reason line under the head; a lane with no usage yet is
Active with $0.00; a count that cannot be made (sala's records unreadable, no transcripts folder) says so on the card in plain
words, with no figure. Before the first count lands the card is quiet (`api/spend` answers `pending`; the first read of a big transcript can take a while and runs in a thread).

**Lane codes and names.** A lane's code is what is stored and sent: `subscription-1`, `subscription-2`, `api`, `bedrock`, `aws-platform` (and `sdk`, which reads as `api`).
Older lane words (`max`, `team`, `awsplatform`) are still read as **aliases on every read** (`lanestate.RENAMED`, `lanestate.norm`
and `renamed` on the server, `laneNorm` in `shared.js`): sala's files written before the rename (`lane-state.tsv`, `lanes.tsv`, `lanes.log`, `spend-lanes.json`), a saved
link (`#lane=max`), a saved `laneOrder`, a form loaded before the change, a schedule's `X-Model-Lane=max` and a saved `quota-max.json` all read as the new code. Nothing stored is
rewritten, and everything this app writes uses the new codes (`quota-subscription-1.json`, a spawn's lane). What a lane is *called* on a page is sala's to say, not this app's:
`GET /api/lane-names` (below) gives each lane's display name, `laneLabel(code)` in `shared.js` draws it in lower case on a pill (api, sdk, aws-platform and bedrock keep their own
words in `LANE_LABEL`), and no display name is written in this package. The CSS has `.lane-subscription-1` and `.lane-subscription-2` (colours `--lane-subscription-1`, `--lane-subscription-2`),
with `.lane-max` and `.lane-team` kept beside them so a page loaded before still draws. Anthropic's own plan words (`subscriptionType`, `PLAN_NAMES` in `quota.py`) are not lane codes and
are not renamed. Tests: `tests/test_lane_subscription_codes.py`.

**A lane's details page.** Each lane card has **Details ›** at the right
end of its head (the dormant ones too), a link to `#lane=<id>` (`subscription-1`, `subscription-2`, `api`; the API card is the api lane, which
the sdk lane's sessions share). The page is a view of the Overview's pane, drawn in place of the cards and the table
while `body` has `lane-open`, and polls what the Overview polls, so its usage and its sessions are the cards' own
answers drawn by the cards' own code and nothing new is asked of Anthropic. It shows, in the header, **Back** (a link to
`#sessions`; in a browser, when the Overview is the entry under the page, the browser's Back instead, so the history does
not grow a second Overview entry) and **Reload**; then
- **Status**: the words are lower case like the status pill (`active`, `dormant`, `not configured`): active, dormant with its reason and the day it began in the `SALA_TZ` zone (`lane-state.tsv`, as the card's one line says it:
  `no seat since Mon Jan 5th`), or not set up (the lane table says so; no session can be put on it), or "not available
  just now" when sala's record could not be read;
- **Record**: the lane's row of sala's lane table, as `sala lane --json` prints it (`lane_fields_tsv` in `lib/common.sh`):
  provider, client, organization, project, billing, payment, plan, account, how it signs in and region; a field the table
  leaves empty is left out. **No file path ever reaches the page**: the API lane's `credential` is
  `key file ~/… + workspace id file ~/…` in the table and reads `Key file + workspace id file` here (`lanes.py` takes
  every path out of every field), and nothing is read from a `.credentials.json` for this page. Usage over time is not
  part of it;
- **Usage**: the lane's card, without its own Details link: limits for subscription-1 and subscription-2, spend and the Billing link for the
  API lane, the month's estimate at list prices with every session for the aws-platform and bedrock lanes, and the dormant
  line for a dormant one (under the figures' head for a per-use lane; alone for subscription-1 and subscription-2). The page's own
  line says "No usage check is made for it, and the New session form does not offer it." for subscription-1 and subscription-2, and only "The New
  session form does not offer it." for a per-use lane, which is still read;
- **Sessions on this lane**: the Overview's rows for the lane, each linked to its session (`#s=<name>`).

A table sala cannot print blanks the Record section only ("The lane record is not available just now.", the reason in a
quiet line above it) and is asked again with the next quota check; the rest of the page stays. `#lane=<unknown>` says
sala's lane table has no such lane. The header and the tab's title read `Lane <name>` (the lane's name as sala says it, lower case: `laneLabel`). The page's own title is the label pill and the lane's name in the labels' words, `bedrock lane`, `aws-platform lane` (`laneLabel`, lower case), never the lane table's capitalised label (`Bedrock`, `Claude Platform on AWS`). **Details ›** on a card is in the plain text colour (`--text`), not the lane's colour; it keeps its hover underline and focus ring. The page is asked for at most as often
as the quota is: when it opens, every minute, and when the tab is shown again.

## The header

The title bar is light. It has a **three-column grid**:
the session name in the middle, centred in the bar, with its status dot and nothing else; and one cluster at the right
end, in this order: the **status badge** (working, or needs input; nothing while the
session is idle), **Reload** as an icon (no word on it; its name and tooltip are "Reload the page"), the **⋯**
button, and the **Shell** button at the right end (*The shell drawer*). Dynamic information is in the bar, where it is seen at a glance; the static facts are not. The name is centred on the **window's** width, not the main
pane's: on a phone, where the toggle and the cluster flank it, and on a desktop, where it stays
put when the sidebar docks or closes (a docked sidebar pulls the title's grid back under it, empty there and click-through).
The cluster never pushes it off-centre; if it does not fit between the sides it is cut with an ellipsis, centred. Only the
sidebar's side gives: on a narrow desktop window the name moves right just far enough to clear the fixed toggle and brand
block (296 px) and never under the cluster (`tests/test_header_layout.py`).

**Under 400 px wide the name is left-aligned.** Centred, it
got only the room between two equal side tracks, about 129 px on a 360 px phone while the bar still had the item count button
(removed, below), which cut a 17-character session name by 2 px and a 20-character one by 28. Below 400 px the title's columns are the toggle's room, the
name's (all that is left) and the cluster's: the name's block starts one gap (8 px) after the sidebar button and runs up
to the cluster, about 234 px for the name on a 360 px phone, and a name that is still too long is cut with an ellipsis against
the cluster, as before. The fold does not change: it is measured on the centred grid (`fold-centred`, set and cleared
inside `nameFits()` in `app.js`, with the class removed in a `finally` so a measure that fails cannot leave the bar centred), so
the same items stay in the bar at every width and the extra room is not given back to Shell, Reload or the badge. From 400 px
up nothing changed: the name stays centred. The phone rule's query is `@media not all and (min-width: 400px)`, the exact
complement of the centred layout's side, not `(max-width: 399px)`: under browser zoom the viewport is fractional in CSS px and
399.01 to 399.99 px matched neither. Its `#title.fold-centred` template is a copy of the base `#title` rule (a custom property
cannot carry it: `--lead` and `--cl` are defined on `#top` and `#title`, not at the root), and a test holds the two equal.

The **⋯ menu** (`#top-tools`, always there, on a desktop and a phone alike) opens when a mouse rests on the ⋯ button
(after about 150 ms) and closes about 300 ms after the pointer has left both the button and the menu (back on either within
that time keeps it). A click on the button while it is open that way **pins** it: it stays open with the pointer gone
(`aria-expanded` true) until a second click on the button, Escape or a click outside; a click before the hover has opened it
opens and pins it. Touch and pen do not hover: a tap opens it and the next tap closes it, as before. The hover and the pin are one
piece of code (`hoverPin` in `app.js`), held by `tests/test_header_hover.py`. The menu holds, top to bottom:

- **Session**: the session's role (`front` or `background`) and its lane as rows, "Role" and "Lane", each badge in its
  colour (front `--call`'s orange, background a violet, each lane its own: `--role-*` and `--lane-*` in `style.css`),
  then the tmux name when it differs from the session's name. No heading and no rows where a session has none of them.
- **View**: **Chat / Terminal** as a segmented control, two real buttons in a group, the open one `aria-pressed="true"`
  (and drawn raised); a click picks the view and closes the menu. Under it the **Thinking & tool calls** toggle, which is
  in the menu at every width.
  The menu follows the ⋯ button in the page, so the keyboard reaches it with Tab from the button.
- what has **folded** out of the bar (below): **Shell** as a row with its icon and word, Reload as a row with
  its word, the status badge as a "Status" row at the end of the Session section.

The name comes first: it is never cut while anything else is still in the bar. On every resize of the header, and
whenever the name, the badge or the fonts change, the page puts everything back into the bar and moves items into the
**⋯** menu one at a time until the name has its full width: **Shell first** (the drawer is also on Ctrl+`, and
the menu row opens and closes it exactly as the button does), then Reload (a desktop browser has its own; the item is
there for the installed app), then the status badge, last because it is the dynamic fact. Nothing is decided by a
breakpoint, so a 60-character name folds more than a short one at the same width. The one element of each item moves
between the bar and the menu, so its listeners go with it (on a desktop window of about 1000 px the session name takes
priority and the icons fold into the menu as on a phone; `tests/test_header_fold.py`).

**No item count button.** The bar once held a button with the session's open board item count, which
opened a sheet listing the items; the Overview's Agents table had the same count in red, opening the same sheet. All three
were removed because open items are read on the board, not on this page (the sheet, its lists and tags, the "For you" section inside it, and the pieces only they used:
`placePopover`, the lists in `static/shared.js`, the history layer of the sheet). The 43 px the button took went to the name and
the fold: on a 360 px phone a short name keeps Shell in the bar and "demo-docs-main" keeps its status badge (`tests/test_header_fold.py`,
`tests/test_header_layout.py`). Reload, the badge and the ⋯ button are hidden in the Overview, where no session is open (the
Overview has its own Reload).

## Board items

The page reads each live session's open stackshot items for one thing: the **New session** form's board item picker, which lists
the open items of the running sessions (`sdItemRows` in `app.js`, one row per item, newest number first, with the owning session in
brackets); any other id can be typed. There is no item count, button or sheet in the session header, the Overview or the sidebar
rows (the sidebar rows show the unread reply count instead, *The unread reply count*); they were removed.
`tests/test_board_items_ui.py` holds that the markup, the page's script and the stylesheets carry none of them, and that the
picker still gets its items.

**Where the data comes from.** `GET /api/board-items` reads stackshot's client API (`GET <server>/client/items?key=<session
name>`, `Authorization: Bearer <token>`, the same read stackshot's `client.py` makes, from `$SALA_STACKSHOT_DIR`, `~/stackshot` unset) once per live session,
at most 4 at a time, through the same serve-stale-while-revalidating cache as `api/quota` and `api/credit`: the page
is answered at once from the last good answer (`pending` with none yet, `refreshing` while a round runs, `partial`
when one session's read failed and its last answer is kept), rounds are at most one a minute, and the answer is kept
in `state_dir/board-items.json` (ids, subjects, needs and the public link only; never the token or the server
address). The token and the server address are read from stackshot's own files (`$XDG_CONFIG_HOME/stackshot/client.token`
and `client.url`, 0600; `STACKSHOT_URL` in the environment wins over the file, as for the client), and the item's page
is `SALA_WEB_STACKSHOT_WEB` + `/items/<n>` (`client.url` is the loopback address, which a phone cannot open): `board#N`
→ `/items/N`, a temporary id as its dashed form, an older `sN` as it is. A missing file, a 401 and an
unreachable server each give a plain `error` ("No stackshot token on this machine.", "stackshot refused this machine's
token (HTTP 401)", "stackshot unreachable (…)") and nothing is retried before 30 s; the page then keeps the items it has.

`board.py` passes through each row's `state` (a short string) and `list` (only when it is `your-move`, `agents` or `waiting`), its
`mover` (`session` | `owner` | `outside`, `who`, and `via` when it waits after another item), the kind of `wait` (`after`, `failed`,
`hold`, `wake`, `recycle`, `due`, `check`, `needs`, `end`, `idle`), `expected_by` (epoch seconds, kept only when positive) and
`overdue`; an absent or malformed field is left out. An item in state `doing` is sent with `wait` `doing`, `expected_by` `null` and
`overdue` `false`, so `board.py` leaves out the kind and the date. No page reads these fields now (the picker uses the id and the
subject); the route keeps sending them as stackshot's interface describes (`docs/stackshot-contracts.md`).

The page polls `api/board-items` once a minute while it is visible (and once on coming back after 5 s hidden), with a
few quick follow-ups while a first answer is still `pending`. Nothing waits for it: the first paint does not, and the picker says
"No open board items of the running sessions are known yet" until the first answer lands. Sessions' names are taken from the live
registry, so a retired pane stops being asked on the next round.

## For you

stackshot's For you list has no page in sala now: it was the first section of the items sheet, which was removed
with the item count button. The server side stays, because it is a stackshot interface and costs nothing idle. `GET /api/for-you`
serves the last good answer at once from a cache of stackshot's `GET /client/for-you`, read at most once a minute in the
background (`foryou.py`, the same serve-stale cache as the board items, kept in memory only: a restart reads it again, `pending`
until it lands). `POST /api/for-you/seen` `{id: <number>|"all"}` and `POST /api/items/<board#N or N>/watch`
`{state: watch|mute|default}` make the call at stackshot with this machine's token and the label `sala-web` (stackshot accepts
the label only on the machine that serves it), put its answer into the cached list at once and return the list as it is now. They have
the same origin, content-type and size checks as the other POSTs, every value is checked here first (a bad one is a 400 and never a
request), and a stackshot refusal comes back as a plain sentence, never a trace; the token and the address never leave
`foryou.py` / `projpick.py`. `foryou.py` is the one module that knows their shapes and `tests/fake_stackshot.py` their stand-in. The
calls are interface 22 of `docs/stackshot-contracts.md`; the test is `tests/test_foryou.py` (the shapes, the server). If a page is
wanted again, it starts from these routes.

## Back

What the browser's Back does. Two modes, chosen at every decision from
the width and the display mode, so a resize or a rotation changes the next action while the entries already made stay
(`app.js`, "selection, hash, history"; `tests/test_back_button.py`):

- **A phone, and the installed app at any width, replace.** A phone is the drawer layout (`max-width: 760px`) in any
  browser; the installed app is `display-mode: standalone`. The sessions and the Overview are peer views of one history
  entry: opening one replaces it, so there is no history between them and Back never walks from one to another. What
  Back does is close the top open layer, and with none open it leaves sala (the installed app exits). A layer is the
  sidebar drawer; one Back closes it. Back on the view with the sidebar open closes the sidebar and does not
  exit. Nothing intercepts the Back that leaves: no `beforeunload`, no entry pushed on launch.
- **A desktop or tablet browser, and a phone wider than 760px, push.** Every view is an entry (the Overview too), so
  Back and Forward walk the sessions visited, as claude.ai and chatgpt.com do in a browser. The sidebar is part of the page
  there and is no layer, so this mode has none.
- **A layer is one pushed entry**, with the same URL and the open layers in `history.state` (`{sala: {layers, idx}}`;
  `"drawer"`; an entry of the items sheet an older page left reads as no layer). Closed another way (the scrim, the close button, Escape), its entry is popped at
  once, so the next Back is not spent on an entry that changes nothing. Escape closes the top layer, one per press.
  Entries are pushed from taps only: Chromium skips entries pushed without a user gesture when the browser's own Back
  button walks the history. A navigation with layers open (a row tapped in the drawer, a link in the page) first goes
  back under them, then replaces or pushes; the popped entries stay ahead as Forward entries, because no API removes
  them without a push, and Forward re-opens their layers over the view that is shown. Widening the window past the drawer pops its entry. The layers are a registry
  (`defineLayer`), so another kind is one more definition; sala has no image viewer (thumbnails open in a new tab).
- **sala opens on the view it was last on** in replace mode, with the sidebar closed: the session last shown if it is
  still live, else the Overview (a `localStorage` key, written on every view). A deep link (`#s=<name>`,
  `#sessions`) wins over it. The view is written to the launch entry, so a reload keeps it. A wide browser (push mode) has no
  last view: with no hash it opens on the Overview, `#sessions` written over the launch entry (`replaceState`, no entry
  added), so Back from it leaves sala as for a `#sessions` deep link.
- **A reload leaves the layers.** The record is kept over a reload, but the page walks back over the entries of the
  layers it had open (a same-document traversal in Chromium) and shows none, so Back then leaves with no dead entry under
  it. An entry of the first build (`depth`, `base`, `overlays`) is read as no layers.
- **The Chat/Terminal toggle touches no history**, and neither does the ⋯ menu, a dropdown a tap outside closes. The
  keyboard going up or down closes no layer.
- **A hash change made outside sala's links** (the address bar, a script) is the browser's own push: that entry is
  taken as it is and recorded. It is not walked back over: an entry without a record is also what an older sala left in
  a tab still open, and a Back onto one of those must show that page. Every in-page link to `#s=<name>` or `#sessions`
  stays a real `<a href>` (Ctrl/Cmd/Shift/middle click open a tab); a plain click on one follows the rules. That holds for
  a link in a reply too: every link there is `target=_blank`, but one to sala's own page and route (a bare
  `#s=<name>`, or the full `https://sala.example.com/#s=<name>`) is taken by sala like the sidebar's, so on a phone the
  installed app does not open Chrome's in-app view; a link to another origin (stackshot, GitHub) or another path still opens
  outside sala. A
  session link whose session is gone says so and carries a link to the Overview.
- **The New session page (`#new`) is a view of its own** (a full page, not a
  pop-up), not a layer: it has a link, so a reload and a shared link open it. Opening it is an entry in either mode (a
  phone too, where the other views replace), so **Back returns to the view it was opened from**, and from the drawer on a
  phone the drawer's own entry is walked back over first, as for any view. Leaving it for another view (a session row, the
  Open button after a create) replaces its entry in replace mode and pushes in push mode. It is not remembered as the last
  view. An entry of an older build that recorded the popover layer (`"new"`) reads as no layers.
- **A lane's details page (`#lane=<id>`) is a view of the Overview**: it follows the same rules, a peer view
  in replace mode (one entry, replaced), an entry of its own in push mode. Its **Back** button returns to the Overview: in
  push mode, when the page was opened from the Overview, it is the browser's Back (the entry under it is the Overview), else
  it is a link that goes to `#sessions` by the rules above. It is not remembered as the last view (a phone reopens on the
  Overview or a session). `tests/test_lane_details.py`.
- **Unsent text is kept per session.** What the owner typed is saved in `localStorage` (one key per session, text only,
  20,000 characters at most) 400 ms after the last keystroke, when the owner leaves the session, and when the page goes; it
  comes back when they return to that session (also after the Overview, a reload or the installed app being closed).
  The box itself is emptied when the owner leaves the session, so a draft is never sent to the session the owner switched to; sending
  or emptying it removes the draft. Attached images are not kept, and they do stay in the composer across a switch (a
  gap, not changed here).

Checked in a headless Chromium against the browser's own history (taps over DevTools `Input` events,
`history.back()` and `forward()`, `Page.getNavigationHistory`, a reload, a sentinel page before sala so that leaving it
can be asserted) at 390 and 1280 px, with the installed app emulated in the page (DevTools has no `display-mode`
feature); not on a phone or in the installed app, where Android's system Back is the same `history.back()` for a
standalone web app.

## New session

The sidebar's first row, above the Overview, is **New session** (a page
of its own, not a pop-up): a link to `#new`, which fills the main
area where the chat sits (the sidebar stays beside it, and its rows work), with the form that starts a project's session.
The page has its own link, so Back returns from it and a reload or a shared link opens it (*Back* above). **It is one
centered column**, about
760 px wide at most and centered in the main area; a phone has the same column at full width with a 16 px gutter. The fields
run top to bottom: scope, project, role, name, mandate, the folded lane, model and effort, Create (with its pending text),
then what Create did (the steps) and the Open button. **The project box is six rows tall** (250 px of 40 px rows, its padding
and border) and scrolls inside itself however many projects the scope has; its lower right corner is a drag handle (CSS
`resize: vertical`, three rows at least, the screen at most; a hint beside the Project label says so on a desktop), and the
height it is dragged to is kept in the browser (`localStorage` `sala.ns.list-h`, whole pixels, written when the drag ends,
read on load; a stored value that is not a number or is under three rows is ignored, one over the screen is cut to it, and a
browser that refuses its storage keeps the default). On a desktop window the rows and fields are laid out so an ordinary
create (pick a scope, pick a project, type the name, Create) needs no scrolling at 1280 x 800; once Create has started, the
foot of the page (Create, the steps, the Open button) is pinned to the bottom edge, so the steps and the link are on the
screen while the fields above scroll under it (a new project's note adds two lines, which scrolls the fields a little before
Create; Create stays in view). A phone scrolls, and its foot is not pinned. A
project's title is shown whole beside its name, wrapped, never cut with an ellipsis or clamped. The form's state (what was
typed, the last result) stays while another view is up, so a create under way is not lost by looking at a session.
The page makes no session itself: a submit is one `sala op spawn` through sala's operation queue, the same path a
session's own `sala op` takes, so `sala-watch` runs it, posts to Slack and sala's rules hold (a name must be on the
project page, the lane must be able to launch, one live session per name). What the form holds:

- **Scope and project**: a scope first
  (the scopes stackshot lists, for example **work**, **home** and **lab**, as chips, and a last chip **all**), then one box. The box lists the scope's *listed*
  projects (stackshot's `GET /client/projects`; every row carries the page's `type`, and the form keeps only the rows whose
  `type` is `project`, the same field the sidebar's groups read: a note page, a sub-page or a page with another type or none
  is not offered, whatever agents or board items it has), each row the
  project's plain **name** and its title: the name is the one the sidebar shows, the page key
  without its folder (`projects/` and the like) and without its scope's prefix (`projects/work-docs` is `docs`,
  `projects/garden` is `garden`); the key is what is sent, and it is never shown (the title is left out when it only repeats the
  name). Typing filters the listed rows at once, here (the key, the name or the title holds the text,
  case-insensitive); once the typing settles stackshot is asked again with the text and sends the scope's *hidden* pages
  that match, which show below a divider, "existing pages, not listed" (`type: project` pages only, as above). A fourth chip, **all** (last), lists every scope's projects together in stackshot's order
  (by key), the hidden matches too; a small muted scope word stands beside a name only where two of the projects known
  share that name. A project of the *all* view is made ready in its own scope. The last row of a scope is
  **+ New project "<typed>"** (the name it would make beneath it: the slug is the typed text in lowercase letters, digits
  and dashes, and the page is `projects/<slug>`); it waits for a name
  to be typed, and gives way to a project that already has that key. Under *all* there is no such row (a project belongs to
  one scope), only the line "pick a scope to make a new project" when the typed text matches nothing. The last scope used,
  *all* included, is remembered; the default is unchanged (the last used, else the open session's, else the default scope). A project
  that stackshot marks retired (`retired: true`, or `status` archived or retired) is not listed. A line under the box
  says what Create will do. The box has a **header row** (Project | Description) over a narrow name column and a wide description
  column (narrower still on a phone). **Once a project is chosen the box folds to one line**, the project's name, its
  description and an arrow; the arrow opens the box again, and choosing another project folds it again, so on a phone the form
  below is in view. A scope switch unfolds it.
  Nothing else is asked of the owner: scope, project, the agent's role and name (and mandate), Create.
- **Role**: `front` (a session the owner talks to; the default) or `back` (a background agent).
- **Name** (-main is suggested only when a new project is created, otherwise a random name such as -pink): sala's suggestion (`sala spawn --suggest-name … --prefix <p>`, asked again when the project or the role changes).
  The prefix is the project's **real** one: its main agent's name without `-main` (`projects/harbor`, listed under lab, whose
  main agent is `harbor-main`, has the prefix `harbor`, not `lab-harbor`), else what its agents' names share, else stackshot's rule for a page's first agent
  (`<scope>-<slug>`, a slug that already starts with `<scope>-` is its own name). The name is `<prefix>-main` only for a front agent
  of a project with **no agent yet** (a new project, or one listed with none); every other name is `<prefix>-<random word>`
  (`lib/spawn.sh`'s word list), and sala never suggests one that is taken (a tmux session, a running claude, an agent on any
  project's map in stackshot's record). The page asks again when the answer is a name it knows to be taken (a running session, an
  agent of a project in the lists it holds) or a `-main` for a project that has agents, and picks a word itself if sala cannot be asked.
  "Create will add <name> to it" names the same name. It stays until the owner edits it; checked as the backend
  checks it (lowercase letters, digits and dashes, no dash at either end, 48 characters at most), the error inline, and a name of a
  running session is refused in the form. **The name field is emptied when the session shows in the list**, so the page never calls its own new session a clash
  (once the session is in the list, "running already" under its name would read as if something had gone wrong). The moment is
  the page seeing the created name in its sessions list or the start reading Ready, whichever comes first, and only while the field
  still holds that name (a different name typed meanwhile stays). The result line and the Open button stay as they are, and Create
  is off for want of a name. Before that moment the field keeps the typed name, because a queued start can still fail: a refused
  create, and a start that ends without the session, leave the name in place and Create usable for the retry. Nothing fills the
  field again by itself (reading the project list again skips the suggestion; picking a project, changing the role or typing in
  the box asks for one on purpose). Typing a name afterwards works as usual, the running-already warning for another running
  session's name included (`nsOwnSeen` in `app.js`; `test_new_session_created_name.py`).
- **Mandate**: a plain textarea, no key of it intercepted (Enter is a new line, Tab leaves the box; an IME's
  keys are its own). Optional for a front agent, required for a back one (nobody briefs a background agent). 20 KB.
- **Lane, model, effort** fold away under *Lane, model, effort*; the first choice of each is **use default (<value>)** with the
  value it resolves to (sala's default lane, `settings.json`'s model and effort; "use default" alone when one cannot be read; the model and effort are read from `~/.claude/settings.json`, so a lane with
  a config directory of its own, the subscription-2 lane, may follow another file and differ from the value shown), and
  none chosen sends nothing, so the session follows the defaults. The model is a selector (opus, sonnet, haiku, fable, and
  *other… (a model id)*, which opens a box for a pinned id such as `claude-opus-5-5`); effort and lane are selectors too. The lanes are the ones a session can be spawned on (`sessions.SPAWN_LANES`: subscription-1, subscription-2,
  api, bedrock, aws-platform; the sdk lane is not spawned; sala refuses a lane that cannot launch yet, e.g. aws-platform
  until its workspace id is set, and the form shows why); the efforts sala's list. A session's lane badge (`proc_lane`, the
  mirror of sala's) reads `CLAUDE_CODE_USE_BEDROCK=1` as bedrock and `CLAUDE_CODE_USE_ANTHROPIC_AWS=1` as aws-platform (Claude
  Platform on AWS, shown "aws-platform"), each in its own colour, ahead of the API key and the config directory.
  The older word `awsplatform` (salamander `lane --migrate` rewrites it) is still read
  here as `aws-platform` in sala's files written before (`lanes.log`, `lanes.tsv`, `lane-state.tsv`, `sessions.json`, the saved
  sightings in `spend-lanes.json`), in a saved link or view (`#lane=awsplatform`), in a spawn payload and in `GET /api/lanes/awsplatform`
  (which answers `"lane": "aws-platform"`); `lanestate.ALIASES`, `spend.canonical`, `spawn.LANE_RENAMED` and the page's `laneNorm`
  (`shared.js`) are the four places. A saved UI setting never embeds the lane name, so none is stranded (checked: `prefs.json` and the
  `localStorage` keys carry none; the saved last view may hold `#lane=awsplatform`, which `laneHashId` reads as the new name).

**Create** does the project's part first, in order, one step shown at a time with its state in words (*working*, *done*,
*failed*; a step that is not needed is not shown, and a retry after a failure goes on from the failed step: the page keeps
what it did, so a page already made is not made again). The button stays disabled from the first step to the last, so a
second tap sends nothing.

1. A **new project**: `POST /api/spawn/project` starts stackshot's `post project` (the project's page from the
   template, then its id, scope and the mark that lists it) as a job; the page asks `GET /api/spawn/project/job?id=` every two
   seconds for up to five and a half minutes, showing "Making the project page, which can take a few minutes (37 s)". It is a
   job, not one long request, because the knowledge base can be slow and the access proxy in front of this app cuts a response off after about 100 s;
   a phone that slept comes back to the same job. 409 (the page exists) says to pick it from the list; 502 (the knowledge base refused)
   says nothing else was recorded and to try again.
2. A **hidden** project: `POST /api/spawn/project-list` lists it again (stackshot's `post project-list`). A *listed* project
   with no agents at all still gets the same call (a harmless renewal of the form's mark, kept from the time stackshot let
   only the label that listed a project add its first agents; stackshot no longer requires it).
3. The **agent**: `POST /api/spawn/project-agent` adds it to the project (stackshot's `post project-agent`: the name, the
   role, `front` true or false, and the mandate's first line, 70 characters, or `front agent of <slug>` when there is none),
   unless the project lists the name already. Every call carries the one label `sala-web`, which the server sets and the page
   cannot. stackshot adds an agent to any listed project, one that has agents already included. It refuses (403) a retired or
   hidden project, and the page says so in words, with stackshot's text; it refuses (409) a name that is taken, by another
   project's agent or by a pending entry from another sender, and the page says to pick another name.
   The line the project's page still owes for the agent stays in stackshot's record (`page_owed`); the answer
   carries it (`pageOwed`, `pageYaml`), and the form tells the owner it is recorded, not to copy it anywhere.
4. The **session**: `POST /api/spawn`, below. If the queue answers *not listed* or *no page* straight after one of the steps
   above, sala has not read stackshot's record yet: the page asks again after 4, 4 and 6 s before it gives up in words.

The old *ADD-TO-PAGE* block and its Copy button are gone from the page; on exit 3 the queue prints a `REGISTER:` line and
stackshot's `post project-agent` command (the queue no longer asks anyone to edit the page's agents map), and the server
passes them on in `block`, but nothing shows it.

The spawn (`POST /api/spawn`, one in flight at a time, the button disabled meanwhile) runs, as an argv list and
never through a shell, `sala op spawn NAME --project <key> --role front|back [--mandate FILE] [--lane L]
[--model M] [--effort E] --from sala-web --words "the owner, via the sala web form: new <role> <name> in <project>,
<HH:MM Www Mon Dth> <zone label>"`. The mandate never goes on the command line: it is written to `state_dir/mandates/
<random>-<name>.md` (0600) and that path is the `--mandate`; the queue passes a readable file as it is and the
session reads it at its first prompt, after the operation has ended, so the file stays (pruned with the uploads
after 30 days); a refused spawn leaves no file. Every field is checked here against the shapes `lib/op.sh` checks,
so a bad one is a 400 and never reaches sala. What the queue answers is shown as it is, as text (never markup):

| sala exits | the page shows |
|---|---|
| 0, `queued op <id>` | *Queued*, then *Starting the session* once the marker says running (`GET /api/spawn/status`), then *Ready* with the Open button (primary style, focused) once its name is in the sessions list (or 30 s after the operation is done), asked every 3 s (every 10 s after five minutes) until the operation ends, not for a fixed time: a start can sit behind other operations in sala's one-at-a-time queue for minutes, and while it is queued the status line says what it waits behind ("Waiting behind 2 retires and 1 rename (running now: retire x)."). A 30-minute cap is the last resort and its words say the start is still queued or running, never that the session is missing; no text of the forms advises reloading the page (the form's state is lost on a reload, and the operation goes on anyway). The steps are a line with the current one named in words and `aria-current="step"`; the seconds so far and a fixed "usually 30 seconds to a minute" (longer when other operations were queued ahead); Start's button says "Starting…" and stays off until ready or failed; the operation id is small text last. A stuck or cancelled operation says in plain words that the session did not start and what to try, with its result line small below; at the cap, a line saying the result comes to Slack |
| 3, the name is not on the project page's agents map | *not queued*, "sala's check does not see <name> on the project yet. Create again in a minute." (asked again 4, 4 and 6 s first when a step above had just changed stackshot's record); no block, no Copy button. sala's own line on the keeper (one stackshot message) is not shown |
| 4, no such page | *not queued*, "sala does not see the page <key> yet. Create again in a minute." |
| 1 or 2, refused | *not queued* and the refusal's lines (stderr and the plan's ✗ lines) |

## Quick sessions

A **quick session** (the page's name for it, since inside sala and in the
API it stays `side`, `fork_of`, `item`, `agents`; sala's `docs/side-sessions.md`) is a short-lived session started
in one step to talk something over: a **fork** of a running session's conversation, or a **fresh** session about a board item,
scoped to the item's project page. It is on no page's agents map, has no role, and retires only on the owner's word, after it ran
`sala side done` (the write-up gate; sala's `retire` refuses it until then). The web UI only starts it, through the same queue as
the New session form: `POST /api/spawn` with `{"side": true, "fork_of": "<agent>"}` (with an optional `"item"`) or `{"side": true, "project": "<key>", "item":
"<id>", "agents"?: "a,b"}`, a blank name meaning the one sala suggests (`sala spawn --suggest-name --side …`, also
`GET /api/spawn/suggest?side=1&fork_of=…|project=…`), which runs `sala op spawn NAME --side [--fork-of AGENT | --project KEY --item
ID] [--agents A,B] [--mandate FILE] --from sala-web --words …`. The words say what it is about: "the owner, via the sala web form: new side
conversation NAME (about board#N in projects/demo-docs), 14:05 Mon Jan 5th UTC". The shapes are checked in `spawn.py` as `lib/op.sh` checks
them (a fork takes no project and no agents; a start about a project needs its item; no role; a name with `-side-`).

It has a form of its own on the New session page, shown while the hash is `#side=…` (the New session form otherwise). **A segmented
switch, New session | Quick session, sits at the very top of the page, the same on both forms** (the look of the scope
selector; there are no loose text links between the forms). The form has two independent, optional fields, each a picker with
a search box and the project list's look (a one-line summary with an arrow that opens a header row and a list):

- **Board item**: the open items of the running sessions (`api/board-items`), newest first, each with its subject and owner; an
  id can be typed instead (`board#N`, `sN`, or a temporary id). On its own it is a fresh session about the item: its project and
  owner are looked up (`GET /api/spawn/item?id=<id>` -> stackshot's client API `item-facts`, label `sala-web`; the store id is `gN`
  for `board#N`, `lN` for a temporary id, `sN` as it is) and shown in fields below, the owner going into "Agents involved". A lookup that
  fails says so and leaves the project to be typed (the box offers the pages' keys).
- **Session to fork**: the running sessions. On its own it is a fork of that session (sala finds its current conversation and
  directory); beside an item, the item is what the fork is about (`--item`).

The backend takes one of the two at least (`--fork-of`, or `--project` with `--item`; the gate is unchanged): with neither, or an
item and no project, the form says what is missing in words and Start waits. A failed start shows the reason the server gave,
in the form, in a box of its own.

- **`#side=<id>`, the Discuss link of stackshot** (`https://sala.example.com/#side=board#N`): the id is everything after `side=`,
  in any form the board shows (it may hold a `#` itself; an optional `&project=<key>&agents=<a,b>` after it fills those two). The
  form opens with the item chosen.
- **`#side=from:<name>`**, a link to a fork: the form with that session chosen to fork. Start queues
  `--fork-of <name>`. No button in the session header (its fold is measured to the pixel): the **Fork** entry of a session row's ⋯
  menu in the sidebar is this link.

Start shows the queued operation and, once the session is in the list, a link to it, as the New session form does. Nothing is
logged; a refusal is text. Like the New session form, the name field is emptied when the started session shows in the list (or the start reads Ready), if it
still holds that name; the result line and the Open link stay, so the check cannot call the session just started a clash. A blank
name is valid here (sala suggests one), so Start stays available. Until then, and for a start that fails or ends without the
session, the typed name stays (`sdOwnSeen`).

## Schedules

The Overview holds four tabs under the lane cards: **Agents** (the default, `#sessions`; the sessions
table, whose first column reads *Agent*), **Schedules** (`#schedules`; once a page of its own under the sidebar's Schedules
entry, which is gone) **Machines** (`#machines`, *Machines*, below) and **Usage analysis** (`#usage`, *Usage analysis*, below). Search is not a tab: it is the sidebar's search box and a page of its own (*Search*, below). An old `#schedules` link opens the Overview with the Schedules tab selected; the tab is a link, so the back button and
a copied address keep it. The Schedules tab lists every scheduled job of ours on the machine, as systemd and cron hold it (`schedules.py`, `GET /api/schedules`,
`static/schedules.js`, `static/schedules.css`); no database, nothing written. **It draws at once, from the last reading, and refreshes
behind it, as the lane cards do** (`swr.py`): systemd is asked about every job with a few short commands, which
would be waited for on every open if the page did not draw first, and now the server keeps the last reading in memory and answers with it in a few milliseconds. A
request that finds the reading older than 30 s (`schedules.TTL`) starts one read in a thread and still answers at once, with the old
reading and `refreshing: true`; a second request while it runs starts no other. The reading carries `fetchedAt` (epoch ms, when it was read) and
`generated` (the same moment in the zone's words, which the tab's count line shows as *read Mon Jan 5th 14:07 UTC*). The very first
request after a restart has no reading yet: the answer is `pending: true` (the tab says *Reading the timers…*) and the read runs; the reading is kept in
memory only, because its *today* and *tomorrow* are counted from the moment it was read. **Agents updates live** as it always did; **Schedules asks
when the tab opens and when its own Reload button is pressed**, and while an answer says `refreshing` it asks again every 1.5 s (40 times at most, as the
lane cards do) and **replaces the table in one step when a reading with a new `fetchedAt` arrives**; an answer it already drew is not drawn again, and the
sort, the *Flagged only* box and the scroll position are untouched by a refresh. There is no standing timer, the Agents tab's polling does not
read it, and leaving the tab ends the follow-up. Reload asks for `?fresh=1`, which makes the reading due at once: the table
stays as it is and the new reading replaces it a moment later. A read that fails keeps the last reading and puts `error` on it (a plain sentence, never the
exception's text): the tab keeps its table and says *Could not read the schedules just now; showing the reading from …*.
The unit files are read with one `systemctl [--user] cat` for all the units of a scope, cut apart at each unit's
`# <path>` header; a unit the batch does not return is asked alone, as before, so a missing unit costs one call and never the others' text.

Only jobs that are ours are listed: a unit that a package ships (a file under `/usr/` or `/lib/`, in either scope: apt-daily,
fstrim, certbot…) is left out of the list and of every count, and the tab says so in one muted note (*N packaged system
timers hidden*, `counts.packaged` in the API). System timers (`systemctl list-timers` without `--user`) are listed when that
answers without sudo (`scope` in the API); otherwise the tab says they were left out.

**One table, sorted by a heading.** The columns, in order: **Job**, **Category**, **What it does**, **When**
(the schedule, the next run and the last run), **Lane**. A heading is a button that sorts the table by its column; a second click on the same heading reverses it (the
arrow beside the heading, and `aria-sort` on it, show which way). The default is **Category, then Job A-Z**. A tie (two jobs with the same
value in the sorted column) falls back to the category order and then the job's name, whichever way the sort runs; a job with nothing in the
sorted column (no category, no next run, no last run, no lane) comes last in both directions. There are no groups and nothing folds or
drags; the saved preferences `scheduleOrder` and `scheduleFolded` are gone (a `PUT api/prefs` with them is refused).

**The Category is the job's own project**. It is the `X-Project=<scope/project>` line in the **service** unit's `[Unit]` section
(`schedules.py` `model_project`, API field `project`, `null` when absent), stored as the label the Agents tab's Project column shows
(*projects/demo-docs*, *work/docs*, *home/garden*), so the two tabs name a project the same way. A job gets it when it is added
(`sala job add --project`, `docs/units.md`) and the page holds no table that places a job: nothing in `schedules.py` or `schedules.js`
maps a name to a category, and the category order is read off the jobs on screen (the projects A-Z, a job with none last). A job with no
`X-Project=` shows "—" as its Category and is flagged `no project`. **Flagged only** hides the clean rows. The `SALA_UNIT_PROJECT_MAP` setting (`from=to` pairs, `schedules.py` `project_map`) shows a unit's `X-Project=` value under another category without editing the unit; unset, the unit's own value shows.

Each row (the columns stack into a card on a phone, so the page never scrolls sideways):

- **Job**: the job's name (the script it runs is its tooltip).
- **Category**: the project, as a quiet chip (the full `X-Project=` value is its tooltip).
- **What it does**: the description, with the leading *name -* of the unit's `Description=` trimmed (`summary` in the API; `description`
  stays as written), and the flag chips (*failed*, *not in git*, *differs from git*, *no lane*, *no project*, *cron*..., one chip a kind,
  the reason only in the chip's tooltip) under it.
- **When**: three lines, one under the other (on a phone the card has one *When* label and the same three lines under it). The column
  sorts by the next run; the phone's sort menu offers *Next run* and *Last run* both.
  Line one: the schedule in plain words, with no zone label (the header line names the zone), computed from the raw systemd lines (`plain_schedule`, a pure function; `plain` in the API; the
  raw `On...` lines are the tooltip of the plain words, and `schedule` in the API):
  `OnUnitActiveSec=5min` is *every 5 min*, `OnCalendar=*:0/10` *every 10 min*, `*-*-* *:00,30:00` *every 30 min, at :00 and :30*,
  `hourly` *every hour*, `daily` *every day at 09:00*, `weekly` *every Monday at 09:00*, `monthly` *on the 1st of every
  month at 09:00*, `OnBootSec=1min` alone *once, 1 min after boot*, with `OnUnitActiveSec=5min` *every 5 min, first 1 min
  after boot*. A seconds field is read too: `*-*-* *:*:07` is *every minute, at :07*, `*:*:0/20` *every 20 sec*, `*:*:07/30`
  *every 30 sec, at :07 and :37*, `*:*:*` *every second*, a daily `15:30:45` *every day at 00:30:45*. Calendar times are read
  in the box's zone (`Etc/UTC`, or a zone the line names) and shown in the **`SALA_TZ` zone** (its own label, `UTC` when it is `Etc/UTC`), the weekday or day of the month moving with them
  across midnight; a line the function does not recognize shows as written.
  Lines two and three: *next* and *last* (the two words muted), each with the run's time. One format for every time in the column, in the `SALA_TZ` zone and with
  no zone label: *today 08:45*, *tomorrow 08:45*, *yesterday 08:45*, any other day *Sun Jan 11th 05:17* (ordinal suffixes 1st, 2nd, 3rd,
  4th, 11th-13th). The day is counted in the `SALA_TZ` zone, not the browser's or the box's: the server writes it as `when` beside `iso`
  and `text` in each of `next` and `last` (`schedules.py` `when_text`), at the moment it reads, so the words are as old as the reading
  (30 s at the most when the tab opens, then replaced). The ISO string with `+04:00` is the tooltip of the time, the raw `On...` lines the tooltip of the schedule words. A job
  that has not run says *not yet run since boot* in muted words. A failed or running result is added as a line under *last* (failed
  in red, running in the busy colour).
- **Lane**: the lane chip (below); a unit with no lane reads *not set*.

The tab shows no link to the service or timer unit files, no script path and no *via* line (the API still sends `links`, `rendered` and
`unit_files`; the script is the name's tooltip). The user's crontab (`crontab -l`) is listed under the table, every line flagged
`cron: move to a timer`; no crontab is an empty list.

**On a phone** (760 px and narrower) the lane cards above the tabs fold into **one chip strip** (*<lane name> 40% · 10%*, *bedrock $12*,
*1 dormant*, read off the cards just drawn) that opens the cards when tapped and closes them when tapped again; the tabs fill the width; each
job row is a card with its Category chip beside the name; and a **sort menu** (a column choice and an ascending/descending button) sits above
the list and does the headings' work.

A timer's **last run** is the service's own start time, else the timer's `LastTriggerUSec`, else the newest journal entry of the
service (`journalctl [--user] -u <service> -n 1`; a boot clears the first two, so a weekly or monthly job would otherwise look
as if it never ran). With none of the three the row reads *last not yet run since boot* in neutral muted grey (`result.state`
`never`): it is not a failure, has no flag and is not counted as one.

- **The model lane** is the `X-Model-Lane=<lane>` key in the **service** unit's `[Unit]` section (systemd ignores `X-` keys;
  read from `systemctl --user cat <service>`, a comment line above it is fine, a drop-in's later value wins). The values:
  `subscription-1`, `bedrock`, `aws-platform`, `api`, `subscription-2`, `sdk`, `none`; the old `max` and `team` still read as subscription-1 and subscription-2 (`schedules.model_lane`). An optional `X-Model-Note=<text>` in the same section
  (for example `+ api key check when an api/sdk session runs`) is the tooltip of the lane chip (the chip column is too narrow
  for text), API field `lane_note` (`null` when absent); a missing note is never a flag.
  A unit of ours with no `X-Model-Lane` reads *not set* (muted italics, no chip) and is flagged `no lane`; only the declared value `none`
  is an outlined chip reading `none` (tooltip: declared: no model call), so the two cannot be mistaken for each other.
- **The links** (in the API only, as `links`; the page no longer shows them) are GitHub links, `https://github.com/<owner>/<repo>/blob/<branch>/<path>`, for the script, the service unit
  file and the timer unit file when each lives in a git repo with a GitHub `origin`: the unit file is resolved with `readlink -f`
  (`realpath`), the repo root with `git -C <dir> rev-parse --show-toplevel`, owner and repo from `git remote get-url origin`
  (https, `ssh://` and `git@github.com:` forms, a token or an ssh host alias in the URL dropped; the owner is whatever the
  remote says), the branch is `origin`'s default branch (`origin/HEAD`), else `main` or `master` if `origin` has it, else the
  checked-out branch.
- **A unit rendered from a template** is not loose. A unit file that is a regular file but whose **first line** is
  `# Rendered by <tool> from <template>.in …` (stackshot's `install.sh` writes `# Rendered by install.sh from
  units/example-job.service.in — edit the template, not this file.`; the pattern is `^#\s*Rendered by\s+\S+\s+from\s+(\S+\.in)\b`)
  shows as "rendered from `<template>`" with a link to the template, which is looked up under `~/stackshot` and the repo of
  the unit's script; with the template not found the row still says it was rendered, without a link.
- **A unit file copied from a repo** is in git. A provisioning step installs the owner's unit files from a separate repo as byte-identical copies, not symlinks. A plain unit file is
  looked up by its name among the files `git ls-files` lists in the owner's separate unit-file repo, `~/salamander`, `~/stackshot`, the render
  roots and the repo of the unit's script: a byte-identical tracked file counts as in git and is the row's link; a file of
  that name that differs from every such file is flagged `differs from git` (the reason names the git file; the row still
  links it); with no git source at all it keeps `not in git`.
- **The flags**, each a chip (one a kind) with its reason as the tooltip only: `failed` (the service's last run did not
  succeed: `ActiveState=failed` or a `Result` other than `success`), `not-git` (the service unit or the timer unit is
  neither a symlink into a git repo, nor rendered from a template, nor a copy of a tracked file; the reason names which and
  why), `git-differs` (a copy that differs from its git file), `no-lane` (no `X-Model-Lane=`), `bad-lane` (a value outside the
  list above), `no-project` (no `X-Project=`: the job has no Category), `no-service` (the timer's service unit is not loaded), `cron` (every crontab line). The header counts each
  reason once per row (`counts.byReason`).
- A command line that carries `NAME=value` with a name that says token, key, secret, password or credential shows the value
  as `***`.

### Search

Search finds a word in the Claude Code transcripts on this machine: `~/.claude/projects/**/*.jsonl`, the subagents' files
included. It is read-only and asks the server (`search.py`, `GET /api/search`, `static/search.js`, `static/search.css`); the
server sends back only the matches, as short snippets, never a transcript.

- **The search box** is at the top of the sidebar on every page (at the top of the drawer on a phone), just under its header. It
  is a box only, with no filters. **Ctrl+K** (or Cmd+K), from anywhere, and **/**, when the cursor is not in a text field or the
  composer, put the cursor in it (a wide screen's sidebar shows while the box has the cursor; a phone opens its drawer); **Escape**
  leaves it. **Enter** opens the results page in a new browser tab, so the page and the chat you were on stay as they are; in the
  installed app and at a phone's width (where a new window would land in Chrome's in-app view, outside sala), and when the
  browser blocks the new tab, it opens in place.
- **The results page** is a page of its own, `#search?q=…&hours=…&front=…&back=…&sub=…&unknown=…&messages=…&tools=…&output=…&thinking=…`
  (`from` and `to` in place of `hours` for picked dates): the same parameters `GET /api/search` takes. The When, Agents and Content
  filters are on this page only, above the results, under **the page's own query box** (the same look as the sidebar's, the full width of the page on a phone, filled from the address). **Enter** in it searches again with the new query and the filters as they are, and rewrites the address in place like a filter (an empty query does nothing, as in the sidebar's box; the sidebar's box takes the new query too). Ctrl+K and **/** still go to the sidebar's box, which a wide screen shows while it has the cursor. A search started from the sidebar's box takes the **last 6 hours, front agents only,
  messages only** (every other box off). Changing a filter searches again and rewrites the address in place (no new history entry).
  Because the query and the filters are in the address, a reload, Back and a shared link open the same search; Back from a
  result's chat shows the results again without asking the server. An old `#search` link opens the page with no query.
- **The query** is plain text, case-insensitive: every word must be in the same entry (a transcript line), and a quoted phrase is
  one word. It is never a regular expression, and no part of it reaches the file system (up to 200 characters and 8 words).
- **When** is a range: 1 h, 6 h (the box's default), 24 h, 3 days, 7 days, or **Pick dates** (two `datetime-local` boxes read in the
  server's `SALA_TZ` zone; the zone is written beside them; no limit but a year). Only files modified after the range
  starts are opened, and in a big file the reading starts at the range's first line (bisecting on the lines' `timestamp`).
- **Agents** are boxes: front agents (on from the box), background agents, their subagents and *role unknown*. **Content**
  boxes: messages (on from the box), tool calls, tool output and thinking. Each box shows `(n)`, how many matches it holds given
  the other group's boxes, so a box says what it hides before it is ticked. Changing a box or a range asks again. Hook and system notices
  (`<system-reminder>`, task notifications and the like) are left out of the messages. Ticking *thinking* adds a note: only some
  of the thinking blocks are saved in a transcript, so a miss there proves nothing.
- **Results are keyed on the agent's permanent id** (the registry `sessions.json`, through each transcript's session id, so a
  `/clear`, a rename or a recycle does not split an agent) and shown by its **current name**, with a role badge. A
  subagent's entry is shown under its agent, marked *subagent*. A transcript the registry does not know shows as *session
  `<first 8>`*.
- **Roles are filled at read time**: the registry row's own role, else what stackshot answers for the name or an alias
  (`front`, `back`; `keeper` reads as background), else the **unknown** bucket, which is never dropped. Nothing is written back to the registry.
- **The summary line** reads `32 matches for “zebra”, newest first · 1 h to Mon Jan 5th 02:08 UTC · searched in 0.4 s`. The server keeps the
  newest **200** matches and a warning says so when there were more (*Showing the newest 200 of N matches*); the page shows 25 at a time
  (*Show N more*). A search is cut at **20 s** and says so; two run at once, a third is refused (429) with a sentence.
- **A result opens the chat at the entry**, however far back it is, when the agent is running: the chat scrolls to it and outlines
  it for a few seconds. Each result carries `pos`, the byte offset of its line in the session's transcript, and `target`, the uuid
  to light. An entry within the chat's loaded tail (the last 200 messages) is scrolled to there; an older one opens the chat
  around it (`GET /api/s/<pid>/transcript?around=<pos>`, *Older messages*): older pages load as the chat is scrolled up, newer
  ones (`?after=<cursor>`) as it is scrolled down, and what the stream brings meanwhile waits until the newer pages meet the live
  end, where it goes in (each message once) and the chat follows the stream again; ↓ goes to the live end at once. A subagent's
  result opens the agent's chat at the Agent/Task tool call that started the subagent, found in the session's transcript through
  the call's tool_result (`toolUseResult.agentId`, or a progress line's `parentToolUseID`); when none is found it opens the chat at
  its end. An entry of an earlier conversation (before a `/clear`) opens the chat at its end with a status line saying why. An
  agent that is not running is not a link (*not running*).

Same access as every other `/api` route (sala-web has no login of its own; it listens on a unix socket behind the access proxy).
Tests: `tests/test_search.py` (the core over a fixture tree), `tests/test_search_api.py`, `tests/test_search_ui.py`.

## Machines

The third Overview tab (`#machines`, next to Agents and Schedules) shows which version of each tool every machine runs: **Machines**, one card per machine, with a
footer that says how old the reading is ("updated 4 min ago", the age of `site/versions.json`). sala reads no runner file. It is a view: no button or field in it, apart from the tab bar's Reload. It **reads when the tab opens and when
Reload is pressed, and at no other time**; a local timer re-words only the footer's age. On a phone the cards stack to one column and the page never scrolls sideways at 390 px (the tab bar's Reload is its icon alone there, so the four tabs fit).
Code: `machines.py`, `GET /api/machines`, `static/machines.js`, `static/machines.css`, the tab and panel in `static/index.html`, the tab routing in `static/app.js`.

- **Cards** come from stackshot's `site/versions.json` and `clients/fleet/<letter>/machine.json`: a row per package (version, then `latest ✓`, `→ <newer>` or
  `offline`); a machine read over ssh as well as reported by its own client shows the ssh row while the host answers and the client's row when it does not. A failed
  setup run, or a package whose latest update attempt failed, is a red line in the card and marks the card. The one exception is a box's own stackshot checkout: it is judged by
  where the box is, not by its last attempt. While the commit the box reports (`stackshot` in its `machine.json`) equals the commit the server tells the boxes to follow
  (`clients/advertised-commit` in stackshot's state folder), the failed checkout attempt is not shown, so the card is red only while the box is elsewhere and clears itself when the two
  match, with no new attempt and no hand step. A failed `reload failed` attempt whose target is the commit the box runs now stays red (the box is at the commit and the new code did not load). With either
  commit unknown (no `advertised-commit` file, no reported commit) the last attempt decides, as it does for every other package.
- **A card's last line** says how the machine stays current, from the follow list (`run_on`, `[machines.<host>]` in a `machines.toml`) and its record
  (`<host>.json`, `at_epoch`): the publisher, or the `run_on` machine, reads "the machine the others follow"; a listed machine reads "follows <run_on> · last HH:MM"
  (the time in the page's zone; no time when there is no record); any other machine reads "updates itself". An unreadable list says "update source not read".
- **Names and order** come from the fleet names file, `[fleet] publisher_letter` and `[machines_panel] ssh_hosts` in `stackshot.toml` (the publisher first, then the
  fleet letters, then the ssh hosts, no name twice). No machine is named in sala's code.
- **A missing reading** is a line in the tab ("No reading yet. stackshot has not written the machines' versions yet."), never an error page, and the footer is blank.
  The files are read with a size cap, nothing in the answer is a token or a session name, and the names from the files are set as text, never as markup.

Tests: `tests/test_machines.py` (the core over a made-up fleet in a temporary folder), `tests/test_machines_ui.py` (headless Chromium at 1280 px and 390 px); both build
their fleet with `tests/machines_world.py`.

In the cards "latest ✓" is green (`--state-active`) and a pending update is `--call`'s orange.

## Usage analysis

The fourth Overview tab (`#usage`, after Agents, Schedules and Machines) shows **what the Claude Code replies on this machine cost, at list prices**, by week, day, lane,
model, project, agent and folder. One data layer (`usage.py`, `GET /api/usage`) sits under three views, switched by the small control at the top of the tab: **Report** (the
default), **Explorer** and **Digest**. This release builds the data layer, the tab and all three views. The tab shows **dollars
only**: the server keeps the token counts on each row and the page never shows them. Other machines are not counted: the tab says so.

- **A week** runs from one weekly reset of the subscription lane to the next (the "This week" limit's `resetsAt`, read from the quota cache the lane cards use). Week 0 is the
  one running now, 1 and 2 are seven days back each. A reset that has passed is rolled forward by whole weeks; with no quota answer the last anchor `usage.py` saved is used, and with
  none the weeks are plain seven-day windows ending now (`resetKnown: false`, and the tab says so). Days are KST, always, whatever `SALA_TZ` says.
- **Report** is: the week picker with its range and "resets in…"; the total at list prices with how much of it was billed (everything except the flat-plan lanes) and the change against
  the same hours of the previous week; one card per lane (a flat-plan lane says *flat plan, not billed*, with the weekly limit used when the quota answer has it; a per-use lane says
  *billed per use (estimate)*); **Group by** Day, Lane, Model, Project, Agent or Folder; a stacked chart by day; and a sortable table with share bars. **Every figure filters**:
  a tap on a lane card, a day, a name in the chart's key or a table row filters the total, the chart and the table to it, a chip shows each filter, a second tap clears it. On a phone
  the table keeps its name and cost columns and every control is a 44 px target; the page never scrolls sideways at 390 px.
- **Explorer** compares any two things side by side, down to a single reply. **Compare** picks the dimension (Week, Day, Lane, Model, Project, Agent or Folder); **A** and **B** pick the
  two values (by default the two costliest of the week; Day starts on the two latest days with replies, Week on this week and the one before; a *none* leaves a side empty). **Break down by**
  picks what the table lists (every dimension but the compared one and Week); a **Where** select per other dimension narrows both sides (each offers only what the other filters leave, and
  *Clear filters* removes them). A card per side shows its dollars at list prices, how much was billed, the replies and, for B, the change against A; a flat-plan lane says *not billed* wherever it
  is named. The table has one row per break-down value with A, B and the change (paired bars, sortable). **A tap on a row lists the replies behind it** (time in KST, model, lane, agent, dollars),
  newest first, for A or B (a switch picks the side), narrowed by the same filters, at most 200 with the number there are in all; a second tap closes it. Week choices ask the server for each week.
  It reads when it opens, on a change of what is compared, and on Reload, and nothing while another view is on screen; the words (not billed, the machine note, the price note) are the Report's.
  Code: `static/usage-explorer.js`, `static/usage-explorer.css`; it joins the tab through `usage.registerView` and shares `usage.kit`.
- **Digest** is the week in a few plain sentences, with the same week picker as Report (the week is one for both views). The sentences are **written by code, from the same rows**
  (`usage_digest.py`, a pure function over one week's answer of `/api/usage`; templates, no model call, no second transcript scan): the total at list prices with how much of it was billed (a
  flat-plan lane's dollars are *not billed*); the busiest day; the lane that took the largest share; the model; the project and the agent that took the most; how the week compares with the
  week before (the running week over the same hours of the week before, a closed week with the week before it, the oldest week says there is no earlier one); and how much of a flat-plan lane's
  weekly limit is used (the running week only, and only when the quota answer has it). Plain words, 1 to 7 sentences, dates like `Sat Nov 7th`, money like `$12.40`, days in KST. A week with no
  replies, a first week with nothing before it, a lane with only flat-plan spend and a model with no price each get a sentence that says so, never `NaN` or `undefined`. The same words
  in the same order for the same rows, whatever the order of the rows, so a scheduled job can call `usage_digest.digest(answer)` and deliver the report at the weekly reset. `GET /api/usage/digest?week=0|1|2`
  serves it (the page asks when the Digest is opened, on a change of week and on Reload).
- **Where the figures come from.** Nothing is asked of Anthropic or AWS: every assistant reply in a Claude Code transcript carries its token counts, which are multiplied by the model's
  list price. The count is `spend.py`'s, reused: **the one price table** (`spend.PRICES`, USD per million tokens, with `spend.PRICES_AS_OF` beside it: a marker, set by whoever checks the
  prices; the tab prints it as *As of …* under the table), the same model-name normalizer, the same rule that a reply is counted once (a streamed reply is several lines with one message
  id, a fork copies history: each id once, with the largest of each token field), the same reading of subagent transcripts (they belong to the session whose folder holds them) and the
  same lane records (`spend.Facts`). A model with no price is counted as $0 and listed under `unpriced`, never silently. Where `spend.py` reads only the sessions that are or were on an AWS
  lane, this reads **every transcript of the last three weeks**, under the default config directory and under each second login's (`sessions.LANE_DIRS`; a second login's `projects`
  folder that is a link to the first is read once, and its lane comes from the records).
- **Names.** *Lane* is the lane at the reply's time. *Agent* is the session's name in sala's registry (a rename counts under the current name), `(unnamed)` for a session it does not know.
  *Project* is the agent's name up to its project part: sessions are named `<scope>-<project>-…`, the scopes being this machine's (`scopes.py`), so `<scope>-<project>`; a name whose
  first part is no scope has its first part. *Folder* is the directory the session started in (the first `cwd` the transcript names), a worktree counted as its repository and the home
  directory written `~`.
- **Keeping it cheap.** Per transcript the scan cache holds the inode, size and mtime last seen, the offset after the last complete line, the first `cwd` and the replies of the window.
  A file whose size and mtime are as they were is not opened; one that grew is read from where it stopped; a replaced or shortened one is read again. The cache lives in memory and in
  `usage-scan.json` in the state directory (tens of MB on a busy machine; saved at the end of every count), and reaches an
  hour back of the oldest week so a reset moving a little never rebuilds it. A day's growth is read in seconds, so the count is not throttled.
- **When it counts.** The count is **a job of its own, once a day at 05:00 KST, plus the tab's Reload; opening the tab, the Explorer or the Digest never starts one.** The job is
  `contrib/sala-web-usage-count` (`python -m sala_web.usage_job` in the web environment; a timer made with `sala job add`, listed on the Schedules tab; no model call, nothing asked
  of Anthropic or AWS): it counts with the code Reload uses, saves `usage-answer.json`, `usage-replies.json` and `usage-scan.json` in the state directory, and exits 1 with one plain line on
  stderr when the count failed, leaving the last saved count in place. The app serves the last saved count at once (`swr.py` `peek`), however old, and reads the files again when the
  job has written newer ones, so a restart or a nightly count needs nothing from anyone. Each answer carries `generated`, and the tab says *counted 5 h ago* from it. `?fresh=1` (the
  tab's Reload) starts one more count in a thread and never blocks the server; a second Reload while one runs joins it, and the page asks again every 3 s (`pending` before there is
  any count, `refreshing` with an older one on screen) until it lands. **With no count made yet** the answer is `noCount: true` (not `pending`: nothing is running, so the page does
  not poll): the tab says *No count yet. The replies are counted once a day; Reload counts them now.*
- **Replies.** Beside the rows the count keeps, per reply, only its time, the key of its row and its dollars. Every count saves them (`usage-replies.json`, a few MB on a busy machine),
  so after a restart, or when the job has counted, `GET /api/usage/replies` reads that file on the first drill-down and counts nothing; with no such file yet (no count made, or only one
  from before the file existed) it answers `noCount: true`, and Reload makes one. `GET /api/usage/replies?week=<0|1|2>&limit=<n>&<dimension>=<value>…` filters by any of `day`, `lane`, `model`, `project`, `agent`, `folder`
  (repeat a name for alternatives) and returns the newest first, at most 200 (`cap`), with `total` and `usd` of all that matched. It reads no transcript of its own and carries no text.
- **What leaves a transcript** is names, counts and dollars: no prompt, reply, tool input or secret. The tab reads when it opens, on a change of week and on Reload, never by itself, and
  what it reads is the last saved count.

Code: `usage.py`, `usage_job.py` with its script `contrib/sala-web-usage-count`, `swr.py` (`peek`, `start`, `refresh_now`, `reload`), `GET /api/usage`, `GET /api/usage/replies`, `static/usage.js`, `static/usage.css`, the tab and panels in `static/index.html`, the tab routing in `static/app.js`; Explorer: `static/usage-explorer.js`, `static/usage-explorer.css`; the Digest: `usage_digest.py`, `GET /api/usage/digest`, `static/usage-digest.js`, `static/usage-digest.css`.
Tests: `tests/test_usage.py` (the data layer over fake transcripts in a temporary folder), `tests/test_usage_count.py` (when it counts: a visit never, Reload once, the job command, a restart), `tests/test_usage_ui.py` (headless Chromium at 1280 px and 390 px); `tests/test_usage_explorer.py` (the replies list and route), `tests/test_usage_explorer_ui.py` (Explorer in Chromium); `tests/test_usage_digest.py` (the sentences and the route), `tests/test_usage_digest_ui.py` (the Digest in a browser, both widths, both themes).

## The language

The page is in English by default and has a Korean version, chosen with the **EN / KO** control at the foot of the session list
(beside the color control, in `#side-foot`): two separate outlined buttons, EN then KO, 44 px wide at least, the one in use in the accent
colour (text and border), each with a tooltip naming its language in the page's own (`side.lang.en`, `side.lang.ko`). Only the page's own words are translated: the buttons, labels, hints, headings,
tooltips, the status and error lines the page itself words, relative ages ("5 min ago") and the dates in tooltips. Never
translated: the chat (messages, tool names and output, the thinking and terminal text), session, project and machine names, paths and
commands, and any text the server sends through (a queue note, an error reason from sala or stackshot, the Usage digest's
sentences, the plan and lane names); those show as sent.

**Where the choice lives.** On the server, as the pref **`lang`** (`en` or `ko`, *Preferences* below), like the other settings, so the
phone and the desktop agree. The page is served already in it: `index.html` and `terminal.html` carry `<html lang="{{lang}}">`, which the
server fills from the saved pref, so a reload paints the right language from the first frame and nothing is kept in `localStorage`. A
tap on a language switches the page at once, without a reload and without losing anything typed, and saves the pref; the page also
reads the pref when it loads, so a change made on another device is taken up.

**The pieces** (all under `static/`):

- `i18n-en.js` sets `window.SALA_I18N_EN`, the English table: dotted key to text, the source of truth for every key. A text with a
  count has two entries, `<key>.one` and `<key>.other`; a value is filled in from `{name}` placeholders.
- `i18n-ko.js` sets `window.SALA_I18N_KO`, the Korean table, with the same keys and placeholders. It is the only file with Korean in it,
  and every Korean character in it is written as a `\uXXXX` escape (no other committed file holds a Hangul character; a test
  checks that, read as bytes). A text with a count needs only `<key>.other`, since Korean has the one plural form. A key it lacks
  shows in English.
- `i18n.js` is the lookup, loaded before every other script: `tl(key, vars)` returns the text in the active language (the active
  language's table, else English, else the key itself), `SalaI18n.apply(root)` words the `data-i18n*` attributes of the markup,
  `tx(key, vars, kind)` returns the attributes of a node a script builds (so the node can be reworded in place), `SalaI18n.setLang`,
  `SalaI18n.onChange(fn)` for a script that keeps text of its own, and `SalaI18n.locale()` for dates and numbers (`en-US` or `ko-KR`).
  Dates keep the configured zone (`SALA_TZ`, `shared.js` `zoneFormat`); only the wording of weekday, month and the zone label follows
  the language.
- The markup says its words in English and names the key: `data-i18n="key"` for the text, `data-i18n-title`, `-placeholder`
  and `-aria-label` for those attributes (`data-i18n-arg` for the one `{arg}` a few texts take). A word a style rule draws
  (`content: attr(data-word)`, the Status and Reload rows of the header menu) is set with `data-i18n-word`, which fills `data-word`.

**Changing the language redraws, it does not reload.** Text the page stored for later (a status line, a note under a form) is stored
as a function that words itself when it is drawn, and each part of the page that builds text from held data (the sidebar, the
Overview, Schedules, Machines, Search, Usage, the forms, the composer's hint, the chips, the header pills) registers with
`SalaI18n.onChange` and draws again from what it holds. The chat's text is not touched.

**Adding a string.** Add the key to `i18n-en.js` (and `<key>.one`/`<key>.other` if it has a count), the Korean text to `i18n-ko.js`
as `\u` escapes, and use it as `tl("key", {name: ...})` in a script or `data-i18n="key"` in the markup, with the English words
between the tags. `tests/test_i18n.py` fails for a key used and not in the English table, a key in the English table that nothing uses,
a Korean key missing, empty or left in English, different placeholders, or markup whose words differ from the table. A text a script
builds once and keeps in the page (an element made by a script) uses `...tx("key")` for its attributes, so a switch can reword it.
An element whose text or attribute script paints from data that arrives later (the header's name, the shell button's tooltip) carries
no `data-i18n*` in the markup: the markup is applied once when the document has loaded, and that apply would otherwise write the
generic words over the script's. Such a text is worded in script at start and again from `SalaI18n.onChange`; a test applies the markup
afresh on every view and fails if anything changes.

**Adding a language.** Another table file (`i18n-xx.js`, with a plural rule in `PLURAL` in `i18n.js` and a `LOCALE` entry), the code in
the `PREFS_LANGS` list in `app.py`, a button in the `.side-lang` group, and the same coverage test over the new table.

## The palette

The colours are stackshot's, under sala's own custom properties in `static/style.css` (a light block, a `prefers-color-scheme: dark` block and a
`:root[data-theme="dark"]` block that repeat each other): `--bg`/`--side-bg` `#fafaf8` and `#161617`, `--accent` the app's one orange (`#ad4608` light, `#f0a06a` dark, the dark one the same orange as the app icons'; the light one holds 4.7:1 or better on every light surface, the dark one 6.6:1 or better on every dark surface; the send button, the tabs' underline, focus rings, the unread counts,
the drop line, the effort tints, links), `--call` and `--role-front-text` the same orange and `--warn` stackshot's amber. Everything that was blue follows the accent. Orange now has several meanings, told apart by shape and place:
the accent (buttons, links, rings, counts), the **front badge** and the **metered lane** (`--call` and `--role-front-text`; the same `#ad4608` and `#f0a06a` as the accent, there is no second orange in the app, and `test_theme_contrast.py` fails on any other orange in a page file; the front badge's fill is the orange at 12% over the page, as at 20% the light text measured 4.10:1).
The lane colours (`--lane-*`), the model family colours, the black Terminal and Shell, and the sala icon (the PNGs and the tab icons, whose `#f0a06a` is the dark theme's orange too) are not part of the palette move and keep theirs.

Four tokens were added to the ones the page had: `--link` (the accent as the colour of text: the same orange as `--accent`, 4.7:1 or better on every surface,
so a link on a user's bubble holds 4.5:1), `--waiting-text` (the text on a red `--waiting` fill: white in the light theme, the dark panel colour in the dark one) and stackshot's `--call` and `--warn`
(the page had neither). A text token is held at WCAG AA (4.5:1) on every surface it sits on, in both themes, with `--faint` reading as `--muted` on a selected
row (`.sess.selected`, `.has-selected`). `--muted`, `--faint`, `--busy`, `--warn` and `--call` differ slightly from stackshot's own values for that reason
(comment at the top of `style.css`). The status bar and the strip behind the gesture bar are each theme's `--bg` (`<meta name="theme-color">` in `index.html`), the
launch splash is the dark one (`manifest.webmanifest`, see "Install as an app").

Tests: `tests/test_theme_contrast.py` (pure Python over the tokens in `style.css`: every text pair's ratio in both themes, the three token blocks agreeing, the front
badge and metered lane on `--call`, the accent and link pairs, the metas and the manifest equal to `--bg`, no colour of the old palette left in the static files); the browser tests that measure
computed colours (`test_unread_count.py`, `test_header_layout.py`, `test_lane_status_pill.py`, `test_quota.py` and others) hold the same 4.5:1 on the rendered page.

### The color tool

A **Colors** button at the bottom of the side panel, under "Show all sessions" (`#side-colors`, the last thing in `#sidebar`), opens a panel for choosing colors on the **dark** theme;
in the light theme (the system's, or `data-theme="light"` on `<html>`) there is no button and nothing is applied. It is a permanent part of the page, and it does not float over the
composer. The panel opens upward from the button, fits 360 px without a sideways scroll and scrolls inside the window. At the bottom of the panel, beside the button, one box holds the presets and the saved
combinations; above it a **Fields** button folds away the 14 fields (each with the browser's own color picker and a hex box; the contrast numbers) and the preview, closed at first and opened by a click, and
opening it grows the panel upward. The panel itself (**Reset**; the presets; the saved combinations; the fold; the fields) is **stackshot's shared color tool**, `static/colortool.js`, which sala pins as a verbatim copy
and never edits: its sha256 is in `static/colortool.js.sha256`, and `tests/test_colortool_wiring.py` fails when the two differ. To take a newer version, run `web/tools/pin-colortool`
(it copies `~/stackshot/shared/colortool.js`, or the path given as its argument, and rewrites the sha file), then run that test. Sala's own part is `static/colortool-sala.js`: the settings
the tool is given (which variables each field sets, how the shipped look is read, the preview of sala's buttons and labels, the panel's note and example hex) and the one call that applies the stored look in the head. A field that follows others (the three label fields and the disabled pair) shows sala's own shipped value while none of the fields it follows is set, and is worked out from the live ones once one is; the panel says "shipped" or "follows the others" beside it. The tool runs the wiring's `onApply` hook in the light theme too, with nothing to apply; the hook then only puts the dark `theme-color` meta back and returns.
Load order: `index.html` and `terminal.html` load `colortool.js` and then `colortool-sala.js` in the head (the stored look is applied before the first paint); only the end of
`index.html`'s body starts the button (`SalaColors.init()`); the terminal page applies the look and has no button. The owners are `colors.py`
and `app.py` (the saved list's three routes), `colortool-sala.js` and the pinned `colortool.js`.

| Field (panel label) | Variables it sets |
|---|---|
| `bg` Page background | `--bg`, `--side-bg`, and the dark `theme-color` meta |
| `card` Cards | `--panel`, and `--code-bg`, `--hover`, `--selected`, `--user-bubble` each moved by the amount the card colour moved from its shipped value |
| `fg` Body text | `--text` |
| `mut` Muted text | `--muted` |
| `line` Lines | `--border` |
| `ibd` Button outlines | `--faint` |
| `link` Text and links | `--link`, `--call`, `--accent`, `--role-front-text`, `--acc` (the orange that is text or a stroke) |
| `solid` Solid fills | `--accent-solid` (the primary buttons, Reload on the update strip included; the tints that selected chips and the front badge mix from it) |
| `onsolid` Text on solid fills | `--accent-on-solid` |
| `labbg` Small label fill | `--label-bg`: the unread count, the "max" effort tag, the front badge |
| `labfg` Small label text | `--label-fg`: the same three |
| `labbd` Small label outline | `--label-bd`: the same three (an inner 1 px ring on the count and the tag, the border of the front badge); equal to the fill it is no visible outline |
| `disbg` Disabled fill, `disfg` Disabled text | `--dis-bg`, `--dis-fg`, and `--dis-op: 1` with them |

The stylesheets read every new name with a fallback (`var(--accent-solid, var(--accent))`, `var(--label-bd, transparent)`, `var(--dis-op, .45)`), so without the script nothing changes.
**Disabled buttons**: the idle Send button (`.send-btn:disabled`) was the solid fill faded to 45% opacity, which turns it brown. In the dark theme it now ships as `--dis-bg` and `--dis-fg` at opacity 1
(`--dis-op`), `#2a2a2c` and `#a3a29d` (*The shipped dark look*, below); in the light theme, where those tokens are not set, it is still the faded solid. With the script's variables set it is exactly the colors it was given. The two other solid buttons that fade by opacity, Create session and Start quick session
(`.ns-submit:disabled`, and `#ns-submit`, `#sd-submit` in the page's `look` style), take the same pair; the paperclip and the Stop button of a running `!` command are not solid buttons and are left alone.
Setting either disabled field sets both (the other from the shipped look).

**The shipped dark look.** The dark theme ships one saved combination as its default, because it keeps the one orange and gives the small labels and the disabled buttons a quiet pair of their own. Its 14 values:
`bg` `#161617`, `card` `#1f1f21`, `fg` `#ececea`, `mut` `#a3a29d`, `line` `#2c2c2e`, `ibd` `#929190`, `link` `#f0a06a`, `solid` `#f0a06a`, `onsolid` `#1f1f21`, `labbg` `#3a2619`, `labfg` `#f0a06a`, `labbd` `#3a2619`, `disbg` `#2a2a2c`, `disfg` `#a3a29d`.
The first nine are the dark theme's own tokens (the neutrals, and the one orange for links, accents and the solid fill, with its dark text); the other five are tokens of their own in `style.css`, in a block beside the dark theme's (`--label-bg`, `--label-fg`, `--label-bd`, `--dis-bg`, `--dis-fg`, and `--dis-op: 1`):
a small label (the unread count, the front badge in the title bar and a search hit, the "max" effort tag) is the orange on a deep brown, `#f0a06a` on `#3a2619` (6.76:1) with an outline of the fill's own color (none to see), and a disabled solid button (Send, Create session, Start quick session) is a flat grey, `#a3a29d` on `#2a2a2c` (5.60:1) at full opacity.
There is still one orange (`link`, `solid` and `labfg` are all `#f0a06a`). The light theme sets none of the six and keeps the stylesheets' fallbacks (the solid fill with its text, the faded button). The panel's `shipped()` (`colortool-sala.js`) reads the six tokens, so the **Original orange theme** preset and the boxes of the fields that follow others show exactly these 14 values;
with no token (the light theme) it works the labels and the disabled pair out from the solid fill as before, and the terminal page, which has no palette, answers from the wiring's fallback table. `tests/test_colortool_wiring.py` and `tests/test_theme_contrast.py` hold it.

**Presets** (all neutrals the same: `#161617`, `#1f1f21`, `#ececea`, `#a3a29d`, `#2c2c2e`, `#929190`; the label outline equals the label fill; disabled `#2a2a2c` / `#a3a29d`), by
text and links / solid / text on solid / label fill / label text: **Original orange theme** (id `live`) is what the app ships (the combination above) and clears every override, as Reset does (the boxes then show the shipped values); **Sky** `#7cb7ff` / `#2a6fd0` / `#ffffff` / `#14283f` / `#7cb7ff`; **Mint** `#5fd3a6` / `#18805d` / `#ffffff` / `#10302a` / `#5fd3a6`;
**Violet** `#b79cff` / `#7a52e0` / `#ffffff` / `#251c46` / `#b79cff`; **Rose** `#ff8fb0` / `#d6336c` / `#ffffff` / `#40182a` / `#ff8fb0`. The list is the pinned file's (version 3; the presets of version 2 are gone from it, and a look stored or saved from one of them keeps applying, because what is kept is the fields, never a preset's id).

**Contrast**: the gate is `warn`: nothing is refused or corrected; a ratio below its limit is a note beside the field.

**What the pinned version does for the fields that follow others**: while none of the fields a small-label or disabled field follows is set, the panel shows the value `shipped()` returns for it (the six tokens above) and says "shipped"; once one is set, the tool works it out from the live ones, and the page draws what the tool then sets.

**Saved combinations** are one list on the account that stackshot's page shares, held by stackshot; sala reaches it through its own server, which adds the token and the sender label
(`colors.py`; the browser sends and sees neither): `GET /api/colors/combos`, `POST /api/colors/combos` `{name, values}` (a name already in the list, case ignored, is replaced in place)
and `POST /api/colors/combos/delete` `{id}`. The name (1 to 40 characters, no control characters) and the 14 colors (`#rrggbb`) are checked before anything is forwarded; the list is not cached, so a
combination saved from the other page shows when the panel is next opened; a row that is not a whole combination of 14 colors is left out; a failure comes back as `{error, field}` (stackshot's own
sentence for a refusal, 502 when it cannot be reached or refused the token, 503 when this machine has no token or the list cannot be read). With the list unavailable the panel says so beside the
list and everything else works. Applying a saved combination fills the 14 fields and keeps them like a pick. The saved list is permanent. Needs `sala-web` in stackshot's `[project_agent] form_senders`
and this machine in `form_machines`.

What is applied stays in this browser: the 14 values as inline custom properties on `<html>`, kept in `localStorage` (key `sala-colortry`: the key keeps the name it had, so a look stored
before the tool was pinned keeps loading; a flat map of `#rrggbb`, only the fields that differ from what they would be unset; without storage the pick lasts until the page closes; whether the Fields fold is open is kept beside it, under `sala-colortry:fields`, and the fold is closed when storage is off or empty). The only request
the tool makes is to `api/colors/combos`. The cfg also restores the dark `theme-color` meta on Reset, the Original orange theme preset and the light theme. On the terminal page the page stays black and a pick reaches only the Copy
offer. Tests: `tests/test_colortool_wiring.py`, `tests/test_colors_combos.py`.

## The look

**The page is drawn with stackshot's look**: one type scale (12, 13, 15, 17 and 22 px; 16 px stays on form fields, since a smaller
field makes iOS zoom the page when it takes focus), two weights (400 and 600, 500 on tags), sentence case, a 4 px grid, 4 and 8 px
corners, one 920 px column, D2Coding for code, stackshot's icons (a 24 grid, a 2 px round stroke), two button levels, tinted tags without
an outline, links without an underline until hover, and the orange accent (`#f0a06a` dark, `#ad4608` light). On a phone the Agents table is
one row per agent, and controls are 44 px (32 px with a mouse).

**Where it lives.** It is in the sources, not applied on top of them:

- `static/*.css` (not `vendor/`) are written on the scale: the five sizes, the two weights, no letter-spacing or uppercase, the monospace
  face on code and terminal rules only (`--mono` leads with D2Coding), padding, margin and gap on the 4 px grid (2 px and under are
  hairlines and stay), radii of 4 or 8 px (a pill and 2 px stay), and the 920 px column. A new rule is written that way too.
- `static/index.html` ends its `<head>` with one `<style id="look">`, after every stylesheet link, so it wins the cascade. It holds the
  `@font-face` for the code face and what a rule on the scale cannot make: the two button levels, the tinted tags, the link rule, the
  orange, the update strip's Reload as a solid main button, the 32 and 44 px controls (`--ctl`, by pointer; the composer's Send is the exception under a finger: drawn 30 px with a 44 px tap area that takes no room, so the one-line row stays 48 px), lane cards three to a row, Agents as rows on a phone, the scroll gutter. The page's
  inline icons are drawn on the 24 grid, and `app.js` draws its check mark at the same 2 px stroke.
- `static/fonts/D2Coding-Regular.woff2` is the code face; `OFL.txt` beside it is its licence (the SIL Open Font License 1.1), which
  travels with the font.

**Not drawn in this look:** the Terminal view's own page (`/terminal` is `terminal.html`) and the contents of the Shell drawer and the
Terminal tab (ttyd's page in a frame: the frame's chrome follows the look, what it shows does not). The `/tty/` address is absolute.

**The installed app is unchanged.** The page links `manifest.webmanifest` (`start_url` and `scope` are `./`, so the app opens at `/`) and
`app.js` registers `/sw.js`, as before; the worker has no fetch handler (*Install as an app* below).

**`/v2` redirects to `/` for a while.** The look was first tried at `/v2/`. `/v2`, `/v2/` and every path under it (GET and HEAD) answer a
temporary redirect (307) to `/`, with the query kept and nothing of the path: `/v2/x` goes to `/`, not to `/x`. This is for old bookmarks
and for the installed app's older link; it is dropped later, and nothing else refers to `/v2`.

**Tests.** `tests/test_look_scale.py` (pure text: every stylesheet holds the scale, the weights, no letter-spacing, no uppercase, the
monospace face on code only, the grid, the two radii and one column width; the page keeps its manifest link and its one `look` style
after every stylesheet link; every inline icon is on the 24 grid), `tests/test_look_redirect.py` (HTTP: `/v2` and what is under it
redirect to `/` with the query, the manifest, the worker and the font with its licence are served) and `tests/test_look_browser.py` (a
headless Chromium at 390, 768, 1024 and 1440 px over the Agents, Schedules and Machines tabs, a chat, Search results and the New session
page: no sideways scroll, a column of at most 920 px on a wide screen, no error logged, the monospace font loaded, the manifest linked and
the worker registered). What they do not cover is in `docs/test-coverage.md`.

**The update strip.** "sala was updated. Reload" (`#update-banner`, `.banner` in `style.css`) is a thin strip above the header. It takes the card gray
(`--panel`) with a `--border` hairline under it, so it follows the dark and the light theme and the color tool, and carries no orange
of its own; it used to mix the accent 14% into the background, which came out brown on the dark theme. Reload (`#reload-btn`, drawn in
the `look` style) is the solid accent button (`--accent-solid`, else `--accent`, with `--accent-on-solid`), so the eye goes there; it keeps
the 2 px focus outline for a keyboard. `tests/test_update_banner_look.py` holds the colors, the contrast (4.5:1 or better) and the strip's
height in both themes.

## Mockup pages

`GET /mockup/<n>` serves an HTML page that `sala mockup add FILE` stored (salamander's `lib/mockup.py`, [docs/mockup.md](../docs/mockup.md)), so a session that cannot publish an Artifact hands a reader
a link instead of a picture. The pages are files under `<sala state>/mockups/<n>.html` (mode 600, folder 700); sala-web only reads them (`mockup.py`, `Settings.mockups_dir`), opens a page without following a link,
serves a regular file of at most 5 MiB only, and answers 404 for a number with no page, for one that is not written as a plain number, and for a folder that does not exist yet. It is `text/html; charset=utf-8`; a page that is not
UTF-8 (put there by hand, the CLI refuses it) is a 415, and any method but GET and HEAD a 405 with `Allow`.

There is no sign-in of its own: sala-web has none and the proxy in front of the site is the sign-in ([web-proxy.md](../docs/web-proxy.md)); the route is served by the same app, so it is inside that sign-in.

Every response under `/mockup/` (a page, a 404, a 405) carries the sandbox headers, because a stored page is someone's HTML at the terminal's address:

```
Content-Security-Policy: sandbox allow-scripts; default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com data:;
  img-src data:; media-src data:; connect-src 'none'; frame-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'self'
X-Content-Type-Options: nosniff
Referrer-Policy: no-referrer
Cache-Control: private, no-cache
```

`sandbox allow-scripts` without `allow-same-origin` gives the page an opaque origin (`self.origin` is `"null"`; `document.cookie` and `localStorage` throw `SecurityError`), so a script in the page cannot read or call sala's API;
`connect-src 'none'` closes `fetch`, XHR, WebSocket and beacons as well. Inline scripts and styles, `data:` images and Google Fonts work. The service worker has no fetch handler, so it never touches `/mockup/`.
`tests/test_mockup.py` checks the route and the headers and drives a real headless Chromium through a page that tries to reach the API, read the cookie and open a socket, and renders the page at a 390 px phone width.
A page should carry `<meta name="viewport" content="width=device-width, initial-scale=1">`; the server sends the file as it is and changes nothing in it.

## Install as an app

The page is an installable web app (on Android Chrome it installs as an app, not as a shortcut). What makes it one:

- **A web app manifest**, `static/manifest.webmanifest`, served at the site root as `/manifest.webmanifest`
  (`application/manifest+json`, `Cache-Control: no-cache`): name and short name `sala`, `start_url` and `scope`
  `./` (relative, so the app is the whole site whatever host serves it), `display: standalone`, the dark theme's page
  background (`--bg` in `style.css`) as `background_color` and `theme_color`, and the icons below. The page links it
  with `crossorigin="use-credentials"`: behind an access proxy the manifest is fetched with the proxy's cookie;
  without it the fetch gets the login redirect and Chrome sees no manifest, hence no install.
- **Icons** under `static/icons/`: `icon-192.png` and `icon-512.png` (purpose any, rounded corners),
  `icon-512-maskable.png` (full-bleed, the glyph inside the 80% safe zone, for Android's own icon shapes) and
  `apple-touch-icon.png` (180). Stackshot's recipe: its dark tile, `#1f1f21`, with sala's `>_` glyph in its orange,
  `#f0a06a`, at the same heavy line (4 of 32, stackshot's 8 of 64), fixed in `tools/make_icons.py`; the inline tab icons in
  `index.html` and `terminal.html` carry the same colours and weight. Why: the two apps' icons read as a pair. The
  underscore starts at x=18 of 32 (it was 17) so the heavier line does not run into the chevron at 16 and 20 px. The
  full-bleed tile (`#1f1f21`) sits on the manifest's splash colour (`#161617`, the dark page) as a slightly lighter
  square. To redraw them (after a change of the glyph), in `web/`: `uv run --no-project --with pillow tools/make_icons.py`; Pillow is
  pulled in for that one command and is not a dependency of the app. Commit the PNGs it writes.
- **A service worker**, `static/sw.js`, served at the root as `/sw.js` (a worker controls only what is under the path
  it is served from; `text/javascript`, `no-cache`) and registered by `app.js` once the page has loaded (feature-
  detected; a refused registration changes nothing). It has **no `fetch` handler and no cache**: it intercepts
  nothing, so the browser fetches as if no worker were there. Current Chrome does not need a handler for its install
  prompt. A worker that passes every request through with `fetch(req)` can fail: Chrome's private-network rules block that fetch
  in an app window installed while the host resolved to a public IP and later resolved to a private address (ERR_FAILED; a hard reload,
  which skips the worker, works). Only `install` (`skipWaiting`)
  and `activate` (`clients.claim`) remain, so a changed `/sw.js` replaces the old worker and takes over every open
  client at once. `tests/test_installable.py` holds that there is no fetch listener.
- In `index.html`: `<link rel="apple-touch-icon">`; two `<meta name="theme-color">`, one per colour scheme (`media=`),
  each the theme's `--bg`, since Chrome colours the installed app's status bar and the strip behind Android's gesture
  bar from it (with the manifest's single light colour, dark mode showed light bars); the
  manifest's `background_color` and `theme_color` are seen on the launch splash screen only, and a manifest has no
  per-scheme variant, so they are the dark theme's `--bg` (a light splash was the same light strip), while the two metas still give each scheme its own bars once the page loads;
  `viewport-fit=cover` in the viewport meta, so the page draws to the screen's edges, with the composer, the sidebar
  and `#main` padded by `env(safe-area-inset-*)` in `style.css`; `<meta name="color-scheme" content="light dark">`
  and `html, body { background: var(--bg) }`, so nothing light shows behind the dark page before its stylesheet
  lands, behind an overscroll or while the keyboard resizes the view.

Chrome's installability criteria it meets: a manifest with a name, icons of 192 and 512 (one maskable), a start URL
inside the scope, standalone display, and served over https (a proxy in front). (A worker with a fetch handler was once part of
that list; it is not any more, see the service worker above.)
`tests/test_installable.py` checks the manifest, the icons, the worker and the page's links; Chrome's own verdict
(`Page.getInstallabilityErrors` over the DevTools protocol against a local instance) is "no errors". In Chrome on Android the app appears under the menu's "Install app" (or "Add to Home screen" → Install); on a
desktop Chrome, DevTools → Application → Manifest shows what it parsed and any installability error.

## The shell drawer

A small console at the bottom of the page, opened and closed with a button. A
terminal on the host under every page, one click away, for the quick command that does not need a Claude session.

**The button.** *Shell* (a terminal icon and the word) is the last button of the header's cluster, on every page (the
session view, the Overview, the New session page, a lane's page). Its `aria-expanded` follows the drawer, it has the active
style while open, its title is "Shell on <host> (Ctrl+`)", and Ctrl+` toggles the drawer when the focus is not in a text
field. On a phone the word goes and the icon stays, 44 by 44 px. In the DOM it sits just before the ⋯ button and is drawn
after it (`order` in `style.css`), so Tab from ⋯ goes into the menu that follows it. Where the name does not fit it **folds
into the ⋯ menu as the first item**: a "Shell" row with the icon and the word, the same button and the same
handler, so the state stays in step; a tap on the row closes the menu and toggles the drawer, and closing the drawer from
inside returns the focus to ⋯. Activated from the keyboard, the row (like the Reload row) puts the focus back on ⋯ when it
closes the menu; a wide screen's drawer then takes the focus into its terminal once the frame has loaded, unless the drawer
was closed by then or the focus is in a text field. The layout pass moves a header item only when it is not already in its
place, so a focused Shell or Reload button keeps its focus when the window is resized or the badge changes. On the Overview
and the New session page, where the menu is hidden, the button stays in the bar.

**The drawer.** `#shell-drawer` sits at the bottom of the main pane, under the chat, and the composer moves up above it.
A handle on its top edge (a 44 by 4 px bar, `ns-resize`) is dragged to resize it, or focused and moved with the arrow keys; the
height is kept in `api/prefs` as **`shellHeight`** (120 to 4000, default 300), so it follows the owner across
browsers; the drawer is never taller than 75 percent of the visible page. Its header holds "Shell", a chip
"<this machine's short hostname> · <SALA_SHELL_SESSION>" (both from `GET /api/config`: `host`, `shellSession`), a note line for a failure, **Open full size** (`/terminal?arg=<SALA_SHELL_SESSION>` in a new tab: the full-size page below) and a
close button. Closing never ends the shell: the bash keeps running in its tmux session and the next open attaches to it
again. **Whether it is open** is kept per browser in `localStorage` (a key of its own), not in `api/prefs`: it stays across
page loads and across switching session, and a second device starts with its own choice. A phone gets the same
drawer as a **bottom sheet** (`@media (max-width: 760px)`): over the chat with a dim backdrop (a tap on it closes), a grab bar, a
16 px top radius, about 60 percent of the height, a **Close** button of at least 44 px, and no *Open full size* link.

**The terminal.** The sheet embeds the same ttyd the Terminal view uses, as an iframe of `state.terminalUrl` plus
`SALA_SHELL_SESSION` (`/tty/?arg=<SALA_SHELL_SESSION>`, with `allow="clipboard-read; clipboard-write"` and `hookTerminalClipboard`, like
`loadTerminal`). The iframe is made the first time the drawer opens, not at page load. `ttyd-tmux-attach` only attaches to a
session that exists, so each open first posts **`POST /api/shell/open`**, which makes the tmux session when it is missing
(`new-session -d -s <SALA_SHELL_SESSION> -c ~ bash -l`: a plain login shell in the home directory of the user sala-web runs as,
under a lock; `created` in the reply is true when it had to) and a created session rebuilds the frame (the shell had
ended). The app makes the session on demand instead of a user unit: a unit is not copied by a deploy (it needs `install.sh` or a
copy by hand), and would not bring the session back after a tmux server restart; making it on demand needs nothing outside
the checkout.

**The key row (phone).** A soft keyboard has no Esc, Tab, Ctrl or arrows, so the sheet has a row under the terminal:
Esc, Tab, Ctrl (sticky: it applies to the next key and clears), up, down, Ctrl+C, each at least 44 px wide and 40 high.
A button posts **`POST /api/shell/keys`** `{"key": "<name>"}`; the server runs `tmux send-keys -t =<SALA_SHELL_SESSION>: <name>`
for a name on a fixed allowlist (`Escape`, `Tab`, `Up`, `Down`, `Left`, `Right`, `Enter`, `BSpace`, `C-a` to `C-z`), never
free text: any other name is 400 with nothing sent, a missing session 502, a cross-origin post 403 and anything but
`application/json` 415, like the other POSTs. Sticky Ctrl sends the matching `C-<letter>` for the next letter typed in the
terminal on a soft keyboard where the browser reports it (best effort); the row's own buttons always work.

**Not a Claude session.** The shell session is excluded everywhere a session list is made: `read_live_sessions` (so not in
the sidebar, the Overview or the project groups) in `sessions.py`; and in sala's shell code
sala-web reads `SALA_SHELL_SESSION` once, when it starts, so it must be restarted (`systemctl --user restart sala-web.service`) after that setting changes; it reads `SALA_TZ` on each call (cached by the config file's modification time), so a change there shows without a restart.

`SALA_SHELL_SESSION` (`lib/common.sh`, default `sala-shell`; `config.py` `SHELL_SESSION` reads the same setting, from sala-web's environment and, when that has none, from sala's config file, same default; `GET /api/config` tells the page the name, so no name is written into the page):
`no_relaunch` treats it as managed outside sala (revive, restore, the lane move, watch's relaunch and the reboot leave it
alone), the revive sweep drops it with no summary row, and `spawn --list`, the lane lists and `adopt` leave it out or
refuse it. Stackshot's session sync reads the registry of Claude sessions, not tmux, so it never sees it.

**Tests.** `tests/test_shell_backend.py` (the endpoints and the exclusions, on a private tmux server and an isolated HOME),
`tests/test_shell_drawer.py` (the page in a headless browser: button, drawer, remembered state, height saved, the key row,
the phone sheet), `tests/test_prefs.py` and `tests/test_header_layout.py`; sala's side in `tests/smoke.sh`.

## The screen's height

The shell, `#app`, is as tall as the part of the page on the screen: `app.js` ("the shell's height" section) sets
`--app-h` on `<html>` to `visualViewport.height` on every resize and scroll of the visual viewport, resize of the
window and return to the page, and `style.css` sizes `#app` (and the sidebar at a phone's width) from it, `100dvh`
without the script. The composer, the sidebar and `#main` pad the safe-area insets (`viewport-fit=cover` above), so
the compose row sits above the gesture bar. The keyboard shrinks the visual viewport the same way
(`interactive-widget=resizes-content` in the viewport meta: the keyboard resizes both viewports, which keeps the
composer above it and the visual viewport unscrolled); a pinch-zoom shrinks it in CSS pixels without hiding anything,
so above scale 1 the variable is dropped and `100dvh` holds.

Why not `100dvh` alone (seen on Android Chrome): right after a keyboard
image paste and the keyboard's close, the composer's lower half (the paperclip, the send button, the model line) sat
under the screen's bottom edge for a while with nothing changed. `100dvh` and
`innerHeight` are the layout viewport, which Chrome on Android brings up to date only once its own bars (the address
bar; the strip it draws over the gesture bar, which it hides while the keyboard is up) have finished showing or
hiding, and not on every frame of the change; after the keyboard's close it can stay at the taller, bars-hidden height
while the bars are back, and a page that cannot scroll gives it no scroll to lay out again on. The visual viewport is
what the browser draws, kept current through those transitions. Sources: the Chrome blog on the keyboard's resize
behaviour (`interactive-widget`), Chrome's edge-to-edge migration guide (`viewport-fit=cover`, the dynamic
`safe-area-inset-bottom`), MDN's Visual Viewport API ("what is actually visible on the screen") and viewport units
(the dynamic viewport's size "is not stable"), web.dev on viewport units ("updating is throttled as the UA UI expands
or retracts").

`tests/test_composer_fit.py` drives the keyboard (both viewports shrunk, a chip row pasted, both restored), a bar
(a shorter layout viewport) and the stale state (the visual viewport shorter than the layout viewport, staged by
shadowing `visualViewport.height`: the protocol cannot produce it) in a headless Chromium, and checks the composer's
box against the visible area at each step; a gesture bar, Chrome's insets and its transitions are a
phone's to show. **The check on the phone**, in a Chrome tab and in the installed app, each: open a session, tap the
composer (keyboard up: the composer whole above the keyboard, the chat still showing), paste an image from the
keyboard (a chip row above the input, still whole), close the keyboard with the back gesture (the composer whole above
the gesture bar, the model line under it visible), scroll the chat up and down (the same), switch to another app and
back (the same), rotate and back (the same). With `?debug=timing` on, every step leaves `viewport` lines in the
timing log; a `compBottom` above `vvH` there is the cut-off caught.

## Hosts

The app is served at whatever address its deployment gives it, e.g. **https://sala.example.com** (an ingress sends the host root to the app's socket and `/tty/` to ttyd, behind one
access-proxy application). It has no host list of its own:
whatever `Host` a request carries is served the same way, a navigation is never redirected, and a POST or PUT is
accepted when its `Origin` matches the Host it came in on. `tests/test_hosts.py` covers each case.

## Data sources

| What | Where |
|---|---|
| Live sessions | `~/.claude/sessions/<pid>.json`; entries whose pid is gone (or reused, by `procStart`) are skipped. **One row per session, also for a conversation moved into a background job** (the CLI's "← for agents" view): the pane's claude stays as a viewer (`status` always `shell`, `parkedJobId` = the job's short id) and a second row, `kind` `bg` with that `jobId`, holds the live conversation under the same name. They are folded (`sessions.py` `read_live_sessions`, `job_row`): the pane's row carries the identity (name, tmux, pid), its status is the job's (working / idle / needs input), its `sessionId` is the job's (the transcript, the model and the spend are read from the live conversation), and the job's row is not listed. `/api/sessions` and the Overview carry `parkedJob` (the job id) on such a row only; the Overview's status cell shows the job's status and, beside it, `in background job eeeeeeee`, and the sidebar row's tooltip says the same. A job with no viewer row (the pane's claude gone) stays listed as its own session. `tests/test_parked_sessions.py` |
| Roles, projects | `python3 $SALA_STACKSHOT_DIR/stackshot/fleet/client.py get roles` (`~/stackshot` when unset; empty = no stackshot: no command, `rolesError` says so), cached 30 s; on failure the last good answer is kept |
| Board items | stackshot's client API, `GET <client.url>/client/items?key=<session name>` with the bearer token from `$XDG_CONFIG_HOME/stackshot/client.token`, one read per live session a minute, the last good answer kept per session (*Board items*) |
| Mockup pages | `$SALA_STATE_DIR/mockups/<n>.html` (default `~/.local/state/salamander/mockups/`), written by `sala mockup add`, read at each request; nothing is cached or listed |
| Transcript | `~/.claude/projects/<cwd, every non-alphanumeric char as ->/<sessionId>.jsonl`, falling back to a glob on the sessionId |
| For you (no page reads it now) | stackshot's client API with the same token and address: `GET <client.url>/client/for-you` (the list and the flags, one read a minute), and on a tap `POST /client/for-you/seen` and `POST /client/items/<key>/watch`, always with the label `sala-web`; kept in memory only; `docs/stackshot-contracts.md`, interface 22 (*For you*) |
| Projects (the New session form) | stackshot's client API with the same token and address as the board items: `GET <client.url>/client/projects?scope=…[&q=…]` (the scope's listed projects, and with `q` its hidden matches), and on Create `POST /client/project` (a new project and its page), `/client/project-list` and `/client/project-agent`, always with the label `sala-web`; these are `client.py get projects` and `post project`, `post project-list`, `post project-agent`; `docs/stackshot-contracts.md`, interface 21 |
| Project pages (the old project list; `GET /api/spawn/options` still sends it, the form does not read it) | stackshot's pages checkout: `[paths] brain` and `[pages] dirs` from `$XDG_CONFIG_HOME/stackshot/stackshot.toml` (a local mirror of the pages; `projects` among the dirs), every `<dir>/**/*.md` but a README and a `type: redirect` or `archive` stub, the key and the frontmatter's title only, read-only, cached 30 s (*New session*) |
| Scheduled jobs (the Schedules tab) | `systemctl [--user] list-timers --all --output=json`, `systemctl [--user] show` per timer and service and `cat` for all the units of a scope at once, `crontab -l`, and `git -C <dir> rev-parse / remote get-url / symbolic-ref` for the links; all read-only; `cat` is one call per scope, and a reading is kept for 30 s before the next request has it read again (*Schedules*) |
| Machines (the Machines tab) | read-only files, once per request: `site/versions.json`, `clients/fleet/<letter>/machine.json` and `clients/advertised-commit` under the stackshot state folder (the cards), the fleet names file and `[machines_panel] ssh_hosts` / `[fleet] publisher_letter` in `stackshot.toml` (the names and their order), a follow list `machines.toml` and `<host>.json` under the follow state folder (each card's last line). No network call, no command, nothing written (*Machines*) |
| Transcripts (the Search page) | `~/.claude/projects/**/*.jsonl` (the `claude_dir` setting), opened read-only at each search and only when modified inside the range; the agent's permanent id and name from sala's `sessions.json`, the role from the registry or stackshot's roles (*Search*) |
| An operation's state (the New session form) | sala's own marker, `$XDG_STATE_HOME/salamander/ops/<id>.op`, then `ops/done/`, read-only |
| Model, effort (the Overview) | what the pane runs now: the claude process's own `--model` and `--effort` (`/proc/<pid>/cmdline`; sala puts both on every resume line), else sala's record for the tmux session (`$XDG_STATE_HOME/salamander/models.tsv`, read-only), else the transcript's latest reply, else (a session on the default model that sala's idle wrap-up cleared) the CLI's default: `~/.claude/settings.json`'s `model` and its effort, the same read the New session form's "use default (<value>)" does (`spawn.claude_defaults`, once per poll; a lane with its own `CLAUDE_CONFIG_DIR` may follow another file, so this is the default lane's). The row's `modelSource` is `launch`, `record`, `reply`, `alias` (a resolved bare alias) or `default`, and `effortSource` (`launch`, `record`, `reply`, `default`) says where the effort came from. The default effort is that of the default model's family, so it is taken only when the model is the default one or of the same family (a `--model opus` resolved to `claude-opus-5-5` is of opus; a sonnet pane under an opus default keeps `not set`). A pane whose environment sets a `CLAUDE_CONFIG_DIR` other than the default lane's gets no default at all (its settings file may differ). The page writes `(default)` beside a default one. A default `settings.json` cannot give is blank, as before (`no reply yet`, `not set`). A bare alias (`opus`) takes the latest reply's full id when that reply is of the same family and newer than the process (the registry's `startedAt`), else shows as `Opus`; a default that is a bare alias is resolved the same way (`modelSource` stays `default`, `modelAlias.from` is `default`) |

An image a session sends (`SendUserFile`) is read from the file the transcript names, under `$HOME` or `/tmp/claude-<uid>`,
only through `/api/file-image`, and an image a reply names in its markdown (`![caption](/abs/path.png)`) only through
`/api/md-image`, from the path in that reply's own text (*What it can and cannot do*).

The transcript parser shows `user` and `assistant` lines, prompts queued while busy (`queued_command`
attachments), and messages from other sessions (as folded notices). It skips meta lines, system reminders,
sidechains, compact summaries and every other line type. The first load reads backwards from the end of the file
(transcripts can be very large), then the SSE stream tails it.

## Run

```sh
uv sync --frozen                   # in web/ of a checkout
uv run sala-web                     # serves on $XDG_RUNTIME_DIR/sala-web/sala-web.sock
curl --unix-socket "$XDG_RUNTIME_DIR/sala-web/sala-web.sock" http://x/api/sessions
```

It listens on a unix socket only, never a TCP port: it has no auth of its own (an access proxy in front of it
is the auth), and a loopback port would let any local user, such as a CI runner's, type into Claude panes.

Settings (environment):

| Variable | Default |
|---|---|
| `SALA_WEB_SOCKET` (or `--socket`) | `$XDG_RUNTIME_DIR/sala-web/sala-web.sock`. Also read from sala's config file. Pins the socket path: `../install.sh --web` writes it as `sala-web.socket`'s `ListenStream=` (the path the app is handed under socket activation), and a manual run binds it |
| `SALA_WEB_STATE_DIR` | `$XDG_STATE_HOME/sala-web`. Also read from sala's config file, where sala's watch reads the same setting (`quota-<lane>.json`) |
| `SALA_WEB_COMPAT_SOCKET` | empty. An old socket path the app links to its own socket at start, when the path's parent directory exists (*Renamed units*); written by the migration only |
| `SALA_WEB_COMPAT_TTYD_SOCKET` | empty. The same for ttyd's old socket path, linked to `SALA_WEB_TTYD_SOCKET` |
| `SALA_WEB_TTYD_SOCKET` | `$XDG_RUNTIME_DIR/sala-web-ttyd/ttyd.sock`: where `sala-web-ttyd.service` listens; only the old ttyd path's link points at it |
| `SALA_WEB_CLAUDE_DIR` | `~/.claude` |
| `SALA_WEB_TMUX_SOCKET` (or `--tmux-socket`) | empty = the default tmux server; tests use a private `-L` name |
| `SALA_WEB_ROLES_CMD` | `python3 $SALA_STACKSHOT_DIR/stackshot/fleet/client.py get roles` (`$SALA_STACKSHOT_DIR/client.py` on a checkout from before stackshot's package) |
| `SALA_STACKSHOT_DIR` | `~/stackshot`: where stackshot's checkout is, sala's one knob for it (`config.example`). Read from the environment here, not from sala's config file, so a unit that needs another path sets it in its own `Environment=`. Set empty on a machine with no stackshot: no roles command |
| `SALA_WEB_SALA_MODELS` | `$XDG_STATE_HOME/salamander/models.tsv` (sala's model record; missing or unreadable = none) |
| `SALA_WEB_TERMINAL_URL` | `/tty/?arg=` (ttyd on the same host, `--base-path /tty`; the tmux session name is appended) |
| `SALA_WEB_STACKSHOT_TOKEN` | `$XDG_CONFIG_HOME/stackshot/client.token`: stackshot's client token file, sent as the bearer and never kept or logged (*Board items*) |
| `SALA_WEB_STACKSHOT_URL` | `$XDG_CONFIG_HOME/stackshot/client.url`: the file with stackshot's server address; `STACKSHOT_URL` in the environment wins, as for stackshot's own client |
| `SALA_WEB_STACKSHOT_WEB` | the board as a phone reaches it; an item's page is `<this>/items/<n>`. Unset: `[instance] board_url` in `~/.config/stackshot/stackshot.toml`, else empty, and an item in `api/board-items` carries no link. Set to an empty string to turn the links off |
| `SALA_WEB_SALA_CMD` | `sala`: the command the New session form queues through (`<this> op spawn …`, `<this> spawn --suggest-name …`), split on spaces; a bare name is looked for on PATH, then at `~/.local/bin/sala` and `~/salamander/bin/salamander` |
| `SALA_WEB_SALA_STATE` | `$XDG_STATE_HOME/salamander`: sala's state, where the queue's markers are read (`ops/<id>.op`) |
| `SALA_WEB_STACKSHOT_STATE` | `[paths] state` in `stackshot.toml`, else `$XDG_STATE_HOME/stackshot`: stackshot's state folder, where the Machines tab reads `site/versions.json` and `clients/fleet/<letter>/machine.json` (*Machines*) |
| `SALA_WEB_FLEET_NAMES` | `[paths] fleet_names` in `stackshot.toml`, else none: the fleet's names file (a TSV of OS hostname, fleet name, board letter) that gives the Machines tab its names |
| `SALA_WEB_MACHINE_FOLLOW_MACHINES` | a `machines.toml` beside the names file's folder, else none: the list of machines that follow another (`run_on`, `[machines.<host>]`), read for each card's last line |
| `SALA_WEB_MACHINE_FOLLOW_STATE` | a state folder under `$XDG_STATE_HOME`: the folder of per-machine records (`<host>.json`, `at_epoch`) |
| `SALA_WEB_BRAIN_DIR` | stackshot's `[paths] brain` (a local mirror of the pages): the pages checkout the project list is read from |
| `SALA_WEB_PAGE_DIRS` | stackshot's `[pages] dirs` (`projects` among them): the page folders, space- or comma-separated |

## Install as a user service

```sh
# in ~/salamander/web, the production checkout (a deploy keeps the venv synced from here on)
uv sync --frozen
install -m 644 contrib/sala-web.socket contrib/sala-web.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now sala-web.socket
systemctl --user enable --now sala-web.service
```

The socket is systemd's (socket activation): `sala-web.socket` creates `%t/sala-web/sala-web.sock` (mode 0600, in a
0700 directory) and hands it to the service as fd 3. Because systemd holds the socket, it outlives every restart of
the service: requests that arrive while sala-web restarts wait in the kernel backlog and are answered by the new
process, so the proxy never finds the origin down. The service has no `RuntimeDirectory=` (it would delete the
directory, and the socket with it, on every stop). Both units are enabled: the service starts at boot rather than on
the first request, and the socket would start it on demand if it ever stopped. A manual run (`uv run sala-web`) binds
its own socket at `--socket` and refuses a path something is already serving on.

**The service runs from the production checkout of the salamander repo.** `ExecStart` is
`%h/salamander/web/.venv/bin/sala-web`, and `static/` is served straight from `~/salamander/web/src/sala_web/static/`,
so a frontend change is live in the owner's browser at its next reload the moment a deploy fast-forwards `main`, before
the restart (Python changes wait for it). Nothing is edited in `~/salamander` itself: a change is a branch in a
worktree (`../CONTRIBUTING.md`). A deploy does not install a changed unit under `contrib/`: copy it into
`~/.config/systemd/user/`, `daemon-reload` and restart by hand.

**On another machine**, `../install.sh --web` does the copying: it writes `sala-web.socket`, `sala-web.service` and
`sala-web-ttyd.service` into `${XDG_CONFIG_HOME:-~/.config}/systemd/user/`, with this checkout's path in their `ExecStart=`
lines (the units in `contrib/` assume the checkout is `~/salamander`; `--web` writes `%h/<path>` for a checkout elsewhere under
your home, or the absolute path outside it). It starts and enables nothing: it prints `uv sync --frozen`, `daemon-reload`,
`enable --now` for the three units and `loginctl enable-linger`. `sala-web-ttyd.service` is ttyd for the Terminal tab and the
Shell drawer at `/tty/` on its own unix socket, and `contrib/sala-web-ttyd-attach` is what it runs per tab. Neither the app nor
ttyd has a login: `../docs/web-proxy.md` puts HTTPS and a login in front of both (a Caddy example and a
tunnel one), and states the rule that neither socket is ever reachable without one.

## Renamed units

The package, the command, the three units, the socket paths and the state directory once had an older name; they
are sala-web now (`sala_web`, `sala-web`, `sala-web.socket`, `sala-web.service`, `sala-web-ttyd.service`,
`$XDG_RUNTIME_DIR/sala-web/sala-web.sock`, `$XDG_RUNTIME_DIR/sala-web-ttyd/ttyd.sock`, `$XDG_STATE_HOME/sala-web`). The page a
user sees did not change (its title and every text and attribute it shows), apart from the name of the version `<meta>`.

An install that still runs the units under the old name is migrated by `../deploy.sh` (its web step), by `../install.sh --web`
and by a plain `../install.sh` (which the deploy that brings this change runs, because `install.sh` changed). The code is
`../lib/webunits.sh`; it finds the old units by what they are (a service `X.service` whose `ExecStart=` runs
`<checkout>/web/.venv/bin/X` and that `Requires=X.socket`), never by a name written in the repository:

1. the venv is synced when it has no `sala-web` command yet;
2. the three new units are installed;
3. each old unit is stopped and disabled, its file kept as `<file>.migrated`, and the file replaced by a symlink to its new
   unit: an alias, so `systemctl --user restart X.service` (the previous `deploy.sh`'s web step, which still runs during the
   deploy that brings this change) restarts `sala-web.service`. Every `*.conf` of an old unit's drop-in directory
   (`X.service.d`, `X.socket.d`, `X-ttyd.service.d`) is copied into the new unit's (`sala-web.service.d`,
   `sala-web.socket.d`, `sala-web-ttyd.service.d`) unless a file of that name is already there (then it is left, and a line
   says so), so a drop-in such as an `AssertPathExists=` keeps applying to the renamed unit. The old directories stay in
   place; systemd reads drop-ins by the unit's own name, so they no longer apply to the alias's target and nothing else reads them;
4. the old state directory `$XDG_STATE_HOME/X` is moved to `SALA_WEB_STATE_DIR` when that does not exist yet (both existing:
   both are left, and a line says so);
5. when the old socket paths differ from the new ones, the drop-in `sala-web.service.d/old-socket-path.conf` sets
   `SALA_WEB_COMPAT_SOCKET` and `SALA_WEB_COMPAT_TTYD_SOCKET` to them and recreates their parent directories at each start
   (they live in `$XDG_RUNTIME_DIR`, which a reboot empties). At start the app makes each old path, when its parent
   directory exists, a symlink to the socket it stands for, so a proxy that still points at the old app socket or the old
   ttyd socket keeps working; a stale socket file left there by the old unit is replaced, anything else is left alone;
6. `daemon-reload`, then each new unit enabled when its old one was enabled and started when its old one was running.

A second run finds no old unit and changes nothing. The old command `<checkout>/web/.venv/bin/X`, which tooling outside this
repository may run directly, is kept for one release as a symlink to `sala-web` (the repository carries no instance name, so
`pyproject.toml` cannot name it): the migration makes it, and so does every later web step (`../deploy.sh`, `../install.sh --web`)
while the old units exist as aliases, when that path does not exist (`uv sync` rebuilds the venv without it).
The proxy (`../docs/web-proxy.md`) is not touched: point it at the new socket paths before the next release.

**Dropping the compatibility** (the release after): delete `old-socket-path.conf`, the copied drop-ins of the old units, the
old command's link in `web/.venv/bin` and the alias symlinks `X.socket`,
`X.service`, `X-ttyd.service` (and the `.migrated` copies) from `~/.config/systemd/user/`, `daemon-reload`, restart
`sala-web.service`, and remove the stale links at the old socket paths; in the code, `compat_socket`, `compat_ttyd_socket`
and `ttyd_socket` in `config.py`, `link_compat_sockets` and `_bound_path` in `app.py`, and `web_legacy_name`, `web_legacy_alias_name`, `web_legacy_cmd_link`, `web_migrate`
and their calls in `lib/webunits.sh`, `install.sh` and `deploy.sh` go, with their tests.

## Deploying

A change takes the salamander repo's path (`../CONTRIBUTING.md`): a branch in a worktree of the repo, the checks
below run in its `web/`, a PR against `main`, and `release.sh <pr>`, run by the releaser, which waits for CI, merges
and runs `deploy.sh` in the production checkout. For a file under `web/` the deploy fast-forwards `main` (static/ is
live from here on), runs `uv sync --frozen` in `web/` and restarts `sala-web.service` (the restart drops no request:
the socket is systemd's). CI, the `web` job of `.github/workflows/tests.yml`, runs the same checks for a change
under `web/` and none of sala's suites; a change outside `web/` runs none of these.

```sh
# in the worktree's web/, before the PR:
uv sync --frozen && uv run --frozen pytest
find src -name '*.js' -not -path '*/vendor/*' -print0 | xargs -0 -n1 node --check
```

What open browser windows see:

- **The server's build version** is the newest mtime under `static/` plus the commit the process started from
  (`GET /api/config` → `version`; the first event of every SSE stream, `event: version`; and a `<meta>` in the page).
  A fast-forward rewrites the changed static files, so even a static-only deploy, live without a restart, changes it.
- **The page** compares it with the version it loaded, at the start of every stream, every 60 s, and when the tab
  comes back into view or gets focus. A newer build shows a strip at the top, "sala was updated. Reload". The page
  reloads by itself only when nothing can be lost: the tab is hidden, the composer is empty, and no upload or unsent
  message is pending (at most once a minute per tab, so it cannot loop). The composer's text is kept in
  `localStorage` per session across any reload and put back after it (*Back*; attached images are not).
  The header carries a Reload of its own (an icon in the bar, a row in its ⋯ menu once the session name needs the room, *The header* above),
  always there, because the installed app has no browser bar to reload from; it takes the same path as the banner's button, the draft stored first, and a plain reload
  brings the current build (the static files are served `no-cache` and the worker never caches).
- **A static file that failed to load** is asked for again by the page itself, with no reload. A request a phone's network drops never reaches
  the server, and a stylesheet or script that fails is skipped without a word (the side panel's search box came up unstyled, with no
  Colors button, until a reload). `index.html` opens its head with a small inline script (so it hears every failure, whatever fails after it):
  a failed `static/*.css` or `static/*.js` of the page, or at load a stylesheet that has no sheet, or the color tool's two scripts with no tool
  (`ColorTool`, `SalaColors`), gets a copy of its element put where it stood (the cascade order holds, and a copy never lands after the look's
  `<style>`) with a cache-busting `&r=<time>`, 0.3 s, 0.6 s, 0.9 s and 1.2 s after each failure: at most 4 tries per file, then it stops
  (a file that is really gone costs 5 requests, not a loop). The checks run at the page's `load` and again 4 s and 12 s after the markup was
  read; a file that loaded is never asked for twice. A recovered color tool starts its own button (`SalaColors.init()`, which the end of the
  body had skipped; it is safe to call twice). Only the main page does this: `terminal.html` has no panel. `tests/test_asset_recovery.py`
  stages the failure (aborted and 404) and holds that the file comes back, the box is styled, the button is drawn once,
  and nothing reloads.
- **During a restart** the SSE stream ends (uvicorn ends streams at once on SIGTERM and gives an in-flight send up to
  8 s), the page shows a quiet "Reconnecting…" in the header if the gap lasts past 800 ms, and EventSource reconnects
  after 1 s (the server sends `retry: 1000`; if the browser gives up, the page reopens the stream, backing off to
  15 s). The reconnected stream's `reset` replaces the chat with the same tail: a view pinned to the bottom stays
  there, a view scrolled up keeps the message being read in place. GETs, the prefs PUT and uploads retry briefly on
  a network error or a 502–504 / 52x; a send is never repeated on its own (its bubble offers Retry).
- **The Terminal tab** (ttyd) does not depend on sala-web and is not reloaded on a version change.
- **Copy in the Terminal tab**: a selection made with the mouse is tmux's (`mouse on`), and tmux (`set-clipboard on`)
  hands it to the terminal as OSC 52. ttyd 1.7.7's page has no handler for OSC 52, so the app registers one on the frame's
  `window.term` (same origin; `hookTerminalClipboard` in termclip.js, polled for 10 s after the frame loads, again when it reloads)
  and writes the decoded text with `copyText`; `?` queries and empty or invalid payloads are ignored. Any program in the pane
  can set the clipboard this way, as with tmux itself. Held Shift while dragging, xterm.js makes its own selection and tmux
  does not see the mouse (xterm.js's rule off macOS); copying that selection is the browser's, not this code's, and untested
  here. A ttyd that is not on the same origin is left alone.
  Where it lives: `static/termclip.js` (loaded by the main page and by the full-size page; `copyText`, `hookTerminalClipboard`).
  **Three views have it:** the Terminal tab, the Shell drawer, and the **full-size page** (`GET /terminal?arg=<tmux session>`,
  `static/terminal.html` and `terminal.js`): ttyd's page in a frame that fills the window, hooked like the other two. The drawer's
  "Open full size" link and the old `/?arg=<session>` links (a redirect to `/terminal?arg=...`) open it, in place of ttyd's bare
  `/tty/` page, which has none of this code. The proxy sends only `/tty` to ttyd and everything else, `/terminal` included, to the
  app, so the one login that covers `/` covers the page (`../docs/web-proxy.md`); the frame is the same `/tty/` (the address in
  `GET /api/config`). A person who types `/tty/?arg=...` into a tab by hand still gets ttyd's bare page.
  **A long drag** (a selection longer than the drawer, holding the mouse at the edge while the pane scrolls): Chrome lets a page
  write the clipboard only within about 5 s of a click or key press, counted from the mouse-down, and the OSC 52 sequence of a
  drag that took longer arrives after that. `copyText` then fails (both `navigator.clipboard` and `execCommand`), and the text,
  which used to be dropped without a word, is kept under a "Copy" button over the terminal (`offerTerminalCopy`;
  `.term-copy-offer` in `termclip.css`). A click is a fresh gesture, so the offer has no timer: it goes away on its click, when a
  newer selection replaces it, when a key is typed in that terminal (a keydown inside the frame), or when the frame loads another page.
  `tests/test_terminal_drag_copy.py` makes drags (quick, and slow with the button) and a Ctrl+V in all three views against
  ttyd, the full-size view opened from the drawer's own link.
- **Paste in a terminal** (all three views): Ctrl+V pastes on Windows and Linux (and Ctrl+Shift+V, and Shift+Insert as before; Cmd+V on a Mac).
  xterm.js turns every Ctrl+letter keydown into the control character (Ctrl+V is 0x16) and cancels the event, so the browser never
  fired `paste`; ttyd 1.7.7 attaches no key handler of its own. The same `hookTerminalClipboard` therefore attaches one with
  `term.attachCustomKeyEventHandler` (once per term, again for a reloaded frame): for the keydown of Ctrl+V, Shift allowed, no Alt
  and no Meta, it returns false, so xterm ignores the key without cancelling it and the browser's own paste reaches xterm's
  textarea (the handler never calls `preventDefault`); every other key, Ctrl+C included, still goes to the pane. On a Mac
  (`navigator.platform`) the handler lets everything through, as Cmd+V already pastes there. Trade-off: a literal ^V (vim's
  block-visual mode, the shell's quoted-insert) cannot be typed into the pane from the browser on Windows or Linux.
  `tests/test_terminal_ctrl_v.py` runs the handler against a fake `term`, and
  ttyd on a scratch tmux session (private socket) with key events, behind a small same-origin router.

Before the socket unit existed (`RuntimeDirectory=` in the service), a restart removed the socket and the proxy
showed its "origin is down" page until the new process bound it again.

Exposing it (an ingress to `$XDG_RUNTIME_DIR/sala-web/sala-web.sock`, a login, DNS) is not
part of `web/`.

## API

| Method, path | |
|---|---|
| `GET /` | the page |
| `GET /manifest.webmanifest` | the web app manifest (*Install as an app*), `application/manifest+json` |
| `GET /sw.js` | the service worker, at the root so its scope is the whole site; `text/javascript`, never cached |
| `GET /mockup/<n>` | a mockup page `sala mockup add` stored (*Mockup pages*); `text/html; charset=utf-8`, 404 for an unknown number, the sandbox headers on every response |
| `GET /sessions` | redirects to `/#sessions`, the Overview |
| `GET /api/config` | `terminalUrl`, the build `version` and the `commit`, `shellSession` (sala's `SALA_SHELL_SESSION`, default `sala-shell`), `host` (this machine's short hostname) and the time zone every time in the page is shown in: `timezone` (`SALA_TZ`, `""` = the viewer's own zone), `tzLabel` (the zone's abbreviation now: IST, CEST, UTC) and `tzOffsetMin` (its UTC offset in minutes now) |
| `GET /api/sessions` | live sessions as `scopes` → project `groups` → `sessions` (front agents first; a role other than front or back sorts after them); `Unregistered` last; also `groups`, the same projects as a flat list; every session carries `agentId` (sala's permanent id for the agent, from the registry `sessions.json`: the key of the saved order; absent when the registry has no row) and `aliases` (the names the agent had, only with `agentId` and when it has any), and `unread_count` (an integer, 0 to 10: the replies written since the owner last opened it, front agents only; 10 means 10 or more and the page shows 9+) and `unread` (`unread_count > 0`) (*The unread reply count*, *Sidebar*) |
| `GET /api/quota` | each account lane's (subscription-1, subscription-2) usage limits from Anthropic's usage endpoint, with the sign-in token read from the lane's `.credentials.json` (never refreshed, written or kept). Served at once from the last good answer per lane (`refreshing`, `pending` as for `/api/credit`), refreshed every 5 minutes in the background and kept in `state_dir/quota-<lane>.json` (a file an earlier version saved as `quota-max.json` or `quota-team.json` is read while the new one is not there; limits, plan, `fetchedAt` and a pending wait only). `fetchedAt` (epoch ms) is the last good reading and stays on the answer while refreshes fail; a lane the dormant record lists is `{lane, dormant, plan?, fetchedAt?}` with the `fetchedAt` of its saved answer, absent when it never answered (the card's last line, "updated 7 min ago"). A failed refresh keeps the lane's answer and adds `error` (plain words), `errorKind` and `nextTry` (epoch ms): `rate_limited` is a 429, tried again when its `Retry-After` says (seconds or an HTTP date, clamped to a minute and 3 hours), else after 2, 4, 8, 16, then 30 minutes; `failed` is another status, no network or an unreadable answer, after 1, 2, 4, 8, 16, then 30 minutes; `sign_in` is no sign-in on the lane or one expired, nothing sent, looked at again at the next poll. A success resets the series; each lane counts its own; the wait is saved with the answer (`nextTry`, `errorKind`), so a restart keeps waiting and sends nothing until it is over. |
| `GET /api/lane-names` | the lanes' display names as sala says them: `{"lanes": [{"code", "display", "aliases"}]}` (`lanenames.py`). Taken from `sala lane names --json` (4 s at most), else `lane-names.json` in sala's state directory, else the last good table this process had, else the codes alone (display = code); kept 60 s. This app holds no display name of its own; the page draws a lane's pill from here (`laneLabel` in `shared.js`, lower case). Read-only; no path, no secret |
| `GET /api/credit` | what the API key (metered and sdk lanes) spent in the `SALA_TZ` zone: `todayUsd`, `monthUsd` (with `today`, `month`), of which `todayEstimatedUsd` / `monthEstimatedUsd` priced from the hourly usage report for the hours since `estimatedFrom` that the Admin API's cost report (complete UTC days, exact; each day's amount shared over its hours by usage) does not have yet, through `usageThrough`; rates calibrated from the cost report (`unpriced` lists tokens with no rate). Served at once from the last good answer (`refreshing` while a background refresh runs; `pending` with no answer yet), refreshed at most every 15 minutes and kept in `state_dir/api-spend.json` (figures only). The key in `$XDG_CONFIG_HOME/anthropic/admin-key` is only sent as `x-api-key`. When the dormant record lists the api lane (sdk reads as api), the answer is the same and also carries `lane: "api"` and `dormant: {reason, since}`; a read that fails with nothing saved has `error` and no figures |
| `GET /api/lanes/<id>` | a lane's details page: `{lane, record, state, error}`. `record` is the lane's row of sala's lane table, from `sala lane --json` run at each request (read-only; 15 s at most): `id`, `label`, `provider`, `client`, `org`, `project`, `billing`, `payment`, `plan`, `account`, `credential` (how it signs in), `region`, `status`, each plain text, `""` for an empty field, with every file path taken out. `state` is `{state: active}`, `{state: dormant, reason, since}` (lane-state.tsv, read at each request; the sdk word reads as api), `{state: "not set up"}` (the table's status) or `{state: unknown}` (no record and not dormant). A table sala cannot print (not found, a non-zero exit, no JSON) is 200 with `record: null` and `error` in plain words, so the state still comes; 404 when the table has no such lane, 400 for a malformed id. Never cached by the browser; no credential or token is read |
| `GET /api/spend` | the aws-platform and bedrock lanes' month-to-date spend as an estimate at list prices, counted from this machine's transcripts (`spend.py`; nothing is asked of AWS or Anthropic): `month` (`2026-01`, UTC), `since`, `lanes`: `[{lane, configured, monthUsd, calls, models: [{model, usd, calls}], sessions: [{sessionId, name, usd, calls, share, live}], unpriced: [{model, calls, tokens}], unmatched: [name]}]`, `configured` from the lane table's status (null when sala cannot print it), `scannedBytes`, `sessionsRead`; a lane the dormant record lists keeps its entry and gains `dormant: {reason, since}` (before the first count it is just `{lane, dormant}`). Served at once from the last good answer (`refreshing`, `pending`, `fetchedAt`), counted in a thread at most every 5 minutes, kept in `state_dir/spend-aws.json` (figures, session names and times); a failed count (a plain `error`: sala's records or the transcripts folder unreadable) keeps the last answer and is tried again after a minute. The read cache is `spend-scan.json`, the live-lane sightings `spend-lanes.json` |
| `GET /api/schedules` | every scheduled job, from the server's last reading (*Schedules*; the same access as the other `/api` routes, held in memory only; a reading older than 30 s is read again in the background and the answer comes at once; `?fresh=1` makes it due now): `fetchedAt` (epoch ms the reading was taken), `refreshing` (true while a newer one is read), `pending` (true until the first reading exists; `timers` is then empty), `error`/`errorKind` (a read that failed; the last reading stays),  `generated`, `timezone` (the `SALA_TZ` setting, `""` = local time), `tzLabel` (the zone's abbreviation now), `timers` as `[{scope, name, service, description, summary (the description without a leading `name -`), project (the service unit's `X-Project=`, the job's Category, `null` when absent), runs: {command, script, line}, schedule: [the timer's On… lines as written], plain (the schedule in plain words, times in the `SALA_TZ` zone), next, last (each `{epoch, iso, text}` in that zone with its offset, e.g. `+04:00`, or `null`), result: {state: ok/failed/running/never/unknown, text}, lane (the service unit's `X-Model-Lane=`, `null` when absent), lane_note (its optional `X-Model-Note=`, `null` when absent), links: {script, service, timer} (GitHub, `null` when not in a GitHub-backed repo), rendered: {service?, timer?: {template, link}} (a unit whose first line is `# Rendered by <tool> from <template>.in`), unit_files, flags: [{code, text}]}]`, `cron` as `[{schedule, command, flags}]`, `counts` (`timers`, `cron`, `flagged`, `byReason`, `packaged`: the package-shipped timers left out of the list), and `scopes` (`user`, `system`: whether each could be listed without sudo). Flag codes: `failed`, `no-service`, `not-git`, `git-differs`, `no-lane`, `bad-lane`, `no-project`, `cron`. Never cached by the browser |
| `GET /api/machines` | the Machines tab, read from files at each request (*Machines*; read-only, nothing stored, `Cache-Control: no-store`, always 200): `generated` (epoch), `tzLabel`, `updated` (epoch of `site/versions.json`, the reading the footer dates, or `null`), `machines` as `{ok, reason, ts, cards: [{name, alert, rows: [{package, version, state (latest/update/offline/unknown), text}], alerts: [{kind (setup/update), detail, tip}], follow: {kind (publisher/follows/self/unknown), text, tip}}]}`. There is no `runners` key. Missing or unreadable files answer `machines.ok: false` with a one-line `reason`. No token or session name is ever in the answer. |
| `GET /api/usage/digest` | the Usage analysis tab's Digest view (*Usage analysis*, Digest; from the saved count of `GET /api/usage`, so no second scan and never a count of its own; `?week=0` (default), `1` or `2` and `?fresh=1` as there, anything else is a 400 `{error}`, `Cache-Control: no-store`): `week`, `now`, `generated`, `tz`, `tzLabel`, `resetKnown`, `scope` (the words that only this machine's sessions are counted), `range` (`startKst`, `endKst`, `end`, `current`; null before the first count) and `sentences` (1 to 7 plain sentences written by code). `noCount: true` with no sentences before the first count, `pending: true` (and `refreshing` with an older count on screen) while a Reload's count runs, `error` in words when a count failed (the last sentences stay). |
| `GET /api/usage` | the Usage analysis tab (*Usage analysis*; the last saved count, held in memory and in `usage-answer.json`, served at once whatever its age: the count is a daily job and the tab's Reload, never a visit; `?fresh=1` starts a count in a thread, or joins the one that runs; a newer file written by the job is read in; `Cache-Control: no-store`): `?week=0` (default), `1` or `2`, anything else is a 400 `{error}`. The answer: `week`, `now` (epoch s), `tz`, `tzLabel`, `resetKnown`, `anchor`, `generated`, `weeks` (`id`, `start`, `end`, `startKst`, `endKst`, `days`, `current`, `total`, `billed`, `replies` for all three), `lanes` (`code`, `label`, `billing`, `flat`, `known`, `quota` of the weekly limit when known), `fields`, `rows` (one per day, lane, model, project, agent and folder of the week asked for, as arrays in the order of `fields`: dollars, replies and the five token counts; the page shows dollars only), `sameHours` (week 0 only), `unpriced`, `prices` (`asOf`, `unit`, `models`). With no count made yet the answer is `{noCount: true}` (the tab says so and offers Reload); while a Reload's count runs it is `{pending: true}` (nothing on screen yet) or the last answer with `refreshing: true`; a failed count keeps the last answer and adds `error` in words. |
| `GET /api/usage/replies` | Explorer's drill-down (*Usage analysis*): `?week=0\|1\|2` (default 0), `&limit=<1..200>` (default and cap 200), and any of `day`, `lane`, `model`, `project`, `agent`, `folder` (a name repeated is a list of alternatives); anything wrong is a 400 `{error}`. The answer: `week`, `generated`, `tz`, `tzLabel`, `fields` (`time` KST, `day`, `lane`, `model`, `project`, `agent`, `folder`, `usd`), `total` and `usd` of everything that matched, `shown`, `capped`, `cap`, `rows` (the newest first). Computed from the same saved count (its records are saved in `usage-replies.json` by every count), so it is served at once, also after a restart, and starts no count; `{noCount: true}` when no count has saved its records yet, `{pending: true}` while a Reload's count runs. No text of a transcript, no token count. |
| `GET /api/search` | a search of the transcripts on this machine (*Search*; nothing stored, never cached by the browser). Query: `q` (plain words, up to 200 characters and 8 words), the range as `hours` (default 24) or `from` and `to` (epoch seconds, or a local `YYYY-MM-DDTHH:MM` in the `SALA_TZ` zone), and switches `front`, `back`, `sub`, `unknown`, `messages`, `tools`, `output`, `thinking` (`1`/`0`; the first six default on, `output` and `thinking` off). Answer: `words`, `from`/`to` and `fromText`/`toText`, `matches`, `shown`, `cap` (200), `capped`, `timedOut`, `deadlineS`, `files` (`scanned`, `inRange`, `all`), `counts` (`agents`, `content`), `elapsedMs`, `timezone`, `tzLabel` and `results` as `[{agent (permanent id), name (current), role, sub, kind, tool, session, uuid, ts, snippet: [[text, marked 0/1]…], when, at}]`, newest first. A bad query or range is a 400 with a sentence, a third parallel search a 429 |
| `GET /api/for-you` | stackshot's For you list: `rows` as `[{id, kind, item, project, what, url, urgent, ts, when, slacked}]` newest first, `flags` as `{"board#N": "watch" or "mute"}` (no entry: the default, shown as watching), `generated`, `fetchedAt`, `refreshing`, `pending`, `error` (a plain sentence; the last list stays). Served at once from the last good answer, read at most once a minute, in memory only (*For you*) |
| `POST /api/for-you/seen` | `{"id": <entry number> or "all"}` → `{ok, seen, rows, flags, fetchedAt}`: the entry (or all) marked seen at stackshot, the list now; a refusal is `{ok: false, error: <sentence>}` with stackshot's status (403, 404, 400) or 502. Origin, content-type and size checked like the other POSTs |
| `POST /api/items/<board#N or N>/watch` | `{"state": "watch" or "mute" or "default"}` → `{ok, item, state, flags, ...}`; the flag set at stackshot; same refusals and checks |
| `GET /api/colors/combos` | the color tool's saved combinations (*The color tool*): `{combos: [{id, name, values: {14 colors}, saved, via}], max}`, stackshot's one list on the account, never cached. A failure is `{error: <sentence>, field}` with stackshot's status for a refusal, 502 (unreachable, token refused, not the list) or 503 (no token or address here, list unreadable) |
| `POST /api/colors/combos` | `{name, values}` (the name 1 to 40 characters, `values` the 14 colors as `#rrggbb`) → the list; a name already there (case ignored) is replaced in place. The sender label is set by the server; a `sender` or any other field in the body is a 400. Same origin, content-type and size checks as the other POSTs |
| `POST /api/colors/combos/delete` | `{id}` → the list (an unknown id is not an error) |
| `GET /api/board-items` | every live session's open stackshot items: `sessions` as `{<name>: {items: [{id, subject, needs, waiting, held, url, state?, list?, …}], waiting: <count>}}` (waiting first, held last), `fetchedAt`, `refreshing`, `pending`, `partial`, `error`. Served at once from the last good answer, refreshed at most once a minute in the background (one client read per session, 4 at a time) and kept in `state_dir/board-items.json`; the token in `$XDG_CONFIG_HOME/stackshot/client.token` is only sent as the bearer (*Board items*) |
| `GET /api/s/<pid>/transcript?n=200` | the last n parsed messages, with `before` (the cursor for the page before them) and `start` (the file's start was reached) |
| `GET /api/s/<pid>/transcript?before=<cursor>` | the n messages that end before the cursor, the new `before` and `start`; 400 on a bad cursor |
| `GET /api/s/<pid>/transcript?around=<cursor>` | about n/2 messages before the line at the cursor (a Search result's `pos`) and the rest from it on, with `before`, `start`, `after` (the cursor for the next newer page) and `end` (the end of the file is in); 400 on a bad cursor |
| `GET /api/s/<pid>/transcript?after=<cursor>` | the n messages from the cursor on, the new `after` and `end`; 400 on a bad cursor |
| `GET /api/s/<pid>/stream` | SSE: `retry: 1000`, `version`, `reset` (last 200 messages), then `append`, `status`, `live`, `gone`. `live` is the pane of a running `!` command (*A running `!` command*); a client that does not know it ignores it |
| `POST /api/s/<pid>/stop` | `{}` as `application/json`: Stop for a running `!` command, Escape and then, if it still runs a second later, Ctrl-C, into that session's own pane → `{ok, sent: ["Escape"(, "C-c")]}`; 409 with nothing sent when no `!` command runs there; origin and content-type checked like the other POSTs |
| `GET /api/image/<sessionId>/<uuid>/<i>/<j>` | an image block from a transcript |
| `GET /api/file-image/<sessionId>/<uuid>/<i>/<k>` | the k-th file of the `SendUserFile` call at content block i of that transcript line, when it is a png, jpeg, gif or webp of at most 15 MB under an allowed root and not hidden or secret-named (*What it can and cannot do*, "Images a session sends"); anything else 404 |
| `GET /api/md-image/<sessionId>/<uuid>/<i>/<n>` | the n-th local image (`![caption](/abs/path.png)` or `~/…`, outside code) in the markdown of the assistant text block i of that transcript line, under the same rules as `file-image`; a refusal is a 404 `{ok: false, error: <reason>}` that the page shows as "image not shown: <reason>"; a place the reply does not name is a 404 too (*What it can and cannot do*, "A markdown image of a file on this machine") |
| `POST /api/upload` | raw image body (`Content-Type: image/png|jpeg|gif|webp`, 20 MB) → `{ok, name, path}`; or any other file, `?name=<its name>` (required for a type that is not an image), streamed to disk, 500 MB at most (413), refused when it would leave under 2 GB free (507), 400 empty → `{ok, name: "<hex>/<safe name>", path, file: true, fileName, size}` (*Any file, not only images*) |
| `POST /api/s/<pid>/send` | `{"text": "...", "uploads": ["<name as /api/upload returned it>"]}` as `application/json`; with a dialog open, `{"text": "2"}` or `{"text": "esc"}` answers it (`dialogAnswer` in the reply) |
| `POST /api/shell/open` | `{}` as `application/json` → `{ok, session: "<SALA_SHELL_SESSION>", created}`: makes the shell drawer's tmux session (a plain `bash -l` in the home directory) when it is missing, under a lock; `created` is true when it had to (*The shell drawer*); 403/415 as every POST, 502 when tmux cannot make it |
| `POST /api/shell/keys` | `{"key": "<name>"}` as `application/json`, `name` one of `Escape`, `Tab`, `Up`, `Down`, `Left`, `Right`, `Enter`, `BSpace`, `C-a`..`C-z` → `{ok, sent}`: `tmux send-keys -t =<SALA_SHELL_SESSION>: <name>`; any other name 400 and nothing sent, 502 when the session is not there; 403/415 as every POST |
| `GET /api/prefs` | the page's saved preferences, defaults filled in |
| `PUT /api/prefs` | merge the given keys into them, as `application/json`; returns the result |
| `POST /api/read` | `{"name": "<session name>"}` as `application/json` (403 cross-origin, 415 other types, 413 over 4 KB, 400 bad body, 404 no live session by that name): the owner opened that session, so its read marker in `state_dir/read-state.json` moves up to its latest reply; returns `{ok, name, moved}` (*The unread reply count*) |
| `GET /api/spawn/options` | what the New session form offers: `projects` (`[{key, title}]`, the project pages; the form no longer reads them, `GET /api/spawn/projects` is its list), `dirs`, `lanes`, `efforts`, `models` (`opus`, `sonnet`, `haiku`, `fable`), `defaults` (`{lane, model, effort}`: what a spawn with none chosen follows, for "use default (<value>)": sala's default lane from `sala lane --json`, the model and effort from `settings.json`; `""` when unreadable), `nameMax`, `mandateMax`, `error` (why the list is empty, else null); never cached |
| `GET /api/spawn/projects?scope=work\|home\|lab\|all[&q=<text>]` | stackshot's project list for the scope (`all`: every scope's, a query-only value that `POST /api/spawn/project` and `project-list` refuse; a row marked retired is left out): `{ok, scope, scopes, projects: [{id, key, title, name, type, scope, listed, hidden, keeper, main, agents: {name: {front, role, page_owed?}}}]}`, the listed ones by key, and with `q` the scope's hidden matches (`hidden: true`); 400 a bad scope or text, 502/503 with `code` (`unreachable`, `refused`, `config`, `busy`) and `error` in plain words; never cached (*New session*) |
| `POST /api/spawn/project` | `{"key": "<folder>/<slug>", "scope", "title"?}` as `application/json` (16 KB at most) → starts stackshot's `post project`; 202 `{ok, job}`; 409 `code: busy` while another is being made; 400 a value stackshot would refuse; 403/415/413 as every POST |
| `GET /api/spawn/project/job?id=<job>` | `{state: running\|done, elapsed, status, result}`; `result` is `{ok: true, id, key, created, note, pageOwed?, pageYaml?}` or `{ok: false, code, step, error}` (`exists` 409, `in-progress` 409 (another request is making that key), a code for the knowledge base refusing 502, `bad`, `unreachable`, …); 404 for an id that is unknown, lost in a restart or over an hour old |
| `POST /api/spawn/project-list` | `{"key": "<prj_id>"\|"<page key>", "scope"?}` → stackshot's `post project-list`; 200 `{ok, id, key, changed, note}` or `{ok: false, code, step, error}` with stackshot's status |
| `POST /api/spawn/project-agent` | `{"project", "name", "role", "front", "mandate"}` (the mandate one line, 600 characters) → stackshot's `post project-agent`; 200 `{ok, id, key, pageOwed, pageYaml, note}`; 403 `code: not-allowed` when stackshot refuses the project (retired or hidden); 409 `exists` (the name is taken); 400 a name that does not start with the project's name |
| `GET /api/spawn/suggest?project=<key>&role=front\|back[&prefix=<p>][&new=1]` | `{"name"}` from `sala spawn --suggest-name [--prefix p] [--new]`: `<prefix>-main` only for a front agent of a project with no agent yet (sala's record lists it with none, or `new=1` says it has no page yet), else `<prefix>-<random word>` (a word picked at random, not in a fixed order; a missing or stale record gives a word too), never a name that is taken (a tmux session, a running claude, an agent of any project in stackshot's record); `prefix` is the project's real one (its main agent's name without `-main`), which the page sends; 400 for a bad key, role or prefix, 502 when sala could not say |
| `POST /api/spawn` | `{"project", "role", "name", "mandate"?, "lane"?, "model"?, "effort"?}` as `application/json` (64 KB at most, the mandate 20 KB) → one `sala op spawn …`. 202 `{ok: true, op, name, project, role, output}` when queued; 409 with `code` `not-listed` (`page`, `name`, `role`, `block`: the `REGISTER:` line and stackshot's register command, `keeper`: sala's line or null, `error`), `no-page` (`page`, `error`), `refused` (`error`, `exit`) or `busy` (one spawn in flight); 400 a bad field (`error` says which), 413 too large, 403 cross-origin, 415 not JSON, 502 `code: error` when sala could not be run or did not finish in 90 s. Nothing typed is logged (*New session*) |
| `GET /api/spawn/status?op=<id>` | the queued operation's record from sala's marker: `op`, `state` (queued, running, waiting, done, stuck, absorbed, cancelled), `result`, `args`, `verb`, `from`, `time`, `started`, `ended`, `unit` (the ones the marker has), and, while `state` is queued, `behind` (what is ahead of it in the queue, running first: a list of `{op, verb, arg, state}`) and `behind_line` (one sentence counted by verb, "" when nothing is ahead); 400 for a bad id, 404 for none |
| `POST /api/debug/<kind>`, `GET /api/debug/<kind>?n=200` | `kind` is `timing`: a record or a list of them (`application/json`, 64 KB at most) appended to `<kind>-debug.log`, 204; the log's last n lines as `text/plain`, the timing log as one readable line a record unless `?raw=1` (temporary; *Timing*) |

POSTs and PUTs carrying an `Origin` that does not match the `Host` are refused (the Host the request came in on; *Hosts*).

### Preferences

The sidebar's settings are kept server-side, so they follow the owner across browsers and devices:
`$XDG_STATE_HOME/sala-web/prefs.json` (`Settings.state_dir/prefs.json`), written atomically (a temp file in the same
directory, fsync, rename) under a lock, mode 0600.

| Key | |
|---|---|
| `scopeOrder` | scope keys (for example `work`, `home`, `lab`, `other`, `Unregistered`) in the order the owner dragged them |
| `groupOrder` | project keys (stackshot project slugs) in the order the owner dragged them; a project moves only within its scope |
| `sessionOrder` | the agents in the order the owner dragged them; a session moves only within its project. One flat list, like `groupOrder`, of sala's permanent agent ids (`agentId`, the registry row's id in `sessions.json`: minted once, it outlives a `sala rename`, a recycle that resumes a new conversation and a `/clear`), and of the session's name for one the registry has no row for. A list saved before the ids holds names: the page reads each as the agent that has the name now, or had it (the row's `aliases`), and saves the list once as ids. A session not in the list follows the listed ones of its project in the default order (a new agent goes last), an entry that is not live is ignored. Entries of agents that ended stay (a returning one finds its place) but at most 100 of them, and never at the cost of a live one: past that, or past the 500 the server takes, the page cuts the gone ones from the end when it saves (Every list in the prefs (the orders, `collapsed`) is saved from the server's current list read at that moment, never from the page's copy (defaults when the file was missing or the read failed, old when another device saved since), and only the key that changed is sent; a drag of agents writes only its own project's entries; when the stored prefs cannot be read nothing is saved and the side panel says so.) |
| `collapsed` | folded headers: project keys, and scope keys as `scope:<key>` |
| `laneOrder` | the Overview's lane card ids (`subscription-1`, `subscription-2`, `api`, `aws-platform`, `bedrock`; an old `max` or `team` in a saved order reads as the new code) in the order the owner dragged them; a lane not in it follows the listed ones in the default order (active, dormant, not configured), an id with no card now is ignored |
| `showAll` | the "Show all sessions" toggle (background agents) |
| `unreadOnly` | the Unread entry's filter (*The Unread entry*): only the agents with an unread reply, plus the open one; false by default |
| `shellHeight` | the shell drawer's height in pixels, an integer from 120 to 4000, default 300 (*The shell drawer*) |
| `lang` | the interface language, `en` (default) or `ko` (*The language*); anything else is refused with a 400 and changes nothing |

The lists hold strings, at most 500 each. Entries not listed follow in the default order; entries that are gone
stay in the list in case they come back.

**Whether the sidebar is open is not kept** (the page no longer reads or writes a `sideHidden` key: a leftover one in
`prefs.json` is dropped on the next read). On a wide screen the sidebar starts
closed on every load and slides over the page, with no room of its own: the pointer on the strip along the left edge or on
the toggle brings it, leaving takes it away, and a click on the toggle keeps it open (docked beside the page) until the next
click, for that page only; the toggle and the header do not move between the states (*the toggle and the header are one fixed
block*, at the top of this document). A phone keeps its drawer.

A PUT carries only the keys it changes. Unknown keys, wrong types and bodies over 64 KB are refused (400, 413); the
same cross-origin and `application/json` guards as `send` apply (403, 415). A file that cannot be read gives the
defaults, key by key.

## Develop

```sh
uv run --frozen pytest             # in web/
```

`tests/test_send.py` starts a private tmux server (`tmux -L <private-name> -f /dev/null`) whose pane imitates
Claude Code's input box and records what it receives; it never touches the default tmux server. The tests that read
the rendered page (`tests/conftest.py`: `served`, `browser`) serve the app on a loopback port with a fake session
whose pid is the test process and drive a headless Chromium over `--remote-debugging-pipe` at a phone's width
(390 px, dark); they look for `chromium` or `google-chrome` on PATH, then playwright's `chrome-headless-shell` under
`~/.cache/ms-playwright`, and are skipped without one. No test reads the board: `conftest.py` points
`SALA_WEB_STACKSHOT_TOKEN` and `SALA_WEB_STACKSHOT_URL` at missing files for every test (`tests/test_board_items.py`
feeds the cache a fake fetch; `tests/test_board_items_ui.py` stubs `api/board-items` in the page). To try the send
path against Claude Code itself, start one on a private server
(`tmux -L <private-name> -f /dev/null new-session -d ... claude`) and run sala-web with `--tmux-socket <private-name>`.

The frontend is `src/sala_web/static/` (one HTML file, vanilla JS, CSS, no build step). A reply (and its thinking) is
markdown, rendered by `marked` and sanitized by `DOMPurify` (`md()`: every link opens in a new tab with
`rel="noopener noreferrer"`; a `javascript:` URL loses its href). Before `marked` sees the text, `mdPrep()` (`shared.js`, pure, tested in node and in the page) puts a blank line before a numbered item that CommonMark would leave as paragraph text: a list may interrupt a paragraph only at "1.", so "Next steps:\n6. x\n7. y" drew as lines, flush left, beside indented lists. It acts only on a line-start `N.` or `N)` (N 2 to 999) outside a code fence, under prose (no list item or indented line in the block above), when the reply has an item numbered N-1 or N+1, and whose text does not start with another `N.`; dates such as `2026. 1. 5.` and `5. 1. 2026.`, a lone number and numbers mid-sentence stay text. A line right under a bullet stays that bullet's continuation. A reply's footer, the labeled note lines a session leaves last (each with its `- `
bullets), renders apart from the body (`replyNodes()`, `.md.footer`): 0.85 of the body's
16px in `--muted` (AA in both themes: 5.6:1 light, 7.1:1 dark), under a 1px `--border` rule when a body precedes it,
each note a block of its own so adjacent notes keep their lines (markdown alone ran several of them into one
paragraph, and lazily joined a note line onto the bullet before it). Its links keep the accent. A footer link on one
line gets 3px of extra tap height above and below its text from an invisible `::after` box, so its tap target is at least
a body link's. A footer link that wraps has no extra area beyond its text, so its target is its own text:
`markWrappedLinks()` (`app.js`) puts `.wrapped` on a link of two lines or more, which turns its `::after` off, because that
box is one rectangle from the first line's left edge to the last line's right edge, partial or empty for a wrapped link. It
runs when a message is added and when the chat's width changes, the only thing that moves a line break. There is no
vertical padding on a footer link: that
put its text a device pixel off the footer text's row at a fractional browser zoom, so the text stays on
the footer baseline. The link stays a plain inline box; an `inline-block` does not break
between lines and moves a long link and the words around it onto rows of their own. The rule (`splitFooter()` in
`shared.js`, pure, tested in node and in the page): a *note line* is a line that opens with one of a short fixed set of
labels followed by `:` (or by an item or a link, for the labels that take one), or the page-note form `Page <slug with a />:`
(a deck's `Page 1: …` is prose, and so is a sentence that merely starts with one of the label words); a bold lead reads as the plain
one. A `- ` or `* ` bullet, an indented line or a blank line belongs to the note above it. The footer is the trailing run of such
lines from its earliest note line to the end; bullets above the first note are body. One closing paragraph may follow
the footer: when the reply ends in a paragraph of prose (its first line not a note, no blank
line inside, at most 8 lines) and the lines before it, past the blank line, end in a run of notes that is not made of page notes
alone, that run is the footer and the paragraph its *tail*, rendered as body text under the footer (`.md.tail`: full
size, the text colour, a 10px gap, no rule). A note followed by anything else (two paragraphs, a paragraph that begins
with a note line, a run of page notes alone before a paragraph) stays body. A run of page notes alone at the
end counts only when it has two or more notes, starts the reply, or follows a blank line, so a body paragraph that merely
begins with `Page …` stays body. A reply without a footer renders as plain markdown; when the footer starts the reply
there is no rule above it; the copy button copies the text as written, footer, tail and all. Text shown as written, the owner's own prompt bubble, a
message from another session (a notice fold) and a tool result, is not markdown-rendered, but its `[label](https://…)`
links and bare `http(s)` URLs are made tappable (`linkTokens` in `shared.js`, text nodes and `<a>` elements, never
innerHTML); they would show as plain text otherwise. A reply line the API sends as a `thinking` block
(*narration*: a narration line shown in the terminal was hidden in the chat with the thinking) is read
from the block's `signature`, the way Claude Code 2.1.311 does (`signature_kind()` in `transcript.py`): the signature is
base64 of a protobuf, field 2 > field 1 > field 8 is a label, `thinking` for real (hidden) thinking and `narration` for
model text. A narration block with text that is not blank is served as a plain `text` block, so it is a reply line whatever
the **Thinking & tool calls** toggle says; every other non-empty thinking block, an unsigned one and one whose signature
does not read included, stays a `thinking` fold behind the toggle, and an empty one is not shown. Chat behaviour worth knowing:
the view stays pinned to the bottom (a `ResizeObserver` re-scrolls as images and markdown settle) until the owner
scrolls up, which shows a jump-to-bottom button; a sent message shows at once as a pending bubble and is replaced by
the transcript's copy when it arrives (matched on its text, ignoring `[Image #N]` chips and Claude Code's
`<pasted_content>` wrapper, else the first new prompt after the send); scope and project headers reorder by dragging
(pointer events, so touch works too) and fold on a click. `marked` 12.0.2 and
`DOMPurify` 3.1.6 are vendored in `static/vendor/`. `tools/make_icons.py` redraws the app icons (*Install as an
app*); nothing under `tools/` runs in the app.
