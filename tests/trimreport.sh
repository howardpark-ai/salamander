#!/usr/bin/env bash
# .github/scripts/trim_report.py, the weekly size report of the suites (CONTRIBUTING.md, *Keeping the suites trim*). A report that
# counts wrong or never says TRIGGER lets the suites grow with nobody looking, and a state file that breaks stops the weekly
# comparison, so this checks the script on throwaway trees:
#   the counts on a tiny made-up tree with both families (the shell suites' `ok` lines and the web files' `assert` lines; a comment,
#   the `ok()` definition, a `bad`-only line, an `echo "ok"`, a tool such as lib.sh and conftest.py are not counted; two ok calls on
#   one line count once), a recorded time and an untimed suite, a time that is negative or above a year ignored with a note,
#   a key in the timings whose file is gone ignored;
#   since a prior state: suites and files added and deleted by name, test lines added and deleted;
#   each threshold's TRIGGER line (and none under the limits, the state file keeping the lines), the growth scaled to a week,
#   a [salamander] table overriding the top-level keys, the config and state files at their XDG default places;
#   an unknown config key (a warning, exit 0), every bad config exiting 2 (a value of the wrong type, a boolean, a negative one, not
#   TOML, not UTF-8, a folder, a missing --config file, a pipe, /dev/stdin), a state folder that cannot be made (exit 1),
#   a corrupt or foreign previous state started over with a note, --dry-run writing nothing, no leftover temporary file, a checkout
#   with no suite (exit 2);
#   --fresh-timings (a stand-in gh on PATH): the queue runs' medians over the committed numbers, neither timings file nor anything else
#   written in the checkout, and every way of getting no numbers failing (exit 1) with no record kept;
#   on_trigger (a stand-in command): what it reads, when it runs and when not, a command that does not take the triggers (exit 3) and
#   the triggers owed to the next run until one is taken, bad values exit 2;
#   then this checkout: its tests/timings.json and web/tests/timings.json parse, and the suites counted are the ones
#   `tests/run.sh --list` names.
# No network, no tmux; no process but the script itself, the stand-ins (and run.sh --list).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
SCRIPT="$ROOT/.github/scripts/trim_report.py"
T=$(mktemp -d "${TMPDIR:-/tmp}/sala-trimreport.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
exec 8< "$T"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
export HOME="$T/home"; mkdir -p "$HOME"
unset XDG_CONFIG_HOME XDG_STATE_HOME

rc=0
rp() {  # <args…> → the script's stdout in $T/out, stderr in $T/err, its exit status in rc
    rc=0; timeout 60 python3 -I "$SCRIPT" "$@" >"$T/out" 2>"$T/err" || rc=$?
}
has() { grep -qF -- "$1" "$T/out"; }          # a literal line part in the report
js() {  # <json file> <python expression over d> → its value
    python3 -I - "$1" "$2" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
v = eval(sys.argv[2]); print(" ".join(map(str, v)) if isinstance(v, tuple) else v)
EOF
}
timings() {  # <file> then key=seconds… → a timings file
    local f="$1"; shift
    python3 -I - "$f" "$@" <<'EOF'
import json, sys
json.dump({"version": 1, "unit": "seconds", "timings": {k: float(v) for k, v in (a.split("=", 1) for a in sys.argv[2:])}}, open(sys.argv[1], "w"))
EOF
}

# --- a tree: tests/a.sh (4 ok lines), tests/b.sh (2), tools lib/run/suitemap/count-procs (not suites), web/tests/test_w.py (2 asserts)
mktree() {  # <tree>
    local t="$1"; mkdir -p "$t/tests" "$t/web/tests"
    cat > "$t/tests/a.sh" <<'EOF'
#!/usr/bin/env bash
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; }
# ok "a comment is not a check"
ok "first: at the start of the line"
  [ 1 = 1 ] && ok "second: behind a test" || bad "second"
if true; then ok "third: after then"; else bad "third"; fi
bad "only a bad call"
echo "all ok"
x=ok
ok "fourth" && ok "and a fifth on the same line, one count"
EOF
    printf '%s\n' 'ok "b1"' '[ 2 = 2 ] && ok "b2" || bad "b2"' > "$t/tests/b.sh"
    local tool; for tool in lib run suitemap count-procs; do printf '%s\n' 'ok "a tool is no suite"' 'ok "again"' 'ok "and again"' > "$t/tests/$tool.sh"; done
    cat > "$t/web/tests/test_w.py" <<'EOF'
def test_a():
    assert 1 == 1
    assert (2)
    # assert not_counted
    foo(); assert 3
    assert_helper(1)
EOF
    printf '%s\n' 'assert True' 'assert True' > "$t/web/tests/conftest.py"
    timings "$t/tests/timings.json" tests/a.sh=120 tests/gone.sh=5
    timings "$t/web/tests/timings.json" tests/test_w.py=60
}

echo "== counts: both families, a time and an untimed suite"
A="$T/a"; mktree "$A"
rp --root "$A" --state-dir "$T/sa" --json --now 2026-01-05T09:00:00+00:00
[ "$rc" = 0 ] && ok "exit 0" || bad "rc=$rc: $(cat "$T/err")"
cp "$T/out" "$T/a.json"
[ "$(js "$T/a.json" "d['families']['shell']['suites'], d['families']['web']['suites'], d['suite_count']")" = "2 1 3" ] \
    && ok "2 shell suites, 1 web file, 3 together (the four tools and conftest.py are not suites)" || bad "suite counts: $(js "$T/a.json" "d['families']")"
[ "$(js "$T/a.json" "d['suites']['tests/a.sh'], d['suites']['tests/b.sh'], d['suites']['web/tests/test_w.py'], d['test_lines']")" = "4 2 2 8" ] \
    && ok "a.sh 4 ok lines, b.sh 2, test_w.py 2 asserts; 8 together (comment, ok(), bad-only, echo, x=ok, tools not counted; two ok calls on a line count once)" \
    || bad "test lines: $(js "$T/a.json" "d['suites']")"
[ "$(js "$T/a.json" "d['serial_minutes'], d['untimed'], d['families']['shell']['minutes'], d['families']['web']['minutes']")" = "3.0 1 2.0 1.0" ] \
    && ok "serial minutes 3.0 (120 s + 60 s), 1 untimed suite (b.sh); the gone key tests/gone.sh is ignored" || bad "minutes: $(js "$T/a.json" "d['serial_minutes'], d['untimed']")"
[ "$(js "$T/a.json" "[n for n, m in d['slowest']]")" = "['tests/a.sh', 'web/tests/test_w.py']" ] && ok "slowest first: a.sh, then the web file (keys are repo paths)" || bad "slowest: $(js "$T/a.json" "d['slowest']")"
rp --root "$A" --dry-run
has "suites: 3 (shell 2, web 1)" && has "test lines: 8 (shell 6 ok lines, web 2 assert lines)" && has "serial minutes: 3.0" && has "2 of 3 timed, 1 untimed" \
    && ok "the text report: both families and the sum" || bad "text: $(cat "$T/out")"
[ "$(grep -c '^TRIGGER' "$T/out")" = 0 ] && ok "no TRIGGER under the placeholder defaults" || bad "a TRIGGER with no config"

echo "== a time that is negative, not finite or above a year is ignored, with its key named"
B="$T/b"; mktree "$B"
printf '%s' '{"timings": {"tests/a.sh": -5, "tests/b.sh": 99999999999, "tests/gone.sh": -1}}' > "$B/tests/timings.json"
rp --root "$B" --dry-run
[ "$rc" = 0 ] && grep -q '^note: shell suite times ignored .*: tests/a.sh, tests/b.sh$' "$T/out" && has "1 of 3 timed, 2 untimed" \
    && ok "a.sh (negative) and b.sh (above a year) counted as untimed with a note; tests/gone.sh is not named" || bad "bad times: rc=$rc $(cat "$T/out")"
printf '%s' '{"timings": {"tests/a.sh": NaN, "tests/b.sh": true}}' > "$B/tests/timings.json"
rp --root "$B" --dry-run
[ "$rc" = 0 ] && grep -q 'ignored.*: tests/a.sh, tests/b.sh' "$T/out" && ok "NaN and a boolean are ignored too" || bad "nan: rc=$rc $(cat "$T/out")"
printf '%s' 'not json' > "$B/tests/timings.json"
rp --root "$B" --dry-run
[ "$rc" = 0 ] && grep -q '^note: no shell suite times: ' "$T/out" && has "1 of 3 timed, 2 untimed" && ok "an unreadable timings file: a note, that family untimed, the other family still timed" || bad "unreadable: rc=$rc $(cat "$T/out")"
rm -f "$B/tests/timings.json" "$B/web/tests/timings.json"
rp --root "$B" --dry-run
[ "$rc" = 0 ] && has "serial minutes: n/a" && has "slowest suites: n/a" && ok "no timings file at all: minutes n/a" || bad "no timings: rc=$rc $(cat "$T/out")"
rm -rf "$B/web"
rp --root "$B" --dry-run
[ "$rc" = 0 ] && has "suites: 2 (shell 2, web 0)" && ok "a checkout with no web/ is measured: 0 web files" || bad "no web: rc=$rc $(cat "$T/out")"

echo "== a state file is written, atomically, and nothing else is left in its folder"
[ -f "$T/sa/state.json" ] && [ "$(ls -A "$T/sa" | wc -l)" = 1 ] && ok "state.json, no temporary or probe file beside it" || bad "state folder: $(ls -A "$T/sa")"
[ "$(js "$T/sa/state.json" "d['format'], d['generated'], d['test_lines']")" = "1 2026-01-05T09:00:00+00:00 8" ] && ok "the record is the first run's" || bad "state: $(cat "$T/sa/state.json")"

echo "== since the prior state: added, deleted, test lines up and down"
rm "$A/tests/b.sh"; printf '%s\n' 'ok "c1"' 'ok "c2"' 'ok "c3"' > "$A/tests/c.sh"; echo 'ok "a6"' >> "$A/tests/a.sh"
printf '%s\n' 'assert 1' 'assert 2' 'assert 3' 'assert 4' > "$A/web/tests/test_x.py"
rp --root "$A" --dry-run --state-dir "$T/sa" --now 2026-01-12T09:00:00+00:00
[ "$rc" = 0 ] && has "since the previous run (7.0 days ago): 2 suites added, 1 deleted; 8 test lines added, 2 deleted (net +6)" \
    && has "  added: tests/c.sh, web/tests/test_x.py" && has "  deleted: tests/b.sh" && ok "added: c.sh and test_x.py; deleted: b.sh; +8 -2 lines (a.sh +1, c.sh +3, test_x.py +4; b.sh -2)" || bad "since: rc=$rc $(cat "$T/out")"
rp --root "$A" --dry-run --json --state-dir "$T/sa" --now 2026-01-12T09:00:00+00:00
cp "$T/out" "$T/a2.json"
[ "$(js "$T/a2.json" "d['per_suite_change']")" = "{'tests/a.sh': 1, 'tests/b.sh': -2, 'tests/c.sh': 3, 'web/tests/test_x.py': 4}" ] && ok "the rise or fall per suite is in the record" || bad "per suite: $(js "$T/a2.json" "d['per_suite_change']")"

echo "== thresholds: each TRIGGER line, none under the limits"
cat > "$T/low.toml" <<'EOF'
max_suites = 1
max_serial_minutes = 1
max_suite_minutes = 1
max_test_line_growth = 0
EOF
rp --root "$A" --dry-run --state-dir "$T/sa" --now 2026-01-12T09:00:00+00:00 --config "$T/low.toml"
[ "$rc" = 0 ] && ok "exit 0 with triggers" || bad "rc=$rc"
for k in max_suites max_serial_minutes max_suite_minutes max_test_line_growth; do
    [ "$(grep -c "^TRIGGER: $k: " "$T/out")" = 1 ] && ok "TRIGGER: $k" || bad "no single TRIGGER: $k line: $(cat "$T/out")"
done
[ "$(grep -c '^TRIGGER' "$T/out")" = 4 ] && [ "$(grep '^TRIGGER' "$T/out" | cut -d: -f2 | paste -sd' ')" = " max_suites  max_serial_minutes  max_suite_minutes  max_test_line_growth" ] \
    && ok "four lines, in the order of the keys" || bad "order: $(grep '^TRIGGER' "$T/out")"
grep -q '^TRIGGER: max_suite_minutes: tests/a.sh takes 2.0 min (1 over) > 1$' "$T/out" && ok "the slowest suite is named, with how many are over" || bad "slowest not named: $(grep '^TRIGGER: max_suite' "$T/out")"
has "Follow-up: a scan for duplicate or obsolete suites" && ok "the follow-up line closes a triggered report" || bad "no follow-up line"
cat > "$T/high.toml" <<'EOF'
max_suites = 1000
max_serial_minutes = 1000
max_suite_minutes = 1000
max_test_line_growth = 1000
EOF
rp --root "$A" --dry-run --state-dir "$T/sa" --now 2026-01-12T09:00:00+00:00 --config "$T/high.toml"
[ "$rc" = 0 ] && [ "$(grep -c 'TRIGGER\|Follow-up' "$T/out")" = 0 ] && ok "under the limits: no TRIGGER, no follow-up" || bad "under limits: $(cat "$T/out")"
# 4 suites now (a, c, test_w, test_x): a limit of 4 is not exceeded, a limit of 3 is
printf 'max_suites = 4\n' > "$T/eq.toml"
rp --root "$A" --dry-run --state-dir "$T/sa" --now 2026-01-12T09:00:00+00:00 --config "$T/eq.toml"
[ "$(grep -c '^TRIGGER' "$T/out")" = 0 ] && ok "4 suites, limit 4: no trigger (above, not at)" || bad "at the limit: $(cat "$T/out")"
printf 'max_suites = 3\n' > "$T/eq.toml"
rp --root "$A" --dry-run --state-dir "$T/sa" --now 2026-01-12T09:00:00+00:00 --config "$T/eq.toml"
[ "$(grep -c '^TRIGGER: max_suites' "$T/out")" = 1 ] && ok "4 suites, limit 3: trigger" || bad "above the limit: $(cat "$T/out")"
echo "-- growth is scaled to a week when the gap is longer: +6 lines over 14 days is 3 a week"
printf 'max_test_line_growth = 4\n' > "$T/g.toml"
rp --root "$A" --dry-run --state-dir "$T/sa" --now 2026-01-19T09:00:00+00:00 --config "$T/g.toml"
[ "$(grep -c '^TRIGGER' "$T/out")" = 0 ] && ok "14 days, +6: 3 a week, limit 4: no trigger" || bad "scaled: $(cat "$T/out")"
printf 'max_test_line_growth = 2\n' > "$T/g.toml"
rp --root "$A" --dry-run --state-dir "$T/sa" --now 2026-01-19T09:00:00+00:00 --config "$T/g.toml"
[ "$(grep -c '^TRIGGER: max_test_line_growth: +3 test lines per week > 2$' "$T/out")" = 1 ] && ok "14 days, +6: 3 a week, limit 2: trigger" || bad "scaled: $(cat "$T/out")"
printf 'max_test_line_growth = 4\n' > "$T/g.toml"
rp --root "$A" --dry-run --state-dir "$T/sa" --now 2026-01-09T09:00:00+00:00 --config "$T/g.toml"
[ "$(grep -c '^TRIGGER: max_test_line_growth' "$T/out")" = 1 ] && ok "4 days, +6: not scaled up (a gap under a week counts as it is), trigger" || bad "short gap: $(cat "$T/out")"
printf 'max_test_line_growth = 0\n' > "$T/g.toml"
rp --root "$A" --dry-run --state-dir "$T/T-none" --now 2026-01-19T09:00:00+00:00 --config "$T/g.toml"
[ "$(grep -c '^TRIGGER' "$T/out")" = 0 ] && ok "no prior state: no growth to judge, no trigger" || bad "baseline: $(cat "$T/out")"
echo "-- the state file keeps the TRIGGER lines"
cp -r "$T/sa" "$T/sb"
rp --root "$A" --state-dir "$T/sb" --json --now 2026-01-12T09:00:00+00:00 --config "$T/low.toml"
[ "$rc" = 0 ] && [ "$(js "$T/sb/state.json" "len(d['triggers'])")" = 4 ] && [ "$(js "$T/sb/state.json" "[t['key'] for t in d['triggers']][0]")" = max_suites ] \
    && ok "state.json holds the four trigger records" || bad "state triggers: rc=$rc $(js "$T/sb/state.json" "d['triggers']")"
echo "-- a [salamander] table overrides the top-level keys"
cat > "$T/tab.toml" <<'EOF'
max_suites = 1
max_suite_minutes = 1

[salamander]
max_suites = 1000

[other]
max_suites = 1
EOF
rp --root "$A" --dry-run --state-dir "$T/sa" --now 2026-01-12T09:00:00+00:00 --config "$T/tab.toml"
[ "$rc" = 0 ] && [ "$(grep -c '^TRIGGER: max_suites' "$T/out")" = 0 ] && [ "$(grep -c '^TRIGGER: max_suite_minutes' "$T/out")" = 1 ] && ok "[salamander] max_suites 1000 beats the top-level 1; the top-level max_suite_minutes still applies; [other] is not ours" || bad "table: rc=$rc $(cat "$T/out")"

echo "== the default places follow XDG"
mkdir -p "$T/xc/salamander"; cp "$T/low.toml" "$T/xc/salamander/test-trim.toml"
XDG_CONFIG_HOME="$T/xc" XDG_STATE_HOME="$T/xs" rp --root "$A" --now 2026-01-12T09:00:00+00:00
[ "$rc" = 0 ] && [ "$(grep -c '^TRIGGER' "$T/out")" = 3 ] && [ -f "$T/xs/salamander/test-trim/state.json" ] \
    && ok "the config is read from \$XDG_CONFIG_HOME/salamander/test-trim.toml and the state written to \$XDG_STATE_HOME/salamander/test-trim/state.json (baseline run: three triggers, no growth)" || bad "xdg: rc=$rc $(cat "$T/out" "$T/err"); $(find "$T/xs" 2>&1)"
rp --root "$A" --dry-run
[ "$rc" = 0 ] && [ "$(grep -c '^TRIGGER' "$T/out")" = 0 ] && [ ! -e "$HOME/.local/state" ] && ok "with no XDG variable and no config: placeholders, and --dry-run made nothing under \$HOME" || bad "home default: rc=$rc $(cat "$T/out"); $(find "$HOME" 2>&1)"

echo "== an unknown config key is a warning"
printf 'max_suite = 3\nmax_suites = 1000\n[salamander]\nmax_serial_minute = 3\n' > "$T/unk.toml"
rp --root "$A" --dry-run --config "$T/unk.toml"
[ "$rc" = 0 ] && grep -qxF "warning: unknown key max_suite in $T/unk.toml" "$T/err" && grep -qF "warning: unknown key max_serial_minute in $T/unk.toml" "$T/err" && [ "$(grep -c '^TRIGGER' "$T/out")" = 0 ] \
    && ok "a mistyped key is named on stderr, top-level and in [salamander]; exit 0, the key is not used" || bad "unknown: rc=$rc $(cat "$T/err")"

echo "== a bad config is exit 2 and no report"
badcfg() {  # <label> <config path>
    rp --root "$A" --dry-run --config "$2"
    [ "$rc" = 2 ] && [ ! -s "$T/out" ] && grep -q '^trim_report: ' "$T/err" && ok "$1: exit 2, a line on stderr, no report" || bad "$1: rc=$rc out=$(head -c 200 "$T/out") err=$(cat "$T/err")"
}
printf 'max_suites = "ten"\n' > "$T/c1.toml"; badcfg "a string value" "$T/c1.toml"
printf 'max_suites = true\n' > "$T/c2.toml"; badcfg "a boolean value" "$T/c2.toml"
printf 'max_suite_minutes = -3\n' > "$T/c3.toml"; badcfg "a negative value" "$T/c3.toml"
printf '[salamander]\nmax_serial_minutes = [1]\n' > "$T/c4.toml"; badcfg "a list in the [salamander] table" "$T/c4.toml"
printf 'max_suites = nan\n' > "$T/c5.toml"; badcfg "nan" "$T/c5.toml"
printf 'max_suites = 1e30\n' > "$T/c6.toml"; badcfg "a value above 10**12" "$T/c6.toml"
printf 'this is [not toml\n' > "$T/c7.toml"; badcfg "not TOML" "$T/c7.toml"
printf 'max_suites = 1 # \xff\xfe\n' > "$T/c8.toml"; badcfg "not UTF-8" "$T/c8.toml"
mkdir "$T/c9.d"; badcfg "a folder" "$T/c9.d"
badcfg "a --config file that does not exist" "$T/none.toml"
mkfifo "$T/c10.fifo"; badcfg "a pipe (no writer)" "$T/c10.fifo"
printf 'max_suites = 5\n' | timeout 60 python3 -I "$SCRIPT" --root "$A" --dry-run --config /dev/stdin >"$T/out" 2>"$T/err"; prc=${PIPESTATUS[1]}
[ "$prc" = 2 ] && grep -q 'pipe' "$T/err" && ok "--config /dev/stdin from a pipe: exit 2, a pipe is not a file" || bad "stdin pipe: rc=$prc $(cat "$T/err")"
printf 'max_suites = 5\n' > "$T/c11.toml"
rp --root "$A" --dry-run --config /dev/stdin < "$T/c11.toml"
[ "$rc" = 0 ] && ok "… while /dev/stdin redirected from a regular file is that file" || bad "stdin file: rc=$rc $(cat "$T/err")"
rp --root "$A" --dry-run --config /dev/null
[ "$rc" = 0 ] && [ "$(grep -c '^TRIGGER' "$T/out")" = 0 ] && ok "/dev/null is an empty config" || bad "devnull: rc=$rc $(cat "$T/err")"

echo "== a state folder that cannot be written is exit 1"
: > "$T/afile"
rp --root "$A" --state-dir "$T/afile/sub"
[ "$rc" = 1 ] && grep -q 'cannot write the state folder' "$T/err" && [ ! -s "$T/out" ] && ok "a state folder under a plain file: exit 1, nothing reported as kept" || bad "unwritable: rc=$rc $(cat "$T/err")"
rp --root "$A" --dry-run --state-dir "$T/afile/sub"
[ "$rc" = 0 ] && ok "… but --dry-run writes nothing and so does not mind" || bad "dry unwritable: rc=$rc $(cat "$T/err")"
mkdir "$T/blocked"; mkdir "$T/blocked/state.json"
rp --root "$A" --state-dir "$T/blocked"
[ "$rc" = 1 ] && grep -q 'cannot write' "$T/err" && [ "$(ls -A "$T/blocked" | wc -l)" = 1 ] && ok "a state file that cannot be replaced: exit 1, no temporary file left behind" || bad "blocked: rc=$rc $(cat "$T/err"); $(ls -A "$T/blocked")"

echo "== a previous record that cannot be used is started over"
mkdir "$T/sc"
for case in "not json at all" '{"format": 2}' '{"format":1,"suites":{"x":-3},"test_lines":0,"generated":"2026-01-05T09:00:00+00:00"}' \
            '{"format":1,"suites":{"x":1},"test_lines":1,"generated":"2026-01-05T09:00:00"}' '{"format":1,"suites":[],"test_lines":0,"generated":"2026-01-05T09:00:00+00:00"}' '[]'; do
    printf '%s' "$case" > "$T/sc/state.json"
    rp --root "$A" --state-dir "$T/sc" --now 2026-01-12T09:00:00+00:00
    [ "$rc" = 0 ] && [ "$(grep -c '^note: the previous record .*starting over$' "$T/out")" = 1 ] && has "this run is the baseline" && [ "$(js "$T/sc/state.json" "d['format'], d['test_lines']")" = "1 14" ] \
        && ok "started over from: $(printf '%s' "$case" | head -c 50)" || bad "corrupt '$case': rc=$rc $(cat "$T/out" "$T/err")"
done
rp --root "$A" --state-dir "$T/sc" --now 2026-01-13T09:00:00+00:00
[ "$rc" = 0 ] && has "since the previous run (1.0 days ago): 0 suites added, 0 deleted; 0 test lines added, 0 deleted (net +0)" && ok "the record written over a corrupt one is used by the next run" || bad "after start-over: $(cat "$T/out")"

echo "== --dry-run writes nothing"
sum=$(cksum < "$T/sa/state.json"); ls -A "$T/sa" > "$T/sa.ls"
rp --root "$A" --dry-run --state-dir "$T/sa" --now 2026-02-02T09:00:00+00:00
[ "$rc" = 0 ] && [ "$(cksum < "$T/sa/state.json")" = "$sum" ] && [ "$(ls -A "$T/sa")" = "$(cat "$T/sa.ls")" ] && ok "an existing state file is untouched" || bad "dry-run changed the state"
rp --root "$A" --dry-run --state-dir "$T/never/made"
[ "$rc" = 0 ] && [ ! -e "$T/never" ] && ok "a state folder that does not exist is not made" || bad "dry-run made $T/never"

echo "== a checkout with no suite is exit 2"
mkdir -p "$T/empty/tests"
rp --root "$T/empty" --dry-run
[ "$rc" = 2 ] && grep -q 'no tests/\*.sh suite' "$T/err" && ok "exit 2, with what to do" || bad "empty: rc=$rc $(cat "$T/err")"
rp --root "$T/does-not-exist" --dry-run
[ "$rc" = 2 ] && ok "a --root that is not there: exit 2" || bad "no root: rc=$rc"
rp --root "$A" --dry-run --now 2026-01-12T09:00:00
[ "$rc" = 2 ] && ok "--now without an offset: exit 2" || bad "now: rc=$rc"
rp --root "$A" --dry-run --nope
[ "$rc" = 2 ] && ok "an unknown flag: exit 2" || bad "flag: rc=$rc"

echo "== --fresh-timings: the queue runs' numbers over the committed ones (a stand-in gh on PATH, no network)"
F="$T/fresh"; mkdir -p "$F/.github/scripts" "$F/tests" "$F/web/tests"
cp "$SCRIPT" "$ROOT/.github/scripts/update_timings.py" "$ROOT/.github/scripts/deal.py" "$F/.github/scripts/"
for i in $(seq -w 1 22); do printf 'ok "x"\n' > "$F/tests/s$i.sh"; done
printf 'assert 1\n' > "$F/web/tests/test_one.py"; printf 'assert 1\n' > "$F/web/tests/test_two.py"
# committed: s01 is old (the logs replace it); s22 and test_two are in no log (they keep their number)
timings "$F/tests/timings.json" tests/s01.sh=1 tests/s22.sh=600
timings "$F/web/tests/timings.json" tests/test_one.py=1 tests/test_two.py=120
G="$T/gh"; mkdir -p "$G/bin" "$G/logs"
python3 -I - "$G/logs" <<'EOF'
import sys
def log(s01, web, n=21, with_web=True):
    L = [f"suites\tUNKNOWN STEP\t2026-01-04T11:50:{i:02d}.0000000Z ════ tests/s{i:02d}.sh (pass, {s01 if i == 1 else 60}s)" for i in range(1, n + 1)]
    if with_web:
        L += [f"web-shard (1)\tUNKNOWN STEP\t2026-01-04T12:00:00.0000000Z collected 4 items",
              f"web-shard (1)\tUNKNOWN STEP\t2026-01-04T12:{web // 60:02d}:{web % 60:02d}.0000000Z tests/test_one.py ....          [100%]"]
    return "\n".join(L) + "\n"
for name, text in (("101", log(120, 30)), ("102", log(240, 90)), ("few", log(9, 30, n=5)), ("noweb", log(120, 0, with_web=False))):
    open(f"{sys.argv[1]}/{name}", "w", encoding="utf-8").write(text)
EOF
cat > "$G/bin/gh" <<'EOF'
#!/usr/bin/env bash
# a stand-in for gh: `repo view` names o/r, `run list` answers with runs 101 and 102, `run view -R REPO ID --log` prints the saved log
# (the one $G/use names for every run, when it is there); $G/fail-list and $G/fail-repo make that call fail; every call is recorded.
G=$(dirname "$(dirname "$0")")
echo "$*" >> "$G/calls"
case "$1 $2" in
    "repo view") [ ! -e "$G/fail-repo" ] || { echo "no such repository" >&2; exit 1; }; echo o/r ;;
    "run list") [ ! -e "$G/fail-list" ] || { echo "HTTP 502 from the stand-in" >&2; exit 1; }
                echo '[{"databaseId":101,"event":"merge_group"},{"databaseId":102,"event":"merge_group"}]' ;;
    "run view") if [ -e "$G/use" ]; then cat "$G/logs/$(cat "$G/use")"; else cat "$G/logs/$5"; fi ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$G/bin/gh"
fr() {  # <args…> → rp for the copy of the script in the throwaway tree, run without -B, the stand-in gh first on PATH
    rc=0; PATH="$G/bin:$PATH" timeout 60 python3 -I "$F/.github/scripts/trim_report.py" --root "$F" --fresh-timings "$@" >"$T/out" 2>"$T/err" || rc=$?
}
tree_sum() { (cd "$F" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 cksum; find . | LC_ALL=C sort); }
before=$(tree_sum); : > "$G/calls"
fr --state-dir "$T/sf" --now 2026-01-05T09:00:00+00:00
[ "$rc" = 0 ] && has "serial minutes: 36.0 (shell 33.0, web 3.0; 24 of 24 timed)" \
    && ok "36.0 minutes: s01 the median 180 s of the two runs, s02 to s21 60 s, s22 and test_two keep the committed numbers, test_one the median 60 s" || bad "fresh: rc=$rc $(cat "$T/out" "$T/err")"
has "  1. tests/s22.sh  10.0 min" && has "  2. tests/s01.sh  3.0 min" && ok "the slowest list uses the fresh numbers" || bad "fresh slowest: $(cat "$T/out")"
has "timings: the median over the newest queue runs' logs (2 read: 2 show shell suites, 2 web test files), laid over the committed numbers" \
    && ok "the report says where the numbers came from" || bad "source line: $(cat "$T/out")"
[ "$(js "$T/sf/state.json" "d['timings_source']['runs'], d['timings_source']['suites_logs'], d['timings_source']['web_logs']")" = "['101', '102'] 2 2" ] \
    && ok "the record keeps the runs read" || bad "source record: $(js "$T/sf/state.json" "d.get('timings_source')")"
[ "$(tree_sum)" = "$before" ] && ok "nothing in the checkout changed or appeared (neither timings file, no __pycache__)" || bad "the checkout changed: $(diff <(echo "$before") <(tree_sum) | head -5)"
grep -q '^repo view ' "$G/calls" && grep -q -- '^run list -R o/r .*--event merge_group .*' "$G/calls" && grep -q -- '--limit 10 ' "$G/calls" \
    && ok "with no --github the repository is the one gh names; it asks for the last 10 merge_group runs" || bad "calls: $(cat "$G/calls")"
: > "$G/calls"; fr --dry-run --github other/name --state-dir "$T/sf"
[ "$rc" = 0 ] && ! grep -q '^repo view' "$G/calls" && grep -q '^run list -R other/name ' "$G/calls" && grep -q '^run view -R other/name 101 --log$' "$G/calls" \
    && ok "--github names the repository" || bad "--github: rc=$rc $(cat "$G/calls")"
: > "$G/calls"; PATH="$G/bin:$PATH" rp --root "$F" --dry-run
[ "$rc" = 0 ] && [ ! -s "$G/calls" ] && has "serial minutes: 12.0" && has "4 of 24 timed" && ! has "timings: " && ok "without --fresh-timings gh is not called and the committed numbers are the report's" || bad "committed: rc=$rc calls=$(cat "$G/calls") $(cat "$T/out")"
nofresh() {  # <label> <text the message holds> → a run that gets no numbers: exit 1, no report, the kept record untouched
    local was; was=$(cksum < "$T/sf/state.json")
    fr --state-dir "$T/sf" --now 2026-01-12T09:00:00+00:00
    [ "$rc" = 1 ] && [ ! -s "$T/out" ] && grep -q '^trim_report: no fresh timings: ' "$T/err" && grep -qF -- "$2" "$T/err" && [ "$(cksum < "$T/sf/state.json")" = "$was" ] \
        && ok "$1: exit 1, no report, the record untouched" || bad "$1: rc=$rc out=$(head -c 200 "$T/out") err=$(cat "$T/err")"
}
: > "$G/fail-list"; nofresh "gh cannot list the runs" "HTTP 502 from the stand-in"; rm "$G/fail-list"
: > "$G/fail-repo"; nofresh "gh cannot name the repository" "pass --github OWNER/NAME"; rm "$G/fail-repo"
echo few > "$G/use"; nofresh "logs with only 5 suites (under update_timings.py's minimum)" "shell suite"; rm "$G/use"
echo noweb > "$G/use"; nofresh "logs with no web time in a checkout that has web tests" "web test file"
mv "$F/web" "$T/web.aside"; fr --dry-run
[ "$rc" = 0 ] && has "suites: 22 (shell 22, web 0)" && ok "… while a checkout with no web tests needs none" || bad "no web, fresh: rc=$rc $(cat "$T/out" "$T/err")"
mv "$T/web.aside" "$F/web"; rm "$G/use"
mkdir "$T/nogh"; ln -s "$(command -v python3)" "$T/nogh/python3"; ln -s "$(command -v timeout)" "$T/nogh/timeout"
PATH="$T/nogh" rp --root "$F" --dry-run --fresh-timings --github o/r
[ "$rc" = 1 ] && grep -q '^trim_report: no fresh timings: ' "$T/err" && ok "no gh at all: exit 1" || bad "no gh: rc=$rc $(cat "$T/err")"
printf 'not json' > "$F/tests/timings.json"; fr --dry-run
[ "$rc" = 0 ] && grep -q "^note: no committed shell suite times, only the queue runs': " "$T/out" && has "23 of 24 timed, 1 untimed" \
    && ok "an unreadable committed file: a note, the runs' numbers alone (s22 untimed)" || bad "unreadable, fresh: rc=$rc $(cat "$T/out" "$T/err")"

echo "== on_trigger: a stand-in command"
H="$T/hook"; mkdir -p "$H"
cat > "$H/hook" <<'EOF'
#!/usr/bin/env bash
# a stand-in for an on_trigger command: keeps what it read and its arguments, exits as the file rc beside it says
H=$(dirname "$0")
cat > "$H/stdin"
echo "$*" >> "$H/ran"
rc=$(cat "$H/rc" 2>/dev/null || echo 0)
if [ "$rc" = 0 ]; then echo "filed one item"; echo "a second line"; else echo "the store refused it" >&2; fi
exit "$rc"
EOF
chmod +x "$H/hook"
HT="$T/h"; mktree "$HT"    # 3 suites, 3.0 serial minutes
hcfg() {  # <file> <max_suites> <max_serial_minutes> [command]
    printf 'max_suites = %s\nmax_serial_minutes = %s\nitem_project = "projects/example"\nitem_mover = "example-engineer"\non_trigger = ["%s", "an argument"]\n' \
        "$2" "$3" "${4:-$H/hook}" > "$1"
}
hcfg "$T/h-hit.toml" 1 1000; hcfg "$T/h-quiet.toml" 1000 1000; hcfg "$T/h-serial.toml" 1000 1
hr() {  # <state dir> <config> <day of January> [args…]
    local sd="$1" cfg="$2" day="$3"; shift 3
    rm -f "$H/ran" "$H/stdin"
    rp --root "$HT" --state-dir "$sd" --config "$cfg" --now "2026-01-${day}T09:00:00+00:00" "$@"
}
pend() { js "$1/state.json" "[t['key'] for t in d.get('open_pending', [])]"; }
sent() { js "$H/stdin" "[t['key'] for t in d['triggers']]"; }

hr "$T/s1" "$T/h-hit.toml" 05
[ "$rc" = 0 ] && [ "$(cat "$H/ran")" = "an argument" ] && ok "a trigger runs the command once, with its arguments; exit 0" || bad "hook: rc=$rc ran=$(cat "$H/ran" 2>&1) $(cat "$T/err")"
[ "$(js "$H/stdin" "sorted(d)")" = "['commit', 'generated', 'item_mover', 'item_project', 'repo', 'state_file', 'triggers']" ] \
    && [ "$(js "$H/stdin" "d['repo'], d['item_project'], d['item_mover'], d['generated'], d['state_file']")" = "salamander projects/example example-engineer 2026-01-05T09:00:00+00:00 $T/s1/state.json" ] \
    && ok "it reads repo, commit, generated, state_file, item_project, item_mover and triggers on stdin" || bad "payload: $(cat "$H/stdin")"
[ "$(js "$H/stdin" "sorted(d['triggers'][0]), d['triggers'][0]['key'], d['triggers'][0]['limit'], d['triggers'][0]['value']")" = "['key', 'limit', 'line', 'value'] max_suites 1 3" ] \
    && [ "$(js "$H/stdin" "d['triggers'][0]['line']")" = "TRIGGER: max_suites: 3 suites and web test files > 1" ] \
    && ok "each trigger carries its key, limit, value and the report's line" || bad "trigger: $(cat "$H/stdin")"
has "on_trigger: took 1 threshold(s)" && has "  filed one item" && has "  a second line" && ok "what the command prints follows the report" || bad "output: $(cat "$T/out")"
[ "$(js "$T/s1/state.json" "'open_pending' in d")" = False ] && [ "$(grep -c 'unknown key' "$T/err")" = 0 ] && ok "taken: nothing owed; the three keys are known (no warning)" || bad "taken: $(cat "$T/s1/state.json" "$T/err")"
hr "$T/s2" "$T/h-hit.toml" 05 --json
[ "$rc" = 0 ] && cp "$T/out" "$T/h.json" && [ "$(js "$T/h.json" "d['on_trigger_output'].splitlines()[0]")" = "on_trigger: took 1 threshold(s)" ] && ok "--json holds it as on_trigger_output" || bad "json: rc=$rc $(cat "$T/out")"
hr "$T/s3" "$T/h-hit.toml" 05 --dry-run
[ "$rc" = 0 ] && [ ! -e "$H/ran" ] && [ ! -e "$T/s3" ] && has "on_trigger: not run (--dry-run); 1 threshold(s) would go to: $H/hook an argument" \
    && ok "--dry-run runs no command and says what would go to it" || bad "dry-run hook: rc=$rc $(cat "$T/out")"
hr "$T/s3" "$T/h-quiet.toml" 05
[ "$rc" = 0 ] && [ ! -e "$H/ran" ] && ! has "on_trigger" && ok "no trigger: the command is not run" || bad "quiet hook: rc=$rc $(cat "$T/out")"

echo "-- a command that does not take the triggers: exit 3, owed until one does"
echo 7 > "$H/rc"
hr "$T/s4" "$T/h-hit.toml" 05
[ "$rc" = 3 ] && has "TRIGGER: max_suites" && grep -qxF "trim_report: on_trigger did not take the triggers: exit 7: the store refused it" "$T/err" \
    && ok "exit 3, the report printed, the command's own words on stderr" || bad "refused: rc=$rc $(cat "$T/out" "$T/err")"
[ "$(pend "$T/s4")" = "['max_suites']" ] && [ "$(js "$T/s4/state.json" "d['test_lines']")" = 8 ] && ok "the record is kept, with the trigger in open_pending" || bad "pending: $(cat "$T/s4/state.json")"
hr "$T/s4" "$T/h-quiet.toml" 12
[ "$rc" = 3 ] && [ "$(sent)" = "['max_suites']" ] && [ "$(pend "$T/s4")" = "['max_suites']" ] && [ "$(grep -c '^TRIGGER' "$T/out")" = 0 ] \
    && has "note: an earlier run's threshold is still owed to on_trigger (max_suites)" \
    && ok "the next run hands it over again with its numbers back under the limits, and it stays owed while refused" || bad "owed: rc=$rc $(cat "$T/out" "$T/err")"
printf 'max_suites = 1000\n' > "$T/h-none.toml"
hr "$T/s4" "$T/h-none.toml" 13
[ "$rc" = 0 ] && [ ! -e "$H/ran" ] && [ "$(pend "$T/s4")" = "['max_suites']" ] && has "(max_suites), and the thresholds file sets no on_trigger" \
    && ok "a config with no on_trigger keeps what is owed, with a note" || bad "no command: rc=$rc $(cat "$T/out") $(cat "$T/s4/state.json")"
rm "$H/rc"
hr "$T/s4" "$T/h-serial.toml" 19
[ "$rc" = 0 ] && [ "$(sent)" = "['max_suites', 'max_serial_minutes']" ] && [ "$(js "$T/s4/state.json" "'open_pending' in d")" = False ] \
    && ok "the owed trigger and the new one go together, in the order of the keys; taken, nothing is owed" || bad "merge: rc=$rc sent=$(cat "$H/stdin" 2>&1)"
hr "$T/s4" "$T/h-quiet.toml" 26
[ "$rc" = 0 ] && [ ! -e "$H/ran" ] && ok "once taken it is not sent again" || bad "sent again: $(cat "$H/stdin" 2>&1)"
echo 1 > "$H/rc"; hr "$T/s5" "$T/h-hit.toml" 05; rm "$H/rc"; echo 'ok "new"' > "$HT/tests/c.sh"
hr "$T/s5" "$T/h-hit.toml" 12
[ "$rc" = 0 ] && [ "$(js "$H/stdin" "len(d['triggers']), d['triggers'][0]['value']")" = "1 4" ] && ok "owed and current of one threshold: one trigger, the newer numbers" || bad "newer: rc=$rc $(cat "$H/stdin" 2>&1)"
rm "$HT/tests/c.sh"
mkdir -p "$T/s6"
printf '%s' '{"format":1,"suites":{},"test_lines":0,"generated":"2026-01-05T09:00:00+00:00","open_pending":[5,{"key":"nope","line":"TRIGGER: x"},{"key":"max_suites"},{"key":["a"],"line":"TRIGGER: y"},{"key":"max_suites","line":"other"}]}' > "$T/s6/state.json"
hr "$T/s6" "$T/h-quiet.toml" 12
[ "$rc" = 0 ] && [ ! -e "$H/ran" ] && ok "damaged open_pending entries are dropped, not sent" || bad "damaged pending: rc=$rc $(cat "$T/out" "$T/err")"

echo "-- how the command is named"
hcfg "$T/h-absent.toml" 1 1000 "$H/absent"
hr "$T/s7" "$T/h-absent.toml" 05
[ "$rc" = 3 ] && grep -q "did not take the triggers: cannot run $H/absent: " "$T/err" && [ "$(pend "$T/s7")" = "['max_suites']" ] && ok "a command that is not there: exit 3, owed" || bad "absent: rc=$rc $(cat "$T/err")"
mkdir -p "$HOME/hk"; cp "$H/hook" "$HOME/hk/hook"
hcfg "$T/h-tilde.toml" 1 1000 '~/hk/hook'
hr "$T/s8" "$T/h-tilde.toml" 05
[ "$rc" = 0 ] && [ -s "$HOME/hk/ran" ] && ok "a leading ~ is the home folder" || bad "tilde: rc=$rc $(cat "$T/err")"
printf 'max_suites = 1\non_trigger = ["%s/absent"]\n[salamander]\non_trigger = ["%s/hook"]\n' "$H" "$H" > "$T/h-table.toml"
hr "$T/s9" "$T/h-table.toml" 05
[ "$rc" = 0 ] && [ -s "$H/ran" ] && [ "$(js "$H/stdin" "[d['item_project'], d['item_mover']]")" = "['', '']" ] \
    && ok "the [salamander] table's command wins; item keys not set are sent empty" || bad "table: rc=$rc $(cat "$T/err")"
printf 'on_trigger = "a string"\n' > "$T/h1.toml"; badcfg "on_trigger as one string" "$T/h1.toml"
printf 'on_trigger = []\n' > "$T/h2.toml"; badcfg "an empty on_trigger" "$T/h2.toml"
printf 'on_trigger = ["a", 1]\n' > "$T/h3.toml"; badcfg "a number in on_trigger" "$T/h3.toml"
printf 'on_trigger = [""]\n' > "$T/h4.toml"; badcfg "an empty string in on_trigger" "$T/h4.toml"
printf 'on_trigger = ["a\\u0000b"]\n' > "$T/h5.toml"; badcfg "a NUL in on_trigger" "$T/h5.toml"
printf 'item_project = 3\n' > "$T/h6.toml"; badcfg "a number as item_project" "$T/h6.toml"
printf '[salamander]\nitem_mover = ["a"]\n' > "$T/h7.toml"; badcfg "a list as item_mover" "$T/h7.toml"
python3 -I - "$ROOT/.github/scripts" <<'EOF' && ok "a command that does not end in time is stopped: exit status 3" || bad "the hook time limit"
import sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1]); import trim_report
trim_report.HOOK_TIMEOUT = 1
try:
    trim_report.hand_over(["sleep", "30"], {})
except trim_report.Fail as e:
    sys.exit(0 if e.code == 3 and "within 1 seconds" in str(e) else 1)
sys.exit(1)
EOF

echo "== this checkout"
for f in tests/timings.json web/tests/timings.json; do
    [ -f "$ROOT/$f" ] || { ok "no $f here: its checks do not apply"; continue; }
    python3 -I - "$ROOT/.github/scripts" "$ROOT/$f" <<'EOF' && ok "$f parses: every kept time is a number of seconds" || bad "$f is not read by trim_report"
import sys
sys.path.insert(0, sys.argv[1]); import trim_report
secs, bad = trim_report.read_timings(sys.argv[2])
assert secs, "no timings"
EOF
done
rp --root "$ROOT" --dry-run --json
if [ "$rc" = 0 ]; then
    cp "$T/out" "$T/real.json"
    ok "a dry run over the real checkout: exit 0"
    [ "$(js "$T/real.json" "d['serial_minutes'] is not None and len(d['timed']) > 0")" = True ] && ok "the real times are read (serial minutes counted)" || bad "no real times: $(js "$T/real.json" "d['notes']")"
    [ "$(js "$T/real.json" "any(n.startswith(('no shell suite times', 'no web test file times')) for n in d['notes'])")" = False ] && ok "no note says a real timings file was unreadable" || bad "notes: $(js "$T/real.json" "d['notes']")"
    js "$T/real.json" "' '.join(sorted(n[len('tests/'):-len('.sh')] for n in d['suites'] if n.endswith('.sh')))" > "$T/real.suites"
    tr ' ' '\n' < <(bash "$ROOT/tests/run.sh" --list) | LC_ALL=C sort | paste -sd" " > "$T/run.suites"
    [ "$(cat "$T/real.suites")" = "$(cat "$T/run.suites")" ] && ok "the shell suites counted are the ones tests/run.sh --list names ($(wc -w < "$T/run.suites"))" || bad "suite lists differ: $(diff <(tr ' ' '\n' < "$T/real.suites") <(tr ' ' '\n' < "$T/run.suites") | head -4)"
    n_web=$(cd "$ROOT/web" 2>/dev/null && ls tests/test_*.py 2>/dev/null | wc -l)
    [ "$(js "$T/real.json" "d['families']['web']['suites']")" = "$n_web" ] && ok "every web/tests/test_*.py is counted ($n_web)" || bad "web count: $(js "$T/real.json" "d['families']['web']['suites']") vs $n_web"
    [ "$(js "$T/real.json" "d['families']['shell']['test_lines'] > 0 and d['families']['web']['test_lines'] > 0")" = True ] && ok "both families have test lines" || bad "no test lines"
else
    bad "the real checkout: rc=$rc $(cat "$T/err")"
fi

[ "$fail" = 0 ] && echo "trimreport: pass" || echo "trimreport: FAIL"
exit $fail
