#!/usr/bin/env bash
# The watchdog's auto-recycle (lib/watch.sh, AUTO-RECYCLE) and `sala recycle --when-idle` (lib/recycle-request.sh):
# board items waiting (a stub SALA_RECYCLE_WANTED_CMD) or a session's request cue one recycle at once, busy box or not
# (no whole-box idle wait), at most once an hour, never with the pane map frozen; requests are cleared once served
# and expire after 24 h. systemd-run is a stub that records what it was asked to launch; the cued recycle is then run for
# real once, to see it skip a busy pane and its retry worker relaunch that pane once idle. Also the provision sets' relaunch
# of a box that answers ssh again (provision_sets_tick): a fake heartbeat store, the launch counted as
# `provision --no-recycle`, so it also proves an automatic provision never recycles the fleet. (The puller catch-up,
# was removed with the other-platform boxes.) And the CLI auto-update split: the update at once (npm stubbed through a
# curl shim), the relaunch of the panes on the old CLI cued at once on a busy box; `update --no-recycle` (a stub
# CLI that moves its own launcher); a box the update unit skipped as offline gets its try back (an ssh stub).
# What launches and when is checked, never the posts' or the log's wording.
# Isolated HOME, a private tmux socket, the compiled fake claude.
# Usage: bash tests/autorecycle.sh   (exit 0 = pass; ~30 s)
set -u
unset TMUX_PANE XDG_STATE_HOME
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, tmux_socket_rm
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null
as_op_unit   # no master: the guarded verbs this suite runs itself stand for the queue's runner (tests/lib.sh, 5)
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$HOME/work"
touch "$HOME/.claude/salamander-rc.stopped"
cc -o "$HOME/.local/bin/claude" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
LAUNCHES="$HOME/launches.txt"
cat > "$HOME/.local/bin/systemd-run" <<EOF
#!/bin/sh
echo "\$*" >> "$LAUNCHES"
EOF
chmod +x "$HOME/.local/bin/systemd-run"
export PATH="$HOME/.local/bin:$PATH"; export FAKE_LOG="$HOME/fake.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="cat >> $POSTS"
export SALA_AUTO_UPDATE=off SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT"
WANT="$HOME/wanted.sh"; export SALA_RECYCLE_WANTED_CMD="sh $WANT"
SALA="$ROOT/bin/salamander"; SOCK="sala-autorecycle-$$"; T="tmux -L $SOCK -f /dev/null"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's (common.sh, on_fleet_server)
cleanup() {
    local p; $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done   # a retry worker the real recycle left
    for p in $(pgrep -x claude); do [ "$HOME/.local/bin/claude" -ef "/proc/$p/exe" ] && kill -9 "$p" 2>/dev/null; done
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
UM=aaaaaaaa-0000-4000-8000-0000000000a1 UA=bbbbbbbb-0000-4000-8000-0000000000b1
hand() { $T new-session -d -s "$1" -c "$HOME/work" -e FAKE_SESSION_ID="$2" -e FAKE_NAME="$1" -e FAKE_LOG="$FAKE_LOG"; $T send-keys -t "$1" 'claude' Enter; }
age() { local a="$1" u; shift; for u in "$@"; do touch -d "@$(( $(date +%s) - a ))" "$HOME/.claude/projects/x/$u.jsonl"; done; }   # transcript last written $1 s ago
wanted() { printf '%s\n' "$1" > "$WANT"; }       # the board stub's script
STATE="$HOME/.claude/salamander-watch.state"; WLOG="$HOME/.claude/salamander-watch.log"
st() { awk -F= -v k="$1" '$1==k {print substr($0, length(k)+2); exit}' "$STATE"; }
st_put() { { grep -v "^$1=" "$STATE"; echo "$1=$2"; } > "$STATE.t"; mv -f "$STATE.t" "$STATE"; }
fresh_board() { st_put recycle_wanted_at 0; }    # drop the 10-min cache of the board's answer
launches() { cat "$LAUNCHES" 2>/dev/null | grep -c 'recycle --update --force'; }
watch() { SALA_MASTER=sala-test-m "$SALA" watch >/dev/null 2>&1; }
workers() { local f n=0; for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill -0 "$(<"$f")" 2>/dev/null && n=$((n+1)); done; echo $n; }   # live retry workers
regstatus() {  # <tmux session> <status>: what the registry says about that pane's claude
    local c; c=$(claude_pid_under "$(tmux display -p -t "$1" '#{pane_pid}')"); set_reg_status "$c" "$2"; }

echo "== setup: a master and one more pane on the fake claude, both idle, transcripts an hour old"
hand sala-test-m "$UM"; hand sala-test-a "$UA"
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux
age 3600 "$UM" "$UA"
fake_up sala-test-m sala-test-a   # no wait for the registry's 10 s idle settle: the fake claude stamps its row 60 s old
. "$ROOT/lib/common.sh"
[ -n "$(claude_pid_under "$(tmux display -p -t sala-test-a '#{pane_pid}')")" ] && ok "fake claudes up" || { echo "no fake claude"; exit 1; }

echo "== nothing wanted: the board prints 0 and nobody asked → nothing happens"
wanted 'echo 0'; watch
[ "$(launches)" = 0 ] && ok "no recycle launched" || bad "launched: $(<"$LAUNCHES")"
[ "$(st recycle_wanted_n)" = 0 ] && ok "the board's answer is cached in watch state" || bad "state: $(grep recycle_ "$STATE")"

echo "== a failing or odd board command counts as 0"
for cmd in 'echo 5; exit 3' 'echo lots' 'true'; do
    wanted "$cmd"; fresh_board; watch
    [ "$(launches)" = 0 ] && [ "$(st recycle_wanted_n)" = 0 ] && ok "'$cmd' → 0, nothing launched" || bad "'$cmd': n=$(st recycle_wanted_n), launches=$(launches)"
done

echo "== 2 board items wait on a busy box (a pane mid-turn, written 1 min ago) → one recycle cued at once, as the master's cue would run it, with one post"
wanted 'echo 2 s1 s2'; fresh_board; age 60 "$UA"; regstatus sala-test-a busy; watch
[ "$(launches)" = 1 ] && ok "one recycle launched at once, the box not idle" || bad "launches: $(launches) — $(grep auto-recycle "$WLOG" | tail -2)"
[ "$(st recycle_wanted_n)" = 2 ] && [ "$(st recycle_wanted_ids)" = "s1 s2" ] && ok "count and ids parsed" || bad "parsed: $(st recycle_wanted_n) / $(st recycle_wanted_ids)"
regstatus sala-test-a idle; age 3600 "$UA"
grep 'recycle --update --force' "$LAUNCHES" | grep -q -- '-p KillMode=process' && grep -q 'SALA_LOCK_WHO=auto-recycle' "$LAUNCHES" && grep -q 'SALA_LOCK_WAIT=600' "$LAUNCHES" \
    && ok "its own unit: KillMode=process (the driver outlives it), lock holder auto-recycle, waits for the lock" || bad "launch line: $(<"$LAUNCHES")"
[ "$(st auto_recycle_served_ids)" = "s1 s2" ] && ok "the served ids are remembered" || bad "served: $(st auto_recycle_served_ids)"

echo "== --when-idle: record, list, cancel; it never recycles by itself"
out=$("$SALA" recycle --when-idle --from tester "reload the new connector" 2>&1)
echo "$out" | grep -q 'recorded recycle request .* from tester: reload the new connector' && ok "recorded" || bad "record: $out"
[ "$(launches)" = 1 ] && ok "recording launched nothing" || bad "recording launched"
"$SALA" recycle --when-idle "second one" >/dev/null; id=$("$SALA" recycle --when-idle --list | awk -F'\t' '$4=="second one" {print $1}')
"$SALA" recycle --when-idle --cancel "$id" | grep -q "dropped recycle request $id" && [ "$("$SALA" recycle --when-idle --list | grep -c .)" = 1 ] && ok "--cancel ID drops just that one" || bad "cancel: $("$SALA" recycle --when-idle --list)"

echo "== the hourly limit: a request right after the last auto-recycle waits"
wanted 'echo 0'; fresh_board; watch
[ "$(launches)" = 1 ] && ok "no second recycle within the hour" || bad "launched again: $(launches)"

echo "== a frozen pane map holds it back"
st_put auto_recycle_at $(( $(date +%s) - 3700 ))
touch "$SALA_SIDECAR"; ledger_freeze recycle $$ >/dev/null 2>&1; watch   # a freeze copies the map: it must exist
[ "$(launches)" = 1 ] && grep -q 'auto-recycle: due, but the pane map is frozen' "$WLOG" && ok "no recycle while frozen" || bad "frozen: launches=$(launches), log: $(grep auto-recycle "$WLOG" | tail -1)"
ledger_unfreeze "test done" >/dev/null 2>&1

echo "== an hour later the request triggers it, and is cleared"
watch
[ "$(launches)" = 2 ] && ok "the request launched the recycle" || bad "launches: $(launches) — $(tail -3 "$WLOG")"
"$SALA" recycle --when-idle --list | grep -q 'no recycle requests' && ok "the request marker is gone" || bad "left: $("$SALA" recycle --when-idle --list)"

echo "== the same board items again: already served, no new recycle; a new id counts"
st_put auto_recycle_at $(( $(date +%s) - 3700 )); wanted 'echo 2 s1 s2'; fresh_board; watch
[ "$(launches)" = 2 ] && ok "served ids do not recycle again" || bad "launched for served ids"
wanted 'echo 3 s1 s2 s3'; fresh_board; watch
[ "$(launches)" = 3 ] && ok "a new id does" || bad "launches: $(launches)"

echo "== SALA_AUTO_RECYCLE=off and a 25-h-old request: nothing launched, the old request expires with a log line"
st_put auto_recycle_at $(( $(date +%s) - 3700 )); wanted 'echo 0'; fresh_board
"$SALA" recycle --when-idle --from tester "while off" >/dev/null
SALA_AUTO_RECYCLE=off SALA_MASTER=sala-test-m "$SALA" watch >/dev/null 2>&1
[ "$(launches)" = 3 ] && ok "off: nothing launched" || bad "launched while off"
"$SALA" recycle --when-idle --cancel >/dev/null
d="$HOME/.local/state/salamander/recycle-requests"; old=$(( $(date +%s) - 90000 ))
printf '%s\tstale-asker\tlong ago\n' "$old" > "$d/$old-1.req"; watch
[ ! -e "$d/$old-1.req" ] && ok "expired: the request is gone" || bad "expiry: $(ls "$d"); $(grep expired "$WLOG")"
[ "$(launches)" = 3 ] && ok "an expired request triggers nothing" || bad "the expired request launched a recycle"

echo "== a request while a pane was written 1 min ago, with the old idle settings still in a config → cued at once (no longer read)"
"$SALA" recycle --when-idle --from tester "a new skill" >/dev/null 2>&1; age 60 "$UM" "$UA"
SALA_AUTO_IDLE=600 SALA_AUTO_UPDATE_IDLE=1800 SALA_MASTER=sala-test-m "$SALA" watch >/dev/null 2>&1
[ "$(launches)" = 4 ] && ok "one recycle cued at once" || bad "launches=$(launches); $(grep auto-recycle "$WLOG" | tail -1)"
age 3600 "$UM" "$UA"

echo "== the cued recycle, run for real: an idle pane is relaunched, a busy one is skipped and its retry worker relaunches it once idle"
# watch's line is \`recycle --update --force\`; --update would run \`claude update\` on the fake claude first, so the run here
# is the same sweep without it: recycle --force, with the env the unit gets and a short retry tick
grep 'unit=sala-auto-recycle-' "$LAUNCHES" | tail -1 | grep -q "salamander' recycle --update --force >>" && ok "the cue: recycle --update --force" || bad "launch line: $(tail -1 "$LAUNCHES")"
regstatus sala-test-a busy; sm0=$(grep -c "^start $UM" "$FAKE_LOG"); sa0=$(grep -c "^start $UA" "$FAKE_LOG")
SALA_RETRY_EVERY=2 SALA_LOCK_WHO=auto-recycle SALA_RELAUNCH_KIND=auto "$SALA" recycle --force >/dev/null 2>&1 || bad "recycle did not start"
waitfor '[ "$(grep -c "^start $UM" "$FAKE_LOG")" -gt '"$sm0"' ]' 60 && ok "the idle pane (sala-test-m) relaunched" || bad "sala-test-m not relaunched: $(tail -5 "$HOME/.claude/salamander-revive.log")"
waitfor '[ "$(workers)" -gt 0 ]' 40 && ok "a retry worker holds the busy pane" || bad "no retry worker: $(tail -5 "$HOME/.claude/salamander-revive.log")"
sleep 3; [ "$(grep -c "^start $UA" "$FAKE_LOG")" = "$sa0" ] && ok "the busy pane (sala-test-a) is not relaunched while busy" || bad "sala-test-a relaunched although busy"
regstatus sala-test-a idle
waitfor '[ "$(grep -c "^start $UA" "$FAKE_LOG")" -gt '"$sa0"' ]' 60 && ok "once idle, its retry worker relaunches it" || bad "sala-test-a not relaunched once idle: $(grep retry "$HOME/.claude/salamander-revive.log" | tail -3)"
waitfor '! recycle_locked && [ "$(workers)" = 0 ]' 60 || bad "the recycle lock or a retry worker is still held"
fake_up sala-test-m sala-test-a; age 3600 "$UM" "$UA"

echo "== served ids the board reports cleared after a recycle: a later flag on them counts again; the others still do not"
CLD="$SALA_RECYCLE_CLEARED_DIR"; PRL="$HOME/post-recycle.log"
hook() {  # <command printing one line>: the post-recycle hook as the recycle driver fires it (detached); waits for its 3 lines
    local n0; n0=$(grep -c . "$PRL" 2>/dev/null)
    SALA_POST_RECYCLE_CMD="$1; echo done" post_recycle_hook "$PRL" recycle "$(date +%s)"
    waitfor '[ "$(grep -c . "$PRL")" -ge '$((n0 + 3))' ]' 20 || bad "the hook did not finish: $(tail -3 "$PRL")"
    sleep 1   # the cleared-ids file is written once the rc is read, after the last line
}
cleared() { ls "$CLD"/*.ids 2>/dev/null | grep -c .; }
st_put auto_recycle_at $(( $(date +%s) - 3700 )); r0=$(launches)
[ "$(st auto_recycle_served_ids)" = "s1 s2 s3" ] || bad "setup: served is '$(st auto_recycle_served_ids)'"
hook 'echo "stackshot: 1 item(s) no longer wait for a recycle (s2)"; exit 1'
[ "$(cleared)" = 0 ] && ok "a post-recycle command that failed hands over nothing" || bad "files after a failed hook: $(cat "$CLD"/*.ids)"
hook 'echo "stackshot: 0 item(s) no longer wait for a recycle (none)"'
wanted 'echo 2 s1 s2'; fresh_board; watch   # the board's answer, cached, still lists s1
[ "$(cleared)" = 0 ] && [ "$(st auto_recycle_served_ids)" = "s1 s2 s3" ] && [ "$(launches)" = "$r0" ] \
    && ok "a report naming none: read and removed, served ids unchanged, nothing launched" || bad "none: files=$(cleared) served='$(st auto_recycle_served_ids)' launches=$(launches)"
hook 'echo "stackshot: 2 item(s) no longer wait for a recycle (s1, s9)"'
[ "$(cleared)" = 1 ] && ok "the cleared ids are handed over in one file" || bad "files: $(cleared); $(tail -3 "$PRL")"
wanted 'echo 1 s2'; watch   # no fresh_board: the cached answer from before the clear must not count
[ "$(cleared)" = 0 ] && [ "$(st auto_recycle_served_ids)" = "s2 s3" ] && ok "s1 leaves the served ids, s2 and s3 stay" || bad "served='$(st auto_recycle_served_ids)' files=$(cleared)"
[ "$(launches)" = "$r0" ] && ok "no recycle: the board asked afresh (not its cached s1), and s2, not reported cleared, is still served" || bad "launched: $(grep auto-recycle "$WLOG" | tail -2)"
wanted 'echo 2 s1 s2'; fresh_board; watch
[ "$(launches)" = $((r0 + 1)) ] && ok "s1 flagged again after its clear → one recycle" || bad "launches=$(launches) (r0=$r0); $(grep auto-recycle "$WLOG" | tail -2)"
[ "$(st auto_recycle_served_ids)" = "s1 s2" ] && ok "served ids now the ones just served" || bad "served='$(st auto_recycle_served_ids)'"

echo "== <id>@<epoch> tokens: a new set time for the same id is a new flag; the post shows the bare id"
st_put auto_recycle_at $(( $(date +%s) - 3700 )); : > "$POSTS"
E1=$(( $(date +%s) + 3600 )); E2=$(( E1 + 7200 ))   # set times after every pane started (the relaunches above): an older flag is served by them (the guard of Tue Nov 3rd, tested below)
wanted "echo 1 g50@$E1"; fresh_board; watch
[ "$(launches)" = $((r0 + 2)) ] && [ "$(st auto_recycle_served_ids)" = "g50@$E1" ] && ok "g50@$E1 → one recycle, the token served" || bad "launches=$(launches) served='$(st auto_recycle_served_ids)'"
grep -q 'waited for a recycle (board#50)' "$POSTS" && ! grep -q "@$E1" "$POSTS" && ! grep -qE '\bg50\b' "$POSTS" && ok "the post names the item as board#50, not the store id g50, without its @epoch" || bad "post: $(<"$POSTS")"
st_put auto_recycle_at $(( $(date +%s) - 3700 )); fresh_board; watch
[ "$(launches)" = $((r0 + 2)) ] && ok "the same token again → no recycle" || bad "the served token launched again"
wanted "echo 1 g50@$E2"; fresh_board; watch
[ "$(launches)" = $((r0 + 3)) ] && [ "$(st auto_recycle_served_ids)" = "g50@$E2" ] && ok "g50 with a new set time → one recycle" || bad "launches=$(launches) served='$(st auto_recycle_served_ids)'"
hook 'echo "stackshot: 1 item(s) no longer wait for a recycle (g50)"'; watch
[ -z "$(st auto_recycle_served_ids)" ] && ok "a bare g50 in the report clears the g50@<epoch> token" || bad "served='$(st auto_recycle_served_ids)'"

echo "== the two guards (Tue Nov 3rd 2026): a flag whose change is not in the checkout yet, and a flag every pane is newer than, recycle nothing"
# On that day a flag (raised 10:38) was served by the recycle at 10:44; the change merged at 10:56 and every pane had been relaunched
# 10:28-10:40, so each rested 30 min and was relaunched again. The panes' startedAt is set by hand here; the change lives in a fixture repo.
FX="$HOME/fx"; mkdir -p "$FX"; g() { git -C "$FX" -c user.name=t -c user.email=t@t.test -c commit.gpgsign=false "$@"; }
g init -q; g checkout -q -b main 2>/dev/null; g commit -q --allow-empty -m base
g checkout -q -b feat; g commit -q --allow-empty -m "the change"; FEAT=$(g rev-parse HEAD); g checkout -q main
export SALA_RECYCLE_REF_REPOS="fx=$FX"; d="$HOME/.local/state/salamander/recycle-requests"
pane_start() { local ep="$1" s c; shift; for s in "$@"; do c=$(claude_pid_under "$(tmux display -p -t "$s" '#{pane_pid}')"); sed -i "s/\"startedAt\":[0-9]*/\"startedAt\":${ep}000/" "$HOME/.claude/sessions/$c.json"; done; }
reset_guard() { wanted "echo 0"; fresh_board; st_put auto_recycle_at $(( $(date +%s) - 3700 )); st_put auto_recycle_served_ids ""; st_put auto_recycle_first_seen ""; "$SALA" recycle --when-idle --cancel >/dev/null; : > "$POSTS"; }
HOOKS="$HOME/hookcalls.txt"; : > "$HOOKS"
watchh() { SALA_POST_RECYCLE_CMD="echo \"\$SALA_RECYCLE_FLAG_AT\" >> $HOOKS" SALA_MASTER=sala-test-m "$SALA" watch >/dev/null 2>&1; }
N0=$(date +%s)
echo "-- the incident: panes relaunched (N0-200) after the flag (N0-300), the change not merged yet"
pane_start $((N0 - 200)) sala-test-m sala-test-a; reset_guard; r0=$(launches)
wanted "echo 1 g60@$((N0 - 300))~fx:pr9"; fresh_board; watchh
[ "$(launches)" = "$r0" ] && ok "pr9 is not in the checkout → no recycle" || bad "launched for a change that is not live: $(grep auto-recycle "$WLOG" | tail -2)"
grep -q 'auto-recycle: skipped.*board#60.*fx:pr9 is not in the checkout yet' "$WLOG" && ok "one log line says why: board#60 waits for fx:pr9" || bad "log: $(grep auto-recycle "$WLOG" | tail -2)"
[ -z "$(st auto_recycle_served_ids)" ] && ok "the flag is not served (its recycle is still to come)" || bad "served: '$(st auto_recycle_served_ids)'"
n=$(grep -c 'auto-recycle: skipped' "$WLOG"); fresh_board; watchh
[ "$(grep -c 'auto-recycle: skipped' "$WLOG")" = "$n" ] && ok "the next run does not repeat the line" || bad "line repeated"
g commit -q --allow-empty -m "Merge pull request #9 from t/x"
fresh_board; watchh
[ "$(launches)" = $((r0 + 1)) ] && ok "pr9 merged and in the checkout, but the panes started before it landed (and the deploy's slack) → one recycle" || bad "launches=$(launches) (r0=$r0): $(grep auto-recycle "$WLOG" | tail -2)"
[ "$(st auto_recycle_served_ids)" = "g60@$((N0 - 300))~fx:pr9" ] && ok "the token is served" || bad "served: '$(st auto_recycle_served_ids)'"
echo "-- a request names its change; a sha counts once its branch is merged; an unreadable or unknown one counts as live"
"$SALA" recycle --when-idle --change not-a-ref "x" 2>&1 | grep -q -- '--change takes' && ok "--change refuses text that is no sha or pr<N>" || bad "no refusal for a bad --change"
reset_guard; r0=$(launches)
"$SALA" recycle --when-idle --from tester --change "fx:${FEAT:0:10}" "needs the feature" | grep -q 'waits until fx:' && ok "recorded with its change" || bad "record: no 'waits until'"
"$SALA" recycle --when-idle --list | grep -q "change: fx:${FEAT:0:10}" && ok "--list shows it" || bad "list: $("$SALA" recycle --when-idle --list)"
watchh
[ "$(launches)" = "$r0" ] && [ "$("$SALA" recycle --when-idle --list | grep -c needs)" = 1 ] && ok "the sha is not in HEAD → no recycle, the request stays" || bad "launches=$(launches); $("$SALA" recycle --when-idle --list)"
grep -q 'auto-recycle: skipped.*request from tester.*is not in the checkout yet' "$WLOG" && ok "its log line names the request" || bad "log: $(grep auto-recycle "$WLOG" | tail -2)"
pane_start $((N0 - 5000)) sala-test-m sala-test-a
g merge -q --no-ff feat -m "merge the feature"; watchh
[ "$(launches)" = $((r0 + 1)) ] && "$SALA" recycle --when-idle --list | grep -q 'no recycle requests' && ok "merged → one recycle, the request cleared" || bad "launches=$(launches) (r0=$r0); $("$SALA" recycle --when-idle --list)"
reset_guard; r0=$(launches)
"$SALA" recycle --when-idle --from tester --change "nosuchrepo:pr1" "unknown repo" >/dev/null; watchh
[ "$(launches)" = $((r0 + 1)) ] && ok "a reference sala cannot check (no checkout for its repo) does not hold a recycle back" || bad "launches=$(launches)"
reset_guard; r0=$(launches); printf '%s\ttester\tnever lands\tfx:pr77\n' $(( $(date +%s) - 20 )) > "$d/$(( $(date +%s) - 20 ))-1.req"; watchh
[ "$(launches)" = "$r0" ] && ok "a change that never lands holds the recycle back (SALA_RECYCLE_REF_WAIT is 24 h)" || bad "not held: launches=$(launches)"
SALA_RECYCLE_REF_WAIT=10 watchh
[ "$(launches)" = $((r0 + 1)) ] && ok "past SALA_RECYCLE_REF_WAIT the missing change no longer holds it" || bad "launches=$(launches) (r0=$r0): $(grep auto-recycle "$WLOG" | tail -2)"

echo "-- every pane started after the flag: nothing recycled, the request dropped, the board told"
pane_start $((N0 - 100)) sala-test-m sala-test-a; reset_guard; r0=$(launches); : > "$HOOKS"
wanted "echo 1 g61@$((N0 - 500))"; fresh_board; watchh
[ "$(launches)" = "$r0" ] && ok "a board flag older than every pane → no recycle" || bad "launched: $(grep auto-recycle "$WLOG" | tail -2)"
grep -q 'auto-recycle: skipped board#61 — every pane (2) was relaunched after the flag' "$WLOG" && ok "one log line says why" || bad "log: $(grep auto-recycle "$WLOG" | tail -2)"
[ "$(st auto_recycle_served_ids)" = "g61@$((N0 - 500))" ] && ok "the token is served, so it is not judged again" || bad "served: '$(st auto_recycle_served_ids)'"
waitfor '[ "$(grep -c . "$HOOKS")" -ge 1 ]' 20 && [ "$(head -1 "$HOOKS")" = "$((N0 - 500))" ] && ok "the board is told, with the flag's own time (post-recycle command, SALA_RECYCLE_FLAG_AT)" || bad "hook: '$(cat "$HOOKS")'"
reset_guard; r0=$(launches); : > "$HOOKS"
st_put auto_recycle_first_seen "g62:$((N0 - 400))"; wanted 'echo 1 g62'; fresh_board; watchh
[ "$(launches)" = "$r0" ] && grep -q 'skipped board#62' "$WLOG" && ok "a bare id is timed by when watch first saw it: older than every pane → served" || bad "bare: launches=$(launches)"
reset_guard; r0=$(launches); wanted 'echo 1 g63'; fresh_board; watchh
[ "$(launches)" = $((r0 + 1)) ] && ok "a bare id seen just now is not provably served → recycled, as before" || bad "bare, new: launches=$(launches)"
reset_guard; r0=$(launches); wanted 'echo 0'; fresh_board
printf '%s\ttester\ta request older than every pane\n' $((N0 - 500)) > "$d/$((N0 - 500))-7.req"; watchh
[ "$(launches)" = "$r0" ] && [ ! -e "$d/$((N0 - 500))-7.req" ] && grep -q 'skipped the request from tester' "$WLOG" && ok "a request older than every pane is dropped with a log line" || bad "req: launches=$(launches); $(ls "$d"); $(grep auto-recycle "$WLOG" | tail -1)"
reset_guard; r0=$(launches)
pane_start $((N0 - 1000)) sala-test-m; pane_start $((N0 - 100)) sala-test-a
printf '%s\ttester\ta 3-field marker of an older sala\n' $((N0 - 500)) > "$d/$((N0 - 500))-8.req"; watchh
[ "$(launches)" = $((r0 + 1)) ] && ok "one pane older than the flag → recycled (and a 3-field marker still reads)" || bad "mixed: launches=$(launches)"
pane_start $((N0 - 100)) sala-test-m sala-test-a
GIT_COMMITTER_DATE="$((N0 - 3000)) +0000" g commit -q --allow-empty -m "Merge pull request #12 from t/y"   # landed long ago
reset_guard; r0=$(launches); printf '%s\ttester\twith a change that landed long ago\tfx:pr12\n' $((N0 - 3000)) > "$d/$((N0 - 3000))-9.req"; watchh
[ "$(launches)" = "$r0" ] && ok "a change that landed before the panes started does not hold back the guard: served" || bad "landed: launches=$(launches); $(grep auto-recycle "$WLOG" | tail -1)"
reset_guard; age 3600 "$UM" "$UA"; fake_up sala-test-m sala-test-a
unset SALA_RECYCLE_REF_REPOS

echo "== CLI auto-update: the CLI update at once, busy box or not; the relaunch of the panes left on the old CLI at the next run"
ME=$(hostname); REAL_CURL=$(command -v curl || echo /usr/bin/curl); NPM="$HOME/npm-latest"; AUV="$HOME/au/versions"; mkdir -p "$AUV" "$HOME/fleet0/a" "$HOME/fleet0/d"
cp "$HOME/.local/bin/claude" "$AUV/9.9.9"; cp "$HOME/.local/bin/claude" "$AUV/9.9.10"; ln -sfn "$AUV/9.9.9" "$HOME/au/claude"   # the launcher: versions/<ver>, as the native installer lays it out
cat > "$HOME/.local/bin/curl" <<EOF
#!/bin/sh
case "\$*" in *registry.npmjs.org*) cat "$NPM"; exit 0;; esac
exec "$REAL_CURL" "\$@"
EOF
chmod +x "$HOME/.local/bin/curl"; echo '{"version": "9.9.10"}' > "$NPM"
echo '{"fleet_ssh": {"box-d": {"letter": "d", "ok": true}}}' > "$HOME/fleet0/a/machine.json"; echo '{"claude": "9.9.8"}' > "$HOME/fleet0/d/machine.json"
auwatch() { SALA_AUTO_UPDATE=on SALA_CLAUDE="$HOME/au/claude" SALA_HEARTBEAT_STATE_DIR="$HOME/fleet0" SALA_MASTER=sala-test-m "$SALA" watch >/dev/null 2>&1; }
updates() { grep -c 'unit=sala-auto-update-' "$LAUNCHES" 2>/dev/null; }
relaunches() { grep -c 'unit=sala-auto-relaunch-' "$LAUNCHES" 2>/dev/null; }
st_put auto_recycle_at "$(date +%s)"   # the auto-recycle stays out of these runs (its hourly limit)
age 120 "$UA"; age 3600 "$UM"; r0=$(launches)
auwatch
[ "$(updates)" = 1 ] && grep 'unit=sala-auto-update-' "$LAUNCHES" | grep -q -- "update box-d $ME --release --no-recycle --auto >>" \
    && ok "npm newer, box busy (a pane active 2 min ago) → ONE update at once: box-d and this box, this box --no-recycle" || bad "updates=$(updates): $(grep update "$LAUNCHES")"
[ "$(relaunches)" = 0 ] && [ "$(launches)" = "$r0" ] && ok "no relaunch, no recycle" || bad "relaunched: $(tail -2 "$LAUNCHES")"
[ "$(st auto_update_tried)" = 9.9.10 ] && [ "$(st auto_update_tried_box-d)" = 9.9.10 ] && ok "one try per version recorded for both" || bad "tried: $(grep auto_update_tried "$STATE")"
ln -sfn "$AUV/9.9.10" "$HOME/au/claude"   # the update unit ran: the launcher moved, the panes still run 9.9.9
regstatus sala-test-a busy; st_put auto_update_checked 0; auwatch
[ "$(updates)" = 1 ] && ok "npm asked again, same version → no second update" || bad "updated again: $(updates)"
[ "$(relaunches)" = 1 ] && ok "panes on 9.9.9 under a 9.9.10 launcher, a pane busy and one written 2 min ago → one relaunch cued at once" || bad "relaunches=$(relaunches); $(grep auto-update "$WLOG" | tail -1)"
grep 'unit=sala-auto-relaunch-' "$LAUNCHES" | grep -q -- "-p KillMode=process --setenv=SALA_LOCK_WHO=auto-update --setenv=SALA_LOCK_WAIT=600 .*salamander' recycle >> .*salamander-revive.log" \
    && ok "its own unit: \`recycle\` (no --force: those panes only), lock holder auto-update, waits for the lock" || bad "launch line: $(grep relaunch "$LAUNCHES")"
auwatch
[ "$(relaunches)" = 1 ] && [ "$(st auto_update_relaunched)" = 9.9.10 ] && ok "next run, panes still on 9.9.9 → no second relaunch for 9.9.10" || bad "relaunches=$(relaunches)"
st_put auto_update_relaunched 9.9.10; regstatus sala-test-a idle; age 3600 "$UA"

echo "== a box the update unit skipped as offline gets its try back (a box awake to the heartbeat but silent to the unit's own probe a minute later)"
# an ssh stub per host: down (ssh-down-<host>), answering with an error from claude update (ssh-err-<host>), else updating 9.9.8 → 9.9.10
cat > "$HOME/.local/bin/ssh" <<EOF
#!/bin/sh
for a; do h=\$l; l=\$a; done
[ -e "$HOME/ssh-down-\$h" ] && exit 255
case "\$l" in *PSVersionTable*) echo posix;; *) if [ -e "$HOME/ssh-err-\$h" ]; then echo "ERR|boom"; else echo "V|9.9.8|9.9.10"; fi;; esac
EOF
chmod +x "$HOME/.local/bin/ssh"
# The fleet hosts here are fixtures (box-d, box-x), never a real machine's name: sala treats a host named like THIS box as the local
# leg (update.sh ME, fleet_hosts), which then runs `claude update` on this box and, for the fake claude, never returns. On the
# CI runner real names did exactly that and the suite hung until the job's time limit.
uau() { SALA_FLEET_HOSTS="box-d box-x" SALA_HEARTBEAT_STATE_DIR= timeout 120 "$SALA" update "$@" >/dev/null 2>&1; }   # what the launched unit runs (bounded: a hang is a failed check, not a lost job)
tried() { st "auto_update_tried_$1"; }
: > "$POSTS"; touch "$HOME/ssh-down-box-d"
[ "$(tried box-d)" = 9.9.10 ] && [ "$(updates)" = 1 ] && ok "start: box-d's try for 9.9.10 is spent, one update launched" || bad "start: tried=$(tried box-d) updates=$(updates)"
uau box-d --auto
[ -z "$(tried box-d)" ] && ok "(a) the unit found box-d offline → its try is given back" || bad "(a) marker kept: '$(tried box-d)'"
st_put auto_update_checked 0; auwatch
[ "$(updates)" = 2 ] && grep 'unit=sala-auto-update-' "$LAUNCHES" | tail -1 | grep -q -- "update box-d --auto >>" && [ "$(tried box-d)" = 9.9.10 ] \
    && ok "(a) the next auto_update run, the heartbeat seeing it awake → box-d launched again (no --release: the release run has been), the try recorded again" || bad "(a) updates=$(updates) tried='$(tried box-d)': $(tail -1 "$LAUNCHES")"
rm -f "$HOME/ssh-down-box-d"
uau box-d --auto
[ "$(tried box-d)" = 9.9.10 ] && ok "(b) the unit reached box-d and updated it → the try stays" || bad "(b) updated: marker '$(tried box-d)'"
st_put auto_update_checked 0; auwatch
[ "$(updates)" = 2 ] && ok "(b) the next run → no launch for box-d (one try per version for a real attempt)" || bad "(b) launched again: updates=$(updates)"
touch "$HOME/ssh-err-box-d"; uau box-d --auto
[ "$(tried box-d)" = 9.9.10 ] && grep -q 'box-d: FAILED' "$HOME/.claude/salamander-update.log" && ok "(b) a real attempt that fails (claude update errors) keeps the try too" || bad "(b) failed: marker '$(tried box-d)'"
st_put auto_update_checked 0; auwatch
[ "$(updates)" = 2 ] && ok "(b) …and is not launched again" || bad "(b) failed attempt relaunched: updates=$(updates)"
rm -f "$HOME/ssh-err-box-d"
echo "== …and a retry loop on a box that stays offline posts nothing of it"
touch "$HOME/ssh-down-box-d"; : > "$POSTS"
uau box-d box-x --auto --release
grep -q 'box-d offline, update when awake' "$POSTS" && [ "$(grep -c 'CLI update' "$POSTS")" = 1 ] && ok "the release run names box-d offline once, with box-x's update" || bad "release post: $(<"$POSTS")"
[ -z "$(tried box-d)" ] && ok "(a) in a release run too: box-d's try is back" || bad "(a) release run kept '$(tried box-d)'"
: > "$POSTS"
for n in 1 2 3; do st_put auto_update_tried_box-d 9.9.10; uau box-d --auto; done
[ ! -s "$POSTS" ] && ok "(c) three retry runs, box-d offline each time → no post" || bad "(c) posted: $(<"$POSTS")"
[ -z "$(tried box-d)" ] && ok "(c) …and it stays due for the next auto_update run" || bad "(c) marker '$(tried box-d)'"
uau box-d box-x --auto
grep -q 'box-x updated' "$POSTS" && ! grep -q 'box-d' "$POSTS" && ok "(c) a retry run that also updates another box posts that box only, not box-d's offline line" || bad "(c) mixed retry post: $(<"$POSTS")"
st_put auto_update_tried_box-d 9.9.10; uau box-d --auto --check
[ "$(tried box-d)" = 9.9.10 ] && ok "a --check leaves the marker alone" || bad "--check cleared the marker"
uau box-d
[ "$(tried box-d)" = 9.9.10 ] && ok "a manual update without --auto leaves the marker alone" || bad "manual run cleared the marker"
rm -f "$HOME/ssh-down-box-d" "$HOME/.local/bin/ssh"; st_put auto_update_tried_box-d 9.9.10

echo "== update --no-recycle (watch's at-once leg): the CLI and the post, no relaunch, no recycle lock"
AU2="$HOME/au2/versions"; mkdir -p "$AU2"
printf '#!/bin/sh\n[ "$1" = update ] && ln -sfn "%s/9.9.10" "%s/au2/claude" && echo "Successfully updated to 9.9.10"\n' "$AU2" "$HOME" > "$AU2/9.9.9"
printf '#!/bin/sh\necho "Claude Code is up to date (9.9.10)"\n' > "$AU2/9.9.10"; chmod +x "$AU2/9.9.9" "$AU2/9.9.10"; ln -sfn "$AU2/9.9.9" "$HOME/au2/claude"
exits0=$(grep -c '^exit' "$FAKE_LOG" 2>/dev/null)
flock -o "$SALA_RECYCLE_LOCK" sleep 40 & holder=$!; sleep 1   # a recycle holds the lock all along
t0=$(date +%s)
out=$(SALA_CLAUDE="$HOME/au2/claude" SALA_HEARTBEAT_STATE_DIR= timeout 60 "$SALA" update "$ME" --auto --no-recycle 2>&1); rc=$?
kill $holder 2>/dev/null; wait $holder 2>/dev/null
[ "$rc" = 0 ] && [ $(( $(date +%s) - t0 )) -lt 30 ] && ok "done in seconds although a recycle holds the lock" || bad "rc=$rc after $(( $(date +%s) - t0 )) s: $out"
[ "$(basename "$(readlink -f "$HOME/au2/claude")")" = 9.9.10 ] && ok "the CLI was updated" || bad "launcher: $(readlink "$HOME/au2/claude")"
sleep 2; [ "$(grep -c '^exit' "$FAKE_LOG" 2>/dev/null)" = "$exits0" ] && ! echo "$out" | grep -q 'relaunching the' && ok "no pane relaunched" || bad "a relaunch ran: $out"

echo "== --update --dry-run: the CLI's updater is never called (Wed Oct 14th 2026: revive --update --dry-run ran claude update)"
AU3="$HOME/au3/versions"; CALLS="$HOME/au3/calls"; mkdir -p "$AU3"
printf '#!/bin/sh\necho "$*" >> "%s"\n[ "$1" = update ] && ln -sfn "%s/9.9.10" "%s/au3/claude"\nexit 0\n' "$CALLS" "$AU3" "$HOME" > "$AU3/9.9.9"
cp "$AU3/9.9.9" "$AU3/9.9.10"; chmod +x "$AU3/9.9.9" "$AU3/9.9.10"; ln -sfn "$AU3/9.9.9" "$HOME/au3/claude"
out=$(SALA_CLAUDE="$HOME/au3/claude" timeout 60 "$SALA" revive --update --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && ! grep -qs '^update' "$CALLS" && [ "$(basename "$(readlink -f "$HOME/au3/claude")")" = 9.9.9 ] && ok "revive --update --dry-run: exit 0, claude update not called, the launcher unmoved" || bad "revive --update --dry-run ($rc): calls '$(slurp "$CALLS")' launcher $(readlink "$HOME/au3/claude") / $out"
grep -qF '[dry-run] would update the CLI: 9.9.9 →' <<< "$out" && ok "and it says what it would do" || bad "no dry-run line: $out"
out=$(SALA_CLAUDE="$HOME/au3/claude" timeout 60 "$SALA" recycle --update --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && grep -qF '[dry-run] would update the CLI: 9.9.9 →' <<< "$out" && grep -q 'flags: .*--dry-run' <<< "$out" && ok "recycle --update --dry-run: the dry-run line, --dry-run handed to the driver" || bad "recycle --update --dry-run ($rc): $out"
sleep 3; ! grep -qs '^update' "$CALLS" && [ "$(basename "$(readlink -f "$HOME/au3/claude")")" = 9.9.9 ] && [ "$(grep -c '^exit' "$FAKE_LOG" 2>/dev/null)" = "$exits0" ] \
    && ok "and still no claude update, no pane relaunched" || bad "after recycle --update --dry-run: calls '$(slurp "$CALLS")', exits $(grep -c '^exit' "$FAKE_LOG")"
rm -f "$HOME/.local/bin/curl"

echo "== provision sets' fixtures: a fake heartbeat store, a tick that retries when a revive runs elsewhere on this box"
FLEET="$HOME/fleet"; mkdir -p "$FLEET/a" "$FLEET/d" "$FLEET/x"
echo '{"claude": "2.1.0"}' > "$FLEET/d/machine.json"; echo '{"claude": "2.1.0"}' > "$FLEET/x/machine.json"
# systemctl stub: every unit reads as not active
cat > "$HOME/.local/bin/systemctl" <<EOF
#!/bin/sh
exit 1
EOF
chmod +x "$HOME/.local/bin/systemctl"
awake() {  # <box-x ok: true|false> — box-d always answers ssh
    printf '{"fleet_ssh": {"box-d": {"letter": "d", "ok": true}, "box-x": {"letter": "x", "ok": %s}}}\n' "$1" > "$FLEET/a/machine.json"; }
export SALA_HEARTBEAT_STATE_DIR="$FLEET"
pwatch() {  # a whole watch tick; one that watch skipped because a revive runs ELSEWHERE on this box (busy_elsewhere is
    # box-wide: another worktree's suite) is retried, so these checks do not depend on what else runs here
    local n wl; for n in $(seq 1 75); do
        wl=$(wc -l < "$WLOG" 2>/dev/null || echo 0)
        SALA_MASTER=sala-test-m "$SALA" watch >/dev/null 2>&1
        tail -n +$((wl + 1)) "$WLOG" | grep -q 'skip: a resurrect restore or a salamander revive is running' || return 0
        sleep 4
    done; }

echo "== provision sets: a box a set lists as offline that answers ssh again → one provision of it, as its own unit"
PS="$(( $(date +%s) - 60 ))-$$"; set_create "$PS" Provision provision 2 1 - 1 out=box-x offline=box-x
awake true; n0=$(grep -c 'unit=sala-auto-provision-sets' "$LAUNCHES"); pwatch
[ "$(grep -c 'unit=sala-auto-provision-sets' "$LAUNCHES")" = $((n0 + 1)) ] && grep 'unit=sala-auto-provision-sets' "$LAUNCHES" | tail -1 | grep -q 'provision --no-recycle box-x' \
    && ok "box-x back → provision --no-recycle box-x under the fixed unit sala-auto-provision-sets" || bad "launches: $(grep provision-sets "$LAUNCHES"); $(grep 'provision sets' "$WLOG" | tail -2)"
pwatch
[ "$(grep -c 'unit=sala-auto-provision-sets' "$LAUNCHES")" = $((n0 + 1)) ] && ok "the next tick does not launch it again (at most every SALA_RETRY_EVERY)" || bad "relaunched: $(grep -c provision-sets "$LAUNCHES")"
rm -f "$SALA_SET_DIR/$PS"

[ "$fail" = 0 ] && echo "PASS" || echo "FAILED"
exit $fail
