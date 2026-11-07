#!/usr/bin/env bash
# The parked question (lib/question.sh, lib/question.py, lib/permission-host.py, `hook ask` in lib/hook.sh). A background `claude -p` run that calls AskUserQuestion is deferred by a PreToolUse hook (the call
# stays in the transcript, the turn ends with terminal_reason tool_deferred and a deferred_tool_use), the question is filed, and nothing is granted until the owner's
# answer arrives; `sala resume-answer` then resumes the session with the hook returning allow + updatedInput {questions, answers}.
# The fake claude (tests/fake-claude-p.py) behaves as 2.1.307 does in that corner (checked once against the real CLI on haiku); filing
# and reading board answers are the two seams SALA_QUESTION_FILE_CMD / SALA_QUESTION_ANSWER_CMD, which the suite fills with scripts.
# Checked: the hook doing nothing without SALA_DEFER_QUESTIONS=1 or for a tool not listed; defer, one record, one filing, and a second
# fire of the hook neither filing again nor allowing; `question run` starting the run with the permission host, the hook settings and
# the env, parking (exit 10) with the id; a resume with no answer running nothing (exit 3); an answer that is not an option refused
# with the options (exit 4) and a --free-text one taken; --dry-run validating and running nothing; the answer by label, by number, with
# "Answer:" in front; two questions and a multi-select; --decline; the answer seam (and an empty one); the sweep; a second question
# after the answer parked in its turn (exit 10, a new id); a finished question refused; a listed Bash call parked, yes allowed, no
# denied, maybe refused; the filing seam (item kept, text masked, a failure left for the sweep); the permission host denying; modes
# and the permission mode carried to the resume; the result's shape (the real CLI's, no stop_reason key, and the old one); stderr noise (and stdout noise) beside a good result
# parsed as done / parked and counted by the sweep, a real failure still showing its stderr; a PATH without claude (the sweep's systemd-run unit) working through SALA_CLAUDE or
# ~/.local/bin/claude, and the hook command and permission host spelled with absolute paths; no secret in any post or log; the record private to the user.
# Usage: bash tests/parkedq.sh   (exit 0 = pass; ~10 s)
set -u
unset TMUX TMUX_PANE XDG_STATE_HOME SALA_MASTER SALA_DEFER_QUESTIONS SALA_DEFER_TOOLS SALA_QUESTION_FILE_CMD SALA_QUESTION_ANSWER_CMD SALA_QUESTION_LABEL SALA_STACKSHOT_CLIENT FAKE_TOOL FAKE_INPUT FAKE_SECOND FAKE_SID FAKE_SHAPE FAKE_STDERR FAKE_STDOUT_PRE FAKE_FAIL
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
trap 'rm -rf "$HOME"' EXIT
mkdir -p "$HOME/.local/bin" "$HOME/work" "$HOME/fakedir"
cp "$ROOT/tests/fake-claude-p.py" "$HOME/.local/bin/claude"; chmod +x "$HOME/.local/bin/claude"
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.jsonl" FAKE_DIR="$HOME/fakedir"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="cat >> $POSTS"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT"
SALA="$ROOT/bin/salamander"; STATE="$HOME/.local/state/salamander"; QD="$STATE/questions"; QLOG="$HOME/.claude/salamander-question.log"
calls() { local n; n=$(grep -c . "$FAKE_LOG" 2>/dev/null); echo "${n:-0}"; }
lastcall() { tail -1 "$FAKE_LOG"; }
qid_of() { sed -n 's/^parked: question \([0-9a-f]*\) .*/\1/p' <<< "$1" | head -1; }
rec() { python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r.get(sys.argv[2],""))' "$QD/$1/record.json" "$2"; }
DEFAULT_IN='{"questions":[{"question":"Pick a colour?","header":"Colour","options":[{"label":"Red","description":"r"},{"label":"Blue","description":"b"}],"multiSelect":false}]}'
payload() {  # <tool> <tool_use_id> [input json] → a PreToolUse payload
    python3 -c 'import json,sys; print(json.dumps({"session_id":"sess-1","cwd":sys.argv[4],"permission_mode":"default","hook_event_name":"PreToolUse","tool_name":sys.argv[1],"tool_use_id":sys.argv[2],"tool_input":json.loads(sys.argv[3])}))' "$1" "$2" "${3:-$DEFAULT_IN}" "$HOME/work" 2>/dev/null
}
TOKEN="[masked Anthropic key]"; DUMMY="dummy-key-NOT-REAL-$$"

echo "== the hook: only a parkable run, only a listed tool"
out=$(payload AskUserQuestion t1 | "$SALA" hook ask); [ -z "$out" ] && [ ! -d "$QD" ] && ok "no SALA_DEFER_QUESTIONS: no output, no record (an interactive pane is untouched)" || bad "out: $out"
out=$(payload Bash t2 '{"command":"ls"}' | SALA_DEFER_QUESTIONS=1 "$SALA" hook ask); [ -z "$out" ] && ok "a tool not in SALA_DEFER_TOOLS: no output" || bad "out: $out"
out=$(printf 'garbage' | SALA_DEFER_QUESTIONS=1 "$SALA" hook ask); r=$?; [ -z "$out" ] && [ "$r" = 0 ] && ok "garbage on stdin: nothing, exit 0" || bad "out: $out rc $r"
out=$(payload AskUserQuestion t3 | SALA_DEFER_QUESTIONS=1 SALA_QUESTION_LABEL=probe "$SALA" hook ask)
[ "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["hookSpecificOutput"]["permissionDecision"])' "$out" 2>/dev/null)" = defer ] && ok "AskUserQuestion in a parkable run: defer" || bad "out: $out"
Q1=$(ls "$QD" | head -1); [ "$(ls "$QD" | wc -l)" = 1 ] && [ "$(rec "$Q1" state)" = parked ] && [ "$(rec "$Q1" label)" = probe ] && ok "one record, parked, the run's label kept" || bad "records: $(ls "$QD")"
[ "$(posts)" = 1 ] && has "$(<"$POSTS")" "probe is waiting for Rowan's answer" && has "$(<"$POSTS")" "it asks: Pick a colour?  [Red / Blue]" && has "$(<"$POSTS")" "sala resume-answer $Q1 --answer" && ok "filed: one post through the notify command (no SALA_QUESTION_FILE_CMD), naming the question, the options and the answer command" || bad "$(posts) posts: $(<"$POSTS")"
[ "$(rec "$Q1" filed)" = post ] && ok "the record says how it was filed" || bad "filed: $(rec "$Q1" filed)"
out=$(payload AskUserQuestion t3 | SALA_DEFER_QUESTIONS=1 "$SALA" hook ask)
has "$out" '"defer"' && ! has "$out" '"allow"' && [ "$(ls "$QD" | wc -l)" = 1 ] && [ "$(posts)" = 1 ] && ok "the hook firing again for the same call: defer again, no second record, no second filing, nothing allowed" || bad "out: $out; $(ls "$QD"); $(posts) posts"
[ "$(stat -c %a "$QD/$Q1")" = 700 ] && [ "$(stat -c %a "$QD/$Q1/record.json")" = 600 ] && ok "the record is private to the user (0700 / 0600)" || bad "modes: $(stat -c %a "$QD/$Q1") $(stat -c %a "$QD/$Q1/record.json")"

echo "== question run: the run started the way a parkable run needs, parked at the question"
out=$("$SALA" question run --cwd "$HOME/work" --label nightly --model haiku "Ask me for a colour" -- --setting-sources project 2>&1); rc=$?
Q2=$(qid_of "$out"); c=$(lastcall)
[ "$rc" = 10 ] && [ -n "$Q2" ] && ok "exit 10 and the question's id" || bad "rc $rc: $out"
has "$out" "sala resume-answer $Q2 --answer" && ok "the line says how to answer" || bad "$out"
python3 - "$c" <<'PY' && ok "claude -p, the permission host tool, the host config naming permission-host.py, the hook settings (matcher AskUserQuestion, command … hook ask), the model and the extra flags, the env and the prompt" || bad "call: $c"
import json, sys
c = json.loads(sys.argv[1]); a = c["argv"]
def opt(n): return a[a.index(n) + 1]
assert a[0] == "-p" and opt("--permission-prompt-tool") == "mcp__salahost__approve" and opt("--output-format") == "json"
host = json.loads(opt("--mcp-config"))["mcpServers"]["salahost"]; assert host["args"][-1].endswith("/lib/permission-host.py"), host
h = json.loads(opt("--settings"))["hooks"]["PreToolUse"][0]; assert h["matcher"] == "AskUserQuestion" and h["hooks"][0]["command"].endswith(" hook ask"), h
assert opt("--model") == "haiku" and "--setting-sources" in a and c["defer_env"] == "1" and c["label"] == "nightly" and c["cwd"].endswith("/work") and c["prompt"] == "Ask me for a colour"
PY
[ "$(rec "$Q2" cwd)" = "$HOME/work" ] && [ "$(rec "$Q2" state)" = parked ] && [ "$(rec "$Q2" label)" = nightly ] && ok "the record: the run's folder, parked, labelled" || bad "record: $(<"$QD/$Q2/record.json")"
out=$("$SALA" question run --cwd "$HOME/work" --json "hello" 2>/dev/null); rc=$?
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["terminal_reason"]=="tool_deferred" and "stop_reason" not in d and d["deferred_tool_use"]["name"]=="AskUserQuestion"' "$out" 2>/dev/null && [ "$rc" = 10 ] && ok "--json prints the raw result (the real shape: terminal_reason tool_deferred, no stop_reason key) and the exit code alone says parked (10)" || bad "rc $rc: $out"

echo "== a parked question with no answer: nothing runs, nothing is granted"
n=$(calls)
out=$("$SALA" resume-answer "$Q2" 2>&1); rc=$?
[ "$rc" = 3 ] && has "$out" "still parked" && [ "$(calls)" = "$n" ] && [ "$(rec "$Q2" state)" = parked ] && ok "exit 3, claude not started, the record still parked" || bad "rc $rc: $out; calls $(calls) vs $n"
out=$("$SALA" resume-answer deadbeef0000 --answer Red 2>&1); rc=$?; [ "$rc" = 2 ] && ok "no such question: exit 2" || bad "rc $rc: $out"
out=$("$SALA" resume-answer "$Q2" --answer Green 2>&1); rc=$?
[ "$rc" = 4 ] && has "$out" "1. Red / 2. Blue" && [ "$(calls)" = "$n" ] && [ "$(rec "$Q2" state)" = parked ] && ok "an answer that is not an option: exit 4, the options printed, nothing run, still parked" || bad "rc $rc: $out"
out=$("$SALA" resume-answer "$Q2" --answer 7 2>&1); rc=$?; [ "$rc" = 4 ] && ok "a number past the options: exit 4" || bad "rc $rc: $out"
out=$("$SALA" resume-answer "$Q2" --answer Blue --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "would resume session" && [ "$(calls)" = "$n" ] && [ "$(rec "$Q2" state)" = parked ] && ok "--dry-run: the answer fits, nothing run, nothing stored" || bad "rc $rc: $out"

echo "== the answer in: the run resumed, the hook allowing with the owner's answer"
out=$("$SALA" resume-answer "$Q2" --answer "Answer: blue" -- --model haiku 2>&1); rc=$?; c=$(lastcall)
[ "$rc" = 0 ] && has "$out" 'ALLOWED {"Pick a colour?": "Blue"}' && ok "exit 0; the call ran with answers {question text: option label} (case and a leading 'Answer:' forgiven)" || bad "rc $rc: $out"
python3 - "$c" "$(rec "$Q2" session_id)" <<'PY' && ok "claude -p --resume <session id> in the run's folder, no prompt, the same host and hook, the extra flags" || bad "call: $c"
import json, sys
c = json.loads(sys.argv[1]); a = c["argv"]
assert a[a.index("--resume") + 1] == sys.argv[2] and c["prompt"] == "" and c["cwd"].endswith("/work") and c["defer_env"] == "1"
assert "--permission-prompt-tool" in a and "--settings" in a and a[a.index("--model") + 1] == "haiku" and "--permission-mode" not in a
PY
[ "$(rec "$Q2" state)" = done ] && ok "the record: done" || bad "state: $(rec "$Q2" state)"
out=$("$SALA" resume-answer "$Q2" --answer Red 2>&1); rc=$?; [ "$rc" = 4 ] && has "$out" "finished already" && ok "a finished question is refused" || bad "rc $rc: $out"

echo "== the answer by number; a permission mode carried; free text"
out=$(FAKE_TOOL=AskUserQuestion "$SALA" question run --cwd "$HOME/work" "again" -- --permission-mode acceptEdits 2>&1); Q3=$(qid_of "$out")
[ -n "$Q3" ] && ok "another run parked" || bad "$out"
out=$("$SALA" resume-answer "$Q3" --answer 1 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" 'ALLOWED {"Pick a colour?": "Red"}' && ok "'1' is the first option" || bad "rc $rc: $out"
has "$(lastcall)" '"--permission-mode", "acceptEdits"' && ok "the run's permission mode passed again on the resume (a resume starts in the default mode)" || bad "call: $(lastcall)"
out=$(FAKE_INPUT='{"questions":[{"question":"Which?","header":"H","options":[{"label":"A","description":""},{"label":"B","description":""}],"multiSelect":false}]}' "$SALA" question run --cwd "$HOME/work" "x" 2>&1); Q4=$(qid_of "$out")
out=$("$SALA" resume-answer "$Q4" --answer "neither, use C" 2>&1); rc=$?; [ "$rc" = 4 ] && ok "free text refused by default" || bad "rc $rc: $out"
out=$("$SALA" resume-answer "$Q4" --answer "neither, use C" --free-text 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" 'ALLOWED {"Which?": "neither, use C"}' && ok "--free-text takes the owner's words as they are" || bad "rc $rc: $out"

echo "== two questions and a multi-select"
TWO='{"questions":[{"question":"Which size?","header":"Size","options":[{"label":"S","description":""},{"label":"L","description":""}],"multiSelect":false},{"question":"Which toppings?","header":"Top","options":[{"label":"Ham","description":""},{"label":"Egg","description":""},{"label":"Corn","description":""}],"multiSelect":true}]}'
out=$(FAKE_INPUT="$TWO" "$SALA" question run --cwd "$HOME/work" "x" 2>&1); Q5=$(qid_of "$out")
out=$("$SALA" resume-answer "$Q5" --answer "L" 2>&1); rc=$?; [ "$rc" = 4 ] && has "$out" "answer each on its own line" && ok "two questions need a line each" || bad "rc $rc: $out"
out=$("$SALA" resume-answer "$Q5" --answer $'1: L\n2: ham, 3' 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" '"Which size?": "L"' && has "$out" '"Which toppings?": "Ham, Corn"' && ok "'1: L' and '2: ham, 3': labels joined for the multi-select" || bad "rc $rc: $out"
out=$(FAKE_INPUT="$TWO" "$SALA" question run --cwd "$HOME/work" "x" 2>&1); Q6=$(qid_of "$out")
printf 'Size: S\nTop: Egg\n' | "$SALA" resume-answer "$Q6" --answer-file - 2>&1 | grep -q '"Which toppings?": "Egg"' && ok "the header names the question; --answer-file - reads stdin" || bad "answer by header failed"

echo "== declined"
out=$("$SALA" question run --cwd "$HOME/work" "x" 2>&1); Q7=$(qid_of "$out")
out=$("$SALA" resume-answer "$Q7" --decline "not now" 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "DENIED Rowan declined: not now" && ok "--decline: the hook denies with the owner's reason, nothing granted" || bad "rc $rc: $out"

echo "== the answer seam: SALA_QUESTION_ANSWER_CMD"
out=$("$SALA" question run --cwd "$HOME/work" "x" 2>&1); Q8=$(qid_of "$out"); n=$(calls)
export SALA_QUESTION_ANSWER_CMD='printf ""'
out=$("$SALA" resume-answer "$Q8" 2>&1); rc=$?; [ "$rc" = 3 ] && [ "$(calls)" = "$n" ] && ok "the seam returning nothing: still parked, nothing run" || bad "rc $rc: $out"
export SALA_QUESTION_ANSWER_CMD='echo "q=$SALA_QUESTION_ID item=$SALA_QUESTION_ITEM" >> '"$HOME/seam.log"'; echo "  Blue  "'
out=$("$SALA" resume-answer "$Q8" 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" 'ALLOWED {"Pick a colour?": "Blue"}' && grep -q "q=$Q8 item=" "$HOME/seam.log" && ok "the seam's answer used (trimmed); it was given the question id and item" || bad "rc $rc: $out; $(slurp "$HOME/seam.log")"

echo "== the sweep"
out=$("$SALA" question run --cwd "$HOME/work" "a" 2>&1); S1=$(qid_of "$out"); out=$("$SALA" question run --cwd "$HOME/work" "b" 2>&1); S2=$(qid_of "$out")
export SALA_QUESTION_ANSWER_CMD='if [ "$SALA_QUESTION_ID" = '"$S1"' ]; then echo 2; fi'
out=$("$SALA" question sweep 2>&1)
[ "$(rec "$S1" state)" = done ] && [ "$(rec "$S2" state)" = parked ] && has "$out" "$S1 has an answer" && ok "the sweep resumed the question with an answer and left the other parked" || bad "sweep: $out; $(rec "$S1" state) $(rec "$S2" state)"
unset SALA_QUESTION_ANSWER_CMD

echo "== a second question after the answer: parked again"
out=$(FAKE_SECOND=1 "$SALA" question run --cwd "$HOME/work" "x" 2>&1); P1=$(qid_of "$out")
out=$(FAKE_SECOND=1 "$SALA" resume-answer "$P1" --answer Red 2>&1); rc=$?; P2=$(qid_of "$out")
[ "$rc" = 10 ] && [ -n "$P2" ] && [ "$P2" != "$P1" ] && [ "$(rec "$P1" state)" = done ] && [ "$(rec "$P2" state)" = parked ] && ok "exit 10 with a new id; the first done, the second parked" || bad "rc $rc: $out"

echo "== a listed Bash call: yes allows that call, no denies, maybe refuses"
export SALA_DEFER_TOOLS="AskUserQuestion Bash"
BASHIN='{"command":"curl -H \"Authorization: Bearer '"$TOKEN"'\" https://example.invalid/x -d ANTHROPIC_API_KEY='"$DUMMY"'","description":"fetch"}'
out=$(FAKE_TOOL=Bash FAKE_INPUT="$BASHIN" "$SALA" question run --cwd "$HOME/work" "x" 2>&1); B1=$(qid_of "$out")
python3 - "$(lastcall)" <<'PY' && ok "the run's hook matcher lists both tools" || bad "settings: $(tail -1 "$FAKE_LOG")"
import json, sys
a = json.loads(sys.argv[1])["argv"]; assert json.loads(a[a.index("--settings") + 1])["hooks"]["PreToolUse"][0]["matcher"] == "AskUserQuestion|Bash"
PY
[ -n "$B1" ] && [ "$(rec "$B1" tool)" = Bash ] && ok "the Bash call parked" || bad "$out"
out=$("$SALA" resume-answer "$B1" --answer "maybe later" 2>&1); rc=$?; [ "$rc" = 4 ] && has "$out" "answer yes" && ok "'maybe': refused, still parked" || bad "rc $rc: $out"
out=$("$SALA" resume-answer "$B1" --answer "Yes, go ahead" 2>&1); rc=$?; [ "$rc" = 0 ] && has "$out" "ALLOWED as asked" && ok "'yes': that call allowed as asked" || bad "rc $rc: $out"
out=$(FAKE_TOOL=Bash FAKE_INPUT='{"command":"rm -rf x"}' "$SALA" question run --cwd "$HOME/work" "x" 2>&1); B2=$(qid_of "$out")
out=$("$SALA" resume-answer "$B2" --answer "No - too risky" 2>&1); rc=$?; [ "$rc" = 0 ] && has "$out" "DENIED Rowan said no: No - too risky" && ok "'no': denied with the owner's words" || bad "rc $rc: $out"
unset SALA_DEFER_TOOLS
has "$(<"$POSTS")" "wants to run Bash: curl -H" && ! has "$(<"$POSTS")" "$TOKEN" && ! has "$(<"$POSTS")" "$DUMMY" && ok "the post for a Bash call masks the token and the key" || bad "post: $(grep -A3 'wants to run' "$POSTS")"

echo "== the filing seam: SALA_QUESTION_FILE_CMD"
cat > "$HOME/filer.sh" <<EOF
#!/bin/sh
cat > "$HOME/filed-text.txt"; echo "id=\$SALA_QUESTION_ID run=\$SALA_QUESTION_LABEL resume=\$SALA_QUESTION_RESUME" > "$HOME/filed-env.txt"
echo "board#83 extra words"
EOF
chmod +x "$HOME/filer.sh"; n=$(posts)
export SALA_QUESTION_FILE_CMD="$HOME/filer.sh"
KEYQ='{"questions":[{"question":"Use ANTHROPIC_API_KEY='"$DUMMY"' for the call?","header":"K","options":[{"label":"Yes","description":""},{"label":"No","description":""}],"multiSelect":false}]}'
out=$(FAKE_INPUT="$KEYQ" "$SALA" question run --cwd "$HOME/work" --label filer "x" 2>&1); F1=$(qid_of "$out")
[ "$(rec "$F1" item)" = "board#83" ] && [ "$(rec "$F1" filed)" = seam ] && [ "$(posts)" = "$n" ] && ok "the seam's first stdout line kept as the item; no post beside it" || bad "item '$(rec "$F1" item)' filed '$(rec "$F1" filed)'; $(posts) posts vs $n"
grep -q "Use ANTHROPIC_API_KEY" "$HOME/filed-text.txt" && ! grep -qF -- "$DUMMY" "$HOME/filed-text.txt" && ok "the question text on its stdin, the key masked" || bad "text: $(<"$HOME/filed-text.txt")"
grep -q "id=$F1 run=filer resume=sala resume-answer $F1" "$HOME/filed-env.txt" && ok "its environment: the id, the run's label, the answer command" || bad "env: $(<"$HOME/filed-env.txt")"
export SALA_QUESTION_FILE_CMD='exit 1'
out=$(FAKE_INPUT="$TWO" "$SALA" question run --cwd "$HOME/work" "x" 2>&1); rc=$?; F2=$(qid_of "$out")
[ "$rc" = 10 ] && [ -n "$F2" ] && [ -z "$(rec "$F2" filed)" ] && grep -q "filing failed: $F2" "$QLOG" && ok "a failing seam: the run still parks, the failure logged, filed left empty" || bad "rc $rc: $out; filed '$(rec "$F2" filed)'"
export SALA_QUESTION_FILE_CMD="$HOME/filer.sh"; "$SALA" question sweep >/dev/null 2>&1
[ "$(rec "$F2" item)" = "board#83" ] && ok "the sweep files it again" || bad "item: '$(rec "$F2" item)'"
unset SALA_QUESTION_FILE_CMD
"$SALA" question list | grep -q "$F2" && "$SALA" question show "$F2" | grep -q "state: parked" && ok "question list / show" || bad "list: $("$SALA" question list)"

echo "== the result's shape: what the real CLI printed (2.1.307, first real run) and the one the fake first guessed"
out=$("$SALA" question run --cwd "$HOME/work" --label shape-real "x" 2>&1); rc=$?
[ "$rc" = 10 ] && has "$out" "parked: question" && ! has "$out" "the run failed" && ok "real shape (terminal_reason, no stop_reason): parked, exit 10, not 'the run failed'" || bad "rc $rc: $out"
out=$(FAKE_SHAPE=legacy "$SALA" question run --cwd "$HOME/work" --label shape-legacy "x" 2>&1); rc=$?
[ "$rc" = 10 ] && has "$out" "parked: question" && ok "the old shape (stop_reason tool_deferred, no terminal_reason): still parked" || bad "rc $rc: $out"
out=$(FAKE_SHAPE=legacy "$SALA" question run --cwd "$HOME/work" --json "x" 2>/dev/null); rc=$?
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["stop_reason"]=="tool_deferred" and "terminal_reason" not in d' "$out" 2>/dev/null && [ "$rc" = 10 ] && ok "--json on the old shape: raw result, exit 10" || bad "rc $rc: $out"
QPY() { SALA_STATE_DIR="$STATE" python3 -I -S "$ROOT/lib/question.py" "$@"; }
RSID="9d1f7c52-3b8a-4e0d-a6c1-0123456789ab"; RTU="toolu_01TESTTESTTESTTESTTEST00"
RIN='{"questions":[{"question":"Which colour?","header":"Colour","options":[{"label":"Red","description":"Pick Red"},{"label":"Blue","description":"Pick Blue"}],"multiSelect":false}]}'
real_json() {  # <tool_use id> [keys to override, JSON] → the real result JSON, key for key as the first real run printed it
    local ov="${2:-}"; [ -n "$ov" ] || ov='{}'
    python3 -c 'import json,sys
o={"type":"result","subtype":"success","is_error":False,"num_turns":1,"result":"","terminal_reason":"tool_deferred","deferred_tool_use":{"id":sys.argv[1],"name":"AskUserQuestion","input":json.loads(sys.argv[4])},"session_id":sys.argv[3],"permission_denials":[],"uuid":"u-1"}
o.update(json.loads(sys.argv[2])); print(json.dumps(o))' "$1" "$ov" "$RSID" "$RIN"
}
payload AskUserQuestion "$RTU" "$RIN" | sed "s/sess-1/$RSID/" | SALA_DEFER_QUESTIONS=1 SALA_QUESTION_LABEL=realjson "$SALA" hook ask >/dev/null
RQ=$(python3 -c 'import hashlib,sys; print(hashlib.sha1(("%s\0%s" % (sys.argv[1], sys.argv[2])).encode()).hexdigest()[:12])' "$RSID" "$RTU")
res=$(real_json "$RTU" | QPY result); rc=$?
[ "$rc" = 0 ] && [ "$(head -1 <<< "$res")" = "$(printf 'parked\t%s\t%s' "$RQ" "$RSID")" ] && ok "the real result JSON verbatim (no stop_reason key) and the hook's record for that call: parked, with the id the hook filed" || bad "rc $rc: $res"
res=$(real_json "toolu_NOT_RECORDED" | QPY result); rc=$?
[ "$rc" = 1 ] && [ "$(head -1 <<< "$res" | cut -f1)" = error ] && ok "a deferral the hook recorded nothing for is not 'parked' (nothing waits): error, exit 1" || bad "rc $rc: $res"
res=$(real_json "$RTU" '{"terminal_reason":"completed","stop_reason":"end_turn"}' | QPY result); [ "$(head -1 <<< "$res" | cut -f1)" = parked ] && bad "a result that says it completed was parked: $res" || ok "a result whose reasons say it completed is not parked, whatever else it carries"
res=$(real_json "$RTU" '{"deferred_tool_use":null,"terminal_reason":"completed","result":"all done"}' | QPY result)
[ "$(head -1 <<< "$res" | cut -f1)" = done ] && [ "$(tail -1 <<< "$res")" = "all done" ] && ok "a finished run (no deferred_tool_use): done, its text after the line" || bad "$res"
res=$(real_json "$RTU" '{"deferred_tool_use":null,"is_error":true}' | QPY result); [ "$(head -1 <<< "$res" | cut -f1)" = error ] && ok "is_error without a deferral: error, as before" || bad "$res"

echo "== stderr noise beside the result (first real resume: 'the run failed' for a run that finished)"
NOISE="Warning: a hook took 3 s [node 12345]"
out=$(FAKE_STDERR="$NOISE" "$SALA" question run --cwd "$HOME/work" --label noisy "x" 2>&1); rc=$?; N1=$(qid_of "$out")
[ "$rc" = 10 ] && [ -n "$N1" ] && ! has "$out" "the run failed" && ok "a stderr line beside a deferral: still parked (exit 10)" || bad "rc $rc: $out"
out=$(FAKE_STDERR="$NOISE" "$SALA" resume-answer "$N1" --answer Red 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" 'ALLOWED {"Pick a colour?": "Red"}' && ! has "$out" "the run failed" && [ "$(rec "$N1" state)" = done ] && ok "a stderr line beside a finished resume: exit 0, the result text, the record done" || bad "rc $rc: $out; state $(rec "$N1" state)"
out=$("$SALA" question run --cwd "$HOME/work" --label noisy "x" 2>&1); N2=$(qid_of "$out")
out=$(FAKE_STDOUT_PRE="npm warn something printed on stdout" "$SALA" resume-answer "$N2" --answer Blue 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" 'ALLOWED {"Pick a colour?": "Blue"}' && ! has "$out" "the run failed" && ok "a non-JSON line ahead of the result on stdout: the last JSON line is the result (exit 0)" || bad "rc $rc: $out"
out=$("$SALA" question run --cwd "$HOME/work" --label noisy "x" 2>&1); N3=$(qid_of "$out")
export SALA_QUESTION_ANSWER_CMD='if [ "$SALA_QUESTION_ID" = '"$N3"' ]; then echo Red; fi'
out=$(FAKE_STDERR="$NOISE" "$SALA" question sweep 2>&1); unset SALA_QUESTION_ANSWER_CMD
has "$out" "$N3 has an answer" && has "$out" "1 finished" && [ "$(rec "$N3" state)" = done ] && ok "the sweep counts a resume with stderr noise as finished" || bad "sweep: $out; state $(rec "$N3" state)"
res=$(printf 'warning: x\n{"is_error": false, "terminal_reason": "completed", "result": "You picked **Red**.", "session_id": "s-9"}\nnode: exit hook\n' | QPY result); rc=$?
[ "$rc" = 0 ] && [ "$(head -1 <<< "$res")" = "$(printf 'done\t-\ts-9')" ] && [ "$(tail -1 <<< "$res")" = "You picked **Red**." ] && ok "qpy result: noise before and after the JSON line, the JSON line is taken" || bad "rc $rc: $res"
res=$(printf 'not json at all\n' | QPY result); rc=$?; [ "$rc" = 1 ] && [ "$(head -1 <<< "$res" | cut -f1)" = unreadable ] && ok "qpy result: no JSON object anywhere: unreadable, exit 1" || bad "rc $rc: $res"
out=$(FAKE_FAIL="boom: the model service said no (E42)" "$SALA" question run --cwd "$HOME/work" "x" 2>&1); rc=$?
[ "$rc" = 1 ] && has "$out" "the run failed" && has "$out" "boom: the model service said no (E42)" && ok "a real failure (exit 1, nothing on stdout): 'the run failed' with its stderr shown" || bad "rc $rc: $out"
out=$(FAKE_FAIL="boom: key ANTHROPIC_API_KEY=$DUMMY rejected" "$SALA" question run --cwd "$HOME/work" "x" 2>&1)
has "$out" "boom" && ! has "$out" "$DUMMY" && ! grep -qF -- "$DUMMY" "$QLOG" && ok "a key in the failure's stderr is masked in the message and the log" || bad "out: $out"

echo "== a PATH without claude (the sweep runs as a systemd-run --user unit: system PATH, no ~/.local/bin)"
mkdir -p "$HOME/outside"; cp "$ROOT/tests/fake-claude-p.py" "$HOME/outside/claude-elsewhere"; chmod +x "$HOME/outside/claude-elsewhere"
SYSPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
mv "$HOME/.local/bin/claude" "$HOME/claude.off"
n=$(calls)
out=$(env PATH=$SYSPATH SALA_CLAUDE="$HOME/outside/claude-elsewhere" "$SALA" question run --cwd "$HOME/work" --label viaenv "x" 2>&1); rc=$?; V1=$(qid_of "$out")
[ "$rc" = 10 ] && [ -n "$V1" ] && [ "$(calls)" = $((n+1)) ] && ok "claude on no PATH at all, SALA_CLAUDE pointing at it: the run starts and parks" || bad "rc $rc: $out"
python3 - "$(lastcall)" "$HOME/outside" <<'PY' && ok "the run's own PATH has claude's folder in front (what the run starts finds the tools beside it)" || bad "path: $(lastcall)"
import json, sys
assert json.loads(sys.argv[1])["path"].split(":")[0] == sys.argv[2], json.loads(sys.argv[1])["path"]
PY
out=$(env PATH=$SYSPATH SALA_CLAUDE="$HOME/outside/claude-elsewhere" "$SALA" resume-answer "$V1" --answer Red 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" 'ALLOWED {"Pick a colour?": "Red"}' && [ "$(rec "$V1" state)" = done ] && ok "the resume through SALA_CLAUDE with that PATH: finished, exit 0, record done" || bad "rc $rc: $out"
mv "$HOME/claude.off" "$HOME/.local/bin/claude"
out=$(env -u SALA_CLAUDE PATH=$SYSPATH "$SALA" question run --cwd "$HOME/work" --label viahome "x" 2>&1); rc=$?
[ "$rc" = 10 ] && ok "no SALA_CLAUDE, claude not on the PATH: ~/.local/bin/claude is found (the unit's case)" || bad "rc $rc: $out"
mv "$HOME/.local/bin/claude" "$HOME/claude.off"
out=$(env -u SALA_CLAUDE PATH=$SYSPATH "$SALA" question run --cwd "$HOME/work" --label noclaude "x" 2>&1); rc=$?
[ "$rc" = 1 ] && has "$out" "claude was not found" && ok "claude nowhere: 'claude was not found', exit 1, no hang" || bad "rc $rc: $out"
out=$(env PATH=$SYSPATH SALA_CLAUDE="$HOME/not-executable" "$SALA" question run --cwd "$HOME/work" --label noclaude "x" 2>&1); rc=$?
[ "$rc" = 1 ] && has "$out" "claude was not found" && ok "SALA_CLAUDE not an executable (and nothing else to find): not found, exit 1" || bad "rc $rc: $out"
mv "$HOME/claude.off" "$HOME/.local/bin/claude"
python3 - "$(env PATH=$SYSPATH SALA_BIN="$SALA" python3 -I -S "$ROOT/lib/question.py" settings-json)" "$(env PATH=$SYSPATH python3 -I -S "$ROOT/lib/question.py" host-json)" "$SALA" <<'PY' && ok "the hook command is salamander's absolute path and the permission host starts python by its absolute path (neither needs a PATH)" || bad "settings/host json"
import json, os, sys
cmd = json.loads(sys.argv[1])["hooks"]["PreToolUse"][0]["hooks"][0]["command"]
assert cmd == sys.argv[3] + " hook ask" and os.path.isabs(cmd.split()[0]), cmd
h = json.loads(sys.argv[2])["mcpServers"]["salahost"]; assert os.path.isabs(h["command"]) and os.access(h["command"], os.X_OK), h
PY
python3 - "$(env PATH=$SYSPATH SALA_BIN="/opt/with space/salamander" python3 -I -S "$ROOT/lib/question.py" settings-json)" <<'PY' && ok "a salamander path with a space is quoted in the hook command" || bad "quoting"
import json, shlex, sys
cmd = json.loads(sys.argv[1])["hooks"]["PreToolUse"][0]["hooks"][0]["command"]
assert shlex.split(cmd) == ["/opt/with space/salamander", "hook", "ask"], cmd
PY

echo "== the permission host: it denies, always"
out=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}' '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
      '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"approve","arguments":{"tool_name":"Bash","input":{"command":"ls"}}}}' | python3 -I -S "$ROOT/lib/permission-host.py")
python3 - "$out" <<'PY' && ok "initialize answered, one tool 'approve', a call answered with behavior deny and a message" || bad "host: $out"
import json, sys
r = [json.loads(l) for l in sys.argv[1].splitlines()]
assert len(r) == 3 and r[1]["result"]["tools"][0]["name"] == "approve"
d = json.loads(r[2]["result"]["content"][0]["text"]); assert d["behavior"] == "deny" and d["message"]
PY

echo "== nothing sensitive anywhere"
! grep -qF -- "$TOKEN" "$POSTS" "$QLOG" && ! grep -qF -- "$DUMMY" "$POSTS" "$QLOG" && ok "no token or key value in any post or in the question log" || bad "a secret-looking value leaked"
! grep -qiE 'leak|breach|kill|quota|credential' "$POSTS" && ok "no alarming word in any post" || bad "alarming word: $(grep -iE 'leak|breach|kill|quota|credential' "$POSTS")"
"$SALA" question bogus >/dev/null 2>&1; [ $? = 2 ] && "$SALA" question --help 2>&1 | grep -q 'salamander resume-answer QID' && ok "usage: unknown verb exit 2, --help lists resume-answer" || bad "usage"

[ "$fail" = 0 ] && echo "parkedq: pass" || echo "parkedq: FAIL"
exit $fail
