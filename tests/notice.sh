#!/usr/bin/env bash
# `sala notice` (lib/notice.sh, lib/notice.py) and its two deliveries, `hook post-tool` and `hook prompt` (lib/hook.sh): a one-time line
# every live session sees at its next turn, with no relaunch.
# Checks: add / list / drop (--from required, the text one line of at most 400 characters, --until as an epoch, a span or an ISO time,
# a past one and a bad one refused, nothing stored by a refusal); delivery once per session through BOTH hook events (the PostToolUse
# and UserPromptSubmit JSON shapes, the prefix, a second call silent, a session that had it through one event not shown it again through
# the other); two notices in one block, oldest first, and only the new one on a later call; a session whose conversation started after
# the notice (the CLI's registry row, or sala's session registry) gets nothing and is marked seen; a notice that expired or was dropped
# before delivery never arrives; a tool call inside a subagent (agent_id) is not delivered to and does not use the notice up; the fast
# paths start no process (no notice file; a notice this session has seen: the hook runs with an empty PATH and says nothing, and under
# strace, where there is one, only the shell itself is executed); a malformed payload, a bad session id, a broken state folder and a
# garbage notice file all print nothing and exit 0; prune (expired notices out, the delivery files of gone sessions out, all of them
# once no notice is left).
# No tmux, no claude: the hooks read JSON from stdin, the live sessions are registry rows under an isolated HOME naming this suite's
# own pids. Nothing is killed.
# Usage: bash tests/notice.sh   (exit 0 = pass; seconds)
set -u
unset TMUX TMUX_PANE XDG_STATE_HOME SALA_STATE_DIR SALA_REG_DIR SALA_NOTICE_PRE SALA_NOTICE_SKIP
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
exec 8< "$HOME"; flock -n 8 || { rm -rf "$HOME"; exit 1; }          # the temp folder is locked for the run (systemd-tmpfiles ageing honors it)
trap 'rm -rf "$HOME"' EXIT
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT"
SALA="$ROOT/bin/salamander"
ST="$HOME/.local/state/salamander"; NF="$ST/notices.tsv"; SEEN="$ST/notices-seen"; REG="$HOME/.claude/sessions"
mkdir -p "$REG" "$ST"
S1=aaaaaaaa-0000-4000-8000-000000000001; S2=aaaaaaaa-0000-4000-8000-000000000002; S3=aaaaaaaa-0000-4000-8000-000000000003; S4=aaaaaaaa-0000-4000-8000-000000000004
NOW=$(date +%s)
row() {  # row <pid> <session id> <startedAt epoch s> — the CLI's registry row for a live process (the pid must exist)
    printf '{"pid":%s,"sessionId":"%s","name":"t%s","startedAt":%s000,"status":"idle"}\n' "$1" "$2" "$1" "$3" > "$REG/$1.json"
}
row $$ "$S1" $((NOW - 600)); row $PPID "$S2" $((NOW - 600)); row 1 "$S3" $((NOW + 3600))   # S3's process started after any notice written now
payload() { printf '{"session_id":"%s","transcript_path":"/x/y.jsonl","cwd":"/x","hook_event_name":"%s","tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":"ok"%s}' "$1" "${2:-PostToolUse}" "${3:-}"; }
hpost() { payload "$1" PostToolUse "${2:-}" | "$SALA" hook post-tool; }       # <session id> [extra json fields] → the hook's stdout
hprompt() { payload "$1" UserPromptSubmit | "$SALA" hook prompt; }
text_of() { python3 -c 'import json, sys; d = json.load(sys.stdin)["hookSpecificOutput"]; print(d["hookEventName"] + "|" + d["additionalContext"])' <<< "$1" 2>/dev/null; }
count_notices() { local n=0 l; [ -s "$NF" ] && { while IFS= read -r l; do n=$((n + 1)); done < "$NF"; }; echo "$n"; }

echo "== add: --from required, the text one line, --until"
out=$("$SALA" notice add "first text" 2>&1); rc=$?
[ "$rc" = 1 ] && [[ $out == *"--from"* ]] && [ ! -s "$NF" ] && ok "no --from: refused, nothing stored" || bad "no --from: rc=$rc $out"
for bad_text in $'two\nlines' $'tab\there' "" "$(printf 'x%.0s' $(seq 1 401))"; do
    out=$("$SALA" notice add "$bad_text" --from tester 2>&1); rc=$?
    [ "$rc" = 1 ] && [ ! -s "$NF" ] && ok "refused text (${#bad_text} chars): nothing stored" || bad "text '${bad_text:0:20}': rc=$rc $out"
done
out=$("$SALA" notice add "$(printf 'x%.0s' $(seq 1 400))" --from tester 2>&1); rc=$?
[ "$rc" = 0 ] && ok "400 characters is the most, and allowed" || bad "400 chars: rc=$rc $out"
"$SALA" notice drop 1 >/dev/null 2>&1
for u in yesterday 1 "2020-01-01T00:00:00Z"; do
    out=$("$SALA" notice add "x" --from tester --until "$u" 2>&1); rc=$?
    [ "$rc" = 1 ] && ok "--until $u: refused" || bad "--until $u: rc=$rc $out"
done
out=$("$SALA" notice add "x" --from "bad name" 2>&1); rc=$?; [ "$rc" = 1 ] && ok "a sender that is not a session name: refused" || bad "sender: rc=$rc"
[ "$(count_notices)" = 0 ] && ok "no refusal stored anything" || bad "stored: $(slurp "$NF")"

echo "== add and list"
out=$("$SALA" notice add "The lane max is now called subscription-1." --from tester 2>&1); rc=$?
[[ $out == *"notice 2 added"* ]] && [[ $out == *"reaches 3 live sessions"* ]] && [ "$rc" = 0 ] && ok "add prints the id (never reused after a drop) and the live sessions it reaches" || bad "add: rc=$rc $out"
IFS=$'\t' read -r id created sender until text < "$NF"
[ "$id" = 2 ] && [ "$sender" = tester ] && [ $((until - created)) = 604800 ] && [ "$text" = "The lane max is now called subscription-1." ] && ok "the row: id, sender, a 7 day default expiry, the text" || bad "row: $(slurp "$NF")"
t0=$(date +%s); out=$("$SALA" notice add "span" --from tester --until 90m 2>&1); t1=$(date +%s)   # bracket the call: a loaded box cannot widen the gap
IFS=$'\t' read -r _ _ _ u2 _ < <(sed -n 2p "$NF")
[ "$u2" -ge $((t0 + 5400)) ] && [ "$u2" -le $((t1 + 5400)) ] && ok "--until 90m" || bad "span: $u2 vs $t0..$t1 + 5400"
"$SALA" notice add "iso" --from tester --until 2999-01-01T00:00:00Z >/dev/null 2>&1; IFS=$'\t' read -r _ _ _ u3 _ < <(sed -n 3p "$NF")
[ "$u3" = 32472144000 ] && ok "--until as an ISO time" || bad "iso: $u3"
"$SALA" notice add "epoch" --from tester --until $((NOW + 100000)) >/dev/null 2>&1; IFS=$'\t' read -r _ _ _ u4 _ < <(sed -n 4p "$NF")
[ "$u4" = $((NOW + 100000)) ] && ok "--until as an epoch" || bad "epoch: $u4"
"$SALA" notice drop 3 >/dev/null; "$SALA" notice drop 4 >/dev/null; "$SALA" notice drop 5 >/dev/null
out=$("$SALA" notice list 2>&1); [[ $out == *"2  from tester"* ]] && [[ $out == *"still due 2"* ]] && ok "list: S1 and S2 still due; S3, started after it, is not" || bad "list: $out"
[ "$("$SALA" notice list --json | python3 -c 'import json, sys; d = json.load(sys.stdin); print(len(d), d[0]["id"], d[0]["due"], d[0]["had"])')" = "1 2 2 0" ] && ok "list --json" || bad "list --json"
out=$("$SALA" notice drop 99 2>&1); rc=$?; [ "$rc" = 1 ] && ok "drop of an unknown id: refused" || bad "drop 99: rc=$rc"

echo "== delivery: once per session, both events"
out=$(hpost "$S1"); rc=$?
[ "$rc" = 0 ] && [ "$(text_of "$out")" = "PostToolUse|[sala notice 2 from tester] The lane max is now called subscription-1." ] && ok "post-tool: PostToolUse additionalContext with the prefix" || bad "post-tool: rc=$rc $out"
out=$(hpost "$S1"); [ -z "$out" ] && ok "the same session's next tool call: nothing" || bad "twice: $out"
out=$(hprompt "$S1"); [ -z "$out" ] && ok "and its next prompt: nothing (it had it through the other event)" || bad "prompt after post-tool: $out"
out=$(hprompt "$S2"); [ "$(text_of "$out")" = "UserPromptSubmit|[sala notice 2 from tester] The lane max is now called subscription-1." ] && ok "prompt: UserPromptSubmit additionalContext, for another session" || bad "prompt: $out"
out=$(hpost "$S2"); [ -z "$out" ] && ok "that session's tool call afterwards: nothing" || bad "S2 post-tool after prompt: $out"
[ "$(slurp "$SEEN/$S1")" = $'2' ] && ok "the delivery file holds the last notice id" || bad "seen: $(slurp "$SEEN/$S1")"
out=$("$SALA" notice list); [[ $out == *"had it or started after it 2, still due 0"* ]] && ok "list: both had it, none due" || bad "list after: $out"

echo "== a session that started after the notice"
out=$(hpost "$S3"); [ -z "$out" ] && [ -e "$SEEN/$S3" ] && ok "registry row started after the notice: nothing shown, marked seen" || bad "S3: out='$out' seen=$(ls "$SEEN")"
row 1 "$S3" $((NOW - 600))
"$SALA" notice add "second for S4" --from tester >/dev/null
cat > "$ST/sessions.json" <<EOF
{"schema": 1, "sessions": {"x": {"id": "x", "transcripts": [{"id": "$S4", "at": "2999-01-01T00:00:00Z", "why": "start"}]}}}
EOF
out=$(hpost "$S4"); [ -z "$out" ] && [ -e "$SEEN/$S4" ] && ok "sala's session registry says the conversation began after it: nothing shown, marked seen" || bad "S4: out='$out'"
rm -f "$ST/sessions.json"
out=$(hpost "$S3"); [ "$(text_of "$out")" = "PostToolUse|[sala notice 6 from tester] second for S4" ] && ok "S3 (started before the second notice) gets it, and only it" || bad "S3 second: $out"

echo "== two notices in one block, oldest first"
"$SALA" notice add "third text" --from other-agent >/dev/null; "$SALA" notice add "fourth text" --from tester >/dev/null
out=$(hpost "$S1"); T=$(text_of "$out")
[ "$T" = "PostToolUse|[sala notice 6 from tester] second for S4"$'\n'"[sala notice 7 from other-agent] third text"$'\n'"[sala notice 8 from tester] fourth text" ] && ok "one block, three lines, oldest first" || bad "block: $T"
"$SALA" notice add "fifth text" --from tester >/dev/null
out=$(hprompt "$S1"); [ "$(text_of "$out")" = "UserPromptSubmit|[sala notice 9 from tester] fifth text" ] && ok "a later notice: only the new one" || bad "later: $out"

echo "== drop before delivery, expiry"
"$SALA" notice add "to be dropped" --from tester >/dev/null
"$SALA" notice drop 10 >/dev/null
out=$(hpost "$S2"); T=$(text_of "$out"); [[ $T != *"to be dropped"* ]] && [[ $T == *"fifth text"* ]] && ok "a dropped notice never arrives" || bad "dropped: $T"
# an expired notice, written to the store as time would leave it
printf '11\t%s\ttester\t%s\tgone by now\n' $((NOW - 100)) $((NOW - 10)) >> "$NF"
out=$(hpost "$S2"); [ -z "$out" ] && ok "an expired notice is not delivered" || bad "expired: $out"
out=$("$SALA" notice list); [[ $out != *"gone by now"* ]] && ok "and not listed" || bad "expired listed: $out"
"$SALA" notice prune >/dev/null; [[ $(slurp "$NF") != *"gone by now"* ]] && ok "prune takes it out of the store" || bad "prune: $(slurp "$NF")"

echo "== a tool call inside a subagent"
"$SALA" notice add "for the session itself" --from tester >/dev/null
out=$(hpost "$S2" ',"agent_id":"agent-7","agent_type":"Explore"'); [ -z "$out" ] && ok "a subagent's tool call (agent_id): nothing, the notice is not used up" || bad "subagent: $out"
out=$(hpost "$S2"); [ "$(text_of "$out")" = "PostToolUse|[sala notice 11 from tester] for the session itself" ] && ok "the session's own next tool call delivers it, once" || bad "after subagent: $out"
out=$(hpost "$S2"); [ -z "$out" ] && ok "and not twice" || bad "twice after subagent: $out"

echo "== the fast paths start no process"
BASH_BIN=$(command -v bash)
hpost "$S1" >/dev/null                         # S1 has now seen every notice that is up
quiet() {  # <session id> → 0 when the hook, run with an empty PATH, prints nothing at all and exits 0: any program it started would be "command not found" on stderr
    local o; o=$(payload "$1" | env -i HOME="$HOME" SALA_BIN="$SALA" SALA_ROOT="$ROOT" PATH=/nonexistent "$BASH_BIN" "$SALA" hook post-tool 2>&1); qrc=$?
    [ "$qrc" = 0 ] && [ -z "$o" ]
}
quiet "$S1" && ok "a notice up that this session has seen: no output, no command run (empty PATH)" || bad "seen path printed or ran something: rc=$qrc"
mkdir -p "$HOME/empty-state/salamander"
fast=$(payload "$S1" | env -i HOME="$HOME/empty-state" XDG_STATE_HOME="$HOME/empty-state" SALA_BIN="$SALA" SALA_ROOT="$ROOT" PATH=/nonexistent "$BASH_BIN" "$SALA" hook post-tool 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$fast" ] && ok "no notice file at all: no output, no command run (empty PATH)" || bad "empty path: rc=$rc $fast"
: > "$HOME/empty-state/salamander/notices.tsv"
fast=$(payload "$S1" | env -i HOME="$HOME/empty-state" XDG_STATE_HOME="$HOME/empty-state" SALA_BIN="$SALA" SALA_ROOT="$ROOT" PATH=/nonexistent "$BASH_BIN" "$SALA" hook post-tool 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$fast" ] && ok "an empty notice file: the same" || bad "empty file: rc=$rc $fast"
if command -v strace >/dev/null 2>&1 && strace -f -e trace=execve -o /dev/null true 2>/dev/null; then
    for c in "empty-state" ""; do
        n=$(payload "$S1" | env HOME="$HOME" XDG_STATE_HOME="${c:+$HOME/$c}" strace -f -e trace=execve -o "$HOME/strace.out" "$BASH_BIN" "$SALA" hook post-tool >/dev/null 2>&1; grep -c 'execve(.*= 0$' "$HOME/strace.out")
        # the first execve is strace's own start of bash; a second would be a process the hook started (the dispatcher's readlink is skipped when SALA_BIN is exported)
        [ "$n" = 1 ] && ok "strace: ${c:-a seen notice}: one execve, the shell itself" || bad "strace (${c:-seen}): $n execve calls: $(grep 'execve(' "$HOME/strace.out" | head -3)"
    done
else echo "  (strace not available: the empty-PATH checks above stand for it)"; fi

echo "== errors print nothing and exit 0"
for p in '' 'not json' '{"session_id":""}' '{"tool_name":"Bash"}' '{"session_id":"../../etc/passwd"}' '{"session_id":"short"}' "{\"session_id\":\"$S1\""; do
    out=$(printf '%s' "$p" | "$SALA" hook post-tool 2>&1); rc=$?; o2=$(printf '%s' "$p" | "$SALA" hook prompt 2>&1); rc2=$?
    [ "$rc" = 0 ] && [ "$rc2" = 0 ] && [ -z "$out" ] && [ -z "$o2" ] && ok "payload '${p:0:30}': silent, exit 0" || bad "payload '$p': rc=$rc/$rc2 out=$out/$o2"
done
"$SALA" notice add "after the errors" --from tester >/dev/null
S5=aaaaaaaa-0000-4000-8000-000000000005
rm -rf "$SEEN"; : > "$SEEN"                         # the delivery folder cannot be made: a file stands there
out=$(hpost "$S5" 2>&1); rc=$?; [ "$rc" = 0 ] && ok "an unusable delivery folder: exit 0, no crash" || bad "broken seen: rc=$rc $out"
[[ $out != *Traceback* ]] && ok "and no traceback" || bad "traceback: $out"
rm -f "$SEEN"
cp "$NF" "$HOME/notices.good"; printf 'garbage\n\t\t\t\nx\ty\tz\n' > "$NF"
out=$(hpost "$S5" 2>&1); rc=$?; [ "$rc" = 0 ] && [ -z "$out" ] && ok "a garbage notice file: silent, exit 0" || bad "garbage: rc=$rc $out"
cp "$HOME/notices.good" "$NF"
chmod 000 "$ST/notices.lock" 2>/dev/null; rm -f "$ST/notices.lock"; mkdir "$ST/notices.lock"   # a lock that cannot be opened for writing
out=$(hpost "$S5" 2>&1); rc=$?; [ "$rc" = 0 ] && [ -z "$out" ] && ok "a lock that cannot be taken: silent, exit 0" || bad "lock: rc=$rc $out"
rmdir "$ST/notices.lock"

echo "== prune"
rm -rf "$SEEN"; hpost "$S1" >/dev/null; hpost "$S2" >/dev/null
touch -d '3 days ago' "$SEEN/$S2"; row $PPID "$S5" $((NOW - 600))                       # S2's process is gone from the registry (its row now names another conversation)
"$SALA" notice prune >/dev/null
[ -e "$SEEN/$S1" ] && [ ! -e "$SEEN/$S2" ] && ok "a gone session's delivery file, a day old, is pruned; a live one stays" || bad "prune seen: $(ls "$SEEN")"
for n in $("$SALA" notice list --json | python3 -c 'import json, sys; print(*[d["id"] for d in json.load(sys.stdin)])'); do "$SALA" notice drop "$n" >/dev/null; done
[ ! -e "$SEEN" ] && [ "$(count_notices)" = 0 ] && ok "no notice left: every delivery file and the folder go" || bad "all dropped: $(ls "$SEEN" 2>&1)"
out=$("$SALA" notice list); [ "$out" = "no active notices" ] && ok "list: no active notices" || bad "list empty: $out"
[ "$(slurp "$ST/notices.seq")" -ge 11 ] && ok "the id counter is kept, so an id is never reused" || bad "seq: $(slurp "$ST/notices.seq")"

echo "== the help text"
out=$("$SALA" notice --help); [[ $out == *"sala notice add"* ]] && [[ $out == *"hook prompt"* ]] && ok "notice --help" || bad "help: $out"
out=$("$SALA" hook 2>&1); [[ $out == *"salamander hook prompt"* ]] && ok "hook usage lists prompt" || bad "hook usage: $out"

echo; [ "$fail" = 0 ] && echo "notice: pass" || echo "notice: FAIL"
exit $fail
