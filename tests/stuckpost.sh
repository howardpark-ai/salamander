#!/usr/bin/env bash
# The stuck-question watch (lib/watch.sh, STUCK-QUESTION WATCH): a pane
# stopped on a terminal-only question (a permission dialog, the read-outside-the-working-folder prompt, a menu: what
# pane_prompt reads as a prompt) hangs unattended, so `watch` posts it once per session per question — the session, the
# dialog's text with secrets masked, the sala-web link — and again only for another question or a later episode. The fake
# claude shows a dialog from a file (FAKE_PROMPT_FILE, drawn as 2.1.29x draws a permission dialog) and holds the pane until a
# key; Slack is a file (SALA_NOTIFY_CMD). Checked: one post for the stuck pane, naming it, the dialog's title, command and
# question and its sala-web link, with no key, token or webhook value in it; the next tick silent; another question → one more
# post; the dialog answered → the record dropped, stuck again → posted again; an idle pane and a busy one never posted; a
# question quoted in the output with the composer under it not a question; the confirm window; a failing notify command →
# the post tried on the next SALA_STUCK_RETRIES ticks, then given up for that question, a later question posted; `watch
# --stuck --dry-run` printing the post and posting, logging and writing nothing; SALA_STUCK_POST=0 reading and keeping
# nothing; a plain `watch` tick running the step; a retired session's record dropped; no secret or alarming word anywhere.
# The Your move row, against a fake stackshot client.py (SALA_STACKSHOT_CLIENT): one open per posted question with the
# session, sender sala-stuck and the one-line 200-character question, none for the same question again, a second open for another
# question; one clear when the dialog goes (tick, retired session, PostToolUse / Stop hook in the pane), none again, none with no row;
# a refusing client leaving the post, its dedup and the hook unharmed, a refused clear retried four times at most.
# Isolated HOME, a private tmux server started with -f /dev/null, the compiled fake claude; no real session is touched.
# Usage: bash tests/stuckpost.sh   (exit 0 = pass; ~20 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_MASTER SALA_RC_SESSION SALA_NO_RELAUNCH SALA_STUCK_POST SALA_STUCK_CONFIRM SALA_STUCK_RETRIES SALA_FLEET_HOSTS
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, tmux_socket_rm
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$HOME/.local/share/claude/versions/9.9.9" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
ln -s "$HOME/.local/share/claude/versions/9.9.9" "$HOME/.local/bin/claude"
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="cat >> $POSTS"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off
export SALA_LIMIT_ALERT=off SALA_LIMIT_RESUME=off SALA_SIGNIN_ALERT=off   # the other watches: not under test
export SALA_SESSION_URL='https://sala.example.test/#s={name}' SALA_STUCK_CONFIRM=0 SALA_STUCK_RETRIES=2
SALA="$ROOT/bin/salamander"; SOCK="sala-stuckpost-$$"; T="tmux -L $SOCK -f /dev/null"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"
WLOG="$HOME/.claude/salamander-watch.log"; STATE="$HOME/.local/state/salamander/stuck.state"; ATTEMPTS="$HOME/attempts.txt"
cleanup() {
    local p
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    for p in $(pgrep -x claude); do [ "$HOME/.local/share/claude/versions/9.9.9" -ef "/proc/$p/exe" ] && kill -9 "$p" 2>/dev/null; done
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux
. "$ROOT/lib/common.sh"
mk() {  # <suffix> <uuid> [prompt file] — a fake claude in tmux session sala-test-<suffix>, wide enough that no dialog line wraps
    local n="$1" u="$2" pf="${3:-}"
    $T new-session -d -s "sala-test-$n" -x 160 -y 40 -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="sala-test-$n" -e FAKE_LOG="$FAKE_LOG" ${pf:+-e FAKE_PROMPT_FILE="$pf"}
    $T send-keys -t "sala-test-$n" "claude" Enter
}
pane() { tmux display -p -t "sala-test-$1" '#{pane_id}'; }
screen() { tmux capture-pane -p -t "$(pane "$1")" | grep -v '^[[:space:]]*$'; }
sw() { "$SALA" watch --stuck >/dev/null 2>&1; }
stv() { awk -F= -v k="$1" '$1==k {print substr($0, length(k)+2); exit}' "$STATE" 2>/dev/null; }
TOKEN="sk-ant-FAKE0123456789abcdefghijklmnopqrstuv"; DUMMY="dummy-key-NOT-REAL-$$"; HEX="0123456789abcdef0123456789abcdef"
HOOK="https://hooks.slack.com/services/T0000/B0000/FAKEFAKEFAKEFAKE"
# the dialogs, drawn as Claude Code 2.1.29x draws a permission dialog: a box, the title, the body, the question, the options
box() {  # <line>… → the box
    local l; echo "╭──────────────────────────────────────────────────────────────────────────────────────────────────────────╮"
    for l in "$@"; do printf '│ %-104s │\n' "$l"; done
    echo "╰──────────────────────────────────────────────────────────────────────────────────────────────────────────╯"
}
bash_q() {  # <command> <description> → a Bash permission dialog
    box "Bash command" "" "  $1" "  $2" "" "Do you want to proceed?" "❯ 1. Yes" "  2. Yes, and don't ask again for similar commands in $DLG" "  3. No, and tell Claude what to do differently (esc)"
}
read_q() { box "Read file outside of the working directory" "" "  $1" "" "Do you want to allow reads from $(dirname "$1") for this session?" "❯ 1. Yes" "  2. Yes, and keep allowing reads from $(dirname "$1")" "  3. No, and tell Claude what to do differently (esc)"; }
# The folder the dialogs name. NOT $HOME: a post is cut at 200 characters (lib/stuck.sh), $HOME is under TMPDIR, and a CI runner's
# TMPDIR is 41-47 characters (RUNNER_TEMP), so a dialog naming $HOME was cut in CI and the expected text did not match.
# Nothing here reads or writes it: it is only text on a screen, so its length is the test's own.
DLG=/srv/stp
PF="$HOME/q-stuck.txt"
bash_q "curl -H \"Authorization: Bearer $TOKEN\" https://example.invalid/x" "Fetch the thing" > "$PF"
mk stuck "$(uuid 1)" "$PF"; mk idle "$(uuid 2)"; mk busy "$(uuid 3)"
fake_up sala-test-stuck sala-test-idle sala-test-busy || exit 1
waitfor 'screen stuck | grep -q "Do you want to proceed"' 20 || { echo "  FAIL the stuck pane shows no dialog: $(screen stuck)"; exit 1; }
waitfor 'screen idle | grep -q "❯"' 20 || { echo "  FAIL the idle pane shows no prompt"; exit 1; }
for f in "$HOME"/.claude/sessions/*.json; do   # the busy pane: its registry row says a turn is running
    grep -q '"name":"sala-test-busy"' "$f" && python3 - "$f" <<'PY'
import json, sys, time
p = sys.argv[1]; o = json.load(open(p)); o["status"] = "busy"; o["statusUpdatedAt"] = int(time.time() * 1000); json.dump(o, open(p, "w"))
PY
done
pane_prompt "$(pane stuck)" && ok "pane_prompt reads the dialog as a terminal-only prompt (the relaunch's own reading)" || bad "pane_prompt misses the dialog: $(screen stuck)"

echo "== one post for the stuck pane, the idle and busy panes left alone"
sw; p=$(lastpost)
[ "$(posts)" = 1 ] && ok "one post" || bad "$(posts) posts: $(slurp "$POSTS")"
has "$(head -1 <<< "$p")" "sala-test-stuck is waiting for an answer in its terminal" && ok "the headline names the session" || bad "headline: $(head -1 <<< "$p")"
has "$p" "it asks: Bash command · curl -H " && has "$p" " · Fetch the thing · Do you want to proceed?" && ok "the question: the dialog's title, command and question" || bad "post: $p"
has "$p" "answer it in sala: https://sala.example.test/#s=sala-test-stuck" && ok "the web UI's link for that session, under the app's name (sala)" || bad "no link: $p"
! has "$p" "$TOKEN" && has "$p" "Authorization: …" && ok "the token in the command masked" || bad "the token in the post: $p"
! grep -q 'sala-test-idle\|sala-test-busy' "$POSTS" && ok "the idle pane and the busy pane: not posted" || bad "$(grep 'sala-test-idle\|sala-test-busy' "$POSTS")"
H1=$(stv s.sala-test-stuck.hash); [ -n "$H1" ] && [ -n "$(stv s.sala-test-stuck.posted)" ] && ok "state: the question's hash and the post remembered" || bad "state: $(slurp "$STATE")"
[ -z "$(grep 'sala-test-idle\|sala-test-busy' "$STATE")" ] && ok "state: nothing for the other panes" || bad "state: $(<"$STATE")"
sw; sw
[ "$(posts)" = 1 ] && ok "the next ticks: silent" || bad "$(posts) posts after two more ticks"

echo "== another question: one more post"
read_q "$DLG/.config/salamander/config" > "$PF"; tmux send-keys -t sala-test-stuck Escape   # the first dialog answered, the next one up
waitfor 'screen stuck | grep -q "Read file outside"' 20 || bad "the second dialog did not show: $(screen stuck)"
sw; p=$(lastpost)
[ "$(posts)" = 2 ] && has "$p" "it asks: Read file outside of the working directory · $DLG/.config/salamander/config · Do you want to allow reads from $DLG/.config/salamander for this session?" \
    && ok "a different question: posted once, its own text" || bad "$(posts) posts: $p"
[ "$(stv s.sala-test-stuck.hash)" != "$H1" ] && ok "state: the new hash" || bad "state: $(<"$STATE")"
sw; [ "$(posts)" = 2 ] && ok "then silent" || bad "$(posts) posts"

echo "== the dialog answered: the record dropped; stuck again: posted again"
rm -f "$PF"; tmux send-keys -t sala-test-stuck Escape
waitfor 'screen stuck | grep -q "❯ *$"' 20 || bad "the pane did not come back to its prompt: $(screen stuck)"
sw
[ "$(posts)" = 2 ] && [ -z "$(stv s.sala-test-stuck.hash)" ] && grep -q 'stuck: sala-test-stuck no longer shows its question' "$WLOG" && ok "no question: nothing posted, the record dropped, logged" || bad "$(posts) posts; state: $(<"$STATE"); log: $(tail -2 "$WLOG")"
read_q "$DLG/.config/salamander/config" > "$PF"; tmux send-keys -t sala-test-stuck Enter   # the same question comes back later
waitfor 'screen stuck | grep -q "Read file outside"' 20 || bad "the dialog did not come back: $(screen stuck)"
sw
[ "$(posts)" = 3 ] && has "$(lastpost)" "Read file outside of the working directory" && ok "a later episode of the same question: posted again" || bad "$(posts) posts: $(lastpost)"

echo "== the confirm window"
bash_q "rm -f $DLG/stp-scratch.txt" "Remove the scratch file" > "$PF"; tmux send-keys -t sala-test-stuck Escape
waitfor 'screen stuck | grep -q "stp-scratch"' 20 || bad "the third dialog did not show"
SALA_STUCK_CONFIRM=1000 sw; SALA_STUCK_CONFIRM=1000 sw
[ "$(posts)" = 3 ] && [ -n "$(stv s.sala-test-stuck.since)" ] && [ -z "$(stv s.sala-test-stuck.posted)" ] && ok "inside the window: not posted, the first sight remembered" || bad "$(posts) posts; state: $(<"$STATE")"
sw; [ "$(posts)" = 4 ] && has "$(lastpost)" "rm -f $DLG/stp-scratch.txt" && ok "past it: posted once" || bad "$(posts) posts: $(lastpost)"

echo "== a question quoted in the output, the composer under it: no question"
printf '%s\n\n%s\n\n%s\n' "I could run it for you. Do you want to proceed?" "────────────────────────────" "❯ " > "$PF"; tmux send-keys -t sala-test-stuck Escape
waitfor 'screen stuck | grep -q "I could run it"' 20 || bad "the quoted question did not show"
sw
[ "$(posts)" = 4 ] && [ -z "$(stv s.sala-test-stuck.hash)" ] && ok "not posted, no record (the earlier record dropped)" || bad "$(posts) posts; state: $(<"$STATE")"

echo "== the notify command failing: tried on the next ticks, then given up for that question"
bash_q "env ANTHROPIC_API_KEY=$DUMMY ./stp-run.sh --hex $HEX" "Run it with the key" > "$PF"; tmux send-keys -t sala-test-stuck Escape
waitfor 'screen stuck | grep -q "stp-run.sh"' 20 || bad "the fourth dialog did not show"
for i in 1 2 3 4 5; do SALA_NOTIFY_CMD="cat >> $ATTEMPTS; exit 1" sw; done
[ "$(grep -c '^[^ ]' "$ATTEMPTS")" = 3 ] && [ "$(posts)" = 4 ] && ok "three attempts over five ticks (one, then SALA_STUCK_RETRIES more), nothing posted" || bad "$(grep -c '^[^ ]' "$ATTEMPTS" 2>/dev/null) attempts, $(posts) posts"
[ "$(grep -c 'stuck: the post for sala-test-stuck failed (exit 1), try' "$WLOG")" = 3 ] && grep -q 'try 3 of 3 — given up for this question' "$WLOG" && ok "each attempt logged, the give-up said" || bad "log: $(grep 'failed' "$WLOG")"
sw; [ "$(posts)" = 4 ] && ok "the command back: still nothing for that question" || bad "$(posts) posts: $(lastpost)"
! grep -qF -- "$DUMMY" "$ATTEMPTS" && ! grep -qF -- "$HEX" "$ATTEMPTS" && grep -q 'API_KEY=…' "$ATTEMPTS" && ok "the key's value and the hex run masked in the attempted post" || bad "attempted post: $(<"$ATTEMPTS")"
bash_q "git push -u origin stp-branch" "Push the branch" > "$PF"; tmux send-keys -t sala-test-stuck Escape
waitfor 'screen stuck | grep -q "git push"' 20 || bad "the fifth dialog did not show"
sw; [ "$(posts)" = 5 ] && has "$(lastpost)" "git push -u origin stp-branch" && ok "a later question: posted" || bad "$(posts) posts: $(lastpost)"

echo "== --dry-run: the post printed, nothing posted, logged or written"
bash_q "curl $HOOK -d x" "Post to the hook" > "$PF"; tmux send-keys -t sala-test-stuck Escape
waitfor 'screen stuck | grep -q "Post to the hook"' 20 || bad "the sixth dialog did not show"
n=$(grep -c . "$WLOG"); s=$(<"$STATE")
out=$("$SALA" watch --stuck --dry-run 2>&1)
has "$out" "would post for sala-test-stuck:" && has "$out" "it asks: Bash command · curl https://hooks.slack.com/… -d x · Post to the hook · Do you want to proceed?" && has "$out" "answer it in sala: https://sala.example.test/#s=sala-test-stuck" \
    && ok "the dry run prints the post, the webhook masked" || bad "dry run: $out"
[ "$(posts)" = 5 ] && [ "$(grep -c . "$WLOG")" = "$n" ] && [ "$(<"$STATE")" = "$s" ] && ok "nothing posted, logged or written" || bad "$(posts) posts; log +$(( $(grep -c . "$WLOG") - n )); state: $(<"$STATE")"
sw; [ "$(posts)" = 6 ] && ok "the real tick after it: posted" || bad "$(posts) posts"

echo "== the knob off, a plain watch tick"
bash_q "ls $DLG/stp-knob" "List it" > "$PF"; tmux send-keys -t sala-test-stuck Escape
waitfor 'screen stuck | grep -q "stp-knob"' 20 || bad "the seventh dialog did not show"
s=$(<"$STATE"); SALA_STUCK_POST=0 sw; SALA_STUCK_POST=off sw
[ "$(posts)" = 6 ] && [ "$(<"$STATE")" = "$s" ] && ok "SALA_STUCK_POST=0 / off: nothing posted, the state untouched" || bad "$(posts) posts; state: $(<"$STATE")"
for s in $(tmux list-sessions -F '#{session_name}'); do "$SALA" adopt "$s" >/dev/null 2>&1; done   # into the pane map first: a plain tick with no master runs the whole tick, its unmapped report included
"$SALA" watch >/dev/null 2>&1   # no master configured: the tick runs this step with the rest
[ "$(posts)" = 7 ] && has "$(lastpost)" "stp-knob" && ok "a plain watch tick runs the step" || bad "$(posts) posts after a plain watch: $(lastpost)"

echo "== the Your move row: opened with the post, once per question; closed when the pane stops waiting; stackshot failing changes nothing"
FC="$HOME/fc"; mkdir -p "$FC"
cat > "$FC/client.py" <<'PY'
import os, sys
# a fake stackshot client.py: `post terminal-prompt open|clear`; appends "verb TAB session TAB question TAB sender" to ./calls; refuses (exit 1) while ./fail exists.
# STRICT like the real one (stackshot client.py `_opts` and `terminal_prompt`): `--name value` pairs only, in two argv slots; `--question=x` or anything else left over
# prints the usage and exits 1; the question one line, 200 characters at most (TERMINAL_PROMPT_Q_MAX)
a = sys.argv[1:]; d = os.path.dirname(os.path.abspath(__file__))
USAGE = "usage: client.py post terminal-prompt open --session <name|id> --question \"<one line, at most 200 characters>\" --sender <label>"
if a[:2] != ["post", "terminal-prompt"]: sys.exit(2)
v, r, opt = (a[2] if len(a) > 2 else ""), a[3:], {}
if v not in ("open", "clear"): print(USAGE, file=sys.stderr); sys.exit(1)
for k in (("session", "question", "sender") if v == "open" else ("session", "sender")):
    if "--" + k in r:
        i = r.index("--" + k)
        if i + 1 >= len(r): print("--" + k + " needs a value\n" + USAGE, file=sys.stderr); sys.exit(1)
        opt[k] = r[i + 1]; del r[i:i + 2]
if r: print(USAGE, file=sys.stderr); sys.exit(1)
s, q, snd = opt.get("session", "").strip(), opt.get("question", "").strip(), opt.get("sender", "").strip()
if not s or not snd or (v == "open" and not q): print(USAGE, file=sys.stderr); sys.exit(1)
if v == "open" and ("\n" in q or "\r" in q or len(q) > 200): print("the question must be one line of at most 200 characters\n" + USAGE, file=sys.stderr); sys.exit(1)
open(os.path.join(d, "calls"), "a").write("\t".join([v, s, q, snd]) + "\n")
if os.path.exists(os.path.join(d, "fail")): print("stackshot: refused (test)", file=sys.stderr); sys.exit(1)
if v == "open": print("board#77")
PY
export SALA_STACKSHOT_CLIENT="$FC/client.py"
fcn() { local n=0 l; { while IFS= read -r l || [ -n "$l" ]; do [[ $l == "$1"$'\t'* ]] && n=$((n + 1)); done < "$FC/calls"; } 2>/dev/null; echo "$n"; }   # <verb> → how many calls
fclast() { tail -1 "$FC/calls" 2>/dev/null; }
W="alpha beta gamma delta alpha beta gamma delta alpha beta gamma delta"   # three of these lines and the title: far over 200 characters
box "Bash command" "" "  echo $W" "  $W" "  $W" "  Say a lot" "" "Do you want to proceed?" "❯ 1. Yes" "  2. No, and tell Claude what to do differently (esc)" > "$PF"; tmux send-keys -t sala-test-stuck Escape
waitfor 'screen stuck | grep -q "Say a lot"' 20 || bad "the long dialog did not show: $(screen stuck)"
p0=$(posts); sw
q=$(fclast | cut -f3)
[ "$(posts)" = $((p0 + 1))  ] && [ "$(fcn open)" = 1 ] && [ "$(fclast | cut -f1,2,4)" = $'open\tsala-test-stuck\tsala-stuck' ] && ok "one open for the post, with the session and the sender sala-stuck" || bad "$(posts) posts; calls: $(slurp "$FC/calls")"
[ "${#q}" = 200 ] && [[ $q != *$'\n'* ]] && [[ $q == "Bash command · echo alpha beta"* ]] && ok "the question: the post's summary, one line, ${#q} characters (200 at most)" || bad "question (${#q}): $q"
[ "$(stv s.sala-test-stuck.row)" = 1 ] && [ "$(stv s.sala-test-stuck.pane)" = "$(pane stuck)" ] && [ "$(stv s.sala-test-stuck.sess)" = sala-test-stuck ] && ok "state: row=1 (and the pane and the session it belongs to)" || bad "state: $(<"$STATE")"
sw; sw
[ "$(posts)" = $((p0 + 1)) ] && [ "$(fcn open)" = 1 ] && ok "the next ticks: no second post, no second open" || bad "$(posts) posts; calls: $(slurp "$FC/calls")"
bash_q "git log --oneline -3" "Show the log" > "$PF"; tmux send-keys -t sala-test-stuck Escape
waitfor 'screen stuck | grep -q "Show the log"' 20 || bad "the next dialog did not show"
sw
[ "$(fcn open)" = 2 ] && [[ $(fclast | cut -f3) == *"git log --oneline -3 · Show the log"* ]] && [ "$(stv s.sala-test-stuck.row)" = 1 ] && ok "a different question for the same session: open again (stackshot updates the question), row=1 kept" || bad "calls: $(slurp "$FC/calls"); state: $(<"$STATE")"
rm -f "$PF"; tmux send-keys -t sala-test-stuck Escape
waitfor 'screen stuck | grep -q "❯ *$"' 20 || bad "the pane did not come back to its prompt: $(screen stuck)"
sw
[ "$(fcn clear)" = 1 ] && [ "$(fclast | cut -f1,2,4)" = $'clear\tsala-test-stuck\tsala-stuck' ] && [ -z "$(stv s.sala-test-stuck.row)" ] && [ -z "$(stv s.sala-test-stuck.hash)" ] && ok "the dialog gone: one clear, row and record dropped" || bad "calls: $(slurp "$FC/calls"); state: $(<"$STATE")"
sw; sw
[ "$(fcn clear)" = 1 ] && ok "the next ticks: no second clear" || bad "$(fcn clear) clears"
grep -q 'stuck: terminal-prompt open ok: board#77' "$WLOG" && grep -q 'stuck: terminal-prompt clear ok' "$WLOG" && ok "both calls logged in the sala log (the stackshot answer with them)" || bad "log: $(grep terminal-prompt "$WLOG")"
! grep -q 'board#77' "$POSTS" && ok "the stackshot answer is not in any post" || bad "answer in a post"

echo "== the stackshot call failing: the notice is posted all the same; nothing to clear afterwards"
: > "$FC/fail"; p0=$(posts); o0=$(fcn open); c0=$(fcn clear)
bash_q "git push origin fail-branch" "Push it" > "$PF"; tmux send-keys -t sala-test-stuck Enter   # (the pane is at its prompt: Enter starts the next dialog)
waitfor 'screen stuck | grep -q "fail-branch"' 20 || bad "the dialog did not show"
sw
[ "$(posts)" = $((p0 + 1)) ] && has "$(lastpost)" "git push origin fail-branch" && [ "$(fcn open)" = $((o0 + 1)) ] && [ -z "$(stv s.sala-test-stuck.row)" ] && [ -n "$(stv s.sala-test-stuck.posted)" ] && ok "open refused (exit 1): the post went out, posted is kept, no row=1" || bad "$(posts) posts; calls: $(slurp "$FC/calls"); state: $(<"$STATE")"
grep -q 'stuck: terminal-prompt open failed (exit 1): stackshot: refused (test)' "$WLOG" && ok "the refusal logged with its reason" || bad "log: $(grep terminal-prompt "$WLOG" | tail -2)"
sw; [ "$(posts)" = $((p0 + 1)) ] && [ "$(fcn open)" = $((o0 + 1)) ] && ok "not retried on the next tick (the notice is the record)" || bad "$(fcn open) opens"
rm -f "$PF"; tmux send-keys -t sala-test-stuck Escape
waitfor 'screen stuck | grep -q "❯ *$"' 20 || bad "the pane did not come back to its prompt"
sw
[ "$(fcn clear)" = "$c0" ] && [ -z "$(stv s.sala-test-stuck.hash)" ] && ok "no row open: no clear call, the record dropped as before" || bad "$(fcn clear) clears; state: $(<"$STATE")"
rm -f "$FC/fail"

echo "== a clear stackshot refuses is tried again, four times at most"
bash_q "git pull origin keep-row" "Pull it" > "$PF"; tmux send-keys -t sala-test-stuck Enter
waitfor 'screen stuck | grep -q "keep-row"' 20 || bad "the dialog did not show"
sw; o0=$(fcn open); c0=$(fcn clear)
[ "$(stv s.sala-test-stuck.row)" = 1 ] && ok "row=1 after the open" || bad "state: $(<"$STATE")"
rm -f "$PF"; tmux send-keys -t sala-test-stuck Escape
waitfor 'screen stuck | grep -q "❯ *$"' 20 || bad "the pane did not come back to its prompt"
: > "$FC/fail"; sw
[ "$(fcn clear)" = $((c0 + 1)) ] && [ "$(stv s.sala-test-stuck.row)" = 2 ] && [ -z "$(stv s.sala-test-stuck.hash)" ] && [ "$(stv s.sala-test-stuck.sess)" = sala-test-stuck ] && ok "clear refused: the question's record dropped, the row kept (2 = one failure)" || bad "calls: $(slurp "$FC/calls"); state: $(<"$STATE")"
rm -f "$FC/fail"; sw
[ "$(fcn clear)" = $((c0 + 2)) ] && [ -z "$(stv s.sala-test-stuck.row)" ] && ok "the next tick: cleared, the row dropped" || bad "calls: $(slurp "$FC/calls"); state: $(<"$STATE")"
: > "$FC/fail"; bash_q "git pull origin keep-row2" "Pull it" > "$PF"; tmux send-keys -t sala-test-stuck Enter
waitfor 'screen stuck | grep -q "keep-row2"' 20 || bad "the dialog did not show"
rm -f "$FC/fail"; sw; c0=$(fcn clear); rm -f "$PF"; tmux send-keys -t sala-test-stuck Escape
waitfor 'screen stuck | grep -q "❯ *$"' 20 || bad "the pane did not come back to its prompt"
: > "$FC/fail"; for i in 1 2 3 4 5 6; do sw; done
[ "$(fcn clear)" = $((c0 + 4)) ] && [ -z "$(stv s.sala-test-stuck.row)" ] && grep -q 'terminal-prompt clear for sala-test-stuck given up after 4 tries' "$WLOG" && ok "four refused clears, then given up and the record dropped" || bad "$(( $(fcn clear) - c0 )) clears; state: $(<"$STATE"); log: $(tail -2 "$WLOG")"
rm -f "$FC/fail"

echo "== the hook path: PostToolUse / Stop in the pane closes the row once the dialog is gone"
bash_q "git fetch origin hook-row" "Fetch it" > "$PF"; tmux send-keys -t sala-test-stuck Enter
waitfor 'screen stuck | grep -q "hook-row"' 20 || bad "the dialog did not show"
sw; c0=$(fcn clear)
[ "$(stv s.sala-test-stuck.row)" = 1 ] || bad "no row before the hook run: $(<"$STATE")"
SP="$(pane stuck)"; IP="$(pane idle)"
hk() { echo '{}' | TMUX_PANE="$1" "$SALA" hook "$2" >/dev/null 2>&1; }   # <pane> <post-tool|stop>
hk "$IP" post-tool; hk "$IP" stop; sleep 1
[ "$(fcn clear)" = "$c0" ] && [ "$(stv s.sala-test-stuck.row)" = 1 ] && ok "another pane's hook runs: nothing called" || bad "calls: $(slurp "$FC/calls")"
hk "$SP" post-tool; sleep 1
[ "$(fcn clear)" = "$c0" ] && [ "$(stv s.sala-test-stuck.row)" = 1 ] && ok "a tool finished while the dialog still holds the pane: the row stays" || bad "calls: $(slurp "$FC/calls")"
rm -f "$PF"; tmux send-keys -t sala-test-stuck Escape
waitfor 'screen stuck | grep -q "❯ *$"' 20 || bad "the pane did not come back to its prompt"
hk "$SP" post-tool
waitfor '[ "$(fcn clear)" = $((c0 + 1)) ] && [ -z "$(stv s.sala-test-stuck.hash)" ]' 20 && [ -z "$(stv s.sala-test-stuck.row)" ] && [ -z "$(stv s.sala-test-stuck.hash)" ] && [ "$(fclast | cut -f1,2)" = $'clear\tsala-test-stuck' ] && ok "PostToolUse in that pane, the dialog gone: one clear, row and record dropped" || bad "calls: $(slurp "$FC/calls"); state: $(<"$STATE")"
hk "$SP" post-tool; hk "$SP" stop; sleep 1
[ "$(fcn clear)" = $((c0 + 1)) ] && ok "later hook runs: no second clear" || bad "$(fcn clear) clears"
bash_q "git fetch origin stop-row" "Fetch it" > "$PF"; tmux send-keys -t sala-test-stuck Enter
waitfor 'screen stuck | grep -q "stop-row"' 20 || bad "the dialog did not show"
sw; rm -f "$PF"; tmux send-keys -t sala-test-stuck Escape
waitfor 'screen stuck | grep -q "❯ *$"' 20 || bad "the pane did not come back to its prompt"
hk "$SP" stop
waitfor '[ "$(fcn clear)" = $((c0 + 2)) ] && [ -z "$(stv s.sala-test-stuck.hash)" ]' 20 && [ -z "$(stv s.sala-test-stuck.row)" ] && ok "the Stop hook closes it the same way" || bad "calls: $(slurp "$FC/calls"); state: $(<"$STATE")"

echo "== the session retired while stuck: its record dropped, its row closed"
bash_q "git fetch origin gone-row" "Fetch it" > "$PF"; tmux send-keys -t sala-test-stuck Enter
waitfor 'screen stuck | grep -q "gone-row"' 20 || bad "the dialog did not show"
sw; P_END=$(posts); c0=$(fcn clear)
[ "$(stv s.sala-test-stuck.row)" = 1 ] || bad "no row before the retire: $(<"$STATE")"
tmux kill-session -t sala-test-stuck
waitfor '! tmux has-session -t =sala-test-stuck 2>/dev/null' 20
sw
[ "$(fcn clear)" = $((c0 + 1)) ] && [ "$(fclast | cut -f1,2)" = $'clear\tsala-test-stuck' ] && ok "gone: the session's row closed (its name kept in the state)" || bad "calls: $(slurp "$FC/calls")"
unset SALA_STACKSHOT_CLIENT
[ -z "$(stv s.sala-test-stuck.hash)" ] && [ -z "$(stv s.sala-test-stuck.row)" ] && grep -q 'stuck: sala-test-stuck is gone — its record dropped' "$WLOG" && [ "$(posts)" = "$P_END" ] && ok "gone: the record dropped, logged, nothing posted" || bad "state: $(<"$STATE"); log: $(tail -2 "$WLOG")"

echo "== the prompt box's border line is not part of the question"
. "$ROOT/lib/stuck.sh"
BD="$HOME/border-q.txt"
dash=$(printf '╌%.0s' $(seq 1 150)); spaced=$(printf -- '- %.0s' $(seq 1 75))
$T new-session -d -s sala-test-border -x 160 -y 40 -c "$HOME" "cat $BD; sleep 600"
bq() {  # <file> → the summary sq_read gives for the screen in <file>, shown in the border pane
    cp "$1" "$BD"; $T respawn-pane -k -t sala-test-border "cat $BD; sleep 600"; sleep 0.5
    local r; r=$(sq_read "$(pane border)") && printf '%s' "${r#*$'\t'}"
}
CMD="git status --short | head -3; git checkout -b next-c"
for kind in "$dash" "$spaced"; do
    { echo "$kind"; echo "Bash command"; echo; echo "  $CMD"; echo "  Show the status"; echo "$kind"; echo; echo "Do you want to proceed?"; echo "❯ 1. Yes"; echo "  2. No, and tell Claude what to do differently (esc)"; } > "$HOME/bq1.txt"
    o=$(bq "$HOME/bq1.txt")
    [ "$o" = "Bash command · $CMD · Show the status · Do you want to proceed?" ] && ok "a border line of ${kind:0:3}… above and below the command: dropped, the question starts with the title and the command" || bad "border pane: $o"
done
{ echo "$dash"; echo "│ Bash command"; echo "│   $CMD"; echo "│ $spaced │"; echo "Do you want to proceed?"; echo "❯ 1. Yes"; echo "  2. No"; } > "$HOME/bq2.txt"
o=$(bq "$HOME/bq2.txt")
[ "${o:0:12}" = "Bash command" ] && [[ $o != *"- - -"* ]] && [[ $o != *"╌╌"* ]] && ok "the border line first, a boxed border line inside: both dropped, the box side stripped from the content" || bad "border pane: $o"
{ echo "Bash command"; echo "  ls -- -x --flag"; echo "- - -"; echo "- - - 5 items"; echo "======"; echo "a_b = c-d"; echo "Do you want to proceed?"; echo "❯ 1. Yes"; echo "  2. No"; } > "$HOME/bq3.txt"
o=$(bq "$HOME/bq3.txt")
[ "$o" = "Bash command · ls -- -x --flag · - - - 5 items · a_b = c-d · Do you want to proceed?" ] && ok "a command with '--' and a '- - - 5 items' line kept (they have letters or digits); '- - -' and '======' dropped" || bad "border pane: $o"
{ echo "$dash"; echo "Bash command"; echo "  $CMD"; echo "Do you want to proceed?"; echo "❯ 1. Yes"; } > "$HOME/bq4.txt"
o=$(bq "$HOME/bq4.txt"); [ "${#o}" -le 200 ] && [[ $o == *"$CMD"* ]] && ok "the 200 characters are spent on the question, not on the border" || bad "border pane (${#o}): $o"
$T kill-session -t sala-test-border 2>/dev/null

echo "== the open call's arguments are the real client's (--question=… was left over for client.py, which prints the usage and exits 1)"
export SALA_STACKSHOT_CLIENT="$FC/client.py"; : > "$FC/calls"; rm -f "$FC/fail"
QD='- starts with a dash'; QS="Bash command · echo \"a  b\" 'c d' · it's  \"quoted\" \$HOME \`x\`"; QL=$(printf 'word%.0s ' $(seq 1 80))
sq_row_open sala-test-argchk s.argchk %9 "$QD"
[ "$(fcn open)" = 1 ] && [ "$(fclast | cut -f2,3)" = $'sala-test-argchk\t- starts with a dash' ] && [ "$(stv s.argchk.row)" = 1 ] && ok "a question starting with '-': taken by the strict fake client (two arguments), row=1" || bad "calls: $(slurp "$FC/calls"); state: $(<"$STATE")"
sq_row_open sala-test-argchk s.argchk %9 "$QS"
[ "$(fcn open)" = 2 ] && [ "$(fclast | cut -f3)" = "$(printf '%s' "$QS" | tr -s '[:space:]' ' ')" ] && ok "spaces, quotes, \$ and a backtick in the question: passed through whole, whitespace squeezed" || bad "calls: $(slurp "$FC/calls")"
sq_row_open sala-test-argchk s.argchk %9 "$QL"
[ "$(fcn open)" = 3 ] && [ "$(fclast | cut -f3 | wc -m)" -le 201 ] && ok "a long question: cut at 200 characters, within what client.py takes" || bad "calls: $(slurp "$FC/calls")"
sq_row_open "bad session" s.argchk2 %9 "x"; sq_row_open sala-test-argchk s.argchk %9 "a
b"
[ "$(fcn open)" = 5 ] && [ "$(fclast | cut -f3)" = "a b" ] && ok "a session name with a space and a question with a line break: passed on as arguments, the line break squeezed to a space" || bad "calls: $(slurp "$FC/calls")"
sq_row_open sala-test-argchk s.argchk %9 "   "; rc=$?
[ "$rc" = 0 ] && grep -q 'stuck: terminal-prompt open failed (exit 1): usage:' "$WLOG" && ok "an empty question: refused by the client, logged, never fatal" || bad "rc $rc; log: $(tail -2 "$WLOG")"
# the REAL client.py's own argument parser against sala's arguments, with its network call (post) replaced; skipped where stackshot is not on this box
# (the package path, else the root path of a checkout from before the package: there the file is the program itself; in a new checkout the root file is a forwarder, which
# would swap the module this test patches)
SSHOME="$(getent passwd "$EUID" | cut -d: -f6)/stackshot"
if [ -f "$SSHOME/stackshot/fleet/client.py" ]; then REALC="${SALA_REAL_STACKSHOT_CLIENT:-$SSHOME/stackshot/fleet/client.py}"; else REALC="${SALA_REAL_STACKSHOT_CLIENT:-$SSHOME/client.py}"; fi
if [ -f "$REALC" ] && python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'; then
    cat > "$FC/real.py" <<'PY'
import importlib.util, json, os, sys
# the real stackshot client.py with post() replaced by a recorder: its _opts / terminal_prompt run on sala's own argv, nothing goes on the network
d = os.path.dirname(os.path.abspath(__file__)); real = os.environ["REAL_CLIENT"]
spec = importlib.util.spec_from_file_location("stackshot_client", real); c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
def post(what, body, timeout=0):
    open(os.path.join(d, "real-calls"), "a").write(json.dumps([what, body]) + "\n"); return 200, {"item": "board#77"}
c.post = post
sys.exit(c.main(["client.py"] + sys.argv[1:]))
PY
    export REAL_CLIENT="$REALC" SALA_STACKSHOT_CLIENT="$FC/real.py"; : > "$FC/real-calls"; n0=$(wc -l < "$WLOG")
    sq_row_open sala-test-real s.real %9 "$QD"; sq_row_open sala-test-real s.real %9 "$QS"; sq_row_open sala-test-real s.real %9 "$QL"
    sq_row_run clear --session sala-test-real
    got=$(python3 -c 'import json,sys
for l in open(sys.argv[1]): w, b = json.loads(l); print(w, b["action"], b["session"], b["sender"], len(b.get("question", "")), b.get("question", "")[:20])' "$FC/real-calls" 2>&1)
    [ "$(wc -l < "$FC/real-calls")" = 4 ] && [[ $got == *"terminal-prompt open sala-test-real sala-stuck 20 - starts with a dash"* ]] && [[ $got == *"terminal-prompt clear sala-test-real sala-stuck 0 "* ]] \
        && ok "the real client.py takes sala's open (dash, quotes, 200 characters) and clear arguments: question, session and sender reach its request body" || bad "real client calls: $got; log: $(tail -n +$((n0 + 1)) "$WLOG" | grep terminal-prompt)"
    ! tail -n +$((n0 + 1)) "$WLOG" | grep -q 'terminal-prompt open failed' && ok "no open failure logged against the real client's parser" || bad "log: $(tail -n +$((n0 + 1)) "$WLOG" | grep terminal-prompt)"
else
    echo "  skip the real client.py parser check: no $REALC on this box"
fi
unset SALA_STACKSHOT_CLIENT REAL_CLIENT

echo "== scrub_text: the shell's fast path hands every non-ASCII text to python (whose case folding reads ſ as s and ı as i)"
sc_bad=""
for sc in 'ſecret=hunter2' 'paſſword=hunter2' 'authorizatıon: hunter2' 'credentıal=hunter2' 'secret=hunter2' 'a note about 日本語 and ſecret=hunter2'; do
    sc_out=$(printf '%s' "$sc" | scrub_text); case $sc_out in *hunter2*) sc_bad+=" [$sc → $sc_out]";; esac
done
[ -z "$sc_bad" ] && ok "ſ and ı spellings of secret, password, authorization, credential are masked like the ASCII ones" || bad "not masked:$sc_bad"
[ "$(printf '%s' 'plain 日本語 note' | scrub_text)" = 'plain 日本語 note' ] && [ "$(printf '%s' 'plain note' | scrub_text)" = 'plain note' ] && ok "text without a secret passes unchanged, with and without non-ASCII" || bad "plain text changed"

echo "== nothing sensitive or alarming anywhere"
! grep -qF -- "$TOKEN" "$POSTS" "$WLOG" "$STATE" "$ATTEMPTS" && ! grep -qF -- "$DUMMY" "$POSTS" "$WLOG" "$STATE" "$ATTEMPTS" && ! grep -qF -- "$HEX" "$POSTS" "$WLOG" "$STATE" "$ATTEMPTS" && ! grep -qF -- "$HOOK" "$POSTS" "$WLOG" "$STATE" "$ATTEMPTS" \
    && ok "no token, key, hex run or webhook value in any post, log, state or attempted post" || bad "a secret-looking value leaked"
! grep -qiE 'leak|breach|kill|quota|credential' "$POSTS" && ok "no alarming word in any post" || bad "alarming word: $(grep -iE 'leak|breach|kill|quota|credential' "$POSTS")"
! grep -qE '^[^ ].*[|]' "$POSTS" && ok "no state separator in a headline" || bad "$(grep -E '^[^ ].*[|]' "$POSTS")"

[ "$fail" = 0 ] && echo "stuckpost: pass" || echo "stuckpost: FAIL"
exit $fail
