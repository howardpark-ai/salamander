# What the suites cover, and why

## The rule (CONTRIBUTING.md, "What gets a test")

A check stays only if it guards a path that can:

- **lose a session, a conversation or an unsent draft**: relaunch, exit, resume, retire, rename, recycle, the reboot
  drain, the busy check and its hooks, the mod's draft and exit refusals, the guard hook's denies;
- or **corrupt the pane map or the resurrect restore point**: ledger writes, follow, freeze, the fleet-server guard,
  snapshot.

Checks of these are dropped:

- wording and formatting (the exact Slack or post text, a headline's emoji, a log line's phrasing, help text), unless a
  program parses that text;
- cases that duplicate another check's protection;
- trivia: parse-only checks that `tests/syntax.sh` already makes, config echoes, cosmetic ordering.

When unsure, the check stays, and the list below says why. A new check follows the same rule.

Counts are the `ok` lines of a passing run.

`web/` (sala-web) is outside this list: it has its own pytest suite, `web/tests/`, run
by CI's `web-shard` jobs (gathered in the `web` check) for a change under `web/` and documented in `web/README.md` (*Develop*, *Deploying*) and in
CONTRIBUTING.md (*web/*). The one web entry below (the board items) is here because its checks guarded something the
rule's two losses do not name and a reader would otherwise drop: what the page tells the user is waiting on them. The page no
longer says it (the item count button, its sheet and the Overview's red count are gone; the entry at the end says
what stayed), so its page checks are history.

## Totals

798 checks before, 554 after. `bash tests/run.sh` (main and this branch run alternately) took about the same before and after,
with no measurable change. The suites run side by side, so the wall time is set by the slowest ones (`sets`, `ledger`,
`sets-master`), and their flows all stayed: what went were checks on flows that run anyway. The suites that lost a flow got
faster on their own (`busyhooks`, `briefing`). Later the run grew (`lanes`, `sets` and `ledger` were the slowest; 1361 checks)
and was brought back down with 1365 checks by the same rule: `watch`'s sign-in step off outside `signin.sh`, its bridge settle
a knob, `lanes` and `ledger` each split in two files (the entries below say what moved); no check dropped.

## What the suites share, and what they cost

**`tests/lib.sh` helpers.** Fourteen helpers that 27 suites each carried as their own copy now live in `tests/lib.sh`, written
in the shell's own builtins (a copy per suite started a `grep`, `awk`, `sed` or `od` per call, thousands of times a run).
A suite that needs another shape defines its own after sourcing the file. Nothing a check asserts changed: each helper
returns what the copy returned, and the cases below were compared old against new before the copies went.

| helper | what it answers |
|---|---|
| `uuid <n>` | a fixed-shape uuid for fake session n |
| `has <text> <needle>` | 0 when the text holds the needle (was `grep -qF`) |
| `cpid <suffix>` | the pid of the claude in tmux session `sala-test-<suffix>` |
| `starts <uuid>` | how many times a fake started on that uuid (lines `start <uuid> …` in `$FAKE_LOG`) |
| `posts`, `post <text>`, `nposts <text>`, `lastpost` | the Slack posts a suite's fake poster appends to `$POSTS`: how many, the first holding the text, how many hold it, the newest |
| `iso <epoch>` | the CLI's timestamp form (`…T…:…:….000Z`) |
| `rid` | a fresh record uuid |
| `set_reg_status <pid> <status>` | that claude's registry row says `<status>` now (the first `"status":"…"`) |
| `enq <verb> …` | runs `sala op …`; sets `OUT`, `RC` and `ID` (the queued op's id) |
| `same_file <a> <b>` | 0 when two files hold the same bytes (was `cmp -s`) |
| `slurp <file>` | a file's text, empty when it cannot be read (for `$(slurp f)` where `$(cat f 2>/dev/null)` stood) |

Also there: `waitfor`, `load_factor`, `scale`, `nap` and `lock_wait` (the load-proof waits: a busy box stretches a bound, it
does not fail a check that only needed more time), `as_op_unit`, `tmux_socket_rm`.

**`tests/count-procs.sh`** is the measure, not a suite (`tests/run.sh` skips it). It runs the named suites one at a time under
`strace -f` and prints, per suite, FORK (processes created, `$(…)` subshells included) and EXEC (programs started, the cost
that matters), the total, and with `-t` the most started commands. A change to a hot path in `lib/` is counted on the suites
that run through it, one at a time, before and after (CONTRIBUTING.md, *Counting processes*, has the habits for `lib/`).
`busyhooks`, `limitwatch` and `modelinplace`, the three that failed under CPU load, pass under eight `yes > /dev/null`
loops (`ok` counts 59, 89, 67, as unloaded).

## Which suites a PR runs (Tue Oct 27th 2026)

**`tests/suites.map` and `tests/suitemap.sh`** are the measure of the other kind: not what a suite checks, but which tracked
files it opens. `--measure` runs each suite under `strace -f -y` (open, openat, openat2) and keeps the tracked files it
opened, minus the shared `full` files and its own file; `--select <from> <to>` turns a PR's diff into the suites that
open a changed file; `--check` keeps the map honest (every suite has its line, every file is covered). A PR runs that
selection; a push to `main` runs every suite, so a file the map misses fails there. The map says what a suite *opens*,
not what it *checks*: a suite that reads a file as data but asserts nothing about it still lists it, and a flow that
reaches a file only by a path the run did not take (a suite that stops at an early failure, a `git clone` of the
checkout, a file handed to a process the trace does not follow) is not on the line. Those are the misses `main` catches.
The `text` suites (`syntax`, `lanefields`) read most of the repo as text, so a change that is only comments still runs
them. `syntax` also opens every tracked file just to read its first line (a shebang test), so it is a `firstline` suite: the
files on the `none` line stay off its line only, since `lanefields` reads README.md as content. A suite that fails under `strace` (its timing checks, or a Claude ancestor on the process tree) may have a partial
line: measure from a shell outside a Claude session and re-measure it alone.

## Per suite

### `tests/syntax.sh`: 59 → 57

Unchanged. Every tracked shell file parses, and the Python files too: the same gate `deploy.sh` runs before it
fast-forwards production. The count fell only because two test files were deleted.

### `tests/smoke.sh`: 39 → 33

Kept: the `proc_*` helpers, the process tree, `is_idle` and the rc-child filter (the busy check and relaunch stand on
them); the composer cases (a draft versus a suggestion: the draft refusal); `not_back_sessions` (the reboot drain's
count); `spawn --list` (its columns are parsed by the briefing linker and the heartbeat); `adopt` and `revive --save-map`
(ledger writes); the heartbeat's `machine.json` / `sessions.json`, its push and the live/git split (a contract stackshot
parses).

Dropped:
- `revive --dry-run` lists the pane, `map` shows it: read-only display.
- the heartbeat's summary line, "quiet heartbeat commits nothing", `heartbeat --check`, the unconfigured no-op: log
  wording and trivia; nothing is lost or corrupted when they break.

Borderline keep: "revive --save-map observes" reads the summary line, but its "0 followed" is what shows the save did not
follow anything.

Kept for the sweep's machines (2 checks, one posix machine behind the `ssh` stub): a swept machine's version lands in its
`machine.json` with no `hub` field (the store's contract), and the payload sent to it runs no git: the guard that the sweep
reaches for no checkout on a machine (the driving machine's own checkout of the sibling tool is that tool's production
checkout). The stub and the fixture also carry the session-links checks below.

### `tests/phases.sh`: 36 → 26

Kept: the dry run never reaches phase 2 or 3 (nothing closed or resumed); a, b, c relaunched; d skipped for its draft, e
for an /exit that never landed, f for a resume that died; resume order and parallel close; every inbox hold released
and the lock with it; `--only` touches one pane; the recycle lock (a second driver refused, a direct revive refused,
`--save-map` never takes it, the lock dies with its driver).

Added after the cut: f's resume now comes up and dies 3 s in, and the check is that f gets no
UPDATED row (its skip row stays as the verdict). A resume that dies after it started was counted as relaunched by the
old `wait_for … claude` check whenever the 1 s poll landed while it was up: a lost session reported as back.

Added Fri Oct 30th (inbox hold first, contract 23; 9 checks): a seventh pane g turns busy after its hold is written (a poller
types a message into it the moment its key appears in `held-msg.txt`). A 5 ms poller records when all six keys were present
and the check is that this is at least `SALA_HOLD_SETTLE` (3 s) minus 0.5 s before the first `exit` in the fake claude's log (an
order-only check passed by a race, 0.87 s, even with the hold written pane by pane right before each `/exit`; confirmed by mutation:
with the hold back in `close_pane` the gap is 1.0 s and the check fails); the sweep says it held six panes; d, skipped in phase 1,
was never held; g is deferred by the re-check before the `/exit`, its skip row is one `transient_skip` accepts (so it is queued for
retry), it is never exited, and its hold is cleared like e's. A second sweep killed with TERM inside its settle leaves no hold
behind (the exit trap; without it the keys stay until watch's 10-minute drop).
`tests/sets-master.sh` (+5 checks): the `--self` worker with an empty registry name: a pane busy once held is released and handed to
the retry worker (a worker runs, the hold lists and ledger are empty, no `/exit` was typed); text typed at the prompt after the hold
aborts it and `wabort` releases the hold by the uuid (mutation: keyed on the name alone, the hold is left behind).

Dropped:
- the dry run's per-pane lines and its phase line; the phase 1/2/3 summary lines: log wording (the outcome rows stay).
- the sweep's wall-time bound: the order/timing check already proves the close is parallel.
- the clean-recycle Slack report: post wording.
- the refusal line's exact text (the refusal's exit 75 stays); the post-recycle output's log prefix.

Borderline keep: `SALA_POST_RECYCLE_CMD` (KIND, STARTED, RESULT, SKIPPED; never on a dry run or outside the driver). Not a
loss path, but a program parses it: stackshot's client clears the board's waits-for-recycle from it.

### `tests/ledger.sh`: 115 → 109

All of the pane-map ledger stays: honored paths, adopt, rename, retire, absence never removing a row, follow, the
freeze and its deferred follows, the stale-freeze clear, the reboot dry run's freeze, `sala restore`, compare and restore
after a recycle and a reboot, the migration, the map gaps of Oct 8th, the fleet-server guard for revive, snapshot and
map writes. Ledger-log lines stay too: the log is the record a lost binding is recovered from, and `refused(follow)`
lines are parsed for de-duplication.

Dropped:
- watch's unmapped-session log line, and its de-duplicated second post: log wording and post noise.
- `spawn --list` showing a dead pane, `revive --map-history`'s display: read-only display (map-history's copies stay).
- the posts "Pane-map freeze cleared", "Recycle: 2 sessions recreated", "Reboot: 1 session recreated", "Reboot dry run
  halted", and the revive log's compare line: wording (the state each one reported is still checked).

Borderline keeps: the one post "sala-test-m is not in the pane map" (the only warning that a session will not come back
after a reboot); "nothing missing → nothing recreated" and `restore --missing` with nothing missing (they read the
output's words, but they are the only checks that the no-op path recreates nothing).

Added after the cut (Sat Oct 10th): a claude on a probe tmux server whose pane id equals a fleet pane's (each server
numbers its panes from %0) is neither taken for a hand rename of that fleet session by `rename --sync` nor followed by
`--save-map`. On main both happened: the master was told of a rename that never was, and the fleet session's map row
moved onto the probe's conversation, so a reboot would have brought back the wrong one.

Split on Wed Oct 14th 2026 (the wall time of `tests/run.sh` is its slowest suite's): `tests/ledger-recycle.sh` holds the
compare and restore at the end of a recycle and of a reboot, the map gaps of Oct 8th, the fleet-server guard, the probe
case and the two retire cases, on a map of three rows it adopts itself (one setup check); `tests/ledger.sh` keeps the
rest. No check was dropped: 114 `ok` lines before, 74 + 41 after.

### `tests/side.sh` new, 71 (85 since Tue Oct 27th); `tests/spawn.sh` +9, `tests/sessions.sh` +8, `web/tests/test_side_sessions.py` new, 35 (Mon Oct 26th 2026)

Side conversations (`lib/spawn.sh` A SIDE SESSION, `lib/side.sh`, `lib/retire.sh`, `lib/sessions.py` `transcript`, `web/src/sala_web/spawn.py`,
`docs/side-sessions.md`). A wrong answer here is a side session that can be retired without its write-up, one that lands on an agents map or
with a role, a fork of the wrong conversation or directory, a summary sent twice or before the write-up exists, or a marker written with a
check failing. `side.sh` (85; +14 on Tue Oct 27th for the header decision: a `-main` marked at once, another agent plain then marked once on stackshot's front-agent refusal, any other refusal not retried, `--summary-to projects/<slug>`, the name check): the argument matrix; the names; the dry run; the real start of each kind with the mandate's content, the
record and the registry row; `side done` in every mode (the three checks, each failing alone and together, the repeat, the failing send,
`--item-updated`, the page-ts fallback); the retire gate. `spawn.sh` (+9): the queue side (the shape refusals with nothing queued, the plan,
the marker's arguments, a conflict, a start about a project with no page, `op retire` of a side session refused at queue time and passing
with the marker). `sessions.sh` (+8): `sessions transcript` (current first, the file or "not on this box", `--json`, retired and live,
ambiguous, none, read-only). `test_side_sessions.py` (35): the argv for both starts, every id form passed whole (`board#N`, `sN`,
`board-tmp-box#N`), the blank name suggested, 17 bodies refused before sala, the item lookup, and in a headless Chromium the Discuss link
for each id form, the submit, the fork link, both forms linking to each other, the name rule and a 320-pixel phone. Nothing was dropped
from the existing suites; the one stand-in changed is `newsess-sala`, which now answers `spawn --suggest-name --side`.

### The New session and Quick session pages, round two: `tests/spawn.sh` +26; `web/tests/test_new_session_ux.py` new, 14; `test_session_order.py` new, 7; six files changed (Mon Oct 26th 2026)

The two forms (`lib/spawn.sh` `suggest_name`, `web/src/sala_web/spawn.py`, `app.py`, `static/app.js`, `index.html`,
`style.css`, `docs/side-sessions.md`). A wrong answer here is a suggested name that is taken (a running session, a registry agent, a name
stackshot holds) or has the wrong prefix (`work-wiki` for a project whose agents are `wiki-*`), a `-main` suggested for a project that
already has one, a failed create that says nothing, a default that says "use default" without the value, a project box too tall for a phone,
a Quick session started with no item and no fork, a deep link (`#side=<id>`, `#side=from:<name>`) that stops working, a session order that is
lost on reload, a drag that moves a session into another project, or an element added to the session header (its fold is measured to the pixel).
`tests/spawn.sh` (+26): `--suggest-name` with the project record (prefix from the agents' names, never from the page key; `-main` only when
the record has no agent; 12 runs of a front on a project with agents, 30 runs of a back with seven names taken by the map or by tmux; `--prefix`
on an unknown project, over the record, with no record, refused when bad or without `--suggest-name`; `name_taken`'s three sources;
`-main` only when the fresh record lists the project with no agent or `--new` says it has no page yet, so a missing, stale or silent record
and an unknown project give a word; no room for `-main` in a long prefix gives a word; a real spawn with no NAME keeps the older rule
(a front is `<prefix>-main`); `--new` refused without `--suggest-name` and with `--side`).
`test_new_session_ux.py` (14): the shape of the project page's rows through the form, `wiki-<word>`, `-main` only for a new project,
the suggestion retried when it is taken (4 calls, then a local word), running-session names refused, the folded one-line summary and the
arrow, Enter and the keyboard, the header row and the narrow name column at 1280 and 390 px, `use default (<value>)` for each lane
(`subscription-1`, `subscription-2`, `api`), the model and effort selectors with "other…", what is sent, and the composer bullet in the text colour in
both themes. `test_session_order.py` (7): the default order untouched, a drag reordering inside its project and kept through a reload, the
click that follows a drag swallowed, a saved order with a new session placed after it and unknown names ignored, no drop into another
project, the header untouched, and a saved list of 497 gone names plus the live ones cut to the live ones and 100 gone ones
when the order is saved, so the cap of 500 never drops a live session's place.
Changed, with the count now: `test_side_sessions.py` (38; the tail was rewritten for the `np-switch` segmented switch, the pickers, the two
optional fields, the refusal reason, no loose links, a phone), `test_prefs.py` (18; `sessionOrder`), `test_new_session.py` (46; options carry
models and defaults; settings.json's model and effort; the stand-in `sala` now answers `lane --json`, `--prefix` and a per-agent suggestion),
`_scope.py` (23), `_page.py` (6), `_column.py` (9) and `test_composer_cm6.py` (18; the bullet's colour now equals the text's). No test dropped. The full suite
found one thing these missed: a row that starts a drag on a press captured the pointer, so a click on its board mark never arrived; four checks
in `test_back_button.py` (the sheet over the drawer) are its guard, and the row now leaves a press on the mark alone. What a name now needs: the
tests that used `work-demo-main` on a project that has agents wait for `work-demo-pink` (sala picks a random free word; the stand-in `sala` of these tests always answers the first free one of pink, plum, reed, rust, which is test-only) and the add-agent
step that comes first. Not covered, and why: any physical phone (the 320, 390 and 1280 px layouts are measured in the harness only).

### The page's palette moved to stackshot's: `web/tests/test_theme_contrast.py` new, 126; four files changed (Wed Nov 4th 2026)

The page's colours were a warm grey with an orange accent; they are stackshot's now (a blue accent, `#fafaf8` and `#161617` pages), with the front badge and the
metered lane kept on stackshot's orange. A wrong answer is text a reader cannot make out (a muted or faint grey, a link on a user's bubble, a state word on its own tint, the
red unread chips in the dark theme, a badge's words on its fill), a status bar or splash that does not match the page, an orange that is the accent again (the front badge
turned blue), or a stale colour of the old palette left in a file. Kept: 120 measured pairs (60 a theme, pure Python over the tokens parsed from `style.css`, each at least
4.5:1: every text token on every surface it sits on, text on a solid fill, a state colour on its own 12% tint, the role badges on their 20% fills, the search highlight);
the dark theme's two declarations (system scheme and `data-theme`) agreeing, with every token a plain hex in both themes; the selected row reading `--faint` as `--muted`;
the stackshot values spot-checked; the front badge, its search twin and the metered lane on `--call` and never the accent; the two `theme-color` metas and the manifest
equal to the `--bg` tokens; no hex of the old palette left in any static file (the sala icon's orange is checked to be the one that stays). Changed: the unread count's
tests now hold `--accent-text` on `--accent` at 4.5:1 (they held white and 3:1), the header test the badge on `--call`, the machines test the two tile classes the
Machines tab got. Not covered, and why: a physical phone's status bar, the installed app's splash screen and the page behind the access proxy's login (none can be driven from this
box; the metas and the manifest are held to the tokens, and the render is measured in the existing browser tests). The screenshots are judged by eye.

### sala UI v2 served at `/v2/` as a layer over v1: `web/tests/test_v2_design.py` new, 15; `test_v2_layer.py` new, 29; `test_v2_browser.py` new, 4 (Wed Nov 4th 2026)

`/v2/` is the same app drawn with stackshot's look: a pass (`web/src/sala_web/v2/design.py`) rewrites v1's stylesheets, `index.html` and `app.js` when they are asked for
and caches the result by the source file's mtime, so v1 work that lands during the trial flows into `/v2/` by itself. A wrong answer is a v2 that drifts off its scale
(a size, weight, radius or spacing the design does not have, a letter-spacing or capitals, a second column width, the code face on prose), a rule the pass skips because it
sits after an `@media` block, a pass that finds no anchor in a changed v1 file and says nothing, a v1 page or file that is no longer byte for byte what it was, a second
installed app (a manifest or a worker registration on the v2 page), a `/v2/api` path that answers otherwise than `/api`, a transform bug that turns a page into a 500, and a
page that scrolls sideways, logs an error or lacks its font on a phone or a wide screen.
`test_v2_design.py` (15, pure text, no server): the output of the pass over every stylesheet `static/` serves (not `vendor/`) holds the five sizes (16 px on form fields), the weights 400
and 600 (500 on tags), no letter-spacing, no uppercase, radii of 0, 2, 4, 8 or the pill, spacing on the 4 px grid (2 px and under left alone), one 920 px column, and the code
face on code only (the old face's name appears nowhere outside comments); the page pass and the script pass find every anchor (a miss fails here, so CI shows it); every inline
icon the page draws is on the 24 grid with a 2 px stroke and round ends; a small rule per thing the pass does (shorthand `font:`, `bold`, the grid, the radii, the column). `test_v2_layer.py` (29, HTTP on the test app): `/` and
every `/static/` file byte for byte v1's; `/v2` redirects; `/v2/` is 200 with the title mark, the face and the additions once, no manifest link, no
worker registration; each stylesheet answers as CSS, transformed, with no other font named; the font served as woff2 with its licence beside it; `no-cache` and an ETag, and a
304 on the same ETag; `/v2/api/...`, an event stream and a write answering as `/api/...`; the prefix middleware on http and websocket scopes with the cookie and other headers
and the query untouched; a pass that raises falling back to v1's file and logging once, never a 500; the cache re-reading when the source or the pass changes.
`test_v2_browser.py` (4, one headless Chromium at 390, 768, 1024 and 1440 px, as `test_search_ui.py` drives it): the Agents, Schedules and Machines tabs, a chat, Search results and the
New session page each open on `/v2/` and are drawn; no sideways scroll; on 1024 px and wider the content column is at most 920 px; no console error, uncaught exception or
failed request (the two CDN stylesheets are blocked, so the run needs no network); the monospace face reports `loaded`; no manifest and no registered worker; the tab title starts with
`v2 · `. The conftest driver now keeps the DevTools events it reads (`CDP.events`), nothing else of it changed. Related suites run with the change: `test_installable.py`,
`test_lane_subscription_codes.py`, `test_theme_contrast.py`, `test_socket_compat.py`.
Not covered, and why: the 44 px controls of a coarse pointer (this driver cannot emulate `pointer: coarse`; the by-pointer sizes are in `extra.css` and seen only in screenshots); a
physical phone's browser, its status bar and the installed app (none can be driven from here); live data (long names, a full fleet, a populated board: the stubs are small); the
Quick session and lane pages in the browser test (they call sala's CLI, which tests do not run) and the Terminal view's own page and the Shell drawer (not restyled on purpose, see
`web/README.md`, "/v2"); that `/v2/` looks like the approved mockup (judged by eye from screenshots, there is no pixel test); a real websocket under the
prefix (the app has no websocket route today; the middleware is held on a websocket scope only); `tests/suites.map` was not re-measured for the three files (web tests are not
enforced by `suitemap.sh --check`). The suite table in `CONTRIBUTING.md` lists only the `tests/*.sh` suites, so it gets no row.

### The agent order kept on the agent, not on its name: `web/tests/test_agent_id.py` new, 5; `test_session_order.py` 7 → 14 (Mon Nov 2nd 2026)

The sidebar's saved agent order was keyed on the session name, which changes (`sala rename`, a conversation's title), so a renamed agent dropped to the end of its
project. It is keyed on the registry's permanent id now. `test_agent_id.py` (5): the id found through the conversation, the name or the tmux session, a row given to
one session only, the conversation beating a crossed name, and the registry file read (live rows only, a bad file gives none). `test_session_order.py` (+4, and the
7 now save ids): a recycle (new pids, panes and conversation ids, part of the fleet gone for a moment) keeps the order, a rename keeps the place and a new agent goes
last, an agent with no registry row is kept by its name, and an order saved by names is read (a renamed agent's old name through its aliases) and rewritten once as ids. A list is saved from the server's current list, never the page's copy:
a page that holds only defaults, or whose prefs failed to load, saves just the project it was dragged in and leaves the stored order of the others (and the other keys)
alone, and a page that cannot read the stored prefs saves nothing.

### `web/tests/test_fork_menu.py`: new, 6 (Mon Oct 26th 2026)

Fork moved from a header button to a **⋯** at the end of each sidebar row, because the header's fold is measured
to the pixel. A wrong answer is a fork of another session than the row's, a fork offered where it cannot work (a session with no tmux pane
to take a conversation from: the sdk lane's), a menu that stays open over the page or opens the session under it, a session started by
the menu itself, or an element added to the header. Kept: the ⋯ only on the rows that can be forked (a quick session is forkable, as
`lib/spawn.sh` allows; the sdk lane's row has none); the menu offering Fork with `#side=from:<name>` for that very row, whole on the screen,
the click not following the row's link; the link opening the Quick session form with the fork filled in and nothing spawned; a quick session's
own menu; Escape, a click elsewhere, a second click, and the keyboard (Enter opens it with the entry focused, Escape gives the focus back to the
button: that check found the button hidden once the menu closed, so it kept no focus, and the order in `closeRowMenu` was changed); a phone
showing the ⋯ on the open session only; the header unchanged. Not covered, and why: a real hover and a real touch. Headless Chromium reports
`hover: none` and a fine pointer in every mode, so the stylesheet's `(pointer: coarse) and (hover: none)` rule never applies there; the
hover is held by focus (`:focus-within` shows the ⋯ as hover does), and the rule itself by a check of the stylesheet's text. `sala spawn --side
--fork-of <agent> --dry-run` was run by hand after the change: unchanged, nothing made.

### `tests/sessions.sh`: new, 54 (Wed Oct 21st 2026); one check added to `tests/spawn.sh`

The session registry (`lib/sessions.py`, `lib/common.sh` THE SESSION REGISTRY, `lib/sessions.sh`): a second file written after the
pane map, whose failure must never cost a session its pane-map row, so every check guards one of "lose a session" and "corrupt the
pane map", or the property the later phases rely on (an id that stays one session's). Kept: the id minted on `add`, a uuid4, the
row the map's (name, pane, cwd, `transcripts[0]`); the id the same after one and two renames with the old names as aliases, and a
repeated add making no second row; `follow` leaving the file byte-identical (a follow that flips back and forth must not rewrite it);
`lane_write`, `model_write`, `model_drop` and the `--project/--role` copy landing, an unknown lane refused as before, a mapped
session with no row getting one on its first field write and an unmapped one getting none; `retire` keeping the row
(`state=retired`) and removing the map row, a re-added name minting a new id and leaving the retired row untouched; the history copy
and the log lines; the listing (`--all`, `--json`); the three drifts a kill between the two writes leaves (a missed add, rename,
retire) reported with exit 1 and nothing written by `--check --dry-run`, repaired by `--check`, consistent on a second run, and a
lane the table and the row disagree on brought back; `--migrate --dry-run` printing one `would mint` line per row of a seeded map
(lane, model, effort, aliases from `salamander-renames.jsonl`, including a two-step rename chain) and writing no file, the real run
making them, a second run none, the map untouched; the pane map byte-identical across a run with the registry on, off and on a
corrupt `sessions.json` (the corrupt file left as it was and logged, `sala sessions` exiting 1 on it), a missing helper costing one
log line and no map write; `SALA_SESSIONS=off` writing no file, log or history and `--migrate` refusing; the registry waiting for the
pane map's lock and then landing, and eight parallel adds all landing in a valid file. Not checked: a real `rename`, `retire` or
`spawn` end to end with the registry on beyond what `ledger`, `ledger-recycle`, `retire` and `spawn` already run (their map-file
comparisons pass unchanged), a production dry run, a concurrent `lane_write` against `ledger_write` beyond the shared-lock check.
`tests/spawn.sh` gained one check: after a project spawn the registry rows carry project, role and the recorded lane.

### `tests/sessions.sh` 54 → 87 and `tests/sessions-spawn.sh` new, 21 (Thu Oct 22nd 2026)

The explicit signal for a fresh start (`lib/sessions.py` `prepare`/`abandon`/`record`, `lib/sessions.sh` `record`, `lib/hook.sh`
`session-start`, `lib/spawn.sh`, `lib/unpark.sh`). Every check guards one of "a start is recorded on the wrong row", "a start is
recorded twice", "the hook disturbs a session start" or "a failed spawn leaves a row". `sessions.sh`: `record` by name, by id and by the
8-character prefix, `why` kept and `--machine` stored; the same conversation twice (any `why`) leaving `sessions.json` byte-identical;
an unknown id or name, a missing or bad `--transcript`/`--why` and a retired name refused with exit 1 and nothing written;
`SALA_SESSIONS=off` writing nothing (file and log) and exiting 0; the pane map's lock waited for; `prepare` returning a uuid4 and the
same id to a second call, the row live with no conversation, the following `add` reusing it, `abandon` dropping a row with none and
keeping one with one; the hook per source (clear, resume, startup recorded with their why; compact and an unknown source nothing),
exit 0 and an empty output on every path, an `sdk-cli` run ignored, an unknown id, no id and no pane, off, the missing sala binary,
empty stdin, and ten kinds of garbage on stdin (text, truncated or wrong-typed JSON, a path in `session_id`, binary); the fallback by
the pane's tmux session name on a private server. `sessions-spawn.sh` (fake claude, private tmux socket): the spawned pane's claude
process and tmux session carry `SALA_SESSION_ID` equal to the one live row's id, with the first conversation on it (`add`); a name
with a live row keeps its id; `SALA_SESSIONS=off` exports nothing and writes nothing; a spawn whose claude dies leaves no row and
one `abandon` log line; `sala unpark` adds the fork as `resume` once (not `add`), the map moving as before, and recording it again
changing nothing. Not checked: a real Claude Code firing the hook (the fake runs none; the payload fields are the documented ones),
`claude -p`'s `CLAUDE_CODE_ENTRYPOINT` inside an sdk-lane pane, the settings entry (not in this repo).

### `tests/sessions.sh` + 33 (`sala sessions tag`, Sat Oct 24th 2026)

`lib/sessions.py` `tag`, `lib/sessions.sh`, `lib/common.sh` `sessions_tag`. Every check guards one of "a field lands on the wrong row", "a
write changes more than it was asked to", "a refused tag writes anyway" or "a registry file is damaged". Kept: set by name, by id and by the
8-character prefix; `--project-key` landing in `project` (and the published copy's `project_key` equal to it); only the given fields
changing (name, id, state, pane, lane, transcripts untouched); `--dry-run` leaving file and log byte-identical; the same tag twice leaving
`sessions.json` byte-identical; `resolve role:<project>/<role>` finding the row afterwards, and exit 2 once a second live row fills the same
role; ten argument errors (a bad role (upper case included), a missing value, whitespace in the project, `--project` and `--project-key`
disagreeing, no session, two sessions, no field, an unknown option) and three unknown sessions (also under `--dry-run`) each refused with
exit 1 and the file byte-identical; a retired row refused by name and by id; a corrupt file left as it was; `SALA_SESSIONS=off` refusing;
the pane map's lock waited for. Dropped (not written): the exact wording of the messages beyond "no session" / "retired" / "also fills".
Not checked: the command against the live registry (the tests use a temporary state directory).

### `tests/autorecycle.sh`: 81 → 56

Kept: what launches and when. Nothing for 0 board items or a failing command; one recycle at once on a busy box; its
unit's `KillMode=process` (the driver must outlive the unit, or a recycle dies mid-relaunch) and lock settings; requests
recorded, cancelled, served once, expired; the hourly limit; no recycle with the map frozen; the cued recycle run for
real (the busy pane skipped, then relaunched by its retry worker); the CLI auto-update (the update at once with
`--no-recycle`, one relaunch per version, its unit and lock; a box the update unit found offline gets its try back and is
launched again on the next run, a real attempt keeps it, a retry run posts nothing of a box that stays offline);
`update --no-recycle` (no relaunch, no wait for the lock).

Dropped:
- the posts' trigger and requester wording, the update post's shape, "watch posts nothing for either".
- the log lines: hourly limit, expiry, the auto-update and relaunch lines, "no idle wait logged" (the launch count
  already shows it).
- `--when-idle --list`'s display, the usage line, the request's "cued at the next run" text.
- `SALA_RELAUNCH_KIND=auto/update` on the launch lines: it changes only the words a waiting pane is told.
- `provision --help`, the other launches' unit names: config echoes and trivia.

Kept from the provision sets: the relaunch of a box that answers ssh again, once per `SALA_RETRY_EVERY`. It counts launches of
`provision --no-recycle`, which proves an automatic provision never recycles the fleet.

Added after the cut (Mon Oct 12th): served ids the board reports cleared. The real `post_recycle_hook` runs a
stub command; a command that fails hands over nothing, a report naming `none` changes nothing, a report naming `s1, s2`
drops s1 from the served ids and keeps s2, which does not recycle again; s1 flagged again then recycles once.
The board's cached answer from before the clear is asked again (without that, a stale listing still naming s1 recycled
the box once more). `<id>@<epoch>` tokens: a new set time for the same id recycles, the same token does not, a bare id in
the report clears the token. On main a served id was never counted again, so one item, flagged again for a new change
two hours after its auto-recycle, waited for the owner's cue. One check reads the post's text (the id shown without its
`@<epoch>`): the epoch is a machine field, and a post naming it would read as an unknown item.

### `tests/busyhooks.sh`: 68 → 44

Kept: the whole busy check. `hook stop` from every payload shape (exit 0, silent, a record or none), the record and its
stamp, the waiters, `is_idle` with a busy record (a shell task; a subagent, a monitor, a workflow), an empty one, a stale
one, the parked fork, the 10 s settle; `hook post-tool` silent without a flag and without reading stdin, the line once
per relaunch and again for a new one, silent after the clear; pruning and clearing; the ready path end to end (busy by
its record, the flag, not relaunched while busy, relaunched at once on the empty record, the flag down, the worker done).

Dropped:
- `is_idle_reason`'s exact sentences (the busy verdict stays), the line's text on its own, the words per kind, the kind
  from `SALA_RELAUNCH_KIND`, the config override of the text, the flag's `what`.
- the worker's wake log line, the closure post naming the pane.
- the second ready-path run (`SALA_RELAUNCH_KIND=update`): the kind changes only the words, so it repeated the first.
- the no-flag timing echo (reported, never checked).

Borderline keep: "flag up: additionalContext = the relaunch notice" compares the exact line. The JSON is parsed by Claude
Code, and the line carries the `sala ready` instruction the ready path depends on.

Added after the cut (Sat Oct 10th): a claude whose only child is a plugin's MCP server (`CLAUDE_PLUGIN_ROOT` in its
environment) is idle by the child-pid guess, and one with a plain child beside it is busy naming only the plain child.
A recycle skipped most panes because a plugin's MCP server read as background work: a session never relaunched.

Added for the auto-armed artifact watch (Sat Oct 10th; 6 checks): a record holding only the watch Claude Code arms
on publish (its description text) reads idle and keeps the URLs; the watch beside a shell reads busy, the shell named; the
same words on another monitor, or other words after the URL, still count. End to end, `revive --only` relaunches a pane
whose only task is the watch as it is: nothing reaches the resumed session's inbox and the sweep says nothing of the watch
(the CLI arms it again on the resume; a watch the session itself stops comes back only on the user's own message, which is
why sala neither stops nor re-requests one); a pane with the watch and a shell stays as it is. A recycle skipped panes
for the watch alone; a pane read idle with real work beside the watch would lose that work at /exit. The fake claude
logs what reaches its messaging socket (`FAKE_SOCK_LOG`, a thread, so no child process appears under it).

Added for every artifact watch label (a follow-up, Sun Oct 11th; 5 checks): with only "auto-armed on publish" exempt,
a watch the session armed on request ("watch requested") kept its pane busy for ever, and the auto-armed watch came back
after a relaunch as "re-armed on session resume" and blocked the next recycle; no artifact watch is work in
flight. Each of the seven labels Claude Code 2.1.296 writes alone reads idle and keeps the URL; "watch requested" and
"re-armed on session resume" are checked on their own as well; a requested watch beside a shell reads busy, the shell
named and the watch not counted; near misses (more words after the label, a cut-off label, another case, two labels)
still count. The earlier near miss "(watch requested)" on a monitor became "(watch started)", an unknown label.

### `tests/mod.sh`: 37 → 34

Kept: `mod_request` (no stamp, a stamp, a stale stamp, an old protocol, the state-dir fallback with and without
`XDG_RUNTIME_DIR`, no reply, no socket, no process); the request line the mod parses; `mod_env_prefix` behaviour
(appended, never clobbered; off when switched off, absent or needing quotes: a bad launch line means no resume);
`resume_cmd` and `spawn` carrying it; `pane_draft` (either the mod or the screen counts); `pane_exit`'s refusals (the
session untouched); `pane_rename` and its keys fallback; a recycle through the mod, refused by it, and by keys once the
stamp is stale.

Added after the cut (a follow-up, Fri Oct 9th): a `spawn --fork` whose claude comes up and dies 3 s in must fail and
leave no pane-map row (the old `wait_for … claude` passed in those 3 s, and spawn renamed and mapped a dead pane). unpark
uses the same `resume_wait` and has no suite of its own.

Added after the cut (Sat Oct 10th): the mod refuses the exit while a turn runs (`reason: turn`), `pane_exit` returns 4 and
types nothing, and the recycle skips the pane as transient, the session untouched. On main the refusal fell through to the
keys and typed /exit. The mod's own tests (`claude plugin test mod`) hold the mod side: refused while the main loop's or a
subagent's turn runs, ok once both completed, and a session start clears a turn a crashed process left open. Until then
the mod ran /exit mid-turn, the CLI handed it to the running turn as a queued prompt, the model read it as text, and the
pane never exited.

Added after the cut (Sat Oct 10th): `resume_send`, the one place a resume line is typed (the sweep's phase 3, the
self-worker, unpark). It types nothing into a pane running claude, nothing for a conversation live elsewhere, and of two
runs racing into one shell exactly one types. On main two retry workers that woke together both relaunched
one pane, and the second resume line sat in the first one's prompt box, blocking every later
relaunch of that pane as "unsubmitted text".

Added after the cut (Sat Oct 10th): `pane_exit` types no /exit for a claude already gone (it would land in whatever runs in
the pane), and in tests/sets.sh a finished retry worker leaves no pid file. On main the worker's EXIT trap read its local
`pidf` after it was gone ("pidf: unbound variable") and left the pid file and waiting flags behind.

Added for the auto-armed artifact watch (Sat Oct 10th; 3 checks): a mod loaded before the fix still refuses the exit
for the watch. When its refusal names monitors only and this stretch's busy record says they are all auto-armed watches,
`pane_exit` types /exit and the pane is relaunched as it is; a refusal naming a shell, or a record with a shell beside the
watch, stands. Without it every pane started before the deploy would be skipped (then deferred and retried every 2 min)
until a hand relaunch. The mod's own tests (`claude plugin test mod`) gained one: the watch alone is answered ok; beside a
shell the exit is refused naming only the shell; other wording on a monitor, or the wording on a shell, is refused.

Added for every artifact watch label (a follow-up, Sun Oct 11th; 2 checks): a mod loaded before the follow-up refuses
the exit for a watch armed on request too; the bridge takes a record holding only a "(watch requested)" watch as the
watch's refusal and relaunches the pane by keys, and still lets the refusal stand for an unknown label on the monitor. The
mod's own tests gained one: the exit answered ok for a watch alone under each of the seven labels; a requested watch beside
a shell refused naming only the shell; near misses refused.

Dropped: the exact prefix string (its behaviour is checked right after), "the prefix changes the one command only"
(bash semantics, not sala), "an answered draft request writes no log line" (log trivia).

Added for the message marker (Mon Oct 12th; asked for by stackshot, whose quote-origin check reads a pane's transcript;
7 checks): every message `tui_send` types (spawn's brief line, `--prompt`) goes in as `<!-- sala --> …` and a slash command
bare. The CLI records a typed message with origin "human", as it does the user's own, so a line of a sala-typed brief would
pass as the user's without the marker; a marker on `/exit` or `/rename` would turn the command into a message (the pane never
exits, the name never takes). A marked line left in the box is sala's own and is cleared before the next command; someone's
draft still refuses the send with nothing typed; spawn's brief line carries the marker end to end, and nothing else spawn
types does. The fake claude logs every line that reaches its composer (`FAKE_TYPED_LOG`). Kept under the rule: a program
(stackshot) parses the exact string, and a broken slash command loses the relaunch.

### `tests/guard.sh`: 106 → 82

Kept: the whole deny table (reboot, CLI update, tmux kill-* on the fleet's server, kill of a claude process or group,
`SALA_TMUX_SOCKET` from the environment and the config); the master's pane exempt and another pane denied; a pane on a
private server passing; every fail-open input.

Near misses, one row per kind (they are the guard's precision): an echoed word, a grep pattern, a git message, a
heredoc's body, a trailing comment, another installer, a systemctl verb on reboot.target, `shutdown -c`, a claude
subcommand, downloading the installer, reboot as an argument, `tmux -L … -f /dev/null`, `tmux -S <private>`, a tmux
command that kills nothing, a pid that is not claude, a pid that does not exist, a job spec, `$(pgrep …)`, a pipe to
xargs, a pkill path under `~/.claude`, a pkill of something else, ssh, and sala's own update and reboot verbs.

Dropped:
- the other near-miss rows of the same kinds (a quoted echo, a second grep and git message, the quoted and `<<-`
  heredocs, a leading comment, apt and uv, a second systemctl and claude subcommand, `command -v` and `test -x`,
  `-L x` and `-Lx`, capture-pane, `-S` default list-sessions, `kill $pid`, `kill -l`, a pkill path under
  `/tmp/claude-<uid>`, `sala cue` with a quoted reboot, `salamander recycle --update`).
- the deny reason's exact wording (the pane and master named, the private-server hint, `<you>` outside tmux): a fix is
  still required in every deny (since Thu Oct 15th 2026 the `sala op … --words` one, never `sala cue`).
- the timing report (never a check).

Added on Thu Oct 15th 2026 ("No master session"; 6 checks, 82 → 88): the fix names the queue's verb for the
kind — a CLI update → `sala op update`, a tmux kill-* → `sala op retire <session>`, a kill of
a claude → `sala op retire <session>` with `revive --only … --force` named for a relaunch — and neither the master nor
`sala cue` (a session reading the deny must find the one door);
with no master configured the former master's pane is denied like any other (the exemption is the master's,
and there is none). The hook's logic is unchanged, so the table above still holds.

Changed on Thu Oct 15th 2026 (a reboot is not queued; 3 checks, 88 → 91): a reboot's deny no longer names `sala op reboot`
but says the owner runs `sala reboot --go` themselves and the session shows them `sala reboot --status` and waits for their word
(`SALA_OP_REBOOT` is off by default and unsupported until a confirmation path is built), checked word for word on `sudo
reboot` and for three more reboot shapes (`reboot`, `systemctl soft-reboot`, `telinit 6`: none may point to the queue),
and every deny's verdict requires that wording for a reboot and the `sala op … --words` fix for the other kinds; a CLI
update's deny must not say "not queued".

Added on Thu Oct 15th 2026 (1 check, 91 → 92): `sala op spawn … --from --words` passes as sala's own verb (the
queue's new verb must reach the queue from a session). The hook's logic is unchanged: every `sala`/`salamander` command is
exempt, so a raw `sala spawn` from a session passes too — spawn calls no guard of its own, and a spawn skill relies on
that; whether the project spawn should be queue-only is open (the suite asserts nothing about the raw form).

### `tests/reauth.sh`: 17 → 7

`--done` hands a forced fleet recycle to the master, so what stays is what keeps it from cueing one for nothing: nothing
cued while the connector needs authentication, failed to connect, fetched no tools or has no status; the exact cue the
master acts on (with `--from`); the hand-over to `sala cue`.

Added on Thu Oct 15th 2026 (no master; 1 check, 7 → 8): with no master `--done` prints the exact `sala op
recycle --force --from <you> --words "<the owner's words>"` line, queues nothing (the queue takes only the owner's words
verbatim, and these are the verb's own) and exits 0. The master checks now name one through `SALA_CUE_TARGET`, on a private
tmux socket directory (`TMUX_TMPDIR`), so the cue's "not live" answer proves the hand-over.

Dropped: the usage lines, the sign-in link and its follow-up line, the login's arguments and the name's `claude.ai `
prefix, several words, a missing connector's message, `--done` not starting a login, the cue without `--from`: a broken
`reauth` login loses nothing.

Borderline keep: a token-looking value in a failed login's output is masked. Not a loss path, but it follows the rule that
a secret is never printed.

### `tests/sets.sh`: 37 → 22 (+16 for the later addition, below) and `tests/sets-master.sh`: 19 → 10

Kept: the set state under ten parallel writers (no write lost, one "set closed"), a settled pane ignored, takeover
(superseded sets; a newer recycle stops a worker), a real recycle leaving two panes behind and closing the set when they
come back, a give-up posting "closed at" exactly once and never "set closed", two workers on one set, a deferred pane
closing its set through watch and leaving the deferred list. The master's own pane: counted outstanding at once while the
first post goes out, settled by the self-worker, relaunched in a clean recycle, given up once when it fails, relaunched
by a retry worker when handed off.

Added after the cut, both checks of the set file: the failing master's resume comes up and dies
3 s in, and the set must say 1/2 and closed (the old `wait_for … claude` check counted it relaunched, 2/2, "Recycle
done", whenever the 1 s poll landed while it was up); the clean recycle's master registers 6 s in, past
`SALA_RESUME_WAIT`, and the set must still say 2/2 with nothing outstanding (a slow start is never a failure).

Dropped: every headline and bullet wording check (the label's format, the emoji, the per-pane bullets, the retry note,
"not relaunched yet", the timing bullets, "open it on claude.ai"), post counts that only guard noise ("no other closure
post", "two posts in all", "the sweep did not post"), and the old-style post's absence. Where a headline carried state
(n/N, closed) it became a check of the set file instead.

Added for the board after a late relaunch (Mon Oct 12th; 11 checks in `sets.sh`): the post-recycle
command stubbed to a file of `<started>|<skipped>` lines, on the flows the suite already runs. The driver's call names
the two panes a real recycle left behind; the retry pass that brings them back calls again with the recycle's own
`started` and nothing skipped, at most one call per pane back. In the give-up flow the pane that comes back is reported
with the other still named, and the give-up at the window's end adds no call. Two workers on one set each name the
right remainder (w2 while w1 comes back; nothing after w2; no call while both are still skipped). Nothing fires for a
set the driver has not reported through (no `hook=1`), for a worker stopped by a takeover, or for a settle the set
ignores (someone else's pane); watch's deferred relaunch reports with the set's start. On main the driver's calls and
the six negatives pass and the five late-relaunch checks fail: nothing told the board once a retry worker or watch
relaunched a skipped pane, so an item whose mover came back later
stayed in the user's queue as "Pane recycle needed". Like the `phases.sh` borderline keep, not a loss path, but a
program parses it: the board's flag is what the user sees.

Added for the panes sala must not relaunch (Tue Oct 13th 2026; 6 checks in `sets-master.sh`): with
`SALA_NO_RELAUNCH` naming one of three panes, a recycle's sweep relaunches the unlisted pane and leaves the listed one
alone, its summary saying so; the listed pane is in neither the skipped rows nor the post-recycle hook's skipped file,
and the set counts N=2 (the unlisted pane and the master's) with nothing of it outstanding; `revive --only` on it refuses
and relaunches nothing; `restore_session` refuses it. A loss path: a pane launched by hand on its own API key
would be brought back by sala's launch line without that key.

Added for deferral (Thu Oct 22nd 2026; 16 checks in `sets.sh`, 1 changed in `busyhooks.sh`): a recycle skipped
a pane that had said `sala ready` repeatedly and gave it up at the window's end, because its background Bash loops kept the
registry state at `shell`, which the retry worker read as transient. A pane lost to the next recycle with its work in
flight is the loss path. (1) A ready pane whose registry state is `shell` goes on the deferred list at once: the worker
ends long before its window, the log never says "still skipped", the set keeps the pane outstanding with nothing given up
and not closed, the report names it as deferred, its claude pid is unchanged (nothing relaunched earlier than before),
`watch` leaves it alone while the state is `shell` and, with the state back at `idle`, relaunches it and closes the set 2/2.
(2) The window's end defers a pane still pending (an unsubmitted draft): on the deferred list with its reason, outstanding
in a set that stays open, no "closed at" post, the report naming it as deferred with the draft as the reason; `watch` does
not relaunch it while the draft stands (the new guard in `deferred_revive`: each try would start a retry worker), and
relaunches it once the draft is sent, closing the set 1/1. The old give-up section now gives up a pane that is gone (a
real give-up, "closed at" once, no "set closed"). On main both new sections fail (nothing is deferred; the pane is "still skipped" or given up).
(3) The waiting line the PostToolUse hook gives a session says to stop its own background watches (TaskStop) and put what
they were waiting for in a `sala note` before `sala ready`: the existing exact-line check in `busyhooks.sh` takes the new
text and fails on main. Not a loss path in its own right, kept because the line is the only thing that frees a pane from
its own shells.

Added for the short deferred-pane bullets (Thu Oct 29th 2026; 10 checks in `sets.sh`, 11 in `holders.sh`, 1 changed in
`holders.sh`): Recycle posts named a held pane with a long reason that carried pids, uptimes, task ids and commands
(`registry says 'shell' (a turn or a dialog is running); running under it: pid 31, up 5 h, task …: until ! pgrep …`), and three
different sentences for it in the first post, the "n deferred" post and the 🔄 follow-ups. Now one line per pane, the same in all three
(`common.sh`, `hold_bullet`): `<session>: busy for <age>; sala relaunches it once it is free` (a turn or a dialog), or
`<session>: its <n> background tasks ran for <age>; sala relaunches it once they finish` (`its 1 background task ran for …`), with
the age in short words (35 min, 2 h, 1 day). `holders.sh` (unit): the age words at their edges; three holders under a registry
`shell`, one holder under `shell`, one child under an idle pane, registry `busy` and "a turn is running" (the /exit refusal), a `shell`
row with no process behind it (worded "busy", never "its 0 background tasks"), a row that cannot be read (no age, both parts of the
line still there), a draft, a prompt, the idle-settle wait and a parked pane (neither kind: left to the caller's own text), `scan
--summary`; every bullet checked for no pid, task id, subagent id, command or "registry". `sets.sh` (end to end): two panes whose
registry says `busy` through a real `recycle --force`, the retry window ending and `watch` relaunching one: the first post's bullet,
the deferred post's bullet and the 🔄 follow-up's bullet for the other have the same words (only the age may differ), none of the three
posts has a pid, an uptime, a task id, a command or the registry wording, and the revive log still holds the long reason; the ready-but-
`shell` pane's deferred bullet is the short form; a 🔄 post prints a tasks bullet and a busy bullet whole while an old-style reason
(a dialog) keeps "still waiting, <why>". Existing assertion changed: `holders.sh`'s `shell` reason no longer says "(a turn or a dialog
is running)" but "(background shells or tasks hold the pane)"; its "registry says 'shell'" head, which `transient_skip` and `reboot.sh`
match, is unchanged. Not checked: the tasks bullet through a real recycle (the fake claude has no child process to count; `holders.sh`
covers it with real children), and the watch's 3 h "not relaunched after …" post, which still names the holding commands on purpose.

Added for the grouped hold lines (Tue Nov 3rd 2026; 6 checks in `sets.sh`, 1 changed): the first recycle post listed every pane held back
for the same reason, one line each. Now panes held for the same reason are one line with a count once more than 5 share it
(`common.sh`, `post_group_bullets`): `all 45 sessions were relaunched 4-16 min ago on 2.1.317: each rests 30 min, then sala relaunches it`
(the minutes as a range, the resting-until times left out, the rule kept); a busy pane and a pane held by background tasks by kind alone
(`8 sessions are busy; sala relaunches each once it is free`); any other reason by its text. 5 or fewer keep a bullet each, the session
named. The 🔄 follow-ups (`30 sessions still waiting: …`), the deferred post and the closed-at post group the same way, before the
12-bullet cap. `sets.sh` builds sets by hand (no pane) and reads the post from the stub poster: 45 resting panes, exactly 5 (names kept),
6 (one line), two reasons of 7 and 8 beside a pair, a 🔄 post of 30 resting panes beside one with its own reason, and a deferred post whose
set still records every pane's bullet. The cap check now gives its 15 panes 15 different reasons (15 with one reason are one line).

### `tests/psets.sh`: 48 → 26

Kept: no set for a clean run; the set and its items split by kind; one master message, never twice, with the exact
`--settle` and `--waiting` commands the master runs (a wrong set id or step would settle the wrong item); `--waiting`
and `--settle` on the set's items (a missing item refused); a failed step joining the open set, retried by its worker,
settled and recorded; the last settle closing the set, which then refuses `--settle`; a give-up closing it once; an
offline box keeping its set open until a later provision of it settles it, clean or with leftovers joining the set.

Added after the cut (`provision --only`, Fri Oct 9th): an unknown step name is refused before anything reaches a box; a
whole-fleet `--only settings` run sends each box (this one included) the steps with `--only settings`, then
`--check --only settings`, in that order; it sends no CLI update, takes no recycle lock (so never recycles; the call has a
timeout, since a recycle would hang in the fake claude) and makes no provision set (a set's retry worker re-runs a whole
provision of its boxes). An `--only` run that recycled or ran every step would change the fleet beyond what was asked.

Added after the cut (Sun Oct 11th): `--only` always includes `repo` when a step script lists it. With a steps
script listing `repo` and `settings`, `--only settings` to a box sends the steps with `--only 'repo,settings'`, in the
apply and under `--check`. Without it a step named alone never fast-forwarded the checkout first, and the machines stayed
behind, the step failing on the stale checkout.

Dropped: the posts' headlines, bullets, label format, "needs you" and the 5th-field leaks, the terminal report and
`--check` wording, `dur_words`, "no post while…", fleet-post absences, "nothing to the master" for offline and failed
items, the second message checks, `--sets`' display, and the recycle-set headline section (`sets.sh` covers recycle sets).
Where a headline carried state it became a check of the set file instead.

### `tests/briefing.sh`: 136 → 48

Kept: the delivery guard (a digest that never read Gmail is held back; an empty result, a failed run and the auth
sentinel post the failure notice instead of the digest); the payload Slack accepts; a linker that hangs, fails or prints
nothing never stops the post; `reply.sh` puts `thread_ts` in the payload (else the reply lands outside its thread), not
without one, and refuses a bad ts (one per malformed shape) or an empty text before anything posts, takes the text from
stdin and runs through a symlink; `lib.sh` sources from anywhere without exiting its caller, and each script finds it;
`systemd-analyze verify` of the six units (it also fails on an ExecStart that is not executable).

Added on Wed Oct 21st 2026 (`units.sh`, 9 checks): each of the three services carries `BRIEFING_BACKEND=cli`, an empty
`BRIEFING_CLAUDE_CONFIG_DIR` and `UnsetEnvironment=ANTHROPIC_API_KEY ANTHROPIC_CUSTOM_HEADERS`, so the briefings run on
the bedrock lane with no local drop-in; one check per unit and line (the lean summary's `BRIEFING_BACKEND=cli` among them; the
forwarded-address and release units must NOT force a backend, or the key would never be tried).

Added on Sun Nov 1st 2026 (`tests/briefing/apicredit.sh`, ~55 checks, and the changed parts of `sdk.sh`, `readguard.sh`
and `sdklane.sh`): the API key is used while the shared credit record (`${XDG_STATE_HOME:-~/.local/state}/api-credit/state.json`,
`lib/api_credit.py` the writer, `lib/api-credit.sh` the pure-bash reader) holds no refusal less than `API_CREDIT_RETRY_S` (6 h) old.
Guarded: both readers agree on every case (no record, 60 s, 21599 s, exactly 21600 s, 7 h, a stamp in the future, the retry override
and its bad values, garbage, a record without `refused_at`, compact and pretty-printed JSON, the default location); a refusal is told by
"credit balance" in any case and nothing else; the write is atomic, mode 700 directory and 600 file, the detail cut at 200 characters,
a new record replaces the old one, no temp file is left, an existing directory keeps its mode; `clear` removes the record and is quiet
without one; `sdk_run.py` against a stub SDK writes the record on a refused result, a `billing_error` message and a `ProcessError`
whose stderr says "credit balance", clears it on a working turn and leaves it alone on any other failure; the SDK run's environment
carries none of the bedrock lane's routing (the units run under `lane exec bedrock`); the forwarded-address and release units no longer force
`BRIEFING_BACKEND=cli`; on the sdk lane the tests stamp a refusal at an epoch in the far future (the real clock reads it as old,
`SALA_LANE_SDK_NOW` a minute after it as fresh) and check `lane_check`, `resume_cmd`, the table, the switch and the wrapper's own gate
against it, and that the driver writes the record when it leaves on a refused turn. The tests' record lives in a temporary
`XDG_STATE_HOME` that is removed pass or fail.

Added on Thu Oct 22nd 2026 (`holds.sh`, 29 checks): the morning summary's "New holds (last 24 hours)" block,
which `holds.py` fetches from stackshot outside the model (so `guard.py` stays as it is). Each check guards a way the
briefing could fail, leak or be steered: both shapes of the section (the session-start brief `/client/brief` returns, and
board.md's head) parse and nothing else gets through, since a wrong parse drops a hold or puts a count into the digest;
a hostile subject (angle brackets, control characters, a fake closing tag, a long line, 30 holds) is cleaned and capped, because
the text is data the model reads; the token goes out as a bearer header and appears in no output; a refused token, an
unreachable server, a server that never answers (the cap) and a missing token file each end as exit 1 with one stderr line;
`fetch_new_holds` turns that into a note with no block (partial output dropped, no temp file left); `summary.sh` with a fake
`claude` and `BRIEFING_NO_POST` puts the block in the prompt, leaves holds out of it when there are none, appends the failure
line to the run's `.err` log after the run's own stderr, and posts the digest in all three cases. A stand-in for stackshot is a listener on
127.0.0.1 and no real token is read.

Added on Fri Oct 23rd 2026 (`lean.sh`, 77 checks, plus 4 in `units.sh` and 2 in `source.sh` for the new pair and
scripts): the lean morning summary, where code reads and trims the unread mail (`gmail_fetch.py`) and one model call with no
tools writes the text (`summary-lean.sh`). The fetch runs against `lean_fake_portal.py`, a listener on 127.0.0.1 that
speaks the portal's MCP with made-up mail in the portal's shapes; the model is a fake `claude`; the webhook is a counting
listener, so "posts nothing" and "posts once" are measured. Each check guards a way the digest could be wrong, leak or
double: the bearer token is accepted, the fetch's own user agent is sent (an edge may refuse a library's default agent), only the
five Gmail reads go out and each passes `guard.py` (a send, draft, label or Drive tool is refused before a request), the
token and the refresh token appear in no output and the refresh token is never used; trimming drops quoted replies,
signatures, newsletter footers, HTML and links, shows dates in the digest's time zone, makes one item per thread with the thread id the
`[gmail:]` marker needs and both unread messages' new text, reads a news alert mail as item titles and destination URLs
(redirect and footer gone, a repeat once), keeps the whole block under the cap by dropping the lowest priority and counting
what was omitted, keeps the true unread count, and lets no mail close the data block; an empty mailbox is a digest with zero,
a masked next page is `N+`; an expired token runs the warm command once and ends as exit 3 when nothing renewed it, a
renewed one carries on, a fresh one never runs it; a refused login, an OAuth answer, an answer that is not a result list, a
JSON-RPC error, a bad token, a missing login file and an unreachable portal are distinct exits with one stderr line and no
block. `summary-lean.sh` is checked for the model call's exact flags and no tool, MCP or settings flag, the system prompt
whole, the mail and holds block on stdin, `SALA_BRIEFING_MODEL`, a Bedrock lane's variables and `BRIEFING_CLAUDE_CONFIG_DIR`
reaching the call, the count line and time from code (a number the model wrote is overwritten), the usage line, no post by
default, one post for `--post` and for `BRIEFING_LEAN_POST=1`, `BRIEFING_NO_POST` honoured, and for a refused login, a
failed read and a run that read nothing a 🚨 notice in the file or on the webhook, with no digest and the model never called;
a failing, `NO_REPLY` or greeting-less model answer is a failed notice and a failed call is retried once; `lean-compare.sh`
prints old and new for a day; the lean units fire at the time set in the unit with `--post`. Not covered: the live portal and the live
renewal of the stored token by the warm command (the first side-by-side run is that check).

Added on Wed Oct 14th 2026 (`readguard.sh`, 80 checks): the read guard `contrib/briefing/guard.py`, which
refuses a portal call that is not plainly a Gmail read before it runs. Every check guards a path that can send, draft,
label or touch Drive through the portal, or lose a digest: the portal's call shapes pass; each write and each
evasion kind (a computed name, an alias, a mixed call, a comment, a concatenated string, destructuring, a default
parameter, reflection, `import`, an escaped or lookalike identifier, a free identifier from the enclosing scope, a
second statement) is refused with the reason the model gets; the hook is on the `claude -p` call and on the SDK runner
and not on a non-briefing `claude -p`; a refused call is not counted as a read nor reported as a write but is named;
`BRIEFING_NO_POST` posts nothing. One row per kind; the same evasion in a second spelling is not a second check.

Added on Wed Oct 14th 2026 (`readguard.sh`, 6 checks): the read guard's load check, which holds a
digest back when the run made portal calls and `guard.log` gained no line (a guard that did not load would otherwise
fail silently). One check per kind: portal calls with no new line (held back, the alert names the run and its log);
portal calls with the hook's line, written by the real hook run from `--settings` (posted); a direct-connector run with
no line (unchecked, posted); the SDK fallback, where the count from before the SDK attempt carries over to the
`claude -p` rerun and the SDK run's portal calls count after its log is moved aside (two checks, each fails if the rerun
takes its own count or drops the SDK's calls); `run_claude_retry`, which keeps the first run's count. The fakes in
`portal.sh` and `sdk.sh` now write the hook's line, so their portal runs still post.

Added on Thu Oct 15th 2026 (no master; `sdk.sh`, 3 checks): `release-watch.sh cli-owner`, the session a new
Claude Code release is relayed to: sala's master when there is one, else `RELEASE_WATCH_CLI_OWNER` (the environment, else the sala config's line;
unset: nobody is told), and the override. A fake `sala` (`RELEASE_WATCH_SALA`) answers.

Added on Fri Oct 16th 2026 (front agents; `sdk.sh`, 5 checks): the release watcher's relay to a front
agent. A recipient named `*-main` gets `[for the user]` as the first line of the message (the SDK prompt on the runner's
stdin is read back: the line, then the text unchanged), because a front agent takes a message only then; any other
recipient gets the text unchanged, with no such line. The Ubuntu LTS notice goes to `RELEASE_WATCH_UBUNTU_SESSION` with the plan's page `RELEASE_WATCH_UBUNTU_PAGE`
named (the main loop run end to end with a fake `curl` and `gh`: the recipient, the page and the first line of what it is sent;
with neither set the notice is posted and nobody is pinged; the session from the sala config's line too).

Added on Thu Oct 22nd 2026 (`links.sh`, 15 checks beyond the earlier ones): the session links in a post now
point to sala's own session link, built as `session_url` builds it, for every session `sala spawn --list` shows, with or
without a claude.ai bridge. This is an exception to the dropped link-shape checks, for two reasons the rule names: a link
that is wrong sends the owner to a dead or wrong page from a post they act on, and the name matcher is built from live session
names, so a name with regex characters (`x.*`, `a+b(1)`) must neither break the linker, which would cost the post its links, nor
link other text. The checks: a bridged session links to sala and not claude.ai; an unbridged one links to sala; a listed
session whose claude exited does too; an unknown name, a longer name that merely starts like a session, and the registry's `?`
placeholder stay plain; regex-character names link as themselves and match nothing else; code spans and existing links are
untouched and board ids and `repo#N` still link; `SALA_SESSION_URL` sets the template, and empty means claude.ai for a bridged
session only; five awkward names (`/ ? # ~ * ' ( )`, a CJK name, `+`) get exactly the url `lib/common.sh`'s `session_url` gives,
which is the guard against the linker's copy of the encoding drifting from sala's. The linker-failure cases above stand.

Added on Thu Oct 22nd 2026 (`links.sh`, 6 checks): the session names now come from the registry
(`sala sessions --json`, rows not retired) because `sala spawn --list` can take longer than the old 5 s cap during a recycle, and the cap cut
it off. Checked with a fake registry file: names link and a retired row stays plain; a registry that is empty, invalid or
failing falls back to the `spawn --list` rows; a fallback that takes 6 s still links, under the real 20 s default cap (about
6 s of the suite); a hung fallback is cut off. `BRIEFING_SESSIONS_CMD` (non-empty) still replaces the whole lookup.

Added on Fri Nov 6th 2026 (`links.sh`, 6 checks): the GitHub account the repo links point into is the setting
`BRIEFING_GITHUB_BASE` and no longer a name in the code. A wrong link sends the reader to another account's repository, so the
checks stand: a trailing `/` is dropped and the base's own owner may prefix `<repo>#N` (another owner's prefix links nothing); a base on
another host with a deeper path is used as given; the sala config's line counts when the environment has none; commit, `<repo>#N` and
page links are all built on the base; and with the setting unset, empty or not a URL ending in an account, none of them links
(page slug, `<repo>#N`, `<owner>/<repo>#N` and commit id stay plain) while session and board links are unaffected.

Dropped:
- `format.sh` (slack_text) and the earlier link-shape checks of `links.sh`: formatting (the session-link checks above are the exception).
- `files.sh`: `bash -n` is `syntax.sh`'s job; the executable bit is caught by `systemd-analyze verify` (for the timers'
  scripts) and by running `reply.sh`; a missing prompt file is caught by the delivery guard; the old install path is
  history.
- the units' key-by-key greps and `systemd-analyze calendar` of fixed strings: config echoes.
- the session-start line being dropped, "says no text", "exactly one post", `BRIEFING_LOGDIR`, the other bad-ts and
  blank-text variants, the `-` stdin form, `post_slack defined`, the `$BRIEFING_DIR` file probes and a second sourcing
  shape: wording, trivia or a duplicate of a kept check.

Borderline keep: "post_slack: formatted, then linked" checks formatting; it stays as the control that makes the
failing-linker cases mean something.

### `tests/limitwatch.sh`: new, 26 (Tue Oct 13th 2026); 41 with the lanes (the same day)

The usage limit can stop every API call with nobody told, and the panes it leaves idle on an unhandled message stay idle.
Accounts and lanes on a machine stop and come back separately, so the watch judges each pane and posts in groups; the partial
stop, a pane stopped later in the same stop and a group's lift each have a check. The checks guard what loses a turn or tells
the owner nothing: the stop and the lift each posted once (a post that never goes is the failure; one on every tick is noise
that hides it), a per-model limit and an error younger than `SALA_LIMIT_CONFIRM` not posted; each pane on the error told once,
and never a busy pane (a message mid-turn), a pane that moved on, one told already or one whose error came after the lift (a
session still limited would be told on every tick); only sala's oneshot units that failed during the stop re-run, once (never
watch itself, a long-running unit or one outside sala's names); both knobs off do nothing. The reset's and the stop's times are
checked because the owner reads them to plan; the rest of the posts' wording is not. `sala alert`: posted in the shape, its exit
codes, which a calling check reads, and a URL in the headline: after the closing `*` with none beside it (Slack took the `*`
into the link), two URLs in order, a URL inside or glued to a `*` moved out, a `*` headline with a clear URL and a headline with
no URL left as before.

With the lanes (which lane each pane is on, and exactly which limit is hit), the suite was rewritten around seven panes on three
lanes, read from each fake's environment as production reads /proc. What a first draft of the post got wrong is what the checks
hold: the limit's name and login on every line (a pane on one lane's 5-hour limit is not "the usage limit"), a pane's "since" as
this episode's first error when an older error is still in its tail and the lane worked in between, and a pane relaunched on
another lane lifted as "moved" and told at once rather than "went on by itself". The lift reasons each have a check because each
is a different thing for the owner to do (nothing, wait for the reset, top up the key); a model's weekly limit not lifted by
another model's success guards the one wrong tell that would repeat on every tick. A headless job that hit the limit unseen is
named by what started it — the unit whose WorkingDirectory is its cwd, the unit whose last run or journal lines are at the
error's time (resolved when first seen and remembered), else the folder in plain words — posted once per starter per episode,
dropped when the unit later re-ran successfully (a briefing that sala re-ran: the first draft of the post called it stopped),
and never a gone pane's transcript: the ways it would either spam, mislead or stay silent. The API lane's 429 is pinned to the
documented shape the code matches; its credit error (`billing_error`, "Credit balance is too low";
`tests/fixtures/limit-billing.jsonl`) and the weekly limit (`tests/fixtures/limit-weekly.jsonl`) are fixtures in the CLI's shape.
The checks added with them hold what a later post got wrong: panes relaunched from the api lane onto a subscription lane, with
an earlier credit error still in their tails and their api stop forgotten while they had no process, were posted as a
subscription lane stopped and "lifted early" minutes later. Now the lane of an error is the error's: a credit record on a
subscription pane is lifted "moved to the subscription lane" (its stop remembered or not), a stopped pane with no process while
a relaunch holds the recycle lock keeps its stop, a pane relaunched on the api lane itself stays stopped since its episode's
first error, and a final sweep over every post, message and log line of the run asserts that no login lane is ever paired with an
API kind. The wording is checked where the owner reads it: "API credit ran out", "out of API credit since …", "API credit had
run out for them since …", "API credit was added", "the weekly limit reset at …".

The sweep pulls no checkout on a machine: the payload sent to a machine runs no git, so no sweep reaches a checkout
(`tests/smoke.sh`, above); the driving machine never runs the payload on itself (`fleet_hosts` drops its own hostname).

### `tests/lanes.sh`: new, 66 (Tue Oct 13th 2026)

The lanes (`lib/common.sh` "lanes", `lib/lane.sh`): which account or key a pane's claude runs on, and that every relaunch
keeps it. Every check guards a relaunch path or the key, by the rule above. The launch-line prefix per lane is checked
for carrying the key file's *path* and never its value, and for handing the process the key when a shell runs it (a
dummy key in the temporary HOME; the value is counted in the evaluated environment, never printed): a value in the typed
text would sit in the pane's scrollback, tmux's buffer and sala's logs. `resume_cmd` is checked on a session's lane
because it is the one line every relaunch path builds (recycle, `revive`, the boot hook, the retry workers, `restore`,
`unpark`): a lane lost there is a pane coming back on the wrong account after the next recycle. A lane directory
without a login is refused, so panes are never relaunched onto a login screen. `sala lane` on one session is
checked end to end through the direct sweep (recorded, relaunched, the key and the header in the new process's
environment, the value in none of the command's output, the scrollback, the logs or the argv); a recycle after it brings
the api pane back on api and the subscription pane on its lane; `--all` records every session and the default and relaunches through
a recycle, leaving a `SALA_NO_RELAUNCH` session alone; a spawn lands on the default; from a pane the others are swept
first and the invoking pane last, by the self-worker (the master's own rule). A missing key file is refused before
anything is recorded or relaunched; `--dry-run` records and relaunches nothing and shows names, not values; a
`SALA_NO_RELAUNCH` session is refused by name. `watch` with the master on the api lane types no `/remote-control` into
it (a 🚨 every cooldown otherwise) and says so once; on a subscription lane, the same screen gets `/remote-control` typed — the control,
so the heal is known to still work where it belongs. `rename` moving the row and `retire` dropping it are checked through
the helpers (the verbs' own paths are `ledger.sh`'s); `retire` end to end drops the row. The reboot's boot-half skip on
the api lane is not exercised (no boot in a sandbox); its helper, `lane_rc`, is.

Added Wed Oct 14th 2026 (33 checks; the suite's `ok` lines stand at 117 with the model-family checks that joined it
earlier): the lane line and the dry runs. Two more panes are launched *by hand* with the lane's env on the launch line,
(`CLAUDE_CONFIG_DIR=<lane dir> claude`, nothing recorded), so the sweep reads one lane from the process
and another from the resume line. Matching lanes are checked to print `lane: subscription-1 → subscription-1` and relaunch; a mismatch with no
row to refuse that pane by name with both lanes and both fixes, relaunch nothing, record nothing and start no retry
worker (a lost lane is a pane coming back on another account, with the key or login it was not meant to have); a
mismatch with a row to relaunch on the row (`lane: subscription-2 → api`, the key then in the new process's environment); and
`--lane-default` to relaunch on the default — each verdict shown by the dry run first, which must relaunch nothing. The
dry runs are checked for scheduling nothing, because `revive --self --dry-run` once scheduled the real
self-relaunch and `recycle --force --dry-run` from a pane froze the pane map and ran the real self-worker on that pane:
`revive --self --dry-run` starts no self-worker, relaunches nothing and leaves the recycle lock's holder line alone;
`revive --self` on a mismatch is refused; `recycle --force --dry-run` from a pane writes the sweep's verdicts and the
self-worker's plan to the log and relaunches no pane, freezes no map, writes no set, posts nothing and stops no earlier
retry worker (a sleep with a pid file stands in for one; the real recycle that follows stops it — the control). A fleet
`recycle --force` with one refused pane relaunches every other pane and names the refused one in the set's post, so a
pane left behind for its lane is never silently skipped. The own-session wording (`revive --force --only <own
session>` now says it did not relaunch and points to `revive --self`) is not checked: wording, and the sweep cannot be
run from inside the fake claude.

Split on Wed Oct 14th 2026 (the wall time of `tests/run.sh` is its slowest suite's): the lane line, the dry runs and the
fleet recycle with a refused pane are `tests/lanes-revive.sh`, which launches a and b on the api lane by hand with rows,
as `lanes.sh` leaves them (one setup check); `tests/lanes.sh` keeps the lanes, the verb and the switches. No check was
dropped: 117 `ok` lines before, 85 + 33 after. `watch`'s sign-in step is turned off for every suite but
`signin.sh` (`tests/lib.sh`, `SALA_SIGNIN_ALERT=off`): the compiled fake does not answer `claude auth status --json`, so
each suite's first `watch` tick sat through `timeout 30` per login lane for a verdict nothing checked, and its api probe
reached the real API with the suite's dummy key. `lanes.sh` spent most of its time in two `watch` ticks.

### `tests/models.sh`: new, 40 (Wed Oct 14th 2026); 53 with `--record-only` (the same day); 71 with the compact window and 82 with the model batch (both Thu Oct 29th 2026)

The models (`lib/common.sh` "models", `lib/model.sh`): the model and effort a session is relaunched on, recorded ahead of
its transcript's. Every check guards the relaunch line or the record, by the rule above. `model_valid` and `effort_known`
are checked because what they pass is typed unquoted into a pane's shell: a `[1m]` suffix would be a glob there, a `;` a
second command. `resume_cmd` is checked with a row and without one, because it is the one line every relaunch path builds:
the row must win (the model always, the effort unless it is `-`), a row of another session must not leak, and a
hand-edited bad value must be ignored rather than typed. The verb is checked to refuse an unknown session, a bad effort
and a bad model before anything is recorded. `--dry-run` is checked to write neither file and relaunch nothing (the lane
default wrote its file under `--dry-run` until it was fixed). The switch is checked end to end through the direct sweep: the
row recorded, the pane relaunched, `--model sonnet --effort medium` on the new claude's command line while its transcript
says opus at high effort; the same pair again is left alone (an extra relaunch costs a session its turn); a later
`revive --force --only` keeps the record. `--clear` is checked to drop the row without a relaunch, and the transcript to
decide again. `rename` moving the row is checked through the helper (the verb's own path is `ledger.sh`'s); `retire` end
to end drops the row. `--record-only` is checked through a copy of the entry point whose `revive.sh` is a logging stub
(bin/salamander sets `SALA_BIN` from its own path, so no other stub sees the call), with a control that the switch through
the same root is seen: no revive call and the claude untouched; `--dry-run` leaving both files as they were; a name sala
has never seen refused, one known only by a pane-map row or only by its model row accepted (the stale or asleep panes of a
model plan); `--clear` with it an error; the table showing a row whose session has no tmux session; and the record
reaching the resume line, both through `resume_cmd` and end to end by a later `revive --force --only`.

**+18 (Thu Oct 29th 2026): the compact window** (`lib/common.sh` COMPACT WINDOW, `lib/spawn.sh`,
`install.sh`, `contrib/compact.tsv`). `claude --autocompact <tokens>` is typed unquoted onto a pane's launch line and the
CLI refuses a value outside 100k–1M at start, which would leave the pane at a shell, so what may reach the line is
checked: a row gives the flag on the resume line (with a model row and on a parked revive's `--name` line too), another
session or none named gives none, 100000, 999999 and 1000000 pass, and seventeen hand-edited bad values (zero, 5000,
99999, 1000001, letters, `150k`, a sign, a leading zero, spaces, `--x`, `;rm`, `$(id)`, empty) are ignored rather than typed.
The sdk lane's pane program carries no flag even with a row. End to end, a `revive --force --only` leaves the pane's claude
running with `--autocompact 150000`, and a real `sala spawn` does the same for a session with a row, none for one without
and none for one with a bad row (the pane still comes up). `install.sh` seeds the state file from `contrib/compact.tsv`
once (the three maintenance rows read back through `compact_tokens_r`) and leaves a hand-edited file alone. Run against the
unfixed code the new checks fail (the flag is missing from every line that should carry it).

**+11 (Thu Oct 29th 2026): the model batch.** `sala model` in its many-session form (11 checks, 71 → 82): `sala model <model> [--effort <level>]
<session>…` (and `--clear <session>…`), the many-session form that makes one operation and one notice of a batch.
Every check guards a batch from a half-done state or from the old waste. Through the same logging-stub root as
`--record-only`: one unknown session among three refuses the whole batch by name (no row written, no revive call), as a
bad effort does; `--dry-run` shows each session's plan and writes nothing; a real batch records both rows and makes
**exactly one** `revive --force --only A --only B` call (the old way was one call per session), prints a `RESULT` line per
session and the summary last; the single-session shape `<session> <model>` still makes its own one-session call with no
batch lines (the rule: a first word that is a model means the many-session form); `--clear` with several sessions drops
all the rows (an unknown one refuses all); `--record-only` goes with the batch with no revive call. Not checked here:
the in-place path of a batch (`tests/modelinplace.sh`), a failure inside one session (`tests/op.sh` stands in for it).

### `tests/modelinplace.sh`: new, 67 (Mon Oct 26th 2026)

The in-place model switch (`lib/model.sh` "SWITCHED IN PLACE FIRST", `lib/common.sh` "THE IN-PLACE SWITCH"): `sala model` on a
pane that is idle with an empty input box types `/model` and `/effort` into it instead of relaunching it, then puts the
lane's saved defaults back. The two losses the rule names are both here. **An unsent draft**: the gate refuses a pane whose
box holds text, and the check is that nothing is typed onto it and the draft is still on the screen afterwards. **A session
or a conversation**: a busy pane must not be typed into (the dialog hangs mid-turn), an unexpected dialog must get an
Escape and never an Enter (an Enter would confirm whatever it asks), and every failure after the first keystroke must end
in the relaunch it replaced. The third thing guarded is a side effect the rule does not name but a reader would drop: Claude
Code saves each `/model` and `/effort` as the lane's **default**, so a switch that did not put it back would move every
session started afterwards; that is why the byte-for-byte comparison of `settings.json` is checked on the success path and
on all three failure paths (a command that never confirms, a default saved with no confirmation line, an effort refused
after the model had switched), why the settings helpers are checked alone (a key somebody else changed meanwhile kept, no
write when nothing differs, the atomic rename with the mode kept and no temp file left, a failed write leaving the file as it
was, an unreadable file refused before anything is typed, a file that did not exist removed again, a symlink kept a link),
and why a second lane's own `settings.json` is the one restored while `~/.claude/settings.json` is not touched. The plan
(`--dry-run`, `sala op --plan`) is checked because the owner reads it before agreeing: it must say *would switch in place* or
*would relaunch*, with the reason, and for the asking session (busy with the very turn that queued it) *once the pane is
idle*; the runner's wait for that session and the recycle lock the whole switch runs under are checked too. A mutation of
the restore call (replaced by a no-op) fails 16 checks.

Not tested here: a real claude. The fake is shaped by a probe of 2.1.310 (the dialog, the *Set model to* and *Set effort level
to* lines, the two keys saved); whether a real CLI re-reads a `settings.json` we have just restored and moves the running
session back is not known. `SALA_MODEL_INPLACE=off` is set in `tests/lib.sh` for every other suite, so `models.sh` and `op.sh`
keep checking the relaunch path (their only change: `op.sh`'s notice text and one plan line).

Added on Thu Oct 29th 2026 (4 checks, 67 → 71): a batch (`sala model haiku --effort low <k> <d>`) mixes the two
paths in one command: the idle pane with an empty box is switched in place (the same process, `/model haiku` typed, the
saved defaults put back byte for byte) and the pane with an unsent draft gets nothing typed and is handed to the batch's
ONE sweep (`relaunch sweep: one revive for 1 pane(s)`); both rows are recorded and the summary says `1 switched in place,
1 relaunching`.

### `tests/sdklane.sh`: new, 78 (Wed Oct 14th 2026)

The sdk lane (`lib/common.sh` "lanes", `lib/sdk-pane.sh`, `contrib/sdk-pane/driver.py`): the API credit through the Agent
SDK, with every relaunch path treating the pane as a claude pane. It runs against a stub SDK (`tests/sdk-stub/`) that
spawns the compiled fake claude the way the SDK spawns the CLI — `cli_path`, `--resume`, the `--mcp-config`, the setting
sources, `--name`, and an environment of the caller's plus `CLAUDE_CODE_ENTRYPOINT=sdk-py` plus the key from the
options — so what the fake logs about its environment is what the real CLI's would carry, and `proc_lane` reads `sdk` the
same way. The real SDK is not run here (no uv, no network, no key); one smoke on a throwaway conversation did that.
Every check guards a relaunch path, the key or the clock, by the rule above. `lane_check sdk` is checked to name each
missing thing (the key file, the `--mcp-config` file — an SDK session has no claude.ai connector, so without the file the
pane would come up with no portal and no GitHub — the interpreter, the window closed) and to read the clock from
`SALA_LANE_SDK_NOW`, because panes relaunched onto a lane that cannot launch sit at their shells. `resume_cmd` is
checked for the pane program's line (`salamander sdk-pane <uuid> <session>`, a model row's `--model` and `--effort`
following), for carrying neither the key nor a `$(cat …)` (the wrapper reads the lane's files itself), and for the subscription
line once the window is closed with one `fallback` line in `lanes.log` (a pane that kept resuming onto the sdk line after
the credit would come up refused at every turn); `lane_for_session` and a default of `sdk` are checked around the instant
itself. `spawn` on a default of `sdk` is checked to refuse before any tmux session is made. `sala lane sdk <session>` is
checked end to end through the direct sweep: the row recorded, the pane relaunched, its program `sala-sdk` (a shell's name
there would make the sweep type a resume line into the driver, and `claude` would make it look for the wrong process),
the fake's environment carrying the key by the SDK's route, `proc_lane` sdk, the driver's argv holding the files' paths
and sala's launcher, the value in none of the command's output, the scrollback, the logs or any argv; the dry run naming
the program, the variables and the files and recording nothing. The screen is checked where sala and sala-web read it: the
last three lines a rule, the ❯ line, a rule; the dim hint read as no draft; typed text read as a draft that refuses a
relaunch (the dry run's verdict quotes it); Ctrl-U clearing it (what `tui_send` types over sala's own leftovers); Enter
reaching the SDK as a query; `tui_send`'s marked message arriving as typed; `/remote-control` answered in the pane and never
sent as a prompt; nothing on the screen matching `pane_prompt`'s list; `is_idle_reason` idle on the SDK CLI's registry
row. A later `revive --force --only` is checked to relaunch the sdk pane with the lane line `sdk → sdk` and the summary
`(lane sdk)`, the old fake left by `/exit` (the stub's disconnect), and a model row's pair on the new SDK line. The credit
fallback is checked end to end on a pane whose stub refuses every turn: the row rewritten to `subscription-1`, one post in plain
words (back on the subscription login, why, the way back), the pane resumed on the subscription line at once (its program `claude`, no key),
the table `subscription-1`/`subscription-1`, the refusal printed before the switch. A killed CLI is checked to leave the pane at its shell with
a line, and the next revive to resume it on sdk through the shell-pane path (the lane line `none → sdk`), after `adopt`
gave it a pane-map row. The wrapper's own date gate is checked with the clock set in the pane's environment: typed after
the instant it runs the subscription line, the row stays `sdk`, and the table says what a relaunch does until the row is cleared.
The switch is checked to refuse once the window is closed, recording and relaunching nothing. The pane program's usage
refusals (no uuid, a bad uuid, a model that could not be typed) are kept because the line is typed into a shell. The mod
in the SDK's CLI (a lane switch once left a session at the driver's box for 30 s: the real
CLI loads the mod from the user settings, the mod answers the exit request ok and runs `/exit`, which ends nothing in a
CLI the SDK drives) is checked with a fake mod on the fake's messaging socket that answers draft with an empty box and
exit with ok and runs nothing: `sala lane subscription-1` ends the pane through its box (the mod asked, the ok taken, `/exit` typed,
the CLI gone with its registry row) and relaunches it on that lane within the sweep; `pane_exit`'s own keys refuse over a draft
(the gate kept, the mod not asked, the draft still there) and on an empty box type `/exit`, the pane at its shell within
`SALA_EXIT_WAIT`, no driver left on the conversation. The tmux server dying under an sdk pane is checked to leave no
driver and no CLI: a driver whose `finish()` printed before setting `done` waited for ever on the dead pty,
and a real CLI alive under one would block every resume as "already live". Not
checked: the real SDK's status flip and Stop hook record under stream-json (the smoke's job), `lw_limit` on the sdk lane
(`limitwatch.sh` covers the API kinds; the lane only joins the "no login name" group).

### `tests/signin.sh`: new, 50 (Wed Oct 14th 2026); 65 with the newest haiku (the same day)

The lane sign-in watch (`lib/watch.sh` SIGN-IN WATCH, `lib/common.sh` `lane_expect`). A `/login` typed in one
pane re-signs that pane's whole lane (a config directory holds one login), and the lane can sit on another account with nobody
told: every pane on it is on an account it is not meant to have, the lanes' version of a lost session. The checks guard what
would leave the owner untold or bury the one post that matters: every lane right posts nothing (a post on every tick is noise
that hides the real one); a lane directory re-signed onto another login is posted exactly once, naming
the lane, what was expected and what was seen, with the fix in the post (`CLAUDE_CONFIG_DIR=<dir> claude auth login
--claudeai`, the warning against `/login`, `sala lane` for one pane: the fix typed wrong re-signs another lane), and the next
ticks are silent; a change to another wrong state is a new post (the lane moved again); an unreadable answer neither posts
nor lifts and is logged once (a hung or missing CLI would otherwise clear a real alert or fill the log); the lifted post goes
once when the lane is right again. A lane signed out and back has a check; one more check
says a signed-in directory that belongs to no lane is never asked and never posted. The watch's own environment is checked not to
reach the CLI: run by hand from a pane on the api lane, an `ANTHROPIC_API_KEY` there makes `claude auth status` report
`api_key` and no subscription, which would post every login lane as wrong. The api lane: the key and the workspace id must
come from the files and never a command line (one request to a local stub, its headers compared and counted, the dummy value
grepped for in every post, log, call record and state file), the request must be the cheap one (haiku, `max_tokens` 1,
counted once within the hour: the brief's cost ceiling), and the haiku the newest the API lists (the latest model is used unless one
is named explicitly): the stub serves `GET /v1/models` too and records the model each
POST names, so the newest `created_at` is checked to win over list order with a newer non-haiku model ignored, the first
listed to win a tie, an explicit `SALA_SIGNIN_API_MODEL` to win with no listing made, a listing that fails (500, bad JSON,
no haiku, a dropped connection) to fall back to the pin with the verdict unchanged, a 503 listing to leave the verdict to the
POST, and a 401 listing to post the key refused with no POST made (a listing failure must neither break the probe nor count
twice); 401 and 403 post once and a 400 — the credit used up, which the
usage-limit watch already reports — must not (the two posts would contradict each other), 429, 5xx and no network must keep
an alert rather than lift it, 200 lifts; no key file is watched only while a session's row or the default is on the lane (a
box with no api lane would otherwise alert forever) and is lifted the moment the file is back. Two lanes breaking in one
tick are one post; the knob off asks and keeps nothing; a plain `watch` tick runs the step (the timer's path, not only
`--signin`). The final sweep holds the words the owner reads: no email in a post (a login's organization can be named after
its email), plain words only, no state separator in a headline. The wording of the
headlines beyond the lane name and the "and" of two lanes is not checked. Not checked: the real CLI's answer (read from the CLI
and pinned in the header of `lib/watch.sh`; the fake prints those shapes), the real API's answer to the one-token call,
and the real model listing's shape (read
from the API: `{data: [{id, created_at, …}], …}`, newest first; the stub serves that shape).

### `tests/rescue.sh`: new, 59 (Wed Oct 14th 2026)

The rescue (`lib/lane.sh` THE RESCUE, `lib/revive.sh` THE RESCUE, `lib/common.sh` `lane_out`, `is_idle_reason` and
`pane_exit` under `SALA_RESCUE`). The master can sit on a lane whose usage is out while the session that could move
it is not the master, and panes stuck on a dead lane can hold a background-task row for work long gone, so every relaunch
cancels its own `/exit` at the CLI's dialog. Every check guards the relaunch of the master or of a pane a rescue touches,
by the rule above. `lane_out` is checked on each of sala's three readings because it decides whether a rescue goes at all
and a wrong "out" would move the master off a lane that works, a wrong "fine" leave it stuck: nothing wrong is fine; a
lane that cannot launch, the sign-in watch's last look wrong (and right again), and the limit watch's state are each out;
the master's own stop is decisive whatever the limit and another pane's only for a lane-wide limit (one model's limit must
not read as the lane going out); sdk is judged by the api lane's stops (its credit is that key's). The verb's refusals are
checked to record and relaunch nothing: no master configured, an unknown lane, one that cannot launch, the master's lane
looking fine (the `--force` named), the master's own pane (the ordinary switch named: the self-worker's route), the lane
it already runs on, a target lane out as well (the lanes that work named), `--force` outside the rescue, `--rescue
--all`. The table's warning is checked for naming the lane, why, the rescue and the working lanes (the line a stuck session
reads first), and for its absence with nothing wrong. `--dry-run` is checked to leave `lanes.tsv`, `lanes.log` and the fake
untouched, since the day's other dry runs had written. The rescue itself is checked end to end from another session with
the limit watch holding the master stopped: the recycle lock held while it runs with the caller in the holder line (two
relaunch drivers would race the same pane), the master relaunched on the new lane with the key in its environment and in
none of the output or logs, the row written, exactly one `rescue` line in `lanes.log` naming when, who, from → to and why,
the caller's own pane untouched, the lock released after. `--force` is checked to move the master off a lane that looks
fine and to say so in the log (the override must be on the record). The stale dialog is checked against the fake's own
drawing of the 2.1.299 dialog (`FAKE_EXIT_DIALOG`: the title, the subtitle, one row per task, the selected "1. Exit and
stop tasks", "Stay", "Esc to cancel"), never a key pressed blind: a plain `revive --only` cancels it with Esc and the
session stays (the dialog gone, the prompt back, the same process), `--rescue` reads the rows off the screen, confirms
and says which rows it took as stale, through `revive --only` and through `sala lane … --rescue` (the flag must reach the
sweep). A pane with a live child (`FAKE_CHILD`) is checked to stay refused with the flag: the one line between a stale row
and work being cut. The Stop hook's record listing a task is checked to skip the pane without the flag and to be passed
over with it, said in the output; the mod's background refusal to stand without the flag and with a child, and to go by
keys under it with the log line naming the stale row. Scheduled rows alone are checked to take the dialog's Enter with no
flag, the control that the rescue changed nothing on the path that existed. `--rescue` without `--only` and `recycle
--rescue` are checked to refuse before anything starts (a fleet confirmed blind). Not checked: the retry worker carrying
`--rescue` into its re-runs (a flag on a line it already builds, under `sets.sh`'s worker flows), the self-worker's
dialog confirm (the same `exit_wait` with the same arguments, under the sweep's check here), the real CLI's dialog text
(read from the 2.1.299 binary and pinned in `exit_wait`'s header; the fake prints that shape), and the wording of the
refusals beyond the words a session acts on.

### `tests/retire.sh`: new, 47 (Wed Oct 14th 2026)

`sala retire` by a name that is not a tmux session (`lib/retire.sh` THE NAME and `--dry-run`). A plain `sala
retire <name>` died at "no tmux session" when the session lived in a hand-launched tmux session with no pane-map
row, and the only name known was the registry's. Every check guards the retire of a session, by the rule above:
retire is the verb that makes a pane stay gone, so a wrong resolution kills someone else's session and a guess kills the
wrong one. The resolution is checked to land on the tmux session the registry row's pane is in (not the name the row was
written with: the `tmux` field is cached at start) and to go through that pane (the /exit taken by the right claude), by
registry name, by conversation id and by its prefix; the choice line is checked to come before the /exit and the kill, the
one line a session or the owner can act on if it is wrong. The refusals are checked to list every candidate and to touch
nothing — the map and its log, the lane and model tables and their logs, every pane and its process, the registry files,
the snapshot marker, the fake's own events, compared whole before and after: two live rows with one name, a prefix on two
(and the full id then taking exactly one), a resolved session that holds a second live claude in another window (retire
kills the whole tmux session). A dead row and a row with no tmux pane are checked to be said and left (the pane-map row
that carries the dead row's conversation pointed at, that row kept: the registry path never drops another name's row).
`--dry-run` is checked on each shape the real run has — a tmux-session name with every row, a busy pane (the refusal,
then `--force`'s override), a resolved name, an orphan row — to name each action (the pane, the pane-map row, the lane
and model rows, the snapshot, the archive or `--keep-web`) and to leave the same state behind, the same claude in its
pane, no snapshot taken. The plain path (a tmux-session name) is checked once end to end as the control that nothing
changed on the path that existed: the rows dropped, the snapshot taken, no registry line. The master guard is checked to
read the resolved name (the master retired by its registry name would be the loss the guard exists for). Not checked: a
registry row whose pane id belongs to another tmux server (the Oct 10th probe case, `ledger.sh`'s check of `is_under`
covers the reading), a Remote Control child's row (the rc server is retired), the exact wording beyond the
words a session acts on.

### `tests/ci.sh`: new (Wed Oct 14th 2026)

The CI gate's two helpers (`.github/scripts/changed.sh`, `.github/scripts/tested.sh`), which decide what the runners
run. Outside the rule's letter (no session, draft or map is at stake in CI), kept because the gate is what stands
between a change and production: `release.sh` reads a skipped job as a verdict, so a wrong `sala=false` from
`changed.sh` merges a sala change that no suite ran on, and a wrong "skip" from `tested.sh` leaves a merged tree that
`main` never tested. `changed.sh` is checked on each shape of change against a throwaway repo (a sala change, the CI's
own files with and without `web/`, `web/` created, a web-only change, both, docs, `web/` removed, an empty diff, no
range), the two output lines compared exactly. `tested.sh` is checked against a `gh` stub serving canned JSON for its
four calls, never the network: the one match (the PR's successful run with the artifact named for this tree) skips, and
everything else runs — another tree, another job, no run, a direct push (and nothing further asked), a PR associated
but not merged as this commit, an unmerged one, each API call failing; two specs in either order; the runs call asks
for the PR's head, the event and success. Not checked: the workflow files themselves (the runner cannot be exercised
before a merge; YAML is parsed by hand before one), the artifact upload (a first-party action).

### `tests/cleantext.sh`: new (Sat Oct 31st 2026)

The clean-text check (`.github/scripts/clean_text.py`, run by `.github/workflows/clean-text.yml`; CONTRIBUTING.md, *Clean
commit and PR text*). Outside the rule's letter (no session, draft or map is at stake), kept because the check is the only
thing between a commit message, a branch name or a PR text and a GitHub page: a pattern that silently stops matching is
invisible until the data is already out. The script against throwaway repos, never the network and never a variable of
GitHub's, in its CI mode (the texts in `CLEAN_TEXT_*`) and with `--local <base>`. Checked: each rule (a board id of both
shapes, the owner's name in any case, the board's host, a host below the owner's domain, the bare domain, a word of the deny
variable) in each place it is read (branch, title, a body line, a commit); the allowed forms passing (a bare `#123`, an org name written with its hyphen, a Claude session URL, a Co-Authored-By line even when it names the owner, the owner's initials);
the deny variable unset, empty, only blank and comment lines, and set (one regex per line, any case, whole words only, a
hyphen being part of a word); a merge commit skipped while the commits it merged are scanned; the
output carrying the matched text and neither the text around it nor a whole 61-line body; a call it cannot answer (a missing
variable, a base that does not resolve) exiting 2, never 0; `--local` with its branch, `--title`, `--body-file`, stdin and a
detached HEAD. Added the same day: the commit range starting at the base branch fetched fresh (a branch that merged the base
back in is not blamed for it; the base sha as the fallback), a hyphen continuing a word only with a word character on its
other side (`--name` and `name-` caught, `name-ci` not), an absent title or body exiting 2, a non-ASCII message under a C locale; and the client-side hooks (`.githooks/`) in a throwaway repo with a local bare remote: a commit refused and a clean
one passing, the `#` lines and the scissors section git drops, a merge commit's message skipped, a push refused for a bad
commit or a branch name and left off the remote, only the commits the remote lacks read (a bad one it already has is not),
a new branch read from the commits no remote-tracking branch reaches, a deletion passing, and the deny words from the
variable first, else from `$XDG_CONFIG_HOME/salamander/clean-text-deny` (comments, the `~/.config` default), skipped with a
notice when neither exists. Added with the regex round: deny lines as case-insensitive regexes (an alternation, a repeat
count with a comma, a `.`), newline-separated only, blank and `#` lines skipped and still counted in the line numbers, two
lines matching one text reported once, an invalid regex in the variable or in the deny file exiting 2 with the source and
line number and never the line, ASCII word boundaries (a name next to a non-ASCII letter caught, `name-ci` not), the base fetched as the
full `refs/remotes/origin/<ref>` (a tag named `origin/main` does not stand in) and a fetch that hangs (a fake `git` first in
`PATH`) cut off by `CLEAN_TEXT_FETCH_TIMEOUT` with the base sha as the fallback. The built-in owner-name, host and board-id rules on the same ASCII boundaries (a non-ASCII letter directly before or after each is caught; an org name with its hyphen and ASCII-adjacent words are not), the deny list split on newlines
only, and a line like `a)|(b` exiting 2. The words used as names in the cases are made up. Not checked: the workflow file itself (a runner cannot be exercised before a merge), the
variable's value, GitHub's `vars` context.

### `tests/githooks-chain.sh`: new (Sat Nov 7th 2026)

The client-side hooks also running the machine's global hook of the same name (`.githooks/chain-global`), in a throwaway repo with
a local bare remote, `HOME` and `XDG_CONFIG_HOME` in a temporary folder, and fake global hooks that log their arguments and keep
their stdin. Checked: no global hook, the repo's own check alone deciding (a clean message and push through, a bad message
refused); a failing global hook failing `commit-msg`, `pre-commit`, `pre-merge-commit` and `pre-push` (no commit, no merge, nothing
on the remote); the global hook getting the same arguments and, for `pre-push`, the remote's name and url and the same stdin, one
line per ref; a non-executable global hook ignored; the repo check failing although the global hook passes (and `pre-push` stopping
before the global hook); a global `core.hooksPath` with a leading `~` winning over the XDG default; a global `core.hooksPath` that
names the repo's own hooks directory not looping. Not checked: a global hook directory given as a relative path.

### `tests/deploy.sh`: new (Wed Oct 14th 2026)

`deploy.sh`'s web step. Kept because a deploy lands under every live session's feet and the step restarts a live unit: a
wrong detection restarts sala-web for a sala change, or leaves the web app on old code after a web one. Against a
throwaway origin and a clone standing in for the production checkout (`SALA_DEPLOY_CHECKOUT`), with a fake `uv` and a
fake `systemctl` on PATH that only log what they were asked (no real unit, venv or checkout is touched): a `web/` file
with no pyproject lands with one line and nothing run; a web-only change is said by the dry run with nothing run or
landed, and for real syncs in `web/`, then restarts, with nothing of sala's install; a lib-only change runs neither and
keeps sala's note; `install.sh` changed is re-run as before; both runs sala's path and then the step; the step failing
after the fast-forward exits 1 with sala's side landed and the last line naming `--web`; `--web` by hand runs the sync
and the restart alone; nothing to deploy runs nothing; the drift check writes the time `origin/main` was last fetched in the zone `SALA_TZ` names (set in the environment or only in sala's config file) with that zone's own label, and in the machine's local time when it is unset (never a literal zone abbreviation). Not checked: the real `uv` and unit (the fakes stand in), the
recycle-lock wait (unchanged, and a web-only deploy waits through it like any other).

### `tests/release.sh`: new, 18 (Tue Oct 27th 2026), 29 and 41 by Wed Oct 28th 2026

`release.sh`'s two ways to a deploy. Kept because the gate is what stands between a merge and a deploy under every live
session's feet: a wrong verdict deploys a main whose own checks failed, or merges a PR twice. `release.sh --run` against a
copy in a throwaway checkout, with a fake `gh` serving canned JSON, a fake `deploy.sh`, `systemd-run` and stackshot client
that only log (no network, no real merge, unit or message; the waits shortened by `SALA_RELEASE_POLL`/`_WAIT`/`_GRACE`). An
open PR is merged and then deployed as before. An already merged PR runs no `gh pr merge`, waits through a pending check run
on main's merge commit, deploys when all passed and sends one message that says it was already merged; a failing or cancelled
check on main exits 1 with no deploy. No check run on main's commit goes on after the grace only when `gh run list` finds no
workflow run either; a listed run keeps the wait going to its end. `--merged` refuses an open PR; a drifted checkout stops
either way before anything is merged or deployed; the start path hands `--run [--merged] <pr>` to the unit; the usage lines.
GitHub's API budget (Wed Oct 28th 2026; the fake `gh` now answers `gh api -i` with headers and an ETag, 304 and exit 1
on a match, and fails the run on `gh pr checks` or `gh run list`): the poll is 60 s by default (a fake `sleep` records it) and
`SALA_RELEASE_POLL` overrides it; a repeated look sends `If-None-Match` and a 304 gives the kept answer (200, 304, 304, 200 over
four looks); an open PR's checks follow its head commit when a push moves it; two releases waiting on one commit make one call
between them (`SALA_RELEASE_GH_TTL`), TTL 0 asks every time, and an answer older than the TTL is asked again with its ETag.
The CI-run poller's file (12 checks, the copy of `release.sh` now has a `lib/cipoll.py` beside it, and the fake `gh` can run a hook on the n-th ask
of a kind): a fresh `<state>/ci-runs/o__r.json` listing a run of the commit that has not completed makes the wait ask GitHub for no check runs and end like a pending
check, in the open and the merged mode, even with check runs that would have passed (the file only ever says "still going"); a run listed as completed gives one
check-runs read, which passes, and with failing check runs the release fails and merges nothing (the file cannot pass a release); a 600 s old file, a 100 s old one
under `SALA_RELEASE_CIFILE_MAX_AGE=60`, a fresh one under `=0`, a fresh file with no run of the commit, no file, a corrupt file and a checkout with no `lib/cipoll.py`
each take the check-runs read as before; a file that turns completed while the release waits (the fake `pulls` ask hook rewrites it) gives one going look with no
check-runs call, then one check-runs read, then the merge.
A check is judged by its newest run, the highest check-run id (6 checks, with start times, ids and the app in the canned check runs): an old failed run plus a newer passing run of the same check
passes and is merged (in either list order), an old passing run plus a newer failed one fails with nothing merged or deployed, an old passing run plus a newer run in
progress keeps waiting to the end of the wait, an old failed run plus a newer queued one (`started_at` null) waits too, and a failed run of a different check is not hidden by another check's newer pass.
The live release reported to stackshot (Thu Nov 5th 2026, 13 checks; the fake client now logs `released` calls apart from messages, the fake `gh` answers `pr view --jq` from a file, the fake `deploy.sh` can fail):
after a successful open-PR release the client got `released --pr https://github.com/o/r/pull/<n> --sha <the merge commit GitHub names after the merge>` once, before the final message, which is still sent, with the
client's lines in the log as `items of PR #n: …`; an already merged PR passes main's merge commit and asks GitHub for nothing more; a refusing client (exit 1), with its error cut to 300 characters, and no client at
all (`STACKSHOT_CLIENT` and `SALA_STACKSHOT_DIR` empty: nothing sent, one `stackshot not configured` line) leave the release green; a failed deploy, in either mode, and a failing check never call `released`; with
GitHub naming no merge commit the PR's first-parent merge in the checkout is used, and with neither the log says so and nothing is sent. Not checked: a real transient unit, the real `gh` and `deploy.sh`, the real client.

### `tests/cipoll.sh`: new, 51 (Wed Oct 28th 2026)

The CI-run poller and its reader (`lib/cipoll.py`, `lib/cipoll.sh`, `lib/ci-repos`, `systemd/sala-cipoll.service`, `docs/ci-runs.md`). Kept because release.sh and
the builders wait on this file instead of GitHub: a torn file, a file that never ages when GitHub is down, or a rate-limited account hammered by a retry loop would
turn the saving into a hang or a ban. Run through the real verbs (`salamander ci-poll`, `salamander ci-runs`) in a locked temporary HOME against a fake `gh` that
serves canned workflow-run lists with an ETag (a matching `If-None-Match` gets 304 and exit 1, as gh does), answers the n-th ask with a raw error (status line and
headers), and logs every call; a poller run is bounded by `SALA_CIPOLL_CYCLES`, so no process is killed, and the waits are shortened by `SALA_CIPOLL_INTERVAL` and
`_BACKOFF_MAX`. Checked: the first look writes the file with the eleven fields and `updated` / `updated_iso`, no tmp file, one log line, no ETag sent; the second look sends
the ETag, a 304 writes the file again with `updated` bumped and the same runs, a changed list replaces them and logs once per change; a reader loop (22,000 reads) while the
file is replaced 60 times never sees a torn file and no tmp file is left; a tmp file a killed poller left is removed at start; an HTTP 500 keeps the old file byte for byte,
backs off 0.2 s then 0.4 s (twice the interval, doubling), is capped by `SALA_CIPOLL_BACKOFF_MAX`, a gh that prints no status (network down) is `HTTP ?` with the last stderr line, the
recovery is logged; a 403 with `x-ratelimit-remaining: 0` waits for the reset and reads no other repo meanwhile, a 429 with `Retry-After`, a 403 without the headers is an
ordinary error; a token-shaped string in gh's error is not logged; the repo list (comments, blanks, a repeat, an invalid line and `../x/y` named once and never a path, two repos
= two files, a repo added and one removed while it runs, the default `lib/ci-repos`, `~/.config/salamander/ci-repos` replacing it); `ci-runs`: fresh = 0 and the JSON, `--sha`
prefix, none = `[]`, a short sha = 2, `--text`, missing = 3, 300 s old = 4 with nothing on stdout, `--max-age` 400 / 0 / 100, corrupt = 5, no `updated` = 5, usage and a bad or
traversing repo name = 2, `--help`; the path under `XDG_STATE_HOME` and under `~/.local/state`; the unit file's lane, `ExecStart` and `Restart=always`. Not checked: the live `gh` and GitHub, systemd running the unit.

### `tests/stuckpost.sh`: new, 32 (Wed Oct 14th 2026)

The stuck-question watch (`lib/watch.sh` STUCK-QUESTION WATCH, `lib/common.sh` `SALA_PROMPT_RE` and `scrub_text`). A pane
stopped on a terminal-only question — a permission dialog, the read-outside-the-working-folder prompt, a numbered menu — is
a session that does nothing until someone answers in the terminal, and nobody watches a headless pane: the inbox is not
read while the dialog is up, and sala never types into such a pane (its relaunches wait the prompt out, `pane_prompt`). The
checks guard what would leave the owner untold, bury the one post that matters, or put something in a post that must not be
there: the fake claude shows a dialog from a file (`FAKE_PROMPT_FILE`, drawn as 2.1.29x draws a permission dialog, at the
bottom of the screen) and holds the pane until a key, `pane_prompt` is checked to read it as a prompt (the watch reads the
same 30 lines with the same pattern, so a dialog it posts is one every relaunch waits out), and one tick posts exactly once,
naming the session, the dialog's title, command and question and the session's sala-web link (the way to answer it from a
phone); the next ticks are silent; another question is posted (the pane is still held, by something else); the dialog
answered drops the record and the same question coming back later is posted again (a record kept past the episode would
hide the next one). An idle pane and a busy one (its registry row says a turn is running) are never posted; a question
quoted in a session's own output with the composer under it is not a question (`pane_prompt` counts it, cautiously, for a
relaunch; a post on it would be noise on every tick). The confirm window keeps a dialog that is being answered right then
out of Slack. The notify command failing: the post is tried on the next `SALA_STUCK_RETRIES` ticks and then given up for
that question, each attempt logged, and a later question still posts (a failure must neither end the tick nor repeat for
ever). `--stuck --dry-run` prints the post and posts, logs and writes nothing; the knob off reads and keeps nothing; a plain
`watch` tick runs the step (the timer's path); a retired session's record is dropped. The sweep holds what must never
reach a post, a log or the state: a token in the dialog's command (`Authorization: Bearer …`), an `ANTHROPIC_API_KEY=` value,
a 32-digit hex run, a Slack webhook url, each masked, and none of the dummy values anywhere; plain words only, no state separator in a headline. The wording beyond the session name, the dialog's lines and the link is not checked. Not checked:
the real CLI's dialog as drawn by the current version (the fake draws the 2.1.29x shape: a box, the title, the body, the
question, `❯ 1.` options), and a real Slack post (the notify command is a file).

### `tests/op.sh`: new, 85 (Wed Oct 14th 2026; 4 added Fri Oct 16th 2026)

The operation queue (`lib/op.sh`; `watch`'s `op_tick`; `op_unit_caller` in `lib/common.sh`): a fleet operation queued by
whichever session heard the owner and run by `watch` with no model, under the recycle lock as its own
`sala-op-<id>` unit, with one `claude -p` only when it is stuck. A queued operation runs unattended, so every check guards
the fleet from a wrong one or a session from a lost relaunch: a verb or an argument outside the shape table, a session or
host name that is not one, `lane default` without a lane, `reboot --go` as an argument, are refused with nothing queued (a
marker is run later by a process that cannot ask); a marker without the owner's words is refused, `--auto` is taken from a
plain shell (an orphaned call; the suite reads the orphan's ancestry first and, when the shell's orphans still fall under
a claude — a suite run from a Claude session's pane — asserts the refusal instead) and refused under a `claude` process (a relayed message is never the owner's words); `reboot` is refused while `SALA_OP_REBOOT` is off, its default (a reboot is not
queued: the refusal says the owner runs `sala reboot --go` themself and a session shows them `sala reboot --status`), and, with
the switch on (unsupported until a confirmation path is built; the code path stays), queued with `reboot --status` as its plan. The plan: the verb's own dry run runs first and its refusal refuses the operation — a retire of no such
session, of a busy pane ("would refuse"), a `revive --only` of no such session; `--plan` shows it and queues nothing; `--plan
recycle --update` runs no `claude update`. The marker's fields (id, time, who heard, the words verbatim and folded to one
line, `--stdin`, the verb and each argument as its own field, `queued`), the kick (`systemctl --user start --no-block
sala-watch.service`, or a one-off `watch --ops` 10 s on when a tick is running), `--list`, `--status`, `--cancel` (a queued one;
a running one refused), another verb on a session already queued refused, `SALA_OP_QUEUE=off` queued and not kicked. The
end of every operation reported to stackshot once (`client.py event --kind fleet_op`: verb, machine, sessions, result ok / partial / failed from the counts of the post and the recycle set; a plan reports none; a client that fails, hangs past `SALA_OP_EVENT_TIMEOUT` or is missing changes nothing but a line in the op log); the end-of-operation kick: with two more queued, an op that ends done and one that ends stuck each request one `watch --ops` (`sala-op-kick-end`, `--on-active=5`) and not two, the next starts on the following tick and not before the first ended (the stand-ins here are `model --clear` markers, a verb that runs alone, so the order holds; `tests/opparallel.sh` has the side-by-side rules); the last op of a queue, a lone stuck op and `SALA_OP_QUEUE=off` request none. The
guards: `master_guard` and `ops_guard` admit a caller whose cgroup (`SALA_CGROUP_FILE`) names a `sala-op-<epoch>-<pid>` unit
from another pane than the master's, and refuse it as before without, with a `sala-auto-*` unit and with the `-kick` unit
(the admission is what lets the runner drive a recycle in the master's place, and it must admit nothing else). Absorption:
three markers (a recycle, this box's update, a `recycle --force`) → one unit for the oldest with `--update --force`, the two
archived as `absorbed` with `into=`, the update's hearer told in its inbox; a plain `watch` tick (no master) runs the step. A
runner that ended without a result (the stub unit never ran): the next tick hands it to the stuck handler as its own
`sala-op-<id>-stuck` unit (never inside the tick: `sala-watch.service` is a oneshot whose leftovers die with it), the one
`claude -p` runs once — `--max-turns`, `--allowedTools` sala's verbs and read-only looks, no bypass flag, on a subscription lane with the api key, custom headers, entrypoint and config dir stripped from an environment that had them — with the operation,
the owner's words, what happened, what was tried and the verdict-line contract in its brief; one 🚨 post naming the exact
failure, the two folded in and the claude -p; the hearing session told; a later tick retries nothing and posts nothing. A
reboot marker whose runner is gone with the boot id changed is the box back: done. End to end: `recycle --force` from the
hearing session with one pane busy → queued with the sweep's verdicts shown → the unit under the lock (the holder line
names `op-<id>`) → the sweep relaunches the idle panes, the busy one goes to the retry worker → `waiting`, the set the
recycle's → the pane idle → the worker relaunches it, the set closes, the waiter judges: done, archived, 4/4, one ✅ post
with who asked and the words, the result in the hearer's inbox (the hearer was relaunched meanwhile), no claude -p. A pane
the set gave up (its pane gone while the worker waited: the window's end defers) → stuck with the set in the brief and the rescue named as allowed, the claude -p's
verdict in the result with no log lines captured into it. The claude -p's `done` is checked: a retire whose session still
lives → stuck with the check named and the session untouched; one that really ended it → done through the claude -p with
the first try in the result. Two queued operations naming one session (markers written past the enqueue check) → the first
stuck on the conflict, the second still queued, the session untouched; `SALA_OP_STUCK=off` runs no claude -p and the post
says none. The waiter's deadline → stuck with the pane named, the retry worker going on by itself. Not checked: a real
systemd unit and cgroup (the stubs stand in; the cgroup line is written by the test), a real `claude -p` (the stub), a real
Slack post, `update`'s and `provision`'s remote legs, `lane` and `rename` through the queue beyond their shapes (their dry
runs and verbs have their own suites), the reboot verb's run.

Added on Fri Oct 16th 2026 (the project-name panes retire; 4 checks): where an operation's reply goes when the pane
that asked (`--from`) is gone, so a result never falls silent. `op_tell` is called straight, against a live pane that
logs its inbox, a retired name with a live `<name>-main`, and names with neither. A live asking pane gets the line as
before (once, unchanged, nothing about a fallback in the op log). A dead one with a live `<name>-main`: the line reaches
the `-main` pane with `[for the user]` as its first line, and the op log says `reply: <from> has no live pane; sent to
<from>-main` (and never `told <from>`: tmux reads a bare `=name` target of `list-panes` as a prefix match, so the retired
`demo` would have found `demo-main` without the `[for the user]` line; the lookup uses `=name:`). Neither live:
nothing is delivered and the op log has `reply FAILED: <from> has no live pane and <from>-main has none either`, the
call still returning 0 (the Slack post stands). A dead asker that is itself a `-main` gets no `-main-main` try and the
failure line. Not checked: a live pane whose messaging socket refuses the push (logged as `reply FAILED … push …`, no
fallback; the code path is a one-line branch).

Added on Sun Oct 25th 2026 (the `model` verb; 42 checks): a session changes its own or another's model and effort
through the queue (`lib/op.sh`, the `model` shape; the switch itself is `lib/model.sh`, `tests/models.sh`'s). Every check
guards a session from a relaunch it did not ask for, or a queued operation from running on a wrong value. The shape table
gained 13 refusals, each exit 2 with nothing queued: no model, no session, an unknown model, a `claude-…[1m]` id (a glob on
the launch line), an unknown effort, `--effort` with no level or twice, `--record-only`, `--dry-run` and `--not-master` (not
queue arguments: a queued record-only would write a row the words did not ask for), `--clear` with a model, `--effort`
where the model goes, a session name with a space; the bad model and bad effort say what is accepted. The plan is
`model … --dry-run` (an unknown session, `--clear` included, refuses it before anything is queued; `--plan` writes no row and
queues nothing; `--clear` has its own note); the plan runs without `TMUX_PANE`, so for the asker's own session it shows the path
the unit takes (`revive --force --only`), not `revive --self`. The marker holds the verb, session, model, `--effort` and level
as arg lines with the words, and no row is written until the unit runs; another verb (`revive --only`, `lane`, `retire`) on
a session with a `model` queued is refused as naming the same session. The notice "this pane will be relaunched once it is
idle" prints when the target is the asking pane's own session and not for another session or for `--clear`. End to end
through the unit: an idle pane's row is recorded and its claude relaunched on `--model haiku --effort high` (one ✅ post, the
result in the asker's inbox); the asking session, busy, is recorded at once and not relaunched while busy (state `waiting`,
a retry worker holds it), then relaunched exactly once when idle with `--model sonnet` and no `--effort`, and gets the result
in its inbox after its relaunch; `--clear` through the queue drops one row, keeps the other and relaunches nothing; no
`claude -p` for any. Not checked: the verb on a real lane or against a real claude, the `op_verify` branch for `model` (only the
stuck handler's `done` reaches it), a `model` on a pane that SALA_NO_RELAUNCH names (model.sh's own refusal, `tests/models.sh`).

Added on Thu Oct 29th 2026 (the many-session `model` form; 26 checks, 147 → 173): a batch of model changes is ONE
operation with ONE result notice, so the asking agent is woken once, not once per session.
Every check guards the requester from the old flood or the fleet from a half-queued batch. The shape: `model <model>` with
no session, `model <model> --effort <level>` with none, `--record-only` on a batch, a bad effort and a name with a space are
refused at queue time (exit 2, nothing queued); one unknown session among three refuses the WHOLE operation, naming it, with
nothing queued and no row written (so does `--clear` with an unknown one). The plan is one plan for all the sessions, and
says one sweep and one notice. The rule for old against new is the first word: `model sala-test-e haiku --effort high` is
planned as the single-session shape it always was, `model haiku sala-test-e` is the many-session form even with one session.
Through the unit, three live panes on `haiku` at `high`: ONE marker holds the model, effort and the three sessions as arg lines;
another verb on any one of them is refused while it is queued; when it runs, the three rows are recorded and the output has
ONE sweep for the three relaunches, each pane relaunched exactly once on `--model haiku --effort high`; one line per session
on the marker; ONE Slack post carrying every session's line and who asked; ONE line into the asker's inbox carrying every
session's line; no `claude -p`. The single-session `--clear` through the same unit is unchanged (no per-session lines);
`--clear <session>…` drops both rows in one operation with one post and one inbox line. A session that fails: through a stand-in
`lib/model.sh` that prints what a batch with a failure prints, the operation ends stuck without the `claude -p`, the result
names the failed session, the marker keeps a line per session, and one 🚨 post and one inbox line carry the failed session's
line and the one that stood. Not checked: a real failure inside one session of a batch (the stand-in prints the failure line; no
session here can be made to fail on its own), the `op_verify` branch for the many-session form (only the stuck handler's
`done` reaches it).

Changed on Thu Oct 15th 2026 (no master): the stub unit runs its command in the queue's cgroup (the stub exports
`SALA_CGROUP_FILE` naming a `sala-op-<id>` unit, as the real unit's `/proc/self/cgroup` does), since with no master the
guards refuse a Claude caller and a suite run from a Claude session's pane is one; the counts are unchanged. The master's
own retire through the queue and the guards with no master are `tests/nomaster.sh`'s, below.

Changed on Thu Oct 15th 2026: the queue gained the `spawn` verb (a project agent's session, with its TEXT
mandate written to `~/.local/state/salamander/mandates/<id>-NAME.md` at queue time) and `op_conflict_with` refuses a second
spawn of a name already queued (two of one verb were never a conflict before; they still are not for the other verbs — this
suite's checks of a retire queued twice and of absorption hold unchanged). Everything about the verb is `tests/spawn.sh`'s,
below; nothing here changed.

### `tests/opparallel.sh`: new, 57 (Wed Oct 28th 2026)

The parallel rule of the operation queue (`lib/op.sh`, `op_shape` and `op_tick_locked`; `recycle_lock_shared` in `lib/common.sh`;
the snapshot lock in `lib/spawn.sh`). Fakes only: the compiled fake claude on a private tmux socket, stub `systemd-run` and
`systemctl`, a fake page check, stackshot client and register hook, a fake resurrect save; a stub `sort` and a `sitecustomize`
put random delays into the pane map, the sessions registry and every verb, so two operations meet at the lock and not by luck.
Decisions: parallel-safe operations start together up to the cap in one pass, the rest wait; `SALA_OP_PARALLEL=1` is one at a
time and a non-number is the default 3; a second operation on a name waits and a younger one on that name does not jump
ahead; a solo operation (recycle) waits for all running ones, blocks the younger ones and has the queue to itself once
it runs; a lane default, a retire of a name only the registry resolves, the master's retire and rename, a marker that fits no
shape and a running marker with no class all run alone; a waiting operation holds its names. Each verb's own declaration is read in one shell (spawn
and its fork source, retire of a live session, rename: par with the shared lock; the rest solo). The races: 20 rounds
(`SALA_OPPAR_ROUNDS`) of two spawns and a retire, a rename every third round, run side by side with random delays, each round
checking the pane map (the controls kept, one whole row per new session, none lost or torn), the registry rows and ledger,
the side records, the lane and model rows, the operation markers, the result messages and Slack-post stubs and the stackshot
client's call log, that no more than the cap ran at once, that verb processes of different operations really ran at the same
moment, that the recycle lock was only ever held shared, and that no two resurrect saves overlapped. The recycle lock: shared
holders at once, an exclusive taker (a relaunch driver) refused beside them and a shared taker beside it, `recycle_locked` reading
locked. With real runners: a solo operation starts after the running spawn ended and the retire behind it after it;
`SALA_OP_PARALLEL=1` runs three operations one after the other; two retires of one session never overlap; a burst of five spawns runs three at a time and
leaves five whole rows on their own conversations, with the follow-up tick asked. The suite cleans up on exit and on TERM, INT
and HUP (processes still running on its HOME are killed before the folder goes), and holds a lock on its temp folder.

### `tests/settingsapply.sh`: new, 40 (Wed Oct 14th 2026)

The settings-apply service (`lib/settings-apply.sh`; `watch`'s `settings_tick`; `provision --quiet` and
`SALA_PROVISION_RESULT_DIR` in `lib/provision.sh`): a Claude Code settings change that lands in the config repo, applied by sala on a machine and its peers and never by a session. It writes `~/.claude/settings.json` on every box unattended, so every
check guards a box from a wrong or lost write: the kill switch reading and writing nothing; the first tick recording the
fingerprint and the commit and launching one `sala-auto-settings` unit for the boxes behind it (an asleep box left out
until the heartbeat store says it answers, then its own launch), each box's first look dry — "would apply" in the step's
words, recorded, no apply run, no backup, the file untouched; an unchanged spec launching nothing; a spec change → the
check, the backup beside settings.json here and over ssh (`settings.json.bak-sala-settings-<stamp>`, the step's own
`.bak-provision-*` too), the apply only where a settings step drifts, provision's check after it, the applied line in the
step's words and one diff line per key changed (`model: "sonnet" → "opus"`), the steps script sent exactly the
settings-class steps with `repo` first, nothing posted; repo-only drift applying nothing; a failing step: one post with
the step's own words (`fold_check` now keeps an apply's own failed line instead of replacing it with "still off"), the
box retried after `SALA_SETTINGS_RETRY` for itself alone with no second post, then fixed with the fail cleared; the
hourly retry gate held only for a box whose last try failed (a box that succeeded on an older spec is due at once); a
settings.json that no longer parses after the apply put back from the backup, the box a failure posted once; a step name
no script lists refused by provision before any box, logged and posted once per fingerprint, every box applied once the
steps are back; two runs at once (the second exits 75 with the lock line, the first ends on its own); the unit still
active → no launch, said once over two ticks; an offline box recorded as offline (not failed), the stale post once per
fingerprint naming it, the box applied once it answers; `--check` printing the verdict (in step, or what it would apply)
and writing nothing; `--status`; `provision --quiet` alone refused. Not checked: a real systemd unit (the stub runs the
unit's command at once, so `wd_launch`'s `--fixed` refusal by systemd is not exercised), a real ssh (the stub switches HOME
to the host's folder), the real provision step scripts and their spec items, a real
Slack post, the 5-minute offline backoff (reset by hand), a run from a Claude pane (provision's master guard).

Changed on Thu Oct 15th 2026 (no master): the suite calls `as_op_unit` right after it sets its HOME
(`tests/lib.sh`, header 5). Its `systemd-run` stub runs the `sala-auto-settings` unit's command in the suite's own shell,
so the apply leg's `provision` (the check leg passes on `--check` alone) reaches the guard from under the Claude session
that runs the suite, which with no master is refused and pointed to `sala op`; the real unit runs in its own systemd
cgroup with no Claude session above it, and the cgroup file stands for that. The counts are unchanged.

### `tests/nomaster.sh`: new, 56 ("No master session", Thu Oct 15th 2026); 4 added Sun Oct 25th 2026

The master is optional since the operation queue (a configured master can be retired once the queue works), and retiring it is one queued operation. Every check guards one of two losses, or the operation itself. A master coming
back from a record after it was unset — `watch` recreating, resuming or bridging it, a last-good restore naming it again —
is a session nobody asked for driving relaunches: `salamander master --unset` on a temporary config is checked to
comment the line out and leave the file parsing with the other lines intact (`salamander config` reads none), to drop the
watchdog's records of the master (name, conversation, bridge, lane, directory) and record `master_unset`, to refresh the
last-good copy to the unset config, to be idempotent, and to leave the session itself alone; `master`, `--name` and
`--json` read "unset", and `--set` again clears the record. A fleet verb run raw by a Claude session with nobody holding
the one-driver rule is two drivers on the same panes: with no master a Claude ancestor is refused with the `sala op …
--words` line and nothing relaunched (`retire`, `recycle --force`; a verb the queue has no shape for, `restore`, refused
with that said), while the queue's cgroup, a `sala-test-*` target, `--dry-run`, `--not-master`, `--check`, a human's pane
shell (`TMUX_PANE` set, tmux above it) and a `tmux run-shell` (the resurrect boot hook's way) pass; the control, a master
set and a Claude caller outside tmux, passes as before. The operation: a plain `retire <the master>` and its dry run
refuse outside the queue, `op --plan` says "would unset SALA_MASTER, then retire", the unit's log has the unset (its output
included) before the retire, the marker carries `unset_master`, the config names no master, the session is gone, one ✅
post names the unset; a retire that fails after the unset (the pane busy by then) is stuck with `SALA_MASTER` still
unset, the session alive and the post saying `master --set` puts it back; an unset that fails (the config's directory
read-only) is stuck with the retire never run and the config untouched. `sala cue`: with a master the words land in its
inbox; with none exit 1, the pointer, the verb table, one example, and nothing in any inbox or the cue log (a cue that
silently went nowhere is an operation the owner thinks happened). `watch` with no master: `--check` healthy and exit 0; a
state that remembers a master with no `master_unset` record is the lost config (exit 1) and healthy once the record is
back; a plain tick heals nothing, recreates no session, types nothing (no `/remote-control`), posts nothing and writes no
master record; the post-boot report is one Slack post with revive's summary and not a second one on the next tick; the
tmux server down with no `tmux.service` and no master is logged and nothing is started (the bare `tmux new-session -s ""`
the master's heal would have run). The boot hook's revive with no master, launched by `tmux run-shell` as the resurrect
hook is: passes the guard, relaunches the panes, leaves the boot record the report reads. Not checked: a real systemd unit
and cgroup (the stubs stand in; the Claude ancestor is a script named `claude`), a real Slack post, `reauth --done` with
no master (it returns cue's exit 1 and pointer), the heartbeat's `master ""`.

Added on Sun Oct 25th 2026 (4 checks): `model` is a verb of the queue now, so a Claude session's raw `sala model
<session> <model> …` and `sala model <session> --clear` (on a session with a record) are refused with the `sala op model … --from
<you> --words` pointer, and no longer with "the queue has no 'model' verb yet": no row written, the existing row kept. The
`--dry-run` form passes (the queue's plan runs it) and so does the no-argument table form, which is read-only. The target is a
plain tmux session not named `sala-test-*` (those pass the guard from any pane).

### `tests/spawn.sh`: new, 116 (Thu Oct 15th 2026)

The project spawn (`lib/spawn.sh` THE MANDATE and A PROJECT AGENT; `lib/common.sh` THE PROJECT SPAWN'S CHECKS; `lib/op.sh`
the spawn verb and THE MANDATE'S TRANSPORT): `spawn NAME --project <page key> --role front|back [--mandate FILE|TEXT] [--lane
L]`, the one path a web request or `sala op spawn` takes to make a project agent's session, unattended. A session made wrong
is a conversation nobody owns: one made under a name its page does not list reads no mandate and is never found from the
board; one made twice, or over a live name, is two writers; a back agent made without a mandate sits at its first prompt
for good. So every check guards one of those, or the pages' contract the web layer parses. Refused before any page is
asked or anything made (exit 1, no `pages.py` call, no session): `--role` without `--project` and the reverse, a role that
is not front or back, a back agent without a mandate, a name outside sala's rule (characters, a dash at either end, 49
characters; 48 passes), a key outside a page key's shape, an empty `--mandate`, `--brief` of no such file (a file only),
`--lane nope`, `--effort huge`. The page: missing → exit 4 with `NO-PAGE: <key>` at column 0 and the pointer to a session that can write pages (nothing in sala writes to the page store), nobody messaged; `resolve` or `agent-listed` unable to tell, or no
`pages.py` anywhere → refused (exit 1), while a plain spawn with no `pages.py` passes as before (`agent_unlisted` fails
open: the two rules side by side). Not listed → exit 3, the refusal on stderr and the `ADD-TO-PAGE: <key>` block on stdout
in the pages' shape (`agents:` then `  <name>: <mandate>` for front; `agents:` / `  background:` / `    <name>: …` for back),
the mandate line the first non-blank line with its heading's `#` stripped, cut to 70 characters (a non-ASCII line at 70 characters, never mid-character), double-quoted for a `: ` inside or a leading dash and plain otherwise (the exact value
the keeper pastes; pages.py's frontmatter reader takes it back whole); the keeper asked by one stackshot message to the
page key with sender `sala spawn` and the block inside, the same name not again within the hour, each further name once,
who heard and the owner's words (`SALA_OP_FROM`, `SALA_OP_WORDS`) in the text; no message with `SALA_SPAWN_REGISTER` configured
(registration is the hook's) or with `SALA_SPAWN_ASK_CMD` set empty, both logged; a name listed on another page and pages.py's
"no project page for this name: nothing to check" (exit 0; a refusal naming `(steward …` instead of `(the page whose …` is read too) both count as not on this page; `SALA_AGENT_CHECK=off` makes no
call and says so. Listed: the dry run prints the plan and makes no session, writes no pane-map row, no lane row (`--lane subscription-1 --dry-run` says "recorded" and writes nothing), calls no hook; no NAME with `--project` takes the suggested name; a tmux
session of the name and a running claude registered under the name are refused before any page is asked and with no
message. `--suggest-name`: `projects/demo-docs` front → `demo-docs-main`, `projects/demo-api` back → `demo-api-<word>`, `projects/demo-room-b` front → `work-demo-room-b-main`, no `--role` refused (the web form shows the suggestion).
The spawns against the fake claude: a front agent with a file mandate given as a relative path → the orientation line
typed with the marker and the ABSOLUTE path (the pane's shell starts in `--cwd`, not where spawn ran), "Do not act on it
until I confirm", every other line a slash command, the pane-map row, no lane row and the default named, the register
no-op said and logged with nothing run; a back agent with a file mandate and `--lane subscription-1` → "Then start on it; nobody is
waiting to confirm" (`--role back` implies `--no-confirm`), the lane row recorded, the hook's four arguments (name, key,
role, file) and its `SALA_SPAWN_NAME/PROJECT/ROLE/MANDATE_FILE/MANDATE_LINE/UUID/LANE`; a front agent with `--prompt`
and a hook exiting 7 → the text typed as the first message with the marker, exit 0, the session up and mapped, one ⚠ line
with the exit code and the log, the hook's file argument empty and the line in `SALA_SPAWN_MANDATE_LINE`. The queue:
twelve shapes outside the table refused with exit 2, nothing queued and no mandate file left (the text written before the
shape check is removed); `--plan` shows the dry run with the mandate's first line and writes no file; not listed at queue
time → exit 3 with the block once more at column 0, nothing queued, the file removed, the keeper asked with who heard and the owner's words; no page → exit 4; a TEXT mandate (a heading, a blank line, quotes, non-ASCII text, dashes) → the marker's `arg=` lines
carry the options and the FILE's path, never the text, the file's bytes equal the text, `--cancel` removes it; a readable
FILE given passes as it is with nothing written; `--prompt` of a path that is a file is text all the same. End to end:
queued with the plan shown → the tick starts `sala-op-<id>` → done and archived, the session up and mapped, reading the
file the queue wrote and starting on it, the file still there afterwards (the session reads it at its first prompt), one ✅
post, no `claude -p`, the register no-op logged from the unit. Two queued spawns of one name → the second refused as
naming the same session (a change to `op_conflict_with`: two of one verb are no conflict except two spawns, since the first
makes the session and the second can only fail on it), its file removed, the first's kept until its cancel removes it. A
name listed at queue time and removed before the run → stuck with "exited 3" and "only the page's keeper can add the
line", no `claude -p` (none could add it), no session, the keeper asked from the unit with who heard and the owner's words (the runner exports `SALA_OP_FROM`, `SALA_OP_WORDS`), one 🚨 post, the mandate file kept for the next try. Not checked: the real
`pages.py` against live pages (the stub answers in its shapes: `<key> True|False|None`, `listed on <key>: …`, the exit-3
line, "nothing to check"), a real stackshot message (`client.py message`), a real register hook, a real systemd unit (the
stub), a real Slack post, the `--fork` and `--master` paths (unchanged; `tests/mod.sh`, `tests/ledger.sh`).

### `tests/lanefields.sh`: new, 109 (Thu Oct 22nd 2026)

The lane fields (`lib/common.sh` "THE LANE FIELDS", `lib/lane.sh` `--list` and `--json`): what a lane is (provider, client, org,
billing, plan, account, credential, region, status) apart from how it launches. Fields only, so what is guarded is the
launch side of the change, not the table's wording. **An unknown lane word**: `lane_known` fails for a word that is no lane and every entry that takes a lane (`lane_check`, `sala lane <word> …`, `lane default <word>`, `spawn --lane <word>`) refuses it by name; a stale word never falls back to the default without a sound and the op queue never accepts it. **bedrock** is a known lane
that `lane_check` refuses as not set up, so no pane and no default can be put on a lane with no launcher (a relaunch onto it
would sit at a shell). **sdk** stays an accepted word (an alias of api with client claude-agent-sdk) with its settings
`SALA_LANE_SDK_PIN`, `SALA_LANE_SDK_CMD` unchanged: a row of sdk in `lanes.tsv` must keep launching as
it did. **`lanes.tsv` is never rewritten**: a seeded table (rows of the accepted older words and of an unknown one) is compared byte for byte, mtime
included, across the table, `--list`, `--json` and four refusals; a written row is still `<session>TAB<lane>`; a row of an unknown word is flagged under the table and launches on the default, and a default file naming an older word reads as its lane (stackshot reads these names). The rest is the spec held in place so a later edit cannot drift from it: every field of the four lanes, the
spec's lists (providers, clients, plans, statuses) and the usage/subscription rules, config overrides winning and a bad
override flagged, `--json` parsed (a program reads it: null for a field a lane leaves out, the sdk alias) and `--list`'s
columns lined up. A few of these are wording by the rule above; they stay because the fields and the table
are the deliverable. No tmux server is started.

### `tests/netwake.sh`: new, 29 (Thu Oct 22nd 2026)

The network-stop wake (`lib/common.sh` THE NETWORK STOP and `net_scan`, `lib/watch.sh` NETWORK-STOP WAKE, the count in
`lib/revive.sh`'s boot summary and in the post-boot report). It guards a session that does nothing for hours: after a reboot with DNS down a pane can end its first turn on "Can't reach the API server", and nothing retries such a turn. It stays by the rule's first loss (a session lost to its owner), and each
check is one way it would fail unseen. Transcripts are written by hand around a fixture in the CLI's shape (`tests/fixtures/net-eai-again.jsonl`, the error and the turn_duration record after it); the fake claude takes the message on its messaging socket
(`FAKE_SOCK_LOG`) and DNS is a `getent` stub. Checked: the detector reads only the newest assistant record of the main
thread, and only an API error record with the text family (a pane that worked after the error, an answer that quotes the
text, the usage limit and an error older than the lookback are not stopped; two errors in a row are one run with a first and
a last epoch); DNS down sends nothing, and the lookup is made once a tick and only while a pane waits; DNS up sends exactly
one message to each stopped pane with the plain text, never to the others, a busy pane once it is idle; a second run, and a
woken turn failing again on the same error, send nothing more (a second message into a pane that cannot answer would pile
up); a pane that worked and stopped again later is a new episode and gets one more; a pane whose session is gone is skipped
without a log line; the knob off reads and keeps nothing; a plain `watch` tick runs the step (the timer's path); the
post-boot report names the panes stopped right now and not the ones that answered; revive's boot summary says "1 resumed, 1
of them stopped on a network error; woken once the network is back" for a pane it resumed whose last turn ended on it, and
revive itself pushes nothing. Not checked: the message's wording beyond the sentence the brief gave, the real CLI's reaction
to the message (the fake logs it), and a live resolver (`getent` is a stub).

### `web/tests/test_board_items.py` and `web/tests/test_board_items_ui.py`: new, 13 and 9 (Thu Oct 15th 2026)

*The page side of this entry was removed Thu Nov 5th 2026 with the item count button (the entry at the end of this file). The server side stays.*

The page shows each live session's open stackshot items and marks the sessions with something waiting on the owner
(`web/README.md`, *Board items*). Neither of the rule's losses applies to a read-only view, so the checks kept here
guard the one thing a wrong answer costs: the owner acting on the page's word about their queue. A missing red count is a decision they do not know is theirs; a count on the wrong session, or one that counts a held item, sends them into a session that has nothing for them; a wrong link sends them to the wrong item. Every check protects one of those or the
token. Server (`test_board_items.py`, a fake fetch, no real board: `conftest.py` points the token and URL settings at
missing files for every test): the waiting rule (`decision` in `needs` and not held; a held item is never waiting
whatever its `needs`; `external` is not the owner), the item's page from its shown id (`board#N` → `/items/N`,
a temporary id as its dashed form, an old `sN` as it is) and the order waiting first, held last; the
first start answers at once and fills in for the live sessions, one round per minute however many pages poll, a
restart serves the saved answer and refreshes once, a fresh saved answer asks nobody; the state file is 0600 and
holds no token and no server address; a missing token or URL file gives its plain message and makes no request; a
401, an unreachable server and an unexpected answer carry no secret in their message and keep the last answer; one
session's failing read keeps that session's last answer and marks the round `partial`; at most 4 reads in flight;
`STACKSHOT_URL` wins over the file and a non-URL is refused; the request goes to `/client/items?key=<name>` with the
bearer header. Page (`test_board_items_ui.py`, headless Chromium, the three APIs stubbed): the chip sits after the
name and outside the fold (markup and the `FOLD` list parsed); the sidebar rows carry no board count (a later change
removed it: the rows show the unread reply count, `test_unread_count.py` below; the board count lives on the header chip
and the Overview); a tap on the chip opens that session's sheet (the hash and the sidebar unchanged) with the rows in order,
each the item's page in a new tab with `noopener`, the tags saying whose move it is, the held one under its line, 44 px
rows, a bottom sheet inside the screen on a phone that scrolls inside itself with 40 items, Escape and the scrim
closing it and the focus going back; the chip at 320, 390, 760, 1000, 1100 and 1280 px beside a whole name, inside the
header, no sideways scroll, the icon and the count alone at every width (43 px; the words in its accessible name and
tooltip) and nothing folded from 1000 px, as without it (`test_header_fold.py` also holds a short name with four badges
folding Reload at 996 px with the chip, nothing without it, since the toggle left the fold), a popover under it at 1280 px and the bottom
sheet at 390 px, hidden in the Overview; the 60-character name folds everything with the chip whole beside it and is cut only at a phone's width; the Overview's
count on the waiting session only, opening its sheet with the table's page scroll unchanged at 390 and 1280 px;
WCAG AA (4.5:1, opaque) for the chip, both strong and quiet, and the tags in both themes; the first paint
not moving when the board's answer lands (every row's box and the header's the same before and after) and a failed
poll leaving the markers; one request on load and one a minute. Not checked: a real phone, the access proxy in front, the production service, a live stackshot answer.

Added on Thu Oct 22nd 2026 (the Waiting group; 2 checks in `test_board_items.py`, 4 in the new
`test_board_items_waiting.py`; two assertions of `test_board_items_ui.py` reworded). The sheet's "On hold" group became one
group "Waiting" built from stackshot's one rule for an item that waits, and a wrong list is what costs here: an
item handed to another session shown as this session's work, a late one not looking late, or the owner's red count moving.
Server: `mover`, `wait`, `expected_by`, `overdue` and `step` pass through as they come (a fractional epoch cut to whole
seconds), "waiting on the owner" is `mover.kind == "owner"` and not an item that waits `via` another (not counted twice), an
older answer without a mover keeps the `needs` rule and its exact old shape, and malformed fields (a string mover, an
unknown kind or wait, a boolean, a negative step) are dropped and over-long names cut. Page (`test_board_items_waiting.py`,
headless Chromium): the sheet's order (the session's own items, "Can no longer end" apart, then Waiting by expected-by with
the undated item last, no "On hold" group); a hold or an idle item the session moves itself stays active; each row's line
(whom or what, `via`, the kind of wait in words, the time in the `SALA_TZ` zone (local time when unset), no time invented for an undated one); "overdue" as a word
on the row for the late ones only; the red count and tag staying the owner's alone; the chip naming the other waiting rows; the
quiet count leaving the Waiting rows out and a session with only Waiting rows having none; AA contrast of the new tag and
line in both themes; and an older stackshot (no new fields) falling back to `held`. Not checked: a real stackshot answer
with the fields (its shapes were read, not called), and the choices a reader could take the other way: a failed wait of the
session's own sits under "Can no longer end", not among its active items.

### `web/tests/test_reply_footer.py`: new, 8 (Thu Oct 15th 2026); 9 with the closing paragraph (the same day)

A reply's footer, the labelled closing notes a session leaves last (a lead word, a colon and optional bullets), renders apart from the body (`web/README.md`, *Develop*). Neither of the rule's losses applies to how a reply is drawn; the checks kept guard what a wrong split costs the owner: body text shrunk and dimmed as if it were bookkeeping (a footer swallowing the body), a note left in the body where the point was to set it apart, a closing ask shrunk and dimmed with the footer (the ask is what they must act on), and a link in the footer they cannot read or tap. The rule (`splitFooter`, run in node): a note after a blank line and a note line right after prose both split; a note with its bullets, then two more notes, is one footer of three notes with the bullets on their note line; a lead in a second script with bullets, and a note after it, is a note of its own (a bold lead too, while a line that starts with the lead word and no colon is prose); four adjacent notes of one kind are four notes; a note followed by two paragraphs, a reply with no note, a single note-like line right after prose, a deck's `Page 1: …` lines and a sentence starting with a word that only looks like a lead ("Board members") are all body, and a reply without a footer comes back as its own text; bullets above the first note stay in the body; a note right under a bullet is its own note; trailing blank lines belong to nobody; a fenced block right under the note means no footer; the footer as the whole reply has an empty body. The closing paragraph (an ask after the notes; such replies showed unstyled): a footer of two notes, then one paragraph, splits into body, footer and tail, with bold leads the same; notes of the weaker kind alone before a paragraph stay body; a note then one paragraph is footer and tail; a paragraph that begins with a note line, or one of nine lines, keeps the reply whole and eight lines is the cap; the ask with its bullet options is one paragraph; a footer that starts the reply with a tail has an empty body; trailing blank lines after the tail; bold and underscored leads read as the plain leads while a bold word that is no lead stays prose; a backticked slug after a lead is a note. The page (headless Chromium, the fake transcript with one reply per case): every footer is
a second `.md` after the body at 0.85 of its 16px, in the `--muted` token (the colour an element given `var(--muted)`
computes to) with AA contrast (4.5:1) on the page's background in the dark and the light theme, under a 1px rule in the
`--border` token 10px below the body, with one block per note each below the last (Board: a paragraph and its list);
its links are anchors in the accent, underlined, opening in a new tab with `noopener noreferrer`, hit where they are
drawn (`elementFromPoint`) and no shorter than a body link (22px against 19px); the footer that is the whole reply has no
rule and nothing beside it; a reply with a note followed by two paragraphs, one with no note and one with two paragraphs
after its Write-up render as the one `.md` that `md()` alone makes of the text (`outerHTML` equal); a footer followed by
the ask, with plain leads and with bold ones, renders body, the dimmed footer under its rule, then the ask as a third
`.md` at the body's size and colour with no rule and a gap above, in that order, its links anchors in the accent that hit
where they are drawn and no shorter than a body link's, the bold lead drawn as its word and not its asterisks; a code
block's copy button stays in the body and the footer gets none; the message's copy button hands the clipboard the text
as written; no sideways scroll at 320, 390 and 1280 px with a 290-character URL in a footer note, every footer and tail
block and link inside the viewport; a reply appended to the transcript while
the page is open (the stream's `append`) arrives split the same way. Not checked: a real phone, the page's webfont (the headless browser falls back to a system font, so the tap heights are that font's), a reply arriving while the stream
reconnects (the `reset` path renders through the same function), the production service.

### `web/tests/test_composer_lists.py`: new, 14 (Thu Oct 15th 2026)

Tab as an indent and lists that continue in the composer (`web/README.md`, *The composer*, "Tab and lists"). The rule's
first loss applies: these keys edit an unsent draft under the owner's hands, and the session receives the text the box shows,
so a wrong edit, a lost caret or a payload that differs from the box is a message they did not write. Every check guards one of those, or the way out of the key trap. Headless Chromium, trusted keys over DevTools, on a desktop and in emulated
touch mode: Tab in the empty box is two spaces with the focus still in the box and nothing sendable, mid-line at the
caret, over a selection in its place, twice in a row never a focus move; Shift+Tab takes two, one or no leading spaces off
the caret's line alone with the caret and a selection kept on their text, and with none to take neither moves the focus
backwards; Tab on `- `, `* `, `1. `, an empty `- ` and an indented item nests it with the caret on its text (a caret put at the line's
start too; a range from the line's start keeps its start before the marker), a dash without
its space, `1.a` and a dash mid-line are plain lines; a selection across lines indents and outdents every line it touches
(a selection ending at a line's start leaves that line out; two, one and no spaces taken per line; backward stays
backward; list lines nest as lines; nothing to outdent changes nothing). Escape then Tab leaves the box (the focus moves
on, the text untouched) and a focus back, a key press after Escape, or the one passed Tab arms it again, while a second
Escape or a Shift pressed alone does not. The guards, on synthetic keydowns the handler must leave alone: Tab with Ctrl,
Alt or Meta, with Shift+Ctrl, with `isComposing`, with `keyCode` 229, Shift+Enter with either, and all of them between a
`compositionstart` and a `compositionend`, each not prevented and the text as it was, the keys the page's again after the
end; a DevTools IME composition with a 229 key during it and Tab nesting after the commit. Lists: Shift+Enter on a
desktop continues `- a`, `* a`, `1. a` (`2. `), `9. a` (`10. `), an indented item with its indent, a list after a blank
line, and the item typed on continues again; the empty item ends the list leaving the line empty (the indent gone too, a
numbered item, an item of spaces alone, a middle item between two), the box empty again after the only item, and the
next Shift+Enter is the plain break; mid-line splits the item with the caret after the new marker, a selection within the
line is replaced then continued, a caret put at the line's start or inside the marker is at the item's text, so Shift+Enter there splits the item,
a range from the line's start and a selection across lines get the browser's own break; the `- ` typed stays the text `- `; plain lines (`a - b`, `-x`, `1.a`, `1) a`, `-`) break as before.
Touch mode: Enter continues and ends a list, Enter on a plain line stays a new line, Shift+Enter and Tab from an
attached keyboard do the same, the Send button and Ctrl+Enter send the box's text. The payload of a six-line draft with
nested and numbered items and a blank line is the box's text byte for byte on a desktop and in touch mode, a trailing
marker included, and the pending bubble shows it; Ctrl+Z takes back a continuation, a nest, a multi-line outdent and a
list's end one key each; a draft with its indents and markers survives a reload. Not checked: a physical phone (an on-screen keyboard: whether it commits a composition before its Enter, what its Tab arrives as), a CJK IME, Firefox or
Safari (whether `execCommand` is there; the fallback splices the text and dispatches the event itself), the production
service.

### `web/tests/test_composer_cm6.py`: new, 13 (Fri Oct 23rd 2026: the composer on CodeMirror 6); 17 since Sat Oct 24th 2026

The composer moved from a hand-made contenteditable to CodeMirror 6 (`web/README.md`, *The composer* and *The bundle*). The
rule's first loss applies twice over: the box holds an unsent message under the owner's hands, and what the session receives is
the document, so a marker typed into the text, a caret that lands inside one, a Backspace that eats the wrong thing or an IME key that edits the box is a message they did not write. The bundle is vendored (a minified script with the MIT banner, the exact
versions of `@codemirror/state`, `view` and `commands` in the banner, the README and `package.json`, the lockfile's resolved
versions, the recipe's files, nothing fetched at runtime, loaded before `app.js`, served from `/static` with no other script on
the page, CodeMirror's EditContext off in the source and the bundle). Headless Chromium, trusted keys over DevTools: `- a` is
drawn as a dot (a widget with `contenteditable=false`, its glyph in from the line's left edge and clear of the text, in the muted
colour) while the document stays `- a`; the new line continues the list and the box's text is sent byte for byte with no
glyph in it, bubble included; `1. ` keeps its number in a styled, hanging marker, `* ` is a dot, a nested item sits further in,
`-a`, `1.a` and a dash mid-line are no lists, a long item wraps under its text. The caret: ArrowLeft from the text start goes
to 2 and stops there on the first line (not 0, never 1); the indent is part of the marker; numbered items;
vertical motion onto the marker's columns lands on the text; a programmatic move inside a marker or to the line's start is
put on the item's text, and a selection end inside it on an edge; Shift+Left extends over the whole marker; a tap on the dot
or left of it lands on the item's text, right of it in the text; the "- " typed at a line's start leaves the caret on the
text, and spaces put in front of a marker by the page make a nested item with the caret on its text. Backspace at an item's
start takes the marker and indent and leaves the text (`- abc`, `  - abc`, `1. a`, an empty last item, a nested star, the only
empty item), the line then has no dot, no padding and its text at the left edge, Backspace elsewhere is the ordinary one, the
next one after leaving deletes a character, a selection with markers in it is deleted whole. An IME composition in an item:
the marker stays drawn while it composes, commits after the marker, the composition events are as typed, an Enter key with
`keyCode` 229 sends and adds nothing, a Backspace with `keyCode` 229 at the item's start does not leave the list, and a
numbered list typed with composed text sends as typed. A paste of an image in a list item is a chip and the document is as it
was; a text paste with an HTML flavour is the plain text in one undo step; a file dropped on the editor is a chip and never text
(CodeMirror's own drop would read it as text); after a send Ctrl+Z does not bring the message back and Ctrl+Y redoes typing; a
list draft is stored as plain markdown and comes back drawn after a reload. The look at 320, 390 and 1280 px in both colour
schemes: no sideways scroll, the row and the send button inside the screen, 22 px lines, past 40vh the editor scrolls instead of
growing, text and marker contrast at least 4.5 against the row, and the colours are the app's variables of the scheme; the
empty box is the send button's 30 px and grows two lines at 22 px each.

Added for Sat Oct 24th 2026: the bullet was too small and the cursor could move in front of it; `- ` still becomes a bullet and both are fixed: four tests. The bullet is a disc the theme draws, measured from a DevTools screenshot of the marker box and of the item's own letters (`xxxx`), in the dark and the light scheme, on an item and a nested one: at least 0.45 and at most 0.8 of the font size across and as high, round (width and height within 2 px), at least 1.5 times the ink of the `•` glyph it replaced (measured in the text's font on a canvas), its middle within 2 px of the middle of the letters' ink, the marker box still 1.5em wide with the text clear of it, the `•` still in the DOM and unpainted (`-webkit-text-fill-color`), the document and the nested disc's place unchanged. The caret rests at the item's text and never before the marker or in it: put at every offset from the line's start to the text's start, for `- `, `* `, an indent of one and two levels, `1. `, `12. ` and an empty item, on the first line and on later ones with plain lines around; a programmatic selection (`selectOffsets`, a dispatched selection); the `- ` typed at a line's start; Home from the text, from mid-text, on a later line and twice in a row; ArrowLeft stops at the text on the first line and goes on to the end of the line above elsewhere (two keys, then one character back), on indented and numbered items too; ArrowRight from the end of the line above; ArrowDown and ArrowUp onto a list line from several columns; Ctrl+Left, Ctrl+Up and Ctrl+Down; a tap left of, on and right of the dot, on a later line and on a nested item; a range from the line's start survives (Select All, Shift+Left over the marker, Right collapsing it to the text). Backspace where the caret lands (a caret put at the line's start) leaves the list, typing there goes into the text, and the text sent is `- item` with no glyph. An IME composition from a caret put at the line's start (`- `, a nested item, `1. `, in front of text) stays after the marker with the marker drawn at every step and commits after it. Not checked: a physical phone (an on-screen keyboard's Enter, Backspace, image chip and IME composition through CodeMirror without EditContext), Firefox and Safari, the font.

Changed with it, because the editable's DOM is CodeMirror's now and no longer a text node: `test_composer_editable.py`,
`test_composer_touch.py`, `test_composer_lists.py`, `test_back_button.py` and `test_composer_fit.py` read the text through
`getText()` and the placeholder as CodeMirror's `.cm-placeholder` (not a `.blank` class and `::before`); the hand-made editable's
DOM-shape checks (how the browser's `<div>` and `<br>` read as lines, the `html` of the box) are gone with the walk they held; a
caret inside a marker is not a state any more (the Tab cases keep the caret before the marker, the Enter case at the marker's
edges); Ctrl+Left by words is the editor's; an `<img>` lift is checked with CodeMirror's own `cm-widgetBuffer` images left alone;
`#input` is a `contenteditable="true"` with `-webkit-user-modify: read-write` (CodeMirror's plaintext-only is overridden) and
`break-spaces` wrapping.

### `web/tests/test_back_button.py`: 13 → 26 (Thu Oct 22nd 2026; one check parametrized twice)

What Back does in sala (`web/README.md`, *Back*), rewritten after a trial of the first build on a phone: the
sessions and the Overview are peer views with no history between them, Back closes the open layer (the sidebar drawer, a
sheet) and otherwise leaves sala, the sidebar-open view must not exit the app, sala opens on the last view, a desktop
browser steps through the sessions visited, and unsent text stays with its session. The rule's first loss applies: a
Back that leaves sala from a session, walks between views or closes nothing drops the owner out of the conversation they were in (the installed app exits) or leaves them in a drawer or a sheet they cannot put away one-handed; the composer's text
reaching the wrong session is the same loss in another form. Every check holds one of the rules against the browser's
real history, driven in a headless Chromium with real taps (DevTools `Input` events, so the pushes have the user
activation a finger gives), `history.back()` and `forward()`, `Page.getNavigationHistory` for the entries and the
position, `Page.reload`, and a sentinel page navigated before sala so that leaving it is asserted. Phone, 390 px
(replace mode): A → B → C → Overview → A through the drawer and the Overview's table keeps one entry (its URL replaced
each time, the history length not growing for a navigation that opens no layer) and one Back leaves; Back from the
Overview leaves, and the drawer opened on the Overview closes on Back with the Overview staying; the drawer (its pushed
entry, the focus on its close button) closed by Back with the session still shown, by the scrim and by the close button
(the focus on the button that opened it), a row tapped in it replacing the one entry with no stale entry under it, the
open session's own row changing nothing, one Back leaving after any number of sessions; the items sheet closed by Back,
the scrim, Escape (the focus on the chip) and the close button, Forward re-opening it from its record; the sheet over the
drawer closing one per Back and a third leaving; a navigation with layers open going back under them first, the popped
entry left ahead as a Forward entry that re-opens its drawer over the view shown (the URL of the view, not the old one)
and drops a sheet that was another session's; a reload with the drawer or the sheet open leaving them (a same-document
traversal, the page the reload made) with no dead entry, Back leaving; a launch with no view opening the remembered
session with the sidebar closed, written into the launch entry (a reload keeps it, Back leaves), the Overview when
remembered, when nothing is remembered and when the remembered session is gone, a deep link winning over it; every view
written to the remembered one; a dead session link saying so with a link to the Overview that replaces it; a hash set
from outside and a link in the page (the first the browser's push, recorded; the second a replace); widening past the
drawer popping its entry, the mode read at the next decision (a row pushes at 1280 px, replaces again at 390) with the
entries already made staying; Chat/Terminal and the ⋯ menu adding no entry and changing no record; the keyboard going up
(height 450, a field blurred, a resize) and down closing no layer; Escape closing one layer per press and the focus
going back to the button that opened the drawer; no `beforeunload` listener on the window (DevTools'
`getEventListeners`) nor in the script; two `history.back()` in a row closing two layers and a third leaving; an entry
of the first build (`depth`, `base`, `overlays`) read as no layers and the next entry written in the new shape.
Installed app (`display-mode: standalone` emulated in the page, as DevTools has no such media feature) at 1280 px:
replace mode on a wide screen, the sheet a layer and the sidebar no drawer, the last view reopened on a launch with no
view. Desktop browser, 1280 px (push mode): Overview → A → B → C pushing four entries, the same session again adding
none, Back walking C → B → A → Overview and Forward, the Overview pushed from a session, the items popover and the New
session popover each a layer, the Get Help link pushed; a phone in landscape (844 px) pushing as a browser does. Links:
modified clicks (Ctrl, Meta, Shift, Alt) and the sheet's stackshot rows left to the browser (not prevented), a plain
click taken; the sheet's rows and the Overview link from a deep link at 390 and 1280 px (one entry becoming the Overview
on a phone, a view pushed in a browser). The composer's text: typed in A it is stored 400 ms later (`localStorage`),
kept when switching to B, where the box is empty (it was not before: the text would have been sent to B) and B's own
text is kept apart, back in A on return, kept across the Overview round trip and across a reload with the tab's
`sessionStorage` cleared, removed when sent (the send payload checked) and not coming back, B's untouched; emptied by
hand it is removed, a draft the first build kept in `sessionStorage` carried over once, 20,000 characters at most. Not
checked: a real phone or the installed app (a phone's Back is the same `history.back()` for a standalone app, and the
standalone mode is emulated by answering the page's own media query), Firefox and Safari (the same History API;
`popstate` on a fragment navigation is in the HTML standard), the browser's Back-button rule that skips entries pushed
without a tap (the tests drive `history.back()`, which does not skip them; every push in the page comes from a tap, and
the tests' taps are user activations), a keyboard on a real phone (the viewport is resized, no keyboard is shown), the
production service. Changed with it: `test_composer_editable.py`, `test_composer_lists.py` and `test_reload_menu.py` read
the draft from `localStorage` (saved after the last keystroke and kept until sent, no longer stored only as the page goes
and taken once), `test_new_session.py::test_back_closes_the_sheet_and_stays` (since replaced) and its last check read `layers` for
`overlays`, `test_board_items_ui.py` opens the drawer by its button (a phone no longer lands on it) and
`test_name.py` takes its no-hash title from a wide window (a phone opens on the Overview).

### `web/tests/test_quota.py`: 9 → 25 (Thu Oct 15th 2026)

The Overview's lane cards: each account lane's usage limits from Anthropic's usage endpoint (`web/README.md`, *Overview*
and the API table). Neither of the rule's losses applies to a read-only card; the checks kept guard two things. The
sign-in token: read from the lane's file, sent as the bearer, never in an answer, a state file or an error. And what the
page does when Anthropic refuses: a lane card read "usage endpoint answered HTTP 429" in red while the page itself kept
the refusal going by asking again every 55 s, so a check that hammers upstream, or a card that cries wolf over numbers it
still has, is what these guard. Server (the usage endpoint a fake; no real credentials file is read): the labels,
percents and plan; one upstream ask per lane per 5 minutes however often asked; an expired token is not sent, nor a
missing or unreadable sign-in, and such a failure (kind `sign_in`) is looked at again at the next poll with no wait
saved; a 401 keeps the last answer; an unexpected error carries only its type and backs off; the request's URL and
headers, and a 500's error with no token in it; answers kept on disk and served at once after a restart, refreshed when
due. The backoff: a 429 carries its `Retry-After` (a count of seconds; an HTTP date as seconds from now; none or
unreadable as none; a date gone by as a negative, which the clamp makes a minute); with one the lane waits exactly that
long, polled often, and sends nothing meanwhile (the fake's call counter), clamped to a minute and to 3 hours; without
one 2, 4, 8, 16, 30, 30, 30 minutes, each wait checked 2 s before its end (nothing sent) and at it (one ask); a success
clears the error, the kind and the next try and starts the series over; another status and no network back off from a
minute (1, 2, 4, 8, 16, 30, 30) as kind `failed` with the last numbers kept; the two lanes on their own (lane A refused, lane B fine: lane B refreshes on its TTL while lane A waits, and lane A's wait grows alone); the wait saved in the lane's file next
to the figures (`nextTry`, `errorKind`; never the error text, the flags or the token; 0600), a restart with the wait
still ahead sending nothing and saying the kind and the next try, one with the wait over refreshing at once and
dropping it; a refusal before any answer kept across a restart the same way; end to end through `fetch_usage` (only `urlopen` faked): a 429 with `Retry-After: 2400` asks nothing more through 2399 s of the page's 55 s polling and one more ask at 2401 s, then a `URLError` keeps the last good numbers with kind `failed` and a backed-off next try. Card (headless Chromium, both kinds): with
saved numbers the line is `.q-err.q-soft`, in the colour the `--muted` token computes to and not the `--error` token's,
opaque, AA contrast (4.5:1) on the card in the dark and the light theme, the three rows still drawn, no second "as of"
in the head, the numbers' time and the next try in it (as the page's own Intl writes them in the `SALA_TZ` zone), no "endpoint",
"HTTP" or status in it and the server's words on hover only; with nothing saved the line is red (`--error`), with the
next try and no rows; a good answer has no line on either lane card. Not checked: a real 429 from Anthropic (the
`Retry-After` shapes are RFC 9110's), the production service, a real phone.

### `web/tests/test_sent_images.py`: new, 15 (Thu Oct 22nd 2026)

The images a session sends to the owner with `SendUserFile`, shown inline in the chat (`web/README.md`, *What it can and
cannot do*, "Images a session sends"). Neither of the rule's losses applies to how a reply is drawn; what these checks
keep guards the one new way a browser can make this machine read a file: `/api/file-image` serves a file from disk on
the strength of a transcript line, so a path outside the home directory, a hidden or secret-named one, a file that is
not an image or one too large must never reach the page. The line shapes come from a fixture in the CLI's shape (`web/tests/fixtures/send-user-file.jsonl`: a `SendUserFile` call with a png, a docx and a jpg and its result line). Parser: one `file_image` block for each image among the files
(the docx none; the URL's `k` counts every file), the caption once, on the first image; no path anywhere in the block;
the result line stays an ordinary tool result; only an assistant's `SendUserFile` call makes a block (not a `Read`, not
a `files` that is no list, objects with a `path` read, numbers and nulls dropped); `find_sent_file` finds the k-th file
of the block at i of the line with that uuid and nothing for a tool result, a missing block or file, an unknown uuid.
Reader: the four types served by their first bytes (an upper-case extension too); a script, an svg, a text file under an
image's name, an image under a `.txt` or `.svg` name, a pdf and an empty file refused; a path outside the roots, one that
climbs out with `..`, hidden directories and files under a root (`.ssh`, `.config`, `.claude`, `.local/state`), names
that say secret (token, credentials, secrets, password, id_rsa), the root itself and a NUL in the path refused, an
ordinary path served as the control; a link out of the roots, one into a hidden directory under the root and one to a
directory outside refused, one that stays inside served; a relative path read against the line's working directory
(none given: refused; one that climbs out: refused) and `~` against `$HOME`; the size cap at exactly its edge; the default roots (home and `/tmp/claude-<uid>`) and the environment setting that overrides them. Route (the app through a test client): type,
`nosniff`, the sandboxing policy and private caching; the docx, a file number past the call's, a block that is not
there, a tool result, an unknown uuid and no transcript, a non-number and a negative index (never Python's last file),
and a file that has gone, all 404; a transcript that names a file outside the roots, a hidden one, `/etc/passwd.png` or a
`..` path gets no image. Page (headless Chromium at 390 px, dark): the image is in the reply with the tool folds hidden
(the default), `loading="lazy"`, decoded at its natural width, no wider than the screen, no sideways scroll, a link to
the full image in a new tab with `noopener`, the caption under it; an image that does not decode shows "Image not
available: detail.jpg" in place of a broken icon, and so does a file that does not exist. Mutation checked once: with
the hidden and secret test off, three of these fail. Not checked: a real phone (the width is emulated), the tap
opening a new tab, the production service, an image over a slow network (lazy loading is the browser's), and what a live Claude Code does when `SendUserFile` refuses a path.

### `web/tests/test_bang_pending.py`: new, 7 (Wed Oct 21st 2026)

A `!` shell command typed in the chat box ran once, but its bubble stayed at the bottom marked "Queued: not in the
transcript yet" with the same text. Claude Code records a `!` input as a `<bash-input>` entry, which the server turns into
a command block, never a text block, so the pending bubble (matched against text blocks only) never merged and turned
"queued" after 60 s. What the checks keep guards a shell command run twice: the parser's block for a `<bash-input>` record (a plain user record, with the output in a separate `<bash-stdout>` record); the pending bubble merging with that
block, whitespace-normalised; another command, an entry older than the send and a slash command not merging; the bubble
never turning "queued", its note saying it is not sent twice, and no Retry on it (a failed send keeps Edit only); an
ordinary message still merging, still turning "queued" and a failed one keeping Retry; the "first new prompt" fallback
not taking a `!` bubble. Four of the seven fail on the page without the fix. The page parts run in a headless Chromium
(skipped without one) with the send stubbed and the 60 s timer fired by hand. Not checked: a real Claude Code pane
running a `!` command, a real browser, the production service.

### `web/tests/test_bang_pane.py`: new, 21; `web/tests/test_bang_live.py`: 20 became 26 (a live-pane check on Claude Code 2.1.312)

A first version showed a running `!` command in the chat and offered Stop, gated on a `<bash-input>` transcript record and on a pane
with no input box. On 2.1.312 neither holds (no `bash-` line until the command ends; the input box stays, with the output,
`+14 lines (18s)`, `(ctrl+b ctrl+b (twice) to run in background)` and a footer `esc to interrupt`), so the chat never showed
the block and Stop answered 409. `tmuxio.bang_pane` now decides from the capture. What the checks keep: a running command found
with its command from the `! ` echo and its text from the output lines (no rules, box, footer, hint or elapsed-time line: `+N lines (Ns)`, a bare `(Ns)` after short output, `Running… (Ns)` for a quiet command, h/m parts included; a quiet command with only that timer still counts; the same
text when the counter ticks; the same under colour codes; either marker alone is enough; a pane with no input box read the
same; the last 40 lines, each cut); and none of these taken for a running one: a finished command, one stopped with Escape
(the command back in a shell-mode box), a model turn that shows `esc to interrupt`, a model's own Bash call with the same
`ctrl+b ctrl+b` hint and an older `! ` echo higher up (the guard: the nearest turn above the box must be the echo; without it
this fails), a thinking spinner after a finished command, a screen whose echo scrolled off. In the stream and at Stop, on a
private tmux server with fake panes showing these screens and a transcript with no `!` record: the block shown, unchanged text
not resent, changed text resent, cleared when the prompt is back, shown again on a reconnect, found when started while the page is
open, never shown for a model turn or a model's Bash call, an idle pane looked at every 2 s and not every 0.75 s; Stop sends
Escape alone or Escape then Ctrl-C, and answers 409 with nothing sent for a finished command, a model turn and a model's Bash
call. The older transcript-record tests stay as the fallback's. Not checked: a real Claude Code pane (the fixtures are rebuilt from a described capture, not a verbatim file; the exact indentation of the echo and the output, and whether a
command shorter than 2 s shows either marker, are unverified), a command whose echo scrolls off a long screen (not found, by
design), and the production service.

### `web/tests/test_bang_output.py`: new, 8; `web/tests/test_transcript.py`: 7 added; `test_bang_pending.py`: one line changed

The output of a finished `!` command was a closed "command output" fold, one tap from what the owner had just asked for. It is now
its own block kind (`bang_output`) and shows open under its `! <cmd>` line. What the checks keep: the parser (a record with both tags, stderr alone, stdout then stderr with no tag left in the text, no output at all, a clip at `TEXT_LIMIT` that says so;
a slash command's `<local-command-stdout>`, a task notification and another wrapper staying folded notices; the command line
still a command block; stdout that holds the closing tag as text not cut short and the stderr read once; an unmatched opening
tag showing its text, not "(no output)"). Keyboard: the text a tab stop, and focus landing on the Fold button when "Show all" goes. On the page, at 1280 and 390 px: the box open and not in a `<details>`, headed "Output · N lines", a real
Fold button with `aria-expanded` and `aria-controls`, the box right after its command line, the first 12 of 30 lines with links
still links and "Show all 30 lines", "(no output)" for an empty one, nothing wider than the chat; Show all opening the rest in
place; Fold closing and opening one box and leaving the others; the slash command's output still a closed fold; the truncation
note kept; the live block of a running command removed in the same call that draws the box, the box right under the command
line, and the stream's later "not running" changing nothing. Headless Chromium parts skipped without one. Not checked: a real
Claude Code `!` command end to end (the records are rebuilt from the shape in test_bang_pending.py), a screen reader, the production
service.

### `web/tests/test_list_render.py`: new, 6 (Thu Oct 22nd 2026)

A numbered list drew with uneven indents: item 6 and items 11 to 13 flush left as lines, items 7 to 10 indented as a list.
Cause (found with the vendored marked 12.0.2 in node): CommonMark lets a list interrupt a paragraph only at "1.", so a run
starting at 6 or 11 right under a prose line stays paragraph text. `mdPrep` (shared.js) now puts a blank line before such an
item. What the checks keep guards a reply that is mangled the other way: a list or a number rewritten that was fine. Kept:
the cause as a canary (marked alone still makes the paragraph, so a marked that fixes it makes `mdPrep` redundant and this
says so); a run under prose, under a bold line, with ")" marks, and the failing shape (6 to 10 one list, 11 to 13 another) becoming lists with the right `start`; and, unchanged to the byte, a list at 1, a loose list, sub-bullets, a lazy
line inside an item, a line after a bullet (still joined to it, the CommonMark continuation; the choice is recorded in the
test), an item below a list item or an indented line, items inside a backtick or tilde fence and the line after a fence,
dates at a line's start ("2026. 10. 16.", "16. 10. 2026."), a lone number with no neighbour, numbers mid-sentence, "7.5", a
missing space after the dot, and text with no numbered line. The page part renders the shape in a headless Chromium
(skipped without one): no number left in paragraph text, every `<ol>` indented alike, a fence's numbers intact. Five of the
six fail on the old code. Not checked: a real phone, a reply longer than the headless page holds, non-ASCII text (the rule looks only at the line's start).

### `web/tests/test_single_tilde.py`: new, 5 (Mon Oct 26th 2026)

A reply that wrote "10~19% ... 20~46" in one paragraph showed everything between the two tildes struck out. Cause: the
vendored marked 12.0.2 takes a single "~" for GFM strikethrough too. `noSingleTildeStrike` (shared.js, called once by app.js, the
only place marked is called) overrides marked's `del` tokenizer: a span starting with "~~" is left to marked's own rule, any other
"~" is text. What the checks keep guards a reply that is mangled the other way: a real strike lost, or a tilde in code changed.
Kept: the cause as a canary (marked alone still strikes between two lone tildes; a marked that stops doing so makes the override
redundant and this says so); "10~19% and 20~46" rendering with no `<del>` and both tildes in the text, with "~5 minutes",
"~/path", "a ~ b ~ c", "~a~" and an unclosed "~~" also unstruck; "~~x~~" still `<del>x</del>`, and the same html as marked alone
in a list, a table cell, bold and with bold inside; a "~" inside an inline code span, a backtick fence and a tilde fence
untouched. The page part renders the same reply in a headless Chromium (skipped without one). The page case and the first
assertions fail without the override. The service worker keeps no cache and the assets carry `?v=` from their mtime, so no
version bump is owed. Not checked: a real phone.

### `web/tests/test_new_session.py`: new, 45 (one shape check parametrized 23 ways, Thu Oct 15th 2026); 44 after the scope picker (Sat Oct 24th 2026)

Changed with the scope picker (where the text below describes the old project rows, the exit 3 block with its Copy
button or the New project entry, this note wins): the `sala` fixture also starts `FakeStackshot`
(`web/tests/fake_stackshot.py`) and points the app's token and address files at it, so no test reaches the real stackshot.
Rewritten: the project rows test is now *the scopes, the one box, the role and the suggested name* (scope chips, the
listed rows of the scope, the filter by key, name or title, Enter picking the first row); the exit 3 test now asserts the
queue's not-listed answer is said in words and the ADD-TO-PAGE block, its `<pre>` and the Copy button never appear; the exit 4
words; the second-submit text (*Working…*); the contrast test (a hidden project reached by a query, then the agent refusal,
every text in the new sheet); the markup test (`nsPost("api/spawn", ` and `fetch(url, { method: "POST"`, no ADD-TO-PAGE
and no `ns-copy`, the new ids present). Removed: the New project entry test (the folder and slug fields are gone; the
`+ New project` row and its checks are in `test_new_session_scope.py`) and the exit 3 block-and-Copy test (replaced by the
one above).

The New session form, the one way the page makes a session, through sala's operation queue (`web/README.md`, *New
session*). What a wrong answer costs is a session the owner did not ask for, or one they asked for that never comes: a spawn
sent with another project, role, name or mandate than the form showed; a mandate that reaches sala changed; typed text
that reaches a shell; a second spawn from a double tap; a refusal shown as markup; or the queue's own answer (the lines
to add to the page, the missing page) lost on the way to them. Every check guards one of those. Nothing runs sala or
touches tmux: `sala` is a stand-in script in tmp_path that records its argv and the mandate file's text and answers as
the queue does in the mode the test set; the project pages are files under a temporary pages checkout; api/sessions is
a stub whose list the test extends to make the new session "appear". Server (a TestClient): the options from the pages
(sorted, nested included; a README, a redirect or archive stub, a file outside the page dirs and a name that is no key
left out; the lanes offered (never sdk); the efforts, the caps; a missing checkout named in `error`); the
suggested name from `sala spawn --suggest-name` and a bad key or role refused before sala; 23 bad bodies refused with
400 (a name with a capital, a dash at either end, a space, 49 characters, empty; a key without its dir, outside the
dirs, with a capital, a trailing slash, `..`; a role that is neither; a back agent without a mandate or with a blank
one; an effort, a lane (`sdk`, `api; id`) or a model (`opus; rm -rf /`) off the shape; a non-string; a field the form
does not have; a non-object) or 413 (a 20 KB + 1 mandate), none reaching sala and no mandate file left; a cross-origin
Origin, `null`, text/plain, GET, a 64 KB body and broken JSON refused as every POST is, the same origin accepted; the
argv as one list in its order with the mandate as a file path, the words last and of the agreed shape, a non-ASCII multi-line mandate with quotes, a leading dash, backticks, `$(id)`, `${HOME}` and a tab arriving in the file byte for
byte plus a final newline, 0600, under `state_dir/mandates/`, kept after a queued spawn, the empty folded options and
the empty front mandate not sent, CRLF as LF; exit 3 as `not-listed` with the exact block from the unindented marker
line to the end (the plan's indented copy not it) and sala's keeper line, exit 4 as `no-page`, exit 1 as `refused`
with the ✗ lines, exit 0 without a `queued op` line and a run past the timeout (the process stopped) and a missing
sala as 502, each leaving no mandate file; a second spawn while one runs 409 `busy` and never run; the marker read
(`arg=` lines gathered, `=` inside a value kept, `ops/done/` found, a bad id 400, none 404); the date stamp's ordinals
and the words; old mandate files pruned and other files left. Page (headless Chromium): the row above the Overview
(the markup, a button with the dialog attributes; the new-session section of app.js with no `innerHTML` and no keydown
handler on the mandate; the README's line changed); at 390 px a tap opens a bottom sheet across the viewport with the
focus on its close button, Escape closes it with the focus back on the row, at 320 and 390 px no sideways scroll with
it open, the scrim closes it, at 1280 px a popover under the row and left-aligned with it inside the viewport with the
focus in the filter, the row's second tap closing it; the sheet an entry of the tab's history as the items sheet is
(`test_back_button.py`'s rules): on a phone Back closes it and leaves the drawer open, one more Back closes the drawer,
closed by its own button its entry goes with it, on a desktop one Back closes it, the record listing `drawer` and
`new` in order; the project rows sorted with key and title at 40 px, the lanes with their configured labels, the filter by key or title (case-insensitive), Enter in the filter picking the first page and
submitting nothing, the empty-match line, back asking sala's other name and requiring a mandate, a name the owner edited
kept through a role change and replaced by the suggestion on another project (the four suggest calls in order); the
name checked inline as the backend checks it (six bad shapes, one good) and a model with a shell character disabling
the button; an IME composition committing in the mandate, Enter a new line and Tab a focus move with no tab
character; a submit queuing the spawn (the record's argv and the mandate file's text as typed), *queued* with the op
id, the status kept through a close and reopen, *starting* once the marker says running, *ready* with the session's
link once the name is in the list, the link opening the session and closing the sheet; a stuck marker as *failed*
with its result line; exit 3 as the block in a `<pre>` byte for byte, the Copy button putting it on the clipboard and
saying *Copied*, the keeper sentence, no mandate file left and the form usable again; exit 4 saying who creates the
page and a refusal with `<script>` staying text (no script element); the New project entry showing the folder and the
slug, naming the page key, refusing a bad slug, keeping the button disabled and posting nothing, folding away when a
page is picked; a second submit while one runs (a click, two `requestSubmit`s) sending nothing; WCAG AA (4.5:1 on the
first opaque ground, translucent layers composited) for every text in the sheet with a result, an error and the
folded fields shown, in both themes, and no sideways scroll at 320, 390 and 1280 px. Not checked: a real `sala op
spawn` (never run from a test or by hand for this change: the stand-in answers in sala's shapes, read from lib/op.sh
and lib/spawn.sh), the real pages checkout and pages.py, a physical phone or a CJK IME (DevTools' composition only), the access proxy in front, the production service.

### `web/tests/test_new_session_projects.py`: new, 79 (Sat Oct 24th 2026); 84 after the all scope

Added with the *all* scope: `all` is accepted as the scope of the list query alone (trimmed and lowercased like the
others; the rows of every scope by key, each with its own `scope`, the hidden matches of every scope with a query; `scopes` stays work, home and lab even if stackshot sends `all` in it), and refused as the scope of `post project` and
`post project-list` (400, the error naming work, home and lab only, nothing reaching stackshot); `all;id`, `all,work` and
`ALL!` stay refused for the query (the old case that expected `all` refused now stands for these). Retired projects: with
`fake_stackshot.retired_rows()` (`status: archived` in any case, `retired: true`, one hidden, and one row with no mark) the
marked rows never reach the page, listed or hidden, and the unmarked one still does ("do not invent other filtering");
`clean_projects` keeps rows with another status, `retired: false`, a `null` status or a string "true". Not checked: that stackshot ever sends such a mark.

The server half of the scope picker (`web/src/sala_web/projpick.py` and its routes; `web/README.md`, *New session* and the
API table). What a wrong answer costs is a project, a page or an agent the owner did not ask for, a stackshot call under
another label than `sala-web`, a token or the stackshot address shown to the page, or a page left waiting for an answer that a proxy cut at its request timeout. Every call goes to `web/tests/fake_stackshot.py`, a real HTTP server on 127.0.0.1 that
answers in stackshot's shapes (client.py, server.py) and refuses a `project-agent` that no project or list call of label
`sala-web` has marked; nothing reaches the live stackshot, a page store or a session. List proxy: the scope's rows reduced to
the fields the form uses, a query passed on, a bad scope (a capital, a path, `all` joined to anything) or a query off the shape refused
before stackshot, a stackshot 4xx, 5xx, a bad JSON body or no server answered as 502 in words with no token or address in
it. Token: the file read each call, a missing or empty token file said as such, a bearer header the fake checks, no token in
any response, log line or record. New project: 202 with a job id, the job polled to done with the page's key, a second
start while one runs 409, the stackshot refusals (409 exists, 502 page store, 400, unreachable) kept on the job with their
words, the job kept an hour and 20 at most. Bodies: the unknown field (a `sender` from the page among them) refused, a key
or ref off the shape, a title with a control character refused and one with line breaks collapsed to spaces, a scope outside work, home and lab, a non-object. List again and project-agent: the label always `sala-web`, `front` and `role`
passed on, the mandate one line of at most 600 characters, `pageOwed` and `pageYaml` returned, stackshot's 403 (the name
proves nothing) answered as `not-allowed`. The POST guards (a cross-origin Origin, text/plain, a body over 16 KB) as for
every POST. After a stackshot change: the owed `page_yaml` is entries only, with no `agents:`
header, when the page has an agents map already (the fake answers so; passed on as it is, the note says which); a 409
"being made" answers as `in-progress` (a wait), not `exists`; a mandate with a control character is refused here with 400
before stackshot. Not checked: the live stackshot and page store.

### `web/tests/test_new_session_scope.py`: new, 13 (Sat Oct 24th 2026); 21 after the all chip and names only

Added (headless Chromium, `FakeStackshot`): the fourth chip *all* is last and lists every scope's projects in stackshot's
order, with no `+ New project` row; typing filters them by key, name or title and brings the hidden matches of every scope
below the divider (a note page disabled, not pickable); under *all* a quiet line "pick a scope to make a new project" shows
only when the typed text matches nothing (hidden matches count as matches), Enter with nothing shown picks and makes
nothing, and a concrete scope offers `+ New project` again; a hidden project picked under *all* is listed again with its
own scope (`work`, never `all`) and its agent name takes that scope; the last used scope may be *all* (the page loaded
afresh from `about:blank`, since a navigation to the same address does not reload it) and the default is unchanged (the open
session's scope, a remembered scope that is no chip ignored). Names only: rows and the `+ New project` row show
the sidebar's name (`sessions.project_title`: no `projects/` or `infra/`, no scope prefix; asserted equal to it for every
row, and the visible text of the box and of the line under it never holds a folder); the title is shown beside the name and
left out when it only repeats it; the box still finds a project by its key; under *all* the scope word stands beside a name
only where two known projects share it (a listed and a hidden twin included), not under a single scope. The widths test also
covers *all* with a long name and a twin at 320, 390 and 1280 px (every chip and tag inside the sheet, no sideways scroll).
`test_new_session.py` follows (the chip list and the row text). Not checked: a real phone, the real stackshot's `scope=all`
answer (the fake follows its documented shape).

The page half (headless Chromium, `FakeStackshot` behind the app). The scope switch and the listed rows of each scope;
typing filtering by key, name or title; with a query the hidden matches below the divider *existing pages, not listed*,
a `type: note` row disabled; `+ New project "<typed>"` always last, inert while the box is empty and gone when the key
exists; the name rule for a new project (`<scope>-<slug>-main`, `-helper`). Create: a new project made with the progress
list (*Make the project page*, *Add the agent*, *Start the session*) and the page waiting on the job without a second
send; a hidden project listed again, then agent, then spawn; a listed project whose agent is already listed skipping
`project-agent`; a listed project with no agent confirming it is listed; 409 *exists* (the page shows it under the
divider), 502 page store with a retry that resumes at the failed step, 403 for a name the project does not list (plain words),
a spawn that fails once because sala's record lags and succeeds on retry, stackshot down. The double-submit guard (two
`requestSubmit`s send one chain), phone (390 px bottom sheet) and desktop (1280 px popover) widths with no sideways
scroll, and a long refusal wrapped inside the sheet. Not checked: a proxy's request timeout (the job and the 2 s poll are the answer to it), a real phone, a CJK IME, a real `sala op spawn`.

`web/tests/fake_stackshot.py` is a test helper, not a test file.



### `web/tests/test_new_session_page.py`: new, 6 (the form as a page, Sat Oct 24th 2026)

The form is a full page, not a pop-up. It moved from a popover and a bottom
sheet to the page `#new` in the main area (`web/README.md`, *New session* and *Back*). What a wrong answer costs: a project
description cut short so two projects look alike before one is picked, an ordinary create that needs scrolling so Create or the
Open button is out of sight, a pop-up left behind in the code, a page that breaks the sidebar beside it. Headless Chromium,
`FakeStackshot` behind the app. A title of 120 characters is shown whole (computed `white-space`, `text-overflow`, no line clamp,
`scrollHeight <= clientHeight`, wrapped to more than one line inside its row) at 1280 and 390 px and under *all*; an ordinary
create (scope, project, name, Create, then the steps, *starting* and the Open button) at 1280 x 800 with 18 rows in the scope and
a long description, leave the form's and the document's `scrollHeight` within their `clientHeight` before Create, and Create, the
steps and the Open button inside the viewport at every stage after it (the foot is pinned to the bottom edge once the steps are
on the page, so the fields may scroll under it; a new project's two-line note makes them scroll a little before Create too), the
list scrolling inside its box; a phone has one column (the name under the
list) and the form scrolls, the document does not, with no sideways scroll; the sidebar stays usable (New session is marked, a
session row leaves the page, New session opens it again on `#new`); the source holds no `new-sheet`, `new-scrim`, `nsOpen`,
`nsClose` or `defineLayer("new")`, routes `#new` as a view and keeps `placePopover` for the items sheet. Changed with it, in
`test_new_session.py`: the markup test (a link to `#new`, the `new-pane` section, the form), the button test (now the page at
phone and desktop widths, the composer gone, no sideways scroll at 320) and the Back test (renamed
`test_back_returns_from_the_page_and_the_link_opens_it_again`: an entry in push and replace mode, Forward, a reload on `#new`
opens the page, a phone through the drawer, an old `"new"` layer record read as none); `test_new_session_scope.py` reads the form
and pane geometry; `test_back_button.py` (the page is an entry, no layer) and `test_sidebar_hover.py` (the sidebar goes as usual
while the page is up, the page stays). Not checked: a real phone's keyboard, a real stackshot.

### `web/tests/test_new_session_column.py`: new, 9 (one column and the project list's handle, Sat Oct 24th 2026)

The New session page on the board (`web/README.md`, *New session*) is one column with a scrolling project list: the two
columns of an earlier layout became one centered column about 760 px wide, the project list six rows tall with its own scroll, a drag handle
on its corner, and the height it is dragged to kept in the browser (`localStorage` `sala.ns.list-h`). What a wrong answer costs: two
columns back, with the name and Create far from the project picked; a column wider than a reading line or pinned to the left; a
list so tall that Create falls off the screen or so short that projects cannot be told apart; a missing or unreachable handle; a
stray stored value that makes a zero-height list, or a browser that refuses its storage taking the page down. Headless Chromium,
`FakeStackshot` behind the app, 18 rows in the scope. The scope chips' row, the filter box, the list, the role, the name, the
mandate, the folded details and Create share one left edge and width (a list at most 760 px, the same room each side of it in the
pane at 1280, and at 1920), in that order top to bottom; a phone's column fills the width with a gutter of 16 to 24 px and no
sideways scroll; the list is 250 px (six rows) at 1280 and at 390, scrolls inside itself with 16 rows or more so the last row
scrolls fully into its box, keeps its height when scrolled, and has the same height in a scope with few rows; the handle exists
(computed `resize: vertical`, `overflow-y: auto`, `min-height` 130 px) and a real press, move and release on the corner over
DevTools `Input` events makes the list taller, stores the height (within 2 px of the box), stops at three rows when pulled the
other way, and a click on a row stores nothing; the corner point is the list's own (not a row, not under the scrollbar) and the
hint beside the Project label shows on a desktop; a stored height is applied on load, eleven bad values (`abc`, empty, `-300`,
`12.5e2`, `50`, `129`, `0`, `NaN`, `Infinity`, a leading space, `400px`) leave the default, and 5000 is cut to the screen (800 - 120)
with Create still on it; with `Storage.prototype` and `window.localStorage` throwing on every call, the page opens, the list is the
default height, a drag, a pick, a scope chip and a typed name raise no error; an ordinary create at 1280 x 800 (an existing
project picked, a mandate typed) leaves the form, the document and Create inside the screen with no scroll at all; a phone scrolls
to Create, and its foot is not pinned (`position: static`). Not checked: a real phone's touch (a browser that has no resize
handle on touch keeps the six-row list), the handle's look in each browser (Chromium's own grip is checked by eye).

### `tests/lanefallback.sh`: new (Sat Oct 31st 2026)
The automatic lane fallback (README, *The lane fallback*). Fakes only: the compiled fake claude on
`sala-test-*` panes in a private tmux server (`tmux -L sala-lanefallback-<pid> -f /dev/null`, isolated HOME, locked and removed
on exit), `systemd-run` and `systemctl` stubs, Slack a file, a stub `claude auth status` for the sign-in watch. Covered: the
map (defaults, the sdk and awsplatform names, `none`, a configured map, a dormant or unready fallback gives rc 1 and a plain
reason, one hop each way); the plan (`lane fallback --dry-run` names the dead lane, the fallback, each session, a model change for a session whose model the fallback lacks, the master last, the default and the jobs, and changes no lane row, default, home or model, relaunches
nothing and queues nothing; a lane that is not dormant is refused); the triggers (a lane's refused usage answer through `watch
--signin` and `lane dormant` by hand each queue ONE operation from sala-watch with the fallback's standing words as the words;
`--no-fallback` and `SALA_LANE_FALLBACK_AUTO=off` queue none; with no usable fallback nothing is queued and the one post carries
"not moved automatically: …"); the move end to end through the queue (rows, relaunches by `proc_lane`, that session on opus with its home model kept, the default and its home, the master through the rescue, a session of another lane untouched, ONE
Slack post naming the lane, the fallback, each session and "model-x → opus", no inbox line to sala-watch); stay (`lane active`
moves nothing, the HOME column and the way back, `lane <home> <session>` and `lane default <home>` clear the home rows, moving
back restores no model); jobs (`lane exec` on a dormant lane runs on bedrock with one stderr line; none when the switch is off;
the "no usable fallback" line); a queued move whose fallback went dormant meanwhile ends stuck (exit 4) with no `claude -p`
helper; queue-time refusals (no usable fallback, unknown lane, extra words). Not covered: a real Bedrock launch, a real
`systemd-run` unit, a real Slack post, the live `claude auth status` of a lane with no subscription.

### `tests/lanedormant.sh` and `web/tests/test_lane_dormant.py`: new (Thu Oct 22nd 2026)
The dormant record (README, *The dormant record*). `lanedormant.sh` (about 100 checks, ~45 s): the record (absent is active, one
row per lane, set once with the first reason and since standing, sdk read as api, a lane id from the table needs nothing, the
day (in the `SALA_TZ` zone) with its ordinal, no temp file, concurrent writers lose nothing, one `lanes.log` line per change); the verbs by hand
(`lane dormant --reason`, `lane active`, `--dry-run` writing nothing byte for byte, the table's dormant line and the note on a
session still on it, the usage line); the refusals (`lane <lane> <session>`, `--all`, `default`, `--rescue`, `spawn --lane`, a
dormant default; spawn's list leaves the lane out; `lane_out` and `lanes_working`); the signals (a login lane signed in without a subscription, signed out, a saved `refused` usage answer — an older one and a 429 are no signal; a login lane signed in on a lower plan than it expects; the `limit-billing.jsonl` fixture on api and sdk panes, since = the stop's first error, an old stop not a signal after `lane active
api`); one post per episode (plain words, the count, "moving them is your call", none while no session is on the
lane, a new episode posts again); the daily look (not before a day, a login lane back by itself with a log line, still wrong stays
dormant, a hand-set lane held, the API lane never back without `lane active api`, no key file or network involved). The web file
(13, headless Chromium for the four page checks): the record read (sdk as api, odd lines skipped), a dormant lane's quota entry
with the plan from the sign-in file (none when it is unreadable), nothing asked and nothing cached, asked again when active, the API card without an Admin API call, a 403 saved as
`errorKind: refused` with the back-off, the form's lanes and a 400 for a dormant one, and the Overview card at 390 px
(the pill as an active card has it (the plan name is the details page's), a "dormant" chip in the head and "No seat since Mon Jan 5th" under it, no bars, an active lane a full card; the
API card with its two pills, no Billing link). The status chip on each card (Fri Oct 23rd 2026; a pill in the lane label's style, lower case): active
green, dormant filled grey, not configured an outline (a lane with no sign-in file, an API lane with no Admin API key), an
expired sign-in still active, the chip left of `Details ›` and the pair kept together at 320 px, the line under a dormant head
the reason as a sentence and the day ("Usage check refused since Tue Jan 6th", "No credit on the API key since …"), and the
server's two "not configured" words held to the page's list. Not checked: the live sign-in output without a subscription, the usage endpoint's status for it, a real Slack post, how the chip looks (no one has seen it in a browser).

### `tests/pset-target.sh`: new, 28 (`SALA_PSET_TARGET`, Fri Oct 16th 2026)

A provision set's session/owner items go to the master; with no master configured (`SALA_MASTER` unset) a
configured `SALA_PSET_TARGET`, a front agent, takes the same text with `[for the user]` on its first line. Two fake claudes
in a private tmux server (what reaches each one's socket is read from `FAKE_SOCK_LOG`), Slack stubbed to a file. Kept:
target live + no master → exactly one message, `[for the user]` first, the master's text and the exact settle command after
it, no Slack post, the items told, never sent twice; the target not live + no master → the Slack post as before and the
items told; target unset + no master → the Slack post, nothing delivered (the regression that the knob changes nothing
unset); a live master → only the master hears, without the `[for the user]` line; a master configured but not live → the item stays
pending with the failure recorded, no post, with the target unset, live or not live alike (the target is never told: a master
briefly down mid-recycle keeps its items). Run against the old `lib/common.sh` 9 checks fail.
Not checked: a target whose pane is live but whose socket refuses the push (exit 4; same branch as not live), the real
`watch` tick that calls `pset_followup`.

### `tests/instantalert.sh`: new, 32 (Thu Oct 22nd 2026)

The instant alert (`lib/hook.sh` `hook notify`, `lib/stuck.sh` `sq_instant`). The stuck watch posts a question only once it has
been up for 90 s (the timer's second tick), so a pane stopped on a permission dialog or AskUserQuestion's menu sits for up to
three minutes before the owner hears of it. Claude Code's Notification hook (`permission_prompt`, raised about 6 s after a dialog
shows with no keystroke; payload checked on a live CLI, 2.1.307) now posts at once. The checks guard what would make that a
second, noisier post instead of an earlier one: the alert goes out with a confirm window of 1000 s set (it must not wait for
it), through the watch's own post path and in the watch's own wording (session, the question read off the pane, the link),
and writes the watch's keys (`hash`, `since`, `posted`, `tries`) so that the watch's tick after it, and the same notification
twice, post nothing; the watch posting first leaves the hook silent; another question is another alert. The types and switches:
`idle_prompt` and an unlisted type, a hook with no `TMUX_PANE` (a `claude -p`, a unit), `SALA_STUCK_INSTANT=off`/`0` and
`SALA_STUCK_POST=off` do nothing; a payload with no type but the permission words is alerted; `SALA_STUCK_INSTANT_TYPES` widens
the list. A screen the watch's reading does not know (an elicitation form) is alerted on the notification's own words, once. A
notify command that fails leaves the question to the watch's retry (posted empty, tries 1, hash kept) and the watch's next tick
posts it. `--dry-run` prints the post and writes, logs and posts nothing; garbage on stdin, an empty payload and a read-only
state directory all exit 0 (a hook must never fail a turn). No token or key value in any post, log, state or attempted post; plain words only. The layout of a fresh pane (the dialog in the upper half, blank rows under it) and AskUserQuestion's blank
row between its question and options are not drawn by the fake claude, so the two `lib/stuck.sh` fixes for them were checked once by hand against a live CLI in a private tmux server. Not checked: the real Notification delivery (the same hand check),
the post to Slack itself (a file stands in).

### `tests/parkedq.sh`: new, 52 (Thu Oct 22nd 2026)

The parked background question (`lib/question.sh`, `lib/question.py`, `lib/permission-host.py`, `hook ask`). A background
`claude -p` run is offered AskUserQuestion only with a permission host, and asked a question it can only hang or guess; the
flow parks it (PreToolUse `defer`: the turn ends with `stop_reason: tool_deferred`, the call stays in the transcript), files the
question and resumes with the owner's answer. The fake claude (`tests/fake-claude-p.py`) behaves as 2.1.307 does in that corner
(it runs the `--settings` hooks with the payload Claude Code sends, defers, resumes by the same `tool_use_id`); the same flow was run once against a live CLI on haiku by hand (park, no answer, wrong answer, `--answer 2`). The checks guard that nothing
is granted unless the answer arrives: the hook is inert without `SALA_DEFER_QUESTIONS=1` (an interactive pane is untouched) or
for a tool not listed; a call is deferred, recorded once in a private record (0700/0600) and filed once, and the hook firing
again for the same call defers again, never files again and never allows; a resume with no answer exits 3 and does not start
claude; an answer that is not an option (or a number past them) exits 4 with the options and leaves the call parked; `--dry-run`
validates and runs nothing. `question run` starts the run with the permission host (`mcp__salahost__approve`, the config naming
`permission-host.py`), the inline hook settings (matcher `AskUserQuestion`, command `… hook ask`), the env and the prompt; the
resume is `--resume <session id>` in the run's folder with no prompt and the run's permission mode passed again. Answers by
label (any case, a leading `Answer:`), by number, by header for two questions, comma-separated for a multi-select, `--free-text`
and `--decline`; the answer seam (empty = still parked, the question id and item in its environment), the sweep (resumes the one
with an answer, leaves the other), a second question after the answer parking again (exit 10, a new id), a finished question
refused. A tool added to `SALA_DEFER_TOOLS` (Bash) parks every call: yes allows that call as asked, no denies with the owner's words,
maybe is refused. The filing seam: the first word of its first stdout line kept as the item, the text on its stdin with the key
masked, the id, label and answer command in its environment, no post beside it; a failing seam leaves the run parked and the
failure logged, and the sweep files it again. The permission host answers `initialize`, `tools/list` and a call with
`behavior: deny`. No token or key value in any post or log, plain words only. Not checked: a live CLI beyond the by-hand run above,
a deferral ignored because the turn made several tool calls (documented, not reproduced), the real board seams (`tests/boardseam.sh` fills them with a fake client).

### `tests/boardseam.sh`: new, 61 (the board seams and the sweep, Thu Oct 22nd 2026)

The parked question's two seams filled with stackshot's shell verbs (`contrib/question-board.py` with `question-board-file.sh` and
`-answer.sh`; `lib/question.sh` `qs_seam`). The client is `tests/fake-stackshot-client.py`, which refuses what the real `post
question` and server refuse (over 5 lines or 8,000 characters, an ask over 240 characters or with `;` / ` · ` in the Decide part,
options not 2 to 6 or not exactly one recommended, a label over 40 characters), so a script that would be refused by the board is
refused here. The checks guard that a parked question reaches the owner and that only the owner's decision resumes it: the default wiring
(no client → the post path, as before; a client at `SALA_STACKSHOT_CLIENT`, at the default checkout path, or named in the config
file as a plain assignment → the board scripts; an explicit seam wins; `off` disables); the filing call (project and its override,
subject, request id = question id, sender = the label, the exact ask, one `--option` per option, the recommended one, the text on
stdin); a second filing reaching the client with the same request id and sender and getting the same item; the option mapping
(a `(Recommended)` label, a Bash call as Yes / No, two questions, a multi-select, a label with `=` or over 40 characters → no
buttons); the board's limits met by the script (a 9,000-character question cut with the pointer line, eight questions, `;` and
` · ` and `done:` in the question, the ask within 240 and the subject within 80); the answer seam (a decision by label and by the owner's words, two questions, a Bash yes; a comment, no answer, an empty one, a decision that is no option, free text, an unreachable
client and an item-less question all leave it parked, the reason logged); a client refusal (the run still parks, `filed` stays
empty, the sweep files it again to the same item); a key in a question masked before the client sees it. A question the board will not take is never left unannounced: the count of failed filings (the hook's try first), no post at the
first two, one at the third naming the reason, the question and the answer command, never a second while the sweep keeps trying, the
count cleared when the board comes back; `SALA_QUESTION_FILE_TRIES=1` and a timeout (exit 124) worded as no answer in time. The
sweep in the watch tick (`watch --questions` with stub `systemd-run` and `systemctl`): no questions directory or only finished ones
launch nothing and call no client; an open question with a decision launches `sala-auto-qsweep` once (RuntimeMaxSec) and the run
resumes; the next ticks inside the interval, a sweep still running and `SALA_QUESTION_SWEEP_EVERY=0` launch nothing; a launch
that cannot start does not fail the tick. Not checked: the real board
(no real item is filed and no real answer read), a decision click by the owner, the real `systemd-run` unit.

### `tests/laterlist.sh`: new, 28 (the later-relaunch list's limit, Thu Oct 22nd 2026)

A pane the recycle set aside (the deferred list) because background shells hold it is never relaunched while they run, and an endless wait loop (`until grep … sleep 3`) can keep it there for hours. `watch` tells such a pane again an hour after it was set aside and posts once at a limit. The checks guard that this never moves a pane
and never goes silent or noisy: a clock made of the row's own `since` and `told_at` fields (no test waits an hour); nothing told
or posted under an hour, the row's counters at zero and the pane not relaunched; told again at an hour (the waiting flag raised
and marked told, the recycle's line pushed to the idle session's socket, since a session held by shells runs no tool call for the
hook to speak through), not twice in one hour, a second and a third time an hour apart, never a fourth, and not early (30 min
after a tell); one post past `SALA_LATER_LIMIT` that names the pane, claude's version, sala's revision, how long and the command
the Stop hook's record lists (a `--token=` value in that command line masked), never a second one; the limit tunable from the
environment; the pane still there and on the list after the post (nothing relaunched, nothing given up); a row written before the
change (six fields, empty set id) read and rewritten with the set id's place kept as `-`; the shells ending: `watch` relaunches
the pane and the row and the waiting flag are gone with it. Not checked: the post's wording beyond its facts, a session that
really obeys the tell (the fake claude only logs the push), the real hook speaking through a tool call.

### `tests/bedrocklane.sh`: new, 67 (the bedrock lane's launch, Fri Oct 23rd 2026)

The bedrock lane (`lib/common.sh` "lanes" and `lane_check`, `lib/lane.sh`): Claude on Amazon Bedrock through the AWS profile
`example-bedrock`, launchable like the api lane. Before this, `lane_check bedrock` refused it as not set up and
`lane_env_names` / `lane_env_prefix` knew nothing of it. What is guarded is the profile and the launch line, by the rule above.
**The profile**: `lane_check` looks for the `[example-bedrock]` header line only (a commented header, a longer profile name and
the bare word do not count; trailing blanks and a CR do), and no dummy value of the credentials file appears in any output;
each missing thing (the file, the header, an unreadable `--mcp-config` file, the claude launcher, a malformed prefix, region or
model id) is refused in a plain sentence naming it. **The administrator profile** is refused whatever the credentials file holds
(a config naming it, any name containing `admin` in any case), and the refusal does not repeat the name: a cheap test, since a
wrong profile would put an AWS administrator key behind every pane on the lane. **The launch line**: the seven variables are
compared with the brief byte for byte, each is settable in config, run by a shell the line hands the process all seven and the
test's own shell keeps none, `--mcp-config` is the api lane's own (once, only with the file), and no credential value and no
`$(cat)` is on it. **End to end** (the fake claude logs its environment; the AWS key's presence only): `sala lane bedrock`
recorded and relaunched, `proc_lane` reads bedrock, the pane's shell never held the variables, no settings file was written, the
other pane is untouched, the dummy values are in none of the output, scrollback, logs or argv; a recycle and a spawn keep the
lane, a switch back to subscription-1 clears the variables, and with the header gone the switch and the spawn are refused before anything
is recorded. **The status** is derived (active while `lane_check` passes, a config override winning) and shows in `--list`,
`--json` and the table. Existing suites changed with it: `lanes.sh`, `rescue.sh` and `lanefields.sh` asserted "not set up" (they
now assert the missing profile), and `lanefields.sh` the region (now the suite's fixture region). The fake claude gained `FAKE_BEDROCK_LOG`.
Not checked: the model ids against Bedrock itself (the Sonnet and Haiku 5.5 global ids are by pattern, see `config.example`), a real
AWS credential chain, the sala-web web page of a bedrock pane (its own `proc_lane` mirror reads such a pane as subscription-1).

**The 1-hour prompt cache (Thu Oct 29th 2026): +5, 89 in all.** Claude Code writes the 5-minute
prompt cache on Bedrock unless `ENABLE_PROMPT_CACHING_1H_BEDROCK=1` is set, so a long-lived pane that wakes after five idle minutes
rewrites its whole context. `lane_env_prefix bedrock` now ends with the switch, for a pane's launch line only: `lane_job_env` (`lane env`,
`lane exec`, `job_env_args`) asks for `lane_env_prefix <lane> job` and does not get it, since a one-shot `claude -p` never reuses a
cache entry and the 1-hour write costs more. Guarded, with the fake claude's new `FAKE_CACHE_LOG`: the pane's line (and
`lane_env_names`, the dry run) carries it; a spawn, a lane move and a recycle's `resume_cmd` start claude with it; the `job` form, `lane env`,
`lane exec` and `job_env_args` do not, and neither do subscription-1, subscription-2, api, aws-platform or a pane moved back to subscription-1. A loss here costs money,
not a session, and is silent (nothing fails), which is why the checks stay.

**The same switch for the API-billed lanes (Thu Oct 29th 2026: the aws-platform lane ran every call
on the 5-minute cache).** Claude Code 2.1.312 decides the cache lifetime in one function: the 1 hour on its own only for
a Claude subscription, else 5 minutes unless `ENABLE_PROMPT_CACHING_1H` is set (any provider) or, for the bedrock provider only,
`ENABLE_PROMPT_CACHING_1H_BEDROCK`. aws-platform's provider is `anthropicAws` (`CLAUDE_CODE_USE_ANTHROPIC_AWS`), so the _BEDROCK
variant would do nothing there: `lane_env_prefix` now ends the aws-platform and api lines with `ENABLE_PROMPT_CACHING_1H=1`, again for
a pane's line only (the `job` form leaves it off). the two subscription lanes get the 1 hour themselves; sdk's pane runs no
`claude` line. The fake claude's `FAKE_CACHE_LOG` line is now `<uuid> cache1h=<plain> cache1h_bedrock=<bedrock>`.
`aws-platform-lane.sh` +7 (names, prefix and its config overrides carry the switch; run by a shell the process gets it once and not the
_BEDROCK one; the `job` form, `lane env`, `lane exec` and `job_env_args` do not; the pane's claude has it after a lane move, a recycle
and a spawn, and not after the move back to subscription-1), `lanes.sh` +9 (the same for api: names, prefix, a shell, the `job` form, subscription-1 / subscription-2 / sdk
without; an api pane's claude has it after the move, a recycle and the sweep, a subscription-2 pane not), `bedrocklane.sh` and `lanefields.sh` only
re-aimed (the bedrock pane has the _BEDROCK switch and not the plain one; sdk and api name the same variables bar the api pane's switch).
Not checked: that the CLI really writes the 1-hour entry (that is the CLI's own code, read from its strings), or the bill.

### `tests/aws-platform-lane.sh`: new, 100 (the aws-platform lane, Fri Oct 23rd 2026); 108 since the rename

The aws-platform lane (`lib/common.sh` "lanes" and `lane_check`, `lib/lane.sh`): the Claude API signed with
the AWS profile `example-bedrock` (SigV4), beside the bedrock lane, modelled on
`tests/bedrocklane.sh`. What is guarded is the workspace id, the profile and the launch line. **The workspace id** is not known
yet, so the lane must refuse while the knob is empty and say which knob: `lane_check` is asked with a good profile and an empty
id, then with ten malformed ids (`abc`, `wrkspc_`, a hyphen, upper case, a space, a semicolon, a `$(…)`, a dot, a prefix, a
leading blank), the refusal never repeating the value; `wrkspc_01EXAMPLE_def` is accepted. **The profile and the rest** are the
bedrock suite's checks again for this lane (header line only, a comment or a longer name does not count, an unreadable
`--mcp-config`, no launcher, a malformed region or model id, an administrator profile refused without repeating its name). **The
launch line** is compared with the brief byte for byte and runs through a shell: `env -u CLAUDE_CODE_USE_BEDROCK -u
CLAUDE_CODE_USE_FOUNDRY -u ANTHROPIC_AWS_API_KEY`, then profile, `CLAUDE_CODE_USE_ANTHROPIC_AWS=1`, workspace, region and the
three plain API model ids; the line never sets the Bedrock or Foundry flag, and a shell that holds all three passes none of
them on, counted. **End to end**: the fake claude logs its environment (`FAKE_AWSP_LOG`, new): recorded and relaunched through
the direct sweep with exactly the lane's variables, `proc_lane` reads aws-platform, the pane's shell never held them, no
settings file, no credential value anywhere; a recycle and a spawn keep it, a switch back to subscription-1 clears it; **a pane whose shell
holds the Bedrock flag, the Foundry flag and a workspace key** (made with the tmux session's `-e`) comes back on the lane with
none of the three in its claude. `proc_lane` is also read from real processes' environments (bedrock before aws-platform, only
the exact value 1, an SDK entrypoint before both, a key beside the flag does not make it api). Existing suites changed with it:
`lanefields.sh` (five lanes, the aws-platform fields, its refusal), `lanedormant.sh` (the picker lists), `rescue.sh` and
`lanes.sh` (one assertion each). Web (`web/tests/`): `test_sessions.py` reads both AWS lanes in sala-web's own `proc_lane`
(bedrock first, an SDK entrypoint before both), `test_lane_dormant.py` and `test_new_session.py` the New session form's lane
list (bedrock and aws-platform offered; a dormant one hidden), `test_lane_details.py` the aws-platform record and its page. Not
checked, because nothing here can reach AWS: the real endpoint, the SigV4 signing, whether
the provider accepts the pinned Sonnet 5.5 and Haiku 5.5 ids (by pattern; the installed CLI's own built-ins for this
provider are Sonnet 4.6 and Haiku 4.5; see `config.example`), the workspace id's real shape beyond the doc's example, a real
credential chain.

Renamed Mon Oct 26th 2026 (the lane name `awsplatform` read badly): the file was
`tests/awsplatformlane.sh`, the lane `awsplatform`. +8 checks in a closing section, "the old name": the old word typed to
`sala lane` still records and relaunches the lane (as aws-platform, with a note on stderr), a `lanes.tsv` row written before the
rename revives the pane on the lane and is rewritten by the next write, and `sala lane --migrate` leaves the file as new. The
`proc_lane` loop waits for the process's environment instead of a fixed 0.3 s (a fixed wait could lose that race on a busy machine). The rename's
own guard is `tests/lane-rename.sh`, below; the rename of the two login lanes is `tests/lane-subscription-codes.sh`.

### `tests/lane-rename.sh`: new, 83 (awsplatform → aws-platform, Mon Oct 26th 2026)

The lane's name is data in sala's files and a token in sala's code, and a pane already runs on the lane with the old word recorded in
the live state, so the old word has to keep working while the new one is written. **Hyphen safety**, spot by spot: a shell variable
name cannot hold a hyphen, so `lane_varid` (hyphen dropped, upper case) names the config variables, and the checks read a lane's fields,
the problems message and the lane's directory name through it (`SALA_LANE_AWSPLATFORM_*` keep their names, so an operator's config keeps
working); a `case` arm, an awk field, a JSON value, `env -u` words and a function name are each exercised with the hyphenated word.
**The old word as input**: `lane_norm`, `lane_known`, `lane_canonical`, `lane_default` and `lane_effective` read it as aws-platform; a
typed `sala lane`, `sala op lane`, `sala spawn --lane` take it and record the new word. **Records written before**: a `lanes.tsv` row,
the `lane-default` line, a `lane-state.tsv` dormant record keyed by the old word, `salamander-limit.json` panes and the registry's
lane read as the new word; writers rewrite the rows they carry along and write nothing when nothing changed. **`proc_lane` and
`lane_out`** print the new name for `CLAUDE_CODE_USE_ANTHROPIC_AWS=1`. **`sala lane --migrate`** (`--dry-run` first): the dry run
changes nothing; the real run rewrites `lanes.tsv`, `lane-default`, `lane-state.tsv` and the registry with one backup each
(`<file>.pre-aws-platform-<stamp>`), keeps the mode, appends one `migrate` line to `lanes.log` and leaves its history as it was; a
second run says "nothing to migrate" and writes nothing. `sessions.py` helpers (`norm_lane`, `table_fields`, `relane`). Not checked:
the live state (the migration ran only in temporary homes), a real pane relaunch (the fake claude), stackshot's own reading.

### `tests/lane-subscription-codes.sh`: new, 69 (the login lanes become subscription-1 and subscription-2, Sun Nov 1st 2026)

The two login lanes are `subscription-1` and `subscription-2`; the first one's display name lives in one
setting (the lane table's `label` field, `SALA_LANE_SUBSCRIPTION1_LABEL`, default `Subscription 1`) and everything sala shows reads it. The older lane
words stay read as aliases, as `awsplatform` did, and no stored file is migrated. **Names**: `lane_norm`, `lane_known`, `lane_canonical`,
`lane_state_id` and `lane_field` take both words; the lane lists name the new codes only; `lane_varid` gives `SUBSCRIPTION1` and the
config written before (`SALA_LANE_MAX_*`, `SALA_LANE_TEAM_*`) still counts. **Older words read as new codes** in `lanes.tsv`,
`lane-default`, `lane-state.tsv`, `lane-home.tsv`, `SALA_LANE_FALLBACK`, a typed word (`sala lane default team`, `sala op`, `sala spawn
--lane`), the registry (`sessions.py`) and the Python helpers (`lanewords.py`, `unitjob.py`). **New writes** record the new codes, and
a dormant row written under the old word is replaced, never paired with a new one. **A read rewrites nothing**: files that say `max`,
`team` or `awsplatform` are byte-identical after every reader has run. **Display name**: `lane_label` and its Python twin give the default label
for the code or the older word, and the setting changes it everywhere at once.
**`sala lane names [--json] [--write]`**: the text form, the exact JSON shape stackshot reads, the override showing in it.
**`lane-names.json`** in the state folder: written by `--write` and by a `sala watch` tick that finds it missing, the config newer or the code newer (a second tick with nothing
changed leaves inode and mtime alone; touching the config makes the next tick rewrite it; a config touch that changed no name is checked once), atomically (no temporary
file left) and only when the content differs. **`lane_label` (Python)**: parsed once per process while the file is unchanged, again when it changes; with no file the
fixed defaults answer and no command runs. **laneok keys**: an old-word key and its new code's key merge to the larger (newer) success, in either order. **Grep check**: no user-visible older lane word for
our lanes in `lib/`, `bin/` and `web/src`, outside comments, the lane table's own definitions and an allow-list of vendor plan
names. The existing suites that named the old codes (lanes, lanefields, lanefallback, lanedormant, limitwatch, rescue, signin,
sdklane, spawn, op, units, retire and the rest) now use the new codes; the old-word fixtures stay in `lane-rename.sh` and here. Not
checked: the live state (isolated home throughout), a real pane relaunch (the fake claude), the docs' wording (the map keeps docs out of the suites), stackshot's own reading of the new file.

### `web/tests/test_lane_rename.py`: new, 10 (awsplatform → aws-platform, Mon Oct 26th 2026)

sala-web's side of the rename: it reads sala's files written before (lane-state.tsv keyed by the old word, lanes.log, lanes.tsv,
lane-default, the registry's lane, the saved sightings in `spend-lanes.json`) and counts them for the new lane, so a month's spend
figure does not lose the messages recorded under the old name; the lane table and the details route answer the old word as the new
lane; a spawn payload from a form loaded before takes it and a wrong word is still refused; `LANE_LABEL` quotes its hyphenated key,
the CSS keeps `.lane-awsplatform` beside `.lane-aws-platform`, and `laneNorm` is run in node; a saved link `#lane=awsplatform`
opens the lane's page in the browser. Not checked: how the pill looks on a screen.

### `web/tests/test_sidebar_header.py`: new, 4 (Sat Oct 24th 2026)

The sidebar's header read as a loose "sala" text alone; it now reads "salamander : <name>" with the sala icon
(the one used for the favicon and the installed app). The sidebar's top header is now the installed app's icon (`icon-192.png`, an
`<img>` with `alt=""` and width and height 20, so nothing shifts while it loads) and the words on one line. Held: the markup (the
`<img>` and the exact text; the page `<title>`, the update banner and the manifest still "sala"; the icon file is served), and in
headless Chromium the header pinned open at 1280 px, peeking at 1280 px (the narrowest case: 280 px less the 52 px the header leaves
for the toggle, fixed over it, and 8 px on the right), and the drawer at 390 px: the icon loaded and 20 x 20, the text exactly
"salamander : <name>" with one line top for its text, icon and text on one row, nothing cut (the line and the header do not
overflow, the page does not scroll sideways), both inside the sidebar, the words clear of the drawer's close button and of the
toggle, and at least 6 px to spare for a wider font. The words are 14px and the wide header's right padding 8px for
the peeking case, which had 3 px to spare at 15px. `test_name.py` now expects the new header text. Not checked: a phone, the
page's webfont (the headless run has the fallback font; the 6 px of spare room is the allowance for the difference), a
screen reader reading the header (the icon is decorative).

### `web/tests/test_sidebar_fixed_head.py`: new, 6 (Sat Oct 24th 2026)

The toggle and the "salamander" header are one fixed block at the top left, so the hover view is nearly the pinned view.
Headless Chromium at 1280 px, real mouse events. Held, closed vs peeking vs pinned, in the dark theme, in the light theme and with a session open: the
toggle's, the header's, the icon's and the words' boxes equal within 0.5 px; the header's text "salamander : <name>" the same in
all three (the "sala" once seen pinned is not drawn by anything now); both `position: fixed`, the toggle the element at its own centre;
the toggle's tooltip "Show sidebar" / "Hide sidebar" and `aria-expanded`; the title bar's first content clear of the block and not
covered in closed and peek (it is the element at its own point, left of it at 280 or more), a peek not moving the page, a pinned
sidebar still docking (the bar at 280, content right of it) and the bar's content at the same x closed and docked; the peek's panel
equal to the pinned one (box, background, border, the New session, Overview, list and "Show all sessions" rows, scroll, padding) with
a shadow only on the peek; the header transparent; the pointer on the header's words peeks nothing, on the toggle it does; the block
following the title bar down by the update banner's height and back; a phone at 390 px: toggle in the title bar, header in the
drawer, neither fixed, the words on one line before the close button, no room kept for the block. `test_header_fold.py` and `test_board_items_ui.py` follow too: the title bar now keeps 296 px at its left for the fixed block while the sidebar is not docked and the toggle is no longer in the bar's row, so the width that has the room the old 762 px had is 996 px (996 - 296 - 16 = 684 = 762 - 32 - the old in-bar toggle's 46). `test_sidebar_hover.py` follows
(the toggle does not move when docked; the bar's children exclude the fixed toggle; the stylesheet check looks for the fixed block).
Not checked: how it looks next to other apps' sidebars, the page's webfont (the block's reserved width has
31 px to spare on the fallback font), a window between 761 and about 900 px with a long session name (the header folds as before,
with 296 px kept on the left), a real touch screen wider than 760 px, the shadow's looks.

### `web/tests/test_sidebar_hover.py`: new, 10 (the sidebar on a wide screen, Fri Oct 23rd 2026)

On a wide window the sidebar is over the page and closed on every load (it starts closed, the left edge or the title
bar's button slides it in, moving away hides it, a click on the button keeps it open for that page only, nothing kept).
Headless Chromium at 1280 px with real DevTools mouse events. Held: it starts closed and takes no room (`#main` at the left
edge, the sidebar `position: fixed`, the old in-sidebar hide button gone); the pointer on the 8 px strip along the left edge
slides it in (`body.side-peek`, the page does not move) and leaving closes it, a pointer on the sidebar itself keeps it; the
button does the same, stays above the sidebar in its header with the brand clear of it, and the way from the button down into the
rows does not shut it; a click pins it (`side-pin`, `aria-expanded`), the pointer may leave, the next click closes it at
once though the pointer is on the button, and a reload starts closed; **no pref is read or written**: a `sideHidden: true`
left in `prefs.json` opens nothing and is not in the page's `state.prefs`, the page makes no PUT to `api/prefs` through all of
the above (every request recorded), the file is byte for byte as it was, the endpoint no longer serves the key and refuses a
PUT of it (an old page's write is refused, not kept) and drops a leftover one on the next write, and no source file of the page
mentions `sideHidden`, `side-hidden` or `side-hide`; the sidebar stays while the New session form is up and goes when it closes; a
phone keeps its drawer (no edge strip, the pointer does nothing, a tap opens `side-open`); the stylesheet's wide rules and
the keyboard's `:has(:focus-visible)` are present. Existing suites changed with it: `test_back_button.py` (`tap` brings the
sidebar in by the pointer before a tap on a row), `test_header_fold.py` and `test_board_items_ui.py` (the wide header is the
whole window now: the defect's width is 762 px, not 1000), `test_composer_fit.py` (the composer at the left edge, the sidebar
fixed), `test_new_session.py` (the button opens the sidebar before the New session popover), `test_prefs.py` (the default
without the key). Not checked: how it feels (the 250 ms before it leaves, the 8 px strip, the 0.18 s slide), a touch screen
wider than 760 px (a tap fires the mouse events, so it should peek and pin; nothing here tapped), a real keyboard's Tab into
the closed sidebar.

#### `web/tests/test_sidebar_hover.py`, follow-up: a pinned sidebar docks (Fri Oct 23rd 2026)

A sidebar open by hover may sit over the title bar; one toggled on by clicking the icon should not. The file is now 15 tests. A PEEK (pointer on the left strip or the button) still slides over the page, title
bar included: the page does not move, the button stays above it. A CLICK pins and DOCKS it: the sidebar is `position: static`
beside the page, `#main`, `#top`, the overview and the composer start at 280 px and end at the window's right edge, the title bar's
children are all right of 280, the button is in the title bar and is the element at its own centre, nothing scrolls sideways, the
edge strip is gone, and the pointer going to the left edge, onto the sidebar and away changes nothing; the next click closes it at
once (no slide-out over the title bar: the page is back at 0, `position: fixed`, closed, and it stays closed); hover then click: the
sidebar's left edge is sampled on every frame through the click and a second of rest and is 0 in every sample (never off the edge,
never sliding), then `side-pin` alone; docked, the chat view's composer and title bar span 280 to 1280; a reload starts closed.
`test_a_click_pins…` became `test_a_click_docks_it_beside_the_page…` (the second click now hits the button where the docked layout
put it), `test_no_pref_is_read_or_written` follows the button the same way. Not checked: how the dock feels (the page jumps right
by 280 px at once, no animation, by choice: a peek that becomes a pin does not move the sidebar itself), a window resized across 760
px while docked (the existing media-query handler clears both states), a touch screen wider than 760 px.
The toggle no longer sits in the title bar: it is fixed at the top left and does not move when the sidebar docks (see `test_sidebar_fixed_head.py`).

### `web/tests/test_lane_cards_nowrap.py`: new, 48 (Fri Oct 23rd 2026)

The lane cards' lines no longer break: at about 1400 px, narrow cards in a row made labels such as "Current session"
wrap, a reset time get cut and a card's chip and "Details ›" fall to a second line. A card is now at least 400 px (two
to a row on a wide screen, one column at 760 px and below), the head never wraps (the pills, chip and link keep their size; the plan name and the
"as of" time, the two that can give way, are cut with an ellipsis), the quota rows' label column is 156 px in every row (the bars
start at the same place) and the label does not wrap. the Overview card's head drops the plan name; the details page keeps it (`opts.plan`). Headless Chromium, geometry only: at 390, 760, 1024, 1280, 1400,
1600 and 1920 px, no label, reset time, percent, chip or link wraps (every client rect of its text nodes on one line), none is
clipped (scrollWidth), none leaves its card, the head's children share one row and stay inside it, a bar is at least 40 px, the page
does not scroll sideways; on the Overview cards as drawn (four limits, the widest reset texts "Resets Wed 12:00 PM" and "Resets Sat Jan
10 12:00 PM"), on cards drawn from extreme answers served through a stub of fetch (a stale answer's "as of", a saved answer with a
failed check, a lane with no sign-in, a dormant lane with a hand-set reason, a spend card with an estimate and the widest figures,
and a dormant API card), and on the details page of subscription-1, subscription-2 and api; two to a row at 1024 and wider, one column at 760 and below;
the plan name is on no Overview card and is on the details page (active and dormant). The same checks fail on the old stylesheet
(5 widths of the Overview, the extremes, the API details page at 390). The dormant line's reason (node, the page's own functions
cut out of sessions.js): a trailing "(who, day)" goes once ("Quota paused (Sam, Mon Jan 5th)" reads "Quota paused"), a
fixed reason code still maps, a parenthesis inside the sentence stays, only the last of two goes, an empty or
parenthesis-only reason reads as no reason; the card says "Quota paused since Mon Jan 5th" and "Usage check refused
since Sun Jan 4th". Existing suites changed with it: `test_credit.py` (no plan beside the pills; two cards to a row at 1280),
`test_lane_dormant.py` (the head is the pill; the text no longer has the plan), `test_lane_details.py` (the plan on the details
page). Not checked: how it looks at a width between the tested ones, a label longer than any the server sends today (it would be
cut with no ellipsis in the label column), a phone, a stale or failed answer from the usage endpoint.

Follow-up (Tue Oct 27th 2026): the label column was 150 px and the date form moved with the day ("now + 8 days" read "Sat Jan 10 12:00 PM"
one week and "Wed Jan 14 12:00 PM" the next, 151.8 px, cut), so tests failed whenever the day changed the form. The widest date form
is pinned: a fixed reset (Wed May 30th 2035, 10:44 AM in the test's zone) drawn as "Resets Wed May 30 10:44 AM" (161.3 px at 12 px in DejaVu Sans, the
widest part of each measured on its own), asserted to be on the page. The column is 164 px, the row's gaps 8 px and its bar least 32 px
(a 312 px card holds the row: 164 + 67 for "100% used" + 16 + 35), the phone layout keeps its 12 px gap.

### `web/tests/test_lane_chip_baseline.py`: new, 20 (Fri Oct 23rd 2026)

On the Overview, 'Active' and 'Dormant' and 'Details' did not line up. The chip's words were 12px and "Details ›" 13px with different line boxes, so the two sat on different baselines
whenever the loaded font's metrics rounded apart. They were first made the same size (13px); the chip is now a pill in the lane
label's own style (12px, its words lower case, no dot) and is held to the label's size, weight and family, with the link (13px, 18px
line height) and the label on the chip's baseline within 0.5 px. Headless Chromium, geometry only: at 390,
760, 1024, 1280 and 1600 px, the baseline of each text is the bottom of a zero-size inline-block set in its line (the words are
wrapped for the measurement and put back at once; a range's top plus the canvas ascent was tried and rejected, since Blink rounds the
ascent and it read the old, differing sizes as aligned). Asserted for each chip state, on the page's own cards: active, dormant
(filled) and not configured (outline) on the cards drawn from the extreme answers of `test_lane_cards_nowrap.py` (a stale "as of", the
widest figures, a spend card), the invisible stand-in before the first answer (fetches that never answer, so the placeholder cards), and
the lane details page of subscription-1 and api, where the card's own "Details ›" is removed and the chip must sit on the pill's baseline. Per
head: chip and link have the same weight and family, and the chip the label's size; their baselines agree within 0.5 px; the pill's too; the head's children
share one row and the head is at most 24 px high; a head's baseline sits at the same distance from its top in every state (no state
shifts the head). The pending chip is `visibility: hidden`. Fails on the 12px-against-13px stylesheet of the first version. Not checked: a font other
than the page's webfont (a phone's fallback font differs; the equal size and line height hold the two together
whichever it is, but only the test runner's font was measured), a phone, how the pill's smaller 12px word sits against the 13px pair
beyond the 0.5 px measured.

### `web/tests/test_spend.py` and `web/tests/test_spend_cards.py`: new, 43 and 31 (Sat Oct 24th 2026)

The Overview's cards for the `aws-platform` lane and the `bedrock` lane: the month's spend as an ESTIMATE AT
LIST PRICES, with the models and the sessions on the lane and each one's share. No AWS usage or cost API exists, so the figure is our
own count: `message.usage` of the Claude Code transcripts times the list price of the model (`sala_web/spend.py`, the rates copied from
the vendor's price list), per session and lane, over the UTC calendar month. `GET /api/spend`, cached like the quota and credit answers
(`swr.py`), incremental per transcript file. Every figure is worded "Estimate at list prices"; a lane that cannot be counted says so on
the card.

`test_spend.py` (43, no browser; transcripts, `lanes.log` and the registry are built in a temporary folder, and the amounts are worked
out by hand): model ids normalised (Bedrock-style `anthropic.claude-…-v1:0`, a region prefix, a date suffix, `[1m]`); the price of each
token kind with the two cache tiers apart (Opus 1M of each kind is $37.20; a Sonnet reply of 1000/2000/3000/4000/500 is $0.0244); an old
row with only `cache_creation_input_tokens` is five-minute; a streamed reply that appears on several lines is counted once at the
largest of each field ($0.0192 + $0.0244 = $0.0436); a copied reply in a subagent or fork counts once; subagent transcripts count for
their session; the UTC month boundary (a reply at 23:59:59.999 on Sep 30th is out, one at 00:00:00.000 on Oct 1st is in, and at 23:30 UTC on Oct 31st the
month is still October, which is already Nov 1st in a zone east of UTC) and the rollover that restarts the cache; a model with no price is listed with its replies, never a silent $0; only the sessions that were on an AWS lane
are read at all and files older than the month are skipped; nothing but numbers, model ids and session ids or names is kept or returned
(a planted text in a message is in neither the cache nor the answer). Lane attribution: a message belongs to the lane the session was on
when it was written, from sala's `lanes.log` (the first change's old lane, a `default` change read as the default of that time, a rename
across its old and new name, `(default)` as a placeholder); a session with no record is on its current lane for all its messages; a live
process on an AWS lane is the truth for a session sala never recorded (and is remembered, so the figures survive its end); a session on
subscription-1 is never remembered; a session named in the record whose transcript is not found is said, not dropped. The incremental scan: a second
count reads only the appended bytes, a line still being written is read when whole, a replaced or shrunk file is read again from the
start, a broken cache is ignored. Unreadable records give a plain sentence and missing ones are just empty. The endpoint: pending until
the first count, then served; a restart serves the saved answer at once; it never raises and says what it could not count; a failed
refresh keeps the last figures with the error; a dormant lane is one line; `configured` comes from `sala lane --json`, unknown when the
table cannot be read; counted every five minutes, a failure tried again after one.

`test_spend_cards.py` (10 state tests and 21 width tests, headless Chromium): a lane with spend shows the month as `$x.xx`, the line
"Estimate at list prices since <day>", a model row and a session row each with their amount and share, a live session linked to its page
and one not running muted; a configured lane with no usage is Active with $0.00; the Overview lists the top five and says "and 2 more ›"
to the details page, which lists all; the `#lane=aws-platform` details page draws the card and its own sessions table; a lane not set up
says "Not set up on this machine." with the "Not configured" chip; a dormant lane is a head and one line; unpriced models and sessions
whose transcript was not found are said in plain words; a count that cannot be made says so on the card and recovers on the next ask;
before the first count the card is quiet (the same lines, blank, at the height of an answered card, so nothing below it moves); a
failed request keeps the figures and says so. Widths 390, 760, 1024, 1280, 1400, 1600 and 1920 px, on the Overview and on each lane's
details page: no label, amount, share or link wraps or is cut, a long session name (47 characters) gives way with an ellipsis on one
line and no row is wider than its card, the other cards still hold. The width check fails when a session name is allowed to wrap
(tried at 390 px).

Existing suites changed with it, all because the Overview now has five cards and the details page of the two AWS lanes a spend card:
`test_credit.py` (placeholders and answered cards counted without the spend cards; five cards), `test_lane_cards_nowrap.py` (7 chips
on the extreme answers, 5 cards on the drawn ones), `test_lane_chip_baseline.py` (7 heads; the pending stub also holds back
`api/spend`), `test_lane_details.py` (the Details link on all five cards; the not-set-up AWS lanes show the spend card's "Not set up on
this machine." instead of "No usage check is made for this lane."; two tests renamed), `test_new_session.py` (the scope label is
"Bedrock" now). `conftest.py` gained an autouse fixture that points the sala command setting at a missing path, so no test runs the installed sala.

Not checked: the model strings of a Bedrock or aws-platform reply as served (the id normalisation follows the documented shapes), the AWS bill against the estimate, the fast-mode and web-search surcharges
(not priced), the lag between a lane being recorded and the session being relaunched on it (the replies of that gap are counted on the
earlier lane), the first scan of a very large set of transcripts, and the lane status `sala lane --json` gives in production.

### `web/tests/test_foryou.py` and `web/tests/test_foryou_ui.py`: new, 40 and 19 (Sat Oct 24th 2026)

*The page side of this entry was removed Thu Nov 5th 2026 with the item count button (the entry at the end of this file). The server side stays.*

stackshot's For you list at the top of the items sheet, with Seen and Watch | Mute (`web/README.md`, *For you*;
`docs/stackshot-contracts.md`, interface 22). Neither of the rule's losses applies to a read-only list with two small writes, so the
checks kept guard what a wrong answer costs: a row the user never sees or cannot get rid of, a flag set on the wrong item or on none,
a refusal shown as a success (or a harmless 404 shown as a failure), a trace or the token on the page, a value that reaches stackshot unchecked, a layout that jumps or
overflows on a phone. Server (`test_foryou.py`, stackshot a fake on 127.0.0.1, `fake_stackshot.py`; conftest points the token and
URL at missing files otherwise): the row's fields and what is dropped (no number, a bool for a number, nothing to say, a `url` that is
not http(s), an `item` that is not `<word>#<number>`, text cut, only a real `true` urgent), the list parse (order kept, bad rows
dropped, only `{board#N: watch|mute}` flags, the 200-row cap, an answer that is not the list refused), the two confirmations read
loosely (no `rows` in a seen answer, no `flags` in a watch answer, gaps filled from what was asked), every value that goes out
(entry number or `all`, `board#N` or its number, the three states, no extra fields, the sender always `sala-web`), a plain sentence
for each stackshot status (403, 404, 400, 401, unreachable, no token, a multi-line or long message not passed on), the list at once
and then filled, one read a minute however many pages ask, a failed read keeping the last list with a plain error and clearing it on
the next good read, no token and an unreachable server dialling nothing, Seen for one entry and for all changing the cached list at
once without another read, a seen call before any read, a bad seen or watch never reaching stackshot, every refusal of stackshot a
plain sentence that changes nothing, the flag for the item by `board%23N` and by the bare number, a watch answer without flags
merged into the ones we had, the origin, content-type and size guards on both POSTs, and the token and address in no response and no
file. Page (`test_foryou_ui.py`, headless Chromium, the real app against the fake, sessions, overview and board items stubbed): the
section first in the sheet with a row per entry (what, item, project, when with the time in the `SALA_TZ` zone on hover, Open to the item's page in a
new tab, Seen, the urgent word and edge, Watch | Mute only for an entry with an item, watching pressed by default), the session's own
items still below it, the dot on the chip with the count in its label, the empty line the same height as the loading line (the
sheet does not move when the answer lands), Seen taking one row only after stackshot answered and the focus going to the section's
title, Mark all seen, a slow answer disabling the button so a second tap sends nothing, Watch / Mute setting the flag at stackshot
(the same state again sending nothing), the muted line with Unmute (`default`), flags set elsewhere showing on their rows and a
muted item with no row still listed, a failed read in plain words with the session's items still there, a refusal of Seen or of
Watch | Mute in plain words with the row still there and the next good action clearing it, the chip not moving when the dot comes
and goes, the section at 390, 760, 1024, 1280, 1400, 1600 and 1920 px (nothing wider than the sheet, no button cut, no sideways
scroll, the sheet inside the screen, touch-sized buttons on a phone, every control named), and AA contrast of the buttons, the tag
and the text in both themes with the pressed button told apart by weight. A Seen for an entry stackshot no longer lists (404:
a double tap, or seen on another page) takes the row away with no error, on the server and on the page. Not checked: a real stackshot
answer to any of the three calls (the shapes are taken from the description of stackshot's calls, and the fake is the only
stand-in; nothing here called a live stackshot), the refusal text of stackshot's 403 on another machine, and a Seen racing a background read that started before it (the
list can show the seen row again until the next read, at most a minute).

### `web/tests/test_foryou_hidden.py`: new, 2; `web/tests/test_foryou_ui.py`: changed (Sun Oct 25th 2026)

*The page side of this entry was removed Thu Nov 5th 2026 with the item count button (the entry at the end of this file). The server side stays.*

The "for you" section is hidden on the page until its design is settled. The page hides the section behind one flag, `FOR_YOU_HIDDEN` in `app.js` (true): `renderForYou` draws
nothing, `loadForYou` reads nothing, the chip has no `fy-new` dot and its label drops "N new for you" (the rest of it stays), and the
sheet starts with the session's own items. `loadForYou`, `api/for-you`, `foryou.py` and `test_foryou.py` are untouched. What a wrong
result costs: the hidden section back on the page, a gap or a stray header where it was, or a dot that says something waits
that cannot be opened. Checked (`test_foryou_hidden.py`, headless Chromium, the real app against stackshot's fake holding four
entries that would otherwise show): the sheet has no `.fy` section and no "For you" text, its first child is an item row, the three
items are as before, the chip class is `bchip strong` with no dot and its label is exactly "3 open board items, 1 waiting on you,
1 waiting on others: open the list", a redraw of the sheet and the chip brings nothing back, the page never reads `api/for-you` and the
fake sees no call to stackshot's for-you routes, and the server route still answers with the entries (so unhiding is one flag).
`test_foryou_ui.py` is kept whole: each test flips the flag on the loaded page (`unhide`) and reads the list, so the feature stays
tested. Not checked: the flag's value in a build other than this one (the production page is the file as served), and the sidebar and
overview, which never showed For you.

### `web/tests/test_lane_status_pill.py`: new, 6 (Sat Oct 24th 2026)

On the Overview, 'Active' and 'Dormant' are a label like the lane labels (active green,
dormant gray), and every label of this type is all lowercase ('bedrock', 'aws platform'). The status chip is now a pill of the label's own class family (`sp-pill lane-chip lane-chip-<state>`, no dot),
and `LANE_LABEL` says "bedrock" and "aws-platform". Headless Chromium, the seven cards drawn from the extreme answers of
`test_lane_cards_nowrap.py` (all three states, the bedrock and aws-platform lanes), at 1280 and 390 px, light and dark: the chip has the
label's classes and draws like it (size, weight, family, height, radius, border width and style), every label and chip is lower case
("active", "dormant", "not configured"; "bedrock" and "aws-platform" among the labels), active is green with a tinted fill, dormant a
grey with a tinted fill, not configured a grey with no fill and a 1px border, each holds 4.5:1 against its fill over what is under it,
the head is one row (at most 24 px) with the chip left of "Details ›". A bedrock details page at both widths shows the lower-case
pill in its title and the chip in its usage card, and the tab title is "Lane bedrock". Other tests changed with the words: the
chip texts, the pill lists (`.sp-pill:not(.lane-chip)`), the New session form's lane options, the dot checks (no dot any more).
Not checked: a phone, a font other than the page's webfont. (The details page's Status box and title, left
capitalised here, were lowered in the next entry.)

### `web/tests/test_lane_details_lowercase.py`: new, 6 tests (7 cases), and words changed in `test_lane_details.py` (Sun Oct 25th 2026)

The 'Details' link keeps the plain text colour, not the colour of the lane
label. A lane's details page names the lane with the labels' words (`LANE_LABEL`), not the lane table's own label, and says its
Status in lower case. Headless Chromium: a bedrock page is titled `bedrock` + `bedrock lane` (tab and header `Lane bedrock`) with
`not configured`; an aws-platform page `aws-platform lane` (no "Claude Platform on AWS" in the title) and the tab `Lane aws-platform`;
subscription-1 `active` and subscription-2 `dormant`; the Details links' aria labels name the lower-case lane; on all seven Overview cards, in the light
and the dark theme, the link's computed colour is the card's plain text colour, not the lane label's, with no underline at rest; the
stylesheet still holds the hover underline and the focus ring. `test_lane_details.py` assertions moved to the new words
(the lower-case lane names, `active`, `dormant`, `not configured`). Not checked: the hover and focus states drawn (the
rules are checked as text), the sentence "Not available just now" (not a status word, left as it is).

### `web/tests/test_hosts.py`: 8 → 5 (Sun Oct 25th 2026)

An earlier hostname of the app was retired; the current address serves the same page and terminal.
The 301 from an old hostname to the canonical one, the old-hosts and canonical-host settings and the checks
that went with them (the redirect's path, query, HEAD and port cases, the manifest and worker, `/tty/` left alone, an open tab's
calls served, the settings parsed from the environment) are gone with the code. What stays guards the one thing the removal could
break: the app has no host list, so the retired name must behave like any unknown host. A navigation on it (and on an unknown host
and on sala) is served 200 with no `Location`, the manifest, worker and config alike; a PUT or POST with an Origin matching its Host
is accepted on any host, and one whose Origin names another host (the live name for the retired one and back, a stranger, `null`) is
refused with 403; the sala host serves the API, static files, an upload and the SSE stream; the index's `/?arg=` redirect to ttyd is
the same on every host; the two settings, set in the environment, change nothing. Not checked: the proxy's routing of the retired name
(the ingress is not in this repo).

### Not in this repo: the `briefing-units` provision step (Sat Oct 24th 2026)

The step that installs `contrib/briefing/systemd/` into `~/.config/systemd/user/` lives in a separate provisioning repo,
so its tests live there too (a throwaway HOME with a fake salamander checkout and a fake `systemctl`). Nothing is added to
`tests/briefing.sh` for it. It covers the lean-pair rule (installed only when missing, a
differing copy reported `manual` and never overwritten, the old summary timer not forced on again), a missing checkout
(`skipped`), and check mode changing nothing. Not checked there: a live `systemctl --user`.

### `web/tests/test_overview_cards_order.py`: new, 8 (Sun Oct 25th 2026); `test_spend_cards.py` 31 → 32, `test_lane_cards_nowrap.py` follows

Active cards come first, three cards fit in one row, and the aws platform card is shorter, with no by-model list or sessions. The Overview's
cards are sorted by the state the card's own chip says: active, then dormant, then not configured, each group in the order the
cards are drawn (subscription-1, subscription-2, api, aws-platform, bedrock); a card is at least 312 px wide (it was 400 px, two to a row) with a
smaller padding and label column; the aws platform card on the Overview no longer draws By model, Sessions or "and K more"
(bedrock's keeps them, and the aws platform details page keeps both). Headless Chromium, the real app over fake sign-in files.
Held: with subscription-1 and api dormant and aws-platform not set up the order is subscription-2, bedrock, subscription-1, api, aws-platform; with every lane active
the order is the old one; a lane that turns dormant (the record changes, the page refreshes) drops to the end of the cards; the grid
has three tracks and three cards in the first row at 1920, 1400 and 1024 px, two at 760 and one at 390, no sideways scroll, and a
card no wider than 360 px at three columns. In `test_spend_cards.py`: the aws platform Overview card has no lists, no "more" link and
the words "By model" and "Sessions" are not in its text, while the bedrock card still has both lists; the aws platform details
page keeps its two models and its sessions (a new test); at each width the long-lists measurement runs on a bedrock card (the
same long data is given to both lanes) and the details page of each lane still lists seven sessions. `test_lane_cards_nowrap.py`
expects three cards in the first row from 1024 px (it expected two), two at 760 px and one below. Not checked: how the three
columns look to a person, bedrock's Overview card losing its lists too (at first only aws platform's did).

### `web/tests/test_lane_details_head.py`: new, 8 tests (12 cases); `test_lane_details.py` and `test_lane_details_lowercase.py` follow (Sun Oct 25th 2026)

A lane's details page has no whole card for the status. The Status
section and its card are gone; the status is the Overview card's own pill (`laneChip`) in the page head, right after the lane's name
and before "N live sessions", and a dormant or not-configured lane has its note as one plain line under the head. Record and Usage
share a row on a wide screen. Headless Chromium over the stand-in sala of `test_lane_details.py`, at 1280 and 390 px. Held: no
`#ld-status` or "Status" heading in the page or its code, and none on a live page; the head's order is label, name, pill, count, the
pill next to the name and centred on it, the head wrapping neither the pill away from the name nor the page sideways; the pill has
the card chip's classes and computes the same size, weight, family, height, radius, border, colour and fill as the chip in the usage
card of the same page, for active (green), dormant (grey with a tint) and not configured (grey outline, no fill); the line is under
the head and above the sections, plain (no border, no fill, 13 px), the exact words for dormant and not configured, empty and taking
no room for an active lane; an unreadable record leaves no pill and keeps "Not available just now" as the line; an unknown lane has
no pill and "sala does not know this lane."; Record and Usage in one row at 1280 px (also on the api, bedrock and aws-platform pages,
which keep their spend cards) and one above the other at 390 px; no sideways scroll at either. In `test_lane_details.py` and
`test_lane_details_lowercase.py` the Status-box assertions became pill and line assertions (`chip`, `line`). Not checked: how it
looks, a phone, the order Record-then-Usage (kept from before) against Usage-then-Record.

### `web/tests/test_spend_cards.py`: 32 → 33 (bedrock too, Sun Oct 25th 2026)

The bedrock card on the Overview drops By model and Sessions, as the aws platform card did, and both
AWS cards also drop "No sessions have used this lane yet." (`SPEND_BRIEF_LANES` in `sessions.js`, `spendCard`; a lane with no usage
is the figure, its estimate and the "updated" foot). Each lane's details page keeps the lists and the line. The quiet card before
the first count follows: a brief card's blank sentence line is gone, so the answered card is no shorter than its placeholder
(`test_credit.py`'s cold-restart no-shift check holds). In `test_spend_cards.py`: the bedrock Overview card is asserted as aws
platform's was (figure and estimate, no lists, no "more" link, "By model" and "Sessions" not in its text); a new test has the
bedrock details page keep its model and its session; the zero-usage test now expects no sentence on either Overview card and the
sentence on each lane's details page; the top-five test became "the Overview lists no sessions and the details page lists all
seven" (the Overview's "and K more ›" has no lane that draws it now; `SPEND_TOP` stays for a lane left out of the brief list);
the width test asserts no lists on either Overview card (the details-page width test already lists seven sessions for each lane).
Not checked: how the two shorter cards look next to each other on a screen.

### `web/tests/test_code_wrap.py`: new, 2 cases (Sun Oct 25th 2026)

A code block that scrolled sideways was hard to read: it now shows wrapped, while the copy button copies it without the wrap's line breaks. A fenced code block in the chat now wraps (`white-space: pre-wrap`, `overflow-wrap: anywhere`, CSS
only; `.md pre` in `style.css`). The test renders four blocks (a 300-character token, a long URL, a long curl line, three short
lines) at a desktop and a 390px phone width: each fits its box (`scrollWidth <= clientWidth`, no page scroll), the long ones take
several screen lines, the short block keeps exactly its three, the copy button stays inside the block, its click hands the
clipboard the raw source with no newline added, and a hand selection of the block gives the same text. The copy-text half guards
what a user pastes (a wrap that leaked into the copied text would break a pasted command). `test_code_copy.py` (the long block is
now a taller block, not a scrolling one-liner) and `test_chat_overflow.py` (a code block no longer scrolls sideways) follow.
Not checked: how the wrapped blocks look on a phone.

### `web/tests/test_lane_details_head.py`: 8 → 9 tests (Sun Oct 25th 2026)

The Usage card on a lane's details page no longer draws the status chip in its own head (the
duplicate noted); the page head's pill beside the lane's name (`laneHead`) is the one. The details page asks for
the card with `page: true` (`quotaCard`, `creditCard`, `spendCard`, `dormantCard`), so `headEnd` returns nothing: no chip, no "Details ›"
(the page used to remove the link afterwards and leave an empty `.q-head-end` behind) and no empty stand-in; the API card's Billing link
now takes the auto margin itself. The Overview's cards are untouched. New test (1280 and 390 px, lanes subscription-1, subscription-2 dormant, api, bedrock
and aws-platform not configured): the page head has exactly one `.lane-chip`, the card has none, no `.q-head-end`, no `.q-details` and no
empty child in its head, its lane label pills stay, the page does not scroll sideways, and the Overview's cards (5 or more) each still
have exactly one chip and one "Details ›"; a dormant lane keeps its one line under the head and an unreadable record keeps its line with
no pill. Existing tests changed: `test_lane_details.py` (the card's chips are `[]`, no head end, no empty head child, one pill in the page
head, on subscription-1, api, dormant and both not-configured lanes), `test_lane_details_head.py` (the pill is compared with the lane label's box,
not the card's), `test_lane_status_pill.py` and `test_spend_cards.py` (their "details card is ready" waits no longer wait for the card's
chip). Not checked: how the shorter head looks on a screen.

### `tests/stackshotshape.sh`: new, 12 (Mon Oct 26th 2026); 14 with contract 12 (the same day) and `web/tests/test_roles_cmd.py`: new, 3

Contract 12's guard (`docs/stackshot-contracts.md`; contract-version 12 since the aws-platform rename, which adds two checks: a writer records aws-platform for either spelling, and the new word is one of the lanes sala lists): stackshot reads sala's `lanes.tsv`, `lane-default` and `salamander-limit.json` directly,
so a change to a row format or a key breaks its `lane` done check and its limit reading with no error on either side. Kept: each file
written by sala's own writer (`lane_write`, `lane_set_default`, `lane_rename`, `lane_drop`; the real `watch --limit` against two fake
panes and a weekly-limit record) and read back by a copy of stackshot's reading rule: `<session>\t<lane>` rows, two fields, sorted,
a lane sala knows; the default alone on the first line; a session with no row on the default, with no default on `subscription-1`; a rename moving
the row, a retire dropping it; `panes` keyed by transcript uuid with `s`, `lane`, `lim` (a plain and a per-model one), `since` and `reset`
as integers; a gone pane dropped. Dropped (not written): `lane-signin.state` (`tests/signin.sh` has sala's own side), the posts' wording,
the other lanes' rows (the format does not differ). Not checked: stackshot itself reading the files (its `tests/check_scenario.py`); the
reader here is a copy of its rule and drifts if stackshot's changes. `test_roles_cmd.py`: sala-web's roles command default (unset
`SALA_STACKSHOT_DIR` is `~/stackshot`, a set one is used, the roles-command setting wins) and the empty case (no command, a plain `rolesError`,
nothing run). Existing: `tests/autorecycle.sh` lost its puller catch-up section (the step is gone) and keeps the provision sets'.

### `tests/holders.sh`: new, 43 (Mon Oct 26th 2026)

The failure mode: a subagent starts a background wait loop (`until ! pgrep -f "bash tests/run.sh"; do sleep 5; done` with
`run_in_background`) that matches itself, so it never ends, and it is in no task list of the main session (a task stop says "No task
found"); the pane's relaunch is held for as long as the loop runs. Two parts, both against a stand-in for a claude (a bash with a
registry row) and real child processes; no tmux server, no claude binary.

Kept (naming, `lib/holders.py scan`, `holders_*` in `lib/common.sh`, `lib/ready.sh`): the scan lists a Bash-tool shell in the CLI's
own form (snapshot prefix, `eval '<command>'`, a quote inside the command kept) with pid, age, the task id its stdout file names
(`tasks/<id>.output`) and the subagent whose transcript received that id; a plugin's MCP server child is left out (the same rule as
`work_children`); the caller's own chain (the Bash call running `sala ready`) is never listed; the cut to 120 characters, the `--max`
tail, a `token=value` masked; the empty pane, a pid that is no pane and a garbage argument all print `0`. `sala ready` prints the
holder block first and its old line after; with nothing under the pane it prints the one old line. The relaunch notice carries the
same list (and is the old line when there is no pid, or nothing under the pane); a registry `shell` state and a child-pid skip name
the holders and keep the head that `transient_skip` matches.

Kept (the hook, `hook subagent-stop`): the subagent's shell stopped by process group, a shell without a group of its own stopped with
its child, a line in the log with task, pid, group and command; the main thread's shell (listed as running too), a process outside
the claude's tree (its task id also in the transcript), and a shell the transcript does not name left alone; a subagent that has not
handed back (it may be waiting for its command), a command text that does not match the process, `SALA_SUBAGENT_CLEANUP=off`, a hook
under no registered claude, and seven garbage inputs: nothing stopped, exit 0, nothing on stdout.

Added (descendants, 4 more, Mon Oct 26th 2026): the hook stops what the shell started, not only the shell. A leftover shell whose loop runs
`setsid sleep` (a process group and a session of its own), a plain `sleep`, a subshell's `setsid sleep` grandchild and a `sleep` that
ignores SIGTERM: the shell and all six descendants are gone (the last by SIGKILL after the 0.3 s wait, its log line says so), an unrelated
`sleep` and the main thread's shell under the same stand-in claude, and the claude itself, are still running, and the log has the shell's
line with the descendant count and one `stopped task …, descendant pid N of <shell>` line each. The test fails on the code before this
change (the setsid sleeps survive). Not checked: a pid reused between the process listing and SIGKILL (the start-time check is a few lines
of `/proc/<pid>/stat`; no way to force a reuse here). (An orphan whose parent had died before the hook read the table was "not found, by
design" here; the next paragraph finds it by its output file.)

Added (outside the tree, 4 more, Mon Oct 26th 2026; found by a pane test): a `setsid sleep` started in a subshell
that exited has init (or a subreaper) for its parent, so it is in no parent-link walk, but its fd 1 and 2 still name the task's output
file. The hook now also stops every process of the same user whose fd 1 or 2 is that very file (full path), whatever its parent, group or
session, after the shell and its tree, SIGTERM, 0.3 s, SIGKILL for what still runs. A leftover shell starts five orphaned sleeps
(checked not to be below the stand-in): one on the task's file, one on the task's file that ignores SIGTERM, one on another task's file in the same
scratch directory, one on the same task id in another scratch directory, one on `/dev/null`. The first two are gone (the second by SIGKILL, its
log line says so); the other three and the claude are still running; the shell's log line has the descendant count and the outside count
(`N descendant(s), 2 outside its tree`) and one `outside the shell's tree pid P` line each for the two. The test fails on the code before this
change (both sleeps survive). Existing assertion changed: the shell's log line in the descendants case now ends `, 0 outside its tree: `. Not
checked: a process that left the tree and redirected its output elsewhere (not found, by design), and one owned by another user (skipped).

Dropped (not written): the wording of the lead and tail lines beyond one line each (cosmetics); the macOS path (no `/proc`: the hook
logs it and stops nothing, the scan lists processes without task ids); the watch's re-tell push (`relaunch_text` is the same call,
checked on its own); a Monitor or other non-shell task started by a subagent (not stopped by design). Timing: the scan reads /proc (no `ps`, Linux; one `ps` elsewhere) and
about 100 ms on an idle machine; the test's bound is 5 s because the suites run in parallel. Existing test changed: `tests/busyhooks.sh`
compares the mixed MCP-and-plain-child reason by its head and the named pid now, not the whole sentence.

### `web/tests/test_header_fold.py` 5 → 6 cases, `web/tests/test_board_items_ui.py` follows (Mon Oct 26th 2026)

'Thinking and tool calls' was sometimes inside the ⋯ menu and sometimes in the session header; it is now in the ⋯ menu at
all times. The `.top-toggle` is no longer in the header's fold: its markup is in `#top-tools`, `layoutHeader` never moves it, `FOLD` is
`[reload, meta, tabs]` and the ⋯ button always shows (`app.js`, `index.html`). Kept in `test_header_fold.py`, at ten widths with a 60-character
and a short name: the name whole while anything else is in the bar, every pill whole, what left the bar is in the menu and nothing else in the
fold order, a wider header never folds more, no sideways scroll, the menu opening inside the page with Escape and an outside click closing it,
the tabs, Reload and the toggle working from the menu, the pref kept over a reload. Changed: the toggle is asserted in the menu and never in the
bar at every width (and not visible while the menu is closed); the ⋯ button is asserted visible at every width instead of "exactly while
something is folded"; the menu check also requires the toggle to be in view when it opens; the fold counts are out of three, not four (long
name: 3 at 996 and 320 px, fewer at 1600; short name at 320 px: 3). The short-name widths moved because the header has the toggle's room back:
without the chip nothing folds at 996 px (it was Reload and the toggle) and Reload folds first at 900 px; with the chip (43 px) Reload folds at
996 px. Those numbers are the same strength as before (partial fold with the badges and tabs whole), at the width where it now happens.
`test_board_items_ui.py`: its header probe measures the fold set without the toggle, `FOLD` as parsed from `app.js` has three entries, the
long name folds three. New test (short name, 1600, 996 and 390 px): the toggle is in the menu and not in the bar, the button shows, the bar's
other items stay inline at 1600; opened, the toggle is a 32 px row inside the menu; a click flips it with the menu staying open; Space on the
focused box flips it back; the pref `showTools` is saved. Not checked: a phone (touch targets are the same row as before: 32 px high, the
whole label tappable), and how the menu with its toggle row first looks on a desktop.

### `web/tests/test_board_items_waiting.py` 4 → 6, `test_board_items_ui.py` follows (Mon Oct 26th 2026)

*The page side of this entry was removed Thu Nov 5th 2026 with the item count button (the entry at the end of this file). The server side stays.*

The open items view used to list on hold first and then waiting; it now shows 'needs your call' first. The sheet (`renderSheet` in `app.js`) shows Needs your call (waiting on the user, not held), In progress, Waiting
on others (the old Waiting) and On hold, each with a header and its count and an empty one left out; "Can no longer end" is untouched
and sits between In progress and Waiting on others. The data is the same (`held`, `wait`, `mover`, `waiting`, `expected_by`): no change
in `board.py` or the API. A wrong answer here is a decision hidden under another header, or a parked item listed as needing the user's call.
Kept: every row's text, tags and wait line, the red and quiet counts, the chip's label, the AA contrast of the wait lines, the
older stackshot falling back to `held` (now under On hold). Changed: the sheet test is the four-group order on the nine-item fixture
(one on the user, two in progress, one failed, three waiting by expected-by, two on hold with the dated one first and the undated last)
and its group list; the solo-quiet case and the older-stackshot case follow with the new headers; `test_board_items_ui.py`'s sheet
check expects Needs your call / In progress / On hold for the three-item fixture; `test_foryou_hidden.py`'s "the list starts with no empty
slot" now means the first group header, not the first item. New: a held item is only ever under On hold (held
and also marked waiting on the user; a `hold` wait that is not `held`), Needs your call keeping only the unheld one, counts in the headers,
no empty group drawn; and a session with only held items has only the On hold group. Not checked: how the extra headers read on
a phone (the sheet is 80 % of the screen at most and scrolls inside itself, as before).

### `tests/permissions.sh`: new, 72 (Mon Oct 26th 2026)

Auto-approve comes first; asking a person is the fallback. The PermissionRequest hook (`salamander hook permission-request`,
`lib/permissions.py`, `docs/permission-hook.md`) approves a permission prompt at once and leaves the dialog alone for the cases in its
table. A wrong answer here is either a prompt that should have been the owner's approved without them (a settings file, CLAUDE.md, the
a hook, a credential, a question) or a harmless prompt left to wait for them. The suite feeds payloads in the CLI's shape to the
real verb and checks stdout and the exit status each time, in an isolated HOME; no tmux, no claude.
Kept: approved with exactly the one allow line, parsed as JSON: Bash `ls`, Read, Edit of an ordinary repo file, a relative path under the
cwd, WebFetch, an MCP tool, acceptEdits mode; not approved by mistake the other way: an Edit whose content names CLAUDE.md (only the target
counts), an Agent prompt that names a settings file, the words "tokenizer" and "hook" in a command, a Grep for "token", a `.aws` inside a
hostname. Left (empty stdout, exit 0, the log line naming the reason): AskUserQuestion, ExitPlanMode, a tool named like one that asks,
Edit and Write of `~/.claude/settings.json` (absolute and `~`), a repo's `.claude/settings.local.json`, `~/.claude.json`, CLAUDE.md,
`.mcp.json`, a hooks directory, `sed -i` on settings, `>> CLAUDE.md`, managed settings, `cd ~/.claude && cat
settings.json`, `..` traversal into settings (an absolute path, a path relative to the payload's cwd, and a command), `$HOME` and quotes
inside a path, an MCP input naming settings, a symlink to settings (realpath), an Edit of a hook script that the settings wire (and an Edit
of one that is not wired, and a Read of the wired one, are approved), `cat ~/.ssh/id_ed25519`, `.aws`, `.gnupg`, an API token file, `.env`,
`.env.local`, a token json, a `.pem`, a stackshot token file, an MCP input naming `~/.ssh`; plan mode; garbage, a JSON
list and empty stdin; a payload with no (or a non-string) tool_name; `SALA_PERMISSION_APPROVE=off|0|no|false|OFF`. The switch unset or `on`
approves again. The log: one line per decision (the count equals the runs, empty and garbage input included), time, allowed or left, tool,
reason, the session's first 8 characters, agent (payload `agent_type`, else `SALA_SESSION_ID`), the input cut to 80 characters; a bearer
value and a `token=` value never reach it; a newline in the input stays on one line; past 512 KB it is cut to its last 2000 lines with
the new line kept. A terminal run says what the verb reads and exits 2, as the other hook verbs do.
Not checked: Claude Code actually honouring the allow line (docs/stuck-question-recovery.md, finding 1, shows the payload; the answer
shape is the documented one) and the hook wired into a real settings.json (a provisioning step, not this repo's). The table is a
net for the prompts that mean something to a person, not a sandbox: a path built by a shell trick (a variable, a glob, a computed
string) is not seen, and the suite does not claim otherwise.

### `web/tests/test_side_grouping.py` new, 11

A quick (side) session in the sidebar and the overview, grouped by its side record: a fork under its origin's current group (and, with the origin gone, the project the record kept; a fork of a fork up the chain), a discuss session under its item's project, no role, the `side` marker on its entry; no record, an origin on no page, no origin, no project, a loop of forks and a junk file all stay Unregistered; a session stackshot knows keeps its own project and role; the overview rows group the same way; both endpoints read the record from `SALA_WEB_SALA_STATE`. Not checked: a real fork (the records here are written by the test in the format of `lib/spawn.sh` `side_record`).

### `tests/help-snapshot.sh`, `tests/skills-flags.sh` and `tests/help-gates.sh`: new, 1 + 1 + 21 (Tue Oct 27th 2026)

The help-text gates (tokenless gates): a sala release must not ship with out-of-date help
or skills text. Outside the rule's letter on purpose ("no tests for wording"): these are not tests of what the help says but
gates that hold when it changes, and `help-gates.sh` tests the gates, each on a deliberate drift. (Sat Nov 7th 2026: the
model check that once stood beside them, a pull request job calling a model on a CLI-touching diff, is removed with its
script, its tests and its CI job; no check on a pull request calls a model or signs in to AWS.)
- `help-snapshot.sh` (check 1) is one check: `sala --help` and the usage of each verb that has a safe help call (`PROBES` in the
  file), run in a clean environment, against the committed `tests/help-snapshot.txt`. Drift fails with the unified diff and
  `bash tests/help-snapshot.sh --update`. The verbs with no help path of their own are listed in the snapshot, not failed.
- `skills-flags.sh` (check 2) is one check: every `sala <verb> --flag` the files of the directory `SKILLS_DIR` names, inside backticks or a code
  block, exists in the regenerated help (`.github/scripts/skills-flags.py`); a flag the help has and no skill names only
  WARNs. `SKILLS_DIR` only; no other location is searched. No skills directory (`SKILLS_DIR` unset or not a directory, as on a CI runner): a skip, exit 0.
- `help-gates.sh` checks the gates: (1) a copy of `bin/` and `lib/` in another directory passes (paths normalised, two runs
  equal), a top-level help line edited fails with the diff and the fix line, `--update` into a throwaway snapshot makes it pass,
  a verb's own usage edited (restore) is caught in its section, a missing root fails; (2) fixture skills: a good mention
  passes, an unmentioned flag only WARNs, a stale flag and a removed verb FAIL with `file:line`, prose, pipes and quoted words
  are not read, no skills directory SKIPs (`SKILLS_DIR` set to a missing directory, unset, and unset with a plugin copy under
  `~/.claude/plugins/synced` that stays unread), `SKILLS_DIR` is the one directory read, and the real regenerated help rejects a stale `sala lane` flag and accepts real ones.

### `tests/flags.sh` (new, Wed Oct 28th 2026)

The recycle flag and the job: a flag clears when every live pane it waits for has relaunched since its time (registry `startedAt`), not
when the worker that relaunched it was its own. Checked: the rule on a fake-pane table (before / same second / after, no `startedAt`,
the master, retired vs gone-but-mapped, a flag with no live panes); a pane skipped by two recycles clearing both (two ✅, two hook
calls, 🔄 for the newest only); a flag raised at 30/40 reading 0/40 with one job; scoped flags; the hook against a strict fake of
`client.py recycled` (one call per cleared flag, flag_at = started, partial clear with the given-up panes); the reconcile of old sets
(dry run, quiet past 48 h, never a flag with a live pane that has not relaunched); the gather gate on a fake clock; the rest; then a
real private tmux for the registry read, a routine recycle that skips a pane relaunched 10 min ago and relaunches it after its rest,
two recycles with one busy pane, a lane flag, and `watch` gathering requests. `tests/sets.sh`'s hook assertions changed from one call
per pane to one call per cleared flag. Not checked: the real stackshot client (the strict fake stands in), a large live fleet.

### `tests/barepane.sh`: new, 25 (the bare-pane heal, Wed Oct 28th 2026)

When a claude process dies, its tmux pane stays up as a bare shell and nothing
revives it, because revive runs only on a reboot, a CLI update or recycle and the deferred list, and watch's own "no claude
in the master pane" check covered the master alone. `lib/barepane.sh` (called by `watch`)
revives any mapped pane that stays at a shell with no claude. The checks guard that this never starts a second writer on a
conversation or acts in the middle of another operation, and that a mass death is healed in steps. No master is configured, a
private tmux socket, an isolated HOME and the compiled fake claude; every kill is one pid whose exe is the fake and whose
environment names the suite's HOME (`killfake`, `cleanup`). Checked: panes with a claude and a first tick over bare panes
revive nothing and post nothing; after the grace the bare panes are revived with `revive --only` (the fake's start log: one
resume each, on the pane's own conversation), the longest-bare first and at most `SALA_BARE_MAX` per tick (the capped one is
named in the log and revived on the next tick, the others not touched again), one post per tick that names the panes; left
alone however long they stay bare: a session the registry marks retired, a side session with its `side done` marker, a shell
running a command, a session in `SALA_NO_RELAUNCH`; a held recycle lock revives nothing and the clocks start over (no revive
on the first tick after it); a pane whose resume dies is tried `SALA_BARE_TRIES` times, one "could not revive" post, then left;
`SALA_BARE_REVIVE=off` revives nothing and the heal resumes once it is back on. Not checked: the real fleet, the exact post
words beyond the headline, a pane map with a multi-pane session (logged and left; one line of code).

### `tests/wrapup.sh`: new, 51 (the idle wrap-up and clear of background agents, Thu Oct 29th 2026); +2 (off by default, Fri Oct 30th 2026)

Decision: the step is OFF by default in code (`SALA_IDLE_WRAPUP` defaults to `off`; the CLI's own
compaction is the only limit). The suite exports `SALA_IDLE_WRAPUP=on` for every check that needs the step to run, and checks that with the variable
unset (the new default) and with garbage in it a tick types nothing and keeps no state, and a `--dry-run` says nothing about any pane. The rest of this
section describes the step as it behaves when turned on.

Why: a wake that comes after a background agent's prompt cache has expired (about an hour) reloads the whole conversation (about 200k
tokens) at the uncached price. The remedy:
ask the idle agent to write down what only it knows, then clear it. `lib/wrapup.sh` (called by `watch`; `watch --wrapup`
alone) does both steps; `lib/hook.sh` `session-start` gives a cleared back agent one context line; `tests/fake-claude.c` learned a
registry row of a given age (`FAKE_IDLE_AGE`), a message that is a turn (`FAKE_TURN_MS`), `/clear` as the real CLI 2.1.312 does it
(probed on a private tmux socket: the same row and pid, name kept, a new `sessionId` within a second) and a CLI that ignores `/clear`
(`FAKE_NO_CLEAR`). Private tmux socket, isolated HOME, the compiled fake claude; every kill is `kill_fake_claude` (exe is the fake and
its environment names the suite's HOME); the Stop hook's record is written by hand. Checked: the off switches (`SALA_IDLE_WRAPUP` unset, `=off`,
`SALA_IDLE_WRAPUP_MIN=0`) type nothing and keep nothing; `--dry-run` says what it would do and changes nothing; an eligible back pane
gets the exact wrap-up text behind the sala marker, and no other pane does; left alone, each with its reason logged once (not at every
tick): a front agent and a side session (no line), a pane mid-turn, one with a background process, text typed in its input box (and the
text is still there), a parked pane, one idle less than the threshold (no line), one relaunched with no turn since, a dialog on the
screen, an sdk-lane pane, a last turn that left a scheduled job; the wrap-up's turn runs, then `/clear` is typed, in that order; the
registry shows a new conversation on the same pid with the name kept, the pane map and the session registry follow, the ledger log has
the follow, one log line per step and no post; the cleared pane, idle for an hour again, is left alone until its new conversation has
had a turn, after which a plain `watch` tick wraps it up again and clears it onto a third conversation; a pane relaunched between the
steps drops its state; a wrap-up that produced no turn is dropped to a retry wait and not repeated at once; a `/clear` the CLI does
not take is tried `SALA_CLEAR_TRIES` times, then recorded `failed` with the conversation and pane map untouched, and the pane is not wrapped up again while nothing changed (checked: two ticks at 55 min idle, one log line) until a Stop record newer than the failure exists; a pane idle past `SALA_IDLE_WRAPUP_MAX_AGE` (70 min against 58) gets neither a wrap-up nor a clear, one log line (also in `--dry-run`), a retry whose wait is over is held by the same bound, and `SALA_IDLE_WRAPUP_MAX_AGE=80` wraps the same pane; an unreadable `sessions.json` (empty back list) keeps the in-flight states while a healthy list still drops a gone session's; the SessionStart hook with
source `clear` prints the context line for a back row (name, project, valid JSON) and nothing for a front row, a start, a resume,
`SALA_CLEAR_CONTEXT=off` or garbage. Not checked: the real CLI's reaction to the wrap-up message (the fake only counts a turn), the
real fleet, a pane that receives a wake between the wrap-up and the `/clear` (its turn simply is the turn that ends), the prompt-cache
saving itself.

### `tests/parked.sh` (new, 31; +5 on Wed Oct 28th 2026 for the name; +5 for the ordinary revive's name) and `web/tests/test_parked_sessions.py` (new, 7) (Wed Oct 28th 2026)

The case: the CLI's "← for agents" view moved a session's conversation into a background job. The
pane's claude stayed as a viewer (registry status `shell`, `parkedJobId`), the registry held a second row (`kind` bg, `jobId`, no tmux)
under the same name, so it looked as if there were two agents of that name. A recycle skipped the pane for ever (it never reads
idle), and the pane map still held the conversation from before the move. Fixtures are rows in the CLI 2.1.312 shape with made-up values.
Kept (web): one overview row and one sidebar entry for the pair, carrying the pane's name, tmux and pid and the job's status
(idle / working / needs input), `sessionId` and `parkedJob`; the status following the job; a job with no viewer still listed; a viewer
whose job process is dead keeping its own `shell` and the mark; the older CLI's whole-uuid `parkedJobId`; an unparked session's payload
unchanged (no `parkedJob` key). Kept (`tests/parked.sh`, a private tmux socket, the compiled fake claude, `sleep` stand-ins for the
jobs): `parked_job_pid_r` by jobId, by whole uuid, by a short id's prefix, none when the job's process is gone; `registry_conv_r`
(the job's conversation, a dead job's one transcript, no transcript: the row's own, an unparked pane's own); `is_idle_reason` /
`is_idle` (job idle: idle; job working: "parked in background job …: registry says 'busy'"; an unparked `shell` pane unchanged; a
parked pane with no live job reading as before); `revive --save-map` following the job (and c unchanged); `salamander map` listing
the pane once with the bridge the job row holds; the heartbeat's `sessions.json` keyed by the job's uuid, one entry; a revive's dry
run naming the job's uuid; a real `revive --only` of the idle one (the job's process ended, the viewer left by Esc and Ctrl-C, the
fake started once on the job's uuid and not on the old one, the new row not parked, the map and the inbox holds clean); a working job
leaving pane and job alone; an unparked pane relaunched as before. The resumed pane's name (the
resumed claude registered as `background-4a`, the job's own title, and sala-web matches the overview row by registry name): the
parked resume's line is `claude --resume <uuid> --name <session>` (checked on the new pane's argv; `resume_cmd`'s third argument
`parked`), an ordinary revive's line and `resume_cmd` without the argument carry no `--name`, a name outside `[a-z0-9-]` is never
typed. The ordinary revive's name (Wed Oct 28th 2026: a conversation that already stored the job's
title would take `background-4a` again on its next ordinary revive): `close_pane` reads the pane's current row and passes the marker `named`
(`resume_cmd`'s third argument, which `parked` also still means) when `name` differs from the tmux session and `nameSource` is not `user`:
a pane whose row says `background-4a`/`derived` resumes with `--name sala-test-d` (argv checked), `nameSource` `user` (a hand rename, which
rename-sync follows) and a name equal to the session get no `--name`; `resume_cmd ... named` is the parked line, an unsafe name is never typed.
Probed on CLI 2.1.312 (a private tmux socket, a throwaway `claude -p` conversation titled `original-bg-title`):
`--resume <uuid> --name X` registers the row as name X, `nameSource` `user`. Dropped: wording beyond the key phrases. Not checked: the real
CLI's viewer (the Esc and Ctrl-C leave is the steps `sala unpark` exercised once on 2.1.282; the fake stands in), `revive --self` from
inside a parked pane, `retire` of a parked pane.

### tests/continuedin.sh: new, 30 (the continued-in follow, `lib/continuedin.sh`)
A live Claude Code pane that moves to a new transcript id (a `continued-in` record in the old transcript, same pid) keeps its pane map row
and session registry row. A private tmux socket, an isolated HOME locked with flock, the compiled fake claude (its registry row set per pane),
eight panes: no record (and one quoted JSON-escaped inside a message) moves nothing; `SALA_CONTINUED_IN=off` moves nothing; with the pane map
frozen (a recycle) every pane is skipped: the map unchanged, no watch log line, no ledger write or deferral, no session registry record. After
the freeze one `watch` tick follows a record that has four more lines after it (a, f, h) and a chain of two (b), each on the pid's registry row
alone; the pane map names the new id and no row an old one, the ledger log has the four `follow` lines with caller `watch, continued-in`, the
watch log one line per pane (b says 2 hops), and the session registry lists the new id after the old (b: old, middle, new, in order). Not
followed, said once in the watch log and not repeated by later runs: a registry row that still names the old id even though the new transcript
exists and the record is newer than the process (e: another process's switch or a hand `--resume`), a new id with no transcript (d; the
transcript appearing is no evidence, the registry row changing to the new id is, and `watch --continued` alone then follows), a follow the
ledger refuses because the new id is another row's conversation (g). Two `revive --save-map` runs (write_sidecar) after the follows, and a
watch run after them, leave the map byte for byte the same (no ping-pong). `cont_record` on a transcript with a record ~62 KB from the end
returns the id and the record's time quickly, the
default window is 256 KiB, a record outside an 8 KiB window is not seen. Nothing posted to Slack. Not checked: the real CLI writing the record
(probed once by reading a large transcript, whose record had four lines after it), `lib/follow.py` firing `watch --continued` and killing a
run after `SALA_FOLLOW_TIMEOUT` (an inotify daemon; the handler is one line like `rename`), a record more than `SALA_CONTINUED_TAIL`
(256 KiB) from the end of the old transcript (not seen by the tick; write_sidecar repairs it at a recycle).
### `tests/retire-own.sh` (new, 108 with a review; reworked after a review; widened; hardened after a review; the throwaway tag; the reason door)

A session may end the throwaway it started with no words. `lib/spawn.sh` now records
the spawning Claude session on a bare throwaway's registry row (`spawned_by`, `lib/sessions.py`), and `sala op retire NAME --from YOU` with no
`--words` is queued when `op_own_retire_ok` (`lib/op.sh`) finds all of: a live row under exactly NAME, no project, no role, not a side session,
`spawned_by` = YOU, NAME neither the master nor YOU. **The caller is placed by process ancestry** (`ancestry_session`, `lib/common.sh`): the
call's parent chain is walked up through `/proc/<pid>/stat` to a pid that is a tmux pane's process, with a Claude Code process on the way (comm `claude` AND an exe under the account's `~/.local/share/claude/versions/`, `claude_exe_trusted`; a test's temporary HOME is trusted in place of the account's); the pane's
session is the caller and `--from` must be it. `TMUX_PANE` and `--from` are only claims, so a plain shell, an orphaned call, a person's pane
(no claude above), or a spoofed `TMUX_PANE` all find no caller and the no-words path is refused (a person still passes `--words`). **The target
is bound to its row by process**: the throwaway's pane and claude carry the row's id as `SALA_SESSION_ID` (`lib/spawn.sh`), and the retire is
refused when ANY process in ANY pane of the tmux session of that name (the whole tree, `proc_tree`) carries another id or none (a session renamed to a dead throwaway's name). **The runner checks again** (`op_run`): the marker stores the row id (`ownrow=`) and a `nowords` marker is re-judged at run time, going stuck with a reason, nothing ended, when the session was replaced, the row changed or the id is missing. Checked
with the fake claude on a private tmux socket (`sala-retire-own-<pid>`), an isolated HOME, `SALA_OP_QUEUE=off` (markers are written, nothing
runs them); each call runs as a child of a driver sitting in its own pane window, `claude` being a copy of bash under the fake install folder run through a symlink named claude (so comm and exe are both a real install's), or of a `human` script for a person's
shell: spawn from owner's pane, from other's pane and from a plain shell (the row's `spawned_by` is owner, other, none); the own retire is
queued with empty `words` and `nowords=words: none (throwaway, retired by its spawner)`, the queued line and `op --list` carry the note, blank words
are no words; refused with nothing queued, each with the "no --words" text, the exception's own sentence and the reason (`refused here: …`):
a throwaway whose spawner is live (both directions), a project agent, a side session, the master, the asker itself, a row with no `spawned_by` under a name that is no throwaway's,
the row's id in place of its name, a name with no row; `rename` with no words keeps the plain refusal; a retire of two names fails the shape; with
words the same retire of another's throwaway still queues, no note. Ancestry: a plain shell (with and without `TMUX_PANE` of owner's pane)
refused; a claude child in other's pane with `TMUX_PANE` = owner's pane refused for `--from` owner ("this call runs in session ...") and for
`--from` other; a person's pane with a spoofed `TMUX_PANE` refused; a claude child in owner's pane with no `TMUX_PANE` queued; an orphaned
double-fork call refused; `spawn` from other's pane with owner's `TMUX_PANE` records other, from a person's pane records none. Rename: a
throwaway of owner's killed (row live), another throwaway renamed to its name, refused ("not the throwaway on that registry row"); an id-less
session of that name with no Claude Code process in it refused ("carries no row id on any process"); no tmux session of that name left, queued. **Review round 2**: a symlink to bash named claude, and a bash copy under a `.../claude/versions/` folder that is not the account's, run as windows of owner's session, are refused ("process ancestry"), the real driver is queued; a child of the throwaway's pane lacking the id, and a second window lacking it, are each refused, queued once they are gone; the marker carries `ownrow=`; with the session replaced after queueing the run goes stuck ("is not the throwaway on that registry row", "nothing was ended"), the replacing session lives and the retire never starts; an `ownrow` changed, or deleted, goes stuck too; the untouched control is retired by the run (state done, session gone). **Review round 3**: with `SALA_OP_STUCK=on` and `SALA_OP_CLAUDE` a stub that records any start, a no-words run whose `ownrow` is changed, and one whose `ownrow` is missing, go stuck ("nothing was ended") without the helper (no `helper=` on the marker, no stub call, no "claude -p" in the log, the session alive), while a control queued with words and made stuck (its `arg=` lines removed) still gets its one helper (`helper=` recorded); a short-lived child in a pane of the target (a zombie, whose environment reads empty) no longer makes the queue-time check refuse (checked to fail when the skip is removed). **Widened Fri Oct 30th 2026** (retiring a throwaway must never need the owner; "who may" is now the spawner, the master, or any session when the row has no live spawner and a throwaway's name): a no-spawner `*-test-*` row is queued from owner and from other (note `retired by any session: no live spawner`, `ownrow=` stored) and still refused with no caller by ancestry; `op_throwaway_name` takes `scratch-*`, `*-check-*`, `*-test-*`, `*-probe-*` and refuses a plain name, an agent's name and near misses; throwaways started by a session that is then closed: refused while it is live ("who is still live"), queued once it is gone, and a dead-spawner row under a plain name refused ("who is no longer live, but its name is not a throwaway's"); the master (other) ends owner's throwaway whose spawner is live (note `retired by the master`) but not a project agent, a side session or itself; a no-spawner row with a project, and one with a side flag, refused under a throwaway name; a row named on a fresh stackshot project record's agents map refused, a name the record does not list still queued; an old row (the pane is the fake claude started with `SALA_SESSION_ID` removed, so it has an idle status for the plan) queued by name binding and then passed by the runner's second check (state done, session gone); a session renamed to a no-spawner throwaway's name refused; a no-spawner throwaway queued and run to done with the note kept on the archived marker. **Review**: `--force` and `--keep-web` are refused with no words at queue time (either flag, before or after the name) and still queue with `--words`; a marker edited by hand to carry `arg=--force` goes stuck in the runner with `SALA_OP_STUCK=on` and a stub helper that is never called (nothing ended); the agents-map check fails closed for the any-session and master doors: a stale, missing or unreadable project record is refused ("could not confirm that ... is unlisted") while the spawner door still queues, `pages.py agent-listed` (a stub through `SALA_AGENT_CHECK_SCRIPT`) answering unlisted (exit 3, or "no project page") lets it through, answering listed refuses ("is on a project's agents map"), and an exit 2 refuses ("cannot tell"); a fresh record that lists a name wins over a `pages.py` answer of unlisted; the master ends only a throwaway-named row or one it started (a plain name spawned by owner refused, "was not started by the master and its name is not a throwaway's", one spawned by the master queued); a pane with no row id on any process passes only under a throwaway's name with a fresh unlisted answer (a no-id victim renamed onto a dead plain-named throwaway's name refused, one renamed onto a dead throwaway-named row refused for a stale or missing record and queued with a fresh one); `op --help` is asserted for the new rules. The guard's `own_throwaway` kill exemption (`tests/guard.sh` below) is not widened and still allows only the spawner, on purpose: it kills by pid at once, with no queue, no runner re-check and no project-record look-up. Not checked: a registry row with a literal missing id (the registry always writes one), the Slack post's wording on a real queue (op.sh's own markers carry words), `spawn` through the web layer.

**The throwaway tag (Fri Oct 30th 2026)**: a bare `sala spawn` writes `throwaway` = `1` onto the row (`lib/spawn.sh`, `sessions_set`; `lib/sessions.py` `FIELDS`; unpublished, so `EXPORT_KEYS` and the contract version do not move), from a Claude session, a plain shell or a person's pane alike; a spawn with `--project`/`--role`/`--mandate` or with `--side` never does; `sessions set` of a project, role or side value, and `sessions tag --project/--role`, clear it (the side-end rename goes through `sessions_set` and so clears it too), while an unrelated field set (a lane) leaves it. `op_own_target_ok` has a new rule `tag` after the spawner rule: any live session may retire a tagged row, whatever its name and whether or not its spawner is live; it still refuses the asking session itself, the master, a row with a project, a role or a side mark (a tag written straight onto such a row by the test does not count), a row on a project's agents map and a stale or unreadable record that cannot confirm it unlisted (fails closed), and `--force`/`--keep-web`; the note is `words: none (throwaway tag set at spawn, retired by any session)`. A row with no tag keeps its earlier rules unchanged: the suite's older cases now stand in for such rows (its `spawn` helper takes the tag off after spawning unless `TAGGED=1`): a live spawner opens only the spawner and the master, no spawner under a plain name is refused, a throwaway's name with no live spawner is open to any session with the note `words: none (throwaway with no tag, retired by any session: no live spawner)`. The runner case queues a tagged row from an unrelated session and runs it (state done, session gone, the archived marker keeps the tag note). Between turns is retire's own idle check, not a new one: a target mid-turn is refused by the plan (`retire NAME --dry-run`, "is not idle") before anything is queued and, if it became busy after queueing, by the runner's `salamander retire` (no `--force` with no words): the operation goes stuck with nothing ended, and the asker queues it again once the target is idle (`tests/retire.sh` covers the idle check). `lib/guard.py`'s `kill <pid>` exemption is not changed: it still allows only the spawner.

**The reason door (Tue Nov 3rd 2026)**: `op_words_policy VERB ARGS…` (`lib/op.sh`) says per verb and arguments whether a marker needs the owner's words (`owner`), a recorded reason (`reason`) or takes the throwaway door (`throwaway`); `op_main` and `op_run` both ask it. The suite's new sections run `revive --only NAME [--only NAME]… [--force] (--item board#N | --why "<line>") --from YOU` with no `--words`, from a driver pane under a fake claude (the same placement as the retire cases). Queued: with empty words, the `nowords=` note, one `ownrow=` per name and `item=` or `reason=` (not `why=`, which the stuck handler uses), shown by `op --list`, `op --status` and the op log; `--why`; `--force` with two names, asked by another session; with `--words` the reason is recorded too and no note is written; `--plan` queues nothing. Refused, nothing queued, each with the sentence that says what is missing: no reason; `--item` as `board#x`, `#5`, `5` or two lines, or with no value; a `--why` of two words, an empty one, one of two lines or over 200 characters; both `--item` and `--why`; a sweep (with and without `--force`); `--rescue`; `--lane-default`; `--item`/`--why` on recycle, retire, lane, model and close-shell; a name with no live row, a row id in place of the name, the asker itself (alone or among several names), the master (alone or among several); a sender not on `SALA_OP_REASON_FROM` (a listed sender is queued); a plain shell with and without a spoofed `TMUX_PANE`, a claude child in another session's pane claiming `--from` owner, a person's pane, an orphaned double-fork call, and `--auto` from a Claude session and from a shell; every other verb with no words keeps its refusal with no door named for it, and retire's throwaway door is unchanged. The policy table is asserted for a sample of shapes, and the stuck helper's brief for a no-words revive allows only `salamander revive [--force] --only` the marker's names and never a retire. The runner cases queue a revive, edit the marker and run `op --run`: a control run relaunches only the named session, and each mismatch (row id replaced or deleted, item deleted or malformed, item and reason together, a two-word reason, a session added with no row id, `--rescue` added, the `--only` removed, the sender no longer allowed, the session made the master since, the sender equal to the session, the verb changed to recycle) ends stuck with the reason, nothing relaunched and no `claude -p` helper. The `--item` check is a format check only (no stackshot lookup); the suite asserts that `op --help` says so, and `tests/help-snapshot.txt` carries the new shape.

### `tests/guard.sh`: the session's own throwaway (+81; reworked after a review)

Note: `sala op retire` with no words was widened to the master and to any session for a throwaway's name (`tests/retire-own.sh` above); this guard exemption was not, and still allows only the spawner on purpose (a kill by pid has no queue, no runner re-check and no agents-map look-up).

A session no longer has to ask the owner to run `kill <pid>` by hand for its own throwaway. `lib/guard.py` lets
`kill <pid>` of the claude of a throwaway the calling session started pass (`make_own_ok`, `own_throwaway`; the caller is the tmux session of
the hook's own `TMUX_PANE`, which Claude Code sets at launch and a command's text cannot set; the target is placed by `tmux list-panes -a`;
the registry row's `spawned_by` must equal the caller, and the pid's `/proc/<pid>/environ` must carry the row's id as `SALA_SESSION_ID`, so a
session renamed to a dead throwaway's name is not that throwaway). **Review round 2 (placement)**: `tmux new-window`/`neww`, `split-window`, `respawn-pane`, `respawn-window`, `join-pane`, `move-pane`, `break-pane` and `new-session -t` aimed at another session of the fleet's server are denied (`placement_rule`, kind `tmuxwin`); the caller is the session of the hook's `TMUX_PANE`, targets are resolved with `tmux display -p`, an unresolvable target, the caller's own session, a private server (`-L`/`-S`) and reads or `send-keys` pass; the master is exempt and an unknown caller with another session's target is denied; the hook's prefilter now also runs the guard on `tmux`. The suite also locks its temporary HOME (`flock`). Checked on a private tmux
server (`sala-guard-<pid>`), an isolated HOME, a fake claude as each pane's own process (each with its row's id) and a registry written
under the HOME; the guard only decides, nothing is killed. Allowed: `kill`, `kill -TERM`, `kill -9`, `sudo kill -TERM` of the caller's own
throwaway, and a new session of a recycled name whose claude carries that row's id. Denied: another session's throwaway, a throwaway with no
`spawned_by`, a project agent (even one the caller started), a side session, the caller's own session, a name with two live rows, own and
another's pid in one command or chained, `pkill claude`, `killall claude`, `kill -1`, the same pid from a session that did not start it, no
`TMUX_PANE`, the master's session, no row, no registry file, a victim renamed to a dead throwaway's name (its claude carries another row id),
a victim with no `SALA_SESSION_ID`; the deny text names the allowed stop. **Review round 3** (+30): `new-window -t =victim`, `new-session -t=victim` and `-t victim` with no colon are denied, as is a window in the caller's own session named like the victim (the lookup tries `<target>:` too); `split-window -p 50`, `-f` and `-l`, `join-pane -p`, the prefixes `new-win` and `split-w`, `owner:\;` as a word that ends the first command, `TMUX_PANE=... tmux new-window`, `env TMUX_PANE=...`, `env -u TMUX_PANE` and an earlier `export TMUX_PANE=...` are denied; so are `swap-pane` (and `swapp`), `swap-window`, `move-window`, `link-window` and `rename-session -t other` (and `rename -t =other`); `rename-session` of the caller's own session (or with no `-t`), `=owner`, `swap-pane` and `move-window` inside the caller's session, and `split-window -p`/`-f` into the caller's own pass. Not checked: a real `kill` (the hook is a decision only), a process
group (denied before and after, unchanged).

### `web/tests/test_shell_backend.py` (new, 41), `web/tests/test_shell_drawer.py` (new, 11), `tests/smoke.sh` (+15), `web/tests/test_prefs.py` (18 → 19) and `web/tests/test_header_layout.py` (the shell drawer, Thu Oct 29th 2026)

What it is: a terminal drawer under every page of sala's web UI (a Shell button in the header, a docked drawer on a desktop, a bottom sheet with a key row on a phone) on a tmux session of its own (`SALA_SHELL_SESSION`, default `sala-shell`), a plain login bash that sala-web makes on demand. A wrong answer costs the following. The session list shows a bare bash as one more Claude session; a revive, a restore or a lane move treats it as a session to bring back (or lists it as "done with it?" at every recycle); the key route takes free text from a page and runs it in a shell; two opens at once make two shells; a button the header cannot hold pushes the session name off the bar.

Kept (`test_shell_backend.py`, a private tmux server `tmux -L`, an isolated HOME, the temp folder locked and removed at the end, every process the suite started stopped by its own pid): `POST /api/shell/open` makes the session once and says `created` only the first time (a plain bash in the home directory, alone in its session; asked again it is the same pane and nothing is sent to it; after the session is killed the next open makes a new one and says so), never touches another session, and two opens at once make exactly one shell; both routes are guarded like the other POSTs (403 cross-origin, 415 not JSON); the key route refuses 22 look-alikes (text, a command, a name in the wrong case, two keys in one, a control character, `Space`, `F1`, `M-x`) and nine bodies that do not carry a key string, all 400 with nothing sent; the allowlist is fixed and holds names only; Tab, Escape, Ctrl+A, Enter and Ctrl+D sent in turn reach the shell and only the shell (read off a `cat -vT`, while a second session is left empty); with no shell running a key is a plain 502 and makes none; a registry row pointing into the shell session is in no list (the session reader, the sidebar's and the Overview's payloads) while a row in any other tmux session is (the control). Kept (`test_shell_drawer.py`, the page in a headless browser against fakes for the two routes): the markup (the button before the ⋯ button in the DOM, drawn after it; the drawer, handle, header, chip, link and close button; the key row); the button on the session view, the Overview and the New session page and nothing loaded (no frame, no `shell/open`) before the first use; a phone opens a sheet with a frame of `/tty/?arg=<the session `api/config` names>`, a dim backdrop, a Close of at least 44 px, and closing keeps the frame (the shell keeps running); a shell that had ended (`created: true`) gets a new frame; each key button posts its fixed name, sticky Ctrl arms the next key and clears; a refused key is said in the drawer; a wide screen docks the drawer under the chat with the composer above it; Ctrl+` toggles unless the focus is in the composer; open or closed survives a reload and leaving for the Overview; the height comes from `api/prefs` and a drag saves it there (the first run of this check found that a drag saved nothing). `test_prefs.py`: `shellHeight` default 300, the round trip (and another key leaving it alone), and a string, a float, a boolean, null, 0, 119, 4001, -300 and a list refused. `test_header_layout.py` follows the new button: the cluster is the board chip, the status badge, Reload, ⋯ and Shell in that order, the Shell button a full-size tap target on a phone, and a short name is whole at every width but one: with the board chip in the bar on a phone narrower than 390 px the name is cut with an ellipsis (centred, some of it in view); the Shell button's move into the menu (below) is the way out. Kept (`tests/smoke.sh`, a private tmux socket): `SALA_SHELL_SESSION` defaults to `sala-shell`; `no_relaunch sala-shell` is true and `no_relaunch` of a bare shell under another name false; `spawn --list`, `lane_sessions_on` and `revive --dry-run` leave `sala-shell` out while naming the control (a bare shell session under another name); `adopt sala-shell` is refused with nothing written to the pane map. Dropped: the look of the drawer (colours, the icon, the chevron), which a screenshot shows and a test would only copy. Not checked: the real ttyd inside the frame (its connection needs a running sala-web and tmux server; the frame's URL, `allow` and clipboard hook are checked, the terminal itself is the Terminal view's and `test_terminal_osc52.py`'s), a real soft keyboard (sticky Ctrl for letters typed in the terminal is best effort), and Ctrl+` pressed inside the terminal frame (the browser gives that key to the frame).

Review round: `test_shell_backend.py` keeps its tmux socket in a short `/tmp/sala-*` folder (a unix socket path is capped at 108 bytes and a CI runner's pytest folder is longer), locked while the test runs and removed at the end, and adds two tests: the shell lock is made per event loop on first use, and `SHELL_SESSION` follows `SALA_SHELL_SESSION` (unset and empty give `sala-shell`; a name in sala's config file is read when the environment has none; read in a fresh interpreter since it is read at import). `test_shell_drawer.py` adds that a press (pointerdown, mousedown) on a key-row button is cancelled so the terminal keeps its focus and the soft keyboard stays, while a press on another drawer button is not, and the click still sends the key. `tests/smoke.sh` adds: `spawn sala-shell` and `rename X sala-shell` are refused (a Claude session must not take the shell's name), with a control for another name each; `revive --only sala-shell` says it is sala's own shell session and not "take it out of SALA_NO_RELAUNCH", with the control that a `SALA_NO_RELAUNCH` session still gets that advice. Not kept: a test of the message wording in lane and model (same helper, `no_relaunch_fix`, as the revive one tested).

### `web/tests/test_header_fold.py` (+2 cases: one test over two names, 8 cases in the file), `web/tests/test_shell_drawer.py` (+2, 11 → 13) and `web/tests/test_header_layout.py` follows (Shell into the ⋯ menu, Thu Oct 29th 2026)

What it is: the header's Shell button joins the fold ahead of Reload (order Shell, Reload, status badge), so on a 360 px phone with the board chip in the bar the session name keeps its room and Shell is the first thing to move into the ⋯ menu, as a "Shell" row with its icon. A wrong answer costs the following. The name is cut on a 360 px phone, or the menu row is a dead copy that does not open the drawer, or its aria state drifts, or on the Overview and the New session page, which hide the ⋯ button, Shell folds out of reach.

Kept (`test_header_fold.py`, a headless Chromium at fixed widths): the fold order is Shell, Reload, status at every width, and `folded` counts follow (320 px folds all three); at 360 px with the board chip, a short name folds only Shell and a longer one (10 characters) folds Shell and Reload, each with a check that with Shell put back in the bar the name would not have fitted (so the fold is not trivially true), the name whole, the chip in the bar after the name with its count, the Shell row in the menu below View with the word, at least 44 px high, the icon, `aria-expanded="false"` and `aria-controls="shell-drawer"`; at 1280 and 996 px nothing is folded and Shell is in the bar with its word. `check` gained a `badge` switch because an idle session has no status badge to expect. Kept (`test_shell_drawer.py`): at 320 px a tap on the ⋯ Shell row opens the drawer (one frame, one open, `aria-expanded` true, the menu closed), a second tap from the reopened menu closes it, closing from inside returns the focus to ⋯, Ctrl+` toggles while Shell is folded, and widening the window puts the button back in the bar with the drawer state kept; on the Overview and the New session page at 320 px Shell stays in the bar as a 44 px tap target that opens and closes the drawer, and folds again on a session. `test_header_layout.py` follows: at 390 px a working session now folds all three (Shell, Reload, status), so the cluster is the board chip and ⋯, and the Shell button measures 0 wide (it is in the menu). `test_board_items_ui.py` follows too: its fold list holds Shell and a 60-character name folds all three. Review round: `test_shell_drawer.py` adds that a layout pass keeps the focus on a focused Shell or Reload button in the bar (the pass used to re-insert them, which blurs a node), and that a keyboard activation (click detail 0) of the folded Shell row leaves the focus on ⋯ while a mouse click is left alone; the menu-row test says it checks state sync by script (a phone sheet's scrim covers ⋯), and the Ctrl+` test waits for the composer focus to stick (the shell frame's late load no longer takes the focus when the drawer is closed or a text field has it). Dropped: the look of the folded row (colours, hover), which a screenshot shows. Not checked: a real phone (a headless Chromium at 360 px stands in; the fonts differ, which is why the names are chosen by measurement rather than count).

### `tests/permmode.sh` (new, 33, Thu Oct 29th 2026)

What it is: every line sala types to relaunch an interactive claude carries the user settings' `permissions.defaultMode` as `--permission-mode <mode>` (`permission_mode_args` in `lib/common.sh`, appended by `resume_cmd`, and by `spawn --fork`), because a resumed session restores the mode its transcript recorded and ignores the settings.

Kept: the helper on a table of settings files (no file, no permissions block, no defaultMode, each of the seven modes, a garbage value with its stderr note, a wrong-case value, a number, a file that does not parse, a file that is not an object, `$CLAUDE_CONFIG_DIR`, a second lane's own directory against the first's); `resume_cmd`'s line with and without the flag and after the lane's `--mcp-config`; the real relaunches, the argv of the fake claude read from `/proc/<pid>/cmdline` after `recycle --force` (revive's path) with the mode set, unset and garbage, and after `spawn --fork` with the mode set and unset, and a plain `spawn` (no flag: a new session reads the settings itself). Isolated HOME, a private tmux socket, the compiled fake claude, every process the suite started stopped through `kill_fake_claude` (its `/proc` exe), the HOME removed by the EXIT trap.

Left out: the sdk lane's pane program (it launches the Agent SDK driver, not a `claude` line) and `lib/question.sh`'s `claude -p` resumes (their own mode logic, deliberately never bypassPermissions); `unpark` and `restore` reach the flag through `resume_cmd` and `revive`, which the suite covers.

### `web/tests/test_header_layout.py` (the centred test now 400 px and up, 16 → 12 cases; +17 new: 16 widths-and-names, 1 for the 360 px numbers, left-aligned name under 400 px, Fri Oct 30th 2026)

The name is left-aligned on phones: centred, it got about 129 px of a 360 px phone with the board chip (a 17-character session name lost 2 px, a 20-character one 28). Under 400 px the title's columns are the toggle's room, the name's (all that is left) and the cluster's (`style.css`, `@media (max-width: 399px)`); from 400 px up the centred grid is untouched. The fold keeps its decisions: `nameFits()` in `app.js` measures on the centred grid (class `fold-centred`, set and cleared inside the call), so the same items stay in the bar.

Kept (a headless Chromium at fixed widths, the board chip in the bar): at 320, 360, 390 and 399 px with four names (10, 17 and 20 characters long, and a 60-character one) the name's block starts one gap (8 px) after the sidebar button and its dot is not under it, the cluster is still the board chip and ⋯ (3 folded), nothing overflows, the name's right edge stays clear of the cluster, a long name is cut with an ellipsis against the cluster (every pixel up to it used) and the 20-character name is whole from 360 px up (at 320 px 141 of its 157 px, centred it had 89); at 360 px a long name has between 175 and 190 px (the decision's numbers, 181 px; centred 129). The old centred-at-every-width test now runs at 400, 430 and 1280 px, and a short name is whole at all of them: that is the "at 400 px and wider nothing changes" check. Dropped: the 320, 360 and 390 px cases of the centred test, which assert the layout this change removes. Not checked: a real phone (Chromium at the width stands in; the fonts differ, which is why the widths are asserted in ranges).

### `web/tests/test_header_layout.py` (+7 cases: 6 tests; the left-aligned name follows the viewport, `fold-centred` always comes off, the 399 px gap closed; Thu Oct 29th 2026)

A load of a 20-character session name at 360 px once showed the name centred and cut (133 of 157 px) where two reloads showed it left-aligned and whole; the device metrics had been set twice. Looked for and not found: a layout that is stale after a width change (the header is laid out again on every resize of the bar by a ResizeObserver, and the phone rule is CSS, so the viewport decides). Found and fixed: the class `fold-centred` that `nameFits()` puts on `#title` while it measures was removed after the measure, not in a `finally`, so a measure that threw left the bar on the centred grid (the name centred and cut) until the next layout; and the phone block's `@media (max-width: 399px)` left 399.01 to 399.99 px (browser zoom) with neither layout, now `@media not all and (min-width: 400px)`, the exact complement of the centred layout's side. The comment on the phone block's second template said it equalled the one above it, which is the phone's own; it is the base `#title` template.

Kept (a headless Chromium): opened at 430 or 1280 px, narrowed to 360 px (left-aligned, whole, 3 folded, `fold-centred` off), the same metrics set again, widened (centred), three round trips, then 399 px (left) and 400 px (centred); opened at 360 px, widened to 430, narrowed to 320 and back to 360; `fold-centred` off after `layoutHeader()` at nine widths, and a MutationObserver on the class sees it go on and off in pairs only, the last change off; the name's `getBoundingClientRect` made to throw on the call made with the class on: the error still comes out and the class is off, and the next layout at 360 px is right (this is the one that fails without the `finally`); the stylesheet has no `@media (max-width: 399px)`, the phone block starts `@media not all and (min-width: 400px)`, and its centred template is the same text as the base `#title` rule. Not checked: a fractional viewport live (the DevTools metrics override takes whole pixels and an iframe's width is snapped to whole pixels, so the gap is held by reading the stylesheet), and a real phone.

### `web/tests/test_sheet_lists.py`: new, 8 (the sheet shows stackshot's three lists, Fri Oct 30th 2026)

*The page side of this entry was removed Thu Nov 5th 2026 with the item count button (the entry at the end of this file). The server side stays.*

The sala ui did not use the same item status as stackshot. The items sheet had five groups of its own; it now has
stackshot's home page lists, Your move, Agents at work and Waiting, in that order, and one function (`boardListOf` in `shared.js`) says
which an item is in: the row's `list` when it is one of the three, else its `state`, else Waiting. A wrong answer here is a decision
for the owner hidden under Waiting, or an item the board calls theirs shown as an agent's. Kept: every row's text, tags and wait line, the
header chip's red for Your move. Held: in node every state's list, a missing or unknown state (and prototype keys such as
`constructor`) in Waiting, `list` over `state`, an unknown `list` falling back to the state, the order within a list and the count; in a
headless Chromium the three titled groups in order with each item where its `list` or `state` puts it, a list with no item having no
group, and the chip and the sheet counting Your move alike. `test_board_items.py` +2 (`state` and `list` pass through `board.py`; a
malformed one is dropped, a long `state` cut) and +1 more (a verifying item's `wait` of `end` passes through, with its date and overdue).
`test_board_items_waiting.py` +1 (a verifying item in Waiting shows *verifying: end date* with its date and the overdue tag, whoever's
move it is) and is rewritten to the three lists (held items and failed
waits are Waiting rows, a Waiting row shows its wait line and overdue tag whoever's move it is, the session's own saying only the kind and date; an older stackshot that sends neither `state` nor `list` puts everything in Waiting, bar an item with `waiting` true, which is Your move); `test_board_items_ui.py`, `test_foryou_hidden.py`
and `test_header_fold.py` follow with the new group titles, chip label and a `state` on their stub items. Not checked: how it reads
on a phone, and the sidebar row's count, which a later change removes.

### `web/tests/test_unread_count.py`: new, 38 (replaces `test_unread_chip.py`, the sidebar's unread reply count, Sat Oct 31st 2026)

A front agent's sidebar row shows a filled orange count of the replies it has written since it was last
opened, in place of the row's board count and the "New" chip. A wrong count costs a session opened for nothing, or a
reply never seen. Held on the server: the scan counts a turn once, by the line that ends it (`stop_reason` not `tool_use`,
so narration between tool calls is not a reply), stops at the first reply not newer than the read marker, widens its window only
while every reply seen is newer and stops at 10; a session that is not idle counts only lines that say they ended, so a running
turn is not counted; the marker is moved up by `POST /api/read` and never down, a first sight counts as read, and the count clears
after it; only a front agent counts (a background agent, a session with another role or none always gets 0), and a line
that has not said it ended is not counted for a session that is busy, waiting or a shell; `/api/sessions` carries an integer `unread_count` and `unread` as `count > 0`. In a headless Chromium
(`/api/sessions` stubbed): the count on a front row (3), none on a row at 0, 9+ above nine with the label "More than 9 unread
replies", the `aria-label` reading "3 unread replies in <session>", the order dot, label, ⋯, count with the count at the row's far
right, the pill's size and weight, filled in both themes, white on `--accent` with a contrast of at least 3:1 in both themes (the
mockup's colours reach 3.12:1 dark and 3.90:1 light, below AA's 4.5:1, which is why the bar is the 3:1 of a UI
component), no row height change, opening a session clearing its count and posting its name to `/api/read` (also on leaving it, and
for a reply that landed while it is open), a folded project or scope header showing the total of the sessions inside (9+ above
nine) and none once expanded, no `.bmark` or `.newchip` left on a row, and the README text naming the cap and the scan. The
other board tests follow the row losing its board mark (`test_board_items_ui.py`, `test_board_items_waiting.py`,
`test_sidebar_count_right.py`, `test_back_button.py`: they open the sheet from the header chip or `openSheet`). Not checked: how it
reads on a phone, and a transcript so far behind that 10 replies lie past 16 MB (the count is then a floor).

### `web/tests/test_back_button.py`: +6 (one test over 3 links and 2 widths, a link in a reply to sala's own page stays in sala)

On a phone, a sala link inside a reply opened Chrome's in-app view, not sala. Every link a reply renders is `target=_blank`
(md() in `app.js`) and the click handler that routes `#s=` and `#sessions` links through `go()` skipped any link with a target. It now
lets `_blank` through, still bounded by its same-origin, same-path, sala-route test. The test renders a reply with `md()` and
dispatches clicks: a bare `#s=<name>`, the full-origin URL and `#sessions` plain-clicked are sala's (`defaultPrevented`) and leave the
sidebar click's history (a phone's one entry becomes the view, a browser pushes one); ctrl, cmd, shift, alt and a middle click on the
same link are left to the browser; a stackshot link, a GitHub link and another path of sala's own origin are left to the browser; every
link keeps `target=_blank` and `rel="noopener noreferrer"`. It fails on the old `app.js` and passes on the new one. Not checked: the
installed app on a phone.

### `tests/webinstall.sh` (new, 35; the web UI's ttyd unit and `install.sh --web`, Sun Nov 1st 2026)

What it is: someone else can install sala's web UI on their own machine. `install.sh --web` copies the three user units from `web/contrib/` (`sala-web.socket`, `sala-web.service`, `sala-web-ttyd.service`) into `${XDG_CONFIG_HOME:-~/.config}/systemd/user`, writing the checkout's path into their `ExecStart=` lines (the units assume `~/salamander`), and prints the commands that start them. `sala-web-ttyd.service` runs ttyd for the Terminal tab and the Shell drawer on a unix socket of its own; `sala-web-ttyd-attach` is the command it runs per tab. `docs/web-proxy.md` is the recipe for HTTPS and a login in front of both sockets.

Kept: under a fake HOME with a copy of the checkout's install inputs, a plain install writes no unit and names `--web`; `--web` writes the three units, mode 644, no temporary file left, nothing enabled, `%h/sala/...` in `ExecStart` for a checkout under HOME, the absolute path for one outside it; a second run changes no file; `XDG_CONFIG_HOME` is honoured; a path with a space, a % or a $ (which a unit line cannot carry safely) exits 1 with nothing written; a write that fails (a folder the user cannot write to; skipped when the suite runs as root) removes its temporary file, exits 1 with a message on stderr and prints no next steps; an unknown option exits 2. The ttyd unit is read for the settings the web UI relies on (`--interface %t/sala-web-ttyd/ttyd.sock`, `--base-path /tty`, `--url-arg`, `--check-origin`, `--writable`, `RuntimeDirectory=sala-web-ttyd`, `UMask=0077`), for owner values (an organisation, a machine, a home path, a board id), and the same for the other two units and with `systemd-analyze --user verify`. The attach script runs on a private tmux server (`tmux -L sala-webinstall-<pid> -f /dev/null`, the only kill is that server's own `kill-server`): a valid existing session gets a client, an unknown name is said so and the sessions listed, an invalid name (`a;b`) never reaches tmux, a typed unknown name closes.

Left out: ttyd itself and the proxy (Caddy, cloudflared) are not run; the Caddyfile in `docs/web-proxy.md` was checked once by hand with Caddy 2.6.2 against fake unix-socket backends (401 without a login on `/` and `/tty/`, 200 with it, the `Host` header passed through), the cloudflared outline was not run. `docs/web-proxy.md` is not opened by the suite (`tests/suites.map` lists `docs/*` as files no suite needs). `systemd-analyze verify` is skipped where the runner has no user manager.

### `tests/neutral-defaults.sh`, `web/tests/test_zone_config.py` (new, 9), `tests/spawn.sh` (the background directory) and the web zone tests (the shell session name, the time zone and the background directory become settings)

What it is: three defaults are settings with neutral values, so a sala installed on any machine shows none of another's. `SALA_SHELL_SESSION` (the web UI's shell drawer, default `sala-shell`; the web app reads the same line from sala's config file and tells the page the name through `api/config`, with the machine's short hostname), `SALA_TZ` (an IANA zone; unset or empty is the machine's own local time everywhere sala and the web UI show a time, and the label is the zone's own abbreviation, never a hard-coded one) and `SALA_BACK_CWD` (where `spawn --role back` starts without `--cwd`; unset is `$HOME`, a named directory this machine lacks refuses the spawn). A wrong answer costs the following: a session name or time zone that belongs to someone else on a page, a time an hour or a day off for someone who never chose a zone, a background agent refused or started in a path that exists only on another machine.

Kept (`tests/neutral-defaults.sh`): with an empty config `SALA_SHELL_SESSION` is `sala-shell`, `is_shell_session` knows that name and no other, `SALA_TZ` and `SALA_BACK_CWD` are empty and all three are listed by `config print`; with `SALA_TZ` unset and a made-up machine zone (America/Los_Angeles, Asia/Kolkata, Etc/UTC) `local_human`, `_when_r` and `cs_tzlabel` give that zone's clock and label and `lane_day` gives the machine's day (23:30 UTC is Sep 22nd in Kolkata and Sep 21st in Los Angeles); with `SALA_TZ=Europe/Berlin` the output is that zone's whatever the machine zone (`23:13 CEST Mon Sep 21st`), the label `CEST`, not a literal; a config line sets a session name and a background directory; config.example documents the three settings; no tracked code, unit, README or config.example holds a personal session name or brief path. `tests/lib.sh` exports a fixed `SALA_TZ` for the other suites (a CI runner is UTC), as a config line would, and `neutral-defaults.sh` unsets it.

Kept (`tests/spawn.sh`): a background agent with no `--cwd` starts in `SALA_BACK_CWD`, else `$HOME`; the directory missing is refused with a message naming it and nothing is started; `--cwd` wins; a front agent is not affected; a leading `~` is the home directory; a directory from another installation's layout is not used when the setting is unset.

Kept (`web/tests/test_zone_config.py`, `test_shell_backend.py`, `test_shell_drawer.py`, `test_schedules.py`, `test_new_session.py`, `test_timing_debug.py`): `api/config` tells `timezone`, `tzLabel`, `tzOffsetMin`, `shellSession` and `host`; Europe/Berlin gives CET in winter and CEST in summer, with offsets; unset, empty or a name that is no zone gives the machine's zone (TZ) and the page then shows the viewer's; both settings are read from sala's config file as text (quotes, `export`, a trailing note, the last line winning, the environment winning over the file, a similarly named key ignored); the zone is parsed from the file again only when the file changed (modification time and size) or the environment's value did, and a changed file shows at the next call without a restart; the page's helpers (run in node) format in the told zone, in the viewer's when none is told and in the viewer's when the name is unknown, with the server's label standing in where the browser spells a zone as a bare `GMT+4`; schedule times, the new session stamp and the timing debug header name the zone of the setting. `conftest.py` pins `SALA_CONFIG` at a file that is not there, `SALA_TZ` at a fixed zone and leaves `SALA_SHELL_SESSION` unset.

Not checked: a browser in a zone other than the machine's (node's `TZ` stands in for it).

### `web/tests/test_scopes_brand.py` (new), `tests/neutral-defaults.sh` and `tests/spawn.sh`, `tests/side.sh` (the scopes and the title bar's name, Sun Nov 1st 2026)

What it is: the scope names and the title bar's suffix are settings with neutral defaults, so a sala installed elsewhere shows neutral ones. The scopes are `SALA_SCOPES` and `SALA_DEFAULT_SCOPE` when `SALA_SCOPES` is set (so a fleet's sidebar order stays its own), else `[project_scopes] order` (and `default`) in stackshot's own file, else none; the suffix after "salamander" is `SALA_BRAND_SUFFIX`, served by `api/config` and put into the served page's markup (`{{brand}}`, escaped), so a reload shows no flash.

Kept (`web/tests/test_scopes_brand.py`, made-up scope names only): with nothing set there are no scopes and no default; the setting gives the list in its order and a default that is a scope (else the first); a line of sala's config file is read when the environment has none; a set `SALA_SCOPES` wins over stackshot's file (order and default included), the file is used when `SALA_SCOPES` is unset, a file without scopes leaves the setting, odd entries (spaces, capitals, paths, numbers, repeats) are dropped, and a changed file is seen without a restart; a session's scope and its project title follow the list; the sidebar groups follow the list order, then `other`, and with none set there is one `other` group; the project form checks a scope against the list when there is one (and its message names the list) and against the slug shape when there is not; `api/config` tells `brand`, `scopes` and `defaultScope`; the served page carries `salamander` or `salamander : <suffix>` (HTML-escaped, read on each load) in the title bar's markup; the suffix is one short line (whitespace collapsed, 40 characters at most); the shipped page, `app.js`, manifest and the unit `Description=` lines name no owner or machine, and `app.js` has no scope list of its own.

Kept (`tests/neutral-defaults.sh`): the three settings are empty by default, are listed by `config print`, and are documented in `config.example` and the README; `suggest_prefix` gives the slug alone with no scopes, otherwise `<scope>-<slug>`: the page directory first when it is a scope (even for a slug that leads with another scope: `lab/work-x` gives `lab-work-x`), then a slug leading with `<scope>-` for a scope other than the default as it is, else the default scope (else the first) in front, even of a slug leading with it (`home-home-ledger`); a slug that equals a scope without a dash, or a longer word such as `workshop`, does not count; a glob in the setting stays a word. `tests/spawn.sh` and `tests/side.sh` export their own made-up fleet for the prefix they assume.

Changed: `web/tests/conftest.py` gives the older web tests a temporary `XDG_CONFIG_HOME` (removed at exit) and a made-up scope list through the environment, so none of them reads this machine's stackshot file; the two older assertions that named the scope list follow that list.

Not checked: the browser side (`app.js` painting the title bar and the scope chips from `api/config`) is checked by reading the script and by `node --check`, not in a browser; `suggest_prefix` has no reader for stackshot's file, so the shell side needs `SALA_SCOPES`.

### `tests/neutral-defaults.sh` (+26 checks), `web/tests/test_owner_name.py` (new, 10) and the suites that asserted the old wording (the owner's name in runtime text becomes a setting, Sun Nov 1st 2026)

What it is: the runtime strings (the text sala sends to sessions, its refusals and notices, the web form's words and hint) read `SALA_OWNER_NAME` (default `the owner`; `lib/common.sh` defaults and exports it, the Python helpers read the environment, sala-web reads the environment and then the config file through `config.owner_name()`). The `[for …]` marker a session's message to a front agent opens with follows the same setting, because the board derives that marker from its own owner setting and the two have to be equal; a fleet whose board calls its owner by a name sets both.

Kept (`tests/neutral-defaults.sh`, made-up name only): the default is `the owner`; set empty it is the default too; `config print` lists it; a config line is read, and `common.sh` exports it so a Python helper sees the same name; `SALA_FALLBACK_WORDS` reads naturally with the default (`the owner's standing pick … until the owner or a session moves them back.`) and with a name; the help snapshot holds no personal name; `config.example` and the README document the setting; a scan over every tracked file of `lib/`, `bin/`, `web/src/`, `mod/` and `contrib/` (the briefing aside) finds no runtime string that holds a personal name. The scan leaves out whole-line and trailing comments in shell, comments and block comments in scripts and pages, and docstrings, and a planted file (a comment, a trailing comment, a docstring, a string) proves it flags the string and nothing else. `web/tests/test_owner_name.py`: default, config line, environment over config, empty, one short line (40 characters), the words a form queues (front, back, side) carry the name, the served page fills `{{owner}}` on each load and escapes it, no placeholder is left, and the shipped page holds no personal name outside comments.

Changed: `tests/lib.sh` and `web/tests/conftest.py` pin a made-up name (`Rowan`), as a config line would, so the suites that assert the full wording (`guard`, `op`, `side`, `spawn`, `parkedq`, `nomaster`, `reauth`, `rename`, `retire-own`, `psets`, `pset-target`, `sets-master`, `flags`, `boardseam`, `settingsapply`, `lanefallback` and the web spawn and side tests) read the name from the fixture; `neutral-defaults.sh` unsets it. The fallback words no longer carry a board id or a date, so `lanefallback.sh` checks the quoted pick instead. `tests/suites.map`'s `neutral-defaults` line was re-measured (the scan opens the shipped files).


Cleaned and reaching every helper (`tests/neutral-defaults.sh`, section "the owner's name is cleaned once, and reaches every helper from the config alone"): `common.sh` keeps only letters, digits, space and `. _ ' -` of the name (at most 40 characters) and falls back to `the owner` when nothing is left, so the name is safe inside the double-quoted strings, provision's `-p "..."` that the remote shell parses a second time, and sed and awk programs. Checked with a name holding a double quote, `$`, a backtick and a command substitution (cleaned; nothing in it runs; provision's PROMPT survives the second parse unchanged), a name of nothing but shell characters (`the owner`), and `O'Neil-Smith Jr.` (kept whole). `SALA_FALLBACK_WORDS` is a default again, so a config line overrides it. With `SALA_OWNER_NAME` unset: `guard.py`, `question.py` (through its hook: the reason starts `The owner declined`, the sentence-start form) and provision's post helper (the `PYPOST` heredoc, run from a copy cut out of `lib/provision.sh`) say `the owner`. `hook pre-tool` run with the name only in a scratch config file and none in the environment carries it into the deny (it does not source `common.sh`), says `the owner` with an empty config, and cleans a hostile name the same way. The scratch folder is `$T` under a locked, trapped `mktemp` with `HOME` inside it. `tests/rename.sh` builds one side mandate with the fixed heading `## Instructions for this conversation` (spawn's heading now) and the rest with the older `## <name>'s instructions for this conversation`: the reason line reads both.
Not checked: the scan reads text, not what runs, so a string built from pieces or read from a file is not seen; lower-case data tags (the owner kind in the provision lines, the board's mover kind and its function names in `board.py`) and one data mapping in `contrib/backfill-job-projects.sh` are left literal by design and are not scanned; comments, docstrings and `contrib/briefing` are not runtime text here; the host names in two messages are a separate setting's job.

### `tests/neutral-install.sh` (new), the neutral test fixtures, and `SALA_HELP_SESSION` (`web/tests/test_scopes_brand.py`, `tests/neutral-defaults.sh`) (a sala installed from scratch names no owner, Sun Nov 1st 2026)

What it is: the last check of the neutral-install series. `install.sh` runs from this checkout into a scratch HOME that has no owner config, and the read-only commands of the installed `sala` and of sala-web are scanned for anything personal. The tests and the runtime text use made-up names (scope names, example domains and profiles, the question board's subject prefix taken from `SALA_DEFAULT_SCOPE`), and the one piece of the web page that was hard-coded, the overview's Get Help chip that opened a named session, is the setting `SALA_HELP_SESSION` (default empty: the chip is not in the served page; a value that is not a session name is ignored).

Kept (`tests/neutral-install.sh`, in a locked temporary directory removed by a trap that is set before anything is created; `tmux`, `systemctl` and `loginctl` are stubs that log and fail, and the run ends by asserting the log is empty and the real sala config is untouched): `install.sh` exits 0, links `salamander` and `sala`, seeds a config identical to `config.example` with no active line and the `compact.tsv`, a second run changes nothing, `--web` copies the three sala-web units; the installed `sala --help`, `lane`, `op`, `job`, `note`, `question` help, `lane --list` and `config` (whose printed neutral values are asserted: shell session `sala-shell`, owner `the owner`, empty scopes, brand, help session, time zone, back directory, master and fleet hosts) and sala-web's `/api/config`, `/`, `/sessions` and `/manifest.webmanifest` (through `starlette.testclient`, with the host name pinned) are scanned for every pattern of the clean-text deny source (the patterns live there and in no suite; a machine with none skips the scans with a notice) (matches counted, never printed; product and repository names are masked first), and with no `SALA_HELP_SESSION` the served page has no Get Help chip and no raw placeholder.

Kept (`web/tests/test_scopes_brand.py`): the Get Help chip opens the session the setting names (read on each load, escaped), is absent when it is unset, and is absent for a value that is not a session name. `web/tests/test_overview_actions.py` checks the markup in the file (the chip between its markers, with the placeholder) and, in a browser, that the chip opens the session `conftest.py` sets (`help-session`, made up). `tests/neutral-defaults.sh`: `SALA_HELP_SESSION` is empty by default, listed by `config print` and documented in `config.example`.

Kept (`tests/boardseam.sh`, section "the subject's scope"): the board subject opens with `SALA_DEFAULT_SCOPE`, else the first word of `SALA_SCOPES` (leading blanks ignored); with neither, the filing is refused before anything is sent, with a log line and an error naming `SALA_DEFAULT_SCOPE`, and the question stays parked for the sweep.

Not checked: the clean-text scan runs only on a machine that has its deny source; the web part is skipped when the machine has neither `web/.venv` nor `uv` (the web CI job runs the app's own tests).

### `tests/retire-verbs.sh` (new, 108), `tests/retire.sh`, `tests/retire-own.sh`, `tests/tmux-exact.sh`, `tests/side.sh`, `tests/lanes.sh`, `tests/models.sh` (`sala retire` split into `retire`, `close-shell` and `forget-row`, Sun Nov 1st 2026)

What it is: `sala retire NAME` did three jobs (end a Claude session, close a plain shell, drop a leftover row) and guessed the session from a registry name or a prefix, with one `--force` for two unrelated bypasses. It is now three verbs with exact names and one flag per guardrail: `retire` (a Claude session; `--id` for a conversation; `--busy`, `--skip-writeup`, `--self`, `--leave-items`), `close-shell` (no Claude in it; `--busy`) and `forget-row` (the session is gone). `sala op` queues all three.

Kept: `tests/retire-verbs.sh` on a private tmux socket and an isolated HOME with the compiled fake claude and a stub for stackshot's items call: each verb's refusals name the verb that does the job, dry and real, with nothing touched (state compared before and after); `--force` refused by all three, naming both new flags; `--busy` skips only the idle check and `--skip-writeup` only the side gate; the items check against a stub that answers items (a mover's counted, a needs-only and a held one not), none, a failure, a hang, garbage and no client, refused with the ids or the reason and overridden by `--leave-items`, in the dry run too; `--id` resolving through the registry; self-retire refused without `--self` and done with it, with no /exit typed into its own pane, also through the queue (refused at queue time without `--self`, queued with it, the marker carrying it) and for `--id` at run time (the op's asker; with `--self` the runner waits for the asker's turn to end, `SALA_RETIRE_SELF_WAIT`, and refuses a pane that stays busy); `--self` from a pane that is mid-turn passes the idle check while a dialog, a child process or another busy session still does not; `close-shell` and `forget-row` dry and real (the session, the map, lane and model rows, the snapshot), the master, the RC session, the caller's session, a shell still running a child and a live name refused; the queue accepting both new verbs with the words rules, the flags reaching the marker, and a no-words call refusing every bypass flag and `--id`. The older suites kept their cases, moved to the new verbs and flags: registry-name lookups became `--id`, the orphan-row cases became a retire refusal naming `forget-row` plus a `forget-row` run, and the exact-target cases of `tests/tmux-exact.sh` run through `close-shell`. `tests/lib.sh` sets an empty-items stub so no suite reaches a real stackshot.

Left out: the real stackshot client (the stub answers in its shape; `docs/stackshot-contracts.md`, interface 25).

### `tests/notice.sh` (new): `sala notice` and the two hooks that deliver it (`lib/notice.sh`, `lib/notice.py`, `hook post-tool`, `hook prompt`)

What it is: a one-time line every live session sees at its next turn, with no relaunch. The suite is plain bash against an isolated HOME: no tmux, no claude, the hooks fed the JSON a settings.json hook gets on stdin, the live sessions registry rows that name the suite's own pids.

Kept: add / list / drop (`--from` required; the text one line of at most 400 characters; `--until` as an epoch, a span or an ISO time; a past or bad one refused; a refusal stores nothing; ids never reused); delivery once per session through both events (the two JSON shapes and the prefix; a second call silent; a session that had it through one event not shown it through the other); two notices in one block oldest first, a later notice alone; a session that started after the notice (the CLI's registry row, then sala's session registry) shown nothing and marked seen; a dropped notice and an expired one never arriving; a subagent's tool call (`agent_id`) delivering nothing and using nothing up; the two fast paths (no notice file, a notice this session has seen) starting no process, proved with an empty PATH and, where `strace` exists, by the one `execve`; a malformed payload, a bad session id, an unusable delivery folder, a garbage notice file and a lock that cannot be taken all silent with exit 0; prune (expired out, a gone session's file out after a day, every file out once no notice is left).

Left out: the settings.json registration of `hook prompt` (provisioning's, another repository), the watch tick's call of `notice prune` (one line, the same verb the suite runs), the wording of the help text beyond the two phrases the snapshot also holds.

### `web/tests/test_card_figures_proportional.py` (new, 5; a lone figure on a card has proportional digits, Sun Nov 1st 2026)

What it is: the Overview's lone figures (the spend and usage cards' `.c-v`, the phone strip's chips, the tabs' counts) were set in tabular digits, which gives a narrow "1" a full-width slot: a card's "$1.11" read as spaced out. They are now proportional; tabular digits stay where numbers line up in a column (the quota rows' percents, the models' and sessions' amounts and shares).

Kept (headless Chromium, else skipped; cards drawn from stubbed answers): the computed `font-variant-numeric` of each class at 1280 and 390 px wide and on the bedrock lane's details page (proportional for the lone ones, tabular for the columns); and the bedrock figure measured against itself, "1111" narrower than "0000" when the page's font has narrower digits (it says nothing on a runner whose font has none).

Not checked: how the tabular columns look beyond their computed style.

### `web/tests/test_search.py` (new, 41), `web/tests/test_search_api.py` (new, 22), `web/tests/test_search_ui.py` (new, 8), `web/tests/test_schedules.py` (the tab list) (the Overview's Search tab, Sun Nov 1st 2026)

What it is: the Search tab finds a word in the Claude Code transcripts on the machine (`web/src/sala_web/search.py`, `GET /api/search`, `static/search.js`). A wrong answer costs a search that reads a file the client named, a match under the wrong agent or a dropped one, a search that never says it was cut, or a page that writes anything.

Kept: over a fixture tree of fake transcripts (its own temp folder, locked while the test runs and removed pass or fail): the query's words and phrases, the range (hours, dates in the page's zone, files older than the range never opened, a file over 1 MiB entered at the range's start), each content box and each agent box and the counts beside them, hook and system notices left out, the snippet's marked parts (emoji included), results keyed on the permanent id across a `/clear`, a rename and a subagent and shown by the current name, the role filled from the registry, stackshot's answer, an alias or `keeper`, else the unknown bucket, an unregistered transcript, a corrupt registry, the 200 cap and its flag, the 20 s deadline (an injected clock), only regular files read, and a digest of the tree unchanged after a search. Through the route: the answer's shape and its size, the switch defaults, hours and dates, sixteen bad requests each a 400 with a sentence, no parameter reaching the file system, a third parallel search a 429, GET only. In headless Chromium (else skipped): the tab and its controls and defaults with no call on open, a real Enter searching, the result rows and counts, a box or chip re-searching, the thinking note, the dates, a result opening the chat with the entry outlined, a snippet with `<img onerror>` staying text, the arrow keys cycling the three tabs, and no sideways scroll at 390 px. `test_schedules.py` now expects the third tab.

Not checked: the click-through for an entry older than the chat's loaded tail beyond its status line; a search over a months-long history.

### `web/tests/test_search_ui.py` (+2: the results page's own query box, Mon Nov 2nd 2026)

What it is: the Search results page has a query box of its own above the When, Agents and Content switches (`#se-query`, `static/search.js`), because on a wide screen the sidebar's box is hidden until the sidebar opens. A wrong answer costs a box that is missing or empty on a reload, a new query that drops the filters, an address that does not follow (or adds a history entry per search), or a box that makes the phone page scroll sideways.

Kept: in headless Chromium (else skipped), over the fake session's transcript: the box is in the markup above the switches and is shown, looks like the sidebar's box (same height and radius) and is filled from the address; an Enter on blanks does nothing (no search, the address unchanged, as in the sidebar's box); an Enter on a new query with tool calls ticked and 1 h picked searches again with exactly those filters, rewrites the address in place (the history length is unchanged), trims the query, and the sidebar's box follows; a switch afterwards keeps the new query; a reload fills the box again; Back leaves the page. At 390 px: the box takes the form's full width, is 44 px high with 16 px type, the page does not scroll sideways, and Enter there searches again.

Not checked: an Enter while an IME composes (the handler returns on `isComposing`; no input method in the headless browser); Ctrl+K on the results page still goes to the sidebar's box, which the existing key test covers.

Changed (the default window is 6 h, Mon Nov 2nd 2026; +2 parametrised cases): a search started from the sidebar's box now opens at 6 h instead of 1 h. `test_a_search_from_the_box_opens_at_6_h_and_an_address_that_names_its_hours_keeps_them`, at 1280 px and at 390 px: Enter in the box leaves only the 6 h chip pressed, `hours=6` in the address and in the `api/search` call and `6 h to` in the summary; an address that names `hours=1` (an old link) opened fresh keeps 1 h in the chip, the address and the call. The tests that clicked the 6 h chip to change the window (a reload and a shared link, the results page's own query box) click 1 h now, and the shared defaults (`DEFAULTS`) and the chip row expect 6 h.

### `web/tests/test_search_ui.py` (+4: the sidebar's box opens its results in a new tab, Wed Nov 4th 2026)

What it is: Enter in the sidebar's search box opens the Search results page in a new browser tab (`static/app.js`, the box's submit handler; `search.js` `boxHash`), so the page and chat in the tab it was typed in are not replaced. A wrong answer costs a search that still replaces the page, a new tab that does not open the search, a search that does nothing where the browser blocks the tab, or a new window in the installed app or on a phone, which lands in Chrome's in-app view outside sala.

Kept: in headless Chromium (else skipped), at 1280 px: Enter opens one new tab at the same address whose hash holds the search with the box's defaults, showing its three results, with `window.opener` cleared; the first tab keeps its chat, scroll, half-typed message, address and history length, made no search call and has the box blurred; a blank Enter opens nothing. At 390 px and in the installed app (the `display-mode: standalone` query answered true in the page, as in `test_back_button.py`): the results open in place, `window.open` never called, no second tab. Where `window.open` answers null: the results open in place. The tests of the results page itself, which start a search through the box, run with `window.open` answering null (they test the page, and the box's new tab is tested on its own), so they follow the in-place path.

Not checked: a real browser's pop-up blocker (headless Chromium lets the tab open from a real key press; the null answer is simulated), a real installed app.

### `web/tests/test_md_images.py` (new, 15; a markdown image of a local file shows inline in the reply, Mon Nov 2nd 2026)

What it is: an agent shows the owner an image by writing `![caption](/abs/path.png)` (or `~/…`) in its reply, and the chat draws it at that spot through `GET /api/md-image/<sid>/<uuid>/<i>/<n>` (`web/README.md`, *What it can and cannot do*, "A markdown image of a file on this machine"). A wrong answer costs a mock-up the owner sees as a path, or the one loss that matters here: a URL that makes this machine read a file the reply never named (the route has no path parameter; the n-th image is read back from the transcript), a link out of the allowed roots followed, a hidden or secret-named folder served, a broken-image icon where a refusal should say why, a page that scrolls sideways at 390 px, or an http image that stopped loading because local paths got their own handling.

Kept: extractor (local images found in order: `<…>` with a space, a title, a `~/` path, parentheses in a name; http, `data:`, `//host`, relative paths, links, fenced and tilde-fenced code and code spans left out); parser (one `localImages` entry and URL per local image, none for a reply without one or a user's text, the http image none); `find_md_image` (the n-th image of the block at i, nothing for a fenced one, a block with none, a missing block, a negative n, a user line, an unknown uuid); `check_image` (png, jpeg, gif served; a dot-folder and `secrets/`, a text file, a script under a `.png` name, a missing file, a link out, a link to a directory outside, a path outside, an svg and a too-large file each refused with its reason; `~` against `$HOME`; `read_sent_image` still answers the file or nothing); a png under the default roots, in `/tmp/claude-<uid>` (skipped when that folder is absent); route (type, `nosniff`, the sandboxing policy, private caching; each unsafe image a 404 with its reason as JSON; past the last image, a fenced one, a user line, a missing block or transcript, a negative n, a query string or path segment carrying a path, and a transcript that names a file outside the roots all 404); page, headless Chromium at 1280 px and 390 px: the image inline in the reply with the tool folds hidden, lazy, at its width and inside the column, no sideways scroll, a link to the full image in a new tab with `noopener`, the caption under it, in order between the text around it; the dot-folder, text-file, missing and symlink cases each one muted "image not shown: <reason>" line with the caption and no image element; an http image still drawn from its URL and untouched; `~/` drawn; an image in a code block left as code; an image that will not decode shows its line, not a broken icon. Every temp folder is made by a fixture that locks it (flock) and removes it in `finally`; the local web server for the http image is shut down in `finally`.

Not checked: a real phone (the width is emulated), the tap opening a new tab, the production service, a file over 15 MB end to end (the cap is checked in `check_image`), and a narration line (it gets the "reply does not name this image" line from the page, not tested in a browser).

### `tests/mq.sh` (new Nov 2nd 2026; the same day: bisect, the merge push, statuses, pause and resume; 285 checks in 35 scenarios; Nov 2nd: the start race; then 312 checks in 37 scenarios: a PR's own failed checks and a conflict with a moved main are refused; then 327 checks in 38 scenarios: the driver re-executes itself when its code changed; then 415 checks in 47 scenarios: replay, the queue on a practice branch from a file; then 417 checks: mode on is open, `ON_OPEN` is `True`; then 484 checks in 56 scenarios: chain mode; then Nov 4th, 485 checks in 52 scenarios: group mode removed, the chain is the only mode)

`lib/mq.sh`, `lib/mq/*.py`, `docs/mq.md`. Kept because the queue will decide what reaches `main`: a lost PR, an entry pushed twice, a driver that never leaves or a call to GitHub nobody counted would each cost more than the queue saves. `tests/mq_scenario.py` builds a locked temp folder (removed in a `finally`, also on SIGTERM) with a local bare repository as origin and real git over it, a fake `gh`, a fake `salamander` (the poller's reader) and a fake `systemd-run` on a fake PATH that answer from files and log every call, and a fake CI that is a function of the pushed tree. The CLI runs through the real verb; the driver runs as the unit would. A crash is injected with `MQ_CRASH_AT=<phase>`; nothing is killed, there is no tmux.

Checked: a PR passes, origin's `main` is untouched, the entry head is one merge commit over `main`, the branch is deleted, and the calls are asserted from the fakes' logs AND the entry record (poller file going twice then finished: 2 GraphQL and 1 check-runs read, 3 poller reads; no poller file and a run pending twice: 3 check-runs reads, the second sent with the ETag and answered 304); git over the remote is counted apart (1 clone, 3 fetches, 2 pushes, 1 ls-remote); a failing entry fails its PR alone and the PR behind it is tested; the newest run of a check wins; a conflict with the PR ahead or with `main` ejects that PR and the entries behind it go on; the snapshot-only conflict hook (resolved; a failing hook, and a conflict on another file as well, eject); a closed, merged, draft, wrong-base and missing PR are ejected at their GraphQL read; a head that moved after the read is ejected; `inflight_max` from main's config, a PR's own copy ignored, the default six (seven PRs, six in flight); an invalid repo config blocks (journaled once, the driver leaves, status, wait and doctor say why) and clears when fixed; GitHub failing (retried, every attempt counted, then given up); no verdict in time; a crash at each of the seven phases, with the lock free, the branch on origin or not, and a fresh driver finishing with one GraphQL read to build and one to recheck, one push of the branch and no invented entry (and a crash with two entries in the chain, both finished); a stale branch of the entry's name; the driver lock (a second driver leaves, `add` starts none while it is held, two `add`s racing never make two drivers, and an `add`, `wait` or `resume` whose `systemd-run` loses the race for the unit says "driver running" and journals `driver_start_raced`, while a failure with no driver alive still says "NOT started"); drop before and after an entry is built; `wait` exit codes 0, 1, 2 and 3; the modes (no file and a bad file refuse; `on` is accepted, and refused only by a copy of the code with `ON_OPEN` set `False`); `status`, `status --json`, the repo from the origin URL, `doctor` (a stale queue branch, a stray worktree, work without a driver); the atomic write and the state path. Not checked: the real `gh`, GitHub and systemd (the fakes stand in).

The merge push, statuses, pause and resume, against the same fakes plus a fake statuses and comments endpoint of `gh`: mode on, reached by queueing in shadow and rewriting the host file (`mq add` accepts it too): three PRs merged in line order, `main` the last entry's head (a fast-forward over the old tip, merge commits in order), six statuses under the context `merge queue`, the call counts of each record; main moved after the verdict (the entry stale and rebuilt once, the entry behind it restacked and not counted, both merged), a PR whose head changed, a PR closed, a PR dropped after its entry was built; a crash after the push (merged with no second push, the entry stacked on it merging next); the deploy lock held (waits, merges when free); a push to main refused by the remote three times pauses the queue and `resume` merges the same tested entry; pause and resume (nothing started, nothing pushed, status/doctor/json say so); a failing status write not stopping the merge; a conflict notifying only in mode on; the rebuild limit. Not checked: flaky reruns, the sweep, the real `gh` and GitHub.

Refusing a PR (`pr_required`, *Which PRs join and stay* in `docs/mq.md`), against a fake GraphQL answer that lists the checks of each PR's head: failed, cancelled and timed-out checks refuse a PR at the join with `refused: a check failed: <name>=fail|cancel` while pending, skipped, neutral, a re-run that passed and the queue's own `merge queue` status do not (and the entries hold only the PRs that were not refused); `pr_required = ["suites"]` holds only that check against a PR; a check that fails while the entry is tested refuses the PR before the verdict counts in shadow (the others stay `tested`, `recheck_ejected` journaled) and in mode on (failure status, ONE comment, the entry stale and rebuilt without it); a PR that merged clean into its entry but conflicts with main after main moved is refused as `refused: conflicts with main (<files>)` in shadow, one that still merges and a snapshot-only conflict the hook mends are not, and mode on meets the same conflict in the rebuild; `pr_required` is validated like the other repo keys.

The driver and a release (`sc_code_reexec`, the driver run from a copy of `lib/mq` in the scenario's folder): unchanged code never re-executes (one `driver_start`, no `code_changed`); a file changed while an entry is testing is journaled once as `code_changed` naming the file, and the driver starts again as a re-exec with the same PID and driver.json, `driver.lock` never free from the change to the second image's start (sampled), the entry finishing under the new image with each phase entered once, one push of the branch and one deletion, two GraphQL reads, no `driver_busy`, no invented entry; new code that fails to import ends the process with the error, one `code_changed`, no loop, the lock free and the entry still in `testing`, and a fresh driver finishing it from its record.

The chain (`sc_chain_*`, *The chain* in `docs/mq.md`): the repo file's key and its defaults (a chain, six in flight, a bad `inflight_max` an error); three PRs stacked and merged in order (each entry on the head of the one ahead, `main` the last head with the merge commits in line order, all three pushed before the first merged, three in flight, the pending status naming what it sits on, two GraphQL reads a PR); the middle PR failing, with entry 1 held unmerged by the deploy lock: failed alone, the entry behind it restacked (not counted as a rebuild) and built again on entry 1's head without the failing PR, one failure comment, the other two merged in order; the first PR failing sending both behind it back; a conflict with the PR ahead ejecting it by name and the next PR landing on the one before; a dropped PR ending its entry at once; `inflight_max = 2` holding two entries testing (a fake CI kept open by a file) and the third starting only after the first is done, the default of six holding six of eight; shadow merging nothing. Not checked: the real `gh` and GitHub.

Group mode removed (`sc_chain_config`, `sc_retired_keys`, `sc_legacy_group_state`, Nov 4th 2026): `queue_mode = "chain"` and an empty file are silent; `group_max` and `bisect` are not errors, each is one warning that names the key and says to delete the line, they are not kept in the config, the queue still tests the PRs one entry each with `inflight_max` beside them honoured, the journal has `repo_config_warning`, `mq doctor` warns and exits 1 and is all ok once the lines are gone; `queue_mode = "group"` blocks the queue with a message that names the fix (the PR waits, nothing is fetched, status says BLOCKED, wait exits 2, doctor exits 1) and the next driver builds once the file says `chain`; a replay file's rules take the retired keys without an error. Records an older version left, written by hand into a real state folder: a two-PR group pushed and testing, a finished group in the history and a PR waiting behind (the driver retires the old record as `restack`/`stale`, journals `legacy_group_retired`, builds each PR again as an entry of its own numbered after the history, counts no rebuild, cleans the branch and worktree, leaves the finished record, and status and doctor work on the mixed history); a bisect parent with two halves (all three retired, the PRs built again); a two-PR record in `merging` whose head was already in `main` (merged as it always was, no second push, nothing retired, nothing rebuilt).

Replay (`sc_replay_*`, 9 scenarios, *Replay* in `docs/mq.md`): with the host key `replay` the PR facts come from a file though the fake GitHub says MERGED or CLOSED (the PRs join, no GraphQL call, `replay_facts` journaled twice per entry), origin/main's rules file may be garbage and is never read, heads are fetched by sha (one on no branch of origin, one that `refs/pull/N/head` does not hold) and the entry tree shows it; a retired `group_max` in the rules is accepted; a PR the file lacks is `pull request not found`, a recorded MERGED, draft or failed check and a sha origin lacks eject with their reasons; a base outside `practice/` or a prefix outside `queue/practice/` blocks the queue before anything is fetched (status, wait, doctor say so); every kind of bad file (unknown key, bad rules value, short sha, bad bucket, not JSON, missing, relative path) is refused with its message; mode `on` is refused, no mode is shadow, `merging()` is false, `mq_git` refuses a push or delete outside `queue/practice/`; a run with a failing PR, a refused PR and a conflict makes no status or comment call and, by a `pre-receive` hook on origin, touches only `refs/heads/queue/practice/` refs; the unit is `mq-<slug>-<run>-<case>` for add, wait and resume; `ci = skip` ends at `built` with no push and no GitHub call, the PRs `tested (CI not run)`, wait exit 4; `mq doctor` of the real queue ignores a `queue/practice/` branch and a replay's lists only its own prefix.

### `web/tests/test_project_groups.py` (new, 9), `test_new_session_projects.py` (+1), `test_new_session_scope.py` (changed): a project is a page whose type is `project` (Mon Nov 2nd 2026)

What it is: the sidebar's project groups and the New session form's project box both read one field, the page's frontmatter `type`. A group exists only for a `type: project` page; a session whose agents map sits on a sub-page or a note page is grouped under its nearest parent by slug prefix that is a project, and one with none stays in `Unregistered`. The box lists only the rows of stackshot's project list whose `type` is `project`. What a wrong answer costs: a note page or a sub-page growing a group of its own next to its project, a project's sessions vanishing into `Unregistered`, the sidebar and the overview disagreeing, an empty sidebar when the pages checkout is missing, or a note page offered as a project to start a session in.

Kept: `nearest_project` (the page itself, one and two levels up, the nearest wins over the topmost, a note is not a prefix match, the directory alone is no page); `group_sessions` and `overview_rows` with a type table (a `type: project` page groups, a sub-page's and a deeper note's sessions roll up to the parent, a page with agents but no project type gets no group, a page the checkout lacks is `Unregistered`, front agents first inside a rolled-up group, the session's own `project` is the group's); without a table the roles' projects are the groups, as before; a side session's record rolls up too, and one that leads to a note page with no project above it stays `Unregistered`; `page_types` and `PagesCache.types()` over a made-up pages folder (quoted and capitalised types, a page with no frontmatter, a redirect stub, a README, a folder outside the page directories) with the form's own page list unchanged, and `None` for a missing or unset checkout; the two endpoints (`/api/sessions`, `/api/overview`) over a made-up pages folder, and with no checkout; `clean_projects` drops a note, a sub-page type, no type and a null type, listed or hidden, keeps `Project` in any case. Changed: the two browser tests that expected a disabled "note page, cannot be listed" row now expect no such row (the fake stackshot still sends one); the retired-project test gives its rows `type: project`.

Not checked: the real pages checkout, the real stackshot's rows, a project created a moment ago whose page has not reached the checkout yet (it shows as `Unregistered` until it does).

### `tests/prwatcher.sh`: new, 41 (Wed Nov 4th 2026)

The PR-watcher cleanup job (`lib/pr_watcher_cleanup.py`, `systemd/sala-pr-watcher-cleanup.{service,timer}`, *PR-watcher cleanup* in `docs/units.md`). Kept because the job
DELETES things on the signed-in Claude account on a timer: a task deleted that was not finished (a recurring routine, a watcher whose pull request is still open, another
account's task), a creator asked twice, or a pass that deletes on the strength of a failed lookup would cost work that cannot be got back. `tests/prwatcher_scenario.py`
runs the job as its own command in a locked temporary folder (removed on every exit, pass or fail) against a fake API (a local http server on 127.0.0.1 serving the task
list in two pages, the sessions and the delete), a fake `gh` that answers a pull request's state from a file and a fake message command that logs what it was asked to
send; the clock is injected (`SALA_PRWATCH_NOW`), so 24 h costs nothing. Checked: a fired-and-off task of an archived, a missing, a not-connected and an unnamed session is deleted
at once with a log line carrying the id, session, pull request and reason in the `SALA_TZ` zone (local time when unset), and nobody is messaged; a second pass finds nothing; the requests carry the bearer, the beta header and
the organization, and the token is in no log, state file or output; a live creator is asked once (the message names the task and says when it goes anyway), nothing is deleted
at an hour or at a minute short of 24 h, nothing is asked twice, and the task goes just past 24 h from the ask; a creator that deletes it first leaves no call and no record; a
message that cannot be delivered is tried again next pass and, never delivered, the deletion comes 24 h after the task was first seen done; a not-yet-fired task with a merged, a closed or a
merged-and-closed pull request, or an archived session, goes, and one with an open pull request (alone or beside a merged one) stays unlogged; an active task is untouched; a task switched off
that never fired and another account's task are left alone and said once (the next pass adds no line); a recurring routine and a one-time task that names no pull request are not even logged;
a failed list, a failed session lookup, a pull request GitHub cannot answer for and a failed delete each leave their task and exit 1 while the others go on (and the failed delete is tried again next pass);
a delete answered 404 counts as done; a list in two pages is read whole; `--dry-run` deletes, asks and writes nothing; an expired token or no sign-in touches nothing and calls no API;
`--only` looks at just the named task; an unknown flag or a bad `--only` is usage, exit 2; the job leaves nothing in `TMPDIR`. Not checked: the real API, the message reaching a real cloud session through stackshot, systemd running the unit.

### `tests/machinefollow.sh`: new, 58 (machine-follow, Wed Nov 4th 2026)

What it is: machine-follow (`lib/machine-follow.py`, the four units `systemd/machine-follow.{path,timer,service}` and `machine-follow@.service`, *machine-follow* in `docs/units.md`) is the
dispatcher that keeps the machines it drives level with the machine it runs on: the stackshot and salamander commits, the Claude CLI, an installed knowledge-base build. Its test
is in the scenario style this repository uses for a lib script (`tests/machinefollow_scenario.py`, plain asserts, a locked scratch folder
removed in `finally`). Kept because a wrong answer here costs the owner a machine that is not brought level when something it follows changed, or one brought level every 10 minutes
(an ssh each time), a slow machine holding up a quick one, a state file that claims a follow that did not happen (the machine then looks current in the Machines tab and is not
followed again), or a failing step read as a skip.

Checked, under made-up machine names: the data file (the shape, nine kinds of wrong entry each named in one line with exit 2 and nothing written, a `before_command` that is not a
list of strings, the setting that finds the file in its three forms and its order, a missing file one line and exit 2); the units against the script and the data (the four paths the
path unit watches, the timer, the `ExecStart` lines, no `[Install]` on the template, `TimeoutStartSec=3h` above the largest step plus the settle wait); the first run (every
machine in file order, each with its own limit, the state in the `SALA_TZ` zone); nothing changed runs nothing; each followed thing (stackshot, salamander, claude-cli, a knowledge-base build) making only the
machines that follow it due; the catch-up; `--host`, `--force`, `--dry-run` (nothing started, run, probed or written) and the wrong host (64); one machine's lock; the dispatcher
starting only due instances and running no step, probe or wait, and leaving an active instance alone and a machine held back by its retry; the real `systemctl --user is-active` and
`start --no-block` calls against a stub; the settle rule (60 s still, ten minutes at most, per knowledge-base follower only, the line naming the host it runs on); 75 as a skip, an
unreachable machine as a skip, any other code as a failure of its own instance only; the state file and the attempt file (success writes one, a skip or failure keeps the old
one; `retry_minutes`); both steps of one entry always running, the worse result, the first capped at 20 minutes and by the entry's limit; the real runner (`~/`, a kill at the limit
with its whole group, exit codes, 127) and `main` with it; the real fingerprints against throwaway git repositories and files; the real script as a command with an isolated HOME
(the data file found by the config line, a missing one, the wrong host, a dry run writing nothing).

Not checked: a real ssh probe or step, a real systemd run (the units are read as text and `systemd-analyze` is not run), the real machines, the real data file (it is the
owner's, outside this repository, so the largest `timeout_minutes` against the template's `TimeoutStartSec` is checked here against a made-up 150 minutes only), the step scripts
(they live beside the data file), and the web UI's reading of the records.

### `web/tests/test_machines.py` (new, 34; 22 since Sat Nov 7th 2026; 27 since the checkout rule below) and `web/tests/test_machines_ui.py` (new, 11; 10 since Sat Nov 7th 2026): the Overview's Machines tab (Wed Nov 4th 2026)

What it is: the third Overview tab shows the version each machine runs (`web/README.md`, *Machines*; `machines.py`, `GET /api/machines`,
`static/machines.js`, `static/machines.css`). It reads stackshot's state files, the fleet names file and machine-follow's list and records, read-only, when the tab opens and
on Reload. Kept because the tab shows the owner which machine is behind, so a wrong answer costs a card that says "latest" for a stale machine, a failed
update that does not show, a machine that "follows" something it does not, or a tab that turns into an error page where a file is missing; and, on a phone, a page that scrolls sideways or a Reload that covers the last tab. `conftest.py` gets an autouse fixture that points the four new settings
at places that do not exist, so no test reads this machine's real state. `tests/machines_world.py` builds the made-up fleet (a few machines with made-up names) in
a temporary folder that is locked (flock) while the test runs and removed in `finally`.

`test_machines.py` (no browser): the order (the publisher, then the fleet by letter, then the ssh hosts, no name twice, a name only in one list still shown, the fleet's own name
beating the names file); the rows (latest, update, offline and unknown by the numbers and the puller's state; an ssh host that answers wins, one that does not lets the fleet's
row win and only fills the packages the fleet does not know; a host that never answered is one offline row); the alerts (a failed setup, the latest attempt of each package
only, a secret-looking `NAME=value` in a reason starred, a malformed machine view with none); a box's own `stackshot checkout` judged by where it is (five tests added, Sat Nov 7th 2026: the failed attempt red while the box's
commit differs from the server's and gone when they match, upper case and a malformed or absent box commit, the server moving on turning it red again, the server's commit unknown so the last attempt decides, another package's failed attempt and the setup run
unchanged, a `reload failed` attempt of the commit the box runs now staying red while one of an older commit clears, the server's commit read from `clients/advertised-commit` and every other content of that file, an oversized one and a missing one meaning unknown, and the whole card
going red and clear by itself over made-up files in the locked temporary fleet, the tab writing nothing). Kept because a card that stays red after the box has caught up costs the owner a hand fix that is not needed, and one that goes green while the new code does not load hides a broken box; the last line (every kind, an unreadable list, `run_on`, a name that could
escape the state folder not read); degrading (a missing versions file, nothing configured, a file over the size cap, each making the tab "no reading", the footer
blank); the answer holding no token, session id or path and no `runners` key; the footer's age, the versions file's own time; the route (200 and `no-store` even with nothing to read, GET only, nothing written); the settings' derivation from `stackshot.toml`
and the environment; and the page wiring (the tab, the panel, both files with the cache-busting version, the hash in `app.js`) with every `machines.css` rule scoped to the panel.

`test_machines_ui.py` (headless Chromium, else skipped), at 1280 px and 390 px against the made-up fleet through the real app: the cards, their rows, the failure lines and the
marked card; the footer; no button, field or form in
the panel and no runner section; three columns of cards on a desktop and one on a phone; no sideways scroll at 390 px and nothing wider than the screen; the three tabs and the icon-only Reload in one bar, each tab 44 px tall, the Reload beside the last
tab and not over it; no read of `api/machines` until the tab opens, one on open, one on Reload, one on every later open, and none by itself; the arrow keys cycling the three tabs and Back
returning to the Machines tab; a missing versions file, a "No reading yet" line and a blank footer; a failed read keeping the last answer
with a note; a machine name that carries `<img onerror>` staying text; the age words (run in node). `test_schedules.py` follows: its
tab-list assertion expected a tab that no longer exists and now expects the Machines tab. `test_search_ui.py` follows too (the Overview has three tabs: the markup, the links and
panels, and the arrow keys walking Agents, Schedules, Machines and wrapping).

Not checked: the real stackshot files on a production box, a real phone (the width is
emulated), the page behind the login proxy, and another machine kind's update logic (out of scope here).

### `web/tests/test_schedules_swr.py` (new, 7), `web/tests/test_schedules.py` (+13, 3 changed): the Schedules tab opens at once from the last reading (Wed Nov 4th 2026)

What it is: `GET /api/schedules` no longer asks systemd on every open (one `systemctl cat` per unit); it is served the way the lane cards
are (`swr.py`, `schedules.SchedulesCache`): the last reading at once, a new one read in the background once it is 30 s old, the page following up while the answer says
`refreshing` (`web/README.md`, *Schedules*). The unit files are read with one `systemctl cat` per scope. Kept because the tab is opened to look at, so a wrong answer costs a tab
that waits again (the reason for the change), a read started per request (a page polling would pile up systemctl runs on the machine), a failed read that blanks the table or
puts an exception's text on the page, a unit file cut at the wrong place (a job shown with another job's lane or schedule, or flagged for a lane it has), or a refresh that
redraws the table under the owner's hand.

Kept (`test_schedules_swr.py`, a fake collector that counts its reads, can be held on a gate and can fail; no systemd, no process, no file): the first request after a restart
answers `pending` + `refreshing` at once and the read runs; a later request gets the stored reading in under 100 ms while a held read runs behind it, two requests start one read,
and the new reading replaces the old one when it lands; a reading inside its 30 s is not read again (twenty requests, one read); a failed read keeps the last reading (same
`fetchedAt`) with `error` and `errorKind`, without the exception's text, waits before the next try and heals on the next good read; a first read that fails stays `pending` with the
error; `?fresh=1` makes the reading due at once and still answers at once, and a second one while it runs starts no other; the reading is memory only (no file in the state folder).
`test_schedules.py` (the fake machine's `systemctl cat` now takes several units, prints a symlink's header as `# <file> -> <target>`, adds drop-ins, skips and fails on a missing
unit): four timers are read with one `cat` call; the rows from the batch equal the rows from one `cat` per unit (the fallback, with drop-ins, a note, a plain file, a rendered
unit); a unit the batch does not return is asked alone and the others keep their text (their lane and project, the missing one flagged); `split_cat` cuts at each unit's own
header, a drop-in's header and a comment that looks like a header do not start a unit, a unit with no header is left out; `cat_units` asks alone for a unit without a unit file
and for one that shares another's file, and reads a unit named twice once. In headless Chromium (else skipped; the answers of `api/schedules` are a stub that hands out a list in
turn): the stored reading is drawn on the first answer and replaced when the second lands, and the page then stops asking; a `pending` first answer shows *Reading the timers…*
and then the table; a new reading keeps the sort and the *Flagged only* box (the filtered rows are the new reading's) and the scroll position; a repeated reading (same
`fetchedAt`) leaves the very same row nodes in place; Reload asks for `?fresh=1` and shows the new reading; a failed refresh keeps the table and says so without the error text;
leaving the tab ends the follow-up. Changed: `test_the_api_returns_what_the_collector_returns` waits for the background read and expects `fetchedAt`; the static check of the page
now allows the one follow-up timeout (cleared when the tab closes) and no interval, and `load(true)` for Reload; `test_the_api_runs_the_collector_at_each_request` is gone (nothing
is read at each request now; `test_a_reading_inside_its_ttl_is_not_read_again` and the `fresh` test take its place); the packaged-unit test checks that no `cat` names a hidden unit.
A check that broke on purpose: redrawing on every answer fails the repeated-reading test.

Not checked: a restart of the real service behind the proxy and a real phone (the width is emulated).

### The app icons are stackshot's recipe: `web/tests/test_installable.py` (+6), `web/tests/test_theme_contrast.py` (1 changed, 1 new) (Wed Nov 4th 2026)

The app icons were a white `>_` on the sala orange; they are stackshot's now: its dark tile (`#1f1f21`) with its orange (`#f0a06a`) as the `>_` glyph, at stackshot's heavy line (4 of 32). A wrong answer
is an icon that is not the pair of stackshot's (the old orange or white left in a PNG or a tab icon), a launcher icon with a transparent corner where it must be opaque, or a glyph whose
underscore runs into the chevron at 16 px. Kept (`test_installable.py`, the PNGs decoded with the standard library alone, since Pillow is not a dependency): the generator's two constants read from
`tools/make_icons.py` are `#1f1f21` and `#f0a06a`; each of the four icons has the stated size, opaque corners for the two full-bleed ones (the maskable and Apple's) and transparent corners for the two
rounded ones, the tile colour at an interior pixel above the glyph, and a few percent of its pixels near `#f0a06a`; both inline tab icons hold the generator's tile and glyph colours and the stroke weight of 4.
Changed (`test_theme_contrast.py`): the old-palette check no longer lets `#d97757` stand in the two pages (the tab icons do not hold it any more), and now also looks for each old colour as it is written
inside a data URI (`%23d97757`); new, the two tab icons each hold the tile and the stroke colour and no white stroke. Not covered, and why: how the glyph looks at 16 and 20 px (judged on a contact sheet
by eye: the underscore starts at x=18, not 17, so the heavier line leaves a gap), and a launcher's own mask (the maskable icon's safe zone is by construction in the generator).

### The accent and the links are the icons' orange, running stays blue: `web/tests/test_theme_contrast.py` +38 pairs, +1 test, 166 in all (Wed Nov 4th 2026)

The page's accent and links were stackshot's blue; they are the app icons' orange now (`#a34a14` light, `#f0a06a` dark; `--accent-text` white on the light one, the panel's dark on the dark one), and a
running runner on the Machines tab keeps a blue of its own (`--run`, `#1f5bc4` light, `#7fb0ff` dark). A wrong answer is a link, a ring or a count whose orange reads under 4.5:1 on a surface (the
tightest is the selected row in the light theme), words on an orange fill that cannot be read, a running runner that turned orange (a status mistaken for an action), or a `--run` that is the accent
or a lane's blue. Kept: the accent, the link and `--run` as text on every page surface and the selected row, in both themes (30 pairs, the link's one new), the accent and `--run` on their own 12% tints (8), 158 measured pairs in all, and
`--accent-text` on `--accent` as before; the accent, link, accent-text and `--run` values spot-checked in both themes; `--run` a blue (its blue channel the largest) and neither the accent nor a
lane's blue; the three Machines rules (the Running tile, the dot, the word) reading `--run` and neither `--accent` nor `--link`; the token sets of the two themes still equal (so `--run` is in both).
Changed: the front-badge test no longer demands that `--call` differs from the accent in the dark theme (the two are the same `#f0a06a` there; in the light theme they still differ), and the palette
spot check holds the new values. The browser tests that measure computed colours (unread count, header badges, lane pill, board items, For you, shell drawer, Machines, overview columns, chat links)
were run unchanged and pass. Not covered, and why: that orange reads as an action and blue as a status to a person (by eye), and an orange accent next to the
orange front badge and metered lane (told apart by place and shape, not by colour).

Update (Sat Nov 7th 2026): the `--run` token and the checks above that name it (its text pairs and 12% tint, the blue test, the three Machines rules) left with the Machines tab's runners section; the accent and link checks stay.

### One orange in the whole app: `web/tests/test_theme_contrast.py` +3 tests, 2 changed, the pair list one name changed (Thu Nov 5th 2026)

The orange is stronger and there is only one: `#ad4608` in the light theme and `#ec8a47` in the dark one, for `--accent`, `--link`, `--call` (the metered lane, the front badge's fill, a pending update),
`--role-front-text`, the `/v2` layer's copies of the accent and the terminal page's fallback. Before, the light theme had three near-oranges (`#a34a14`, `#a44d1b`, `#944312`) and the dark one a lighter `#f0a06a`. The app icons and the two inline
tab icons keep `#f0a06a`, and the amber statuses (`--busy`, `--warn`, the yellow lane) stay. A wrong answer is an orange left in a page file that is neither of the two (an old value in `style.css`, a rogue
faint orange in a rule, a copy in the `/v2` stylesheet, a hex in a script), the icons' orange outside an icon, or text on the orange under 4.5:1. New: every colour in the orange band (hue 15 to 40 degrees,
saturation above 40%, read from hex, rgb and hsl forms, 3- or 6-digit, and the `%23` form) in `static/` and `v2/` (css, html, js, py; the inline tab icons cut out first) must be one of the two oranges or an amber on the
allow-list by name (`#a16207`, the light theme's yellow lane, with its reason); both oranges and the allow-listed amber must still be in use (so a dead allow-list entry fails); `#f0a06a` appears in the two tab icons and `tools/make_icons.py` and nowhere
else; the scan itself is tested on `#f0a06a`, `#A34A14`, `rgb(240 160 106)`, `hsl(24 80% 60%)`, `#e82` and `%23c96442`, which it must find, and on a blue, `#e3b341` and a grey, which it must pass. Changed: the palette spot check and the accent
test hold the new values, and the "front and metered use `--call`" test no longer asks that `--call` differs from the accent (it is the same orange now). The light front badge on its 20% tint measured 4.10:1 with the new orange,
so its fill is the orange at 12% over the page now (4.61:1 light, 5.94:1 dark; the pair is named `--role-front-text on --call 12%`), in `style.css` and `search.css`, and the layout test holds the 12%. The other pairs hold: the orange as text
on the tightest surface, the selected row, measures 4.68:1 light and 5.50:1 dark; white on the light orange 5.74:1, the panel dark on the dark one 6.50:1. Not covered, and why: how the stronger orange looks to a person (by eye).

### The item count button, its sheet and the Overview's red count are removed: `web/tests/test_board_items_ui.py` rewritten (7), four files deleted (Thu Nov 5th 2026)

The item count button in the title bar, the items sheet it opens and the red count in the Overview's Agents
table (which opened the same sheet) are removed: open items are read on the board, not on this page. The New session form's board item picker reads the same data and stays (`api/board-items`, `board.py`,
`sdItemRows` in `app.js`); so do `foryou.py`, `/api/for-you*` and `test_foryou.py`, a stackshot interface whose page was inside the sheet. A wrong
answer is a leftover of the three on the page (a button with no sheet behind it, a count that opens nothing, a stylesheet rule or a history layer for a sheet
that is not there), a picker that lost its items with the sheet's code, or a header that folds Shell, Reload or the status badge for room a deleted button
no longer takes. Deleted with what they covered (`test_board_items_waiting.py`, 9 tests: the sheet's rows, waits and tags; `test_sheet_lists.py`, 8: the
three lists; `test_foryou_ui.py`, 12 and `test_foryou_hidden.py`, 2: the For you section and its hidden flag). Kept: `test_board_items.py` and `test_foryou.py`
(the server side, unchanged). New (`test_board_items_ui.py`, headless Chromium, 7 tests): the sources (markup, `app.js`, `sessions.js`, `shared.js`, the stylesheets) and the /v2 layer's rewrite of them hold none of the
button, sheet or count's names or classes; the one reader that stays (`loadBoard`, `sdItemRows`) is still in the script; a session with open items has no button in the title bar and its Agents table row no count, on `/` and `/v2/`; the sidebar rows carry no board count; the New session
picker still lists the items of the running sessions, newest number first, with the owner in brackets, and opens with them; and the page still asks for the board once a minute and not sooner. The module is still the shared harness
about 25 other browser tests import (`wait_for`, `stub`, the fakes). Changed: `test_back_button.py` (32 pass; the sheet-layer tests removed, the drawer's kept, an old
`{sheet: ...}` history entry read as no layer), `test_header_fold.py` (8), `test_header_hover.py` (7; the ⋯ menu alone), `test_header_layout.py` (38; the cluster
without the button, and the 360 px name room about 234 px, not 181), `test_new_session_page.py` (`placePopover` is gone), `test_v2_design.py` (the script pass
touches four anchors, not five). Also run, unchanged and passing: `test_v2_layer.py`, `test_v2_browser.py`, `test_theme_contrast.py`, `test_side_sessions.py` and the New session, sidebar,
header-menu, shell-drawer, search, unread-count, project-group and parked-session browser tests. Not covered, and why: how the bar looks without the button on a real
phone (judged on 360 and 390 px screenshots), and the unused `--waiting-text` colour variables, kept because `test_theme_contrast.py` still
measures them.

### The color tool: `web/tests/test_colortool_wiring.py` new, 30 (replaces `test_colortry.py`); `test_colors_combos.py` docstring only; `test_theme_contrast.py` 1 exemption changed (Thu Nov 5th 2026)


The temporary floating color button is gone. The panel is stackshot's shared tool, `static/colortool.js`, pinned in sala byte for byte (its sha256 in `static/colortool.js.sha256`, pinned with `web/tools/pin-colortool`); sala's part is
`static/colortool-sala.js`, and the button is the last thing in the side panel (`#side-colors`) (`web/README.md`, "The color tool"). The saved list is one list on the account, held by stackshot and reached through sala's server
(`web/src/sala_web/colors.py`, three `/api/colors/combos` routes); it is permanent.
A wrong answer is a pinned copy edited by hand or drifted from its sha file; a script missing from one of the three pages (the main page, `/v2/`, the full-size terminal), loaded twice or in the wrong order, or the button started on the terminal page; a
stored look applied after the body is drawn (a flash on first paint); a floating button back in the corner, a button anywhere but last in the side panel, or one over the composer; a panel that does not fit 360 px, opens downward past the window or cannot be scrolled; a field that moves
a variable of another field or leaves one out; a pick lost on a reload or left behind by Reset or "Live now" (any inline property, the four shifted surfaces, `--dis-op`, the status-bar color); a stylesheet that reads a new variable without a fallback (the page would change with the
tool absent); the idle Send button still faded by opacity (brown) with the disabled pair set, or changed without the tool; a look stored by the earlier try-out that stops loading; the light theme recolored by a dark pick; a token or the sender label in the browser; a body that is not the name
and the 14 colors reaching stackshot; a stackshot failure that breaks the panel; a cached list.
`test_colortool_wiring.py`, text checks: the pinned `colortool.js` matches its sha file and starts with its `/* colortool vN */` line; `pin-colortool` copies a file verbatim (CRLF, a tab, no final newline), writes the sha file, leaves no temporary file, and refuses a file without the version
line or a missing path, leaving the pinned copy as it was; both scripts are served at `/static/` and `/v2/static/`; each page carries the two script tags once in the head, the tool first and after the stylesheets and theme-color metas, only `index.html` calls `SalaColors.init()` (last in the body, after `app.js`),
and `#side-colors` is the last element of the side panel after `show-back` and `side-note` and absent from the terminal page; `colortry.js`, `test_colortry.py` and the old wording are gone (the storage key keeps its name); the wiring's `onApply` returns in the light theme (where the tool calls it with nothing resolved) after putting the status-bar meta back, and `cfg.text` holds only keys the pinned tool reads; the settings in the wiring (`storageKey`, `gate: "warn"`, mount, address, the
variables of each of the 14 fields, the four shifted surfaces), the wiring makes no request, token or storage call of its own, the tool has one `fetch`, no XHR or beacon, and the panel's alias tokens (`--card`, `--line`, `--fg`, `--mut`, `--ibd`, `--ifill`) point at sala's and share no name with a sala token;
the `.ct-prev` rules in the wiring repeat the declarations of the front badge, the overview tag and the "max" tag that `style.css` and `sessions.css` scope to a page region; every read of `--accent-solid`, `--accent-on-solid`, `--label-bg`, `--label-fg`, `--label-bd`, `--dis-bg`, `--dis-fg` and `--dis-op` has a
fallback and none is declared in a stylesheet; the disabled rule of the Send button falls back to the shipped colors and the 45% fade. Browser checks (headless Chromium): at 360 x 740 and 1280 x 800, on `/` and `/v2/`, with two saved combinations: one button, in the side panel, in the flow, under "Show all sessions",
at the very bottom, no fixed element of the tool before it is opened; the open panel is in the body, above the button, inside the window, with no sideways scroll, scrolls, its last button can be reached; Escape closes it. At 390 px: the Radix preset, a card pick and a page background pick set exactly their
variables (the card's four shifted surfaces moved by the same step; the disabled pair with `--dis-op: 1`; the dark status-bar meta only, the light one untouched) and are stored as the fields that differ from the unset value; a reload applies them before the panel is opened; Reset and "Live now" leave no inline property of
the tool's, restore the status-bar color, the page background and the faded Send; the idle Send is exactly the disabled pair at opacity 1 while a preset holds it. With nothing set and the fields unfolded, the five fields that follow others (`labbg`, `labfg`, `labbd`, `disbg`, `disfg`) show the values the wiring's `shipped()` gives (the solid fill, the text on it, the solid fill, and both at 45% over the card) and say "shipped"; setting the card, the solid fill or the link color turns exactly the rows that follow it to "follows the others", and Reset puts all five back. A look stored by the earlier try-out is applied in the head, before the body, with the meta, and is read not rewritten; in the light scheme there is no button, no script error, the dark status-bar meta is as shipped and the
stored dark look is not applied, and a `data-theme` set on `<html>` shows and hides it at once; the terminal page applies the look and has no button and stays black; with `colortool.js` blocked the page loads as shipped. With the fake stackshot: the list is listed (and read again on each opening, a row that is not a
whole combination left out), applied, saved from a name typed in the panel (no `window.prompt`; the browser sends only the name and the values), replaced under the same name in another case, deleted after a second press; the browser's requests carry no token, `Authorization` or sender label and no picked color outside the one
save. With stackshot answering 503, not listening, or no token on the machine, the panel says why without a token or address, and the presets, fields, Reset and a failed Save still behave.
`test_colors_combos.py` (the routes against the fake stackshot): the list is stackshot's and not cached (a row added by another page shows at once), rows that are not rows are left out; a save forwards the trimmed NFC name and the 14 lowercase colours with the sender set by the server, and a `sender`, `id` or any other field from the browser is a 400
that never reaches stackshot; a name that is empty, blank, over 40 characters, with a newline, NUL, zero-width space or direction override, or not a string is a 400 on `name`; values with a key short or over, a non-hex, a 3-digit hex, a number, null, a list or a string are a 400 on `values` or the key; the same name in another case replaces in place; delete sends the id with the sender,
an unknown id is a 200, a bad id a 400; a body that is not JSON, not an object, another content type, another origin or over 16 KB is 400, 415, 403, 413; stackshot's 400, 403 (field `sender`), 409, 413 and 415 pass through with their sentence and field, an unlisted field becomes null and a long sentence is cut; a 503, 500, 404 or plain-text answer, an answer that is not the list, stackshot not listening
(502), no token or address (503) and a refused token (502) each give `{error, field}` with the right status and neither the token nor the address in it.
Changed: `test_theme_contrast.py` skips the one file `colortool.js`, by name and with the reason "pinned shared source of stackshot's color tool: its presets hold their own hex values", in the orange scan and the icon-orange scan, and the front badge's search twin and the header layout test expect the tint mixed from
`var(--accent-solid, var(--call)) 12%`. Not covered, and why: a coarse pointer (headless Chromium does not report one), the browser's own color dialog (the picker's `input` event is dispatched), the installed app's status bar (the meta is checked, the bar is not), the panel's own texts and layout inside (stackshot's file, tested there),
stackshot's real storage, 4 KB limit and contrast-free save (the fake only answers what it is told), and how the colors look (by eye).

### The dark theme's orange is the Old orange `#f0a06a`: `web/tests/test_theme_contrast.py` 5 changed (Thu Nov 5th 2026)

The one orange of the dark theme moves from `#ec8a47` to `#f0a06a` (the color tool's **Old orange**, and the value of the app icons): `--accent`, `--link`, `--call` and `--role-front-text` in the dark blocks of
`style.css`, the `/v2` layer's dark `--accent`, `--link` and `--acc`, the terminal page's fallback in `termclip.css` and the color tool wiring's fallback table. The text on an accent fill stays `#1f1f21`; the light theme
(`#ad4608`) is unchanged; the idle Send's disabled pair is not stored anywhere, it is the solid and its text at 45% over the card, so it follows. A wrong answer is a dark rule that still holds `#ec8a47` (a link, a ring or a
count of the old orange next to the new), or a dark orange that no longer reads: `#f0a06a` measures 8.56:1 on the page, 7.79:1 on the card and 6.60:1 on the selected row, and `#1f1f21` on `#f0a06a` 7.79:1.
Changed (`test_theme_contrast.py`): the palette spot check, the accent and link check, and the set of allowed oranges (`#ad4608`, `#f0a06a`) hold the new value, so a leftover `#ec8a47` in any page file now fails the orange scan;
the scan's own test finds `#ec8a47` (and `rgb(236 138 71)`) as a stray orange and passes the two oranges. The test that kept `#f0a06a` inside the tab icons and nowhere else is rewritten, since the dark
theme uses the same value: the two tab icons and `tools/make_icons.py` still carry it, and the dark `--accent` and `--link` equal it while the light accent does not. This supersedes the two earlier entries' statements of `#ec8a47`
and of the icons' orange being used nowhere else. Not covered, and why: how the lighter orange looks to a person (by eye).

### `tests/backlane.sh`: new (Thu Nov 5th 2026)
The back agents' lane rule (README, *The back agents' lane rule*). Fakes only, in an isolated, locked and removed HOME: a saved sala-web usage answer (`quota-subscription-1.json`) and a limit-watch state written by the test, a fake `salamander` that records `op …` and applies a `lane <lane> <sessions…>` move to `lanes.tsv`, a `tmux` that answers `has-session` from a list, and the real `lane_check` with one lane the test marks not ready; no real operation, lane move, network or tmux server. Covered: the rule is off by default (a 95% reading queues and writes nothing; `watch --back-lanes --dry-run` says it is off); nothing moves at 0, 50 and 89%, on a two-hour-old reading, a failed one (`errorKind`), a missing or unreadable file, a window already over, an answer with only a model-scoped weekly limit at 99%, or with the home lane dormant; step 1 at 90% queues ONE `op lane aws-platform <names> --from sala-watch --words <the rule's words>` naming the live back agents on the home lane (one on a model only that lane runs included) and not a front agent, a side session, an agent on api, an agent with no tmux session or a job-named session, leaves their lanes and the default lane as they were, writes the lane log, and a repeat tick or the same window again queues nothing; step 2 moves them to bedrock once for a workspace or credit stop on aws-platform after the move, not for a stop on another lane, of the rate kind or from before the move, and leaves an agent on such a model with one notice naming it; step 3 sends every back agent in the order home, wherever it stands, on a fresh under-90% reading of a later window, once, and not on the same window, a reading at 95%, a stale reading or a dormant home lane, leaving the api and front agents alone, and the next window can start the cycle again; no queued operation is a job or an exec and `lane-default` is never written; an operation the queue refuses gives one notice and the next tick a quiet line with the rule's lane unchanged, then moves once the queue takes it; a target lane that cannot launch gives one notice per window and nothing is queued; with no live back agent the rule's lane still advances without an operation; the reading's refresh (a stub `curl` stands for sala-web: a missing or older-than-half-the-max-age answer is asked for with one plain GET of `<url>/api/quota`, `-fsS --max-time 5`, no header or token, and the step then fires on the refreshed file; a failed call, or one that writes nothing new, leaves it stale and nobody moves; a second tick within `SALA_BACK_LANE_REFRESH_EVERY` does not ask again; a young reading, a dormant home lane, `SALA_BACK_LANE_REFRESH_URL=off` and a socket that is not there make no call; an older-than-half but still valid reading is used when the call fails; the default is sala-web's socket under `XDG_RUNTIME_DIR` (`--unix-socket … http://localhost/api/quota`) and `SALA_WEB_SOCKET` moves it; `--dry-run` says it would refresh, asks nobody and writes nothing); `back_lane_spawn_lane` and `spawn --dry-run` (a stub page check) name the rule's lane for a back agent while the rule has them off home, and not for a front agent, with `--lane`, with the back agents home, with the rule off, or with the rule's lane dormant or not ready; `watch --back-lanes --dry-run` prints "would: step 1/2/3" and queues nothing and leaves the state file as it was. Not covered, and why: a real lane move through `sala op` and the switch (`tests/lanefallback.sh` and `tests/lanes.sh` cover the machinery the rule queues into); sala-web's real answer to the GET (`web/tests` cover the route and the file); a model change on bedrock (the rule leaves such an agent where it is and does not change a model).
Changed: `lib/watch.sh` adds the lane a stopped pane runs on (`rlane`) to the limit watch's state (`docs/stackshot-contracts.md` version 35, interface 12); `tests/stackshotshape.sh` checks that each stopped pane carries it, and `tests/limitwatch.sh` passes unchanged; `SALA_LIMIT_STATE` can be set by the environment.

### The dark theme ships the saved combination "live+small label flip": `web/tests/test_colortool_wiring.py` +5 tests, 4 changed; `test_theme_contrast.py` +1; `test_unread_count.py` 3 changed (Thu Nov 5th 2026)

Sala ships one of the color tool's saved combinations as its dark default, because it keeps the one orange and gives the small labels and the disabled buttons a quiet pair of their own. Of its 14 values nine were already shipped (the six neutrals `#161617` `#1f1f21` `#ececea` `#a3a29d` `#2c2c2e` `#929190`, and the one orange `#f0a06a` for the links and the solid fill, `#1f1f21` on it);
the other five were worked out from the solid fill and are now the dark theme's own tokens in `style.css` (`--label-bg #3a2619`, `--label-fg #f0a06a`, `--label-bd #3a2619`, `--dis-bg #2a2a2c`, `--dis-fg #a3a29d`, with `--dis-op: 1`): the unread count, the front badge, the "max" effort tag and a search hit's front tag are the orange on a deep
brown with an outline of the fill's color, and the disabled Send, Create session and Start quick session are a flat grey pair at full opacity. The light theme sets none of them and keeps the stylesheets' fallbacks. The panel's "Live now" boxes (the wiring's `shipped()`) read the six tokens; on the terminal page, which has no palette, the wiring's fallback table answers with the same values. The color tool's own preset **Old orange** is in the pinned file and is untouched.
A wrong answer is a dark small label or disabled button still drawn from the solid fill (an orange pill with dark text, a faded brown Send), a panel whose Live now boxes differ from what the page draws, or the light theme changed.
New (`test_colortool_wiring.py`): the two style.css blocks (the dark media query and `data-theme="dark"`) declare exactly the six tokens with these values and the token blocks of the contrast test do not; `shipped()` returns the 14 values of the combination exactly, on the main page, `/v2/` and the terminal page, with nothing set and nothing stored; in the light theme `shipped()` is still worked out from the solid fill
and the count and the faded Send are drawn as before; the computed colors of a count, a front badge, a search hit's front tag (text, fill, outline) and of every disabled solid button present (Send, Create session, Start quick session) on `/` and `/v2/`. New (`test_theme_contrast.py`): the label pair (6.76:1) and the disabled pair (5.60:1) hold 4.5:1, the label text is the app's one orange, the light theme sets none of the tokens.
Changed: the "stylesheets read the variables with a fallback" test lets the two shipped blocks (and only them) declare the six names; the label and disabled rows of the panel show the combination while shipped, and follow the others as before once a field they follow is set; the disabled Send is the grey pair at opacity 1 as shipped, after Reset and without the script, and a field typed in or a preset moves it; "Two oranges" now stores fewer
properties (its label fill and text equal the shipped ones); `test_unread_count.py`: the dark count is `#f0a06a` on `#3a2619` (the light one is unchanged). Not covered, and why: how the combination looks to a person (by eye).

### `web/tests/test_usage.py` (new, 30) and `web/tests/test_usage_ui.py` (new, 18): the Overview's Usage analysis tab (Sat Nov 7th 2026)

What it is: the fourth Overview tab shows what this machine's Claude Code replies cost at list prices, by week, day, lane, model, project, agent and folder (`web/README.md`,
*Usage analysis*; `usage.py`, `GET /api/usage`, `static/usage.js`, `static/usage.css`). Part one builds the data layer, the tab and the Report view. Kept because the owner reads a
dollar figure off it, so a wrong answer costs a total that is too high (a streamed reply or a forked history counted twice, a second login's linked folder counted twice) or too low (a
subagent's usage left out, a reply in the wrong week), a week that does not run from one weekly reset to the next, a day that is not a KST day, a model with no price counted as $0 without a
word, a re-read of every transcript on every refresh, a prompt or reply leaving a transcript, a filter that leaves the total or the table unfiltered, a token count on a page of dollars, and, on a
phone, a page that scrolls sideways or a control too small to hit. Every transcript, registry and state file is a fake in a temporary folder (pytest's `tmp_path`, removed when the test ends); the
fake logins' folders and the sala command point at nothing (`conftest.py` gets an autouse fixture, `no_real_login_dirs`, so no test counts this machine's own transcripts); nothing asks
Anthropic or AWS.

`test_usage.py` (no browser): the weeks (a reset ahead, one that has passed rolled forward by whole weeks, a far one rolled back, none known: seven-day windows ending now; the days a week
touches, one that ends at KST midnight not counting that day); the KST day boundary; the project from the agent name (a scope, a name with no scope, none configured, unnamed); the folder
(the first `cwd`, a worktree counted as its repository, the home directory as `~`, the folder name when a transcript names no `cwd`); the price of a reply from the table by the numbers, the two
cache-write tiers on their own prices, a streamed reply and a forked history counted once with the largest counts, a subagent counted for its session, an unknown session as `(unnamed)`,
the lane of a session and `billed` leaving out the flat plan (with and without sala's lane table), the three weeks and the replies before and after them, a reply at KST midnight, a model
with no price listed and costing nothing, the last saved anchor standing in for a missing reset, a reset with fractions of a second as one boundary, the same-hours comparison; the
cache (a second count opens no transcript, a grown one reads only the added bytes, a half-written line read once complete, a replaced file read again, the saved file making a new
process read nothing, a window moved back rebuilding it, a transcript outside the window not opened, a second login's folder that links to the first counted once and a separate one on its
own lane); the answer holding no prompt, reply or tool text, in memory or in the saved cache; the endpoint (the week asked for, its rows and fields, a bad `week` a 400, a failed count keeping the last
answer with an error in words and never the exception's text).

`test_usage_ui.py` (headless Chromium, else skipped), at 1280 px and 390 px through the real app over fake transcripts: the markup and both files with the cache-busting version, the hash in `app.js`; the tab
opening on its link with Report first, Explorer and Digest both built (neither says it is coming next), the arrow keys wrapping; a read when the tab opens and on Reload and none from any other tab; the total
and its "billed" line, the lane cards' words, the grouping by each of Day, Lane, Model, Project, Agent and Folder (each adding up to the total, the chart's title following), no token word on the
page; a name from the registry staying text; a tap on a lane card filtering the total and the table with a chip that clears it, a table row, a day and a key name each filtering and Clear all
emptying them, the table's sort flipping on a second tap, a week switch asking again and showing that week's figures with the filters cleared, a failed read keeping the last figures with a note;
no console error or uncaught exception anywhere (the check itself was shown to catch both); no sideways scroll, four tabs and the icon-only Reload in one bar and every control at least 44 px on a
phone, one lane card to a line and the table keeping its name and cost columns there, all five columns on a desktop. Set `SALA_USAGE_SHOTS` to leave a screenshot of each width.

Changed: `test_search_ui.py`, `test_schedules.py`, `test_machines.py` and `test_machines_ui.py` follow the fourth tab (the tab list, the panels, the arrow keys walking four tabs and wrapping, the tab
bar of a phone holding four tabs); the Machines keyboard test now reaches Usage analysis before it wraps.

Not covered, and why: the real transcripts of a production machine and their cold scan time (measured by hand once on the build box, not asserted: it depends on the machine), a real quota answer
(the weekly reset is given by the test), a physical phone (the width is emulated), the price table's truth (the table is spend.py's; `PRICES_AS_OF` is a marker a person sets), and the other two views (each has its own section below).

### `web/tests/test_usage_explorer.py` (new, 11) and `web/tests/test_usage_explorer_ui.py` (new, 19): the Usage analysis tab's Explorer view (Sat Nov 7th 2026)

What it is: the Explorer view compares any two things side by side and lists the replies behind a row (`web/README.md`, *Usage analysis*; `usage.py` `reply_list`, `GET /api/usage/replies`,
`static/usage-explorer.js`, `static/usage-explorer.css`). Kept because the owner reads dollars off it, so a wrong answer costs two sides that do not add up to the Report, an A swapped with a B,
a filter that narrows one side and not the other, a break-down whose rows do not sum to the side, a tap whose replies are not those of that row and side, a list that is not capped or does not say
how many there are in all, a flat-plan figure that counts as billed or lacks its *not billed*, a prompt or token count leaving a transcript or reaching the page, a view that reads the server while
it is not on screen, markup built from a name, and, on a phone, a page that scrolls sideways or a control too small to hit. Every transcript, registry and state file is a fake in a temporary folder.

`test_usage_explorer.py` (no browser): the replies of a week newest first with KST times and their dollars adding up to the rows of the Report; a filter on each of day, lane, model, project, agent
and folder; the cap and `limit` with the total and dollars of everything that matched; the weeks and a reply counted once; a model with no price at $0; no text and no token count in a record; a second
count opening no transcript; the route (a bad `week` or `limit` a 400, a repeated name as alternatives); `pending` after a restart until a count has run; a failed count answering with an error in words.

`test_usage_explorer_ui.py` (headless Chromium, else skipped), at 1280 px and 390 px: the markup, the two files and the hook into `usage.js`; the view opening from the views control, reading once and
nothing while another view is on screen; the default comparison (the two costliest lanes, the flat plan *not billed*, billed per use, the change of B against A, the Report's notes, no token word);
each of Model and Agent compared with both sides adding up to their columns; the compared dimension leaving the break-down and the filters; Day choosing the two latest days; A and B changed and a
*none* side; a Where filter narrowing both sides and *Clear filters*; Week compared and the week filter; a tap on a row listing the replies for A and for B (newest first, dollars, *not billed*) and
closing on a second tap; the list capped at 200 with its total; a failed read of the replies and a retry; a failed read of the usage keeping the last figures; the table's sort; a registry name staying
text; Reload; no console error; no sideways scroll, the two side cards side by side and every control 44 px on a phone. Set `SALA_USAGE_SHOTS` to leave a screenshot of each width.

Changed: `test_usage_ui.py` asserts Explorer is built (it no longer says *coming next*).

Not covered, and why: the real transcripts of a production machine (the counts are the Report's), a physical phone (the width is emulated), and how the wording reads to a person (by eye).

### `web/tests/test_usage_digest.py` (new, 31) and `web/tests/test_usage_digest_ui.py` (new, 9): the Usage analysis tab's Digest view (Sat Nov 7th 2026)

What it is: the Digest is the week in a few plain sentences, written by code from the rows the Report already counts (`web/README.md`, *Usage analysis*; `usage_digest.py`, `GET /api/usage/digest`,
`static/usage-digest.js`, `static/usage-digest.css`). Kept because the owner reads a sentence as a fact, so a wrong answer is a sentence that says a figure the Report does not (a total, a billed share, a busiest
day or a top name that differs from the table), flat-plan dollars described as billed, a comparison the wrong way round or against the wrong hours, a limit shown for a week that is over, a literal `NaN`,
`undefined` or `None` or an ISO date in a sentence, a token count where dollars belong, a week with no replies or with no earlier week that breaks instead of saying so, words that change with the order of the rows
(a scheduled job would deliver a different report each time), a model call or a second transcript scan behind the route, and wording that drifts from the Report's own. The sentences are a pure function over
made-up answers; the route runs over fake transcripts in a temporary folder (`World` of `test_usage.py`), nothing asks Anthropic or AWS and no real sala runs.

`test_usage_digest.py` (no browser): the running week's seven sentences word for word (total and billed, busiest day, lane, model, project and agent, the same-hours comparison, the weekly limit with its reset in
KST); a closed week (named by its days, compared with the week before it, no limit sentence); the oldest week saying there is no earlier week; a drop reading "down", a change under a percent reading "about the
same", a week before with no spend or with nothing counted said plainly; the limit for the running week only, only for a flat-plan lane that has it, two lanes in one sentence; a week with no replies; replies on a
model with no price (no division by zero); only flat-plan spend ("none of it was billed", "all of it" on one lane, model and day); only per-use spend ("all of it was billed"), a tie going to the earlier day;
sessions with no name said in words; no known weekly reset (the last seven days and the ones before); a singular reply and a thousand with its comma; "all of it" only when it is all, and "over 99%" for a share
that rounds to the whole; no placeholder, ISO date, bracket or token word in any sentence of nine kinds of week, never more than seven sentences; the same words whatever the order of the rows; odd input (rows too short,
a number that is not one, lanes that are not objects) saying less and never raising; the date, time, money and model words by the numbers (every ordinal, 12 AM and PM); the module importing only `re`, `datetime`
and `__future__` (no model, no network, no file); the flat-plan, per-use and machines words equal to the ones in `static/usage.js`; the route (the sentences are those of the Report's own count, one scan for
both routes, a bad `week` a 400, no text of a transcript and no token word); the pending answer with no sentences; a failed count keeping the last sentences with the error in words.

`test_usage_digest_ui.py` (headless Chromium, else skipped), through the real app over fake transcripts: the panel and both files with the cache-busting version, loaded after `usage.js` and before `app.js`; the
Digest's sentences, bold amounts (nothing else bold), week picker, range, machines note and no "coming next", token, `undefined` or `NaN`; a read only when the Digest is on screen (none while the Report is, one on opening,
one on a change of week, one on Reload with `fresh=1`, none on leaving, one again on coming back), the week being one for both views; a name like `<img onerror=…>` in a sentence staying text; a failed read keeping the last
sentences with a note; at 1280 px and 390 px, dark and light: no sideways scroll, text of 16 px that stands out of its card in both themes, the card inside its gutters, every control a 44 px target on a phone. Set
`SALA_USAGE_SHOTS` to leave a screenshot of each width and theme.

Changed: `test_usage_ui.py` no longer expects the Digest to say it is coming next.

Not covered, and why: this box's real transcripts and a real quota answer (checked by hand once, against a copy of the real quota file, not asserted: the figures depend on the machine), a physical phone (the width is
emulated), and how the wording reads to a person (by eye).
