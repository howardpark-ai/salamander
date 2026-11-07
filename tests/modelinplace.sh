#!/usr/bin/env bash
# The in-place model switch (lib/model.sh "SWITCHED IN PLACE FIRST", lib/common.sh
# "THE IN-PLACE SWITCH"): `sala model <session> <model> [--effort <level>]` on a pane that is idle with an empty input box types
# `/model <value>` and `/effort <level>` into its composer instead of relaunching it, then puts the saved defaults in the lane's
# settings.json back (Claude Code saves each command as the default: the top-level `model`, `modelSettings.<id>.effortLevel`).
# Against the fake claude (tests/fake-claude.c, FAKE_MODEL_MODE) answering as Claude Code 2.1.310 does when probed: a "Switch model?"
# dialog when the value differs from the last turn's (text typed into it swallowed, Enter confirms, Esc keeps), a "Set model to" /
# "Set effort level to" line, the default written to settings.json (tests/fake-settings.py). NOT tested here: a real claude (the
# live probe was made by hand), and whether a real CLI re-reads a settings.json we have restored under a running session.
# Checked: idle + empty box → switched in place (same process and pid, the record written first, the keys typed, Enter sent only
# on the dialog, settings.json byte for byte as before, the pair remembered so a second request is left alone and the table marks
# it); no dialog when the model is the same as the last turn's; busy → relaunch (nothing typed, settings untouched); a draft in the
# box → nothing typed and the draft kept; a dialog that is not "Switch model?" → Escape only, no Enter, relaunch; a command that
# never confirms → relaunch, defaults restored; a default saved with no confirmation line, and an effort the model refuses after the
# model switched → restored on the failure path; the subscription-2 lane's own settings.json restored, the default lane's untouched; the
# settings helpers alone (snapshot and compare-and-restore: a key somebody else changed meanwhile kept, nothing differs → no
# write, the write atomic with the mode kept and no temp file left, a failed write leaving the file as it was, an unreadable file
# refused, a file that did not exist removed again); --dry-run saying which path applies and writing nothing; the queue's plan
# (`op --plan`) saying so for the asking session; SALA_MODEL_INPLACE=off. A batch mixing an in-place switch and a pane left for the one sweep.
# Isolated HOME, a private tmux socket, the compiled fake claude. Usage: bash tests/modelinplace.sh   (exit 0 = pass; ~90 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_SET SALA_SET_SELF SALA_POST_RECYCLE_CMD SALA_RECYCLE SALA_RETRY_WORKER SALA_NO_RELAUNCH SALA_MASTER SALA_OP_PLAN SALA_OP_FROM
unset ANTHROPIC_API_KEY ANTHROPIC_CUSTOM_HEADERS CLAUDE_CONFIG_DIR
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, tmux_socket_rm
export SALA_MODEL_INPLACE=on SALA_MODEL_INPLACE_WAIT=8 SALA_MODEL_INPLACE_SETTLE=0.3   # lib.sh turns the switch off for the other suites
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$HOME/.claude-team"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$HOME/.local/share/claude/versions/9.9.9" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
ln -s "$HOME/.local/share/claude/versions/9.9.9" "$HOME/.local/bin/claude"
printf '#!/bin/sh\necho "$*" >> "%s/systemd-run.txt"\n' "$HOME" > "$HOME/.local/bin/systemd-run"; chmod +x "$HOME/.local/bin/systemd-run"
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log" FAKE_TYPED_LOG="$HOME/typed.log" FAKE_KEY_LOG="$HOME/keys.log" FAKE_SETTINGS_PY="$ROOT/tests/fake-settings.py"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off SALA_RETRY_EVERY=2 SALA_RETRY_WINDOW=60
SALA="$ROOT/bin/salamander"; SOCK="sala-modelinplace-$$"; T="tmux -L $SOCK -f /dev/null"; RLOG="$HOME/.claude/salamander-revive.log"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's
cleanup() {
    local f p; for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    for p in $(pgrep -x claude); do [ "$HOME/.local/share/claude/versions/9.9.9" -ef "/proc/$p/exe" ] && kill -9 "$p" 2>/dev/null; done
    chmod -R u+rwx "$HOME" 2>/dev/null; rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux    # literal socket: the children run set -u
. "$ROOT/lib/common.sh"
wait_lock() { lock_wait "$HOME/.claude/salamander-recycle.lock" 80; }
mk() { local n="$1" u="$2"; shift 2; $T new-session -d -s "sala-test-$n" -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="sala-test-$n" -e FAKE_LOG="$FAKE_LOG" "$@"; $T send-keys -t "sala-test-$n" 'claude' Enter; }
row() { model_row "$1" | tr '\t' /; }                                             # <session> → "model/effort", or nothing
typed() { local n; n=$(grep -c "^$1 $2" "$FAKE_TYPED_LOG" 2>/dev/null); echo "${n:-0}"; }   # <uuid> <line prefix> → how many such lines reached its composer
keys() { grep "^$1 " "$FAKE_KEY_LOG" 2>/dev/null | cut -d' ' -f2- | paste -sd';' -; }   # <uuid> → "<dialog> <key>;…"
regstatus() { local c; c=$(cpid "${1#sala-test-}"); set_reg_status "$c" "$2"; }
arec() { printf '{"type":"assistant","isSidechain":false,"message":{"model":"%s","role":"assistant","content":[{"type":"text","text":"x"}]},"effort":"%s","sessionId":"%s"}\n' "$2" "$3" "$1"; }
SET="$HOME/.claude/settings.json"; TSET="$HOME/.claude-team/settings.json"
mkset() {  # <file> → a settings.json as the CLI writes it, with keys of every kind around the two that /model and /effort change
    python3 - "$1" <<'PY'
import json, sys
d = {"theme": "dark", "model": "opus", "permissions": {"allow": ["Bash(ls:*)"], "deny": []}, "modelSettings": {"opus": {"effortLevel": "high", "keep": 1}, "haiku": {"effortLevel": "low"}},
     "note": "héllo", "n": 3, "flag": True}
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PY
    chmod 600 "$1"
}
mkset "$SET"; cp -p "$SET" "$HOME/settings.orig"; mkset "$TSET"; cp -p "$TSET" "$HOME/tsettings.orig"
same_as() { same_file "$1" "$2"; }                                                   # byte for byte
for n in 1 2 3 4 5 6 7 8 9 10 11; do u=$(uuid $n); { arec "$u" claude-opus-5 high; arec "$u" claude-opus-5 high; } > "$HOME/.claude/projects/x/$u.jsonl"; done

echo "== setup: panes on the fake claude, each answering /model in its own way"
mk a  "$(uuid 1)"  -e FAKE_MODEL_MODE=ok
mk b  "$(uuid 2)"  -e FAKE_MODEL_MODE=nodialog
mk c  "$(uuid 3)"  -e FAKE_MODEL_MODE=ok
mk d  "$(uuid 4)"  -e FAKE_MODEL_MODE=ok
mk e  "$(uuid 5)"  -e FAKE_MODEL_MODE=weird
mk f  "$(uuid 6)"  -e FAKE_MODEL_MODE=silent
mk g  "$(uuid 7)"  -e FAKE_MODEL_MODE=writeonly
mk h  "$(uuid 8)"  -e FAKE_MODEL_MODE=effortfail
mk t  "$(uuid 9)"  -e FAKE_MODEL_MODE=ok -e CLAUDE_CONFIG_DIR="$HOME/.claude-team"
mk k  "$(uuid 10)" -e FAKE_MODEL_MODE=ok -e FAKE_MODEL_START=sonnet
fake_up sala-test-a sala-test-b sala-test-c sala-test-d sala-test-e sala-test-f sala-test-g sala-test-h sala-test-t sala-test-k || exit 1
U1=$(uuid 1); U2=$(uuid 2); U3=$(uuid 3); U4=$(uuid 4); U5=$(uuid 5); U6=$(uuid 6); U7=$(uuid 7); U8=$(uuid 8); U9=$(uuid 9); U10=$(uuid 10)

echo "== the settings helpers alone: snapshot and compare-and-restore"
W="$HOME/hw"; mkdir -p "$W"; S="$W/settings.json"; SN="$W/snap"
mkset "$S"; cp -p "$S" "$W/orig"
model_settings_snapshot "$S" "$SN" && ok "snapshot of a settings.json: written" || bad "snapshot failed"
out=$(model_settings_restore "$S" "$SN"); rc=$?
[ "$rc" = 0 ] && [ "$out" = unchanged ] && ok "nothing differs: 'unchanged', exit 0" || bad "restore, nothing changed ($rc): $out"
ino=$(stat -c %i "$S"); mt=$(stat -c %Y.%y "$S")
model_settings_restore "$S" "$SN" >/dev/null; [ "$(stat -c %i "$S")" = "$ino" ] && [ "$(stat -c %Y.%y "$S")" = "$mt" ] && ok "and then no write at all: same inode, same mtime" || bad "a no-op restore wrote the file"
python3 "$ROOT/tests/fake-settings.py" "$W" model sonnet; python3 "$ROOT/tests/fake-settings.py" "$W" effort sonnet medium; python3 "$ROOT/tests/fake-settings.py" "$W" effort opus xhigh
out=$(model_settings_restore "$S" "$SN"); rc=$?
[ "$rc" = 0 ] && has "$out" restored && has "$out" model && has "$out" "effort(opus)" && has "$out" "effort(sonnet)" && same_as "$S" "$W/orig" && ok "after /model sonnet, /effort on two ids: restored byte for byte ($out)" || bad "restore ($rc): $out / $(diff "$W/orig" "$S")"
[ "$(stat -c %a "$S")" = 600 ] && ok "the file's mode (600) kept" || bad "mode: $(stat -c %a "$S")"
[ -z "$(ls -A "$W" | grep -F '.settings.json.sala-')" ] && ok "no temp file left beside it" || bad "temp files: $(ls -A "$W")"
[ "$(stat -c %i "$S")" != "$ino" ] && ok "the write was a rename over the file (a new inode: atomic), never an in-place rewrite" || bad "same inode after a restore"
# somebody else changes another key (and the model) while we wait: their other key stays, the model goes back
python3 "$ROOT/tests/fake-settings.py" "$W" model sonnet
python3 - "$S" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p, encoding="utf-8")); d["theme"] = "light"; d["added"] = {"x": 1}
open(p, "w", encoding="utf-8").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PY
out=$(model_settings_restore "$S" "$SN"); rc=$?
python3 - "$S" <<'PY' && ok "a key somebody else changed meanwhile (theme, a new one) is kept; only model went back" || bad "restore beside a foreign change: $(<"$S")"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["theme"] == "light" and d["added"] == {"x": 1} and d["model"] == "opus" and d["modelSettings"]["opus"] == {"effortLevel": "high", "keep": 1} and d["note"] == "héllo", d
PY
# an id and a modelSettings that did not exist before are removed again, an effort that did exist comes back
mkset "$S"; python3 - "$S" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p, encoding="utf-8")); del d["modelSettings"]; del d["model"]
open(p, "w", encoding="utf-8").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PY
cp -p "$S" "$W/orig2"; model_settings_snapshot "$S" "$SN"
python3 "$ROOT/tests/fake-settings.py" "$W" model haiku; python3 "$ROOT/tests/fake-settings.py" "$W" effort haiku max
out=$(model_settings_restore "$S" "$SN"); same_as "$S" "$W/orig2" && ok "a model and a modelSettings that were not there are gone again, byte for byte" || bad "absent keys not removed ($out): $(diff "$W/orig2" "$S")"
# a settings.json written with tabs / compact: the layout is kept
printf '{\n\t"model": "opus",\n\t"theme": "dark"\n}\n' > "$S"; cp -p "$S" "$W/orig3"; model_settings_snapshot "$S" "$SN"
python3 - "$S" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["model"] = "sonnet"; open(p, "w").write(json.dumps(d, indent="\t") + "\n")
PY
model_settings_restore "$S" "$SN" >/dev/null; same_as "$S" "$W/orig3" && ok "a tab-indented file keeps its tabs" || bad "tab layout: $(cat -A "$S")"
# a write that cannot happen leaves the file as it was
mkset "$S"; model_settings_snapshot "$S" "$SN"; python3 "$ROOT/tests/fake-settings.py" "$W" model sonnet; cp -p "$S" "$W/changed"; chmod 500 "$W"
out=$(model_settings_restore "$S" "$SN"); rc=$?; chmod 700 "$W"
[ "$rc" = 4 ] && has "$out" "write failed" && same_as "$S" "$W/changed" && ok "a directory that cannot be written: exit 4, the file exactly as it was" || bad "failed write ($rc): $out"
# unreadable file: snapshot refuses; a file that did not exist is removed again
printf 'not json' > "$S"; out=$(model_settings_snapshot "$S" "$SN"); rc=$?
[ "$rc" = 3 ] && has "$out" unreadable && same_as "$S" <(printf 'not json') && ok "a settings.json that is not JSON: snapshot refuses (exit 3), nothing touched" || bad "unreadable ($rc): $out"
rm -f "$S"; model_settings_snapshot "$S" "$SN"; python3 "$ROOT/tests/fake-settings.py" "$W" model sonnet; [ -f "$S" ] || bad "fake did not create the file"
out=$(model_settings_restore "$S" "$SN"); [ ! -e "$S" ] && has "$out" removed && ok "a settings.json that did not exist before: removed again" || bad "created file stays ($out): $(slurp "$S")"
ln -s "$W/real.json" "$W/link.json"; mkset "$W/real.json"; model_settings_snapshot "$W/link.json" "$SN"; python3 "$ROOT/tests/fake-settings.py" "$W" model sonnet >/dev/null 2>&1
python3 - "$W/real.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p, encoding="utf-8")); d["model"] = "sonnet"; open(p, "w", encoding="utf-8").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PY
model_settings_restore "$W/link.json" "$SN" >/dev/null; [ -L "$W/link.json" ] && grep -q '"model": "opus"' "$W/real.json" && ok "a symlinked settings.json: the target is restored, the link stays a link" || bad "symlink: $(ls -l "$W")"
model_config_dir "$(cpid t)" sala-test-t | grep -qx "$HOME/.claude-team" && model_config_dir "$(cpid a)" sala-test-a | grep -qx "$HOME/.claude" && ok "model_config_dir: the team pane's own CLAUDE_CONFIG_DIR, else ~/.claude" || bad "config dirs: $(model_config_dir "$(cpid t)" x) / $(model_config_dir "$(cpid a)" x)"

echo "== the plan says which path applies (--dry-run writes nothing)"
out=$("$SALA" model sala-test-a sonnet --effort medium --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "[dry-run] would switch in place: /model sonnet, /effort medium typed into the idle pane" && has "$out" "$HOME/.claude/settings.json" && ! has "$out" "revive --force" && ok "idle pane, empty box: 'would switch in place' (and which settings.json it puts back)" || bad "dry run idle ($rc): $out"
[ ! -e "$SALA_MODELS" ] && [ ! -e "$SALA_MODEL_LOG" ] && [ "$(typed "$U1" /model)" = 0 ] && ok "and nothing recorded, nothing typed" || bad "dry run wrote/typed: $(slurp "$SALA_MODELS") / $(slurp "$FAKE_TYPED_LOG")"
regstatus sala-test-c busy
out=$("$SALA" model sala-test-c sonnet --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "[dry-run] would relaunch — it cannot be switched in place: not idle" && has "$out" "revive --force --only sala-test-c" && ok "busy pane: 'would relaunch', with the reason and the sweep's verdict" || bad "dry run busy ($rc): $out"
out=$(SALA_OP_PLAN=1 SALA_OP_FROM=sala-test-c "$SALA" model sala-test-c sonnet --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "would switch in place once the pane is idle (the asking session" && ! has "$out" "would relaunch" && ok "the asking session, busy with this very turn: 'would switch in place once the pane is idle'" || bad "dry run asker ($rc): $out"
out=$(SALA_OP_PLAN=1 SALA_OP_FROM=sala-test-d "$SALA" model sala-test-c sonnet --dry-run 2>&1)
has "$out" "would relaunch — it cannot be switched in place: not idle" && ok "a busy pane that is not the asker: 'would relaunch'" || bad "dry run busy, other asker: $out"
regstatus sala-test-c idle
out=$(TMUX_PANE=$(tmux display -p -t sala-test-a '#{pane_id}') "$SALA" model sala-test-a sonnet --dry-run 2>&1)
has "$out" "would relaunch — it cannot be switched in place: this command's own pane" && has "$out" "revive --self" && ok "this command's own pane (a session run from inside): relaunched last by the self-worker, as before" || bad "dry run own pane: $out"
out=$(SALA_MODEL_INPLACE=off "$SALA" model sala-test-a sonnet --dry-run 2>&1)
has "$out" "would relaunch — it cannot be switched in place: in-place switching is off (SALA_MODEL_INPLACE=off)" && ok "SALA_MODEL_INPLACE=off: 'would relaunch'" || bad "dry run off: $out"
out=$("$SALA" op --plan model sala-test-a haiku --effort high 2>&1)
has "$out" "plan: salamander model sala-test-a haiku --effort high" && has "$out" "[dry-run] would switch in place" && has "$out" "plan only: nothing queued" && ok "sala op --plan: the same words reach the queue's plan" || bad "op plan: $out"
regstatus sala-test-c busy
out=$("$SALA" op --plan model sala-test-c haiku --from sala-test-c 2>&1)
has "$out" "would switch in place once the pane is idle (the asking session" && ok "sala op --plan for the asking session: 'once the pane is idle'" || bad "op plan asker: $out"
regstatus sala-test-c idle

echo "== idle pane, empty input box, a dialog: switched in place, same process, defaults as before"
pa=$(cpid a); sa=$(starts "$U1")
out=$("$SALA" model sala-test-a sonnet --effort medium 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "recorded: sala-test-a → sonnet/medium" && has "$out" "switched in place: sala-test-a runs on sonnet/medium" && ok "exit 0, recorded first, 'switched in place'" || bad "in-place switch ($rc): $out"
[ "$(cpid a)" = "$pa" ] && [ "$(starts "$U1")" = "$sa" ] && ok "the same claude process (pid $pa), not relaunched" || bad "relaunched: pid $pa → $(cpid a), starts $sa → $(starts "$U1")"
[ "$(typed "$U1" '/model sonnet')" = 1 ] && [ "$(typed "$U1" '/effort medium')" = 1 ] && ok "/model sonnet then /effort medium were typed into its composer" || bad "typed: $(grep "^$U1" "$FAKE_TYPED_LOG")"
[ "$(keys "$U1")" = "Switch model? enter" ] && ok "one key reached the dialog: Enter, on 'Switch model?'" || bad "dialog keys: '$(keys "$U1")'"
same_as "$SET" "$HOME/settings.orig" && ok "settings.json byte for byte as before (the CLI had saved sonnet and medium as the defaults)" || bad "settings changed: $(diff "$HOME/settings.orig" "$SET")"
has "$out" "saved defaults in $SET put back (restored: model, effort(opus)" || has "$out" "saved defaults in $SET put back" && ok "and the output says it put them back" || bad "no restore line: $out"
[ "$(row sala-test-a)" = sonnet/medium ] && ok "the record: sonnet/medium" || bad "row: $(row sala-test-a)"
[ "$(cut -f3,4 < <(grep "^$pa" "$SALA_MODEL_INPLACE_STATE"))" = $'sonnet\tmedium' ] && ok "the switch is remembered for that process (model-inplace.tsv)" || bad "state: $(slurp "$SALA_MODEL_INPLACE_STATE")"
"$SALA" model | grep -qE '^sala-test-a +sonnet/medium +sonnet/medium\* +' && ! "$SALA" model | grep -q 'a relaunch puts it on the record' && ok "the table: it runs sonnet/medium* (starred: switched in place), no 'a relaunch puts it…' note" || bad "table: $("$SALA" model)"
out=$("$SALA" model sala-test-a sonnet --effort medium 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "left alone" && [ "$(typed "$U1" /model)" = 1 ] && ok "the same pair again: left alone, nothing typed" || bad "same pair ($rc): $out"
out=$("$SALA" model sala-test-a opus 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "switched in place" && [ "$(typed "$U1" '/model opus')" = 1 ] && [ "$(typed "$U1" /effort)" = 1 ] && [ "$(cpid a)" = "$pa" ] && ok "and back to opus (no effort asked: only /model typed, the pair on the launch line is no longer what decides)" || bad "back to opus ($rc): $out / $(grep "^$U1" "$FAKE_TYPED_LOG")"
same_as "$SET" "$HOME/settings.orig" && ok "settings.json still as before" || bad "settings changed after the second switch: $(diff "$HOME/settings.orig" "$SET")"
[ "$(cut -f3,4 < <(grep "^$pa" "$SALA_MODEL_INPLACE_STATE"))" = $'opus\tmedium' ] && ok "the state keeps the effort it had switched to (medium) when only the model moved" || bad "state: $(<"$SALA_MODEL_INPLACE_STATE")"

echo "== no dialog (the model is the same as the last turn's): still switched, Enter never sent"
out=$("$SALA" model sala-test-b sonnet 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "switched in place" && [ -z "$(keys "$U2")" ] && [ "$(starts "$U2")" = 1 ] && same_as "$SET" "$HOME/settings.orig" && ok "switched, no key sent to any dialog, settings as before" || bad "nodialog ($rc): $out / keys '$(keys "$U2")'"
out=$("$SALA" model sala-test-k sonnet 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "switched in place" && [ -z "$(keys "$U10")" ] && ok "a pane already on the model the dialog would offer: no dialog, none answered" || bad "same model ($rc): $out / keys '$(keys "$U10")'"

echo "== the subscription-2 lane: its own settings.json is the one put back, the default lane's is not touched"
cp -p "$SET" "$HOME/settings.before"
out=$("$SALA" model sala-test-t haiku --effort low 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "switched in place" && has "$out" "saved defaults in $TSET put back" && ok "switched in place; the settings.json it puts back is the subscription-2 directory's" || bad "subscription-2 ($rc): $out"
same_as "$TSET" "$HOME/tsettings.orig" && same_as "$SET" "$HOME/settings.before" && ok "the subscription-2 settings.json as before, ~/.claude/settings.json untouched throughout" || bad "subscription-2 settings: $(diff "$HOME/tsettings.orig" "$TSET")"
[ "$(typed "$U9" '/model haiku')" = 1 ] && ok "typed into the subscription-2 pane" || bad "subscription-2 typed: $(grep "^$U9" "$FAKE_TYPED_LOG")"

echo "== busy pane: nothing typed, relaunched like before"
regstatus sala-test-c busy; sc=$(starts "$U3")
out=$("$SALA" model sala-test-c sonnet --effort medium 2>&1); rc=$?
has "$out" "not switched in place (not idle" && [ "$(typed "$U3" /)" = 0 ] && same_as "$SET" "$HOME/settings.orig" && ok "the reason printed, nothing typed, settings untouched" || bad "busy ($rc): $out / typed $(grep "^$U3" "$FAKE_TYPED_LOG")"
[ "$(row sala-test-c)" = sonnet/medium ] && [ "$(starts "$U3")" = "$sc" ] && ok "the record is written; the busy pane is not relaunched while it works (the retry worker holds it)" || bad "busy: row '$(row sala-test-c)', starts $(starts "$U3")"
regstatus sala-test-c idle
waitfor '[ "$(starts "$U3")" = $((sc+1)) ]' 80 && ok "idle again: relaunched by the retry worker" || bad "no relaunch of c: $(tail -10 "$RLOG")"
wait_lock; fake_up sala-test-c
case "$(proc_args "$(cpid c)")" in *"--resume $U3 --model sonnet --effort medium"*) ok "on --model sonnet --effort medium" ;; *) bad "c args: $(proc_args "$(cpid c)")" ;; esac

echo "== the asking session, from the queue's runner: waited for until its turn ends, then switched in place"
regstatus sala-test-c busy; pc=$(cpid c); sc=$(starts "$U3"); ( sleep 4; regstatus sala-test-c idle ) &
out=$(SALA_OP_ID=1760000000-1 SALA_OP_FROM=sala-test-c SALA_MODEL_INPLACE_ASKER_WAIT=20 "$SALA" model sala-test-c haiku --effort low 2>&1); rc=$?
wait
[ "$rc" = 0 ] && has "$out" "the asking session is still in its turn" && has "$out" "switched in place: sala-test-c runs on haiku/low" && [ "$(cpid c)" = "$pc" ] && [ "$(starts "$U3")" = "$sc" ] && same_as "$SET" "$HOME/settings.orig" \
    && ok "busy at first, idle 4 s later: switched in place, same process, settings as before" || bad "asker wait ($rc): $out / pid $pc → $(cpid c)"
regstatus sala-test-c busy
out=$(SALA_OP_ID=1760000000-2 SALA_OP_FROM=sala-test-d SALA_MODEL_INPLACE_ASKER_WAIT=20 "$SALA" model sala-test-c opus 2>&1)
! has "$out" "waiting up to" && has "$out" "not switched in place (not idle" && ok "a busy pane that is not the asker's own: not waited for" || bad "other asker waited: $out"
for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done; regstatus sala-test-c idle
wait_lock

echo "== a draft in the input box: nothing typed onto it, the draft kept"
tmux send-keys -t sala-test-d -l "half a sentence"; sleep 1
out=$("$SALA" model sala-test-d sonnet 2>&1); rc=$?
has "$out" "not switched in place (its input box holds unsent text)" && [ "$(typed "$U4" /)" = 0 ] && same_as "$SET" "$HOME/settings.orig" && ok "the reason printed, nothing typed, settings untouched" || bad "draft ($rc): $out / typed $(grep "^$U4" "$FAKE_TYPED_LOG")"
tmux capture-pane -p -t sala-test-d | grep -q 'half a sentence' && ok "and the draft is still in the box" || bad "draft gone: $(tmux capture-pane -p -t sala-test-d | tail -3)"
for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done; tmux send-keys -t sala-test-d C-u; sleep 0.5
wait_lock

echo "== a dialog that is not 'Switch model?': Escape only, never an Enter; relaunched"
se=$(starts "$U5")
out=$("$SALA" model sala-test-e sonnet --effort medium 2>&1); rc=$?
has "$out" "an unexpected dialog is on the screen" && has "$out" "relaunching instead" && ok "the failure named, the relaunch taken" || bad "weird dialog ($rc): $out"
[ "$(keys "$U5")" = "Do you want to apply this change? esc" ] && ok "the only key the dialog saw was Escape" || bad "weird keys: '$(keys "$U5")'"
same_as "$SET" "$HOME/settings.orig" && ok "settings.json untouched" || bad "settings: $(diff "$HOME/settings.orig" "$SET")"
waitfor '[ "$(starts "$U5")" = $((se+1)) ]' 40 && ok "and the pane was relaunched (the fallback)" || bad "no relaunch of e: $(tail -10 "$RLOG")"
wait_lock; fake_up sala-test-e
case "$(proc_args "$(cpid e)")" in *"--model sonnet --effort medium"*) ok "on the record: --model sonnet --effort medium" ;; *) bad "e args: $(proc_args "$(cpid e)")" ;; esac

echo "== a command that never confirms: Escape, defaults restored, relaunched"
sf_=$(starts "$U6")
out=$(SALA_MODEL_INPLACE_WAIT=3 "$SALA" model sala-test-f sonnet 2>&1); rc=$?
has "$out" "no new 'Set model to' line after '/model sonnet' within 3s" && has "$out" "relaunching instead" && ok "the failure named" || bad "silent ($rc): $out"
same_as "$SET" "$HOME/settings.orig" && ok "settings.json as before" || bad "settings: $(diff "$HOME/settings.orig" "$SET")"
waitfor '[ "$(starts "$U6")" = $((sf_+1)) ]' 40 && ok "relaunched" || bad "no relaunch of f: $(tail -10 "$RLOG")"
wait_lock; fake_up sala-test-f

echo "== the default saved but no confirmation line: the restore runs on the failure path"
sg=$(starts "$U7")
out=$(SALA_MODEL_INPLACE_WAIT=3 "$SALA" model sala-test-g sonnet --effort medium 2>&1); rc=$?
has "$out" "relaunching instead" && has "$out" "saved defaults in $SET put back" && ok "failure named, and the defaults put back" || bad "writeonly ($rc): $out"
same_as "$SET" "$HOME/settings.orig" && ok "settings.json as before (the CLI had saved sonnet as the default)" || bad "settings: $(diff "$HOME/settings.orig" "$SET")"
waitfor '[ "$(starts "$U7")" = $((sg+1)) ]' 40 && ok "relaunched" || bad "no relaunch of g: $(tail -10 "$RLOG")"
wait_lock; fake_up sala-test-g

echo "== the model switched, the effort refused: restored on the failure path, relaunched"
sh_=$(starts "$U8")
out=$("$SALA" model sala-test-h sonnet --effort high 2>&1); rc=$?
has "$out" "no new 'Set effort level to' line after '/effort high'" && has "$out" "saved defaults in $SET put back" && ok "the effort named as the failure, the defaults put back" || bad "effortfail ($rc): $out"
[ "$(typed "$U8" '/model sonnet')" = 1 ] && [ "$(typed "$U8" '/effort high')" = 1 ] && same_as "$SET" "$HOME/settings.orig" && ok "both typed; settings.json as before although the model had switched" || bad "effortfail: typed $(grep "^$U8" "$FAKE_TYPED_LOG"); $(diff "$HOME/settings.orig" "$SET")"
waitfor '[ "$(starts "$U8")" = $((sh_+1)) ]' 40 && ok "relaunched" || bad "no relaunch of h: $(tail -10 "$RLOG")"
wait_lock; fake_up sala-test-h

echo "== a batch: k idle is switched in place, d with a draft is left for the ONE sweep; one summary with a line each"
pk=$(cpid k); sk=$(starts "$U10"); wait_lock
tmux send-keys -t sala-test-d -l "half a sentence"; sleep 1
out=$("$SALA" model haiku --effort low sala-test-k sala-test-d 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "model batch: 2 session(s) → haiku/low" && has "$out" "RESULT sala-test-k: switched in place to haiku/low" && has "$out" "RESULT sala-test-d: relaunch started on haiku/low" \
    && [ "$(tail -1 <<< "$out")" = "model batch: 2 session(s) → haiku/low: 1 switched in place, 1 relaunching" ] && ok "exit 0: k switched in place, d handed to the sweep, the summary last" || bad "batch ($rc): $out"
[ "$(cpid k)" = "$pk" ] && [ "$(starts "$U10")" = "$sk" ] && [ "$(typed "$U10" '/model haiku')" = 1 ] && [ "$(typed "$U4" '/model haiku')" = 0 ] && ok "k: the same process, /model haiku typed; d: nothing typed onto its draft" || bad "batch panes: k pid $pk → $(cpid k), starts $sk → $(starts "$U10"), typed k $(typed "$U10" /model) d $(typed "$U4" /model)"
[ "$(row sala-test-k)" = haiku/low ] && [ "$(row sala-test-d)" = haiku/low ] && has "$out" "relaunch sweep: one revive for 1 pane(s)" && ok "both rows recorded; one sweep, for d alone (k needed none)" || bad "batch rows/sweep: '$(row sala-test-k)' '$(row sala-test-d)' / $out"
same_as "$SET" "$HOME/settings.orig" && ok "the batch's in-place switch put the saved defaults back, as the single one does" || bad "batch settings: $(diff "$HOME/settings.orig" "$SET")"
for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done; tmux send-keys -t sala-test-d C-u; sleep 0.5
wait_lock

echo "== the state file and the lock"
grep -q "^$(cpid a)	" "$SALA_MODEL_INPLACE_STATE" && ok "the in-place state still names pane a's live process" || bad "state: $(<"$SALA_MODEL_INPLACE_STATE")"
inplace_put 999999 x y 2>/dev/null
inplace_put "$(cpid a)" opus high; grep -q "^$(cpid a)	" "$SALA_MODEL_INPLACE_STATE" && [ "$(grep -c "^$(cpid a)	" "$SALA_MODEL_INPLACE_STATE")" = 1 ] && ! grep -q '^999999	' "$SALA_MODEL_INPLACE_STATE" && ok "inplace_put: one row per live process, a dead pid's row dropped" || bad "state after put: $(<"$SALA_MODEL_INPLACE_STATE")"
exec 8>"$SALA_RECYCLE_LOCK"; flock -n 8
out=$("$SALA" model sala-test-b opus 2>&1); rc=$?
[ "$rc" = 75 ] && [ "$(typed "$U2" '/model opus')" = 0 ] && same_as "$SET" "$HOME/settings.orig" && ok "a relaunch driver holding the recycle lock: refused (75), nothing typed — the switch runs under that lock" || bad "locked ($rc): $out"
exec 8>&-

[ "$fail" = 0 ] && echo "modelinplace: pass" || echo "modelinplace: FAIL"
exit $fail
