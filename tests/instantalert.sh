#!/usr/bin/env bash
# The instant alert (lib/hook.sh `hook notify`, lib/stuck.sh sq_instant).
# Claude Code's Notification hook (permission_prompt: the dialog has waited ~6 s with no keystroke; verified on 2.1.307, whose payload is
# {hook_event_name, message: "Claude needs your permission", notification_type}) runs `salamander hook notify`, which reads the pane's
# dialog the way the stuck watch does and posts at once, through the watch's own post path (SALA_NOTIFY_CMD) and the watch's own state
# keys (stuck.state: hash, since, posted, tries), so the watch's 90 s post stays silent for that question. The fake claude shows a dialog
# from a file (FAKE_PROMPT_FILE) as in stuckpost.sh; the hook runs with TMUX_PANE set, as Claude Code's hook child has it.
# Checked: the alert at once inside a confirm window of 1000 s, naming the session, the dialog's question and its link, no secret in it;
# the state keys written; the watch's tick after it silent; the alert twice, once; another question, one more; the watch posting first and
# the alert after it silent; idle_prompt and an unlisted type ignored; a payload without a type but with the permission words alerted; no
# TMUX_PANE, SALA_STUCK_INSTANT=off and SALA_STUCK_POST=off doing nothing; a screen the watch cannot read still alerted on the
# notification's words; a failing notify command leaving the question to the watch's retry; --dry-run printing and writing nothing; garbage
# on stdin and an unwritable state directory never failing the hook; no secret or alarming word in any post, log or state.
# The Your move row: the alert opens it through a fake client.py, once per question; a refusing client leaves the alert alone.
# Isolated HOME, a private tmux server started with -f /dev/null, the compiled fake claude; no real session is touched.
# Usage: bash tests/instantalert.sh   (exit 0 = pass; ~15 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_MASTER SALA_RC_SESSION SALA_NO_RELAUNCH SALA_STUCK_POST SALA_STUCK_CONFIRM SALA_STUCK_RETRIES SALA_STUCK_INSTANT SALA_STUCK_INSTANT_TYPES SALA_FLEET_HOSTS
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect"
touch "$HOME/.claude/salamander-rc.stopped"
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$HOME/.local/share/claude/versions/9.9.9" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
ln -s "$HOME/.local/share/claude/versions/9.9.9" "$HOME/.local/bin/claude"
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="cat >> $POSTS"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off
export SALA_LIMIT_ALERT=off SALA_LIMIT_RESUME=off SALA_SIGNIN_ALERT=off
export SALA_SESSION_URL='https://sala.example.test/#s={name}' SALA_STUCK_CONFIRM=1000 SALA_STUCK_RETRIES=2
SALA="$ROOT/bin/salamander"; SOCK="sala-instant-$$"; T="tmux -L $SOCK -f /dev/null"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"
WLOG="$HOME/.claude/salamander-watch.log"; STATE="$HOME/.local/state/salamander/stuck.state"
cleanup() {
    local p
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    for p in $(pgrep -x claude); do [ "$HOME/.local/share/claude/versions/9.9.9" -ef "/proc/$p/exe" ] && kill -9 "$p" 2>/dev/null; done
    chmod -R u+w "$HOME" 2>/dev/null; rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux
. "$ROOT/lib/common.sh"
mk() {  # <suffix> <uuid> [prompt file]
    local n="$1" u="$2" pf="${3:-}"
    $T new-session -d -s "sala-test-$n" -x 160 -y 40 -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="sala-test-$n" -e FAKE_LOG="$FAKE_LOG" ${pf:+-e FAKE_PROMPT_FILE="$pf"}
    $T send-keys -t "sala-test-$n" "claude" Enter
}
pane() { tmux display -p -t "sala-test-$1" '#{pane_id}'; }
screen() { tmux capture-pane -p -t "$(pane "$1")" | grep -v '^[[:space:]]*$'; }
sw() { "$SALA" watch --stuck >/dev/null 2>&1; }
PERM='{"session_id":"x","hook_event_name":"Notification","message":"Claude needs your permission","notification_type":"permission_prompt"}'
nf() {  # <session suffix> <json> [hook args…] — the hook as Claude Code runs it: the pane in its environment, the payload on stdin
    local s="$1" j="$2"; shift 2
    printf '%s' "$j" | TMUX_PANE="$(pane "$s")" "$SALA" hook notify "$@" 2>&1
}
stv() { awk -F= -v k="$1" '$1==k {print substr($0, length(k)+2); exit}' "$STATE" 2>/dev/null; }
TOKEN="[masked Anthropic key]"; DUMMY="dummy-key-NOT-REAL-$$"
box() {
    local l; echo "╭──────────────────────────────────────────────────────────────────────────────────────────────────────────╮"
    for l in "$@"; do printf '│ %-104s │\n' "$l"; done
    echo "╰──────────────────────────────────────────────────────────────────────────────────────────────────────────╯"
}
bash_q() { box "Bash command" "" "  $1" "  $2" "" "Do you want to proceed?" "❯ 1. Yes" "  2. Yes, and don't ask again for similar commands in $HOME" "  3. No, and tell Claude what to do differently (esc)"; }
ask_q() { box "Colour" "" "Pick a colour?" "❯ 1. Red" "     Red" "  2. Blue" "     Blue" "  3. Type something." "" "  4. Chat about this" "Enter to select · ↑/↓ to navigate · Esc to cancel"; }   # AskUserQuestion's menu, as 2.1.307 draws it
PF="$HOME/q-stuck.txt"
bash_q "curl -H \"Authorization: Bearer $TOKEN\" https://example.invalid/x" "Fetch the thing" > "$PF"
mk stuck "$(uuid 1)" "$PF"; mk idle "$(uuid 2)"
fake_up sala-test-stuck sala-test-idle || exit 1
waitfor 'screen stuck | grep -q "Do you want to proceed"' 20 || { echo "  FAIL the stuck pane shows no dialog: $(screen stuck)"; exit 1; }
waitfor 'screen idle | grep -q "❯"' 20 || { echo "  FAIL the idle pane shows no prompt"; exit 1; }

echo "== the alert at once, inside a confirm window the watch would still wait out"
out=$(nf stuck "$PERM"); p=$(lastpost)
[ "$(posts)" = 1 ] && ok "one post, no wait for SALA_STUCK_CONFIRM (1000 s)" || bad "$(posts) posts: $(slurp "$POSTS"); hook said: $out"
has "$(head -1 <<< "$p")" "sala-test-stuck is waiting for an answer in its terminal" && ok "the headline names the session (the watch's own wording)" || bad "headline: $(head -1 <<< "$p")"
has "$p" "it asks: Bash command · curl -H " && has "$p" " · Fetch the thing · Do you want to proceed?" && ok "the question read off the pane: title, command, question" || bad "post: $p"
has "$p" "answer it in sala: https://sala.example.test/#s=sala-test-stuck" && ok "the session's link" || bad "no link: $p"
! has "$p" "$TOKEN" && has "$p" "Authorization: …" && ok "the token in the command masked" || bad "the token in the post: $p"
[ -z "$out" ] && ok "the hook printed nothing" || bad "the hook printed: $out"
[ -n "$(stv s.sala-test-stuck.hash)" ] && [ -n "$(stv s.sala-test-stuck.posted)" ] && [ -n "$(stv s.sala-test-stuck.since)" ] && [ "$(stv s.sala-test-stuck.tries)" = 0 ] && ok "the watch's keys written: hash, since, posted, tries" || bad "state: $(slurp "$STATE")"
[ -n "$(stv s.sala-test-stuck.instant)" ] && ok "state: the instant alert's time kept" || bad "state: $(<"$STATE")"
grep -q 'stuck: instant alert for sala-test-stuck (permission_prompt)' "$WLOG" && ok "logged in the watch's log" || bad "log: $(tail -3 "$WLOG" 2>/dev/null)"

echo "== the watch after it: silent; the alert again: silent"
SALA_STUCK_CONFIRM=0 sw; SALA_STUCK_CONFIRM=0 sw
[ "$(posts)" = 1 ] && ok "the watch's tick finds the question posted: no second post" || bad "$(posts) posts after the watch"
nf stuck "$PERM" >/dev/null; nf stuck "$PERM" >/dev/null
[ "$(posts)" = 1 ] && ok "the same notification again: once per question" || bad "$(posts) posts after two more"

echo "== another question: one more alert"
ask_q > "$PF"; tmux send-keys -t sala-test-stuck Escape
waitfor 'screen stuck | grep -q "Pick a colour"' 20 || bad "the menu did not show: $(screen stuck)"
nf stuck "$PERM" >/dev/null; p=$(lastpost)
[ "$(posts)" = 2 ] && has "$p" "Pick a colour?" && ok "AskUserQuestion's menu: its own alert" || bad "$(posts) posts: $p"

echo "== the watch posts first: the alert after it is silent"
bash_q "git push -u origin ia-branch" "Push the branch" > "$PF"; tmux send-keys -t sala-test-stuck Escape
waitfor 'screen stuck | grep -q "git push"' 20 || bad "the push dialog did not show"
SALA_STUCK_CONFIRM=0 sw
[ "$(posts)" = 3 ] && has "$(lastpost)" "git push -u origin ia-branch" || bad "$(posts) posts: $(lastpost)"
out=$(nf stuck "$PERM")
[ "$(posts)" = 3 ] && ok "already posted by the watch: the alert adds nothing" || bad "$(posts) posts: $(lastpost)"

echo "== types and switches"
bash_q "ls $HOME/ia-types" "List it" > "$PF"; tmux send-keys -t sala-test-stuck Escape
waitfor 'screen stuck | grep -q "ia-types"' 20 || bad "the dialog did not show"
nf stuck '{"message":"Claude is waiting for your input","notification_type":"idle_prompt"}' >/dev/null
nf stuck '{"message":"x","notification_type":"auth_success"}' >/dev/null
[ "$(posts)" = 3 ] && ok "idle_prompt and an unlisted type: no alert" || bad "$(posts) posts: $(lastpost)"
printf '%s' "$PERM" | "$SALA" hook notify >/dev/null 2>&1
[ "$(posts)" = 3 ] && ok "no TMUX_PANE (a claude -p, a unit): nothing" || bad "$(posts) posts"
SALA_STUCK_INSTANT=off nf stuck "$PERM" >/dev/null; SALA_STUCK_INSTANT=0 nf stuck "$PERM" >/dev/null; SALA_STUCK_POST=off nf stuck "$PERM" >/dev/null
[ "$(posts)" = 3 ] && ok "SALA_STUCK_INSTANT=off / 0 and SALA_STUCK_POST=off: nothing" || bad "$(posts) posts: $(lastpost)"
nf stuck '{"message":"Claude needs your permission to use Bash"}' >/dev/null
[ "$(posts)" = 4 ] && has "$(lastpost)" "ia-types" && ok "a payload with no type but the permission words: alerted" || bad "$(posts) posts: $(lastpost)"
SALA_STUCK_INSTANT_TYPES="idle_prompt" nf idle '{"message":"Claude is waiting","notification_type":"idle_prompt"}' >/dev/null
[ "$(posts)" = 5 ] && ok "SALA_STUCK_INSTANT_TYPES widens the list (idle_prompt on a pane with no dialog: the notification's words)" || bad "$(posts) posts: $(lastpost)"

echo "== a screen the watch cannot read: alerted on the notification's own words"
nf idle '{"message":"Server asks for input: contact form","notification_type":"elicitation_dialog"}' >/dev/null; p=$(lastpost)
[ "$(posts)" = 6 ] && has "$p" "sala-test-idle is waiting for an answer in its terminal" && has "$p" "it asks: Server asks for input: contact form" && ok "elicitation_dialog with no dialog the pattern knows: the words, once" || bad "$(posts) posts: $p"
nf idle '{"message":"Server asks for input: contact form","notification_type":"elicitation_dialog"}' >/dev/null
[ "$(posts)" = 6 ] && ok "the same words again: once" || bad "$(posts) posts"

echo "== a failing notify command: the watch's retry takes over"
bash_q "env ANTHROPIC_API_KEY=$DUMMY ./ia-run.sh" "Run it with the key" > "$PF"; tmux send-keys -t sala-test-stuck Escape
waitfor 'screen stuck | grep -q "ia-run.sh"' 20 || bad "the dialog did not show"
SALA_NOTIFY_CMD="cat >> $HOME/attempts.txt; exit 1" nf stuck "$PERM" >/dev/null
[ "$(posts)" = 6 ] && [ -z "$(stv s.sala-test-stuck.posted)" ] && [ "$(stv s.sala-test-stuck.tries)" = 1 ] && [ -n "$(stv s.sala-test-stuck.hash)" ] && ok "not posted; tries 1; the question's hash kept for the watch" || bad "$(posts) posts; state: $(grep stuck "$STATE")"
grep -q 'the instant alert for sala-test-stuck failed (exit 1)' "$WLOG" && ok "the failure logged" || bad "log: $(tail -2 "$WLOG")"
SALA_STUCK_CONFIRM=0 sw
[ "$(posts)" = 7 ] && has "$(lastpost)" "ia-run.sh" && [ -n "$(stv s.sala-test-stuck.posted)" ] && ok "the watch's next tick posts it" || bad "$(posts) posts: $(lastpost)"
! grep -qF -- "$DUMMY" "$POSTS" "$HOME/attempts.txt" && grep -q 'API_KEY=…' "$HOME/attempts.txt" && ok "the key's value masked in the attempted post too" || bad "attempted post: $(<"$HOME/attempts.txt")"

echo "== --dry-run: printed, nothing posted, logged or written"
bash_q "ls $HOME/ia-dry" "List it" > "$PF"; tmux send-keys -t sala-test-stuck Escape
waitfor 'screen stuck | grep -q "ia-dry"' 20 || bad "the dialog did not show"
n=$(grep -c . "$WLOG"); s=$(<"$STATE"); out=$(nf stuck "$PERM" --dry-run)
has "$out" "would post for sala-test-stuck (instant, permission_prompt):" && has "$out" "it asks: Bash command · ls $HOME/ia-dry" && ok "the dry run prints the post" || bad "dry run: $out"
[ "$(posts)" = 7 ] && [ "$(grep -c . "$WLOG")" = "$n" ] && [ "$(<"$STATE")" = "$s" ] && ok "nothing posted, logged or written" || bad "$(posts) posts; log +$(( $(grep -c . "$WLOG") - n ))"
nf stuck "$PERM" >/dev/null; [ "$(posts)" = 8 ] && ok "the real alert after it: posted" || bad "$(posts) posts"
out=$(nf stuck "$PERM" --dry-run); has "$out" "posted already" && ok "a dry run on a posted question says so" || bad "dry run: $out"

echo "== the hook never fails a turn"
printf 'not json at all' | TMUX_PANE="$(pane stuck)" "$SALA" hook notify >/dev/null 2>&1; r1=$?
printf '' | "$SALA" hook notify >/dev/null 2>&1; r2=$?
chmod a-w "$HOME/.local/state/salamander" "$STATE" "$STATE.lock" 2>/dev/null
ask_q > "$PF"; tmux send-keys -t sala-test-stuck Escape
waitfor 'screen stuck | grep -q "Pick a colour"' 20
nf stuck "$PERM" >/dev/null 2>&1; r3=$?
chmod u+w "$HOME/.local/state/salamander" "$STATE" "$STATE.lock" 2>/dev/null
[ "$r1" = 0 ] && [ "$r2" = 0 ] && [ "$r3" = 0 ] && ok "garbage, an empty payload and a read-only state directory: exit 0 each" || bad "exits $r1 $r2 $r3"
"$SALA" hook notify </dev/null >/dev/null 2>&1 || true
"$SALA" hook 2>&1 | grep -q 'salamander hook notify' && ok "the hook usage lists the verb" || bad "usage: $("$SALA" hook 2>&1 | head -3)"

echo "== a reader that leaves early gets no EPIPE message (hook.sh: sq_panes | awk … exit; claude_pid_under: pids_under | read)"
# SIGPIPE ignored (as under the hook), output far past the pipe buffer, a reader that takes one byte: the builtin printf must stay silent
epipe=$(bash -c '. "$1/lib/common.sh"; . "$1/lib/stuck.sh"; trap "" PIPE
    _panes_get_r() { local _b; printf -v _b "%070000d" 0; printf -v "$1" %s "$_b$_b$_b"; }
    sq_panes | head -c1 >/dev/null
    pids_under $$ $(yes $$ 2>/dev/null | head -n 20000) | head -c1 >/dev/null' _ "$ROOT" 2>&1 >/dev/null)
[ -z "$epipe" ] && ok "sq_panes and pids_under: a closed pipe is silent" || bad "stderr: $epipe"
# the printers that walk by the shell's own loops: a reader that is already gone (`| true`) must not draw a message either
EPD="$HOME/epd"; mkdir -p "$EPD"   # inside the suite's HOME, which its cleanup removes on any exit (a bare mktemp -d here was left by a cancelled run)
epipe2=$(bash -c '. "$1/lib/common.sh"; trap "" PIPE; export HOME; SALA_SET_DIR=$2
    for i in $(seq 1 300); do printf "kind=Provision\nclosed=0\n" > "$2/$i"; done
    pset_open | true
    _step_lines "$(yes "STEP|a|b" 2>/dev/null | head -n 3000)" | true
    SALA_FLEET_HOSTS=$(yes h 2>/dev/null | head -n 3000 | paste -sd" " -) fleet_hosts | true
    pgrep_mine . | true
    work_children $$ | true' _ "$ROOT" "$EPD" 2>&1 >/dev/null)
rm -rf "$EPD"
[ -z "$epipe2" ] && ok "pset_open, _step_lines, fleet_hosts, pgrep_mine, work_children: a closed pipe is silent" || bad "stderr: $epipe2"

echo "== the Your move row: the instant alert opens it, once per question; a failing stackshot changes nothing"
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
bash_q "git rebase origin/ia-row" "Rebase it" > "$PF"; tmux send-keys -t sala-test-stuck Escape
waitfor 'screen stuck | grep -q "ia-row"' 20 || bad "the dialog did not show"
p0=$(posts); out=$(nf stuck "$PERM")
[ "$(posts)" = $((p0 + 1)) ] && [ "$(fcn open)" = 1 ] && [ "$(fclast | cut -f1,2,4)" = $'open\tsala-test-stuck\tsala-stuck' ] && ok "the alert: one post, one open for that session, sender sala-stuck" || bad "$(posts) posts; calls: $(slurp "$FC/calls")"
q=$(fclast | cut -f3); [ -n "$q" ] && [ "${#q}" -le 200 ] && [[ $q != *$'\n'* ]] && has "$(lastpost)" "it asks: $q" && ok "the question is the post's own summary, one line" || bad "question: $q"
[ -z "$out" ] && [ "$(stv s.sala-test-stuck.row)" = 1 ] && [ "$(stv s.sala-test-stuck.pane)" = "$(pane stuck)" ] && ok "the hook printed nothing; state: row=1 and the pane" || bad "hook said: $out; state: $(<"$STATE")"
nf stuck "$PERM" >/dev/null; nf stuck "$PERM" >/dev/null; SALA_STUCK_CONFIRM=0 sw
[ "$(posts)" = $((p0 + 1)) ] && [ "$(fcn open)" = 1 ] && ok "the same notification again, and the watch's tick: no second post, no second open" || bad "$(posts) posts; calls: $(slurp "$FC/calls")"
bash_q "git rebase origin/ia-row2" "Rebase it again" > "$PF"; tmux send-keys -t sala-test-stuck Escape
waitfor 'screen stuck | grep -q "ia-row2"' 20 || bad "the next dialog did not show"
nf stuck "$PERM" >/dev/null
[ "$(posts)" = $((p0 + 2)) ] && [ "$(fcn open)" = 2 ] && [[ $(fclast | cut -f3) == *"ia-row2"* ]] && ok "another question: a second post and a second open (stackshot updates the question)" || bad "$(posts) posts; calls: $(slurp "$FC/calls")"
: > "$FC/fail"; bash_q "git rebase origin/ia-row3" "Rebase it a third time" > "$PF"; tmux send-keys -t sala-test-stuck Escape
waitfor 'screen stuck | grep -q "ia-row3"' 20 || bad "the third dialog did not show"
out=$(nf stuck "$PERM"; echo "rc=$?")
[ "$(posts)" = $((p0 + 3)) ] && has "$(lastpost)" "ia-row3" && [ "$(fcn open)" = 3 ] && [ "$out" = "rc=0" ] && ok "stackshot refusing the open: the alert went out all the same, the hook still exit 0 and silent" || bad "$(posts) posts; hook: $out; calls: $(slurp "$FC/calls")"
grep -q 'stuck: terminal-prompt open failed (exit 1)' "$WLOG" && ok "the refusal logged" || bad "log: $(tail -2 "$WLOG")"
rm -f "$FC/fail"; unset SALA_STACKSHOT_CLIENT

echo "== nothing sensitive or alarming anywhere"
! grep -qF -- "$TOKEN" "$POSTS" "$WLOG" "$STATE" && ! grep -qF -- "$DUMMY" "$POSTS" "$WLOG" "$STATE" && ok "no token or key value in any post, log or state" || bad "a secret-looking value leaked"
! grep -qiE 'leak|breach|kill|quota|credential' "$POSTS" && ok "no alarming word in any post" || bad "alarming word: $(grep -iE 'leak|breach|kill|quota|credential' "$POSTS")"

[ "$fail" = 0 ] && echo "instantalert: pass" || echo "instantalert: FAIL"
exit $fail
