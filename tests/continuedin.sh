#!/usr/bin/env bash
# Continued-in follow (Thu Oct 29th 2026; lib/continuedin.sh, called by lib/watch.sh before bare_tick and alone as
# `sala watch --continued`, which lib/follow.py runs when a registry row's sessionId changes). Claude Code 2.1.31x can move a LIVE
# pane to a new transcript id without restarting the process: it appends a {"type":"continued-in","sessionId":"<old>",
# "continuedInSessionId":"<new>"} record to the OLD transcript (not necessarily as its last line). The pane map and the session
# registry kept the old id until a revive three hours later; now watch follows the switch. What is checked:
#  - the control: panes whose transcripts have no record (one with the record text only inside a message, JSON-escaped) are
#    left alone, and SALA_CONTINUED_IN=off follows nothing even with a record and a registry that agrees;
#  - a frozen pane map (a recycle or reboot holds it): the pane is skipped entirely, nothing followed, logged or recorded; the
#    first run after the freeze follows;
#  - one full watch tick follows a switch whose old transcript has four more lines after the record (registry agrees) and a
#    chain of two (old -> middle -> new) in one tick; the pane map names the new id, no row names the old one, the ledger log has
#    the follow with the caller "watch, continued-in", the session registry lists the new ids after the old (the old is no longer
#    the current transcript), and the watch log has one line per pane; `revive --save-map` (write_sidecar) after the follow leaves
#    the map where it is;
#  - not followed: the registry row is the ONLY evidence, so a record whose registry row still says the old id is left alone even
#    when the new transcript exists and the record is newer than the process (e: another process's switch, or a hand --resume),
#    and a second tick plus `revive --save-map` leave it (no ping-pong); a new id with no transcript (d, logged once, not every
#    tick; followed when the registry row changes); a follow the ledger refuses (the new id is another row's conversation:
#    logged once, the old row stays);
#  - cont_record on a big transcript: a record followed by ~60 KB of later lines is found in well under a second (the old bash
#    string slicing took seconds), the default window is 256 KiB, and a record pushed out of a small window is not seen.
# SAFETY: every kill is a `kill -9` of ONE pid whose /proc/<pid>/exe is the suite's own compiled fake claude and whose
# /proc/<pid>/environ names this suite's temporary HOME (tests/lib.sh kill_fake_claude). The tmux server is a private socket
# (tmux -L sala-continuedin-<pid> -f /dev/null, SALA_TMUX_SOCKET pointing at it), HOME is a mktemp -d (locked with flock while the
# suite runs, removed by the EXIT trap pass or fail), the claude is tests/fake-claude.c; no real pane, server, ~/.claude or claude
# process is read or touched, and the suite refuses to start if any of that is not so. Posts go to a file.
# Usage: bash tests/continuedin.sh   (exit 0 = pass; ~60 s)
set -u
unset TMUX TMUX_PANE XDG_STATE_HOME SALA_MASTER SALA_SET SALA_SET_SELF SALA_RECYCLE SALA_RETRY_WORKER SALA_LOCK_WHO SALA_LOCK_WAIT SALA_RELAUNCH_KIND \
      SALA_FLEET_HOSTS SALA_CGROUP_FILE SALA_OP_QUEUE SALA_NO_RELAUNCH SALA_BOOT_ID SALA_CONFIG SALA_CONTINUED_IN SALA_BARE_REVIVE
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
export HOME=$(mktemp -d); export SALA_TZ=Etc/UTC SALA_CONFIG=/dev/null
case "$HOME" in /tmp/*|"${TMPDIR:-/tmp}"/*) ;; *) echo "continuedin: HOME is not a temporary directory ($HOME) - refusing to run"; exit 1;; esac
exec 7< "$HOME"; flock -n 7 || { rm -rf "$HOME"; exit 1; }   # the temp folder is locked for the run (systemd-tmpfiles ageing honors it)
as_op_unit   # the guarded verbs this suite runs itself (adopt) stand for the queue's runner (tests/lib.sh, 5)
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
FAKEBIN="$HOME/.local/share/claude/versions/9.9.9"
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$FAKEBIN" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
ln -s "$FAKEBIN" "$HOME/.local/bin/claude"
printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/systemd-run"
cat > "$HOME/.local/bin/systemctl" <<'EOF'
#!/bin/bash
case "$*" in *is-active*) exit 3 ;; *is-system-running*) echo running; exit 0 ;; *cat*tmux.service*) exit 1 ;; *) exit 0 ;; esac
EOF
chmod +x "$HOME/.local/bin/systemd-run" "$HOME/.local/bin/systemctl"
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log" FAKE_TYPED_LOG="$HOME/typed.log"
POSTS="$HOME/posts.txt"; : > "$POSTS"; export SALA_NOTIFY_CMD="{ cat; echo '%%'; } >> $POSTS"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off
export SALA_LIMIT_ALERT=off SALA_LIMIT_RESUME=off SALA_STUCK_POST=off SALA_BARE_REVIVE=off   # the other watches: not under test
SALA="$ROOT/bin/salamander"; SOCK="sala-continuedin-$$"; T="tmux -L $SOCK -f /dev/null"
export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's
case "$SOCK" in sala-continuedin-*) ;; *) echo "continuedin: not a private socket - refusing to run"; exit 1;; esac
WLOG="$HOME/.claude/salamander-watch.log"; : > "$WLOG"
cleanup() {
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    kill_fake_claude "$FAKEBIN"
    exec 7<&-; rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux    # literal socket: the children run set -u
. "$ROOT/lib/common.sh"
mk() { local n="$1" u="$2"; shift 2; $T new-session -d -s "sala-test-$n" -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="sala-test-$n" -e FAKE_LOG="$FAKE_LOG" "$@"; $T send-keys -t "sala-test-$n" 'claude' Enter; }
tick() { "$SALA" watch >/dev/null 2>&1; }
cont() { "$SALA" watch --continued >/dev/null 2>&1; }
wlogn() { grep -c -- "$1" "$WLOG" 2>/dev/null || true; }
mapped() { sidecar_uuid_for_session "sala-test-$1"; }   # <suffix> → the pane map's conversation
TD="$HOME/.claude/projects/x"
# tr_old <old uuid> [<new uuid> <epoch>] → the old transcript: some history (one line holds the record text JSON-escaped, as a message quoting it would),
# the continued-in record when a new id is given, then four more lines after it (it is not the last line)
tr_old() {
    local o="$1" n="${2:-}" e="${3:-0}" i
    {   printf '{"type":"user","sessionId":"%s","message":{"content":"history"}}\n' "$o"
        printf '{"type":"assistant","sessionId":"%s","message":{"content":"quoting {\\"type\\":\\"continued-in\\",\\"sessionId\\":\\"%s\\",\\"continuedInSessionId\\":\\"%s\\"}"}}\n' "$o" "$o" "$(uuid 99)"
        [ -n "$n" ] && printf '{"type":"continued-in","timestamp":"%s","sessionId":"%s","continuedInSessionId":"%s"}\n' "$(iso "$e")" "$o" "$n"
        for i in 1 2 3 4; do printf '{"type":"system","sessionId":"%s","content":"later %s"}\n' "$o" "$i"; done
    } > "$TD/$o.jsonl"
}
tr_new() { printf '{"type":"history-suppression","sessionId":"%s"}\n' "$1" > "$TD/$1.jsonl"; }   # <uuid> → the new transcript, as the CLI begins one
set_reg_sid() {   # <pid> <uuid> → that claude's registry row says it is in <uuid> now (the first "sessionId":"…" in it)
    local f="$HOME/.claude/sessions/$1.json" t; { IFS= read -r -d '' t < "$f"; } 2>/dev/null || :
    [[ $t =~ \"sessionId\":\"[^\"]*\" ]] && t=${t/"${BASH_REMATCH[0]}"/\"sessionId\":\"$2\"}
    printf '%s' "$t" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
}
# sess_ids <session> → its session-registry transcript ids, oldest first, one per line (sessions transcript lists the current one first)
sess_ids() { sessions_py transcript "$1" --json 2>/dev/null | grep -o '"id": *"[0-9a-f-]*"' | grep -o '[0-9a-f]\{8\}-[0-9a-f-]*' | tail -n +2 | tac; }

echo "== setup: private tmux server, isolated HOME, the compiled fake claude (sala-test-a..h)"
NOW=$(date +%s)
mk a "$(uuid 1)"; mk b "$(uuid 2)"; mk c "$(uuid 3)"; mk d "$(uuid 4)"; mk e "$(uuid 5)"
mk f "$(uuid 6)"
mk g "$(uuid 7)"; mk h "$(uuid 8)"
fake_up sala-test-a sala-test-b sala-test-c sala-test-d sala-test-e sala-test-f sala-test-g sala-test-h || exit 1
for n in a b c d e f g h; do "$SALA" adopt "sala-test-$n" >/dev/null 2>&1 || bad "adopt sala-test-$n failed"; done
[ "$($T display -p '#{socket_path}')" = "$SALA_TMUX_SOCKET" ] && ok "the tmux server is the suite's private socket ($SOCK)" || bad "socket: $($T display -p '#{socket_path}')"
declare -A PID; for n in a b c d e f g h; do PID[$n]=$(cpid "$n"); [ -n "${PID[$n]}" ] || bad "no claude pid under sala-test-$n"; done
MAP0=$(slurp "$SALA_SIDECAR")

echo "== control: no continued-in record anywhere (c quotes one inside a message) - nothing moves"
for n in 1 2 3 4 5 6 7 8; do tr_old "$(uuid $n)"; done
tick; cont
[ "$(slurp "$SALA_SIDECAR")" = "$MAP0" ] && [ "$(wlogn 'continued-in:')" = 0 ] && ok "the pane map is unchanged, nothing in the watch log" || bad "map changed or logged: $(grep 'continued-in' "$WLOG" | tail -3)"

echo "== records written; h has one with a registry that agrees, but SALA_CONTINUED_IN=off follows nothing"
E=$((NOW + 5))
tr_old "$(uuid 1)" "$(uuid 11)" "$E"; tr_new "$(uuid 11)"; set_reg_sid "${PID[a]}" "$(uuid 11)"              # a: registry agrees
tr_old "$(uuid 2)" "$(uuid 12)" "$E"; tr_old "$(uuid 12)" "$(uuid 22)" "$E"; tr_new "$(uuid 22)"; set_reg_sid "${PID[b]}" "$(uuid 22)"   # b: a chain of two
tr_old "$(uuid 4)" "$(uuid 14)" "$E"; set_reg_sid "${PID[d]}" "$(uuid 4)"                                      # d: no transcript for the new id, registry still the old
tr_old "$(uuid 5)" "$(uuid 15)" "$E"; tr_new "$(uuid 15)"                                                       # e: registry stale (still uuid 5), the new transcript exists, the record is newer than the process
tr_old "$(uuid 6)" "$(uuid 16)" "$E"; tr_new "$(uuid 16)"; set_reg_sid "${PID[f]}" "$(uuid 16)"                  # f: registry agrees
tr_old "$(uuid 7)" "$(uuid 3)" "$E"; set_reg_sid "${PID[g]}" "$(uuid 3)"                                        # g: the new id is c's conversation (the ledger refuses)
tr_old "$(uuid 8)" "$(uuid 18)" "$E"; tr_new "$(uuid 18)"; set_reg_sid "${PID[h]}" "$(uuid 18)"                  # h: registry agrees
SALA_CONTINUED_IN=off cont; SALA_CONTINUED_IN=off tick
[ "$(slurp "$SALA_SIDECAR")" = "$MAP0" ] && [ "$(wlogn 'continued-in:')" = 0 ] && ok "switch off: the pane map is unchanged, nothing logged" || bad "followed with the switch off: $(grep 'continued-in' "$WLOG" | tail -3)"

echo "== a frozen pane map (a recycle holds it): every pane is skipped - nothing followed, logged or recorded"
ledger_freeze recycle $$ >/dev/null 2>&1 || bad "could not freeze the pane map"
cont; tick
[ "$(slurp "$SALA_SIDECAR")" = "$MAP0" ] && [ "$(wlogn 'continued-in:')" = 0 ] && ok "frozen: the pane map is unchanged and the watch log has no continued-in line" || bad "frozen, yet: $(grep 'continued-in' "$WLOG" | tail -3)"
[ "$(grep -c "	follow	.*watch, continued-in" "$SALA_LEDGER_LOG" 2>/dev/null || true)" = 0 ] && [ ! -s "$SALA_LEDGER_DEFERRED" ] && ok "frozen: no ledger write, nothing deferred" || bad "ledger under a freeze: $(tail -3 "$SALA_LEDGER_LOG"); deferred: $(slurp "$SALA_LEDGER_DEFERRED")"
! sessions_py transcript sala-test-a --json 2>/dev/null | grep -q "$(uuid 11)" && ok "frozen: the session registry did not record the new id" || bad "a recorded while frozen: $(sess_ids sala-test-a | tr '\n' ' ')"
ledger_unfreeze test >/dev/null 2>&1
ledger_frozen && bad "still frozen" || :

echo "== one full watch tick follows a, b (two hops), f and h (registry agrees); e (registry stale) is left"
tick
[ "$(mapped a)" = "$(uuid 11)" ] && ok "a: the pane map names the new conversation (record followed by four more lines)" || bad "a: $(mapped a)"
[ "$(mapped b)" = "$(uuid 22)" ] && ok "b: a chain of two followed in one tick (old -> middle -> new)" || bad "b: $(mapped b)"
[ "$(mapped f)" = "$(uuid 16)" ] && [ "$(mapped h)" = "$(uuid 18)" ] && ok "f and h: followed once the freeze is lifted and the switch is on" || bad "f=$(mapped f) h=$(mapped h)"
! grep -q "$(uuid 1)\|$(uuid 2)\|$(uuid 12)\|$(uuid 6)\|$(uuid 8)" "$SALA_SIDECAR" && ok "no followed row of the pane map names an old id" || bad "old ids still in the map: $(cut -f1,2 "$SALA_SIDECAR" | tr '\t' ' ' | tr '\n' ';')"
[ "$(grep -c "	follow	.*watch, continued-in" "$SALA_LEDGER_LOG")" = 4 ] && grep -q "follow	sala-test-a	" "$SALA_LEDGER_LOG" && ok "the ledger log has four follow lines, caller 'watch, continued-in'" || bad "ledger log: $(tail -6 "$SALA_LEDGER_LOG")"
[ "$(wlogn 'continued-in: sala-test-a: conversation .* → .* (1 hop(s)); pane map followed, session registry recorded')" = 1 ] \
    && [ "$(wlogn 'continued-in: sala-test-b: conversation .* → .* (2 hop(s)); pane map followed')" = 1 ] && ok "one watch log line per followed pane (b says 2 hops)" || bad "watch log: $(grep 'continued-in' "$WLOG")"
[ "$(sess_ids sala-test-a | tail -1)" = "$(uuid 11)" ] && [ "$(sess_ids sala-test-a | head -1)" = "$(uuid 1)" ] && ok "a: the session registry lists the new id after the old one (the old is no longer current)" || bad "a ids: $(sess_ids sala-test-a | tr '\n' ' ')"
[ "$(sess_ids sala-test-b | tr '\n' ' ')" = "$(uuid 2) $(uuid 12) $(uuid 22) " ] && ok "b: the session registry holds old, middle and new, in order" || bad "b ids: $(sess_ids sala-test-b | tr '\n' ' ')"

echo "== not followed: c (no record), d (the new id has no transcript), e (registry stale though the record is newer), g (the ledger refuses)"
[ "$(mapped c)" = "$(uuid 3)" ] && ok "c: no record in the tail (one quoted in a message does not count)" || bad "c: $(mapped c)"
[ "$(mapped d)" = "$(uuid 4)" ] && grep -q "sala-test-d: a continued-in record names $(uuid 14), but the pid's registry row still says $(uuid 4)" "$WLOG" && ok "d: a record the registry row does not confirm is not followed, said in the log" || bad "d: $(mapped d); $(grep 'sala-test-d' "$WLOG")"
[ "$(mapped e)" = "$(uuid 5)" ] && grep -q "sala-test-e: a continued-in record names $(uuid 15), but the pid's registry row still says $(uuid 5)" "$WLOG" && ok "e: the new transcript exists and the record is newer than the process, but the registry row says the old id: not followed" || bad "e: $(mapped e); $(grep 'sala-test-e' "$WLOG")"
[ "$(mapped g)" = "$(uuid 7)" ] && [ "$(wlogn 'sala-test-g: conversation .*pane map NOT followed (exit 2')" = 1 ] && ok "g: the ledger refused (the new id is c's conversation): the old row stays, logged" || bad "g: $(mapped g); $(grep 'sala-test-g' "$WLOG")"

echo "== write_sidecar (revive --save-map) after a follow leaves the map where it is: no ping-pong"
MAP1=$(slurp "$SALA_SIDECAR"); N1=$(wlogn 'continued-in:')
"$SALA" revive --save-map >/dev/null 2>&1; "$SALA" revive --save-map >/dev/null 2>&1
[ "$(slurp "$SALA_SIDECAR")" = "$MAP1" ] && ok "two saves: the map is byte for byte the same (a, b, f, h on their new ids, e on its own)" || bad "save-map moved a row: $(cut -f1,2 "$SALA_SIDECAR" | tr '\t' ' ' | tr '\n' ';')"
cont; tick; "$SALA" revive --save-map >/dev/null 2>&1
[ "$(slurp "$SALA_SIDECAR")" = "$MAP1" ] && [ "$(wlogn 'continued-in:')" = "$N1" ] && ok "a watch run and a save after that: the map unchanged, no log line repeated (d, e, g said once)" || bad "map/log changed: $(wlogn 'continued-in:') vs $N1; $(tail -4 "$WLOG")"

echo "== evidence that arrives later is followed: the registry row of d changes"
tr_new "$(uuid 14)"; cont
[ "$(mapped d)" = "$(uuid 4)" ] && ok "d: the new transcript alone (registry still the old id) is not evidence" || bad "d followed on the transcript alone: $(mapped d)"
set_reg_sid "${PID[d]}" "$(uuid 14)"; cont
[ "$(mapped d)" = "$(uuid 14)" ] && [ "$(wlogn 'continued-in: sala-test-d: conversation')" = 1 ] && ok "d: the registry row now says the new id - followed by 'watch --continued' alone" || bad "d: $(mapped d); $(grep 'sala-test-d' "$WLOG")"
[ "$(sess_ids sala-test-d | tail -1)" = "$(uuid 14)" ] && ok "d: the session registry follows too" || bad "d ids: $(sess_ids sala-test-d | tr '\n' ' ')"
[ "$(mapped e)" = "$(uuid 5)" ] && [ "$(mapped g)" = "$(uuid 7)" ] && [ "$(mapped c)" = "$(uuid 3)" ] && ok "e, g and c still on their own conversations" || bad "e=$(mapped e) g=$(mapped g) c=$(mapped c)"
[ "$(posts)" = 0 ] && ok "nothing posted to Slack" || bad "posts: $(<"$POSTS")"

echo "== cont_record on a big transcript: a record followed by ~60 KB of later lines, found fast"
BIG=$(uuid 30)
PAD=$(printf 'z%.0s' $(seq 1 90))
{   for ((i = 1; i <= 1500; i++)); do printf '{"type":"system","sessionId":"%s","content":"earlier %s %s"}\n' "$BIG" "$i" "$PAD"; done
    printf '{"type":"continued-in","timestamp":"%s","sessionId":"%s","continuedInSessionId":"%s"}\n' "$(iso "$E")" "$BIG" "$(uuid 31)"
    for ((i = 1; i <= 340; i++)); do printf '{"type":"system","sessionId":"%s","content":"later %s %s"}\n' "$BIG" "$i" "$PAD"; done
} > "$TD/$BIG.jsonl"
AFTER=$(( $(stat -c %s "$TD/$BIG.jsonl") - $(grep -abo '"type":"continued-in"' "$TD/$BIG.jsonl" | head -1 | cut -d: -f1) ))
[ "$AFTER" -gt 60000 ] && ok "the record is $AFTER bytes from the end of the file" || bad "the record is only $AFTER bytes from the end"
cr() { ( unset SALA_CONTINUED_TAIL; [ -z "${1:-}" ] || SALA_CONTINUED_TAIL=$1; . "$ROOT/lib/continuedin.sh"; cont_record "$BIG"; rc=$?; echo "$rc $CONT_NEXT $CONT_EP $SALA_CONTINUED_TAIL" ); }
T0=$(date +%s%N); R=$(cr); MS=$(( ($(date +%s%N) - T0) / 1000000 ))
[ "${R%% *}" = 0 ] && [ "$(cut -d' ' -f2 <<< "$R")" = "$(uuid 31)" ] && [ "$(cut -d' ' -f3 <<< "$R")" = "$E" ] && ok "found: the next id and the record's time (default window)" || bad "cont_record: $R"
[ "$MS" -lt 1000 ] && ok "and fast: $MS ms (the bash slicing it replaced took seconds on this file)" || bad "cont_record took $MS ms"
[ "$(cut -d' ' -f4 <<< "$R")" = 262144 ] && ok "the default window is 256 KiB" || bad "default window: $(cut -d' ' -f4 <<< "$R")"
R=$(cr 8192)
[ "${R%% *}" = 1 ] && ok "a record pushed out of a small window (8 KiB) is not seen (write_sidecar repairs that at a recycle)" || bad "record seen in an 8 KiB window: $R"

[ "$fail" = 0 ] && echo "continuedin: pass" || echo "continuedin: FAIL"
exit $fail
