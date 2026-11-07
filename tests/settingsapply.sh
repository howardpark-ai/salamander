#!/usr/bin/env bash
# The settings-apply service (lib/settings-apply.sh): a Claude Code settings change that lands in the machine spec
# is applied by sala, on this box and the fleet, never by a session. Checks, against a fake spec checkout (a git repo in the
# suite's HOME), a steps script stub (--list, --check, --only; its `settings` step reads the spec's `model:` line and writes
# ~/.claude/settings.json of the box it runs on, with a .bak-provision-* backup), fake hosts (an `ssh` stub that runs
# everything here with HOME switched to the host's own folder; an .offline marker does not answer), a heartbeat store, and
# systemd-run / systemctl stubs (the unit's command runs here, synchronously). The state and the log, never Slack's wording:
# the kill switch; the first tick's dry look (recorded, nothing changed); an unchanged spec launching nothing; a box asleep
# in the store waiting for its wake; a spec change → check, backup, apply where a settings step drifts, the key-by-key diff
# in the log; repo-only drift applying nothing; a failing step posted once and retried, then fixed; a settings.json that no
# longer parses put back from the backup; a step name no script lists refused and posted once; empty steps and inputs (the defaults) applying nothing; the run's lock; a unit still
# running; the stale post once per fingerprint; --check recording nothing; --status; provision --quiet alone refused.
# Isolated HOME, no tmux, nothing real.
# Usage: bash tests/settingsapply.sh   (exit 0 = pass; ~20 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_MASTER SALA_SETTINGS_APPLY SALA_SETTINGS_STEPS SALA_SETTINGS_SPEC_DIR SALA_SETTINGS_INPUTS
export SALA_SETTINGS_APPLY=on   # the default is off: the tick and the watch tests below run with the service on; the kill-switch tests set off themselves
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
as_op_unit   # no master: the unit's command runs here, in this shell — its provision stands for the service's unit, which no Claude session launches (tests/lib.sh, 5)
TOP="$HOME"
mkdir -p "$HOME/.claude" "$HOME/.local/bin" "$HOME/hosts/t-host-b/.claude" "$HOME/hosts/t-host-c/.claude" "$HOME/knobs" "$HOME/fleet/a" "$HOME/demo-ops/spec"
trap 'rm -rf "$HOME"' EXIT
ME=$(hostname)
# the fleet: ssh runs everything here, with HOME switched to the host's own folder (~ in the command lands there)
cat > "$HOME/.local/bin/ssh" <<EOF
#!/usr/bin/env bash
while [ \$# -gt 0 ]; do case "\$1" in -o) shift 2;; -*) shift;; *) break;; esac; done
h="\$1"; shift; c="\$*"
[ -e "$TOP/hosts/\$h.offline" ] && exit 255
echo "\$h \$c" >> "$TOP/ssh.txt"
case "\$c" in true) :;; "bash -s"*) eval "FAKE_HOST=\$h HOME=$TOP/hosts/\$h bash -s \${c#bash -s}";; *--version*) echo "9.9.9";; *) eval "HOME=$TOP/hosts/\$h; \$c";; esac
EOF
chmod +x "$HOME/.local/bin/ssh"
# the steps script: --list names the steps; every run is recorded as "<host> <args>"; `settings` compares the box's
# settings.json model with the spec's `model:` line and writes it (knobs: fail-settings.<h>, corrupt.<h>, repo-behind.<h>,
# manual-deny.<h>; `hold` makes every run wait until it is removed)
cat > "$HOME/steps.sh" <<EOF
#!/usr/bin/env bash
TOP="$TOP"
case "\$*" in *--list*) printf 'repo      the checkout\nsettings  the merge,\n          continued\ndeny-rules  deny entries\nguard-hook  the guard\n'; exit 0;; esac
h="\${FAKE_HOST:-$ME}"; echo "\$h \$*" >> "\$TOP/calls.txt"
CHECK=0; ONLY=""; while [ \$# -gt 0 ]; do case "\$1" in --check) CHECK=1;; --only) ONLY="\$2"; shift;; esac; shift; done
wants() { [ -z "\$ONLY" ] && return 0; case ",\$ONLY," in *",\$1,"*) return 0;; esac; return 1; }
K="\$TOP/knobs"; while [ -e "\$K/hold" ]; do sleep 0.2; done
S="\$HOME/.claude/settings.json"
want=\$(sed -n 's/^model: //p' "\$TOP/demo-ops/spec/all-machines.md" | head -1)
have=\$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("model",""))' "\$S" 2>/dev/null)
if wants repo; then
    if [ -e "\$K/repo-behind.\$h" ]; then [ "\$CHECK" = 1 ] && echo "STEP|drift|repo|3 behind" || { rm -f "\$K/repo-behind.\$h"; echo "STEP|fixed|repo|3 behind → 0"; }
    else echo "STEP|ok|repo|in step"; fi
fi
if wants settings; then
    if [ "\$have" = "\$want" ]; then echo "STEP|ok|settings|model \$have"
    elif [ "\$CHECK" = 1 ]; then echo "STEP|drift|settings|model \${have:-unset} → \$want"
    elif [ -e "\$K/fail-settings.\$h" ]; then echo "STEP|failed|settings|refused by the test knob"
    else
        cp -p "\$S" "\$S.bak-provision-\$(date +%s)"
        if [ -e "\$K/corrupt.\$h" ]; then echo '{"model": ' > "\$S"
        else python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["model"]=sys.argv[2]; json.dump(d, open(p,"w"), indent=2)' "\$S" "\$want"; fi
        echo "STEP|fixed|settings|model \${have:-unset} → \$want"
    fi
fi
wants deny-rules && { [ -e "\$K/manual-deny.\$h" ] && echo "STEP|manual|deny-rules|an allow entry: Rowan adds it|owner" || echo "STEP|ok|deny-rules|all 4 present"; }
wants guard-hook && echo "STEP|ok|guard-hook|installed"
exit 0
EOF
# systemd-run: recorded, and the unit's command run here at once (its own `>> log` redirect inside); systemctl: the unit's state from a marker
cat > "$HOME/.local/bin/systemd-run" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$TOP/systemd-run.txt"
while [ \$# -gt 0 ] && [ "\$1" != bash ]; do shift; done
( "\$@" ) 7>&- </dev/null >/dev/null 2>&1; exit 0
EOF
printf '#!/usr/bin/env bash\ncase "$*" in *is-active*sala-auto-settings*) [ -e "%s/unit-active" ] && exit 0 || exit 3;; esac; exit 0\n' "$TOP" > "$HOME/.local/bin/systemctl"
chmod +x "$HOME/.local/bin/systemd-run" "$HOME/.local/bin/systemctl"
export PATH="$HOME/.local/bin:$PATH"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="{ cat; echo '%%'; } >> $POSTS"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AGENT_CHECK=off SALA_PROVISION_STEPS="$HOME/steps.sh" SALA_PROVISION_STEPS_LINUX=""
export SALA_FLEET_HOSTS="t-host-b t-host-c" SALA_HEARTBEAT_STATE_DIR="$HOME/fleet" SALA_HEARTBEAT_REPO="" SALA_POST_UPDATE_CMD=""
export SALA_SETTINGS_STEPS="settings deny-rules guard-hook" SALA_SETTINGS_SPEC_DIR="$HOME/demo-ops" SALA_SETTINGS_INPUTS="MACHINE_SPEC.md spec/all-machines.md spec/missing.md"
export SALA_SETTINGS_RETRY=0 SALA_SETTINGS_LOCK_WAIT=1
SALA="$ROOT/bin/salamander"; LOG="$HOME/.claude/salamander-settings-apply.log"; STATE="$HOME/.local/state/salamander/settings-apply.state"
. "$ROOT/lib/common.sh"
. "$ROOT/lib/settings-apply.sh"   # sa_get / sa_set, for reading the state back (and one offline backoff reset)
nlaunch() { local n; n=$(grep -c -- '--unit=sala-auto-settings' "$HOME/systemd-run.txt" 2>/dev/null); echo "${n:-0}"; }
lastlaunch() { tail -1 "$HOME/systemd-run.txt" 2>/dev/null | sed 's/.*settings-apply --run //; s/ >>.*//'; }
model() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("model",""))' "$1" 2>/dev/null; }
sfile() { [ "$1" = "$ME" ] && echo "$HOME/.claude/settings.json" || echo "$HOME/hosts/$1/.claude/settings.json"; }   # <box>
setmodel() { python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["model"]=sys.argv[2]; json.dump(d, open(p,"w"))' "$(sfile "$1")" "$2"; }
napply() { local n; n=$(grep -c "^$1 --only" "$HOME/calls.txt" 2>/dev/null); echo "${n:-0}"; }   # <box> → the steps script's apply runs on it (no --check)
store() { python3 -c 'import json,sys; json.dump({"fleet_ssh": {"t-host-b": {"ok": sys.argv[1]=="1"}, "t-host-c": {"ok": sys.argv[2]=="1"}}}, open(sys.argv[3], "w"))' "$1" "$2" "$HOME/fleet/a/machine.json"; }
tick() { "$SALA" watch --settings >/dev/null 2>&1; }
spec_change() { echo "$1" >> "$HOME/demo-ops/spec/all-machines.md"; git -C "$HOME/demo-ops" -c user.name=t -c user.email=t@t commit -qam "$1"; }
fp() { sa_fingerprint; }
for b in "$ME" t-host-b t-host-c; do echo '{"model": "sonnet", "env": {"X": "1"}, "permissions": {"allow": ["Bash(ls)"]}}' > "$(sfile "$b")"; done
printf '# spec\n' > "$HOME/demo-ops/MACHINE_SPEC.md"; printf 'model: opus\n' > "$HOME/demo-ops/spec/all-machines.md"
git -C "$HOME/demo-ops" init -q && git -C "$HOME/demo-ops" add -A && git -C "$HOME/demo-ops" -c user.name=t -c user.email=t@t commit -qm init
C1=$(git -C "$HOME/demo-ops" rev-parse --short HEAD); store 1 0

echo "== the kill switch: SALA_SETTINGS_APPLY=off reads and writes nothing"
SALA_SETTINGS_APPLY=off tick
[ ! -e "$STATE" ] && [ ! -e "$LOG" ] && [ "$(nlaunch)" = 0 ] && ok "off: no state, no log, no launch" || bad "off did something: $(slurp "$LOG")"

echo "== the first tick: the spec's fingerprint recorded, the boxes behind it launched once, their first look dry"
F1=$(fp); tick
[ "$(nlaunch)" = 1 ] && [ "$(lastlaunch)" = "$ME t-host-b" ] && ok "one launch of sala-auto-settings for this box and the awake host (t-host-c asleep in the store)" || bad "launches: $(slurp "$HOME/systemd-run.txt")"
grep -q "tick: spec $F1 (demo-ops $C1): boxes behind it are applied when due" "$LOG" && ok "the log names the fingerprint and the commit" || bad "log: $(<"$LOG")"
grep -q "^\[.*\] $ME: first look at spec $F1: would apply settings (model sonnet → opus) — recorded, nothing changed" "$LOG" && grep -q "t-host-b: first look at spec $F1: would apply" "$LOG" \
    && ok "the first look says what it would apply, in the step's words" || bad "log: $(grep 'first look' "$LOG")"
[ "$(model "$(sfile "$ME")")" = sonnet ] && [ "$(model "$(sfile t-host-b)")" = sonnet ] && [ "$(napply "$ME")" = 0 ] && [ "$(napply t-host-b)" = 0 ] && ! ls "$HOME"/.claude/settings.json.bak-* >/dev/null 2>&1 \
    && ok "nothing changed: no apply run, no backup, model still sonnet" || bad "changed: $(<"$HOME/calls.txt"); $(ls "$HOME"/.claude/)"
[ "$(sa_get "done.$ME")" = "$F1" ] && [ "$(sa_get done.t-host-b)" = "$F1" ] && [ -z "$(sa_get done.t-host-c)" ] && ok "state: done.$ME and done.t-host-b at $F1, t-host-c not yet" || bad "state: $(<"$STATE")"
[ ! -s "$POSTS" ] && ok "no post" || bad "posted: $(<"$POSTS")"

echo "== an unchanged spec: nothing launched"
tick; [ "$(nlaunch)" = 1 ] && ok "no second launch" || bad "launched again: $(<"$HOME/systemd-run.txt")"

echo "== t-host-c wakes (the store says it answers): its own dry first look"
store 1 1; tick
[ "$(nlaunch)" = 2 ] && [ "$(lastlaunch)" = "t-host-c" ] && ok "launched for t-host-c alone" || bad "launches: $(<"$HOME/systemd-run.txt")"
[ "$(sa_get done.t-host-c)" = "$F1" ] && [ "$(model "$(sfile t-host-c)")" = sonnet ] && ok "t-host-c recorded at $F1, unchanged" || bad "state: $(<"$STATE")"

echo "== the spec changes: the drifting boxes are backed up, applied and the diff is logged"
spec_change "a prose line"; F2=$(fp); C2=$(git -C "$HOME/demo-ops" rev-parse --short HEAD); [ "$F2" != "$F1" ] || bad "the fingerprint did not change"
: > "$HOME/calls.txt"; tick
grep -q "tick: spec $F2 (demo-ops $C2), changed from $F1" "$LOG" && ok "the change is logged with both fingerprints" || bad "log: $(tail -5 "$LOG")"
[ "$(lastlaunch)" = "$ME t-host-b t-host-c" ] && ok "launched for all three" || bad "launch: $(lastlaunch)"
allok=1; for b in "$ME" t-host-b t-host-c; do
    [ "$(model "$(sfile "$b")")" = opus ] || { allok=0; bad "$b: model $(model "$(sfile "$b")")"; }
    grep -q "$b: drift: settings (model sonnet → opus) — applying" "$LOG" || { allok=0; bad "$b: no drift line"; }
    grep -q "$b: settings.json backed up as .*settings.json.bak-sala-settings-" "$LOG" || { allok=0; bad "$b: no backup line"; }
    grep -q "$b: applied spec $F2 (demo-ops $C2): settings: model sonnet → opus · 3 steps ok; panes take it at their next relaunch" "$LOG" || { allok=0; bad "$b: no applied line: $(grep "$b: applied" "$LOG")"; }
    grep -qF "$b: settings.json model: \"sonnet\" → \"opus\"" "$LOG" || { allok=0; bad "$b: no diff line: $(grep "$b: settings.json" "$LOG")"; }
    [ "$(napply "$b")" = 1 ] || { allok=0; bad "$b: $(napply "$b") apply runs"; }
    [ "$(sa_get "done.$b")" = "$F2" ] || { allok=0; bad "$b: done=$(sa_get "done.$b")"; }
done
[ "$allok" = 1 ] && ok "each box: drift line, backup line, applied line with the step's words, one diff line, one apply run, done at $F2"
ls "$HOME"/.claude/settings.json.bak-sala-settings-* >/dev/null 2>&1 && ls "$HOME"/hosts/t-host-c/.claude/settings.json.bak-sala-settings-* >/dev/null 2>&1 && ls "$HOME"/.claude/settings.json.bak-provision-* >/dev/null 2>&1 \
    && ok "sala's backup beside settings.json here and on t-host-c, the step's own .bak-provision-* too" || bad "backups: $(ls "$HOME"/.claude "$HOME"/hosts/t-host-c/.claude)"
[ "$(grep -c "$ME --only" "$HOME/calls.txt")" = 1 ] && [ "$(grep -c "$ME --check --only" "$HOME/calls.txt")" = 2 ] && ok "this box: the check, the apply, provision's check after it" || bad "calls: $(<"$HOME/calls.txt")"
[ ! -s "$POSTS" ] && ok "a quiet apply posts nothing" || bad "posted: $(<"$POSTS")"
[ "$(grep -vc -- '--only repo,settings,deny-rules,guard-hook$' "$HOME/calls.txt")" = 0 ] && ok "every run of the steps script got exactly the settings-class steps (repo first, as provision --only always sends it)" || bad "calls: $(head -3 "$HOME/calls.txt")"

echo "== repo-only drift: in step, nothing applied"
touch "$HOME/knobs/repo-behind.t-host-b"; spec_change "another line"; F3=$(fp); : > "$HOME/calls.txt"; tick
grep -q "t-host-b: in step with spec $F3 (4 steps ok)" "$LOG" && [ "$(napply t-host-b)" = 0 ] && [ -e "$HOME/knobs/repo-behind.t-host-b" ] && ok "t-host-b's repo lag is not a settings change: no apply" || bad "log: $(grep t-host-b "$LOG" | tail -2); calls: $(<"$HOME/calls.txt")"
rm -f "$HOME/knobs/repo-behind.t-host-b"

echo "== a failing step: posted once with the step's words, retried, not posted again, then fixed"
setmodel t-host-c sonnet; touch "$HOME/knobs/fail-settings.t-host-c"; spec_change "a third line"; F4=$(fp); tick
[ "$(nposts 'Settings apply failed on t-host-c')" = 1 ] && grep -qF 't-host-c: settings (refused by the test knob)' <<< "$(post 'Settings apply failed')" && ok "one post, the step's words" || bad "posts: $(<"$POSTS")"
grep -q "t-host-c: apply failed (spec $F4): settings (refused by the test knob)" "$LOG" && [ "$(sa_get done.t-host-c)" = "$F3" ] && [ -n "$(sa_get fail.t-host-c)" ] && ok "logged; done.t-host-c stays at $F3, fail recorded" || bad "log: $(grep t-host-c "$LOG" | tail -3); state: $(<"$STATE")"
n=$(nlaunch); tick
[ "$(nlaunch)" = $((n+1)) ] && [ "$(lastlaunch)" = "t-host-c" ] && [ "$(nposts 'Settings apply failed')" = 1 ] && ok "retried (SALA_SETTINGS_RETRY) for t-host-c alone, no second post" || bad "launches $(nlaunch) vs $n, posts $(nposts 'Settings apply failed')"
rm -f "$HOME/knobs/fail-settings.t-host-c"; tick
[ "$(model "$(sfile t-host-c)")" = opus ] && [ "$(sa_get done.t-host-c)" = "$F4" ] && [ -z "$(sa_get fail.t-host-c)" ] && [ "$(nposts 'Settings apply failed')" = 1 ] && ok "fixed: applied, fail cleared, still one post" || bad "state: $(<"$STATE")"

echo "== a settings.json that no longer parses after the apply: the backup goes back, posted"
setmodel "$ME" sonnet; touch "$HOME/knobs/corrupt.$ME"; spec_change "a fourth line"; F5=$(fp); : > "$POSTS"; tick
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$(sfile "$ME")" 2>/dev/null && [ "$(model "$(sfile "$ME")")" = sonnet ] && ok "settings.json parses again, from the backup (model back to sonnet)" || bad "settings.json: $(cat "$(sfile "$ME")")"
grep -q "$ME: apply failed (spec $F5): settings.json did not parse after the apply: the backup was put back (.*bak-sala-settings-" "$LOG" && [ "$(nposts "Settings apply failed on $ME")" = 1 ] && [ "$(sa_get "done.$ME")" = "$F4" ] \
    && ok "logged and posted once; done.$ME stays at $F4" || bad "log: $(grep "$ME: apply" "$LOG" | tail -1); posts: $(nposts 'Settings apply failed')"
rm -f "$HOME/knobs/corrupt.$ME"; tick
[ "$(model "$(sfile "$ME")")" = opus ] && [ "$(sa_get "done.$ME")" = "$F5" ] && ok "the retry applied it" || bad "state: $(<"$STATE")"

echo "== a step name no script lists: provision refuses before any box, posted once, retried"
spec_change "a fifth line"; F6=$(fp); : > "$POSTS"
SALA_SETTINGS_STEPS="settings nosuch" tick
grep -q "run: provision --check did not run: .*no step named nosuch" "$LOG" && [ "$(nposts 'Settings apply could not run')" = 1 ] && ok "the refusal is logged and posted" || bad "log: $(tail -2 "$LOG"); posts: $(<"$POSTS")"
SALA_SETTINGS_STEPS="settings nosuch" tick
[ "$(nposts 'Settings apply could not run')" = 1 ] && ok "no second post for the same fingerprint" || bad "posts: $(nposts 'Settings apply could not run')"
tick; [ "$(sa_get "done.$ME")" = "$F6" ] && [ "$(sa_get done.t-host-b)" = "$F6" ] && [ "$(sa_get done.t-host-c)" = "$F6" ] && [ -z "$(sa_get fail.t-host-b)" ] && ok "with the steps back: every box at $F6, no fail left" || bad "state: $(<"$STATE")"

echo "== two runs at once: the second gives way (exit 75)"
touch "$HOME/knobs/hold"; : > "$HOME/calls.txt"
"$SALA" settings-apply --run t-host-b >/dev/null 2>&1 & A=$!
waitfor 'grep -q "^t-host-b --check" "$HOME/calls.txt"' 20 || bad "run A did not reach the steps script"
"$SALA" settings-apply --run t-host-b >/dev/null 2>&1; rc=$?
[ "$rc" = 75 ] && grep -q "run: another settings-apply run holds the lock" "$LOG" && ok "run B: exit 75, the lock line in the log" || bad "run B: exit $rc; $(tail -1 "$LOG")"
rm -f "$HOME/knobs/hold"; wait "$A"; rcA=$?
[ "$rcA" = 0 ] && ok "run A finished on its own (exit 0)" || bad "run A: exit $rcA"

echo "== a run stopped by SIGTERM (a timeout, a cancelled CI job) leaves nothing in TMPDIR"
SCR="$HOME/scratch"; mkdir -p "$SCR"; left() { ls -A "$SCR" 2>/dev/null; }
touch "$HOME/knobs/hold"; : > "$HOME/calls.txt"
TMPDIR="$SCR" "$SALA" settings-apply --run t-host-b >/dev/null 2>&1 &
SP=$!
waitfor 'grep -q "^t-host-b --check" "$HOME/calls.txt"' 20 || bad "the run did not reach the steps script"
case "$(left)" in sala-settings-apply.*) ok "a run in flight holds its result folder (sala-settings-apply.*) in TMPDIR" ;; *) bad "unexpected name: $(left | tr '\n' ' ')" ;; esac
kill -TERM "$SP" 2>/dev/null; wait "$SP" 2>/dev/null
[ -z "$(left)" ] && ok "stopped by SIGTERM: the result folder is gone (the EXIT trap removed it)" || bad "left after the stop: $(left | tr '\n' ' ')"
rm -f "$HOME/knobs/hold"; waitfor '! pgrep -f "^bash $HOME/steps.sh" >/dev/null' 20   # the steps the stopped run left waiting end


echo "== the unit still running: no second launch, said once"
touch "$HOME/unit-active"; spec_change "a sixth line"; F7=$(fp); n=$(nlaunch); tick; tick
[ "$(nlaunch)" = "$n" ] && [ "$(grep -c "from an earlier run still runs" "$LOG")" = 1 ] && ok "no launch while sala-auto-settings is active; logged once over two ticks" || bad "launches $(nlaunch) vs $n; $(grep -c 'still runs' "$LOG") lines"
rm -f "$HOME/unit-active"; tick
[ "$(nlaunch)" = $((n+1)) ] && [ "$(sa_get "done.$ME")" = "$F7" ] && ok "launched once the unit is gone" || bad "launches $(nlaunch)"

echo "== an offline box, then the stale post once per fingerprint"
touch "$HOME/hosts/t-host-c.offline"; spec_change "a seventh line"; F8=$(fp); : > "$POSTS"; tick
grep -q "t-host-c: offline, not answering ssh — tried again once it answers" "$LOG" && [ -n "$(sa_get offline.t-host-c)" ] && [ "$(sa_get done.t-host-c)" = "$F7" ] && ok "t-host-c offline: recorded, not failed" || bad "log: $(grep t-host-c "$LOG" | tail -1); state: $(<"$STATE")"
SALA_SETTINGS_STALE=0 tick; SALA_SETTINGS_STALE=0 tick
[ "$(nposts 'not on every box')" = 1 ] && grep -qF 't-host-c: has not answered ssh since the spec changed' <<< "$(post 'not on every box')" && ok "the stale post once, naming t-host-c as offline" || bad "posts: $(<"$POSTS")"
rm -f "$HOME/hosts/t-host-c.offline"; sa_set offline.t-host-c 1; n=$(nlaunch); tick   # the 5-min offline backoff, reset by hand
[ "$(nlaunch)" = $((n+1)) ] && [ "$(lastlaunch)" = "t-host-c" ] && [ "$(sa_get done.t-host-c)" = "$F8" ] && [ -z "$(sa_get offline.t-host-c)" ] && ok "back: applied, offline cleared" || bad "state: $(<"$STATE")"

echo "== --check records nothing; --status"
before=$(md5sum "$STATE"); : > "$POSTS"
out=$("$SALA" settings-apply --check t-host-b 2>&1)
grep -q "t-host-b: in step with spec $F8 (4 steps ok)" <<< "$out" && [ "$(md5sum "$STATE")" = "$before" ] && [ ! -s "$POSTS" ] && ok "--check: printed, state untouched, no post" || bad "check: $out; state changed: $([ "$(md5sum "$STATE")" != "$before" ] && echo yes)"
setmodel t-host-b sonnet; out=$("$SALA" settings-apply --check t-host-b 2>&1)
grep -q "t-host-b: would apply settings (model sonnet → opus)" <<< "$out" && [ "$(model "$(sfile t-host-b)")" = sonnet ] && ok "--check on a drifting box says what it would apply and changes nothing" || bad "check: $out"
setmodel t-host-b opus
out=$("$SALA" settings-apply 2>&1)
grep -q "^settings apply: on · steps: settings deny-rules guard-hook" <<< "$out" && grep -q "^  t-host-b .*at spec $F8" <<< "$out" && grep -q "^unit sala-auto-settings: not running" <<< "$out" && grep -q "spec: $HOME/demo-ops → $F8" <<< "$out" \
    && ok "--status: the switch, the steps, each box's fingerprint, the unit" || bad "status: $out"
SALA_SETTINGS_APPLY=off "$SALA" settings-apply 2>&1 | grep -q "^settings apply: off (SALA_SETTINGS_APPLY)" && ok "--status shows the switch off" || bad "status off"
out=$(env -u SALA_SETTINGS_STEPS "$SALA" settings-apply 2>&1)
grep -q "^settings apply: on · steps: (none: SALA_SETTINGS_STEPS is empty)" <<< "$out" && ok "the default steps are empty: --status says so" || bad "default steps: $out"

echo "== the inputs are the config's own list: a change to a script or a data file in it changes the fingerprint"
(
    export SALA_SETTINGS_INPUTS="SPEC.md scripts/steps.sh data/settings.json" SALA_SETTINGS_SPEC_DIR="$HOME/specdef"; . "$ROOT/lib/settings-apply.sh"
    mkdir -p "$SALA_SETTINGS_SPEC_DIR/scripts" "$SALA_SETTINGS_SPEC_DIR/data"
    printf 'm\n' > "$SALA_SETTINGS_SPEC_DIR/SPEC.md"; printf 'p\n' > "$SALA_SETTINGS_SPEC_DIR/scripts/steps.sh"; printf '{}\n' > "$SALA_SETTINGS_SPEC_DIR/data/settings.json"
    d1=$(sa_fingerprint); printf '{"a": 1}\n' > "$SALA_SETTINGS_SPEC_DIR/data/settings.json"; d2=$(sa_fingerprint)
    printf 'q\n' >> "$SALA_SETTINGS_SPEC_DIR/scripts/steps.sh"; d3=$(sa_fingerprint)
    [ -n "$d1" ] && [ "$d1" != "$d2" ] && [ "$d2" != "$d3" ]
) && ok "each file the config lists is a fingerprint input" || bad "the configured SALA_SETTINGS_INPUTS misses a file"
rm -rf "$HOME/specdef"

echo "== steps and inputs empty (the defaults): the tick and the run find nothing and apply nothing, without an error"
cp "$STATE" "$HOME/state.keep"; sa_del said
n=$(nlaunch); c0=$(wc -c < "$HOME/calls.txt"); fp0=$(sa_get fp); l0=$(wc -l < "$LOG"); : > "$POSTS"
env -u SALA_SETTINGS_STEPS -u SALA_SETTINGS_INPUTS "$SALA" watch --settings >/dev/null 2>&1; rc1=$?
env -u SALA_SETTINGS_STEPS -u SALA_SETTINGS_INPUTS "$SALA" watch --settings >/dev/null 2>&1; rc2=$?
[ "$rc1" = 0 ] && [ "$rc2" = 0 ] && [ "$(nlaunch)" = "$n" ] && [ "$(wc -c < "$HOME/calls.txt")" = "$c0" ] && [ "$(sa_get fp)" = "$fp0" ] && [ ! -s "$POSTS" ] \
    && [ "$(( $(wc -l < "$LOG") - l0 ))" = 1 ] && tail -1 "$LOG" | grep -q "none of the spec's inputs is readable" && ok "empty steps and inputs: the tick exits 0, launches and applies nothing, posts nothing, logs once" || bad "empty tick: rc $rc1/$rc2, launches $(nlaunch) vs $n, log: $(tail -2 "$LOG")"
sa_del said; l0=$(wc -l < "$LOG")
env -u SALA_SETTINGS_STEPS "$SALA" watch --settings >/dev/null 2>&1; rc1=$?
env -u SALA_SETTINGS_STEPS "$SALA" watch --settings >/dev/null 2>&1; rc2=$?
[ "$rc1" = 0 ] && [ "$rc2" = 0 ] && [ "$(nlaunch)" = "$n" ] && [ "$(wc -c < "$HOME/calls.txt")" = "$c0" ] && [ ! -s "$POSTS" ] \
    && [ "$(( $(wc -l < "$LOG") - l0 ))" = 1 ] && tail -1 "$LOG" | grep -q "SALA_SETTINGS_STEPS is empty" && ok "inputs but no steps: the tick exits 0, launches and applies nothing, logs once" || bad "no-steps tick: rc $rc1/$rc2, log: $(tail -2 "$LOG")"
out=$(env -u SALA_SETTINGS_STEPS -u SALA_SETTINGS_INPUTS "$SALA" settings-apply --run 2>&1); rc=$?
[ "$rc" != 0 ] && grep -q "none of the spec's inputs is readable" <<< "$out" && [ "$(wc -c < "$HOME/calls.txt")" = "$c0" ] && ok "the run with no input: refused in one line, nothing applied" || bad "empty run: rc $rc: $out"
out=$(env -u SALA_SETTINGS_STEPS "$SALA" settings-apply --run 2>&1); rc=$?
[ "$rc" != 0 ] && grep -q "SALA_SETTINGS_STEPS is empty" <<< "$out" && [ "$(wc -c < "$HOME/calls.txt")" = "$c0" ] && ok "the run with inputs but no steps: refused in one line, nothing applied" || bad "no-steps run: rc $rc: $out"
cp "$HOME/state.keep" "$STATE"; rm -f "$HOME/state.keep"

echo "== the hourly retry gate holds for a box whose last try failed, not for one whose last run succeeded"
cp "$STATE" "$HOME/state.keep"
(
    export SALA_SETTINGS_RETRY=3600; now=$(date +%s)
    for b in t-host-b t-host-c; do sa_set "done.$b" NEWFP; done   # the fleet is current: only this box is in question
    sa_set "done.$ME" OLDFP; sa_set "tried.$ME" $((now - 60)); sa_del "fail.$ME"
    due_ok=$(sa_due NEWFP)
    sa_set "fail.$ME" "apply failed"
    due_fail=$(sa_due NEWFP)
    sa_set "tried.$ME" $((now - 7200))
    due_old=$(sa_due NEWFP)
    [ "$due_ok" = "$ME" ] && [ -z "$due_fail" ] && [ "$due_old" = "$ME" ]
) && ok "a success a minute ago is due on a new spec at once; a failure a minute ago waits the hour; a failure an hour old is due" || bad "retry gate: sa_due does not hold only for failed boxes"
cp "$HOME/state.keep" "$STATE"; rm -f "$HOME/state.keep"

echo "== provision --quiet needs --only or --check"
out=$("$SALA" provision --quiet t-host-b 2>&1); rc=$?
[ "$rc" != 0 ] && grep -q "provision --quiet goes with --only or --check" <<< "$out" && ok "refused: $(head -1 <<< "$out" | cut -c1-60)" || bad "rc $rc: $out"

[ "$fail" = 0 ] && echo "settingsapply: all passed" || echo "settingsapply: FAILED"
exit "$fail"
