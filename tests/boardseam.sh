#!/usr/bin/env bash
# The parked question's board seams (Thu Oct 22nd 2026; contrib/question-board.py with its wrappers question-board-file.sh and
# question-board-answer.sh, and lib/question.sh's default wiring `qs_seam`), against tests/fake-stackshot-client.py, a client.py that
# enforces the limits the real `post question` and `get answer` have (stackshot's), and tests/fake-claude-p.py. No real board,
# no network, nothing posted anywhere.
# Checked: the default wiring (no client → the post path as before; a client at SALA_STACKSHOT_CLIENT or ~/stackshot/client.py → the
# board scripts for both seams; an explicit SALA_QUESTION_FILE_CMD / _ANSWER_CMD winning; `off` disabling); the filing call's shape
# (project, "[gamma] <label>: <question>" subject, request id = the question id, sender = the run's label, the exact ask line, one
# --option label=line per option, the recommended one, the text on stdin); request-id idempotency passed through (filing again prints
# the same item, the same triple reaches the client); the option mapping (a "(Recommended)" label, a listed Bash call as Yes / No,
# several questions / a multi-select / a label the board cannot take → no buttons, answer in words); the board's limits (a long
# question cut with the pointer line, many questions, an ask kept to 240 characters and cleared of "·" and ";", a subject within 80);
# the answer seam (a decision by label, by text, for two questions; a comment, an empty answer, an item with none, an unreachable client
# and a decision that does not fit the call all leave the question parked); a client refusal (the run still parks, exit 1 from the seam,
# filed left empty and the sweep files it again to the same item); three failed filings in a row announced once as a post (SALA_QUESTION_FILE_TRIES,
# a timeout worded as no answer in time); the sweep run by a unit with the system PATH (no ~/.local/bin) still resuming; the sweep in the watch tick (`watch --questions`, a stub systemd-run/systemctl): nothing without an open
# question, one unit per SALA_QUESTION_SWEEP_EVERY, not while the last runs, off at 0, never failing the tick; no secret in any call.
# Usage: bash tests/boardseam.sh   (exit 0 = pass; ~15 s)
set -u
unset TMUX TMUX_PANE XDG_STATE_HOME SALA_MASTER SALA_DEFER_QUESTIONS SALA_DEFER_TOOLS SALA_QUESTION_FILE_CMD SALA_QUESTION_ANSWER_CMD SALA_QUESTION_LABEL SALA_QUESTION_PROJECT SALA_STACKSHOT_CLIENT SALA_SCOPES SALA_QUESTION_SCOPE FAKE_TOOL FAKE_INPUT FAKE_SECOND FAKE_SID FAKE_CLIENT_FAIL
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC SALA_DEFAULT_SCOPE=gamma SALA_QUESTION_PROJECT=projects/example
trap 'rm -rf "$HOME"' EXIT
mkdir -p "$HOME/.local/bin" "$HOME/work" "$HOME/fakedir" "$HOME/fc" "$HOME/scratch"
export TMPDIR="$HOME/scratch"   # the run's own scratch folder, inside the suite's HOME (its EXIT trap removes it): the last sections check nothing is left in it
cp "$ROOT/tests/fake-claude-p.py" "$HOME/.local/bin/claude"; chmod +x "$HOME/.local/bin/claude"
cp "$ROOT/tests/fake-stackshot-client.py" "$HOME/fc/client.py"; chmod +x "$HOME/fc/client.py"
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.jsonl" FAKE_DIR="$HOME/fakedir" FAKE_CLIENT_DIR="$HOME/fcdata"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="cat >> $POSTS"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT"
SALA="$ROOT/bin/salamander"; STATE="$HOME/.local/state/salamander"; QD="$STATE/questions"; QLOG="$HOME/.claude/salamander-question.log"
CALLS="$FAKE_CLIENT_DIR/calls.jsonl"
calls() { local n; n=$(grep -c . "$FAKE_LOG" 2>/dev/null); echo "${n:-0}"; }
ccalls() { local n; n=$(grep -c . "$CALLS" 2>/dev/null); echo "${n:-0}"; }
qid_of() { sed -n 's/^parked: question \([0-9a-f]*\) .*/\1/p' <<< "$1" | head -1; }
rec() { python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r.get(sys.argv[2],""))' "$QD/$1/record.json" "$2"; }
lp() {  # <python expression> → the expression over the client's last `post question` call: o (options by name), options, text, lines
    python3 - "$CALLS" "$1" <<'PY'
import json, sys
p = [c for c in (json.loads(l) for l in open(sys.argv[1])) if c["argv"][:2] == ["post", "question"]][-1]
a = p["argv"][2:]; o = {}; options = []
for i in range(0, len(a), 2):
    if a[i] == "--option": options.append(a[i + 1])
    else: o[a[i][2:]] = a[i + 1]
print(eval(sys.argv[2], {"o": o, "options": options, "text": p["stdin"], "lines": [l for l in p["stdin"].splitlines() if l.strip()], "len": len, "all": all}))
PY
}
answer_file() { mkdir -p "$FAKE_CLIENT_DIR/answers"; printf '%b' "$2" > "$FAKE_CLIENT_DIR/answers/${1#board#}"; }   # <board#N> <the line, \t and \n as escapes>
par() {  # <input json> [label] → run a parkable question through the fake claude; prints the run's output
    FAKE_INPUT="$1" "$SALA" question run --cwd "$HOME/work" --label "${2:-nightly}" "ask" 2>&1
}
DEFAULT_IN='{"questions":[{"question":"Pick a colour?","header":"Colour","options":[{"label":"Red","description":"The warm one"},{"label":"Blue","description":"The cool one"}],"multiSelect":false}]}'
DUMMY="dummy-key-NOT-REAL-$$"

echo "== the default wiring: the board scripts only when the client exists"
export SALA_STACKSHOT_CLIENT="$HOME/no-such-client.py"
out=$(par "$DEFAULT_IN"); Q0=$(qid_of "$out")
[ -n "$Q0" ] && [ "$(rec "$Q0" filed)" = post ] && [ "$(posts)" = 1 ] && [ ! -e "$CALLS" ] && ok "no client: the question goes out as a post through the notify command, as before" || bad "filed '$(rec "$Q0" filed)', $(posts) posts: $out"
export SALA_STACKSHOT_CLIENT="$HOME/fc/client.py"; n=$(posts)
out=$(par "$DEFAULT_IN"); Q1=$(qid_of "$out")
[ -n "$Q1" ] && [ "$(rec "$Q1" filed)" = seam ] && [ "$(rec "$Q1" item)" = "board#9001" ] && [ "$(posts)" = "$n" ] && ok "a client at SALA_STACKSHOT_CLIENT: filed by the file seam as board#9001, no post beside it" || bad "filed '$(rec "$Q1" filed)' item '$(rec "$Q1" item)': $out; log: $(tail -3 "$QLOG")"
unset SALA_STACKSHOT_CLIENT; mkdir -p "$HOME/stackshot"; cp "$HOME/fc/client.py" "$HOME/stackshot/client.py"; chmod +x "$HOME/stackshot/client.py"
out=$(par "$DEFAULT_IN" other); Q1b=$(qid_of "$out")
[ "$(rec "$Q1b" item)" = "board#9002" ] && ok "with the variable unset the client is ~/stackshot/client.py" || bad "item '$(rec "$Q1b" item)': $out"
n=$(posts); out=$(SALA_STACKSHOT_DIR= par "$DEFAULT_IN" nodir); Q1c=$(qid_of "$out")
[ -n "$Q1c" ] && [ "$(rec "$Q1c" filed)" = post ] && [ "$(posts)" = $((n + 1)) ] && ok "SALA_STACKSHOT_DIR empty: no client, the post path even with ~/stackshot/client.py there" || bad "empty dir: filed '$(rec "$Q1c" filed)', $(posts) posts: $out"
mkdir -p "$HOME/ssdir"; cp "$HOME/fc/client.py" "$HOME/ssdir/client.py"; chmod +x "$HOME/ssdir/client.py"
out=$(SALA_STACKSHOT_DIR="$HOME/ssdir" par "$DEFAULT_IN" otherdir); Q1d=$(qid_of "$out")
[ "$(rec "$Q1d" filed)" = seam ] && ok "SALA_STACKSHOT_DIR=<dir>: the client is <dir>/client.py" || bad "dir: filed '$(rec "$Q1d" filed)': $out"
rm -rf "$HOME/stackshot" "$HOME/ssdir"; export SALA_STACKSHOT_CLIENT="$HOME/fc/client.py"
cat > "$HOME/filer.sh" <<EOF
#!/bin/sh
cat > /dev/null; echo "board#82 by-hand"
EOF
chmod +x "$HOME/filer.sh"; n=$(ccalls)
export SALA_QUESTION_FILE_CMD="$HOME/filer.sh"
out=$(par "$DEFAULT_IN" explicit); Q1c=$(qid_of "$out")
[ "$(rec "$Q1c" item)" = "board#82" ] && [ "$(ccalls)" = "$n" ] && ok "an explicit SALA_QUESTION_FILE_CMD wins: the client is not called" || bad "item '$(rec "$Q1c" item)'; client calls $(ccalls) vs $n"
export SALA_QUESTION_FILE_CMD=off; n=$(ccalls); p=$(posts)
out=$(par "$DEFAULT_IN" offrun); Q1d=$(qid_of "$out")
[ "$(rec "$Q1d" filed)" = post ] && [ "$(posts)" = $((p+1)) ] && [ "$(ccalls)" = "$n" ] && ok "SALA_QUESTION_FILE_CMD=off: the post path, the client untouched even though it exists" || bad "filed '$(rec "$Q1d" filed)'; client calls $(ccalls) vs $n"
export SALA_QUESTION_ANSWER_CMD=off; answer_file board#9001 'decision\tBlue\t\t2026-10-22T10:00:00+04:00\n'; n=$(ccalls)
out=$("$SALA" resume-answer "$Q1" 2>&1); rc=$?
[ "$rc" = 3 ] && [ "$(ccalls)" = "$n" ] && ok "SALA_QUESTION_ANSWER_CMD=off: the board is not read, the question stays parked (exit 3)" || bad "rc $rc: $out"
unset SALA_QUESTION_FILE_CMD SALA_QUESTION_ANSWER_CMD; rm -f "$FAKE_CLIENT_DIR/answers/9001"

echo "== the filing call: project, subject, request id, sender, ask, options, text"
out=$(par "$DEFAULT_IN"); Q2=$(qid_of "$out")
[ "$(lp "o['project']")" = "projects/example" ] && ok "the project is the SALA_QUESTION_PROJECT setting" || bad "project: $(lp "o['project']")"
[ "$(lp "o['subject']")" = "[gamma] nightly: Pick a colour?" ] && ok "subject: [scope] <label>: <first question>" || bad "subject: $(lp "o['subject']")"
[ "$(lp "o['request-id']")" = "$Q2" ] && [ "$(lp "o['sender']")" = nightly ] && ok "request id = the question id; sender = the run's label" || bad "rid $(lp "o['request-id']") sender $(lp "o['sender']")"
[ "$(lp "o['ask']")" = "Decide: Pick a colour? · Recommend: none, your call · Stakes: a background run is parked until you answer · By: any time" ] && ok "the ask line has the exact shape" || bad "ask: $(lp "o['ask']")"
[ "$(lp "options")" = "['Red=The warm one', 'Blue=The cool one']" ] && [ "$(lp "o['recommended']")" = Red ] && ok "one --option label=line per option (the line is the option's description), the first flagged recommended" || bad "options: $(lp options) rec $(lp "o['recommended']")"
[ "$(lp "text.strip()")" = "Pick a colour?  [Red / Blue]" ] && ok "the question text on stdin (sala's own, secrets masked)" || bad "text: $(lp text)"
export SALA_QUESTION_PROJECT="projects/other"; out=$(par "$DEFAULT_IN"); export SALA_QUESTION_PROJECT=projects/example
[ "$(lp "o['project']")" = "projects/other" ] && ok "SALA_QUESTION_PROJECT overrides the project" || bad "project: $(lp "o['project']")"

printf 'SALA_QUESTION_PROJECT=projects/fromconfig\nSALA_STACKSHOT_CLIENT=%s\n' "$HOME/fc/client.py" > "$HOME/conf"; n=$(ccalls)
out=$(env -u SALA_STACKSHOT_CLIENT SALA_CONFIG="$HOME/conf" FAKE_INPUT="$DEFAULT_IN" "$SALA" question run --cwd "$HOME/work" --label fromconf "ask" 2>&1)
[ "$(ccalls)" -gt "$n" ] && [ "$(lp "o['project']")" = "projects/fromconfig" ] && ok "both knobs set in the config file (plain assignments, not exported) reach the scripts" || bad "calls $(ccalls) vs $n; project $(lp "o['project']"): $out"

echo "== request-id idempotency passes through"
n=$(ccalls); I1=$(rec "$Q2" item); I2=$("$SALA" question file "$Q2" >/dev/null 2>&1; rec "$Q2" item)
[ "$I1" = "$I2" ] && [ "$(ccalls)" = $((n+1)) ] && [ "$(lp "o['request-id']")" = "$Q2" ] && [ "$(lp "o['sender']")" = nightly ] && [ "$(python3 -c 'import json; print(json.load(open("'"$FAKE_CLIENT_DIR"'/items.json"))["n"])')" = "$(python3 -c 'import json; print(len(json.load(open("'"$FAKE_CLIENT_DIR"'/items.json"))["map"]))')" ] && ok "filing the same question again reaches the client with the same request id and sender and gets the same item ($I1), and files nothing new" || bad "item $I1 vs $I2; calls $(ccalls) vs $n"

echo "== the option mapping"
out=$(par '{"questions":[{"question":"Which way?","header":"W","options":[{"label":"Left","description":""},{"label":"Right (Recommended)","description":"the usual"},{"label":"Up","description":"x"}],"multiSelect":false}]}'); Q3=$(qid_of "$out")
[ "$(lp "o['recommended']")" = "Right (Recommended)" ] && [ "$(lp "options[0]")" = "Left=Pick “Left”." ] && ok "the option labelled (Recommended) is the recommended one; an option with no description gets a line of its own" || bad "rec $(lp "o['recommended']") opts $(lp options)"
export SALA_DEFER_TOOLS="AskUserQuestion Bash"
out=$(FAKE_TOOL=Bash par '{"command":"rm -rf build","description":"clean"}' bashrun); QB=$(qid_of "$out"); unset SALA_DEFER_TOOLS
[ "$(lp "options")" = "['Yes=Allow this exact call.', 'No=Deny it; nothing is granted.']" ] && [ "$(lp "o['recommended']")" = No ] && has "$(lp "o['ask']")" "Decide: bashrun wants to run Bash: rm -rf build" && ok "a listed Bash call: Yes / No, No (the safe one) flagged, the ask names the call" || bad "opts $(lp options) rec $(lp "o['recommended']") ask $(lp "o['ask']")"
TWO='{"questions":[{"question":"Which size?","header":"Size","options":[{"label":"S","description":""},{"label":"L","description":""}],"multiSelect":false},{"question":"Which toppings?","header":"Top","options":[{"label":"Ham","description":""},{"label":"Egg","description":""},{"label":"Corn","description":""}],"multiSelect":true}]}'
out=$(par "$TWO"); QT=$(qid_of "$out")
[ -n "$(rec "$QT" item)" ] && [ "$(lp "len(options)")" = 0 ] && [ "$(lp "'recommended' in o")" = False ] && has "$(lp "o['ask']")" "(+1 more, see the item, answer one line each as '1: label')" && [ "$(lp "lines[-1]")" = "Answer in words on the item: an option's label or number, one line per question as '1: label'." ] && ok "two questions: no buttons, the ask says there is one more, the item says to answer a line each" || bad "options $(lp options) ask $(lp "o['ask']") last $(lp "lines[-1]")"
out=$(par '{"questions":[{"question":"Which toppings?","header":"Top","options":[{"label":"Ham","description":""},{"label":"Egg","description":""}],"multiSelect":true}]}'); QM=$(qid_of "$out")
[ "$(lp "len(options)")" = 0 ] && ok "a multi-select: no buttons" || bad "options: $(lp options)"
out=$(par '{"questions":[{"question":"Which?","header":"H","options":[{"label":"a=b","description":""},{"label":"C","description":""}],"multiSelect":false}]}'); QE=$(qid_of "$out")
[ "$(lp "len(options)")" = 0 ] && ok "a label with '=' (the board cannot take it): no buttons, answered in words" || bad "options: $(lp options)"
out=$(par '{"questions":[{"question":"Which?","header":"H","options":[{"label":"An option label that is far too long for the board to hold","description":""},{"label":"C","description":""}],"multiSelect":false}]}'); QL=$(qid_of "$out")
[ "$(lp "len(options)")" = 0 ] && ok "a label over 40 characters: no buttons" || bad "options: $(lp options)"

echo "== the board's limits are met here, never by the client"
LONG=$(python3 -c 'print("Q" * 9000)')
out=$(par '{"questions":[{"question":"'"$LONG"'","header":"H","options":[{"label":"A","description":"a"},{"label":"B","description":"b"}],"multiSelect":false}]}' longrun); QX=$(qid_of "$out")
[ -n "$(rec "$QX" item)" ] && ok "a 9000-character question is filed (the client was not refused)" || bad "not filed: $out; $(tail -2 "$QLOG")"
[ "$(lp "len(text) <= 8000 and len(lines) <= 5")" = True ] && has "$(lp "lines[-1]")" "(cut; see sala question show $QX)" && ok "its text is a trimmed head ending with (cut; see sala question show <id>), within 5 lines and 8000 characters" || bad "text: $(lp "len(text)") $(lp "lines[-1]")"
[ "$(lp "len(o['ask']) <= 240 and o['ask'].startswith('Decide: QQQ')")" = True ] && [ "$(lp "len(o['subject']) <= 80")" = True ] && ok "the ask stays within 240 characters and the subject within 80" || bad "ask $(lp "len(o['ask'])") subject $(lp "len(o['subject'])")"
out=$(par '{"questions":[{"question":"Which release train should this go out on tonight?","header":"H","options":[{"label":"A","description":"a"},{"label":"B","description":"b"}],"multiSelect":false}]}' demo-builder-with-a-very-long-session-label-here)
[ "$(lp "len(o['subject']) <= 80 and o['subject'].startswith('[gamma] demo-builder-with-a-very-long…: Which release')")" = True ] && ok "a long label is cut to 30 characters in the subject, so the question stays readable inside 80" || bad "subject: $(lp "o['subject']")"
EIGHT=$(python3 -c 'import json; print(json.dumps({"questions":[{"question":"Question %d?" % i,"header":"H%d" % i,"options":[{"label":"A","description":""},{"label":"B","description":""}],"multiSelect":False} for i in range(1,9)]}))')
out=$(par "$EIGHT"); Q8=$(qid_of "$out")
[ -n "$(rec "$Q8" item)" ] && [ "$(lp "len(lines)")" = 5 ] && [ "$(lp "lines[-2]")" = "(cut; see sala question show $Q8)" ] && [ "$(lp "lines[0]")" = "1. Question 1?  [A / B]" ] && ok "eight questions: the first three lines kept, the cut line, the answer-in-words line: 5 lines, filed" || bad "item '$(rec "$Q8" item)': $(lp "lines")"
out=$(par '{"questions":[{"question":"Ship it; or wait · now? Decide: done: yes","header":"H","options":[{"label":"A","description":""},{"label":"B","description":""}],"multiSelect":false}]}'); QS=$(qid_of "$out")
[ -n "$(rec "$QS" item)" ] && [ "$(lp "';' in o['ask'] or '·' in o['ask'].split(' · Recommend:')[0]")" = False ] && [ "$(lp "o['ask'].count('Decide:')")" = 1 ] && ok "';', ' · ' and a 'Decide:' inside the question are made safe in the ask (the board reads them as several decisions)" || bad "ask: $(lp "o['ask']"); item '$(rec "$QS" item)'"
[ "$(lp "'done:' in text.lower()")" = False ] && ok "'done:' in the text is defused (the board's description gate forbids it)" || bad "text: $(lp text)"

echo "== the answer seam: only a decision, only words that fit the call"
I=$(rec "$Q2" item); N=${I#board#}
out=$("$SALA" resume-answer "$Q2" 2>&1); rc=$?
[ "$rc" = 3 ] && ok "no answer on the item: exit 3, still parked" || bad "rc $rc: $out"
answer_file "$I" 'comment\t\tBlue, I think\t2026-10-22T10:00:00+04:00\n'
out=$("$SALA" resume-answer "$Q2" 2>&1); rc=$?; [ "$rc" = 3 ] && [ "$(rec "$Q2" state)" = parked ] && ok "a comment is never an answer: exit 3, still parked" || bad "rc $rc: $out"
answer_file "$I" 'decision\tGreen\t\t2026-10-22T10:00:00+04:00\n'; n=$(calls)
out=$("$SALA" resume-answer "$Q2" 2>&1); rc=$?
[ "$rc" = 3 ] && [ "$(calls)" = "$n" ] && [ "$(rec "$Q2" state)" = parked ] && grep -q "does not fit the parked call" "$QLOG" && ok "a decision that is no option: not used, claude not started, the reason in the question log" || bad "rc $rc: $out; log: $(tail -2 "$QLOG")"
answer_file "$I" 'decision\tBlue\t\t2026-10-22T10:00:00+04:00\n'
out=$("$SALA" resume-answer "$Q2" 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" 'ALLOWED {"Pick a colour?": "Blue"}' && [ "$(rec "$Q2" state)" = done ] && ok "a decision with the option's label: the run resumed with it" || bad "rc $rc: $out"
IX=$(rec "$Q3" item); answer_file "$IX" 'comment\t\tUp?\t2026-10-22T10:00:00+04:00\n'
out=$("$SALA" question sweep 2>&1); [ "$(rec "$Q3" state)" = parked ] && ok "the sweep leaves a question whose item has only a comment" || bad "sweep: $out"
answer_file "$IX" 'decision\t\t2\t2026-10-22T11:00:00+04:00\n'
out=$("$SALA" question sweep 2>&1)
[ "$(rec "$Q3" state)" = done ] && has "$out" "$Q3 has an answer" && ok "the sweep resumes it once the owner's decision (the owner's words '2', no button) is there" || bad "state $(rec "$Q3" state): $out"
IT=$(rec "$QT" item); answer_file "$IT" 'decision\t\t1: L / 2: ham, 3\t2026-10-22T10:00:00+04:00\n'
out=$("$SALA" resume-answer "$QT" 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" '"Which size?": "L"' && has "$out" '"Which toppings?": "Ham, Corn"' && ok "two questions: the owner's lines (the board writes line breaks as ' / ') are read back as a line each" || bad "rc $rc: $out"
IB=$(rec "$QB" item); answer_file "$IB" 'decision\tYes\t\t2026-10-22T10:00:00+04:00\n'
out=$(SALA_DEFER_TOOLS="AskUserQuestion Bash" "$SALA" resume-answer "$QB" 2>&1); rc=$?; [ "$rc" = 0 ] && has "$out" "ALLOWED as asked" && ok "a Bash call: Yes allows that call" || bad "rc $rc: $out"
IE=$(rec "$QE" item); answer_file "$IE" 'decision\t\tC\t2026-10-22T10:00:00+04:00\n'
out=$("$SALA" resume-answer "$QE" 2>&1); rc=$?; [ "$rc" = 0 ] && has "$out" 'ALLOWED {"Which?": "C"}' && ok "words for a call the board had no buttons for: used when they are an option's label" || bad "rc $rc: $out"
IL=$(rec "$QL" item); answer_file "$IL" 'decision\t\tsomething else entirely\t2026-10-22T10:00:00+04:00\n'
out=$("$SALA" resume-answer "$QL" 2>&1); rc=$?; [ "$rc" = 3 ] && [ "$(rec "$QL" state)" = parked ] && ok "free text is not taken through the seam (sala's --free-text rule): still parked" || bad "rc $rc: $out"
answer_file "$IL" ''
out=$("$SALA" resume-answer "$QL" 2>&1); rc=$?; [ "$rc" = 3 ] && ok "an empty answer: still parked" || bad "rc $rc: $out"
answer_file "$IL" 'decision\tC\t\t2026-10-22T10:00:00+04:00\n'; export FAKE_CLIENT_FAIL=1
out=$("$SALA" resume-answer "$QL" 2>&1); rc=$?; [ "$rc" = 3 ] && grep -q "client exit 1" "$QLOG" && ok "a client that fails (the board unreachable): not yet, logged, nothing run" || bad "rc $rc: $out"
unset FAKE_CLIENT_FAIL
out=$(env SALA_QUESTION_ID="$QL" SALA_QUESTION_ITEM="-" "$ROOT/contrib/question-board-answer.sh" 2>&1); rc=$?; [ "$rc" = 1 ] && [ -z "$out" ] && ok "the answer script with no item: nothing, exit 1" || bad "rc $rc: $out"

echo "== a client refusal: the run parks, the question stays retryable"
export FAKE_CLIENT_FAIL=1; n=$(posts)
out=$(par "$DEFAULT_IN" refused); rc=$?; QR=$(qid_of "$out")
[ -n "$QR" ] && [ -z "$(rec "$QR" filed)" ] && [ -z "$(rec "$QR" item)" ] && grep -q "filing failed: $QR" "$QLOG" && [ "$(posts)" = "$n" ] && ok "the file seam failing (exit 1): the run still parks (id $QR), filed left empty, the failure logged" || bad "filed '$(rec "$QR" filed)': $out"
"$SALA" question sweep >/dev/null 2>&1; [ -z "$(rec "$QR" item)" ] && ok "the sweep tries again and the refusal stands: nothing filed" || bad "item: $(rec "$QR" item)"
unset FAKE_CLIENT_FAIL; "$SALA" question sweep >/dev/null 2>&1
[ -n "$(rec "$QR" item)" ] && [ "$(rec "$QR" filed)" = seam ] && ok "the board back: the sweep files it" || bad "item '$(rec "$QR" item)' filed '$(rec "$QR" filed)'"
n=$(ccalls); out=$(env SALA_STACKSHOT_CLIENT="$HOME/none.py" SALA_QUESTION_ID="$QR" "$ROOT/contrib/question-board-file.sh" <<< "q" 2>&1); rc=$?
[ "$rc" = 1 ] && has "$out" "no stackshot client" && ok "the file script with no client: exit 1 and the reason" || bad "rc $rc: $out"

echo "== a question the board will not take is never left unannounced: one post at the third failure"
export FAKE_CLIENT_FAIL=1; p=$(posts)
out=$(par "$DEFAULT_IN" announce); QA=$(qid_of "$out")
[ -n "$QA" ] && [ "$(posts)" = "$p" ] && [ "$(cat "$QD/$QA/fails")" = 1 ] && ok "the first failed filing (the hook's) counts one and posts nothing" || bad "posts $(posts) vs $p; fails '$(cat "$QD/$QA/fails" 2>/dev/null)': $out"
"$SALA" question sweep >/dev/null 2>&1
[ "$(posts)" = "$p" ] && [ "$(cat "$QD/$QA/fails")" = 2 ] && ok "the second (a sweep): still nothing posted" || bad "posts $(posts) vs $p; fails '$(cat "$QD/$QA/fails")'"
"$SALA" question sweep >/dev/null 2>&1; t=$(tail -n +"$((p+1))" "$POSTS" | tr '\n' ' ')
[ "$(posts)" = $((p+1)) ] && has "$t" "announce is waiting for Rowan's answer" && has "$t" "the board did not take it after 3 tries" && has "$t" "refused (FAKE_CLIENT_FAIL)" && has "$t" "Pick a colour?  [Red / Blue]" && has "$t" "sala resume-answer $QA --answer" && [ -e "$QD/$QA/announced" ] && ok "the third: one post saying the board did not take it, the reason, the question and the answer command" || bad "$(posts) posts: $t"
"$SALA" question sweep >/dev/null 2>&1; "$SALA" question sweep >/dev/null 2>&1
[ "$(posts)" = $((p+1)) ] && [ "$(cat "$QD/$QA/fails")" -ge 5 ] && [ -z "$(rec "$QA" item)" ] && ok "the sweep keeps trying to file it (fails $(cat "$QD/$QA/fails")) and the post is never repeated" || bad "posts $(posts) vs $((p+1)); fails $(cat "$QD/$QA/fails"); item '$(rec "$QA" item)'"
unset FAKE_CLIENT_FAIL; "$SALA" question sweep >/dev/null 2>&1
[ -n "$(rec "$QA" item)" ] && [ ! -e "$QD/$QA/fails" ] && [ "$(posts)" = $((p+1)) ] && ok "the board back: filed, the failure count cleared, still no second post" || bad "item '$(rec "$QA" item)'; posts $(posts)"
export SALA_QUESTION_FILE_TRIES=1 SALA_QUESTION_FILE_CMD='exit 124'; p=$(posts)
out=$(par "$DEFAULT_IN" slow); QW=$(qid_of "$out"); t=$(tail -n +"$((p+1))" "$POSTS" | tr '\n' ' ')
[ "$(posts)" = $((p+1)) ] && has "$t" "after 1 tries" && has "$t" "it did not answer in time" && ok "SALA_QUESTION_FILE_TRIES=1 posts at the first failure; a timeout (exit 124) says it did not answer in time" || bad "$(posts) posts: $t"
unset SALA_QUESTION_FILE_TRIES SALA_QUESTION_FILE_CMD

echo "== the sweep in the watch tick: only with an open question, once per interval, as its own unit"
TOP="$HOME/sd"; mkdir -p "$TOP"
cat > "$HOME/.local/bin/systemd-run" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$TOP/systemd-run.txt"
while [ \$# -gt 0 ] && [ "\$1" != bash ]; do shift; done
if [ -e "$TOP/bare" ]; then ( env -u SALA_CLAUDE PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin "\$@" ) 7>&- </dev/null >/dev/null 2>&1; exit 0; fi   # a real unit: the system PATH, nothing of ours
( "\$@" ) 7>&- </dev/null >/dev/null 2>&1; exit 0
EOF
printf '#!/usr/bin/env bash\ncase "$*" in *is-active*sala-auto-qsweep*) [ -e "%s/unit-active" ] && exit 0 || exit 3;; esac; exit 0\n' "$TOP" > "$HOME/.local/bin/systemctl"
chmod +x "$HOME/.local/bin/systemd-run" "$HOME/.local/bin/systemctl"
nsd() { local n; n=$(grep -c -- '--unit=sala-auto-qsweep' "$TOP/systemd-run.txt" 2>/dev/null); echo "${n:-0}"; }
wq() { "$SALA" watch --questions >/dev/null 2>&1; }
n=$(ccalls); XDG_STATE_HOME="$HOME/nostate" wq
[ "$(nsd)" = 0 ] && [ "$(ccalls)" = "$n" ] && ok "no questions directory: no unit, no client call" || bad "units $(nsd); client calls $(ccalls) vs $n"
mkdir -p "$HOME/donestate/salamander/questions/abc123"; echo '{"qid": "abc123", "state": "done"}' > "$HOME/donestate/salamander/questions/abc123/record.json"
XDG_STATE_HOME="$HOME/donestate" wq
[ "$(nsd)" = 0 ] && [ "$(ccalls)" = "$n" ] && ok "only finished questions: no unit, no client call" || bad "units $(nsd); client calls $(ccalls) vs $n"
out=$(par "$DEFAULT_IN" sweepme); QZ=$(qid_of "$out"); answer_file "$(rec "$QZ" item)" 'decision\tBlue\t\t2026-10-22T10:00:00+04:00\n'; rm -f "$STATE/question-sweep.stamp"
wq
[ "$(nsd)" = 1 ] && grep -q -- '-p RuntimeMaxSec=1800' "$TOP/systemd-run.txt" && grep -q -- 'question sweep' "$TOP/systemd-run.txt" && [ "$(rec "$QZ" state)" = done ] && ok "an open question with the owner's decision: one watch tick launches sala-auto-qsweep (RuntimeMaxSec=1800) and the run is resumed" || bad "units $(nsd); state $(rec "$QZ" state): $(cat "$TOP/systemd-run.txt" 2>/dev/null | tail -1)"
wq; wq
[ "$(nsd)" = 1 ] && ok "the next ticks inside SALA_QUESTION_SWEEP_EVERY (60 s) launch nothing" || bad "units: $(nsd)"
echo 0 > "$STATE/question-sweep.stamp"; touch "$TOP/unit-active"; wq
[ "$(nsd)" = 1 ] && ok "the interval over but the last sweep still running: not launched again" || bad "units: $(nsd)"
rm -f "$TOP/unit-active"; echo 0 > "$STATE/question-sweep.stamp"; SALA_QUESTION_SWEEP_EVERY=0 wq
[ "$(nsd)" = 1 ] && ok "SALA_QUESTION_SWEEP_EVERY=0: disabled" || bad "units: $(nsd)"
SALA_QUESTION_SWEEP_EVERY=30 SALA_QUESTION_SWEEP_TIMEOUT=99 wq
[ "$(nsd)" = 2 ] && grep -q -- 'RuntimeMaxSec=99' "$TOP/systemd-run.txt" && ok "the interval over: launched again, the timeout knob passed" || bad "units: $(nsd)"
chmod 000 "$HOME/.local/bin/systemd-run"; echo 0 > "$STATE/question-sweep.stamp"; "$SALA" watch --questions >/dev/null 2>&1; rc=$?; chmod 755 "$HOME/.local/bin/systemd-run"
[ "$rc" = 0 ] && ok "a launch that cannot start never fails the tick" || bad "rc $rc"

echo "== the sweep unit has the system PATH (no ~/.local/bin): the resume still finds claude"
grep -q -- "--setenv=PATH=$HOME/.local/bin:" "$TOP/systemd-run.txt" && ok "the unit is started with claude's folder at the front of its PATH (--setenv=PATH=...), as well" || bad "options: $(tail -1 "$TOP/systemd-run.txt")"
touch "$TOP/bare"; : > "$QLOG"
out=$(par "$DEFAULT_IN" baresweep); QB=$(qid_of "$out"); answer_file "$(rec "$QB" item)" 'decision\tRed\t\t2026-10-22T10:05:00+04:00\n'; echo 0 > "$STATE/question-sweep.stamp"
SALA_QUESTION_SWEEP_EVERY=30 wq
[ "$(rec "$QB" state)" = done ] && ! grep -q "claude is not on the PATH\|claude was not found\|the run failed" "$QLOG" && ok "the sweep run by a unit without claude on its PATH resumed the question: done" || bad "state $(rec "$QB" state); log: $(tail -3 "$QLOG")"
rm -f "$TOP/bare"

echo "== the subject's scope: SALA_DEFAULT_SCOPE, else the first word of SALA_SCOPES, else the filing is refused with the setting named"
n=$(ccalls)
out=$( unset SALA_DEFAULT_SCOPE SALA_SCOPES; par "$DEFAULT_IN" noscope ); QN=$(qid_of "$out")
[ -n "$QN" ] && [ "$(ccalls)" = "$n" ] && [ -z "$(rec "$QN" filed)" ] && [ -z "$(rec "$QN" item)" ] && grep -q "filing refused: $QN.*SALA_DEFAULT_SCOPE" "$QLOG" && ok "no scope set: nothing is sent to the board (an empty prefix would be refused there), the question stays parked, the log names SALA_DEFAULT_SCOPE" || bad "calls $(ccalls) vs $n, filed '$(rec "$QN" filed)': $out"
out=$( unset SALA_DEFAULT_SCOPE SALA_SCOPES; "$SALA" question file "$QN" 2>&1 ); rc=$?
[ "$rc" != 0 ] && has "$out" "SALA_DEFAULT_SCOPE" && ok "sala question file with no scope: a plain error naming the setting (exit $rc)" || bad "rc $rc: $out"
n=$(ccalls)
out=$( unset SALA_QUESTION_PROJECT; par "$DEFAULT_IN" noproject ); QP=$(qid_of "$out")
[ -n "$QP" ] && [ "$(ccalls)" = "$n" ] && [ -z "$(rec "$QP" filed)" ] && [ -z "$(rec "$QP" item)" ] && grep -q "filing refused: $QP.*SALA_QUESTION_PROJECT" "$QLOG" && ok "no project set: nothing is sent to the board, the log names SALA_QUESTION_PROJECT" || bad "no project: calls $(ccalls) vs $n; filed '$(rec "$QP" filed)'; $(tail -2 "$QLOG")"
out=$( unset SALA_DEFAULT_SCOPE; SALA_SCOPES="delta epsilon" par "$DEFAULT_IN" fallback ); QF=$(qid_of "$out")
[ "$(lp "o['subject']")" = "[delta] fallback: Pick a colour?" ] && [ "$(rec "$QF" filed)" = seam ] && ok "no default scope: the first of SALA_SCOPES opens the subject" || bad "subject: $(lp "o['subject']")"
out=$( unset SALA_DEFAULT_SCOPE; SALA_SCOPES="  delta epsilon" par "$DEFAULT_IN" spaced ); QS=$(qid_of "$out")
[ "$(lp "o['subject']")" = "[delta] spaced: Pick a colour?" ] && [ "$(rec "$QS" filed)" = seam ] && ok "a leading space in SALA_SCOPES does not empty the prefix" || bad "subject: $(lp "o['subject']")"
out=$( SALA_DEFAULT_SCOPE=" gamma"; export SALA_DEFAULT_SCOPE; SALA_SCOPES="delta" par "$DEFAULT_IN" both ); QX=$(qid_of "$out")
[ "$(lp "o['subject']")" = "[gamma] both: Pick a colour?" ] && ok "SALA_DEFAULT_SCOPE wins over SALA_SCOPES, its leading space ignored" || bad "subject: $(lp "o['subject']")"

echo "== no scratch file is left in TMPDIR, whatever ended the call: a success, a refusal, a failure, a stop"
left() { ls -A "$TMPDIR" 2>/dev/null; }
[ -z "$(left)" ] && ok "every run above (filed, refused, failed, timed out) left TMPDIR empty" || bad "left in TMPDIR: $(left | tr '\n' ' ')"
out=$(SALA_QUESTION_FILE_CMD=false par "$DEFAULT_IN" stopq); QZ=$(qid_of "$out")
[ -n "$QZ" ] && [ -z "$(rec "$QZ" filed)" ] && [ -z "$(left)" ] && ok "a parked question whose filing failed (filed left empty), nothing left" || bad "QZ='$QZ' filed '$(rec "$QZ" filed)', left: $(left | tr '\n' ' ')"
RELEASE="$HOME/seam.release"; rm -f "$RELEASE"
SALA_QUESTION_FILE_CMD='cat >/dev/null; i=0; while [ ! -e "$HOME/seam.release" ] && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i+1)); done' "$SALA" question file "$QZ" >/dev/null 2>&1 &
SP=$!
waitfor '[ -n "$(ls -A "$TMPDIR")" ]' 40 && ok "a filing in flight holds one scratch file (the file seam's stderr)" || bad "no scratch file while the seam runs"
case "$(left)" in sala-qfile.*) ok "it is the sala-qfile one" ;; *) bad "unexpected scratch name: $(left | tr '\n' ' ')" ;; esac
kill -TERM "$SP" 2>/dev/null; wait "$SP" 2>/dev/null; : > "$RELEASE"   # the stop (a timeout's SIGTERM, a cancelled job); the seam's own process sees the release file and ends (it gives up after 20 s on its own)
[ -z "$(left)" ] && ok "the filing stopped by SIGTERM left nothing behind (the EXIT trap removed the scratch file)" || bad "left after the stop: $(left | tr '\n' ' ')"

echo "== nothing sensitive, no alarming word"
! grep -qF -- "$DUMMY" "$CALLS" "$POSTS" "$QLOG" && ok "no key value in any client call, post or log" || bad "a secret-looking value leaked"
! grep -qiE 'leak|breach|kill|quota|credential' "$CALLS" && ok "no alarming word in anything the scripts send (subject, ask, options, text)" || bad "alarming word: $(grep -ioE 'leak|breach|kill|quota|credential' "$CALLS" | head -2)"
KEYQ='{"questions":[{"question":"Use ANTHROPIC_API_KEY='"$DUMMY"' for the call?","header":"K","options":[{"label":"Yes","description":""},{"label":"No","description":""}],"multiSelect":false}]}'
out=$(par "$KEYQ" keyrun); QK=$(qid_of "$out")
[ -n "$(rec "$QK" item)" ] && ! grep -qF -- "$DUMMY" "$CALLS" && has "$(lp "o['ask']")" "Use ANTHROPIC_API_KEY" && ok "a key in the question is masked before it reaches the client (the ask carries only the masked words)" || bad "ask: $(lp "o['ask']"); $(grep -c "$DUMMY" "$CALLS") hits"

[ -z "$(left)" ] && ok "at the end of the suite TMPDIR is still empty" || bad "left at the end: $(left | tr '\n' ' ')"
[ "$fail" = 0 ] && echo "boardseam: pass" || echo "boardseam: FAIL"
exit $fail
