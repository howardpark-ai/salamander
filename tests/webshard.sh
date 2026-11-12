#!/usr/bin/env bash
# .github/scripts/web-shard.sh, which deals the web app's test files to the shards of tests.yml's `web-shard` job by their RECORDED
# times (web/tests/timings.json; the dealer itself, .github/scripts/deal.py, is checked by tests/deal.sh). A wrong split costs a test
# that never runs (a file in no shard) or runs twice, and neither shows as a failure, so this checks the split itself: on a
# throwaway tree with test files whose sizes run opposite to their recorded times, the four shards are exactly the expected lists
# (the size does not matter, the time does), their union is exactly all tests/test_*.py of web/ and the shards are disjoint, the
# same on a second call, a new file with no recorded time is dealt (at the median) and a recorded file that is gone is ignored,
# no timings file deals evenly, a timings file that is not valid exits 2, conftest.py, helpers and fixtures are not dealt, a bad
# shard number or count exits 2 (nothing printed), and a shard with no file (more shards than files, or no test file at all)
# exits 1. Then the same on this checkout's real web/tests/ with six shards. No network, no tmux, no process but the scripts themselves.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
SCRIPT="$ROOT/.github/scripts/web-shard.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/sala-webshard.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
exec 8< "$T"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock

# a tree shaped like the repository: <tree>/.github/scripts/{web-shard.sh,deal.py} and <tree>/web/tests/test_*.py
mk() {  # <tree> → the scripts in place, web/tests empty but for files that are no test (conftest.py, a fixture)
    mkdir -p "$1/.github/scripts" "$1/web/tests/fixtures"
    cp "$SCRIPT" "$ROOT/.github/scripts/deal.py" "$1/.github/scripts/"
    : > "$1/web/tests/conftest.py"; : > "$1/web/tests/fixtures/test_not_a_test.py"; : > "$1/web/tests/helper.py"
}
size() {  # <tree> <name> <bytes>
    head -c "$3" /dev/zero > "$1/web/tests/$2"
}
times() {  # <tree> then name=seconds… → web/tests/timings.json
    local t="$1"; shift
    python3 -I - "$t/web/tests/timings.json" "$@" <<'EOF'
import json, sys
json.dump({"version": 1, "unit": "seconds", "timings": {"tests/" + k: float(v) for k, v in (a.split("=", 1) for a in sys.argv[2:])}}, open(sys.argv[1], "w"))
EOF
}
shard() { bash "$1/.github/scripts/web-shard.sh" "$2" "$3" 2>"$T/err"; }   # <tree> <shard> <n> → its files; stderr in $T/err

echo "== a tree of ten test files: the biggest file is the fastest, the smallest the slowest"
A="$T/a"; mk "$A"
i=0; for n in a b c d e f g h i j; do i=$((i + 1)); size "$A" "test_$n.py" $(( (11 - i) * 100 )); done   # a is 1000 bytes, j is 100
times "$A" test_a.py=10 test_b.py=20 test_c.py=30 test_d.py=40 test_e.py=50 test_f.py=60 test_g.py=70 test_h.py=80 test_i.py=90 test_j.py=100
# by time, longest first: j i h g f e d c b a; each to the lightest of four: j→1 (100), i→2 (90), h→3 (80), g→4 (70), f→4 (130), e→3 (130),
# d→2 (130), c→1 (130), b→1 (150, the tie to the lower number), a→2 (140)
want1="tests/test_j.py tests/test_c.py tests/test_b.py"; want2="tests/test_i.py tests/test_d.py tests/test_a.py"
want3="tests/test_h.py tests/test_e.py"; want4="tests/test_g.py tests/test_f.py"
for s in 1 2 3 4; do
    w=want$s; got=$(shard "$A" $s 4 | paste -sd' ')
    [ "$got" = "${!w}" ] && ok "shard $s of 4 is ${!w//tests\/test_/}" || bad "shard $s of 4: got '$got', want '${!w}'"
done
all=$(for s in 1 2 3 4; do shard "$A" $s 4; done | sort); every=$(cd "$A/web" && ls tests/test_*.py | sort)
[ "$all" = "$every" ] && ok "the union of the four shards is exactly the ten tests/test_*.py" || bad "union: '$all' vs '$every'"
[ -z "$(echo "$all" | sort | uniq -d)" ] && ok "no file is in two shards" || bad "a file is in two shards: $(echo "$all" | sort | uniq -d)"
case "$all" in *conftest*|*helper*|*fixtures*) bad "a file that is no tests/test_*.py was dealt: $all" ;; *) ok "conftest.py, helper.py and the fixtures folder are not dealt" ;; esac
[ "$(shard "$A" 2 4)" = "$(shard "$A" 2 4)" ] && ok "the same split on a second call" || bad "the split changed between two calls"
got=$(shard "$A" 1 1 | sort | paste -sd' '); [ "$got" = "$(echo "$every" | paste -sd' ')" ] && ok "one shard of one gets every file" || bad "1 of 1: '$got'"
shard "$A" 1 4 >/dev/null; grep -q 'shard 1 of 4: 3 items, about 150 s' "$T/err" && ok "the log line says the shard's share and its estimated seconds (150 s)" || bad "report: $(cat "$T/err")"

echo "== equal times: ties by name, the same split everywhere"
B="$T/b"; mk "$B"
for n in e d c b a; do size "$B" "test_$n.py" 50; done
times "$B" test_a.py=7 test_b.py=7 test_c.py=7 test_d.py=7 test_e.py=7
got=$(shard "$B" 1 2 | paste -sd' '); [ "$got" = "tests/test_a.py tests/test_c.py tests/test_e.py" ] && ok "ties are dealt by name (shard 1 of 2: a c e)" || bad "ties: '$got'"
got=$(LC_ALL=en_US.UTF-8 shard "$B" 2 2 | paste -sd' '); [ "$got" = "tests/test_b.py tests/test_d.py" ] && ok "… whatever the caller's locale (shard 2 of 2: b d)" || bad "locale: '$got'"

echo "== a new test file is dealt at the median, a recorded file that is gone is ignored"
size "$A" test_new.py 5000
# the median of the ten recorded times (10..100) is 55, so the new file sits between f (60) and e (50): f→4 (130), new→3 (80 + 55 = 135), e→2 (140), d→1 (140),
# c→4 (160), b→3 (155), a→1 (150): shard 3 is h, the new file, b
got=$(shard "$A" 3 4 | paste -sd' '); [ "$got" = "tests/test_h.py tests/test_new.py tests/test_b.py" ] && ok "the new file, with no entry, is dealt at the median (55 s): shard 3 is h, new, b" || bad "new file: '$got'"
all=$(for s in 1 2 3 4; do shard "$A" $s 4; done | sort); [ "$all" = "$(cd "$A/web" && ls tests/test_*.py | sort)" ] && ok "… and the union is still every file, the new one once" || bad "union with a new file: '$all'"
rm -f "$A/web/tests/test_new.py"
times "$A" test_a.py=10 test_b.py=20 test_c.py=30 test_d.py=40 test_e.py=50 test_f.py=60 test_g.py=70 test_h.py=80 test_i.py=90 test_j.py=100 test_gone.py=5000
got=$(shard "$A" 1 4 | paste -sd' '); [ "$got" = "$want1" ] && ok "a recorded file that is not there is ignored (shard 1 as before)" || bad "gone file: '$got'"
rm -f "$A/web/tests/timings.json"
got=$(shard "$A" 1 4 | paste -sd' '); rc=$?
[ "$got" = "tests/test_a.py tests/test_e.py tests/test_i.py" ] && grep -q 'no recorded times' "$T/err" && ok "no timings file: the files are dealt evenly, by name (a e i), with a note" || bad "no timings: '$got' $(cat "$T/err")"
printf 'not json' > "$A/web/tests/timings.json"
out=$(shard "$A" 1 4); rc=$?; [ "$rc" = 2 ] && [ -z "$out" ] && grep -q 'timings.json' "$T/err" && ok "a timings file that is not valid: exit 2, named, nothing printed" || bad "bad timings: rc=$rc out='$out'"
rm -f "$A/web/tests/timings.json"

echo "== a bad argument exits 2 and prints nothing on stdout"
for args in "" "1" "0 4" "5 4" "x 4" "1 x" "-1 4" "1 0" "1.5 4" "1 4 4" "01x 4" "1 4x"; do
    out=$(bash "$A/.github/scripts/web-shard.sh" $args 2>"$T/err"); rc=$?
    [ "$rc" = 2 ] && [ -z "$out" ] && grep -q '^usage: web-shard.sh' "$T/err" && ok "args '$args': usage, exit 2" || bad "args '$args': rc=$rc out='$out' err=$(cat "$T/err")"
done

echo "== a shard with no file exits 1"
out=$(shard "$A" 11 12); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && grep -q 'shard 11 of 12 has no test file' "$T/err" && ok "shard 11 of 12 over ten files: exit 1, named" || bad "11 of 12: rc=$rc out='$out' err=$(cat "$T/err")"
out=$(shard "$A" 12 12); rc=$?; [ "$rc" = 1 ] && ok "shard 12 of 12: exit 1" || bad "12 of 12: rc=$rc out='$out'"
out=$(shard "$A" 10 12); rc=$?; [ "$rc" = 0 ] && [ -n "$out" ] && ok "shard 10 of 12 (a file of its own): exit 0" || bad "10 of 12: rc=$rc out='$out'"
E="$T/e"; mk "$E"
out=$(shard "$E" 1 4); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && grep -q 'no tests/test_\*.py under web/' "$T/err" && ok "no test file at all: exit 1, named" || bad "no tests: rc=$rc out='$out' err=$(cat "$T/err")"

echo "== this checkout's web/tests, six shards"
every=$(cd "$ROOT/web" && ls tests/test_*.py | sort); n=$(echo "$every" | wc -l)
if [ "$n" -ge 6 ]; then
    all=$(for s in 1 2 3 4 5 6; do bash "$SCRIPT" $s 6 2>/dev/null; done | sort)
    [ "$all" = "$every" ] && ok "the six shards deal exactly the $n tests/test_*.py of web/" || bad "real union differs: $(diff <(echo "$all") <(echo "$every") | head -5)"
    [ -z "$(echo "$all" | uniq -d)" ] && ok "… each in one shard only" || bad "a real file is in two shards"
else
    ok "no web/tests here ($n test files): the real-tree check does not apply"
fi

[ "$fail" = 0 ] && echo "webshard: pass" || echo "webshard: FAIL"
exit $fail
