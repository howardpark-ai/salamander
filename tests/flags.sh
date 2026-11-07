#!/usr/bin/env bash
# The recycle FLAG, the JOB and their waits (lib/common.sh "recycle sets",
# set_sync, recycle_job_gate, recycle_rest_left; lib/revive.sh rest_applies; lib/watch.sh sets_tick). What is checked is state and
# that the posts and hook calls go out, never their wording.
#   1. THE RULE, on a table of fake panes (_set_pane_read redefined: session, state, start time), so a fleet of any size costs nothing:
#      a flag clears when every live pane it waits for has relaunched since its time; a pane that started in the flag's own second, one
#      with nothing to read, or one not yet back keeps it open; a retired pane does not count (N drops), one gone but still mapped does;
#      a pane skipped by two recycles clears BOTH flags when it comes back (two ✅ posts, two hook calls); the master's pane is a pane
#      like another; a flag with no live panes at all closes; the open records of the old format are reconciled once (a dry run
#      first, changing nothing; the old ones close without a post), never closing a flag with a live pane that has not relaunched.
#   2. THE JOB: a flag raised at 15/20 reads 0/20, the same job relaunches the 15 again, one pointer and one worker; only the job's flag
#      posts 🔄, the older one posts when it clears. The deferred list keeps one row per pane, repointed at the newest flag.
#   3. SCOPES: a revive / lane / model flag is one pane and clears on that pane alone; an all-panes flag needs every live pane.
#   4. THE HOOK against tests/fake-recycled-client.py, a strict fake of stackshot's client: ONE call per cleared flag, flag_at = started
#      = the flag's time, skipped empty for a full clear and the given-up panes for a partial one (a pane held past the later list's
#      limit), nothing while a flag is open, never twice; the BAD lines the fake writes for a malformed call stay out of its log.
#   5. THE GATE (fake clock): flags 3 min apart keep gathering, 10 min of silence resets, the 30 min cap resets, an op recycle waits for
#      nothing, a knob at 0 turns the wait off, one short post per gathering.
#   6. THE REST: the registry's startedAt; a pane started 10 min ago is skipped by a routine recycle and relaunched once its rest is
#      up, an op recycle skips the rest, a knob at 0 turns it off; the real _set_pane_read on a real pane; two flags and one busy
#      pane end to end; a lane flag; watch gathering a request behind an unfinished job, then resetting once.
# Slack stubbed to a file. Isolated HOME, a private tmux socket, the compiled fake claude (tests/fake-claude.c).
# Usage: bash tests/flags.sh   (exit 0 = pass)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_SET SALA_SET_SELF SALA_POST_RECYCLE_CMD SALA_RECYCLE SALA_RETRY_WORKER SALA_FLAG_SRC
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
as_op_unit
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect"
touch "$HOME/.claude/salamander-rc.stopped"
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$HOME/.local/share/claude/versions/9.9.9" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
FAKEBIN="$HOME/.local/share/claude/versions/9.9.9"
ln -s "$FAKEBIN" "$HOME/.local/bin/claude"
LAUNCHES="$HOME/launches.txt"; printf '#!/bin/sh\necho "$*" >> "%s"\n' "$LAUNCHES" > "$HOME/.local/bin/systemd-run"; chmod +x "$HOME/.local/bin/systemd-run"
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="{ cat; echo '%%'; } >> $POSTS"
HOOKLOG="$HOME/recycled.jsonl"; : > "$HOOKLOG"; export FAKE_RECYCLED_LOG="$HOOKLOG" SALA_POST_RECYCLE_CMD="python3 $ROOT/tests/fake-recycled-client.py"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off
SALA="$ROOT/bin/salamander"; SOCK="sala-flags-$$"; T="tmux -L $SOCK -f /dev/null"; RLOG="$HOME/.claude/salamander-revive.log"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"
cleanup() {
    local f p; for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    kill_fake_claude "$FAKEBIN"
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux
. "$ROOT/lib/common.sh"
workers() { local f n=0; for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill -0 "$(<"$f")" 2>/dev/null && n=$((n+1)); done; echo $n; }
hooks() { local n=0 l; while IFS= read -r l || [ -n "$l" ]; do [ -n "$l" ] && n=$((n+1)); done < "$HOOKLOG"; echo "$n"; }
hook_with() { grep -c -- "$1" "$HOOKLOG"; }                # how many calls hold the text
nobad() { ! grep -q '^BAD' "$HOOKLOG"; }                   # the strict fake refused nothing
reset_sets() { waitfor '! pgrep -f tests/fake-recycled-client.py >/dev/null' 20; rm -f "$SALA_SET_DIR"/[0-9]*-[0-9]* "$SALA_SET_DIR"/current.* "$SALA_SET_DIR"/job.* "$SALA_DEFERRED"; : > "$POSTS"; : > "$HOOKLOG"; }
wait_lock() { lock_wait "$HOME/.claude/salamander-recycle.lock" 60; }
mk() { local n="$1" u="$2"; shift 2; $T new-session -d -s "sala-test-$n" -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="$n" -e FAKE_LOG="$FAKE_LOG" "$@"; $T send-keys -t "sala-test-$n" 'claude' Enter; }
draft() { fake_up "$1"; $T send-keys -t "sala-test-$1" -l 'half a thought'; waitfor "$T capture-pane -p -t sala-test-$1 | grep -q 'half a thought'" 20; }
undraft() { $T send-keys -t "sala-test-$1" Enter; }
newest_set() { local f best=""; for f in "$SALA_SET_DIR"/[0-9]*-[0-9]*; do [ -e "$f" ] || continue; [[ ${f##*/} > "${best##*/}" ]] && best=$f; done; echo "${best##*/}"; }

# ── the fake panes: session \t state (live | wait | gone) \t startedAt (epoch s) ─────────────────────────────────────────────────
PT="$HOME/panes.tsv"; : > "$PT"
pane() { local s=$1; shift; { grep -v "^$s"$'\t' "$PT" 2>/dev/null; printf '%s\t%s\t%s\n' "$s" "$1" "${2:-0}"; } > "$PT.t"; mv -f "$PT.t" "$PT"; }
_set_pane_read() { local s st sa; while IFS=$'\t' read -r s st sa; do if [ "$s" = "$1" ]; then case "$st" in live) echo "live $((sa * 1000)) 9.9.9";; *) echo "$st";; esac; return 0; fi; done < "$PT"; echo gone; }
mkdir -p "$(dirname "$SALA_SIDECAR")"; : > "$SALA_SIDECAR"
mapped() { printf '%s\t%s\tn\t/tmp\n' "$1" "$(uuid 1)" >> "$SALA_SIDECAR"; }   # a row of the pane map: the session is not retired
TT=$(date +%s)
flag() { local id=$1 total=$2 done=$3 srcv=$4; shift 4; set_create "$id" Recycle recycle "$total" "$done" 9.9.9 1 "src=$srcv" fscope=all hook=1 "$@"; }

echo "== 1. the rule: a flag clears when every pane it waits for has relaunched since its time"
reset_sets; mapped keepme
S1="$((TT-600))-101"; flag "$S1" 3 0 recycle out=a out=b out=c
pane a live $((TT-300)); pane b live $((TT-900)); pane c wait
set_sync >/dev/null
[ "$(set_val "$S1" done)" = 1 ] && [ "$(set_count "$S1" out)" = 2 ] && ! _set_out "$S1" a && ok "a (relaunched after the flag) is settled; b (before it) and c (nothing to read) stay out" || bad "S1: $(<"$SALA_SET_DIR/$S1")"
[ "$(nposts '1/3')" = 1 ] && ok "one 🔄 post for it, the flag being the job's newest" || bad "posts: $(<"$POSTS")"
sleep 1; [ "$(hooks)" = 0 ] && ok "a flag still waiting fires no hook call" || bad "early hook: $(<"$HOOKLOG")"
pane b live "$((TT-600))"; set_sync >/dev/null
_set_out "$S1" b && ok "a pane that started in the flag's own second has not relaunched for it" || bad "b settled by a start inside the flag's second"
pane b live $((TT-100)); pane c live $((TT-50)); set_sync >/dev/null
[ "$(set_val "$S1" closed)" = 1 ] && [ "$(set_val "$S1" done)" = 3 ] && [ "$(nposts 'set closed')" = 1 ] && ok "all three back: the flag clears, one ✅ post" || bad "S1: $(<"$SALA_SET_DIR/$S1")"
waitfor '[ "$(hooks)" -ge 1 ]' 20; sleep 1
[ "$(hooks)" = 1 ] && [ "$(hook_with "\"flag_at\": $((TT-600)), \"result\": \"ok\", \"skipped\": \[\]")" = 1 ] && [ "$(hook_with "\"started\": $((TT-600))")" = 1 ] && nobad \
    && ok "ONE hook call for the cleared flag: started = flag_at = its time, result ok, nothing skipped" || bad "hook: $(<"$HOOKLOG")"
set_sync >/dev/null; sleep 1; [ "$(hooks)" = 1 ] && [ "$(nposts 'set closed')" = 1 ] && ok "a closed flag is not judged again (no second post, no second call)" || bad "again: $(hooks) calls, $(nposts 'set closed') closes"

echo "== 1b. a pane spawned after the flag counts as relaunched; a start time that is 0 or missing never does, and nothing crashes"
reset_sets
S1b="$((TT-400))-111"; flag "$S1b" 3 0 recycle out=newborn out=zero out=blank
pane newborn live $((TT-100)); pane zero live 0; pane blank wait
set_sync >/dev/null 2>"$HOME/err.txt"
! _set_out "$S1b" newborn && _set_out "$S1b" zero && _set_out "$S1b" blank && [ ! -s "$HOME/err.txt" ] && ok "newborn counted; startedAt 0 and an unreadable pane stay out; no error output" || bad "S1b: $(<"$SALA_SET_DIR/$S1b") $(<"$HOME/err.txt")"

echo "== 1c. the master's pane is a pane like another"
reset_sets
S1c="$((TT-300))-121"; flag "$S1c" 2 1 recycle out=master
pane master live $((TT-20)); set_sync >/dev/null
[ "$(set_val "$S1c" closed)" = 1 ] && [ "$(set_val "$S1c" done)" = 2 ] && ok "the master back by its own new process clears the flag" || bad "S1c: $(<"$SALA_SET_DIR/$S1c")"

echo "== 2. a pane skipped by two recycles clears BOTH flags when it comes back: two ✅ posts, two hook calls, 🔄 only for the newest"
reset_sets
TA=$((TT-7200)); TB=$((TT-3600)); SA="$TA-201"; SB="$TB-202"
flag "$SA" 4 2 recycle out=p out=q; flag "$SB" 4 2 recycle out=p out=q; set_point recycle "$SB"
pane p live $((TA-100)); pane q live $((TA-100))
pane p live $((TT-60)); set_resolve "$SB" ok p "p relaunched on 9.9.9, 59 min after the recycle"
! _set_out "$SA" p && _set_out "$SA" q && [ "$(set_val "$SA" done)" = 3 ] && ok "p back: the OLDER flag drops it too (done 3/4), without its worker" || bad "SA: $(<"$SALA_SET_DIR/$SA")"
[ "$(nposts "$(set_label "$TB")")" = 1 ] && [ "$(nposts "$(set_label "$TA")")" = 0 ] && ok "one 🔄 post, the job's (newest) flag's; the older flag posts nothing while it waits" || bad "posts: $(<"$POSTS")"
pane q live $((TT-30)); set_resolve "$SB" ok q "q relaunched on 9.9.9, 60 min after the recycle"
[ "$(set_val "$SB" closed)" = 1 ] && [ "$(set_val "$SA" closed)" = 1 ] && [ "$(nposts '· 4/4 · set closed')" = 2 ] && ok "q back: both flags clear, a ✅ post each" || bad "SA/SB: $(<"$SALA_SET_DIR/$SA") / $(<"$SALA_SET_DIR/$SB"); $(<"$POSTS")"
waitfor '[ "$(hooks)" -ge 2 ]' 20; sleep 1
[ "$(hooks)" = 2 ] && [ "$(hook_with "\"flag_at\": $TA,")" = 1 ] && [ "$(hook_with "\"flag_at\": $TB,")" = 1 ] && [ "$(hook_with '"skipped": \[\]')" = 2 ] && nobad \
    && ok "two hook calls, one per flag, each with its own time and nothing skipped" || bad "hooks: $(<"$HOOKLOG")"

echo "== 3. retired and gone panes"
reset_sets; : > "$SALA_SIDECAR"; mapped lost1
S3="$((TT-500))-301"; flag "$S3" 4 0 recycle out=r1 out=lost1 out=s1 out=s2
pane r1 gone; pane lost1 gone; pane s1 live $((TT-10)); pane s2 live $((TT-10))
set_sync >/dev/null
[ "$(set_val "$S3" total)" = 3 ] && [ "$(set_count "$S3" out)" = 1 ] && _set_out "$S3" lost1 && [ "$(set_val "$S3" closed)" = 0 ] && ok "r1 (gone, not in the pane map: retired) does not count (N 4 → 3); lost1 (gone but still mapped) keeps the flag open" || bad "S3: $(<"$SALA_SET_DIR/$S3")"
[ -n "$(post 'r1')" ] && ok "the flag's post names r1" || bad "no post names r1: $(<"$POSTS")"
pane lost1 live $((TT-5)); set_sync >/dev/null
[ "$(set_val "$S3" closed)" = 1 ] && [ "$(set_val "$S3" done)" = 3 ] && [ "$(nposts '3/3 · set closed')" = 1 ] && ok "lost1 back: 3/3, closed" || bad "S3: $(<"$SALA_SET_DIR/$S3")"

echo "== 3b. a flag with no live panes at all closes"
reset_sets; : > "$SALA_SIDECAR"; mapped someoneelse
S3b="$((TT-400))-311"; flag "$S3b" 2 0 recycle out=g1 out=g2; pane g1 gone; pane g2 gone
set_sync >/dev/null; waitfor '[ "$(hooks)" -ge 1 ]' 20
[ "$(set_val "$S3b" closed)" = 1 ] && [ "$(set_val "$S3b" total)" = 0 ] && [ "$(nposts 'set closed')" = 1 ] && [ "$(hooks)" = 1 ] && ok "both retired: the flag closes (0/0), one post, one call" || bad "S3b: $(<"$SALA_SET_DIR/$S3b") $(<"$POSTS")"

echo "== 4. the job: a flag raised at 15/20 reads 0/20, the same job relaunches the 15 again, one pointer, 🔄 only for the newest flag"
reset_sets; : > "$SALA_SIDECAR"
TA=$((TT-3000)); TB=$((TT-1200)); SA="$TA-401"; SB="$TB-402"; SAs=(); SBs=(); PA=(); for i in $(seq 1 20); do SAs+=(); done
mapfile -t OUT10 < <(for i in $(seq 16 20); do echo "out=p$i"; done); mapfile -t OUT40 < <(for i in $(seq 1 20); do echo "out=p$i"; done)
flag "$SA" 20 15 auto "${OUT10[@]}"; set_point recycle "$SA"
for i in $(seq 1 15); do pane "p$i" live $((TA+60)); done; for i in $(seq 16 20); do pane "p$i" live $((TA-100)); done
[ "$(set_val "$SA" done)/$(set_val "$SA" total)" = 15/20 ] && ok "the job stands at 15/20 against the first flag" || bad "SA: $(set_val "$SA" done)/$(set_val "$SA" total)"
flag "$SB" 20 0 auto "${OUT40[@]}"; set_point recycle "$SB"      # a new flag: the sweep of the SAME job opens it, nothing relaunched since its time
set_sync >/dev/null
[ "$(set_val "$SB" done)/$(set_val "$SB" total)" = 0/20 ] && [ "$(set_count "$SB" out)" = 20 ] && ok "the counter reads 0/20 against the newest flag: the 15 relaunched before it are out again" || bad "SB: $(set_val "$SB" done)/$(set_val "$SB" total) out $(set_count "$SB" out)"
set_superseded "$SA" && ! set_superseded "$SB" && [ "$(<"$(_set_scope_file recycle)")" = "$SB" ] && [ "$(ls "$SALA_SET_DIR"/current.* | wc -l)" = 1 ] && ok "one job: the pointer names the newest flag only, the older flag is superseded (its worker stops at its next tick)" || bad "pointer: $(<"$(_set_scope_file recycle)")"
mapfile -t ARGS < <(for i in $(seq 1 15); do pane "p$i" live $((TB+60)); printf '%s\n%s\n%s\n' ok "p$i" "p$i relaunched again"; done)
set_resolve "$SB" "${ARGS[@]}"
[ "$(set_val "$SB" done)" = 15 ] && [ "$(nposts '15/20')" = 1 ] && [ "$(nposts "$(set_label "$TA")")" = 0 ] && ok "the 15 relaunched again: 🔄 15/20 under the newest flag, nothing under the older one" || bad "posts: $(grep -c . "$POSTS") $(post '15/20' | head -3)"
[ "$(set_val "$SA" closed)" = 0 ] && ok "the older flag still waits for p16..p20" || bad "SA closed early"
mapfile -t ARGS < <(for i in $(seq 16 20); do pane "p$i" live $((TB+120)); printf '%s\n%s\n%s\n' ok "p$i" "p$i relaunched"; done)
set_resolve "$SB" "${ARGS[@]}"
[ "$(set_val "$SB" closed)" = 1 ] && [ "$(set_val "$SA" closed)" = 1 ] && [ "$(set_val "$SA" done)" = 20 ] && [ "$(nposts '20/20 · set closed')" = 2 ] && ok "the last five back: BOTH flags clear at 20/20, a ✅ post each" || bad "SA/SB: $(<"$SALA_SET_DIR/$SA" | head -12 | paste -sd' ' -)"
waitfor '[ "$(hooks)" -ge 2 ]' 20; sleep 1; [ "$(hooks)" = 2 ] && nobad && ok "two hook calls, one per flag" || bad "hooks: $(<"$HOOKLOG")"

echo "== 4b. the deferred list keeps one row per pane, repointed at the newest flag"
reset_sets
printf '%s\t%s\t%s\t%s\t%s\t%s\n' pq "$(date +%s)" "background work is running" 0 1 oldset-1 > "$SALA_DEFERRED"
defer_add pq "again" 1 newset-2
[ "$(grep -c . "$SALA_DEFERRED")" = 1 ] && awk -F'\t' '$1 == "pq" && $6 == "newset-2" && $3 == "background work is running" {f=1} END {exit !f}' "$SALA_DEFERRED" && ok "still one row, its why kept, its set id the newest flag's" || bad "deferred: $(<"$SALA_DEFERRED")"
rm -f "$SALA_DEFERRED"

echo "== 5. scopes: a revive/lane/model flag is one pane; an all-panes flag needs every live pane"
reset_sets
SR="$((TT-500))-501"; SL="$((TT-400))-502"
set_create "$SR" Revive only.x 1 0 9.9.9 1 out=x src=lane fscope=x; flag "$SL" 2 0 recycle out=y out=z
pane x live $((TT-1000)); pane y live $((TT-1000)); pane z live $((TT-1000)); set_sync >/dev/null
pane x live $((TT-10)); set_sync >/dev/null
[ "$(set_val "$SR" closed)" = 1 ] && [ "$(set_count "$SL" out)" = 2 ] && ok "x relaunched: the one-pane flag clears on that pane alone; the all-panes flag is untouched" || bad "SR/SL: $(<"$SALA_SET_DIR/$SR") / $(<"$SALA_SET_DIR/$SL")"
sleep 1; [ "$(hooks)" = 0 ] && ok "a Revive flag never fires the hook" || bad "hook: $(<"$HOOKLOG")"
pane y live $((TT-8)); set_sync >/dev/null; [ "$(set_val "$SL" closed)" = 0 ] && ok "y back, z not: the all-panes flag stays open" || bad "SL closed on y alone"
pane z live $((TT-6)); set_sync >/dev/null; waitfor '[ "$(hooks)" -ge 1 ]' 20
[ "$(set_val "$SL" closed)" = 1 ] && [ "$(hooks)" = 1 ] && ok "z back: the all-panes flag clears (one call)" || bad "SL: $(<"$SALA_SET_DIR/$SL")"

echo "== 6. the hook: a partial clear (a pane held past the later list's limit), strict fake of the client"
reset_sets
SP="$((TT-4000))-601"; flag "$SP" 3 1 recycle out=u out=v; pane u live $((TT-5000)); pane v live $((TT-5000))
set_giveup_pane u "held for 3 h by background work, so this recycle stopped waiting for it"
sleep 1; [ "$(set_val "$SP" closed)" = 0 ] && [ "$(hooks)" = 0 ] && ok "u given up, v still out: the flag is open, no call" || bad "SP: $(<"$SALA_SET_DIR/$SP"); $(<"$HOOKLOG")"
set_giveup_pane v "held for 3 h by a busy turn, so this recycle stopped waiting for it"
waitfor '[ "$(hooks)" -ge 1 ]' 20; sleep 1
[ "$(set_val "$SP" closed)" = 1 ] && [ "$(nposts 'closed at 1/3')" = 1 ] && ok "v given up too: the flag closes \"at 1/3\" with the given-up wording, once" || bad "SP: $(<"$SALA_SET_DIR/$SP"); $(<"$POSTS")"
[ "$(hooks)" = 1 ] && [ "$(hook_with "\"flag_at\": $((TT-4000)),")" = 1 ] && [ "$(hook_with '"result": "partial", "skipped": \["u", "v"\]')" = 1 ] && nobad \
    && ok "ONE call: partial, the two given-up panes as skipped, flag_at = started = the flag's time" || bad "hook: $(<"$HOOKLOG")"
set_giveup_pane u "again"; sleep 1; [ "$(hooks)" = 1 ] && ok "a closed flag takes no second give-up and fires no second call" || bad "hooks: $(<"$HOOKLOG")"
reset_sets
SC="$((TT-300))-611"; set_create "$SC" Recycle recycle 2 2 9.9.9 0 src=recycle fscope=all
set_report "$SC"; set_recycled "$SC" "$RLOG" "${SC%%-*}"; set_recycled "$SC" "$RLOG" "${SC%%-*}"
waitfor '[ "$(hooks)" -ge 1 ]' 20; sleep 1
[ "$(set_val "$SC" closed)" = 1 ] && [ "$(hooks)" = 1 ] && [ "$(hook_with "\"flag_at\": ${SC%%-*},")" = 1 ] && nobad && ok "a clean recycle (closed by its first post): the driver's end fires its one call, once" || bad "hooks: $(<"$HOOKLOG")"
: > "$HOOKLOG"; set_recycled "no-such-set" "$RLOG" 1234 a b; waitfor '[ "$(hooks)" -ge 1 ]' 20
[ "$(hook_with '"flag_at": 1234,')" = 1 ] && [ "$(hook_with '"skipped": \["a", "b"\]')" = 1 ] && nobad && ok "without a set (a sweep that died) the driver's own skipped list stands in, as before" || bad "hooks: $(<"$HOOKLOG")"

echo "== 7. the old-format sets at upgrade: one reconcile, a dry run first"
reset_sets; : > "$SALA_SIDECAR"; rm -f "$SALA_SET_DIR/.reconciled"
OLD="$((TT-90000))-701"; ANC="$((TT-200000))-702"; BUSY="$((TT-3000))-703"
for id in "$OLD" "$ANC" "$BUSY"; do printf 'id=%s\nkind=Recycle\nscope=recycle\nt0=%s\nlabel=%s\nver=2.1.312\ntotal=3\nclosed=0\ncreated=%s\nreported=1\nhook=1\ndone=1\n' "$id" "${id%%-*}" "$(set_label "${id%%-*}")" "${id%%-*}" > "$SALA_SET_DIR/$id"; done
printf 'out=ax\nout=ay\n' >> "$SALA_SET_DIR/$OLD"; printf 'out=az\n' >> "$SALA_SET_DIR/$ANC"; printf 'out=bz\n' >> "$SALA_SET_DIR/$BUSY"
for s in ax ay az; do pane $s live $((TT-100)); done; pane bz live $((TT-9000))
snap() { cat "$SALA_SET_DIR"/[0-9]*-[0-9]* "$POSTS" "$HOOKLOG" 2>/dev/null | cksum; ls "$SALA_SET_DIR" | cksum; }
b=$(snap); d=$(set_sync --dry-run); a=$(snap)
[ "$a" = "$b" ] && [ ! -e "$SALA_SET_DIR/.reconciled" ] && ok "the dry run changes nothing (sets, posts, calls, marker)" || bad "dry run changed something"
[[ $d == *"$OLD"* ]] && [[ $d == *"$ANC"* ]] && [[ $d != *"$BUSY"* ]] && ok "and names the two it would close, not the one whose pane has not relaunched" || bad "dry run said: $d"
set_sync >/dev/null; waitfor '[ "$(hooks)" -ge 1 ]' 20; sleep 1
[ "$(set_val "$OLD" closed)" = 1 ] && [ "$(set_val "$ANC" closed)" = 1 ] && [ "$(set_val "$BUSY" closed)" = 0 ] && [ -e "$SALA_SET_DIR/.reconciled" ] && ok "reconcile: both old flags closed by the rule, the one with a live pane that has not relaunched stays open" || bad "after: $(set_val "$OLD" closed)$(set_val "$ANC" closed)$(set_val "$BUSY" closed)"
[ "$(nposts "$(set_label "${OLD%%-*}")")" = 1 ] && [ "$(nposts "$(set_label "${ANC%%-*}")")" = 0 ] && ok "the 25 h old one posts its ✅; the 55 h old one (past SALA_SET_QUIET_AFTER) closes without a post" || bad "posts: $(<"$POSTS")"
[ "$(hooks)" = 1 ] && [ "$(hook_with "\"flag_at\": ${OLD%%-*},")" = 1 ] && ok "and only the first fires its hook call" || bad "hooks: $(<"$HOOKLOG")"
grep -q "settled Recycle .* ($OLD)" "$RLOG" && grep -q "settled Recycle .* ($ANC)" "$RLOG" && ok "what it closed is in the log" || bad "log: $(grep 'sets:' "$RLOG")"
: > "$POSTS"; set_sync >/dev/null; [ ! -s "$POSTS" ] && ok "a second pass changes nothing" || bad "second pass posted: $(<"$POSTS")"

echo "== 8. the gate (a fake clock): gather flags, reset once"
reset_sets; : > "$SALA_SIDECAR"
export SALA_RECYCLE_GATHER=600 SALA_RECYCLE_GATHER_MAX=1800
CLOCK=$TT; _now_r() { printf -v "$1" '%s' "$CLOCK"; }
SJ="$((TT-1300))-801"; flag "$SJ" 2 1 auto out=jp; pane jp live $((TT-9000)); set_point recycle "$SJ"
gate() { CLOCK=$1; shift; recycle_job_gate "$@"; }
out=$(gate $((TT)) auto k1); rc=$?
[ "$rc" = 1 ] && [[ $out == *"resets at"* ]] && ok "an unfinished job: the first flag is gathered, and the line says when it resets" || bad "gate: rc=$rc $out"
gate $((TT+180)) auto k1 k2 >/dev/null; r1=$?; gate $((TT+360)) auto k1 k2 k3 >/dev/null; r2=$?; gate $((TT+360+599)) auto k1 k2 k3 >/dev/null; r3=$?
[ "$r1" = 1 ] && [ "$r2" = 1 ] && [ "$r3" = 1 ] && ok "flags 3 min apart keep gathering (the clock restarts at each new flag)" || bad "rc: $r1 $r2 $r3"
gate $((TT+360+600)) auto k1 k2 k3 >/dev/null; r4=$?
[ "$r4" = 0 ] && ok "10 min with no new flag: the job resets (start now)" || bad "no reset at 10 min of silence (rc $r4)"
gather_clear
keys=c0; gate $TT auto $keys >/dev/null; for i in 1 2 3 4 5; do keys="$keys c$i"; gate $((TT+300*i)) auto $keys >/dev/null; done
gate $((TT+1799)) auto $keys >/dev/null; r5=$?; gate $((TT+1800)) auto $keys >/dev/null; r6=$?
[ "$r5" = 1 ] && [ "$r6" = 0 ] && ok "flags every 5 min never let it settle: the 30 min cap after the first resets it" || bad "cap: $r5 $r6"
gather_clear
gate $TT op-recycle k1 >/dev/null && ok "an op recycle (Rowan's words) waits for nothing" || bad "op-recycle gathered"
SALA_RECYCLE_GATHER=0 gate $TT auto k1 >/dev/null && SALA_RECYCLE_GATHER_MAX=0 gate $TT auto k1 >/dev/null && ok "a knob at 0 turns the wait off" || bad "a knob at 0 still waited"
gather_clear; : > "$POSTS"; gate $TT auto k1 >/dev/null; gather_note "line one"; gather_note "line one"
[ "$(nposts "line one")" = 1 ] && ok "one short post per gathering" || bad "posts: $(<"$POSTS")"
_set_put "$SJ" closed 1; gate $((TT+5)) auto k9 >/dev/null && [ -z "$(_job_get gather_first)" ] && ok "no unfinished job: a flag starts it at once, and the gathering is forgotten" || bad "gate with a finished job gathered"
. "$ROOT/lib/common.sh"   # the real _now_r and _set_pane_read again

echo "== 9. the rest: startedAt, a pane that relaunched less than SALA_RECYCLE_REST ago"
reset_sets
mkreg() { printf '{"pid":%s,"startedAt":%s000,"status":"idle"}\n' "$1" "$2" > "$HOME/.claude/sessions/$1.json"; }
mkreg 7771 $((TT-600)); mkreg 7772 $((TT-1800)); printf '{"pid":7773,"status":"idle"}\n' > "$HOME/.claude/sessions/7773.json"
# The pane started TT-600 s ago, so 1200 s were left AT TT; recycle_rest_left reads the real clock, and on a loaded runner minutes
# can pass between TT (taken at the top of this suite) and here (seen in CI: 1086 left). The bound follows the clock read
# right before and right after the call instead of a fixed window: 1200 - (seconds since TT) must bracket the answer.
b=$(date +%s); l=$(SALA_RECYCLE_REST=1800 recycle_rest_left 7771); a=$(date +%s)
[ "${l:-0}" -ge $((1200 - (a - TT))) ] && [ "$l" -le $((1200 - (b - TT))) ] && ok "a pane that started 10 min ago has about 20 min of rest left" || bad "left: '$l' (expected $((1200 - (a - TT))) to $((1200 - (b - TT))))"
[ -z "$(SALA_RECYCLE_REST=1800 recycle_rest_left 7772)" ] && [ -z "$(SALA_RECYCLE_REST=1800 recycle_rest_left 7773)" ] && [ -z "$(SALA_RECYCLE_REST=0 recycle_rest_left 7771)" ] && ok "none left at 30 min, none for a row without startedAt, none with the knob at 0" || bad "rest of the others"
[ "$(SALA_FLAG_SRC=lane flag_src)" = lane ] && [ "$(flag_src)" = revive ] && [ "$(SALA_RECYCLE=1 flag_src)" = recycle ] && [ "$(SALA_RECYCLE=1 SALA_RELAUNCH_KIND=auto flag_src)" = auto ] && [ "$(SALA_RECYCLE=1 SALA_FLAG_SRC=op-recycle flag_src)" = op-recycle ] && ok "flag_src: revive, lane, recycle, auto, op-recycle" || bad "flag_src"
[ "$(pane_last_relaunch nosuchsession)" = "" ] && ok "pane_last_relaunch reads nothing for a session that is not there" || bad "pane_last_relaunch"

if [ "${FLAGS_SYNTH_ONLY:-0}" = 1 ]; then   # sections 10-11 start fake claudes in a private tmux and kill them (kill_fake_claude): a local run on a box with real panes can stop here
    echo "(sections 10-11, the real tmux part, skipped: FLAGS_SYNTH_ONLY=1)"; [ "$fail" = 0 ] && { echo "PASS"; exit 0; }; echo "FAIL"; exit 1
fi
echo "== 10. the real read of a pane, and the rest through a real recycle"
RA=$(uuid 41); RB=$(uuid 42)
mk ra "$RA"; mk rb "$RB" -e FAKE_STARTED_AT=$((TT-3600)); fake_up ra rb
r=$(_set_pane_read sala-test-ra); read -r st sa v <<< "$r"
[ "$st" = live ] && [ "$((sa/1000))" -ge $((TT-5)) ] && [ "$v" = 9.9.9 ] && ok "_set_pane_read: live, startedAt from the registry row, the version" || bad "read: $r"
r=$(_set_pane_read sala-test-rb); read -r st sa v <<< "$r"; [ "$((sa/1000))" = $((TT-3600)) ] && ok "and the row's own start (an hour old)" || bad "read rb: $r"
[ "$(_set_pane_read sala-test-nope)" = gone ] && ok "no such session: gone" || bad "gone: $(_set_pane_read sala-test-nope)"
$T new-session -d -s sala-test-bare -c "$HOME"; [ "$(_set_pane_read sala-test-bare)" = wait ] && ok "a session with no claude in it (between /exit and the resume): wait, never gone" || bad "bare: $(_set_pane_read sala-test-bare)"
$T kill-session -t sala-test-bare
RBP=$(cpid rb); cp "$HOME/.claude/sessions/$RBP.json" "$HOME/row.bak"; sed -i 's/"startedAt":[0-9]*,//' "$HOME/.claude/sessions/$RBP.json"
[ "$(_set_pane_read sala-test-rb)" = wait ] && ok "a row without startedAt: wait, no error" || bad "no startedAt: $(_set_pane_read sala-test-rb)"; cp "$HOME/row.bak" "$HOME/.claude/sessions/$RBP.json"
$T kill-server; sleep 1; [ "$(_set_pane_read sala-test-ra)" = wait ] && ok "tmux not answering (a reboot): wait, so nothing is judged gone" || bad "no server: $(_set_pane_read sala-test-ra)"
tmux_socket_rm; kill_fake_claude "$FAKEBIN"; sleep 1

echo "== 10b. a routine recycle skips a pane that relaunched 10 min ago and relaunches it once its rest is up; an op recycle and a knob at 0 do not wait"
reset_sets; : > "$FAKE_LOG"; rm -f "$HOME"/.claude/sessions/*.json
export SALA_RETRY_EVERY=2 SALA_RETRY_WINDOW=120
mk ra "$RA"; mk rb "$RB" -e FAKE_STARTED_AT=$((TT-3600)); fake_up ra rb
export SALA_RECYCLE_REST=9
out=$("$SALA" recycle --force 2>&1); echo "$out" | grep -q 'recycle started' || bad "recycle did not start: $out"
waitfor '[ -n "$(post "resting until")" ]' 120 && ok "the left-behind post names ra as resting until a time" || bad "no rest post: $(<"$POSTS"; tail -20 "$RLOG")"
[ "$(starts "$RB")" = 2 ] && ok "rb (an hour old) was relaunched at once" || bad "rb starts: $(starts "$RB")"
[ "$(starts "$RA")" = 1 ] && ok "ra (started seconds ago) was not relaunched by the sweep" || bad "ra starts: $(starts "$RA")"
S10=$(newest_set); [ "$(set_val "$S10" src)" = recycle ] && [ "$(set_val "$S10" fscope)" = all ] && ok "the flag record: src recycle, scope all" || bad "set: $(<"$SALA_SET_DIR/$S10")"
waitfor '[ "$(starts "$RA")" = 2 ]' 160 && ok "its rest over, the retry worker relaunched it" || bad "ra never relaunched: $(tail -12 "$RLOG")"
waitfor '[ "$(set_val "$S10" closed)" = 1 ]' 60 && [ "$(nposts 'set closed')" = 1 ] && ok "the flag cleared: one ✅ post" || bad "set: $(<"$SALA_SET_DIR/$S10")"
waitfor '[ "$(hooks)" -ge 1 ]' 30; sleep 1; [ "$(hooks)" = 1 ] && nobad && ok "one hook call for the flag" || bad "hooks: $(<"$HOOKLOG")"
wait_lock; waitfor '[ "$(workers)" = 0 ]' 40 || bad "the retry worker did not finish"
: > "$POSTS"; : > "$HOOKLOG"
export SALA_RECYCLE_REST=0; "$SALA" recycle --force >/dev/null 2>&1; wait_lock
waitfor '[ "$(hooks)" -ge 1 ]' 40
waitfor '[ "$(starts "$RA")" = 3 ]' 80 && [ -z "$(post 'resting until')" ] && ok "SALA_RECYCLE_REST=0: a pane that relaunched seconds ago is relaunched again, no wait" || bad "knob 0: ra starts $(starts "$RA"); $(<"$POSTS")"
wait_lock; waitfor '[ "$(workers)" = 0 ]' 40

echo "== 10c. two flags, one busy pane: both clear when it is finally relaunched (an op recycle, with no rest, is the second)"
reset_sets; : > "$FAKE_LOG"; rm -f "$HOME"/.claude/sessions/*.json
$T kill-server 2>/dev/null; sleep 1; tmux_socket_rm; kill_fake_claude "$FAKEBIN"
RC=$(uuid 43); RD=$(uuid 44)
mk rc "$RC"; mk rd "$RD"; draft rc; draft rd; fake_up rc rd
export SALA_RECYCLE_REST=600 SALA_RETRY_EVERY=3 SALA_RETRY_WINDOW=300
"$SALA" recycle --force >/dev/null 2>&1; waitfor '[ -n "$(post "· 0/2 relaunched")" ]' 120 && ok "the first (routine) recycle leaves both panes: they hold unsent text" || bad "no first post: $(<"$POSTS")"
wait_lock; S1A=$(newest_set); sleep 1
SALA_FLAG_SRC=op-recycle "$SALA" recycle --force >/dev/null 2>&1; waitfor '[ "$(set_count "$(newest_set)" out)" = 2 ] && [ "$(newest_set)" != "$S1A" ]' 120 && ok "a second recycle (from Rowan's words) opens a second flag" || bad "no second set: $(ls "$SALA_SET_DIR")"
wait_lock; S1B=$(newest_set)
[ "$(set_val "$S1B" src)" = op-recycle ] && set_superseded "$S1A" && ok "the second flag has source op-recycle and took the job over: one job, the first flag superseded" || bad "S1B: $(<"$SALA_SET_DIR/$S1B")"
undraft rc; undraft rd
waitfor '[ "$(set_val "$S1A" closed)" = 1 ] && [ "$(set_val "$S1B" closed)" = 1 ]' 200 && ok "both panes relaunched: BOTH flags are closed" || bad "A: $(<"$SALA_SET_DIR/$S1A") B: $(<"$SALA_SET_DIR/$S1B"); $(tail -15 "$RLOG")"
[ "$(nposts 'set closed')" = 2 ] && ok "a ✅ post each" || bad "closed posts: $(nposts 'set closed'): $(<"$POSTS")"
waitfor '[ "$(hooks)" -ge 2 ]' 40; sleep 1; [ "$(hooks)" = 2 ] && [ "$(hook_with "\"flag_at\": ${S1A%%-*},")" = 1 ] && [ "$(hook_with "\"flag_at\": ${S1B%%-*},")" = 1 ] && nobad && ok "two hook calls, one per flag" || bad "hooks: $(<"$HOOKLOG")"
wait_lock; waitfor '[ "$(workers)" = 0 ]' 60 || bad "a retry worker is still running (one job, one worker, finishing)"

echo "== 10d. a lane flag is one pane: src lane, scope that pane, cleared by it alone"
reset_sets; : > "$FAKE_LOG"; rm -f "$HOME"/.claude/sessions/*.json
$T kill-server 2>/dev/null; sleep 1; tmux_socket_rm; kill_fake_claude "$FAKEBIN"
RE=$(uuid 45); mk re "$RE"; draft re; fake_up re
export SALA_RECYCLE_REST=0
SALA_FLAG_SRC=lane "$SALA" revive --force --only sala-test-re >/dev/null 2>&1
S10d=$(newest_set)
[ "$(set_val "$S10d" kind)" = Revive ] && [ "$(set_val "$S10d" src)" = lane ] && [ "$(set_val "$S10d" fscope)" = sala-test-re ] && ok "the flag: Revive, src lane, scope that one pane" || bad "set: $(<"$SALA_SET_DIR/$S10d")"
undraft re; waitfor '[ "$(set_val "$S10d" closed)" = 1 ]' 160 && ok "cleared when that pane relaunched" || bad "set: $(<"$SALA_SET_DIR/$S10d"); $(tail -8 "$RLOG")"
sleep 1; [ "$(hooks)" = 0 ] && ok "no hook call for a revive flag" || bad "hooks: $(<"$HOOKLOG")"
wait_lock; waitfor '[ "$(workers)" = 0 ]' 40

echo "== 11. watch gathers a request behind an unfinished job, then resets once"
reset_sets; rm -f "$HOME"/.claude/sessions/*.json; : > "$SALA_SIDECAR"; : > "$LAUNCHES"
$T kill-server 2>/dev/null; sleep 1; tmux_socket_rm; kill_fake_claude "$FAKEBIN"
RM=$(uuid 46); mk wm "$RM"; fake_up wm; touch -d "@$((TT-3600))" "$HOME/.claude/projects/x/$RM.jsonl" 2>/dev/null
SW="$(date +%s)-901"; set_create "$SW" Recycle recycle 2 1 9.9.9 1 out=ghostpane src=auto fscope=all; set_point recycle "$SW"
export SALA_AUTO_RECYCLE=on SALA_RECYCLE_GATHER=4 SALA_RECYCLE_GATHER_MAX=40 SALA_RECYCLE_REST=0
WLG="$HOME/.claude/salamander-watch.log"
watchrun() { SALA_MASTER=sala-test-wm "$SALA" watch >/dev/null 2>&1; }
launches() { grep -c 'recycle --update --force' "$LAUNCHES" 2>/dev/null; }
"$SALA" recycle --when-idle --from t "first request" >/dev/null; watchrun
[ "$(launches)" = 0 ] && grep -q 'auto-recycle: .*waiting for flags to settle' "$WLG" && ok "watch: the job is unfinished, so the request is gathered (not launched), the log says when" || bad "launched $(launches); $(tail -5 "$WLG")"
[ "$(nposts 'waiting for flags to settle')" = 1 ] && ok "one short 🔄 post for the gathering" || bad "posts: $(<"$POSTS")"
G1=$(_job_get gather_last); nap 1.2; "$SALA" recycle --when-idle --from t "second request" >/dev/null; watchrun
G2=$(_job_get gather_last)
[ "$(launches)" = 0 ] && [ -n "$G1" ] && [ "$G2" -gt "$G1" ] && ok "a second request: the clock restarted (gather_last moved), nothing launched" || bad "launched $(launches), gather_last $G1 -> $G2: $(<"$LAUNCHES")"
[ "$(nposts 'waiting for flags to settle')" = 1 ] && ok "and no second post" || bad "posts: $(nposts 'waiting for flags to settle')"
nap 4.5; watchrun
[ "$(launches)" = 1 ] && ok "4 s with no new flag: ONE job started for both requests" || bad "launches: $(<"$LAUNCHES")"
[ -z "$(ls "$SALA_STATE_DIR/recycle-requests" 2>/dev/null)" ] && ok "the two requests are served and cleared" || bad "requests left"
[ -z "$(_job_get gather_first)" ] && ok "the gathering is forgotten once the job starts" || bad "gather state left: $(<"$SALA_SET_DIR/job.recycle")"
d=$("$SALA" watch --sets --dry-run 2>&1); [ $? = 0 ] && ok "watch --sets --dry-run runs" || bad "watch --sets --dry-run: $d"

[ "$fail" = 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
