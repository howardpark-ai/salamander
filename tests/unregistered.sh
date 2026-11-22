#!/usr/bin/env bash
# The unregistered-agent-pane watch (lib/watch.sh, UNREGISTERED AGENT PANES; `watch --unregistered`): an agent session that is live on this box but on no
# project's agents map in stackshot's project record shows under "Unregistered" on the board, and nothing noticed. The watch reads the published record file
# (project_record_agent, no pages.py, no HTTP), skips what the spawn gate's one exceptions list skips (agent_gate_exempt: scratch-*, *-check-*, *-test-*, *-probe-*, a side
# session by name or by its record, sala's shell, an auto-generated throwaway by its registry tag) and posts the rest that the record lists nowhere.
#   a  a live non-exempt pane missing from a fresh record: ONE post for it (and none for a listed pane, an exempt name, a side session, the shell), a log line, one state key;
#      the post says who acts and the register command's shape in plain words, with no time of day and no alarming word
#   g  the grace: a pane first seen missing is not posted until SALA_UNREGISTERED_GRACE has passed (a name registered a moment ago has not reached the record yet)
#   b  the same pane on the next runs: not posted again within the back-off; posted again once it has passed (SALA_UNREGISTERED_BACKOFF)
#   c  listed, exempt, side, a box with no stackshot, SALA_AGENT_CHECK=off and SALA_UNREGISTERED_CHECK=off: nothing posted, no key
#   d  a stale, missing or unreadable record: ONE "could not check" post, no per-pane post, every key kept; once per back-off; its key goes when the record answers again
#   e  a pane that gets registered, goes away or becomes exempt: its state key goes (and posts nothing); a plain watch tick runs the step
#   f  a record that cannot answer, three review points: (a) only panes a registry tag exempts (a side session, a generated throwaway) are live: no "could not check" post, no per-pane post;
#      (b) one non-exempt pane is live and a key of a pane that is not live is seeded: both keys survive the outage, and go once a readable record lists the live pane;
#      (c) the "could not check" line says the panes it could not read an answer for were not reported (and no longer claims that no session was reported)
#   h  an outage tick that reads no pane still deletes no key (the record-level answer): a stale record with (b) only exempt live panes, by tag or by name, or (a) no live pane at all, and a seeded
#      unreg.<name> key plus a seeded unreg_record key: both stay, nothing is posted; (c) with a readable record the same keys go. f's case a also reads the side tag's fixture back (side=1, throwaway=0)
# Isolated HOME, a private tmux server started with -f /dev/null, the compiled fake claude, a stub project record (SALA_PROJECT_RECORD); every post lands in a file.
# Usage: bash tests/unregistered.sh   (exit 0 = pass; ~25 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_RC_SESSION SALA_NO_RELAUNCH SALA_FLEET_HOSTS SALA_UNREGISTERED_CHECK SALA_UNREGISTERED_GRACE SALA_UNREGISTERED_BACKOFF SALA_STACKSHOT_CLIENT
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, tmux_socket_rm
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
exec 8< "$HOME"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$HOME/.local/share/claude/versions/9.9.9" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
ln -s "$HOME/.local/share/claude/versions/9.9.9" "$HOME/.local/bin/claude"
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="cat >> $POSTS"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off
export SALA_LIMIT_ALERT=off SALA_LIMIT_RESUME=off SALA_SIGNIN_ALERT=off SALA_STUCK_POST=0   # the other watches: not under test
export SALA_PROJECT_RECORD="$HOME/projects.json" SALA_STACKSHOT_DIR="" SALA_SHELL_SESSION=delta-demo-shell
SALA="$ROOT/bin/salamander"; SOCK="sala-unreg-$$"; T="tmux -L $SOCK -f /dev/null"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"
WLOG="$HOME/.claude/salamander-watch.log"; WSTATE="$HOME/.claude/salamander-watch.state"
cleanup() {  # only this suite's own server and the fakes whose executable is our copy (never by name)
    local p
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    for p in $(pgrep -x claude); do [ "$HOME/.local/share/claude/versions/9.9.9" -ef "/proc/$p/exe" ] && kill -9 "$p" 2>/dev/null; done
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux
. "$ROOT/lib/common.sh"
mk() {  # <session name> <uuid> — a fake claude in a tmux session of that name
    $T new-session -d -s "$1" -x 160 -y 40 -c "$HOME" -e FAKE_SESSION_ID="$2" -e FAKE_NAME="$1" -e FAKE_LOG="$FAKE_LOG"
    $T send-keys -t "$1" "claude" Enter
}
# mkrec <age in seconds> <agent name>… → the published record, written <age> seconds ago: projects/delta-demo with those agents (a -main name front, any other back) and projects/other
mkrec() { local age=$1; shift; python3 - "$age" "$@" > "$SALA_PROJECT_RECORD" <<'PY'
import datetime, json, sys
age, names = float(sys.argv[1]), sys.argv[2:]
ag = {n: {"front": n.endswith("-main"), "role": n.rsplit("-", 1)[-1], "mandate_line": "demo line"} for n in names}
t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=age)
p1, p2 = "prj_%08x" % 1, "prj_%08x" % 2   # built, never a literal id in this file
print(json.dumps({"schema": 1, "generated": t.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "projects": {p1: {"id": p1, "key": "projects/delta-demo", "keeper": "delta-demo-main", "agents": ag},
                 p2: {"id": p2, "key": "projects/other", "keeper": "other-main", "agents": {"other-main": {"front": True, "role": "main", "mandate_line": "x"}}}},
    "by_key": {"projects/delta-demo": p1, "projects/other": p2}}))
PY
}
uw() { env "$@" "$SALA" watch --unregistered >/dev/null 2>&1; }   # [VAR=value…] → one run of the step alone
HEAD='is live but not registered on stackshot'
nmiss() { grep -c "$HEAD" "$POSTS" 2>/dev/null || true; }          # per-pane posts
ncant() { grep -c 'Could not check whether live agents are registered' "$POSTS" 2>/dev/null || true; }
nkeys() { grep -c '^unreg\.' "$WSTATE" 2>/dev/null || true; }
reset() { : > "$POSTS"; sed -i '/^unreg[._]/d' "$WSTATE" 2>/dev/null; true; }
B=delta-demo-builder
D1=aaaaaaaa-1111-4000-8000-000000000001; D2=aaaaaaaa-1111-4000-8000-000000000002; D3=aaaaaaaa-1111-4000-8000-000000000003; D4=aaaaaaaa-1111-4000-8000-000000000004
D5=aaaaaaaa-1111-4000-8000-000000000005; D6=aaaaaaaa-1111-4000-8000-000000000006; D7=aaaaaaaa-1111-4000-8000-000000000007; D8=aaaaaaaa-1111-4000-8000-000000000008

echo "== setup: one missing agent, one listed, and every kind of exempt pane"
mkdir -p "$SALA_STATE_DIR/side"; printf 'origin=delta-demo-main\n' > "$SALA_STATE_DIR/side/delta-demo-ghost.side"   # a side session by its record, not by its name
mk "$B" "$D1"; mk delta-demo-main "$D2"; mk scratch-demo-q "$D3"; mk delta-demo-side-a1 "$D4"; mk delta-demo-probe-z "$D5"; mk delta-demo-shell "$D6"; mk delta-demo-ghost "$D7"; mk delta-demo-check-w "$D8"
fake_up "$B" delta-demo-main scratch-demo-q delta-demo-side-a1 delta-demo-probe-z delta-demo-shell delta-demo-ghost delta-demo-check-w
mkrec 5 delta-demo-main
: > "$POSTS"; [ -e "$WSTATE" ] || : > "$WSTATE"

echo "== a: a live non-exempt pane missing from a fresh record is posted once"
uw SALA_UNREGISTERED_GRACE=0
[ "$(nmiss)" = 1 ] && grep -q "^.*\*$B $HEAD\*" "$POSTS" && ok "exactly one post, for $B" || bad "posts: $(nmiss): $(slurp "$POSTS")"
for n in delta-demo-main scratch-demo-q delta-demo-side-a1 delta-demo-probe-z delta-demo-shell delta-demo-ghost delta-demo-check-w; do
    ! grep -q "$n" "$POSTS" && continue; bad "a post names $n: $(slurp "$POSTS")"
done; ok "no post names a listed pane, a throwaway's name, a side session (by name or by record) or the shell"
[ "$(nkeys)" = 1 ] && grep -q "^unreg\.$B=[0-9]*:[0-9]*$" "$WSTATE" && ok "one state key, first-seen:last-post" || bad "state: $(grep unreg "$WSTATE")"
grep -q "unregistered: '$B' is live and on no project's agents map" "$WLOG" && ok "the log line says it" || bad "log: $(tail -3 "$WLOG")"
grep -q 'Unregistered' "$POSTS" && grep -q "post project-agent projects/delta-demo $B --role builder --front|--back --mandate" "$POSTS" && grep -q 'rename it to a name its project already lists' "$POSTS" && grep -q 'its name starts like the project projects/delta-demo' "$POSTS" \
    && ok "the post says what it means, which project it belongs to, the register command's shape and the rename route" || bad "post text: $(slurp "$POSTS")"
! grep -qE '[0-9]{1,2}:[0-9]{2}|UTC|KST|20[0-9]{2}' "$POSTS" && ok "no time of day, zone or year in the post" || bad "a time in the post: $(slurp "$POSTS")"
! grep -qiE 'leak|breach|kill|quota|credential|exposed' "$POSTS" && ok "no alarming word" || bad "alarming word: $(slurp "$POSTS")"
[ "$(grep -c "$B" "$POSTS")" -ge 1 ] && ! grep -qiE 'token|secret|key=' "$POSTS" && ok "no secret" || bad "post: $(slurp "$POSTS")"

echo "== b: not posted again within the back-off; again once it has passed"
uw SALA_UNREGISTERED_GRACE=0; uw SALA_UNREGISTERED_GRACE=0
[ "$(nmiss)" = 1 ] && ok "two more runs inside the back-off: still the one post" || bad "posts after two more runs: $(nmiss)"
uw SALA_UNREGISTERED_GRACE=0 SALA_UNREGISTERED_BACKOFF=0
[ "$(nmiss)" = 2 ] && ok "past the back-off: posted again" || bad "posts after the back-off: $(nmiss)"
grep -q 'repeats every' "$POSTS" && ok "the post says it repeats and when it stops" || bad "no repeat sentence"

echo "== g: the grace — a pane first seen missing waits SALA_UNREGISTERED_GRACE"
reset
uw SALA_UNREGISTERED_GRACE=3600; uw SALA_UNREGISTERED_GRACE=3600
[ "$(nmiss)" = 0 ] && [ "$(nkeys)" = 1 ] && grep -q "^unreg\.$B=[0-9]*:0$" "$WSTATE" && ok "inside the grace: no post, the first-seen stamp kept (last post 0)" || bad "grace: posts=$(nmiss) state=$(grep unreg "$WSTATE")"
f=$(grep "^unreg\.$B=" "$WSTATE" | sed 's/^[^=]*=//; s/:.*//'); sed -i "s/^unreg\.$B=.*/unreg.$B=$(( f - 4000 )):0/" "$WSTATE"
uw SALA_UNREGISTERED_GRACE=3600
[ "$(nmiss)" = 1 ] && grep -q 'missing for 6[0-9] min' "$POSTS" && ok "once it has been missing past the grace: posted, with how long" || bad "after the grace: posts=$(nmiss) $(slurp "$POSTS")"
uw SALA_UNREGISTERED_GRACE=3600
[ "$(nmiss)" = 1 ] && ok "and not again within the back-off" || bad "again: $(nmiss)"

echo "== e: registered, exempt or gone: the key goes and nothing is posted"
mkrec 5 delta-demo-main "$B"
: > "$POSTS"; uw SALA_UNREGISTERED_GRACE=0
[ "$(nmiss)" = 0 ] && [ "$(nkeys)" = 0 ] && ok "the pane is listed now: its key is gone, nothing posted" || bad "registered: posts=$(nmiss) keys=$(nkeys)"
mkrec 5 delta-demo-main; : > "$POSTS"; uw SALA_UNREGISTERED_GRACE=0
[ "$(nmiss)" = 1 ] && [ "$(nkeys)" = 1 ] && ok "missing again: a fresh episode posts again" || bad "fresh episode: posts=$(nmiss) keys=$(nkeys)"
$T kill-session -t "=$B"; waitfor "! tmux has-session -t =$B 2>/dev/null" 20
: > "$POSTS"; uw SALA_UNREGISTERED_GRACE=0
[ "$(nmiss)" = 0 ] && [ "$(nkeys)" = 0 ] && ok "the pane is gone: its key is gone, nothing posted" || bad "gone: posts=$(nmiss) keys=$(nkeys) $(grep unreg "$WSTATE")"
mk "$B" "$D1"; fake_up "$B"; reset
mkdir -p "$SALA_STATE_DIR/side"; uw SALA_UNREGISTERED_GRACE=0
[ "$(nkeys)" = 1 ] && ok "back (a new pane under the name): a key again" || bad "key: $(nkeys)"
printf 'origin=delta-demo-main\n' > "$SALA_STATE_DIR/side/$B.side"; : > "$POSTS"; uw SALA_UNREGISTERED_GRACE=0
[ "$(nmiss)" = 0 ] && [ "$(nkeys)" = 0 ] && ok "it became a side session: exempt, its key goes, nothing posted" || bad "side: posts=$(nmiss) keys=$(nkeys)"
rm -f "$SALA_STATE_DIR/side/$B.side"; reset

echo "== e: an auto-generated throwaway (its registry row's tag) is exempt although its name is not on the list"
$T set-environment -g FAKE_SESSION_ID aaaaaaaa-1111-4000-8000-000000000009; $T set-environment -g FAKE_NAME gen-demo; $T set-environment -g FAKE_LOG "$FAKE_LOG"
SPOUT=$(SALA_SPAWN_PREFIX=delta-demo "$SALA" spawn --cwd "$HOME" 2>&1); GEN=$(grep -oE 'delta-demo-[0-9]{8}-[a-z]+' <<< "$SPOUT" | head -1)   # a name-less spawn: its name is generated and its registry row tagged throwaway
if [ -n "$GEN" ] && tmux has-session -t "=$GEN" 2>/dev/null; then
    fake_up gen-demo 2>/dev/null
    reset; uw SALA_UNREGISTERED_GRACE=0
    [ "$(nmiss)" = 1 ] && ! grep -q "$GEN" "$POSTS" && ok "the throwaway '$GEN' is not posted (only $B is)" || bad "throwaway: posts=$(nmiss): $(slurp "$POSTS")"
    $T kill-session -t "=$GEN"
else bad "no throwaway made by a name-less spawn: $SPOUT"; fi

echo "== c: a box with no stackshot, and the two switches, post nothing"
reset; mv "$SALA_PROJECT_RECORD" "$HOME/projects.json.away"
uw SALA_UNREGISTERED_GRACE=0
[ "$(nmiss)" = 0 ] && [ "$(ncant)" = 0 ] && [ "$(nkeys)" = 0 ] && ok "no record file and no stackshot client: nothing posted, nothing kept (silent)" || bad "no stackshot: posts=$(nmiss)/$(ncant) keys=$(nkeys): $(slurp "$POSTS")"
mv "$HOME/projects.json.away" "$SALA_PROJECT_RECORD"; mkrec 5 delta-demo-main
uw SALA_UNREGISTERED_GRACE=0 SALA_AGENT_CHECK=off
[ "$(nmiss)" = 0 ] && [ "$(nkeys)" = 0 ] && ok "SALA_AGENT_CHECK=off (the spawn gate's switch): nothing" || bad "agent check off: posts=$(nmiss) keys=$(nkeys)"
uw SALA_UNREGISTERED_GRACE=0 SALA_UNREGISTERED_CHECK=off
[ "$(nmiss)" = 0 ] && [ "$(nkeys)" = 0 ] && ok "SALA_UNREGISTERED_CHECK=off: nothing" || bad "check off: posts=$(nmiss) keys=$(nkeys)"
uw SALA_UNREGISTERED_GRACE=0
[ "$(nmiss)" = 1 ] && ok "and with the switches back, the same box posts the one missing pane" || bad "switches back: $(nmiss)"

echo "== d: a record that cannot answer: one 'could not check' post, no per-pane post, no key cleared"
reset; uw SALA_UNREGISTERED_GRACE=0; [ "$(nkeys)" = 1 ] || bad "setup: no key for $B"
: > "$POSTS"
mkrec 3600 delta-demo-main    # written an hour ago: stale
uw SALA_UNREGISTERED_GRACE=0; uw SALA_UNREGISTERED_GRACE=0
[ "$(ncant)" = 1 ] && [ "$(nmiss)" = 0 ] && ok "stale: one 'could not check' post across two runs, no per-pane post" || bad "stale: cant=$(ncant) miss=$(nmiss): $(slurp "$POSTS")"
grep -q 'stale' "$POSTS" && grep -q 'could not read an answer for were not reported' "$POSTS" && ok "it says why, and that nothing was reported" || bad "stale text: $(slurp "$POSTS")"
grep -q "^unreg\.$B=" "$WSTATE" && ok "the pane's key is kept (a record that cannot answer clears nothing)" || bad "key lost: $(grep unreg "$WSTATE")"
grep -q '^unreg_record=' "$WSTATE" && ok "the 'could not check' state key is kept" || bad "no unreg_record key"
uw SALA_UNREGISTERED_GRACE=0 SALA_UNREGISTERED_BACKOFF=0
[ "$(ncant)" = 2 ] && ok "past the back-off the 'could not check' line is posted again" || bad "after the back-off: $(ncant)"
: > "$POSTS"; echo '{"schema": 1, "proj' > "$SALA_PROJECT_RECORD"
uw SALA_UNREGISTERED_GRACE=0 SALA_UNREGISTERED_BACKOFF=0
[ "$(ncant)" = 1 ] && [ "$(nmiss)" = 0 ] && grep -q 'unreadable' "$POSTS" && ok "unreadable (garbage): the same one line, naming it" || bad "garbage: cant=$(ncant) miss=$(nmiss): $(slurp "$POSTS")"
: > "$POSTS"; rm -f "$SALA_PROJECT_RECORD"; printf '#!/usr/bin/env python3\n' > "$HOME/client.py"
uw SALA_UNREGISTERED_GRACE=0 SALA_UNREGISTERED_BACKOFF=0 SALA_STACKSHOT_CLIENT="$HOME/client.py"
[ "$(ncant)" = 1 ] && [ "$(nmiss)" = 0 ] && grep -q 'no project record' "$POSTS" && ok "missing, with a stackshot client on the box: the same one line" || bad "missing: cant=$(ncant) miss=$(nmiss): $(slurp "$POSTS")"
: > "$POSTS"; mkrec 5 delta-demo-main
uw SALA_UNREGISTERED_GRACE=0 SALA_UNREGISTERED_BACKOFF=0
! grep -q '^unreg_record=' "$WSTATE" && ok "the record answers again: its 'could not check' key goes" || bad "unreg_record kept: $(grep unreg_ "$WSTATE")"
[ "$(nmiss)" = 1 ] && [ "$(ncant)" = 0 ] && ok "and the pane is judged again against the fresh record" || bad "fresh again: miss=$(nmiss) cant=$(ncant)"

echo "== e: a plain watch tick runs the step"
reset
env SALA_UNREGISTERED_GRACE=0 "$SALA" watch >/dev/null 2>&1
[ "$(nmiss)" = 1 ] && grep -q "\*$B $HEAD\*" "$POSTS" && ok "a plain tick posts the missing pane" || bad "plain tick: posts=$(nmiss): $(slurp "$POSTS")"

echo "== f: a record that cannot answer: registry-tag exemptions come before the count, an outage deletes no key, the wording"
for n in "$B" delta-demo-main; do $T kill-session -t "=$n" 2>/dev/null; done; waitfor "! tmux has-session -t =$B 2>/dev/null && ! tmux has-session -t =delta-demo-main 2>/dev/null" 20
mktag() {  # <FAKE_SESSION_ID> <FAKE_NAME> → the name of a pane a name-less spawn made (its registry row tagged throwaway)
    $T set-environment -g FAKE_SESSION_ID "$1"; $T set-environment -g FAKE_NAME "$2"; $T set-environment -g FAKE_LOG "$FAKE_LOG"
    SALA_SPAWN_PREFIX=delta-demo "$SALA" spawn --cwd "$HOME" 2>&1 | grep -oE 'delta-demo-[0-9]{8}-[a-z]+' | head -1
}
TG=$(mktag aaaaaaaa-1111-4000-8000-00000000000a gen-demo-t); fake_up gen-demo-t 2>/dev/null
SG=$(mktag aaaaaaaa-1111-4000-8000-00000000000b gen-demo-s); fake_up gen-demo-s 2>/dev/null
rowtags() {  # <session> → "side throwaway" as the registry row reads back (1 or 0 each): what unreg_tag_exempt itself asks
    sessions_py resolve "$1" --live --json 2>/dev/null | python3 -I -c 'import json,sys
try: r=json.load(sys.stdin)
except Exception: sys.exit(0)
print("%s %s" % ("1" if r.get("side") else "0", "1" if r.get("throwaway") else "0"))' 2>/dev/null
}
if [ -n "$TG" ] && [ -n "$SG" ] && [ "$TG" != "$SG" ] && sessions_py set "$SG" side=1 >/dev/null 2>&1; then   # SG: a registry row tagged side ONLY (set side=1 clears the throwaway tag the name-less spawn put on it; the read-back below proves it), with no side record file and no -side- in its name
    [ "$(rowtags "$SG")" = "1 0" ] && [ "$(rowtags "$TG")" = "0 1" ] && ok "a: the fixture holds: $SG is side=1 throwaway=0 (side tag only), $TG is side=0 throwaway=1 (throwaway tag only)" || bad "a: fixture rows: SG='$(rowtags "$SG")' (want 1 0) TG='$(rowtags "$TG")' (want 0 1)"
    mkrec 3600 delta-demo-main    # stale
    reset; uw SALA_UNREGISTERED_GRACE=0; uw SALA_UNREGISTERED_GRACE=0
    [ "$(ncant)" = 0 ] && [ "$(nmiss)" = 0 ] && [ "$(nkeys)" = 0 ] && [ ! -s "$POSTS" ] && ok "a: stale record, only a registry-tagged side session and a tagged generated throwaway live: no 'could not check' post, no per-pane post, no key" || bad "a: tag-exempt only: cant=$(ncant) miss=$(nmiss) keys=$(nkeys): $(slurp "$POSTS")"
    ! grep -q '^unreg_record=' "$WSTATE" && ok "a: and no 'could not check' state key" || bad "a: unreg_record: $(grep unreg_ "$WSTATE")"
    mk "$B" "$D1"; fake_up "$B"
    GONE=delta-demo-gone-pane
    sed -i '/^unreg[._]/d' "$WSTATE"   # case b starts clean, whatever a left behind
    printf 'unreg.%s=100:0\nunreg.%s=100:0\n' "$B" "$GONE" >> "$WSTATE"   # a live pane's key and the key of a pane that is not live
    : > "$POSTS"; uw SALA_UNREGISTERED_GRACE=0; uw SALA_UNREGISTERED_GRACE=0
    [ "$(ncant)" = 1 ] && [ "$(nmiss)" = 0 ] && ok "b: stale record, one non-exempt live pane: one 'could not check' post (the tagged panes are not counted), no per-pane post" || bad "b: one bad pane: cant=$(ncant) miss=$(nmiss): $(slurp "$POSTS")"
    grep -q '1 live agent session(s) could not be checked' "$POSTS" && ok "b: it counts the one pane only" || bad "b: count: $(slurp "$POSTS")"
    grep -q "^unreg\.$B=" "$WSTATE" && grep -q "^unreg\.$GONE=" "$WSTATE" && ok "b: an outage deletes no key: the live pane's key and the key of a pane that is not live both stay" || bad "b: keys after the outage: $(grep unreg "$WSTATE")"
    grep -q 'panes this check could not read an answer for were not reported' "$POSTS" && ! grep -q 'no session was reported' "$POSTS" && ok "c: the line says the panes it could not read an answer for were not reported, and no longer claims that no session was reported" || bad "c: wording: $(slurp "$POSTS")"
    ! grep -qE '[0-9]{1,2}:[0-9]{2}|UTC|KST|20[0-9]{2}' "$POSTS" && ok "c: no time of day or zone in it" || bad "c: a time in the post: $(slurp "$POSTS")"
    : > "$POSTS"; mkrec 5 delta-demo-main "$B"
    uw SALA_UNREGISTERED_GRACE=0
    [ "$(nkeys)" = 0 ] && [ "$(nmiss)" = 0 ] && [ "$(ncant)" = 0 ] && ! grep -q '^unreg_record=' "$WSTATE" && ok "b: a readable record that lists the live pane: the keys of the listed pane and the gone pane go, nothing posted" || bad "b: readable again: keys=$(grep unreg "$WSTATE") miss=$(nmiss) cant=$(ncant)"
else bad "f: could not set up the tagged panes: throwaway='$TG' side='$SG'"; fi

echo "== h: an outage tick that reads no pane still keeps every key (one record-level answer per tick, independent of panes)"
hseed() { sed -i '/^unreg[._]/d' "$WSTATE"; printf 'unreg.%s=100:0\nunreg_record=100:0\n' delta-demo-held >> "$WSTATE"; : > "$POSTS"; }   # a pane's key (the pane is not live) and the outage post's key
hkept() { grep -q '^unreg\.delta-demo-held=100:0$' "$WSTATE" && grep -q '^unreg_record=100:0$' "$WSTATE"; }   # both exactly as seeded
$T kill-session -t "=$B" 2>/dev/null; waitfor "! tmux has-session -t =$B 2>/dev/null" 20
if [ -n "$TG" ] && [ -n "$SG" ]; then
    mkrec 3600 delta-demo-main    # stale
    hseed; uw SALA_UNREGISTERED_GRACE=0; uw SALA_UNREGISTERED_GRACE=0
    [ ! -s "$POSTS" ] && hkept && ok "b: stale record, only exempt live panes (the tagged throwaway and side session, and the exempt names): both keys kept, nothing posted" || bad "b: exempt only: posts=$(slurp "$POSTS") keys=$(grep unreg "$WSTATE")"
    mkrec 5 delta-demo-main; uw SALA_UNREGISTERED_GRACE=0
    [ "$(nkeys)" = 0 ] && ! grep -q '^unreg_record=' "$WSTATE" && [ ! -s "$POSTS" ] && ok "c: the same panes, a readable record: both keys go, nothing posted" || bad "c: readable again: keys=$(grep unreg "$WSTATE") posts=$(slurp "$POSTS")"
    $T kill-session -t "=$TG" 2>/dev/null; $T kill-session -t "=$SG" 2>/dev/null; waitfor "! tmux has-session -t =$TG 2>/dev/null && ! tmux has-session -t =$SG 2>/dev/null" 20
    mkrec 3600 delta-demo-main
    hseed; uw SALA_UNREGISTERED_GRACE=0; uw SALA_UNREGISTERED_GRACE=0
    [ ! -s "$POSTS" ] && hkept && ok "b: stale record, only panes exempt by their names live: both keys kept, nothing posted" || bad "b: name-exempt only: posts=$(slurp "$POSTS") keys=$(grep unreg "$WSTATE")"
else bad "h: no tagged panes to start from (f's setup failed)"; fi
$T kill-server 2>/dev/null; waitfor "! tmux has-session 2>/dev/null" 20   # no live pane at all: the scan is empty
mkrec 3600 delta-demo-main
hseed; uw SALA_UNREGISTERED_GRACE=0; uw SALA_UNREGISTERED_GRACE=0
[ ! -s "$POSTS" ] && hkept && ok "a: stale record, no live pane at all (empty scan): both keys kept, nothing posted" || bad "a: empty scan: posts=$(slurp "$POSTS") keys=$(grep unreg "$WSTATE")"
mkrec 5 delta-demo-main; uw SALA_UNREGISTERED_GRACE=0
[ "$(nkeys)" = 0 ] && ! grep -q '^unreg_record=' "$WSTATE" && [ ! -s "$POSTS" ] && ok "c: an empty scan and a readable record: both keys go, nothing posted" || bad "c: empty scan, readable: keys=$(grep unreg "$WSTATE") posts=$(slurp "$POSTS")"

# only the outage post's key is seeded (no pane key): the empty-scan probe must still count it as a key it could delete, so a stale record keeps it and a readable one clears it
mkrec 3600 delta-demo-main
sed -i '/^unreg[._]/d' "$WSTATE"; printf 'unreg_record=100:0\n' >> "$WSTATE"; : > "$POSTS"; uw SALA_UNREGISTERED_GRACE=0; uw SALA_UNREGISTERED_GRACE=0
[ ! -s "$POSTS" ] && grep -q '^unreg_record=100:0$' "$WSTATE" && ok "d: stale record, empty scan, only the 'could not check' key seeded: it is kept, nothing posted" || bad "d: only unreg_record, stale: posts=$(slurp "$POSTS") keys=$(grep unreg "$WSTATE")"
mkrec 5 delta-demo-main; uw SALA_UNREGISTERED_GRACE=0
! grep -q '^unreg_record=' "$WSTATE" && [ ! -s "$POSTS" ] && ok "d: the same, the record readable again: the key goes, nothing posted" || bad "d: only unreg_record, readable: keys=$(grep unreg "$WSTATE") posts=$(slurp "$POSTS")"

[ "$fail" = 0 ] && echo "unregistered: pass" || echo "unregistered: FAIL"
exit $fail
