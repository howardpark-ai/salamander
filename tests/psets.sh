#!/usr/bin/env bash
# Provision sets (2026-10-08; common.sh, "provision sets"): a `sala provision` run that leaves something on a
# box gets the recycle set's follow-up. Checks, against fake hosts (an `ssh` stub on PATH that runs the steps script
# locally, reading each host's STEP lines from a fixture; a host with an .offline marker does not answer), Slack stubbed to
# a file (SALA_NOTIFY_CMD) and the master's inbox stubbed (a fake claude in a private tmux server, its messaging socket
# replaced by a listener that writes what arrives to a file). The set's state, never the posts' wording: a clean
# run makes no set; a run with leftovers makes one, its items split by kind (session | owner; none = owner; the older spelling is read as owner); ONE master
# message carrying the exact settle and --waiting commands it will run, never sent twice; --waiting and --settle on the
# set's items; a failed step joining the set, retried by its worker and settled; the last settle closing the set, which
# then refuses --settle; a give-up closing it once; an offline box keeping its set open until a later provision of it
# settles it (clean, and with leftovers that join the set); `provision --only`: an unknown step refused before any box, the
# named steps applied then checked on every box, no CLI update, no recycle, no set, `repo` always included (a step named
# alone is sent as --only 'repo,<step>'). Isolated HOME, nothing real.
# Usage: bash tests/psets.sh   (exit 0 = pass; ~1 min)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_SET SALA_PSET_WORKER SALA_MASTER
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, tmux_socket_rm
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
as_op_unit   # no master: the guarded verbs this suite runs itself stand for the queue's runner (tests/lib.sh, 5)
mkdir -p "$HOME/.claude/sessions" "$HOME/.local/bin" "$HOME/hosts" "$HOME/.local/share/claude/versions"
touch "$HOME/.claude/salamander-rc.stopped"
cc -o "$HOME/.local/share/claude/versions/9.9.9" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
ln -s "$HOME/.local/share/claude/versions/9.9.9" "$HOME/.local/bin/claude"
# the fleet: ssh runs everything here; `bash -s` gets the steps script with FAKE_HOST set; the CLI update answers 9.9.9
cat > "$HOME/.local/bin/ssh" <<EOF
#!/usr/bin/env bash
while [ \$# -gt 0 ]; do case "\$1" in -o) shift 2;; -*) shift;; *) break;; esac; done
h="\$1"; shift; c="\$*"
[ -e "$HOME/hosts/\$h.offline" ] && exit 255
echo "\$h \$c" >> "$HOME/ssh.txt"
[ "\$c" != true ] && [ -e "$HOME/hosts/\$h.hang" ] && { i=0; while [ ! -e "$HOME/hosts/\$h.go" ] && [ \$i -lt 100 ]; do sleep 0.2; i=\$((i+1)); done; exit 1; }   # a box that does not answer past the ssh check (the scratch test below stops the run there; it lets go after 20 s on its own)
case "\$c" in true) :;; "bash -s"*) eval "FAKE_HOST=\$h bash -s \${c#bash -s}";; *claude*) echo "V|9.9.9|9.9.9";; esac
EOF
chmod +x "$HOME/.local/bin/ssh"
# the steps script: --list names three steps (one with a continuation line, as the real ones do); every other run is
# recorded as "<host> <args>" (this box: "local") and prints the host's fixture, its .check one under --check when there is one
cat > "$HOME/steps.sh" <<EOF
#!/bin/sh
case "\$*" in *--list*) printf 'deploy    the scripts\ngitcfg    git config,\n          continued\nsettings  the merge\n'; exit 0;; esac
h="\${FAKE_HOST:-local}"; echo "\$h \$*" >> "$HOME/calls.txt"
f="$HOME/hosts/\$h.steps"; case "\$*" in *--check*) [ -e "\$f.check" ] && f="\$f.check";; esac
cat "\$f"
EOF
printf '#!/bin/sh\necho "$*" >> "%s/systemd-run.txt"\n' "$HOME" > "$HOME/.local/bin/systemd-run"; chmod +x "$HOME/.local/bin/systemd-run"
export PATH="$HOME/.local/bin:$PATH"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="{ cat; echo '%%'; } >> $POSTS"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AGENT_CHECK=off SALA_PROVISION_STEPS="$HOME/steps.sh" SALA_FLEET_HOSTS=""
export SALA_RETRY_EVERY=2 SALA_RETRY_WINDOW=40 SALA_POST_UPDATE_CMD="" SALA_HEARTBEAT_STATE_DIR="" SALA_HEARTBEAT_REPO=""
SALA="$ROOT/bin/salamander"; SOCK="sala-psets-$$"; T="tmux -L $SOCK -f /dev/null"; INBOX="$HOME/inbox.txt"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's (common.sh, on_fleet_server)
cleanup() {
    local f p; for f in "$HOME"/.claude/salamander-pretry.*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done
    [ -n "${LPID:-}" ] && kill "$LPID" 2>/dev/null
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 0.5
    for p in $(pgrep -x claude); do [ "$HOME/.local/share/claude/versions/9.9.9" -ef "/proc/$p/exe" ] && kill -9 "$p" 2>/dev/null; done
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux
. "$ROOT/lib/common.sh"
show() { sed 's/^/      | /' "$POSTS" 2>/dev/null | grep -v '| %%$'; }
nmsgs() { awk -v RS='%%\n' 'NF {n++} END {print n+0}' "$INBOX" 2>/dev/null; }
steps() { local h="$1"; shift; printf '%s\n' "$@" > "$HOME/hosts/$h.steps"; }   # <host> <STEP line…>
newset() { ls "$SALA_SET_DIR" 2>/dev/null | grep -E '^[0-9]+-[0-9]+$' | while read -r f; do grep -qx 'closed=0' "$SALA_SET_DIR/$f" && echo "$f"; done | tail -1; }
OKS=("STEP|ok|deploy|current" "STEP|ok|gitcfg|ok" "STEP|ok|settings|ok")

echo "== the master: a fake claude in a private tmux server, its inbox socket a listener writing to a file"
$T new-session -d -s sala-test-master -c "$HOME" -e FAKE_SESSION_ID=00000000-0000-4000-8000-0000000000aa -e FAKE_NAME=master; $T send-keys -t sala-test-master 'claude' Enter
waitfor 'ls "$HOME"/.claude/fake-*.sock >/dev/null 2>&1' 20 || { echo "the fake master did not start"; exit 1; }
MSOCK=$(ls "$HOME"/.claude/fake-*.sock | head -1); rm -f "$MSOCK"
python3 - "$MSOCK" "$INBOX" <<'PYL' &
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(5)
while True:
    c, _ = s.accept(); data = b""
    while True:
        b = c.recv(65536)
        if not b: break
        data += b
    c.close()
    for line in data.decode().splitlines():
        if line.strip():
            with open(sys.argv[2], "a") as f: f.write(json.loads(line)["message"]["content"] + "\n%%\n")
PYL
LPID=$!; export SALA_CUE_TARGET=sala-test-master
waitfor '[ -S "$MSOCK" ]' 20 && ok "the master's inbox is stubbed" || { echo "listener did not start"; exit 1; }

echo "== a clean run: the single fleet post, no set"
steps t-host-c "${OKS[@]}"
"$SALA" provision t-host-c >/dev/null 2>&1
[ -z "$(newset)" ] && ok "no set made" || bad "a set was made: $(newset)"
: > "$POSTS"

echo "== a run with leftovers: the first post, the kinds, one message to the master"
steps t-host-a "${OKS[@]}" "STEP|manual|repo|local commits, fast-forward refused" "STEP|manual|deny-rules|missing|session"
out=$("$SALA" provision t-host-a t-host-c 2>&1)
A=$(newset)
[ -n "$A" ] && [ "$(set_val "$A" kind)" = Provision ] && [ "$(set_val "$A" total)" = 2 ] && [ "$(set_val "$A" done)" = 1 ] && ok "set $A: kind Provision, N=2 boxes, n=1 OK" || bad "set: $(slurp "$SALA_SET_DIR/$A")"
grep -q '^item=t-host-a|repo|owner|' "$SALA_SET_DIR/$A" && grep -q '^item=t-host-a|deny-rules|session|' "$SALA_SET_DIR/$A" && ok "kinds: repo (no 5th field) → owner, deny-rules → session" || bad "items: $(grep ^item= "$SALA_SET_DIR/$A")"
waitfor '[ "$(nmsgs)" -ge 1 ]' 10
# the 5th field: owner, session, none (= owner)
[ "$(pstep_parse 'STEP|manual|x|d|owner')" = "$(printf 'manual\tx\td\towner')" ] \
    && [ "$(pstep_parse 'STEP|manual|x|d')" = "$(printf 'manual\tx\td\towner')" ] && [ "$(pstep_parse 'STEP|manual|x|d|session')" = "$(printf 'manual\tx\td\tsession')" ] \
    && ok "pstep_parse: owner and none give owner; session stays session" || bad "pstep_parse: $(pstep_parse 'STEP|manual|x|d|owner') / $(pstep_parse 'STEP|manual|x|d') / $(pstep_parse 'STEP|manual|x|d|session')"
[ "$(nmsgs)" = 1 ] && ok "exactly one message to the master" || bad "$(nmsgs) messages: $(<"$INBOX")"
M=$(<"$INBOX")
grep -qF "(set $A)" <<< "$M" && grep -qF "• t-host-a · deny-rules (deny entries): missing" <<< "$M" && grep -qF "sala provision --settle $A t-host-a deny-rules ok \"" <<< "$M" \
    && ok "it names the set, host, step, detail and the exact settle command for the session item" || bad "message: $M"
grep -qF "sala provision --waiting $A t-host-a repo \"<item id> is waiting on your OK in <your session>\"" <<< "$M" && grep -q 'board item' <<< "$M" \
    && ok "the owner item: file a board item, then --waiting (one plain command)" || bad "owner part: $M"
[ "$(set_count "$A" tell)" = 0 ] && ok "told: nothing pending" || bad "tell left: $(set_vals "$A" tell)"
pset_tell "$A"; [ "$(nmsgs)" = 1 ] && ok "telling again sends nothing" || bad "a second message"

echo "== --waiting, a failed step retried and settled by the set's worker, --settle closing the set"
r=$("$SALA" provision --waiting "$A" t-host-a repo "box-a is waiting on your OK in ops-main" 2>&1) && ok "--waiting: $r" || bad "--waiting failed: $r"
"$SALA" provision --waiting "$A" t-host-a nosuch "x" >/dev/null 2>&1 && bad "--waiting on a missing item succeeded" || ok "--waiting on a missing item is refused"
r=$("$SALA" provision --settle "$A" t-host-a deny-rules ok "deny entries added" 2>&1) && ok "--settle deny-rules: $r" || bad "--settle failed: $r"
: > "$POSTS"
steps t-host-a "${OKS[@]:0:2}" "STEP|failed|settings|merge failed: locked" "STEP|manual|repo|local commits, fast-forward refused"
"$SALA" provision t-host-a >/dev/null 2>&1
grep -q '^item=t-host-a|settings|' "$SALA_SET_DIR/$A" && [ -z "$(newset | grep -vx "$A")" ] && ok "the failed step joins the open set (no new set)" || bad "join: $(grep ^item= "$SALA_SET_DIR/$A"); sets: $(newset)"
waitfor 'pset_worker_live "$A"' 10 && ok "the set's retry worker runs" || bad "no retry worker: $(tail -5 "$SALA_PSET_LOG")"
steps t-host-a "${OKS[@]:0:2}" "STEP|fixed|settings|merged" "STEP|manual|repo|local commits, fast-forward refused"
waitfor '! grep -q "^item=t-host-a|settings|" "$SALA_SET_DIR/$A"' 40 && ok "a retry settled the failed step (it came back fixed)" || bad "settings still open: $(tail -5 "$SALA_PSET_LOG")"
waitfor '! pset_worker_live "$A"' 20 && ok "the worker stops once no failed item is left" || bad "worker still running"
grep -qx 'fix=t-host-a|settings fixed' "$SALA_SET_DIR/$A" && ok "recorded: settings fixed" || bad "fix lines: $(grep ^fix= "$SALA_SET_DIR/$A")"
r=$("$SALA" provision --settle "$A" t-host-a repo ok "repo back in step with GitHub" 2>&1); echo "      $r"
[ "$(set_val "$A" closed)" = 1 ] && [ "$(set_val "$A" done)" = 2 ] && [ -n "$(post '· set closed')" ] && ok "the last settle closed the set: 2/2, its \"set closed\" post out" || bad "closed=$(set_val "$A" closed): $(show)"
"$SALA" provision --settle "$A" t-host-a repo ok >/dev/null 2>&1 && bad "settling a closed set succeeded" || ok "a closed set refuses --settle"
: > "$POSTS"

echo "== give-up: an item waiting on Rowan past the window → \"closed at 0/1\", once"
steps t-host-a "${OKS[@]}" "STEP|manual|auth|not logged in"
"$SALA" provision t-host-a >/dev/null 2>&1; B=$(newset)
"$SALA" provision --waiting "$B" t-host-a auth "box-b is waiting on your OK in ops-main" >/dev/null 2>&1
sed -i -E "s/^(item=t-host-a\|auth\|owner\|)[0-9]+/\1$(( $(date +%s) - 700000 ))/" "$SALA_SET_DIR/$B"
pset_expire "$B"; pset_expire "$B"
[ "$(set_val "$B" closed)" = 1 ] && [ -n "$(post 'closed at')" ] && ok "past the window the set is given up: closed, its \"closed at\" post out" || bad "give-up: $(cat "$SALA_SET_DIR/$B"; show)"
[ "$(nposts 'closed at')" = 1 ] && ok "posted once" || bad "posted $(nposts 'closed at') times"
: > "$POSTS"

echo "== an offline box keeps the set open; a later provision of it settles it (clean)"
steps t-host-b "${OKS[@]}"; touch "$HOME/hosts/t-host-b.offline"
"$SALA" provision t-host-c t-host-b >/dev/null 2>&1; C1=$(newset)
[ -n "$C1" ] && [ "$(set_val "$C1" total)" = 2 ] && [ "$(set_val "$C1" done)" = 1 ] && ok "a set for the offline box: 1/2, open" || bad "offline set: $(slurp "$SALA_SET_DIR/$C1")"
sleep 1; pset_worker_live "$C1" && bad "a retry worker for an offline box" || ok "no retry worker for it"
rm -f "$HOME/hosts/t-host-b.offline"; "$SALA" provision t-host-b >/dev/null 2>&1
[ "$(set_val "$C1" done)" = 2 ] && [ "$(set_val "$C1" closed)" = 1 ] && ok "back online and clean: the same set settled and closed (2/2)" || bad "offline settle: $(<"$SALA_SET_DIR/$C1")"
: > "$POSTS"

echo "== an offline box back with leftovers: they join the same set, the master hears of the session one"
touch "$HOME/hosts/t-host-b.offline"; "$SALA" provision t-host-c t-host-b >/dev/null 2>&1; D=$(newset)
rm -f "$HOME/hosts/t-host-b.offline"; steps t-host-b "${OKS[@]}" "STEP|manual|resurrect-timer|no snapshot in 20 min|session"
"$SALA" provision t-host-b >/dev/null 2>&1
grep -q '^item=t-host-b|resurrect-timer|session|' "$SALA_SET_DIR/$D" && [ "$(set_val "$D" closed)" = 0 ] && ok "its leftover joins the same set, still open" || bad "join: $(<"$SALA_SET_DIR/$D")"
"$SALA" provision --settle "$D" t-host-b resurrect-timer ok "saver restarted" >/dev/null 2>&1
[ "$(set_val "$D" done)" = 2 ] && [ "$(set_val "$D" closed)" = 1 ] && ok "settled: the set closed (2/2)" || bad "close: $(<"$SALA_SET_DIR/$D")"

echo "== --only: just the named steps, the apply then their check, on every box; no CLI update, no recycle, no set"
: > "$HOME/calls.txt"; : > "$HOME/ssh.txt"
"$SALA" provision --only settings,nosuch t-host-c >/dev/null 2>&1 && bad "an unknown step was accepted" || ok "an unknown step is refused"
[ ! -s "$HOME/calls.txt" ] && [ ! -s "$HOME/ssh.txt" ] && ok "and nothing reached a box" || bad "reached: $(cat "$HOME/calls.txt" "$HOME/ssh.txt")"
for h in t-host-c t-host-a local; do steps "$h" "STEP|fixed|settings|1 entry merged"; echo "STEP|ok|settings|ok" > "$HOME/hosts/$h.steps.check"; done
rm -f "$SALA_LOG_DIR/salamander-recycle.lock" "$SALA_LOG_DIR/salamander-revive.log"; sets_before=$(ls "$SALA_SET_DIR" | wc -l)
# timeout: a regression that recycles would hang in the fake claude's `update`, not fail
SALA_FLEET_HOSTS="t-host-c t-host-a" timeout 120 "$SALA" provision --only settings >/dev/null 2>&1; rc=$?
for h in t-host-c t-host-a local; do
    got=$(grep "^$h " "$HOME/calls.txt" | tr '\n' '/')
    [ "$got" = "$h --only settings/$h --check --only settings/" ] && ok "$h: the steps ran with --only settings, then --check --only settings" || bad "$h: $got"
done
[ "$rc" = 0 ] && ok "exit 0 when the check after the apply is clean" || bad "exit $rc"
! grep -q claude "$HOME/ssh.txt" && ok "no CLI update sent to a box" || bad "ssh: $(grep claude "$HOME/ssh.txt")"
[ ! -e "$SALA_LOG_DIR/salamander-recycle.lock" ] && [ ! -e "$SALA_LOG_DIR/salamander-revive.log" ] && ok "a whole-fleet --only run never recycles" || bad "a recycle ran: $(cat "$SALA_LOG_DIR/salamander-revive.log" 2>/dev/null | tail -3)"
[ "$(ls "$SALA_SET_DIR" | wc -l)" = "$sets_before" ] && ok "no provision set (its retry worker would run a whole provision)" || bad "a set was made: $(newset)"

echo "== --only always runs repo first: a step named alone is sent with repo added, so the checkout is current"
# `--only <step>` once never fast-forwarded the checkout first; the boxes stayed hundreds of commits behind and the step
# failed on the stale checkout (the case then was a step of one platform; a later change retired it, the rule stays)
printf '#!/bin/sh\ncase "$*" in *--list*) printf "repo      fast-forward\\nsettings  the merge\\n";; esac\n' > "$HOME/steps-repo.sh"
for mode in "" --check; do : > "$HOME/ssh.txt"
    SALA_PROVISION_STEPS="$HOME/steps-repo.sh" timeout 120 "$SALA" provision $mode --only settings t-host-c >/dev/null 2>&1
    grep -qF "bash -s -- ${mode:+$mode }--only 'repo,settings'" "$HOME/ssh.txt" && ok "${mode:-apply}: the steps sent with --only 'repo,settings'" || bad "${mode:-apply}: repo not added: $(grep -v ' true$' "$HOME/ssh.txt")"
done

echo "== a provision or heartbeat run stopped by SIGTERM (a timeout, a cancelled CI job) leaves nothing in TMPDIR"
SCR="$HOME/scratch"; mkdir -p "$SCR" "$HOME/hbstate"; touch "$HOME/hosts/t-hang.hang"; steps t-hang "${OKS[@]}"
left() { ls -A "$SCR" 2>/dev/null; }
TMPDIR="$SCR" "$SALA" provision t-hang >/dev/null 2>&1 &
SP=$!
waitfor '[ -n "$(left)" ]' 40 && case "$(left)" in sala-provision.*) ok "a provision in flight holds its result folder (sala-provision.*) in TMPDIR" ;; *) bad "unexpected name: $(left | tr '\n' ' ')" ;; esac || bad "no result folder while the provision runs"
kill -TERM "$SP" 2>/dev/null; wait "$SP" 2>/dev/null
[ -z "$(left)" ] && ok "stopped by SIGTERM: the result folder is gone (the EXIT trap removed it)" || bad "left after the stop: $(left | tr '\n' ' ')"
TMPDIR="$SCR" SALA_FLEET_HOSTS="t-hang" SALA_HEARTBEAT_STATE_DIR="$HOME/hbstate" SALA_HEARTBEAT_REPO="" SALA_HEARTBEAT_GIT=off SALA_HEARTBEAT_LETTER=z "$SALA" heartbeat --dry-run >/dev/null 2>&1 &
SP=$!
waitfor '[ -n "$(left)" ]' 40 && case "$(left)" in sala-heartbeat.*) ok "a heartbeat sweep in flight holds its probe folder (sala-heartbeat.*) in TMPDIR" ;; *) bad "unexpected name: $(left | tr '\n' ' ')" ;; esac || bad "no probe folder while the sweep runs"
kill -TERM "$SP" 2>/dev/null; wait "$SP" 2>/dev/null
[ -z "$(left)" ] && ok "stopped by SIGTERM: the probe folder is gone" || bad "left after the stop: $(left | tr '\n' ' ')"
: > "$HOME/hosts/t-hang.go"   # lets the hung ssh stubs end

[ "$fail" = 0 ] && echo "PASS" || echo "FAILED"
exit "$fail"
