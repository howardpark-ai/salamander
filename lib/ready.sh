# lib/ready.sh — a session's own word that it may be relaunched now.
#
#   salamander ready            run as the LAST tool call of a turn: marks this conversation ready
#   salamander ready --clear    withdraw it
#   salamander ready --list     markers on disk
#
# The registry's `idle` is an observation from outside; it cannot say whether a background child
# or a subagent's work matters, so recycle refuses such panes (is_idle_reason) and retries every
# few minutes. A ready marker is the session saying, from inside: I am at a checkpoint, whatever
# is still running may be cut: a shell or a task. A running SUBAGENT is never cut: the in-session mod refuses the exit for it, and
# the idle check reads its transcript (subagent_holders), so `ready` names it and says the relaunch waits for it. With the word, the idle guard needs only registry-idle ≥ 10 s, and the
# retry worker is woken by it (SIGUSR1) instead of waiting for its next SALA_RETRY_EVERY tick. The
# marker is consumed by the relaunch and expires after SALA_READY_TTL s. Run from inside the
# session (a Bash tool call): the conversation is found by walking up to the claude process (own_claude_pid, common.sh).
# When processes still run under the pane, the output names them first: pid, how long, task id, command.

case "${1:-}" in
    --list) ls -l --time-style=+%H:%M "$SALA_READY_DIR" 2>/dev/null | tail -n +2 || echo "no ready markers"; exit 0 ;;
    ''|--clear) ;;
    *) die "usage: salamander ready [--clear|--list]" ;;
esac
cpid=$(own_claude_pid) || die "not inside a Claude Code session (no registry entry above pid $$)"
uuid=$(registry_field "$cpid" sessionId); name=$(registry_field "$cpid" name)
[ -n "$uuid" ] || die "registry entry for pid $cpid has no sessionId"
if [ "${1:-}" = --clear ]; then rm -f "$SALA_READY_DIR/$uuid"; echo "ready marker cleared for ${name:-$uuid}"; exit 0; fi
mkdir -p "$SALA_READY_DIR"; date +%s > "$SALA_READY_DIR/$uuid"
# wake a pending recycle's retry worker (lib/revive.sh; ready_wake, common.sh — the Stop hook uses the same wake when a turn
# ends with nothing in flight, lib/hook.sh) — the relaunch follows as soon as this turn ends
# what still runs under this pane, said first so that "ready" cannot be read as "nothing is running". A shell a
# subagent started is in no task list of this session (the incident: three `sala ready` and "no background shell" over a
# subagent's until-loop that held the relaunch for about 5 hours), so the process tree is read, not the session's own list.
# Read-only, one python reading /proc; nothing is printed when nothing runs, and the lines below are as before.
holders_block "$cpid" "ready: ${name:-?} ($uuid) — but <n> still run under this pane and will be cut at the relaunch, or hold it:" "$SALA_HOLDERS_HOWTO"
woke=1; ready_wake && woke=0
# a subagent the session started is never cut, and the in-session mod refuses the exit for it: name it, with how it ends, so "ready" is not
# read as "relaunching now" (subagent_holders, common.sh: the same definition the recycle's idle check and the mod use)
subagents_block "$cpid"
nsub=$(subagent_holders "$cpid" "$uuid" | grep -c .)
drow=$(deferred_row_for "$cpid")   # a pane on the deferred list is a relaunch waiting for it, whatever the recycle's sets say now
if [ "${nsub:-0}" -gt 0 ]; then
    echo "ready: ${name:-?} ($uuid) — held by the subagent(s) above; the relaunch follows within minutes after they end, not when this turn does"
elif [ "$woke" = 0 ]; then
    echo "ready: ${name:-?} ($uuid) — the pending recycle relaunches this pane as soon as this turn ends; make this the turn's last action"
elif [ -n "$drow" ]; then
    IFS=$'\t' read -r _ dsince _ <<< "$drow"
    echo "ready: ${name:-?} ($uuid) — this pane is on the deferred list since $(local_human "${dsince:-0}"): watch relaunches it within a few minutes of the turn ending, once nothing holds it; make this the turn's last action"
else
    echo "ready: ${name:-?} ($uuid) — no recycle is waiting right now; the marker holds for $((SALA_READY_TTL/60)) min (withdraw: salamander ready --clear)"
fi
