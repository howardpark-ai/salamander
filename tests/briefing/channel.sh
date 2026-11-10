#!/usr/bin/env bash
# Named Slack channels: a post can name a channel (a short [a-z0-9-]+ name), and a channel with its own webhook file posts there.
# Part 1, `salamander alert --channel`: the stub notify command sees SALA_NOTIFY_CHANNEL=<name> for that call and the same text, and
#   does not see the variable without --channel (even when the caller's own environment has one); --channel=<name>; a name outside
#   [a-z0-9-]+ (or none) is exit 2 with nothing posted or logged; options only before the headline; `--` and a headline that
#   starts with `-`; -h and --help print the usage and post nothing; sala_post (sala's own notices) never carries a channel; a hung
#   notify command is still stopped at SALA_NOTIFY_TIMEOUT.
# Part 2, post_slack against a listener on 127.0.0.1 (one path per webhook file): the channel's file when it exists and holds a
#   URL (BRIEFING_CHANNEL before SALA_NOTIFY_CHANNEL; the name in capitals with dashes as underscores; the config line, the
#   environment over it), the default file when the setting is unset or empty, the file is missing, empty or blank, or the name
#   does not match; post-stdin.sh end to end behind `salamander alert --channel`.
# Part 3, the jobs: release-alert.sh, summary-lean.sh, summary.sh, defunct.sh and reply.sh post to `reports` by default (their
#   own failure notices included), BRIEFING_CHANNEL moves one, and an unset reports setting falls back to the default webhook.
# Nothing leaves the box and no real webhook is read.
# Usage: bash tests/briefing/channel.sh   (exit 0 = pass; a few seconds)
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd); D=$ROOT/contrib/briefing
fail=0; ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fail=1; }
T=$(mktemp -d); trap 'kill "${SRV:-}" 2>/dev/null; rm -rf "$T"' EXIT
exec 8<"$T"; flock -n 8   # systemd-tmpfiles ageing honours a held flock on the folder
unset SALA_NOTIFY_CMD SALA_WATCH_NOTIFY_CMD SALA_STACKSHOT_WEB SALA_NOTIFY_CHANNEL BRIEFING_CHANNEL BRIEFING_THREAD_TS BRIEFING_NO_POST \
      BRIEFING_WEBHOOK_FILE BRIEFING_WEBHOOK_FILE_REPORTS BRIEFING_WEBHOOK_FILE_STACK_OPS BRIEFING_WEBHOOK_FILE_OPS BRIEFING_GMAIL_CONNECTOR BRIEFING_FORWARD_LABEL
mkdir -p "$T/home" "$T/log" "$T/bin" "$T/blog"
export HOME=$T/home

# ------------------------------------------------------------------------------------------------ part 1: salamander alert
# the stub notify command: records the channel variable (or that it is unset) and the text it was given, one pair of files per call
cat > "$T/notify.sh" <<EOF
#!/bin/sh
n=\$(ls "$T" | grep -c '^seen\\.')
n=\$((n + 1))
if [ "\${SALA_NOTIFY_CHANNEL+x}" = x ]; then echo "set:\$SALA_NOTIFY_CHANNEL" > "$T/seen.\$n"; else echo unset > "$T/seen.\$n"; fi
cat > "$T/text.\$n"
EOF
chmod +x "$T/notify.sh"
calls() { ls "$T" | grep -c '^seen\.'; }
reset() { rm -f "$T"/seen.* "$T"/text.* "$T/log/salamander-alert.log"; }
alert() { SALA_NOTIFY_CMD=$T/notify.sh SALA_CONFIG=/dev/null SALA_LOG_DIR=$T/log bash "$ROOT/bin/salamander" alert "$@" >"$T/alert.out" 2>&1; }

reset; alert "Disk is full" "host one" "Details: /var/log/x"; rc=$?
[ $rc = 0 ] && [ "$(calls)" = 1 ] && [ "$(cat "$T/seen.1")" = unset ] && ok "no --channel: the notify command sees no SALA_NOTIFY_CHANNEL" || bad "plain alert: rc=$rc calls=$(calls) seen=$(cat "$T/seen.1" 2>/dev/null)"
cp "$T/text.1" "$T/plain.txt"
want=$(printf '%s\n%s\n%s' '⚠️ *Disk is full*' '    • host one' 'Details: /var/log/x')
[ "$(cat "$T/plain.txt")" = "$want" ] && ok "the plain alert's text is sala_post's shape (the baseline for the channel runs)" || bad "plain text: $(cat "$T/plain.txt")"
grep -q 'channel' "$T/log/salamander-alert.log" && bad "the log line of a plain alert names a channel: $(cat "$T/log/salamander-alert.log")" || ok "the log line of a plain alert is unchanged (no channel in it)"

reset; alert --channel reports "Disk is full" "host one" "Details: /var/log/x"; rc=$?
[ $rc = 0 ] && [ "$(calls)" = 1 ] && [ "$(cat "$T/seen.1")" = set:reports ] && ok "--channel reports: the notify command sees SALA_NOTIFY_CHANNEL=reports" || bad "--channel: rc=$rc calls=$(calls) seen=$(cat "$T/seen.1" 2>/dev/null)"
cmp -s "$T/text.1" "$T/plain.txt" && ok "--channel reports: the posted text is the same as without it" || bad "channel text differs: $(cat "$T/text.1")"
grep -qF '(channel reports)' "$T/log/salamander-alert.log" && ok "the alert log line names the channel" || bad "log: $(cat "$T/log/salamander-alert.log" 2>/dev/null)"

reset; alert --channel=stack-ops "Disk is full" "host one" "Details: /var/log/x"; rc=$?
[ $rc = 0 ] && [ "$(cat "$T/seen.1" 2>/dev/null)" = set:stack-ops ] && cmp -s "$T/text.1" "$T/plain.txt" && ok "--channel=stack-ops (the = form, a dash in the name): channel and text arrive" || bad "--channel=: rc=$rc seen=$(cat "$T/seen.1" 2>/dev/null)"

reset; alert --channel 7-up-2 "x"; rc=$?
[ $rc = 0 ] && [ "$(cat "$T/seen.1" 2>/dev/null)" = set:7-up-2 ] && ok "digits and dashes are fine in a name" || bad "digit name: rc=$rc seen=$(cat "$T/seen.1" 2>/dev/null)"

# the caller's own environment must not leak a channel into a post that names none
reset; SALA_NOTIFY_CHANNEL=leak alert "Disk is full" "host one" "Details: /var/log/x"; rc=$?
[ $rc = 0 ] && [ "$(cat "$T/seen.1" 2>/dev/null)" = unset ] && ok "an inherited SALA_NOTIFY_CHANNEL is removed from a post that names no channel" || bad "leak: rc=$rc seen=$(cat "$T/seen.1" 2>/dev/null)"
reset; SALA_NOTIFY_CHANNEL=leak alert --channel reports "x"; rc=$?
[ "$(cat "$T/seen.1" 2>/dev/null)" = set:reports ] && ok "--channel wins over an inherited SALA_NOTIFY_CHANNEL" || bad "override: seen=$(cat "$T/seen.1" 2>/dev/null)"

# SALA_WATCH_NOTIFY_CMD (the other name of the setting) gets it too
reset; SALA_NOTIFY_CMD= SALA_WATCH_NOTIFY_CMD=$T/notify.sh SALA_CONFIG=/dev/null SALA_LOG_DIR=$T/log bash "$ROOT/bin/salamander" alert --channel reports "x" >/dev/null 2>&1; rc=$?
[ $rc = 0 ] && [ "$(cat "$T/seen.1" 2>/dev/null)" = set:reports ] && ok "SALA_WATCH_NOTIFY_CMD gets the channel too" || bad "watch cmd: rc=$rc seen=$(cat "$T/seen.1" 2>/dev/null)"

# a bad name: exit 2, nothing posted, nothing logged
for badname in Reports rep_orts 'two words' 'a/b' 'a.b' 'é' ';touch x' '$(id)' ''; do
    reset; alert --channel "$badname" "x"; rc=$?
    [ $rc = 2 ] && [ "$(calls)" = 0 ] && [ ! -e "$T/log/salamander-alert.log" ] && grep -q 'channel name' "$T/alert.out" \
        && ok "--channel '$badname': usage error, exit 2, nothing posted or logged" || bad "--channel '$badname': rc=$rc calls=$(calls) out=$(cat "$T/alert.out")"
done
reset; alert "--channel=" "x"; rc=$?
[ $rc = 2 ] && [ "$(calls)" = 0 ] && ok "--channel= (empty): exit 2, nothing posted" || bad "--channel=: rc=$rc calls=$(calls)"
reset; alert --channel; rc=$?
[ $rc = 2 ] && [ "$(calls)" = 0 ] && ok "--channel with no name: exit 2" || bad "--channel alone: rc=$rc calls=$(calls)"
reset; alert --channel reports; rc=$?
[ $rc = 2 ] && [ "$(calls)" = 0 ] && ok "--channel reports with no headline: exit 2, nothing posted" || bad "no headline: rc=$rc calls=$(calls)"
reset; alert --channel reports --; rc=$?
[ $rc = 2 ] && [ "$(calls)" = 0 ] && ok "--channel reports -- with no headline: exit 2" || bad "-- and no headline: rc=$rc calls=$(calls)"

# options only before the headline: after it, --channel is a bullet line
reset; alert "Disk is full" --channel reports; rc=$?
[ $rc = 0 ] && [ "$(cat "$T/seen.1" 2>/dev/null)" = unset ] && grep -qF '    • --channel' "$T/text.1" && grep -qF '    • reports' "$T/text.1" \
    && ok "--channel after the headline is not an option: no channel, the words are bullets" || bad "late option: rc=$rc seen=$(cat "$T/seen.1" 2>/dev/null) text=$(cat "$T/text.1" 2>/dev/null)"

# `--` ends the options: a headline that starts with `-`
reset; alert --channel reports -- "-h failed" "line"; rc=$?
[ $rc = 0 ] && [ "$(cat "$T/seen.1" 2>/dev/null)" = set:reports ] && [ "$(head -1 "$T/text.1")" = '⚠️ *-h failed*' ] \
    && ok "--channel reports -- '-h failed': the headline starting with - posts to the channel" || bad "-- headline: rc=$rc seen=$(cat "$T/seen.1" 2>/dev/null) text=$(cat "$T/text.1" 2>/dev/null)"
reset; alert -- "-h failed"; rc=$?
[ $rc = 0 ] && [ "$(cat "$T/seen.1" 2>/dev/null)" = unset ] && [ "$(head -1 "$T/text.1")" = '⚠️ *-h failed*' ] \
    && ok "-- '-h failed' without a channel still posts (the existing rule)" || bad "-- alone: rc=$rc text=$(cat "$T/text.1" 2>/dev/null)"
reset; alert "-h failed"; rc=$?
[ $rc = 0 ] && [ "$(head -1 "$T/text.1")" = '⚠️ *-h failed*' ] && ok "a first argument '-h failed' is a headline (the existing rule)" || bad "-h failed: rc=$rc"
reset; alert --channel reports "--helpful"; rc=$?
[ $rc = 0 ] && [ "$(head -1 "$T/text.1")" = '⚠️ *--helpful*' ] && ok "--channel reports '--helpful': the headline after the channel is not an option" || bad "--helpful: rc=$rc text=$(cat "$T/text.1" 2>/dev/null)"

# -h / --help: the usage, nothing posted, nothing logged, no notify command needed
for h in -h --help; do
    reset; out=$(env -u SALA_NOTIFY_CMD -u SALA_WATCH_NOTIFY_CMD SALA_CONFIG=/dev/null SALA_LOG_DIR=$T/log bash "$ROOT/bin/salamander" alert "$h" 2>&1); rc=$?
    [ $rc = 0 ] && [ "$(calls)" = 0 ] && [ ! -e "$T/log/salamander-alert.log" ] && printf '%s\n' "$out" | grep -qF -- '--channel <name>' && printf '%s\n' "$out" | grep -q '^usage: salamander alert' \
        && ok "alert $h: the usage (naming --channel), exit 0, nothing posted or logged" || bad "alert $h: rc=$rc calls=$(calls) out=$out"
done
reset; alert -h; [ "$(calls)" = 0 ] && ok "alert -h with the notify command set posts nothing" || bad "-h posted"

# sala_post (sala's own notices, the watch's alerts): never a channel, even with one in the caller's environment
reset
( export SALA_NOTIFY_CHANNEL=leak SALA_NOTIFY_CMD=$T/notify.sh SALA_CONFIG=/dev/null SALA_LOG_DIR=$T/log
  . "$ROOT/lib/common.sh" >/dev/null 2>&1; sala_post "Recycle done" "one session" )
[ "$(cat "$T/seen.1" 2>/dev/null)" = unset ] && [ "$(calls)" = 1 ] && ok "sala_post (sala's own notices): no SALA_NOTIFY_CHANNEL reaches the command" || bad "sala_post: calls=$(calls) seen=$(cat "$T/seen.1" 2>/dev/null)"
reset
( export SALA_NOTIFY_CMD=$T/notify.sh SALA_CONFIG=/dev/null SALA_LOG_DIR=$T/log
  . "$ROOT/lib/common.sh" >/dev/null 2>&1; printf 'a post\n' | sala_send_post "$SALA_NOTIFY_CMD" reports; echo "rc=$?" > "$T/sendrc"; printf 'a post\n' | sala_send_post "$SALA_NOTIFY_CMD" )
[ "$(cat "$T/seen.1" 2>/dev/null)" = set:reports ] && [ "$(cat "$T/seen.2" 2>/dev/null)" = unset ] && [ "$(cat "$T/sendrc")" = rc=0 ] \
    && ok "sala_send_post <cmd> <channel>: the variable for that call only; the next call without one is clean" || bad "send_post: $(cat "$T/seen.1" 2>/dev/null) / $(cat "$T/seen.2" 2>/dev/null) / $(cat "$T/sendrc" 2>/dev/null)"

# the timeout wrapper is still there with a channel, and the exit code is the command's
t0=$(date +%s)
SALA_NOTIFY_CMD='sleep 60' SALA_NOTIFY_TIMEOUT=1 SALA_CONFIG=/dev/null SALA_LOG_DIR=$T/log bash "$ROOT/bin/salamander" alert --channel reports '*stuck post*' >/dev/null 2>&1; rc=$?
dt=$(( $(date +%s) - t0 ))
[ $rc = 1 ] && [ $dt -lt 20 ] && ok "a hung notify command is stopped at SALA_NOTIFY_TIMEOUT with a channel too (exit 1 after ${dt}s)" || bad "hung command: rc=$rc after ${dt}s"
SALA_NOTIFY_CMD='exit 3' SALA_CONFIG=/dev/null SALA_LOG_DIR=$T/log bash "$ROOT/bin/salamander" alert --channel reports 'x' >/dev/null 2>&1; rc=$?
[ $rc = 1 ] && ok "a failing notify command is exit 1 with a channel too" || bad "failing command: rc=$rc"

# ------------------------------------------------------------------------------------------------ part 2: post_slack and the webhook files
# one listener, one path per webhook file; each request is kept as path.N and body.N
python3 - "$T/port" "$T/req" <<'PY' &
import http.server, sys
port_file, base = sys.argv[1], sys.argv[2]
seen = [0]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        seen[0] += 1
        open(f"{base}.path.{seen[0]}", "w").write(self.path)
        open(f"{base}.body.{seen[0]}", "wb").write(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(port_file, "w").write(str(s.server_address[1]))
s.serve_forever()
PY
SRV=$!
for _ in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
[ -s "$T/port" ] || { bad "the 127.0.0.1 listener did not start"; exit 1; }
PORT=$(cat "$T/port")
wh() { printf 'http://127.0.0.1:%s/%s\n' "$PORT" "$1" > "$2"; }
wh default "$T/wh-default"; wh reports "$T/wh-reports"; wh ops "$T/wh-ops"
: > "$T/wh-empty"; printf ' \n\t\n' > "$T/wh-blank"
cat > "$T/config" <<EOF
BRIEFING_WEBHOOK_FILE=$T/wh-default
BRIEFING_WEBHOOK_FILE_REPORTS=$T/wh-reports
BRIEFING_WEBHOOK_FILE_STACK_OPS=$T/wh-ops
BRIEFING_WEBHOOK_FILE_GONE=$T/wh-does-not-exist
BRIEFING_WEBHOOK_FILE_EMPTY=$T/wh-empty
BRIEFING_WEBHOOK_FILE_BLANK=$T/wh-blank
BRIEFING_WEBHOOK_FILE_UNSET_ONE=
EOF
export SALA_CONFIG=$T/config BRIEFING_LOGDIR=$T/blog BRIEFING_SESSIONS_CMD=true BRIEFING_BOARD_DIR=$T/no-board BRIEFING_COMMIT_REPOS=
nreq() { ls "$T" | grep -c '^req\.path\.'; }
lastpath() { cat "$T/req.path.$(nreq)" 2>/dev/null; }
# post <VAR=val…> -- <text> posts through the real lib.sh's post_slack with a clean channel environment
post() {
    local envs=(); while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
    env -u BRIEFING_CHANNEL -u SALA_NOTIFY_CHANNEL ${envs[@]+"${envs[@]}"} bash -c '. "$1/lib.sh" 2>/dev/null; post_slack "$2"' _ "$D" "$1" 2>&1
}
expect() { # expect <label> <path> <env…>: one post with that environment must land on /<path>
    local label=$1 want=$2; shift 2; local n out; n=$(nreq)
    out=$(post "$@" -- "a post for $label");
    if [ "$out" = ok ] && [ "$(nreq)" = $((n + 1)) ] && [ "$(lastpath)" = "/$want" ]; then ok "$label: posted to /$want"; else bad "$label: want /$want, got $(lastpath) (out=$out, requests $n -> $(nreq))"; fi
}
expect "no channel" default
expect "BRIEFING_CHANNEL=reports (the config line)" reports BRIEFING_CHANNEL=reports
expect "SALA_NOTIFY_CHANNEL=reports" reports SALA_NOTIFY_CHANNEL=reports
expect "BRIEFING_CHANNEL=stack-ops (STACK_OPS: capitals, dash as underscore)" ops BRIEFING_CHANNEL=stack-ops
expect "BRIEFING_CHANNEL before SALA_NOTIFY_CHANNEL" ops BRIEFING_CHANNEL=stack-ops SALA_NOTIFY_CHANNEL=reports
expect "an empty BRIEFING_CHANNEL leaves SALA_NOTIFY_CHANNEL" reports BRIEFING_CHANNEL= SALA_NOTIFY_CHANNEL=reports
expect "a channel with no setting at all (other)" default BRIEFING_CHANNEL=other
expect "a channel whose setting is empty (unset-one)" default BRIEFING_CHANNEL=unset-one
expect "a channel whose file is missing (gone)" default BRIEFING_CHANNEL=gone
expect "a channel whose file is empty (empty)" default BRIEFING_CHANNEL=empty
expect "a channel whose file is only blanks (blank)" default BRIEFING_CHANNEL=blank
expect "a name that does not match (Reports)" default BRIEFING_CHANNEL=Reports
expect "a name that does not match (a/b)" default SALA_NOTIFY_CHANNEL=a/b
expect "the environment over the config line" ops BRIEFING_CHANNEL=reports BRIEFING_WEBHOOK_FILE_REPORTS="$T/wh-ops"
expect "BRIEFING_WEBHOOK_FILE in the environment is the default" ops BRIEFING_WEBHOOK_FILE="$T/wh-ops" BRIEFING_CHANNEL=gone
wh reports "$HOME/wh-r"   # a setting written with a leading ~ is the caller's home (here the test's)
expect "a leading ~ in the setting is the caller's home" reports BRIEFING_CHANNEL=reports BRIEFING_WEBHOOK_FILE_REPORTS='~/wh-r'
# the payload is post_slack's, whatever the channel
n=$(nreq); post BRIEFING_CHANNEL=reports -- 'plain post' >/dev/null
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if sorted(d)==["text","unfurl_links","unfurl_media"] and d["text"]=="plain post" else 1)' "$T/req.body.$((n + 1))" \
    && ok "a channel post has the same payload (text and the two unfurl flags)" || bad "payload: $(cat "$T/req.body.$((n + 1))")"

# post-stdin.sh (the notify command) behind `salamander alert --channel`: the whole path
e2e() { # e2e <label> <want path> [alert args…]
    local label=$1 want=$2 n; shift 2; n=$(nreq)
    SALA_NOTIFY_CMD=$D/post-stdin.sh SALA_LOG_DIR=$T/log bash "$ROOT/bin/salamander" alert "$@" >/dev/null 2>&1; rc=$?
    if [ $rc = 0 ] && [ "$(nreq)" = $((n + 1)) ] && [ "$(lastpath)" = "/$want" ]; then ok "$label: alert -> post-stdin.sh -> /$want"; else bad "$label: rc=$rc want /$want got $(lastpath) (requests $n -> $(nreq))"; fi
}
e2e "alert without a channel" default "Disk is full" "host one"
e2e "alert --channel reports" reports --channel reports "Disk is full" "host one"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["text"].startswith("⚠️ *Disk is full*") and "host one" in d["text"] else 1)' "$T/req.body.$(nreq)" \
    && ok "the channel post carries the alert's text" || bad "e2e text: $(cat "$T/req.body.$(nreq)")"
e2e "alert --channel=stack-ops" ops --channel=stack-ops "Disk is full"
e2e "alert --channel gone (its file is missing)" default --channel gone "Disk is full"
SALA_NOTIFY_CHANNEL=leak e2e "alert without a channel, one inherited" default "Disk is full"
n=$(nreq); SALA_NOTIFY_CMD=$D/post-stdin.sh SALA_LOG_DIR=$T/log bash "$ROOT/bin/salamander" alert --channel 'Bad Name' "x" >/dev/null 2>&1; rc=$?
[ $rc = 2 ] && [ "$(nreq)" = "$n" ] && ok "alert --channel 'Bad Name': exit 2 and no request reached any webhook" || bad "bad name end to end: rc=$rc requests $n -> $(nreq)"

# ------------------------------------------------------------------------------------------------ part 3: the jobs
# a stand-in checkout: the real scripts and lib.sh, release-watch.sh replaced by a stub (the real one probes the network)
mkdir -p "$T/real/contrib" "$T/real/lib"; cp -r "$D" "$T/real/contrib/briefing"; cp "$ROOT/lib/boardlinks.sh" "$T/real/lib/boardlinks.sh"
RB=$T/real/contrib/briefing
cat > "$RB/release-watch.sh" <<'EOF'
#!/bin/bash
echo "A new release is out"
[ -n "${STUB_FAIL-}" ] && { echo "probe failed" >&2; exit 1; }
exit 0
EOF
chmod +x "$RB/release-watch.sh"
# a fake `claude` that fails at once (the digest's own failure notice is the post), and a fetch that fails (summary-lean's)
printf '#!/bin/sh\nexit 1\n' > "$T/bin/claude"; chmod +x "$T/bin/claude"
printf '#!/bin/sh\necho "the portal was not reached" >&2\nexit 4\n' > "$T/bin/fetch"; chmod +x "$T/bin/fetch"
jobenv=(HOME="$T/home" BRIEFING_LOGDIR="$T/blog" BRIEFING_CLAUDE_BIN="$T/bin/claude" BRIEFING_LEAN_FETCH_CMD="$T/bin/fetch" BRIEFING_BACKEND=cli
        BRIEFING_HOLDS_CMD=true BRIEFING_LEAN_RETRY_WAIT=0 BRIEFING_GMAIL_CONNECTOR=demo BRIEFING_FORWARD_LABEL=forwarded)
job() { # job <label> <script> <want paths, space separated> [VAR=val …] -- [args]: runs a job and checks where each of its posts went, in order
    local label=$1 script=$2 want=$3 envs=() n got="" i p w=""; shift 3
    while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done; [ "${1:-}" = -- ] && shift
    n=$(nreq)
    env -u BRIEFING_CHANNEL -u SALA_NOTIFY_CHANNEL "${jobenv[@]}" ${envs[@]+"${envs[@]}"} "$RB/$script" "$@" >"$T/job.out" 2>&1; rc=$?
    for ((i = n + 1; i <= $(nreq); i++)); do got+="${got:+ }$(cat "$T/req.path.$i")"; done
    for p in $want; do w+="${w:+ }/$p"; done
    if [ "$got" = "$w" ]; then ok "$label: $w (exit $rc)"; else bad "$label: want [$w], got [$got] (exit $rc: $(head -c 300 "$T/job.out"))"; fi
}
job "release-alert.sh: the release post" release-alert.sh "reports" --
job "release-alert.sh: the post and then the probe-failure notice, both" release-alert.sh "reports reports" STUB_FAIL=1 --
job "release-alert.sh with BRIEFING_CHANNEL=stack-ops" release-alert.sh "ops" BRIEFING_CHANNEL=stack-ops --
job "summary-lean.sh --post: its failure notice" summary-lean.sh "reports" -- --post
job "summary-lean.sh --post with BRIEFING_CHANNEL=stack-ops" summary-lean.sh "ops" BRIEFING_CHANNEL=stack-ops -- --post
job "summary.sh: its failure notice" summary.sh "reports" --
job "summary.sh with BRIEFING_CHANNEL=stack-ops" summary.sh "ops" BRIEFING_CHANNEL=stack-ops --
job "defunct.sh: its failure notice" defunct.sh "reports" --
job "defunct.sh with BRIEFING_CHANNEL=stack-ops" defunct.sh "ops" BRIEFING_CHANNEL=stack-ops --
# reply.sh: a thread reply goes to the channel of the post it answers
n=$(nreq); out=$(env -u BRIEFING_CHANNEL -u SALA_NOTIFY_CHANNEL "${jobenv[@]}" "$RB/reply.sh" 1760000000.123456 'Done' 2>&1)
[ "$out" = ok ] && [ "$(nreq)" = $((n + 1)) ] && [ "$(lastpath)" = /reports ] && python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("thread_ts")=="1760000000.123456" else 1)' "$T/req.body.$(nreq)" \
    && ok "reply.sh: the thread reply goes to /reports, with its thread_ts" || bad "reply.sh: out=$out last=$(lastpath)"
n=$(nreq); out=$(env -u SALA_NOTIFY_CHANNEL "${jobenv[@]}" BRIEFING_CHANNEL=stack-ops "$RB/reply.sh" 1760000000.123456 'Done' 2>&1)
[ "$out" = ok ] && [ "$(lastpath)" = /ops ] && ok "reply.sh with BRIEFING_CHANNEL=stack-ops: the reply follows it" || bad "reply.sh override: out=$out last=$(lastpath)"
# the reports channel's setting unset: every job falls back to the default webhook, so no post is lost while the webhook is missing
printf 'BRIEFING_WEBHOOK_FILE=%s\n' "$T/wh-default" > "$T/config-noreports"
job "release-alert.sh, reports has no webhook yet: the default one" release-alert.sh "default" SALA_CONFIG="$T/config-noreports" --
job "summary-lean.sh --post, reports has no webhook yet: the default one" summary-lean.sh "default" SALA_CONFIG="$T/config-noreports" -- --post
exit $fail
