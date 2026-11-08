# `sala reboot` — the participant contract (v1)

`sala reboot` takes a box down cleanly and brings it back in order. sala drives the sequence; every service that holds state or
delivers into sessions takes part through **one executable per service** (a *hook*) that implements five verbs.
sala knows nothing else about the service: no unit names, no paths, no queues.

## Registration

In sala's config, in **stop order** (the boot side runs them in reverse, i.e. start order):

```
SALA_REBOOT_HOOKS="queue=/path/to/queue-hook stackshot=/path/to/stackshot-hook store=/path/to/store-hook"
```

`name=path`, space-separated. A hook must be runnable by the sala user without a prompt (use `sudo -n` inside it for
system units, and say so in its header).

## Verbs

Every verb: exit **0** = done and verified, anything else = failed. The **last line of stdout** is a one-line human
summary, which sala puts into its report verbatim, so make it say what happened in plain words (≤ 120 chars). Put details
in your own log. A verb must finish within its time budget; sala kills it after the budget and treats that as a failure.

| Verb | Budget | Must do | Exit 0 means |
|---|---|---|---|
| `pause --at <ISO-8601 UTC>` | 30 s | Switch inbound delivery to **queue-only**: keep receiving and recording, deliver nothing into sessions. Persist the paused state and `--at` so it **survives a restart and a reboot** (the service must come back up still paused). Idempotent. | paused, persisted |
| `flush-stop` | 300 s | Commit/persist everything pending (queues, cursors, pending writes pushed), then stop the service cleanly. | the service is stopped **and** nothing is left unflushed |
| `start` | 120 s | Start the service (used by `--dry-run` and by a halted run's rollback; at a real boot, systemd starts it). It must come up **paused** if it was paused. | running and healthy |
| `status` | 15 s | Report state. **Exit 0** = running and healthy, **exit 3** = stopped, anything else = broken. The summary line says `paused since <ISO>` when paused. | — |
| `resume --since <ISO-8601 UTC> --sessions <file>` | 600 s | Leave queue-only mode. Deliver what was queued, **oldest first, only to the sessions listed** in `<file>` (one Claude transcript uuid per line — the panes sala verified as resumed and bridged; anything for a session not in the list stays queued and is reported). Then catch up from `--since` (for a delivery service: re-read its sources and deliver new items as ordinary notices marked as catch-up). Clear the persisted pause. Idempotent. | unpaused; summary says queued / delivered / held / catch-up counts |

Services with nothing to pause (a plain data store) implement `pause` and `resume` as no-ops that exit 0 with a one-line summary.

## What sala does with them

`sala reboot --dry-run` (the acceptance test) and `sala reboot --go` (the real one, only on the owner's word), from the
master pane:

1. **Pause:** records `T` = now (UTC); runs `pause --at T` on every hook. Any failure → resume all, stop.
2. **Drain:** waits until every pane except the master is idle (busy ones are held; a pane still busy after the budget
   halts the run), drains feedback drafts, takes a resurrect snapshot, and records every pane's conversation uuid and
   claude.ai id.
3. **Flush and stop, in order:** `flush-stop`, then `status` must exit 3, per hook in `SALA_REBOOT_HOOKS` order; a final
   heartbeat. Any failure → **halt: no reboot**, `start` + `resume` the ones already stopped, report.
4. **Dry run:** `start` every hook in reverse order (each `status` must exit 0), then `resume --since T --sessions <live>`.
   **Real run:** writes the reboot marker (`T`, the pane snapshot, the planned checks) and issues the reboot as the
   master's last act.

**At boot** (the marker is present): `sala watch` launches the boot half as its own systemd unit. It waits for revive,
recreates every session of the frozen pane-map roster that did not come back (see *The pane map during a reboot*),
checks each pane's claude.ai id against the snapshot (re-bridging with `/remote-control` where needed) and writes the
verified session list. Then it polls every hook's `status` together and runs `resume --since T --sessions <file>` on each
one **the moment it exits 0**, so a slow hook holds nobody else. A hook still stopped (exit 3) at 300 s gets one `start`.
A hook not up by 300 s is reported to the master at once, as **still coming up** (any exit but 0 and 3) or **down**
(exit 3 and the start failed), and stays on watch for up to 30 min after boot: if it comes up, sala resumes it and tells
the master; if not, it says it gave up and leaves the marker, so `sala reboot --resume` finishes the run. The summary
lines go into the one post-boot report in the master's pane, which is sent once every hook is resumed or reported.
So a hook's `status` should exit 3 only when the service is really stopped, not while it is starting.

## The pane map during a reboot

sala's record of which conversation lives in which tmux session is the pane map (`~/.local/state/salamander/pane-map.tsv`:
tmux session, uuid, name, cwd), a ledger only honored paths change — see the design note in [design-notes.md](design-notes.md). For a reboot it is also the
**roster**: at the pause step `sala reboot` freezes it (a copy of its rows next to it, with the owner pid, boot id,
reason and time). While the freeze stands no `spawn`, `rename`, `retire`, `unpark` or `adopt` goes through (each refuses
up front and says so), and a conversation switch observed in a live pane is deferred and applied when the freeze is
lifted. A dry run lifts it at its end, a halted run in its rollback, and a real reboot in the boot half; a freeze whose
owner is gone (a run that died) is cleared by `sala watch` within minutes, with a report. A `sala reboot` started while
the map is already frozen (a recycle still running) refuses before anything is paused.

**At boot**, once revive has finished (its boot record), the boot half holds the frozen roster against tmux: every
session of it that resurrect and revive did not bring back is recreated — the tmux session detached at a shell in the
row's cwd, then `revive --only NAME`, which resumes the row's conversation by uuid under the usual dedupe guard — and
one post says "Reboot: N sessions recreated" (🚨 for any that could not be). Then the freeze is lifted, the pane check
against the snapshot runs over the full set, and the hooks are resumed as below. `sala reboot --resume`, standing in
for a boot half that never ran, does the same comparison first. After a boot that was not a clean `sala reboot` there
is no roster; the post-boot report names the rows with no tmux session, and `sala restore --missing` brings them back.

## Session notes (for sessions, not services)

A session whose work continues after the reboot leaves itself a note before the drain: `sala note "<what I do next>"`
from its own pane, or in one step with the hand-over, `sala cue --after "<what I do next>" "reboot the box"`. Notes are
not reboot-specific: one comes back after its session's next relaunch of any kind (see `lib/note.sh`). During a clean
reboot, watch holds off and the boot half delivers the due notes once the hooks are resumed or reported, and tells the
master about any whose session is not back. The shutdown report names the sessions with notes; a dry run changes nothing.
