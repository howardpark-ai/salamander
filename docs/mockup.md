# Mockup pages: `sala mockup`

A session that cannot publish an Artifact still needs to show a reader a design. `sala mockup add page.html` stores an HTML file under the next
number and prints its address, `https://<sala's address>/mockup/<n>`; sala-web serves it. The reader opens a link instead of a picture, on a desktop or a phone.

```
$ sala mockup add login.html
https://sala.example.com/mockup/7
```

**A revision uses `update` on the same number, never a new `add`.** `sala mockup update 7 login-v2.html` replaces page 7 in place, so it keeps its number and its address,
and the page it replaces is saved as a version first (see *Versions* below). A new `add` makes a new number and a new address, so the reader's link to page 7 would
keep showing the old design. `update` refuses a number that has no page: a new page is always `add`.

## Commands

| | |
|---|---|
| `sala mockup add FILE\|-` | store an HTML file (a path, or `-` for standard input) and print its address on stdout, nothing else, so `$(sala mockup add page.html)` is the link. `sala mockup FILE` is the same. A new page only. |
| `sala mockup update N FILE\|-` | a revision: replace stored page N in place (same number, same address), with the same checks and output as `add`. The page it replaces is saved as a version. An unknown N is refused. |
| `sala mockup history N` | the saved versions of page N, newest first: when each was saved (UTC), its size and its file name. Prints nothing when there are none. |
| `sala mockup undo N` | restore the newest saved version of page N. The page it replaces is saved as a version too, so undoing again goes back to where it was. |
| `sala mockup list [--json]` | the stored pages: number, size, age, address. Saved versions are not listed. |
| `sala mockup remove [--force] N` | delete one page now, with its versions. Its number stays used. Refused when an open board item links the page (`SALA_MOCKUP_REFERENCES`, below), and also when that command fails; `--force` removes it anyway. |
| `sala mockup clean [--dry-run] [--days N] [--max-bytes N]` | the daily pass (below). |

**The address** is the scheme and host of `SALA_SESSION_URL` (the link template sala already uses for a session's web link, for example
`https://sala.example.com/s/{name}`), followed by `/mockup/<n>`. Nothing is hard-coded. With the setting unset the path `/mockup/<n>` is printed and a
note on stderr says what to put in front of it.

**What a page may be.** UTF-8 text, not empty, at most 5 MiB, no NUL byte, and no lettered designs; anything else is refused with a sentence and takes no number. UTF-8 is the one
encoding because the response says `text/html; charset=utf-8` (no byte-order guessing, no per-file charset) and a mockup is text; 5 MiB is far more than
a hand-made page with inline styles, scripts and `data:` images needs, and the response is read whole.
A page that letters its designs is refused too: when the visible text holds a design word (variant, option, design, layout, proposal, alternative, concept,
version, approach, or the Korean words for option, draft design and design) followed by one capital letter standing alone ("Variant A", "Option B"), `add` says
which phrases it found and takes no number. Name each design instead (One-line strip, Fuller panel), the same words as the board's options: a letter on a
page and a letter on the board can mean different designs, a name cannot. Only the visible text counts: script and style bodies, comments, tags and
attributes (`class="variant-a"`) are skipped, and a lowercase letter or a sentence that ends before a capital ("the options. A new line") is not a hit.
There is no override flag: a name is always possible.
Put `<meta name="viewport" content="width=device-width, initial-scale=1">` in the page's `<head>` so a phone lays it out at its own width instead of a zoomed-out
desktop page; `add` prints a note on stderr when the meta is missing, and changes nothing in the file.

**Back to sala.** When sala-web serves a page it adds one link at the top of the body, "Back to sala" (at least 44 px high, in the page's flow, no sideways scroll at phone width), because the installed phone app opens a link
to a page of its own site inside its own window, with no address bar and no way back. The stored file is not changed, so a page needs nothing for it, and need not draw a way back to the chat of its own
(web/README.md, *Mockup pages*).

## Storage

Under sala's state folder: `$SALA_STATE_DIR/mockups/` (else `$XDG_STATE_HOME/salamander/mockups/`, else `~/.local/state/salamander/mockups/`), mode 700.

- `<n>.html`: a page, mode 600. Pages are stored under their number only, never under a name the writer chose.
- `counter`: the last number given, mode 600.
- `.lock`: the lock file.
- `versions/<n>/<UTC time>.html`: the saved versions of page N (below), mode 600 in folders of mode 700. The name is the time the version was saved, to the
  microsecond, such as `20261127T142709.123456Z.html`; two saves in one microsecond still get two names.

The CLI is the only writer; sala-web only reads. A number is taken under an exclusive `flock` on `.lock`: the counter becomes `max(counter, highest page) + 1` and is
written (temporary file, `fsync`, rename) before the page is, so a crash leaves a gap and never a number given twice, parallel `add`s get different numbers, and a deleted
page's number is never given again. A page is written under a temporary name and renamed, so a reader never sees half a page.

## Versions

Every `update` and every `undo` saves the content it replaces as a new version under `versions/<n>/`, before the new content is renamed over `<n>.html`. Nothing an update
replaces is lost, and a crash between the two writes leaves the old page in its versions, never lost. The commands:

- `sala mockup history N` lists the versions newest first: when each was saved (UTC), its size, and its file name.
- `sala mockup undo N` restores the newest version over page N and saves what it replaces as a version, so undo is itself undone by the next `undo`. The restored version
  is taken out of the versions, so each undo steps back one version.
- The versions are never listed by `list`. sala-web shows them read-only, and only through the page: see *The history on the page* below.
- `remove N` deletes the page's versions with the page. `clean` deletes them with the page it deletes. The versions of a page that is gone (left by a removal done
  by hand) are deleted by the daily pass once they are older than the keep time (`SALA_MOCKUP_KEEP_DAYS`).
- A page's versions count toward the folder's size for the size rule below.

## The history on the page

When page N has a saved earlier version, the served page (`/mockup/<n>`) shows one small history icon at the right end of the "Back to sala" row. A
tap opens the list of earlier versions below that row, newest first. Each reads "Until <time>" in Korea time (for example "Until Wed Oct 28th 14:07
KST"): the time that version was replaced, not the time it was made. A tap on one opens it at `/mockup/<n>/versions/<id>`, where `<id>` is that time
in UTC as the file is named, such as `20261127T142709.123456Z`. That view is read-only and has the same sandbox headers as the page. Its bar is one
44 px row: "Current page" at the left, to go back to `/mockup/<n>`, and the same "Until <time>" at the right (on a screen too narrow for both, the
time is cut with an ellipsis, never the link). There is no restore button and no diff: `sala mockup undo N` is the only way to put a version back.

- With no saved earlier version there is no icon, and the page is served as before.
- The list is in the page's flow, never over the page's content, and each of its rows is at least 44 px high.
- An address is served only when page N exists and `<id>` is the name of a saved version of N, a regular file; anything else (another page's
  version, a link, a file that is not a version, an id that is not a real time) is a 404 with the same headers.
- Like the page, a version sits behind the same sign-in (the proxy) as everything else on the site.

## How it is served

`GET /mockup/<n>` on sala-web, `text/html; charset=utf-8`, 404 for a number with no page. There is no sign-in of its own: sala-web has none, the
proxy in front of the site is the sign-in ([web-proxy.md](web-proxy.md)), and this route is served by the same app, so it is behind the same sign-in as everything else.

A stored page is somebody's HTML at the address of the terminal, so every response under `/mockup/` (a page, a 404, a 405) carries:

```
Content-Security-Policy: sandbox allow-scripts; default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline' https://fonts.googleapis.com;
  font-src https://fonts.gstatic.com data:; img-src data:; media-src data:; connect-src 'none'; frame-src 'none'; worker-src 'none'; object-src 'none';
  base-uri 'none'; form-action 'none'; frame-ancestors 'self'
X-Content-Type-Options: nosniff
Referrer-Policy: no-referrer
Cache-Control: private, no-cache
```

- `sandbox allow-scripts` (no `allow-same-origin`) gives the page an opaque origin: `document.cookie` and `localStorage` throw, and a request the page makes is origin-less and cross-site,
  so sala's API is neither readable nor reachable by it. No forms, popups, modals, navigation of the top page, downloads.
- `connect-src 'none'` closes `fetch`, XHR, WebSocket, EventSource and beacons; `default-src 'none'` and the other `'none'`s close frames, workers and plugins.
- What a mockup needs stays open: inline scripts and styles, `data:` images and fonts, Google Fonts (the stylesheet from `fonts.googleapis.com`, files from `fonts.gstatic.com`).
- `nosniff` and `no-referrer` keep the type fixed and the page from learning where it was opened from. `private, no-cache` because the page is behind a sign-in and a deleted page should be gone at the next load.

The sandbox was checked in a real headless Chromium (`web/tests/test_mockup.py`): the page's inline script runs, `self.origin` is `"null"`, cookie and storage reads throw `SecurityError`, `fetch` of sala's API (relative,
absolute, credentialed), a fetch of another site, XHR, WebSocket and a beacon are all blocked, an inline style applies, a `data:` image decodes, and at a 390 px wide phone viewport the page does not scroll sideways.

The service worker (`web/src/sala_web/static/sw.js`) has no fetch handler, so it never sees a request for a mockup; a test fails if a handler is ever added that does not step aside for `/mockup/`.

## Cleanup

`sala-mockup-clean.timer` (daily, `systemd/`) runs `sala mockup clean`, which applies two rules in this order:

1. **Age.** A page older than 7 days (`SALA_MOCKUP_KEEP_DAYS`, `--days N`; the age is the file's modification time, set when the page was last updated) is deleted, with its versions, unless an open board item links it.
2. **Size.** If the folder (every file in it, versions included) still holds more than 1 GB (`SALA_MOCKUP_MAX_BYTES`, `--max-bytes N`; default 1073741824), pages are deleted oldest first (equal ages by number) until it is under the cap.
   A page an open board item links goes last: only when every unlinked page is already gone and the folder is still over.

Each deletion is printed with its reason; `--dry-run` prints what it would delete and deletes none. A half-written page older than a day (a crash's leftover) is removed too.

**Which pages an open board item links** is the one thing the pass cannot read for itself. The board's supported reads give a script subjects, per-session item lists without descriptions and item
status, not the text of an item's description without a model call, and reading the board's repository directly is not allowed. So the host says how, with `SALA_MOCKUP_REFERENCES` (in `~/.config/salamander/config`):

| value | what the pass does |
|---|---|
| unset or empty (the default) | **Nothing is deleted, by either rule.** It keeps every page, exits 0 and prints why (and, when the folder is over the cap, says so). A host that has not said how to read the board loses nothing. |
| `none` | no open item links a page: age and size alone decide. An explicit choice. |
| a command line | run without a shell (60 s limit). Every `/mockup/<n>` in its output is a page an open item links. A command that fails, times out, is not found or prints over 8 MiB keeps every page and exits 1: deleting on a failed read could remove a page somebody is reading. |

A command that prints nothing readable but exits 0 means nothing is linked. The command is the host's to write (for example a small script over the board client that prints the open items' descriptions).

## Settings

| Setting | Default | |
|---|---|---|
| `SALA_MOCKUP_KEEP_DAYS` | `7` | the age rule's days |
| `SALA_MOCKUP_MAX_BYTES` | `1073741824` (1 GB) | the folder's size cap; a named constant in `lib/mockup.py` (`CAP_BYTES_DEFAULT`) |
| `SALA_MOCKUP_REFERENCES` | unset | how the pass learns which pages are linked (above) |

All three are read from `~/.config/salamander/config` (a plain `NAME=value` line) or from the environment; a line in the config wins over the environment, as for every sala setting. The daily `sala-mockup-clean.service` has only `PATH` in its environment, so for it the config file is the one source.

Tests: `tests/mockup.sh` (numbering, atomic counter, refusals, `update` and its versions, `history`, `undo`, `remove` with its link refusal and `--force`, both cleanup rules with a stub reader and fake sizes and ages, the unit files) and `web/tests/test_mockup.py` (the route, its headers, a revision served on the next load, the history icon and the version view with their
addresses and refusals, and a real headless browser at a 390 px phone width in light and dark).
