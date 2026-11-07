#!/usr/bin/env bash
# Portability smoke test: tmux + a compiled fake `claude` → the proc_* helpers, the process-tree
# functions and the read-only commands must agree with the ground truth on Linux AND macOS.
# Runs in an isolated HOME. Usage: bash tests/smoke.sh   (exit 0 = pass)
set -eu
unset XDG_STATE_HOME   # the pane map goes under the sandbox HOME, never a state dir of the real user
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, tmux_socket_rm
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null
as_op_unit   # no master: the guarded verbs this suite runs itself (adopt) stand for the queue's runner (tests/lib.sh, 5)
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect"
cc -o "$HOME/.local/bin/claude" "$ROOT/tests/fake-claude.c"
export PATH="$HOME/.local/bin:$PATH"
SOCK="sala-smoke-$$"; T="tmux -L $SOCK -f /dev/null"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's (common.sh, on_fleet_server)
cleanup() { $T kill-server 2>/dev/null || true; tmux_socket_rm; sleep 1; rm -rf "$HOME" 2>/dev/null || true; }; trap cleanup EXIT
UUID=11111111-1111-4111-8111-111111111111
$T new-session -d -s smoke -c "$HOME" -e FAKE_SESSION_ID=$UUID -e FAKE_NAME=smoke
$T send-keys -t smoke 'claude' Enter
fake_up smoke || true   # wait for its registry row, not a fixed 2 s: a login shell under load (a CI runner, a parallel run) can start `claude` later than that
. "$ROOT/lib/common.sh"
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux   # literal socket: the child runs set -u
echo "== $(uname -s) $(uname -m) · tmux $(command tmux -V) · ps/lsof helpers"
panepid=$(tmux display -p -t smoke '#{pane_pid}')
# what the runner's log needs when no claude is found under the pane: the pane's process tree, every claude, the registry rows and the screen
pane_diag() {  # <pane pid> <tmux session>
    echo "  --- diag: processes under pane pid $1 (ps -eo pid,ppid,comm,args)"
    { ps -eo pid,ppid,comm,args --forest 2>/dev/null || ps -axo pid,ppid,comm,args 2>/dev/null; } | awk -v root="$1" 'NR == 1 { print; next }
        { pp[$1] = $2; line[$1] = $0; ord[++n] = $1 }
        END { for (i = 1; i <= n; i++) { q = ord[i]; d = 0; while (q != "" && q != 0 && d++ < 4096) { if (q == root) { print line[ord[i]]; break }; q = pp[q] } } }' | sed 's/^/    /'
    echo "  --- diag: processes named claude (comm), first 20, args cut at 150 characters"
    ps -eo pid,ppid,user,comm,args 2>/dev/null | awk 'NR == 1 || $4 ~ /^claude/ { print "    " substr($0, 1, 150) }' | head -n 20 || true
    echo "  --- diag: pid 1 comm '$(cat /proc/1/comm 2>/dev/null)'; this user $(id -un) (uid $EUID); /proc/self/stat readable: $([ -r /proc/self/stat ] && echo yes || echo no); pane_current_command '$(tmux display -p -t "$2" '#{pane_current_command}' 2>/dev/null)'"
    echo "  --- diag: registry rows"
    local f; for f in "$HOME"/.claude/sessions/*.json; do [ -e "$f" ] && echo "    ${f##*/}: $(slurp "$f") (alive: $(proc_alive "${f##*/}" 2>/dev/null && echo y || echo n))"; done
    echo "  --- diag: the pane screen"; tmux capture-pane -p -t "$2" 2>/dev/null | sed '/^[[:space:]]*$/d; s/^/    | /' || true
}
waitfor 'claude_pid_under "$panepid" >/dev/null' 40 || true   # the fake is up by its registry row; this only absorbs the gap before its process is visible under the pane
cpid=$(claude_pid_under "$panepid") && ok "claude_pid_under → $cpid" || { bad "claude_pid_under found nothing under pane pid $panepid"; pane_diag "$panepid" smoke; }
[ "$(proc_ppid "$cpid")" = "$panepid" ] && ok "proc_ppid = pane shell" || bad "proc_ppid $(proc_ppid "$cpid") ≠ $panepid"
is_under "$cpid" "$panepid" && ok "is_under" || bad "is_under"
REAL_HOME=$(cd "$HOME" && pwd -P)   # macOS: $TMPDIR is under /var → /private/var; lsof (and the CLI) report the real path
[ "$(proc_cwd "$cpid")" = "$REAL_HOME" ] && ok "proc_cwd = real \$HOME" || bad "proc_cwd '$(proc_cwd "$cpid")' ≠ $REAL_HOME"
case "$(proc_exe "$cpid")" in */claude) ok "proc_exe → $(proc_exe "$cpid")";; *) bad "proc_exe '$(proc_exe "$cpid")'";; esac
[ "$(proc_version "$cpid")" = "9.9.9" ] && ok "proc_version from registry" || bad "proc_version '$(proc_version "$cpid")'"
proc_args "$cpid" | grep -q claude && ok "proc_args" || bad "proc_args '$(proc_args "$cpid")'"
is_rc_child "$cpid" && bad "is_rc_child false positive" || ok "is_rc_child negative"
waitfor '[ "$(proc_etime "$cpid")" -ge 1 ]' 10 || true   # it was up as soon as its row appeared; the check wants it at least a second old
e=$(proc_etime "$cpid"); [ "$e" -ge 1 ] && [ "$e" -lt 600 ] && ok "proc_etime ${e}s" || bad "proc_etime '$e'"
proc_table | grep -qE "^ *$cpid +$panepid$" && ok "proc_table row" || bad "proc_table lacks $cpid $panepid"
[ "$(registry_field "$cpid" sessionId)" = "$UUID" ] && ok "registry_field sessionId" || bad "registry sessionId '$(registry_field "$cpid" sessionId)'"
live_pane_for_uuid "$UUID" >/dev/null && ok "live_pane_for_uuid" || bad "live_pane_for_uuid"
d=$(session_scratch_dirs "$cpid" "$UUID" | head -1); case "$d" in */tasks) ok "session_scratch_dirs → $d";; *) bad "session_scratch_dirs '$d'";; esac
is_idle "$cpid"; r=$?; [ "$r" = 0 ] && ok "is_idle (registry idle, 60 s old, no children)" || bad "is_idle rc=$r"
# the pure-bash registry reader answers exactly as json.load does: only a complete object is read in the shell
regcase() {  # <label> <row content> <field> <want>
    printf '%s' "$2" > "$SALA_REG_DIR/999991.json"
    local got; got=$(registry_field 999991 "$3")
    [ "$got" = "$4" ] && ok "registry_field $1" || bad "registry_field $1: got '$got', want '$4'"
}
regcase "a complete row"                '{"pid":1,"status":"idle","statusUpdatedAt":17}' status idle
regcase "a truncated row is empty"      '{"pid":1,"status":"idle","statusUpdatedAt":17' status ""
regcase "trailing garbage is empty"     '{"pid":1,"status":"idle"} x' status ""
regcase "a second closing brace is empty" '{"status":"idle"} }' status ""
regcase "a top-level array is empty"    '[{"status":"idle"}]' status ""
regcase "-0 is 0, as in python"         '{"n":-0,"status":"idle"}' n 0
regcase "007 is not JSON: empty"        '{"n":007,"status":"idle"}' n ""
printf '%s' '{"pid":1,"status":"idle","statusUpdatedAt":17' > "$SALA_REG_DIR/999991.json"
is_idle 999991 && r=0 || r=$?; [ "$r" = 2 ] && ok "is_idle on a truncated row is 2 (unknown), not idle" || bad "is_idle truncated row rc=$r"
rm -f "$SALA_REG_DIR/999991.json"
# bin/salamander's bash >= 4.4 check passes under the running bash, and refuses with a message naming 4.4 when the minimum is not met
vchk=$(sed -n '/^# bash-version-check/,/^# end bash-version-check/p' "$ROOT/bin/salamander")
[ -n "$vchk" ] && bash -c "$vchk" 2>/dev/null && ok "bin/salamander bash-version check passes under bash $BASH_VERSION" || bad "bash-version check failed under bash $BASH_VERSION"
out=$(bash -c "${vchk//-lt 4/-lt 99}" 2>&1) && bad "bash-version check passed with a minimum of 99" || { case $out in *"bash >= 4.4"*) ok "bash-version check refuses an old bash, naming 4.4";; *) bad "bash-version message: '$out'";; esac; }
# a second, rc-child-shaped process must be filtered out of the sidecar
$T new-session -d -s rcfake -c "$HOME" -e FAKE_SESSION_ID=cse_01FAKE -e FAKE_NAME=served
$T send-keys -t rcfake 'claude --print --sdk-url https://example.invalid' Enter; fake_up served
rcpid=$(claude_pid_under "$(tmux display -p -t rcfake '#{pane_pid}')")
is_rc_child "$rcpid" && ok "is_rc_child positive" || bad "is_rc_child missed --sdk-url"
echo "== composer: suggestion vs draft (draft_from_capture on real Claude Code 2.1.280 escape sequences)"
E=$(printf '\033'); P=$(printf '\342\235\257\302\240')   # ❯ + NBSP as raw UTF-8 bytes: $'\u…' depends on the locale (macOS runner: C)
chk() { local got; got=$(printf '%s\n' "$2" | draft_from_capture); [ "$got" = "$3" ] && ok "$1" || bad "$1: got '$got', want '$3'"; }
printf '%s\n' "${E}[39m${P}x" | draft_from_capture | grep -qx x && ok "(0) prompt line recognised" || bad "(0) the ❯ input line was not recognised at all — every empty-draft case below would pass vacuously"
chk "(1) empty prompt → no draft"                      "${E}[39m${P}"                                              ""
chk "(2) dim suggestion only → no draft"              "${E}[39m${P}${E}[2mrun the fleet cli update${E}[0m"        ""
chk "(3) typed text → draft, quoted"                  "${E}[39m${P}my own unsent note"                            "my own unsent note"
chk "(4) typed text equal to a suggestion → draft"    "${E}[39m${P}show /etc/adduser.conf"                        "show /etc/adduser.conf"
chk "(5) typed text + dim completion → typed part"    "${E}[39m${P}show ${E}[2m/etc/adduser.conf${E}[0m"         "show"
chk "(6) busy composer (gray prompt) → no draft"      "${E}[38;5;246m${P}${E}[39m"                                ""
chk "(7) last input line wins over scrollback"        "$(printf '%s\n%s' "${E}[39m${P}old message" "${E}[39m${P}")" ""
# the input box in shell mode: after "!" the box line starts with "!" and a no-break space, not ❯;
# the screens below are captures from Claude Code (-e), cut to the lines that matter: a submitted prompt above, then the box between two
# rules (pink while in shell mode), then the footer hint, which also starts with "!"
RULE=$(printf '\342\224\200\342\224\200\342\224\200\342\224\200\342\224\200\342\224\200\342\224\200\342\224\200\342\224\200\342\224\200\342\224\200\342\224\200'); BANG=$(printf '!\302\240')
OLD="${E}[38;5;246m${E}[48;5;237m$(printf '\342\235\257') ${E}[38;5;231mreply with the single word ok${E}[39m"
shellscreen() { printf '%s\n' "$OLD" "" "${E}[38;5;246mWorked for 8s${E}[39m" "" "${E}[38;5;211m${RULE}" "${BANG}${E}[39m$1" "${E}[38;5;211m${RULE}" "${E}[39m  ${E}[38;5;211m! for shell mode${E}[39m"; }
chk "(8) shell mode, nothing typed, old prompt above → no draft"   "$(shellscreen "")"       ""
chk "(9) shell mode, '! ls -la' typed → draft"                      "$(shellscreen " ls -la")" "ls -la"
chk "(10) shell mode, '!' and spaces only → no draft"               "$(shellscreen "   ")"     ""
chk "(11) empty ❯ box, old prompt above → no draft"                 "$(printf '%s\n' "$OLD" "" "${E}[38;5;246m${RULE}" "${E}[39m${P}${E}[2mTry \"refactor <filepath>\"${E}[22m" "${E}[38;5;246m${RULE}" "  ⏵⏵ bypass permissions on")" ""
chk "(12) ❯ box with text, old prompt above → the box's text"       "$(printf '%s\n' "$OLD" "" "${E}[38;5;246m${RULE}" "${E}[39m${P}my unsent note" "${E}[38;5;246m${RULE}" "  ⏵⏵ bypass permissions on")" "my unsent note"
chk "(13) an output rule and a ! line right under it, an empty ❯ box below → no draft" "$(printf '%s\n' "${E}[38;5;246m${RULE}" "! warning: something" "" "${E}[38;5;246m${RULE}" "${E}[39m${P}" "${E}[38;5;246m${RULE}" "  ⏵⏵ bypass permissions on")" ""
FOOT="${E}[39m  ${E}[38;5;211m! for shell mode${E}[39m"
chk "(14) shell mode, '!ls' with no space → draft"                   "$(printf '%s\n' "$OLD" "${E}[38;5;211m${RULE}" "!ls${E}[39m" "${E}[38;5;211m${RULE}" "$FOOT")" "ls"
chk "(15) shell mode, bottom rule off the screen, nothing typed → no draft" "$(printf '%s\n' "$OLD" "" "${E}[38;5;211m${RULE}" "${BANG}${E}[39m")" ""
chk "(16) shell mode, bottom rule off the screen, '! ls' → draft"    "$(printf '%s\n' "$OLD" "" "${E}[38;5;211m${RULE}" "${BANG}${E}[39m ls")" "ls"
chk "(17) shell mode with the placeholder (dim) → no draft"          "$(printf '%s\n' "$OLD" "${E}[38;5;211m${RULE}" "${BANG}${E}[2m${E}[39mTry \"fix typecheck errors\"${E}[0m" "${E}[38;5;211m${RULE}" "$FOOT")" ""
chk "(18) ❯ draft with the '! for shell mode' footer → the draft"    "$(printf '%s\n' "$OLD" "${E}[38;5;246m${RULE}" "${E}[39m${P}my unsent note" "${E}[38;5;246m${RULE}" "$FOOT")" "my unsent note"
chk "(19) multi-line ❯ draft (second line under the first) → a draft" "$(printf '%s\n' "$OLD" "${E}[38;5;246m${RULE}" "${E}[39m${P}first line" "  second line" "${E}[38;5;246m${RULE}" "$FOOT")" "first line"
chk "(20) the footer alone, no box on the screen → no draft"         "$(printf '%s\n' "${E}[38;5;211m${RULE}" "$FOOT")" ""
GREY="${E}[38;5;246m${RULE}"
for note in '! Auto-update failed' '! for shortcuts'; do
    chk "(20a) a '$note' notice on the last row under an empty ❯ box → no draft"  "$(printf '%s\n' "$OLD" "" "$GREY" "${E}[39m${P}" "$GREY" "$note")" ""
    chk "(20b) a '$note' notice under a ❯ draft → the draft"                      "$(printf '%s\n' "$OLD" "" "$GREY" "${E}[39m${P}my draft" "$GREY" "$note")" "my draft"
    chk "(20c) a '$note' notice with the footer after it → not a box"             "$(printf '%s\n' "$OLD" "" "$GREY" "${E}[39m${P}" "$GREY" "$note" "  ⏵⏵ bypass permissions on")" ""
done
chk "(20d) a multi-line ❯ draft with a notice under the bottom rule → the first line" "$(printf '%s\n' "$OLD" "$GREY" "${E}[39m${P}first line" "  second line" "$GREY" "! Auto-update failed")" "first line"
chk "(20e) a stale rule and '! stale' pair in the scrollback, the two last rules hold no box → the old reading (no draft)" "$(printf '%s\n' "$GREY" "! stale" "$GREY" "some output" "more output" "$GREY" "tool output" "$GREY" "last line")" ""
chk "(20f) a multi-paragraph ❯ draft (blank row inside) with a plain '! Auto-update failed' on the last row → the draft" "$(printf '%s\n' "$OLD" "" "$GREY" "${E}[39m${P}my draft" "" "$GREY" "! Auto-update failed")" "my draft"
chk "(20g) the same with the notice dim → the draft" "$(printf '%s\n' "$OLD" "" "$GREY" "${E}[39m${P}my draft" "" "$GREY" "${E}[2m! Auto-update failed${E}[0m")" "my draft"
chkbox() { local got; _box_from_capture "$2"; got=$_BOX_GLYPH; [ "$got" = "$3" ] && ok "$1" || bad "$1: glyph '$got', want '$3'"; }   # which box the lookup found: ❯, !, or none
PINK="${E}[38;5;211m${RULE}"
STALEQ="$(printf '%s\n' "$GREY" "${E}[39m${P}" "some output" "$PINK" "${BANG}${E}[39m" "$PINK" "$FOOT")"
chkbox "(20h) a stale empty ❯ line under an old rule, a real empty shell box below → the ! box" "$STALEQ" "!"
chkbox "(20i) a dialog's '❯ 1. Yes' left in the scrollback, a real empty shell box below → the ! box" "$(printf '%s\n' "$GREY" "${E}[39m${P}1. Yes" "  2. No" "$PINK" "${BANG}${E}[39m" "$PINK" "$FOOT")" "!"
chk "(20j) a stale ❯ line under an old rule, a shell box with '! ls' below → ls" "$(printf '%s\n' "$GREY" "${E}[39m${P}old text" "some output" "$PINK" "${BANG}${E}[39m ls" "$PINK" "$FOOT")" "ls"
chk "(20k) a wrapped ! draft (second row under the first), no ❯ on the screen → the first row" "$(printf '%s\n' "welcome" "$PINK" "${BANG}${E}[39mlong command part one" "  part two" "$PINK" "$FOOT")" "long command part one"
chk "(20l) a multi-paragraph ! draft with a dim '! Auto-update failed' on the last row → the first line" "$(printf '%s\n' "$PINK" "${BANG}${E}[39mecho a" "" "  echo b" "$PINK" "${E}[2m! Auto-update failed${E}[0m")" "echo a"
# tui_send never types into a box in shell mode (leave_shell_mode): a stubbed tmux (a function, in a subshell) serves screens and logs the keys.
# A "!" box gets one Escape first; one that stays in shell mode makes tui_send fail with nothing typed; text in a "!" box is a draft, refused.
echo "== tui_send and shell mode (stubbed tmux)"
STUB=$(mktemp -d "$HOME/stubtmux.XXXXXX")
shellscreen "" > "$STUB/screen.shell"; shellscreen " ls" > "$STUB/screen.shelltext"
printf '%s\n' "$OLD" "${E}[38;5;246m${RULE}" "${E}[39m${P}" "${E}[38;5;246m${RULE}" "  ⏵⏵ bypass permissions on" > "$STUB/screen.prompt"
printf '%s\n' "$OLD" "${E}[38;5;246m${RULE}" "${E}[39m${P}my note" "${E}[38;5;246m${RULE}" "  ⏵⏵ bypass permissions on" > "$STUB/screen.prompttext"
cp "$STUB/screen.shell" "$STUB/screen.racy"
printf '%s\n' "$OLD" "" "✻ Working… (3s · esc to interrupt)" "${E}[38;5;211m${RULE}" "${BANG}${E}[39m" "${E}[38;5;211m${RULE}" "$FOOT" > "$STUB/screen.shellbusy"
# a rewind-style dialog that shows no ❯ box, under a stale "───" / "! warning old" / "───" run of output
printf '%s\n' "$OLD" "${E}[38;5;246m${RULE}" "${BANG}${E}[39m" "${E}[38;5;246m${RULE}" "Rewind to an earlier message" "  first message" "  second message" "  third message" "  fourth message" "  fifth message" "  sixth message" "  seventh message" "  use the arrows" > "$STUB/screen.dialog"
printf '%s\n' "$OLD" "" "Do you want to proceed?" "${E}[38;5;211m${RULE}" "${BANG}${E}[39m" "${E}[38;5;211m${RULE}" "$FOOT" > "$STUB/screen.shelldialog"
shellscreen " /exit" > "$STUB/screen.shellresidue"
printf '%s\n' "$STALEQ" > "$STUB/screen.stalebox"
printf '%s\n' "some output" "" "Rewind to an earlier message" "  first message" > "$STUB/screen.nobox"
tui_stub() {  # <start state> <state an Escape leads to, none to stay> <text> → $STUB/rc, keys, err; screens are $STUB/screen.<state>; racy serves shell once, then shelltext
    ( echo "$1" > "$STUB/state"; : > "$STUB/keys"; ESCTO=$2
      tmux() { case "$1" in
          capture-pane) cat "$STUB/screen.$(cat "$STUB/state")"; [ "$(cat "$STUB/state")" = racy ] && echo shelltext > "$STUB/state" ;;
          send-keys) shift; printf '%s\n' "$*" >> "$STUB/keys"; if [ "$*" = "-t %9 Escape" ] && [ "$ESCTO" != none ]; then echo "$ESCTO" > "$STUB/state"; fi ;;
          *) : ;;
        esac; }
      rc=0; tui_send %9 "$3" 2>"$STUB/err" || rc=$?; echo $rc > "$STUB/rc" )
}
tui_stub shell prompt /exit
[ "$(cat "$STUB/rc")" = 0 ] && [ "$(grep -n . "$STUB/keys" | sed -n '1p;2p;3p' | cut -d: -f2- | paste -sd'|')" = "-t %9 Escape|-t %9 -l /exit|-t %9 Enter" ] \
    && ok "(21) an empty ! box: Escape first, then the text and Enter" || bad "(21) rc=$(cat "$STUB/rc") keys: $(paste -sd'|' "$STUB/keys") err: $(cat "$STUB/err")"
tui_stub shell none /exit
[ "$(cat "$STUB/rc")" = 1 ] && ! grep -q -- ' -l ' "$STUB/keys" && [ "$(grep -c Escape "$STUB/keys")" = 1 ] && grep -q "still in shell mode" "$STUB/err" \
    && ok "(22) a box that stays in shell mode: one Escape, nothing typed, rc 1, one line saying so" || bad "(22) rc=$(cat "$STUB/rc") keys: $(paste -sd'|' "$STUB/keys") err: $(cat "$STUB/err")"
tui_stub prompt prompt /exit
[ "$(cat "$STUB/rc")" = 0 ] && ! grep -q Escape "$STUB/keys" && grep -q -- '-l /exit' "$STUB/keys" \
    && ok "(23) a ❯ box: no Escape, the text typed as before" || bad "(23) rc=$(cat "$STUB/rc") keys: $(paste -sd'|' "$STUB/keys")"
tui_stub shelltext prompt /exit
[ "$(cat "$STUB/rc")" = 1 ] && ! grep -q . "$STUB/keys" && grep -q "unsubmitted text" "$STUB/err" \
    && ok "(24) text in a ! box is a draft: refused, no key sent" || bad "(24) rc=$(cat "$STUB/rc") keys: $(paste -sd'|' "$STUB/keys") err: $(cat "$STUB/err")"
expect_refused() {  # <label> <err word> → rc 1, no key sent at all, one line naming why
    [ "$(cat "$STUB/rc")" = 1 ] && ! grep -q . "$STUB/keys" && grep -q "$2" "$STUB/err" \
        && ok "$1" || bad "$1: rc=$(cat "$STUB/rc") keys: $(paste -sd'|' "$STUB/keys") err: $(cat "$STUB/err")"
}
tui_stub shellbusy prompt /exit
expect_refused "(25) a busy pane with an empty ! box: no Escape, nothing typed, rc 1" "busy"
tui_stub dialog prompt /exit
expect_refused "(26) a dialog under a stale rule and empty-looking ! line pair: no Escape, nothing typed, rc 1" "no live input box"
tui_stub shelldialog prompt /exit
expect_refused "(27) a permission dialog on the screen with a shell box: no Escape, nothing typed, rc 1" "dialog or panel"
tui_stub racy prompt /exit
expect_refused "(28) text appears in the ! box after the draft check read it empty: no Escape, nothing typed, rc 1" "text in its shell box"
tui_stub shell prompttext /exit
[ "$(cat "$STUB/rc")" = 1 ] && [ "$(paste -sd'|' "$STUB/keys")" = "-t %9 Escape" ] && grep -q "after the Escape" "$STUB/err" \
    && ok "(29) text in the box once the Escape has left shell mode: the one Escape, nothing typed, rc 1" || bad "(29) rc=$(cat "$STUB/rc") keys: $(paste -sd'|' "$STUB/keys") err: $(cat "$STUB/err")"
tui_stub shellresidue prompt /exit
expect_refused "(30) sala's own leftover '/exit' in a ! box is not cleared with C-u: refused, no key sent" "unsubmitted text"
tui_stub shell nobox /exit
[ "$(cat "$STUB/rc")" = 1 ] && [ "$(paste -sd'|' "$STUB/keys")" = "-t %9 Escape" ] && grep -q "still in shell mode" "$STUB/err" \
    && ok "(31) the screen shows no box after the Escape: not success, the one Escape, nothing typed, rc 1" || bad "(31) rc=$(cat "$STUB/rc") keys: $(paste -sd'|' "$STUB/keys") err: $(cat "$STUB/err")"
tui_stub stalebox prompt /exit
[ "$(cat "$STUB/rc")" = 0 ] && [ "$(paste -sd'|' "$STUB/keys")" = "-t %9 Escape|-t %9 -l /exit|-t %9 Enter" ] \
    && ok "(32) a stale ❯ line above a real empty shell box: Escape first, then the text (never /exit after the !)" || bad "(32) rc=$(cat "$STUB/rc") keys: $(paste -sd'|' "$STUB/keys") err: $(cat "$STUB/err")"
# $STUB is under the suite's HOME, removed by the EXIT trap
if [ -e /proc/1/environ ] && [ ! -r /proc/1/environ ]; then   # another user's process: its environ is unreadable (Linux, not root)
    re_escape_r pid1_re "$(cat /proc/1/comm)"   # pgrep_mine takes an ERE: on some boxes pid 1 is `init(Distro-12.34)`, comm cut to `init(Distro-12.`
    err=$(pgrep_mine "$pid1_re" 2>&1 >/dev/null || true)   # no match is rc 1: the sandbox HOME owns none
    [ -z "$err" ] && ok "pgrep_mine skips another user's process quietly" || bad "pgrep_mine printed: $err"
fi
# a name with regex metacharacters (`init(Distro-12.34)`, as a comm and as an argv) goes through pgrep_mine as a literal
echo "== pgrep_mine and re_escape_r: names with regex metacharacters"
for w in 'init(Distro-12.34)' 'init(Distro-12.' 'a[b]+c*d' 'x|y' '{1}' 'p\q' '^$' 'a.b' 'q?r'; do
    re_escape_r wre "$w"; wre="^$wre\$"
    miss=""; for near in "${w}x" "x${w}" "${w:0:${#w}-1}"; do [[ $near =~ $wre ]] && miss="$miss '$near'"; done
    if [[ $w =~ $wre ]] && [ -z "$miss" ]; then ok "re_escape_r '$w': matches itself, nothing near it"; else bad "re_escape_r '$w' → $wre (matched near misses:$miss)"; fi
done
re_escape_r wre 'a.b+'; [[ axb+ =~ $wre ]] && bad "re_escape_r 'a.b+': the dot matched a letter" || ok "re_escape_r: a dot is a dot, a plus is a plus"
printf 'init(Distro-12.34)\n' | grep -Eq "$(re_escape_r r 'init(Distro-12.34)'; echo "$r")" && ok "the escaped form is an ERE grep reads as the literal" || bad "grep -E on the escaped init(Distro-12.34)"
if [ -r /proc/self/stat ]; then
    # a process whose comm is `init(Distro-12.34)` (cut to 15 characters by the kernel) and whose argv carries the whole name, with this HOME
    python3 -c 'import ctypes, time; ctypes.CDLL(None).prctl(15, b"init(Distro-12.34)", 0, 0, 0); time.sleep(120)  # init(Distro-12.34) a[b]+c*d' &
    fp=$!; waitfor '[ "$(cat /proc/'"$fp"'/comm 2>/dev/null)" = "init(Distro-12." ]' 20 || bad "the fake process did not take the comm (comm: $(cat /proc/$fp/comm 2>/dev/null))"
    comm=$(cat /proc/$fp/comm); re_escape_r wre "$comm"
    out=$(pgrep_mine "$wre" 2>&1) && rc=0 || rc=$?
    case "$out" in "$fp "*) [ "$rc" = 0 ] && ok "pgrep_mine finds a process by its comm '$comm', escaped" || bad "rc=$rc: $out" ;; *) bad "pgrep_mine '$wre': rc=$rc $out" ;; esac
    re_escape_r wre 'a[b]+c*d'
    out=$(pgrep_mine "$wre" 2>&1) && rc=0 || rc=$?
    case "$out" in "$fp "*) ok "… and by '[', ']', '+', '*' in its command line" ;; *) bad "pgrep_mine '$wre': rc=$rc $out" ;; esac
    out=$(pgrep_mine 'a\[b\]c' 2>&1) && rc=0 || rc=$?; [ "$rc" = 1 ] && [ -z "$out" ] && ok "a near miss matches nothing" || bad "near miss: rc=$rc $out"
    err=$(pgrep_mine "$comm" 2>&1 >/dev/null) && rc=0 || rc=$?   # the unescaped comm is not a regular expression: said once, rc 2, not once per process
    [ "$rc" = 2 ] && [ "$(printf '%s\n' "$err" | grep -c .)" = 1 ] && case "$err" in "pgrep_mine: not a regular expression: "*) true ;; *) false ;; esac \
        && ok "the unescaped comm: one message, rc 2" || bad "unescaped comm: rc=$rc, $(printf '%s\n' "$err" | grep -c .) line(s): $err"
    kill "$fp" 2>/dev/null || true; wait "$fp" 2>/dev/null || true
fi
echo "== not_back_sessions: only sessions not back on their conversation count as skipped after a reboot"
got=$(not_back_sessions "a: not back on its conversation" "b: claude.ai id session_02X, expected session_01Y" "c: claude.ai id none, expected session_01Z" "d: not back on its conversation" | paste -sd' ' -)
[ "$got" = "a d" ] && ok "not_back_sessions → a d (b and c, back under a new claude.ai id, left out)" || bad "not_back_sessions: '$got', want 'a d'"
[ -z "$(not_back_sessions)" ] && ok "not_back_sessions with no rows → nothing" || bad "not_back_sessions with no rows printed something"
echo "== read-only commands"
out=$(SALA_CONFIG=/dev/null "$ROOT/bin/salamander" spawn --list 2>&1); echo "$out" | grep -q 'smoke.*9.9.9.*session_01FAKE' && ok "spawn --list shows the pane" || bad "spawn --list: $out"
# the pane map is a ledger (2026-10-06): a session made by hand enters it through `adopt`, never through a save
out=$("$ROOT/bin/salamander" adopt smoke 2>&1); grep -q "^smoke	$UUID	smoke	$REAL_HOME$" "$SALA_SIDECAR" && ok "adopt writes the pane map row (4 columns, cwd from the process)" || bad "adopt: $out / $(slurp "$SALA_SIDECAR")"
out=$("$ROOT/bin/salamander" revive --save-map 2>&1); echo "$out" | grep -q '^pane map: 1 row(s), 1 live pane(s) seen, 0 followed' && ok "revive --save-map observes: $out" || bad "save-map: $out"
grep -q '^rcfake' "$SALA_SIDECAR" && bad "save-map added the rc child" || ok "save-map adds nothing (the rc child stays out)"
echo "== the web UI's shell session is not a Claude session (common.sh is_shell_session)"
# sala-shell is a plain login bash that sala-web makes on demand; "plainshell" is the control, a bare shell under any other name
$T new-session -d -s sala-shell -c "$HOME"; $T new-session -d -s plainshell -c "$HOME"
[ "$SALA_SHELL_SESSION" = sala-shell ] && ok "SALA_SHELL_SESSION defaults to sala-shell" || bad "SALA_SHELL_SESSION is '$SALA_SHELL_SESSION'"
no_relaunch sala-shell && ok "no_relaunch sala-shell: revive, restore, the lane move and watch leave it alone" || bad "no_relaunch sala-shell is false"
no_relaunch plainshell && bad "no_relaunch plainshell is true (the control)" || ok "no_relaunch plainshell is false (the control)"
out=$(SALA_CONFIG=/dev/null "$ROOT/bin/salamander" spawn --list 2>&1)
echo "$out" | grep -q 'sala-shell' && bad "spawn --list names sala-shell: $out" || ok "spawn --list leaves sala-shell out"
echo "$out" | grep -q 'plainshell' && ok "spawn --list still names a bare shell under another name (the control)" || bad "spawn --list lost the control: $out"
printf 'sala-shell	subscription-1
plainshell	subscription-1
' > "$SALA_LANES"   # lanes.tsv rows for both; the lane lists read them
lane_sessions_on subscription-1 | grep -qx sala-shell && bad "lane_sessions_on names sala-shell" || ok "lane_sessions_on leaves sala-shell out"
lane_sessions_on subscription-1 | grep -qx plainshell && ok "lane_sessions_on still names a session under another name (the control)" || bad "lane_sessions_on lost the control"
rm -f "$SALA_LANES"
out=$("$ROOT/bin/salamander" adopt sala-shell 2>&1) && rc=0 || rc=$?
{ [ "$rc" -ne 0 ] && echo "$out" | grep -q "web UI's shell" && ! grep -q '^sala-shell' "$SALA_SIDECAR"; } && ok "adopt sala-shell refused, nothing written to the pane map" || bad "adopt sala-shell: rc=$rc $out"
# the name is reserved: a Claude session must never take it (revive, lane and watch would skip it, the drawer's keys would type into it)
out=$("$ROOT/bin/salamander" spawn sala-shell --dry-run 2>&1) && rc=0 || rc=$?
{ [ "$rc" -ne 0 ] && echo "$out" | grep -q "web UI's shell session"; } && ok "spawn sala-shell refused (the name is the shell's)" || bad "spawn sala-shell: rc=$rc $out"
out=$("$ROOT/bin/salamander" spawn plainshell2 --dry-run 2>&1) && rc=0 || rc=$?
echo "$out" | grep -q "web UI's shell session" && bad "spawn plainshell2 refused as the shell's name (the control): $out" || ok "spawn under another name is not refused as the shell's (the control)"
out=$("$ROOT/bin/salamander" rename plainshell sala-shell --dry-run 2>&1) && rc=0 || rc=$?
{ [ "$rc" -ne 0 ] && echo "$out" | grep -q "web UI's shell session"; } && ok "rename X sala-shell refused (the name is the shell's)" || bad "rename plainshell sala-shell: rc=$rc $out"
out=$("$ROOT/bin/salamander" rename plainshell plainshell3 --dry-run 2>&1) && rc=0 || rc=$?
echo "$out" | grep -q "web UI's shell session" && bad "rename to another name refused as the shell's (the control): $out" || ok "rename to another name is not refused as the shell's (the control)"
# a refusal that names the shell session does not send the reader to SALA_NO_RELAUNCH, which it is not on
out=$("$ROOT/bin/salamander" revive --only sala-shell 2>&1) && rc=0 || rc=$?
{ [ "$rc" -ne 0 ] && echo "$out" | grep -q "sala's own shell session" && ! echo "$out" | grep -q "take it out of SALA_NO_RELAUNCH"; } && ok "revive --only sala-shell: says it is sala's own shell session, not 'take it out of SALA_NO_RELAUNCH'" || bad "revive --only sala-shell: rc=$rc $out"
out=$(SALA_NO_RELAUNCH=plainshell "$ROOT/bin/salamander" revive --only plainshell 2>&1) && rc=0 || rc=$?
{ [ "$rc" -ne 0 ] && echo "$out" | grep -q "take it out of SALA_NO_RELAUNCH"; } && ok "revive --only on a SALA_NO_RELAUNCH session still says to take it out of the list (the control)" || bad "revive --only plainshell: rc=$rc $out"
out=$("$ROOT/bin/salamander" revive --dry-run 2>&1)
echo "$out" | grep -q 'sala-shell' && bad "revive --dry-run mentions sala-shell: $out" || ok "revive --dry-run has no row, skip or shell line for sala-shell"
echo "$out" | grep -q 'plainshell' && ok "revive --dry-run still reports a bare shell pane under another name (the control)" || bad "revive --dry-run lost the control: $out"
$T kill-session -t sala-shell; $T kill-session -t plainshell
echo "== heartbeat: the files stackshot reads (git store: bare remote + checkout in the sandbox)"
git init -q --bare "$HOME/store.git"; git clone -q "$HOME/store.git" "$HOME/store" 2>/dev/null
git -C "$HOME/store" -c user.name=smoke -c user.email=smoke@example.invalid commit -q --allow-empty -m init && git -C "$HOME/store" push -q origin HEAD 2>/dev/null
printf '# host\tname\tletter\n%s\tsmoke-box\tq\n' "$(hostname | tr '[:upper:]' '[:lower:]')" > "$HOME/fleet.tsv"
export GIT_AUTHOR_NAME=smoke GIT_AUTHOR_EMAIL=smoke@example.invalid GIT_COMMITTER_NAME=smoke GIT_COMMITTER_EMAIL=smoke@example.invalid
out=$(SALA_HEARTBEAT_REPO="$HOME/store" SALA_HEARTBEAT_DIR=data SALA_FLEET_NAMES="$HOME/fleet.tsv" "$ROOT/bin/salamander" heartbeat 2>&1) || bad "heartbeat exited non-zero: $out"
python3 - "$HOME/store/data/q" "$UUID" <<'PY2' && ok "machine.json + sessions.json per contract" || bad "heartbeat files off contract"
import json, sys, os
m = json.load(open(os.path.join(sys.argv[1], "machine.json"))); s = json.load(open(os.path.join(sys.argv[1], "sessions.json")))
assert m["letter"] == "q" and m["fleet"] == "smoke-box" and m["claude"] == "9.9.9" and m["checked"].endswith("Z"), m
e = s[sys.argv[2]]; assert e["name"] == "smoke" and e["url"] == "https://claude.ai/code/session_01FAKE" and e["machine"] == "q" and e["seen"] == m["checked"], e
assert "cse_01FAKE" in s   # the rc-shaped fake registers too; the heartbeat reports what the registry says is live in tmux
PY2
git -C "$HOME/store.git" cat-file -e HEAD:data/q/sessions.json 2>/dev/null && ok "heartbeat pushed to the remote" || bad "heartbeat did not push"
# live store + git master-only: full facts locally, only the master record in git
out=$(SALA_HEARTBEAT_STATE_DIR="$HOME/live" SALA_HEARTBEAT_GIT=master SALA_MASTER=smoke SALA_HEARTBEAT_REPO="$HOME/store" SALA_HEARTBEAT_DIR=data SALA_FLEET_NAMES="$HOME/fleet.tsv" "$ROOT/bin/salamander" heartbeat 2>&1)
python3 - "$HOME/live/q" "$HOME/store/data/q" <<'PY2' && ok "live store full, git carries only the master record" || bad "live/master split: $out"
import json, sys
live, git = sys.argv[1], sys.argv[2]
lm = json.load(open(live + "/machine.json")); gm = json.load(open(git + "/machine.json"))
assert lm["claude"] == "9.9.9" and "fleet_ssh" in lm
assert set(gm) == {"letter", "fleet", "master", "master_session"} and gm["master"] == "smoke"
PY2
echo "== heartbeat fleet sweep: a posix box behind an ssh stub — its version published, no hub field, no git in the payload"
# one fake host behind an `ssh` stub (psets.sh's shape): lin1 answers the liveness probe and prints its fixture for the
# sweep's shell payload (the payload sent is recorded, to read back).
mkdir -p "$HOME/hosts"; POSTS="$HOME/posts.txt"; : > "$POSTS"
cat > "$HOME/.local/bin/ssh" <<EOF
#!/usr/bin/env bash
while [ \$# -gt 0 ]; do case "\$1" in -o) shift 2;; -*) shift;; *) break;; esac; done
h="\$1"; shift; c="\$*"
[ -e "$HOME/hosts/\$h.offline" ] && exit 255
case "\$c" in
  true) :;;
  *) printf '%s\n' "\$c" > "$HOME/hosts/\$h.sh"; cat "$HOME/hosts/\$h.out";;
esac
EOF
chmod +x "$HOME/.local/bin/ssh"
printf 'LIN1-OS\tlin1\tl\n' >> "$HOME/fleet.tsv"
# The coordinator's shape — a LIVE store (SALA_HEARTBEAT_STATE_DIR) the facts are read from — plus the git store
sweep() { out=$(SALA_HEARTBEAT_STATE_DIR="$HOME/fleet-live" SALA_HEARTBEAT_REPO="$HOME/store" SALA_HEARTBEAT_DIR=data SALA_FLEET_NAMES="$HOME/fleet.tsv" SALA_FLEET_HOSTS="lin1" SALA_NOTIFY_CMD="{ cat; echo '%%'; } >> $POSTS" "$ROOT/bin/salamander" heartbeat --no-push 2>&1) || bad "sweep exited non-zero: $out"; }
printf 'V:9.9.9 (Claude Code)\n' > "$HOME/hosts/lin1.out"
sweep
python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); sys.exit(not (m["claude"] == "9.9.9" and m["fleet"] == "lin1" and m["letter"] == "l" and "hub" not in m))' "$HOME/fleet-live/l/machine.json" \
    && ok "a swept box: its version in its machine.json, no hub field (the store's contract)" || bad "lin1 machine.json: $(slurp "$HOME/fleet-live/l/machine.json")"
! grep -qwE 'git|ops-hub|stackshot' "$HOME/hosts/lin1.sh" && ok "the payload sent to a box runs no git and names no checkout (the sweep moves nothing on a box)" || bad "lin1 payload: $(<"$HOME/hosts/lin1.sh")"
[ ! -s "$POSTS" ] && ok "a clean sweep posts nothing" || bad "posts: $(<"$POSTS")"
echo "== session links (Tue Oct 13th 2026): the driving box's own rows carry the sala-web link, a swept box's keep claude.ai"
# Term links replace the remote-control links — sala's heartbeat is the one source. The first heartbeat
# above (no SALA_FLEET_HOSTS: a standalone box) already showed the claude.ai link where no template is in force.
unset SALA_SESSION_URL
UE=33333333-3333-4333-8333-333333333333; RU=22222222-2222-4222-8222-222222222222; EN='enc test+ü&x(1)!'
$T new-session -d -s enc -c "$HOME" -e FAKE_SESSION_ID=$UE -e "FAKE_NAME=$EN"; $T send-keys -t enc 'claude' Enter; fake_up "$EN"
python3 - "$HOME/.claude/sessions/$(claude_pid_under "$(tmux display -p -t enc '#{pane_pid}')").json" <<'PY2'
import json, sys; p = sys.argv[1]; d = json.load(open(p)); d["bridgeSessionId"] = None; json.dump(d, open(p, "w"))   # bridge down
PY2
printf 'V:9.9.9 (Claude Code)\nS:4242|1|{"sessionId":"%s","name":"remote-one","bridgeSessionId":"session_01REMOTE","tmux":"remote-one:@1.%%1"}\n' "$RU" > "$HOME/hosts/lin1.out"
links() { out=$(SALA_HEARTBEAT_STATE_DIR="$HOME/link-live" SALA_FLEET_NAMES="$HOME/fleet.tsv" SALA_FLEET_HOSTS="lin1" "$ROOT/bin/salamander" heartbeat --no-push 2>&1) || bad "links sweep exited non-zero: $out"; }
url() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], {}).get("url", "<no row>"))' "$HOME/link-live/$1/sessions.json" "$2" 2>/dev/null || echo "<no file>"; }
links
[ "$(url q "$UUID")" = "https://claude.ai/code/session_01FAKE" ] && [ "$(url q "$UE")" = "" ] && ok "this box, no SALA_SESSION_URL (sala's default names no web UI): the claude.ai link, \"\" while the bridge is down" || bad "default url: smoke '$(url q "$UUID")', enc '$(url q "$UE")'"
SALA_SESSION_URL='https://sala.example.com/#s={name}' links
[ "$(url q "$UUID")" = "https://sala.example.com/#s=smoke" ] && ok "this box, bridged, SALA_SESSION_URL set: the web UI's link" || bad "q/smoke url: $(url q "$UUID")"
[ "$(url q "$UE")" = "https://sala.example.com/#s=enc%20test%2B%C3%BC%26x(1)!" ] && ok "this box, no bridge: listed, with the web UI's link, the name encoded as encodeURIComponent does" || bad "q/enc url: $(url q "$UE")"
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); a, b = s[sys.argv[2]], s[sys.argv[3]]; sys.exit(not (set(a) == set(b) == {"name", "url", "seen", "machine"} and a["name"] == sys.argv[4]))' \
    "$HOME/link-live/q/sessions.json" "$UE" "$UUID" "$EN" && ok "the unbridged row has the bridged row's fields (name, url, seen, machine), nothing else" || bad "row fields: $(<"$HOME/link-live/q/sessions.json")"
printf 'V:9.9.9 (Claude Code)\nS:4243|1|{"sessionId":"44444444-4444-4444-8444-444444444444","name":"remote-nobridge","tmux":"rn:@2.%%2"}\nS:4242|1|{"sessionId":"%s","name":"remote-one","bridgeSessionId":"session_01REMOTE","tmux":"remote-one:@1.%%1"}\n' "$RU" > "$HOME/hosts/lin1.out"; links
[ "$(url l 44444444-4444-4444-8444-444444444444)" = "<no row>" ] && [ "$(url l "$RU")" = "https://claude.ai/code/session_01REMOTE" ] && ok "a swept box keeps today's filter: its unbridged session is not listed" || bad "l rows: $(<"$HOME/link-live/l/sessions.json")"
[ "$(url l "$RU")" = "https://claude.ai/code/session_01REMOTE" ] && ok "a swept box's row keeps its claude.ai link" || bad "l/remote url: $(url l "$RU")"
SALA_SESSION_URL= links
[ "$(url q "$UUID")" = "https://claude.ai/code/session_01FAKE" ] && [ "$(url q "$UE")" = "" ] && ok "SALA_SESSION_URL empty: the old link (claude.ai, \"\" while the bridge is down)" || bad "empty template: smoke '$(url q "$UUID")', enc '$(url q "$UE")'"
[ "$(url l "$RU")" = "https://claude.ai/code/session_01REMOTE" ] && ok "… and the swept row is unchanged" || bad "l/remote url: $(url l "$RU")"
SALA_SESSION_URL='https://t.example/open?s={name}&x=1' links
[ "$(url q "$UE")" = "https://t.example/open?s=enc%20test%2B%C3%BC%26x(1)!&x=1" ] && [ "$(url l "$RU")" = "https://claude.ai/code/session_01REMOTE" ] \
    && ok "a template of the config's: {name} replaced, encoded; the swept row still claude.ai" || bad "custom template: enc '$(url q "$UE")', remote '$(url l "$RU")'"
got=$(SALA_FLEET_HOSTS=x SALA_SESSION_URL='https://sala.example.com/#s={name}' session_url "a/b?c#d ~*'" session_01X); [ "$got" = "https://sala.example.com/#s=a%2Fb%3Fc%23d%20~*'" ] && ok "session_url: / ? # and space encoded, ~ * ' kept (encodeURIComponent)" || bad "session_url: $got"
got=$(SALA_FLEET_HOSTS= session_url smoke session_01X); [ "$got" = "https://claude.ai/code/session_01X" ] && ok "session_url, not the driving box and unset: the claude.ai link" || bad "session_url standalone: $got"
[ "$fail" = 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
