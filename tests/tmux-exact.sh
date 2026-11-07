#!/usr/bin/env bash
# Exact tmux session targets (lib/common.sh EXACT TMUX SESSION TARGETS): a session NAME handed to tmux as a plain `-t NAME`
# is read loosely. A number is a window index of the CALLER's own session, so a stray session `0` made `sala retire 0
# --dry-run` name the caller's own pane (and a real run would have retired the caller); a name can match a window name in the
# caller's session; an unmatched name prefix-matches another session (`work` → `work-a`). This suite runs the cases on a
# private tmux server with the caller's pane in an `anchor` session (TMUX_PANE, as a session's own shell has it):
#   - the helpers: tmux_sess_t → `=NAME`, tmux_win_t → `=NAME:` / `=NAME:N`, an empty name → a bare `=` that tmux refuses
#     (`=:` would read as the caller's own session); each resolved by tmux itself: `0` is session 0's pane and not the
#     caller's, a window named like a session in the caller's session is not that session, `work` is no `work-a`,
#     `work-a` is not `work-ab`;
#   - `sala close-shell` (the sessions here are plain shells; `sala retire` of one is refused and names close-shell), dry run
#     and real, on sessions `0`, `work-a`, `work-ab` and a session named like a window of the caller's session: the dry run
#     counts the exact session's own panes and touches nothing, the prefix `work` is refused with the plain sentence and
#     nothing touched (by retire and by close-shell), a real close of `work-a` leaves `work-ab`, a real close of `0` leaves
#     the caller's session and pane alone;
#   - the same sessions through `sala master` (its pane lookup) and `sala unpark`'s refusal of a missing session.
# Isolated HOME, a private tmux socket (sala-tmuxexact-<pid>), no claude: the sessions are plain shells. Every file and the
# server are removed at the end, pass or fail.
# Usage: bash tests/tmux-exact.sh   (exit 0 = pass; ~15 s)
set -u
unset TMUX_PANE XDG_STATE_HOME
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, tmux_socket_rm
SANDBOX=""; SOCK="sala-tmuxexact-$$"; T="tmux -L $SOCK -f /dev/null"
BUSY_PIDS=""; BUSYDIR=""
cleanup() {
    local p   # the two long-running children below, by pid and only while /proc/<pid>/exe is this suite's own copy (never by name)
    for p in $BUSY_PIDS; do [ "$(readlink "/proc/$p/exe" 2>/dev/null)" = "$BUSYDIR/busy" ] || [ "$(readlink "/proc/$p/exe" 2>/dev/null)" = "$BUSYDIR/claude" ] && kill "$p" 2>/dev/null; done
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 0.5
    [ -n "$SANDBOX" ] && rm -rf "$SANDBOX" 2>/dev/null
    true
}; trap cleanup EXIT   # set before the temp folder exists
SANDBOX=$(mktemp -d); export HOME=$SANDBOX; export SALA_CONFIG=/dev/null
exec 8< "$SANDBOX"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
as_op_unit   # the guarded verbs this suite runs itself stand for the queue's runner (tests/lib.sh, 5)
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$HOME/work"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="cat >> $POSTS"   # no post leaves the box
export SALA_AUTO_UPDATE=off SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_SNAPSHOT_CMD="touch $HOME/snap.done"
SALA="$ROOT/bin/salamander"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's
. "$ROOT/lib/common.sh"
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux   # literal socket: the children run set -u
fail=0

# the caller: a shell in session `anchor`, whose window 0 is named `colw`, the name of a session made below
tmux new-session -d -s anchor -n colw -c "$HOME/work"
for s in 0 work-a work-ab colw; do tmux new-session -d -s "$s" -c "$HOME/work"; done   # (a session `colw` beside a window `colw` of the caller's)
pane_of() { tmux list-panes -t "=$1:" -F '#{pane_id}' | head -1; }   # <session> → the id of its first pane, by an exact target
ME=$(pane_of anchor); P0=$(pane_of 0); PA=$(pane_of work-a); PAB=$(pane_of work-ab); PC=$(pane_of colw)
[ -n "$ME" ] && [ -n "$P0" ] && [ -n "$PA" ] && [ -n "$PAB" ] && [ -n "$PC" ] || { bad "the sessions did not come up (anchor '$ME', 0 '$P0', work-a '$PA', work-ab '$PAB', colw '$PC')"; exit 1; }
sessions() { tmux list-sessions -F '#{session_name}' | sort | paste -sd' '; }
all() { tmux list-panes -a -F '#{session_name} #{pane_id} #{pane_pid}'; echo "$(sessions)"; ls "$HOME/snap.done" 2>/dev/null; }
sala_as_me() { TMUX_PANE="$ME" "$SALA" "$@"; }   # a sala verb run from the caller's own pane, as a session runs it

echo "== the loose reading these helpers replace (the cases the exact forms must beat)"
loose0=$(TMUX_PANE=$ME tmux list-panes -t 0 -F '#{pane_id}' 2>/dev/null | head -1)
[ "$loose0" = "$ME" ] && ok "a plain -t 0 from the caller's pane is the CALLER's window 0 ($ME), not session 0 ($P0): the bug" || bad "a plain -t 0 gave '$loose0' (the caller is $ME, session 0 is $P0): this tmux reads it differently, the suite's premise is gone"
looseb=$(TMUX_PANE=$ME tmux list-panes -t =0 -F '#{pane_id}' 2>/dev/null | head -1)
[ "$looseb" = "$ME" ] && ok "a bare =0 as a window target is still the caller's window 0: only the session-qualified form is exact" || bad "a bare -t =0 gave '$looseb' (the caller is $ME): the premise of tmux_win_t is gone"
loosec=$(TMUX_PANE=$ME tmux list-panes -t =colw -F '#{pane_id}' 2>/dev/null | head -1)
[ "$loosec" = "$ME" ] && ok "a bare =colw is the caller's WINDOW named colw, not the session colw ($PC)" || bad "a bare -t =colw gave '$loosec' (the caller is $ME)"

echo "== the helpers"
[ "$(tmux_sess_t 0)" = "=0" ] && [ "$(tmux_sess_t work-a)" = "=work-a" ] && ok "tmux_sess_t NAME → =NAME" || bad "tmux_sess_t: '$(tmux_sess_t 0)' '$(tmux_sess_t work-a)'"
[ "$(tmux_win_t 0)" = "=0:" ] && [ "$(tmux_win_t work-a)" = "=work-a:" ] && [ "$(tmux_win_t work-a 0)" = "=work-a:0" ] && ok "tmux_win_t NAME → =NAME:, NAME N → =NAME:N" || bad "tmux_win_t: '$(tmux_win_t 0)' '$(tmux_win_t work-a)' '$(tmux_win_t work-a 0)'"
[ "$(tmux_win_t '')" = "=" ] && [ "$(tmux_win_t)" = "=" ] && ok "an empty name → a bare =, never =:" || bad "tmux_win_t of nothing: '$(tmux_win_t '')'"
TMUX_PANE=$ME tmux list-panes -t "$(tmux_win_t '')" >/dev/null 2>&1 && bad "tmux accepted the empty-name target (it reads =: as the caller's session)" || ok "tmux refuses the empty-name target"
got=$(TMUX_PANE=$ME tmux list-panes -t "$(tmux_win_t 0)" -F '#{pane_id}' | head -1)
[ "$got" = "$P0" ] && [ "$got" != "$ME" ] && ok "tmux_win_t 0 is session 0's pane ($P0), not the caller's ($ME)" || bad "tmux_win_t 0 resolved to '$got' (session 0 is $P0, the caller $ME)"
got=$(TMUX_PANE=$ME tmux list-panes -t "$(tmux_win_t colw)" -F '#{pane_id}' | head -1)
[ "$got" = "$PC" ] && [ "$got" != "$ME" ] && ok "tmux_win_t colw is session colw's pane, not the caller's window named colw" || bad "tmux_win_t colw resolved to '$got' (session colw is $PC, the caller $ME)"
got=$(TMUX_PANE=$ME tmux list-panes -s -t "$(tmux_win_t work-a)" -F '#{pane_id}' | head -1)
[ "$got" = "$PA" ] && ok "list-panes -s with tmux_win_t work-a is work-a's pane" || bad "list-panes -s: '$got' (work-a is $PA)"
got=$(TMUX_PANE=$ME tmux display -p -t "$(tmux_win_t work-a 0)" '#{pane_id}')
[ "$got" = "$PA" ] && [ "$got" != "$PAB" ] && ok "tmux_win_t work-a 0 is work-a's pane, not work-ab's" || bad "display work-a:0: '$got' (work-a $PA, work-ab $PAB)"
TMUX_PANE=$ME tmux list-panes -t "$(tmux_win_t work)" >/dev/null 2>&1 && bad "tmux_win_t work matched a session (the prefix of work-a)" || ok "tmux_win_t work matches no session: no prefix match"
TMUX_PANE=$ME tmux has-session -t "$(tmux_sess_t work)" 2>/dev/null && bad "tmux_sess_t work matched a session" || ok "tmux_sess_t work matches no session"
TMUX_PANE=$ME tmux has-session -t "$(tmux_sess_t work-a)" 2>/dev/null && ok "tmux_sess_t work-a is a session" || bad "tmux_sess_t work-a is none"

# The caller's panes are NOT idle, as a session's own are never: its shell runs a long-running child (`busy`), and a second window of its
# session runs a process whose comm is `claude`. Both are copies of bash under $HOME (an exe of the suite's own, so the cleanup finds them by
# /proc exe), waiting in `read -t`, no child of their own. A listing that read `=0` as the caller's window would count them as session 0's.
BUSYDIR="$HOME/busy-bin"; mkdir -p "$BUSYDIR"; cp "$(command -v bash)" "$BUSYDIR/busy"; cp "$(command -v bash)" "$BUSYDIR/claude"
tmux send-keys -t "$ME" "$BUSYDIR/busy -c 'read -t 600 x'" Enter
tmux new-window -d -t "=anchor:" -n callerclaude -c "$HOME/work"
CW=$(tmux list-panes -t "=anchor:callerclaude" -F '#{pane_id}' | head -1)
tmux send-keys -t "$CW" "$BUSYDIR/claude -c 'read -t 600 x'" Enter
kids_of() { local pp; pp=$(tmux display -p -t "$1" '#{pane_pid}'); pgrep -P "$pp" 2>/dev/null | head -1; }
waitfor '[ -n "$(kids_of "$ME")" ] && [ -n "$(kids_of "$CW")" ]' 40
BUSY_PIDS="$(kids_of "$ME") $(kids_of "$CW")"
[ -n "$(kids_of "$ME")" ] && [ -n "$(kids_of "$CW")" ] && ok "the caller's pane $ME runs a long-running child, its second window $CW a process named claude (the suite's premise for the cases below)" || { bad "the caller's busy panes did not come up (me '$(kids_of "$ME")', window '$(kids_of "$CW")')"; exit 1; }

echo "== sala close-shell --dry-run 0: the session named 0, never the caller's window 0"
s0=$(all)
out=$(sala_as_me close-shell 0 --dry-run 2>&1); rc=$?; echo "$out" | sed 's/^/    /'
[ "$rc" = 0 ] && echo "$out" | grep -qF "'0': 1 pane(s), none with a Claude session" && echo "$out" | grep -qF "would kill tmux session '0'" && ok "names session '0' and counts its own one pane, not the caller's window 0" || bad "close-shell 0 --dry-run: rc=$rc"
[ "$(all)" = "$s0" ] && ok "close-shell 0 --dry-run touched nothing" || bad "close-shell 0 --dry-run changed something: $(diff <(echo "$s0") <(all) | head -5)"
out=$(sala_as_me retire 0 --dry-run 2>&1); rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -qF "sala close-shell 0" && [ "$(all)" = "$s0" ] && ok "retire 0 --dry-run: refused (no Claude in it), names close-shell, touches nothing" || bad "retire 0 --dry-run: rc=$rc: $out"

out=$(sala_as_me forget-row 0 --dry-run 2>&1); rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -qF "tmux session '0' is live (a shell, no Claude)" && echo "$out" | grep -qF "sala close-shell 0" && [ "$(all)" = "$s0" ] && ok "forget-row 0 --dry-run: session 0 is a live plain shell (not the caller's pane with a claude in it), names close-shell, touches nothing" || bad "forget-row 0 --dry-run: rc=$rc: $out"

echo "== a session named like a window of the caller's session"
out=$(sala_as_me close-shell colw --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -qF "would kill tmux session 'colw'" && echo "$out" | grep -qF "'colw': 1 pane(s)" && [ "$(all)" = "$s0" ] && ok "close-shell colw --dry-run is the session colw (one pane), not the caller's window colw" || bad "close-shell colw --dry-run: rc=$rc: $out"

echo "== a prefix is refused, never matched"
out=$(sala_as_me close-shell work --dry-run 2>&1); rc=$?; echo "$out" | sed 's/^/    /'
[ "$rc" != 0 ] && echo "$out" | grep -qF "no tmux session 'work'" && ! echo "$out" | grep -q "work-a" && ok "close-shell work --dry-run: refused with a plain sentence, no work-a or work-ab named" || bad "close-shell work --dry-run: rc=$rc"
out=$(sala_as_me close-shell work 2>&1); rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -qF "no tmux session 'work'" && [ "$(all)" = "$s0" ] && ok "close-shell work (real): refused, every session still there" || bad "close-shell work: rc=$rc, $(diff <(echo "$s0") <(all) | head -5)"
out=$(sala_as_me retire work --dry-run 2>&1); rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -qF "no tmux session 'work'" && ! echo "$out" | grep -q "work-a" && ok "retire work --dry-run: refused too, no work-a named" || bad "retire work --dry-run: rc=$rc: $out"
out=$(sala_as_me close-shell wor --dry-run 2>&1); rc=$?
[ "$rc" != 0 ] && ! echo "$out" | grep -q "work-a" && ok "close-shell wor: a shorter prefix refused too" || bad "close-shell wor --dry-run: rc=$rc: $out"

echo "== work-a is not work-ab"
out=$(sala_as_me close-shell work-a --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -qF "would kill tmux session 'work-a'" && ! echo "$out" | grep -qF "work-ab" && ok "close-shell work-a --dry-run names work-a, not work-ab" || bad "close-shell work-a --dry-run: rc=$rc: $out"
out=$(sala_as_me close-shell work-a 2>&1); rc=$?; echo "$out" | sed 's/^/    /'
[ "$rc" = 0 ] && echo "$out" | grep -qF "'work-a': tmux session killed" && ok "close-shell work-a: killed" || bad "close-shell work-a: rc=$rc"
[ "$(sessions)" = "0 anchor colw work-ab" ] && [ "$(pane_of work-ab)" = "$PAB" ] && ok "work-a gone; work-ab, 0, colw and the caller's session untouched ($(sessions))" || bad "sessions after closing work-a: $(sessions)"

echo "== a real close of 0 leaves the caller alone"
out=$(sala_as_me close-shell 0 2>&1); rc=$?; echo "$out" | sed 's/^/    /'
[ "$rc" = 0 ] && echo "$out" | grep -qF "'0': tmux session killed" && ok "close-shell 0 (real): session 0 killed" || bad "close-shell 0: rc=$rc"
[ "$(sessions)" = "anchor colw work-ab" ] && tmux display -p -t "$ME" '#{pane_id}' >/dev/null 2>&1 && ok "session 0 gone; the caller's session and pane $ME are alive ($(sessions))" || bad "after closing 0: $(sessions)"
out=$(sala_as_me close-shell 0 --dry-run 2>&1); rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -qF "no tmux session '0'" && ok "close-shell 0 once it is gone: refused, the caller's window 0 is not taken for it" || bad "close-shell 0 after: rc=$rc: $out"
out=$(sala_as_me forget-row 0 --dry-run 2>&1); rc=$?
[ "$rc" != 0 ] && ok "forget-row 0 with no row for it: refused" || bad "forget-row 0 after: rc=$rc: $out"

echo "== the other verbs that look a session up by name"
out=$(sala_as_me unpark 0 2>&1); rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -qF "no tmux session '0'" && ok "unpark 0 with no session 0: refused, not the caller's window 0" || bad "unpark 0: rc=$rc: $out"
out=$(sala_as_me unpark work 2>&1); rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -qF "no tmux session 'work'" && ok "unpark work: no prefix match on work-ab" || bad "unpark work: rc=$rc: $out"

[ "$fail" = 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
