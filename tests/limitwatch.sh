#!/usr/bin/env bash
# The usage-limit watch (lib/watch.sh, USAGE-LIMIT WATCH) and `sala alert` (lib/alert.sh). Transcripts are written by hand
# in the record shapes Claude Code writes (the weekly and 5-hour limits, a model's weekly limit) and in the API lane's
# documented shape of a 429 (no quota record; no recorded sample); sanitized records are the fixtures under tests/fixtures/:
# the API workspace spending limit (limit-workspace.jsonl: its regain time the reset; a pane moved off the api lane, another
# lifted by its lane's success after the regain time, a headless run on it), the api lane's credit (limit-billing.jsonl:
# error "billing_error", "Credit balance is too low") and the weekly limit (limit-weekly.jsonl). Fake claudes (the compiled
# tests/fake-claude.c) run on a private tmux socket, on
# three lanes read from each process's environment (subscription-1: nothing; subscription-2: CLAUDE_CONFIG_DIR; api: a DUMMY key), and what
# reached each one's messaging socket is read from FAKE_SOCK_LOG. Slack is a file (SALA_NOTIFY_CMD), systemctl a stub that
# answers for a table of user units (state, description, working directory, last run, result) and records what it was
# asked to do. Checked: a stop posted once with a line per lane and limit (the limit named from the record and the lane's
# login, the reset in the suite's zone; not inside SALA_LIMIT_CONFIRM, not for a per-model credit error, never twice); a pane's "since"
# is the first error of this episode, not an older error still in its tail when the lane worked in between; a pane-less
# `claude -p` run (entrypoint sdk-cli; a session started by hand, "cli", or a record with no
# entrypoint is skipped and keeps no state) on the limit named by what started it (the unit whose WorkingDirectory is its cwd, a unit
# whose last run is at the error's time, else plain words with the folder), its runs on one line, once per starter per
# episode, and a run the unit later re-ran successfully dropped (a daily briefing); the lifts, each with its reason: a
# pane relaunched on another lane ("moved", told at once), the reset passed with a success on the lane after it ("reset";
# a model's limit waits for that model's success), a success before the reset ("lifted early": its own, or its lane's;
# the api lane's kinds have no reset: "API credit was added", "the API rate limit lifted"); told once, a busy one once
# idle, never one that went on or erred again after the lift; sala's failed oneshot units re-run once when the last stopped
# pane lifts; a gone pane dropped silently; both knobs off: nothing; `sala alert`; a pane's records from before its claude
# process started are never its lane's successes (an api pane's turns on another login must not lift api panes
# "early" while the API credit is still out), nor its own lift when its lane has not worked since. THE LANE OF AN
# ERROR IS THE ERROR'S (panes relaunched from api onto subscription-1 with a billing_error still in
# their tails must not be posted "Ultra lane stopped: Ultra credit used up"): a credit record is the api lane's whoever runs it — a
# subscription-1 pane with one in its tail is lifted "moved to the Ultra lane", never stopped on subscription-1, in the stopped panes or (its stop
# forgotten while it had no process) not; a stopped pane with no process while a relaunch holds the recycle lock keeps its
# stop; relaunched on the api lane itself with the credit still out, a pane stays stopped, since its episode's first error;
# the weekly reset lifts with "the Ultra weekly limit reset at …"; and no post, message or log line of the run pairs a login
# lane with an API kind. Usage: bash tests/limitwatch.sh   (exit 0 = pass; ~45 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_TZ ANTHROPIC_API_KEY ANTHROPIC_CUSTOM_HEADERS CLAUDE_CONFIG_DIR SALA_LANE_API_KEY_FILE SALA_LANE_TEAM_DIR
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null
P="$HOME/.claude/projects/x"; mkdir -p "$HOME/.claude/sessions" "$P" "$HOME/.local/bin" "$HOME/work" "$HOME/.claude-team"
touch "$HOME/.claude/salamander-rc.stopped"
cc -o "$HOME/.local/bin/claude" "$ROOT/tests/fake-claude.c" -lpthread || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
SCTL="$HOME/systemctl.calls"; UNITS="$HOME/units.tsv"   # the stub's user units, one per line, tab-separated:
# id · state · Type · StateChangeTimestamp · Description · WorkingDirectory · ExecMainStartTimestamp · ExecMainExitTimestamp · ActiveEnterTimestamp · Result
cat > "$HOME/.local/bin/systemctl" <<EOF
#!/bin/bash
# stub: --user list-units [--state=failed] … → the units of $UNITS; show -p A,B[,…] [--value] [--timestamp=unix] [--] U… → their
# properties, one block per unit (a timestamp as @epoch, empty when 0, as systemctl prints them); the rest is recorded
echo "\$*" >> "$SCTL"
[ "\$1" = --user ] && shift
case "\$1" in
  list-units) case "\$*" in
                *--state=failed*) while IFS=\$'\t' read -r id st _; do [ "\$st" = failed ] && echo "\$id loaded failed failed x"; done < "$UNITS";;
                *) while IFS=\$'\t' read -r id st _; do echo "\$id loaded \$st dead x"; done < "$UNITS";;
              esac ;;
  show) shift; props=""; value=0; units=()
        while [ \$# -gt 0 ]; do case "\$1" in -p) props="\$2"; shift 2;; --value) value=1; shift;; --) shift;; -*) shift;; *) units+=("\$1"); shift;; esac; done
        IFS=, read -ra P <<< "\$props"
        # the stub reads the file itself (an awk per unit and tick was the biggest single cost of this suite); units in the order asked
        for u in "\${units[@]}"; do
            while IFS= read -r l; do
                l=\${l//\$'\t'/\$'\x01'}; IFS=\$'\x01' read -r f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 <<< "\$l"
                [ "\$f1" = "\$u" ] || continue
                for p in "\${P[@]}"; do v=""
                    case \$p in
                        Id) v=\$f1;; ActiveState) v=\$f2;; Type) v=\$f3;; StateChangeTimestamp) v="@\$f4";; Description) v=\$f5;; WorkingDirectory) v=\$f6;;
                        ExecMainStartTimestamp) [ -n "\$f7" ] && [ "\$f7" != 0 ] && v="@\$f7";; ExecMainExitTimestamp) [ -n "\$f8" ] && [ "\$f8" != 0 ] && v="@\$f8";;
                        ActiveEnterTimestamp) [ -n "\$f9" ] && [ "\$f9" != 0 ] && v="@\$f9";; Result) v=\$f10;;
                    esac
                    if [ "\$value" = 1 ]; then echo "\$v"; else echo "\$p=\$v"; fi
                done; echo
            done < "$UNITS"
        done ;;
  is-system-running) echo running ;;
esac
exit 0
EOF
chmod +x "$HOME/.local/bin/systemctl"
unit() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$UNITS"; }   # <id> <state> <Type> <StateChange> <Description> <WorkingDirectory> <start> <exit> <active> <Result>
JOURNAL="$HOME/journal.tsv"; : > "$JOURNAL"   # the journalctl stub's lines: epoch, the json record; --since @s --until @u select by epoch
cat > "$HOME/.local/bin/journalctl" <<EOF
#!/bin/bash
s=0; u=9999999999; while [ \$# -gt 0 ]; do case "\$1" in --since) s=\${2#@}; shift 2;; --until) u=\${2#@}; shift 2;; *) shift;; esac; done
awk -F'\t' -v s="\$s" -v u="\$u" '\$1>=s && \$1<=u {print \$2}' "$JOURNAL"
EOF
chmod +x "$HOME/.local/bin/journalctl"
jline() { printf '%s\t{"%s":"%s","__REALTIME_TIMESTAMP":"%s000000"}\n' "$1" "$2" "$3" "$1" >> "$JOURNAL"; }   # <epoch> <USER_UNIT|_SYSTEMD_USER_UNIT> <unit>
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log" FAKE_SOCK_LOG="$HOME/sock.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="cat >> $POSTS"
export SALA_LIMIT_PSTART="*=0"   # the records here are dated before the fake claudes started: every pane's process "started" at 0 (the last section sets its own)
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT"
SALA="$ROOT/bin/salamander"; SOCK="sala-limitwatch-$$"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"
cleanup() {
    local p; command tmux -L "$SOCK" kill-server 2>/dev/null; tmux_socket_rm; sleep 0.5
    for p in $(pgrep -x claude); do [ "$HOME/.local/bin/claude" -ef "/proc/$p/exe" ] && kill -9 "$p" 2>/dev/null; done
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux
UA=aaaaaaaa-0000-4000-8000-0000000000a1 UB=bbbbbbbb-0000-4000-8000-0000000000b1 UC=cccccccc-0000-4000-8000-0000000000c1 UD=dddddddd-0000-4000-8000-0000000000d1
UE=eeeeeeee-0000-4000-8000-0000000000e1 UF=ffffffff-0000-4000-8000-0000000000f1 UG=12121212-0000-4000-8000-000000000121
UH=78787878-0000-4000-8000-000000000781 UH2=78787878-0000-4000-8000-000000000782 UH3=78787878-0000-4000-8000-000000000783   # no pane: headless runs
UH4=78787878-0000-4000-8000-000000000784 UH5=78787878-0000-4000-8000-000000000785
mk() {  # <letter> <uuid> [tmux -e VAR=val…]: a fake claude pane on a lane (its env is what lane_running reads from /proc)
    local n="sala-test-$1" u="$2"; shift 2
    tmux new-session -d -s "$n" -c "$HOME/work" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="$n" -e FAKE_LOG="$FAKE_LOG" -e FAKE_SOCK_LOG="$FAKE_SOCK_LOG" "$@"
    tmux send-keys -t "$n" 'claude' Enter
}
mk a "$UA"; mk b "$UB"; mk f "$UF"; mk g "$UG"                                   # subscription-1: nothing on the line
mk c "$UC" -e CLAUDE_CONFIG_DIR="$HOME/.claude-team"                             # team: its config directory
mk d "$UD" -e ANTHROPIC_API_KEY="dummy-key-NOT-REAL-$$"; mk e "$UE" -e ANTHROPIC_API_KEY="dummy-key-NOT-REAL-$$"   # api: a dummy key
fake_up sala-test-a sala-test-b sala-test-c sala-test-d sala-test-e sala-test-f sala-test-g || exit 1
. "$ROOT/lib/common.sh"
NOW=$(date +%s); RESET=$((NOW + 86400)); RESET_B=$((NOW - 300)); RESET_C=$((NOW - 200))   # a reset still ahead; two already past
epk() { [ "${EP:-cli}" = - ] || printf '"entrypoint":"%s",' "${EP:-cli}"; }   # a record's top-level entrypoint: "cli" (a session someone runs, a pane's), EP=sdk-cli (`claude -p`), EP=- (none)
hl() { EP=sdk-cli "$@"; }   # hl <ok_rec|err_rec|…> …: the record of a headless `claude -p` run
ok_rec() {   # <uuid> <epoch> [model] [cwd]: a normal assistant record
    printf '{%s"parentUuid":null,"isSidechain":false,"type":"assistant","uuid":"%s","timestamp":"%s","cwd":"%s","message":{"model":"%s","role":"assistant","content":[{"type":"text","text":"done"}]},"sessionId":"%s"}\n' "$(epk)" "$(rid)" "$(iso "$2")" "${4:-$HOME/work}" "${3:-claude-opus-5-5}" "$1" >> "$P/$1.jsonl"; }
err_rec() {  # <uuid> <epoch> [apiError] [reset] [rateLimitType] [cwd]: the usage-limit error record (Claude Code 2.1.29x shape)
    printf '{%s"parentUuid":null,"isSidechain":false,"type":"assistant","uuid":"%s","timestamp":"%s","cwd":"%s","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"You'"'"'ve hit your weekly limit · resets Jan 7, 5am (UTC)"}],"stop_reason":"stop_sequence"},"requestId":"r","apiError":"%s","apiErrorParams":{"rate_limit_info":{"status":"rejected","resetsAt":%s,"rateLimitType":"%s"}},"quotaLimits":{"status":"rejected","resetsAt":%s,"rateLimitType":"%s","overageStatus":"rejected","overageDisabledReason":"out_of_credits"},"error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":429,"sessionId":"%s"}\n' \
        "$(epk)" "$(rid)" "$(iso "$2")" "${6:-$HOME/work}" "${3:-usage_limit_reached}" "${4:-$RESET}" "${5:-seven_day}" "${4:-$RESET}" "${5:-seven_day}" "$1" >> "$P/$1.jsonl"; }
fixture() {  # FX=<name> fixture <uuid> <epoch> [cwd] [sed -e…]: a sanitized record from tests/fixtures/, its placeholders filled; its top-level
             # entrypoint "cli" (a pane's) kept, made EP (hl: sdk-cli) or dropped (EP=-), as epk does for the hand-written records
    local e=(); case "${EP:-cli}" in cli) ;; -) e=(-e 's|"entrypoint":"cli",||');; *) e=(-e "s|\"entrypoint\":\"cli\"|\"entrypoint\":\"$EP\"|");; esac
    sed -e "s|@UUID@|$(rid)|" -e "s|@TS@|$(iso "$2")|" -e "s|@CWD@|${3:-$HOME/work}|" -e "s|@SESSION@|$1|" ${e[@]+"${e[@]}"} "${@:4}" "$ROOT/tests/fixtures/$FX.jsonl" >> "$P/$1.jsonl"; }
api_rec() {  # <uuid> <epoch> rate|credit [cwd]: the API lane's errors. credit is the sanitized record (tests/fixtures/limit-billing.jsonl:
             # error "billing_error", 400, the text "Credit balance is too low"); rate as the CLI would record a 429 (no quotaLimits; no recorded sample)
    if [ "$3" = rate ]; then
        printf '{%s"type":"assistant","uuid":"%s","timestamp":"%s","cwd":"%s","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"API Error: 429 {\\"type\\":\\"error\\",\\"error\\":{\\"type\\":\\"rate_limit_error\\",\\"message\\":\\"This request would exceed the rate limit for your organization\\"}}"}]},"error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":429,"sessionId":"%s"}\n' "$(epk)" "$(rid)" "$(iso "$2")" "${4:-$HOME/work}" "$1" >> "$P/$1.jsonl"
    else FX=limit-billing fixture "$1" "$2" "${4:-}"; fi; }
wk_rec() {   # <uuid> <epoch> [reset epoch] [rateLimitType]: the sanitized weekly-limit record (tests/fixtures/limit-weekly.jsonl),
             # its resetsAt and rateLimitType filled in
    FX=limit-weekly fixture "$1" "$2" "" -e "s|@RESET@|${3:-$RESET}|g" -e "s|@TYPE@|${4:-seven_day}|g"; }
ws_rec() {   # <uuid> <epoch> [cwd] [regain epoch]: the sanitized workspace-spending-limit record (tests/fixtures/limit-workspace.jsonl),
             # its "regain access on 2099-01-01 at 00:00 UTC" rewritten when a regain epoch is given
    local re=()
    [ -n "${4:-}" ] && re=(-e "s/regain access on 2099-01-01 at 00:00 UTC/regain access on $(date -u -d "@$4" '+%Y-%m-%d at %H:%M') UTC/")
    sed -e "s|@UUID@|$(rid)|" -e "s|@TS@|$(iso "$2")|" -e "s|@CWD@|${3:-$HOME/work}|" -e "s|@SESSION@|$1|" ${re[@]+"${re[@]}"} "$ROOT/tests/fixtures/limit-workspace.jsonl" >> "$P/$1.jsonl"; }
user_rec() { printf '{"type":"user","uuid":"%s","timestamp":"%s","message":{"role":"user","content":"a message"}}\n' "$(rid)" "$(iso "$2")" >> "$P/$1.jsonl"; }
told() { local n; n=$(grep -c "^$1 .*\] Your lane ([a-z0-9-]*) works again" "$FAKE_SOCK_LOG" 2>/dev/null); echo "${n:-0}"; }
lw() { "$SALA" watch --limit >/dev/null 2>&1; }
regstatus() { local c; c=$(claude_pid_under "$(tmux display -p -t "$1" '#{pane_pid}')"); set_reg_status "$c" "$2"; }
lwt() { local d; d=$(TZ=Etc/UTC date -d "@$1" +%-d); case "$d" in 1|21|31) s=st;; 2|22) s=nd;; 3|23) s=rd;; *) s=th;; esac; TZ=Etc/UTC date -d "@$1" "+%a %b $d$s %H:%M"; }
STATE="$HOME/.claude/salamander-limit.json"
OLD=$((NOW-9000)); STOP=$((NOW-7000)); FAILED_AT=$((STOP+600))
: > "$UNITS"
unit budget-watch.service inactive oneshot $((NOW-6000)) "the budget watch" "$HOME/jobs/budget" $((NOW-6010)) $((NOW-6000)) "" exit-code   # its runs' cwd: its WorkingDirectory
unit sala-briefing-summary-lean.service failed oneshot "$FAILED_AT" "sala briefing — Morning Email Summary to Slack #example-channel (contrib/briefing/summary-lean.sh)" "!$HOME" $((FAILED_AT-10)) "$FAILED_AT" "" exit-code
unit sala-old.service failed oneshot $((STOP-3000)) "an old failure" "!$HOME" $((STOP-3010)) $((STOP-3000)) "" exit-code
unit sala-long.service failed simple "$FAILED_AT" "a long-running one" "!$HOME" $((FAILED_AT-10)) "$FAILED_AT" "" exit-code
unit sala-watch.service failed oneshot "$FAILED_AT" "the watch itself" "!$HOME" $((FAILED_AT-10)) "$FAILED_AT" "" exit-code
unit other-thing.service failed oneshot "$FAILED_AT" "not sala's" "!$HOME" $((FAILED_AT-10)) "$FAILED_AT" "" exit-code
unit sala-daemon.service active simple $((NOW-20000)) "a daemon up since boot" "!$HOME" $((NOW-20000)) "" $((NOW-20000)) success   # spans everything: claims no run
unit sala-home.service inactive oneshot $((NOW-30000)) "a oneshot that works in the home folder" "$HOME" $((NOW-30010)) $((NOW-30000)) "" success   # the home folder is everyone's: no match by it
stopped() { python3 -c 'import json,sys; print(" ".join(sorted(p["s"] for p in json.load(open(sys.argv[1]))["panes"].values())))' "$STATE" 2>/dev/null; }   # the panes the state holds as stopped

echo "== the lanes read from the panes' environments; every pane's last turn went through: nothing"
for u in $UA $UB $UC $UD $UE $UF $UG; do user_rec "$u" $((NOW-9600)); ok_rec "$u" $((NOW-9500)); done
lw
[ "$(posts)" = 0 ] && [ -z "$(stopped)" ] && ok "no post, no pane in the state" || bad "posts: $(slurp "$POSTS")"
echo "== a per-model credit error (another model still works) is no stop"
user_rec "$UF" $((NOW-9300)); err_rec "$UF" $((NOW-9200)) model_requires_usage_credits; lw
[ "$(posts)" = 0 ] && ok "no post for model_requires_usage_credits" || bad "posted: $(<"$POSTS")"

echo "== a stop on three lanes, six limits; a's older error from a past episode (the lane worked after it) is not its since"
user_rec "$UA" $((OLD-50)); err_rec "$UA" "$OLD"                      # a's earlier episode: an error still in its tail…
user_rec "$UB" $((NOW-8050)); ok_rec "$UB" $((NOW-8000)); user_rec "$UG" $((NOW-8050)); ok_rec "$UG" $((NOW-8000)) claude-sonnet-5   # …while the Ultra lane worked after it
user_rec "$UA" $((STOP-50)); err_rec "$UA" "$STOP"                                               # subscription-1: the weekly limit, reset ahead
user_rec "$UB" $((STOP+150)); err_rec "$UB" $((STOP+200)) usage_limit_reached "$RESET_B" five_hour   # subscription-1: the 5-hour limit, reset past
user_rec "$UC" $((STOP+50)); err_rec "$UC" $((STOP+100)) usage_limit_reached "$RESET_C" five_hour    # subscription-2: the 5-hour limit, reset past
user_rec "$UF" $((STOP+250)); err_rec "$UF" $((STOP+300)) usage_limit_reached "$RESET" seven_day_opus   # subscription-1: Opus's weekly limit
user_rec "$UD" $((STOP+350)); api_rec "$UD" $((STOP+400)) rate                                      # api: a 429
user_rec "$UE" $((STOP+450)); api_rec "$UE" $((STOP+500)) credit                                    # api: the credit balance
hl ok_rec "$UH" $((NOW-9000)) claude-opus-5-5 "$HOME/jobs/budget"; hl err_rec "$UH" $((NOW-6000)) usage_limit_reached "$RESET" seven_day "$HOME/jobs/budget"   # no pane: a claude -p run every so often
hl err_rec "$UH2" $((NOW-5000)) usage_limit_reached "$RESET" seven_day "$HOME/jobs/budget"
SALA_LIMIT_CONFIRM=99999 "$SALA" watch --limit >/dev/null 2>&1
[ "$(posts)" = 0 ] && ok "not posted while younger than SALA_LIMIT_CONFIRM" || bad "posted early"
lw; lw
[ "$(posts)" = 1 ] && ok "one post over two runs, g working" || bad "posts: $(posts) — $(<"$POSTS")"
grep -qxF "🚨 *Ultra, Team, api lanes stopped for 6 panes*" "$POSTS" \
    && ok "the headline names every lane" || bad "headline: $(head -1 "$POSTS")"
grep -q "^    • Ultra lane: Ultra weekly limit since $(lwt "$STOP"), it says it resets $(lwt "$RESET"): sala-test-a$" "$POSTS" && ok "a: the Ultra lane's weekly limit, since this episode's first error, not $(lwt "$OLD")" || bad "a: $(<"$POSTS")"
grep -q "^    • Ultra lane: Ultra 5-hour limit since $(lwt $((STOP+200))), it says it resets $(lwt "$RESET_B"): sala-test-b$" "$POSTS" && ok "b: the 5-hour limit on its own line" || bad "b: $(<"$POSTS")"
grep -q "^    • Team lane: Team 5-hour limit since $(lwt $((STOP+100))), it says it resets $(lwt "$RESET_C"): sala-test-c$" "$POSTS" && ok "c: the Team lane, the Team login" || bad "c: $(<"$POSTS")"
grep -q "^    • Ultra lane: Ultra Opus weekly limit since $(lwt $((STOP+300))), it says it resets $(lwt "$RESET"): sala-test-f$" "$POSTS" && ok "f: one model's weekly limit" || bad "f: $(<"$POSTS")"
grep -q "^    • api lane: API rate limit since $(lwt $((STOP+400))), with no reset time given: sala-test-d$" "$POSTS" && ok "d: the api lane's 429" || bad "d: $(<"$POSTS")"
grep -q "^    • api lane: out of API credit since $(lwt $((STOP+500))): sala-test-e$" "$POSTS" && ok "e: the api lane's credit, the sanitized record" || bad "e: $(<"$POSTS")"
[ "$(grep -c 'outside the panes' "$POSTS")" = 1 ] && grep -q "^    • outside the panes, the budget watch (budget-watch): weekly limit since $(lwt $((NOW-6000))) (2 runs so far), it says it resets $(lwt "$RESET"); its next scheduled run tries again$" "$POSTS" \
    && ok "the headless runs on one line, named by the unit whose WorkingDirectory is their cwd, since the first run after its last success" || bad "headless: $(<"$POSTS")"
[ "$(told "$UA")$(told "$UB")$(told "$UC")$(told "$UD")$(told "$UE")$(told "$UF")" = 000000 ] && ok "nobody told while stopped" || bad "told while stopped"

echo "== a is relaunched on the api lane with the same conversation: lifted at once, 'moved', told; the headless cwd not posted again"
tmux kill-session -t sala-test-a; sleep 0.3; mk a "$UA" -e ANTHROPIC_API_KEY="dummy-key-NOT-REAL-$$"; fake_up sala-test-a || exit 1
lw; lw
[ "$(posts)" = 2 ] && lastpost | grep -q "^✅ \*api lane working again for 1 pane since" && ok "one lift post, a alone, its lane in the headline" || bad "posts: $(posts) — $(lastpost)"
lastpost | grep -q "^    • moved to the api lane: sala-test-a$" && ok "its reason: moved to the api lane" || bad "$(lastpost)"
lastpost | grep -q "^    • the Ultra weekly limit had stopped them since $(lwt "$STOP")$" && ok "what had stopped it, since when" || bad "$(lastpost)"
waitfor '[ "$(told "$UA")" = 1 ]' 10 && grep -q "^$UA .*Your lane (api) works again: moved to the api lane\." "$FAKE_SOCK_LOG" && ok "a told once, with the reason" || bad "a told $(told "$UA")×: $(grep "^$UA" "$FAKE_SOCK_LOG")"
[ "$(grep -c 'outside the panes' "$POSTS")" = 1 ] && ok "the headless cwd posted once per episode" || bad "headless posted again"

echo "== b's 5-hour reset has passed and a Sonnet success on the Ultra lane follows it: b lifted by the reset (busy → told once idle); f waits for an Opus success"
user_rec "$UG" $((NOW-110)); ok_rec "$UG" $((NOW-100)) claude-sonnet-5; regstatus sala-test-b busy; lw
[ "$(posts)" = 3 ] && lastpost | grep -qxF "✅ *Ultra lane working again for 1 pane since $(lwt $((NOW-100)))*" && lastpost | grep -q "^    • the Ultra 5-hour limit reset at $(lwt "$RESET_B"): sala-test-b$" && ok "b lifted by its reset, posted alone" || bad "posts: $(posts) — $(lastpost)"
lastpost | grep -q "^    • busy, told once idle: sala-test-b$" && [ "$(told "$UB")" = 0 ] && ok "busy b not told yet" || bad "b: told $(told "$UB"), $(lastpost)"
[ "$(stopped)" = "sala-test-c sala-test-d sala-test-e sala-test-f" ] && ok "f still stopped: a Sonnet success does not lift Opus's limit" || bad "stopped: $(stopped)"
grep -q 'start' "$SCTL" 2>/dev/null && bad "units re-run before the last pane lifted" || ok "no unit re-run while panes are still stopped"
regstatus sala-test-b idle; lw; lw
waitfor '[ "$(told "$UB")" = 1 ]' 10 && grep -q "^$UB .*the Ultra 5-hour limit reset at $(lwt "$RESET_B")\." "$FAKE_SOCK_LOG" && ok "b told once, once idle, with the reason" || bad "b told $(told "$UB")×"

echo "== a success on the api lane (a's) before any reset: d and e lifted early by their lane's success, told"
user_rec "$UA" $((NOW-60)); ok_rec "$UA" $((NOW-50)); lw
[ "$(posts)" = 4 ] && lastpost | grep -qxF "✅ *api lane working again for 2 panes since $(lwt $((NOW-50)))*" && lastpost | grep -q "^    • the API rate limit lifted: sala-test-d$" && lastpost | grep -q "^    • API credit was added: sala-test-e$" \
    && ok "one post for both, each with its own reason (no reset to be early to)" || bad "posts: $(posts) — $(lastpost)"
lastpost | grep -q "^    • the API rate limit had stopped 1 of them since $(lwt $((STOP+400)))$" && lastpost | grep -q "^    • API credit had run out for 1 of them since $(lwt $((STOP+500)))$" \
    && ok "each limit's own since" || bad "$(lastpost)"
waitfor '[ "$(told "$UD")$(told "$UE")" = 11 ]' 10 && grep -q "^$UD .*Your lane (api) works again: the API rate limit lifted\." "$FAKE_SOCK_LOG" && grep -q "^$UE .*Your lane (api) works again: API credit was added\." "$FAKE_SOCK_LOG" && ok "d and e told once each, with the reason" || bad "told d=$(told "$UD") e=$(told "$UE"): $(grep "^$UD\|^$UE" "$FAKE_SOCK_LOG")"

echo "== f goes on by itself before its reset (lifted early), c after its own reset: the last two lift, units re-run once; the budget watch works again"
user_rec "$UF" $((NOW-45)); ok_rec "$UF" $((NOW-40)); user_rec "$UC" $((NOW-35)); ok_rec "$UC" $((NOW-30))
hl ok_rec "$UH3" $((NOW-900)) claude-opus-5-5 "$HOME/jobs/budget"; lw; lw
[ "$(posts)" = 5 ] && lastpost | grep -qxF "✅ *Working again on the Team, Ultra lanes: 2 panes since $(lwt $((NOW-30)))*" && ok "one lift post for the two, both lanes in the headline" || bad "posts: $(posts) — $(lastpost)"
lastpost | grep -q "^    • the Ultra Opus weekly limit lifted early: sala-test-f$" && ok "f: its own success before the reset: lifted early" || bad "$(lastpost)"
lastpost | grep -q "^    • the Team 5-hour limit reset at $(lwt "$RESET_C"): sala-test-c$" && ok "c: its own success after the reset" || bad "$(lastpost)"
[ "$(told "$UC")$(told "$UF")" = 00 ] && ok "neither told: they went on" || bad "told c=$(told "$UC") f=$(told "$UF")"
[ "$(grep -c '^--user start --no-block sala-briefing-summary-lean.service' "$SCTL")" = 1 ] && grep -q '^--user reset-failed sala-briefing-summary-lean.service' "$SCTL" \
    && lastpost | grep -q "^    • re-run after failing during the stop: sala-briefing-summary-lean$" && ok "the oneshot that failed during the stop: reset and started, once, when the last pane lifted" || bad "calls: $(grep -E 'start|reset' "$SCTL")"
grep -qE 'start .*(sala-old|sala-long|sala-watch|other-thing)' "$SCTL" && bad "started another unit: $(grep start "$SCTL")" \
    || ok "not one failed before the stop, a long-running one, watch itself or one outside sala's names"
[ -z "$(stopped)" ] && ! grep -q '"headless": {"budget' "$STATE" && ok "no pane stopped, the budget watch's episode over" || bad "stopped: $(stopped); state: $(<"$STATE")"

echo "== a new budget-watch error after the success, older than the confirm time: posted again, on its own (no pane stopped)"
hl err_rec "$UH3" $((NOW-700)) usage_limit_reached "$RESET" seven_day "$HOME/jobs/budget"; lw
[ "$(posts)" = 6 ] && lastpost | grep -q "^⚠️ \*A usage limit stops 1 run outside the panes\*" && lastpost | grep -q "^    • outside the panes, the budget watch (budget-watch): weekly limit since $(lwt $((NOW-700))), it says it resets" \
    && ok "its own post, a new episode, one run" || bad "posts: $(posts) — $(lastpost)"

echo "== a daily briefing: its run failed on the limit, sala re-ran the unit and it succeeded before the watch looked (the journal names the unit): dropped, never posted; a run nothing started is named by its folder"
hl err_rec "$UH4" $((NOW-100)) usage_limit_reached "$RESET" seven_day "$HOME"                   # the morning briefing: its cwd is the implicit home
unit sala-briefing-defunct.service inactive oneshot $((NOW-20)) "sala briefing — Defunct Address Queue to Slack #example-channel (contrib/briefing/defunct.sh)" "!$HOME" $((NOW-30)) $((NOW-20)) "" success   # its last run: the rerun, which succeeded
unit sala-elsewhere.service inactive oneshot $((NOW-95)) "a job elsewhere" "$HOME/elsewhere" $((NOW-105)) $((NOW-95)) "" success   # ran at the same time, in its own folder
jline $((NOW-110)) USER_UNIT sala-briefing-defunct.service; jline $((NOW-104)) USER_UNIT sala-watch.service; jline $((NOW-105)) _SYSTEMD_USER_UNIT sala-elsewhere.service   # the journal at the error's time
lw   # younger than the confirm time: not posted, but its starter is resolved now
grep -q "\"$UH4\": {[^}]*\"unit\": \"sala-briefing-defunct.service\"" "$STATE" && ok "the run's starter from the journal: the briefing unit (not the watch's own tick, not the job in another folder)" || bad "state: $(grep -o "\"$UH4\": {[^}]*}" "$STATE")"
SALA_LIMIT_CONFIRM=50 "$SALA" watch --limit >/dev/null 2>&1
[ "$(posts)" = 6 ] && ! grep -q 'defunct' "$POSTS" && ok "the unit's later successful run drops it: no post" || bad "posts: $(posts) — $(lastpost)"
hl err_rec "$UH5" $((NOW-300)) usage_limit_reached "$RESET" seven_day "$HOME"; SALA_LIMIT_CONFIRM=50 "$SALA" watch --limit >/dev/null 2>&1   # no unit ran near NOW-300
[ "$(posts)" = 7 ] && lastpost | grep -q "^    • outside the panes, a Claude run from the home folder ($HOME): weekly limit since $(lwt $((NOW-300))), it says it resets $(lwt "$RESET"); nothing retries it on its own$" \
    && ok "no unit matches (not the daemon up since boot, not the oneshot whose WorkingDirectory is the home folder): plain words with the full folder, and nobody retries it" || bad "posts: $(posts) — $(lastpost)"

echo "== b still limited (an error after its lift): not told again, not posted inside the confirm time"
user_rec "$UB" $((NOW-40)); hl err_rec "$UB" $((NOW-30)); lw; lw   # as `claude -p`: once b is gone, only the lookback's memory of the pane keeps it from the headless runs
[ "$(told "$UB")" = 1 ] && [ "$(posts)" = 7 ] && ok "b told once in all, no post" || bad "b told $(told "$UB")×, posts $(posts)"

echo "== a stopped pane that is gone drops out without a word"
SALA_LIMIT_CONFIRM=0 "$SALA" watch --limit >/dev/null 2>&1
[ "$(posts)" = 8 ] && [ "$(stopped)" = sala-test-b ] && lastpost | grep -qxF "🚨 *Ultra lane stopped for 1 pane: Ultra weekly limit*" && ok "b's new stop posted (confirm 0), its lane and limit in the headline" || bad "posts: $(posts) — $(lastpost)"
tmux kill-session -t sala-test-b; sleep 0.5; lw
[ "$(posts)" = 8 ] && [ -z "$(stopped)" ] && ! grep -q "\"$UB\": {\"at\"" "$STATE" && ok "b gone: dropped, no post, not a headless run either" || bad "posts: $(posts); stopped: $(stopped); state: $(<"$STATE")"

echo "== the API workspace spending limit, the sanitized record: classified, its regain time the reset, one post with a headless run on it"
UI=34343434-0000-4000-8000-000000000341 UJ=34343434-0000-4000-8000-000000000342 UK=34343434-0000-4000-8000-000000000343
mk h "$UI" -e ANTHROPIC_API_KEY="dummy-key-$$"; mk i "$UJ" -e ANTHROPIC_API_KEY="dummy-key-$$"; fake_up sala-test-h sala-test-i || exit 1
T=$(date +%s); WSR=$(date -u -d '2099-01-01 00:00' +%s); RW=$(( (T - 120) / 60 * 60 ))   # the record's own reset; a reset already past (whole minutes)
P0=$(posts)
user_rec "$UI" $((T-3)); ws_rec "$UI" $((T-2))                       # h: the record as Claude Code wrote it
user_rec "$UJ" $((T-3)); ws_rec "$UJ" $((T-2)) "$HOME/work" "$RW"    # i: the same, its regain time already past
ws_rec "$UK" $((NOW-4000)) "$HOME/jobs/lib"                            # a claude -p run on the API key, no pane, nothing started it
SALA_LIMIT_CONFIRM=0 "$SALA" watch --limit >/dev/null 2>&1
[ "$(posts)" = $((P0+1)) ] && lastpost | grep -qxF "🚨 *api lane stopped for 2 panes: API workspace spending limit*" \
    && ok "classified as the API workspace spending limit (error unknown, 400, the text): one post, one limit in the headline" || bad "posts: $(posts) — $(lastpost)"
lastpost | grep -qxF "    • api lane: API workspace spending limit since $(lwt $((T-2))), it says it resets $(lwt "$WSR"): sala-test-h" \
    && ok "h: \"regain access on 2099-01-01 at 00:00 UTC\" is the reset ($(lwt "$WSR") in the suite zone)" || bad "h: $(lastpost)"
lastpost | grep -qxF "    • api lane: API workspace spending limit since $(lwt $((T-2))), it says it resets $(lwt "$RW"): sala-test-i" \
    && ok "i: a rewritten regain time parsed the same way" || bad "i: $(lastpost)"
lastpost | grep -qxF "    • outside the panes, a Claude run from $HOME/jobs/lib: API workspace spending limit since $(lwt $((NOW-4000))), it says it resets $(lwt "$WSR"); nothing retries it on its own" \
    && ok "the headless run on it: still named an API limit with no lane" || bad "headless: $(lastpost)"
[ "$(stopped)" = "sala-test-h sala-test-i" ] && ok "h and i held as stopped" || bad "stopped: $(stopped)"

echo "== h relaunched on the Ultra lane: 'moved', told; i waits for its lane"
tmux kill-session -t sala-test-h; sleep 0.3; mk h "$UI"; fake_up sala-test-h || exit 1
lw
[ "$(posts)" = $((P0+2)) ] && lastpost | grep -q "^✅ \*Ultra lane working again for 1 pane since" && lastpost | grep -qxF "    • moved to the Ultra lane: sala-test-h" \
    && lastpost | grep -qxF "    • the API workspace spending limit had stopped them since $(lwt $((T-2)))" && ok "h lifted: moved to the Ultra lane, the limit named" || bad "posts: $(posts) — $(lastpost)"
waitfor '[ "$(told "$UI")" = 1 ]' 10 && grep -q "^$UI .*Your lane (subscription-1) works again: moved to the Ultra lane\." "$FAKE_SOCK_LOG" && ok "h told once, with the reason" || bad "h told $(told "$UI")×"
[ "$(stopped)" = sala-test-i ] && ok "i still stopped" || bad "stopped: $(stopped)"

echo "== a success on the api lane after i's regain time: i lifted by the reset, told"
user_rec "$UA" $((T-1)); ok_rec "$UA" "$T"; lw
[ "$(posts)" = $((P0+3)) ] && lastpost | grep -qxF "✅ *api lane working again for 1 pane since $(lwt "$T")*" && lastpost | grep -qxF "    • the API workspace spending limit reset at $(lwt "$RW"): sala-test-i" \
    && ok "i lifted by the reset, the regain time named" || bad "posts: $(posts) — $(lastpost)"
waitfor '[ "$(told "$UJ")" = 1 ]' 10 && grep -q "^$UJ .*Your lane (api) works again: the API workspace spending limit reset at $(lwt "$RW")\." "$FAKE_SOCK_LOG" && ok "i told once, with the reason" || bad "i told $(told "$UJ")×"
[ -z "$(stopped)" ] && ok "nothing stopped" || bad "stopped: $(stopped)"

echo "== both knobs off: nothing read, nothing kept"
: > "$POSTS"; : > "$SCTL"; : > "$FAKE_SOCK_LOG"; rm -f "$HOME/.claude/salamander-limit."*
for u in $UC $UD; do user_rec "$u" $((NOW-20)); err_rec "$u" $((NOW-10)); done
SALA_LIMIT_ALERT=off SALA_LIMIT_RESUME=off SALA_LIMIT_CONFIRM=0 "$SALA" watch --limit >/dev/null 2>&1
[ ! -s "$POSTS" ] && [ ! -s "$SCTL" ] && [ ! -s "$FAKE_SOCK_LOG" ] && [ ! -e "$STATE" ] \
    && ok "no post, no unit, no message, no state" || bad "posts=$(posts) sctl=$(wc -l < "$SCTL") sock=$(wc -l < "$FAKE_SOCK_LOG")"

echo "== sala alert"
"$SALA" alert "the nightly job missed its slot" "the job did not run" "Details: ~/x.log"; rc=$?
[ "$rc" = 0 ] && head -1 "$POSTS" | grep -qF '⚠️ *the nightly job missed its slot*' && grep -q '^    • the job did not run' "$POSTS" \
    && ok "posted in sala's shape, exit 0" || bad "rc=$rc: $(<"$POSTS")"
# a URL in the headline stays outside the bold: Slack took the closing * into the link of stackshot's item URLs
U1=https://board.example.test/items/38; U2=https://board.example.test/items/39
: > "$POSTS"; "$SALA" alert "Urgent: the job is late $U1" "a line"; rc=$?
p=$(head -1 "$POSTS")
[ "$rc" = 0 ] && [ "$p" = "⚠️ *Urgent: the job is late* → $U1" ] && [[ $p != *"*$U1"* && $p != *"$U1*"* ]] \
    && ok "a headline ending in a URL: the URL after the closing *, no * beside it" || bad "rc=$rc: $p"
: > "$POSTS"; "$SALA" alert "late $U1 and $U2." >/dev/null 2>&1; p=$(head -1 "$POSTS")
[ "$p" = "⚠️ *late and* → $U1 → $U2" ] && ok "two URLs: both after the bold, in order" || bad "$p"
: > "$POSTS"; "$SALA" alert "late — $U1" >/dev/null 2>&1; p=$(head -1 "$POSTS")
[ "$p" = "⚠️ *late* → $U1" ] && ok "the separator that led to the URL goes with it" || bad "$p"
: > "$POSTS"; "$SALA" alert "*late $U1*" >/dev/null 2>&1; p=$(head -1 "$POSTS")
[ "$p" = "*late* → $U1" ] && ok "a headline with its own * and the URL inside it: the URL moved out" || bad "$p"
: > "$POSTS"; "$SALA" alert "*late*$U1" >/dev/null 2>&1; p=$(head -1 "$POSTS")
[ "$p" = "*late* → $U1" ] && ok "a * glued to the URL's front: the URL moved out" || bad "$p"
: > "$POSTS"; "$SALA" alert "*late* $U1" >/dev/null 2>&1; p=$(head -1 "$POSTS")
[ "$p" = "*late* $U1" ] && ok "a headline with a * and a URL clear of it: sent as it is" || bad "$p"
: > "$POSTS"; "$SALA" alert "no link here" >/dev/null 2>&1; p=$(head -1 "$POSTS")
[ "$p" = "⚠️ *no link here*" ] && ok "a headline with no URL: as before" || bad "$p"
SALA_NOTIFY_CMD= "$SALA" alert "x" >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && ok "no notify command: exit 3" || bad "rc=$rc"
SALA_NOTIFY_CMD='exit 7' "$SALA" alert "x" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok "a failing notify command: exit 1" || bad "rc=$rc"
# --help / -h: the usage, exit 0, nothing posted, no alert log line, and no notify command needed. The notify command here is a stub
# that writes to $POSTS (a file in the suite's temporary HOME); a real channel is never configured in this suite.
ALOGF="$HOME/.claude/salamander-alert.log"
for flag in --help -h; do
    : > "$POSTS"; : > "$ALOGF"
    out=$("$SALA" alert "$flag" 2>"$HOME/alert.err"); rc=$?
    [ "$rc" = 0 ] && [[ $out == "usage: salamander alert "* ]] && [[ $out == *"exit: 0 posted · 1 the notify command failed · 2 usage (a channel name that is not [a-z0-9-]+ included) · 3 no notify command configured"* ]] \
        && [ ! -s "$POSTS" ] && [ ! -s "$ALOGF" ] && [ ! -s "$HOME/alert.err" ] \
        && ok "alert $flag: the usage on stdout, exit 0, nothing posted, no log line" || bad "alert $flag rc=$rc out=$out posts=$(<"$POSTS") log=$(<"$ALOGF")"
    : > "$ALOGF"
    out=$(env -u SALA_NOTIFY_CMD -u SALA_WATCH_NOTIFY_CMD "$SALA" alert "$flag" 2>&1); rc=$?
    [ "$rc" = 0 ] && [[ $out == "usage: salamander alert "* ]] && [ ! -s "$ALOGF" ] \
        && ok "alert $flag with no notify command configured: the usage, exit 0, no log line" || bad "alert $flag (none configured) rc=$rc out=$out log=$(<"$ALOGF")"
    : > "$POSTS"
    "$SALA" alert "$flag" "a line" >/dev/null 2>&1; rc=$?
    [ "$rc" = 0 ] && [ ! -s "$POSTS" ] && ok "alert $flag with more arguments: still the usage, nothing posted" || bad "alert $flag + args rc=$rc posts=$(<"$POSTS")"
done
# no arguments or an empty headline: the short usage line, exit 2 (as before)
out=$("$SALA" alert 2>&1 >/dev/null); rc=$?
[ "$rc" = 2 ] && [ "$out" = 'usage: salamander alert [--channel <name>] "<headline>" ["<line>"…]' ] && ok "alert with no argument: the usage line on stderr, exit 2" || bad "rc=$rc out=$out"
# -- ends option handling: the next argument is the headline, even if it is --help or starts with -
: > "$POSTS"; : > "$ALOGF"; "$SALA" alert -- "-5 slots missed" "a line" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(head -1 "$POSTS")" = "⚠️ *-5 slots missed*" ] && grep -q '^    • a line' "$POSTS" && grep -q 'exit 0: ⚠️ \*-5 slots missed\*' "$ALOGF" \
    && ok "alert -- <headline starting with ->: posted, exit 0, logged" || bad "rc=$rc: $(<"$POSTS")"
: > "$POSTS"; "$SALA" alert -- --help >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(head -1 "$POSTS")" = "⚠️ *--help*" ] && ok "alert -- --help: the headline is --help, posted" || bad "rc=$rc: $(<"$POSTS")"
"$SALA" alert -- >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "alert -- with no headline: exit 2" || bad "rc=$rc"
# only the exact words are options, and only as the first argument
: > "$POSTS"; "$SALA" alert "-h failed" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(head -1 "$POSTS")" = "⚠️ *-h failed*" ] && ok "a headline that starts with -h but is more: posted as before" || bad "rc=$rc: $(<"$POSTS")"
: > "$POSTS"; "$SALA" alert "--helpful" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(head -1 "$POSTS")" = "⚠️ *--helpful*" ] && ok "a headline that starts with --help but is more: posted as before" || bad "rc=$rc: $(<"$POSTS")"
: > "$POSTS"; "$SALA" alert "the job" "--help" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(head -1 "$POSTS")" = "⚠️ *the job*" ] && grep -q '^    • --help' "$POSTS" && ok "--help as a later argument is a line, posted" || bad "rc=$rc: $(<"$POSTS")"

echo "== an api pane relaunched with normal records from another login in its tail; the api lane out of credit: nobody lifted"
tmux kill-session -t sala-test-a; sleep 0.3                                  # a's api success at T is no part of this
user_rec "$UI" $((T+1)); ok_rec "$UI" $((T+2))   # h went on, on subscription-1: with the state wiped above, its workspace error (the api lane's) as its newest record would make it a 'moved' lift here
UL=56565656-0000-4000-8000-000000000561; mk j "$UL" -e ANTHROPIC_API_KEY="dummy-key-NOT-REAL-$$"; fake_up sala-test-j || exit 1
# i's workspace error sits at T-2 and a lane success lifts it only when strictly newer (lib/watch.sh: laneok > errat): j's success below is
# stamped T2-3, so T2 must be at least T+3 whole seconds. This stretch takes ~1.5 s on a quiet box, which left i stopped when T2-T came out 1.
waitfor '[ "$(date +%s)" -ge "$((T+3))" ]' 20
JPID=$(claude_pid_under "$(tmux display -p -t sala-test-j '#{pane_pid}')"); T2=$(date +%s); P0=$(posts); : > "$FAKE_SOCK_LOG"
user_rec "$UL" $((T2-60)); ok_rec "$UL" $((T2-50))                   # j's turn on its earlier login, before this process
api_rec "$UL" $((T2-20)) credit                                         # j relaunched on the api lane at T2-30: the credit error
for u in $UD $UE; do user_rec "$u" $((T2-110)); api_rec "$u" $((T2-100)) credit; done   # d and e: on the credit error since before
export SALA_LIMIT_PSTART="*=0 $JPID=$((T2-30))"
SALA_LIMIT_CONFIRM=0 "$SALA" watch --limit >/dev/null 2>&1
[ "$(posts)" = $((P0+1)) ] && case " $(stopped) " in *" sala-test-d sala-test-e "*" sala-test-j "*) true;; *) false;; esac \
    && lastpost | grep -q "^    • api lane: out of API credit since .*: sala-test-d, sala-test-e, sala-test-j$" \
    && python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["panes"][sys.argv[2]]["since"] == int(sys.argv[3]) else 1)' "$STATE" "$UL" $((T2-20)) && ok "d, e and j stopped; j's since its own error, after its earlier success" || bad "posts: $(posts); stopped: $(stopped) — $(lastpost)"
lw; lw
[ "$(posts)" = $((P0+1)) ] && case " $(stopped) " in *" sala-test-d sala-test-e "*" sala-test-j "*) true;; *) false;; esac && [ "$(told "$UD")$(told "$UE")" = 00 ] \
    && ok "j's record from before its process is no api-lane success: nobody lifted, nobody told" || bad "posts: $(posts); stopped: $(stopped) — $(lastpost)"
python3 -c 'import json,sys; sys.exit(1 if json.load(open(sys.argv[1]))["laneok"].get("api|", 0) >= int(sys.argv[2]) else 0)' "$STATE" $((T2-50)) \
    && ok "the state's api-lane success is not j's older record" || bad "laneok: $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["laneok"])' "$STATE")"
echo "== j's newest record is a success from before its process (relaunched again at T2-5): j not lifted; then an api success after it: all lifted"
ok_rec "$UL" $((T2-10)); export SALA_LIMIT_PSTART="*=0 $JPID=$((T2-5))"; lw
[ "$(posts)" = $((P0+1)) ] && case " $(stopped) " in *" sala-test-j "*) true;; *) false;; esac && ok "j still stopped: its success predates its process, its lane has not worked since" || bad "posts: $(posts); stopped: $(stopped) — $(lastpost)"
user_rec "$UL" $((T2-4)); ok_rec "$UL" $((T2-3)); lw
[ "$(posts)" = $((P0+2)) ] && lastpost | grep -q "^✅ \*api lane working again for [0-9]* panes since $(lwt $((T2-3)))\*$" && lastpost | grep -q "^    • API credit was added: .*sala-test-d.*sala-test-j" \
    && ok "a success after j's process started: d, e and j lifted, API credit was added, the api lane named" || bad "posts: $(posts) — $(lastpost)"
waitfor '[ "$(told "$UD")$(told "$UE")" = 11 ]' 10 && grep -q "^$UD .*\] Your lane (api) works again: API credit was added\." "$FAKE_SOCK_LOG" && ok "d and e told, the lane named" || bad "told d=$(told "$UD") e=$(told "$UE"): $(<"$FAKE_SOCK_LOG")"
[ "$(told "$UL")" = 0 ] && ok "j not told: it went on" || bad "j told"

echo "== outside the panes only \`claude -p\` counts (entrypoint sdk-cli); a session started by hand (cli) or a record with no entrypoint is skipped"
UM=90909090-0000-4000-8000-000000000901 UN=90909090-0000-4000-8000-000000000902 UO=90909090-0000-4000-8000-000000000903
T3=$(date +%s); P0=$(posts)
user_rec "$UM" $((T3-410)); hl err_rec "$UM" $((T3-400)) usage_limit_reached "$RESET" seven_day "$HOME/jobs/ep-sdk"              # claude -p
user_rec "$UN" $((T3-420)); user_rec "$UN" $((T3-410)); err_rec "$UN" $((T3-400)) usage_limit_reached "$RESET" seven_day "$HOME/jobs/ep-cli"   # by hand: /login, "ping", the error
user_rec "$UO" $((T3-410)); EP=- err_rec "$UO" $((T3-400)) usage_limit_reached "$RESET" seven_day "$HOME/jobs/ep-none"           # no entrypoint
SALA_LIMIT_CONFIRM=50 "$SALA" watch --limit >/dev/null 2>&1
[ "$(posts)" = $((P0+1)) ] && lastpost | grep -qxF "    • outside the panes, a Claude run from $HOME/jobs/ep-sdk: weekly limit since $(lwt $((T3-400))), it says it resets $(lwt "$RESET"); nothing retries it on its own" \
    && ok "sdk-cli: counted and posted" || bad "posts: $(posts) — $(lastpost)"
! grep -q 'jobs/ep-cli' "$POSTS" && ! grep -q 'jobs/ep-none' "$POSTS" && lastpost | grep -q "^⚠️ \*A usage limit stops 1 run outside the panes\*" \
    && ok "cli and no entrypoint: not counted, not posted" || bad "posts: $(<"$POSTS")"
python3 -c 'import json,sys; st=json.load(open(sys.argv[1])); h=st["hseen"]; hd=" ".join(st["headless"]); sys.exit(0 if sys.argv[2] in h and sys.argv[3] not in h and sys.argv[4] not in h and "ep-cli" not in hd and "ep-none" not in hd else 1)' "$STATE" "$UM" "$UN" "$UO" \
    && ok "no state kept for the cli run or the one with no entrypoint" || bad "state: $(<"$STATE")"
SALA_LIMIT_CONFIRM=50 "$SALA" watch --limit >/dev/null 2>&1
[ "$(posts)" = $((P0+1)) ] && ok "nothing posted on the next tick either" || bad "posts: $(posts) — $(lastpost)"

echo "== the billing_error record: five api panes out of credit; a subscription-1 pane with the same record in its tail is never 'Ultra credit'"
UK2=14141414-0000-4000-8000-000000000141 UL2=14141414-0000-4000-8000-000000000142 UM2=14141414-0000-4000-8000-000000000143
UN2=14141414-0000-4000-8000-000000000144 UO2=14141414-0000-4000-8000-000000000145 UQ2=14141414-0000-4000-8000-000000000146 UR2=14141414-0000-4000-8000-000000000147
for x in k:$UK2 l:$UL2 m:$UM2 n:$UN2 o:$UO2; do mk "${x%%:*}" "${x#*:}" -e ANTHROPIC_API_KEY="dummy-key-NOT-REAL-$$"; done   # api
mk q "$UQ2"; fake_up sala-test-k sala-test-l sala-test-m sala-test-n sala-test-o sala-test-q || exit 1                      # q: subscription-1
pidof_pane() { claude_pid_under "$(tmux display -p -t "$1" '#{pane_pid}')"; }
T3=$(date +%s); P0=$(posts); : > "$FAKE_SOCK_LOG"; export SALA_LIMIT_PSTART="*=0"   # every process "started" at 0: each record is its own process's
for u in $UK2 $UL2 $UM2 $UN2 $UO2 $UQ2; do user_rec "$u" $((T3-1)); api_rec "$u" "$T3" credit; done
SALA_LIMIT_CONFIRM=0 "$SALA" watch --limit >/dev/null 2>&1
[ "$(posts)" = $((P0+2)) ] && lastpost | grep -qxF "🚨 *api lane stopped for 5 panes: API credit ran out*" && ok "the stop headline: the api lane, 'API credit ran out'" || bad "posts: $(posts) — $(lastpost)"
l=$(lastpost | grep "^    • api lane: out of API credit since $(lwt "$T3"): ")
[ -n "$l" ] && for x in k l m n o; do grep -q "sala-test-$x" <<< "$l" || l=""; done; [ -n "$l" ] && ok "the bullet: 'api lane: out of API credit since …', the five named" || bad "$(lastpost)"
case " $(stopped) " in *" sala-test-k sala-test-l sala-test-m sala-test-n sala-test-o "*) ok "k, l, m, n, o held as stopped" ;; *) bad "stopped: $(stopped)" ;; esac
python3 -c 'import json,sys; st=json.load(open(sys.argv[1])); sys.exit(0 if all(p["lane"]=="api" for p in st["panes"].values() if p["lim"] in ("credit","rate","workspace")) else 1)' "$STATE" \
    && ok "the state: every credit stop is on the api lane" || bad "state: $(<"$STATE")"
pq=$(awk '/^[^ ]/ {p=""} {p=p $0 "\n"} /^    • moved to the Ultra lane: sala-test-q$/ {print p; exit}' "$POSTS" | head -1)
[ "$(posts)" = $((P0+2)) ] && grep -qF "✅ *Ultra lane working again for 1 pane since" <<< "$pq" && ok "q, running on subscription-1 with the credit record in its tail: no stop on subscription-1 — lifted as 'moved to the Ultra lane' (the lane of the error is the api lane, whoever runs it)" || bad "posts: $(posts) — $(cat "$POSTS" | tail -12)"
grep -qF "    • API credit had run out for them since $(lwt "$T3")" "$POSTS" && ok "what had stopped q: 'API credit had run out for them since …'" || bad "$(cat "$POSTS" | tail -12)"
waitfor '[ "$(told "$UQ2")" = 1 ]' 10 && grep -q "^$UQ2 .*Your lane (subscription-1) works again: moved to the Ultra lane\." "$FAKE_SOCK_LOG" && ok "q told once" || bad "q told $(told "$UQ2")×"

echo "== k and l relaunched onto the Ultra lane with the same conversation (their process younger than the error): lifted as moved, told; no stop on subscription-1"
tmux kill-session -t sala-test-k; tmux kill-session -t sala-test-l; sleep 0.3; mk k "$UK2"; mk l "$UL2"; fake_up sala-test-k sala-test-l || exit 1
PST3="*=0 $(pidof_pane sala-test-k)=$((T3+1)) $(pidof_pane sala-test-l)=$((T3+1))"; export SALA_LIMIT_PSTART="$PST3"; lw; lw
[ "$(posts)" = $((P0+3)) ] && lastpost | grep -q "^✅ \*Ultra lane working again for 2 panes since " && lastpost | grep -q "^    • moved to the Ultra lane: .*sala-test-[kl], sala-test-[kl]$" \
    && lastpost | grep -qxF "    • API credit had run out for them since $(lwt "$T3")" && ok "one lift post for k and l: moved to the Ultra lane, the credit named as what had stopped them" || bad "posts: $(posts) — $(lastpost)"
waitfor '[ "$(told "$UK2")$(told "$UL2")" = 11 ]' 10 && grep -q "^$UK2 .*Your lane (subscription-1) works again: moved to the Ultra lane\." "$FAKE_SOCK_LOG" && ok "k and l told once each" || bad "told k=$(told "$UK2") l=$(told "$UL2")"
[ "$(stopped)" = "sala-test-c sala-test-m sala-test-n sala-test-o" ] && ok "m, n, o still stopped on api (c on subscription-2 from before)" || bad "stopped: $(stopped)"

echo "== n dropped from the state while it had no claude process (no relaunch in flight), then back on subscription-1: no stop on subscription-1 either — lifted as moved, told once"
tmux kill-session -t sala-test-n; sleep 0.5; lw
[ "$(stopped)" = "sala-test-c sala-test-m sala-test-o" ] && ok "n gone with no relaunch holding the lock: dropped" || bad "stopped: $(stopped)"
mk n "$UN2"; fake_up sala-test-n || exit 1; PST3="$PST3 $(pidof_pane sala-test-n)=$((T3+1))"; export SALA_LIMIT_PSTART="$PST3"; lw; lw
[ "$(posts)" = $((P0+4)) ] && lastpost | grep -q "^✅ \*Ultra lane working again for 1 pane since " && lastpost | grep -qxF "    • moved to the Ultra lane: sala-test-n" \
    && lastpost | grep -qxF "    • API credit had run out for them since $(lwt "$T3")" && ok "n lifted as moved although its stop was forgotten: the old api error is no stop on subscription-1" || bad "posts: $(posts) — $(lastpost)"
waitfor '[ "$(told "$UN2")" = 1 ]' 10 && [ "$(stopped)" = "sala-test-c sala-test-m sala-test-o" ] && ok "n told once over two runs, not stopped" || bad "told n=$(told "$UN2"); stopped: $(stopped)"

echo "== o has no claude process while a relaunch holds the recycle lock: its api stop is kept; back on subscription-1 it lifts as moved"
( exec 7>>"$HOME/.claude/salamander-recycle.lock"; flock 7; exec sleep 60 ) & LOCKPID=$!; waitfor '! flock -n "$HOME/.claude/salamander-recycle.lock" true' 10 || bad "could not take the recycle lock"
tmux kill-session -t sala-test-o; sleep 0.5; lw
[ "$(stopped)" = "sala-test-c sala-test-m sala-test-o" ] && ok "o kept as stopped while the relaunch runs" || bad "stopped: $(stopped)"
kill "$LOCKPID" 2>/dev/null; wait "$LOCKPID" 2>/dev/null; mk o "$UO2"; fake_up sala-test-o || exit 1; PST3="$PST3 $(pidof_pane sala-test-o)=$((T3+1))"; export SALA_LIMIT_PSTART="$PST3"; lw
[ "$(posts)" = $((P0+5)) ] && lastpost | grep -qxF "    • moved to the Ultra lane: sala-test-o" && [ "$(stopped)" = "sala-test-c sala-test-m" ] && ok "o lifted as moved from its kept stop" || bad "posts: $(posts); stopped: $(stopped) — $(lastpost)"

echo "== m relaunched on the api lane itself while the credit is still out, then a fresh billing_error: stays stopped on api, its since unchanged; credit added: lifted"
tmux kill-session -t sala-test-m; sleep 0.3; mk m "$UM2" -e ANTHROPIC_API_KEY="dummy-key-NOT-REAL-$$"; fake_up sala-test-m || exit 1
PST3="$PST3 $(pidof_pane sala-test-m)=$((T3+1))"; export SALA_LIMIT_PSTART="$PST3"; lw
[ "$(posts)" = $((P0+5)) ] && [ "$(stopped)" = "sala-test-c sala-test-m" ] && ok "m, on the api lane again with the old error: still its stop, nothing posted" || bad "posts: $(posts); stopped: $(stopped) — $(lastpost)"
user_rec "$UM2" $((T3+2)); api_rec "$UM2" $((T3+3)) credit; lw
[ "$(posts)" = $((P0+5)) ] && [ "$(stopped)" = "sala-test-c sala-test-m" ] && python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["panes"][sys.argv[2]]["since"] == int(sys.argv[3]) else 1)' "$STATE" "$UM2" "$T3" \
    && ok "a fresh billing_error after the relaunch: still stopped, since this episode's first error" || bad "posts: $(posts); stopped: $(stopped); state: $(grep -o "\"$UM2\": {[^}]*}" "$STATE")"
T3B=$(date +%s); user_rec "$UM2" $((T3B-1)); ok_rec "$UM2" "$T3B"; lw   # credit bought: m's own success on the api lane
[ "$(posts)" = $((P0+6)) ] && lastpost | grep -qxF "✅ *api lane working again for 1 pane since $(lwt "$T3B")*" && lastpost | grep -qxF "    • API credit was added: sala-test-m" \
    && lastpost | grep -qxF "    • API credit had run out for them since $(lwt "$T3")" && ok "m lifted: 'API credit was added'" || bad "posts: $(posts) — $(lastpost)"

echo "== the weekly limit from the sanitized record: r stopped on subscription-1, then lifted by the reset with a subscription-1 success after it, told"
mk r "$UR2"; fake_up sala-test-r || exit 1; : > "$FAKE_SOCK_LOG"; T4=$(date +%s); R4=$((T4+4)); P0=$(posts)
user_rec "$UR2" $((T4-1)); wk_rec "$UR2" "$T4" "$R4" seven_day
SALA_LIMIT_CONFIRM=0 "$SALA" watch --limit >/dev/null 2>&1
[ "$(posts)" = $((P0+1)) ] && lastpost | grep -qxF "🚨 *Ultra lane stopped for 1 pane: Ultra weekly limit*" && lastpost | grep -qxF "    • Ultra lane: Ultra weekly limit since $(lwt "$T4"), it says it resets $(lwt "$R4"): sala-test-r" \
    && ok "the weekly record classified: the Ultra lane's Ultra weekly limit, its reset in the suite zone" || bad "posts: $(posts) — $(lastpost)"
waitfor '[ "$(date +%s)" -ge "$((R4+1))" ]' 20; T5=$(date +%s); user_rec "$UG" $((T5-1)); ok_rec "$UG" "$T5"; lw   # the reset passed; g's success on the Ultra lane after it
[ "$(posts)" = $((P0+2)) ] && lastpost | grep -qxF "✅ *Ultra lane working again for 1 pane since $(lwt "$T5")*" && lastpost | grep -qxF "    • the Ultra weekly limit reset at $(lwt "$R4"): sala-test-r" \
    && lastpost | grep -qxF "    • the Ultra weekly limit had stopped them since $(lwt "$T4")" && ok "r lifted by the reset: 'the Ultra weekly limit reset at …', 'had stopped them since …'" || bad "posts: $(posts) — $(lastpost)"
waitfor '[ "$(told "$UR2")" = 1 ]' 10 && grep -q "^$UR2 .*Your lane (subscription-1) works again: the Ultra weekly limit reset at $(lwt "$R4")\." "$FAKE_SOCK_LOG" && ok "r told once, with the reset" || bad "r told $(told "$UR2")×: $(<"$FAKE_SOCK_LOG")"

echo "== structural: no post, message or log line ever pairs a login lane with an API kind"
if grep -nE "(Ultra|Team|subscription-1|subscription-2|login)( lane)?:? ?(credit|rate limit|workspace)|(subscription-1|subscription-2|login) lane stopped for [0-9]* panes?: .*API|lane \((subscription-1|subscription-2|login)\) works again: (API|the API)" "$POSTS" "$FAKE_SOCK_LOG" "$HOME/.claude/salamander-watch.log" 2>/dev/null; then bad "a login lane paired with an API kind (above)"
else ok "no 'Ultra credit', no 'Ultra lane: … API …', no api kind told to a login lane, across every post, message and log line of this run"; fi
grep -q "credit used up\|lifted early: sala-test-[demjq]" "$POSTS" && bad "old wording: $(grep -n 'credit used up\|lifted early' "$POSTS")" || ok "no 'credit used up' anywhere; the credit lifts say 'API credit was added'"

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit $fail
