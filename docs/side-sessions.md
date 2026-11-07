# Quick sessions, called side sessions inside sala

On the web page the thing is a **Quick session** (the label, the page title and the buttons say "Quick session"); inside sala and in the API it stays `side`
(`--side`, `side`, `fork_of`, `item`, `agents`, the registry's fields, `sala side done`), so nothing that already speaks to it
changes. A **side session** is a short-lived session started in one step, for the owner
to talk something over with. It is not an agent of a project: it is on no page's `agents:` map, has no role, and takes over
nobody's work. It exists to be talked to, and it must leave a write-up behind before it goes.

## The two starts

| Start | Command | The session |
|---|---|---|
| **Fork** | `sala spawn --side --fork-of AGENT [--item ID] [NAME]` | continues the live conversation of `AGENT` (`claude --resume <its current uuid> --fork-session`, found for you), started in the agent's directory (the CLI finds a conversation by it) unless `--cwd` says otherwise. Named `<agent>-side-<word><nn>` (the agent's name cut at a previous `-side-`). Its summary goes to the agent. |
| **Discuss** | `sala spawn --side --project KEY --item ID [--agents A,B] [NAME]` | a **fresh** session (not a fork), scoped to the item's project page `KEY`. Named `<the project's usual agent prefix>-side-<word><nn>` (its main agent in stackshot's project record, else the `--suggest-name` convention). Its summary goes to the project's main agent. |

`--suggest-name --side (--fork-of AGENT | --project KEY)` prints a name. A given name must be an agent name containing
`-side-` (at most 48 characters). The item id is any form stackshot shows: `board#N`, a temporary `board-tmp-box#N`, an
older `sN` (`item_id_ok` in `lib/common.sh`). Through the queue: `sala op spawn NAME --side …` (the same options plus `--lane`,
`--model`, `--effort`, `--cwd`, `--mandate FILE|TEXT`, `--no-confirm`), checked at queue time (no role; exactly one of
`--fork-of` and `--project`; a project needs its item; the shapes) and planned with `spawn --dry-run`, which finds the agent
to fork or the project's page. A raw `sala spawn --side` is guarded like a raw `sala spawn` is today (it is not).

**The mandate** is written for the session to `$SALA_STATE_DIR/mandates/side-<name>.md` when it runs and typed to it as for
any mandate file. It says: what the conversation is; the item (its id, and its link when it is a `board#N` and the sala config sets `SALA_STACKSHOT_WEB` (the board's web address: the link is `<address>/items/<N>`; unset, the mandate says to read the item with the board connector)); to read the
project page's Current state and the item first; the involved agents (`--agents`, passed in by the caller: the item's owner,
the sessions in its needs); to **find and read only the transcript excerpts it needs** from them with the new read-only
`sala sessions transcript <name> [--json]`, never a whole transcript; that it is a side conversation with the owner; that it
must run `sala side done` before it ends; and that it retires only when the owner tells it to. A `--mandate` of the caller is
appended as the owner's own instructions.

There is **no quiet watch, no auto-retire and no cap**. A side session retires only on the owner's word, through `sala op retire`. The one case where
a retire takes no words is not a side session at all: a plain throwaway (bare `sala spawn`, no project, role or side flag) carrying the throwaway tag a bare spawn writes (any session may retire a tagged row, whatever its name, between turns); a row from before the tag keeps the older rules (its spawner, the master, or any session when NAME is a throwaway's name and it has no live spawner). Never with
a bypass flag (`--busy`, `--skip-writeup`, `--self`, `--leave-items`), `--id` or `--keep-web`, and only when the project record confirms NAME is on no agents map (`sala op retire NAME --from YOU`; docs/session-registry.md, *A throwaway's spawner*). A side session is refused that path, tagged or not, and a spawn with `--side` never writes the tag.

## The write-up gate: `sala side done`

```
sala side done [--name NAME] [--item ID] [--item-updated EPOCH|ISO] [--summary FILE|TEXT|-] [--summary-to NAME|projects/SLUG] [--dry-run]
```

Run by the side session itself (its own tmux session is the default `--name`). It writes the marker
`$SALA_STATE_DIR/side/<name>.done` **only if all of these hold**, and says every one that does not:

1. **The board item changed since the session started.** A script cannot read an arbitrary item from stackshot: its client lists
   an item only under the sessions that own it or are named in its needs (`get items <session>`, each with `updated`). So the item
   is looked for under the `--agents` the session was started with, the agent forked from and the summary's receiver, and its
   `updated` must be later than the session's start. When none lists it (the session is not named on the item), the session reads
   the item through its stackshot connector and confirms with `--item-updated <the time it saw>`; that confirmation is taken as
   the item's word. This is the one weak link, and it is why the flag exists. No item on the record (a fork started without
   `--item`): skipped, and said.
2. **The project page has a timeline line from the session**: `- **YYYY-MM-DD** | <name> — …`, dated on or after the day it
   started, in the local mirror of the pages (`$SALA_BRAIN_DIR`, unset by default; every put is committed to it at once). Where the
   mirror is not on the box, the page's last change from stackshot (`get page-ts`) after the start counts, said as the weaker proof.
   No project on the record: skipped, and said.
3. **The summary reached the origin agent (a fork) or the project's main agent (a start about an item).** `side done` sends it
   itself from `--summary` through stackshot's client `message` (once, only when everything else holds, and a repeat never
   sends it again). A receiver ending in `-main` gets `[for <owner>]` on line 1 (`<owner>` is the `SALA_OWNER_NAME` setting). `--summary-to NAME` sends to someone else: first without the
   mark (a background agent must not get it); if stackshot refuses with its front-agent text ("is a front agent of … a session
   the owner talks to … `[for <owner>]`", a user-facing agent whose name does not end in `-main`), it is sent once more with the mark.
   Any other failure ends there. `--summary-to projects/SLUG` (or a key in another page dir) sends it to the project: the router rules it,
   and the message is never marked. The log of each attempt is in `$SALA_LOG_DIR/salamander-side.log`.

`--dry-run` runs the checks and sends and writes nothing.

`sala retire` (and so `sala op retire`) of a side session is **refused** until the marker is there, in its dry run (the queue's
plan, so nothing is queued) and for real; the refusal says what is missing and points at `sala side done --name NAME --dry-run`.
`--skip-writeup` is the only bypass, said when used (`--force` is gone: it was this and `--busy`). A session with no side record is untouched. After a retire the record and the
marker move to `side/retired/`.

**A side session that becomes an agent**: `sala rename <side session> <agent name>` (the name does not contain
`-side-`) lists the new name as a front agent of the session's project through stackshot (`client.py post project-agent … --front
--sender sala-web`: a pending entry in the project record, the page's own line stays its keeper's to add), renames the session, and
ends the side record the way a retire leaves a finished one (record and marker to `side/retired/`, the row's `side*` fields cleared,
the row tagged with the project and `front`). The write-up (`side done`, the summary) is then not owed: it is an ordinary agent. The
project is the record's `project`, else the origin agent's; with neither the rename is refused in its plan (`sala op --plan rename`,
`--dry-run`) and nothing starts. A refusal by stackshot renames nothing and keeps the record. `rename --sync` (a hand rename) does not.

## State

| File | Holds |
|---|---|
| `$SALA_STATE_DIR/side/<name>.side` | the record: `name`, `kind` (fork or discuss), `origin`, `project`, `item`, `agents`, `summary_to`, `started` (epoch), `uuid`, `origin_uuid`, `mandate`, and after the send `summary_sent_to`, `summary_sent_at`. The gate reads this file, not the registry, so `SALA_SESSIONS=off` does not turn it off. |
| `$SALA_STATE_DIR/side/<name>.done` | the write-up marker |
| `$SALA_STATE_DIR/side/retired/` | both, after the retire |
| session registry row | `side=1`, `side_origin`, `side_item`, `side_at` (display copies; `sala sessions` shows `side` in the ROLE column of a row with no role). Not published to stackshot: `session-registry.json` is unchanged and no contract version moves. |
| `$SALA_LOG_DIR/salamander-side.log` | the output of the summary message |

Knobs (stackshot's client is three commands so the tests can stub them): `SALA_SIDE_ITEMS_CMD`, `SALA_SIDE_PAGE_TS_CMD`,
`SALA_SIDE_MSG_CMD`, `SALA_BRAIN_DIR`, `SALA_SIDE_TIMEOUT` (30 s), `SALA_SIDE_MSG_TIMEOUT` (150 s: the client waits for delivery).

## `sala sessions transcript <name> [--json]`

Read-only (`lib/sessions.py`, like `resolve`): where the conversations of a session are on disk, the current one first, then the
earlier ones, each with its path under the CLI's projects directory, or `(not on this box)`. A live row wins over a retired one of
the same name; two live rows are ambiguous (exit 2); none, exit 1. `--json`: `{id, name, state, transcripts: [{id, path, current,
machine, at, why}]}`.

## The web UI

Same page and same queue as the New session form (`web/README.md`, *Quick sessions*): a form of its own under `#side=…`.
A segmented switch **New session | Quick session** at the very top of the page (the look of the scope selector, the same on both
forms) moves between the two; there are no loose text links. **The Discuss link of stackshot,
`https://<the web UI address>/#side=<id>`, opens the form with the item filled in** (the id is everything after `side=`, whatever
its form, a `#` included; the item's project and owner are looked up from stackshot's `item-facts`). `#side=from:<name>` is a fork
of that session. **The Fork button is in the "⋯" menu** of a session's row in the sidebar, a link to that `#side=from:<name>`; there is none in the session header, whose fold is measured to the pixel
and has no room. The ⋯ is offered for a session with a tmux pane and not on the sdk lane (nothing to take a conversation from);
a quick session can be forked too (`lib/spawn.sh` cuts the new name at the earlier `-side-`).

The form has two independent, optional fields, each a picker with a search box:

- **Board item**: the open items of the running sessions (`api/board-items`), newest first; any id can be typed as well. Alone, it
  is a fresh session about the item on its project's page (the project and owner are looked up and shown).
- **Session to fork**: the running sessions. Alone, it is a fork of that session; beside an item, the item is what the fork is about.

The backend still needs one of the two (`--side` takes `--fork-of` or `--project` with `--item`): with neither, the form says so
and the button waits. A board item alone also needs its project page (looked up from stackshot; filled in by hand if that fails).
`POST /api/spawn` accepts `side`, `fork_of`, `item`, `agents`.

## In the web app

The sidebar and the overview group a side session by its record (`kind`, `origin`, `project`): a fork under the group its origin has
now, a discuss session under its item's project, with no role; no record, or none that leads to a project, is `Unregistered` as for any
session on no page. sala-web reads the `.side` file, read-only (web/README.md, *Sidebar*).
