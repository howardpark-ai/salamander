#!/usr/bin/env bash
# Recycle sets (common.sh, "recycle sets"): every notice after a recycle's first post names that
# recycle by its label and counts n/N. What is checked is the set's state and that its posts go out, never their wording
# The set state under concurrent writers; a real recycle leaving two panes behind, both back in one retry pass →
# the set closed; a give-up (a pane gone) → "closed at n/N" exactly once and never "set closed"; the master's own pane:
# tests/sets-master.sh (split out, so the two run side by side); two workers on one set (the self-worker case)
# both keep running and the count covers both; a newer recycle stops a worker; a deferred pane keeps its set open until
# watch relaunches it; a pane that said ready but is held by background shells only (registry state 'shell') goes on the
# deferred list at once, and a pane still pending when the retry window ends is deferred, not given up. The
# post-recycle command through the set: stubbed to a file of one "<started>|<skipped>|<flag_at>" line per call, it fires ONCE PER CLEARED
# FLAG, with the flag's time as started and flag_at and the panes not got back as skipped (the flag rule itself, and a strict fake of the client: tests/flags.sh); never while the flag is open, for a set the driver has not reported, or a stopped worker.
# A 🔄 post names every pane still out, one bullet each with its reason from the first post, and the given-up ones (capped at 12, then
# "…and N more"); the ✅ and ⚠️ closing posts are unchanged.
# Slack stubbed to a file (SALA_NOTIFY_CMD). Isolated HOME, a private tmux socket, the compiled fake claude
# (tests/fake-claude.c). Usage: bash tests/sets.sh   (exit 0 = pass)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_SET SALA_SET_SELF SALA_POST_RECYCLE_CMD SALA_RECYCLE SALA_RETRY_WORKER
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, tmux_socket_rm
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
as_op_unit   # no master: the guarded verbs this suite runs itself stand for the queue's runner (tests/lib.sh, 5)
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$HOME/.local/share/claude/versions/9.9.9" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
ln -s "$HOME/.local/share/claude/versions/9.9.9" "$HOME/.local/bin/claude"   # as the CLI installs it: the launcher target's name is the version
printf '#!/bin/sh\necho "$*" >> "%s/systemd-run.txt"\n' "$HOME" > "$HOME/.local/bin/systemd-run"; chmod +x "$HOME/.local/bin/systemd-run"   # watch launches nothing
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="{ cat; echo '%%'; } >> $POSTS"   # one post per record, '%%' between them
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off
PR="$HOME/post-recycle.txt"   # the post-recycle command, stubbed: one "<started>|<skipped>|<flag_at>" line per call - ONE PER CLEARED FLAG (tests/flags.sh checks it against a strict fake of the client)
export SALA_POST_RECYCLE_CMD="printf '%s|%s|%s\n' \"\$SALA_RECYCLE_STARTED\" \"\$SALA_RECYCLE_SKIPPED\" \"\$SALA_RECYCLE_FLAG_AT\" >> $PR"
# (the shell's own reads, no grep/sed/cut/sort per call)
reports() { local n=0 l; if [ -s "$PR" ]; then while IFS= read -r l || [ -n "$l" ]; do [ -n "$l" ] && n=$((n+1)); done < "$PR"; fi; echo "$n"; }
report() { local i=0 l; [ -r "$PR" ] || return 0; while IFS= read -r l || [ -n "$l" ]; do i=$((i+1)); [ "$i" = "$1" ] && { printf '%s\n' "$l"; return 0; }; done < "$PR"; }   # the n-th call: "<started>|<skipped>"
skipped() {   # its skipped list, as a sorted set
    local l f w i j out=() t; l=$(report "$1"); f=${l#*|}; [[ $l == *'|'* ]] || f=$l; f=${f%%|*}
    for w in $f; do
        i=${#out[@]}; out[i]=$w
        while [ "$i" -gt 0 ] && [[ ${out[i-1]} > ${out[i]} ]]; do t=${out[i-1]}; out[i-1]=${out[i]}; out[i]=$t; i=$((i-1)); done
    done
    echo "${out[*]-}"
}
started() { local l; l=$(report "$1"); echo "${l%%|*}"; }
flagat() { local l; l=$(report "$1"); echo "${l##*|}"; }   # the third field: SALA_RECYCLE_FLAG_AT, always the same epoch as started
SALA="$ROOT/bin/salamander"; SOCK="sala-sets-$$"; T="tmux -L $SOCK -f /dev/null"; RLOG="$HOME/.claude/salamander-revive.log"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's (common.sh, on_fleet_server)
cleanup() {
    local f p; for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    for p in $(pgrep -x claude); do [ "$HOME/.local/share/claude/versions/9.9.9" -ef "/proc/$p/exe" ] && kill -9 "$p" 2>/dev/null; done
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux    # literal socket: the children run set -u
. "$ROOT/lib/common.sh"
show() { sed 's/^/      | /' "$POSTS" 2>/dev/null | grep -v '| %%$'; }
wait_lock() { lock_wait "$HOME/.claude/salamander-recycle.lock" 60; }
# exit-empty off once a session has started the server: a section ending with its last kill-session must not empty it, or the next
# new-session races the server going away (the same failure as tests/sets-master.sh). cleanup kills it.
mk() { local n="$1" u="$2"; shift 2; $T new-session -d -s "sala-test-$n" -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="$n" -e FAKE_LOG="$FAKE_LOG" "$@"; $T set -s exit-empty off; $T send-keys -t "sala-test-$n" 'claude' Enter; }
draft() {  # typed, never submitted: a transient skip (once the fake is up; until the text shows in the pane)
    fake_up "$1"; $T send-keys -t "sala-test-$1" -l 'half a thought'; waitfor "$T capture-pane -p -t sala-test-$1 | grep -q 'half a thought'" 20; }
undraft() { $T send-keys -t "sala-test-$1" Enter; }                         # submitted: the composer is empty again
workers() { local f n=0; for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill -0 "$(<"$f")" 2>/dev/null && n=$((n+1)); done; echo $n; }

echo "== the set state: one file per set, every write under one lock"
S1="$(date +%s)-111"; set_create "$S1" Recycle recycle 12 2 9.9.9 1 $(for i in $(seq 1 10); do echo "out=p$i"; done)
for i in $(seq 1 10); do set_resolve "$S1" ok "p$i" "p$i relaunched on 9.9.9" & done; wait
[ "$(set_val "$S1" done)" = 12 ] && [ "$(set_count "$S1" out)" = 0 ] && ok "10 parallel closures: done 12/12, nothing outstanding (no write lost)" || bad "parallel closures: done=$(set_val "$S1" done) out=$(set_count "$S1" out)"
[ "$(nposts '· set closed')" = 1 ] && ok "exactly one of them says \"set closed\"" || bad "set closed posted $(nposts '· set closed') times"; show
set_resolve "$S1" ok p3 "p3 again"; [ "$(nposts 'p3 again')" = 0 ] && ok "a pane already settled is ignored (no second post)" || bad "p3 posted twice"
sleep 1; [ "$(reports)" = 0 ] && ok "a set the driver has not reported through (no hook=1) fires no post-recycle command" || bad "post-recycle calls: $(<"$PR")"
set_point recycle "$S1"; set_superseded "$S1" && bad "superseded by itself" || ok "the current set is not superseded"
set_point recycle "$(( ${S1%%-*} + 5 ))-222"; set_superseded "$S1" && ok "a newer current set supersedes it" || bad "newer set did not supersede"
set_point recycle "$(( ${S1%%-*} - 5 ))-333"; set_superseded "$S1" && bad "an older pointer superseded it" || ok "an older pointer does not"
rm -f "$(_set_scope_file recycle)"   # the sets below carry back-dated ids: a pointer left here would read as a newer flag, and a superseded flag posts no 🔄
: > "$POSTS"

echo "== a 🔄 post names every pane still out, one bullet each, with its reason; ✅ and ⚠️ posts stay as they were"
# the set's own record, no pane: skip= is the first post's left-behind bullet, out= a pane still outstanding, gave= one given up
BUSY="registry says 'busy' (a turn or a dialog is running)"; DLG="a terminal prompt is showing — dismiss it (attach) and rerun"
posts_plain() { grep -v '^%%$' "$POSTS" 2>/dev/null; }   # the posts as sent, without the record separator
FB="$(date +%s)"; HEAD() { echo "🔄 *Recycle $(set_label "$1") · $2*"; }
S5="$((FB-101))-501"; set_create "$S5" Recycle recycle 4 1 9.9.9 1 out=pa out=pb out=pc out=pd "skip=pa: $BUSY" "skip=pb: $DLG" "skip=pd: $BUSY"
: > "$POSTS"; set_resolve "$S5" ok pd "pd relaunched on 9.9.9, 12 min after the recycle"
want="$(HEAD "${S5%%-*}" 2/4)
    • pd relaunched on 9.9.9, 12 min after the recycle
    • pa: still waiting, $BUSY
    • pb: still waiting, $DLG
    • pc: still waiting, not relaunched yet"
[ "$(posts_plain)" = "$want" ] && ok "pending: a busy pane, a dialog pane, and one the first post named no reason for (the master's), each its own bullet after the pane just back" || bad "pending post: $(show)"
S6="$((FB-102))-502"; set_create "$S6" Recycle recycle 3 0 9.9.9 1 out=pa out=pb gave="pg: its pane is gone" "skip=pa: $BUSY" "skip=pg: its pane is gone"
: > "$POSTS"; set_resolve "$S6" ok pb "pb relaunched on 9.9.9, 3 min after the recycle"
want="$(HEAD "${S6%%-*}" 1/3)
    • pb relaunched on 9.9.9, 3 min after the recycle
    • pa: still waiting, $BUSY
    • pg: given up, its pane is gone"
[ "$(posts_plain)" = "$want" ] && ok "given up: a pane given up earlier shows as \"pg: given up, <reason>\" after the pending ones" || bad "given-up post: $(show)"
S7="$((FB-103))-503"; set_create "$S7" Recycle recycle 2 0 9.9.9 1 out=pa out=pb "skip=pa: $BUSY"
: > "$POSTS"; set_resolve "$S7" ok pa "pa relaunched on 9.9.9, 4 min after the recycle" ok pb "pb relaunched on 9.9.9, 4 min after the recycle"
want="✅ *Recycle $(set_label "${S7%%-*}") · 2/2 · set closed*
    • pa relaunched on 9.9.9, 4 min after the recycle
    • pb relaunched on 9.9.9, 4 min after the recycle"
[ "$(posts_plain)" = "$want" ] && ok "✅ set closed: exactly as before, no pane lines" || bad "closed post: $(show)"
S9="$((FB-105))-505"; set_create "$S9" Recycle recycle 3 0 9.9.9 1 out=pa out=pb gave="pg: its pane is gone" "skip=pa: $BUSY"
: > "$POSTS"; set_resolve "$S9" ok pa "pa relaunched on 9.9.9, 4 min after the recycle" ok pb "pb relaunched on 9.9.9, 4 min after the recycle"
want="🔄 *Recycle $(set_label "${S9%%-*}") · 2/3*
    • pa relaunched on 9.9.9, 4 min after the recycle
    • pb relaunched on 9.9.9, 4 min after the recycle
⚠️ *Recycle $(set_label "${S9%%-*}") closed at 2/3*
    • pg: its pane is gone
    • open it on claude.ai and check it
Details: ~/.claude/salamander-revive.log"
[ "$(posts_plain)" = "$want" ] && ok "none pending: the last pane back with a give-up behind it is a 🔄 with no extra lines, then the ⚠️ closed-at post unchanged" || bad "closed-at posts: $(show)"
SA="$((FB-106))-506"; mapfile -t many < <(for i in $(seq 1 15); do echo "out=q$i"; echo "skip=q$i: a draft of $i words is waiting"; done)   # 15 different reasons: panes with one reason are one line (below)
set_create "$SA" Recycle recycle 16 0 9.9.9 1 out=qz "${many[@]}"
: > "$POSTS"; set_resolve "$SA" ok qz "qz relaunched on 9.9.9, 1 min after the recycle"
[ "$(posts_plain | grep -c '^    • q[0-9]*: still waiting, ')" = 12 ] && [ "$(posts_plain | tail -1)" = "    • …and 3 more" ] \
    && ok "the cap: 15 panes out → the first 12 as bullets, then \"• …and 3 more\"" || bad "capped post: $(show)"
SB="$((FB-107))-507"; long=$(printf 'x%.0s' $(seq 1 400))
set_create "$SB" Recycle recycle 2 0 9.9.9 1 out=pa out=pb "skip=pa: $long"
: > "$POSTS"; set_resolve "$SB" ok pb "pb relaunched on 9.9.9, 1 min after the recycle"
[ "$(posts_plain | awk 'length > 300' | wc -l)" = 0 ] && posts_plain | grep -q "^    • pa: still waiting, x*…$" && ok "a very long reason is cut, so a post stays small" || bad "long reason: $(show | cut -c1-200)"

echo "== panes held for the same reason are one line with a count; 5 or fewer keep their names"
# the first post: skip= bullets as the sweep wrote them (sets.sh builds the record by hand, no pane; the post goes to the stub poster above)
REST() { echo "relaunched only $1 min ago (on 2.1.317) — resting until 10:$2 UTC; sala relaunches it then (SALA_RECYCLE_REST 30 min)"; }
GAP=0
first_post() {   # <count of rest rows> [extra skip= rows…] → the first post of a fresh set (reported=0) holding them
    local n="$1" i; shift; GAP=$((GAP+1)); local id="$((FB-200-GAP))-6$GAP" kv=()
    for i in $(seq 1 "$n"); do kv+=("out=r$i" "skip=r$i: $(REST $(( (i * 7) % 13 + 4 )) $(( 10 + i % 40 )))"); done
    for i in "$@"; do kv+=("$i"); done
    set_create "$id" Recycle recycle $(( n + $# )) 0 2.1.317 0 "${kv[@]}" "note=sala retries them every 5 min for up to 2 h"
    : > "$POSTS"; set_report "$id"; LASTID=$id
}
first_post 21
want="⚠️ *Recycle $(set_label "${LASTID%%-*}") · 0/21 relaunched*
    • all 21 sessions were relaunched 4-16 min ago on 2.1.317: each rests 30 min, then sala relaunches it
    • sala retries them every 5 min for up to 2 h"
[ "$(posts_plain)" = "$want" ] && ok "21 panes resting for the same reason: the headline, one line with the count and the minutes' range, the retry note" || bad "21 rest post: $(show)"
[ "$(posts_plain | grep -c 'relaunched only')" = 0 ] && ok "no pane's own rest line is in it" || bad "per-pane lines in the 21 post"
first_post 5
[ "$(posts_plain | grep -c '^    • r[1-5]: relaunched only [0-9]* min ago (on 2.1.317) — resting until 10:[0-9]* UTC; sala relaunches it then (SALA_RECYCLE_REST 30 min)$')" = 5 ] && ! posts_plain | grep -q 'sessions' \
    && ok "5 panes with one reason: one bullet each, the session named, as before" || bad "5 rest post: $(show)"
first_post 6
want="⚠️ *Recycle $(set_label "${LASTID%%-*}") · 0/6 relaunched*
    • all 6 sessions were relaunched 5-13 min ago on 2.1.317: each rests 30 min, then sala relaunches it
    • sala retries them every 5 min for up to 2 h"
[ "$(posts_plain)" = "$want" ] && ok "6 panes with one reason: one line, names dropped" || bad "6 rest post: $(show)"
extra=(); for i in 1 2 3 4 5 6 7 8; do extra+=("out=b$i" "skip=b$i: busy for $((i*3)) min; sala relaunches it once it is free"); done
extra+=("out=d1" "skip=d1: a terminal prompt is showing" "out=d2" "skip=d2: a terminal prompt is showing")
first_post 7 "${extra[@]}"
want="⚠️ *Recycle $(set_label "${LASTID%%-*}") · 0/27 relaunched*
    • 7 sessions were relaunched 5-14 min ago on 2.1.317: each rests 30 min, then sala relaunches it
    • 8 sessions are busy; sala relaunches each once it is free
    • d1: a terminal prompt is showing
    • d2: a terminal prompt is showing
    • sala retries them every 5 min for up to 2 h"
[ "$(posts_plain)" = "$want" ] && ok "two reasons of 7 and 8 and a pair: a line with its count each, the pair by name (not \"all\")" || bad "mixed post: $(show)"
# a 🔄 follow-up: the panes still out, grouped before the 12-line cap
SG="$((FB-300))-701"; kv=(); for i in $(seq 1 30); do kv+=("out=g$i" "skip=g$i: $(REST $(( i % 9 + 4 )) 30)"); done; kv+=("out=gz" "skip=gz: $BUSY" "out=gy")
set_create "$SG" Recycle recycle 33 0 2.1.317 1 "${kv[@]}"
: > "$POSTS"; set_resolve "$SG" ok gy "gy relaunched on 2.1.317, 40 min after the recycle"
want="$(HEAD "${SG%%-*}" 1/33)
    • gy relaunched on 2.1.317, 40 min after the recycle
    • 30 sessions still waiting: relaunched 4-12 min ago on 2.1.317; each rests 30 min, then sala relaunches it
    • gz: still waiting, $BUSY"
[ "$(posts_plain)" = "$want" ] && ok "a 🔄 post: 30 resting panes are one line (\"still waiting\"), the pane with its own reason keeps its name" || bad "pending group post: $(show)"
# a deferred post (the retry window's end): the same grouping, the record keeps each pane's bullet
SD="$((FB-301))-702"; set_create "$SD" Recycle recycle 8 0 2.1.317 1 $(for i in $(seq 1 8); do echo "out=h$i"; done)
b=(); for i in 1 2 3 4 5 6; do b+=("h$i: busy for $((i*2)) h; sala relaunches it once it is free"); done
: > "$POSTS"; set_deferred "$SD" "${b[@]}" "h7: its 2 background tasks ran for 3 h; sala relaunches it once they finish" "h8: its 1 background task ran for 5 min; sala relaunches it once they finish"
want="⚠️ *Recycle $(set_label "${SD%%-*}") · 0/8 relaunched · 8 deferred*
    • 6 sessions are busy; sala relaunches each once it is free
    • h7: its 2 background tasks ran for 3 h; sala relaunches it once they finish
    • h8: its 1 background task ran for 5 min; sala relaunches it once they finish"
[ "$(posts_plain)" = "$want" ] && [ "$(set_count "$SD" skip)" = 8 ] && ok "a deferred post groups 6 busy panes into a line; the set still records all 8 bullets" || bad "deferred post: $(show)"
: > "$POSTS"

echo "== a recycle: two panes left behind, both back in one retry pass, then \"set closed\""
mk a "$(uuid 1)"; mk d1 "$(uuid 2)"; mk d2 "$(uuid 3)"; draft d1; draft d2; fake_up a
[ "$(grep -c '^start' "$FAKE_LOG")" = 3 ] || { echo "the fake panes did not start: $(<"$FAKE_LOG")"; exit 1; }
export SALA_RETRY_EVERY=4 SALA_RETRY_WINDOW=120
S0=$(date +%s); out=$("$SALA" recycle --force 2>&1); echo "$out" | grep -q 'recycle started' || bad "recycle did not start: $out"
waitfor '[ -n "$(post "relaunched*")" ]' 120 && ok "the left-behind post is out" || bad "no left-behind post: $(cat "$POSTS"; tail -30 "$RLOG")"
sleep 2; [ "$(reports)" = 0 ] && ok "the driver's end fires no post-recycle call while the flag still waits for its two panes" || bad "driver's call: '$(report 1)' (from $S0)"
undraft d1; undraft d2   # before the worker's first look (4 s): both come back in the same pass
waitfor '[ -n "$(post "· set closed")" ]' 120 && ok "the retry pass closed the set" || bad "no closure: $(show; tail -20 "$RLOG")"
show; wait_lock; waitfor '[ "$(workers)" = 0 ]' 20 || bad "the retry worker did not finish"
waitfor '[ "$(reports)" -ge 1 ]' 40; sleep 1; n=$(reports)
[ "$n" = 1 ] && [ "$(started 1)" -ge "$S0" ] 2>/dev/null && [ "$(flagat 1)" = "$(started 1)" ] && [ -z "$(skipped 1)" ] \
    && ok "one call for the cleared flag: the flag's time as started and flag_at, both back, nothing skipped" \
    || bad "calls: $(paste -sd';' "$PR") (n=$n, from $S0)"
[ -z "$(ls "$HOME"/.claude/salamander-retry.*.pid 2>/dev/null)" ] && ! grep -q "unbound variable" "$RLOG" \
    && ok "the finished worker took its pid file with it (its EXIT trap)" || bad "left: $(ls "$HOME"/.claude/salamander-retry.*.pid 2>/dev/null) $(grep "unbound variable" "$RLOG")"
$T kill-session -t sala-test-a; $T kill-session -t sala-test-d1; $T kill-session -t sala-test-d2; : > "$POSTS"; : > "$PR"


echo "== a give-up: one pane back, one gone → \"closed at 1/2\", once"
mk g1 "$(uuid 4)"; mk g2 "$(uuid 5)"; draft g1; draft g2
export SALA_RETRY_EVERY=3 SALA_RETRY_WINDOW=120
out=$("$SALA" recycle --force 2>&1); echo "$out" | grep -q 'recycle started' || bad "recycle did not start: $out"
waitfor '[ -n "$(post "· 0/2 relaunched*")" ]' 120 && ok "left-behind post: · 0/2 relaunched" || bad "no left-behind post: $(show)"
sleep 2; [ "$(reports)" = 0 ] && ok "no call while the flag waits for g1 and g2" || bad "early call: '$(report 1)'"
undraft g2; waitfor '[ -n "$(post "· 1/2*")" ]' 120 || bad "g2 did not come back: $(show)"
$T kill-session -t sala-test-g1   # a pane that is gone is a real give-up (the window's end is a deferral now)
waitfor '[ -n "$(post "closed at")" ]' 60 && ok "the vanished pane was given up with a give-up post" || bad "no give-up post: $(show; tail -20 "$RLOG")"
waitfor '[ "$(workers)" = 0 ]' 20; [ "$(nposts 'closed at')" = 1 ] && ok "\"closed at\" posted exactly once" || bad "\"closed at\" posted $(nposts 'closed at') times"
grep -q '· set closed' "$POSTS" && bad "a set with a give-up said \"set closed\"" || ok "no \"set closed\" in a set with a give-up"
show; wait_lock; waitfor '[ "$(workers)" = 0 ]' 20 || bad "the retry worker did not finish"
sleep 1; [ "$(reports)" = 1 ] && [ "$(skipped 1)" = sala-test-g1 ] && [ "$(flagat 1)" = "$(started 1)" ] \
    && ok "the flag cleared PARTLY: one call, g1 named as skipped, g2 back" || bad "calls: $(paste -sd';' "$PR")"
$T kill-session -t sala-test-g2; : > "$POSTS"; : > "$PR"

echo "== two workers on one set (the self-worker's next to the driver's): both run, the count covers both"
mk w1 "$(uuid 6)"; mk w2 "$(uuid 7)"; mk w3 "$(uuid 8)"; draft w1; draft w2; draft w3
export SALA_RETRY_EVERY=2 SALA_RETRY_WINDOW=120
S2="$(date +%s)-444"; set_create "$S2" Recycle recycle 3 1 9.9.9 1 out=sala-test-w1 out=sala-test-w2 hook=1; set_point recycle "$S2"   # hook=1: the driver's call is out
for n in w1 w2; do SALA_SET="$S2" setsid "$SALA" revive --retry-worker --force -- "$(tmux display -p -t "sala-test-$n" '#{pane_id}')|sala-test-$n|sala-test-$n:0|$(cpid "$n")" </dev/null >>"$RLOG" 2>&1 & done
waitfor 'grep -q "sala-test-w1:0: still skipped (retry 2)" "$RLOG" && grep -q "sala-test-w2:0: still skipped (retry 2)" "$RLOG"' 60
[ "$(workers)" = 2 ] && ok "after 2 ticks each both workers still run, each with its own pid file" || bad "$(workers) worker(s) alive (the second stopped the first?)"
[ "$(reports)" = 0 ] && ok "no post-recycle call while both are still skipped" || bad "calls while skipped: $(<"$PR")"
# THE CAPS (a run under the suites' load, Wed Oct 14th 2026: "no 2/3 post" after 15 s): a worker's pass once the draft is gone
# is its next tick (SALA_RETRY_EVERY, 2 s here), then `revive --only` — the mod asked, /exit by the keys, the exit waited for,
# the resume typed and its registry row waited for, a dozen process starts (a python3 per registry read, pgrep, tmux) — then
# the set's post: 5 to 8 s on an idle box, past 15 s with 23 suites side by side. Positive waits: a cap of 60 s asserts
# nothing less (the post either comes or it does not), the same for the 3/3 post below.
undraft w1; waitfor '[ -n "$(post "· 2/3*")" ]' 120 && ok "w1 back: 🔄 *Recycle … · 2/3*" || bad "no 2/3 post: $(show)"
sleep 1; [ "$(reports)" = 0 ] && ok "w1 back, w2 still out: the flag is open, so no call yet" || bad "early call: '$(report 1)'"
undraft w2; waitfor '[ -n "$(post "· 3/3 · set closed*")" ]' 120 && ok "w2 back, from the other worker: ✅ *Recycle … · 3/3 · set closed*" || bad "no 3/3 post: $(show)"
waitfor '[ "$(reports)" -ge 1 ]' 40 && [ "$(started 1)" = "${S2%%-*}" ] && [ -z "$(skipped 1)" ] && [ "$(reports)" = 1 ] \
    && ok "w2 back, the flag clears: ONE call, the set's own start, nothing skipped" || bad "calls: $(paste -sd';' "$PR")"
[ "$(nposts 'set closed')" = 1 ] && ok "one \"set closed\"" || bad "set closed $(nposts 'set closed') times"
show; waitfor '[ "$(workers)" = 0 ]' 20 && ok "both workers finished" || bad "a worker is still running"
: > "$PR"
echo "== takeover: a newer recycle set stops a worker of the older one"
S3="$(date +%s)-555"; set_create "$S3" Recycle recycle 1 0 9.9.9 1 out=sala-test-w3 hook=1; set_point recycle "$S3"
SALA_SET="$S3" setsid "$SALA" revive --retry-worker --force -- "$(tmux display -p -t sala-test-w3 '#{pane_id}')|sala-test-w3|sala-test-w3:0|$(cpid w3)" </dev/null >>"$RLOG" 2>&1 &
waitfor '[ "$(workers)" = 1 ]' 10; set_point recycle "$(( ${S3%%-*} + 1 ))-666"
waitfor '[ "$(workers)" = 0 ]' 20 && grep -q "retry: a newer recycle took over ($(( ${S3%%-*} + 1 ))-666) — stopping" "$RLOG" && ok "the worker stopped: \"a newer recycle took over\"" || bad "worker did not stop on takeover: $(workers) alive"
sleep 1; [ "$(reports)" = 0 ] && ok "a stopped worker reports nothing (w3 was never relaunched)" || bad "calls after the takeover: $(<"$PR")"
$T kill-session -t sala-test-w1; $T kill-session -t sala-test-w2; $T kill-session -t sala-test-w3; : > "$POSTS"; : > "$PR"

echo "== a deferred pane keeps its set open until watch relaunches it"
mk m "$(uuid 9)"; mk x "$(uuid 10)"; fake_up m x
S4="$(date +%s)-777"; set_create "$S4" Recycle recycle 2 1 9.9.9 1 out=sala-test-x hook=1
printf '%s\t%s\t%s\t%s\t%s\t%s\n' sala-test-x "$(date +%s)" "background work is running" "$(cpid x)" 1 "$S4" > "$SALA_DEFERRED"
# no wait for the registry's 10 s idle settle: the fake claude stamps its row 60 s old
set_resolve "$S4" ok sala-test-other "not in the set"   # someone else's pane: ignored
[ "$(set_count "$S4" out)" = 1 ] && [ ! -s "$POSTS" ] && ok "before watch: x outstanding, the set open, nothing posted" || bad "before watch: out=$(set_count "$S4" out) posts: $(show)"
sleep 1; [ "$(reports)" = 0 ] && ok "an ignored settle (someone else's pane) makes no post-recycle call" || bad "calls: $(<"$PR")"
SALA_MASTER=sala-test-m "$SALA" watch >/dev/null 2>&1
grep -q 'deferred: sala-test-x relaunched' "$HOME/.claude/salamander-watch.log" && ok "watch relaunched x" || bad "watch did not relaunch x: $(grep deferred "$HOME/.claude/salamander-watch.log")"
[ "$(set_val "$S4" done)" = 2 ] && [ "$(set_val "$S4" closed)" = 1 ] && [ -n "$(post 'set closed')" ] && ok "x closed the set: 2/2, closed, its \"set closed\" post out" || bad "deferred: $(cat "$SALA_SET_DIR/$S4"; show)"
[ ! -s "$SALA_DEFERRED" ] && ok "x left the deferred list" || bad "deferred list: $(<"$SALA_DEFERRED")"
waitfor '[ "$(reports)" -ge 1 ]' 40 && [ "$(started 1)" = "${S4%%-*}" ] && [ -z "$(skipped 1)" ] && [ "$(reports)" = 1 ] \
    && ok "watch's deferred relaunch reports x back: the set's own start, nothing skipped, one call" || bad "calls: $(paste -sd';' "$PR")"
$T kill-session -t sala-test-m; $T kill-session -t sala-test-x; : > "$POSTS"; : > "$PR"   # the sections below sweep with a recycle: only their own panes
# A pane that said `sala ready` many times in a recycle was still given up at
# the window's end, because two background Bash loops kept its registry state at 'shell', which the worker read as transient.
echo "== a pane that said ready but is held by background shells only: on the deferred list at once, never relaunched"
mk sh1 "$(uuid 11)"; mk mm "$(uuid 12)"; fake_up sh1 mm
SC=$(cpid sh1); sed -i 's/"status":"[a-z]*"/"status":"shell"/' "$HOME/.claude/sessions/$SC.json"   # the turn is over, a background shell runs
mkdir -p "$SALA_READY_DIR"; date +%s > "$SALA_READY_DIR/$(uuid 11)"                                   # what `sala ready` writes
: > "$POSTS"; : > "$PR"; rm -f "$SALA_DEFERRED"
export SALA_RETRY_EVERY=2 SALA_RETRY_WINDOW=120
S5="$(date +%s)-888"; set_create "$S5" Recycle recycle 2 1 9.9.9 1 out=sala-test-sh1 hook=1; set_point recycle "$S5"
SALA_SET="$S5" setsid "$SALA" revive --retry-worker --force -- "$(tmux display -p -t sala-test-sh1 '#{pane_id}')|sala-test-sh1|sala-test-sh1:0|$SC" </dev/null >>"$RLOG" 2>&1 &
waitfor 'grep -q "^sala-test-sh1	" "$SALA_DEFERRED" 2>/dev/null' 60 && ok "the pane is on the deferred list" || bad "not deferred: $(cat "$SALA_DEFERRED" 2>/dev/null; tail -8 "$RLOG")"
grep -q "sala-test-sh1:0: still skipped" "$RLOG" && bad "it was counted as still skipped: $(grep 'sh1:0: still skipped' "$RLOG" | tail -2)" || ok "never counted as \"still skipped\""
waitfor '[ "$(workers)" = 0 ]' 40 && ok "the worker has nothing left to retry and ended (long before its window)" || bad "worker still running"
[ "$(set_count "$S5" out)" = 1 ] && [ "$(set_count "$S5" gave)" = 0 ] && [ "$(set_val "$S5" closed)" = 0 ] && ok "the set keeps it outstanding: nothing given up, not closed" || bad "set: $(<"$SALA_SET_DIR/$S5")"
[ -n "$(post 'deferred')" ] && [ -n "$(post 'sala-test-sh1')" ] && ok "the report names the pane as deferred" || bad "no deferred post: $(show)"
[[ $(post 'deferred') =~ (^|$'\n')\ +•\ sala-test-sh1:\ busy\ for\ [0-9]+\ min\;\ sala\ relaunches\ it\ once\ it\ is\ free($'\n'|$) ]] && ! has "$(post 'deferred')" "background shell" \
    && ok "its bullet is the short form (no process to count under the stand-in: \"busy for <age>\"), not \"said ready, but its background shell(s)…\"" || bad "deferred bullet: $(post 'deferred')"
[ "$(cpid sh1)" = "$SC" ] && ok "the pane was not relaunched while its shells run (same claude pid)" || bad "pid $SC → $(cpid sh1)"
SALA_MASTER=sala-test-mm "$SALA" watch >/dev/null 2>&1
[ "$(cpid sh1)" = "$SC" ] && grep -q "^sala-test-sh1	" "$SALA_DEFERRED" && ok "watch leaves it alone while the registry still says 'shell'" || bad "watch moved it: pid $(cpid sh1); $(<"$SALA_DEFERRED")"
sed -i 's/"status":"[a-z]*"/"status":"idle"/' "$HOME/.claude/sessions/$SC.json"                        # the shells are done
SALA_MASTER=sala-test-mm "$SALA" watch >/dev/null 2>&1
grep -q 'deferred: sala-test-sh1 relaunched' "$HOME/.claude/salamander-watch.log" && [ "$(set_val "$S5" closed)" = 1 ] && [ "$(set_val "$S5" done)" = 2 ] \
    && ok "shells done: watch relaunched it and closed the set 2/2" || bad "after the shells: $(cat "$SALA_SET_DIR/$S5"; grep deferred "$HOME/.claude/salamander-watch.log")"
$T kill-session -t sala-test-sh1; $T kill-session -t sala-test-mm; : > "$POSTS"; : > "$PR"; rm -f "$SALA_DEFERRED"

echo "== the window's end defers a pane that is still pending, it does not give it up"
mk we "$(uuid 13)"; draft we
export SALA_RETRY_EVERY=2 SALA_RETRY_WINDOW=8
out=$("$SALA" recycle --force 2>&1); echo "$out" | grep -q 'recycle started' || bad "recycle did not start: $out"
waitfor '[ -n "$(post "· 0/1 relaunched*")" ]' 120 && ok "left-behind post: · 0/1 relaunched" || bad "no left-behind post: $(show)"
waitfor 'grep -q "^sala-test-we	" "$SALA_DEFERRED" 2>/dev/null' 120 && ok "the window ended with the pane on the deferred list" || bad "not deferred: $(cat "$SALA_DEFERRED" 2>/dev/null; tail -12 "$RLOG")"
waitfor '[ "$(workers)" = 0 ]' 40 || bad "the retry worker did not finish"; wait_lock
SE=$(ls -t "$SALA_SET_DIR" | grep -v '^current\|\.lock' | head -1)
[ "$(set_count "$SE" gave)" = 0 ] && [ "$(set_count "$SE" out)" = 1 ] && [ "$(set_val "$SE" closed)" = 0 ] && ok "nothing given up: the pane stays outstanding in its set, which stays open" || bad "set: $(<"$SALA_SET_DIR/$SE")"
[ -z "$(post 'closed at')" ] && ok "no \"closed at\" post" || bad "gave up: $(show)"
[ -n "$(post 'deferred')" ] && post deferred | grep -q 'half a thought\|draft\|unsubmitted' && ok "the report names the pane as deferred, with its reason (the unsubmitted draft)" || bad "no deferred post with a reason: $(show)"
grep -q 'sala-test-we:0: still skipped after' "$RLOG" && bad "the old give-up line is back" || ok "no give-up line in the log"
WP=$(cpid we); mk mm "$(uuid 14)"; fake_up mm
SALA_MASTER=sala-test-mm "$SALA" watch >/dev/null 2>&1
[ "$(cpid we)" = "$WP" ] && grep -q "^sala-test-we	" "$SALA_DEFERRED" && ok "watch does not relaunch it while the draft stands" || bad "watch: pid $WP → $(cpid we); $(<"$SALA_DEFERRED")"
undraft we; SALA_MASTER=sala-test-mm "$SALA" watch >/dev/null 2>&1
grep -q 'deferred: sala-test-we relaunched' "$HOME/.claude/salamander-watch.log" && [ "$(set_val "$SE" closed)" = 1 ] && [ "$(set_val "$SE" done)" = 1 ] \
    && ok "the draft sent: watch relaunched it and the set closed 1/1" || bad "after the draft: $(cat "$SALA_SET_DIR/$SE"; grep deferred "$HOME/.claude/salamander-watch.log")"

# Decision: a held pane is named in a recycle's posts with ONE short reason, the same words in the first
# post, the "n deferred" post and the 🔄 follow-ups, and never a pid, an uptime, a task id or a command (those stay in the log).
echo "== two busy panes: the same short bullet in the first post, the deferred post and the 🔄 follow-up, no pid or command"
$T kill-session -t sala-test-we; $T kill-session -t sala-test-mm; rm -f "$SALA_DEFERRED"; : > "$POSTS"; : > "$PR"
mk b1 "$(uuid 21)"; mk b2 "$(uuid 22)"; fake_up b1 b2
B1=$(cpid b1); B2=$(cpid b2)
sed -i 's/"status":"[a-z]*"/"status":"busy"/' "$HOME/.claude/sessions/$B1.json" "$HOME/.claude/sessions/$B2.json"   # a turn is running in both
export SALA_RETRY_EVERY=2 SALA_RETRY_WINDOW=8
out=$("$SALA" recycle --force 2>&1); echo "$out" | grep -q 'recycle started' || bad "recycle did not start: $out"
pbl() { local l; while IFS= read -r l; do [[ $l == *"• $2: "* ]] && { printf '%s' "${l#*• }"; return 0; }; done <<< "$1"; return 1; }   # <post> <session> → that pane's bullet text
norm() { printf '%s' "${1//[0-9]/N}"; }   # the age is the only thing that moves between the posts
WANT='^sala-test-b[12]: busy for [0-9]+ min; sala relaunches it once it is free$'
waitfor '[ -n "$(post "· 0/2 relaunched*")" ]' 120 && ok "the first post is out: · 0/2 relaunched" || bad "no first post: $(show)"
P1=$(post "· 0/2 relaunched*"); F1=$(pbl "$P1" sala-test-b1); F2=$(pbl "$P1" sala-test-b2)
[[ $F1 =~ $WANT ]] && [[ $F2 =~ $WANT ]] && ok "first post: \"<session>: busy for <age>; sala relaunches it once it is free\", one per pane" || bad "first post bullets: '$F1' '$F2' in: $P1"
waitfor '[ -n "$(post " deferred*")" ]' 120 && ok "the window ended: the \"n deferred\" post is out" || bad "no deferred post: $(show; tail -12 "$RLOG")"
P2=$(post " deferred*"); D1=$(pbl "$P2" sala-test-b1); D2=$(pbl "$P2" sala-test-b2)
[ "$(norm "$D1")" = "$(norm "$F1")" ] && [ "$(norm "$D2")" = "$(norm "$F2")" ] && ok "deferred post: the same words as the first post, no \"still not relaunchable after\" or \"deferred, not given up\"" || bad "deferred bullets: '$D1' '$D2' vs '$F1' '$F2'"
waitfor '[ "$(workers)" = 0 ]' 40 || bad "the retry worker did not finish"; wait_lock
sed -i 's/"status":"[a-z]*"/"status":"idle"/' "$HOME/.claude/sessions/$B1.json"     # b1's turn ended
mk mm2 "$(uuid 23)"; fake_up mm2; : > "$POSTS"
SALA_MASTER=sala-test-mm2 "$SALA" watch >/dev/null 2>&1
waitfor '[ -n "$(post "· 1/2*")" ]' 120 && ok "b1 relaunched by watch: a 🔄 · 1/2 follow-up" || bad "no follow-up: $(show; grep deferred "$HOME/.claude/salamander-watch.log")"
P3=$(post "· 1/2*"); W2=$(pbl "$P3" sala-test-b2)
[ "$(norm "$W2")" = "$(norm "$F2")" ] && ok "the 🔄 follow-up names b2 with the same words (no \"still waiting,\")" || bad "follow-up bullet: '$W2' vs '$F2' in: $P3"
ALLP=""; for P in "$P1" "$P2" "$P3"; do ALLP+="$P"$'\n'; done
case "$ALLP" in *[Pp]id*|*"up "[0-9]*|*"task id"*|*"registry"*|*"sleep"*|*"running under"*|*"turn or a dialog"*|*"child pids"*) bad "a post carries a pid, uptime, task id, command or the registry wording: $ALLP";; *) ok "none of the three posts carries a pid, an uptime, a task id, a command or the registry wording";; esac
grep -q "sala-test-b2:0: still skipped (retry" "$RLOG" && grep -q "registry says 'busy'" "$RLOG" && ok "the log keeps the long reason (registry says 'busy' …)" || bad "log lost the reason: $(grep b2 "$RLOG" | tail -3)"
$T kill-session -t sala-test-b1; $T kill-session -t sala-test-b2; $T kill-session -t sala-test-mm2

echo "== the 🔄 follow-up of a held pane: a background-tasks bullet is printed whole, an old-style reason keeps \"still waiting,\""
rm -f "$(_set_scope_file recycle)"   # the sets below carry back-dated ids: a newer current pointer would make them superseded, and a superseded flag posts no 🔄
FC="$(date +%s)"; SD="$((FC-201))-701"; TASKS="sala-test-pa: its 3 background tasks ran for 2 h; sala relaunches it once they finish"
set_create "$SD" Recycle recycle 4 0 9.9.9 1 out=sala-test-pa out=sala-test-pb out=sala-test-pc out=sala-test-pd "skip=$TASKS" "skip=sala-test-pb: busy for 35 min; sala relaunches it once it is free" "skip=sala-test-pc: $DLG"
: > "$POSTS"; set_resolve "$SD" ok sala-test-pd "sala-test-pd relaunched on 9.9.9, 4 min after the recycle"
P=$(post "· 1/4*")
[ "$(pbl "$P" sala-test-pa)" = "${TASKS}" ] && [ "$(pbl "$P" sala-test-pb)" = "sala-test-pb: busy for 35 min; sala relaunches it once it is free" ] && [ "$(pbl "$P" sala-test-pc)" = "sala-test-pc: still waiting, $DLG" ] \
    && ok "tasks and busy bullets whole; a dialog pane's reason still \"still waiting, <why>\"" || bad "follow-up: $P"

show
[ "$fail" = 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
