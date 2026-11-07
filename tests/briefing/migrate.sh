#!/usr/bin/env bash
# the run logs live in a state directory (logs are state, XDG; BRIEFING_LOGDIR). lib.sh's migrate_old_logdir carries the files
# of an older directory (BRIEFING_OLD_LOGDIR) over on the first run: plain files only, mv -n (nothing overwritten), a name in both
# stays in the old directory and is named on one cron.log line, the old directory goes once empty, and a second run changes
# nothing. Everything runs in temp directories; the real ~/.cache and ~/.local are never named.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd); D=$ROOT/contrib/briefing
fail=0; ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fail=1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
OLD=$T/old; NEW=$T/new
snap() { (cd "$T" && { find old new -printf '%p %y %l\n'; find old new -type f -exec cksum {} +; } | sort); }
run() { env -u BRIEFING_LOGDIR -u BRIEFING_OLD_LOGDIR HOME="$T/home" BRIEFING_LOGDIR="$NEW" BRIEFING_OLD_LOGDIR="$OLD" bash -c '. "$1/lib.sh" 2>/dev/null; echo "alive"' _ "$D"; }

# setup: the old directory holds summary.jsonl (only there), cron.log (also in the new directory, other content), a lean/
# subdirectory with a file, and a symlink; the new directory already has cron.log
mkdir -p "$OLD/lean" "$NEW" "$T/home"
printf 'old summary\n' > "$OLD/summary.20261020.jsonl"
printf 'old cron line\n' > "$OLD/cron.log"
printf 'old lean digest\n' > "$OLD/lean/20261020.txt"
ln -s summary.20261020.jsonl "$OLD/latest"
printf 'new cron line\n' > "$NEW/cron.log"

out=$(run); [ "$out" = alive ] && ok "sourcing lib.sh with an old directory present does not exit the caller" || bad "first run: $out"
[ "$(cat "$NEW/summary.20261020.jsonl" 2>/dev/null)" = 'old summary' ] && [ ! -e "$OLD/summary.20261020.jsonl" ] && ok "a file only in the old directory is moved" || bad "summary not moved"
[ "$(cat "$NEW/lean/20261020.txt" 2>/dev/null)" = 'old lean digest' ] && [ ! -d "$OLD/lean" ] && ok "a subdirectory's file is moved and the emptied subdirectory removed" || bad "lean not moved"
grep -qxF 'new cron line' "$NEW/cron.log" && ! grep -qF 'old cron line' "$NEW/cron.log" && ok "a name in both: the new file is not overwritten and the old content is not mixed in" || bad "cron.log changed: $(cat "$NEW/cron.log")"
[ "$(cat "$OLD/cron.log" 2>/dev/null)" = 'old cron line' ] && ok "a name in both: the old file stays where it was" || bad "old cron.log gone"
[ -L "$OLD/latest" ] && [ ! -e "$NEW/latest" ] && ok "a symlink is left alone" || bad "symlink handled"
[ -d "$OLD" ] && ok "the old directory stays while something is left in it" || bad "old directory removed with files left"
line=$(grep 'migrated' "$NEW/cron.log"); case $line in *'migrated 2 log file(s)'*'left in the old directory: '*cron.log*latest*|*'migrated 2 log file(s)'*'left in the old directory: '*latest*cron.log*) ok "one cron.log line counts the moved files and names what stayed";; *) bad "cron.log line: ${line:-none}";; esac
[ "$(grep -c migrated "$NEW/cron.log")" = 1 ] && ok "exactly one migration line" || bad "migration lines: $(grep -c migrated "$NEW/cron.log")"

a=$(snap); run >/dev/null; b=$(snap); run >/dev/null; c=$(snap)
[ "$a" = "$b" ] && [ "$b" = "$c" ] && ok "running it again (twice) changes nothing" || bad "a second run changed the files: $(diff <(printf '%s\n' "$a") <(printf '%s\n' "$b"))"

# when nothing collides and nothing odd is left, the old directory is removed and the files are in the new one
rm -rf "$T/o2" "$T/n2"; mkdir -p "$T/o2/lean"; printf 'a\n' > "$T/o2/a.jsonl"; printf 'b\n' > "$T/o2/lean/b.txt"
env HOME="$T/home" BRIEFING_LOGDIR="$T/n2" BRIEFING_OLD_LOGDIR="$T/o2" bash -c '. "$1/lib.sh" 2>/dev/null' _ "$D"
[ ! -e "$T/o2" ] && [ "$(cat "$T/n2/a.jsonl")" = a ] && [ "$(cat "$T/n2/lean/b.txt")" = b ] && ok "a clean carry-over moves everything and removes the old directory" || bad "clean case: $(ls -R "$T/o2" "$T/n2" 2>&1 | head)"

# a repointed LOGDIR with no old directory named never migrates (a test must not touch the real ~/.cache)
mkdir -p "$T/fake-cache"; printf 'x\n' > "$T/fake-cache/x.jsonl"
env -u BRIEFING_OLD_LOGDIR HOME="$T/home" BRIEFING_LOGDIR="$T/n3" bash -c '. "$1/lib.sh" 2>/dev/null; echo "old=[$OLD_LOGDIR]"' _ "$D" | grep -qxF 'old=[]' && ok "BRIEFING_LOGDIR set without BRIEFING_OLD_LOGDIR: no old directory is read" || bad "OLD_LOGDIR not empty under a repointed LOGDIR"
# the defaults: state, not cache, under a neutral name; no old directory unless one is named
out=$(env -u BRIEFING_LOGDIR -u BRIEFING_OLD_LOGDIR -u BRIEFING_WEBHOOK_FILE -u XDG_STATE_HOME HOME="$T/h4" SALA_CONFIG="$T/none" bash -c '. "$1/lib.sh" 2>/dev/null; echo "$LOGDIR|$OLD_LOGDIR|$WEBHOOK_FILE"' _ "$D")
[ "$out" = "$T/h4/.local/state/sala-briefing||$T/h4/.config/sala-briefing/slack-webhook" ] && ok "no setting: logs in ~/.local/state/sala-briefing, no old directory, the webhook file in ~/.config/sala-briefing" || bad "defaults: $out"
# the sala config's lines (made-up paths): the log directory, the old one it carries over, the webhook file; ~ is the home
mkdir -p "$T/h5/old-logs"; printf 'x\n' > "$T/h5/old-logs/x.jsonl"
printf 'BRIEFING_LOGDIR=~/demo-logs\nBRIEFING_OLD_LOGDIR="$HOME/old-logs"   # carried over\nBRIEFING_WEBHOOK_FILE=~/demo-hook\n' > "$T/h5.config"
out=$(env -u BRIEFING_LOGDIR -u BRIEFING_OLD_LOGDIR -u BRIEFING_WEBHOOK_FILE HOME="$T/h5" SALA_CONFIG="$T/h5.config" bash -c '. "$1/lib.sh" 2>/dev/null; migrate_old_logdir; echo "$LOGDIR|$OLD_LOGDIR|$WEBHOOK_FILE"' _ "$D")
[ "$out" = "$T/h5/demo-logs|$T/h5/old-logs|$T/h5/demo-hook" ] && [ "$(cat "$T/h5/demo-logs/x.jsonl" 2>/dev/null)" = x ] && ok "the sala config's BRIEFING_LOGDIR, BRIEFING_OLD_LOGDIR and BRIEFING_WEBHOOK_FILE lines are read, and the old directory carried over" || bad "config: $out"
# the units name no log path: BRIEFING_CRON_LOG=1 appends the script's own output to cron.log in its log directory, and a child does not inherit it
out=$(env -u BRIEFING_OLD_LOGDIR HOME="$T/h6" BRIEFING_LOGDIR="$T/h6/logs" BRIEFING_CRON_LOG=1 bash -c '. "$1/lib.sh"; echo "to the log"; echo "child=[$(printenv BRIEFING_CRON_LOG)]"' _ "$D")
[ -z "$out" ] && grep -qx 'to the log' "$T/h6/logs/cron.log" && grep -qx 'child=\[\]' "$T/h6/logs/cron.log" && ok "BRIEFING_CRON_LOG=1: the output goes to cron.log in the log directory; a child does not get it" || bad "cron log: out=$out log=$(cat "$T/h6/logs/cron.log" 2>/dev/null)"
! grep -q '^Standard\(Output\|Error\)=' "$D"/systemd/sala-briefing-*.service && grep -q '^Environment=BRIEFING_CRON_LOG=1$' "$D"/systemd/sala-briefing-*.service && ok "the units append through BRIEFING_CRON_LOG, naming no directory" || bad "unit paths"
exit $fail
