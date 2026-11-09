#!/usr/bin/env bash
# Pinned sessions (lib/common.sh "THE PINNED SESSIONS", lib/lane.sh `lane pin | unpin | pins`): a pinned session is held out of every
# BULK lane move and said so in the move's output, dry runs too; only a move that names it moves it. Checked on fakes only (the compiled
# fake claude on sala-test-* panes in a private tmux server with its own socket, a fake `sala` for the back agents' queue; nothing real is
# started, stopped or called):
#   THE HELPERS: no list = nothing pinned; a fixture list (a comment, a blank line, a row naming no lane, a row naming a lane sala does not
#     know) read by lane_is_pinned / lane_pin_of / pinned_skip_note / lane_pins_split; a pinned session with no row of its own launches on
#     its pin's lane (the default's change does not re-home it), a row of its own wins over the pin; a rename carries the pin.
#   THE VERBS: `lane pin <session> <lane>` writes (and replaces) the row and keeps the other lines; `lane unpin`; `lane pins`; bad names
#     and lanes refused; the table shows the pin.
#   THE BULK MOVES, each with a pinned and an unpinned session: `lane <lane> --all` (dry run and the default it sets), `lane default <lane>`
#     (dry run and real), `lane fallback <lane>` (dry run), the back agents' rule (`back_lane_tick`, dry run and real, the fake `sala op`
#     argv): the pinned one is listed as "skipped (pinned to <lane>): <session>", the unpinned one moves, exit status unchanged.
#   THE NAMED MOVE: `lane <lane> <session>` moves the pinned session (dry run, then for real: the row is written and the pane relaunched)
#     and says "pinned to <lane>, moving as asked" once; an unpinned session's named move says nothing about pins.
# Isolated HOME in a temp folder (locked while the suite runs, removed at the end). Usage: bash tests/lanepins.sh   (exit 0 = pass; ~30 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_SET SALA_SET_SELF SALA_POST_RECYCLE_CMD SALA_RECYCLE SALA_RETRY_WORKER SALA_NO_RELAUNCH SALA_MASTER SALA_LANE_PINS SALA_LANE_FALLBACK SALA_LANE_FALLBACK_AUTO
unset ANTHROPIC_API_KEY ANTHROPIC_CUSTOM_HEADERS CLAUDE_CONFIG_DIR SALA_LANE_API_KEY_FILE SALA_LANE_API_WORKSPACE_FILE SALA_LANE_API_MCP_CONFIG SALA_LANE_TEAM_DIR ENABLE_PROMPT_CACHING_1H ENABLE_PROMPT_CACHING_1H_BEDROCK
unset SALA_BACK_LANE_RULE SALA_BACK_LANE_ORDER SALA_BACK_LANE_THRESHOLD SALA_BACK_LANE_MAX_AGE SALA_BACK_LANE_WORDS SALA_BACK_LANE_STATE
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, fake_up, tmux_socket_rm
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
exec 7< "$HOME"; flock -n 7 || true   # the temp folder is locked while the suite runs (systemd-tmpfiles ageing honours it)
as_op_unit   # no master: the guarded verbs this suite runs itself stand for the queue's runner (tests/lib.sh, 5)
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$HOME/web" "$HOME/fakebin"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$HOME/.local/share/claude/versions/9.9.9" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (the EXIT trap does not exist yet)
ln -s "$HOME/.local/share/claude/versions/9.9.9" "$HOME/.local/bin/claude"
printf '#!/bin/sh\necho "$*" >> "%s/systemd-run.txt"\n' "$HOME" > "$HOME/.local/bin/systemd-run"; chmod +x "$HOME/.local/bin/systemd-run"
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log" FAKE_LANE_LOG="$HOME/fake-lane.log" FAKE_TYPED_LOG="$HOME/typed.log" FAKE_CACHE_LOG="$HOME/fake-cache.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="{ cat; echo '%%'; } >> $POSTS"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off
SALA="$ROOT/bin/salamander"; SOCK="sala-lanepins-$$"; T="tmux -L $SOCK -f /dev/null"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's (common.sh, on_fleet_server)
# subscription-2 needs a signed-in directory to be a lane a move may pick
mkdir -p "$HOME/.claude-team"; printf '{"fake":true}\n' > "$HOME/.claude-team/.credentials.json"
cleanup() {
    local f p; for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    for p in /proc/[0-9]*; do [ "$HOME/.local/share/claude/versions/9.9.9" -ef "$p/exe" ] && kill -9 "${p#/proc/}" 2>/dev/null; done   # only our own fake, matched by its executable, never by name
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux    # literal socket: the children run set -u
. "$ROOT/lib/common.sh"
wait_lock() { lock_wait "$HOME/.claude/salamander-recycle.lock" 80; }
mk() { local n="$1" u="$2"; shift 2; $T new-session -d -s "sala-test-$n" -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="sala-test-$n" -e FAKE_LOG="$FAKE_LOG" -e FAKE_LANE_LOG="$FAKE_LANE_LOG" -e FAKE_TYPED_LOG="$FAKE_TYPED_LOG" -e FAKE_CACHE_LOG="$FAKE_CACHE_LOG" "$@"; $T send-keys -t "sala-test-$n" 'claude' Enter; }
has() { case "$1" in *"$2"*) return 0;; esac; return 1; }
hasline() { grep -qxF -- "$2" <<< "$1"; }   # <text> <exact line, leading blanks ignored>
trim() { sed 's/^ *//' <<< "$1"; }
U1=$(uuid 1); U2=$(uuid 2); UX=$(uuid 9)
PINS="$SALA_LANE_PINS"
mkdir -p "$SALA_STATE_DIR"

echo "== the helpers: no list, nothing pinned"
[ "$PINS" = "$SALA_STATE_DIR/lane-pins.tsv" ] && [ ! -e "$PINS" ] && ok "the list is lane-pins.tsv in the state dir and ships absent" || bad "pins path/state: '$PINS'"
lane_is_pinned sala-test-pin && bad "a session is pinned with no list" || ok "no list: lane_is_pinned says no"
[ -z "$(lane_pin_of sala-test-pin)" ] && ! pinned_skip_note sala-test-pin >/dev/null && ok "no list: no lane, no skip note (rc 1)" || bad "no list: pin_of '$(lane_pin_of sala-test-pin)'"
lane_pins_split a b c; [ "${PIN_MOVE[*]}" = "a b c" ] && [ ${#PIN_SKIP[@]} -eq 0 ] && ok "no list: lane_pins_split keeps everybody" || bad "split: ${PIN_MOVE[*]} / ${PIN_SKIP[*]}"

echo "== the helpers: a fixture list"
printf '# held out of bulk moves\n\nsala-test-pin\tsubscription-1\nsess-nolane\nsess-odd\tnot-a-lane\nsess-old\tteam\n' > "$PINS"
lane_is_pinned sala-test-pin && ok "a listed session is pinned" || bad "sala-test-pin not pinned"
! lane_is_pinned sala-test-a && ! lane_is_pinned '# held out of bulk moves' && ! lane_is_pinned '' && ok "an unlisted session, a comment line and an empty name are not" || bad "false pin"
[ "$(lane_pin_of sala-test-pin)" = subscription-1 ] && ok "lane_pin_of: the lane of the row" || bad "pin_of: '$(lane_pin_of sala-test-pin)'"
[ "$(lane_pin_of sess-old)" = subscription-2 ] && ok "an old lane word in the list is read as the current lane" || bad "old word: '$(lane_pin_of sess-old)'"
lane_is_pinned sess-nolane && lane_is_pinned sess-odd && ok "a row naming no lane, or one sala does not know, still pins (the safe side)" || bad "odd rows not pinned"
[ "$(pinned_skip_note sala-test-pin)" = "skipped (pinned to subscription-1): sala-test-pin" ] && ok "pinned_skip_note: skipped (pinned to <lane>): <session>" || bad "note: '$(pinned_skip_note sala-test-pin)'"
[ "$(pinned_moving_note sala-test-pin)" = "pinned to subscription-1, moving as asked: sala-test-pin" ] && ok "pinned_moving_note: pinned to <lane>, moving as asked: <session>" || bad "moving note: '$(pinned_moving_note sala-test-pin)'"
lane_pins_split sala-test-a sala-test-pin sala-test-b; [ "${PIN_MOVE[*]}" = "sala-test-a sala-test-b" ] && [ "${PIN_SKIP[*]}" = "sala-test-pin" ] && ok "lane_pins_split: the unpinned in order, the pinned apart" || bad "split: ${PIN_MOVE[*]} / ${PIN_SKIP[*]}"
export SALA_LANE_PINS="$HOME/other-pins.tsv"; printf 'sess-env\tapi\n' > "$SALA_LANE_PINS"
lane_is_pinned sess-env && ! lane_is_pinned sala-test-pin && ok "SALA_LANE_PINS names another list" || bad "env override"
export SALA_LANE_PINS="$PINS"; rm -f "$HOME/other-pins.tsv"

echo "== the helpers: the pin's lane is where a session without a row of its own launches"
printf 'sala-test-pin\tsubscription-1\n' > "$PINS"; lane_set_default subscription-2
[ "$(lane_for_session sala-test-pin)" = subscription-1 ] && [ "$(lane_for_session sala-test-a)" = subscription-2 ] && ok "default subscription-2: the pinned session stays on its pin's lane, the other follows the default" || bad "for_session: pin '$(lane_for_session sala-test-pin)' a '$(lane_for_session sala-test-a)'"
lane_write sala-test-pin api; [ "$(lane_for_session sala-test-pin)" = api ] && ok "a row of its own (an explicit move) wins over the pin" || bad "row over pin: '$(lane_for_session sala-test-pin)'"
lane_drop sala-test-pin; lane_set_default subscription-1
printf 'sess-old-name\tsubscription-1\nother-pin\tapi\n' > "$PINS"; lane_rename sess-old-name sess-new-name
lane_is_pinned sess-new-name && ! lane_is_pinned sess-old-name && lane_is_pinned other-pin && [ "$(lane_pin_of sess-new-name)" = subscription-1 ] && ok "lane_rename carries the pin to the new name (and leaves the others)" || bad "rename: $(<"$PINS")"
rm -f "$PINS"

echo "== the verbs: pin, pins, unpin"
out=$("$SALA" lane pins 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "no session is pinned" && ok "lane pins with no list: says so, exit 0" || bad "pins, empty ($rc): $out"
out=$("$SALA" lane pin sala-test-pin subscription-1 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "pinned: sala-test-pin to the subscription-1 lane" && [ "$(slurp "$PINS")" = "sala-test-pin	subscription-1" ] && ok "lane pin: the row is written (session TAB lane)" || bad "pin ($rc): $out / $(slurp "$PINS")"
printf '# my note\n' >> "$PINS"; "$SALA" lane pin sess-two team >/dev/null 2>&1; "$SALA" lane pin sala-test-pin subscription-2 >/dev/null 2>&1
[ "$(grep -c '^sala-test-pin' "$PINS")" = 1 ] && [ "$(lane_pin_of sala-test-pin)" = subscription-2 ] && grep -qx '# my note' "$PINS" && [ "$(lane_pin_of sess-two)" = subscription-2 ] && ok "pinning again replaces the row, keeps the other rows and the comment, and writes the current lane word" || bad "re-pin: $(<"$PINS")"
out=$("$SALA" lane pins 2>&1)
hasline "$out" "sala-test-pin                  subscription-2" && hasline "$out" "sess-two                       subscription-2" && ! has "$out" "my note" && ok "lane pins: one line per pinned session with its lane, no comment" || bad "pins: $out"
for badargs in "x" "x bogus" "-x api" "a:b api" "'#c' api" ""; do
    eval "\"\$SALA\" lane pin $badargs" >/dev/null 2>&1; [ $? = 1 ] || bad "lane pin $badargs was not refused"
done
! lane_is_pinned x && ! lane_is_pinned a:b && ok "a missing lane, an unknown lane, a bad session name: refused, nothing written" || bad "bad pin written: $(<"$PINS")"
out=$("$SALA" lane unpin sess-two 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "unpinned: sess-two" && ! lane_is_pinned sess-two && lane_is_pinned sala-test-pin && ok "lane unpin: the row goes, the others stay" || bad "unpin ($rc): $out / $(<"$PINS")"
out=$("$SALA" lane unpin sess-two 2>&1); rc=$?; [ "$rc" = 0 ] && has "$out" "is not pinned" && ok "unpin of an unpinned session: said, exit 0" || bad "unpin again ($rc): $out"
grep -q "pin" "$SALA_LANE_LOG" && ok "pin and unpin are in the lane log" || bad "no lane log lines"
"$SALA" lane unpin sala-test-pin >/dev/null 2>&1; rm -f "$PINS"
"$SALA" lane --help 2>&1 | grep -q 'lane pin <session> <lane>' && ok "the help names the verbs" || bad "help lacks lane pin"

echo "== two panes on the fake claude: one unpinned (a), one pinned (pin)"
mk a "$U1"; mk pin "$U2"; fake_up sala-test-a sala-test-pin
"$SALA" lane pin sala-test-pin subscription-1 >/dev/null
out=$("$SALA" lane 2>&1)
grep -qE '^sala-test-pin +\(default\) +subscription-1 .*pinned to subscription-1' <<< "$out" && ! grep -E '^sala-test-a ' <<< "$out" | grep -q pinned && ok "the table notes the pin on its session only" || bad "table: $out"

echo "== lane <lane> --all: the pinned session is skipped, listed, dry run too"
rm -f "$SALA_LANE_DEFAULT_FILE"
tsv_before=$(slurp "$SALA_LANES")
out=$("$SALA" lane subscription-2 --all --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && ok "--all --dry-run: exit 0" || bad "--all dry run ($rc): $out"
hasline "$(trim "$out")" "skipped (pinned to subscription-1): sala-test-pin" && ok "the dry run lists: skipped (pinned to subscription-1): sala-test-pin" || bad "no skip line: $out"
grep -q '^  sala-test-a: .*→ subscription-2' <<< "$out" && ! grep -q '^  sala-test-pin: ' <<< "$out" && ok "the unpinned session is in the plan, the pinned one is not" || bad "plan: $out"
has "$out" "lane subscription-2: 1 session(s)" && ok "the count is of the sessions that move" || bad "count: $out"
[ "$(slurp "$SALA_LANES")" = "$tsv_before" ] && [ ! -e "$SALA_LANE_DEFAULT_FILE" ] && ok "nothing recorded" || bad "lanes.tsv changed: $(slurp "$SALA_LANES")"

echo "== lane default <lane>: the pinned session keeps its lane, listed"
out=$("$SALA" lane default subscription-2 --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "1 session(s) without a lane of their own would take it" && hasline "$(trim "$out")" "skipped (pinned to subscription-1): sala-test-pin" && ok "dry run: one session re-homed, the pinned one skipped and listed" || bad "default dry run ($rc): $out"
[ ! -e "$SALA_LANE_DEFAULT_FILE" ] && ok "the dry run wrote nothing" || bad "default file written by a dry run"
out=$("$SALA" lane default subscription-2 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "default lane: subscription-2 (was subscription-1) — 1 session(s)" && hasline "$(trim "$out")" "skipped (pinned to subscription-1): sala-test-pin" && ok "real: the default changes, the pinned session is listed" || bad "default ($rc): $out"
[ "$(lane_for_session sala-test-a)" = subscription-2 ] && [ "$(lane_for_session sala-test-pin)" = subscription-1 ] && ok "the unpinned session follows the new default, the pinned one is still on subscription-1" || bad "for_session: a $(lane_for_session sala-test-a), pin $(lane_for_session sala-test-pin)"
"$SALA" lane default subscription-1 >/dev/null 2>&1

echo "== the named move: a pinned session moves when it is named, and says so once"
out=$("$SALA" lane subscription-2 sala-test-pin --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(grep -c 'moving as asked' <<< "$out")" = 1 ] && hasline "$(trim "$out")" "pinned to subscription-1, moving as asked: sala-test-pin" && ! has "$out" "skipped (pinned" && ok "dry run: 'pinned to subscription-1, moving as asked' once, no skip" || bad "named dry run ($rc): $out"
grep -q '^  sala-test-pin: .*→ subscription-2' <<< "$out" && ok "and the plan has it moving" || bad "named plan: $out"
out=$("$SALA" lane subscription-2 sala-test-a --dry-run 2>&1); has "$out" "pinned" && bad "an unpinned named move talks of pins: $out" || ok "an unpinned session's named move says nothing about pins"
out=$("$SALA" lane subscription-2 sala-test-pin 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(grep -c 'moving as asked' <<< "$out")" = 1 ] && ok "real: exit 0, the note once" || bad "named move ($rc): $out"
[ "$(lane_row sala-test-pin)" = subscription-2 ] && ok "recorded: the pinned session is on subscription-2" || bad "row: '$(lane_row sala-test-pin)'"
waitfor '[ "$(starts "$U2")" = 2 ]' 40 && ok "and its pane was relaunched" || bad "no relaunch: $(<"$FAKE_LOG")"
wait_lock; fake_up sala-test-pin
lane_is_pinned sala-test-pin && ok "the pin stays on the list (an explicit move is not an unpin)" || bad "the pin was dropped"

echo "== lane fallback <lane>: the pinned session stays, listed"
export SALA_LANE_FALLBACK="subscription-2=subscription-1"
"$SALA" lane pin sala-test-pin subscription-2 >/dev/null; lane_write sala-test-a subscription-2
"$SALA" lane dormant subscription-2 --no-fallback >/dev/null 2>&1 || bad "could not mark subscription-2 dormant"
rows_before=$(slurp "$SALA_LANES")
out=$("$SALA" lane fallback subscription-2 --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && ok "fallback --dry-run: exit 0" || bad "fallback dry run ($rc): $out"
hasline "$(trim "$out")" "skipped (pinned to subscription-2): sala-test-pin" && ok "listed: skipped (pinned to subscription-2): sala-test-pin" || bad "no skip line: $out"
grep -q '^  sala-test-a: subscription-2 → subscription-1' <<< "$out" && ! grep -q '^  sala-test-pin: ' <<< "$out" && ok "the unpinned session moves, the pinned one is not in the plan" || bad "fallback plan: $out"
[ "$(slurp "$SALA_LANES")" = "$rows_before" ] && [ ! -e "$SALA_LANE_HOME" ] && ok "the dry run recorded nothing" || bad "fallback dry run wrote: $(slurp "$SALA_LANES")"
"$SALA" lane active subscription-2 >/dev/null 2>&1; unset SALA_LANE_FALLBACK

echo "== the back agents' rule: a pinned back agent is skipped, listed, in the dry run and the real pass"
SESSIONS=$(bash -c '. "$1/lib/common.sh"; echo "$SALA_SESSIONS_FILE"' _ "$ROOT")
python3 -I -S - "$SESSIONS" <<'PY'
import json, sys
rows = {}
for n in ("back-a", "back-pin"):
    rows[n] = {"id": n, "name": n, "state": "live", "role": "back", "side": None, "project": "projects/x", "created": n}
json.dump({"schema": 1, "sessions": rows}, open(sys.argv[1], "w"))
PY
printf '%s\n' back-a back-pin > "$HOME/live"
printf 'back-a\tsubscription-1\nback-pin\tsubscription-1\n' > "$SALA_LANES"; rm -f "$SALA_LANE_DEFAULT_FILE" "$SALA_LANE_STATE" "$SALA_LANE_HOME"
printf 'back-pin\tsubscription-1\n' > "$PINS"
NOW=$(date +%s); RESET=$((NOW + 3 * 86400)); ISO=$(date -u -d "@$RESET" +%Y-%m-%dT%H:%M:%SZ)
printf '{"fetchedAt": %s, "limits": [{"label": "This week", "percent": 95, "resetsAt": "%s"}]}\n' "$((NOW * 1000))" "$ISO" > "$HOME/web/quota-subscription-1.json"
# the fake sala: records the queued operation
cat > "$HOME/fakebin/salamander" <<'EOF'
#!/bin/bash
[ "$1" = op ] || exit 0
printf '%s|' "$@" >> "$FAKE_OPLOG"; echo >> "$FAKE_OPLOG"
echo "queued op 1760000000-1: lane $3"
EOF
chmod +x "$HOME/fakebin/salamander"
cat > "$HOME/drv.sh" <<'EOF'
#!/bin/bash
. "$ROOT/lib/common.sh"
SALA_BIN="$HOME/fakebin/salamander"
tmux() { [ "${1:-}" = has-session ] && grep -qx -- "${3#=}" "$HOME/live" 2>/dev/null; }
lane_check() { return 0; }
eval "$1"
EOF
bl() { ROOT="$ROOT" SALA_BACK_LANE_RULE=on SALA_BACK_LANE_ORDER="subscription-1 aws-platform bedrock" SALA_BACK_LANE_WORDS="the rule" SALA_BACK_LANE_REFRESH_URL=off SALA_WEB_STATE_DIR="$HOME/web" \
       FAKE_OPLOG="$HOME/ops.log" bash "$HOME/drv.sh" "$1" 2>&1; }
: > "$HOME/ops.log"
out=$(bl 'back_lane_tick --dry-run'); rc=$?
[ "$rc" = 0 ] && has "$out" "would: step 1" && has "$out" "sala op lane aws-platform back-a --from sala-watch" && ok "dry run: the unpinned back agent would move" || bad "back dry run ($rc): $out"
has "$out" "skipped (pinned to subscription-1): back-pin" && ! has "$out" "aws-platform back-a back-pin" && ok "dry run: skipped (pinned to subscription-1): back-pin, and not in the move" || bad "back dry run, pinned: $out"
[ ! -s "$HOME/ops.log" ] && ok "the dry run queued nothing" || bad "dry run queued: $(<"$HOME/ops.log")"
out=$(bl 'back_lane_tick')
has "$out" "moved: step 1" && has "$out" "skipped (pinned to subscription-1): back-pin" && ok "real pass: moved, and the skip is in the line" || bad "back real pass: $out"
[ "$(slurp "$HOME/ops.log")" = "op|lane|aws-platform|back-a|--from|sala-watch|--words|the rule|" ] && ok "the queued operation names back-a alone" || bad "queued: $(slurp "$HOME/ops.log")"
rm -f "$PINS"; : > "$HOME/ops.log"; rm -f "$HOME/.local/state/salamander/back-lane.state"
printf 'back-a\tsubscription-1\nback-pin\tsubscription-1\n' > "$SALA_LANES"
out=$(bl 'back_lane_tick'); has "$out" "moved: step 1" && ! has "$out" "skipped" && [ "$(slurp "$HOME/ops.log")" = "op|lane|aws-platform|back-a|back-pin|--from|sala-watch|--words|the rule|" ] && ok "control: with no pin, both back agents move and no skip is said" || bad "control: $out / $(slurp "$HOME/ops.log")"

[ "$fail" = 0 ] && echo "lanepins: pass" || echo "lanepins: FAIL"
exit $fail
