#!/usr/bin/env bash
# Models (Wed Oct 14th 2026, asked by the project's main session; lib/common.sh "models", lib/model.sh): the model and effort a session is
# relaunched on, recorded, ahead of its transcript's. What is checked guards the relaunch line and the record: model_valid
# and effort_known (what may be typed onto a launch line); resume_cmd taking a session's row over its transcript (the model
# always, the effort unless the row says "-"), a row of another session or a hand-edited bad value changing nothing;
# `sala model` refusing an unknown session, a bad effort and a bad model before anything is recorded; `--dry-run` writing
# nothing (no models.tsv, no models.log) and relaunching nothing (the lane default bug once fixed); the switch recording
# the row and relaunching the pane through the direct sweep with --model and --effort on its claude's command line while
# its transcript says otherwise; a second run on the same pair leaving it alone; a later relaunch keeping the record; the
# table; `--clear` (and its dry run) dropping the row without a relaunch; `--record-only` writing the row with no revive
# call (a stubbed revive.sh), its dry run writing nothing, an unknown name refused and a pane-map-known one with no tmux
# session accepted, the record reaching the next resume line; rename and retire carrying or dropping the row.
# The batch: `model <model> <session>…` refusing the lot for one unknown session, ONE revive call for all the relaunches, a RESULT line
# per session and a summary, the single-session shape unchanged, `--clear` and `--record-only` with several sessions.
# Isolated HOME, a private tmux socket, the compiled fake claude (tests/fake-claude.c). Usage: bash tests/models.sh
# (exit 0 = pass; ~40 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_SET SALA_SET_SELF SALA_POST_RECYCLE_CMD SALA_RECYCLE SALA_RETRY_WORKER SALA_NO_RELAUNCH SALA_MASTER
unset ANTHROPIC_API_KEY ANTHROPIC_CUSTOM_HEADERS CLAUDE_CONFIG_DIR
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, tmux_socket_rm
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$HOME/.local/share/claude/versions/9.9.9" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
ln -s "$HOME/.local/share/claude/versions/9.9.9" "$HOME/.local/bin/claude"
printf '#!/bin/sh\necho "$*" >> "%s/systemd-run.txt"\n' "$HOME" > "$HOME/.local/bin/systemd-run"; chmod +x "$HOME/.local/bin/systemd-run"
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="{ cat; echo '%%'; } >> $POSTS"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off
SALA="$ROOT/bin/salamander"; SOCK="sala-models-$$"; T="tmux -L $SOCK -f /dev/null"; RLOG="$HOME/.claude/salamander-revive.log"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's
cleanup() {
    local f p; for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    for p in $(pgrep -x claude); do [ "$HOME/.local/share/claude/versions/9.9.9" -ef "/proc/$p/exe" ] && kill -9 "$p" 2>/dev/null; done
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux    # literal socket: the children run set -u
. "$ROOT/lib/common.sh"
wait_lock() { lock_wait "$HOME/.claude/salamander-recycle.lock" 80; }
mk() { local n="$1" u="$2"; shift 2; $T new-session -d -s "sala-test-$n" -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="sala-test-$n" -e FAKE_LOG="$FAKE_LOG" "$@"; $T send-keys -t "sala-test-$n" 'claude' Enter; }
row() { model_row "$1" | tr '\t' /; }                                             # <session> → "model/effort", or nothing
arec() {  # <uuid> <model> <effort> → one assistant record of that conversation
    printf '{"type":"assistant","isSidechain":false,"message":{"model":"%s","role":"assistant","content":[{"type":"text","text":"x"}]},"effort":"%s","sessionId":"%s"}\n' "$2" "$3" "$1"
}
U1=$(uuid 1); U2=$(uuid 2); UX=$(uuid 9)
# the transcripts say opus at high effort: whatever a relaunch puts on the line beyond that comes from the record
for u in "$U1" "$U2" "$UX"; do { arec "$u" claude-opus-5 high; arec "$u" claude-opus-5 high; } > "$HOME/.claude/projects/x/$u.jsonl"; done

echo "== model_valid and effort_known: what may be typed onto a launch line"
for m in opus sonnet haiku fable claude-sonnet-5-5 claude-opus-4-1-20250805 claude-haiku-4.5; do model_valid "$m" || bad "model_valid refused '$m'"; done; ok "the four family aliases and full claude-… ids pass"
for m in '' gpt-5 Sonnet claude- 'claude-opus-4-6[1m]' 'claude-opus;rm' 'claude-OPUS-5' 'sonnet x'; do model_valid "$m" && bad "model_valid passed '$m'"; done; ok "an empty word, another vendor's, capitals, a glob suffix, shell metacharacters: refused"
for e in low medium high xhigh max; do effort_known "$e" || bad "effort_known refused '$e'"; done
for e in '' none ultra High 'max ' -; do effort_known "$e" && bad "effort_known passed '$e'"; done; ok "efforts: low medium high xhigh max, nothing else"

echo "== resume_cmd: the session's row over the transcript"
base="$(mod_env_prefix)claude --resume $UX"
[ "$(resume_cmd "$UX" sala-test-x)" = "$base --model opus --effort high" ] && ok "no row: the transcript's family and effort (as before)" || bad "no row: $(resume_cmd "$UX" sala-test-x)"
model_write sala-test-x sonnet medium && [ "$(row sala-test-x)" = sonnet/medium ] && ok "model_write: the row is read back" || bad "model_write: $(slurp "$SALA_MODELS")"
[ "$(resume_cmd "$UX" sala-test-x)" = "$base --model sonnet --effort medium" ] && ok "row sonnet/medium: --model sonnet --effort medium over the transcript's opus/high" || bad "row over transcript: $(resume_cmd "$UX" sala-test-x)"
[ "$(resume_cmd "$UX" sala-test-y)" = "$base --model opus --effort high" ] && [ "$(resume_cmd "$UX")" = "$base --model opus --effort high" ] && ok "another session, or none named: untouched by the row" || bad "row leaked: $(resume_cmd "$UX" sala-test-y)"
model_write sala-test-x claude-sonnet-5-5 && [ "$(row sala-test-x)" = claude-sonnet-5-5/- ] && ok "no effort given: the row says '-'" || bad "row without effort: $(row sala-test-x)"
[ "$(resume_cmd "$UX" sala-test-x)" = "$base --model claude-sonnet-5-5 --effort high" ] && ok "row with '-': the full id as --model, the transcript's effort kept" || bad "row with -: $(resume_cmd "$UX" sala-test-x)"
model_write sala-test-x sonnet bogus && bad "model_write took a bad effort" || ok "model_write refuses a bad effort"
model_write sala-test-x gpt-5 && bad "model_write took a bad model" || ok "model_write refuses a bad model"
[ "$(row sala-test-x)" = claude-sonnet-5-5/- ] && ok "and the row is as it was" || bad "row after refusals: $(row sala-test-x)"
printf 'sala-test-z\tclaude-opus;rm\tultra\n' >> "$SALA_MODELS"
[ "$(resume_cmd "$UX" sala-test-z)" = "$base --model opus --effort high" ] && ok "a hand-edited bad row: ignored, never typed" || bad "bad row: $(resume_cmd "$UX" sala-test-z)"
model_rename sala-test-x sala-test-w; [ -z "$(row sala-test-x)" ] && [ "$(row sala-test-w)" = claude-sonnet-5-5/- ] && ok "model_rename moves the row (sala rename)" || bad "after rename: $(<"$SALA_MODELS")"
model_drop sala-test-w; model_drop sala-test-z; [ -z "$(row sala-test-w)" ] && ok "model_drop: the row is gone (sala retire, --clear)" || bad "after drop: $(<"$SALA_MODELS")"
grep -q $'\tset\tsala-test-x\t(transcript) → sonnet/medium\t' "$SALA_MODEL_LOG" && ok "models.log has one line per change" || bad "models.log: $(slurp "$SALA_MODEL_LOG")"
rm -f "$SALA_MODELS" "$SALA_MODEL_LOG"

echo "== the verb: the table and the refusals"
out=$("$SALA" model 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'nothing recorded' <<< "$out" && ok "sala model, nothing recorded: says so" || bad "empty table ($rc): $out"
out=$("$SALA" model sala-test-nope sonnet 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q "unknown session 'sala-test-nope'" <<< "$out" && [ ! -e "$SALA_MODELS" ] && ok "an unknown session: refused by name, nothing recorded" || bad "unknown session ($rc): $out"
out=$("$SALA" model sala-test-nope --clear 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q "unknown session 'sala-test-nope'" <<< "$out" && ok "--clear on an unknown session with no row: refused" || bad "clear unknown ($rc): $out"

echo "== two panes on the fake claude, launched by hand"
mk a "$U1"; mk b "$U2"; fake_up sala-test-a sala-test-b
out=$("$SALA" model sala-test-a sonnet --effort ultra 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q "invalid effort 'ultra'" <<< "$out" && ok "--effort ultra: refused, naming the levels" || bad "bad effort ($rc): $out"
out=$("$SALA" model sala-test-a gpt-5 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q "unknown model 'gpt-5'" <<< "$out" && ok "an unknown model: refused" || bad "bad model ($rc): $out"
out=$("$SALA" model sala-test-a sonnet --effort 2>&1); rc=$?
[ "$rc" = 1 ] && ok "--effort with no level: refused" || bad "--effort alone ($rc): $out"
[ ! -e "$SALA_MODELS" ] && [ "$(starts "$U1")" = 1 ] && ok "after the refusals: nothing recorded, nothing relaunched" || bad "after refusals: $(slurp "$SALA_MODELS"), starts $(starts "$U1")"

echo "== --dry-run: writes nothing, relaunches nothing"
out=$("$SALA" model sala-test-a sonnet --effort medium --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'DRY RUN: nothing recorded' <<< "$out" && grep -qF '[dry-run] would record sala-test-a → sonnet/medium' <<< "$out" && grep -q 'would /exit' <<< "$out" && ok "exit 0, the row it would record, the sweep's verdict" || bad "dry run ($rc): $out"
[ ! -e "$SALA_MODELS" ] && [ ! -e "$SALA_MODEL_LOG" ] && ok "no models.tsv, no models.log" || bad "dry run wrote: $(cat "$SALA_MODELS" "$SALA_MODEL_LOG" 2>/dev/null)"
sleep 2; [ "$(starts "$U1")" = 1 ] && ! proc_args "$(cpid a)" | grep -q -- '--model' && ok "sala-test-a not relaunched" || bad "dry run relaunched: starts $(starts "$U1")"

echo "== sala model <session> sonnet --effort medium: recorded, relaunched on them"
out=$("$SALA" model sala-test-a sonnet --effort medium 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'recorded: sala-test-a → sonnet/medium' <<< "$out" && ok "exit 0, recorded" || bad "sala model ($rc): $out"
waitfor '[ "$(starts "$U1")" = 2 ]' 40 && ok "sala-test-a relaunched" || bad "no relaunch: $(<"$FAKE_LOG"); $(tail -20 "$RLOG")"
wait_lock; fake_up sala-test-a
a=$(proc_args "$(cpid a)")
case "$a" in *"--resume $U1 --model sonnet --effort medium"*) ok "its claude runs with --model sonnet --effort medium (the transcript says opus/high)" ;; *) bad "args: $a" ;; esac
[ "$(row sala-test-a)" = sonnet/medium ] && ok "the row: sala-test-a sonnet medium" || bad "row: $(<"$SALA_MODELS")"
[ "$(starts "$U2")" = 1 ] && [ -z "$(row sala-test-b)" ] && ok "sala-test-b untouched, unrecorded" || bad "b: starts $(starts "$U2"), row '$(row sala-test-b)'"
out=$("$SALA" model sala-test-a sonnet --effort medium 2>&1); rc=$?
sleep 2; [ "$rc" = 0 ] && grep -q 'left alone' <<< "$out" && [ "$(starts "$U1")" = 2 ] && ok "the same pair again: left alone, no relaunch" || bad "same pair ($rc): $out; starts $(starts "$U1")"
"$SALA" model | grep -qE '^sala-test-a +sonnet/medium +sonnet/medium +opus/high' && ok "the table: recorded, launched with, the transcript's last turn" || bad "table: $("$SALA" model)"

echo "== a later relaunch keeps the record"
"$SALA" revive --force --only sala-test-a >/dev/null 2>&1 || bad "revive --only did not run"
waitfor '[ "$(starts "$U1")" = 3 ]' 40 && ok "relaunched by revive --force --only" || bad "no relaunch: $(tail -20 "$RLOG")"
wait_lock; fake_up sala-test-a
case "$(proc_args "$(cpid a)")" in *"--model sonnet --effort medium"*) ok "and back on sonnet/medium" ;; *) bad "args after revive: $(proc_args "$(cpid a)")" ;; esac

echo "== --clear"
out=$("$SALA" model sala-test-a --clear --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'would drop' <<< "$out" && [ "$(row sala-test-a)" = sonnet/medium ] && ok "--clear --dry-run: the row stays" || bad "clear dry run ($rc): $out / $(row sala-test-a)"
out=$("$SALA" model sala-test-a --clear 2>&1); rc=$?
sleep 2; [ "$rc" = 0 ] && [ -z "$(row sala-test-a)" ] && [ "$(starts "$U1")" = 3 ] && ok "--clear: the row gone, nothing relaunched" || bad "clear ($rc): $out / row '$(row sala-test-a)', starts $(starts "$U1")"
[ "$(resume_cmd "$U1" sala-test-a)" = "$(mod_env_prefix)claude --resume $U1 --model opus --effort high" ] && ok "the transcript decides again" || bad "after clear: $(resume_cmd "$U1" sala-test-a)"
out=$("$SALA" model sala-test-a --clear 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'no model recorded' <<< "$out" && ok "--clear with no row: says so, exit 0" || bad "clear again ($rc): $out"

echo "== --record-only: the row alone, no relaunch"
# a copy of the entry point whose lib/revive.sh is a stub that logs its arguments: bin/salamander sets SALA_BIN and
# SALA_ROOT from its own path, so this root is the only way to see every revive call the verb makes
STUB="$HOME/stubroot"; RCALLS="$HOME/revive-calls.txt"; mkdir -p "$STUB/bin" "$STUB/lib"; cp "$ROOT/bin/salamander" "$STUB/bin/salamander"
for f in "$ROOT"/lib/*; do ln -s "$f" "$STUB/lib/$(basename "$f")"; done; ln -s "$ROOT/mod" "$STUB/mod"
rm -f "$STUB/lib/revive.sh"; printf 'echo "revive $*" >> "%s"; exit 0\n' "$RCALLS" > "$STUB/lib/revive.sh"
SSALA="$STUB/bin/salamander"
wait_lock; pa=$(cpid a); sa=$(starts "$U1")
out=$("$SSALA" model sala-test-a sonnet --effort low --record-only 2>&1); rc=$?
[ "$rc" = 0 ] && grep -qF 'recorded: sala-test-a → sonnet/low' <<< "$out" && grep -qF '(not relaunched; takes effect at its next relaunch)' <<< "$out" && [ "$(row sala-test-a)" = sonnet/low ] && ok "a live session: exit 0, the row sonnet/low recorded" || bad "record-only ($rc): $out / row '$(row sala-test-a)'"
sleep 2; [ ! -s "$RCALLS" ] && [ "$(starts "$U1")" = "$sa" ] && [ "$(cpid a)" = "$pa" ] && ok "no revive call (the stub saw none), its claude untouched" || bad "record-only relaunched: calls '$(slurp "$RCALLS")', starts $(starts "$U1") (was $sa)"
out=$("$SSALA" model sala-test-b haiku 2>&1); rc=$?
grep -qF 'revive --force --only sala-test-b' "$RCALLS" 2>/dev/null && ok "control: without --record-only the same root calls revive --force --only (the stub sees it)" || bad "control ($rc): $out / calls '$(slurp "$RCALLS")'"
model_drop sala-test-b; : > "$RCALLS"
cp "$SALA_MODELS" "$HOME/models.before"; ll=$(wc -l < "$SALA_MODEL_LOG")
printf 'sala-test-c\t%s\tsala-test-c\t%s\n' "$UX" "$HOME" >> "$SALA_SIDECAR"   # a pane-map row, no tmux session (a stale or asleep one)
out=$("$SSALA" model sala-test-c haiku --effort low --record-only --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && grep -qF '[dry-run] would record sala-test-c → haiku/low' <<< "$out" && grep -qF 'sala-test-c haiku low' <<< "$out" && ok "--dry-run: exit 0, the row it would write" || bad "record-only dry run ($rc): $out"
same_file "$SALA_MODELS" "$HOME/models.before" && [ "$(wc -l < "$SALA_MODEL_LOG")" = "$ll" ] && [ ! -s "$RCALLS" ] && ok "--dry-run: models.tsv and models.log unchanged, no revive call" || bad "record-only dry run wrote: $(<"$SALA_MODELS"); calls '$(slurp "$RCALLS")'"
out=$("$SSALA" model sala-test-nope sonnet --record-only 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q "unknown session 'sala-test-nope'" <<< "$out" && [ -z "$(row sala-test-nope)" ] && ok "a name sala has never seen: refused, nothing recorded" || bad "record-only unknown ($rc): $out"
out=$("$SSALA" model sala-test-c haiku --effort low --record-only 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(row sala-test-c)" = haiku/low ] && [ ! -s "$RCALLS" ] && grep -q 'no tmux session now' <<< "$out" && ok "known by the pane map, no tmux session: accepted, recorded, no revive call" || bad "record-only map-known ($rc): $out / row '$(row sala-test-c)'"
model_write sala-test-r opus; out=$("$SSALA" model sala-test-r sonnet --record-only 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(row sala-test-r)" = sonnet/- ] && ok "known by its own model row alone: accepted" || bad "record-only row-known ($rc): $out"; model_drop sala-test-r
out=$("$SSALA" model sala-test-a --clear --record-only 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'takes no --record-only' <<< "$out" && [ "$(row sala-test-a)" = sonnet/low ] && ok "--clear --record-only: an error, the row stays" || bad "clear+record-only ($rc): $out"
"$SALA" model | grep -qE '^sala-test-c +haiku/low +- +- +no tmux session' && ok "the table shows the recorded row of a session with no tmux session" || bad "table: $("$SALA" model)"
[ "$(resume_cmd "$UX" sala-test-c)" = "$(mod_env_prefix)claude --resume $UX --model haiku --effort low" ] && ok "its next resume line carries the record (resume_cmd)" || bad "resume_cmd after record-only: $(resume_cmd "$UX" sala-test-c)"
"$SALA" revive --force --only sala-test-a >/dev/null 2>&1 || bad "revive --only did not run"
waitfor '[ "$(starts "$U1")" = $((sa+1)) ]' 40 && ok "a later relaunch of sala-test-a (revive --force --only)" || bad "no relaunch: $(tail -20 "$RLOG")"
wait_lock; fake_up sala-test-a
case "$(proc_args "$(cpid a)")" in *"--resume $U1 --model sonnet --effort low"*) ok "comes back on the recorded sonnet/low" ;; *) bad "args after record-only + revive: $(proc_args "$(cpid a)")" ;; esac
model_drop sala-test-c; awk -F'\t' '$1!="sala-test-c"' "$SALA_SIDECAR" > "$SALA_SIDECAR.t" && mv -f "$SALA_SIDECAR.t" "$SALA_SIDECAR"

echo "== the batch: model <model> [--effort <level>] <session>… — one lock, one sweep, one summary"
# the same stub root: its revive.sh logs every call, so ONE call naming both panes is visible (two calls would be the old way, once per session)
wait_lock; model_drop sala-test-a; model_drop sala-test-b; : > "$RCALLS"; sa=$(starts "$U1"); sb=$(starts "$U2")
out=$("$SSALA" model haiku --effort low sala-test-a sala-test-nope sala-test-b 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q "unknown session 'sala-test-nope'" <<< "$out" && [ -z "$(row sala-test-a)" ] && [ -z "$(row sala-test-b)" ] && [ ! -s "$RCALLS" ] \
    && ok "batch with one unknown session: the whole batch refused by name, no row written, no revive call" || bad "batch unknown ($rc): $out / rows '$(row sala-test-a)' '$(row sala-test-b)' / calls '$(slurp "$RCALLS")'"
out=$("$SSALA" model haiku --effort ultra sala-test-a sala-test-b 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q "invalid effort 'ultra'" <<< "$out" && [ -z "$(row sala-test-a)" ] && ok "batch with a bad effort: refused before anything is recorded" || bad "batch bad effort ($rc): $out"
out=$("$SSALA" model haiku --effort low sala-test-a sala-test-b --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'model batch: 2 session(s) → haiku/low — DRY RUN' <<< "$out" && grep -qF '[dry-run] would record sala-test-a → haiku/low' <<< "$out" && grep -qF '[dry-run] would record sala-test-b → haiku/low' <<< "$out" \
    && [ -z "$(row sala-test-a)" ] && ! grep -qv -e '--dry-run' "$RCALLS" && ok "batch --dry-run: the plan of each session, nothing written, no revive call but the dry runs'" || bad "batch dry run ($rc): $out"
: > "$RCALLS"
out=$("$SSALA" model haiku --effort low sala-test-a sala-test-b 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(row sala-test-a)" = haiku/low ] && [ "$(row sala-test-b)" = haiku/low ] && ok "batch: both rows recorded, exit 0" || bad "batch ($rc): $out / rows '$(row sala-test-a)' '$(row sala-test-b)'"
[ "$(grep -vc -e '--dry-run' "$RCALLS")" = 1 ] && [ "$(grep -v -e '--dry-run' "$RCALLS")" = "revive --force --only sala-test-a --only sala-test-b" ] && ok "ONE revive call for both panes (--only a --only b), not one per session" || bad "revive calls: '$(slurp "$RCALLS")'"
grep -qx 'RESULT sala-test-a: relaunch started on haiku/low (a busy pane is retried until it is idle)' <<< "$out" && grep -qx 'RESULT sala-test-b: relaunch started on haiku/low (a busy pane is retried until it is idle)' <<< "$out" \
    && [ "$(tail -1 <<< "$out")" = "model batch: 2 session(s) → haiku/low: 2 relaunching" ] && ok "a RESULT line per session, then the one summary line last" || bad "batch output: $out"
out=$("$SSALA" model haiku --effort low sala-test-a sala-test-b 2>&1); rc=$?
grep -qx 'RESULT sala-test-a: relaunch started on haiku/low (a busy pane is retried until it is idle)' <<< "$out" && ok "control: with in-place switching off every pane is relaunched, as the single shape does" || bad "batch again: $out"
: > "$RCALLS"
out=$("$SSALA" model sala-test-a haiku --effort low 2>&1); rc=$?
[ "$rc" = 0 ] && ! grep -q 'model batch' <<< "$out" && ! grep -q '^RESULT' <<< "$out" && [ "$(<"$RCALLS")" = "revive --force --only sala-test-a" ] && ok "the single-session shape <session> <model> is unchanged: no batch summary, its own revive call" || bad "single shape ($rc): $out / calls '$(slurp "$RCALLS")'"
out=$("$SSALA" model --clear sala-test-a sala-test-b 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$(row sala-test-a)" ] && [ -z "$(row sala-test-b)" ] && grep -q '^RESULT sala-test-a: record dropped (was haiku/low)' <<< "$out" && [ "$(tail -1 <<< "$out")" = "model batch: 2 session(s): 2 records dropped" ] \
    && ok "--clear with several sessions: both rows dropped, a line each, one summary" || bad "batch clear ($rc): $out / rows '$(row sala-test-a)' '$(row sala-test-b)'"
out=$("$SSALA" model --clear sala-test-a sala-test-nope 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q "unknown session 'sala-test-nope'" <<< "$out" && ok "--clear with an unknown session among them: refused" || bad "batch clear unknown ($rc): $out"
model_write sala-test-a opus; : > "$RCALLS"
out=$("$SSALA" model haiku --record-only sala-test-a sala-test-b 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(row sala-test-a)" = haiku/- ] && [ "$(row sala-test-b)" = haiku/- ] && [ ! -s "$RCALLS" ] && grep -q '^RESULT sala-test-b: recorded haiku' <<< "$out" && ok "--record-only goes with the batch: rows written, no revive call" || bad "batch record-only ($rc): $out / calls '$(slurp "$RCALLS")'"
model_drop sala-test-a; model_drop sala-test-b
wait_lock

echo "== retire drops the row"
model_write sala-test-b haiku low
"$SALA" retire sala-test-b --keep-web --busy >/dev/null 2>&1; [ -z "$(row sala-test-b)" ] && ok "retired: its model row is gone" || bad "row after retire: '$(row sala-test-b)'"

echo "== compact.tsv: --autocompact on a pane's launch line (lib/common.sh COMPACT WINDOW)"
model_drop sala-test-x 2>/dev/null; rm -f "$SALA_MODELS" "$SALA_COMPACT"; mkdir -p "$SALA_STATE_DIR"
base="$(mod_env_prefix)claude --resume $UX --model opus --effort high"
[ "$(resume_cmd "$UX" sala-test-x)" = "$base" ] && ok "no compact.tsv: no flag, the line as before" || bad "no file: $(resume_cmd "$UX" sala-test-x)"
printf '# a comment\nsala-test-x\t150000\n' > "$SALA_COMPACT"
[ "$(resume_cmd "$UX" sala-test-x)" = "$base --autocompact 150000" ] && ok "a row: --autocompact 150000 on the resume line (a comment line above is no row)" || bad "row: $(resume_cmd "$UX" sala-test-x)"
[ "$(resume_cmd "$UX" sala-test-y)" = "$base" ] && [ "$(resume_cmd "$UX")" = "$base" ] && ok "another session, or none named: no flag (the project setting applies)" || bad "row leaked: $(resume_cmd "$UX" sala-test-y)"
model_write sala-test-x sonnet medium
[ "$(resume_cmd "$UX" sala-test-x)" = "$(mod_env_prefix)claude --resume $UX --model sonnet --effort medium --autocompact 150000" ] && ok "with a model row too: both on the line" || bad "model + compact: $(resume_cmd "$UX" sala-test-x)"
[ "$(resume_cmd "$UX" sala-test-x parked)" = "$(mod_env_prefix)claude --resume $UX --name sala-test-x --model sonnet --effort medium --autocompact 150000" ] && ok "a parked revive (--name) carries it as well" || bad "parked: $(resume_cmd "$UX" sala-test-x parked)"
model_drop sala-test-x
f0=$fail; for v in 100000 1000000 999999; do printf 'sala-test-x\t%s\n' "$v" > "$SALA_COMPACT"; [ "$(resume_cmd "$UX" sala-test-x)" = "$base --autocompact $v" ] || bad "good value $v: $(resume_cmd "$UX" sala-test-x)"; done; [ "$fail" = "$f0" ] && ok "100000, 999999 and 1000000 (the CLI's 100k–1M) pass"
f0=$fail; for v in 0 5000 99999 1000001 2000000 abc 150k 1.5e5 -150000 0150000 ' 150000' '150000 ' '150000 --x' '15000;rm' '$(id)' ''; do
    printf 'sala-test-x\t%s\n' "$v" > "$SALA_COMPACT"
    [ "$(resume_cmd "$UX" sala-test-x)" = "$base" ] || bad "bad value '$v' reached the line: $(resume_cmd "$UX" sala-test-x)"
done; [ "$fail" = "$f0" ] && ok "a hand-edited bad value (outside 100000–1000000, not digits, a shell word): ignored, never typed"
printf 'sala-test-x\n' > "$SALA_COMPACT"; [ "$(resume_cmd "$UX" sala-test-x)" = "$base" ] && ok "a row with no tokens column: no flag" || bad "one column: $(resume_cmd "$UX" sala-test-x)"
compact_valid 150000 && ! compact_valid 99999 && ! compact_valid '' && ok "compact_valid: whole numbers 100000–1000000 only" || bad "compact_valid"
printf 'sala-test-x\t150000\n' > "$SALA_COMPACT"; lane_write sala-test-x sdk; SDKNOW=1800000000   # no refusal on record: the sdk row launches on sdk at any clock
r=$(SALA_LANE_SDK_NOW=$SDKNOW resume_cmd "$UX" sala-test-x)
[ "$r" = "$SALA_BIN sdk-pane $UX sala-test-x --model opus --effort high" ] && ok "the sdk lane's pane program: no --autocompact, even with a row" || bad "sdk line: $r"
lane_drop sala-test-x

echo "== compact.tsv: the pane's claude really runs with it (revive), and a plain spawn"
printf 'sala-test-a\t150000\n' > "$SALA_COMPACT"; sa=$(starts "$U1")
"$SALA" revive --force --only sala-test-a >/dev/null 2>&1 || bad "revive --only did not run"
waitfor '[ "$(starts "$U1")" = $((sa+1)) ]' 40 && ok "sala-test-a relaunched by revive --force --only" || bad "no relaunch: $(tail -20 "$RLOG")"
wait_lock; fake_up sala-test-a
case "$(proc_args "$(cpid a)")" in *"--resume $U1"*" --autocompact 150000"*) ok "its claude runs with --autocompact 150000" ;; *) bad "args after revive: $(proc_args "$(cpid a)")" ;; esac
tmux set-environment -g FAKE_LOG "$FAKE_LOG"
spawn_c() { tmux set-environment -g FAKE_SESSION_ID "$2"; tmux set-environment -g FAKE_NAME "sala-test-$1"; "$SALA" spawn "sala-test-$1" --cwd "$HOME" 2>&1; }   # <suffix> <uuid>
printf 'sala-test-sp1\t150000\nsala-test-sp3\t5000\n' > "$SALA_COMPACT"
out=$(spawn_c sp1 "$(uuid 21)"); rc=$?
[ "$rc" = 0 ] && case "$(proc_args "$(cpid sp1)")" in *" --autocompact 150000"*) ok "spawn of a session with a row: --autocompact 150000 on its claude" ;; *) bad "spawn args: $(proc_args "$(cpid sp1)")" ;; esac || bad "spawn sp1 ($rc): $out"
out=$(spawn_c sp2 "$(uuid 22)"); rc=$?
[ "$rc" = 0 ] && case "$(proc_args "$(cpid sp2)")" in *autocompact*) bad "spawn without a row got the flag: $(proc_args "$(cpid sp2)")" ;; *) ok "spawn of a session with no row: no flag" ;; esac || bad "spawn sp2 ($rc): $out"
out=$(spawn_c sp3 "$(uuid 23)"); rc=$?
[ "$rc" = 0 ] && case "$(proc_args "$(cpid sp3)")" in *autocompact*) bad "spawn with a bad row got the flag: $(proc_args "$(cpid sp3)")" ;; *) ok "spawn with a bad row (5000): no flag, the pane comes up" ;; esac || bad "spawn sp3 ($rc): $out"
rm -f "$SALA_COMPACT"

echo "== install.sh seeds compact.tsv from contrib/compact.tsv, once"
IH="$HOME/inst-home"; mkdir -p "$IH"; ITSV="$IH/.local/state/salamander/compact.tsv"
HOME="$IH" BIN_DIR="$IH/bin" bash "$ROOT/install.sh" >/dev/null 2>&1
same_file "$ITSV" "$ROOT/contrib/compact.tsv" && ok "a fresh box: the state file is the shipped table" || bad "seed: $(cat "$ITSV" 2>&1)"
rows=$(grep -vc '^[[:space:]]*\(#\|$\)' "$ROOT/contrib/compact.tsv"); [ "$rows" = 0 ] && ok "the shipped file has no data rows (a window is a row added to the live file)" || bad "shipped data rows: $rows"
nc=$(grep -v '^[[:space:]]*$' "$ROOT/contrib/compact.tsv" | grep -vc '^#'); [ "$nc" = 0 ] && grep -q '^#' "$ROOT/contrib/compact.tsv" && ok "every non-blank line of the shipped file is a # comment, and there are comments" || bad "a non-comment line in the shipped file: $nc"
SALA_STATE_DIR="$HOME/.local/state/salamander"; SALA_COMPACT="$SALA_STATE_DIR/compact.tsv"
printf 'my-own\t120000\n' > "$ITSV"; HOME="$IH" BIN_DIR="$IH/bin" bash "$ROOT/install.sh" >/dev/null 2>&1
[ "$(cat "$ITSV")" = "$(printf 'my-own\t120000')" ] && ok "a second install leaves a hand-edited file alone" || bad "overwritten: $(cat "$ITSV")"

[ "$fail" = 0 ] && echo "models: pass" || echo "models: FAIL"
exit $fail
