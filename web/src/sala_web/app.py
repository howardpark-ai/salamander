"""sala-web: a web UI for the Claude Code sessions in tmux on this machine.

Endpoints (all read-only except /api/upload, PUT /api/prefs and POST /api/read, which write to the state dir, /api/s/<pid>/send, whose
only write to tmux is a paste plus Enter into that session's own pane, or one digit or Escape answering a numbered dialog
open there, POST /api/s/<pid>/stop, whose only write to tmux is Escape (and Ctrl-C) into that session's pane while a `!`
command runs there, and POST /api/spawn, which queues a new session through sala's operation queue, `sala op spawn`, and makes
none itself):

  GET  /                          the page (/?arg=<tmux session> redirects to /terminal); #s=<name> opens a
                                  session, #sessions the sessions overview (every live session's role, status, model
                                  and lane, with account usage and API spend above them)
  GET  /v2, /v2/<path>            a temporary redirect (307) to /, the query kept and the path dropped: the new look was tried at /v2/ before it became
                                  the page, and old bookmarks and the installed app's older link land on /; dropped later
  GET  /terminal                  the full-size terminal: ttyd's page in a frame filling the window, ?arg=<tmux session> (static/terminal.html)
  GET  /manifest.webmanifest      the web app manifest (the page is installable as an app; static/manifest.webmanifest)
  GET  /sw.js                     the service worker, at the root so its scope is the whole site (static/sw.js)
  GET  /mockup/<n>                a page `sala mockup add` stored under that number (mockup.py; 404 for any other address under /mockup), as
                                  text/html; charset=utf-8 in a sandbox: every answer under /mockup carries a Content-Security-Policy
                                  `sandbox allow-scripts` (an opaque origin: no cookies, no sala API) with connect-src 'none', nosniff and
                                  Referrer-Policy no-referrer; read-only, behind the same sign-in as the rest of the site (the proxy's)
  GET  /api/config                settings the page needs (terminal URL prefix, the title-bar suffix, the scopes) and the build version
  GET  /sessions                  redirects to /#sessions (the overview was its own page before it moved into /)
  GET  /api/sessions              live sessions grouped by project; each carries "unread_count" (the replies a front
                                  agent has written since the owner opened it, at most 10; the sidebar's orange count) and
                                  "unread" (count > 0); unread.py; and "agentId" (sala's permanent id for the agent,
                                  from the registry's sessions.json: the key of the saved agent order) with its
                                  "aliases", when the registry has a row for it
  POST /api/read                  {"name"}: the owner opened that session, so its read marker moves up to its latest reply
                                  (state_dir/read-state.json, so the phone and the desktop agree; unread.py)
  GET  /api/overview              the same sessions as flat rows in sidebar order, each with the model and effort its
                                  pane runs now (its command line, else sala's record, else its latest reply; a bare
                                  alias resolved to the exact version as the claude binary it runs resolves it)
  GET  /api/lane-names            the lanes' display names as sala says them (lanenames.py): {"lanes": [{"code", "display", "aliases"}]},
                                  from `sala lane names --json`, else the lane-names.json sala writes in its state dir, else the
                                  codes alone (display = code); this app holds no display name of its own, and the page reads each
                                  lane's name here (static/shared.js laneLabel)
  GET  /api/quota                 each account lane's (subscription-1, subscription-2) usage limits (a lane sala's dormant record lists, lane-state.tsv
                                  in sala's state dir, comes back as {"lane", "dormant": {reason, since}[, "plan"][, "fetchedAt"]}
                                  and is asked nothing; its fetchedAt, epoch ms, is the last good reading kept in
                                  state_dir/quota-<lane>.json, absent when it has none; every card's last line,
                                  "updated 7 min ago", is this answer's fetchedAt and says "updated unknown" without one;
                                  the per-use lanes below keep their spend when dormant), from Anthropic's usage endpoint: the last
                                  answer at once, refreshed in the background every 5 minutes and kept in
                                  state_dir/quota-<lane>.json (swr.py; reads the lane's sign-in token, never refreshes,
                                  writes or keeps it); a failed refresh keeps the answer with "error", "errorKind"
                                  (rate_limited | failed | sign_in) and "nextTry", backing off per lane (a 429 as its
                                  Retry-After says), the wait saved so a restart keeps it
  GET  /api/credit                what the API key (metered and sdk lanes) spent today and this month in the SALA_TZ zone (local time when unset), from the
                                  Admin API's cost and usage reports (GET only): the last answer at once, refreshed in
                                  the background every 15 minutes and kept in state_dir/api-spend.json (swr.py). Asked the
                                  same when the lane is dormant: the answer then also carries "lane": "api" and
                                  "dormant": {reason, since}, and the card shows the figures beside the reason
  GET  /api/spend                month-to-date spend of the aws-platform and bedrock lanes as an ESTIMATE AT LIST PRICES,
                                  counted from this machine's own Claude Code transcripts (spend.py; no AWS or Anthropic call):
                                  {"month", "since", "lanes": [{"lane", "configured", "monthUsd", "calls", "models": [{model,
                                  usd, calls}], "sessions": [{name, sessionId, usd, share, live}], "unpriced", "unmatched"}]};
                                  a lane the dormant record lists keeps its figures (nothing is asked for them) and its entry gains
                                  "dormant": {reason, since}; before the first count it is just {"lane", "dormant"}. The last answer at once,
                                  refreshed in a thread every 5 minutes and kept in state_dir/spend-aws.json (swr.py; the
                                  per-file read cache is spend-scan.json, the live lane sightings spend-lanes.json); "pending"
                                  until the first count lands, "error" in plain words when it cannot be counted
  GET  /api/usage?week=<0|1|2>    the Overview's Usage analysis tab (usage.py): what the Claude Code replies on THIS machine cost, at list prices, over one weekly
                                  range (0 = the running week, 1 and 2 = seven days back each; a week runs from one weekly reset of the subscription lane to the
                                  next), counted from the transcripts under ~/.claude/projects and each second login's folder, subagents included (no AWS or Anthropic
                                  call): {"week", "tz", "tzLabel" (KST), "resetKnown", "generated", "anchor", "weeks": [{id, start, end, startKst, endKst, days, current,
                                  total, billed, replies}], "lanes": [{code, label, billing, flat, known, quota: {percent, resetsAt} | null}], "fields": ["day", "lane",
                                  "model", "project", "agent", "folder", "usd", "replies", "tokens"], "rows": [[...one value per field...]] (tokens = [input, cache
                                  write 5m, cache write 1h, cache read, output], kept on record, never shown), "sameHours", "unpriced", "prices": {asOf, unit, models}}.
                                  No message text, prompt or secret. The last saved count at once: a visit never counts. The count is a job of its own, once a day
                                  (contrib/sala-web-usage-count, usage_job.py), saved in state_dir/usage-answer.json (the drill-down's records in usage-replies.json,
                                  the per-file read cache in usage-scan.json) and read in again here when the job has written a newer one; ?fresh=1 (the Reload
                                  button) starts one more, in a thread. "noCount" when none was made yet, "pending" and "refreshing" while a Reload's count runs,
                                  "error" in plain words when a count failed (the last count stays)
  GET  /api/usage/digest?week=<0|1|2>   the Usage analysis tab's Digest view (usage_digest.py): the same week in 1 to 7 plain sentences written by code (no model call)
                                  from the cached count above (no second scan): {"week", "now", "generated", "tz", "tzLabel", "resetKnown", "scope" (only this
                                  machine's sessions are counted), "range" {startKst, endKst, end, current} | null, "sentences": [...]}; "pending" (no sentences) before the
                                  first count, "noCount", "refreshing" and "error" as /api/usage; ?fresh=1 as above; a bad week is a 400
  GET  /api/usage/replies?week=<0|1|2>&<dimension>=<value>…   Explorer's drill-down (usage.py): the single replies behind a filter of that week, newest first, at most
                                  `cap` (200; ?limit=<n> asks for fewer): {"week", "generated", "tz", "tzLabel", "fields": ["time" (KST), "day", "lane", "model",
                                  "project", "agent", "folder", "usd"], "rows": [[…]], "total" (every reply that matches), "usd" (their dollars), "shown", "capped", "cap"}.
                                  A dimension (day, lane, model, project, agent, folder) may be given once or several times (alternatives); one not given matches anything.
                                  Read from the records the last count left in memory, no transcript is opened; "pending" until the first count has landed (also right after a
                                  restart, which makes a count due), "error" in plain words when there is none and the count failed; a week other than 0 to 2 is a 400
  GET  /api/schedules             every scheduled job on this machine, from the last reading of systemd and cron (schedules.py; served at once and read
                                  again in the background once it is 30 s old, swr.py: "fetchedAt" (epoch ms), "refreshing", "pending" before the first
                                  reading, "error" when a read failed and the last stays; ?fresh=1 makes it due now; memory only, no database): {"generated", "timezone" (SALA_TZ, "" = local), "tzLabel", "timers":
                                  [{scope (user | system), name, service, description, summary (it without a leading "<name> — "), project (X-Project= of the service unit: the job's category, null when absent), runs {command, script, line}, schedule
                                  (the timer's On… lines as written), plain (the schedule in plain words, times in the SALA_TZ zone), next and last {epoch, iso (with the zone's offset), text} (null for none),
                                  result {state: ok | failed | running | never | unknown, text}, lane (X-Model-Lane= of the
                                  service unit, null when absent), lane_note (its optional X-Model-Note=, null when absent), links {script, service, timer} (GitHub, null when
                                  not in a GitHub-backed repo), unit_files, flags [{code, text}]}], "cron": [{schedule, command,
                                  flags}], "counts": {timers, cron, flagged, byReason, packaged (the package-shipped timers left out of the list)}, "scopes": {user, system} (whether each
                                  scope's timers could be listed without sudo)}. Only jobs that are ours are listed. The flag codes: failed,
                                  no-service, not-git, git-differs, no-lane, bad-lane, no-project, cron
  GET  /api/machines              the Overview's Machines tab (machines.py), stackshot's last readings, read from its state folder at each
                                  request (nothing written, nothing asked of GitHub or a machine): {"generated" (epoch s), "tzLabel", "updated"
                                  (epoch s of the versions file, null when there is none), "machines": {"ok", "reason",
                                  "cards": [{name, alert, rows: [{package, version, state: latest | update | offline | unknown, text}],
                                  alerts: [{kind: setup | update, detail, tip}], follow: {kind: publisher | follows | self | unknown, text, tip}}]}}.
                                  A source that is missing or unreadable gives "ok": false and a "reason" in plain words, still 200
  GET  /api/search                the Overview's Search tab (search.py): ?q=<words, every one must be in the same entry; "quoted" = a phrase>
                                  &hours=<N, default 24> | &from=&to= (epoch s, or 2026-11-01T09:00 in the page's zone; at most a year), switches 1/0: front, back, sub
                                  (subagents), unknown (a role nobody knows) default on; messages, tools default on; output, thinking default off.
                                  Plain case-insensitive substrings over ~/.claude/projects/**/*.jsonl, subagents included, read-only; no
                                  parameter is a path. -> {"words", "from", "to", "fromText", "toText", "matches" (all that pass the switches),
                                  "shown", "cap" (200), "capped", "timedOut" (stopped at deadlineS and sent what it had), "files" {scanned,
                                  inRange, all}, "counts" {agents: {front, back, sub, unknown}, content: {messages, tools, output, thinking}}
                                  (what each box would add, given the other group's switches), "elapsedMs", "results": [{agent (the
                                  registry's permanent id, else session:<Claude session id>), name (its current name), role (front | back |
                                  unknown), sub, kind, tool, session, uuid, ts, when, at, snippet: [[text, 1 if it matched]], pos, target}],
                                  newest first}. pos: the byte offset (a line's start) to open the agent's chat at (GET transcript?around=)
                                  and target: the uuid to light there: the entry's own, or for a subagent's entry the Agent/Task call in
                                  the session's transcript that started it (pos null when that call was not found).
                                  400 with a sentence for a bad query or range, 429 when two searches already run
  GET  /api/lanes/<id>            a lane's details page: {"lane", "record", "state", "error"}. record = the lane's
                                  row of sala's lane table (`sala lane --json`, read each time; provider, client, org,
                                  project, billing, payment, plan, account, credential = how it signs in, region), every
                                  value plain text with any file path taken out (lanes.py); state = {"state": "active" |
                                  "dormant" (with reason and since, from lane-state.tsv) | "not set up" | "unknown"};
                                  a table sala cannot print gives record null and error (a plain sentence), still 200;
                                  404 when the table has no such lane (sdk reads as api), 400 for a malformed id
  GET  /api/board-items           each live session's open stackshot items, from stackshot's client API (the page's reader
                                  is the New session page's board item picker)
                                  read with this machine's token (board.py): {"sessions": {<name>: {"items": [{id,
                                  subject, needs, waiting, held, url[, mover, wait, expected_by, overdue, step]}],
                                  "waiting": n}}}, waiting = the mover is the owner (without a mover: needs
                                  lists "decision" and the item is not held), the fields in brackets passed through
                                  from stackshot's one rule for an item that waits;
                                  the last answer at once, one round of reads per
                                  minute in the background (4 at a time, the live sessions only), kept in
                                  state_dir/board-items.json (text only, never the token); "error" a plain string when
                                  the board cannot be read
  GET  /api/for-you               stackshot's For you list (foryou.py): {"rows": [{id, kind, item, project,
                                  what, url, urgent, ts, when, slacked}], "flags": {"board#N": "watch" | "mute"},
                                  "generated", "fetchedAt"}, "error" a plain sentence when it cannot be read; the last
                                  answer at once, one read a minute in the background, in memory only
  POST /api/for-you/seen          {"id": <entry number> | "all"} -> {"ok", "seen", "rows", "flags"}: the entry (or all)
                                  marked seen at stackshot, the list now; a refusal as {"ok": false, "error": a sentence}
  POST /api/items/<key>/watch     {"state": "watch" | "mute" | "default"} for board#N (or its number) -> {"ok", "item",
                                  "state", "flags"}; the same origin and content-type checks as the other POSTs
  GET  /api/colors/combos         the color tool's saved combinations (colors.py): stackshot's one list on the
                                  account, not cached: {"combos": [{id, name, values: {the 14 colors}, saved, via}], "max"};
                                  a failure is {"error": a sentence, "field": the field at fault | null} (400 bad body, 403,
                                  409 list full, 413; 502 stackshot unreachable or refusing the token; 503 no setup on this
                                  machine or the list unreadable)
  POST /api/colors/combos         {"name", "values": {the 14 colors, #rrggbb}} -> the list; a name already there (case ignored)
                                  is replaced in place; this server adds the sender label, the browser sends and sees no token
  POST /api/colors/combos/delete  {"id"} -> the list (an unknown id is not an error)
  GET  /api/s/<pid>/transcript    the last n parsed messages (?n=200), with `before` (a byte offset into the transcript:
                                  the cursor for the page before them) and `start` (true: the file's start was reached);
                                  ?before=<cursor> gives the n messages that end before it instead (400 on a bad cursor);
                                  ?around=<cursor> (a line's start: a Search result's pos) gives about n/2 messages before that line
                                  and the rest from it on, with `before`/`start` and `after` (the cursor for the next newer page)/`end`
                                  (true: the end of the file is in); ?after=<cursor> gives the n messages from it on, `after` and
                                  `end`. One of before, around and after; each cursor is checked the same way (400 when bad)
  GET  /api/s/<pid>/stream        SSE: "version", "reset" with the last 200 messages, then "append", "status" and "live" events.
                                  "live" is the pane of a running `!` command: Claude Code writes a `!` command's
                                  output to the transcript only when the command ends (2.1.312: no record before) and its pane
                                  keeps the input box, so the stream looks at the pane (a capture every 2 s, every 0.75 s while
                                  one runs). A `!` command runs when the line `! <command>` is the nearest turn above the input
                                  box, a "ctrl+b ... run in background" line or an elapsed-time line ("+N lines (Ns)", "(Ns)", "Running… (Ns)") is under it, and "esc to
                                  interrupt" is on the screen. It sends {"running": true, "command", "uuid", "text"} (plain text
                                  below the command's echo, the last 40 lines, the hint, the counter, rules and footer cut; uuid
                                  only when the transcript has the command's <bash-input> record) whenever the text changes, and
                                  {"running": false} when the pane no longer shows it. A reply or a model's own Bash call that
                                  shows "esc to interrupt" is not one. A stream that opens or reconnects during a command sends
                                  it right after its "reset"; a client that does not know the event ignores it
  POST /api/s/<pid>/stop          {} -> Stop for a running `!` command (the same pane check): Escape into that session's own pane
                                  and, if the command still runs a second later, Ctrl-C -> {"ok", "sent": ["Escape"[, "C-c"]]}.
                                  409 and nothing sent when no `!` command is running (or the pane is not the session's), 403
                                  cross-origin, 415 without application/json
  GET  /api/image/<sid>/<uuid>/<i>/<j>   an image block from a transcript
  GET  /api/file-image/<sid>/<uuid>/<i>/<k>   the k-th file of the SendUserFile call at block i of a transcript line,
                                  when it is an image under the home directory or /tmp/claude-<uid> (sentimages.py:
                                  png, jpeg, gif or webp by its first bytes, 15 MB at most, no hidden or secret-named
                                  path); the URL names a place in the transcript, never a path
  GET  /api/md-image/<sid>/<uuid>/<i>/<n>   the n-th local image (![caption](/abs/path.png) or ![caption](~/path.png)) in
                                  the markdown of the assistant text block i of a transcript line, with the rules of
                                  file-image; a refusal is a 404 whose "error" says why (the page shows it where the image
                                  would be); the URL names a place in the transcript, never a path
  POST /api/upload                raw body -> stored under uploads/: an image (Content-Type image/png|jpeg|gif|webp) under a
                                  random name; any other file (?name=<its name>) streamed to disk, 500 MB at most, as
                                  uploads/<random folder>/<its name made safe> -> {"ok", "name", "path", ...}
  POST /api/s/<pid>/send          {"text", "uploads": [names, as /api/upload returned them]} -> paste the stored paths and
                                  the text into the pane, then Enter (with a dialog
                                  open: an option number or "esc" is sent as that one key)
  GET  /api/prefs                 the page's saved preferences (scopeOrder, groupOrder, sessionOrder, collapsed,
                                  laneOrder, showAll, unreadOnly, showTools, shellHeight, lang)
  PUT  /api/prefs                 merge the given keys into them (state_dir/prefs.json, written atomically)
  POST /api/shell/open            make sure the Shell drawer's tmux session (SALA_SHELL_SESSION, default sala-shell) exists (a plain login bash in ~)
  POST /api/shell/keys            {"key"}: one key of the drawer's key row into the shell session, from a fixed list of key names
  GET  /api/spawn/options         what the New session form offers (spawn.py): the project pages (key, title)
                                  read from stackshot's pages checkout, the page dirs, the lanes a session can be spawned
                                  on, the effort levels, the name and mandate limits
  GET  /api/spawn/suggest         ?project=<key>&role=front|back[&prefix=<agent-name prefix>][&new=1] (or ?side=1&fork_of=<agent> | &project=<key>) -> {"name"}, from `sala spawn --suggest-name`
  GET  /api/spawn/item            ?id=<board#N | board-tmp-box#N | sN> -> {"ok", "item", "project", "owner", "status"} from stackshot's item-facts:
                                  what the Discuss link (#side=<id>) prefills a side conversation's form with
  GET  /api/spawn/projects        ?scope=<one of the scopes>|all[&q=<text>] -> the scope's listed projects (all: every
                                  scope's, each row with its own scope), and with q its hidden matches too, from
                                  stackshot's `GET /client/projects` (projpick.py)
  POST /api/spawn/project         {"key", "scope", "title"?} -> starts stackshot's `post project` (a new project and its gbrain
                                  page; minutes) as a job: 202 {"job"}
  GET  /api/spawn/project/job     ?id=<job> -> {"state": running|done, "elapsed", "status", "result"}
  POST /api/spawn/project-list    {"key", "scope"?} -> stackshot's `post project-list` (a hidden project listed again)
  POST /api/spawn/project-agent   {"project", "name", "role", "front", "mandate"} -> stackshot's `post project-agent` (the
                                  agent added to the project before its session starts); the label is always `sala-web`
  POST /api/spawn                 {"project", "role", "name", "mandate"?, "lane"?, "model"?, "effort"?} (a side conversation:
                                  {"side": true, "fork_of" | "project" + "item" + "agents"?, "name"?: blank = suggested, ...}) -> `sala op spawn …
                                  --from sala-web --words "<name>, via the sala web form: …"`, an argv list, the mandate as
                                  a file under state_dir/mandates/; 202 {"op"} when queued, 409 with "code" not-listed (the
                                  REGISTER line and register command), no-page or refused (the queue's reason), 400 for a shape the backend
                                  would refuse too. The one write to sala: the form is the only way this app makes a session
  GET  /api/spawn/status          ?op=<id> -> the queued operation's state from sala's own marker (queued, running, waiting,
                                  done, stuck, …) and its result line; while it is queued, also what it waits behind
                                  ("behind": [{op, verb, arg, state}], "behind_line": "Waiting behind 2 retires …")
  POST /api/debug/<kind>          a record, or a list of them, from a page -> one JSON line each in
                                  state_dir/<kind>-debug.log (temporary; debuglog.py): "timing", where a page
                                  load's milliseconds went (timingdebug.py); 204
  GET  /api/debug/<kind>          the log's last 200 lines (?n=) as text/plain, for a curl on the unix socket; the
                                  timing log as one readable line a record (?raw=1 for the JSON lines)
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import dataclasses
import html as htmllib
import json
import os
import re
import secrets
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
from pathlib import Path
from urllib.parse import urlsplit

from starlette.applications import Starlette
from starlette.concurrency import run_in_threadpool
from starlette.requests import Request
from starlette.responses import FileResponse, HTMLResponse, JSONResponse, RedirectResponse, Response, StreamingResponse
from starlette.routing import Mount, Route
from starlette.staticfiles import StaticFiles

from . import board as B
from . import colors as CLR
from . import credit as CR
from . import debuglog as DL
from . import foryou as FY
from . import lanenames as LNM
from . import lanes as LN
from . import lanestate as LS
from . import machines as MCH
from . import mockup as MK
from . import projpick as PP
from . import quota as Q
from . import schedules as SCH
from . import search as SRC
from . import scopes as SC
from . import spend as SPD
from . import sentimages as SI
from . import sessions as S
from . import spawn as SP
from . import timingdebug as TD
from . import tz as TZ
from . import tmuxio as T
from . import transcript as TR
from . import unread as UR
from . import usage as USG
from . import usage_digest as USGD
from .config import SHELL_SESSION, Settings, brand_suffix, help_session, owner_name

STATIC = Path(__file__).parent / "static"
IMAGE_TYPES = {"image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp"}
UPLOAD_RE = re.compile(r"^[0-9a-f]{32}\.(png|jpg|gif|webp)$")
UPLOAD_MAX_AGE_DAYS = 30
# Any other file: stored as uploads/<32 hex>/<safe name>, the folder random per upload, the name the file's own
# made safe by safe_upload_name(); the reference the page sends back is "<hex>/<name>" (valid_file_ref()).
UPLOAD_DIR_RE = re.compile(r"^[0-9a-f]{32}$")
UPLOAD_NAME_MAX_CHARS = 120
UPLOAD_NAME_MAX_BYTES = 240   # a file name is 255 bytes at most on ext4; 120 non-ASCII letters would not fit
UPLOAD_PARTIAL = ".partial"   # what a file is called while it streams in; a safe name never starts with a dot
UPLOAD_PARTIAL_MAX_AGE_S = 86400
UPLOAD_CHUNK = 1024 * 1024    # written to disk in pieces of this size
UPLOAD_DISK_CHECK_EVERY = 64 * 1024 * 1024
TAIL_N = 200
SEARCH_PARALLEL = 2           # transcript searches that may run at once (each reads a lot; a third is refused with a sentence)
SEARCH_DEFAULT_HOURS = 24
DUP_WINDOW = 20.0  # seconds: an identical send to the same pane inside this is a double submit
PREFS_MAX_BYTES = 64 * 1024
PREFS_MAX_GROUPS = 500
PREFS_DEFAULTS = {"scopeOrder": [], "groupOrder": [], "sessionOrder": [], "collapsed": [],
                  "laneOrder": [], "showAll": False, "unreadOnly": False, "showTools": False, "shellHeight": 300, "lang": "en"}
PREFS_LISTS = ("scopeOrder", "groupOrder", "sessionOrder", "collapsed", "laneOrder")
PREFS_BOOLS = ("showAll", "unreadOnly", "showTools")
PREFS_LANGS = ("en", "ko")        # the interface languages (static/i18n.js); English is the default
SHELL_HEIGHT_RANGE = (120, 4000)   # px, the Shell drawer's height on a wide screen; the page keeps it inside the window
SSE_RETRY_MS = 1000           # EventSource reconnect delay after the stream drops (a restart)
LIVE_EVERY = 0.7              # seconds between two captures of a pane that runs a `!` command (the stream's "live" event: one tick of its 0.75 s loop)
LIVE_LOOK_EVERY = 2.0         # ... when none was seen running: a look at the pane for one (Claude Code 2.1.312 does not record it in the transcript)
STOP_WAIT = 1.0               # seconds between Stop's Escape and its Ctrl-C (sent only if the command still runs)
GRACEFUL_SHUTDOWN_S = 8       # longest send (paste, wait for the image chips, Enter) finishes; streams end at once
SD_LISTEN_FDS_START = 3       # systemd socket activation passes the listening socket as fd 3


def _git_commit(start: Path | None = None) -> str:
    """The short commit of the checkout this process was started from ("" outside one). Read once at start: it names
    the Python code running, which only a restart changes. git finds the checkout itself, walking up from the package's
    directory (`git -C`): sala-web is web/ of the salamander repo (Wed Oct 14th 2026), whose .git is above web/, so a
    look for web/.git (what this did when web/ was a repository of its own) would find nothing there."""
    try:
        out = subprocess.run(["git", "-C", str(start or Path(__file__).resolve().parent), "rev-parse", "--short", "HEAD"],
                             capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return ""
    return out.stdout.strip() if out.returncode == 0 else ""


def _systemd_listen_fd() -> int | None:
    """fd 3 when systemd passed exactly one listening socket to this process (socket activation), else None."""
    pid, fds = os.environ.get("LISTEN_PID"), os.environ.get("LISTEN_FDS", "0")
    for k in ("LISTEN_PID", "LISTEN_FDS", "LISTEN_FDNAMES"):  # not for the children (tmux, the roles command)
        os.environ.pop(k, None)
    if pid != str(os.getpid()):
        return None
    try:
        n = int(fds)
    except ValueError:
        return None
    if n != 1:
        if n > 1:
            print(f"sala-web: systemd passed {n} sockets; expected 1", file=sys.stderr)
        return None
    return SD_LISTEN_FDS_START


def _bound_path(fd: int) -> Path | None:
    """The unix path the listening socket on `fd` is bound to (socket activation), or None."""
    try:
        s = socket.socket(fileno=os.dup(fd))
    except OSError:
        return None
    try:
        name = s.getsockname()
    except OSError:
        return None
    finally:
        s.close()
    return Path(name) if isinstance(name, str) and name.startswith("/") else None


def link_compat_sockets(settings: Settings, own: Path) -> list[tuple[Path, Path]]:
    """Keep the old socket paths working (Settings.compat_socket, compat_ttyd_socket): each old path whose parent
    directory exists becomes a symlink to the socket it stands for (this app's own, `own`; ttyd's), so a proxy that
    still points at the old path reaches the new one. A stale socket or an older link at the old path is replaced;
    anything else there (a file, a directory) is left alone and reported. Returns the links made."""
    made = []
    for old, target in ((settings.compat_socket, own), (settings.compat_ttyd_socket, settings.ttyd_socket)):
        if old is None or old == target:
            continue
        if not old.parent.is_dir():
            print(f"sala-web: {old.parent} does not exist; the old socket path {old} is not linked", file=sys.stderr)
            continue
        try:
            st = old.lstat()
        except FileNotFoundError:
            st = None
        except OSError as e:
            print(f"sala-web: cannot look at {old}: {e}", file=sys.stderr)
            continue
        if st is not None:
            if not (stat.S_ISLNK(st.st_mode) or stat.S_ISSOCK(st.st_mode)):
                print(f"sala-web: {old} is neither a socket nor a link; left alone", file=sys.stderr)
                continue
            if stat.S_ISLNK(st.st_mode) and os.readlink(old) == str(target):
                made.append((old, target))
                continue
        try:
            tmp = old.with_name(f".{old.name}.{os.getpid()}")
            with contextlib.suppress(FileNotFoundError):
                tmp.unlink()
            os.symlink(target, tmp)
            os.replace(tmp, old)   # atomic: a proxy connecting meanwhile finds either the old socket or the link
        except OSError as e:
            print(f"sala-web: cannot link {old} to {target}: {e}", file=sys.stderr)
            continue
        print(f"sala-web: the old socket path {old} now points at {target}", file=sys.stderr)
        made.append((old, target))
    return made


def _safe_char(ch: str) -> bool:
    return ch in "._-" or (ch.isascii() and ch.isalnum()) or (not ch.isascii() and (ch.isalpha() or ch.isdecimal()))


def safe_upload_name(raw: str) -> str:
    """A file name made safe to store and to paste into a pane unquoted: no path part, no control character, only
    letters (non-ASCII ones too), digits, dot, dash and underscore; whitespace and every other character become an
    underscore (runs of them one), runs of dots one dot, no leading dot, 120 characters and 240 bytes at most with the
    extension kept, never empty ("file")."""
    name = unicodedata.normalize("NFC", raw or "")
    name = re.split(r"[/\\]", name)[-1]
    name = "".join(ch for ch in name if unicodedata.category(ch)[0] != "C")
    name = "".join(ch if _safe_char(ch) else "_" for ch in name)
    name = re.sub(r"_{2,}", "_", re.sub(r"\.{2,}", ".", name)).lstrip(".")
    stem, dot, ext = name.rpartition(".")
    if not dot or len(ext) > 20:  # no extension, or a tail too long to be one: cut the whole name
        stem, ext = name, ""
    else:
        ext = "." + ext
    while stem and (len(stem) + len(ext) > UPLOAD_NAME_MAX_CHARS or len((stem + ext).encode()) > UPLOAD_NAME_MAX_BYTES):
        stem = stem[:-1]
    return (stem + ext).lstrip(".") or "file"


def valid_file_ref(ref: str) -> bool:
    """"<32 hex>/<name>" with a name that safe_upload_name() could have made: nothing else is a stored file."""
    folder, sep, name = ref.partition("/")
    return bool(sep and UPLOAD_DIR_RE.match(folder) and name and safe_upload_name(name) == name
                and ".." not in name and "/" not in name)


def _err(status: int, msg: str) -> JSONResponse:
    return JSONResponse({"ok": False, "error": msg}, status_code=status)


def _cross_origin(request: Request) -> bool:
    """A POST from another site. With the JSON / image content types required below, a browser must preflight a
    cross-site request (which fails: no CORS headers), and a request that carries an Origin must match the Host.
    The Host it came in on, not a fixed hostname: whatever host the page was served from posts to its own."""
    origin = request.headers.get("origin")
    if not origin or origin == "null":
        return origin == "null"
    return urlsplit(origin).netloc.lower() != (request.headers.get("host") or "").lower()


def _validate_prefs(body: object) -> dict | str:
    """The known keys of a prefs object, checked; an error message for anything else (unknown keys included)."""
    if not isinstance(body, dict):
        return "prefs must be a JSON object"
    unknown = sorted(set(body) - set(PREFS_DEFAULTS))
    if unknown:
        return f"unknown prefs keys: {', '.join(unknown)}"
    out: dict = {}
    for name in PREFS_LISTS:
        if name not in body:
            continue
        keys = body[name]
        if not isinstance(keys, list) or not all(isinstance(k, str) and 0 < len(k) <= 512 for k in keys):
            return f"{name} must be a list of non-empty strings"
        if len(keys) > PREFS_MAX_GROUPS:
            return f"{name} has more than {PREFS_MAX_GROUPS} entries"
        out[name] = list(dict.fromkeys(keys))  # drop repeats, keep the first place
    for name in PREFS_BOOLS:
        if name not in body:
            continue
        if not isinstance(body[name], bool):
            return f"{name} must be true or false"
        out[name] = body[name]
    if "shellHeight" in body:
        h = body["shellHeight"]
        if isinstance(h, bool) or not isinstance(h, int) or not SHELL_HEIGHT_RANGE[0] <= h <= SHELL_HEIGHT_RANGE[1]:
            return f"shellHeight must be a whole number from {SHELL_HEIGHT_RANGE[0]} to {SHELL_HEIGHT_RANGE[1]}"
        out["shellHeight"] = h
    if "lang" in body:
        if body["lang"] not in PREFS_LANGS:
            return f"lang must be one of {', '.join(PREFS_LANGS)}"
        out["lang"] = body["lang"]
    return out


def _read_prefs(path: Path) -> dict:
    """Saved prefs over the defaults; a missing or unreadable file gives the defaults."""
    prefs = json.loads(json.dumps(PREFS_DEFAULTS))
    try:
        saved = json.loads(path.read_text())
    except (OSError, ValueError):
        return prefs
    if isinstance(saved, dict):
        for k in PREFS_DEFAULTS:  # key by key: one bad or unknown key does not lose the others
            if k in saved and isinstance(ok := _validate_prefs({k: saved[k]}), dict):
                prefs.update(ok)
    return prefs


def _write_prefs(path: Path, prefs: dict) -> None:
    """Write to a temp file in the same directory, fsync, then rename over the old file: a reader sees the old
    prefs or the new ones, never half a file."""
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".prefs-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(prefs, f, ensure_ascii=False)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


class RevalidatedStatic(StaticFiles):
    """Static files that the browser re-checks on every load (a cheap 304 by ETag), so a deploy shows at the next
    reload instead of after the browser's heuristic cache expires."""

    async def get_response(self, path: str, scope) -> Response:
        resp = await super().get_response(path, scope)
        resp.headers["Cache-Control"] = "no-cache"
        return resp


def create_app(settings: Settings | None = None) -> Starlette:
    settings = settings or Settings()
    roles = S.RolesCache(settings)
    models = TR.ModelCache()
    # which front agents have a reply the owner has not opened yet (unread.py): the sidebar's orange count
    read_state = UR.ReadState(settings.state_dir / UR.FILE_NAME, settings.projects_dir)
    catalogs = S.CatalogCache()  # each claude binary's model catalog, scanned once: resolves a bare --model alias
    # the account lanes that have a quota: subscription-1 is the login in claude_dir (~/.claude), subscription-2 is sala's second login
    quota = Q.QuotaCache({"subscription-1": settings.claude_dir, **S.LANE_DIRS}, state_dir=settings.state_dir)
    credit = CR.CreditCache(settings.admin_key, settings.state_dir / "api-spend.json")

    async def lane_configured() -> dict[str, bool | None]:
        """Whether sala's lane table says each AWS lane is set up (status other than "not set up"); {} when it cannot be read."""
        rc, out, _err = await SP.run([*SP.resolve_cmd(settings.sala_cmd), "lane", "--json"], LN.TIMEOUT)
        if rc != 0:
            return {}
        rows = LN.parse_table(out)
        return {lane: r["status"] != "not set up" for lane in SPD.LANES if (r := LN.record_of(rows, lane))}

    async def lane_table() -> list[dict]:
        """sala's lane table rows (`sala lane --json`), [] when it cannot be read: the Usage analysis tab's billed-or-flat flag per lane."""
        rc, out, _err = await SP.run([*SP.resolve_cmd(settings.sala_cmd), "lane", "--json"], LN.TIMEOUT)
        return LN.parse_table(out) if rc == 0 else []

    async def run_lane_names() -> str | None:
        """`sala lane names --json`: its output, None when sala did not print it (no such command yet, a failure, a timeout)."""
        try:
            rc, out, _err = await SP.run([*SP.resolve_cmd(settings.sala_cmd), "lane", "names", "--json"], LNM.TIMEOUT)
        except (OSError, TimeoutError):
            return None
        return out if rc == 0 else None

    lane_names = LNM.LaneNames(run_lane_names, settings.sala_state_dir)

    # the aws-platform and bedrock lanes' month-to-date spend, counted from the transcripts (spend.py)
    spend = SPD.SpendCache(settings, lambda: S.read_live_sessions(settings), lane_configured)
    # the Usage analysis tab (usage.py): every reply on this machine at list prices, by week, day, lane, model, project, agent and folder
    usage = USG.UsageCache(settings, lambda: S.read_live_sessions(settings), lane_table, lane_names.rows,
                           lambda: quota.get(dormant_lanes()))
    # the board items of every live session: one round of client-API reads a minute, served from the cache
    board = B.BoardCache(settings.stackshot_token, settings.stackshot_url, settings.stackshot_web,
                         settings.state_dir / "board-items.json")
    # stackshot's For you list (foryou.py): one read a minute, Seen and Watch / Mute through the same token
    foryou_calls = FY.Calls(settings.stackshot_token, settings.stackshot_url)
    foryou = FY.ForYouCache(foryou_calls)
    # the color tool's saved combinations (colors.py): stackshot's one list on the account, not cached, the same token
    color_calls = CLR.Calls(settings.stackshot_token, settings.stackshot_url)
    send_locks: dict[str, asyncio.Lock] = {}
    last_sent: dict[str, tuple] = {}
    prefs_lock = asyncio.Lock()
    # the New session form (spawn.py): the project pages, cached; one spawn through the queue at a time
    pages = SP.PagesCache(settings.brain_dir, settings.page_dirs)
    spawn_lock = asyncio.Lock()
    # the form's project step (projpick.py): stackshot's project calls with this machine's board token; a new project's
    # page is made by a job the page asks about, since it can take minutes
    stackshot = PP.Stackshot(settings.stackshot_token, settings.stackshot_url)
    project_jobs = PP.Jobs()
    def spawn_lanes() -> list[str]:
        """The lanes the form offers: the spawn lanes without the dormant ones (a dormant lane is refused by sala too)."""
        d = dormant_lanes()
        return [lane for lane in S.SPAWN_LANES if lane not in d]
    prefs_path = settings.state_dir / "prefs.json"
    commit = _git_commit()
    # set when the server starts shutting down (a restart): open SSE streams end at once instead of holding the stop
    shutting_down = threading.Event()

    def _asset_version() -> str:
        # newest mtime under static/: a deploy changes it, so the page's asset URLs change and no cached copy is used
        return str(int(max(p.stat().st_mtime for p in STATIC.rglob("*") if p.is_file())))

    def build_version() -> str:
        # what an open page compares with the version it loaded: a fast-forward changes the static mtimes at once
        # (static/ is served from the tree), a restart changes the commit
        v = _asset_version()
        return f"{v}-{commit}" if commit else v

    async def index(request: Request) -> Response:
        # /?arg=<tmux session> was ttyd's own URL before sala-web took the host: keep those links working
        if "arg" in request.query_params:
            return RedirectResponse("/terminal?" + request.url.query, status_code=302)
        return _page("index.html")

    async def v2_moved(request: Request) -> Response:
        # /v2 was where the new look was tried before it became the page: an old bookmark and the installed app's older link land on /.
        # Temporary (the address is dropped later), relative so it holds under whatever path prefix a proxy adds, the query kept and the
        # path not (/v2/x -> /; /?arg= then goes on to /terminal as it always did). One "../" for each directory the request is under:
        # /v2 -> ./, /v2/ and /v2/x -> ../, /v2/a/b -> ../../
        path = request.url.path
        up = "../" * (1 + path[len("/v2/"):].count("/")) if path.startswith("/v2/") else "./"
        return RedirectResponse(up + ("?" + request.url.query if request.url.query else ""), status_code=307)

    async def terminal_page(request: Request) -> Response:
        # the full-size terminal (the Shell drawer's "Open full size", the old /?arg= links): ttyd's page in a frame that fills the
        # window, so that the clipboard code (static/termclip.js) is on it; bare /tty/ in a tab has none. Under the same login as
        # "/" (the proxy sends only /tty to ttyd, everything else here), and ?arg=<tmux session> is read by the page, not here.
        return _page("terminal.html")

    def _page(name: str) -> Response:
        # the title bar's text is in the served page (paintBrand only repaints it), so a reload shows no flash of the bare name.
        suffix = brand_suffix()
        brand = htmllib.escape("salamander : " + suffix if suffix else "salamander")
        html = ((STATIC / name).read_text().replace("{{build}}", build_version()).replace("{{v}}", _asset_version())
                .replace("{{brand}}", brand).replace("{{owner}}", htmllib.escape(owner_name()))
                .replace("{{lang}}", _read_prefs(prefs_path)["lang"]))   # the saved language is in the served page: no flash of the other
        # the overview's Get Help chip opens the session SALA_HELP_SESSION names; with none set the chip is not in the page
        help_ = help_session()
        html = (html.replace("{{help}}", htmllib.escape(help_)) if help_
                else re.sub(r"<!--help-->.*?<!--/help-->", "", html, flags=re.S))
        return HTMLResponse(html, headers={"Cache-Control": "no-cache"})

    async def sessions_page(request: Request) -> Response:
        # the overview is a view of the main page now; links and bookmarks to the old page land on it. Relative, so
        # it resolves against whatever host and path prefix the browser used
        return RedirectResponse("./#sessions", status_code=302)

    async def manifest(request: Request) -> Response:
        # The web app manifest, at the root: its start_url and scope ("./") resolve against its own URL, so the app
        # is the whole site. The page links it with crossorigin="use-credentials" (Cloudflare Access: without the
        # cookie the fetch gets the login redirect and the browser sees no manifest). Re-checked on every load, like
        # the static files, so a change shows at the next reload.
        return FileResponse(STATIC / "manifest.webmanifest", media_type="application/manifest+json",
                            headers={"Cache-Control": "no-cache"})

    async def service_worker(request: Request) -> Response:
        # At the root, not under /static/: a service worker controls only what is under the path it is served
        # from. No-cache: the browser re-reads it on every check, so a changed worker takes over at the next load.
        return FileResponse(STATIC / "sw.js", media_type="text/javascript", headers={"Cache-Control": "no-cache"})

    async def mockup_page(request: Request) -> Response:
        # A page `sala mockup add` stored, served at the terminal's own address, so EVERY answer here (a page, a 404, a 405) carries the
        # sandbox headers of mockup.py. Read-only; the sign-in is the proxy's, as for every route. "n" is the number as written in the address.
        if request.method not in ("GET", "HEAD"):
            return Response("method not allowed", status_code=405, media_type="text/plain",
                            headers={**MK.HEADERS, "Allow": "GET, HEAD"})
        raw = request.path_params.get("n", "")
        body = await run_in_threadpool(MK.read_page, settings.mockups_dir, raw)
        if body is None:
            return Response("no such mockup", status_code=404, media_type="text/plain", headers=MK.HEADERS)
        try:
            text = body.decode("utf-8")
        except UnicodeDecodeError:   # the CLI only stores UTF-8; a file put there by hand that is not is not served as if it were
            return Response("this mockup is not UTF-8 text", status_code=415, media_type="text/plain", headers=MK.HEADERS)
        return HTMLResponse(text, headers=MK.HEADERS)   # text/html; charset=utf-8

    async def config(request: Request) -> Response:
        # shellSession and host name the Shell drawer (sala's SALA_SHELL_SESSION and this machine); timezone (SALA_TZ, "" = the
        # viewer's own zone), tzLabel and tzOffsetMin say which zone every time shown is in (tz.py); brand is the suffix of the
        # title bar's "salamander" (SALA_BRAND_SUFFIX, "" = none), scopes and defaultScope the project scopes (scopes.py)
        return JSONResponse({"terminalUrl": settings.terminal_url, "version": build_version(), "commit": commit,
                             "shellSession": SHELL_SESSION, "host": socket.gethostname().split(".")[0], "brand": brand_suffix(),
                             "scopes": SC.names(), "defaultScope": SC.default(), **TZ.info()},
                            headers={"Cache-Control": "no-store"})

    async def list_sessions(request: Request) -> Response:
        live = await run_in_threadpool(S.read_live_sessions, settings)
        await run_in_threadpool(lambda: S.attach_agent_ids(live, S.load_agent_rows(settings.sala_state_dir / "sessions.json")))
        r = await roles.get()
        scopes = S.group_sessions(live, r, await run_in_threadpool(S.side_records, settings.sala_state_dir / "side"), await pages.types())
        await run_in_threadpool(read_state.annotate, scopes)   # sets each session's "unread_count" and "unread"
        # "groups" is the same projects as a flat list, for clients that predate scopes
        return JSONResponse({"scopes": scopes, "groups": [g for sc in scopes for g in sc["groups"]],
                             "rolesError": roles.last_error})

    def _overview_rows(r: dict[str, dict], types: dict[str, str] | None) -> list[dict]:
        rows = S.overview_rows(S.read_live_sessions(settings), r, S.side_records(settings.sala_state_dir / "side"), types)
        records = S.sala_models(settings.sala_models)  # read once per poll; {} when sala keeps no record
        # what the CLI follows with no flag and no record: the default lane's settings.json, as the New session
        # form reads it; one small file, read once per poll like the record ("" for what it cannot read: no default)
        default = SP.claude_defaults(settings.claude_dir)
        for row in rows:
            path = TR.transcript_path(settings.projects_dir, row.pop("cwd"), row["sessionId"])
            reply = models.get(path) if path else {}
            pid = row["pid"]
            # a pane with its own CLAUDE_CONFIG_DIR may follow another settings file: no default for it
            cfg = S.pane_config_dir(pid)
            own = bool(cfg) and Path(cfg).resolve() != settings.claude_dir.resolve()
            row.update(S.running_model(S.launch_flags(pid), records.get(row.pop("tmuxSession")), reply,
                                       row.pop("startedAt"), S.model_env(pid), catalogs.for_pid(pid),
                                       None if own else default))
        return rows

    async def overview(request: Request) -> Response:
        r = await roles.get()
        rows = await run_in_threadpool(_overview_rows, r, await pages.types())
        return JSONResponse({"sessions": rows, "rolesError": roles.last_error}, headers={"Cache-Control": "no-store"})

    def dormant_lanes() -> dict[str, dict]:
        """The lanes sala's record says are dormant (lanestate.py; read at each request, a small file): their card is one
        line, they are asked nothing, and the New session form does not offer them."""
        return LS.dormant(settings.sala_state_dir / "lane-state.tsv")

    async def get_lane_names(request: Request) -> Response:
        return JSONResponse(await lane_names.get(), headers={"Cache-Control": "no-store"})

    async def get_quota(request: Request) -> Response:
        return JSONResponse({"lanes": await quota.get(dormant_lanes())}, headers={"Cache-Control": "no-store"})

    async def get_credit(request: Request) -> Response:
        # the API key's spend is the card's figure whether the lane is active or dormant (a dormant lane still shows its
        # period's spend): the same cache and the same Admin API read, at most every 15 minutes (a read of the org's cost report
        # with the admin key, which is not the inference key whose credit ran out); the dormant record is added beside it
        out = dict(await credit.get())
        d = dormant_lanes().get("api")
        if d:
            out.update({"lane": "api", "dormant": d})
        return JSONResponse(out, headers={"Cache-Control": "no-store"})

    async def get_spend(request: Request) -> Response:
        # the count is from this machine's own transcripts and asks nobody anything, so a dormant lane keeps its figures;
        # its entry only gains "dormant" (a dormant lane the count has not reached yet is just {lane, dormant}: the card says pending)
        out = spend.get()
        dormant = dormant_lanes()
        lanes = [{**x, "dormant": dormant[x["lane"]]} if x.get("lane") in dormant else x for x in out.get("lanes") or []]
        have = {x.get("lane") for x in lanes}
        lanes += [{"lane": lane, "dormant": dormant[lane]} for lane in SPD.LANES if lane in dormant and lane not in have]
        out["lanes"] = lanes
        return JSONResponse(out, headers={"Cache-Control": "no-store"})

    async def get_usage(request: Request) -> Response:
        # the Usage analysis tab (usage.py): the last saved count at once, whoever asks and however old it is (the daily job, usage_job.py, counts);
        # only ?fresh=1 (the Reload button) starts a count, in a thread; ?week=0|1|2 picks the range
        try:
            week = int(request.query_params.get("week", "0"))
        except ValueError:
            week = -1
        if week not in range(USG.WEEKS):
            return JSONResponse({"error": "week must be 0, 1 or 2"}, status_code=400, headers={"Cache-Control": "no-store"})
        return JSONResponse(usage.get(week, fresh=request.query_params.get("fresh") == "1"), headers={"Cache-Control": "no-store"})

    async def get_usage_digest(request: Request) -> Response:
        # the Usage analysis tab's Digest view (usage_digest.py): the week in a few plain sentences written by code from the same saved count as
        # /api/usage (no second scan; "noCount" before the first count, "pending" and "refreshing" while a Reload's count runs); ?week=0|1|2 and ?fresh=1 as /api/usage
        try:
            week = int(request.query_params.get("week", "0"))
        except ValueError:
            week = -1
        if week not in range(USG.WEEKS):
            return JSONResponse({"error": "week must be 0, 1 or 2"}, status_code=400, headers={"Cache-Control": "no-store"})
        return JSONResponse(USGD.answer(usage.get(week, fresh=request.query_params.get("fresh") == "1")), headers={"Cache-Control": "no-store"})

    async def get_usage_replies(request: Request) -> Response:
        # Explorer's drill-down (usage.py, reply_list): the single replies behind a filter, newest first, capped, from the records the last count left in memory
        # (no transcript is opened); ?week=0|1|2, then any of day, lane, model, project, agent, folder, each once or several times (alternatives), ?limit=<n> up to the cap
        q = request.query_params
        try:
            week = int(q.get("week", "0"))
            limit = int(q.get("limit", str(USG.REPLIES_CAP)))
        except ValueError:
            week, limit = -1, 0
        if week not in range(USG.WEEKS) or limit < 1:
            return JSONResponse({"error": "week must be 0, 1 or 2 and limit a positive number"}, status_code=400, headers={"Cache-Control": "no-store"})
        where = {d: q.getlist(d) for d in USG.REPLY_DIMS if q.getlist(d)}
        return JSONResponse(await usage.replies(week, where, limit), headers={"Cache-Control": "no-store"})

    schedules = SCH.SchedulesCache()

    async def get_schedules(request: Request) -> Response:
        # every scheduled job: the last reading at once, a fresh one read in the background once it is 30 s old (swr.py, the lane cards'
        # way: the read is ~1 s of systemctl calls in a thread, which no page waits on); ?fresh=1 (the Reload button) makes it due now
        out = schedules.get(fresh=request.query_params.get("fresh") == "1")
        return JSONResponse(out, headers={"Cache-Control": "no-store"})

    async def get_machines(request: Request) -> Response:
        # the Machines tab (machines.py): stackshot's last reading of the machines' versions, a few small files read at each request
        # (in a thread), never cached, never a call to GitHub or to a machine; a missing file is "no reading yet"
        out = await run_in_threadpool(lambda: MCH.collect(settings))
        return JSONResponse(out, headers={"Cache-Control": "no-store"})

    search_gate = asyncio.Semaphore(SEARCH_PARALLEL)

    async def get_search(request: Request) -> Response:
        # a search of this machine's transcripts (search.py): text, a range and on/off switches in, matches (snippets) out. No
        # parameter is a path or a file name, nothing is written, and a search reads a lot, so two run at a time at most
        qp = request.query_params

        def on(name: str, default: bool) -> bool:
            v = qp.get(name)
            return default if v is None else v.lower() in ("1", "true", "on", "yes")

        try:
            words = SRC.parse_words(qp.get("q", ""))
            now = time.time()
            if "from" in qp or "to" in qp:
                since = SRC.parse_when(qp.get("from", ""), TZ.zone())
                until = SRC.parse_when(qp["to"], TZ.zone()) if "to" in qp else now
            else:
                since, until = now - float(qp.get("hours", SEARCH_DEFAULT_HOURS)) * 3600, now
            if not (0 < since < until < 4e9) or until - since > SRC.MAX_RANGE_S:
                raise SRC.SearchError("That time range is not one a search can use (the start before the end, at most a year).")
        except SRC.SearchError as e:
            return _err(400, str(e))
        except ValueError:
            return _err(400, "That time range is not one a search can use.")
        params = SRC.Params(
            words=words, since=since, until=until,
            agents={c for c in SRC.AGENT_CATS if on(c, True)},
            content={k for k, d in (("messages", True), ("tools", True), ("output", False), ("thinking", False)) if on(k, d)})
        if search_gate.locked():
            return _err(429, "Two searches are already running; try again in a moment.")
        async with search_gate:
            r = await roles.get()
            out = await run_in_threadpool(SRC.run, params, settings.projects_dir, settings.sala_state_dir / "sessions.json", r)
        out["timezone"], out["tzLabel"] = TZ.setting(), TZ.label()
        return JSONResponse(out, headers={"Cache-Control": "no-store"})

    async def get_lane(request: Request) -> Response:
        # a lane's details page: its record from sala's lane table (`sala lane --json`, read-only; lanes.py takes
        # every file path out of it), and its state from lane-state.tsv. A table sala cannot print is {"record": null,
        # "error"}: the page says so and still shows the rest from the answers it already has
        lane = request.path_params["lane"]
        if not LN.LANE_ID_RE.match(lane):
            return _err(400, "that is no lane id")
        canonical = LS.norm(lane)
        rows, error = None, None
        try:
            rc, out, err = await SP.run([*SP.resolve_cmd(settings.sala_cmd), "lane", "--json"], LN.TIMEOUT)
            if rc != 0:
                error = f"sala exited {rc}"
            else:
                rows = LN.parse_table(out)
        except (OSError, TimeoutError) as e:
            error = f"could not run sala: {e}"
        except ValueError as e:
            error = str(e)
        record = LN.record_of(rows, lane) if rows is not None else None
        if rows is not None and record is None:
            return _err(404, "sala's lane table has no such lane")
        state = LN.state_of(record, dormant_lanes().get(canonical))
        return JSONResponse({"lane": canonical, "record": record, "state": state, "error": error},
                            headers={"Cache-Control": "no-store"})

    async def get_board_items(request: Request) -> Response:
        # the live sessions' names are the keys the board knows them by (the pane name, as the sidebar lists them)
        live = await run_in_threadpool(S.read_live_sessions, settings)
        return JSONResponse(await board.get([s.name for s in live]), headers={"Cache-Control": "no-store"})

    def _session(request: Request) -> S.Session | None:
        try:
            pid = int(request.path_params["pid"])
        except (KeyError, ValueError):
            return None
        return S.find_session(settings, pid)

    async def _own_pane(s: S.Session) -> str | None:
        """The session's tmux pane when it is one of its own (the pane's process is the session's process or its ancestor),
        else None: the check send makes before it types anything, made before a capture or a key here too."""
        pane = s.pane_id
        if not pane:
            return None
        try:
            return pane if S.is_same_or_descendant(s.pid, await T.pane_pid(settings, pane)) else None
        except T.TmuxError:
            return None

    async def _bang_screen(pane: str, bang: dict | None = None) -> dict | None:
        """{"command", "text"} of the `!` command running in the pane, or None. The pane decides (Claude Code
        2.1.312 writes nothing to the transcript while the command runs and keeps its input box): T.bang_pane reads the
        capture. The fallback, only when a transcript record `bang` says a command runs: a pane that shows no input box
        at all is that command's, as live_text shows it."""
        try:
            captured = await T.capture(settings, pane)
        except T.TmuxError:
            return None
        got = T.bang_pane(captured)
        if got is None and bang and T.input_box(captured)[0] == "missing":
            got = {"command": bang.get("command") or "", "text": T.live_text(captured, bang.get("command") or "")}
        return got

    async def get_transcript(request: Request) -> Response:
        s = _session(request)
        if not s:
            return _err(404, "no live session with that pid")
        path = TR.transcript_path(settings.projects_dir, s.cwd, s.session_id)
        if not path:
            return JSONResponse({"session": s.to_json(), "messages": [], "offset": 0, "path": None})
        try:
            n = max(1, min(int(request.query_params.get("n", TAIL_N)), 2000))
        except ValueError:
            return _err(400, "n is not an integer")
        before = request.query_params.get("before")
        around = request.query_params.get("around")
        after = request.query_params.get("after")
        if sum(x is not None for x in (before, around, after)) > 1:
            return _err(400, "give one of before, around and after")
        # a page around a line (a Search result's pos) or after a cursor a page gave: a byte offset into this session's own
        # transcript, checked as `before` is; `after` is the cursor for the next newer page, `end` that the live end is in
        if around is not None:
            try:
                d = await run_in_threadpool(TR.read_around, path, s.session_id, around, n)
            except TR.BadCursor as e:
                return _err(400, str(e))
            return JSONResponse({"session": s.to_json(), **d})
        if after is not None:
            try:
                msgs, cursor, at_end = await run_in_threadpool(TR.read_after, path, s.session_id, after, n)
            except TR.BadCursor as e:
                return _err(400, str(e))
            return JSONResponse({"session": s.to_json(), "messages": msgs, "after": cursor, "end": at_end})
        if before is None:
            msgs, cursor, off = await run_in_threadpool(TR.read_tail_page, path, s.session_id, n)
            return JSONResponse({"session": s.to_json(), "messages": msgs, "offset": off, "path": str(path),
                                 "before": cursor, "start": cursor == 0})
        # an older page: the messages that end before the cursor a page gave (a byte offset into this session's own
        # transcript; the path is the server's, never the client's)
        try:
            msgs, cursor, at_start = await run_in_threadpool(TR.read_before, path, s.session_id, before, n)
        except TR.BadCursor as e:
            return _err(400, str(e))
        return JSONResponse({"session": s.to_json(), "messages": msgs, "before": cursor, "start": at_start})

    async def stream(request: Request) -> Response:
        s0 = _session(request)
        if not s0:
            return _err(404, "no live session with that pid")
        pid = s0.pid

        def ev(name: str, data: object) -> str:
            return f"event: {name}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"

        async def gen():
            # reconnect quickly after the stream drops; then tell the page which build it is talking to
            yield f"retry: {SSE_RETRY_MS}\n\n"
            yield ev("version", {"version": build_version()})
            s = s0
            path: Path | None = None
            off = 0
            status = None
            announced_empty = False
            last_ping = time.monotonic()
            last_check = 0.0
            # a running `!` command: Claude Code writes its output to the transcript when it ends, and in 2.1.312
            # nothing before, so the pane is what tells and shows it: a capture every LIVE_LOOK_EVERY s looks for one
            # (LIVE_EVERY s while one is shown). bang = the transcript's latest `!` record when it is a <bash-input> with no
            # output record yet (a fallback for a Claude Code that records it, kept up to date from the lines the stream
            # reads; it speeds up the first look and supplies the uuid); live_sent = the last "live" payload the page was
            # given (None: the page shows nothing); live_every = seconds between two captures (slow again after three looks
            # that find nothing though the record says a command runs, a stale record)
            bang: dict | None = None
            pane: str | None = None
            live_sent: dict | None = None
            last_live = 0.0
            live_every = LIVE_LOOK_EVERY
            idle_looks = 0
            while True:
                if shutting_down.is_set() or await request.is_disconnected():
                    return
                now = time.monotonic()
                if now - last_check >= 2 or path is None:
                    last_check = now
                    cur = await run_in_threadpool(S.find_session, settings, pid)
                    if cur is None:
                        yield ev("gone", {"pid": pid})
                        return
                    if cur.status != status:
                        status = cur.status
                        yield ev("status", {"status": status})
                    if path is None or cur.session_id != s.session_id:
                        changed = cur.session_id != s.session_id
                        s = cur
                        path = TR.transcript_path(settings.projects_dir, s.cwd, s.session_id)
                        if path is not None:
                            msgs, cursor, off = await run_in_threadpool(TR.read_tail_page, path, s.session_id, TAIL_N)
                            # before: the cursor for an older page (GET transcript?before=); start: there is none
                            yield ev("reset", {"session": s.to_json(), "messages": msgs, "before": cursor, "start": cursor == 0})
                            announced_empty = False
                            # the reset replaced the chat, the live block with it: ask again from the transcript
                            bang = await run_in_threadpool(TR.bang_running, path)
                            pane, live_sent, last_live, live_every, idle_looks = None, None, 0.0, LIVE_EVERY if bang else LIVE_LOOK_EVERY, 0
                        elif changed or not announced_empty:
                            # a new session has no transcript until its first prompt: say so once
                            yield ev("reset", {"session": s.to_json(), "messages": [], "note": "no transcript yet"})
                            announced_empty = True
                if path is not None:
                    try:
                        size = path.stat().st_size
                    except OSError:
                        size = -1
                    if size < off:  # rewritten or gone: start over
                        path = None
                        continue
                    if size > off:
                        before = off
                        msgs, off = await run_in_threadpool(TR.read_from, path, s.session_id, off)
                        if msgs:
                            yield ev("append", {"messages": msgs})
                        if off > before:
                            bang = await run_in_threadpool(TR.bang_scan, path, before, off, bang)
                            live_every, idle_looks = LIVE_EVERY if bang else LIVE_LOOK_EVERY, 0
                if now - last_live >= live_every:
                    last_live = now
                    pane = pane or await _own_pane(s)
                    got = await _bang_screen(pane, bang) if pane else None
                    if got is None:
                        idle_looks += 1
                        if idle_looks >= 3 or bang is None:  # nothing running, or a stale record three looks running: look less often
                            live_every = LIVE_LOOK_EVERY
                        if live_sent is not None:  # the command ended (its output record landed, or the pane is back to its prompt): the page drops the block
                            live_sent = None
                            yield ev("live", {"running": False})
                    else:
                        live_every, idle_looks = LIVE_EVERY, 0
                        same = bool(bang) and bang.get("command") == got["command"]
                        payload = {"running": True, "command": got["command"],
                                   "uuid": (bang.get("uuid") or "") if same else "", "text": got["text"]}
                        if payload != live_sent:
                            live_sent = payload
                            yield ev("live", payload)
                if now - last_ping >= 15:
                    last_ping = now
                    yield ": ping\n\n"
                await asyncio.sleep(0.75)

        return StreamingResponse(gen(), media_type="text/event-stream",
                                 headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})

    async def image(request: Request) -> Response:
        sid = request.path_params["sid"]
        uuid = request.path_params["uuid"]
        if not (TR.UUID_RE.match(sid) and TR.UUID_RE.match(uuid)):
            return _err(400, "bad id")
        path = await run_in_threadpool(TR.transcript_path, settings.projects_dir, "", sid)
        if not path:
            return _err(404, "no transcript")
        got = await run_in_threadpool(TR.find_image, path, uuid, int(request.path_params["i"]),
                                      int(request.path_params["j"]))
        if not got:
            return _err(404, "no image")
        mt, data = got
        return Response(data, media_type=mt, headers={"Cache-Control": "private, max-age=86400"})

    async def file_image(request: Request) -> Response:
        sid = request.path_params["sid"]
        uuid = request.path_params["uuid"]
        if not (TR.UUID_RE.match(sid) and TR.UUID_RE.match(uuid)):
            return _err(400, "bad id")
        path = await run_in_threadpool(TR.transcript_path, settings.projects_dir, "", sid)
        if not path:
            return _err(404, "no transcript")
        named = await run_in_threadpool(TR.find_sent_file, path, uuid, request.path_params["i"], request.path_params["k"])
        got = named and await run_in_threadpool(SI.read_sent_image, named[0], named[1], settings.image_roots,
                                                settings.max_sent_image_bytes)
        if not got:
            return _err(404, "no image")
        mt, data = got
        # nosniff and a sandboxing CSP: whatever the bytes are, a browser opening this URL shows an image or nothing
        return Response(data, media_type=mt, headers={
            "Cache-Control": "private, max-age=300", "X-Content-Type-Options": "nosniff",
            "Content-Security-Policy": "default-src 'none'; sandbox"})

    async def md_image(request: Request) -> Response:
        """An image a reply names in its markdown (![caption](/abs/path.png)): served only for the n-th local image of that
        assistant text block, with the same rules as a sent file; a refusal says why (the page shows it in place of the image)."""
        sid = request.path_params["sid"]
        uuid = request.path_params["uuid"]
        if not (TR.UUID_RE.match(sid) and TR.UUID_RE.match(uuid)):
            return _err(400, "bad id")
        path = await run_in_threadpool(TR.transcript_path, settings.projects_dir, "", sid)
        if not path:
            return _err(404, "no transcript")
        named = await run_in_threadpool(TR.find_md_image, path, uuid, request.path_params["i"], request.path_params["n"])
        if not named:
            return _err(404, "the reply does not name this image")
        got = await run_in_threadpool(SI.check_image, named[0], named[1], settings.image_roots, settings.max_sent_image_bytes)
        if isinstance(got, str):
            return _err(404, got)
        mt, data = got
        return Response(data, media_type=mt, headers={
            "Cache-Control": "private, max-age=300", "X-Content-Type-Options": "nosniff",
            "Content-Security-Policy": "default-src 'none'; sandbox"})

    async def upload(request: Request) -> Response:
        if _cross_origin(request):
            return _err(403, "cross-origin request refused")
        ctype = (request.headers.get("content-type") or "").split(";")[0].strip().lower()
        ext = IMAGE_TYPES.get(ctype)
        if not ext:
            if "name" not in request.query_params:  # the page names every file it sends; a bare POST of a type is not one
                return _err(415, f"unsupported image type {ctype or '(none)'} (a file is sent with ?name=<its name>)")
            return await upload_file(request, request.query_params.get("name") or "")
        body = bytearray()
        async for chunk in request.stream():
            body += chunk
            if len(body) > settings.max_upload_bytes:
                return _err(413, "image too large")
        if not body:
            return _err(400, "empty body")
        settings.uploads_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        name = f"{secrets.token_hex(16)}.{ext}"
        dest = settings.uploads_dir / name
        await run_in_threadpool(dest.write_bytes, bytes(body))
        return JSONResponse({"ok": True, "name": name, "path": str(dest)})

    def _free_bytes() -> int:
        return shutil.disk_usage(settings.uploads_dir).free

    async def upload_file(request: Request, raw_name: str) -> Response:
        """Any file, streamed to uploads/<random folder>/<safe name> in pieces, never held whole in memory. Refused as soon
        as the running size passes the limit or the disk would be left under the free-space floor; the folder of a
        refused or broken upload is removed. The file is written under a temporary name and renamed when complete, so a
        reference that exists is a whole file."""
        limit, floor = settings.max_file_upload_bytes, settings.min_free_bytes
        mb = f"{limit / 1048576:g} MB"
        try:
            declared = int(request.headers.get("content-length") or 0)
        except ValueError:
            declared = 0
        if declared > limit:
            return _err(413, f"file too large (limit {mb})")
        root = settings.uploads_dir
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        if _free_bytes() - declared < floor:
            return _err(507, f"not enough disk space on the server for this file (it must leave {floor / 1073741824:g} GB free)")
        safe = safe_upload_name(raw_name)
        folder = root / secrets.token_hex(16)
        dest = folder / safe
        # a name made of safe characters cannot leave its folder; resolved and checked all the same
        if dest.resolve().parent != folder.resolve() or not folder.resolve().is_relative_to(root.resolve()):
            return _err(400, "bad file name")
        folder.mkdir(mode=0o700)
        part = folder / UPLOAD_PARTIAL
        size = checked = 0
        ok = False
        try:
            fd = os.open(part, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as f:
                buf = bytearray()
                async for chunk in request.stream():
                    buf += chunk
                    size += len(chunk)
                    if size > limit:
                        return _err(413, f"file too large (limit {mb})")
                    if len(buf) >= UPLOAD_CHUNK:
                        await run_in_threadpool(f.write, bytes(buf))
                        buf.clear()
                        if size - checked >= UPLOAD_DISK_CHECK_EVERY:
                            checked = size
                            if _free_bytes() < floor:
                                return _err(507, f"the server's disk is nearly full; stopped at {size // 1048576} MB")
                if buf:
                    await run_in_threadpool(f.write, bytes(buf))
            if not size:
                return _err(400, "empty file")
            os.replace(part, dest)
            ok = True
        finally:
            if not ok:  # refused, empty, a dropped connection or a write error: no partial file stays
                await run_in_threadpool(shutil.rmtree, folder, True)
        return JSONResponse({"ok": True, "name": f"{folder.name}/{safe}", "path": str(dest), "file": True,
                             "fileName": safe, "size": size})

    def upload_path(ref: str) -> Path | None:
        """The stored file a reference from the page names, or None: an image's flat name or a file's "<hex>/<name>",
        validated strictly, and its resolved path must lie inside uploads_dir."""
        if not (UPLOAD_RE.match(ref) or valid_file_ref(ref)):
            return None
        root = settings.uploads_dir
        p = root / ref
        return p if p.resolve().is_relative_to(root.resolve()) else None

    async def send(request: Request) -> Response:
        if _cross_origin(request):
            return _err(403, "cross-origin request refused")
        if (request.headers.get("content-type") or "").split(";")[0].strip().lower() != "application/json":
            return _err(415, "send takes application/json")
        s = _session(request)
        if not s:
            return _err(404, "no live session with that pid")
        try:
            body = await request.json()
        except ValueError:
            return _err(400, "body must be JSON")
        text = str(body.get("text") or "").replace("\r\n", "\n").replace("\r", "\n")
        names = body.get("uploads") or []
        if not isinstance(names, list) or not all(isinstance(n, str) for n in names):
            return _err(400, "bad upload names")
        paths = [upload_path(n) for n in names]
        if any(p is None for p in paths):
            return _err(400, "bad upload names")
        if any(not p.is_file() for p in paths):
            return _err(400, "an uploaded file is missing")
        if not text.strip() and not paths:
            return _err(400, "nothing to send")
        pane = s.pane_id
        if not pane:
            return _err(409, "session has no tmux pane on record")
        lock = send_locks.setdefault(pane, asyncio.Lock())
        async with lock:
            # the same message to the same pane within DUP_WINDOW seconds is a double submit: refuse the copy. A
            # dialog answer is a copy only while the same dialog is still open or the input box is back ("1" twice
            # to two dialogs in a row is two answers), so that check waits for the capture in _send_locked.
            sig = (text.strip(), tuple(names))
            prev = last_sent.get(pane)
            repeat = bool(prev and prev[0] == sig and time.monotonic() - prev[1] < DUP_WINDOW and not body.get("force"))
            if repeat and prev[2] is None:
                return _duplicate()
            try:
                resp, answered = await _send_locked(s, pane, text, paths, prev[2] if repeat else None)
                if resp.status_code == 200:
                    last_sent[pane] = (sig, time.monotonic(), answered)
                return resp
            except T.TmuxError as e:
                return _err(502, f"tmux failed: {e}")

    def _duplicate() -> Response:
        return JSONResponse({"ok": False, "duplicate": True, "error": "already sent a moment ago"}, status_code=409)

    async def _send_locked(s: S.Session, pane: str, text: str, paths: list[Path],
                           answered_before: str | None) -> tuple[Response, str | None]:
        """Paste and submit, or answer the dialog the pane shows. Returns the response and, for a dialog answer,
        the dialog's text (what a repeat of the same answer is compared with)."""
        try:
            ppid = await T.pane_pid(settings, pane)
        except T.TmuxError as e:
            return _err(409, f"pane {pane} not found ({e})"), None
        if not S.is_same_or_descendant(s.pid, ppid):
            return _err(409, f"pane {pane} does not belong to session {s.name}; nothing sent"), None
        captured = await T.capture(settings, pane)
        state, _ = T.input_box(captured)
        if state == "missing":
            return await _answer_dialog(pane, captured, text, paths, answered_before)
        if answered_before is not None:
            return _duplicate(), None  # the dialog this answered is gone: a copy now would be typed as a prompt
        if T.shell_mode(captured) and text.lstrip().startswith(T.SHELL):
            # the box is already in shell mode (it starts with "!"): the command's own "!" would be a second one
            text = text.lstrip()[len(T.SHELL):]
            if not text.strip() and not paths:
                return _err(400, "nothing to send after the ! the pane's shell mode already has"), None
        return await _paste_and_submit(pane, state, text, paths), None

    async def _answer_dialog(pane: str, captured: str, text: str, paths: list[Path],
                             answered_before: str | None) -> tuple[Response, str | None]:
        """No input box: if a numbered dialog is open, a lone option number picks it (one keypress, which Claude
        Code's selection dialogs act on at once, no Enter) and "esc" cancels it. Anything else is refused."""
        options, dialog_text = T.dialog(captured)
        if not options:
            return _err(409, "no input box in the pane (a dialog or menu may be open); nothing sent"), None
        if answered_before == dialog_text:
            return _duplicate(), None
        answer = text.strip()
        offer = f"answer with one of {', '.join(options)}, or esc; nothing sent"
        if paths or not (answer in options or answer.lower() == "esc"):
            if answer.isdigit() and not paths:
                return _err(409, f"a dialog is open in the pane and {answer} is not one of its options: {offer}"), None
            return _err(409, f"a dialog is open in the pane: {offer}"), None
        key = "Escape" if answer.lower() == "esc" else answer
        await T.send_key(settings, pane, key)
        return JSONResponse({"ok": True, "dialogAnswer": key, "imagesPasted": 0, "imagesAttached": 0}), dialog_text

    async def _paste_and_submit(pane: str, state: str, text: str, paths: list[Path]) -> Response:
        if state == "text":
            return _err(409, "pane input box is not empty; nothing sent")
        attached = 0
        # the pane turns a pasted image path into an attachment chip, which is what is counted; any other file's path
        # stays text (stored images are flat in uploads/, other files one folder down)
        images = sum(1 for p in paths if p.parent == settings.uploads_dir)
        if paths:
            before = T.count_chips(await T.capture(settings, pane))
            await T.paste(settings, pane, " ".join(str(p) for p in paths))
            for _ in range(20 if images else 0):
                await asyncio.sleep(0.15)
                attached = T.count_chips(await T.capture(settings, pane)) - before
                if attached >= images:
                    break
        if text.strip():
            await T.paste(settings, pane, (" " if paths else "") + text)
        await asyncio.sleep(0.3)
        state, _ = T.input_box(await T.capture(settings, pane))
        if state == "missing":
            return _err(409, "the input box disappeared while pasting; pasted but not submitted")
        await T.send_enter(settings, pane)
        return JSONResponse({"ok": True, "imagesPasted": images, "imagesAttached": max(attached, 0),
                             "filesPasted": len(paths) - images})

    async def stop_bang(request: Request) -> Response:
        """Stop the `!` command running in the session's pane: Escape, and, if the command still runs STOP_WAIT
        seconds later, Ctrl-C. Only while one runs (the pane shows it: T.bang_pane; a transcript record that says one runs
        and a pane without an input box count too); otherwise 409 and nothing is sent. The keys go to that session's own
        pane, under the pane's send lock."""
        if _cross_origin(request):
            return _err(403, "cross-origin request refused")
        if (request.headers.get("content-type") or "").split(";")[0].strip().lower() != "application/json":
            return _err(415, "stop takes application/json")
        s = _session(request)
        if not s:
            return _err(404, "no live session with that pid")
        pane = s.pane_id
        if not pane:
            return _err(409, "session has no tmux pane on record")
        path = TR.transcript_path(settings.projects_dir, s.cwd, s.session_id)

        async def running() -> bool:
            if await _bang_screen(pane) is not None:
                return True
            bang = await run_in_threadpool(TR.bang_running, path) if path else None
            return bool(bang) and await _bang_screen(pane, bang) is not None

        async with send_locks.setdefault(pane, asyncio.Lock()):
            try:
                if await _own_pane(s) != pane:
                    return _err(409, f"pane {pane} does not belong to session {s.name}; nothing sent")
                if not await running():
                    return _err(409, "no ! command is running in this session; nothing sent")
                await T.send_key(settings, pane, "Escape")
                sent = ["Escape"]
                await asyncio.sleep(STOP_WAIT)
                if await running():
                    await T.send_key(settings, pane, T.STOP_KEY)
                    sent.append(T.STOP_KEY)
            except T.TmuxError as e:
                return _err(502, f"tmux failed: {e}")
        return JSONResponse({"ok": True, "sent": sent})

    async def shell_open(request: Request) -> Response:
        """Make sure the Shell drawer's tmux session (SALA_SHELL_SESSION) exists; the drawer calls it each time it opens,
        before it loads (or reloads) the ttyd iframe, because ttyd-tmux-attach attaches only to a session that is there.
        Creates a plain login bash in the home directory when missing, touches an existing one not at all. `created` tells
        the page the old terminal is gone (the shell had ended), so it reloads the iframe."""
        if _cross_origin(request):
            return _err(403, "cross-origin request refused")
        if (request.headers.get("content-type") or "").split(";")[0].strip().lower() != "application/json":
            return _err(415, "shell/open takes application/json")
        try:
            created = await T.ensure_shell_session(settings)
        except (T.TmuxError, OSError, asyncio.TimeoutError) as e:
            return _err(502, f"could not start the shell: {e}")
        return JSONResponse({"ok": True, "session": SHELL_SESSION, "created": created})

    async def shell_keys(request: Request) -> Response:
        """One key of the Shell drawer's key row (the phone's Esc, Tab, Ctrl+letter, arrows, Ctrl+C) into the shell session
: {"key": "<tmux key name>"}, from the fixed list T.SHELL_KEYS only, never text; 400 for anything else.
        Same guards as the other POSTs: the origin check and JSON."""
        if _cross_origin(request):
            return _err(403, "cross-origin request refused")
        if (request.headers.get("content-type") or "").split(";")[0].strip().lower() != "application/json":
            return _err(415, "shell/keys takes application/json")
        try:
            body = await request.json()
        except ValueError:
            return _err(400, "body must be JSON")
        key = body.get("key") if isinstance(body, dict) else None
        if not isinstance(key, str) or key not in T.SHELL_KEYS:
            return _err(400, "key must be one of: " + ", ".join(sorted(T.SHELL_KEYS)))
        try:
            await T.send_shell_key(settings, key)
        except (T.TmuxError, OSError, asyncio.TimeoutError) as e:
            return _err(502, f"tmux failed: {e}")
        return JSONResponse({"ok": True, "sent": key})

    async def get_prefs(request: Request) -> Response:
        return JSONResponse(await run_in_threadpool(_read_prefs, prefs_path), headers={"Cache-Control": "no-store"})

    async def put_prefs(request: Request) -> Response:
        if _cross_origin(request):
            return _err(403, "cross-origin request refused")
        if (request.headers.get("content-type") or "").split(";")[0].strip().lower() != "application/json":
            return _err(415, "prefs take application/json")
        raw = bytearray()
        async for chunk in request.stream():
            raw += chunk
            if len(raw) > PREFS_MAX_BYTES:
                return _err(413, "prefs too large")
        try:
            body = json.loads(raw)
        except ValueError:
            return _err(400, "body must be JSON")
        patch = _validate_prefs(body)
        if isinstance(patch, str):
            return _err(400, patch)
        async with prefs_lock:
            prefs = await run_in_threadpool(_read_prefs, prefs_path)
            prefs.update(patch)
            if len(json.dumps(prefs, ensure_ascii=False).encode()) > PREFS_MAX_BYTES:
                return _err(413, "prefs too large")
            try:
                await run_in_threadpool(_write_prefs, prefs_path, prefs)
            except OSError as e:
                return _err(500, f"could not save prefs: {e.strerror or e}")
        return JSONResponse({"ok": True, **prefs})

    async def post_read(request: Request) -> Response:
        """The owner opened a session: its read marker moves up to its latest reply (unread.py). The server takes the time from
        the transcript, so a page cannot mark a reply it was not shown."""
        if _cross_origin(request):
            return _err(403, "cross-origin request refused")
        if (request.headers.get("content-type") or "").split(";")[0].strip().lower() != "application/json":
            return _err(415, "read takes application/json")
        raw = bytearray()
        async for chunk in request.stream():
            raw += chunk
            if len(raw) > 4096:
                return _err(413, "body too large")
        try:
            body = json.loads(raw)
        except ValueError:
            return _err(400, "body must be JSON")
        name = body.get("name") if isinstance(body, dict) else None
        if not isinstance(name, str) or not name:
            return _err(400, 'body must be {"name": "<session name>"}')
        live = await run_in_threadpool(S.read_live_sessions, settings)
        found = next((x for x in live if x.name == name), None)
        if found is None:
            return _err(404, "no live session with that name")
        moved = await run_in_threadpool(read_state.mark_read, found.name, found.cwd, found.session_id)
        return JSONResponse({"ok": True, "name": found.name, "moved": moved}, headers={"Cache-Control": "no-store"})

    # THE NEW SESSION FORM (spawn.py has the shapes, the argv and the
    # parsing). The form is the one way this app makes a session, and it makes none itself: a submit is one `sala op
    # spawn …` run as an argv list, with the same origin and content-type guards as send and prefs, every field checked
    # here against the shapes lib/op.sh checks (so a bad one is a 400 here and never reaches sala), the mandate written to
    # a file under state_dir/mandates/ and only its path on the command line, and one spawn in flight at a time (a second
    # while one runs is refused with 409 busy: the page disables its button meanwhile, and the queue would refuse a second
    # spawn of the same name anyway). Nothing typed is logged.
    async def lane_default() -> str:
        """The lane a spawn with no --lane launches on (`sala lane --json`, its `default`); "" when sala cannot say."""
        try:   # a few seconds, not LN.TIMEOUT: a slow sala must not hold the form's options (the label then says "use default" alone)
            rc, out, _err = await SP.run([*SP.resolve_cmd(settings.sala_cmd), "lane", "--json"], SP.LANE_DEFAULT_TIMEOUT)
        except (OSError, TimeoutError):
            return ""
        return LN.default_of(out) if rc == 0 else ""

    async def spawn_options(request: Request) -> Response:
        # what an empty lane, model or effort follows (the form says "use default (<value>)"); "" = could not be read.
        # The project list and the three readings are asked together, so the slowest of them is the wait, not their sum
        projects, lane, claude = await asyncio.gather(pages.get(), lane_default(), run_in_threadpool(SP.claude_defaults, settings.claude_dir))
        defaults = {"lane": lane, **claude}
        return JSONResponse({"projects": projects, "dirs": settings.page_dirs, "lanes": spawn_lanes(), "efforts": list(SP.EFFORTS),
                             "models": list(SP.MODELS), "defaults": defaults,
                             "nameMax": SP.NAME_MAX, "mandateMax": SP.MANDATE_MAX, "error": pages.error},
                            headers={"Cache-Control": "no-store"})

    async def suggest_name(args: list[str]) -> tuple[str | None, tuple[int, str] | None]:
        """`sala spawn --suggest-name <args>` -> (the name, None) or (None, (status, message))."""
        cmd = SP.resolve_cmd(settings.sala_cmd)
        try:
            rc, out, err = await SP.run([*cmd, "spawn", "--suggest-name", *args], SP.SUGGEST_TIMEOUT)
        except (OSError, TimeoutError) as e:
            return None, (502, f"could not run sala: {e}")
        name = out.strip().splitlines()[-1].strip() if out.strip() else ""
        if rc != 0 or not SP.name_ok(name):
            return None, (502, (err.strip() or out.strip() or f"sala exited {rc}")[-1000:])
        return name, None

    async def spawn_suggest(request: Request) -> Response:
        project = (request.query_params.get("project") or "").strip()
        role = (request.query_params.get("role") or "").strip()
        if request.query_params.get("side") == "1":   # a side conversation: the name of a fork of an agent, or of a start about a project's item
            fork_of = (request.query_params.get("fork_of") or "").strip()
            if fork_of:
                if not SP.name_ok(fork_of):
                    return _err(400, "fork_of must be a running agent's session name")
                args = ["--side", "--fork-of", fork_of]
            elif SP.page_key_ok(project, settings.page_dirs):
                args = ["--side", "--project", project]
            else:
                return _err(400, "a side conversation's name needs fork_of (an agent) or project (a page key)")
            name, bad = await suggest_name(args)
            return _err(*bad) if bad else JSONResponse({"name": name}, headers={"Cache-Control": "no-store"})
        if not SP.page_key_ok(project, settings.page_dirs):
            return _err(400, "project must be a page key (<dir>/<slug>)")
        if role not in SP.ROLES:
            return _err(400, "role must be front or back")
        args = ["--project", project, "--role", role]
        prefix = (request.query_params.get("prefix") or "").strip()   # the project's real agent-name prefix, when the page knows it
        if prefix:
            if not SP.prefix_ok(prefix):
                return _err(400, "prefix must be lowercase letters, digits and dashes, no dash at either end")
            args += ["--prefix", prefix]
        if request.query_params.get("new") == "1":   # the project has no page yet (the form's new project): -main is right though no record can know it
            args.append("--new")
        name, bad = await suggest_name(args)
        return _err(*bad) if bad else JSONResponse({"name": name}, headers={"Cache-Control": "no-store"})

    async def spawn_item(request: Request) -> Response:
        """?id=<the item as stackshot shows it> -> {"item", "project", "owner", "status"}: what the Discuss link (#side=<id>) prefills the form with."""
        raw = (request.query_params.get("id") or "").strip()
        sid = SP.store_id(raw)
        if not sid:
            return _err(400, "id must be a board item id as stackshot shows it (board#N, board-tmp-box#N, sN)")
        rep = await run_in_threadpool(stackshot.item_facts, sid)
        rows = rep.data.get("items") if rep.status == 200 and isinstance(rep.data, dict) else None
        if not isinstance(rows, dict):
            status, body = PP.failure(rep, "item")
            return JSONResponse(body, status_code=status, headers={"Cache-Control": "no-store"})
        row = rows.get(sid)
        if not isinstance(row, dict):
            return JSONResponse({"ok": False, "code": "not-found", "error": f"stackshot does not know {raw}"}, status_code=404, headers={"Cache-Control": "no-store"})
        owner = str(row.get("owner") or "")
        return JSONResponse({"ok": True, "item": str(row.get("shown") or raw), "project": str(row.get("project") or ""),
                             "owner": owner if SP.name_ok(owner) else "", "status": str(row.get("status") or "")},
                            headers={"Cache-Control": "no-store"})

    async def spawn_post(request: Request) -> Response:
        if _cross_origin(request):
            return _err(403, "cross-origin request refused")
        if (request.headers.get("content-type") or "").split(";")[0].strip().lower() != "application/json":
            return _err(415, "spawn takes application/json")
        raw = bytearray()
        async for chunk in request.stream():
            raw += chunk
            if len(raw) > SP.BODY_MAX:
                return _err(413, "body too large")
        try:
            body = json.loads(raw)
        except ValueError:
            return _err(400, "body must be JSON")
        req = SP.validate(body, settings.page_dirs, spawn_lanes())
        if isinstance(req, tuple):
            return _err(*req)
        if spawn_lock.locked():
            return JSONResponse({"ok": False, "code": "busy", "error": "a spawn is already in flight; wait for its answer"}, status_code=409)
        async with spawn_lock:
            cmd = SP.resolve_cmd(settings.sala_cmd)
            if req.side and not req.name:   # a blank name on a side conversation: sala suggests one (<prefix>-side-<word><nn>)
                name, bad = await suggest_name(["--side", "--fork-of", req.fork_of] if req.fork_of else ["--side", "--project", req.project])
                if bad:
                    return _err(*bad)
                req = dataclasses.replace(req, name=name)
            mandate_file: Path | None = None
            try:
                if req.mandate:
                    mandate_file = await run_in_threadpool(SP.write_mandate, settings.mandates_dir, req.name, req.mandate)
            except OSError as e:
                return _err(500, f"could not write the mandate file: {e.strerror or e}")
            argv = SP.argv_for(cmd, req, mandate_file, SP.side_words_for(req) if req.side else SP.words_for(req.role, req.name, req.project))
            try:
                rc, out, err = await SP.run(argv, SP.QUEUE_TIMEOUT)
            except (OSError, TimeoutError) as e:
                if mandate_file:
                    with contextlib.suppress(OSError):
                        mandate_file.unlink()
                return JSONResponse({"ok": False, "code": "error", "error": f"could not run sala: {e}"}, status_code=502)
            status, payload = SP.parse_result(rc, out, err, req)
            if status != 202 and mandate_file:  # a refused spawn leaves no file; a queued one's is the session's to read
                with contextlib.suppress(OSError):
                    mandate_file.unlink()
            return JSONResponse(payload, status_code=status)

    # The form's project step (projpick.py): a scope, a project in it, and on Create the project made or listed
    # again and the agent added to it before the spawn above. Every value is checked here against the shapes stackshot
    # checks (a bad one is a 400 and no request), with the same origin and content-type guards as the spawn; the calls are
    # HTTP with a JSON body, so there is no shell. stackshot's own refusals pass on in plain words (`error`) with a `code`
    # the page words its answer by. Nothing typed is logged; the token and the address never leave projpick.py.
    async def read_json_post(request: Request) -> object:
        if _cross_origin(request):
            return _err(403, "cross-origin request refused")
        if (request.headers.get("content-type") or "").split(";")[0].strip().lower() != "application/json":
            return _err(415, "this takes application/json")
        raw = bytearray()
        async for chunk in request.stream():
            raw += chunk
            if len(raw) > 16 * 1024:
                return _err(413, "body too large")
        try:
            return json.loads(raw)
        except ValueError:
            return _err(400, "body must be JSON")

    async def spawn_projects(request: Request) -> Response:
        v = PP.validate_query(dict(request.query_params))
        if isinstance(v[0], int):
            return _err(*v)
        rep = await run_in_threadpool(stackshot.projects, *v)
        data = PP.clean_projects(rep.data) if rep.status == 200 else None
        if data is None:
            if rep.status == 200:
                rep = PP.Reply(502, {"error": "stackshot sent an answer that is not the project list"})
            status, body = PP.failure(rep, "projects")
            return JSONResponse(body, status_code=status, headers={"Cache-Control": "no-store"})
        return JSONResponse({"ok": True, **data}, headers={"Cache-Control": "no-store"})

    async def spawn_project_new(request: Request) -> Response:
        body = await read_json_post(request)
        if isinstance(body, Response):
            return body
        req = PP.validate_new(body, settings.page_dirs)
        if isinstance(req, tuple):
            return _err(*req)
        if project_jobs.running():
            return JSONResponse({"ok": False, "code": "busy", "error": "a project is being made already; wait for its answer"}, status_code=409)

        def work() -> tuple[int, dict]:
            rep = stackshot.new_project(req)
            if rep.status == 200 and isinstance(rep.data, dict):
                return 200, PP.project_success(rep)
            return PP.failure(rep, "project")

        return JSONResponse({"ok": True, "job": project_jobs.start(work)}, status_code=202)

    async def spawn_project_job(request: Request) -> Response:
        job = project_jobs.get((request.query_params.get("id") or "").strip())
        if job is None:
            return _err(404, "no such job (the app restarted, or it is over an hour old); look for the project in the list")
        return JSONResponse(job, headers={"Cache-Control": "no-store"})

    async def spawn_project_list(request: Request) -> Response:
        body = await read_json_post(request)
        if isinstance(body, Response):
            return body
        req = PP.validate_list(body, settings.page_dirs)
        if isinstance(req, tuple):
            return _err(*req)
        rep = await run_in_threadpool(stackshot.list_project, req)
        if rep.status == 200 and isinstance(rep.data, dict):
            return JSONResponse(PP.project_success(rep))
        status, out = PP.failure(rep, "list")
        return JSONResponse(out, status_code=status)

    async def spawn_project_agent(request: Request) -> Response:
        body = await read_json_post(request)
        if isinstance(body, Response):
            return body
        req = PP.validate_agent(body, settings.page_dirs)
        if isinstance(req, tuple):
            return _err(*req)
        rep = await run_in_threadpool(stackshot.add_agent, req)
        if rep.status == 200 and isinstance(rep.data, dict):
            return JSONResponse(PP.project_success(rep))
        status, out = PP.failure(rep, "agent")
        return JSONResponse(out, status_code=status)

    # stackshot's For you list (foryou.py): the list from the cache, and Seen and Watch / Mute as POSTs with the
    # same origin and content-type guards; a refusal of stackshot's comes back as a plain sentence, never a trace
    async def get_for_you(request: Request) -> Response:
        return JSONResponse(foryou.get(), headers={"Cache-Control": "no-store"})

    async def post_for_you_seen(request: Request) -> Response:
        body = await read_json_post(request)
        if isinstance(body, Response):
            return body
        req = FY.validate_seen(body)
        if isinstance(req, tuple):
            return _err(*req)
        rep = await run_in_threadpool(foryou_calls.seen, req)
        if rep.status == 200:
            try:
                got = FY.parse_seen(rep.data)
            except RuntimeError as e:
                return _err(502, str(e))
            snap = foryou.apply(rows=got["rows"], drop=got["seen"] if got["rows"] is None else None)
            return JSONResponse({"ok": True, "seen": got["seen"], **snap}, headers={"Cache-Control": "no-store"})
        if rep.status == 404 and req["id"] != "all":
            # stackshot: not on the list, one already marked seen included (a second tap, another page): it is gone, which is
            # what was asked; the list is dropped of it here and the answer is the list as it is
            snap = foryou.apply(drop=[req["id"]])
            return JSONResponse({"ok": True, "seen": [], **snap}, headers={"Cache-Control": "no-store"})
        status, msg = FY.sentence(rep, "mark it seen", "That entry is not on the list any more; it may have been seen already.")
        return _err(status, msg)

    async def post_item_watch(request: Request) -> Response:
        body = await read_json_post(request)
        if isinstance(body, Response):
            return body
        req = FY.validate_watch(request.path_params["key"], body)
        if isinstance(req[0], int):
            return _err(*req)
        shown, out = req
        rep = await run_in_threadpool(foryou_calls.watch, shown, out)
        if rep.status == 200:
            try:
                got = FY.parse_watch(rep.data, shown, out["state"])
            except RuntimeError as e:
                return _err(502, str(e))
            flags = got["flags"]
            if flags is None:   # no map in the answer: ours, with this one item set
                flags = {k: v for k, v in (foryou.snapshot().get("flags") or {}).items() if k != got["item"]}
                if got["state"] in FY.FLAG_STATES:
                    flags[got["item"]] = got["state"]
            snap = foryou.apply(flags=flags)
            return JSONResponse({"ok": True, "item": got["item"], "state": got["state"], **snap}, headers={"Cache-Control": "no-store"})
        status, msg = FY.sentence(rep, "change the flag", "stackshot does not know that item.")
        return _err(status, msg)

    # The color tool's saved combinations (colors.py; the panel is the pinned static/colortool.js): proxied to stackshot's one list with this
    # machine's token and the label sala-web, which this server sets (the browser sends a name and the 14 colors, or an id); not
    # cached; every answer is the list or {"error", "field"}
    def colors_reply(status: int, body: dict) -> Response:
        return JSONResponse(body, status_code=status, headers={"Cache-Control": "no-store"})

    async def colors_body(request: Request) -> object:
        body = await read_json_post(request)
        if isinstance(body, Response):      # the origin, type, size and JSON guards answer as {"ok", "error"}: this page's shape is {"error", "field"}
            try:
                msg = json.loads(body.body).get("error") or "bad request"
            except ValueError:
                msg = "bad request"
            return colors_reply(body.status_code, {"error": msg, "field": None})
        return body

    async def get_colors_combos(request: Request) -> Response:
        return colors_reply(*CLR.answer(await run_in_threadpool(color_calls.list)))

    async def post_colors_combos(request: Request) -> Response:
        body = await colors_body(request)
        if isinstance(body, Response):
            return body
        req = CLR.validate_save(body)
        if isinstance(req, tuple):
            return colors_reply(*req)
        return colors_reply(*CLR.answer(await run_in_threadpool(color_calls.save, req)))

    async def post_colors_combos_delete(request: Request) -> Response:
        body = await colors_body(request)
        if isinstance(body, Response):
            return body
        req = CLR.validate_delete(body)
        if isinstance(req, tuple):
            return colors_reply(*req)
        return colors_reply(*CLR.answer(await run_in_threadpool(color_calls.delete, req)))

    async def spawn_status(request: Request) -> Response:
        op = (request.query_params.get("op") or "").strip()
        if not SP.OP_ID_RE.match(op):
            return _err(400, "op must be an operation id (<epoch>-<pid>)")
        rec = await run_in_threadpool(SP.op_status, settings.sala_state_dir, op)
        if rec is None:
            return _err(404, "no such operation")
        return JSONResponse(rec, headers={"Cache-Control": "no-store"})

    # The debug logs (temporary, Wed Oct 14th 2026; debuglog.py): "timing" (timingdebug.py, README "Timing": where a
    # page load's milliseconds went); the input debug and the paste probe (Fri Oct 30th 2026, retired the same day) also used them. A page
    # posts records, batched, with the same origin and content-type guards as send and prefs; the maintainer reads the
    # tail over the unix socket (the timing log's as one readable line a record, ?raw=1 for the JSON lines). Remove a
    # log's entry here and its module with the rest of that debug; the two handlers and their routes go with the last
    # one.
    debug_logs = {"timing": DL.DebugLog(settings.state_dir / TD.LOG_NAME)}
    debug_lock = asyncio.Lock()

    async def post_debug(request: Request) -> Response:
        log = debug_logs.get(request.path_params["kind"])
        if not log:
            return _err(404, "no such debug log")
        if _cross_origin(request):
            return _err(403, "cross-origin request refused")
        if (request.headers.get("content-type") or "").split(";")[0].strip().lower() != "application/json":
            return _err(415, "a debug log takes application/json")
        raw = bytearray()
        async for chunk in request.stream():
            raw += chunk
            if len(raw) > DL.MAX_BODY:
                return _err(413, "debug body too large")
        try:
            body = json.loads(raw)
        except ValueError:
            return _err(400, "body must be JSON")
        events = DL.events_of(body)
        if isinstance(events, str):
            return _err(400, events)
        async with debug_lock:
            try:
                await run_in_threadpool(log.append, events)
            except OSError as e:
                return _err(500, f"could not write the debug log: {e.strerror or e}")
        return Response(status_code=204)

    async def get_debug(request: Request) -> Response:
        kind = request.path_params["kind"]
        log = debug_logs.get(kind)
        if not log:
            return _err(404, "no such debug log")
        try:
            n = max(1, min(int(request.query_params.get("n", DL.TAIL_LINES)), DL.TAIL_MAX))
        except ValueError:
            return _err(400, "n must be a number")
        text = await run_in_threadpool(log.tail, n)
        if kind == "timing" and request.query_params.get("raw") != "1":
            text = TD.summary(text)
        return Response(text, media_type="text/plain", headers={"Cache-Control": "no-store"})

    def prune_uploads() -> None:
        cutoff = time.time() - UPLOAD_MAX_AGE_DAYS * 86400
        if settings.uploads_dir.is_dir():
            now = time.time()
            for p in settings.uploads_dir.iterdir():
                try:
                    if UPLOAD_RE.match(p.name) and p.stat().st_mtime < cutoff:
                        p.unlink()
                    elif UPLOAD_DIR_RE.match(p.name) and p.is_dir() and not p.is_symlink():
                        # a file's folder: gone after 30 days, a half-written one (still holding its temporary file) after one
                        age = now - p.stat().st_mtime
                        if age > UPLOAD_MAX_AGE_DAYS * 86400 or (age > UPLOAD_PARTIAL_MAX_AGE_S and (p / UPLOAD_PARTIAL).exists()):
                            shutil.rmtree(p, ignore_errors=True)
                except OSError:
                    pass
        SP.prune_mandates(settings.mandates_dir, UPLOAD_MAX_AGE_DAYS)  # a spawned session read its mandate long ago

    static_app = RevalidatedStatic(directory=STATIC)
    routes = [
        Route("/", index),
        Route("/v2", v2_moved, methods=["GET", "HEAD"]),
        Route("/v2/{rest:path}", v2_moved, methods=["GET", "HEAD"]),   # a temporary redirect to / (v2_moved)
        Route("/terminal", terminal_page),
        Route("/manifest.webmanifest", manifest),
        Route("/sw.js", service_worker),
        # everything under /mockup (any method, any depth) is answered by mockup_page, so no answer of this prefix lacks the sandbox headers
        Route("/mockup/{n:path}", mockup_page, methods=MK.METHODS),
        Route("/mockup", mockup_page, methods=MK.METHODS),
        Route("/api/config", config),
        Route("/sessions", sessions_page),
        Route("/api/sessions", list_sessions),
        Route("/api/overview", overview),
        Route("/api/lane-names", get_lane_names),
        Route("/api/quota", get_quota),
        Route("/api/credit", get_credit),
        Route("/api/spend", get_spend),
        Route("/api/schedules", get_schedules),
        Route("/api/machines", get_machines),
        Route("/api/usage", get_usage),
        Route("/api/usage/digest", get_usage_digest),
        Route("/api/usage/replies", get_usage_replies),
        Route("/api/search", get_search),
        Route("/api/lanes/{lane}", get_lane),
        Route("/api/board-items", get_board_items),
        Route("/api/for-you", get_for_you),
        Route("/api/for-you/seen", post_for_you_seen, methods=["POST"]),
        Route("/api/items/{key}/watch", post_item_watch, methods=["POST"]),
        Route("/api/colors/combos", get_colors_combos),
        Route("/api/colors/combos", post_colors_combos, methods=["POST"]),
        Route("/api/colors/combos/delete", post_colors_combos_delete, methods=["POST"]),
        Route("/api/s/{pid:int}/transcript", get_transcript),
        Route("/api/s/{pid:int}/stream", stream),
        Route("/api/s/{pid:int}/send", send, methods=["POST"]),
        Route("/api/s/{pid:int}/stop", stop_bang, methods=["POST"]),
        Route("/api/image/{sid}/{uuid}/{i:int}/{j}", image),
        Route("/api/file-image/{sid}/{uuid}/{i:int}/{k:int}", file_image),
        Route("/api/md-image/{sid}/{uuid}/{i:int}/{n:int}", md_image),
        Route("/api/upload", upload, methods=["POST"]),
        Route("/api/shell/open", shell_open, methods=["POST"]),
        Route("/api/shell/keys", shell_keys, methods=["POST"]),
        Route("/api/prefs", get_prefs, methods=["GET"]),
        Route("/api/prefs", put_prefs, methods=["PUT"]),
        Route("/api/read", post_read, methods=["POST"]),
        # the New session form: the options, the suggested name, the spawn through the queue, its state
        Route("/api/spawn/options", spawn_options),
        Route("/api/spawn/suggest", spawn_suggest),
        Route("/api/spawn/status", spawn_status),
        Route("/api/spawn/item", spawn_item),
        Route("/api/spawn/projects", spawn_projects),
        Route("/api/spawn/project", spawn_project_new, methods=["POST"]),
        Route("/api/spawn/project/job", spawn_project_job),
        Route("/api/spawn/project-list", spawn_project_list, methods=["POST"]),
        Route("/api/spawn/project-agent", spawn_project_agent, methods=["POST"]),
        Route("/api/spawn", spawn_post, methods=["POST"]),
        # the debug logs (temporary): the timing log by kind
        Route("/api/debug/{kind}", get_debug, methods=["GET"]),
        Route("/api/debug/{kind}", post_debug, methods=["POST"]),
        Mount("/static", static_app, name="static"),
    ]
    @contextlib.asynccontextmanager
    async def lifespan(app):
        await run_in_threadpool(prune_uploads)
        yield
        shutting_down.set()

    app = Starlette(routes=routes, lifespan=lifespan)
    app.state.settings = settings
    app.state.shutting_down = shutting_down
    app.state.build_version = build_version
    app.state.quota = quota
    app.state.credit = credit
    app.state.spend = spend
    app.state.usage = usage
    app.state.board = board
    app.state.foryou = foryou
    app.state.schedules = schedules
    return app


def _socket_in_use(path: Path) -> bool:
    if not path.exists():
        return False
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(1)
    try:
        s.connect(str(path))
        return True
    except OSError:
        return False
    finally:
        s.close()


def main() -> None:
    import uvicorn

    ap = argparse.ArgumentParser(prog="sala-web", description=__doc__.splitlines()[0])
    ap.add_argument("--socket", help="unix socket path (default $XDG_RUNTIME_DIR/sala-web/sala-web.sock); "
                    "not used when systemd passes the socket (contrib/sala-web.socket)")
    ap.add_argument("--tmux-socket", help="tmux -L name (default: the default tmux server)")
    args = ap.parse_args()
    settings = Settings()
    if args.socket:
        settings.socket = Path(args.socket)
    if args.tmux_socket is not None:
        settings.tmux_socket_name = args.tmux_socket
    app = create_app(settings)

    class Server(uvicorn.Server):
        def handle_exit(self, sig, frame):
            app.state.shutting_down.set()  # SSE generators return on their next tick (under a second)
            super().handle_exit(sig, frame)

    common = dict(log_level="info", timeout_graceful_shutdown=GRACEFUL_SHUTDOWN_S)
    fd = _systemd_listen_fd()  # set only when systemd started this process; a manual run uses the socket path
    if fd is not None:
        # Socket activation (contrib/sala-web.socket): systemd owns the socket, so it outlives a restart and requests
        # that arrive meanwhile wait in the kernel backlog instead of failing.
        config = uvicorn.Config(app, fd=fd, **common)
        link_compat_sockets(settings, _bound_path(fd) or settings.socket)
    else:
        sock = settings.socket
        # Unix socket only, in a 0700 directory: no TCP port, which any local user (such as the CI runner's) could
        # reach.
        if _socket_in_use(sock):
            sys.exit(f"sala-web: something is already serving on {sock}; pass --socket <another path>")
        sock.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(sock.parent, 0o700)
        if sock.exists():
            sock.unlink()
        config = uvicorn.Config(app, uds=str(sock), **common)
        link_compat_sockets(settings, sock)   # a dangling link until uvicorn binds the socket, a moment later
    Server(config).run()


if __name__ == "__main__":
    main()
